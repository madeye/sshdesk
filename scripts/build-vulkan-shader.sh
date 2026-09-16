#!/bin/sh
# Regenerate with glslang 12.0.0 (Debian bookworm glslang-tools).
# Normal builds embed the checked-in SPIR-V and need no shader compiler.
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
    '') destination=native/gpu/resize.spv ;;
    --check) destination=$(mktemp); trap 'rm -f "$destination"' EXIT HUP INT TERM ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
glslangValidator --version | grep -q 'Glslang Version: .*12\.0\.0' || {
    echo 'Shader regeneration requires glslang 12.0.0 (Debian bookworm).' >&2
    exit 1
}
glslangValidator -V --target-env vulkan1.0 native/gpu/resize.comp -o "$destination"
spirv-val --target-env vulkan1.0 "$destination"
if [ "${1:-}" = --check ]; then cmp "$destination" native/gpu/resize.spv; fi
