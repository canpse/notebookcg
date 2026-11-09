//! Gravação de PNG, com o compressor (deflate) escrito aqui.
//!
//! Um PNG é: assinatura, pedaços (IHDR com o tamanho, IDAT com os pixels
//! comprimidos, IEND) e um CRC em cada pedaço. Os pixels vão linha por linha,
//! cada linha com um FILTRO na frente: em vez do valor do pixel, guarda a
//! diferença pro vizinho (esquerda, cima...). Num desenho com áreas lisas a
//! diferença é quase sempre zero, e zeros repetidos comprimem muito.
//!
//! A compressão é o deflate (o mesmo do zip): LZ77 troca um trecho repetido
//! por "volte D bytes e copie N", e um código de Huffman fixo escreve
//! letras e pares (N, D) com poucos bits.
const std = @import("std");
const Tela = @import("tela.zig").Tela;

// ---------------------------------------------------------------- deflate

/// Escreve bits do menos significativo pro mais, como o deflate pede.
const Bits = struct {
    saida: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    acumulado: u64 = 0,
    n: u6 = 0,

    fn por(b: *Bits, valor: u32, n: u6) !void {
        b.acumulado |= @as(u64, valor) << b.n;
        b.n += n;
        while (b.n >= 8) {
            try b.saida.append(b.gpa, @truncate(b.acumulado));
            b.acumulado >>= 8;
            b.n -= 8;
        }
    }

    /// Códigos de Huffman vão do bit mais significativo pro menos: invertidos.
    fn codigo(b: *Bits, c: u32, n: u6) !void {
        var inv: u32 = 0;
        for (0..n) |i| inv |= ((c >> @intCast(i)) & 1) << @intCast(n - 1 - i);
        try b.por(inv, n);
    }

    fn fechar(b: *Bits) !void {
        if (b.n > 0) try b.saida.append(b.gpa, @truncate(b.acumulado));
        b.acumulado = 0;
        b.n = 0;
    }
};

/// Huffman fixo do deflate (RFC 1951, 3.2.6).
fn literal(b: *Bits, v: u32) !void {
    if (v < 144) return b.codigo(0x30 + v, 8);
    if (v < 256) return b.codigo(0x190 + v - 144, 9);
    if (v < 280) return b.codigo(v - 256, 7);
    return b.codigo(0xc0 + v - 280, 8);
}

const base_tamanho = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const extra_tamanho = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const base_distancia = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const extra_distancia = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

fn copia(b: *Bits, tamanho: u32, distancia: u32) !void {
    var i: usize = base_tamanho.len - 1;
    while (base_tamanho[i] > tamanho) i -= 1;
    try literal(b, @intCast(257 + i));
    try b.por(tamanho - base_tamanho[i], extra_tamanho[i]);
    var j: usize = base_distancia.len - 1;
    while (base_distancia[j] > distancia) j -= 1;
    try b.codigo(@intCast(j), 5);
    try b.por(distancia - base_distancia[j], extra_distancia[j]);
}

const janela = 32768;
const bits_hash = 15;
const tentativas = 24;
const minimo = 3;
const maximo = 258;

fn hash3(d: []const u8, i: usize) usize {
    const v = @as(u32, d[i]) | @as(u32, d[i + 1]) << 8 | @as(u32, d[i + 2]) << 16;
    return (v *% 0x9e3779b1) >> (32 - bits_hash);
}

/// Comprime `dados` num bloco deflate só, com Huffman fixo.
pub fn deflate(gpa: std.mem.Allocator, dados: []const u8, saida: *std.ArrayList(u8)) !void {
    // Pra cada hash de 3 bytes, a última posição onde ele apareceu; e pra
    // cada posição, a anterior com o mesmo hash (a corrente de candidatos).
    const cabeca = try gpa.alloc(i32, 1 << bits_hash);
    defer gpa.free(cabeca);
    @memset(cabeca, -1);
    const anterior = try gpa.alloc(i32, janela);
    defer gpa.free(anterior);

    var b: Bits = .{ .saida = saida, .gpa = gpa };
    try b.por(1, 1); // último bloco
    try b.por(1, 2); // tipo 1: Huffman fixo
    var i: usize = 0;
    while (i < dados.len) {
        var melhor_n: usize = 0;
        var melhor_d: usize = 0;
        if (i + minimo <= dados.len) {
            const h = hash3(dados, i);
            var cand = cabeca[h];
            var tentou: usize = 0;
            const limite = @min(maximo, dados.len - i);
            while (cand >= 0 and tentou < tentativas) : (tentou += 1) {
                const c: usize = @intCast(cand);
                if (i - c > janela) break;
                var n: usize = 0;
                while (n < limite and dados[c + n] == dados[i + n]) n += 1;
                if (n > melhor_n) {
                    melhor_n = n;
                    melhor_d = i - c;
                    if (n == limite) break;
                }
                const prox = anterior[c % janela];
                if (prox >= cand) break; // corrente velha, sobrescrita
                cand = prox;
            }
        }
        const passo = if (melhor_n >= minimo) melhor_n else 1;
        if (melhor_n >= minimo) {
            try copia(&b, @intCast(melhor_n), @intCast(melhor_d));
        } else {
            try literal(&b, dados[i]);
        }
        // Registra todas as posições puladas na tabela de hash.
        for (0..passo) |_| {
            if (i + minimo <= dados.len) {
                const h = hash3(dados, i);
                anterior[i % janela] = cabeca[h];
                cabeca[h] = @intCast(i);
            }
            i += 1;
        }
    }
    try literal(&b, 256); // fim do bloco
    try b.fechar();
}

/// Envelope zlib: 2 bytes de cabeçalho, o deflate e a soma Adler-32.
pub fn zlib(gpa: std.mem.Allocator, dados: []const u8, saida: *std.ArrayList(u8)) !void {
    try saida.appendSlice(gpa, &.{ 0x78, 0x01 });
    try deflate(gpa, dados, saida);
    var soma: [4]u8 = undefined;
    std.mem.writeInt(u32, &soma, adler32(dados), .big);
    try saida.appendSlice(gpa, &soma);
}

fn adler32(dados: []const u8) u32 {
    var a: u32 = 1;
    var s: u32 = 0;
    for (dados) |c| {
        a = (a + c) % 65521;
        s = (s + a) % 65521;
    }
    return s << 16 | a;
}

// ---------------------------------------------------------------- PNG

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Linhas filtradas: pra cada linha testa os filtros e fica com o que dá
/// diferenças menores (heurística da própria especificação do PNG).
fn filtrar(gpa: std.mem.Allocator, t: *const Tela) ![]u8 {
    const w: usize = t.largura;
    const passo = w * 3;
    const saida = try gpa.alloc(u8, (passo + 1) * t.altura);
    errdefer gpa.free(saida);
    const linha = try gpa.alloc(u8, passo * 2);
    defer gpa.free(linha);
    const atual = linha[0..passo];
    const cima = linha[passo..];
    @memset(cima, 0);
    var tentativa: [4][]u8 = undefined;
    const buf = try gpa.alloc(u8, passo * 4);
    defer gpa.free(buf);
    for (0..4) |k| tentativa[k] = buf[k * passo ..][0..passo];

    for (0..t.altura) |y| {
        for (0..w) |x| {
            const p = t.pixels[y * w + x];
            atual[x * 3] = @truncate(p >> 16);
            atual[x * 3 + 1] = @truncate(p >> 8);
            atual[x * 3 + 2] = @truncate(p);
        }
        var melhor: usize = 0;
        var melhor_soma: usize = std.math.maxInt(usize);
        for (0..4) |f| {
            var soma: usize = 0;
            for (0..passo) |i| {
                const a: u8 = if (i >= 3) atual[i - 3] else 0;
                const b = cima[i];
                const c: u8 = if (i >= 3) cima[i - 3] else 0;
                const v = atual[i] -% switch (f) {
                    0 => 0,
                    1 => a,
                    2 => b,
                    else => paeth(a, b, c),
                };
                tentativa[f][i] = v;
                soma += @abs(@as(i8, @bitCast(v)));
            }
            if (soma < melhor_soma) {
                melhor_soma = soma;
                melhor = f;
            }
        }
        const destino = saida[y * (passo + 1) ..][0 .. passo + 1];
        // Números dos filtros no PNG: 0 nenhum, 1 esquerda, 2 cima, 4 Paeth.
        destino[0] = ([_]u8{ 0, 1, 2, 4 })[melhor];
        @memcpy(destino[1..], tentativa[melhor]);
        @memcpy(cima, atual);
    }
    return saida;
}

fn pedaco(gpa: std.mem.Allocator, saida: *std.ArrayList(u8), tipo: *const [4]u8, dados: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(dados.len), .big);
    try saida.appendSlice(gpa, &n);
    try saida.appendSlice(gpa, tipo);
    try saida.appendSlice(gpa, dados);
    var crc = std.hash.Crc32.init();
    crc.update(tipo);
    crc.update(dados);
    std.mem.writeInt(u32, &n, crc.final(), .big);
    try saida.appendSlice(gpa, &n);
}

/// A tela inteira como arquivo PNG (RGB, 8 bits por canal).
pub fn escrever(gpa: std.mem.Allocator, t: *const Tela) ![]u8 {
    var saida: std.ArrayList(u8) = .empty;
    errdefer saida.deinit(gpa);
    try saida.appendSlice(gpa, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], t.largura, .big);
    std.mem.writeInt(u32, ihdr[4..8], t.altura, .big);
    ihdr[8] = 8; // bits por canal
    ihdr[9] = 2; // RGB
    ihdr[10] = 0; // compressão: deflate
    ihdr[11] = 0; // filtro: os 5 padrão
    ihdr[12] = 0; // sem entrelaçamento
    try pedaco(gpa, &saida, "IHDR", &ihdr);

    const linhas = try filtrar(gpa, t);
    defer gpa.free(linhas);
    var comprimido: std.ArrayList(u8) = .empty;
    defer comprimido.deinit(gpa);
    try zlib(gpa, linhas, &comprimido);
    try pedaco(gpa, &saida, "IDAT", comprimido.items);
    try pedaco(gpa, &saida, "IEND", "");
    return saida.toOwnedSlice(gpa);
}

const testing = std.testing;
const opaco = @import("tela.zig").opaco;

fn descomprimir(comprimido: []const u8) ![]u8 {
    var entrada: std.Io.Reader = .fixed(comprimido);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&entrada, .zlib, &buf);
    return d.reader.allocRemaining(testing.allocator, .unlimited);
}

test "deflate: o descompressor da biblioteca padrão devolve o original" {
    var dados: [5000]u8 = undefined;
    // Um pouco de tudo: repetição longa, padrão curto e bytes "aleatórios".
    var aleatorio = std.Random.DefaultPrng.init(42);
    for (&dados, 0..) |*d, i| d.* = if (i < 1500) 7 else if (i < 3000) @truncate(i % 5) else aleatorio.random().int(u8);
    var saida: std.ArrayList(u8) = .empty;
    defer saida.deinit(testing.allocator);
    try zlib(testing.allocator, &dados, &saida);
    const volta = try descomprimir(saida.items);
    defer testing.allocator.free(volta);
    try testing.expectEqualSlices(u8, &dados, volta);
    // A parte repetida quase some.
    try testing.expect(saida.items.len < 2000 + 400);
}

test "deflate de nada e de um byte" {
    for ([_][]const u8{ "", "a", "abcabcabcabc" }) |s| {
        var saida: std.ArrayList(u8) = .empty;
        defer saida.deinit(testing.allocator);
        try zlib(testing.allocator, s, &saida);
        const volta = try descomprimir(saida.items);
        defer testing.allocator.free(volta);
        try testing.expectEqualStrings(s, volta);
    }
}

test "PNG: cabeçalho certo e os pixels voltam depois do filtro" {
    var t = try Tela.criar(testing.allocator, 3, 2, opaco | 0xffffff);
    defer t.destruir();
    t.pixels[1] = opaco | 0x102030;
    t.pixels[5] = opaco | 0xff0000;
    const png = try escrever(testing.allocator, &t);
    defer testing.allocator.free(png);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
    try testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    // Desfaz os filtros e confere os pixels.
    const n_idat = std.mem.readInt(u32, png[33..37], .big);
    try testing.expectEqualSlices(u8, "IDAT", png[37..41]);
    const linhas = try descomprimir(png[41..][0..n_idat]);
    defer testing.allocator.free(linhas);
    const passo = 9;
    var cima = [_]u8{0} ** passo;
    for (0..2) |y| {
        const l = linhas[y * (passo + 1) ..][0 .. passo + 1];
        var atual: [passo]u8 = undefined;
        for (0..passo) |i| {
            const a: u8 = if (i >= 3) atual[i - 3] else 0;
            const c: u8 = if (i >= 3) cima[i - 3] else 0;
            atual[i] = l[1 + i] +% switch (l[0]) {
                0 => 0,
                1 => a,
                2 => cima[i],
                4 => paeth(a, cima[i], c),
                else => return error.FiltroInesperado,
            };
        }
        for (0..3) |x| {
            const p = t.pixels[y * 3 + x];
            try testing.expectEqual(@as(u8, @truncate(p >> 16)), atual[x * 3]);
            try testing.expectEqual(@as(u8, @truncate(p)), atual[x * 3 + 2]);
        }
        cima = atual;
    }
}
