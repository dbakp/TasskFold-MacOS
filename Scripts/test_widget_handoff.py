#!/usr/bin/env python3
"""Exercise the owned widget disk handoff with separate OS processes and isolated data."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parent.parent
helper = r'''
import Foundation
@main struct HandoffFixture {
    static func main() throws {
        let args = CommandLine.arguments, disk = WidgetActionDisk(directory: URL(fileURLWithPath: args[1]))
        do {
            switch args[2] {
            case "enqueue":
                let request = try WidgetCompletionRequest(account: args[3], taskID: args[4], token: args[5])
                let saved = try disk.enqueue(request)
                print(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
            case "pending": print(String(decoding: try JSONEncoder().encode(disk.pending(account: args[3])), as: UTF8.self))
            case "ack":
                for request in try disk.pending(account: args[3]) where Int(request.taskID.dropFirst(5))! < 64 { try disk.acknowledge(request) }
            default: fatalError("Unknown fixture command")
            }
        } catch { print(error.localizedDescription); exit(2) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="taskfold-widget-process-tests-") as directory:
    path = Path(directory); source = path / "Fixture.swift"; source.write_text(helper)
    binary = path / "fixture"
    subprocess.run(["xcrun", "swiftc", "-D", "SWIFT_PACKAGE", "-parse-as-library", str(root / "Taskfold/Core/WidgetActions.swift"), str(source), "-o", str(binary)], check=True, timeout=120)
    shared = path / "group"; shared.mkdir()
    tokens = [str(uuid.uuid4()) for _ in range(129)]
    projection = {"version": 2, "account": "fixture-a", "tasks": [{"id": f"task-{i}", "completionToken": token} for i, token in enumerate(tokens)]}
    (shared / "widget.json").write_text(json.dumps(projection))
    def run(*args): return subprocess.run([str(binary), str(shared), *args], text=True, capture_output=True, timeout=15)
    def enqueue(i):
        result = run("enqueue", "fixture-a", f"task-{i}", tokens[i]); assert result.returncode == 0, result.stdout
        return json.loads(result.stdout)
    with ThreadPoolExecutor(max_workers=8) as pool:
        initial = list(pool.map(enqueue, range(96)))
        retries = list(pool.map(enqueue, range(96)))
    assert sorted(initial, key=lambda r: r["taskID"]) == sorted(retries, key=lambda r: r["taskID"]), "Retries changed accepted times or request identity"
    queued = json.loads(run("pending", "fixture-a").stdout)
    assert len(queued) == 96 and len({r["id"] for r in queued}) == 96, "Cross-process writes lost or duplicated requests"
    with ThreadPoolExecutor(max_workers=8) as pool: list(pool.map(enqueue, range(96, 128)))
    assert run("enqueue", "fixture-a", "task-128", tokens[128]).returncode == 2, "Capacity must report refusal"
    assert len(json.loads(run("pending", "fixture-a").stdout)) == 128, "Capacity silently trimmed accepted work"
    assert run("enqueue", "fixture-b", "task-0", tokens[0]).returncode == 2, "Wrong workspace accepted"
    projection["account"] = "fixture-b"; (shared / "widget.json").write_text(json.dumps(projection))
    assert run("enqueue", "fixture-a", "task-0", tokens[0]).returncode == 2, "Old-account widget accepted"
    assert len(json.loads(run("pending", "fixture-a").stdout)) == 128, "Switching workspace discarded accepted work"
    assert run("ack", "fixture-a").returncode == 0
    remaining = json.loads(run("pending", "fixture-a").stdout)
    assert {r["taskID"] for r in remaining} == {f"task-{i}" for i in range(64, 128)}, "Acknowledgement affected another request"
    print("PASS: separate-process enqueue/retry, 128-action capacity without trimming, workspace rejection/retention, and scoped acknowledgement")
