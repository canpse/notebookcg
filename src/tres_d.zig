//! O pedaço 3D das aulas: vetores, matrizes 4×4, malhas e um rasterizador
//! de triângulos com z-buffer. Nada de OpenGL: cada triângulo é projetado
//! e pintado pixel por pixel aqui, que é justamente o que as aulas 6, 7 e 8
//! querem mostrar.
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const Caixa = tela_.Caixa;
const opaco = tela_.opaco;

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn v(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn mais(a: Vec3, b: Vec3) Vec3 {
        return v(a.x + b.x, a.y + b.y, a.z + b.z);
    }
    pub fn menos(a: Vec3, b: Vec3) Vec3 {
        return v(a.x - b.x, a.y - b.y, a.z - b.z);
    }
    pub fn vezes(a: Vec3, k: f32) Vec3 {
        return v(a.x * k, a.y * k, a.z * k);
    }
    pub fn escalar(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn vetorial(a: Vec3, b: Vec3) Vec3 {
        return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
    }
    pub fn tamanho(a: Vec3) f32 {
        return @sqrt(a.escalar(a));
    }
    pub fn normalizado(a: Vec3) Vec3 {
        const t = a.tamanho();
        return if (t < 1e-9) a else a.vezes(1 / t);
    }
};

/// Matriz 4×4 em coordenadas homogêneas: o mesmo truque da Mat3, com uma
/// dimensão a mais. m[linha][coluna]; o ponto é um vetor coluna (x, y, z, 1).
pub const Mat4 = struct {
    m: [4][4]f32,

    pub const identidade: Mat4 = .{ .m = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub fn translacao(x: f32, y: f32, z: f32) Mat4 {
        var r = identidade;
        r.m[0][3] = x;
        r.m[1][3] = y;
        r.m[2][3] = z;
        return r;
    }

    pub fn escala(x: f32, y: f32, z: f32) Mat4 {
        var r = identidade;
        r.m[0][0] = x;
        r.m[1][1] = y;
        r.m[2][2] = z;
        return r;
    }

    /// Giro em torno do eixo X (y e z mudam).
    pub fn rotX(a: f32) Mat4 {
        const c = @cos(a);
        const s = @sin(a);
        var r = identidade;
        r.m[1][1] = c;
        r.m[1][2] = -s;
        r.m[2][1] = s;
        r.m[2][2] = c;
        return r;
    }

    /// Giro em torno do eixo Y (x e z mudam).
    pub fn rotY(a: f32) Mat4 {
        const c = @cos(a);
        const s = @sin(a);
        var r = identidade;
        r.m[0][0] = c;
        r.m[0][2] = s;
        r.m[2][0] = -s;
        r.m[2][2] = c;
        return r;
    }

    /// Projeção perspectiva (a do OpenGL): a câmera olha pra −z; `fov` é o
    /// ângulo de visão vertical. A última linha copia −z pra w: depois de
    /// dividir por w, o que está longe encolhe.
    pub fn perspectiva(fov: f32, perto: f32, longe: f32) Mat4 {
        const f = 1 / @tan(fov / 2);
        return .{ .m = .{
            .{ f, 0, 0, 0 },
            .{ 0, f, 0, 0 },
            .{ 0, 0, (longe + perto) / (perto - longe), 2 * longe * perto / (perto - longe) },
            .{ 0, 0, -1, 0 },
        } };
    }

    /// Projeção ortográfica: só escala e joga z fora (w fica 1). `s` é a
    /// escala de x e y, escolhida pra caber o mesmo tamanho da perspectiva.
    pub fn ortografica(s: f32, perto: f32, longe: f32) Mat4 {
        return .{ .m = .{
            .{ s, 0, 0, 0 },
            .{ 0, s, 0, 0 },
            .{ 0, 0, -2 / (longe - perto), -(longe + perto) / (longe - perto) },
            .{ 0, 0, 0, 1 },
        } };
    }

    pub fn vezes(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |i| for (0..4) |j| {
            var s: f32 = 0;
            for (0..4) |k| s += a.m[i][k] * b.m[k][j];
            r.m[i][j] = s;
        };
        return r;
    }

    /// (x, y, z, 1) → (x', y', z', w), sem dividir.
    pub fn aplicar4(a: Mat4, p: Vec3) [4]f32 {
        var r: [4]f32 = undefined;
        for (0..4) |i| r[i] = a.m[i][0] * p.x + a.m[i][1] * p.y + a.m[i][2] * p.z + a.m[i][3];
        return r;
    }

    pub fn ponto(a: Mat4, p: Vec3) Vec3 {
        const r = a.aplicar4(p);
        return Vec3.v(r[0] / r[3], r[1] / r[3], r[2] / r[3]);
    }

    /// Direção (w = 0): a translação não mexe em vetores, só em pontos.
    pub fn direcao(a: Mat4, d: Vec3) Vec3 {
        return Vec3.v(
            a.m[0][0] * d.x + a.m[0][1] * d.y + a.m[0][2] * d.z,
            a.m[1][0] * d.x + a.m[1][1] * d.y + a.m[1][2] * d.z,
            a.m[2][0] * d.x + a.m[2][1] * d.y + a.m[2][2] * d.z,
        );
    }
};

/// Triângulo de uma malha: índices dos vértices, no sentido anti-horário
/// visto de fora (é isso que deixa o descarte de faces de trás funcionar).
pub const Tri = [3]u16;

pub const Malha = struct {
    pontos: []Vec3,
    normais: []Vec3,
    tris: []Tri,
};

/// Cubo de −1 a 1. Cada face tem os próprios 4 vértices (a normal muda de
/// uma face pra outra). Ordem dos cantos: n + (−u−v, u−v, u+v, −u+v) com
/// u × v = n, que dá anti-horário olhando de fora.
pub fn cubo(pontos: *[24]Vec3, normais: *[24]Vec3, tris: *[12]Tri) Malha {
    const faces = [6][3]Vec3{
        .{ Vec3.v(1, 0, 0), Vec3.v(0, 1, 0), Vec3.v(0, 0, 1) },
        .{ Vec3.v(-1, 0, 0), Vec3.v(0, 0, 1), Vec3.v(0, 1, 0) },
        .{ Vec3.v(0, 1, 0), Vec3.v(0, 0, 1), Vec3.v(1, 0, 0) },
        .{ Vec3.v(0, -1, 0), Vec3.v(1, 0, 0), Vec3.v(0, 0, 1) },
        .{ Vec3.v(0, 0, 1), Vec3.v(1, 0, 0), Vec3.v(0, 1, 0) },
        .{ Vec3.v(0, 0, -1), Vec3.v(0, 1, 0), Vec3.v(1, 0, 0) },
    };
    for (faces, 0..) |f, i| {
        const n = f[0];
        const u = f[1];
        const w = f[2];
        const cantos = [4]Vec3{
            n.menos(u).menos(w),
            n.mais(u).menos(w),
            n.mais(u).mais(w),
            n.menos(u).mais(w),
        };
        for (cantos, 0..) |c, k| {
            pontos[i * 4 + k] = c;
            normais[i * 4 + k] = n;
        }
        const b: u16 = @intCast(i * 4);
        tris[i * 2] = .{ b, b + 1, b + 2 };
        tris[i * 2 + 1] = .{ b, b + 2, b + 3 };
    }
    return .{ .pontos = pontos, .normais = normais, .tris = tris };
}

pub const max_pontos_esfera = 49 * 97;
pub const max_tris_esfera = 48 * 96 * 2;

/// Esfera de raio 1 por paralelos e meridianos: `aneis` faixas de latitude,
/// `gomos` de longitude. Na esfera a normal é o próprio ponto.
pub fn esfera(aneis: usize, gomos: usize, pontos: []Vec3, normais: []Vec3, tris: []Tri) Malha {
    var np: usize = 0;
    for (0..aneis + 1) |i| {
        const teta = std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(aneis));
        for (0..gomos + 1) |j| {
            const fi = 2 * std.math.pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(gomos));
            const p = Vec3.v(@sin(teta) * @cos(fi), @cos(teta), -@sin(teta) * @sin(fi));
            pontos[np] = p;
            normais[np] = p;
            np += 1;
        }
    }
    var nt: usize = 0;
    for (0..aneis) |i| for (0..gomos) |j| {
        const a: u16 = @intCast(i * (gomos + 1) + j);
        const b: u16 = @intCast((i + 1) * (gomos + 1) + j);
        const quad = [2]Tri{ .{ a, b, b + 1 }, .{ a, b + 1, a + 1 } };
        for (quad) |t| {
            const p0 = pontos[t[0]];
            const p1 = pontos[t[1]];
            const p2 = pontos[t[2]];
            // Nos polos um lado tem tamanho zero: triângulo sem área, pula.
            const n = p1.menos(p0).vetorial(p2.menos(p0));
            if (n.tamanho() < 1e-7) continue;
            // Garante anti-horário visto de fora.
            tris[nt] = if (n.escalar(p0.mais(p1).mais(p2)) >= 0) t else .{ t[0], t[2], t[1] };
            nt += 1;
        }
    };
    return .{ .pontos = pontos[0..np], .normais = normais[0..np], .tris = tris[0..nt] };
}

/// Um vértice já na tela: posição em pixels, profundidade (z do NDC, −1
/// perto, 1 longe) e um atributo qualquer pra interpolar (cor, normal...).
pub const VTela = struct { x: f32, y: f32, z: f32, a: Vec3 };

pub const Raster = struct {
    tela: *Tela,
    area: Caixa,
    zbuf: []f32,
    usar_z: bool = true,
    /// Estatística pra mostrar na aula: quantas vezes um pixel foi pintado
    /// e quantas vezes o teste de profundidade recusou.
    escritas: usize = 0,
    recusados: usize = 0,

    pub fn limparZ(r: *Raster) void {
        @memset(r.zbuf, std.math.inf(f32));
        r.escritas = 0;
        r.recusados = 0;
    }

    /// Pinta o triângulo: pra cada pixel da caixa dele, as coordenadas
    /// baricêntricas (w0, w1, w2) dizem se está dentro e quanto de cada
    /// vértice vai no z e no atributo. `sombra.cor(atributo, x, y)` dá a cor.
    pub fn triangulo(r: *Raster, v0: VTela, v1: VTela, v2: VTela, sombra: anytype) void {
        const area = (v1.x - v0.x) * (v2.y - v0.y) - (v2.x - v0.x) * (v1.y - v0.y);
        if (@abs(area) < 1e-6) return;
        const cx = (Caixa{
            .x0 = @intFromFloat(@floor(@max(@min(v0.x, v1.x, v2.x), -1))),
            .y0 = @intFromFloat(@floor(@max(@min(v0.y, v1.y, v2.y), -1))),
            .x1 = @intFromFloat(@ceil(@min(@max(v0.x, v1.x, v2.x), 1e5)) + 1),
            .y1 = @intFromFloat(@ceil(@min(@max(v0.y, v1.y, v2.y), 1e5)) + 1),
        });
        const c = Caixa{
            .x0 = @max(cx.x0, r.area.x0),
            .y0 = @max(cx.y0, r.area.y0),
            .x1 = @min(cx.x1, r.area.x1),
            .y1 = @min(cx.y1, r.area.y1),
        };
        if (c.x0 >= c.x1 or c.y0 >= c.y1) return;
        const larg: usize = @intCast(r.area.x1 - r.area.x0);
        var y = c.y0;
        while (y < c.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var x = c.x0;
            while (x < c.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                // Função de aresta: de que lado de cada aresta o pixel está.
                const w0 = ((v2.x - v1.x) * (py - v1.y) - (px - v1.x) * (v2.y - v1.y)) / area;
                const w1 = ((v0.x - v2.x) * (py - v2.y) - (px - v2.x) * (v0.y - v2.y)) / area;
                const w2 = 1 - w0 - w1;
                if (w0 < 0 or w1 < 0 or w2 < 0) continue;
                const z = w0 * v0.z + w1 * v1.z + w2 * v2.z;
                const i = @as(usize, @intCast(y - r.area.y0)) * larg + @as(usize, @intCast(x - r.area.x0));
                if (r.usar_z) {
                    if (z >= r.zbuf[i]) {
                        r.recusados += 1;
                        continue;
                    }
                }
                r.zbuf[i] = @min(z, r.zbuf[i]);
                const a = v0.a.vezes(w0).mais(v1.a.vezes(w1)).mais(v2.a.vezes(w2));
                r.tela.ponto(x, y, sombra.cor(a, x, y));
                r.escritas += 1;
            }
        }
    }
};

pub fn corDe(rgb: Vec3) Cor {
    const r: u32 = @intFromFloat(@round(std.math.clamp(rgb.x, 0, 1) * 255));
    const g: u32 = @intFromFloat(@round(std.math.clamp(rgb.y, 0, 1) * 255));
    const b: u32 = @intFromFloat(@round(std.math.clamp(rgb.z, 0, 1) * 255));
    return opaco | (r << 16) | (g << 8) | b;
}

pub fn rgbDe(c: Cor) Vec3 {
    return Vec3.v(
        @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(c & 0xff)) / 255,
    );
}

const testing = std.testing;

test "Mat4: perspectiva divide por w (longe encolhe)" {
    const p = Mat4.perspectiva(std.math.pi / 2.0, 0.1, 100);
    const perto = p.ponto(Vec3.v(1, 0, -2));
    const longe = p.ponto(Vec3.v(1, 0, -4));
    try testing.expectApproxEqAbs(@as(f32, 0.5), perto.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), longe.x, 1e-5);
    try testing.expect(perto.z < longe.z);
}

test "cubo: normais apontam pra fora e triângulos anti-horários vistos de fora" {
    var p: [24]Vec3 = undefined;
    var n: [24]Vec3 = undefined;
    var t: [12]Tri = undefined;
    const m = cubo(&p, &n, &t);
    for (m.tris) |tri| {
        const a = m.pontos[tri[0]];
        const nf = m.pontos[tri[1]].menos(a).vetorial(m.pontos[tri[2]].menos(a));
        try testing.expect(nf.escalar(m.normais[tri[0]]) > 0);
    }
}

test "esfera: triângulos virados pra fora" {
    var p: [max_pontos_esfera]Vec3 = undefined;
    var n: [max_pontos_esfera]Vec3 = undefined;
    var t: [max_tris_esfera]Tri = undefined;
    const m = esfera(8, 12, &p, &n, &t);
    try testing.expect(m.tris.len > 100);
    for (m.tris) |tri| {
        const a = m.pontos[tri[0]];
        const nf = a.menos(a).mais(m.pontos[tri[1]].menos(a)).vetorial(m.pontos[tri[2]].menos(a));
        try testing.expect(nf.escalar(a.mais(m.pontos[tri[1]]).mais(m.pontos[tri[2]])) > 0);
    }
}

test "raster: z-buffer deixa o mais perto na frente, não importa a ordem" {
    var t = try Tela.criar(testing.allocator, 10, 10, opaco);
    defer t.destruir();
    const zb = try testing.allocator.alloc(f32, 100);
    defer testing.allocator.free(zb);
    var r = Raster{ .tela = &t, .area = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }, .zbuf = zb };
    r.limparZ();
    const Liso = struct {
        c: Cor,
        pub fn cor(s: @This(), _: Vec3, _: i32, _: i32) Cor {
            return s.c;
        }
    };
    const z0 = Vec3.v(0, 0, 0);
    // Perto (z = 0) primeiro, longe (z = 0.5) depois: o de longe não aparece.
    r.triangulo(.{ .x = 0, .y = 0, .z = 0, .a = z0 }, .{ .x = 10, .y = 0, .z = 0, .a = z0 }, .{ .x = 0, .y = 10, .z = 0, .a = z0 }, Liso{ .c = opaco | 0xff0000 });
    r.triangulo(.{ .x = 0, .y = 0, .z = 0.5, .a = z0 }, .{ .x = 10, .y = 0, .z = 0.5, .a = z0 }, .{ .x = 0, .y = 10, .z = 0.5, .a = z0 }, Liso{ .c = opaco | 0x00ff00 });
    try testing.expectEqual(opaco | 0xff0000, t.pixels[2 * 10 + 2]);
    try testing.expect(r.recusados > 0);
}
