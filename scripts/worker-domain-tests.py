#!/usr/bin/env python3
"""Offline tests: no identities, services, provider calls or host process kills."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import signal
import sys
import time
import hashlib
import shutil
from contextlib import contextmanager
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('domains', Path(__file__).with_name('worker-domain.py'))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class Backend:
    def __init__(self):
        self.live = False
        self.uncertain = False
        self.stop_fails = False
    def create(self, record): pass
    def populated(self, record):
        if self.uncertain: raise d.DomainError('visibility unavailable')
        return self.live
    def kill(self, record):
        if self.stop_fails: raise d.DomainError('stop failed')
        self.live = False


class DomainTests(unittest.TestCase):
    def test_mac_directory_groups_are_distinct_from_execution_groups(self):
        with patch.object(d.sys,'platform','darwin'), patch.object(d.os,'getgrouplist',return_value=[602,12,61,701,702,333,100]):
            d.validate_directory_groups('_loop_exec_author',602)
        for groups in ([602,80],[602,0],[12,61]):
            with patch.object(d.sys,'platform','darwin'), patch.object(d.os,'getgrouplist',return_value=groups):
                with self.assertRaises(d.DomainError): d.validate_directory_groups('_loop_exec_author',602)
        with patch.object(d.sys,'platform','linux'), patch.object(d.os,'getgrouplist',return_value=[602,100]):
            with self.assertRaises(d.DomainError): d.validate_directory_groups('_loop_exec_author',602)
    def test_drop_verifies_private_kernel_groups_before_execution(self):
        from contextlib import ExitStack
        with ExitStack() as stack:
            calls=[]
            for method in ('setgid','setgroups','setuid'):
                stack.enter_context(patch.object(d.os,method,side_effect=lambda value,m=method:calls.append((m,value))))
            for method in ('getuid','geteuid','getgid','getegid'):
                stack.enter_context(patch.object(d.os,method,return_value=602))
            with patch.object(d,'kernel_groups',return_value=[602]): d.drop(dict(uid=602,gid=602))
            self.assertEqual(calls,[('setgid',602),('setgroups',[602]),('setuid',602)])
            for groups in ([],[602,12],[0],[602,80]):
                with patch.object(d,'kernel_groups',return_value=groups):
                    with self.assertRaisesRegex(d.DomainError,'kernel groups'): d.drop(dict(uid=602,gid=602))
    def test_interpreter_operand_must_be_protected_and_pinned(self):
        script='/protected/adapter.py'; python='/usr/bin/python3'
        with patch.object(d,'protected',side_effect=lambda p:Path(p)) as protected:
            with self.assertRaises(d.DomainError): d.validate_adapter_command([python,'-I',script],{python:'hash'})
            d.validate_adapter_command([python,'-I',script],{python:'hash',script:'hash'})
            self.assertIn((script,),[c.args for c in protected.call_args_list])
            for command in ([python,'-c','code'],[python,'-m','mutable'],[python,script],['/bin/sh','-c','mutable']):
                with self.assertRaises(d.DomainError): d.validate_adapter_command(command,{python:'hash',script:'hash'})
        with patch.object(d,'protected',side_effect=d.DomainError('writable operand')):
            with self.assertRaises(d.DomainError): d.validate_adapter_command([python,'-I',script],{python:'hash',script:'hash'})
    def test_load_config_rejects_missing_and_changed_script_artifacts(self):
        # Account/root ownership calls are explicit fixtures; file contents and manifest
        # validation run through load_config, not a replica of its validation logic.
        binary=self.root/'python3'; binary.write_text('pinned interpreter')
        adapter=self.root/'adapter.py'; adapter.write_text('pinned program')
        state=self.root/'state'; state.mkdir(mode=0o700)
        cg=self.root/'cg'; cg.mkdir(); (cg/'cgroup.controllers').write_text('pids')
        config=dict(protocol=1,enabled=True,observer_uid=601,controller_uid=600,state=str(state),
                    timeout=10,backend='linux-cgroup-v2',cgroup_parent=str(cg),
                    artifacts={str(binary):hashlib.sha256(binary.read_bytes()).hexdigest()},
                    roles={r:dict(uid=uid,command=[str(binary),'-I',str(adapter)])
                           for r,uid in (('author',602),('acceptance',603))})
        path=self.root/'config.json'
        with patch.object(d.os,'getuid',return_value=0),patch.object(d.os,'geteuid',return_value=0), \
             patch.dict(d.os.environ,{'SUDO_UID':'601'}),patch.object(d.sys,'platform','linux'), \
             patch.object(d,'validate_account'),patch.object(d,'require_cgroup_mount'), \
             patch.object(d,'protected',side_effect=lambda p,**kw:Path(p)) as protected:
            path.write_text(json.dumps(config))
            with self.assertRaisesRegex(d.DomainError,'not pinned'):d.load_config(path)
            config['artifacts'][str(adapter)]=hashlib.sha256(adapter.read_bytes()).hexdigest()
            path.write_text(json.dumps(config)); d.load_config(path)
            self.assertIn((str(adapter),),[c.args for c in protected.call_args_list])
            adapter.write_text('changed program')
            with self.assertRaisesRegex(d.DomainError,'artifact changed'):d.load_config(path)
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.backend = Backend()
        self.store = d.Store(self.root, 'config-v1', self.backend)
        self.req = dict(job_id='a'*64+'-1', fence='b'*64, role='author')
    def tearDown(self): self.tmp.cleanup()
    def reserve(self): return self.store.reserve(self.req)
    def launch(self):
        self.reserve()
        return self.store.consume(self.req)
    def test_reserve_is_idempotent_and_roles_exclusive(self):
        self.assertEqual(self.reserve(), self.reserve())
        other = dict(self.req, job_id='c'*64+'-1')
        with self.assertRaisesRegex(d.DomainError, 'occupied'): self.store.reserve(other)
        reviewer = dict(other, role='acceptance')
        self.assertEqual(self.store.reserve(reviewer)['role'], 'acceptance')
    def test_unknown_job_sealed_before_delayed_reserve(self):
        self.assertEqual(self.store.seal(self.req)['phase'], 'closed')
        with self.assertRaisesRegex(d.DomainError, 'closed'): self.reserve()
    def test_launch_consumed_before_spawn_and_never_replayed(self):
        self.launch()
        with self.assertRaisesRegex(d.DomainError, 'consumed'): self.store.consume(self.req)
    def test_detached_reparented_members_retain_slot(self):
        self.launch()
        self.backend.live = True  # membership, independent of PID/PPID/PGID/session
        with self.assertRaisesRegex(d.DomainError, 'populated'): self.store.seal(self.req)
        self.assertEqual(self.store.read(self.req)['phase'], 'launched')
    def test_unknown_visibility_and_failed_stop_retain_slot(self):
        self.launch()
        self.backend.uncertain = True
        with self.assertRaises(d.DomainError): self.store.seal(self.req)
        self.backend.uncertain = False
        self.backend.live = self.backend.stop_fails = True
        with self.assertRaises(d.DomainError): self.store.seal(self.req, stop=True)
        self.assertEqual(self.store.read(self.req)['phase'], 'launched')
    def test_launch_lock_blocks_seal_including_before_enrollment(self):
        self.launch()
        with d.lock(self.root / (self.req['job_id']+'.launch')):
            with self.assertRaisesRegex(d.DomainError, 'launcher'): self.store.seal(self.req)
        self.assertEqual(self.store.seal(self.req)['phase'], 'closed')
    def test_stop_then_new_assignment_old_replay_denied(self):
        self.launch()
        self.backend.live = True
        self.assertEqual(self.store.seal(self.req, stop=True)['phase'], 'closed')
        self.store.reserve(dict(self.req, job_id='d'*64+'-1'))
        with self.assertRaisesRegex(d.DomainError, 'closed'): self.reserve()
    def test_old_seal_never_stops_new_assignment(self):
        self.launch()
        self.store.seal(self.req)
        self.store.reserve(dict(self.req, job_id='d'*64+'-1'))
        self.backend.live = True
        self.store.seal(self.req, stop=True)
        self.assertTrue(self.backend.live)
    def test_unknown_stop_cannot_kill_another_jobs_domain(self):
        self.launch(); self.backend.live=True
        other=dict(self.req,job_id='e'*64+'-1')
        with self.assertRaisesRegex(d.DomainError,'occupied'): self.store.seal(other,stop=True)
        self.assertTrue(self.backend.live)
    def test_fence_and_role_and_config_changes_rejected(self):
        self.reserve()
        for req in (dict(self.req, fence='c'*64), dict(self.req, role='acceptance')):
            with self.assertRaises(d.DomainError): self.store.seal(req)
        self.store.revision = 'config-v2'
        with self.assertRaises(d.DomainError): self.store.seal(self.req)
    def test_preexisting_process_prevents_reservation(self):
        self.backend.live = True
        with self.assertRaises(d.DomainError): self.reserve()
    def test_malformed_identity_and_state_are_not_empty(self):
        for value in ('../../escape', '', 'x', None):
            with self.assertRaises(d.DomainError): self.store.reserve(dict(self.req, job_id=value))
        self.reserve()
        (self.root/(self.req['job_id']+'.json')).write_text('{')
        with self.assertRaises((ValueError, d.DomainError)): self.store.seal(self.req)
    def test_linux_population_unknown_rejected(self):
        cg = self.root/'cg'; cg.mkdir()
        record = dict(self.req)
        target = cg/self.req['job_id']; target.mkdir()
        b = d.LinuxCgroup(cg)
        for body in ('', 'populated x\n', 'populated 0\npopulated 1\n'):
            (target/'cgroup.events').write_text(body)
            with self.assertRaises(d.DomainError): b.populated(record)
        (target/'cgroup.events').write_text('populated 1\nfrozen 0\n')
        self.assertTrue(b.populated(record))
        (target/'cgroup.events').write_text('populated 0\nfrozen 0\n')
        self.assertFalse(b.populated(record))
        (target/'cgroup.events').unlink()
        with self.assertRaises(OSError): b.populated(record)
    def test_fake_cgroup_filesystem_cannot_prove_stop(self):
        mounts='1 0 0:1 / / rw - ext4 /dev/root rw\n2 1 0:2 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n'
        d.require_cgroup_mount(Path('/sys/fs/cgroup/loop'),mounts)
        for path in ('/tmp/fake','/sys/fs/cgroup-copy'):
            with self.assertRaises(d.DomainError): d.require_cgroup_mount(Path(path),mounts)
        mounts+='3 2 0:3 / /sys/fs/cgroup/loop rw - tmpfs tmpfs rw\n'
        with self.assertRaises(d.DomainError): d.require_cgroup_mount(Path('/sys/fs/cgroup/loop'),mounts)
    def test_uid_backend_requires_dedicated_accounts(self):
        for uid in (0, 1, 502, os.getuid()):
            with self.assertRaises(d.DomainError):
                d.validate_account(dict(uid=uid, gid=uid, name='interactive', home=str(self.root)))
    def test_uid_inventory_errors_and_truncation_never_mean_empty(self):
        with patch.object(d.ctypes,'CDLL') as lib:
            backend=d.MacUID({'author':{'uid':602}})
            api=lib.return_value.proc_listpids
            for replies in ([0], [4,-1], [4,3], [4,4100]*8):
                api.side_effect=replies
                with self.assertRaises(d.DomainError): backend.populated({'role':'author'})
            def denied(*args):
                if args[-1]==0: return 4
                d.ctypes.set_errno(1)
                return 0
            api.side_effect=denied
            with self.assertRaises(d.DomainError): backend.populated({'role':'author'})
            api.side_effect=[4,0]
            self.assertFalse(backend.populated({'role':'author'}))


@contextmanager
def host_fixture():
    # sudo may preserve a caller-private TMPDIR, whose ancestors are not traversable by
    # execution accounts. The synthetic fixture must have a shared, canonical temp parent.
    path=tempfile.mkdtemp(prefix='loop-domain-proof-',dir='/private/tmp' if sys.platform=='darwin' else '/tmp')
    try: yield path
    except BaseException:
        print('Failed host proof retained at '+path,file=sys.stderr)
        raise
    else: shutil.rmtree(path)


def host_proof(author_uid, reviewer_uid, cgroup_parent=None):
    """Explicit privileged synthetic acceptance. Never called by --self-test."""
    d.require(os.getuid()==0 and author_uid>=600 and reviewer_uid>=600 and author_uid!=reviewer_uid,
              'root and distinct dedicated proof UIDs required')
    if sys.platform.startswith('linux'): d.require_cgroup_mount(cgroup_parent)
    with host_fixture() as tmp:
        root=Path(tmp).resolve(); root.chmod(0o755)
        state=root/'state'; state.mkdir(mode=0o700)
        roles={}
        for role,uid in (('author',author_uid),('acceptance',reviewer_uid)):
            if sys.platform=='darwin':
                account=d.pwd.getpwuid(uid)
                d.validate_account(dict(uid=uid,gid=account.pw_gid,name=account.pw_name,home=account.pw_dir))
            home=root/role; home.mkdir(mode=0o700); os.chown(home,uid,uid)
            roles[role]=dict(uid=uid,gid=uid,home=str(home),name='_loop_exec_proof_'+role,
                             command=[sys.executable,'-I',str(root/'fixture.py')])
        backend=d.MacUID(roles) if sys.platform=='darwin' else d.LinuxCgroup(cgroup_parent)
        store=d.Store(state,'host-proof-v1',backend)
        config=dict(roles=roles,timeout=10)
        fixture=root/'fixture.py'
        shared=root/'directory-group-only'
        shared.write_text('synthetic group access sentinel')
        os.chown(shared,0,100); shared.chmod(0o640)
        fixture.write_text("""import ctypes,json,os,sys,time
packet=json.load(sys.stdin)
api=ctypes.CDLL(None).getgroups
api.argtypes=(ctypes.c_int,ctypes.POINTER(ctypes.c_uint32)); api.restype=ctypes.c_int
count=api(0,None); groups=(ctypes.c_uint32*max(1,count))()
assert count>=0 and api(count,groups)==count
assert set(groups)=={os.getgid()}
try: open('directory-group-only').read()
except PermissionError: denied=True
else: raise RuntimeError('inherited directory group granted file access')
if packet.get('mode')=='detach':
    middle=os.fork()
    if middle==0:
        os.setsid()
        child=os.fork()
        if child:
            os._exit(0)
        # This orphan launches more separate sessions while the supervisor is interrupted.
        for _ in range(24):
            pid=os.fork()
            if pid==0:
                os.setsid()
                time.sleep(60)
                os._exit(0)
            time.sleep(.01)
        time.sleep(60)
        os._exit(0)
    os.waitpid(middle,0)
print(json.dumps(dict(uid=os.getuid(),pgid=os.getpgrp(),kernel_groups=list(groups),shared_group_file_denied=denied)),flush=True)
if packet.get('mode')=='detach': time.sleep(60)
""")
        fixture.chmod(0o444)  # installer uses umask 077; execution UIDs still need to read code
        evidence={}
        launched=[]
        try:
            for index,role in enumerate(('author','acceptance')):
                req=dict(job_id=hashlib.sha256(('interrupted-'+role).encode()).hexdigest()+'-1',
                         fence='b'*64,role=role)
                req['packet']=dict(role=role,result_schema=dict(job_id=req['job_id']),worktree=str(root),mode='detach')
                store.reserve(req); launched.append(req)
                pid=os.fork()
                if pid==0:
                    try: d.run(store,req,config); os._exit(0)
                    except BaseException as exc:
                        print('synthetic launcher: '+(str(exc) if isinstance(exc,d.DomainError) else type(exc).__name__),file=sys.stderr,flush=True)
                        os._exit(125)
                output=state/(req['job_id']+'.output')
                deadline=time.monotonic()+10
                while (not output.exists() or not output.read_text().strip()) and time.monotonic()<deadline:
                    time.sleep(.01)
                d.require(output.exists() and output.read_text().strip(), 'fixture did not execute')
                observed=json.loads(output.read_text())
                d.require(observed['uid']==roles[role]['uid'], 'wrong execution identity')
                os.kill(pid,signal.SIGKILL); os.waitpid(pid,0)
                try: store.seal(req)
                except d.DomainError: pass
                else: raise d.DomainError('surviving commands were incorrectly released')
                d.require(backend.populated(req),'detached job disappeared before stop proof')
                proof=store.seal(req,stop=True)
                d.require(proof['phase']=='closed' and not backend.populated(req),'job stop unproven')
                evidence[role]=dict(uid=observed['uid'],interrupted_launcher_retains_job=True,
                                   detached_reparented_commands_stopped=True,children_during_shutdown_stopped=True,
                                   kernel_groups=observed['kernel_groups'],shared_group_file_denied=observed['shared_group_file_denied'])
                for attempt in range(2):
                    again=dict(job_id=hashlib.sha256((role+str(attempt)).encode()).hexdigest()+'-1',fence='b'*64,role=role)
                    again['packet']=dict(role=role,result_schema=dict(job_id=again['job_id']),worktree=str(root))
                    store.reserve(again); launched.append(again)
                    result=d.run(store,again,config)
                    d.require(result['exit_code']==0 and result['failure'] is None and
                              result['proof']['phase']=='closed','clean job did not finish')
                evidence[role]['successful_cleanup_and_repeat_assignment']=True
            return dict(host=sys.platform,synthetic_domain_proof='passed',roles=evidence,
                        model_calls=0,github_calls=0,services_started=False)
        finally:
            # Only domains created by this proof are eligible for cleanup. Unknown/busy state
            # remains on disk on a failed proof; never infer that a failed kill succeeded.
            for req in launched:
                r=store.read(req)
                if r and r['phase']!='closed': store.seal(req,stop=True)
            if cgroup_parent:
                for req in launched: backend.path(req).rmdir()


if __name__ == '__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--host-proof':
        import argparse
        parser=argparse.ArgumentParser()
        parser.add_argument('--host-proof',action='store_true')
        parser.add_argument('--author-uid',type=int,required=True)
        parser.add_argument('--reviewer-uid',type=int,required=True)
        parser.add_argument('--cgroup-parent',type=Path)
        args=parser.parse_args()
        print(json.dumps(host_proof(args.author_uid,args.reviewer_uid,args.cgroup_parent),indent=2))
    else: unittest.main(argv=[__file__])
