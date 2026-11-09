//! Camadas: cada uma é um objeto feito a partir de um MODELO (o que ela é:
//! desenho, retângulo, elipse, texto...) com os parâmetros dele, mais uma
//! matriz que leva da camada pra folha.
//!
//! O modelo é a descrição; os pixels da camada são a imagem gerada a partir
//! dele (modelo → imagem, que é a definição de computação gráfica). Mudar um
//! parâmetro é gerar os pixels de novo. Mover, girar ou escalar é só trocar a
//! matriz: os pixels não mudam, então dá pra girar e voltar sem perder nada.
//!
//! Pra mostrar na janela, cada pixel da camada passa por duas matrizes:
//! camada → folha (a da camada) e folha → janela (a vista). As camadas são
//! pintadas de baixo pra cima, cada uma por cima da anterior: o algoritmo
//! do pintor.
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const Caixa = tela_.Caixa;
const opaco = tela_.opaco;
const m3 = @import("mat3.zig");
const Mat3 = m3.Mat3;
const Ponto = m3.Ponto;
const fonte = @import("fonte.zig");

pub const Tipo = enum {
    desenho,
    retangulo,
    elipse,
    texto,
    imagem,

    pub fn nome(t: Tipo) []const u8 {
        return switch (t) {
            .desenho => "Desenho",
            .retangulo => "Retângulo",
            .elipse => "Elipse",
            .texto => "Texto",
            .imagem => "Imagem",
        };
    }
};

pub const Forma = struct { largura: u16, altura: u16, cor: Cor };

pub const Texto = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,
    cor: Cor,
    escala: u8 = 3,

    pub fn conteudo(t: *const Texto) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn trocar(t: *Texto, s: []const u8) void {
        const n = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = @intCast(n);
    }

    /// Põe um caractere no fim (em UTF-8). Sem espaço, não põe.
    pub fn inserir(t: *Texto, c: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &tmp) catch return;
        if (t.len + n > t.buf.len) return;
        @memcpy(t.buf[t.len..][0..n], tmp[0..n]);
        t.len += n;
    }

    /// Tira o último caractere (que pode ter mais de um byte: "ã" tem 2).
    pub fn apagarUltimo(t: *Texto) void {
        while (t.len > 0) {
            t.len -= 1;
            // Bytes 10xxxxxx são continuação: segue até o começo da letra.
            if (t.buf[t.len] & 0xc0 != 0x80) break;
        }
    }
};

pub const Modelo = union(Tipo) {
    /// Pincel livre: aqui os próprios pixels são o modelo.
    desenho,
    retangulo: Forma,
    elipse: Forma,
    texto: Texto,
    imagem,
};

pub const Camada = struct {
    pixels: Tela,
    modelo: Modelo,
    /// camada → folha
    matriz: Mat3 = Mat3.identidade,
    /// Onde tem tinta, em pixels da camada (null = vazia). Serve pra
    /// desenhar só essa parte, pro contorno da seleção e pro centro do giro.
    conteudo: ?Caixa = null,
    nome_buf: [32]u8 = undefined,
    nome_len: u8 = 0,

    pub fn nome(c: *const Camada) []const u8 {
        return c.nome_buf[0..c.nome_len];
    }

    fn batizar(c: *Camada, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&c.nome_buf, fmt, args) catch c.nome_buf[0..];
        c.nome_len = @intCast(s.len);
    }

    /// Gera os pixels a partir do modelo (no desenho não há o que gerar).
    pub fn gerar(c: *Camada) !void {
        const gpa = c.pixels.gpa;
        var nova: Tela = switch (c.modelo) {
            .desenho, .imagem => return,
            .retangulo => |f| try Tela.criar(gpa, f.largura, f.altura, f.cor),
            .elipse => |f| blk: {
                var t = try Tela.criar(gpa, f.largura, f.altura, 0);
                // Pixel dentro se (x/rx)² + (y/ry)² ≤ 1, medindo do centro
                // da elipse até o centro do pixel.
                const rx = @as(f32, @floatFromInt(f.largura)) / 2;
                const ry = @as(f32, @floatFromInt(f.altura)) / 2;
                for (0..f.altura) |y| {
                    const dy = (@as(f32, @floatFromInt(y)) + 0.5 - ry) / ry;
                    for (0..f.largura) |x| {
                        const dx = (@as(f32, @floatFromInt(x)) + 0.5 - rx) / rx;
                        if (dx * dx + dy * dy <= 1) t.pixels[y * f.largura + x] = f.cor;
                    }
                }
                break :blk t;
            },
            .texto => |*tx| blk: {
                const s = tx.conteudo();
                const esc: i32 = tx.escala;
                const l: u16 = @intCast(@max(1, fonte.medir(s, esc)));
                var t = try Tela.criar(gpa, l, @intCast(fonte.altura * esc), 0);
                _ = fonte.escrever(&t, 0, 0, s, tx.cor, esc);
                break :blk t;
            },
        };
        errdefer nova.destruir();
        c.pixels.destruir();
        c.pixels = nova;
        c.conteudo = .{ .x0 = 0, .y0 = 0, .x1 = nova.largura, .y1 = nova.altura };
    }

    /// Cor do modelo (o desenho não tem uma só: cada traço tem a dele).
    pub fn cor(c: *const Camada) ?Cor {
        return switch (c.modelo) {
            .retangulo, .elipse => |f| f.cor,
            .texto => |t| t.cor,
            .desenho, .imagem => null,
        };
    }

    /// Troca a cor do modelo e gera os pixels de novo.
    pub fn mudarCor(c: *Camada, nova: Cor) !void {
        switch (c.modelo) {
            .retangulo, .elipse => |*f| f.cor = nova,
            .texto => |*t| t.cor = nova,
            .desenho, .imagem => return,
        }
        try c.gerar();
    }

    /// camada → janela
    pub fn naJanela(c: *const Camada, vista: Mat3) Mat3 {
        return vista.vezes(c.matriz);
    }

    /// Traço de pincel em coordenadas da camada.
    pub fn pincel(c: *Camada, x0: i32, y0: i32, x1: i32, y1: i32, raio: i32, cor_traco: Cor) void {
        c.pixels.linha(x0, y0, x1, y1, raio, cor_traco);
        const tocado: Caixa = .{ .x0 = @min(x0, x1) - raio, .y0 = @min(y0, y1) - raio, .x1 = @max(x0, x1) + raio + 1, .y1 = @max(y0, y1) + raio + 1 };
        if (tocado.recortar(c.pixels.largura, c.pixels.altura)) |t| c.conteudo = Caixa.unir(c.conteudo, t);
    }

    pub fn limpar(c: *Camada) void {
        if (c.modelo != .desenho) return;
        c.pixels.limpar(0);
        c.conteudo = null;
    }

    /// Tem tinta no pixel (x, y) da camada?
    pub fn temTinta(c: *const Camada, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= c.pixels.largura or y >= c.pixels.altura) return false;
        return c.pixels.pegar(x, y) >> 24 != 0;
    }

    /// Centro do que está desenhado (ou da camada, se vazia), na camada.
    pub fn centro(c: *const Camada) Ponto {
        const k = c.conteudo orelse Caixa{ .x0 = 0, .y0 = 0, .x1 = c.pixels.largura, .y1 = c.pixels.altura };
        return .{ .x = @as(f32, @floatFromInt(k.x0 + k.x1)) / 2, .y = @as(f32, @floatFromInt(k.y0 + k.y1)) / 2 };
    }

    /// Os 4 cantos do conteúdo levados pra janela (em ordem, pra contorno).
    pub fn cantos(c: *const Camada, vista: Mat3) ?[4]Ponto {
        const k = c.conteudo orelse return null;
        const m = c.naJanela(vista);
        // Folga de 4 px pra o contorno não ficar escondido em cima do traço.
        const folga = 4;
        const x0: f32 = @floatFromInt(k.x0 - folga);
        const y0: f32 = @floatFromInt(k.y0 - folga);
        const x1: f32 = @floatFromInt(k.x1 + folga);
        const y1: f32 = @floatFromInt(k.y1 + folga);
        return .{ m.aplicar(x0, y0), m.aplicar(x1, y0), m.aplicar(x1, y1), m.aplicar(x0, y1) };
    }
};

/// Cores que os objetos novos vão recebendo, pra dar pra distinguir.
const paleta = [_]Cor{ opaco | 0x2f7df6, opaco | 0xf59e0b, opaco | 0x10b981, opaco | 0xef4444, opaco | 0x8b5cf6 };

pub const Documento = struct {
    gpa: std.mem.Allocator,
    /// Da de baixo (0, o fundo) pra de cima.
    camadas: std.ArrayList(Camada) = .empty,
    selecionada: usize = 0,
    largura: u16,
    altura: u16,
    /// Quantos objetos já foram criados (dá o número no nome).
    criados: u32 = 0,

    /// Documento com um retângulo de fundo do tamanho da folha, selecionado.
    pub fn criar(gpa: std.mem.Allocator, largura: u16, altura: u16, papel: Cor) !Documento {
        var d: Documento = .{ .gpa = gpa, .largura = largura, .altura = altura };
        errdefer d.destruir();
        var fundo: Camada = .{
            .pixels = try Tela.criar(gpa, 1, 1, 0),
            .modelo = .{ .retangulo = .{ .largura = largura, .altura = altura, .cor = papel } },
        };
        errdefer fundo.pixels.destruir();
        try fundo.gerar();
        fundo.batizar("Fundo", .{});
        try d.camadas.append(gpa, fundo);
        return d;
    }

    pub fn destruir(d: *Documento) void {
        for (d.camadas.items) |*c| c.pixels.destruir();
        d.camadas.deinit(d.gpa);
    }

    pub fn atual(d: *Documento) *Camada {
        return &d.camadas.items[d.selecionada];
    }

    /// Objeto novo do `tipo` com os parâmetros padrão, centrado em `centro`
    /// (na folha), logo acima da selecionada; passa a ser o selecionado.
    /// O desenho é uma folha transparente do tamanho do documento.
    pub fn adicionar(d: *Documento, tipo: Tipo, centro: Ponto) !void {
        const cor = paleta[d.criados % paleta.len];
        var c: Camada = switch (tipo) {
            .desenho => .{ .pixels = try Tela.criar(d.gpa, d.largura, d.altura, 0), .modelo = .desenho },
            .retangulo => .{ .pixels = try Tela.criar(d.gpa, 1, 1, 0), .modelo = .{ .retangulo = .{ .largura = 200, .altura = 120, .cor = cor } } },
            .elipse => .{ .pixels = try Tela.criar(d.gpa, 1, 1, 0), .modelo = .{ .elipse = .{ .largura = 160, .altura = 160, .cor = cor } } },
            .texto => blk: {
                var t: Texto = .{ .cor = opaco | 0x1d1d1f };
                t.trocar("Texto");
                break :blk .{ .pixels = try Tela.criar(d.gpa, 1, 1, 0), .modelo = .{ .texto = t } };
            },
            .imagem => return error.AindaNaoTem,
        };
        errdefer c.pixels.destruir();
        try c.gerar();
        if (tipo != .desenho) {
            const l: f32 = @floatFromInt(c.pixels.largura);
            const a: f32 = @floatFromInt(c.pixels.altura);
            c.matriz = Mat3.translacao(@round(centro.x - l / 2), @round(centro.y - a / 2));
        }
        d.criados += 1;
        c.batizar("{s} {d}", .{ tipo.nome(), d.criados });
        try d.camadas.insert(d.gpa, d.selecionada + 1, c);
        d.selecionada += 1;
    }

    /// Apaga a selecionada; a última que sobrar não sai.
    pub fn apagar(d: *Documento) void {
        if (d.camadas.items.len == 1) return;
        var c = d.camadas.orderedRemove(d.selecionada);
        c.pixels.destruir();
        if (d.selecionada > 0) d.selecionada -= 1;
    }

    /// Troca a selecionada de lugar com a vizinha (+1 sobe, -1 desce).
    pub fn mover(d: *Documento, sentido: i2) void {
        const alvo = @as(isize, @intCast(d.selecionada)) + sentido;
        if (alvo < 0 or alvo >= d.camadas.items.len) return;
        const a: usize = @intCast(alvo);
        std.mem.swap(Camada, &d.camadas.items[d.selecionada], &d.camadas.items[a]);
        d.selecionada = a;
    }

    /// Seleção por clique: a camada mais de cima que tem tinta embaixo do
    /// ponto (x, y) da janela. Pergunta a cada camada com a inversa dela.
    pub fn tocar(d: *const Documento, vista: Mat3, x: i32, y: i32) ?usize {
        var i = d.camadas.items.len;
        while (i > 0) {
            i -= 1;
            const c = &d.camadas.items[i];
            const inv = c.naJanela(vista).inversa() orelse continue;
            const p = inv.aplicar(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            if (@abs(p.x) > 1e6 or @abs(p.y) > 1e6) continue;
            if (c.temTinta(@intFromFloat(@floor(p.x)), @intFromFloat(@floor(p.y)))) return i;
        }
        return null;
    }

    /// Transforma a camada selecionada por `g`, dada em coordenadas da
    /// JANELA (ex.: arrastar 10 px pra direita na tela, mesmo com a vista
    /// girada). Como a matriz da camada vive na folha:
    /// nova = vista⁻¹ · g · vista · antiga.
    pub fn transformar(d: *Documento, vista: Mat3, g: Mat3) void {
        const inv_vista = vista.inversa() orelse return;
        const c = d.atual();
        const nova = inv_vista.vezes(g).vezes(vista).vezes(c.matriz);
        if (nova.inversa() == null) return;
        c.matriz = nova;
    }

    /// Centro da selecionada, na janela.
    pub fn centroNaJanela(d: *Documento, vista: Mat3) Ponto {
        const c = d.atual();
        const p = c.centro();
        return c.naJanela(vista).aplicar(p.x, p.y);
    }

    /// Pinta todas as camadas na janela, de baixo pra cima.
    pub fn desenhar(d: *const Documento, janela: *Tela, vista: Mat3) void {
        for (d.camadas.items) |*c| {
            const inv = c.naJanela(vista).inversa() orelse continue;
            const k = c.cantos(vista) orelse continue;
            // Só a área da janela onde a camada pode cair, com 1 pixel de
            // folga pela mistura bilinear da borda.
            var caixa: Caixa = .{ .x0 = std.math.maxInt(i32), .y0 = std.math.maxInt(i32), .x1 = std.math.minInt(i32), .y1 = std.math.minInt(i32) };
            for (k) |p| {
                const x = std.math.clamp(p.x, -1e6, 1e6);
                const y = std.math.clamp(p.y, -1e6, 1e6);
                caixa = Caixa.unir(caixa, .{ .x0 = @as(i32, @intFromFloat(@floor(x))) - 1, .y0 = @as(i32, @intFromFloat(@floor(y))) - 1, .x1 = @as(i32, @intFromFloat(@ceil(x))) + 2, .y1 = @as(i32, @intFromFloat(@ceil(y))) + 2 });
            }
            janela.comporTransformada(&c.pixels, inv, caixa);
        }
    }

    /// Contorno da camada selecionada: o retângulo do conteúdo levado pra
    /// janela (gira e escala junto com a camada).
    pub fn contorno(d: *Documento, janela: *Tela, vista: Mat3, cor: Cor) void {
        const k = d.atual().cantos(vista) orelse return;
        for (0..4) |i| {
            const a = k[i];
            const b = k[(i + 1) % 4];
            janela.linha(arredondar(a.x), arredondar(a.y), arredondar(b.x), arredondar(b.y), 0, cor);
        }
    }
};

fn arredondar(v: f32) i32 {
    return @intFromFloat(@round(std.math.clamp(v, -1e5, 1e5)));
}

const testing = std.testing;
const origem: Ponto = .{ .x = 0, .y = 0 };

test "clicar seleciona a camada de cima que tem tinta ali" {
    var d = try Documento.criar(testing.allocator, 50, 50, opaco | 0xffffff);
    defer d.destruir();
    try d.adicionar(.desenho, origem);
    d.atual().pincel(10, 10, 20, 10, 1, opaco);
    try testing.expectEqual(@as(?usize, 1), d.tocar(Mat3.identidade, 15, 10));
    // Longe do traço só tem o fundo.
    try testing.expectEqual(@as(?usize, 0), d.tocar(Mat3.identidade, 40, 40));
}

test "mover a camada leva a tinta junto e o clique acompanha" {
    var d = try Documento.criar(testing.allocator, 50, 50, opaco | 0xffffff);
    defer d.destruir();
    try d.adicionar(.desenho, origem);
    d.atual().pincel(10, 10, 10, 10, 0, opaco | 0xff0000);
    d.transformar(Mat3.identidade, Mat3.translacao(20, 5));
    try testing.expectEqual(@as(?usize, 1), d.tocar(Mat3.identidade, 30, 15));
    try testing.expectEqual(@as(?usize, 0), d.tocar(Mat3.identidade, 10, 10));

    var janela = try Tela.criar(testing.allocator, 50, 50, opaco);
    defer janela.destruir();
    d.desenhar(&janela, Mat3.identidade);
    try testing.expectEqual(opaco | 0xff0000, janela.pixels[15 * 50 + 30]);
    try testing.expectEqual(opaco | 0xffffff, janela.pixels[10 * 50 + 10]);
}

test "arrastar na janela com a vista com zoom move a mesma distância na tela" {
    var d = try Documento.criar(testing.allocator, 50, 50, opaco);
    defer d.destruir();
    try d.adicionar(.desenho, origem);
    d.atual().pincel(5, 5, 5, 5, 0, opaco);
    const vista = Mat3.escala(2, 2);
    const antes = d.centroNaJanela(vista);
    d.transformar(vista, Mat3.translacao(10, 0));
    const depois = d.centroNaJanela(vista);
    try testing.expectApproxEqAbs(antes.x + 10, depois.x, 1e-3);
}

test "ordem das camadas: subir, descer e apagar" {
    var d = try Documento.criar(testing.allocator, 8, 8, opaco);
    defer d.destruir();
    try d.adicionar(.desenho, origem);
    try d.adicionar(.desenho, origem);
    d.atual().pincel(1, 1, 1, 1, 0, opaco | 0xabcdef);
    d.mover(-1);
    try testing.expectEqual(@as(usize, 1), d.selecionada);
    try testing.expect(d.atual().temTinta(1, 1));
    d.apagar();
    try testing.expectEqual(@as(usize, 2), d.camadas.items.len);
    d.apagar();
    d.apagar(); // a última não sai
    try testing.expectEqual(@as(usize, 1), d.camadas.items.len);
}

test "modelos viram objetos do próprio tamanho, centrados onde pediu" {
    var d = try Documento.criar(testing.allocator, 400, 300, opaco | 0xffffff);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 200, .y = 150 });
    try testing.expectEqualStrings("Retângulo 1", d.atual().nome());
    try testing.expectEqual(@as(u16, 200), d.atual().pixels.largura);
    // O centro do retângulo cai no centro pedido: clicar ali acha ele.
    try testing.expectEqual(@as(?usize, 1), d.tocar(Mat3.identidade, 200, 150));

    try d.adicionar(.elipse, .{ .x = 100, .y = 100 });
    // O canto da caixa da elipse é transparente: o clique passa pro de baixo.
    try testing.expect(!d.atual().temTinta(0, 0));
    try testing.expect(d.atual().temTinta(80, 80));

    try d.adicionar(.texto, .{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u16, 5 * 8 * 3), d.atual().pixels.largura);
    try testing.expectEqualStrings("Texto 3", d.atual().nome());
    try testing.expectError(error.AindaNaoTem, d.adicionar(.imagem, origem));
}

test "mudar a cor gera de novo com a cor nova" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 50, .y = 50 });
    try d.atual().mudarCor(opaco | 0x123456);
    try testing.expectEqual(opaco | 0x123456, d.atual().pixels.pixels[0]);
    try testing.expectEqual(@as(?Cor, opaco | 0x123456), d.atual().cor());
}

test "inserir e apagar no texto respeitam UTF-8" {
    var t: Texto = .{ .cor = 0 };
    t.trocar("S");
    t.inserir('ã');
    t.inserir('o');
    try testing.expectEqualStrings("São", t.conteudo());
    t.apagarUltimo();
    t.apagarUltimo();
    try testing.expectEqualStrings("S", t.conteudo());
}

test "mudar um parâmetro e gerar de novo muda os pixels" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    try d.adicionar(.texto, origem);
    d.atual().modelo.texto.trocar("Oi");
    try d.atual().gerar();
    try testing.expectEqual(@as(u16, 2 * 8 * 3), d.atual().pixels.largura);
}
