import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-ci.sh"


class CombinedChecksTests(unittest.TestCase):
    def run_checks(self, failing_stage=None):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            repo = base / "repo"
            scripts = repo / "scripts"
            scripts.mkdir(parents=True)
            shutil.copy2(SCRIPT, scripts / SCRIPT.name)
            record = base / "calls.jsonl"
            tools = base / "bin"
            tools.mkdir()
            stub = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
stage = {{"check-core.sh": "core", "python3": "tooling", "check-native.sh": "native"}}[name]
with open(os.environ["CHECK_RECORD"], "a") as output:
    output.write(json.dumps({{"stage": stage, "cwd": os.getcwd(), "args": sys.argv[1:]}}) + "\\n")
sys.exit(71 if os.environ.get("FAIL_STAGE") == stage else 0)
"""
            for path in (scripts / "check-core.sh", scripts / "check-native.sh", tools / "python3"):
                path.write_text(stub)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       CHECK_RECORD=str(record), FAIL_STAGE=failing_stage or "")
            result = subprocess.run(["bash", str(scripts / SCRIPT.name)], cwd=base,
                                    env=env, capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in record.read_text().splitlines()]
            self.assertTrue(all(call["cwd"] == str(repo) for call in calls))
            return result, calls

    def test_full_entry_point_runs_every_stage_from_its_own_checkout(self):
        result, calls = self.run_checks()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["stage"] for call in calls], ["core", "tooling", "native"])
        self.assertEqual(calls[1]["args"], ["-m", "unittest", "discover", "-s", "scripts/tests", "-v"])
        self.assertEqual(calls[2]["args"], [], "The full entry point cannot narrow native coverage")

    def test_each_failure_keeps_its_status_and_stops_later_stages(self):
        for stage, expected in (("core", ["core"]), ("tooling", ["core", "tooling"]),
                                ("native", ["core", "tooling", "native"])):
            with self.subTest(stage=stage):
                result, calls = self.run_checks(stage)
                self.assertEqual(result.returncode, 71)
                self.assertEqual([call["stage"] for call in calls], expected)


if __name__ == "__main__":
    unittest.main()
