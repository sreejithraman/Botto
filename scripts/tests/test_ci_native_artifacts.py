import glob
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-native.sh"
DEVICE = "D631DAA3-17A3-44CD-B6E9-B66986AA7312"


class NativeArtifactTests(unittest.TestCase):
    def run_native(self, status, *, build_status=0, produces_result=True, parent_inside_package=False, finalization_failure=None, suite="", passed_tests=1, workflow_event=None, cancel_stage="", cancel_signal=signal.SIGTERM):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name).resolve()
        repo = base / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT, repo / "scripts/check-native.sh")
        shutil.copy2(SCRIPT.parent / "dev-process.py", repo / "scripts/dev-process.py")
        tools = base / "bin"
        tools.mkdir()
        uuid = tools / "uuidgen"
        uuid.write_text("#!/bin/sh\nprintf 'fixture-run\\n'\n")
        uuid.chmod(0o755)
        xcode = tools / "xcodebuild"
        xcode.write_text('''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
args = sys.argv[1:]
action = args[0]
derived = Path(args[args.index("-derivedDataPath") + 1])
enumerating = "-enumerate-tests" in args
result = None if enumerating else Path(args[args.index("-resultBundlePath") + 1])
record = Path(os.environ["CI_COMMAND_RECORD"])
commands = json.loads(record.read_text()) if record.exists() else []
commands.append({"action": "enumerate" if enumerating else action, "derived": str(derived), "result": str(result),
                 "selection": [arg for arg in args if arg.startswith("-only-testing:")],
                 "parallel": args[args.index("-parallel-testing-enabled") + 1],
                 "diagnostics": args[args.index("-collect-test-diagnostics") + 1] if "-collect-test-diagnostics" in args else None,
                 "destination": args[args.index("-destination") + 1]})
record.write_text(json.dumps(commands))
def finish(status):
    if os.environ["CI_CANCEL_STAGE"] == ("enumerate" if enumerating else action):
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        target = Path(args[args.index("-test-enumeration-output-path") + 1]) if enumerating else result / "retained-proof"
        with target.open("a") as output:
            output.write("active writer\\n")
        writer_record = Path(os.environ["CI_WRITER_RECORD"])
        pending_record = writer_record.with_suffix(".tmp")
        pending_record.write_text(json.dumps({"pid": os.getpid(), "path": str(target)}))
        pending_record.replace(writer_record)
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            with target.open("a") as output:
                output.write("more evidence\\n")
            time.sleep(0.02)
        sys.exit(130)
    sys.exit(status)
if enumerating:
    assert (derived / "build-data").is_file()
    Path(args[args.index("-test-enumeration-output-path") + 1]).write_text(
        "BottoTests/FixtureTests/example()\\nBottoTests/OtherTests/unrelated()\\n")
    finish(0)
if action == "test-without-building":
    if not (derived / "build-data").is_file():
        sys.exit(98)
else:
    derived.mkdir(parents=True, exist_ok=True)
    (derived / "build-data").write_text("disposable build")
if action == "build-for-testing" or os.environ["CI_PRODUCES_RESULT"] == "1":
    result.mkdir()
    (result / "retained-proof").write_text(action + " proof")
print("native output")
finish(int(os.environ["CI_BUILD_STATUS"] if action == "build-for-testing" else os.environ["CI_NATIVE_STATUS"]))
''')
        xcode.chmod(0o755)
        xcrun = tools / "xcrun"
        xcrun.write_text(f'''#!{sys.executable}
import json, os, sys
assert sys.argv[1:5] == ["xcresulttool", "get", "test-results", "summary"]
print(json.dumps({{"passedTests": int(os.environ["CI_PASSED_TESTS"]), "failedTests": 0, "skippedTests": 0}}))
''')
        xcrun.chmod(0o755)
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
                           CI_COMMAND_RECORD=str(record), CI_NATIVE_STATUS=str(status), CI_BUILD_STATUS=str(build_status),
                           CI_PASSED_TESTS=str(passed_tests),
                           CI_CANCEL_STAGE=cancel_stage, CI_WRITER_RECORD=str(base / "writer.json"),
                           CI_PRODUCES_RESULT="1" if produces_result else "0")
        command = ["bash", str(repo / "scripts/check-native.sh"), suite]
        if workflow_event:
            workflow = (SCRIPT.parents[1] / ".github/workflows/ios.yml").read_text()
            step = workflow.split("        id: checks\n", 1)[1].split("      - name:", 1)[0]
            body = textwrap.dedent(step.split("        run: |\n", 1)[1])
            environment.update(GITHUB_EVENT_NAME=workflow_event, NATIVE_TEST=suite)
            command = ["bash", "-e", "-o", "pipefail", "-c", body]
        if cancel_stage:
            with (base / "stdout").open("w") as stdout, (base / "stderr").open("w") as stderr:
                process = subprocess.Popen(command, cwd=repo, env=environment, stdout=stdout, stderr=stderr)
                unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
                try:
                    deadline = time.monotonic() + 5
                    writer_record = base / "writer.json"
                    while not writer_record.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(writer_record.exists(), "Xcode never entered the active-writing stage")
                    writer = json.loads(writer_record.read_text())
                    process.send_signal(cancel_signal)
                    returncode = process.wait(timeout=5)
                    target = Path(writer["path"])
                    evidence = target.read_bytes() if target.exists() else None
                    time.sleep(0.15)
                    stable = evidence == (target.read_bytes() if target.exists() else None)
                    writer_state = subprocess.run(["ps", "-o", "stat=", "-p", str(writer["pid"])],
                                                  capture_output=True, text=True, check=False).stdout.strip()
                    self.assertIsNone(unrelated.poll(), "Cancellation reached an unrelated process")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
                    unrelated.terminate()
                    unrelated.wait(timeout=5)
            result = subprocess.CompletedProcess(command, returncode, (base / "stdout").read_text(),
                                                 (base / "stderr").read_text())
            result.writer_stable = stable
            result.writer_state = writer_state
            if writer_state and not writer_state.startswith("Z"):
                time.sleep(4)
        else:
            result = subprocess.run(command, cwd=repo,
                                    env=environment, capture_output=True, text=True, timeout=10)
        return repo, parent, record, result

    def assert_registered_artifacts(self, record, directory):
        paths = dict(line.split("=", 1) for line in (record.parent / "github-output").read_text().splitlines())
        self.assertEqual(Path(paths["native_result_fallback"]), directory / "CIResults-*.xcresult")
        self.assertEqual(Path(paths["native_selection_fallback"]), directory / "selected-tests.txt")
        return paths

    def upload_paths(self, outputs, repo):
        workflow = (SCRIPT.parents[1] / ".github/workflows/ios.yml").read_text()
        upload = workflow.split("      - name: Save native test results\n", 1)[1]
        paths = textwrap.dedent(upload.split("          path: |\n", 1)[1].split("          include-hidden-files:", 1)[0])
        for name, value in outputs.items():
            paths = paths.replace("${{ steps.checks.outputs." + name + " }}", value)
        return {Path(match) for pattern in paths.splitlines() if pattern.strip()
                for match in glob.glob(str(repo / pattern.strip()))}

    def test_outer_workflow_cancellation_stops_the_writer_before_artifact_upload(self):
        for stage, event, suite in (("build-for-testing", "pull_request", ""),
                                    ("enumerate", "workflow_dispatch", "FixtureTests"),
                                    ("test-without-building", "push", "")):
            for sig in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(stage=stage, signal=sig):
                    repo, parent, record, result = self.run_native(
                        0, workflow_event=event, suite=suite, cancel_stage=stage, cancel_signal=sig)
                    self.assertEqual(result.returncode, 128 + sig, result.stderr)
                    self.assertTrue(result.writer_stable, "An Xcode writer mutated its result after the workflow owner exited")
                    self.assertTrue(not result.writer_state or result.writer_state.startswith("Z"), result.writer_state)
                    commands = json.loads(record.read_text())
                    directory = Path(commands[-1]["derived"]).parent
                    paths = self.assert_registered_artifacts(record, directory)
                    bundles = list(directory.glob("CIResults-*.xcresult"))
                    self.assertTrue(bundles)
                    upload = self.upload_paths(paths, repo)
                    self.assertTrue(set(bundles).issubset(upload))
                    self.assertTrue(all((bundle / "retained-proof").is_file() for bundle in bundles))
                    self.assertNotIn(directory / "DerivedData", upload)
                    if stage == "enumerate":
                        self.assertIn(Path(paths["native_selection_fallback"]), upload)
                    self.assertTrue((directory / "DerivedData/build-data").is_file(), "Cancellation must leave its partial outputs in place")
                    self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_outputs_are_external_and_results_survive_success_or_failure(self):
        for status in (0, 65):
            with self.subTest(native_status=status):
                repo, parent, record, result = self.run_native(status)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("native output", result.stdout)
                commands = json.loads(record.read_text())
                self.assertEqual([command["action"] for command in commands], ["build-for-testing", "test-without-building"])
                self.assertEqual(commands[0]["derived"], commands[1]["derived"])
                self.assertEqual({command["destination"] for command in commands}, {f"platform=iOS Simulator,id={DEVICE}"})
                self.assertTrue(all(command["selection"] == ["-only-testing:BottoTests"] for command in commands))
                self.assertTrue(all(command["parallel"] == "NO" for command in commands))
                self.assertTrue(all(command["diagnostics"] == "never" for command in commands))
                for command in commands:
                    for key in ("derived", "result"):
                        path = Path(command[key])
                        self.assertTrue(path.is_relative_to(parent))
                        self.assertFalse(path.is_relative_to(repo))
                        self.assertFalse(path.exists())
                retained = repo / ".artifacts/CIResults-fixture-run.xcresult/retained-proof"
                self.assertEqual(retained.read_text(), "test-without-building proof")
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
                    captured = json.loads(record.read_text())[-1]
                    directory = Path(captured["derived"]).parent
                    self.assertTrue(directory.is_dir())
                    self.assertIn(str(directory), result.stderr)
                    self.assert_registered_artifacts(record, directory)
                    if command == "rm":
                        self.assertEqual((repo / ".artifacts/CIResults-fixture-run.xcresult/retained-proof").read_text(), "test-without-building proof")
                    else:
                        self.assertEqual((Path(captured["result"]) / "retained-proof").read_text(), "test-without-building proof")
                    self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_build_failure_skips_tests_and_retains_its_result_and_status(self):
        for failure in (None, "mv"):
            with self.subTest(finalization_failure=failure):
                repo, parent, record, result = self.run_native(0, build_status=66, finalization_failure=failure)
                self.assertEqual(result.returncode, 66, result.stderr)
                commands = json.loads(record.read_text())
                self.assertEqual([command["action"] for command in commands], ["build-for-testing"])
                build = commands[0]
                retained = repo / ".artifacts/CIResults-Build-fixture-run.xcresult/retained-proof"
                if failure:
                    retained = Path(build["result"]) / "retained-proof"
                    self.assert_registered_artifacts(record, Path(build["derived"]).parent)
                else:
                    self.assertEqual([path.name for path in parent.iterdir()], ["unrelated-data"])
                self.assertEqual(retained.read_text(), "build-for-testing proof")
                self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_pull_request_build_mode_does_not_execute_native_tests(self):
        for build_status in (0, 66):
            with self.subTest(build_status=build_status):
                repo, _, record, result = self.run_native(
                    0, build_status=build_status, suite="--build-only", passed_tests=0)
                self.assertEqual(result.returncode, build_status, result.stderr)
                commands = json.loads(record.read_text())
                self.assertEqual([command["action"] for command in commands], ["build-for-testing"])
                retained = repo / ".artifacts/CIResults-Build-fixture-run.xcresult/retained-proof"
                self.assertEqual(retained.read_text(), "build-for-testing proof")
                if not build_status:
                    self.assertIn("Native tests were built but not executed", result.stdout)

    def test_manual_input_cannot_select_the_pull_request_build_mode(self):
        _, _, record, result = self.run_native(0, suite="--build-only", workflow_event="workflow_dispatch")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(record.exists(), "Invalid diagnostic input must fail before Xcode")

    def test_workflow_events_preserve_build_only_and_test_execution_boundaries(self):
        for event, selector, actions in (
            ("pull_request", "", ["build-for-testing"]),
            ("push", "", ["build-for-testing", "test-without-building"]),
            ("workflow_dispatch", "FixtureTests", ["build-for-testing", "enumerate", "test-without-building"]),
        ):
            with self.subTest(event=event):
                _, _, record, result = self.run_native(0, suite=selector, workflow_event=event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([call["action"] for call in json.loads(record.read_text())], actions)

    def test_parent_inside_the_package_is_rejected(self):
        _, parent, record, result = self.run_native(0, parent_inside_package=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the local Swift package", result.stderr)
        self.assertFalse(record.exists())
        self.assertEqual([path.name for path in parent.iterdir()], ["unrelated-data"])
        self.assertEqual((parent / "unrelated-data").read_text(), "keep")

    def test_focused_run_selects_only_the_named_suite(self):
        _, _, record, result = self.run_native(0, suite="FixtureTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(command["selection"] == ["-only-testing:BottoTests/FixtureTests"]
                            for command in json.loads(record.read_text())))

    def test_focused_discovery_artifact_failure_keeps_the_native_verdict_and_result(self):
        for status in (0, 65):
            with self.subTest(status=status):
                _, _, record, result = self.run_native(status, suite="FixtureTests", finalization_failure="cp")
                self.assertEqual(result.returncode, status or 73)
                last = json.loads(record.read_text())[-1]
                self.assertEqual((Path(last["result"]) / "retained-proof").read_text(), "test-without-building proof")
                self.assert_registered_artifacts(record, Path(last["derived"]).parent)

    def test_focused_run_can_select_an_exact_test(self):
        _, _, record, result = self.run_native(0, suite="FixtureTests/example()")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(command["selection"] == ["-only-testing:BottoTests/FixtureTests/example()"]
                            for command in json.loads(record.read_text())))

    def test_invalid_selector_syntax_stops_before_xcode(self):
        for suite in ("FixtureTests; touch other-data", "../FixtureTests"):
            with self.subTest(suite=suite):
                _, _, record, result = self.run_native(0, suite=suite)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(record.exists())

    def test_framework_discovery_rejects_helpers_wrong_labels_and_another_suites_method(self):
        for selector in ("MissingTests", "FixtureTests/helper()", "FixtureTests/example(wrong:)",
                         "FixtureTests/unrelated()"):
            with self.subTest(selector=selector):
                repo, _, record, result = self.run_native(0, suite=selector)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([c["action"] for c in json.loads(record.read_text())],
                                 ["build-for-testing", "enumerate"])
                self.assertEqual((repo / ".artifacts/CIResults-Build-fixture-run.xcresult/retained-proof").read_text(),
                                 "build-for-testing proof")

    def test_empty_success_cannot_claim_native_coverage_and_keeps_its_result(self):
        repo, parent, _, result = self.run_native(0, passed_tests=0)
        self.assertNotEqual(result.returncode, 0)
        retained = repo / ".artifacts/CIResults-fixture-run.xcresult/retained-proof"
        self.assertEqual(retained.read_text(), "test-without-building proof")
        self.assertEqual([path.name for path in parent.iterdir()], ["unrelated-data"])


if __name__ == "__main__":
    unittest.main()
