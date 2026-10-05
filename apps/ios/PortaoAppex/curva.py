#!/usr/bin/env python3
"""Lê o log de uma corrida do degrau 4 e responde a única pergunta que importa: a pegada
estabiliza ou sobe?

    ./curva.py medida-degrau4/completo/degraus.txt

O pico não é o resultado — a **inclinação** é. Uma pegada que cresce 200 KB por minuto passa num
teste de trinta segundos e mata uma aula de quarenta minutos, e é por isso que o relato por fase
traz a reta ajustada por mínimos quadrados junto com o primeiro e o último valor. Os dois
importam: a reta pega a tendência, os extremos pegam o degrau que a reta suaviza.

O primeiro terço de cada fase é **descartado** do ajuste. Toda fase começa com um transiente —
alocação de sessão, criação do encoder, aquecimento do pool do VideoToolbox — e incluí-lo faria
qualquer fase parecer crescente.
"""

import re
import sys
from collections import OrderedDict

LINHA = re.compile(
    r"DEGRAU4 t=(?P<t>[\d.]+) fase=(?P<fase>\S+).*?pegada=(?P<pegada>\d+)"
    r"(?:.*?memoria_disponivel=(?P<disp>\d+))?"
)
DISPONIVEL = re.compile(r"memoria_disponivel=(\d+)")


def reta(pontos):
    """Mínimos quadrados; devolve a inclinação em bytes por minuto."""
    n = len(pontos)
    if n < 3:
        return None
    sx = sum(p[0] for p in pontos)
    sy = sum(p[1] for p in pontos)
    sxx = sum(p[0] * p[0] for p in pontos)
    sxy = sum(p[0] * p[1] for p in pontos)
    denominador = n * sxx - sx * sx
    if abs(denominador) < 1e-9:
        return None
    return (n * sxy - sx * sy) / denominador * 60.0


def mb(bytes_):
    return f"{bytes_ / 1048576:.3f} MB"


def main(caminho):
    fases = OrderedDict()
    tetos = []
    for linha in open(caminho, encoding="utf-8", errors="replace"):
        m = LINHA.search(linha)
        if not m:
            continue
        t = float(m.group("t"))
        pegada = int(m.group("pegada"))
        fases.setdefault(m.group("fase"), []).append((t, pegada))
        d = DISPONIVEL.search(linha)
        if d:
            tetos.append(int(d.group(1)) + pegada)

    if not fases:
        print("nenhuma amostra de 1 Hz encontrada em", caminho)
        return 1

    print(f"{'fase':<22} {'amostras':>8} {'primeira':>12} {'última':>12} "
          f"{'mín':>12} {'máx':>12} {'inclinação':>16}")
    print("-" * 100)
    for fase, pontos in fases.items():
        pontos.sort()
        corte = len(pontos) // 3
        ajuste = pontos[corte:] if len(pontos) - corte >= 3 else pontos
        inclinacao = reta(ajuste)
        pegadas = [p[1] for p in pontos]
        texto = "—" if inclinacao is None else f"{inclinacao / 1024:+.1f} KB/min"
        print(f"{fase:<22} {len(pontos):>8} {mb(pegadas[0]):>12} {mb(pegadas[-1]):>12} "
              f"{mb(min(pegadas)):>12} {mb(max(pegadas)):>12} {texto:>16}")

    if tetos:
        print()
        print(f"teto do jetsam (disponível + pegada): mín {mb(min(tetos))}  "
              f"máx {mb(max(tetos))}  em {len(tetos)} amostras")
    todas = [p[1] for pontos in fases.values() for p in pontos]
    print(f"pegada geral: mín {mb(min(todas))}  máx {mb(max(todas))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "medida-degrau4/completo/degraus.txt"))
