const std = @import("std");
const builtin = @import("builtin");
pub const Span = extern struct { first: u32, length: u32, offset: u32, error_bound: u32 };
extern fn sshdesk_metal_create([*:0]const u8) ?*anyopaque;
extern fn sshdesk_metal_destroy(*anyopaque) void;
extern fn sshdesk_metal_pass(*anyopaque, [*]const u8, usize, [*]const Span, usize, [*]const u32, usize, [*][4]u8, u32, u32, u32, u32) c_int;
extern fn sshdesk_vulkan_create([*]const u32, usize, c_int) ?*anyopaque;
extern fn sshdesk_vulkan_destroy(*anyopaque) void;
extern fn sshdesk_vulkan_pass(*anyopaque, [*]const u8, usize, [*]const Span, usize, [*]const u32, usize, [*][4]u8, u32, u32, u32, u32) c_int;
const has_vulkan = builtin.os.tag == .linux or builtin.os.tag == .windows;
const spirv align(4) = @embedFile("gpu/resize.spv").*;
pub const Backend = enum(u8) { cpu, metal, vulkan };
const Mode = enum { auto, cpu, metal, vulkan };
// Fault injection is compiled out of production executables.
pub var testing_reject_passes = false;
pub var testing_rejected_passes: usize = 0;
pub var testing_completed_passes = std.atomic.Value(usize).init(0);
var mutex: std.Thread.Mutex = .{};
var context: ?*anyopaque = null;
var attempted = false;
var selected: Backend = .cpu;
var used = std.atomic.Value(Backend).init(.cpu);
pub fn active() bool {
    return used.load(.acquire) != .cpu;
}
pub fn backendName() []const u8 {
    return @tagName(used.load(.acquire));
}
fn mode() Mode {
    if (builtin.os.tag != .windows) {
        return parseMode(std.posix.getenv("SSHDESK_RESIZE") orelse "auto");
    }
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "SSHDESK_RESIZE") catch return .auto;
    defer std.heap.page_allocator.free(value);
    return parseMode(value);
}
fn parseMode(value: []const u8) Mode {
    return std.meta.stringToEnum(Mode, value) orelse .cpu;
}
fn backend(requested: Mode) Backend {
    return switch (requested) {
        .cpu => .cpu,
        .metal => if (builtin.os.tag == .macos) .metal else .cpu,
        .vulkan => if (has_vulkan) .vulkan else .cpu,
        .auto => if (builtin.os.tag == .macos) .metal else if (has_vulkan) .vulkan else .cpu,
    };
}
pub fn enabled() bool {
    const requested = mode();
    return requested != .auto and backend(requested) != .cpu;
}
pub fn shouldUse(source_pixels: usize, target_pixels: usize) bool {
    const requested = mode();
    if (backend(requested) == .cpu) return false;
    if (builtin.is_test) return requested != .auto;
    return requested != .auto or (source_pixels >= 512 * 512 and target_pixels < source_pixels);
}
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    if (context) |ctx| switch (selected) {
        .metal => if (builtin.os.tag == .macos) sshdesk_metal_destroy(ctx),
        .vulkan => if (has_vulkan) sshdesk_vulkan_destroy(ctx),
        .cpu => {},
    };
    context = null;
    attempted = false;
    selected = .cpu;
    used.store(.cpu, .release);
    if (builtin.is_test) testing_completed_passes.store(0, .release);
}
pub fn pass(source: []const u8, spans: []const Span, weights: []const u32, output: [][4]u8, source_width: usize, width: usize, height: usize, vertical: bool) bool {
    if (builtin.is_test and testing_reject_passes) {
        testing_rejected_passes += 1;
        // Simulate a failed dispatch leaving unusable partial output behind.
        @memset(std.mem.sliceAsBytes(output), 0xff);
        return false;
    }
    mutex.lock();
    defer mutex.unlock();
    if (!attempted) {
        attempted = true;
        const requested = mode();
        selected = backend(requested);
        context = switch (selected) {
            .metal => if (builtin.os.tag == .macos) sshdesk_metal_create(@embedFile("gpu/resize.metal")) else null,
            .vulkan => if (has_vulkan) sshdesk_vulkan_create(@ptrCast(&spirv), spirv.len, @intFromBool(requested == .vulkan)) else null,
            .cpu => null,
        };
    }
    const ctx = context orelse return false;
    const ok = switch (selected) {
        .metal => if (builtin.os.tag == .macos) sshdesk_metal_pass(ctx, source.ptr, source.len, spans.ptr, spans.len * @sizeOf(Span), weights.ptr, weights.len * 4, output.ptr, @intCast(source_width), @intCast(width), @intCast(height), @intFromBool(vertical)) != 0 else false,
        .vulkan => if (has_vulkan) sshdesk_vulkan_pass(ctx, source.ptr, source.len, spans.ptr, spans.len * @sizeOf(Span), weights.ptr, weights.len * 4, output.ptr, @intCast(source_width), @intCast(width), @intCast(height), @intFromBool(vertical)) != 0 else false,
        .cpu => false,
    };
    if (ok) {
        used.store(selected, .release);
        if (builtin.is_test) _ = testing_completed_passes.fetchAdd(1, .acq_rel);
    }
    return ok;
}

test "backend selection honors CPU override and platform availability" {
    try std.testing.expectEqual(Backend.cpu, backend(.cpu));
    try std.testing.expectEqual(Mode.cpu, parseMode("unknown"));
    try std.testing.expectEqual(Mode.vulkan, parseMode("vulkan"));
    try std.testing.expectEqual(if (builtin.os.tag == .macos) Backend.metal else Backend.cpu, backend(.metal));
    try std.testing.expectEqual(if (has_vulkan) Backend.vulkan else Backend.cpu, backend(.vulkan));
    try std.testing.expectEqual(if (builtin.os.tag == .macos) Backend.metal else if (has_vulkan) Backend.vulkan else Backend.cpu, backend(.auto));
}
