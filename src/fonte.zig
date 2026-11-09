//! Texto na tela com fonte bitmap: cada letra é uma grade de 8×16 bits
//! (1 = pinta, 0 = deixa). Escrever é carimbar a grade de cada letra,
//! uma ao lado da outra. Sem curvas nem antisserrilhado: o mais simples que
//! existe, e o mesmo que o console do Linux usa.
const std = @import("std");
const dados = @import("fonte_dados.zig");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;

pub const largura = dados.largura;
pub const altura = dados.altura;

/// Glifo de um caractere Unicode; fora do Latin-1 vira "?".
fn glifo(codigo: u21) *const [altura]u8 {
    const c: u21 = if (codigo >= dados.primeiro and codigo <= 255) codigo else '?';
    return &dados.glifos[c - dados.primeiro];
}

/// Quantos caracteres (não bytes: "ã" ocupa 2 bytes em UTF-8 e 1 casa na tela).
fn contar(texto: []const u8) usize {
    var n: usize = 0;
    var it = Iterador{ .bytes = texto };
    while (it.proximo()) |_| n += 1;
    return n;
}

/// Lê UTF-8 sem travar em byte inválido (vira "?").
const Iterador = struct {
    bytes: []const u8,
    i: usize = 0,

    fn proximo(it: *Iterador) ?u21 {
        if (it.i >= it.bytes.len) return null;
        const tam = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch {
            it.i += 1;
            return '?';
        };
        if (it.i + tam > it.bytes.len) {
            it.i = it.bytes.len;
            return '?';
        }
        const c = std.unicode.utf8Decode(it.bytes[it.i..][0..tam]) catch '?';
        it.i += tam;
        return c;
    }
};

/// Largura do texto em pixels.
pub fn medir(texto: []const u8, escala: i32) i32 {
    return @as(i32, @intCast(contar(texto))) * largura * escala;
}

/// Escreve com o canto de cima à esquerda em (x, y). `escala` 2 desenha cada
/// bit como um quadrado 2×2. Devolve o x onde o texto terminou.
pub fn escrever(t: *Tela, x: i32, y: i32, texto: []const u8, cor: Cor, escala: i32) i32 {
    var cx = x;
    var it = Iterador{ .bytes = texto };
    while (it.proximo()) |c| {
        for (glifo(c), 0..) |linha_bits, ly| {
            var bits = linha_bits;
            var lx: i32 = 0;
            while (bits != 0) : (lx += 1) {
                if (bits & 0x80 != 0) {
                    const px = cx + lx * escala;
                    const py = y + @as(i32, @intCast(ly)) * escala;
                    var dy: i32 = 0;
                    while (dy < escala) : (dy += 1) {
                        var dx: i32 = 0;
                        while (dx < escala) : (dx += 1) t.ponto(px + dx, py + dy, cor);
                    }
                }
                bits <<= 1;
            }
        }
        cx += largura * escala;
    }
    return cx;
}

const testing = std.testing;

test "medir conta caracteres, não bytes" {
    try testing.expectEqual(@as(i32, 3 * 8), medir("São", 1));
    try testing.expectEqual(@as(i32, 2 * 16), medir("ç!", 2));
}

test "escrever pinta dentro da caixa de cada letra e devolve onde parou" {
    var t = try Tela.criar(testing.allocator, 40, 20, 0);
    defer t.destruir();
    const fim = escrever(&t, 2, 1, "Ãé", 0xffffff, 1);
    try testing.expectEqual(@as(i32, 18), fim);
    var pintados: usize = 0;
    for (t.pixels, 0..) |p, i| {
        if (p == 0) continue;
        pintados += 1;
        const x = i % 40;
        const y = i / 40;
        try testing.expect(x >= 2 and x < 18 and y >= 1 and y < 17);
    }
    try testing.expect(pintados > 20);
}

test "acento aparece: Ã tem pixel nas 2 linhas de cima e A não" {
    var com = try Tela.criar(testing.allocator, 8, 16, 0);
    defer com.destruir();
    var sem = try Tela.criar(testing.allocator, 8, 16, 0);
    defer sem.destruir();
    _ = escrever(&com, 0, 0, "Ã", 1, 1);
    _ = escrever(&sem, 0, 0, "A", 1, 1);
    var topo_com: usize = 0;
    var topo_sem: usize = 0;
    for (0..2 * 8) |i| {
        topo_com += @intFromBool(com.pixels[i] != 0);
        topo_sem += @intFromBool(sem.pixels[i] != 0);
    }
    try testing.expect(topo_com > 0);
    try testing.expectEqual(@as(usize, 0), topo_sem);
}

test "byte inválido não quebra" {
    var t = try Tela.criar(testing.allocator, 40, 16, 0);
    defer t.destruir();
    _ = escrever(&t, 0, 0, "a\xffb\xc3", 1, 1);
}
