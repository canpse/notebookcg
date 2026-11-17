const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // O redesenho passa por todos os pixels da janela a cada quadro: em Debug
    // fica lento demais. Por isso os programas saem em ReleaseFast se ninguém
    // pedir outra coisa; os testes ficam em Debug, que confere estouro de
    // conta e índice fora do vetor.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Modo de compilação") orelse .ReleaseFast;

    // CG Interativa: o software educacional (o trabalho).
    const aulas = b.addExecutable(.{ .name = "cg-interativa", .root_module = b.createModule(.{
        .root_source_file = b.path("src/aulas.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    }) });
    b.installArtifact(aulas);

    // Atalho no menu de aplicativos e ícone (padrão freedesktop), com o
    // caminho do binário de onde for instalado: `zig build --prefix ~/.local`.
    const atalho = std.mem.replaceOwned(u8, b.allocator, @embedFile("assets/cg-interativa.desktop.in"), "@BIN@", b.getInstallPath(.bin, "cg-interativa")) catch @panic("sem memória");
    const gerados = b.addWriteFiles();
    const desktop = gerados.add("cg-interativa.desktop", atalho);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(desktop, .{ .custom = "share/applications" }, "cg-interativa.desktop").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("assets/cg-interativa.png"), .{ .custom = "share/icons/hicolor/256x256/apps" }, "cg-interativa.png").step);
    const rodar = b.addRunArtifact(aulas);
    if (b.args) |args| rodar.addArgs(args);
    b.step("run", "Abre a CG Interativa (zig build run -- N abre na aula N)").dependOn(&rodar.step);

    // O quadro de desenho que veio antes (mesma base: janela, tela, matrizes).
    const editor = b.addExecutable(.{ .name = "editor", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const rodar_editor = b.addRunArtifact(editor);
    if (b.args) |args| rodar_editor.addArgs(args);
    b.step("editor", "Abre o quadro de desenho antigo").dependOn(&rodar_editor.step);

    const testes = b.step("test", "Roda os testes");
    for ([_][]const u8{ "src/aulas.zig", "src/main.zig" }) |raiz| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(raiz),
            .target = target,
            .optimize = .Debug,
        }) });
        testes.dependOn(&b.addRunArtifact(t).step);
    }
}
