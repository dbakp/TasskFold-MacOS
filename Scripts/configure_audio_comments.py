#!/usr/bin/env python3
"""Register independently owned audio-comment sources in the app target."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

root = Path(__file__).resolve().parent.parent
project = root / "Taskfold.xcodeproj/project.pbxproj"
source = project.read_text()
objects = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)]))["objects"]
proj = next(row for row in objects.values() if row.get("isa") == "PBXProject")
lines = []

def uid(name):
    return hashlib.sha256(("taskfold-audio-comment:" + name).encode()).hexdigest()[:24].upper()

def append(key, field, value):
    global source
    pattern = r"(" + re.escape(key) + r"\s*=\s*\{[^\n]*?\b" + field + r"\s*=\s*\()"
    source, count = re.subn(pattern, lambda match: match[1] + value + ",", source, count=1)
    assert count == 1

def add_source(phase, path):
    assert (root / path).is_file()
    ref = next((key for key, row in objects.items() if row.get("isa") == "PBXFileReference" and row.get("path") == path), None)
    if ref is None:
        ref = uid("ref:" + path)
        assert ref not in objects
        objects[ref] = {"isa": "PBXFileReference", "path": path}
        lines.append(f'{ref} = {{ isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = "<group>"; }};')
        append(proj["mainGroup"], "children", ref)
    if any(objects.get(key, {}).get("fileRef") == ref for key in objects[phase]["files"]):
        return
    build = uid("build:" + phase + path); assert build not in objects
    lines.append(f"{build} = {{ isa = PBXBuildFile; fileRef = {ref}; }};")
    append(phase, "files", build)

app = next(row for row in objects.values() if row.get("isa") == "PBXNativeTarget" and row.get("name") == "Taskfold")
phase = next(key for key in app["buildPhases"] if objects[key]["isa"] == "PBXSourcesBuildPhase")
for path in ["Taskfold/Core/AudioComments.swift", "Taskfold/Core/AudioCommentDecoding.swift", "Taskfold/Core/AudioCommentPending.swift"]:
    add_source(phase, path)
if lines:
    source = source.replace("}; rootObject", "\n" + "\n".join(lines) + "\n}; rootObject", 1)
    project.write_text(source)
subprocess.run(["plutil", "-lint", str(project)], check=True, stdout=subprocess.DEVNULL)
