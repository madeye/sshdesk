const std = @import("std");
const builtin = @import("builtin");
pub const Span = extern struct { first: u32, length: u32, offset: u32, error_bound: u32 };
extern fn sshdesk_metal_create([*:0]const u8) ?*anyopaque;
extern fn sshdesk_metal_destroy(*anyopaque) void;
extern fn sshdesk_metal_pass(*anyopaque, [*]const u8, usize, [*]const Span, usize, [*]const u32, usize, [*][4]u8, u32, u32, u32, u32) c_int;
var mutex: std.Thread.Mutex = .{};
var context: ?*anyopaque = null;
var attempted = false;
var used = std.atomic.Value(bool).init(false);
pub fn active() bool {
    return used.load(.acquire);
}
pub fn enabled() bool {
    if (builtin.os.tag != .macos) return false;
    const mode = std.posix.getenv("SSHDESK_RESIZE") orelse return false;
    return std.mem.eql(u8, mode, "metal");
}
pub fn shouldUse(source_pixels: usize, target_pixels: usize) bool {
    if (builtin.os.tag != .macos) return false;
    if (builtin.is_test) return enabled();
    const mode = std.posix.getenv("SSHDESK_RESIZE") orelse "auto";
    if (std.mem.eql(u8, mode, "metal")) return true;
    return std.mem.eql(u8, mode, "auto") and source_pixels >= 512 * 512 and target_pixels < source_pixels;
}
pub fn deinit() void {
    if (builtin.os.tag != .macos) return;
    mutex.lock();
    defer mutex.unlock();
    if (context) |ctx| sshdesk_metal_destroy(ctx);
    context = null;
    attempted = false;
    used.store(false, .release);
}
pub fn pass(source: []const u8, spans: []const Span, weights: []const u32, output: [][4]u8, source_width: usize, width: usize, height: usize, vertical: bool) bool {
    if (builtin.os.tag != .macos) return false;
    mutex.lock();
    defer mutex.unlock();
    if (!attempted) {
        attempted = true;
        context = sshdesk_metal_create(@embedFile("gpu/resize.metal"));
    }
    const ctx = context orelse return false;
    const ok = sshdesk_metal_pass(ctx, source.ptr, source.len, spans.ptr, spans.len * @sizeOf(Span), weights.ptr, weights.len * 4, output.ptr, @intCast(source_width), @intCast(width), @intCast(height), @intFromBool(vertical)) != 0;
    if (ok) used.store(true, .release);
    return ok;
}
