const std = @import("std");
pub const Snapshot = struct {
    fps: f64 = 0,
    capture_fps: f64 = 0,
    changed: f64 = 0,
    capture_ms: f64 = 0,
    render_encode_ms: f64 = 0,
    write_ms: f64 = 0,
    age_ms: f64 = 0,
    tx_kbit: f64 = 0,
    rx_kbit: f64 = 0,
    sent: usize = 0,
    received: u64 = 0,
    rtt_ms: f64 = 0,
    columns: usize = 80,
    rows: usize = 24,
    width: usize = 0,
    height: usize = 0,
    full: usize = 0,
    delta: usize = 0,
    dropped: usize = 0,
    pub fn overlay(self: Snapshot, a: std.mem.Allocator) ![]u8 {
        const text = try std.fmt.allocPrint(a, "SSHDESK {d:.1} updates {d:.1} capture FPS {d:.1}% changed\n" ++
            "cap {d:.1} render/encode {d:.1} write {d:.1} age {d:.1} ms\n" ++
            "tx {d:.0} rx {d:.0} Kbit/s total {d}/{d} KiB RTT {d:.1} ms\n" ++
            "term {d}x{d} remote {d}x{d} full {d} delta {d} drop {d}", .{ self.fps, self.capture_fps, self.changed, self.capture_ms, self.render_encode_ms, self.write_ms, self.age_ms, self.tx_kbit, self.rx_kbit, self.sent / 1024, self.received / 1024, self.rtt_ms, self.columns, self.rows, self.width, self.height, self.full, self.delta, self.dropped });
        defer a.free(text);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var row: usize = 2;
        while (lines.next()) |line| : (row += 1) {
            if (row > self.rows) break;
            try out.writer(a).print("\x1b[{d};1H\x1b[0;37;40m{s}\x1b[0m", .{ row, line[0..@min(line.len, self.columns)] });
        }
        return out.toOwnedSlice(a);
    }
};
test "statistics overlay respects small terminal dimensions" {
    const a = std.testing.allocator;
    const bytes = try (Snapshot{ .columns = 12, .rows = 3 }).overlay(a);
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[4;1H") == null);
}
