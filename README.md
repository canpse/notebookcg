# CG Interativa

![CG Interativa](docs/prints/aulas/a3.png)

**[Português](#português) · [English](#english)**

## Português

Software educacional de Computação Gráfica: **9 aulas interativas**, uma por
tópico da ementa da disciplina. Em cada aula você mexe na cena com o mouse e o
teclado, e o painel da direita mostra, ao vivo, os números por trás da imagem
(matrizes, códigos de região, profundidade, a conta da iluminação).
Interface em português e inglês (`F2` ou o botão PT/EN).

Tudo feito do zero em [Zig](https://ziglang.org), **sem biblioteca gráfica**:
a janela fala o protocolo do X11 pelo socket, cada pixel é escrito num vetor
na memória e o 3D tem rasterizador de triângulos com z-buffer próprio. O
programa é, ele mesmo, um exemplo do que ensina.

| | Aula | O que mostra |
|---|---|---|
| 1 | Framebuffer e pixels | matriz de pixels, índice y·largura+x, RGB, tamanho real |
| 2 | Rasterização de retas | DDA, Bresenham (tabela do erro), antialiasing |
| 3 | Transformações 2D | S, R, T e M = T·R·S ao vivo; ordem; giro no centro |
| 4 | Janela → viewport | mundo × tela, sx/sy, distorção |
| 5 | Recorte de retas | Cohen-Sutherland com códigos de 4 bits e passos |
| 6 | Projeção 3D | pipeline de um vértice (mundo, câmera, clip, ÷w, tela), perspectiva × ortográfica, vista de cima |
| 7 | Superfícies ocultas | sem remoção, faces de trás, pintor, z-buffer (e ver o z-buffer) |
| 8 | Iluminação e shading | modelo de Phong: flat, Gouraud, Phong; a conta no pixel do mouse |
| 9 | Animação | grafo de cena Sol-Terra-Lua, quadros-chave e curvas de tempo |

### Instalar

Precisa de Linux com X11 (no Wayland, o XWayland serve; é o padrão no GNOME e no KDE).

**Pacote pronto** (sem compilar): baixe o `.tar.gz` da sua arquitetura em
[Releases](../../releases), extraia e rode o instalador:

    tar xzf cg-interativa-1.0.0-x86_64-linux.tar.gz
    cd cg-interativa-1.0.0-x86_64-linux
    ./instalar.sh            # instala em ~/.local, sem sudo

**Do código** (precisa do [Zig 0.16](https://ziglang.org/download/)):

    git clone https://github.com/canpse/notebookcg && cd notebookcg
    ./instalar.sh            # ou: zig build -Doptimize=ReleaseFast --prefix ~/.local

Depois é só abrir **CG Interativa** no menu de aplicativos, ou rodar
`cg-interativa` (`cg-interativa 7` abre direto na aula 7; `--en`/`--pt`
escolhem o idioma). Pra instalar pra todos os usuários:
`sudo PREFIX=/usr/local ./instalar.sh`. Pra remover: `./instalar.sh --remover`.

### Desenvolver

    zig build run -- 5       # compila e abre na aula 5
    zig build test           # testes
    ferramentas/empacotar.sh 1.0.0   # pacotes do release em dist/

As aulas estão em `src/aulas.zig`; o 3D (Mat4, malhas, rasterizador) em
`src/tres_d.zig`; a janela em `src/x11.zig`; o framebuffer e as primitivas em
`src/tela.zig`; a matriz 3×3 em `src/mat3.zig`. Pra gerar prints sem mexer no
mouse: `CG_PRINT=saida.ppm CG_MOUSE=x,y CG_TECLAS=mm CG_LANG=en zig-out/bin/cg-interativa N`.

## English

Educational computer graphics software: **9 interactive lessons**, one per
topic of a typical CG course. In each lesson you manipulate the scene with
the mouse and keyboard while the side panel shows, live, the numbers behind
the image (matrices, region codes, depth, the lighting equation).
The interface is in Portuguese and English (press `F2` or click PT/EN; it
starts in the language of `$LANG`).

Written from scratch in [Zig](https://ziglang.org) with **no graphics
library**: the window speaks the X11 protocol over its socket, every pixel is
written to an array in memory, and the 3D part has its own triangle
rasterizer with a z-buffer.

Lessons: framebuffer and pixels · line rasterization (DDA, Bresenham,
antialiasing) · 2D transforms with homogeneous matrices · window-to-viewport ·
Cohen-Sutherland clipping · 3D projection (perspective/orthographic, with the
full pipeline of one vertex) · hidden surfaces (none, back-face culling,
painter's, z-buffer) · Phong lighting (flat, Gouraud, Phong) · animation
(scene graph and easing curves).

### Install

Requires Linux with X11 (XWayland works on Wayland desktops).

**Prebuilt package**: download the `.tar.gz` for your architecture from
[Releases](../../releases), extract it and run `./instalar.sh` (installs to
`~/.local`, no sudo). **From source** (needs [Zig 0.16](https://ziglang.org/download/)):
clone and run `./instalar.sh`, or `zig build -Doptimize=ReleaseFast --prefix ~/.local`.
Then open **CG Interativa** from your app menu or run `cg-interativa`
(`cg-interativa 7 --en` opens lesson 7 in English). Remove with
`./instalar.sh --uninstall`.

## Licença / License

GPL-3.0-or-later ([LICENSE](LICENSE)). A fonte bitmap vem da fonte de console
`eurlatgr` do projeto kbd (GPL). / The bitmap font comes from the `eurlatgr`
console font of the kbd project (GPL).

Trabalho da disciplina de Computação Gráfica, Ciência da Computação, IFC
Campus Rio do Sul, 2026. / Computer Graphics course project, IFC, Brazil, 2026.

---

O repositório também tem o quadro de desenho que veio antes (mesma base):
`zig build editor`. O resto deste arquivo é sobre ele.

# Quadro de desenho (editor-cg)

Um quadro infinito pra rabiscar rápido, onde **qualquer pedaço vira imagem
num gesto**: você arrasta a ferramenta Recorte sobre uma região e ela já
está na área de transferência (Ctrl+V em qualquer programa) e salva em PNG.

É diferente de uma ferramenta de captura de tela: o recorte não é uma foto do
que aparece, ele é **gerado de novo a partir do modelo** (os pontos do traço,
o tamanho do retângulo, o texto), na escala que você escolher (1× a 4×). Por
isso sai nítido, sem menu nem alça por cima, e a região fica marcada no
quadro como moldura: mexeu no desenho, recorta de novo com um clique.

Feito do zero em Zig, sem nenhuma biblioteca: trabalho de Computação
Gráfica (IFC, 2026.2). A janela fala o protocolo do X11 pelo socket, cada
pixel é pintado num vetor na memória, e até o PNG (com o compressor deflate)
é escrito aqui.

    zig build run                      # abre o editor (pasta atual)
    zig build run -- ~/desenhos        # pasta dos recortes, quadros e imagens
    zig build run -- aula.quadro       # abre um quadro salvo
    zig build test                     # roda os testes

Precisa de Zig 0.16 e de um servidor X (no Wayland, o XWayland serve, e o
recorte copiado aparece pros programas Wayland também).

![formas](docs/prints/quadro-formas-2026-11-09.png)

## Como usar

Ferramentas na barra de cima, cada uma com a sua tecla (como no Excalidraw):

| Tecla | Ferramenta | |
|---|---|---|
| `V` | Seleção | clique seleciona, `Shift` soma; arrastar no vazio seleciona uma área; dois cliques no vazio criam texto, num texto editam |
| `P` | Pincel | cada traço é um objeto, suavizado ao soltar |
| `L` / `A` | Linha / Seta | da ponta à ponta; `Shift` prende de 15 em 15° |
| `R` / `O` | Retângulo / Elipse | arraste o tamanho; `Shift` faz quadrado / círculo |
| `T` | Texto | clique e digite (acentos pelo layout do sistema); `Enter` termina |
| `E` | Borracha | apaga o objeto que o mouse tocar |
| `C` | Recorte | arraste a região: vira moldura, PNG copiado e salvo como `recorte-N.png` |
| `I` | Imagem | abre um PPM/PGM da pasta (lista dentro da janela) |

- **painel da direita**: cor, fundo (retângulo e elipse), espessura, traço
  liso ou **à mão**, tamanho do texto. Com algo selecionado, muda o
  selecionado; sem nada, muda como a ferramenta vai criar
- **moldura selecionada**: escala do recorte (1× a 4×), `Copiar PNG` (ou
  `Enter`) e `Salvar PPM`
- **alças** na seleção: cantos escalam com proporção (`Shift`: livre), o meio
  dos lados estica, a bolinha gira (`Shift`: de 15 em 15°). Com vários
  selecionados, a caixa é a de todos e transforma todos juntos
- `Ctrl+Z` / `Ctrl+Y` (ou `Ctrl+Shift+Z`): desfazer / refazer
- `Ctrl+C`: copia a seleção como imagem (só ela, sem o que está em volta)
- `Ctrl+D`: duplica; `Ctrl+A`: seleciona tudo; `Ctrl+G` / `Ctrl+Shift+G`: agrupa / desagrupa
- `Delete`: apaga; `Page Up` / `Page Down`: sobe / desce na pilha; setas: empurram 1 (`Shift`: 10)
- `Ctrl+S`: salva o quadro (`quadro-N.quadro` na pasta, ou o que estiver aberto); `Ctrl+O` / `Abrir`: abre
- vista: rodinha dá zoom em torno do cursor; botão direito, do meio ou
  `espaço` + arrastar andam; `Shift+Q` / `Shift+E` giram; `0` volta pra 100%;
  `1` enquadra tudo; `-` / `=` zoom

O `zig build run` compila em ReleaseFast (em Debug o redesenho engasga);
`-Doptimize=Debug` se precisar depurar.

## A computação gráfica por trás

- **modelo → imagem**: nada é guardado em pixels, a não ser as fotos
  importadas e o texto (a fonte é bitmap). Traço é uma lista de pontos,
  retângulo é largura × altura. Cada quadro é pintado de novo a partir disso,
  na resolução da tela ou do recorte
- **coordenadas homogêneas**: cada objeto tem uma matriz 3×3 (objeto → mundo);
  a vista é outra (mundo → tela). Arrastar na tela com a vista girada e com
  zoom: `nova = vista⁻¹ · g · vista · antiga`
- **recorte**: `mundo → imagem = S(escala) · região⁻¹`, a mesma pintura com
  outra matriz
- **traço suave (antialiasing)**: a cobertura de cada pixel vem da distância
  do centro dele ao segmento; uma máscara guarda o máximo, pra borda não
  escurecer onde os segmentos se sobrepõem
- **retângulo e elipse por mapeamento inverso** com **função de distância com
  sinal**: dentro, borda e "perto da borda" (pro clique) são uma conta só
- **suavização de Chaikin** no pincel (cortar cantos converge pra uma
  B-spline quadrática)
- **estilo à mão**: duas passadas tortas por *value noise* com semente fixa
- **algoritmo do pintor**, composição "por cima" com alfa pré-multiplicado,
  interpolação bilinear nas imagens, Bresenham nas linhas da interface
- **descarte**: objeto cuja caixa cai fora da tela nem é pintado

## Onde está cada coisa

- `src/x11.zig`: a janela (conexão, eventos, envio dos pixels, tabela do teclado) e a área de transferência (dono do CLIPBOARD, responde TARGETS e image/png; BIG-REQUESTS pra imagem grande)
- `src/tela.zig`: o vetor de pixels; ponto, disco, Bresenham, traço suave com máscara, tracejado, bilinear e composição por mapeamento inverso
- `src/mat3.zig`: matriz 3×3 em coordenadas homogêneas (translação, escala, rotação, composição em torno de um ponto, inversa, fator de escala)
- `src/camada.zig`: os modelos (traço, linha, seta, retângulo, elipse, texto, imagem, moldura), como cada um se pinta e responde ao clique, estilo à mão, Chaikin; o documento: seleção, grupos, pilha, arrasto, desfazer/refazer (fotos do quadro) e o recorte
- `src/alcas.zig`: alças (referencial da caixa `m`; o arrasto vira `m · g · m⁻¹` na tela)
- `src/png.zig`: gravação de PNG com filtros por linha (Sub, Up, Paeth) e deflate próprio (LZ77 com cadeia de hash + Huffman fixo)
- `src/quadro.zig`: o arquivo `.quadro` (o modelo em texto)
- `src/ppm.zig`: leitura de PPM/PGM em texto e binário; gravação em P3
- `src/fonte.zig` e `src/fonte_dados.zig`: fonte bitmap 8×16 (ASCII + Latin-1), gerada por `ferramentas/fonte_psf.py` da fonte de console `eurlatgr` do kbd (GPL)
- `src/digitar.zig`: de tecla a letra (keysym → Unicode, tecla morta + letra)
- `src/arquivos.zig`: lista de arquivos da pasta (pra escolher dentro da janela)
- `src/ui.zig`: barra de ferramentas, painel de propriedades e camadas, rodapé, lista de arquivos; o mesmo layout desenha e responde ao clique
- `src/main.zig`: o editor (ferramentas, gestos do mouse, atalhos, recorte, arquivos)

![recorte](docs/prints/quadro-moldura-2026-11-09.png)
