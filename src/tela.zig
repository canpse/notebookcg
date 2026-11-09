//! A tela é só um vetor de pixels na memória. Tudo que o editor desenha
//! acaba aqui, um pixel de cada vez; a janela só copia isto pro monitor.
const std = @import("std");
const Mat3 = @import("mat3.zig").Mat3;

/// 0xAARRGGBB. A é a opacidade: 0 transparente, 255 opaco. A janela ignora
/// o A; nas camadas ele é o que deixa ver o que está embaixo.
pub const Cor = u32;

pub const opaco: Cor = 0xff000000;

/// Retângulo de pixels; x1 e y1 ficam de fora.
pub const Caixa = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn unir(a: ?Caixa, b: Caixa) Caixa {
        const c = a orelse return b;
        return .{ .x0 = @min(c.x0, b.x0), .y0 = @min(c.y0, b.y0), .x1 = @max(c.x1, b.x1), .y1 = @max(c.y1, b.y1) };
    }

    pub fn contem(c: Caixa, x: i32, y: i32) bool {
        return x >= c.x0 and x < c.x1 and y >= c.y0 and y < c.y1;
    }

    /// Parte da caixa que cabe em (0,0)–(largura,altura); null se nada.
    pub fn recortar(c: Caixa, largura: i32, altura: i32) ?Caixa {
        const r: Caixa = .{ .x0 = @max(c.x0, 0), .y0 = @max(c.y0, 0), .x1 = @min(c.x1, largura), .y1 = @min(c.y1, altura) };
        return if (r.x0 < r.x1 and r.y0 < r.y1) r else null;
    }
};

pub const Tela = struct {
    gpa: std.mem.Allocator,
    pixels: []Cor,
    largura: u16,
    altura: u16,
    /// Cobertura de cada pixel (0–255) do traço sendo pintado; criada na
    /// primeira vez que precisar. Ver `tracar`.
    mascara: ?[]u8 = null,
    sujo: ?Caixa = null,

    pub fn criar(gpa: std.mem.Allocator, largura: u16, altura: u16, fundo: Cor) !Tela {
        const pixels = try gpa.alloc(Cor, @as(usize, largura) * altura);
        @memset(pixels, fundo);
        return .{ .gpa = gpa, .pixels = pixels, .largura = largura, .altura = altura };
    }

    pub fn destruir(t: *Tela) void {
        t.gpa.free(t.pixels);
        if (t.mascara) |m| t.gpa.free(m);
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

    pub fn clonar(t: *const Tela) !Tela {
        const pixels = try t.gpa.dupe(Cor, t.pixels);
        return .{ .gpa = t.gpa, .pixels = pixels, .largura = t.largura, .altura = t.altura };
    }

    pub fn limpar(t: *Tela, cor: Cor) void {
        @memset(t.pixels, cor);
    }

    /// Pinta um pixel. Fora da tela não faz nada.
    pub fn ponto(t: *Tela, x: i32, y: i32, cor: Cor) void {
        if (x < 0 or y < 0 or x >= t.largura or y >= t.altura) return;
        t.pixels[@as(usize, @intCast(y)) * t.largura + @as(usize, @intCast(x))] = cor;
    }

    /// Retângulo cheio (só a parte que cabe na tela).
    pub fn retangulo(t: *Tela, caixa: Caixa, cor: Cor) void {
        const c = caixa.recortar(t.largura, t.altura) orelse return;
        var y = c.y0;
        while (y < c.y1) : (y += 1) {
            const inicio = @as(usize, @intCast(y)) * t.largura;
            @memset(t.pixels[inicio + @as(usize, @intCast(c.x0)) .. inicio + @as(usize, @intCast(c.x1))], cor);
        }
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

    /// Pinta `cor` por cima do pixel cobrindo só uma fração dele (0 a 1).
    /// É isso que suaviza a borda (antialiasing): um pixel que a forma cobre
    /// pela metade fica meio pintado em vez de "pinta ou não pinta", que é o
    /// que dá a escadinha.
    pub fn misturar(t: *Tela, x: i32, y: i32, cor: Cor, cobertura: f32) void {
        if (x < 0 or y < 0 or x >= t.largura or y >= t.altura) return;
        const a = std.math.clamp(cobertura, 0, 1) * @as(f32, @floatFromInt(cor >> 24)) / 255;
        if (a <= 0.002) return;
        const i = @as(usize, @intCast(y)) * t.largura + @as(usize, @intCast(x));
        if (a >= 0.998) {
            t.pixels[i] = cor | opaco;
            return;
        }
        const embaixo = t.pixels[i];
        var r: Cor = opaco;
        inline for (.{ 16, 8, 0 }) |sh| {
            const c: f32 = @floatFromInt((cor >> sh) & 0xff);
            const e: f32 = @floatFromInt((embaixo >> sh) & 0xff);
            r |= @as(Cor, @intFromFloat(@round(c * a + e * (1 - a)))) << sh;
        }
        t.pixels[i] = r;
    }

    /// Segmento grosso de (ax, ay) a (bx, by) com pontas redondas e borda
    /// suave, mas ainda NÃO pinta: marca na máscara quanto cada pixel está
    /// coberto (a distância do centro do pixel ao segmento diz isso). Um
    /// traço tem centenas de segmentos que se sobrepõem nas juntas; se cada
    /// um pintasse direto, a borda meio transparente seria pintada várias
    /// vezes e ficaria escura. Com a máscara, cada pixel guarda o MAIOR valor
    /// e `pintarMascara` pinta uma vez só no fim.
    pub fn tracar(t: *Tela, ax: f32, ay: f32, bx: f32, by: f32, raio: f32, cor: Cor) void {
        const m = t.pegarMascara() orelse {
            // Sem memória pra máscara: pinta direto (borda um pouco mais escura).
            t.segmentoDireto(ax, ay, bx, by, raio, cor);
            return;
        };
        const r = @max(raio, 0.5);
        const caixa = (Caixa{
            .x0 = paraInt(@min(ax, bx) - r - 1),
            .y0 = paraInt(@min(ay, by) - r - 1),
            .x1 = paraInt(@max(ax, bx) + r + 2),
            .y1 = paraInt(@max(ay, by) + r + 2),
        }).recortar(t.largura, t.altura) orelse return;
        t.sujo = Caixa.unir(t.sujo, caixa);
        var y = caixa.y0;
        while (y < caixa.y1) : (y += 1) {
            var x = caixa.x0;
            while (x < caixa.x1) : (x += 1) {
                const d = distanciaAoSegmento(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, ax, ay, bx, by);
                const cob = std.math.clamp(r + 0.5 - d, 0, 1);
                if (cob <= 0) continue;
                const i = @as(usize, @intCast(y)) * t.largura + @as(usize, @intCast(x));
                m[i] = @max(m[i], @as(u8, @intFromFloat(@round(cob * 255))));
            }
        }
    }

    /// Pinta com `cor` o que foi marcado na máscara desde a última vez e a zera.
    pub fn pintarMascara(t: *Tela, cor: Cor) void {
        const m = t.mascara orelse return;
        const c = t.sujo orelse return;
        t.sujo = null;
        var y = c.y0;
        while (y < c.y1) : (y += 1) {
            var x = c.x0;
            while (x < c.x1) : (x += 1) {
                const i = @as(usize, @intCast(y)) * t.largura + @as(usize, @intCast(x));
                if (m[i] == 0) continue;
                t.misturar(x, y, cor, @as(f32, @floatFromInt(m[i])) / 255);
                m[i] = 0;
            }
        }
    }

    fn pegarMascara(t: *Tela) ?[]u8 {
        if (t.mascara) |m| {
            if (m.len == t.pixels.len) return m;
            t.gpa.free(m);
            t.mascara = null;
        }
        const m = t.gpa.alloc(u8, t.pixels.len) catch return null;
        @memset(m, 0);
        t.mascara = m;
        t.sujo = null;
        return m;
    }

    fn segmentoDireto(t: *Tela, ax: f32, ay: f32, bx: f32, by: f32, raio: f32, cor: Cor) void {
        const r = @max(raio, 0.5);
        var y = paraInt(@min(ay, by) - r - 1);
        while (y < paraInt(@max(ay, by) + r + 2)) : (y += 1) {
            if (y < 0 or y >= t.altura) continue;
            var x = @max(0, paraInt(@min(ax, bx) - r - 1));
            while (x < @min(t.largura, paraInt(@max(ax, bx) + r + 2))) : (x += 1) {
                const d = distanciaAoSegmento(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, ax, ay, bx, by);
                t.misturar(x, y, cor, r + 0.5 - d);
            }
        }
    }

    /// Linha fina tracejada (contorno de moldura e de seleção).
    pub fn tracejada(t: *Tela, ax: f32, ay: f32, bx: f32, by: f32, traco: f32, cor: Cor) void {
        const dx = bx - ax;
        const dy = by - ay;
        const l = @sqrt(dx * dx + dy * dy);
        if (l < 0.5) return;
        var s: f32 = 0;
        while (s < l) : (s += 0.5) {
            if (@mod(s, 2 * traco) >= traco) continue;
            t.ponto(paraInt(ax + dx * s / l), paraInt(ay + dy * s / l), cor);
        }
    }

    /// Pixel (x, y), grudando na borda se cair fora.
    pub fn pegar(t: *const Tela, x: i32, y: i32) Cor {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i32, t.largura) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i32, t.altura) - 1));
        return t.pixels[cy * t.largura + cx];
    }

    /// Cor na posição (u, v) em unidades de pixel, que quase sempre cai entre
    /// pixels: mistura os 4 vizinhos pelo quanto (u, v) está perto de cada um
    /// (interpolação bilinear). Fora da imagem devolve null.
    ///
    /// Devolve {A, R, G, B} de 0 a 255 com a cor já PRÉ-MULTIPLICADA pela
    /// opacidade. Misturar sem isso faria a borda de um traço puxar a cor dos
    /// pixels transparentes vizinhos (que não têm cor nenhuma) e escurecer.
    pub fn amostrar(t: *const Tela, u: f32, v: f32) ?[4]f32 {
        const lw: f32 = @floatFromInt(t.largura);
        const lh: f32 = @floatFromInt(t.altura);
        if (!(u >= -0.5 and v >= -0.5 and u < lw - 0.5 and v < lh - 0.5)) return null;
        const base_u = @floor(u);
        const base_v = @floor(v);
        const fx = u - base_u;
        const fy = v - base_v;
        const x: i32 = @intFromFloat(base_u);
        const y: i32 = @intFromFloat(base_v);
        const vizinhos = [4]Cor{ t.pegar(x, y), t.pegar(x + 1, y), t.pegar(x, y + 1), t.pegar(x + 1, y + 1) };
        const pesos = [4]f32{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
        var r = [4]f32{ 0, 0, 0, 0 };
        for (vizinhos, pesos) |c, p| {
            const a: f32 = @floatFromInt(c >> 24);
            r[0] += a * p;
            inline for (.{ 16, 8, 0 }, 1..) |s, i| {
                const canal: f32 = @floatFromInt((c >> s) & 0xff);
                r[i] += canal * (a / 255) * p;
            }
        }
        return r;
    }

    /// O pixel que contém (u, v), no mesmo formato de `amostrar`.
    pub fn maisPerto(t: *const Tela, u: f32, v: f32) ?[4]f32 {
        if (!(u >= 0 and v >= 0 and u < @as(f32, @floatFromInt(t.largura)) and v < @as(f32, @floatFromInt(t.altura)))) return null;
        const c = t.pixels[@as(usize, @intFromFloat(v)) * t.largura + @as(usize, @intFromFloat(u))];
        const a: f32 = @floatFromInt(c >> 24);
        return .{ a, @as(f32, @floatFromInt((c >> 16) & 0xff)) * a / 255, @as(f32, @floatFromInt((c >> 8) & 0xff)) * a / 255, @as(f32, @floatFromInt(c & 0xff)) * a / 255 };
    }

    /// Pinta `origem` POR CIMA desta tela, transformada por uma matriz da qual
    /// se recebe a INVERSA, só dentro de `caixa`. Mapeamento inverso: pra cada
    /// pixel daqui pergunta "de onde você veio lá?". No sentido direto (levar
    /// cada pixel de lá pra cá) sobram buracos quando a imagem gira ou aumenta.
    /// "Por cima": cor final = origem + destino × (1 − opacidade da origem).
    /// `vizinho`: em vez de misturar os 4 vizinhos, pega o pixel mais perto
    /// (pra fonte bitmap, que aumentada fica nítida, de pixels grandes).
    pub fn comporTransformada(t: *Tela, origem: *const Tela, inversa: Mat3, caixa: Caixa, vizinho: bool) void {
        const c = caixa.recortar(t.largura, t.altura) orelse return;
        var y = c.y0;
        while (y < c.y1) : (y += 1) {
            const fy: f32 = @floatFromInt(y);
            var x = c.x0;
            while (x < c.x1) : (x += 1) {
                const fx: f32 = @floatFromInt(x);
                // +0.5: o centro do pixel; -0.5 volta pra índice do outro lado.
                const p = inversa.aplicar(fx + 0.5, fy + 0.5);
                const s = (if (vizinho) origem.maisPerto(p.x, p.y) else origem.amostrar(p.x - 0.5, p.y - 0.5)) orelse continue;
                if (s[0] < 0.5) continue;
                const i = @as(usize, @intCast(y)) * t.largura + @as(usize, @intCast(x));
                const resto = 1 - s[0] / 255;
                var cor: Cor = opaco;
                inline for (.{ 16, 8, 0 }, 1..) |sh, k| {
                    const embaixo: f32 = @floatFromInt((t.pixels[i] >> sh) & 0xff);
                    const canal = @min(255, s[k] + embaixo * resto);
                    cor |= @as(Cor, @intFromFloat(@round(canal))) << sh;
                }
                t.pixels[i] = cor;
            }
        }
    }
};

pub fn paraInt(v: f32) i32 {
    return @intFromFloat(@floor(std.math.clamp(v, -1e6, 1e6)));
}

/// Distância do ponto (px, py) ao segmento a–b.
pub fn distanciaAoSegmento(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const l2 = dx * dx + dy * dy;
    const h = if (l2 > 0) std.math.clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1) else 0;
    const ex = px - (ax + h * dx);
    const ey = py - (ay + h * dy);
    return @sqrt(ex * ex + ey * ey);
}

test "traço suave: dentro cheio, borda no meio-termo, longe nada" {
    var t = try Tela.criar(std.testing.allocator, 20, 10, opaco | 0xffffff);
    defer t.destruir();
    t.tracar(2, 5, 18, 5, 2.5, opaco);
    t.tracar(10, 5, 10, 5, 2.5, opaco); // sobreposto: não escurece a borda
    t.pintarMascara(opaco);
    try std.testing.expectEqual(opaco, t.pixels[4 * 20 + 10]);
    try std.testing.expectEqual(opaco | 0xffffff, t.pixels[0]);
    // A linha y=2 (centro 2.5) fica a 2.5 do eixo: metade coberta.
    const meio = t.pixels[2 * 20 + 10] & 0xff;
    try std.testing.expect(meio > 100 and meio < 160);
    try std.testing.expectEqual(@as(?Caixa, null), t.sujo);
}

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

const caixa_toda: Caixa = .{ .x0 = 0, .y0 = 0, .x1 = 1000, .y1 = 1000 };

test "compor uma imagem opaca sem transformar copia igualzinho" {
    var origem = try Tela.criar(std.testing.allocator, 5, 4, 0);
    defer origem.destruir();
    for (origem.pixels, 0..) |*p, i| p.* = opaco | @as(Cor, @intCast(i * 0x030201));
    var destino = try Tela.criar(std.testing.allocator, 5, 4, opaco);
    defer destino.destruir();
    destino.comporTransformada(&origem, Mat3.identidade, caixa_toda, false);
    try std.testing.expectEqualSlices(Cor, origem.pixels, destino.pixels);
}

test "o transparente deixa ver o que está embaixo" {
    var origem = try Tela.criar(std.testing.allocator, 2, 1, 0);
    defer origem.destruir();
    origem.pixels[1] = opaco | 0x102030;
    var destino = try Tela.criar(std.testing.allocator, 2, 1, opaco | 0xffffff);
    defer destino.destruir();
    destino.comporTransformada(&origem, Mat3.identidade, caixa_toda, false);
    try std.testing.expectEqual(opaco | 0xffffff, destino.pixels[0]);
    try std.testing.expectEqual(opaco | 0x102030, destino.pixels[1]);
}

test "bilinear entre preto opaco e transparente sobre branco dá cinza, não preto" {
    var t = try Tela.criar(std.testing.allocator, 2, 1, 0);
    defer t.destruir();
    t.pixels[0] = opaco;
    const s = t.amostrar(0.5, 0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 127.5), s[0], 0.01);
    try std.testing.expectEqual(@as(?[4]f32, null), t.amostrar(5, 0));
}

test "dobrar o tamanho cobre a área toda sem buracos" {
    var origem = try Tela.criar(std.testing.allocator, 4, 4, opaco | 0x111111);
    defer origem.destruir();
    var destino = try Tela.criar(std.testing.allocator, 8, 8, opaco);
    defer destino.destruir();
    destino.comporTransformada(&origem, Mat3.escala(2, 2).inversa().?, caixa_toda, false);
    for (destino.pixels) |p| try std.testing.expectEqual(opaco | 0x111111, p);
}
