const std = @import("std");

pub fn build(b: *std.Build) void {
    const modulo = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const exe = b.addExecutable(.{ .name = "editor", .root_module = modulo });
    b.installArtifact(exe);

    b.step("run", "Abre o editor").dependOn(&b.addRunArtifact(exe).step);

    const testes = b.addTest(.{ .root_module = modulo });
    b.step("test", "Roda os testes").dependOn(&b.addRunArtifact(testes).step);
}
