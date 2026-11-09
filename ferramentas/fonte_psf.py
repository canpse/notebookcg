"""Converte uma fonte de console PSF1 (com tabela Unicode) em src/fonte_dados.zig.

Uso: python3 ferramentas/fonte_psf.py /usr/lib/kbd/consolefonts/eurlatgr.psfu.gz

Gera os glifos dos códigos 32 a 255 (ASCII + Latin-1, que tem todos os acentos
do português). Cada glifo é 16 bytes, um por linha; o bit mais alto é o pixel
da esquerda.
"""
import gzip, sys

caminho = sys.argv[1]
dados = (gzip.open if caminho.endswith('.gz') else open)(caminho, 'rb').read()
assert dados[:2] == b'\x36\x04', 'não é PSF1'
modo, altura = dados[2], dados[3]
n = 512 if modo & 1 else 256
assert modo & 2, 'a fonte não tem tabela Unicode'
glifos = [dados[4 + i * altura: 4 + (i + 1) * altura] for i in range(n)]

# Tabela Unicode: pra cada glifo, códigos u16 até 0xFFFF (0xFFFE começa sequências, ignoradas).
unicode = {}
pos = 4 + n * altura
for g in range(n):
    em_sequencia = False
    while True:
        c = dados[pos] | dados[pos + 1] << 8
        pos += 2
        if c == 0xFFFF:
            break
        if c == 0xFFFE:
            em_sequencia = True
        elif not em_sequencia:
            unicode.setdefault(c, g)

interrogacao = glifos[unicode[ord('?')]]
linhas = []
faltando = []
for c in range(32, 256):
    if c in unicode:
        g = glifos[unicode[c]]
    else:
        g = interrogacao
        faltando.append(c)
    bytes_ = ', '.join(f'0x{b:02x}' for b in g)
    rotulo = chr(c) if c != 0x7f and not 0x80 <= c < 0xa0 else f'U+{c:04X}'
    linhas.append(f'    .{{ {bytes_} }}, // {c} {rotulo}')

nome = caminho.rsplit('/', 1)[-1]
saida = f"""//! Gerado por ferramentas/fonte_psf.py a partir de {nome} (fonte de console
//! do Linux, pacote kbd; licença GPL). Não editar à mão.
pub const largura = 8;
pub const altura = {altura};
pub const primeiro = 32;

/// Glifos dos códigos {32} a 255; cada byte é uma linha, bit mais alto à esquerda.
pub const glifos = [_][altura]u8{{
{chr(10).join(linhas)}
}};
"""
open('src/fonte_dados.zig', 'w').write(saida)
print(f'{len(linhas)} glifos, altura {altura}; sem glifo (virou ?): {faltando}')
