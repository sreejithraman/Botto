import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class FullChecksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="botto-full-checks-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.repo = self.directory / "repo with spaces"
        scripts = self.repo / "scripts"
        scripts.mkdir(parents=True)
        for name in ("check.sh", "check-core.sh"):
            shutil.copy2(SOURCE_ROOT / "scripts" / name, scripts / name)
        self.calls = self.directory / "calls.jsonl"
        binary_directory = self.directory / "bin"
        binary_directory.mkdir()
        stub = (
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "name = pathlib.Path(sys.argv[0]).name\n"
            "with open(os.environ['BOTTO_FULL_CHECK_CALLS'], 'a') as calls:\n"
            "    calls.write(json.dumps({'name': name, 'args': sys.argv[1:], 'absence': os.environ.get('TEST_RUNNER_BOTTO_ARTIFACT_EXPORT_ABSENCE')}) + '\\n')\n"
            "if name == 'xcrun':\n"
            "    print(json.dumps({'devices': {'test': [{'udid': 'test-phone', 'name': 'iPhone test'}]}}))\n"
            "if name == 'verify-artifact-export.py':\n"
            "    receipt = pathlib.Path(sys.argv[sys.argv.index('--receipt') + 1])\n"
            "    receipt.parent.mkdir(parents=True, exist_ok=True)\n"
            "    before = '--require-absent' in sys.argv\n"
            "    failed = int(os.environ.get('BOTTO_FULL_CHECK_ABSENCE_STATUS' if before else 'BOTTO_FULL_CHECK_EXPORT_STATUS', '0'))\n"
            "    receipt.write_text(json.dumps({'status': ('failed' if failed else 'absent') if before else 'passed', 'saved_filename': 'notes.txt'}))\n"
            "sys.exit(int(os.environ.get('BOTTO_FULL_CHECK_TEST_STATUS', '0')) if name == 'xcodebuild'\n"
            "         else int(os.environ.get('BOTTO_FULL_CHECK_ABSENCE_STATUS' if '--require-absent' in sys.argv else 'BOTTO_FULL_CHECK_EXPORT_STATUS', '0'))\n"
            "         if name == 'verify-artifact-export.py' else 0)\n"
        )
        for name in ("swift", "xcrun", "xcodebuild"):
            executable = binary_directory / name
            executable.write_text(stub)
            executable.chmod(0o755)
        (scripts / "verify-artifact-export.py").write_text(stub)
        self.env = {key: value for key, value in os.environ.items() if key != "BOTTO_TEST_DIAGNOSTICS"}
        self.env.update(PATH=str(binary_directory) + os.pathsep + os.environ["PATH"],
                        BOTTO_FULL_CHECK_CALLS=str(self.calls),
                        BOTTO_TEST_DESTINATION="platform=iOS Simulator,id=D631DAA3-17A3-44CD-B6E9-B66986AA7312")

    def run_checks(self, expected):
        result = subprocess.run([str(self.repo / "scripts/check.sh")], cwd=self.directory,
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_failed_tests_disable_verbose_diagnostics_and_still_read_back_export(self):
        self.env["BOTTO_FULL_CHECK_TEST_STATUS"] = "65"
        self.env["BOTTO_FULL_CHECK_EXPORT_STATUS"] = "7"
        calls = self.run_checks(65)
        test = next(call for call in calls if call["name"] == "xcodebuild")
        index = test["args"].index("-collect-test-diagnostics")
        self.assertEqual(test["args"][index + 1], "never")
        self.assertEqual(calls[-1]["name"], "verify-artifact-export.py")
        self.assertEqual(len(list((self.repo / ".artifacts").glob("artifact-export.*/result.json"))), 1)
        verifications = [call for call in calls if call["name"] == "verify-artifact-export.py"]
        self.assertEqual(len(verifications), 2)
        self.assertIn("--require-absent", verifications[0]["args"])
        self.assertIn("--absence-receipt", verifications[1]["args"])
        for flag in ("--device", "--filename", "--not-before"):
            values = [call["args"][call["args"].index(flag) + 1] for call in verifications]
            self.assertEqual(values[0], values[1])
        self.assertEqual(verifications[0]["args"][verifications[0]["args"].index("--filename") + 1], "notes.txt")

    def test_explicit_diagnostics_and_export_failure_status(self):
        self.env["BOTTO_TEST_DIAGNOSTICS"] = "on-failure"
        self.env["BOTTO_FULL_CHECK_EXPORT_STATUS"] = "7"
        calls = self.run_checks(7)
        test = next(call for call in calls if call["name"] == "xcodebuild")
        index = test["args"].index("-collect-test-diagnostics")
        self.assertEqual(test["args"][index + 1], "on-failure")

    def test_existing_provider_file_stops_before_running_tests(self):
        self.env["BOTTO_FULL_CHECK_ABSENCE_STATUS"] = "7"
        calls = self.run_checks(7)
        self.assertFalse(any(call["name"] == "xcodebuild" for call in calls))
        self.assertEqual(calls[-1]["name"], "verify-artifact-export.py")
        self.assertIn("--require-absent", calls[-1]["args"])

    def test_missing_owned_destination_stops_before_checks(self):
        self.env.pop("BOTTO_TEST_DESTINATION")
        self.assertEqual(self.run_checks(2), [])

    def test_owned_destination_and_preflight_are_forwarded_to_ui(self):
        calls = self.run_checks(0)
        native = next(call for call in calls if call["name"] == "xcodebuild")
        index = native["args"].index("-destination")
        self.assertEqual(native["args"][index + 1], self.env["BOTTO_TEST_DESTINATION"])
        evidence = json.loads(native["absence"])
        self.assertEqual(evidence["status"], "absent")
        self.assertEqual(evidence["saved_filename"], "notes.txt")

    def test_failed_repeat_preserves_previous_run_evidence(self):
        self.run_checks(0)
        receipts = list((self.repo / ".artifacts").glob("artifact-export.*/*.json"))
        self.assertEqual(len(receipts), 2)
        previous = {path: path.read_bytes() for path in receipts}
        self.env["BOTTO_FULL_CHECK_ABSENCE_STATUS"] = "7"
        self.run_checks(7)
        self.assertTrue(all(path.read_bytes() == data for path, data in previous.items()))
        self.assertEqual(len(list((self.repo / ".artifacts").glob("artifact-export.*"))), 2)

    def test_invalid_diagnostics_stops_before_running_checks(self):
        self.env["BOTTO_TEST_DIAGNOSTICS"] = "invalid"
        self.assertEqual(self.run_checks(2), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
