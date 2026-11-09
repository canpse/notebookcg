const std = @import("std");
const x11 = @import("x11.zig");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const opaco = tela_.opaco;
const m3 = @import("mat3.zig");
const Mat3 = m3.Mat3;
const Ponto = m3.Ponto;
const Documento = @import("camada.zig").Documento;
const ui = @import("ui.zig");
const Modo = ui.Modo;

const papel = opaco | 0xf4f1ea;
const mesa = opaco | 0x3a3a3c;
const tinta = opaco | 0x1d1d1f;
const cor_selecao = opaco | 0x2f7df6;
const raio_pincel = 2;

const largura_folha = 900;
const altura_folha = 600;

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

const PontoInt = struct { x: i32, y: i32 };

fn paraInt(v: f32) i32 {
    return @intFromFloat(@floor(std.math.clamp(v, -1e6, 1e6)));
}

fn centroDaArea(tela: *const Tela) Ponto {
    const w: f32 = @floatFromInt(@as(i32, tela.largura) - ui.largura_painel);
    const h: f32 = @floatFromInt(@as(i32, tela.altura) - ui.altura_barra - ui.altura_rodape);
    return .{ .x = w / 2, .y = @as(f32, ui.altura_barra) + h / 2 };
}

/// Vista que encaixa a folha inteira na área livre (fora dos menus).
fn vistaInicial(tela: *const Tela) Mat3 {
    const w: f32 = @floatFromInt(@max(1, @as(i32, tela.largura) - ui.largura_painel));
    const h: f32 = @floatFromInt(@max(1, @as(i32, tela.altura) - ui.altura_barra - ui.altura_rodape));
    const s = @min(1, 0.94 * @min(w / largura_folha, h / altura_folha));
    const c = centroDaArea(tela);
    return Mat3.translacao(c.x, c.y).vezes(Mat3.escala(s, s)).vezes(Mat3.translacao(-largura_folha / 2.0, -altura_folha / 2.0));
}

/// Ponto da janela levado pra dentro da camada selecionada.
fn naCamada(doc: *Documento, vista: Mat3, x: i32, y: i32) ?PontoInt {
    const inv = doc.atual().naJanela(vista).inversa() orelse return null;
    const p = inv.aplicar(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
    return .{ .x = paraInt(p.x), .y = paraInt(p.y) };
}

pub fn main(init: std.process.Init) !void {
    var janela = try x11.Janela.abrir(init.gpa, init.environ_map, "editor", 1200, 760);
    defer janela.fechar();

    var doc = try Documento.criar(init.gpa, largura_folha, altura_folha, papel);
    defer doc.destruir();
    var tela = try Tela.criar(init.gpa, 1200, 760, mesa);
    defer tela.destruir();

    // folha → janela. Zoom, arrastar e girar a VISTA não mexem nas camadas.
    var vista = vistaInicial(&tela);
    var modo: Modo = .pincel;
    var shift = false;
    // Enquanto um botão está apertado, onde ele estava por último
    // (o pincel em coordenadas da camada; os arrastos na janela).
    var pincel: ?PontoInt = null;
    var arrasto_camada: ?PontoInt = null;
    var arrasto_vista: ?PontoInt = null;
    // Botão do menu embaixo do mouse (fica destacado).
    var sobre: ?usize = null;
    var mudou = true;

    laco: while (true) {
        // Dorme até chegar um evento, trata todos os que já chegaram e só então redesenha.
        var evento = try janela.proximo(true);
        while (evento) |e| : (evento = try janela.proximo(false)) {
            const layout = ui.montar(tela.largura, tela.altura, &doc, modo);
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
                    const cj = centroDaArea(&tela);
                    const c = doc.centroNaJanela(vista);
                    switch (t.codigo) {
                        tecla.esc => break :laco,
                        tecla.b => modo = .pincel,
                        tecla.v => modo = .mover,
                        tecla.n => try doc.adicionar(.desenho, .{ .x = 0, .y = 0 }),
                        tecla.delete => doc.apagar(),
                        tecla.tab => doc.selecionada = if (shift)
                            (doc.selecionada + doc.camadas.items.len - 1) % doc.camadas.items.len
                        else
                            (doc.selecionada + 1) % doc.camadas.items.len,
                        tecla.page_up => doc.mover(1),
                        tecla.page_down => doc.mover(-1),
                        tecla.c => doc.atual().limpar(),
                        tecla.r => doc.atual().matriz = Mat3.identidade,
                        tecla.zero => vista = vistaInicial(&tela),
                        // q/e giram a camada em torno do centro dela; com shift, a vista.
                        tecla.q, tecla.e => {
                            const ang: f32 = if (t.codigo == tecla.q) -passo_giro else passo_giro;
                            if (shift) {
                                vista = Mat3.rotacao(ang).emTornoDe(cj.x, cj.y).vezes(vista);
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
                },
                .botao => |b| {
                    // Clique em cima do menu é do menu, não da folha.
                    if (b.apertou and layout.dentro(b.x, b.y)) {
                        if (b.numero != botao.esquerdo) continue;
                        const acao = layout.clicar(b.x, b.y) orelse continue;
                        switch (acao) {
                            .adicionar => |tipo| {
                                const inv = vista.inversa() orelse continue;
                                const cj = centroDaArea(&tela);
                                try doc.adicionar(tipo, inv.aplicar(cj.x, cj.y));
                                modo = if (tipo == .desenho) .pincel else .mover;
                            },
                            .modo => |m| modo = m,
                            .selecionar => |i| doc.selecionada = i,
                            .subir => doc.mover(1),
                            .descer => doc.mover(-1),
                            .apagar => doc.apagar(),
                        }
                        mudou = true;
                        continue;
                    }
                    switch (b.numero) {
                        botao.esquerdo => {
                            if (!b.apertou) {
                                pincel = null;
                                arrasto_camada = null;
                                continue;
                            }
                            switch (modo) {
                                .pincel => {
                                    // O pincel só pinta em camada de desenho; em
                                    // outro modelo, abre um desenho novo por cima.
                                    if (doc.atual().modelo != .desenho) try doc.adicionar(.desenho, .{ .x = 0, .y = 0 });
                                    const q = naCamada(&doc, vista, b.x, b.y) orelse continue;
                                    doc.atual().pincel(q.x, q.y, q.x, q.y, raio_pincel, tinta);
                                    pincel = q;
                                },
                                .mover => {
                                    if (doc.tocar(vista, b.x, b.y)) |i| doc.selecionada = i;
                                    arrasto_camada = .{ .x = b.x, .y = b.y };
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
                    }
                },
                .movimento => |m| {
                    const novo_sobre = layout.sobre(m.x, m.y);
                    if (!std.meta.eql(novo_sobre, sobre)) {
                        sobre = novo_sobre;
                        mudou = true;
                    }
                    // O mouse anda mais rápido que os eventos chegam: ligar o ponto
                    // anterior ao atual com uma linha é o que evita o traço pontilhado.
                    if (pincel) |*p| {
                        if (naCamada(&doc, vista, m.x, m.y)) |q| {
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
        if (mudou) {
            tela.limpar(mesa);
            doc.desenhar(&tela, vista);
            if (modo == .mover) doc.contorno(&tela, vista, cor_selecao);
            const layout = ui.montar(tela.largura, tela.altura, &doc, modo);
            ui.desenhar(&tela, &layout, sobre, &doc, modo);
            try janela.mostrar(tela.pixels, tela.largura, tela.altura);
            mudou = false;
        }
    }
}

test {
    _ = @import("x11.zig");
    _ = @import("tela.zig");
    _ = @import("mat3.zig");
    _ = @import("camada.zig");
    _ = @import("fonte.zig");
    _ = @import("ui.zig");
}
