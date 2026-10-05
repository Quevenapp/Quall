#!/usr/bin/env python3
"""Conta **fatias por quadro** e **pacotes por quadro** num Annex-B H.264.

    tools/fatias.py captura.h264 [outro.h264 ...]
    tools/fatias.py --json captura.h264
    tools/fatias.py --aferir            # o banco de prova, sem nenhum arquivo

**Não decodifica imagem nenhuma**, pela mesma razão que `tools/ler-sps.py`: as origens desta
bancada são telas e câmeras, e a regra do projeto é medir por campo, nunca por pixel. Este
programa lê cabeçalho de NAL e cabeçalho de fatia — `first_mb_in_slice` e `slice_type`, os dois
primeiros campos — e mais nada. Nenhum macrobloco é percorrido, nenhum quadro é aberto, gravado
ou convertido.

# Por que existe

`docs/regras-de-frente.md`: *"a plataforma aceitou" não é "a plataforma fez"*. Ligar
`KEY_INTRA_REFRESH_PERIOD` no `MediaFormat`, ou `kVTCompressionPropertyKey_MaxH264SliceBytes` no
VideoToolbox, ou `AVEncSliceControlSize` no Media Foundation, devolve sucesso nas três
plataformas — inclusive quando o encoder ignora o pedido em silêncio. A única testemunha é o
bitstream que saiu, e é o que este programa lê.

# As duas grandezas, que NÃO são a mesma

1. **Pacotes por unidade de acesso** — o tamanho da *rajada* que o quadro põe no rádio, e o
   **critério de aceitação desta frente**. `docs/idr-que-sobrevive.md` mediu a curva com
   instrumento de UDP puro: unidades de **até 35 pacotes** quebram 1,00 % (500 quadros); de
   **40 para cima**, 10,37 % (540 quadros). Um fator de dez, e o mecanismo dos 10 % —
   truncamento de cauda por fila que satura — **não existe** abaixo do joelho. Por isso a linha
   que este programa imprime em destaque é `unidades acima de 35 pacotes`, e o alvo é **zero**.
   Fatiar **não** encolhe esta grandeza — os bytes são os mesmos, só repartidos em mais NALs (e
   o total de pacotes até sobe um pouco, porque cada NAL curto custa um pacote inteiro). Quem
   encolhe é o refresh intra, que troca um quadro enorme por muitos quadros médios.

2. **Pacotes por fatia** — quanto custa perder *um* pacote, e quanto da imagem sobrevive a um
   truncamento. Como o corte é de **cauda** e a cabeça sempre chega, um IDR de 60 pacotes
   fatiado em quatro entrega as duas ou três primeiras fatias íntegras mesmo cortado em 40. É o
   que `MaxH264SliceBytes` promete — e é **metade** de um conserto: hoje o depacotizador
   (`crates/quall-core/src/rtp.rs`, `abortar()`) joga a cabeça fora junto com a cauda, e aquele
   arquivo não é desta frente.

O relatório imprime as duas, sempre juntas, porque confundi-las é o jeito mais fácil de declarar
vitória sem ter nenhuma.

# A conta de pacotes é a do emissor, não `ceil(bytes / 1188)`

`pacotes_da_unidade` é uma reimplementação em Python de `crates/quall-core/src/track.rs`
(`pacotes_da_unidade`/`pacotes_do_nal`), que por sua vez replica
`H264RtpPacketizer::fragment` → `NalUnit::GenerateFragments` da libdatachannel 0.23.2. A conta
ingênua subestima por duas razões independentes — a divisão é por NAL e não por quadro, e a
biblioteca desconta o cabeçalho FU-A **depois** de repartir. `--aferir` confere esta cópia contra
os casos conhecidos que os testes daquele arquivo fixam (1188->1, 5958->7, 17200->16, e as duas
unidades compostas), porque quem confere não pode ser o mesmo código que escreve.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Maior fragmento FU-A. Espelha `MAX_FRAGMENTO` de `crates/quall-core/src/track.rs`.
MAX_FRAGMENTO = 1188

VCL = range(1, 6)          # 1..5 carregam fatia de imagem
NAL_IDR = 5
NAL_SEI = 6
NAL_SPS = 7
NAL_PPS = 8
NAL_AUD = 9

# slice_type % 5: 0=P, 1=B, 2=I, 3=SP, 4=SI
NOME_SLICE = {0: "P", 1: "B", 2: "I", 3: "SP", 4: "SI"}


# --------------------------------------------------------------------------------------------
# Leitura de bits — a mesma forma de `tools/ler-sps.py`, deliberadamente duplicada: um leitor
# compartilhado faria os dois programas errarem juntos.
# --------------------------------------------------------------------------------------------
class Bits:
    def __init__(self, b: bytes) -> None:
        self.b, self.i = b, 0

    def u(self, n: int) -> int:
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.b[self.i >> 3] >> (7 - (self.i & 7))) & 1)
            self.i += 1
        return v

    def ue(self) -> int:
        z = 0
        while self.u(1) == 0:
            z += 1
        return (1 << z) - 1 + (self.u(z) if z else 0)


def desescapa(b: bytes) -> bytes:
    """Tira os bytes 0x03 de anti-emulação: `00 00 03` -> `00 00`."""
    out, i = bytearray(), 0
    while i < len(b):
        if i + 2 < len(b) and b[i] == 0 and b[i + 1] == 0 and b[i + 2] == 3:
            out += b[i:i + 2]
            i += 3
        else:
            out.append(b[i])
            i += 1
    return bytes(out)


# --------------------------------------------------------------------------------------------
# NALs e pacotes — a cópia fiel do lado do emissor
# --------------------------------------------------------------------------------------------
def nals(buf: bytes) -> list[tuple[int, int]]:
    """`(inicio, tamanho)` de cada NAL, pela regra de `nals_annexb` do núcleo.

    Aceita prefixo de 3 **ou** de 4 bytes; o zero extra do prefixo de 4 pertence ao prefixo, não
    ao NAL anterior. O último NAL vai até o fim do buffer.
    """
    inicios: list[int] = []
    i, n = 0, len(buf)
    while i + 3 <= n:
        if buf[i] == 0 and buf[i + 1] == 0 and buf[i + 2] == 1:
            inicios.append(i + 3)
            i += 3
        else:
            i += 1
    saida: list[tuple[int, int]] = []
    for k, ini in enumerate(inicios):
        if k + 1 < len(inicios):
            fim = inicios[k + 1] - 3
            if fim > ini and buf[fim - 1] == 0:
                fim -= 1
        else:
            fim = n
        saida.append((ini, max(0, fim - ini)))
    return saida


def pacotes_do_nal(tam: int) -> int:
    """Fragmentos que um NAL de `tam` bytes produz — `NalUnit::generateFragments`."""
    if tam == 0:
        return 0
    if tam <= MAX_FRAGMENTO:
        return 1
    n = -(-tam // MAX_FRAGMENTO)          # ceil
    m = max(0, -(-tam // n) - 2)
    if m == 0:
        return n
    return -(-(tam - 1) // m)


def pacotes_da_unidade(annexb: bytes) -> int:
    return sum(pacotes_do_nal(t) for _, t in nals(annexb))


# --------------------------------------------------------------------------------------------
# Cabeçalho de fatia e SEI
# --------------------------------------------------------------------------------------------
def cabecalho_de_fatia(nal: bytes) -> tuple[int, int] | None:
    """`(first_mb_in_slice, slice_type)` — os dois primeiros campos do cabeçalho de fatia.

    Devolve `None` se o NAL for curto demais para conter os dois. Não lê mais nada: `pic_parameter
    _set_id` em diante depende do PPS ativo e não faz falta para nenhuma pergunta desta frente.
    """
    corpo = desescapa(nal[1:9])
    if len(corpo) < 2:
        return None
    try:
        b = Bits(corpo)
        return b.ue(), b.ue()
    except IndexError:
        return None


def tipos_de_sei(nal: bytes) -> list[int]:
    """Tipos de payload SEI (RFC/ITU H.264 §7.3.2.3.1), lidos só pelo cabeçalho de cada payload.

    Interessa o **tipo 6, `recovery_point`**: é o que um encoder emite quando o fluxo não tem IDR
    mas tem ponto de recuperação — a assinatura clássica do refresh intra gradual.
    """
    corpo = desescapa(nal[1:])
    tipos, i = [], 0
    while i < len(corpo):
        t = 0
        while i < len(corpo) and corpo[i] == 0xFF:
            t += 255
            i += 1
        if i >= len(corpo):
            break
        t += corpo[i]
        i += 1
        tam = 0
        while i < len(corpo) and corpo[i] == 0xFF:
            tam += 255
            i += 1
        if i >= len(corpo):
            break
        tam += corpo[i]
        i += 1
        tipos.append(t)
        i += tam
        if corpo[i:i + 1] == b"\x80":     # rbsp_trailing_bits
            break
    return tipos


# --------------------------------------------------------------------------------------------
# Unidades de acesso
# --------------------------------------------------------------------------------------------
class Unidade:
    """Uma unidade de acesso: os NALs de uma imagem, mais os não-VCL que a precedem."""

    def __init__(self) -> None:
        self.nals: list[tuple[int, int]] = []   # (tipo, tamanho)
        self.bytes = 0
        self.pacotes = 0
        self.fatias = 0
        self.tipos_de_fatia: list[str] = []
        self.idr = False
        self.sei: list[int] = []
        self.maior_fatia = 0
        self.pacotes_da_maior_fatia = 0

    def acrescenta(self, tipo: int, tam: int, cab: tuple[int, int] | None,
                   sei: list[int] | None) -> None:
        self.nals.append((tipo, tam))
        # +4 do start code: é o que o arquivo carrega e o que o emissor manda.
        self.bytes += tam + 4
        self.pacotes += pacotes_do_nal(tam)
        if tipo in VCL:
            self.fatias += 1
            if tipo == NAL_IDR:
                self.idr = True
            if cab is not None:
                self.tipos_de_fatia.append(NOME_SLICE.get(cab[1] % 5, "?"))
            if tam > self.maior_fatia:
                self.maior_fatia = tam
                self.pacotes_da_maior_fatia = pacotes_do_nal(tam)
        if sei:
            self.sei.extend(sei)

    def resumo(self) -> dict:
        return {
            "bytes": self.bytes,
            "pacotes": self.pacotes,
            "fatias": self.fatias,
            "tipos_de_fatia": "".join(self.tipos_de_fatia),
            "idr": self.idr,
            "maior_fatia_bytes": self.maior_fatia,
            "pacotes_da_maior_fatia": self.pacotes_da_maior_fatia,
            "sei": sorted(set(self.sei)),
        }


def unidades(buf: bytes) -> list[Unidade]:
    """Divide o fluxo em unidades de acesso.

    A fronteira é `first_mb_in_slice == 0` num NAL VCL, que é a regra do §7.4.1.2.4 reduzida ao
    que basta aqui (um fluxo de baseline sem campos nem múltiplas imagens por carimbo). Um AUD
    (tipo 9), quando existe, também abre unidade. Os não-VCL que aparecem antes da primeira fatia
    pertencem à unidade que vem — é assim que SPS/PPS colados na frente do IDR entram na conta de
    pacotes **daquele** quadro, que é como o emissor de fato os manda.
    """
    saida: list[Unidade] = []
    atual = Unidade()
    tem_fatia = False
    for ini, tam in nals(buf):
        if tam == 0:
            continue
        tipo = buf[ini] & 0x1F
        cab = None
        sei = None
        if tipo in VCL:
            cab = cabecalho_de_fatia(buf[ini:ini + tam])
            primeira_do_quadro = cab is not None and cab[0] == 0
            if tem_fatia and primeira_do_quadro:
                saida.append(atual)
                atual = Unidade()
                tem_fatia = False
        elif tipo == NAL_AUD and tem_fatia:
            saida.append(atual)
            atual = Unidade()
            tem_fatia = False
        elif tipo == NAL_SEI:
            sei = tipos_de_sei(buf[ini:ini + tam])
        atual.acrescenta(tipo, tam, cab, sei)
        if tipo in VCL:
            tem_fatia = True
    if atual.nals:
        saida.append(atual)
    return saida


# --------------------------------------------------------------------------------------------
# Relatório
# --------------------------------------------------------------------------------------------
def pct(valores: list[int], p: float) -> int:
    if not valores:
        return 0
    v = sorted(valores)
    return v[min(len(v) - 1, max(0, int(p * (len(v) - 1))))]


def analisa(caminho: Path, fps: float) -> dict:
    buf = caminho.read_bytes()
    us = unidades(buf)
    quadros = [u for u in us if u.fatias > 0]
    idrs = [u for u in quadros if u.idr]
    outros = [u for u in quadros if not u.idr]
    pac = [u.pacotes for u in quadros]
    # O joelho de `docs/idr-que-sobrevive.md`: até 35 pacotes a quebra é 1 %, de 40 para cima é
    # 10 %. `acima_do_joelho` é o número que fecha ou não fecha esta frente.
    acima_do_joelho = sum(1 for p in pac if p > 35)
    na_faixa = sum(1 for p in pac if 40 <= p <= 80)
    acima = sum(1 for p in pac if p > 80)
    fatias_i_em_nao_idr = sum(
        1 for u in outros for t in u.tipos_de_fatia if t in ("I", "SI")
    )
    quadros_com_i_sem_idr = sum(
        1 for u in outros if any(t in ("I", "SI") for t in u.tipos_de_fatia)
    )
    hist_fatias: dict[int, int] = {}
    for u in quadros:
        hist_fatias[u.fatias] = hist_fatias.get(u.fatias, 0) + 1
    bytes_totais = sum(u.bytes for u in quadros)
    segundos = (len(quadros) / fps) if fps > 0 else 0.0
    return {
        "arquivo": str(caminho),
        "quadros": len(quadros),
        "idrs": len(idrs),
        "fatias_por_quadro": {str(k): v for k, v in sorted(hist_fatias.items())},
        "fatias_p50": pct([u.fatias for u in quadros], 0.50),
        "pacotes_por_quadro": {
            "p50": pct(pac, 0.50), "p95": pct(pac, 0.95),
            "max": max(pac) if pac else 0,
        },
        "pacotes_do_idr": {
            "n": len(idrs),
            "p50": pct([u.pacotes for u in idrs], 0.50),
            "max": max((u.pacotes for u in idrs), default=0),
        },
        "pacotes_dos_demais": {
            "n": len(outros),
            "p50": pct([u.pacotes for u in outros], 0.50),
            "p95": pct([u.pacotes for u in outros], 0.95),
            "max": max((u.pacotes for u in outros), default=0),
        },
        "unidades_acima_de_35_pacotes": acima_do_joelho,
        "quadros_na_faixa_40_80": na_faixa,
        "quadros_acima_de_80": acima,
        "maior_fatia_pacotes": {
            "p50": pct([u.pacotes_da_maior_fatia for u in quadros], 0.50),
            "max": max((u.pacotes_da_maior_fatia for u in quadros), default=0),
        },
        "fatias_i_fora_de_idr": fatias_i_em_nao_idr,
        "quadros_com_fatia_i_sem_idr": quadros_com_i_sem_idr,
        "sei_recovery_point": sum(1 for u in quadros if 6 in u.sei),
        "bytes": bytes_totais,
        "kbps_a_fps": round(bytes_totais * 8 / 1000 / segundos, 1) if segundos > 0 else None,
        "fps_assumido": fps,
    }


def imprime(r: dict) -> None:
    print(f"== {r['arquivo']}")
    print(f"   quadros {r['quadros']}  ·  IDR {r['idrs']}  ·  "
          f"{r['bytes']} B  ·  {r['kbps_a_fps']} kbps a {r['fps_assumido']} fps")
    print(f"   fatias/quadro: {r['fatias_por_quadro']}  (p50 {r['fatias_p50']})")
    q = r["pacotes_por_quadro"]
    print(f"   pacotes/quadro: p50 {q['p50']}  p95 {q['p95']}  max {q['max']}")
    i, d = r["pacotes_do_idr"], r["pacotes_dos_demais"]
    print(f"     IDR   n={i['n']} p50 {i['p50']} max {i['max']}")
    print(f"     demais n={d['n']} p50 {d['p50']} p95 {d['p95']} max {d['max']}")
    n = r["unidades_acima_de_35_pacotes"]
    print(f"   >>> ACIMA DO JOELHO (>35 pacotes): {n} de {r['quadros']} quadro(s)"
          f"{'  <-- alvo é zero' if n else '  <-- ZERO'}")
    print(f"       na faixa 40-80: {r['quadros_na_faixa_40_80']}  ·  "
          f"acima de 80: {r['quadros_acima_de_80']}")
    m = r["maior_fatia_pacotes"]
    print(f"   maior fatia do quadro: p50 {m['p50']} pacote(s), max {m['max']}")
    print(f"   fatia I fora de IDR: {r['fatias_i_fora_de_idr']} em "
          f"{r['quadros_com_fatia_i_sem_idr']} quadro(s)  ·  "
          f"SEI recovery_point: {r['sei_recovery_point']}")


# --------------------------------------------------------------------------------------------
# Banco de prova
# --------------------------------------------------------------------------------------------
def au(tamanhos: list[int], tipos: list[int] | None = None,
       primeiro_mb: list[int] | None = None) -> bytes:
    """Monta uma unidade de acesso sintética. `tipos` são tipos de NAL; o corpo é enchimento.

    O byte de enchimento é `0x41`, o mesmo dos testes de `track.rs`, para que a conta de pacotes
    seja comparável byte a byte com aquele banco.
    """
    v = bytearray()
    for k, n in enumerate(tamanhos):
        v += b"\x00\x00\x00\x01"
        tipo = tipos[k] if tipos else 1
        v.append(0x40 | tipo)
        corpo = bytearray(b"\x41" * (n - 1))
        if tipo in VCL and n >= 3:
            # first_mb_in_slice = m (ue), slice_type = 0 (P) — dois campos, bits altos.
            m = primeiro_mb[k] if primeiro_mb else 0
            corpo[0] = 0b1010_0000 if m == 0 else 0b0101_0000  # ue(0),ue(0) / ue(1),..
        v += corpo
    return bytes(v)


def aferir() -> int:
    """Confere a cópia da conta de pacotes contra os casos que `track.rs` fixa, e a divisão em
    unidades contra casos construídos com resposta conhecida."""
    falhas = 0

    def checa(nome: str, obtido, esperado) -> None:
        nonlocal falhas
        ok = obtido == esperado
        if not ok:
            falhas += 1
        print(f"  [{'ok ' if ok else 'ERRO'}] {nome}: {obtido!r}"
              + ("" if ok else f"  (esperado {esperado!r})"))

    print("aferição 1 — a conta de pacotes contra os casos de crates/quall-core/src/track.rs")
    checa("pacotes_do_nal(1)", pacotes_do_nal(1), 1)
    checa("pacotes_do_nal(1188)", pacotes_do_nal(1188), 1)
    # 1.189 B — um byte acima do fragmento — dão **três** pacotes, não dois: n = 2,
    # m = ceil(1189/2) - 2 = 593, e ceil(1188/593) = 3. É o mesmo desconto de cabeçalho FU-A que
    # faz 5.958 dar 7. Escrevi 2 na primeira versão deste banco e o instrumento me corrigiu.
    checa("pacotes_do_nal(1189) — e NÃO 2", pacotes_do_nal(1189), 3)
    checa("pacotes_do_nal(5958) — a conta ingênua diz 6", pacotes_do_nal(5958), 7)
    checa("pacotes_do_nal(17200)", pacotes_do_nal(17200), 16)
    checa("AU (2,20,5958) = 1+1+7", pacotes_da_unidade(au([2, 20, 5958])), 9)
    checa("AU (27,8,17200) = 1+1+16", pacotes_da_unidade(au([27, 8, 17200])), 18)

    print("aferição 2 — a divisão em NAL aceita prefixo de 3 e de 4 bytes")
    quatro = au([100])
    tres = b"\x00\x00\x01" + b"\x41" * 100
    checa("prefixo de 4", [t for _, t in nals(quatro)], [100])
    checa("prefixo de 3", [t for _, t in nals(tres)], [100])

    print("aferição 3 — uma fatia por quadro, três quadros")
    fluxo = b"".join(au([500], [1]) for _ in range(3))
    us = unidades(fluxo)
    checa("quadros", len(us), 3)
    checa("fatias por quadro", [u.fatias for u in us], [1, 1, 1])

    print("aferição 4 — quatro fatias no MESMO quadro (first_mb_in_slice != 0 nas três últimas)")
    fluxo = au([500, 500, 500, 500], [1, 1, 1, 1], [0, 1, 1, 1])
    us = unidades(fluxo)
    checa("quadros", len(us), 1)
    checa("fatias", [u.fatias for u in us], [4])
    checa("pacotes do quadro", [u.pacotes for u in us], [4])
    checa("maior fatia em pacotes", [u.pacotes_da_maior_fatia for u in us], [1])

    print("aferição 5 — SPS+PPS+IDR entram na conta do quadro do IDR")
    fluxo = au([27, 8, 17200], [7, 8, 5], [0, 0, 0])
    us = unidades(fluxo)
    checa("quadros", len(us), 1)
    checa("é IDR", [u.idr for u in us], [True])
    checa("pacotes", [u.pacotes for u in us], [18])

    print("aferição 6 — o mesmo total de bytes, fatiado, NÃO encolhe a rajada")
    inteiro = unidades(au([60000], [5], [0]))[0]
    partido = unidades(au([12000] * 5, [5] * 5, [0, 1, 1, 1, 1]))[0]
    checa("um NAL de 60 kB", inteiro.pacotes, pacotes_do_nal(60000))
    checa("cinco de 12 kB somam o mesmo ou mais",
          partido.pacotes >= inteiro.pacotes, True)
    checa("mas a maior fatia cai", partido.pacotes_da_maior_fatia < inteiro.pacotes_da_maior_fatia,
          True)

    print("aferição 7 — SEI recovery_point (tipo 6) é reconhecido")
    # SEI: payload type 6, tamanho 2, dois bytes, rbsp_trailing.
    sei = b"\x00\x00\x00\x01\x06\x06\x02\x00\x00\x80"
    checa("tipos_de_sei", tipos_de_sei(sei[4:]), [6])

    falhas += aferir_com_ffmpeg()

    print()
    if falhas:
        print(f"AFERIÇÃO REPROVADA: {falhas} caso(s)")
    else:
        print("aferição completa: o instrumento reproduz todos os casos conhecidos")
    return 1 if falhas else 0


def aferir_com_ffmpeg() -> int:
    """Aferição **externa**: um codificador que não é nosso, com o número de fatias pedido na
    linha de comando, e a origem sintética do `testsrc` — nunca tela de ninguém.

    As aferições de 1 a 7 conferem o programa contra ele mesmo e contra os números que
    `track.rs` fixa. Esta confere contra um terceiro: se o x264 recebe `slices=4` e este
    programa não disser 4, o instrumento está errado, não o x264. Vale nos dois sentidos —
    `slices=1` tem de dar **1**, porque um contador que enxerga fatia onde não há é tão inútil
    quanto um que não enxerga onde há.

    Pulada, com aviso, quando não houver `ffmpeg` com libx264 nesta máquina.
    """
    import shutil
    import subprocess
    import tempfile

    print("aferição 8 — contra o x264, que não é nosso (origem sintética `testsrc`)")
    if shutil.which("ffmpeg") is None:
        print("  [pulada] não há ffmpeg nesta máquina")
        return 0

    falhas = 0
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        for n in (1, 4, 8):
            alvo = d / f"x264-{n}.h264"
            r = subprocess.run(
                ["ffmpeg", "-y", "-v", "error",
                 "-f", "lavfi", "-i", "testsrc=size=720x1280:rate=30:duration=2",
                 "-pix_fmt", "yuv420p", "-c:v", "libx264", "-profile:v", "baseline",
                 "-x264-params", f"slices={n}:keyint=30", "-f", "h264", str(alvo)],
                capture_output=True, text=True,
            )
            if r.returncode != 0 or not alvo.exists() or alvo.stat().st_size == 0:
                print(f"  [pulada] o ffmpeg desta máquina não codificou com slices={n}")
                return falhas
            us = [u for u in unidades(alvo.read_bytes()) if u.fatias > 0]
            obtido = sorted({u.fatias for u in us})
            ok = obtido == [n]
            if not ok:
                falhas += 1
            print(f"  [{'ok ' if ok else 'ERRO'}] x264 slices={n} em {len(us)} quadros -> "
                  f"fatias observadas {obtido}")
    return falhas


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arquivos", nargs="*", type=Path)
    ap.add_argument("--json", action="store_true", help="sai em JSON, um objeto por arquivo")
    ap.add_argument("--fps", type=float, default=30.0,
                    help="taxa assumida para converter bytes em kbps (padrão 30)")
    ap.add_argument("--aferir", action="store_true",
                    help="roda o banco de prova contra casos conhecidos e sai")
    a = ap.parse_args(argv)

    if a.aferir:
        return aferir()
    if not a.arquivos:
        ap.error("nomeie ao menos um .h264, ou use --aferir")

    saidas = []
    for c in a.arquivos:
        if not c.exists():
            print(f"não existe: {c}", file=sys.stderr)
            return 2
        r = analisa(c, a.fps)
        saidas.append(r)
        if not a.json:
            imprime(r)
    if a.json:
        print(json.dumps(saidas, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
