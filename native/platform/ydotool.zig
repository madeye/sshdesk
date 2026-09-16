const std = @import("std");
const process = @import("../process.zig");
const input = @import("../input.zig");
pub const Backend = struct {
    allocator: std.mem.Allocator,
    held: [3]bool = @splat(false),
    pub fn init(a: std.mem.Allocator) !Backend {
        var self: Backend = .{ .allocator = a };
        try self.command(&.{"debug"});
        return self;
    }
    fn command(self: *Backend, args: []const []const u8) !void {
        var argv: [32][]const u8 = undefined;
        if (args.len >= argv.len) return error.TooManyArguments;
        argv[0] = "ydotool";
        @memcpy(argv[1..][0..args.len], args);
        var result = process.run(self.allocator, argv[0 .. args.len + 1], 2 * std.time.ns_per_s, 65536) catch |err| {
            if (err == error.FileNotFound) return error.InstallYdotoolAndStartYdotoold;
            return err;
        };
        defer result.deinit();
        if (!result.success()) return error.CheckYdotooldSocketAndUinputPermissions;
    }
    pub fn move(self: *Backend, x: i32, y: i32) !void {
        var bx: [32]u8 = undefined;
        var by: [32]u8 = undefined;
        try self.command(&.{ "mousemove", "--absolute", try std.fmt.bufPrint(&bx, "{d}", .{@max(0, x)}), try std.fmt.bufPrint(&by, "{d}", .{@max(0, y)}) });
    }
    pub fn button(self: *Backend, number: u8, down: bool, x: i32, y: i32) !void {
        if (number < 1 or number > 3) return error.InvalidButton;
        try self.move(x, y);
        const base: u8 = if (number == 1) 0 else if (number == 2) 2 else 1;
        var buf: [32]u8 = undefined;
        try self.command(&.{ "click", "--next-delay", "0", try std.fmt.bufPrint(&buf, "0x{x}", .{base | @as(u8, if (down) 0x40 else 0x80)}) });
        self.held[number - 1] = down;
    }
    pub fn scroll(self: *Backend, amount: i32, x: i32, y: i32) !void {
        try self.move(x, y);
        var buf: [32]u8 = undefined;
        try self.command(&.{ "mousemove", "--wheel", "0", try std.fmt.bufPrint(&buf, "{d}", .{std.math.clamp(amount, -20, 20)}) });
    }
    pub fn key(self: *Backend, event: input.KeyEvent) !void {
        var modifiers = event.modifiers;
        const code: ?u16 = switch (event.key) {
            .character => blk: {
                const cp = event.unicode;
                if (cp >= 'A' and cp <= 'Z') modifiers |= 1;
                if (cp <= 127) {
                    const lower = std.ascii.toLower(@intCast(cp));
                    for ([_][]const u8{ "asdfghjkl", "qwertyuiop", "zxcvbnm" }, [_]u16{ 30, 16, 44 }) |row, base| {
                        if (std.mem.indexOfScalar(u8, row, lower)) |i| break :blk base + @as(u16, @intCast(i));
                    }
                }
                break :blk null;
            },
            .escape => 1,
            .backspace => 14,
            .tab => 15,
            .enter => 28,
            .home => 102,
            .up => 103,
            .page_up => 104,
            .left => 105,
            .right => 106,
            .end => 107,
            .down => 108,
            .page_down => 109,
            .insert => 110,
            .delete => 111,
            .f11 => 87,
            .f12 => 88,
            else => 59 + @as(u16, @intFromEnum(event.key)) - 20,
        };
        if (code == null) {
            if (event.key == .character and event.action == 2 and modifiers == 0) {
                var bytes: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(event.unicode, &bytes);
                try self.command(&.{ "type", "--key-delay", "0", "--", bytes[0..n] });
            }
            return;
        }
        var args: [11][]const u8 = undefined;
        var storage: [8][16]u8 = undefined;
        var n: usize = 3;
        var s: usize = 0;
        args[0] = "key";
        args[1] = "--key-delay";
        args[2] = "0";
        const mods = [_]u16{ 42, 56, 29 };
        if (event.action != 1) {
            for (mods, 0..) |m, i| if (modifiers & (@as(u3, 1) << @intCast(i)) != 0) {
                args[n] = try std.fmt.bufPrint(&storage[s], "{d}:1", .{m});
                n += 1;
                s += 1;
            };
            args[n] = try std.fmt.bufPrint(&storage[s], "{d}:1", .{code.?});
            n += 1;
            s += 1;
        }
        if (event.action != 0) {
            args[n] = try std.fmt.bufPrint(&storage[s], "{d}:0", .{code.?});
            n += 1;
            s += 1;
            for (0..3) |j| {
                const i = 2 - j;
                if (modifiers & (@as(u3, 1) << @intCast(i)) != 0) {
                    args[n] = try std.fmt.bufPrint(&storage[s], "{d}:0", .{mods[i]});
                    n += 1;
                    s += 1;
                }
            }
        }
        try self.command(args[0..n]);
    }
    pub fn deinit(self: *Backend) void {
        for (self.held, 0..) |held, i| if (held) {
            self.button(@intCast(i + 1), false, 0, 0) catch {};
        };
    }
};
