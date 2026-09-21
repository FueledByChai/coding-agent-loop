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
    def test_lost_check_creation_polls_without_reposting_or_releasing(self):
        for name in (c.GATE,c.ADMISSION):
            with self.subTest(name=name):
                self.db.close();self.tmp.cleanup();self.setUp()
                if name==c.ADMISSION:self.through_dispatch()
                live=c.Provider.__new__(c.Provider);live.policy={'app_id':10};live.journal=self.db
                created=[];visible=[False]
                live.pages=lambda *a,**kw:created if visible[0] else []
                def api(method,path,data):
                    if method=='POST':
                        key='gate_check_create_intent' if name==c.GATE else 'admission_check_create_intent'
                        self.assertEqual(data['external_id'],self.db.active()[key]['external_id'])
                        created.append(dict(data,id=91,app={'id':10}))
                        raise RuntimeError('response lost after accepted create')
                    return dict(created[0],**data)
                live.api=api
                original=self.p.check
                self.p.check=lambda a,n,*args,**kw:live.check(a,n,*args,**kw) if n==name else original(a,n,*args,**kw)
                with self.assertRaises(RuntimeError):self.step()
                self.runner=c.Controller(self.db,self.p,'policy1')
                for _ in range(3):self.step()
                self.assertEqual(1,len(created))
                self.assertEqual(1,self.db.active()['number'])
                visible[0]=True
                self.step()
                self.assertEqual(1,len(created))
                self.assertEqual([('dispatch',1)],[x for x in self.p.calls if x[0]=='dispatch'])

    def test_unknown_admission_creation_still_cancels_stale_run(self):
        self.through_dispatch()
        live=c.Provider.__new__(c.Provider);live.policy={'app_id':10};live.journal=self.db
        live.pages=lambda *a,**kw:[]
        live.api=mock.Mock(side_effect=RuntimeError('lost create'))
        original=self.p.check
        self.p.check=lambda a,n,*args,**kw:live.check(a,n,*args,**kw) if n==c.ADMISSION else original(a,n,*args,**kw)
        with self.assertRaises(RuntimeError):self.step()
        self.p.snapshots[1]['head']='d'*40
        self.step()
        self.assertEqual('blocked',self.db.active()['phase'])
        self.assertIn(('cancel',1),self.p.calls)
        self.assertEqual(1,live.api.call_count)
        self.assertIn('admission_check_create_intent',self.db.active())

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
    def test_successful_merge_waits_for_landed_reads_across_restart(self):
        self.through_admission(); self.p.runs[0].update(status='completed',conclusion='success')
        self.p.verify_merge=mock.Mock(side_effect=[False,False,True])
        self.step()
        self.assertEqual('merging',self.db.active()['phase'])
        self.runner=c.Controller(self.db,self.p,'policy1')
        self.step()
        self.assertEqual(1,self.db.active()['number'])
        self.assertEqual('merging',self.db.active()['phase'])
        result=self.step()
        self.assertIsNone(self.db.active())
        self.assertEqual(2,self.db.next_number())
        self.assertEqual('success',self.p.checks[c.GATE]['conclusion'])
        self.assertNotIn('reason',result)
        self.assertEqual([('merge',1)],[x for x in self.p.calls if x[0]=='merge'])
        self.assertEqual([('dispatch',1)],[x for x in self.p.calls if x[0]=='dispatch'])

    def test_delayed_merge_holds_lane_until_gate_repair_survives_restart(self):
        self.through_admission();self.p.runs[0].update(status='completed',conclusion='success')
        self.p.verify_merge=mock.Mock(side_effect=[False,False,True,True,True])
        self.step();self.step()
        self.assertEqual('failure',self.p.checks[c.GATE]['conclusion'])
        original=self.p.check
        def lost(a,name,status,conclusion=None,external=None):
            self.assertEqual('merging',self.db.active()['phase'])
            original(a,name,status,conclusion,external)
            raise RuntimeError('lost gate repair response')
        self.p.check=lost
        with self.assertRaises(RuntimeError):self.step()
        self.assertEqual(1,self.db.active()['number'])
        self.p.check=mock.Mock(side_effect=c.CheckPending('gate temporarily invisible'))
        self.runner=c.Controller(self.db,self.p,'policy1')
        self.step()
        self.assertEqual(1,self.db.active()['number'])
        self.assertIn('check_wait',self.db.active())
        self.p.check=original
        result=self.step()
        self.assertIsNone(self.db.active())
        self.assertEqual(2,self.db.next_number())
        self.assertEqual('success',self.p.checks[c.GATE]['conclusion'])
        self.assertNotIn('reason',result);self.assertNotIn('check_wait',result)
        self.assertEqual([('merge',1)],[x for x in self.p.calls if x[0]=='merge'])
        self.assertEqual([('dispatch',1)],[x for x in self.p.calls if x[0]=='dispatch'])

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
        check=dict(app={'id':10},name='Queue CI admission',status='in_progress',external_id=c.admission_id(expected))
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
    def test_privileged_launch_ignores_path_and_interpreter_startup_injection(self):
        import os,subprocess
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);marker=root/'executed-untrusted'
            payload='#!/bin/sh\nprintf injected > "$ATTACK_MARKER"\nexit 76\n'
            for name in ('bash','dirname','python3'):
                path=root/name;path.write_text(payload);path.chmod(0o755)
            startup=root/'startup';startup.write_text('printf startup > "$ATTACK_MARKER"\n')
            (root/'sitecustomize.py').write_text('import os;open(os.environ["ATTACK_MARKER"],"w").write("python startup")\n')
            env=dict(os.environ,PATH=str(root),BASH_ENV=str(startup),ENV=str(startup),
                     PYTHONPATH=str(root),ATTACK_MARKER=str(marker))
            wrapper=Path(__file__).with_name('queue-controller.sh').resolve()
            entry=wrapper.with_suffix('.py')
            for command in ([str(wrapper),'--help'],['/bin/bash','-p',str(wrapper),'--help'],[str(entry),'--help']):
                with self.subTest(command=command):
                    if marker.exists():marker.unlink()
                    result=subprocess.run(command,env=env,text=True,capture_output=True,timeout=10)
                    self.assertEqual(0,result.returncode,result.stderr)
                    self.assertIn('usage:',result.stdout)
                    self.assertFalse(marker.exists(),'untrusted startup code ran')

    def test_observation_rejects_unprotected_path_before_token_or_tools(self):
        p=c.Provider.__new__(c.Provider)
        p.policy={'read_path':'/trusted/bin:/foreign/bin','repo':'fixture/project','base':'trunk'}
        p.root=Path('/trusted/mirror');p.app=mock.Mock()
        def protect(path):
            if str(path)=='/foreign/bin':raise c.q.QueueError('foreign owner')
            return Path(path)
        with mock.patch.object(c,'protected_path',side_effect=protect),\
             mock.patch.object(c.subprocess,'run') as run,\
             mock.patch.object(c.w,'Observer') as observer:
            observer.return_value.snapshot.return_value=snapshot()
            with self.assertRaises(c.q.QueueError):p.observe(1)
            p.app.token.assert_not_called();run.assert_not_called();observer.assert_not_called()

    def test_observation_rejects_empty_relative_and_foreign_symlink_tools(self):
        p=c.Provider.__new__(c.Provider)
        p.root=Path('/trusted/mirror');p.app=mock.Mock()
        for value in ('/trusted/bin:',':/trusted/bin','bin:/trusted/bin','/trusted/bin'):
            p.policy={'read_path':value,'repo':'fixture/project','base':'trunk'}
            def protect(path):
                if Path(path).name in ('gh','bd'):raise c.q.QueueError('binary symlink target has foreign owner')
                return Path(path)
            with self.subTest(value=value),mock.patch.object(c,'protected_path',side_effect=protect),\
                 mock.patch.object(c.subprocess,'run') as run,mock.patch.object(c.w,'Observer') as observer,\
                 mock.patch('shutil.which',side_effect=lambda name,**kw:'/trusted/bin/'+name):
                observer.return_value.snapshot.return_value=snapshot()
                with self.assertRaises(c.q.QueueError):p.observe(1)
                p.app.token.assert_not_called();run.assert_not_called();observer.assert_not_called()

    def test_protected_observation_uses_canonical_path_and_bd_binary(self):
        p=c.Provider.__new__(c.Provider)
        p.root=Path('/trusted/mirror');p.app=mock.Mock()
        p.app.token.return_value='test-token'
        p.policy={'read_path':'/trusted/bin','repo':'fixture/project','base':'trunk'}
        paths=[]
        def protect(path):
            paths.append(str(path))
            return Path(str(path).replace('/trusted/','/canonical/'))
        with mock.patch.object(c,'protected_path',side_effect=protect),\
             mock.patch.object(c.subprocess,'run') as run,mock.patch.object(c.w,'Observer') as observer,\
             mock.patch('shutil.which',side_effect=lambda name,**kw:'/canonical/bin/'+name):
            observer.return_value.snapshot.return_value=snapshot()
            self.assertEqual(snapshot(),p.observe(1))
            self.assertIn('/canonical/bin/gh',paths);self.assertIn('/canonical/bin/bd',paths)
            self.assertEqual('/canonical/bin/bd',run.call_args.args[0][0])
            self.assertEqual('/canonical/bin',observer.call_args.args[1]['PATH'])
            self.assertNotIn('GH_TOKEN',run.call_args.kwargs['env'])
            reader=observer.call_args.kwargs['ticket_reader']
            run.return_value.stdout=json.dumps([{'id':'AA-1'}])
            self.assertEqual({'id':'AA-1'},reader('AA-1'))
            self.assertEqual(['/canonical/bin/bd','show','AA-1','--json','--readonly'],run.call_args.args[0])
            self.assertEqual('/canonical/bin',run.call_args.kwargs['env']['PATH'])
            self.assertNotIn('GH_TOKEN',run.call_args.kwargs['env'])

    def test_private_configuration_rejects_foreign_owned_ancestors(self):
        path=Path('/protected/foreign/policy.json')
        def stat(p,**kw):
            return mock.Mock(st_uid=999999 if str(p)=='/protected/foreign' else c.os.getuid(),
                             st_mode=0o755 if p!=path else 0o600)
        with mock.patch.object(Path,'resolve',lambda p:p),mock.patch.object(Path,'is_file',return_value=True),\
             mock.patch.object(Path,'stat',stat):
            with self.assertRaises(c.q.QueueError):c.secure_file(path)

    def test_protected_wrapper_rejects_environment_code_injection(self):
        p=c.Provider.__new__(c.Provider)
        for name in ('BASH_ENV','ENV','PYTHONPATH','LD_PRELOAD','RUBYOPT'):
            p.policy={'refresh':{'command':['/trusted/wrapper'],'env':{name:'/author/code'},'timeout':10}}
            executable=mock.Mock()
            executable.is_absolute.return_value=True
            executable.stat.return_value=mock.Mock(st_uid=c.os.getuid(),st_mode=0o755)
            with self.subTest(name=name),mock.patch.object(c,'protected_path',return_value=executable),\
                 mock.patch.object(c.subprocess,'run',return_value=mock.Mock(stdout='{}')) as run:
                with self.assertRaises(c.q.QueueError):p.command('refresh',{})
                run.assert_not_called()

    def test_adapter_interpreter_arguments_cannot_select_unprotected_code(self):
        p=c.Provider.__new__(c.Provider)
        for command in (['/usr/bin/python3','/author/adapter.py'],['/bin/bash','-c','untrusted'],
                        ['/usr/bin/env','PATH=/author/bin','adapter']):
            p.policy={'refresh':{'command':command,'env':{},'timeout':10}}
            executable=mock.Mock()
            executable.is_absolute.return_value=True
            executable.stat.return_value=mock.Mock(st_uid=c.os.getuid(),st_mode=0o755)
            with self.subTest(command=command),mock.patch.object(c,'protected_path',return_value=executable),\
                 mock.patch.object(c.subprocess,'run',return_value=mock.Mock(stdout='{}')) as run:
                with self.assertRaises(c.q.QueueError):p.command('refresh',{})
                run.assert_not_called()

    def test_relative_adapter_is_rejected_before_execution(self):
        p=c.Provider.__new__(c.Provider)
        p.policy={'refresh':{'command':['tmp/refresh'],'env':{},'timeout':10}}
        executable=mock.Mock()
        executable.is_absolute.return_value=True
        executable.stat.return_value=mock.Mock(st_uid=c.os.getuid(),st_mode=0o755)
        with mock.patch.object(c,'protected_path',return_value=executable),\
             mock.patch.object(c.subprocess,'run',return_value=mock.Mock(stdout='{}')) as run:
            with self.assertRaises(c.q.QueueError):p.command('refresh',{})
            run.assert_not_called()

    def test_preflight_binds_workflow_id_to_pinned_path_and_active_state(self):
        p=c.Provider.__new__(c.Provider)
        p.policy=dict(ruleset_ids=[],workflow_id=17,workflow_path='.github/workflows/queue.yml',
                      workflow_sha256=c.q.hashlib.sha256(b'pinned').hexdigest(),base='trunk')
        workflow=dict(id=17,path=p.policy['workflow_path'],state='active')
        def api(method,path):
            if path=='':return {'allow_auto_merge':False}
            if path.startswith('/actions/workflows/'):return workflow
            if path.startswith('/contents/'):return {'content':c.base64.b64encode(b'pinned').decode()}
            raise AssertionError(path)
        p.api=api
        with mock.patch.object(c,'validate_rules'):
            self.assertTrue(p.protections())
            for field,value in [('id',18),('path','.github/workflows/unrelated.yml'),('state','disabled_manually')]:
                original=workflow[field];workflow[field]=value
                with self.subTest(field=field),self.assertRaises(c.q.QueueError):p.protections()
                workflow[field]=original

    def test_admission_external_id_is_bounded_and_binds_long_repository(self):
        p=c.Provider.__new__(c.Provider);p.policy={'app_id':123456789};p.journal=mock.Mock()
        s=snapshot();s['repository']='o'*39+'/'+('r'*100)
        a=dict(id='a'*32,snapshot=s,run_id=123456789012)
        p.pages=mock.Mock(return_value=[])
        p.api=mock.Mock(return_value={'id':91})
        p.check(a,c.ADMISSION,'in_progress')
        payload=p.api.call_args.args[2]
        self.assertLessEqual(len(payload['external_id']),255)
        check=dict(payload,app={'id':p.policy['app_id']})
        expected=c.admission_identity(a,p)
        self.assertTrue(c.admitted([check],expected,1))
        self.assertFalse(c.admitted([check],dict(expected,repository='other/project'),1))

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
                 GITHUB_SHA='c'*40,GITHUB_REPOSITORY='o'*39+'/'+('r'*100),GITHUB_RUN_ID='8',GH_TOKEN='fixture')
        identity=dict(repository=env['GITHUB_REPOSITORY'],app_id=10,attempt='a'*32,head='b'*40,base_sha='c'*40,run_id=8)
        check=dict(name=c.ADMISSION,app={'id':10},status='in_progress',external_id=c.admission_id(identity))
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
        p=c.Provider.__new__(c.Provider);p.policy={'app_id':10};p.journal=mock.Mock()
        a=dict(id='nonce',snapshot=snapshot(),run_id=8)
        external=c.admission_id(c.admission_identity(a,p))
        check=dict(id=91,name=c.ADMISSION,app={'id':10},external_id=external)
        p.pages=mock.Mock(return_value=[check]);p.api=mock.Mock(return_value=check)
        p.check(a,c.ADMISSION,'in_progress',external=c.admission_identity(a,p))
        self.assertEqual(('PATCH','/check-runs/91'),p.api.call_args.args[:2])
        p.api.reset_mock();p.pages.return_value=[]
        with self.assertRaises(c.CheckPending):p.check(a,c.ADMISSION,'completed','failure')
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

class WorkerReceiptTests(unittest.TestCase):
    def setUp(self):
        # Protected ancestors are part of the real launcher boundary; /tmp is writable
        # by other identities on Linux, so use a private directory below this test UID.
        self.temp=tempfile.TemporaryDirectory(prefix='.queue-receipt-test-',dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()
        self.repo=self.root/'mirror';self.repo.mkdir()
        c.subprocess.run(['/usr/bin/git','init','-q',str(self.repo)],check=True)
        self.bin=self.root/'tools';self.bin.mkdir()
        self.tool_alias=self.root/'tool-alias';self.tool_alias.symlink_to(self.bin,target_is_directory=True)
        self.log=self.root/'tools.jsonl'
        self.policy=dict(revision='receipt-test',timeout=30,max_attempts=1,
                         read_path=str(self.tool_alias)+':/usr/bin:/bin',
                         roles={role:dict(identity=role,github_login='author',command=['/usr/bin/true'],
                                env={'HOME':str(self.root/role)}) for role in ('author','acceptance')})
        for role in self.policy['roles']: (self.root/role).mkdir()
        self.policy_file=self.root/'policy.json'
        self.policy_file.write_text(json.dumps(self.policy))
        self.ticket=dict(id='AA-1',status='in_progress',assignee='author',description='intent',
                         acceptance_criteria='Prove the fixture',labels=['sprint'],dependencies=[])
        path='repos/fixture/project/pulls/1'
        self.responses={path:dict(state='open',draft=False,merged=False,node_id='fixture',body='body',
            head=dict(ref='ticket/AA-1',sha='1'*40,repo={'full_name':'fixture/project'}),
            base={'ref':'trunk'},user={'login':'author'}),
            'repos/fixture/project/commits/trunk':{'sha':'b'*40},
            path+'/commits?per_page=100':[[dict(sha='1'*40,commit={'message':'AA-1: fixture'})]],
            path+'/reviews?per_page=100':[[dict(id=1,body='',state='COMMENTED',commit_id='1'*40,
                submitted_at='2026-01-01T00:00:00Z',user={'login':c.q.REVIEWER})]],
            path+'/comments?per_page=100':[[]],
            'repos/fixture/project/issues/1/comments?per_page=100':[[]]}
        record=('import json,os,sys\nfrom pathlib import Path\n'
                'with Path('+repr(str(self.log))+').open("a") as log:\n'
                ' log.write(json.dumps({"tool":Path(sys.argv[0]).name,"args":sys.argv[1:],'
                '"env":dict(os.environ)})+"\\n")\n')
        self.write_tool('bd',record+'print(json.dumps('+repr([self.ticket])+'))\n')
        self.write_tool('gh',record+'responses='+repr(self.responses)+'\n'
            'if sys.argv[1]=="repo": result={"nameWithOwner":"fixture/project"}\n'
            'elif sys.argv[2]=="graphql": result={"data":{"node":{"reviewThreads":'
            '{"pageInfo":{"hasNextPage":False,"endCursor":None},"nodes":[]}}}}\n'
            'else: result=responses[sys.argv[4]]\nprint(json.dumps(result))\n')
        env={'PATH':self.policy['read_path'],'HOME':str(self.root/'acceptance')}
        reader=lambda ticket:c.q.read_ticket(self.repo,ticket,env=env,executable=str(self.bin/'bd'))
        self.snapshot=c.w.Observer(self.repo,env,ticket_reader=reader).snapshot('fixture/project',1)
        self.state=self.root/'state'
        db=c.w.Journal(self.state)
        try:
            job=db.prepare(self.snapshot,'acceptance',self.repo,self.policy)
            receipt=dict(job_id=job['id'],head=self.snapshot['head'],criteria_hash=self.snapshot['criteria_hash'],
                         policy_hash=job['policy_hash'],outcome='pass',criteria=[{'id':'c1','evidence':'fixture proof'}])
            db.record(job['id'],'finished',receipt);db.release(job['id'],'fixture worker stopped')
        finally:db.close()
        self.packet=json.dumps({'snapshot':self.snapshot,'binding':c.q.digest(c.w.binding(self.snapshot))})
        self.wrapper=Path(__file__).with_name('queue-controller.sh').resolve()

    def write_tool(self,name,body):
        tool=self.bin/name
        tool.write_text('#!/usr/bin/python3 -I\n'+body);tool.chmod(0o700)

    def invoke(self,entry):
        self.log.unlink(missing_ok=True)
        return c.subprocess.run([str(entry),'--root',str(self.repo),'--state',str(self.state),
            '--policy',str(self.policy_file),'worker-receipt'],input=self.packet,text=True,capture_output=True,
            env={'PATH':'/usr/bin:/bin','HOME':str(self.root/'author'),
                 'GH_TOKEN':'untrusted-inherited-token','PYTHONPATH':'/untrusted'},timeout=30)

    def test_receipt_uses_protected_tools_for_both_observations_through_each_entry(self):
        for entry in (self.wrapper,self.wrapper.with_suffix('.py')):
            with self.subTest(entry=entry):
                result=self.invoke(entry)
                self.assertEqual(0,result.returncode,result.stderr)
                self.assertEqual('pass',json.loads(result.stdout)['outcome'])
                calls=[json.loads(line) for line in self.log.read_text().splitlines()]
                bd=[call for call in calls if call['tool']=='bd']
                self.assertEqual(['dolt','pull'],bd[0]['args'])
                self.assertEqual(6,len([call for call in bd if call['args'][0]=='show']))
                self.assertEqual(2,len([call for call in calls if call['args'][0]=='repo']))
                expected_path=c.os.pathsep.join(str(Path(p).resolve()) for p in
                                               self.policy['read_path'].split(c.os.pathsep))
                for call in calls:
                    self.assertEqual(str(self.root/'acceptance'),call['env']['HOME'])
                    self.assertEqual(expected_path,call['env']['PATH'])
                    for name in ('GH_TOKEN','GITHUB_TOKEN','PYTHONPATH'):
                        self.assertNotIn(name,call['env'])

    def test_receipt_rejects_missing_relative_or_writable_path_before_execution(self):
        for path in (None,'relative:/usr/bin:/bin',str(self.bin)+':/usr/bin:/bin'):
            with self.subTest(path=path):
                self.policy['read_path']=path;self.policy_file.write_text(json.dumps(self.policy))
                self.bin.chmod(0o777 if path and path.startswith(str(self.bin)) else 0o700)
                try:
                    result=self.invoke(self.wrapper)
                    self.assertNotEqual(0,result.returncode)
                    if path is None:self.assertIn('protected read_path required',result.stderr)
                    else:self.assertTrue('absolute' in result.stderr or 'protected' in result.stderr,result.stderr)
                    self.assertFalse(self.log.exists())
                finally:self.bin.chmod(0o700)

if __name__=='__main__': unittest.main(argv=[sys.argv[0]])
