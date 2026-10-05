#!/usr/bin/env python3
"""Gera um Annex-B H.264 de **origem sintética nossa** com N fatias por quadro.

    tools/origem-fatiada.py --saida /tmp/fatiado8.h264 --fatias 8
    tools/origem-fatiada.py --saida /tmp/fatiado8.h264 --fatias 8 --largura 720 --altura 1520

## Por que ele existe

`docs/idr-pequeno.md` provou que **nenhum encoder Android da bancada fatia**: `KEY_INTRA_REFRESH_PERIOD`
vira período de quadro-chave no A10s e é ecoado-e-ignorado no A07, e a chave de fornecedor
`vendor.mtk.ext.venc.wfd.slice-count` é aceita e ignorada nos dois braços medidos. Logo a pergunta
*"o `MediaCodec` decodifica uma unidade de acesso a que falta fatia?"* não pode ser feita com um
fluxo produzido no próprio aparelho — não há como produzi-lo lá. A origem multifatia tem de vir de
fora, e a resposta é sobre o **decodificador**: de que codificador vieram os bytes não muda a
política dele. É o mesmo argumento que `apps/macos/Sources/sonda-fatias/main.swift` escreve para o
`--fluxo` externo.

## A origem, e por que é um mosaico de semente fixa

O mesmo mosaico de `AnimatedContentView.denso` (Android) e de `quadroDenso` (macOS): blocos de 8x8
com valor de um gerador congruencial de semente fixa, mais uma barra clara que anda com o número do
quadro. As duas razões são regra desta casa:

- `docs/regras-de-frente.md` — *"o arquivo de vídeo não carrega no nome o que tem dentro"*. Nenhum
  pixel de tela de ninguém entra aqui, o que importa em dobro nesta frente: ela é a única
  autorizada a **olhar** o quadro decodificado, e só pode olhar porque a origem é nossa.
- **Antes e depois só se comparam com a mesma origem.** Semente fixa dá o mesmo arquivo, byte a
  byte, em qualquer máquina com o mesmo x264.

O fundo liso da origem animada padrão comprimiria a quase nada e o IDR sairia com meia dúzia de
pacotes — longe do regime de ~60 pacotes que atravessa o joelho de `docs/idr-que-sobrevive.md`.

## O portão: o arquivo só é entregue se o artefato tiver as fatias pedidas

*"A plataforma aceitou" não é "a plataforma fez"* vale também para o x264. Este roteiro roda
`tools/fatias.py` sobre o que saiu e **falha** se a contagem de fatias do IDR não for a pedida.
`tools/fatias.py` é o instrumento aferido em oito casos, um deles exatamente contra o x264.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
FATIAS = RAIZ / "tools" / "fatias.py"

# O mesmo gerador de `quadroDenso` (macOS) e de `AnimatedContentView.denso` (Android).
SEMENTE = 0x5DEECE66D
MASCARA = (1 << 48) - 1
LADO = 8


def quadro_denso(largura: int, altura: int, n: int) -> bytes:
    """Um quadro I420: mosaico de blocos de 8x8 mais uma barra que anda.

    A barra existe para o encoder não degenerar em quadros P vazios — sem movimento nenhum, o
    bitrate depois do primeiro IDR cai a nada e a comparação não diz nada.
    """
    semente = SEMENTE
    y = bytearray(largura * altura)
    by = 0
    while by < altura:
        bx = 0
        while bx < largura:
            semente = (semente * SEMENTE + 0xB) & MASCARA
            v = 16 + ((semente >> 16) % 220)
            largura_do_bloco = min(LADO, largura - bx)
            linha = bytes([v]) * largura_do_bloco
            for dy in range(min(LADO, altura - by)):
                off = (by + dy) * largura + bx
                y[off:off + largura_do_bloco] = linha
            bx += LADO
        by += LADO
    x0 = (n * 17) % max(1, largura - 40)
    barra = bytes([235]) * 40
    for lin in range(altura):
        off = lin * largura + x0
        y[off:off + 40] = barra
    # Croma neutro: a pergunta desta origem é de luminância, e um croma constante deixa o plano Y
    # ser o único sinal — o que torna a estatística de banda da sonda legível.
    uv = bytes([128]) * (largura * altura // 4)
    return bytes(y) + uv + uv


def gerar(saida: Path, largura: int, altura: int, fatias: int, quadros: int, fps: int,
          gop: int) -> None:
    if shutil.which("ffmpeg") is None:
        sys.exit("!! ffmpeg não está no PATH — ele é quem carrega o libx264 aqui")
    cru = b"".join(quadro_denso(largura, altura, n) for n in range(quadros))
    parametros = ":".join([
        f"slices={fatias}",
        f"keyint={gop}",
        f"min-keyint={gop}",
        "scenecut=0",
        "bframes=0",
        # CABAC desligado e perfil baseline: é o que `profile-level-id=42e028` do `fmtp` deste
        # projeto promete, e o contrato não é desta frente para mexer.
        "cabac=0",
        "repeat-headers=1",
    ])
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "yuv420p",
        "-s", f"{largura}x{altura}", "-r", str(fps), "-i", "-",
        "-c:v", "libx264", "-profile:v", "baseline", "-preset", "veryfast",
        "-x264-params", parametros,
        "-f", "h264", "-y", str(saida),
    ]
    subprocess.run(cmd, input=cru, check=True)


def conferir(saida: Path, fatias: int) -> dict:
    """Roda `tools/fatias.py` sobre o artefato. Falha se o IDR não tiver as fatias pedidas."""
    r = subprocess.run([sys.executable, str(FATIAS), "--json", str(saida)],
                       capture_output=True, text=True, check=True)
    resumo = json.loads(r.stdout)[0]
    if resumo["idrs"] < 1:
        sys.exit("!! o artefato não tem IDR nenhum")
    obtidas = sorted(int(k) for k in resumo["fatias_por_quadro"])
    if obtidas != [fatias]:
        sys.exit(f"!! pedi {fatias} fatias e o artefato saiu com {obtidas} — "
                 "não entrego artefato que não é o que diz ser")
    return resumo


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--saida", required=True, type=Path)
    p.add_argument("--fatias", type=int, default=8)
    p.add_argument("--largura", type=int, default=720)
    p.add_argument("--altura", type=int, default=1520)
    p.add_argument("--quadros", type=int, default=12)
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--gop", type=int, default=12)
    a = p.parse_args()

    a.saida.parent.mkdir(parents=True, exist_ok=True)
    gerar(a.saida, a.largura, a.altura, a.fatias, a.quadros, a.fps, a.gop)
    resumo = conferir(a.saida, a.fatias)
    print(f"{a.saida} — {a.largura}x{a.altura}, {resumo['bytes']} B, "
          f"{resumo['quadros']} quadros, {resumo['idrs']} IDR")
    print(f"  fatias/quadro {resumo['fatias_por_quadro']} · "
          f"IDR em {resumo['pacotes_do_idr']['max']} pacotes · "
          f"maior fatia {resumo['maior_fatia_pacotes']['max']} pacote(s)")
    print("  conferido por tools/fatias.py — o instrumento aferido, não o retorno do ffmpeg")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
