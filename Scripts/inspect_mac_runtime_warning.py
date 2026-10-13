#!/usr/bin/env python3
"""Inspect archived QoS warnings without launching or changing any application.

Uses UUID-matched image offsets to relocate archived frames into a live reference
process. Raw historical virtual addresses must not be symbolicated against a
new process: its shared-cache slide may differ. Missing images stay unresolved.
The output never converts a warning-bearing XCTest run into a clean run.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def inspect(result, reference_pid):
    image_text = run(['xcrun', 'symbols', '-uuid', '-noSymbols', '-noSources', str(reference_pid)])
    mapping_text = run(['vmmap', '-w', str(reference_pid)])
    images = {m.group(1): m.group(2) for m in re.finditer(
        r'^\s+([0-9A-F-]{36})\s+arm64e?\s+(.+?) \[', image_text, re.M)}
    bases = {m.group(2): int(m.group(1), 16) for m in re.finditer(
        r'^__TEXT\s+([0-9a-f]+)-[^\n]+?\s(/(?:System|usr)/[^\n]+)$', mapping_text, re.M)}
    test_tree = json.loads(run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(result)]))
    def qos_warnings(node):
        if isinstance(node, dict):
            count = int(node.get('nodeType') == 'Runtime Warning' and 'quality-of-service' in node.get('name', ''))
            return count + sum(qos_warnings(value) for value in node.values())
        if isinstance(node, list):
            return sum(qos_warnings(value) for value in node)
        return 0
    reported_warnings = qos_warnings(test_tree)
    events = []
    seen = set()
    with tempfile.TemporaryDirectory(prefix='taskfold-runtime-attribution-') as temp:
        run(['xcrun', 'xcresulttool', 'export', 'diagnostics', '--path', str(result), '--output-path', temp])
        for archive in Path(temp).rglob('*.logarchive'):
            raw = run(['/usr/bin/log', 'show', '--archive', str(archive), '--style', 'json',
                       '--predicate', 'eventMessage CONTAINS "priority inversion"', '--info', '--debug'])
            for event in json.loads(raw):
                key = (event.get('timestamp'), event.get('processID'), event.get('threadID'))
                if key in seen:
                    continue
                seen.add(key)
                frames = []
                for frame in event.get('backtrace', {}).get('frames', []):
                    path = images.get(frame['imageUUID'])
                    base = bases.get(path)
                    frames.append({'uuid': frame['imageUUID'], 'offset': frame['imageOffset'],
                                   'image': path, 'relocatedAddress': hex(base + frame['imageOffset']) if base else None})
                known = [f for f in frames if f['relocatedAddress']]
                if known:
                    symbols = run(['xcrun', 'atos', '-arch', 'arm64e', '-p', str(reference_pid)] +
                                  [f['relocatedAddress'] for f in known]).splitlines()
                    if len(symbols) != len(known):
                        raise ValueError('Unexpected symbolication frame count')
                    for frame, symbol in zip(known, symbols):
                        frame['symbol'] = symbol
                message = event.get('eventMessage', '')
                match = re.search(r'____message__:(\{.*?\})', message)
                metadata = json.loads(match.group(1)) if match else {}
                symbols = '\n'.join(f.get('symbol', '') for f in frames)
                events.append({'timestamp': event.get('timestamp'),
                               'process': Path(event.get('processImagePath', '')).name,
                               'processUUID': event.get('processImageUUID'),
                               'sender': event.get('senderImagePath'),
                               'metadata': metadata, 'frames': frames,
                               'dataDetectorsServicesMenuInspectionObserved':
                                   all(s in symbols for s in ['_getDataDetectorsScanner', '_NSServicesMenuUpdater', 'NSMenu(Accessibility)'])})
    return {'resultBundle': result.name, 'referencePID': reference_pid,
            'method': 'UUID-matched current image base plus archived image offset; atos reads the live process only. Missing images remain unresolved.',
            'reportedQoSWarningCount': reported_warnings,
            'archivedQoSEventCount': len(events),
            'archiveCoversReportedWarnings': len(events) >= reported_warnings, 'events': events,
            'limits': ['Historical runtime warnings remain recorded; no clean-runtime pass is inferred.',
                       'Zero matching archived events does not mean zero reported warnings. Missing archival coverage remains unclassified.',
                       'A known system stack is evidence of the observed trigger, not proof that every hang has this cause.',
                       'No app launch, input, network request or persistent data mutation occurs.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--reference-pid', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.reference_pid <= 0 or not args.result.is_dir():
        parser.error('An existing result bundle and positive live reference PID are required')
    report = inspect(args.result, args.reference_pid)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': args.result.name, 'reportedWarnings': report['reportedQoSWarningCount'], 'archivedEvents': report['archivedQoSEventCount'],
                      'servicesMenuInspection': [e['dataDetectorsServicesMenuInspectionObserved'] for e in report['events']]}))
