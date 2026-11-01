#!/usr/bin/env python3
"""Diagnostic branch only: four real-scheduler cohorts on one host/build."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / "dev-host"))
from process_groups import child_exited, stop_group


# Method counts from the executed 3867874 baseline, not the discovery catalogue.
COHORT = {
    "DemoAvatarActivityTests": 2,
    "DemoConversationTests": 21,
    "InboxPreviewRenderingTests": 1,
    "AdaptiveWorkspaceTests": 17,
    "AppStoreAvatarTests": 32,
}
ARMS = (("A1", "utility"), ("B1", "userInitiated"), ("B2", "userInitiated"), ("A2", "utility"))


def bounded(command, seconds, *, environment=None):
    if seconds <= 0:
        return 124
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    deadline = time.monotonic() + seconds
    timed_out = False
    try:
        while not child_exited(process):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            time.sleep(min(.1, remaining))
    finally:
        # Retain the unreaped leader through group retirement, even after normal exit.
        # Only this invocation's process group; never a Simulator service.
        stop_group(process, grace=5 if timed_out else 0)
    return 124 if timed_out else process.returncode


def read_result(verb, result):
    output = subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", verb, "--path", str(result)],
        text=True, timeout=30,
    )
    return json.loads(output)


def executed_methods(tree):
    methods = []

    def visit(node):
        if node.get("nodeType") == "Test Case":
            methods.append(node)
        for child in node.get("children", []):
            visit(child)

    for node in tree["testNodes"]:
        visit(node)
    return methods


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: avatar-priority-ab.py 'platform=iOS Simulator,id=OWNED-UUID'")
    repo = Path(__file__).resolve().parents[1]
    os.chdir(repo)
    parent = Path(os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp").resolve()
    if parent.is_relative_to(repo):
        sys.exit("Native outputs must stay outside the local Swift package.")
    workspace = Path(tempfile.mkdtemp(prefix="botto-avatar-priority-", dir=parent))
    results = workspace / "Results"
    results.mkdir()
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write(f"native_result_fallback={results}\n")
    run_id = str(uuid.uuid4())
    receipt_path = results / "avatar-priority-abba.json"
    receipt = {
        "kind": "diagnostic-priority-abba",
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "destination": sys.argv[1], "cohort": COHORT, "enumeration": False,
        "executionBudgetSeconds": 1500, "buildLimitSeconds": 360, "armLimitSeconds": 360,
        "arms": [],
        "causalVerdict": "Undetermined. Both A/B passing or fast A2 is inconclusive; inspect all stage journals and prior work.",
    }
    arguments = ["-project", "Botto.xcodeproj", "-scheme", "Botto", "-configuration", "Debug"]
    arguments += [f"-only-testing:BottoTests/{suite}" for suite in COHORT]
    arguments += ["-destination", sys.argv[1], "-parallel-testing-enabled", "NO",
                  "-derivedDataPath", str(workspace / "DerivedData"), "CODE_SIGNING_ALLOWED=NO"]
    deadline = time.monotonic() + 1500
    status = 0

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")

    try:
        build = results / f"CIResults-Build-PriorityABBA-{run_id}.xcresult"
        receipt["buildStatus"] = "running"
        save()
        status = bounded(["xcodebuild", "build-for-testing", *arguments, "-resultBundlePath", str(build)], 360)
        receipt["buildStatus"] = status
        save()
        if not status:
            for arm, variant in ARMS:
                result = results / f"CIResults-PriorityABBA-{run_id}-{arm}.xcresult"
                environment = dict(os.environ)
                for key, value in {"BOTTO_AVATAR_DECODE_PRIORITY": variant, "BOTTO_AVATAR_PRIORITY_ARM": arm}.items():
                    environment[key] = value
                    environment["TEST_RUNNER_" + key] = value
                started = time.monotonic()
                budget = max(0, min(360, deadline - started))
                receipt["activeArm"] = {"arm": arm, "variant": variant, "budgetSeconds": budget}
                save()
                launch_error = None
                try:
                    arm_status = bounded(["xcodebuild", "test-without-building", *arguments,
                                          "-resultBundlePath", str(result)],
                                         budget, environment=environment)
                except OSError as error:
                    arm_status = 1
                    launch_error = str(error)
                record = {"arm": arm, "variant": variant, "nativeStatus": arm_status,
                          "elapsedSeconds": time.monotonic() - started, "budgetSeconds": budget,
                          "notStarted": budget <= 0, "result": result.name}
                if launch_error:
                    record["launchError"] = launch_error
                try:
                    summary = read_result("summary", result)
                    tree = read_result("tests", result)
                    (results / f"{arm}-executed-tests.json").write_text(json.dumps(tree, indent=2) + "\n")
                    methods = executed_methods(tree)
                    counts = {suite: sum(m["nodeIdentifier"].split("/")[0] == suite for m in methods) for suite in COHORT}
                    record.update(summary=summary, executedCounts=counts)
                    if counts != COHORT or len(methods) != sum(COHORT.values()):
                        raise ValueError("Actual xcresult method counts do not match the pinned five-suite cohort")
                    if summary.get("passedTests", 0) < 1 or summary.get("failedTests", 0) or summary.get("skippedTests", 0):
                        arm_status = arm_status or 1
                    traces = results / f"{arm}-traces"
                    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                                    "--test-id", "AppStoreAvatarTests", "--filter", "*.txt",
                                    "--output-path", str(traces)], check=True, timeout=30)
                    snapshots = [p.read_text() for p in traces.glob("*.txt") if "priorityArm=" in p.read_text()]
                    if not snapshots or any(f"priorityArm={arm} variant={variant} " not in text for text in snapshots):
                        raise ValueError("Missing or mismatched diagnostic arm/priority in native journal")
                    if any("dropped=0 " not in text for text in snapshots):
                        raise ValueError("The process journal exceeded its event bound")
                    record["observedProcessIDs"] = sorted({int(pid) for text in snapshots for pid in re.findall(r"priorityArm=.*? pid=(\d+)", text)})
                    previous_pids = {pid for prior in receipt["arms"] for pid in prior.get("observedProcessIDs", [])}
                    if len(record["observedProcessIDs"]) != 1 or previous_pids.intersection(record["observedProcessIDs"]):
                        raise ValueError("The arm did not establish a distinct app-host process identity")
                except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError) as error:
                    record["evidenceError"] = str(error)
                    arm_status = arm_status or 1
                record["status"] = arm_status
                receipt["arms"].append(record)
                receipt.pop("activeArm", None)
                status = status or arm_status
                save()
    except (OSError, subprocess.SubprocessError) as error:
        status = status or 1
        receipt["runnerError"] = str(error)
        raise
    finally:
        artifacts = repo / ".artifacts"
        artifacts.mkdir(exist_ok=True)
        for result in results.glob("CIResults-*.xcresult"):
            try:
                shutil.move(str(result), artifacts / result.name)
            except OSError as error:
                status = status or 1
                receipt.setdefault("finalizationErrors", []).append(str(error))
        receipt["aggregateStatus"] = status
        save()
        print(f"Priority experiment receipt and traces retained at: {results}", flush=True)
        shutil.rmtree(workspace / "DerivedData", ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
