#!/usr/bin/env python3
"""Prepare the reserved, network-isolated native team-editor acceptance app.

The rollout switch is enabled only in this disposable copy. Launch with
--team-editor-testing; add --team-editor-reset to seed synthetic test tasks.
Normal builds retain their existing rollout and network configuration.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = args.output.expanduser().resolve()
subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_workflow_ui_test.py")),
                "--output", str(root), "--namespace", "workflowteststeameditbridge"], check=True)
info = root / "Taskfold/Info.plist"
value = plistlib.loads(info.read_bytes())
value["TaskfoldTeamsEnabled"] = True
value["CFBundleDisplayName"] = "Taskfold Team Editor Test"
info.write_bytes(plistlib.dumps(value))
for path in root.rglob("Backend.plist"):
    path.write_bytes(plistlib.dumps({"URL": "https://synthetic.example", "Key": "synthetic-public"}))
for relative in ["Taskfold/Core/Backend.swift", "Taskfold/Core/Backups.swift"]:
    path = root / relative
    source = path.read_text().replace("com.taskfold.ios.session", "com.taskfold.workflowteststeameditbridge.session")
    source = source.replace("com.taskfold.recovery.v1", "com.taskfold.workflowteststeameditbridge.recovery")
    path.write_text(source)

receipt = root / "team-editor-test-receipt.json"
files = ["Taskfold/Core/Store.swift", "Taskfold/Core/Backups.swift", "Taskfold/Core/Backend.swift", "Taskfold/Info.plist"]
receipt.write_text(json.dumps({
    "namespace": "workflowteststeameditbridge", "teamRolloutInCopyOnly": True,
    "network": "All requests intercepted and rejected when the exact DEBUG fixture is enabled",
    "files": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}
}, indent=2) + "\n")
