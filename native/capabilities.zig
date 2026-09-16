const std = @import("std");
const Color = @import("render.zig").Color;
pub const Capabilities = struct { color: Color, mouse: bool, unicode: bool };
fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn contains(s: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(s, needle) != null;
}
fn boolean(value: []const u8, default: bool) !bool {
    if (eq(value, "auto")) return default;
    for ([_][]const u8{ "0", "false", "no" }) |word| if (eq(value, word)) return false;
    for ([_][]const u8{ "1", "true", "yes" }) |word| if (eq(value, word)) return true;
    return error.InvalidTerminalBoolean;
}
pub fn detect(env: *const std.process.EnvMap) !Capabilities {
    const term = env.get("TERM") orelse return error.AnsiTerminalRequired;
    if (term.len == 0 or eq(term, "dumb") or eq(term, "unknown")) return error.AnsiTerminalRequired;
    const override = env.get("SSHDESK_COLOR") orelse "auto";
    const colorterm = env.get("COLORTERM") orelse "";
    var color: Color = .ansi16;
    if (eq(override, "auto") or override.len == 0) {
        if (eq(colorterm, "truecolor") or eq(colorterm, "24bit") or contains(term, "direct") or contains(term, "kitty") or contains(term, "wezterm") or contains(term, "alacritty")) color = .truecolor else if (contains(term, "256color")) color = .ansi256;
    } else if (eq(override, "truecolor") or eq(override, "24bit") or eq(override, "24-bit")) color = .truecolor else if (eq(override, "256") or eq(override, "256color")) color = .ansi256 else if (eq(override, "16") or eq(override, "ansi") or eq(override, "basic")) color = .ansi16 else return error.InvalidColor;
    var unicode = false;
    for ([_][]const u8{ "xterm", "screen", "tmux", "rxvt", "kitty", "wezterm", "alacritty", "linux" }) |name| {
        if (contains(term, name)) unicode = true;
    }
    return .{ .color = color, .mouse = try boolean(env.get("SSHDESK_MOUSE") orelse "auto", true), .unicode = try boolean(env.get("SSHDESK_UNICODE") orelse "auto", unicode) };
}
pub fn nextScale(current: f64, latency_ms: f64, write_ms: f64) f64 {
    if (latency_ms >= 250 or write_ms >= 30) return @max(0.5, @round(current * 0.75 * 100) / 100);
    if (latency_ms >= 100 or write_ms >= 14) return @max(0.5, @round(current * 0.85 * 100) / 100);
    if (current < 1 and latency_ms < 60 and write_ms > 0 and write_ms < 8) return @min(1, @round(current * 1.08 * 100) / 100);
    return current;
}
pub fn limitedRate(maximum: f64, latency_ms: f64, write_ms: f64) f64 {
    var rate = maximum;
    if (latency_ms >= 500) rate = @min(rate, 10) else if (latency_ms >= 250) rate = @min(rate, 15) else if (latency_ms >= 100) rate = @min(rate, 30);
    if (write_ms > 0) rate = @min(rate, 1000 / @max(1, write_ms * 2));
    return @max(0.5, rate);
}
pub const Adaptive = struct {
    maximum_fps: f64 = 60,
    scale: f64 = 1,
    automatic_scale: bool = true,
    write_ms: f64 = 0,
    rtt_ms: f64 = 0,
    last_adjust_ns: u64 = 0,
    pub fn observe(self: *Adaptive, write_ms: f64, rtt_ms: f64) void {
        self.write_ms = self.write_ms * 0.8 + write_ms * 0.2;
        self.rtt_ms = self.rtt_ms * 0.8 + rtt_ms * 0.2;
    }
    pub fn adjust(self: *Adaptive, now: u64, pending_ms: f64) void {
        if (!self.automatic_scale) return;
        const scale = nextScale(self.scale, @max(self.rtt_ms, pending_ms), self.write_ms);
        const cooldown: u64 = if (scale < self.scale) 2 * std.time.ns_per_s else 8 * std.time.ns_per_s;
        if (scale != self.scale and now -| self.last_adjust_ns >= cooldown) {
            self.scale = scale;
            self.last_adjust_ns = now;
        }
    }
    pub fn interval(self: Adaptive, pending_ms: f64) u64 {
        return @intFromFloat(std.time.ns_per_s / limitedRate(self.maximum_fps, @max(self.rtt_ms, pending_ms), self.write_ms));
    }
};
test "capability overrides and adaptive backpressure bounds" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.AnsiTerminalRequired, detect(&env));
    try env.put("TERM", "xterm-256color");
    try std.testing.expectEqual(Color.ansi256, (try detect(&env)).color);
    try env.put("COLORTERM", "truecolor");
    try std.testing.expectEqual(Color.truecolor, (try detect(&env)).color);
    try env.put("SSHDESK_UNICODE", "0");
    try std.testing.expect(!(try detect(&env)).unicode);
    try env.put("SSHDESK_MOUSE", "invalid");
    try std.testing.expectError(error.InvalidTerminalBoolean, detect(&env));
    var adaptive: Adaptive = .{};
    for (0..20) |i| {
        adaptive.observe(200, 100);
        adaptive.adjust(i * 2 * std.time.ns_per_s, 0);
    }
    try std.testing.expect(adaptive.scale >= 0.25 and adaptive.scale < 1);
    try std.testing.expect(adaptive.interval(1000) >= 100 * std.time.ns_per_ms);
}

test "reference adaptive scale and terminal backpressure thresholds" {
    try std.testing.expectEqual(@as(f64, 0.75), nextScale(1, 260, 5));
    try std.testing.expectEqual(@as(f64, 0.81), nextScale(0.75, 40, 4));
    try std.testing.expectEqual(@as(f64, 0.5), nextScale(0.5, 500, 50));
    try std.testing.expectEqual(@as(f64, 60), limitedRate(60, 0, 5));
    try std.testing.expectEqual(@as(f64, 30), limitedRate(60, 150, 5));
    try std.testing.expectEqual(@as(f64, 20), limitedRate(60, 0, 25));
    try std.testing.expect(limitedRate(60, 600, 0) <= 10);
}
