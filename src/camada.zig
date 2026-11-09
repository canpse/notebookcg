//! O quadro: um campo sem borda onde cada coisa desenhada é um objeto
//! (camada) feito de um MODELO (o que ela é: traço, retângulo, texto...)
//! com os parâmetros dele, mais uma matriz que leva da camada pro mundo.
//!
//! O modelo é a descrição; a imagem é gerada a partir dele na hora de
//! pintar, já na resolução de quem vai ver (modelo → imagem, a definição de
//! computação gráfica). Por isso o traço continua liso com zoom de 10× e o
//! recorte sai nítido em 4×: não existe "pixel do traço" guardado, existe
//! uma lista de pontos que é pintada de novo em cada escala.
//!
//! Na tela, cada objeto passa por duas matrizes: camada → mundo (a dele) e
//! mundo → janela (a vista). Os objetos são pintados de baixo pra cima,
//! cada um por cima do anterior: o algoritmo do pintor.
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
    linha,
    seta,
    retangulo,
    elipse,
    texto,
    imagem,
    moldura,

    pub fn nome(t: Tipo) []const u8 {
        return switch (t) {
            .desenho => "Desenho",
            .linha => "Linha",
            .seta => "Seta",
            .retangulo => "Retângulo",
            .elipse => "Elipse",
            .texto => "Texto",
            .imagem => "Imagem",
            .moldura => "Moldura",
        };
    }
};

/// Retângulo com lados em ponto flutuante (no mundo, na camada ou na tela).
pub const Retangulo = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    pub fn unir(a: ?Retangulo, b: Retangulo) Retangulo {
        const c = a orelse return b;
        return .{ .x0 = @min(c.x0, b.x0), .y0 = @min(c.y0, b.y0), .x1 = @max(c.x1, b.x1), .y1 = @max(c.y1, b.y1) };
    }

    pub fn contem(r: Retangulo, x: f32, y: f32) bool {
        return x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1;
    }

    pub fn dentroDe(r: Retangulo, fora: Retangulo) bool {
        return r.x0 >= fora.x0 and r.y0 >= fora.y0 and r.x1 <= fora.x1 and r.y1 <= fora.y1;
    }

    pub fn crescer(r: Retangulo, f: f32) Retangulo {
        return .{ .x0 = r.x0 - f, .y0 = r.y0 - f, .x1 = r.x1 + f, .y1 = r.y1 + f };
    }

    pub fn largura(r: Retangulo) f32 {
        return r.x1 - r.x0;
    }
    pub fn altura(r: Retangulo) f32 {
        return r.y1 - r.y0;
    }

    /// Caixa (alinhada) que contém este retângulo depois de transformado.
    pub fn transformado(r: Retangulo, m: Mat3) Retangulo {
        const cs = [_]Ponto{ m.aplicar(r.x0, r.y0), m.aplicar(r.x1, r.y0), m.aplicar(r.x1, r.y1), m.aplicar(r.x0, r.y1) };
        var s: Retangulo = .{ .x0 = cs[0].x, .y0 = cs[0].y, .x1 = cs[0].x, .y1 = cs[0].y };
        for (cs[1..]) |p| s = unir(s, .{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y });
        return s;
    }

    /// Em pixels inteiros, com 1 de folga pra borda suave.
    pub fn emPixels(r: Retangulo) Caixa {
        return .{ .x0 = tela_.paraInt(r.x0) - 1, .y0 = tela_.paraInt(r.y0) - 1, .x1 = tela_.paraInt(r.x1) + 2, .y1 = tela_.paraInt(r.y1) + 2 };
    }
};

/// Traço do pincel, linha ou seta: os pontos por onde passa.
pub const Traco = struct {
    pontos: std.ArrayList(Ponto) = .empty,
    cor: Cor,
    espessura: f32,
    /// Estilo "à mão" (só linha e seta; o pincel já é à mão).
    mao: bool = false,
    /// Escolhe o tremido: o mesmo objeto treme sempre igual.
    semente: u32 = 0,

    /// Suavização de Chaikin ("cortar os cantos"): cada segmento p–q vira
    /// dois pontos, a 1/4 e a 3/4 dele. Repetindo, a linha quebrada que o
    /// mouse deixou converge pra uma curva lisa (uma B-spline quadrática).
    /// As pontas ficam onde estavam.
    pub fn suavizar(t: *Traco, gpa: std.mem.Allocator, vezes: usize) !void {
        for (0..vezes) |_| {
            const p = t.pontos.items;
            if (p.len < 3) return;
            var novo: std.ArrayList(Ponto) = .empty;
            errdefer novo.deinit(gpa);
            try novo.ensureTotalCapacity(gpa, 2 * p.len);
            novo.appendAssumeCapacity(p[0]);
            for (p[0 .. p.len - 1], p[1..]) |a, b| {
                novo.appendAssumeCapacity(.{ .x = 0.75 * a.x + 0.25 * b.x, .y = 0.75 * a.y + 0.25 * b.y });
                novo.appendAssumeCapacity(.{ .x = 0.25 * a.x + 0.75 * b.x, .y = 0.25 * a.y + 0.75 * b.y });
            }
            novo.appendAssumeCapacity(p[p.len - 1]);
            t.pontos.deinit(gpa);
            t.pontos = novo;
        }
    }
};

pub const Forma = struct {
    largura: f32,
    altura: f32,
    /// Cor do contorno.
    cor: Cor,
    /// Cor de dentro; null = vazado.
    fundo: ?Cor = null,
    /// Grossura do contorno; 0 = sem contorno.
    espessura: f32,
    mao: bool = false,
    semente: u32 = 0,
};

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

/// Região do quadro que vira imagem com um clique (e de novo depois, se o
/// desenho mudar). Não aparece no recorte, só na tela.
pub const Moldura = struct {
    largura: f32,
    altura: f32,
    numero: u32,
    /// Pixels de saída por unidade do mundo: 2 = o dobro da tela em zoom 1.
    escala: u8 = 2,
};

pub const Modelo = union(Tipo) {
    desenho: Traco,
    linha: Traco,
    seta: Traco,
    retangulo: Forma,
    elipse: Forma,
    texto: Texto,
    /// Índice em `Documento.imagens` (os pixels são grandes e nunca mudam:
    /// ficam num lugar só, e desfazer não precisa copiar).
    imagem: u32,
    moldura: Moldura,
};

pub const Imagem = struct {
    pixels: Tela,
    /// De onde veio, relativo à pasta (pra salvar o quadro).
    caminho: []u8,
};

/// Como os objetos novos nascem (e o que o painel mostra marcado).
pub const Estilo = struct {
    cor: Cor = opaco | 0x1d1d1f,
    fundo: ?Cor = null,
    espessura: f32 = 3,
    tamanho: u8 = 3,
    mao: bool = false,
};

/// Qual propriedade do estilo mudar nos selecionados.
pub const Propriedade = enum { cor, fundo, espessura, tamanho, mao };

const tolerancia_toque = 5; // pixels de tela

pub const Camada = struct {
    modelo: Modelo,
    /// camada → mundo
    matriz: Mat3 = Mat3.identidade,
    /// A matriz quando o arrasto começou: cada passo do arrasto recalcula a
    /// partir dela (somar passinhos acumularia erro de arredondamento).
    matriz0: Mat3 = Mat3.identidade,
    nome_buf: [32]u8 = undefined,
    nome_len: u8 = 0,
    selecionada: bool = false,
    /// Objetos com o mesmo grupo (≠ 0) são selecionados juntos.
    grupo: u32 = 0,
    /// Pixels do texto (a fonte é bitmap, então o texto vira imagem).
    cache: ?Tela = null,

    pub fn nome(c: *const Camada) []const u8 {
        return c.nome_buf[0..c.nome_len];
    }

    pub fn batizar(c: *Camada, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&c.nome_buf, fmt, args) catch c.nome_buf[0..];
        c.nome_len = @intCast(s.len);
    }

    pub fn liberar(c: *Camada, gpa: std.mem.Allocator) void {
        if (c.traco()) |t| t.pontos.deinit(gpa);
        if (c.cache) |*t| t.destruir();
        c.cache = null;
    }

    /// Cópia independente (os pontos do traço são copiados).
    pub fn clonar(c: *const Camada, gpa: std.mem.Allocator) !Camada {
        var n = c.*;
        n.cache = null;
        switch (n.modelo) {
            .desenho, .linha, .seta => |*t| {
                t.pontos = .empty;
                try t.pontos.appendSlice(gpa, c.tracoConst().?.pontos.items);
            },
            else => {},
        }
        errdefer n.liberar(gpa);
        try n.gerar(gpa);
        return n;
    }

    pub fn traco(c: *Camada) ?*Traco {
        return switch (c.modelo) {
            .desenho, .linha, .seta => |*t| t,
            else => null,
        };
    }

    fn tracoConst(c: *const Camada) ?*const Traco {
        return switch (c.modelo) {
            .desenho, .linha, .seta => |*t| t,
            else => null,
        };
    }

    /// Gera o que precisa ser gerado a partir do modelo: só o texto, que
    /// vira pixels da fonte. O resto é pintado direto do modelo.
    pub fn gerar(c: *Camada, gpa: std.mem.Allocator) !void {
        const tx = switch (c.modelo) {
            .texto => |*t| t,
            else => return,
        };
        const s = tx.conteudo();
        const esc: i32 = tx.escala;
        const l: u16 = @intCast(@max(1, fonte.medir(s, esc)));
        var t = try Tela.criar(gpa, l, @intCast(fonte.altura * esc), 0);
        _ = fonte.escrever(&t, 0, 0, s, tx.cor, esc);
        if (c.cache) |*velho| velho.destruir();
        c.cache = t;
    }

    /// O valor de cada propriedade no objeto (null = não tem).
    pub fn cor(c: *const Camada) ?Cor {
        return switch (c.modelo) {
            .desenho, .linha, .seta => |t| t.cor,
            .retangulo, .elipse => |f| f.cor,
            .texto => |t| t.cor,
            .imagem, .moldura => null,
        };
    }

    pub fn temFundo(c: *const Camada) bool {
        return c.modelo == .retangulo or c.modelo == .elipse;
    }

    /// À mão? (null = o objeto não tem essa opção)
    pub fn aMao(c: *const Camada) ?bool {
        return switch (c.modelo) {
            .linha, .seta => |t| t.mao,
            .retangulo, .elipse => |f| f.mao,
            else => null,
        };
    }

    pub fn espessura(c: *const Camada) ?f32 {
        return switch (c.modelo) {
            .desenho, .linha, .seta => |t| t.espessura,
            .retangulo, .elipse => |f| f.espessura,
            else => null,
        };
    }

    /// Muda uma propriedade (se o objeto tiver) e gera de novo.
    pub fn aplicar(c: *Camada, gpa: std.mem.Allocator, p: Propriedade, e: Estilo) !void {
        switch (c.modelo) {
            .desenho, .linha, .seta => |*t| switch (p) {
                .cor => t.cor = e.cor,
                .espessura => t.espessura = e.espessura,
                .mao => t.mao = e.mao,
                else => {},
            },
            .retangulo, .elipse => |*f| switch (p) {
                .cor => f.cor = e.cor,
                .fundo => f.fundo = e.fundo,
                .espessura => f.espessura = e.espessura,
                .mao => f.mao = e.mao,
                else => {},
            },
            .texto => |*t| switch (p) {
                .cor => t.cor = e.cor,
                .tamanho => t.escala = e.tamanho,
                else => {},
            },
            .imagem, .moldura => {},
        }
        try c.gerar(gpa);
    }

    /// Caixa do objeto nas coordenadas dele (antes da matriz).
    pub fn caixa(c: *const Camada, imagens: []const Imagem) Retangulo {
        return switch (c.modelo) {
            .desenho, .linha, .seta => |t| blk: {
                const p = t.pontos.items;
                if (p.len == 0) break :blk .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
                var r: Retangulo = .{ .x0 = p[0].x, .y0 = p[0].y, .x1 = p[0].x, .y1 = p[0].y };
                for (p[1..]) |q| r = Retangulo.unir(r, .{ .x0 = q.x, .y0 = q.y, .x1 = q.x, .y1 = q.y });
                const folga = t.espessura / 2 + (if (c.modelo == .seta) tamanhoPonta(t.espessura) else 0) + (if (t.mao) amplitudeAMao(t.espessura) + 4 else 0);
                break :blk r.crescer(folga);
            },
            .retangulo, .elipse => |f| (Retangulo{ .x0 = 0, .y0 = 0, .x1 = f.largura, .y1 = f.altura }).crescer(f.espessura / 2 + if (f.mao) amplitudeAMao(f.espessura) + 4 else 0),
            .moldura => |m| .{ .x0 = 0, .y0 = 0, .x1 = m.largura, .y1 = m.altura },
            .texto => .{ .x0 = 0, .y0 = 0, .x1 = if (c.cache) |t| @floatFromInt(t.largura) else 1, .y1 = if (c.cache) |t| @floatFromInt(t.altura) else 1 },
            .imagem => |id| blk: {
                const t = &imagens[id].pixels;
                break :blk .{ .x0 = 0, .y0 = 0, .x1 = @floatFromInt(t.largura), .y1 = @floatFromInt(t.altura) };
            },
        };
    }

    /// O ponto (x, y) da tela "pega" no objeto? `m` leva da camada pra tela.
    pub fn toca(c: *const Camada, imagens: []const Imagem, m: Mat3, x: f32, y: f32) bool {
        const inv = m.inversa() orelse return false;
        const s = m.fator();
        const q = inv.aplicar(x, y);
        if (@abs(q.x) > 1e7 or @abs(q.y) > 1e7) return false;
        switch (c.modelo) {
            .desenho, .linha, .seta => |t| {
                const p = t.pontos.items;
                if (p.len == 0) return false;
                const limite = (t.espessura / 2 * s + tolerancia_toque) / s;
                if (p.len == 1) return tela_.distanciaAoSegmento(q.x, q.y, p[0].x, p[0].y, p[0].x, p[0].y) <= limite;
                for (p[0 .. p.len - 1], p[1..]) |a, b| {
                    if (tela_.distanciaAoSegmento(q.x, q.y, a.x, a.y, b.x, b.y) <= limite) return true;
                }
                return false;
            },
            .retangulo, .elipse => |f| {
                const d = distanciaForma(f, c.modelo == .elipse, q.x, q.y) * s;
                if (f.fundo != null and d <= 0) return true;
                return @abs(d) <= f.espessura / 2 * s + tolerancia_toque;
            },
            .moldura => |mo| {
                const d = distanciaRetangulo(mo.largura, mo.altura, q.x, q.y) * s;
                if (@abs(d) <= tolerancia_toque) return true;
                // O nome em cima do canto também pega.
                const canto = m.aplicar(0, 0);
                return x >= canto.x and x <= canto.x + @as(f32, @floatFromInt(fonte.medir(c.nome(), 1))) + 40 and y >= canto.y - fonte.altura - 6 and y <= canto.y;
            },
            .texto, .imagem => return c.caixa(imagens).contem(q.x, q.y),
        }
    }

    /// Pinta o objeto na tela `t`; `m` leva da camada pra tela.
    pub fn desenhar(c: *const Camada, t: *Tela, imagens: []const Imagem, m: Mat3) void {
        const na_tela = c.caixa(imagens).transformado(m);
        // Fora da tela: nem tenta (com quadro grande, é a maior economia).
        if (na_tela.x1 < -2 or na_tela.y1 < -2 or na_tela.x0 > @as(f32, @floatFromInt(t.largura)) + 2 or na_tela.y0 > @as(f32, @floatFromInt(t.altura)) + 2) return;
        switch (c.modelo) {
            .desenho, .linha, .seta => |*tr| desenharTraco(t, tr, c.modelo == .seta, m),
            .retangulo, .elipse => |f| desenharForma(t, f, c.modelo == .elipse, m, na_tela),
            .texto => if (c.cache) |*px| {
                const inv = m.inversa() orelse return;
                t.comporTransformada(px, inv, na_tela.emPixels(), true);
            },
            .imagem => |id| {
                const inv = m.inversa() orelse return;
                t.comporTransformada(&imagens[id].pixels, inv, na_tela.emPixels(), false);
            },
            .moldura => {}, // só na tela, por `desenharMoldura`
        }
    }
};

fn tamanhoPonta(espessura: f32) f32 {
    return @max(12, espessura * 4);
}

/// O traço: cada par de pontos vizinhos é um segmento grosso, todos na
/// mesma máscara e pintados de uma vez (ver `Tela.tracar`).
fn desenharTraco(t: *Tela, tr: *const Traco, seta: bool, m: Mat3) void {
    const p = tr.pontos.items;
    if (p.len == 0) return;
    const r = tr.espessura / 2 * m.fator();
    if (tr.mao and p.len == 2) return desenharTracoAMao(t, tr, seta, m, r);
    var a = m.aplicar(p[0].x, p[0].y);
    t.tracar(a.x, a.y, a.x, a.y, r, tr.cor);
    for (p[1..]) |q| {
        const b = m.aplicar(q.x, q.y);
        t.tracar(a.x, a.y, b.x, b.y, r, tr.cor);
        a = b;
    }
    if (seta and p.len >= 2) {
        // Duas hastes saindo da ponta, a ±27° da direção da linha.
        const fim = p[p.len - 1];
        const antes = p[0];
        const dx = fim.x - antes.x;
        const dy = fim.y - antes.y;
        const l = @sqrt(dx * dx + dy * dy);
        if (l > 0.01) {
            const k = tamanhoPonta(tr.espessura) / l;
            const ponta = m.aplicar(fim.x, fim.y);
            inline for (.{ 0.47, -0.47 }) |ang| {
                const c = @cos(@as(f32, ang));
                const s = @sin(@as(f32, ang));
                const hx = fim.x - k * (c * dx - s * dy);
                const hy = fim.y - k * (s * dx + c * dy);
                const h = m.aplicar(hx, hy);
                t.tracar(ponta.x, ponta.y, h.x, h.y, r, tr.cor);
            }
        }
    }
    t.pintarMascara(tr.cor);
}

// ---------------------------------------------------------------- à mão
//
// O jeito "desenhado à mão": cada linha é traçada DUAS vezes, cada vez um
// pouco torta, e passa um pouquinho das pontas. O torto vem de um ruído
// suave (value noise): números aleatórios em pontos espaçados ao longo da
// linha, ligados por uma curva lisa. A semente fixa os números, então o
// objeto treme sempre igual (não fica dançando a cada quadro).

/// Número "aleatório" entre -1 e 1, sempre o mesmo pra mesma (semente, i).
fn sorteio(semente: u32, i: i32) f32 {
    var h: u32 = semente *% 0x9e3779b1 ^ @as(u32, @bitCast(i)) *% 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h)) / 2147483648.0 - 1;
}

/// Ruído suave: sorteia nos inteiros e liga com uma curva em S.
fn ruido(semente: u32, x: f32) f32 {
    const base = @floor(x);
    const f = x - base;
    const i: i32 = @intFromFloat(std.math.clamp(base, -1e9, 1e9));
    const a = sorteio(semente, i);
    const b = sorteio(semente, i +% 1);
    return a + (b - a) * f * f * (3 - 2 * f);
}

const onda = 50; // unidades entre um sorteio e outro

/// Uma passada torta pelos pontos `base` (na camada): cada ponto anda na
/// direção perpendicular ao caminho conforme o ruído.
fn passadaAMao(t: *Tela, m: Mat3, base: []const Ponto, semente: u32, amplitude: f32, raio: f32, cor: Cor) void {
    if (base.len < 2) return;
    var andado: f32 = 0;
    var anterior: ?Ponto = null;
    for (base, 0..) |p, i| {
        const q = base[@min(i + 1, base.len - 1)];
        const o = base[i -| 1];
        var nx = -(q.y - o.y);
        var ny = q.x - o.x;
        const n = @max(@sqrt(nx * nx + ny * ny), 1e-6);
        nx /= n;
        ny /= n;
        if (i > 0) andado += @sqrt((p.x - o.x) * (p.x - o.x) + (p.y - o.y) * (p.y - o.y));
        const d = amplitude * ruido(semente, andado / onda);
        const atual = m.aplicar(p.x + nx * d, p.y + ny * d);
        if (anterior) |a| t.tracar(a.x, a.y, atual.x, atual.y, raio, cor);
        anterior = atual;
    }
}

/// Linha reta de a até b à mão: duas passadas, passando um pouco das pontas.
fn retaAMao(t: *Tela, m: Mat3, a: Ponto, b: Ponto, semente: u32, amplitude: f32, raio: f32, cor: Cor) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 1e-3) return;
    var buf: [256]Ponto = undefined;
    for (0..2) |passada| {
        const sem = semente +% @as(u32, @intCast(passada)) *% 7919;
        const sobra_ini = (2 + 2 * sorteio(sem, 101)) / l;
        const sobra_fim = (2 + 2 * sorteio(sem, 202)) / l;
        const n: usize = std.math.clamp(@as(usize, @intFromFloat(l / 6)), 2, buf.len);
        for (0..n) |i| {
            const k = -sobra_ini + (1 + sobra_ini + sobra_fim) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
            buf[i] = .{ .x = a.x + dx * k, .y = a.y + dy * k };
        }
        passadaAMao(t, m, buf[0..n], sem, amplitude, raio, cor);
    }
}

fn amplitudeAMao(espessura: f32) f32 {
    return 1.2 + espessura * 0.4;
}

fn desenharTracoAMao(t: *Tela, tr: *const Traco, seta: bool, m: Mat3, r: f32) void {
    const p = tr.pontos.items;
    const amp = amplitudeAMao(tr.espessura);
    retaAMao(t, m, p[0], p[1], tr.semente, amp, r, tr.cor);
    if (seta) {
        const dx = p[1].x - p[0].x;
        const dy = p[1].y - p[0].y;
        const l = @sqrt(dx * dx + dy * dy);
        if (l > 0.01) {
            const k = tamanhoPonta(tr.espessura) / l;
            inline for (.{ 0.47, -0.47 }, 0..) |ang, i| {
                const c = @cos(@as(f32, ang));
                const s = @sin(@as(f32, ang));
                const h: Ponto = .{ .x = p[1].x - k * (c * dx - s * dy), .y = p[1].y - k * (s * dx + c * dy) };
                retaAMao(t, m, p[1], h, tr.semente +% 31 *% @as(u32, i + 1), amp * 0.5, r, tr.cor);
            }
        }
    }
    t.pintarMascara(tr.cor);
}

/// Contorno à mão: no retângulo, cada lado é uma reta à mão (os cantos
/// se cruzam); na elipse, duas voltas tortas que se sobrepõem no fim.
fn contornoAMao(t: *Tela, f: Forma, elipse: bool, m: Mat3) void {
    const r = f.espessura / 2 * m.fator();
    const amp = amplitudeAMao(f.espessura);
    const w = f.largura;
    const h = f.altura;
    if (!elipse) {
        const cs = [_]Ponto{ .{ .x = 0, .y = 0 }, .{ .x = w, .y = 0 }, .{ .x = w, .y = h }, .{ .x = 0, .y = h } };
        for (0..4) |i| retaAMao(t, m, cs[i], cs[(i + 1) % 4], f.semente +% @as(u32, @intCast(i)) *% 104729, amp, r, f.cor);
    } else {
        var buf: [600]Ponto = undefined;
        const perimetro = std.math.pi * (w + h) / 2;
        const n: usize = std.math.clamp(@as(usize, @intFromFloat(perimetro / 5)), 16, buf.len);
        for (0..2) |passada| {
            const sem = f.semente +% @as(u32, @intCast(passada)) *% 7919;
            const inicio = std.math.pi * (1 + sorteio(sem, 5));
            const volta = 2 * std.math.pi + 0.35;
            for (0..n) |i| {
                const ang = inicio + volta * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
                buf[i] = .{ .x = w / 2 + w / 2 * @cos(ang), .y = h / 2 + h / 2 * @sin(ang) };
            }
            passadaAMao(t, m, buf[0..n], sem, amp, r, f.cor);
        }
    }
    t.pintarMascara(f.cor);
}

/// Distância com sinal do ponto à borda do retângulo 0..w × 0..h
/// (negativa dentro). Com ela, "dentro" e "perto da borda" são uma conta só.
fn distanciaRetangulo(w: f32, h: f32, x: f32, y: f32) f32 {
    const qx = @abs(x - w / 2) - w / 2;
    const qy = @abs(y - h / 2) - h / 2;
    const fora = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0));
    return fora + @min(@max(qx, qy), 0);
}

/// Mesma ideia pra elipse inscrita em 0..w × 0..h. A distância exata a uma
/// elipse não tem fórmula fechada; esta aproximação (de Inigo Quilez) é boa
/// perto da borda, que é onde importa.
fn distanciaElipse(w: f32, h: f32, x: f32, y: f32) f32 {
    const a = w / 2;
    const b = h / 2;
    if (a < 0.01 or b < 0.01) return distanciaRetangulo(w, h, x, y);
    const px = x - a;
    const py = y - b;
    const k0 = @sqrt((px / a) * (px / a) + (py / b) * (py / b));
    const k1 = @sqrt((px / (a * a)) * (px / (a * a)) + (py / (b * b)) * (py / (b * b)));
    if (k1 < 1e-6) return -@min(a, b);
    return k0 * (k0 - 1) / k1;
}

fn distanciaForma(f: Forma, elipse: bool, x: f32, y: f32) f32 {
    return if (elipse) distanciaElipse(f.largura, f.altura, x, y) else distanciaRetangulo(f.largura, f.altura, x, y);
}

/// Retângulo e elipse por mapeamento inverso: cada pixel da tela volta pra
/// dentro do objeto e pergunta "a que distância da borda eu estou?".
/// Distância em pixels de tela → quanto o pixel é coberto (borda suave).
fn desenharForma(t: *Tela, f: Forma, elipse: bool, m: Mat3, na_tela: Retangulo) void {
    const inv = m.inversa() orelse return;
    const s = m.fator();
    const meia = f.espessura / 2 * s;
    const c = na_tela.emPixels().recortar(t.largura, t.altura) orelse return;
    var y = c.y0;
    while (y < c.y1) : (y += 1) {
        var x = c.x0;
        while (x < c.x1) : (x += 1) {
            const q = inv.aplicar(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            const d = distanciaForma(f, elipse, q.x, q.y) * s;
            if (f.fundo) |fundo| t.misturar(x, y, fundo, 0.5 - d);
            if (f.espessura > 0 and !f.mao) t.misturar(x, y, f.cor, @max(meia, 0.5) + 0.5 - @abs(d));
        }
    }
    if (f.mao and f.espessura > 0) contornoAMao(t, f, elipse, m);
}

pub const cor_moldura = opaco | 0x6e56cf;

/// Moldura na tela: contorno tracejado e o nome em cima.
pub fn desenharMoldura(t: *Tela, c: *const Camada, m: Mat3) void {
    const mo = c.modelo.moldura;
    const cs = [_]Ponto{ m.aplicar(0, 0), m.aplicar(mo.largura, 0), m.aplicar(mo.largura, mo.altura), m.aplicar(0, mo.altura) };
    for (0..4) |i| {
        const a = cs[i];
        const b = cs[(i + 1) % 4];
        t.tracejada(a.x, a.y, b.x, b.y, 6, cor_moldura);
        t.tracejada(a.x + 0.7, a.y + 0.7, b.x + 0.7, b.y + 0.7, 6, cor_moldura);
    }
    var buf: [48]u8 = undefined;
    const rotulo = std.fmt.bufPrint(&buf, "{s} · {d}×", .{ c.nome(), mo.escala }) catch c.nome();
    _ = fonte.escrever(t, tela_.paraInt(cs[0].x), tela_.paraInt(cs[0].y) - fonte.altura - 4, rotulo, cor_moldura, 1);
}

const Foto = []Camada;
const max_historico = 200;

pub const Documento = struct {
    gpa: std.mem.Allocator,
    /// De baixo pra cima.
    camadas: std.ArrayList(Camada) = .empty,
    imagens: std.ArrayList(Imagem) = .empty,
    /// Quantos objetos e molduras já foram criados (dá o número no nome).
    criados: u32 = 0,
    molduras: u32 = 0,
    grupos: u32 = 0,
    /// Desfazer: fotos do quadro antes de cada mudança. Refazer: as que o
    /// desfazer tirou. Cada foto é uma cópia das camadas; as imagens não
    /// entram (nunca mudam e ficam em `imagens`).
    passado: std.ArrayList(Foto) = .empty,
    futuro: std.ArrayList(Foto) = .empty,

    pub fn criar(gpa: std.mem.Allocator) Documento {
        return .{ .gpa = gpa };
    }

    fn liberarFoto(gpa: std.mem.Allocator, f: Foto) void {
        for (f) |*c| c.liberar(gpa);
        gpa.free(f);
    }

    fn liberarFotos(d: *Documento, l: *std.ArrayList(Foto)) void {
        for (l.items) |f| liberarFoto(d.gpa, f);
        l.clearRetainingCapacity();
    }

    pub fn limpar(d: *Documento) void {
        for (d.camadas.items) |*c| c.liberar(d.gpa);
        d.camadas.clearRetainingCapacity();
        for (d.imagens.items) |*i| {
            i.pixels.destruir();
            d.gpa.free(i.caminho);
        }
        d.imagens.clearRetainingCapacity();
        d.liberarFotos(&d.passado);
        d.liberarFotos(&d.futuro);
        d.criados = 0;
        d.molduras = 0;
        d.grupos = 0;
    }

    pub fn destruir(d: *Documento) void {
        d.limpar();
        d.camadas.deinit(d.gpa);
        d.imagens.deinit(d.gpa);
        d.passado.deinit(d.gpa);
        d.futuro.deinit(d.gpa);
    }

    // ------------------------------------------------------------ desfazer

    fn foto(d: *Documento) !Foto {
        const f = try d.gpa.alloc(Camada, d.camadas.items.len);
        var n: usize = 0;
        errdefer {
            for (f[0..n]) |*c| c.liberar(d.gpa);
            d.gpa.free(f);
        }
        for (d.camadas.items) |*c| {
            f[n] = try c.clonar(d.gpa);
            n += 1;
        }
        return f;
    }

    fn restaurar(d: *Documento, f: Foto) !void {
        var novas: std.ArrayList(Camada) = .empty;
        errdefer {
            for (novas.items) |*c| c.liberar(d.gpa);
            novas.deinit(d.gpa);
        }
        try novas.ensureTotalCapacity(d.gpa, f.len);
        for (f) |*c| novas.appendAssumeCapacity(try c.clonar(d.gpa));
        for (d.camadas.items) |*c| c.liberar(d.gpa);
        d.camadas.deinit(d.gpa);
        d.camadas = novas;
    }

    /// Chamar ANTES de mudar o quadro: guarda como ele está.
    pub fn marcar(d: *Documento) !void {
        const f = try d.foto();
        errdefer liberarFoto(d.gpa, f);
        if (d.passado.items.len == max_historico) liberarFoto(d.gpa, d.passado.orderedRemove(0));
        try d.passado.append(d.gpa, f);
        d.liberarFotos(&d.futuro);
    }

    /// A ação começou mas não mudou nada (ex.: clique sem arrastar): joga
    /// fora a última marca, pra o desfazer não ter passos vazios.
    pub fn desmarcar(d: *Documento) void {
        if (d.passado.pop()) |f| liberarFoto(d.gpa, f);
    }

    pub fn desfazer(d: *Documento) !bool {
        const f = d.passado.pop() orelse return false;
        defer liberarFoto(d.gpa, f);
        const agora = try d.foto();
        d.futuro.append(d.gpa, agora) catch {
            liberarFoto(d.gpa, agora);
            return error.OutOfMemory;
        };
        try d.restaurar(f);
        return true;
    }

    pub fn refazer(d: *Documento) !bool {
        const f = d.futuro.pop() orelse return false;
        defer liberarFoto(d.gpa, f);
        const agora = try d.foto();
        d.passado.append(d.gpa, agora) catch {
            liberarFoto(d.gpa, agora);
            return error.OutOfMemory;
        };
        try d.restaurar(f);
        return true;
    }

    // ------------------------------------------------------------ objetos

    /// Põe o objeto no topo, com nome, e deixa só ele selecionado.
    pub fn adicionar(d: *Documento, c: Camada) !*Camada {
        var nova = c;
        if (nova.modelo == .moldura) {
            d.molduras += 1;
            nova.modelo.moldura.numero = d.molduras;
            nova.batizar("Moldura {d}", .{d.molduras});
        } else {
            d.criados += 1;
            nova.batizar("{s} {d}", .{ std.meta.activeTag(nova.modelo).nome(), d.criados });
        }
        // Cada objeto treme do seu jeito.
        switch (nova.modelo) {
            .desenho, .linha, .seta => |*t| if (t.semente == 0) {
                t.semente = d.criados *% 2654435761 +% 1;
            },
            .retangulo, .elipse => |*f| if (f.semente == 0) {
                f.semente = d.criados *% 2654435761 +% 1;
            },
            else => {},
        }
        errdefer nova.liberar(d.gpa);
        try nova.gerar(d.gpa);
        d.limparSelecao();
        nova.selecionada = true;
        try d.camadas.append(d.gpa, nova);
        return &d.camadas.items[d.camadas.items.len - 1];
    }

    /// Imagem (já lida) como objeto novo, centrada em `centro` (no mundo) e
    /// reduzida pela matriz se passar de `lado_max`: os pixels ficam todos
    /// lá, e aumentar de volta não perde nada.
    pub fn adicionarImagem(d: *Documento, pixels: Tela, caminho: []const u8, centro: Ponto, lado_max: f32) !void {
        const copia = try d.gpa.dupe(u8, caminho);
        errdefer d.gpa.free(copia);
        try d.imagens.append(d.gpa, .{ .pixels = pixels, .caminho = copia });
        errdefer _ = d.imagens.pop();
        const l: f32 = @floatFromInt(pixels.largura);
        const a: f32 = @floatFromInt(pixels.altura);
        const s = @min(1, lado_max / @max(l, a));
        const c = try d.adicionar(.{
            .modelo = .{ .imagem = @intCast(d.imagens.items.len - 1) },
            .matriz = Mat3.translacao(centro.x, centro.y).vezes(Mat3.escala(s, s)).vezes(Mat3.translacao(-l / 2, -a / 2)),
        });
        const base = std.fs.path.basename(caminho);
        c.batizar("{s}", .{base[0..@min(base.len, c.nome_buf.len)]});
    }

    // ------------------------------------------------------------ seleção

    pub fn limparSelecao(d: *Documento) void {
        for (d.camadas.items) |*c| c.selecionada = false;
    }

    pub fn quantasSelecionadas(d: *const Documento) usize {
        var n: usize = 0;
        for (d.camadas.items) |c| n += @intFromBool(c.selecionada);
        return n;
    }

    /// A selecionada, se for exatamente uma.
    pub fn unica(d: *Documento) ?*Camada {
        var achou: ?*Camada = null;
        for (d.camadas.items) |*c| if (c.selecionada) {
            if (achou != null) return null;
            achou = c;
        };
        return achou;
    }

    /// Marca (ou desmarca) o objeto i e o grupo dele inteiro.
    pub fn marcarSelecao(d: *Documento, i: usize, sim: bool) void {
        const g = d.camadas.items[i].grupo;
        for (d.camadas.items, 0..) |*c, k| {
            if (k == i or (g != 0 and c.grupo == g)) c.selecionada = sim;
        }
    }

    pub fn selecionarTudo(d: *Documento) void {
        for (d.camadas.items) |*c| c.selecionada = true;
    }

    /// Seleciona o que cabe inteiro no retângulo `r` da tela.
    pub fn selecionarArea(d: *Documento, vista: Mat3, r: Retangulo) void {
        for (d.camadas.items, 0..) |*c, i| {
            if (d.caixaNaTela(c, vista).dentroDe(r)) d.marcarSelecao(i, true);
        }
    }

    pub fn apagarSelecionadas(d: *Documento) void {
        var i: usize = 0;
        while (i < d.camadas.items.len) {
            if (d.camadas.items[i].selecionada) {
                var c = d.camadas.orderedRemove(i);
                c.liberar(d.gpa);
            } else i += 1;
        }
    }

    /// Cópia dos selecionados, deslocada por `desloc` (no mundo), no topo;
    /// a cópia fica selecionada. Grupos copiados viram grupos novos.
    pub fn duplicar(d: *Documento, desloc: Mat3) !void {
        const n = d.camadas.items.len;
        var novo_grupo = std.AutoHashMap(u32, u32).init(d.gpa);
        defer novo_grupo.deinit();
        for (0..n) |i| {
            if (!d.camadas.items[i].selecionada) continue;
            var c = try d.camadas.items[i].clonar(d.gpa);
            errdefer c.liberar(d.gpa);
            c.matriz = desloc.vezes(c.matriz);
            if (c.grupo != 0) {
                const r = try novo_grupo.getOrPut(c.grupo);
                if (!r.found_existing) {
                    d.grupos += 1;
                    r.value_ptr.* = d.grupos;
                }
                c.grupo = r.value_ptr.*;
            }
            try d.camadas.append(d.gpa, c);
            d.camadas.items[i].selecionada = false;
        }
    }

    pub fn agrupar(d: *Documento) void {
        if (d.quantasSelecionadas() < 2) return;
        d.grupos += 1;
        for (d.camadas.items) |*c| if (c.selecionada) {
            c.grupo = d.grupos;
        };
    }

    pub fn desagrupar(d: *Documento) void {
        for (d.camadas.items) |*c| if (c.selecionada) {
            c.grupo = 0;
        };
    }

    /// Sobe (+1) ou desce (-1) cada selecionado uma posição na pilha.
    pub fn mover(d: *Documento, sentido: i2) void {
        const cs = d.camadas.items;
        if (cs.len < 2) return;
        if (sentido > 0) {
            var i = cs.len - 1;
            while (i > 0) {
                i -= 1;
                if (cs[i].selecionada and !cs[i + 1].selecionada) std.mem.swap(Camada, &cs[i], &cs[i + 1]);
            }
        } else {
            for (1..cs.len) |i| {
                if (cs[i].selecionada and !cs[i - 1].selecionada) std.mem.swap(Camada, &cs[i], &cs[i - 1]);
            }
        }
    }

    /// O objeto mais de cima embaixo do ponto (x, y) da tela.
    pub fn tocar(d: *const Documento, vista: Mat3, x: i32, y: i32) ?usize {
        var i = d.camadas.items.len;
        while (i > 0) {
            i -= 1;
            const c = &d.camadas.items[i];
            if (c.toca(d.imagens.items, vista.vezes(c.matriz), @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5)) return i;
        }
        return null;
    }

    pub fn caixaNaTela(d: *const Documento, c: *const Camada, vista: Mat3) Retangulo {
        return c.caixa(d.imagens.items).transformado(vista.vezes(c.matriz));
    }

    /// Caixa (na tela) que contém todos os selecionados.
    /// Caixa no mundo de tudo (pra enquadrar o quadro inteiro na tela).
    pub fn caixaDeTudo(d: *const Documento) ?Retangulo {
        var r: ?Retangulo = null;
        for (d.camadas.items) |*c| r = Retangulo.unir(r, c.caixa(d.imagens.items).transformado(c.matriz));
        return r;
    }

    pub fn caixaSelecao(d: *const Documento, vista: Mat3) ?Retangulo {
        var r: ?Retangulo = null;
        for (d.camadas.items) |*c| if (c.selecionada) {
            r = Retangulo.unir(r, d.caixaNaTela(c, vista));
        };
        return r;
    }

    // ------------------------------------------------------------ transformar

    pub fn iniciarArrasto(d: *Documento) void {
        for (d.camadas.items) |*c| c.matriz0 = c.matriz;
    }

    /// Aplica `g` (dada na TELA: arrastar 10 px pra direita, girar em torno
    /// de um ponto da tela...) aos selecionados, a partir de como estavam no
    /// começo do arrasto. A matriz de cada um vive no mundo, então:
    ///     nova = vista⁻¹ · g · vista · antiga
    pub fn arrastar(d: *Documento, vista: Mat3, g: Mat3) void {
        const inv = vista.inversa() orelse return;
        const no_mundo = inv.vezes(g).vezes(vista);
        for (d.camadas.items) |*c| if (c.selecionada) {
            const nova = no_mundo.vezes(c.matriz0);
            if (nova.inversa() != null) c.matriz = nova;
        };
    }

    /// Como `arrastar`, mas soma em cima de onde está agora (setas do teclado).
    pub fn transformar(d: *Documento, vista: Mat3, g: Mat3) void {
        d.iniciarArrasto();
        d.arrastar(vista, g);
    }

    /// Depois de esticar um retângulo, elipse ou moldura pelas alças, passa
    /// a escala da matriz pro modelo (largura e altura) e deixa na matriz só
    /// giro e posição. Assim o contorno não engorda junto e o recorte da
    /// moldura sai sem distorção. As colunas da matriz são os eixos do
    /// objeto no mundo: o comprimento delas é a escala de cada eixo.
    pub fn assentarEscala(d: *Documento) void {
        for (d.camadas.items) |*c| {
            if (!c.selecionada) continue;
            const m = &c.matriz.m;
            const sx = @sqrt(m[0][0] * m[0][0] + m[1][0] * m[1][0]);
            const sy = @sqrt(m[0][1] * m[0][1] + m[1][1] * m[1][1]);
            // Eixos tortos um em relação ao outro (cisalhamento): deixa.
            const cisalha = m[0][0] * m[0][1] + m[1][0] * m[1][1];
            if (sx < 1e-4 or sy < 1e-4 or @abs(cisalha) > 1e-3 * sx * sy) continue;
            switch (c.modelo) {
                .retangulo, .elipse => |*f| {
                    f.largura *= sx;
                    f.altura *= sy;
                },
                .moldura => |*mo| {
                    mo.largura *= sx;
                    mo.altura *= sy;
                },
                else => continue,
            }
            m[0][0] /= sx;
            m[1][0] /= sx;
            m[0][1] /= sy;
            m[1][1] /= sy;
        }
    }

    // ------------------------------------------------------------ pintar

    /// Pinta todos os objetos na tela, de baixo pra cima.
    pub fn desenhar(d: *const Documento, t: *Tela, vista: Mat3) void {
        for (d.camadas.items) |*c| c.desenhar(t, d.imagens.items, vista.vezes(c.matriz));
    }

    pub fn desenharMolduras(d: *const Documento, t: *Tela, vista: Mat3) void {
        for (d.camadas.items) |*c| if (c.modelo == .moldura) desenharMoldura(t, c, vista.vezes(c.matriz));
    }

    /// RECORTE: pinta de novo, numa imagem nova, a região `largura`×`altura`
    /// (nas unidades dela) que `regiao` leva pro mundo, com `escala` pixels
    /// por unidade. Não é foto da tela: é o modelo gerado de novo, então
    /// sai nítido em qualquer escala, sem menu nem alça por cima.
    ///     mundo → imagem = S(escala · σ) · regiao⁻¹
    /// (σ é o quanto a própria região foi aumentada, se foi.)
    /// `so_selecao`: só os objetos selecionados (copiar a seleção como imagem).
    pub fn recortar(d: *const Documento, regiao: Mat3, largura: f32, altura: f32, escala: f32, fundo: Cor, so_selecao: bool) !Tela {
        const inv = regiao.inversa() orelse return error.RegiaoInvalida;
        const k = escala * regiao.fator();
        const w = @ceil(largura * k);
        const h = @ceil(altura * k);
        if (!(w >= 1 and h >= 1)) return error.RegiaoVazia;
        if (w > 8000 or h > 8000) return error.RecorteGrandeDemais;
        var t = try Tela.criar(d.gpa, @intFromFloat(w), @intFromFloat(h), fundo);
        errdefer t.destruir();
        const para_imagem = Mat3.escala(k, k).vezes(inv);
        for (d.camadas.items) |*c| {
            if (c.modelo == .moldura or (so_selecao and !c.selecionada)) continue;
            c.desenhar(&t, d.imagens.items, para_imagem.vezes(c.matriz));
        }
        return t;
    }
};

const testing = std.testing;
const branco = opaco | 0xffffff;

fn tracoNovo(gpa: std.mem.Allocator, pontos: []const Ponto, esp: f32) !Camada {
    var t: Traco = .{ .cor = opaco, .espessura = esp };
    try t.pontos.appendSlice(gpa, pontos);
    return .{ .modelo = .{ .desenho = t } };
}

fn retanguloNovo(x: f32, y: f32, w: f32, h: f32, fundo: ?Cor) Camada {
    return .{ .modelo = .{ .retangulo = .{ .largura = w, .altura = h, .cor = opaco, .fundo = fundo, .espessura = 2 } }, .matriz = Mat3.translacao(x, y) };
}

test "o traço é pintado do modelo: liso em qualquer zoom" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(try tracoNovo(testing.allocator, &.{ .{ .x = 2, .y = 5 }, .{ .x = 18, .y = 5 } }, 2));
    var t = try Tela.criar(testing.allocator, 80, 40, branco);
    defer t.destruir();
    // Zoom de 4×: o traço de 2 unidades vira 8 pixels de grossura.
    d.desenhar(&t, Mat3.escala(4, 4));
    try testing.expectEqual(opaco, t.pixels[20 * 80 + 40]);
    try testing.expectEqual(opaco, t.pixels[17 * 80 + 40]);
    try testing.expectEqual(branco, t.pixels[10 * 80 + 40]);
}

test "clicar pega o objeto de cima; retângulo vazado só pela borda" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(retanguloNovo(10, 10, 100, 60, null));
    _ = try d.adicionar(try tracoNovo(testing.allocator, &.{ .{ .x = 0, .y = 100 }, .{ .x = 50, .y = 100 } }, 3));
    const v = Mat3.identidade;
    try testing.expectEqual(@as(?usize, 0), d.tocar(v, 11, 40)); // na borda esquerda
    try testing.expectEqual(@as(?usize, null), d.tocar(v, 60, 40)); // no meio, vazado
    try testing.expectEqual(@as(?usize, 1), d.tocar(v, 25, 102));
    d.camadas.items[0].modelo.retangulo.fundo = branco;
    try testing.expectEqual(@as(?usize, 0), d.tocar(v, 60, 40)); // com fundo, o meio pega
}

test "arrastar com a vista com zoom move a mesma distância na tela" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(retanguloNovo(5, 5, 10, 10, null));
    const vista = Mat3.escala(2, 2);
    const antes = d.caixaSelecao(vista).?;
    d.iniciarArrasto();
    d.arrastar(vista, Mat3.translacao(10, 0));
    d.arrastar(vista, Mat3.translacao(20, 0)); // a partir do começo, não acumula
    const depois = d.caixaSelecao(vista).?;
    try testing.expectApproxEqAbs(antes.x0 + 20, depois.x0, 1e-3);
}

test "desfazer e refazer voltam o quadro inteiro" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    try d.marcar();
    _ = try d.adicionar(try tracoNovo(testing.allocator, &.{.{ .x = 1, .y = 1 }}, 2));
    try d.marcar();
    d.camadas.items[0].traco().?.pontos.items[0].x = 99;
    try testing.expect(try d.desfazer());
    try testing.expectEqual(@as(f32, 1), d.camadas.items[0].traco().?.pontos.items[0].x);
    try testing.expect(try d.desfazer());
    try testing.expectEqual(@as(usize, 0), d.camadas.items.len);
    try testing.expect(!try d.desfazer());
    try testing.expect(try d.refazer());
    try testing.expect(try d.refazer());
    try testing.expectEqual(@as(f32, 99), d.camadas.items[0].traco().?.pontos.items[0].x);
    // Mudar depois de desfazer apaga o refazer.
    _ = try d.desfazer();
    try d.marcar();
    try testing.expect(!try d.refazer());
}

test "seleção: grupo vem junto, área pega o que cabe inteiro, apagar e duplicar" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(retanguloNovo(0, 0, 10, 10, null));
    _ = try d.adicionar(retanguloNovo(100, 0, 10, 10, null));
    _ = try d.adicionar(retanguloNovo(300, 0, 10, 10, null));
    d.selecionarTudo();
    d.camadas.items[2].selecionada = false;
    d.agrupar();
    d.limparSelecao();
    d.marcarSelecao(0, true);
    try testing.expectEqual(@as(usize, 2), d.quantasSelecionadas());
    d.limparSelecao();
    d.selecionarArea(Mat3.identidade, .{ .x0 = 250, .y0 = -20, .x1 = 400, .y1 = 50 });
    try testing.expect(d.unica() == &d.camadas.items[2]);
    try d.duplicar(Mat3.translacao(20, 20));
    try testing.expectEqual(@as(usize, 4), d.camadas.items.len);
    try testing.expect(d.camadas.items[3].selecionada and !d.camadas.items[2].selecionada);
    d.apagarSelecionadas();
    try testing.expectEqual(@as(usize, 3), d.camadas.items.len);
}

test "subir e descer andam uma posição" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(retanguloNovo(0, 0, 1, 1, null));
    _ = try d.adicionar(retanguloNovo(5, 0, 1, 1, null));
    d.limparSelecao();
    d.camadas.items[0].selecionada = true;
    d.mover(1);
    try testing.expect(d.camadas.items[1].selecionada);
    d.mover(1); // já no topo
    try testing.expect(d.camadas.items[1].selecionada);
    d.mover(-1);
    try testing.expect(d.camadas.items[0].selecionada);
}

test "recorte: gera de novo na escala pedida e ignora a moldura" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(retanguloNovo(10, 10, 20, 20, opaco | 0xff0000));
    _ = try d.adicionar(.{ .modelo = .{ .moldura = .{ .largura = 40, .altura = 40, .numero = 0 } } });
    try testing.expectEqualStrings("Moldura 1", d.camadas.items[1].nome());
    var r = try d.recortar(d.camadas.items[1].matriz, 40, 40, 3, branco, false);
    defer r.destruir();
    try testing.expectEqual(@as(u16, 120), r.largura);
    // O meio do quadrado (20,20) cai em (60,60) no recorte de 3×.
    try testing.expectEqual(opaco | 0xff0000, r.pixels[60 * 120 + 60]);
    try testing.expectEqual(branco, r.pixels[5 * 120 + 5]);
}

test "Chaikin: mais pontos, pontas no lugar, canto arredondado" {
    var c = try tracoNovo(testing.allocator, &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } }, 2);
    defer c.liberar(testing.allocator);
    try c.traco().?.suavizar(testing.allocator, 2);
    const p = c.traco().?.pontos.items;
    try testing.expectEqual(@as(usize, 12), p.len); // 3 → 6 → 12
    try testing.expectEqual(Ponto{ .x = 0, .y = 0 }, p[0]);
    try testing.expectEqual(Ponto{ .x = 10, .y = 10 }, p[p.len - 1]);
    // Nenhum ponto passa exatamente pelo canto (10, 0).
    for (p) |q| try testing.expect(!(q.x == 10 and q.y == 0));
}

test "texto: inserir e apagar respeitam UTF-8 e o tamanho muda os pixels" {
    var t: Texto = .{ .cor = 0 };
    t.trocar("S");
    t.inserir('ã');
    t.inserir('o');
    try testing.expectEqualStrings("São", t.conteudo());
    t.apagarUltimo();
    t.apagarUltimo();
    try testing.expectEqualStrings("S", t.conteudo());

    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    const c = try d.adicionar(.{ .modelo = .{ .texto = t } });
    try testing.expectEqual(@as(u16, 8 * 3), c.cache.?.largura);
    try c.aplicar(testing.allocator, .tamanho, .{ .tamanho = 5 });
    try testing.expectEqual(@as(u16, 8 * 5), c.cache.?.largura);
}

test "forma com fundo pinta dentro, vazada só a borda" {
    var t = try Tela.criar(testing.allocator, 50, 50, branco);
    defer t.destruir();
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    _ = try d.adicionar(retanguloNovo(10, 10, 30, 30, null));
    _ = try d.adicionar(.{ .modelo = .{ .elipse = .{ .largura = 10, .altura = 10, .cor = opaco, .fundo = opaco | 0x00ff00, .espessura = 0 } }, .matriz = Mat3.translacao(30, 30) });
    d.desenhar(&t, Mat3.identidade);
    try testing.expectEqual(opaco, t.pixels[25 * 50 + 10]); // borda do retângulo
    try testing.expectEqual(branco, t.pixels[20 * 50 + 20]); // dentro, vazado
    try testing.expectEqual(opaco | 0x00ff00, t.pixels[35 * 50 + 35]); // meio da elipse
    try testing.expectEqual(branco, t.pixels[30 * 50 + 30]); // canto da caixa da elipse
}

test "à mão: o contorno treme mas fica perto da borda, e sempre igual" {
    var t1 = try Tela.criar(testing.allocator, 120, 120, branco);
    defer t1.destruir();
    var t2 = try Tela.criar(testing.allocator, 120, 120, branco);
    defer t2.destruir();
    const f: Forma = .{ .largura = 80, .altura = 80, .cor = opaco, .espessura = 2, .mao = true, .semente = 42 };
    const c: Camada = .{ .modelo = .{ .retangulo = f }, .matriz = Mat3.translacao(20, 20) };
    c.desenhar(&t1, &.{}, c.matriz);
    c.desenhar(&t2, &.{}, c.matriz);
    try testing.expectEqualSlices(Cor, t1.pixels, t2.pixels);
    // O meio fica limpo e o lado de cima tem tinta perto de y = 20.
    try testing.expectEqual(branco, t1.pixels[60 * 120 + 60]);
    var tinta: usize = 0;
    for (14..27) |y| tinta += @intFromBool(t1.pixels[y * 120 + 60] != branco);
    try testing.expect(tinta > 0);
}
