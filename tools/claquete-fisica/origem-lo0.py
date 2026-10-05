#!/usr/bin/env python3
"""Autoteste de ponta a ponta em `lo0`: uma origem `.h264` com clarões nos instantes da claquete
da própria sonda (`crates/quall-probe/src/claquete.rs`), para o `emitir-video --claquete` mandar
com os estouros no som e o `receber-claquete` gravar do outro lado.

A imagem não vem de captura nenhuma: é cinza sintético com um retângulo que acende. O clarão do
evento k começa no primeiro quadro cujo carimbo passa de `t_k` e dura 100 ms (deslocamento 0) ou
200 ms (+40), a mesma convenção de classe da Claquete R5. O som é o da sonda: estouro seco de 10 ms
em `t_k + deslocamento`. Então, por evento, a verdade é

    Δ_k = t_k − travessia_k    (≈ t_k − (c_{k−1} + c_k)/2, no máximo meio quadro)

e o `conferir` abaixo a compara com o que o analisador mediu, evento a evento, usando os carimbos
de envio que a sonda gravou na verdade da claquete (`--claquete-saida`).

Uso:
    origem-lo0.py gerar DIR --semente S [--segundos 70] [--fps 30]
    origem-lo0.py conferir RELATO.json VERDADE.json PREFIXO [--deslocar-ms 0]
"""

import argparse
import csv
import json
import os
import subprocess
import sys

import numpy as np

MASCARA = (1 << 64) - 1


def misturar(x):
    """O `misturar` de `claquete.rs` (splitmix64 de um passo)."""
    x = (x + 0x9E3779B97F4A7C15) & MASCARA
    z = x
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASCARA
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASCARA
    return z ^ (z >> 31)


def eventos_da_sonda(semente, ate_us):
    """`Claquete::nova`: (t_us, desloc_us) de cada evento."""
    out, t, k = [], 2_000_000, 0
    while t < ate_us:
        a = misturar(semente ^ ((k * 2) & MASCARA))
        b = misturar(semente ^ ((k * 2 + 1) & MASCARA))
        out.append((t, 40_000 if b & 1 else 0))
        t += 700_000 + a % 600_001
        k += 1
    return out


def gerar(a):
    os.makedirs(a.dir, exist_ok=True)
    L, A = 320, 240
    n = int(a.segundos * a.fps)
    ts = [int(round(k * 1e6 / a.fps)) for k in range(n)]
    evs = eventos_da_sonda(a.semente, int(a.segundos * 1e6))
    aceso = np.zeros(n, dtype=bool)
    for t, d in evs:
        dur = 200_000 if d else 100_000
        for k in range(n):
            if t <= ts[k] < t + dur:
                aceso[k] = True
    q = np.full((n, A, L), 40, dtype=np.uint8)
    q[aceso, 60:180, 80:240] = 220
    bruto = os.path.join(a.dir, "origem.gray")
    q.tofile(bruto)
    h264 = os.path.join(a.dir, "origem.h264")
    subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{L}x{A}",
                    "-r", str(a.fps), "-i", bruto, "-c:v", "libx264", "-profile:v", "baseline",
                    "-bf", "0", "-g", str(int(a.fps * 2)), "-pix_fmt", "yuv420p",
                    "-x264-params", "repeat-headers=1", "-f", "h264", "-y", h264], check=True)
    os.remove(bruto)
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "packet=size,flags",
                        "-of", "csv=p=0", h264], capture_output=True, text=True, check=True)
    pac = [linha.split(",") for linha in r.stdout.split()]
    if len(pac) != n:
        sys.exit(f"!! {len(pac)} pacotes para {n} quadros")
    sidecar = {
        "header": {"width": L, "height": A, "target_fps": int(round(a.fps)), "preset": "camera",
                   "capture_api": "sintetico", "encoder": "libx264", "encoder_is_hardware": False,
                   "target_bitrate_bps": 0, "gop_frames": int(a.fps * 2),
                   "color_range": "limited", "video_file": "origem.h264"},
        "frames": [{"number": k, "timestamp_us": ts[k], "bytes": int(pac[k][0]),
                    "idr": "K" in pac[k][1]} for k in range(n)],
    }
    with open(os.path.join(a.dir, "origem.json"), "w") as f:
        json.dump(sidecar, f)
    print(f"origem: {n} quadros a {a.fps} fps, {len(evs)} eventos da semente {a.semente}, "
          f"{int(aceso.sum())} quadros acesos → {a.dir}/origem.json")


def conferir(a):
    rel = json.load(open(a.relato))
    ver = json.load(open(a.verdade))
    quadros = list(csv.DictReader(open(a.prefixo + ".quadros.csv")))
    meta = json.load(open(a.prefixo + ".json"))
    dv = meta["video"]["deslocamento_us"]
    # O carimbo de envio de cada quadro, no relógio da sonda emissora, é o carimbo do fio; o
    # recebido é o mesmo número rebaseado. O quadro marcado (o 1º aceso) e o anterior dão a
    # travessia esperada; a origem entre os relógios sai do casamento do analisador.
    eventos = ver["eventos"]
    tq = np.array([int(q["timestamp_us"]) + dv for q in quadros]) / 1e6
    erros = []
    for p in rel["pares"]:
        k = p.get("evento")
        if k is None:
            continue
        e = eventos[k]
        # O quadro recebido cujo tempo comum está mais perto da travessia medida, e o anterior.
        j = int(np.searchsorted(tq, p["t_clarao_s"]))
        if j <= 0 or j >= len(tq):
            continue
        meio = (tq[j - 1] + tq[j]) / 2
        # Verdade: o evento está `t_k − c_k` depois do quadro aceso (c_k da sonda, no relógio da
        # sonda); o quadro aceso é tq[j] no relógio comum. Δ esperado = (t_k − c_k) + (tq[j] − meio).
        esperado = (e["t_us"] - e["carimbo_video_us"]) / 1000 + (tq[j] - meio) * 1000 + a.deslocar_ms
        erros.append(p["delta_ms"] - esperado)
    erros = np.array(erros)
    if len(erros) == 0:
        sys.exit("!! nenhum evento casado")
    print(f"conferência evento a evento: n {len(erros)}, erro (medido − esperado) p05 "
          f"{np.percentile(erros, 5):+.2f} ms, p50 {np.median(erros):+.2f}, p95 "
          f"{np.percentile(erros, 95):+.2f}, máx |{np.abs(erros).max():.2f}| ms")
    ok = abs(np.median(erros)) <= 1.0 and np.percentile(np.abs(erros), 95) <= 2.0
    print("CONFERE" if ok else "NÃO CONFERE")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gerar")
    g.add_argument("dir")
    g.add_argument("--semente", type=int, required=True)
    g.add_argument("--segundos", type=float, default=70.0)
    g.add_argument("--fps", type=float, default=30.0)
    c = sub.add_parser("conferir")
    c.add_argument("relato")
    c.add_argument("verdade")
    c.add_argument("prefixo")
    c.add_argument("--deslocar-ms", type=float, default=0.0)
    a = ap.parse_args()
    if a.cmd == "gerar":
        gerar(a)
        return 0
    return conferir(a)


if __name__ == "__main__":
    sys.exit(main())
