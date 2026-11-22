#!/bin/bash
# Compiles StampTransform.swift + ExifGpsPatch.swift with their standalone test and runs it (macOS host, no simulator needed).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat "$here/ios/community_flutter_stamp_composite/Sources/community_flutter_stamp_composite/StampTransform.swift" > "$tmp/main.swift"
sed '/^import Foundation$/d' "$here/ios/community_flutter_stamp_composite/Sources/community_flutter_stamp_composite/ExifGpsPatch.swift" >> "$tmp/main.swift"
sed '/^import Foundation$/d' "$here/ios/Tests/StampTransformTests.swift" >> "$tmp/main.swift"
xcrun swiftc -O -o "$tmp/t" "$tmp/main.swift"
"$tmp/t"
