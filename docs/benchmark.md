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
