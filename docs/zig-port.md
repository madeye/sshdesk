# Zig port validation

The native implementation uses Zig 0.15.2. The nine installed command names are
native executables sharing the modules in `native/`. libpng 1.6.58 and zlib 1.3.2
are pinned by content hash and linked statically. Installers build the native
commands without pip, virtual environments, or a Python runtime.

## Behavioral coverage

The Python implementation, packaging, and runtime dependencies have been removed.
The baseline remains available at commit
`3a6e421de5101973852e8735a202dcc1a5c6288a`; the
[test migration ledger](test-migration.md) records every original behavioral
case and its native replacement. The retained integration/installer harness
uses Python's standard library only and is not installed with SSHDESK.

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

## Live versus automated evidence

Local evidence is retained in `artifacts/zig-port/`:

- macOS native Debug tests, ReleaseSafe commands, and native command/PTY tests;
- real CoreGraphics capture and accessibility permission check, 2304×1296;
- Linux AArch64 executables running in a Debian container with Xvfb, using
  FFmpeg, MIT-SHM, and XGetImage, plus XTest input readback;
- Windows x86-64 native CI, including synthetic ConPTY rendering, resize, Unicode,
  detach, and PowerShell syntax parsing.

Live GNOME/PipeWire, KDE/wlroots, and Windows interactive-desktop validation has
not been performed. ConPTY tests validate terminal sessions, not GDI/SendInput
against a logged-in Windows desktop.
No privileged host installers have been run and the host SSH configuration has
not been changed. Native Linux, macOS, and Windows CI passed
[before reference removal](https://github.com/madeye/sshdesk/actions/runs/35057059884).
Final-tree runs are available in the [branch CI history](https://github.com/madeye/sshdesk/actions/workflows/test.yml?query=branch%3Afeature%2Fzig-port).

## Benchmark

`tools/compare-renderers.py` records the deterministic fixture definition,
environment, warmups, all raw samples, and mean timings under
`artifacts/zig-port/benchmark`. The initial matched static-render workload was
slower in Zig than Python/Pillow. It excludes capture, SSH, and terminal output
and does not establish an end-to-end performance result.
