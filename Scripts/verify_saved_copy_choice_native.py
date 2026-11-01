"""Read-only saved-data proof for the reserved synthetic copy-choice peer."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('peer', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
raw = args.peer.read_bytes()
state = json.loads(raw)
root = state['root']
assert root['id'] == 'ec990000-0000-4000-8000-000000000002'
assert root['user_id'] == 'ec990000-0000-4000-8000-000000000001'
assert root['task_generation'] == 'ec990000-0000-4000-8000-000000000003'
assert root['project_id'] is None and root['title'] == 'Native child workspace'

def child(key, title):
    return dict(id=key, title=title, description='Original saved notes', priority=4, completed=False, future={'keep': True})

first = child('concept', 'Prepare the review')
first['subtasks'] = [dict(id='nested', title='Collect supporting notes', description='Keep these nested instructions', future={'keep': True})]
original_tree = [first, child('review', 'Publish the summary')]
chosen_tree = json.loads(json.dumps(original_tree))
chosen_tree[0]['description'] = 'Stored subtask instructions'
assert root['subtasks'] == chosen_tree
assert state['repairWrites'] == 1 and state['adoptionApplied'] is True
for key in ['writes', 'adoptionWrites', 'adoptionRequests']:
    assert state.get(key, 0) == 0, key
assert not state.get('receipts') and not state.get('adoptionReceipts')
receipts = state['repairReceipts']
assert len(receipts) == 1
request_id, saved = next(iter(receipts.items()))
command, receipt = saved['body'], saved['result']
assert command['request_id'] == request_id and receipt['request_id'] == request_id
assert receipt['state'] == 'applied' and receipt['node_count'] == 3
assert len(command['changes']) == 1
choice = command['changes'][0]
assert choice['kind'] == 'choose_copy' and choice['source'] == 'records' and choice['path'] == []
assert len(choice['copy_digest']) == 64 and all(c in '0123456789abcdef' for c in choice['copy_digest'])
original_bytes = saved['original'].encode()
assert len(original_bytes) == receipt['archive_bytes']
assert hashlib.sha256(original_bytes).hexdigest() == receipt['archive_digest']
original = json.loads(original_bytes)
old_root = json.loads(json.dumps(root)); old_root['subtasks'] = original_tree
assert original['root'] == old_root and original['copy_choice'] == choice
assert original['review_digest'] == command['review_digest'] and original['repair_digest'] == command['repair_digest']
snapshot_tree = json.loads(json.dumps(original_tree)); snapshot_tree[0]['description'] = 'Saved snapshot instructions'
assert original['projection']['source_tree'] == snapshot_tree
assert len(original['records']) == 3
assert original['records'][0]['fields'] == chosen_tree[0]
assert original['records'][1]['fields'] == chosen_tree[0]['subtasks'][0]
assert original['records'][2]['fields'] == chosen_tree[1]
assert original['authority']['task_id'] == root['id']
assert original['root_history'] == [] and original['child_history'] == state.get('repairHistory', [])
proof = dict(passed=True, oneAppliedRepair=True, selectedStoredCopyExact=True, allThreeOriginalCopiesRetained=True,
             originalHashAndLengthVerified=True, nestedAndUnknownFieldsPreserved=True, noUnrelatedWrites=True,
             peerSHA256=hashlib.sha256(raw).hexdigest(),
             scope='Synthetic file-backed native controls and persistence; real SQL authorization/atomicity and historical custody verified separately')
args.output.write_text(json.dumps(proof, indent=2) + '\n')
print('Saved-copy choice native persistence proof passed')
