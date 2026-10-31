from pathlib import Path
import os
import json
import base64
import datetime
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "testflight.py"


class TestFlightCommandTests(unittest.TestCase):
    def test_refuses_local_publication_before_touching_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ)
            env.pop("GITHUB_ACTIONS", None)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--build-number",
                    "2",
                    "--source-sha",
                    "a" * 40,
                    "--output-dir",
                    directory,
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GitHub Actions", result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])


STUB = r"""
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
p = Path(os.environ["FIXTURE"])
s = json.loads(p.read_text())
s.setdefault("calls", []).append([Path(sys.argv[0]).name, *args])
def done(value):
 p.write_text(json.dumps(s)); print(json.dumps(value)); sys.exit(0)
def flag(name): return args[args.index(name)+1]
if Path(sys.argv[0]).name == "git":
 p.write_text(json.dumps(s))
 print(s.get("sha", "a"*40) if args[0] == "rev-parse" else s.get("dirty", "")); sys.exit(0)
assert "ASC_PRIVATE_KEY" not in os.environ
assert not any(k.startswith("BOTTO_") for k in os.environ)
assert Path(os.environ["ASC_PRIVATE_KEY_PATH"]).stat().st_mode & 0o777 == 0o600
if s.get("fail_operation") == " ".join(args[:2]):
 p.write_text(json.dumps(s)); print(s.get("diagnostic","PRIVATE-MATERIAL"),file=sys.stderr); sys.exit(1)
if Path(sys.argv[0]).name == "ditto":
 import zipfile
 with zipfile.ZipFile(args[-2]) as z: z.extractall(args[-1])
 done({})
if Path(sys.argv[0]).name == "security":
 if args[0] == "cms":
  p.write_text(json.dumps(s)); sys.stdout.buffer.write(Path(flag("-i")).read_bytes()); sys.exit(0)
 if "-s" in args:
  s["search"]=args[args.index("-s")+1:]; done({})
 p.write_text(json.dumps(s)); print('"login.keychain-db" "custom.keychain-db"'); sys.exit(0)
if Path(sys.argv[0]).name == "codesign":
 if "--verify" in args:
  if s.get("bad_export_signature") and "exported" in args[-1] and args[-1].endswith(".appex"):
   p.write_text(json.dumps(s)); sys.exit(1)
  done({})
 if "--extract-certificates" in args: sys.exit(1)
 extract=next((a.split("=",1)[1] for a in args if a.startswith("--extract-certificates=")),None)
 if extract:
  bundle="com.sree.botto.notifications" if args[-1].endswith(".appex") else "com.sree.botto"
  wrong=(s.get("bad_export_certificate") and "exported" in args[-1]) or (".xcarchive/" in args[-1] and s.get("archive_certificate_target") == bundle)
  Path(extract+"0").write_bytes(b"wrong" if wrong else b"fixture-certificate"); done({})
 import plistlib
 bundle="com.sree.botto.notifications" if args[-1].endswith(".appex") else "com.sree.botto"
 ent={"application-identifier":"team."+bundle,"com.apple.developer.team-identifier":"team","get-task-allow":False,
      "keychain-access-groups":(["team.com.sree.botto","team.com.sree.botto.push"] if bundle == "com.sree.botto" else ["team.com.sree.botto.push"]),"aps-environment":"production"}
 if "exported" in args[-1]:
  layout=s.get("export_keychain_layout")
  if bundle == "com.sree.botto":
   if layout == "app_missing_private": ent["keychain-access-groups"]=["team.com.sree.botto.push"]
   if layout == "app_reversed": ent["keychain-access-groups"]=["team.com.sree.botto.push","team.com.sree.botto"]
   if layout == "app_extra": ent["keychain-access-groups"].append("team.other")
  else:
   if layout == "extension_private": ent["keychain-access-groups"].append("team.com.sree.botto")
   if layout == "extension_extra": ent["keychain-access-groups"].append("team.other")
 if s.get("bad_export_entitlements") and "exported" in args[-1] and args[-1].endswith(".appex"): ent["get-task-allow"]=True
 p.write_text(json.dumps(s)); sys.stdout.buffer.write(plistlib.dumps(ent)); sys.exit(0)
if args[:3] == ["signing","keychain","install"]:
 import hashlib
 Path(flag("--keychain")).touch()
 done({"teamId":"team","certificateSha256":"wrong" if s.get("bad_certificate") else hashlib.sha256(b"fixture-certificate").hexdigest()})
if args[:3] == ["signing","keychain","delete"]:
 Path(flag("--keychain")).unlink(); done({})
if args[:2] == ["xcode","archive"]:
 assert flag("--scheme") == "Botto Internal"
 assert flag("--configuration") == "Internal"
 import plistlib
 archive=Path(flag("--archive-path"))
 for path,bundle in [(archive/"Products/Applications/Botto.app","com.sree.botto"),
                     (archive/"Products/Applications/Botto.app/PlugIns/BottoNotifications.appex","com.sree.botto.notifications")]:
  path.mkdir(parents=True,exist_ok=True)
  (path/"Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":bundle,"CFBundleShortVersionString":"0.1.0","CFBundleVersion":"1001"}))
  uuid="app-uuid" if bundle == "com.sree.botto" else "extension-uuid"
  profile=plistlib.loads((Path.home()/"Library/Developer/Xcode/UserData/Provisioning Profiles"/(uuid+".mobileprovision")).read_bytes())
  if s.get("archive_profile_target") == bundle: profile["UUID"]="wrong-uuid"
  (path/"embedded.mobileprovision").write_bytes(plistlib.dumps(profile))
 done({})
if args[:2] == ["xcode","export"]:
 import plistlib
 options=plistlib.loads(Path(flag("--export-options")).read_bytes())
 assert options["manageAppVersionAndBuildNumber"] is False
 assert options["testFlightInternalTestingOnly"] is True
 assert options["provisioningProfiles"]=={"com.sree.botto":"com.sree.botto","com.sree.botto.notifications":"com.sree.botto.notifications"}
 import zipfile
 with zipfile.ZipFile(flag("--ipa-path"),"w") as z:
  for target,bundle,uuid in [("Botto","com.sree.botto","app-uuid"),("BottoNotifications","com.sree.botto.notifications","extension-uuid")]:
   prefix="Payload/Botto.app/" + ("PlugIns/BottoNotifications.appex/" if target != "Botto" else "")
   info={"CFBundleIdentifier":bundle,"CFBundleShortVersionString":"0.1.0","CFBundleVersion":"999" if s.get("bad_export_version") and target != "Botto" else "1001"}
   z.writestr(prefix+"Info.plist",plistlib.dumps(info))
   profile=plistlib.loads((Path.home()/"Library/Developer/Xcode/UserData/Provisioning Profiles"/(uuid+".mobileprovision")).read_bytes())
   if s.get("bad_export_profile") and target != "Botto": profile["UUID"]="wrong-uuid"
   z.writestr(prefix+"embedded.mobileprovision",plistlib.dumps(profile))
 done({})
if args[:1] == ["ipa-info"]:
 done({"signatureVerification":"valid","bundleId":"com.sree.botto","version":"0.1.0","buildNumber":"1001","teamId":"team"})
if args[:2] == ["builds","upload"]:
 s["uploads"]=[{"attributes":{"state":{"state":"PROCESSING"}}}]
 if s.pop("interrupt_upload",False):
  p.write_text(json.dumps(s)); sys.exit(1)
 done({})
if args[:3] == ["xcode", "version", "view"]:
 assert flag("--configuration") == "Internal"
 done({"version":"0.1.0"})
if args[:3] == ["testflight", "groups", "list"]:
 done({"data":[{"id":"group", "attributes":{"isInternalGroup":not s.get("external",False)}}]})
if args[:2] == ["builds", "next-build-number"]: done({"nextBuildNumber":str(s.get("next_number",1001))})
if args[:2] == ["builds", "list"]:
 b = s.get("build")
 done({"data": [] if not b else [{"id":"build", "attributes":{"processingState":b,"expired":False}}]})
if args[:3] == ["builds", "uploads", "list"]: done({"data":s.get("uploads",[])})
if args[:2] == ["builds", "wait"]:
 s["build"]="VALID"; done({})
if args[:2] == ["builds", "info"]: done({"data":{"attributes":{"usesNonExemptEncryption":s.get("encryption",False)}}})
if args[:3] == ["builds", "test-notes", "list"]:
 done({"data": [] if not s.get("notes") else [{"attributes":{"whatsNew":s["notes"]}}]})
if args[:3] == ["builds", "test-notes", "create"]:
 s["notes"]=flag("--whats-new"); done({})
if args[:2] == ["builds", "add-groups"]:
 s["assigned"]=True
 if s.pop("interrupt_assignment",False):
  p.write_text(json.dumps(s)); sys.exit(1)
 done({})
if args[:3] == ["builds", "groups", "list"]: done({"groups":[{"id":"group","type":"internal"}] if s.get("assigned") else []})
if args[:3] == ["builds", "build-beta-detail", "view"]: done({"data":{"attributes":{"internalBuildState":"IN_BETA_TESTING"}}})
# Unexpected commands, including signing/upload, are failures in retry tests.
p.write_text(json.dumps(s)); sys.exit(9)
"""


class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ["asc", "git", "security", "codesign", "ditto"]:
            path = self.bin / tool
            path.write_text(f"#!{sys.executable}\n" + STUB)
            path.chmod(0o755)
        self.fixture = self.root / "fixture.json"
        self.fixture.write_text('{"build":"VALID"}')
        self.output = self.root / "output"
        self.env = dict(
            os.environ,
            GITHUB_ACTIONS="true",
            GITHUB_RUN_ID="123",
            RUNNER_TEMP=str(self.root),
            ASC_KEY_ID="key",
            ASC_ISSUER_ID="issuer",
            ASC_PRIVATE_KEY="PRIVATE-MATERIAL",
            BOTTO_APP_ID="app",
            BOTTO_TEAM_ID="team",
            BOTTO_INTERNAL_GROUP_ID="group",
            FIXTURE=str(self.fixture),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
        )

    def run_release(self):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--build-number",
                "1001",
                "--source-sha",
                "a" * 40,
                "--output-dir",
                str(self.output),
            ],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def state(self, **values):
        self.fixture.write_text(json.dumps(values))

    def test_existing_valid_build_finishes_without_signing_secrets_or_upload(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((self.output / "receipt.json").read_text())
        self.assertEqual(receipt["buildID"], "build")
        self.assertEqual(receipt["sourceSHA"], "a" * 40)
        self.assertEqual(receipt["runID"], "123")
        self.assertNotIn(
            "PRIVATE-MATERIAL", result.stdout + result.stderr + json.dumps(receipt)
        )
        self.assertEqual(
            sorted(p.name for p in self.root.iterdir()),
            ["bin", "fixture.json", "output"],
        )

    def test_interrupted_group_assignment_is_reconciled_without_duplicate_notes(self):
        self.state(build="VALID", interrupt_assignment=True)
        self.assertNotEqual(self.run_release().returncode, 0)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertEqual(
            sum(c[1:4] == ["builds", "test-notes", "create"] for c in calls), 1
        )
        self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in calls))

    def test_existing_group_membership_does_not_repeat_relationship_mutation(self):
        self.state(build="VALID", assigned=True)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] == ["builds", "add-groups"] for c in calls))

    def test_accepted_upload_without_build_waits_instead_of_uploading_again(self):
        self.state(uploads=[{"attributes": {"state": {"state": "PROCESSING"}}}])
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertTrue(any(c[1:3] == ["builds", "wait"] for c in calls))
        self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in calls))

    def test_superseded_unuploaded_number_stops_before_signing(self):
        self.state(next_number=1003)
        for attempt in ("1", "2"):
            with self.subTest(attempt=attempt):
                self.env["GITHUB_RUN_ATTEMPT"] = attempt
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("superseded", result.stderr)
                self.assertIn("new workflow run", result.stderr)
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(
                    any(
                        c[1:3] in (["xcode", "archive"], ["builds", "upload"])
                        for c in calls
                    )
                )
                self.assertFalse(
                    any(c[1:4] == ["signing", "keychain", "install"] for c in calls)
                )

    def test_committed_lower_number_reconciles_after_newer_build(self):
        self.state(build="VALID", next_number=1003)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(
            any(
                c[1:3] in (["builds", "next-build-number"], ["builds", "upload"])
                for c in calls
            )
        )

    def test_processing_lower_number_reconciles_after_newer_upload(self):
        self.state(
            uploads=[{"attributes": {"state": {"state": "PROCESSING"}}}],
            next_number=1003,
        )
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(
            any(
                c[1:3] in (["builds", "next-build-number"], ["builds", "upload"])
                for c in calls
            )
        )

    def test_failed_build_requires_new_run(self):
        self.state(build="INVALID")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("new workflow run", result.stderr)

    def test_external_group_rejected_before_upload(self):
        self.state(build="VALID", external=True)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("internal", result.stderr)
        self.assertFalse(self.output.exists())

    def test_dirty_source_rejected_before_credentials(self):
        self.state(dirty=" M project.yml")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean", result.stderr)
        self.assertFalse(self.output.exists())

    def test_uncommitted_reservation_requires_new_run_without_wait_or_upload(self):
        self.state(uploads=[{"attributes": {"state": {"state": "AWAITING_UPLOAD"}}}])
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("new workflow run", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(
            any(c[1:3] in [["builds", "upload"], ["builds", "wait"]] for c in calls)
        )

    def test_safe_operation_diagnostics_distinguish_permanent_and_transient(self):
        for diagnostic, category, advice in [
            ("timed out PRIVATE-MATERIAL", "processing-timeout", "rerun this workflow"),
            (
                "processing failed PRIVATE-MATERIAL",
                "processing-rejected",
                "new workflow run",
            ),
        ]:
            with self.subTest(category=category):
                self.state(
                    uploads=[{"attributes": {"state": {"state": "PROCESSING"}}}],
                    fail_operation="builds wait",
                    diagnostic=diagnostic,
                )
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("PRIVATE-MATERIAL", result.stderr)
                report = json.loads((self.output / "failure.json").read_text())
                self.assertEqual(report["operation"], "asc builds wait")
                self.assertEqual(report["category"], category)
                self.assertIn(advice, report["recovery"])
                self.assertNotIn("PRIVATE-MATERIAL", json.dumps(report))

    def test_source_sha_must_match_checkout(self):
        self.state(sha="b" * 40)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git HEAD", result.stderr)
        self.assertFalse(self.output.exists())

    def test_unknown_encryption_is_actionable_and_does_not_patch(self):
        self.state(build="VALID", encryption=None)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ITSAppUsesNonExemptEncryption", result.stderr)
        self.assertFalse(
            any(
                c[1:3] == ["builds", "update"]
                for c in json.loads(self.fixture.read_text())["calls"]
            )
        )


class PackagingTests(ReconciliationTests):
    def setUp(self):
        super().setUp()
        self.env["HOME"] = str(self.root / "home")
        certificate = b"fixture-certificate"
        for variable, bundle, uuid in [
            ("BOTTO_APP_PROFILE_BASE64", "com.sree.botto", "app-uuid"),
            (
                "BOTTO_NOTIFICATIONS_PROFILE_BASE64",
                "com.sree.botto.notifications",
                "extension-uuid",
            ),
        ]:
            entitlements = {
                "application-identifier": "team." + bundle,
                "com.apple.developer.team-identifier": "team",
                "get-task-allow": False,
                "beta-reports-active": True,
                "aps-environment": "production",
            }
            profile = {
                "Name": bundle,
                "UUID": uuid,
                "TeamIdentifier": ["team"],
                "DeveloperCertificates": [certificate],
                "ExpirationDate": datetime.datetime(2099, 1, 1),
                "Entitlements": entitlements,
            }
            self.env[variable] = base64.b64encode(plistlib.dumps(profile)).decode()
        self.env["BOTTO_SIGNING_IDENTITY_BASE64"] = base64.b64encode(
            b"fixture-p12"
        ).decode()
        self.env["BOTTO_SIGNING_PASSWORD"] = "fixture-password"

    def test_new_build_uploads_once_and_restores_search_list_and_profiles(self):
        self.state()
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.fixture.read_text())
        self.assertEqual(sum(c[1:3] == ["builds", "upload"] for c in state["calls"]), 1)
        self.assertEqual(state["search"], ["login.keychain-db", "custom.keychain-db"])
        self.assertFalse(list((self.root / "home").rglob("*.mobileprovision")))
        self.assertEqual(
            sorted(p.name for p in self.output.iterdir()),
            ["Botto.ipa", "receipt.json", "what-to-test.txt"],
        )
        receipt = json.loads((self.output / "receipt.json").read_text())
        self.assertEqual(len(receipt["ipaSHA256"]), 64)

    def test_upload_commit_followed_by_failure_does_not_upload_on_retry(self):
        self.state(interrupt_upload=True)
        self.assertNotEqual(self.run_release().returncode, 0)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertEqual(sum(c[1:3] == ["builds", "upload"] for c in calls), 1)
        self.assertEqual(
            sum(c[1:4] == ["signing", "keychain", "install"] for c in calls), 1
        )

    def test_archive_and_export_failures_have_distinct_safe_diagnostics(self):
        for operation, diagnostic, category in [
            (
                "xcode archive",
                "No profiles for PRIVATE-MATERIAL",
                "signing-configuration",
            ),
            ("xcode export", "export failed PRIVATE-MATERIAL", "build-configuration"),
        ]:
            with self.subTest(operation=operation):
                self.state(fail_operation=operation, diagnostic=diagnostic)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                report = json.loads((self.output / "failure.json").read_text())
                self.assertEqual(report["operation"], "asc " + operation)
                self.assertEqual(report["category"], category)
                self.assertNotIn("PRIVATE-MATERIAL", result.stderr + json.dumps(report))
                self.assertNotIn("rerun this workflow", report["recovery"])

    def test_archived_profiles_and_certificates_are_verified_before_export(self):
        for problem in ("archive_profile_target", "archive_certificate_target"):
            for bundle in ("com.sree.botto", "com.sree.botto.notifications"):
                with self.subTest(problem=problem, bundle=bundle):
                    self.state(**{problem: bundle})
                    result = self.run_release()
                    self.assertNotEqual(result.returncode, 0)
                    calls = json.loads(self.fixture.read_text())["calls"]
                    self.assertFalse(
                        any(c[1:3] in (["xcode", "export"], ["builds", "upload"]) for c in calls)
                    )
                    self.assertFalse(list((self.root / "home").rglob("*.mobileprovision")))
                    self.assertEqual(
                        json.loads(self.fixture.read_text())["search"],
                        ["login.keychain-db", "custom.keychain-db"],
                    )

    def test_exported_targets_are_verified_before_upload(self):
        for problem in [
            "bad_export_version",
            "bad_export_entitlements",
            "bad_export_profile",
            "bad_export_signature",
            "bad_export_certificate",
        ]:
            with self.subTest(problem=problem):
                self.state(**{problem: True})
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    any(
                        c[1:3] == ["builds", "upload"]
                        for c in json.loads(self.fixture.read_text())["calls"]
                    )
                )
                self.assertNotIn("PRIVATE-MATERIAL", result.stderr)

    def test_exported_keychain_groups_preserve_connection_vault_isolation(self):
        for layout in (
            "app_missing_private",
            "app_reversed",
            "app_extra",
            "extension_private",
            "extension_extra",
        ):
            with self.subTest(layout=layout):
                self.state(export_keychain_layout=layout)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("keychain", result.stderr.lower())
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in calls))

    def test_expired_profile_rejected_before_keychain_import(self):
        self.state()
        profile = plistlib.loads(base64.b64decode(self.env["BOTTO_APP_PROFILE_BASE64"]))
        profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        self.env["BOTTO_APP_PROFILE_BASE64"] = base64.b64encode(
            plistlib.dumps(profile)
        ).decode()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expired", result.stderr)
        self.assertFalse(
            any(
                c[1:4] == ["signing", "keychain", "install"]
                for c in json.loads(self.fixture.read_text())["calls"]
            )
        )

    def test_signing_failure_restores_existing_search_list(self):
        self.state(bad_certificate=True)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absent", result.stderr)
        state = json.loads(self.fixture.read_text())
        self.assertEqual(state["search"], ["login.keychain-db", "custom.keychain-db"])
        self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in state["calls"]))


if __name__ == "__main__":
    unittest.main()
