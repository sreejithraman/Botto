#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_diagnostics=${BOTTO_TEST_DIAGNOSTICS:-never}
case "$test_diagnostics" in
  never|on-failure) ;;
  *) echo "BOTTO_TEST_DIAGNOSTICS must be never or on-failure" >&2; exit 2 ;;
esac
./scripts/check-core.sh
destination_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for group in devices.values() for d in group if "iPhone" in d["name"]))')
artifact_proof_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
artifact_proof_started_at=$(date +%s)
# Keep both verdicts: an independent provider read must not hide a UI failure,
# and a UI pass cannot stand in for durable original-byte readback.
set +e
TEST_RUNNER_BOTTO_ARTIFACT_EXPORT_PROOF_ID="$artifact_proof_id" \
xcodebuild test -project Botto.xcodeproj -scheme Botto -configuration Debug \
  -destination "platform=iOS Simulator,id=$destination_id" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics "$test_diagnostics" \
  -derivedDataPath .artifacts/DerivedData CODE_SIGNING_ALLOWED=NO
test_status=$?
python3 scripts/verify-artifact-export.py \
  --device "$destination_id" \
  --filename "botto-artifact-export-proof-$artifact_proof_id.txt" \
  --not-before "$artifact_proof_started_at" \
  --receipt .artifacts/artifact-export-receipt.json
export_status=$?
set -e
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
exit "$export_status"
