#!/usr/bin/env python3
"""A **forma que uma sessão põe no fio**, medida do par `.h264` + `.json` — sem rádio e sem sessão.

## Por que existe

`docs/idr-que-sobrevive.md` mede a curva de sobrevivência do quadro por tamanho de rajada com UDP
puro, e mede **zero** perda em quadros de 21 pacotes. No mesmo dia, uma sessão do Quall com uma
origem *"cujos quadros quase todos têm 21 pacotes"* perdeu 7,9 a 8,4 %. Os dois números não podem
estar os dois certos sobre a mesma coisa, e a explicação mais barata era a premissa: **"21 pacotes"
é uma mediana, e a cauda de uma distribuição não é a mediana dela.**

Conferir isso não precisa de bancada nenhuma. A origem daquela sessão é sintética e o par
`.h264` + `.json` do `docs/contrato-sidecar.md` descreve quadro a quadro o que foi mandado. Este
roteiro lê os dois e responde, **pela regra exata do pacotizador**, quantos pacotes cada quadro
vira no fio — e a que taxa de pacotes por segundo o conjunto sai.

## Privacidade

Lê **contadores**, nunca pixels: só os comprimentos dos NAL e os campos do sidecar. Não decodifica,
não renderiza e não grava quadro nenhum. Roda em qualquer par, inclusive num que tenha vindo de
captura de tela — nada do conteúdo atravessa.

## A regra do pacotizador, e por que não é o teto da divisão

`crates/quall-core/src/track.rs::pacotes_da_unidade` reproduz `NalUnit::generateFragments` da
libdatachannel, e ela **não** é `ceil(tam / 1188)`:

    n = ceil(tam / MAX_FRAGMENTO);  m = ceil(tam / n) - 2;  pacotes = ceil((tam - 1) / m)

A subtração de 2 é o cabeçalho de FU-A, e ela empurra o resultado para cima em quase todo tamanho.
E a conta é **por NAL**, não por unidade de acesso: um IDR com SPS + PPS + fatia vira
`1 + 1 + fragmentos(fatia)`. Usar o teto da divisão sobre a unidade inteira subestima — foi o que
este roteiro fez na primeira versão, e a aferição contra a corrida de campo pegou.

## Aferição

    tools/forma-da-sessao.py --aferir

Três casos, e o terceiro é o que vale:

1. os dois casos fixados nos testes de unidade de `track.rs` (`pacotes_do_nal(17200) == 16` e a
   unidade de acesso `[27, 8, 17200]` == 18 pacotes);
2. um NAL de um byte, que é o degrau onde `m` poderia zerar;
3. **o caso conhecido desta bancada**: a corrida de campo de 31/08 (`/tmp/sonda-1.txt`) mandou
   **2105 quadros** desta origem em laço e o emissor relatou **47 919 pacotes entregues à
   libdatachannel**. Reproduzir esse número exato, a partir só do arquivo, é a prova de que a
   regra aqui é a regra que roda.

Se o par do caso conhecido não estiver na máquina, a aferição **não** imprime `PASSA`: imprime
`INCOMPLETO` e sai com 2. Os dois primeiros blocos conferem a aritmética contra o que o autor
imaginou; só o terceiro a confere contra o que de fato saiu no fio, e um instrumento que passa sem
ele é aritmética conferida contra si mesma. `--caso-conhecido` aponta outro par.

## Uso

    tools/forma-da-sessao.py --sidecar /tmp/fonte-agitada.json
    tools/forma-da-sessao.py --sidecar /tmp/fonte-agitada.json --quadros-enviados 2105
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

MAX_FRAGMENTO = 1188


def pacotes_do_nal(tam: int) -> int:
    """`crates/quall-core/src/track.rs::pacotes_do_nal`, byte a byte."""
    if tam == 0:
        return 0
    if tam <= MAX_FRAGMENTO:
        return 1
    n = -(-tam // MAX_FRAGMENTO)
    m = max(0, -(-tam // n) - 2)
    if m == 0:
        return n
    return -(-(tam - 1) // m)


def nals_annexb(dados: bytes) -> list[int]:
    """Os comprimentos dos NAL, como `H264RtpPacketizer::splitFrame` com `StartSequence`.

    Aceita prefixo de 3 **ou** de 4 bytes; o último NAL vai até o fim do buffer.
    """
    inicios: list[int] = []
    i = 0
    n = len(dados)
    while i + 3 <= n:
        if dados[i] == 0 and dados[i + 1] == 0 and dados[i + 2] == 1:
            inicios.append(i + 3)
            i += 3
        else:
            i += 1
    tamanhos: list[int] = []
    for k, ini in enumerate(inicios):
        fim = n if k + 1 == len(inicios) else inicios[k + 1] - 3
        # Um prefixo de 4 bytes é um de 3 com um zero na frente: ele pertence ao próximo NAL.
        if fim > ini and dados[fim - 1] == 0:
            fim -= 1
        tamanhos.append(max(0, fim - ini))
    return tamanhos


def pacotes_da_unidade(annexb: bytes) -> int:
    return sum(pacotes_do_nal(t) for t in nals_annexb(annexb))


def aferir(conhecido: Path) -> int:
    falhas = 0
    pulou = False

    def confere(nome: str, obtido, esperado) -> None:
        nonlocal falhas
        ok = obtido == esperado
        falhas += 0 if ok else 1
        print(f"  [{'PASSA' if ok else 'REPROVA'}] {nome}: {obtido} (esperado {esperado})")

    print("aferição 1 — os casos fixados nos testes de unidade de track.rs")
    confere("pacotes_do_nal(17200)", pacotes_do_nal(17200), 16)
    # `au(&[27, 8, 17200])` do teste `idr_com_parametros`: SPS + PPS + fatia grande.
    au = b"".join(b"\x00\x00\x00\x01" + b"\x41" * t for t in (27, 8, 17200))
    confere("pacotes_da_unidade(SPS+PPS+fatia)", pacotes_da_unidade(au), 18)
    confere("nals_annexb dá três NAL", nals_annexb(au), [27, 8, 17200])

    print("aferição 2 — os degraus")
    confere("pacotes_do_nal(0)", pacotes_do_nal(0), 0)
    confere("pacotes_do_nal(1)", pacotes_do_nal(1), 1)
    confere("pacotes_do_nal(1188)", pacotes_do_nal(1188), 1)
    confere("pacotes_do_nal(1189)", pacotes_do_nal(1189), 3)

    print("aferição 3 — o caso conhecido: a corrida de campo de 31/08")
    sidecar = conhecido
    if not sidecar.exists():
        pulou = True
        print(f"  [PULA] {sidecar} não está aqui — regenere com `gerar-fonte.swift --agitacao 20"
              " --bitrate 6000000 --largura 720 --altura 1520`, ou aponte outro par com"
              " --caso-conhecido")
    else:
        por_quadro = medir(sidecar)[0]
        # As duas corridas de `/tmp/sonda-1.txt` e `/tmp/sonda-2.txt` relataram, as duas,
        # `quadros enviados: 2105` e `PACOTES ENTREGUES À libdatachannel: 47919`, com o arquivo
        # em laço. A conta que reproduz esse número **exato**, e ela não é 2105 quadros seguidos:
        #
        # - `quadros enviados` conta os envios que deram certo. Um deles não é do laço: é o IDR
        #   reenviado por PLI (`crates/quall-probe/src/video.rs`, `idrs_forcados`), que o laço
        #   **insere** sem consumir índice. Logo o laço andou 2104 quadros, não 2105;
        # - o PLI chegou na abertura, quando `ultimo_idr` ainda era 0 — então o quadro reenviado
        #   é o **quadro 0**, o IDR de abertura, o maior do arquivo.
        #
        # 2104 quadros do laço + o quadro 0 de novo. Se este número deixar de bater, ou a regra
        # do pacotizador mudou ou o laço do emissor mudou — as duas coisas que este roteiro
        # presume e não pode presumir calado.
        laco = sum(por_quadro[i % len(por_quadro)] for i in range(2104))
        confere("2104 quadros do laço + o IDR de abertura reenviado por PLI",
                laco + por_quadro[0], 47919)

    print()
    if falhas:
        print("REPROVA")
        return 1
    if pulou:
        # `docs/regras-de-frente.md`: instrumento não aferido contra caso conhecido não é
        # instrumento. Os casos sintéticos conferem a aritmética contra o que eu mesmo imaginei;
        # só o caso conhecido confere a regra contra o que de fato saiu no fio. Sem ele isto não
        # pode imprimir a mesma palavra que imprime com ele.
        print("INCOMPLETO — os casos sintéticos passam, mas o CASO CONHECIDO não rodou.")
        print("Isto não é um instrumento aferido; é aritmética conferida contra si mesma.")
        return 2
    print("PASSA")
    return 0


def medir(sidecar: Path) -> tuple[list[int], dict]:
    """Devolve (pacotes por quadro, cabeçalho)."""
    d = json.loads(sidecar.read_text())
    h264 = sidecar.parent / d["header"]["video_file"]
    if not h264.exists():
        sys.exit(f"não achei {h264}, que o sidecar diz descrever")
    dados = h264.read_bytes()
    soma = sum(f["bytes"] for f in d["frames"])
    if soma != len(dados):
        sys.exit(f"o sidecar não descreve este arquivo: soma={soma} arquivo={len(dados)}")
    por_quadro: list[int] = []
    pos = 0
    for f in d["frames"]:
        por_quadro.append(pacotes_da_unidade(dados[pos:pos + f["bytes"]]))
        pos += f["bytes"]
    return por_quadro, d


def quantil(v: list[int], p: float) -> int:
    s = sorted(v)
    return s[min(len(s) - 1, int(p * len(s)))]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sidecar", help="o .json do par; o .h264 vem do campo video_file")
    p.add_argument("--quadros-enviados", type=int,
                   help="quantos quadros a corrida mandou, com o arquivo em laço")
    p.add_argument("--aferir", action="store_true")
    p.add_argument("--caso-conhecido", default="/tmp/fonte-agitada.json",
                   help="o par da corrida de campo de 31/08, contra o qual a aferição 3 confere")
    a = p.parse_args()
    if a.aferir:
        return aferir(Path(a.caso_conhecido))
    if not a.sidecar:
        p.error("dê --sidecar ou --aferir")

    por_quadro, d = medir(Path(a.sidecar))
    h = d["header"]
    idr = [n for n, f in zip(por_quadro, d["frames"]) if f["idr"]]
    comum = [n for n, f in zip(por_quadro, d["frames"]) if not f["idr"]]
    fps = h["target_fps"]
    total = sum(por_quadro)

    print(f"origem      : {h['video_file']}  {h['width']}x{h['height']} @ {fps} fps, "
          f"alvo {h['target_bitrate_bps'] / 1e6:.1f} Mb/s, GOP {h['gop_frames']}")
    print(f"quadros     : {len(por_quadro)} ({len(idr)} IDR)")
    print(f"TODOS       : p50={quantil(por_quadro, .5)} p90={quantil(por_quadro, .9)} "
          f"p99={quantil(por_quadro, .99)} máx={max(por_quadro)} "
          f"média={total / len(por_quadro):.1f} pacotes")
    if idr:
        print(f"IDR         : p50={quantil(idr, .5)} p90={quantil(idr, .9)} máx={max(idr)}")
    if comum:
        print(f"comum       : p50={quantil(comum, .5)} p90={quantil(comum, .9)} "
              f"p99={quantil(comum, .99)} máx={max(comum)}")

    n = a.quadros_enviados or len(por_quadro)
    pac = sum(por_quadro[i % len(por_quadro)] for i in range(n))
    dur = n / fps
    print()
    print(f"o que isso põe no fio, em {n} quadros ({dur:.1f} s a {fps} fps):")
    print(f"  pacotes            : {pac}")
    print(f"  TAXA DE PACOTES    : {pac / dur:.0f} pacotes/s")
    print(f"  média por quadro   : {pac / n:.1f} pacotes")

    print()
    faixas = [(0, 20), (21, 35), (36, 39), (40, 49), (50, 59), (60, 83), (84, 119), (120, 1 << 30)]
    print(f"{'faixa (pacotes)':<16}{'quadros':>9}{'%':>8}{'pacotes':>10}{'% pacotes':>11}")
    for lo, hi in faixas:
        s = [t for t in por_quadro if lo <= t <= hi]
        nome = f"{lo}-{hi}" if hi < (1 << 29) else f"{lo}+"
        print(f"{nome:<16}{len(s):>9}{100 * len(s) / len(por_quadro):>7.1f}%"
              f"{sum(s):>10}{100 * sum(s) / total:>10.1f}%")
    grandes = [t for t in por_quadro if t >= 40]
    print()
    print(f"quadros de 40+ pacotes (acima do joelho de docs/idr-que-sobrevive.md): "
          f"{len(grandes)} de {len(por_quadro)} = {100 * len(grandes) / len(por_quadro):.1f}% "
          f"dos quadros, {100 * sum(grandes) / total:.1f}% dos pacotes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
