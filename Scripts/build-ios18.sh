#!/usr/bin/env bash
set -euo pipefail
# The pinned swift-protobuf revision's protoc executable product is rejected by
# Xcode 26's SwiftPM; Wire only needs the SwiftProtobuf library, so opt out.
export PROTOBUF_NO_PROTOC=${PROTOBUF_NO_PROTOC:-true}
root=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
    ""|--release|--release-personal|--sign-dev) ;;
    --sign-personal) python3 "$root/Checks/parity.py" --client-complete ;;
    --sign) python3 "$root/Checks/parity.py" --complete; bash "$root/Checks/run.sh"; python3 "$root/Checks/live_remux.py"; python3 "$root/Checks/live_decode.py"; python3 "$root/Checks/native_decode.py"; python3 "$root/Checks/audio_segments.py"; python3 "$root/Checks/presentation_timing.py"; bash "$root/Checks/storage_locations.sh"; python3 "$root/Checks/backup_recovery.py"; PYTHONDONTWRITEBYTECODE=1 python3 "$root/Checks/anime4k.py" ;;
    *) echo "Usage: build.cmd [--release | --release-personal | --sign | --sign-personal | --sign-dev]" >&2; exit 2 ;;
esac
work="$HOME/.cache/piliplus-native/build"
mkdir -p "$work/Sources" "$root/dist"
# xtool and SwiftPM share this staging directory between debug, release and signing.
exec 9>"$work/.pili-build.lock"
# flock removed for macOS CI (single-runner, no lock contention)
mkdir -p "$work/Resources"
cp "$root/Resources/Info.plist" "$root/Resources/PiliPlus.entitlements" "$work/Resources/"
if [[ $(uname -s) == Darwin ]]; then
  compiled_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
else
  compiled_sdk=$(swift sdk configure --show-configuration darwin arm64-apple-ios | python3 -c 'import sys; rows=[r.removeprefix("sdkRootPath: ").strip() for r in sys.stdin if r.startswith("sdkRootPath: ")]; assert len(rows)==1,"Swift SDK root unavailable"; print(rows[0])')
fi
sdk="${PILI_IOS_SDK:-$compiled_sdk}"
export PILI_IOS_SDK="$sdk"
PILI_IOS_SDK_VERSION=$(python3 "$root/Tools/build_stamp.py" --root "$root" --plist "$work/Resources/Info.plist" --sdk "$sdk" --compiled-sdk "$compiled_sdk" --print-sdk-version)
export PILI_IOS_SDK_VERSION
cp "$root/Resources/AppIcon.png" "$work/Resources/AppIcon.png"
cp "$root/Package.swift" "$root/xtool.yml" "$work/"
if [[ ${1:-} == --sign-personal || ${1:-} == --release-personal || ${1:-} == --sign-dev ]]; then
  python3 "$root/Tools/personal_profile.py" "$work"
fi
mkdir -p "$work/Wire" "$work/ArchiveKit" "$work/ColorKit"
rsync -a --delete --exclude=".build" --exclude=".swiftpm" "$root/ColorKit/" "$work/ColorKit/"
rsync -a --delete --exclude=".build" --exclude=".swiftpm" "$root/ArchiveKit/" "$work/ArchiveKit/"
rsync -a --delete --exclude=".build" --exclude=".swiftpm" "$root/Wire/" "$work/Wire/"
media_prefix=$(bash "$root/MediaKit/build-ffmpeg.sh" ios)
mkdir -p "$work/MediaKit"
rsync -a --delete --exclude="Vendor" --exclude=".build" --exclude=".swiftpm" "$root/MediaKit/" "$work/MediaKit/"
mkdir -p "$work/MediaKit/Vendor"
rsync -a --delete "$media_prefix/include/" "$work/MediaKit/Vendor/include/"
rsync -a --delete --include="*.a" --exclude="*" "$media_prefix/lib/" "$work/MediaKit/Vendor/lib/"
caption_prefix=$(python3 "$root/MediaKit/build-subtitles.py" ios)
rsync -a "$caption_prefix/include/" "$work/MediaKit/Vendor/include/"
rsync -a --include="*.a" --exclude="*" "$caption_prefix/lib/" "$work/MediaKit/Vendor/lib/"
mpv_prefix=$(python3 "$root/MediaKit/build-mpv.py")
rsync -a "$mpv_prefix/include/" "$work/MediaKit/Vendor/include/"
rsync -a --include="*.a" --exclude="*" "$mpv_prefix/lib/" "$work/MediaKit/Vendor/lib/"
mkdir -p "$root/dist/MPV/include"
cp "$mpv_prefix/lib/libmpv.a" "$mpv_prefix/lib/libplacebo.a" "$root/dist/MPV/"
cp "$mpv_prefix/build-receipt.json" "$root/dist/MPV/build-receipt.json"
rsync -a "$mpv_prefix/include/mpv/" "$root/dist/MPV/include/mpv/"
if [[ -f "$root/Package.resolved" ]]; then cp "$root/Package.resolved" "$work/"; fi
rsync -a --delete "$root/Sources/" "$work/Sources/"
cd "$work"
# The host resolves the package graph; link Apple SDK stubs, never host ELF libraries.
export PKG_CONFIG_PATH="$root/Resources/cross-pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
if [[ ${1:-} == --sign-dev ]]; then
    # Development-only device build: personal signing, no delivery gate, never copied into dist/Delivery.
    # PILI_FAST_BUILD: parallel, incremental -O compile (see Package.swift).
    PILI_FAST_BUILD=1 xtool dev build --configuration release --ipa --sign
    cp xtool/PiliNative.ipa "$root/dist/PiliNative-dev-signed.ipa"
elif [[ ${1:-} == --sign || ${1:-} == --sign-personal ]]; then
    signing_scope=full
    if [[ ${1:-} == --sign-personal ]]; then signing_scope=personal; fi
    xtool dev build --configuration release --ipa --sign
    cp xtool/PiliNative.ipa "$root/dist/PiliNative-signed.ipa"
elif [[ ${1:-} == --release || ${1:-} == --release-personal ]]; then
    signing_scope=full
    outfile=PiliNative-release-unsigned.ipa
    if [[ ${1:-} == --release-personal ]]; then signing_scope=personal; outfile=PiliNative-personal-unsigned.ipa; fi
    xtool dev build --configuration release --ipa
    cp xtool/PiliNative.ipa "$root/dist/$outfile"
else
    xtool dev build --ipa
    cp xtool/PiliNative.ipa "$root/dist/PiliNative.ipa"
fi
