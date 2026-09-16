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
pub const Adaptive = struct {
    maximum_fps: f64 = 60,
    scale: f64 = 1,
    automatic_scale: bool = true,
    write_ms: f64 = 0,
    rtt_ms: f64 = 0,
    pub fn observe(self: *Adaptive, write_ms: f64, rtt_ms: f64) void {
        self.write_ms = self.write_ms * 0.8 + write_ms * 0.2;
        self.rtt_ms = self.rtt_ms * 0.8 + rtt_ms * 0.2;
        if (self.automatic_scale) {
            if (self.write_ms > 80) self.scale = @max(0.25, self.scale - 0.05) else if (self.write_ms < 20) self.scale = @min(1, self.scale + 0.01);
        }
    }
    pub fn interval(self: Adaptive, pending_ms: f64) u64 {
        const milliseconds = @max(1000 / self.maximum_fps, @max(self.write_ms * 1.15, @max(self.rtt_ms / 2, pending_ms / 2)));
        return @intFromFloat(@min(2000, milliseconds) * std.time.ns_per_ms);
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
    for (0..20) |_| adaptive.observe(200, 100);
    try std.testing.expect(adaptive.scale >= 0.25 and adaptive.scale < 1);
    try std.testing.expect(adaptive.interval(1000) >= 500 * std.time.ns_per_ms);
}
