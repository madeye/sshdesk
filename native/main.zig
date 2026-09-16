const std = @import("std");
const core = @import("sshdesk");
pub fn main() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const code = run(gpa.allocator()) catch |err| blk: {
        var buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{s}: {s}\n", .{ @import("options").command, @errorName(err) }) catch "sshdesk: error\n";
        std.fs.File.stderr().writeAll(message) catch {};
        break :blk @as(u8, if (err == error.UnknownOption or err == error.WrongArgumentCount or err == error.UnknownAgentCommand or err == error.MissingOptionValue or err == error.InvalidInteger or err == error.InvalidNumber or err == error.UnknownKey or err == error.InvalidButton or err == error.InvalidColor or err == error.UnknownCaptureBackend or err == error.UnknownInputBackend or err == error.UnexpectedArgument or err == error.MissingAgentCommand) 2 else 1);
    };
    if (gpa.deinit() == .leak) std.process.exit(1);
    if (code != 0) std.process.exit(code);
}
fn run(a: std.mem.Allocator) !u8 {
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    return core.cli.dispatch(a, @import("options").command, args[1..]);
}
