#!/usr/bin/env python3
"""
A **curva de resposta** do enlace ao bitrate, medida numa sessão só, Android → Android.

Existe porque a pergunta desta frente — *como a perda responde ao bitrate oferecido, neste
enlace?* — não sobrevive ao método padrão desta bancada. `docs/bancada.md` repete, em três
frentes diferentes, que **duas corridas seguidas em 2,4 GHz não são comparáveis entre si**: o
rádio anda ao longo da medição. Sete pontos de curva medidos em sete corridas de 30 s medem sete
janelas de rádio diferentes, e a resposta que sai é a soma de duas coisas.

Com o bitrate trocado **em voo** (`MediaCodec.setParameters`, `PARAMETER_KEY_VIDEO_BITRATE`), os
sete pontos cabem numa sessão de dois minutos: mesmo encoder, mesma associação DTLS, mesma janela
de rádio, mesmo `MediaProjection`. É a diferença entre comparar horas e comparar minutos.

    apps/android/tools/aa-escada.py --sentido a10s-tablet \
        --escada 4000,3000,2000,1500,1000,700,500 --passo 20

Cada degrau vira uma linha de curva com:

  * **bitrate pedido** — o que foi para `setParameters`;
  * **bitrate entregue no fio** — bytes que saíram do encoder, do `janela_do_fio` do emissor.
    Os dois **não** coincidem por construção, e é por isso que os dois saem;
  * **pacotes/s, perda exata, quadros, suspeitos, IDRs quebrados** — do `janela_do_enlace` do
    receptor, com o denominador do emissor (ver `JanelaDoEnlace`).

# O alinhamento dos dois lados, e por que ele é grosseiro de propósito

Os dois aparelhos carimbam em relógios diferentes. Este roteiro **não** tenta casá-los: ele usa a
ordem das janelas dentro de cada corrida e o fato de que os degraus são longos (20 s) contra
janelas curtas (0,5-1 s). Cada degrau descarta as [DESCARTE_S] primeiras janelas — o transitório
em que o encoder ainda está atravessando o degrau anterior —, e o que sobra é o regime.

Um degrau que não sobreviver ao descarte sai da tabela em vez de sair errado.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

AQUI = Path(__file__).resolve().parent
sys.path.insert(0, str(AQUI))
from aparelho import Aparelho  # noqa: E402

# `aa-corrida.py` tem hífen no nome e não é importável por `import`. Ele é reaproveitado, e não
# copiado, porque `sobe_emissor` carrega três armadilhas de bancada (o diálogo do `systemui` que
# sobrevive ao `force-stop`, o consentimento diferente entre Android 11 e 16, a bolha de dica que
# esconde o botão) que custaram um lote inteiro para achar. Copiá-las seria copiar o direito de
# perdê-las.
_spec = importlib.util.spec_from_file_location("aa_corrida", AQUI / "aa-corrida.py")
aa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aa)

PKG = "com.quall.android"

#: Segundos descartados no começo de cada degrau. Um degrau é aplicado no laço de dreno do
#: encoder (≤10 ms), mas o **efeito** no fio leva o tempo de o controle de taxa do codec
#: convergir, e a janela que atravessa a troca mistura dois bitrates.
DESCARTE_S = 4.0


def prefs(serial: str, porta: int, escada: list[int], passo_ms: int,
          janela_fio_ms: int, janela_enlace_ms: int, bitrate_kbps: int = 0) -> None:
    """As preferências de bancada desta frente, escritas por `run-as`.

    Não usa `bancada-prefs.sh`: aquele roteiro escreve seis chaves fixas e apagaria as desta
    frente. As chaves de IDR ficam no **padrão de produto** de propósito — o que esta corrida
    varia é o bitrate, e mais nada.
    """
    xml = f"""<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name="porta" value="{porta}" />
    <string name="prefixo_nome">esc-</string>
    <string name="escada_kbps">{",".join(str(k) for k in escada)}</string>
    <int name="escada_passo_ms" value="{passo_ms}" />
    <int name="janela_do_fio_ms" value="{janela_fio_ms}" />
    <int name="janela_do_enlace_ms" value="{janela_enlace_ms}" />
    <int name="bitrate_kbps" value="{bitrate_kbps}" />
</map>"""
    subprocess.run(["adb", "-s", serial, "shell", "am", "force-stop", PKG],
                   check=True, capture_output=True, text=True)
    subprocess.run(
        ["adb", "-s", serial, "shell",
         f"run-as {PKG} sh -c 'mkdir -p /data/data/{PKG}/shared_prefs && "
         f"cat > /data/data/{PKG}/shared_prefs/quall-bancada.xml'"],
        input=xml, check=True, capture_output=True, text=True,
    )
    lido = subprocess.run(
        ["adb", "-s", serial, "shell",
         f"run-as {PKG} cat /data/data/{PKG}/shared_prefs/quall-bancada.xml"],
        capture_output=True, text=True,
    ).stdout
    # Conferido de volta, e não suposto: uma frente desta bancada rodou um lote inteiro com o
    # sinalizador desligado por confiar na escrita.
    if "escada_kbps" not in lido and escada:
        raise RuntimeError(f"{serial}: a escada não chegou às preferências:\n{lido}")


def janelas_do_fio(bruto: str) -> list[dict]:
    """`janela_do_fio ms=… bytes=… quadros=… kbps=… bitrate_pedido=…` do emissor."""
    saida = []
    for m in re.finditer(
        r"janela_do_fio ms=(\d+) bytes=(\d+) quadros=(\d+) kbps=([\d,.]+) bitrate_pedido=(\d+)",
        bruto,
    ):
        saida.append({
            "ms": int(m.group(1)),
            "bytes": int(m.group(2)),
            "quadros": int(m.group(3)),
            "kbps": float(m.group(4).replace(",", ".")),
            "pedido_bps": int(m.group(5)),
        })
    return saida


def janelas_do_enlace(bruto: str) -> list[dict]:
    """`janela_do_enlace …` do receptor."""
    saida = []
    for m in re.finditer(
        r"janela_do_enlace ms=(\d+) pacotes=(\d+) pac_s=(\d+) perdidos=(\d+) "
        r"perda_pct=([\d,.]+) quadros=(\d+) suspeitos=(\d+) rupturas=(\d+) "
        r"idrs_ok=(\d+) idrs_quebrados=(\d+)",
        bruto,
    ):
        saida.append({
            "ms": int(m.group(1)),
            "pacotes": int(m.group(2)),
            "pac_s": int(m.group(3)),
            "perdidos": int(m.group(4)),
            "perda_pct": float(m.group(5).replace(",", ".")),
            "quadros": int(m.group(6)),
            "suspeitos": int(m.group(7)),
            "rupturas": int(m.group(8)),
            "idrs_ok": int(m.group(9)),
            "idrs_quebrados": int(m.group(10)),
        })
    return saida


def degraus_do_emissor(fio: list[dict]) -> list[dict]:
    """Agrupa as janelas do fio por `bitrate_pedido`, na ordem em que apareceram.

    Agrupa por **valor observado**, e não pela escada pedida: se o codec ignorar um degrau, a
    tabela mostra o que aconteceu, e não o que se queria. Um degrau repetido na escada (por
    exemplo 4000 no começo e no fim) vira dois grupos, porque a ordem os separa.
    """
    grupos = []
    for j in fio:
        if grupos and grupos[-1]["pedido_bps"] == j["pedido_bps"]:
            grupos[-1]["janelas"].append(j)
        else:
            grupos.append({"pedido_bps": j["pedido_bps"], "janelas": [j]})
    return grupos


def fatiar_por_degrau(enlace: list[dict], degraus: list[dict]) -> None:
    """Reparte as janelas do receptor entre os degraus, por tempo acumulado de cada lado.

    As duas listas cobrem a **mesma** sessão e cada janela carrega a própria duração, então o
    tempo acumulado é comparável mesmo com relógios diferentes — o que não é comparável é o
    instante absoluto. O erro que sobra é o atraso entre o emissor começar a contar e o receptor
    começar, e ele é absorvido pelo descarte de [DESCARTE_S] no começo de cada degrau.
    """
    # Fronteiras dos degraus no eixo de tempo do emissor.
    t = 0.0
    fronteiras = []
    for g in degraus:
        dur = sum(j["ms"] for j in g["janelas"]) / 1000.0
        fronteiras.append((t, t + dur, g))
        g["enlace"] = []
        t += dur
    # O receptor começa depois do emissor (ele conecta), então a origem dele é deslocada para o
    # fim: alinhamos os **fins** das duas sessões, que é o instante que os dois compartilham.
    total_enlace = sum(j["ms"] for j in enlace) / 1000.0
    deslocamento = t - total_enlace
    te = deslocamento
    for j in enlace:
        meio = te + j["ms"] / 2000.0
        te += j["ms"] / 1000.0
        for ini, fim, g in fronteiras:
            if ini <= meio < fim:
                # O descarte: janela cujo **meio** cai nos primeiros DESCARTE_S do degrau é
                # transitório, e transitório não é ponto de curva.
                if meio - ini >= DESCARTE_S:
                    g["enlace"].append(j)
                break


def resumo(g: dict) -> dict:
    """Uma linha de curva: pedido, entregue no fio, e o dano do outro lado."""
    jf = [j for j in g["janelas"]]
    # Mesmo descarte do lado do emissor: as primeiras janelas do degrau atravessam a troca.
    corte = int(DESCARTE_S * 1000 / max(1, jf[0]["ms"])) if jf else 0
    jf_reg = jf[corte:] or jf
    je = g.get("enlace", [])
    bytes_fio = sum(j["bytes"] for j in jf_reg)
    ms_fio = sum(j["ms"] for j in jf_reg)
    pacotes = sum(j["pacotes"] for j in je)
    perdidos = sum(j["perdidos"] for j in je)
    ms_enlace = sum(j["ms"] for j in je)
    return {
        "pedido_kbps": g["pedido_bps"] // 1000,
        "fio_kbps": round(bytes_fio * 8 / ms_fio, 1) if ms_fio else None,
        "janelas_fio": len(jf_reg),
        "quadros_s": round(sum(j["quadros"] for j in jf_reg) * 1000 / ms_fio, 1) if ms_fio else None,
        "janelas_enlace": len(je),
        "pac_s": round(pacotes * 1000 / ms_enlace, 0) if ms_enlace else None,
        # **O denominador é o do emissor**: `pacotes` já é vistos + perdidos. Ver `JanelaDoEnlace`.
        "perda_pct": round(perdidos * 100 / pacotes, 3) if pacotes else None,
        "perda_pct_p50_janela": (
            round(statistics.median(j["perda_pct"] for j in je), 3) if je else None
        ),
        "perdidos": perdidos,
        "pacotes": pacotes,
        "suspeitos": sum(j["suspeitos"] for j in je),
        "rupturas": sum(j["rupturas"] for j in je),
        "idrs_ok": sum(j["idrs_ok"] for j in je),
        "idrs_quebrados": sum(j["idrs_quebrados"] for j in je),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sentido", required=True,
                    help="<emissor>-<receptor>, por nome curto: " + ", ".join(sorted(aa.APARELHOS)))
    ap.add_argument("--escada", default="4000,3000,2000,1500,1000,700,500",
                    help="bitrates em kbps, na ordem em que a sessão vai percorrê-los")
    ap.add_argument("--passo", type=int, default=20, help="segundos por degrau")
    ap.add_argument("--janela-fio", type=int, default=1000, help="ms da janela do emissor")
    ap.add_argument("--janela-enlace", type=int, default=1000, help="ms da janela do receptor")
    ap.add_argument("--saida", default="")
    args = ap.parse_args()

    try:
        nome_e, nome_r = args.sentido.split("-", 1)
        e = Aparelho(aa.APARELHOS[nome_e], nome_e)
        r = Aparelho(aa.APARELHOS[nome_r], nome_r)
    except (ValueError, KeyError):
        print(f"--sentido inválido: {args.sentido!r}")
        return 2

    escada = [int(x) for x in args.escada.split(",") if x.strip()]
    segundos = len(escada) * args.passo + 6  # folga para o último degrau fechar

    for a in (e, r):
        a.acorda()
    prefs(e.serial, aa.PORTA[e.serial], escada, args.passo * 1000,
          args.janela_fio, args.janela_enlace)
    prefs(r.serial, aa.PORTA[r.serial], [], args.passo * 1000, 0, args.janela_enlace)

    condicao = {
        "sentido": args.sentido,
        "escada_kbps": escada,
        "passo_s": args.passo,
        "janela_fio_ms": args.janela_fio,
        "janela_enlace_ms": args.janela_enlace,
        "segundos": segundos,
        "emissor": {"nome": e.nome, "serial": e.serial, "wifi": e.wifi(), "ip": e.ip()},
        "receptor": {"nome": r.nome, "serial": r.serial, "wifi": r.wifi(), "ip": r.ip()},
        "comecou": time.strftime("%H:%M:%S"),
    }
    print(json.dumps(condicao, ensure_ascii=False, indent=2))

    r.para_app()
    r.abre_app()
    pontos = aa.calibra_controles(r)

    e.limpa_logcat()
    r.limpa_logcat()
    endereco, pin = aa.sobe_emissor(e)
    r.toca(rid="buttonReceive", espera=2.0, pacote=PKG)
    r.escreve("editEndereco", endereco)
    r.escreve("editPin", pin)
    if not r.toca(rid="buttonConectar", espera=2.0, pacote=PKG):
        raise RuntimeError(f"{r.nome}: não achei o botão Conectar")

    print(f"espelhando por {segundos} s ({len(escada)} degraus de {args.passo} s)…")
    time.sleep(segundos)

    x, y = pontos["buttonPararRecepcao"]
    r.sh(f"input tap {x} {y}")
    time.sleep(4.0)
    r.sh("input keyevent KEYCODE_BACK")
    time.sleep(1.0)

    bruto_e = e.logcat("QuallH264Encoder:I QuallMirror:I *:S")
    bruto_r = r.logcat("QuallReceptor:I *:S")
    e.para_app()
    r.para_app()

    fio = janelas_do_fio(bruto_e)
    enlace = janelas_do_enlace(bruto_r)
    degraus = degraus_do_emissor(fio)
    fatiar_por_degrau(enlace, degraus)
    linhas = [resumo(g) for g in degraus]

    print(f"\njanelas: fio={len(fio)} enlace={len(enlace)} degraus={len(degraus)}")
    cab = ("pedido  fio     quadros/s  pac/s   perda%   perdidos/pacotes  suspeitos  "
           "idr ok/quebrado")
    print(cab)
    print("-" * len(cab))
    for l in linhas:
        print(f"{l['pedido_kbps']:>6}  {str(l['fio_kbps']):>6}  {str(l['quadros_s']):>9}  "
              f"{str(l['pac_s']):>5}   {str(l['perda_pct']):>6}   "
              f"{l['perdidos']:>6}/{l['pacotes']:<9}  {l['suspeitos']:>9}  "
              f"{l['idrs_ok']}/{l['idrs_quebrados']}")

    resultado = {
        "condicao": condicao,
        "terminou": time.strftime("%H:%M:%S"),
        "curva": linhas,
        "janelas_do_fio": fio,
        "janelas_do_enlace": enlace,
        "linha_emissor": aa.ultimo_com(bruto_e, "sessão encerrada"),
        "linha_receptor": aa.ultimo_com(bruto_r, "recepção encerrada"),
    }
    destino = args.saida or f"escada-{args.sentido}-{int(time.time())}.json"
    Path(destino).write_text(json.dumps(resultado, ensure_ascii=False, indent=2))
    print(f"\ngravado em {destino}")
    print(f"emissor: {resultado['linha_emissor'][-320:]}")
    print(f"receptor: {resultado['linha_receptor'][-320:]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
