#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

selector=${1:-}
if [ "$#" -gt 1 ]; then
  echo 'Usage: check-native.sh [--build-only | SuiteName[/testFunction(...)]]' >&2
  exit 2
fi
build_only=false
library_acceptance=false
library_native_failures=false
library_ui_failures=false
if [ "$selector" = LibraryNativeFailures ]; then
  library_native_failures=true
  selector=
elif [ "$selector" = LibraryUIFailures ]; then
  library_acceptance=true
  library_ui_failures=true
  selector=
fi
if [ "$selector" = LibraryAcceptance ]; then
  library_acceptance=true
  selector=
fi
if [ "$selector" = --build-only ]; then
  build_only=true
  selector=
fi
selection=BottoTests
if [ -n "$selector" ]; then
  python3 - "$selector" <<'PYTHON'
import re
import sys
match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?:/([A-Za-z_][A-Za-z0-9_]*)(?:\([A-Za-z_:]*\))?)?", sys.argv[1])
if not match:
    sys.exit("Expected a native test suite or suite/test selector.")
PYTHON
  selection="BottoTests/$selector"
fi
selections=("-only-testing:$selection")
if [ "$library_acceptance" = true ]; then
  selections=("-only-testing:BottoUITests/InboxRetentionUITests"
    "-only-testing:BottoUITests/ArtifactExportUITests/testLibrarySaveToFilesAndReopenSavedOriginal")
fi
if [ "$library_ui_failures" = true ]; then
  selections=("-only-testing:BottoUITests/InboxRetentionUITests/testRevealedInboxShowsReplyAndReopeningKeepsDraft"
    "-only-testing:BottoUITests/ArtifactExportUITests/testLibrarySaveToFilesAndReopenSavedOriginal")
fi
if [ "$library_native_failures" = true ]; then
  selections=("-only-testing:BottoTests/AppStoreRichReplyTests"
    "-only-testing:BottoTests/NativeTranscriptIdentityTests"
    "-only-testing:BottoTests/ReplyFileBodyLayoutTests"
    "-only-testing:BottoTests/WorkspaceLibraryTests"
    "-only-testing:BottoTests/ArtifactCacheTests")
fi

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
if [ "$library_acceptance" = true ]; then
  device_id=$(python3 - "$destination" <<'PYTHON'
import sys
import uuid
parts = dict(part.split("=", 1) for part in sys.argv[1].split(","))
uuid.UUID(parts["id"])
print(parts["id"])
PYTHON
)
  artifact_proof_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  export TEST_RUNNER_BOTTO_ARTIFACT_EXPORT_PROOF_ID="$artifact_proof_id"
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
  "${selections[@]}"
  -destination "$destination"
  -parallel-testing-enabled NO
  -derivedDataPath "$native_directory/DerivedData"
  CODE_SIGNING_ALLOWED=NO)
xcodebuild build-for-testing "${native_arguments[@]}" \
  -resultBundlePath "$native_directory/$result_name" || native_status=$?
if [ "$native_status" -eq 0 ] && [ -n "$selector" ]; then
  xcodebuild test-without-building "${native_arguments[@]}" -enumerate-tests \
    -test-enumeration-style flat -test-enumeration-format text \
    -test-enumeration-output-path "$native_directory/selected-tests.txt" || native_status=$?
  if [ "$native_status" -eq 0 ]; then
    python3 - "$selection" "$native_directory/selected-tests.txt" <<'PYTHON' || native_status=$?
from pathlib import Path
import sys
requested = sys.argv[1].removesuffix("()")
identifiers = [line.strip().removesuffix("()") for line in Path(sys.argv[2]).read_text().splitlines()]
matches = [name for name in identifiers if name == requested or name.startswith(requested + "/")]
if not matches:
    sys.exit("The requested native test was not discovered by Xcode; no tests executed.")
print("Xcode discovered %d matching test identifiers." % len(matches))
PYTHON
  fi
fi
if [ "$native_status" -eq 0 ] && [ "$build_only" = false ]; then
  result_name="CIResults-$result_id.xcresult"
  if [ "$library_acceptance" = true ]; then
    artifact_proof_started_at=$(date +%s)
  fi
  xcodebuild test-without-building "${native_arguments[@]}" \
    -resultBundlePath "$native_directory/$result_name" || native_status=$?
  if [ "$library_acceptance" = true ]; then
    export_status=0
    python3 scripts/verify-artifact-export.py \
      --device "$device_id" \
      --filename "botto-artifact-export-proof-$artifact_proof_id.txt" \
      --not-before "$artifact_proof_started_at" \
      --receipt "$native_directory/export-receipt.json" || export_status=$?
    printf 'Library UI exit: %s; independent export readback exit: %s\n' "$native_status" "$export_status"
    if [ "$native_status" -eq 0 ]; then
      native_status=$export_status
    fi
  fi
fi
if [ "$native_status" -eq 0 ] && [ "$build_only" = false ]; then
  if ! xcrun xcresulttool get test-results summary --path "$native_directory/$result_name" | python3 -c '
import json, sys
summary = json.load(sys.stdin)
passed = summary.get("passedTests")
if not isinstance(passed, int) or passed < 1:
    sys.exit("Native run reported success without executing any passing tests.")
print("Native results: %s passed, %s failed, %s skipped" % (
    passed, summary.get("failedTests"), summary.get("skippedTests")))
'; then
    native_status=1
  fi
fi
if [ "$native_status" -eq 0 ] && [ "$build_only" = true ]; then
  printf 'Native tests were built but not executed (pull-request build check).\n'
fi

finalize_native() {
  mkdir -p .artifacts || return
  if [ -f "$native_directory/export-receipt.json" ]; then
    cp "$native_directory/export-receipt.json" ".artifacts/CIExport-$result_id.json" || return
  fi
  if [ -f "$native_directory/selected-tests.txt" ]; then
    cp "$native_directory/selected-tests.txt" ".artifacts/CISelectedTests-$result_id.txt" || return
  fi
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
