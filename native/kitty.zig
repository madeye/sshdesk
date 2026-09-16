const std = @import("std");
const Frame = @import("frame.zig").Frame;
const Png = @import("png.zig").Png;
const A = std.mem.Allocator;
pub const Geometry = struct { columns: usize, rows: usize, cell_width: usize, cell_height: usize };
pub const Probe = struct {
    buffer: [8192]u8 = undefined,
    len: usize = 0,
    kitty: bool = false,
    pixel_width: usize = 0,
    pixel_height: usize = 0,
    cell_width: usize = 0,
    cell_height: usize = 0,
    pub fn feed(self: *Probe, bytes: []const u8) !void {
        if (bytes.len > self.buffer.len - self.len) return error.TerminalProbeTooLarge;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        const text = self.buffer[0..self.len];
        if (std.mem.indexOf(u8, text, "i=31;OK") != null) self.kitty = true;
        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, text, offset, "\x1b[")) |start| {
            const end = std.mem.indexOfScalarPos(u8, text, start + 2, 't') orelse break;
            var parts = std.mem.splitScalar(u8, text[start + 2 .. end], ';');
            const kind = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch {
                offset = end + 1;
                continue;
            };
            const height = std.fmt.parseInt(usize, parts.next() orelse "", 10) catch {
                offset = end + 1;
                continue;
            };
            const width = std.fmt.parseInt(usize, parts.next() orelse "", 10) catch {
                offset = end + 1;
                continue;
            };
            if (parts.next() == null and width > 0 and height > 0 and width <= 32768 and height <= 32768) {
                if (kind == 4) {
                    self.pixel_width = width;
                    self.pixel_height = height;
                }
                if (kind == 6 and width <= 256 and height <= 512) {
                    self.cell_width = width;
                    self.cell_height = height;
                }
            }
            offset = end + 1;
        }
    }
};
pub fn graphics(a: A, packet: []const u8, tmux: bool) ![]u8 {
    if (!tmux) return a.dupe(u8, packet);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x1bPtmux;");
    for (packet) |c| {
        try out.append(a, c);
        if (c == 27) try out.append(a, c);
    }
    try out.appendSlice(a, "\x1b\\");
    return out.toOwnedSlice(a);
}
pub const Encoder = struct {
    allocator: A,
    png: Png,
    tmux: bool = false,
    previous: ?Frame = null,
    geometry: ?Geometry = null,
    base_image: ?usize = null,
    viewport: ?@import("render.zig").Viewport = null,
    pixel_viewport: ?@import("render.zig").Viewport = null,
    cursor_loaded: bool = false,
    pub fn init(a: A, tmux: bool) !Encoder {
        return .{ .allocator = a, .png = try Png.init(), .tmux = tmux };
    }
    pub fn deinit(self: *Encoder) void {
        if (self.previous) |*f| f.deinit();
        self.png.deinit();
    }
    pub fn reset(self: *Encoder) void {
        if (self.previous) |*f| f.deinit();
        self.previous = null;
        self.geometry = null;
        self.base_image = null;
        self.cursor_loaded = false;
    }
    fn appendGraphics(self: *Encoder, out: *std.ArrayList(u8), bytes: []const u8) !void {
        const wrapped = try graphics(self.allocator, bytes, self.tmux);
        defer self.allocator.free(wrapped);
        try out.appendSlice(self.allocator, wrapped);
    }
    fn transmit(self: *Encoder, out: *std.ArrayList(u8), tile: Frame, id: usize, column: usize, row: usize) !void {
        const a = self.allocator;
        const png = try self.png.encodePalette(a, tile);
        defer a.free(png);
        const payload = try a.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
        defer a.free(payload);
        _ = std.base64.standard.Encoder.encode(payload, png);
        try out.writer(a).print("\x1b[{d};{d}H", .{ row + 1, column + 1 });
        var offset: usize = 0;
        while (offset < payload.len) {
            const end = @min(offset + 4096, payload.len);
            var command: std.ArrayList(u8) = .empty;
            defer command.deinit(a);
            if (offset == 0) try command.writer(a).print("\x1b_Ga=T,q=1,C=1,z={d},f=100,i={d},p=1,m={d};", .{ @as(i32, if (id < 100) -2 else -1), id, @intFromBool(end < payload.len) }) else try command.writer(a).print("\x1b_Gm={d},q=1;", .{@intFromBool(end < payload.len)});
            try command.appendSlice(a, payload[offset..end]);
            try command.appendSlice(a, "\x1b\\");
            try self.appendGraphics(out, command.items);
            offset = end;
        }
    }
    pub fn cursor(self: *Encoder, x: usize, y: usize, cell_width: usize, cell_height: usize) ![]u8 {
        const a = self.allocator;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.writer(a).print("\x1b[{d};{d}H", .{ y / cell_height + 1, x / cell_width + 1 });
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(a);
        if (!self.cursor_loaded) {
            var rgba: [12 * 18 * 4]u8 = @splat(0);
            for (0..18) |row| for (0..12) |column| {
                if (column <= row / 2 and row < 15) {
                    const offset = (row * 12 + column) * 4;
                    const edge: u8 = if (column == 0 or column == row / 2 or row == 14) 0 else 255;
                    @memcpy(rgba[offset..][0..4], &[_]u8{ edge, edge, edge, 255 });
                }
            };
            var encoded: [std.base64.standard.Encoder.calcSize(rgba.len)]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&encoded, &rgba);
            try command.writer(a).print("\x1b_Ga=T,f=32,s=12,v=18,i=99,p=1,z=3,C=1,q=1,X={d},Y={d};{s}\x1b\\", .{ x % cell_width, y % cell_height, encoded });
            self.cursor_loaded = true;
        } else {
            try command.writer(a).print("\x1b_Ga=p,i=99,p=1,z=3,C=1,q=1,X={d},Y={d}\x1b\\", .{ x % cell_width, y % cell_height });
        }
        try self.appendGraphics(&out, command.items);
        return out.toOwnedSlice(a);
    }
    pub fn encode(self: *Encoder, source: Frame, geometry: Geometry, scale: f64) ![]u8 {
        if (geometry.columns < 1 or geometry.columns > 1024 or geometry.rows < 1 or geometry.rows > 1024 or geometry.cell_width < 1 or geometry.cell_width > 256 or geometry.cell_height < 1 or geometry.cell_height > 512 or !std.math.isFinite(scale) or scale < 0.25 or scale > 1) return error.InvalidPixelGeometry;
        const a = self.allocator;
        const top = @min(1, geometry.rows - 1);
        const available_w = geometry.columns * geometry.cell_width;
        const available_h = (geometry.rows - top) * geometry.cell_height;
        const desktop = source.desktopSize();
        const ratio = @min(1, @min(@as(f64, @floatFromInt(available_w)) / @as(f64, @floatFromInt(desktop[0])), @as(f64, @floatFromInt(available_h)) / @as(f64, @floatFromInt(desktop[1])))) * scale;
        const width = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(desktop[0])) * ratio))));
        const height = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(desktop[1])) * ratio))));
        var current = try source.resize(a, width, height);
        var transferred = false;
        defer if (!transferred) current.deinit();
        var full = self.previous == null or self.previous.?.width != width or self.previous.?.height != height or self.geometry == null or !std.meta.eql(self.geometry.?, geometry);
        if (!full) {
            var changed: usize = 0;
            for (current.pixels, self.previous.?.pixels) |new, old| {
                if (!std.mem.eql(u8, &new, &old)) changed += 1;
            }
            if (changed * 100 >= current.pixels.len * 60) full = true;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        if (self.base_image == null) {
            try self.appendGraphics(&out, "\x1b_Ga=d,d=A,q=1\x1b\\");
            self.cursor_loaded = false;
        }
        const xcells = (geometry.columns - (width + geometry.cell_width - 1) / geometry.cell_width) / 2;
        const ycells = top + (geometry.rows - top - (height + geometry.cell_height - 1) / geometry.cell_height) / 2;
        const tile_w = @max(geometry.cell_width, (256 / geometry.cell_width) * geometry.cell_width);
        const tile_h = @max(geometry.cell_height, (256 / geometry.cell_height) * geometry.cell_height);
        if (full) {
            const id: usize = if (self.base_image == 1) 2 else 1;
            try self.transmit(&out, current, id, xcells, ycells);
            try self.appendGraphics(&out, "\x1b_Ga=d,d=Z,z=-1,q=1\x1b\\");
            if (self.base_image) |old| {
                var buffer: [96]u8 = undefined;
                try self.appendGraphics(&out, try std.fmt.bufPrint(&buffer, "\x1b_Ga=d,d=I,i={d},q=1\x1b\\", .{old}));
            }
            self.base_image = id;
        } else {
            var y: usize = 0;
            var id: usize = 100;
            while (y < height) : (y += tile_h) {
                var x: usize = 0;
                while (x < width) : (x += tile_w) {
                    defer id += 1;
                    const w = @min(tile_w, width - x);
                    const h = @min(tile_h, height - y);
                    var changed = full;
                    if (!changed) for (0..h) |row| {
                        const start = (y + row) * width + x;
                        if (!std.mem.eql(u8, std.mem.sliceAsBytes(current.pixels[start..][0..w]), std.mem.sliceAsBytes(self.previous.?.pixels[start..][0..w]))) {
                            changed = true;
                            break;
                        }
                    };
                    if (!changed) continue;
                    var tile = try Frame.init(a, w, h);
                    defer tile.deinit();
                    for (0..h) |row| @memcpy(tile.pixels[row * w ..][0..w], current.pixels[(y + row) * width + x ..][0..w]);
                    try self.transmit(&out, tile, id, xcells + x / geometry.cell_width, ycells + y / geometry.cell_height);
                }
            }
        }
        const bytes = try out.toOwnedSlice(a);
        self.viewport = .{ .x = xcells, .y = ycells, .width = (width + geometry.cell_width - 1) / geometry.cell_width, .height = (height + geometry.cell_height - 1) / geometry.cell_height, .desktop_width = desktop[0], .desktop_height = desktop[1] };
        self.pixel_viewport = .{ .x = xcells * geometry.cell_width, .y = ycells * geometry.cell_height, .width = width, .height = height, .desktop_width = desktop[0], .desktop_height = desktop[1] };
        if (self.previous) |*previous| previous.deinit();
        self.previous = current;
        self.geometry = geometry;
        transferred = true;
        return bytes;
    }
};
test "fragmented Kitty probe, pixel geometry and tmux escaping" {
    var probe: Probe = .{};
    try probe.feed("\x1b_Gi=31;");
    try probe.feed("OK\x1b\\\x1b[4;720;1280t\x1b[6;20;10t");
    try std.testing.expect(probe.kitty);
    try std.testing.expectEqual(@as(usize, 1280), probe.pixel_width);
    try std.testing.expectEqual(@as(usize, 20), probe.cell_height);
    const wrapped = try graphics(std.testing.allocator, "\x1b_Ga=q\x1b\\", true);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("\x1bPtmux;\x1b\x1b_Ga=q\x1b\x1b\\\x1b\\", wrapped);
}
test "Kitty PNG tiles, static suppression and changed tile update" {
    const a = std.testing.allocator;
    var encoder = try Encoder.init(a, false);
    defer encoder.deinit();
    var frame = try @import("frame.zig").synthetic(a, 640, 360, null);
    defer frame.deinit();
    const geometry: Geometry = .{ .columns = 80, .rows = 24, .cell_width = 10, .cell_height = 20 };
    const first = try encoder.encode(frame, geometry, 1);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "f=100") != null);
    const same = try encoder.encode(frame, geometry, 1);
    defer a.free(same);
    try std.testing.expectEqual(@as(usize, 0), same.len);
    frame.pixels[0] = .{ 255, 0, 0 };
    const delta = try encoder.encode(frame, geometry, 1);
    defer a.free(delta);
    try std.testing.expect(delta.len > 0 and delta.len < first.len);
    try std.testing.expectEqual(@as(usize, 640), encoder.previous.?.width);
}

test "Kitty canvas decodes to bounded paletted pixels and large updates replace canvas" {
    const a = std.testing.allocator;
    var encoder = try Encoder.init(a, false);
    defer encoder.deinit();
    var frame = try Frame.init(a, 320, 180);
    defer frame.deinit();
    @memset(frame.pixels, .{ 255, 0, 0 });
    const geometry: Geometry = .{ .columns = 200, .rows = 80, .cell_width = 10, .cell_height = 20 };
    const bytes = try encoder.encode(frame, geometry, 1);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "a=T"));
    try std.testing.expectEqual(@as(usize, 320), encoder.previous.?.width);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    var commands = std.mem.splitSequence(u8, bytes, "\x1b_G");
    while (commands.next()) |command| {
        const semicolon = std.mem.indexOfScalar(u8, command, ';') orelse continue;
        if (!std.mem.startsWith(u8, command, "a=T") and !std.mem.startsWith(u8, command, "m=")) continue;
        const end = std.mem.indexOf(u8, command, "\x1b\\") orelse return error.InvalidPacket;
        try std.testing.expect(end - semicolon - 1 <= 4096);
        try payload.appendSlice(a, command[semicolon + 1 .. end]);
    }
    const pngbytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(payload.items));
    defer a.free(pngbytes);
    try std.base64.standard.Decoder.decode(pngbytes, payload.items);
    try std.testing.expectEqual(@as(u8, 3), pngbytes[25]); // PNG indexed-color IHDR.
    var decoded = try encoder.png.decode(a, pngbytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 320), decoded.width);
    for (decoded.pixels) |p| try std.testing.expectEqual([3]u8{ 255, 0, 0 }, p);
    @memset(frame.pixels, .{ 255, 255, 255 });
    const large = try encoder.encode(frame, geometry, 1);
    defer a.free(large);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, large, "a=T"));
    try std.testing.expect(std.mem.indexOf(u8, large, "d=Z,z=-1") != null);
}

test "prescaled images retain desktop coordinates in both renderers" {
    const a = std.testing.allocator;
    var source = try Frame.init(a, 320, 180);
    defer source.deinit();
    @memset(source.pixels, .{ 12, 34, 56 });
    source.desktop_width = 1920;
    source.desktop_height = 1080;
    var encoder = try Encoder.init(a, false);
    defer encoder.deinit();
    const output = try encoder.encode(source, .{ .columns = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, 0.5);
    defer a.free(output);
    try std.testing.expectEqual(@as(usize, 1920), encoder.viewport.?.desktop_width);
    try std.testing.expectEqual(@as(usize, 320), encoder.previous.?.width);
    var ansi = try @import("render.zig").render(a, source, 80, 24, 1, 0.5);
    defer ansi.deinit();
    try std.testing.expectEqual(@as(usize, 1920), ansi.viewport.desktop_width);
    try std.testing.expect(ansi.viewport.x > 0 and ansi.viewport.y >= 1);
    try std.testing.expect(ansi.viewport.coordinates(0, 0) == null);
}

test "pixel mouse mapping uses exact pixel boundaries and cursor reuses its image" {
    const Viewport = @import("render.zig").Viewport;
    const v: Viewport = .{ .x = 80, .y = 40, .width = 800, .height = 450, .desktop_width = 1920, .desktop_height = 1080 };
    try std.testing.expect(v.coordinates(79, 40) == null);
    try std.testing.expectEqual([2]i32{ 1, 1 }, v.coordinates(80, 40).?);
    try std.testing.expectEqual([2]i32{ 1918, 1078 }, v.coordinates(879, 489).?);
    var encoder = try Encoder.init(std.testing.allocator, false);
    defer encoder.deinit();
    const first = try encoder.cursor(81, 43, 10, 20);
    defer std.testing.allocator.free(first);
    const moved = try encoder.cursor(89, 49, 10, 20);
    defer std.testing.allocator.free(moved);
    try std.testing.expect(std.mem.indexOf(u8, first, "a=T,f=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "a=p,i=99") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "X=9,Y=9") != null);
}
