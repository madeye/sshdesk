const std = @import("std");
const Frame = @import("frame.zig").Frame;
// libpng simplified API (png_image, version 1), linked from pinned source.
const Image = extern struct {
    @"opaque": ?*anyopaque = null,
    version: u32 = 1,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 2,
    flags: u32 = 0,
    colormap_entries: u32 = 0,
    warning_or_error: u32 = 0,
    message: [64]u8 = @splat(0),
};
extern fn png_image_begin_read_from_memory(*Image, [*]const u8, usize) c_int;
extern fn png_image_finish_read(*Image, ?*const anyopaque, [*]u8, i32, ?*anyopaque) c_int;
extern fn png_image_write_to_memory(*Image, ?[*]u8, *usize, c_int, [*]const u8, i32, ?*const anyopaque) c_int;
extern fn png_image_free(*Image) void;
pub const Png = struct {
    begin: *const fn (*Image, [*]const u8, usize) callconv(.c) c_int = png_image_begin_read_from_memory,
    finish: *const fn (*Image, ?*const anyopaque, [*]u8, i32, ?*anyopaque) callconv(.c) c_int = png_image_finish_read,
    write: *const fn (*Image, ?[*]u8, *usize, c_int, [*]const u8, i32, ?*const anyopaque) callconv(.c) c_int = png_image_write_to_memory,
    free: *const fn (*Image) callconv(.c) void = png_image_free,
    pub fn init() !Png {
        return .{};
    }
    pub fn deinit(_: *Png) void {}
    pub fn encode(self: Png, a: std.mem.Allocator, frame: Frame) ![]u8 {
        var image: Image = .{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
        defer self.free(&image);
        var size: usize = 0;
        const data = std.mem.sliceAsBytes(frame.pixels);
        if (self.write(&image, null, &size, 0, data.ptr, 0, null) == 0) return error.PngEncodeFailed;
        const bytes = try a.alloc(u8, size);
        errdefer a.free(bytes);
        if (self.write(&image, bytes.ptr, &size, 0, data.ptr, 0, null) == 0) return error.PngEncodeFailed;
        return try a.realloc(bytes, size);
    }
    pub fn encodePalette(self: Png, a: std.mem.Allocator, frame: Frame) ![]u8 {
        // Deterministic 2/3/2-bit palette; no dependency on image-library quantizers.
        var palette: [128][3]u8 = undefined;
        for (&palette, 0..) |*rgb, i| rgb.* = .{ @intCast(((i >> 5) & 3) * 255 / 3), @intCast(((i >> 2) & 7) * 255 / 7), @intCast((i & 3) * 255 / 3) };
        const indices = try a.alloc(u8, frame.pixels.len);
        defer a.free(indices);
        for (frame.pixels, indices) |rgb, *index| index.* = @intCast(((@as(u16, rgb[0]) * 3 + 127) / 255) << 5 | ((@as(u16, rgb[1]) * 7 + 127) / 255) << 2 | ((@as(u16, rgb[2]) * 3 + 127) / 255));
        var image: Image = .{ .width = @intCast(frame.width), .height = @intCast(frame.height), .format = 10, .colormap_entries = 128 };
        defer self.free(&image);
        var size: usize = 0;
        if (self.write(&image, null, &size, 0, indices.ptr, 0, &palette) == 0) return error.PngEncodeFailed;
        const bytes = try a.alloc(u8, size);
        errdefer a.free(bytes);
        if (self.write(&image, bytes.ptr, &size, 0, indices.ptr, 0, &palette) == 0) return error.PngEncodeFailed;
        return a.realloc(bytes, size);
    }
    pub fn decode(self: Png, a: std.mem.Allocator, bytes: []const u8) !Frame {
        var image: Image = .{};
        defer self.free(&image);
        if (bytes.len > 64 * 1024 * 1024 or self.begin(&image, bytes.ptr, bytes.len) == 0) return error.InvalidPng;
        image.format = 2;
        var frame = try Frame.init(a, image.width, image.height);
        errdefer frame.deinit();
        if (self.finish(&image, null, std.mem.sliceAsBytes(frame.pixels).ptr, 0, null) == 0) return error.InvalidPng;
        return frame;
    }
};
test "PNG roundtrip verifies decoded RGB pixels, malformed input" {
    var png = try Png.init();
    defer png.deinit();
    var frame = try Frame.init(std.testing.allocator, 3, 2);
    defer frame.deinit();
    frame.pixels[0] = .{ 255, 0, 0 };
    frame.pixels[1] = .{ 0, 255, 0 };
    frame.pixels[2] = .{ 0, 0, 255 };
    frame.pixels[3] = .{ 12, 34, 56 };
    frame.pixels[4] = .{ 0, 0, 0 };
    frame.pixels[5] = .{ 255, 255, 255 };
    const bytes = try png.encode(std.testing.allocator, frame);
    defer std.testing.allocator.free(bytes);
    var decoded = try png.decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(frame.pixels), std.mem.sliceAsBytes(decoded.pixels));
    try std.testing.expectError(error.InvalidPng, png.decode(std.testing.allocator, "bad png"));
}
