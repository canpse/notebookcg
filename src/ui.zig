//! Menus dentro da janela, desenhados pixel a pixel como todo o resto.
//!
//! A cada quadro `montar` calcula onde fica cada botão a partir do tamanho
//! da janela e do documento. A mesma lista serve pra desenhar e pra saber o
//! que foi clicado: o que aparece é exatamente o que responde ao mouse.
//!
//! Layout: barra no topo (adicionar objeto por modelo + modo), painel à
//! direita com as camadas (de cima pra baixo como na pilha) e as
//! propriedades da selecionada, e rodapé com dicas.
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

/// O que a interface precisa saber do editor pra se montar.
pub const Estado = struct {
    modo: Modo,
    /// Cor do pincel (e a marcada na paleta quando a camada não tem cor).
    cor: Cor,
    /// Digitando no texto selecionado.
    editando: bool = false,
    /// Escolhendo imagem: a lista de arquivos aparece por cima de tudo.
    arquivos: ?[]const []u8 = null,
    pasta: []const u8 = "",
    rolagem: usize = 0,
    /// Recado no rodapé (ex.: a imagem não abriu).
    aviso: ?[]const u8 = null,
};

pub const Acao = union(enum) {
    adicionar: Tipo,
    modo: Modo,
    selecionar: usize,
    subir,
    descer,
    apagar,
    cor: Cor,
    editar_texto,
    abrir: usize,
    cancelar_abrir,
    salvar,
};

pub const paleta = [_]Cor{
    opaco | 0x1d1d1f, opaco | 0x8e8e93, opaco | 0xffffff, opaco | 0xef4444, opaco | 0xf59e0b, opaco | 0xfacc15,
    opaco | 0x10b981, opaco | 0x06b6d4, opaco | 0x2f7df6, opaco | 0x8b5cf6, opaco | 0xec4899, opaco | 0x92400e,
};

pub const altura_barra = fonte.altura + 12;
pub const largura_painel = 210;
pub const altura_rodape = fonte.altura + 8;
const altura_linha = fonte.altura + 8;
const lado_amostra = 26;

const cor = struct {
    const fundo = opaco | 0x1c1c1e;
    const borda = opaco | 0x3a3a3c;
    const texto = opaco | 0xe8e6e1;
    const apagado = opaco | 0x6e6e73;
    const titulo = opaco | 0x98989d;
    const sobre = opaco | 0x2c2c2e;
    const ligado = opaco | 0x2f7df6;
    const campo = opaco | 0x2c2c2e;
};

const Botao = struct {
    caixa: Caixa,
    acao: Acao,
    rotulo: []const u8 = "",
    ligado: bool = false,
    /// Aparece, mas ainda não faz nada.
    desligado: bool = false,
};

const Titulo = struct { x: i32, y: i32, texto: []const u8 };

pub const Layout = struct {
    botoes: [96]Botao = undefined,
    n: usize = 0,
    titulos: [4]Titulo = undefined,
    n_titulos: usize = 0,
    barra: Caixa,
    painel: Caixa,
    rodape: Caixa,
    /// Janela da lista de arquivos, quando aberta: enquanto isso, só ela responde.
    modal: ?Caixa = null,
    /// Quantas linhas de arquivo cabem (pra rolagem).
    linhas_visiveis: usize = 0,

    fn por(l: *Layout, b: Botao) void {
        if (l.n == l.botoes.len) return;
        l.botoes[l.n] = b;
        l.n += 1;
    }

    fn titulo(l: *Layout, x: i32, y: i32, texto: []const u8) void {
        if (l.n_titulos == l.titulos.len) return;
        l.titulos[l.n_titulos] = .{ .x = x, .y = y, .texto = texto };
        l.n_titulos += 1;
    }

    /// O ponto cai em cima da interface (e não da folha)?
    pub fn dentro(l: *const Layout, x: i32, y: i32) bool {
        if (l.modal != null) return true;
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

pub fn montar(largura: u16, altura: u16, doc: *Documento, estado: Estado) Layout {
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
        l.por(.{ .caixa = .{ .x0 = x, .y0 = 3, .x1 = x + bw, .y1 = altura_barra - 3 }, .acao = .{ .adicionar = t }, .rotulo = r });
        x += bw + 4;
    }
    // Modos, encostados na direita.
    x = w - 6;
    const modos = [_]struct { m: Modo, r: []const u8 }{ .{ .m = .mover, .r = "Mover" }, .{ .m = .pincel, .r = "Pincel" } };
    for (modos) |m| {
        const bw = fonte.medir(m.r, 1) + 16;
        x -= bw;
        l.por(.{ .caixa = .{ .x0 = x, .y0 = 3, .x1 = x + bw, .y1 = altura_barra - 3 }, .acao = .{ .modo = m.m }, .rotulo = m.r, .ligado = estado.modo == m.m });
        x -= 4;
    }
    {
        const r = "Salvar PPM";
        const bw = fonte.medir(r, 1) + 16;
        x -= bw + 16;
        l.por(.{ .caixa = .{ .x0 = x, .y0 = 3, .x1 = x + bw, .y1 = altura_barra - 3 }, .acao = .salvar, .rotulo = r });
    }

    // Painel, de baixo pra cima: botões da pilha, propriedades da
    // selecionada e, no espaço que sobrar, a lista de camadas.
    const p = l.painel;
    const esq = p.x0 + 4;
    const dir = p.x1 - 4;
    var y = p.y1 - altura_linha - 4;
    const pilha = [_]struct { a: Acao, r: []const u8 }{ .{ .a = .subir, .r = "Subir" }, .{ .a = .descer, .r = "Descer" }, .{ .a = .apagar, .r = "Apagar" } };
    const terco = @divTrunc(dir - esq, 3);
    for (pilha, 0..) |b, k| {
        const x0 = esq + @as(i32, @intCast(k)) * terco;
        l.por(.{ .caixa = .{ .x0 = x0, .y0 = y, .x1 = x0 + terco - 2, .y1 = y + altura_linha }, .acao = b.a, .rotulo = b.r });
    }

    const atual = doc.atual();
    if (atual.modelo == .texto) {
        y -= altura_linha + 10;
        l.por(.{ .caixa = .{ .x0 = esq + 6, .y0 = y, .x1 = dir - 6, .y1 = y + altura_linha }, .acao = .editar_texto, .rotulo = atual.modelo.texto.conteudo(), .ligado = estado.editando });
        y -= fonte.altura + 6;
        l.titulo(p.x0 + 10, y, "TEXTO (clique ou Enter)");
    }
    // Cor: a do modelo selecionado ou, num desenho, a do pincel.
    const cor_marcada = atual.cor() orelse estado.cor;
    const por_linha = 6;
    const linhas_paleta = (paleta.len + por_linha - 1) / por_linha;
    y -= @as(i32, linhas_paleta) * (lado_amostra + 4) + 8;
    for (paleta, 0..) |c, k| {
        const cx = esq + 6 + @as(i32, @intCast(k % por_linha)) * (lado_amostra + 4);
        const cy = y + @as(i32, @intCast(k / por_linha)) * (lado_amostra + 4);
        l.por(.{ .caixa = .{ .x0 = cx, .y0 = cy, .x1 = cx + lado_amostra, .y1 = cy + lado_amostra }, .acao = .{ .cor = c }, .ligado = c == cor_marcada });
    }
    y -= fonte.altura + 6;
    l.titulo(p.x0 + 10, y, if (atual.modelo == .desenho) "COR DO PINCEL" else "COR");
    const limite_lista = y - 10;

    l.titulo(p.x0 + 10, p.y0 + 8, "CAMADAS");
    var yl = p.y0 + altura_linha + 4;
    var i = doc.camadas.items.len;
    while (i > 0 and yl + altura_linha <= limite_lista) {
        i -= 1;
        l.por(.{ .caixa = .{ .x0 = esq, .y0 = yl, .x1 = dir, .y1 = yl + altura_linha }, .acao = .{ .selecionar = i }, .rotulo = doc.camadas.items[i].nome(), .ligado = i == doc.selecionada });
        yl += altura_linha + 2;
    }

    if (estado.arquivos) |nomes| montarEscolha(&l, w, h, nomes, estado.rolagem);
    return l;
}

/// Janela por cima de tudo com os arquivos de imagem; o resto fica apagado.
fn montarEscolha(l: *Layout, w: i32, h: i32, nomes: []const []u8, rolagem: usize) void {
    for (l.botoes[0..l.n]) |*b| {
        b.desligado = true;
        b.ligado = false;
    }
    const largura = @min(w - 40, 560);
    const altura = @min(h - 80, 520);
    const x0 = @divTrunc(w - largura, 2);
    const y0 = @divTrunc(h - altura, 2);
    const caixa: Caixa = .{ .x0 = x0, .y0 = y0, .x1 = x0 + largura, .y1 = y0 + altura };
    l.modal = caixa;
    const topo_lista = y0 + altura_linha + 16;
    const base_lista = caixa.y1 - altura_linha - 16;
    l.linhas_visiveis = @intCast(@max(1, @divTrunc(base_lista - topo_lista, altura_linha + 2)));
    var y = topo_lista;
    var i = rolagem;
    while (i < nomes.len and y + altura_linha <= base_lista) : (i += 1) {
        l.por(.{ .caixa = .{ .x0 = x0 + 8, .y0 = y, .x1 = caixa.x1 - 8, .y1 = y + altura_linha }, .acao = .{ .abrir = i }, .rotulo = nomes[i] });
        y += altura_linha + 2;
    }
    const bw = fonte.medir("Cancelar", 1) + 24;
    l.por(.{ .caixa = .{ .x0 = caixa.x1 - 8 - bw, .y0 = caixa.y1 - altura_linha - 8, .x1 = caixa.x1 - 8, .y1 = caixa.y1 - 8 }, .acao = .cancelar_abrir, .rotulo = "Cancelar" });
}

fn centralizado(t: *Tela, c: Caixa, texto: []const u8, cor_texto: Cor) void {
    const x = c.x0 + @divTrunc(c.x1 - c.x0 - fonte.medir(texto, 1), 2);
    const y = c.y0 + @divTrunc(c.y1 - c.y0 - fonte.altura, 2);
    _ = fonte.escrever(t, x, y, texto, cor_texto, 1);
}

fn moldura(t: *Tela, c: Caixa, espessura: i32, cor_borda: Cor) void {
    t.retangulo(.{ .x0 = c.x0, .y0 = c.y0, .x1 = c.x1, .y1 = c.y0 + espessura }, cor_borda);
    t.retangulo(.{ .x0 = c.x0, .y0 = c.y1 - espessura, .x1 = c.x1, .y1 = c.y1 }, cor_borda);
    t.retangulo(.{ .x0 = c.x0, .y0 = c.y0, .x1 = c.x0 + espessura, .y1 = c.y1 }, cor_borda);
    t.retangulo(.{ .x0 = c.x1 - espessura, .y0 = c.y0, .x1 = c.x1, .y1 = c.y1 }, cor_borda);
}

pub fn desenhar(t: *Tela, l: *const Layout, sobre: ?usize, doc: *Documento, estado: Estado) void {
    t.retangulo(l.barra, cor.fundo);
    t.retangulo(l.painel, cor.fundo);
    t.retangulo(.{ .x0 = l.painel.x0, .y0 = l.painel.y0, .x1 = l.painel.x0 + 1, .y1 = l.painel.y1 }, cor.borda);
    t.retangulo(.{ .x0 = 0, .y0 = l.barra.y1 - 1, .x1 = l.barra.x1, .y1 = l.barra.y1 }, cor.borda);
    t.retangulo(l.rodape, cor.fundo);
    for (l.titulos[0..l.n_titulos]) |ti| _ = fonte.escrever(t, ti.x, ti.y, ti.texto, cor.titulo, 1);

    var modal_desenhado = false;
    for (l.botoes[0..l.n], 0..) |b, i| {
        // A janela da lista vem depois dos botões apagados: pinta ela antes
        // do primeiro botão dela.
        if (l.modal) |m| {
            if (!modal_desenhado and !b.desligado) {
                desenharFundoEscolha(t, m, estado);
                modal_desenhado = true;
            }
        }
        const em_cima = sobre == i and !b.desligado;
        const cor_texto = if (b.desligado) cor.apagado else cor.texto;
        switch (b.acao) {
            .cor => |c| {
                t.retangulo(b.caixa, c);
                moldura(t, b.caixa, 1, cor.borda);
                if (b.ligado) {
                    moldura(t, .{ .x0 = b.caixa.x0 - 3, .y0 = b.caixa.y0 - 3, .x1 = b.caixa.x1 + 3, .y1 = b.caixa.y1 + 3 }, 2, cor.texto);
                } else if (em_cima) {
                    moldura(t, .{ .x0 = b.caixa.x0 - 2, .y0 = b.caixa.y0 - 2, .x1 = b.caixa.x1 + 2, .y1 = b.caixa.y1 + 2 }, 1, cor.titulo);
                }
            },
            .editar_texto => {
                t.retangulo(b.caixa, cor.campo);
                moldura(t, b.caixa, 1, if (b.ligado) cor.ligado else if (em_cima) cor.titulo else cor.borda);
                const fim = fonte.escrever(t, b.caixa.x0 + 6, b.caixa.y0 + 4, b.rotulo, cor.texto, 1);
                // Cursor piscando seria mais um timer; um traço fixo basta.
                if (b.ligado) t.retangulo(.{ .x0 = fim + 1, .y0 = b.caixa.y0 + 4, .x1 = fim + 3, .y1 = b.caixa.y1 - 4 }, cor.ligado);
            },
            .abrir => {
                if (em_cima) t.retangulo(b.caixa, cor.ligado);
                // Caminho comprido: mostra o fim, que é o que distingue.
                const cabe: usize = @intCast(@max(4, @divTrunc(b.caixa.x1 - b.caixa.x0 - 16, fonte.largura)));
                var x = b.caixa.x0 + 8;
                var nome = b.rotulo;
                if (nome.len > cabe) {
                    x = fonte.escrever(t, x, b.caixa.y0 + 4, "...", cor.titulo, 1);
                    nome = nome[nome.len - (cabe - 3) ..];
                    // Não começar no meio de uma letra de 2 bytes.
                    while (nome.len > 0 and nome[0] & 0xc0 == 0x80) nome = nome[1..];
                }
                _ = fonte.escrever(t, x, b.caixa.y0 + 4, nome, cor.texto, 1);
            },
            // Linhas de camada: nome alinhado à esquerda.
            .selecionar => {
                if (b.ligado) t.retangulo(b.caixa, cor.ligado) else if (em_cima) t.retangulo(b.caixa, cor.sobre);
                _ = fonte.escrever(t, b.caixa.x0 + 8, b.caixa.y0 + 4, b.rotulo, cor_texto, 1);
            },
            else => {
                if (b.ligado) t.retangulo(b.caixa, cor.ligado) else if (em_cima) t.retangulo(b.caixa, cor.sobre);
                centralizado(t, b.caixa, b.rotulo, cor_texto);
            },
        }
    }

    // Rodapé: o que dá pra fazer agora (ou o recado, se tiver).
    var buf: [200]u8 = undefined;
    if (estado.aviso) |a| {
        _ = fonte.escrever(t, 10, l.rodape.y0 + 4, a, opaco | 0xfacc15, 1);
        return;
    }
    const dica = if (estado.arquivos != null)
        "escolha a imagem (rodinha rola a lista) · Esc cancela"
    else if (estado.editando)
        "digitando: Enter ou Esc termina · Backspace apaga"
    else switch (estado.modo) {
        .pincel => "arraste pra desenhar (se não for desenho, cria um)",
        .mover => "arraste move · cantos escalam · lados esticam · bolinha gira (Shift: 15°)",
    };
    const texto = std.fmt.bufPrint(&buf, "{s}  ·  {s}", .{ doc.atual().nome(), dica }) catch return;
    _ = fonte.escrever(t, 10, l.rodape.y0 + 4, texto, cor.texto, 1);
}

fn desenharFundoEscolha(t: *Tela, m: Caixa, estado: Estado) void {
    t.retangulo(.{ .x0 = m.x0 + 6, .y0 = m.y0 + 6, .x1 = m.x1 + 6, .y1 = m.y1 + 6 }, opaco | 0x111112);
    t.retangulo(m, cor.fundo);
    moldura(t, m, 1, cor.borda);
    var buf: [160]u8 = undefined;
    const n = if (estado.arquivos) |a| a.len else 0;
    // Pasta comprida: só o fim dela cabe no título.
    const cabe: usize = @intCast(@max(8, @divTrunc(m.x1 - m.x0 - 24, fonte.largura) - 24));
    const pasta = if (estado.pasta.len > cabe) estado.pasta[estado.pasta.len - cabe ..] else estado.pasta;
    const reticencias = if (estado.pasta.len > cabe) "..." else "";
    const titulo = std.fmt.bufPrint(&buf, "Abrir imagem  ·  {d} em {s}{s}", .{ n, reticencias, pasta }) catch "Abrir imagem";
    _ = fonte.escrever(t, m.x0 + 12, m.y0 + 10, titulo, cor.texto, 1);
    if (n == 0) _ = fonte.escrever(t, m.x0 + 12, m.y0 + 50, "nenhum .ppm ou .pgm aqui (zig build run -- <pasta>)", cor.titulo, 1);
}

const testing = std.testing;

test "clicar num botão da barra dá a ação dele" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    const l = montar(900, 600, &d, .{ .modo = .pincel, .cor = paleta[0] });
    const ret = l.botoes[1].caixa;
    try testing.expectEqual(Acao{ .adicionar = .retangulo }, l.clicar(ret.x0 + 2, ret.y0 + 2).?);
    const img = l.botoes[4].caixa;
    try testing.expectEqual(Acao{ .adicionar = .imagem }, l.clicar(img.x0 + 2, img.y0 + 2).?);
    try testing.expect(l.dentro(5, 5));
    try testing.expect(!l.dentro(300, 300));
}

fn contar(l: *const Layout, comptime tag: std.meta.Tag(Acao)) usize {
    var n: usize = 0;
    for (l.botoes[0..l.n]) |b| n += @intFromBool(b.acao == tag);
    return n;
}

test "painel lista as camadas de cima pra baixo" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    try d.adicionar(.retangulo, .{ .x = 50, .y = 50 });
    const l = montar(900, 600, &d, .{ .modo = .mover, .cor = paleta[0] });
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

test "paleta sempre; campo de texto só quando a selecionada é texto" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    const e: Estado = .{ .modo = .mover, .cor = paleta[0] };
    var l = montar(900, 600, &d, e);
    try testing.expectEqual(paleta.len, contar(&l, .cor));
    try testing.expectEqual(@as(usize, 0), contar(&l, .editar_texto));
    try d.adicionar(.texto, .{ .x = 50, .y = 50 });
    l = montar(900, 600, &d, e);
    try testing.expectEqual(@as(usize, 1), contar(&l, .editar_texto));
}

test "com a lista de arquivos aberta, só ela responde" {
    var d = try Documento.criar(testing.allocator, 100, 100, opaco);
    defer d.destruir();
    var a = "a.ppm".*;
    var b = "b.ppm".*;
    const nomes = [_][]u8{ &a, &b };
    const l = montar(900, 600, &d, .{ .modo = .mover, .cor = paleta[0], .arquivos = &nomes });
    const ret = l.botoes[1].caixa;
    try testing.expectEqual(@as(?Acao, null), l.clicar(ret.x0 + 2, ret.y0 + 2));
    try testing.expect(l.dentro(300, 300));
    try testing.expectEqual(@as(usize, 2), contar(&l, .abrir));
    try testing.expectEqual(@as(usize, 1), contar(&l, .cancelar_abrir));
}
