#!/usr/bin/env python3
"""Autoteste do `analisar.py` sem aparelho: grava o que o `quall-probe receber-claquete` gravaria
de um emissor que filma a Claquete R5, com um Δ câmera × microfone **conhecido**.

O modelo (e onde ele é mais generoso que a bancada):
* a câmera a `--fps` com tremor de ±1 ms no carimbo; a exposição de cada quadro é o intervalo
  inteiro, **centrada no carimbo** (a convenção real é desconhecida: ver `analisar.py`);
* o iPad ocupa um retângulo do quadro, acende no vsync de 60 Hz seguinte ao instante programado,
  e dura 100 ms (classe 0) ou 200 ms (+40), com a classe da semente como no app; a gravação começa
  no evento 3, para o analisador ter de alinhar a sequência;
* o bipe (3150 Hz, rampas de cosseno de 2 ms) sai `classe + viés_do_iPad` depois do clarão, voa
  `distância/343` e chega ao microfone, que o carimba `Δ` depois do que a câmera carimbaria: Δ é
  a verdade que o analisador tem de devolver. Tremor gaussiano por evento, ruído e zumbido;
* os carimbos de cada track têm bases diferentes, e o deslocamento do relógio comum de cada uma
  vai no `P.json`, como a sonda grava; o som decodificado sai atrasado os 6,5 ms do Opus;
* `--perda-som` tira pacotes de som (buracos na linha do tempo).

Uso:
    sintetico.py PREFIXO [--delta-ms 23] [--semente 12345] [--eventos 40] [--fps 30]
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analisar import BIPE_HZ, VEL_SOM, classes_da_semente  # noqa: E402

SR = 48000
L, A = 160, 120


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prefixo")
    ap.add_argument("--delta-ms", type=float, default=23.0)
    ap.add_argument("--semente", type=int, default=12345)
    ap.add_argument("--eventos", type=int, default=40)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--vies-ipad-ms", type=float, default=-17.4)
    ap.add_argument("--distancia-m", type=float, default=0.5)
    ap.add_argument("--tremor-ms", type=float, default=1.5)
    ap.add_argument("--bipe-ms", type=float, default=10.0)
    ap.add_argument("--perda-som", type=float, default=0.01)
    ap.add_argument("--intervalo-s", type=float, default=2.0,
                    help="o -intervaloS da Claquete (2.0137 varre a fase do clarão no quadro)")
    ap.add_argument("--qp", type=int, help="qp fixo do x264 (0 = sem perda); padrão: o crf do x264")
    a = ap.parse_args()
    P = a.prefixo
    rng = np.random.default_rng(3)

    intervalo, t0, primeiro = a.intervalo_s, 1.3, 3
    classes = classes_da_semente(a.semente, primeiro + a.eventos)
    dur = t0 + a.eventos * intervalo + 1.0
    vsync = 1 / 60.0
    acende, apaga, bipe = [], [], []
    for i in range(a.eventos):
        c = classes[primeiro + i]
        tp = t0 + i * intervalo
        on = np.ceil(tp / vsync) * vsync + 0.0021
        off = np.ceil((tp + (0.2 if c == 40 else 0.1)) / vsync) * vsync + 0.0021
        acende.append(on)
        apaga.append(off)
        bipe.append(on + (c + a.vies_ipad_ms + a.delta_ms) / 1000 + a.distancia_m / VEL_SOM
                    + rng.normal(0, a.tremor_ms / 1000))

    # --- vídeo ------------------------------------------------------------------------------
    T = 1 / a.fps
    n_q = int(dur / T)
    ts = np.arange(n_q) * T + rng.uniform(-0.001, 0.001, n_q)
    sub = 32

    def aceso(t):
        b = np.zeros_like(t)
        for on, off in zip(acende, apaga):
            b = np.maximum(b, ((t >= on) & (t < off)).astype(float))
        return b

    quadros = np.full((n_q, A, L), 30, dtype=np.uint8)
    for k in range(n_q):
        amostra = ts[k] - T / 2 + (np.arange(sub) + 0.5) / sub * T
        f = aceso(amostra).mean()
        quadros[k, 30:90, 40:120] = np.clip(40 + 170 * f + rng.normal(0, 1.0), 0, 255)
    bruto = P + ".gray"
    quadros.tofile(bruto)
    subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{L}x{A}",
                    "-r", str(a.fps), "-i", bruto, "-c:v", "libx264", "-bf", "0", "-g", "60",
                    "-pix_fmt", "yuv420p"] + (["-qp", str(a.qp)] if a.qp is not None else [])
                   + ["-f", "h264", "-y", P + ".h264"], check=True)
    os.remove(bruto)
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "packet=pos,size,flags",
                        "-of", "csv=p=0", P + ".h264"], capture_output=True, text=True, check=True)
    pacotes_v = [linha.split(",") for linha in r.stdout.split()]
    if len(pacotes_v) != n_q:
        sys.exit(f"!! {len(pacotes_v)} pacotes para {n_q} quadros")
    base_v, base_s, epoca = 7_000_000, 123_456_789, 1_000_000
    with open(P + ".quadros.csv", "w") as f:
        f.write("indice,pos,bytes,timestamp_us,idr\n")
        for k, (size, pos, flags) in enumerate(pacotes_v):
            f.write(f"{k},{pos},{size},{int(round(ts[k] * 1e6)) + base_v},{int('K' in flags)}\n")

    # --- som --------------------------------------------------------------------------------
    atraso = 0.0065
    n_a = int(dur * SR)
    t = np.arange(n_a) / SR
    x = rng.normal(0, 0.002, n_a) + 0.01 * np.sin(2 * np.pi * 1000 * t)
    nb, rampa = int(a.bipe_ms / 1000 * SR), int(0.002 * SR)
    env = np.ones(nb)
    k = np.arange(rampa)
    env[:rampa] = 0.5 - 0.5 * np.cos(np.pi * k / rampa)
    env[-rampa:] = env[:rampa][::-1]
    for tb in bipe:
        i0 = int(np.floor(tb * SR))
        fr = tb * SR - i0
        kk = np.arange(nb) - fr
        x[i0:i0 + nb] += 0.05 * env * np.sin(2 * np.pi * BIPE_HZ * kk / SR)
    # O decodificado sai atrasado o conteúdo do codec: a amostra j do pacote de carimbo τ é a
    # captura de τ − 6,5 ms + j/SR.
    atraso_n = int(round(atraso * SR))
    x = np.concatenate([np.zeros(atraso_n), x])
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    por = 960
    linhas, pedacos, amostra, perdidos = [], [], 0, 0
    for p in range(n_a // por):
        if p > 5 and rng.random() < a.perda_som:
            perdidos += 1
            continue
        pedacos.append(pcm[p * por:(p + 1) * por])
        linhas.append(f"{p & 0xFFFF},{p * 20_000 + base_s},{amostra},{por}")
        amostra += por
    np.concatenate(pedacos).tofile(P + ".som.pcm")
    with open(P + ".som.csv", "w") as f:
        f.write("seq,timestamp_us,amostra,amostras\n" + "\n".join(linhas) + "\n")

    meta = {
        "sonda": "sintetico.py",
        "video": {"deslocamento_us": epoca - base_v, "status": "valido", "violacoes_da_guarda": 0},
        "som": {"codec": "Opus", "taxa_hz": SR, "canais": 1, "atraso_do_conteudo_us": 6500,
                "deslocamento_us": epoca - base_s, "status": "valido", "violacoes_da_guarda": 0},
        "serie_do_deslocamento": [],
        "verdade": {"delta_ms": a.delta_ms, "vies_ipad_ms": a.vies_ipad_ms,
                    "distancia_m": a.distancia_m, "semente": a.semente},
    }
    with open(P + ".json", "w") as f:
        json.dump(meta, f, indent=2)
    print(f"sintético: {n_q} quadros a {a.fps} fps, {a.eventos} eventos (do {primeiro}), "
          f"{perdidos} pacote(s) de som perdidos; Δ verdadeiro {a.delta_ms:+.1f} ms, viés do iPad "
          f"{a.vies_ipad_ms:+.1f} ms, distância {a.distancia_m} m")


if __name__ == "__main__":
    main()
