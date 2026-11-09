//! Quadro infinito pra rabiscar rápido, onde qualquer pedaço vira imagem
//! num gesto: a ferramenta Recorte gera de novo a região, na escala que
//! quiser, e põe o PNG na área de transferência.
const std = @import("std");
const x11 = @import("x11.zig");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const opaco = tela_.opaco;
const m3 = @import("mat3.zig");
const Mat3 = m3.Mat3;
const Ponto = m3.Ponto;
const camada = @import("camada.zig");
const Documento = camada.Documento;
const Camada = camada.Camada;
const Retangulo = camada.Retangulo;
const ui = @import("ui.zig");
const Ferramenta = ui.Ferramenta;
const Digitacao = @import("digitar.zig").Digitacao;
const alcas = @import("alcas.zig");
const arquivos = @import("arquivos.zig");
const ppm = @import("ppm.zig");
const png = @import("png.zig");
const quadro = @import("quadro.zig");
const fonte = @import("fonte.zig");

const papel = opaco | 0xf8f7f4;
const cor_grade = opaco | 0xd6d2c8;
const cor_selecao = opaco | 0x6e56cf;
const espaco_grade = 24; // unidades do mundo

const passo_giro = std.math.pi / 12.0; // 15°
const passo_zoom = 1.1;
const duplo_ms = 400;

// Posições físicas das teclas (as mesmas em qualquer layout; os nomes são
// do teclado americano).
const tecla = struct {
    const esc = 9;
    const um = 10;
    const zero = 19;
    const menos = 20;
    const igual = 21;
    const backspace = 22;
    const q = 24;
    const e = 26;
    const r = 27;
    const t = 28;
    const y = 29;
    const i = 31;
    const o = 32;
    const p = 33;
    const enter = 36;
    const a = 38;
    const s = 39;
    const d = 40;
    const g = 42;
    const l = 46;
    const shift_esq = 50;
    const z = 52;
    const c = 54;
    const v = 55;
    const b = 56;
    const shift_dir = 62;
    const espaco = 65;
    const cima = 111;
    const page_up = 112;
    const esquerda = 113;
    const direita = 114;
    const baixo = 116;
    const page_down = 117;
    const delete = 119;
};
const mascara_shift = 1;
const mascara_ctrl = 4;

// Botões do mouse no X11: 1 esquerdo, 2 meio, 3 direito, 4 e 5 a rodinha.
const botao = struct {
    const esquerdo = 1;
    const meio = 2;
    const direito = 3;
    const rodinha_cima = 4;
    const rodinha_baixo = 5;
};

const PontoInt = struct { x: i32, y: i32 };

/// O que o mouse está fazendo enquanto o botão está apertado.
const Gesto = union(enum) {
    nenhum,
    vista: PontoInt,
    mover: struct { x0: i32, y0: i32, moveu: bool = false },
    alca: alcas.Arrasto,
    area: struct { x0: i32, y0: i32, x1: i32, y1: i32 },
    pincel,
    /// Criando retângulo, elipse, linha ou seta: o objeto já existe e
    /// acompanha o mouse.
    forma: struct { x0: i32, y0: i32 },
    borracha: struct { apagou: bool = false },
    recorte: struct { x0: i32, y0: i32, x1: i32, y1: i32 },
};

/// Uma região retangular da tela levada pro mundo: a matriz (região →
/// mundo) e o tamanho nas unidades da região, que são as do mundo.
const Regiao = struct { m: Mat3, largura: f32, altura: f32 };

const Editor = struct {
    init: std.process.Init,
    gpa: std.mem.Allocator,
    janela: *x11.Janela,
    doc: Documento,
    tela: Tela,
    /// mundo → janela. Zoom, arrastar e girar a VISTA não mexem nos objetos.
    vista: Mat3 = Mat3.identidade,
    ferramenta: Ferramenta = .selecao,
    estilo: camada.Estilo = .{},
    gesto: Gesto = .nenhum,
    shift: bool = false,
    espaco: bool = false,
    mouse: PontoInt = .{ .x = 0, .y = 0 },
    sobre: ?usize = null,
    sobre_alca: ?alcas.Alca = null,
    editando: bool = false,
    /// O texto em edição acabou de ser criado (se ficar vazio, some sem
    /// deixar passo no desfazer).
    texto_novo: bool = false,
    digitacao: Digitacao = .{},
    lista: ?arquivos.Lista = null,
    lista_quadros: bool = false,
    rolagem: usize = 0,
    aviso: ?[]const u8 = null,
    aviso_buf: [200]u8 = undefined,
    pasta: []const u8,
    arquivo: ?[]const u8 = null,
    arquivo_buf: [std.fs.max_path_bytes]u8 = undefined,
    alterado: bool = false,
    ultimo_clique: struct { tempo: u32 = 0, x: i32 = -100, y: i32 = -100 } = .{},
    mudou: bool = true,

    fn avisar(ed: *Editor, comptime fmt: []const u8, args: anytype) void {
        ed.aviso = std.fmt.bufPrint(&ed.aviso_buf, fmt, args) catch null;
    }

    fn estadoUi(ed: *const Editor) ui.Estado {
        return .{
            .ferramenta = ed.ferramenta,
            .estilo = ed.estilo,
            .editando = ed.editando,
            .arquivos = if (ed.lista) |l| l.nomes.items else null,
            .titulo_lista = if (ed.lista_quadros) "Abrir quadro" else "Abrir imagem",
            .pasta = ed.pasta,
            .rolagem = ed.rolagem,
            .aviso = ed.aviso,
            .arquivo = if (ed.arquivo) |a| std.fs.path.basename(a) else null,
            .alterado = ed.alterado,
        };
    }

    /// Guarda o quadro como está, antes de mudar (pro desfazer).
    fn marcar(ed: *Editor) void {
        ed.doc.marcar() catch ed.avisar("sem memória pro desfazer", .{});
        ed.alterado = true;
    }

    fn centroDaArea(ed: *const Editor) Ponto {
        const w: f32 = @floatFromInt(@as(i32, ed.tela.largura) - ui.largura_painel);
        const h: f32 = @floatFromInt(@as(i32, ed.tela.altura) - ui.altura_barra - ui.altura_rodape);
        return .{ .x = w / 2, .y = @as(f32, ui.altura_barra) + h / 2 };
    }

    fn noMundo(ed: *const Editor, x: f32, y: f32) Ponto {
        const inv = ed.vista.inversa() orelse return .{ .x = x, .y = y };
        return inv.aplicar(x, y);
    }

    /// Retângulo da tela (x0,y0)–(x1,y1) como região do mundo, alinhada com
    /// a tela mesmo se a vista estiver girada:
    ///     região → mundo = vista⁻¹ · T(x0, y0) · S(zoom)
    fn regiaoDaTela(ed: *const Editor, xa: f32, ya: f32, xb: f32, yb: f32) Regiao {
        const zoom = @max(ed.vista.fator(), 1e-6);
        const inv = ed.vista.inversa() orelse Mat3.identidade;
        return .{
            .m = inv.vezes(Mat3.translacao(@min(xa, xb), @min(ya, yb))).vezes(Mat3.escala(zoom, zoom)),
            .largura = @abs(xb - xa) / zoom,
            .altura = @abs(yb - ya) / zoom,
        };
    }

    fn trocarFerramenta(ed: *Editor, f: Ferramenta) void {
        ed.terminarEdicao();
        ed.ferramenta = f;
        if (f != .selecao) ed.doc.limparSelecao();
    }

    // ------------------------------------------------------------ arquivos

    fn caminhoLivre(ed: *Editor, buf: []u8, prefixo: []const u8, ext: []const u8) ![]const u8 {
        var n: u32 = 1;
        while (n < 10000) : (n += 1) {
            const nome = try std.fmt.bufPrint(buf, "{s}/{s}-{d}.{s}", .{ ed.pasta, prefixo, n, ext });
            std.Io.Dir.cwd().access(ed.init.io, nome, .{}) catch return nome;
        }
        return error.NomesEsgotados;
    }

    fn gravar(ed: *Editor, caminho: []const u8, bytes: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(ed.init.io, .{ .sub_path = caminho, .data = bytes });
    }

    fn lerArquivo(ed: *Editor, caminho: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(ed.init.io, caminho, ed.gpa, .limited(256 * 1024 * 1024));
    }

    /// Pras imagens de dentro do .quadro (caminhos relativos à pasta).
    const LeitorImagens = struct {
        ed: *Editor,
        pub fn imagem(self: LeitorImagens, relativo: []const u8) !Tela {
            const caminho = try std.fs.path.join(self.ed.gpa, &.{ self.ed.pasta, relativo });
            defer self.ed.gpa.free(caminho);
            const bytes = try self.ed.lerArquivo(caminho);
            defer self.ed.gpa.free(bytes);
            return ppm.ler(self.ed.gpa, bytes);
        }
    };

    fn abrirQuadro(ed: *Editor, caminho: []const u8) void {
        const bytes = ed.lerArquivo(caminho) catch |err| {
            ed.avisar("não abriu {s}: {s}", .{ caminho, @errorName(err) });
            return;
        };
        defer ed.gpa.free(bytes);
        quadro.ler(&ed.doc, bytes, LeitorImagens{ .ed = ed }) catch |err| {
            ed.avisar("não abriu {s}: {s}", .{ caminho, @errorName(err) });
            return;
        };
        const n = @min(caminho.len, ed.arquivo_buf.len);
        @memcpy(ed.arquivo_buf[0..n], caminho[0..n]);
        ed.arquivo = ed.arquivo_buf[0..n];
        ed.alterado = false;
        ed.enquadrarTudo();
        ed.avisar("aberto {s} ({d} objetos)", .{ std.fs.path.basename(caminho), ed.doc.camadas.items.len });
    }

    fn salvarQuadro(ed: *Editor) void {
        const bytes = quadro.escrever(ed.gpa, &ed.doc) catch {
            ed.avisar("sem memória pra salvar", .{});
            return;
        };
        defer ed.gpa.free(bytes);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const caminho = ed.arquivo orelse (ed.caminhoLivre(&buf, "quadro", "quadro") catch {
            ed.avisar("não achei nome livre na pasta", .{});
            return;
        });
        ed.gravar(caminho, bytes) catch |err| {
            ed.avisar("não salvou: {s}", .{@errorName(err)});
            return;
        };
        if (ed.arquivo == null) {
            @memcpy(ed.arquivo_buf[0..caminho.len], caminho);
            ed.arquivo = ed.arquivo_buf[0..caminho.len];
        }
        ed.alterado = false;
        ed.avisar("salvo em {s}", .{std.fs.path.basename(caminho)});
    }

    fn abrirLista(ed: *Editor, de_quadros: bool) void {
        ed.terminarEdicao();
        if (ed.lista) |*l| l.deinit();
        ed.lista = arquivos.listar(ed.gpa, ed.init.io, ed.pasta, if (de_quadros) &arquivos.quadros else &arquivos.imagens) catch |err| blk: {
            ed.avisar("não deu pra ler a pasta {s}: {s}", .{ ed.pasta, @errorName(err) });
            break :blk null;
        };
        ed.lista_quadros = de_quadros;
        ed.rolagem = 0;
    }

    fn fecharLista(ed: *Editor) void {
        if (ed.lista) |*l| l.deinit();
        ed.lista = null;
    }

    fn escolher(ed: *Editor, i: usize) void {
        const relativo = ed.lista.?.nomes.items[i];
        const caminho = std.fs.path.join(ed.gpa, &.{ ed.pasta, relativo }) catch return;
        defer ed.gpa.free(caminho);
        if (ed.lista_quadros) {
            ed.abrirQuadro(caminho);
        } else blk: {
            const bytes = ed.lerArquivo(caminho) catch |err| {
                ed.avisar("não abriu {s}: {s}", .{ relativo, @errorName(err) });
                break :blk;
            };
            defer ed.gpa.free(bytes);
            var img = ppm.ler(ed.gpa, bytes) catch |err| {
                ed.avisar("não abriu {s}: {s}", .{ relativo, @errorName(err) });
                break :blk;
            };
            const c = ed.centroDaArea();
            const zoom = @max(ed.vista.fator(), 1e-6);
            const lado = 0.6 * @as(f32, @floatFromInt(@min(ed.tela.largura, ed.tela.altura))) / zoom;
            ed.marcar();
            ed.doc.adicionarImagem(img, relativo, ed.noMundo(c.x, c.y), lado) catch {
                img.destruir();
                ed.doc.desmarcar();
                break :blk;
            };
            ed.ferramenta = .selecao;
        }
        ed.fecharLista();
    }

    // ------------------------------------------------------------ recorte

    /// Gera a região de novo, põe o PNG na área de transferência e salva o
    /// arquivo (PNG, ou PPM se `em_ppm`).
    fn recortar(ed: *Editor, r: Regiao, escala: f32, so_selecao: bool, em_ppm: bool) void {
        var img = ed.doc.recortar(r.m, r.largura, r.altura, escala, papel, so_selecao) catch |err| {
            ed.avisar("não recortou: {s}", .{@errorName(err)});
            return;
        };
        defer img.destruir();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (em_ppm) {
            const bytes = ppm.escreverP3(ed.gpa, &img) catch return;
            defer ed.gpa.free(bytes);
            const caminho = ed.caminhoLivre(&buf, "recorte", "ppm") catch return;
            ed.gravar(caminho, bytes) catch |err| {
                ed.avisar("não salvou: {s}", .{@errorName(err)});
                return;
            };
            ed.avisar("salvo {s} ({d}×{d})", .{ std.fs.path.basename(caminho), img.largura, img.altura });
            return;
        }
        const bytes = png.escrever(ed.gpa, &img) catch {
            ed.avisar("sem memória pro PNG", .{});
            return;
        };
        defer ed.gpa.free(bytes);
        const copiou = if (ed.janela.copiar(bytes)) true else |_| false;
        const caminho = ed.caminhoLivre(&buf, "recorte", "png") catch "";
        const salvou = caminho.len > 0 and (if (ed.gravar(caminho, bytes)) true else |_| false);
        ed.avisar("{s}{s}{s}  ({d}×{d}, {d} KB)", .{
            if (copiou) "copiado (Ctrl+V cola)" else "não copiou",
            if (salvou) " · salvo em " else "",
            if (salvou) std.fs.path.basename(caminho) else "",
            img.largura,
            img.altura,
            bytes.len / 1024,
        });
    }

    fn recortarMoldura(ed: *Editor, c: *const Camada, em_ppm: bool) void {
        const mo = c.modelo.moldura;
        ed.recortar(.{ .m = c.matriz, .largura = mo.largura, .altura = mo.altura }, @floatFromInt(mo.escala), false, em_ppm);
    }

    /// Ctrl+C: a seleção (só ela, sem o que estiver em volta) como imagem.
    fn copiarSelecao(ed: *Editor) void {
        if (ed.doc.unica()) |c| if (c.modelo == .moldura) return ed.recortarMoldura(c, false);
        const r = ed.doc.caixaSelecao(ed.vista) orelse {
            ed.avisar("nada selecionado pra copiar", .{});
            return;
        };
        const folga = 12 * ed.vista.fator();
        ed.recortar(ed.regiaoDaTela(r.x0 - folga, r.y0 - folga, r.x1 + folga, r.y1 + folga), 2, true, false);
    }

    // ------------------------------------------------------------ vista

    fn enquadrarTudo(ed: *Editor) void {
        const c = ed.centroDaArea();
        const r = ed.doc.caixaDeTudo() orelse {
            ed.vista = Mat3.translacao(c.x, c.y);
            return;
        };
        const w: f32 = @floatFromInt(@max(1, @as(i32, ed.tela.largura) - ui.largura_painel));
        const h: f32 = @floatFromInt(@max(1, @as(i32, ed.tela.altura) - ui.altura_barra - ui.altura_rodape));
        const s = std.math.clamp(0.9 * @min(w / @max(r.largura(), 1), h / @max(r.altura(), 1)), 0.05, 2);
        ed.vista = Mat3.translacao(c.x, c.y).vezes(Mat3.escala(s, s)).vezes(Mat3.translacao(-(r.x0 + r.x1) / 2, -(r.y0 + r.y1) / 2));
    }

    fn aproximar(ed: *Editor, s: f32, x: f32, y: f32) void {
        const z = ed.vista.fator() * s;
        if (z < 0.02 or z > 60) return;
        ed.vista = Mat3.escala(s, s).emTornoDe(x, y).vezes(ed.vista);
    }

    // ------------------------------------------------------------ texto

    fn textoEmEdicao(ed: *Editor) ?*camada.Texto {
        const c = ed.doc.unica() orelse return null;
        return switch (c.modelo) {
            .texto => |*t| t,
            else => null,
        };
    }

    fn criarTexto(ed: *Editor, x: i32, y: i32) void {
        ed.marcar();
        const zoom_ = @max(ed.vista.fator(), 1e-6);
        const inv = ed.vista.inversa() orelse Mat3.identidade;
        const meia_altura = @as(f32, @floatFromInt(ed.estilo.tamanho)) * fonte.altura / 2;
        var t: camada.Texto = .{ .cor = ed.estilo.cor, .escala = ed.estilo.tamanho };
        t.trocar("");
        _ = ed.doc.adicionar(.{
            .modelo = .{ .texto = t },
            .matriz = inv.vezes(Mat3.translacao(@floatFromInt(x), @floatFromInt(y))).vezes(Mat3.escala(zoom_, zoom_)).vezes(Mat3.translacao(0, -meia_altura)),
        }) catch {
            ed.doc.desmarcar();
            return;
        };
        ed.editando = true;
        ed.texto_novo = true;
        ed.ferramenta = .selecao;
    }

    fn editarTexto(ed: *Editor) void {
        if (ed.textoEmEdicao() == null) return;
        ed.marcar();
        ed.editando = true;
        ed.texto_novo = false;
    }

    /// Termina a digitação; texto que ficou vazio some.
    fn terminarEdicao(ed: *Editor) void {
        if (!ed.editando) return;
        ed.editando = false;
        const t = ed.textoEmEdicao() orelse return;
        if (t.len == 0) {
            ed.doc.apagarSelecionadas();
            if (ed.texto_novo) ed.doc.desmarcar();
        }
    }

    fn digitar(ed: *Editor, ev: anytype) void {
        const t = ed.textoEmEdicao() orelse {
            ed.editando = false;
            return;
        };
        switch (ed.digitacao.traduzir(ed.janela.simbolo(ev.codigo, ev.estado))) {
            .letra => |c| t.inserir(c),
            .apagar => t.apagarUltimo(),
            .confirmar, .cancelar => return ed.terminarEdicao(),
            .nada => return,
        }
        ed.doc.unica().?.gerar(ed.gpa) catch {};
    }

    // ------------------------------------------------------------ propriedades

    fn aplicar(ed: *Editor, p: camada.Propriedade) void {
        if (ed.doc.quantasSelecionadas() == 0) return;
        ed.marcar();
        for (ed.doc.camadas.items) |*c| if (c.selecionada) {
            c.aplicar(ed.gpa, p, ed.estilo) catch {};
        };
    }

    // ------------------------------------------------------------ eventos

    fn teclado(ed: *Editor, t: anytype) !void {
        if (t.codigo == tecla.shift_esq or t.codigo == tecla.shift_dir) {
            ed.shift = t.apertou;
            return;
        }
        if (t.codigo == tecla.espaco and !ed.editando) {
            ed.espaco = t.apertou;
            return;
        }
        if (!t.apertou) return;
        ed.aviso = null;
        ed.mudou = true;
        if (ed.lista != null) {
            if (t.codigo == tecla.esc) ed.fecharLista();
            return;
        }
        if (ed.editando) return ed.digitar(t);

        const c = ed.centroDaArea();
        const zoom_ = @max(ed.vista.fator(), 1e-6);
        if (t.estado & mascara_ctrl != 0) {
            switch (t.codigo) {
                tecla.z => _ = if (ed.shift) try ed.doc.refazer() else try ed.doc.desfazer(),
                tecla.y => _ = try ed.doc.refazer(),
                tecla.d => if (ed.doc.quantasSelecionadas() > 0) {
                    ed.marcar();
                    const inv = ed.vista.inversa() orelse return;
                    // 16 px na tela, pra baixo e pra direita, seja qual for o zoom.
                    const a = inv.aplicar(0, 0);
                    const b = inv.aplicar(16, 16);
                    try ed.doc.duplicar(Mat3.translacao(b.x - a.x, b.y - a.y));
                },
                tecla.a => ed.doc.selecionarTudo(),
                tecla.g => {
                    ed.marcar();
                    if (ed.shift) ed.doc.desagrupar() else ed.doc.agrupar();
                },
                tecla.s => ed.salvarQuadro(),
                tecla.o => ed.abrirLista(true),
                tecla.c => ed.copiarSelecao(),
                else => {},
            }
            return;
        }
        switch (t.codigo) {
            tecla.v => ed.trocarFerramenta(.selecao),
            tecla.p, tecla.b => ed.trocarFerramenta(.pincel),
            tecla.l => ed.trocarFerramenta(.linha),
            tecla.a => ed.trocarFerramenta(.seta),
            tecla.r => ed.trocarFerramenta(.retangulo),
            tecla.o => ed.trocarFerramenta(.elipse),
            tecla.t => ed.trocarFerramenta(.texto),
            tecla.c => ed.trocarFerramenta(.recorte),
            tecla.i => ed.abrirLista(false),
            // E é a borracha; com Shift, Q e E giram a vista.
            tecla.e => if (ed.shift) {
                ed.vista = Mat3.rotacao(passo_giro).emTornoDe(c.x, c.y).vezes(ed.vista);
            } else ed.trocarFerramenta(.borracha),
            tecla.q => if (ed.shift) {
                ed.vista = Mat3.rotacao(-passo_giro).emTornoDe(c.x, c.y).vezes(ed.vista);
            },
            tecla.esc => {
                if (ed.gesto != .nenhum) return;
                if (ed.doc.quantasSelecionadas() > 0) ed.doc.limparSelecao() else ed.ferramenta = .selecao;
            },
            tecla.delete, tecla.backspace => if (ed.doc.quantasSelecionadas() > 0) {
                ed.marcar();
                ed.doc.apagarSelecionadas();
            },
            tecla.enter => if (ed.doc.unica()) |sel| switch (sel.modelo) {
                .texto => ed.editarTexto(),
                .moldura => ed.recortarMoldura(sel, false),
                else => {},
            },
            tecla.page_up, tecla.page_down => if (ed.doc.quantasSelecionadas() > 0) {
                ed.marcar();
                ed.doc.mover(if (t.codigo == tecla.page_up) 1 else -1);
            },
            tecla.cima, tecla.baixo, tecla.esquerda, tecla.direita => if (ed.doc.quantasSelecionadas() > 0) {
                ed.marcar();
                const passo: f32 = if (ed.shift) 10 else 1;
                const dx: f32 = if (t.codigo == tecla.esquerda) -passo else if (t.codigo == tecla.direita) passo else 0;
                const dy: f32 = if (t.codigo == tecla.cima) -passo else if (t.codigo == tecla.baixo) passo else 0;
                ed.doc.transformar(ed.vista, Mat3.translacao(dx, dy));
            },
            // 0: zoom 100% sem giro, no mesmo centro; 1: enquadra tudo.
            tecla.zero => {
                const meio = ed.noMundo(c.x, c.y);
                ed.vista = Mat3.translacao(c.x - meio.x, c.y - meio.y);
            },
            tecla.um => ed.enquadrarTudo(),
            tecla.menos => ed.aproximar(1.0 / passo_zoom, c.x, c.y),
            tecla.igual => ed.aproximar(passo_zoom, c.x, c.y),
            else => {},
        }
        _ = zoom_;
    }

    fn acaoDoMenu(ed: *Editor, acao: ui.Acao) !void {
        if (acao != .cor and acao != .tamanho) ed.terminarEdicao();
        switch (acao) {
            .ferramenta => |f| ed.trocarFerramenta(f),
            .imagem => ed.abrirLista(false),
            .abrir_quadro => ed.abrirLista(true),
            .salvar_quadro => ed.salvarQuadro(),
            .selecionar => |i| {
                if (!ed.shift) ed.doc.limparSelecao();
                ed.doc.marcarSelecao(i, !(ed.shift and ed.doc.camadas.items[i].selecionada));
                ed.ferramenta = .selecao;
            },
            .subir, .descer => {
                ed.marcar();
                ed.doc.mover(if (acao == .subir) 1 else -1);
            },
            .apagar => {
                ed.marcar();
                ed.doc.apagarSelecionadas();
            },
            .duplicar => {
                ed.marcar();
                const inv = ed.vista.inversa() orelse return;
                const a = inv.aplicar(0, 0);
                const b = inv.aplicar(16, 16);
                try ed.doc.duplicar(Mat3.translacao(b.x - a.x, b.y - a.y));
            },
            .agrupar => {
                ed.marcar();
                ed.doc.agrupar();
            },
            .desagrupar => {
                ed.marcar();
                ed.doc.desagrupar();
            },
            .cor => |c| {
                ed.estilo.cor = c;
                ed.aplicar(.cor);
            },
            .fundo => |f| {
                ed.estilo.fundo = f;
                ed.aplicar(.fundo);
            },
            .espessura => |e| {
                ed.estilo.espessura = e;
                ed.aplicar(.espessura);
            },
            .tamanho => |t| {
                ed.estilo.tamanho = t;
                ed.aplicar(.tamanho);
            },
            .mao => |m| {
                ed.estilo.mao = m;
                ed.aplicar(.mao);
            },
            .escala => |e| if (ed.doc.unica()) |c| if (c.modelo == .moldura) {
                ed.marcar();
                ed.doc.unica().?.modelo.moldura.escala = e;
            },
            .recortar => if (ed.doc.unica()) |c| if (c.modelo == .moldura) ed.recortarMoldura(c, false),
            .salvar_ppm => if (ed.doc.unica()) |c| if (c.modelo == .moldura) ed.recortarMoldura(c, true),
            .abrir => |i| ed.escolher(i),
            .cancelar_abrir => ed.fecharLista(),
        }
    }

    fn apertou(ed: *Editor, b: anytype) !void {
        const x: i32 = b.x;
        const y: i32 = b.y;
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        // Rodinha: zoom em torno do cursor (o ponto embaixo do mouse fica
        // parado), ou rola a lista de arquivos.
        if (b.numero == botao.rodinha_cima or b.numero == botao.rodinha_baixo) {
            const sobe = b.numero == botao.rodinha_cima;
            if (ed.lista) |l| {
                const layout = ui.montar(ed.tela.largura, ed.tela.altura, &ed.doc, ed.estadoUi());
                const max = l.nomes.items.len -| layout.linhas_visiveis;
                ed.rolagem = if (sobe) ed.rolagem -| 3 else @min(max, ed.rolagem + 3);
            } else ed.aproximar(if (sobe) passo_zoom else 1.0 / passo_zoom, fx, fy);
            return;
        }
        ed.aviso = null;
        const layout = ui.montar(ed.tela.largura, ed.tela.altura, &ed.doc, ed.estadoUi());
        if (layout.dentro(x, y)) {
            if (b.numero != botao.esquerdo) return;
            if (layout.clicar(x, y)) |acao| try ed.acaoDoMenu(acao);
            return;
        }
        if (b.numero == botao.direito or b.numero == botao.meio or (b.numero == botao.esquerdo and ed.espaco)) {
            ed.gesto = .{ .vista = .{ .x = x, .y = y } };
            return;
        }
        if (b.numero != botao.esquerdo) return;

        const duplo = b.tempo -% ed.ultimo_clique.tempo < duplo_ms and @abs(x - ed.ultimo_clique.x) < 6 and @abs(y - ed.ultimo_clique.y) < 6;
        ed.ultimo_clique = .{ .tempo = b.tempo, .x = x, .y = y };
        if (ed.editando) {
            ed.terminarEdicao();
            if (ed.ferramenta == .selecao and !duplo) {
                // O clique que termina a digitação não seleciona outra coisa.
                return;
            }
        }

        switch (ed.ferramenta) {
            .selecao => {
                if (duplo) {
                    if (ed.doc.tocar(ed.vista, x, y)) |i| {
                        if (ed.doc.camadas.items[i].modelo == .texto) {
                            ed.doc.limparSelecao();
                            ed.doc.camadas.items[i].selecionada = true;
                            ed.editarTexto();
                        }
                    } else ed.criarTexto(x, y);
                    return;
                }
                if (alcas.Alvo.de(&ed.doc, ed.vista)) |alvo| {
                    if (alvo.tocar(x, y)) |a| {
                        ed.marcar();
                        if (alcas.Arrasto.iniciar(&ed.doc, alvo, a, x, y)) |ar| ed.gesto = .{ .alca = ar };
                        return;
                    }
                }
                const tocado = ed.doc.tocar(ed.vista, x, y);
                if (ed.shift) {
                    if (tocado) |i| {
                        ed.doc.marcarSelecao(i, !ed.doc.camadas.items[i].selecionada);
                    } else ed.gesto = .{ .area = .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y } };
                    return;
                }
                const dentro_selecao = if (alcas.Alvo.de(&ed.doc, ed.vista)) |a| a.dentro(x, y) else false;
                if (tocado) |i| {
                    if (!ed.doc.camadas.items[i].selecionada) {
                        ed.doc.limparSelecao();
                        ed.doc.marcarSelecao(i, true);
                    }
                } else if (!dentro_selecao) {
                    ed.doc.limparSelecao();
                    ed.gesto = .{ .area = .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y } };
                    return;
                }
                ed.marcar();
                ed.doc.iniciarArrasto();
                ed.gesto = .{ .mover = .{ .x0 = x, .y0 = y } };
            },
            .pincel => {
                ed.marcar();
                var t: camada.Traco = .{ .cor = ed.estilo.cor, .espessura = ed.estilo.espessura };
                try t.pontos.append(ed.gpa, ed.noMundo(fx, fy));
                _ = ed.doc.adicionar(.{ .modelo = .{ .desenho = t } }) catch |err| {
                    t.pontos.deinit(ed.gpa);
                    return err;
                };
                ed.gesto = .pincel;
            },
            .linha, .seta => {
                ed.marcar();
                var t: camada.Traco = .{ .cor = ed.estilo.cor, .espessura = ed.estilo.espessura, .mao = ed.estilo.mao };
                const p = ed.noMundo(fx, fy);
                try t.pontos.appendSlice(ed.gpa, &.{ p, p });
                _ = ed.doc.adicionar(.{ .modelo = if (ed.ferramenta == .linha) .{ .linha = t } else .{ .seta = t } }) catch |err| {
                    t.pontos.deinit(ed.gpa);
                    return err;
                };
                ed.gesto = .{ .forma = .{ .x0 = x, .y0 = y } };
            },
            .retangulo, .elipse => {
                ed.marcar();
                const f: camada.Forma = .{ .largura = 0, .altura = 0, .cor = ed.estilo.cor, .fundo = ed.estilo.fundo, .espessura = ed.estilo.espessura, .mao = ed.estilo.mao };
                const r = ed.regiaoDaTela(fx, fy, fx, fy);
                _ = try ed.doc.adicionar(.{ .modelo = if (ed.ferramenta == .retangulo) .{ .retangulo = f } else .{ .elipse = f }, .matriz = r.m });
                ed.gesto = .{ .forma = .{ .x0 = x, .y0 = y } };
            },
            .texto => ed.criarTexto(x, y),
            .borracha => {
                ed.marcar();
                ed.gesto = .{ .borracha = .{} };
                ed.apagarEmbaixo(x, y);
            },
            .recorte => ed.gesto = .{ .recorte = .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y } },
        }
    }

    fn apagarEmbaixo(ed: *Editor, x: i32, y: i32) void {
        const i = ed.doc.tocar(ed.vista, x, y) orelse return;
        ed.doc.limparSelecao();
        ed.doc.marcarSelecao(i, true);
        ed.doc.apagarSelecionadas();
        ed.gesto.borracha.apagou = true;
    }

    /// Ponta da linha com Shift: o ângulo vai de 15 em 15°.
    fn pontaComShift(ed: *const Editor, x0: i32, y0: i32, x: i32, y: i32) Ponto {
        const dx: f32 = @floatFromInt(x - x0);
        const dy: f32 = @floatFromInt(y - y0);
        if (!ed.shift) return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
        const l = @sqrt(dx * dx + dy * dy);
        const ang = @round(std.math.atan2(dy, dx) / passo_giro) * passo_giro;
        return .{ .x = @as(f32, @floatFromInt(x0)) + l * @cos(ang), .y = @as(f32, @floatFromInt(y0)) + l * @sin(ang) };
    }

    fn arrastou(ed: *Editor, x: i32, y: i32) void {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        switch (ed.gesto) {
            .nenhum => return,
            .vista => |*a| {
                ed.vista = Mat3.translacao(@floatFromInt(x - a.x), @floatFromInt(y - a.y)).vezes(ed.vista);
                a.* = .{ .x = x, .y = y };
            },
            .mover => |*m| {
                ed.doc.arrastar(ed.vista, Mat3.translacao(@floatFromInt(x - m.x0), @floatFromInt(y - m.y0)));
                m.moveu = true;
            },
            .alca => |*ar| ar.mover(&ed.doc, ed.vista, x, y, ed.shift),
            .area => |*a| {
                a.x1 = x;
                a.y1 = y;
            },
            .recorte => |*a| {
                a.x1 = x;
                a.y1 = y;
            },
            .pincel => {
                const c = ed.doc.unica() orelse return;
                const t = c.traco() orelse return;
                const ultimo = ed.vista.aplicar(t.pontos.items[t.pontos.items.len - 1].x, t.pontos.items[t.pontos.items.len - 1].y);
                // Ponto novo só depois de andar um pouco: menos pontos, e a
                // suavização no fim cuida do resto.
                const dx = fx - ultimo.x;
                const dy = fy - ultimo.y;
                if (dx * dx + dy * dy < 2.5 * 2.5) return;
                t.pontos.append(ed.gpa, ed.noMundo(fx, fy)) catch return;
            },
            .forma => |f| {
                const c = ed.doc.unica() orelse return;
                switch (c.modelo) {
                    .linha, .seta => |*t| {
                        const p = ed.pontaComShift(f.x0, f.y0, x, y);
                        t.pontos.items[1] = ed.noMundo(p.x, p.y);
                    },
                    .retangulo, .elipse => |*fo| {
                        var x1 = fx;
                        var y1 = fy;
                        if (ed.shift) {
                            // Quadrado / círculo: o lado maior manda.
                            const dx = fx - @as(f32, @floatFromInt(f.x0));
                            const dy = fy - @as(f32, @floatFromInt(f.y0));
                            const l = @max(@abs(dx), @abs(dy));
                            x1 = @as(f32, @floatFromInt(f.x0)) + std.math.copysign(l, dx);
                            y1 = @as(f32, @floatFromInt(f.y0)) + std.math.copysign(l, dy);
                        }
                        const r = ed.regiaoDaTela(@floatFromInt(f.x0), @floatFromInt(f.y0), x1, y1);
                        c.matriz = r.m;
                        fo.largura = r.largura;
                        fo.altura = r.altura;
                    },
                    else => {},
                }
            },
            .borracha => ed.apagarEmbaixo(x, y),
        }
        ed.mudou = true;
    }

    fn soltou(ed: *Editor, b: anytype) void {
        if (b.numero == botao.rodinha_cima or b.numero == botao.rodinha_baixo) return;
        const gesto = ed.gesto;
        ed.gesto = .nenhum;
        ed.mudou = true;
        switch (gesto) {
            .nenhum, .vista => {},
            .mover => |m| if (!m.moveu) ed.doc.desmarcar(),
            .alca => ed.doc.assentarEscala(),
            .area => |a| {
                const r: Retangulo = .{ .x0 = @floatFromInt(@min(a.x0, a.x1)), .y0 = @floatFromInt(@min(a.y0, a.y1)), .x1 = @floatFromInt(@max(a.x0, a.x1)), .y1 = @floatFromInt(@max(a.y0, a.y1)) };
                if (r.largura() > 2 or r.altura() > 2) ed.doc.selecionarArea(ed.vista, r);
            },
            .pincel => if (ed.doc.unica()) |c| if (c.traco()) |t| {
                t.suavizar(ed.gpa, 2) catch {};
            },
            .forma => |f| {
                // Clique sem arrastar não deixa objeto de tamanho zero.
                if (@abs(b.x - f.x0) < 3 and @abs(b.y - f.y0) < 3) {
                    ed.doc.apagarSelecionadas();
                    ed.doc.desmarcar();
                    return;
                }
                ed.ferramenta = .selecao;
            },
            .borracha => |br| if (!br.apagou) ed.doc.desmarcar(),
            .recorte => |a| {
                if (@abs(a.x1 - a.x0) < 4 or @abs(a.y1 - a.y0) < 4) return;
                const r = ed.regiaoDaTela(@floatFromInt(a.x0), @floatFromInt(a.y0), @floatFromInt(a.x1), @floatFromInt(a.y1));
                ed.marcar();
                const c = ed.doc.adicionar(.{ .modelo = .{ .moldura = .{ .largura = r.largura, .altura = r.altura, .numero = 0 } }, .matriz = r.m }) catch {
                    ed.doc.desmarcar();
                    return;
                };
                ed.recortarMoldura(c, false);
                ed.ferramenta = .selecao;
            },
        }
    }

    fn movimento(ed: *Editor, x: i32, y: i32, layout: *const ui.Layout) void {
        ed.mouse = .{ .x = x, .y = y };
        const novo_sobre = layout.sobre(x, y);
        if (!std.meta.eql(novo_sobre, ed.sobre)) {
            ed.sobre = novo_sobre;
            ed.mudou = true;
        }
        if (ed.gesto != .nenhum) return ed.arrastou(x, y);
        if (ed.ferramenta == .selecao) {
            const nova = if (alcas.Alvo.de(&ed.doc, ed.vista)) |a| a.tocar(x, y) else null;
            if (nova != ed.sobre_alca) {
                ed.sobre_alca = nova;
                ed.mudou = true;
            }
        }
    }

    // ------------------------------------------------------------ pintar

    /// Grade de pontos do quadro. O espaço entre os pontos dobra quando o
    /// zoom diminui, pra não virar uma mancha cinza.
    fn grade(ed: *Editor) void {
        const zoom_ = ed.vista.fator();
        var passo: f32 = espaco_grade;
        while (passo * zoom_ < 14) passo *= 2;
        const inv = ed.vista.inversa() orelse return;
        const area: Retangulo = .{ .x0 = 0, .y0 = 0, .x1 = @floatFromInt(ed.tela.largura), .y1 = @floatFromInt(ed.tela.altura) };
        const mundo = area.transformado(inv);
        var gy = @floor(mundo.y0 / passo) * passo;
        while (gy <= mundo.y1) : (gy += passo) {
            var gx = @floor(mundo.x0 / passo) * passo;
            while (gx <= mundo.x1) : (gx += passo) {
                const p = ed.vista.aplicar(gx, gy);
                const px = tela_.paraInt(p.x);
                const py = tela_.paraInt(p.y);
                ed.tela.ponto(px, py, cor_grade);
                if (zoom_ > 1.5) ed.tela.ponto(px + 1, py, cor_grade);
            }
        }
    }

    fn retanguloTracejado(ed: *Editor, x0: i32, y0: i32, x1: i32, y1: i32, cor: Cor) void {
        const a: f32 = @floatFromInt(x0);
        const b: f32 = @floatFromInt(y0);
        const c: f32 = @floatFromInt(x1);
        const d: f32 = @floatFromInt(y1);
        ed.tela.tracejada(a, b, c, b, 5, cor);
        ed.tela.tracejada(c, b, c, d, 5, cor);
        ed.tela.tracejada(c, d, a, d, 5, cor);
        ed.tela.tracejada(a, d, a, b, 5, cor);
    }

    fn pintar(ed: *Editor) !void {
        ed.tela.limpar(papel);
        ed.grade();
        ed.doc.desenhar(&ed.tela, ed.vista);
        ed.doc.desenharMolduras(&ed.tela, ed.vista);

        // Seleção: caixa fina em cada um (se forem vários) e as alças.
        const n_sel = ed.doc.quantasSelecionadas();
        if (n_sel > 1) {
            for (ed.doc.camadas.items) |*c| if (c.selecionada) {
                const r = ed.doc.caixaNaTela(c, ed.vista);
                ed.retanguloTracejado(tela_.paraInt(r.x0), tela_.paraInt(r.y0), tela_.paraInt(r.x1), tela_.paraInt(r.y1), cor_selecao);
            };
        }
        if (n_sel > 0 and ed.ferramenta == .selecao and ed.gesto != .pincel) {
            if (alcas.Alvo.de(&ed.doc, ed.vista)) |a| alcas.desenhar(&ed.tela, a, ed.sobre_alca);
        }
        // Cursor no fim do texto sendo digitado.
        if (ed.editando) if (ed.doc.unica()) |c| if (c.cache) |px| {
            const m = ed.vista.vezes(c.matriz);
            const w: f32 = @floatFromInt(if (c.modelo.texto.len == 0) 0 else px.largura);
            const a = m.aplicar(w + 2, 0);
            const b = m.aplicar(w + 2, @floatFromInt(px.altura));
            ed.tela.tracar(a.x, a.y, b.x, b.y, 1, cor_selecao);
            ed.tela.pintarMascara(cor_selecao);
        };
        switch (ed.gesto) {
            .area => |a| ed.retanguloTracejado(a.x0, a.y0, a.x1, a.y1, cor_selecao),
            .recorte => |a| {
                ed.retanguloTracejado(a.x0, a.y0, a.x1, a.y1, camada.cor_moldura);
                var buf: [40]u8 = undefined;
                const zoom_ = @max(ed.vista.fator(), 1e-6);
                const w: u32 = @intFromFloat(@abs(@as(f32, @floatFromInt(a.x1 - a.x0))) / zoom_ * 2);
                const h: u32 = @intFromFloat(@abs(@as(f32, @floatFromInt(a.y1 - a.y0))) / zoom_ * 2);
                const s = std.fmt.bufPrint(&buf, "{d}×{d} px (2×)", .{ w, h }) catch "";
                _ = fonte.escrever(&ed.tela, @min(a.x0, a.x1), @max(a.y0, a.y1) + 4, s, camada.cor_moldura, 1);
            },
            else => {},
        }
        const estado = ed.estadoUi();
        const layout = ui.montar(ed.tela.largura, ed.tela.altura, &ed.doc, estado);
        ui.desenhar(&ed.tela, &layout, ed.sobre, estado);
        try ed.janela.mostrar(ed.tela.pixels, ed.tela.largura, ed.tela.altura);
    }
};

pub fn main(init: std.process.Init) !void {
    // Argumento: a pasta das imagens e dos quadros, ou um .quadro pra abrir.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const arg: []const u8 = if (args.len > 1) args[1] else ".";
    const eh_quadro = std.mem.endsWith(u8, arg, ".quadro");
    const pasta = if (eh_quadro) (std.fs.path.dirname(arg) orelse ".") else arg;

    var janela = try x11.Janela.abrir(init.gpa, init.environ_map, "editor", 1200, 760);
    defer janela.fechar();

    var ed: Editor = .{
        .init = init,
        .gpa = init.gpa,
        .janela = &janela,
        .doc = Documento.criar(init.gpa),
        .tela = try Tela.criar(init.gpa, 1200, 760, papel),
        .pasta = pasta,
    };
    defer ed.doc.destruir();
    defer ed.tela.destruir();
    defer ed.fecharLista();
    ed.enquadrarTudo();
    if (eh_quadro) ed.abrirQuadro(arg);

    laco: while (true) {
        // Dorme até chegar um evento, trata todos os que já chegaram e só então redesenha.
        var evento = try janela.proximo(true);
        while (evento) |e| : (evento = try janela.proximo(false)) {
            switch (e) {
                .fechar => break :laco,
                .expor => ed.mudou = true,
                .redimensionar => |r| {
                    try ed.tela.redimensionar(r.largura, r.altura, papel);
                    ed.mudou = true;
                },
                .tecla => |t| try ed.teclado(t),
                .botao => |b| {
                    ed.mudou = true;
                    if (b.apertou) try ed.apertou(b) else ed.soltou(b);
                },
                .movimento => |m| {
                    const layout = ui.montar(ed.tela.largura, ed.tela.altura, &ed.doc, ed.estadoUi());
                    ed.movimento(m.x, m.y, &layout);
                },
            }
        }
        if (ed.mudou) {
            try ed.pintar();
            ed.mudou = false;
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
    _ = @import("digitar.zig");
    _ = @import("alcas.zig");
    _ = @import("ppm.zig");
    _ = @import("png.zig");
    _ = @import("quadro.zig");
    _ = @import("arquivos.zig");
}
