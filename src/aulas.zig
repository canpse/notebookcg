//! CG Interativa: um software educacional de Computação Gráfica.
//!
//! Cada aula é uma tela com uma demonstração que o aluno mexe com o mouse e
//! o teclado, e um painel que mostra, ao vivo, os números por trás do que
//! está na tela (a matriz, o código de região, a profundidade, a conta da
//! iluminação). Tudo feito do zero: a janela fala o protocolo do X11, cada
//! pixel é pintado num vetor na memória (`tela.zig`), as transformações são
//! matrizes em coordenadas homogêneas (`mat3.zig`, `tres_d.zig`).
const std = @import("std");
const linux = std.os.linux;
const x11 = @import("x11.zig");
const tela_ = @import("tela.zig");
const Tela = tela_.Tela;
const Cor = tela_.Cor;
const Caixa = tela_.Caixa;
const opaco = tela_.opaco;
const paraInt = tela_.paraInt;
const fonte = @import("fonte.zig");
const Mat3 = @import("mat3.zig").Mat3;
const td = @import("tres_d.zig");
const Vec3 = td.Vec3;
const Mat4 = td.Mat4;

pub const cores = struct {
    pub const demo = opaco | 0xf8f7f4;
    pub const painel = opaco | 0x1d1d22;
    pub const lateral = opaco | 0x26262c;
    pub const texto = opaco | 0xe6e6e6;
    pub const fraco = opaco | 0x9a9aa6;
    pub const destaque = opaco | 0x8b7cf6;
    pub const valor = opaco | 0xf5c84c;
    pub const tinta = opaco | 0x1e1e1e;
    pub const grade = opaco | 0xe2dfd8;
    pub const cinza = opaco | 0x9a978f;
    pub const vermelho = opaco | 0xe03e3e;
    pub const verde = opaco | 0x2f9e44;
    pub const azul = opaco | 0x1971c2;
    pub const laranja = opaco | 0xf08c00;
    pub const roxo = opaco | 0x6e56cf;
    pub const branco = opaco | 0xffffff;
};

const largura_lateral = 230;
const largura_painel = 420;

const titulos = [_][]const u8{
    "Framebuffer e pixels",
    "Rasterização de retas",
    "Transformações 2D",
    "Janela -> viewport",
    "Recorte de retas",
    "Projeção 3D",
    "Superfícies ocultas",
    "Iluminação e shading",
    "Animação",
};

// ---------------------------------------------------------------------------
// Painel de texto da direita

pub const Painel = struct {
    texto: [16384]u8 = undefined,
    n: usize = 0,
    linhas: [200]Linha = undefined,
    nl: usize = 0,

    pub const Tipo = enum { titulo, texto, mono, espaco };
    const Linha = struct { ini: usize, fim: usize, cor: Cor, tipo: Tipo };

    pub fn add(p: *Painel, tipo: Tipo, cor: Cor, comptime fmt: []const u8, args: anytype) void {
        if (p.nl >= p.linhas.len) return;
        const s = std.fmt.bufPrint(p.texto[p.n..], fmt, args) catch return;
        p.linhas[p.nl] = .{ .ini = p.n, .fim = p.n + s.len, .cor = cor, .tipo = tipo };
        p.n += s.len;
        p.nl += 1;
    }
    pub fn titulo(p: *Painel, comptime s: []const u8) void {
        p.add(.titulo, cores.destaque, s, .{});
    }
    pub fn txt(p: *Painel, comptime s: []const u8) void {
        p.add(.texto, cores.texto, s, .{});
    }
    pub fn ctl(p: *Painel, comptime s: []const u8) void {
        p.add(.mono, cores.fraco, s, .{});
    }
    pub fn val(p: *Painel, comptime fmt: []const u8, args: anytype) void {
        p.add(.mono, cores.valor, fmt, args);
    }
    pub fn esp(p: *Painel) void {
        p.add(.espaco, 0, "", .{});
    }
    pub fn mat3(p: *Painel, nome: []const u8, m: Mat3) void {
        for (0..3) |i| p.val("{s:<4}[{d:>7.2} {d:>7.2} {d:>7.2} ]", .{ if (i == 1) nome else "", m.m[i][0], m.m[i][1], m.m[i][2] });
    }
    pub fn mat4(p: *Painel, nome: []const u8, m: Mat4) void {
        for (0..4) |i| p.val("{s:<4}[{d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} ]", .{ if (i == 1) nome else "", m.m[i][0], m.m[i][1], m.m[i][2], m.m[i][3] });
    }
};

// ---------------------------------------------------------------------------
// O aplicativo

const Botao = struct { numero: u8, x: i32, y: i32, shift: bool };

pub const App = struct {
    gpa: std.mem.Allocator,
    janela: *x11.Janela,
    tela: Tela,
    zbuf: []f32 = &.{},
    aula: usize = 0,
    mx: i32 = 0,
    my: i32 = 0,
    /// Botão apertado agora (0 = nenhum).
    botao: u8 = 0,
    shift: bool = false,
    /// Duração do último quadro pintado, em ms (aparece na aula de animação).
    quadro_ms: f32 = 0,

    fb: Framebuffer = .{},
    re: Retas = .{},
    tr: Transformacoes = .{},
    jv: JanelaViewport = .{},
    rc: RecorteAula = .{},
    pj: Projecao = .{},
    oc: Ocultas = .{},
    il: Iluminacao = .{},
    an: Animacao = .{},

    const campos = [_][]const u8{ "fb", "re", "tr", "jv", "rc", "pj", "oc", "il", "an" };

    /// Chama `nome` na aula atual, se ela tiver esse método.
    fn naAula(app: *App, comptime nome: []const u8, args: anytype) void {
        switch (app.aula) {
            inline 0...campos.len - 1 => |i| {
                const s = &@field(app, campos[i]);
                const T = @TypeOf(s.*);
                if (@hasDecl(T, nome)) @call(.auto, @field(T, nome), .{ s, app } ++ args);
            },
            else => {},
        }
    }

    pub fn area(app: *const App) Caixa {
        return .{ .x0 = largura_lateral, .y0 = 0, .x1 = @max(largura_lateral + 100, @as(i32, app.tela.largura) - largura_painel), .y1 = app.tela.altura };
    }

    fn animando(app: *const App) bool {
        return switch (app.aula) {
            1 => app.re.anim,
            2 => app.tr.anim,
            5 => app.pj.auto,
            8 => !app.an.pausado,
            else => false,
        };
    }

    fn passo(app: *App, dt: f32) void {
        switch (app.aula) {
            1 => app.re.t += dt,
            2 => app.tr.ang += 45 * dt,
            5 => app.pj.yaw += 0.6 * dt,
            8 => app.an.t += dt * app.an.vel,
            else => {},
        }
    }

    // --- desenho -----------------------------------------------------------

    pub fn linha(app: *App, ax: f32, ay: f32, bx: f32, by: f32, esp: f32, cor: Cor) void {
        app.tela.tracar(ax, ay, bx, by, esp / 2, cor);
        app.tela.pintarMascara(cor);
    }
    pub fn tracejada(app: *App, ax: f32, ay: f32, bx: f32, by: f32, cor: Cor) void {
        app.tela.tracejada(ax, ay, bx, by, 5, cor);
    }
    pub fn seta(app: *App, ax: f32, ay: f32, bx: f32, by: f32, esp: f32, cor: Cor) void {
        app.linha(ax, ay, bx, by, esp, cor);
        const dx = bx - ax;
        const dy = by - ay;
        const l = @sqrt(dx * dx + dy * dy);
        if (l < 1) return;
        const ux = dx / l;
        const uy = dy / l;
        const k: f32 = 9;
        app.linha(bx, by, bx - k * ux - k * 0.5 * uy, by - k * uy + k * 0.5 * ux, esp, cor);
        app.linha(bx, by, bx - k * ux + k * 0.5 * uy, by - k * uy - k * 0.5 * ux, esp, cor);
    }
    pub fn texto(app: *App, x: i32, y: i32, s: []const u8, cor: Cor) void {
        _ = fonte.escrever(&app.tela, x, y, s, cor, 1);
    }
    pub fn textoF(app: *App, x: i32, y: i32, cor: Cor, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        app.texto(x, y, s, cor);
    }
    pub fn ret(app: *App, x0: i32, y0: i32, x1: i32, y1: i32, cor: Cor) void {
        app.tela.retangulo(.{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }, cor);
    }
    pub fn contorno(app: *App, x0: i32, y0: i32, x1: i32, y1: i32, cor: Cor) void {
        app.ret(x0, y0, x1, y0 + 1, cor);
        app.ret(x0, y1 - 1, x1, y1, cor);
        app.ret(x0, y0, x0 + 1, y1, cor);
        app.ret(x1 - 1, y0, x1, y1, cor);
    }
    pub fn circulo(app: *App, x: f32, y: f32, r: f32, cor: Cor) void {
        app.tela.disco(paraInt(x), paraInt(y), paraInt(r), cor);
    }

    fn pintar(app: *App) !void {
        var ini: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ini);

        const a = app.area();
        const n: usize = @intCast((a.x1 - a.x0) * (a.y1 - a.y0));
        if (app.zbuf.len != n) {
            app.gpa.free(app.zbuf);
            app.zbuf = try app.gpa.alloc(f32, n);
        }
        app.tela.limpar(cores.demo);
        var p: Painel = .{};
        p.add(.titulo, cores.texto, "{d}. {s}", .{ app.aula + 1, titulos[app.aula] });
        app.naAula("pintar", .{&p});
        app.pintarLateral();
        app.pintarPainel(&p);
        try app.janela.mostrar(app.tela.pixels, app.tela.largura, app.tela.altura);

        var fim: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &fim);
        app.quadro_ms = @as(f32, @floatFromInt(fim.sec - ini.sec)) * 1000 + @as(f32, @floatFromInt(fim.nsec - ini.nsec)) / 1e6;
    }

    fn pintarLateral(app: *App) void {
        app.ret(0, 0, largura_lateral, app.tela.altura, cores.lateral);
        _ = fonte.escrever(&app.tela, 16, 16, "CG Interativa", cores.texto, 2);
        app.texto(16, 52, "Computação Gráfica", cores.fraco);
        for (titulos, 0..) |t, i| {
            const y: i32 = 90 + @as(i32, @intCast(i)) * 36;
            const atual = i == app.aula;
            const sobre = app.mx < largura_lateral and app.my >= y and app.my < y + 32;
            if (atual) app.ret(8, y, largura_lateral - 8, y + 32, cores.roxo) else if (sobre) app.ret(8, y, largura_lateral - 8, y + 32, opaco | 0x34343c);
            app.textoF(18, y + 8, if (atual) cores.branco else cores.fraco, "{d}", .{i + 1});
            app.texto(40, y + 8, t, if (atual) cores.branco else cores.texto);
        }
        const yb: i32 = @as(i32, app.tela.altura) - 60;
        app.texto(16, yb, "1-9 ou clique: aula", cores.fraco);
        app.texto(16, yb + 20, "PgUp/PgDn: anterior/próx.", cores.fraco);
    }

    fn pintarPainel(app: *App, p: *Painel) void {
        const x0: i32 = @as(i32, app.tela.largura) - largura_painel;
        app.ret(x0, 0, app.tela.largura, app.tela.altura, cores.painel);
        const x = x0 + 16;
        const maxw = largura_painel - 32;
        var y: i32 = 16;
        for (p.linhas[0..p.nl], 0..) |l, i| {
            const s = p.texto[l.ini..l.fim];
            switch (l.tipo) {
                .espaco => y += 8,
                .titulo => {
                    if (i == 0) {
                        _ = fonte.escrever(&app.tela, x, y, s, l.cor, 2);
                        y += 44;
                    } else {
                        y += 8;
                        app.texto(x, y, s, l.cor);
                        app.ret(x, y + 17, x + fonte.medir(s, 1), y + 18, l.cor);
                        y += 24;
                    }
                },
                .mono => {
                    app.texto(x, y, s, l.cor);
                    y += 17;
                },
                .texto => {
                    var cx: i32 = 0;
                    var it = std.mem.splitScalar(u8, s, ' ');
                    while (it.next()) |palavra| {
                        const w = fonte.medir(palavra, 1);
                        if (cx > 0 and cx + w > maxw) {
                            cx = 0;
                            y += 17;
                        }
                        app.texto(x + cx, y, palavra, l.cor);
                        cx += w + 8;
                    }
                    y += 19;
                },
            }
        }
    }

    // --- eventos -------------------------------------------------------------

    fn irPara(app: *App, i: usize) void {
        if (i < titulos.len) app.aula = i;
    }

    fn tecla(app: *App, ev: anytype) void {
        app.shift = ev.estado & 1 != 0;
        if (!ev.apertou) return;
        const s = app.janela.simbolo(ev.codigo, ev.estado);
        switch (s) {
            '1'...'9' => return app.irPara(s - '1'),
            0xff55 => return app.irPara(if (app.aula == 0) titulos.len - 1 else app.aula - 1),
            0xff56 => return app.irPara((app.aula + 1) % titulos.len),
            else => {},
        }
        app.naAula("tecla", .{s});
    }

    fn apertou(app: *App, b: Botao) void {
        if (b.x < largura_lateral) {
            if (b.numero != 1) return;
            const i = @divFloor(b.y - 90, 36);
            if (i >= 0 and b.y >= 90) app.irPara(@intCast(i));
            return;
        }
        if (b.x >= @as(i32, app.tela.largura) - largura_painel) return;
        if (b.numero <= 3) app.botao = b.numero;
        app.naAula("apertou", .{b});
    }

    fn soltou(app: *App, b: Botao) void {
        if (b.numero == app.botao) {
            app.botao = 0;
            app.naAula("soltou", .{b});
        }
    }

    fn moveu(app: *App, x: i32, y: i32) void {
        const dx = x - app.mx;
        const dy = y - app.my;
        app.mx = x;
        app.my = y;
        app.naAula("moveu", .{ dx, dy });
    }
};

fn fl(v: i32) f32 {
    return @floatFromInt(v);
}

const Rand = struct {
    s: u32 = 12345,
    fn f(r: *Rand) f32 {
        r.s = r.s *% 1664525 +% 1013904223;
        return @as(f32, @floatFromInt(r.s >> 8)) / 16777216.0;
    }
};

fn misturaCor(a: Cor, b: Cor, t: f32) Cor {
    return td.corDe(td.rgbDe(a).vezes(1 - t).mais(td.rgbDe(b).vezes(t)));
}

// ===========================================================================
// 1. Framebuffer

const Framebuffer = struct {
    const NX = 32;
    const NY = 20;
    const paleta = [_]Cor{ opaco | 0xffffff, cores.vermelho, cores.verde, opaco | 0x3b82f6, opaco | 0xfacc15, opaco | 0x22d3ee, opaco | 0xe879f9, cores.laranja };

    px: [NY][NX]Cor = blk: {
        var p: [NY][NX]Cor = @splat(@splat(opaco));
        p[4][7] = opaco | 0xffffff; // framebuffer[4][7] = 1, o primeiro exercício da aula
        break :blk p;
    },
    cor_i: usize = 0,
    apagando: bool = false,

    const Geo = struct { x0: i32, y0: i32, s: i32 };
    fn geo(app: *const App) Geo {
        const a = app.area();
        const s = @max(4, @min(@divFloor(a.x1 - a.x0 - 40, NX), @divFloor(a.y1 - a.y0 - 190, NY)));
        return .{ .x0 = a.x0 + @divFloor(a.x1 - a.x0 - s * NX, 2), .y0 = a.y0 + 30, .s = s };
    }
    fn celula(app: *const App) ?[2]usize {
        const g = geo(app);
        const cx = @divFloor(app.mx - g.x0, g.s);
        const cy = @divFloor(app.my - g.y0, g.s);
        if (cx < 0 or cy < 0 or cx >= NX or cy >= NY) return null;
        return .{ @intCast(cx), @intCast(cy) };
    }
    fn aplicar(f: *Framebuffer, app: *const App) void {
        if (app.botao == 0) return;
        const c = celula(app) orelse return;
        f.px[c[1]][c[0]] = if (f.apagando) opaco else paleta[f.cor_i];
    }

    pub fn apertou(f: *Framebuffer, app: *App, b: Botao) void {
        f.apagando = b.numero == 3;
        f.aplicar(app);
    }
    pub fn moveu(f: *Framebuffer, app: *App, _: i32, _: i32) void {
        f.aplicar(app);
    }
    pub fn tecla(f: *Framebuffer, _: *App, s: u32) void {
        switch (s) {
            'c' => f.cor_i = (f.cor_i + 1) % paleta.len,
            'l' => f.px = @splat(@splat(opaco)),
            'g' => for (0..NY) |y| for (0..NX) |x| {
                const r: u32 = @intCast(x * 255 / (NX - 1));
                const g: u32 = @intCast(y * 255 / (NY - 1));
                f.px[y][x] = opaco | (r << 16) | (g << 8) | 0x60;
            },
            else => {},
        }
    }

    pub fn pintar(f: *Framebuffer, app: *App, p: *Painel) void {
        const g = geo(app);
        for (0..NY) |y| for (0..NX) |x| {
            const x0 = g.x0 + @as(i32, @intCast(x)) * g.s;
            const y0 = g.y0 + @as(i32, @intCast(y)) * g.s;
            app.ret(x0, y0, x0 + g.s, y0 + g.s, opaco | 0x3a3a40);
            app.ret(x0 + 1, y0 + 1, x0 + g.s, y0 + g.s, f.px[y][x]);
        };
        app.texto(g.x0, g.y0 - 22, "framebuffer[20][32]: cada quadrado é um pixel", cores.cinza);
        const sob = celula(app);
        if (sob) |c| {
            const x0 = g.x0 + @as(i32, @intCast(c[0])) * g.s;
            const y0 = g.y0 + @as(i32, @intCast(c[1])) * g.s;
            app.contorno(x0 - 1, y0 - 1, x0 + g.s + 2, y0 + g.s + 2, cores.laranja);
        }
        // Em tamanho real: o mesmo vetor, 1 pixel do framebuffer = 1 pixel do monitor.
        const yb = g.y0 + g.s * NY + 30;
        app.texto(g.x0, yb, "tamanho real (1:1)", cores.cinza);
        app.texto(g.x0 + 200, yb, "ampliado 4x", cores.cinza);
        for (0..NY) |y| for (0..NX) |x| {
            const c = f.px[y][x];
            app.tela.ponto(g.x0 + @as(i32, @intCast(x)), yb + 24 + @as(i32, @intCast(y)), c);
            const k: i32 = 4;
            app.ret(g.x0 + 200 + @as(i32, @intCast(x)) * k, yb + 24 + @as(i32, @intCast(y)) * k, g.x0 + 200 + @as(i32, @intCast(x + 1)) * k, yb + 24 + @as(i32, @intCast(y + 1)) * k, c);
        };

        p.titulo("O que é");
        p.txt("A imagem na tela é uma matriz de pixels guardada na memória: o framebuffer. O monitor lê essa memória várias vezes por segundo e acende cada ponto com a cor que está lá.");
        p.txt("Cada pixel guarda uma cor em RGB: 3 números de 0 a 255 (8 bits cada), juntos num inteiro de 32 bits 0xRRGGBB.");
        p.txt("A matriz é guardada linha por linha num vetor só: o pixel (x, y) fica no índice y * largura + x.");
        p.titulo("Ao vivo");
        if (sob) |c| {
            const cor = f.px[c[1]][c[0]] & 0xffffff;
            p.val("framebuffer[{d}][{d}]  (y, x)", .{ c[1], c[0] });
            p.val("índice = {d}*32 + {d} = {d}", .{ c[1], c[0], c[1] * NX + c[0] });
            p.val("byte   = índice * 4 = {d}", .{(c[1] * NX + c[0]) * 4});
            p.val("cor = 0x{x:0>6}  R={d} G={d} B={d}", .{ cor, cor >> 16, (cor >> 8) & 0xff, cor & 0xff });
        } else p.val("(passe o mouse na grade)", .{});
        p.val("32 x 20 = 640 pixels = 2560 bytes", .{});
        const w: usize = app.tela.largura;
        const h: usize = app.tela.altura;
        p.val("esta janela: {d} x {d} = {d} pixels", .{ w, h, w * h });
        p.val("             = {d:.1} MB por quadro", .{@as(f32, @floatFromInt(w * h * 4)) / 1e6});
        p.titulo("Controles");
        p.ctl("botão esquerdo   acende o pixel");
        p.ctl("botão direito    apaga");
        p.val("c  troca a cor (atual: 0x{x:0>6})", .{paleta[f.cor_i] & 0xffffff});
        p.ctl("g  gradiente: R cresce com x, G com y");
        p.ctl("l  limpa tudo");
    }
};

// ===========================================================================
// 2. Rasterização de retas

const Retas = struct {
    const NX = 40;
    const NY = 25;
    const Modo = enum { dda, bresenham, antialiasing };
    const Px = struct { x: i32, y: i32, cob: f32 = 1, erro: i32 = 0, rx: f32 = 0, ry: f32 = 0 };

    a: [2]i32 = .{ 3, 18 },
    b: [2]i32 = .{ 34, 5 },
    modo: Modo = .bresenham,
    anim: bool = false,
    t: f32 = 0,
    pegou: ?usize = null,
    px: [NX * NY]Px = undefined,

    const Geo = struct { x0: i32, y0: i32, s: i32 };
    fn geo(app: *const App) Geo {
        const a = app.area();
        const s = @max(4, @min(@divFloor(a.x1 - a.x0 - 40, NX), @divFloor(a.y1 - a.y0 - 60, NY)));
        return .{ .x0 = a.x0 + @divFloor(a.x1 - a.x0 - s * NX, 2), .y0 = a.y0 + 40, .s = s };
    }
    fn centro(g: Geo, c: [2]i32) [2]f32 {
        return .{ fl(g.x0 + c[0] * g.s) + fl(g.s) / 2, fl(g.y0 + c[1] * g.s) + fl(g.s) / 2 };
    }

    /// DDA: anda `passos` = max(|dx|, |dy|) vezes somando um incremento real
    /// e arredonda. Assim nunca pula um pixel no eixo que mais cresce.
    fn dda(a: [2]i32, b: [2]i32, out: []Px) usize {
        const dx = fl(b[0] - a[0]);
        const dy = fl(b[1] - a[1]);
        const passos: usize = @intFromFloat(@max(@abs(dx), @abs(dy)));
        if (passos == 0) {
            out[0] = .{ .x = a[0], .y = a[1] };
            return 1;
        }
        const ix = dx / @as(f32, @floatFromInt(passos));
        const iy = dy / @as(f32, @floatFromInt(passos));
        var x = fl(a[0]);
        var y = fl(a[1]);
        for (0..passos + 1) |i| {
            out[i] = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)), .rx = x, .ry = y };
            x += ix;
            y += iy;
        }
        return passos + 1;
    }

    /// Bresenham: só soma de inteiros. `erro` acumula o quanto a reta real
    /// se afastou do pixel; quando passa do meio, muda de linha (ou coluna).
    fn bresenham(a: [2]i32, b: [2]i32, out: []Px) usize {
        const dx: i32 = @intCast(@abs(b[0] - a[0]));
        const dy: i32 = -@as(i32, @intCast(@abs(b[1] - a[1])));
        const sx: i32 = if (a[0] < b[0]) 1 else -1;
        const sy: i32 = if (a[1] < b[1]) 1 else -1;
        var erro = dx + dy;
        var x = a[0];
        var y = a[1];
        var n: usize = 0;
        while (true) {
            out[n] = .{ .x = x, .y = y, .erro = erro };
            n += 1;
            if (x == b[0] and y == b[1]) break;
            const e2 = 2 * erro;
            if (e2 >= dy) {
                erro += dy;
                x += sx;
            }
            if (e2 <= dx) {
                erro += dx;
                y += sy;
            }
        }
        return n;
    }

    /// Antialiasing: em vez de "acende ou não", cada pixel recebe uma
    /// fração da cor conforme a distância do centro dele até a reta ideal.
    fn suave(a: [2]i32, b: [2]i32, out: []Px) usize {
        var n: usize = 0;
        var y = @min(a[1], b[1]) - 1;
        while (y <= @max(a[1], b[1]) + 1) : (y += 1) {
            var x = @min(a[0], b[0]) - 1;
            while (x <= @max(a[0], b[0]) + 1) : (x += 1) {
                if (x < 0 or y < 0 or x >= NX or y >= NY) continue;
                const d = tela_.distanciaAoSegmento(fl(x), fl(y), fl(a[0]), fl(a[1]), fl(b[0]), fl(b[1]));
                const cob = std.math.clamp(1.0 - d, 0, 1);
                if (cob < 0.03) continue;
                out[n] = .{ .x = x, .y = y, .cob = cob };
                n += 1;
            }
        }
        return n;
    }

    fn calcular(r: *Retas) usize {
        return switch (r.modo) {
            .dda => dda(r.a, r.b, &r.px),
            .bresenham => bresenham(r.a, r.b, &r.px),
            .antialiasing => suave(r.a, r.b, &r.px),
        };
    }

    fn celula(app: *const App) [2]i32 {
        const g = geo(app);
        return .{ std.math.clamp(@divFloor(app.mx - g.x0, g.s), 0, NX - 1), std.math.clamp(@divFloor(app.my - g.y0, g.s), 0, NY - 1) };
    }
    pub fn apertou(r: *Retas, app: *App, b: Botao) void {
        if (b.numero != 1) return;
        const c = celula(app);
        const da = (c[0] - r.a[0]) * (c[0] - r.a[0]) + (c[1] - r.a[1]) * (c[1] - r.a[1]);
        const db = (c[0] - r.b[0]) * (c[0] - r.b[0]) + (c[1] - r.b[1]) * (c[1] - r.b[1]);
        r.pegou = if (da <= db) 0 else 1;
        r.moveu(app, 0, 0);
    }
    pub fn moveu(r: *Retas, app: *App, _: i32, _: i32) void {
        const i = r.pegou orelse return;
        if (app.botao != 1) return;
        if (i == 0) r.a = celula(app) else r.b = celula(app);
        r.t = 0;
    }
    pub fn soltou(r: *Retas, _: *App, _: Botao) void {
        r.pegou = null;
    }
    pub fn tecla(r: *Retas, _: *App, s: u32) void {
        switch (s) {
            'm' => r.modo = @enumFromInt((@as(u8, @intFromEnum(r.modo)) + 1) % 3),
            'a' => {
                r.anim = !r.anim;
                r.t = 0;
            },
            else => {},
        }
    }

    pub fn pintar(r: *Retas, app: *App, p: *Painel) void {
        const g = geo(app);
        const n = r.calcular();
        const visiveis: usize = if (r.anim) @min(n, @as(usize, @intFromFloat(@mod(r.t * 8, fl(@intCast(n + 10)))))) else n;
        app.textoF(g.x0, g.y0 - 24, cores.cinza, "algoritmo: {s}", .{@tagName(r.modo)});
        for (0..NY) |y| for (0..NX) |x| {
            const x0 = g.x0 + @as(i32, @intCast(x)) * g.s;
            const y0 = g.y0 + @as(i32, @intCast(y)) * g.s;
            app.ret(x0, y0, x0 + g.s, y0 + g.s, cores.grade);
            app.ret(x0 + 1, y0 + 1, x0 + g.s, y0 + g.s, cores.branco);
        };
        for (r.px[0..visiveis]) |q| {
            const x0 = g.x0 + q.x * g.s;
            const y0 = g.y0 + q.y * g.s;
            app.ret(x0 + 1, y0 + 1, x0 + g.s, y0 + g.s, misturaCor(cores.branco, cores.tinta, q.cob));
        }
        const ca = centro(g, r.a);
        const cb = centro(g, r.b);
        app.linha(ca[0], ca[1], cb[0], cb[1], 2, cores.vermelho);
        app.circulo(ca[0], ca[1], 6, cores.laranja);
        app.circulo(cb[0], cb[1], 6, cores.laranja);
        app.texto(paraInt(ca[0]) + 8, paraInt(ca[1]) - 20, "A", cores.laranja);
        app.texto(paraInt(cb[0]) + 8, paraInt(cb[1]) - 20, "B", cores.laranja);

        const dx = r.b[0] - r.a[0];
        const dy = r.b[1] - r.a[1];
        p.titulo("O que é");
        p.txt("Rasterizar é decidir quais pixels acender para representar uma forma contínua. A reta vermelha é a ideal; os quadrados escuros são o que a tela consegue mostrar.");
        switch (r.modo) {
            .dda => p.txt("DDA: dá max(|dx|,|dy|) passos, somando um incremento real em x e y e arredondando. Simples, mas usa ponto flutuante e arredondamento a cada pixel."),
            .bresenham => p.txt("Bresenham: só soma e compara inteiros. A variável erro guarda o quanto a reta ideal se afastou do pixel atual; quando passa do meio, o algoritmo muda de linha."),
            .antialiasing => p.txt("Antialiasing: cada pixel recebe uma fração da cor proporcional à cobertura (aqui, 1 - distância do centro do pixel à reta). Some o efeito de escada (serrilhado)."),
        }
        p.titulo("Ao vivo");
        p.val("A = ({d}, {d})   B = ({d}, {d})", .{ r.a[0], r.a[1], r.b[0], r.b[1] });
        p.val("dx = {d}   dy = {d}   pixels = {d}", .{ dx, dy, n });
        if (dx != 0) p.val("inclinação m = dy/dx = {d:.3}", .{fl(dy) / fl(dx)}) else p.val("reta vertical (dx = 0)", .{});
        switch (r.modo) {
            .dda => {
                p.val(" i   x real  y real  ->  pixel", .{});
                for (r.px[0..@min(n, 12)], 0..) |q, i| p.val("{d:>2}  {d:>6.2}  {d:>6.2}  ->  ({d}, {d})", .{ i, q.rx, q.ry, @as(u32, @intCast(q.x)), @as(u32, @intCast(q.y)) });
            },
            .bresenham => {
                p.val(" i   pixel      erro", .{});
                for (r.px[0..@min(n, 12)], 0..) |q, i| p.val("{d:>2}  ({d:>2}, {d:>2})   {d}", .{ i, @as(u32, @intCast(q.x)), @as(u32, @intCast(q.y)), q.erro });
            },
            .antialiasing => p.val("pixels parciais: {d}", .{n}),
        }
        if (n > 12 and r.modo != .antialiasing) p.val(" ...", .{});
        p.titulo("Controles");
        p.ctl("arraste perto de A ou B   move a ponta");
        p.ctl("m  troca: DDA / Bresenham / antialiasing");
        p.ctl("a  anima o desenho pixel a pixel");
    }
};

// ===========================================================================
// 3. Transformações 2D

const Transformacoes = struct {
    /// Um "F": não tem simetria, então dá pra ver giro e espelhamento.
    const forma = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 2 }, .{ 2, 2 }, .{ 2, 3 }, .{ 1, 3 }, .{ 1, 4 }, .{ 3, 4 }, .{ 3, 5 }, .{ 0, 5 } };
    const unidade: f32 = 30;

    tx: f32 = 3,
    ty: f32 = 1,
    ang: f32 = 30,
    sx: f32 = 1,
    sy: f32 = 1,
    /// false: M = T·R·S ; true: M = R·T·S
    trocada: bool = false,
    pivo: bool = false,
    anim: bool = false,
    arrastando: bool = false,

    fn vista(app: *const App) Mat3 {
        const a = app.area();
        const ox = fl(a.x0) + fl(a.x1 - a.x0) * 0.42;
        const oy = fl(a.y0) + fl(a.y1 - a.y0) * 0.62;
        return Mat3.translacao(ox, oy).vezes(Mat3.escala(unidade, -unidade));
    }
    fn partes(t: *const Transformacoes) [3]Mat3 {
        const rad = t.ang * std.math.pi / 180;
        var r = Mat3.rotacao(rad);
        if (t.pivo and !t.trocada) r = r.emTornoDe(1.5, 2.5);
        return .{ Mat3.translacao(t.tx, t.ty), r, Mat3.escala(t.sx, t.sy) };
    }
    fn matriz(t: *const Transformacoes, trocada: bool) Mat3 {
        const pt = t.partes();
        return if (!trocada) pt[0].vezes(pt[1]).vezes(pt[2]) else pt[1].vezes(pt[0]).vezes(pt[2]);
    }

    pub fn apertou(t: *Transformacoes, _: *App, b: Botao) void {
        if (b.numero == 1) t.arrastando = true;
        if (b.numero == 4) t.sx *= 1.1;
        if (b.numero == 4) t.sy *= 1.1;
        if (b.numero == 5) t.sx /= 1.1;
        if (b.numero == 5) t.sy /= 1.1;
    }
    pub fn soltou(t: *Transformacoes, _: *App, _: Botao) void {
        t.arrastando = false;
    }
    pub fn moveu(t: *Transformacoes, _: *App, dx: i32, dy: i32) void {
        if (!t.arrastando) return;
        t.tx += fl(dx) / unidade;
        t.ty -= fl(dy) / unidade;
    }
    pub fn tecla(t: *Transformacoes, _: *App, s: u32) void {
        switch (s) {
            'q' => t.ang += 15,
            'e' => t.ang -= 15,
            '=', '+' => {
                t.sx *= 1.25;
                t.sy *= 1.25;
            },
            '-' => {
                t.sx /= 1.25;
                t.sy /= 1.25;
            },
            'x' => t.sx = -t.sx,
            'y' => t.sy = -t.sy,
            'h' => t.sx *= 1.25,
            'o' => t.trocada = !t.trocada,
            'c' => t.pivo = !t.pivo,
            'a' => t.anim = !t.anim,
            '0' => t.* = .{},
            0xff51 => t.tx -= 1,
            0xff53 => t.tx += 1,
            0xff52 => t.ty += 1,
            0xff54 => t.ty -= 1,
            else => {},
        }
        t.ang = @mod(t.ang, 360);
    }

    fn contornar(app: *App, m: Mat3, esp: f32, cor: Cor, tracejado: bool) void {
        for (0..forma.len) |i| {
            const a = m.aplicar(forma[i][0], forma[i][1]);
            const b = m.aplicar(forma[(i + 1) % forma.len][0], forma[(i + 1) % forma.len][1]);
            if (tracejado) app.tracejada(a.x, a.y, b.x, b.y, cor) else app.linha(a.x, a.y, b.x, b.y, esp, cor);
        }
    }

    /// Pinta o interior por mapeamento inverso: cada pixel volta pro espaço
    /// do objeto pela inversa da matriz e testa se está dentro do polígono.
    fn preencher(app: *App, m: Mat3, cor: Cor) void {
        const inv = m.inversa() orelse return;
        var c: Caixa = .{ .x0 = std.math.maxInt(i32), .y0 = std.math.maxInt(i32), .x1 = std.math.minInt(i32), .y1 = std.math.minInt(i32) };
        for (forma) |q| {
            const s = m.aplicar(q[0], q[1]);
            c = .{ .x0 = @min(c.x0, paraInt(s.x)), .y0 = @min(c.y0, paraInt(s.y)), .x1 = @max(c.x1, paraInt(s.x) + 1), .y1 = @max(c.y1, paraInt(s.y) + 1) };
        }
        const a = app.area();
        var y = @max(c.y0, a.y0);
        while (y < @min(c.y1, a.y1)) : (y += 1) {
            var x = @max(c.x0, a.x0);
            while (x < @min(c.x1, a.x1)) : (x += 1) {
                const q = inv.aplicar(fl(x) + 0.5, fl(y) + 0.5);
                if (dentro(q.x, q.y)) app.tela.misturar(x, y, cor, 0.3);
            }
        }
    }
    fn dentro(x: f32, y: f32) bool {
        var d = false;
        var j = forma.len - 1;
        for (0..forma.len) |i| {
            const a = forma[i];
            const b = forma[j];
            if ((a[1] > y) != (b[1] > y) and x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) d = !d;
            j = i;
        }
        return d;
    }

    pub fn pintar(t: *Transformacoes, app: *App, p: *Painel) void {
        const a = app.area();
        const v = vista(app);
        // Grade e eixos do mundo.
        var k: i32 = -30;
        while (k <= 30) : (k += 1) {
            const h0 = v.aplicar(fl(k), -30);
            const h1 = v.aplicar(fl(k), 30);
            const g0 = v.aplicar(-30, fl(k));
            const g1 = v.aplicar(30, fl(k));
            const cor = if (k == 0) cores.cinza else cores.grade;
            app.tela.linha(paraInt(h0.x), paraInt(h0.y), paraInt(h1.x), paraInt(h1.y), 0, cor);
            app.tela.linha(paraInt(g0.x), paraInt(g0.y), paraInt(g1.x), paraInt(g1.y), 0, cor);
        }
        const o = v.aplicar(0, 0);
        app.texto(paraInt(o.x) + 4, paraInt(o.y) + 4, "(0,0)", cores.cinza);

        const m = t.matriz(t.trocada);
        const outra = t.matriz(!t.trocada);
        contornar(app, v, 1, cores.cinza, true); // original
        contornar(app, v.vezes(outra), 1, cores.laranja, true);
        preencher(app, v.vezes(m), cores.roxo);
        contornar(app, v.vezes(m), 2.5, cores.roxo, false);
        const p0 = v.vezes(m).aplicar(3, 5);
        app.circulo(p0.x, p0.y, 5, cores.vermelho);
        app.texto(paraInt(p0.x) + 8, paraInt(p0.y) - 8, "P'", cores.vermelho);
        const po = v.aplicar(3, 5);
        app.circulo(po.x, po.y, 3, cores.cinza);
        app.texto(paraInt(po.x) + 6, paraInt(po.y) - 8, "P", cores.cinza);
        app.texto(a.x0 + 16, a.y1 - 60, "--- original (cinza)", cores.cinza);
        app.textoF(a.x0 + 16, a.y1 - 40, cores.laranja, "--- mesma T, R, S na ordem {s}", .{if (t.trocada) "T·R·S" else "R·T·S"});
        app.textoF(a.x0 + 16, a.y1 - 20, cores.roxo, "___ resultado: M = {s}", .{if (t.trocada) "R·T·S" else "T·R·S"});

        const pt = t.partes();
        const pr = m.aplicar(3, 5);
        p.titulo("O que é");
        p.txt("Com coordenadas homogêneas, o ponto (x, y) vira (x, y, 1) e translação, rotação e escala viram todas matrizes 3x3. Juntar transformações é multiplicar matrizes.");
        p.txt("A ordem importa: em M = T·R·S o ponto é escalado, depois girado em torno da origem, depois transladado. Trocar a ordem (o contorno laranja) dá outro resultado.");
        p.titulo("Ao vivo");
        p.mat3("S =", pt[2]);
        p.mat3(if (t.pivo and !t.trocada) "R'=" else "R =", pt[1]);
        p.mat3("T =", pt[0]);
        p.mat3("M =", m);
        p.val("P = (3, 5, 1)  ->  P' = M·P = ({d:.2}, {d:.2}, 1)", .{ pr.x, pr.y });
        p.val("ângulo {d:.0} graus, escala ({d:.2}, {d:.2})", .{ t.ang, t.sx, t.sy });
        if (t.pivo and !t.trocada) p.val("R' = T(c)·R·T(-c), c = (1.5, 2.5)", .{});
        p.titulo("Controles");
        p.ctl("arrastar / setas  translada (T)");
        p.ctl("q / e      gira 15 graus (R)");
        p.ctl("- / = ou rodinha  escala (S)");
        p.ctl("x / y      espelha (escala -1)");
        p.ctl("o  troca a ordem   c  gira no centro");
        p.ctl("a  anima a rotação   0  volta ao início");
    }
};

// ===========================================================================
// 5. Recorte (Cohen-Sutherland); usado também na aula 4

pub const Retangulo = struct { xmin: f32, ymin: f32, xmax: f32, ymax: f32 };

const ESQ: u4 = 1;
const DIR: u4 = 2;
const BAIXO: u4 = 4;
const CIMA: u4 = 8;

/// Código de região de 4 bits: cima, baixo, direita, esquerda (na tela o y
/// cresce pra baixo, então "cima" é y < ymin).
pub fn codigo(r: Retangulo, x: f32, y: f32) u4 {
    var c: u4 = 0;
    if (x < r.xmin) c |= ESQ;
    if (x > r.xmax) c |= DIR;
    if (y > r.ymax) c |= BAIXO;
    if (y < r.ymin) c |= CIMA;
    return c;
}

fn bits(c: u4) [4]u8 {
    var s: [4]u8 = undefined;
    for (0..4) |i| s[i] = if ((c >> @intCast(3 - i)) & 1 == 1) '1' else '0';
    return s;
}

const Passos = struct {
    buf: [8][64]u8 = undefined,
    tam: [8]usize = @splat(0),
    n: usize = 0,
    fn add(ps: *Passos, comptime fmt: []const u8, args: anytype) void {
        if (ps.n >= 8) return;
        const s = std.fmt.bufPrint(&ps.buf[ps.n], fmt, args) catch return;
        ps.tam[ps.n] = s.len;
        ps.n += 1;
    }
};

/// Cohen-Sutherland: se os dois códigos são 0, a reta está toda dentro; se
/// o E lógico deles não é 0, os dois estão do mesmo lado de fora e a reta
/// toda some. Senão, corta a ponta de fora na borda e repete.
pub fn cohenSutherland(r: Retangulo, a0: [2]f32, b0: [2]f32, passos: ?*Passos) ?[2][2]f32 {
    var a = a0;
    var b = b0;
    var ca = codigo(r, a[0], a[1]);
    var cb = codigo(r, b[0], b[1]);
    var volta: usize = 0;
    while (volta < 8) : (volta += 1) {
        if (ca | cb == 0) {
            if (passos) |ps| ps.add("{s} | {s} = 0000: aceita", .{ bits(ca), bits(cb) });
            return .{ a, b };
        }
        if (ca & cb != 0) {
            if (passos) |ps| ps.add("{s} & {s} != 0: rejeita", .{ bits(ca), bits(cb) });
            return null;
        }
        const fora = if (ca != 0) ca else cb;
        const p = if (ca != 0) a else b;
        const q = if (ca != 0) b else a;
        var n: [2]f32 = undefined;
        var borda: []const u8 = undefined;
        if (fora & CIMA != 0) {
            n = .{ p[0] + (q[0] - p[0]) * (r.ymin - p[1]) / (q[1] - p[1]), r.ymin };
            borda = "cima";
        } else if (fora & BAIXO != 0) {
            n = .{ p[0] + (q[0] - p[0]) * (r.ymax - p[1]) / (q[1] - p[1]), r.ymax };
            borda = "baixo";
        } else if (fora & DIR != 0) {
            n = .{ r.xmax, p[1] + (q[1] - p[1]) * (r.xmax - p[0]) / (q[0] - p[0]) };
            borda = "direita";
        } else {
            n = .{ r.xmin, p[1] + (q[1] - p[1]) * (r.xmin - p[0]) / (q[0] - p[0]) };
            borda = "esquerda";
        }
        if (passos) |ps| ps.add("{s} {s}: corta {s} na borda {s}", .{ bits(ca), bits(cb), if (ca != 0) "A" else "B", borda });
        if (ca != 0) {
            a = n;
            ca = codigo(r, a[0], a[1]);
        } else {
            b = n;
            cb = codigo(r, b[0], b[1]);
        }
    }
    return null;
}

const RecorteAula = struct {
    seg: [48][2][2]f32 = undefined,
    n: usize = 0,
    jan: ?Retangulo = null,
    novo: ?[2]f32 = null,
    rand: Rand = .{},
    codigos: bool = true,

    fn iniciar(rc: *RecorteAula, app: *const App) void {
        const a = app.area();
        const w = fl(a.x1 - a.x0);
        const h = fl(a.y1 - a.y0);
        if (rc.jan == null) rc.jan = .{ .xmin = fl(a.x0) + w * 0.3, .ymin = h * 0.32, .xmax = fl(a.x0) + w * 0.7, .ymax = h * 0.62 };
    }
    fn sortear(rc: *RecorteAula, app: *const App) void {
        const a = app.area();
        rc.n = 7;
        for (0..rc.n) |i| {
            for (0..2) |k| rc.seg[i][k] = .{ fl(a.x0) + 20 + rc.rand.f() * fl(a.x1 - a.x0 - 40), 40 + rc.rand.f() * fl(a.y1 - a.y0 - 120) };
        }
    }

    pub fn apertou(rc: *RecorteAula, app: *App, b: Botao) void {
        rc.iniciar(app);
        const j = &rc.jan.?;
        switch (b.numero) {
            1 => rc.novo = .{ fl(b.x), fl(b.y) },
            4, 5 => {
                const k: f32 = if (b.numero == 4) 1.1 else 1.0 / 1.1;
                const cx = (j.xmin + j.xmax) / 2;
                const cy = (j.ymin + j.ymax) / 2;
                j.* = .{ .xmin = cx - (cx - j.xmin) * k, .xmax = cx + (j.xmax - cx) * k, .ymin = cy - (cy - j.ymin) * k, .ymax = cy + (j.ymax - cy) * k };
            },
            else => {},
        }
    }
    pub fn moveu(rc: *RecorteAula, app: *App, dx: i32, dy: i32) void {
        if (app.botao == 3 or app.botao == 2) if (rc.jan) |*j| {
            j.xmin += fl(dx);
            j.xmax += fl(dx);
            j.ymin += fl(dy);
            j.ymax += fl(dy);
        };
    }
    pub fn soltou(rc: *RecorteAula, app: *App, b: Botao) void {
        if (b.numero != 1) return;
        const ini = rc.novo orelse return;
        rc.novo = null;
        const fim = [2]f32{ fl(app.mx), fl(app.my) };
        if (@abs(fim[0] - ini[0]) + @abs(fim[1] - ini[1]) < 6) return;
        if (rc.n == rc.seg.len) {
            std.mem.copyForwards([2][2]f32, rc.seg[0 .. rc.n - 1], rc.seg[1..rc.n]);
            rc.n -= 1;
        }
        rc.seg[rc.n] = .{ ini, fim };
        rc.n += 1;
    }
    pub fn tecla(rc: *RecorteAula, app: *App, s: u32) void {
        switch (s) {
            ' ' => rc.sortear(app),
            'l' => rc.n = 0,
            'r' => rc.codigos = !rc.codigos,
            else => {},
        }
    }

    pub fn pintar(rc: *RecorteAula, app: *App, p: *Painel) void {
        rc.iniciar(app);
        if (rc.n == 0 and rc.rand.s == 12345) rc.sortear(app);
        const a = app.area();
        const j = rc.jan.?;
        // As 9 regiões: as bordas da janela prolongadas.
        app.tracejada(fl(a.x0), j.ymin, fl(a.x1), j.ymin, cores.grade);
        app.tracejada(fl(a.x0), j.ymax, fl(a.x1), j.ymax, cores.grade);
        app.tracejada(j.xmin, fl(a.y0), j.xmin, fl(a.y1), cores.grade);
        app.tracejada(j.xmax, fl(a.y0), j.xmax, fl(a.y1), cores.grade);
        if (rc.codigos) {
            const xs = [3]f32{ (fl(a.x0) + j.xmin) / 2, (j.xmin + j.xmax) / 2, (j.xmax + fl(a.x1)) / 2 };
            const ys = [3]f32{ j.ymin / 2, (j.ymin + j.ymax) / 2, (j.ymax + fl(a.y1)) / 2 };
            for (ys) |y| for (xs) |x| {
                const c = codigo(j, x, y);
                const s = bits(c);
                app.texto(paraInt(x) - 16, paraInt(y) - 8, &s, opaco | 0xc9c5bb);
            };
        }
        app.ret(paraInt(j.xmin), paraInt(j.ymin), paraInt(j.xmax), paraInt(j.ymax), opaco | 0xefecff);
        app.contorno(paraInt(j.xmin) - 1, paraInt(j.ymin) - 1, paraInt(j.xmax) + 1, paraInt(j.ymax) + 1, cores.roxo);
        app.contorno(paraInt(j.xmin), paraInt(j.ymin), paraInt(j.xmax), paraInt(j.ymax), cores.roxo);

        var aceitas: usize = 0;
        var rejeitadas: usize = 0;
        var cortadas: usize = 0;
        var ps: Passos = .{};
        for (rc.seg[0..rc.n], 0..) |s, i| {
            const ultimo = i + 1 == rc.n;
            const res = cohenSutherland(j, s[0], s[1], if (ultimo) &ps else null);
            if (res) |r| {
                const inteira = r[0][0] == s[0][0] and r[0][1] == s[0][1] and r[1][0] == s[1][0] and r[1][1] == s[1][1];
                if (inteira) aceitas += 1 else cortadas += 1;
                if (!inteira) app.tracejada(s[0][0], s[0][1], s[1][0], s[1][1], cores.cinza);
                app.linha(r[0][0], r[0][1], r[1][0], r[1][1], 3, cores.verde);
                if (!inteira) {
                    app.circulo(r[0][0], r[0][1], 3, cores.tinta);
                    app.circulo(r[1][0], r[1][1], 3, cores.tinta);
                }
            } else {
                rejeitadas += 1;
                app.tracejada(s[0][0], s[0][1], s[1][0], s[1][1], cores.vermelho);
            }
            if (rc.codigos) for (s) |q| {
                const c = bits(codigo(j, q[0], q[1]));
                app.circulo(q[0], q[1], 2, if (ultimo) cores.laranja else cores.tinta);
                app.texto(paraInt(q[0]) + 5, paraInt(q[1]) + 2, &c, if (ultimo) cores.laranja else cores.cinza);
            };
        }
        if (rc.novo) |ini| app.linha(ini[0], ini[1], fl(app.mx), fl(app.my), 1.5, cores.laranja);

        p.titulo("O que é");
        p.txt("Recortar é jogar fora o que cai fora da janela de visualização antes de desenhar. Cohen-Sutherland dá a cada ponta um código de 4 bits: cima, baixo, direita, esquerda.");
        p.txt("Códigos 0000 e 0000: a reta está toda dentro (aceita). E lógico dos códigos diferente de 0: as duas pontas estão do mesmo lado de fora (rejeita sem fazer conta). Senão, corta a ponta de fora na borda e repete.");
        p.titulo("Ao vivo");
        p.val("verdes inteiras: {d}  cortadas: {d}", .{ aceitas, cortadas });
        p.val("rejeitadas (vermelhas): {d}", .{rejeitadas});
        p.val("janela: x {d:.0}..{d:.0}  y {d:.0}..{d:.0}", .{ j.xmin, j.xmax, j.ymin, j.ymax });
        if (rc.n > 0) {
            p.val("passos da última reta (laranja):", .{});
            for (0..ps.n) |i| p.val("  {s}", .{ps.buf[i][0..ps.tam[i]]});
        }
        p.titulo("Controles");
        p.ctl("arrastar (esquerdo)  desenha uma reta");
        p.ctl("arrastar (direito)   move a janela");
        p.ctl("rodinha    muda o tamanho da janela");
        p.ctl("espaço  retas novas   l  limpa");
        p.ctl("r  mostra/esconde os códigos");
    }
};

// ===========================================================================
// 4. Janela -> viewport

const JanelaViewport = struct {
    const Seg = struct { a: [2]f32, b: [2]f32, cor: Cor };
    jan: Retangulo = .{ .xmin = 2.5, .ymin = 1, .xmax = 10.5, .ymax = 7 },
    arrastando: bool = false,
    cena: [96]Seg = undefined,
    n: usize = 0,

    fn montar(j: *JanelaViewport) void {
        if (j.n > 0) return;
        const S = struct {
            fn add(jj: *JanelaViewport, ax: f32, ay: f32, bx: f32, by: f32, cor: Cor) void {
                jj.cena[jj.n] = .{ .a = .{ ax, ay }, .b = .{ bx, by }, .cor = cor };
                jj.n += 1;
            }
            fn circ(jj: *JanelaViewport, cx: f32, cy: f32, r: f32, cor: Cor) void {
                for (0..16) |i| {
                    const a0 = fl(@intCast(i)) * std.math.pi / 8;
                    const a1 = fl(@intCast(i + 1)) * std.math.pi / 8;
                    add(jj, cx + r * @cos(a0), cy + r * @sin(a0), cx + r * @cos(a1), cy + r * @sin(a1), cor);
                }
            }
        };
        const casa = cores.vermelho;
        S.add(j, 0, 2, 20, 2, cores.verde);
        S.add(j, 3, 2, 3, 6, casa);
        S.add(j, 7, 2, 7, 6, casa);
        S.add(j, 3, 6, 7, 6, casa);
        S.add(j, 3, 6, 5, 8.5, casa);
        S.add(j, 5, 8.5, 7, 6, casa);
        S.add(j, 4.5, 2, 4.5, 4, cores.laranja);
        S.add(j, 5.5, 2, 5.5, 4, cores.laranja);
        S.add(j, 4.5, 4, 5.5, 4, cores.laranja);
        S.add(j, 11, 2, 11, 4.2, cores.laranja);
        S.add(j, 11.6, 2, 11.6, 4.2, cores.laranja);
        S.circ(j, 11.3, 5.4, 1.4, cores.verde);
        S.circ(j, 16, 11, 1.2, opaco | 0xe8a400);
        for (0..8) |i| {
            const a = fl(@intCast(i)) * std.math.pi / 4;
            S.add(j, 16 + 1.6 * @cos(a), 11 + 1.6 * @sin(a), 16 + 2.3 * @cos(a), 11 + 2.3 * @sin(a), opaco | 0xe8a400);
        }
        S.add(j, 13, 2, 16, 7, cores.azul);
        S.add(j, 16, 7, 19.5, 2, cores.azul);
    }

    /// Mundo (0..20 × 0..14, y pra cima) na metade esquerda.
    fn mundo(app: *const App) Mat3 {
        const a = app.area();
        const w = fl(a.x1 - a.x0) / 2 - 30;
        const k = @min(w / 20, (fl(a.y1 - a.y0) - 120) / 14);
        return Mat3.translacao(fl(a.x0) + 20, 40 + 14 * k).vezes(Mat3.escala(k, -k));
    }
    fn viewport(app: *const App) Retangulo {
        const a = app.area();
        const x0 = fl(a.x0) + fl(a.x1 - a.x0) / 2 + 10;
        const w = fl(a.x1) - x0 - 20;
        return .{ .xmin = x0, .ymin = 60, .xmax = x0 + w, .ymax = 60 + w * 0.75 };
    }
    /// Janela (mundo) -> viewport (tela): leva o canto da janela pra
    /// origem, escala pelo tamanho e põe no canto do viewport. O y inverte
    /// porque no mundo ele cresce pra cima e na tela pra baixo.
    fn matriz(j: *const JanelaViewport, v: Retangulo) Mat3 {
        const sx = (v.xmax - v.xmin) / (j.jan.xmax - j.jan.xmin);
        const sy = (v.ymax - v.ymin) / (j.jan.ymax - j.jan.ymin);
        return Mat3.translacao(v.xmin, v.ymax).vezes(Mat3.escala(sx, -sy)).vezes(Mat3.translacao(-j.jan.xmin, -j.jan.ymin));
    }

    pub fn apertou(j: *JanelaViewport, app: *App, b: Botao) void {
        if (b.numero == 1) j.arrastando = true;
        if (b.numero == 4 or b.numero == 5) {
            const k: f32 = if (b.numero == 5) 1.1 else 1.0 / 1.1;
            const cx = (j.jan.xmin + j.jan.xmax) / 2;
            const cy = (j.jan.ymin + j.jan.ymax) / 2;
            const kx = if (app.shift) 1 else k;
            j.jan = .{ .xmin = cx - (cx - j.jan.xmin) * k, .xmax = cx + (j.jan.xmax - cx) * k, .ymin = cy - (cy - j.jan.ymin) * kx, .ymax = cy + (j.jan.ymax - cy) * kx };
        }
    }
    pub fn soltou(j: *JanelaViewport, _: *App, _: Botao) void {
        j.arrastando = false;
    }
    pub fn moveu(j: *JanelaViewport, app: *App, dx: i32, dy: i32) void {
        if (!j.arrastando) return;
        const k = mundo(app).fator();
        j.jan.xmin += fl(dx) / k;
        j.jan.xmax += fl(dx) / k;
        j.jan.ymin -= fl(dy) / k;
        j.jan.ymax -= fl(dy) / k;
    }
    pub fn tecla(j: *JanelaViewport, _: *App, s: u32) void {
        const w = j.jan.xmax - j.jan.xmin;
        const h = j.jan.ymax - j.jan.ymin;
        switch (s) {
            '[' => j.jan.xmax -= w * 0.1,
            ']' => j.jan.xmax += w * 0.1,
            ',' => j.jan.ymax -= h * 0.1,
            '.' => j.jan.ymax += h * 0.1,
            'p' => j.jan.ymax = j.jan.ymin + w * 0.75,
            '0' => j.jan = (JanelaViewport{}).jan,
            else => {},
        }
    }

    pub fn pintar(j: *JanelaViewport, app: *App, p: *Painel) void {
        j.montar();
        const m = mundo(app);
        const v = viewport(app);
        const mv = j.matriz(v);
        // Mundo.
        const c0 = m.aplicar(0, 0);
        const c1 = m.aplicar(20, 14);
        app.ret(paraInt(c0.x), paraInt(c1.y), paraInt(c1.x), paraInt(c0.y), cores.branco);
        var k: f32 = 0;
        while (k <= 20) : (k += 2) {
            const a = m.aplicar(k, 0);
            const b = m.aplicar(k, 14);
            app.tracejada(a.x, a.y, b.x, b.y, cores.grade);
            if (k <= 14) {
                const e = m.aplicar(0, k);
                const d = m.aplicar(20, k);
                app.tracejada(e.x, e.y, d.x, d.y, cores.grade);
            }
        }
        for (j.cena[0..j.n]) |s| {
            const a = m.aplicar(s.a[0], s.a[1]);
            const b = m.aplicar(s.b[0], s.b[1]);
            app.linha(a.x, a.y, b.x, b.y, 2, s.cor);
        }
        const w0 = m.aplicar(j.jan.xmin, j.jan.ymin);
        const w1 = m.aplicar(j.jan.xmax, j.jan.ymax);
        app.contorno(paraInt(w0.x), paraInt(w1.y), paraInt(w1.x), paraInt(w0.y), cores.roxo);
        app.contorno(paraInt(w0.x) - 1, paraInt(w1.y) - 1, paraInt(w1.x) + 1, paraInt(w0.y) + 1, cores.roxo);
        app.texto(paraInt(c0.x), 14, "MUNDO (coordenadas do objeto)", cores.cinza);
        app.textoF(paraInt(w0.x), paraInt(w0.y) + 4, cores.roxo, "({d:.1}, {d:.1})", .{ j.jan.xmin, j.jan.ymin });
        app.textoF(paraInt(w1.x) - 90, paraInt(w1.y) - 18, cores.roxo, "({d:.1}, {d:.1})", .{ j.jan.xmax, j.jan.ymax });
        // Viewport.
        app.ret(paraInt(v.xmin), paraInt(v.ymin), paraInt(v.xmax), paraInt(v.ymax), cores.branco);
        for (j.cena[0..j.n]) |s| {
            const a = mv.aplicar(s.a[0], s.a[1]);
            const b = mv.aplicar(s.b[0], s.b[1]);
            if (cohenSutherland(v, .{ a.x, a.y }, .{ b.x, b.y }, null)) |r| app.linha(r[0][0], r[0][1], r[1][0], r[1][1], 2, s.cor);
        }
        app.contorno(paraInt(v.xmin), paraInt(v.ymin), paraInt(v.xmax), paraInt(v.ymax), cores.tinta);
        app.texto(paraInt(v.xmin), 14, "VIEWPORT (pixels da tela)", cores.cinza);
        app.textoF(paraInt(v.xmin), paraInt(v.ymax) + 6, cores.tinta, "({d:.0}, {d:.0})", .{ v.xmin, v.ymax });
        app.textoF(paraInt(v.xmax) - 100, paraInt(v.ymin) - 20, cores.tinta, "({d:.0}, {d:.0})", .{ v.xmax, v.ymin });

        // Mouse no mundo: mostra onde cai no viewport.
        const inv = m.inversa().?;
        const q = inv.aplicar(fl(app.mx), fl(app.my));
        const dentro_mundo = q.x >= 0 and q.x <= 20 and q.y >= 0 and q.y <= 14 and app.mx < paraInt(v.xmin) - 10;
        const sx = (v.xmax - v.xmin) / (j.jan.xmax - j.jan.xmin);
        const sy = (v.ymax - v.ymin) / (j.jan.ymax - j.jan.ymin);

        p.titulo("O que é");
        p.txt("O desenho é descrito em coordenadas do mundo (metros, unidades quaisquer). A janela escolhe o pedaço do mundo que vai aparecer; o viewport é o retângulo da tela, em pixels, onde ele aparece.");
        p.txt("A transformação janela-viewport é uma translação, uma escala e outra translação. O que sai da janela é recortado (Cohen-Sutherland, aula 5).");
        p.titulo("Ao vivo");
        p.val("sx = ({d:.0}-{d:.0}) / ({d:.1}-{d:.1}) = {d:.2}", .{ v.xmax, v.xmin, j.jan.xmax, j.jan.xmin, sx });
        p.val("sy = ({d:.0}-{d:.0}) / ({d:.1}-{d:.1}) = {d:.2}", .{ v.ymax, v.ymin, j.jan.ymax, j.jan.ymin, sy });
        p.val("M = T(vxmin, vymax)·S(sx, -sy)·T(-xmin, -ymin)", .{});
        p.mat3("M =", mv);
        if (@abs(sx - sy) > 0.01 * sx) p.add(.mono, cores.vermelho, "sx != sy: a imagem fica esticada!", .{}) else p.val("sx = sy: proporção mantida", .{});
        if (dentro_mundo) {
            const r = mv.aplicar(q.x, q.y);
            p.val("mouse no mundo ({d:.2}, {d:.2})", .{ q.x, q.y });
            p.val("     -> viewport ({d:.0}, {d:.0}) px", .{ r.x, r.y });
            const pm = m.aplicar(q.x, q.y);
            app.circulo(pm.x, pm.y, 4, cores.laranja);
            if (r.x >= v.xmin and r.x <= v.xmax and r.y >= v.ymin and r.y <= v.ymax) app.circulo(r.x, r.y, 5, cores.laranja);
        }
        p.titulo("Controles");
        p.ctl("arrastar no mundo   move a janela");
        p.ctl("rodinha             zoom (tamanho)");
        p.ctl("[ ]  largura    , .  altura");
        p.ctl("p  corrige a proporção   0  volta");
    }
};

// ===========================================================================
// 6. Projeção 3D

const Projecao = struct {
    yaw: f32 = 0.6,
    pitch: f32 = 0.45,
    dist: f32 = 4.5,
    fov: f32 = 60,
    perspectiva: bool = true,
    auto: bool = false,

    fn matrizes(pj: *const Projecao) [3]Mat4 {
        const modelo = Mat4.rotX(pj.pitch).vezes(Mat4.rotY(pj.yaw));
        const vista = Mat4.translacao(0, 0, -pj.dist);
        const f = pj.fov * std.math.pi / 180;
        const proj = if (pj.perspectiva) Mat4.perspectiva(f, 0.1, 100) else Mat4.ortografica(1 / (pj.dist * @tan(f / 2)), 0.1, 100);
        return .{ modelo, vista, proj };
    }

    pub fn moveu(pj: *Projecao, app: *App, dx: i32, dy: i32) void {
        if (app.botao != 1) return;
        pj.yaw += fl(dx) * 0.01;
        pj.pitch += fl(dy) * 0.01;
    }
    pub fn apertou(pj: *Projecao, _: *App, b: Botao) void {
        if (b.numero == 4) pj.dist = @max(2, pj.dist - 0.25);
        if (b.numero == 5) pj.dist = @min(20, pj.dist + 0.25);
    }
    pub fn tecla(pj: *Projecao, _: *App, s: u32) void {
        switch (s) {
            'p' => pj.perspectiva = !pj.perspectiva,
            '-' => pj.dist = @min(20, pj.dist + 0.25),
            '=', '+' => pj.dist = @max(2, pj.dist - 0.25),
            '[' => pj.fov = @max(15, pj.fov - 5),
            ']' => pj.fov = @min(150, pj.fov + 5),
            'a' => pj.auto = !pj.auto,
            '0' => pj.* = .{},
            else => {},
        }
    }

    pub fn pintar(pj: *Projecao, app: *App, p: *Painel) void {
        const a = app.area();
        const ms = pj.matrizes();
        const mvp = ms[2].vezes(ms[1]).vezes(ms[0]);
        const cx = fl(a.x0 + a.x1) / 2;
        const cy = fl(a.y0 + a.y1) / 2 - 40;
        const meio = @min(fl(a.x1 - a.x0), fl(a.y1 - a.y0)) * 0.42;
        const S = struct {
            fn tela(m: Mat4, q: Vec3, ccx: f32, ccy: f32, mm: f32) ?[2]f32 {
                const c = m.aplicar4(q);
                if (c[3] <= 0.05) return null;
                return .{ ccx + c[0] / c[3] * mm, ccy - c[1] / c[3] * mm };
            }
        };
        // Moldura do plano de projeção (NDC de -1 a 1).
        app.contorno(paraInt(cx - meio), paraInt(cy - meio), paraInt(cx + meio), paraInt(cy + meio), cores.grade);
        // Arestas do cubo.
        var cantos: [8]Vec3 = undefined;
        for (0..8) |i| cantos[i] = Vec3.v(if (i & 1 != 0) 1 else -1, if (i & 2 != 0) 1 else -1, if (i & 4 != 0) 1 else -1);
        for (0..8) |i| for (0..3) |eixo| {
            const jx = i | (@as(usize, 1) << @intCast(eixo));
            if (jx == i) continue;
            const pa = S.tela(mvp, cantos[i], cx, cy, meio) orelse continue;
            const pb = S.tela(mvp, cantos[jx], cx, cy, meio) orelse continue;
            app.linha(pa[0], pa[1], pb[0], pb[1], 2.5, cores.tinta);
        };
        const eixos = [_]struct { v: Vec3, c: Cor, n: []const u8 }{ .{ .v = Vec3.v(1.7, 0, 0), .c = cores.vermelho, .n = "x" }, .{ .v = Vec3.v(0, 1.7, 0), .c = cores.verde, .n = "y" }, .{ .v = Vec3.v(0, 0, 1.7), .c = cores.azul, .n = "z" } };
        const o = S.tela(mvp, Vec3.v(0, 0, 0), cx, cy, meio).?;
        for (eixos) |e| if (S.tela(mvp, e.v, cx, cy, meio)) |q| {
            app.seta(o[0], o[1], q[0], q[1], 2, e.c);
            app.texto(paraInt(q[0]) + 4, paraInt(q[1]) - 8, e.n, e.c);
        };
        const vtx = Vec3.v(1, 1, 1);
        if (S.tela(mvp, vtx, cx, cy, meio)) |q| {
            app.circulo(q[0], q[1], 6, cores.laranja);
            app.texto(paraInt(q[0]) + 8, paraInt(q[1]) - 8, "V", cores.laranja);
        }

        // Vista de cima: câmera, campo de visão e o cubo no plano x-z da câmera.
        const iw: f32 = 260;
        const ih: f32 = 190;
        const ix = fl(a.x0) + 14;
        const iy = fl(a.y1) - ih - 14;
        app.ret(paraInt(ix), paraInt(iy), paraInt(ix + iw), paraInt(iy + ih), cores.branco);
        app.contorno(paraInt(ix), paraInt(iy), paraInt(ix + iw), paraInt(iy + ih), cores.cinza);
        app.texto(paraInt(ix) + 6, paraInt(iy) + 4, "vista de cima (x, z da câmera)", cores.cinza);
        const k = (ih - 40) / (pj.dist + 2);
        const camx = ix + iw / 2;
        const camy = iy + ih - 12;
        const f = pj.fov * std.math.pi / 180;
        if (pj.perspectiva) {
            const tg = @tan(f / 2);
            const d = pj.dist + 2;
            app.tracejada(camx, camy, camx - tg * d * k, camy - d * k, cores.laranja);
            app.tracejada(camx, camy, camx + tg * d * k, camy - d * k, cores.laranja);
        } else {
            const half = pj.dist * @tan(f / 2) * k;
            app.tracejada(camx - half, camy, camx - half, iy + 20, cores.laranja);
            app.tracejada(camx + half, camy, camx + half, iy + 20, cores.laranja);
        }
        const mv = ms[1].vezes(ms[0]);
        for (0..8) |i| for (0..3) |eixo| {
            const jx = i | (@as(usize, 1) << @intCast(eixo));
            if (jx == i) continue;
            const pa = mv.ponto(cantos[i]);
            const pb = mv.ponto(cantos[jx]);
            app.linha(camx + pa.x * k, camy + pa.z * k, camx + pb.x * k, camy + pb.z * k, 1.5, cores.tinta);
        };
        app.circulo(camx, camy, 5, cores.roxo);
        app.texto(paraInt(camx) + 8, paraInt(camy) - 10, "olho", cores.roxo);

        const mundo = ms[0].aplicar4(vtx);
        const cam = mv.aplicar4(vtx);
        const clip = mvp.aplicar4(vtx);
        p.titulo("O que é");
        p.txt("Para mostrar um objeto 3D numa tela 2D, cada vértice passa por matrizes 4x4: modelo (gira o objeto), câmera (põe o olho na origem olhando para -z) e projeção.");
        if (pj.perspectiva) p.txt("Na perspectiva, a projeção copia -z para w. Depois de dividir x e y por w, o que está longe encolhe: as arestas paralelas convergem.") else p.txt("Na ortográfica, w fica 1: nada encolhe com a distância e as arestas paralelas continuam paralelas (desenho técnico).");
        p.titulo("Ao vivo: o vértice V = (1, 1, 1)");
        p.val("mundo   ({d:>5.2}, {d:>5.2}, {d:>5.2})", .{ mundo[0], mundo[1], mundo[2] });
        p.val("câmera  ({d:>5.2}, {d:>5.2}, {d:>5.2})", .{ cam[0], cam[1], cam[2] });
        p.val("clip    ({d:>5.2}, {d:>5.2}, {d:>5.2}, w={d:.2})", .{ clip[0], clip[1], clip[2], clip[3] });
        p.val("/w      ({d:>5.2}, {d:>5.2})  (NDC, -1 a 1)", .{ clip[0] / clip[3], clip[1] / clip[3] });
        p.val("tela    ({d:.0}, {d:.0}) px", .{ cx + clip[0] / clip[3] * meio, cy - clip[1] / clip[3] * meio });
        p.mat4(if (pj.perspectiva) "P =" else "O =", ms[2]);
        p.val("distância {d:.2}   fov {d:.0} graus", .{ pj.dist, pj.fov });
        p.titulo("Controles");
        p.ctl("arrastar   gira o cubo");
        p.ctl("p  perspectiva / ortográfica");
        p.ctl("- / = ou rodinha  distância da câmera");
        p.ctl("[ ]  ângulo de visão (fov)");
        p.ctl("a  gira sozinho   0  volta ao início");
    }
};

// ===========================================================================
// 7 e 8: cena 3D com triângulos

const Camera = struct {
    mvp: Mat4,
    cx: f32,
    cy: f32,
    meio: f32,
    fn naTela(c: Camera, q: Vec3) ?td.VTela {
        const r = c.mvp.aplicar4(q);
        if (r[3] <= 0.05) return null;
        return .{ .x = c.cx + r[0] / r[3] * c.meio, .y = c.cy - r[1] / r[3] * c.meio, .z = r[2] / r[3], .a = Vec3.v(0, 0, 0) };
    }
};

fn camera(app: *const App, vista_proj: Mat4) Camera {
    const a = app.area();
    return .{ .mvp = vista_proj, .cx = fl(a.x0 + a.x1) / 2, .cy = fl(a.y0 + a.y1) / 2, .meio = @min(fl(a.x1 - a.x0), fl(a.y1 - a.y0)) * 0.48 };
}

fn rasterDe(app: *App) td.Raster {
    return .{ .tela = &app.tela, .area = app.area(), .zbuf = app.zbuf };
}

const Liso = struct {
    pub fn cor(_: Liso, a: Vec3, _: i32, _: i32) Cor {
        return td.corDe(a);
    }
};

const Ocultas = struct {
    const Modo = enum { nenhuma, faces_de_tras, pintor, z_buffer };
    const nomes = [_][]const u8{ "sem remoção (ordem da lista)", "descarte de faces de trás", "algoritmo do pintor", "z-buffer" };
    const TriCena = struct { v: [3]td.VTela, cor: Vec3, prof: f32, de_tras: bool };

    modo: Modo = .nenhuma,
    yaw: f32 = 0.5,
    pitch: f32 = 0.35,
    ver_z: bool = false,
    arame: bool = false,
    tris: [36]TriCena = undefined,

    pub fn moveu(o: *Ocultas, app: *App, dx: i32, dy: i32) void {
        if (app.botao != 1) return;
        o.yaw += fl(dx) * 0.01;
        o.pitch += fl(dy) * 0.01;
    }
    pub fn tecla(o: *Ocultas, _: *App, s: u32) void {
        switch (s) {
            'm' => o.modo = @enumFromInt((@as(u8, @intFromEnum(o.modo)) + 1) % 4),
            'z' => o.ver_z = !o.ver_z,
            'w' => o.arame = !o.arame,
            else => {},
        }
    }

    pub fn pintar(o: *Ocultas, app: *App, p: *Painel) void {
        const giro = Mat4.rotX(o.pitch).vezes(Mat4.rotY(o.yaw));
        const vp = Mat4.perspectiva(50.0 * std.math.pi / 180.0, 0.5, 20).vezes(Mat4.translacao(0, 0, -6));
        const cam = camera(app, vp);
        const objetos = [_]struct { m: Mat4, cor: Vec3 }{
            .{ .m = Mat4.translacao(-0.7, 0.1, 0).vezes(Mat4.escala(0.9, 0.9, 0.9)), .cor = Vec3.v(0.88, 0.3, 0.3) },
            .{ .m = Mat4.translacao(0.6, 0.3, 0.2).vezes(Mat4.rotY(0.6)).vezes(Mat4.rotX(0.4)).vezes(Mat4.escala(0.75, 0.75, 0.75)), .cor = Vec3.v(0.25, 0.5, 0.9) },
            .{ .m = Mat4.translacao(0, -0.2, 0).vezes(Mat4.escala(2.2, 0.08, 1.6)), .cor = Vec3.v(0.35, 0.75, 0.4) },
        };
        var pts: [24]Vec3 = undefined;
        var nrm: [24]Vec3 = undefined;
        var tt: [12]td.Tri = undefined;
        const cubo = td.cubo(&pts, &nrm, &tt);
        const luz = Vec3.v(0.4, 0.8, 0.5).normalizado();
        var n: usize = 0;
        for (objetos) |ob| {
            const m = giro.vezes(ob.m);
            for (cubo.tris) |t| {
                var tc: TriCena = undefined;
                var ok = true;
                var prof: f32 = 0;
                for (0..3) |k| {
                    const w = m.ponto(cubo.pontos[t[k]]);
                    tc.v[k] = cam.naTela(w) orelse {
                        ok = false;
                        break;
                    };
                    prof += w.z;
                }
                if (!ok) continue;
                const nm = m.direcao(cubo.normais[t[0]]).normalizado();
                const l = 0.3 + 0.7 * @max(nm.escalar(luz), 0);
                tc.cor = ob.cor.vezes(l);
                tc.prof = prof / 3;
                // Área com sinal na tela (y pra baixo): negativa = anti-horário = de frente.
                const ar = (tc.v[1].x - tc.v[0].x) * (tc.v[2].y - tc.v[0].y) - (tc.v[2].x - tc.v[0].x) * (tc.v[1].y - tc.v[0].y);
                tc.de_tras = ar >= 0;
                o.tris[n] = tc;
                n += 1;
            }
        }
        const lista = o.tris[0..n];
        if (o.modo == .pintor) {
            std.mem.sort(TriCena, lista, {}, struct {
                fn menor(_: void, x: TriCena, y: TriCena) bool {
                    return x.prof < y.prof; // mais longe (z mais negativo) primeiro
                }
            }.menor);
        }
        var r = rasterDe(app);
        r.limparZ();
        r.usar_z = o.modo == .z_buffer;
        var desenhados: usize = 0;
        var descartados: usize = 0;
        for (lista) |*t| {
            if (o.modo != .nenhuma and t.de_tras) {
                descartados += 1;
                continue;
            }
            for (&t.v) |*v| v.a = t.cor;
            r.triangulo(t.v[0], t.v[1], t.v[2], Liso{});
            desenhados += 1;
        }
        // Pixels cobertos: os que receberam profundidade.
        var cobertos: usize = 0;
        var zmin: f32 = std.math.inf(f32);
        var zmax: f32 = -std.math.inf(f32);
        for (r.zbuf) |z| if (z != std.math.inf(f32)) {
            cobertos += 1;
            zmin = @min(zmin, z);
            zmax = @max(zmax, z);
        };
        if (o.ver_z and cobertos > 0) {
            const a = r.area;
            const larg: usize = @intCast(a.x1 - a.x0);
            for (r.zbuf, 0..) |z, i| {
                const x = a.x0 + @as(i32, @intCast(i % larg));
                const y = a.y0 + @as(i32, @intCast(i / larg));
                const g: f32 = if (z == std.math.inf(f32)) 1 else 0.1 + 0.8 * (z - zmin) / @max(zmax - zmin, 1e-6);
                app.tela.ponto(x, y, td.corDe(Vec3.v(g, g, g)));
            }
        }
        if (o.arame) for (lista) |t| {
            if (o.modo != .nenhuma and t.de_tras) continue;
            for (0..3) |k| {
                const a = t.v[k];
                const b = t.v[(k + 1) % 3];
                app.linha(a.x, a.y, b.x, b.y, 1, cores.tinta);
            }
        };
        const a = app.area();
        app.textoF(a.x0 + 16, 16, cores.tinta, "modo: {s}", .{nomes[@intFromEnum(o.modo)]});

        p.titulo("O que é");
        p.txt("Num desenho 3D vários triângulos caem no mesmo pixel; só o mais perto deveria aparecer. Remoção de superfícies ocultas é o que decide isso.");
        switch (o.modo) {
            .nenhuma => p.txt("Sem remoção: os triângulos são pintados na ordem da lista e o último ganha. A placa verde aparece por cima de tudo, até do que está na frente dela."),
            .faces_de_tras => p.txt("Descarte de faces de trás: num objeto fechado, triângulo virado para longe da câmera (horário na tela) nunca aparece. Corta metade do trabalho, mas não resolve um objeto na frente do outro."),
            .pintor => p.txt("Algoritmo do pintor: ordena os triângulos do mais longe para o mais perto e pinta nessa ordem. Falha quando objetos se cruzam (a placa atravessa os cubos): não existe uma ordem certa."),
            .z_buffer => p.txt("Z-buffer: cada pixel guarda a profundidade do que já foi pintado nele; um novo pixel só é pintado se estiver mais perto. Funciona em qualquer ordem e com objetos que se cruzam, ao custo de memória (um número por pixel)."),
        }
        p.titulo("Ao vivo");
        p.val("triângulos: {d}  desenhados: {d}", .{ n, desenhados });
        p.val("descartados (de trás): {d}", .{descartados});
        p.val("pixels pintados: {d}", .{r.escritas});
        p.val("pixels visíveis: {d}", .{cobertos});
        if (cobertos > 0) p.val("sobreposição: {d:.2} pinturas/pixel", .{fl(@intCast(r.escritas)) / fl(@intCast(cobertos))});
        if (o.modo == .z_buffer) p.val("recusados pelo teste de z: {d}", .{r.recusados});
        p.titulo("Controles");
        p.ctl("m  troca o método (4 modos)");
        p.ctl("arrastar   gira a cena");
        p.ctl("z  mostra o z-buffer (claro = longe)");
        p.ctl("w  mostra as arestas dos triângulos");
    }
};

const Iluminacao = struct {
    const Modo = enum { flat, gouraud, phong };
    modo: Modo = .gouraud,
    aneis: usize = 10,
    luz: Vec3 = Vec3.v(-0.5, 0.6, 0.62),
    ka: f32 = 0.12,
    kd: f32 = 0.7,
    ks: f32 = 0.6,
    brilho: f32 = 24,
    yaw: f32 = 0,
    arame: bool = false,
    pontos: [td.max_pontos_esfera]Vec3 = undefined,
    normais: [td.max_pontos_esfera]Vec3 = undefined,
    tris: [td.max_tris_esfera]td.Tri = undefined,
    sonda: Sonda = .{},

    const base = Vec3.v(0.95, 0.5, 0.2);
    const Sonda = struct { ok: bool = false, a: Vec3 = Vec3.v(0, 0, 0) };

    /// Modelo de Phong: ambiente + difusa (Lambert, N·L) + especular (R·V)^n.
    fn phong(il: *const Iluminacao, n0: Vec3) Vec3 {
        const n = n0.normalizado();
        const l = il.luz.normalizado();
        const v = Vec3.v(0, 0, 1);
        const nl = @max(n.escalar(l), 0);
        const r = n.vezes(2 * n.escalar(l)).menos(l);
        const rv = if (nl > 0) std.math.pow(f32, @max(r.escalar(v), 0), il.brilho) else 0;
        return base.vezes(il.ka + il.kd * nl).mais(Vec3.v(1, 1, 1).vezes(il.ks * rv));
    }

    const Sombra = struct {
        il: *Iluminacao,
        mx: i32,
        my: i32,
        pub fn cor(s: Sombra, a: Vec3, x: i32, y: i32) Cor {
            if (x == s.mx and y == s.my) s.il.sonda = .{ .ok = true, .a = a };
            return td.corDe(if (s.il.modo == .phong) s.il.phong(a) else a);
        }
    };

    pub fn moveu(il: *Iluminacao, app: *App, dx: i32, _: i32) void {
        if (app.botao == 1) il.luzDoMouse(app);
        if (app.botao == 3) il.yaw += fl(dx) * 0.01;
    }
    pub fn apertou(il: *Iluminacao, app: *App, b: Botao) void {
        if (b.numero == 1) il.luzDoMouse(app);
    }
    fn luzDoMouse(il: *Iluminacao, app: *App) void {
        const c = camera(app, Mat4.identidade);
        var lx = (fl(app.mx) - c.cx) / (c.meio * 0.8);
        var ly = (c.cy - fl(app.my)) / (c.meio * 0.8);
        const d = lx * lx + ly * ly;
        if (d > 1) {
            lx /= @sqrt(d);
            ly /= @sqrt(d);
        }
        il.luz = Vec3.v(lx, ly, @sqrt(@max(0.0, 1 - lx * lx - ly * ly)) + 0.05);
    }
    pub fn tecla(il: *Iluminacao, _: *App, s: u32) void {
        switch (s) {
            'm' => il.modo = @enumFromInt((@as(u8, @intFromEnum(il.modo)) + 1) % 3),
            'a' => il.ka = @max(0, il.ka - 0.05),
            'A' => il.ka = @min(1, il.ka + 0.05),
            'd' => il.kd = @max(0, il.kd - 0.05),
            'D' => il.kd = @min(1, il.kd + 0.05),
            's' => il.ks = @max(0, il.ks - 0.05),
            'S' => il.ks = @min(1, il.ks + 0.05),
            'n' => il.brilho = @max(1, il.brilho / 1.5),
            'N' => il.brilho = @min(512, il.brilho * 1.5),
            '-' => il.aneis = @max(3, il.aneis - 1),
            '=', '+' => il.aneis = @min(48, il.aneis + 1),
            'w' => il.arame = !il.arame,
            else => {},
        }
    }

    pub fn pintar(il: *Iluminacao, app: *App, p: *Painel) void {
        const malha = td.esfera(il.aneis, il.aneis * 2, &il.pontos, &il.normais, &il.tris);
        const modelo = Mat4.rotY(il.yaw).vezes(Mat4.rotX(0.3));
        const vp = Mat4.perspectiva(40.0 * std.math.pi / 180.0, 0.5, 20).vezes(Mat4.translacao(0, 0, -3.2));
        const cam = camera(app, vp.vezes(modelo));
        var r = rasterDe(app);
        r.limparZ();
        il.sonda = .{};
        const sombra = Sombra{ .il = il, .mx = app.mx, .my = app.my };
        var desenhados: usize = 0;
        for (malha.tris) |t| {
            var v: [3]td.VTela = undefined;
            var ok = true;
            for (0..3) |k| v[k] = cam.naTela(malha.pontos[t[k]]) orelse {
                ok = false;
                break;
            };
            if (!ok) continue;
            const ar = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[2].x - v[0].x) * (v[1].y - v[0].y);
            if (ar >= 0) continue;
            var nw: [3]Vec3 = undefined;
            for (0..3) |k| nw[k] = modelo.direcao(malha.normais[t[k]]);
            switch (il.modo) {
                .flat => {
                    const p0 = modelo.ponto(malha.pontos[t[0]]);
                    const nf = modelo.ponto(malha.pontos[t[1]]).menos(p0).vetorial(modelo.ponto(malha.pontos[t[2]]).menos(p0));
                    const c = il.phong(nf);
                    for (&v) |*q| q.a = c;
                },
                .gouraud => for (0..3) |k| {
                    v[k].a = il.phong(nw[k]);
                },
                .phong => for (0..3) |k| {
                    v[k].a = nw[k];
                },
            }
            r.triangulo(v[0], v[1], v[2], sombra);
            desenhados += 1;
            if (il.arame) for (0..3) |k| app.linha(v[k].x, v[k].y, v[(k + 1) % 3].x, v[(k + 1) % 3].y, 1, opaco | 0x553322);
        }
        // A luz: um sol na direção dela.
        const c = camera(app, Mat4.identidade);
        const l = il.luz.normalizado();
        const sx = c.cx + l.x * c.meio * 0.8;
        const sy = c.cy - l.y * c.meio * 0.8;
        app.tracejada(c.cx, c.cy, sx, sy, cores.laranja);
        app.circulo(sx, sy, 10, opaco | 0xfacc15);
        const a = app.area();
        app.textoF(a.x0 + 16, 16, cores.tinta, "sombreamento: {s}", .{@tagName(il.modo)});

        p.titulo("O que é");
        p.txt("Modelo de iluminação de Phong: I = ka + kd·max(N·L, 0) + ks·max(R·V, 0)^n. Ambiente (luz espalhada), difusa (Lambert: depende do ângulo entre a normal N e a luz L) e especular (o brilho, onde a luz refletida R aponta para o olho V).");
        switch (il.modo) {
            .flat => p.txt("Flat: uma conta por triângulo, com a normal da face. Rápido, mas as facetas aparecem."),
            .gouraud => p.txt("Gouraud: a conta é feita nos vértices (com a normal de cada vértice) e a COR é interpolada dentro do triângulo. Liso, mas o brilho fica borrado ou some com poucos triângulos."),
            .phong => p.txt("Phong: a NORMAL é interpolada e a conta é feita em cada pixel. O brilho fica certo mesmo com poucos triângulos, ao custo de uma conta por pixel."),
        }
        p.titulo("Ao vivo");
        p.val("ka = {d:.2}  kd = {d:.2}  ks = {d:.2}  n = {d:.0}", .{ il.ka, il.kd, il.ks, il.brilho });
        p.val("L = ({d:.2}, {d:.2}, {d:.2})  V = (0, 0, 1)", .{ l.x, l.y, l.z });
        p.val("esfera: {d} triângulos ({d} visíveis)", .{ malha.tris.len, desenhados });
        if (il.sonda.ok) {
            if (il.modo == .phong) {
                const n = il.sonda.a.normalizado();
                const nl = n.escalar(l);
                const rr = n.vezes(2 * nl).menos(l);
                p.val("no mouse: N = ({d:.2}, {d:.2}, {d:.2})", .{ n.x, n.y, n.z });
                p.val("  N·L = {d:.3}   R·V = {d:.3}", .{ nl, rr.z });
                p.val("  I = {d:.2} + {d:.2}·{d:.2} + {d:.2}·{d:.3}", .{ il.ka, il.kd, @max(nl, 0), il.ks, if (nl > 0) std.math.pow(f32, @max(rr.z, 0), il.brilho) else 0 });
            } else {
                p.val("no mouse: cor interpolada", .{});
                p.val("  RGB = ({d:.2}, {d:.2}, {d:.2})", .{ il.sonda.a.x, il.sonda.a.y, il.sonda.a.z });
            }
        } else p.val("(passe o mouse na esfera)", .{});
        p.titulo("Controles");
        p.ctl("m  flat / Gouraud / Phong");
        p.ctl("arrastar (esq.)  move a luz");
        p.ctl("arrastar (dir.)  gira a esfera");
        p.ctl("- / =  menos/mais triângulos");
        p.ctl("a A  ambiente   d D  difusa");
        p.ctl("s S  especular  n N  brilho");
        p.ctl("w  mostra as arestas");
    }
};

// ===========================================================================
// 9. Animação

const Animacao = struct {
    t: f32 = 0,
    vel: f32 = 1,
    pausado: bool = false,
    eixos: bool = true,
    rastro: bool = true,
    trilha: [300][2]f32 = undefined,
    nt: usize = 0,
    it: usize = 0,
    ultimo_t: f32 = -1,

    pub fn tecla(an: *Animacao, _: *App, s: u32) void {
        switch (s) {
            ' ' => an.pausado = !an.pausado,
            '-' => an.vel = @max(0.125, an.vel / 2),
            '=', '+' => an.vel = @min(8, an.vel * 2),
            'h' => an.eixos = !an.eixos,
            'r' => {
                an.rastro = !an.rastro;
                an.nt = 0;
            },
            '0' => an.* = .{},
            0xff53 => an.t += 0.1,
            0xff51 => an.t = @max(0, an.t - 0.1),
            else => {},
        }
    }

    fn eixosDe(app: *App, m: Mat3) void {
        const o = m.aplicar(0, 0);
        const x = m.aplicar(28, 0);
        const y = m.aplicar(0, 28);
        app.seta(o.x, o.y, x.x, x.y, 1.5, cores.vermelho);
        app.seta(o.x, o.y, y.x, y.y, 1.5, cores.verde);
    }

    fn suave(u: f32) f32 {
        return u * u * (3 - 2 * u);
    }
    fn quique(u_ini: f32) f32 {
        const n1: f32 = 7.5625;
        const d1: f32 = 2.75;
        var u = u_ini;
        if (u < 1 / d1) return n1 * u * u;
        if (u < 2 / d1) {
            u -= 1.5 / d1;
            return n1 * u * u + 0.75;
        }
        if (u < 2.5 / d1) {
            u -= 2.25 / d1;
            return n1 * u * u + 0.9375;
        }
        u -= 2.625 / d1;
        return n1 * u * u + 0.984375;
    }

    pub fn pintar(an: *Animacao, app: *App, p: *Painel) void {
        const a = app.area();
        const t = an.t;
        const altura_faixa: f32 = 170;
        const cx = fl(a.x0 + a.x1) / 2;
        const cy = (fl(a.y1) - altura_faixa) / 2 + 10;
        const raio_terra = @min(fl(a.x1 - a.x0) * 0.36, cy - 40);
        const w_terra: f32 = 2.0 * std.math.pi / 10.0; // uma volta a cada 10 s
        const w_lua: f32 = 2.0 * std.math.pi / 2.5;
        const w_giro: f32 = 2.0 * std.math.pi / 1.5;

        // Grafo de cena: cada corpo é desenhado no sistema de coordenadas do pai.
        const m_sol = Mat3.translacao(cx, cy).vezes(Mat3.rotacao(t * 0.3));
        const m_orbita = Mat3.translacao(cx, cy).vezes(Mat3.rotacao(t * w_terra)).vezes(Mat3.translacao(raio_terra, 0));
        const m_terra = m_orbita.vezes(Mat3.rotacao(t * w_giro));
        const m_lua = m_orbita.vezes(Mat3.rotacao(t * w_lua)).vezes(Mat3.translacao(52, 0));

        // Órbitas.
        var i: usize = 0;
        while (i < 96) : (i += 1) {
            const a0 = fl(@intCast(i)) * std.math.pi / 48;
            const a1 = fl(@intCast(i + 1)) * std.math.pi / 48;
            app.tracejada(cx + raio_terra * @cos(a0), cy + raio_terra * @sin(a0), cx + raio_terra * @cos(a1), cy + raio_terra * @sin(a1), cores.grade);
        }
        const pl = m_lua.aplicar(0, 0);
        if (an.rastro) {
            if (t != an.ultimo_t) {
                an.trilha[an.it] = .{ pl.x, pl.y };
                an.it = (an.it + 1) % an.trilha.len;
                an.nt = @min(an.nt + 1, an.trilha.len);
                an.ultimo_t = t;
            }
            for (0..an.nt) |k| {
                const q = an.trilha[(an.it + an.trilha.len - 1 - k) % an.trilha.len];
                app.tela.misturar(paraInt(q[0]), paraInt(q[1]), cores.azul, 1 - fl(@intCast(k)) / fl(@intCast(an.trilha.len)));
            }
        }
        const ps = m_sol.aplicar(0, 0);
        app.circulo(ps.x, ps.y, 34, opaco | 0xfacc15);
        const pt = m_terra.aplicar(0, 0);
        app.circulo(pt.x, pt.y, 16, opaco | 0x3b82f6);
        const marca = m_terra.aplicar(16, 0);
        app.linha(pt.x, pt.y, marca.x, marca.y, 2, cores.branco);
        app.circulo(pl.x, pl.y, 7, cores.cinza);
        if (an.eixos) {
            eixosDe(app, m_sol);
            eixosDe(app, m_terra);
            eixosDe(app, m_lua);
        }

        // Faixa de interpolação: de A até B e volta, com três curvas de tempo.
        const fy = fl(a.y1) - altura_faixa;
        app.ret(a.x0, paraInt(fy), a.x1, a.y1, opaco | 0xefede8);
        const x0 = fl(a.x0) + 150;
        const x1 = fl(a.x1) - 190;
        const ciclo = @mod(t / 2, 2);
        const u = if (ciclo < 1) ciclo else 2 - ciclo;
        const curvas = [_]struct { n: []const u8, f: *const fn (f32) f32, c: Cor }{
            .{ .n = "linear", .f = &linear, .c = cores.tinta },
            .{ .n = "suave", .f = &suave, .c = cores.roxo },
            .{ .n = "quique", .f = &quique, .c = cores.laranja },
        };
        app.texto(a.x0 + 16, paraInt(fy) + 10, "interpolação entre dois quadros-chave (A e B)", cores.cinza);
        for (curvas, 0..) |c, k| {
            const y = fy + 50 + fl(@intCast(k)) * 40;
            app.texto(a.x0 + 16, paraInt(y) - 8, c.n, c.c);
            app.tracejada(x0, y, x1, y, cores.cinza);
            app.texto(paraInt(x0) - 14, paraInt(y) - 8, "A", cores.cinza);
            app.texto(paraInt(x1) + 6, paraInt(y) - 8, "B", cores.cinza);
            app.circulo(x0 + (x1 - x0) * c.f(u), y, 10, c.c);
            // O gráfico da curva: tempo no x, posição no y.
            const gx = fl(a.x1) - 150;
            const gy = y + 15;
            const gw: f32 = 34;
            const gh: f32 = 30;
            var s: usize = 0;
            while (s < 20) : (s += 1) {
                const s0 = fl(@intCast(s)) / 20;
                const s1 = fl(@intCast(s + 1)) / 20;
                app.linha(gx + s0 * gw * 3, gy - c.f(s0) * gh, gx + s1 * gw * 3, gy - c.f(s1) * gh, 1.2, c.c);
            }
            app.circulo(gx + u * gw * 3, gy - c.f(u) * gh, 3, cores.vermelho);
        }

        p.titulo("O que é");
        p.txt("Animar é redesenhar a cena muitas vezes por segundo, mudando um pouco a cada quadro em função do tempo t.");
        p.txt("Grafo de cena: a Lua é desenhada no sistema de coordenadas da Terra, que está no do Sol. A matriz de cada corpo é a do pai vezes a sua: basta girar o pai e os filhos vão junto. As setas mostram os eixos x (vermelho) e y (verde) de cada sistema.");
        p.txt("Embaixo: entre dois quadros-chave a posição é interpolada. A curva de tempo muda o movimento (constante, acelerando e freando, quicando).");
        p.titulo("Ao vivo");
        p.val("t = {d:.2} s   velocidade {d:.3}x", .{ t, an.vel });
        p.val("M_terra = T(c)·R({d:.0}°)·T({d:.0}, 0)·R({d:.0}°)", .{ @mod(t * w_terra * 180 / std.math.pi, 360), raio_terra, @mod(t * w_giro * 180 / std.math.pi, 360) });
        p.val("M_lua   = T(c)·R({d:.0}°)·T({d:.0}, 0)·R({d:.0}°)·T(52, 0)", .{ @mod(t * w_terra * 180 / std.math.pi, 360), raio_terra, @mod(t * w_lua * 180 / std.math.pi, 360) });
        p.mat3("Lua", m_lua);
        p.val("u = {d:.2}: linear {d:.2}  suave {d:.2}  quique {d:.2}", .{ u, u, suave(u), quique(u) });
        p.val("último quadro: {d:.1} ms ({d:.0} quadros/s possíveis)", .{ app.quadro_ms, 1000 / @max(app.quadro_ms, 0.1) });
        p.titulo("Controles");
        p.ctl("espaço  pausa   setas  avança/volta");
        p.ctl("- / =   mais devagar / mais rápido");
        p.ctl("h  eixos   r  rastro   0  reinicia");
    }
};

fn linear(u: f32) f32 {
    return u;
}

// ===========================================================================

pub fn main(init: std.process.Init) !void {
    var janela = try x11.Janela.abrir(init.gpa, init.environ_map, "CG Interativa", 1400, 860);
    defer janela.fechar();
    var app: App = .{
        .gpa = init.gpa,
        .janela = &janela,
        .tela = try Tela.criar(init.gpa, 1400, 860, cores.demo),
    };
    defer app.tela.destruir();
    defer init.gpa.free(app.zbuf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        const n = std.fmt.parseInt(usize, args[1], 10) catch 1;
        app.irPara(n -| 1);
    }

    // Pra gerar as figuras do artigo sem mexer no mouse de ninguém:
    // CG_MOUSE="x,y" põe o mouse num lugar; CG_PRINT=arquivo.ppm pinta um
    // quadro, salva e sai.
    if (init.environ_map.get("CG_MOUSE")) |m| {
        var it = std.mem.splitScalar(u8, m, ',');
        app.mx = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
        app.my = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    }
    if (init.environ_map.get("CG_PRINT")) |caminho| {
        if (init.environ_map.get("CG_TEMPO")) |t| app.an.t = std.fmt.parseFloat(f32, t) catch 0;
        if (init.environ_map.get("CG_TECLAS")) |ts| for (ts) |c| app.naAula("tecla", .{@as(u32, c)});
        try app.pintar();
        const w: usize = app.tela.largura;
        const h: usize = app.tela.altura;
        var cab: [32]u8 = undefined;
        const c = try std.fmt.bufPrint(&cab, "P6\n{d} {d}\n255\n", .{ w, h });
        const dados = try init.gpa.alloc(u8, c.len + w * h * 3);
        defer init.gpa.free(dados);
        @memcpy(dados[0..c.len], c);
        for (app.tela.pixels, 0..) |px, i| {
            dados[c.len + i * 3] = @truncate(px >> 16);
            dados[c.len + i * 3 + 1] = @truncate(px >> 8);
            dados[c.len + i * 3 + 2] = @truncate(px);
        }
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = caminho, .data = dados });
        return;
    }

    var antes: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &antes);
    var mudou = true;
    laco: while (true) {
        const anim = app.animando();
        var evento: ?x11.Evento = if (anim) (if (janela.esperar(15)) try janela.proximo(false) else null) else try janela.proximo(true);
        while (evento) |e| : (evento = try janela.proximo(false)) {
            mudou = true;
            switch (e) {
                .fechar => break :laco,
                .expor => {},
                .redimensionar => |r| try app.tela.redimensionar(r.largura, r.altura, cores.demo),
                .tecla => |t| {
                    if (t.apertou and app.janela.simbolo(t.codigo, t.estado) == 0xff1b) break :laco;
                    app.tecla(t);
                },
                .botao => |b| {
                    const bt: Botao = .{ .numero = b.numero, .x = b.x, .y = b.y, .shift = b.estado & 1 != 0 };
                    app.shift = bt.shift;
                    if (b.apertou) app.apertou(bt) else app.soltou(bt);
                },
                .movimento => |m| app.moveu(m.x, m.y),
            }
        }
        var agora: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &agora);
        const dt = @as(f32, @floatFromInt(agora.sec - antes.sec)) + @as(f32, @floatFromInt(agora.nsec - antes.nsec)) / 1e9;
        antes = agora;
        if (app.animando()) {
            app.passo(@min(dt, 0.1));
            mudou = true;
        }
        if (mudou) {
            try app.pintar();
            mudou = false;
        }
    }
}

test {
    _ = @import("tres_d.zig");
    _ = @import("tela.zig");
    _ = @import("mat3.zig");
    _ = @import("fonte.zig");
}

const testing = std.testing;

test "Cohen-Sutherland: dentro aceita, mesmo lado rejeita, atravessando corta" {
    const r: Retangulo = .{ .xmin = 0, .ymin = 0, .xmax = 10, .ymax = 10 };
    try testing.expect(cohenSutherland(r, .{ 1, 1 }, .{ 9, 9 }, null) != null);
    try testing.expect(cohenSutherland(r, .{ -5, -1 }, .{ -1, 20 }, null) == null);
    const c = cohenSutherland(r, .{ -5, 5 }, .{ 15, 5 }, null).?;
    try testing.expectApproxEqAbs(@as(f32, 0), c[0][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 10), c[1][0], 1e-5);
    try testing.expectEqual(@as(u4, CIMA | ESQ), codigo(r, -1, -1));
}

test "Bresenham e DDA acendem um pixel por coluna numa reta deitada" {
    var buf: [64]Retas.Px = undefined;
    const n = Retas.bresenham(.{ 0, 0 }, .{ 10, 3 }, &buf);
    try testing.expectEqual(@as(usize, 11), n);
    const m = Retas.dda(.{ 0, 0 }, .{ 10, 3 }, &buf);
    try testing.expectEqual(@as(usize, 11), m);
    try testing.expectEqual(@as(i32, 3), buf[10].y);
}
