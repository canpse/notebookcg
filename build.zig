const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // O redesenho passa por todos os pixels da janela a cada quadro: em Debug
    // fica ~150 ms por quadro e girar/arrastar engasga. Por isso o editor sai
    // em ReleaseFast se ninguém pedir outra coisa; os testes ficam em Debug,
    // que confere estouro de conta e índice fora do vetor.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Modo de compilação do editor") orelse .ReleaseFast;

    const modulo = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "editor", .root_module = modulo });
    b.installArtifact(exe);

    b.step("run", "Abre o editor").dependOn(&b.addRunArtifact(exe).step);

    const modulo_testes = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const testes = b.addTest(.{ .root_module = modulo_testes });
    b.step("test", "Roda os testes").dependOn(&b.addRunArtifact(testes).step);
}
