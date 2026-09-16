const std = @import("std");
const Desktop = @import("platform.zig").Desktop;
const input = @import("input.zig");
const Png = @import("png.zig").Png;
const A = std.mem.Allocator;
pub const max_command = 65536;
pub const max_text = 16384;
pub const Action = enum { info, screenshot, observe, move, click, scroll, type, key, wait, quit, session };
pub const Request = struct {
    id: std.json.Value = .null,
    action: Action,
    x: i32 = 0,
    y: i32 = 0,
    amount: i32 = 0,
    button: u8 = 1,
    count: usize = 1,
    text: []const u8 = "",
    key: input.Key = .enter,
    modifiers: u3 = 0,
    max_width: usize = 0,
    interval_ms: f64 = 0,
    seconds: f64 = 0,
};
fn string(v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}
fn integer(v: std.json.Value) !i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch error.ExpectedInteger,
        else => error.ExpectedInteger,
    };
}
fn number(v: std.json.Value) !f64 {
    const n = switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, s) catch return error.ExpectedNumber,
        else => return error.ExpectedNumber,
    };
    if (!std.math.isFinite(n)) return error.ExpectedFiniteNumber;
    return n;
}
fn get(obj: std.json.ObjectMap, name: []const u8, default: std.json.Value) std.json.Value {
    return obj.get(name) orelse default;
}
fn required(obj: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return obj.get(name) orelse error.MissingRequiredField;
}
pub fn coordinate(v: i64) !i32 {
    if (v < -16384 or v > 65535) return error.CoordinateOutsideSupportedRange;
    return @intCast(v);
}
fn textValid(value: []const u8) !void {
    const count = std.unicode.utf8CountCodepoints(value) catch return error.InvalidUtf8;
    if (count > max_text) return error.TextTooLong;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
}
pub fn parse(value: std.json.Value) !Request {
    if (value != .object) return error.RequestMustBeJsonObject;
    const obj = value.object;
    const action = std.meta.stringToEnum(Action, try string(try required(obj, "action"))) orelse return error.UnknownAction;
    if (action == .session) return error.UnknownAction;
    var req: Request = .{ .action = action, .id = get(obj, "id", .null) };
    switch (action) {
        .move, .click, .scroll => {
            req.x = try coordinate(try integer(try required(obj, "x")));
            req.y = try coordinate(try integer(try required(obj, "y")));
            if (action == .click) {
                const b = try string(get(obj, "button", .{ .string = "left" }));
                req.button = if (std.mem.eql(u8, b, "left")) 1 else if (std.mem.eql(u8, b, "middle")) 2 else if (std.mem.eql(u8, b, "right")) 3 else return error.InvalidButton;
                req.count = @intCast(std.math.clamp(try integer(get(obj, "count", .{ .integer = 1 })), 1, 20));
            }
            if (action == .scroll) req.amount = @intCast(std.math.clamp(try integer(try required(obj, "amount")), -20, 20));
        },
        .type => {
            req.text = try string(get(obj, "text", .{ .string = "" }));
            try textValid(req.text);
            req.interval_ms = std.math.clamp(try number(get(obj, "interval_ms", .{ .integer = 0 })), 0, 1000);
        },
        .key => {
            req.key = try input.named(try string(try required(obj, "key")));
            for ([_][]const u8{ "shift", "alt", "ctrl" }, 0..) |name, i| {
                const v = get(obj, name, .{ .bool = false });
                if (v != .bool) return error.ExpectedBoolean;
                if (v.bool) req.modifiers |= @as(u3, 1) << @intCast(i);
            }
        },
        .screenshot, .observe => req.max_width = @intCast(std.math.clamp(try integer(get(obj, "max_width", .{ .integer = 0 })), 0, 4096)),
        .wait => req.seconds = std.math.clamp(try number(get(obj, "seconds", .{ .integer = 0 })), 0, 10),
        else => {},
    }
    return req;
}
pub const Controller = struct {
    allocator: A,
    desktop: ?Desktop = null,
    capture_name: []const u8 = "auto",
    input_ready: bool = false,
    pub fn deinit(self: *Controller) void {
        if (self.desktop) |*d| d.deinit();
    }
    fn capture(self: *Controller) !*Desktop {
        if (self.desktop == null) self.desktop = try Desktop.init(self.allocator, self.capture_name, false, false);
        return &self.desktop.?;
    }
    fn controls(self: *Controller) !*Desktop {
        const d = try self.capture();
        if (!self.input_ready and !d.synthetic) {
            if (d.backend) |*b| try b.checkInput();
            d.input_enabled = true;
            self.input_ready = true;
        }
        return d;
    }
    pub fn screenshot(self: *Controller, max_width: usize) ![]u8 {
        const desktop = try self.capture();
        var frame = try desktop.capture();
        defer frame.deinit();
        var png = try Png.init();
        defer png.deinit();
        if (max_width > 0 and frame.width > max_width) {
            const h = @max(1, (frame.height * max_width + frame.width / 2) / frame.width);
            var resized = try frame.resize(self.allocator, max_width, h);
            defer resized.deinit();
            return png.encode(self.allocator, resized);
        }
        return png.encode(self.allocator, frame);
    }
    pub fn execute(self: *Controller, req: Request) ![]u8 {
        const a = self.allocator;
        switch (req.action) {
            .info => {
                const d = try self.capture();
                var frame = try d.capture();
                defer frame.deinit();
                return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .ok = true, .platform = d.selection.system, .session = d.selection.session, .capture = d.selection.capture, .input = d.selection.input, .width = d.width, .height = d.height }, .{});
            },
            .observe, .screenshot => {
                const bytes = try self.screenshot(req.max_width);
                defer a.free(bytes);
                const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
                defer a.free(encoded);
                _ = std.base64.standard.Encoder.encode(encoded, bytes);
                return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .ok = true, .width = self.desktop.?.width, .height = self.desktop.?.height, .format = "png", .image_base64 = encoded }, .{});
            },
            .move => try (try self.controls()).move(req.x, req.y),
            .click => {
                const d = try self.controls();
                for (0..req.count) |i| {
                    try d.button(req.button, true, req.x, req.y);
                    try d.button(req.button, false, req.x, req.y);
                    if (i + 1 < req.count) std.Thread.sleep(50 * std.time.ns_per_ms);
                }
            },
            .scroll => try (try self.controls()).scroll(req.amount, req.x, req.y),
            .key => try (try self.controls()).key(.{ .key = req.key, .modifiers = req.modifiers }),
            .type => {
                const d = try self.controls();
                var it = (try std.unicode.Utf8View.init(req.text)).iterator();
                while (it.nextCodepoint()) |cp| {
                    try d.key(.{ .unicode = cp });
                    if (req.interval_ms > 0) std.Thread.sleep(@intFromFloat(req.interval_ms * std.time.ns_per_ms));
                }
            },
            .wait => {
                var remaining: u64 = @intFromFloat(req.seconds * std.time.ns_per_s);
                while (remaining > 0) {
                    if (interrupted.load(.acquire)) return error.Interrupted;
                    const step = @min(remaining, 10 * std.time.ns_per_ms);
                    std.Thread.sleep(step);
                    remaining -= step;
                }
            },
            .quit => return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .ok = true, .quit = true }, .{}),
            .session => return error.UnknownAction,
        }
        return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .ok = true }, .{});
    }
};
pub const Response = struct { bytes: []u8, quit: bool = false };
pub fn respond(controller: *Controller, line: []const u8) !Response {
    const a = controller.allocator;
    if (line.len > max_command) return .{ .bytes = try a.dupe(u8, "{\"ok\":false,\"error\":\"request is too large\"}") };
    var id: std.json.Value = .null;
    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{ .max_value_len = max_command }) catch |err| return failure(a, id, err);
    defer parsed.deinit();
    if (parsed.value == .object) id = get(parsed.value.object, "id", .null);
    const req = parse(parsed.value) catch |err| return failure(a, id, err);
    const bytes = controller.execute(req) catch |err| return failure(a, id, err);
    return .{ .bytes = bytes, .quit = req.action == .quit };
}
fn failure(a: A, id: std.json.Value, err: anyerror) !Response {
    return .{ .bytes = try std.json.Stringify.valueAlloc(a, .{ .id = id, .ok = false, .@"error" = @import("errors.zig").describe(err) }, .{}) };
}
var interrupted = std.atomic.Value(bool).init(false);
fn onSignal(_: c_int) callconv(.c) void {
    interrupted.store(true, .release);
    @import("terminal.zig").cancelOutput();
}
fn writeSession(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (interrupted.load(.acquire)) return error.Interrupted;
        if (!try @import("terminal.zig").outputReady()) continue;
        offset += std.fs.File.stdout().write(bytes[offset..@min(bytes.len, offset + 4096)]) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
    }
}
pub fn session(controller: *Controller) !void {
    interrupted.store(false, .release);
    var signals = @import("terminal.zig").Signals.init(onSignal);
    defer signals.deinit();
    const posix = @import("builtin").os.tag != .windows;
    const original_flags = if (posix) try std.posix.fcntl(std.fs.File.stdout().handle, std.posix.F.GETFL, 0) else 0;
    if (posix) _ = try std.posix.fcntl(std.fs.File.stdout().handle, std.posix.F.SETFL, original_flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    defer if (posix) {
        _ = std.posix.fcntl(std.fs.File.stdout().handle, std.posix.F.SETFL, original_flags) catch 0;
    };
    var line: [max_command + 1]u8 = undefined;
    var length: usize = 0;
    var oversized = false;
    var buffer: [4096]u8 = undefined;
    const stdin = std.fs.File.stdin();
    while (true) {
        if (interrupted.load(.acquire)) return error.Interrupted;
        if (posix) {
            var descriptors = [_]std.posix.pollfd{.{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&descriptors, 25) == 0) continue;
        }
        const n = try stdin.read(&buffer);
        if (n == 0) break;
        for (buffer[0..n]) |byte| {
            if (byte != '\n') {
                if (length < line.len) {
                    line[length] = byte;
                    length += 1;
                } else oversized = true;
                continue;
            }
            const response = try respond(controller, if (oversized) &line else line[0..length]);
            defer controller.allocator.free(response.bytes);
            try writeSession(response.bytes);
            try writeSession("\n");
            if (response.quit) return;
            length = 0;
            oversized = false;
        }
    }
    if (length > 0 or oversized) {
        const response = try respond(controller, if (oversized) &line else line[0..length]);
        defer controller.allocator.free(response.bytes);
        try writeSession(response.bytes);
        try writeSession("\n");
    }
}
test "agent malformed requests, bounds, Unicode, response IDs and recovery" {
    const a = std.testing.allocator;
    var controller: Controller = .{ .allocator = a, .capture_name = "synthetic" };
    defer controller.deinit();
    const requests = [_][]const u8{ "{not json", "[]", "{\"id\":3,\"action\":\"teleport\"}", "{\"id\":4,\"action\":\"move\",\"x\":999999,\"y\":0}" };
    for (requests) |r| {
        const response = try respond(&controller, r);
        defer a.free(response.bytes);
        const json = try std.json.parseFromSlice(std.json.Value, a, response.bytes, .{});
        defer json.deinit();
        try std.testing.expect(!json.value.object.get("ok").?.bool);
    }
    const response = try respond(&controller, "{\"id\":\"世界\",\"action\":\"type\",\"text\":\"🙂; $(id)\"}");
    defer a.free(response.bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, response.bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("世界", parsed.value.object.get("id").?.string);
    const quit = try respond(&controller, "{\"action\":\"quit\"}");
    defer a.free(quit.bytes);
    try std.testing.expect(quit.quit);
}
test "agent screenshot reports desktop dimensions and decoded image dimensions" {
    const a = std.testing.allocator;
    var controller: Controller = .{ .allocator = a, .capture_name = "synthetic" };
    defer controller.deinit();
    var png = try @import("png.zig").Png.init();
    defer png.deinit();
    const response = try respond(&controller, "{\"id\":1,\"action\":\"observe\",\"max_width\":160}");
    defer a.free(response.bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, response.bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1280), parsed.value.object.get("width").?.integer);
    const encoded = parsed.value.object.get("image_base64").?.string;
    const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer a.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    var decoded = try png.decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 160), decoded.width);
    try std.testing.expectEqual(@as(usize, 90), decoded.height);
}

test "JSON actions clamp repetitions and reject non-finite values and oversized Unicode text" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"action\":\"click\",\"x\":0,\"y\":0,\"count\":999}",
        "{\"action\":\"scroll\",\"x\":0,\"y\":0,\"amount\":-999}",
        "{\"action\":\"type\",\"text\":\"世界\",\"interval_ms\":9999}",
    };
    for (cases, 0..) |text, i| {
        const value = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer value.deinit();
        const request = try parse(value.value);
        if (i == 0) try std.testing.expectEqual(@as(usize, 20), request.count);
        if (i == 1) try std.testing.expectEqual(@as(i32, -20), request.amount);
        if (i == 2) try std.testing.expectEqual(@as(f64, 1000), request.interval_ms);
    }
    try std.testing.expectError(error.ExpectedFiniteNumber, number(.{ .string = "nan" }));
    try std.testing.expectError(error.TextTooLong, textValid(&(@as([max_text + 1]u8, @splat('a')))));
    try std.testing.expectError(error.CoordinateOutsideSupportedRange, coordinate(65536));
}

fn responseAllocationExercise(a: A) !void {
    var controller: Controller = .{ .allocator = a, .capture_name = "synthetic" };
    defer controller.deinit();
    const response = try respond(&controller, "{\"id\":\"世界\",\"action\":\"wait\",\"seconds\":0}");
    defer a.free(response.bytes);
}
test "agent JSON response allocation failures release parsed values" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, responseAllocationExercise, .{});
}
