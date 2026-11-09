//! Camadas: cada uma é um objeto com os próprios pixels (com transparência)
//! e a própria matriz, que leva da camada pra folha. Mover, girar ou
//! escalar uma camada é só trocar a matriz dela; os pixels não mudam, então
//! dá pra girar e voltar sem perder qualidade.
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
const m3 = @import("mat3.zig");
const Mat3 = m3.Mat3;
const Ponto = m3.Ponto;

pub const Camada = struct {
    pixels: Tela,
    /// camada → folha
    matriz: Mat3 = Mat3.identidade,
    /// Onde tem tinta, em pixels da camada (null = vazia). Serve pra
    /// desenhar só essa parte, pro contorno da seleção e pro centro do giro.
    conteudo: ?Caixa = null,

    /// camada → janela
    pub fn naJanela(c: *const Camada, vista: Mat3) Mat3 {
        return vista.vezes(c.matriz);
    }

    /// Traço de pincel em coordenadas da camada.
    pub fn pincel(c: *Camada, x0: i32, y0: i32, x1: i32, y1: i32, raio: i32, cor: Cor) void {
        c.pixels.linha(x0, y0, x1, y1, raio, cor);
        const tocado: Caixa = .{ .x0 = @min(x0, x1) - raio, .y0 = @min(y0, y1) - raio, .x1 = @max(x0, x1) + raio + 1, .y1 = @max(y0, y1) + raio + 1 };
        if (tocado.recortar(c.pixels.largura, c.pixels.altura)) |t| c.conteudo = Caixa.unir(c.conteudo, t);
    }

    pub fn limpar(c: *Camada) void {
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

pub const Documento = struct {
    gpa: std.mem.Allocator,
    /// Da de baixo (0, o fundo) pra de cima.
    camadas: std.ArrayList(Camada) = .empty,
    selecionada: usize = 0,
    largura: u16,
    altura: u16,

    /// Documento com uma camada de fundo opaca, já selecionada.
    pub fn criar(gpa: std.mem.Allocator, largura: u16, altura: u16, papel: Cor) !Documento {
        var d: Documento = .{ .gpa = gpa, .largura = largura, .altura = altura };
        errdefer d.destruir();
        try d.camadas.append(gpa, .{
            .pixels = try Tela.criar(gpa, largura, altura, papel),
            .conteudo = .{ .x0 = 0, .y0 = 0, .x1 = largura, .y1 = altura },
        });
        return d;
    }

    pub fn destruir(d: *Documento) void {
        for (d.camadas.items) |*c| c.pixels.destruir();
        d.camadas.deinit(d.gpa);
    }

    pub fn atual(d: *Documento) *Camada {
        return &d.camadas.items[d.selecionada];
    }

    /// Camada transparente nova logo acima da selecionada, e passa a ser ela.
    pub fn novaCamada(d: *Documento) !void {
        var pixels = try Tela.criar(d.gpa, d.largura, d.altura, 0);
        errdefer pixels.destruir();
        try d.camadas.insert(d.gpa, d.selecionada + 1, .{ .pixels = pixels });
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
const opaco = tela_.opaco;

test "clicar seleciona a camada de cima que tem tinta ali" {
    var d = try Documento.criar(testing.allocator, 50, 50, opaco | 0xffffff);
    defer d.destruir();
    try d.novaCamada();
    d.atual().pincel(10, 10, 20, 10, 1, opaco);
    try testing.expectEqual(@as(?usize, 1), d.tocar(Mat3.identidade, 15, 10));
    // Longe do traço só tem o fundo.
    try testing.expectEqual(@as(?usize, 0), d.tocar(Mat3.identidade, 40, 40));
}

test "mover a camada leva a tinta junto e o clique acompanha" {
    var d = try Documento.criar(testing.allocator, 50, 50, opaco | 0xffffff);
    defer d.destruir();
    try d.novaCamada();
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
    try d.novaCamada();
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
    try d.novaCamada();
    try d.novaCamada();
    d.atual().pincel(1, 1, 1, 1, 0, opaco | 0xabcdef);
    d.mover(-1);
    try testing.expectEqual(@as(usize, 1), d.selecionada);
    try testing.expect(d.atual().temTinta(1, 1));
    d.apagar();
    try testing.expectEqual(@as(usize, 2), d.camadas.items.len);
    d.apagar();
    d.apagar(); // o fundo sozinho não sai
    try testing.expectEqual(@as(usize, 1), d.camadas.items.len);
}
