# editor-cg

Editor de texto e imagens feito do zero em Zig, sem nenhuma biblioteca:
trabalho de Computação Gráfica (IFC, 2026.2).

"Do zero" aqui quer dizer que o programa abre a própria janela falando o
protocolo do X11 pelo socket e pinta cada pixel num vetor na memória.

    zig build run     # abre o editor
    zig build test    # roda os testes

Precisa de Zig 0.16 e de um servidor X (no Wayland, o XWayland serve).

## Como usar

- arrastar com o botão esquerdo: desenha
- `c`: limpa
- `Esc`: sai

## Onde está cada coisa

- `src/x11.zig`: a janela (conexão, eventos, envio dos pixels)
- `src/tela.zig`: o vetor de pixels e os desenhos básicos (ponto, disco, linha de Bresenham)
- `src/main.zig`: o laço principal
