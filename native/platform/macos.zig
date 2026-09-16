const std = @import("std");
const Frame = @import("../frame.zig").Frame;
const KeyEvent = @import("../input.zig").KeyEvent;
const Point = extern struct { x: f64, y: f64 };
const Rect = extern struct { origin: Point, size: extern struct { width: f64, height: f64 } };
pub const Backend = struct {
    cg: std.DynLib,
    cf: std.DynLib,
    app: std.DynLib,
    held: [3]bool = @splat(false),
    lookup_override: ?*const fn ([]const u8, []const u8) ?*const anyopaque = null,
    position: Point = .{ .x = 0, .y = 0 },
    pub fn init() !Backend {
        var cg = try std.DynLib.open("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics");
        errdefer cg.close();
        var cf = try std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
        errdefer cf.close();
        const app = try std.DynLib.open("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices");
        return .{ .cg = cg, .cf = cf, .app = app };
    }
    fn fnc(self: *Backend, comptime T: type, comptime name: [:0]const u8) !T {
        if (self.lookup_override) |lookup| return @ptrCast(@alignCast(lookup("cg", name) orelse return error.MissingCoreGraphicsAPI));
        return self.cg.lookup(T, name) orelse error.MissingCoreGraphicsAPI;
    }
    fn release(self: *Backend, value: *anyopaque) void {
        const Call = *const fn (*anyopaque) callconv(.c) void;
        const call: Call = if (self.lookup_override) |lookup| @ptrCast(@alignCast(lookup("cf", "CFRelease") orelse return)) else self.cf.lookup(Call, "CFRelease") orelse return;
        call(value);
    }
    pub fn checkInput(self: *Backend) !void {
        const Call = *const fn () callconv(.c) bool;
        const trusted: Call = if (self.lookup_override) |lookup| @ptrCast(@alignCast(lookup("app", "AXIsProcessTrusted") orelse return error.MissingAccessibilityAPI)) else self.app.lookup(Call, "AXIsProcessTrusted") orelse return error.MissingAccessibilityAPI;
        if (!trusted()) return error.GrantAccessibilityPermissionToInstalledExecutable;
    }
    pub fn capture(self: *Backend, a: std.mem.Allocator) !Frame {
        const permitted = try self.fnc(*const fn () callconv(.c) bool, "CGPreflightScreenCaptureAccess");
        if (!permitted()) return error.GrantScreenRecordingPermissionToInstalledExecutable;
        const main = try self.fnc(*const fn () callconv(.c) u32, "CGMainDisplayID");
        const create = try self.fnc(*const fn (u32) callconv(.c) ?*anyopaque, "CGDisplayCreateImage");
        const image = create(main()) orelse return error.DesktopCaptureFailedCheckScreenRecordingPermission;
        defer self.release(image);
        const width = (try self.fnc(*const fn (*anyopaque) callconv(.c) usize, "CGImageGetWidth"))(image);
        const height = (try self.fnc(*const fn (*anyopaque) callconv(.c) usize, "CGImageGetHeight"))(image);
        // Draw into a known RGBA layout instead of assuming the display's byte order.
        const color = (try self.fnc(*const fn () callconv(.c) ?*anyopaque, "CGColorSpaceCreateDeviceRGB"))() orelse return error.DesktopCaptureFailed;
        defer self.release(color);
        var frame = try Frame.init(a, width, height);
        errdefer frame.deinit();
        const raw = try a.alloc(u8, width * height * 4);
        defer a.free(raw);
        const context = (try self.fnc(*const fn ([*]u8, usize, usize, usize, usize, *anyopaque, u32) callconv(.c) ?*anyopaque, "CGBitmapContextCreate"))(raw.ptr, width, height, 8, width * 4, color, 0x4001) orelse return error.DesktopCaptureFailed;
        defer self.release(context);
        (try self.fnc(*const fn (*anyopaque, Rect, *anyopaque) callconv(.c) void, "CGContextDrawImage"))(context, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) } }, image);
        for (frame.pixels, 0..) |*p, i| p.* = raw[i * 4 ..][0..3].*;
        const logical_width = (try self.fnc(*const fn (u32) callconv(.c) usize, "CGDisplayPixelsWide"))(main());
        const logical_height = (try self.fnc(*const fn (u32) callconv(.c) usize, "CGDisplayPixelsHigh"))(main());
        if (logical_width > 0 and logical_height > 0 and (logical_width != width or logical_height != height)) {
            var logical = try frame.resize(a, logical_width, logical_height);
            logical.desktop_width = logical_width;
            logical.desktop_height = logical_height;
            frame.deinit();
            return logical;
        }
        return frame;
    }
    fn post(self: *Backend, event: ?*anyopaque) !void {
        const e = event orelse return error.InputEventCreationFailed;
        defer self.release(e);
        (try self.fnc(*const fn (u32, *anyopaque) callconv(.c) void, "CGEventPost"))(0, e);
    }
    pub fn key(self: *Backend, k: KeyEvent) !void {
        const code: u16 = switch (k.key) {
            .character => 0,
            .enter => 36,
            .tab => 48,
            .backspace => 51,
            .escape => 53,
            .home => 115,
            .end => 119,
            .page_up => 116,
            .page_down => 121,
            .delete => 117,
            .left => 123,
            .right => 124,
            .down => 125,
            .up => 126,
            .f1 => 122,
            .f2 => 120,
            .f3 => 99,
            .f4 => 118,
            .f5 => 96,
            .f6 => 97,
            .f7 => 98,
            .f8 => 100,
            .f9 => 101,
            .f10 => 109,
            .f11 => 103,
            .f12 => 111,
            .insert => 114,
        };
        const create = try self.fnc(*const fn (?*anyopaque, u16, bool) callconv(.c) ?*anyopaque, "CGEventCreateKeyboardEvent");
        const unicode = try self.fnc(*const fn (*anyopaque, usize, [*]const u16) callconv(.c) void, "CGEventKeyboardSetUnicodeString");
        const flags = try self.fnc(*const fn (*anyopaque, u64) callconv(.c) void, "CGEventSetFlags");
        for ([_]bool{ true, false }) |down| {
            if ((k.action == 0 and !down) or (k.action == 1 and down)) continue;
            const e = create(null, code, down) orelse return error.InputEventCreationFailed;
            errdefer self.release(e);
            if (k.key == .character) {
                var units: [2]u16 = undefined;
                const n: usize = if (k.unicode <= 0xffff) blk: {
                    units[0] = @intCast(k.unicode);
                    break :blk 1;
                } else blk: {
                    const value = k.unicode - 0x10000;
                    units[0] = @intCast(0xd800 + (value >> 10));
                    units[1] = @intCast(0xdc00 + (value & 0x3ff));
                    break :blk 2;
                };
                unicode(e, n, &units);
            }
            flags(e, (@as(u64, if (k.modifiers & 1 != 0) 1 else 0) << 17) | (@as(u64, if (k.modifiers & 2 != 0) 1 else 0) << 19) | (@as(u64, if (k.modifiers & 4 != 0) 1 else 0) << 18));
            // post owns the event even on error.
            (try self.fnc(*const fn (u32, *anyopaque) callconv(.c) void, "CGEventPost"))(0, e);
            self.release(e);
        }
    }
    pub fn move(self: *Backend, x: i32, y: i32) !void {
        self.position = .{ .x = @floatFromInt(@max(0, x)), .y = @floatFromInt(@max(0, y)) };
        const kind: u32 = if (self.held[0]) 6 else if (self.held[2]) 7 else if (self.held[1]) 27 else 5;
        const create = try self.fnc(*const fn (?*anyopaque, u32, Point, u32) callconv(.c) ?*anyopaque, "CGEventCreateMouseEvent");
        try self.post(create(null, kind, self.position, 0));
    }
    pub fn button(self: *Backend, number: u8, down: bool, x: i32, y: i32) !void {
        if (number < 1 or number > 3) return error.InvalidButton;
        self.position = .{ .x = @floatFromInt(@max(0, x)), .y = @floatFromInt(@max(0, y)) };
        const create = try self.fnc(*const fn (?*anyopaque, u32, Point, u32) callconv(.c) ?*anyopaque, "CGEventCreateMouseEvent");
        const kind: u32 = switch (number) {
            1 => if (down) 1 else 2,
            2 => if (down) 25 else 26,
            else => if (down) 3 else 4,
        };
        try self.post(create(null, kind, self.position, if (number == 1) 0 else if (number == 2) 2 else 1));
        self.held[number - 1] = down;
    }
    pub fn scroll(self: *Backend, amount: i32, x: i32, y: i32) !void {
        try self.move(x, y);
        const create = try self.fnc(*const fn (?*anyopaque, u32, u32, ...) callconv(.c) ?*anyopaque, "CGEventCreateScrollWheelEvent");
        try self.post(create(null, 1, 1, @as(c_int, std.math.clamp(amount, -20, 20))));
    }
    pub fn deinit(self: *Backend) void {
        for (self.held, 0..) |held, i| if (held) {
            self.button(@intCast(i + 1), false, @intFromFloat(self.position.x), @intFromFloat(self.position.y)) catch {};
        };
        if (self.lookup_override != null) return;
        self.app.close();
        self.cf.close();
        self.cg.close();
    }
};

const Mock = struct {
    var permitted = true;
    var trusted = true;
    var missing_trust = false;
    var missing_image = false;
    var logical_size: usize = 2;
    fn access() callconv(.c) bool {
        return permitted;
    }
    fn trust() callconv(.c) bool {
        return trusted;
    }
    fn mainDisplay() callconv(.c) u32 {
        return 1;
    }
    fn displayImage(_: u32) callconv(.c) ?*anyopaque {
        return if (missing_image) null else @ptrFromInt(1);
    }
    fn imageSize(_: *anyopaque) callconv(.c) usize {
        return 2;
    }
    fn logical(_: u32) callconv(.c) usize {
        return logical_size;
    }
    fn color() callconv(.c) ?*anyopaque {
        return @ptrFromInt(2);
    }
    fn context(raw: [*]u8, _: usize, _: usize, _: usize, _: usize, _: *anyopaque, _: u32) callconv(.c) ?*anyopaque {
        @memcpy(raw[0..16], &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 });
        return @ptrFromInt(3);
    }
    fn draw(_: *anyopaque, _: Rect, _: *anyopaque) callconv(.c) void {}
    fn release(_: *anyopaque) callconv(.c) void {}
    fn lookup(domain: []const u8, name: []const u8) ?*const anyopaque {
        if (std.mem.eql(u8, domain, "app")) return if (missing_trust) null else @ptrCast(&trust);
        if (std.mem.eql(u8, domain, "cf")) return @ptrCast(&release);
        const names = .{ "CGPreflightScreenCaptureAccess", "CGMainDisplayID", "CGDisplayCreateImage", "CGImageGetWidth", "CGImageGetHeight", "CGDisplayPixelsWide", "CGDisplayPixelsHigh", "CGColorSpaceCreateDeviceRGB", "CGBitmapContextCreate", "CGContextDrawImage" };
        const pointers = .{ &access, &mainDisplay, &displayImage, &imageSize, &imageSize, &logical, &logical, &color, &context, &draw };
        inline for (names, pointers) |candidate, pointer| if (std.mem.eql(u8, name, candidate)) return @ptrCast(pointer);
        return null;
    }
};
test "CoreGraphics capture keeps RGB pixels and converts Retina image to logical coordinates" {
    var backend: Backend = .{ .cg = undefined, .cf = undefined, .app = undefined, .lookup_override = Mock.lookup };
    defer backend.deinit();
    Mock.permitted = true;
    Mock.missing_image = false;
    for ([_]usize{ 2, 1 }) |size| {
        Mock.logical_size = size;
        var frame = try backend.capture(std.testing.allocator);
        defer frame.deinit();
        try std.testing.expectEqual([2]usize{ size, size }, frame.desktopSize());
        try std.testing.expectEqual(size, frame.width);
        try std.testing.expectEqual([3]u8{ if (size == 1) 128 else 255, if (size == 1) 128 else 0, if (size == 1) 128 else 0 }, frame.pixels[0]);
    }
}
test "macOS permission checks use ApplicationServices and identify installed executable" {
    var backend: Backend = .{ .cg = undefined, .cf = undefined, .app = undefined, .lookup_override = Mock.lookup };
    defer backend.deinit();
    Mock.missing_trust = false;
    Mock.trusted = true;
    try backend.checkInput();
    Mock.trusted = false;
    try std.testing.expectError(error.GrantAccessibilityPermissionToInstalledExecutable, backend.checkInput());
    Mock.missing_trust = true;
    try std.testing.expectError(error.MissingAccessibilityAPI, backend.checkInput());
    Mock.permitted = false;
    try std.testing.expectError(error.GrantScreenRecordingPermissionToInstalledExecutable, backend.capture(std.testing.allocator));
    Mock.permitted = true;
    Mock.missing_image = true;
    try std.testing.expectError(error.DesktopCaptureFailedCheckScreenRecordingPermission, backend.capture(std.testing.allocator));
    Mock.missing_image = false;
}
