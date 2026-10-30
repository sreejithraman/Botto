import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("normalize_project", Path(__file__).resolve().parents[1] / "normalize-project.py")
normalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(normalizer)


class ProjectNormalizationTests(unittest.TestCase):
    def test_checkout_label_changes_without_changing_package_identity_or_path(self):
        identifier = "FD97ADBA45AD8504F6C28E66"
        original = (
            f'{identifier} /* arbitrary-checkout */ = {{isa = PBXFileReference; '
            'lastKnownFileType = folder; name = "arbitrary-checkout"; path = .; sourceTree = SOURCE_ROOT; };\n'
            f'children = ({identifier} /* arbitrary-checkout */,);\n'
        )
        changed = normalizer.normalize_project(original)
        self.assertNotIn("arbitrary-checkout", changed)
        self.assertEqual(changed.count(identifier), 2)
        self.assertEqual(changed.count("/* BottoCore */"), 2)
        self.assertIn("name = BottoCore; path = .; sourceTree = SOURCE_ROOT;", changed)
        self.assertEqual(normalizer.normalize_project(changed), changed)

    def test_missing_reference_fails_instead_of_silently_leaving_private_labels(self):
        with self.assertRaisesRegex(ValueError, "Expected one"):
            normalizer.normalize_project("No root package reference\n")

    def test_multiple_root_references_are_rejected(self):
        line = ('FD97ADBA45AD8504F6C28E66 /* sample */ = {isa = PBXFileReference; '
                'lastKnownFileType = folder; name = sample; path = .; sourceTree = SOURCE_ROOT; };\n')
        with self.assertRaisesRegex(ValueError, "Expected one"):
            normalizer.normalize_project(line + line)
