#!/bin/sh
# Zig 0.15.2 predates the macOS 27 SDK's arm64e-only linker stubs.
# Select an already-installed compatible SDK without changing xcode-select.
set -eu
if [ "$(uname -s)" != Darwin ]; then exec "$@"; fi
sdk="${SSHDESK_MACOS_SDK-}"
if [ -z "${sdk}" ]; then
    current="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
    if sed -n '1,/^install-name/p' "${current}/usr/lib/libSystem.tbd" | grep -q 'arm64-macos'; then exec "$@"; fi
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
        if [ -f "${candidate}/usr/lib/libSystem.tbd" ] && sed -n '1,/^install-name/p' "${candidate}/usr/lib/libSystem.tbd" | grep -q 'arm64-macos'; then sdk="${candidate}"; fi
    done
fi
[ -n "${sdk}" ] || { echo 'Set SSHDESK_MACOS_SDK to an installed SDK compatible with Zig 0.15.2' >&2; exit 1; }
shim="$(mktemp -d "${TMPDIR:-/tmp}/sshdesk-sdk.XXXXXX")"
trap 'unlink "${shim}/xcrun"; rmdir "${shim}"' EXIT HUP INT TERM
cat > "${shim}/xcrun" <<'SHIM'
#!/bin/sh
if [ "$*" = '--sdk macosx --show-sdk-path' ]; then printf '%s\n' "${SSHDESK_MACOS_SDK}"; else exec /usr/bin/xcrun "$@"; fi
SHIM
chmod +x "${shim}/xcrun"
export SSHDESK_MACOS_SDK="${sdk}"
PATH="${shim}:${PATH}" "$@"
