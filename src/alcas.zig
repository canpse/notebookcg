//! Alças de transformação na caixa do objeto selecionado: mexer direto com
//! o mouse em vez de atalho.
//!
//! - cantos: escala proporcional, com o canto oposto parado
//! - meio dos lados: estica só naquela direção, com o lado oposto parado
//! - bolinha acima da caixa: gira em torno do centro (Shift: de 15 em 15°)
//!
//! A escala acontece nas coordenadas da CAMADA (antes da matriz dela), por
//! isso esticar um objeto girado estica ao longo dele, não da tela:
//!     nova = matriz · T(âncora) · S · T(−âncora)
//! O giro acontece na janela, em torno do centro do objeto na tela:
//!     nova = vista⁻¹ · R(centro) · vista · matriz
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const opaco = tela_.opaco;
const m3 = @import("mat3.zig");
const Mat3 = m3.Mat3;
const Ponto = m3.Ponto;
const Camada = @import("camada.zig").Camada;

pub const Alca = enum { canto_no, canto_ne, canto_se, canto_so, lado_n, lado_l, lado_s, lado_o, girar };

const folga = 4; // a caixa fica 4 px pra fora do conteúdo (a mesma de Camada.cantos)
const raio_toque = 8;
const distancia_giro = 26;

const cor_linha = opaco | 0x2f7df6;
const cor_alca = opaco | 0xffffff;
const cor_sobre = opaco | 0xfacc15;

/// Caixa do objeto em coordenadas da camada.
const CaixaLocal = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    fn de(c: *const Camada) ?CaixaLocal {
        const k = c.conteudo orelse return null;
        return .{
            .x0 = @floatFromInt(k.x0 - folga),
            .y0 = @floatFromInt(k.y0 - folga),
            .x1 = @floatFromInt(k.x1 + folga),
            .y1 = @floatFromInt(k.y1 + folga),
        };
    }

    fn meioX(b: CaixaLocal) f32 {
        return (b.x0 + b.x1) / 2;
    }
    fn meioY(b: CaixaLocal) f32 {
        return (b.y0 + b.y1) / 2;
    }

    /// Ponto da alça e ponto que fica parado (âncora), na camada.
    fn alcaEAncora(b: CaixaLocal, a: Alca) [2]Ponto {
        const xm = b.meioX();
        const ym = b.meioY();
        return switch (a) {
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
};

/// Onde cada alça aparece na janela.
pub fn pontos(c: *const Camada, vista: Mat3) ?[9]Ponto {
    if (c.travada) return null;
    const b = CaixaLocal.de(c) orelse return null;
    const m = c.naJanela(vista);
    var r: [9]Ponto = undefined;
    inline for (0..8) |i| {
        const p = b.alcaEAncora(@enumFromInt(i))[0];
        r[i] = m.aplicar(p.x, p.y);
    }
    // A de girar fica pra fora do lado de cima, na direção centro → topo
    // (que é o "pra cima" do objeto, mesmo girado).
    const topo = r[@intFromEnum(Alca.lado_n)];
    const centro = m.aplicar(b.meioX(), b.meioY());
    const dx = topo.x - centro.x;
    const dy = topo.y - centro.y;
    const n = @max(1e-3, @sqrt(dx * dx + dy * dy));
    r[@intFromEnum(Alca.girar)] = .{ .x = topo.x + dx / n * distancia_giro, .y = topo.y + dy / n * distancia_giro };
    return r;
}

/// Alça embaixo do ponto (x, y) da janela. A de girar tem prioridade, e os
/// cantos vêm antes dos lados (em objeto pequeno elas ficam pertinho).
pub fn tocar(c: *const Camada, vista: Mat3, x: i32, y: i32) ?Alca {
    const ps = pontos(c, vista) orelse return null;
    const ordem = [_]Alca{ .girar, .canto_no, .canto_ne, .canto_se, .canto_so, .lado_n, .lado_l, .lado_s, .lado_o };
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    for (ordem) |a| {
        const p = ps[@intFromEnum(a)];
        if (@abs(p.x - fx) <= raio_toque and @abs(p.y - fy) <= raio_toque) return a;
    }
    return null;
}

pub const Arrasto = struct {
    alca: Alca,
    /// A matriz da camada quando o arrasto começou: cada movimento recalcula
    /// a partir dela (somar passinhos acumularia erro de arredondamento).
    matriz0: Mat3,
    /// camada → janela no começo (pra levar o mouse pra dentro da camada).
    inversa0: Mat3,
    alca_local: Ponto,
    ancora: Ponto,
    /// Pro giro: centro na janela e ângulo inicial do mouse em volta dele.
    centro: Ponto,
    angulo0: f32,

    pub fn iniciar(c: *const Camada, vista: Mat3, alca: Alca, x: i32, y: i32) ?Arrasto {
        const b = CaixaLocal.de(c) orelse return null;
        const m = c.naJanela(vista);
        const inv = m.inversa() orelse return null;
        const ha = b.alcaEAncora(alca);
        const centro = m.aplicar(b.meioX(), b.meioY());
        return .{
            .alca = alca,
            .matriz0 = c.matriz,
            .inversa0 = inv,
            .alca_local = ha[0],
            .ancora = ha[1],
            .centro = centro,
            .angulo0 = std.math.atan2(@as(f32, @floatFromInt(y)) - centro.y, @as(f32, @floatFromInt(x)) - centro.x),
        };
    }

    pub fn mover(ar: *const Arrasto, c: *Camada, vista: Mat3, x: i32, y: i32, shift: bool) void {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const nova = switch (ar.alca) {
            .girar => blk: {
                var ang = std.math.atan2(fy - ar.centro.y, fx - ar.centro.x) - ar.angulo0;
                if (shift) {
                    const passo = std.math.pi / 12.0;
                    ang = @round(ang / passo) * passo;
                }
                const inv_vista = vista.inversa() orelse return;
                break :blk inv_vista.vezes(Mat3.rotacao(ang).emTornoDe(ar.centro.x, ar.centro.y)).vezes(vista).vezes(ar.matriz0);
            },
            else => blk: {
                // O mouse levado pra dentro da camada (como ela era no começo).
                const p = ar.inversa0.aplicar(fx, fy);
                const hx = ar.alca_local.x - ar.ancora.x;
                const hy = ar.alca_local.y - ar.ancora.y;
                const px = p.x - ar.ancora.x;
                const py = p.y - ar.ancora.y;
                var sx: f32 = 1;
                var sy: f32 = 1;
                switch (ar.alca) {
                    // Canto: projeta o mouse na diagonal âncora → alça; a
                    // mesma escala nos dois eixos mantém a proporção.
                    .canto_no, .canto_ne, .canto_se, .canto_so => {
                        const s = (px * hx + py * hy) / (hx * hx + hy * hy);
                        sx = s;
                        sy = s;
                    },
                    .lado_l, .lado_o => sx = px / hx,
                    .lado_n, .lado_s => sy = py / hy,
                    .girar => unreachable,
                }
                // Nunca zero (sem inversa); negativo espelha, o que é válido.
                sx = minimo(sx);
                sy = minimo(sy);
                break :blk ar.matriz0.vezes(Mat3.escala(sx, sy).emTornoDe(ar.ancora.x, ar.ancora.y));
            },
        };
        if (nova.inversa() != null) c.matriz = nova;
    }
};

fn minimo(s: f32) f32 {
    if (@abs(s) >= 0.02) return s;
    return if (s < 0) -0.02 else 0.02;
}

fn arredondar(v: f32) i32 {
    return @intFromFloat(@round(std.math.clamp(v, -1e5, 1e5)));
}

/// Contorno da caixa, linha até a alça de girar e as alças.
pub fn desenhar(t: *Tela, c: *const Camada, vista: Mat3, sobre: ?Alca) void {
    const ps = pontos(c, vista) orelse return;
    const cantos = [_]Alca{ .canto_no, .canto_ne, .canto_se, .canto_so };
    for (0..4) |i| {
        const a = ps[@intFromEnum(cantos[i])];
        const b = ps[@intFromEnum(cantos[(i + 1) % 4])];
        t.linha(arredondar(a.x), arredondar(a.y), arredondar(b.x), arredondar(b.y), 0, cor_linha);
    }
    const topo = ps[@intFromEnum(Alca.lado_n)];
    const giro = ps[@intFromEnum(Alca.girar)];
    t.linha(arredondar(topo.x), arredondar(topo.y), arredondar(giro.x), arredondar(giro.y), 0, cor_linha);

    for (ps, 0..) |p, i| {
        const a: Alca = @enumFromInt(i);
        const preenchimento = if (sobre == a) cor_sobre else cor_alca;
        const x = arredondar(p.x);
        const y = arredondar(p.y);
        if (a == .girar) {
            t.disco(x, y, 6, cor_linha);
            t.disco(x, y, 4, preenchimento);
        } else {
            t.retangulo(.{ .x0 = x - 5, .y0 = y - 5, .x1 = x + 6, .y1 = y + 6 }, cor_linha);
            t.retangulo(.{ .x0 = x - 4, .y0 = y - 4, .x1 = x + 5, .y1 = y + 5 }, preenchimento);
        }
    }
}

const testing = std.testing;
const Documento = @import("camada.zig").Documento;

fn pertoDe(esperado: Ponto, p: Ponto) !void {
    try testing.expectApproxEqAbs(esperado.x, p.x, 0.05);
    try testing.expectApproxEqAbs(esperado.y, p.y, 0.05);
}

test "arrastar o canto escala proporcional e o canto oposto fica parado" {
    var d = try Documento.criar(testing.allocator, 400, 400, opaco);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 100, .y = 100 });
    const c = d.atual();
    const v = Mat3.identidade;
    const antes = pontos(c, v).?;
    const se = antes[@intFromEnum(Alca.canto_se)];
    try testing.expectEqual(@as(?Alca, .canto_se), tocar(c, v, arredondar(se.x), arredondar(se.y)));
    const ar = Arrasto.iniciar(c, v, .canto_se, arredondar(se.x), arredondar(se.y)).?;
    // Arrasta o canto pra longe do oposto: a caixa (208×128) dobra.
    const no = antes[@intFromEnum(Alca.canto_no)];
    ar.mover(c, v, arredondar(no.x + 2 * (se.x - no.x)), arredondar(no.y + 2 * (se.y - no.y)), false);
    const depois = pontos(c, v).?;
    try pertoDe(no, depois[@intFromEnum(Alca.canto_no)]);
    try testing.expectApproxEqAbs(2 * (se.x - no.x), depois[@intFromEnum(Alca.canto_se)].x - no.x, 1);
}

test "lado estica só numa direção, ao longo do objeto girado" {
    var d = try Documento.criar(testing.allocator, 400, 400, opaco);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 200, .y = 200 });
    d.transformar(Mat3.identidade, Mat3.rotacao(std.math.pi / 2.0).emTornoDe(200, 200));
    const c = d.atual();
    const v = Mat3.identidade;
    const antes = pontos(c, v).?;
    const l = antes[@intFromEnum(Alca.lado_l)];
    const o = antes[@intFromEnum(Alca.lado_o)];
    // Girado 90°: o lado "leste" do objeto aponta pra baixo na tela.
    try testing.expect(l.y > o.y + 100);
    const ar = Arrasto.iniciar(c, v, .lado_l, arredondar(l.x), arredondar(l.y)).?;
    ar.mover(c, v, arredondar(l.x), arredondar(l.y + 50), false);
    const depois = pontos(c, v).?;
    try pertoDe(o, depois[@intFromEnum(Alca.lado_o)]); // lado oposto parado
    try testing.expectApproxEqAbs(l.y + 50, depois[@intFromEnum(Alca.lado_l)].y, 1);
    // A altura do objeto (largura na tela agora) não mudou.
    const n0 = antes[@intFromEnum(Alca.lado_n)];
    const s0 = antes[@intFromEnum(Alca.lado_s)];
    const n1 = depois[@intFromEnum(Alca.lado_n)];
    const s1 = depois[@intFromEnum(Alca.lado_s)];
    try testing.expectApproxEqAbs(@abs(n0.x - s0.x), @abs(n1.x - s1.x), 0.05);
}

test "girar pela alça: com shift, de 15 em 15 graus; o centro fica parado" {
    var d = try Documento.criar(testing.allocator, 400, 400, opaco);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 200, .y = 200 });
    const c = d.atual();
    const v = Mat3.identidade;
    const g = pontos(c, v).?[@intFromEnum(Alca.girar)];
    const ar = Arrasto.iniciar(c, v, .girar, arredondar(g.x), arredondar(g.y)).?;
    // Mouse um pouco à direita do centro: perto de 80°, com shift vira 75°.
    ar.mover(c, v, 300, 185, true);
    const m = c.matriz.m;
    try testing.expectApproxEqAbs(@cos(@as(f32, 75.0 * std.math.pi / 180.0)), m[0][0], 1e-3);
    const centro = c.naJanela(v).aplicar(100, 60);
    try pertoDe(.{ .x = 200, .y = 200 }, centro);
}
