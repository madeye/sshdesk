"""Compare two ReleaseSafe executables, alternating order and retaining every sample."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--before-revision", help="Revision of the baseline executable, if known")
    parser.add_argument("--after", type=Path, default=Path("zig-out/bin/sshdesk-bench"))
    parser.add_argument("--fixture", type=Path, default=Path("artifacts/zig-port/benchmark/fixture.rgb"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--columns", type=int, default=100)
    parser.add_argument("--rows", type=int, default=30)
    parser.add_argument("--after-backend", choices=("cpu", "metal", "vulkan"), default="cpu")
    parser.add_argument("--rounds", type=int, default=5)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    binaries = {"before": args.before, "after": args.after}
    rounds = []
    for number in range(args.rounds):
        order = ["before", "after"] if number % 2 == 0 else ["after", "before"]
        result = {"order": order}
        for label in order:
            raw = subprocess.check_output([
                str(binaries[label].resolve()), "--fixture", str(args.fixture.resolve()),
                "--iterations", "100", "--columns", str(args.columns), "--rows", str(args.rows),
                "--color", "256",
            ], text=True, env={**os.environ, "SSHDESK_RESIZE": args.after_backend if label == "after" else "cpu"})
            result[label] = json.loads(raw)
            if label == "after" and result[label].get("resize_backend") != args.after_backend:
                raise RuntimeError(f"requested {args.after_backend} backend was not used")
        if result["before"]["encoded_bytes"] != result["after"]["encoded_bytes"]:
            raise RuntimeError("static-frame suppression changed")
        rounds.append(result)
    medians = {label: statistics.median(r[label]["mean_ms"] for r in rounds) for label in binaries}
    report = {
        "method": "1920x1080 static RGB, resize/render/diff/encode; 10 warmups then 100 samples per run; alternating order; no capture or terminal I/O; builds stopped",
        "platform": platform.platform(), "build_mode": "ReleaseSafe", "zig": "0.15.2",
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip() if platform.system() == "Darwin" else platform.processor(),
        "before_revision": args.before_revision,
        "fixture_sha256": digest(args.fixture),
        "binaries_sha256": {label: digest(path) for label, path in binaries.items()},
        "after_frame_source_sha256": digest(Path("native/frame.zig")),
        "after_backend": args.after_backend,
        "columns": args.columns, "rows": args.rows, "rounds": rounds,
        "median_run_mean_ms": medians, "speedup": medians["before"] / medians["after"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("median_run_mean_ms", "speedup")}))


if __name__ == "__main__":
    main()
