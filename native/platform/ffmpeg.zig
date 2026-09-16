const std = @import("std");
const Frame = @import("../frame.zig").Frame;
const Streams = enum { stdout, stderr };
pub const Backend = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    poller: std.Io.Poller(Streams),
    width: usize,
    height: usize,
    pub fn init(a: std.mem.Allocator, display: []const u8, width: usize, height: usize, fps: f64) !Backend {
        const size = try std.fmt.allocPrint(a, "{d}x{d}", .{ width, height });
        defer a.free(size);
        const rate = try std.fmt.allocPrint(a, "{d}", .{fps});
        defer a.free(rate);
        const address = try std.fmt.allocPrint(a, "{s}+0,0", .{display});
        defer a.free(address);
        const argv = &[_][]const u8{ "ffmpeg", "-nostdin", "-loglevel", "error", "-thread_queue_size", "1", "-f", "x11grab", "-draw_mouse", "0", "-framerate", rate, "-video_size", size, "-i", address, "-pix_fmt", "rgb24", "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1" };
        var child = std.process.Child.init(argv, a);
        child.pgid = 0;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        errdefer {
            @import("../process.zig").terminate(&child);
        }
        try child.waitForSpawn();
        return .{ .allocator = a, .child = child, .poller = std.Io.poll(a, Streams, .{ .stdout = child.stdout.?, .stderr = child.stderr.? }), .width = width, .height = height };
    }
    pub fn capture(self: *Backend, a: std.mem.Allocator) !Frame {
        var timer = try std.time.Timer.start();
        const length = self.width * self.height * 3;
        while (self.poller.reader(.stdout).bufferedLen() < length) {
            if (!try self.poller.pollTimeout(20 * std.time.ns_per_ms)) {
                self.reportFailure();
                return error.FFmpegStreamEnded;
            }
            // Drain stderr independently of frame completion, with bounded retention.
            const stderr = self.poller.reader(.stderr);
            if (stderr.bufferedLen() > 2048) stderr.toss(stderr.bufferedLen() - 2048);
            if (timer.read() > 2 * std.time.ns_per_s) {
                self.reportFailure();
                return error.FFmpegCaptureTimedOut;
            }
        }
        const reader = self.poller.reader(.stdout);
        const complete = reader.bufferedLen() / length;
        if (complete > 1) reader.toss((complete - 1) * length);
        var frame = try Frame.init(a, self.width, self.height);
        errdefer frame.deinit();
        @memcpy(std.mem.sliceAsBytes(frame.pixels), (try reader.take(length)));
        return frame;
    }
    fn reportFailure(self: *Backend) void {
        const bytes = self.poller.reader(.stderr).buffered();
        if (bytes.len == 0) return;
        std.fs.File.stderr().writeAll("ffmpeg: ") catch {};
        std.fs.File.stderr().writeAll(bytes[bytes.len - @min(bytes.len, 2048) ..]) catch {};
        std.fs.File.stderr().writeAll("\n") catch {};
    }
    pub fn deinit(self: *Backend) void {
        self.poller.deinit();
        @import("../process.zig").terminate(&self.child);
    }
};
