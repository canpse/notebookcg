#!/bin/sh
# Gera os pacotes binários pro GitHub Releases em dist/:
#   ferramentas/empacotar.sh 1.0.0
# Linux: bin/, share/ (atalho e ícone), instalar.sh, LICENSE e README.
# Windows: cg-interativa.exe, instalar.bat, LICENSE.txt e README.
set -e
VERSAO="${1:?uso: empacotar.sh VERSAO}"
cd "$(dirname "$0")/.."
rm -rf dist && mkdir -p dist
for ALVO in x86_64-linux aarch64-linux; do
	NOME="cg-interativa-$VERSAO-$ALVO"
	zig build -Doptimize=ReleaseFast -Dtarget="$ALVO" --prefix "dist/$NOME"
	cp instalar.sh LICENSE README.md "dist/$NOME/"
	tar -C dist -czf "dist/$NOME.tar.gz" "$NOME"
	rm -rf "dist/$NOME"
done
# Windows: o .exe roda sozinho (dois cliques); instalar.bat põe no Menu Iniciar.
NOME="cg-interativa-$VERSAO-x86_64-windows"
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows --prefix "dist/$NOME"
mv "dist/$NOME/bin/cg-interativa.exe" "dist/$NOME/"
rm -rf "dist/$NOME/bin"
cp windows/instalar.bat README.md "dist/$NOME/"
cp LICENSE "dist/$NOME/LICENSE.txt"
python3 -c "import shutil,sys; shutil.make_archive(sys.argv[1], 'zip', 'dist', sys.argv[2])" "dist/$NOME" "$NOME"
rm -rf "dist/$NOME"
(cd dist && sha256sum ./*.tar.gz ./*.zip >SHA256SUMS)
ls -l dist
