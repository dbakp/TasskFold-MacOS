#!/usr/bin/env python3
"""Exercise the actual share-mailbox flock across independent local processes, using only synthetic data."""
from pathlib import Path
import json, subprocess, tempfile, uuid
ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='taskfold-share-process-', dir='/private/tmp') as folder:
    folder = Path(folder)
    main = folder / 'main.swift'
    main.write_text('''import Foundation
let args = CommandLine.arguments
let disk = SharedCaptureDisk(directory: URL(fileURLWithPath: args[1]))
let context = SharedCaptureWorkspace(account: "synthetic-process-owner", generation: UUID(uuidString: args[2])!, label: "Synthetic process test")
switch args[3] {
case "publish": try disk.publish(context)
case "save":
    for number in 0..<16 {
        let value = try SharedCaptureContent(title: "Synthetic \\(args[4])-\\(number)")
        try disk.save(SharedCaptureDraft(workspace: context, content: value))
    }
default:
    let drafts = try disk.drafts(account: context.account)
    print(String(data: try JSONEncoder().encode(drafts.map { $0.content.title }.sorted()), encoding: .utf8)!)
}
''')
    executable = folder / 'probe'
    subprocess.run(['swiftc', str(ROOT / 'Taskfold/Core/SharedCapture.swift'), str(main), '-o', str(executable)], check=True, capture_output=True, text=True)
    base = [str(executable), str(folder / 'mailbox'), str(uuid.uuid4())]
    subprocess.run(base + ['publish'], check=True, capture_output=True, text=True)
    processes = [subprocess.Popen(base + ['save', str(number)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for number in range(4)]
    for process in processes:
        stdout, stderr = process.communicate(timeout=30)
        if process.returncode: raise AssertionError(stderr or stdout)
    result = subprocess.run(base + ['read'], check=True, capture_output=True, text=True)
    actual = json.loads(result.stdout)
    expected = sorted(f'Synthetic {process}-{number}' for process in range(4) for number in range(16))
    assert actual == expected, 'Concurrent processes lost, duplicated or changed a draft'
    print('Passed: 64 complete drafts persisted across 4 independent processes; temporary synthetic mailbox removed.')
