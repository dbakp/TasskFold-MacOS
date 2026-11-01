#!/usr/bin/env python3
"""Check actual native move/assignee/Undo/Redo snapshots without losing JSON precision."""
import argparse
import copy
import json
from pathlib import Path
from verify_assignment_native import ROOT, SOURCE, DESTINATION, TOKENS, require, load, digest, same, root, clear


def verify(directory, summary_path):
    summary_bytes = summary_path.read_bytes()
    summary = load(summary_bytes)
    require(summary['result'] == 'Passed' and summary['passedTests'] == 1 and
            all(summary.get(key, 0) == 0 for key in ('failedTests', 'skippedTests', 'expectedFailures')), 'Require the native history test to pass without skips')
    require(len(summary['devicesAndConfigurations']) == 1, 'Require one native destination')
    device = summary['devicesAndConfigurations'][0]['device']
    directory = directory.resolve()
    manifest_bytes = (directory / 'manifest.json').read_bytes()
    groups = load(manifest_bytes)
    require(len(groups) == 1 and groups[0]['testIdentifier'].endswith('/testProjectMoveExplicitAssigneeUndoRedoAndColdReturn()'), 'Unexpected test scope')
    snapshots, proofs = {}, []
    for label in ('original', 'moved', 'undone', 'redone', 'cold return'):
        chosen = [a for a in groups[0]['attachments'] if a['suggestedHumanReadableName'].startswith('Explicit assignment ' + label)]
        require(len(chosen) == 1, 'Missing or duplicate snapshot: ' + label)
        item = chosen[0]
        path = (directory / item['exportedFileName']).resolve()
        require(path.parent == directory and path.suffix == '.json', 'Unsafe attachment path')
        require(item['deviceId'] == device['deviceId'], 'Wrong native destination')
        data = path.read_bytes()
        snapshots[label] = load(data)
        for token in TOKENS:
            require(token.encode() in data, 'Exact source token missing: ' + label)
        proofs.append({'name': label, 'sha256': digest(data), 'bytes': len(data)})
    original = root(snapshots['original'])
    require(original['project_id'] == SOURCE and original['assigned_to'] == 'ui-testing', 'Wrong source project/owner')
    for label in ('moved', 'undone', 'redone', 'cold return'):
        expected = copy.deepcopy(original)
        expected['project_id'] = SOURCE if label == 'undone' else DESTINATION
        expected['section_id'] = None
        clear(expected['subtasks'])
        require(same(root(snapshots[label]), expected), 'Unexpected root/child change: ' + label)
        require(snapshots[label].get('pending') == [], 'Unexpected local pending writes')
        for table in ('projects', 'sections'):
            require(same(snapshots[label]['tables'].get(table), snapshots['original']['tables'].get(table)), 'Unrelated rows changed')
    require(same(snapshots['redone'], snapshots['cold return']), 'Cold return changed saved snapshot')
    return {'passed': True, 'device': device, 'summarySHA256': digest(summary_bytes), 'manifestSHA256': digest(manifest_bytes),
            'scope': 'Synthetic local native project/assignee controls, actual Undo/Redo and cold return; historical child assignees remain cleared; no hosted delivery or speech claim',
            'fullRootAndExactChildValuesVerified': True, 'fullSnapshotColdReturnVerified': True, 'snapshots': proofs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('attachments', type=Path)
    parser.add_argument('summary', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = {'passed': False}
    try:
        result = verify(args.attachments, args.summary)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        result['error'] = str(error)
        raise SystemExit(str(error))
    finally:
        args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print('Verified native root-assignee history and five lossless snapshots')


if __name__ == '__main__':
    main()
