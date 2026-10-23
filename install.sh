#!/bin/sh
set -eu

prefix=${KEYBOARD_CONTROLLER_PREFIX:-"$HOME/.local"}
source_dir=
setup=yes
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) [ "$#" -ge 2 ] || exit 2; prefix=$2; shift 2 ;;
        --from) [ "$#" -ge 2 ] || exit 2; source_dir=$2; shift 2 ;;
        --no-setup) setup=no; shift ;;
        --help) printf '%s\n' 'install.sh [--prefix DIR] [--from PACKAGE_DIR] [--no-setup]'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$prefix" ] || { printf 'Empty install prefix\n' >&2; exit 2; }
case $(uname -s) in Linux) platform=linux ;; Darwin) platform=darwin ;; *) printf 'Use install.ps1 on Windows.\n' >&2; exit 1 ;; esac
case $(uname -m) in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) printf 'Unsupported CPU architecture\n' >&2; exit 1 ;; esac
archive="keyboard-controller-$platform-$arch.tar.gz"
work=$(mktemp -d "${TMPDIR:-/tmp}/keyboard-controller-install.XXXXXXXX")
trap 'rm -rf "$work"' 0
trap 'exit 130' INT
trap 'exit 1' HUP TERM

if [ -n "$source_dir" ]; then
    cp "$source_dir/$archive" "$work/$archive"
    cp "$source_dir/$archive.sha256" "$work/$archive.sha256"
else
    base=https://github.com/iiinno/keyboard-controller/releases/latest/download
    for file in "$archive" "$archive.sha256"; do
        if ! curl --proto '=https' --tlsv1.2 -fsSL "$base/$file" -o "$work/$file"; then
            printf 'Download failed. A published release is required; CI packages can be installed with --from DIR.\n' >&2
            exit 1
        fi
    done
fi

read -r expected recorded extra < "$work/$archive.sha256"
[ -z "${extra:-}" ] && [ "$recorded" = "$archive" ] && [ "${#expected}" -eq 64 ] || { printf 'Invalid checksum manifest\n' >&2; exit 1; }
case "$expected" in *[!0-9a-fA-F]*) printf 'Invalid SHA-256\n' >&2; exit 1 ;; esac
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work/$archive" | cut -d ' ' -f 1)
else
    actual=$(shasum -a 256 "$work/$archive" | cut -d ' ' -f 1)
fi
[ "$actual" = "$expected" ] || { printf 'SHA-256 mismatch; nothing installed.\n' >&2; exit 1; }

# Extract only one verified regular file, never archive paths or links.
[ "$(tar -tzf "$work/$archive" | grep -c '^keyboard-controller$')" -eq 1 ] || { printf 'Invalid package layout\n' >&2; exit 1; }
case $(tar -tvzf "$work/$archive" keyboard-controller) in -*) ;; *) printf 'Executable must be a regular file\n' >&2; exit 1 ;; esac
mkdir "$work/unpack"
tar -xzf "$work/$archive" -C "$work/unpack" -- keyboard-controller
[ -f "$work/unpack/keyboard-controller" ] && [ ! -L "$work/unpack/keyboard-controller" ] || exit 1
chmod 755 "$work/unpack/keyboard-controller"
"$work/unpack/keyboard-controller" version
mkdir -p "$prefix/bin"
if [ -L "$prefix/bin/keyboard-controller" ] || [ -d "$prefix/bin/keyboard-controller" ]; then
    printf 'Install target is a link or directory; choose another --prefix.\n' >&2
    exit 1
fi
staged=$(mktemp "$prefix/bin/.keyboard-controller.XXXXXXXX")
if ! cp "$work/unpack/keyboard-controller" "$staged" || ! chmod 755 "$staged"; then rm -f "$staged"; exit 1; fi
mv -f "$staged" "$prefix/bin/keyboard-controller"
target="$prefix/bin/keyboard-controller"
printf 'Installed: %s\n' "$target"

if [ "$platform" = darwin ]; then config_dir="$HOME/Library/Application Support"; else config_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}; fi
if [ -e "$config_dir/keyboard-controller/config.json" ]; then
    printf 'Existing configuration kept.\n'
elif [ "$setup" = yes ]; then
    if [ -t 0 ]; then "$target" setup
    elif ( : < /dev/tty ) 2>/dev/null; then "$target" setup < /dev/tty
    else printf 'Run "%s" setup in a terminal to choose your keyboards.\n' "$target"; fi
fi
printf 'Next: "%s" permissions --apply\n' "$target"
if [ "$platform" = darwin ]; then
    printf 'Test: sudo "%s" test --config "%s/keyboard-controller/config.json"\n' "$target" "$config_dir"
    printf 'Start: sudo "%s" run --config "%s/keyboard-controller/config.json"\n' "$target" "$config_dir"
else
    printf 'Then: "%s" test\nStart: "%s" run\n' "$target" "$target"
fi
