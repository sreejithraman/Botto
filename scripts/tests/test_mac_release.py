import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "mac_release", Path(__file__).resolve().parents[1] / "mac-release.py"
)
mac_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mac_release)


class MacReleaseTests(unittest.TestCase):
    SAMPLE_SHA = "a" * 64

    def test_release_tag_and_archive_filename(self):
        self.assertEqual(mac_release.release_tag("0.1.0", "beta", "1"), "v0.1.0-beta.1")
        self.assertEqual(mac_release.release_tag("0.1.0", "stable"), "v0.1.0")
        self.assertEqual(mac_release.archive_filename("0.1.0", "beta", "1"), "Botto-0.1.0-beta.1.zip")
        self.assertEqual(mac_release.archive_filename("0.1.0", "stable"), "Botto-0.1.0.zip")
        self.assertEqual(mac_release.cask_filename("beta"), "botto@beta.rb")
        self.assertEqual(mac_release.cask_filename("stable"), "botto.rb")

    def test_render_beta_cask(self):
        cask = mac_release.render_cask(
            channel="beta",
            version="0.1.0",
            build="4",
            sha256=self.SAMPLE_SHA,
        )
        self.assertIn('cask "botto@beta" do', cask)
        self.assertIn('version "0.1.0-beta.4"', cask)
        self.assertIn(f'sha256 "{self.SAMPLE_SHA}"', cask)
        self.assertIn(
            'url "https://github.com/sreejithraman/Botto/releases/download/v0.1.0-beta.4/Botto-0.1.0-beta.4.zip"',
            cask,
        )
        self.assertIn('app "Botto.app"', cask)
        self.assertIn("auto_updates true", cask)
        self.assertIn('conflicts_with cask: "botto"', cask)
        self.assertIn("depends_on arch: :arm64", cask)
        self.assertNotIn("BottoMac", cask)

    def test_render_stable_cask(self):
        cask = mac_release.render_cask(
            channel="stable",
            version="0.1.0",
            sha256=self.SAMPLE_SHA,
        )
        self.assertIn('cask "botto" do', cask)
        self.assertIn('version "0.1.0"', cask)
        self.assertIn(f'sha256 "{self.SAMPLE_SHA}"', cask)
        self.assertIn('url "https://github.com/sreejithraman/Botto/releases/download/v#{version}/Botto-#{version}.zip"', cask)
        self.assertIn('app "Botto.app"', cask)
        self.assertIn('conflicts_with cask: "botto@beta"', cask)

    def test_verify_checksum_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "Botto-0.1.0-beta.1.zip"
            archive.write_bytes(b"zip-bytes")
            digest = mac_release.sha256_file(archive)
            checksum = root / "Botto-0.1.0-beta.1.zip.sha256"
            checksum.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
            self.assertEqual(mac_release.verify_checksum_file(archive, checksum), digest)

            checksum.write_text(f"{'b' * 64}  {archive.name}\n", encoding="utf-8")
            with self.assertRaisesRegex(mac_release.ReleaseError, "SHA-256 mismatch"):
                mac_release.verify_checksum_file(archive, checksum)

    def test_verify_appcast_xml_checks_signature_and_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            appcast.write_text(
                """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Botto</title>
    <item>
      <title>0.1.0</title>
      <sparkle:channel>beta</sparkle:channel>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
      <enclosure url="https://github.com/sreejithraman/Botto/releases/download/v0.1.0-beta.1/Botto-0.1.0-beta.1.zip"
                 length="100" type="application/octet-stream" sparkle:edSignature="abc123=="/>
    </item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )
            mac_release.verify_appcast_xml(
                appcast,
                expected_zip_name="Botto-0.1.0-beta.1.zip",
                expected_channel="beta",
            )
            with self.assertRaisesRegex(mac_release.ReleaseError, "default \\(stable\\) channel"):
                mac_release.verify_appcast_xml(
                    appcast,
                    expected_zip_name="Botto-0.1.0-beta.1.zip",
                    expected_channel="stable",
                )

    def test_rejects_invalid_inputs(self):
        with self.assertRaises(mac_release.ReleaseError):
            mac_release.validate_version("v0.1.0")
        with self.assertRaises(mac_release.ReleaseError):
            mac_release.validate_build("0")
        with self.assertRaises(mac_release.ReleaseError):
            mac_release.validate_sha256("not-a-sha")


if __name__ == "__main__":
    unittest.main()
