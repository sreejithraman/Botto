#!/usr/bin/env python3
"""Export Botto's current source without Git history or local development state."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


ROOT_FILES = {
    ".gitattributes", ".gitignore", "AGENTS.md", "CHANGELOG.md",
    "CONTRIBUTING.md", "GLOSSARY.md", "LICENSE", "Package.swift", "README.md",
    "SECURITY.md", "THIRD_PARTY_NOTICES.md", "project.yml",
}
ROOT_DIRECTORIES = {
    ".githooks", ".github", "App", "AppTests", "AppUITests", "Botto.xcodeproj",
    "LICENSES", "Push", "Sources", "Tests", "docs", "scripts",
}
LOCAL_DIRECTORIES = {
    ".git", ".artifacts", ".build", ".swiftpm", ".venv", ".wrangler",
    "DerivedData", "__pycache__", "node_modules", "xcuserdata",
}
SIGNING_SUFFIXES = {".p8", ".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".xcuserstate"}


def git(root, *arguments, data=None):
    return subprocess.check_output(["git", "-C", str(root), *arguments], input=data)


def collect_source(root):
    names = sorted(set(git(root, "ls-files", "-co", "--exclude-standard", "-z").split(b"\0")) - {b""})
    attributes = git(root, "check-attr", "-z", "--stdin", "export-ignore", data=b"\0".join(names) + b"\0").split(b"\0")
    omitted = {attributes[i] for i in range(0, len(attributes) - 1, 3) if attributes[i + 2] == b"set"}
    source = {}
    for raw_name in names:
        name = raw_name.decode("utf-8")
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"Unsafe source path: {name}")
        if raw_name in omitted:
            continue
        if path.parts[0] not in ROOT_DIRECTORIES and name not in ROOT_FILES:
            raise ValueError(f"Review this unexpected release file before exporting: {name}")
        if any(part in LOCAL_DIRECTORIES for part in path.parts):
            raise ValueError(f"Local development state cannot be exported: {name}")
        if (path.name == ".env" or (path.name.startswith(".env.") and path.name != ".env.example")
                or path.name == ".dev.vars" or path.name.startswith(".dev.vars.")
                or path.suffix in SIGNING_SUFFIXES):
            raise ValueError(f"Credential or signing material cannot be exported: {name}")
        original = root / name
        if any(parent.is_symlink() for parent in [original, *original.parents]
               if parent.is_relative_to(root)):
            raise ValueError(f"Symbolic links cannot be exported: {name}")
        if not original.exists():
            continue
        if not original.is_file():
            raise ValueError(f"Expected a regular source file: {name}")
        source[name] = (original.read_bytes(), "755" if original.stat().st_mode & 0o111 else "644")
    required = {"LICENSE", "README.md", "project.yml", "Botto.xcodeproj/project.pbxproj"}
    if not required <= source.keys():
        raise ValueError("The export is missing required Botto source files")
    return source, sorted(name.decode("utf-8") for name in omitted)


def export_source(root, output, manifest_path):
    if output.exists() or output.is_symlink():
        raise ValueError("Choose a new output directory; existing directories are never replaced")
    if manifest_path.exists() or manifest_path.is_symlink():
        raise ValueError("Choose a new manifest path; existing files are never replaced")
    if manifest_path.is_relative_to(output):
        raise ValueError("Keep the manifest outside the exported source directory")
    source, omitted = collect_source(root)
    versions = set(re.findall(r'MARKETING_VERSION:\s*"([0-9]+\.[0-9]+\.[0-9]+)"', source["project.yml"][0].decode()))
    if len(versions) != 1:
        raise ValueError("App and extension must declare the same release version")
    files = [{"path": name, "sha256": hashlib.sha256(data).hexdigest(), "mode": mode, "bytes": len(data)}
             for name, (data, mode) in sorted(source.items())]
    identity = "\n".join(f"{item['sha256']} {item['mode']} {item['path']}" for item in files)
    manifest = {"format": 1, "version": versions.pop(), "snapshot_sha256": hashlib.sha256(identity.encode()).hexdigest(),
                "files": files, "omitted": omitted}
    output.mkdir(parents=True, exist_ok=False)
    for name, (data, mode) in source.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as handle:
            handle.write(data)
        os.chmod(destination, int(mode, 8))
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("x", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New source directory, without Git history")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = arguments.output.expanduser().absolute()
    manifest_path = output.with_name(output.name + "-manifest.json")
    try:
        manifest = export_source(root, output, manifest_path)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Source export stopped: {error}\n")
    print(f"Prepared Botto {manifest['version']}: {len(manifest['files'])} files")
    print(f"Snapshot SHA-256: {manifest['snapshot_sha256']}")
    print(f"Source: {output}")
    print(f"Manifest: {manifest_path}")


if __name__ == "__main__":
    main()
