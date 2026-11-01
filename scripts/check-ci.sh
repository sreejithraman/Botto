#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

./scripts/check-core.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v

destination=${BOTTO_TEST_DESTINATION:-}
if [ -z "$destination" ]; then
  device_id=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
iphones = [device for runtime in devices.values() for device in runtime
           if device.get("isAvailable") and "iPhone" in device["name"]]
if not iphones:
    sys.exit("No available iPhone Simulator. Install an iOS runtime in Xcode Settings > Components.")
print(iphones[0]["udid"])
')
  destination="platform=iOS Simulator,id=$device_id"
fi

# Xcode watches this local Swift package; native output writes must not trigger rescans.
native_parent=$(python3 - "$repo_root" "${RUNNER_TEMP:-${TMPDIR:-/tmp}}" <<'PYTHON'
from pathlib import Path
import sys
parent = Path(sys.argv[2]).resolve()
if parent.is_relative_to(Path(sys.argv[1])):
    sys.exit("Native test outputs must stay outside the local Swift package.")
print(parent)
PYTHON
)
native_directory=$(mktemp -d "${native_parent%/}/botto-native.XXXXXX")
result_id=$(uuidgen)
result_name="CIResults-Build-$result_id.xcresult"
native_status=0
native_arguments=(-project Botto.xcodeproj -scheme Botto -configuration Debug
  -only-testing:BottoTests
  -destination "$destination"
  -parallel-testing-enabled NO
  -derivedDataPath "$native_directory/DerivedData"
  CODE_SIGNING_ALLOWED=NO)
xcodebuild build-for-testing "${native_arguments[@]}" \
  -resultBundlePath "$native_directory/$result_name" || native_status=$?
if [ "$native_status" -eq 0 ]; then
  result_name="CIResults-$result_id.xcresult"
  xcodebuild test-without-building "${native_arguments[@]}" \
    -resultBundlePath "$native_directory/$result_name" || native_status=$?
fi

finalize_native() {
  mkdir -p .artifacts || return
  if [ -d "$native_directory/$result_name" ]; then
    mv "$native_directory/$result_name" ".artifacts/$result_name" || return
    printf 'Native test results: %s\n' "$repo_root/.artifacts/$result_name" || return
  fi
  rm -rf "$native_directory"
}

finalization_status=0
if finalize_native; then
  :
else
  finalization_status=$?
  printf 'Native test outputs retained at: %s\n' "$native_directory" >&2
  if [ -n "${GITHUB_OUTPUT:-}" ] && [ -d "$native_directory/$result_name" ]; then
    if ! printf 'native_result_fallback=%s\n' "$native_directory/$result_name" >> "$GITHUB_OUTPUT"; then
      printf 'Could not register the fallback native result for upload.\n' >&2
    fi
  fi
fi

if [ "$native_status" -ne 0 ]; then
  exit "$native_status"
fi
exit "$finalization_status"
