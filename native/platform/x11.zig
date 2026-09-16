const std = @import("std");
const Frame = @import("../frame.zig").Frame;
const input = @import("../input.zig");
const Display = opaque {};
const shm = @cImport({
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});
const Image = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    data: ?[*]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    obdata: ?*anyopaque,
    funcs: extern struct { create: ?*anyopaque, destroy: *const fn (*Image) callconv(.c) c_int, get: *const fn (*Image, c_int, c_int) callconv(.c) c_ulong, put: ?*anyopaque, sub: ?*anyopaque, add: ?*anyopaque },
};
const ShmInfo = extern struct { segment: c_ulong = 0, id: c_int = -1, address: ?[*]u8 = null, read_only: c_int = 0 };
const SharedImage = struct { library: std.DynLib, image: *Image, info: *ShmInfo, allocator: std.mem.Allocator };
var shm_error = std.atomic.Value(bool).init(false);
fn onShmError(_: *Display, _: *anyopaque) callconv(.c) c_int {
    shm_error.store(true, .release);
    return 0;
}
pub const Backend = struct {
    lib: std.DynLib,
    xtest: ?std.DynLib = null,
    display: *Display,
    root: c_ulong,
    ffmpeg: ?@import("ffmpeg.zig").Backend = null,
    ffmpeg_failed: bool = false,
    fps: f64 = 60,

    shared_image: ?SharedImage = null,
    shm_failed: bool = false,
    held: [3]bool = @splat(false),
    pub fn setFrameRate(self: *Backend, fps: f64) void {
        const bounded = std.math.clamp(fps, 0.5, 120);
        if (@abs(bounded - self.fps) < 1) return;
        self.fps = bounded;
        if (self.ffmpeg) |*stream| stream.deinit();
        self.ffmpeg = null;
    }
    pub fn init() !Backend {
        var lib = std.DynLib.open("libX11.so.6") catch return error.InstallLibX11;
        errdefer lib.close();
        const init_threads = lib.lookup(*const fn () callconv(.c) c_int, "XInitThreads") orelse return error.MissingX11API;
        if (init_threads() == 0) return error.X11ThreadInitializationFailed;
        const open = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "XOpenDisplay") orelse return error.MissingX11API;
        const display = open(null) orelse return error.SetDisplayAndXauthorityForDesktopOwner;
        const root = (lib.lookup(*const fn (*Display) callconv(.c) c_ulong, "XDefaultRootWindow") orelse return error.MissingX11API)(display);
        return .{ .lib = lib, .display = display, .root = root };
    }
    fn fnc(self: *Backend, comptime T: type, comptime name: [:0]const u8) !T {
        return self.lib.lookup(T, name) orelse error.MissingX11API;
    }
    pub fn checkInput(self: *Backend) !void {
        if (self.xtest == null) self.xtest = std.DynLib.open("libXtst.so.6") catch return error.InstallLibXtst;
        const query = self.xtest.?.lookup(*const fn (*Display, *c_int, *c_int, *c_int, *c_int) callconv(.c) c_int, "XTestQueryExtension") orelse return error.MissingXTest;
        var e: c_int = 0;
        var ev: c_int = 0;
        var major: c_int = 0;
        var minor: c_int = 0;
        if (query(self.display, &ev, &e, &major, &minor) == 0) return error.EnableXTestExtension;
    }
    fn flush(self: *Backend) !void {
        _ = (try self.fnc(*const fn (*Display) callconv(.c) c_int, "XFlush"))(self.display);
    }
    pub fn size(self: *Backend) ![2]usize {
        var root: c_ulong = 0;
        var x: c_int = 0;
        var y: c_int = 0;
        var w: c_uint = 0;
        var h: c_uint = 0;
        var border: c_uint = 0;
        var depth: c_uint = 0;
        if ((try self.fnc(*const fn (*Display, c_ulong, *c_ulong, *c_int, *c_int, *c_uint, *c_uint, *c_uint, *c_uint) callconv(.c) c_int, "XGetGeometry"))(self.display, self.root, &root, &x, &y, &w, &h, &border, &depth) == 0) return error.X11CaptureFailed;
        return .{ w, h };
    }
    fn startShm(self: *Backend, a: std.mem.Allocator, dimensions: [2]usize) !void {
        var library = std.DynLib.open("libXext.so.6") catch return error.InstallLibXext;
        errdefer library.close();
        const query = library.lookup(*const fn (*Display) callconv(.c) c_int, "XShmQueryExtension") orelse return error.MissingMitShm;
        if (query(self.display) == 0) return error.MissingMitShm;
        const info = try a.create(ShmInfo);
        errdefer a.destroy(info);
        info.* = .{};
        const screen = (try self.fnc(*const fn (*Display) callconv(.c) c_int, "XDefaultScreen"))(self.display);
        const visual = (try self.fnc(*const fn (*Display, c_int) callconv(.c) *anyopaque, "XDefaultVisual"))(self.display, screen);
        const depth = (try self.fnc(*const fn (*Display, c_int) callconv(.c) c_int, "XDefaultDepth"))(self.display, screen);
        const create = library.lookup(*const fn (*Display, *anyopaque, c_uint, c_int, ?[*]u8, *ShmInfo, c_uint, c_uint) callconv(.c) ?*Image, "XShmCreateImage") orelse return error.MissingMitShm;
        const image = create(self.display, visual, @intCast(depth), 2, null, info, @intCast(dimensions[0]), @intCast(dimensions[1])) orelse return error.MitShmCreateFailed;
        errdefer {
            image.data = null;
            _ = image.funcs.destroy(image);
        }
        if (image.bytes_per_line <= 0) return error.InvalidX11Image;
        const length = try std.math.mul(usize, @intCast(image.bytes_per_line), dimensions[1]);
        info.id = shm.shmget(shm.IPC_PRIVATE, length, shm.IPC_CREAT | 0o600);
        if (info.id < 0) return error.SharedMemoryUnavailable;
        defer _ = shm.shmctl(info.id, shm.IPC_RMID, null);
        const address = shm.shmat(info.id, null, 0);
        if (address == null or @intFromPtr(address.?) == std.math.maxInt(usize)) return error.SharedMemoryAttachFailed;
        info.address = @ptrCast(address);
        errdefer _ = shm.shmdt(address);
        image.data = info.address;
        const lock = try self.fnc(*const fn (*Display) callconv(.c) void, "XLockDisplay");
        const unlock = try self.fnc(*const fn (*Display) callconv(.c) void, "XUnlockDisplay");
        lock(self.display);
        defer unlock(self.display);
        const sync = try self.fnc(*const fn (*Display, c_int) callconv(.c) c_int, "XSync");
        _ = sync(self.display, 0);
        const Handler = *const fn (*Display, *anyopaque) callconv(.c) c_int;
        const set = try self.fnc(*const fn (?Handler) callconv(.c) ?Handler, "XSetErrorHandler");
        shm_error.store(false, .release);
        const old = set(onShmError);
        defer _ = set(old);
        const attach = library.lookup(*const fn (*Display, *ShmInfo) callconv(.c) c_int, "XShmAttach") orelse return error.MissingMitShm;
        const attached = attach(self.display, info);
        _ = sync(self.display, 0);
        if (attached == 0 or shm_error.load(.acquire)) return error.MitShmAttachRejected;
        self.shared_image = .{ .library = library, .image = image, .info = info, .allocator = a };
    }
    fn stopShm(self: *Backend) void {
        if (self.shared_image) |*shared| {
            if (shared.library.lookup(*const fn (*Display, *ShmInfo) callconv(.c) c_int, "XShmDetach")) |detach| _ = detach(self.display, shared.info);
            if (self.fnc(*const fn (*Display, c_int) callconv(.c) c_int, "XSync")) |sync| {
                _ = sync(self.display, 0);
            } else |_| {}
            shared.image.data = null;
            _ = shared.image.funcs.destroy(shared.image);
            if (shared.info.address) |address| _ = shm.shmdt(address);
            shared.allocator.destroy(shared.info);
            shared.library.close();
            self.shared_image = null;
        }
    }
    fn copyImage(image: *Image, frame: *Frame) !void {
        for (frame.pixels, 0..) |*p, i| {
            const pixel = image.funcs.get(image, @intCast(i % frame.width), @intCast(i / frame.width));
            for ([_]c_ulong{ image.red_mask, image.green_mask, image.blue_mask }, 0..) |mask, channel| {
                if (mask == 0) return error.UnsupportedX11PixelMask;
                const shift: std.math.Log2Int(c_ulong) = @intCast(@ctz(mask));
                p[channel] = @intCast(((pixel & mask) >> shift) * 255 / (mask >> shift));
            }
        }
    }
    pub fn capture(self: *Backend, a: std.mem.Allocator) !Frame {
        const dimensions = try self.size();
        var env = try std.process.getEnvMap(a);
        defer env.deinit();
        const mode = env.get("SSHDESK_X11_CAPTURE") orelse "auto";
        if (!std.mem.eql(u8, mode, "auto") and !std.mem.eql(u8, mode, "ffmpeg") and !std.mem.eql(u8, mode, "xshm") and !std.mem.eql(u8, mode, "x11") and !std.mem.eql(u8, mode, "pillow")) return error.InvalidX11CaptureMode;
        const want_ffmpeg = std.mem.eql(u8, mode, "auto") or std.mem.eql(u8, mode, "ffmpeg");
        if (want_ffmpeg and !self.ffmpeg_failed) {
            if (self.ffmpeg) |*stream| {
                if (stream.width != dimensions[0] or stream.height != dimensions[1]) {
                    stream.deinit();
                    self.ffmpeg = null;
                }
            }
            if (self.ffmpeg == null) self.ffmpeg = @import("ffmpeg.zig").Backend.init(a, env.get("DISPLAY") orelse ":0", dimensions[0], dimensions[1], self.fps) catch null;
            if (self.ffmpeg) |*stream| {
                if (stream.capture(a)) |frame| return frame else |err| {
                    stream.deinit();
                    self.ffmpeg = null;
                    self.ffmpeg_failed = true;
                    if (std.mem.eql(u8, mode, "ffmpeg")) return err;
                }
            } else {
                self.ffmpeg_failed = true;
                if (std.mem.eql(u8, mode, "ffmpeg")) return error.InstallFfmpegWithX11grab;
            }
        }
        var frame = try Frame.init(a, dimensions[0], dimensions[1]);
        errdefer frame.deinit();
        if (!std.mem.eql(u8, mode, "x11") and !std.mem.eql(u8, mode, "pillow") and !self.shm_failed) {
            if (self.shared_image) |shared| {
                if (shared.image.width != dimensions[0] or shared.image.height != dimensions[1]) self.stopShm();
            }
            if (self.shared_image == null) self.startShm(a, dimensions) catch {
                self.shm_failed = true;
            };
            if (self.shared_image) |*shared| {
                const get = shared.library.lookup(*const fn (*Display, c_ulong, *Image, c_int, c_int, c_ulong) callconv(.c) c_int, "XShmGetImage") orelse return error.MissingMitShm;
                if (get(self.display, self.root, shared.image, 0, 0, std.math.maxInt(c_ulong)) != 0) {
                    try copyImage(shared.image, &frame);
                    return frame;
                }
                self.stopShm();
                self.shm_failed = true;
            }
            if (std.mem.eql(u8, mode, "xshm") and self.shm_failed) return error.MitShmCaptureUnavailable;
        }
        const image = (try self.fnc(*const fn (*Display, c_ulong, c_int, c_int, c_uint, c_uint, c_ulong, c_int) callconv(.c) ?*Image, "XGetImage"))(self.display, self.root, 0, 0, @intCast(frame.width), @intCast(frame.height), std.math.maxInt(c_ulong), 2) orelse return error.X11CaptureFailed;
        defer _ = image.funcs.destroy(image);
        try copyImage(image, &frame);
        return frame;
    }
    fn keycode(self: *Backend, code: u8, down: bool) !void {
        const call = self.xtest.?.lookup(*const fn (*Display, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeKeyEvent") orelse return error.MissingXTest;
        if (call(self.display, code, @intFromBool(down), 0) == 0) return error.X11InputFailed;
    }
    pub fn key(self: *Backend, k: input.KeyEvent) !void {
        try self.checkInput();
        const codefn = try self.fnc(*const fn (*Display, c_ulong) callconv(.c) u8, "XKeysymToKeycode");
        const code = codefn(self.display, input.keysym(k));
        if (code == 0) return;
        var modifier_bits = k.modifiers;
        if (k.key == .character) {
            const symbol = input.keysym(k);
            const lookup = try self.fnc(*const fn (*Display, u8, c_int) callconv(.c) c_ulong, "XKeycodeToKeysym");
            if (lookup(self.display, code, 1) == symbol or lookup(self.display, code, 3) == symbol) modifier_bits |= 1;
        }
        const modifiers = [_]c_ulong{ 0xffe1, 0xffe9, 0xffe3 };
        var pressed = [_]u8{ 0, 0, 0 };
        defer {
            for (pressed) |p| if (p != 0) {
                self.keycode(p, false) catch {};
            };
            self.flush() catch {};
        }
        for (modifiers, 0..) |sym, i| if (modifier_bits & (@as(u3, 1) << @intCast(i)) != 0) {
            const c = codefn(self.display, sym);
            if (c != 0) {
                try self.keycode(c, true);
                pressed[i] = c;
            }
        };
        if (k.action != 1) try self.keycode(code, true);
        if (k.action != 0) try self.keycode(code, false);
    }
    pub fn move(self: *Backend, x: i32, y: i32) !void {
        try self.checkInput();
        const call = self.xtest.?.lookup(*const fn (*Display, c_int, c_int, c_int, c_ulong) callconv(.c) c_int, "XTestFakeMotionEvent") orelse return error.MissingXTest;
        if (call(self.display, -1, @max(0, x), @max(0, y), 0) == 0) return error.X11InputFailed;
        try self.flush();
    }
    pub fn button(self: *Backend, number: u8, down: bool, x: i32, y: i32) !void {
        try self.move(x, y);
        const call = self.xtest.?.lookup(*const fn (*Display, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeButtonEvent") orelse return error.MissingXTest;
        if (call(self.display, number, @intFromBool(down), 0) == 0) return error.X11InputFailed;
        if (number >= 1 and number <= 3) self.held[number - 1] = down;
        try self.flush();
    }
    pub fn scroll(self: *Backend, amount: i32, x: i32, y: i32) !void {
        for (0..@abs(std.math.clamp(amount, -20, 20))) |_| {
            try self.button(if (amount > 0) 4 else 5, true, x, y);
            try self.button(if (amount > 0) 4 else 5, false, x, y);
        }
    }
    pub fn deinit(self: *Backend) void {
        self.stopShm();
        if (self.ffmpeg) |*stream| stream.deinit();
        for (self.held, 0..) |held, i| if (held) {
            self.button(@intCast(i + 1), false, 0, 0) catch {};
        };
        if (self.lib.lookup(*const fn (*Display) callconv(.c) c_int, "XCloseDisplay")) |close| _ = close(self.display);
        if (self.xtest) |*lib| lib.close();
        self.lib.close();
    }
};
