"""Black-box native executable contracts; no Python is used by SSHDESK itself."""
from __future__ import annotations

import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(os.environ.get("SSHDESK_NATIVE_BIN", "zig-out/bin")).resolve()
SUFFIX = ".exe" if os.name == "nt" else ""
COMMANDS = (
    "sshdesk", "sshdesk-local", "sshdesk-server", "sshdesk-bench", "sshdesk-agent",
    "sshdesk-agent-ssh", "sshdesk-forced-command", "sshdesk-split", "sshdesk-remote",
)


def executable(name: str) -> str:
    return str(BIN / (name + SUFFIX))


@unittest.skipUnless((BIN / ("sshdesk" + SUFFIX)).is_file(), "build native executables first")
class NativeContracts(unittest.TestCase):
    def command(self, name: str, *args: str, **kwargs: object) -> subprocess.CompletedProcess:
        return subprocess.run([executable(name), *args], capture_output=True, timeout=10, check=False, **kwargs)

    def test_nine_native_commands_and_help(self) -> None:
        for name in COMMANDS:
            self.assertTrue(Path(executable(name)).is_file(), name)
            if name not in {"sshdesk-agent-ssh", "sshdesk-forced-command"}:
                result = self.command(name, "--help")
                self.assertEqual(result.returncode, 0, (name, result.stderr))

    def test_synthetic_check_and_color_fallbacks(self) -> None:
        check = self.command("sshdesk-server", "--capture", "synthetic", "--no-input", "--check")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn(b"1280x720", check.stdout)
        for mode, marker in (("truecolor", b"38;2;"), ("256", b"38;5;"), ("16", b"\x1b[30;")):
            result = self.command("sshdesk-local", "--capture", "synthetic", "--once",
                                  "--columns", "20", "--rows", "10", "--color", mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(marker, result.stdout)
            self.assertIn("▀".encode(), result.stdout)
        ascii_result = self.command("sshdesk-local", "--capture", "synthetic", "--ascii", "--once")
        self.assertNotIn("▀".encode(), ascii_result.stdout)

    def test_non_pty_and_exact_forced_command_allowlist(self) -> None:
        for command in ("", "shell", "sshdesk-shell", "desktop", "sshdesk", "sshdesk-server"):
            result = self.command("sshdesk-forced-command", env={**os.environ, "SSH_ORIGINAL_COMMAND": command})
            self.assertEqual(result.returncode, 1, (command, result.stderr))
            self.assertIn(b"PtyRequired", result.stderr)
        for command in ("id", "shell -c id", "shell;id", "desktop extra", "sshdesk-agentx info"):
            result = self.command("sshdesk-forced-command", env={**os.environ, "SSH_ORIGINAL_COMMAND": command})
            self.assertEqual(result.returncode, 126, (command, result.stderr))
        for command in ("sshdesk-agent screenshot --output /tmp/no", "sshdesk-agent observe --output=/tmp/no", "'bad"):
            self.assertEqual(self.command("sshdesk-agent-ssh", command).returncode, 2)

    def test_bounded_json_session_recovers_and_quits(self) -> None:
        payload = b'{bad}\n[]\n' + b'x' * 100000 + b'\n' + (
            '{"id":"世界","action":"wait","seconds":0}\n'
            '{"id":5,"action":"quit"}\n{"id":6,"action":"info"}\n'
        ).encode()
        result = self.command("sshdesk-agent", "session", input=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 5)
        self.assertFalse(responses[0]["ok"])
        self.assertEqual(responses[2], {"ok": False, "error": "request is too large"})
        self.assertEqual(responses[3], {"id": "世界", "ok": True})
        self.assertTrue(responses[4]["quit"])

    def test_invalid_options_are_rejected_before_capture(self) -> None:
        for args in (("--tailscale",), ("--no-tailscale",), ("--max-fps", "invalid"), ("--capture", "invalid")):
            self.assertEqual(self.command("sshdesk-server", *args).returncode, 2)
        for args in (("--max-fps", "nan"), ("--scale", "2")):
            self.assertEqual(self.command("sshdesk-server", *args).returncode, 1)
        self.assertEqual(self.command("sshdesk-agent", "info", "--output", "x").returncode, 2)
        self.assertNotEqual(self.command("sshdesk-remote", "-oProxyCommand=id", "info").returncode, 0)

    @unittest.skipUnless(os.name == "posix", "executable shim requires POSIX")
    def test_remote_fixed_argv_unicode_timeout_and_response(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shim = root / "ssh"
            shim.write_text(
                "#!/usr/bin/env python3\nimport json,os,sys,time\n"
                "from pathlib import Path\n"
                "data=sys.stdin.read()\n"
                "Path(os.environ['RECORD']).write_text(json.dumps([sys.argv[1:],json.loads(data)]))\n"
                "if os.environ.get('STALL'): time.sleep(5)\n"
                "print(json.dumps({'id':1,'ok':True,'platform':'fixture','width':320}))\n"
            )
            shim.chmod(0o755)
            environment = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                           "RECORD": str(root / "request.json")}
            result = self.command("sshdesk-remote", "alice@example.com", "type", "世界; $(id)", env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            argv, request = json.loads((root / "request.json").read_text())
            self.assertEqual(argv, ["alice@example.com", "sshdesk-agent", "session"])
            self.assertEqual(request["text"], "世界; $(id)")
            info = self.command("sshdesk-remote", "alice@example.com", "info", env=environment)
            self.assertEqual(json.loads(info.stdout), {"platform": "fixture", "width": 320})
            started = time.monotonic()
            timed = self.command("sshdesk-remote", "alice@example.com", "--timeout", "0.1", "info",
                                 env={**environment, "STALL": "1"})
            self.assertNotEqual(timed.returncode, 0)
            self.assertIn(b"TimedOut", timed.stderr)
            self.assertLess(time.monotonic() - started, 2)

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("xvfb-run"), "Linux Xvfb failure fixture")
    def test_ffmpeg_failure_retains_bounded_diagnostic_and_reaps_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shim = root / "ffmpeg"
            shim.write_text("#!/usr/bin/env python3\nimport sys\n"
                            "sys.stderr.write('x'*4096+'capturer error')\n"
                            "sys.stdout.buffer.write(b'partial')\n")
            shim.chmod(0o755)
            environment = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                           "SSHDESK_X11_CAPTURE": "ffmpeg"}
            result = subprocess.run(["xvfb-run", "-a", executable("sshdesk-server"),
                                     "--check", "--capture", "x11", "--no-input"],
                                    env=environment, capture_output=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 1, result.stderr)
            diagnostic = result.stderr + result.stdout
            self.assertIn(b"capturer error", diagnostic, (result.returncode, result.stdout, result.stderr))
            self.assertIn(b"FFmpegStreamEnded", diagnostic)
            self.assertLess(len(diagnostic), 2300)

    @unittest.skipUnless(os.name == "posix", "POSIX signal semantics")
    def test_agent_interrupt_restores_session_resources(self) -> None:
        process = subprocess.Popen([executable("sshdesk-agent"), "session"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b'{"action":"wait","seconds":10}\n')
            process.stdin.flush()
            time.sleep(0.1)
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 130, (stdout, stderr))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    @unittest.skipUnless(os.name == "posix", "executable shim requires POSIX")
    def test_tmux_split_uses_fixed_argv(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shim = root / "tmux"
            shim.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                            "with open(os.environ['RECORD'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n")
            shim.chmod(0o755)
            environment = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                           "RECORD": str(root / "calls.jsonl"), "TMUX": "fixture", "TMUX_PANE": "%7"}
            result = self.command("sshdesk-split", "alice@example.com", "--direction", "left", "--size", "40", env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            self.assertEqual(calls[-1], ["split-window", "-h", "-b", "-p", "40", "-t", "%7", "--", "ssh", "alice@example.com"])
            self.assertNotEqual(self.command("sshdesk-split", "host;id", env=environment).returncode, 0)

    @unittest.skipUnless(sys.platform == "linux", "Linux Wayland backend fixture")
    def test_wayland_native_agent_argv_and_uppercase_modifiers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shim = root / "ydotool"
            shim.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                            "with open(os.environ['RECORD'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n")
            shim.chmod(0o755)
            environment = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                           "RECORD": str(root / "calls.jsonl"), "WAYLAND_DISPLAY": "fixture",
                           "XDG_SESSION_TYPE": "wayland", "XDG_CURRENT_DESKTOP": "sway"}
            requests = [{"action": "type", "text": "A世"}, {"action": "move", "x": 10, "y": 20}, {"action": "quit"}]
            payload = "".join(json.dumps(r) + "\n" for r in requests).encode()
            result = self.command("sshdesk-agent", "session", env=environment, input=payload)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(all(json.loads(line)["ok"] for line in result.stdout.splitlines()))
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            self.assertEqual(calls[0], ["debug"])
            self.assertEqual(calls[1], ["key", "--key-delay", "0", "42:1", "30:1", "30:0", "42:0"])
            self.assertEqual(calls[2], ["type", "--key-delay", "0", "--", "世"])
            self.assertEqual(calls[3], ["mousemove", "--absolute", "10", "20"])


@unittest.skipUnless(os.name == "posix" and (BIN / "sshdesk").is_file(), "native POSIX PTY test")
class NativePtyContracts(unittest.TestCase):
    def session(self, *, kitty: bool = False, terminate: bool = False, backpressure: bool = False,
                shell: bool = False) -> bytes:
        import fcntl
        import pty
        import struct
        import termios

        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 800, 480))
        environment = {**os.environ, "TERM": "xterm-256color", "SSHDESK_RENDER": "auto" if kitty else "ansi",
                       "RUN_AS": "this-account-must-never-run-the-shell"}
        args = [executable("sshdesk-server"), "--capture", "synthetic", "--no-input"]
        if shell:
            args = [executable("sshdesk-forced-command")]
            environment["SSH_ORIGINAL_COMMAND"] = "shell"
        process = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave, env=environment,
                                   start_new_session=True)
        output = bytearray()
        try:
            deadline = time.monotonic() + 8
            replied = False
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.05)
                if ready:
                    output.extend(os.read(master, 65536))
                if kitty and b"i=31" in output and not replied:
                    os.write(master, b"\x1b_Gi=31;OK\x1b\\\x1b[4;480;800t\x1b[6;20;10t")
                    replied = True
                if shell:
                    os.write(master, b"id -un; exit\n")
                    break
                if (b"f=100" if kitty else "▀".encode()) in output:
                    break
                if process.poll() is not None:
                    self.fail(f"session exited early: {output!r}")
            else:
                self.fail(f"session did not render: {output[-1000:]!r}")
            if not shell:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 1000, 600))
                if backpressure:
                    time.sleep(0.3)
                if terminate:
                    process.send_signal(signal.SIGTERM)
                else:
                    os.write(master, b"\x1d\x1d")
            deadline = time.monotonic() + 5
            while process.poll() is None and time.monotonic() < deadline:
                if backpressure:
                    time.sleep(0.02)
                else:
                    ready, _, _ = select.select([master], [], [], 0.05)
                    if ready:
                        output.extend(os.read(master, 65536))
            self.assertIsNotNone(process.poll(), "input failed to stop the session under backpressure")
            self.assertEqual(process.returncode, 130 if terminate else 0, output[-1000:])
            if not shell:
                self.assertEqual(termios.tcgetattr(slave), original, "terminal modes not restored")
            if not shell and not backpressure:
                self.assertIn(b"\x1b[?1049l", output)
            return bytes(output)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            os.close(master)
            os.close(slave)

    def test_detach_resize_and_restore(self) -> None:
        self.session()

    def test_signal_cleanup(self) -> None:
        self.session(terminate=True)

    def test_kitty_probe_and_native_pixels(self) -> None:
        self.session(kitty=True)

    def test_input_stays_responsive_under_output_backpressure(self) -> None:
        self.session(backpressure=True)

    def test_shell_retains_authenticated_identity(self) -> None:
        import pwd
        output = self.session(shell=True)
        self.assertIn(pwd.getpwuid(os.getuid()).pw_name.encode(), output)


@unittest.skipUnless(os.name == "nt" and (BIN / "sshdesk.exe").is_file(), "native Windows ConPTY test")
class NativeWindowsPtyContracts(unittest.TestCase):
    def test_synthetic_session_resize_detach_and_utf8(self) -> None:
        from unittest.mock import patch

        from tests.windows_pty import Console

        with patch.dict(os.environ, {"TERM": "xterm-256color", "SSHDESK_RENDER": "ansi"}):
            console = Console([executable("sshdesk-server"), "--capture", "synthetic", "--no-input"])
        try:
            console.wait_for(b"SSHDESK")
            console.wait_for("▀".encode())
            console.resize()
            console.write(b"\x13")
            console.wait_for(b"capture FPS")
            console.write(b"\x1d\x1d")
            self.assertEqual(console.wait(), 0, bytes(console.output[-2000:]))
        finally:
            console.close()


if __name__ == "__main__":
    unittest.main()
