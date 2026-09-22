#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('handoff',Path(__file__).with_name('queue-handoff.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
c=h.c
spec=importlib.util.spec_from_file_location('fixtures',Path(__file__).with_name('queue-controller-tests.py'))
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
f.c=c


class HandoffTests(unittest.TestCase):
    def test_uid_types_cannot_defeat_controller_identity_separation(self):
        adapter=dict(command=['/protected/adapter'],timeout=60,env={'PATH':'/usr/bin:/bin'})
        p=dict(repo='fixture/project',base='trunk',app_id=10,installation_id=11,app_actor_id=12,
               workflow_id=13,author_uid=502,reviewer_uid=601,acceptance=adapter,refresh=adapter,
               nominator_ids=[42],acceptance_actor_ids=[42],shared_account_workflow_trust=True)
        source=mock.Mock()
        with mock.patch.object(c,'secure_file',return_value=source),mock.patch.object(c.os,'getuid',return_value=600):
            for mode in ('workers','github-v1'):
                p['handoff']=mode
                source.read_text.side_effect=lambda:c.q.encoded(p)
                c.load_policy(Path('/not-read'))
                for invalid in (True,None,'admin','WRITE',{},[]):
                    p['ruleset_administration']=invalid
                    with self.subTest(mode=mode,administration=invalid),self.assertRaises(c.q.QueueError):
                        c.load_policy(Path('/not-read'))
                for valid in ('read','write'):
                    p['ruleset_administration']=valid
                    c.load_policy(Path('/not-read'))
                p.pop('ruleset_administration')
                for field in (('author_uid','reviewer_uid') if mode=='workers' else ('author_uid',)):
                    original=p[field]
                    for invalid in ('600','502',600.0,502.0,True,False,None,0,-1):
                        p[field]=invalid
                        with self.subTest(mode=mode,field=field,value=invalid),self.assertRaises(c.q.QueueError):
                            c.load_policy(Path('/not-read'))
                    p[field]=original
                p['author_uid']=600
                with self.assertRaises(c.q.QueueError):c.load_policy(Path('/not-read'))
                p['author_uid']=502

    def setUp(self):
        self.s=f.snapshot()
        self.s['reviews']=[dict(id=99,body='Independent assessment: all criteria met',state='COMMENTED',commit_id=self.s['head'])]
        self.url='https://github.com/fixture/project/pull/1#pullrequestreview-99'
        self.status=dict(id=7,context=c.ACCEPTANCE,state='success',creator={'id':42},
            target_url=self.url,description='queue-acceptance-v1:'+c.q.digest(c.w.binding(self.s)))
        self.p=c.Provider.__new__(c.Provider)
        self.p.policy={'handoff':'github-v1','acceptance_actor_ids':[42]}
        self.p.pages=lambda *a,**kw:[self.status]

    def test_acceptance_binds_final_head_feedback_and_metadata(self):
        receipt=self.p.acceptance(self.s)
        self.assertEqual(receipt['job'],'github-status:7')
        for field,value in [('head','e'*40),('base_sha','e'*40),('criteria_hash','e'*64),
                            ('comments',[{'id':2,'body':'new feedback'}]),('pr_body','changed')]:
            with self.subTest(field=field),self.assertRaises(c.q.QueueError):
                self.p.acceptance(dict(self.s,**{field:value}))
        changed=copy.deepcopy(self.s);changed['ticket_metadata']['labels'].append('changed')
        with self.assertRaises(c.q.QueueError):self.p.acceptance(changed)

    def test_latest_failure_foreign_actor_and_uncited_assessment_block(self):
        for change in ({'state':'failure'},{'creator':{'id':8}},{'target_url':'https://example.com/proof'}):
            original=self.status;self.status=dict(original,**change)
            with self.subTest(change=change),self.assertRaises(c.q.QueueError):self.p.acceptance(self.s)
            self.status=original
        newer=dict(self.status,id=8,state='pending')
        self.p.pages=lambda *a,**kw:[self.status,newer]
        with self.assertRaises(c.q.QueueError):self.p.acceptance(self.s)
        self.p.pages=lambda *a,**kw:[self.status]
        self.s['reviews'][0]['commit_id']='f'*40
        self.status['description']='queue-acceptance-v1:'+c.q.digest(c.w.binding(self.s))
        with self.assertRaises(c.q.QueueError):self.p.acceptance(self.s)

    def test_publish_refuses_changed_or_other_review_and_reuses_unchanged(self):
        observer=mock.Mock()
        review=dict(self.s['reviews'][0],user={'id':42})
        observer.get.side_effect=lambda p:{'id':42} if p=='user' else review
        observer.pages.return_value=[self.status]
        binding=c.q.digest(c.w.binding(self.s))
        self.assertTrue(h.publish(observer,self.s,'accept',self.url,binding)['reused'])
        observer.command.assert_not_called()
        with self.assertRaises(c.q.QueueError):h.publish(observer,self.s,'accept',self.url,'old')
        review['user']['id']=43
        with self.assertRaises(c.q.QueueError):h.publish(observer,self.s,'accept',self.url,binding)
        observer.command.assert_not_called()

    def test_only_current_app_selection_permits_refresh(self):
        packet=dict(attempt='a'*32,kind=c.SELECTION,**{k:self.s[k] for k in ('repository','number','head','base_sha')})
        r=dict(id=3,name=c.SELECTION,app={'id':10},status='in_progress',head_sha=self.s['head'],
               external_id='queue-selection-v1:'+c.q.digest(packet),output={'summary':c.q.encoded(packet)})
        self.assertEqual(h.selected([r],self.s,10),packet)
        for change in ({'app':{'id':11}},{'status':'completed'},{'head_sha':'e'*40},{'external_id':'fake'}):
            with self.subTest(change=change),self.assertRaises(c.q.QueueError):h.selected([dict(r,**change)],self.s,10)
        with self.assertRaises(c.q.QueueError):h.selected([r],dict(self.s,base_sha='e'*40),10)
        with self.assertRaises(c.q.QueueError):h.selected([r,dict(r,id=4,status='completed')],self.s,10)

    def test_nomination_discovery_preserves_order_and_retired_requests(self):
        with tempfile.TemporaryDirectory() as tmp:
            db=c.Journal(Path(tmp)/'state')
            self.p.journal=db
            self.p.policy.update(base='trunk',repo='fixture/project',nominator_ids=[42])
            prs=[dict(number=n,draft=False,head={'sha':str(n)*40,'repo':{'full_name':'fixture/project'}}) for n in (1,2,3)]
            statuses={n:[dict(id=100-n,context=c.NOMINATION,state='success',creator={'id':42},description='queue-nomination-v1')] for n in (1,2,3)}
            self.p.pages=lambda path:prs if path.startswith('/pulls') else statuses[int(path.split('/')[2][0])]
            self.p.discover();self.p.discover()
            self.assertEqual([r['number'] for r in db.requests()],[3,2,1])
            db.retire_request(3,'operator withdrawal');self.p.discover()
            self.assertEqual([r['number'] for r in db.requests()],[2,1])
            db.close()


class RefreshTests(unittest.TestCase):
    setUp=f.ControllerTests.setUp
    tearDown=f.ControllerTests.tearDown
    step=f.ControllerTests.step
    def test_selected_refresh_survives_restart_without_launching_workers(self):
        self.p.policy={'handoff':'github-v1'}
        self.p.discover=lambda:None
        self.p.ready=lambda s:s['head'].startswith('d')
        a=self.step();self.assertEqual(a['phase'],'waiting_refresh')
        self.runner=c.Controller(self.db,self.p,'policy1')
        for _ in range(3):self.step()
        self.assertFalse(any(x[0] in ('refresh','dispatch') for x in self.p.calls))
        self.p.snapshots[1]['head']='d'*40;self.p.proof=False
        a=self.step();self.assertEqual(a['phase'],'reviewing')
        self.assertEqual(self.db.next_number(),1)
        self.p.proof=True
        self.assertEqual(self.step()['phase'],'dispatching')
        self.assertEqual([x for x in self.p.calls if x[0]=='dispatch'],[('dispatch',1)])

    def test_base_change_during_external_refresh_blocks_lane(self):
        self.p.policy={'handoff':'github-v1'};self.p.discover=lambda:None;self.p.ready=lambda s:False
        self.step();self.p.snapshots[1]['base_sha']='e'*40
        self.assertEqual(self.step()['phase'],'blocked')
        self.assertFalse(any(x[0] in ('refresh','dispatch') for x in self.p.calls))
        self.assertEqual(self.db.next_number(),1)

    def test_changed_stale_refresh_is_recoverable_and_unknown_readiness_waits(self):
        self.p.policy={'handoff':'github-v1'};self.p.discover=lambda:None
        readiness=[False];self.p.ready=lambda s:readiness[0]
        old=self.step();self.assertEqual(old['phase'],'waiting_refresh')
        self.p.snapshots[1]['head']='e'*40
        readiness[0]=None
        self.assertEqual(self.step()['phase'],'waiting_refresh')
        readiness[0]=False
        blocked=self.step();self.assertEqual(blocked['phase'],'blocked')
        self.assertIn('stale head',blocked['reason'])
        self.assertEqual(self.db.next_number(),1)
        self.assertFalse(any(x[0] in ('refresh','dispatch') for x in self.p.calls))
        self.assertTrue(self.p.stopped(blocked))
        # The existing retry protocol can now retire this stopped attempt and
        # produce a fresh selection on the new head without releasing another PR.
        self.runner.block(blocked,blocked['reason'])
        blocked.update(phase='retired',recovery_reason='retry selected refresh')
        self.db.save(blocked,retire=True)
        selected=self.step()
        self.assertEqual(selected['phase'],'waiting_refresh')
        self.assertEqual(selected['snapshot']['head'],'e'*40)
        self.assertNotEqual(selected['id'],old['id'])
        self.assertEqual(self.db.next_number(),1)


if __name__=='__main__':
    result=unittest.main(exit=False)
    if result.result.wasSuccessful():print('queue-handoff self-test passed')
    sys.exit(0 if result.result.wasSuccessful() else 1)
