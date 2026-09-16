const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.15.2")) @panic("SSHDESK requires Zig 0.15.2");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("LICENSE"), .prefix, "share/licenses/sshdesk/LICENSE").step);
    const zlib = b.dependency("zlib", .{});
    const zmodule = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    zmodule.addIncludePath(zlib.path(""));
    zmodule.addCSourceFiles(.{ .root = zlib.path(""), .files = &.{ "adler32.c", "crc32.c", "deflate.c", "infback.c", "inffast.c", "inflate.c", "inftrees.c", "trees.c", "zutil.c", "compress.c", "uncompr.c" }, .flags = &.{"-std=c11"} });
    const zarchive = b.addLibrary(.{ .name = "z", .linkage = .static, .root_module = zmodule });
    const png = b.dependency("libpng", .{});
    const config = b.addWriteFiles();
    _ = config.addCopyFile(png.path("scripts/pnglibconf.h.prebuilt"), "pnglibconf.h");
    const pmodule = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    pmodule.addIncludePath(config.getDirectory());
    pmodule.addIncludePath(png.path(""));
    pmodule.addIncludePath(zlib.path(""));
    pmodule.addCSourceFiles(.{ .root = png.path(""), .files = &.{ "png.c", "pngerror.c", "pngget.c", "pngmem.c", "pngpread.c", "pngread.c", "pngrio.c", "pngrtran.c", "pngrutil.c", "pngset.c", "pngtrans.c", "pngwio.c", "pngwrite.c", "pngwtran.c", "pngwutil.c" }, .flags = &.{ "-std=c11", "-DPNG_ARM_NEON_OPT=0", "-DPNG_POWERPC_VSX_OPT=0", "-DPNG_INTEL_SSE_OPT=0", "-DPNG_MIPS_MSA_OPT=0", "-DPNG_LOONGARCH_LSX_OPT=0" } });
    pmodule.linkLibrary(zarchive);
    const pngarchive = b.addLibrary(.{ .name = "png", .linkage = .static, .root_module = pmodule });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(png.path("LICENSE"), .prefix, "share/licenses/sshdesk/libpng-LICENSE").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(zlib.path("LICENSE"), .prefix, "share/licenses/sshdesk/zlib-LICENSE").step);
    const core = b.createModule(.{ .root_source_file = b.path("native/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    core.linkLibrary(pngarchive);
    if (target.result.os.tag == .macos) {
        core.addCSourceFile(.{ .file = b.path("native/gpu/metal.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" } });
        core.linkFramework("Foundation", .{});
        core.linkFramework("Metal", .{});
        core.linkSystemLibrary("objc", .{});
    }
    if (target.result.os.tag == .windows) {
        core.linkSystemLibrary("user32", .{});
        core.linkSystemLibrary("gdi32", .{});
    }
    const tests = b.addTest(.{ .root_module = core });
    const test_binary = b.step("test-bin", "Install the native test runner without executing it");
    test_binary.dependOn(&b.addInstallFileWithDir(tests.getEmittedBin(), .bin, if (target.result.os.tag == .windows) "sshdesk-tests.exe" else "sshdesk-tests").step);
    const test_step = b.step("test", "Run native behavioral tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const names = [_][]const u8{ "sshdesk", "sshdesk-local", "sshdesk-server", "sshdesk-bench", "sshdesk-agent", "sshdesk-agent-ssh", "sshdesk-forced-command", "sshdesk-split", "sshdesk-remote" };
    for (names) |name| {
        const options = b.addOptions();
        options.addOption([]const u8, "command", name);
        const module = b.createModule(.{ .root_source_file = b.path("native/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("sshdesk", core);
        module.addOptions("options", options);
        b.installArtifact(b.addExecutable(.{ .name = name, .root_module = module }));
    }
}
