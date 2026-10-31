import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


POLICY = Path(__file__).resolve().parents[1] / "testflight-policy.py"
REPOSITORY = "sreejithraman/Botto"


class TestFlightPolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release policy test")
        self.git("config", "user.email", "release@example.invalid")
        (self.repo / "README.md").write_text("Example\n")
        self.delivered_sha = self.commit("Initial commit")
        (self.repo / "App").mkdir()
        (self.repo / "App/Botto.swift").write_text("App change\n")
        self.sha = self.commit("Change app")
        self.git("remote", "add", "origin", str(self.repo))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(
            "#!/usr/bin/env python3\nimport os,sys,json,time,subprocess\nfrom pathlib import Path\n"
            "endpoint=next(x for x in sys.argv if x.startswith('repos/'))\n"
            "if os.environ.get('TEST_GH_CALLS'):\n"
            " with open(os.environ['TEST_GH_CALLS'],'a') as f: f.write(endpoint+'\\n')\n"
            "if '/ios.yml/runs?' in endpoint: value=json.loads(os.environ['TEST_CI_RUNS'])\n"
            "elif '/testflight.yml/runs?' in endpoint:\n"
            " if os.environ.get('TEST_HISTORY_FAILURE') == 'true': sys.exit(1)\n"
            " if os.environ.get('TEST_SLOW_HISTORY') == 'true': time.sleep(10)\n"
            " if os.environ.get('TEST_ADVANCE_MAIN'): subprocess.run(['git','-c','core.hooksPath=/dev/null','update-ref','refs/heads/main',os.environ['TEST_ADVANCE_MAIN']],check=True)\n"
            " value=json.loads(os.environ.get('TEST_COMPLETED_RELEASE_RUNS',os.environ['TEST_RELEASE_RUNS']) if 'status=completed' in endpoint else os.environ['TEST_RELEASE_RUNS'])\n"
            "else:\n"
            " jobs=os.environ.get('TEST_LATEST_RELEASE_JOBS',os.environ['TEST_RELEASE_JOBS']) if 'filter=latest' in endpoint else os.environ['TEST_RELEASE_JOBS']\n"
            " value=json.loads(jobs)[endpoint.split('/runs/')[1].split('/')[0]]\n"
            "pages=value if isinstance(value,list) else [value]\n"
            "for page in pages:\n"
            " for run in page.get('workflow_runs',[]):\n"
            "  run.setdefault('event','workflow_dispatch');run.setdefault('head_branch','main');run.setdefault('path','.github/workflows/testflight.yml')\n"
            "  run.setdefault('head_repository',{'full_name':'sreejithraman/Botto'});run.setdefault('head_sha',os.environ['TEST_DELIVERED_SHA'])\n"
            "if '--slurp' not in sys.argv:\n"
            " if isinstance(value,list): value=value[0]\n"
            " if 'jobs' in value: value.setdefault('total_count',len(value['jobs']))\n"
            "print(json.dumps(value))\n"
        )
        gh.chmod(0o755)

    def git(self, *args):
        return subprocess.run(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                *args,
            ],
            cwd=self.repo,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def event(self):
        return {
            "repository": {"full_name": REPOSITORY},
            "workflow_run": {
                "conclusion": "success",
                "event": "push",
                "head_branch": "main",
                "head_sha": self.sha,
                "head_repository": {"full_name": REPOSITORY},
                "path": ".github/workflows/ios.yml",
                "name": "iOS",
            },
        }

    def run_policy(
        self,
        event=None,
        event_name="workflow_run",
        automatic="true",
        error=None,
        after_queue=False,
        **changes,
    ):
        event_file = self.root / "event.json"
        event_file.write_text(json.dumps(event if event is not None else self.event()))
        env = dict(
            os.environ,
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            GITHUB_EVENT_PATH=str(event_file),
            GITHUB_EVENT_NAME=event_name,
            GITHUB_REPOSITORY=REPOSITORY,
            GITHUB_REF="refs/heads/main",
            GITHUB_SHA=self.sha,
            GITHUB_RUN_NUMBER="7",
            GITHUB_RUN_ID="999",
            GITHUB_RUN_ATTEMPT="1",
            BOTTO_TESTFLIGHT_AUTOMATIC=automatic,
            TEST_DELIVERED_SHA=self.delivered_sha,
            TEST_RELEASE_RUNS=json.dumps([{"workflow_runs": [{"id": 1}]}]),
            TEST_RELEASE_JOBS=json.dumps(
                {
                    "1": [
                        {
                            "jobs": [
                                {
                                    "name": f"Publish {self.delivered_sha}",
                                    "conclusion": "success",
                                    "steps": [
                                        {
                                            "name": "Sign, upload, and distribute internally",
                                            "conclusion": "success",
                                        }
                                    ],
                                }
                            ]
                        }
                    ]
                }
            ),
            TEST_CI_RUNS=json.dumps(
                {
                    "workflow_runs": [
                        {
                            "head_sha": self.sha,
                            "head_branch": "main",
                            "event": "push",
                            "conclusion": "success",
                        }
                    ]
                }
            ),
        )
        env.pop("GITHUB_OUTPUT", None)
        env.update(changes)
        result = subprocess.run(
            ["python3", str(POLICY), *(["--after-queue"] if after_queue else [])],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
        )
        if error is not None:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_successful_main_app_commit_gets_reserved_build_number(self):
        result = self.run_policy()
        self.assertTrue(result["publish"])
        self.assertEqual(result["source_sha"], self.sha)
        self.assertEqual(result["build_number"], 1007)

    def test_automatic_delivery_stays_off_until_enabled(self):
        self.assertFalse(self.run_policy(automatic="false")["publish"])

    def test_untrusted_and_failed_events_cannot_publish(self):
        for field, value in (
            ("conclusion", "failure"),
            ("event", "pull_request"),
            ("head_branch", "feature"),
            ("path", "other.yml"),
        ):
            with self.subTest(field=field):
                event = self.event()
                event["workflow_run"][field] = value
                self.assertFalse(self.run_policy(event)["publish"])
        event = self.event()
        event["workflow_run"]["head_repository"]["full_name"] = "someone/Botto"
        self.assertFalse(self.run_policy(event)["publish"])
        self.assertFalse(self.run_policy(GITHUB_REPOSITORY="someone/Botto")["publish"])

    def test_docs_only_main_commit_does_not_publish_automatically(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Documentation change\n")
        self.sha = self.commit("Update docs")
        self.assertFalse(self.run_policy()["publish"])

    def test_docs_head_carries_forward_a_superseded_app_change(self):
        old_event = self.event()
        (self.repo / "README.md").write_text("Documentation after the app change\n")
        self.sha = self.commit("Docs after pending app")
        self.assertFalse(self.run_policy(old_event)["publish"])
        self.assertTrue(self.run_policy()["publish"])

    def test_skipped_or_failed_publish_step_does_not_advance_delivery_baseline(self):
        (self.repo / "README.md").write_text("Docs after pending app\n")
        self.sha = self.commit("Docs")
        for conclusion in ("skipped", "failure"):
            with self.subTest(conclusion=conclusion):
                jobs = {
                    "2": [
                        {
                            "jobs": [
                                {
                                    "name": f"Publish {self.sha}",
                                    "conclusion": "success",
                                    "steps": [
                                        {
                                            "name": "Sign, upload, and distribute internally",
                                            "conclusion": conclusion,
                                        }
                                    ],
                                }
                            ]
                        }
                    ],
                    "1": [
                        {
                            "jobs": [
                                {
                                    "name": f"Publish {self.delivered_sha}",
                                    "conclusion": "success",
                                    "steps": [
                                        {
                                            "name": "Sign, upload, and distribute internally",
                                            "conclusion": "success",
                                        }
                                    ],
                                }
                            ]
                        }
                    ],
                }
                self.assertTrue(
                    self.run_policy(
                        TEST_RELEASE_RUNS=json.dumps(
                            [{"workflow_runs": [{"id": 2}, {"id": 1}]}]
                        ),
                        TEST_RELEASE_JOBS=json.dumps(jobs),
                    )["publish"]
                )

    def test_renamed_out_app_source_triggers_delivery(self):
        self.delivered_sha = self.sha
        self.git("config", "diff.renames", "true")
        (self.repo / "docs").mkdir()
        self.git("mv", "App/Botto.swift", "docs/Botto.swift")
        self.sha = self.commit("Remove old app source by moving it")
        self.assertTrue(self.run_policy()["publish"])

    def test_stale_rerun_fails_with_explicit_recovery_handoff(self):
        event = self.event()
        (self.repo / "App/Botto.swift").write_text("New current app\n")
        self.commit("Advance main after partial delivery")
        self.run_policy(
            event,
            GITHUB_RUN_ATTEMPT="2",
            error="did not reconcile the prior Apple upload",
        )

    def test_current_publish_retry_reconciles_a_confirmed_build(self):
        self.delivered_sha = self.sha
        self.assertFalse(self.run_policy(GITHUB_RUN_ATTEMPT="2")["publish"])
        self.assertTrue(
            self.run_policy(after_queue=True, GITHUB_RUN_ATTEMPT="2")["publish"]
        )
        self.assertFalse(self.run_policy(after_queue=True)["publish"])

    def test_non_ascii_app_paths_and_pending_docs_are_detected(self):
        self.git("config", "core.quotePath", "true")
        path = self.repo / "App/Café.swift"
        path.write_text("Old app input\n")
        self.delivered_sha = self.commit("Add Unicode input")
        path.write_text("Changed app input\n")
        self.sha = self.commit("Change Unicode input")
        self.assertTrue(self.run_policy()["publish"])
        (self.repo / "README.md").write_text("Later docs\n")
        self.sha = self.commit("Docs after Unicode app")
        self.assertTrue(self.run_policy()["publish"])

    def test_many_skipped_runs_have_a_fixed_request_budget(self):
        runs = [{"id": n} for n in range(101, 0, -1)]
        jobs = {
            str(n): [
                {"jobs": [{"name": "Publish", "conclusion": "skipped", "steps": []}]}
            ]
            for n in range(101, 1, -1)
        }
        jobs["1"] = [
            {
                "jobs": [
                    {
                        "name": f"Publish {self.delivered_sha}",
                        "steps": [
                            {
                                "name": "Sign, upload, and distribute internally",
                                "conclusion": "success",
                            }
                        ],
                    }
                ]
            }
        ]
        calls = self.root / "gh-calls"
        self.assertTrue(
            self.run_policy(
                TEST_RELEASE_RUNS=json.dumps([{"workflow_runs": runs}]),
                TEST_RELEASE_JOBS=json.dumps(jobs),
                TEST_GH_CALLS=str(calls),
            )["publish"]
        )
        self.assertLessEqual(len(calls.read_text().splitlines()), 21)

    def test_slow_history_falls_back_before_candidate_deadline(self):
        start = time.monotonic()
        self.assertTrue(self.run_policy(TEST_SLOW_HISTORY="true")["publish"])
        self.assertLess(time.monotonic() - start, 8)

    def test_partial_attempt_history_is_unknown_not_an_older_baseline(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Docs after possible newer delivery\n")
        self.sha = self.commit("Docs")
        jobs = {
            "2": [
                {
                    "total_count": 101,
                    "jobs": [{"name": f"Publish {self.sha}", "steps": []}],
                }
            ],
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ],
        }
        self.assertTrue(
            self.run_policy(
                TEST_RELEASE_RUNS=json.dumps(
                    [{"workflow_runs": [{"id": 2}, {"id": 1}]}]
                ),
                TEST_RELEASE_JOBS=json.dumps(jobs),
            )["publish"]
        )

    def test_main_advancing_during_history_lookup_prevents_publication(self):
        original = self.sha
        (self.repo / "App/Botto.swift").write_text("New main during policy\n")
        future = self.commit("New main")
        self.git("checkout", "--detach", original)
        self.git("branch", "-f", "main", original)
        self.assertFalse(
            self.run_policy(after_queue=True, TEST_ADVANCE_MAIN=future)["publish"]
        )
        self.assertEqual(self.git("rev-parse", "HEAD"), original)
        self.assertEqual(self.git("rev-parse", "main"), future)

    def test_untrusted_history_cannot_claim_official_delivery(self):
        jobs = {
            "2": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.sha}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ],
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ],
        }
        unsafe = [
            {"event": "pull_request"},
            {"head_repository": {"full_name": "fork/Botto"}},
            {"head_branch": "feature"},
            {"path": ".github/workflows/other.yml"},
        ]
        for fields in unsafe:
            with self.subTest(fields=fields):
                run = {"id": 2, "head_sha": self.sha, **fields}
                self.assertTrue(
                    self.run_policy(
                        TEST_RELEASE_RUNS=json.dumps(
                            [{"workflow_runs": [run, {"id": 1}]}]
                        ),
                        TEST_RELEASE_JOBS=json.dumps(jobs),
                    )["publish"]
                )

    def test_history_marker_must_match_its_workflow_source(self):
        jobs = {
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.sha}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ]
        }
        self.assertTrue(self.run_policy(TEST_RELEASE_JOBS=json.dumps(jobs))["publish"])

    def test_missing_history_repository_is_an_unknown_baseline(self):
        self.delivered_sha = self.sha
        self.assertTrue(
            self.run_policy(
                TEST_RELEASE_RUNS=json.dumps(
                    [{"workflow_runs": [{"id": 1, "head_repository": None}]}]
                )
            )["publish"]
        )

    def reverted_history(self, newer_steps, newer_job=None, newer_fields=None):
        old = self.sha
        self.delivered_sha = old
        (self.repo / "App/Botto.swift").write_text("Temporary delivered feature\n")
        newer = self.commit("Temporary feature")
        (self.repo / "App/Botto.swift").write_text("App change\n")
        self.sha = self.commit("Revert temporary feature")
        run = {"id": 2, "head_sha": newer, **(newer_fields or {})}
        job = {"name": f"Publish {newer}", "steps": newer_steps, **(newer_job or {})}
        jobs = {
            "2": [{"jobs": [job]}],
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {old}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ],
        }
        return {
            "TEST_RELEASE_RUNS": json.dumps([{"workflow_runs": [run, {"id": 1}]}]),
            "TEST_RELEASE_JOBS": json.dumps(jobs),
        }

    def test_incomplete_newer_history_does_not_hide_a_revert(self):
        for field, missing in (
            (field, value)
            for field in ("event", "head_branch", "path")
            for value in (None, "")
        ):
            with self.subTest(field=field, missing=missing):
                values = self.reverted_history(
                    [
                        {
                            "name": "Sign, upload, and distribute internally",
                            "conclusion": "success",
                        }
                    ],
                    newer_fields={field: missing},
                )
                self.assertTrue(self.run_policy(**values)["publish"])

    def test_inconsistent_newer_success_does_not_hide_a_revert(self):
        values = self.reverted_history(
            [
                {
                    "name": "Sign, upload, and distribute internally",
                    "conclusion": "success",
                }
            ],
            newer_job={"name": "Publish " + "a" * 40},
        )
        self.assertTrue(self.run_policy(**values)["publish"])

    def test_unconfirmed_publication_does_not_hide_a_revert(self):
        for state in ("failure", "cancelled", None):
            with self.subTest(state=state):
                values = self.reverted_history(
                    [
                        {
                            "name": "Sign, upload, and distribute internally",
                            "conclusion": state,
                        }
                    ]
                )
                self.assertTrue(self.run_policy(**values)["publish"])
        values = self.reverted_history(
            [
                {
                    "name": "Sign, upload, and distribute internally",
                    "conclusion": "skipped",
                }
            ]
        )
        self.assertFalse(self.run_policy(**values)["publish"])

    def test_own_running_policy_does_not_erase_the_delivered_baseline(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Docs only\n")
        self.sha = self.commit("Docs")
        jobs = {
            "999": [{"jobs": [{"name": f"Publish {self.sha}", "steps": []}]}],
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ],
        }
        self.assertFalse(
            self.run_policy(
                TEST_RELEASE_RUNS=json.dumps(
                    [{"workflow_runs": [{"id": 999, "head_sha": self.sha}, {"id": 1}]}]
                ),
                TEST_RELEASE_JOBS=json.dumps(jobs),
            )["publish"]
        )

    def test_excluded_main_app_guidance_does_not_publish_without_app_changes(self):
        self.delivered_sha = self.sha
        path = self.repo / "App/Views/AGENTS.md"
        path.parent.mkdir(parents=True)
        path.write_text("UI guidance\n")
        self.sha = self.commit("Update excluded guidance")
        self.assertFalse(self.run_policy()["publish"])
        (self.repo / "App/Botto.swift").write_text("App change alongside guidance\n")
        self.sha = self.commit("App after guidance")
        self.assertTrue(self.run_policy()["publish"])

    def test_contradictory_skipped_job_does_not_hide_a_revert(self):
        for state in ("failure", "cancelled", None, "success"):
            with self.subTest(state=state):
                values = self.reverted_history(
                    [
                        {
                            "name": "Sign, upload, and distribute internally",
                            "conclusion": state,
                        }
                    ],
                    newer_job={"conclusion": "skipped"},
                )
                self.assertTrue(self.run_policy(**values)["publish"])

    def test_independent_success_survives_a_contradictory_later_attempt(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Docs after a known successful delivery\n")
        self.sha = self.commit("Docs")
        jobs = {
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "conclusion": "skipped",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "failure",
                                }
                            ],
                        },
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "conclusion": "failure",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        },
                    ]
                }
            ]
        }
        self.assertFalse(self.run_policy(TEST_RELEASE_JOBS=json.dumps(jobs))["publish"])

    def test_skipped_job_with_success_step_is_not_confirmation(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Docs after a contradictory result\n")
        self.sha = self.commit("Docs")
        jobs = {
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "conclusion": "skipped",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "success",
                                }
                            ],
                        }
                    ]
                }
            ]
        }
        self.assertTrue(self.run_policy(TEST_RELEASE_JOBS=json.dumps(jobs))["publish"])

    def test_conflicting_failed_attempt_does_not_hide_a_revert(self):
        values = self.reverted_history(
            [{"name": "Sign, upload, and distribute internally", "conclusion": "failure"}]
        )
        runs = json.loads(values["TEST_RELEASE_RUNS"])
        runs[0]["workflow_runs"][0]["head_sha"] = self.delivered_sha
        jobs = json.loads(values["TEST_RELEASE_JOBS"])
        jobs["2"][0]["jobs"].append(
            {
                "name": f"Publish {self.delivered_sha}",
                "steps": [
                    {
                        "name": "Sign, upload, and distribute internally",
                        "conclusion": "success",
                    }
                ],
            }
        )
        values["TEST_RELEASE_RUNS"] = json.dumps(runs)
        values["TEST_RELEASE_JOBS"] = json.dumps(jobs)
        self.assertTrue(self.run_policy(**values)["publish"])

    def test_no_confirmed_delivery_publishes_conservatively(self):
        self.assertTrue(
            self.run_policy(TEST_RELEASE_RUNS='[{"workflow_runs": []}]')["publish"]
        )

    def test_bundled_legal_resources_trigger_delivery(self):
        self.delivered_sha = self.sha
        for name in ("LICENSE", "LICENSES/Pele.txt", "THIRD_PARTY_NOTICES.md"):
            with self.subTest(path=name):
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("Corrected bundled notice\n")
                self.sha = self.commit("Correct legal resource")
                self.assertTrue(self.run_policy()["publish"])
                self.delivered_sha = self.sha

    def test_queued_docs_head_skips_after_active_app_delivery_finishes(self):
        app_sha = self.sha
        (self.repo / "README.md").write_text("Docs after app\n")
        self.sha = self.commit("Docs")
        self.assertTrue(self.run_policy()["publish"])
        self.delivered_sha = app_sha
        self.assertFalse(self.run_policy()["publish"])
        self.assertTrue(self.run_policy(event_name="workflow_dispatch")["publish"])

    def test_successful_delivery_survives_later_failed_attempt(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Docs after delivered app\n")
        self.sha = self.commit("Docs")
        latest = {
            "1": [
                {
                    "jobs": [
                        {
                            "name": f"Publish {self.delivered_sha}",
                            "steps": [
                                {
                                    "name": "Sign, upload, and distribute internally",
                                    "conclusion": "failure",
                                }
                            ],
                        }
                    ]
                }
            ]
        }
        self.assertFalse(
            self.run_policy(TEST_LATEST_RELEASE_JOBS=json.dumps(latest))["publish"]
        )

    def test_successful_delivery_remains_visible_while_rerun_is_active(self):
        self.delivered_sha = self.sha
        (self.repo / "README.md").write_text("Docs while delivery reruns\n")
        self.sha = self.commit("Docs")
        self.assertFalse(
            self.run_policy(TEST_COMPLETED_RELEASE_RUNS='[{"workflow_runs": []}]')[
                "publish"
            ]
        )

    def test_unavailable_or_malformed_history_publishes_conservatively(self):
        self.assertTrue(self.run_policy(TEST_HISTORY_FAILURE="true")["publish"])
        self.assertTrue(
            self.run_policy(TEST_RELEASE_RUNS='"malformed response"')["publish"]
        )

    def test_already_delivered_source_does_not_publish_again_automatically(self):
        self.delivered_sha = self.sha
        self.assertFalse(self.run_policy()["publish"])

    def test_merge_commit_includes_changes_against_its_first_parent(self):
        self.git("checkout", "-b", "feature")
        (self.repo / "App/Botto.swift").write_text("Merged feature\n")
        self.commit("Feature")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "feature", "-m", "Merge feature")
        self.sha = self.git("rev-parse", "HEAD")
        self.assertTrue(self.run_policy()["publish"])

    def test_superseded_tested_commit_does_not_publish(self):
        event = self.event()
        (self.repo / "App/Botto.swift").write_text("New main\n")
        self.commit("New main")
        self.assertFalse(self.run_policy(event)["publish"])

    def test_manual_delivery_needs_main_and_successful_exact_commit_checks(self):
        self.assertTrue(
            self.run_policy(event_name="workflow_dispatch", automatic="false")[
                "publish"
            ]
        )
        self.assertFalse(
            self.run_policy(
                event_name="workflow_dispatch", GITHUB_REF="refs/heads/feature"
            )["publish"]
        )
        self.assertFalse(
            self.run_policy(
                event_name="workflow_dispatch", TEST_CI_RUNS='{"workflow_runs": []}'
            )["publish"]
        )

    def test_manual_delivery_can_publish_a_docs_only_commit(self):
        (self.repo / "README.md").write_text("Updated docs\n")
        self.sha = self.commit("Docs")
        self.assertTrue(self.run_policy(event_name="workflow_dispatch")["publish"])


if __name__ == "__main__":
    unittest.main()
