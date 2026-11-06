#!/usr/bin/env python3
"""Refuse heavy local tests when the output volume has too little free space.

Read-only: this check never removes files or modifies Docker/Simulator data.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, default=Path("/tmp"))
    parser.add_argument("--minimum-gib", type=float, default=20)
    args = parser.parse_args()
    if not 0 < args.minimum_gib < 10000:
        parser.error("Use a positive storage floor below 10000 GiB.")
    target = args.path.expanduser().resolve()
    while not target.exists():
        target = target.parent
    free = shutil.disk_usage(target).free
    required = int(args.minimum_gib * 1024 ** 3)
    result = {"path": str(target), "freeBytes": free, "requiredBytes": required,
              "canStartHeavyTests": free >= required}
    print(json.dumps(result))
    if free < required:
        print(f"Stop: {free / 1024 ** 3:.1f} GiB free; {args.minimum_gib:g} GiB required. "
              "Clean approved obsolete outputs before building, booting simulators or starting database fixtures.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
