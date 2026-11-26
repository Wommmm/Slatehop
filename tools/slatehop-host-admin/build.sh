#!/bin/bash
set -euo pipefail
umask 077

if [[ $(/usr/bin/uname -s) != Darwin ]]; then
    printf '%s\n' 'SlateHop Host Admin build requires macOS with the system Swift toolchain.' >&2
    exit 69
fi

host_sha=
if (( $# != 0 )); then
    if [[ $# != 2 || "$1" != --trusted-host-sha256 || ! "$2" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        printf '%s\n' 'Usage: build.sh [--trusted-host-sha256 SHA256]' >&2
        exit 64
    fi
    host_sha=$(printf '%s' "$2" | LC_ALL=C /usr/bin/tr A-F a-f)
fi

source_dir=$(cd -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd -P)
arch=$(/usr/bin/uname -m)
case "$arch" in
    arm64|x86_64) ;;
    *) printf 'Unsupported macOS build architecture: %s\n' "$arch" >&2; exit 69 ;;
esac

sources=(HostAdminAdapter.swift HostAdminApp.swift HostAdminView.swift HostAdminDemo.swift)
for index in "${!sources[@]}"; do
    sources[$index]="$source_dir/${sources[$index]}"
    if [[ ! -f "${sources[$index]}" ]]; then
        printf 'Missing integrated candidate input: %s\n' "${sources[$index]}" >&2
        exit 66
    fi
done
/usr/bin/xcrun --sdk macosx --find swiftc >/dev/null

output=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/slatehop-host-admin.XXXXXXXX")
build_complete=0
trap 'if (( build_complete == 0 )); then /bin/rm -rf -- "$output"; fi' EXIT
app="$output/SlateHop Host Admin.app"
/bin/mkdir -p "$app/Contents/MacOS"
/bin/cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
if [[ -n "$host_sha" ]]; then
    /usr/bin/plutil -replace SlateHopTrustedHostSHA256 -string "$host_sha" "$app/Contents/Info.plist"
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist" >&2
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O \
    -target "${arch}-apple-macosx13.0" "${sources[@]}" \
    -o "$app/Contents/MacOS/SlateHopHostAdmin"
/usr/bin/codesign --sign - "$app"
/usr/bin/codesign --verify --strict "$app"

build_complete=1
printf '%s\n' "$app"
