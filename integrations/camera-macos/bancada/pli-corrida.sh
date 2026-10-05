#!/usr/bin/env bash
# Uma corrida do A/B do PLI na perda, no MacBook, com perda **induzida de propósito**.
#
# ## Por que perda induzida, e não um rádio ruim
#
# O enlace que perde pacote de verdade nesta bancada é o de 2,4 GHz do A10s
# (`docs/anomalia-de-sequencia.md`), e ele não é desta frente. Esperar um rádio ruim também não
# serviria: as nove corridas de Wi-Fi daquele documento deram `15, 0, 76, 74, 174, 195, 0, 94, 382`
# anomalias — duas delas **zero**. Medir recuperação num gerador de perda que às vezes não perde é
# medir o azar do canal, não o conserto.
#
# ## Como a perda é feita, e por que ela é honesta
#
# `kill -STOP` no processo receptor. Enquanto ele está congelado, o buffer de recepção UDP do
# socket enche e **o kernel do macOS descarta** os datagramas que não cabem; ao `kill -CONT` o
# fluxo volta com um buraco de verdade na sequência RTP. Três coisas fazem disso uma medição e não
# um truque:
#
#   * quem descarta é o kernel, não código nosso — o `netstat -s -p udp` conta e o número aparece
#     no relatório de cada corrida, ao lado do `sequence_anomalies` do núcleo. Numa corrida de
#     ensaio de 2,5 s de congelamento os dois deram **258 e 257**;
#   * **nada** foi acrescentado ao caminho de produto: o descarte é um sinal do sistema operacional
#     contra o processo, e a casca não sabe que está sendo medida;
#   * é repetível: o mesmo congelamento produz o mesmo tamanho de buraco, dentro da variação do
#     agendador.
#
# O que ele **não** é: perda de rádio. O buraco daqui é um bloco contíguo, e a perda de Wi-Fi
# medida no A10s é uma rajada de ~36 posições algumas vezes por minuto. O que os dois têm em comum
# é o que o conserto vê — um buraco na sequência no meio do fluxo — e é só isso que esta bancada
# afirma reproduzir.
#
# ## Regra de rede desta frente
#
# Portas 7910–7919, `--sem-mdns` sempre, `display_name` prefixado por `pli-`. Duas outras frentes
# estão na mesma LAN e a contaminação de mDNS entre frentes já aconteceu duas vezes.
#
# uso: pli-corrida.sh <app> <porta> <rotulo> <congelar_ms> [intervalo_pli_ms] [segundos]
#   <app>  caminho do binário QuallCamera a medir (o de antes ou o de depois do conserto)
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROBE="$RAIZ/target/release/quall-probe"
CLIPE="${PLI_CLIPE:-/tmp/pli-clipe/sintetico.json}"
PIN=778899

app=${1:?caminho do binário QuallCamera}
porta=${2:?porta 7910-7919}
rotulo=${3:?rotulo da corrida}
congelar_ms=${4:?ms de congelamento (0 = corrida de controle)}
intervalo_ms=${5:-500}
segundos=${6:-28}
congelar_em=${PLI_CONGELAR_EM:-10}

saida=${PLI_SAIDA:-/tmp/pli}; mkdir -p "$saida"
base="$saida/$rotulo"

if [ "$porta" -lt 7910 ] || [ "$porta" -gt 7919 ]; then
  echo "porta $porta fora da faixa desta frente (7910-7919)" >&2; exit 2
fi
[ -x "$app" ] || { echo "não achei o binário: $app" >&2; exit 2; }
[ -f "$CLIPE" ] || { echo "não achei o clipe: $CLIPE (rode gerar-clipe)" >&2; exit 2; }

netstat -s -p udp > "$base.udp.antes" 2>&1

# --- emissor: a sonda, com o clipe sintético, em laço ------------------------------------------
# `emitir-video` atende PLI na hora (reenvia o último IDR do arquivo dentro da fatia de espera de
# 33 ms), que é o emissor "que atende na hora" do item 7 do `anomalia-de-sequencia.md`.
"$PROBE" emitir-video --entrada "$CLIPE" --porta "$porta" --nome pli-emissor \
  --pin $PIN --sem-mdns --repetir --track camera > "$base.emissor" 2>&1 &
pid_e=$!
for _ in $(seq 1 60); do grep -q "esperando um receptor" "$base.emissor" 2>/dev/null && break; sleep 0.5; done
if ! grep -q "esperando um receptor" "$base.emissor" 2>/dev/null; then
  echo "  emissor não subiu; ver $base.emissor" >&2; kill $pid_e 2>/dev/null; exit 1
fi

# --- receptor: a casca de produto do macOS, sem a câmera virtual --------------------------------
# `QUALL_SEM_CAMERA=1` exercita rede + decode e pula a câmera. É o mesmo `Receptor.swift` do
# produto: o que se mede aqui é a casca, não uma sonda parecida com ela.
QUALL_SEM_CAMERA=1 QUALL_PLI_INTERVALO_MS="$intervalo_ms" QUALL_PLI_PISO_CURTO_MS="$intervalo_ms" \
  "$app" receber --ip 127.0.0.1:"$porta" --pin $PIN --segundos "$segundos" \
  > "$base.receptor" 2>&1 &
pid_r=$!

sleep "$congelar_em"
if [ "$congelar_ms" -gt 0 ]; then
  kill -STOP $pid_r 2>/dev/null
  python3 -c "import time;time.sleep($congelar_ms/1000.0)"
  kill -CONT $pid_r 2>/dev/null
  echo "  congelado por ${congelar_ms} ms aos ${congelar_em}s"
fi

wait $pid_r
kill $pid_e 2>/dev/null; wait $pid_e 2>/dev/null
netstat -s -p udp > "$base.udp.depois" 2>&1

a=$(grep "full socket buffers" "$base.udp.antes" | tr -dc 0-9)
d=$(grep "full socket buffers" "$base.udp.depois" | tr -dc 0-9)
echo "### $rotulo  congelar=${congelar_ms}ms piso=${intervalo_ms}ms"
echo "  kernel descartou por buffer cheio: $((d - a)) datagramas"
grep -E "contadores do núcleo|PERDA:|recebidos=" "$base.receptor" | tail -3
grep -E "pedidos de IDR|IDR forçados|quadros enviados" "$base.emissor" | tail -3
