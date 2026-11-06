#!/usr/bin/env python3
"""Exercise the production voice controller with a synthetic recorder; no mic opens.
Includes the real one-minute deadline. This is not genuine speech/TCC acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
proof = (repo/'Scripts/fixtures/VoiceCaptureControllerProof.swift').read_text()
backend = (repo/'Taskfold/Core/Backend.swift').read_text()
error = re.search(r'struct AppFailure: LocalizedError \{.*?\n\}', backend, re.S).group(0)
binding = (repo/'Taskfold/Core/InboxReview.swift').read_text().split('enum InboxReviewBatch')[0]
with tempfile.TemporaryDirectory(prefix='taskfold-voice-controller-') as name:
    folder = Path(name)
    (folder/'Proof.swift').write_text(proof)
    (folder/'Bindings.swift').write_text(binding+'\n'+error)
    command = ['xcrun','swiftc','-parse-as-library',str(folder/'Proof.swift'),str(folder/'Bindings.swift'),str(repo/'Taskfold/Core/VoiceDraft.swift'),str(repo/'Taskfold/VoiceCapture.swift'),str(repo/'Taskfold/AudioSessionLease.swift'),'-o',str(folder/'Proof')]
    result = subprocess.run(command,text=True,capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    result = subprocess.run([str(folder/'Proof'),str(args.output.resolve())],text=True,capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout+result.stderr)
checks = json.loads(args.output.read_text())
evidence = {'checks':checks,'sourceSHA256':{name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in ['Taskfold/Core/VoiceDraft.swift','Taskfold/VoiceCapture.swift','Taskfold/AudioSessionLease.swift','Scripts/fixtures/VoiceCaptureControllerProof.swift']},'limits':['Mac-native controller with a synthetic recorder; no microphone or permission prompt was opened.','The real recorder is invoked only with a false context gate to verify rejection before permission access.','No genuine speech-recognition accuracy, audio interruption or TCC recovery acceptance.']}
args.output.write_text(json.dumps(evidence,indent=2)+'\n')
print(f'{len(checks)} voice controller checks passed')
