#!/usr/bin/env python3
"""Adversarial checks against the retained actual native project-change snapshots."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import verify_assignment_native as verifier


class NativeAssignmentVerifierTests(unittest.TestCase):
    def setUp(self):
        fixture = Path(__file__).resolve().parents[1] / "docs/assignment-tree-native/phone"
        self.temporary = tempfile.TemporaryDirectory(prefix="taskfold-assignment-verifier-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        shutil.copytree(fixture / "attachments", self.directory / "attachments")
        shutil.copy2(fixture / "test-summary.json", self.directory / "summary.json")
        self.attachments = self.directory / "attachments"
        self.summary = self.directory / "summary.json"

    def snapshot(self, test, prefix, last=False):
        manifest = json.loads((self.attachments / "manifest.json").read_text())
        group = next(g for g in manifest if g["testIdentifier"].endswith("/" + test))
        items = sorted((a for a in group["attachments"] if a["suggestedHumanReadableName"].startswith(prefix)), key=lambda a: a["timestamp"])
        return self.attachments / items[-1 if last else 0]["exportedFileName"]

    def corrupt_cold(self, before, after):
        path = self.snapshot(verifier.MOVE, "Actual saved project change cache", last=True)
        data = path.read_text()
        self.assertIn(before, data)
        path.write_text(data.replace(before, after, 1))

    def verify(self):
        return verifier.verify(self.attachments, self.summary)

    def test_accepts_actual_native_snapshots(self):
        report = self.verify()
        self.assertTrue(report["passed"])
        self.assertEqual(len(report["attachments"]), 6)

    def test_rejects_rounded_large_integer(self):
        self.corrupt_cold('"é":9007199254740993', '"é":9007199254740992')
        with self.assertRaisesRegex(ValueError, "move changed"):
            self.verify()

    def test_rejects_distinct_unicode_key_loss(self):
        self.corrupt_cold('"e\\u0301":17', '"other":17')
        with self.assertRaisesRegex(ValueError, "move changed"):
            self.verify()

    def test_rejects_boolean_replaced_by_number(self):
        self.corrupt_cold('"completed":false', '"completed":0')
        with self.assertRaisesRegex(ValueError, "move changed"):
            self.verify()

    def test_rejects_modified_unsupported_source(self):
        path = self.snapshot(verifier.REFUSAL, "Unsupported source after cold return")
        data = path.read_text(); self.assertIn(verifier.SOURCE, data)
        path.write_text(data.replace(verifier.SOURCE, verifier.DESTINATION))
        with self.assertRaisesRegex(ValueError, "Refusal/cold return"):
            self.verify()

    def test_rejects_failed_or_skipped_native_summary(self):
        original = json.loads(self.summary.read_text())
        for field in ["failedTests", "skippedTests", "expectedFailures"]:
            with self.subTest(field=field):
                summary = dict(original); summary[field] = 1
                self.summary.write_text(json.dumps(summary))
                with self.assertRaisesRegex(ValueError, "Both native tests"):
                    self.verify()

    def test_rejects_snapshots_from_another_device(self):
        path = self.attachments / "manifest.json"; manifest = json.loads(path.read_text())
        for group in manifest:
            for item in group["attachments"]:
                item["deviceId"] = "foreign-device"
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "another destination"):
            self.verify()

    def test_rejects_attachment_path_traversal(self):
        path = self.attachments / "manifest.json"; manifest = json.loads(path.read_text())
        for group in manifest:
            for item in group["attachments"]:
                if item["suggestedHumanReadableName"].startswith("Original project change source"):
                    item["exportedFileName"] = "../summary.json"
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "Invalid attachment path"):
            self.verify()


if __name__ == "__main__":
    unittest.main(verbosity=2)
