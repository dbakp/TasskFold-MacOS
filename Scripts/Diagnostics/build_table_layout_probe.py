#!/usr/bin/env python3
"""Build a standalone synthetic SwiftUI List reproducer; never launches it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path, help="New directory; existing paths are refused")
    args = parser.parse_args()
    root = args.output_directory.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=False)
    app = root / "Taskfold Table Layout Probe.app"
    executable = app / "Contents/MacOS/TableLayoutProbe"
    executable.parent.mkdir(parents=True)
    source = Path(__file__).with_name("TableLayoutProbe.swift")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.dbakp.taskfold.diagnostics.tablelayoutprobe",
        "CFBundleName": "Taskfold Table Layout Probe",
        "CFBundleExecutable": "TableLayoutProbe",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "15.0",
    }))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run(["codesign", "--sign", "-", str(app)], check=True)
    print(json.dumps({"app": str(app), "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(), "launched": False}))


if __name__ == "__main__":
    main()
