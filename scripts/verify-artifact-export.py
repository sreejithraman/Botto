#!/usr/bin/env python3
"""Fresh byte readback of one public Save to Files export from an owned simulator.

Run after xcodebuild, before deleting its exact simulator. This never creates,
changes, or deletes saved files. The receipt proves bytes and provider ownership;
retain the separate UI test evidence for Save completion and reopening in Files.
"""

import argparse
from datetime import datetime, timezone
import hashlib
from itertools import islice
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
from time import monotonic
import uuid


# Independent transcription of the public Canvas notes.txt fixture, not bytes
# from Botto's model, preview, cache, or a file produced by this verification run.
EXPECTED = b"Canvas demo\n\nDraft, review, then publish. All sample files stay on this device.\n"
EXPECTED_SHA256 = "ab2d37c15d4277807c8d7c9ac788d680ce95645b07a1d0e61ee34005a2b41cce"
PROVIDER_OWNER = "group.com.apple.FileProvider.LocalStorage"
METADATA = ".com.apple.mobile_container_manager.metadata.plist"
STORAGE = "File Provider Storage"
PROOF_NAME = re.compile(r"botto-artifact-export-proof-([0-9a-fA-F-]{36})\.txt")
ABSENCE_RECORD = "botto-artifact-export-absence-v1"


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def valid_uuid(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError):
        return False


def no_symlinks(path, *, must_exist=True):
    """Check every component before resolving, including directories and metadata."""
    require(".." not in path.parts, f"Parent traversal is not allowed: {path}")
    absolute = path.absolute()
    for component in reversed((absolute, *absolute.parents)):
        require(not component.is_symlink(), f"Symlink cannot establish durable ownership: {component}")
    return absolute.resolve(strict=must_exist)


def validate_relative_path(relative):
    parts = relative.parts
    require(len(parts) >= 6 and parts[:3] == ("Containers", "Shared", "AppGroup"),
            "Expected shared provider storage, not Botto's app container.")
    require(valid_uuid(parts[3]), "Expected a real provider container UUID.")
    require(parts[4] == STORAGE, "Expected the durable File Provider Storage directory.")
    folders = parts[5:-1]
    forbidden = {"tmp", "temp", "temporary", "cache", "caches", "preview", "previews", "botto", "botto.app", "com.sree.botto"}
    require(not any(p.lower() in forbidden or p.lower().startswith("botto-artifact-") for p in folders),
            "Temporary, cache, Botto, and preview directories cannot prove a saved export.")
    require(not any(p.startswith(".") for p in folders), "Hidden provider staging/trash directories are not durable output.")
    return parts


def read_plist(path):
    resolved = no_symlinks(path)
    with resolved.open("rb") as handle:
        value = plistlib.load(handle)
    require(isinstance(value, dict), f"Expected metadata dictionary: {path}")
    return value


def provider_owner(container):
    metadata = read_plist(container / METADATA)
    owner = metadata.get("MCMMetadataIdentifier")
    require(owner == PROVIDER_OWNER, f"Wrong provider metadata owner: {owner!r}")
    return owner


def unreadable_directory(error):
    raise error


def saved_candidates(device_data, filename, *, proving_absence=False):
    groups = no_symlinks(device_data / "Containers/Shared/AppGroup", must_exist=not proving_absence)
    matches = []
    if not groups.exists():
        return matches
    for container in groups.iterdir():
        # Do not traverse unrelated providers, app containers, or symbolic links.
        if proving_absence:
            require(not container.is_symlink(), "A linked provider container cannot establish absence.")
        if container.is_symlink() or not container.is_dir() or not valid_uuid(container.name):
            continue
        metadata_path = container / METADATA
        if proving_absence:
            no_symlinks(metadata_path, must_exist=False)
        storage = container / STORAGE
        if not metadata_path.exists():
            require(not proving_absence or not (storage.exists() or storage.is_symlink()),
                    "Unknown provider storage cannot establish absence.")
            continue
        owner = read_plist(metadata_path).get("MCMMetadataIdentifier")
        require(not proving_absence or not storage.exists() or (isinstance(owner, str) and bool(owner)),
                "Unknown provider owner cannot establish absence.")
        if owner != PROVIDER_OWNER:
            continue
        if proving_absence:
            no_symlinks(storage, must_exist=False)
        if not storage.exists():
            continue
        no_symlinks(storage)
        for directory, subdirs, filenames in os.walk(storage, followlinks=False, onerror=unreadable_directory):
            # Reject a matching symlink later; never follow directory symlinks.
            if proving_absence:
                require(not any((Path(directory) / name).is_symlink() for name in subdirs),
                        "A linked provider directory cannot establish absence.")
                aliases = [name for name in subdirs + filenames if name.casefold() == filename.casefold()]
                matches.extend(Path(directory) / name for name in aliases)
                target = Path(directory) / filename
                if not aliases and (target.exists() or target.is_symlink()):
                    matches.append(target)
            subdirs[:] = [name for name in subdirs if not (Path(directory) / name).is_symlink()]
            if not proving_absence and filename in filenames:
                matches.append(Path(directory) / filename)
    return matches


def discover_saved(device_data, filename):
    matches = saved_candidates(device_data, filename)
    require(len(matches) == 1, f"Expected exactly one {filename!r} in local Files storage; found {len(matches)}.")
    return matches[0]


def failure_diagnostics(args):
    """Path/owner hints only; never use diagnostic candidates as acceptance."""
    result = {"provider_metadata": [], "fixture_paths": [], "limit_reached": False}
    if not valid_uuid(args.device) or (args.filename != "notes.txt" and PROOF_NAME.fullmatch(args.filename) is None):
        return result
    deadline = monotonic() + 2
    try:
        device = no_symlinks(args.device_set / args.device)
        identity = read_plist(device / "device.plist")
        require(str(identity.get("UDID", "")).lower() == args.device.lower(), "Device identity mismatch.")
        groups = no_symlinks(device / "data/Containers/Shared/AppGroup")
        visited_directories = 0
        # Bound group inspection, retained metadata, directory traversal, exact
        # filename matches, and time. Do not list unrelated filenames or content.
        for index, container in enumerate(islice(groups.iterdir(), 129)):
            if index == 128 or monotonic() >= deadline or len(result["provider_metadata"]) == 8:
                result["limit_reached"] = True
                break
            if container.is_symlink() or not container.is_dir() or not valid_uuid(container.name):
                continue
            metadata_path = container / METADATA
            if not metadata_path.exists() or metadata_path.is_symlink():
                continue
            owner = read_plist(metadata_path).get("MCMMetadataIdentifier")
            if not isinstance(owner, str) or not owner.startswith("group.com.apple.FileProvider."):
                continue
            result["provider_metadata"].append({"path": str(metadata_path), "owner": owner})
            if owner != PROVIDER_OWNER:
                continue
            # Inspect only the local provider for this exact fixture name. This
            # can reveal a changed native layout, but cannot pass verification.
            for directory, subdirs, filenames in os.walk(container, followlinks=False):
                visited_directories += 1
                if visited_directories > 256 or monotonic() >= deadline or len(result["fixture_paths"]) == 8:
                    result["limit_reached"] = True
                    break
                subdirs[:] = [name for name in subdirs if not (Path(directory) / name).is_symlink()]
                if args.filename in filenames:
                    result["fixture_paths"].append(str(Path(directory) / args.filename))
    except (VerificationError, OSError, ValueError, plistlib.InvalidFileException) as error:
        result["scan_error"] = str(error)
    return result


def verify(args, receipt):
    require(valid_uuid(args.device), "--device must be the exact CI simulator UDID.")
    match = PROOF_NAME.fullmatch(args.filename)
    require(args.filename == "notes.txt" or (match is not None and valid_uuid(match[1])),
            "--filename must be notes.txt or botto-artifact-export-proof-<UUID>.txt from this UI run.")
    require(not args.require_absent or args.filename == "notes.txt", "Absence mode is only for the default notes.txt export.")
    require(args.filename == "notes.txt" or args.absence_receipt is None, "UUID exports do not use an absence receipt.")
    require(math.isfinite(args.not_before) and 0 < args.not_before <= datetime.now(timezone.utc).timestamp(),
            "--not-before must be the Unix time recorded before this CI test run.")
    require(len(EXPECTED) == 80 and hashlib.sha256(EXPECTED).hexdigest() == EXPECTED_SHA256,
            "Independent expected fixture is inconsistent.")
    device = no_symlinks(args.device_set / args.device)
    identity = read_plist(device / "device.plist")
    require(str(identity.get("UDID", "")).lower() == args.device.lower(), "Device metadata does not match the requested UDID.")
    receipt["device_metadata"] = str(device / "device.plist")
    receipt["device_name"] = identity.get("name")
    receipt["runtime"] = identity.get("runtime")
    device_data = no_symlinks(device / "data", must_exist=not args.require_absent)
    if args.require_absent:
        require(args.saved is None, "Absence must inspect all local provider storage, not --saved.")
        candidates = saved_candidates(device_data, args.filename, proving_absence=True)
        require(not candidates, f"Expected no preexisting {args.filename!r} in local Files storage; found {len(candidates)}.")
        receipt["record_kind"] = ABSENCE_RECORD
        receipt["checked_unix_seconds"] = datetime.now(timezone.utc).timestamp()
        return
    fresh_after = args.not_before
    if args.filename == "notes.txt":
        require(args.absence_receipt is not None, "Default notes.txt requires --absence-receipt from before the UI run.")
        require(args.saved is None, "Default notes.txt must be discovered in local provider storage.")
        baseline_path = no_symlinks(args.absence_receipt)
        with os.fdopen(os.open(baseline_path, os.O_RDONLY | os.O_NOFOLLOW), "r", encoding="utf-8") as handle:
            metadata = os.fstat(handle.fileno())
            require(stat.S_ISREG(metadata.st_mode) and metadata.st_size <= 16384,
                    "Absence receipt must be a regular file no larger than 16 KiB.")
            baseline = json.load(handle)
        require(isinstance(baseline, dict) and baseline.get("record_kind") == ABSENCE_RECORD and baseline.get("status") == "absent",
                "Expected a successful export absence receipt.")
        require(str(baseline.get("device_udid", "")).lower() == args.device.lower() and
                baseline.get("saved_filename") == args.filename and baseline.get("not_before") == args.not_before and
                baseline.get("device_metadata") == str(device / "device.plist"),
                "Absence receipt does not match this device, device set, filename, and UI run.")
        checked = baseline.get("checked_unix_seconds")
        require(isinstance(checked, (int, float)) and not isinstance(checked, bool) and math.isfinite(checked) and
                args.not_before <= checked <= datetime.now(timezone.utc).timestamp(), "Absence receipt has an invalid check time.")
        fresh_after = checked
        receipt["absence_receipt"] = str(baseline_path)
        receipt["absent_checked_unix_seconds"] = checked
    candidate = args.saved if args.saved is not None else discover_saved(device_data, args.filename)
    require(candidate.name == args.filename, "Saved file does not have this run's exact filename.")
    saved = no_symlinks(candidate)
    try:
        relative = saved.relative_to(device_data)
    except ValueError as error:
        raise VerificationError("Saved file is outside the specified simulator.") from error
    parts = validate_relative_path(relative)
    container = device_data.joinpath(*parts[:4])
    receipt["saved_original"] = str(saved)
    receipt["provider_metadata"] = str(container / METADATA)
    receipt["provider_owner"] = provider_owner(container)
    # Open a new read handle only after ownership/path checks. Do not accept a
    # symlink or a replacement while reading, or an output left by an older run.
    with os.fdopen(os.open(saved, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode), "Saved output must be a regular file.")
        require(before.st_mtime >= fresh_after, "Saved output predates this CI test run or its absence check.")
        digest = hashlib.sha256()
        actual = bytearray()
        while chunk := handle.read(65536):
            digest.update(chunk)
            # Keep enough for exact raw-byte comparison without retaining a
            # potentially large incorrect output in memory.
            if len(actual) <= len(EXPECTED):
                actual.extend(chunk[:len(EXPECTED) + 1 - len(actual)])
        after = os.fstat(handle.fileno())
    no_symlinks(saved)
    current = saved.lstat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) ==
            (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns),
            "Saved output changed during fresh readback.")
    receipt["saved_bytes"] = after.st_size
    receipt["saved_modified_at"] = datetime.fromtimestamp(after.st_mtime, timezone.utc).isoformat()
    receipt["saved_sha256"] = digest.hexdigest()
    receipt["byte_identical"] = after.st_size == len(EXPECTED) and actual == EXPECTED
    require(receipt["byte_identical"] and receipt["saved_sha256"] == EXPECTED_SHA256,
            "Saved output differs from the original Canvas notes bytes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Exact owned CI simulator UDID; never 'booted'")
    parser.add_argument("--filename", required=True, help="Default notes.txt or exact unique .txt filename recorded by the UI test")
    parser.add_argument("--not-before", required=True, type=float, help="Unix time recorded before xcodebuild test")
    parser.add_argument("--saved", type=Path, help="Optional actual output path; otherwise discover the exact filename")
    parser.add_argument("--device-set", type=Path, default=Path.home() / "Library/Developer/CoreSimulator/Devices",
                        help="CI CoreSimulator device set, if using a custom set")
    parser.add_argument("--receipt", required=True, type=Path, help="Retained JSON result, including verification failures")
    absence = parser.add_mutually_exclusive_group()
    absence.add_argument("--require-absent", action="store_true", help="Record that default notes.txt is absent before the UI run")
    absence.add_argument("--absence-receipt", type=Path, help="Successful pre-UI absence receipt required for default notes.txt")
    args = parser.parse_args()
    # A receipt must never replace the output being inspected or another file
    # inside a simulator. CI retains receipts alongside its xcresult bundle.
    if args.receipt.resolve().is_relative_to(args.device_set.resolve()):
        parser.error("--receipt must be outside the simulator device set")
    if args.absence_receipt is not None and args.absence_receipt.resolve().is_relative_to(args.device_set.resolve()):
        parser.error("--absence-receipt must be outside the simulator device set")
    if any(path is not None and args.receipt.resolve() == path.resolve() for path in (args.saved, args.absence_receipt)):
        parser.error("--receipt must not replace the saved file or absence receipt")
    if args.receipt.exists() or args.receipt.is_symlink():
        parser.error("--receipt already exists; choose a new run-specific path")
    receipt = {
        "status": "failed",
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "device_udid": args.device,
        "saved_filename": args.filename,
        "not_before": args.not_before if math.isfinite(args.not_before) else str(args.not_before),
        "expected_fixture": "Independent literal transcription of public Canvas notes.txt",
        "expected_bytes": len(EXPECTED),
        "expected_sha256": EXPECTED_SHA256,
        "byte_identical": False,
        "scope": "Durable local Files-provider bytes only; Save completion and Files reopen require separate UI evidence.",
    }
    try:
        verify(args, receipt)
        receipt["status"] = "absent" if args.require_absent else "passed"
    except (VerificationError, OSError, ValueError, plistlib.InvalidFileException) as error:
        receipt["error"] = str(error)
        receipt["diagnostics"] = failure_diagnostics(args)
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    try:
        with args.receipt.open("x", encoding="utf-8") as handle:
            handle.write(json.dumps(receipt, indent=2, allow_nan=False) + "\n")
    except FileExistsError:
        parser.error("--receipt already exists; choose a new run-specific path")
    print(json.dumps(receipt, indent=2, allow_nan=False))
    return 0 if receipt["status"] in ("passed", "absent") else 1


if __name__ == "__main__":
    sys.exit(main())
