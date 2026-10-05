#!/usr/bin/env python3
"""Mede a ordem dos campos de um .dv pela sequência (roda no Mac, com o ffmpeg e o numpy).

Com T_n = campo de cima do quadro n e B_n = campo de baixo:
- campo de baixo primeiro (BFF): os tempos são B_n = 2n, T_n = 2n+1. Então B_{n+1} está a 1 campo de
  T_n, e T_{n+1} está a 3 campos de B_n;
- campo de cima primeiro (TFF): o contrário.

R = média|B_{n+1} − T_n| / média|T_{n+1} − B_n|, no luma, com o campo de baixo interpolado para as
linhas do de cima. R < 1 quer dizer BFF; R > 1, TFF; perto de 1, sem movimento para decidir. Por
quadro, a contagem de quadros que votam em cada ordem (só os que têm movimento).

    ordem-dos-campos.py arquivo.dv [...]
"""
import subprocess
import sys

import numpy as np

W, H = 720, 480


def quadros(dv: str) -> np.ndarray:
    cru = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "dv", "-i", dv,
                          "-map", "0:v", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(cru, np.uint8).reshape(-1, H, W).astype(np.float32)


def main() -> None:
    for dv in sys.argv[1:]:
        q = quadros(dv)
        topo = q[:, 0::2, :]   # linhas 0, 2, ... (240)
        baixo = q[:, 1::2, :]  # linhas 1, 3, ...
        # baixo nas posições do topo: a linha 2i fica entre as de baixo 2i-1 e 2i+1
        b_no_topo = baixo.copy()
        b_no_topo[:, 1:, :] = (baixo[:, :-1, :] + baixo[:, 1:, :]) / 2
        n = len(q) - 1
        d_bff = np.abs(b_no_topo[1:] - topo[:-1]).mean(axis=(1, 2))  # |B_{n+1} - T_n|
        d_tff = np.abs(topo[1:] - b_no_topo[:-1]).mean(axis=(1, 2))  # |T_{n+1} - B_n|
        mov = (d_bff + d_tff) / 2
        com_mov = mov > 2.0
        votos_bff = int(np.sum((d_bff < d_tff) & com_mov))
        votos_tff = int(np.sum((d_tff < d_bff) & com_mov))
        r = d_bff[com_mov].mean() / d_tff[com_mov].mean() if com_mov.any() else float("nan")
        print(f"{dv}: {n} pares, {int(com_mov.sum())} com movimento; "
              f"média|B(n+1)-T(n)|={d_bff[com_mov].mean():.2f} média|T(n+1)-B(n)|={d_tff[com_mov].mean():.2f} "
              f"R={r:.3f} → {'BFF' if r < 1 else 'TFF'}; votos BFF={votos_bff} TFF={votos_tff}")


if __name__ == "__main__":
    main()
