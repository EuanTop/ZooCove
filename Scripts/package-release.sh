#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-}"
export ZOOCOVE_DEVELOPER_ID="${ZOOCOVE_DEVELOPER_ID-${NOTCHZOO_DEVELOPER_ID-${THREADISLAND_DEVELOPER_ID:-}}}"
notary_profile="${ZOOCOVE_NOTARY_PROFILE-${NOTCHZOO_NOTARY_PROFILE-${THREADISLAND_NOTARY_PROFILE:-}}}"
case "$mode" in
    --local)
        suffix=-local
        export ZOOCOVE_DEVELOPER_ID=
        ;;
    --public)
        suffix=
        : "${ZOOCOVE_DEVELOPER_ID:?Set a Developer ID Application identity for public releases}"
        : "${notary_profile:?Set the name of a notarytool keychain profile}"
        if [[ "$ZOOCOVE_DEVELOPER_ID" != "Developer ID Application: "* ]]; then
            printf '%s\n' 'Public releases require a Developer ID Application identity.' >&2
            exit 2
        fi
        ;;
    *) printf '%s\n' 'Usage: Scripts/package-release.sh --local | --public' >&2; exit 2 ;;
esac

version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.zoocove-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/content"

# Public builds include both CPU architectures unless the maintainer requests a specific slice.
ZOOCOVE_OUTPUT_DIR="$stage/content" ZOOCOVE_ARCH="${ZOOCOVE_ARCH:-${NOTCHZOO_ARCH:-${THREADISLAND_ARCH:-universal}}}" Scripts/build-app.sh
ln -s /Applications "$stage/content/Applications"

filename="ZooCove-$version$suffix.dmg"
image="$stage/$filename"
hdiutil create -srcfolder "$stage/content" -volname "ZooCove" -fs HFS+ -format UDZO "$image"
hdiutil verify "$image"

if [[ "$mode" == --public ]]; then
    codesign --sign "$ZOOCOVE_DEVELOPER_ID" --timestamp "$image"
    xcrun notarytool submit "$image" --keychain-profile "$notary_profile" \
        --wait --output-format json > "$stage/notarization.json"
    if [[ "$(plutil -extract status raw "$stage/notarization.json")" != Accepted ]]; then
        cat "$stage/notarization.json" >&2
        exit 1
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi

(cd "$stage" && shasum -a 256 "$filename" > "$filename.sha256")
mv -f "$image" "$PWD/dist/$filename"
mv -f "$stage/$filename.sha256" "$PWD/dist/$filename.sha256"
printf '%s\n' "$PWD/dist/$filename" "$PWD/dist/$filename.sha256"
