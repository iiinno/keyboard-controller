#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/keyboard-controller-install-test.XXXXXXXX")
trap 'rm -rf "$work"' 0
sh "$root/install.sh" --from "$root/dist" --prefix "$work/with spaces" --no-setup
"$work/with spaces/bin/keyboard-controller" version
"$work/with spaces/bin/keyboard-controller" devices --json
# A modified archive must be rejected without replacing the installed program.
mkdir "$work/bad"
cp "$root"/dist/*.tar.gz* "$work/bad/"
for archive in "$work"/bad/*.tar.gz; do printf 'tampered' >> "$archive"; done
before=$(cksum "$work/with spaces/bin/keyboard-controller")
if sh "$root/install.sh" --from "$work/bad" --prefix "$work/with spaces" --no-setup; then
    printf 'Tampered package was accepted\n' >&2; exit 1
fi
after=$(cksum "$work/with spaces/bin/keyboard-controller")
[ "$before" = "$after" ] || { printf 'Installed program changed after failed verification\n' >&2; exit 1; }
printf 'PASS: native package, paths with spaces, and checksum rejection\n'
