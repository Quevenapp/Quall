#!/usr/bin/env python3
"""Valida um par .h264 + .json contra o contrato em docs/contrato-sidecar.md.

Existe porque a primeira rodada do M1 produziu dois sidecars incompatíveis — macOS e Windows
escolheram nomes de chave diferentes, e ninguém percebeu até alguém abrir os dois lado a lado.
Contrato que não é verificado por máquina não é contrato.

    tools/valida-sidecar.py captura.json
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

PRESETS = {"screen", "camera"}
FAIXAS = {"full", "limited"}

CABECALHO = {
    "width": int,
    "height": int,
    "target_fps": int,
    "preset": str,
    "capture_api": str,
    "encoder": str,
    "encoder_is_hardware": bool,
    "target_bitrate_bps": int,
    "gop_frames": int,
    "color_range": str,
    "video_file": str,
}

QUADRO = {
    "number": int,
    "timestamp_us": int,
    "bytes": int,
    "idr": bool,
    "encode_latency_us": int,
}


def tipo_ok(valor, esperado):
    # bool é subclasse de int em Python; sem isto, True passaria por inteiro.
    if esperado is int:
        return isinstance(valor, int) and not isinstance(valor, bool)
    return isinstance(valor, esperado)


def valida(caminho_json):
    erros = []
    caminho_json = Path(caminho_json)

    try:
        doc = json.loads(caminho_json.read_text())
    except Exception as e:
        return [f"não consegui ler o JSON: {e}"]

    for chave in ("header", "frames"):
        if chave not in doc:
            erros.append(f"falta a chave de topo '{chave}'")
    if erros:
        achadas = ", ".join(sorted(doc.keys()))
        erros.append(f"chaves de topo encontradas: {achadas}")
        return erros

    cab = doc["header"]
    for chave, tipo in CABECALHO.items():
        if chave not in cab:
            erros.append(f"header: falta '{chave}'")
        elif not tipo_ok(cab[chave], tipo):
            erros.append(f"header: '{chave}' devia ser {tipo.__name__}, veio {type(cab[chave]).__name__}")

    if cab.get("preset") not in PRESETS:
        erros.append(f"header: 'preset' devia ser um de {sorted(PRESETS)} (minúsculo), veio {cab.get('preset')!r}")
    if cab.get("color_range") not in FAIXAS:
        erros.append(f"header: 'color_range' devia ser um de {sorted(FAIXAS)}, veio {cab.get('color_range')!r}")

    quadros = doc["frames"]
    if not isinstance(quadros, list) or not quadros:
        return erros + ["'frames' devia ser uma lista não vazia"]

    for i, q in enumerate(quadros):
        for chave, tipo in QUADRO.items():
            if chave not in q:
                erros.append(f"frames[{i}]: falta '{chave}'")
            elif not tipo_ok(q[chave], tipo):
                erros.append(f"frames[{i}]: '{chave}' devia ser {tipo.__name__}, veio {type(q[chave]).__name__}")
        if len(erros) > 20:
            erros.append("... (parando de listar erros de tipo)")
            break

    if not quadros[0].get("idr"):
        erros.append("o primeiro quadro precisa ser IDR")

    numeros = [q.get("number") for q in quadros if isinstance(q.get("number"), int)]
    if numeros != sorted(numeros) or len(set(numeros)) != len(numeros):
        erros.append("'number' precisa ser estritamente crescente e sem repetição")
    if numeros and numeros[0] != 0:
        erros.append(f"'number' precisa começar em 0, começou em {numeros[0]}")

    ts = [q.get("timestamp_us") for q in quadros if isinstance(q.get("timestamp_us"), int)]
    if any(b <= a for a, b in zip(ts, ts[1:])):
        erros.append("'timestamp_us' precisa ser estritamente crescente (relógio monotônico)")

    # Taxa obtida contra taxa pedida. Não é campo do sidecar: é derivada dos próprios quadros,
    # e existe porque um defeito real passou despercebido no M2. A captura do Android entregava
    # 67 quadros por segundo com `target_fps` de 30 — o `VirtualDisplay` empurra na taxa da tela e
    # nada descartava —, a fila do encoder entupia e a latência ia a 251 ms. O `.h264` ficava
    # perfeito e o sidecar validava; só a latência denunciava.
    #
    # Entregar MENOS que o pedido é legítimo: tela parada não gera quadro novo, e é assim que o
    # Windows.Graphics.Capture se comporta. Entregar MAIS é sempre defeito.
    if len(ts) >= 2 and ts[-1] > ts[0]:
        duracao = (ts[-1] - ts[0]) / 1_000_000
        obtida = len(quadros) / duracao
        pedida = cab.get("target_fps")
        if isinstance(pedida, int) and pedida > 0 and obtida > pedida * 1.15:
            erros.append(
                f"taxa obtida ({obtida:.1f} qps) acima da pedida ({pedida} qps) — o encoder está "
                f"recebendo mais do que foi configurado para receber, e a fila dele vai crescer"
            )

    video = caminho_json.parent / cab.get("video_file", "")
    if not video.is_file():
        erros.append(f"não achei o vídeo '{cab.get('video_file')}' ao lado do sidecar")
    else:
        soma = sum(q["bytes"] for q in quadros if isinstance(q.get("bytes"), int))
        real = video.stat().st_size
        if soma != real:
            erros.append(f"soma de 'bytes' ({soma}) não bate com o tamanho de {video.name} ({real})")

        if shutil.which("ffprobe"):
            try:
                saida = subprocess.run(
                    ["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
                     "-show_entries", "stream=nb_read_frames,profile,width,height",
                     "-of", "default=noprint_wrappers=1", str(video)],
                    capture_output=True, text=True, timeout=180,
                )
                campos = dict(
                    linha.split("=", 1) for linha in saida.stdout.strip().splitlines() if "=" in linha
                )
                n = int(campos.get("nb_read_frames", -1))
                if n != len(quadros):
                    erros.append(f"ffprobe contou {n} quadros, o sidecar declara {len(quadros)}")
                for chave, esperado in (("width", cab.get("width")), ("height", cab.get("height"))):
                    if campos.get(chave) and int(campos[chave]) != esperado:
                        erros.append(f"ffprobe diz {chave}={campos[chave]}, o sidecar diz {esperado}")
                perfil = campos.get("profile", "")
                if "Baseline" not in perfil:
                    erros.append(f"perfil H.264 devia ser Baseline, ffprobe diz {perfil!r}")
            except Exception as e:
                erros.append(f"ffprobe falhou: {e}")
        else:
            print("aviso: ffprobe ausente — validação externa do .h264 não foi feita")

    return erros


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    problemas = valida(sys.argv[1])
    if problemas:
        print(f"REPROVADO — {len(problemas)} problema(s):")
        for p in problemas:
            print(f"  - {p}")
        sys.exit(1)
    print("aprovado")
