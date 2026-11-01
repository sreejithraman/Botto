#!/usr/bin/env python3
"""Publish one tested GitHub Actions revision to an internal TestFlight group."""

import argparse
import base64
import datetime
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
from typing import Optional
import plistlib
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import quote


class ReleaseError(Exception):
    pass


class PublicationInterrupted(Exception):
    pass


FAILURE_PATH = None

ROOT = Path(__file__).resolve().parents[1]
BUNDLES = {
    "Botto": "com.sree.botto",
    "BottoNotifications": "com.sree.botto.notifications",
}


def notes_prefix(source, version, number):
    return f"Botto {version} ({number})\nSource: {source}\n\n"


def apple_note_text(text):
    # Match asc 5.16.0 internal/cli/shared/test_notes.go's Apple character limits.
    refused = (
        (0x20D0, 0x20FF), (0x2400, 0x245F), (0x2500, 0x259F),
        (0x2600, 0x27EF), (0x2800, 0x28FF), (0x2980, 0x2BFF),
        (0xE000, 0xF8FF), (0xFE00, 0xFE0F), (0xFFFD, 0xFFFD),
        (0x10000, 0x10FFFF),
    )
    generic_marks = ((0x0300, 0x036F), (0x1AB0, 0x1AFF), (0x1DC0, 0x1DFF), (0xFE20, 0xFE2F))
    return " ".join("".join(
        char for char in unicodedata.normalize("NFC", text)
        if char != "<"
        and not any(low <= ord(char) <= high for low, high in refused)
        and not (
            unicodedata.category(char) == "Mn"
            and any(low <= ord(char) <= high for low, high in generic_marks)
        )
    ).split())


def what_to_test(source, version, number, baseline, env):
    if baseline:
        if not re.fullmatch(r"[0-9a-f]{40}", baseline):
            raise ReleaseError("release-note baseline must be a full commit SHA")
        ancestor = subprocess.run(
            ["git", "merge-base", "--is-ancestor", baseline, source],
            cwd=ROOT, env=env, capture_output=True,
        )
        if ancestor.returncode:
            baseline = None
    revision = f"{baseline}..{source}" if baseline else source
    commits = command(
        "git", "rev-list", "--first-parent", "--reverse", "--max-count=200", revision, env=env
    ).decode().splitlines()
    entries = []
    for sha in commits:
        paths = command(
            "git", "diff-tree", "--root", "--diff-merges=first-parent", "--no-commit-id",
            "--name-only", "--no-renames", "-z", "-r", sha, env=env,
        ).decode().split("\0")
        app_paths = [
            path for path in paths
            if path.startswith(("App/", "Sources/")) and Path(path).name != "AGENTS.md"
        ]
        if not app_paths:
            continue
        subject, trailers = command(
            "git", "show", "-s",
            "--format=%s%x00%(trailers:key=Release-Note,valueonly,unfold=true)", sha, env=env,
        ).decode().split("\0", 1)
        authored = [line.strip() for line in trailers.splitlines() if line.strip()]
        if len(authored) > 1:
            raise ReleaseError(f"commit {sha} has more than one Release-Note trailer")
        if authored:
            if authored[0].casefold() == "none":
                continue
            note = authored[0]
        else:
            if all(path == "App/Resources/Info.plist" for path in app_paths):
                continue
            if re.match(
                r"(?:build|chore|ci|docs|refactor|style|test)(?:\([^)]*\))?!?:|Revert\b|"
                r"Merge (?:pull request #\d+\b|(?:remote-tracking )?branch\b)|"
                r"(?:Bump|Set|Update) (?:the )?(?:(?:marketing|release) )?version(?: to)? v?\d+\.\d+\.\d+\b|"
                r"(?:Set|Bump|Update|Prepare|Publish) Botto \d+\.\d+\.\d+\b",
                subject, re.IGNORECASE,
            ):
                continue
            note = re.sub(r"\s*\(#\d+\)\s*$", "", subject)
        note = apple_note_text(note)
        if note:
            if note in entries:
                entries.remove(note)
            entries.append(note)
    prefix = notes_prefix(source, version, number)
    link = (
        f"https://github.com/sreejithraman/Botto/compare/{baseline}...{source}"
        if baseline else f"https://github.com/sreejithraman/Botto/commits/{source}"
    )
    footer = f"\n\nChanges: {link}"
    lines = []
    for entry in reversed(entries):
        line = f"- {entry}"
        if len((prefix + "\n".join([*lines, line]) + footer).encode()) > 3500:
            continue
        lines.append(line)
    if not lines:
        lines = ["- Internal build and delivery updates."]
    return prefix + "\n".join(reversed(lines)) + footer


def command(*args, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True)
    if result.returncode:
        operation = " ".join(
            args[
                : next(
                    (index for index, arg in enumerate(args) if arg.startswith("--")),
                    len(args),
                )
            ]
            if args[0] == "asc"
            else args[:2]
        )
        diagnostic = (result.stdout + result.stderr).lower()
        category = "command-failed"
        recovery = (
            "inspect this operation's configuration before starting a new workflow run"
        )
        if any(
            word in diagnostic
            for word in [b"unauthorized", b"forbidden", b"authentication failed"]
        ):
            category = "authentication"
            recovery = "check the configured API key and its permissions"
        elif any(
            word in diagnostic
            for word in [
                b"provisioning",
                b"profiles for",
                b"errsec",
                b"code object is not signed",
            ]
        ):
            category = "signing-configuration"
            recovery = (
                "fix the signing configuration before starting a new workflow run"
            )
        elif args[0] == "codesign" or args[:3] == ("asc", "signing", "keychain"):
            category = "signing-verification"
            recovery = "check the signing identity and profiles before starting a new workflow run"
        elif args[:3] == ("asc", "builds", "wait"):
            if any(
                word in diagnostic
                for word in [b"invalid", b"processing failed", b"rejected"]
            ):
                category = "processing-rejected"
                recovery = "start a new workflow run with a new build number after fixing the rejection"
            elif any(
                word in diagnostic
                for word in [b"timed out", b"timeout", b"deadline exceeded"]
            ):
                category = "processing-timeout"
                recovery = "rerun this workflow to reconcile the reserved build number"
            else:
                category = "processing-query-failed"
                recovery = (
                    "check service availability, then rerun this workflow to reconcile"
                )
        elif args[:3] == ("asc", "builds", "upload"):
            category = "upload-commit-unknown"
            recovery = (
                "inspect the Apple upload before starting a new workflow run; "
                "an unknown outcome without a saved upload ID cannot be reconciled automatically"
            )
        elif args[:2] == ("asc", "xcode"):
            category = "build-configuration"
            recovery = "fix the build configuration before starting a new workflow run"
        elif args[0] == "asc":
            category = "remote-request-failed"
            recovery = "check service availability and permissions, then rerun this workflow to reconcile"
        report = {
            "operation": operation,
            "category": category,
            "exitCode": result.returncode,
            "recovery": recovery,
        }
        if FAILURE_PATH is not None:
            FAILURE_PATH.parent.mkdir(parents=True, exist_ok=True)
            FAILURE_PATH.write_text(json.dumps(report, indent=2) + "\n")
        raise ReleaseError(
            f"{operation}: {category} (exit {result.returncode}); {recovery}"
        )
    return result.stdout


def asc(*args, env):
    try:
        return json.loads(command("asc", *args, "--output", "json", env=env))
    except (ValueError, UnicodeError) as error:
        raise ReleaseError("asc returned an invalid JSON response") from error


def required(name):
    value = os.environ.get(name)
    if not value:
        raise ReleaseError(f"missing {name}")
    return value


def private_file(path, data):
    with path.open("xb") as file:
        os.chmod(path, 0o600)
        file.write(data)
    return path


def decode_profile(path, bundle, team, env):
    try:
        profile = plistlib.loads(
            command("security", "cms", "-D", "-i", str(path), env=env)
        )
        entitlements = profile["Entitlements"]
        expiration = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
        valid = (
            profile["TeamIdentifier"] == [team]
            and entitlements["application-identifier"] == f"{team}.{bundle}"
            and entitlements["com.apple.developer.team-identifier"] == team
            and not entitlements.get("get-task-allow", True)
            and entitlements.get("beta-reports-active") is True
            and "ProvisionedDevices" not in profile
            and not profile.get("ProvisionsAllDevices", False)
            and expiration > datetime.datetime.now(datetime.timezone.utc)
            and profile["DeveloperCertificates"]
            and profile["Name"]
            and re.fullmatch(r"[A-Za-z0-9-]+", profile["UUID"])
        )
        if bundle == BUNDLES["Botto"]:
            valid = valid and entitlements.get("aps-environment") == "production"
        if not valid:
            raise ValueError()
        return profile
    except (KeyError, TypeError, ValueError, plistlib.InvalidFileException) as error:
        raise ReleaseError(
            f"invalid or expired App Store provisioning profile for {bundle}"
        ) from error


def exact_build(app, version, number, env):
    result = asc(
        "builds",
        "list",
        "--app",
        app,
        "--version",
        version,
        "--build-number",
        number,
        "--platform",
        "IOS",
        "--processing-state",
        "all",
        "--paginate",
        env=env,
    )
    builds = result["data"]
    if len(builds) > 1:
        raise ReleaseError("multiple builds match the reserved version and number")
    if not builds:
        return None
    build = builds[0]
    attributes = build["attributes"]
    if attributes.get("expired") or attributes.get("processingState") in {
        "FAILED",
        "INVALID",
    }:
        raise ReleaseError(
            "reserved build failed or expired; start a new workflow run with a new build number"
        )
    return build


def internal_group(app, group, env, *, manual_only=False):
    groups = asc("testflight", "groups", "list", "--app", app, "--paginate", env=env)[
        "data"
    ]
    if not any(
        item["id"] == group and item["attributes"].get("isInternalGroup") is True
        for item in groups
    ):
        raise ReleaseError("configured group must belong to this app and be internal")
    if manual_only and any(
        item["attributes"].get("isInternalGroup") is not False
        and item["attributes"].get("hasAccessToAllBuilds") is not False
        for item in groups
    ):
        raise ReleaseError(
            "disable automatic distribution for every internal group before a fresh upload; "
            "manual-only access could not be confirmed"
        )


def verify_bundles(app, version, number, team, profiles, fingerprint, certificates, env):
    extension = app / "PlugIns/BottoNotifications.appex"
    signed = []
    certificates.mkdir(mode=0o700)
    for target, path in [("Botto", app), ("BottoNotifications", extension)]:
        bundle = BUNDLES[target]
        command(
            "codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            str(path),
            env=env,
        )
        info = plistlib.loads((path / "Info.plist").read_bytes())
        entitlements = plistlib.loads(
            command("codesign", "-d", "--entitlements", ":-", str(path), env=env)
        )
        if (
            info.get("CFBundleIdentifier") != bundle
            or info.get("CFBundleShortVersionString") != version
            or str(info.get("CFBundleVersion")) != number
            or entitlements.get("application-identifier") != f"{team}.{bundle}"
            or entitlements.get("com.apple.developer.team-identifier") != team
            or entitlements.get("get-task-allow", True)
        ):
            raise ReleaseError(
                f"signed target identity or version mismatch for {bundle}"
            )
        profile = decode_profile(
            path / "embedded.mobileprovision", BUNDLES[target], team, env
        )
        if profile["UUID"] != profiles[target]["UUID"]:
            raise ReleaseError(
                f"signed profile UUID mismatch for {BUNDLES[target]}; fix signing configuration"
            )
        certificate_prefix = certificates / target
        command(
            "codesign",
            "--display",
            f"--extract-certificates={certificate_prefix}",
            str(path),
            env=env,
        )
        certificate = Path(str(certificate_prefix) + "0").read_bytes()
        if (
            hashlib.sha256(certificate).hexdigest() != fingerprint
            or certificate not in profile["DeveloperCertificates"]
        ):
            raise ReleaseError(
                f"signing certificate mismatch for {BUNDLES[target]}; fix signing configuration"
            )

        signed.append(entitlements)
    shared = f"{team}.com.sree.botto.push"
    if (
        signed[0].get("keychain-access-groups")
        != [f"{team}.{BUNDLES['Botto']}", shared]
        or signed[1].get("keychain-access-groups") != [shared]
        or signed[0].get("aps-environment") != "production"
    ):
        raise ReleaseError(
            "signed targets have invalid Keychain groups or production push entitlements"
        )


def verify_export(ipa, temp, version, number, team, profiles, fingerprint, env):
    exported = temp / "exported"
    exported.mkdir()
    command("ditto", "-x", "-k", str(ipa), str(exported), env=env)
    app = exported / "Payload/Botto.app"
    verify_bundles(
        app, version, number, team, profiles, fingerprint, temp / "exported-certificates", env
    )


def package(temp, output, version, number, team, env):
    profiles = {}
    paths = {}
    for target, variable in [
        ("Botto", "BOTTO_APP_PROFILE_BASE64"),
        ("BottoNotifications", "BOTTO_NOTIFICATIONS_PROFILE_BASE64"),
    ]:
        try:
            paths[target] = private_file(
                temp / f"{target}.mobileprovision",
                base64.b64decode(required(variable), validate=True),
            )
        except ValueError as error:
            raise ReleaseError(f"invalid base64 in {variable}") from error
        profiles[target] = decode_profile(paths[target], BUNDLES[target], team, env)
    identity = private_file(
        temp / "identity.p12",
        base64.b64decode(required("BOTTO_SIGNING_IDENTITY_BASE64"), validate=True),
    )
    password = private_file(
        temp / "identity-password", required("BOTTO_SIGNING_PASSWORD").encode()
    )
    keychain_password = private_file(
        temp / "keychain-password", secrets.token_urlsafe(32).encode()
    )
    keychain = temp / "signing.keychain-db"
    original = shlex.split(
        command("security", "list-keychains", "-d", "user", env=env).decode()
    )
    installed_profiles = []
    profile_directory = (
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    )
    try:
        result = asc(
            "signing",
            "keychain",
            "install",
            "--identity",
            str(identity),
            "--identity-password-file",
            str(password),
            "--keychain",
            str(keychain),
            "--keychain-password-file",
            str(keychain_password),
            "--add-to-search-list",
            "--confirm",
            env=env,
        )
        if result.get("teamId") != team:
            raise ReleaseError("signing identity belongs to another team")
        fingerprint = result["certificateSha256"].replace(":", "").lower()
        for profile in profiles.values():
            if fingerprint not in [
                hashlib.sha256(cert).hexdigest()
                for cert in profile["DeveloperCertificates"]
            ]:
                raise ReleaseError(
                    "signing identity is absent from a provisioning profile"
                )
        profile_directory.mkdir(parents=True, exist_ok=True)
        for target, profile in profiles.items():
            destination = profile_directory / f"{profile['UUID']}.mobileprovision"
            content = paths[target].read_bytes()
            if destination.exists():
                if destination.read_bytes() != content:
                    raise ReleaseError(
                        "provisioning profile UUID collides with an existing profile"
                    )
            else:
                private_file(destination, content)
                installed_profiles.append(destination)
        archive = temp / "Botto.xcarchive"
        flags = [
            "-destination",
            "generic/platform=iOS",
            f"CURRENT_PROJECT_VERSION={number}",
            "CODE_SIGN_STYLE=Manual",
            "CODE_SIGN_IDENTITY=Apple Distribution",
            f"DEVELOPMENT_TEAM={team}",
            f"BOTTO_APP_PROVISIONING_PROFILE_SPECIFIER={profiles['Botto']['Name']}",
            f"BOTTO_NOTIFICATIONS_PROVISIONING_PROFILE_SPECIFIER={profiles['BottoNotifications']['Name']}",
        ]
        asc(
            "xcode",
            "archive",
            "--project",
            "Botto.xcodeproj",
            "--scheme",
            "Botto Internal",
            "--configuration",
            "Internal",
            "--archive-path",
            str(archive),
            *[f"--xcodebuild-flag={flag}" for flag in flags],
            env=env,
        )
        verify_bundles(
            archive / "Products/Applications/Botto.app",
            version,
            number,
            team,
            profiles,
            fingerprint,
            temp / "archive-certificates",
            env,
        )
        options = temp / "ExportOptions.plist"
        private_file(
            options,
            plistlib.dumps(
                {
                    "method": "app-store-connect",
                    "signingStyle": "manual",
                    "teamID": team,
                    "signingCertificate": "Apple Distribution",
                    "manageAppVersionAndBuildNumber": False,
                    "testFlightInternalTestingOnly": True,
                    "provisioningProfiles": {
                        BUNDLES[target]: profile["Name"]
                        for target, profile in profiles.items()
                    },
                }
            ),
        )
        ipa = output / "Botto.ipa"
        asc(
            "xcode",
            "export",
            "--archive-path",
            str(archive),
            "--export-options",
            str(options),
            "--ipa-path",
            str(ipa),
            "--overwrite",
            env=env,
        )
        verification = asc(
            "ipa-info", "--path", str(ipa), "--verify-signature", env=env
        )
        if (
            verification.get("signatureVerification") != "valid"
            or verification.get("bundleId") != BUNDLES["Botto"]
            or verification.get("version") != version
            or str(verification.get("buildNumber")) != number
            or verification.get("teamId") != team
        ):
            raise ReleaseError("exported IPA signature or metadata mismatch")
        try:
            verify_export(ipa, temp, version, number, team, profiles, fingerprint, env)
        except (ReleaseError, OSError, ValueError, KeyError):
            if FAILURE_PATH is not None and not FAILURE_PATH.exists():
                FAILURE_PATH.write_text(
                    json.dumps(
                        {
                            "operation": "verify exported IPA",
                            "category": "invalid-signed-artifact",
                            "recovery": "fix the exported target signing configuration before starting a new workflow run",
                        },
                        indent=2,
                    )
                    + "\n"
                )
            raise
        return ipa
    finally:
        for path in installed_profiles:
            path.unlink(missing_ok=True)
        try:
            command(
                "security", "list-keychains", "-d", "user", "-s", *original, env=env
            )
        finally:
            if keychain.exists():
                asc(
                    "signing",
                    "keychain",
                    "delete",
                    "--keychain",
                    str(keychain),
                    "--confirm",
                    env=env,
                )


@dataclass(frozen=True)
class BuildNotes:
    localization_id: Optional[str]
    text: Optional[str]


def existing_notes(build_id, source, version, number, env):
    localizations = asc(
        "builds", "test-notes", "list", "--build-id", build_id,
        "--locale", "en-US", "--paginate", env=env,
    )["data"]
    if not isinstance(localizations, list):
        raise ReleaseError("invalid What to Test localization response; review this build manually")
    if not localizations:
        return BuildNotes(None, None)
    if len(localizations) != 1:
        raise ReleaseError("existing What to Test notes are ambiguous; review this build manually")
    localization = localizations[0]
    if not isinstance(localization, dict) or not isinstance(localization.get("attributes"), dict):
        raise ReleaseError("invalid What to Test localization; review this build manually")
    localization_id = localization.get("id")
    attributes = localization.get("attributes", {})
    if (
        localization.get("type") != "betaBuildLocalizations"
        or not isinstance(localization_id, str) or not localization_id
        or attributes.get("locale") != "en-US"
    ):
        raise ReleaseError("invalid What to Test localization; review this build manually")
    prefix = notes_prefix(source, version, number)
    notes = attributes.get("whatsNew")
    if notes is None or isinstance(notes, str) and not notes.strip():
        return BuildNotes(localization_id, None)
    if (
        not isinstance(notes, str)
        or not notes.startswith(prefix)
        or not notes[len(prefix):].strip()
    ):
        raise ReleaseError(
            "existing What to Test notes belong to another source, are ambiguous or empty; review this build manually"
        )
    return BuildNotes(localization_id, notes)


def project_version(env):
    versions = [
        asc(
            "xcode",
            "version",
            "view",
            "--project",
            "Botto.xcodeproj",
            "--target",
            target,
            "--configuration",
            "Internal",
            "--xcodebuild-settings-lookup",
            "never",
            env=env,
        )["version"]
        for target in BUNDLES
    ]
    if versions[0] != versions[1]:
        raise ReleaseError("app and extension marketing versions differ")
    return versions[0]


def prepare_notes(args, env):
    version = project_version(env)
    notes = what_to_test(args.source_sha, version, args.build_number, args.notes_base_sha, env)
    record = {
        "sourceSHA": args.source_sha, "runID": required("GITHUB_RUN_ID"),
        "version": version, "buildNumber": args.build_number,
        "notesBaseSHA": args.notes_base_sha or None, "whatToTest": notes,
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    private_file(args.output_dir / "prepared-notes.json", (json.dumps(record, indent=2) + "\n").encode())


def prepared_notes(output, source, version, number):
    path = output / "prepared-notes.json"
    if not path.exists():
        raise ReleaseError(
            "original prepared notes are unavailable; restore this run's testflight-notes artifact "
            "or review the uploaded build and restore its source-bound notes manually"
        )
    record = json.loads(path.read_text())
    expected = {"sourceSHA": source, "version": version, "buildNumber": number, "runID": required("GITHUB_RUN_ID")}
    prefix = notes_prefix(source, version, number)
    notes = record.get("whatToTest")
    if (
        any(record.get(key) != value for key, value in expected.items())
        or "notesBaseSHA" not in record
        or (record["notesBaseSHA"] is not None and not re.fullmatch(r"[0-9a-f]{40}", str(record["notesBaseSHA"])))
        or not isinstance(notes, str) or not notes.startswith(prefix)
        or not notes[len(prefix):].strip() or len(notes.encode()) > 3500
    ):
        raise ReleaseError("prepared notes do not match this source, run, version and build; restore the original artifact")
    return notes


def verify_build_upload(build_id, upload_id, env):
    resource = asc(
        "api", "GET", f"/v1/builds/{quote(build_id, safe='')}",
        "--query", "fields[builds]=buildUpload", "--query", "include=buildUpload",
        "--query", "fields[buildUploads]=cfBundleVersion,cfBundleShortVersionString,state", env=env,
    )["data"]
    if resource.get("relationships", {}).get("buildUpload", {}).get("data") != {
        "type": "buildUploads", "id": upload_id,
    }:
        raise ReleaseError("Apple build does not belong to this run's saved upload; inspect the original upload manually")


def publish(args, temp, env):
    app, team, group = (
        required("BOTTO_APP_ID"),
        required("BOTTO_TEAM_ID"),
        required("BOTTO_INTERNAL_GROUP_ID"),
    )
    version = project_version(env)
    internal_group(app, group, env)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    receipt_path = output / "receipt.json"
    receipt = {
        "sourceSHA": args.source_sha,
        "runID": required("GITHUB_RUN_ID"),
        "version": version,
        "buildNumber": args.build_number,
    }
    if receipt_path.exists():
        previous = json.loads(receipt_path.read_text())
        if any(previous.get(key) != value for key, value in receipt.items()):
            raise ReleaseError("existing receipt belongs to another release")
        receipt.update(previous)
    build = exact_build(app, version, args.build_number, env)
    first_attempt = int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) == 1
    upload_id = receipt.get("uploadID")
    if build and first_attempt:
        raise ReleaseError("reserved build number is already occupied; start a new workflow run with a higher number")
    if not first_attempt and (not isinstance(upload_id, str) or not upload_id):
        raise ReleaseError(
            "saved upload identity is unavailable; inspect the original Apple upload before starting a new workflow run; "
            "this run cannot verify ownership or repeat the upload"
        )
    verified_build_id = None
    if build:
        verify_build_upload(build["id"], upload_id, env)
        verified_build_id = build["id"]
    selected_notes = None
    if not build:
        uploads = asc(
            "builds",
            "uploads",
            "list",
            "--app",
            app,
            "--cf-bundle-short-version",
            version,
            "--cf-bundle-version",
            args.build_number,
            "--platform",
            "IOS",
            "--paginate",
            env=env,
        )["data"]
        if uploads and first_attempt:
            raise ReleaseError("reserved build number is already occupied; start a new workflow run with a higher number")
        if uploads and not any(item.get("id") == upload_id for item in uploads):
            raise ReleaseError("reserved upload does not belong to this run's saved upload; inspect it manually")
        states = {item["attributes"].get("state", {}).get("state") for item in uploads}
        if states - {"PROCESSING", "COMPLETE"}:
            raise ReleaseError(
                "reserved upload is uncommitted, failed, or unknown and cannot safely resume; "
                "start a new workflow run with a new build number; do not upload this number again"
            )
        if not uploads:
            if not first_attempt:
                raise ReleaseError("saved upload is not visible at Apple; inspect it manually before starting a new workflow run")
            next_number = asc(
                "builds",
                "next-build-number",
                "--app",
                app,
                "--version",
                version,
                "--platform",
                "IOS",
                "--processing-state",
                "all",
                env=env,
            )["nextBuildNumber"]
            if not re.fullmatch(r"[1-9][0-9]*", str(next_number)):
                raise ReleaseError(
                    "cannot validate Apple's build-number floor; review remote numbering before publishing"
                )
            if int(args.build_number) < int(next_number):
                raise ReleaseError(
                    "reserved build number is superseded and no committed upload was found; "
                    "start a new workflow run with a higher build number"
                )
            selected_notes = prepared_notes(output, args.source_sha, version, args.build_number)
            ipa = package(temp, output, version, args.build_number, team, env)
            receipt["ipaSHA256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
            internal_group(app, group, env, manual_only=True)
            uploaded = asc("builds", "upload", "--app", app, "--ipa", str(ipa), env=env)
            upload_id = uploaded.get("uploadId")
            if not isinstance(upload_id, str) or not upload_id:
                raise ReleaseError("upload returned no identity; inspect the Apple upload manually before starting a new workflow run")
            receipt["uploadID"] = upload_id
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    if not build or build["attributes"].get("processingState") != "VALID":
        asc(
            "builds",
            "wait",
            "--app",
            app,
            "--build-number",
            args.build_number,
            "--version",
            version,
            "--platform",
            "IOS",
            "--timeout",
            "15m",
            "--poll-interval",
            "30s",
            "--fail-on-invalid",
            env=env,
        )
        build = exact_build(app, version, args.build_number, env)
    if not build or build["attributes"].get("processingState") != "VALID":
        raise ReleaseError("build is not valid yet; rerun this workflow to reconcile")
    build_id = build["id"]
    if build_id != verified_build_id:
        verify_build_upload(build_id, upload_id, env)
    info = asc("builds", "info", "--build-id", build_id, env=env)
    if info["data"]["attributes"].get("usesNonExemptEncryption") is not False:
        raise ReleaseError(
            "build export compliance is unknown; set ITSAppUsesNonExemptEncryption=false and start a new workflow run"
        )
    current_notes = existing_notes(build_id, args.source_sha, version, args.build_number, env)
    notes = current_notes.text
    if notes is None:
        notes = selected_notes if selected_notes is not None else prepared_notes(
            output, args.source_sha, version, args.build_number
        )
        current_notes = existing_notes(build_id, args.source_sha, version, args.build_number, env)
        if current_notes.text is not None:
            notes = current_notes.text
    if current_notes.text is None:
        body = {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"whatsNew": notes},
        }}
        method, endpoint = "POST", "/v1/betaBuildLocalizations"
        if current_notes.localization_id:
            body["data"]["id"] = current_notes.localization_id
            method, endpoint = "PATCH", f"/v1/betaBuildLocalizations/{quote(current_notes.localization_id, safe='')}"
        else:
            body["data"]["attributes"]["locale"] = "en-US"
            body["data"]["relationships"] = {"build": {"data": {"type": "builds", "id": build_id}}}
        request = private_file(temp / "notes-request.json", json.dumps(body).encode())
        try:
            asc("api", method, endpoint, "--body-file", str(request), "--confirm", env=env)
        except ReleaseError:
            try:
                recovered = existing_notes(build_id, args.source_sha, version, args.build_number, env).text
                if method == "PATCH" and recovered is not None and recovered != notes:
                    raise ReleaseError(
                        "What to Test notes differ after an uncertain update; review this build manually"
                    )
            except ReleaseError:
                if FAILURE_PATH is not None:
                    FAILURE_PATH.unlink(missing_ok=True)
                raise
            if recovered is None:
                raise
            notes = recovered
            if FAILURE_PATH is not None:
                FAILURE_PATH.unlink(missing_ok=True)
        else:
            if existing_notes(build_id, args.source_sha, version, args.build_number, env).text != notes:
                raise ReleaseError("What to Test notes were not confirmed; rerun to reconcile")
    internal_group(app, group, env)
    membership = asc("builds", "groups", "list", "--build-id", build_id, env=env)
    if not any(
        item["id"] == group and item.get("type") == "internal"
        for item in membership["groups"]
    ):
        asc("builds", "add-groups", "--build-id", build_id, "--group", group, env=env)
        membership = asc("builds", "groups", "list", "--build-id", build_id, env=env)
    if not any(
        item["id"] == group and item.get("type") == "internal"
        for item in membership["groups"]
    ):
        raise ReleaseError("internal group assignment was not confirmed")
    detail = asc("builds", "build-beta-detail", "view", "--build-id", build_id, env=env)
    if detail["data"]["attributes"].get("internalBuildState") != "IN_BETA_TESTING":
        raise ReleaseError(
            "build is not available for internal testing yet; rerun this workflow"
        )
    (output / "failure.json").unlink(missing_ok=True)
    receipt["buildID"] = build_id
    receipt.setdefault("ipaSHA256", None)
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    (output / "what-to-test.txt").write_text(notes + "\n")
    print(
        f"TestFlight build {version} ({args.build_number}) is available to the internal group"
    )


def interrupted(_number, _frame):
    raise PublicationInterrupted("publication interrupted; rerun this workflow to reconcile")


def main():
    global FAILURE_PATH
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--notes-base-sha")
    parser.add_argument("--prepare-notes", action="store_true", help="prepare the immutable notes artifact before upload")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ReleaseError("publication is available only in GitHub Actions")
    if (
        not re.fullmatch(r"[1-9][0-9]*", args.build_number)
        or int(args.build_number) < 1001
    ):
        raise ReleaseError("CI build number must be an integer of at least 1001")
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        raise ReleaseError("source SHA must be a full lowercase commit SHA")
    if args.notes_base_sha and not re.fullmatch(r"[0-9a-f]{40}", args.notes_base_sha):
        raise ReleaseError("release-note baseline must be a full commit SHA")
    FAILURE_PATH = args.output_dir.resolve() / "failure.json"
    FAILURE_PATH.unlink(missing_ok=True)
    required("GITHUB_RUN_ID")
    if command("git", "rev-parse", "HEAD").decode().strip() != args.source_sha:
        raise ReleaseError("source SHA does not match git HEAD")
    if command("git", "status", "--porcelain", "--untracked-files=no").strip():
        raise ReleaseError("tracked source must be clean")
    with tempfile.TemporaryDirectory(
        prefix="botto-testflight-", dir=required("RUNNER_TEMP")
    ) as directory:
        temp = Path(directory)
        os.chmod(temp, 0o700)
        env = dict(os.environ)
        for name in list(env):
            if name.startswith("BOTTO_") or name in {
                "ASC_PRIVATE_KEY",
                "ASC_PRIVATE_KEY_PATH",
                "ASC_PROFILE",
                "ASC_CONFIG_PATH",
            }:
                env.pop(name)
        if args.prepare_notes:
            prepare_notes(args, env)
            return
        env.update(
            ASC_KEY_ID=required("ASC_KEY_ID"),
            ASC_ISSUER_ID=required("ASC_ISSUER_ID"),
            ASC_PRIVATE_KEY_PATH=str(
                private_file(temp / "AuthKey.p8", required("ASC_PRIVATE_KEY").encode())
            ),
            ASC_BYPASS_KEYCHAIN="true",
            ASC_CONFIG_PATH=str(temp / "asc.json"),
        )
        publish(args, temp, env)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, PublicationInterrupted, OSError, ValueError, KeyError) as error:
        # Unexpected structured-response errors must not print potentially secret values.
        message = (
            str(error)
            if isinstance(error, (ReleaseError, PublicationInterrupted))
            else "invalid local data or tool response"
        )
        print(f"TestFlight: {message}", file=sys.stderr)
        sys.exit(1)
