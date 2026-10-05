#!/usr/bin/env bash
# O lote do A/B: N pares de corridas, **intercalados**, para que os braços compartilhem as mesmas
# condições de máquina. O `anomalia-de-sequencia.md` mostra por que isso não é zelo: no lote dele a
# subida piorou de mediana 214 para 379 ao longo de meia hora de medição, e um braço medido inteiro
# antes do outro teria trocado o conserto pela hora do dia.
#
# Os dois braços são o **mesmo binário** e o **mesmo caminho de código**. O que muda é o piso de
# supressão: um piso maior que a corrida inteira é o limite natural da política — a casca sonda,
# detecta e mede exatamente igual, e nunca pede. Não há chave de "desligar o conserto".
#
# ## A varredura de fase, e a armadilha que ela conserta
#
# O primeiro lote deste A/B congelou sempre aos 10,0 s e saiu com o braço "sem conserto" em
# 903 · 531 · 514 · 512 · 552 ms. Quatro dos cinco números praticamente iguais **não é** a
# distribuição de "quanto tempo até o próximo IDR programado": é fase travada. O emissor da sonda
# começa o arquivo quando o receptor conecta, o GOP tem 2,000 s e o congelamento tem 2,500 s — o
# buraco caía sempre a 500 ms do IDR seguinte. O número certo é **uniforme em [0, GOP]**, e medir
# um ponto dele cinco vezes não é medir cinco vezes.
#
# Aqui o instante do congelamento anda em passos de GOP/N ao longo de uma volta inteira do GOP, o
# que cobre a fase por construção em vez de por sorte. Com 8 pares e GOP de 2 s, os passos são de
# 250 ms.
#
# uso: pli-lote.sh <app> <pares> [congelar_ms] [piso_com_ms] [gop_s]
set -uo pipefail
# O caminho do app vira absoluto **antes** do `cd`: com caminho relativo o `cd` daqui já apontava
# para outro lugar, e as dez corridas falharam em silêncio, cada uma com uma linha só.
app=$(cd "$(dirname "${1:?caminho do binário QuallCamera}")" && pwd)/$(basename "$1")
cd "$(dirname "${BASH_SOURCE[0]}")"

n=${2:-8}
congelar=${3:-2500}
piso=${4:-500}
gop=${5:-2.0}
SEM_CONSERTO=999999   # nenhum pedido cabe numa corrida de 28 s
# Qual corrida rodar: laço local (`pli-corrida.sh`) ou o A07 por Wi-Fi (`pli-corrida-a07.sh`).
CORRIDA=${PLI_CORRIDA:-pli-corrida.sh}

for i in $(seq 0 $((n - 1))); do
  # Fase do congelamento dentro do GOP: 0, GOP/n, 2·GOP/n, …
  em=$(python3 -c "print(f'{10 + $i * $gop / $n:.3f}')")
  echo "=== par $((i + 1))/$n — congelamento aos ${em}s (fase $(python3 -c "print(f'{($i * $gop / $n):.3f}')")s do GOP)"
  PLI_CONGELAR_EM=$em bash "./$CORRIDA" "$app" $((7910 + (i % 5))) "sem-$i" "$congelar" "$SEM_CONSERTO"
  PLI_CONGELAR_EM=$em bash "./$CORRIDA" "$app" $((7915 + (i % 5))) "com-$i" "$congelar" "$piso"
done

echo
echo "=========== resumo ==========="
python3 - "${PLI_SAIDA:-/tmp/pli}" <<'FIM'
import glob, os, re, statistics, sys
saida = sys.argv[1]
for braco, rotulo in (("sem", "SEM conserto (nenhum PLI)"), ("com", "COM conserto (PLI na perda)")):
    vals, pedidos, anomalias = [], [], []
    prefixo = os.environ.get("PLI_PREFIXO", "")
    for arq in sorted(glob.glob(os.path.join(saida, f"{prefixo}{braco}-*.receptor"))):
        t = open(arq, encoding="utf-8", errors="replace").read()
        m = re.search(r"PERDA: eventos=(\d+) pedidos de IDR=(\d+)(?: idrs recebidos=\d+)? sem referência \(ms\)= ?(.*)", t)
        if not m:
            continue
        pedidos.append(int(m.group(2)))
        vals += [int(x) for x in m.group(3).split()]
        a = re.findall(r'"sequence_anomalies":(\d+)', t)
        if a:
            anomalias.append(int(a[-1]))
    if not vals:
        print(f"-- {rotulo}: nenhuma corrida")
        continue
    o = sorted(vals)
    print(f"-- {rotulo}: n={len(o)}")
    print(f"   sem referência (ms): {' · '.join(str(v) for v in vals)}")
    print(f"   min {o[0]}  mediana {statistics.median(o):.0f}  max {o[-1]}")
    print(f"   pedidos de IDR por corrida: {pedidos}")
    print(f"   anomalias de sequência por corrida: {anomalias}")
FIM
