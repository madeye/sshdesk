const std = @import("std");
const builtin = @import("builtin");
const frame = @import("frame.zig");
const input = @import("input.zig");
const Png = @import("png.zig").Png;
const process = @import("process.zig");
const Native = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig").Backend,
    .linux => @import("platform/x11.zig").Backend,
    .windows => @import("platform/windows.zig").Backend,
    else => Unsupported,
};
const Unsupported = struct {
    pub fn init() !Unsupported {
        return error.UnsupportedPlatform;
    }
    pub fn deinit(_: *Unsupported) void {}
    pub fn capture(_: *Unsupported, _: std.mem.Allocator) !frame.Frame {
        return error.UnsupportedPlatform;
    }
    pub fn checkInput(_: *Unsupported) !void {
        return error.UnsupportedPlatform;
    }
    pub fn key(_: *Unsupported, _: input.KeyEvent) !void {
        return error.UnsupportedPlatform;
    }
    pub fn move(_: *Unsupported, _: i32, _: i32) !void {
        return error.UnsupportedPlatform;
    }
    pub fn button(_: *Unsupported, _: u8, _: bool, _: i32, _: i32) !void {
        return error.UnsupportedPlatform;
    }
    pub fn scroll(_: *Unsupported, _: i32, _: i32, _: i32) !void {
        return error.UnsupportedPlatform;
    }
};
pub const Selection = struct { system: []const u8, session: []const u8, capture: []const u8, input: []const u8 };
pub fn detect(env: *const std.process.EnvMap) !Selection {
    return detectSystem(builtin.os.tag, env);
}
pub fn detectSystem(comptime os: std.Target.Os.Tag, env: *const std.process.EnvMap) !Selection {
    switch (os) {
        .macos => return .{ .system = "Darwin", .session = "aqua", .capture = "native", .input = "quartz" },
        .windows => return .{ .system = "Windows", .session = "windows", .capture = "native", .input = "sendinput" },
        .linux => {
            if (env.get("WAYLAND_DISPLAY") != null and !std.ascii.eqlIgnoreCase(env.get("XDG_SESSION_TYPE") orelse "", "x11")) {
                const desktop = env.get("XDG_CURRENT_DESKTOP") orelse "";
                const gnome = std.ascii.indexOfIgnoreCase(desktop, "gnome") != null or std.ascii.indexOfIgnoreCase(desktop, "unity") != null;
                return .{ .system = "Linux", .session = "wayland", .capture = if (gnome) "gnome" else "wayland", .input = if (gnome) "mutter" else "ydotool" };
            }
            if (env.get("DISPLAY") != null) return .{ .system = "Linux", .session = "x11", .capture = "x11", .input = "x11" };
            return error.SetDisplayOrWaylandDisplay;
        },
        else => return error.UnsupportedPlatform,
    }
}
pub const Desktop = struct {
    allocator: std.mem.Allocator,
    backend: ?Native = null,
    input_backend: ?Native = null,
    input_name: []const u8 = "auto",
    gnome: ?*@import("platform/gnome.zig").Backend = null,
    ydotool: ?@import("platform/ydotool.zig").Backend = null,
    synthetic: bool = false,
    animate: bool = true,
    wayland: bool = false,
    wayland_tool: []const u8 = "grim",
    frame_number: usize = 0,
    target: ?[2]usize = null,

    width: usize = 1280,
    height: usize = 720,
    input_enabled: bool = true,
    held_keys: [256]?input.KeyEvent = @splat(null),
    selection: Selection = .{ .system = "Synthetic", .session = "synthetic", .capture = "synthetic", .input = "none" },
    pub fn setTarget(self: *Desktop, target: ?[2]usize, fps: f64) !void {
        self.target = target;
        if (self.gnome) |backend| if (target) |size| try backend.setTarget(size[0], size[1]);
        if (builtin.os.tag == .linux) if (self.backend) |*backend| backend.setFrameRate(fps);
    }
    pub fn init(a: std.mem.Allocator, name: []const u8, enabled: bool, animate: bool) !Desktop {
        var result: Desktop = .{ .allocator = a, .input_enabled = enabled, .animate = animate };
        if (std.mem.eql(u8, name, "synthetic")) {
            result.synthetic = true;
            result.input_enabled = false;
            return result;
        }
        var env = try std.process.getEnvMap(a);
        defer env.deinit();
        result.selection = try detect(&env);
        const selected = if (std.mem.eql(u8, name, "auto")) result.selection.capture else name;
        if (std.mem.eql(u8, selected, "gnome")) {
            if (builtin.os.tag != .linux) return error.GnomeRequiresLinux;
            result.gnome = try @import("platform/gnome.zig").Backend.init(a);
            result.width = result.gnome.?.width;
            result.height = result.gnome.?.height;
            return result;
        }
        if (std.mem.eql(u8, selected, "wayland")) {
            if (builtin.os.tag != .linux) return error.WaylandRequiresLinux;
            result.wayland = true;
            const desktop_name = env.get("XDG_CURRENT_DESKTOP") orelse "";
            if (std.ascii.indexOfIgnoreCase(desktop_name, "kde") != null or std.ascii.indexOfIgnoreCase(desktop_name, "plasma") != null) result.wayland_tool = "spectacle";
            if (enabled) result.ydotool = try @import("platform/ydotool.zig").Backend.init(a);
        } else {
            if (!std.mem.eql(u8, selected, "native") and !std.mem.eql(u8, selected, "x11")) return error.UnknownCaptureBackend;
            if (std.mem.eql(u8, selected, "x11") and builtin.os.tag != .linux) return error.X11RequiresLinux;
            result.backend = try Native.init();
            errdefer result.backend.?.deinit();
            if (enabled) try result.backend.?.checkInput();
        }
        return result;
    }
    pub fn configureInput(self: *Desktop, name: []const u8) !void {
        if (self.synthetic or std.mem.eql(u8, name, "none")) {
            self.input_enabled = false;
            return;
        }
        self.input_name = name;
        self.input_enabled = true;
        const selected = if (std.mem.eql(u8, name, "auto")) (if (self.gnome != null) "mutter" else if (self.wayland) "ydotool" else self.selection.input) else name;
        if (std.mem.eql(u8, selected, "mutter")) {
            if (self.gnome == null) return error.MutterInputRequiresLinkedGnomeCapture;
        } else if (std.mem.eql(u8, selected, "ydotool")) {
            if (builtin.os.tag != .linux) return error.YdotoolRequiresLinux;
            _ = try self.waylandInput();
        } else {
            const valid = switch (builtin.os.tag) {
                .linux => "x11",
                .macos => "quartz",
                .windows => "sendinput",
                else => "unsupported",
            };
            if (!std.mem.eql(u8, selected, valid)) return error.InputBackendNotAvailableOnThisPlatform;
            if (self.backend) |*backend| try backend.checkInput() else {
                self.input_backend = try Native.init();
                try self.input_backend.?.checkInput();
            }
        }
        self.input_name = selected;
    }
    pub fn capture(self: *Desktop) !frame.Frame {
        var result = if (self.gnome) |backend| try backend.capture(self.allocator) else if (self.synthetic) try frame.synthetic(self.allocator, self.width, self.height, if (self.animate) self.frame_number else null) else if (self.wayland) blk: {
            var png = try Png.init();
            defer png.deinit();
            if (std.mem.eql(u8, self.wayland_tool, "grim")) {
                var child = process.run(self.allocator, &.{ "grim", "-c", "-t", "png", "-" }, 5 * std.time.ns_per_s, 64 * 1024 * 1024) catch |err| {
                    if (err == error.FileNotFound) return error.InstallGrimForWaylandCapture;
                    return err;
                };
                defer child.deinit();
                if (!child.success()) return error.GrimCaptureFailed;
                break :blk try png.decode(self.allocator, child.stdout);
            }
            const path = try std.fmt.allocPrint(self.allocator, "/tmp/sshdesk-capture-{x}.png", .{std.crypto.random.int(u128)});
            defer self.allocator.free(path);
            const file = try std.fs.cwd().createFile(path, .{ .exclusive = true, .mode = 0o600 });
            file.close();
            defer std.fs.cwd().deleteFile(path) catch {};
            var child = process.run(self.allocator, &.{ "spectacle", "-b", "-n", "-o", path }, 5 * std.time.ns_per_s, 65536) catch |err| {
                if (err == error.FileNotFound) return error.InstallSpectacleForKdeCapture;
                return err;
            };
            defer child.deinit();
            if (!child.success()) return error.SpectacleCaptureFailed;
            const bytes = try std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024);
            defer self.allocator.free(bytes);
            break :blk try png.decode(self.allocator, bytes);
        } else try self.backend.?.capture(self.allocator);
        const desktop = result.desktopSize();
        self.width = desktop[0];
        self.height = desktop[1];
        if (self.target) |size| {
            if (size[0] < result.width or size[1] < result.height) {
                const small = result.resize(self.allocator, @min(size[0], result.width), @min(size[1], result.height)) catch |err| {
                    result.deinit();
                    return err;
                };
                result.deinit();
                result = small;
            }
        }
        self.frame_number +%= 1;
        return result;
    }
    pub fn key(self: *Desktop, event: input.KeyEvent) !void {
        if (!self.input_enabled) return;
        var matching: ?usize = null;
        var free: ?usize = null;
        for (self.held_keys, 0..) |held, i| {
            if (held) |k| {
                if (k.key == event.key and k.unicode == event.unicode) matching = i;
            } else if (free == null) free = i;
        }
        const index = matching orelse free orelse return error.TooManyHeldKeys;
        try self.injectKey(event);
        self.held_keys[index] = if (event.action == 0) event else null;
    }
    fn injectKey(self: *Desktop, event: input.KeyEvent) !void {
        if (!self.input_enabled) return;
        if (self.input_backend) |*backend| {
            try backend.key(event);
            return;
        }
        if (std.mem.eql(u8, self.input_name, "ydotool")) {
            try (try self.waylandInput()).key(event);
            return;
        }
        if (self.gnome) |backend| {
            try backend.key(event);
            return;
        }
        if (self.wayland) {
            try (try self.waylandInput()).key(event);
            return;
        }
        try self.backend.?.key(event);
    }
    pub fn move(self: *Desktop, x: i32, y: i32) !void {
        if (!self.input_enabled) return;
        if (self.input_backend) |*backend| {
            try backend.move(x, y);
            return;
        }
        if (std.mem.eql(u8, self.input_name, "ydotool")) {
            try (try self.waylandInput()).move(x, y);
            return;
        }
        if (self.gnome) |backend| {
            try backend.move(x, y);
            return;
        }
        if (self.wayland) {
            try (try self.waylandInput()).move(x, y);
            return;
        }
        try self.backend.?.move(x, y);
    }
    pub fn button(self: *Desktop, number: u8, down: bool, x: i32, y: i32) !void {
        if (!self.input_enabled) return;
        if (self.input_backend) |*backend| {
            try backend.button(number, down, x, y);
            return;
        }
        if (std.mem.eql(u8, self.input_name, "ydotool")) {
            try (try self.waylandInput()).button(number, down, x, y);
            return;
        }
        if (self.gnome) |backend| {
            try backend.button(number, down, x, y);
            return;
        }
        if (self.wayland) {
            try (try self.waylandInput()).button(number, down, x, y);
            return;
        }
        try self.backend.?.button(number, down, x, y);
    }
    pub fn scroll(self: *Desktop, amount: i32, x: i32, y: i32) !void {
        if (!self.input_enabled) return;
        if (self.input_backend) |*backend| {
            try backend.scroll(amount, x, y);
            return;
        }
        if (std.mem.eql(u8, self.input_name, "ydotool")) {
            try (try self.waylandInput()).scroll(amount, x, y);
            return;
        }
        if (self.gnome) |backend| {
            try backend.scroll(amount, x, y);
            return;
        }
        if (self.wayland) {
            try (try self.waylandInput()).scroll(amount, x, y);
            return;
        }
        try self.backend.?.scroll(amount, x, y);
    }
    fn waylandInput(self: *Desktop) !*@import("platform/ydotool.zig").Backend {
        if (self.ydotool == null) self.ydotool = try @import("platform/ydotool.zig").Backend.init(self.allocator);
        return &self.ydotool.?;
    }
    pub fn deinit(self: *Desktop) void {
        for (self.held_keys) |held| if (held) |key_event| {
            var release = key_event;
            release.action = 1;
            self.injectKey(release) catch {};
        };
        if (self.gnome) |backend| backend.deinit();
        if (self.ydotool) |*backend| backend.deinit();
        if (self.input_backend) |*backend| backend.deinit();
        if (self.backend) |*backend| backend.deinit();
    }
};

test "Xvfb native capture and XTest input integration" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(a, "SSHDESK_TEST_XVFB") catch return error.SkipZigTest;
    defer a.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    var desktop = try Desktop.init(a, "x11", true, false);
    defer desktop.deinit();
    const backend = &desktop.backend.?;
    const DisplayPointer = @TypeOf(backend.display);
    const background = backend.lib.lookup(*const fn (DisplayPointer, c_ulong, c_ulong) callconv(.c) c_int, "XSetWindowBackground").?;
    const clear = backend.lib.lookup(*const fn (DisplayPointer, c_ulong) callconv(.c) c_int, "XClearWindow").?;
    const sync = backend.lib.lookup(*const fn (DisplayPointer, c_int) callconv(.c) c_int, "XSync").?;
    _ = background(backend.display, backend.root, 0xffffff);
    _ = clear(backend.display, backend.root);
    _ = sync(backend.display, 0);
    var capture = try desktop.capture();
    defer capture.deinit();
    try std.testing.expect(capture.width > 0 and capture.height > 0);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, capture.pixels[0]);
    try desktop.move(20, 30);
    try desktop.button(1, true, 20, 30);
    try desktop.button(1, false, 20, 30);
    try desktop.key(.{ .key = .enter });
    _ = sync(backend.display, 0);
    const query = backend.lib.lookup(*const fn (DisplayPointer, c_ulong, *c_ulong, *c_ulong, *c_int, *c_int, *c_int, *c_int, *c_uint) callconv(.c) c_int, "XQueryPointer").?;
    var root: c_ulong = 0;
    var child: c_ulong = 0;
    var x: c_int = 0;
    var y: c_int = 0;
    var wx: c_int = 0;
    var wy: c_int = 0;
    var mask: c_uint = 0;
    try std.testing.expect(query(backend.display, backend.root, &root, &child, &x, &y, &wx, &wy, &mask) != 0);
    try std.testing.expectEqual(@as(c_int, 20), x);
    try std.testing.expectEqual(@as(c_int, 30), y);
    try std.testing.expectEqual(@as(c_uint, 0), mask & (256 | 512 | 1024));
    try desktop.setTarget(.{ 100, 50 }, 24);
    var scaled = try desktop.capture();
    defer scaled.deinit();
    try std.testing.expectEqual([2]usize{ 100, 50 }, .{ scaled.width, scaled.height });
    try std.testing.expectEqual([2]usize{ capture.width, capture.height }, scaled.desktopSize());
    try std.testing.expectEqual(@as(f64, 24), backend.fps);
}

test "platform selection respects explicit X11 and Wayland compositor" {
    const a = std.testing.allocator;
    var env = std.process.EnvMap.init(a);
    defer env.deinit();
    try std.testing.expectError(error.SetDisplayOrWaylandDisplay, detectSystem(.linux, &env));
    try env.put("DISPLAY", ":42");
    try std.testing.expectEqualStrings("x11", (try detectSystem(.linux, &env)).capture);
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    try env.put("XDG_CURRENT_DESKTOP", "ubuntu:GNOME");
    try std.testing.expectEqualStrings("gnome", (try detectSystem(.linux, &env)).capture);
    try std.testing.expectEqualStrings("mutter", (try detectSystem(.linux, &env)).input);
    try env.put("XDG_CURRENT_DESKTOP", "KDE");
    try std.testing.expectEqualStrings("ydotool", (try detectSystem(.linux, &env)).input);
    try env.put("XDG_SESSION_TYPE", "X11");
    try std.testing.expectEqualStrings("x11", (try detectSystem(.linux, &env)).capture);
    try std.testing.expectEqualStrings("quartz", (try detectSystem(.macos, &env)).input);
    try std.testing.expectEqualStrings("sendinput", (try detectSystem(.windows, &env)).input);
}
