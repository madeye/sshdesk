const std = @import("std");
pub const keys = [_][]const u8{
    "DISPLAY",             "XAUTHORITY",               "WAYLAND_DISPLAY",     "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP", "DBUS_SESSION_BUS_ADDRESS", "YDOTOOL_SOCKET",      "SSHDESK_RENDER",  "SSHDESK_COLOR",
    "SSHDESK_MOUSE",       "SSHDESK_UNICODE",          "SSHDESK_X11_CAPTURE", "SSHDESK_MAX_FPS", "SSHDESK_SCALE",
    "SSHDESK_RESIZE",
};
pub fn validAccount(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.-", ch) == null) return false;
    return true;
}
pub const Entry = struct { key: []const u8, value: []const u8 };
pub fn entry(line: []const u8) ?Entry {
    const equal = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = line[0..equal];
    const value = std.mem.trimEnd(u8, line[equal + 1 ..], "\r");
    for (keys) |allowed| if (std.mem.eql(u8, key, allowed)) return .{ .key = key, .value = value };
    if (std.mem.eql(u8, key, "RUN_AS")) return .{ .key = key, .value = value };
    return null;
}
test "configuration allowlist never evaluates values or accepts unsafe accounts" {
    try std.testing.expect(entry("PATH=/evil") == null);
    try std.testing.expect(entry("source /evil") == null);
    try std.testing.expectEqualStrings("$(touch /tmp/file)", entry("DISPLAY=$(touch /tmp/file)").?.value);
    try std.testing.expect(validAccount("desktop-owner"));
    try std.testing.expect(!validAccount("alice;id"));
    try std.testing.expect(!validAccount("../alice"));
}
