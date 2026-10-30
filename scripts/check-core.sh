#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"
swift test --no-parallel --scratch-path .artifacts/CoreTests
swift build --target BottoCore --scratch-path .artifacts/CoreMainActor \
  -Xswiftc -default-isolation -Xswiftc MainActor
