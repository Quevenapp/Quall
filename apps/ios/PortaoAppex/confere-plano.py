#!/usr/bin/env python3
"""Compara o plano que o roteiro **enviou** com o que o aparelho **decodificou**.

    ./confere-plano.py enviado.json '{"altura":1280,...}'

Sai com 0 se cada chave enviada aparece no eco com o mesmo valor, e com 1 dizendo exatamente
qual chave divergiu.

Existe porque três defeitos seguidos deste degrau tiveram a mesma forma: uma condição que
deveria abortar passou em silêncio. Um plano que chega pela metade — chave nova que o binário no
aparelho ainda não conhece, campo com o tipo errado, arquivo truncado no envio — produz uma
corrida que roda bonito e mede outra coisa. Como cada corrida custa um toque humano que o
iPhone 7 não automatiza, essa é a diferença entre gastar o toque e desperdiçá-lo.

Só as chaves **enviadas** são conferidas: o eco traz o plano inteiro, com os padrões preenchidos,
e cobrar igualdade de chave que ninguém mandou seria cobrar que o roteiro repetisse os padrões.
"""

import json
import sys


def igual(a, b):
    # JSON não distingue 30 de 30.0, e o Swift codifica `Double` como `30` quando é inteiro.
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b or a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) < 1e-9
    return a == b


def main(argv):
    if len(argv) < 3:
        print("uso: confere-plano.py <enviado.json> <eco-json>")
        return 2
    with open(argv[1], encoding="utf-8") as f:
        enviado = json.load(f)
    try:
        eco = json.loads(argv[2])
    except json.JSONDecodeError as erro:
        print(f"!! o eco do aparelho não é JSON válido: {erro}")
        print(f"   recebido: {argv[2][:400]}")
        return 1

    problemas = []
    for chave, valor in enviado.items():
        if chave not in eco:
            problemas.append(f"   {chave}: ENVIADO {valor!r}, AUSENTE no eco "
                             f"(o binário no aparelho não conhece esta chave)")
        elif not igual(valor, eco[chave]):
            problemas.append(f"   {chave}: ENVIADO {valor!r}, DECODIFICADO {eco[chave]!r}")

    if problemas:
        print(f"!! o plano decodificado no aparelho NÃO bate com o enviado "
              f"({len(problemas)} de {len(enviado)} chaves):")
        print("\n".join(problemas))
        return 1

    print(f"   plano conferido: {len(enviado)} chaves enviadas, todas iguais no eco do aparelho")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
