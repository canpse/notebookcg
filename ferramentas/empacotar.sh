#!/bin/sh
# Gera os pacotes binários pro GitHub Releases em dist/:
#   ferramentas/empacotar.sh 1.0.0
# Cada pacote tem bin/, share/ (atalho e ícone), instalar.sh, LICENSE e README.
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
(cd dist && sha256sum ./*.tar.gz >SHA256SUMS)
ls -l dist
