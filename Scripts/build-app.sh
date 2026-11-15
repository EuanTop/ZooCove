#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
destination="${ZOOCOVE_OUTPUT_DIR:-${NOTCHZOO_OUTPUT_DIR:-${THREADISLAND_OUTPUT_DIR:-$PWD/dist}}}"
architecture="${ZOOCOVE_ARCH:-${NOTCHZOO_ARCH:-${THREADISLAND_ARCH:-$(uname -m)}}}"
identity="${ZOOCOVE_DEVELOPER_ID-${NOTCHZOO_DEVELOPER_ID-${THREADISLAND_DEVELOPER_ID:-}}}"
case "$architecture" in
    universal) flags=(--arch arm64 --arch x86_64) ;;
    arm64|x86_64) flags=(--arch "$architecture") ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac

swift build --configuration release "${flags[@]}"
binary_dir=$(swift build --configuration release "${flags[@]}" --show-bin-path)
mkdir -p "$destination"
stage=$(mktemp -d "$destination/.zoocove-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
build="$stage/ZooCove.app"
app="$destination/ZooCove.app"
mkdir -p "$build/Contents/MacOS" "$build/Contents/Resources" "$stage/AppIcon.iconset"

install -m 755 "$binary_dir/ZooCove" "$build/Contents/MacOS/ZooCove"
# Swift's debug map contains absolute paths to the developer's build machine.
xcrun strip -S "$build/Contents/MacOS/ZooCove"
install -m 644 Resources/Info.plist "$build/Contents/Info.plist"
install -m 644 LICENSE "$build/Contents/Resources/LICENSE"
swift Scripts/PrepareCompanions.swift Design/animal-doodles-16.png \
    "$build/Contents/Resources/Companions" "$stage/art.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/art.png" --out "$stage/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$stage/art.png" --out "$stage/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$build/Contents/Resources/AppIcon.icns" "$stage/AppIcon.iconset"

if [[ -n "$identity" ]]; then
    codesign --force --options runtime --timestamp --sign "$identity" "$build"
else
    codesign --force --sign - "$build"
fi
codesign --verify --strict --deep "$build"

if [[ -e "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$build" "$app"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
    exit 1
fi
printf '%s\n' "$app"
