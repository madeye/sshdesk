const std = @import("std");
const routing = @import("routing.zig");
const cli = @import("cli.zig");
const process = @import("process.zig");
const A = std.mem.Allocator;
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn run(a: A, command: []const u8, args: []const []const u8) !u8 {
    if (args.len == 0 or !routing.validTarget(args[0])) return error.InvalidSshTarget;
    if (eq(command, "sshdesk-split")) return split(a, args);
    var offset: usize = 1;
    var timeout: f64 = 30;
    if (args.len > offset and eq(args[offset], "--timeout")) {
        if (args.len <= offset + 1) return error.MissingOptionValue;
        timeout = try std.fmt.parseFloat(f64, args[offset + 1]);
        offset += 2;
    }
    if (!std.math.isFinite(timeout) or timeout <= 0 or timeout > 86400) return error.InvalidTimeout;
    const parsed = try cli.parseAgent(args[offset..]);
    if (parsed.request.action == .session) return process.inherited(a, &.{ "ssh", args[0], "sshdesk-agent", "session" });
    const req = parsed.request;
    const name = @tagName(req.action);
    const key_name = try a.dupe(u8, @tagName(req.key));
    defer a.free(key_name);
    for (key_name) |*c| {
        if (c.* == '_') c.* = '-';
    }
    const request = try std.json.Stringify.valueAlloc(a, .{ .id = 1, .action = name, .x = req.x, .y = req.y, .amount = req.amount, .button = if (req.button == 1) "left" else if (req.button == 2) "middle" else "right", .count = req.count, .text = req.text, .key = key_name, .ctrl = req.modifiers & 4 != 0, .alt = req.modifiers & 2 != 0, .shift = req.modifiers & 1 != 0, .max_width = req.max_width, .interval_ms = req.interval_ms }, .{});
    defer a.free(request);
    const payload = try std.mem.concat(a, u8, &.{ request, "\n" });
    defer a.free(payload);
    var result = try process.runWithInput(a, &.{ "ssh", args[0], "sshdesk-agent", "session" }, payload, @intFromFloat(timeout * std.time.ns_per_s), 64 * 1024 * 1024);
    defer result.deinit();
    if (!result.success()) return error.RemoteSshFailed;
    var json = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, result.stdout, " \r\n\t"), .{});
    defer json.deinit();
    if (json.value != .object) return error.InvalidRemoteResponse;
    const ok = json.value.object.get("ok") orelse return error.InvalidRemoteResponse;
    if (ok != .bool or !ok.bool) return error.RemoteActionFailed;
    if (req.action == .screenshot or req.action == .observe) {
        const encoded = json.value.object.get("image_base64") orelse return error.InvalidRemoteResponse;
        if (encoded != .string) return error.InvalidRemoteResponse;
        const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded.string));
        defer a.free(bytes);
        try std.base64.standard.Decoder.decode(bytes, encoded.string);
        try cli.writeImage(parsed.output, bytes);
    } else if (req.action == .info) {
        _ = json.value.object.swapRemove("id");
        _ = json.value.object.swapRemove("ok");
        const output = try std.json.Stringify.valueAlloc(a, json.value, .{});
        defer a.free(output);
        try std.fs.File.stdout().writeAll(output);
        try std.fs.File.stdout().writeAll("\n");
    }
    return 0;
}
fn split(a: A, args: []const []const u8) !u8 {
    var direction: []const u8 = "right";
    var size: []const u8 = "50";
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingOptionValue;
        if (eq(args[i], "--direction")) direction = args[i + 1] else if (eq(args[i], "--size")) size = args[i + 1] else return error.UnknownOption;
    }
    if (!eq(direction, "right") and !eq(direction, "left") and !eq(direction, "up") and !eq(direction, "down")) return error.InvalidDirection;
    const n = try std.fmt.parseInt(u8, size, 10);
    if (n < 20 or n > 80) return error.OptionOutOfRange;
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    const existing = env.get("TMUX") != null;
    const session = try std.fmt.allocPrint(a, "sshdesk-{x}", .{std.crypto.random.int(u64)});
    defer a.free(session);
    const pane = if (existing) env.get("TMUX_PANE") orelse return error.InvalidTmuxPane else session;
    if (existing) {
        if (pane.len < 2 or pane[0] != '%') return error.InvalidTmuxPane;
        _ = std.fmt.parseInt(u32, pane[1..], 10) catch return error.InvalidTmuxPane;
    }
    if (!existing) {
        if (try process.inherited(a, &.{ "tmux", "new-session", "-d", "-s", session }) != 0) return error.TmuxFailed;
    }
    errdefer if (!existing) {
        _ = process.inherited(a, &.{ "tmux", "kill-session", "-t", session }) catch 1;
    };
    if (try process.inherited(a, &.{ "tmux", "set-option", "-t", pane, "allow-passthrough", "on" }) != 0) return error.TmuxFailed;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "tmux", "split-window", if (eq(direction, "left") or eq(direction, "right")) "-h" else "-v" });
    if (eq(direction, "left") or eq(direction, "up")) try argv.append(a, "-b");
    try argv.appendSlice(a, &.{ "-p", size, "-t", pane, "--", "ssh", args[0] });
    const code = try process.inherited(a, argv.items);
    if (existing) return code;
    if (code != 0) return error.TmuxFailed;
    return process.inherited(a, &.{ "tmux", "attach-session", "-t", session });
}
