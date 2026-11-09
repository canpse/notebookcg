# editor-cg

Editor de texto e imagens feito do zero em Zig, sem nenhuma biblioteca:
trabalho de Computação Gráfica (IFC, 2026.2).

"Do zero" aqui quer dizer que o programa abre a própria janela falando o
protocolo do X11 pelo socket e pinta cada pixel num vetor na memória.

    zig build run                 # abre o editor
    zig build run -- ~/fotos      # pasta onde o "+ Imagem" procura .ppm/.pgm
    zig build test    # roda os testes

Precisa de Zig 0.16 e de um servidor X (no Wayland, o XWayland serve).

## Como usar

Tudo que entra no documento começa escolhendo o **modelo** na barra de cima:
Desenho, Retângulo, Elipse, Texto ou Imagem (PPM/PGM, P2/P3/P5/P6, escolhida
numa lista dentro da janela com os arquivos da pasta e subpastas; imagem
grande entra reduzida pela matriz, sem perder pixel). Cada camada é um objeto:
o modelo (tipo + parâmetros) gera os pixels dela, e uma matriz própria diz
onde ela fica na folha. Mover, girar e escalar mudam só a matriz.

- barra de cima: `+ Modelo` cria o objeto no meio da tela; `Pincel` / `Mover` trocam o modo
- painel da direita: as camadas de cima pra baixo; clicar seleciona; `Subir`, `Descer`, `Apagar`
- **cor**: a paleta no painel troca a cor do objeto selecionado (num desenho, a cor do pincel)
- **texto**: um texto novo já nasce digitando (a primeira letra troca o "Texto" padrão); depois, clicar no campo TEXTO ou `Enter` volta a editar; `Enter`/`Esc` termina. Acentos pelo layout do sistema, com tecla morta (´ + a = á)
- modo **Pincel** (`b`): arrastar desenha; se a selecionada não for um desenho, cria um por cima
- modo **Mover** (`v`): clicar seleciona o objeto de cima que tem tinta ali; arrastar move. No selecionado aparecem as **alças**: cantos escalam mantendo a proporção (canto oposto parado), o meio dos lados estica só naquela direção (ao longo do objeto, mesmo girado), a bolinha de cima gira em torno do centro (`Shift`: de 15 em 15°). O fundo é travado (clicar no papel vazio não arrasta a folha)
- atalhos que fazem o mesmo: `q` / `e` gira 15°; `-` / `=` diminui / aumenta; `r` desfaz giro e escala (fica no lugar)
- `n`: desenho novo; `Tab`: próxima camada; `Page Up` / `Page Down`: sobe / desce; `Delete`: apaga; `c`: limpa o desenho
- rodinha: zoom da vista em torno do cursor; botão direito arrastando: move a vista; `Shift+q/e`: gira a vista; `0`: vista inicial
- `Esc`: sai

O `zig build run` compila em ReleaseFast (em Debug o redesenho engasga);
`-Doptimize=Debug` se precisar depurar.

## Onde está cada coisa

- `src/x11.zig`: a janela (conexão, eventos, envio dos pixels, tabela do teclado)
- `src/tela.zig`: o vetor de pixels e os desenhos básicos (ponto, disco, linha de Bresenham)
- `src/mat3.zig`: matriz 3×3 em coordenadas homogêneas (translação, escala, rotação, composição em torno de um ponto, inversa)
- `src/tela.zig`: também a amostragem bilinear com alfa pré-multiplicado e a composição "por cima" por mapeamento inverso
- `src/camada.zig`: modelos (desenho, retângulo, elipse, texto) e `gerar` (modelo → pixels); camadas e documento: seleção por clique (inversa de vista·camada), transformar em coordenadas da janela (`vista⁻¹·g·vista·camada`), pintar de baixo pra cima (algoritmo do pintor) e contorno
- `src/fonte.zig`: texto com fonte bitmap 8×16 (carimba a grade de bits de cada letra; lê UTF-8)
- `src/fonte_dados.zig`: os glifos (ASCII + Latin-1), gerados por `ferramentas/fonte_psf.py` a partir da fonte de console `eurlatgr` do pacote kbd do Linux (GPL)
- `src/ppm.zig`: leitura de PPM/PGM em texto e binário
- `src/arquivos.zig`: lista de imagens da pasta (pra escolher dentro da janela)
- `src/digitar.zig`: de tecla a letra (keysym → Unicode, tecla morta + letra = letra acentuada)
- `src/alcas.zig`: alças de transformação (escala na coordenada da camada: `matriz·T(âncora)·S·T(−âncora)`; giro na janela em torno do centro)
- `src/ui.zig`: menus dentro da janela (barra, painel de camadas, rodapé); o mesmo layout desenha e responde ao clique
- `src/main.zig`: o laço principal (teclas, mouse, modos)
