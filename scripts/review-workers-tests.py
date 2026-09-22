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


class IsolationTest(unittest.TestCase):
    def test_author_tree_is_opaque_to_reviewer_git(self):
        policy={'isolation':{'author_worktrees':{'AA-1':'/author/AA-1'}}}
        with mock.patch.object(w,'git',side_effect=AssertionError('reviewer entered author Git')):
            self.assertEqual('/author/AA-1',str(w.author_tree(policy,snapshot(),Path('/author/AA-1'))))
        for path in ('/author/other','/author/AA-1/../AA-1'):
            with self.assertRaises(w.q.QueueError):
                w.author_tree(policy,snapshot(),path)

    def test_isolated_prepare_does_not_read_author_git(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); tree=root/'hostile';tree.mkdir()
            marker=root/'executed'; hook=root/'fsmonitor'
            subprocess.run(['git','init','-q',str(tree)],check=True)
            hook.write_text('#!/bin/sh\ntouch '+str(marker)+'\nprintf "token\\000"\n')
            hook.chmod(0o755)
            subprocess.run(['git','-C',str(tree),'config','core.fsmonitor',str(hook)],check=True)
            p={'isolation':{'author_worktrees':{'AA-1':str(tree)}}}
            self.assertEqual(tree,w.author_tree(p,snapshot(),tree))
            self.assertFalse(marker.exists())

    def test_cross_uid_permission_uncertainty_retains_ownership(self):
        with mock.patch.object(w.os,'killpg',side_effect=PermissionError):
            self.assertTrue(w.group_alive(4242))

    def test_protected_paths_reject_links_and_author_owned_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'file';p.write_text('fixture')
            link=Path(td)/'link';link.symlink_to(p)
            with self.assertRaises(w.q.QueueError):w.protected_worker_path(link)
            with mock.patch.object(w.os,'getuid',return_value=os.getuid()+1):
                with self.assertRaises(w.q.QueueError):w.protected_worker_path(p)

    def test_bridge_rejects_wrong_identity_before_any_git_or_adapter(self):
        p={'author_uid':os.getuid()+1,'repo':'fixture/project','worktrees':{'AA-1':'/author/AA-1'},
           'command':['/usr/bin/false'],'env':{'HOME':'/author'}}
        with mock.patch.object(w,'git',side_effect=AssertionError('Git before UID check')):
            with self.assertRaisesRegex(w.q.QueueError,'configured non-root author UID'):
                w.validate_author_bridge(p,{'protocol':1,'role':'author','snapshot':snapshot(),'worktree':'/author/AA-1'})


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

    def test_isolated_guardian_never_runs_git_in_author_checkout(self):
        foreign=self.root/'foreign-author'
        subprocess.run(['git','clone','-q',str(self.repo),str(foreign)],check=True)
        marker=self.root/'reviewer-ran-author-hook'
        hook=self.root/'hostile-fsmonitor'
        hook.write_text('#!/bin/sh\ntouch '+str(marker)+'\nprintf "token\\000"\n');hook.chmod(0o755)
        subprocess.run(['git','-C',str(foreign),'config','core.fsmonitor',str(hook)],check=True)
        p=json.loads(self.policy.read_text())
        p['isolation']={'author_worktrees':{'AA-1':str(foreign)}}
        p['read_path']=self.env['PATH']
        with mock.patch.dict(os.environ,self.env,clear=True):
            fresh=w.Observer(self.repo).snapshot('fixture/project',1)
        db=w.Journal(self.state)
        try:
            j=db.prepare(fresh,'author',foreign,p);db.start(j['id'])
            fd=os.open(str(self.state/(j['id']+'.lock')),os.O_CREAT|os.O_RDWR,0o600)
            real_git=w.git
            def reviewer_git(root,*args):
                self.assertNotEqual(foreign,Path(root),'reviewer inspected author Git')
                return real_git(root,*args)
            with mock.patch.object(w,'load_policy',return_value=p), mock.patch.object(w.Observer,'snapshot',return_value=fresh), \
                 mock.patch.object(w.os,'getpgrp',return_value=os.getpid()), mock.patch.object(w,'git',side_effect=reviewer_git):
                w.execute_guardian(db,j['id'],self.policy,self.repo,fd)
            self.assertEqual('finished',db.get(j['id'])['state'],db.get(j['id'])['result'])
            self.assertFalse(marker.exists())
        finally:db.close()

    @unittest.skipIf(os.getuid()==0, 'requires a real non-root checkout owner; root uses --identity-proof')
    def test_author_bridge_checks_actual_checkout_before_adapter(self):
        self.git('remote','add','origin','https://github.com/fixture/project.git')
        p={'author_uid':os.getuid(),'repo':'fixture/project','worktrees':{'AA-1':str(self.repo.resolve())}}
        s=snapshot(head=self.git('rev-parse','HEAD'))
        packet={'protocol':1,'role':'author','snapshot':s,'worktree':str(self.repo.resolve())}
        self.assertEqual(self.repo.resolve(),w.validate_author_bridge(p,packet))
        for change in ({'head':'a'*40},{'branch':'ticket/AA-2'},{'repository':'other/repo'}):
            with self.subTest(change=change), self.assertRaises(w.q.QueueError):
                w.validate_author_bridge(p,{**packet,'snapshot':{**s,**change}})
        (self.repo/'dirty').write_text('must not start on an unclean checkout')
        with self.assertRaises(w.q.QueueError):w.validate_author_bridge(p,packet)

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

def identity_proof(author_uid, reviewer_uid, parent):
    """Opt-in, root-run synthetic OS proof. No credentials, GitHub calls or service installation."""
    import select
    import shutil
    import pwd
    w.q.require(os.getuid()==0 and author_uid>0 and reviewer_uid>0 and author_uid!=reviewer_uid,
                'identity proof requires root and two different non-root UIDs')
    parent=w.protected_worker_path(Path(parent),{0})
    root=Path(tempfile.mkdtemp(prefix='worker-identity-proof-',dir=parent));root.chmod(0o755)
    children=set()
    def drop(uid):
        try:gid=pwd.getpwuid(uid).pw_gid
        except KeyError:gid=uid
        os.setgroups([]);os.setgid(gid);os.setuid(uid)
        os.environ.clear();os.environ.update(PATH='/usr/bin:/bin',HOME=str(root/str(uid)))
        os.chdir(os.environ['HOME']);os.umask(0o077)
    def run_as(uid, fn):
        rd,wr=os.pipe();pid=os.fork()
        if pid==0:
            os.close(rd);os.setpgid(0,0)
            try:
                drop(uid);value=fn();out={'ok':True,'value':value}
            except BaseException as exc:out={'ok':False,'error':type(exc).__name__+': '+str(exc)}
            os.write(wr,json.dumps(out).encode());os.close(wr);os._exit(0)
        children.add(pid);os.close(wr)
        try:
            if not select.select([rd],[],[],30)[0]:raise AssertionError('identity fixture timed out')
            raw=os.read(rd,1024*1024);os.waitpid(pid,0);children.remove(pid)
            value=json.loads(raw);assert value['ok'],value
            return value['value']
        finally:os.close(rd)
    def git(repo,*args):
        return subprocess.check_output(['/usr/bin/git','-C',str(repo),*args],text=True,
                                       stderr=subprocess.DEVNULL,timeout=10).strip()
    try:
        author=root/str(author_uid);reviewer=root/str(reviewer_uid)
        for home,uid in ((author,author_uid),(reviewer,reviewer_uid)):
            home.mkdir(mode=0o700);os.chown(home,uid,uid)
        seed=root/'seed';seed.mkdir()
        env={'PATH':'/usr/bin:/bin','HOME':str(root)}
        for args in (['init','-q'],['config','user.name','Synthetic'],['config','user.email','fixture@example.invalid'],['checkout','-qb','ticket/AA-1']):
            subprocess.run(['/usr/bin/git','-C',str(seed)]+args,env=env,check=True,stdout=subprocess.DEVNULL)
        (seed/'proof.txt').write_text('synthetic fixture\n')
        for args in (['add','.'],['commit','-qm','AA-1: synthetic']):
            subprocess.run(['/usr/bin/git','-C',str(seed)]+args,env=env,check=True)
        head=git(seed,'rev-parse','HEAD')
        git(seed,'bundle','create',str(root/'seed.bundle'),'--all')
        for uid,home in ((author_uid,author),(reviewer_uid,reviewer)):
            run_as(uid,lambda home=home:subprocess.run(['/usr/bin/git','clone','-q',str(root/'seed.bundle'),str(home/'repo')],check=True).returncode)
        bridge=root/'bridge.json';adapter=root/'adapter.py';code=root/'code';code.mkdir()
        for name in ('review-workers.py','merge-queue.py'):
            shutil.copyfile(Path(w.__file__).with_name(name),code/name)
            (code/name).chmod(0o644)
        adapter.write_text('import json,os,sys\np=json.load(sys.stdin);r=p["result_schema"];r.update(head=p["snapshot"]["head"],outcome="handled",dispositions=[],executed_uid=os.getuid());print(json.dumps(r))\n')
        adapter.chmod(0o644)
        tools=root/'tools';tools.mkdir()
        for name in ('gh','bd'):
            tool=tools/name;tool.write_text('#!/bin/sh\nexit 99\n');tool.chmod(0o755)
        # Python is a fixed protected executable; this root-owned config pins its script argument.
        interpreter=str(Path(sys.executable).resolve())
        bridge.write_text(json.dumps({'author_uid':author_uid,'repo':'fixture/project',
            'worktrees':{'AA-1':str(author/'repo')},'command':[interpreter,'-I',str(adapter)],
            'env':{'HOME':str(author)}}));bridge.chmod(0o644)
        def author_setup():
            git(author/'repo','remote','set-url','origin','https://github.com/fixture/project.git')
            hook=author/'hostile-git-hook'
            hook.write_text('#!/bin/sh\n/usr/bin/id -u > '+str(author/'hook-uid')+'\nprintf "token\\000"\n');hook.chmod(0o755)
            git(author/'repo','config','core.fsmonitor',str(hook))
            return True
        run_as(author_uid,author_setup)
        def prepare_reviewer():
            (reviewer/'credential').write_text('synthetic-read-only-credential')
            git(reviewer/'repo','status','--porcelain')
            p=policy();p['isolation']={'author_uid':author_uid,'reviewer_uid':reviewer_uid,
                'bridge_policy':str(bridge),'author_worktrees':{'AA-1':str(author/'repo')}}
            p['read_path']=str(tools)+':/usr/bin'
            p['roles']['author']['env']={'HOME':str(author)}
            p['roles']['acceptance']['env']={'HOME':str(reviewer)}
            config=reviewer/'workers.json';config.write_text(json.dumps(p))
            p=w.load_policy(config,reviewer/'repo')
            s=snapshot(head=head,base_sha=head,commits=[head]);s['git_common_dir']=str(reviewer/'repo/.git')
            db=w.Journal(reviewer/'state')
            try:
                j=db.prepare(s,'author',author/'repo',p)
                assert db.prepare(s,'author',author/'repo',p)['id']==j['id']
                try:db.prepare(s,'acceptance',reviewer/'review-tree',p)
                except w.q.QueueError:pass
                else:raise AssertionError('overlapping role acquired PR')
                return w.packet(j)
            finally:db.close()
        packet=run_as(reviewer_uid,prepare_reviewer)
        def author_run():
            for path in (reviewer/'credential',reviewer/'state/workers.sqlite'):
                try:path.read_bytes()
                except PermissionError:pass
                else:raise AssertionError('author read reviewer private state')
            packet['guardian_pgid']=os.getpgrp()
            result=subprocess.run([interpreter,'-I',str(code/'review-workers.py'),'--policy',str(bridge),'author-bridge'],
                                  input=json.dumps(packet),capture_output=True,text=True,timeout=15)
            assert result.returncode==0,result.stderr
            receipt=json.loads(result.stdout)
            assert receipt['executed_uid']==author_uid and receipt['head']==head
            assert (author/'hook-uid').read_text().strip()==str(author_uid)
            return True
        assert run_as(author_uid,author_run)
        # A group contains a reviewer guardian and an author child. The reviewer can kill
        # itself but cannot kill the different-UID author. A fresh reviewer must retain ownership.
        start_rd,start_wr=os.pipe();ready_rd,ready_wr=os.pipe();guard=os.fork()
        if guard==0:
            os.close(start_wr);os.close(ready_rd);os.setpgid(0,0);drop(reviewer_uid)
            os.write(ready_wr,b'1');os.read(start_rd,1);os.killpg(os.getpgrp(),signal.SIGKILL);os._exit(9)
        children.add(guard);os.close(start_rd);os.close(ready_wr)
        assert select.select([ready_rd],[],[],5)[0];os.read(ready_rd,1);os.close(ready_rd)
        ready_rd,ready_wr=os.pipe();linger=os.fork()
        if linger==0:
            os.close(ready_rd);os.close(start_wr);os.setpgid(0,guard);drop(author_uid)
            os.write(ready_wr,b'1');os.close(ready_wr);time.sleep(60);os._exit(0)
        children.add(linger);os.close(ready_wr)
        assert select.select([ready_rd],[],[],5)[0];os.read(ready_rd,1);os.close(ready_rd)
        os.write(start_wr,b'1');os.close(start_wr);os.waitpid(guard,0);children.remove(guard)
        def hold():
            assert w.group_alive(guard)
            db=w.Journal(reviewer/'state')
            try:
                db.record(packet['result_schema']['job_id'],'failed',pgid=guard)
                try:w.reconcile(db,packet['result_schema']['job_id'],reviewer/'repo')
                except w.q.QueueError:pass
                else:raise AssertionError('released surviving author')
                assert db.get(packet['result_schema']['job_id'])['active']
            finally:db.close()
            return True
        assert run_as(reviewer_uid,hold)
        os.kill(linger,signal.SIGKILL);os.waitpid(linger,0);children.remove(linger)
        def release():
            db=w.Journal(reviewer/'state')
            try:return not w.reconcile(db,packet['result_schema']['job_id'],reviewer/'repo')['active']
            finally:db.close()
        assert run_as(reviewer_uid,release)
        return {'synthetic_identity_proof':'passed','author_uid':author_uid,'reviewer_uid':reviewer_uid,
                'author_git_hook_runs_only_as_author':True,'reviewer_git_metadata_separate':True,
                'author_denied_reviewer_credentials_and_journal':True,'duplicate_roles_blocked':True,
                'surviving_author_retains_job':True,'release_after_verified_stop':True,
                'github_calls':0,'model_calls':0,'services_started':False}
    finally:
        for pid in children:
            try:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
            try:os.waitpid(pid,0)
            except ChildProcessError:pass
        shutil.rmtree(root)


if __name__ == '__main__':
    if '--identity-proof' in sys.argv:
        import argparse
        parser=argparse.ArgumentParser()
        parser.add_argument('--identity-proof',action='store_true')
        parser.add_argument('--author-uid',type=int,required=True)
        parser.add_argument('--reviewer-uid',type=int,required=True)
        parser.add_argument('--proof-parent',required=True)
        args=parser.parse_args()
        print(json.dumps(identity_proof(args.author_uid,args.reviewer_uid,args.proof_parent),indent=2))
    else:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
