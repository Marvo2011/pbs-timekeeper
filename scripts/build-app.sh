#!/bin/bash
# Builds "build/PBS Timekeeper.app" and a zip of it.
#
# The app bundles proxmox-backup-client: by default the release of the macOS port named in
# CLIENT_VERSION is downloaded (and its checksum verified), PBS_CLIENT=/path/to/binary uses
# a local build instead. The app is signed ad hoc, set CODESIGN_IDENTITY to sign it with a
# Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(cat VERSION)
client_version=$(cat CLIENT_VERSION)
out=build
app="$out/PBS Timekeeper.app"
client_repo="Marvo2011/proxmox-backup-client-mac"

client="${PBS_CLIENT:-}"
if [[ -z "$client" ]]; then
    name="proxmox-backup-client-${client_version}-macos-arm64"
    url="https://github.com/${client_repo}/releases/download/v${client_version}/${name}.tar.gz"
    rm -rf "$out/client"
    mkdir -p "$out/client"
    curl -fsSL -o "$out/client/$name.tar.gz" "$url"
    curl -fsSL -o "$out/client/$name.tar.gz.sha256" "$url.sha256"
    (cd "$out/client" && shasum -a 256 -c "$name.tar.gz.sha256")
    tar -C "$out/client" -xzf "$out/client/$name.tar.gz"
    client="$out/client/$name/proxmox-backup-client"
fi

swift build -c release --arch arm64 --product PBSTimekeeper
bin="$(swift build -c release --arch arm64 --show-bin-path)/PBSTimekeeper"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/PBSTimekeeper"
cp "$client" "$app/Contents/MacOS/proxmox-backup-client"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
sed -e "s/@VERSION@/${version}/g" -e "s/@CLIENT_VERSION@/${client_version}/g" \
    Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null

identity="${CODESIGN_IDENTITY:--}"
sign_options=()
if [[ "$identity" != "-" ]]; then
    sign_options=(--options runtime --timestamp)
fi
# the nested client first, then the app that seals it
codesign --force --sign "$identity" ${sign_options[@]+"${sign_options[@]}"} "$app/Contents/MacOS/proxmox-backup-client"
codesign --force --sign "$identity" ${sign_options[@]+"${sign_options[@]}"} "$app"
codesign --verify --deep --strict "$app"

zip="$out/PBS-Timekeeper-${version}-macos-arm64.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$app"
echo "$zip"
