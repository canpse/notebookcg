//! Matriz 3×3 em coordenadas homogêneas.
//!
//! Um ponto 2D (x, y) vira o vetor (x, y, 1). Com esse 1 a mais, translação,
//! escala e rotação viram todas multiplicação de matriz, e uma sequência de
//! transformações vira uma matriz só (o produto delas). É o que o editor usa
//! pra mostrar a folha na janela: girada, com zoom e arrastada.
const std = @import("std");

pub const Ponto = struct { x: f32, y: f32 };

pub const Mat3 = struct {
    /// m[linha][coluna]
    m: [3][3]f32,

    pub const identidade: Mat3 = .{ .m = .{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    } };

    /// Soma (tx, ty) a todo ponto. Só existe como matriz por causa do 1 extra:
    /// a última coluna é multiplicada por ele.
    pub fn translacao(tx: f32, ty: f32) Mat3 {
        return .{ .m = .{
            .{ 1, 0, tx },
            .{ 0, 1, ty },
            .{ 0, 0, 1 },
        } };
    }

    /// Estica em relação à origem (0, 0).
    pub fn escala(sx: f32, sy: f32) Mat3 {
        return .{ .m = .{
            .{ sx, 0, 0 },
            .{ 0, sy, 0 },
            .{ 0, 0, 1 },
        } };
    }

    /// Gira em torno da origem. Na tela o y cresce pra baixo, então ângulo
    /// positivo gira no sentido horário.
    pub fn rotacao(radianos: f32) Mat3 {
        const c = @cos(radianos);
        const s = @sin(radianos);
        return .{ .m = .{
            .{ c, -s, 0 },
            .{ s, c, 0 },
            .{ 0, 0, 1 },
        } };
    }

    /// Produto a·b. Aplicado num ponto, faz primeiro `b` e depois `a`
    /// (a matriz mais à direita é a que encosta no ponto).
    pub fn vezes(a: Mat3, b: Mat3) Mat3 {
        var r: Mat3 = undefined;
        for (0..3) |i| {
            for (0..3) |j| {
                var soma: f32 = 0;
                for (0..3) |k| soma += a.m[i][k] * b.m[k][j];
                r.m[i][j] = soma;
            }
        }
        return r;
    }

    /// A mesma transformação, mas usando (cx, cy) como centro em vez da
    /// origem: leva o centro pra origem, transforma e devolve.
    pub fn emTornoDe(t: Mat3, cx: f32, cy: f32) Mat3 {
        return translacao(cx, cy).vezes(t).vezes(translacao(-cx, -cy));
    }

    pub fn aplicar(t: Mat3, x: f32, y: f32) Ponto {
        const m = t.m;
        // Em transformações afins w é sempre 1; dividir deixa a função
        // correta também pra projeções.
        const w = m[2][0] * x + m[2][1] * y + m[2][2];
        return .{
            .x = (m[0][0] * x + m[0][1] * y + m[0][2]) / w,
            .y = (m[1][0] * x + m[1][1] * y + m[1][2]) / w,
        };
    }

    /// Inversa pela adjunta: cofatores transpostos divididos pelo
    /// determinante. Sem inversa (determinante 0, ex. escala 0) devolve null.
    pub fn inversa(t: Mat3) ?Mat3 {
        const m = t.m;
        // Num 3×3, pegar as linhas e colunas "seguintes" em ciclo já dá o
        // cofator com o sinal certo.
        var cof: [3][3]f32 = undefined;
        for (0..3) |i| {
            const ia = (i + 1) % 3;
            const ib = (i + 2) % 3;
            for (0..3) |j| {
                const ja = (j + 1) % 3;
                const jb = (j + 2) % 3;
                cof[i][j] = m[ia][ja] * m[ib][jb] - m[ia][jb] * m[ib][ja];
            }
        }
        const det = m[0][0] * cof[0][0] + m[0][1] * cof[0][1] + m[0][2] * cof[0][2];
        if (@abs(det) < 1e-12) return null;
        var r: Mat3 = undefined;
        for (0..3) |i| {
            for (0..3) |j| r.m[i][j] = cof[j][i] / det;
        }
        return r;
    }
};

const testing = std.testing;

fn pertoDe(esperado: Ponto, p: Ponto) !void {
    try testing.expectApproxEqAbs(esperado.x, p.x, 1e-4);
    try testing.expectApproxEqAbs(esperado.y, p.y, 1e-4);
}

test "translação, escala e rotação num ponto" {
    try pertoDe(.{ .x = 4, .y = 7 }, Mat3.translacao(3, 5).aplicar(1, 2));
    try pertoDe(.{ .x = 2, .y = 6 }, Mat3.escala(2, 3).aplicar(1, 2));
    // 90° leva o eixo x no eixo y (pra baixo, na tela).
    try pertoDe(.{ .x = 0, .y = 1 }, Mat3.rotacao(std.math.pi / 2.0).aplicar(1, 0));
}

test "a ordem importa: girar e depois mover é diferente de mover e depois girar" {
    const r = Mat3.rotacao(std.math.pi / 2.0);
    const t = Mat3.translacao(10, 0);
    try pertoDe(.{ .x = 10, .y = 1 }, t.vezes(r).aplicar(1, 0));
    try pertoDe(.{ .x = 0, .y = 11 }, r.vezes(t).aplicar(1, 0));
}

test "em torno de um ponto, o ponto fica parado" {
    const m = Mat3.rotacao(0.7).vezes(Mat3.escala(3, 3)).emTornoDe(50, 20);
    try pertoDe(.{ .x = 50, .y = 20 }, m.aplicar(50, 20));
}

test "inversa desfaz" {
    const m = Mat3.translacao(30, -4).vezes(Mat3.rotacao(1.1)).vezes(Mat3.escala(2, 0.5));
    const inv = m.inversa().?;
    const p = m.aplicar(7, 9);
    try pertoDe(.{ .x = 7, .y = 9 }, inv.aplicar(p.x, p.y));
    try testing.expect(Mat3.escala(0, 1).inversa() == null);
}
