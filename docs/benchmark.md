# Benchmark methodology

`sshdesk-bench` uses a deterministic 1920×1080 synthetic desktop, renders it to
the requested terminal size, computes cell deltas, and measures the exact ANSI
bytes SSHDESK would write to the SSH PTY. It does not include OpenSSH encryption
or network framing overhead.

Choose the same color mode as the deployed terminal when comparing runs:

```bash
sshdesk-bench --duration 60 --columns 100 --rows 30 --color 256
```

The input figure measures terminal escape parsing, not end-to-end X11 or network
latency. For repeatable results keep terminal dimensions, color mode, CPU
governor, compiler/build mode, SSH cipher, network path, and desktop workload fixed.

For a live session, press `Ctrl+S` to show captured FPS, displayed FPS, dropped
intermediate frames, capture, combined render/encode, and write timings, bandwidth, and terminal
geometry. A dropped intermediate frame is intentional latest-frame behavior and
means the client is receiving newer pixels instead of draining old work.

## Language-port comparison

`tools/compare-renderers.py` produces one deterministic RGB fixture and feeds
it to both the archived Python baseline and the native ReleaseSafe renderer.
Both use 1920×1080 RGB, 100×30 cells, ANSI256, ten warmups, and 100 measured
resize/render/diff/encode iterations. Capture, terminal I/O, and SSH are excluded.
The fixture generator, SHA-256, environment, and individual samples are retained
under `artifacts/zig-port/benchmark`. Recreate the fixture with:

```sh
mkdir -p /tmp/sshdesk-python-baseline
git archive 3a6e421de5101973852e8735a202dcc1a5c6288a src | tar -x -C /tmp/sshdesk-python-baseline
# In a separate benchmark environment with Pillow 12.3.0:
python3 tools/compare-renderers.py --reference-root /tmp/sshdesk-python-baseline/src
```

This static fixture comparison is not an end-to-end FPS result. Consult the raw
files for results; the initial Zig implementation was slower than Pillow on this
workload. Live workloads and unlike backend paths must be reported separately.

## Resizer optimization and Metal

The follow-up on Apple M4, macOS 27, Zig 0.15.2 ReleaseSafe retains five
alternating before/after runs per workload under
[`artifacts/resize-performance`](../artifacts/resize-performance). Each run
uses ten warmups and 100 measured frames from the same 1920×1080 RGB fixture.
The table reports the median of those run means, in milliseconds:

| Output cells (image pixels) | Before | Optimized CPU | Before | Metal |
| --- | ---: | ---: | ---: | ---: |
| 100×30 (100×56) | 5.60 | 4.16 | 5.47 | 0.923 |
| 640×180 (640×360) | 8.23 | 7.15 | 8.23 | 2.10 |

Each backend has its own paired baseline to expose run-to-run variation.
Metal is about 5.9× and 3.9× faster than the corresponding original Zig runs.
A separate rerun of the Python comparison measured 3.61 ms for Python/Pillow
and 1.02 ms for automatic Metal resizing. The earlier port results remain
unchanged in their original directory.

Metal first-frame times were 22–33 ms in these runs and include context/pipeline
initialization. They are recorded separately from steady-state samples. The OS
shader cache was not cleared; these are not guaranteed cold-cache startup times.
GPU timings include both passes, all copies, CPU rounding correction, and waits;
no capture, SSH, or terminal presentation is included. These are workload-specific
measurements, not an end-to-end desktop FPS claim.

To reproduce, build the baseline commit `fb58736` in a separate checkout with
`zig build -Doptimize=ReleaseSafe`, then compare its executable with this branch:

```sh
python3 tools/compare-native-resize.py \
  --before /path/to/baseline/zig-out/bin/sshdesk-bench \
  --after-backend metal --output /tmp/metal-comparison.json
# Repeat with --after-backend cpu, and/or --columns 640 --rows 180.
```

To validate actual GPU execution use
`SSHDESK_RESIZE=metal scripts/with-zig-sdk.sh zig build test`. GPU tests fail
if no Metal pass executes, while ordinary CI remains usable without a GPU.
