const std = @import("std");
const terminal = @import("terminal.zig");
const Frame = @import("frame.zig").Frame;
const Desktop = @import("platform.zig").Desktop;
const render = @import("render.zig");
const input = @import("input.zig");
const Options = @import("cli.zig").Options;
const A = std.mem.Allocator;
const kitty = @import("kitty.zig");
pub const Slot = struct {
    mutex: std.Thread.Mutex = .{},
    frame: ?Frame = null,
    generation: u64 = 0,
    dropped: usize = 0,
    pub fn publish(self: *Slot, frame: Frame) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var owned = frame;
        if (frame.generation != self.generation) {
            owned.deinit();
            self.dropped += 1;
            return;
        }
        if (self.frame) |*old| {
            old.deinit();
            self.dropped += 1;
        }
        self.frame = owned;
    }
    pub fn take(self: *Slot) ?Frame {
        self.mutex.lock();
        defer self.mutex.unlock();
        const f = self.frame;
        self.frame = null;
        return f;
    }
    pub fn resize(self: *Slot) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.generation +%= 1;
        if (self.frame) |*f| {
            f.deinit();
            self.frame = null;
            self.dropped += 1;
        }
        return self.generation;
    }
    pub fn currentGeneration(self: *Slot) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generation;
    }
    pub fn deinit(self: *Slot) void {
        if (self.take()) |f| {
            var owned = f;
            owned.deinit();
        }
    }
};
var signal_stop = std.atomic.Value(bool).init(false);
fn signalHandler(_: c_int) callconv(.c) void {
    signal_stop.store(true, .release);
}
const Shared = struct {
    allocator: A,
    opts: Options,
    desktop: *Desktop,
    initial_input: []const u8 = "",
    stop: std.atomic.Value(bool) = .init(false),
    slot: Slot = .{},
    mutex: std.Thread.Mutex = .{},
    viewport: ?render.Viewport = null,
    cursor: ?input.Point = null,
    pixel_mouse: bool = false,
    target: ?[2]usize = null,
    capture_interval: std.atomic.Value(u64) = .init(0),
    failure: ?anyerror = null,
    stats: std.atomic.Value(bool) = .init(false),
    captured: std.atomic.Value(u64) = .init(0),
    capture_ns: std.atomic.Value(u64) = .init(0),
    received: std.atomic.Value(u64) = .init(0),
    probe_ns: std.atomic.Value(i64) = .init(0),
    rtt_ns: std.atomic.Value(u64) = .init(0),
    fn stopNow(self: *Shared) void {
        self.stop.store(true, .release);
        terminal.cancelOutput();
    }
    fn fail(self: *Shared, err: anyerror) void {
        self.mutex.lock();
        self.failure = err;
        self.mutex.unlock();
        self.stopNow();
    }
    fn captureWorker(self: *Shared) void {
        while (!self.stop.load(.acquire)) {
            self.mutex.lock();
            const target = self.target;
            const generation = self.slot.currentGeneration();
            self.mutex.unlock();
            const interval = self.capture_interval.load(.acquire);
            self.desktop.setTarget(target, @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(@max(1, interval)))) catch |err| {
                self.fail(err);
                return;
            };
            const capture_start = std.time.nanoTimestamp();
            var frame = self.desktop.capture() catch |err| {
                self.fail(err);
                return;
            };
            self.capture_ns.store(@intCast(@max(0, std.time.nanoTimestamp() - capture_start)), .release);
            _ = self.captured.fetchAdd(1, .monotonic);
            frame.generation = generation;
            self.slot.publish(frame);
            var remaining = interval -| @as(u64, @intCast(@max(0, std.time.nanoTimestamp() - capture_start)));
            while (remaining > 0 and !self.stop.load(.acquire)) {
                const delay = @min(remaining, 5 * std.time.ns_per_ms);
                std.Thread.sleep(delay);
                remaining -= delay;
            }
        }
    }
    fn inputWorker(self: *Shared) void {
        var parser: input.Parser = .{};
        parser.feed(self.initial_input) catch |err| {
            self.fail(err);
            return;
        };
        var bytes: [4096]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            if (terminal.inputReady() catch |err| {
                self.fail(err);
                return;
            }) {
                const n = std.fs.File.stdin().read(&bytes) catch |err| {
                    self.fail(err);
                    return;
                };
                if (n == 0) {
                    self.stopNow();
                    return;
                }
                _ = self.received.fetchAdd(n, .monotonic);
                parser.feed(bytes[0..n]) catch |err| {
                    self.fail(err);
                    return;
                };
            }
            var coalescer: input.Coalescer = .{};
            var events: [2]input.Event = undefined;
            while (parser.next(std.time.milliTimestamp())) |event| {
                const count = coalescer.push(event, &events);
                for (events[0..count]) |next| self.handle(self.desktop, next) catch |err| {
                    self.fail(err);
                    return;
                };
            }
            if (coalescer.flush()) |move| self.handle(self.desktop, move) catch |err| {
                self.fail(err);
                return;
            };
        }
    }
    fn handle(self: *Shared, desktop: *Desktop, event: input.Event) !void {
        switch (event) {
            .exit => self.stopNow(),
            .stats => self.stats.store(!self.stats.load(.acquire), .release),
            .key => |key| try desktop.key(key),
            .report => {
                const started = self.probe_ns.swap(0, .acq_rel);
                if (started > 0) self.rtt_ns.store(@intCast(@max(0, std.time.nanoTimestamp() - started)), .release);
            },
            else => {
                if (!self.opts.mouse) return;
                const point = switch (event) {
                    .move => |p| p,
                    .button => |b| b.point,
                    .scroll => |s| s.point,
                    else => unreachable,
                };
                self.mutex.lock();
                const viewport = self.viewport;
                self.mutex.unlock();
                const v = viewport orelse return;
                const mapped = v.coordinates(point.column, point.row) orelse return;
                self.mutex.lock();
                self.cursor = point;
                self.mutex.unlock();
                switch (event) {
                    .move => try desktop.move(mapped[0], mapped[1]),
                    .button => |b| try desktop.button(b.button, b.pressed, mapped[0], mapped[1]),
                    .scroll => |s| try desktop.scroll(s.amount, mapped[0], mapped[1]),
                    else => unreachable,
                }
            },
        }
    }
};
fn output(shared: *Shared, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (shared.stop.load(.acquire) or signal_stop.load(.acquire)) return error.SessionStopped;
        if (!try terminal.outputReady()) continue;
        offset += std.fs.File.stdout().write(bytes[offset..@min(offset + 4096, bytes.len)]) catch |err| {
            if (shared.stop.load(.acquire) or signal_stop.load(.acquire)) return error.SessionStopped;
            if (err == error.WouldBlock) continue;
            return err;
        };
    }
}
fn probeTerminal(a: A, shared: *Shared, tmux: bool, retained: *std.ArrayList(u8)) !kitty.Probe {
    const query = try kitty.graphics(a, "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\", tmux);
    defer a.free(query);
    try output(shared, query);
    try output(shared, "\x1b[14t\x1b[16t");
    var probe: kitty.Probe = .{};
    var timer = try std.time.Timer.start();
    while (timer.read() < 200 * std.time.ns_per_ms) {
        if (!try terminal.inputReady()) continue;
        var buffer: [4096]u8 = undefined;
        const n = try std.fs.File.stdin().read(&buffer);
        if (n == 0) return error.TerminalDisconnected;
        try probe.feed(buffer[0..n]);
    }
    // Retain user keystrokes received during probing. Strip only complete
    // protocol responses; incomplete escapes remain for the incremental parser.
    const bytes = probe.buffer[0..probe.len];
    var i: usize = 0;
    while (i < bytes.len) {
        if (std.mem.startsWith(u8, bytes[i..], "\x1b_G")) {
            if (std.mem.indexOf(u8, bytes[i..], "\x1b\\")) |end| {
                i += end + 2;
                continue;
            }
        }
        if (std.mem.startsWith(u8, bytes[i..], "\x1b[4;") or std.mem.startsWith(u8, bytes[i..], "\x1b[6;")) {
            if (std.mem.indexOfScalar(u8, bytes[i..], 't')) |end| {
                i += end + 1;
                continue;
            }
        }
        try retained.append(a, bytes[i]);
        i += 1;
    }
    return probe;
}
pub fn run(a: A, opts: Options) !u8 {
    if (!std.fs.File.stdin().isTty() or !std.fs.File.stdout().isTty()) return error.InteractiveSshPtyRequired;
    signal_stop.store(false, .release);
    var signals = terminal.Signals.init(signalHandler);
    defer signals.deinit();
    var desktop = Desktop.init(a, opts.capture, false, opts.animate) catch |err| {
        if (signal_stop.load(.acquire)) return 130;
        return err;
    };
    defer desktop.deinit();
    if (!opts.no_input) desktop.configureInput(opts.input) catch |err| {
        if (signal_stop.load(.acquire)) return 130;
        return err;
    };
    if (signal_stop.load(.acquire)) return 130;
    var state = try terminal.State.enter();
    defer state.deinit();
    var shared: Shared = .{ .allocator = a, .opts = opts, .desktop = &desktop };
    defer shared.slot.deinit();
    try output(&shared, render.enter);
    defer {
        terminal.cleanup(render.leave);
    }
    if (opts.mouse) try output(&shared, render.mouse_on);
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    const mode = env.get("SSHDESK_RENDER") orelse "auto";
    if (!std.mem.eql(u8, mode, "auto") and !std.mem.eql(u8, mode, "ansi") and !std.mem.eql(u8, mode, "kitty")) return error.InvalidRenderMode;
    const tmux = env.get("TMUX") != null;
    var retained: std.ArrayList(u8) = .empty;
    defer retained.deinit(a);
    var probe: kitty.Probe = .{};
    if (!std.mem.eql(u8, mode, "ansi")) probe = try probeTerminal(a, &shared, tmux, &retained);
    shared.initial_input = retained.items;
    var pixel: ?kitty.Encoder = null;
    if (probe.kitty or std.mem.eql(u8, mode, "kitty")) pixel = try kitty.Encoder.init(a, tmux);
    defer if (pixel) |*encoder| {
        encoder.deinit();
        const clear = kitty.graphics(a, "\x1b_Ga=d,d=A,q=1\x1b\\", tmux) catch null;
        if (clear) |bytes| {
            terminal.cleanup(bytes);
            a.free(bytes);
        }
    };
    const initial_size = terminal.dimensions(.{ opts.columns, opts.rows });
    if (pixel != null and !opts.fps_explicit) shared.opts.fps = 60;
    const cell_width = if (probe.cell_width > 0) probe.cell_width else if (probe.pixel_width >= initial_size[0]) probe.pixel_width / initial_size[0] else 8;
    const cell_height = if (probe.cell_height > 0) probe.cell_height else if (probe.pixel_height >= initial_size[1]) probe.pixel_height / initial_size[1] else 16;
    shared.capture_interval.store(@intFromFloat(std.time.ns_per_s / shared.opts.fps), .release);
    shared.pixel_mouse = pixel != null and opts.mouse;
    if (shared.pixel_mouse) try output(&shared, "\x1b[?1016h");
    const capture = try std.Thread.spawn(.{}, Shared.captureWorker, .{&shared});
    defer {
        shared.stop.store(true, .release);
        capture.join();
    }
    const input_thread = try std.Thread.spawn(.{}, Shared.inputWorker, .{&shared});
    defer {
        shared.stop.store(true, .release);
        terminal.cancelThread(input_thread);
        input_thread.join();
    }
    var previous: ?render.Rendered = null;
    defer if (previous) |*p| p.deinit();
    var old_size = terminal.dimensions(.{ opts.columns, opts.rows });
    var fingerprint: ?u64 = null;
    var frames: usize = 0;
    var total_bytes: usize = 0;
    var timer = try std.time.Timer.start();
    var adaptive: @import("capabilities.zig").Adaptive = .{ .maximum_fps = shared.opts.fps, .scale = opts.scale, .automatic_scale = !opts.scale_explicit };
    var next_present: u64 = 0;
    var last_stats: u64 = 0;
    var last_scale = opts.scale;
    var stats_visible = false;
    var last_probe: u64 = 0;
    var last_cursor: ?input.Point = null;
    var full_count: usize = 0;
    var delta_count: usize = 0;
    var snapshot: @import("stats.zig").Snapshot = .{};
    while (!shared.stop.load(.acquire) and !signal_stop.load(.acquire)) {
        shared.mutex.lock();
        const cursor = shared.cursor;
        shared.mutex.unlock();
        if (cursor) |point| if (last_cursor == null or !std.meta.eql(point, last_cursor.?)) {
            if (pixel) |*encoder| {
                const bytes = try encoder.cursor(@intCast(@max(0, point.column)), @intCast(@max(0, point.row)), cell_width, cell_height);
                defer a.free(bytes);
                output(&shared, bytes) catch |err| {
                    if (err == error.SessionStopped) break;
                    return err;
                };
            } else {
                var buffer: [64]u8 = undefined;
                const bytes = try std.fmt.bufPrint(&buffer, "\x1b[{d};{d}H\x1b[?25h", .{ point.row + 1, point.column + 1 });
                output(&shared, bytes) catch |err| {
                    if (err == error.SessionStopped) break;
                    return err;
                };
            }
            last_cursor = point;
        };
        if (timer.read() < next_present) {
            std.Thread.sleep(2 * std.time.ns_per_ms);
            continue;
        }
        const visible = shared.stats.load(.acquire);
        if (visible != stats_visible) {
            stats_visible = visible;
            fingerprint = null;
            if (previous) |*p| p.deinit();
            previous = null;
            if (pixel) |*encoder| encoder.reset();
        }
        if (timer.read() - last_probe >= std.time.ns_per_s and shared.probe_ns.load(.acquire) == 0) {
            shared.probe_ns.store(@intCast(std.time.nanoTimestamp()), .release);
            output(&shared, "\x1b[6n") catch |err| {
                if (err == error.SessionStopped) break;
                return err;
            };
            last_probe = timer.read();
        }
        const size = terminal.dimensions(old_size);
        if (!std.meta.eql(size, old_size)) {
            old_size = size;
            shared.mutex.lock();
            _ = shared.slot.resize();
            shared.target = null;
            shared.mutex.unlock();
            fingerprint = null;
            if (previous) |*p| p.deinit();
            previous = null;
            if (pixel) |*encoder| encoder.reset();
        }
        var frame = shared.slot.take() orelse {
            std.Thread.sleep(2 * std.time.ns_per_ms);
            continue;
        };
        defer frame.deinit();
        const digest = frame.fingerprint();
        const refresh_stats = shared.stats.load(.acquire) and timer.read() - last_stats > 500 * std.time.ns_per_ms;
        if (fingerprint != null and fingerprint.? == digest and !refresh_stats and last_scale == adaptive.scale) continue;
        const desktop_size = frame.desktopSize();
        const target = if (pixel != null) blk: {
            const ratio = @min(1, @min(@as(f64, @floatFromInt(size[0] * cell_width)) / @as(f64, @floatFromInt(desktop_size[0])), @as(f64, @floatFromInt((size[1] - @min(1, size[1] - 1)) * cell_height)) / @as(f64, @floatFromInt(desktop_size[1])))) * adaptive.scale;
            break :blk [2]usize{ @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(desktop_size[0])) * ratio)))), @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(desktop_size[1])) * ratio)))) };
        } else blk: {
            const view = try render.Viewport.calculate(desktop_size[0], desktop_size[1], size[0], size[1], 1, adaptive.scale);
            break :blk [2]usize{ view.width, view.height * 2 };
        };
        shared.mutex.lock();
        if (shared.target == null or !std.meta.eql(shared.target.?, target)) {
            shared.target = target;
            _ = shared.slot.resize();
        }
        shared.mutex.unlock();
        const presented_at = timer.read();
        last_scale = adaptive.scale;
        var packet_size: usize = 0;
        var encoded_at = presented_at;
        var full_update = false;
        var changed: f64 = 0;
        if (pixel) |*encoder| {
            const bytes = try encoder.encode(frame, .{ .columns = size[0], .rows = size[1], .cell_width = cell_width, .cell_height = cell_height }, adaptive.scale);
            defer a.free(bytes);
            encoded_at = timer.read();
            full_update = std.mem.indexOf(u8, bytes, "z=-2") != null;
            changed = if (full_update) 100 else 0;
            output(&shared, bytes) catch |err| {
                if (err == error.SessionStopped) break;
                return err;
            };
            packet_size = bytes.len;
            shared.mutex.lock();
            shared.viewport = if (shared.pixel_mouse) encoder.pixel_viewport else encoder.viewport;
            shared.mutex.unlock();
        } else {
            var current = try render.render(a, frame, size[0], size[1], 1, adaptive.scale);
            var transferred = false;
            defer if (!transferred) current.deinit();
            const packet = try render.encode(a, previous, current, opts.color, opts.unicode);
            defer a.free(packet.bytes);
            encoded_at = timer.read();
            full_update = packet.full;
            changed = @as(f64, @floatFromInt(packet.changed)) * 100 / @as(f64, @floatFromInt(current.cells.len));
            output(&shared, packet.bytes) catch |err| {
                if (err == error.SessionStopped) break;
                return err;
            };
            shared.mutex.lock();
            shared.viewport = current.viewport;
            shared.mutex.unlock();
            if (previous) |*p| p.deinit();
            previous = current;
            transferred = true;
            packet_size = packet.bytes.len;
        }
        const write_done = timer.read();
        if (packet_size > 0) {
            if (full_update) full_count += 1 else delta_count += 1;
        }
        shared.slot.mutex.lock();
        const dropped = shared.slot.dropped;
        shared.slot.mutex.unlock();
        const elapsed = @max(0.001, @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s);
        const received = shared.received.load(.acquire);
        snapshot = .{ .columns = size[0], .rows = size[1], .width = desktop_size[0], .height = desktop_size[1], .full = full_count, .delta = delta_count, .dropped = dropped, .fps = @as(f64, @floatFromInt(frames)) / elapsed, .capture_fps = @as(f64, @floatFromInt(shared.captured.load(.acquire))) / elapsed, .changed = changed, .capture_ms = @as(f64, @floatFromInt(shared.capture_ns.load(.acquire))) / std.time.ns_per_ms, .render_encode_ms = @as(f64, @floatFromInt(encoded_at - presented_at)) / std.time.ns_per_ms, .write_ms = @as(f64, @floatFromInt(write_done - encoded_at)) / std.time.ns_per_ms, .age_ms = @as(f64, @floatFromInt(@max(0, std.time.nanoTimestamp() - frame.captured_ns))) / std.time.ns_per_ms, .tx_kbit = @as(f64, @floatFromInt(total_bytes * 8)) / elapsed / 1000, .rx_kbit = @as(f64, @floatFromInt(received * 8)) / elapsed / 1000, .sent = total_bytes, .received = received, .rtt_ms = @as(f64, @floatFromInt(shared.rtt_ns.load(.acquire))) / std.time.ns_per_ms };
        fingerprint = digest;
        frames += 1;
        total_bytes += packet_size;
        adaptive.observe(@as(f64, @floatFromInt(write_done - encoded_at)) / std.time.ns_per_ms, @as(f64, @floatFromInt(shared.rtt_ns.load(.acquire))) / std.time.ns_per_ms);
        const probe_started = shared.probe_ns.load(.acquire);
        const pending_ms: f64 = if (probe_started > 0) @as(f64, @floatFromInt(@max(0, std.time.nanoTimestamp() - probe_started))) / std.time.ns_per_ms else 0;
        adaptive.adjust(timer.read(), pending_ms);
        const interval = adaptive.interval(pending_ms);
        next_present = timer.read() + interval;
        shared.capture_interval.store(interval, .release);
        last_stats = timer.read();
        output(&shared, "\x1b[1;1H\x1b[0mSSHDESK | Ctrl+] twice: detach | Ctrl+S: stats\x1b[K") catch |err| {
            if (err == error.SessionStopped) break;
            return err;
        };
        if (stats_visible) {
            const overlay = try snapshot.overlay(a);
            defer a.free(overlay);
            output(&shared, overlay) catch |err| {
                if (err == error.SessionStopped) break;
                return err;
            };
        }
        last_cursor = null; // Frame/header output moves the terminal cursor.

    }
    shared.mutex.lock();
    const failure = shared.failure;
    shared.mutex.unlock();
    if (failure) |err| return err;
    return if (signal_stop.load(.acquire)) 130 else 0;
}
test "single latest frame slot, backpressure and resize generation rejection" {
    const a = std.testing.allocator;
    var slot: Slot = .{};
    defer slot.deinit();
    slot.publish(try Frame.init(a, 2, 2));
    slot.publish(try Frame.init(a, 3, 3));
    try std.testing.expectEqual(@as(usize, 1), slot.dropped);
    var latest = slot.take().?;
    defer latest.deinit();
    try std.testing.expectEqual(@as(usize, 3), latest.width);
    _ = slot.resize();
    slot.publish(try Frame.init(a, 2, 2));
    try std.testing.expect(slot.take() == null);
    var fresh = try Frame.init(a, 4, 4);
    fresh.generation = slot.currentGeneration();
    slot.publish(fresh);
    var accepted = slot.take().?;
    defer accepted.deinit();
    try std.testing.expectEqual(@as(usize, 4), accepted.width);
}
