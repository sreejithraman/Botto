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

xcodebuild test -project Botto.xcodeproj -scheme Botto -configuration Debug \
  -only-testing:BottoTests \
  -destination "$destination" \
  -parallel-testing-enabled NO \
  -derivedDataPath .artifacts/CIDerivedData \
  -resultBundlePath ".artifacts/CIResults-$(uuidgen).xcresult" \
  CODE_SIGNING_ALLOWED=NO
