#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REF="v4.21611"
OUTPUT="$PROJECT_ROOT/artifacts"
SOURCE_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: tool/pm3_apple/build.sh [--ref REF] [--output DIR] [--source-dir DIR]

Builds TagentraPM3Core.xcframework for iOS device and simulator. A source
override is useful for testing an existing RRG checkout; it is copied before
the compatibility overlay is applied.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --source-dir) SOURCE_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

"$SCRIPT_DIR/doctor.sh"

REPOSITORY="$(python3 - "$SCRIPT_DIR/refs.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["repository"])
PY
)"
EXPECTED_SHA="$(python3 - "$SCRIPT_DIR/refs.json" "$REF" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data["validated_refs"].get(sys.argv[2], ""))
PY
)"
SLUG="$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '_')"
WORK_ROOT="$PROJECT_ROOT/.build/pm3_apple/$SLUG"
SOURCE_DIR="$WORK_ROOT/source"
BUILD_ROOT="$WORK_ROOT/build"

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$OUTPUT"
if [[ -n "$SOURCE_OVERRIDE" ]]; then
  cp -R "$SOURCE_OVERRIDE" "$SOURCE_DIR"
  git -C "$SOURCE_DIR" checkout --force --detach "$REF"
else
  git clone --filter=blob:none --no-checkout "$REPOSITORY" "$SOURCE_DIR"
  git -C "$SOURCE_DIR" fetch --force --depth=1 origin "$REF"
  git -C "$SOURCE_DIR" checkout --force --detach FETCH_HEAD
fi

ACTUAL_SHA="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ -n "$EXPECTED_SHA" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "ref $REF resolved to $ACTUAL_SHA; expected $EXPECTED_SHA" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/prepare_upstream.py" \
  --source "$SOURCE_DIR" \
  --shim "$PROJECT_ROOT/native/pm3_apple_shim" \
  --revision "$ACTUAL_SHA"

build_slice() {
  local name="$1"
  local sdk="$2"
  local arch="$3"
  local sdk_path deployment_flag build_dir
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  build_dir="$BUILD_ROOT/$name"
  if [[ "$sdk" == "iphoneos" ]]; then
    deployment_flag="-miphoneos-version-min=15.0"
  else
    deployment_flag="-mios-simulator-version-min=15.0"
  fi

  cmake -S "$SOURCE_DIR/client/experimental_lib" -B "$build_dir" -G Xcode \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/ios.toolchain.cmake" \
    -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR='@rpath' \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DTAGENTRA_EXTERNAL_CFLAGS="-arch $arch -isysroot $sdk_path $deployment_flag" \
    -DSKIPBT=1 \
    -DSKIPPYTHON=1 \
    -DSKIPREADLINE=1 \
    -DSKIPLINENOISE=1 \
    -DSKIPGD=1 \
    -DSKIPJANSSONSYSTEM=1 \
    -DSKIPWHEREAMISYSTEM=1
  cmake --build "$build_dir" --config Release --target pm3rrg_rdv4 --parallel

  local framework
  framework="$(find "$build_dir" -type d -name TagentraPM3Core.framework -print -quit)"
  if [[ -z "$framework" ]]; then
    echo "TagentraPM3Core.framework was not produced for $name" >&2
    exit 1
  fi
  mkdir -p "$WORK_ROOT/frameworks"
  rm -rf "$WORK_ROOT/frameworks/$name.framework"
  cp -R "$framework" "$WORK_ROOT/frameworks/$name.framework"
}

build_slice device-arm64 iphoneos arm64
build_slice simulator-arm64 iphonesimulator arm64
build_slice simulator-x86_64 iphonesimulator x86_64

DEVICE_FRAMEWORK="$WORK_ROOT/frameworks/device-arm64.framework"
SIM_FRAMEWORK="$WORK_ROOT/frameworks/simulator.framework"
cp -R "$WORK_ROOT/frameworks/simulator-arm64.framework" "$SIM_FRAMEWORK"
lipo -create \
  "$WORK_ROOT/frameworks/simulator-arm64.framework/TagentraPM3Core" \
  "$WORK_ROOT/frameworks/simulator-x86_64.framework/TagentraPM3Core" \
  -output "$SIM_FRAMEWORK/TagentraPM3Core"

for framework in "$DEVICE_FRAMEWORK" "$SIM_FRAMEWORK"; do
  mkdir -p "$framework/Modules"
  cat >"$framework/Modules/module.modulemap" <<'EOF'
framework module TagentraPM3Core {
  umbrella header "TagentraPM3Core.h"
  export *
  module * { export * }
}
EOF
done

XCFRAMEWORK="$OUTPUT/TagentraPM3Core.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -framework "$DEVICE_FRAMEWORK" \
  -framework "$SIM_FRAMEWORK" \
  -output "$XCFRAMEWORK"

python3 - "$OUTPUT/TagentraPM3Core-build.json" "$REF" "$ACTUAL_SHA" <<'PY'
import datetime, json, sys
path, ref, sha = sys.argv[1:]
with open(path, "w", encoding="utf-8") as output:
    json.dump({
        "abi_version": 1,
        "upstream_repository": "https://github.com/RfidResearchGroup/proxmark3.git",
        "upstream_ref": ref,
        "upstream_revision": sha,
        "deployment_target": "iOS 15.0",
        "architectures": ["ios-arm64", "ios-simulator-arm64", "ios-simulator-x86_64"],
        "built_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }, output, indent=2)
    output.write("\n")
PY

cp "$PROJECT_ROOT/LICENSE" "$OUTPUT/LICENSE"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$OUTPUT/THIRD_PARTY_NOTICES.md"
echo "Created $XCFRAMEWORK from RRG $REF ($ACTUAL_SHA)"
