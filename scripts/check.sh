#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_diagnostics=${BOTTO_TEST_DIAGNOSTICS:-never}
case "$test_diagnostics" in
  never|on-failure) ;;
  *) echo "BOTTO_TEST_DIAGNOSTICS must be never or on-failure" >&2; exit 2 ;;
esac
if [ -z "${BOTTO_TEST_DESTINATION:-}" ]; then
  echo 'Set BOTTO_TEST_DESTINATION to platform=iOS Simulator,id=<owned clean UUID>.' >&2
  exit 2
fi
destination_id=$(python3 - "$BOTTO_TEST_DESTINATION" <<'PYTHON'
import sys
import uuid
try:
    fields = [part.split("=", 1) for part in sys.argv[1].split(",")]
    values = dict(fields)
    if len(fields) != 2 or set(values) != {"platform", "id"} or values["platform"] != "iOS Simulator":
        raise ValueError()
    uuid.UUID(values["id"])
    print(values["id"])
except (ValueError, KeyError):
    sys.exit("Expected platform=iOS Simulator,id=<owned clean UUID>.")
PYTHON
) || exit 2
./scripts/check-core.sh
mkdir -p .artifacts
artifact_run_directory=$(mktemp -d .artifacts/artifact-export.XXXXXX)
printf 'Export evidence: %s\n' "$artifact_run_directory"
artifact_absence_receipt="$artifact_run_directory/absence.json"
artifact_proof_started_at=$(date +%s)
python3 scripts/verify-artifact-export.py \
  --device "$destination_id" --filename notes.txt \
  --not-before "$artifact_proof_started_at" --require-absent \
  --receipt "$artifact_absence_receipt"
# Keep both verdicts: an independent provider read must not hide a UI failure,
# and a UI pass cannot stand in for durable original-byte readback.
set +e
TEST_RUNNER_BOTTO_ARTIFACT_EXPORT_ABSENCE="$(cat "$artifact_absence_receipt")" \
xcodebuild test -project Botto.xcodeproj -scheme Botto -configuration Debug \
  -destination "platform=iOS Simulator,id=$destination_id" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics "$test_diagnostics" \
  -derivedDataPath .artifacts/DerivedData CODE_SIGNING_ALLOWED=NO
test_status=$?
python3 scripts/verify-artifact-export.py \
  --device "$destination_id" \
  --filename notes.txt \
  --not-before "$artifact_proof_started_at" \
  --absence-receipt "$artifact_absence_receipt" \
  --receipt "$artifact_run_directory/result.json"
export_status=$?
set -e
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
exit "$export_status"
