const std = @import("std");
const Frame = @import("../frame.zig").Frame;
const input = @import("../input.zig");
const Ptr = *anyopaque;
const CString = [*:0]const u8;
const remote_name = "org.gnome.Mutter.RemoteDesktop";
const remote_iface = remote_name ++ ".Session";
const screen_name = "org.gnome.Mutter.ScreenCast";
const screen_iface = screen_name ++ ".Session";
fn printZ(a: std.mem.Allocator, comptime format: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0);
}
pub const Backend = struct {
    allocator: std.mem.Allocator,
    libraries: [5]std.DynLib,
    bus: ?Ptr = null,
    remote: ?[:0]u8 = null,
    screen: ?[:0]u8 = null,
    stream: ?[:0]u8 = null,
    subscription: u32 = 0,
    node: u32 = 0,
    pipeline: ?Ptr = null,
    sink: ?Ptr = null,
    width: usize = 0,
    height: usize = 0,
    target: ?[2]usize = null,
    held: [3]bool = @splat(false),
    call_override: ?*const fn (*Backend, CString, CString, CString, CString, ?Ptr) anyerror!Ptr = null,
    pub fn init(a: std.mem.Allocator) !*Backend {
        const self = try a.create(Backend);
        errdefer a.destroy(self);
        var libs: [5]std.DynLib = undefined;
        var n: usize = 0;
        errdefer for (libs[0..n]) |*lib| lib.close();
        for ([_][]const u8{ "libglib-2.0.so.0", "libgobject-2.0.so.0", "libgio-2.0.so.0", "libgstreamer-1.0.so.0", "libgstapp-1.0.so.0" }, 0..) |name, i| {
            libs[i] = std.DynLib.open(name) catch return error.InstallGlibGioGstreamerAndPipewirePlugin;
            n += 1;
        }
        self.* = .{ .allocator = a, .libraries = libs };
        // Subsequent failures use closeResources, without closing the libraries twice.
        errdefer self.closeResources();
        (try self.symbol(*const fn (?*c_int, ?*?[*]CString) callconv(.c) void, "gst_init"))(null, null);
        const factory = (try self.symbol(*const fn (CString) callconv(.c) ?Ptr, "gst_element_factory_find"))("pipewiresrc") orelse return error.InstallGstreamerPipewirePlugin;
        self.unrefObject(factory);
        self.bus = (try self.symbol(*const fn (c_int, ?Ptr, ?*?Ptr) callconv(.c) ?Ptr, "g_bus_get_sync"))(2, null, null) orelse return error.ConnectToDesktopOwnerSessionBus;
        const area = try self.desktopArea();
        self.width = @intCast(area[2]);
        self.height = @intCast(area[3]);
        const remote = try self.call(remote_name, "/org/gnome/Mutter/RemoteDesktop", remote_name, "CreateSession", null);
        defer self.unref(remote);
        self.remote = try self.objectPath(remote);
        const parameters = try self.variant("('org.gnome.Mutter.RemoteDesktop.Session', 'SessionId')");
        const result = try self.call(remote_name, self.remote.?, "org.freedesktop.DBus.Properties", "Get", parameters);
        defer self.unref(result);
        const boxed = try self.child(result, 0);
        defer self.unref(boxed);
        const unboxed = (try self.symbol(*const fn (Ptr) callconv(.c) Ptr, "g_variant_get_variant"))(boxed);
        defer self.unref(unboxed);
        const id = try self.text(unboxed);
        for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidMutterSessionId;
        const properties = try printZ(a, "({{'remote-desktop-session-id': <'{s}'>}},)", .{id});
        defer a.free(properties);
        const screen = try self.call(screen_name, "/org/gnome/Mutter/ScreenCast", screen_name, "CreateSession", try self.variant(properties));
        defer self.unref(screen);
        self.screen = try self.objectPath(screen);
        const rectangle = try printZ(a, "({d}, {d}, {d}, {d}, {{'cursor-mode': <uint32 0>}})", .{ area[0], area[1], area[2], area[3] });
        defer a.free(rectangle);
        const stream = try self.call(screen_name, self.screen.?, screen_iface, "RecordArea", try self.variant(rectangle));
        defer self.unref(stream);
        self.stream = try self.objectPath(stream);
        self.subscription = (try self.symbol(*const fn (Ptr, CString, CString, CString, CString, ?CString, c_int, *const fn (Ptr, CString, CString, CString, CString, Ptr, ?Ptr) callconv(.c) void, ?Ptr, ?*const fn (?Ptr) callconv(.c) void) callconv(.c) u32, "g_dbus_connection_signal_subscribe"))(self.bus.?, screen_name, screen_name ++ ".Stream", "PipeWireStreamAdded", self.stream.?, null, 0, onStream, self, null);
        const started = try self.call(remote_name, self.remote.?, remote_iface, "Start", null);
        self.unref(started);
        var timer = try std.time.Timer.start();
        const context = (try self.symbol(*const fn () callconv(.c) Ptr, "g_main_context_default"))();
        const iterate = try self.symbol(*const fn (Ptr, c_int) callconv(.c) c_int, "g_main_context_iteration");
        while (self.node == 0) {
            while (iterate(context, 0) != 0) {}
            if (timer.read() > 5 * std.time.ns_per_s) return error.MutterDidNotPublishPipewireStream;
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        return self;
    }
    fn symbol(self: *Backend, comptime T: type, comptime name: [:0]const u8) !T {
        for (&self.libraries) |*lib| if (lib.lookup(T, name)) |value| return value;
        return error.IncompatibleGnomeLibrary;
    }
    fn unref(self: *Backend, value: Ptr) void {
        const f = self.symbol(*const fn (Ptr) callconv(.c) void, "g_variant_unref") catch return;
        f(value);
    }
    fn unrefObject(self: *Backend, value: Ptr) void {
        const f = self.symbol(*const fn (Ptr) callconv(.c) void, "g_object_unref") catch return;
        f(value);
    }
    fn unrefMini(self: *Backend, value: Ptr) void {
        const f = self.symbol(*const fn (Ptr) callconv(.c) void, "gst_mini_object_unref") catch return;
        f(value);
    }
    fn child(self: *Backend, value: Ptr, index: usize) !Ptr {
        return (try self.symbol(*const fn (Ptr, usize) callconv(.c) Ptr, "g_variant_get_child_value"))(value, index);
    }
    fn count(self: *Backend, value: Ptr) !usize {
        return (try self.symbol(*const fn (Ptr) callconv(.c) usize, "g_variant_n_children"))(value);
    }
    fn text(self: *Backend, value: Ptr) ![]const u8 {
        return std.mem.span((try self.symbol(*const fn (Ptr, ?*usize) callconv(.c) CString, "g_variant_get_string"))(value, null));
    }
    fn int(self: *Backend, value: Ptr) !i32 {
        return (try self.symbol(*const fn (Ptr) callconv(.c) i32, "g_variant_get_int32"))(value);
    }
    fn uint(self: *Backend, value: Ptr) !u32 {
        return (try self.symbol(*const fn (Ptr) callconv(.c) u32, "g_variant_get_uint32"))(value);
    }
    fn double(self: *Backend, value: Ptr) !f64 {
        return (try self.symbol(*const fn (Ptr) callconv(.c) f64, "g_variant_get_double"))(value);
    }
    fn atInt(self: *Backend, value: Ptr, index: usize) !i32 {
        const v = try self.child(value, index);
        defer self.unref(v);
        return self.int(v);
    }
    fn lookup(self: *Backend, value: Ptr, field: CString) !?Ptr {
        return (try self.symbol(*const fn (Ptr, CString, ?CString) callconv(.c) ?Ptr, "g_variant_lookup_value"))(value, field, null);
    }
    fn objectPath(self: *Backend, value: Ptr) ![:0]u8 {
        const v = try self.child(value, 0);
        defer self.unref(v);
        return self.allocator.dupeZ(u8, try self.text(v));
    }
    fn variant(self: *Backend, value: CString) !Ptr {
        return (try self.symbol(*const fn (?CString, CString, ?CString, ?*CString, ?*?Ptr) callconv(.c) ?Ptr, "g_variant_parse"))(null, value, null, null, null) orelse error.InvalidGVariant;
    }
    fn call(self: *Backend, destination: CString, path: CString, interface: CString, method: CString, parameters: ?Ptr) !Ptr {
        defer if (parameters) |v| self.unref(v);
        if (self.call_override) |override| return override(self, destination, path, interface, method, parameters);
        return (try self.symbol(*const fn (Ptr, CString, CString, CString, CString, ?Ptr, ?CString, c_int, c_int, ?Ptr, ?*?Ptr) callconv(.c) ?Ptr, "g_dbus_connection_call_sync"))(self.bus.?, destination, path, interface, method, parameters, null, 0, if (std.mem.eql(u8, std.mem.span(method), "Stop") or std.mem.startsWith(u8, std.mem.span(method), "Notify")) 1000 else 5000, null, null) orelse error.MutterDbusCallFailedCheckDesktopSessionPermissions;
    }
    fn onStream(_: Ptr, _: CString, _: CString, _: CString, _: CString, parameters: Ptr, user: ?Ptr) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(user.?));
        const v = self.child(parameters, 0) catch return;
        defer self.unref(v);
        self.node = self.uint(v) catch 0;
    }
    fn desktopArea(self: *Backend) ![4]i32 {
        const state = try self.call("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", "GetCurrentState", null);
        defer self.unref(state);
        return self.areaFromState(state);
    }
    fn areaFromState(self: *Backend, state: Ptr) ![4]i32 {
        const monitors = try self.child(state, 1);
        defer self.unref(monitors);
        const logical = try self.child(state, 2);
        defer self.unref(logical);
        const properties = try self.child(state, 3);
        defer self.unref(properties);
        var layout: u32 = 2;
        if (try self.lookup(properties, "layout-mode")) |v| {
            defer self.unref(v);
            layout = try self.uint(v);
        }
        var left: i32 = std.math.maxInt(i32);
        var top = left;
        var right: i32 = std.math.minInt(i32);
        var bottom = right;
        const equal = try self.symbol(*const fn (Ptr, Ptr) callconv(.c) c_int, "g_variant_equal");
        for (0..try self.count(logical)) |i| {
            const monitor = try self.child(logical, i);
            defer self.unref(monitor);
            const x = try self.atInt(monitor, 0);
            const y = try self.atInt(monitor, 1);
            const scalev = try self.child(monitor, 2);
            defer self.unref(scalev);
            const scale = try self.double(scalev);
            const transformv = try self.child(monitor, 3);
            defer self.unref(transformv);
            const transform = try self.uint(transformv);
            const specs = try self.child(monitor, 5);
            defer self.unref(specs);
            var width: i32 = 0;
            var height: i32 = 0;
            for (0..try self.count(specs)) |j| {
                const spec = try self.child(specs, j);
                defer self.unref(spec);
                for (0..try self.count(monitors)) |k| {
                    const physical = try self.child(monitors, k);
                    defer self.unref(physical);
                    const pspec = try self.child(physical, 0);
                    defer self.unref(pspec);
                    if (equal(spec, pspec) == 0) continue;
                    const modes = try self.child(physical, 1);
                    defer self.unref(modes);
                    for (0..try self.count(modes)) |m| {
                        const mode = try self.child(modes, m);
                        defer self.unref(mode);
                        const props = try self.child(mode, 6);
                        defer self.unref(props);
                        const active = try self.lookup(props, "is-current") orelse continue;
                        defer self.unref(active);
                        if ((try self.symbol(*const fn (Ptr) callconv(.c) c_int, "g_variant_get_boolean"))(active) == 0) continue;
                        width = @max(width, try self.atInt(mode, 1));
                        height = @max(height, try self.atInt(mode, 2));
                    }
                }
            }
            if (width == 0 or height == 0) continue;
            if (transform % 2 != 0) std.mem.swap(i32, &width, &height);
            if (layout == 1) {
                if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidMonitorScale;
                width = @intFromFloat(@round(@as(f64, @floatFromInt(width)) / scale));
                height = @intFromFloat(@round(@as(f64, @floatFromInt(height)) / scale));
            }
            if (width <= 0 or height <= 0 or width > 16384 or height > 16384 or @abs(@as(i64, x)) > 32768 or @abs(@as(i64, y)) > 32768) return error.InvalidDesktopDimensions;
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, x + width);
            bottom = @max(bottom, y + height);
        }
        if (left == std.math.maxInt(i32) or right - left > 16384 or bottom - top > 16384) return error.NoSupportedActiveMonitors;
        return .{ left, top, right - left, bottom - top };
    }
    fn startPipeline(self: *Backend) !void {
        if (self.pipeline != null) return;
        const size = self.target orelse .{ self.width, self.height };
        const description = try printZ(self.allocator, "pipewiresrc path={d} do-timestamp=true keepalive-time=100 ! queue leaky=downstream max-size-buffers=1 ! videoconvert n-threads=2 ! videoscale method=1 n-threads=2 ! video/x-raw,format=RGB,width={d},height={d},pixel-aspect-ratio=1/1 ! appsink name=sshdesk_sink max-buffers=1 drop=true sync=false", .{ self.node, size[0], size[1] });
        defer self.allocator.free(description);
        self.pipeline = (try self.symbol(*const fn (CString, ?*?Ptr) callconv(.c) ?Ptr, "gst_parse_launch"))(description, null) orelse return error.GstreamerPipelineFailed;
        errdefer self.stopPipeline();
        self.sink = (try self.symbol(*const fn (Ptr, CString) callconv(.c) ?Ptr, "gst_bin_get_by_name"))(self.pipeline.?, "sshdesk_sink") orelse return error.GstreamerSinkMissing;
        if ((try self.symbol(*const fn (Ptr, c_int) callconv(.c) c_int, "gst_element_set_state"))(self.pipeline.?, 4) == 0) return error.GstreamerPipelineFailed;
    }
    fn stopPipeline(self: *Backend) void {
        if (self.pipeline) |pipeline| {
            if (self.symbol(*const fn (Ptr, c_int) callconv(.c) c_int, "gst_element_set_state")) |set| {
                _ = set(pipeline, 1);
            } else |_| {}
            if (self.sink) |sink| self.unrefObject(sink);
            self.sink = null;
            self.unrefObject(pipeline);
            self.pipeline = null;
        }
    }
    pub fn setTarget(self: *Backend, width: usize, height: usize) !void {
        if (width < 1 or height < 1 or width > 16384 or height > 16384) return error.InvalidDimensions;
        const size = [2]usize{ @min(width, self.width), @min(height, self.height) };
        if (self.target == null or !std.meta.eql(size, self.target.?)) {
            self.target = size;
            self.stopPipeline();
        }
    }
    pub fn capture(self: *Backend, a: std.mem.Allocator) !Frame {
        try self.startPipeline();
        const pull = try self.symbol(*const fn (Ptr, u64) callconv(.c) ?Ptr, "gst_app_sink_try_pull_sample");
        const sample = pull(self.sink.?, 2 * std.time.ns_per_s) orelse blk: {
            self.stopPipeline();
            try self.startPipeline();
            break :blk pull(self.sink.?, 2 * std.time.ns_per_s) orelse return error.PipewireCaptureTimedOut;
        };
        defer self.unrefMini(sample);
        const caps = (try self.symbol(*const fn (Ptr) callconv(.c) ?Ptr, "gst_sample_get_caps"))(sample) orelse return error.InvalidVideoFrame;
        const structure = (try self.symbol(*const fn (Ptr, c_uint) callconv(.c) Ptr, "gst_caps_get_structure"))(caps, 0);
        const getint = try self.symbol(*const fn (Ptr, CString, *c_int) callconv(.c) c_int, "gst_structure_get_int");
        var w: c_int = 0;
        var h: c_int = 0;
        if (getint(structure, "width", &w) == 0 or getint(structure, "height", &h) == 0 or w < 1 or h < 1 or w > 16384 or h > 16384) return error.InvalidVideoFrame;
        var frame = try Frame.init(a, @intCast(w), @intCast(h));
        errdefer frame.deinit();
        frame.desktop_width = self.width;
        frame.desktop_height = self.height;
        const buffer = (try self.symbol(*const fn (Ptr) callconv(.c) ?Ptr, "gst_sample_get_buffer"))(sample) orelse return error.InvalidVideoFrame;
        const stride = (frame.width * 3 + 3) & ~@as(usize, 3);
        const raw = try a.alloc(u8, stride * frame.height);
        defer a.free(raw);
        if ((try self.symbol(*const fn (Ptr, usize, [*]u8, usize) callconv(.c) usize, "gst_buffer_extract"))(buffer, 0, raw.ptr, raw.len) != raw.len) return error.InvalidVideoFrame;
        for (0..frame.height) |y| @memcpy(std.mem.sliceAsBytes(frame.pixels[y * frame.width ..][0..frame.width]), raw[y * stride ..][0 .. frame.width * 3]);
        return frame;
    }
    fn notify(self: *Backend, method: CString, parameters: CString) !void {
        const result = try self.call(remote_name, self.remote.?, remote_iface, method, try self.variant(parameters));
        self.unref(result);
    }
    pub fn key(self: *Backend, event: input.KeyEvent) !void {
        const sym = input.keysym(event);
        if (sym == 0) return;
        const modifiers = [_]u32{ 42, 56, 29 };
        var held = [_]bool{ false, false, false };
        defer for (held, 0..) |down, i| {
            if (down) {
                var buf: [64]u8 = undefined;
                const message = std.fmt.bufPrintZ(&buf, "(uint32 {d}, false)", .{modifiers[i]}) catch continue;
                self.notify("NotifyKeyboardKeycode", message) catch {};
            }
        };
        for (modifiers, 0..) |code, i| if (event.modifiers & (@as(u3, 1) << @intCast(i)) != 0) {
            var buf: [64]u8 = undefined;
            try self.notify("NotifyKeyboardKeycode", try std.fmt.bufPrintZ(&buf, "(uint32 {d}, true)", .{code}));
            held[i] = true;
        };
        for ([_]bool{ true, false }) |down| {
            if ((event.action == 0 and !down) or (event.action == 1 and down)) continue;
            var buf: [64]u8 = undefined;
            try self.notify("NotifyKeyboardKeysym", try std.fmt.bufPrintZ(&buf, "(uint32 {d}, {s})", .{ sym, if (down) "true" else "false" }));
        }
    }
    pub fn move(self: *Backend, x: i32, y: i32) !void {
        var buf: [512]u8 = undefined;
        try self.notify("NotifyPointerMotionAbsolute", try std.fmt.bufPrintZ(&buf, "('{s}', {d}.0, {d}.0)", .{ self.stream.?, std.math.clamp(x, 0, @as(i32, @intCast(self.width)) - 1), std.math.clamp(y, 0, @as(i32, @intCast(self.height)) - 1) }));
    }
    pub fn button(self: *Backend, number: u8, down: bool, x: i32, y: i32) !void {
        if (number < 1 or number > 3) return error.InvalidButton;
        try self.move(x, y);
        var buf: [64]u8 = undefined;
        const code: i32 = if (number == 1) 0x110 else if (number == 2) 0x112 else 0x111;
        try self.notify("NotifyPointerButton", try std.fmt.bufPrintZ(&buf, "({d}, {s})", .{ code, if (down) "true" else "false" }));
        self.held[number - 1] = down;
    }
    pub fn scroll(self: *Backend, amount: i32, x: i32, y: i32) !void {
        try self.move(x, y);
        var buf: [64]u8 = undefined;
        try self.notify("NotifyPointerAxisDiscrete", try std.fmt.bufPrintZ(&buf, "(uint32 0, {d})", .{std.math.clamp(amount, -20, 20)}));
    }
    fn closeResources(self: *Backend) void {
        for (self.held, 0..) |held, i| if (held) {
            self.button(@intCast(i + 1), false, 0, 0) catch {};
        };
        self.stopPipeline();
        if (self.bus) |bus| {
            if (self.subscription != 0) {
                if (self.symbol(*const fn (Ptr, u32) callconv(.c) void, "g_dbus_connection_signal_unsubscribe")) |f| f(bus, self.subscription) else |_| {}
            }
            if (self.screen) |path| {
                if (self.call(screen_name, path, screen_iface, "Stop", null)) |v| self.unref(v) else |_| {}
            }
            if (self.remote) |path| {
                if (self.call(remote_name, path, remote_iface, "Stop", null)) |v| self.unref(v) else |_| {}
            }
            self.unrefObject(bus);
            self.bus = null;
        }
        if (self.remote) |path| self.allocator.free(path);
        if (self.screen) |path| self.allocator.free(path);
        if (self.stream) |path| self.allocator.free(path);
    }
    pub fn deinit(self: *Backend) void {
        self.closeResources();
        for (&self.libraries) |*lib| lib.close();
        const a = self.allocator;
        a.destroy(self);
    }
};

fn variantTestBackend() !Backend {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var libraries: [5]std.DynLib = undefined;
    var count: usize = 0;
    errdefer for (libraries[0..count]) |*lib| lib.close();
    for (&libraries) |*lib| {
        lib.* = std.DynLib.open("libglib-2.0.so.0") catch return error.SkipZigTest;
        count += 1;
    }
    return .{ .allocator = std.testing.allocator, .libraries = libraries };
}
test "GNOME native variants combine scaled monitors into complete desktop area" {
    var backend = try variantTestBackend();
    defer for (&backend.libraries) |*lib| lib.close();
    const state = try backend.variant("(uint32 1, [(('DP-1','vendor','left','1'), [('mode-a',1920,1080,60.0,1.0,@ad [],{'is-current': <true>})], @a{sv} {})," ++
        " (('eDP-1','vendor','right','2'), [('mode-b',2560,1600,60.0,1.0,@ad [],{'is-current': <true>})], @a{sv} {})]," ++
        " [(0,0,1.0,uint32 0,true,[('DP-1','vendor','left','1')],@a{sv} {}), (1920,0,2.0,uint32 0,false,[('eDP-1','vendor','right','2')],@a{sv} {})]," ++
        " {'layout-mode': <uint32 1>})");
    defer backend.unref(state);
    try std.testing.expectEqual([4]i32{ 0, 0, 3200, 1080 }, try backend.areaFromState(state));
}
const MockCalls = struct {
    var stops: usize = 0;
    var moves: usize = 0;
    fn call(backend: *Backend, _: CString, path: CString, _: CString, method: CString, parameters: ?Ptr) !Ptr {
        const name = std.mem.span(method);
        if (std.mem.eql(u8, name, "Stop")) {
            try std.testing.expectEqualStrings(if (stops == 0) "/screen/session" else "/remote/session", std.mem.span(path));
            stops += 1;
        } else if (std.mem.eql(u8, name, "NotifyPointerMotionAbsolute")) {
            try std.testing.expectEqualStrings("/remote/session", std.mem.span(path));
            const p = parameters.?;
            const stream = try backend.child(p, 0);
            defer backend.unref(stream);
            try std.testing.expectEqualStrings("/screen/stream", try backend.text(stream));
            const x = try backend.child(p, 1);
            defer backend.unref(x);
            const y = try backend.child(p, 2);
            defer backend.unref(y);
            try std.testing.expectEqual(@as(f64, 0), try backend.double(x));
            try std.testing.expectEqual(@as(f64, 719), try backend.double(y));
            moves += 1;
        } else return error.UnexpectedMockCall;
        return backend.variant("()");
    }
};
test "GNOME linked input clamps coordinates and resize preserves compositor sessions" {
    var backend = try variantTestBackend();
    defer for (&backend.libraries) |*lib| lib.close();
    backend.bus = @ptrFromInt(1);
    backend.remote = try backend.allocator.dupeZ(u8, "/remote/session");
    backend.screen = try backend.allocator.dupeZ(u8, "/screen/session");
    backend.stream = try backend.allocator.dupeZ(u8, "/screen/stream");
    backend.width = 1280;
    backend.height = 720;
    backend.call_override = MockCalls.call;
    MockCalls.stops = 0;
    MockCalls.moves = 0;
    try backend.move(-20, 9999);
    try backend.setTarget(640, 360);
    try std.testing.expectEqual(@as(usize, 0), MockCalls.stops);
    try std.testing.expectEqualStrings("/remote/session", backend.remote.?);
    backend.closeResources();
    try std.testing.expectEqual(@as(usize, 2), MockCalls.stops);
    try std.testing.expectEqual(@as(usize, 1), MockCalls.moves);
}
