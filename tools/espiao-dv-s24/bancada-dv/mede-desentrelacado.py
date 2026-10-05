#!/usr/bin/env python3
"""Mede os modos do desentrelaçador com números, não de olho (roda no Mac).

Para cada modo (weave, bob, adapt, adapt2 com variações), roda o dv-bancada do Mac com -Y e mede
três coisas:
- **pente residual** nas gravações com movimento (a Panasonic mexida e a mão na frente). É o
  número de pixels, por mil, das linhas reconstruídas que saem do intervalo vertical das
  vizinhas por mais de 20 códigos de luma. Os "pontinhos" e "fiapos" do adaptativo são isso:
  pixel do campo velho deixado onde o novo mostra outra coisa. O weave dá o teto e o bob, perto
  de zero;
- **detalhe na cena parada** (amostra-1): PSNR do luma contra o weave, que é a verdade numa cena
  parada. O bob perde a resolução vertical;
- **fonte conhecida** (testsrc2 entrelaçado em BFF): PSNR do luma contra a origem do campo novo;
- **movimento real com verdade conhecida**: a gravação 4:3 com a mão, levada a 59,94 progressivo
  pelo bwdif do ffmpeg (`sintetico/real43-60p.yuv`), entrelaçada de novo em BFF e codificada em DV
  (`sintetico/real43.dv`). Contra a origem do campo novo: PSNR e **erro grosso**, os pixels por mil
  com |erro| > 40. É a medida independente dos pontinhos: não sai da própria regra do pente;
- **pente fraco** nas gravações com movimento: por mil, onde a média do pente em x±3 passa de 3
  códigos. É o pente de baixo contraste (listras numa área escura) que o pente > 20 não vê.

    mede-desentrelacado.py <dv-bancada-mac> <dir fase-a>
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

W, H, CW = 720, 480, 180
TAM = W * H + 2 * CW * H

MODOS = [
    ("weave", ["-d", "weave"]),
    ("bob", ["-d", "bob"]),
    ("adapt", ["-d", "adapt"]),
    ("adapt2 P16 R0", ["-d", "adapt2", "-J", "0", "-P", "16", "-R", "0"]),
    ("adapt2 J3 P3 R0", ["-d", "adapt2", "-J", "3", "-P", "3", "-R", "0"]),
]


def luma(arq: Path) -> np.ndarray:
    d = np.fromfile(arq, np.uint8)
    n = len(d) // TAM
    return np.stack([d[i * TAM:i * TAM + W * H].reshape(H, W) for i in range(n)]).astype(np.int16)


def pente_por_mil(y: np.ndarray) -> float:
    o = y[:, 1:-1:2, :]
    a = y[:, 0:-2:2, :]
    b = y[:, 2::2, :]
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    p = np.maximum(o - hi, lo - o)
    return 1000.0 * float((p > 20).mean())


def pente_fraco_por_mil(y: np.ndarray, janela: int = 3, limiar: float = 3.0) -> float:
    """O pente de baixo contraste que o olho vê numa área escura: a média do pente em x±3 > 3."""
    o = y[:, 1:-1:2, :]
    a = y[:, 0:-2:2, :]
    b = y[:, 2::2, :]
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    p = np.maximum(np.maximum(o - hi, lo - o), 0).astype(np.float32)
    k = 2 * janela + 1
    c = np.cumsum(np.pad(p, ((0, 0), (0, 0), (janela + 1, janela))), axis=2)
    media = (c[:, :, k:] - c[:, :, :-k]) / k
    return 1000.0 * float((media > limiar).mean())


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(((a.astype(np.float64) - b) ** 2).mean())
    return 99.0 if mse == 0 else 10 * np.log10(255 * 255 / mse)


def roda(bancada: str, dv: Path, args: list, saida: Path) -> np.ndarray:
    subprocess.run([bancada, "-i", str(dv), "-o", str(saida.parent / "png-lixo"), "-p", "1", "-q",
                    "999", "-Y", str(saida)] + args, check=True, capture_output=True)
    return luma(saida)


def main() -> None:
    bancada, fa = sys.argv[1], Path(sys.argv[2])
    trab = fa / "mede-des"
    trab.mkdir(exist_ok=True)
    fonte = np.fromfile(fa / "sintetico" / "fonte-60p.yuv", np.uint8)
    nf = len(fonte) // TAM
    fonte_y = np.stack([fonte[i * TAM:i * TAM + W * H].reshape(H, W) for i in range(nf)]).astype(np.int16)
    weave_parado = None
    real = np.fromfile(fa / "sintetico" / "real43-60p.yuv", np.uint8)
    nr = len(real) // TAM
    real_y = np.stack([real[i * TAM:i * TAM + W * H].reshape(H, W) for i in range(nr)]).astype(np.int16)
    print(f"{'modo':16s} {'pente 16:9':>11s} {'pente 4:3':>10s} {'parado vs weave':>16s} {'sintético':>10s}"
          f" {'real PSNR':>10s} {'real grosso':>12s} {'fraco 16:9':>11s} {'fraco 4:3':>10s}")
    for nome, args in MODOS:
        m169 = roda(bancada, fa / "movimento-169.dv", args, trab / "m169.yuv")[1:]
        m43 = roda(bancada, fa / "movimento-43.dv", args, trab / "m43.yuv")[1:]
        p169, p43 = pente_por_mil(m169), pente_por_mil(m43)
        f169, f43 = pente_fraco_por_mil(m169), pente_fraco_por_mil(m43)
        parado = roda(bancada, fa / "amostra-1.dv", args, trab / "parado.yuv")
        if weave_parado is None:
            weave_parado = parado.copy()
        pp = psnr(parado[1:], weave_parado[1:])
        sint = roda(bancada, fa / "sintetico" / "sint.dv", args, trab / "sint.yuv")
        ps = np.mean([psnr(sint[q], fonte_y[2 * q + 1]) for q in range(1, len(sint))])
        r = roda(bancada, fa / "sintetico" / "real43.dv", args, trab / "real.yuv")
        pr = np.mean([psnr(r[q], real_y[2 * q + 1]) for q in range(1, len(r))])
        grosso = np.mean([1000.0 * float((np.abs(r[q] - real_y[2 * q + 1]) > 40).mean()) for q in range(1, len(r))])
        print(f"{nome:16s} {p169:11.2f} {p43:10.2f} {pp:16.2f} {ps:10.2f} {pr:10.2f} {grosso:12.3f} {f169:11.2f} {f43:10.2f}")


if __name__ == "__main__":
    main()
