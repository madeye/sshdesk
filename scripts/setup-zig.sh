#!/bin/sh
# Print the directory containing a checksum-verified Zig 0.15.2 executable.
set -eu
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = 0.15.2 ]; then
    dirname "$(command -v zig)"
    exit 0
fi
root="${1:?usage: setup-zig.sh TOOLCHAIN_DIRECTORY}"
case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; *) echo 'Zig bootstrap supports aarch64 and x86_64' >&2; exit 1 ;; esac
case "$(uname -s)" in Darwin) platform=macos ;; Linux) platform=linux ;; *) echo 'Use the PowerShell installer on Windows' >&2; exit 1 ;; esac
case "${arch}-${platform}" in
    aarch64-macos) checksum=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
    x86_64-macos) checksum=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
    aarch64-linux) checksum=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f ;;
    x86_64-linux) checksum=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
esac
mkdir -p "${root}"
root="$(CDPATH= cd -- "${root}" && pwd)"
name="zig-${arch}-${platform}-0.15.2"
archive="${root}/${name}.tar.xz"
if [ ! -x "${root}/${name}/zig" ]; then
    curl -fsSL "https://ziglang.org/download/0.15.2/${name}.tar.xz" -o "${archive}"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\n' "${checksum}" "${archive}" | sha256sum -c - >&2
    else
        printf '%s  %s\n' "${checksum}" "${archive}" | shasum -a 256 -c - >&2
    fi
    tar -xJf "${archive}" -C "${root}"
fi
[ "$("${root}/${name}/zig" version)" = 0.15.2 ] || exit 1
printf '%s\n' "${root}/${name}"
