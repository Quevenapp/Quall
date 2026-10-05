#!/usr/bin/env python3
"""Prova da gravação da DV no S24 (GravacaoDvService), sem toque, com o Mac conferindo o MP4.

- `--arquivo A.dv`: a `libqualldv` toca quadros gravados em laço no lugar do USB
  (`camera_dv_arquivo`); `--usb`: a filmadora plugada (com a permissão USB já dada).
- Grava `--segundos`, para (ou, com `--matar`, mata o processo no meio: a gravação interrompida),
  puxa o MP4 da Galeria (Movies/Quall) e mede com ffprobe: resolução, taxa, duração, som.
- `--sincronia`: o arquivo é o `barras-e-sincronia.dv` (clarão branco e bipe no mesmo quadro a cada
  2,002 s depois de 4 s de barras). Mede o atraso do som contra a imagem em cada clarão, e a cor
  das barras contra a fonte.

Não roda com o aparelho em uso: com a tela acesa e desbloqueada, para e diz.

    prova-gravacao.py --serial S --saida DIR (--arquivo A.dv | --usb) [--segundos 60] [--matar] [--sincronia]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

PKG = "com.quall.android"
PREFS = "shared_prefs/quall-bancada.xml"
BANCADA = f"{PKG}/.bancada.BancadaDaCameraDvActivity"


def adb(serial: str, *args: str, entrada: bytes | None = None) -> str:
    r = subprocess.run(["adb", "-s", serial, *args], input=entrada, capture_output=True)
    return r.stdout.decode(errors="replace")


def em_uso(serial: str) -> bool:
    power = adb(serial, "shell", "dumpsys", "power")
    janela = adb(serial, "shell", "dumpsys", "window")
    acordado = "mWakefulness=Awake" in power
    bloqueado = "isKeyguardShowing=true" in janela
    return acordado and not bloqueado


def gravar_prefs(serial: str, chaves: dict[str, str]) -> None:
    existe = adb(serial, "shell", "run-as", PKG, "ls", PREFS).strip()
    atual = adb(serial, "shell", "run-as", PKG, "cat", PREFS) if "No such file" not in existe else ""
    if "<map" not in atual:
        if existe and "No such file" not in existe:
            raise RuntimeError(f"não consegui ler {PREFS}; não escrevo por cima")
        atual = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n"
    for nome, linha in chaves.items():
        atual = re.sub(rf'\s*<[^>]*name="{nome}"[^>]*?(/>|>[^<]*</string>)', "", atual)
        atual = atual.replace("</map>", f"    {linha}\n</map>")
    adb(serial, "shell", "am", "force-stop", PKG)
    adb(serial, "exec-in", "run-as", PKG, "sh", "-c", f"cat > {PREFS}", entrada=atual.encode())


def ffprobe(arq: Path) -> dict:
    r = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(arq)],
                       capture_output=True, text=True)
    return json.loads(r.stdout or "{}")


def sincronia(mp4: Path) -> None:
    """O clarão (Y médio alto) e o bipe (energia do som) em cada ciclo de 2,002 s."""
    import numpy as np
    W, H = 320, 180
    cru = subprocess.run(["ffmpeg", "-v", "error", "-i", str(mp4), "-vf", f"scale={W}:{H}", "-f", "rawvideo",
                          "-pix_fmt", "gray", "-"], capture_output=True).stdout
    y = np.frombuffer(cru, np.uint8).reshape(-1, H, W).mean(axis=(1, 2))
    fps = 30000 / 1001
    so = subprocess.run(["ffmpeg", "-v", "error", "-i", str(mp4), "-map", "0:a:0", "-ac", "1", "-ar", "48000",
                         "-f", "s16le", "-"], capture_output=True).stdout
    a = np.abs(np.frombuffer(so, np.int16).astype(float))
    clarões = [i for i in range(1, len(y)) if y[i] > 150 and y[i - 1] < 100]
    bipes = []
    limiar = 3000
    i = 0
    while i < len(a):
        if a[i] > limiar:
            bipes.append(i)
            i += 48000
        else:
            i += 1
    print(f"clarões: {len(clarões)} (quadros {clarões[:6]}...), bipes: {len(bipes)}")
    difs = []
    for c in clarões:
        tv = c / fps
        prox = min(bipes, key=lambda b: abs(b / 48000 - tv), default=None)
        if prox is not None and abs(prox / 48000 - tv) < 0.5:
            difs.append((prox / 48000 - tv) * 1000)
    if difs:
        print("som - imagem por clarão (ms): " + ", ".join(f"{d:+.1f}" for d in difs))
        print(f"média {np.mean(difs):+.1f} ms, faixa {min(difs):+.1f} a {max(difs):+.1f} ms "
              f"(a resolução da imagem é um quadro, 33,4 ms)")
    # barras: médias YUV por barra no quadro 60 (a fonte: 6 faixas de 120 px em 854 -> 1280)
    cru = subprocess.run(["ffmpeg", "-v", "error", "-i", str(mp4), "-vf", "select=eq(n\\,60)", "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"], capture_output=True).stdout
    Wf, Hf = 1280, 720
    Y = np.frombuffer(cru[:Wf * Hf], np.uint8).reshape(Hf, Wf)
    U = np.frombuffer(cru[Wf * Hf:Wf * Hf * 5 // 4], np.uint8).reshape(Hf // 2, Wf // 2)
    V = np.frombuffer(cru[Wf * Hf * 5 // 4:], np.uint8).reshape(Hf // 2, Wf // 2)
    nomes = ["branco", "vermelho", "verde", "azul", "cinza", "preto"]
    for k, nome in enumerate(nomes):
        x0 = int((k * 120 + 30) * Wf / 720)
        x1 = int((k * 120 + 90) * Wf / 720)
        print(f"  barra {nome:8s}: Y {Y[200:500, x0:x1].mean():6.1f}  U {U[100:250, x0//2:x1//2].mean():6.1f}  "
              f"V {V[100:250, x0//2:x1//2].mean():6.1f}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--saida", required=True)
    ap.add_argument("--arquivo")
    ap.add_argument("--usb", action="store_true")
    ap.add_argument("--segundos", type=int, default=60)
    ap.add_argument("--matar", action="store_true")
    ap.add_argument("--sincronia", action="store_true")
    ap.add_argument("--forcar", action="store_true", help="roda mesmo com a tela acesa")
    ap.add_argument("--tela-apagada", action="store_true", help="apaga a tela depois de começar")
    a = ap.parse_args()
    s = a.serial
    saida = Path(a.saida)
    saida.mkdir(parents=True, exist_ok=True)
    if em_uso(s) and not a.forcar:
        print("PARADO: a tela do S24 está acesa e desbloqueada (o Pessoa Exemplo está usando?)")
        return 3
    if "ServiceRecord" in adb(s, "shell", "dumpsys", "activity", "services", PKG):
        print("PARADO: há serviço do Quall de pé (sessão ou gravação)")
        return 3
    chaves = {"camera_dv": '<boolean name="camera_dv" value="true" />'}
    if a.arquivo:
        subprocess.run(["adb", "-s", s, "push", "-q", a.arquivo, "/data/local/tmp/amostra-dv.dv"], check=True)
        adb(s, "shell", "run-as", PKG, "cp", "/data/local/tmp/amostra-dv.dv", "files/amostra-dv.dv")
        adb(s, "shell", "rm", "-f", "/data/local/tmp/amostra-dv.dv")
        chaves["camera_dv_arquivo"] = f'<string name="camera_dv_arquivo">/data/user/0/{PKG}/files/amostra-dv.dv</string>'
    gravar_prefs(s, chaves)
    adb(s, "logcat", "-c")
    t0 = time.time()
    adb(s, "shell", "am", "start", "-n", BANCADA, "--es", "fonte", "gravar-arquivo" if a.arquivo else "gravar-usb")
    if a.tela_apagada:
        # A porta de bancada acende a tela para subir o serviço em primeiro plano; aqui ela se apaga
        # e a gravação segue com a tela desligada (o caso da fita longa).
        time.sleep(4)
        adb(s, "shell", "input", "keyevent", "KEYCODE_SLEEP")
        print("tela apagada durante a gravação")
    time.sleep(a.segundos)
    if a.matar:
        adb(s, "shell", "am", "force-stop", PKG)
        print("processo morto no meio da gravação")
        time.sleep(2)
        # a próxima abertura do app remonta e publica o pendente
        adb(s, "shell", "am", "start", "-n", f"{PKG}/.ui.MainActivity")
        time.sleep(8)
        adb(s, "shell", "input", "keyevent", "KEYCODE_HOME")
    else:
        adb(s, "shell", "am", "start", "-n", BANCADA, "--es", "fonte", "parar-gravacao")
        for _ in range(30):
            time.sleep(1)
            if "gravação: " in adb(s, "logcat", "-d", "-s", "QuallDv:I"):
                break
    log = adb(s, "logcat", "-d", "-s", "QuallDv:*", "AndroidRuntime:E")
    (saida / "logcat.txt").write_text(log)
    print("\n".join(l for l in log.splitlines() if re.search(r"gravador|gravação|mp4|remont|publicad", l))[-3000:])
    lista = adb(s, "shell", "ls", "-t", "/sdcard/Movies/Quall/").split()
    if not lista:
        print("nenhum arquivo em Movies/Quall")
        return 1
    nome = lista[0]
    mp4 = saida / nome
    subprocess.run(["adb", "-s", s, "pull", "-q", f"/sdcard/Movies/Quall/{nome}", str(mp4)], check=True)
    info = ffprobe(mp4)
    (saida / "ffprobe.json").write_text(json.dumps(info, indent=1))
    f = info.get("format", {})
    print(f"\n{nome}: {int(f.get('size', 0)) / 1e6:.1f} MB, duração {float(f.get('duration', 0)):.2f} s, "
          f"{int(f.get('bit_rate', 0)) / 1e6:.2f} Mbit/s, marcas {f.get('tags', {}).get('major_brand')}")
    for st in info.get("streams", []):
        if st["codec_type"] == "video":
            print(f"  vídeo: {st['codec_name']} {st.get('profile')} {st['width']}x{st['height']} "
                  f"{st.get('avg_frame_rate')} quadros={st.get('nb_frames')} "
                  f"{int(st.get('bit_rate', 0)) / 1e6:.2f} Mbit/s cor={st.get('color_range')}/"
                  f"{st.get('color_space')}/{st.get('color_primaries')}/{st.get('color_transfer')} "
                  f"duração {st.get('duration')}")
        else:
            print(f"  som: {st['codec_name']} {st.get('profile')} {st.get('sample_rate')} Hz "
                  f"{st.get('channels')} canais {int(st.get('bit_rate', 0)) / 1e3:.0f} kbit/s "
                  f"duração {st.get('duration')} início {st.get('start_time')}")
    print(f"(gravou por {time.time() - t0:.0f} s de relógio)")
    # A tela estava livre no começo (é a condição para rodar): apaga de novo o que a bancada acendeu.
    adb(s, "shell", "input", "keyevent", "KEYCODE_SLEEP")
    if a.sincronia:
        sincronia(mp4)
    return 0


if __name__ == "__main__":
    sys.exit(main())
