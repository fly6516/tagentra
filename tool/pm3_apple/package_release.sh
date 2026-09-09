#!/usr/bin/env bash
set -euo pipefail
output="${1:-artifacts}"
test -d "$output/TagentraPM3Core.xcframework"
rm -f "$output/TagentraPM3Core.xcframework.zip" "$output/SHA256SUMS"
(cd "$output" && ditto -c -k --sequesterRsrc --keepParent TagentraPM3Core.xcframework TagentraPM3Core.xcframework.zip)
entries="$(unzip -Z1 "$output/TagentraPM3Core.xcframework.zip" | awk -F/ 'NF {print $1}' | sort -u)"
test "$entries" = TagentraPM3Core.xcframework
(cd "$output" && shasum -a 256 TagentraPM3Core.xcframework.zip TagentraPM3Core-source.tar.gz TagentraPM3Core-build.json LICENSE THIRD_PARTY_NOTICES.md > SHA256SUMS)
