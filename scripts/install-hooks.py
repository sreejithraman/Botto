#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]


def git(*arguments, allowed_statuses=(0,)):
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), *arguments],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode not in allowed_statuses:
        raise RuntimeError(result.stderr.strip() or "Git command failed.")
    return result.stdout


def main():
    if Path(git("rev-parse", "--show-toplevel").rstrip("\n")).resolve() != REPO_ROOT:
        raise RuntimeError("Run the installer from a complete repository checkout.")
    for name in (".githooks/pre-push", "scripts/check-core.sh"):
        path = REPO_ROOT / name
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError(f"Required file is missing or not executable: {path}")
    configured_paths = git(
        "config", "--null", "--get-all", "core.hooksPath", allowed_statuses=(0, 1),
    )
    if any(path != ".githooks" for path in configured_paths.split("\0")[:-1]):
        raise RuntimeError(
            "Refusing to replace existing core.hooksPath. "
            "Keep your hook setup and run scripts/check-core.sh directly."
        )
    common_directory = git("rev-parse", "--path-format=absolute", "--git-common-dir").rstrip("\n")
    default_hooks = Path(common_directory) / "hooks"
    if default_hooks.is_dir():
        enabled_hooks = sorted(
            hook.name for hook in default_hooks.iterdir()
            if not hook.name.endswith(".sample") and hook.is_file() and os.access(hook, os.X_OK)
        )
        if enabled_hooks:
            raise RuntimeError(
                f"Refusing to bypass existing hooks in {default_hooks}: {', '.join(enabled_hooks)}. "
                "Keep your hook setup and run scripts/check-core.sh directly."
            )
    local_paths = git(
        "config", "--local", "--null", "--get-all", "core.hooksPath", allowed_statuses=(0, 1),
    )
    if not local_paths:
        git("config", "--local", "core.hooksPath", ".githooks")
    print(
        "Enabled core checks before push "
        "(repository-local core.hooksPath=.githooks, shared by linked worktrees)."
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
