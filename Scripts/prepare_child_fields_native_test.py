#!/usr/bin/env python3
"""Create a new reserved local-only child-field acceptance host; never overwrite one."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--completions", action="store_true", help="Enable independent completion in this reserved test host only")
args = parser.parse_args()
subprocess.run([sys.executable, str(Path(__file__).with_name("check_test_storage.py")), "--path", str(args.output.expanduser().parent)], check=True)
root = args.output.expanduser().resolve()
if root.exists():
    parser.error("Use a new output directory. Reuse existing hosts with explicit incremental source updates.")
subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_team_editor_native_test.py")), "--output", str(root)], check=True)
path = root / "Taskfold/Info.plist"
value = plistlib.loads(path.read_bytes())
value["TaskfoldChildRecordReadsEnabled"] = True
value["TaskfoldChildRecordWritesEnabled"] = True
if args.completions:
    value["TaskfoldChildRecordCompletionsEnabled"] = True
value["CFBundleDisplayName"] = "Taskfold Child Field Test"
path.write_bytes(plistlib.dumps(value))
print("Launch with --team-editor-testing --child-fields-native; add --child-fields-native-reset only to reset the dedicated synthetic accounts.")
