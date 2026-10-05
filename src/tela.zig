//! A tela é só um vetor de pixels na memória. Tudo que o editor desenha
//! acaba aqui, um pixel de cada vez; a janela só copia isto pro monitor.
const std = @import("std");

/// 0x00RRGGBB
pub const Cor = u32;

pub const Tela = struct {
    gpa: std.mem.Allocator,
    pixels: []Cor,
    largura: u16,
    altura: u16,

    pub fn criar(gpa: std.mem.Allocator, largura: u16, altura: u16, fundo: Cor) !Tela {
        const pixels = try gpa.alloc(Cor, @as(usize, largura) * altura);
        @memset(pixels, fundo);
        return .{ .gpa = gpa, .pixels = pixels, .largura = largura, .altura = altura };
    }

    pub fn destruir(t: *Tela) void {
        t.gpa.free(t.pixels);
    }

    /// Troca o tamanho mantendo o desenho que couber; o resto vira `fundo`.
    pub fn redimensionar(t: *Tela, largura: u16, altura: u16, fundo: Cor) !void {
        if (largura == t.largura and altura == t.altura) return;
        var nova = try Tela.criar(t.gpa, largura, altura, fundo);
        const l = @min(largura, t.largura);
        var y: usize = 0;
        while (y < @min(altura, t.altura)) : (y += 1) {
            @memcpy(nova.pixels[y * largura ..][0..l], t.pixels[y * t.largura ..][0..l]);
        }
        t.destruir();
        t.* = nova;
    }

    pub fn limpar(t: *Tela, cor: Cor) void {
        @memset(t.pixels, cor);
    }

    /// Pinta um pixel. Fora da tela não faz nada.
    pub fn ponto(t: *Tela, x: i32, y: i32, cor: Cor) void {
        if (x < 0 or y < 0 or x >= t.largura or y >= t.altura) return;
        t.pixels[@as(usize, @intCast(y)) * t.largura + @as(usize, @intCast(x))] = cor;
    }

    /// Círculo cheio: todo pixel a até `raio` do centro.
    pub fn disco(t: *Tela, cx: i32, cy: i32, raio: i32, cor: Cor) void {
        var dy: i32 = -raio;
        while (dy <= raio) : (dy += 1) {
            var dx: i32 = -raio;
            while (dx <= raio) : (dx += 1) {
                if (dx * dx + dy * dy <= raio * raio) t.ponto(cx + dx, cy + dy, cor);
            }
        }
    }

    /// Linha de (x0,y0) a (x1,y1) pelo algoritmo de Bresenham: anda um pixel
    /// por vez e usa só soma de inteiros pra decidir quando mudar de linha.
    /// Em cada pixel carimba um disco, que é o que dá a espessura do traço.
    pub fn linha(t: *Tela, x0: i32, y0: i32, x1: i32, y1: i32, raio: i32, cor: Cor) void {
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const passo_x: i32 = if (x0 < x1) 1 else -1;
        const passo_y: i32 = if (y0 < y1) 1 else -1;
        var erro = dx + dy;
        var x = x0;
        var y = y0;
        while (true) {
            t.disco(x, y, raio, cor);
            if (x == x1 and y == y1) break;
            const e2 = 2 * erro;
            if (e2 >= dy) {
                erro += dy;
                x += passo_x;
            }
            if (e2 <= dx) {
                erro += dx;
                y += passo_y;
            }
        }
    }
};

test "linha pinta as duas pontas e nada longe dela" {
    var t = try Tela.criar(std.testing.allocator, 20, 10, 0);
    defer t.destruir();
    t.linha(2, 1, 17, 8, 0, 0xffffff);
    try std.testing.expectEqual(@as(Cor, 0xffffff), t.pixels[1 * 20 + 2]);
    try std.testing.expectEqual(@as(Cor, 0xffffff), t.pixels[8 * 20 + 17]);
    try std.testing.expectEqual(@as(Cor, 0), t.pixels[8 * 20 + 2]);
    // Bresenham pinta exatamente um pixel por coluna quando a linha é mais larga que alta.
    var pintados: usize = 0;
    for (t.pixels) |p| pintados += @intFromBool(p != 0);
    try std.testing.expectEqual(@as(usize, 16), pintados);
}

test "desenhar fora da tela não quebra" {
    var t = try Tela.criar(std.testing.allocator, 8, 8, 0);
    defer t.destruir();
    t.linha(-50, -50, 60, 60, 3, 1);
    t.ponto(8, 0, 1);
    t.ponto(0, 8, 1);
}

test "redimensionar mantém o desenho" {
    var t = try Tela.criar(std.testing.allocator, 4, 4, 0);
    defer t.destruir();
    t.ponto(3, 3, 7);
    try t.redimensionar(10, 6, 9);
    try std.testing.expectEqual(@as(Cor, 7), t.pixels[3 * 10 + 3]);
    try std.testing.expectEqual(@as(Cor, 9), t.pixels[5 * 10 + 9]);
    try t.redimensionar(2, 2, 9);
    try std.testing.expectEqual(@as(usize, 4), t.pixels.len);
}
