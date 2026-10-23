#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${VERSION:-dev}
case "$version" in *[!a-zA-Z0-9._+-]*|'') printf 'Invalid version\n' >&2; exit 1 ;; esac
platform=$(go env GOOS)
arch=$(go env GOARCH)
case "$platform-$arch" in linux-amd64|linux-arm64|darwin-amd64|darwin-arm64) ;; *) printf 'Unsupported build target\n' >&2; exit 1 ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/keyboard-controller-package.XXXXXXXX")
trap 'rm -rf "$work"' 0
if [ "$platform" = linux ]; then cgo=0; else cgo=1; fi
(cd "$root/portable" && CGO_ENABLED=$cgo go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$work/keyboard-controller" .)
if [ "$platform" = darwin ]; then
    codesign --force --sign - --identifier site.iiinno.keyboard-controller "$work/keyboard-controller"
    codesign --verify --strict "$work/keyboard-controller"
fi
cp "$root/LICENSE" "$root/README.md" "$work/"
cp "$(go env GOROOT)/LICENSE" "$work/GO-LICENSE.txt"
mkdir -p "$root/dist"
archive="keyboard-controller-$platform-$arch.tar.gz"
tar -czf "$root/dist/$archive" -C "$work" keyboard-controller LICENSE README.md GO-LICENSE.txt
(cd "$root/dist" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$archive"; else shasum -a 256 "$archive"; fi) > "$root/dist/$archive.sha256"
printf 'PACKAGE=%s\n' "$root/dist/$archive"
