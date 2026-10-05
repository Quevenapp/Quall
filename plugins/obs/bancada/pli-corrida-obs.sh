#!/usr/bin/env bash
# O A/B do PLI na perda, com o **plugin de OBS** como receptor, no MacBook.
#
# É a casca que mais importa das três: é a que o produto usa para pôr o celular numa cena, e é a
# que o `anomalia-de-sequencia.md` flagrou parando de pedir IDR depois do primeiro quadro publicado
# e lendo `frames_dropped` só para escrever no diário.
#
# ## Duas mudanças temporárias, as duas com `trap`
#
# O `git log` deste repositório tem um commit inteiro sobre isto — "mudança temporária sem
# try/finally envenena o ajuste do usuário para sempre". Aqui as duas são:
#
#   * o **plugin instalado** é trocado pelo desta branch e devolvido no fim (o do usuário volta
#     byte a byte, de um `.quall-bak`);
#   * a **coleção de cenas** é criada pelo `montar-cena.py`, que já guarda a do usuário e a devolve
#     no `restaurar`.
#
# ## O que se mede, e onde
#
# O diário do OBS. O plugin escreve uma linha quando o núcleo perde quadro e outra a cada
# relatório; o instante da linha de perda contra o instante do IDR seguinte é o tempo sem
# referência. **Nenhuma captura de tela**: a `regras-de-frente.md` proíbe fotografar a tela do
# anfitrião, e aqui não há janela isolável — a testemunha é o contador e o diário, e este roteiro
# **não afirma** o que apareceu na tela.
#
# uso: pli-corrida-obs.sh <porta> <rotulo> <congelar_ms> [segundos]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RAIZ="$(cd ../../.. && pwd)"
PROBE="$RAIZ/target/release/quall-probe"
CLIPE="${PLI_CLIPE:-/tmp/pli-clipe/sintetico.json}"
PLUGIN_CONSTRUIDO="$RAIZ/plugins/obs/build/quall-obs.plugin"
DESTINO="$HOME/Library/Application Support/obs-studio/plugins"
DIARIOS="$HOME/Library/Application Support/obs-studio/logs"
PIN=778899

porta=${1:?porta 7910-7919}
rotulo=${2:?rotulo}
congelar_ms=${3:?ms de congelamento}
segundos=${4:-40}
congelar_em=${PLI_CONGELAR_EM:-16}

saida=${PLI_SAIDA:-/tmp/pli}; mkdir -p "$saida"
base="$saida/obs-$rotulo"

[ -d "$PLUGIN_CONSTRUIDO" ] || { echo "plugin não construído: rode plugins/obs/construir.sh" >&2; exit 2; }
pgrep -x OBS >/dev/null && { echo "o OBS já está aberto; feche antes" >&2; exit 2; }

restaurar() {
  osascript -e 'with timeout of 6 seconds
    quit app "OBS"
  end timeout' 2>/dev/null || true
  sleep 3
  pgrep -x OBS >/dev/null && kill -TERM "$(pgrep -x OBS)" 2>/dev/null
  python3 ./montar-cena.py restaurar >/dev/null 2>&1 || true
  rm -rf "$DESTINO/quall-obs.plugin"
  if [ -d "$DESTINO/quall-obs.plugin.quall-bak" ]; then
    mv "$DESTINO/quall-obs.plugin.quall-bak" "$DESTINO/quall-obs.plugin"
  fi
}
trap restaurar EXIT

# --- trocar o plugin ---------------------------------------------------------------------------
mkdir -p "$DESTINO"
rm -rf "$DESTINO/quall-obs.plugin.quall-bak"
[ -d "$DESTINO/quall-obs.plugin" ] && mv "$DESTINO/quall-obs.plugin" "$DESTINO/quall-obs.plugin.quall-bak"
cp -R "$PLUGIN_CONSTRUIDO" "$DESTINO/"
codesign --force --sign - --timestamp=none "$DESTINO/quall-obs.plugin" >/dev/null 2>&1 || true

python3 ./montar-cena.py montar "pli=127.0.0.1:$porta/$PIN" >/dev/null

# --- emissor -----------------------------------------------------------------------------------
"$PROBE" emitir-video --entrada "$CLIPE" --porta "$porta" --nome pli-emissor \
  --pin $PIN --sem-mdns --repetir --track camera > "$base.emissor" 2>&1 &
pid_e=$!
for _ in $(seq 1 60); do grep -q "esperando um receptor" "$base.emissor" 2>/dev/null && break; sleep 0.5; done
if ! grep -q "esperando um receptor" "$base.emissor" 2>/dev/null; then
  echo "  emissor não subiu; ver $base.emissor" >&2; kill $pid_e 2>/dev/null; exit 1
fi

netstat -s -p udp > "$base.udp.antes" 2>&1
open -a OBS
# Esperar o **processo**, não um relógio: a subida do OBS varia com o que ele carrega.
for _ in $(seq 1 60); do pgrep -x OBS >/dev/null && break; sleep 0.5; done
pid_obs=$(pgrep -x OBS | head -1)
[ -n "$pid_obs" ] || { echo "o OBS não subiu" >&2; kill $pid_e 2>/dev/null; exit 1; }
echo "  OBS pid $pid_obs"

sleep "$congelar_em"
if [ "$congelar_ms" -gt 0 ]; then
  kill -STOP "$pid_obs" 2>/dev/null
  python3 -c "import time;time.sleep($congelar_ms/1000.0)"
  kill -CONT "$pid_obs" 2>/dev/null
  echo "  OBS congelado por ${congelar_ms} ms"
fi
# **Nada de `$(( ))` aqui.** O instante do congelamento é fracionário de propósito — é assim que a
# fase dentro do GOP varre —, e a aritmética do bash é inteira: com `PLI_CONGELAR_EM=16.3` o
# `$((segundos - congelar_em))` não é 21,7, é erro, e a corrida terminava **no instante do
# congelamento**. Três corridas saíram com a linha de perda como última linha do diário e nenhuma
# linha de recuperação — o que parecia "o conserto não respondeu" e era o roteiro fechando cedo.
python3 -c "import time;time.sleep(max(0.0, $segundos - $congelar_em))"

diario=$(ls -t "$DIARIOS"/*.txt 2>/dev/null | head -1)
restaurar
trap - EXIT
kill $pid_e 2>/dev/null; wait $pid_e 2>/dev/null
netstat -s -p udp > "$base.udp.depois" 2>&1

a=$(grep "full socket buffers" "$base.udp.antes" | tr -dc 0-9)
d=$(grep "full socket buffers" "$base.udp.depois" | tr -dc 0-9)
cp "$diario" "$base.diario" 2>/dev/null
echo "### obs-$rotulo  congelar=${congelar_ms}ms"
echo "  kernel descartou por buffer cheio: $((d - a))"
echo "  diário: $base.diario"
grep -E "\[quall\]" "$base.diario" 2>/dev/null | grep -E "perdeu quadro|núcleo:|em curso|fim da sessão|primeira imagem" | tail -12
