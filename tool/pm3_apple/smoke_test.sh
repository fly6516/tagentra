#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCFRAMEWORK="${1:-$PROJECT_ROOT/artifacts/TagentraPM3Core.xcframework}"
EXPECTED_REVISION="${2:-}"
WORK_ROOT="$PROJECT_ROOT/.build/pm3_apple/smoke"

[[ -d "$XCFRAMEWORK" ]] || { echo "XCFramework not found: $XCFRAMEWORK" >&2; exit 1; }
SIM_SLICE="$(find "$XCFRAMEWORK" -maxdepth 1 -type d -name '*simulator*' -print -quit)"
FRAMEWORK="$SIM_SLICE/TagentraPM3Core.framework"
[[ -d "$FRAMEWORK" ]] || { echo "simulator framework slice is missing" >&2; exit 1; }

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT/Smoke.app/Frameworks"
cp -R "$FRAMEWORK" "$WORK_ROOT/Smoke.app/Frameworks/"
cp "$SCRIPT_DIR/smoke_main.m" "$WORK_ROOT/main.m"

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "arm64" ]]; then HOST_ARCH="x86_64"; fi
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang \
  -target "$HOST_ARCH-apple-ios15.0-simulator" \
  -fobjc-arc "$WORK_ROOT/main.m" \
  -I "$FRAMEWORK/Headers" \
  -F "$WORK_ROOT/Smoke.app/Frameworks" \
  -framework TagentraPM3Core -framework Foundation -framework UIKit \
  -Wl,-rpath,@executable_path/Frameworks \
  -DEXPECTED_REVISION="\"$EXPECTED_REVISION\"" \
  -isysroot "$SDK_PATH" \
  -o "$WORK_ROOT/Smoke.app/Smoke"

cat >"$WORK_ROOT/Smoke.app/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Smoke</string>
  <key>CFBundleIdentifier</key><string>org.tagentra.pm3core.smoke</string>
  <key>CFBundleName</key><string>Smoke</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>15.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
EOF

codesign --force --sign - "$WORK_ROOT/Smoke.app/Frameworks/TagentraPM3Core.framework"
codesign --force --sign - "$WORK_ROOT/Smoke.app"

DEVICE_ID="$(python3 - <<'PY'
import json, subprocess
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            print(device["udid"])
            raise SystemExit
raise SystemExit("no available iPhone simulator")
PY
)"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl uninstall "$DEVICE_ID" org.tagentra.pm3core.smoke 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$WORK_ROOT/Smoke.app"
OUTPUT="$(xcrun simctl launch --console "$DEVICE_ID" org.tagentra.pm3core.smoke 2>&1)"
printf '%s\n' "$OUTPUT"
grep -q 'TAGENTRA_PM3_SMOKE_OK' <<<"$OUTPUT"
