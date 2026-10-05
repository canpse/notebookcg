const std = @import("std");
const x11 = @import("x11.zig");
const Tela = @import("tela.zig").Tela;

const papel = 0xf4f1ea;
const tinta = 0x1d1d1f;
const raio_pincel = 2;

// Posições físicas das teclas (as mesmas em qualquer layout).
const tecla_esc = 9;
const tecla_c = 54;

pub fn main(init: std.process.Init) !void {
    var janela = try x11.Janela.abrir(init.gpa, init.environ_map, "editor", 900, 600);
    defer janela.fechar();
    std.debug.print("janela 0x{x} aberta\n", .{janela.id});

    var tela = try Tela.criar(init.gpa, 900, 600, papel);
    defer tela.destruir();

    // Enquanto o botão está apertado, guarda onde o pincel estava por último.
    var pincel: ?struct { x: i32, y: i32 } = null;
    var mudou = true;

    laco: while (true) {
        // Dorme até chegar um evento, trata todos os que já chegaram e só então redesenha.
        var evento = try janela.proximo(true);
        while (evento) |e| : (evento = try janela.proximo(false)) {
            switch (e) {
                .fechar => break :laco,
                .expor => mudou = true,
                .redimensionar => |r| {
                    try tela.redimensionar(r.largura, r.altura, papel);
                    mudou = true;
                },
                .tecla => |t| if (t.apertou) switch (t.codigo) {
                    tecla_esc => break :laco,
                    tecla_c => {
                        tela.limpar(papel);
                        mudou = true;
                    },
                    else => {},
                },
                .botao => |b| if (b.numero == 1) {
                    if (b.apertou) {
                        tela.disco(b.x, b.y, raio_pincel, tinta);
                        pincel = .{ .x = b.x, .y = b.y };
                        mudou = true;
                    } else pincel = null;
                },
                // O mouse anda mais rápido que os eventos chegam: ligar o ponto
                // anterior ao atual com uma linha é o que evita o traço pontilhado.
                .movimento => |m| if (pincel) |*p| {
                    tela.linha(p.x, p.y, m.x, m.y, raio_pincel, tinta);
                    p.* = .{ .x = m.x, .y = m.y };
                    mudou = true;
                },
            }
        }
        if (mudou) {
            try janela.mostrar(tela.pixels, tela.largura, tela.altura);
            mudou = false;
        }
    }
}

test {
    _ = @import("x11.zig");
    _ = @import("tela.zig");
}
