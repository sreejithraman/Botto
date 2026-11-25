import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("normalize_project", Path(__file__).resolve().parents[1] / "normalize-project.py")
normalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(normalizer)


class ProjectNormalizationTests(unittest.TestCase):
    def generated(self, identifier, checkout):
        return (
            "/* Begin PBXFileReference section */\n"
            "\t\t0000000000000000000000AA /* First.swift */ = {isa = PBXFileReference; path = First.swift; };\n"
            f'\t\t{identifier} /* {checkout} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = folder; name = "{checkout}"; path = .; sourceTree = SOURCE_ROOT; }};\n'
            "\t\tFFFFFFFFFFFFFFFFFFFFFFFF /* Last.swift */ = {isa = PBXFileReference; path = Last.swift; };\n"
            "/* End PBXFileReference section */\n"
            f"children = ({identifier} /* {checkout} */,);\n"
        )

    def test_every_checkout_name_produces_the_same_project(self):
        # XcodeGen derives both the label and the ID from the directory name.
        first = normalizer.normalize_project(self.generated("FD97ADBA45AD8504F6C28E66", "arbitrary-checkout"))
        second = normalizer.normalize_project(self.generated("10AB2C3D4E5F60718293A4B5", "copy"))
        self.assertEqual(first, second)
        self.assertNotIn("arbitrary-checkout", first)
        self.assertEqual(first.count(normalizer.STABLE_ID), 2)
        self.assertIn("name = BottoCore; path = .; sourceTree = SOURCE_ROOT;", first)
        ids = [line.strip()[:24] for line in first.split("\n")[1:4]]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(normalizer.normalize_project(first), first)

    def test_missing_reference_fails_instead_of_silently_leaving_private_labels(self):
        with self.assertRaisesRegex(ValueError, "Expected one"):
            normalizer.normalize_project("No root package reference\n")

    def test_multiple_root_references_are_rejected(self):
        line = ('FD97ADBA45AD8504F6C28E66 /* sample */ = {isa = PBXFileReference; '
                'lastKnownFileType = folder; name = sample; path = .; sourceTree = SOURCE_ROOT; };\n')
        with self.assertRaisesRegex(ValueError, "Expected one"):
            normalizer.normalize_project(line + line)

    def test_stable_id_already_used_elsewhere_is_rejected(self):
        text = self.generated("FD97ADBA45AD8504F6C28E66", "copy") + f"{normalizer.STABLE_ID} /* Other */\n"
        with self.assertRaisesRegex(ValueError, "already in use"):
            normalizer.normalize_project(text)
