#!/usr/bin/env python3
"""Gera uma origem de vídeo **sintética nossa** (`.h264` + sidecar) para `quall-probe emitir-video`.

## Por que existe

A frente do caminho de saída precisava rodar `quall-probe` MacBook → A10s para tirar o Windows da
equação, e `emitir-video` exige o par do `docs/contrato-sidecar.md`. O repositório não versiona
`.h264` nenhum, e toda captura de bancada que existia tinha origem numa tela de trabalho — que é
material do usuário e não pode ser aberto, renderizado nem gravado (`docs/regras-de-frente.md`).

Aqui a origem é `testsrc2` do libavfilter: um padrão sintético gerado pelo próprio ffmpeg. Não há
restrição de privacidade nenhuma sobre este arquivo — é a mesma distinção que faz `prova-laco.ps1`
manter `--salvar` e `prova-rede.ps1` não.

## O que ele fixa, e por quê

Os padrões reproduzem a **forma de tráfego** da sessão Dell → A10s medida em 29/08: 1274x716 (o
teto), ~24 fps, ~1,15 Mbps e um IDR a cada ~44 quadros. A comparação que a frente quer fazer é
"a mesma forma de tráfego, sem o Windows no caminho" — e forma de tráfego é taxa de pacotes e
tamanho de pacote, não resolução nominal.

O script imprime, ao final, a **contagem exata de pacotes RTP** que a libdatachannel vai numerar
para este arquivo, pela mesma regra de `quall_core::track::pacotes_da_unidade` (que **não** é
`ceil(bytes/1188)`). É esse número que se compara com o da sessão do Windows para saber se os dois
braços põem a mesma coisa no fio.

## A fonte leve deixou de ser a única, em 03/09/2026

Por duas semanas **toda** medição de carga desta bancada usou o `testsrc2` acima, e em 02/09 a
primeira câmera real mostrou o tamanho do buraco: o padrão põe **161,8 pacotes/s** no fio, e as
câmeras de `docs/bancada.md` põem de **422 a ~1700**. Cor chapada parada é de graça para o x264 —
congelando o primeiro quadro em laço, 5 s de `testsrc2` custam **6,8 %** do animado —, e a predição
inter tira mais da metade do resto. Não era um detalhe de realismo: era medir o codificador
acertando, e chamar isso de medir o enlace.

Daí `--gerador`. Os nomes de [`GERADORES`] foram medidos a CRF 23 fixo, 1920x1080@30, baseline,
`keyint=60`, e o que separa um do outro é **quanto o quadro anterior ajuda a prever o próximo**:

| gerador | tamanho a CRF 23 | contra o `testsrc2` |
|---|---|---|
| `movimento-real` (life) | 19.384.386 B | **7,9x** |
| `camera-forte` (testsrc2 + ruído) | 13.661.972 B | 5,6x |
| `camera` (mandelbrot + hue + ruído) | 4.236.891 B | 1,7x |
| `testsrc2` | 2.451.193 B | 1x |

`life` é o único em que codificar tudo como quadro-chave sai **menor** que com GOP: o quadro
anterior não ajuda. Essa é a definição operacional de movimento real, e é por isso que ele está
aqui e `rotate` não — girar o `testsrc2` **alivia** o codificador (0,714x), porque a interpolação
retira informação em vez de acrescentar.

**Toda semente é fixada.** `life`, `cellauto` e `noise` sorteiam o estado inicial quando ninguém
manda (`random_seed` e `all_seed` nascem em -1), e uma origem que muda a cada corrida não é origem
de bancada. Os presets cravam a semente; um grafo passado à mão é responsabilidade de quem passa.

## O `-level` era 3.1 e o SDP anuncia 4.0

Até 03/09/2026 este script cravava `-level 3.1` com um comentário dizendo que isso casava o
`PERFIL_H264`. Não casava: `42e028` é `0x28` = 40 = **nível 4.0** desde 01/09. No padrão de
1274x716 o erro não aparecia — 3600 macroblocos cabem nos dois —, mas a 1080p o x264 escrevia
`level_idc=31` descrevendo 8160 macroblocos contra o `MaxFS` 3600 daquele nível, avisava três vezes
e ninguém via, porque o script rodava com `-loglevel error`.

O conserto não é trocar um literal por outro: o nível agora sai de [`nivel_do_sdp`], que lê
`crates/quall-core/src/track.rs` pelo mesmo caminho que `quall_core::teto::nivel_anunciado` — o
número mora num lugar só, e quem mudar o `fmtp` não precisa lembrar deste arquivo. E o ffmpeg
passou a rodar em `-loglevel warning`, para o próximo aviso aparecer.

## Uso

    tools/fonte-sintetica.py --saida /tmp/fonte --segundos 60
    # produz /tmp/fonte/sintetico.h264 e /tmp/fonte/sintetico.json

    # a fonte pesada, no teto do produto para 1080p30 (docs/bancada.md)
    tools/fonte-sintetica.py --saida /tmp/pesada --segundos 60 --gerador camera \
        --largura 1920 --altura 1080 --fps 30 --kbps 9000 --gop 60 --fatias 4

    # um grafo qualquer do libavfilter, com {largura} {altura} {fps} substituídos
    tools/fonte-sintetica.py --saida /tmp/x --gerador 'mandelbrot=size={largura}x{altura}:rate={fps}'
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

MAX_FRAGMENTO = 1188

# Uma semente só para tudo que sorteia, e ela é a data em que a fonte pesada entrou.
SEMENTE = 20260903

RAIZ = Path(__file__).resolve().parent.parent

GERADORES = {
    "testsrc2": {
        "grafo": "testsrc2=size={largura}x{altura}:rate={fps}",
        "preset": "screen",
        "sobre": "o padrão do libavfilter: cor chapada e movimento previsível — a fonte LEVE",
    },
    "camera": {
        "grafo": ("mandelbrot=size={largura}x{altura}:rate={fps},"
                  "hue=h=t*40,noise=alls=8:allf=t+u:all_seed=" + str(SEMENTE)),
        "preset": "camera",
        "sobre": "detalhe fino que se renova, mais grão — a linha de câmera calma da bancada",
    },
    "camera-forte": {
        "grafo": ("testsrc2=size={largura}x{altura}:rate={fps},"
                  "noise=alls=20:allf=t+u:all_seed=" + str(SEMENTE)),
        "preset": "camera",
        "sobre": "ruído temporal forte: nada se prevê do quadro anterior, tudo custa bits",
    },
    "movimento-real": {
        "grafo": ("life=size={largura}x{altura}:rate={fps}:mold=10:ratio=0.1:"
                  "random_seed=" + str(SEMENTE) + ":life_color=#dcdcdc:death_color=#202020"),
        "preset": "camera",
        "sobre": "o mais pesado medido: a predição inter PIORA o arquivo em 15,8 %",
    },
    "idr-pesado": {
        "grafo": ("cellauto=size={largura}x{altura}:rate={fps}:rule=30:ratio=0.5:"
                  "random_seed=" + str(SEMENTE) + ":scroll=1:full=0"),
        "preset": "camera",
        "sobre": "quadro-chave gigante e quadros P quase de graça: para estressar o joelho do IDR",
    },
}


def nivel_do_sdp() -> str:
    """O nível H.264 que o projeto anuncia, lido de `crates/quall-core/src/track.rs`.

    Mesmo caminho de `quall_core::teto::nivel_anunciado`: os seis dígitos de `profile-level-id`
    são `profile_idc`, bits de restrição e `level_idc`, e é o último byte que interessa. Ler em vez
    de repetir é o ponto — um `-level` cravado aqui já mentiu por dois dias.
    """
    texto = (RAIZ / "crates/quall-core/src/track.rs").read_text()
    m = re.search(r"profile-level-id=([0-9a-fA-F]{6})", texto)
    if not m:
        raise SystemExit("não achei profile-level-id em crates/quall-core/src/track.rs")
    idc = int(m.group(1)[4:6], 16)
    return f"{idc // 10}.{idc % 10}"


def pacotes_do_nal(tam: int) -> int:
    """Fragmentos que um NAL de `tam` bytes produz em `NalUnit::generateFragments` da 0.23.2.

    Espelha `quall_core::track::pacotes_do_nal`. A biblioteca calcula `n = ceil(tam/1188)`,
    reparte em `m = ceil(tam/n)`, **subtrai 2** (indicador + cabeçalho FU-A) e só então corta a
    carga (`tam - 1`, sem o cabeçalho do NAL). Isso frequentemente dá um fragmento a mais que a
    conta ingênua `ceil(tam/1188)`.
    """
    if tam <= 0:
        return 0
    if tam <= MAX_FRAGMENTO:
        return 1
    n = -(-tam // MAX_FRAGMENTO)
    m = -(-tam // n) - 2
    if m <= 0:
        return n
    return -(-(tam - 1) // m)


def nals_annexb(dados: bytes) -> list[int]:
    """Tamanhos dos NALs, do jeito que `H264RtpPacketizer::splitFrame` divide com StartSequence."""
    inicios = []
    i = 0
    n = len(dados)
    while i + 3 <= n:
        if dados[i] == 0 and dados[i + 1] == 0 and dados[i + 2] == 1:
            inicios.append(i + 3)
            i += 3
        else:
            i += 1
    tamanhos = []
    for k, ini in enumerate(inicios):
        if k + 1 < len(inicios):
            fim = inicios[k + 1] - 3
            if fim > ini and dados[fim - 1] == 0:
                fim -= 1
        else:
            fim = n
        tamanhos.append(max(0, fim - ini))
    return tamanhos


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--saida", required=True, help="diretório onde gravar o par")
    p.add_argument("--nome", default="sintetico")
    p.add_argument("--segundos", type=int, default=60)
    p.add_argument("--largura", type=int, default=1274)
    p.add_argument("--altura", type=int, default=716)
    p.add_argument("--fps", type=int, default=24)
    p.add_argument("--kbps", type=int, default=1150)
    p.add_argument("--gop", type=int, default=44)
    # **Fatias por quadro, e isto é o que casa a FORMA de tráfego.** O MFT do Dell emite mais de
    # um NAL de fatia por quadro: a sessão Dell → A10s põe ~10 pacotes RTP por quadro no fio,
    # enquanto o x264 de fatia única, no mesmo bitrate e no mesmo fps, põe ~6,6. Como cada NAL é
    # fragmentado por si, dividir o quadro em fatias **aumenta** a contagem de pacotes sem mexer
    # em bitrate nem em fps — que é exatamente a variável que se quer casar.
    p.add_argument("--fatias", type=int, default=1)
    # O que se põe na entrada do codificador. Um nome de `GERADORES` ou um grafo do libavfilter
    # inteiro, com `{largura}`, `{altura}` e `{fps}` substituídos. O padrão continua sendo o
    # `testsrc2` de sempre, de propósito: mudar o default mudaria em silêncio a origem de
    # `apps/macos/Bancada/provar-receptor.sh`, que chama este script sem geometria nenhuma.
    p.add_argument("--gerador", default="testsrc2",
                   help="nome de GERADORES (%s) ou um grafo lavfi" % ", ".join(GERADORES))
    # O botão que controla o tamanho da rajada de IDR sem mexer na taxa média. Estava amarrado em
    # 2x kbps, que é justamente a variável que a campanha precisa perseguir separada.
    p.add_argument("--bufsize-kbps", type=int, default=None,
                   help="padrão: 2x --kbps")
    p.add_argument("--preset", choices=["screen", "camera"], default=None,
                   help="padrão: o do gerador escolhido")
    # **O nível do SDP não descreve 1080p60 nem 4K.** `42e028` é 4.0, cujo `MaxMBPS` cobre 1080p
    # a 30 e não a 60, e cujo `MaxFS` nem cabe 4K. Um aparelho de verdade escreve no SPS o nível
    # do que codifica (o `MediaCodec` escolhe 4.2 ou 5.2 sozinho), e um decodificador de hardware
    # pode recusar um SPS que declara 4.0 com 32 400 macroblocos por quadro. Para imitar a origem
    # real nessas geometrias o nível tem de poder ser dito.
    p.add_argument("--nivel", default=None,
                   help="nível H.264 do SPS (ex.: 4.2, 5.2); padrão: o do SDP")
    a = p.parse_args()

    escolhido = GERADORES.get(a.gerador)
    grafo = (escolhido["grafo"] if escolhido else a.gerador).format(
        largura=a.largura, altura=a.altura, fps=a.fps)
    preset = a.preset or (escolhido["preset"] if escolhido else "camera")
    bufsize = a.bufsize_kbps if a.bufsize_kbps is not None else 2 * a.kbps
    nivel = a.nivel or nivel_do_sdp()

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        print("preciso de ffmpeg e ffprobe no PATH", file=sys.stderr)
        return 1

    destino = Path(a.saida)
    destino.mkdir(parents=True, exist_ok=True)
    h264 = destino / f"{a.nome}.h264"
    sidecar = destino / f"{a.nome}.json"

    # `-profile:v baseline` e o `-level` de `nivel_do_sdp` casam com o `PERFIL_H264` que o SDP
    # anuncia — o nível é LIDO, não repetido. `bframes=0` vem junto do baseline; `scenecut=0`
    # mantém o GOP fixo, senão o tamanho do IDR passaria a depender do conteúdo e a forma de
    # tráfego deixaria de ser fixa. `-loglevel warning` para o x264 poder reclamar em voz alta.
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "lavfi", "-i", grafo,
        "-t", str(a.segundos),
        "-c:v", "libx264", "-profile:v", "baseline", "-level", nivel,
        "-pix_fmt", "yuv420p",
        "-b:v", f"{a.kbps}k", "-maxrate", f"{a.kbps}k", "-bufsize", f"{bufsize}k",
        "-x264-params", f"keyint={a.gop}:min-keyint={a.gop}:scenecut=0:repeat-headers=1:slices={a.fatias}",
        "-f", "h264", str(h264),
    ]
    subprocess.run(cmd, check=True)

    # `-show_packets` sobre o elementary stream devolve uma entrada por unidade de acesso, com o
    # tamanho em bytes e a bandeira `K` para quadro-chave. A soma dos tamanhos **tem** de bater
    # com o arquivo: é a mesma conferência que `Sidecar::carregar` faz do lado Rust, e é o que
    # permite fatiar o `.h264` sem interpretar H.264.
    r = subprocess.run(
        ["ffprobe", "-hide_banner", "-loglevel", "error", "-select_streams", "v:0",
         "-show_packets", "-of", "json", str(h264)],
        check=True, capture_output=True, text=True,
    )
    pacotes = json.loads(r.stdout)["packets"]

    quadros = []
    intervalo_us = 1_000_000 // a.fps
    for i, q in enumerate(pacotes):
        quadros.append({
            "number": i,
            # O carimbo do ffprobe pode repetir em stream cru; o contrato exige `timestamp_us`
            # estritamente crescente, e a cadência é a nominal de qualquer jeito.
            "timestamp_us": i * intervalo_us,
            "bytes": int(q["size"]),
            "idr": "K" in q.get("flags", ""),
            # O contrato exige o campo e o validador cobra o tipo, mas **não houve captura**: esta
            # origem sai de um arquivo, não de um sensor. Zero aqui quer dizer "não existe", e não
            # "foi instantâneo". `quall-probe` não lê o campo (`crates/quall-probe/src/video.rs`).
            "encode_latency_us": 0,
        })

    soma = sum(q["bytes"] for q in quadros)
    tamanho = h264.stat().st_size
    if soma != tamanho:
        print(f"a soma dos pacotes ({soma}) não bate com o arquivo ({tamanho}); "
              "o sidecar descreveria outro arquivo", file=sys.stderr)
        return 1
    if not quadros or not quadros[0]["idr"]:
        print("o primeiro quadro não é IDR e o contrato exige que seja", file=sys.stderr)
        return 1

    sidecar.write_text(json.dumps({
        "header": {
            "width": a.largura, "height": a.altura, "target_fps": a.fps,
            "preset": preset,
            "capture_api": f"lavfi {a.gerador} (origem sintética, sem captura de tela)",
            "encoder": "libx264", "encoder_is_hardware": False,
            "target_bitrate_bps": a.kbps * 1000, "gop_frames": a.gop,
            "color_range": "limited", "video_file": h264.name,
        },
        "frames": quadros,
    }, indent=1))

    # A forma de tráfego, que é o que se compara entre braços.
    dados = h264.read_bytes()
    desloc = 0
    total_pac = 0
    pac_por_quadro = []
    for q in quadros:
        au = dados[desloc:desloc + q["bytes"]]
        desloc += q["bytes"]
        n = sum(pacotes_do_nal(t) for t in nals_annexb(au))
        pac_por_quadro.append(n)
        total_pac += n
    dur = len(quadros) / a.fps
    origem_do_nivel = "--nivel" if a.nivel else "de PERFIL_H264"
    print(f"gerador {a.gerador!r}  nível {nivel} ({origem_do_nivel})  preset {preset}  "
          f"bufsize {bufsize}k")
    print(f"{h264}  {tamanho} B")
    print(f"{sidecar}  {len(quadros)} quadros ({sum(1 for q in quadros if q['idr'])} IDR), "
          f"{dur:.1f} s")
    print(f"forma no fio: {total_pac} pacotes RTP  =  {total_pac / dur:.1f} pacotes/s  "
          f"|  {8 * tamanho / dur / 1000:.0f} kbps  |  {total_pac / len(quadros):.2f} pacotes/quadro")
    idr = [n for n, q in zip(pac_por_quadro, quadros) if q["idr"]]
    nao = [n for n, q in zip(pac_por_quadro, quadros) if not q["idr"]]
    if idr:
        print(f"  IDR: {min(idr)}–{max(idr)} pacotes   não-IDR: {min(nao)}–{max(nao)} pacotes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
