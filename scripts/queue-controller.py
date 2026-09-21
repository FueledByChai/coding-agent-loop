#!/usr/bin/python3 -I
"""Opt-in trusted queue controller. Run from a protected installation, never a PR checkout.

No imported shadow snapshots. App credentials remain in this process. Commands configured
by the operator run with explicit environments and must cross the documented OS boundary.
"""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import shutil
import subprocess
import sys
import time
from urllib.request import Request, urlopen
from urllib.parse import quote
import uuid
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('queue_workers',Path(__file__).with_name('review-workers.py'))
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
q = w.q
GATE = 'Queue merge gate'
ADMISSION = 'Queue CI admission'


class Pending(Exception):
    """Provider is still computing readiness; retain ownership without mutating the PR."""


class CheckPending(Exception):
    """A check creation was attempted; only provider visibility can settle its identity."""


class Journal:
    def __init__(self,state):
        self.state=Path(state).resolve()
        self.state.mkdir(parents=True,exist_ok=True,mode=0o700)
        q.require(self.state.stat().st_uid==os.getuid() and not self.state.stat().st_mode & 0o077,
                  'controller state must be private and controller-owned')
        self.db=sqlite3.connect(str(self.state/'controller.sqlite'),isolation_level=None,timeout=30)
        self.db.row_factory=sqlite3.Row
        os.chmod(self.state/'controller.sqlite',0o600)
        self.db.execute('CREATE TABLE IF NOT EXISTS requests(position INTEGER PRIMARY KEY, number INTEGER UNIQUE, done INTEGER DEFAULT 0)')
        self.db.execute('CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY,data TEXT,active INTEGER)')
        self.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS one_controller_attempt ON attempts(active) WHERE active=1')
        self.db.execute('CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY,at REAL,attempt TEXT,detail TEXT)')
        self.db.execute('CREATE TABLE IF NOT EXISTS lane(binding TEXT)')
        # The constant-expression unique index also guards direct/concurrent inserts.
        # An old journal with conflicting bindings fails here without deleting any state.
        self.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS one_lane ON lane((1))')
    def close(self): self.db.close()
    @contextmanager
    def lock(self):
        fd=os.open(str(self.state/'controller.lock'),os.O_CREAT|os.O_RDWR,0o600)
        try:
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: raise q.QueueError('controller already running; no lease stealing')
            yield
        finally: os.close(fd)
    def bind(self,repo,base):
        lane=q.encoded([repo.lower(),base])
        with self.lock():
            rows=list(self.db.execute('SELECT binding FROM lane'))
            q.require(len(rows)<=1 and (not rows or rows[0][0]==lane),'controller journal belongs to a different lane')
            if not rows:self.db.execute('INSERT INTO lane VALUES (?)',(lane,))
    def enqueue(self,number):
        q.require(q.integer(number),'positive PR number required')
        self.db.execute('BEGIN IMMEDIATE')
        try:
            row=self.db.execute('SELECT done FROM requests WHERE number=?',(number,)).fetchone()
            if row and row['done']:
                a=self.active()
                q.require(not a or a['number']!=number,'active attempt cannot be requeued')
                self.db.execute('DELETE FROM requests WHERE number=?',(number,))
            self.db.execute('INSERT OR IGNORE INTO requests(number) VALUES (?)',(number,))
            self.db.execute('COMMIT')
        except BaseException:self.db.execute('ROLLBACK');raise
    def retire_request(self,number,reason):
        q.require(q.integer(number) and w.nonempty(reason),'request number and retirement reason required')
        with self.lock():
            a=self.active()
            q.require(not a or a['number']!=number,'active attempt retains ownership; verify stop through retry/reconciliation')
            self.db.execute('BEGIN IMMEDIATE')
            try:
                cursor=self.db.execute('UPDATE requests SET done=1 WHERE number=? AND done=0',(number,))
                q.require(cursor.rowcount==1,'request is absent or already retired')
                self.db.execute('INSERT INTO events(at,attempt,detail) VALUES (?,NULL,?)',
                    (time.time(),q.encoded({'kind':'retire-request','number':number,'reason':reason})))
                self.db.execute('COMMIT')
            except BaseException:self.db.execute('ROLLBACK');raise
    def requests(self):
        return [dict(row) for row in self.db.execute('SELECT position,number FROM requests WHERE done=0 ORDER BY position')]
    def next_number(self):
        row=self.db.execute('SELECT number FROM requests WHERE done=0 ORDER BY position LIMIT 1').fetchone()
        return row[0] if row else None
    def active(self):
        row=self.db.execute('SELECT data FROM attempts WHERE active=1').fetchone()
        return json.loads(row[0]) if row else None
    def save(self,a,done=False,retire=False):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            self.db.execute('INSERT INTO attempts VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,active=excluded.active',
                            (a['id'],q.encoded(a),0 if done or retire else 1))
            if done: self.db.execute('UPDATE requests SET done=1 WHERE number=?',(a['number'],))
            self.db.execute('INSERT INTO events(at,attempt,detail) VALUES (?,?,?)',(time.time(),a['id'],q.encoded(a)))
            self.db.execute('COMMIT')
        except BaseException: self.db.execute('ROLLBACK'); raise


def reviewed(s):
    q.require(s['review_evidence'] and not s['changes_requested'] and all(t['resolved'] for t in s['threads']),
              'completed exact-head review and resolved findings required')
    q.require(all(d['status']=='closed' for d in s['ticket_metadata']['dependencies'] if d['dependency_type']=='blocks'),
              'ticket dependencies must be complete')


class Controller:
    def __init__(self,db,provider,policy_hash): self.db,self.p,self.policy_hash=db,provider,policy_hash
    def fresh(self,a):
        self.p.protections()
        s=self.p.observe(a['number']); reviewed(s)
        q.require(w.binding(s)==w.binding(a['snapshot']),'head/base/review/ticket evidence changed')
        ready=self.p.ready(s)
        if ready is None:raise Pending('GitHub is computing mergeability; poll without refresh')
        q.require(ready,'selected head is not current and mergeable')
        q.require(self.p.acceptance(s)==a['acceptance'],'independent acceptance changed')
        q.require(a['policy']==self.policy_hash,'controller policy changed')
        return s
    def block(self,a,reason):
        a.update(phase='blocked',reason=reason); self.db.save(a)
        # Revoke admission first. Never release a lane on an exception or elapsed time.
        pending=None
        for name in (ADMISSION,GATE):
            try:self.p.check(a,name,'completed','failure')
            except CheckPending as exc:pending=exc
        self.p.cancel(a)
        if pending:raise pending
        return a
    def tick(self):
        with self.db.lock():
            try:return self._tick()
            except CheckPending as exc:
                a=self.db.active();a['check_wait']=str(exc);self.db.save(a)
                return a
    def _tick(self):
        a=self.db.active()
        if a and a['phase']=='merging':
            if self.p.verify_merge(a):
                # A previous inconclusive read may have revoked the gate. Repair it
                # before releasing ownership; failed/lost updates retry without merging.
                self.p.check(a,GATE,'completed','success')
                a.pop('reason',None);a.pop('check_wait',None)
                a['phase']='merged'; self.db.save(a,done=True)
            else:
                self.p.check(a,GATE,'completed','failure')
                a['reason']='merge outcome unconfirmed; operator reconciliation required'; self.db.save(a)
            return a
        if a and a['phase']=='blocked':
            return self.block(a,a['reason'])
        if not a:
            n=self.db.next_number()
            if n is None: return None
            self.p.protections()
            s=self.p.observe(n)
            a=dict(id=uuid.uuid4().hex,number=n,phase='selected',snapshot=s,policy=self.policy_hash)
            self.db.save(a)
        try:
            q.require(a['policy']==self.policy_hash,'controller policy changed')
            if a['phase']=='refreshing':
                # A lost/timeout refresh response cannot prove its author worker stopped.
                # Hold even if the remote branch now looks current. Never replay it.
                a['reason']='refresh outcome uncertain; reconcile the author guardian before proceeding'
                self.db.save(a); return a
            if a['phase'] in ('selected','reviewing'):
                s=self.p.observe(a['number'])
                if a.get('gate_check_create_intent'):
                    q.require(w.binding(s)==w.binding(a['snapshot']),'evidence changed after gate creation intent')
                ready=self.p.ready(s)
                if ready is None:return a
                if not ready:
                    if a['phase']=='selected':
                        # Persist before mutation. Never replay a refresh whose outcome is unknown.
                        a.update(phase='refreshing',snapshot=s,refresh_finished=False); self.db.save(a)
                        result=self.p.refresh(a)
                        q.require(result.get('stopped') is True and q.sha(result.get('head')),'refresh must prove worker stop and resulting head')
                        a.update(phase='reviewing',refresh_finished=True); self.db.save(a)
                    else:
                        raise q.QueueError('selected head needs another refresh; retire this stopped attempt explicitly')
                    return a
                a.update(phase='reviewing',snapshot=s); self.db.save(a)
                try:
                    reviewed(s); acceptance=self.p.acceptance(s)
                except q.QueueError as exc:
                    a['reason']=str(exc); self.db.save(a); return a
                a.update(acceptance=acceptance)
                self.fresh(a)
                self.p.check(a,GATE,'in_progress')
                self.fresh(a)
                a.update(phase='dispatching',dispatch_intent=True,dispatch_started_at=time.time()); self.db.save(a)
                self.p.dispatch(a)  # uncertain response is reconciled, never dispatched twice
                return a
            self.fresh(a)
            runs=self.p.find_runs(a)
            q.require(len(runs)<=1,'multiple runs for one dispatch; admission refused')
            if not runs: return a
            run=runs[0]
            q.require(run['run_attempt']==1,'reruns need a new explicit attempt')
            if 'run_id' in a: q.require(a['run_id']==run['id'],'CI run identity changed')
            if a['phase']=='dispatching':
                a.update(run_id=run['id'],phase='running'); self.db.save(a)
                self.fresh(a)
                self.p.check(a,ADMISSION,'in_progress',external=admission_identity(a,self.p))
                self.db.save(a)
                return a
            if run['status']!='completed':
                self.p.check(a,ADMISSION,'in_progress',external=admission_identity(a,self.p))
                self.db.save(a)
                return a
            q.require(self.p.ci_success(a,run),'actual admitted CI did not succeed')
            self.fresh(a)
            self.p.check(a,ADMISSION,'completed','success')
            self.p.check(a,GATE,'completed','success')
            self.fresh(a)
            # Re-read CI after publishing the gate, rejecting a concurrently requested rerun.
            again=self.p.find_runs(a)
            q.require(len(again)==1 and again[0]['id']==a['run_id'] and again[0]['run_attempt']==1 and
                      self.p.ci_success(a,again[0]),'CI changed before merge')
            a['phase']='merging'; self.db.save(a)
            self.p.merge(a)
            # GitHub may acknowledge the write before PR/ancestry/tree reads converge.
            # Persisted merge intent keeps ownership and lets later ticks verify, never replay.
            if not self.p.verify_merge(a):return a
            a.pop('reason',None);a.pop('check_wait',None)
            a['phase']='merged'; self.db.save(a,done=True)
            return a
        except Pending as exc:
            a['reason']=str(exc)
            self.p.check(a,GATE,'in_progress')
            self.db.save(a)
            return a
        except q.QueueError as exc: return self.block(a,str(exc))


def admission_identity(a,provider):
    return dict(repository=a['snapshot']['repository'],app_id=getattr(provider,'policy',{}).get('app_id',10),
                attempt=a['id'],head=a['snapshot']['head'],base_sha=a['snapshot']['base_sha'],run_id=a['run_id'])


def admission_id(identity):
    return 'queue-admission-v1:'+q.digest(identity)


def admitted(checks,expected,run_attempt):
    if run_attempt!=1: return False
    matches=[]
    for check in checks:
        if check.get('name')!=ADMISSION or check.get('app',{}).get('id')!=expected['app_id']: continue
        if check.get('external_id')==admission_id(expected):matches.append(check)
    return len(matches)==1 and matches[0]['status']=='in_progress'


def dispatch_boundary(a):
    stamp=a.get('dispatch_started_at')
    q.require(type(stamp) in (float,int) and q.math.isfinite(stamp) and stamp>0,
              'dispatch time missing; retain the attempt for reconciliation')
    # Small clock skew allowance; preserve the original boundary across restart.
    return datetime.fromtimestamp(stamp-300,timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def run_matches(run,a,p):
    return (run.get('display_title')=='queue:'+a['id'] and run.get('event')=='workflow_dispatch' and
            run.get('head_sha')==a['snapshot']['base_sha'] and run.get('head_branch')==p['base'] and
            run.get('workflow_id')==p['workflow_id'] and run.get('actor',{}).get('id')==p['app_actor_id'] and
            run.get('triggering_actor',{}).get('id')==p['app_actor_id'] and run.get('run_attempt')==1)


def protected_path(path):
    path=Path(path).expanduser().resolve()
    for item in (path,)+tuple(path.parents):
        q.require(item.stat().st_uid in (0,os.getuid()) and not item.stat().st_mode & 0o022,
                  'path must be protected from other identities: '+str(item))
    return path


def secure_file(path):
    path=Path(path).expanduser().resolve()
    q.require(path.is_file() and path.stat().st_uid==os.getuid() and not path.stat().st_mode & 0o077,
              'private controller-owned file required: '+str(path))
    # Writable ancestor directories would allow swapping even a protected file.
    for parent in path.parents:
        q.require(parent.stat().st_uid in (0,os.getuid()) and not parent.stat().st_mode & 0o022,
                  'untrusted configuration ancestor: '+str(parent))
    return path


def protected_search_path(read_path):
    q.require(isinstance(read_path,str) and bool(read_path),'protected read_path required')
    directories=[]
    for entry in read_path.split(os.pathsep):
        q.require(bool(entry) and Path(entry).is_absolute(),'read_path entries must be absolute and nonempty')
        directories.append(str(protected_path(entry)))
    return os.pathsep.join(directories)


def protected_tools(read_path):
    canonical=protected_search_path(read_path)
    binaries={}
    for name in ('gh','bd'):
        path=shutil.which(name,path=canonical)
        q.require(path is not None,'trusted read tool missing: '+name)
        binaries[name]=str(protected_path(path))
    return canonical,binaries


def request(method,path,token,data=None):
    q.require(path.startswith('/') and not path.startswith('//'),'relative GitHub API path required')
    req=Request('https://api.github.com'+path,method=method,
                headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json',
                         'X-GitHub-Api-Version':'2022-11-28','Content-Type':'application/json'},
                data=None if data is None else q.encoded(data).encode())
    with urlopen(req,timeout=30) as response:
        body=response.read(8*1024*1024+1)
    q.require(len(body)<=8*1024*1024,'GitHub response too large')
    return json.loads(body) if body else None


class App:
    def __init__(self,p): self.p=p; self.cached=None; self.until=0
    def token(self):
        if self.cached and time.time()<self.until: return self.cached
        enc=lambda b:base64.urlsafe_b64encode(b).rstrip(b'=')
        now=int(time.time())
        data=b'.'.join([enc(q.encoded({'alg':'RS256','typ':'JWT'}).encode()),
                        enc(q.encoded({'iat':now-60,'exp':now+480,'iss':str(self.p['app_id'])}).encode())])
        key=secure_file(self.p['private_key'])
        signature=subprocess.run(['/usr/bin/openssl','dgst','-sha256','-sign',str(key)],input=data,
                                 stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
        jwt=(data+b'.'+enc(signature)).decode()
        info=request('GET','/app',jwt)
        q.require(info['id']==self.p['app_id'],'GitHub App identity mismatch')
        r=request('POST','/app/installations/'+str(self.p['installation_id'])+'/access_tokens',jwt,
                  {'repositories':[self.p['repo'].split('/')[1]],
                   'permissions':{'contents':'write','pull_requests':'write','checks':'write','actions':'write','administration':'read'}})
        self.cached=r['token']; self.until=now+2700
        return self.cached
    def api(self,method,path,data=None): return request(method,path,self.token(),data)


class Provider:
    def __init__(self,p,root,journal):
        self.policy=p; self.root=Path(root); self.journal=journal; self.app=App(p); self.prefix='/repos/'+p['repo']
    def api(self,method,path,data=None): return self.app.api(method,self.prefix+path,data)
    def pages(self,path,key=None,until=None):
        result=[];page=1;seen=set()
        while True:
            data=self.api('GET',path+('&' if '?' in path else '?')+'per_page=100&page='+str(page))
            rows=data[key] if key else data
            q.require(isinstance(rows,list),'invalid paginated GitHub result')
            if rows:
                fingerprint=q.digest(rows)
                q.require(fingerprint not in seen,'GitHub pagination repeated a page')
                seen.add(fingerprint)
            result.extend(rows)
            if len(rows)<100 or (until and until(result)):return result
            page+=1
    def observe(self,n):
        # Validate every search directory and resolved binary before requesting credentials.
        read_path,binaries=protected_tools(self.policy['read_path'])
        # Only gh receives the short-lived App token. Configured worker commands never do.
        env={'PATH':os.defpath,'HOME':str(Path.home()),'GH_TOKEN':self.app.token(),'GH_PROMPT_DISABLED':'1'}
        env['PATH']=read_path
        subprocess.run([binaries['bd'],'dolt','pull'],cwd=self.root,env={'PATH':read_path,'HOME':str(Path.home())},
                       stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90,check=True)
        read_env={'PATH':read_path,'HOME':str(Path.home())}
        ticket_reader=lambda ticket:q.read_ticket(self.root,ticket,env=read_env,executable=binaries['bd'])
        s=w.Observer(self.root,env,ticket_reader=ticket_reader).snapshot(self.policy['repo'],n)
        q.require(s['base']==self.policy['base'],'PR targets another lane')
        return s
    def ready(self,s):
        pr=self.api('GET','/pulls/'+str(s['number']))
        q.require(pr.get('auto_merge') is None,'disable ordinary auto-merge before queue admission')
        q.require(pr['head']['sha']==s['head'] and pr['base']['ref']==s['base'],'PR changed during readiness read')
        blockers=[d['id'] for d in s['ticket_metadata']['dependencies'] if d['dependency_type']=='blocks']
        if blockers:
            def found(rows):
                subjects=[item['commit']['message'].partition('\n')[0] for item in rows]
                return all(any(subject.startswith(ticket+':') for subject in subjects) for ticket in blockers)
            commits=self.pages('/commits?sha='+s['base_sha'],until=found)
            q.require(found(commits),
                      'dependency lacks a naming commit on the observed base')
        comparison=self.api('GET','/compare/'+s['base_sha']+'...'+s['head'])
        if comparison['merge_base_commit']['sha']!=s['base_sha']:return False
        if pr['mergeable'] is None:return None
        q.require(pr['mergeable'] is True,'current head has a confirmed merge conflict')
        return True
    def command(self,name,packet):
        adapter=self.policy[name]
        # A single protected wrapper owns all interpreter/config choices.
        q.require(isinstance(adapter['command'],list) and len(adapter['command'])==1,
                  'adapter must be one protected wrapper executable without arguments')
        q.require(Path(adapter['command'][0]).is_absolute(),'absolute adapter executable required')
        executable=protected_path(adapter['command'][0])
        q.require(executable.is_absolute() and executable.stat().st_uid in (0,os.getuid()) and
                  not executable.stat().st_mode & 0o022,'untrusted adapter executable')
        env=dict(adapter['env'])
        q.require(not set(env)-{'PATH','HOME','LANG','LC_ALL','LC_CTYPE','TZ'},
                  'adapter environment must not select interpreter code or preload configuration')
        env['PATH']=protected_search_path(env.get('PATH',os.defpath))
        env['HOME']=str(protected_path(env.get('HOME',str(Path.home()))))
        result=subprocess.run([str(executable)],input=q.encoded(packet),text=True,stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE,env=env,cwd='/',timeout=adapter['timeout'],check=True)
        q.require(len(result.stdout)<=1048576,'adapter response too large')
        return json.loads(result.stdout)
    def acceptance(self,s):
        result=self.command('acceptance',{'snapshot':s,'binding':q.digest(w.binding(s))})
        q.require(result.get('outcome')=='pass' and result.get('binding')==q.digest(w.binding(s)) and
                  w.nonempty(result.get('job')) and result.get('reviewer_identity')==self.policy['reviewer_identity'],
                  'fresh independent acceptance receipt required')
        return result
    def refresh(self,a):
        s=a['snapshot']
        # Adapter must use the sanctioned refresh helper under the author identity, with
        # expected remote head/base and durable worker ownership. No App credential supplied.
        return self.command('refresh',{'repository':s['repository'],'number':s['number'],'ticket':s['ticket'],
                     'expected_head':s['head'],'expected_base':s['base_sha'],'attempt':a['id']})
    def check(self,a,name,status,conclusion=None,external=None):
        head=a['snapshot']['base_sha'] if name==ADMISSION else a['snapshot']['head']
        if name==ADMISSION and 'run_id' not in a:
            if status=='completed' and conclusion=='failure': return None
            raise q.QueueError('CI run must be bound before admission')
        if name==ADMISSION: external=admission_identity(a,self)
        identity=admission_id(external) if name==ADMISSION else q.encoded({'attempt':a['id'],'kind':name})
        key='admission_check' if name==ADMISSION else 'gate_check'
        intent_key=key+'_create_intent'
        target={'head':head,'external_id':identity}
        q.require(not a.get(intent_key) or a[intent_key]==target,'check creation identity changed')
        checks=self.pages('/commits/'+head+'/check-runs?filter=all',key='check_runs')
        matches=[r for r in checks if r['name']==name and r['app']['id']==self.policy['app_id'] and
                 (r.get('external_id')==identity or r['id']==a.get('admission_check' if name==ADMISSION else 'gate_check'))]
        q.require(len(matches)<=1,'ambiguous App check creation; operator reconciliation required')
        data={'status':status}
        if conclusion:data['conclusion']=conclusion
        if matches:
            a[key]=matches[0]['id'];a[intent_key]=target;self.journal.save(a)
            r=self.api('PATCH','/check-runs/'+str(matches[0]['id']),data)
        else:
            # A lost create response or stale listing must never trigger another POST.
            if a.get(intent_key) or a.get(key):
                raise CheckPending(name+' creation outcome unconfirmed; retaining lane and polling')
            # Do not create a success check after losing a prior check identity.
            if status=='completed' and conclusion=='failure': return None
            q.require(status=='in_progress','cannot complete an unknown App check')
            a[intent_key]=target;self.journal.save(a)
            r=self.api('POST','/check-runs',dict(data,name=name,head_sha=head,external_id=identity))
        a[key]=r['id'];self.journal.save(a)
        return r['id']
    def dispatch(self,a):
        s=a['snapshot']
        self.api('POST','/actions/workflows/'+str(self.policy['workflow_id'])+'/dispatches',
                 {'ref':self.policy['base'],'inputs':{'attempt':a['id'],'head':s['head'],'base_sha':s['base_sha'],
                     'app_id':str(self.policy['app_id'])}})
    def find_runs(self,a):
        runs=self.pages('/actions/workflows/'+str(self.policy['workflow_id'])+'/runs?event=workflow_dispatch'
                        +'&head_sha='+a['snapshot']['base_sha']+'&created='+quote('>='+dispatch_boundary(a),safe=''),
                        key='workflow_runs')
        matches=[r for r in runs if r.get('display_title')=='queue:'+a['id']]
        q.require(all(run_matches(r,a,self.policy) for r in matches),'unauthorized or retried CI dispatch')
        return matches
    def ci_success(self,a,run):
        if run['status']!='completed' or run['conclusion']!='success':return False
        jobs=self.pages('/actions/runs/'+str(run['id'])+'/attempts/1/jobs',key='jobs')
        matched=[j for j in jobs if j['name']==self.policy['ci_job']]
        if len(matched)!=1:return False
        job=matched[0]
        required={'Queue admission','Full check'}
        steps=job.get('steps',[])
        return job['conclusion']=='success' and all(sum(s['name']==n and s['status']=='completed' and
                   s['conclusion']=='success' for s in steps)==1 for n in required)
    def cancel(self,a):
        if 'run_id' in a:
            run=self.api('GET','/actions/runs/'+str(a['run_id']))
            if run['status']!='completed':self.api('POST','/actions/runs/'+str(a['run_id'])+'/cancel')
    def stopped(self,a):
        if not a.get('dispatch_intent'): return a.get('refresh_finished') is not False
        runs=self.find_runs(a)
        return bool(runs) and all(r['status']=='completed' for r in runs)
    def merge(self,a):
        s=a['snapshot']
        r=self.api('PUT','/pulls/'+str(s['number'])+'/merge',{'sha':s['head'],'merge_method':'rebase'})
        q.require(r.get('merged') is True,'GitHub refused expected-head merge')
    def verify_merge(self,a):
        s=a['snapshot']; pr=self.api('GET','/pulls/'+str(s['number']))
        if not pr.get('merged') or pr['head']['sha']!=s['head'] or pr['base']['ref']!=s['base']:return False
        landed=pr.get('merge_commit_sha')
        if not q.sha(landed):return False
        main=self.api('GET','/commits/'+quote(s['base'],safe=''))['sha']
        compare=self.api('GET','/compare/'+landed+'...'+main)
        before=self.api('GET','/git/commits/'+s['head'])['tree']['sha']
        after=self.api('GET','/git/commits/'+landed)['tree']['sha']
        return compare['merge_base_commit']['sha']==landed and before==after
    def protections(self):
        p=self.policy
        # Two rulesets: update restriction permits ONLY this App; the second has no bypass
        # and preserves strict CI, resolved threads and the App-pinned gate for the App too.
        rules=[self.api('GET','/rulesets/'+str(i)) for i in p['ruleset_ids']]
        validate_rules(rules,p)
        repo=self.api('GET','')
        q.require(not repo['allow_auto_merge'],'repository auto-merge must be disabled for exclusive controller merging')
        workflow=self.api('GET','/actions/workflows/'+str(p['workflow_id']))
        q.require(workflow.get('id')==p['workflow_id'] and workflow.get('path')==p['workflow_path'] and
                  workflow.get('state')=='active','dispatch workflow must match the pinned active workflow path')
        data=self.api('GET','/contents/'+p['workflow_path']+'?ref='+quote(p['base'],safe=''))
        content=base64.b64decode(data['content'])
        q.require(q.hashlib.sha256(content).hexdigest()==p['workflow_sha256'],'trusted workflow changed')
        return True


def validate_rules(rules,p):
    protections=[]; exclusive=[]
    for rule in rules:
        q.require(rule['enforcement']=='active' and rule['target']=='branch','inactive queue ruleset')
        refs=rule['conditions']['ref_name']
        q.require(refs['include']==['refs/heads/'+p['base']] and refs['exclude']==[], 'ruleset lane mismatch')
        types={r['type']:r for r in rule['rules']}
        if 'update' in types:
            q.require(rule['bypass_actors']==[{'actor_id':p['app_id'],'actor_type':'Integration','bypass_mode':'always'}],
                      'only the queue App may update the base branch')
            exclusive.append(rule)
        else:
            q.require(not rule['bypass_actors'],'protection ruleset must have no bypass actors')
            checks=types['required_status_checks']['parameters']
            q.require(checks['strict_required_status_checks_policy'] and not checks.get('do_not_enforce_on_create',False),
                      'strict up-to-date checks required')
            q.require({'context':GATE,'integration_id':p['app_id']} in checks['required_status_checks'],
                      'required gate must name the dedicated App source')
            q.require(types['pull_request']['parameters']['required_review_thread_resolution'], 'resolved conversations required')
            q.require(types['pull_request']['parameters']['allowed_merge_methods']==['rebase'], 'rebase-only merges required')
            q.require('deletion' in types and 'non_fast_forward' in types,'branch history protections required')
            protections.append(rule)
    q.require(len(protections)==1 and len(exclusive)==1,'two independent protection/update rulesets required')


def load_policy(path):
    p=json.loads(secure_file(path).read_text())
    q.identity(p['repo'],p['base'])
    for k in ('app_id','installation_id','app_actor_id','workflow_id'):
        q.require(q.integer(p[k]),'positive '+k+' required')
    for role in ('acceptance','refresh'):
        a=p[role]
        q.require(isinstance(a['command'],list) and len(a['command'])==1 and w.nonempty(a['command'][0]),
                  'one protected adapter wrapper executable required; configure arguments inside it')
        q.require(type(a['timeout']) is int and 1<=a['timeout']<=900,'bounded adapter timeout required')
        q.require(isinstance(a['env'],dict) and all(isinstance(k,str) and isinstance(v,str) for k,v in a['env'].items()),'explicit adapter environment required')
        q.require(not any(k in a['env'] for k in ('GH_TOKEN','GITHUB_TOKEN')),'controller adapters must not receive App tokens')
    q.require(p['author_uid']!=os.getuid() and p['reviewer_uid']!=os.getuid() and p['reviewer_uid']!=p['author_uid'],
              'dedicated controller, author and independent reviewer OS identities required')
    return p


def worker_receipt(args):
    """Run as the independent reviewer identity, through an operator-owned sudo adapter."""
    packet=json.loads(sys.stdin.read(1048577))
    expected=packet['snapshot']
    q.require(packet['binding']==q.digest(w.binding(expected)),'invalid requested binding')
    root=args.root.resolve()
    policy=w.load_policy(args.policy,root)
    read_path,binaries=protected_tools(policy.get('read_path'))
    home=protected_path(policy['roles']['acceptance']['env']['HOME'])
    # Use the reviewer's configured login store, never inherited tokens or startup
    # settings. Both observers and their Beads reads use the same protected tools.
    env={'PATH':read_path,'HOME':str(home),'GH_PROMPT_DISABLED':'1'}
    subprocess.run([binaries['bd'],'dolt','pull'],cwd=root,env=env,
                   stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90,check=True)
    ticket_reader=lambda ticket:q.read_ticket(root,ticket,env=env,executable=binaries['bd'])
    observer=w.Observer(root,env,ticket_reader=ticket_reader)
    fresh=observer.snapshot(expected['repository'],expected['number'])
    q.require(w.binding(fresh)==w.binding(expected),'acceptance source differs from requested candidate')
    db=w.Journal(w.trusted_path(args.state,root))
    try:
        w.bind_state(root,args.state)
        receipt=db.acceptance(fresh,policy)
        q.require(receipt and receipt['outcome']=='pass','independent worker acceptance unavailable')
        final=observer.snapshot(expected['repository'],expected['number'])
        q.require(w.binding(final)==w.binding(fresh),'acceptance changed during read')
        print(q.encoded({'outcome':'pass','job':receipt['job_id'],'binding':q.digest(w.binding(final)),
                        'reviewer_identity':policy['roles']['acceptance']['identity'],
                        'policy_hash':receipt['policy_hash']}))
    finally:db.close()
    return 0


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--policy',type=Path)
    parser.add_argument('--state',type=Path)
    parser.add_argument('--root',type=Path)
    sub=parser.add_subparsers(dest='command')
    en=sub.add_parser('enqueue'); en.add_argument('pr',type=int)
    retire=sub.add_parser('retire-request');retire.add_argument('pr',type=int);retire.add_argument('--reason',required=True)
    for name in ('tick','serve','status','preflight','worker-receipt'):sub.add_parser(name)
    retry=sub.add_parser('retry'); retry.add_argument('--reason',required=True)
    args=parser.parse_args()
    if args.self_test:
        result=subprocess.call([sys.executable,str(Path(__file__).with_name('queue-controller-tests.py'))])
        if not result:print('queue-controller self-test passed')
        return result
    q.require(args.policy and args.state and args.root and args.command,'--policy, --state, --root and command required')
    if args.command=='worker-receipt':
        return worker_receipt(args)
    p=load_policy(args.policy)
    q.require(args.state.resolve()==Path(p['state_dir']).resolve(),'use the canonical operator-configured state directory')
    root=protected_path(args.root)
    protected_path(Path(__file__).parent)
    protected_path(args.state.parent)
    w.outside(args.policy,root); w.outside(args.state,root)
    db=Journal(args.state)
    try:
        db.bind(p['repo'],p['base'])
        provider=Provider(p,root,db)
        ph=q.digest({'policy':p,'implementation':q.hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                     'observer':w.policy_hash({})})
        runner=Controller(db,provider,ph)
        if args.command=='enqueue':
            with db.lock():
                provider.observe(args.pr); db.enqueue(args.pr)
            print(q.encoded({'enqueued':args.pr,'merge_authorization':False}))
        elif args.command=='retire-request':
            db.retire_request(args.pr,args.reason)
            print(q.encoded({'retired_request':args.pr,'reason':args.reason,'remote_mutations':False}))
        elif args.command=='retry':
            with db.lock():
                a=db.active()
                q.require(a and a['phase']=='blocked','only a blocked attempt may be retried')
                q.require(provider.stopped(a),'cannot prove dispatched CI stopped; keep lane held')
                runner.block(a,a['reason'])
                a.update(phase='retired',recovery_reason=args.reason)
                db.save(a,retire=True)
            print('attempt retired; next tick retries the same selected PR')
        elif args.command=='status':print(q.encoded({'active':db.active(),'requests':db.requests()}))
        elif args.command=='preflight':provider.protections(); print('queue protections and trusted workflow verified')
        elif args.command=='tick':print(q.encoded(runner.tick()))
        else:
            while True:
                try: print(q.encoded(runner.tick()),flush=True)
                except Exception as exc:
                    # No retry of uncertain mutation. Persisted phase controls recovery.
                    print('queue-controller: '+type(exc).__name__,file=sys.stderr,flush=True)
                time.sleep(15)
    finally:db.close()
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except Exception as exc:
        print('queue-controller: '+str(exc),file=sys.stderr); sys.exit(1)
