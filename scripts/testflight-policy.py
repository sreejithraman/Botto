#!/usr/bin/env python3
"""Select a tested main revision for the maintainer's internal TestFlight."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


REPOSITORY = "sreejithraman/Botto"
HISTORY_RUN_LIMIT = 20
HISTORY_SECONDS = 30
HISTORY_REQUEST_SECONDS = 5
RELEASE_PATHS = (
    "App/",
    "Sources/",
    "Botto.xcodeproj/",
    "project.yml",
    "Package.swift",
    "Package.resolved",
    "LICENSE",
    "LICENSES/",
    "THIRD_PARTY_NOTICES.md",
    "scripts/testflight.py",
    "scripts/testflight-policy.py",
    "scripts/check-ci.sh",
    ".github/workflows/testflight.yml",
)


def command(*args, timeout=30):
    return subprocess.run(
        args, capture_output=True, text=True, check=True, timeout=timeout
    ).stdout.strip()


def last_delivered_sha():
    deadline = time.monotonic() + HISTORY_SECONDS

    def request(path):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("delivery history budget exhausted")
        return json.loads(
            command(
                "gh",
                "api",
                f"repos/{REPOSITORY}/{path}",
                timeout=min(HISTORY_REQUEST_SECONDS, remaining),
            )
        )

    runs = request(
        f"actions/workflows/testflight.yml/runs?branch=main&per_page={HISTORY_RUN_LIMIT}"
    )["workflow_runs"]
    expected = {
        "event": {"workflow_run", "workflow_dispatch"},
        "head_branch": {"main"},
        "path": {".github/workflows/testflight.yml"},
    }
    for run in runs[:HISTORY_RUN_LIMIT]:
        if not isinstance(run, dict):
            return None
        repository = run.get("head_repository")
        repository_name = (
            repository.get("full_name") if isinstance(repository, dict) else None
        )
        if (
            isinstance(repository_name, str)
            and repository_name
            and repository_name != REPOSITORY
        ) or any(
            isinstance(run.get(field), str) and run[field] and run[field] not in allowed
            for field, allowed in expected.items()
        ):
            continue
        if repository_name != REPOSITORY or any(
            not isinstance(run.get(field), str) or not run[field] for field in expected
        ):
            return None
        head_sha = run["head_sha"]
        if not isinstance(head_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
            return None
        response = request(f"actions/runs/{run['id']}/jobs?filter=all&per_page=100")
        jobs = response["jobs"]
        confirmed = False
        publication_jobs = 0
        uncertain_publication = False
        for job in jobs:
            name = job["name"]
            if not isinstance(name, str):
                return None
            steps = [
                step
                for step in job.get("steps", [])
                if step["name"] == "Sign, upload, and distribute internally"
            ]
            if name == "Publish" or name.startswith("Publish ") or steps:
                publication_jobs += 1
                may_have_published = (
                    any(step.get("conclusion") != "skipped" for step in steps)
                    if steps
                    else job.get("conclusion") != "skipped"
                )
                if may_have_published:
                    marker = re.fullmatch(r"Publish ([0-9a-f]{40})", name)
                    if not marker or marker[1] != head_sha:
                        return None
                    uncertain_publication = True
                if job.get("conclusion") != "skipped" and any(
                    step.get("conclusion") == "success" for step in steps
                ):
                    confirmed = True
        if confirmed:
            return head_sha
        if response["total_count"] > len(jobs):
            return None
        if str(run["id"]) == os.environ.get("GITHUB_RUN_ID"):
            continue
        if not publication_jobs or uncertain_publication:
            return None

    return None


def is_current_main(sha):
    current = command("git", "ls-remote", "origin", "refs/heads/main").split()
    if command("git", "rev-parse", "HEAD") == sha and current and current[0] == sha:
        return True
    if int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) > 1:
        raise SystemExit(
            "This rerun is superseded by newer main and did not reconcile the prior Apple upload. "
            "Inspect the original build in App Store Connect, then start a new TestFlight run "
            "on current main after its iOS checks pass."
        )
    return False


def is_release_input(path):
    main_app_path = path.startswith("App/") and not path.startswith(
        "App/NotificationService/"
    )
    if main_app_path and Path(path).name == "AGENTS.md":
        return False
    return path.startswith(RELEASE_PATHS)


def select(after_queue=False):
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if (
        os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
        or event.get("repository", {}).get("full_name") != REPOSITORY
    ):
        return {
            "publish": False,
            "reason": "This workflow publishes only the maintainer repository.",
        }

    kind = os.environ["GITHUB_EVENT_NAME"]
    if kind == "workflow_run":
        run = event.get("workflow_run", {})
        if not (
            run.get("event") == "push"
            and run.get("head_branch") == "main"
            and run.get("conclusion") == "success"
            and run.get("name") == "iOS"
            and run.get("path") == ".github/workflows/ios.yml"
            and run.get("head_repository", {}).get("full_name") == REPOSITORY
        ):
            return {
                "publish": False,
                "reason": "The source run is not a successful main push check.",
            }
        if os.environ.get("BOTTO_TESTFLIGHT_AUTOMATIC") != "true":
            return {"publish": False, "reason": "Automatic delivery is disabled."}
        sha = run.get("head_sha", "")
    elif (
        kind == "workflow_dispatch"
        and os.environ.get("GITHUB_REF") == "refs/heads/main"
    ):
        sha = os.environ.get("GITHUB_SHA", "")
    else:
        return {"publish": False, "reason": "Delivery must originate from main."}

    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return {"publish": False, "reason": "Invalid source revision."}
    if not is_current_main(sha):
        return {
            "publish": False,
            "reason": "A newer main revision superseded this candidate.",
        }

    if kind == "workflow_dispatch":
        response = json.loads(
            command(
                "gh",
                "api",
                f"repos/{REPOSITORY}/actions/workflows/ios.yml/runs?head_sha={sha}&branch=main&event=push&status=success",
            )
        )
        if not any(
            run.get("head_sha") == sha
            and run.get("head_branch") == "main"
            and run.get("event") == "push"
            and run.get("conclusion") == "success"
            for run in response["workflow_runs"]
        ):
            return {
                "publish": False,
                "reason": "Main needs a successful iOS push check for this exact revision.",
            }
    retrying = after_queue and int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) > 1
    baseline = None
    if not retrying and (kind != "workflow_dispatch" or after_queue):
        try:
            baseline = last_delivered_sha()
        except (
            subprocess.SubprocessError,
            OSError,
            ValueError,
            TypeError,
            KeyError,
        ):
            print(
                "Delivery history is unavailable; treating the delivery baseline as unknown.",
                file=sys.stderr,
            )
            baseline = None
    if kind != "workflow_dispatch" and not retrying:
        if baseline:
            ancestor = subprocess.run(
                ["git", "merge-base", "--is-ancestor", baseline, sha],
                capture_output=True,
            )
            if ancestor.returncode == 0:
                changed = command(
                    "git", "diff", "--no-renames", "--name-only", "-z", baseline, sha
                ).split("\0")
            else:
                changed = command(
                    "git", "ls-tree", "-r", "--name-only", "-z", sha
                ).split("\0")
        else:
            changed = command("git", "ls-tree", "-r", "--name-only", "-z", sha).split(
                "\0"
            )
        if not any(is_release_input(path) for path in changed):
            return {
                "publish": False,
                "reason": "No app, build, or delivery files changed since the last confirmed beta.",
            }

    if not is_current_main(sha):
        return {
            "publish": False,
            "reason": "A newer main revision superseded this candidate.",
        }

    number = int(os.environ["GITHUB_RUN_NUMBER"])
    if number < 1:
        raise ValueError("GITHUB_RUN_NUMBER must be positive")
    return {
        "publish": True,
        "source_sha": sha,
        "build_number": number + 1000,
        "notes_base_sha": baseline or "",
        "reason": "The current main revision passed its iOS checks.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--after-queue", action="store_true")
    args = parser.parse_args()
    result = select(after_queue=args.after_queue)
    print(json.dumps(result))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as file:
            file.write(f"publish={str(result['publish']).lower()}\n")
            for name in ("source_sha", "build_number", "notes_base_sha"):
                if name in result:
                    file.write(f"{name}={result[name]}\n")


if __name__ == "__main__":
    main()
