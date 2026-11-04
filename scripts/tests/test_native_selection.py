import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "native-selection.py"
SPEC = importlib.util.spec_from_file_location("native_selection", SCRIPT)
native_selection = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native_selection)

# Format retained from `xcodebuild -enumerate-tests` under -only-testing.
INVENTORY = """Plan Botto
\tBottoTests/AppStoreAvatarTests/cachedImageExpiresWithoutFetchingOnEveryRoster() (disabled)
\tBottoTests/AppStoreAvatarTests/desktopFaceCopyFallsBackButPhotoRemains(photo:) (disabled)
\tBottoTests/AppStoreAvatarTests/revisionCacheRemovalAndImageFailuresStayLocal()
\tBottoTests/DemoConversationTests/testDemoStart()
\tBottoTests/WorkspaceTests/pair(_:second:) (disabled)
"""


def case(identifier, result="Passed"):
    return {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": result}


def results(*cases):
    return [{"nodeType": "Test Plan", "children": [{"nodeType": "Test Suite", "children": list(cases)}]}]


class SyntaxTests(unittest.TestCase):
    def test_accepts_the_identifier_forms_xcode_reports(self):
        for selector in ("AppStoreAvatarTests", "Suite/method()", "Suite/method(mime:)", "Suite/method(_:)",
                         "Suite/method(first:second:)", "Suite/method(seed1:)", "Suite/Nested/method(value:)",
                         "DemoConversationTests/testDemoStart"):
            with self.subTest(selector=selector):
                native_selection.validate(selector)

    def test_rejects_forms_xcode_cannot_report(self):
        for selector in ("", "Suite/", "Suite/method(mime)", "Suite/method(a:b)", "Suite/method(:)", "Suite/method(::)",
                         "Suite(mime:)", "Suite/method(mime:", "Suite/1method()", "--build-only", "../Suite",
                         "Suite/method(); touch other", "BottoTests", "BottoTests/Suite/method()"):
            with self.subTest(selector=selector), self.assertRaises(SystemExit):
                native_selection.validate(selector)


class DiscoveryTests(unittest.TestCase):
    def test_counts_only_active_tests_in_a_suite(self):
        self.assertIn("1 matching", native_selection.discovery("AppStoreAvatarTests", INVENTORY))

    def test_suite_with_only_disabled_tests_is_not_discovered(self):
        with self.assertRaises(SystemExit):
            native_selection.discovery("WorkspaceTests", INVENTORY)

    def test_active_exact_method_matches_with_or_without_empty_parentheses(self):
        for selector in ("DemoConversationTests/testDemoStart", "DemoConversationTests/testDemoStart()"):
            with self.subTest(selector=selector):
                self.assertIn("1 matching", native_selection.discovery(selector, INVENTORY))

    def test_listed_parameterized_identifier_defers_to_the_result_bundle(self):
        for selector in ("AppStoreAvatarTests/desktopFaceCopyFallsBackButPhotoRemains(photo:)",
                         "WorkspaceTests/pair(_:second:)"):
            with self.subTest(selector=selector):
                self.assertIn("result bundle", native_selection.discovery(selector, INVENTORY))

    def test_disabled_method_without_parameters_stays_rejected(self):
        with self.assertRaises(SystemExit):
            native_selection.discovery("AppStoreAvatarTests/cachedImageExpiresWithoutFetchingOnEveryRoster()", INVENTORY)

    def test_near_miss_stops_and_names_the_listed_identifier(self):
        expected = "AppStoreAvatarTests/desktopFaceCopyFallsBackButPhotoRemains(photo:)"
        for selector in ("AppStoreAvatarTests/desktopFaceCopyFallsBackButPhotoRemains",
                         "AppStoreAvatarTests/desktopFaceCopyFallsBackButPhotoRemains()",
                         "AppStoreAvatarTests/desktopFaceCopyFallsBackButPhotoRemains(wrong:)"):
            with self.subTest(selector=selector), self.assertRaises(SystemExit) as stopped:
                native_selection.discovery(selector, INVENTORY)
            self.assertIn(expected, str(stopped.exception))

    def test_missing_test_and_prefix_collision_are_not_discovered(self):
        for selector in ("MissingTests", "AppStoreAvatar", "AppStoreAvatarTests/helper()"):
            with self.subTest(selector=selector), self.assertRaises(SystemExit):
                native_selection.discovery(selector, INVENTORY)


class ResultTests(unittest.TestCase):
    def test_full_run_needs_a_passing_count(self):
        self.assertIn("2 passed", native_selection.verified_results(None, {"passedTests": 2}, []))
        for summary in ({"passedTests": 0}, {}, {"passedTests": "1"}):
            with self.subTest(summary=summary), self.assertRaises(SystemExit):
                native_selection.verified_results(None, summary, [])

    def test_focused_run_needs_its_selection_to_pass(self):
        nodes = results(case("Suite/method(mime:)"), case("Suite/other()", "Skipped"))
        for selector in ("Suite", "Suite/method(mime:)"):
            with self.subTest(selector=selector):
                native_selection.verified_results(selector, {"passedTests": 1}, nodes)
        for selector in ("Suite/other()", "Suite/method(other:)", "Sui", "Other"):
            with self.subTest(selector=selector), self.assertRaises(SystemExit):
                native_selection.verified_results(selector, {"passedTests": 1}, nodes)

    def test_xctest_selector_matches_the_identifier_xcode_records(self):
        native_selection.verified_results("Legacy/testOne", {"passedTests": 1}, results(case("Legacy/testOne()")))

    def test_method_failure_names_its_enclosing_suite(self):
        with self.assertRaises(SystemExit) as stopped:
            native_selection.verified_results("Outer/Inner/method(value:)", {"passedTests": 0}, [])
        self.assertIn("check-native.sh Outer/Inner", str(stopped.exception))


if __name__ == "__main__":
    unittest.main()
