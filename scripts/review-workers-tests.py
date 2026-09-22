#!/usr/bin/env python3
"""Offline worker lifecycle/evidence tests, also shipped to consumers."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import threading

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('workers', Path(__file__).with_name('review-workers.py'))
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


def snapshot(**changes):
    s = dict(repository='fixture/project', number=1, head='a'*40, base='trunk', base_sha='b'*40,
             branch='ticket/AA-1', ticket='AA-1', intent='fixture intent', pr_body='fixture PR', criteria='First criterion\nSecond criterion',
             criteria_hash=w.q.digest('First criterion\nSecond criterion'),
             criteria_items=[dict(id='c1', text='First criterion'), dict(id='c2', text='Second criterion')],
             review_evidence='review:7', threads=[], comments=[], reviews=[], commits=['a'*40],
             changes_requested=False, author_login='author', assignee='owner',
             ticket_metadata={'labels':[], 'dependencies':[]})
    s.update(changes)
    return s


def policy():
    return dict(revision='fixture-v1', timeout=10, max_attempts=2,
                roles={r:dict(identity=r, github_login='author', command=['/usr/bin/true'], env={'HOME':'/tmp/'+r})
                       for r in ('author','acceptance')})


def result(job, **changes):
    s = job['snapshot']
    r = dict(job_id=job['id'], head=s['head'], criteria_hash=s['criteria_hash'],
             policy_hash=job['policy_hash'], outcome='pass',
             criteria=[dict(id=c['id'], evidence='fixture assertion '+c['id']) for c in s['criteria_items']])
    r.update(changes)
    return r


class WorkersTest(unittest.TestCase):
    def test_lifecycle_reply_cannot_forge_another_job_or_revision(self):
        p=policy(); p['lifecycle']={'command':['/fixed/broker'],'timeout':30,'revision':'a'*64}
        j=self.db.prepare(snapshot(),'author',self.tree,p)
        proof=dict(job_id=j['id'],role=j['role'],phase='closed',revision='a'*64,
                   fence=w.q.digest([j['id'],j['policy_hash'],w.binding(j['snapshot'])]))
        for field,value in (('job_id','b'*64+'-1'),('role','acceptance'),('fence','c'*64),
                            ('revision','d'*64),('phase','launched')):
            reply=dict(protocol=1,result=dict(proof,**{field:value}))
            proc=mock.Mock(returncode=0,stdout=json.dumps(reply))
            with mock.patch.object(w.subprocess,'run',return_value=proc):
                with self.assertRaises(w.q.QueueError): w.reconcile(self.db,j['id'])
            self.assertTrue(self.db.get(j['id'])['active'])
        proc=mock.Mock(returncode=0,stdout=json.dumps(dict(protocol=1,result=proof)))
        with mock.patch.object(w.subprocess,'run',return_value=proc): w.reconcile(self.db,j['id'])
        self.assertFalse(self.db.get(j['id'])['active'])

    def test_domain_stop_proof_is_required_even_without_recorded_pgid(self):
        p=policy(); p['lifecycle']={'command':['/fixed/broker'], 'timeout':30, 'revision':'a'*64}
        j=self.db.prepare(snapshot(),'author',self.tree,p)
        with mock.patch.object(w,'domain_call',side_effect=w.q.QueueError('domain populated')):
            with self.assertRaisesRegex(w.q.QueueError,'populated'): w.reconcile(self.db,j['id'])
        self.assertTrue(self.db.get(j['id'])['active'])
        with mock.patch.object(w,'domain_call',return_value={'phase':'closed'}):
            w.reconcile(self.db,j['id'])
        self.assertFalse(self.db.get(j['id'])['active'])

    def test_domain_intent_survives_restart_without_rewriting_history(self):
        old=self.job(); w.reconcile(self.db,old['id'])
        before=list(self.db.db.execute('SELECT * FROM worker_events WHERE job=?',(old['id'],)))
        p=policy(); p['lifecycle']={'command':['/fixed/broker'], 'timeout':30, 'revision':'a'*64}
        j=self.db.prepare(snapshot(number=2),'author',self.tree,p)
        self.db.close(); self.db=w.Journal(self.state)
        self.assertEqual('/fixed/broker',self.db.domain(j['id'])['command'][0])
        self.assertEqual(2,self.db.db.execute('SELECT version FROM worker_metadata').fetchone()[0])
        self.assertEqual([tuple(x) for x in before], [tuple(x) for x in self.db.db.execute(
            'SELECT * FROM worker_events WHERE job=?',(old['id'],))])

    def test_author_packet_asks_for_resulting_head(self):
        j=self.job(role='author')
        example=w.packet(j)['result_schema']
        self.assertNotEqual(j['snapshot']['head'],example['head'])
        self.assertIn('resulting',example['head'])
        fresh=snapshot(head='c'*40)
        receipt=result(j,head=fresh['head'],outcome='handled',dispositions=[])
        self.assertEqual('handled',w.validate_result(j,receipt,fresh)['outcome'])

    def test_linux_zombies_live_threads_and_uncertain_inventory(self):
        zombies={12:('Z','100')}
        with mock.patch.object(w.sys,'platform','linux'), mock.patch.object(w.os,'killpg'):
            for observations, expected in (([zombies,zombies],False),
                ([{12:('Z','100'),13:('S','100')}],True), ([None],True),
                ([{}],True), ([zombies,{12:('Z','100'),14:('Z','101')}],True)):
                with self.subTest(observations=observations), mock.patch.object(w,'linux_group_tasks',side_effect=observations):
                    self.assertEqual(expected,w.group_alive(12))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='review-workers-')
        self.root = Path(self.temp.name)
        self.state = self.root/'state'
        self.db = w.Journal(self.state)
        self.tree = self.root/'tree'
        self.tree.mkdir()

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def job(self, role='acceptance', snap=None, tree=None, retry=None):
        return self.db.prepare(snap or snapshot(), role, tree or self.tree, policy(), retry)

    def test_duplicate_and_restart_have_one_owner(self):
        j = self.job()
        self.assertEqual(j['id'], self.job()['id'])
        self.db.close()
        self.db = w.Journal(self.state)
        self.assertEqual(j['id'], self.job()['id'])
        with self.assertRaises(w.q.QueueError):
            self.job(role='author')
        with self.assertRaises(w.q.QueueError):
            self.job(snap=snapshot(number=2))  # same worktree, different PR

    def test_changed_head_cannot_steal_an_active_job(self):
        self.job()
        with self.assertRaises(w.q.QueueError):
            self.job(snap=snapshot(head='c'*40))

    def test_every_criterion_and_identity_required(self):
        j = self.job()
        self.assertEqual('pass', w.validate_result(j, result(j), snapshot())['outcome'])
        for change in ({'criteria':[]}, {'criteria':[{'id':'c1','evidence':'x'}]},
                       {'head':'c'*40}, {'criteria_hash':'d'*64}, {'policy_hash':'e'*64},
                       {'job_id':'other'}, {'criteria':[{'id':'c1','evidence':'x'}]*2},
                       {'criteria':[{'id':'c1','evidence':''},{'id':'c2','evidence':'x'}]}):
            with self.subTest(change=change), self.assertRaises(w.q.QueueError):
                w.validate_result(j, result(j, **change), snapshot())

    def test_head_criteria_policy_and_feedback_invalidate_pass(self):
        j = self.job()
        for s in (snapshot(head='c'*40), snapshot(criteria_hash='e'*64),
                  snapshot(base_sha='d'*40), snapshot(intent='new intent'), snapshot(pr_body='new claim'), snapshot(comments=[{'id':8}]),
                  snapshot(review_evidence=None)):
            with self.subTest(snapshot=s), self.assertRaises(w.q.QueueError):
                w.validate_result(j, result(j), s)
        self.db.record(j['id'], 'finished', result(j))
        self.db.release(j['id'], 'verified stopped')
        self.assertTrue(self.db.acceptance(snapshot(), policy()))
        self.assertIsNone(self.db.acceptance(snapshot(head='c'*40), policy()))
        self.assertIsNone(self.db.acceptance(snapshot(), dict(policy(), revision='v2')))

    def test_metadata_changes_invalidate_active_jobs_and_receipts(self):
        original = {'labels':['sprint', 'story:LS-03'], 'dependencies':[
            {'id':'AA-2', 'dependency_type':'blocks', 'status':'closed'}]}
        changes = [dict(original, labels=[]), dict(original, labels=['sprint']),
                   dict(original, labels=original['labels']+['urgent']),
                   dict(original, dependencies=[]),
                   dict(original, dependencies=original['dependencies']+[
                       {'id':'AA-3', 'dependency_type':'blocks', 'status':'open'}])]
        for field, value in [('id','AA-3'), ('dependency_type','related'), ('status','open')]:
            changes.append(dict(original, dependencies=[dict(original['dependencies'][0], **{field:value})]))
        s=snapshot(ticket_metadata=original)
        j=self.job(snap=s)
        self.assertEqual(original, w.packet(j)['snapshot']['ticket_metadata'])
        for state in ('queued','running'):
            self.db.record(j['id'],state)
            for metadata in changes:
                fresh=snapshot(ticket_metadata=metadata)
                with self.subTest(state=state,metadata=metadata):
                    with self.assertRaises(w.q.QueueError): self.job(snap=fresh)
                    with self.assertRaises(w.q.QueueError): w.validate_result(j,result(j),fresh)
        self.db.record(j['id'],'finished',result(j))
        self.db.release(j['id'],'fixture verified stopped')
        self.assertTrue(self.db.acceptance(s,policy()))
        for metadata in changes:
            self.assertIsNone(self.db.acceptance(snapshot(ticket_metadata=metadata),policy()))

    def test_metadata_normalization_rejects_incomplete_provider_values(self):
        self.assertEqual({'labels':[], 'dependencies':[]},w.ticket_metadata({}))
        for value in ({'labels':None}, {'labels':'sprint'}, {'labels':['']},
                      {'dependencies':None}, {'dependencies':{}},
                      {'dependencies':[{'id':'AA-2','status':'open'}]},
                      {'dependencies':[{'id':'AA-2','dependency_type':'blocks'}]}):
            with self.subTest(value=value), self.assertRaises(w.q.QueueError):
                w.ticket_metadata(value)

    def test_legacy_receipts_missing_metadata_are_stale(self):
        j=self.job()
        self.db.record(j['id'],'finished',result(j))
        self.db.release(j['id'],'fixture verified stopped')
        legacy=dict(j['snapshot']);del legacy['ticket_metadata']
        self.db.db.execute('UPDATE jobs SET snapshot=? WHERE id=?',(w.q.encoded(legacy),j['id']))
        # Tolerate legacy shape independently of policy invalidation; never infer empty metadata.
        self.assertIsNone(self.db.acceptance(snapshot(),policy()))
        self.db.db.execute('UPDATE jobs SET policy_hash=? WHERE id=?',('pre-upgrade-policy',j['id']))
        self.assertIsNone(self.db.acceptance(snapshot(),policy()))

    def test_author_receipt_is_also_invalidated_by_metadata_change(self):
        j=self.job(role='author')
        fresh=snapshot(ticket_metadata={'labels':['new-scope'], 'dependencies':[]})
        with self.assertRaises(w.q.QueueError):
            w.validate_result(j,result(j,outcome='handled',dispositions=[]),fresh)

    def test_author_cannot_produce_acceptance(self):
        j = self.job(role='author')
        with self.assertRaises(w.q.QueueError):
            w.validate_result(j, result(j), snapshot())
        r = result(j, outcome='handled', dispositions=[])
        w.validate_result(j, r, snapshot())
        self.db.record(j['id'], 'finished', r)
        self.db.release(j['id'], 'verified stopped')
        self.assertIsNone(self.db.acceptance(snapshot(), policy()))

    def test_crash_and_exhaustion_require_stop(self):
        j = self.job()
        self.db.record(j['id'], 'running', pgid=os.getpgrp())
        with self.assertRaises(w.q.QueueError):
            w.reconcile(self.db, j['id'])
        self.assertTrue(self.db.get(j['id'])['active'])
        self.db.record(j['id'], 'failed', {'error':'fixture stopped'}, pgid=None)
        w.reconcile(self.db, j['id'])
        with self.assertRaises(w.q.QueueError):
            self.job()  # retries must be explicit
        j2 = self.job(retry='corrected adapter')
        self.assertNotEqual(j['id'], j2['id'])
        self.db.record(j2['id'], 'failed', {'error':'fixture stopped'})
        w.reconcile(self.db, j2['id'])
        with self.assertRaises(w.q.QueueError):
            self.job(retry='third attempt')

    def test_clean_summary_requires_trusted_actor_completion_and_resolution(self):
        body='<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | ✅ **Completed** | `aaaaaaa` | Manual request |'
        comment=dict(id=11, user={'login':w.q.REVIEWER}, body=body)
        resolve=lambda value: 'a'*40
        self.assertEqual('comment:11', w.q.review_evidence([], 'a'*40, [comment], resolve))
        for c in (dict(comment, user={'login':'author'}), dict(comment,body=body.replace('Completed','Running')),dict(comment,body='Quoted: '+body)):
            self.assertIsNone(w.q.review_evidence([], 'a'*40, [c], resolve))
        self.assertIsNone(w.q.review_evidence([], 'a'*40, [comment], lambda _: 'b'*40))
        with self.assertRaises(w.q.QueueError):
            w.q.review_evidence([], 'a'*40, [comment], lambda _: (_ for _ in ()).throw(w.q.QueueError('ambiguous')))


    def test_blocked_acceptance_never_returns_a_pass(self):
        j=self.job()
        self.db.record(j['id'],'finished',result(j,outcome='blocked',blocker='missing proof'))
        self.db.release(j['id'],'stopped')
        self.assertIsNone(self.db.acceptance(snapshot(),policy()))

    def test_separate_ticket_requires_verified_ticket_criteria(self):
        t=dict(id='thread1',root=10,resolved=False)
        j=self.job('author',snapshot(threads=[t],review_evidence=None))
        reply=dict(id=20,html_url='https://example/reply',in_reply_to_id=10,user={'login':'author'},body='Outside scope, tracked AA-2')
        fresh=snapshot(threads=[t],comments=[reply],review_evidence=None)
        d=dict(finding='thread1',kind='separate-ticket',reply_url=reply['html_url'],ticket='AA-2',rationale='Outside scope',evidence='requirement boundary')
        r=result(j,outcome='blocked',blocker='follow-up required',dispositions=[d])
        with self.assertRaises(w.q.QueueError): w.validate_result(j,r,fresh)
        fresh['followups']={'AA-2':{'acceptance_criteria':'named regression proof'}}
        self.assertEqual('blocked',w.validate_result(j,r,fresh)['outcome'])

    def test_two_processes_cannot_dispatch_one_job_twice(self):
        j=self.job()
        self.db.start(j['id'])
        second=w.Journal(self.state)
        try:
            with self.assertRaises(w.q.QueueError): second.start(j['id'])
        finally: second.close()

    def test_concurrent_pr_claims(self):
        barrier=threading.Barrier(2)
        results=[]
        def claim(role):
            db=w.Journal(self.state)
            try:
                barrier.wait()
                results.append(db.prepare(snapshot(),role,self.tree,policy())['id'])
            except w.q.QueueError: results.append(None)
            finally: db.close()
        threads=[threading.Thread(target=claim,args=(r,)) for r in ('author','acceptance')]
        for t in threads:t.start()
        for t in threads:t.join()
        self.assertEqual(1,sum(v is not None for v in results))

    def test_launcher_lock_prevents_uncertain_start_recovery(self):
        j=self.job()
        self.db.start(j['id'])
        with w.job_lock(self.state,j['id']):
            with self.assertRaises(w.q.QueueError): w.reconcile(self.db,j['id'])
        self.assertEqual('failed',w.reconcile(self.db,j['id'])['state'])

    def test_author_fix_and_dispute_need_actual_thread_replies(self):
        thread=dict(id='thread1',root=10,resolved=False)
        s=snapshot(threads=[thread],review_evidence=None)
        j=self.job('author',s)
        reply=dict(id=20,html_url='https://example/reply/20',in_reply_to_id=10,
                   user={'login':'author'},body='fixed '+'a'*40)
        fresh=snapshot(threads=[dict(thread,resolved=True)],comments=[reply])
        d=dict(finding='thread1',kind='fix',commit='a'*40,reply_url=reply['html_url'],evidence='regression passed')
        r=result(j,outcome='handled',dispositions=[d])
        w.validate_result(j,r,fresh)
        for change in (dict(comments=[]),dict(commits=[]),dict(comments=[dict(reply,in_reply_to_id=99)]),
                       dict(comments=[dict(reply,user={'login':'reviewer'})])):
            with self.subTest(change=change),self.assertRaises(w.q.QueueError):
                w.validate_result(j,r,dict(fresh,**change))
        dispute=dict(d,kind='dispute',rationale='requirement excludes this case')
        reply['body']=dispute['rationale']
        with self.assertRaises(w.q.QueueError): w.validate_result(j,dict(r,dispositions=[dispute]),fresh)
        w.validate_result(j,dict(r,outcome='blocked',blocker='await reviewer',dispositions=[dispute]),fresh)


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='worker-runtime-')
        self.root=Path(self.temp.name)
        self.repo=self.root/'repo'
        self.repo.mkdir()
        self.state=self.root/'state'
        self.bin=self.root/'bin'; self.bin.mkdir()
        self.data=self.root/'provider.json'
        self.policy=self.root/'policy.json'
        self.cli=Path(__file__).with_name('review-workers.py').resolve()
        self.env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ['PATH'],FIXTURE_DATA=str(self.data))
        def git(*args):return subprocess.check_output(['git','-C',str(self.repo)]+list(args),text=True,stderr=subprocess.DEVNULL).strip()
        self.git=git
        git('init','-q');git('config','user.email','test@example.invalid');git('config','user.name','fixture')
        git('checkout','-qb','ticket/AA-1')
        (self.repo/'proof.py').write_text('assert 1 + 1 == 2\n')
        git('add','.');git('commit','-qm','AA-1: fixture')
        head=git('rev-parse','HEAD')
        self.data.write_text(json.dumps(dict(head=head,base=head,comments=[],threads=[],reviews=[],
                                            issue_comments=[],criteria='Check proof.py',commit_message='AA-1: fixture')))
        stub=r"""#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
s=json.loads(Path(os.environ['FIXTURE_DATA']).read_text())
a=sys.argv[1:]
if Path(sys.argv[0]).name=='bd':
 if s.get('feedback_race'):
  counter=Path(os.environ['FIXTURE_DATA']+'.reads');n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
  if n==2:
   s['issue_comments'].append(dict(id=99,body='new finding during observation',user={'login':'reviewer'}))
   Path(os.environ['FIXTURE_DATA']).write_text(json.dumps(s))
 if s.get('metadata_race'):
  counter=Path(os.environ['FIXTURE_DATA']+'.metadata-reads');n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
  if n==s['metadata_race']:
   s[s['metadata_field']]=s['metadata_change']
   Path(os.environ['FIXTURE_DATA']).write_text(json.dumps(s))
 print(json.dumps([dict(id='AA-1',status='in_progress',assignee='owner',acceptance_criteria=s['criteria'],labels=s.get('labels',[]),dependencies=s.get('dependencies',[]))]));sys.exit()
if a[0]=='repo':print(json.dumps({'nameWithOwner':'fixture/project'}));sys.exit()
if a[:2]==['api','graphql']:
 print(json.dumps({'data':{'node':{'reviewThreads':{'pageInfo':{'hasNextPage':False,'endCursor':None},'nodes':s['threads']}}}}));sys.exit()
assert a[:3]==['api','--method','GET'],a
path=a[3]
if '/pulls/1/commits' in path: value=[{'sha':s['head'],'commit':{'message':s['commit_message']}}]
elif '/pulls/1/reviews' in path: value=s['reviews']
elif '/pulls/1/comments' in path: value=s['comments']
elif '/issues/1/comments' in path: value=s['issue_comments']
elif '/pulls/1' in path:
 value=dict(state='open',draft=False,merged=False,node_id='pr1',user={'login':'author'},head={'sha':s['head'],'ref':'ticket/AA-1','repo':{'full_name':'fixture/project'}},base={'ref':'trunk'})
elif '/commits/trunk' in path:value={'sha':s['base']}
elif '/commits/' in path:value={'sha':s['head']}
else:raise AssertionError(path)
if '--paginate' in a:value=[value]
print(json.dumps(value))
"""
        for command in ('gh','bd'):
            path=self.bin/command;path.write_text(stub);path.chmod(0o755)
        self.adapter=self.root/'adapter.py'
        self.adapter.write_text(r"""import json,os,sys,time
from pathlib import Path
p=json.load(sys.stdin);s=p['snapshot'];r=p['result_schema']
assert 'CONTROLLER_SECRET' not in os.environ
mode=os.environ.get('MODE','pass')
if mode=='sleep':
 Path(os.environ['MARKER']).write_text(str(os.getpid()))
 time.sleep(30)
if mode=='invalid':print('{}');sys.exit()
if mode=='stderr-large':sys.stderr.write('x'*(1024*1024+1))
if mode=='dirty':Path('unexpected.txt').write_text('changed by reviewer')
if mode=='descendant':
 import subprocess
 subprocess.Popen([sys.executable,'-c','import time; time.sleep(2)'])
if mode=='metadata-change':
 d=Path(os.environ['FIXTURE_DATA']);v=json.loads(d.read_text());v[v['metadata_field']]=v['metadata_change'];d.write_text(json.dumps(v))
if mode=='source-change':
 d=Path(os.environ['FIXTURE_DATA']);v=json.loads(d.read_text());v['criteria']='changed while reviewing';d.write_text(json.dumps(v))
r['head']=s['head']
r['outcome']='handled' if p['role']=='author' else 'pass'
if p['role']=='author':r['dispositions']=[]
else:r['criteria']=[dict(id=c['id'],evidence='proof.py assertion') for c in s['criteria_items']]
print(json.dumps(r))
""")
        self.configure()
        self.complete_review()

    def configure(self,mode='pass',timeout=10):
        p=policy();p['timeout']=timeout
        for role in p['roles']:
            p['roles'][role]['command']=[sys.executable,str(self.adapter)]
            p['roles'][role]['env']={'HOME':str(self.root/role),'MODE':mode,'MARKER':str(self.root/'started'),
                                   'FIXTURE_DATA':str(self.data),'PATH':os.environ['PATH']}
        self.policy.write_text(json.dumps(p))

    def complete_review(self):
        s=json.loads(self.data.read_text())
        s['reviews']=[dict(id=7,body='review complete',user={'login':w.q.REVIEWER},commit_id=s['head'],submitted_at='now',state='COMMENTED')]
        self.data.write_text(json.dumps(s))

    def tearDown(self):self.temp.cleanup()

    def call(self,*args):
        return subprocess.run([sys.executable,str(self.cli),'--state',str(self.state),'--root',str(self.repo),
                               '--policy',str(self.policy)]+list(args),env=dict(self.env,CONTROLLER_SECRET='do-not-inherit'),
                              capture_output=True,text=True,timeout=15)

    def prepare(self,role='acceptance'):
        p=self.call('prepare','--repo','fixture/project','--pr','1','--worktree',str(self.repo),'--role',role)
        self.assertEqual(0,p.returncode,p.stderr)
        return json.loads(p.stdout)

    def test_real_process_pass_and_fresh_query(self):
        j=self.prepare();p=self.call('run',j['id'])
        self.assertEqual(0,p.returncode,p.stderr)
        self.assertEqual('finished',json.loads(p.stdout)['state'])
        evidence=self.call('acceptance','--repo','fixture/project','--pr','1')
        self.assertEqual(0,evidence.returncode,evidence.stderr)
        self.assertFalse(json.loads(evidence.stdout)['merge_authorization'])
        self.assertNotEqual(str(self.repo),j['worktree'])
        self.assertFalse(Path(j['worktree']).exists())
        self.assertNotIn(j['worktree'],self.git('worktree','list','--porcelain'))
        self.assertFalse(json.loads(self.call('show',j['id']).stdout)['active'])
        repeat=self.prepare()
        self.assertEqual(j['id'],repeat['id'])
        self.assertNotEqual(0,self.call('run',j['id']).returncode)

    def test_repository_case_alias_reuses_finished_acceptance(self):
        j=self.prepare()
        self.assertEqual(0,self.call('run',j['id']).returncode)
        p=self.call('advance','--repo','FIXTURE/PROJECT','--pr','1','--worktree',str(self.repo))
        self.assertEqual(0,p.returncode,p.stderr)
        self.assertEqual(j['id'],json.loads(p.stdout)['id'])

    def test_incomplete_dirty_and_changed_source_never_pass(self):
        for mode in ('invalid','dirty','source-change'):
            with self.subTest(mode=mode):
                self.configure(mode)
                j=self.prepare();p=self.call('run',j['id'])
                self.assertEqual(1,p.returncode,p.stderr)
                self.assertEqual('failed',json.loads(p.stdout)['state'])
                self.assertNotEqual(0,self.call('acceptance','--repo','fixture/project','--pr','1').returncode)
                # Each mode gets a fresh detached tree and key after cleanup of this synthetic one.
                self.assertFalse(Path(j['worktree']).exists())

    def test_timeout_stops_group_before_releasing(self):
        self.configure('sleep',1)
        j=self.prepare();p=self.call('run',j['id'])
        self.assertEqual(1,p.returncode,p.stderr)
        done=json.loads(p.stdout)
        self.assertEqual('failed',done['state'])
        self.assertFalse(done['active'])
        self.assertFalse(w.group_alive(done['pgid']))

    def test_live_descendant_retains_slot_after_guardian_exits(self):
        self.configure('descendant')
        j=self.prepare();p=self.call('run',j['id'])
        self.assertNotEqual(0,p.returncode)
        self.assertIn('group still alive',p.stderr)
        self.assertTrue(json.loads(self.call('show',j['id']).stdout)['active'])
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            p=self.call('reconcile',j['id'])
            if p.returncode==0:break
            time.sleep(.05)
        self.assertEqual(0,p.returncode,p.stderr)

    def test_killed_launcher_does_not_duplicate_guardian(self):
        self.configure('sleep',2)
        j=self.prepare()
        cmd=[sys.executable,str(self.cli),'--state',str(self.state),'--root',str(self.repo),'--policy',str(self.policy),'run',j['id']]
        with open(os.devnull,'w') as sink:
            p=subprocess.Popen(cmd,env=self.env,stdout=sink,stderr=sink)
            deadline=time.monotonic()+5
            while not (self.root/'started').exists() and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue((self.root/'started').exists())
            p.kill();p.wait()
            blocked=self.call('reconcile',j['id'])
            self.assertNotEqual(0,blocked.returncode)
            self.assertNotEqual(0,self.call('run',j['id']).returncode)
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                stopped=self.call('reconcile',j['id'])
                if stopped.returncode==0:break
                time.sleep(.05)
            self.assertEqual(0,stopped.returncode,stopped.stderr)
            self.assertEqual('failed',json.loads(stopped.stdout)['state'])

    def test_second_journal_cannot_bypass_repository_ownership(self):
        self.prepare()
        other=self.root/'other-state'
        p=subprocess.run([sys.executable,str(self.cli),'--root',str(self.repo),'--state',str(other),'status'],env=self.env,capture_output=True,text=True)
        self.assertNotEqual(0,p.returncode)
        self.assertIn('another worker journal',p.stderr)

    def test_policy_change_after_prepare_never_launches_old_job(self):
        j=self.prepare();self.configure('sleep')
        p=self.call('run',j['id'])
        self.assertEqual(1,p.returncode,p.stderr)
        self.assertFalse((self.root/'started').exists())
        self.assertEqual('failed',json.loads(p.stdout)['state'])

    def test_provider_failure_blocks_prior_acceptance(self):
        j=self.prepare();self.assertEqual(0,self.call('run',j['id']).returncode)
        self.data.unlink()
        p=self.call('acceptance','--repo','fixture/project','--pr','1')
        self.assertNotEqual(0,p.returncode)
        self.assertNotIn('"outcome":"pass"',p.stdout)

    def test_feedback_race_blocks_prior_acceptance(self):
        j=self.prepare();self.assertEqual(0,self.call('run',j['id']).returncode)
        data=json.loads(self.data.read_text());data['feedback_race']=True
        self.data.write_text(json.dumps(data))
        p=self.call('acceptance','--repo','fixture/project','--pr','1')
        self.assertNotEqual(0,p.returncode,p.stdout)
        self.assertIn('feedback changed during observation',p.stderr)

    def change_data(self, **changes):
        data=json.loads(self.data.read_text());data.update(changes)
        self.data.write_text(json.dumps(data))

    def test_metadata_provider_order_is_stable_and_packet_is_complete(self):
        deps=[dict(id='AA-2',dependency_type='blocks',status='closed'),
              dict(id='AA-3',dependency_type='related',status='open')]
        self.change_data(labels=['sprint','story:LS-03'],dependencies=deps)
        j=self.prepare()
        metadata=j['snapshot']['ticket_metadata']
        self.assertEqual(['sprint','story:LS-03'],metadata['labels'])
        self.assertEqual(deps,metadata['dependencies'])
        self.change_data(labels=['story:LS-03','sprint'],dependencies=list(reversed(deps)))
        self.assertEqual(j['id'],self.prepare()['id'])
        self.assertEqual(0,self.call('run',j['id']).returncode)
        self.assertEqual(0,self.call('acceptance','--repo','fixture/project','--pr','1').returncode)

    def test_metadata_changes_before_during_and_after_worker(self):
        for phase in ('prepared','running','stored'):
            for field, change in [('labels',['new-label']),('dependencies',[
                    dict(id='AA-2',dependency_type='blocks',status='open')])]:
                with self.subTest(phase=phase,field=field):
                    self.change_data(labels=[],dependencies=[],metadata_field=field,metadata_change=change)
                    self.configure('metadata-change' if phase=='running' else 'pass')
                    p=json.loads(self.policy.read_text());p['revision']=phase+field
                    self.policy.write_text(json.dumps(p))
                    j=self.prepare()
                    if phase=='prepared': self.change_data(**{field:change})
                    run=self.call('run',j['id'])
                    self.assertEqual(0 if phase=='stored' else 1,run.returncode,run.stdout+run.stderr)
                    if phase=='stored': self.change_data(**{field:change})
                    evidence=self.call('acceptance','--repo','fixture/project','--pr','1')
                    self.assertNotEqual(0,evidence.returncode,evidence.stdout)
                    self.assertFalse(json.loads(self.call('show',j['id']).stdout)['active'])

    def test_metadata_race_at_both_final_source_reads_blocks_receipt(self):
        j=self.prepare();self.assertEqual(0,self.call('run',j['id']).returncode)
        for read in (2,3):
            for field, change in [('labels',['new-label']),('dependencies',[
                    dict(id='AA-2',dependency_type='blocks',status='open')])]:
                with self.subTest(read=read,field=field):
                    counter=Path(str(self.data)+'.metadata-reads')
                    if counter.exists(): counter.unlink()
                    self.change_data(labels=[],dependencies=[],metadata_race=read,
                                     metadata_field=field,metadata_change=change)
                    p=self.call('acceptance','--repo','fixture/project','--pr','1')
                    self.assertNotEqual(0,p.returncode,p.stdout)
                    self.assertIn('source changed during observation',p.stderr)

    def test_stderr_limit_after_fast_exit(self):
        self.configure('stderr-large')
        j=self.prepare();p=self.call('run',j['id'])
        self.assertEqual(1,p.returncode,p.stdout)
        self.assertEqual('failed',json.loads(p.stdout)['state'])

    def test_missing_reviewer_directory_is_unregistered_before_retry(self):
        import shutil
        j=self.prepare()
        self.git('worktree','add','--detach',j['worktree'],j['snapshot']['head'])
        shutil.rmtree(j['worktree'])
        self.assertIn(j['worktree'],self.git('worktree','list','--porcelain'))
        p=self.call('reconcile',j['id'])
        self.assertEqual(0,p.returncode,p.stderr)
        self.assertNotIn(j['worktree'],self.git('worktree','list','--porcelain'))
        p=self.call('advance','--repo','fixture/project','--pr','1','--worktree',str(self.repo),'--retry','verified stopped and cleaned')
        self.assertEqual(0,p.returncode,p.stderr)
        self.assertEqual('finished',json.loads(p.stdout)['state'])

    def test_clean_summary_is_resolved_via_provider(self):
        s=json.loads(self.data.read_text());s['reviews']=[]
        s['issue_comments']=[dict(id=9,html_url='https://example/comment/9',user={'login':w.q.REVIEWER},
          body='<!-- codex-pull-request-review-summary -->\n| **Code Review** | **Completed** | `'+s['head'][:7]+'` | Manual request |')]
        self.data.write_text(json.dumps(s))
        j=self.prepare()
        self.assertEqual('comment:9',j['snapshot']['review_evidence'])


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
