const std = @import("std");
const Allocator = std.mem.Allocator;
pub const RGB = [3]u8;
pub const Frame = struct {
    allocator: Allocator,
    width: usize,
    height: usize,
    pixels: []RGB,
    captured_ns: i128,
    generation: u64 = 0,
    desktop_width: usize = 0,
    desktop_height: usize = 0,
    pub fn desktopSize(self: Frame) [2]usize {
        return .{ if (self.desktop_width > 0) self.desktop_width else self.width, if (self.desktop_height > 0) self.desktop_height else self.height };
    }
    pub fn init(a: Allocator, width: usize, height: usize) !Frame {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
        return .{ .allocator = a, .width = width, .height = height, .pixels = try a.alloc(RGB, try std.math.mul(usize, width, height)), .captured_ns = std.time.nanoTimestamp() };
    }
    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
    pub fn fingerprint(self: Frame) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&self.width));
        hash.update(std.mem.asBytes(&self.height));
        const desktop = self.desktopSize();
        hash.update(std.mem.asBytes(&desktop));
        hash.update(std.mem.sliceAsBytes(self.pixels));
        return hash.final();
    }
    pub fn resize(self: Frame, a: Allocator, width: usize, height: usize) !Frame {
        var out = try Frame.init(a, width, height);
        out.captured_ns = self.captured_ns;
        out.generation = self.generation;
        const desktop = self.desktopSize();
        out.desktop_width = desktop[0];
        out.desktop_height = desktop[1];
        errdefer out.deinit();
        if (width == self.width and height == self.height) {
            @memcpy(out.pixels, self.pixels);
            return out;
        }
        var horizontal = try Frame.init(a, width, self.height);
        defer horizontal.deinit();
        const sx = @as(f64, @floatFromInt(self.width)) / @as(f64, @floatFromInt(width));
        const fx = @max(1, sx);
        for (0..width) |x| {
            const center = (@as(f64, @floatFromInt(x)) + 0.5) * sx;
            const first: usize = @intFromFloat(@max(0, @floor(center - fx + 0.5)));
            const end: usize = @intFromFloat(@min(@as(f64, @floatFromInt(self.width)), @floor(center + fx + 0.5)));
            for (0..self.height) |y| {
                var total: f64 = 0;
                var sum = [_]f64{ 0, 0, 0 };
                for (first..end) |i| {
                    const weight = @max(0, 1 - @abs((@as(f64, @floatFromInt(i)) + 0.5 - center) / fx));
                    total += weight;
                    for (0..3) |c| sum[c] += @as(f64, @floatFromInt(self.pixels[y * self.width + i][c])) * weight;
                }
                for (0..3) |c| horizontal.pixels[y * width + x][c] = @intFromFloat(std.math.clamp(@round(sum[c] / total), 0, 255));
            }
        }
        const sy = @as(f64, @floatFromInt(self.height)) / @as(f64, @floatFromInt(height));
        const fy = @max(1, sy);
        for (0..height) |y| {
            const center = (@as(f64, @floatFromInt(y)) + 0.5) * sy;
            const first: usize = @intFromFloat(@max(0, @floor(center - fy + 0.5)));
            const end: usize = @intFromFloat(@min(@as(f64, @floatFromInt(self.height)), @floor(center + fy + 0.5)));
            for (0..width) |x| {
                var total: f64 = 0;
                var sum = [_]f64{ 0, 0, 0 };
                for (first..end) |i| {
                    const weight = @max(0, 1 - @abs((@as(f64, @floatFromInt(i)) + 0.5 - center) / fy));
                    total += weight;
                    for (0..3) |c| sum[c] += @as(f64, @floatFromInt(horizontal.pixels[i * width + x][c])) * weight;
                }
                for (0..3) |c| out.pixels[y * width + x][c] = @intFromFloat(std.math.clamp(@round(sum[c] / total), 0, 255));
            }
        }
        return out;
    }
};
pub fn synthetic(a: Allocator, width: usize, height: usize, number: ?usize) !Frame {
    const f = try Frame.init(a, width, height);
    for (f.pixels, 0..) |*pixel, i| {
        const x = i % width;
        const y = i / width;
        pixel.* = if (y < @max(12, height / 18)) .{ 35, 42, 55 } else if (x >= width / 10 and x <= width / 2 and y >= height / 8 and y <= height / 2) .{ 43, 108, 176 } else if (x >= width / 20 and x < width - width / 20 and y >= height / 8 and y < height - height / 16) .{ 48, 57, 73 } else .{ 18, 22, 30 };
        if (number) |n| {
            const r = @max(3, @min(width, height) / 30);
            const cx: i64 = @intCast((n *% 13) % width);
            const cy: i64 = @intCast(height -| (height / 8 + r));
            const dx = @as(i64, @intCast(x)) - cx;
            const dy = @as(i64, @intCast(y)) - cy;
            if (dx * dx + dy * dy <= r * r) pixel.* = .{ 238, 127, 74 };
        }
    }
    return f;
}
test "owned frames, stable fingerprints, bilinear pixels and invalid dimensions" {
    const a = std.testing.allocator;
    var f = try Frame.init(a, 2, 2);
    defer f.deinit();
    @memset(f.pixels, .{ 12, 34, 56 });
    var resized = try f.resize(a, 7, 9);
    defer resized.deinit();
    for (resized.pixels) |p| try std.testing.expectEqual(RGB{ 12, 34, 56 }, p);
    try std.testing.expectEqual(f.fingerprint(), f.fingerprint());
    try std.testing.expectError(error.InvalidDimensions, Frame.init(a, 0, 1));
    try std.testing.expectError(error.InvalidDimensions, Frame.init(a, 16385, 1));
}
fn allocationScenario(a: Allocator) !void {
    var f = try synthetic(a, 16, 9, null);
    defer f.deinit();
    var small = try f.resize(a, 4, 3);
    defer small.deinit();
}
test "frame allocation failures release ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "downsampling filters alternating pixels instead of aliasing" {
    var f = try Frame.init(std.testing.allocator, 4, 1);
    defer f.deinit();
    f.pixels[0] = .{ 0, 0, 0 };
    f.pixels[1] = .{ 255, 255, 255 };
    f.pixels[2] = .{ 0, 0, 0 };
    f.pixels[3] = .{ 255, 255, 255 };
    var tiny = try f.resize(std.testing.allocator, 1, 1);
    defer tiny.deinit();
    try std.testing.expectEqual(RGB{ 128, 128, 128 }, tiny.pixels[0]);
}
