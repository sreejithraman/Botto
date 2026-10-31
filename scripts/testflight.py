#!/usr/bin/env python3
"""Publish one tested GitHub Actions revision to an internal TestFlight group."""

import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tempfile


class ReleaseError(Exception):
    pass


FAILURE_PATH = None

ROOT = Path(__file__).resolve().parents[1]
BUNDLES = {
    "Botto": "com.sree.botto",
    "BottoNotifications": "com.sree.botto.notifications",
}


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
                "rerun this workflow to reconcile; never upload this number manually"
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


def internal_group(app, group, env):
    groups = asc("testflight", "groups", "list", "--app", app, "--paginate", env=env)[
        "data"
    ]
    if not any(
        item["id"] == group and item["attributes"].get("isInternalGroup") is True
        for item in groups
    ):
        raise ReleaseError("configured group must belong to this app and be internal")


def verify_bundles(app, version, number, team, env):
    extension = app / "PlugIns/BottoNotifications.appex"
    signed = []
    for path, bundle in [
        (app, BUNDLES["Botto"]),
        (extension, BUNDLES["BottoNotifications"]),
    ]:
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
    verify_bundles(app, version, number, team, env)
    for target, path in [
        ("Botto", app),
        ("BottoNotifications", app / "PlugIns/BottoNotifications.appex"),
    ]:
        profile = decode_profile(
            path / "embedded.mobileprovision", BUNDLES[target], team, env
        )
        if profile["UUID"] != profiles[target]["UUID"]:
            raise ReleaseError(
                f"exported profile UUID mismatch for {BUNDLES[target]}; fix signing configuration"
            )
        certificate_prefix = temp / f"{target}-exported-cert"
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
                f"exported signing certificate mismatch for {BUNDLES[target]}; fix signing configuration"
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
            "Botto",
            "--configuration",
            "Release",
            "--archive-path",
            str(archive),
            *[f"--xcodebuild-flag={flag}" for flag in flags],
            env=env,
        )
        verify_bundles(
            archive / "Products/Applications/Botto.app", version, number, team, env
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


def publish(args, temp, env):
    app, team, group = (
        required("BOTTO_APP_ID"),
        required("BOTTO_TEAM_ID"),
        required("BOTTO_INTERNAL_GROUP_ID"),
    )
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
            "Release",
            "--xcodebuild-settings-lookup",
            "never",
            env=env,
        )["version"]
        for target in BUNDLES
    ]
    if versions[0] != versions[1]:
        raise ReleaseError("app and extension marketing versions differ")
    version = versions[0]
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
        states = {item["attributes"].get("state", {}).get("state") for item in uploads}
        if states - {"PROCESSING", "COMPLETE"}:
            raise ReleaseError(
                "reserved upload is uncommitted, failed, or unknown and cannot safely resume; "
                "start a new workflow run with a new build number; do not upload this number again"
            )
        if not uploads:
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
            ipa = package(temp, output, version, args.build_number, team, env)
            receipt["ipaSHA256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
            asc("builds", "upload", "--app", app, "--ipa", str(ipa), env=env)
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
    info = asc("builds", "info", "--build-id", build_id, env=env)
    if info["data"]["attributes"].get("usesNonExemptEncryption") is not False:
        raise ReleaseError(
            "build export compliance is unknown; set ITSAppUsesNonExemptEncryption=false and start a new workflow run"
        )
    notes = "Please test sidekick conversations, notifications, and sign-in. Report anything unexpected."
    localizations = asc(
        "builds",
        "test-notes",
        "list",
        "--build-id",
        build_id,
        "--locale",
        "en-US",
        "--paginate",
        env=env,
    )["data"]
    if not localizations:
        asc(
            "builds",
            "test-notes",
            "create",
            "--build-id",
            build_id,
            "--locale",
            "en-US",
            "--whats-new",
            notes,
            env=env,
        )
    elif localizations[0]["attributes"].get("whatsNew") != notes:
        raise ReleaseError(
            "existing What to Test notes differ; review this build manually"
        )
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
    raise ReleaseError("publication interrupted; rerun this workflow to reconcile")


def main():
    global FAILURE_PATH
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--source-sha", required=True)
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
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        # Unexpected structured-response errors must not print potentially secret values.
        message = (
            str(error)
            if isinstance(error, ReleaseError)
            else "invalid local data or tool response"
        )
        print(f"TestFlight: {message}", file=sys.stderr)
        sys.exit(1)
