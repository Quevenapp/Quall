#!/usr/bin/env python3
"""Junta as corridas de `anomalia-corrida.sh` numa tabela.

Uma corrida não decide nada. O que decide é a coluna inteira, e o valor desta tabela está em
por lado a lado, na mesma linha, o que o **emissor** contou, o que o **receptor** contou e o
que o **sistema operacional dos dois lados** contou. Se o núcleo acusa buraco na sequência
enquanto o kernel do Mac não descartou datagrama nenhum e a wlan0 do A10s não acusou erro de
transmissão, o que faltou nunca esteve na máquina: perdeu-se no caminho.

Uso: tools/anomalia-resumo.py <diretório das corridas> [prefixo]
"""

import re
import sys
from pathlib import Path


def num(texto, padrao):
    m = re.search(padrao, texto, re.M)
    return int(m.group(1)) if m else None


def mac_contadores(caminho):
    t = caminho.read_text(errors="replace") if caminho.exists() else ""
    en0 = re.search(r"^en0\s+\d+\s+<Link#\d+>\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)",
                    t, re.M)
    return {
        "udp_recebidos": num(t, r"(\d+) datagrams received"),
        "udp_sem_socket": num(t, r"(\d+) dropped due to no socket"),
        "udp_buffer_cheio": num(t, r"(\d+) dropped due to full socket buffers"),
        "udp_checksum_ruim": num(t, r"(\d+) with bad checksum"),
        "en0_ipkts": int(en0.group(1)) if en0 else None,
        "en0_ierrs": int(en0.group(2)) if en0 else None,
    }


def fone_contadores(caminho):
    t = caminho.read_text(errors="replace") if caminho.exists() else ""
    dev = re.search(r"wlan0:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+"
                    r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", t)
    udp = re.search(r"^Udp:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", t, re.M)
    return {
        "wlan0_tx_pkts": int(dev.group(6)) if dev else None,
        "wlan0_tx_errs": int(dev.group(7)) if dev else None,
        "wlan0_tx_drop": int(dev.group(8)) if dev else None,
        "wlan0_rx_drop": int(dev.group(4)) if dev else None,
        "udp_out": int(udp.group(4)) if udp else None,
        "udp_sndbuf_errs": int(udp.group(6)) if udp else None,
        "rssi": num(t, r"RSSI: (-?\d+)"),
        "tela": "ON" if "state=ON" in t else ("OFF" if "state=OFF" in t else "?"),
    }


def delta(a, b, chave):
    x, y = a.get(chave), b.get(chave)
    return None if x is None or y is None else y - x


def main():
    raiz = Path(sys.argv[1])
    prefixo = sys.argv[2] if len(sys.argv) > 2 else ""
    linhas = []
    for rec in sorted(raiz.glob(f"{prefixo}*.receptor")):
        rot = rec.stem
        emi = raiz / f"{rot}.emissor"
        if not emi.exists():
            continue
        te, tr = emi.read_text(errors="replace"), rec.read_text(errors="replace")
        enviados = num(te, r"quadros enviados\s*:\s*(\d+)")
        buffer_max = num(te, r"buffer máximo da track\s*:\s*(\d+)")
        idr_env = num(te, r"IDR no fluxo\s*:\s*(\d+)")
        gravados = num(tr, r"quadros gravados\s*:\s*(\d+)")
        idr_rec = num(tr, r"^\s*IDR\s*:\s*(\d+)")
        perdidos = num(tr, r"quadros perdidos\s*:\s*(\d+)")
        anomalias = num(tr, r"anomalias de seq\s*:\s*(\d+)")
        if enviados is None or anomalias is None:
            continue
        ma, mb = (mac_contadores(raiz / f"{rot}.mac.{q}") for q in ("antes", "depois"))
        fa, fb = (fone_contadores(raiz / f"{rot}.fone.{q}") for q in ("antes", "depois"))
        linhas.append({
            "rotulo": rot,
            "enviados": enviados,
            "gravados": gravados,
            "perdidos": perdidos,
            "anomalias": anomalias,
            "idr_env": idr_env,
            "idr_rec": idr_rec,
            "idr_falta": (idr_env or 0) - (idr_rec or 0),
            "sumidos": enviados - (gravados or 0) - (perdidos or 0),
            "buffer_max": buffer_max,
            "tx_pkts": delta(fa, fb, "wlan0_tx_pkts"),
            "tx_errs": delta(fa, fb, "wlan0_tx_errs"),
            "tx_drop": delta(fa, fb, "wlan0_tx_drop"),
            "rx_drop": delta(fa, fb, "wlan0_rx_drop"),
            "sndbuf": delta(fa, fb, "udp_sndbuf_errs"),
            "mac_buf_cheio": delta(ma, mb, "udp_buffer_cheio"),
            "mac_ierrs": delta(ma, mb, "en0_ierrs"),
            "mac_cksum": delta(ma, mb, "udp_checksum_ruim"),
            "rssi": fb.get("rssi"),
            "tela": fb.get("tela"),
        })

    cab = ("rotulo", "enviados", "gravados", "perdidos", "anomalias", "sumidos",
           "idr_env", "idr_rec", "idr_falta", "buffer_max",
           "tx_pkts", "tx_errs", "tx_drop", "rx_drop", "sndbuf", "mac_buf_cheio", "mac_ierrs", "mac_cksum",
           "rssi", "tela")
    larg = [max(len(c), *(len(str(l[c])) for l in linhas)) if linhas else len(c) for c in cab]
    print("  ".join(c.ljust(w) for c, w in zip(cab, larg)))
    for l in linhas:
        print("  ".join(str(l[c]).ljust(w) for c, w in zip(cab, larg)))

    if linhas:
        an = [l["anomalias"] for l in linhas]
        pe = [l["perdidos"] or 0 for l in linhas]
        pk = [l["tx_pkts"] for l in linhas if l["tx_pkts"]]
        print()
        print(f"n={len(linhas)}  anomalias: min {min(an)} · mediana {sorted(an)[len(an)//2]} "
              f"· max {max(an)} · soma {sum(an)}")
        print(f"          quadros perdidos: soma {sum(pe)} de {sum(l['gravados'] or 0 for l in linhas)} entregues")
        ie, ir = sum(l["idr_env"] or 0 for l in linhas), sum(l["idr_rec"] or 0 for l in linhas)
        qe, qg = sum(l["enviados"] for l in linhas), sum(l["gravados"] or 0 for l in linhas)
        if ie:
            print(f"          IDR: {ie} enviados, {ir} recebidos → {(ie-ir)/ie*100:.2f}% de IDR perdido")
        if qe:
            print(f"          quadros: {qe} enviados, {qg} recebidos → {(qe-qg)/qe*100:.2f}% de quadro perdido")
        if pk:
            print(f"          pacotes tx da wlan0: soma {sum(pk)} → anomalias/pacote "
                  f"{sum(an)/sum(pk)*100:.3f}%")


if __name__ == "__main__":
    main()
