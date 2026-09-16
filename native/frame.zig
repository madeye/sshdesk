const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu = @import("gpu.zig");
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
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
        return self.resizeImpl(a, width, height, gpu.shouldUse(self.pixels.len, width * height));
    }
    fn resizeImpl(self: Frame, a: Allocator, width: usize, height: usize, want_gpu: bool) !Frame {
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
        var horizontal_filter = try Filter.init(a, self.width, width);
        defer horizontal_filter.deinit(a);
        var vertical_filter = try Filter.init(a, self.height, height);
        defer vertical_filter.deinit(a);
        // Traverse source and destination rows contiguously. Coefficients depend
        // only on geometry, so compute them once rather than for every row.
        if (!(want_gpu and horizontal_filter.applyGpu(a, self.pixels, self.width, width, self.height, false, horizontal.pixels))) for (0..self.height) |y| {
            const source = self.pixels[y * self.width ..][0..self.width];
            for (horizontal_filter.spans, 0..) |span, x| {
                horizontal.pixels[y * width + x] = horizontal_filter.apply(span, source, 1);
            }
        };
        if (!(want_gpu and vertical_filter.applyGpu(a, horizontal.pixels, width, width, height, true, out.pixels))) for (vertical_filter.spans, 0..) |span, y| {
            for (0..width) |x| out.pixels[y * width + x] = vertical_filter.apply(span, horizontal.pixels[x..], width);
        };
        return out;
    }
};
fn channel(sum: f64, total: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(sum / total), 0, 255));
}
const Filter = struct {
    const unit: u32 = 1 << 22;
    const Span = struct { first: usize, len: usize, offset: usize, total: f64, error_bound: u32 = 0 };
    spans: []Span,
    weights: []f64,
    fixed: []u32,
    fn init(a: Allocator, source: usize, target: usize) !Filter {
        const spans = try a.alloc(Span, target);
        errdefer a.free(spans);
        const scale = @as(f64, @floatFromInt(source)) / @as(f64, @floatFromInt(target));
        const support = @max(1, scale);
        const stride = @min(source, @as(usize, @intFromFloat(@ceil(2 * support))) + 1);
        const weights = try a.alloc(f64, target * stride);
        errdefer a.free(weights);
        const fixed = try a.alloc(u32, weights.len);
        errdefer a.free(fixed);
        @memset(fixed, 0);
        for (spans, 0..) |*span, x| {
            const center = (@as(f64, @floatFromInt(x)) + 0.5) * scale;
            const first: usize = @intFromFloat(@max(0, @floor(center - support + 0.5)));
            const end: usize = @intFromFloat(@min(@as(f64, @floatFromInt(source)), @floor(center + support + 0.5)));
            span.* = .{ .first = first, .len = end - first, .offset = x * stride, .total = 0 };
            for (weights[span.offset..][0..span.len], first..) |*weight, i| {
                weight.* = @max(0, 1 - @abs((@as(f64, @floatFromInt(i)) + 0.5 - center) / support));
                span.total += weight.*;
            }
            // Quantize cumulative weights so every span sums to exactly unit:
            // constant colors stay constant, and accumulators cannot overflow.
            var cumulative: f64 = 0;
            var previous: u32 = 0;
            var error_sum: f64 = 0;
            for (weights[span.offset..][0..span.len], fixed[span.offset..][0..span.len]) |weight, *quantized| {
                cumulative += weight;
                const boundary: u32 = @intFromFloat(@round(cumulative / span.total * unit));
                quantized.* = boundary - previous;
                previous = boundary;
                error_sum += @abs(@as(f64, @floatFromInt(quantized.*)) - weight / span.total * unit);
            }
            // Absolute error for any 8-bit channel, plus one fixed-point unit
            // for floating summation/division error (at most 16384 taps).
            span.error_bound = @intFromFloat(@ceil(error_sum * 255) + 1);
        }
        return .{ .spans = spans, .weights = weights, .fixed = fixed };
    }
    fn applyGpu(self: Filter, a: Allocator, source: []const RGB, source_width: usize, width: usize, height: usize, vertical: bool, destination: []RGB) bool {
        const spans = a.alloc(gpu.Span, self.spans.len) catch return false;
        defer a.free(spans);
        for (spans, self.spans) |*packed_span, span| packed_span.* = .{
            .first = @intCast(span.first),
            .length = @intCast(span.len),
            .offset = @intCast(span.offset),
            .error_bound = span.error_bound,
        };
        const output = a.alloc([4]u8, destination.len) catch return false;
        defer a.free(output);
        if (!gpu.pass(std.mem.sliceAsBytes(source), spans, self.fixed, output, source_width, width, height, vertical)) return false;
        for (output, destination, 0..) |pixel, *rgb, index| {
            rgb.* = pixel[0..3].*;
            if (pixel[3] == 0) continue;
            const x = index % width;
            const y = index / width;
            const span = self.spans[if (vertical) y else x];
            const pixels = if (vertical) source[x..] else source[y * source_width ..][0..source_width];
            inline for (0..3) |c| if (pixel[3] & (@as(u8, 1) << c) != 0) {
                rgb[c] = self.exact(span, pixels, if (vertical) source_width else 1, c);
            };
        }
        return true;
    }
    fn exact(self: Filter, span: Span, pixels: []const RGB, step: usize, c: usize) u8 {
        var sum: f64 = 0;
        for (self.weights[span.offset..][0..span.len], span.first..) |weight, i| {
            sum += @as(f64, @floatFromInt(pixels[i * step][c])) * weight;
        }
        return channel(sum, span.total);
    }
    fn apply(self: Filter, span: Span, pixels: []const RGB, step: usize) RGB {
        var sum: @Vector(4, u32) = @splat(0);
        for (self.fixed[span.offset..][0..span.len], span.first..) |weight, i| {
            const pixel = pixels[i * step];
            const lanes: @Vector(4, u32) = .{ pixel[0], pixel[1], pixel[2], 0 };
            // Proven bound: 255 * unit < 2^32, because weights sum to unit.
            sum +%= lanes *% @as(@Vector(4, u32), @splat(weight));
        }
        var result: RGB = undefined;
        inline for (0..3) |c| {
            const fraction = sum[c] & (unit - 1);
            const distance = if (fraction >= unit / 2) fraction - unit / 2 else unit / 2 - fraction;
            if (distance <= span.error_bound) {
                // Quantization could change a rounding decision. Re-evaluate
                // just this channel with the original arithmetic and ordering.
                result[c] = self.exact(span, pixels, step, c);
            } else result[c] = @intCast((sum[c] + unit / 2) >> 22);
        }
        return result;
    }
    fn deinit(self: *Filter, a: Allocator) void {
        a.free(self.fixed);
        a.free(self.spans);
        a.free(self.weights);
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
    // Required CPU allocations propagate OOM. Optional GPU staging failures
    // are tested separately because they must recover successfully.
    var small = try f.resizeImpl(a, 4, 3, false);
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

// Frozen scalar implementation from fb58736, used only as a pixel oracle.
fn referenceResize(self: Frame, a: Allocator, width: usize, height: usize) !Frame {
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

test "optimized resize is pixel-exact against the scalar reference" {
    const a = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x5348534445534b);
    const shapes = [_][4]usize{
        .{ 1, 1, 9, 7 },     .{ 1, 31, 7, 1 },    .{ 31, 1, 1, 7 },
        .{ 8, 8, 8, 8 },     .{ 73, 41, 2, 3 },   .{ 3, 5, 41, 73 },
        .{ 97, 53, 19, 12 }, .{ 13, 29, 13, 3 },  .{ 31, 7, 2, 7 },
        .{ 16384, 1, 1, 1 }, .{ 1, 16384, 1, 1 },
    };
    for (0..shapes.len + 64) |i| {
        var shape: [4]usize = undefined;
        if (i < shapes.len) {
            shape = shapes[i];
        } else {
            for (&shape) |*dimension| dimension.* = random.random().intRangeAtMost(usize, 1, 80);
        }
        var source = try Frame.init(a, shape[0], shape[1]);
        defer source.deinit();
        random.random().bytes(std.mem.sliceAsBytes(source.pixels));
        source.generation = 42;
        source.desktop_width = 1920;
        source.desktop_height = 1080;
        var expected = try referenceResize(source, a, shape[2], shape[3]);
        defer expected.deinit();
        var actual = try source.resize(a, shape[2], shape[3]);
        defer actual.deinit();
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.pixels), std.mem.sliceAsBytes(actual.pixels));
        try std.testing.expectEqual(source.captured_ns, actual.captured_ns);
        try std.testing.expectEqual(source.generation, actual.generation);
        try std.testing.expectEqual(source.desktopSize(), actual.desktopSize());
    }
}

test "requested GPU backend matches scalar pixels without silent fallback" {
    if (!gpu.enabled()) return error.SkipZigTest;
    defer gpu.deinit();
    const a = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(42);
    for ([_][4]usize{ .{ 1920, 1080, 100, 56 }, .{ 7, 3, 31, 19 }, .{ 1, 31, 7, 1 }, .{ 31, 1, 1, 7 }, .{ 16384, 1, 1, 1 } }) |shape| {
        var source = try Frame.init(a, shape[0], shape[1]);
        defer source.deinit();
        random.random().bytes(std.mem.sliceAsBytes(source.pixels));
        var expected = try referenceResize(source, a, shape[2], shape[3]);
        defer expected.deinit();
        const passes = gpu.testing_completed_passes.load(.acquire);
        var actual = try source.resizeImpl(a, shape[2], shape[3], true);
        defer actual.deinit();
        try std.testing.expectEqual(passes + 2, gpu.testing_completed_passes.load(.acquire));
        try std.testing.expect(gpu.active());
        try std.testing.expectEqualStrings(if (@import("builtin").os.tag == .macos) "metal" else "vulkan", gpu.backendName());
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.pixels), std.mem.sliceAsBytes(actual.pixels));
    }
}

test "GPU buffers remain isolated across concurrent resize calls" {
    if (!gpu.enabled()) return error.SkipZigTest;
    defer gpu.deinit();
    const Worker = struct {
        ok: bool = false,
        seed: u64,
        fn run(self: *@This()) void {
            self.check() catch return;
            self.ok = true;
        }
        fn check(self: *@This()) !void {
            const a = std.testing.allocator;
            var random = std.Random.DefaultPrng.init(self.seed);
            var source = try Frame.init(a, 97, 53);
            defer source.deinit();
            for (0..8) |i| {
                random.random().bytes(std.mem.sliceAsBytes(source.pixels));
                var expected = try referenceResize(source, a, 13 + i, 17 + i);
                defer expected.deinit();
                var actual = try source.resizeImpl(a, 13 + i, 17 + i, true);
                defer actual.deinit();
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.pixels), std.mem.sliceAsBytes(actual.pixels));
            }
        }
    };
    var first: Worker = .{ .seed = 1 };
    var second: Worker = .{ .seed = 2 };
    const passes = gpu.testing_completed_passes.load(.acquire);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    second.run();
    thread.join();
    try std.testing.expect(first.ok and second.ok);
    try std.testing.expectEqual(passes + 32, gpu.testing_completed_passes.load(.acquire));
}

test "failed GPU passes fall back to exact SIMD CPU pixels" {
    const a = std.testing.allocator;
    gpu.testing_reject_passes = true;
    gpu.testing_rejected_passes = 0;
    defer gpu.testing_reject_passes = false;
    var source = try Frame.init(a, 97, 53);
    defer source.deinit();
    var random = std.Random.DefaultPrng.init(91);
    random.random().bytes(std.mem.sliceAsBytes(source.pixels));
    var expected = try referenceResize(source, a, 19, 12);
    defer expected.deinit();
    var actual = try source.resizeImpl(a, 19, 12, true);
    defer actual.deinit();
    try std.testing.expectEqual(@as(usize, 2), gpu.testing_rejected_passes);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.pixels), std.mem.sliceAsBytes(actual.pixels));
}

test "GPU staging allocation failures fall back without further allocation" {
    const a = std.testing.allocator;
    var source = try Frame.init(a, 97, 53);
    defer source.deinit();
    var random = std.Random.DefaultPrng.init(92);
    random.random().bytes(std.mem.sliceAsBytes(source.pixels));
    var expected = try referenceResize(source, a, 19, 12);
    defer expected.deinit();
    // Output, intermediate frame, and two filters require eight allocations.
    // Failure of either GPU-only staging allocation must leave CPU usable.
    for ([_]usize{ 8, 9 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var actual = try source.resizeImpl(failing.allocator(), 19, 12, true);
        defer actual.deinit();
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.pixels), std.mem.sliceAsBytes(actual.pixels));
    }
}

test "GPU context can be destroyed and recreated" {
    if (!gpu.enabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    var source = try synthetic(a, 97, 53, null);
    defer source.deinit();
    var expected = try referenceResize(source, a, 19, 12);
    defer expected.deinit();
    for (0..3) |_| {
        gpu.deinit();
        defer gpu.deinit();
        try std.testing.expect(!gpu.active());
        var actual = try source.resizeImpl(a, 19, 12, true);
        defer actual.deinit();
        try std.testing.expectEqual(@as(usize, 2), gpu.testing_completed_passes.load(.acquire));
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.pixels), std.mem.sliceAsBytes(actual.pixels));
    }
}
