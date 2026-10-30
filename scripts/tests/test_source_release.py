import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("source_release", Path(__file__).resolve().parents[1] / "prepare-source-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class SourceReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write("LICENSE", "MIT sample\n")
        self.write("README.md", "Botto\n")
        self.write("project.yml", 'MARKETING_VERSION: "0.1.0"\n')
        self.write("Botto.xcodeproj/project.pbxproj", "project\n")
        self.output = Path(self.temporary.name) / "Botto"
        self.manifest = Path(self.temporary.name) / "manifest.json"

    def write(self, name, content):
        destination = self.root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
        return destination

    def export(self):
        return release.export_source(self.root, self.output, self.manifest)

    def test_export_keeps_source_and_modes_but_omits_drafts_and_ignored_state(self):
        self.write(".gitattributes", "/docs/drafting/** export-ignore\n")
        self.write(".gitignore", ".env\n.artifacts/\n")
        self.write("docs/drafting/session.md", "private drafting record\n")
        subprocess.run(["git", "-C", str(self.root), "add", "docs/drafting/session.md"], check=True)
        self.write(".env", "synthetic ignored credential\n")
        self.write(".artifacts/log", "local run\n")
        self.write("scripts/check.sh", "#!/bin/sh\nexit 0\n").chmod(0o755)
        result = self.export()
        self.assertFalse((self.output / ".git").exists())
        self.assertFalse((self.output / ".env").exists())
        self.assertFalse((self.output / "docs/drafting/session.md").exists())
        self.assertFalse((self.output / ".artifacts").exists())
        self.assertEqual((self.output / "README.md").read_text(), "Botto\n")
        self.assertTrue((self.output / "scripts/check.sh").stat().st_mode & 0o111)
        self.assertEqual(json.loads(self.manifest.read_text()), result)
        self.assertEqual(result["version"], "0.1.0")
        self.assertIn("docs/drafting/session.md", result["omitted"])

    def test_tracked_signing_material_is_rejected_before_any_output(self):
        self.write("App/Signing/AuthKey.p8", "synthetic key placeholder\n")
        subprocess.run(["git", "-C", str(self.root), "add", "App/Signing/AuthKey.p8"], check=True)
        with self.assertRaisesRegex(ValueError, "Credential or signing"):
            self.export()
        self.assertFalse(self.output.exists())

    def test_tracked_relay_credentials_are_rejected_even_when_ignored(self):
        self.write(".gitignore", ".dev.vars\n.dev.vars.*\n")
        for name in [".dev.vars", ".dev.vars.production"]:
            with self.subTest(name=name):
                self.output = self.output.with_name("Botto-" + name)
                self.manifest = self.manifest.with_name("manifest-" + name + ".json")
                path = self.write("Push/relay/" + name, "SYNTHETIC_SECRET=placeholder\n")
                subprocess.run(["git", "-C", str(self.root), "add", "-f", str(path)], check=True)
                with self.assertRaisesRegex(ValueError, "Credential or signing"):
                    self.export()
                self.assertFalse(self.output.exists())
                self.assertFalse(self.manifest.exists())
                subprocess.run(["git", "-C", str(self.root), "rm", "-f", str(path)], check=True,
                               stdout=subprocess.DEVNULL)

    def test_symlink_outside_checkout_is_rejected(self):
        external = Path(self.temporary.name) / "private-data"
        external.write_text("synthetic private data\n")
        (self.root / "App").mkdir()
        (self.root / "App/linked.txt").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Symbolic links"):
            self.export()
        self.assertFalse(self.output.exists())

    def test_existing_export_is_never_replaced(self):
        self.output.mkdir()
        sentinel = self.output / "preserve.txt"
        sentinel.write_text("keep this file\n")
        with self.assertRaisesRegex(ValueError, "never replaced"):
            self.export()
        self.assertEqual(sentinel.read_text(), "keep this file\n")

    def test_unreviewed_top_level_file_is_rejected(self):
        self.write("personal-notes.txt", "synthetic private note\n")
        with self.assertRaisesRegex(ValueError, "unexpected release file"):
            self.export()
        self.assertFalse(self.output.exists())

    def test_mismatched_app_and_extension_versions_are_rejected(self):
        self.write("project.yml", 'MARKETING_VERSION: "0.1.0"\nMARKETING_VERSION: "0.2.0"\n')
        with self.assertRaisesRegex(ValueError, "same release version"):
            self.export()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
