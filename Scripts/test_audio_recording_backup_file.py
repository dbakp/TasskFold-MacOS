#!/usr/bin/env python3
"""Decode an actual portable recording file with this repo's Core and native AAC codec; never plays audio."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--input', required=True, type=Path)
parser.add_argument('--caption', required=True)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
source = repo / 'Scripts/fixtures/AudioPortableFileProof.swift'
products = args.scratch.resolve() / 'debug'
with tempfile.TemporaryDirectory(prefix='taskfold-audio-portable-file-') as folder:
    binary = Path(folder) / 'proof'
    result = subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-enable-testing', '-I', str(products), '-L', str(products), '-lTaskfoldCore', str(source), '-o', str(binary)], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr)
    warnings = [line for line in result.stderr.splitlines() if 'warning:' in line]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(binary), str(args.input.resolve()), args.caption, str(args.output.resolve())], check=True, capture_output=True, text=True, timeout=60)
result = json.loads(args.output.read_text())
result['compilerWarnings'] = warnings
result['sources'] = {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in ['Taskfold/Core/AudioComments.swift', 'Taskfold/Core/AudioCommentDecoding.swift', 'Scripts/fixtures/AudioPortableFileProof.swift']}
result['scope'] = 'Mac executable with this independent repository Core and full native AAC decode of an actual file; no playback, microphone, permission or native import UI acceptance.'
args.output.write_text(json.dumps(result, indent=2) + '\n')
print('Portable recording file admitted; exact caption/audio and full native decode passed.')
