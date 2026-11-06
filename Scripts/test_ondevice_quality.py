#!/usr/bin/env python3
"""Explicit real on-device probe using only fixed synthetic goals; no app-data access or saved-task writes."""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["Taskfold/Core/OnDeviceAssistance.swift", "Taskfold/Core/TaskBreakdown.swift", "Taskfold/Core/FilterAssistance.swift", "TaskfoldTests/TaskBreakdownTests.swift", "TaskfoldTests/FilterAssistanceTests.swift"]

def hashes():
    return {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-model', action='store_true', help='Explicitly permit inference on the six built-in synthetic examples')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not args.run_model:
        parser.error('Use --run-model to explicitly request synthetic on-device inference')
    output = args.output.resolve()
    if output.parent != Path('/tmp').resolve() or not output.name.startswith('taskfold-') or output.suffix != '.json':
        parser.error('Choose a new /tmp/taskfold-*.json report')
    log = output.with_suffix('.log')
    if output.exists() or log.exists():
        parser.error('Preserve earlier evidence; choose a new report name')
    subprocess.run([sys.executable, str(ROOT/'Scripts/check_test_storage.py'), '--path', '/tmp'], check=True)
    before = hashes()
    report = {'schema': 1, 'owner': ROOT.name, 'execution': 'Mac-hosted owning Core', 'syntheticOnly': True,
              'savedTaskOrFilterWrites': False, 'cloudInferenceFallback': False, 'realGenerationAccepted': False,
              'sourceSHA256': before, 'driverSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'observations': []}
    environment = dict(os.environ, TASKFOLD_TEST_ON_DEVICE_MODEL='1')
    selection = 'TaskBreakdownTests/testActualOnDeviceEngineWhenExplicitlyRequested|FilterAssistanceTests/testActualOnDeviceFilterEngineWhenExplicitlyRequested'
    with log.open('x') as stream:
        log.chmod(0o600)
        try:
            worker = subprocess.Popen(['bash', 'Scripts/test_core.sh', '--filter', selection], cwd=ROOT, env=environment,
                                      stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            report['testExitCode'] = worker.wait(timeout=600)
        except subprocess.TimeoutExpired:
            # The new session contains only this probe and its compiler/test children.
            # Signal this owned group without targeting shared system model services.
            os.killpg(worker.pid, signal.SIGTERM)
            try: worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(worker.pid, signal.SIGKILL)
                worker.wait()
            report['testExitCode'] = None
            report['error'] = 'The synthetic probe exceeded its ten-minute process limit.'
    text = log.read_text()
    report['logSHA256'] = hashlib.sha256(log.read_bytes()).hexdigest()
    report['sourcesUnchanged'] = hashes() == before
    try:
        report['observations'] = [json.loads(line.removeprefix('TASKFOLD_MODEL_OBSERVATION ')) for line in text.splitlines() if line.startswith('TASKFOLD_MODEL_OBSERVATION ')]
    except ValueError:
        report['error'] = 'The model observation log could not be parsed.'
    report['unavailableReasons'] = sorted(set(line.partition('_MODEL_UNAVAILABLE ')[2] for line in text.splitlines() if '_MODEL_UNAVAILABLE ' in line))
    counts = {engine: sum(row.get('engine') == engine for row in report['observations']) for engine in ['steps', 'filter']}
    report['semanticAndShapeChecksPassed'] = report.get('testExitCode') == 0 and counts == {'steps': 3, 'filter': 3} and 'TASK_BREAKDOWN_MODEL_ACCEPTED' in text and 'FILTER_ASSISTANCE_MODEL_ACCEPTED' in text
    report['realGenerationAccepted'] = bool(report['semanticAndShapeChecksPassed'] and report['sourcesUnchanged'] and not report['unavailableReasons'] and not report.get('error'))
    # Useful action-title quality and language still need inspection of the actual
    # outputs; parse/count success must not masquerade as a general quality audit.
    report['taskTitleQualityReviewed'] = False
    with output.open('x') as stream:
        output.chmod(0o600)
        json.dump(report, stream, indent=2, ensure_ascii=False)
        stream.write('\n')
    print(json.dumps({'realGenerationAccepted': report['realGenerationAccepted'], 'testExitCode': report.get('testExitCode'), 'observations': len(report['observations']), 'unavailableReasons': report['unavailableReasons'], 'report': str(output)}))
    return 0 if report['realGenerationAccepted'] else 2 if report.get('testExitCode') == 0 and report['unavailableReasons'] and report['sourcesUnchanged'] and not report.get('error') else 1

if __name__ == '__main__':
    sys.exit(main())
