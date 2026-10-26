#!/usr/bin/env python3
"""Prepare an isolated local heading-authoring test copy; never modify production settings.

Build/sign the copied app, then launch with --uitesting --workflow-fixture
--task-heading-fixture -localMode YES. Add --subtask-organizer-fixture for
nested type controls. Omit seed flags on relaunch to inspect durable state.
Cloud/team heading authoring remains unavailable.
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
subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_team_editor_native_test.py")),
                "--output", str(root)], check=True)
info = root / "Taskfold/Info.plist"
value = plistlib.loads(info.read_bytes())
value["TaskfoldHeadingsEnabled"] = True
value["CFBundleDisplayName"] = "Taskfold Heading Test"
info.write_bytes(plistlib.dumps(value))
(root / "task-heading-test-receipt.json").write_text(json.dumps({
    "reservedNamespace": "workflowteststeameditbridge",
    "localHeadingAuthoringInCopyOnly": True,
    "cloudHeadingAuthoring": False,
    "sourceStoreSHA256": hashlib.sha256((Path(__file__).resolve().parents[1] / "Taskfold/Core/Store.swift").read_bytes()).hexdigest(),
    "preparedInfoSHA256": hashlib.sha256(info.read_bytes()).hexdigest(),
    "limitations": ["Preparation is not runtime acceptance", "No hosted schema, rollout or production setting changed"]
}, indent=2) + "\n")
