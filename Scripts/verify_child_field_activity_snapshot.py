#!/usr/bin/env python3
"""Verify the isolated activity fixture's persisted cache; never change app data."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path


def verify(path):
    raw=Path(path).read_bytes();snapshot=json.loads(raw);tables=snapshot['tables']
    root=next(r for r in tables['tasks'] if r['id']=='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa75')
    assert root['user_id']=='ui-testing' and root['task_generation']=='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa90'
    assert root['subtasks'][0]['id']=='concept'
    assert root['subtasks'][0]['description']=='Keep these revised instructions private'
    assert root['subtasks'][0]['priority']==1
    events=tables['task_node_activity'];assert len(events)==2
    assert len({e['id'] for e in events})==2
    events=sorted(events,key=lambda e:e['sequence'])
    assert [e['kinds'] for e in events]==[['created'],['edited']]
    assert [e['format_version'] for e in events]==[1,2]
    event=events[1];assert event['changed_fields']==['description','priority']
    assert event['actor_id']==event['user_id']=='ui-testing'
    assert event['task_id']==root['id'] and event['task_generation']==root['task_generation']
    assert event['before_state']==event['after_state']
    assert event['recorded_at']==event['effective_at']
    assert all(e['node_key']=='concept' for e in events)
    epoch=tables['task_node_activity_epoch'];assert len(epoch)==1 and epoch[0]['id']=='current'
    instant=lambda s:datetime.fromisoformat(s.replace('Z','+00:00'))
    assert instant(epoch[0]['field_recorded_from'])>instant(epoch[0]['recorded_from'])
    text=json.dumps(events)
    assert 'Keep these revised instructions private' not in text and 'Keep these original instructions private' not in text
    assert not snapshot.get('pending',[])
    report={'status':'passed','nodeEvents':2,'editEntries':1,'actualFields':['description','priority'],'planningStateUnchanged':True,'noCompletionEventsInvented':True,'privateContentAbsentFromLedger':True,'currentTaskContentPreserved':True,'noPendingNetworkMutations':True,'snapshotSHA256':hashlib.sha256(raw).hexdigest(),'scope':'Owned local synthetic workspace, actual SwiftUI and durable cache; SQL acceptance is separate'}
    return report,{'events':events,'epoch':epoch,'pendingCount':0}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('snapshot',type=Path);parser.add_argument('--output',type=Path);parser.add_argument('--state-output',type=Path);args=parser.parse_args()
    report,state=verify(args.snapshot)
    result=json.dumps(report,indent=2)+'\n'
    if args.output:args.output.write_text(result)
    else:print(result,end='')
    if args.state_output:args.state_output.write_text(json.dumps(state,indent=2)+'\n')
