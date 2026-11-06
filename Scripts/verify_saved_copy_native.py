"""Read-only proof for the reserved native saved-copy comparison fixture."""
import argparse, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('peer',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
raw=a.peer.read_bytes();state=json.loads(raw);root=state['root']
assert root['id']=='ec990000-0000-4000-8000-000000000002'
assert root['user_id']=='ec990000-0000-4000-8000-000000000001'
assert root['task_generation']=='ec990000-0000-4000-8000-000000000003'
assert root['project_id'] is None and root['title']=='Native child workspace'
def child(key,title):return dict(id=key,title=title,description='Original saved notes',priority=4,completed=False,future={'keep':True})
first=child('concept','Prepare the review');first['subtasks']=[dict(id='nested',title='Collect supporting notes',description='Keep these nested instructions',future={'keep':True})]
assert root['subtasks']==[first,child('review','Publish the summary')]
for key in ['writes','requests','adoptionWrites','adoptionRequests','repairWrites','repairRequests']:
 assert state.get(key,0)==0,(key,state.get(key))
for key in ['receipts','adoptionReceipts','repairReceipts','repairOriginals']:
 assert not state.get(key),(key,state.get(key))
for text in ['Saved snapshot instructions','Stored subtask instructions']:
 assert text not in raw.decode(), 'Comparison-only content entered saved peer state'
proof={'passed':True,'rootAndNestedOriginalUnchanged':True,'originalUnknownFieldsPreserved':True,'noFieldAdoptionOrRepairWrites':True,'noNewReceiptsOrArchives':True,'comparisonContentNotPersisted':True,'peerSHA256':hashlib.sha256(raw).hexdigest(),'scope':'Synthetic file-backed native peer; database access and exact SQL exports verified separately'}
a.output.write_text(json.dumps(proof,indent=2)+'\n');print('Saved-copy native persistence proof passed')
