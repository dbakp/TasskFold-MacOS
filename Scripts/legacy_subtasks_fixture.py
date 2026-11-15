#!/usr/bin/env python3
"""Regenerates TaskfoldTests/Fixtures/legacy_subtasks.json.

An independent implementation of the legacy JSON-subtask -> child-row conversion (Migration B), using only the
standard library (hashlib.md5), so the expected UUIDs do not come from the Swift code under test:

    legacy_child_id(root, path) = md5('taskfold.child-row.v1|' + lower(root) + '|' + U+001F.join(path)) as a uuid

Run from the repo root:  python3 Scripts/legacy_subtasks_fixture.py
"""
import base64, hashlib, json, os

NS = "taskfold.child-row.v1"
SEP = "\x1f"
MAX_LEVEL = 10      # at most ten ancestors, so level 10 is the deepest allowed
READABLE = 32


def md5_uuid(text):
    h = hashlib.md5(text.encode("utf-8")).hexdigest()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def legacy_child_id(root, path):
    return md5_uuid(NS + "|" + root.lower() + "|" + SEP.join(path))


def child_key(node, i):
    if isinstance(node, dict) and isinstance(node.get("id"), str) and node["id"] != "":
        return node["id"]
    return f"@{i}"


def segments(siblings):
    keys = [child_key(n, i) for i, n in enumerate(siblings)]
    return [k if keys.count(k) == 1 else f"@{i}" for i, k in enumerate(keys)]


def count_below(node):
    if isinstance(node, dict) and isinstance(node.get("subtasks"), list):
        return sum(1 + count_below(c) for c in node["subtasks"])
    return 0


TEXT = ["title", "description", "completed_at", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "created_at", "assigned_to"]
FLAG = ["completed", "is_heading"]
NUM = ["priority", "duration_minutes"]
LST = ["labels", "comments", "attachments", "reminder_specs"]
HANDLED = set(TEXT + FLAG + NUM + LST + ["id", "subtasks"])


def convert(root, subtasks):
    rid = root["id"]
    rows, skipped, reparented, used = [], [], [], {rid.lower()}
    counter = [0]

    def walk(sibs, parent, level, path, anchor):
        names = segments(sibs)
        for i, node in enumerate(sibs):
            here = path + [names[i]]
            nid = legacy_child_id(rid, here)

            def skip(reason):
                skipped.append({"path": here, "reason": reason, "descendants": count_below(node)})
            if level > READABLE:
                skip("depth_over_32"); continue
            pid, order = parent, i + 1
            if level > MAX_LEVEL:
                pid = anchor; counter[0] += 1; order = 1000 + counter[0]
            if isinstance(node, str):
                title = node
            elif isinstance(node, dict) and isinstance(node.get("title"), str):
                title = node["title"]
            else:
                skip("missing_title" if isinstance(node, dict) else "not_an_object"); continue
            if title.strip() == "":
                skip("empty_title"); continue
            if nid in used:
                skip("id_collision"); continue
            used.add(nid)
            row = {"id": nid, "parent_id": pid, "child_order": order, "title": title, "path": here, "level": level}
            fields, extra = {}, {}
            if isinstance(node, dict):
                for k, v in sorted(node.items()):
                    if v is None:
                        continue
                    ok = ((k in TEXT and isinstance(v, str)) or (k in FLAG and isinstance(v, bool)) or
                          (k in NUM and isinstance(v, (int, float)) and not isinstance(v, bool)) or (k in LST and isinstance(v, list)))
                    if k in HANDLED and k not in ("id", "subtasks"):
                        if ok: fields[k] = v
                        else: extra[k] = v
                    elif k == "subtasks":
                        if not isinstance(v, list): extra[k] = v
                    elif k not in HANDLED:
                        extra[k] = v
            row["completed"] = fields.get("completed", False)
            row["fields"] = {k: fields[k] for k in ("description", "priority", "due_date", "labels", "is_heading") if k in fields}
            assignee = fields.get("assigned_to")
            row["assigned_to"] = assignee if (assignee and root.get("project_id")) else None
            row["source_metadata"] = {"taskfold_legacy_child": extra} if extra else {}
            rows.append(row)
            if level > MAX_LEVEL:
                reparented.append({"id": nid, "path": here, "level": level, "parent": pid})
            if isinstance(node, dict) and isinstance(node.get("subtasks"), list):
                walk(node["subtasks"], nid, level + 1, here, parent if level == MAX_LEVEL else anchor)
    walk(subtasks, rid, 1, [], rid)
    return rows, skipped, reparented


def nest(depth, prefix="n"):
    node = None
    for d in range(depth, 0, -1):
        node = {"id": f"{prefix}{d}", "title": f"Level {d}", **({"subtasks": [node]} if node else {})}
    return [node]


def root(rid, project="33333333-3333-4333-8333-333333333333"):
    return {"id": rid, "user_id": "99999999-9999-4999-8999-999999999999", "project_id": project,
            "section_id": None if project is None else "44444444-4444-4444-8444-444444444444", "created_at": "2026-01-02T03:04:05+00:00"}


TREES = [
    ("nested_with_fields", root("11111111-1111-4111-8111-111111111111"), [
        {"id": "a", "title": "First", "completed": True, "priority": 2, "description": "note", "due_date": "2026-02-03", "labels": ["x"], "assigned_to": "u-2",
         "colour": "red", "subtasks": [{"id": "b", "title": "Nested", "is_heading": True, "subtasks": [{"id": "c", "title": "Deep"}]}, "plain string child"]},
        {"id": "z", "title": "Second", "sticky": {"k": [1, 2]}},
        "A bare string",
    ]),
    ("duplicate_and_missing_ids", root("22222222-2222-4222-8222-222222222222", None), [
        {"title": "No id"}, {"id": "dup", "title": "Dup one", "assigned_to": "u-2"}, {"id": "dup", "title": "Dup two", "subtasks": [{"id": "dup", "title": "Child of dup two"}]},
        {"id": "", "title": "Empty id"}, {"id": 7, "title": "Numeric id"},
    ]),
    ("id_collision", root("55555555-5555-4555-8555-555555555555"), [
        {"id": "@1", "title": "Literal at-sign id"}, {"id": "x", "title": "Dup a"}, {"id": "x", "title": "Dup b"},
    ]),
    ("junk_nodes", root("66666666-6666-4666-8666-666666666666"), [
        42, None, True, ["array"], {"id": "notitle", "subtasks": [{"id": "lost", "title": "Lost with parent"}]}, {"id": "blank", "title": "   "}, "", {"id": "t", "title": 5},
        {"id": "ok", "title": "Survivor", "subtasks": "not a list", "priority": "high", "completed": "yes"},
    ]),
    ("depth_chain_12", root("77777777-7777-4777-8777-777777777777"), nest(12)),
    ("depth_chain_34", root("88888888-8888-4888-8888-888888888888"), nest(34)),
    ("depth_branches", root("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), [
        {"id": "p", "title": "P", "subtasks": nest(11, "q")}, {"id": "r", "title": "R", "subtasks": nest(12, "s")},
    ]),
    ("unicode_ids", root("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"), [
        {"id": "é/日本☃", "title": "Unicode", "subtasks": [{"id": "a|b", "title": "Pipe"}]}, {"id": "with space", "title": "Space"},
    ]),
    ("empty_and_non_list", root("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"), []),
]

out = {
    "format": "taskfold.legacy-subtasks-fixture",
    "version": 1,
    "algorithm": {
        "id": "legacy_child_id(root, path) = md5('taskfold.child-row.v1|' || lower(root) || '|' || path joined by U+001F) formatted 8-4-4-4-12 (no version bits).",
        "path_segment": "SubtaskTree.childKey: the node id when it is a non-empty string, else '@index'. When several siblings share a key, each of them uses '@index' instead.",
        "levels": "A child of the root is level 1. A node deeper than level 10 is re-parented to its level-9 ancestor (the deepest the server's ten-ancestor guard allows is level 10). Its id still comes from its real path. child_order is index+1 among the original siblings; re-parented nodes get 1000 + their running count in pre-order. Nodes deeper than level 32 are skipped (depth_over_32).",
        "skip_reasons": "not_an_object, missing_title (object without a string title), empty_title (blank), depth_over_32, id_collision. A skipped node takes its whole branch with it; descendants counts the nodes lost.",
        "field_mapping": "title, description, completed, completed_at, priority, due_date, due_time, time_zone, scheduled_at, deadline_date, duration_minutes, labels, comments, attachments, reminder_specs, is_heading, created_at, assigned_to copy when their JSON type is right; anything else (or a mistyped known key) goes to source_metadata.taskfold_legacy_child. assigned_to survives only when the root has a project. user_id, project_id, section_id come from the root.",
    },
    "verification": "Every expected id below was computed by Scripts/legacy_subtasks_fixture.py with hashlib.md5 (Python standard library), not by the Swift implementation. Swift's LegacySubtaskConversionTests must reproduce them, and the Migration B SQL must reproduce them with md5(...)::uuid. Regenerate with `python3 Scripts/legacy_subtasks_fixture.py` and review the diff.",
    "id_cases": [],
    "trees": [],
    "references": [],
}

for rid, path in [
    ("11111111-1111-4111-8111-111111111111", ["a"]),
    ("11111111-1111-4111-8111-111111111111", ["a", "b", "c"]),
    ("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", ["a"]),            # upper-case root is lower-cased
    ("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ["@0", "@3"]),
    ("11111111-1111-4111-8111-111111111111", ["é/日本☃", "a|b"]),
    ("11111111-1111-4111-8111-111111111111", []),                 # empty path: separator-less tail
]:
    out["id_cases"].append({"root": rid, "path": path, "expected": legacy_child_id(rid, path)})

for name, r, subs in TREES:
    rows, skipped, reparented = convert(r, subs)
    out["trees"].append({"name": name, "root": r, "subtasks": subs, "expected_rows": rows, "expected_skipped": skipped, "expected_reparented": reparented})


def ref(rid, keys):
    return "subtask:" + base64.b64encode(json.dumps([rid] + keys, separators=(",", ":")).encode()).decode()


R1 = "11111111-1111-4111-8111-111111111111"
for tree, keys, resolvable in [("nested_with_fields", ["a"], True), ("nested_with_fields", ["a", "b", "c"], True), ("nested_with_fields", ["a", "nope"], False),
                               ("junk_nodes", ["ok"], True), ("junk_nodes", ["notitle"], False)]:
    t = next(t for t in TREES if t[0] == tree)
    rid = t[1]["id"]
    out["references"].append({"tree": tree, "reference": ref(rid, keys), "direct_id": legacy_child_id(rid, keys),
                              "expected_with_tree": legacy_child_id(rid, keys) if resolvable else None})

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TaskfoldTests", "Fixtures", "legacy_subtasks.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False, sort_keys=False)
    f.write("\n")
print("wrote", os.path.normpath(path), len(out["trees"]), "trees")
