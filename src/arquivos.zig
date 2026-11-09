//! Lista os arquivos de certas extensões (.ppm e .pgm, ou .quadro) de uma
//! pasta e das subpastas, pra escolher dentro da janela (o editor não tem
//! diálogo de arquivo do sistema).
const std = @import("std");
const Io = std.Io;

const profundidade_max = 3;
const max_arquivos = 300;

pub const Lista = struct {
    gpa: std.mem.Allocator,
    /// Caminhos relativos à pasta, em ordem alfabética.
    nomes: std.ArrayList([]u8) = .empty,

    pub fn deinit(l: *Lista) void {
        for (l.nomes.items) |n| l.gpa.free(n);
        l.nomes.deinit(l.gpa);
    }
};

pub const imagens = [_][]const u8{ ".ppm", ".pgm" };
pub const quadros = [_][]const u8{".quadro"};

fn combina(nome: []const u8, extensoes: []const []const u8) bool {
    const ext = std.fs.path.extension(nome);
    for (extensoes) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn listar(gpa: std.mem.Allocator, io: Io, pasta: []const u8, extensoes: []const []const u8) !Lista {
    var l: Lista = .{ .gpa = gpa };
    errdefer l.deinit();
    var dir = try Io.Dir.cwd().openDir(io, pasta, .{ .iterate = true });
    defer dir.close(io);
    try varrer(&l, io, dir, "", 0, extensoes);
    std.mem.sort([]u8, l.nomes.items, {}, struct {
        fn menor(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.menor);
    return l;
}

fn varrer(l: *Lista, io: Io, dir: Io.Dir, prefixo: []const u8, nivel: usize, extensoes: []const []const u8) !void {
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (l.nomes.items.len >= max_arquivos) return;
        if (e.name.len > 0 and e.name[0] == '.') continue; // ocultos e .zig-cache
        const caminho = if (prefixo.len == 0)
            try l.gpa.dupe(u8, e.name)
        else
            try std.fs.path.join(l.gpa, &.{ prefixo, e.name });
        switch (e.kind) {
            .file => if (combina(e.name, extensoes)) {
                try l.nomes.append(l.gpa, caminho);
                continue;
            },
            .directory => if (nivel + 1 < profundidade_max) {
                defer l.gpa.free(caminho);
                var sub = dir.openDir(io, e.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                try varrer(l, io, sub, caminho, nivel + 1, extensoes);
                continue;
            },
            else => {},
        }
        l.gpa.free(caminho);
    }
}

test "acha imagens em subpastas e ignora o resto" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "fotos/velhas");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ppm", .data = "P3 1 1 255 0 0 0" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notas.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fotos/velhas/b.PGM", .data = "P2 1 1 255 0" });

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &base);
    var l = try listar(std.testing.allocator, io, base[0..n], &imagens);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 2), l.nomes.items.len);
    try std.testing.expectEqualStrings("a.ppm", l.nomes.items[0]);
    try std.testing.expectEqualStrings("fotos/velhas/b.PGM", l.nomes.items[1]);
}
