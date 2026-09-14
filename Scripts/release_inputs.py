#!/usr/bin/env python3
"""Fingerprint build sources, excluding generated project and release documentation."""
import hashlib
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
digest = hashlib.sha256()
for name in sorted(set(paths)):
    if name == "SharedCoreRevision" or name.startswith(("Taskfold/", "TaskfoldWidgets/", "Scripts/", "Config/")):
        path = root / name
        if path.is_file():
            digest.update(name.encode() + b"\0" + path.read_bytes() + b"\0")
print(digest.hexdigest())
