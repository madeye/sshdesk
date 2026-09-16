const std = @import("std");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});
const Frame = @import("../frame.zig").Frame;
const input = @import("../input.zig");
pub const Backend = struct {
    held: [3]bool = @splat(false),
    position: [2]i32 = .{ 0, 0 },
    pub fn init() !Backend {
        var session: c.DWORD = 0;
        if (c.ProcessIdToSessionId(c.GetCurrentProcessId(), &session) == 0) return error.WindowsSessionQueryFailed;
        if (session == 0) return error.RunInLoggedInInteractiveWindowsSessionNotSessionZero;
        return .{};
    }
    pub fn checkInput(_: *Backend) !void {}
    pub fn capture(_: *Backend, a: std.mem.Allocator) !Frame {
        const x = c.GetSystemMetrics(c.SM_XVIRTUALSCREEN);
        const y = c.GetSystemMetrics(c.SM_YVIRTUALSCREEN);
        const width = c.GetSystemMetrics(c.SM_CXVIRTUALSCREEN);
        const height = c.GetSystemMetrics(c.SM_CYVIRTUALSCREEN);
        if (width <= 0 or height <= 0) return error.EmptyWindowsDesktop;
        var frame = try Frame.init(a, @intCast(width), @intCast(height));
        errdefer frame.deinit();
        const dc = c.GetDC(null) orelse return error.GdiCaptureFailed;
        defer _ = c.ReleaseDC(null, dc);
        const memory = c.CreateCompatibleDC(dc) orelse return error.GdiCaptureFailed;
        defer _ = c.DeleteDC(memory);
        const bitmap = c.CreateCompatibleBitmap(dc, width, height) orelse return error.GdiCaptureFailed;
        defer _ = c.DeleteObject(bitmap);
        const previous = c.SelectObject(memory, bitmap) orelse return error.GdiCaptureFailed;
        if (c.BitBlt(memory, 0, 0, width, height, dc, x, y, c.SRCCOPY | c.CAPTUREBLT) == 0) {
            _ = c.SelectObject(memory, previous);
            return error.GdiCaptureFailed;
        }
        _ = c.SelectObject(memory, previous);
        var info: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = c.BI_RGB;
        const raw = try a.alloc(u8, frame.width * frame.height * 4);
        defer a.free(raw);
        if (c.GetDIBits(memory, bitmap, 0, @intCast(height), raw.ptr, &info, c.DIB_RGB_COLORS) != height) return error.GdiCaptureFailed;
        for (frame.pixels, 0..) |*p, i| p.* = .{ raw[i * 4 + 2], raw[i * 4 + 1], raw[i * 4] };
        return frame;
    }
    fn send(event: *c.INPUT) !void {
        if (c.SendInput(1, event, @sizeOf(c.INPUT)) != 1) return error.SendInputFailedCheckDesktopIntegrityLevel;
    }
    fn keyEvent(code: u16, scan: u16, flags: u32) !void {
        var event: c.INPUT = std.mem.zeroes(c.INPUT);
        event.type = c.INPUT_KEYBOARD;
        event.unnamed_0.ki.wVk = code;
        event.unnamed_0.ki.wScan = scan;
        event.unnamed_0.ki.dwFlags = flags;
        try send(&event);
    }
    pub fn key(_: *Backend, k: input.KeyEvent) !void {
        const code: u16 = switch (k.key) {
            .character => 0,
            .enter => c.VK_RETURN,
            .escape => c.VK_ESCAPE,
            .backspace => c.VK_BACK,
            .tab => c.VK_TAB,
            .home => c.VK_HOME,
            .end => c.VK_END,
            .up => c.VK_UP,
            .down => c.VK_DOWN,
            .left => c.VK_LEFT,
            .right => c.VK_RIGHT,
            .page_up => c.VK_PRIOR,
            .page_down => c.VK_NEXT,
            .insert => c.VK_INSERT,
            .delete => c.VK_DELETE,
            else => @as(u16, c.VK_F1) + @as(u16, @intFromEnum(k.key)) - 20,
        };
        var held: [3]bool = @splat(false);
        const codes = [_]u16{ c.VK_SHIFT, c.VK_MENU, c.VK_CONTROL };
        defer for (held, 0..) |down, i| {
            if (down) keyEvent(codes[i], 0, c.KEYEVENTF_KEYUP) catch {};
        };
        for (codes, 0..) |modifier, i| if (k.modifiers & (@as(u3, 1) << @intCast(i)) != 0) {
            try keyEvent(modifier, 0, 0);
            held[i] = true;
        };
        var units: [2]u16 = undefined;
        var n: usize = 1;
        if (k.unicode <= 0xffff) units[0] = @intCast(k.unicode) else {
            const v = k.unicode - 0x10000;
            units[0] = @intCast(0xd800 + (v >> 10));
            units[1] = @intCast(0xdc00 + (v & 0x3ff));
            n = 2;
        }
        for ([_]bool{ true, false }) |down| {
            if ((k.action == 0 and !down) or (k.action == 1 and down)) continue;
            const flags: u32 = if (down) 0 else c.KEYEVENTF_KEYUP;
            if (k.key == .character) {
                for (units[0..n]) |unit| try keyEvent(0, unit, flags | c.KEYEVENTF_UNICODE);
            } else try keyEvent(code, 0, flags);
        }
    }
    pub fn move(self: *Backend, x: i32, y: i32) !void {
        const width = c.GetSystemMetrics(c.SM_CXVIRTUALSCREEN);
        const height = c.GetSystemMetrics(c.SM_CYVIRTUALSCREEN);
        if (width <= 0 or height <= 0) return error.EmptyWindowsDesktop;
        self.position = .{ std.math.clamp(x, 0, width - 1), std.math.clamp(y, 0, height - 1) };
        var event: c.INPUT = std.mem.zeroes(c.INPUT);
        event.type = c.INPUT_MOUSE;
        event.unnamed_0.mi.dx = @intCast(@divTrunc(@as(i64, self.position[0]) * 65535, @max(1, width - 1)));
        event.unnamed_0.mi.dy = @intCast(@divTrunc(@as(i64, self.position[1]) * 65535, @max(1, height - 1)));
        event.unnamed_0.mi.dwFlags = c.MOUSEEVENTF_MOVE | c.MOUSEEVENTF_ABSOLUTE | c.MOUSEEVENTF_VIRTUALDESK;
        try send(&event);
    }
    pub fn button(self: *Backend, number: u8, down: bool, x: i32, y: i32) !void {
        try self.move(x, y);
        var event: c.INPUT = std.mem.zeroes(c.INPUT);
        event.type = c.INPUT_MOUSE;
        event.unnamed_0.mi.dwFlags = switch (number) {
            1 => if (down) c.MOUSEEVENTF_LEFTDOWN else c.MOUSEEVENTF_LEFTUP,
            2 => if (down) c.MOUSEEVENTF_MIDDLEDOWN else c.MOUSEEVENTF_MIDDLEUP,
            3 => if (down) c.MOUSEEVENTF_RIGHTDOWN else c.MOUSEEVENTF_RIGHTUP,
            else => return error.InvalidButton,
        };
        try send(&event);
        self.held[number - 1] = down;
    }
    pub fn scroll(self: *Backend, amount: i32, x: i32, y: i32) !void {
        try self.move(x, y);
        var event: c.INPUT = std.mem.zeroes(c.INPUT);
        event.type = c.INPUT_MOUSE;
        event.unnamed_0.mi.dwFlags = c.MOUSEEVENTF_WHEEL;
        event.unnamed_0.mi.mouseData = @bitCast(std.math.clamp(amount, -20, 20) * @as(i32, c.WHEEL_DELTA));
        try send(&event);
    }
    pub fn deinit(self: *Backend) void {
        for (self.held, 0..) |down, i| if (down) {
            self.button(@intCast(i + 1), false, self.position[0], self.position[1]) catch {};
        };
    }
};
