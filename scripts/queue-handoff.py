#!/usr/bin/env python3
"""Existing-agent handoff. Uses the agent's GitHub login; never reads the queue App key."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('queue_controller',Path(__file__).with_name('queue-controller.py'))
c=importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
q,w=c.q,c.w


def selected(checks,s,app_id):
    rows=[r for r in checks if r.get('name')==c.SELECTION and r.get('app',{}).get('id')==app_id]
    q.require(rows,'no App selection for this head; waiting PRs must not refresh')
    r=max(rows,key=lambda x:x['id'])
    q.require(r['status']=='in_progress' and r['head_sha']==s['head'],'selection is no longer active')
    packet=json.loads(r['output']['summary'])
    q.require(r['external_id']=='queue-selection-v1:'+q.digest(packet),'selection identity mismatch')
    q.require(all(packet.get(k)==s[k] for k in ('repository','number','head','base_sha')) and
              packet.get('kind')==c.SELECTION and q.re.fullmatch('[0-9a-f]{32}',packet.get('attempt','')),
              'selection belongs to another candidate or base')
    return packet


def publish(observer,s,mode,proof_url=None,expected=None):
    if mode=='accept':
        c.reviewed(s)
        binding=q.digest(w.binding(s))
        q.require(expected==binding,'evidence changed since independent assessment; reassess before accepting')
        prefix='https://github.com/'+s['repository']+'/pull/'+str(s['number'])+'#pullrequestreview-'
        q.require(isinstance(proof_url,str) and proof_url.startswith(prefix),'assessment review URL required')
        user=observer.get('user')
        review=observer.get('repos/'+s['repository']+'/pulls/'+str(s['number'])+'/reviews/'+proof_url[len(prefix):])
        q.require(review['user']['id']==user['id'] and review['commit_id']==s['head'] and
                  review['state']=='COMMENTED' and w.nonempty(review['body']),
                  'cite your submitted independent assessment on this exact head')
        data=dict(state='success',context=c.ACCEPTANCE,description='queue-acceptance-v1:'+binding,target_url=proof_url)
    else:
        c.reviewed(s)
        data=dict(state='success',context=c.NOMINATION,description='queue-nomination-v1')
    path='repos/'+s['repository']+'/statuses/'+s['head']
    args=['api','--method','POST',path]
    for key,value in data.items():args+=['-f',key+'='+value]
    # Unchanged requests reuse their existing status. A latest failure is never ignored.
    latest=c.latest_status(observer.pages('repos/'+s['repository']+'/commits/'+s['head']+'/statuses?per_page=100'),data['context'])
    user=observer.get('user')
    if latest and latest.get('creator',{}).get('id')==user['id'] and all(latest.get(k)==v for k,v in data.items()):
        return dict(status_id=latest['id'],reused=True,merge_authorization=False)
    result=observer.command(args)
    return dict(status_id=result['id'],reused=False,merge_authorization=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--root',type=Path,default=Path.cwd())
    parser.add_argument('--pr',type=int)
    parser.add_argument('--proof-url')
    parser.add_argument('--binding')
    parser.add_argument('--app-id',type=int)
    parser.add_argument('command',nargs='?',choices=['inspect','nominate','accept','selected'])
    a=parser.parse_args()
    if a.self_test:return subprocess.call([sys.executable,str(Path(__file__).with_name('queue-handoff-tests.py')),'--self-test'])
    q.require(a.pr and a.command,'--pr and command required')
    subprocess.run(['bd','dolt','pull'],cwd=a.root,check=True,stdout=sys.stderr)
    observer=w.Observer(a.root)
    repo=observer.command(['repo','view','--json','nameWithOwner'])['nameWithOwner']
    s=observer.snapshot(repo,a.pr)
    if a.command=='inspect':out=dict(snapshot=s,binding=q.digest(w.binding(s)))
    elif a.command=='selected':
        q.require(q.integer(a.app_id),'--app-id must come from the trusted operator configuration')
        pages=observer.command(['api','--method','GET','repos/'+repo+'/commits/'+s['head']+
                               '/check-runs?filter=all&per_page=100','--paginate','--slurp'])
        q.require(isinstance(pages,list) and all(isinstance(p.get('check_runs'),list) for p in pages),
                  'incomplete selection check inventory')
        checks=[r for page in pages for r in page['check_runs']]
        out=selected(checks,s,a.app_id)
    else:out=publish(observer,s,a.command,a.proof_url,a.binding)
    print(q.encoded(out))
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except Exception as exc:print('queue-handoff: '+str(exc),file=sys.stderr);sys.exit(1)
