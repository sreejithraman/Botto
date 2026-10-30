import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(__file__).resolve().parents[2]
OWNED_FILES = (
    "scripts/check-core.sh",
    "scripts/install-hooks.py",
    ".githooks/pre-push",
)


class LocalChecksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="botto-local-checks-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.repo = self.directory / "repo with spaces"
        self.repo.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.calls = self.directory / "swift-calls.jsonl"
        self.global_config = self.directory / "global.gitconfig"
        self.global_config.write_text("[user]\n\tname = Local Check Test\n\temail = checks@example.invalid\n")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=str(self.global_config),
            GIT_TEMPLATE_DIR=str(self.directory / "empty-template"),
            HOME=str(self.directory),
            XDG_CONFIG_HOME=str(self.directory / "xdg"),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            BOTTO_CHECK_CALLS=str(self.calls),
        )
        self.run_command("git", "init", "--initial-branch=main", str(self.repo))
        for name in OWNED_FILES:
            source = SOURCE_ROOT / name
            if source.exists():
                target = self.repo / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        swift = self.bin / "swift"
        swift.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['BOTTO_CHECK_CALLS'], 'a') as calls:\n"
            "    calls.write(json.dumps({'cwd': os.getcwd(), 'args': sys.argv[1:]}) + '\\n')\n"
            "status = 23 if os.environ.get('BOTTO_CHECK_FAIL') == sys.argv[1] else 0\n"
            "print('stub swift ' + sys.argv[1] + ' status=' + str(status), flush=True)\n"
            "sys.exit(status)\n"
        )
        swift.chmod(0o755)

    def run_command(self, *arguments, cwd=None, expected=0, env=None):
        result = subprocess.run(
            arguments, cwd=cwd or self.directory, env=env or self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout)
        return result

    def git(self, *arguments, repo=None, expected=0):
        return self.run_command("git", "-C", str(repo or self.repo), *arguments, expected=expected)

    def swift_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def install(self, expected=0, repo=None):
        return self.run_command(sys.executable, str((repo or self.repo) / "scripts/install-hooks.py"), expected=expected)

    def linked_worktree(self):
        self.git("add", ".")
        self.git("commit", "-m", "Disposable worktree fixture")
        worktree = self.directory / "linked worktree"
        self.git("worktree", "add", "-b", "linked", str(worktree))
        return worktree

    def test_core_checks_run_in_repo_root_from_unrelated_directory(self):
        self.run_command(str(self.repo / "scripts/check-core.sh"))
        self.assertEqual(self.swift_calls(), [
            {"cwd": str(self.repo), "args": ["test", "--no-parallel", "--scratch-path", ".artifacts/CoreTests"]},
            {"cwd": str(self.repo), "args": [
                "build", "--target", "BottoCore", "--scratch-path", ".artifacts/CoreMainActor",
                "-Xswiftc", "-default-isolation", "-Xswiftc", "MainActor",
            ]},
        ])

    def test_core_failure_returns_status_and_stops_remaining_steps(self):
        self.env["BOTTO_CHECK_FAIL"] = "test"
        self.run_command(str(self.repo / "scripts/check-core.sh"), expected=23)
        self.assertEqual([call["args"][0] for call in self.swift_calls()], ["test"])

    def test_compatibility_failure_returns_status(self):
        self.env["BOTTO_CHECK_FAIL"] = "build"
        self.run_command(str(self.repo / "scripts/check-core.sh"), expected=23)
        self.assertEqual([call["args"][0] for call in self.swift_calls()], ["test", "build"])

    def test_installed_hook_blocks_failed_push_and_allows_success(self):
        self.git("add", ".")
        self.git("commit", "-m", "Disposable hook fixture")
        remote = self.directory / "remote.git"
        self.run_command("git", "init", "--bare", str(remote))
        self.run_command(sys.executable, str(self.repo / "scripts/install-hooks.py"))
        self.env["BOTTO_CHECK_FAIL"] = "test"
        rejected = self.git("push", str(remote), "HEAD:refs/heads/proof", expected=1)
        self.assertIn("stub swift test status=23", rejected.stdout)
        missing_ref = self.git("show-ref", "--verify", "refs/heads/proof", repo=remote, expected=128)
        self.assertEqual([call["args"][0] for call in self.swift_calls()], ["test"])
        self.env["BOTTO_CHECK_FAIL"] = "build"
        rejected_build = self.git("push", str(remote), "HEAD:refs/heads/proof", expected=1)
        self.assertIn("stub swift build status=23", rejected_build.stdout)
        self.git("show-ref", "--verify", "refs/heads/proof", repo=remote, expected=128)
        self.env.pop("BOTTO_CHECK_FAIL")
        accepted = self.git("push", str(remote), "HEAD:refs/heads/proof")
        self.assertIn("stub swift build status=0", accepted.stdout)
        self.assertEqual(
            self.git("rev-parse", "refs/heads/proof", repo=remote).stdout,
            self.git("rev-parse", "HEAD").stdout,
        )
        self.assertEqual(
            [call["args"][0] for call in self.swift_calls()],
            ["test", "test", "build", "test", "build"],
        )
        if proof_directory := os.environ.get("BOTTO_CHECK_PROOF_DIR"):
            proof = Path(proof_directory)
            proof.mkdir(parents=True, exist_ok=True)
            (proof / "push-rejected.log").write_text(rejected.stdout)
            (proof / "push-build-rejected.log").write_text(rejected_build.stdout)
            (proof / "push-accepted.log").write_text(accepted.stdout)
            (proof / "push-swift-calls.jsonl").write_text(self.calls.read_text())
            (proof / "push-verdicts.json").write_text(json.dumps({
                "command": ["git", "-C", str(self.repo), "push", str(remote), "HEAD:refs/heads/proof"],
                "failed_test_push_status": rejected.returncode,
                "failed_build_push_status": rejected_build.returncode,
                "missing_remote_ref_status_after_rejection": missing_ref.returncode,
                "successful_push_status": accepted.returncode,
                "remote_head": self.git("rev-parse", "refs/heads/proof", repo=remote).stdout.strip(),
                "local_head": self.git("rev-parse", "HEAD").stdout.strip(),
            }, indent=2) + "\n")

    def test_conflicting_hooks_path_is_preserved(self):
        self.git("config", "--local", "core.hooksPath", "user-hooks")
        config = self.repo / ".git/config"
        before = config.read_bytes()
        result = self.install(expected=1)
        self.assertIn("core.hooksPath", result.stdout)
        self.assertEqual(config.read_bytes(), before)

    def test_enabled_default_hooks_are_preserved(self):
        for name in ("pre-push", "pre-commit", "commit-msg"):
            with self.subTest(hook=name):
                hook = self.repo / ".git/hooks" / name
                hook.parent.mkdir(exist_ok=True)
                hook.write_text("#!/bin/sh\nexit 0\n")
                hook.chmod(0o755)
                before_hook = hook.read_bytes()
                config = self.repo / ".git/config"
                before_config = config.read_bytes()
                result = self.install(expected=1)
                self.assertIn(name, result.stdout)
                self.assertEqual(hook.read_bytes(), before_hook)
                self.assertTrue(os.access(hook, os.X_OK))
                self.assertEqual(config.read_bytes(), before_config)
                hook.unlink()

    def test_repeated_install_does_not_rewrite_config_or_touch_other_repos(self):
        unrelated = self.directory / "unrelated"
        self.run_command("git", "init", str(unrelated))
        self.git("config", "--local", "core.hooksPath", "private-hooks", repo=unrelated)
        unrelated_config = unrelated / ".git/config"
        before_unrelated = unrelated_config.read_bytes()
        before_global = self.global_config.read_bytes()
        self.install()
        config = self.repo / ".git/config"
        before_repeat = (config.read_bytes(), config.stat().st_mtime_ns)
        hook = self.repo / ".githooks/pre-push"
        before_hook = (hook.read_bytes(), hook.stat().st_mode)
        self.install()
        self.assertEqual((config.read_bytes(), config.stat().st_mtime_ns), before_repeat)
        self.assertEqual((hook.read_bytes(), hook.stat().st_mode), before_hook)
        self.assertEqual(unrelated_config.read_bytes(), before_unrelated)
        self.assertEqual(self.global_config.read_bytes(), before_global)
        self.assertEqual(self.git("config", "--local", "--get-all", "core.hooksPath").stdout, ".githooks\n")

    def test_nonexecutable_project_hook_is_refused_without_config_changes(self):
        hook = self.repo / ".githooks/pre-push"
        hook.chmod(0o644)
        config = self.repo / ".git/config"
        before = config.read_bytes()
        result = self.install(expected=1)
        self.assertIn("executable", result.stdout)
        self.assertEqual(config.read_bytes(), before)

    def test_linked_worktree_uses_its_own_relative_hook_and_build_paths(self):
        worktree = self.linked_worktree()
        self.assertTrue((worktree / ".git").is_file())
        self.install(repo=worktree)
        self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath").stdout, ".githooks\n")
        remote = self.directory / "worktree-remote.git"
        self.run_command("git", "init", "--bare", str(remote))
        nested = worktree / "scripts"
        self.run_command("git", "push", str(remote), "HEAD:refs/heads/linked", cwd=nested)
        self.assertEqual([call["cwd"] for call in self.swift_calls()], [str(worktree), str(worktree)])
        self.assertEqual([call["args"][0] for call in self.swift_calls()], ["test", "build"])

    def test_linked_worktree_refuses_shared_default_user_hook(self):
        worktree = self.linked_worktree()
        hook = self.repo / ".git/hooks/pre-push"
        hook.parent.mkdir(exist_ok=True)
        hook.write_text("#!/bin/sh\nexit 0\n")
        hook.chmod(0o755)
        before = (self.repo / ".git/config").read_bytes()
        result = self.install(repo=worktree, expected=1)
        self.assertIn(str(hook.parent), result.stdout)
        self.assertEqual((self.repo / ".git/config").read_bytes(), before)
        self.assertEqual(hook.read_text(), "#!/bin/sh\nexit 0\n")

    def test_inherited_global_and_worktree_hook_config_is_preserved(self):
        self.run_command("git", "config", "--global", "core.hooksPath", "global-hooks")
        before_global = self.global_config.read_bytes()
        before_local = (self.repo / ".git/config").read_bytes()
        self.install(expected=1)
        self.assertEqual(self.global_config.read_bytes(), before_global)
        self.assertEqual((self.repo / ".git/config").read_bytes(), before_local)
        self.run_command("git", "config", "--global", "--unset", "core.hooksPath")
        worktree = self.linked_worktree()
        self.git("config", "--local", "extensions.worktreeConfig", "true")
        self.git("config", "--worktree", "core.hooksPath", "worktree-hooks", repo=worktree)
        worktree_config = Path(self.git("rev-parse", "--path-format=absolute", "--git-path", "config.worktree", repo=worktree).stdout.strip())
        before_worktree = worktree_config.read_bytes()
        before_common = (self.repo / ".git/config").read_bytes()
        self.install(repo=worktree, expected=1)
        self.assertEqual(worktree_config.read_bytes(), before_worktree)
        self.assertEqual((self.repo / ".git/config").read_bytes(), before_common)

    def test_disabled_hooks_and_executable_samples_are_preserved(self):
        hook_directory = self.repo / ".git/hooks"
        hook_directory.mkdir(exist_ok=True)
        disabled = hook_directory / "pre-push"
        disabled.write_text("#!/bin/sh\nexit 41\n")
        disabled.chmod(0o644)
        sample = hook_directory / "pre-commit.sample"
        sample.write_text("#!/bin/sh\nexit 42\n")
        sample.chmod(0o755)
        self.install()
        self.install()
        self.assertEqual(disabled.read_text(), "#!/bin/sh\nexit 41\n")
        self.assertFalse(os.access(disabled, os.X_OK))
        self.assertEqual(sample.read_text(), "#!/bin/sh\nexit 42\n")
        self.assertTrue(os.access(sample, os.X_OK))


if __name__ == "__main__":
    unittest.main(verbosity=2)
