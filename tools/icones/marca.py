# SPDX-License-Identifier: MPL-2.0
# Codigo do gerador aberto; direitos de marca dos desenhos/saidas: DIREITOS-DA-MARCA.txt.
"""A marca do Quall para os ícones dos apps (`docs/telas-estudio.md` §4): o "Q" é um anel branco com a luz de
gravação vermelha no corte do anel, sobre azul-marinho escuro.

Uma geometria só, em unidades da marca (o mesmo desenho de 32 unidades do app: anel de raio 10,5 com traço de
3,6 centrado em 15;15, e a bolinha de raio 4,6 em 25,2;25,2). Para os ícones, a bolinha **corta** o anel: um
vão de `VAO` unidades em volta dela some do anel e deixa ver o fundo — é o "corte do O" do pedido do Bruno
(30/09). Daqui saem os PNGs (`desenhar`) e o caminho vetorial do Android (`caminho_do_anel`).
"""
from __future__ import annotations

import math

from PIL import Image, ImageDraw

# --- a marca, em unidades ---------------------------------------------------------------------------------
CX, CY = 15.0, 15.0          # centro do anel
R_ANEL = 10.5                # raio do meio do traço
TRACO = 3.6                  # espessura do traço
DX, DY = 25.2, 25.2          # centro da luz
R_LUZ = 4.6                  # raio da luz
VAO = 1.5                    # o corte em volta da luz

R_FORA = R_ANEL + TRACO / 2
R_DENTRO = R_ANEL - TRACO / 2
R_CORTE = R_LUZ + VAO

# A caixa da marca (do anel à luz), para centrar.
X0 = min(CX - R_FORA, DX - R_LUZ)
X1 = max(CX + R_FORA, DX + R_LUZ)
LADO = X1 - X0                         # 27,1
MEIO = (X0 + X1) / 2                   # 16,25

# --- cores ----------------------------------------------------------------------------------------------
BRANCO = (255, 255, 255)
VERMELHO = (255, 69, 58)               # #FF453A, o NO AR do app no escuro
MARINHO_ALTO = (0x15, 0x26, 0x52)      # o fundo: azul-marinho escuro, um degradê suave de cima para baixo
MARINHO_BAIXO = (0x0A, 0x14, 0x33)
MARINHO = (0x0F, 0x1C, 0x42)           # a cor única (fundo do Android, quem não faz degradê)


def hexa(c: tuple[int, int, int]) -> str:
    return "#%02X%02X%02X" % c


def degrade(lado: int, alto=MARINHO_ALTO, baixo=MARINHO_BAIXO) -> Image.Image:
    """O fundo: degradê vertical de `alto` para `baixo`."""
    col = Image.new("RGB", (1, lado))
    for y in range(lado):
        t = y / max(1, lado - 1)
        col.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(alto, baixo)))
    return col.resize((lado, lado))


def mascara_da_marca(lado: int, escala: float, ox: float, oy: float, *, traco_extra: float = 0.0):
    """As duas máscaras (anel cortado, luz) num quadro `lado`, com `escala` px por unidade e a origem da
    marca em (ox, oy) px. `traco_extra` engrossa o traço (em unidades) para os tamanhos minúsculos."""
    def px(x, y):
        return ox + (x - X0) * escala, oy + (y - X0) * escala

    anel = Image.new("L", (lado, lado), 0)
    d = ImageDraw.Draw(anel)
    rf, rd = R_FORA + traco_extra / 2, R_DENTRO - traco_extra / 2
    cx, cy = px(CX, CY)
    d.ellipse([cx - rf * escala, cy - rf * escala, cx + rf * escala, cy + rf * escala], fill=255)
    d.ellipse([cx - rd * escala, cy - rd * escala, cx + rd * escala, cy + rd * escala], fill=0)
    lx, ly = px(DX, DY)
    rc = R_CORTE * escala
    d.ellipse([lx - rc, ly - rc, lx + rc, ly + rc], fill=0)

    luz = Image.new("L", (lado, lado), 0)
    rl = R_LUZ * escala
    ImageDraw.Draw(luz).ellipse([lx - rl, ly - rl, lx + rl, ly + rl], fill=255)
    return anel, luz


def desenhar(lado: int, *, fracao: float = 0.586, fundo: Image.Image | None = None, traco_extra: float = 0.0,
             super_amostra: int = 8) -> Image.Image:
    """O ícone quadrado, sangrado: fundo + marca centrada ocupando `fracao` do lado. Desenha `super_amostra`
    vezes maior e reduz (borda suave sem depender de biblioteca de vetor)."""
    g = lado * super_amostra
    base = (fundo.resize((g, g)) if fundo is not None else degrade(g)).convert("RGB")
    escala = g * fracao / LADO
    o = (g - LADO * escala) / 2
    anel, luz = mascara_da_marca(g, escala, o, o, traco_extra=traco_extra)
    base.paste(Image.new("RGB", (g, g), BRANCO), (0, 0), anel)
    base.paste(Image.new("RGB", (g, g), VERMELHO), (0, 0), luz)
    return base.resize((lado, lado), Image.LANCZOS)


def placa_arredondada(lado: int, raio: float, super_amostra: int = 8) -> Image.Image:
    """Máscara L de um quadrado arredondado ocupando o quadro todo."""
    g = lado * super_amostra
    m = Image.new("L", (g, g), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, g - 1, g - 1], radius=raio * super_amostra, fill=255)
    return m.resize((lado, lado), Image.LANCZOS)


# --- o caminho vetorial (Android) ---------------------------------------------------------------------------

def _intersecoes(r_circ: float) -> tuple[float, float]:
    """Os dois ângulos (em volta do centro do anel) onde o círculo de raio `r_circ` cruza o círculo do corte."""
    d = math.hypot(DX - CX, DY - CY)
    base = math.atan2(DY - CY, DX - CX)
    # lei dos cossenos: r_corte² = r² + d² - 2 r d cos(θ)
    c = (r_circ ** 2 + d ** 2 - R_CORTE ** 2) / (2 * r_circ * d)
    meia = math.acos(max(-1.0, min(1.0, c)))
    return base - meia, base + meia


def caminho_do_anel(escala: float, ox: float, oy: float) -> str:
    """O anel com o corte, como `pathData` (SVG/Android): arco de fora pelo lado longo, arco do corte até o
    círculo de dentro, arco de dentro de volta, e o arco do corte fechando. Coordenadas em `escala` por unidade
    com a origem da marca em (ox, oy)."""
    def p(x, y):
        return f"{ox + (x - X0) * escala:.3f},{oy + (y - X0) * escala:.3f}"

    def no_anel(r, a):
        return CX + r * math.cos(a), CY + r * math.sin(a)

    fa1, fa2 = _intersecoes(R_FORA)
    da1, da2 = _intersecoes(R_DENTRO)
    rf, rd, rc = R_FORA * escala, R_DENTRO * escala, R_CORTE * escala
    f1, f2 = no_anel(R_FORA, fa1), no_anel(R_FORA, fa2)
    d1, d2 = no_anel(R_DENTRO, da1), no_anel(R_DENTRO, da2)
    return (f"M{p(*f2)} "
            f"A{rf:.3f},{rf:.3f} 0 1 1 {p(*f1)} "          # fora, de f2 a f1 pelo lado longo
            f"A{rc:.3f},{rc:.3f} 0 0 0 {p(*d1)} "          # o corte, de fora para dentro
            f"A{rd:.3f},{rd:.3f} 0 1 0 {p(*d2)} "          # dentro, de volta pelo lado longo
            f"A{rc:.3f},{rc:.3f} 0 0 0 {p(*f2)} Z")        # o corte, de dentro para fora


def caminho_da_luz(escala: float, ox: float, oy: float) -> str:
    lx, ly = ox + (DX - X0) * escala, oy + (DY - X0) * escala
    r = R_LUZ * escala
    return (f"M{lx - r:.3f},{ly:.3f} A{r:.3f},{r:.3f} 0 1 0 {lx + r:.3f},{ly:.3f} "
            f"A{r:.3f},{r:.3f} 0 1 0 {lx - r:.3f},{ly:.3f} Z")
