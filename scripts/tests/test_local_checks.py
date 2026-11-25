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

    def test_configured_hook_blocks_failed_push_and_allows_success(self):
        self.git("add", ".")
        self.git("commit", "-m", "Disposable hook fixture")
        remote = self.directory / "remote.git"
        self.run_command("git", "init", "--bare", str(remote))
        self.git("config", "--local", "core.hooksPath", ".githooks")
        self.env["BOTTO_CHECK_FAIL"] = "test"
        rejected = self.git("push", str(remote), "HEAD:refs/heads/proof", expected=1)
        self.assertIn("stub swift test status=23", rejected.stdout)
        self.git("show-ref", "--verify", "refs/heads/proof", repo=remote, expected=128)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
