# Third-party software

## Interception

This project uses the Interception API by Francisco Lopes.

- Project: https://github.com/oblitum/Interception
- Copyright: Francisco Lopes
- License: see the upstream repository and its `licenses` directory

Interception is separately licensed and is not covered by this repository's MIT License.

This repository intentionally does not distribute `interception.dll`, the driver binaries, or `install-interception.exe`. Download them from the upstream Interception project and review its license terms before use. The upstream project describes different terms for non-commercial and commercial use.

## AutoHotkey

- Project: https://github.com/AutoHotkey/AutoHotkey
- The Windows installer downloads the official AutoHotkey archive and retains its included license files. The interpreter is not committed to this repository or bundled in its Windows source package. Review the upstream license before use or redistribution.

## Go standard library

- Project: https://go.dev/
- Native Linux/macOS executables contain Go runtime and standard-library code. Their packages include the toolchain's LICENSE as GO-LICENSE.txt. No third-party Go modules are used.

## OS APIs

Linux uses the kernel evdev interface. macOS dynamically links the system IOKit and CoreFoundation frameworks. No Apple frameworks or custom Linux/macOS drivers are redistributed.
