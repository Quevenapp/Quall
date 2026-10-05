#!/usr/bin/env python3
"""O tom em degraus da S-A6, para outro aparelho tocar em laço perto do S24.

Um ciclo de 26 s: 2 s de silêncio e seis degraus de 3 s, de 0 a -30 dB em passos de -6 dB
(o degrau de 0 dB fica a -6 dBFS no arquivo, para o alto-falante não saturar), cada um seguido de
1 s de silêncio. Rampas de 10 ms nas bordas. WAV mono, 48 kHz, 16 bits. Sintético: nenhum som
captado entra aqui.

    python3 tools/sonda-r5/android/gera-degraus.py --saida /tmp/quall-exemplo
    afplay degraus.wav     # ou qualquer reprodutor em laço; a S-A6 grava 30 s por fonte
"""
import argparse
import math
import struct
import wave

TAXA = 48_000


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--saida", required=True)
    ap.add_argument("--hz", type=float, default=1000.0)
    ap.add_argument("--ciclos", type=int, default=4, help="ciclos de 26 s no arquivo (padrão 4 = 104 s)")
    a = ap.parse_args()

    rampa = int(0.010 * TAXA)
    amostras: list[int] = []

    def silencio(s: float) -> None:
        amostras.extend([0] * int(s * TAXA))

    def tom(s: float, db: float) -> None:
        n = int(s * TAXA)
        amp = 0.5 * 10 ** (db / 20)
        for i in range(n):
            env = min(1.0, i / rampa, (n - 1 - i) / rampa)
            amostras.append(int(round(32767 * amp * env * math.sin(2 * math.pi * a.hz * i / TAXA))))

    for _ in range(a.ciclos):
        silencio(2.0)
        for k in range(6):
            tom(3.0, -6.0 * k)
            silencio(1.0)

    with wave.open(a.saida, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TAXA)
        w.writeframes(struct.pack(f"<{len(amostras)}h", *amostras))
    print(f"{a.saida}: {len(amostras) / TAXA:.1f} s, {a.hz:g} Hz, {a.ciclos} ciclo(s) de 26 s")


if __name__ == "__main__":
    main()
