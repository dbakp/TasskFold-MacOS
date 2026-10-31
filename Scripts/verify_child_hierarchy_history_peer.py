#!/usr/bin/env python3
"""Verify an exported hierarchy Undo/Redo native peer; no app data is changed."""
import argparse
import hashlib
import json
from pathlib import Path


def verify(path):
    raw=Path(path).read_bytes()
    s=json.loads(raw)
    assert s.get('structureWrites')==4 and s.get('structureRequests')==4, s
    assert s['writes']==0 and s['requests']==0
    entries=sorted(s['structureReceipts'].values(),key=lambda e:e['receipt']['after_revision'])
    assert len(entries)==4
    commands=[e['body'] for e in entries]
    action=commands[0]['action']
    assert [c['action'] for c in commands]==[action,'undo',action,'undo']
    assert len({c['request_id'] for c in commands})==4
    assert commands[1]['undo_of']==commands[0]['request_id']
    assert commands[3]['undo_of']==commands[2]['request_id']
    assert [c['structure_revision'] for c in commands]==[1,2,3,4]
    assert [e['receipt']['after_revision'] for e in entries]==[2,3,4,5]
    assert s.get('structureArchives',{})=={}
    root=s['root']
    assert root['user_id']=='ec990000-0000-4000-8000-000000000001'
    assert root['id']=='ec990000-0000-4000-8000-000000000002'
    assert root['task_generation']=='ec990000-0000-4000-8000-000000000003'
    for command in commands:
        assert command['protocol']==1 and command['account']==root['user_id']
        assert command['task_id']==root['id'] and command['task_generation']==root['task_generation']
        assert command['project_id']==root['project_id']
    if action=='insert':
        assert commands[0]['node']==commands[2]['node']
        assert commands[0]['node']['title']=='Hierarchy history proof'
    elif action=='move':
        assert commands[0]['node_key']==commands[2]['node_key']=='concept'
        assert commands[0]['parent_key']==commands[2]['parent_key']=='review'
        assert commands[0]['index']==commands[2]['index']
    else:
        assert action=='delete'
        assert commands[0]['node_key']==commands[2]['node_key']=='concept'
        assert set(commands[2]['subtree_versions'])=={'concept','nested'}
        assert all(v['revision']==1 for v in commands[2]['subtree_versions'].values())
        assert commands[0]['incarnation']!=commands[2]['incarnation']
    expected=[{'id':'concept','title':'Prepare the review','description':'Original saved notes','priority':4,'completed':False,'future':{'keep':True}}, {'id':'review','title':'Publish the summary','description':'Original saved notes','priority':4,'completed':False,'future':{'keep':True}}]
    if action=='delete':
        expected[0]['subtasks']=[{'id':'nested','title':'Collect supporting notes','description':'Keep these nested instructions','future':{'keep':True}}]
    # Restoring deletion refreshes completion identity metadata by contract.
    def authored(node):
        if isinstance(node,list):return [authored(x) for x in node]
        if isinstance(node,dict):return {k:authored(v) for k,v in node.items() if k!='taskfold_completion_v1'}
        return node
    assert authored(s['root']['subtasks'])==expected, s['root']['subtasks']
    return {'status':'passed','requests':4,'writes':4,'freshIdentities':4,'sequence':[action,'undo','redo','undo'],'finalAuthoredTreeExact':True,'latestArchiveConsumed':True,'scope':'Synthetic native HTTP peer; not hosted SQL or real shared-account acceptance','peerSHA256':hashlib.sha256(raw).hexdigest()}


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('state',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    result=json.dumps(verify(args.state),indent=2)+'\n'
    if args.output: args.output.write_text(result)
    else: print(result,end='')
