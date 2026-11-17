//! Janela no Windows pela API Win32 (user32 e gdi32), com a mesma cara da
//! janela do X11 (`x11.zig`): abrir, mostrar os pixels, próximo evento.
//! O resto do programa não sabe em qual sistema está.
//!
//! No Windows quem recebe os eventos é uma função nossa que o sistema chama
//! (`procedimento`); ela só guarda cada evento numa fila, e `proximo` tira
//! da fila, como no X11.
const std = @import("std");

pub const Evento = @import("x11.zig").Evento;

const HWND = *opaque {};
const HDC = *opaque {};
const HINSTANCE = *opaque {};
const HCURSOR = *opaque {};
const BOOL = i32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct { hwnd: ?HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: u32, pt: POINT, lPrivate: u32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const PAINTSTRUCT = extern struct { hdc: HDC, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
const BITMAPINFO = extern struct { bmiHeader: BITMAPINFOHEADER, bmiColors: [1]u32 = .{0} };

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn MsgWaitForMultipleObjects(u32, ?*const anyopaque, BOOL, u32, u32) callconv(.winapi) u32;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) i32;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn AdjustWindowRect(*RECT, u32, BOOL) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
extern "gdi32" fn SetDIBitsToDevice(HDC, i32, i32, u32, u32, i32, i32, u32, u32, *const anyopaque, *const BITMAPINFO, u32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;

const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_PAINT = 0x000F;
const WM_CLOSE = 0x0010;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEWHEEL = 0x020A;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const PM_REMOVE = 1;
const QS_ALLINPUT = 0x04FF;
const IDC_ARROW = 32512;

pub const Janela = struct {
    hwnd: HWND,
    fila: [256]Evento = undefined,
    ini: usize = 0,
    n: usize = 0,
    pixels: ?[]const u32 = null,
    largura: u16 = 0,
    altura: u16 = 0,
    /// Última posição do mouse (a rodinha não traz a posição na janela).
    mx: i16 = 0,
    my: i16 = 0,
    /// O Windows não deixa voltar com erro de dentro do `procedimento`;
    /// quem chama `abrir` guarda a janela aqui pra ele achar a fila.
    var atual: ?*Janela = null;

    pub fn abrir(gpa: std.mem.Allocator, _: anytype, titulo: []const u8, largura: u16, altura: u16) !Janela {
        _ = SetProcessDPIAware();
        const inst = GetModuleHandleW(null);
        const classe = std.unicode.utf8ToUtf16LeStringLiteral("CGInterativa");
        const wc: WNDCLASSEXW = .{ .lpfnWndProc = procedimento, .hInstance = inst, .lpszClassName = classe, .hCursor = LoadCursorW(null, IDC_ARROW), .hIcon = null };
        // A classe é registrada uma vez por processo; a segunda janela reusa.
        const registrada = struct {
            var ja: bool = false;
        };
        if (!registrada.ja) {
            if (RegisterClassExW(&wc) == 0) return error.JanelaFalhou;
            registrada.ja = true;
        }
        const t16 = try std.unicode.utf8ToUtf16LeAllocZ(gpa, titulo);
        defer gpa.free(t16);
        var r: RECT = .{ .left = 0, .top = 0, .right = largura, .bottom = altura };
        _ = AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, 0);
        const hwnd = CreateWindowExW(0, classe, t16, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, null, null, inst, null) orelse return error.JanelaFalhou;
        return .{ .hwnd = hwnd };
    }

    /// Precisa ser chamada com a janela já no lugar definitivo (o
    /// `procedimento` escreve na fila por este ponteiro).
    fn ligar(j: *Janela) void {
        if (atual != j) {
            atual = j;
            _ = ShowWindow(j.hwnd, 1);
        }
    }

    pub fn fechar(j: *Janela) void {
        _ = DestroyWindow(j.hwnd);
        atual = null;
    }

    fn empurrar(j: *Janela, e: Evento) void {
        // Movimentos seguidos: só o último interessa (evita encher a fila).
        if (e == .movimento and j.n > 0) {
            const ult = &j.fila[(j.ini + j.n - 1) % j.fila.len];
            if (ult.* == .movimento) {
                ult.* = e;
                return;
            }
        }
        if (j.n == j.fila.len) return;
        j.fila[(j.ini + j.n) % j.fila.len] = e;
        j.n += 1;
    }

    fn tirar(j: *Janela) ?Evento {
        if (j.n == 0) return null;
        const e = j.fila[j.ini];
        j.ini = (j.ini + 1) % j.fila.len;
        j.n -= 1;
        return e;
    }

    pub fn mostrar(j: *Janela, pixels: []const u32, largura: u16, altura: u16) !void {
        j.ligar();
        j.pixels = pixels;
        j.largura = largura;
        j.altura = altura;
        const dc = GetDC(j.hwnd) orelse return;
        defer _ = ReleaseDC(j.hwnd, dc);
        j.copiar(dc);
    }

    /// 0xAARRGGBB na memória (little-endian) é B, G, R, A: exatamente o
    /// formato de um bitmap de 32 bits do Windows. Altura negativa = a
    /// primeira linha é a de cima, como na nossa tela.
    fn copiar(j: *Janela, dc: HDC) void {
        const px = j.pixels orelse return;
        const bi: BITMAPINFO = .{ .bmiHeader = .{ .biWidth = j.largura, .biHeight = -@as(i32, j.altura) } };
        _ = SetDIBitsToDevice(dc, 0, 0, j.largura, j.altura, 0, 0, 0, j.altura, px.ptr, &bi, 0);
    }

    pub fn proximo(j: *Janela, bloquear: bool) !?Evento {
        j.ligar();
        while (true) {
            if (j.tirar()) |e| return e;
            var m: MSG = undefined;
            if (bloquear) {
                if (GetMessageW(&m, null, 0, 0) <= 0) return .fechar;
            } else if (PeekMessageW(&m, null, 0, 0, PM_REMOVE) == 0) return null;
            _ = TranslateMessage(&m);
            _ = DispatchMessageW(&m);
        }
    }

    pub fn esperar(j: *Janela, ms: i32) bool {
        j.ligar();
        if (j.n > 0) return true;
        return MsgWaitForMultipleObjects(0, null, 0, @intCast(@max(ms, 0)), QS_ALLINPUT) == 0;
    }

    /// `codigo` aqui é a tecla virtual do Windows (VK_*); devolve o mesmo
    /// símbolo que o X11 daria (keysym), que é o que o programa entende.
    pub fn simbolo(_: *const Janela, codigo: u8, estado: u16) u32 {
        const shift = estado & 1 != 0;
        return switch (codigo) {
            'A'...'Z' => if (shift) codigo else codigo + 32,
            '0'...'9' => codigo,
            0x20 => ' ',
            0x1B => 0xff1b, // Esc
            0x21 => 0xff55, // Page Up
            0x22 => 0xff56, // Page Down
            0x25 => 0xff51, // ←
            0x26 => 0xff52, // ↑
            0x27 => 0xff53, // →
            0x28 => 0xff54, // ↓
            0x71 => 0xffbf, // F2
            0x6B => '+',
            0x6D => '-',
            0x60...0x69 => '0' + @as(u32, codigo - 0x60), // teclado numérico
            else => blk: {
                // Teclas de pontuação dependem do layout: o Windows diz qual é.
                const c = MapVirtualKeyW(codigo, 2) & 0x7fff;
                break :blk if (c >= 0x20 and c < 0x7f) c else 0;
            },
        };
    }
};

fn estadoAtual() u16 {
    var e: u16 = 0;
    if (GetKeyState(0x10) < 0) e |= 1; // Shift
    if (GetKeyState(0x11) < 0) e |= 4; // Ctrl
    return e;
}

fn procedimento(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    const j = Janela.atual orelse return DefWindowProcW(hwnd, msg, wp, lp);
    const x: i16 = @truncate(lp);
    const y: i16 = @truncate(lp >> 16);
    switch (msg) {
        WM_CLOSE, WM_DESTROY => j.empurrar(.fechar),
        WM_SIZE => {
            const w: u16 = @truncate(@as(usize, @bitCast(lp)));
            const h: u16 = @truncate(@as(usize, @bitCast(lp)) >> 16);
            if (w > 0 and h > 0) j.empurrar(.{ .redimensionar = .{ .largura = w, .altura = h } });
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            if (BeginPaint(hwnd, &ps)) |dc| j.copiar(dc);
            _ = EndPaint(hwnd, &ps);
            j.empurrar(.expor);
        },
        WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => {
            if (msg == WM_SYSKEYDOWN and wp == 0x73) return DefWindowProcW(hwnd, msg, wp, lp); // Alt+F4
            j.empurrar(.{ .tecla = .{ .codigo = @truncate(wp), .apertou = msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN, .estado = estadoAtual() } });
        },
        WM_MOUSEMOVE => {
            j.mx = x;
            j.my = y;
            j.empurrar(.{ .movimento = .{ .x = x, .y = y } });
        },
        WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN => {
            _ = SetCapture(hwnd);
            const n: u8 = if (msg == WM_LBUTTONDOWN) 1 else if (msg == WM_MBUTTONDOWN) 2 else 3;
            j.empurrar(.{ .botao = .{ .numero = n, .apertou = true, .x = x, .y = y, .estado = estadoAtual() } });
        },
        WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP => {
            _ = ReleaseCapture();
            const n: u8 = if (msg == WM_LBUTTONUP) 1 else if (msg == WM_MBUTTONUP) 2 else 3;
            j.empurrar(.{ .botao = .{ .numero = n, .apertou = false, .x = x, .y = y, .estado = estadoAtual() } });
        },
        WM_MOUSEWHEEL => {
            // Como no X11: rodinha pra cima é o botão 4, pra baixo o 5.
            // A posição vem em coordenadas da tela; usa a última conhecida.
            const giro: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const n: u8 = if (giro > 0) 4 else 5;
            const mx = j.mx;
            const my = j.my;
            j.empurrar(.{ .botao = .{ .numero = n, .apertou = true, .x = mx, .y = my, .estado = estadoAtual() } });
            j.empurrar(.{ .botao = .{ .numero = n, .apertou = false, .x = mx, .y = my, .estado = estadoAtual() } });
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    return 0;
}

const testing = std.testing;

test "Win32: teclas e mouse passam pela fila do Windows e viram os mesmos eventos do X11" {
    var j = try Janela.abrir(testing.allocator, {}, "teste", 320, 200);
    defer j.fechar();
    // Esvazia o que o sistema manda ao mostrar a janela (tamanho, pintura).
    while (try j.proximo(false)) |_| {}

    _ = PostMessageW(j.hwnd, WM_KEYDOWN, 0x71, 0); // F2
    _ = PostMessageW(j.hwnd, WM_KEYDOWN, 'Q', 0);
    _ = PostMessageW(j.hwnd, WM_MOUSEMOVE, 0, (40 << 16) | 30);
    _ = PostMessageW(j.hwnd, WM_LBUTTONDOWN, 0, (40 << 16) | 30);
    _ = PostMessageW(j.hwnd, WM_MOUSEWHEEL, @as(usize, 120) << 16, 0);

    var teclas: [2]u32 = undefined;
    var nt: usize = 0;
    var clique = false;
    var rodinha: u8 = 0;
    var movimento = false;
    while (try j.proximo(false)) |e| switch (e) {
        .tecla => |t| if (t.apertou and nt < 2) {
            teclas[nt] = j.simbolo(t.codigo, t.estado);
            nt += 1;
        },
        .movimento => |m| movimento = m.x == 30 and m.y == 40,
        .botao => |b| {
            if (b.numero == 1 and b.apertou and b.x == 30 and b.y == 40) clique = true;
            if (b.numero == 4 and b.x == 30 and b.y == 40) rodinha += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), nt);
    try testing.expectEqual(@as(u32, 0xffbf), teclas[0]); // F2 -> keysym do X11
    try testing.expectEqual(@as(u32, 'q'), teclas[1]); // sem shift: minúscula
    try testing.expect(movimento);
    try testing.expect(clique);
    try testing.expectEqual(@as(u8, 2), rodinha); // aperta e solta, no lugar do mouse
}

test "Win32: mostrar não falha e a espera devolve quando o tempo acaba" {
    var j = try Janela.abrir(testing.allocator, {}, "teste", 64, 32);
    defer j.fechar();
    var px: [64 * 32]u32 = @splat(0xff6e56cf);
    try j.mostrar(&px, 64, 32);
    // Mensagens atrasadas do sistema podem chegar; depois delas, a espera
    // tem que acabar por tempo (é o que dá o ritmo da animação).
    var acabou = false;
    for (0..100) |_| {
        while (try j.proximo(false)) |_| {}
        if (!j.esperar(10)) {
            acabou = true;
            break;
        }
    }
    try testing.expect(acabou);
}
