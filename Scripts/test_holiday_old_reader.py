#!/usr/bin/env python3
"""Compile a previous committed Core reader against an opaque version-5 holiday fixture."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--revision", required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
revision = subprocess.check_output(["git", "rev-parse", "--verify", args.revision + "^{commit}"], cwd=repo, text=True).strip()
fixture = (repo / "Scripts/fixtures/OldHolidayReaderTests.swift").read_bytes()
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="taskfold-holiday-reader-") as directory:
    target = Path(directory)
    archive = subprocess.check_output(["git", "archive", revision, "Package.swift", "Taskfold/Core", "TaskfoldWidgets", "TaskfoldTests/Fixtures"], cwd=repo)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for item in source.getmembers():
            path = Path(item.name)
            if path.is_absolute() or ".." in path.parts or item.issym() or item.islnk():
                raise RuntimeError("Unexpected archive path")
        source.extractall(target)
    old_source = (target / "Taskfold/Core/Reminders.swift").read_bytes()
    if b"var holidaySchedule:" in old_source:
        raise RuntimeError("Choose a previous reader without holiday support")
    (target / "TaskfoldTests/OldHolidayReaderTests.swift").write_bytes(fixture)
    run = subprocess.run(["swift", "test", "--package-path", str(target), "--scratch-path", str(target / "build"), "--filter", "OldHolidayReaderTests"], capture_output=True, text=True)
    log = run.stdout + run.stderr
    args.output.with_suffix(".log").write_text(log)
    if run.returncode or not re.search(r"Executed 1 test, with 0 failures", log):
        raise RuntimeError("Old-reader preservation check failed; inspect log")
    proof = {"revision": revision, "oldReminderSourceSHA256": hashlib.sha256(old_source).hexdigest(), "fixtureSHA256": hashlib.sha256(fixture).hexdigest(), "passed": 1, "checks": ["unsupported rather than planned-time reinterpretation", "title/planned-toggle edits preserve opaque holiday policy", "exact saved record roundtrip", "recurring successor retains opaque settings", "no substitute notifications"], "scope": "This selected previous native Core reader only; no claim all older versions enforce new behavior."}
    args.output.write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof))
