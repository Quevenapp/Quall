#!/usr/bin/env python3
"""
Resume uma varredura do **piso de insistência** do PLI, ponto a ponto, com as duas metades da troca.

Irmão de `aa-piso.py`, que varre o piso de **abertura** (quanto tempo uma perda nova espera antes
do primeiro pedido). Este varre o piso de **insistência** (o intervalo mínimo entre repetições do
mesmo pedido) com a abertura travada em 100 ms — o veredito da varredura anterior
(`docs/android-para-android.md`, seção 16). Os dois pisos governam coisas diferentes: abertura
decide se uma perda **nova** tem chance de curar de graça antes do primeiro pedido; insistência
decide quanto uma perda **já pedida e não atendida** espera antes do próximo pedido.

    apps/android/tools/aa-piso-insistencia.py varredura.json [outra.json ...]

Vários arquivos do **mesmo sentido** são somados por ponto — os pontos foram ciclados (rotacionados)
dentro de cada lote, então juntar lotes mantém a intercalação que a comparação exige.
"""
from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict


def num(v, padrao=0.0):
    if v is None:
        return padrao
    try:
        return float(str(v).replace("ms", "").replace(",", "."))
    except ValueError:
        return padrao


def pct(vs, q):
    if not vs:
        return 0.0
    o = sorted(vs)
    return o[int((q / 100.0) * (len(o) - 1))]


def main(caminhos):
    por_intervalo = defaultdict(list)
    condicao = None
    for c in caminhos:
        d = json.loads(open(c).read())
        condicao = condicao or d["condicao"]
        for x in d["corridas"]:
            if "erro" in x:
                continue
            por_intervalo[int(x.get("intervalo_ms", 500))].append(x)

    cond = condicao
    print(f"\n=== varredura do piso de insistência — {cond['sentido']} ===")
    for papel in ("emissor", "receptor"):
        w = cond[papel]["wifi"]
        print(f"  {papel:9s} {cond[papel]['nome']:7s} {cond[papel]['ip']:15s} "
              f"{w['ssid']!r} {w['frequencia']} rssi={w['rssi']}")
    print(f"  piso de abertura fixo em 100 ms; {cond['segundos']} s por corrida\n")

    cab = (f"{'piso':>6} {'corr':>5} {'amostras':>9} | {'mediana':>8} {'p95':>8} {'>500ms':>7} | "
           f"{'PLI/min':>8} {'curadas':>8} {'perda pkt':>10} {'reordem':>8} {'fps':>6}")
    print(cab)
    print("-" * len(cab))
    for intervalo in sorted(por_intervalo):
        cs = por_intervalo[intervalo]
        amostras = [v for x in cs for v in x.get("sem_referencia_amostras", [])]
        segs = sum(num(x.get("segundos"), 30) for x in cs)
        pedidos = sum(num(x["receptor"].get("pedidos_por_perda")) for x in cs)
        curadas = sum(num(x["receptor"].get("resolvidas_sem_pedido")) for x in cs)
        # `nucleo_packets_missing` deixou de existir em 29/08/2026: virou
        # `nucleo_packets_missing_upper_bound`, porque nunca foi perda — cobrava
        # reordenação junto, de 1,3x a 44x. O `-1` é deliberado: `num` devolve 0.0
        # para chave ausente, e uma tabela dizendo "perda 0" por causa de uma chave
        # que sumiu é exatamente o instrumento mentiroso que esta casa passou dois
        # dias caçando. Com -1 a coluna fica visivelmente errada.
        falt = sum(num(x["receptor"].get("nucleo_packets_missing_upper_bound"), -1) for x in cs)
        vist = sum(num(x["receptor"].get("nucleo_packets_seen")) for x in cs)
        reor = sum(num(x["receptor"].get("nucleo_reorder_events")) for x in cs)
        fps = [num(x["receptor"].get("fps")) for x in cs]
        acima = sum(1 for v in amostras if v > 500)
        med = statistics.median(amostras) if amostras else 0.0
        print(f"{intervalo:>6} {len(cs):>5} {len(amostras):>9} | "
              f"{med:>8.1f} {pct(amostras, 95):>8.1f} "
              f"{(100 * acima / len(amostras) if amostras else 0):>6.1f}% | "
              f"{(60 * pedidos / segs if segs else 0):>8.1f} {int(curadas):>8} "
              f"{(100 * falt / (falt + vist) if falt + vist else 0):>9.2f}% "
              f"{int(reor):>8} {statistics.mean(fps) if fps else 0:>6.1f}")

    print("\n  amostras cruas por piso (ms):")
    for intervalo in sorted(por_intervalo):
        a = sorted(v for x in por_intervalo[intervalo] for v in x.get("sem_referencia_amostras", []))
        print(f"    {intervalo:>5}: n={len(a):<4} {[round(v) for v in a[:40]]}"
              f"{' …' if len(a) > 40 else ''}")


if __name__ == "__main__":
    main(sys.argv[1:])
