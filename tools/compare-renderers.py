"""Matching static RGB workload. Requires an external Python baseline checkout and Pillow."""
import argparse
import hashlib
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--reference-root", type=Path, required=True)
parser.add_argument("--native-bin", type=Path, default=Path("zig-out/bin/sshdesk-bench"))
parser.add_argument("--output", type=Path, default=Path("artifacts/zig-port/benchmark"))
args = parser.parse_args()
sys.path.insert(0, str(args.reference_root.resolve()))
from PIL import Image, ImageDraw
from PIL import __version__ as pillow_version
from sshdesk.capture.base import Frame

from sshdesk.render import (
    ColorMode,
    TerminalCapabilities,
    TerminalRenderer,
    TerminalWriter,
)

args.output.mkdir(parents=True, exist_ok=True)
image = Image.new("RGB", (1920, 1080), (18, 22, 30))
draw = ImageDraw.Draw(image)
for y in range(0, 1080, 40):
    for x in range(0, 1920, 64):
        draw.rectangle((x, y, x + 48, y + 24), fill=(x % 256, y % 256, (x + y) % 256))
fixture = args.output / "fixture.rgb"
fixture.write_bytes(image.tobytes())
renderer = TerminalRenderer()
writer = TerminalWriter(TerminalCapabilities("benchmark", ColorMode.ANSI256, True, True, True))
source = Frame(image, 0)
previous = None
samples = []
encoded_bytes = 0
for iteration in range(110):
    started = time.perf_counter_ns()
    current = renderer.render(source, 100, 30)
    update = renderer.diff(previous, current)
    encoded = writer.update(update)
    previous = current
    if iteration >= 10:
        samples.append(time.perf_counter_ns() - started)
        encoded_bytes += len(encoded)
reference = {"implementation": "python", "iterations": 100, "warmup": 10, "columns": 100, "rows": 30,
             "mean_ms": sum(samples) / len(samples) / 1e6, "encoded_bytes": encoded_bytes, "samples_ns": samples}
(args.output / "python.json").write_text(json.dumps(reference, indent=2) + "\n")
native = subprocess.run([str(args.native_bin.resolve()), "--fixture", str(fixture), "--iterations", "100",
                         "--columns", "100", "--rows", "30", "--color", "256"],
                        check=True, capture_output=True, text=True)
(args.output / "zig.json").write_text(native.stdout)
metadata = {"platform": platform.platform(), "python": sys.version, "pillow": pillow_version,
            "reference_commit": "3a6e421de5101973852e8735a202dcc1a5c6288a", "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
            "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
            "native_executable_sha256": hashlib.sha256(args.native_bin.read_bytes()).hexdigest(),
            "conditions": "ReleaseSafe native executable; sequential implementations; run with builds stopped",
            "workload": "1920x1080 static RGB; 100x30 ANSI256; resize, render, diff, encode; 10 warmups + 100 measured; no terminal I/O or capture"}
(args.output / "method.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps({"python_mean_ms": reference["mean_ms"], "zig_mean_ms": json.loads(native.stdout)["mean_ms"]}))
