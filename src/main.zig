const std = @import("std");
const x11 = @import("x11.zig");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const opaco = tela_.opaco;
const Mat3 = @import("mat3.zig").Mat3;
const Documento = @import("camada.zig").Documento;

const papel = opaco | 0xf4f1ea;
const mesa = opaco | 0x3a3a3c;
const tinta = opaco | 0x1d1d1f;
const cor_selecao = opaco | 0x2f7df6;
const cor_barra = opaco | 0x1c1c1e;
const cor_texto_barra = opaco | 0xe8e6e1;
const raio_pincel = 2;
const fonte = @import("fonte.zig");

const passo_giro = std.math.pi / 12.0; // 15°
const passo_zoom = 1.1;

// Posições físicas das teclas (as mesmas em qualquer layout; os nomes são
// do teclado americano).
const tecla = struct {
    const esc = 9;
    const menos = 20;
    const igual = 21;
    const zero = 19;
    const tab = 23;
    const q = 24;
    const e = 26;
    const r = 27;
    const c = 54;
    const v = 55;
    const b = 56;
    const n = 57;
    const shift_esq = 50;
    const shift_dir = 62;
    const page_up = 112;
    const page_down = 117;
    const delete = 119;
};

// Botões do mouse no X11: 1 esquerdo, 3 direito, 4 e 5 a rodinha.
const botao = struct {
    const esquerdo = 1;
    const direito = 3;
    const rodinha_cima = 4;
    const rodinha_baixo = 5;
};

const Modo = enum { pincel, mover };
const PontoInt = struct { x: i32, y: i32 };

fn paraInt(v: f32) i32 {
    return @intFromFloat(@floor(std.math.clamp(v, -1e6, 1e6)));
}

const altura_barra = fonte.altura + 8;

/// Faixa no rodapé com o modo e a camada selecionada.
fn barraDeEstado(tela: *Tela, modo: Modo, doc: *const Documento) void {
    const topo = @as(i32, tela.altura) - altura_barra;
    tela.retangulo(.{ .x0 = 0, .y0 = topo, .x1 = tela.largura, .y1 = tela.altura }, cor_barra);
    var buf: [128]u8 = undefined;
    const nome_modo = switch (modo) {
        .pincel => "Pincel (b)",
        .mover => "Mover (v)",
    };
    const texto = std.fmt.bufPrint(&buf, "{s}   ·   camada {d} de {d}", .{ nome_modo, doc.selecionada + 1, doc.camadas.items.len }) catch return;
    _ = fonte.escrever(tela, 10, topo + 4, texto, cor_texto_barra, 1);
}

pub fn main(init: std.process.Init) !void {
    var janela = try x11.Janela.abrir(init.gpa, init.environ_map, "editor", 900, 600);
    defer janela.fechar();

    var doc = try Documento.criar(init.gpa, 900, 600, papel);
    defer doc.destruir();
    try doc.novaCamada(); // começa já com uma camada transparente pra desenhar
    var tela = try Tela.criar(init.gpa, 900, 600, mesa);
    defer tela.destruir();

    // folha → janela. Zoom, arrastar e girar a VISTA não mexem nas camadas.
    var vista = Mat3.identidade;
    var modo: Modo = .pincel;
    var shift = false;
    // Enquanto um botão está apertado, onde ele estava por último
    // (o pincel em coordenadas da camada; os arrastos na janela).
    var pincel: ?PontoInt = null;
    var arrasto_camada: ?PontoInt = null;
    var arrasto_vista: ?PontoInt = null;
    var mudou = true;
    var contar = true;

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
                .tecla => |t| {
                    if (t.codigo == tecla.shift_esq or t.codigo == tecla.shift_dir) {
                        shift = t.apertou;
                        continue;
                    }
                    if (!t.apertou) continue;
                    const centro_janela_x: f32 = @as(f32, @floatFromInt(tela.largura)) / 2;
                    const centro_janela_y: f32 = @as(f32, @floatFromInt(tela.altura)) / 2;
                    const c = doc.centroNaJanela(vista);
                    switch (t.codigo) {
                        tecla.esc => break :laco,
                        tecla.b => modo = .pincel,
                        tecla.v => modo = .mover,
                        tecla.n => try doc.novaCamada(),
                        tecla.delete => doc.apagar(),
                        tecla.tab => doc.selecionada = if (shift)
                            (doc.selecionada + doc.camadas.items.len - 1) % doc.camadas.items.len
                        else
                            (doc.selecionada + 1) % doc.camadas.items.len,
                        tecla.page_up => doc.mover(1),
                        tecla.page_down => doc.mover(-1),
                        tecla.c => doc.atual().limpar(),
                        tecla.r => doc.atual().matriz = Mat3.identidade,
                        tecla.zero => vista = Mat3.identidade,
                        // q/e giram a camada em torno do centro dela; com shift, a vista.
                        tecla.q, tecla.e => {
                            const ang: f32 = if (t.codigo == tecla.q) -passo_giro else passo_giro;
                            if (shift) {
                                vista = Mat3.rotacao(ang).emTornoDe(centro_janela_x, centro_janela_y).vezes(vista);
                            } else {
                                doc.transformar(vista, Mat3.rotacao(ang).emTornoDe(c.x, c.y));
                            }
                        },
                        tecla.menos, tecla.igual => {
                            const s: f32 = if (t.codigo == tecla.igual) passo_zoom else 1.0 / passo_zoom;
                            doc.transformar(vista, Mat3.escala(s, s).emTornoDe(c.x, c.y));
                        },
                        else => continue,
                    }
                    mudou = true;
                    contar = true;
                },
                .botao => |b| switch (b.numero) {
                    botao.esquerdo => {
                        if (!b.apertou) {
                            pincel = null;
                            arrasto_camada = null;
                            continue;
                        }
                        switch (modo) {
                            .pincel => {
                                const inv = doc.atual().naJanela(vista).inversa() orelse continue;
                                const p = inv.aplicar(@as(f32, @floatFromInt(b.x)) + 0.5, @as(f32, @floatFromInt(b.y)) + 0.5);
                                const q: PontoInt = .{ .x = paraInt(p.x), .y = paraInt(p.y) };
                                doc.atual().pincel(q.x, q.y, q.x, q.y, raio_pincel, tinta);
                                pincel = q;
                            },
                            .mover => {
                                if (doc.tocar(vista, b.x, b.y)) |i| doc.selecionada = i;
                                arrasto_camada = .{ .x = b.x, .y = b.y };
                                contar = true;
                            },
                        }
                        mudou = true;
                    },
                    botao.direito => arrasto_vista = if (b.apertou) .{ .x = b.x, .y = b.y } else null,
                    // Zoom da vista em torno do cursor: o ponto embaixo do mouse fica parado.
                    botao.rodinha_cima, botao.rodinha_baixo => if (b.apertou) {
                        const s: f32 = if (b.numero == botao.rodinha_cima) passo_zoom else 1.0 / passo_zoom;
                        vista = Mat3.escala(s, s).emTornoDe(@floatFromInt(b.x), @floatFromInt(b.y)).vezes(vista);
                        mudou = true;
                    },
                    else => {},
                },
                .movimento => |m| {
                    // O mouse anda mais rápido que os eventos chegam: ligar o ponto
                    // anterior ao atual com uma linha é o que evita o traço pontilhado.
                    if (pincel) |*p| {
                        if (doc.atual().naJanela(vista).inversa()) |inv| {
                            const f = inv.aplicar(@as(f32, @floatFromInt(m.x)) + 0.5, @as(f32, @floatFromInt(m.y)) + 0.5);
                            const q: PontoInt = .{ .x = paraInt(f.x), .y = paraInt(f.y) };
                            doc.atual().pincel(p.x, p.y, q.x, q.y, raio_pincel, tinta);
                            p.* = q;
                            mudou = true;
                        }
                    }
                    if (arrasto_camada) |*a| {
                        doc.transformar(vista, Mat3.translacao(@floatFromInt(m.x - a.x), @floatFromInt(m.y - a.y)));
                        a.* = .{ .x = m.x, .y = m.y };
                        mudou = true;
                    }
                    if (arrasto_vista) |*a| {
                        vista = Mat3.translacao(@floatFromInt(m.x - a.x), @floatFromInt(m.y - a.y)).vezes(vista);
                        a.* = .{ .x = m.x, .y = m.y };
                        mudou = true;
                    }
                },
            }
        }
        if (mudou or contar) {
            tela.limpar(mesa);
            doc.desenhar(&tela, vista);
            if (modo == .mover) doc.contorno(&tela, vista, cor_selecao);
            barraDeEstado(&tela, modo, &doc);
            try janela.mostrar(tela.pixels, tela.largura, tela.altura);
            mudou = false;
            contar = false;
        }
    }
}

test {
    _ = @import("x11.zig");
    _ = @import("tela.zig");
    _ = @import("mat3.zig");
    _ = @import("camada.zig");
    _ = @import("fonte.zig");
}
