//! De tecla a letra. O X11 diz o símbolo (keysym) de cada tecla no layout
//! do sistema; aqui ele vira um caractere Unicode ou um comando (apagar,
//! confirmar, cancelar).
//!
//! Acentos no teclado brasileiro usam "tecla morta": ´ sozinho não escreve
//! nada, espera a próxima letra e as duas viram uma só (´ + a = á). Com
//! espaço, sai o próprio acento.
const std = @import("std");

pub const Tecla = union(enum) {
    letra: u21,
    apagar,
    confirmar,
    cancelar,
    /// Tecla que não escreve (shift, acento esperando a próxima, ...).
    nada,
};

const Regra = struct { acento: u21, de: []const u8, para: []const u21 };

const regras = [_]Regra{
    .{ .acento = '´', .de = "aeiouyAEIOUYcC", .para = &.{ 'á', 'é', 'í', 'ó', 'ú', 'ý', 'Á', 'É', 'Í', 'Ó', 'Ú', 'Ý', 'ç', 'Ç' } },
    .{ .acento = '`', .de = "aeiouAEIOU", .para = &.{ 'à', 'è', 'ì', 'ò', 'ù', 'À', 'È', 'Ì', 'Ò', 'Ù' } },
    .{ .acento = '^', .de = "aeiouAEIOU", .para = &.{ 'â', 'ê', 'î', 'ô', 'û', 'Â', 'Ê', 'Î', 'Ô', 'Û' } },
    .{ .acento = '~', .de = "aonAON", .para = &.{ 'ã', 'õ', 'ñ', 'Ã', 'Õ', 'Ñ' } },
    .{ .acento = '¨', .de = "aeiouAEIOU", .para = &.{ 'ä', 'ë', 'ï', 'ö', 'ü', 'Ä', 'Ë', 'Ï', 'Ö', 'Ü' } },
    .{ .acento = '¸', .de = "cC", .para = &.{ 'ç', 'Ç' } },
};

fn compor(acento: u21, base: u21) ?u21 {
    for (regras) |r| {
        if (r.acento != acento) continue;
        for (r.de, r.para) |d, p| {
            if (d == base) return p;
        }
    }
    return null;
}

/// Teclas mortas do X11 (dead_grave, dead_acute...) e o acento de cada uma.
fn acentoMorto(keysym: u32) ?u21 {
    return switch (keysym) {
        0xfe50 => '`',
        0xfe51 => '´',
        0xfe52 => '^',
        0xfe53 => '~',
        0xfe57 => '¨',
        0xfe5b => '¸',
        else => null,
    };
}

/// Caractere que o keysym escreve, se escrever algum.
fn unicode(keysym: u32) ?u21 {
    // Latin-1: o número do keysym é o próprio código Unicode.
    if ((keysym >= 0x20 and keysym <= 0x7e) or (keysym >= 0xa0 and keysym <= 0xff)) return @intCast(keysym);
    // Keysyms "Unicode": 0x01000000 + código.
    if (keysym & 0xff000000 == 0x01000000) return @intCast(keysym & 0x1fffff);
    return null;
}

pub const Digitacao = struct {
    /// Acento esperando a próxima tecla.
    morta: ?u21 = null,

    pub fn traduzir(d: *Digitacao, keysym: u32) Tecla {
        switch (keysym) {
            0xff08 => return .apagar,
            0xff0d, 0xff8d => return .confirmar,
            0xff1b => return .cancelar,
            else => {},
        }
        if (acentoMorto(keysym)) |a| {
            // Duas mortas iguais seguidas: sai o acento.
            if (d.morta == a) {
                d.morta = null;
                return .{ .letra = a };
            }
            d.morta = a;
            return .nada;
        }
        const c = unicode(keysym) orelse return .nada; // shift, ctrl...
        const a = d.morta orelse return .{ .letra = c };
        d.morta = null;
        if (c == ' ') return .{ .letra = a };
        return .{ .letra = compor(a, c) orelse c };
    }
};

const testing = std.testing;

test "tecla morta junta com a próxima letra" {
    var d: Digitacao = .{};
    try testing.expectEqual(Tecla.nada, d.traduzir(0xfe51)); // ´
    try testing.expectEqual(Tecla{ .letra = 'á' }, d.traduzir('a'));
    try testing.expectEqual(Tecla.nada, d.traduzir(0xfe53)); // ~
    try testing.expectEqual(Tecla{ .letra = 'Ã' }, d.traduzir('A'));
    try testing.expectEqual(Tecla{ .letra = 'b' }, d.traduzir('b'));
}

test "acento com espaço sai sozinho; sem combinação, a letra sai sem acento" {
    var d: Digitacao = .{};
    _ = d.traduzir(0xfe52);
    try testing.expectEqual(Tecla{ .letra = '^' }, d.traduzir(' '));
    _ = d.traduzir(0xfe53);
    try testing.expectEqual(Tecla{ .letra = 'x' }, d.traduzir('x'));
}

test "comandos e teclas que não escrevem" {
    var d: Digitacao = .{};
    try testing.expectEqual(Tecla.apagar, d.traduzir(0xff08));
    try testing.expectEqual(Tecla.confirmar, d.traduzir(0xff0d));
    try testing.expectEqual(Tecla.nada, d.traduzir(0xffe1)); // shift
    try testing.expectEqual(Tecla{ .letra = 'ç' }, d.traduzir(0xe7)); // a tecla Ç do ABNT2
}
