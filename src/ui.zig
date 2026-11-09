//! Menus dentro da janela, desenhados pixel a pixel como todo o resto.
//!
//! A cada quadro `montar` calcula onde fica cada botão a partir do tamanho
//! da janela e do documento. A mesma lista serve pra desenhar e pra saber o
//! que foi clicado: o que aparece é exatamente o que responde ao mouse.
//!
//! Layout: barra no topo (adicionar objeto por modelo + modo), painel de
//! camadas à direita (de cima pra baixo como na pilha) e rodapé com dicas.
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const Caixa = tela_.Caixa;
const opaco = tela_.opaco;
const fonte = @import("fonte.zig");
const camada = @import("camada.zig");
const Documento = camada.Documento;
const Tipo = camada.Tipo;

pub const Modo = enum { pincel, mover };

pub const Acao = union(enum) {
    adicionar: Tipo,
    modo: Modo,
    selecionar: usize,
    subir,
    descer,
    apagar,
};

pub const altura_barra = fonte.altura + 12;
pub const largura_painel = 210;
pub const altura_rodape = fonte.altura + 8;
const altura_linha = fonte.altura + 8;

const cor = struct {
    const fundo = opaco | 0x1c1c1e;
    const borda = opaco | 0x3a3a3c;
    const texto = opaco | 0xe8e6e1;
    const apagado = opaco | 0x6e6e73;
    const titulo = opaco | 0x98989d;
    const sobre = opaco | 0x2c2c2e;
    const ligado = opaco | 0x2f7df6;
};

const Botao = struct {
    caixa: Caixa,
    acao: Acao,
    rotulo: []const u8,
    ligado: bool = false,
    /// Aparece, mas ainda não faz nada.
    desligado: bool = false,
};

pub const Layout = struct {
    botoes: [96]Botao = undefined,
    n: usize = 0,
    barra: Caixa,
    painel: Caixa,
    rodape: Caixa,

    fn por(l: *Layout, b: Botao) void {
        if (l.n == l.botoes.len) return;
        l.botoes[l.n] = b;
        l.n += 1;
    }

    /// O ponto cai em cima da interface (e não da folha)?
    pub fn dentro(l: *const Layout, x: i32, y: i32) bool {
        return l.barra.contem(x, y) or l.painel.contem(x, y) or l.rodape.contem(x, y);
    }

    /// Índice do botão embaixo do ponto.
    pub fn sobre(l: *const Layout, x: i32, y: i32) ?usize {
        for (l.botoes[0..l.n], 0..) |b, i| {
            if (b.caixa.contem(x, y)) return i;
        }
        return null;
    }

    /// Ação do botão clicado (botão desligado não responde).
    pub fn clicar(l: *const Layout, x: i32, y: i32) ?Acao {
        const i = l.sobre(x, y) orelse return null;
        const b = l.botoes[i];
        return if (b.desligado) null else b.acao;
    }
};

const tipos_na_barra = [_]Tipo{ .desenho, .retangulo, .elipse, .texto, .imagem };
const rotulos_na_barra = [_][]const u8{ "+ Desenho", "+ Retângulo", "+ Elipse", "+ Texto", "+ Imagem" };

pub fn montar(largura: u16, altura: u16, doc: *const Documento, modo: Modo) Layout {
    const w: i32 = largura;
    const h: i32 = altura;
    var l: Layout = .{
        .barra = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = altura_barra },
        .painel = .{ .x0 = w - largura_painel, .y0 = altura_barra, .x1 = w, .y1 = h - altura_rodape },
        .rodape = .{ .x0 = 0, .y0 = h - altura_rodape, .x1 = w, .y1 = h },
    };

    // Barra: um botão por modelo, da esquerda pra direita.
    var x: i32 = 6;
    for (tipos_na_barra, rotulos_na_barra) |t, r| {
        const bw = fonte.medir(r, 1) + 16;
        l.por(.{ .caixa = .{ .x0 = x, .y0 = 3, .x1 = x + bw, .y1 = altura_barra - 3 }, .acao = .{ .adicionar = t }, .rotulo = r, .desligado = t == .imagem });
        x += bw + 4;
    }
    // Modos, encostados na direita.
    x = w - 6;
    const modos = [_]struct { m: Modo, r: []const u8 }{ .{ .m = .mover, .r = "Mover" }, .{ .m = .pincel, .r = "Pincel" } };
    for (modos) |m| {
        const bw = fonte.medir(m.r, 1) + 16;
        x -= bw;
        l.por(.{ .caixa = .{ .x0 = x, .y0 = 3, .x1 = x + bw, .y1 = altura_barra - 3 }, .acao = .{ .modo = m.m }, .rotulo = m.r, .ligado = modo == m.m });
        x -= 4;
    }

    // Painel: título, uma linha por camada (a de cima primeiro) e, embaixo,
    // os botões da pilha.
    const p = l.painel;
    const y_botoes = p.y1 - altura_linha - 4;
    var y = p.y0 + altura_linha + 4;
    var i = doc.camadas.items.len;
    while (i > 0 and y + altura_linha <= y_botoes) {
        i -= 1;
        l.por(.{ .caixa = .{ .x0 = p.x0 + 4, .y0 = y, .x1 = p.x1 - 4, .y1 = y + altura_linha }, .acao = .{ .selecionar = i }, .rotulo = doc.camadas.items[i].nome(), .ligado = i == doc.selecionada });
        y += altura_linha + 2;
    }
    const pilha = [_]struct { a: Acao, r: []const u8 }{ .{ .a = .subir, .r = "Subir" }, .{ .a = .descer, .r = "Descer" }, .{ .a = .apagar, .r = "Apagar" } };
    const terco = @divTrunc(p.x1 - p.x0 - 8, 3);
    for (pilha, 0..) |b, k| {
        const x0 = p.x0 + 4 + @as(i32, @intCast(k)) * terco;
        l.por(.{ .caixa = .{ .x0 = x0, .y0 = y_botoes, .x1 = x0 + terco - 2, .y1 = y_botoes + altura_linha }, .acao = b.a, .rotulo = b.r });
    }
    return l;
}

fn centralizado(t: *Tela, c: Caixa, texto: []const u8, cor_texto: Cor) void {
    const x = c.x0 + @divTrunc(c.x1 - c.x0 - fonte.medir(texto, 1), 2);
    const y = c.y0 + @divTrunc(c.y1 - c.y0 - fonte.altura, 2);
    _ = fonte.escrever(t, x, y, texto, cor_texto, 1);
}

pub fn desenhar(t: *Tela, l: *const Layout, sobre: ?usize, doc: *Documento, modo: Modo) void {
    t.retangulo(l.barra, cor.fundo);
    t.retangulo(l.painel, cor.fundo);
    t.retangulo(.{ .x0 = l.painel.x0, .y0 = l.painel.y0, .x1 = l.painel.x0 + 1, .y1 = l.painel.y1 }, cor.borda);
    t.retangulo(.{ .x0 = 0, .y0 = l.barra.y1 - 1, .x1 = l.barra.x1, .y1 = l.barra.y1 }, cor.borda);
    t.retangulo(l.rodape, cor.fundo);
    _ = fonte.escrever(t, l.painel.x0 + 10, l.painel.y0 + 8, "CAMADAS", cor.titulo, 1);

    for (l.botoes[0..l.n], 0..) |b, i| {
        const fundo: ?Cor = if (b.ligado) cor.ligado else if (sobre == i and !b.desligado) cor.sobre else null;
        if (fundo) |f| t.retangulo(b.caixa, f);
        const cor_texto = if (b.desligado) cor.apagado else cor.texto;
        switch (b.acao) {
            // Linhas de camada: nome alinhado à esquerda.
            .selecionar => _ = fonte.escrever(t, b.caixa.x0 + 8, b.caixa.y0 + 4, b.rotulo, cor_texto, 1),
            else => centralizado(t, b.caixa, b.rotulo, cor_texto),
        }
    }

    // Rodapé: o que dá pra fazer agora.
    var buf: [160]u8 = undefined;
    const dica = switch (modo) {
        .pincel => "arraste pra desenhar (se não for desenho, cria um)",
        .mover => "clique seleciona · arraste move · q/e gira · -/= escala · r desfaz",
    };
    const texto = std.fmt.bufPrint(&buf, "{s}  ·  {s}", .{ doc.atual().nome(), dica }) catch return;
    _ = fonte.escrever(t, 10, l.rodape.y0 + 4, texto, cor.texto, 1);
}

const testing = std.testing;

test "clicar num botão da barra dá a ação dele; o de imagem ainda não responde" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    const l = montar(900, 600, &d, .pincel);
    const ret = l.botoes[1].caixa;
    try testing.expectEqual(Acao{ .adicionar = .retangulo }, l.clicar(ret.x0 + 2, ret.y0 + 2).?);
    const img = l.botoes[4].caixa;
    try testing.expectEqual(@as(?Acao, null), l.clicar(img.x0 + 2, img.y0 + 2));
    try testing.expect(l.dentro(5, 5));
    try testing.expect(!l.dentro(300, 300));
}

test "painel lista as camadas de cima pra baixo" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 50, .y = 50 });
    const l = montar(900, 600, &d, .mover);
    var linhas: [4]usize = undefined;
    var n: usize = 0;
    for (l.botoes[0..l.n]) |b| switch (b.acao) {
        .selecionar => |i| {
            linhas[n] = i;
            n += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), linhas[0]);
    try testing.expectEqual(@as(usize, 0), linhas[1]);
}
