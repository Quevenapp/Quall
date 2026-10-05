#!/usr/bin/env python3
"""Lê os conjuntos de parâmetros de um Annex-B e imprime o que decide o comportamento do decodificador.

    tools/ler-sps.py recebido.h264 [outro.h264 ...]
    tools/ler-sps.py --hex 2742001fab402802dc80

**Não decodifica imagem nenhuma.** Percorre os NALs, pega o do tipo 7 e lê os campos do SPS. Isso
importa: os fluxos desta bancada vêm de câmeras e de telas, e a regra do projeto é medir por campo,
nunca por pixel — nada aqui abre, converte ou grava imagem.

Por que existe: em 2026-08-24 este leitor mostrou que o emissor Apple emitia um SPS de 10 bytes
**sem VUI nenhum**, e que por isso o decodificador da Microsoft era obrigado a assumir o teto do
nível e empilhava ~5 quadros — 169,5 ms de `decode` p50 contra 3,70 ms do MediaCodec. O conserto
(`RemendoDeSPS`) derrubou para 4,24 ms. Comparar bitstreams de plataformas diferentes é medição
barata e de alto rendimento; ver `docs/regras-de-frente.md`.

É deliberadamente independente do analisador em Swift (`RemendoDeSPS.analisar`): quem confere não
pode ser o mesmo código que escreve.
"""
import collections
import sys


class Bits:
    def __init__(self, b):
        self.b, self.i = b, 0

    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.b[self.i >> 3] >> (7 - (self.i & 7))) & 1)
            self.i += 1
        return v

    def ue(self):
        z = 0
        while self.u(1) == 0:
            z += 1
        return (1 << z) - 1 + (self.u(z) if z else 0)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)


def desescapa(b):
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


def nals(buf):
    i, n = 0, len(buf)
    while i < n - 3:
        if buf[i] == 0 and buf[i + 1] == 0 and buf[i + 2] == 1:
            i += 3
        elif i < n - 4 and buf[i:i + 4] == b"\x00\x00\x00\x01":
            i += 4
        else:
            i += 1
            continue
        j = i
        while j < n - 3 and not (buf[j] == 0 and buf[j + 1] == 0 and buf[j + 2] == 1):
            j += 1
        if j >= n - 3:
            j = n
        else:
            while j > i and buf[j - 1] == 0:
                j -= 1
        yield buf[i:j]
        i = j


ALTO = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)


def hrd(b):
    n = b.ue() + 1
    b.u(4); b.u(4)
    for _ in range(n):
        b.ue(); b.ue(); b.u(1)
    b.u(5); b.u(5); b.u(5); b.u(5)


def le_sps(nal):
    r = {}
    b = Bits(desescapa(nal[1:]))
    r["profile_idc"] = b.u(8)
    cs = b.u(8)
    r["constraint_set"] = "".join(str((cs >> (7 - k)) & 1) for k in range(6))
    r["level_idc"] = b.u(8)
    r["sps_id"] = b.ue()
    if r["profile_idc"] in ALTO:
        cf = b.ue()
        r["chroma_format_idc"] = cf
        if cf == 3:
            b.u(1)
        b.ue(); b.ue(); b.u(1)
        if b.u(1):
            for i in range(8 if cf != 3 else 12):
                if b.u(1):
                    ult = prox = 8
                    for _ in range(16 if i < 6 else 64):
                        if prox:
                            prox = (ult + b.se() + 256) % 256
                        ult = prox or ult
    r["log2_max_frame_num_minus4"] = b.ue()
    poc = b.ue()
    r["pic_order_cnt_type"] = poc
    if poc == 0:
        b.ue()
    elif poc == 1:
        b.u(1); b.se(); b.se()
        for _ in range(b.ue()):
            b.se()
    r["max_num_ref_frames"] = b.ue()
    b.u(1)                                   # gaps_in_frame_num_value_allowed_flag
    w = (b.ue() + 1) * 16
    h = (b.ue() + 1) * 16
    fmo = b.u(1)
    r["frame_mbs_only_flag"] = fmo
    if not fmo:
        b.u(1)
        h *= 2
    b.u(1)                                   # direct_8x8_inference_flag
    if b.u(1):                               # frame_cropping_flag
        cl, cr, ct, cb = b.ue(), b.ue(), b.ue(), b.ue()
        w -= (cl + cr) * 2
        h -= (ct + cb) * (2 if fmo else 4)
    r["tamanho"] = f"{w}x{h}"
    vui = b.u(1)
    r["vui_parameters_present"] = bool(vui)
    if not vui:
        return r
    if b.u(1):                               # aspect_ratio_info_present_flag
        if b.u(8) == 255:
            b.u(16); b.u(16)
    if b.u(1):                               # overscan_info_present_flag
        b.u(1)
    if b.u(1):                               # video_signal_type_present_flag
        r["video_format"] = b.u(3)
        r["video_full_range_flag"] = b.u(1)
        if b.u(1):
            r["colour_primaries"] = b.u(8)
            r["transfer_characteristics"] = b.u(8)
            r["matrix_coefficients"] = b.u(8)
        else:
            r["colour_description"] = "ausente"
    else:
        r["video_signal_type"] = "ausente"
    if b.u(1):                               # chroma_loc_info_present_flag
        b.ue(); b.ue()
    if b.u(1):                               # timing_info_present_flag
        nu, ts = b.u(32), b.u(32)
        r["timing"] = f"num_units={nu} time_scale={ts} fixed={b.u(1)}"
    nal_hrd = b.u(1)
    if nal_hrd:
        hrd(b)
    vcl_hrd = b.u(1)
    if vcl_hrd:
        hrd(b)
    if nal_hrd or vcl_hrd:
        b.u(1)
    r["pic_struct_present_flag"] = b.u(1)
    br = b.u(1)
    r["bitstream_restriction_flag"] = br
    if br:
        r["motion_vectors_over_pic_boundaries_flag"] = b.u(1)
        r["max_bytes_per_pic_denom"] = b.ue()
        r["max_bits_per_mb_denom"] = b.ue()
        r["log2_max_mv_length_horizontal"] = b.ue()
        r["log2_max_mv_length_vertical"] = b.ue()
        r["max_num_reorder_frames"] = b.ue()
        r["max_dec_frame_buffering"] = b.ue()
    return r


def mostrar(nome, sps, tipos=None, tamanho=None):
    print(f"== {nome}" + (f"  ({tamanho} bytes)" if tamanho is not None else ""))
    if tipos:
        print("   NALs:", ", ".join(f"tipo{t}={c}" for t, c in sorted(tipos.items())))
    if sps is None:
        print("   NENHUM SPS")
        return 1
    print(f"   SPS ({len(sps)} bytes): {sps.hex()}")
    for k, v in le_sps(sps).items():
        print(f"     {k} = {v}")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "--hex":
        return mostrar("hex", bytes.fromhex(argv[1].replace(" ", "")))
    if not argv:
        print(__doc__)
        return 2
    ruim = 0
    for caminho in argv:
        with open(caminho, "rb") as f:
            buf = f.read()
        tipos, sps = collections.Counter(), None
        for nal in nals(buf):
            if not nal:
                continue
            tipos[nal[0] & 0x1F] += 1
            if (nal[0] & 0x1F) == 7 and sps is None:
                sps = nal
        ruim += mostrar(caminho, sps, tipos, len(buf))
        print()
    return ruim


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
