#!/usr/bin/env python3
"""Actual capture controller, codec and vault, using synthetic media drivers only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
products = args.scratch.resolve() / 'debug'
sources = ['Taskfold/AudioSessionLease.swift', 'Taskfold/AudioCommentMedia.swift', 'Taskfold/AudioCommentCapture.swift', 'Scripts/fixtures/AudioCommentCaptureProof.swift']
with tempfile.TemporaryDirectory(prefix='taskfold-audio-controller-') as directory:
    directory = Path(directory); executable = directory / 'proof'; root = directory / 'storage'; root.mkdir()
    command = ['swiftc', '-parse-as-library', '-swift-version', '5', '-D', 'AUDIO_COMMENT_CONTROLLER_TESTING', '-enable-testing', '-I', str(products), '-L', str(products), '-lTaskfoldCore'] + [str(repo / path) for path in sources] + ['-o', str(executable)]
    result = subprocess.run(command, text=True, capture_output=True, timeout=60)
    if result.returncode: raise RuntimeError(result.stderr)
    warnings = [line for line in result.stderr.splitlines() if "warning:" in line]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run([str(executable), str(root), str(repo / 'TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a'), str(args.output.resolve())], text=True, capture_output=True, timeout=60)
    if result.returncode: raise RuntimeError(result.stdout + result.stderr)
checks = json.loads(args.output.read_text())
args.output.write_text(json.dumps({'checks': checks, 'compilerWarnings': warnings, 'sources': {path: hashlib.sha256((repo / path).read_bytes()).hexdigest() for path in sources}, 'limits': ['Mac executable with actual controller/Core codec/vault and synthetic recorder/player; no microphone, permission dialog or sound output.', 'Real recorder and player tested only with a false context or occupied lease, before hardware/permission access.', 'Native UI, actual capture/playback/interruption/TCC and mobile runtime acceptance remain separate.']}, indent=2) + '\n')
print(f'{len(checks)} audio controller checks passed')
