const std = @import("std");
const f = @import("frame.zig");
const A = std.mem.Allocator;
pub const Color = enum { truecolor, ansi256, ansi16 };
pub const Cell = struct { fg: f.RGB, bg: f.RGB };
pub const Viewport = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    desktop_width: usize,
    desktop_height: usize,
    pub fn calculate(dw: usize, dh: usize, columns: usize, rows: usize, margin: usize, scale: f64) !Viewport {
        if (dw == 0 or dh == 0 or columns == 0 or columns > 1024 or rows == 0 or rows > 1024 or margin > 16 or !std.math.isFinite(scale) or scale < 0.25 or scale > 1) return error.InvalidViewport;
        const top = @min(margin, rows - 1);
        const available = rows - top;
        const ratio = @min(@as(f64, @floatFromInt(columns)) / @as(f64, @floatFromInt(dw)), @as(f64, @floatFromInt(available * 2)) / @as(f64, @floatFromInt(dh))) * scale;
        const w = @max(1, @min(columns, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(dw)) * ratio)))));
        const h = (@max(2, @min(available * 2, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(dh)) * ratio))))) + 1) / 2;
        return .{ .x = (columns - w) / 2, .y = top + (available - h) / 2, .width = w, .height = h, .desktop_width = dw, .desktop_height = dh };
    }
    pub fn coordinates(self: Viewport, column: i32, row: i32) ?[2]i32 {
        if (column < 0 or row < 0) return null;
        const x: usize = @intCast(column);
        const y: usize = @intCast(row);
        if (x < self.x or x >= self.x + self.width or y < self.y or y >= self.y + self.height) return null;
        return .{ @intCast(@min(self.desktop_width - 1, ((x - self.x) * 2 + 1) * self.desktop_width / (self.width * 2))), @intCast(@min(self.desktop_height - 1, ((y - self.y) * 2 + 1) * self.desktop_height / (self.height * 2))) };
    }
};
pub const Rendered = struct {
    allocator: A,
    columns: usize,
    rows: usize,
    viewport: Viewport,
    cells: []Cell,
    pub fn deinit(self: *Rendered) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};
pub fn render(a: A, frame: f.Frame, columns: usize, rows: usize, margin: usize, scale: f64) !Rendered {
    const desktop = frame.desktopSize();
    const v = try Viewport.calculate(desktop[0], desktop[1], columns, rows, margin, scale);
    var resized = try frame.resize(a, v.width, v.height * 2);
    defer resized.deinit();
    const cells = try a.alloc(Cell, columns * rows);
    @memset(cells, .{ .fg = .{ 0, 0, 0 }, .bg = .{ 0, 0, 0 } });
    for (0..v.height) |y| for (0..v.width) |x| {
        cells[(y + v.y) * columns + x + v.x] = .{ .fg = resized.pixels[y * 2 * v.width + x], .bg = resized.pixels[(y * 2 + 1) * v.width + x] };
    };
    return .{ .allocator = a, .columns = columns, .rows = rows, .viewport = v, .cells = cells };
}
const palette = [_]f.RGB{ .{ 0, 0, 0 }, .{ 205, 49, 49 }, .{ 13, 188, 121 }, .{ 229, 229, 16 }, .{ 36, 114, 200 }, .{ 188, 63, 188 }, .{ 17, 168, 205 }, .{ 229, 229, 229 }, .{ 102, 102, 102 }, .{ 241, 76, 76 }, .{ 35, 209, 139 }, .{ 245, 245, 67 }, .{ 59, 142, 234 }, .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 } };
fn distance(a: f.RGB, b: f.RGB) u32 {
    var result: u32 = 0;
    for (a, b) |x, y| {
        const d = @as(i32, x) - @as(i32, y);
        result += @intCast(d * d);
    }
    return result;
}
pub fn ansi16(rgb: f.RGB) u8 {
    var best: u32 = std.math.maxInt(u32);
    var result: u8 = 0;
    for (palette, 0..) |color, i| {
        const d = distance(color, rgb);
        if (d < best) {
            best = d;
            result = @intCast(i);
        }
    }
    return result;
}
pub fn ansi256(rgb: f.RGB) u8 {
    var cube: f.RGB = undefined;
    var mapped: f.RGB = undefined;
    for (rgb, 0..) |c, i| {
        cube[i] = @intCast((@as(u32, c) * 5 + 127) / 255);
        mapped[i] = if (cube[i] == 0) 0 else 55 + cube[i] * 40;
    }
    const gray: u8 = @intCast(@min(23, @max(0, @divTrunc(@as(i32, rgb[0]) + rgb[1] + rgb[2] - 24 + 15, 30))));
    const level = 8 + gray * 10;
    return if (distance(rgb, .{ level, level, level }) < distance(rgb, mapped)) 232 + gray else 16 + 36 * cube[0] + 6 * cube[1] + cube[2];
}
pub const enter = "\x1b[22;0t\x1b]2;SSHDESK\x1b\\\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";
pub const mouse_on = "\x1b[?1003h\x1b[?1006h";
pub const leave = "\x1b[?1016l\x1b[0m\x1b[?25h\x1b[?1006l\x1b[?1003l\x1b[?1049l\x1b[23;0t";
pub const Encoded = struct { bytes: []u8, changed: usize, full: bool };
pub fn encode(a: A, previous: ?Rendered, current: Rendered, color: Color, unicode: bool) !Encoded {
    var full = previous == null;
    var changed: usize = 0;
    if (previous) |p| {
        full = p.columns != current.columns or p.rows != current.rows or !std.meta.eql(p.viewport, current.viewport);
    }
    if (full) {
        changed = current.cells.len;
    } else {
        for (previous.?.cells, current.cells) |old, new| {
            if (!std.meta.eql(old, new)) changed += 1;
        }
        full = changed * 100 >= current.cells.len * 60;
    }
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    if (changed == 0) return .{ .bytes = try bytes.toOwnedSlice(a), .changed = 0, .full = false };
    const writer = bytes.writer(a);
    var last: ?Cell = null;
    var last_index: ?usize = null;
    for (current.cells, 0..) |cell, index| {
        if (!full and std.meta.eql(previous.?.cells[index], cell)) continue;
        if (last_index == null or index != last_index.? + 1 or index % current.columns == 0) try writer.print("\x1b[{d};{d}H", .{ index / current.columns + 1, index % current.columns + 1 });
        var c = cell;
        if (!unicode) for (0..3) |i| {
            c.fg[i] = @intCast((@as(u16, c.fg[i]) + c.bg[i]) / 2);
            c.bg[i] = c.fg[i];
        };
        if (last == null or !std.meta.eql(last.?, c)) {
            switch (color) {
                .truecolor => try writer.print("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ c.fg[0], c.fg[1], c.fg[2], c.bg[0], c.bg[1], c.bg[2] }),
                .ansi256 => try writer.print("\x1b[38;5;{d};48;5;{d}m", .{ ansi256(c.fg), ansi256(c.bg) }),
                .ansi16 => {
                    const fg = ansi16(c.fg);
                    const bg = ansi16(c.bg);
                    try writer.print("\x1b[{d};{d}m", .{ @as(u16, if (fg < 8) 30 else 82) + fg, @as(u16, if (bg < 8) 40 else 92) + bg });
                },
            }
            last = c;
        }
        try writer.writeAll(if (unicode) "▀" else " ");
        last_index = index;
    }
    try writer.writeAll("\x1b[0m");
    return .{ .bytes = try bytes.toOwnedSlice(a), .changed = changed, .full = full };
}
test "viewport margins, small terminals, scale and mouse mapping" {
    const v = try Viewport.calculate(1920, 1080, 80, 24, 1, 1);
    try std.testing.expect(v.y >= 1);
    try std.testing.expect(v.coordinates(0, 0) == null);
    const point = v.coordinates(@intCast(v.x), @intCast(v.y)).?;
    try std.testing.expect(point[0] >= 0 and point[1] >= 0);
    const tiny = try Viewport.calculate(1920, 1080, 1, 1, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), tiny.height);
    try std.testing.expectError(error.InvalidViewport, Viewport.calculate(1, 1, 0, 24, 0, 1));
}
fn scenario(a: A) !void {
    var frame = try f.synthetic(a, 64, 36, null);
    defer frame.deinit();
    var first = try render(a, frame, 20, 10, 0, 1);
    defer first.deinit();
    const full = try encode(a, null, first, .truecolor, true);
    defer a.free(full.bytes);
    try std.testing.expect(full.full);
    try std.testing.expect(std.mem.indexOf(u8, full.bytes, "▀") != null);
    const same = try encode(a, first, first, .ansi256, true);
    defer a.free(same.bytes);
    try std.testing.expectEqual(@as(usize, 0), same.bytes.len);
    var next = try render(a, frame, 20, 10, 0, 1);
    defer next.deinit();
    next.cells[3] = .{ .fg = .{ 255, 0, 0 }, .bg = .{ 0, 255, 0 } };
    const delta = try encode(a, first, next, .ansi16, false);
    defer a.free(delta.bytes);
    try std.testing.expect(!delta.full);
    try std.testing.expectEqual(@as(usize, 1), delta.changed);
    try std.testing.expect(std.mem.indexOf(u8, delta.bytes, "▀") == null);
}
test "full, delta, static suppression, colors and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scenario, .{});
}
test "large changes and terminal resize force full redraws; deltas emit one glyph" {
    const a = std.testing.allocator;
    var frame = try f.synthetic(a, 64, 36, null);
    defer frame.deinit();
    var first = try render(a, frame, 20, 10, 1, 1);
    defer first.deinit();
    var next = try render(a, frame, 20, 10, 1, 1);
    defer next.deinit();
    next.cells[30] = .{ .fg = .{ 255, 0, 0 }, .bg = .{ 0, 0, 255 } };
    const delta = try encode(a, first, next, .truecolor, true);
    defer a.free(delta.bytes);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, delta.bytes, "▀"));
    @memset(next.cells, .{ .fg = .{ 255, 255, 255 }, .bg = .{ 255, 255, 255 } });
    const large = try encode(a, first, next, .ansi256, true);
    defer a.free(large.bytes);
    try std.testing.expect(large.full);
    var resized = try render(a, frame, 30, 12, 1, 1);
    defer resized.deinit();
    const changed_size = try encode(a, first, resized, .ansi16, true);
    defer a.free(changed_size.bytes);
    try std.testing.expect(changed_size.full);
    try std.testing.expectEqualStrings("\x1b[22;0t", enter[0..7]);
    try std.testing.expect(std.mem.endsWith(u8, leave, "\x1b[23;0t"));
}
