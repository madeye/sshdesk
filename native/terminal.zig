const std = @import("std");
const builtin = @import("builtin");
const windows = builtin.os.tag == .windows;
const c = if (windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("termios.h");
});
var output_thread: if (windows) c.HANDLE else void = if (windows) null else {};
pub fn cancelOutput() void {
    if (windows) if (output_thread != null) {
        _ = c.CancelSynchronousIo(output_thread);
    };
}
pub fn cancelThread(thread: std.Thread) void {
    if (windows) _ = c.CancelSynchronousIo(thread.getHandle());
}
pub fn cleanup(bytes: []const u8) void {
    if (!windows) {
        std.fs.File.stdout().writeAll(bytes) catch {};
        return;
    }
    const Writer = struct {
        bytes: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            std.fs.File.stdout().writeAll(self.bytes) catch {};
        }
    };
    var writer: Writer = .{ .bytes = bytes };
    const thread = std.Thread.spawn(.{}, Writer.run, .{&writer}) catch return;
    var waited: usize = 0;
    while (!writer.done.load(.acquire)) : (waited += 1) {
        if (waited >= 100) cancelThread(thread);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    thread.join();
}
pub const State = if (windows) struct {
    input_mode: c.DWORD,
    output_mode: c.DWORD,
    pub fn enter() !@This() {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        var input_mode: c.DWORD = 0;
        var output_mode: c.DWORD = 0;
        if (c.GetConsoleMode(stdin.handle, &input_mode) == 0 or c.GetConsoleMode(stdout.handle, &output_mode) == 0) return error.InteractiveWindowsConsoleRequired;
        if (c.SetConsoleMode(stdin.handle, (input_mode & ~@as(c.DWORD, c.ENABLE_ECHO_INPUT | c.ENABLE_LINE_INPUT | c.ENABLE_PROCESSED_INPUT)) | c.ENABLE_VIRTUAL_TERMINAL_INPUT) == 0) return error.EnableVirtualTerminalInputFailed;
        errdefer _ = c.SetConsoleMode(stdin.handle, input_mode);
        if (c.SetConsoleMode(stdout.handle, output_mode | c.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) return error.EnableVirtualTerminalOutputFailed;
        output_thread = c.OpenThread(c.THREAD_TERMINATE, 0, c.GetCurrentThreadId());
        return .{ .input_mode = input_mode, .output_mode = output_mode };
    }
    pub fn deinit(self: *@This()) void {
        if (output_thread != null) _ = c.CloseHandle(output_thread);
        output_thread = null;
        _ = c.SetConsoleMode(std.fs.File.stdin().handle, self.input_mode);
        _ = c.SetConsoleMode(std.fs.File.stdout().handle, self.output_mode);
    }
} else struct {
    termios: std.posix.termios,
    flags: usize,
    pub fn enter() !@This() {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        const original = try std.posix.tcgetattr(stdin.handle);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);
        errdefer std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};
        const flags = try std.posix.fcntl(stdout.handle, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(stdout.handle, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        return .{ .termios = original, .flags = flags };
    }
    pub fn deinit(self: *@This()) void {
        _ = std.posix.fcntl(std.fs.File.stdout().handle, std.posix.F.SETFL, self.flags) catch 0;
        std.posix.tcsetattr(std.fs.File.stdin().handle, .NOW, self.termios) catch {};
        _ = c.tcflush(std.fs.File.stdin().handle, c.TCIFLUSH);
    }
};
pub fn dimensions(fallback: [2]usize) [2]usize {
    if (windows) {
        var info: c.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (c.GetConsoleScreenBufferInfo(std.fs.File.stdout().handle, &info) != 0) {
            const w = info.srWindow.Right - info.srWindow.Left + 1;
            const h = info.srWindow.Bottom - info.srWindow.Top + 1;
            if (w > 0 and h > 0) return .{ @intCast(@min(1024, w)), @intCast(@min(1024, h)) };
        }
    } else {
        var size: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
        if (std.posix.system.ioctl(std.fs.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) == 0 and size.col > 0 and size.row > 0) return .{ @min(1024, size.col), @min(1024, size.row) };
    }
    return fallback;
}
pub fn inputReady() !bool {
    if (windows) {
        const result = c.WaitForSingleObject(std.fs.File.stdin().handle, 10);
        if (result == c.WAIT_FAILED) return error.TerminalDisconnected;
        return result == c.WAIT_OBJECT_0;
    } else {
        var fds = [_]std.posix.pollfd{.{ .fd = std.fs.File.stdin().handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.poll(&fds, 10);
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return error.TerminalDisconnected;
        return fds[0].revents & std.posix.POLL.IN != 0;
    }
}
pub fn outputReady() !bool {
    if (windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = std.fs.File.stdout().handle, .events = std.posix.POLL.OUT, .revents = 0 }};
    _ = try std.posix.poll(&fds, 50);
    if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return error.TerminalDisconnected;
    return fds[0].revents & std.posix.POLL.OUT != 0;
}
pub const Signals = if (windows) struct {
    var callback: ?*const fn (c_int) callconv(.c) void = null;
    fn handler(event: c.DWORD) callconv(.winapi) c.BOOL {
        if (event == c.CTRL_C_EVENT or event == c.CTRL_BREAK_EVENT or event == c.CTRL_CLOSE_EVENT or event == c.CTRL_LOGOFF_EVENT or event == c.CTRL_SHUTDOWN_EVENT) {
            if (callback) |call| call(0);
            cancelOutput();
            return 1;
        }
        return 0;
    }
    pub fn init(call: *const fn (c_int) callconv(.c) void) @This() {
        callback = call;
        _ = c.SetConsoleCtrlHandler(handler, 1);
        return .{};
    }
    pub fn deinit(_: *@This()) void {
        _ = c.SetConsoleCtrlHandler(handler, 0);
        callback = null;
    }
} else struct {
    const signals = [_]u6{ std.posix.SIG.HUP, std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.PIPE };
    old: [signals.len]std.posix.Sigaction,
    pub fn init(handler: *const fn (c_int) callconv(.c) void) @This() {
        var self: @This() = undefined;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &action, &self.old[i]);
        return self;
    }
    pub fn deinit(self: *@This()) void {
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &self.old[i], null);
    }
};
