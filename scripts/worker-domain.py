#!/usr/bin/env python3
"""Trusted whole-job lifecycle broker. No GitHub, model or merge semantics.

Run only through an operator-owned fixed entry point, with a fixed root-owned config.
Never grant sudo access to this script with caller-selected --config or Python options.
--self-test is unprivileged; installation and host acceptance are separate operations.
"""
import argparse
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
LIMIT = 1024*1024


class DomainError(Exception): pass


def require(ok, why):
    if not ok: raise DomainError(why)


def encoded(obj): return json.dumps(obj, sort_keys=True, separators=(',', ':'))


def identity(request):
    require(isinstance(request, dict), 'request must be an object')
    require(isinstance(request.get('job_id'), str) and
            re.fullmatch(r'[a-f0-9]{64}-[1-9][0-9]*', request['job_id']), 'invalid job identity')
    require(isinstance(request.get('fence'), str) and
            re.fullmatch(r'[a-f0-9]{64}', request['fence']), 'invalid job fence')
    require(request.get('role') in ('author', 'acceptance'), 'invalid role')
    return {k: request[k] for k in ('job_id', 'fence', 'role')}


@contextmanager
def lock(path):
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise DomainError('launcher or lifecycle operation still alive; ownership retained')
        yield fd
    finally: os.close(fd)


class Store:
    """Persistent launch tombstones. The root-owned lock covers all role assignments."""
    def __init__(self, root, revision, backend):
        self.root, self.revision, self.backend = Path(root), revision, backend
    def path(self, request): return self.root/(identity(request)['job_id']+'.json')
    def read(self, request):
        p = self.path(request)
        if not p.exists(): return None
        r = json.loads(p.read_text())
        require(all(r.get(k) == v for k,v in identity(request).items()) and
                r.get('revision') == self.revision, 'job fence, role or installed configuration changed')
        require(r.get('phase') in ('reserved','launched','closed'), 'unknown domain phase')
        return r
    def write(self, record):
        fd, name = tempfile.mkstemp(dir=str(self.root), prefix='.write-')
        try:
            with os.fdopen(fd, 'w') as out:
                out.write(encoded(record)); out.flush(); os.fsync(out.fileno())
            os.replace(name, self.path(record))
            # Darwin does not permit fsync on directories. The renamed file itself was synced;
            # missing/corrupt launched state on recovery is never inferred to mean empty.
            if sys.platform != 'darwin':
                fd = os.open(str(self.root), os.O_RDONLY)
                try: os.fsync(fd)
                finally: os.close(fd)
        finally:
            if os.path.exists(name): os.unlink(name)
    def reserve(self, request):
        with lock(self.root/'assignments.lock'):
            r = self.read(request)
            if r:
                require(r['phase'] != 'closed', 'job permanently closed; replay denied')
                return r
            for path in self.root.glob('*.json'):
                other = json.loads(path.read_text())
                require(other.get('phase') in ('reserved','launched','closed'), 'unknown assignment state')
                require(other['phase'] == 'closed' or other['role'] != request['role'], 'role domain occupied')
            r = dict(identity(request), revision=self.revision, phase='reserved')
            # Record intent before touching the kernel. A failed create keeps the reservation.
            self.write(r)
            self.backend.create(r)
            require(not self.backend.populated(r), 'domain already populated; operator recovery required')
            return r
    def consume(self, request):
        # Caller MUST hold the launch lock across consume, fork and enrollment. The child
        # inherits it until credentials/membership are established, even if its parent dies.
        with lock(self.root/'assignments.lock'):
            r = self.read(request)
            require(r is not None and r['phase'] == 'reserved', 'launch already consumed or domain not reserved')
            require(not self.backend.populated(r), 'domain populated before launch')
            r['phase'] = 'launched'
            self.write(r)
            return r
    def seal(self, request, stop=False):
        with lock(self.root/(identity(request)['job_id']+'.launch')):
            with lock(self.root/'assignments.lock'):
                r = self.read(request)
                if r and r['phase']=='closed': return r
                for path in self.root.glob('*.json'):
                    other=json.loads(path.read_text())
                    require(other.get('phase') in ('reserved','launched','closed'), 'unknown assignment state')
                    require(other['job_id']==request['job_id'] or other['phase']=='closed' or
                            other['role']!=request['role'], 'role domain occupied by another job')
                # No reservation is not stop proof: write a permanent launch-denial tombstone
                # AND inspect the OS domain. A late reserve cannot resurrect this identity.
                if r is None:
                    r = dict(identity(request), revision=self.revision, phase='reserved')
                    self.write(r)
                    self.backend.create(r)
                if stop:
                    require(r['phase']=='launched' or not self.backend.populated(r),
                            'domain has no consumed launch; unknown processes retained')
                    if r['phase']=='launched': self.backend.kill(r)
                require(not self.backend.populated(r), 'domain populated; ownership retained')
                r['phase'] = 'closed'
                self.write(r)
                return r


class LinuxCgroup:
    """Root-owned cgroup v2 domain. No delegation or writable cgroup mounts in workers."""
    def __init__(self, parent): self.parent = Path(parent)
    def command(self, argv): return argv
    def path(self, r): return self.parent/r['job_id']
    def create(self, r):
        self.path(r).mkdir(mode=0o700, exist_ok=True)
        require((self.path(r)/'cgroup.kill').is_file(), 'cgroup v2 kill support required')
    def populated(self, r):
        rows = [line.split() for line in (self.path(r)/'cgroup.events').read_text().splitlines()]
        values = [row[1] for row in rows if len(row)==2 and row[0]=='populated']
        require(len(values)==1 and values[0] in ('0','1'), 'incomplete cgroup population evidence')
        return values[0]=='1'
    def enroll(self, r):
        (self.path(r)/'cgroup.procs').write_text(str(os.getpid()))
        libc = ctypes.CDLL(None, use_errno=True)
        require(libc.prctl(38, 1, 0, 0, 0)==0, 'cannot establish no_new_privs')
    def kill(self, r):
        (self.path(r)/'cgroup.kill').write_text('1')
        deadline = time.monotonic()+5
        while self.populated(r) and time.monotonic()<deadline: time.sleep(.02)


class MacUID:
    """Exclusive non-login real-UID domains, never the interactive/observer/controller UID.

    proc_listpids(PROC_RUID_ONLY) filters allproc and zombproc under the kernel proc-list
    lock. Count zombies as populated: no userland PID lookup is used to prove emptiness.
    UID-scoped kill(-1) runs AFTER irrevocably dropping root; no reused PID is signalled.
    """
    def __init__(self, roles):
        self.roles = roles
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_listpids.argtypes = (ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int)
        self.lib.proc_listpids.restype = ctypes.c_int
    def create(self, r): pass
    def enroll(self, r): pass  # credential drop, under inherited launch lock, is enrollment
    def command(self, argv):
        # Block launchd submission and the cron/at spool: those could create new work after
        # an empty inventory. This inherited profile is independent of the model's own sandbox.
        profile='(version 1)(allow default)(deny job-creation)(deny authorization-right-obtain)' \
                '(deny file-write* (subpath "/private/var/at"))'
        return ['/usr/bin/sandbox-exec','-p',profile]+argv
    def populated(self, r):
        uid = self.roles[r['role']]['uid']
        for _ in range(8):
            ctypes.set_errno(0)
            needed = self.lib.proc_listpids(5, uid, None, 0)
            require(needed>0, 'cannot size complete UID inventory')
            size = needed+4096
            require(size <= 64*LIMIT, 'UID inventory exceeds limit')
            buf = ctypes.create_string_buffer(size)
            ctypes.set_errno(0)
            count = self.lib.proc_listpids(5, uid, buf, size)
            require(count>=0 and ctypes.get_errno()==0 and count%4==0, 'incomplete UID inventory')
            if count < size: return count != 0
        raise DomainError('UID inventory repeatedly truncated')
    def kill(self, r):
        account = self.roles[r['role']]
        # A small trusted child changes identity before issuing the kernel permission-filtered
        # broadcast. No command or PID selected by model output ever runs with root authority.
        pid = os.fork()
        if pid == 0:
            try:
                drop(account)
                try: os.kill(-1, signal.SIGKILL)
                except ProcessLookupError: pass
                os._exit(0)
            except BaseException: os._exit(125)
        _, status = os.waitpid(pid, 0)
        require(os.WIFEXITED(status) and os.WEXITSTATUS(status)==0 or
                os.WIFSIGNALED(status) and os.WTERMSIG(status)==signal.SIGKILL,
                'UID stop helper failed')
        deadline = time.monotonic()+5
        while self.populated(r) and time.monotonic()<deadline: time.sleep(.02)


def protected(path, directory=False):
    path = Path(path)
    require(path.is_absolute() and path.resolve()==path, 'protected path must be canonical and absolute')
    for p in (path, *path.parents):
        s = p.lstat()
        require(s.st_uid==0 and not s.st_mode & 0o022 and not stat.S_ISLNK(s.st_mode), 'root-owned non-writable path required')
    require(path.is_dir() if directory else path.is_file(), 'protected path type mismatch')
    return path


def validate_account(account):
    uid, gid, name = account.get('uid'), account.get('gid'), account.get('name')
    require(type(uid) is int and uid>=600 and type(gid) is int and gid>=600 and
            isinstance(name,str) and name.startswith('_loop_exec_'), 'dedicated execution account required')
    p = pwd.getpwnam(name)
    require(p.pw_uid==uid and p.pw_gid==gid and p.pw_dir==account.get('home') and
            p.pw_shell in ('/usr/bin/false','/bin/false','/usr/sbin/nologin','/sbin/nologin'), 'execution account mismatch')
    require(set(os.getgrouplist(name,gid))=={gid}, 'execution account must have only its private group')
    require(uid not in (os.getuid(), account.get('observer_uid'), account.get('controller_uid')), 'execution and trusted identities overlap')
    home = Path(p.pw_dir)
    require(home.is_absolute() and home.resolve()==home, 'canonical execution home required')
    require(home.stat().st_uid==uid and home.stat().st_mode & 0o077==0, 'execution HOME must be private')


def drop(account):
    os.setgroups([])
    os.setgid(account['gid'])
    os.setuid(account['uid'])
    require(os.getuid()==account['uid'] and os.geteuid()==account['uid'] and
            os.getgid()==account['gid'] and os.getegid()==account['gid'], 'credential drop failed')


def require_cgroup_mount(parent, mountinfo=None):
    text=Path('/proc/self/mountinfo').read_text() if mountinfo is None else mountinfo
    candidates=[]
    for line in text.splitlines():
        before,after=line.split(' - ',1)
        field=before.split()[4]
        mount=Path(re.sub(r'\\([0-7]{3})',lambda m: chr(int(m.group(1),8)),field))
        if parent==mount or mount in parent.parents:
            candidates.append((len(mount.parts),after.split()[0]))
    require(candidates and max(candidates)[1]=='cgroup2','domain parent is not a kernel cgroup v2 mount')


def load_config(path):
    require(os.getuid()==0 and os.geteuid()==0, 'broker requires fixed privileged entry point')
    path = protected(path)
    config = json.loads(path.read_text())
    require(config.get('protocol')==1 and config.get('enabled') is True, 'domain service is not activated')
    require(type(config.get('observer_uid')) is int and config['observer_uid']>=500 and
            type(config.get('controller_uid')) is int and config['controller_uid']>=500 and
            config['observer_uid']!=config['controller_uid'], 'separate observer/controller identities required')
    caller = os.environ.get('SUDO_UID')
    require(caller is None or caller in ('0',str(config['observer_uid'])), 'caller is not the configured observer')
    state = protected(config['state'], directory=True)
    require(state.stat().st_mode & 0o077==0, 'broker state must be root-private')
    require(set(config['roles'])=={'author','acceptance'}, 'exactly two role domains required')
    seen = set()
    artifacts=config.get('artifacts')
    require(isinstance(artifacts,dict) and artifacts, 'pinned runtime artifacts required')
    for name, digest in artifacts.items():
        artifact=protected(name)
        require(hashlib.sha256(artifact.read_bytes()).hexdigest()==digest, 'installed runtime artifact changed')
    for account in config['roles'].values():
        validate_account(dict(account, observer_uid=config['observer_uid'], controller_uid=config['controller_uid']))
        require(account['uid'] not in seen, 'execution roles must use distinct UIDs'); seen.add(account['uid'])
        cmd = account['command']
        require(isinstance(cmd,list) and cmd and all(isinstance(v,str) and v for v in cmd), 'fixed adapter argv required')
        protected(cmd[0])
        require(cmd[0] in artifacts, 'adapter executable is not pinned')
        env = account.get('env',{})
        require(isinstance(env,dict) and all(isinstance(k,str) and isinstance(v,str) for k,v in env.items()), 'invalid fixed environment')
        require(not any(k in env for k in ('HOME','USER','LOGNAME','SUDO_UID')), 'identity environment is broker-owned')
    require(type(config.get('timeout')) is int and 1<=config['timeout']<=86400, 'bounded timeout required')
    if sys.platform=='darwin':
        require(config['backend']=='mac-exclusive-uid-v1', 'wrong host backend')
        require('/usr/bin/sandbox-exec' in artifacts, 'system sandbox launcher must be pinned')
        backend = MacUID(config['roles'])
    elif sys.platform.startswith('linux'):
        require(config['backend']=='linux-cgroup-v2', 'wrong host backend')
        parent = protected(config['cgroup_parent'], directory=True)
        require_cgroup_mount(parent)
        require((parent/'cgroup.controllers').is_file(), 'cgroup v2 parent required')
        backend = LinuxCgroup(parent)
    else: raise DomainError('unsupported host; ownership retained')
    revision = hashlib.sha256(path.read_bytes()+Path(__file__).read_bytes()).hexdigest()
    return config, Store(state, revision, backend)


def run(store, request, config):
    packet = request.get('packet')
    require(isinstance(packet,dict) and packet.get('role')==request['role'] and
            packet.get('result_schema',{}).get('job_id')==request['job_id'], 'worker packet identity mismatch')
    cwd = packet.get('worktree')
    require(isinstance(cwd,str) and Path(cwd).is_absolute(), 'absolute worker directory required')
    account = config['roles'][request['role']]
    # These root-private artifacts remain readable only by the trusted observer via the fixed
    # broker response. Worker processes receive standard streams, no lifecycle/state descriptors.
    with lock(store.root/(identity(request)['job_id']+'.launch')) as launch_fd:
        r = store.consume(request)
        paths = [store.root/(request['job_id']+suffix) for suffix in ('.input','.output','.error')]
        with paths[0].open('x+b') as inp, paths[1].open('x+b') as out, paths[2].open('x+b') as err:
            inp.write(encoded(packet).encode()); inp.flush(); inp.seek(0)
            env = {'PATH':'/usr/bin:/bin','LANG':'en_US.UTF-8', **account.get('env',{}),
                   'HOME':account['home'], 'USER':account['name'], 'LOGNAME':account['name']}
            pid = os.fork()
            if pid==0:
                try:
                    # launch_fd survives fork until enrollment and the irreversible uid drop.
                    # CLOEXEC closes it on successful exec; any earlier failure exits with it.
                    store.backend.enroll(r)
                    drop(account)
                    os.chdir(cwd)  # never traverse repository-selected paths with root privilege
                    for source, target in ((inp.fileno(),0),(out.fileno(),1),(err.fileno(),2)):
                        os.dup2(source,target)
                    argv=store.backend.command(account['command'])
                    os.execve(argv[0],argv,env)
                except BaseException: os._exit(125)
            deadline = time.monotonic()+config['timeout']
            failure = None
            while True:
                ended, status = os.waitpid(pid,os.WNOHANG)
                if ended: break
                if time.monotonic()>=deadline or max(p.stat().st_size for p in paths[1:])>LIMIT:
                    failure = 'timeout or output limit'
                    store.backend.kill(r)
                    # Do not block forever on an uninterruptible process. Retain ownership.
                    ended, status = os.waitpid(pid,os.WNOHANG)
                    require(ended==pid, 'stop incomplete; ownership retained')
                    break
                time.sleep(.05)
            # Adapter exit is not job completion. Treat any remaining command as failure,
            # stop the full domain, and require an explicit retry of the job.
            if store.backend.populated(r):
                failure = failure or 'adapter exited with surviving commands'
                store.backend.kill(r)
            out.flush(); out.seek(0)
            output = out.read(LIMIT+1)
            require(len(output)<=LIMIT, 'adapter output exceeds limit')
            code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128+os.WTERMSIG(status)
            result = dict(exit_code=code, output=output.decode('utf-8'), failure=failure)
    proof = store.seal(request)
    return dict(proof=proof, **result)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--self-test',action='store_true')
    p.add_argument('--config',type=Path)
    args = p.parse_args()
    if args.self_test:
        rc = subprocess.call([sys.executable,str(Path(__file__).with_name('worker-domain-tests.py'))])
        if rc==0: print('worker-domain self-test passed')
        return rc
    require(args.config is not None, 'fixed --config required')
    os.umask(0o077)
    config, store = load_config(args.config)
    raw = sys.stdin.buffer.read(2*LIMIT+1)
    require(len(raw)<=2*LIMIT, 'request exceeds limit')
    req = json.loads(raw); identity(req)
    require(req.get('protocol')==1 and req.get('revision')==store.revision, 'installed lifecycle revision mismatch')
    action = req.get('action')
    if action=='reserve': result=store.reserve(req)
    elif action=='run': result=run(store,req,config)
    elif action in ('seal','stop'): result=store.seal(req,stop=action=='stop')
    else: raise DomainError('unsupported lifecycle operation')
    print(encoded(dict(protocol=1, result=result)))
    return 0


if __name__=='__main__':
    try: sys.exit(main())
    except (DomainError,OSError,ValueError,KeyError,TypeError) as exc:
        # No config, model stderr, token or environment data is printed by failures.
        print('worker-domain: '+(str(exc) if isinstance(exc,DomainError) else type(exc).__name__),file=sys.stderr)
        sys.exit(1)
