#!/usr/bin/env bash
# Sensibilidade do número à carga da máquina.
#
# Existe porque três frentes usam este MacBook ao mesmo tempo e "espere a máquina ficar quieta"
# não é um critério: é uma esperança. Em vez de escolher um limiar de load no chute, medir a
# corrida em várias cargas e ver quais números se mexem e quais não.
#
# Não força carga nenhuma: aproveita a que existir. Cada corrida registra o load de 1 minuto ao
# lado da própria distribuição, e o resumo sai em CSV.
#
#   uso: tools/vidro-a-vidro/varredura-de-carga.sh [QUANTAS] [SEGUNDOS_POR_CORRIDA]
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUANTAS="${1:-6}"
SEGUNDOS="${2:-12}"
BASE="$AQUI/corridas/varredura-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BASE"
CSV="$BASE/varredura.csv"

echo "load1,load5,n_manchete,manchete_p50,manchete_p95,manchete_max,frac_16ms,trabalho_p50,trabalho_p95,trabalho_max,encode_p50,decode_p50,sck_p50,acendeu,enviados,desenhados" >"$CSV"

for i in $(seq 1 "$QUANTAS"); do
    DIR="$BASE/c$i"
    L1=$(uptime | sed 's/.*load averages*: *//' | awk '{print $1}' | tr -d ,)
    echo "-- corrida $i/$QUANTAS  load1=$L1 --"
    "$AQUI/correr.sh" "$SEGUNDOS" "$DIR" >"$DIR.log" 2>&1 || true
    python3 - "$DIR" "$L1" "$CSV" <<'PY'
import json, sys, os
d, l1, csv = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.join(d, "resumo.json")
if not os.path.exists(p):
    print("  sem resumo — corrida descartada"); sys.exit(0)
r = json.load(open(p))
m, t = r.get("manchete_ms") or {}, r.get("trabalho_do_pipeline_ms") or {}
f = r.get("fatias_ms") or {}
cov = r.get("cobertura") or {}
l5 = (r.get("cabecalho_emissor", {}).get("carga_inicio", {}).get("load_avg") or [0, 0])[1]
hist = r.get("manchete_histograma_1ms") or []
tot = sum(n for _, n in hist) or 1
frac16 = sum(n for b, n in hist if 16 <= b < 17) / tot


def g(dic, k="p50"):
    return f"{dic.get(k, float('nan')):.3f}" if dic else ""


enc = f.get("T1→T2  encode (VideoToolbox)") or {}
dec = f.get("T3r→T3 decode (VideoToolbox)") or {}
sck = f.get("T0c→T1 commit do desenho → quadro no processo") or {}
linha = ",".join([
    l1, f"{l5:.2f}", str(m.get("n", 0)), g(m), g(m, "p95"), g(m, "max"), f"{frac16:.3f}",
    g(t), g(t, "p95"), g(t, "max"), g(enc), g(dec), g(sck),
    str(cov.get("acenderam", 0)), str(cov.get("enviados", 0)), str(cov.get("desenhados", 0)),
])
open(csv, "a").write(linha + "\n")
print("  " + linha)
PY
done

echo
echo "== varredura em $CSV =="
column -s, -t "$CSV"
