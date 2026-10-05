//! Janela no X11 falando o protocolo direto pelo socket, sem Xlib nem XCB.
//!
//! O servidor X é um programa separado. Abrir uma janela é mandar pra ele
//! mensagens binárias ("requisições") por um socket; ele devolve eventos de
//! 32 bytes (tecla, mouse, redimensionou...). Aqui só existe o mínimo que o
//! editor usa. Referência: "X Window System Protocol", versão 11.
const std = @import("std");
const linux = std.os.linux;

pub const Evento = union(enum) {
    fechar,
    /// O servidor perdeu o conteúdo da janela e quer que a gente mande de novo.
    expor,
    redimensionar: struct { largura: u16, altura: u16 },
    /// `codigo` é a posição física da tecla, não a letra.
    tecla: struct { codigo: u8, apertou: bool },
    botao: struct { numero: u8, apertou: bool, x: i16, y: i16 },
    movimento: struct { x: i16, y: i16 },
};

// Números do protocolo.
const op_criar_janela = 1;
const op_mapear_janela = 8;
const op_internar_atomo = 16;
const op_mudar_propriedade = 18;
const op_criar_gc = 55;
const op_enviar_imagem = 72;

const atomo_atom = 4;
const atomo_string = 31;
const atomo_wm_name = 39;

const mascara_eventos = 0x1 // tecla apertada
| 0x2 // tecla solta
| 0x4 // botão apertado
| 0x8 // botão solto
| 0x40 // movimento do mouse
| 0x8000 // exposição
| 0x20000; // mudança de tamanho

pub const Janela = struct {
    fd: i32,
    id: u32,
    gc: u32,
    profundidade: u8,
    /// Maior requisição que o servidor aceita, em bytes.
    max_requisicao: usize,
    atomo_protocolos: u32,
    atomo_fechar: u32,
    entrada: [4096]u8 = undefined,
    n_entrada: usize = 0,

    pub fn abrir(
        gpa: std.mem.Allocator,
        ambiente: *const std.process.Environ.Map,
        titulo: []const u8,
        largura: u16,
        altura: u16,
    ) !Janela {
        const fd = try conectar(ambiente.get("DISPLAY") orelse ":0");
        errdefer _ = linux.close(fd);

        // 1. Apresentação: ordem dos bytes, versão do protocolo e a senha.
        var arq_auth: [4096]u8 = undefined;
        const cookie = acharCookie(lerAutorizacao(ambiente, &arq_auth)) orelse "";
        const nome_auth: []const u8 = if (cookie.len > 0) "MIT-MAGIC-COOKIE-1" else "";
        var p: Pacote = .{};
        p.c8('l'); // little-endian
        p.c8(0);
        p.c16(11); // X11
        p.c16(0);
        p.c16(@intCast(nome_auth.len));
        p.c16(@intCast(cookie.len));
        p.c16(0);
        p.texto(nome_auth);
        p.texto(cookie);
        try escreverTudo(fd, p.bytes());

        // 2. O servidor responde com tudo que a gente precisa saber dele.
        var cab: [8]u8 = undefined;
        try lerTudo(fd, &cab);
        const resto = try gpa.alloc(u8, @as(usize, ler16(&cab, 6)) * 4);
        defer gpa.free(resto);
        try lerTudo(fd, resto);
        if (cab[0] != 1) {
            std.debug.print("o servidor X recusou a conexão: {s}\n", .{resto[0..@min(cab[1], resto.len)]});
            return error.ConexaoRecusada;
        }
        const base_ids = ler32(resto, 4);
        const tam_fabricante: usize = ler16(resto, 16);
        const n_formatos: usize = resto[21];
        const tela = resto[32 + alinhar4(tam_fabricante) + 8 * n_formatos ..];
        const raiz = ler32(tela, 0);
        const profundidade = tela[38];
        if (profundidade != 24) return error.ProfundidadeNaoSuportada;

        var j: Janela = .{
            .fd = fd,
            .id = base_ids, // os ids quem escolhe é o cliente, dentro da faixa que recebeu
            .gc = base_ids + 1,
            .profundidade = profundidade,
            .max_requisicao = @as(usize, ler16(resto, 18)) * 4,
            .atomo_protocolos = 0,
            .atomo_fechar = 0,
        };
        j.atomo_protocolos = try j.internarAtomo("WM_PROTOCOLS");
        j.atomo_fechar = try j.internarAtomo("WM_DELETE_WINDOW");

        // 3. Cria a janela (ainda invisível), filha da raiz.
        p = .{};
        p.c8(op_criar_janela);
        p.c8(0); // profundidade: a mesma da raiz
        p.c16(8 + 2);
        p.c32(j.id);
        p.c32(raiz);
        p.c16(0); // x, y: quem decide é o gerenciador de janelas
        p.c16(0);
        p.c16(largura);
        p.c16(altura);
        p.c16(0); // borda
        p.c16(1); // classe: entrada e saída
        p.c32(0); // visual: o mesmo da raiz
        p.c32(0x10 | 0x800); // quais atributos vêm a seguir
        p.c32(1); // gravidade noroeste: ao redimensionar, mantém o que já estava desenhado
        p.c32(mascara_eventos);
        try escreverTudo(fd, p.bytes());

        try j.mudarPropriedade(atomo_wm_name, atomo_string, 8, titulo);
        // Sem isto, clicar no X da janela derruba a conexão em vez de avisar.
        var valor: [4]u8 = undefined;
        std.mem.writeInt(u32, &valor, j.atomo_fechar, .little);
        try j.mudarPropriedade(j.atomo_protocolos, atomo_atom, 32, &valor);

        // 4. Contexto gráfico: o X exige um pra qualquer desenho, mesmo vazio.
        p = .{};
        p.c8(op_criar_gc);
        p.c8(0);
        p.c16(4);
        p.c32(j.gc);
        p.c32(j.id);
        p.c32(0);
        try escreverTudo(fd, p.bytes());

        // 5. Mostra a janela.
        p = .{};
        p.c8(op_mapear_janela);
        p.c8(0);
        p.c16(2);
        p.c32(j.id);
        try escreverTudo(fd, p.bytes());

        return j;
    }

    pub fn fechar(j: *Janela) void {
        _ = linux.close(j.fd);
    }

    /// Copia os pixels pra janela. `pixels` tem `largura * altura` cores 0x00RRGGBB.
    pub fn mostrar(j: *Janela, pixels: []const u32, largura: u16, altura: u16) !void {
        // Uma requisição tem tamanho máximo, então a imagem vai em faixas horizontais.
        const linhas_por_faixa = @max(1, (j.max_requisicao - 24) / (@as(usize, largura) * 4));
        var y: usize = 0;
        while (y < altura) {
            const n = @min(linhas_por_faixa, altura - y);
            const faixa = std.mem.sliceAsBytes(pixels[y * largura ..][0 .. n * largura]);
            var p: Pacote = .{};
            p.c8(op_enviar_imagem);
            p.c8(2); // formato: um valor por pixel
            p.c16(@intCast(6 + faixa.len / 4));
            p.c32(j.id);
            p.c32(j.gc);
            p.c16(largura);
            p.c16(@intCast(n));
            p.c16(0); // x de destino
            p.c16(@intCast(y)); // y de destino
            p.c8(0);
            p.c8(j.profundidade);
            p.c16(0);
            try escreverTudo(j.fd, p.bytes());
            try escreverTudo(j.fd, faixa);
            y += n;
        }
    }

    /// Devolve o próximo evento. Com `bloquear`, dorme até chegar um; sem,
    /// devolve null quando não há nada esperando.
    pub fn proximo(j: *Janela, bloquear: bool) !?Evento {
        while (true) {
            while (j.n_entrada >= 32) {
                const bruto = j.entrada[0..32].*;
                std.mem.copyForwards(u8, j.entrada[0 .. j.n_entrada - 32], j.entrada[32..j.n_entrada]);
                j.n_entrada -= 32;
                if (j.traduzir(&bruto)) |ev| return ev;
            }
            if (!bloquear) {
                var espera = [1]linux.pollfd{.{ .fd = j.fd, .events = linux.POLL.IN, .revents = 0 }};
                if (linux.poll(&espera, 1, 0) != 1) return null;
            }
            const r = linux.read(j.fd, j.entrada[j.n_entrada..].ptr, j.entrada.len - j.n_entrada);
            switch (linux.errno(r)) {
                .SUCCESS => {
                    if (r == 0) return .fechar; // o servidor desligou
                    j.n_entrada += r;
                },
                .INTR => {},
                else => return error.LeituraFalhou,
            }
        }
    }

    fn traduzir(j: *const Janela, b: *const [32]u8) ?Evento {
        // O bit mais alto só diz que o evento foi enviado por outro programa.
        const tipo = b[0] & 0x7f;
        return switch (tipo) {
            0 => {
                std.debug.print("erro do X11: código {d} na requisição {d}\n", .{ b[1], b[10] });
                return null;
            },
            2, 3 => .{ .tecla = .{ .codigo = b[1], .apertou = tipo == 2 } },
            4, 5 => .{ .botao = .{ .numero = b[1], .apertou = tipo == 4, .x = lerI16(b, 24), .y = lerI16(b, 26) } },
            6 => .{ .movimento = .{ .x = lerI16(b, 24), .y = lerI16(b, 26) } },
            // Uma exposição pode vir em vários pedaços; basta redesenhar no último.
            12 => if (ler16(b, 16) == 0) .expor else null,
            22 => .{ .redimensionar = .{ .largura = ler16(b, 20), .altura = ler16(b, 22) } },
            33 => if (ler32(b, 8) == j.atomo_protocolos and ler32(b, 12) == j.atomo_fechar) .fechar else null,
            else => null,
        };
    }

    /// Átomo é o número que o servidor dá pra um nome. Só funciona antes de a
    /// janela existir, porque lê a resposta sem esperar eventos no meio.
    fn internarAtomo(j: *Janela, nome: []const u8) !u32 {
        var p: Pacote = .{};
        p.c8(op_internar_atomo);
        p.c8(0);
        p.c16(@intCast(2 + alinhar4(nome.len) / 4));
        p.c16(@intCast(nome.len));
        p.c16(0);
        p.texto(nome);
        try escreverTudo(j.fd, p.bytes());
        var resposta: [32]u8 = undefined;
        try lerTudo(j.fd, &resposta);
        if (resposta[0] != 1) return error.RespostaInesperada;
        return ler32(&resposta, 8);
    }

    fn mudarPropriedade(j: *Janela, propriedade: u32, tipo: u32, bits: u8, dados: []const u8) !void {
        var p: Pacote = .{};
        p.c8(op_mudar_propriedade);
        p.c8(0); // substituir
        p.c16(@intCast(6 + alinhar4(dados.len) / 4));
        p.c32(j.id);
        p.c32(propriedade);
        p.c32(tipo);
        p.c8(bits);
        p.c8(0);
        p.c16(0);
        p.c32(@intCast(dados.len / (bits / 8)));
        p.texto(dados);
        try escreverTudo(j.fd, p.bytes());
    }
};

/// Monta uma requisição campo a campo, em little-endian.
const Pacote = struct {
    dados: [512]u8 = undefined,
    n: usize = 0,

    fn c8(p: *Pacote, v: u8) void {
        p.dados[p.n] = v;
        p.n += 1;
    }
    fn c16(p: *Pacote, v: u16) void {
        std.mem.writeInt(u16, p.dados[p.n..][0..2], v, .little);
        p.n += 2;
    }
    fn c32(p: *Pacote, v: u32) void {
        std.mem.writeInt(u32, p.dados[p.n..][0..4], v, .little);
        p.n += 4;
    }
    /// Bytes seguidos de zeros até fechar um múltiplo de 4, como o X exige.
    fn texto(p: *Pacote, s: []const u8) void {
        @memcpy(p.dados[p.n..][0..s.len], s);
        p.n += s.len;
        while (p.n % 4 != 0) p.c8(0);
    }
    fn bytes(p: *const Pacote) []const u8 {
        return p.dados[0..p.n];
    }
};

fn alinhar4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn ler16(b: []const u8, pos: usize) u16 {
    return std.mem.readInt(u16, b[pos..][0..2], .little);
}

fn lerI16(b: []const u8, pos: usize) i16 {
    return std.mem.readInt(i16, b[pos..][0..2], .little);
}

fn ler32(b: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, b[pos..][0..4], .little);
}

/// DISPLAY=":0" quer dizer o socket /tmp/.X11-unix/X0.
fn conectar(display: []const u8) !i32 {
    const inicio = (std.mem.indexOfScalar(u8, display, ':') orelse return error.DisplayInvalido) + 1;
    const fim = std.mem.indexOfScalarPos(u8, display, inicio, '.') orelse display.len;
    const numero = std.fmt.parseInt(u16, display[inicio..fim], 10) catch return error.DisplayInvalido;

    const r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(r) != .SUCCESS) return error.SocketFalhou;
    const fd: i32 = @intCast(r);
    errdefer _ = linux.close(fd);

    var endereco: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = try std.fmt.bufPrint(&endereco.path, "/tmp/.X11-unix/X{d}", .{numero});
    if (linux.errno(linux.connect(fd, &endereco, @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        return error.ServidorXNaoEncontrado;
    }
    return fd;
}

/// Lê o arquivo de senhas do X ($XAUTHORITY ou ~/.Xauthority). Sem arquivo, devolve vazio.
fn lerAutorizacao(ambiente: *const std.process.Environ.Map, destino: []u8) []const u8 {
    var caminho: [512]u8 = undefined;
    const c = if (ambiente.get("XAUTHORITY")) |x|
        std.fmt.bufPrintZ(&caminho, "{s}", .{x}) catch return ""
    else
        std.fmt.bufPrintZ(&caminho, "{s}/.Xauthority", .{ambiente.get("HOME") orelse return ""}) catch return "";

    const r = linux.open(c.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(r) != .SUCCESS) return "";
    const fd: i32 = @intCast(r);
    defer _ = linux.close(fd);

    var n: usize = 0;
    while (n < destino.len) {
        const lido = linux.read(fd, destino[n..].ptr, destino.len - n);
        if (linux.errno(lido) != .SUCCESS or lido == 0) break;
        n += lido;
    }
    return destino[0..n];
}

/// O arquivo é uma lista de entradas (família, endereço, número, nome, dados),
/// cada campo precedido do tamanho em 2 bytes big-endian.
fn acharCookie(arquivo: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (true) {
        i += 2; // família
        _ = campo(arquivo, &i) orelse return null; // endereço
        _ = campo(arquivo, &i) orelse return null; // número do display
        const nome = campo(arquivo, &i) orelse return null;
        const dados = campo(arquivo, &i) orelse return null;
        if (std.mem.eql(u8, nome, "MIT-MAGIC-COOKIE-1")) return dados;
    }
}

fn campo(arquivo: []const u8, i: *usize) ?[]const u8 {
    if (i.* + 2 > arquivo.len) return null;
    const n = std.mem.readInt(u16, arquivo[i.*..][0..2], .big);
    i.* += 2;
    if (i.* + n > arquivo.len) return null;
    defer i.* += n;
    return arquivo[i.*..][0..n];
}

fn escreverTudo(fd: i32, dados: []const u8) !void {
    var resto = dados;
    while (resto.len > 0) {
        const r = linux.write(fd, resto.ptr, resto.len);
        switch (linux.errno(r)) {
            .SUCCESS => resto = resto[r..],
            .INTR => {},
            else => return error.EscritaFalhou,
        }
    }
}

fn lerTudo(fd: i32, destino: []u8) !void {
    var n: usize = 0;
    while (n < destino.len) {
        const r = linux.read(fd, destino[n..].ptr, destino.len - n);
        switch (linux.errno(r)) {
            .SUCCESS => {
                if (r == 0) return error.ConexaoFechada;
                n += r;
            },
            .INTR => {},
            else => return error.LeituraFalhou,
        }
    }
}

test "acha o cookie pulando entradas de outro tipo" {
    const arquivo = "\x01\x00" ++ "\x00\x02pc" ++ "\x00\x010" ++ "\x00\x05OUTRO" ++ "\x00\x02zz" ++
        "\x01\x00" ++ "\x00\x02pc" ++ "\x00\x00" ++ "\x00\x12MIT-MAGIC-COOKIE-1" ++ "\x00\x04abcd";
    try std.testing.expectEqualStrings("abcd", acharCookie(arquivo).?);
    try std.testing.expect(acharCookie(arquivo[0 .. arquivo.len - 1]) == null);
    try std.testing.expect(acharCookie("") == null);
}

test "pacote alinha o texto em 4 bytes" {
    var p: Pacote = .{};
    p.c16(0x1234);
    p.texto("abc");
    try std.testing.expectEqualSlices(u8, "\x34\x12abc\x00\x00\x00", p.bytes());
}
