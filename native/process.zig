const std = @import("std");
pub const Result = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
    pub fn success(self: Result) bool {
        return switch (self.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }
};
pub fn run(a: std.mem.Allocator, argv: []const []const u8, timeout_ns: u64, maximum: usize) !Result {
    return runWithInput(a, argv, null, timeout_ns, maximum);
}
const InputWriter = struct {
    file: std.fs.File,
    bytes: []const u8,
    fn run(self: InputWriter) void {
        defer self.file.close();
        self.file.writeAll(self.bytes) catch {};
    }
};
pub fn runWithInput(a: std.mem.Allocator, argv: []const []const u8, bytes: ?[]const u8, timeout_ns: u64, maximum: usize) !Result {
    var child = std.process.Child.init(argv, a);
    if (@import("builtin").os.tag != .windows) child.pgid = 0;
    child.stdin_behavior = if (bytes != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const group_id = if (@import("builtin").os.tag != .windows) child.id else 0;
    var reaped = false;
    var writer: ?std.Thread = null;
    defer {
        if (!reaped) {
            terminate(&child);
        }
        if (@import("builtin").os.tag != .windows) std.posix.kill(-group_id, std.posix.SIG.KILL) catch {};
        if (writer) |thread| thread.join();
    }
    if (bytes) |data| {
        writer = try std.Thread.spawn(.{}, InputWriter.run, .{InputWriter{ .file = child.stdin.?, .bytes = data }});
        child.stdin = null;
    }
    var poller = std.Io.poll(a, enum { stdout, stderr }, .{ .stdout = child.stdout.?, .stderr = child.stderr.? });
    defer poller.deinit();
    var timer = try std.time.Timer.start();
    while (try poller.pollTimeout(10 * std.time.ns_per_ms)) {
        if (timer.read() >= timeout_ns) return error.ChildTimedOut;
        if (poller.reader(.stdout).bufferedLen() > maximum or poller.reader(.stderr).bufferedLen() > maximum) return error.ChildOutputTooLarge;
    }
    if (poller.reader(.stdout).bufferedLen() > maximum or poller.reader(.stderr).bufferedLen() > maximum) return error.ChildOutputTooLarge;
    // A process may close both pipes before exiting. Enforce the same deadline
    // while waiting rather than allowing a closed-pipe child to hang cleanup.
    if (@import("builtin").os.tag == .windows) {
        const w = std.os.windows;
        while (w.kernel32.WaitForSingleObject(child.id, 10) == w.WAIT_TIMEOUT) {
            if (timer.read() >= timeout_ns) return error.ChildTimedOut;
        }
    } else {
        while (true) {
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) {
                const status = result.status;
                child.term = if (std.posix.W.IFEXITED(status)) .{ .Exited = std.posix.W.EXITSTATUS(status) } else if (std.posix.W.IFSIGNALED(status)) .{ .Signal = std.posix.W.TERMSIG(status) } else .{ .Unknown = status };
                break;
            }
            if (timer.read() >= timeout_ns) return error.ChildTimedOut;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }
    const term = try child.wait();
    reaped = true;
    const stdout = try poller.toOwnedSlice(.stdout);
    errdefer a.free(stdout);
    return .{ .allocator = a, .stdout = stdout, .stderr = try poller.toOwnedSlice(.stderr), .term = term };
}
pub fn inherited(a: std.mem.Allocator, argv: []const []const u8) !u8 {
    var child = std.process.Child.init(argv, a);
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}
test "subprocess output bound, timeout, and reaping closed pipes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var result = try run(a, &.{ "/bin/sh", "-c", "printf hello" }, std.time.ns_per_s, 100);
    defer result.deinit();
    try std.testing.expect(result.success());
    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectError(error.ChildOutputTooLarge, run(a, &.{ "/bin/sh", "-c", "printf 123456789" }, std.time.ns_per_s, 4));
    try std.testing.expectError(error.ChildTimedOut, run(a, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec sleep 2" }, 20 * std.time.ns_per_ms, 100));
}

/// Child.kill() uses an unbounded SIGTERM wait on POSIX. Capture helpers may
/// ignore TERM while blocked on output, so always bound termination and reap.
pub fn terminate(child: *std.process.Child) void {
    if (@import("builtin").os.tag == .windows) {
        _ = child.kill() catch {};
        return;
    }
    const group_id = if (child.pgid == 0) child.id else 0;
    defer if (group_id != 0) {
        std.posix.kill(-group_id, std.posix.SIG.KILL) catch {};
    };
    if (child.term != null) {
        _ = child.wait() catch {};
        return;
    }
    std.posix.kill(if (group_id != 0) -group_id else child.id, std.posix.SIG.TERM) catch {};
    var timer = std.time.Timer.start() catch {
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
        return;
    };
    while (timer.read() < 500 * std.time.ns_per_ms) {
        const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (result.pid != 0) {
            const status = result.status;
            child.term = if (std.posix.W.IFEXITED(status)) .{ .Exited = std.posix.W.EXITSTATUS(status) } else if (std.posix.W.IFSIGNALED(status)) .{ .Signal = std.posix.W.TERMSIG(status) } else .{ .Unknown = status };
            _ = child.wait() catch {};
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
    _ = child.wait() catch {};
}

test "timeouts escalate past a helper that ignores SIGTERM" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var timer = try std.time.Timer.start();
    try std.testing.expectError(error.ChildTimedOut, run(std.testing.allocator, &.{ "/bin/sh", "-c", "trap '' TERM; exec sleep 30" }, 50 * std.time.ns_per_ms, 100));
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
}

test "helper descendants cannot retain pipes and block input-writer cleanup" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const payload = try a.alloc(u8, 1024 * 1024);
    defer a.free(payload);
    @memset(payload, 'x');
    var timer = try std.time.Timer.start();
    try std.testing.expectError(error.ChildTimedOut, runWithInput(a, &.{ "/bin/sh", "-c", "sleep 10 & wait" }, payload, 50 * std.time.ns_per_ms, 100));
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
}
