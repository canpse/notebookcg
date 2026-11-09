# editor-cg

Editor de texto e imagens feito do zero em Zig, sem nenhuma biblioteca:
trabalho de Computação Gráfica (IFC, 2026.2).

"Do zero" aqui quer dizer que o programa abre a própria janela falando o
protocolo do X11 pelo socket e pinta cada pixel num vetor na memória.

    zig build run     # abre o editor
    zig build test    # roda os testes

Precisa de Zig 0.16 e de um servidor X (no Wayland, o XWayland serve).

## Como usar

Cada camada é um objeto: tem os próprios pixels (com transparência) e a
própria matriz. Mover, girar e escalar mudam só a matriz.

- `b`: modo pincel (arrastar com o esquerdo desenha na camada selecionada)
- `v`: modo mover (clicar seleciona a camada de cima que tem tinta ali; arrastar move; contorno azul na selecionada)
- `q` / `e`: gira a camada selecionada 15° em torno do centro dela
- `-` / `=`: diminui / aumenta a camada selecionada
- `r`: desfaz as transformações da camada
- `n`: camada nova acima da selecionada
- `Tab` / `Shift+Tab`: seleciona a próxima / anterior
- `Page Up` / `Page Down`: sobe / desce a camada na pilha
- `Delete`: apaga a camada
- `c`: limpa a camada
- rodinha: zoom da vista em torno do cursor; botão direito arrastando: move a vista; `Shift+q/e`: gira a vista; `0`: vista normal
- `Esc`: sai

A barra no rodapé mostra o modo e qual camada está selecionada.

O `zig build run` compila em ReleaseFast (em Debug o redesenho engasga);
`-Doptimize=Debug` se precisar depurar.

## Onde está cada coisa

- `src/x11.zig`: a janela (conexão, eventos, envio dos pixels)
- `src/tela.zig`: o vetor de pixels e os desenhos básicos (ponto, disco, linha de Bresenham)
- `src/mat3.zig`: matriz 3×3 em coordenadas homogêneas (translação, escala, rotação, composição em torno de um ponto, inversa)
- `src/tela.zig`: também a amostragem bilinear com alfa pré-multiplicado e a composição "por cima" por mapeamento inverso
- `src/camada.zig`: camadas e documento: seleção por clique (inversa de vista·camada), transformar em coordenadas da janela (`vista⁻¹·g·vista·camada`), pintar de baixo pra cima (algoritmo do pintor) e contorno
- `src/fonte.zig`: texto com fonte bitmap 8×16 (carimba a grade de bits de cada letra; lê UTF-8)
- `src/fonte_dados.zig`: os glifos (ASCII + Latin-1), gerados por `ferramentas/fonte_psf.py` a partir da fonte de console `eurlatgr` do pacote kbd do Linux (GPL)
- `src/main.zig`: o laço principal (teclas, mouse, modos, barra de estado)
