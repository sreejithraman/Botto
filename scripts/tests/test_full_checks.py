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
            "    calls.write(json.dumps({'name': name, 'args': sys.argv[1:]}) + '\\n')\n"
            "if name == 'xcrun':\n"
            "    print(json.dumps({'devices': {'test': [{'udid': 'test-phone', 'name': 'iPhone test'}]}}))\n"
            "if name == 'verify-artifact-export.py':\n"
            "    receipt = pathlib.Path(sys.argv[sys.argv.index('--receipt') + 1])\n"
            "    receipt.parent.mkdir(parents=True, exist_ok=True)\n"
            "    receipt.write_text('{}')\n"
            "sys.exit(int(os.environ.get('BOTTO_FULL_CHECK_TEST_STATUS', '0')) if name == 'xcodebuild'\n"
            "         else int(os.environ.get('BOTTO_FULL_CHECK_EXPORT_STATUS', '0'))\n"
            "         if name == 'verify-artifact-export.py' else 0)\n"
        )
        for name in ("swift", "xcrun", "xcodebuild"):
            executable = binary_directory / name
            executable.write_text(stub)
            executable.chmod(0o755)
        (scripts / "verify-artifact-export.py").write_text(stub)
        self.env = {key: value for key, value in os.environ.items() if key != "BOTTO_TEST_DIAGNOSTICS"}
        self.env.update(PATH=str(binary_directory) + os.pathsep + os.environ["PATH"],
                        BOTTO_FULL_CHECK_CALLS=str(self.calls))

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
        self.assertTrue((self.repo / ".artifacts/artifact-export-receipt.json").exists())

    def test_explicit_diagnostics_and_export_failure_status(self):
        self.env["BOTTO_TEST_DIAGNOSTICS"] = "on-failure"
        self.env["BOTTO_FULL_CHECK_EXPORT_STATUS"] = "7"
        calls = self.run_checks(7)
        test = next(call for call in calls if call["name"] == "xcodebuild")
        index = test["args"].index("-collect-test-diagnostics")
        self.assertEqual(test["args"][index + 1], "on-failure")

    def test_invalid_diagnostics_stops_before_running_checks(self):
        self.env["BOTTO_TEST_DIAGNOSTICS"] = "invalid"
        self.assertEqual(self.run_checks(2), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
