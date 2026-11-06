#!/usr/bin/env python3
"""Read only the owned grouped-activity fixture and export ledger metadata."""
import argparse
from datetime import datetime
import hashlib,json,uuid
from pathlib import Path

def verify(path):
    raw=Path(path).read_bytes();snapshot=json.loads(raw);tables=snapshot['tables']
    ids=['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa93','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa94']
    tasks={row['id']:row for row in tables['tasks']}
    assert all(tasks[key]['user_id']=='ui-testing' and tasks[key]['completed'] for key in ids)
    events=tables['task_activity'];grouped=[e for e in events if e.get('operation_context')]
    assert len(grouped)==2 and set(e['task_id'] for e in grouped)==set(ids)
    assert len(set(e['id'] for e in events))==len(events)
    contexts=[e['operation_context'] for e in grouped];assert contexts[0]==contexts[1]
    context=contexts[0];assert set(context)=={'version','origin','id'} and context['version']==1 and context['origin']=='local_commit';uuid.UUID(context['id'])
    instant=lambda text:datetime.fromisoformat(text.replace('Z','+00:00'))
    for event in grouped:
        assert event['kinds']==['completed'] and event['actor_id']==event['user_id']=='ui-testing'
        assert not event['before_state']['completed'] and event['after_state']['completed']
        assert instant(event['effective_at'])==instant(event['after_state']['completed_at'])==instant(tasks[event['task_id']]['completed_at'])
        assert event['completion_version']==tasks[event['task_id']]['completion_version']
    assert not snapshot.get('pending',[])
    assert 'Prepare the study' not in json.dumps(grouped) and 'Send the summary' not in json.dumps(grouped)
    return {'status':'passed','groupedEntries':2,'groups':1,'origin':'local_commit','chosenInstantsPreserved':True,'exactCurrentCompletionPreserved':True,'privateTextAbsentFromLedger':True,'noPendingNetworkMutations':True,'snapshotSHA256':hashlib.sha256(raw).hexdigest()}, {'events':events,'pendingCount':0}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('snapshot',type=Path);parser.add_argument('--output',type=Path);parser.add_argument('--state-output',type=Path);args=parser.parse_args();report,state=verify(args.snapshot);text=json.dumps(report,indent=2)+'\n'
    if args.output:args.output.write_text(text)
    else:print(text,end='')
    if args.state_output:args.state_output.write_text(json.dumps(state,indent=2)+'\n')
