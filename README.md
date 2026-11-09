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
- arrastar com o botão direito: move a folha
- rodinha: zoom em torno do cursor
- `q` / `e`: gira 15° pra um lado ou pro outro (em torno do centro da janela)
- `0`: volta a vista ao normal
- `c`: limpa
- `Esc`: sai

O `zig build run` compila em ReleaseFast (em Debug o redesenho engasga);
`-Doptimize=Debug` se precisar depurar.

## Onde está cada coisa

- `src/x11.zig`: a janela (conexão, eventos, envio dos pixels)
- `src/tela.zig`: o vetor de pixels e os desenhos básicos (ponto, disco, linha de Bresenham)
- `src/mat3.zig`: matriz 3×3 em coordenadas homogêneas (translação, escala, rotação, composição em torno de um ponto, inversa)
- `src/tela.zig`: também a amostragem bilinear e o desenho transformado por mapeamento inverso
- `src/main.zig`: o laço principal. O desenho mora numa folha; a janela mostra a folha pela matriz `vista`, e o mouse volta pela inversa
