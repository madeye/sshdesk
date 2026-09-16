from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "install.sh"
WINDOWS_INSTALLER = ROOT / "scripts" / "install.ps1"
CONFIGURE_SSHD = ROOT / "scripts" / "configure-sshd.sh"


@unittest.skipUnless(os.name == "posix" and shutil.which("sh"), "POSIX shell test")
class InstallerTests(unittest.TestCase):
    def test_bootstrap_has_valid_shell_syntax_and_help(self) -> None:
        subprocess.run(["sh", "-n", INSTALLER], check=True)
        subprocess.run(["sh", "-n", CONFIGURE_SSHD], check=True)
        result = subprocess.run(
            ["sh", INSTALLER, "--help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("--user USER", result.stdout)
        self.assertIn('Linux|Darwin)', INSTALLER.read_text())

    def test_removed_network_options_are_unknown(self) -> None:
        for option in ("--tailscale", "--no-tailscale"):
            result = subprocess.run(["sh", INSTALLER, option], capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown option", result.stderr)

    def test_wayland_dependencies_are_installed_and_checked_before_openssh(self) -> None:
        source = INSTALLER.read_text()
        self.assertIn('kde) executable="spectacle"', source)
        self.assertIn('wlroots) executable="grim"', source)
        self.assertIn('YDOTOOL_VERSION="1.0.4"', source)
        self.assertIn('YDOTOOL_SHA256="daa83507', source)
        self.assertIn('YDOTOOL_SOURCE_SHA256="ba075a43', source)
        self.assertIn("gnome_streaming_is_ready", source)
        self.assertIn("gstreamer1.0-pipewire", source)
        self.assertIn("pipewire-gstreamer", source)
        self.assertIn("DeviceAllow=/dev/uinput rw", source)
        self.assertIn("/etc/modules-load.d/sshdesk-uinput.conf", source)
        self.assertIn("--socket-perm=0600", source)
        self.assertIn('"${ydotool_cli}" debug', source)
        dependency_install = source.rindex("    install_linux_desktop_dependencies\n")
        application_install = source.rindex('    "${project_directory}/scripts/install-server.sh"')
        desktop_check = source.rindex('say "Verifying graphical capture and input access..."')
        openssh_config = source.rindex('sshd_main="/etc/ssh/sshd_config"')
        self.assertLess(dependency_install, application_install)
        self.assertLess(application_install, desktop_check)
        self.assertLess(desktop_check, openssh_config)


class WindowsInstallerTests(unittest.TestCase):
    def test_windows_bootstrap_downloads_and_configures(self) -> None:
        source = WINDOWS_INSTALLER.read_text()
        self.assertIn('Get-WindowsCapability -Online -Name "OpenSSH.Server', source)
        self.assertIn('"https://github.com/$Repository/archive/refs/heads/$Branch.zip"', source)
        self.assertIn('Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP"', source)
        self.assertIn("[CmdletBinding()]", source)


class NativeBuildTests(unittest.TestCase):
    def test_pinned_native_build_and_dependency_licenses(self) -> None:
        build = (ROOT / "build.zig").read_text()
        manifest = (ROOT / "build.zig.zon").read_text()
        self.assertIn('builtin.zig_version_string, "0.15.2"', build)
        self.assertIn('.minimum_zig_version = "0.15.2"', manifest)
        self.assertEqual(manifest.count('.hash = '), 3)
        self.assertIn('libpng-LICENSE', build)
        self.assertIn('zlib-LICENSE', build)
        self.assertIn('share/licenses/sshdesk/Vulkan-Headers', build)
        self.assertIn('MIT License', (ROOT / "LICENSE").read_text())

    def test_installers_build_native_commands_without_python_setup(self) -> None:
        for name in ("install-server.sh", "install-macos.sh", "install-windows.ps1"):
            source = (ROOT / "scripts" / name).read_text()
            self.assertIn('build -Doptimize=ReleaseSafe', source)
            self.assertNotIn('pip install', source)
            self.assertNotIn('-m venv', source)


if __name__ == "__main__":
    unittest.main()
