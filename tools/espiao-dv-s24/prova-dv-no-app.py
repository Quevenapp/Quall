#!/usr/bin/env python3
"""Prova da câmera DV no app de produto (fase B), com o Mac recebendo pelo `quall-probe receber-video`.

Dois modos:
- `--arquivo AMOSTRA.dv`: a `libqualldv` toca quadros gravados pelo espião, em laço, no lugar do
  USB (bandeira `camera_dv_arquivo`). Prova o caminho inteiro (decodificação, ImageWriter, encoder,
  rede, receptor) **sem filmadora e sem diálogo de permissão USB**;
- sem `--arquivo`: a filmadora plugada, com a permissão USB já dada ao Quall (o diálogo é um toque
  do Pessoa Exemplo, pela tela: Espelhar com "Filmadora USB"). Sem ela, o roteiro para e diz.

O que faz:
1. confere que o Quall não está em sessão, pelo `MirrorService` no `dumpsys`;
2. grava as duas chaves de bancada no XML do app (as outras chaves ficam como estão);
3. sobe a sessão pela porta de bancada (a tela fica atrás do bloqueio) e lê o PIN da notificação;
4. recebe N segundos no Mac com o `quall-probe receber-video --saida`;
5. para o espelhamento e traz o logcat `QuallDv`/`QuallMirror`.

Não instala APK: a sessão principal decide quando trocar o APK do S24.

    prova-dv-no-app.py --serial S --probe CAMINHO/quall-probe --saida DIR [--arquivo A.dv] [--segundos 20]
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ / "apps" / "android" / "tools"))
from aparelho import Aparelho  # noqa: E402

PKG = "com.quall.android"
PREFS = "shared_prefs/quall-bancada.xml"


def adb(serial: str, *args: str, entrada: bytes | None = None) -> str:
    r = subprocess.run(["adb", "-s", serial, *args], input=entrada, capture_output=True)
    return r.stdout.decode(errors="replace")


def gravar_prefs(serial: str, chaves: dict[str, str]) -> None:
    # `shell`, e não `exec-out`: no S24 por Wi-Fi o `exec-out run-as cat` voltou vazio, e um XML
    # novo por cima apagaria as outras chaves de bancada. Sem leitura confiável, não escreve.
    existe = adb(serial, "shell", "run-as", PKG, "ls", PREFS).strip()
    atual = adb(serial, "shell", "run-as", PKG, "cat", PREFS) if "No such file" not in existe else ""
    if "<map" not in atual:
        if existe and "No such file" not in existe:
            raise RuntimeError(f"não consegui ler {PREFS} (existe: {existe!r}); não escrevo por cima")
        atual = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n"
    for nome, linha in chaves.items():
        atual = re.sub(rf'\s*<[^>]*name="{nome}"[^>]*?(/>|>[^<]*</string>)', "", atual)
        atual = atual.replace("</map>", f"    {linha}\n</map>")
    adb(serial, "shell", "am", "force-stop", PKG)
    adb(serial, "exec-in", "run-as", PKG, "sh", "-c", f"mkdir -p shared_prefs && cat > {PREFS}",
        entrada=atual.encode())
    print("prefs de bancada:\n" + adb(serial, "shell", "run-as", PKG, "cat", PREFS))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--probe", required=True)
    ap.add_argument("--saida", required=True)
    ap.add_argument("--arquivo")
    ap.add_argument("--segundos", type=int, default=20)
    ap.add_argument("--porta", type=int, default=7877)
    a = ap.parse_args()
    saida = Path(a.saida)
    saida.mkdir(parents=True, exist_ok=True)

    servicos = adb(a.serial, "shell", "dumpsys", "activity", "services", "com.quall.android")
    if "MirrorService" in servicos and "app=ProcessRecord" in servicos:
        print("PARADO: o MirrorService do Quall está de pé no aparelho (sessão com o Pessoa Exemplo?)")
        return 3

    chaves = {"camera_dv": '<boolean name="camera_dv" value="true" />'}
    if a.arquivo:
        remoto = "/data/local/tmp/amostra-dv.dv"
        subprocess.run(["adb", "-s", a.serial, "push", "-q", a.arquivo, remoto], check=True)
        adb(a.serial, "shell", "run-as", PKG, "cp", remoto, "files/amostra-dv.dv")
        caminho = f"/data/user/0/{PKG}/files/amostra-dv.dv"
        chaves["camera_dv_arquivo"] = f'<string name="camera_dv_arquivo">{caminho}</string>'
    else:
        chaves["camera_dv_arquivo"] = '<string name="camera_dv_arquivo"></string>'
    gravar_prefs(a.serial, chaves)

    # A tela do S24 fica atrás do bloqueio (só o Pessoa Exemplo abre): a sessão sobe pela porta de bancada
    # (`BancadaDaCameraDvActivity`, só no APK debug), e o PIN vem da notificação.
    e = Aparelho(a.serial, "s24")
    e.limpa_logcat()
    fonte = "arquivo" if a.arquivo else "usb"
    adb(a.serial, "shell", "am", "start", "-n", f"{PKG}/.bancada.BancadaDaCameraDvActivity", "--es", "fonte", fonte)
    ip = e.ip()
    endereco = f"{ip}:{a.porta}"
    pin = ""
    for _ in range(20):
        time.sleep(1.0)
        notif = adb(a.serial, "shell", "dumpsys", "notification", "--noredact")
        m = re.search(r"Esperando um receptor.{0,6}PIN (\d{6})", notif)
        if m:
            pin = m.group(1)
            break
        log = adb(a.serial, "logcat", "-d", "-s", "QuallDv:*", "QuallMirror:E")
        if "sem filmadora plugada ou sem permissão USB" in log:
            print("PARADO: o Quall ainda não tem a permissão USB da filmadora — toque do Pessoa Exemplo")
            return 4
    if not pin:
        print("o PIN não apareceu na notificação")
        print(adb(a.serial, "logcat", "-d", "-s", "QuallDv:*", "QuallMirror:*"))
        return 1
    print(f"emissor em {endereco}, PIN {pin}")
    h264 = saida / "recebido.h264"
    r = subprocess.run([a.probe, "receber-video", "--ip", endereco, "--pin", pin,
                        "--segundos", str(a.segundos), "--saida", str(h264)],
                       capture_output=True, text=True)
    (saida / "probe.txt").write_text(r.stdout + r.stderr)
    print(r.stdout[-3000:], r.stderr[-2000:])
    adb(a.serial, "shell", "am", "start", "-n", f"{PKG}/.bancada.BancadaDaCameraDvActivity", "--es", "fonte", "parar")
    time.sleep(3)
    log = adb(a.serial, "logcat", "-d", "-s", "QuallDv:*", "QuallMirror:*", "QuallCameraEncSource:*",
              "QuallSurfaceEnc:*", "AndroidRuntime:E")
    (saida / "logcat.txt").write_text(log)
    print("\n".join(l for l in log.splitlines() if "QuallDv" in l)[-4000:])
    print(f"gravado: {h264} ({h264.stat().st_size if h264.exists() else 0} bytes)")
    return 0 if h264.exists() and h264.stat().st_size > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
