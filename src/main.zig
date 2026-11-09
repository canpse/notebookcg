const std = @import("std");
const x11 = @import("x11.zig");
const Tela = @import("tela.zig").Tela;
const Mat3 = @import("mat3.zig").Mat3;

const papel = 0xf4f1ea;
const mesa = 0x3a3a3c;
const tinta = 0x1d1d1f;
const raio_pincel = 2;

const passo_giro = std.math.pi / 12.0; // 15°
const passo_zoom = 1.1;

// Posições físicas das teclas (as mesmas em qualquer layout).
const tecla_esc = 9;
const tecla_c = 54;
const tecla_q = 24;
const tecla_e = 26;
const tecla_0 = 19;

// Botões do mouse no X11: 1 esquerdo, 3 direito, 4 e 5 a rodinha.
const botao_desenhar = 1;
const botao_arrastar = 3;
const rodinha_cima = 4;
const rodinha_baixo = 5;

const PontoInt = struct { x: i32, y: i32 };

/// O desenho mora na `folha`; a janela mostra a folha passando pela matriz
/// `vista` (folha → janela). Girar, dar zoom e arrastar só mexem na vista.
/// O mouse faz o caminho de volta com a inversa: janela → folha.
const Editor = struct {
    vista: Mat3 = Mat3.identidade,
    inversa: Mat3 = Mat3.identidade,

    /// Aplica `t` depois da vista atual, em coordenadas da janela.
    fn transformar(ed: *Editor, t: Mat3) void {
        const nova = t.vezes(ed.vista);
        // Uma vista sem inversa (zoom 0) travaria o mouse: ignora.
        const inv = nova.inversa() orelse return;
        ed.vista = nova;
        ed.inversa = inv;
    }

    fn naFolha(ed: *const Editor, x: i32, y: i32) PontoInt {
        const p = ed.inversa.aplicar(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
        const limite = 1e6;
        return .{
            .x = @intFromFloat(@floor(std.math.clamp(p.x, -limite, limite))),
            .y = @intFromFloat(@floor(std.math.clamp(p.y, -limite, limite))),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var janela = try x11.Janela.abrir(init.gpa, init.environ_map, "editor", 900, 600);
    defer janela.fechar();
    std.debug.print("janela 0x{x} aberta\n", .{janela.id});

    var folha = try Tela.criar(init.gpa, 900, 600, papel);
    defer folha.destruir();
    var tela = try Tela.criar(init.gpa, 900, 600, mesa);
    defer tela.destruir();

    var ed: Editor = .{};
    // Enquanto o botão está apertado, guarda onde estava por último
    // (o pincel em coordenadas da folha, o arrasto em coordenadas da janela).
    var pincel: ?PontoInt = null;
    var arrasto: ?PontoInt = null;
    var mudou = true;

    laco: while (true) {
        // Dorme até chegar um evento, trata todos os que já chegaram e só então redesenha.
        var evento = try janela.proximo(true);
        while (evento) |e| : (evento = try janela.proximo(false)) {
            switch (e) {
                .fechar => break :laco,
                .expor => mudou = true,
                .redimensionar => |r| {
                    try tela.redimensionar(r.largura, r.altura, mesa);
                    mudou = true;
                },
                .tecla => |t| if (t.apertou) {
                    const centro_x: f32 = @as(f32, @floatFromInt(tela.largura)) / 2;
                    const centro_y: f32 = @as(f32, @floatFromInt(tela.altura)) / 2;
                    switch (t.codigo) {
                        tecla_esc => break :laco,
                        tecla_c => folha.limpar(papel),
                        tecla_q => ed.transformar(Mat3.rotacao(-passo_giro).emTornoDe(centro_x, centro_y)),
                        tecla_e => ed.transformar(Mat3.rotacao(passo_giro).emTornoDe(centro_x, centro_y)),
                        tecla_0 => ed = .{},
                        else => continue,
                    }
                    mudou = true;
                },
                .botao => |b| switch (b.numero) {
                    botao_desenhar => if (b.apertou) {
                        const p = ed.naFolha(b.x, b.y);
                        folha.disco(p.x, p.y, raio_pincel, tinta);
                        pincel = p;
                        mudou = true;
                    } else {
                        pincel = null;
                    },
                    botao_arrastar => arrasto = if (b.apertou) .{ .x = b.x, .y = b.y } else null,
                    // Zoom em torno do cursor: o ponto embaixo do mouse fica parado.
                    rodinha_cima, rodinha_baixo => if (b.apertou) {
                        const s: f32 = if (b.numero == rodinha_cima) passo_zoom else 1.0 / passo_zoom;
                        ed.transformar(Mat3.escala(s, s).emTornoDe(@floatFromInt(b.x), @floatFromInt(b.y)));
                        mudou = true;
                    },
                    else => {},
                },
                .movimento => |m| {
                    // O mouse anda mais rápido que os eventos chegam: ligar o ponto
                    // anterior ao atual com uma linha é o que evita o traço pontilhado.
                    if (pincel) |*p| {
                        const q = ed.naFolha(m.x, m.y);
                        folha.linha(p.x, p.y, q.x, q.y, raio_pincel, tinta);
                        p.* = q;
                        mudou = true;
                    }
                    if (arrasto) |*a| {
                        ed.transformar(Mat3.translacao(@floatFromInt(m.x - a.x), @floatFromInt(m.y - a.y)));
                        a.* = .{ .x = m.x, .y = m.y };
                        mudou = true;
                    }
                },
            }
        }
        if (mudou) {
            tela.desenharTransformada(&folha, ed.inversa, mesa);
            try janela.mostrar(tela.pixels, tela.largura, tela.altura);
            mudou = false;
        }
    }
}

test {
    _ = @import("x11.zig");
    _ = @import("tela.zig");
    _ = @import("mat3.zig");
}
