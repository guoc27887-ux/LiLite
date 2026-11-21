#!/usr/bin/env bash
set -euo pipefail
# iOS 18 fork CI build (unsigned Release IPA).
# Upstream 1.0.25 dropped xtool and builds natively with Xcode (LiLite.xcodeproj);
# this script is a thin wrapper around ./build.sh --release.
# The pinned swift-protobuf revision's protoc executable product is rejected by
# Xcode 26's SwiftPM; Wire only needs the SwiftProtobuf library, so opt out.
export PROTOBUF_NO_PROTOC=${PROTOBUF_NO_PROTOC:-true}
root=$(cd "$(dirname "$0")/.." && pwd)
# Firebase SDK staging (1.0.2+ requirement): stages FirebaseSDK/ (device +
# simulator slices + xcframeworks) for the Xcode build. build.sh runs this too;
# staging here keeps the step explicit and idempotent.
python3 "$root/Tools/firebase_sdk.py" "$root"
bash "$root/build.sh" --release
mv "$root/dist/PiliNative-release-unsigned.ipa" "$root/dist/lilite-ios18-unsigned.ipa"
echo "Built dist/lilite-ios18-unsigned.ipa"
