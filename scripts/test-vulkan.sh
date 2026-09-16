#!/bin/sh
# Explicit software Vulkan validation; never treat this as GPU performance data.
set -eu
runner=${1:-zig-out/bin/sshdesk-tests}
found=false
for icd in /usr/share/vulkan/icd.d/lvp_icd*.json; do
    if [ -f "$icd" ]; then
        export VK_ICD_FILENAMES="$icd" VK_DRIVER_FILES="$icd"
        found=true
        break
    fi
done
if [ "$found" != true ]; then echo 'Mesa lavapipe ICD is required.' >&2; exit 1; fi
log=$(mktemp)
trap 'rm -f "$log"' EXIT HUP INT TERM
status=0
SSHDESK_RESIZE=vulkan VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation "$runner" >"$log" 2>&1 || status=$?
cat "$log"
[ "$status" -eq 0 ] || exit "$status"
# The Vulkan layer reports API errors without changing the process exit status.
if grep -E 'Validation Error|VUID-' "$log"; then exit 1; fi

# Isolated lavapipe must be opt-in, and a missing ICD must still render on CPU.
SSHDESK_NATIVE_BIN=$(dirname "$runner") SSHDESK_TEST_VULKAN_SOFTWARE=1 \
    python3 -m unittest \
    tests.test_native_integration.NativeContracts.test_software_vulkan_requires_explicit_selection \
    tests.test_native_integration.NativeContracts.test_missing_vulkan_driver_falls_back_to_identical_cpu_output -v
