#!/usr/bin/env python3
"""Imprime, em uma linha por campo, o JSON de medição que a sonda do Windows devolve.

Existe para não ter que embutir Python dentro de heredoc dentro de shell — que nesta bancada já
custou uma edição perdida em silêncio, porque o delimitador interno fechou o externo.
"""
import json
import sys

d = json.load(open(sys.argv[1]))
for k, v in d.items():
    if isinstance(v, dict) and "p50" in v:
        print(f"   {k:24s} media={v['media']:.3f} p50={v['p50']:.3f} "
              f"p95={v['p95']:.3f} max={v['max']:.3f} n={v['amostras']}")
    elif not isinstance(v, (dict, list)):
        print(f"   {k:24s} {v}")
