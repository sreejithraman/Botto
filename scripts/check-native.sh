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
if [ "$selector" = --build-only ]; then
  build_only=true
  selector=
fi
library_ui=false
if [ "$selector" = LibraryUIFailures ]; then
  library_ui=true
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
selection_arguments=("-only-testing:$selection")
if [ "$library_ui" = true ]; then
  selection_arguments=(
    -only-testing:BottoUITests/InboxRetentionUITests/testRevealedInboxShowsReplyAndReopeningKeepsDraft
    -only-testing:BottoUITests/ArtifactExportUITests/testLibrarySaveToFilesAndReopenSavedOriginal)
fi
native_arguments=(-project Botto.xcodeproj -scheme Botto -configuration Debug
  "${selection_arguments[@]}"
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
export_directory=
export_started=
if [ "$native_status" -eq 0 ] && [ "$library_ui" = true ]; then
  diagnostic_device=$(python3 - "$destination" <<'PYTHON'
import sys
import uuid
fields = dict(part.split("=", 1) for part in sys.argv[1].split(","))
if fields.get("platform") != "iOS Simulator":
    sys.exit("Diagnostic requires an exact iOS Simulator destination.")
print(uuid.UUID(fields["id"]))
PYTHON
  ) || native_status=$?
  if [ "$native_status" -eq 0 ]; then
    printf 'Waiting for hosted Simulator boot and data migration: %s\n' "$diagnostic_device"
    xcrun simctl bootstatus "$diagnostic_device" -b || native_status=$?
  fi
  if [ "$native_status" -eq 0 ]; then
    export_directory="$repo_root/.artifacts/CIExport-$result_id"
    mkdir -p .artifacts
    mkdir "$export_directory" || native_status=$?
  fi
  if [ "$native_status" -eq 0 ]; then
    export_started=$(date +%s)
    python3 scripts/verify-artifact-export.py --device "$diagnostic_device" \
      --filename notes.txt --not-before "$export_started" --require-absent \
      --receipt "$export_directory/absence.json" || native_status=$?
  fi
fi
if [ "$native_status" -eq 0 ] && [ "$build_only" = false ]; then
  result_name="CIResults-$result_id.xcresult"
  if [ "$library_ui" = true ]; then
    TEST_RUNNER_BOTTO_ARTIFACT_EXPORT_ABSENCE="$(cat "$export_directory/absence.json")" \
    xcodebuild test-without-building "${native_arguments[@]}" \
      -resultBundlePath "$native_directory/$result_name" || native_status=$?
    export_status=0
    python3 scripts/verify-artifact-export.py --device "$diagnostic_device" \
      --filename notes.txt --not-before "$export_started" \
      --absence-receipt "$export_directory/absence.json" \
      --receipt "$export_directory/result.json" || export_status=$?
    if [ "$native_status" -eq 0 ]; then native_status=$export_status; fi
  else
    xcodebuild test-without-building "${native_arguments[@]}" \
      -resultBundlePath "$native_directory/$result_name" || native_status=$?
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
