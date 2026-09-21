#!/usr/bin/env python3
"""Offline admission, provider and recovery fixtures; no live credentials."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('controller', Path(__file__).with_name('queue-controller.py'))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def snapshot(n=1):
    return dict(repository='fixture/project', number=n, head=str(n)*40, base='trunk', base_sha='b'*40,
        branch='ticket/AA-'+str(n), ticket='AA-'+str(n), criteria_hash='c'*64, intent='intent', pr_body='body',
        review_evidence='review:1', threads=[], comments=[], reviews=[], assignee='author',
        ticket_metadata={'labels':['sprint'], 'dependencies':[]}, changes_requested=False)


class Provider:
    def __init__(self):
        self.snapshots = {n:snapshot(n) for n in (1,2,3)}
        self.calls = []
        self.runs = []
        self.checks = {}
        self.proof = True
        self.landed = False
        self.on_dispatch = None
    def observe(self, n): return json.loads(json.dumps(self.snapshots[n]))
    def ready(self, s): return True
    def acceptance(self, s):
        if not self.proof: raise c.q.QueueError('acceptance unavailable')
        return {'job':'independent-1','binding':c.q.digest(c.w.binding(s))}
    def refresh(self, a):
        self.calls.append(('refresh',a['number']))
        return {'stopped':True,'head':a['snapshot']['head']}
    def check(self, a, name, status, conclusion=None, external=None):
        self.calls.append(('check',name,status,conclusion))
        self.checks[name] = dict(status=status,conclusion=conclusion,external=external)
        return 7
    def dispatch(self, a):
        self.calls.append(('dispatch',a['number']))
        self.runs.append(dict(id=8,run_attempt=1,status='in_progress',conclusion=None))
        if self.on_dispatch: self.on_dispatch()
    def find_runs(self, a): return self.runs
    def ci_success(self, a, run): return run['status']=='completed' and run['conclusion']=='success'
    def cancel(self, a): self.calls.append(('cancel',a['number']))
    def stopped(self, a): return all(r['status']=='completed' for r in self.runs)
    def merge(self, a): self.calls.append(('merge',a['number'])); self.landed=True
    def verify_merge(self,a): return self.landed
    def protections(self): return True


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.db=c.Journal(Path(self.tmp.name)/'state')
        self.p=Provider()
        self.runner=c.Controller(self.db,self.p,'policy1')
        for n in (1,2,3): self.db.enqueue(n)
    def tearDown(self): self.db.close(); self.tmp.cleanup()
    def step(self): return self.runner.tick()
    def through_dispatch(self):
        for _ in range(5):
            a=self.step()
            if a['phase']=='dispatching': return a
        self.fail('not dispatched')
    def through_admission(self):
        self.through_dispatch(); return self.step()
    def test_retired_request_can_be_explicitly_requeued_at_the_tail(self):
        self.db.retire_request(1,'draft while waiting')
        self.db.enqueue(1)
        self.assertEqual([2,3,1],[r['number'] for r in self.db.requests()])
        self.db.enqueue(2)
        self.assertEqual([2,3,1],[r['number'] for r in self.db.requests()])

    def test_invalid_waiting_request_can_be_retired_without_touching_an_active_one(self):
        original=self.p.observe
        def observe(n):
            if n==1:raise c.q.QueueError('PR closed while waiting')
            return original(n)
        self.p.observe=observe
        with self.assertRaises(c.q.QueueError):self.step()
        self.assertIsNone(self.db.active())
        self.db.retire_request(1,'PR closed while waiting')
        a=self.step()
        self.assertEqual(2,a['number'])
        with self.assertRaises(c.q.QueueError):self.db.retire_request(2,'must not steal active work')
        self.assertEqual(2,self.db.active()['number'])
        self.assertFalse(any(x[:2] in (('dispatch',1),('refresh',1)) for x in self.p.calls))
        self.assertTrue(any('retire-request' in row[0] for row in self.db.db.execute('SELECT detail FROM events')))

    def test_unknown_mergeability_waits_without_refresh_or_dispatch(self):
        self.p.ready=lambda s:None
        for _ in range(3):self.step()
        self.assertEqual('selected',self.db.active()['phase'])
        self.assertFalse(any(x[0] in ('refresh','dispatch','merge') for x in self.p.calls))

    def test_unknown_mergeability_after_admission_keeps_polling(self):
        self.through_admission()
        self.p.ready=lambda s:None
        self.step()
        self.assertEqual('running',self.db.active()['phase'])
        self.assertFalse(any(x[0] in ('cancel','merge') for x in self.p.calls))

    def test_lane_schema_forbids_a_second_binding(self):
        self.db.bind('fixture/project','trunk')
        with self.assertRaises(c.sqlite3.IntegrityError):
            self.db.db.execute('INSERT INTO lane(binding) VALUES (?)',('["other/project","trunk"]',))
        self.assertEqual(1,self.db.db.execute('SELECT count(*) FROM lane').fetchone()[0])

    def test_two_initial_binders_have_exactly_one_owner(self):
        import threading
        barrier=threading.Barrier(2)
        results=[]
        def bind(repo):
            db=c.Journal(self.db.state)
            try:
                barrier.wait(timeout=5)
                try:db.bind(repo,'trunk');results.append(('bound',repo))
                except c.q.QueueError:results.append(('refused',repo))
            finally:db.close()
        threads=[threading.Thread(target=bind,args=(r,)) for r in ('fixture/one','fixture/two')]
        for t in threads:t.start()
        for t in threads:t.join(timeout=10)
        self.assertFalse(any(t.is_alive() for t in threads))
        self.assertEqual(1,len([r for r in results if r[0]=='bound']))
        self.assertEqual(1,self.db.db.execute('SELECT count(*) FROM lane').fetchone()[0])

    def test_refresh_only_selected_and_lost_response_holds_even_if_current(self):
        self.p.ready=lambda s:False
        self.p.refresh=mock.Mock(side_effect=RuntimeError('lost response'))
        with self.assertRaises(RuntimeError):self.step()
        self.p.ready=lambda s:True
        for _ in range(3):self.step()
        self.assertEqual('refreshing',self.db.active()['phase'])
        self.p.refresh.assert_called_once()
        self.assertEqual(1,self.p.refresh.call_args.args[0]['number'])
        self.assertFalse(any(x[0]=='dispatch' for x in self.p.calls))

    def test_three_prs_one_slot_and_unchanged_run_reuse(self):
        a=self.through_admission()
        for _ in range(5): self.step()
        self.assertEqual([('dispatch',1)],[x for x in self.p.calls if x[0]=='dispatch'])
        self.assertFalse(any(x[0]=='refresh' and x[1]!=1 for x in self.p.calls))
        self.p.runs[0].update(status='completed',conclusion='success')
        self.step()
        self.assertIn(('merge',1),self.p.calls)
        self.assertEqual(2,self.db.next_number())
    def test_dispatch_crash_never_resends_or_steals(self):
        def crash(): raise RuntimeError('connection lost after write')
        self.p.on_dispatch=crash
        with self.assertRaises(RuntimeError): self.through_dispatch()
        self.runner=c.Controller(self.db,self.p,'policy1')
        self.step(); self.step()
        self.assertEqual(1,len([x for x in self.p.calls if x[0]=='dispatch']))
        self.assertEqual(1,self.db.active()['number'])
    def test_unknown_dispatch_holds_lane_indefinitely(self):
        self.through_dispatch(); self.p.runs=[]
        for _ in range(5): self.step()
        self.assertEqual('dispatching',self.db.active()['phase'])
        self.assertEqual(1,len([x for x in self.p.calls if x[0]=='dispatch']))
    def test_duplicate_runs_fail_closed(self):
        self.through_dispatch(); self.p.runs.append(dict(self.p.runs[0],id=9))
        self.step()
        self.assertEqual('blocked',self.db.active()['phase'])
        self.assertFalse(any(x[:3]==('check','Queue CI admission','in_progress') for x in self.p.calls))
    def test_changed_evidence_revokes_gate_and_holds_until_stop(self):
        for field,value in [('head','d'*40),('base_sha','e'*40),('review_evidence',None),
                            ('threads',[{'resolved':False}]),('pr_body','changed'),
                            ('ticket_metadata',{'labels':['changed'],'dependencies':[]})]:
            with self.subTest(field=field):
                self.db.close(); self.tmp.cleanup(); self.setUp()
                original=dict(self.p.snapshots[1]); self.p.snapshots[1][field]=value
                # Each fresh fixture starts a candidate before applying this mutation.
                self.p.snapshots[1]=original
                if not self.db.active(): self.through_admission()
                self.p.snapshots[1][field]=value
                self.step()
                self.assertEqual('blocked',self.db.active()['phase'])
                self.assertFalse(any(x[0]=='merge' for x in self.p.calls))
                self.p.snapshots[1]=original
    def test_no_review_or_acceptance_cannot_spend_ci(self):
        self.p.proof=False
        for _ in range(3): self.step()
        self.assertFalse(any(x[0]=='dispatch' for x in self.p.calls))
    def test_non_success_ci_never_publishes_green(self):
        self.through_admission(); self.p.runs[0].update(status='completed',conclusion='skipped')
        self.step()
        self.assertEqual('blocked',self.db.active()['phase'])
        self.assertFalse(any(x[0]=='merge' for x in self.p.calls))
    def test_merge_crash_reconciles_landed_state_without_resending(self):
        self.through_admission(); self.p.runs[0].update(status='completed',conclusion='success')
        original=self.p.merge
        def crash(a): original(a); raise RuntimeError('lost merge response')
        self.p.merge=crash
        with self.assertRaises(RuntimeError):
            for _ in range(3): self.step()
        self.step()
        self.assertIsNone(self.db.active())
        self.assertEqual(1,len([x for x in self.p.calls if x[0]=='merge']))
    def test_policy_change_invalidates_attempt(self):
        self.through_admission()
        c.Controller(self.db,self.p,'policy2').tick()
        self.assertEqual('blocked',self.db.active()['phase'])
    def test_journal_cannot_replace_another_active_attempt(self):
        self.through_dispatch()
        existing=self.db.active()
        with self.assertRaises(c.sqlite3.IntegrityError):
            self.db.save(dict(existing,id='other-owner'))
        self.assertEqual(existing,self.db.active())

    def test_independent_controller_lock_cannot_overlap(self):
        with self.db.lock():
            other=c.Journal(self.db.state)
            try:
                with self.assertRaises(c.q.QueueError):
                    with other.lock(): pass
            finally: other.close()
    def test_admission_run_identity_and_rerun_refusal(self):
        expected=dict(repository='fixture/project',app_id=10,attempt='nonce',head='a'*40,base_sha='b'*40,run_id=8)
        check=dict(app={'id':10},name='Queue CI admission',status='in_progress',external_id=json.dumps(expected))
        self.assertTrue(c.admitted([check],expected,1))
        for field,value in [('app_id',11),('head','c'*40),('base_sha','c'*40),('run_id',9),('attempt','other')]:
            with self.subTest(field=field): self.assertFalse(c.admitted([check],dict(expected,**{field:value}),1))
        self.assertFalse(c.admitted([check],expected,2))
        check['status']='completed'; check['conclusion']='success'
        self.assertFalse(c.admitted([check],expected,1))
    def test_run_filter_rejects_manual_actor_wrong_workflow_or_base(self):
        a=dict(id='nonce',snapshot=snapshot())
        p=dict(repo='fixture/project',base='trunk',workflow_id=17,app_actor_id=20)
        r=dict(display_title='queue:nonce',event='workflow_dispatch',head_sha='b'*40,head_branch='trunk',
               workflow_id=17,actor={'id':20},triggering_actor={'id':20},run_attempt=1)
        self.assertTrue(c.run_matches(r,a,p))
        for field,value in [('actor',{'id':21}),('triggering_actor',{'id':21}),('head_sha','a'*40),
                            ('event','push'),('workflow_id',18),('run_attempt',2),('display_title','queue:other')]:
            self.assertFalse(c.run_matches(dict(r,**{field:value}),a,p))


class ProtocolTests(unittest.TestCase):
    def test_actual_workflow_gate_rejects_forged_identity_before_checkout(self):
        import io, os, re
        root=Path(__file__).resolve().parent.parent
        path=root/'templates/ci/queue-controller.yml'
        if not path.exists():path=root/'loop/templates/ci/queue-controller.yml'
        text=path.read_text()
        code=text.split("          python3 - <<'PY'\n",1)[1].split('          PY',1)[0]
        code='\n'.join(line[10:] for line in code.splitlines())
        self.assertLess(text.index('name: Queue admission'),text.index('uses: actions/checkout'))
        self.assertNotIn('pull_request:',text)
        self.assertNotIn('continue-on-error:',text)
        self.assertIn('persist-credentials: false',text)
        env=dict(GITHUB_EVENT_NAME='workflow_dispatch',GITHUB_RUN_ATTEMPT='1',QUEUE_APP_ID='10',
                 QUEUE_REQUEST_APP='10',QUEUE_ATTEMPT='a'*32,QUEUE_HEAD='b'*40,QUEUE_BASE='c'*40,
                 GITHUB_SHA='c'*40,GITHUB_REPOSITORY='fixture/project',GITHUB_RUN_ID='8',GH_TOKEN='fixture')
        identity=dict(repository='fixture/project',app_id=10,attempt='a'*32,head='b'*40,base_sha='c'*40,run_id=8)
        check=dict(name=c.ADMISSION,app={'id':10},status='in_progress',external_id=json.dumps(identity))
        def response():return io.StringIO(json.dumps({'check_runs':[check]}))
        with mock.patch('urllib.request.urlopen',side_effect=lambda *a,**kw:response()),mock.patch('time.sleep'):
            with mock.patch.dict(os.environ,env,clear=True):exec(code,{})
            for key,value in [('QUEUE_REQUEST_APP','11'),('GITHUB_RUN_ATTEMPT','2'),('QUEUE_BASE','d'*40),
                              ('QUEUE_ATTEMPT','bad'),('QUEUE_HEAD','$(bad)'),('GITHUB_RUN_ID','9')]:
                with self.subTest(key=key),mock.patch.dict(os.environ,dict(env,**{key:value}),clear=True):
                    with self.assertRaises((AssertionError,SystemExit)):exec(code,{})
            check['status']='completed';check['conclusion']='success'
            with mock.patch.dict(os.environ,env,clear=True),self.assertRaises(SystemExit):exec(code,{})

    def test_live_check_reconciles_lost_create_response(self):
        p=c.Provider.__new__(c.Provider);p.policy={'app_id':10}
        a=dict(id='nonce',snapshot=snapshot(),run_id=8)
        external=c.q.encoded(c.admission_identity(a,p))
        check=dict(id=91,name=c.ADMISSION,app={'id':10},external_id=external)
        p.pages=mock.Mock(return_value=[check]);p.api=mock.Mock(return_value=check)
        p.check(a,c.ADMISSION,'in_progress',external=c.admission_identity(a,p))
        self.assertEqual(('PATCH','/check-runs/91'),p.api.call_args.args[:2])
        p.api.reset_mock();p.pages.return_value=[]
        p.check(a,c.ADMISSION,'completed','failure')
        p.api.assert_not_called()

    def test_dependency_proof_stops_once_all_commits_are_found(self):
        p=c.Provider.__new__(c.Provider)
        s=snapshot();s['ticket_metadata']['dependencies']=[{'id':'AA-0','dependency_type':'blocks','status':'closed'}]
        calls=[]
        def api(method,path):
            calls.append(path)
            if path.startswith('/pulls/'):
                return dict(auto_merge=None,head={'sha':s['head']},base={'ref':s['base']},mergeable=True)
            if path.startswith('/compare/'):
                return {'merge_base_commit':{'sha':s['base_sha']}}
            # A large repository; the naming commit is already on its first page.
            return [{'sha':str(len(calls))+'-'+str(n),'commit':{'message':('AA-0: shipped' if n==0 else '' if n==1 else 'older')}} for n in range(100)]
        p.api=api
        self.assertTrue(p.ready(s))
        self.assertEqual(1,len([path for path in calls if path.startswith('/commits?')]))

    def test_pagination_reads_beyond_old_ceiling_and_detects_cycles(self):
        p=c.Provider.__new__(c.Provider)
        count=[0]
        def api(method,path):
            count[0]+=1
            return [{'id':count[0]*100+n} for n in range(100)] if count[0]<=101 else []
        p.api=api
        self.assertEqual(10100,len(p.pages('/inventory')))
        p.api=lambda *args:[{'id':n} for n in range(100)]
        with self.assertRaises(c.q.QueueError):p.pages('/inventory')

    def test_run_discovery_is_bounded_by_attempt_time_and_base(self):
        p=c.Provider.__new__(c.Provider)
        p.policy={'workflow_id':17,'base':'trunk','app_actor_id':20}
        a=dict(id='nonce',snapshot=snapshot(),dispatch_started_at=1800000000)
        p.pages=mock.Mock(return_value=[])
        self.assertEqual([],p.find_runs(a))
        query=p.pages.call_args.args[0]
        self.assertIn('created=',query)
        self.assertIn('head_sha='+a['snapshot']['base_sha'],query)
        self.assertIn(c.quote('>='+c.dispatch_boundary(a),safe=''),query)

    def test_provider_distinguishes_unknown_from_proven_stale(self):
        p=c.Provider.__new__(c.Provider)
        s=snapshot()
        pr=dict(auto_merge=None,head={'sha':s['head']},base={'ref':s['base']},mergeable=None)
        comparison={'merge_base_commit':{'sha':s['base_sha']}}
        p.api=lambda method,path:pr if path.startswith('/pulls/') else comparison
        self.assertIsNone(p.ready(s))
        pr['mergeable']=True;self.assertIs(p.ready(s),True)
        comparison['merge_base_commit']['sha']='c'*40
        self.assertIs(p.ready(s),False)

    def test_live_ci_evidence_requires_real_full_step(self):
        p=c.Provider.__new__(c.Provider);p.policy={'ci_job':'Queue full check'}
        job=dict(name='Queue full check',conclusion='success',steps=[
            dict(name=n,status='completed',conclusion='success') for n in ('Queue admission','Full check')])
        p.pages=mock.Mock(return_value=[job])
        run=dict(id=8,status='completed',conclusion='success')
        self.assertTrue(p.ci_success({},run))
        for outcome in ('skipped','neutral','failure','cancelled'):
            job['steps'][1]['conclusion']=outcome
            self.assertFalse(p.ci_success({},run))

    def test_rules_separate_exclusive_update_from_unbypassable_protections(self):
        p=dict(app_id=10,base='trunk')
        common=dict(enforcement='active',target='branch',conditions={'ref_name':{'include':['refs/heads/trunk'],'exclude':[]}})
        protection=dict(common,bypass_actors=[],rules=[{'type':'deletion'},{'type':'non_fast_forward'},
            {'type':'pull_request','parameters':{'required_review_thread_resolution':True,'allowed_merge_methods':['rebase']}},
            {'type':'required_status_checks','parameters':{'strict_required_status_checks_policy':True,
             'required_status_checks':[{'context':c.GATE,'integration_id':10}]}}])
        update=dict(common,bypass_actors=[{'actor_id':10,'actor_type':'Integration','bypass_mode':'always'}],rules=[{'type':'update'}])
        c.validate_rules([protection,update],p)
        for mutate in (lambda r:r[0].update(bypass_actors=update['bypass_actors']),
                       lambda r:r[1]['bypass_actors'][0].update(actor_id=11),
                       lambda r:r[0]['rules'][-1]['parameters'].update(strict_required_status_checks_policy=False),
                       lambda r:r[0]['rules'][-1]['parameters']['required_status_checks'][0].update(integration_id=11),
                       lambda r:r[0]['rules'][-2]['parameters'].update(required_review_thread_resolution=False)):
            rules=json.loads(json.dumps([protection,update]));mutate(rules)
            with self.assertRaises(c.q.QueueError):c.validate_rules(rules,p)

if __name__=='__main__': unittest.main(argv=[sys.argv[0]])
