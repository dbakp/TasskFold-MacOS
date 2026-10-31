#!/usr/bin/env python3
"""Verify the reserved synthetic peer after a field-history acceptance journey.

Read-only: this neither launches an app nor changes a task or Simulator.
"""
import argparse
import hashlib
import json
from pathlib import Path


def verify(path: Path) -> dict:
    raw = path.read_bytes()
    state = json.loads(raw)
    root = state['root']
    assert root['user_id'] == 'ec990000-0000-4000-8000-000000000001'
    assert root['id'] == 'ec990000-0000-4000-8000-000000000002'
    assert state['writes'] == state['requests'] == 4
    entries = sorted(state['receipts'].values(), key=lambda row: row['receipt']['revision'])
    assert len(entries) == 4
    commands = [row['body'] for row in entries]
    assert len({row['request_id'] for row in commands}) == 4
    estimate = 'duration_minutes' in commands[0]['changes']
    assert [row['protocol'] for row in commands] == ([1, 2, 1, 2] if estimate else [1, 1, 1, 1])
    assert [row['revision'] for row in commands] == [1, 2, 3, 4]
    assert [row['receipt']['revision'] for row in entries] == [2, 3, 4, 5]
    expected_edit = {'title': 'Field history proof'}
    if estimate:
        expected_edit['duration_minutes'] = 30
    assert commands[0]['changes'] == commands[2]['changes'] == expected_edit
    assert commands[1]['changes'] == commands[3]['changes'] == {'title': 'Prepare the review'}
    assert commands[1].get('remove_fields', []) == commands[3].get('remove_fields', []) == (['duration_minutes'] if estimate else [])
    expected = [
        {'id': 'concept', 'title': 'Prepare the review', 'description': 'Original saved notes',
         'priority': 4, 'completed': False, 'future': {'keep': True}},
        {'id': 'review', 'title': 'Publish the summary', 'description': 'Original saved notes',
         'priority': 4, 'completed': False, 'future': {'keep': True}},
    ]
    assert root['subtasks'] == expected
    assert state['versions'] == {'concept': 5, 'review': 1}
    for command, row in zip(commands, entries):
        proof = row['receipt']
        for key in ['protocol', 'account', 'request_id', 'task_id', 'task_generation', 'project_id', 'node_key', 'incarnation']:
            assert proof[key] == command[key]
        assert command['account'] == root['user_id'] and command['task_id'] == root['id']
        assert command['task_generation'] == root['task_generation'] and command['project_id'] == root['project_id']
        assert command['node_key'] == 'concept' and command['incarnation'] == 'ec990000-0000-4000-8000-000000000005'
    return {
        'status': 'passed', 'requests': 4, 'writes': 4, 'freshIdentities': 4,
        'sequence': ['edit', 'undo', 'redo', 'undo'],
        'finalFieldsExact': True, 'estimateEditAndRemovalExercised': estimate,
        'absentEstimateRestoredExactly': True if estimate else None,
        'untouchedSiblingVersion': 1, 'editedNodeVersion': 5,
        'scope': 'Reserved synthetic native HTTP peer; not hosted SQL or real shared-account acceptance',
        'peerSHA256': hashlib.sha256(raw).hexdigest(),
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('state', type=Path, help='Exported synthetic server.json')
    parser.add_argument('--output', type=Path, help='Optional proof output; the input is never modified')
    args = parser.parse_args()
    report = json.dumps(verify(args.state), indent=2) + '\n'
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end='')
