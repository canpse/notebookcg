//! Alças de transformação na caixa da seleção: mexer direto com o mouse.
//!
//! - cantos: escala proporcional, com o canto oposto parado (Shift: livre)
//! - meio dos lados: estica só naquela direção, com o lado oposto parado
//! - bolinha acima da caixa: gira em torno do centro (Shift: de 15 em 15°)
//!
//! A caixa tem um REFERENCIAL: a matriz `m` que leva das coordenadas dela
//! pra tela. Com um objeto só, é a do próprio objeto (vista · matriz), e a
//! caixa gira junto com ele; esticar um objeto girado estica ao longo dele.
//! Com vários, é a identidade e a caixa fica alinhada com a tela.
//!
//! O arrasto calcula a transformação g no referencial da caixa e leva pra
//! tela:   g_tela = m · g · m⁻¹
//! e cada objeto selecionado recebe g_tela (ver `Documento.arrastar`).
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const opaco = tela_.opaco;
const m3 = @import("mat3.zig");
const Mat3 = m3.Mat3;
const Ponto = m3.Ponto;
const camada = @import("camada.zig");
const Documento = camada.Documento;
const Retangulo = camada.Retangulo;

pub const Alca = enum { canto_no, canto_ne, canto_se, canto_so, lado_n, lado_l, lado_s, lado_o, girar };

const folga = 6; // a caixa fica uns pixels pra fora do objeto
const raio_toque = 8;
const distancia_giro = 26;

const cor_linha = opaco | 0x2f7df6;
const cor_alca = opaco | 0xffffff;
const cor_sobre = opaco | 0xfacc15;

/// A caixa da seleção e o referencial dela.
pub const Alvo = struct {
    m: Mat3,
    caixa: Retangulo,
    /// Moldura não gira (o recorte sai sempre reto).
    gira: bool = true,

    pub fn de(d: *Documento, vista: Mat3) ?Alvo {
        if (d.unica()) |c| {
            const m = vista.vezes(c.matriz);
            const s = @max(m.fator(), 1e-6);
            return .{ .m = m, .caixa = c.caixa(d.imagens.items).crescer(folga / s), .gira = c.modelo != .moldura };
        }
        const r = d.caixaSelecao(vista) orelse return null;
        return .{ .m = Mat3.identidade, .caixa = r.crescer(folga) };
    }

    fn meioX(a: Alvo) f32 {
        return (a.caixa.x0 + a.caixa.x1) / 2;
    }
    fn meioY(a: Alvo) f32 {
        return (a.caixa.y0 + a.caixa.y1) / 2;
    }

    /// Ponto da alça e ponto que fica parado (âncora), no referencial.
    fn alcaEAncora(a: Alvo, alca: Alca) [2]Ponto {
        const b = a.caixa;
        const xm = a.meioX();
        const ym = a.meioY();
        return switch (alca) {
            .canto_no => .{ .{ .x = b.x0, .y = b.y0 }, .{ .x = b.x1, .y = b.y1 } },
            .canto_ne => .{ .{ .x = b.x1, .y = b.y0 }, .{ .x = b.x0, .y = b.y1 } },
            .canto_se => .{ .{ .x = b.x1, .y = b.y1 }, .{ .x = b.x0, .y = b.y0 } },
            .canto_so => .{ .{ .x = b.x0, .y = b.y1 }, .{ .x = b.x1, .y = b.y0 } },
            .lado_n => .{ .{ .x = xm, .y = b.y0 }, .{ .x = xm, .y = b.y1 } },
            .lado_s => .{ .{ .x = xm, .y = b.y1 }, .{ .x = xm, .y = b.y0 } },
            .lado_l => .{ .{ .x = b.x1, .y = ym }, .{ .x = b.x0, .y = ym } },
            .lado_o => .{ .{ .x = b.x0, .y = ym }, .{ .x = b.x1, .y = ym } },
            .girar => .{ .{ .x = xm, .y = b.y0 }, .{ .x = xm, .y = ym } },
        };
    }

    /// Onde cada alça aparece na tela.
    pub fn pontos(a: Alvo) [9]Ponto {
        var r: [9]Ponto = undefined;
        inline for (0..8) |i| {
            const p = a.alcaEAncora(@enumFromInt(i))[0];
            r[i] = a.m.aplicar(p.x, p.y);
        }
        // A de girar fica pra fora do lado de cima, na direção centro → topo
        // (que é o "pra cima" do objeto, mesmo girado).
        const topo = r[@intFromEnum(Alca.lado_n)];
        const centro = a.m.aplicar(a.meioX(), a.meioY());
        const dx = topo.x - centro.x;
        const dy = topo.y - centro.y;
        const n = @max(1e-3, @sqrt(dx * dx + dy * dy));
        r[@intFromEnum(Alca.girar)] = .{ .x = topo.x + dx / n * distancia_giro, .y = topo.y + dy / n * distancia_giro };
        return r;
    }

    /// Alça embaixo do ponto (x, y) da tela. A de girar tem prioridade, e os
    /// cantos vêm antes dos lados (em objeto pequeno elas ficam pertinho).
    pub fn tocar(a: Alvo, x: i32, y: i32) ?Alca {
        const ps = a.pontos();
        const ordem = [_]Alca{ .girar, .canto_no, .canto_ne, .canto_se, .canto_so, .lado_n, .lado_l, .lado_s, .lado_o };
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        for (ordem) |al| {
            if (al == .girar and !a.gira) continue;
            const p = ps[@intFromEnum(al)];
            if (@abs(p.x - fx) <= raio_toque and @abs(p.y - fy) <= raio_toque) return al;
        }
        return null;
    }

    /// O ponto (x, y) da tela cai dentro da caixa?
    pub fn dentro(a: Alvo, x: i32, y: i32) bool {
        const inv = a.m.inversa() orelse return false;
        const p = inv.aplicar(@floatFromInt(x), @floatFromInt(y));
        return a.caixa.contem(p.x, p.y);
    }
};

pub const Arrasto = struct {
    alca: Alca,
    alvo: Alvo,
    inversa: Mat3,
    alca_local: Ponto,
    ancora: Ponto,
    /// Pro giro: centro na tela e ângulo inicial do mouse em volta dele.
    centro: Ponto,
    angulo0: f32,

    pub fn iniciar(d: *Documento, alvo: Alvo, alca: Alca, x: i32, y: i32) ?Arrasto {
        const inv = alvo.m.inversa() orelse return null;
        const ha = alvo.alcaEAncora(alca);
        const centro = alvo.m.aplicar(alvo.meioX(), alvo.meioY());
        d.iniciarArrasto();
        return .{
            .alca = alca,
            .alvo = alvo,
            .inversa = inv,
            .alca_local = ha[0],
            .ancora = ha[1],
            .centro = centro,
            .angulo0 = std.math.atan2(@as(f32, @floatFromInt(y)) - centro.y, @as(f32, @floatFromInt(x)) - centro.x),
        };
    }

    /// A transformação, na tela, que leva a seleção de como estava no começo
    /// pra onde o mouse está agora.
    pub fn naTela(ar: *const Arrasto, x: i32, y: i32, shift: bool) Mat3 {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        if (ar.alca == .girar) {
            var ang = std.math.atan2(fy - ar.centro.y, fx - ar.centro.x) - ar.angulo0;
            if (shift) {
                const passo = std.math.pi / 12.0;
                ang = @round(ang / passo) * passo;
            }
            return Mat3.rotacao(ang).emTornoDe(ar.centro.x, ar.centro.y);
        }
        // O mouse levado pro referencial da caixa (como era no começo).
        const p = ar.inversa.aplicar(fx, fy);
        const hx = ar.alca_local.x - ar.ancora.x;
        const hy = ar.alca_local.y - ar.ancora.y;
        const px = p.x - ar.ancora.x;
        const py = p.y - ar.ancora.y;
        var sx: f32 = 1;
        var sy: f32 = 1;
        switch (ar.alca) {
            // Canto: projeta o mouse na diagonal âncora → alça; a mesma
            // escala nos dois eixos mantém a proporção. Com Shift, livre.
            .canto_no, .canto_ne, .canto_se, .canto_so => if (shift) {
                sx = px / hx;
                sy = py / hy;
            } else {
                const s = (px * hx + py * hy) / (hx * hx + hy * hy);
                sx = s;
                sy = s;
            },
            .lado_l, .lado_o => sx = px / hx,
            .lado_n, .lado_s => sy = py / hy,
            .girar => unreachable,
        }
        // Nunca zero (sem inversa); negativo espelha, o que é válido.
        const g = Mat3.escala(minimo(sx), minimo(sy)).emTornoDe(ar.ancora.x, ar.ancora.y);
        return ar.alvo.m.vezes(g).vezes(ar.inversa);
    }

    pub fn mover(ar: *const Arrasto, d: *Documento, vista: Mat3, x: i32, y: i32, shift: bool) void {
        d.arrastar(vista, ar.naTela(x, y, shift));
    }
};

fn minimo(s: f32) f32 {
    if (!std.math.isFinite(s)) return 1;
    if (@abs(s) >= 0.02) return s;
    return if (s < 0) -0.02 else 0.02;
}

fn arredondar(v: f32) i32 {
    return @intFromFloat(@round(std.math.clamp(v, -1e5, 1e5)));
}

/// Contorno da caixa, linha até a alça de girar e as alças.
pub fn desenhar(t: *Tela, a: Alvo, sobre: ?Alca) void {
    const ps = a.pontos();
    const cantos = [_]Alca{ .canto_no, .canto_ne, .canto_se, .canto_so };
    for (0..4) |i| {
        const p = ps[@intFromEnum(cantos[i])];
        const q = ps[@intFromEnum(cantos[(i + 1) % 4])];
        t.linha(arredondar(p.x), arredondar(p.y), arredondar(q.x), arredondar(q.y), 0, cor_linha);
    }
    if (a.gira) {
        const topo = ps[@intFromEnum(Alca.lado_n)];
        const giro = ps[@intFromEnum(Alca.girar)];
        t.linha(arredondar(topo.x), arredondar(topo.y), arredondar(giro.x), arredondar(giro.y), 0, cor_linha);
    }
    for (ps, 0..) |p, i| {
        const al: Alca = @enumFromInt(i);
        if (al == .girar and !a.gira) continue;
        const preenchimento = if (sobre == al) cor_sobre else cor_alca;
        const x = arredondar(p.x);
        const y = arredondar(p.y);
        if (al == .girar) {
            t.disco(x, y, 6, cor_linha);
            t.disco(x, y, 4, preenchimento);
        } else {
            t.retangulo(.{ .x0 = x - 5, .y0 = y - 5, .x1 = x + 6, .y1 = y + 6 }, cor_linha);
            t.retangulo(.{ .x0 = x - 4, .y0 = y - 4, .x1 = x + 5, .y1 = y + 5 }, preenchimento);
        }
    }
}

const testing = std.testing;

fn pertoDe(esperado: Ponto, p: Ponto) !void {
    try testing.expectApproxEqAbs(esperado.x, p.x, 0.05);
    try testing.expectApproxEqAbs(esperado.y, p.y, 0.05);
}

fn retangulo(d: *Documento, x: f32, y: f32) !void {
    _ = try d.adicionar(.{ .modelo = .{ .retangulo = .{ .largura = 200, .altura = 120, .cor = opaco, .espessura = 0 } }, .matriz = Mat3.translacao(x, y) });
}

test "arrastar o canto escala proporcional e o canto oposto fica parado" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    try retangulo(&d, 0, 0);
    const v = Mat3.identidade;
    const alvo = Alvo.de(&d, v).?;
    const antes = alvo.pontos();
    const se = antes[@intFromEnum(Alca.canto_se)];
    const no = antes[@intFromEnum(Alca.canto_no)];
    try testing.expectEqual(@as(?Alca, .canto_se), alvo.tocar(arredondar(se.x), arredondar(se.y)));
    const ar = Arrasto.iniciar(&d, alvo, .canto_se, arredondar(se.x), arredondar(se.y)).?;
    ar.mover(&d, v, arredondar(no.x + 2 * (se.x - no.x)), arredondar(no.y + 2 * (se.y - no.y)), false);
    const depois = Alvo.de(&d, v).?.pontos();
    // (a folga da caixa é em pixels, por isso a tolerância)
    try testing.expectApproxEqAbs(no.x, depois[@intFromEnum(Alca.canto_no)].x, 8);
    try testing.expectApproxEqAbs(2 * (se.x - no.x), depois[@intFromEnum(Alca.canto_se)].x - no.x, 12);
}

test "lado estica só numa direção, ao longo do objeto girado" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    try retangulo(&d, 100, 140);
    d.transformar(Mat3.identidade, Mat3.rotacao(std.math.pi / 2.0).emTornoDe(200, 200));
    const v = Mat3.identidade;
    const alvo = Alvo.de(&d, v).?;
    const antes = alvo.pontos();
    const l = antes[@intFromEnum(Alca.lado_l)];
    const o = antes[@intFromEnum(Alca.lado_o)];
    // Girado 90°: o lado "leste" do objeto aponta pra baixo na tela.
    try testing.expect(l.y > o.y + 100);
    const ar = Arrasto.iniciar(&d, alvo, .lado_l, arredondar(l.x), arredondar(l.y)).?;
    ar.mover(&d, v, arredondar(l.x), arredondar(l.y + 50), false);
    const c = d.unica().?;
    // A largura do objeto (altura na tela) cresceu; a altura não mudou.
    const m = c.matriz.m;
    try testing.expectApproxEqAbs(@as(f32, 1), @sqrt(m[0][1] * m[0][1] + m[1][1] * m[1][1]), 1e-3);
    try testing.expect(@sqrt(m[0][0] * m[0][0] + m[1][0] * m[1][0]) > 1.2);
}

test "girar pela alça: com shift, de 15 em 15 graus; o centro fica parado" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    try retangulo(&d, 100, 140);
    const v = Mat3.identidade;
    const alvo = Alvo.de(&d, v).?;
    const g = alvo.pontos()[@intFromEnum(Alca.girar)];
    const ar = Arrasto.iniciar(&d, alvo, .girar, arredondar(g.x), arredondar(g.y)).?;
    // Mouse um pouco à direita do centro: perto de 80°, com shift vira 75°.
    ar.mover(&d, v, 300, 185, true);
    const m = d.unica().?.matriz;
    try testing.expectApproxEqAbs(@cos(@as(f32, 75.0 * std.math.pi / 180.0)), m.m[0][0], 1e-3);
    try pertoDe(.{ .x = 200, .y = 200 }, m.aplicar(100, 60));
}

test "com dois selecionados a caixa é a da tela e escala os dois" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    try retangulo(&d, 0, 0);
    try retangulo(&d, 300, 0);
    d.selecionarTudo();
    const v = Mat3.identidade;
    const alvo = Alvo.de(&d, v).?;
    try testing.expectEqual(Mat3.identidade, alvo.m);
    // Lado esquerdo parado em x = -6 (a folga); puxa o direito de 506 pra
    // 1018: tudo dobra a partir de -6, e o segundo vai de 300 pra 606.
    const ar = Arrasto.iniciar(&d, alvo, .lado_l, 506, 60).?;
    ar.mover(&d, v, 1018, 60, false);
    try testing.expectApproxEqAbs(@as(f32, 606), d.camadas.items[1].matriz.aplicar(0, 0).x, 0.5);
}
