const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent.zig");
const routing = @import("routing.zig");
const platform = @import("platform.zig");
const renderer = @import("render.zig");
const A = std.mem.Allocator;
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub const Options = struct {
    capture: []const u8 = "auto",
    input: []const u8 = "auto",
    display: ?[]const u8 = null,
    once: bool = false,
    check: bool = false,
    no_input: bool = false,
    animate: bool = true,
    unicode: bool = true,
    mouse: bool = true,
    color: renderer.Color = .truecolor,
    columns: usize = 80,
    rows: usize = 24,
    fps: f64 = 30,
    fps_explicit: bool = false,
    scale_explicit: bool = false,
    scale: f64 = 1,
    duration: f64 = 60,
    fixture: ?[]const u8 = null,
    iterations: usize = 100,
};
fn next(args: []const []const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingOptionValue;
    return args[i.*];
}
fn boundedInt(comptime T: type, s: []const u8, min: T, max: T) !T {
    const value = std.fmt.parseInt(T, s, 10) catch return error.InvalidInteger;
    if (value < min or value > max) return error.OptionOutOfRange;
    return value;
}
fn boundedFloat(s: []const u8, min: f64, max: f64) !f64 {
    const value = std.fmt.parseFloat(f64, s) catch return error.InvalidNumber;
    if (!std.math.isFinite(value) or value < min or value > max) return error.OptionOutOfRange;
    return value;
}
pub fn expandEquals(args: []const []const u8) !std.ArrayList([]const u8) {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(std.heap.page_allocator);
    var positional = false;
    for (args) |arg| {
        if (eq(arg, "--")) positional = true;
        if (!positional and std.mem.startsWith(u8, arg, "--")) if (std.mem.indexOfScalar(u8, arg, '=')) |split| {
            try words.append(std.heap.page_allocator, arg[0..split]);
            try words.append(std.heap.page_allocator, arg[split + 1 ..]);
            continue;
        };
        try words.append(std.heap.page_allocator, arg);
    }
    return words;
}
pub fn parseOptions(raw: []const []const u8) !Options {
    var words = try expandEquals(raw);
    defer words.deinit(std.heap.page_allocator);
    const args = words.items;
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "--capture")) {
            opts.capture = try next(args, &i);
            if (!oneOf(opts.capture, &.{ "auto", "synthetic", "native", "x11", "wayland", "gnome" })) return error.UnknownCaptureBackend;
        } else if (eq(arg, "--input")) {
            opts.input = try next(args, &i);
            if (!oneOf(opts.input, &.{ "auto", "none", "x11", "quartz", "sendinput", "mutter", "ydotool" })) return error.UnknownInputBackend;
        } else if (eq(arg, "--display")) opts.display = try next(args, &i) else if (eq(arg, "--once")) opts.once = true else if (eq(arg, "--check")) opts.check = true else if (eq(arg, "--no-input")) opts.no_input = true else if (eq(arg, "--synthetic-static")) opts.animate = false else if (eq(arg, "--ascii")) opts.unicode = false else if (eq(arg, "--no-mouse")) opts.mouse = false else if (eq(arg, "--columns")) opts.columns = try boundedInt(usize, try next(args, &i), 1, 1024) else if (eq(arg, "--rows")) opts.rows = try boundedInt(usize, try next(args, &i), 1, 1024) else if (eq(arg, "--max-fps")) {
            opts.fps = try boundedFloat(try next(args, &i), 0.5, 120);
            opts.fps_explicit = true;
        } else if (eq(arg, "--scale")) {
            opts.scale = try boundedFloat(try next(args, &i), 0.25, 1);
            opts.scale_explicit = true;
        } else if (eq(arg, "--fixture")) opts.fixture = try next(args, &i) else if (eq(arg, "--iterations")) opts.iterations = try boundedInt(usize, try next(args, &i), 1, 10000) else if (eq(arg, "--duration")) opts.duration = try boundedFloat(try next(args, &i), 0.001, 86400) else if (eq(arg, "--color")) {
            const color = try next(args, &i);
            opts.color = if (eq(color, "truecolor") or eq(color, "auto")) .truecolor else if (eq(color, "256")) .ansi256 else if (eq(color, "16")) .ansi16 else return error.InvalidColor;
        } else return error.UnknownOption;
    }
    if (eq(opts.input, "none")) opts.no_input = true;
    return opts;
}
fn oneOf(value: []const u8, values: []const []const u8) bool {
    for (values) |v| if (eq(value, v)) return true;
    return false;
}
pub const AgentArgs = struct { request: agent.Request, output: []const u8 = "-" };
pub fn parseAgent(raw: []const []const u8) !AgentArgs {
    var words = try expandEquals(raw);
    defer words.deinit(std.heap.page_allocator);
    const args = words.items;
    if (args.len == 0) return error.MissingAgentCommand;
    const action = std.meta.stringToEnum(agent.Action, args[0]) orelse return error.UnknownAgentCommand;
    if (action == .quit or action == .wait) return error.UnknownAgentCommand;
    var result: AgentArgs = .{ .request = .{ .action = action } };
    var positional: [3][]const u8 = undefined;
    var count: usize = 0;
    var i: usize = 1;
    var only_positionals = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "--") and !only_positionals) {
            only_positionals = true;
            continue;
        }
        if (only_positionals) {
            if (count == positional.len) return error.UnexpectedArgument;
            positional[count] = arg;
            count += 1;
            continue;
        }
        if (eq(arg, "--max-width") and (action == .screenshot or action == .observe)) result.request.max_width = try boundedInt(usize, try next(args, &i), 0, 4096) else if (eq(arg, "--output") and (action == .screenshot or action == .observe)) result.output = try next(args, &i) else if (eq(arg, "--count") and action == .click) {
            const n = std.fmt.parseInt(i64, try next(args, &i), 10) catch return error.InvalidInteger;
            result.request.count = @intCast(std.math.clamp(n, 1, 20));
        } else if (eq(arg, "--button") and action == .click) {
            const b = try next(args, &i);
            result.request.button = if (eq(b, "left")) 1 else if (eq(b, "middle")) 2 else if (eq(b, "right")) 3 else return error.InvalidButton;
        } else if (eq(arg, "--interval-ms") and action == .type) result.request.interval_ms = std.math.clamp(try boundedFloat(try next(args, &i), -1e12, 1e12), 0, 1000) else if (eq(arg, "--ctrl") and action == .key) result.request.modifiers |= 4 else if (eq(arg, "--alt") and action == .key) result.request.modifiers |= 2 else if (eq(arg, "--shift") and action == .key) result.request.modifiers |= 1 else {
            if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
            if (count == positional.len) return error.UnexpectedArgument;
            positional[count] = arg;
            count += 1;
        }
    }
    const expected: usize = switch (action) {
        .move, .click => 2,
        .scroll => 3,
        .type, .key => 1,
        else => 0,
    };
    if (count != expected) return error.WrongArgumentCount;
    switch (action) {
        .move, .click => {
            result.request.x = try boundedInt(i32, positional[0], -16384, 65535);
            result.request.y = try boundedInt(i32, positional[1], -16384, 65535);
        },
        .scroll => {
            const n = std.fmt.parseInt(i64, positional[0], 10) catch return error.InvalidInteger;
            result.request.amount = @intCast(std.math.clamp(n, -20, 20));
            result.request.x = try boundedInt(i32, positional[1], -16384, 65535);
            result.request.y = try boundedInt(i32, positional[2], -16384, 65535);
        },
        .type => {
            result.request.text = positional[0];
            if (try std.unicode.utf8CountCodepoints(positional[0]) > agent.max_text) return error.TextTooLong;
        },
        .key => result.request.key = try @import("input.zig").named(positional[0]),
        else => {},
    }
    return result;
}
pub fn writeImage(path: []const u8, bytes: []const u8) !void {
    if (eq(path, "-")) {
        try std.fs.File.stdout().writeAll(bytes);
        return;
    }
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}
pub fn agentCommand(a: A, args: []const []const u8) !u8 {
    const parsed = try parseAgent(args);
    var controller: agent.Controller = .{ .allocator = a };
    defer controller.deinit();
    if (parsed.request.action == .session) {
        agent.session(&controller) catch |err| {
            if (err == error.Interrupted) return 130;
            return err;
        };
        return 0;
    }
    if (parsed.request.action == .screenshot or parsed.request.action == .observe) {
        const bytes = try controller.screenshot(parsed.request.max_width);
        defer a.free(bytes);
        try writeImage(parsed.output, bytes);
        return 0;
    }
    const response = try controller.execute(parsed.request);
    defer a.free(response);
    if (parsed.request.action == .info) {
        var json = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        defer json.deinit();
        _ = json.value.object.swapRemove("id");
        _ = json.value.object.swapRemove("ok");
        const bytes = try std.json.Stringify.valueAlloc(a, json.value, .{});
        defer a.free(bytes);
        try std.fs.File.stdout().writeAll(bytes);
        try std.fs.File.stdout().writeAll("\n");
    }
    return 0;
}
const env_c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("stdlib.h");
}) else @cImport({
    @cInclude("stdlib.h");
});
fn setEnvironment(a: A, name: []const u8, value: []const u8) !void {
    const key = try a.dupeZ(u8, name);
    defer a.free(key);
    const text = try a.dupeZ(u8, value);
    defer a.free(text);
    if (builtin.os.tag == .windows) {
        if (env_c._putenv_s(key, text) != 0) return error.SetEnvironmentFailed;
    } else {
        if (env_c.setenv(key, text, 1) != 0) return error.SetEnvironmentFailed;
    }
}
fn serverOptions(a: A, args: []const []const u8) !Options {
    var options = try parseOptions(args);
    if (options.fps_explicit and options.fps < 1) return error.OptionOutOfRange;
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    if (options.display) |display| try setEnvironment(a, "DISPLAY", display);
    if (!options.fps_explicit) if (env.get("SSHDESK_MAX_FPS")) |value| {
        if (!eq(value, "auto")) {
            options.fps = try boundedFloat(value, 1, 120);
            options.fps_explicit = true;
        }
    };
    if (!options.scale_explicit) if (env.get("SSHDESK_SCALE")) |value| {
        if (!eq(value, "auto")) {
            options.scale = try boundedFloat(value, 0.25, 1);
            options.scale_explicit = true;
        }
    };
    if (!options.check) {
        for (args, 0..) |arg, i| if (eq(arg, "--color") and i + 1 < args.len) {
            try env.put("SSHDESK_COLOR", args[i + 1]);
        };
        for (args) |arg| if (std.mem.startsWith(u8, arg, "--color=")) {
            try env.put("SSHDESK_COLOR", arg[8..]);
        };
        const caps = try @import("capabilities.zig").detect(&env);
        options.color = caps.color;
        options.mouse = options.mouse and caps.mouse;
        options.unicode = options.unicode and caps.unicode;
    }
    return options;
}
pub fn dispatch(a: A, command: []const u8, args: []const []const u8) !u8 {
    // Forced commands never interpret their arguments as local help options.
    if (eq(command, "sshdesk-agent-ssh")) {
        if (args.len != 1) return 2;
        var words = routing.split(a, args[0]) catch return 2;
        defer words.deinit();
        const route = routing.classify(words.items.items) catch |err| return if (err == error.CommandDenied) 126 else 2;
        if (route != .agent) return 126;
        return agentCommand(a, words.items.items[1..]);
    }
    if (eq(command, "sshdesk-forced-command")) return forced(a);
    for (args) |arg| {
        if (eq(arg, "--")) break;
        if (eq(arg, "--help") or eq(arg, "-h")) {
            try help(command);
            return 0;
        }
    }
    if (eq(command, "sshdesk-agent")) return agentCommand(a, args);
    if (eq(command, "sshdesk-local")) {
        var opts = try parseOptions(args);
        const size = @import("terminal.zig").dimensions(.{ 80, 24 });
        var normalized = try expandEquals(args);
        defer normalized.deinit(std.heap.page_allocator);
        var columns = false;
        var rows = false;
        for (normalized.items) |arg| {
            if (eq(arg, "--columns")) columns = true;
            if (eq(arg, "--rows")) rows = true;
        }
        if (!columns) opts.columns = size[0];
        if (!rows) opts.rows = size[1];
        const alternate = !opts.once and std.fs.File.stdout().isTty();
        if (alternate) try std.fs.File.stdout().writeAll(renderer.enter);
        defer if (alternate) {
            std.fs.File.stdout().writeAll(renderer.leave) catch {};
        };
        var desktop = try platform.Desktop.init(a, opts.capture, false, opts.animate);
        defer desktop.deinit();
        var frame = try desktop.capture();
        defer frame.deinit();
        var rendered = try renderer.render(a, frame, opts.columns, opts.rows, 0, opts.scale);
        defer rendered.deinit();
        const encoded = try renderer.encode(a, null, rendered, opts.color, opts.unicode);
        defer a.free(encoded.bytes);
        try std.fs.File.stdout().writeAll(encoded.bytes);
        return 0;
    }
    if (eq(command, "sshdesk-server") or eq(command, "sshdesk")) {
        const opts = try serverOptions(a, args);
        if (opts.check) {
            var desktop = try platform.Desktop.init(a, opts.capture, false, opts.animate);
            defer desktop.deinit();
            if (!opts.no_input) try desktop.configureInput(opts.input);
            var frame = try desktop.capture();
            defer frame.deinit();
            const message = try std.fmt.allocPrint(a, "SSHDESK check passed: {d}x{d} {s} capture; input={s}\n", .{ frame.width, frame.height, opts.capture, if (opts.no_input) "disabled" else "enabled" });
            defer a.free(message);
            try std.fs.File.stdout().writeAll(message);
            return 0;
        }
        return @import("session.zig").run(a, opts);
    }
    if (eq(command, "sshdesk-bench")) {
        var opts = try parseOptions(args);
        var words = try expandEquals(args);
        defer words.deinit(std.heap.page_allocator);
        var columns = false;
        var rows = false;
        var color = false;
        for (words.items) |arg| {
            if (eq(arg, "--columns")) columns = true;
            if (eq(arg, "--rows")) rows = true;
            if (eq(arg, "--color")) color = true;
        }
        if (!columns) opts.columns = 100;
        if (!rows) opts.rows = 30;
        if (!color) opts.color = .ansi256;
        return @import("bench.zig").run(a, opts);
    }
    if (eq(command, "sshdesk-split") or eq(command, "sshdesk-remote")) return @import("client.zig").run(a, command, args);
    return error.UnknownCommand;
}
const passwd = if (builtin.os.tag != .windows) @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
}) else struct {};
fn desktopAccount(a: A, account: []const u8) !?[]u8 {
    const config = @import("config.zig");
    if (!config.validAccount(account)) return error.InvalidAuthenticatedAccount;
    const path = try std.fmt.allocPrint(a, "/etc/sshdesk/{s}.conf", .{account});
    defer a.free(path);
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    const stat = try std.posix.fstat(file.handle);
    if (stat.uid != 0 or stat.mode & 0o022 != 0) return error.ConfigurationMustBeRootOwnedAndNotGroupWritable;
    const bytes = try file.readToEndAlloc(a, 65536);
    defer a.free(bytes);
    var run_as: ?[]u8 = null;
    errdefer if (run_as) |name| a.free(name);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (config.entry(line)) |entry| {
        if (std.mem.eql(u8, entry.key, "RUN_AS")) {
            if (!config.validAccount(entry.value)) return error.InvalidDesktopAccount;
            if (run_as) |name| a.free(name);
            run_as = null;
            run_as = try a.dupe(u8, entry.value);
        } else try setEnvironment(a, entry.key, entry.value);
    };
    return run_as;
}
fn forced(a: A) anyerror!u8 {
    const original = std.process.getEnvVarOwned(a, "SSH_ORIGINAL_COMMAND") catch try a.dupe(u8, "");
    defer a.free(original);
    var words = routing.split(a, original) catch return 2;
    defer words.deinit();
    const route = routing.classify(words.items.items) catch |err| return if (err == error.CommandDenied) 126 else 2;
    if (route != .agent and (!std.fs.File.stdin().isTty() or !std.fs.File.stdout().isTty())) return error.InteractiveSshPtyRequired;
    if (route == .shell) {
        // Resolve the authenticated uid before consulting any desktop configuration.
        if (builtin.os.tag == .windows) {
            const shell = std.process.getEnvVarOwned(a, "COMSPEC") catch try a.dupe(u8, "cmd.exe");
            defer a.free(shell);
            return @import("process.zig").inherited(a, &.{shell});
        } else {
            const account = passwd.getpwuid(passwd.getuid()) orelse return error.AuthenticatedAccountNotFound;
            const shell = std.mem.span(account.*.pw_shell);
            if (shell.len == 0) return error.LoginShellUnavailable;
            return std.process.execv(a, &.{ shell, "-l" });
        }
    }
    if (builtin.os.tag == .linux) {
        const account = passwd.getpwuid(passwd.getuid()) orelse return error.AuthenticatedAccountNotFound;
        const name = try a.dupe(u8, std.mem.span(account.*.pw_name));
        defer a.free(name);
        const run_as = try desktopAccount(a, name);
        defer if (run_as) |value| a.free(value);
        if (run_as) |owner| if (!eq(owner, name)) {
            if (route == .agent) return std.process.execv(a, &.{ "/usr/bin/sudo", "-n", "-u", owner, "--", "/usr/local/bin/sshdesk-agent-ssh", original });
            return std.process.execv(a, &.{ "/usr/bin/sudo", "-n", "-u", owner, "--", "/usr/local/bin/sshdesk-server" });
        };
    }
    if (route == .agent) return agentCommand(a, words.items.items[1..]);
    return dispatch(a, "sshdesk-server", &.{});
}
fn help(command: []const u8) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(command);
    if (std.mem.startsWith(u8, command, "sshdesk-agent")) try stdout.writeAll(" <info|screenshot|observe|move|click|scroll|type|key|session> [arguments]\n") else if (eq(command, "sshdesk-split")) try stdout.writeAll(" TARGET [--direction right|left|down|up] [--size 20..80]\n") else if (eq(command, "sshdesk-remote")) try stdout.writeAll(" TARGET [--timeout SECONDS] <agent command> [arguments]\n") else try stdout.writeAll(" [--capture auto|x11|gnome|wayland|native|synthetic] [--check]\n  --no-input --synthetic-static --color auto|truecolor|256|16 --ascii\n  --no-mouse --max-fps 0.5..120 --scale 0.25..1 --columns N --rows N\n");
}
test "removed flags and command allowlist fail closed" {
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{"--tailscale"}));
    try std.testing.expectError(error.UnknownOption, parseAgent(&.{ "info", "--output", "/tmp/foo" }));
    try std.testing.expectError(error.WrongArgumentCount, parseAgent(&.{ "info", ";id" }));
    try std.testing.expectError(error.OptionOutOfRange, parseOptions(&.{ "--scale", "nan" }));
    const parsed = try parseAgent(&.{ "type", "世界; $(id)" });
    try std.testing.expectEqualStrings("世界; $(id)", parsed.request.text);
}

test "equals options, positional Unicode and benchmark argument bounds" {
    const opts = try parseOptions(&.{ "--capture=synthetic", "--max-fps=60", "--scale=0.5", "--color=256" });
    try std.testing.expectEqualStrings("synthetic", opts.capture);
    try std.testing.expectEqual(@as(f64, 60), opts.fps);
    try std.testing.expectEqual(@as(f64, 0.5), opts.scale);
    const parsed = try parseAgent(&.{ "type", "--", "--literal=世界" });
    try std.testing.expectEqualStrings("--literal=世界", parsed.request.text);
    try std.testing.expectError(error.OptionOutOfRange, parseOptions(&.{"--max-fps=0"}));
    try std.testing.expectError(error.OptionOutOfRange, parseOptions(&.{"--duration=nan"}));
}
