from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
import unittest


class TestFlightNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        spec = importlib.util.spec_from_file_location(
            "testflight_notes_fixture", Path(__file__).resolve().parents[1] / "testflight.py"
        )
        self.publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.publisher)
        self.publisher.ROOT = self.repo
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Notes fixture")
        self.git("config", "user.email", "notes@example.invalid")

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-C", str(self.repo), *args], stderr=subprocess.PIPE, text=True
        ).strip()

    def commit(self, path, message):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(message)
        self.git("add", "--", path)
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def notes(self, source, baseline=None):
        return self.publisher.what_to_test(source, "0.1.0", "1001", baseline, dict(os.environ))

    def test_notes_describe_app_changes_since_the_delivered_source(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.commit("README.md", "Rewrite setup")
        self.commit("App/Views/AGENTS.md", "Explain view conventions")
        self.commit("AppTests/Example.swift", "Add tests")
        self.commit("App/Botto.swift", "Keep drafts after reconnecting (#42)")
        source = self.commit("Sources/BottoCore/Chat.swift", "Restore live conversations")
        notes = self.notes(source, baseline)
        self.assertTrue(notes.startswith(f"Botto 0.1.0 (1001)\nSource: {source}\n\n"))
        self.assertIn("- Keep drafts after reconnecting\n", notes)
        self.assertIn("- Restore live conversations\n", notes)
        for excluded in ("Previous beta", "Rewrite setup", "Explain view", "Add tests", "(#42)"):
            self.assertNotIn(excluded, notes)

    def test_trailers_override_internal_titles_and_can_omit_changes(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.commit("App/Botto.swift", "chore: feedback\n\nRelease-Note: Feel new chat haptics.")
        self.commit("App/Botto.swift", "chore: follow-up\n\nRelease-Note: Feel new chat haptics.")
        self.commit("App/Botto.swift", "Expose internals\n\nRelease-Note: none")
        self.commit("App/Botto.swift", "ci: adjust setup")
        self.commit("App/Botto.swift", "Bump version to 0.2.0")
        self.commit("App/Botto.swift", "Revert an implementation detail")
        self.commit("App/Botto.swift", "Update version history display")
        source = self.commit("App/Botto.swift", "Revert something\n\nRelease-Note: Restore connection recovery.")
        notes = self.notes(source, baseline)
        self.assertEqual(notes.count("Feel new chat haptics."), 1)
        self.assertIn("Restore connection recovery.", notes)
        self.assertIn("Update version history display", notes)
        for excluded in ("Expose internals", "ci:", "Bump version", "Revert"):
            self.assertNotIn(excluded, notes)

    def test_notes_stay_on_the_tested_commit_when_head_moves(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        source = self.commit("App/Botto.swift", "Show the developer playgrounds")
        expected = self.notes(source, baseline)
        self.commit("App/Botto.swift", "Not part of this build")
        self.assertEqual(self.notes(source, baseline), expected)
        self.assertNotIn("Not part of this build", expected)

    def test_scan_limit_counts_unrelated_commits_before_filtering(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        feature = self.commit("App/Botto.swift", "Keep drafts after reconnecting")
        for index in range(199):
            source = self.commit("README.md", f"Documentation update {index}")
        self.assertIn("- Keep drafts after reconnecting", self.notes(source, baseline))

        for index in (199, 200):
            with self.subTest(unrelated_commits=index + 1):
                source = self.commit("README.md", f"Documentation update {index}")
                for notes_base in (baseline, None):
                    with self.subTest(baseline=notes_base):
                        notes = self.notes(source, notes_base)
                        self.assertNotIn("Keep drafts after reconnecting", notes)
                        self.assertNotIn("Documentation update", notes)
                        self.assertIn("- Internal build and delivery updates.", notes)
                        link = (f"compare/{baseline}...{source}" if notes_base
                                else f"commits/{source}")
                        self.assertIn(f"https://github.com/sreejithraman/Botto/{link}", notes)
                self.assertIn(feature, self.git("rev-list", f"{baseline}..{source}").splitlines())

    def test_unknown_or_unrelated_baseline_uses_available_history(self):
        first = self.commit("App/Botto.swift", "First app")
        self.git("checkout", "-b", "other")
        unrelated = self.commit("App/Other.swift", "Other branch")
        self.git("checkout", "main")
        source = self.commit("App/Botto.swift", "Current app")
        for baseline in (None, unrelated, "a" * 40):
            with self.subTest(baseline=baseline):
                notes = self.notes(source, baseline)
                self.assertIn("First app", notes)
                self.assertIn("Current app", notes)
                self.assertNotIn("Other branch", notes)
        self.assertNotEqual(first, source)

    def test_notes_preserve_unicode_and_remain_bounded(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.commit("App/世界.swift", "你好 🦊")
        source = self.commit("App/Botto.swift", "Long note " + "🦊" * 1000)
        notes = self.notes(source, baseline)
        self.assertIn("你好", notes)
        self.assertNotIn("🦊", notes)
        self.assertLessEqual(len(notes.encode()), 3500)
        self.assertIn(f"compare/{baseline}...{source}", notes)

    def test_notes_use_the_pinned_cli_unicode_contract(self):
        source = self.commit("App/Botto.swift", "Cafe\u0301 <chat> 🦊 ☀️ x\u0301 हिन्दी ไทย عَرَبِيّ")
        notes = self.notes(source)
        self.assertIn("- Café chat> x हिन्दी ไทย عَرَبِيّ", notes)
        for unsupported in ("<", "🦊", "☀", "\ufe0f", "\u0301"):
            self.assertNotIn(unsupported, notes)

    def test_multiple_authored_notes_require_clear_wording(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        source = self.commit("App/Botto.swift", "Change\n\nRelease-Note: First\nRelease-Note: Second")
        with self.assertRaisesRegex(self.publisher.ReleaseError, "more than one"):
            self.notes(source, baseline)

    def test_merge_uses_only_the_change_against_its_first_parent(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.git("checkout", "-b", "documentation")
        self.commit("README.md", "Document the app")
        self.git("checkout", "main")
        self.commit("App/Botto.swift", "Keep the app change")
        self.git("merge", "--no-ff", "documentation", "-m", "Merge documentation")
        source = self.git("rev-parse", "HEAD")
        notes = self.notes(source, baseline)
        self.assertIn("Keep the app change", notes)
        self.assertNotIn("Merge documentation", notes)

    def test_default_merge_titles_require_an_authored_note(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.git("checkout", "-b", "feature")
        self.commit("App/Botto.swift", "Feature branch detail")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "feature", "-m", "Merge pull request #4 from owner/feature")
        source = self.git("rev-parse", "HEAD")
        self.assertNotIn("Merge pull request", self.notes(source, baseline))
        self.git("commit", "--amend", "-m", "Merge pull request #4 from owner/feature\n\nRelease-Note: Keep drafts between sessions.")
        notes = self.notes(self.git("rev-parse", "HEAD"), baseline)
        self.assertIn("Keep drafts between sessions.", notes)
        self.assertNotIn("Merge pull request", notes)

    def test_an_oversized_middle_entry_does_not_hide_a_later_change(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.commit("App/Botto.swift", "Keep earlier app work")
        self.commit("App/Botto.swift", "Oversized " + "x" * 3500)
        source = self.commit("App/Botto.swift", "Open the developer menu")
        notes = self.notes(source, baseline)
        self.assertIn("Keep earlier app work", notes)
        self.assertIn("Open the developer menu", notes)
        self.assertLessEqual(len(notes.encode()), 3500)

    def test_recent_changes_take_priority_when_the_notes_are_full(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        for index in range(70):
            source = self.commit("App/Botto.swift", f"Feature {index:02d}: " + "useful improvements " * 3)
        notes = self.notes(source, baseline)
        self.assertIn("Feature 69:", notes)
        self.assertNotIn("Feature 00:", notes)
        self.assertLessEqual(len(notes.encode()), 3500)

    def test_delivery_only_metadata_is_omitted_without_hiding_the_internal_menu(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        self.commit("App/Resources/Info.plist", "Add protected internal TestFlight publishing")
        self.commit("App/Resources/Info.plist", "Set app URLs\n\nRelease-Note: Open bots from shared links.")
        source = self.commit("App/Views/DeveloperMenuView.swift", "Open the developer menu in internal builds")
        notes = self.notes(source, baseline)
        self.assertNotIn("Add protected internal TestFlight publishing", notes)
        self.assertIn("Open bots from shared links.", notes)
        self.assertIn("Open the developer menu in internal builds", notes)

    def test_a_repeated_note_keeps_its_most_recent_priority(self):
        baseline = self.commit("App/Botto.swift", "Previous beta")
        titles = [f"Feature {index:02d}: " + "useful improvements " * 3 for index in range(70)]
        for title in titles:
            self.commit("App/Botto.swift", title)
        source = self.commit("App/Botto.swift", titles[0])
        notes = self.notes(source, baseline)
        self.assertIn("Feature 00:", notes)
        self.assertIn("Feature 69:", notes)
        self.assertNotIn("Feature 01:", notes)
        self.assertEqual(notes.count("Feature 00:"), 1)


if __name__ == "__main__":
    unittest.main()
