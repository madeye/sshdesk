# Vulkan validation

Local validation uses the Linux ARM64 ReleaseSafe test executable in a Debian
bookworm container on Apple M4. Mesa lavapipe is a **software Vulkan driver**;
these logs are correctness/validation evidence, not physical GPU benchmarks.
The shader was generated and reproduced with glslang 12.0.0 and validated with
SPIRV-Tools 2023.1 for Vulkan 1.0. See `tools/Dockerfile.validation` and
`scripts/test-vulkan.sh` to reproduce the test environment.

The tests assert successful GPU API dispatch for both filter passes and compare
all pixels against the original scalar resizer. They also exercise buffer
resizing, concurrent calls, destruction/recreation, and SIMD fallback.
`VK_LAYER_KHRONOS_validation` is enabled, and the runner fails on Vulkan API
validation errors in addition to test failures.

Physical Linux/Windows GPUs and live desktop sessions on those hosts were not
available locally. Native Windows build and synthetic integration checks run
in GitHub Actions; they do not imply hardware Vulkan validation.
