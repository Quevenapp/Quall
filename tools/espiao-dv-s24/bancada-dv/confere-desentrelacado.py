#!/usr/bin/env python3
"""Controle do desentrelaçador com fonte conhecida (roda no Mac).

Gera 240 quadros progressivos a 59,94 (testsrc2, em movimento), entrelaça em campo de baixo primeiro
e codifica em DV com o ffmpeg. Depois roda o dv-bancada do Mac nos três modos e mede o PSNR do luma
de cada saída contra os dois quadros de origem: o do campo de baixo (2n, o mais velho) e o do campo
de cima (2n+1, o mais novo). O desentrelaçador certo fica mais perto do 2n+1.

    confere-desentrelacado.py <dv-bancada-mac> <dir de trabalho>
"""
import math
import subprocess
import sys
from pathlib import Path

W, H, CW = 720, 480, 180
TAM = W * H + 2 * CW * H


def psnr(a: bytes, b: bytes) -> float:
    mse = sum((x - y) ** 2 for x, y in zip(a, b)) / len(a)
    return 99.0 if mse == 0 else 10 * math.log10(255 * 255 / mse)


def main() -> None:
    bancada, trabalho = sys.argv[1], Path(sys.argv[2])
    trabalho.mkdir(parents=True, exist_ok=True)
    fonte, dv = trabalho / "fonte-60p.yuv", trabalho / "sint.dv"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=720x480:rate=60000/1001,format=yuv411p", "-frames:v", "240",
                    "-f", "rawvideo", "-y", str(fonte)], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt",
                    "yuv411p", "-s", "720x480", "-r", "60000/1001", "-i", str(fonte), "-vf",
                    "interlace=scan=bff:lowpass=0,setfield=bff", "-c:v", "dvvideo", "-pix_fmt",
                    "yuv411p", "-aspect", "16:9", "-f", "dv", "-y", str(dv)], check=True)
    src = fonte.read_bytes()
    for modo in ("weave", "bob", "adapt"):
        saida = trabalho / f"des-{modo}.yuv"
        r = subprocess.run([bancada, "-i", str(dv), "-o", str(trabalho / "png"), "-p", "1", "-q", "999",
                            "-d", modo, "-Y", str(saida)], check=True, capture_output=True, text=True)
        linhas = [l for l in r.stdout.splitlines() if "VAUX" in l or "desentrela" in l]
        d = saida.read_bytes()
        n = len(d) // TAM
        velho = novo = 0.0
        amostras = range(2, n, 7)
        for q in amostras:
            y = d[q * TAM:q * TAM + W * H]
            velho += psnr(y, src[(2 * q) * TAM:(2 * q) * TAM + W * H])
            novo += psnr(y, src[(2 * q + 1) * TAM:(2 * q + 1) * TAM + W * H])
        k = len(amostras)
        print(f"{modo:5s}: PSNR Y contra o campo velho (2n) {velho / k:.2f} dB, "
              f"contra o novo (2n+1) {novo / k:.2f} dB  | {' | '.join(linhas)}")


if __name__ == "__main__":
    main()
