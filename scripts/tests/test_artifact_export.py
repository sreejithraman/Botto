import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "verify-artifact-export.py"
ORIGINAL = b"Canvas demo\n\nDraft, review, then publish. All sample files stay on this device.\n"


class ArtifactExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="botto-export-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.devices = self.root / "devices"
        self.device_id = str(uuid.uuid4()).upper()
        self.device = self.devices / self.device_id
        self.device.mkdir(parents=True)
        with (self.device / "device.plist").open("wb") as handle:
            plistlib.dump({"UDID": self.device_id, "name": "Owned fixture iPhone"}, handle)
        self.storage = self.device / "data/Containers/Shared/AppGroup" / str(uuid.uuid4()).upper() / "File Provider Storage"
        self.storage.mkdir(parents=True)
        with (self.storage.parent / ".com.apple.mobile_container_manager.metadata.plist").open("wb") as handle:
            plistlib.dump({"MCMMetadataIdentifier": "group.com.apple.FileProvider.LocalStorage"}, handle)
        self.started = time.time() - 1
        self.absence = self.root / "absence.json"

    def run_verifier(self, *extra, filename="notes.txt", receipt=None, expected=0):
        receipt = receipt or self.root / (str(uuid.uuid4()) + "-result.json")
        result = subprocess.run([sys.executable, str(SCRIPT), "--device", self.device_id,
                                 "--device-set", str(self.devices), "--filename", filename,
                                 "--not-before", str(self.started), "--receipt", str(receipt),
                                 *map(str, extra)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(receipt.read_text()) if expected != 2 and receipt.exists() else None

    def test_default_name_requires_a_bound_absence_then_fresh_original_bytes(self):
        baseline = self.run_verifier("--require-absent", receipt=self.absence)
        self.assertEqual(baseline["status"], "absent")
        self.assertFalse((self.storage / "notes.txt").exists())
        (self.storage / "notes.txt").write_bytes(ORIGINAL)
        result = self.run_verifier("--absence-receipt", self.absence)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["saved_bytes"], 80)
        self.assertEqual(result["saved_sha256"], "ab2d37c15d4277807c8d7c9ac788d680ce95645b07a1d0e61ee34005a2b41cce")
        self.assertTrue(result["byte_identical"])

    def test_preexisting_default_cannot_be_certified_absent(self):
        saved = self.storage / "notes.txt"
        saved.write_bytes(ORIGINAL)
        result = self.run_verifier("--require-absent", receipt=self.absence, expected=1)
        self.assertEqual(result["status"], "failed")
        self.assertIn("preexisting", result["error"])
        self.assertEqual(saved.read_bytes(), ORIGINAL)

    def test_default_name_without_absence_evidence_is_rejected(self):
        (self.storage / "notes.txt").write_bytes(ORIGINAL)
        result = self.run_verifier(expected=1)
        self.assertIn("--absence-receipt", result["error"])

    def test_linked_absence_or_multiple_saved_candidates_do_not_pass(self):
        self.run_verifier("--require-absent", receipt=self.absence)
        saved = self.storage / "notes.txt"
        saved.write_bytes(ORIGINAL)
        linked_receipt = self.root / "linked-absence.json"
        linked_receipt.symlink_to(self.absence)
        linked = self.run_verifier("--absence-receipt", linked_receipt, expected=1)
        self.assertIn("Symlink", linked["error"])
        duplicate = self.storage / "Other" / "notes.txt"
        duplicate.parent.mkdir()
        duplicate.write_bytes(ORIGINAL)
        ambiguous = self.run_verifier("--absence-receipt", self.absence, expected=1)
        self.assertIn("found 2", ambiguous["error"])

    def test_absence_is_bound_to_success_device_filename_start_and_time(self):
        baseline = self.run_verifier("--require-absent", receipt=self.absence)
        (self.storage / "notes.txt").write_bytes(ORIGINAL)
        for key, value in [("status", "failed"), ("record_kind", "unrelated"),
                           ("device_udid", str(uuid.uuid4())), ("saved_filename", "other.txt"),
                           ("not_before", self.started - 10), ("checked_unix_seconds", float("nan")),
                           ("checked_unix_seconds", time.time() + 60)]:
            with self.subTest(key=key, value=value):
                self.absence.write_text(json.dumps({**baseline, key: value}))
                result = self.run_verifier("--absence-receipt", self.absence, expected=1)
                self.assertEqual(result["status"], "failed")

    def test_old_or_changed_bytes_do_not_pass_after_absence(self):
        self.run_verifier("--require-absent", receipt=self.absence)
        saved = self.storage / "notes.txt"
        saved.write_bytes(ORIGINAL)
        os.utime(saved, (self.started, self.started))
        stale = self.run_verifier("--absence-receipt", self.absence, expected=1)
        self.assertIn("predates", stale["error"])
        saved.write_bytes(b"Changed export bytes")
        fresh = time.time()
        os.utime(saved, (fresh, fresh))
        changed = self.run_verifier("--absence-receipt", self.absence, expected=1)
        self.assertIn("differs from the original", changed["error"])

    def test_absence_can_precede_provider_creation_without_creating_it(self):
        shutil.rmtree(self.device / "data")
        result = self.run_verifier("--require-absent", receipt=self.absence)
        self.assertEqual(result["status"], "absent")
        self.assertFalse((self.device / "data").exists())

    def test_a_linked_provider_path_cannot_prove_absence(self):
        outside = self.root / "existing-original"
        outside.write_bytes(ORIGINAL)
        (self.storage / "notes.txt").symlink_to(outside)
        linked_file = self.run_verifier("--require-absent", receipt=self.absence, expected=1)
        self.assertIn("preexisting", linked_file["error"])
        (self.storage / "notes.txt").unlink()
        (self.storage / "linked-directory").symlink_to(self.root, target_is_directory=True)
        linked_directory = self.run_verifier("--require-absent", receipt=self.root / "linked-dir-absence.json", expected=1)
        self.assertIn("linked provider directory", linked_directory["error"])

    def test_linked_metadata_cannot_hide_a_provider_from_the_absence_check(self):
        metadata = self.storage.parent / ".com.apple.mobile_container_manager.metadata.plist"
        metadata.unlink()
        metadata.symlink_to(self.root / "missing-metadata")
        result = self.run_verifier("--require-absent", receipt=self.absence, expected=1)
        self.assertIn("Symlink", result["error"])

    def test_case_alias_cannot_be_certified_absent(self):
        (self.storage / "Notes.txt").write_bytes(ORIGINAL)
        result = self.run_verifier("--require-absent", receipt=self.absence, expected=1)
        self.assertEqual(result["status"], "failed")

    def test_unknown_provider_storage_cannot_be_certified_absent(self):
        (self.storage / "notes.txt").write_bytes(ORIGINAL)
        metadata = self.storage.parent / ".com.apple.mobile_container_manager.metadata.plist"
        metadata.unlink()
        result = self.run_verifier("--require-absent", receipt=self.absence, expected=1)
        self.assertEqual(result["status"], "failed")

    def test_provider_storage_without_owner_cannot_be_certified_absent(self):
        metadata = self.storage.parent / ".com.apple.mobile_container_manager.metadata.plist"
        with metadata.open("wb") as handle:
            plistlib.dump({}, handle)
        result = self.run_verifier("--require-absent", receipt=self.absence, expected=1)
        self.assertEqual(result["status"], "failed")

    def test_a_second_preflight_cannot_replace_prior_absence_evidence(self):
        self.run_verifier("--require-absent", receipt=self.absence)
        original = self.absence.read_bytes()
        (self.storage / "notes.txt").write_bytes(ORIGINAL)
        self.run_verifier("--require-absent", receipt=self.absence, expected=2)
        self.assertEqual(self.absence.read_bytes(), original)

    def test_absence_from_a_cloned_device_set_cannot_authorize_readback(self):
        self.run_verifier("--require-absent", receipt=self.absence)
        other_set = self.root / "other-devices"
        shutil.copytree(self.devices, other_set)
        other_storage = other_set / self.storage.relative_to(self.devices)
        (other_storage / "notes.txt").write_bytes(ORIGINAL)
        result = self.run_verifier("--absence-receipt", self.absence,
                                   "--device-set", other_set, expected=1)
        self.assertEqual(result["status"], "failed")

    def test_legacy_uuid_original_still_passes_without_absence_mode(self):
        filename = "botto-artifact-export-proof-" + str(uuid.uuid4()) + ".txt"
        (self.storage / filename).write_bytes(ORIGINAL)
        result = self.run_verifier(filename=filename)
        self.assertTrue(result["byte_identical"])
        self.assertEqual(result["provider_owner"], "group.com.apple.FileProvider.LocalStorage")

    def test_wrong_provider_temporary_and_linked_originals_stay_rejected(self):
        filename = "botto-artifact-export-proof-" + str(uuid.uuid4()) + ".txt"
        saved = self.storage / filename
        saved.write_bytes(ORIGINAL)
        metadata = self.storage.parent / ".com.apple.mobile_container_manager.metadata.plist"
        with metadata.open("wb") as handle:
            plistlib.dump({"MCMMetadataIdentifier": "group.another-provider"}, handle)
        wrong_owner = self.run_verifier("--saved", saved, filename=filename, expected=1)
        self.assertIn("Wrong provider", wrong_owner["error"])
        with metadata.open("wb") as handle:
            plistlib.dump({"MCMMetadataIdentifier": "group.com.apple.FileProvider.LocalStorage"}, handle)
        temporary = self.storage / "tmp" / filename
        temporary.parent.mkdir()
        temporary.write_bytes(ORIGINAL)
        temp_result = self.run_verifier("--saved", temporary, filename=filename, expected=1)
        self.assertIn("Temporary", temp_result["error"])
        saved.unlink()
        saved.symlink_to(temporary)
        linked = self.run_verifier("--saved", saved, filename=filename, expected=1)
        self.assertIn("Symlink", linked["error"])

    def test_result_receipts_cannot_replace_saved_bytes_or_absence_evidence(self):
        self.run_verifier("--require-absent", receipt=self.absence)
        saved = self.storage / "notes.txt"
        saved.write_bytes(ORIGINAL)
        self.run_verifier("--absence-receipt", self.absence, receipt=self.absence, expected=2)
        self.assertEqual(json.loads(self.absence.read_text())["status"], "absent")
        self.run_verifier("--saved", saved, receipt=saved, expected=2)
        self.assertEqual(saved.read_bytes(), ORIGINAL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
