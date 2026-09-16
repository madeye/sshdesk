const std = @import("std");
pub const Key = enum(u8) { character = 0, enter = 1, escape = 2, backspace = 3, tab = 4, up = 5, down = 6, right = 7, left = 8, home = 9, end = 10, page_up = 11, page_down = 12, insert = 13, delete = 14, f1 = 20, f2 = 21, f3 = 22, f4 = 23, f5 = 24, f6 = 25, f7 = 26, f8 = 27, f9 = 28, f10 = 29, f11 = 30, f12 = 31 };
pub const KeyEvent = struct { key: Key = .character, unicode: u21 = 0, modifiers: u3 = 0, action: u2 = 2 };
pub const Point = struct { column: i32, row: i32 };
pub const Event = union(enum) {
    key: KeyEvent,
    exit,
    stats,
    move: Point,
    button: struct { point: Point, button: u8, pressed: bool },
    scroll: struct { point: Point, amount: i32 },
    report: Point,
};
pub fn named(name: []const u8) !Key {
    inline for (std.meta.fields(Key)) |field| {
        if (field.value != 0) {
            const candidate = comptime blk: {
                var bytes: [field.name.len]u8 = undefined;
                for (field.name, 0..) |c, i| bytes[i] = if (c == '_') '-' else c;
                break :blk bytes;
            };
            if (std.ascii.eqlIgnoreCase(name, &candidate)) return @enumFromInt(field.value);
        }
    }
    return error.UnknownKey;
}
pub fn keysym(event: KeyEvent) u32 {
    return switch (event.key) {
        .character => if (event.unicode <= 255) event.unicode else 0x01000000 | @as(u32, event.unicode),
        .enter => 0xff0d,
        .escape => 0xff1b,
        .backspace => 0xff08,
        .tab => 0xff09,
        .home => 0xff50,
        .left => 0xff51,
        .up => 0xff52,
        .right => 0xff53,
        .down => 0xff54,
        .page_up => 0xff55,
        .page_down => 0xff56,
        .end => 0xff57,
        .insert => 0xff63,
        .delete => 0xffff,
        else => 0xffbe + @as(u32, @intFromEnum(event.key)) - 20,
    };
}
pub const Parser = struct {
    buffer: [8192]u8 = undefined,
    len: usize = 0,
    detach: bool = false,
    escape_since: ?i64 = null,
    legacy_button: u8 = 1,
    pub fn feed(self: *Parser, data: []const u8) !void {
        if (data.len > self.buffer.len - self.len) {
            self.len = 0;
            return error.InputSequenceTooLarge;
        }
        @memcpy(self.buffer[self.len..][0..data.len], data);
        self.len += data.len;
    }
    fn consume(self: *Parser, n: usize) void {
        std.mem.copyForwards(u8, self.buffer[0 .. self.len - n], self.buffer[n..self.len]);
        self.len -= n;
        self.escape_since = null;
    }
    fn tap(key: Key, mods: u3, unicode: u21) Event {
        return .{ .key = .{ .key = key, .modifiers = mods, .unicode = unicode } };
    }
    fn mouse(self: *Parser, code: u32, x: u32, y: u32, pressed: bool, legacy: bool) ?Event {
        const p: Point = .{ .column = @intCast(x -| 1), .row = @intCast(y -| 1) };
        if (code & 64 != 0) return .{ .scroll = .{ .point = p, .amount = if (code & 1 != 0) -1 else 1 } };
        if (code & 32 != 0) return .{ .move = p };
        var button: u8 = @intCast((code & 3) + 1);
        var down = pressed;
        if (legacy) {
            if (button == 4) {
                button = self.legacy_button;
                down = false;
            } else self.legacy_button = button;
        }
        if (button > 3) return null;
        return .{ .button = .{ .point = p, .button = button, .pressed = down } };
    }
    pub fn next(self: *Parser, now_ms: i64) ?Event {
        while (self.len > 0) {
            const first = self.buffer[0];
            if (self.detach) {
                self.detach = false;
                if (first == 0x1d) {
                    self.consume(1);
                    return .exit;
                }
                return tap(.character, 4, ']');
            }
            switch (first) {
                0x1d => {
                    self.consume(1);
                    self.detach = true;
                    continue;
                },
                0x13 => {
                    self.consume(1);
                    return .stats;
                },
                10, 13 => {
                    self.consume(1);
                    return tap(.enter, 0, 0);
                },
                8, 127 => {
                    self.consume(1);
                    return tap(.backspace, 0, 0);
                },
                9 => {
                    self.consume(1);
                    return tap(.tab, 0, 0);
                },
                else => {},
            }
            if (first >= 1 and first <= 26) {
                self.consume(1);
                return tap(.character, 4, 'a' + @as(u21, first) - 1);
            }
            var offset: usize = 0;
            var mods: u3 = 0;
            if (first == 27) {
                if (self.escape_since == null) self.escape_since = now_ms;
                if (self.len >= 3 and self.buffer[1] == 'O') {
                    const key: ?Key = switch (self.buffer[2]) {
                        'P' => .f1,
                        'Q' => .f2,
                        'R' => .f3,
                        'S' => .f4,
                        'H' => .home,
                        'F' => .end,
                        else => null,
                    };
                    if (key) |k| {
                        self.consume(3);
                        return tap(k, 0, 0);
                    }
                }
                if (self.len >= 3 and self.buffer[1] == '[') {
                    if (self.buffer[2] == 'M') {
                        if (self.len < 6) return null;
                        const code = self.buffer[3] -| 32;
                        const x = self.buffer[4] -| 32;
                        const y = self.buffer[5] -| 32;
                        self.consume(6);
                        if (self.mouse(code, x, y, true, true)) |e| return e;
                        continue;
                    }
                    var end: usize = 2;
                    while (end < self.len and !(self.buffer[end] >= 0x40 and self.buffer[end] <= 0x7e)) : (end += 1) {}
                    if (end < self.len) {
                        const final = self.buffer[end];
                        const is_mouse = self.buffer[2] == '<';
                        var parts = std.mem.splitScalar(u8, self.buffer[if (is_mouse) 3 else 2..end], ';');
                        var values = [_]u32{ 0, 0, 0 };
                        var n: usize = 0;
                        var valid = true;
                        while (parts.next()) |part| {
                            if (n == 3) {
                                valid = false;
                                break;
                            }
                            values[n] = if (part.len == 0) 0 else std.fmt.parseInt(u32, part, 10) catch {
                                valid = false;
                                break;
                            };
                            n += 1;
                        }
                        if (valid and is_mouse and n == 3 and values[0] <= 99999 and values[1] <= 99999 and values[2] <= 99999 and (final == 'M' or final == 'm')) {
                            self.consume(end + 1);
                            if (self.mouse(values[0], values[1], values[2], final == 'M', false)) |e| return e;
                            continue;
                        }
                        if (valid and !is_mouse) {
                            if (final == 'R' and n == 2 and values[0] <= 9999 and values[1] <= 9999) {
                                self.consume(end + 1);
                                return .{ .report = .{ .row = @intCast(values[0] -| 1), .column = @intCast(values[1] -| 1) } };
                            }
                            mods = @truncate(if (n > 1) values[1] -| 1 else 0);
                            const key: ?Key = switch (final) {
                                'P' => .f1,
                                'Q' => .f2,
                                'S' => .f4,
                                'A' => .up,
                                'B' => .down,
                                'C' => .right,
                                'D' => .left,
                                'H' => .home,
                                'F' => .end,
                                'Z' => .tab,
                                '~' => switch (values[0]) {
                                    1 => .home,
                                    2 => .insert,
                                    3 => .delete,
                                    4 => .end,
                                    5 => .page_up,
                                    6 => .page_down,
                                    15 => .f5,
                                    17 => .f6,
                                    18 => .f7,
                                    19 => .f8,
                                    20 => .f9,
                                    21 => .f10,
                                    23 => .f11,
                                    24 => .f12,
                                    else => null,
                                },
                                else => null,
                            };
                            if (key) |k| {
                                self.consume(end + 1);
                                return tap(k, mods | @as(u3, if (final == 'Z') 1 else 0), 0);
                            }
                        }
                    }
                }
                if (self.len >= 2 and self.buffer[1] != '[' and self.buffer[1] != 'O') {
                    offset = 1;
                    mods = 2;
                } else {
                    if (now_ms - self.escape_since.? < 35) return null;
                    self.consume(1);
                    return tap(.escape, 0, 0);
                }
            }
            const length = std.unicode.utf8ByteSequenceLength(self.buffer[offset]) catch 1;
            if (self.len - offset < length) return null;
            const cp = std.unicode.utf8Decode(self.buffer[offset..][0..length]) catch {
                self.consume(offset + 1);
                return tap(.character, mods, 0xfffd);
            };
            self.consume(offset + length);
            if (cp >= 'A' and cp <= 'Z') mods |= 1;
            return tap(.character, mods, cp);
        }
        return null;
    }
};
test "fragmented UTF8, escape timeout, detach, modifiers and mouse" {
    var p: Parser = .{};
    try p.feed("\xe4\xb8");
    try std.testing.expect(p.next(0) == null);
    try p.feed("\x96");
    try std.testing.expectEqual(@as(u21, '世'), p.next(1).?.key.unicode);
    try p.feed("\x1b[");
    try std.testing.expect(p.next(2) == null);
    try p.feed("1;5A");
    try std.testing.expectEqual(KeyEvent{ .key = .up, .modifiers = 4 }, p.next(3).?.key);
    try p.feed("\x1b");
    try std.testing.expect(p.next(10) == null);
    try std.testing.expectEqual(Key.escape, p.next(45).?.key.key);
    try p.feed("\x1b[<0;5;8M\x1b[<0;5;8m");
    try std.testing.expect(p.next(50).?.button.pressed);
    try std.testing.expect(!p.next(50).?.button.pressed);
    try p.feed("\x1d\x1d");
    try std.testing.expect(p.next(50).? == .exit);
    try p.feed("\x13");
    try std.testing.expect(p.next(51).? == .stats);
    try std.testing.expectEqual(@as(u32, 0x01004e16), keysym(.{ .unicode = '世' }));
}
test "input bound and special key names" {
    var p: Parser = .{};
    try std.testing.expectError(error.InputSequenceTooLarge, p.feed(&(@as([8193]u8, @splat('a')))));
    try std.testing.expectEqual(Key.page_up, try named("page-up"));
    try std.testing.expectError(error.UnknownKey, named("$(id)"));
}

test "key mapping, SGR scroll and legacy release preserve terminal semantics" {
    var p: Parser = .{};
    try p.feed("aA\r\x7f\t\x1b[A\x1b[24~\x01");
    for ([_]Key{ .character, .character, .enter, .backspace, .tab, .up, .f12, .character }, 0..) |key, i| {
        const event = p.next(0).?.key;
        try std.testing.expectEqual(key, event.key);
        if (i == 7) try std.testing.expectEqual(@as(u3, 4), event.modifiers);
    }
    try p.feed("\x1b[<32;11;6M\x1b[<64;11;6M\x1b[<65;11;6M");
    try std.testing.expectEqual(Point{ .column = 10, .row = 5 }, p.next(1).?.move);
    try std.testing.expectEqual(@as(i32, 1), p.next(1).?.scroll.amount);
    try std.testing.expectEqual(@as(i32, -1), p.next(1).?.scroll.amount);
    try p.feed("\x1b[M" ++ [_]u8{ 35, 42, 37 });
    try std.testing.expect(!p.next(1).?.button.pressed);
    try p.feed("\x1b[1;2D\x1b[3;3~\x1b[Z");
    try std.testing.expectEqual(KeyEvent{ .key = .left, .modifiers = 1 }, p.next(2).?.key);
    try std.testing.expectEqual(KeyEvent{ .key = .delete, .modifiers = 2 }, p.next(2).?.key);
    try std.testing.expectEqual(KeyEvent{ .key = .tab, .modifiers = 1 }, p.next(2).?.key);
}

test "legacy mouse, modified function keys, cursor replies and Alt remain distinct" {
    var parser: Parser = .{};
    try parser.feed("\x1b[M");
    try std.testing.expect(parser.next(0) == null);
    try parser.feed(&.{ 32, 37, 40 });
    const click = parser.next(1).?.button;
    try std.testing.expect(click.pressed);
    try std.testing.expectEqual(Point{ .column = 4, .row = 7 }, click.point);
    try parser.feed("\x1b[1;2P\x1b[12;34R\x1bx");
    try std.testing.expectEqual(KeyEvent{ .key = .f1, .modifiers = 1 }, parser.next(2).?.key);
    var report: ?Point = null;
    var alt: ?KeyEvent = null;
    while (parser.next(100)) |event| switch (event) {
        .report => |p| report = p,
        .key => |key| if (key.unicode == 'x') {
            alt = key;
        },
        else => {},
    };
    try std.testing.expectEqual(Point{ .column = 33, .row = 11 }, report.?);
    try std.testing.expectEqual(@as(u3, 2), alt.?.modifiers);
}

pub const Coalescer = struct {
    pending: ?Event = null,
    pub fn push(self: *Coalescer, event: Event, out: *[2]Event) usize {
        if (event == .move) {
            self.pending = event;
            return 0;
        }
        var count: usize = 0;
        if (self.pending) |move| {
            out[0] = move;
            count = 1;
            self.pending = null;
        }
        out[count] = event;
        return count + 1;
    }
    pub fn flush(self: *Coalescer) ?Event {
        const result = self.pending;
        self.pending = null;
        return result;
    }
};
test "mouse motion coalescing preserves clicks and the final motion" {
    var coalescer: Coalescer = .{};
    var out: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), coalescer.push(.{ .move = .{ .column = 1, .row = 2 } }, &out));
    try std.testing.expectEqual(@as(usize, 0), coalescer.push(.{ .move = .{ .column = 3, .row = 4 } }, &out));
    const click: Event = .{ .button = .{ .point = .{ .column = 3, .row = 4 }, .button = 1, .pressed = true } };
    try std.testing.expectEqual(@as(usize, 2), coalescer.push(click, &out));
    try std.testing.expectEqual(Point{ .column = 3, .row = 4 }, out[0].move);
    try std.testing.expectEqual(click, out[1]);
    _ = coalescer.push(.{ .move = .{ .column = 5, .row = 6 } }, &out);
    try std.testing.expectEqual(Point{ .column = 5, .row = 6 }, coalescer.flush().?.move);
    try std.testing.expect(coalescer.flush() == null);
}
