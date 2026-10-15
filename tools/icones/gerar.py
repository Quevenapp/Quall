#!/usr/bin/env python3
"""Gera os ícones dos quatro apps a partir da mesma marca (`marca.py`).

    python3 tools/icones/gerar.py            # escreve tudo no lugar de cada app
    python3 tools/icones/gerar.py --previa P # e uma folha com todos lado a lado em P

O pedido (Bruno, 30/09): "os ícones do Windows, Android, iOS e Mac dos launchers / atalho / exe como foi feito na
home do iOS / Android: Q em branco com bolinha vermelha (rec) no corte do O, sobre fundo azul-marinho escuro".

O que sai, e por quê cada um tem a forma que tem:

- **iOS** — `apps/ios/Quall/App/Assets.xcassets/AppIcon.appiconset`: um PNG de 1024, quadrado e sem alfa (o
  sistema arredonda; o Xcode 14 em diante gera os outros tamanhos de um só, também para o iOS 15).
- **Android** — o ícone adaptativo em vetor (`res/drawable/ic_launcher_*.xml`): fundo em degradê, a marca em
  primeiro plano com 46 dp de lado (dentro do círculo seguro de 66 dp), e a camada monocromática do Android 13
  (o tema do sistema pinta a marca de uma cor só: por isso o corte é geometria de verdade, e não um disco da cor
  do fundo por cima). Mais o PNG de 512 da ficha do Play.
- **Mac** — `apps/macos/Empacotar/Quall.icns`: no macOS 11 em diante o desenho do ícone inclui a placa (quadrado
  arredondado de 824 em 1024, com sombra), e o sistema não recorta nada.
- **Windows** — `apps/windows/quall.ico` (16 a 256, PNG dentro do ICO), que o `build.rs` embute no
  `quall-app.exe` como recurso; o atalho e "Programas e Recursos" leem o ícone do `.exe`. Placa arredondada; nos
  tamanhos de 16 a 24 a marca ocupa mais da placa e o traço engrossa, para não sumir na barra de tarefas. E os
  três logos do pacote MSIX da câmera virtual (`integrations/camera-windows/msix/Assets`).
"""
from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marca as m  # noqa: E402

RAIZ = Path(__file__).resolve().parents[2]


def png(im: Image.Image) -> bytes:
    b = BytesIO()
    im.save(b, "PNG", optimize=True)
    return b.getvalue()


# --- iOS -----------------------------------------------------------------------------------------------------

def ios() -> list[Path]:
    cat = RAIZ / "apps/ios/Quall/App/Assets.xcassets"
    conj = cat / "AppIcon.appiconset"
    conj.mkdir(parents=True, exist_ok=True)
    (cat / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    m.desenhar(1024).convert("RGB").save(conj / "AppIcon-1024.png", optimize=True)   # sem alfa: a App Store recusa
    (conj / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    return [conj / "AppIcon-1024.png"]


# --- Android -------------------------------------------------------------------------------------------------

LADO_ANDROID = 108.0
MARCA_ANDROID = 46.0        # dp: a marca inteira cabe no círculo seguro de 66 dp (a ponta da luz fica a ~29 dp do centro)

CABECALHO_VETOR = '''<?xml version="1.0" encoding="utf-8"?>
<!-- Gerado por tools/icones/gerar.py (a marca em tools/icones/marca.py). Não editar à mão. -->
'''


def android() -> list[Path]:
    res = RAIZ / "apps/android/app/src/main/res"
    u = MARCA_ANDROID / m.LADO
    o = (LADO_ANDROID - MARCA_ANDROID) / 2
    anel, luz = m.caminho_do_anel(u, o, o), m.caminho_da_luz(u, o, o)
    saidas = []

    fundo = res / "drawable/ic_launcher_background.xml"
    fundo.write_text(CABECALHO_VETOR + f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- Azul-marinho escuro, um degradê suave de cima para baixo (o mesmo do iOS, do Mac e do Windows). -->
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="54"
                android:startY="0"
                android:endX="54"
                android:endY="108"
                android:startColor="{m.hexa(m.MARINHO_ALTO)}"
                android:endColor="{m.hexa(m.MARINHO_BAIXO)}" />
        </aapt:attr>
    </path>
</vector>
''')
    saidas.append(fundo)

    frente = res / "drawable/ic_launcher_foreground.xml"
    frente.write_text(CABECALHO_VETOR + f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- O "Q": o anel branco, cortado em volta da luz. -->
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{anel}" />
    <!-- A luz de gravação, no corte. -->
    <path
        android:fillColor="{m.hexa(m.VERMELHO)}"
        android:pathData="{luz}" />
</vector>
''')
    saidas.append(frente)

    mono = res / "drawable/ic_launcher_monochrome.xml"
    mono.write_text(CABECALHO_VETOR + f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- O ícone do tema (Android 13): o sistema pinta tudo de uma cor; o corte separa a luz do anel. -->
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{anel}" />
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{luz}" />
</vector>
''')
    saidas.append(mono)

    adapt = res / "mipmap-anydpi-v26/ic_launcher.xml"
    adapt.write_text('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')
    saidas.append(adapt)

    # A ficha do Play: 512 × 512, quadrado (o Play aplica a máscara).
    loja = RAIZ / "tools/icones/loja"
    loja.mkdir(parents=True, exist_ok=True)
    m.desenhar(512).save(loja / "play-512.png", optimize=True)
    saidas.append(loja / "play-512.png")
    return saidas


# --- Mac -----------------------------------------------------------------------------------------------------

def icone_do_mac(lado: int) -> Image.Image:
    """A placa do macOS 11+: quadrado arredondado de 824/1024 do lado, raio 185/1024, sombra embaixo."""
    sa = 4
    g = lado * sa
    placa = round(g * 824 / 1024)
    raio = g * 185.4 / 1024
    margem = (g - placa) // 2
    pequeno = lado <= 32
    rosto = m.desenhar(placa // sa, fracao=0.62 if pequeno else 0.586,
                       traco_extra=0.9 if lado <= 16 else (0.5 if lado <= 32 else 0.0)).resize((placa, placa), Image.LANCZOS)
    tela = Image.new("RGBA", (g, g), (0, 0, 0, 0))
    mascara = m.placa_arredondada(placa // sa, raio / sa).resize((placa, placa), Image.LANCZOS)
    # A sombra: a mesma placa, preta, descida e borrada.
    sombra = Image.new("RGBA", (g, g), (0, 0, 0, 0))
    preto = Image.new("RGBA", (placa, placa), (0, 0, 0, 90))
    sombra.paste(preto, (margem, margem + round(g * 10 / 1024)), mascara)
    sombra = sombra.filter(ImageFilter.GaussianBlur(g * 10 / 1024))
    tela = Image.alpha_composite(tela, sombra)
    tela.paste(rosto.convert("RGBA"), (margem, margem), mascara)
    return tela.resize((lado, lado), Image.LANCZOS)


def mac() -> list[Path]:
    destino = RAIZ / "apps/macos/Empacotar/Quall.icns"
    with tempfile.TemporaryDirectory() as t:
        conj = Path(t) / "Quall.iconset"
        conj.mkdir()
        for base in (16, 32, 128, 256, 512):
            icone_do_mac(base).save(conj / f"icon_{base}x{base}.png")
            icone_do_mac(base * 2).save(conj / f"icon_{base}x{base}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(conj), "-o", str(destino)], check=True)
    return [destino]


# --- Windows -------------------------------------------------------------------------------------------------

TAMANHOS_WINDOWS = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)


def icone_do_windows(lado: int) -> Image.Image:
    """Placa arredondada que ocupa o quadro (raio ~20 %). Nos minúsculos a marca cresce e o traço engrossa."""
    if lado <= 24:
        fracao, extra = 0.70, 1.0
    elif lado <= 48:
        fracao, extra = 0.64, 0.4
    else:
        fracao, extra = 0.586, 0.0
    rosto = m.desenhar(lado, fracao=fracao, traco_extra=extra).convert("RGBA")
    mascara = m.placa_arredondada(lado, max(2.0, lado * 0.2))
    tela = Image.new("RGBA", (lado, lado), (0, 0, 0, 0))
    tela.paste(rosto, (0, 0), mascara)
    return tela


def ico(imagens: list[Image.Image]) -> bytes:
    """Um `.ico` com uma imagem PNG por tamanho (Windows Vista em diante lê PNG dentro do ICO)."""
    dados = [png(im) for im in imagens]
    cab = struct.pack("<HHH", 0, 1, len(imagens))
    deslocamento = 6 + 16 * len(imagens)
    entradas = b""
    for im, d in zip(imagens, dados):
        w, h = im.size
        entradas += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(d), deslocamento)
        deslocamento += len(d)
    return cab + entradas + b"".join(dados)


def windows() -> list[Path]:
    destino = RAIZ / "apps/windows/quall.ico"
    destino.write_bytes(ico([icone_do_windows(t) for t in TAMANHOS_WINDOWS]))
    saidas = [destino]
    # Os logos do pacote MSIX da câmera virtual (eram quadrados de preenchimento de ~200 bytes).
    msix = RAIZ / "integrations/camera-windows/msix/Assets"
    for nome, lado in (("Square150x150Logo.png", 150), ("Square44x44Logo.png", 44), ("StoreLogo.png", 50)):
        icone_do_windows(lado).save(msix / nome, optimize=True)
        saidas.append(msix / nome)
    return saidas


# --- a folha de prévia ---------------------------------------------------------------------------------------

def previa(caminho: Path) -> None:
    from PIL import ImageDraw
    fundo = (36, 36, 44)
    folha = Image.new("RGB", (1560, 560), fundo)
    d = ImageDraw.Draw(folha)
    # iOS (com o arredondamento que o sistema aplica)
    ios_im = m.desenhar(300).convert("RGBA")
    folha.paste(ios_im, (30, 60), m.placa_arredondada(300, 300 * 0.2237))
    d.text((30, 30), "iOS (o sistema arredonda)", fill=(220, 220, 230))
    # Android (máscara redonda e a de squircle)
    a = Image.new("RGBA", (300, 300))
    a.paste(m.degrade(300).convert("RGBA"))
    fr = m.desenhar(300, fracao=MARCA_ANDROID / 72 * 0.86, fundo=m.degrade(300))
    circ = Image.new("L", (300, 300), 0)
    ImageDraw.Draw(circ).ellipse([0, 0, 299, 299], fill=255)
    folha.paste(fr.convert("RGBA"), (370, 60), circ)
    d.text((370, 30), "Android (máscara redonda)", fill=(220, 220, 230))
    # Mac
    folha.paste(icone_do_mac(300), (710, 60), icone_do_mac(300))
    d.text((710, 30), "Mac (placa e sombra)", fill=(220, 220, 230))
    # Windows, vários tamanhos
    x = 1060
    d.text((1060, 30), "Windows (256, 48, 32, 24, 16)", fill=(220, 220, 230))
    for t in (256, 48, 32, 24, 16):
        im = icone_do_windows(t)
        folha.paste(im, (x, 60 + (256 - t)), im)
        x += t + 18
    # Tamanhos reais pequenos em fila, para ver a leitura
    d.text((30, 400), "tamanhos reais: 16, 20, 24, 32, 48, 64 (Windows) e 29, 40, 60 (iOS)", fill=(220, 220, 230))
    x = 30
    for t in (16, 20, 24, 32, 48, 64):
        im = icone_do_windows(t)
        folha.paste(im, (x, 440), im)
        x += t + 16
    for t in (29, 40, 60):
        im = m.desenhar(t).convert("RGBA")
        folha.paste(im, (x, 440), m.placa_arredondada(t, t * 0.2237))
        x += t + 16
    folha.save(caminho)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--previa", type=Path, help="também grava uma folha de prévia neste caminho")
    a = ap.parse_args()
    for nome, f in (("iOS", ios), ("Android", android), ("Mac", mac), ("Windows", windows)):
        for p in f():
            print(f"{nome:8} {p.relative_to(RAIZ)}  ({p.stat().st_size} B)")
    if a.previa:
        previa(a.previa)
        print(f"prévia   {a.previa}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
