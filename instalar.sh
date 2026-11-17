#!/bin/sh
# CG Interativa: instala no sistema (no seu usuário, sem sudo).
#   ./instalar.sh              instala em ~/.local  (ou PREFIX=/usr/local sudo -E ./instalar.sh)
#   ./instalar.sh --remover    desinstala
# Funciona na pasta do código-fonte (compila com o Zig 0.16) e na pasta do
# pacote pronto do GitHub Releases (só copia).
#
# Installs CG Interativa for your user (~/.local by default; set PREFIX to
# change). Use --uninstall to remove. Works from the source tree (builds
# with Zig 0.16) and from the prebuilt release package (just copies).
set -e
PREFIX="${PREFIX:-$HOME/.local}"
AQUI=$(cd "$(dirname "$0")" && pwd)
BIN="$PREFIX/bin/cg-interativa"
ATALHO="$PREFIX/share/applications/cg-interativa.desktop"
ICONE="$PREFIX/share/icons/hicolor/256x256/apps/cg-interativa.png"

case "$1" in
--remover | --uninstall)
	rm -f "$BIN" "$ATALHO" "$ICONE"
	echo "CG Interativa removida de $PREFIX / removed from $PREFIX"
	exit 0
	;;
esac

if [ -f "$AQUI/build.zig" ]; then
	if ! command -v zig >/dev/null 2>&1; then
		echo "Precisa do Zig 0.16 (https://ziglang.org/download/) ou use o pacote pronto do GitHub Releases."
		echo "Needs Zig 0.16 (https://ziglang.org/download/), or use the prebuilt package from GitHub Releases."
		exit 1
	fi
	(cd "$AQUI" && zig build -Doptimize=ReleaseFast --prefix "$PREFIX")
else
	install -Dm755 "$AQUI/bin/cg-interativa" "$BIN"
	install -Dm644 "$AQUI/share/icons/hicolor/256x256/apps/cg-interativa.png" "$ICONE"
	mkdir -p "$(dirname "$ATALHO")"
	sed "s|^Exec=.*|Exec=$BIN|" "$AQUI/share/applications/cg-interativa.desktop" >"$ATALHO"
	chmod 644 "$ATALHO"
fi
update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -q "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true

echo "CG Interativa instalada em / installed to: $BIN"
echo "Abra pelo menu de aplicativos ou rode / open it from the app menu or run: cg-interativa"
case ":$PATH:" in
*":$PREFIX/bin:"*) ;;
*) echo "Aviso / note: $PREFIX/bin não está no PATH / is not in your PATH." ;;
esac
