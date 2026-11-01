from pathlib import Path
import os
import json
import base64
import datetime
import plistlib
import subprocess
import sys
import shutil
import signal
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
 if args[0] == "rev-list" and s.get("notes_git_failure"): sys.exit(1)
 if args[0] == "rev-list": print("\n".join(s.get("note_commits",{}).get(args[-1],[]))); sys.exit(0)
 if args[0] == "diff-tree": print("App/Botto.swift\0",end=""); sys.exit(0)
 if args[0] == "show": print(s["note_messages"][args[-1]],end=""); sys.exit(0)
 print(s.get("sha", "a"*40) if args[0] == "rev-parse" else s.get("dirty", "")); sys.exit(0)
assert "ASC_PRIVATE_KEY" not in os.environ
assert not any(k.startswith("BOTTO_") for k in os.environ)
if args[:3] != ["xcode","version","view"]: assert Path(os.environ["ASC_PRIVATE_KEY_PATH"]).stat().st_mode & 0o777 == 0o600
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
 s["uploads"]=[{"id":"upload","attributes":{"state":{"state":"PROCESSING"}}}]
 if s.pop("interrupt_upload",False):
  p.write_text(json.dumps(s)); sys.exit(1)
 done({"uploadId":"upload"})
if args[:3] == ["api", "GET", "/v1/builds/build"]:
 data={"id":"build"}
 if "include=buildUpload" in args: data["relationships"]={"buildUpload":{"data":{"type":"buildUploads","id":s.get("build_upload_id","upload")}}}
 done({"data":data})
if args[:3] == ["xcode", "version", "view"]:
 assert flag("--configuration") == "Internal"
 done({"version":"0.1.0"})
if args[:3] == ["testflight", "groups", "list"]:
 s["group_reads"]=s.get("group_reads",0)+1
 attributes={"isInternalGroup":not s.get("external",False), "hasAccessToAllBuilds":s.get("automatic_access",False)}
 if s.get("missing_automatic_access"): attributes.pop("hasAccessToAllBuilds")
 if s.get("access_after_first_read") and s["group_reads"] > 1: attributes["hasAccessToAllBuilds"]=True
 groups=[{"id":"group", "attributes":attributes}]
 if "additional_group_access" in s:
  groups.append({"id":"additional", "attributes":{"isInternalGroup":s.get("additional_group_internal",True), "hasAccessToAllBuilds":s["additional_group_access"]}})
 done({"data":groups})
if args[:2] == ["builds", "next-build-number"]: done({"nextBuildNumber":str(s.get("next_number",1001))})
if args[:2] == ["builds", "list"]:
 b = s.get("build")
 done({"data": [] if not b else [{"id":"build", "attributes":{"processingState":b,"expired":False}}]})
if args[:3] == ["builds", "uploads", "list"]: done({"data":s.get("uploads",[])})
if args[:2] == ["builds", "wait"]:
 s["build"]="VALID"; done({})
if args[:2] == ["builds", "info"]: done({"data":{"attributes":{"usesNonExemptEncryption":s.get("encryption",False)}}})
if args[:3] == ["builds", "test-notes", "list"]:
 s["note_reads"]=s.get("note_reads",0)+1
 if s["note_reads"] == 2 and s.get("notes_before_initialization"): s["notes"]=s["notes_before_initialization"]
 resource={"type":"betaBuildLocalizations","id":"localization","attributes":{"locale":"en-US","whatsNew":s.get("notes")}}
 if s.get("notes_missing_field") and s.get("notes") is None: resource["attributes"].pop("whatsNew")
 done({"data":s.get("localization_records",[resource] if s.get("notes") or s.get("empty_localization") else [])})
if args[:3] == ["api", "PATCH", "/v1/betaBuildLocalizations/localization"]:
 body_file=Path(flag("--body-file")); assert body_file.stat().st_mode & 0o777 == 0o600
 body=json.loads(body_file.read_text())["data"]
 assert "--confirm" in args and body["type"] == "betaBuildLocalizations" and body["id"] == "localization"
 assert set(body["attributes"]) == {"whatsNew"}
 if not s.get("drop_notes_write"): s["notes"]=body["attributes"]["whatsNew"]
 if s.get("notes_after_patch"): s["notes"]=s["notes_after_patch"]
 patch_signal=s.pop("signal_note_patch",None)
 if patch_signal:
  p.write_text(json.dumps(s)); os.kill(os.getppid(),patch_signal)
  sys.exit(0)
 if s.pop("interrupt_note_patch",False):
  p.write_text(json.dumps(s)); sys.exit(1)
 done({"data":{"type":"betaBuildLocalizations","id":"localization"}})
if args[:3] == ["api", "POST", "/v1/betaBuildLocalizations"]:
 body_file=Path(flag("--body-file"))
 assert body_file.stat().st_mode & 0o777 == 0o600
 body=json.loads(body_file.read_text())["data"]
 assert "--confirm" in args and body["type"] == "betaBuildLocalizations"
 assert body["attributes"]["locale"] == "en-US"
 assert body["relationships"]["build"]["data"] == {"type":"builds","id":"build"}
 if s.get("race_notes"): s["notes"]=s.pop("race_notes")
 if s.get("notes"):
  p.write_text(json.dumps(s)); sys.exit(1)
 if not s.get("drop_notes_write"): s["notes"]=body["attributes"]["whatsNew"]
 done({"data":{"type":"betaBuildLocalizations","id":"localization"}})
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
        self.checkpoint()
        self.state(build="VALID")

    def checkpoint(self, notes=None, baseline=None):
        self.output.mkdir(exist_ok=True)
        record = {"sourceSHA": "a" * 40, "runID": "123", "version": "0.1.0", "buildNumber": "1001", "notesBaseSHA": baseline,
                  "whatToTest": notes or f"Botto 0.1.0 (1001)\nSource: {'a' * 40}\n\n- Prepared tester instructions."}
        (self.output / "prepared-notes.json").write_text(json.dumps(record))

    def run_release(self, *, baseline="", prepare=False):
        if prepare:
            (self.output / "prepared-notes.json").unlink(missing_ok=True)
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--build-number",
                "1001",
                "--source-sha",
                "a" * 40,
                "--notes-base-sha", baseline,
                *(["--prepare-notes"] if prepare else []),
                "--output-dir",
                str(self.output),
            ],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def state(self, **values):
        # Existing remote state models a retry with its restored upload receipt.
        remote = bool(values.get("build") or values.get("uploads"))
        self.env["GITHUB_RUN_ATTEMPT"] = "2" if remote else "1"
        for upload in values.get("uploads", []):
            upload.setdefault("id", "upload")
        path = self.output / "receipt.json"
        if remote:
            path.write_text(json.dumps({"sourceSHA": "a" * 40, "runID": "123", "version": "0.1.0", "buildNumber": "1001", "uploadID": "upload"}))
        else:
            path.unlink(missing_ok=True)
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

    def test_first_attempt_refuses_a_build_number_occupied_by_another_upload(self):
        for remote in ({"build": "VALID"}, {"uploads": [{"id": "foreign", "attributes": {"state": {"state": "PROCESSING"}}}]}):
            with self.subTest(remote=remote):
                self.state(**remote)
                self.env["GITHUB_RUN_ATTEMPT"] = "1"
                (self.output / "receipt.json").unlink(missing_ok=True)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already occupied", result.stderr)
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(any(c[1:3] in (["api", "POST"], ["builds", "add-groups"], ["builds", "upload"], ["xcode", "archive"]) for c in calls))

    def test_interrupted_group_assignment_is_reconciled_without_duplicate_notes(self):
        self.state(build="VALID", interrupt_assignment=True)
        self.assertNotEqual(self.run_release().returncode, 0)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertEqual(
            sum(c[1:4] == ["api", "POST", "/v1/betaBuildLocalizations"] for c in calls), 1
        )
        self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in calls))

    def test_retry_refuses_another_upload_even_with_matching_source_notes(self):
        for remote in ({"build": "VALID", "build_upload_id": "foreign"}, {"uploads": [{"id": "foreign", "attributes": {"state": {"state": "PROCESSING"}}}]}):
            with self.subTest(remote=remote):
                self.state(**remote, notes=f"Botto 0.1.0 (1001)\nSource: {'a' * 40}\n\nMatching notes")
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not belong", result.stderr)
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(any(c[1:3] in (["api", "POST"], ["builds", "add-groups"], ["builds", "upload"]) for c in calls))

    def test_retry_requires_a_saved_upload_identity_before_claiming_a_build(self):
        self.state(build="VALID")
        (self.output / "receipt.json").unlink()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("saved upload identity", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] in (["api", "POST"], ["builds", "add-groups"], ["builds", "upload"]) for c in calls))

    def test_receipt_from_another_run_cannot_claim_a_matching_build(self):
        self.state(build="VALID")
        path = self.output / "receipt.json"
        record = json.loads(path.read_text())
        record["runID"] = "another-run"
        path.write_text(json.dumps(record))
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("receipt belongs to another release", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] in (["api", "POST"], ["builds", "add-groups"], ["builds", "upload"]) for c in calls))

    def test_notes_are_read_back_before_group_distribution(self):
        self.state(build="VALID", drop_notes_write=True)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notes were not confirmed", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] == ["builds", "add-groups"] for c in calls))

    def test_owned_empty_apple_localization_is_initialized_without_upload(self):
        for empty in (None, "", " \n", "missing"):
            with self.subTest(empty=empty):
                self.state(build="VALID", empty_localization=True,
                           notes=None if empty == "missing" else empty, notes_missing_field=empty == "missing")
                result = self.run_release()
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads(self.fixture.read_text())
                self.assertEqual(state["notes"], json.loads((self.output / "prepared-notes.json").read_text())["whatToTest"])
                self.assertEqual(sum(c[1:3] == ["api", "PATCH"] for c in state["calls"]), 1)
                self.assertFalse(any(c[1:3] in (["api", "POST"], ["builds", "upload"]) for c in state["calls"]))
                self.assertTrue(state["assigned"])

    def test_empty_localization_requires_checkpoint_and_upload_ownership(self):
        for failure in ("checkpoint", "ownership", "first-attempt"):
            with self.subTest(failure=failure):
                self.checkpoint()
                self.state(build="VALID", empty_localization=True,
                           build_upload_id="another" if failure == "ownership" else "upload")
                if failure == "checkpoint":
                    (self.output / "prepared-notes.json").unlink()
                if failure == "first-attempt":
                    self.env["GITHUB_RUN_ATTEMPT"] = "1"
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(any(c[1:3] in (["api", "PATCH"], ["api", "POST"], ["builds", "add-groups"]) for c in calls))

    def test_empty_localization_write_is_confirmed_and_recoverable(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                self.state(build="VALID", empty_localization=True,
                           drop_notes_write=not interrupted, interrupt_note_patch=interrupted)
                result = self.run_release()
                self.assertEqual(result.returncode == 0, interrupted, result.stderr)
                state = json.loads(self.fixture.read_text())
                self.assertEqual(state.get("assigned", False), interrupted)
                self.assertEqual(sum(c[1:3] == ["api", "PATCH"] for c in state["calls"]), 1)

    def test_cancelled_localization_write_stops_distribution_and_can_be_reconciled(self):
        for cancellation in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(cancellation=cancellation):
                self.state(build="VALID", empty_localization=True, signal_note_patch=int(cancellation))
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("publication interrupted", result.stderr)
                state = json.loads(self.fixture.read_text())
                prepared = json.loads((self.output / "prepared-notes.json").read_text())["whatToTest"]
                self.assertEqual(state["notes"], prepared)
                self.assertFalse(state.get("assigned", False))
                self.assertFalse(any(c[1:3] == ["builds", "add-groups"] for c in state["calls"]))
                result = self.run_release()
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads(self.fixture.read_text())
                self.assertTrue(state["assigned"])
                self.assertEqual(sum(c[1:3] == ["api", "PATCH"] for c in state["calls"]), 1)

    def test_uncertain_localization_patch_requires_exact_attempted_text(self):
        prefix = f"Botto 0.1.0 (1001)\nSource: {'a' * 40}\n\n"
        for observed in (prefix + "- Altered instructions.", prefix + "- Prepared"):
            with self.subTest(observed=observed):
                self.state(build="VALID", empty_localization=True,
                           notes_after_patch=observed, interrupt_note_patch=True)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("review this build manually", result.stderr)
                self.assertFalse((self.output / "failure.json").exists())
                state = json.loads(self.fixture.read_text())
                self.assertEqual(state["notes"], observed)
                self.assertFalse(state.get("assigned", False))
                self.assertFalse(any(c[1:3] == ["builds", "add-groups"] for c in state["calls"]))

    def test_initialization_rechecks_and_preserves_concurrent_nonempty_notes(self):
        for source in ("a", "b"):
            with self.subTest(source=source):
                notes = f"Botto 0.1.0 (1001)\nSource: {source * 40}\n\nMaintainer instructions"
                self.state(build="VALID", empty_localization=True, notes_before_initialization=notes)
                result = self.run_release()
                self.assertEqual(result.returncode == 0, source == "a", result.stderr)
                state = json.loads(self.fixture.read_text())
                self.assertEqual(state.get("notes"), notes)
                self.assertFalse(any(c[1:3] in (["api", "PATCH"], ["api", "POST"]) for c in state["calls"]))

    def test_invalid_localization_metadata_is_not_initialized(self):
        valid = {"id": "localization", "type": "betaBuildLocalizations",
                 "attributes": {"locale": "en-US", "whatsNew": None}}
        records = [[{**valid, "id": ""}], [{**valid, "type": "other"}],
                   [{**valid, "attributes": {"locale": "fr", "whatsNew": None}}],
                   [{**valid, "attributes": {"locale": "en-US", "whatsNew": False}}],
                   [valid, valid], [None], [{**valid, "attributes": None}], None]
        for resources in records:
            with self.subTest(resources=resources):
                self.state(build="VALID", localization_records=resources)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(any(c[1:3] in (["api", "PATCH"], ["api", "POST"], ["builds", "add-groups"]) for c in calls))

    def test_existing_source_bound_notes_are_reused_without_regeneration(self):
        notes = f"Botto 0.1.0 (1001)\nSource: {'a' * 40}\n\n- Original tester instructions."
        self.state(build="VALID", notes=notes)
        (self.output / "prepared-notes.json").unlink()
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "what-to-test.txt").read_text(), notes + "\n")
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] in (["api", "POST"], ["api", "PATCH"]) for c in calls))
        self.assertFalse(any(c[0:2] == ["git", "rev-list"] for c in calls))

    def test_existing_notes_for_another_source_are_not_overwritten(self):
        self.state(build="VALID", notes=f"Botto 0.1.0 (1001)\nSource: {'b' * 40}\n\nOther source")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another source", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] == ["builds", "add-groups"] for c in calls))

    def test_concurrent_notes_for_another_source_are_not_overwritten(self):
        notes = f"Botto 0.1.0 (1001)\nSource: {'b' * 40}\n\nOther source"
        self.state(build="VALID", race_notes=notes)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another source", result.stderr)
        state = json.loads(self.fixture.read_text())
        self.assertEqual(state["notes"], notes)
        self.assertFalse(any(c[1:3] == ["builds", "add-groups"] for c in state["calls"]))

    def test_concurrent_notes_for_this_source_are_reused_without_overwrite(self):
        notes = f"Botto 0.1.0 (1001)\nSource: {'a' * 40}\n\nMaintainer instructions"
        self.state(build="VALID", race_notes=notes)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.fixture.read_text())["notes"], notes)
        self.assertEqual((self.output / "what-to-test.txt").read_text(), notes + "\n")
        self.assertFalse((self.output / "failure.json").exists())

    def test_missing_checkpoint_stops_missing_notes_recovery(self):
        self.state(build="VALID")
        (self.output / "prepared-notes.json").unlink()
        self.env["GITHUB_RUN_ATTEMPT"] = "2"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("original prepared notes are unavailable", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] in (["api", "POST"], ["builds", "add-groups"], ["builds", "upload"]) for c in calls))
        self.assertFalse(any(c[:2] == ["git", "rev-list"] for c in calls))

    def test_missing_checkpoint_stops_fresh_signing_and_upload(self):
        self.state()
        (self.output / "prepared-notes.json").unlink()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("original prepared notes are unavailable", result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] in (["xcode", "archive"], ["builds", "upload"]) or c[1:4] == ["signing", "keychain", "install"] for c in calls))

    def test_prepared_notes_are_bound_to_source_run_version_and_build(self):
        for field, value in [("sourceSHA", "b" * 40), ("runID", "456"), ("version", "0.2.0"), ("buildNumber", "1002"), ("notesBaseSHA", "bad"), ("whatToTest", "Wrong notes")]:
            with self.subTest(field=field):
                self.state(build="VALID")
                self.checkpoint()
                path = self.output / "prepared-notes.json"
                record = json.loads(path.read_text())
                record[field] = value
                path.write_text(json.dumps(record))
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("prepared notes do not match", result.stderr)
                self.assertFalse(any(c[1:3] == ["api", "POST"] for c in json.loads(self.fixture.read_text())["calls"]))

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
                self.assertIn("superseded" if attempt == "1" else "saved upload identity", result.stderr)
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

    def test_committed_build_reconciles_even_when_group_access_changed(self):
        self.state(build="VALID", assigned=True, automatic_access=True)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in calls))

    def test_external_group_rejected_before_upload(self):
        self.state(build="VALID", external=True)
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("internal", result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, before)

    def test_dirty_source_rejected_before_credentials(self):
        self.state(dirty=" M project.yml")
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean", result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, before)

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
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git HEAD", result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, before)

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
    def test_committed_upload_retry_preserves_the_original_notes_range(self):
        baseline, old, ambiguous, current = "b" * 40, "c" * 40, "d" * 40, "a" * 40
        self.state(
            note_commits={f"{baseline}..{current}": [current], current: [old, ambiguous, current]},
            note_messages={old: "Already delivered change\0", ambiguous: "Old change\0First\nSecond", current: "Keep drafts after reconnecting\0"},
            fail_operation="builds wait", diagnostic="timeout",
        )
        result = self.run_release(baseline=baseline, prepare=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = (self.output / "prepared-notes.json").read_bytes()
        notes = json.loads(original)["whatToTest"]
        self.assertIn("Keep drafts after reconnecting", notes)
        self.assertIn(f"compare/{baseline}...{current}", notes)
        self.assertNotIn("Already delivered", notes)
        result = self.run_release(baseline=baseline)
        self.assertNotEqual(result.returncode, 0)
        state = json.loads(self.fixture.read_text())
        state.pop("fail_operation")
        state["build"] = "VALID"
        self.fixture.write_text(json.dumps(state))
        original_upload_receipt = (self.output / "receipt.json").read_bytes()
        self.assertEqual(json.loads(original_upload_receipt)["uploadID"], "upload")
        # A new runner restores the notes checkpoint and its own upload receipt.
        shutil.rmtree(self.output)
        self.output.mkdir()
        (self.output / "prepared-notes.json").write_bytes(original)
        (self.output / "receipt.json").write_bytes(original_upload_receipt)
        self.env["GITHUB_RUN_ATTEMPT"] = "2"
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.fixture.read_text())
        self.assertEqual(state["notes"], notes)
        self.assertEqual(sum(c[1:3] == ["builds", "upload"] for c in state["calls"]), 1)
        self.assertEqual(sum(c[:2] == ["git", "rev-list"] for c in state["calls"]), 1)

    def test_notes_failure_stops_before_signing_or_upload(self):
        self.state(notes_git_failure=True)
        result = self.run_release(prepare=True)
        self.assertNotEqual(result.returncode, 0)
        calls = json.loads(self.fixture.read_text())["calls"]
        self.assertFalse(any(
            c[1:3] in (["xcode", "archive"], ["builds", "upload"])
            or c[1:4] == ["signing", "keychain", "install"] for c in calls
        ))

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

    def test_fresh_upload_requires_explicit_manual_access_for_all_internal_groups(self):
        cases = [
            {"automatic_access": True},
            {"automatic_access": None},
            {"missing_automatic_access": True},
            {"additional_group_access": True},
            {"additional_group_access": None},
            {"access_after_first_read": True},
        ]
        for state in cases:
            with self.subTest(state=state):
                self.state(**state)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                calls = json.loads(self.fixture.read_text())["calls"]
                self.assertFalse(any(c[1:3] == ["builds", "upload"] for c in calls))

    def test_external_auto_access_cannot_receive_an_internal_only_build(self):
        self.state(additional_group_access=True, additional_group_internal=False)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)

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
            ["Botto.ipa", "prepared-notes.json", "receipt.json", "what-to-test.txt"],
        )
        receipt = json.loads((self.output / "receipt.json").read_text())
        self.assertEqual(len(receipt["ipaSHA256"]), 64)

    def test_unknown_upload_outcome_requires_manual_ownership_reconciliation(self):
        self.state(interrupt_upload=True)
        self.assertNotEqual(self.run_release().returncode, 0)
        self.env["GITHUB_RUN_ATTEMPT"] = "2"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("saved upload identity", result.stderr)
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
