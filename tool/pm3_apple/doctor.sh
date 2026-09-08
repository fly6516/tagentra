#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

required=(git cmake python3 xcrun xcodebuild lipo codesign)
for command_name in "${required[@]}"; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

xcodebuild -version
cmake --version | head -n 1
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
echo "Apple build environment is ready."
