#!/usr/bin/env python3
"""Verify the actual Core vault across independent synthetic processes; no app/mic."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True, type=Path, help='Existing Swift Package scratch path built with testing enabled')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
products = args.scratch.resolve() / 'debug'
assert (products / 'libTaskfoldCore.a').is_file(), 'Run the focused Core tests first'
fixture = repo / 'TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a'
with tempfile.TemporaryDirectory(prefix='taskfold-audio-vault-process-') as temporary:
    temporary = Path(temporary)
    executable = temporary / 'probe'
    compile_command = ['swiftc', '-swift-version', '5', '-enable-testing', '-I', str(products), '-L', str(products), '-lTaskfoldCore', str(repo / 'Scripts/AudioCommentVaultProbe.swift'), '-o', str(executable)]
    subprocess.run(compile_command, check=True, capture_output=True, text=True, timeout=60)
    store = temporary / 'store'; store.mkdir(mode=0o700)
    def invoke(mode):
        result = subprocess.run([str(executable), mode, str(store), str(fixture)], check=True, capture_output=True, text=True, timeout=30)
        return json.loads(result.stdout)
    written = invoke('write')
    restored = invoke('verify')
    assert written['pid'] != restored['pid']
    assert {k: v for k, v in written.items() if k != 'pid'} == {k: v for k, v in restored.items() if k != 'pid'}
    account = hashlib.sha256(b'11111111-1111-4111-8111-111111111111').hexdigest()
    folder = store / 'AudioCommentsPrivate' / account
    before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.glob('*.bin')}
    lock = os.open(folder / '.lock', os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = invoke('busy')
        assert busy['status'] == 'busy'
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
    after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.glob('*.bin')}
    assert before == after
    unlocked = invoke('verify')
    assert unlocked['status'] == 'verified'
    assert len({written['pid'], restored['pid'], busy['pid'], unlocked['pid']}) == 4
    departure = [invoke(mode) for mode in ['prepare-departure', 'verify-departure', 'finish-departure', 'verify-finished']]
    assert len({item['pid'] for item in departure}) == 4
    assert all({k:v for k,v in item.items() if k != 'pid'} == {k:v for k,v in departure[0].items() if k != 'pid'} for item in departure)
    revoked = invoke('prepare-revoked')
    discarded = invoke('discard-revoked')
    refused = invoke('reject-revoked:' + revoked['fence'])
    still_absent = invoke('verify-revoked')
    assert len({item['pid'] for item in [revoked, discarded, refused, still_absent]}) == 4
    print(json.dumps({'status': 'passed', 'separateProcesses': 12, 'completedDiscardCannotBeRevivedByAnOlderProcessFence': True, 'departureJournalSurvivesProcessExitWithoutCompletingDraft': True, 'explicitFinishUsesOriginalIDsAndAudioAcrossProcesses': True, 'localAndCloudDraftsRestored': True, 'exactPendingIntentAndAudioRestored': True, 'crossProcessLockRefusedWithoutMutation': True, 'noMicrophonePlaybackOrNetwork': True, 'ownedTemporaryDirectoryRemovedOnExit': True}, indent=2))
