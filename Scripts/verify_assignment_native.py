#!/usr/bin/env python3
"""Verify exported synthetic native project-change snapshots without numeric/key loss."""
import argparse
import copy
from decimal import Decimal
import hashlib
import json
from pathlib import Path

ROOT = "a5110000-0000-4000-8000-000000000001"
SOURCE = "a5110000-0000-4000-8000-000000000002"
DESTINATION = "a5110000-0000-4000-8000-000000000003"
MOVE = "testProjectChangePreservesExactChecklistThroughSaveAndColdReturn()"
REFUSAL = "testProjectChangeUnsupportedChecklistRefusesWithoutChangingSource()"
TOKENS = ['"é":9007199254740993', '"e\\u0301":17', '"future":{"keep":"exact"}']


def require(value, message):
    if not value:
        raise ValueError(message)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


def load(data):
    return json.loads(data, parse_float=Decimal, object_pairs_hook=pairs,
                      parse_constant=lambda value: require(False, "Invalid JSON constant"))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def same(first, second):
    # Python's ordinary equality treats false and 0 as equal. Preserve JSON types
    # and exact Unicode code points, while comparing numbers without Double.
    if isinstance(first, bool) or isinstance(second, bool):
        return type(first) is type(second) and first == second
    if isinstance(first, dict) and isinstance(second, dict):
        return first.keys() == second.keys() and all(same(value, second[key]) for key, value in first.items())
    if isinstance(first, list) and isinstance(second, list):
        return len(first) == len(second) and all(same(a, b) for a, b in zip(first, second))
    if isinstance(first, (int, Decimal)) and isinstance(second, (int, Decimal)):
        return first == second
    return type(first) is type(second) and first == second


def root(snapshot):
    tasks = snapshot["tables"]["tasks"]
    require(len(tasks) == 1 and tasks[0]["id"] == ROOT and tasks[0]["user_id"] == "ui-testing", "Synthetic root identity mismatch")
    return tasks[0]


def clear(tree):
    require(isinstance(tree, list), "Expected supported synthetic child array")
    for item in tree:
        if isinstance(item, str):
            continue
        require(isinstance(item, dict), "Unexpected synthetic child")
        item["assigned_to"] = None
        if item.get("subtasks") is not None:
            clear(item["subtasks"])


def verify(directory, summary_path):
    summary_bytes = summary_path.read_bytes()
    summary = load(summary_bytes)
    require(summary["result"] == "Passed" and summary["passedTests"] == 2 and
            all(summary.get(key, 0) == 0 for key in ("failedTests", "skippedTests", "expectedFailures")), "Both native tests must pass without skips")
    require(len(summary["devicesAndConfigurations"]) == 1, "Require one observed native destination")
    directory = directory.resolve()
    manifest_bytes = (directory / "manifest.json").read_bytes()
    manifest = load(manifest_bytes)
    groups = {}
    for group in manifest:
        name = group["testIdentifier"].split("/")[-1]
        require(name not in groups, "Duplicate native test group")
        groups[name] = group["attachments"]
    require(set(groups) == {MOVE, REFUSAL}, "Unexpected native test scope")
    proofs = []

    def snapshots(test, prefix, count):
        selected = sorted((item for item in groups[test] if item["suggestedHumanReadableName"].startswith(prefix)), key=lambda item: item["timestamp"])
        require(len(selected) == count, "Missing exact attachment count: " + prefix)
        result = []
        for item in selected:
            path = (directory / item["exportedFileName"]).resolve()
            require(path.parent == directory and path.suffix == ".json", "Invalid attachment path")
            require(item["deviceId"] == summary["devicesAndConfigurations"][0]["device"]["deviceId"], "Attachment belongs to another destination")
            data = path.read_bytes()
            parsed = load(data)
            proofs.append({"name": item["suggestedHumanReadableName"], "sha256": digest(data), "bytes": len(data)})
            result.append((parsed, data))
        return result

    original, original_data = snapshots(MOVE, "Original project change source", 1)[0]
    saved, cold = snapshots(MOVE, "Actual saved project change cache", 2)
    expected = copy.deepcopy(root(original))
    require(expected["project_id"] == SOURCE and expected["assigned_to"] == "ui-testing", "Wrong original assignment/project")
    require(expected["subtasks"][0]["é"] == 9007199254740993 and expected["subtasks"][0]["e\u0301"] == 17, "Exact Unicode/large-number fixture missing")
    expected["project_id"] = DESTINATION
    expected["assigned_to"] = expected["section_id"] = None
    clear(expected["subtasks"])
    for snapshot, raw in (saved, cold):
        require(same(root(snapshot), expected), "The move changed data beyond project/section/assignments")
        require(snapshot.get("pending") == [], "Local move left unexpected pending writes")
        for table in ("projects", "sections"):
            require(same(snapshot["tables"].get(table), original["tables"].get(table)), "Unrelated project/section rows changed")
        for token in TOKENS:
            require(token.encode() in raw and token.encode() in original_data, "Exact original token missing: " + token)
    require(same(saved[0], cold[0]), "Full saved snapshot changed across cold return")

    refused, refused_data = snapshots(REFUSAL, "Unsupported project change source", 1)[0]
    immediate, immediate_data = snapshots(REFUSAL, "Unsupported source after refusal", 1)[0]
    returned, _ = snapshots(REFUSAL, "Unsupported source after cold return", 1)[0]
    require(root(refused)["project_id"] == SOURCE and root(refused)["assigned_to"] == "ui-testing" and root(refused)["subtasks"] == {"future_container": "Keep this unsupported source"}, "Wrong unsupported-source fixture")
    require(refused_data == immediate_data, "Refusal rewrote the source file")
    require(same(refused, immediate) and same(refused, returned), "Refusal/cold return changed saved values")
    return {"passed": True, "scope": "Observed local synthetic native project picker, save/autosave, refusal and cold return; no cloud delivery or spoken-output claim", "device": summary["devicesAndConfigurations"][0]["device"], "summarySHA256": digest(summary_bytes), "manifestSHA256": digest(manifest_bytes), "fullRootMoveHasOnlyExpectedChanges": True, "exactUnicodeKeysAndLargeIntegerPreserved": True, "fullSnapshotColdReturnPreserved": True, "refusalSourceBytesUntouched": True, "refusalFullSnapshotColdReturnPreserved": True, "attachments": proofs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = {"passed": False}
    args.output.write_text(json.dumps(report) + "\n")
    try:
        report = verify(args.attachments, args.summary)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        report["error"] = str(error)
        raise SystemExit(str(error))
    finally:
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print("Verified both native flows and six lossless snapshots")


if __name__ == "__main__":
    main()
