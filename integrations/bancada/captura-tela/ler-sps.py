#!/usr/bin/env python3
"""Le o SPS de um Annex-B e diz o que o emissor DECLAROU: nivel, e a faixa/matriz de cor da VUI.

Existe porque "faixa nao declarada no VUI" e "nivel acima do anunciado" sao duas causas
diferentes com o mesmo sintoma na tela, e a unica forma de separa-las e ler os bits. A regra
desta casa e que o emissor declare no bitstream o que ele de fato faz; este script confere.

  ./ler-sps.py arquivo.h264 [outro.h264 ...]
"""
import sys

def sps_nals(d):
    """Todo NAL de tipo 7, com os bytes de anti-emulacao ja removidos."""
    i, achados = 0, []
    while i + 4 < len(d):
        if d[i] == 0 and d[i+1] == 0:
            if d[i+2] == 1: h = i + 3
            elif d[i+2] == 0 and d[i+3] == 1: h = i + 4
            else:
                i += 1; continue
            j = h + 1
            while j + 2 < len(d):
                if d[j] == 0 and d[j+1] == 0 and d[j+2] in (0, 1): break
                j += 1
            if (d[h] & 0x1F) == 7:
                bruto = d[h+1:j]
                limpo, k = bytearray(), 0
                while k < len(bruto):
                    if k + 2 < len(bruto) and bruto[k] == 0 and bruto[k+1] == 0 and bruto[k+2] == 3:
                        limpo += b'\x00\x00'; k += 3
                    else:
                        limpo.append(bruto[k]); k += 1
                achados.append(bytes(limpo))
            i = h
        else:
            i += 1
    return achados

class Bits:
    def __init__(self, b): self.b, self.p = b, 0
    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.b[self.p >> 3]
            v = (v << 1) | ((byte >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v
    def ue(self):
        z = 0
        while self.u(1) == 0: z += 1
        return (1 << z) - 1 + (self.u(z) if z else 0)
    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)

FAIXA = {0: "limitada (tv)", 1: "cheia (full)"}
MATRIZ = {1: "BT.709", 5: "BT.470BG", 6: "SMPTE170M (BT.601)", 2: "nao especificada"}
PRIM = {1: "BT.709", 5: "BT.470BG", 6: "SMPTE170M", 2: "nao especificada"}

def ler(sps):
    r = {}
    b = Bits(sps)
    r["profile_idc"] = b.u(8); b.u(8); r["level_idc"] = b.u(8)
    b.ue()                                   # seq_parameter_set_id
    if r["profile_idc"] in (100,110,122,244,44,83,86,118,128,138,139,134,135):
        c = b.ue()
        if c == 3: b.u(1)
        b.ue(); b.ue(); b.u(1)
        if b.u(1):
            for i in range(8 if c != 3 else 12):
                if b.u(1):
                    tam, ultimo, prox = (16 if i < 6 else 64), 8, 8
                    for _ in range(tam):
                        if prox: prox = (ultimo + b.se() + 256) % 256
                        ultimo = prox or ultimo
    b.ue()                                   # log2_max_frame_num_minus4
    poc = b.ue()
    if poc == 0: b.ue()
    elif poc == 1:
        b.u(1); b.se(); b.se()
        for _ in range(b.ue()): b.se()
    b.ue(); b.u(1)                           # max_num_ref_frames, gaps
    larg = b.ue(); alt = b.ue()
    somente_quadro = b.u(1)
    if not somente_quadro: b.u(1)
    r["largura"] = (larg + 1) * 16
    r["altura"] = (alt + 1) * 16 * (2 - somente_quadro)
    b.u(1)                                   # direct_8x8
    if b.u(1):
        b.ue(); b.ue(); b.ue(); b.ue()       # cropping
    tem_vui = b.u(1)
    r["vui"] = bool(tem_vui)
    r["faixa"] = None; r["matriz"] = None; r["primarias"] = None
    r["sinal_de_video"] = False
    if tem_vui:
        if b.u(1):                           # aspect_ratio_info
            if b.u(8) == 255: b.u(16); b.u(16)
        if b.u(1): b.u(1)                    # overscan
        if b.u(1):                           # video_signal_type_present_flag
            r["sinal_de_video"] = True
            b.u(3)                           # video_format
            r["faixa"] = b.u(1)              # video_full_range_flag
            if b.u(1):                       # colour_description_present_flag
                r["primarias"] = b.u(8); b.u(8); r["matriz"] = b.u(8)
    return r

for caminho in sys.argv[1:]:
    d = open(caminho, "rb").read(2_000_000)
    todos = sps_nals(d)
    if not todos:
        print(f"{caminho}: nenhum SPS"); continue
    r = ler(todos[0])
    print(f"\n{caminho}   ({len(todos)} SPS nos primeiros 2 MB)")
    print(f"  profile_idc = {r['profile_idc']}   level_idc = {r['level_idc']} "
          f"(nivel {r['level_idc']//10}.{r['level_idc']%10})   {r['largura']}x{r['altura']}")
    if not r["vui"]:
        print("  VUI: AUSENTE — o emissor nao declara nada sobre cor nem faixa")
    elif not r["sinal_de_video"]:
        print("  VUI: presente, mas SEM video_signal_type — faixa e matriz NAO declaradas")
    else:
        print(f"  VUI: faixa = {FAIXA.get(r['faixa'], r['faixa'])}")
        if r["matriz"] is None:
            print("       matriz/primarias NAO declaradas (colour_description ausente)")
        else:
            print(f"       primarias = {PRIM.get(r['primarias'], r['primarias'])}   "
                  f"matriz = {MATRIZ.get(r['matriz'], r['matriz'])}")
