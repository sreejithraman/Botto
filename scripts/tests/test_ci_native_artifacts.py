import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-ci.sh"
DEVICE = "D631DAA3-17A3-44CD-B6E9-B66986AA7312"


class NativeArtifactTests(unittest.TestCase):
    def run_native(self, status, *, produces_result=True, parent_inside_package=False, finalization_failure=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name).resolve()
        repo = base / "repo"
        (repo / "scripts/tests").mkdir(parents=True)
        shutil.copy2(SCRIPT, repo / "scripts/check-ci.sh")
        core = repo / "scripts/check-core.sh"
        core.write_text("#!/bin/bash\nexit 0\n")
        core.chmod(0o755)
        tools = base / "bin"
        tools.mkdir()
        uuid = tools / "uuidgen"
        uuid.write_text("#!/bin/sh\nprintf 'fixture-run\\n'\n")
        uuid.chmod(0o755)
        xcode = tools / "xcodebuild"
        xcode.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
derived = Path(args[args.index("-derivedDataPath") + 1])
result = Path(args[args.index("-resultBundlePath") + 1])
Path(os.environ["CI_COMMAND_RECORD"]).write_text(json.dumps({"derived": str(derived), "result": str(result)}))
derived.mkdir(parents=True)
(derived / "build-data").write_text("disposable build")
if os.environ["CI_PRODUCES_RESULT"] == "1":
    result.mkdir()
    (result / "retained-proof").write_text("native proof")
print("native output")
sys.exit(int(os.environ["CI_NATIVE_STATUS"]))
''')
        xcode.chmod(0o755)
        if finalization_failure:
            failure = tools / finalization_failure
            failure.write_text("#!/bin/sh\nexit 73\n")
            failure.chmod(0o755)
        parent = (repo if parent_inside_package else base) / "native-temp"
        parent.mkdir()
        (parent / "unrelated-data").write_text("keep")
        record = base / "command.json"
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                           RUNNER_TEMP=str(parent), BOTTO_TEST_DESTINATION=f"platform=iOS Simulator,id={DEVICE}",
                           GITHUB_OUTPUT=str(base / "github-output"),
                           CI_COMMAND_RECORD=str(record), CI_NATIVE_STATUS=str(status),
                           CI_PRODUCES_RESULT="1" if produces_result else "0")
        result = subprocess.run(["bash", str(repo / "scripts/check-ci.sh")], cwd=repo,
                                env=environment, capture_output=True, text=True, timeout=10)
        return repo, parent, record, result

    def test_outputs_are_external_and_results_survive_success_or_failure(self):
        for status in (0, 65):
            with self.subTest(native_status=status):
                repo, parent, record, result = self.run_native(status)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("native output", result.stdout)
                command = json.loads(record.read_text())
                for path in command.values():
                    self.assertTrue(Path(path).is_relative_to(parent))
                    self.assertFalse(Path(path).is_relative_to(repo))
                    self.assertFalse(Path(path).exists())
                retained = repo / ".artifacts/CIResults-fixture-run.xcresult/retained-proof"
                self.assertEqual(retained.read_text(), "native proof")
                self.assertEqual([path.name for path in parent.iterdir()], ["unrelated-data"])
                self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_failure_without_a_result_retains_native_exit_status(self):
        repo, parent, _, result = self.run_native(2, produces_result=False)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(list((repo / ".artifacts").iterdir()), [])
        self.assertEqual([path.name for path in parent.iterdir()], ["unrelated-data"])
        self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_finalization_failure_preserves_native_verdict_and_evidence(self):
        for command in ("mkdir", "mv", "rm"):
            for native_status in (0, 65):
                with self.subTest(command=command, native_status=native_status):
                    repo, parent, record, result = self.run_native(native_status, finalization_failure=command)
                    self.assertEqual(result.returncode, native_status or 73, result.stderr)
                    captured = json.loads(record.read_text())
                    directory = Path(captured["derived"]).parent
                    self.assertTrue(directory.is_dir())
                    self.assertIn(str(directory), result.stderr)
                    output = record.parent / "github-output"
                    if command == "rm":
                        self.assertEqual((repo / ".artifacts/CIResults-fixture-run.xcresult/retained-proof").read_text(), "native proof")
                        self.assertFalse(output.exists())
                    else:
                        self.assertEqual((Path(captured["result"]) / "retained-proof").read_text(), "native proof")
                        self.assertEqual(output.read_text(), "native_result_fallback=" + captured["result"] + "\n")
                    self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_parent_inside_the_package_is_rejected(self):
        _, parent, record, result = self.run_native(0, parent_inside_package=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the local Swift package", result.stderr)
        self.assertFalse(record.exists())
        self.assertEqual([path.name for path in parent.iterdir()], ["unrelated-data"])
        self.assertEqual((parent / "unrelated-data").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
