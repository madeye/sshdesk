const std = @import("std");
pub const max_command = 65536;
pub const Route = enum { desktop, shell, agent };
pub const Words = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,
    pub fn deinit(self: *Words) void {
        for (self.items.items) |word| self.allocator.free(word);
        self.items.deinit(self.allocator);
    }
};
// Tokenize quoting only. There is deliberately no expansion or shell evaluation.
pub fn split(a: std.mem.Allocator, command: []const u8) !Words {
    if (command.len > max_command or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
    var result: Words = .{ .allocator = a };
    errdefer result.deinit();
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(a);
    var quote: u8 = 0;
    var started = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = command[i];
        if (quote == 0 and std.ascii.isWhitespace(ch)) {
            if (started) {
                const owned = try a.dupe(u8, word.items);
                errdefer a.free(owned);
                try result.items.append(a, owned);
                word.clearRetainingCapacity();
                started = false;
            }
            continue;
        }
        started = true;
        if (ch == '\\' and quote != '\'') {
            i += 1;
            if (i == command.len) return error.UnterminatedQuote;
            if (quote == '"' and command[i] != '"' and command[i] != '\\') try word.append(a, '\\');
            try word.append(a, command[i]);
        } else if (ch == quote) {
            quote = 0;
        } else if (quote == 0 and (ch == '\'' or ch == '"')) {
            quote = ch;
        } else try word.append(a, ch);
    }
    if (quote != 0) return error.UnterminatedQuote;
    if (started) {
        const owned = try a.dupe(u8, word.items);
        errdefer a.free(owned);
        try result.items.append(a, owned);
    }
    return result;
}
pub fn classify(words: []const []const u8) !Route {
    if (words.len == 0) return .desktop;
    if (words.len == 1) {
        for ([_][]const u8{ "shell", "sshdesk-shell" }) |v| if (std.mem.eql(u8, words[0], v)) return .shell;
        for ([_][]const u8{ "desktop", "sshdesk", "sshdesk-server" }) |v| if (std.mem.eql(u8, words[0], v)) return .desktop;
    }
    if (!std.mem.eql(u8, std.fs.path.basename(words[0]), "sshdesk-agent")) return error.CommandDenied;
    for (words[1..]) |v| if (std.mem.eql(u8, v, "--output") or std.mem.startsWith(u8, v, "--output=")) return error.RemoteOutputDenied;
    return .agent;
}
pub fn validTarget(target: []const u8) bool {
    if (target.len == 0 or target.len > 255 or target[0] == '-') return false;
    for (target) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_.%+@:-", c) == null) return false;
    return true;
}
test "exact SSH selectors and command injection rejection" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "shell -c id", "shell;id", "/bin/sh", "desktop --capture synthetic", "sshdesk-agentx info", "$(id)", "shell\nwhoami" }) |cmd| {
        var w = try split(a, cmd);
        defer w.deinit();
        try std.testing.expectError(error.CommandDenied, classify(w.items.items));
    }
    var w = try split(a, "'shell'");
    defer w.deinit();
    try std.testing.expectEqual(Route.shell, try classify(w.items.items));
    try std.testing.expectError(error.UnterminatedQuote, split(a, "'shell"));
    var out = try split(a, "sshdesk-agent screenshot --output=/tmp/file");
    defer out.deinit();
    try std.testing.expectError(error.RemoteOutputDenied, classify(out.items.items));
    try std.testing.expect(!validTarget("-oProxyCommand=id"));
    try std.testing.expect(!validTarget("host;id"));
    try std.testing.expect(validTarget("alice@example.com"));
}
fn allocationScenario(a: std.mem.Allocator) !void {
    var words = try split(a, "sshdesk-agent type 'Unicode 世界; $(id)' --interval-ms 1");
    defer words.deinit();
    try std.testing.expectEqualStrings("Unicode 世界; $(id)", words.items.items[2]);
    try std.testing.expectEqual(Route.agent, try classify(words.items.items));
}
test "quoted Unicode and allocation failure cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
