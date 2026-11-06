#!/usr/bin/env python3
"""Read the isolated synthetic native peer after the real repair controls ran."""
import argparse,hashlib,json,uuid
from pathlib import Path
from datetime import datetime

def verify(path):
    data=Path(path).read_bytes();state=json.loads(data)
    account='ec990000-0000-4000-8000-000000000001';root_id='ec990000-0000-4000-8000-000000000002'
    root=state['root'];assert root['id']==root_id and root['user_id']==account
    assert state['adoptionApplied'] and state['repairWrites']==1
    rows=root['subtasks'];assert len(rows)==2 and rows[0]['id']=='review' and rows[1]['id']!='review';uuid.UUID(rows[1]['id'])
    assert rows[0]['completed'] and rows[0]['completed_at']=='2026-10-20T09:10:00Z' and rows[0]['completion_version']==1
    assert not rows[1]['completed'] and rows[1]['completion_version']==0 and rows[1]['future']=={'keep':True}
    receipts=list(state['repairReceipts'].values());assert len(receipts)==1
    receipt=receipts[0];b=receipt['body'];assert b['changes']==[{'kind':'separate_duplicate','path':[1],'keep_path':[0],'reference':rows[1]['id']}]
    original_text=receipt['original'];original=json.loads(original_text);result=receipt['result']
    assert result['state']=='applied' and result['archive_digest']==hashlib.sha256(original_text.encode()).hexdigest()
    assert result['archive_bytes']==len(original_text.encode()) and result['node_count']==2
    assert original['root']['subtasks']==[rows[0],{**rows[1],'id':'review'}]
    events=state['repairHistory'];assert original['child_history']==events
    retained=[e for e in events if e['node_key']=='review'];assert len(retained)==2
    completed=[e for e in retained if 'completed' in e['kinds']];assert len(completed)==1
    instant=lambda value:datetime.fromisoformat(value.replace('Z','+00:00'))
    assert instant(completed[0]['effective_at'])==instant(completed[0]['after_state']['completed_at'])
    assert not any(e['node_key']==rows[1]['id'] for e in events)
    assert any('coverage_gap' in e['kinds'] for e in events)
    assert all(e['task_id']==root_id and e['user_id']==account for e in events)
    assert len({e['id'] for e in events})==len(events)
    return {'status':'passed','scope':'native peer persistence; independent SQL authority acceptance remains separate','rootID':root_id,'peerSHA256':hashlib.sha256(data).hexdigest(),'historySHA256':hashlib.sha256(json.dumps(events,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'historyEvents':len(events),'retainedReferenceEvents':2,'retainedCompletionEvents':1,'coverageGapPreserved':True,'freshIdentityHasNoCopiedHistory':True,'keeperCompletionDatePreserved':True,'exactArchivedHistoryPreserved':True,'appliedWrites':1,'receipts':1,'archiveDigestVerified':True}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('peer',type=Path);p.add_argument('--output',type=Path);a=p.parse_args();result=verify(a.peer);text=json.dumps(result,indent=2)+'\n'
    if a.output:a.output.write_text(text)
    else:print(text,end='')
