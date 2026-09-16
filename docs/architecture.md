# Architecture

SSHDESK is a server-side terminal application launched by OpenSSH as a forced
command. The client is any normal SSH client with an interactive terminal.

```text
normal SSH client and terminal
          │ terminal graphics or ANSI / PTY input
          │ one authenticated SSH session
          ▼
OpenSSH sshd ── ForceCommand ── sshdesk-server
                                  ├── ScreenCapture
                                  │   ├── X11Capture
                                  │   │   ├── FFmpeg/XCB
                                  │   │   ├── MIT-SHM fallback
                                  │   │   └── XGetImage fallback
                                  │   ├── GnomeScreenCastCapture
                                  │   │   └── Mutter/PipeWire/GStreamer
                                  │   ├── WaylandCapture
                                  │   └── NativeCapture (macOS/Windows)
                                  ├── Renderer
                                  │   ├── KittyRenderer
                                  │   └── TerminalRenderer (fallback)
                                  ├── InputBackend
                                  │   ├── X11Input
                                  │   ├── MutterInput
                                  │   ├── YdotoolInput
                                  │   ├── MacOSInput
                                  │   └── WindowsInput
                                  └── SessionStats
```

OpenSSH owns authentication, encryption, host keys, PTY allocation, window-size
messages, connection management, and network transport. SSHDESK does not
implement SSH, listen on a port, or define client credentials.

`ScreenCapture`, `Renderer`, and `InputBackend` are independent. Linux selects
X11 or the active Wayland compositor automatically; native macOS and Windows
implementations use the same interfaces. GNOME links one ScreenCast stream to
one RemoteDesktop input session, while other Wayland backends remain isolated
behind the same capture/input abstractions.

The session probes terminal graphics and pixel geometry before starting its input
thread. A capable terminal receives palette-compressed PNG tiles through the Kitty
graphics protocol; other terminals receive colored half-block cells. The session
keeps rendered state in both modes. A changed frame becomes either a full redraw
or a tile/cell delta; an unchanged frame produces no frame output.
The preferred X11 backend reads a persistent FFmpeg/XCB stream. An independent
capture worker publishes only one latest frame; replacing it frees the old
frame. Resize generations reject in-flight frames from an earlier geometry.
Native MIT-SHM and XGetImage provide automatic fallbacks. Owned RGB buffers
carry both image dimensions and desktop dimensions, so local prescaling keeps
input coordinates intact. Frame fingerprints suppress unchanged output.

GNOME binds GLib/GIO and GStreamer C APIs. Mutter publishes a PipeWire node
once per session, GStreamer drains it through a one-buffer appsink, and input
uses the linked RemoteDesktop object. A target size change rebuilds the local
pipeline without recreating the compositor session.

Input parsing/injection runs in its own thread. Output backpressure adjusts
presentation and capture intervals and, unless fixed by the user, render scale.
The default maximum is 60 FPS for Kitty and 30 FPS for ANSI. Explicit limits
range from 0.5 to 120 FPS and scale from 0.25 to 1. libpng/zlib are linked
statically for screenshot and Kitty PNG encoding; no interpreter is used.

There is deliberately no SSHDESK application transport or client binary. An
unmodified SSH client carries one PTY byte stream. Kitty graphics, ANSI/UTF-8,
keyboard reports, and mouse reports are terminal protocols inside that stream.

## Agent path

Agent computer use is an optional, low-frequency control path. OpenSSH invokes
the fixed `sshdesk-agent` command without a PTY. Requests are bounded
newline-delimited JSON because they are infrequent control operations; PNG
observations are base64 encoded in responses. The desktop's interactive frame
path remains the direct terminal stream and never uses JSON.

```text
agent ── sshdesk-remote ── OpenSSH ── sshdesk-agent session
                                      ├── ScreenCapture
                                      └── InputBackend
```

The forced-command dispatcher reserves the basename `sshdesk-agent`, parses its
arguments without a shell, and rejects unrecognized original commands.
Standard OpenSSH connection multiplexing can reuse a transport for repeated
agent calls.

## Optional shell path

The exact remote command argument `shell` (or `sshdesk-shell`) opens an
interactive login shell as the authenticated SSH account. It never uses the
`RUN_AS` elevation reserved for the desktop and constrained agent paths. Plain
PTY connections still select SSHDESK; `desktop`, `sshdesk`, and
`sshdesk-server` select it explicitly. Other original commands remain rejected.

```text
OpenSSH ForceCommand dispatcher
    |-- no original command / desktop -- sshdesk-server
    |-- sshdesk-agent ... -------------- restricted agent parser
    `-- shell -------------------------- authenticated account login shell
```
