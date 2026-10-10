const std = @import("std");

pub fn build(b: *std.Build) void {
    // 目标:x86_64-linux 静态、无 libc(直接 syscall),可在任意 SteamOS 上运行
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Build optimization mode") orelse .ReleaseSmall;

    const exe = b.addExecutable(.{
        .name = "dt-monitor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = optimize == .ReleaseSmall,
            .unwind_tables = if (optimize != .Debug) .none else null,
        }),
    });
    // 全项目禁止 linkLibC() 与 @cImport
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
