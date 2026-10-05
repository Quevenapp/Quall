#!/usr/bin/env python3
"""
O A/B do **controlador de taxa**, Android → Android, no mesmo APK.

Dois braços, e a única coisa que muda entre eles é `taxa_que_escuta`:

  * **antes** — o produto de hoje: bitrate fixo, o emissor manda o que mandaram ele mandar;
  * **depois** — o controlador ligado.

O relato do enlace (`janela_do_enlace_ms`) fica ligado **nos dois**, de propósito: assim o
tráfego do relato está no ar nas duas medições e não pode explicar a diferença entre elas.

    apps/android/tools/aa-taxa.py --sentido a10s-tablet --corridas 6 --segundos 60

**Os braços são intercalados**, nunca medidos em lote — o rádio de 2,4 GHz piora ao longo de meia
hora de medição, e um lote de um braço seguido do outro compararia horas diferentes. É a mesma
disciplina de `aa-corrida.py`, e ela existe porque esta bancada já publicou uma varredura em que
os dois pontos extremos calharam de pegar as três piores janelas de rádio do lote.

# O número que decide

Não é "o bitrate baixou". É **`suspeitos`** — quadros que foram para a tela com a referência
quebrada — e **`sem_referencia_ms` deixando de bater na válvula de 2 s**. Os dois saem da linha de
encerramento do receptor, que é a mesma de toda prova de recepção deste projeto.
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

_spec = importlib.util.spec_from_file_location("aa_corrida", AQUI / "aa-corrida.py")
aa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aa)

PKG = "com.quall.android"


def prefs(serial: str, porta: int, taxa: bool, janela_enlace_ms: int,
          janela_fio_ms: int = 0) -> None:
    """Escreve as preferências do braço. As de IDR ficam no padrão de produto."""
    xml = f"""<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name="porta" value="{porta}" />
    <string name="prefixo_nome">tx-</string>
    <boolean name="taxa_que_escuta" value="{"true" if taxa else "false"}" />
    <int name="janela_do_enlace_ms" value="{janela_enlace_ms}" />
    <int name="janela_do_fio_ms" value="{janela_fio_ms}" />
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
    # Conferido de volta: uma frente desta bancada rodou um lote inteiro com o sinalizador
    # desligado por confiar na escrita.
    esperado = f'name="taxa_que_escuta" value="{"true" if taxa else "false"}"'
    if esperado not in lido:
        raise RuntimeError(f"{serial}: o braço não chegou às preferências:\n{lido}")


def decisoes(bruto: str) -> list[dict]:
    """As linhas `taxa: janela …` do emissor — uma por relato que atravessou."""
    saida = []
    for m in re.finditer(
        r"taxa: janela ms=(\d+) pacotes=(\d+) perdidos=(\d+) perda=([\d,.]+)% "
        r"suspeitos=(\d+) idrs_quebrados=(\d+) -> (\w+) bitrate=(\d+)",
        bruto,
    ):
        saida.append({
            "ms": int(m.group(1)),
            "pacotes": int(m.group(2)),
            "perdidos": int(m.group(3)),
            "perda_pct": float(m.group(4).replace(",", ".")),
            "suspeitos": int(m.group(5)),
            "idrs_quebrados": int(m.group(6)),
            "motivo": m.group(7),
            "bitrate": int(m.group(8)),
        })
    return saida


def uma_corrida(e: Aparelho, r: Aparelho, pontos: dict, segundos: int, taxa: bool,
                com_pin: bool, janela_ms: int) -> dict:
    for a in (e, r):
        a.acorda()
    e.limpa_logcat()
    r.limpa_logcat()
    endereco, pin = aa.sobe_emissor(e)

    r.toca(rid="buttonReceive", espera=2.0, pacote=PKG)
    r.escreve("editEndereco", endereco)
    if com_pin:
        r.escreve("editPin", pin)
    if not r.toca(rid="buttonConectar", espera=2.0, pacote=PKG):
        raise RuntimeError(f"{r.nome}: não achei o botão Conectar")

    time.sleep(segundos)
    tela = r.tela_acesa()
    x, y = pontos["buttonPararRecepcao"]
    r.sh(f"input tap {x} {y}")
    time.sleep(4.0)
    r.sh("input keyevent KEYCODE_BACK")
    time.sleep(1.0)

    bruto_r = r.logcat("QuallReceptor:I *:S")
    bruto_e = e.logcat("QuallMirror:I QuallH264Encoder:I *:S")
    e.para_app()

    sem_ref = [float(m.replace(",", ".")) for m in
               re.findall(r"sem referência por ([\d,.]+) ms", bruto_r)]
    d = decisoes(bruto_e)
    return {
        "taxa_que_escuta": taxa,
        "segundos": segundos,
        "janela_ms": janela_ms,
        "tela_do_receptor_acesa": tela,
        "receptor": aa.campos(aa.ultimo_com(bruto_r, "recepção encerrada")),
        "emissor": aa.campos(aa.ultimo_com(bruto_e, "sessão encerrada")),
        "sem_referencia_amostras": sem_ref,
        "decisoes": d,
        "bitrate_final": d[-1]["bitrate"] if d else None,
        "bitrates_vistos": sorted({x["bitrate"] for x in d}),
        "linha_receptor": aa.ultimo_com(bruto_r, "recepção encerrada"),
        "linha_emissor": aa.ultimo_com(bruto_e, "sessão encerrada"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sentido", required=True,
                    help="<emissor>-<receptor>: " + ", ".join(sorted(aa.APARELHOS)))
    ap.add_argument("--corridas", type=int, default=6)
    ap.add_argument("--segundos", type=int, default=60)
    ap.add_argument("--janela", type=int, default=500, help="ms da janela do enlace")
    ap.add_argument("--saida", default="")
    args = ap.parse_args()

    try:
        nome_e, nome_r = args.sentido.split("-", 1)
        e = Aparelho(aa.APARELHOS[nome_e], nome_e)
        r = Aparelho(aa.APARELHOS[nome_r], nome_r)
    except (ValueError, KeyError):
        print(f"--sentido inválido: {args.sentido!r}")
        return 2

    for a in (e, r):
        a.acorda()
    condicao = {
        "sentido": args.sentido,
        "corridas": args.corridas,
        "segundos": args.segundos,
        "janela_ms": args.janela,
        "emissor": {"nome": e.nome, "serial": e.serial, "wifi": e.wifi(), "ip": e.ip()},
        "receptor": {"nome": r.nome, "serial": r.serial, "wifi": r.wifi(), "ip": r.ip()},
        "comecou": time.strftime("%H:%M:%S"),
    }
    print(json.dumps(condicao, ensure_ascii=False, indent=2))

    prefs(r.serial, aa.PORTA[r.serial], False, args.janela)
    r.para_app()
    r.abre_app()
    pontos = aa.calibra_controles(r)
    print(f"controles do receptor: {pontos}")

    corridas = []
    com_pin = True
    for i in range(args.corridas):
        taxa = (i % 2 == 1)  # intercalado, nunca em lote
        prefs(e.serial, aa.PORTA[e.serial], taxa, args.janela, janela_fio_ms=1000)
        prefs(r.serial, aa.PORTA[r.serial], False, args.janela)
        r.abre_app()
        try:
            c = uma_corrida(e, r, pontos, args.segundos, taxa, com_pin, args.janela)
        except Exception as exc:  # uma corrida ruim não derruba o lote
            print(f"corrida {i + 1}: FALHOU: {exc}")
            corridas.append({"taxa_que_escuta": taxa, "erro": str(exc)})
            e.para_app()
            r.para_app()
            continue
        com_pin = False
        corridas.append(c)
        rec = c["receptor"]
        print(
            f"corrida {i + 1}/{args.corridas} taxa={'LIGADA' if taxa else 'desligada'}: "
            f"suspeitos={rec.get('suspeitos')} rupturas={rec.get('rupturas')} "
            f"pior_rajada={rec.get('pior_rajada')} "
            f"perda_exata={rec.get('nucleo_packets_lost_for_real')} "
            f"pacotes={rec.get('nucleo_packets_seen')} "
            f"idrs_ok={rec.get('nucleo_idrs_ready')} "
            f"idrs_quebrados={rec.get('nucleo_idrs_broken')} "
            f"fps={rec.get('fps')} sem_ref={rec.get('sem_referencia_ms')} "
            f"bitrate_final={c['bitrate_final']} decisoes={len(c['decisoes'])}"
        )

    resultado = {"condicao": condicao, "terminou": time.strftime("%H:%M:%S"),
                 "corridas": corridas}
    destino = args.saida or f"taxa-{args.sentido}-{int(time.time())}.json"
    Path(destino).write_text(json.dumps(resultado, ensure_ascii=False, indent=2))
    print(f"\ngravado em {destino}")

    # O resumo dos dois braços, com o número que fecha a frente na frente.
    for rotulo, ligada in (("desligada", False), ("LIGADA", True)):
        boas = [c for c in corridas if c.get("taxa_que_escuta") is ligada and "receptor" in c]
        if not boas:
            continue
        def n(c, k):
            return aa.num(c["receptor"].get(k))
        susp = [n(c, "suspeitos") for c in boas]
        perd = [n(c, "nucleo_packets_lost_for_real") for c in boas]
        pac = [n(c, "nucleo_packets_seen") + n(c, "nucleo_packets_lost_for_real") for c in boas]
        quebr = [n(c, "nucleo_idrs_broken") for c in boas]
        prontos = [n(c, "nucleo_idrs_ready") for c in boas]
        # A válvula de 2 s: quantas recuperações terminaram nela, e não numa cura.
        valvula = sum(1 for c in boas for x in c["sem_referencia_amostras"] if x >= 1900)
        total_ref = sum(len(c["sem_referencia_amostras"]) for c in boas)
        print(
            f"\n{rotulo} (n={len(boas)}): "
            f"suspeitos p50={statistics.median(susp):.0f} {sorted(int(x) for x in susp)} · "
            f"perda={sum(perd) * 100 / max(1, sum(pac)):.2f}% · "
            f"idrs quebrados={sum(quebr):.0f}/{sum(quebr) + sum(prontos):.0f} · "
            f"na válvula de 2 s: {valvula}/{total_ref}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
