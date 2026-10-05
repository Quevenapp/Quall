#!/usr/bin/env python3
"""Veredito sobre um fluxo H.264 Annex-B, lido do próprio bitstream.

    Testes/confere-h264.py recebido.h264 [--teto-maior 1920] [--teto-menor 1080]
                                         [--faixa limitada|completa] [--minimo-idr 1]

Sai com o número de condições reprovadas. Zero é aprovação.

## Por que existe, tendo `ffprobe`

O `ffprobe` é a testemunha externa deste projeto e continua sendo — mas ele responde `color_range`
depois de passar pelo mapeamento interno do FFmpeg, e **não** responde as outras duas perguntas
que a câmera precisa que sejam reprováveis:

1. **faixa de cor errada** — aqui é lido o `video_full_range_flag` do VUI, o bit do padrão, e não
   uma etiqueta derivada. Quando o VUI **não existe**, isso aparece como ausência, e não como um
   palpite: a ressalva que `contrato-sidecar.md` registrou como tarefa em aberto ("o fluxo é
   limitado e não declara") é exatamente esse caso, e ela precisa reprovar em vez de passar por
   parecer com o padrão do H.264;
2. **dimensão fora do teto** — do SPS, que é o que o receptor de fato vai ler. O teto de 1080x1920
   é do nível anunciado no SDP (dívida 16), e o `ffprobe` responde a dimensão do contêiner que ele
   deduziu, não a que o parâmetro declara;
3. **IDR sem parâmetros** — o `ffprobe` não tem como reprovar isso: um fluxo cujo primeiro IDR não
   leva SPS/PPS decodifica normalmente *para quem estava lá desde o começo*. Quem entra no meio
   fica sem imagem, que é o defeito medido no Windows no M1 e o que
   `idrs_without_parameters` denuncia do lado do núcleo. Só varrendo as unidades NAL dá para ver.

Nada aqui depende do FFmpeg, do VideoToolbox nem do núcleo: entra um arquivo, sai um veredito.
"""

import sys


# --- leitura de bits ---------------------------------------------------------------------------

class Bits:
    """Leitor de bits com Exp-Golomb, sobre o RBSP já desescapado."""

    def __init__(self, dados):
        self.dados = dados
        self.pos = 0  # em bits

    def u(self, n):
        valor = 0
        for _ in range(n):
            byte = self.pos >> 3
            if byte >= len(self.dados):
                raise ValueError("SPS acabou no meio da leitura")
            bit = (self.dados[byte] >> (7 - (self.pos & 7))) & 1
            valor = (valor << 1) | bit
            self.pos += 1
        return valor

    def ue(self):
        """Exp-Golomb sem sinal. O teto de 32 zeros evita laço infinito em lixo."""
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 32:
                raise ValueError("Exp-Golomb sem fim — o fluxo não é um SPS")
        if zeros == 0:
            return 0
        return (1 << zeros) - 1 + self.u(zeros)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)


def desescapar(nal):
    """Tira os bytes 0x03 de prevenção de emulação: 00 00 03 xx vira 00 00 xx."""
    saida = bytearray()
    i = 0
    while i < len(nal):
        if i + 2 < len(nal) and nal[i] == 0 and nal[i + 1] == 0 and nal[i + 2] == 3:
            saida += b"\x00\x00"
            i += 3
        else:
            saida.append(nal[i])
            i += 1
    return bytes(saida)


# --- Annex-B -----------------------------------------------------------------------------------

def unidades(dados):
    """Devolve (tipo, corpo) de cada unidade NAL, partindo por start code de 3 ou 4 bytes."""
    achados = []
    inicios = []
    i = 0
    fim = len(dados)
    while i + 2 < fim:
        if dados[i] == 0 and dados[i + 1] == 0:
            if dados[i + 2] == 1:
                inicios.append((i, 3))
                i += 3
                continue
            if i + 3 < fim and dados[i + 2] == 0 and dados[i + 3] == 1:
                inicios.append((i, 4))
                i += 4
                continue
        i += 1
    for indice, (posicao, tamanho) in enumerate(inicios):
        comeco = posicao + tamanho
        acaba = inicios[indice + 1][0] if indice + 1 < len(inicios) else fim
        corpo = dados[comeco:acaba]
        if not corpo:
            continue
        achados.append((corpo[0] & 0x1F, corpo))
    return achados


def ler_sps(corpo):
    """Dimensão e descrição de cor do SPS. `corpo` inclui o byte de cabeçalho da NAL."""
    b = Bits(desescapar(corpo[1:]))
    ficha = {}
    ficha["profile_idc"] = b.u(8)
    b.u(8)  # constraint flags + reservado
    ficha["level_idc"] = b.u(8)
    b.ue()  # seq_parameter_set_id

    chroma = 1
    if ficha["profile_idc"] in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
        chroma = b.ue()
        if chroma == 3:
            b.u(1)
        b.ue()
        b.ue()
        b.u(1)
        if b.u(1):  # seq_scaling_matrix_present_flag
            for i in range(8 if chroma != 3 else 12):
                if b.u(1):
                    tamanho = 16 if i < 6 else 64
                    ultimo, proximo = 8, 8
                    for _ in range(tamanho):
                        if proximo:
                            proximo = (ultimo + b.se() + 256) % 256
                        ultimo = proximo or ultimo
    ficha["chroma_format_idc"] = chroma

    b.ue()  # log2_max_frame_num_minus4
    ordem = b.ue()
    if ordem == 0:
        b.ue()
    elif ordem == 1:
        b.u(1)
        b.se()
        b.se()
        for _ in range(b.ue()):
            b.se()
    b.ue()  # max_num_ref_frames
    b.u(1)  # gaps_in_frame_num_value_allowed_flag

    largura_mbs = b.ue() + 1
    altura_unidades = b.ue() + 1
    quadro_so = b.u(1)
    if not quadro_so:
        b.u(1)
    b.u(1)  # direct_8x8_inference_flag

    corte = [0, 0, 0, 0]
    if b.u(1):  # frame_cropping_flag
        corte = [b.ue(), b.ue(), b.ue(), b.ue()]

    largura = largura_mbs * 16
    altura = (2 - quadro_so) * altura_unidades * 16
    # 4:2:0 (chroma_format_idc == 1) corta de dois em dois; 4:4:4 e monocromático, de um em um.
    unidade_x = 2 if chroma == 1 else 1
    unidade_y = (2 if chroma == 1 else 1) * (2 - quadro_so)
    largura -= (corte[0] + corte[1]) * unidade_x
    altura -= (corte[2] + corte[3]) * unidade_y
    ficha["largura"] = largura
    ficha["altura"] = altura

    # --- VUI: é aqui que mora o veredito da faixa de cor -------------------------------------
    ficha["vui"] = False
    ficha["faixa_declarada"] = None
    ficha["cor_declarada"] = None
    if b.u(1):  # vui_parameters_present_flag
        ficha["vui"] = True
        if b.u(1):  # aspect_ratio_info_present_flag
            if b.u(8) == 255:
                b.u(16)
                b.u(16)
        if b.u(1):  # overscan_info_present_flag
            b.u(1)
        if b.u(1):  # video_signal_type_present_flag
            b.u(3)  # video_format
            ficha["faixa_declarada"] = "completa" if b.u(1) else "limitada"
            if b.u(1):  # colour_description_present_flag
                ficha["cor_declarada"] = (b.u(8), b.u(8), b.u(8))
    return ficha


def conferir(caminho, teto_maior, teto_menor, faixa_pedida, minimo_idr):
    with open(caminho, "rb") as arquivo:
        dados = arquivo.read()

    falhas = []
    aprovados = []

    nals = unidades(dados)
    if not nals:
        print("  ✗ nenhuma unidade NAL: o arquivo não é Annex-B (ou está vazio)")
        return 1

    contagem = {}
    for tipo, _ in nals:
        contagem[tipo] = contagem.get(tipo, 0) + 1
    nomes = {1: "fatia", 5: "IDR", 6: "SEI", 7: "SPS", 8: "PPS", 9: "AUD"}
    resumo = " ".join(
        "%s=%d" % (nomes.get(t, "tipo%d" % t), n) for t, n in sorted(contagem.items())
    )
    print("  unidades NAL: %s (%d bytes)" % (resumo, len(dados)))

    # --- todo IDR leva SPS e PPS -------------------------------------------------------------
    #
    # A varredura é por unidade de acesso: SPS e PPS valem para o IDR que vem depois deles e antes
    # da próxima fatia não-IDR. Um SPS enviado uma vez no começo **não** conta para os IDR
    # seguintes — quem entra na sessão no minuto três não viu aquele SPS.
    idrs = 0
    idrs_sem_parametros = 0
    tem_sps = False
    tem_pps = False
    for tipo, _ in nals:
        if tipo == 7:
            tem_sps = True
        elif tipo == 8:
            tem_pps = True
        elif tipo == 5:
            idrs += 1
            if not (tem_sps and tem_pps):
                idrs_sem_parametros += 1
            tem_sps = False
            tem_pps = False
        elif tipo == 1:
            tem_sps = False
            tem_pps = False

    if idrs < minimo_idr:
        falhas.append("o fluxo tem %d IDR, e o mínimo pedido é %d" % (idrs, minimo_idr))
    elif idrs_sem_parametros:
        falhas.append(
            "%d de %d IDR vieram SEM SPS/PPS na mesma unidade de acesso — quem entra na "
            "sessão depois desse ponto fica sem imagem" % (idrs_sem_parametros, idrs)
        )
    else:
        aprovados.append("os %d IDR levaram SPS e PPS junto" % idrs)

    # A primeira unidade precisa ser parâmetro: um fluxo que começa por fatia não decodifica.
    if nals[0][0] not in (7, 8, 9, 6):
        falhas.append(
            "a primeira unidade NAL é tipo %d, não SPS — o receptor começa sem parâmetros"
            % nals[0][0]
        )
    else:
        aprovados.append("o fluxo começa por parâmetros (NAL tipo %d)" % nals[0][0])

    # --- SPS: dimensão e faixa de cor ---------------------------------------------------------
    sps = next((corpo for tipo, corpo in nals if tipo == 7), None)
    if sps is None:
        falhas.append("não há SPS no fluxo — nada declara dimensão nem faixa de cor")
        for f in falhas:
            print("  ✗ %s" % f)
        return len(falhas)

    try:
        ficha = ler_sps(sps)
    except ValueError as erro:
        print("  ✗ o SPS não pôde ser lido: %s" % erro)
        return len(falhas) + 1

    l, a = ficha["largura"], ficha["altura"]
    print(
        "  SPS: %dx%d perfil=%d nível=%d vui=%s faixa=%s cor=%s"
        % (
            l, a, ficha["profile_idc"], ficha["level_idc"],
            "sim" if ficha["vui"] else "NÃO",
            ficha["faixa_declarada"] or "não declarada",
            ficha["cor_declarada"] or "não declarada",
        )
    )

    if max(l, a) > teto_maior or min(l, a) > teto_menor:
        falhas.append(
            "dimensão %dx%d passa do teto de %dx%d — o nível anunciado no SDP não a comporta "
            "(dívida 16)" % (l, a, teto_maior, teto_menor)
        )
    else:
        aprovados.append("dimensão %dx%d dentro do teto de %dx%d" % (l, a, teto_maior, teto_menor))

    if l % 2 or a % 2:
        falhas.append("dimensão ímpar (%dx%d): não existe em 4:2:0" % (l, a))

    if ficha["faixa_declarada"] is None:
        falhas.append(
            "o fluxo NÃO declara a faixa de cor (sem video_signal_type no VUI). Depender do "
            "padrão do H.264 é a fragilidade que contrato-sidecar.md registrou como tarefa em "
            "aberto"
        )
    elif ficha["faixa_declarada"] != faixa_pedida:
        falhas.append(
            "faixa de cor %s, e o contrato padroniza %s — o MediaCodec do A10s ignora o "
            "video_full_range_flag" % (ficha["faixa_declarada"], faixa_pedida)
        )
    else:
        aprovados.append("faixa de cor %s, declarada no VUI" % ficha["faixa_declarada"])

    if ficha["cor_declarada"] is None:
        falhas.append("o VUI não traz primárias, transferência e matriz")
    elif ficha["cor_declarada"] != (1, 1, 1):
        falhas.append(
            "descrição de cor %s, e o esperado é (1, 1, 1) = ITU-R BT.709"
            % (ficha["cor_declarada"],)
        )
    else:
        aprovados.append("descrição de cor BT.709 completa (primárias, transferência, matriz)")

    for texto in aprovados:
        print("  ✓ %s" % texto)
    for texto in falhas:
        print("  ✗ %s" % texto)
    return len(falhas)


def main(argumentos):
    if not argumentos:
        print(__doc__)
        return 2
    caminho = argumentos[0]
    teto_maior, teto_menor = 1920, 1080
    faixa = "limitada"
    minimo_idr = 1
    i = 1
    while i < len(argumentos):
        chave = argumentos[i]
        valor = argumentos[i + 1] if i + 1 < len(argumentos) else ""
        if chave == "--teto-maior":
            teto_maior = int(valor)
        elif chave == "--teto-menor":
            teto_menor = int(valor)
        elif chave == "--faixa":
            faixa = valor
        elif chave == "--minimo-idr":
            minimo_idr = int(valor)
        else:
            print("opção desconhecida: %s" % chave)
            return 2
        i += 2
    try:
        return conferir(caminho, teto_maior, teto_menor, faixa, minimo_idr)
    except FileNotFoundError:
        print("  ✗ não achei o arquivo %s" % caminho)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
