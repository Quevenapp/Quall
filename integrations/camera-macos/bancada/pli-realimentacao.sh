#!/usr/bin/env bash
# Mede a **realimentação** do PLI: pedir IDR a cada perda pode ser pior que não pedir?
#
# ## A pergunta, e por que ela não é retórica
#
# O `anomalia-de-sequencia.md` diz que atender um PLI injeta um IDR inteiro em rajada no mesmo
# caminho que acabou de perder pacote — no fluxo de bancada dele, 95 pacotes seguidos num rádio que
# acabou de comer 36 — e registra que **isso não foi medido**. Se cada perda vira um pedido e cada
# pedido vira uma rajada, uma perda pode virar uma tempestade que se alimenta.
#
# ## O regime: várias perdas na mesma corrida
#
# Uma perda só não distingue política nenhuma: com o piso de 500 ms, um evento vira um pedido em
# qualquer configuração. Aqui a corrida leva **N buracos** espaçados, o que é a ordem de grandeza
# que o `anomalia-de-sequencia.md` mediu no A10s ("~36 posições por evento, alguns eventos por
# minuto"). O que se compara entre os braços é: quantos pedidos a política emitiu, quantos pacotes
# a mais isso injetou, e se os quadros entregues caíram.
#
# ## Uma tentativa que falhou, e o que ela ensinou
#
# A primeira versão deste roteiro tentava **saturar** o caminho: parar e soltar o receptor em pulsos
# de 150 ms, para ele consumir ~metade do que chegava e o buffer viver cheio. Deu **zero** descarte
# em 66 pulsos. O motivo é que o receptor é muito mais rápido que o fluxo: em cada janela solta ele
# esvazia o buffer inteiro em milissegundos, então "metade do tempo parado" não é "metade da
# vazão". Não dá para construir um caminho saturado deste jeito, e o registro fica aqui para
# ninguém tentar de novo.
#
# **Consequência para a leitura dos números:** esta bancada mede o **custo** da política (quantos
# pedidos, quantos pacotes a mais) e não a realimentação de rádio. Ver o relato.
#
# uso: pli-realimentacao.sh <app> <porta> <rotulo> <piso_ms> [buracos] [segundos]
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROBE="$RAIZ/target/release/quall-probe"
CLIPE="${PLI_CLIPE:-/tmp/pli-clipe/sintetico.json}"
PIN=778899

app=${1:?caminho do binário QuallCamera}
porta=${2:?porta 7910-7919}
rotulo=${3:?rotulo}
piso=${4:?piso de supressão em ms}
buracos=${5:-5}
segundos=${6:-45}
congelar_ms=${PLI_CONGELAR_MS:-2500}
primeiro=${PLI_PRIMEIRO:-7}
espaco=${PLI_ESPACO:-6}

saida=${PLI_SAIDA:-/tmp/pli}; mkdir -p "$saida"
base="$saida/rea-$rotulo"

netstat -s -p udp > "$base.udp.antes" 2>&1

"$PROBE" emitir-video --entrada "$CLIPE" --porta "$porta" --nome pli-emissor \
  --pin $PIN --sem-mdns --repetir --track camera > "$base.emissor" 2>&1 &
pid_e=$!
for _ in $(seq 1 60); do grep -q "esperando um receptor" "$base.emissor" 2>/dev/null && break; sleep 0.5; done
if ! grep -q "esperando um receptor" "$base.emissor" 2>/dev/null; then
  echo "  emissor não subiu; ver $base.emissor" >&2; kill $pid_e 2>/dev/null; exit 1
fi

QUALL_SEM_CAMERA=1 QUALL_PLI_INTERVALO_MS="$piso" QUALL_PLI_PISO_CURTO_MS="$piso" \
  "$app" receber --ip 127.0.0.1:"$porta" --pin $PIN --segundos "$segundos" \
  > "$base.receptor" 2>&1 &
pid_r=$!

sleep "$primeiro"
for _ in $(seq 1 "$buracos"); do
  kill -STOP $pid_r 2>/dev/null || break
  python3 -c "import time;time.sleep($congelar_ms/1000.0)"
  # **Sempre soltar.** Um receptor que fique parado nunca imprime o resultado e o lote pendura no
  # `wait`; e o processo sobreviveria à corrida, que é um defeito que esta bancada já registrou.
  kill -CONT $pid_r 2>/dev/null || break
  sleep "$espaco"
done

wait $pid_r
kill $pid_e 2>/dev/null; wait $pid_e 2>/dev/null
netstat -s -p udp > "$base.udp.depois" 2>&1

a=$(grep "full socket buffers" "$base.udp.antes" | tr -dc 0-9)
d=$(grep "full socket buffers" "$base.udp.depois" | tr -dc 0-9)
echo "### $rotulo  piso=${piso}ms  buracos=${buracos}x${congelar_ms}ms"
echo "  kernel descartou por buffer cheio: $((d - a))"
grep -E "PERDA:|contadores do núcleo" "$base.receptor" | tail -2
