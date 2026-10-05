#!/usr/bin/env python3
"""PSNR e SSIM do que sai do decodificador contra a origem, quadro a quadro, com p50 e p05.

═══════════════════════════════════════════════════════════════════════════════════════════
 PROIBIÇÃO, e ela não é formalidade: **NUNCA aponte este instrumento para material cuja
 origem seja captura de tela de qualquer máquina do usuário.**

 Este é o primeiro instrumento do projeto que **abre pixels** — decodifica um `.h264` e olha
 o conteúdo dele. Todos os outros medem por contador. `docs/regras-de-frente.md` registra o
 dia em que uma frente abriu um quadro de um `.h264` de bancada e encontrou o WhatsApp Web do
 usuário e nomes de contato: "o arquivo de vídeo não carrega no nome o que tem dentro".

 A origem aqui é padrão sintético nosso — `testsrc2` do libavfilter, gerado por este próprio
 script. É a mesma distinção que faz `prova-laco.ps1` manter `--salvar` e `prova-rede.ps1`
 perdê-lo. `--origem-externa` existe para o caso de outra frente gerar a origem sintética por
 fora, e **exige** que quem chama afirme a procedência: se você não sabe de onde o arquivo
 veio, a resposta é não medir.

 Se o que você quer medir foi capturado de uma tela — do MacBook, do Dell, de um celular do
 usuário —, este script é a ferramenta errada. Meça por contador.
═══════════════════════════════════════════════════════════════════════════════════════════

## Por que existe

Este projeto mediu perda, latência, fps, tamanho de quadro e nível de H.264, e **nunca mediu
qualidade de imagem**. A pergunta ficou viva na noite de 28/08: a quinta porta faz o emissor
do Dell mandar **1,2 Mbps** onde sem ela mandaria **3,7**, e **9.089 bytes por quadro
não-IDR contra 16.293**. Bits são insumo, não qualidade — mas um terço dos bits é indício
suficiente para a pergunta existir, e sem número ela não se decide.

## O que ele mede, e onde ele corta

Três pontos da cadeia, e a graça está em compará-los:

    testsrc2  ──►  x264  ──►  [ quall-core · RTP/RFC 6184 · SRTP · libdatachannel ]  ──►  .h264
    (referência)   (origem)                    (a cadeia)                            (recebido)
         │            │                                                                   │
         └──── PSNR/SSIM ────┘  «só o codificador»                                        │
         └────────────────────────── PSNR/SSIM ────────────────────────────────────────────┘
                                                            «depois da cadeia»

- **só o codificador** responde a pergunta da quinta porta: quanto custa em qualidade mandar
  um terço dos bits. Não passa por rede nenhuma;
- **depois da cadeia** acrescenta o que a nossa pilha faz com aquilo. Num laço local sem
  perda os dois números têm de ser **iguais** — e essa igualdade é a prova de que a cadeia é
  transparente e de que toda a degradação medida é do codificador. Quando eles divergirem,
  a diferença é nossa.

O decodificador é o do ffmpeg (software), **não** o VideoToolbox, o MediaFoundation nem o
MediaCodec. Um H.264 conforme decodifica igual nos quatro — mas isso é norma, não medição, e
está na lista do que este instrumento não prova.

## p05, e não a média

Em vídeo, o pior caso importa mais que o caso típico: um quadro que desmancha é o que a
pessoa vê. `p05` é o 5º percentil — 5 % dos quadros estão **abaixo** dele. Para PSNR e SSIM,
maior é melhor, então o percentil baixo é a cauda ruim.

## Uso

    # a corrida de calibração inteira (3 taxas, laço local, ~4 min):
    tools/qualidade-de-imagem.py --saida /tmp/qualidade --segundos 20 --kbps 3700 1200 200

    # só o codificador, sem subir sessão nenhuma (rápido, e não toca em rede):
    tools/qualidade-de-imagem.py --saida /tmp/q --segundos 10 --kbps 1200 --sem-cadeia

    # a pergunta da quinta porta, quando o Dell estiver livre: gere a origem aqui, leve o
    # par .h264/.json para a máquina que emite, traga o recebido de volta e meça com
    tools/qualidade-de-imagem.py --saida /tmp/q --medir-recebido /tmp/recebido.h264 \\
        --referencia /tmp/qualidade/referencia.mkv --origem-externa "testsrc2 gerado aqui"

O relatório sai em texto na saída padrão e em `<saida>/qualidade.json`.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
PROBE = RAIZ / "target" / "release" / "quall-probe"

MAX_FRAGMENTO = 1188


# ─────────────────────────── contagem de pacotes (espelha o núcleo) ───────────────────────


def pacotes_do_nal(tam: int) -> int:
    """Fragmentos de um NAL em `NalUnit::generateFragments` da libdatachannel 0.23.2.

    Cópia deliberada de `tools/fonte-sintetica.py`, que por sua vez espelha
    `quall_core::track::pacotes_do_nal`. Copiado em vez de importado porque
    `fonte-sintetica.py` é usado por outra frente e não se mexe nele: um `import` por
    `importlib` amarraria os dois scripts sem necessidade. Se a regra mudar no núcleo, os
    três lugares mudam juntos — e o teste que a fixa é do núcleo.
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
    """Tamanhos dos NALs, como `H264RtpPacketizer::splitFrame` divide com StartSequence."""
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


# ───────────────────────────────────── ferramentas ────────────────────────────────────────


def rodar(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RuntimeError(
            f"falhou: {' '.join(str(c) for c in cmd)}\n{r.stderr.strip()[-2000:]}"
        )
    return r


def contar_quadros(caminho: Path) -> int:
    r = rodar([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-count_frames", "-show_entries", "stream=nb_read_frames",
        "-of", "default=nk=1:nw=1", str(caminho),
    ])
    return int(r.stdout.strip().splitlines()[0])


# ─────────────────────────────────── origem sintética ─────────────────────────────────────


def gerar_referencia(destino: Path, largura: int, altura: int, fps: int, segundos: int) -> Path:
    """A referência: `testsrc2` gravado **sem perda** (ffv1), em `yuv420p`.

    Por que um arquivo, e não gerar `testsrc2` de novo na hora de comparar: o `testsrc2` é
    determinístico, mas depender disso é depender de um detalhe do libavfilter que ninguém
    fixou. Com o arquivo, a referência e a origem codificada saem **dos mesmos pixels**, e
    isso é verificável (`ffv1` é sem perda por definição).

    `yuv420p` aqui e não no encode: converter uma vez, antes, tira a conversão de espaço de
    cor de dentro da medição. Se a referência fosse RGB, parte do PSNR seria do arredondamento
    da conversão e não do codificador.
    """
    ref = destino / "referencia.mkv"
    rodar([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc2=size={largura}x{altura}:rate={fps}",
        "-t", str(segundos),
        "-pix_fmt", "yuv420p", "-c:v", "ffv1", "-level", "3",
        str(ref),
    ])
    return ref


def codificar(ref: Path, destino: Path, kbps: int, fps: int, gop: int, fatias: int) -> tuple[Path, Path]:
    """Codifica a referência em `.h264` Annex-B + sidecar do `docs/contrato-sidecar.md`.

    Os parâmetros do x264 são os de `tools/fonte-sintetica.py`, de propósito: é a origem que
    a bancada já usa para casar a **forma de tráfego** da sessão do Dell. `scenecut=0` mantém
    o GOP fixo — sem isso o tamanho do IDR passaria a depender do conteúdo e dois braços de
    taxas diferentes não seriam mais comparáveis.
    """
    h264 = destino / f"origem-{kbps}k.h264"
    sidecar = destino / f"origem-{kbps}k.json"
    rodar([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(ref),
        "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.1",
        "-pix_fmt", "yuv420p",
        "-b:v", f"{kbps}k", "-maxrate", f"{kbps}k", "-bufsize", f"{2 * kbps}k",
        "-x264-params",
        f"keyint={gop}:min-keyint={gop}:scenecut=0:repeat-headers=1:slices={fatias}",
        "-f", "h264", str(h264),
    ])

    r = rodar([
        "ffprobe", "-hide_banner", "-loglevel", "error", "-select_streams", "v:0",
        "-show_packets", "-of", "json", str(h264),
    ])
    pacotes = json.loads(r.stdout)["packets"]
    intervalo_us = 1_000_000 // fps
    quadros = [{
        "number": i,
        "timestamp_us": i * intervalo_us,
        "bytes": int(q["size"]),
        "idr": "K" in q.get("flags", ""),
    } for i, q in enumerate(pacotes)]

    soma = sum(q["bytes"] for q in quadros)
    if soma != h264.stat().st_size:
        raise RuntimeError(
            f"a soma dos pacotes ({soma}) não bate com {h264} ({h264.stat().st_size}); "
            "o sidecar descreveria outro arquivo"
        )
    if not quadros or not quadros[0]["idr"]:
        raise RuntimeError("o primeiro quadro não é IDR e o contrato exige que seja")

    largura, altura = medidas(ref)
    sidecar.write_text(json.dumps({
        "header": {
            "width": largura, "height": altura, "target_fps": fps, "preset": "screen",
            "capture_api": "lavfi testsrc2 (origem sintética, sem captura de tela)",
            "encoder": "libx264", "encoder_is_hardware": False,
            "target_bitrate_bps": kbps * 1000, "gop_frames": gop,
            "color_range": "limited", "video_file": h264.name,
        },
        "frames": quadros,
    }, indent=1))

    # A forma no fio, pela regra exata da libdatachannel — para que este braço possa ser
    # comparado com os das outras frentes sem refazer a conta.
    dados = h264.read_bytes()
    desloc = 0
    total = 0
    for q in quadros:
        au = dados[desloc:desloc + q["bytes"]]
        desloc += q["bytes"]
        total += sum(pacotes_do_nal(t) for t in nals_annexb(au))
    dur = len(quadros) / fps
    print(f"    origem {kbps} kbps: {h264.stat().st_size} B, {len(quadros)} quadros, "
          f"{8 * h264.stat().st_size / dur / 1000:.0f} kbps reais, "
          f"{total / dur:.1f} pacotes RTP/s, {total / len(quadros):.2f} pacotes/quadro")
    return h264, sidecar


def medidas(caminho: Path) -> tuple[int, int]:
    r = rodar([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", str(caminho),
    ])
    largura, altura = r.stdout.strip().splitlines()[0].split("x")
    return int(largura), int(altura)


# ──────────────────────────────────── o laço local ────────────────────────────────────────


def laco_local(sidecar: Path, saida: Path, porta: int, pin: str, segundos: int,
               registros: Path) -> Path:
    """Uma sessão inteira do Quall **dentro do MacBook**: emissor e receptor no mesmo host.

    Isto não é rede: os dois processos falam por `127.0.0.1`, e é a mesma coisa que
    `docs/app-macos.md` faz nas corridas de bancada do app. Nenhum byte sai da máquina, e
    nenhuma medição de outra frente é contaminada.

    O que atravessa é a cadeia de verdade: `quall-core`, a pacotização RFC 6184 da
    libdatachannel, DTLS/SRTP e a remontagem de `rtp.rs`. O que **não** atravessa é o ar —
    e é por isso que este braço mede o codificador limpo, sem perda por cima.
    """
    registros.mkdir(parents=True, exist_ok=True)
    reg_emissor = registros / f"emissor-{porta}.txt"
    reg_receptor = registros / f"receptor-{porta}.txt"

    with reg_emissor.open("w") as f:
        emissor = subprocess.Popen(
            [str(PROBE), "emitir-video", "--entrada", str(sidecar),
             "--porta", str(porta), "--pin", pin, "--sem-mdns"],
            stdout=f, stderr=subprocess.STDOUT,
        )

    try:
        pronto = False
        for _ in range(60):
            time.sleep(0.5)
            if "esperando um receptor" in reg_emissor.read_text(errors="replace"):
                pronto = True
                break
            if emissor.poll() is not None:
                break
        if not pronto:
            raise RuntimeError(
                f"o emissor não chegou a escutar; veja {reg_emissor}"
            )

        with reg_receptor.open("w") as f:
            r = subprocess.run(
                [str(PROBE), "receber-video", "--ip", f"127.0.0.1:{porta}", "--pin", pin,
                 "--sem-mdns", "--segundos", str(segundos), "--saida", str(saida)],
                stdout=f, stderr=subprocess.STDOUT, timeout=segundos + 180,
            )
        if r.returncode != 0:
            raise RuntimeError(f"o receptor falhou; veja {reg_receptor}")
    finally:
        try:
            emissor.wait(timeout=20)
        except subprocess.TimeoutExpired:
            emissor.kill()

    texto = reg_receptor.read_text(errors="replace")
    for chave in ("quadros gravados", "pacotes vistos", "pacotes faltando", "PERDA EXATA"):
        for linha in texto.splitlines():
            if chave in linha:
                print("      " + linha.strip())
                break
    return saida


SONDA_MACOS = RAIZ / "apps" / "macos" / ".build" / "release" / "sonda-qualidade"


def codificar_no_macos(ref: Path, destino: Path, fps: int) -> tuple[Path, Path]:
    """Codifica a referência com o **encoder do produto no macOS**: `H264Encoder`/VideoToolbox.

    Este é o braço que fecha parte da lacuna "o emissor do macOS nunca foi provado ponta a
    ponta". Ele não tem `--kbps`: quem decide a taxa é o preset do produto
    (`CapturePreset.screen`), e o ponto é medir **o emissor que existe**, não um emissor
    parametrizado para a ocasião.

    A origem crua vai em NV12 porque é o formato que o `H264Encoder` recebe da captura de
    verdade (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`). A conversão de `yuv420p` para
    `nv12` é só o entrelaçamento do croma — **aferida aqui como exata**: o `.nv12` comparado
    de volta com a referência dá PSNR infinito em todos os quadros.
    """
    if not SONDA_MACOS.exists():
        raise RuntimeError(
            f"falta {SONDA_MACOS}. Rode:\n"
            "  cd apps/macos && swift build -c release --product sonda-qualidade"
        )
    largura, altura = medidas(ref)
    cru = destino / "origem.nv12"
    rodar([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(ref),
        "-pix_fmt", "nv12", "-f", "rawvideo", str(cru),
    ])
    prefixo = destino / "origem-macos"
    r = rodar([
        str(SONDA_MACOS), "--entrada", str(cru), "--saida", str(prefixo),
        "--largura", str(largura), "--altura", str(altura), "--fps", str(fps),
    ])
    for linha in r.stdout.splitlines():
        if linha.strip():
            print("    " + linha.rstrip())
    cru.unlink(missing_ok=True)
    return Path(f"{prefixo}.h264"), Path(f"{prefixo}.json")


# ──────────────────────────── o IDR reenviado por PLI ─────────────────────────────────────


def unidades_de_acesso(caminho: Path) -> list[bytes]:
    """Fatia um Annex-B em unidades de acesso, pelas fronteiras que o `ffprobe` já sabe achar.

    Sem interpretar H.264: as posições vêm de `-show_packets`, e a soma dos tamanhos tem de
    fechar com o arquivo — a mesma conferência que `Sidecar::carregar` faz do lado Rust.
    """
    r = rodar([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
        "-of", "json", str(caminho),
    ])
    tamanhos = [int(x["size"]) for x in json.loads(r.stdout)["packets"]]
    dados = caminho.read_bytes()
    aus, desloc = [], 0
    for n in tamanhos:
        aus.append(dados[desloc:desloc + n])
        desloc += n
    if desloc != len(dados):
        raise RuntimeError(
            f"{caminho}: as unidades de acesso somam {desloc} B e o arquivo tem {len(dados)}"
        )
    return aus


def tirar_idr_reenviado(recebido: Path, trabalho: Path, rotulo: str) -> tuple[Path, int]:
    """Remove os IDR que o emissor **reenviou** por pedido do receptor (PLI/FIR).

    # Por que isto existe, e por que não é maquiagem

    Um receptor que entra numa sessão pede um quadro-chave — é o comportamento correto dele,
    é o que as quatro cascas fazem, e é o que faz a imagem aparecer sem esperar o GOP. O
    emissor responde reenviando `ultimo_idr`, **o mesmo access unit, byte a byte**
    (`quall-probe`: `leitor.quadro(ultimo_idr, &sidecar)`).

    Medido no laço local de 6 s a 1.200 kbps: a origem tem 144 unidades e o recebido tem
    **145**, com `pedidos de IDR (PLI/FIR): 1` e `IDR forçados por pedido: 1` no relatório do
    emissor. A unidade de índice 1 é **byte a byte igual** à de índice 0.

    Esse quadro a mais não é degradação: é o mesmo quadro entregue duas vezes, e um
    decodificador o exibe duas vezes sem estranhar. Mas ele desloca **todo** o resto do fluxo
    em uma posição, e o emparelhamento por índice passaria a comparar o quadro *k* com o
    *k+1* — o que produziria uma queda enorme de PSNR que não tem nada a ver com qualidade. É
    o mesmo modo de falha do carimbo de tempo, por outra porta.

    A regra reproduz exatamente o que o emissor faz: uma unidade é reenvio quando é **igual,
    byte a byte, ao último IDR já aceito**. Igualdade byte a byte é forte de propósito — dois
    quadros codificados de conteúdo diferente não colidem — e a contagem de removidos sai no
    relatório para que ninguém confunda "alinhei" com "escondi".

    Pressuposto declarado: a origem é sintética e **muda em todo quadro**. Numa tela parada,
    dois quadros seguidos podem legitimamente codificar para os mesmos bytes, e aí esta regra
    descartaria conteúdo. Não é o caso de `testsrc2`, e não deve ser usado onde seja.
    """
    aus = unidades_de_acesso(recebido)
    ultimo_idr: bytes | None = None
    mantidas: list[bytes] = []
    removidas = 0
    for au in aus:
        if ultimo_idr is not None and au == ultimo_idr:
            removidas += 1
            continue
        mantidas.append(au)
        # Um IDR carrega o NAL tipo 5; SPS/PPS vêm colados no mesmo access unit. Basta
        # reconhecer que o access unit contém um NAL de IDR para lembrá-lo como candidato a
        # reenvio.
        if contem_idr(au):
            ultimo_idr = au
    if removidas == 0:
        return recebido, 0
    limpo = trabalho / f"{rotulo}-sem-idr-reenviado.h264"
    limpo.write_bytes(b"".join(mantidas))
    return limpo, removidas


def contem_idr(au: bytes) -> bool:
    """Se a unidade de acesso tem um NAL de IDR (tipo 5). Start code de 3 e de 4 bytes."""
    i = 0
    n = len(au)
    while i + 3 <= n:
        if au[i] == 0 and au[i + 1] == 0 and au[i + 2] == 1:
            if i + 3 < n and (au[i + 3] & 0x1F) == 5:
                return True
            i += 3
        else:
            i += 1
    return False


# ────────────────────────────────── PSNR e SSIM ───────────────────────────────────────────


def por_quadro(distorcido: Path, referencia: Path, trabalho: Path, rotulo: str,
               fps: int) -> dict:
    """PSNR e SSIM quadro a quadro de `distorcido` contra `referencia`.

    Duas passadas em vez de uma: os filtros `psnr` e `ssim` do ffmpeg consomem os dois
    fluxos, e encadear os dois numa passada exige `split` dos dois lados — mais peças para
    dar errado do que rodar duas vezes um arquivo de 20 s.

    # O emparelhamento é por **índice**, e isto foi medido, não escolhido por gosto

    Os dois filtros casam os quadros pelo `framesync`, que é **por carimbo de tempo**. A
    referência é Matroska, e a especificação do Matroska guarda carimbo em **milissegundo
    inteiro**: a 24 fps os quadros caem em 0, 42, 83, 125, 167… enquanto o `.h264` cru tem
    base 1/1200000 e cai em 0; 41,667; 83,333; 125… O arredondamento erra de lado a cada três
    quadros, e o `framesync` passa a comparar o quadro *k* com o *k+1*.

    O sintoma, medido aqui: um `.h264` codificado com `-qp 0` — **sem perda**, o mesmo
    arquivo — dava `inf` em dois de cada três quadros e **25,6 dB** no terceiro. Uma
    codificação sem perda não pode degradar quadro nenhum; o número era do relógio. Com o
    emparelhamento errado, o p05 de 3.700 kbps dava 24,16 dB e o de 200 kbps dava 24,23 —
    **o instrumento dizia que a taxa não importa para o pior caso**, que é exatamente a
    conclusão que ele existe para não deixar alguém tirar de graça.

    `settb=1/fps,setpts=N` põe os dois fluxos em carimbos inteiros iguais ao número do
    quadro: 0, 1, 2… O emparelhamento passa a ser posição contra posição, sem arredondamento
    no meio. [`calibrar`] afere isso a cada corrida.

    # O rótulo de cor, e o segundo número que era do metadado e não da imagem

    O `psnr` do ffmpeg negocia formato entre os dois fluxos, e quando os **rótulos de cor**
    diferem ele insere uma conversão de matriz. O rótulo não é o mesmo nos dois lados por um
    motivo legítimo: o `RemendoDeSPS` do emissor do macOS **escreve** o VUI (é a dívida que
    ele existe para pagar), então o fluxo dele sai marcado `bt709`/faixa de vídeo, enquanto a
    referência `ffv1` sai com `colorspace=unknown`.

    Medido: o emissor do macOS a 4 Mbps dava **PSNR 22,36 dB com SSIM 0,974** — combinação
    impossível, porque um erro que derruba o PSNR em 27 dB não deixa a estrutura intacta. Era
    a conversão de matriz. Comparando os planos crus, sem rótulo nenhum dos dois lados, o
    mesmo arquivo dá **46,71 dB**. Vinte e quatro decibéis de diferença, e nenhum deles vinha
    da imagem.

    `setparams` **rotula sem converter**. Aplicado igual nos dois lados, os fluxos passam a
    ter o mesmo rótulo, a negociação não insere escalador nenhum e o que se compara são as
    amostras como estão gravadas — que é o que a pergunta pede. Se algum dia for preciso medir
    a conversão de espaço de cor, ela é outra medição, com outro instrumento.

    **A checagem de contagem é obrigatória, não zelo.** Com o emparelhamento por índice, um
    quadro a menos no meio desloca tudo que vem depois. Se a cadeia tiver descartado um
    quadro, o número mediria o deslocamento e não a qualidade.
    """
    n_dist = contar_quadros(distorcido)
    n_ref = contar_quadros(referencia)
    if n_dist != n_ref:
        raise RuntimeError(
            f"[{rotulo}] {n_dist} quadros contra {n_ref} da referência. Os filtros comparam "
            "posição a posição: com contagens diferentes o número mediria o desalinhamento, "
            "não a qualidade. Alinhe (ou reporte a perda) antes de medir."
        )

    # `setparams` **rotula**, não converte — e é exatamente por isso que ele está aqui.
    # Ver a nota "O rótulo de cor" no cabeçalho desta função.
    rotulo_de_cor = ("setparams=range=tv:colorspace=bt709:"
                     "color_primaries=bt709:color_trc=bt709,format=yuv420p")
    alinhar = (f"[0:v]{rotulo_de_cor},settb=1/{fps},setpts=N[a];"
               f"[1:v]{rotulo_de_cor},settb=1/{fps},setpts=N[b];[a][b]")
    log_psnr = trabalho / f"psnr-{rotulo}.log"
    log_ssim = trabalho / f"ssim-{rotulo}.log"
    for filtro, log in (("psnr", log_psnr), ("ssim", log_ssim)):
        rodar([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(distorcido), "-i", str(referencia),
            "-lavfi", f"{alinhar}{filtro}=stats_file={log}",
            "-f", "null", "-",
        ])

    psnr = []
    for linha in log_psnr.read_text().splitlines():
        m = re.search(r"psnr_y:(\S+)", linha)
        if m:
            psnr.append(float("inf") if m.group(1) == "inf" else float(m.group(1)))
    ssim = []
    for linha in log_ssim.read_text().splitlines():
        m = re.search(r"\bAll:(\S+)", linha)
        if m:
            ssim.append(float(m.group(1)))

    if len(psnr) != n_ref or len(ssim) != n_ref:
        raise RuntimeError(
            f"[{rotulo}] o filtro produziu {len(psnr)} linhas de PSNR e {len(ssim)} de SSIM "
            f"para {n_ref} quadros"
        )
    return {
        "quadros": n_ref,
        "psnr_y": resumo(psnr),
        "ssim": resumo(ssim),
        "psnr_por_quadro": psnr,
        "ssim_por_quadro": ssim,
    }


def calibrar(ref: Path, trabalho: Path, fps: int) -> dict:
    """Afere o instrumento contra o **caso conhecido** antes de ele medir qualquer coisa.

    O caso conhecido é uma codificação H.264 **sem perda** (`-qp 0`) da própria referência.
    Ela tem de dar PSNR infinito e SSIM 1,0 em **todos** os quadros: erro zero é a única
    resposta certa quando não houve erro. Qualquer outra coisa é defeito do instrumento — e
    já foi: ver o porquê do emparelhamento por índice em [`por_quadro`].

    Um instrumento que não foi aferido contra um caso conhecido não é instrumento, então isto
    roda a cada corrida e **aborta** quando falha. Custa alguns segundos.
    """
    sem_perda = trabalho / "calibracao-sem-perda.h264"
    rodar([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(ref),
        "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-f", "h264", str(sem_perda),
    ])
    m = por_quadro(sem_perda, ref, trabalho, "calibracao", fps)

    ruins_psnr = [i for i, v in enumerate(m["psnr_por_quadro"]) if not math.isinf(v)]
    ruins_ssim = [i for i, v in enumerate(m["ssim_por_quadro"]) if v < 0.999999]
    if ruins_psnr or ruins_ssim:
        raise RuntimeError(
            "CALIBRAÇÃO FALHOU. Uma codificação sem perda tem de dar PSNR infinito e SSIM 1,0 "
            f"em todos os {m['quadros']} quadros, e deu erro em {len(ruins_psnr)} (PSNR) e "
            f"{len(ruins_ssim)} (SSIM). Os primeiros: PSNR {ruins_psnr[:6]}, SSIM "
            f"{ruins_ssim[:6]}. Enquanto isto não fechar, nenhum número deste script vale — "
            "quase certamente os quadros estão sendo emparelhados errado."
        )
    print(f"    calibração: {m['quadros']}/{m['quadros']} quadros com PSNR ∞ e SSIM 1,0 "
          "sobre uma codificação sem perda — o instrumento não inventa erro")
    return {"quadros": m["quadros"], "psnr_infinito_em_todos": True, "ssim_um_em_todos": True}


def percentil(valores: list[float], p: float) -> float:
    """Percentil por interpolação linear. `inf` sobrevive: quadro sem erro é sem erro."""
    if not valores:
        return float("nan")
    v = sorted(valores)
    if len(v) == 1:
        return v[0]
    pos = (len(v) - 1) * p
    baixo = math.floor(pos)
    alto = math.ceil(pos)
    if baixo == alto:
        return v[baixo]
    if math.isinf(v[baixo]) or math.isinf(v[alto]):
        return v[baixo]
    return v[baixo] + (v[alto] - v[baixo]) * (pos - baixo)


def resumo(valores: list[float]) -> dict:
    return {
        "p05": percentil(valores, 0.05),
        "p50": percentil(valores, 0.50),
        "p95": percentil(valores, 0.95),
        "min": min(valores) if valores else float("nan"),
        "max": max(valores) if valores else float("nan"),
    }


def fmt(x: float, casas: int = 2) -> str:
    if math.isinf(x):
        return "∞"
    if math.isnan(x):
        return "—"
    return f"{x:.{casas}f}"


# ────────────────────────────────────── relatório ─────────────────────────────────────────


def imprimir(braços: list[dict]) -> None:
    print()
    print("═" * 92)
    print("QUALIDADE DE IMAGEM — PSNR (dB, luma) e SSIM contra a origem sintética")
    print("═" * 92)
    print(f"{'braço':>8}  {'ponto':<20} {'quadros':>7}  "
          f"{'PSNR p50':>9} {'PSNR p05':>9}  {'SSIM p50':>9} {'SSIM p05':>9}")
    print("─" * 92)
    for b in braços:
        for ponto in ("so_codificador", "depois_da_cadeia"):
            m = b.get(ponto)
            if not m:
                continue
            rotulo = "só o codificador" if ponto == "so_codificador" else "depois da cadeia"
            print(f"{b['nome']:>8}  {rotulo:<20} {m['quadros']:>7}  "
                  f"{fmt(m['psnr_y']['p50']):>9} {fmt(m['psnr_y']['p05']):>9}  "
                  f"{fmt(m['ssim']['p50'], 4):>9} {fmt(m['ssim']['p05'], 4):>9}")
        print("─" * 92)

    # A transparência da cadeia, que é o que separa "o codificador degradou" de "nós
    # degradamos". Num laço local sem perda os dois pontos têm de dar o mesmo número.
    for b in braços:
        a, c = b.get("so_codificador"), b.get("depois_da_cadeia")
        if not a or not c:
            continue
        d_psnr = abs(a["psnr_y"]["p50"] - c["psnr_y"]["p50"])
        d_ssim = abs(a["ssim"]["p50"] - c["ssim"]["p50"])
        veredito = ("TRANSPARENTE" if d_psnr < 1e-6 and d_ssim < 1e-6
                    else f"DEGRADOU (ΔPSNR {d_psnr:.4f} dB, ΔSSIM {d_ssim:.6f})")
        print(f"  cadeia no braço {b['nome']}: {veredito}")
    print()


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--saida", required=True, help="diretório de trabalho e de saída")
    p.add_argument("--segundos", type=int, default=20, help="duração da origem")
    p.add_argument("--kbps", type=int, nargs="+", default=[3700, 1200],
                   help="taxas a comparar. O par da quinta porta é 3700 e 1200")
    p.add_argument("--largura", type=int, default=1274)
    p.add_argument("--altura", type=int, default=716)
    p.add_argument("--fps", type=int, default=24)
    p.add_argument("--gop", type=int, default=44)
    p.add_argument("--fatias", type=int, default=4)
    p.add_argument("--porta", type=int, default=17931)
    p.add_argument("--pin", default="314159")
    p.add_argument("--emissor-macos", action="store_true",
                   help="acrescenta um braço com o encoder do PRODUTO no macOS "
                        "(H264Encoder/VideoToolbox, via apps/macos sonda-qualidade). "
                        "A taxa é a do preset do produto, não a de --kbps")
    p.add_argument("--sem-cadeia", action="store_true",
                   help="só o codificador; não sobe sessão nenhuma")
    p.add_argument("--medir-recebido", type=Path,
                   help="mede um .h264 já recebido em vez de rodar o laço local")
    p.add_argument("--referencia", type=Path,
                   help="referência sem perda já gerada (usar com --medir-recebido)")
    p.add_argument("--origem-externa", metavar="PROCEDENCIA",
                   help="afirma, por escrito, de onde veio a origem de --medir-recebido. "
                        "Obrigatório com ela, e vai para o relatório. Se a origem for "
                        "captura de tela de máquina do usuário, NÃO use este script")
    a = p.parse_args()

    for f in ("ffmpeg", "ffprobe"):
        if not shutil.which(f):
            print(f"preciso de {f} no PATH", file=sys.stderr)
            return 1

    destino = Path(a.saida)
    destino.mkdir(parents=True, exist_ok=True)
    trabalho = destino / "trabalho"
    trabalho.mkdir(exist_ok=True)

    if a.medir_recebido:
        if not a.origem_externa:
            print("--medir-recebido exige --origem-externa: diga de onde veio aquele vídeo.\n"
                  "Se veio de captura de tela de qualquer máquina do usuário, este script é a\n"
                  "ferramenta errada — meça por contador.", file=sys.stderr)
            return 1
        if not a.referencia or not a.referencia.exists():
            print("--medir-recebido exige --referencia com o .mkv sem perda da origem",
                  file=sys.stderr)
            return 1
        print(f"procedência declarada da origem: {a.origem_externa}")
        aferição = calibrar(a.referencia, trabalho, a.fps)
        # O mesmo desconto do laço local, e pelo mesmo motivo: um `.h264` vindo de uma sessão
        # de verdade traz o IDR que o emissor reenviou ao receptor entrar. Sem isto, o caminho
        # de entrega — que é justamente o que esta opção existe para servir — falharia na
        # conferência de contagem.
        alinhado, reenviados = tirar_idr_reenviado(a.medir_recebido, trabalho, "recebido")
        if reenviados:
            print(f"    {reenviados} IDR reenviado(s) por PLI removido(s) do alinhamento "
                  "(mesmo quadro entregue duas vezes; não é degradação)")
        m = por_quadro(alinhado, a.referencia, trabalho, "recebido", a.fps)
        braços = [{"nome": "recebido", "depois_da_cadeia": m,
                   "procedencia": a.origem_externa, "calibracao": aferição,
                   "idrs_reenviados_removidos": reenviados}]
        imprimir(braços)
        (destino / "qualidade.json").write_text(json.dumps(braços, indent=1))
        return 0

    if not a.sem_cadeia and not PROBE.exists():
        print(f"falta {PROBE}; rode cargo build -p quall-probe --release", file=sys.stderr)
        return 1

    print(f"referência: testsrc2 {a.largura}x{a.altura} a {a.fps} fps, {a.segundos} s "
          "(padrão sintético, sem captura de tela)")
    ref = gerar_referencia(destino, a.largura, a.altura, a.fps, a.segundos)
    print(f"    {ref}  ({ref.stat().st_size} B, sem perda, {contar_quadros(ref)} quadros)")

    # Antes de qualquer número: o instrumento contra um caso de resposta conhecida.
    aferição = calibrar(ref, trabalho, a.fps)

    # Cada braço é «uma origem codificada de um jeito», e todos passam pelo mesmo caminho a
    # partir daqui. O braço do macOS entra na mesma fila que as taxas do x264 de propósito: o
    # que muda entre eles é só quem codificou.
    a_codificar: list[tuple[str, callable]] = [
        (f"{kbps}k", (lambda k=kbps: codificar(ref, destino, k, a.fps, a.gop, a.fatias)))
        for kbps in sorted(a.kbps, reverse=True)
    ]
    if a.emissor_macos:
        a_codificar.append(("macOS", lambda: codificar_no_macos(ref, destino, a.fps)))

    braços = []
    for i, (nome, fazer) in enumerate(a_codificar):
        print(f"\n  ── {nome} ──")
        h264, sidecar = fazer()
        braço = {"nome": nome, "origem": str(h264)}
        braço["so_codificador"] = por_quadro(h264, ref, trabalho, f"cod-{nome}", a.fps)
        print(f"    só o codificador : PSNR p50 "
              f"{fmt(braço['so_codificador']['psnr_y']['p50'])} dB, "
              f"p05 {fmt(braço['so_codificador']['psnr_y']['p05'])} dB  |  SSIM p50 "
              f"{fmt(braço['so_codificador']['ssim']['p50'], 4)}, "
              f"p05 {fmt(braço['so_codificador']['ssim']['p05'], 4)}")

        if not a.sem_cadeia:
            recebido = destino / f"recebido-{nome}.h264"
            print("    laço local (emissor e receptor no mesmo Mac, 127.0.0.1)…")
            laco_local(sidecar, recebido, a.porta + i, a.pin,
                       a.segundos + 20, trabalho)
            braço["recebido"] = str(recebido)
            alinhado, reenviados = tirar_idr_reenviado(recebido, trabalho, f"cad-{nome}")
            braço["idrs_reenviados_removidos"] = reenviados
            if reenviados:
                print(f"      {reenviados} IDR reenviado(s) por PLI removido(s) do "
                      "alinhamento (mesmo quadro entregue duas vezes; não é degradação)")
            braço["depois_da_cadeia"] = por_quadro(alinhado, ref, trabalho, f"cad-{nome}", a.fps)
            print(f"    depois da cadeia : PSNR p50 "
                  f"{fmt(braço['depois_da_cadeia']['psnr_y']['p50'])} dB, "
                  f"p05 {fmt(braço['depois_da_cadeia']['psnr_y']['p05'])} dB  |  SSIM p50 "
                  f"{fmt(braço['depois_da_cadeia']['ssim']['p50'], 4)}, "
                  f"p05 {fmt(braço['depois_da_cadeia']['ssim']['p05'], 4)}")
        braços.append(braço)

    imprimir(braços)

    enxuto = [{k: v for k, v in b.items()} for b in braços]
    for b in enxuto:
        for ponto in ("so_codificador", "depois_da_cadeia"):
            if ponto in b:
                b[ponto] = {k: v for k, v in b[ponto].items()
                            if not k.endswith("_por_quadro")}
    (destino / "qualidade.json").write_text(json.dumps(
        {"calibracao": aferição,
         "origem": "lavfi testsrc2 (padrão sintético; nenhuma captura de tela)",
         "decodificador": "ffmpeg (software)",
         "braços": enxuto}, indent=1))
    print(f"relatório: {destino / 'qualidade.json'}")
    return 0


if __name__ == "__main__":
    # As recusas deste script são mensagens para uma pessoa ler — "a contagem não bate",
    # "a calibração falhou", "diga de onde veio a origem". Um traceback de Python enterra a
    # frase que importa embaixo de dez linhas de pilha.
    try:
        raise SystemExit(main())
    except RuntimeError as e:
        print(f"\n{e}", file=sys.stderr)
        raise SystemExit(1)
