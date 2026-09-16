# Zig port validation

The native implementation uses Zig 0.15.2. The nine installed command names are
native executables sharing the modules in `native/`. libpng 1.6.58 and zlib 1.3.2
are pinned by content hash and linked statically. Installers build the native
commands without pip, virtual environments, or a Python runtime.

## Migration gate

The Python implementation and its old behavioral tests are retained temporarily
as a reference. Removing them is gated on native behavioral coverage and native
Linux/macOS/Windows CI, not on successful cross-compilation alone. This branch
must not be described as a completed language replacement while that gate is
open.

| Behavior | Native verification |
| --- | --- |
| Exact SSH selectors, PTY requirements, authenticated shell identity | `routing.zig`, native command and PTY integration |
| Restricted agent commands, Unicode, request limits, response IDs, PNG observations | `agent.zig`, `cli.zig`, native JSON/SSH integration |
| Fixed SSH/tmux argv and remote timeout | native integration tests, `process.zig` |
| Owned RGB buffers, filtered resize, fingerprints, allocation failures | `frame.zig`, `render.zig` |
| ANSI full/delta/static output, fallbacks, title restoration | `render.zig`, native PTY integration |
| Kitty probing, tmux passthrough, canvas/tile PNGs, pixel mapping, cursor | `kitty.zig`, native PTY integration |
| Fragmented UTF-8/escape/mouse input and control keys | `input.zig` |
| Latest frame slot, resize generation, output backpressure, detach/signals | `session.zig`, native PTY integration |
| Adaptive FPS/scale and capture target propagation | `capabilities.zig`, Xvfb integration |
| CoreGraphics RGB/logical-size conversion and permission failures | native C API fixtures; live Mac capture/permission check |
| X11 FFmpeg/MIT-SHM/XGetImage and XTest pointer/release | real Xvfb integration for all three paths |
| GNOME monitor union, linked stream coordinates, session cleanup and resize | real GLib variants and mocked D-Bus transport on Linux |
| Other Wayland ydotool initialization, uppercase and Unicode argv | Linux native executable fixture |
| Subprocess deadlines, bounded output, ignored TERM, descendant cleanup | `process.zig` |
| Installer syntax and removed-option rejection | shell checks, PowerShell parser, installer tests |

Still requiring parity review before removing the reference: backend failure
messages and cleanup under all original fault-injection cases, and complete
command-specific parser/exit-code
compatibility. The old reference suite remains available to catch regressions
in those contracts while the native tests are expanded.

## Live versus automated evidence

Local evidence is retained in `artifacts/zig-port/`:

- macOS native Debug tests, ReleaseSafe commands, and native command/PTY tests;
- real CoreGraphics capture and accessibility permission check, 2304×1296;
- Linux AArch64 executables running in a Debian container with Xvfb, using
  FFmpeg, MIT-SHM, and XGetImage, plus XTest input readback;
- Windows x86-64 ReleaseSafe cross-compilation and PowerShell syntax parsing.

Live GNOME/PipeWire, KDE/wlroots, and Windows interactive-desktop validation has
not been performed. Windows cross-compilation is not a Windows runtime test.
No privileged host installers have been run and the host SSH configuration has
not been changed. CI is configured for native Linux, macOS, and Windows builds;
its results must be recorded separately when run.

## Benchmark

`tools/compare-renderers.py` records the deterministic fixture definition,
environment, warmups, all raw samples, and mean timings under
`artifacts/zig-port/benchmark`. The initial matched static-render workload was
slower in Zig than Python/Pillow. It excludes capture, SSH, and terminal output
and does not establish an end-to-end performance result.
