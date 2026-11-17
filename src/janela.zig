//! A janela do sistema: X11 no Linux (e outros Unix), Win32 no Windows.
//! As duas têm a mesma interface (abrir, mostrar, proximo, esperar, simbolo).
const builtin = @import("builtin");
const sistema = if (builtin.os.tag == .windows) @import("win32.zig") else @import("x11.zig");

pub const Janela = sistema.Janela;
pub const Evento = sistema.Evento;

/// Relógio monotônico em segundos (pra animação e pra medir o quadro).
pub fn agora() f64 {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
            extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
        };
        var c: i64 = 0;
        var f: i64 = 1;
        _ = k.QueryPerformanceCounter(&c);
        _ = k.QueryPerformanceFrequency(&f);
        return @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(f));
    }
    const linux = @import("std").os.linux;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

/// O sistema está em português? (Linux: $LANG; Windows: idioma da interface.)
pub fn sistemaEmPortugues(lang: ?[]const u8) bool {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
        };
        if (lang == null) return k.GetUserDefaultUILanguage() & 0x3ff == 0x16; // LANG_PORTUGUESE
    }
    const l = lang orelse return true;
    return l.len >= 2 and l[0] == 'p' and l[1] == 't';
}
