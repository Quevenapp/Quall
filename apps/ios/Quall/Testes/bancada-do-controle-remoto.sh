#!/bin/zsh
# **A bancada do controle remoto da câmera (R9b), no MacBook, em 127.0.0.1 e sem câmera.**
#
# `docs/controle-remoto-da-camera.md` §12: os embrulhos de verdade do iOS (`FilmadorRemoto` e
# `CameraRemotaDaSessao`, `App/CameraRemota.swift`) e as regras puras (`RegrasDoControleRemoto`)
# contra o núcleo de verdade, numa sessão de vídeo hospedar/conectar sem track, sem aparelho. A câmera
# do filmador é imaginária (o registro e o lido são do programa). Prova o caminho de mensagens do
# iOS: o núcleo aceita as capacidades do iOS, o receptor fica pronto e desenha o molde do iOS, o
# pedido volta aplicado com o autor e o "Controlado por", o lido e o toque atravessam, a opção
# desligada dá `nao_permitido` e a câmera fechada dá `sem_camera`. **Não prova** a câmera nem a tela:
# isso é a prova em aparelho.
#
# Compila o núcleo para o Mac (`cargo build -p quall-ffi --release --offline`, em `target/`), e o
# programa a partir de `BancadaDoControleRemoto.swift` (que vira o `main.swift` dele) com os arquivos
# do app que ele exercita. Fora do `rodar.sh` porque compila o núcleo (minutos na primeira vez).
set -eu
AQUI=${0:A:h}
Q="$AQUI/.."
RAIZ="$AQUI/../../../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

( cd "$RAIZ" && cargo build -p quall-ffi --release --offline -q )
cp "$AQUI/BancadaDoControleRemoto.swift" "$TMP/main.swift"
swiftc -O -import-objc-header "$AQUI/PonteDaBancadaDoControleRemoto.h" -I "$RAIZ/crates/quall-ffi/include" \
  "$Q/Comum/Idioma.swift" \
  "$Q/App/RegrasDosControles.swift" \
  "$Q/App/RegrasDoControleRemoto.swift" \
  "$Q/App/CameraRemota.swift" \
  "$TMP/main.swift" \
  "$RAIZ/target/release/libquall.a" -lc++ \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -o "$TMP/bancada" 2> "$TMP/compilacao.txt" || { cat "$TMP/compilacao.txt"; echo "!! não compilou"; exit 1; }
"$TMP/bancada"
