#!/usr/bin/env python3
"""Require actual XCTest coverage before accepting a selected native UI run."""
import argparse
import json
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", help="Completed .xcresult bundle")
    parser.add_argument("--expected-tests", type=int, required=True)
    parser.add_argument("--allow-runtime-warnings", action="store_true",
                        help="Report warnings without accepting them as clean-runtime evidence")
    args = parser.parse_args()
    if args.expected_tests < 1:
        parser.error("expected-tests must be positive; zero selected cases are not verification")
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", args.result_bundle],
        capture_output=True, text=True,
    )
    if result.returncode:
        print(result.stderr.strip() or "Could not read the completed result bundle", file=sys.stderr)
        return 1
    try:
        summary = json.loads(result.stdout)
    except json.JSONDecodeError:
        print("Result summary was not valid JSON", file=sys.stderr)
        return 1
    expected = args.expected_tests
    failures = []
    for key, wanted in [("totalTestCount", expected), ("passedTests", expected),
                        ("failedTests", 0), ("skippedTests", 0), ("expectedFailures", 0)]:
        if summary.get(key) != wanted:
            failures.append(f"{key}: expected {wanted}, observed {summary.get(key)!r}")
    if summary.get("result") != "Passed":
        failures.append(f"result: {summary.get('result')!r}")
    warnings = summary.get("runtimeWarnings")
    if not isinstance(warnings, list):
        failures.append("runtime warnings were not reported")
    elif warnings:
        print(json.dumps({"runtimeWarnings": warnings}, indent=2), file=sys.stderr)
        if not args.allow_runtime_warnings:
            failures.append("runtime warnings remain")
    if failures:
        print("UI verification rejected: " + "; ".join(failures), file=sys.stderr)
        return 1
    print(f"Verified {expected} actual passing UI tests; "
          + ("runtime warnings remain explicitly allowed." if warnings else "no runtime warnings."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
