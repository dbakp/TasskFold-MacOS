#!/usr/bin/env python3
"""Read only the isolated ordering fixture; export ledger metadata, not task text."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path

def verify(path):
    raw=Path(path).read_bytes();snapshot=json.loads(raw);tables=snapshot['tables']
    root=next(r for r in tables['tasks'] if r['id']=='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa75')
    assert root['user_id']=='ui-testing' and root['task_generation']=='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa90'
    assert [n['id'] for n in root['subtasks']]==['companion','concept']
    assert root['subtasks'][1]['description']=='Keep these revised instructions private' and root['subtasks'][1]['priority']==1
    events=tables['task_node_activity'];assert len(events)==4 and len({e['id'] for e in events})==4
    orders=[e for e in events if e['format_version']==3];assert len(orders)==1
    event=orders[0];assert event['kinds']==['reordered'] and event['node_key']==''
    assert event['order_context']=={'before':['concept','companion'],'after':['companion','concept']}
    assert event['before_path']==event['after_path']==[] and event['before_state']==event['after_state']
    assert event['actor_id']==event['user_id']=='ui-testing' and event['completion_version']==0
    assert not event['work_before'] and not event['work_after'] and event['recorded_at']==event['effective_at']
    assert all(e['task_id']==root['id'] and e['task_generation']==root['task_generation'] for e in events)
    assert sum(e['kinds']==['edited'] for e in events)==1 and sum(e['kinds']==['created'] for e in events)==2
    assert not any('completed' in e['kinds'] or 'reopened' in e['kinds'] for e in events)
    epoch=tables['task_node_activity_epoch'];assert len(epoch)==1 and epoch[0]['id']=='current'
    instant=lambda s:datetime.fromisoformat(s.replace('Z','+00:00'))
    assert instant(epoch[0]['order_recorded_from'])>instant(epoch[0]['field_recorded_from'])>instant(epoch[0]['recorded_from'])
    text=json.dumps(events)
    for private in ['Keep these revised instructions private','Keep these original instructions private','Prepare the concept','Review the companion sketch']:assert private not in text
    assert not snapshot.get('pending',[])
    return {'status':'passed','nodeEvents':4,'orderingEntries':1,'editEntries':1,'oneEntryForList':True,'currentOrderPreserved':True,'noCompletionCreditInvented':True,'privateContentAbsent':True,'noPendingNetworkMutations':True,'snapshotSHA256':hashlib.sha256(raw).hexdigest()}, {'events':events,'epoch':epoch,'pendingCount':0}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('snapshot',type=Path);parser.add_argument('--output',type=Path);parser.add_argument('--state-output',type=Path);args=parser.parse_args()
    report,state=verify(args.snapshot);result=json.dumps(report,indent=2)+'\n'
    if args.output:args.output.write_text(result)
    else:print(result,end='')
    if args.state_output:args.state_output.write_text(json.dumps(state,indent=2)+'\n')
