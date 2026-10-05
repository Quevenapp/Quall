#!/usr/bin/env python3
"""Autoteste do `analisar.py`: um vídeo de 240 fps com viés **conhecido**, sem aparelho nenhum.

Gera um .mov (H.264 + AAC, como o do iPhone) e o JSON da claquete com a mesma semente, e
imprime o viés verdadeiro. O `analisar.py` tem de devolvê-lo, e o controle 0/+40 tem de dar 40.

O modelo, e onde ele é mais generoso que a bancada:
* a exposição de cada quadro é o intervalo inteiro, **centrado no PTS** — a convenção real da
  câmera lenta é desconhecida (±meio quadro, ver `analisar.py`);
* a tela sobe em `--subida-ms` (padrão 3 ms, linear), e acende no quadro de 60 Hz seguinte ao
  instante programado, como o iPad;
* o bipe é o do app (3150 Hz, rampas de cosseno de 2 ms), com tremor gaussiano, sobre ruído e
  um zumbido de 1 kHz.

Uso:
    sintetico.py SAIDA_DIR [--vies-ms 23] [--eventos 40] [--semente 12345] [--tremor-ms 1.5]
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analisar import BIPE_HZ, classes_da_semente  # noqa: E402

FPS = 240
SR = 48000
LADO = 64


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("saida")
    ap.add_argument("--vies-ms", type=float, default=23.0)
    ap.add_argument("--eventos", type=int, default=40)
    ap.add_argument("--semente", type=int, default=12345)
    ap.add_argument("--tremor-ms", type=float, default=1.5)
    ap.add_argument("--subida-ms", type=float, default=3.0)
    ap.add_argument("--bipe-ms", type=float, default=50.0)
    a = ap.parse_args()
    os.makedirs(a.saida, exist_ok=True)
    rng = np.random.default_rng(7)

    intervalo = 2.0
    t0 = 1.3
    classes = classes_da_semente(a.semente, a.eventos + 5)
    # O vídeo começa no evento 3, para o analisador ter de alinhar a sequência.
    primeiro = 3
    dur = t0 + a.eventos * intervalo + 1.0
    programados = [t0 + i * intervalo for i in range(a.eventos)]
    periodo_tela = 1 / 60.0
    fase_tela = 0.0042
    acende = [np.ceil((t - fase_tela) / periodo_tela) * periodo_tela + fase_tela for t in programados]
    apaga = [acende[i] + (0.2 if classes[primeiro + i] == 40 else 0.1) for i in range(a.eventos)]

    # --- vídeo: luminância por quadro, exposição de um quadro centrada no PTS
    n_q = int(dur * FPS)
    sub = 16
    lo, hi = 20.0, 220.0
    subida = a.subida_ms / 1000

    def brilho(t):
        b = np.zeros_like(t)
        for ta, tp in zip(acende, apaga):
            up = np.clip((t - ta) / subida, 0, 1)
            down = np.clip((t - tp) / subida, 0, 1)
            b = np.maximum(b, up - down)
        return b

    quadros = np.empty((n_q, LADO, LADO), dtype=np.uint8)
    for k in range(n_q):
        ts = k / FPS + (np.arange(sub) + 0.5) / (sub * FPS) - 0.5 / FPS
        v = lo + (hi - lo) * brilho(ts).mean() + rng.normal(0, 1.0)
        quadros[k] = np.clip(v, 0, 255)
    bruto_v = os.path.join(a.saida, "v.gray")
    quadros.tofile(bruto_v)

    # --- som
    n_a = int(dur * SR)
    x = rng.normal(0, 0.003, n_a) + 0.02 * np.sin(2 * np.pi * 1000 * np.arange(n_a) / SR)
    nb = int(SR * a.bipe_ms / 1000)
    rampa = int(SR * 0.002)
    env = np.ones(nb)
    env[:rampa] = 0.5 - 0.5 * np.cos(np.pi * np.arange(rampa) / rampa)
    env[-rampa:] = env[:rampa][::-1]
    verdade = []
    for i, ta in enumerate(acende):
        # O "instante da imagem" é o meio da subida da tela; o som sai viés + classe depois.
        t_img = ta + subida / 2
        d = classes[primeiro + i] / 1000
        tb = t_img + d + a.vies_ms / 1000 + rng.normal(0, a.tremor_ms / 1000)
        verdade.append((tb - t_img - d) * 1000)
        i0 = int(round(tb * SR))
        frac = tb * SR - i0
        k = np.arange(nb)
        x[i0:i0 + nb] += 0.3 * env * np.sin(2 * np.pi * BIPE_HZ * (k - frac) / SR)
    bruto_a = os.path.join(a.saida, "a.f32")
    x.astype(np.float32).tofile(bruto_a)

    mov = os.path.join(a.saida, "sintetico.mov")
    subprocess.run(["ffmpeg", "-v", "error", "-y",
                    "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{LADO}x{LADO}", "-r", str(FPS),
                    "-i", bruto_v, "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", bruto_a,
                    "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-b:a", "192k", mov], check=True)
    os.remove(bruto_v)
    os.remove(bruto_a)

    cfg = {"sonda": "S-C1", "semente": str(a.semente), "intervalo_s": intervalo,
           "bipe_hz": BIPE_HZ, "bipe_ms": a.bipe_ms, "rampa_ms": 2.0,
           "eventos": [{"i": i, "classe_ms": c, "t_programado_s": -1, "t_clarao_alvo_s": -1,
                        "t_bipe_agendado_s": -1} for i, c in enumerate(classes)]}
    js = os.path.join(a.saida, "claquete-sintetica.json")
    with open(js, "w") as f:
        json.dump(cfg, f, indent=1)
    v = np.array(verdade)
    print(f"{mov}\n{js}")
    print(f"verdade: viés {a.vies_ms:+.1f} ms; Δ sorteado p05 {np.percentile(v, 5):+.1f}, "
          f"p50 {np.median(v):+.1f}, p95 {np.percentile(v, 95):+.1f}, n {len(v)}")


if __name__ == "__main__":
    main()
