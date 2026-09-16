const std = @import("std");
const frame = @import("frame.zig");
const render = @import("render.zig");
const Options = @import("cli.zig").Options;
pub fn run(a: std.mem.Allocator, opts: Options) !u8 {
    if (opts.fixture) |path| return fixture(a, opts, path);
    var timer = try std.time.Timer.start();
    var count: usize = 0;
    var bytes: usize = 0;
    var full: usize = 0;
    var delta: usize = 0;
    var changed_total: f64 = 0;
    var buckets: std.AutoHashMap(usize, usize) = .init(a);
    defer buckets.deinit();
    var previous: ?render.Rendered = null;
    defer if (previous) |*p| p.deinit();
    const deadline: u64 = @intFromFloat(opts.duration * std.time.ns_per_s);
    while (timer.read() < deadline) {
        const next = @as(u64, @intCast(count)) * std.time.ns_per_s / 30;
        if (timer.read() < next) {
            std.Thread.sleep(@min(next - timer.read(), 5 * std.time.ns_per_ms));
            continue;
        }
        var captured = try frame.synthetic(a, 1920, 1080, count);
        defer captured.deinit();
        var current = try render.render(a, captured, opts.columns, opts.rows, 0, opts.scale);
        var transferred = false;
        defer if (!transferred) current.deinit();
        const packet = try render.encode(a, previous, current, opts.color, opts.unicode);
        defer a.free(packet.bytes);
        bytes += packet.bytes.len;
        const bucket = try buckets.getOrPut(@intCast(timer.read() / std.time.ns_per_s));
        if (!bucket.found_existing) bucket.value_ptr.* = 0;
        bucket.value_ptr.* += packet.bytes.len;
        changed_total += @as(f64, @floatFromInt(packet.changed)) * 100 / @as(f64, @floatFromInt(current.cells.len));
        if (packet.full) full += 1 else if (packet.changed > 0) delta += 1;
        if (previous) |*p| p.deinit();
        previous = current;
        transferred = true;
        count += 1;
    }
    const elapsed = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    var peak: f64 = 0;
    var it = buckets.iterator();
    while (it.next()) |entry| {
        const second: f64 = @floatFromInt(entry.key_ptr.*);
        const duration = @max(0.000000001, @min(elapsed, second + 1) - second);
        peak = @max(peak, @as(f64, @floatFromInt(entry.value_ptr.* * 8)) / duration / 1000);
    }
    var parser: @import("input.zig").Parser = .{};
    const input_started = timer.read();
    for (0..1000) |_| {
        try parser.feed("a\x1b[A\x1b[<0;10;20M");
        while (parser.next(0) != null) {}
    }
    const latency = @as(f64, @floatFromInt(timer.read() - input_started)) / 1000 / std.time.ns_per_ms;
    const result = try std.fmt.allocPrint(a, "Session duration:       {d:.1}s\nAverage FPS:            {d:.1}\nAverage bandwidth:      {d:.0} Kbit/s\nPeak bandwidth:         {d:.0} Kbit/s\nInput parse latency:    {d:.2} ms\nFull frames:            {d}\nDelta frames:           {d}\nAverage changed area:   {d:.1}%\n", .{ elapsed, @as(f64, @floatFromInt(count)) / elapsed, @as(f64, @floatFromInt(bytes * 8)) / elapsed / 1000, peak, latency, full, delta, if (count > 0) changed_total / @as(f64, @floatFromInt(count)) else 0 });
    defer a.free(result);
    try std.fs.File.stdout().writeAll(result);
    return 0;
}

fn fixture(a: std.mem.Allocator, opts: Options, path: []const u8) !u8 {
    const raw = try std.fs.cwd().readFileAlloc(a, path, 1920 * 1080 * 3);
    defer a.free(raw);
    if (raw.len != 1920 * 1080 * 3) return error.Expected1920x1080RgbFixture;
    var source = try frame.Frame.init(a, 1920, 1080);
    defer source.deinit();
    @memcpy(std.mem.sliceAsBytes(source.pixels), raw);
    const samples = try a.alloc(u64, opts.iterations);
    defer a.free(samples);
    var total_bytes: usize = 0;
    var first_frame_ns: u64 = 0;
    var previous: ?render.Rendered = null;
    defer if (previous) |*p| p.deinit();
    var timer = try std.time.Timer.start();
    for (0..opts.iterations + 10) |iteration| {
        const start = timer.read();
        var current = try render.render(a, source, opts.columns, opts.rows, 0, 1);
        var transferred = false;
        defer if (!transferred) current.deinit();
        const packet = try render.encode(a, previous, current, opts.color, true);
        defer a.free(packet.bytes);
        if (previous) |*p| p.deinit();
        previous = current;
        transferred = true;
        if (iteration == 0) first_frame_ns = timer.read() - start;
        if (iteration >= 10) {
            samples[iteration - 10] = timer.read() - start;
            total_bytes += packet.bytes.len;
        }
    }
    var total: u64 = 0;
    for (samples) |n| total += n;
    const result = try std.json.Stringify.valueAlloc(a, .{ .implementation = "zig", .resize_backend = @import("gpu.zig").backendName(), .first_frame_ms = @as(f64, @floatFromInt(first_frame_ns)) / std.time.ns_per_ms, .iterations = opts.iterations, .warmup = 10, .columns = opts.columns, .rows = opts.rows, .mean_ms = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(opts.iterations)) / std.time.ns_per_ms, .encoded_bytes = total_bytes, .samples_ns = samples }, .{});
    defer a.free(result);
    try std.fs.File.stdout().writeAll(result);
    try std.fs.File.stdout().writeAll("\n");
    return 0;
}
