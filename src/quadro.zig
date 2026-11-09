//! Arquivo .quadro: o MODELO salvo, não a imagem. Um texto que dá pra ler:
//!
//!     quadro 1
//!     imagem 9:fotos/a.ppm
//!     camada retangulo 0  1 0 120 0 1 80  11:Retângulo 1  200 120 ff1d1d1f - 3
//!
//! Cada camada: tipo, grupo, a matriz (as 6 primeiras posições; a última
//! linha é sempre 0 0 1), o nome e os parâmetros do modelo. Texto livre vai
//! como "tamanho:bytes", assim pode ter espaço e acento sem escapar nada.
//! As imagens ficam nos arquivos delas; o quadro guarda só o caminho.
const std = @import("std");
const camada = @import("camada.zig");
const Documento = camada.Documento;
const Camada = camada.Camada;
const Tipo = camada.Tipo;
const Tela = @import("tela.zig").Tela;
const Mat3 = @import("mat3.zig").Mat3;

const Saida = struct {
    gpa: std.mem.Allocator,
    l: std.ArrayList(u8) = .empty,

    fn f(s: *Saida, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        try s.l.appendSlice(s.gpa, try std.fmt.bufPrint(&buf, fmt, args));
    }

    fn texto(s: *Saida, t: []const u8) !void {
        try s.f(" {d}:", .{t.len});
        try s.l.appendSlice(s.gpa, t);
    }
};

pub fn escrever(gpa: std.mem.Allocator, d: *const Documento) ![]u8 {
    var s: Saida = .{ .gpa = gpa };
    errdefer s.l.deinit(gpa);
    try s.f("quadro 1\n", .{});
    for (d.imagens.items) |img| {
        try s.f("imagem", .{});
        try s.texto(img.caminho);
        try s.f("\n", .{});
    }
    for (d.camadas.items) |*c| {
        const m = c.matriz.m;
        try s.f("camada {s} {d}  {d} {d} {d} {d} {d} {d} ", .{ @tagName(c.modelo), c.grupo, m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2] });
        try s.texto(c.nome());
        try s.f(" ", .{});
        switch (c.modelo) {
            .desenho, .linha, .seta => |t| {
                try s.f(" {x:0>8} {d} {d} {d} {d}", .{ t.cor, t.espessura, @intFromBool(t.mao), t.semente, t.pontos.items.len });
                for (t.pontos.items) |p| try s.f(" {d} {d}", .{ p.x, p.y });
            },
            .retangulo, .elipse => |fo| {
                try s.f(" {d} {d} {x:0>8} ", .{ fo.largura, fo.altura, fo.cor });
                if (fo.fundo) |fu| try s.f("{x:0>8}", .{fu}) else try s.f("-", .{});
                try s.f(" {d} {d} {d}", .{ fo.espessura, @intFromBool(fo.mao), fo.semente });
            },
            .texto => |t| {
                try s.f(" {x:0>8} {d}", .{ t.cor, t.escala });
                try s.texto(t.conteudo());
            },
            .imagem => |id| try s.f(" {d}", .{id}),
            .moldura => |mo| try s.f(" {d} {d} {d}", .{ mo.largura, mo.altura, mo.escala }),
        }
        try s.f("\n", .{});
    }
    return s.l.toOwnedSlice(gpa);
}

pub const Erro = error{ NaoEQuadro, ArquivoQuebrado } || std.mem.Allocator.Error;

const Leitor = struct {
    b: []const u8,
    i: usize = 0,

    fn pular(l: *Leitor) void {
        while (l.i < l.b.len and std.ascii.isWhitespace(l.b[l.i])) l.i += 1;
    }

    fn palavra(l: *Leitor) ?[]const u8 {
        l.pular();
        const ini = l.i;
        while (l.i < l.b.len and !std.ascii.isWhitespace(l.b[l.i])) l.i += 1;
        return if (l.i > ini) l.b[ini..l.i] else null;
    }

    fn real(l: *Leitor) !f32 {
        const p = l.palavra() orelse return error.ArquivoQuebrado;
        const v = std.fmt.parseFloat(f32, p) catch return error.ArquivoQuebrado;
        if (!std.math.isFinite(v)) return error.ArquivoQuebrado;
        return v;
    }

    fn inteiro(l: *Leitor, T: type, base: u8) !T {
        const p = l.palavra() orelse return error.ArquivoQuebrado;
        return std.fmt.parseInt(T, p, base) catch error.ArquivoQuebrado;
    }

    /// "5:Texto" (o texto pode ter espaços).
    fn texto(l: *Leitor) ![]const u8 {
        l.pular();
        const dois = std.mem.indexOfScalarPos(u8, l.b, l.i, ':') orelse return error.ArquivoQuebrado;
        const n = std.fmt.parseInt(usize, l.b[l.i..dois], 10) catch return error.ArquivoQuebrado;
        if (dois + 1 + n > l.b.len) return error.ArquivoQuebrado;
        l.i = dois + 1 + n;
        return l.b[dois + 1 ..][0..n];
    }
};

/// Troca o conteúdo de `d` pelo do arquivo. `contexto.imagem(caminho)`
/// lê cada imagem (quem sabe onde estão os arquivos é quem chama).
pub fn ler(d: *Documento, bytes: []const u8, contexto: anytype) !void {
    var l: Leitor = .{ .b = bytes };
    const cab = l.palavra() orelse return error.NaoEQuadro;
    if (!std.mem.eql(u8, cab, "quadro")) return error.NaoEQuadro;
    _ = try l.inteiro(u32, 10);
    d.limpar();
    const gpa = d.gpa;
    errdefer d.limpar();
    while (l.palavra()) |tipo_linha| {
        if (std.mem.eql(u8, tipo_linha, "imagem")) {
            const caminho = try l.texto();
            var px = try contexto.imagem(caminho);
            errdefer px.destruir();
            const copia = try gpa.dupe(u8, caminho);
            errdefer gpa.free(copia);
            try d.imagens.append(gpa, .{ .pixels = px, .caminho = copia });
            continue;
        }
        if (!std.mem.eql(u8, tipo_linha, "camada")) return error.ArquivoQuebrado;
        const tipo = std.meta.stringToEnum(Tipo, l.palavra() orelse return error.ArquivoQuebrado) orelse return error.ArquivoQuebrado;
        var c: Camada = .{ .modelo = undefined };
        c.grupo = try l.inteiro(u32, 10);
        var m = Mat3.identidade;
        for (0..2) |i| for (0..3) |j| {
            m.m[i][j] = try l.real();
        };
        c.matriz = m;
        if (m.inversa() == null) return error.ArquivoQuebrado;
        const nome = try l.texto();
        c.batizar("{s}", .{nome[0..@min(nome.len, c.nome_buf.len)]});
        c.modelo = switch (tipo) {
            .desenho, .linha, .seta => blk: {
                var t: camada.Traco = .{ .cor = try l.inteiro(u32, 16), .espessura = try l.real(), .mao = try l.inteiro(u1, 10) == 1, .semente = try l.inteiro(u32, 10) };
                errdefer t.pontos.deinit(gpa);
                const n = try l.inteiro(usize, 10);
                if (n > 1_000_000) return error.ArquivoQuebrado;
                try t.pontos.ensureTotalCapacity(gpa, n);
                for (0..n) |_| t.pontos.appendAssumeCapacity(.{ .x = try l.real(), .y = try l.real() });
                break :blk switch (tipo) {
                    .desenho => .{ .desenho = t },
                    .linha => .{ .linha = t },
                    else => .{ .seta = t },
                };
            },
            .retangulo, .elipse => blk: {
                const w = try l.real();
                const h = try l.real();
                const cor = try l.inteiro(u32, 16);
                const fp = l.palavra() orelse return error.ArquivoQuebrado;
                const fundo: ?u32 = if (std.mem.eql(u8, fp, "-")) null else std.fmt.parseInt(u32, fp, 16) catch return error.ArquivoQuebrado;
                const f: camada.Forma = .{ .largura = w, .altura = h, .cor = cor, .fundo = fundo, .espessura = try l.real(), .mao = try l.inteiro(u1, 10) == 1, .semente = try l.inteiro(u32, 10) };
                break :blk if (tipo == .retangulo) .{ .retangulo = f } else .{ .elipse = f };
            },
            .texto => blk: {
                var t: camada.Texto = .{ .cor = try l.inteiro(u32, 16), .escala = try l.inteiro(u8, 10) };
                if (t.escala == 0 or t.escala > 16) return error.ArquivoQuebrado;
                t.trocar(try l.texto());
                break :blk .{ .texto = t };
            },
            .imagem => blk: {
                const id = try l.inteiro(u32, 10);
                if (id >= d.imagens.items.len) return error.ArquivoQuebrado;
                break :blk .{ .imagem = id };
            },
            .moldura => blk: {
                const w = try l.real();
                const h = try l.real();
                const e = try l.inteiro(u8, 10);
                d.molduras += 1;
                break :blk .{ .moldura = .{ .largura = w, .altura = h, .numero = d.molduras, .escala = std.math.clamp(e, 1, 4) } };
            },
        };
        errdefer c.liberar(gpa);
        try c.gerar(gpa);
        try d.camadas.append(gpa, c);
        if (tipo != .moldura) d.criados += 1;
        d.grupos = @max(d.grupos, c.grupo);
    }
}

const testing = std.testing;
const opaco = @import("tela.zig").opaco;

const SemImagens = struct {
    fn imagem(_: SemImagens, caminho: []const u8) !Tela {
        var t = try Tela.criar(testing.allocator, 2, 2, opaco);
        t.pixels[0] = @intCast(caminho.len);
        return t;
    }
};

test "salvar e abrir devolve o mesmo quadro" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    var t: camada.Traco = .{ .cor = opaco | 0x123456, .espessura = 2.5 };
    try t.pontos.appendSlice(testing.allocator, &.{ .{ .x = 1.5, .y = -2 }, .{ .x = 30, .y = 40.25 } });
    _ = try d.adicionar(.{ .modelo = .{ .seta = t }, .grupo = 3 });
    var tx: camada.Texto = .{ .cor = opaco, .escala = 5 };
    tx.trocar("São João: 1 2");
    _ = try d.adicionar(.{ .modelo = .{ .texto = tx }, .matriz = Mat3.rotacao(0.3).vezes(Mat3.translacao(5, 7)) });
    _ = try d.adicionar(.{ .modelo = .{ .elipse = .{ .largura = 50, .altura = 20, .cor = opaco, .fundo = opaco | 0xfff3bf, .espessura = 3, .mao = true } } });
    _ = try d.adicionar(.{ .modelo = .{ .moldura = .{ .largura = 300, .altura = 200, .numero = 0, .escala = 3 } } });
    try d.imagens.append(testing.allocator, .{ .pixels = try Tela.criar(testing.allocator, 2, 2, opaco), .caminho = try testing.allocator.dupe(u8, "fotos/a b.ppm") });
    _ = try d.adicionar(.{ .modelo = .{ .imagem = 0 } });

    const bytes = try escrever(testing.allocator, &d);
    defer testing.allocator.free(bytes);
    var e = Documento.criar(testing.allocator);
    defer e.destruir();
    try ler(&e, bytes, SemImagens{});

    try testing.expectEqual(d.camadas.items.len, e.camadas.items.len);
    const seta = e.camadas.items[0].modelo.seta;
    try testing.expectEqual(@as(f32, 40.25), seta.pontos.items[1].y);
    try testing.expectEqual(@as(u32, 3), e.camadas.items[0].grupo);
    try testing.expectEqualStrings("São João: 1 2", e.camadas.items[1].modelo.texto.conteudo());
    try testing.expectEqual(d.camadas.items[1].matriz, e.camadas.items[1].matriz);
    try testing.expectEqual(@as(?u32, opaco | 0xfff3bf), e.camadas.items[2].modelo.elipse.fundo);
    try testing.expect(e.camadas.items[2].modelo.elipse.mao);
    try testing.expectEqual(d.camadas.items[2].modelo.elipse.semente, e.camadas.items[2].modelo.elipse.semente);
    try testing.expectEqual(@as(u8, 3), e.camadas.items[3].modelo.moldura.escala);
    try testing.expectEqualStrings("fotos/a b.ppm", e.imagens.items[0].caminho);
    try testing.expectEqualStrings(d.camadas.items[2].nome(), e.camadas.items[2].nome());
    // O próximo objeto continua a numeração.
    try testing.expectEqual(d.criados, e.criados);
}

test "arquivo estranho dá erro e não deixa nada pela metade" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    try testing.expectError(error.NaoEQuadro, ler(&d, "P3 1 1 255", SemImagens{}));
    try testing.expectError(error.ArquivoQuebrado, ler(&d, "quadro 1\ncamada desenho 0 1 0 0 0 1 0 1:x ff000000 2 0 1 5 1 2", SemImagens{}));
    try testing.expectEqual(@as(usize, 0), d.camadas.items.len);
}
