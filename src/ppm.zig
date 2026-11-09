//! Leitura de imagens Netpbm: PPM (colorida) e PGM (cinza), nas versões em
//! texto (P3, P2) e binária (P6, P5). É o formato mais simples que existe:
//! um cabeçalho em texto (tipo, largura, altura, valor máximo) e depois os
//! valores de cada pixel, linha por linha. `#` começa um comentário.
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const opaco = tela_.opaco;

pub const Erro = error{ FormatoDesconhecido, CabecalhoRuim, FaltamPixels, GrandeDemais } || std.mem.Allocator.Error;

/// Lê números de um cabeçalho/corpo em texto, pulando espaços e comentários.
const Leitor = struct {
    b: []const u8,
    i: usize = 0,

    fn pularBrancos(l: *Leitor) void {
        while (l.i < l.b.len) {
            const c = l.b[l.i];
            if (c == '#') {
                while (l.i < l.b.len and l.b[l.i] != '\n') l.i += 1;
            } else if (std.ascii.isWhitespace(c)) {
                l.i += 1;
            } else break;
        }
    }

    fn numero(l: *Leitor) ?u32 {
        l.pularBrancos();
        const inicio = l.i;
        var v: u32 = 0;
        while (l.i < l.b.len and std.ascii.isDigit(l.b[l.i])) : (l.i += 1) {
            v = std.math.mul(u32, v, 10) catch return null;
            v = std.math.add(u32, v, l.b[l.i] - '0') catch return null;
        }
        return if (l.i == inicio) null else v;
    }
};

/// Converte um valor de 0..maximo pra 0..255.
fn canal(v: u32, maximo: u32) u32 {
    return @min(255, (@min(v, maximo) * 255 + maximo / 2) / maximo);
}

pub fn ler(gpa: std.mem.Allocator, bytes: []const u8) Erro!Tela {
    if (bytes.len < 2 or bytes[0] != 'P') return error.FormatoDesconhecido;
    const tipo = bytes[1];
    const colorida = switch (tipo) {
        '3', '6' => true,
        '2', '5' => false,
        else => return error.FormatoDesconhecido,
    };
    const binaria = tipo == '6' or tipo == '5';

    var l: Leitor = .{ .b = bytes, .i = 2 };
    const largura = l.numero() orelse return error.CabecalhoRuim;
    const altura = l.numero() orelse return error.CabecalhoRuim;
    const maximo = l.numero() orelse return error.CabecalhoRuim;
    if (largura == 0 or altura == 0 or maximo == 0 or maximo > 65535) return error.CabecalhoRuim;
    if (largura > std.math.maxInt(u16) or altura > std.math.maxInt(u16)) return error.GrandeDemais;

    var t = try Tela.criar(gpa, @intCast(largura), @intCast(altura), opaco);
    errdefer t.destruir();
    const por_pixel: usize = if (colorida) 3 else 1;

    if (binaria) {
        // Depois do valor máximo vem exatamente um caractere branco, e então
        // os bytes crus (2 bytes por valor, big-endian, se o máximo > 255).
        const largo: usize = if (maximo > 255) 2 else 1;
        const inicio = l.i + 1;
        const precisa = t.pixels.len * por_pixel * largo;
        if (inicio + precisa > bytes.len) return error.FaltamPixels;
        const corpo = bytes[inicio..][0..precisa];
        for (t.pixels, 0..) |*p, i| {
            var v: [3]u32 = undefined;
            for (0..por_pixel) |k| {
                const pos = (i * por_pixel + k) * largo;
                v[k] = if (largo == 2) @as(u32, corpo[pos]) << 8 | corpo[pos + 1] else corpo[pos];
            }
            p.* = cor(v, colorida, maximo);
        }
    } else {
        for (t.pixels) |*p| {
            var v: [3]u32 = undefined;
            for (0..por_pixel) |k| v[k] = l.numero() orelse return error.FaltamPixels;
            p.* = cor(v, colorida, maximo);
        }
    }
    return t;
}

fn cor(v: [3]u32, colorida: bool, maximo: u32) u32 {
    const r = canal(v[0], maximo);
    const g = if (colorida) canal(v[1], maximo) else r;
    const b = if (colorida) canal(v[2], maximo) else r;
    return opaco | r << 16 | g << 8 | b;
}

const testing = std.testing;

test "P3 com comentário" {
    var t = try ler(testing.allocator, "P3\n# um comentário\n2 1\n255\n255 0 0   0 0 255\n");
    defer t.destruir();
    try testing.expectEqual(@as(u16, 2), t.largura);
    try testing.expectEqual(opaco | 0xff0000, t.pixels[0]);
    try testing.expectEqual(opaco | 0x0000ff, t.pixels[1]);
}

test "P2 com máximo 15 vira cinza de 0 a 255" {
    var t = try ler(testing.allocator, "P2 2 1 15 15 0");
    defer t.destruir();
    try testing.expectEqual(opaco | 0xffffff, t.pixels[0]);
    try testing.expectEqual(opaco, t.pixels[1]);
}

test "P6 e P5 binários" {
    var t = try ler(testing.allocator, "P6\n1 1\n255\n\x10\x20\x30");
    defer t.destruir();
    try testing.expectEqual(opaco | 0x102030, t.pixels[0]);
    var g = try ler(testing.allocator, "P5 2 1 255\n\x00\x80");
    defer g.destruir();
    try testing.expectEqual(opaco | 0x808080, g.pixels[1]);
}

test "arquivo cortado ou estranho dá erro, não quebra" {
    try testing.expectError(error.FaltamPixels, ler(testing.allocator, "P3 2 2 255 1 2 3"));
    try testing.expectError(error.FormatoDesconhecido, ler(testing.allocator, "GIF89a"));
    try testing.expectError(error.CabecalhoRuim, ler(testing.allocator, "P3 0 2 255"));
    try testing.expectError(error.FaltamPixels, ler(testing.allocator, "P6 4 4 255\nab"));
}
