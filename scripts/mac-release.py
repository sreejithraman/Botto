#!/usr/bin/env python3
"""Package, sign, notarize, generate Sparkle appcasts, and publish Botto.app Homebrew casks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = "sreejithraman/Botto"
DEFAULT_TAP_REPO = "sreejithraman/homebrew-tap"
DEFAULT_SPARKLE_ACCOUNT = "botto"
APP_BUNDLE_NAME = "Botto.app"
MAC_SCHEME = "BottoMac"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TEAM_ID_RE = re.compile(r"\(([A-Z0-9]{10})\)\s*$")


class ReleaseError(RuntimeError):
    """Raised when a release preflight, build, signing, or publish step fails."""


def validate_version(version: str) -> str:
    if not SEMVER_RE.fullmatch(version):
        raise ReleaseError(f"Expected X.Y.Z marketing version, got {version!r}")
    return version


def validate_build(build: str) -> str:
    if not build.isdigit() or int(build) <= 0:
        raise ReleaseError(f"Expected positive integer build number, got {build!r}")
    return str(int(build))


def validate_sha256(digest: str) -> str:
    normalized = digest.strip().lower()
    if not SHA256_RE.fullmatch(normalized):
        raise ReleaseError(f"Expected 64-character lowercase SHA-256 hex digest, got {digest!r}")
    return normalized


def validate_repo(repo: str) -> str:
    if not REPO_RE.fullmatch(repo):
        raise ReleaseError(f"Expected owner/repo GitHub slug, got {repo!r}")
    return repo


def release_tag(version: str, channel: str, build: str | None = None) -> str:
    validate_version(version)
    if channel == "beta":
        if not build:
            raise ReleaseError("Beta releases require --build")
        return f"v{version}-beta.{validate_build(build)}"
    if channel == "stable":
        return f"v{version}"
    raise ReleaseError(f"Unsupported channel {channel!r}")


def archive_filename(version: str, channel: str, build: str | None = None) -> str:
    validate_version(version)
    if channel == "beta":
        if not build:
            raise ReleaseError("Beta releases require --build")
        return f"Botto-{version}-beta.{validate_build(build)}.zip"
    if channel == "stable":
        return f"Botto-{version}.zip"
    raise ReleaseError(f"Unsupported channel {channel!r}")


def cask_filename(channel: str) -> str:
    if channel == "beta":
        return "botto@beta.rb"
    if channel == "stable":
        return "botto.rb"
    raise ReleaseError(f"Unsupported channel {channel!r}")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_checksum_file(artifact: Path, checksum_path: Path) -> str:
    if not artifact.is_file():
        raise ReleaseError(f"Missing release archive: {artifact}")
    if not checksum_path.is_file():
        raise ReleaseError(f"Missing checksum file: {checksum_path}")
    raw = checksum_path.read_text(encoding="utf-8").strip().splitlines()
    if not raw:
        raise ReleaseError(f"Empty checksum file: {checksum_path}")
    parts = raw[0].split()
    expected = validate_sha256(parts[0])
    if len(parts) >= 2 and Path(parts[1]).name != artifact.name:
        raise ReleaseError(f"Checksum file {checksum_path} names {parts[1]!r}, expected {artifact.name!r}")
    actual = sha256_file(artifact)
    if actual != expected:
        raise ReleaseError(f"SHA-256 mismatch for {artifact.name}: expected {expected}, got {actual}")
    return actual


def render_cask(
    *,
    channel: str,
    version: str,
    sha256: str,
    repo: str = DEFAULT_REPO,
    build: str | None = None,
    templates_dir: Path = REPO_ROOT / "scripts/homebrew",
) -> str:
    validate_version(version)
    digest = validate_sha256(sha256)
    validate_repo(repo)
    tag = release_tag(version, channel, build)

    template_name = "botto-beta.rb.template" if channel == "beta" else "botto.rb.template"
    template_path = templates_dir / template_name
    if not template_path.is_file():
        raise ReleaseError(f"Missing cask template: {template_path}")

    rendered = template_path.read_text(encoding="utf-8")
    replacements = {
        "@VERSION@": version,
        "@SHA256@": digest,
        "@REPO@": repo,
        "@TAG@": tag,
    }
    if channel == "beta":
        replacements["@BUILD@"] = validate_build(build or "")
    for needle, value in replacements.items():
        rendered = rendered.replace(needle, value)
    if "@" in re.sub(r'cask "botto@beta"', "", rendered):
        leftovers = re.findall(r"@[A-Z0-9_]+@", rendered)
        if leftovers:
            raise ReleaseError(f"Unreplaced template placeholders: {', '.join(leftovers)}")
    return rendered


def run_cmd(cmd: list[str], *, cwd: Path | None = None, capture: bool = False, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if result.returncode != 0:
        detail = ""
        if capture:
            detail = f"\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        raise ReleaseError(f"Command failed ({result.returncode}): {' '.join(cmd)}{detail}")
    return result.stdout if capture else ""


def detect_developer_id_team(signing_identity: str | None = None) -> tuple[str, str]:
    output = run_cmd(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
    matches = re.findall(r'"(Developer ID Application:[^"]+)"', output)
    if signing_identity:
        candidates = [m for m in matches if signing_identity in m]
    else:
        candidates = matches
    if not candidates:
        raise ReleaseError(
            "No valid 'Developer ID Application' certificate found in Keychain. "
            "Install one or pass --signing-identity and --team-id."
        )
    identity = candidates[0]
    team_match = TEAM_ID_RE.search(identity)
    if not team_match:
        raise ReleaseError(f"Could not extract 10-character Team ID from identity {identity!r}")
    return identity, team_match.group(1)


def find_generate_appcast(explicit: Path | None = None) -> Path:
    if explicit is not None:
        if not explicit.is_file() or not os.access(explicit, os.X_OK):
            raise ReleaseError(f"generate_appcast is not executable: {explicit}")
        return explicit
    search_roots = [
        Path("/tmp/botto-sparkle-resolve"),
        Path(os.environ.get("RUNNER_TEMP", "/tmp")),
        Path.home() / "Library/Developer/Xcode/DerivedData",
    ]
    for root in search_roots:
        if not root.exists():
            continue
        for candidate in root.glob("**/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate
    raise ReleaseError(
        "Could not find Sparkle's generate_appcast binary. Run "
        "`xcodebuild -resolvePackageDependencies -project Botto.xcodeproj -scheme BottoMac` "
        "or pass --generate-appcast PATH."
    )


def verify_app_bundle(app_path: Path, *, expected_version: str, expected_build: str, expected_channel: str) -> None:
    if not app_path.is_dir():
        raise ReleaseError(f"Expected {APP_BUNDLE_NAME} at {app_path}")
    info_plist_path = app_path / "Contents/Info.plist"
    if not info_plist_path.is_file():
        raise ReleaseError(f"Missing Info.plist inside {app_path}")
    with info_plist_path.open("rb") as handle:
        info = plistlib.load(handle)

    if info.get("CFBundleName") != "Botto":
        raise ReleaseError(f"Expected CFBundleName='Botto', got {info.get('CFBundleName')!r}")
    if info.get("CFBundleShortVersionString") != expected_version:
        raise ReleaseError(
            f"Expected CFBundleShortVersionString={expected_version!r}, "
            f"got {info.get('CFBundleShortVersionString')!r}"
        )
    if info.get("CFBundleVersion") != expected_build:
        raise ReleaseError(
            f"Expected CFBundleVersion={expected_build!r}, got {info.get('CFBundleVersion')!r}"
        )
    if expected_channel == "beta" and info.get("BottoUpdateChannel") != "beta":
        raise ReleaseError(
            f"Expected BottoUpdateChannel='beta' for beta build, got {info.get('BottoUpdateChannel')!r}"
        )
    public_key = str(info.get("SUPublicEDKey", "")).strip()
    if not public_key or "PENDING_" in public_key:
        raise ReleaseError("SUPublicEDKey is missing or placeholder in built Botto.app Info.plist")

    t3_binary = app_path / "Contents/Resources/T3Engine/t3"
    if not t3_binary.is_file() or not os.access(t3_binary, os.X_OK):
        raise ReleaseError(f"Embedded T3 engine binary missing or non-executable: {t3_binary}")

    run_cmd(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)])
    run_cmd([str(t3_binary), "--version"], capture=True)


def verify_appcast_xml(appcast_path: Path, *, expected_zip_name: str, expected_channel: str) -> None:
    if not appcast_path.is_file():
        raise ReleaseError(f"Missing generated appcast: {appcast_path}")
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel_elem = root.find("channel")
    if channel_elem is None:
        raise ReleaseError("Invalid appcast.xml: missing <channel>")

    matched = False
    for item in channel_elem.findall("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        url = enclosure.attrib.get("url", "")
        if not url.endswith("/" + expected_zip_name):
            continue
        sig = enclosure.attrib.get(f"{{{SPARKLE_NS}}}edSignature", "").strip()
        if not sig:
            raise ReleaseError(f"Appcast enclosure for {expected_zip_name} is missing sparkle:edSignature")
        sparkle_channel = item.findtext(f"{{{SPARKLE_NS}}}channel")
        if expected_channel == "beta" and sparkle_channel != "beta":
            raise ReleaseError(f"Expected <sparkle:channel>beta</sparkle:channel> for {expected_zip_name}")
        if expected_channel == "stable" and sparkle_channel not in (None, ""):
            raise ReleaseError(
                f"Expected default (stable) channel for {expected_zip_name}, got {sparkle_channel!r}"
            )
        matched = True
        break

    if not matched:
        raise ReleaseError(f"Generated appcast.xml has no <enclosure> for {expected_zip_name}")


def cmd_package(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    build = validate_build(args.build)
    channel = args.channel
    update_channel_setting = "beta" if channel == "beta" else ""

    if args.team_id:
        team_id = args.team_id
        identity = args.signing_identity or f"Developer ID Application"
    else:
        identity, team_id = detect_developer_id_team(args.signing_identity)

    output_dir = Path(args.output_dir or (REPO_ROOT / ".artifacts" / f"mac-release-{version}-{build}")).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    zip_name = archive_filename(version, channel, build)
    final_zip = output_dir / zip_name
    checksum_path = output_dir / f"{zip_name}.sha256"

    with tempfile.TemporaryDirectory(prefix="botto-mac-release-") as temp_str:
        temp = Path(temp_str)
        derived_data = temp / "DerivedData"
        archive_path = temp / "Botto.xcarchive"
        export_dir = temp / "Export"
        export_options = temp / "ExportOptions.plist"
        with export_options.open("wb") as handle:
            plistlib.dump(
                {
                    "method": "developer-id",
                    "signingStyle": "automatic",
                    "teamID": team_id,
                },
                handle,
            )

        print(f"Archiving {APP_BUNDLE_NAME} {version} ({build}) [{channel}] for team {team_id}...", flush=True)
        run_cmd(
            [
                "xcodebuild",
                "archive",
                "-project",
                str(REPO_ROOT / "Botto.xcodeproj"),
                "-scheme",
                MAC_SCHEME,
                "-configuration",
                "Release",
                "-destination",
                "generic/platform=macOS",
                "-derivedDataPath",
                str(derived_data),
                "-archivePath",
                str(archive_path),
                "ARCHS=arm64",
                "ONLY_ACTIVE_ARCH=NO",
                f"DEVELOPMENT_TEAM={team_id}",
                f"MARKETING_VERSION={version}",
                f"CURRENT_PROJECT_VERSION={build}",
                f"BOTTO_UPDATE_CHANNEL={update_channel_setting}",
            ],
            cwd=REPO_ROOT,
        )

        print("Exporting Developer ID signed app...", flush=True)
        run_cmd(
            [
                "xcodebuild",
                "-exportArchive",
                "-archivePath",
                str(archive_path),
                "-exportPath",
                str(export_dir),
                "-exportOptionsPlist",
                str(export_options),
            ],
            cwd=REPO_ROOT,
        )

        exported_app = export_dir / APP_BUNDLE_NAME
        verify_app_bundle(
            exported_app,
            expected_version=version,
            expected_build=build,
            expected_channel=channel,
        )

        if not args.skip_notarize:
            notarize_zip = temp / "Botto-notarize.zip"
            run_cmd(["ditto", "-c", "-k", "--keepParent", str(exported_app), str(notarize_zip)])
            notary_profile = args.notary_profile or os.environ.get("BOTTO_NOTARY_PROFILE")
            if notary_profile:
                print(f"Submitting {notarize_zip.name} via notarytool profile {notary_profile}...", flush=True)
                notary_cmd = [
                    "xcrun",
                    "notarytool",
                    "submit",
                    str(notarize_zip),
                    "--keychain-profile",
                    notary_profile,
                    "--wait",
                ]
                notary_keychain = os.environ.get("BOTTO_NOTARY_KEYCHAIN")
                if notary_keychain:
                    notary_cmd.extend(["--keychain", notary_keychain])
                run_cmd(notary_cmd)
            else:
                print(f"Submitting {notarize_zip.name} via asc notarization...", flush=True)
                run_cmd(["asc", "notarization", "submit", "--file", str(notarize_zip), "--wait"])

            print("Stapling and verifying Gatekeeper assessment...", flush=True)
            run_cmd(["xcrun", "stapler", "staple", str(exported_app)])
            run_cmd(["xcrun", "stapler", "validate", str(exported_app)])
            run_cmd(["spctl", "-a", "-t", "exec", "-vv", str(exported_app)])

        if final_zip.exists():
            final_zip.unlink()
        run_cmd(["ditto", "-c", "-k", "--keepParent", str(exported_app), str(final_zip)])

    digest = sha256_file(final_zip)
    checksum_path.write_text(f"{digest}  {final_zip.name}\n", encoding="utf-8")
    metadata = {
        "version": version,
        "build": build,
        "channel": channel,
        "tag": release_tag(version, channel, build),
        "zip": final_zip.name,
        "sha256": digest,
        "notarized": not args.skip_notarize,
        "signingIdentity": identity,
        "teamId": team_id,
    }
    (output_dir / "release-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"Packaged: {final_zip}")
    print(f"SHA-256:  {digest}")
    return 0


def cmd_render_cask(args: argparse.Namespace) -> int:
    rendered = render_cask(
        channel=args.channel,
        version=args.version,
        build=args.build,
        sha256=args.sha256,
        repo=args.repo,
    )
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rendered, encoding="utf-8")
        print(f"Wrote {out_path}")
    else:
        sys.stdout.write(rendered)
    return 0


def generate_updated_appcast(
    *,
    zip_path: Path,
    channel: str,
    tag: str,
    repo: str,
    appcast_path: Path,
    generate_appcast_bin: Path,
    sparkle_account: str,
    ed_key_file: Path | None,
    release_notes: str | None = None,
) -> None:
    validate_repo(repo)
    if not zip_path.is_file():
        raise ReleaseError(f"Missing release zip: {zip_path}")

    with tempfile.TemporaryDirectory(prefix="botto-appcast-") as temp_str:
        feed_dir = Path(temp_str) / "feed"
        feed_dir.mkdir()
        if appcast_path.is_file():
            shutil.copy2(appcast_path, feed_dir / "appcast.xml")
        staged_zip = feed_dir / zip_path.name
        shutil.copy2(zip_path, staged_zip)
        if release_notes:
            notes_file = staged_zip.with_suffix(".txt")
            notes_file.write_text(release_notes.strip() + "\n", encoding="utf-8")

        cmd = [
            str(generate_appcast_bin),
            "--download-url-prefix",
            f"https://github.com/{repo}/releases/download/{tag}/",
            "--link",
            f"https://github.com/{repo}/releases/tag/{tag}",
            "--maximum-versions",
            "10",
        ]
        if channel == "beta":
            cmd.extend(["--channel", "beta"])
        if ed_key_file is not None:
            cmd.extend(["--ed-key-file", str(ed_key_file)])
        else:
            cmd.extend(["--account", sparkle_account])
        cmd.append(str(feed_dir))

        run_cmd(cmd)
        generated = feed_dir / "appcast.xml"
        verify_appcast_xml(generated, expected_zip_name=zip_path.name, expected_channel=channel)
        appcast_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(generated, appcast_path)


def cmd_appcast(args: argparse.Namespace) -> int:
    gen_bin = find_generate_appcast(Path(args.generate_appcast) if args.generate_appcast else None)
    ed_key = Path(args.ed_key_file) if args.ed_key_file else None
    notes = Path(args.release_notes_file).read_text(encoding="utf-8") if args.release_notes_file else args.release_notes
    appcast_path = Path(args.appcast).resolve()
    generate_updated_appcast(
        zip_path=Path(args.zip).resolve(),
        channel=args.channel,
        tag=args.tag,
        repo=args.repo,
        appcast_path=appcast_path,
        generate_appcast_bin=gen_bin,
        sparkle_account=args.sparkle_account,
        ed_key_file=ed_key,
        release_notes=notes,
    )
    print(f"Updated Sparkle appcast at {appcast_path}")
    return 0


def cmd_publish(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    build = validate_build(args.build) if args.build else None
    channel = args.channel
    repo = validate_repo(args.repo)
    tap_repo = validate_repo(args.tap_repo)
    tag = release_tag(version, channel, build)

    zip_path = Path(args.zip).resolve()
    checksum_path = Path(args.sha256_file).resolve() if args.sha256_file else Path(f"{zip_path}.sha256")
    digest = verify_checksum_file(zip_path, checksum_path)
    expected_name = archive_filename(version, channel, build)
    if zip_path.name != expected_name:
        raise ReleaseError(f"Expected archive named {expected_name!r}, got {zip_path.name!r}")

    cask_text = render_cask(channel=channel, version=version, build=build, sha256=digest, repo=repo)
    cask_name = cask_filename(channel)
    notes = args.notes or f"Botto {version}" + (f" Beta {build}" if channel == "beta" else "")

    with tempfile.TemporaryDirectory(prefix="botto-publish-") as temp_str:
        temp = Path(temp_str)
        cask_check_file = temp / cask_name
        cask_check_file.write_text(cask_text, encoding="utf-8")
        run_cmd(["ruby", "-c", str(cask_check_file)], capture=True)

        if args.dry_run:
            print(f"[dry-run] Would publish {tag} ({zip_path.name}, sha256={digest}) to {repo}")
            print(f"[dry-run] Would update Casks/{cask_name} in {tap_repo}:\n{cask_text}")
            return 0

        # 1. Create or update GitHub Release with zip + sha256
        existing = subprocess.run(
            ["gh", "release", "view", tag, "--repo", repo],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if existing.returncode == 0:
            run_cmd(["gh", "release", "upload", tag, str(zip_path), str(checksum_path), "--repo", repo, "--clobber"])
        else:
            create_cmd = [
                "gh",
                "release",
                "create",
                tag,
                str(zip_path),
                str(checksum_path),
                "--repo",
                repo,
                "--title",
                f"Botto {version}" + (f" Beta {build}" if channel == "beta" else ""),
                "--notes",
                notes,
            ]
            if channel == "beta":
                create_cmd.append("--prerelease")
            if args.target_commit:
                create_cmd.extend(["--target", args.target_commit])
            run_cmd(create_cmd)

        # 2. Update appcast.xml on repo main branch if requested
        if not args.skip_appcast:
            gen_bin = find_generate_appcast(Path(args.generate_appcast) if args.generate_appcast else None)
            ed_key = Path(args.ed_key_file) if args.ed_key_file else None
            botto_checkout = temp / "botto"
            run_cmd(["gh", "repo", "clone", repo, str(botto_checkout), "--", "--depth", "1", "--branch", "main"])
            appcast_file = botto_checkout / "appcast.xml"
            generate_updated_appcast(
                zip_path=zip_path,
                channel=channel,
                tag=tag,
                repo=repo,
                appcast_path=appcast_file,
                generate_appcast_bin=gen_bin,
                sparkle_account=args.sparkle_account,
                ed_key_file=ed_key,
                release_notes=notes,
            )
            run_cmd(["git", "add", "appcast.xml"], cwd=botto_checkout)
            status = run_cmd(["git", "status", "--porcelain"], cwd=botto_checkout, capture=True).strip()
            if status:
                run_cmd(["git", "commit", "-m", f"Update Sparkle appcast for {tag}"], cwd=botto_checkout)
                run_cmd(["git", "push", "origin", "main"], cwd=botto_checkout)

        # 3. Update Homebrew tap cask
        tap_checkout = temp / "homebrew-tap"
        run_cmd(["gh", "repo", "clone", tap_repo, str(tap_checkout), "--", "--depth", "1"])
        cask_path = tap_checkout / "Casks" / cask_name
        cask_path.parent.mkdir(parents=True, exist_ok=True)
        cask_path.write_text(cask_text, encoding="utf-8")
        run_cmd(["ruby", "-c", str(cask_path)], capture=True)
        run_cmd(["git", "add", f"Casks/{cask_name}"], cwd=tap_checkout)
        tap_status = run_cmd(["git", "status", "--porcelain"], cwd=tap_checkout, capture=True).strip()
        if tap_status:
            run_cmd(["git", "commit", "-m", f"Update {cask_name[:-3]} to {tag}"], cwd=tap_checkout)
            run_cmd(["git", "push", "origin", "HEAD"], cwd=tap_checkout)

    print(f"Published {tag} to https://github.com/{repo}/releases/tag/{tag} and updated {tap_repo}/Casks/{cask_name}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build, sign, notarize, and publish Botto.app releases.")
    sub = parser.add_subparsers(dest="command", required=True)

    p_pkg = sub.add_parser("package", help="Archive, Developer ID sign, notarize, staple, and zip Botto.app")
    p_pkg.add_argument("--version", required=True, help="Marketing version X.Y.Z")
    p_pkg.add_argument("--build", required=True, help="Positive integer CFBundleVersion")
    p_pkg.add_argument("--channel", choices=("beta", "stable"), default="beta")
    p_pkg.add_argument("--team-id", help="Apple Developer Team ID (auto-detected from Keychain if omitted)")
    p_pkg.add_argument("--signing-identity", help="Developer ID Application identity filter")
    p_pkg.add_argument("--notary-profile", help="Optional notarytool Keychain profile (defaults to asc notarization)")
    p_pkg.add_argument("--output-dir", help="Output directory for zip, sha256, and metadata")
    p_pkg.add_argument("--skip-notarize", action="store_true", help="Skip Apple notarization/stapling (smoke test only)")
    p_pkg.set_defaults(func=cmd_package)

    p_cask = sub.add_parser("render-cask", help="Render a Homebrew Cask file from template")
    p_cask.add_argument("--channel", choices=("beta", "stable"), required=True)
    p_cask.add_argument("--version", required=True)
    p_cask.add_argument("--build", help="Required for beta casks")
    p_cask.add_argument("--sha256", required=True)
    p_cask.add_argument("--repo", default=DEFAULT_REPO)
    p_cask.add_argument("--output", help="Write rendered cask to this file")
    p_cask.set_defaults(func=cmd_render_cask)

    p_appcast = sub.add_parser("appcast", help="Generate or update Ed25519-signed Sparkle appcast.xml")
    p_appcast.add_argument("--zip", required=True)
    p_appcast.add_argument("--channel", choices=("beta", "stable"), required=True)
    p_appcast.add_argument("--tag", required=True)
    p_appcast.add_argument("--repo", default=DEFAULT_REPO)
    p_appcast.add_argument("--appcast", default=str(REPO_ROOT / "appcast.xml"))
    p_appcast.add_argument("--generate-appcast", help="Path to Sparkle generate_appcast binary")
    p_appcast.add_argument("--sparkle-account", default=DEFAULT_SPARKLE_ACCOUNT)
    p_appcast.add_argument("--ed-key-file", help="Path to Sparkle Ed25519 private key file (CI)")
    p_appcast.add_argument("--release-notes", help="Plain-text release notes")
    p_appcast.add_argument("--release-notes-file", help="File containing plain-text release notes")
    p_appcast.set_defaults(func=cmd_appcast)

    p_pub = sub.add_parser("publish", help="Publish GitHub Release, Sparkle appcast.xml, and Homebrew tap cask")
    p_pub.add_argument("--zip", required=True)
    p_pub.add_argument("--sha256-file", help="Path to .sha256 file (defaults to <zip>.sha256)")
    p_pub.add_argument("--version", required=True)
    p_pub.add_argument("--build", help="Required for beta releases")
    p_pub.add_argument("--channel", choices=("beta", "stable"), required=True)
    p_pub.add_argument("--repo", default=DEFAULT_REPO)
    p_pub.add_argument("--tap-repo", default=DEFAULT_TAP_REPO)
    p_pub.add_argument("--target-commit", help="Target commit/branch for GitHub Release tag")
    p_pub.add_argument("--notes", help="Release notes text")
    p_pub.add_argument("--generate-appcast", help="Path to Sparkle generate_appcast binary")
    p_pub.add_argument("--sparkle-account", default=DEFAULT_SPARKLE_ACCOUNT)
    p_pub.add_argument("--ed-key-file", help="Path to Sparkle Ed25519 private key file (CI)")
    p_pub.add_argument("--skip-appcast", action="store_true", help="Skip updating appcast.xml on main")
    p_pub.add_argument("--dry-run", action="store_true", help="Validate and print actions without mutating remotes")
    p_pub.set_defaults(func=cmd_publish)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ReleaseError as exc:
        print(f"mac-release: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
