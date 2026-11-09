//! Menus dentro da janela, desenhados pixel a pixel como todo o resto.
//!
//! A cada quadro `montar` calcula onde fica cada botão a partir do tamanho
//! da janela e do quadro. A mesma lista serve pra desenhar e pra saber o
//! que foi clicado: o que aparece é exatamente o que responde ao mouse.
//!
//! Layout: barra no topo com as ferramentas (cada uma cria um modelo, ou
//! seleciona, apaga, recorta), painel à direita com as propriedades do que
//! está selecionado (ou de como a ferramenta vai criar) e as camadas, e
//! rodapé com dicas.
const std = @import("std");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const Caixa = tela_.Caixa;
const opaco = tela_.opaco;
const fonte = @import("fonte.zig");
const camada = @import("camada.zig");
const Documento = camada.Documento;
const Estilo = camada.Estilo;

pub const Ferramenta = enum {
    selecao,
    pincel,
    linha,
    seta,
    retangulo,
    elipse,
    texto,
    borracha,
    recorte,

    pub fn rotulo(f: Ferramenta) []const u8 {
        return switch (f) {
            .selecao => "Seleção",
            .pincel => "Pincel",
            .linha => "Linha",
            .seta => "Seta",
            .retangulo => "Retângulo",
            .elipse => "Elipse",
            .texto => "Texto",
            .borracha => "Borracha",
            .recorte => "Recorte",
        };
    }

    pub fn atalho(f: Ferramenta) []const u8 {
        return switch (f) {
            .selecao => "V",
            .pincel => "P",
            .linha => "L",
            .seta => "A",
            .retangulo => "R",
            .elipse => "O",
            .texto => "T",
            .borracha => "E",
            .recorte => "C",
        };
    }
};

/// O que a interface precisa saber do editor pra se montar.
pub const Estado = struct {
    ferramenta: Ferramenta = .selecao,
    /// Como a ferramenta cria (o painel mostra isto quando nada está selecionado).
    estilo: Estilo = .{},
    /// Digitando no texto selecionado.
    editando: bool = false,
    /// Escolhendo arquivo: a lista aparece por cima de tudo.
    arquivos: ?[]const []u8 = null,
    titulo_lista: []const u8 = "Abrir",
    pasta: []const u8 = "",
    rolagem: usize = 0,
    /// Recado no rodapé (ex.: onde o recorte foi salvo).
    aviso: ?[]const u8 = null,
    /// Quadro aberto (nome do arquivo) e se mudou desde que salvou.
    arquivo: ?[]const u8 = null,
    alterado: bool = false,
};

pub const Acao = union(enum) {
    ferramenta: Ferramenta,
    imagem,
    abrir_quadro,
    salvar_quadro,
    selecionar: usize,
    subir,
    descer,
    apagar,
    duplicar,
    agrupar,
    desagrupar,
    cor: Cor,
    fundo: ?Cor,
    espessura: f32,
    tamanho: u8,
    mao: bool,
    escala: u8,
    recortar,
    salvar_ppm,
    abrir: usize,
    cancelar_abrir,
};

pub const paleta = [_]Cor{
    opaco | 0x1d1d1f, opaco | 0x8e8e93, opaco | 0xffffff, opaco | 0xe03131, opaco | 0xf08c00, opaco | 0xf5c400,
    opaco | 0x2f9e44, opaco | 0x0c8599, opaco | 0x1971c2, opaco | 0x6741d9, opaco | 0xc2255c, opaco | 0x8d5524,
};

/// Fundos: o primeiro é "nenhum" (vazado); o resto, tons claros.
pub const fundos = [_]?Cor{
    null,              opaco | 0xffffff, opaco | 0xfff3bf, opaco | 0xffd8a8, opaco | 0xffc9c9, opaco | 0xfcc2d7,
    opaco | 0xd0bfff, opaco | 0xa5d8ff, opaco | 0x99e9f2, opaco | 0xb2f2bb, opaco | 0xe9ecef, opaco | 0x1d1d1f,
};

pub const espessuras = [_]struct { v: f32, r: []const u8 }{ .{ .v = 1.5, .r = "Fina" }, .{ .v = 3, .r = "Média" }, .{ .v = 6, .r = "Grossa" } };
pub const tamanhos = [_]struct { v: u8, r: []const u8 }{ .{ .v = 2, .r = "P" }, .{ .v = 3, .r = "M" }, .{ .v = 5, .r = "G" }, .{ .v = 8, .r = "GG" } };

pub const altura_barra = fonte.altura + 14;
pub const largura_painel = 220;
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
    const ligado = opaco | 0x5b4bc4;
    const campo = opaco | 0x2c2c2e;
};

const Botao = struct {
    caixa: Caixa,
    acao: Acao,
    rotulo: []const u8 = "",
    /// Letra do atalho, mostrada mais apagada depois do rótulo.
    atalho: []const u8 = "",
    ligado: bool = false,
    desligado: bool = false,
};

const Titulo = struct { x: i32, y: i32, texto: []const u8 };

pub const Layout = struct {
    botoes: [128]Botao = undefined,
    n: usize = 0,
    titulos: [8]Titulo = undefined,
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

    /// O ponto cai em cima da interface (e não do quadro)?
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

/// Quais seções de propriedade fazem sentido agora, e o valor marcado de
/// cada uma: o do primeiro selecionado que tem aquela propriedade ou, sem
/// seleção, o da ferramenta.
const Propriedades = struct {
    cor: ?Cor = null,
    fundo: ??Cor = null,
    espessura: ?f32 = null,
    tamanho: ?u8 = null,
    mao: ?bool = null,
};

fn propriedades(doc: *const Documento, e: Estado) Propriedades {
    var p: Propriedades = .{};
    var alguma = false;
    for (doc.camadas.items) |*c| {
        if (!c.selecionada) continue;
        alguma = true;
        if (p.cor == null) p.cor = c.cor();
        if (p.espessura == null) p.espessura = c.espessura();
        if (p.mao == null) p.mao = c.aMao();
        switch (c.modelo) {
            .retangulo, .elipse => |f| if (p.fundo == null) {
                p.fundo = f.fundo;
            },
            .texto => |t| if (p.tamanho == null) {
                p.tamanho = t.escala;
            },
            else => {},
        }
    }
    if (alguma) return p;
    const s = e.estilo;
    switch (e.ferramenta) {
        .pincel => {
            p.cor = s.cor;
            p.espessura = s.espessura;
        },
        .linha, .seta => {
            p.cor = s.cor;
            p.espessura = s.espessura;
            p.mao = s.mao;
        },
        .retangulo, .elipse => {
            p.cor = s.cor;
            p.fundo = s.fundo;
            p.espessura = s.espessura;
            p.mao = s.mao;
        },
        .texto => {
            p.cor = s.cor;
            p.tamanho = s.tamanho;
        },
        else => {},
    }
    return p;
}

const ferramentas = [_]Ferramenta{ .selecao, .pincel, .linha, .seta, .retangulo, .elipse, .texto, .borracha, .recorte };

fn larguraBotao(r: []const u8, atalho: []const u8) i32 {
    return fonte.medir(r, 1) + (if (atalho.len > 0) fonte.medir(atalho, 1) + 6 else 0) + 16;
}

pub fn montar(largura: u16, altura: u16, doc: *Documento, estado: Estado) Layout {
    const w: i32 = largura;
    const h: i32 = altura;
    var l: Layout = .{
        .barra = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = altura_barra },
        .painel = .{ .x0 = w - largura_painel, .y0 = altura_barra, .x1 = w, .y1 = h - altura_rodape },
        .rodape = .{ .x0 = 0, .y0 = h - altura_rodape, .x1 = w, .y1 = h },
    };

    // Barra: as ferramentas, da esquerda pra direita, e a imagem.
    var x: i32 = 6;
    const y0 = 4;
    const y1 = altura_barra - 4;
    for (ferramentas) |f| {
        const bw = larguraBotao(f.rotulo(), f.atalho());
        l.por(.{ .caixa = .{ .x0 = x, .y0 = y0, .x1 = x + bw, .y1 = y1 }, .acao = .{ .ferramenta = f }, .rotulo = f.rotulo(), .atalho = f.atalho(), .ligado = estado.ferramenta == f });
        x += bw + 3;
    }
    x += 8;
    {
        const bw = larguraBotao("Imagem", "I");
        l.por(.{ .caixa = .{ .x0 = x, .y0 = y0, .x1 = x + bw, .y1 = y1 }, .acao = .imagem, .rotulo = "Imagem", .atalho = "I" });
    }
    // Arquivo, encostado na direita.
    x = w - 6;
    const arq = [_]struct { a: Acao, r: []const u8 }{ .{ .a = .salvar_quadro, .r = "Salvar" }, .{ .a = .abrir_quadro, .r = "Abrir" } };
    for (arq) |b| {
        const bw = larguraBotao(b.r, "");
        x -= bw;
        l.por(.{ .caixa = .{ .x0 = x, .y0 = y0, .x1 = x + bw, .y1 = y1 }, .acao = b.a, .rotulo = b.r });
        x -= 3;
    }

    // Painel, de cima pra baixo: propriedades e, embaixo, as camadas.
    const p = l.painel;
    const esq = p.x0 + 10;
    const dir = p.x1 - 8;
    var y = p.y0 + 8;
    const props = propriedades(doc, estado);

    if (props.cor) |marcada| {
        l.titulo(esq, y, "COR");
        y += fonte.altura + 4;
        y = amostras(&l, esq, y, &paleta, marcada, .cor);
    }
    if (props.fundo) |marcado| {
        l.titulo(esq, y, "FUNDO");
        y += fonte.altura + 4;
        for (fundos, 0..) |f, k| {
            const cx = esq + @as(i32, @intCast(k % 6)) * (lado_amostra + 4);
            const cy = y + @as(i32, @intCast(k / 6)) * (lado_amostra + 4);
            l.por(.{ .caixa = .{ .x0 = cx, .y0 = cy, .x1 = cx + lado_amostra, .y1 = cy + lado_amostra }, .acao = .{ .fundo = f }, .ligado = std.meta.eql(f, marcado) });
        }
        y += 2 * (lado_amostra + 4) + 8;
    }
    if (props.espessura) |marcada| {
        l.titulo(esq, y, "ESPESSURA");
        y += fonte.altura + 4;
        const terco = @divTrunc(dir - esq, 3);
        for (espessuras, 0..) |e, k| {
            const bx = esq + @as(i32, @intCast(k)) * terco;
            l.por(.{ .caixa = .{ .x0 = bx, .y0 = y, .x1 = bx + terco - 3, .y1 = y + altura_linha }, .acao = .{ .espessura = e.v }, .rotulo = e.r, .ligado = e.v == marcada });
        }
        y += altura_linha + 12;
    }
    if (props.mao) |marcado| {
        l.titulo(esq, y, "TRAÇO");
        y += fonte.altura + 4;
        const metade = @divTrunc(dir - esq, 2);
        l.por(.{ .caixa = .{ .x0 = esq, .y0 = y, .x1 = esq + metade - 3, .y1 = y + altura_linha }, .acao = .{ .mao = false }, .rotulo = "Liso", .ligado = !marcado });
        l.por(.{ .caixa = .{ .x0 = esq + metade, .y0 = y, .x1 = dir, .y1 = y + altura_linha }, .acao = .{ .mao = true }, .rotulo = "À mão", .ligado = marcado });
        y += altura_linha + 12;
    }
    if (props.tamanho) |marcado| {
        l.titulo(esq, y, "TAMANHO DO TEXTO");
        y += fonte.altura + 4;
        const quarto = @divTrunc(dir - esq, 4);
        for (tamanhos, 0..) |t, k| {
            const bx = esq + @as(i32, @intCast(k)) * quarto;
            l.por(.{ .caixa = .{ .x0 = bx, .y0 = y, .x1 = bx + quarto - 3, .y1 = y + altura_linha }, .acao = .{ .tamanho = t.v }, .rotulo = t.r, .ligado = t.v == marcado });
        }
        y += altura_linha + 12;
    }
    if (doc.unica()) |c| if (c.modelo == .moldura) {
        l.titulo(esq, y, "ESCALA DO RECORTE");
        y += fonte.altura + 4;
        const quarto = @divTrunc(dir - esq, 4);
        const rotulos = [_][]const u8{ "1×", "2×", "3×", "4×" };
        for (rotulos, 1..) |r, k| {
            const bx = esq + @as(i32, @intCast(k - 1)) * quarto;
            l.por(.{ .caixa = .{ .x0 = bx, .y0 = y, .x1 = bx + quarto - 3, .y1 = y + altura_linha }, .acao = .{ .escala = @intCast(k) }, .rotulo = r, .ligado = c.modelo.moldura.escala == k });
        }
        y += altura_linha + 4;
        const metade = @divTrunc(dir - esq, 2);
        l.por(.{ .caixa = .{ .x0 = esq, .y0 = y, .x1 = esq + metade - 3, .y1 = y + altura_linha }, .acao = .recortar, .rotulo = "Copiar PNG", .ligado = true });
        l.por(.{ .caixa = .{ .x0 = esq + metade, .y0 = y, .x1 = dir, .y1 = y + altura_linha }, .acao = .salvar_ppm, .rotulo = "Salvar PPM" });
        y += altura_linha + 12;
    };

    // Ações da seleção.
    const n_sel = doc.quantasSelecionadas();
    if (n_sel > 0) {
        l.titulo(esq, y, "SELEÇÃO");
        y += fonte.altura + 4;
        const terco = @divTrunc(dir - esq, 3);
        const linha1 = [_]struct { a: Acao, r: []const u8 }{ .{ .a = .subir, .r = "Subir" }, .{ .a = .descer, .r = "Descer" }, .{ .a = .apagar, .r = "Apagar" } };
        for (linha1, 0..) |b, k| {
            const bx = esq + @as(i32, @intCast(k)) * terco;
            l.por(.{ .caixa = .{ .x0 = bx, .y0 = y, .x1 = bx + terco - 3, .y1 = y + altura_linha }, .acao = b.a, .rotulo = b.r });
        }
        y += altura_linha + 3;
        var agrupado = false;
        for (doc.camadas.items) |c| agrupado = agrupado or (c.selecionada and c.grupo != 0);
        const metade = @divTrunc(dir - esq, 2);
        l.por(.{ .caixa = .{ .x0 = esq, .y0 = y, .x1 = esq + metade - 3, .y1 = y + altura_linha }, .acao = .duplicar, .rotulo = "Duplicar" });
        if (agrupado) {
            l.por(.{ .caixa = .{ .x0 = esq + metade, .y0 = y, .x1 = dir, .y1 = y + altura_linha }, .acao = .desagrupar, .rotulo = "Desagrupar" });
        } else {
            l.por(.{ .caixa = .{ .x0 = esq + metade, .y0 = y, .x1 = dir, .y1 = y + altura_linha }, .acao = .agrupar, .rotulo = "Agrupar", .desligado = n_sel < 2 });
        }
        y += altura_linha + 12;
    }

    // Camadas no espaço que sobrou, de cima pra baixo como na pilha.
    if (y + 2 * altura_linha < p.y1) {
        l.titulo(esq, y, "CAMADAS");
        y += fonte.altura + 6;
        var i = doc.camadas.items.len;
        while (i > 0 and y + altura_linha <= p.y1 - 4) {
            i -= 1;
            const c = &doc.camadas.items[i];
            l.por(.{ .caixa = .{ .x0 = esq - 4, .y0 = y, .x1 = dir, .y1 = y + altura_linha }, .acao = .{ .selecionar = i }, .rotulo = c.nome(), .ligado = c.selecionada });
            y += altura_linha + 1;
        }
    }

    if (estado.arquivos) |nomes| montarEscolha(&l, w, h, nomes, estado.rolagem);
    return l;
}

fn amostras(l: *Layout, esq: i32, y: i32, cores: []const Cor, marcada: Cor, comptime tag: std.meta.Tag(Acao)) i32 {
    for (cores, 0..) |c, k| {
        const cx = esq + @as(i32, @intCast(k % 6)) * (lado_amostra + 4);
        const cy = y + @as(i32, @intCast(k / 6)) * (lado_amostra + 4);
        l.por(.{ .caixa = .{ .x0 = cx, .y0 = cy, .x1 = cx + lado_amostra, .y1 = cy + lado_amostra }, .acao = @unionInit(Acao, @tagName(tag), c), .ligado = c == marcada });
    }
    const linhas: i32 = @intCast((cores.len + 5) / 6);
    return y + linhas * (lado_amostra + 4) + 8;
}

/// Janela por cima de tudo com os arquivos; o resto fica apagado.
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

fn centralizado(t: *Tela, b: Botao, cor_texto: Cor) void {
    const c = b.caixa;
    const larg = fonte.medir(b.rotulo, 1) + (if (b.atalho.len > 0) fonte.medir(b.atalho, 1) + 6 else 0);
    const x = c.x0 + @divTrunc(c.x1 - c.x0 - larg, 2);
    const y = c.y0 + @divTrunc(c.y1 - c.y0 - fonte.altura, 2);
    const fim = fonte.escrever(t, x, y, b.rotulo, cor_texto, 1);
    if (b.atalho.len > 0) _ = fonte.escrever(t, fim + 6, y, b.atalho, if (b.ligado) opaco | 0xc8c0f0 else cor.apagado, 1);
}

fn moldura(t: *Tela, c: Caixa, espessura: i32, cor_borda: Cor) void {
    t.retangulo(.{ .x0 = c.x0, .y0 = c.y0, .x1 = c.x1, .y1 = c.y0 + espessura }, cor_borda);
    t.retangulo(.{ .x0 = c.x0, .y0 = c.y1 - espessura, .x1 = c.x1, .y1 = c.y1 }, cor_borda);
    t.retangulo(.{ .x0 = c.x0, .y0 = c.y0, .x1 = c.x0 + espessura, .y1 = c.y1 }, cor_borda);
    t.retangulo(.{ .x0 = c.x1 - espessura, .y0 = c.y0, .x1 = c.x1, .y1 = c.y1 }, cor_borda);
}

fn amostra(t: *Tela, b: Botao, c: ?Cor, em_cima: bool) void {
    if (c) |cc| {
        t.retangulo(b.caixa, cc);
    } else {
        // "Nenhum": xadrez com um risco.
        t.retangulo(b.caixa, opaco | 0xffffff);
        t.linha(b.caixa.x0 + 3, b.caixa.y1 - 4, b.caixa.x1 - 4, b.caixa.y0 + 3, 1, opaco | 0xe03131);
    }
    moldura(t, b.caixa, 1, cor.borda);
    if (b.ligado) {
        moldura(t, .{ .x0 = b.caixa.x0 - 3, .y0 = b.caixa.y0 - 3, .x1 = b.caixa.x1 + 3, .y1 = b.caixa.y1 + 3 }, 2, cor.texto);
    } else if (em_cima) {
        moldura(t, .{ .x0 = b.caixa.x0 - 2, .y0 = b.caixa.y0 - 2, .x1 = b.caixa.x1 + 2, .y1 = b.caixa.y1 + 2 }, 1, cor.titulo);
    }
}

pub fn desenhar(t: *Tela, l: *const Layout, sobre: ?usize, estado: Estado) void {
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
            .cor => |c| amostra(t, b, c, em_cima),
            .fundo => |c| amostra(t, b, c, em_cima),
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
                if (b.ligado) t.retangulo(b.caixa, cor.ligado) else if (em_cima) t.retangulo(b.caixa, cor.sobre) else t.retangulo(b.caixa, opaco | 0x242426);
                centralizado(t, b, cor_texto);
            },
        }
    }

    // Rodapé: o que dá pra fazer agora (ou o recado, se tiver).
    if (estado.aviso) |a| {
        _ = fonte.escrever(t, 10, l.rodape.y0 + 4, a, opaco | 0xfacc15, 1);
        return;
    }
    const dica = if (estado.arquivos != null)
        "escolha o arquivo (rodinha rola a lista) · Esc cancela"
    else if (estado.editando)
        "digitando: Enter ou Esc termina · Backspace apaga"
    else switch (estado.ferramenta) {
        .selecao => "Shift soma · arraste no vazio: área · 2 cliques: texto · Ctrl+C: imagem",
        .pincel => "arraste pra desenhar · cada traço é um objeto",
        .linha, .seta => "arraste da ponta à ponta (Shift: de 15 em 15°)",
        .retangulo, .elipse => "arraste o tamanho (Shift: quadrado/círculo)",
        .texto => "clique onde quer escrever",
        .borracha => "passe por cima do que quer apagar",
        .recorte => "arraste a região: vira moldura, e o PNG é copiado e salvo",
    };
    var buf: [240]u8 = undefined;
    const arquivo = estado.arquivo orelse "quadro novo";
    const texto = std.fmt.bufPrint(&buf, "{s}{s}  ·  {s}  ·  Ctrl+Z desfaz · botão direito: anda · rodinha: zoom", .{ arquivo, if (estado.alterado) " *" else "", dica }) catch return;
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
    const titulo = std.fmt.bufPrint(&buf, "{s}  ·  {d} em {s}{s}", .{ estado.titulo_lista, n, reticencias, pasta }) catch estado.titulo_lista;
    _ = fonte.escrever(t, m.x0 + 12, m.y0 + 10, titulo, cor.texto, 1);
    if (n == 0) _ = fonte.escrever(t, m.x0 + 12, m.y0 + 50, "nada aqui (zig build run -- <pasta>)", cor.titulo, 1);
}

const testing = std.testing;

fn contar(l: *const Layout, comptime tag: std.meta.Tag(Acao)) usize {
    var n: usize = 0;
    for (l.botoes[0..l.n]) |b| n += @intFromBool(b.acao == tag);
    return n;
}

test "barra: uma ferramenta por botão, e cabe em 1200 px" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    const l = montar(1200, 700, &d, .{});
    try testing.expectEqual(ferramentas.len, contar(&l, .ferramenta));
    const ret = l.botoes[4].caixa;
    try testing.expectEqual(Acao{ .ferramenta = .retangulo }, l.clicar(ret.x0 + 2, ret.y0 + 2).?);
    // O último da esquerda (Imagem) não encosta no primeiro da direita.
    var fim_esq: i32 = 0;
    var ini_dir: i32 = 10000;
    for (l.botoes[0..l.n]) |b| switch (b.acao) {
        .imagem => fim_esq = b.caixa.x1,
        .abrir_quadro => ini_dir = b.caixa.x0,
        else => {},
    };
    try testing.expect(fim_esq < ini_dir);
}

test "painel mostra só as propriedades que fazem sentido" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    var l = montar(1200, 700, &d, .{ .ferramenta = .selecao });
    try testing.expectEqual(@as(usize, 0), contar(&l, .cor));
    l = montar(1200, 700, &d, .{ .ferramenta = .retangulo });
    try testing.expectEqual(paleta.len, contar(&l, .cor));
    try testing.expectEqual(fundos.len, contar(&l, .fundo));
    l = montar(1200, 700, &d, .{ .ferramenta = .texto });
    try testing.expectEqual(@as(usize, 0), contar(&l, .fundo));
    try testing.expectEqual(tamanhos.len, contar(&l, .tamanho));
    // Moldura selecionada: escala e recortar.
    _ = try d.adicionar(.{ .modelo = .{ .moldura = .{ .largura = 10, .altura = 10, .numero = 0 } } });
    l = montar(1200, 700, &d, .{});
    try testing.expectEqual(@as(usize, 4), contar(&l, .escala));
    try testing.expectEqual(@as(usize, 1), contar(&l, .recortar));
    try testing.expectEqual(@as(usize, 1), contar(&l, .selecionar));
}

test "com a lista de arquivos aberta, só ela responde" {
    var d = Documento.criar(testing.allocator);
    defer d.destruir();
    var a = "a.ppm".*;
    var b = "b.ppm".*;
    const nomes = [_][]u8{ &a, &b };
    const l = montar(1200, 700, &d, .{ .arquivos = &nomes });
    const ret = l.botoes[1].caixa;
    try testing.expectEqual(@as(?Acao, null), l.clicar(ret.x0 + 2, ret.y0 + 2));
    try testing.expect(l.dentro(300, 300));
    try testing.expectEqual(@as(usize, 2), contar(&l, .abrir));
    try testing.expectEqual(@as(usize, 1), contar(&l, .cancelar_abrir));
}
