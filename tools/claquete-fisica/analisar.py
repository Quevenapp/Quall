#!/usr/bin/env python3
"""Claquete física do R5 (G4): a sincronia câmera × microfone de um emissor real, pela rede.

Entrada: o prefixo que `quall-probe receber-claquete --saida P` gravou (P.h264, P.quadros.csv,
P.som.pcm, P.som.csv, P.json). O iPad roda a Claquete R5 na frente da câmera do emissor: a cada
`intervalo` um clarão de tela inteira e um bipe de 3150 Hz, com 0 ou +40 ms entre os dois
(`docs/teleprompter-com-camera.md` §8 G4 e §8.4 passo B; `docs/som-no-receptor.md` §9).

Tudo no **relógio comum** da sessão: a captura de cada quadro e de cada amostra é
`timestamp_us + deslocamento` da track (o `P.json`), e o som ainda desconta o atraso do conteúdo
do codec (Opus: 6,5 ms). Por evento:

    bruto_i = t_bipe_i − t_clarão_i
    Δ_i     = bruto_i − classe_i − distância/343 − viés_do_iPad

Positivo é som atrasado. `viés_do_iPad` é o som − tela da própria claquete, medido na fase 0
pela S-C1 (−17,4 ms p50, `teleprompter-com-camera.md` §8.2).

Como cada tempo é medido (o mesmo método da S-C1, `tools/sonda-r5/claquete/analisar.py`):

* clarão: luma média de cada quadro decodificado (ffprobe sobre o .h264, reduzido a 64x64,
  opcionalmente só a ROI). O quadro decodificado é casado com o carimbo pelo **byte onde ele
  começa** no .h264 (`pkt_pos` × a coluna `pos`), e não pela contagem. O instante é a travessia de
  50 % entre o escuro e o claro, interpolada entre os dois quadros vizinhos;
* bipe: demodulação em 3150 Hz, média móvel centrada de 4 ms, módulo; a travessia de 50 % do
  pico, menos meia rampa do bipe (2 ms de rampa no app);
* a classe de cada evento vem da **duração do clarão** (100 ms = 0, 200 ms = +40), sem usar o
  som; a sequência vista é alinhada contra a da semente (`--semente`). O controle 0/+40 é
  mediana(+40) − mediana(0) dos brutos, e tem de dar 40 ± 5 ms (§9.3, controle 1).

Critério (§9.1): p05 ≥ −45 ms e p95 ≤ +125 ms. O veredito só sai com o instrumento conferido:
relógio comum válido e estável, controle 0/+40 dentro, sequência ≥ 95 %, cobertura ≥ 90 %, n ≥ 20.

O que isto **não** cobre, e o relato repete: a convenção do carimbo da câmera (começo, meio ou fim
da exposição: até meio quadro, ±16,7 ms a 30 fps, que o controle 0/+40 não vê); a fase do clarão
na grade de quadros (o clarão cai no vsync de 60 Hz do iPad, a câmera o amostra em poucas fases, e
o erro da travessia pode virar viés fixo de até ±T/4, ±8,3 ms a 30 fps — só a deriva entre os
cristais o varre; medido no autoteste: −2,2 ms com a fase parada, +0,5 com a fase varrida); o
obturador rolante sem ROI; o viés do iPad fora do que a S-C1 mediu (±3,6 ms entre p05 e p95 dela).

Uso:
    analisar.py PREFIXO --semente S --distancia-m 0.4 [--intervalo-s 2] [--eventos 150]
                [--vies-ipad-ms -17.4] [--rampa-ms 2] [--roi x,y,w,h] [--saida relato.json]
    analisar.py PREFIXO --verdade-da-sonda claquete.json --distancia-m 0 --vies-ipad-ms 0 \\
                --rampa-ms 0          # o autoteste em lo0 contra o emitir-video --claquete
"""

import argparse
import csv
import json
import math
import os
import subprocess
import sys

import numpy as np

BIPE_HZ = 3150.0
JANELA_MS = 4.0
VEL_SOM = 343.0
MASCARA = (1 << 64) - 1
VIES_IPAD_S_C1_MS = -17.4


def splitmix64(estado):
    """Igual ao `SplitMix64` da Claquete R5 (`tools/sonda-r5/ios/Claquete/AppClaquete.swift`)."""
    estado = (estado + 0x9E3779B97F4A7C15) & MASCARA
    z = estado
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASCARA
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASCARA
    return estado, z ^ (z >> 31)


def classes_da_semente(semente, n):
    """A classe de cada evento da Claquete R5: o bit alto de cada sorteio, em ordem."""
    e, out = semente, []
    for _ in range(n):
        e, v = splitmix64(e)
        out.append(40.0 if (v >> 63) == 1 else 0.0)
    return out


def ler_csv(caminho):
    with open(caminho) as f:
        return list(csv.DictReader(f))


# --------------------------------------------------------------------------------------------
# imagem
# --------------------------------------------------------------------------------------------

def luma_por_pos(h264, roi):
    """{pkt_pos: luma média} de cada quadro decodificado."""
    filtros = []
    if roi:
        x, y, w, h = roi
        filtros.append(f"crop={w}:{h}:{x}:{y}")
    filtros += ["scale=64:64:flags=area", "format=gray", "signalstats"]
    fonte = "movie=" + h264.replace("\\", "\\\\").replace(":", "\\:").replace(",", "\\,") \
        + "," + ",".join(filtros)
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-f", "lavfi", "-i", fonte, "-show_entries",
         "frame=pkt_pos:frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0"],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"!! o ffprobe não decodificou {h264}: {r.stderr.strip()[:400]}")
    saida = {}
    for linha in r.stdout.splitlines():
        partes = linha.strip().split(",")
        if len(partes) < 2 or not partes[0] or not partes[1]:
            continue
        try:
            saida[int(partes[0])] = float(partes[1])
        except ValueError:
            continue
    return saida


def claroes(t, y, contraste_minimo):
    lo, hi = np.percentile(y, 10), np.percentile(y, 99.5)
    if hi - lo < contraste_minimo:
        sys.exit(f"!! sem clarão visível: luma de {lo:.1f} a {hi:.1f} (mínimo {contraste_minimo}). "
                 "Confira o enquadramento, o brilho do iPad, ou use --roi")
    meio = (lo + hi) / 2

    def cruza(k):
        a, b = y[k - 1], y[k]
        return t[k - 1] + (meio - a) / (b - a) * (t[k] - t[k - 1])

    sobe = [k for k in range(1, len(y)) if y[k - 1] < meio <= y[k]]
    desce = [k for k in range(1, len(y)) if y[k - 1] >= meio > y[k]]
    eventos = []
    j = 0
    for k in sobe:
        # Um buraco de quadros (perda) entre os vizinhos: a interpolação não vale.
        if t[k] - t[k - 1] > 0.1:
            continue
        while j < len(desce) and desce[j] <= k:
            j += 1
        if j >= len(desce):
            break
        ts, td = cruza(k), cruza(desce[j])
        dur = td - ts
        if not 0.05 <= dur <= 0.35:
            continue
        if eventos and ts - eventos[-1]["t"] < 0.5:
            continue
        eventos.append({"t": ts, "dur_ms": dur * 1000, "classe_ms": 40.0 if dur > 0.15 else 0.0,
                        "passo_ms": (t[k] - t[k - 1]) * 1000})
    return eventos, {"escuro": float(lo), "claro": float(hi), "meio": float(meio)}


# --------------------------------------------------------------------------------------------
# som
# --------------------------------------------------------------------------------------------

def linha_do_tempo(pcm, pacotes, sr, canais, t0_us):
    """O som posto na grade de amostras pelo carimbo de cada pacote; buraco vira zero."""
    x = np.fromfile(pcm, dtype="<i2").astype(np.float64) / 32768.0
    if canais > 1:
        x = x[: len(x) // canais * canais].reshape(-1, canais).mean(axis=1)
    ordem = sorted(pacotes, key=lambda p: int(p["timestamp_us"]))
    base = int(ordem[0]["timestamp_us"])
    fim = int(ordem[-1]["timestamp_us"])
    total = int(round((fim - base) * sr / 1e6)) + int(ordem[-1]["amostras"]) + 1
    y = np.zeros(total)
    coberto = np.zeros(total, dtype=bool)
    buracos, sobrepostos = 0, 0
    esperado = None
    for p in ordem:
        i0 = int(round((int(p["timestamp_us"]) - base) * sr / 1e6))
        a, n = int(p["amostra"]), int(p["amostras"])
        if esperado is not None:
            if i0 > esperado + 1:
                buracos += 1
            elif i0 < esperado - 1:
                sobrepostos += 1
        y[i0:i0 + n] = x[a:a + n]
        coberto[i0:i0 + n] = True
        esperado = i0 + n
    t = (base + t0_us) / 1e6 + np.arange(total) / sr
    return t, y, {"buracos": buracos, "sobrepostos": sobrepostos,
                  "cobertura_do_som": float(coberto.mean())}


def bipes(t, x, sr, rampa_ms):
    n = np.arange(len(x))
    z = x * np.exp(-2j * np.pi * BIPE_HZ * n / sr)
    w = max(3, int(round(JANELA_MS / 1000 * sr)) | 1)
    h = w // 2
    c = np.concatenate([[0], np.cumsum(z)])
    env = np.zeros(len(x))
    env[h:len(x) - h] = np.abs(c[w + np.arange(len(x) - 2 * h)] - c[np.arange(len(x) - 2 * h)]) / w
    piso = float(np.median(env))
    # O bipe ocupa ~0,5–2,5 % do tempo (10–50 ms a cada 2 s): o p99,9 cai dentro dele.
    topo = float(np.percentile(env, 99.9))
    if topo < piso * 4:
        sys.exit(f"!! sem bipe em {BIPE_HZ:.0f} Hz (piso {piso:.2e}, p99,9 {topo:.2e}): o volume "
                 "do iPad, a distância, ou o microfone não abriu")
    limiar = piso + 0.3 * (topo - piso)
    acima = env > limiar
    bordas = np.flatnonzero(np.diff(acima.astype(np.int8)))
    inicios = [b + 1 for b in bordas if not acima[b]]
    eventos = []
    ultimo = -1e9
    for i0 in inicios:
        if (i0 - ultimo) / sr < 0.5:
            continue
        fim = min(len(env), i0 + int(0.08 * sr))
        kp = i0 + int(np.argmax(env[i0:fim]))
        pico = env[kp]
        meio = piso + 0.5 * (pico - piso)
        k = kp
        while k > 0 and env[k] >= meio:
            k -= 1
        a, b = env[k], env[k + 1]
        tc = t[k] + (meio - a) / (b - a) * (t[k + 1] - t[k])
        eventos.append({"t": float(tc - rampa_ms / 2000), "pico": float(pico)})
        ultimo = i0
    return eventos, {"piso": piso, "p999": topo}


# --------------------------------------------------------------------------------------------
# estatística e relato
# --------------------------------------------------------------------------------------------

def quantis(v):
    v = np.asarray(v)
    return {"n": int(len(v)), "p05": float(np.percentile(v, 5)), "p50": float(np.median(v)),
            "p95": float(np.percentile(v, 95)), "media": float(v.mean()),
            "desvio": float(v.std(ddof=1)) if len(v) > 1 else 0.0,
            "min": float(v.min()), "max": float(v.max())}


def histograma(v, passo=4.0):
    v = np.asarray(v)
    lo, hi = math.floor(v.min() / passo) * passo, math.ceil(v.max() / passo) * passo
    linhas = []
    b = lo
    while b < hi + 1e-9:
        k = int(((v >= b) & (v < b + passo)).sum())
        linhas.append(f"  {b:+7.1f} ms | {'#' * k} {k}")
        b += passo
    return linhas


def alinhar(claroes_vistos, esperados, tolerancia_s):
    """Acha o evento de cada clarão.

    `esperados`: lista de (t_relativo_s, classe) no relógio do gerador. Cada candidato de origem
    põe um dos primeiros clarões sobre um dos esperados; o placar é (classes que batem, tempos que
    batem). Com o intervalo fixo da Claquete R5 os tempos batem em qualquer origem e quem decide é
    a sequência de classes, como na S-C1; com a verdade da sonda, os intervalos irregulares também.
    """
    te = np.array([e[0] for e in esperados])
    placar = []
    vistos = set()
    mapas = set()
    for f in claroes_vistos[:3]:
        for j in range(len(esperados)):
            o = round(f["t"] - te[j], 4)
            if o in vistos:
                continue
            vistos.add(o)
            classes, tempos, idx = 0, 0, []
            for c in claroes_vistos:
                k = int(np.argmin(np.abs(te + o - c["t"])))
                if abs(te[k] + o - c["t"]) <= tolerancia_s:
                    tempos += 1
                    idx.append(k)
                    if esperados[k][1] == c["classe_ms"]:
                        classes += 1
                else:
                    idx.append(None)
            # Origens diferentes que dão o mesmo casamento são o mesmo candidato.
            if tuple(idx) in mapas:
                continue
            mapas.add(tuple(idx))
            placar.append((classes, tempos, o, idx))
    placar.sort(key=lambda p: (p[0], p[1]), reverse=True)
    return placar


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prefixo")
    ap.add_argument("--semente", type=int, help="a semente da Claquete R5 (-semente do app)")
    ap.add_argument("--intervalo-s", type=float, default=2.0)
    ap.add_argument("--eventos", type=int, default=150)
    ap.add_argument("--verdade-da-sonda", help="o --claquete-saida do emitir-video (autoteste)")
    ap.add_argument("--distancia-m", type=float, required=True,
                    help="alto-falante do iPad → microfone do emissor (0 no autoteste)")
    ap.add_argument("--vies-ipad-ms", type=float, default=VIES_IPAD_S_C1_MS,
                    help="som − tela da claquete (S-C1: −17,4 ms). 0 no autoteste")
    ap.add_argument("--rampa-ms", type=float, default=2.0,
                    help="a rampa do bipe (2 ms no app; 0 no estouro seco da sonda)")
    ap.add_argument("--roi", help="x,y,w,h da tela do iPad no quadro decodificado")
    ap.add_argument("--contraste-minimo", type=float, default=8.0)
    ap.add_argument("--tolerancia-controle-ms", type=float, default=5.0)
    ap.add_argument("--saida", help="grava o relato em JSON")
    a = ap.parse_args()
    if (a.semente is None) == (a.verdade_da_sonda is None):
        sys.exit("!! diga --semente (a Claquete R5) ou --verdade-da-sonda (o autoteste), um só")

    P = a.prefixo
    for suf in (".h264", ".quadros.csv", ".som.pcm", ".som.csv", ".json"):
        if not os.path.exists(P + suf):
            sys.exit(f"!! falta {P + suf}")
    with open(P + ".json") as f:
        meta = json.load(f)
    mv, ms = meta["video"], meta["som"]
    problemas = []

    # --- o relógio comum ---------------------------------------------------------------------
    dv, ds = mv.get("deslocamento_us"), ms.get("deslocamento_us")
    if dv is None or ds is None:
        sys.exit(f"!! relógio comum sem deslocamento válido (vídeo: {mv.get('status')}, som: "
                 f"{ms.get('status')}): sem ele imagem e som não estão no mesmo relógio")
    serie_v = [s["video"] for s in meta.get("serie_do_deslocamento", []) if s.get("video") is not None]
    serie_s = [s["som"] for s in meta.get("serie_do_deslocamento", []) if s.get("som") is not None]
    andou = max((max(x) - min(x)) if x else 0 for x in (serie_v, serie_s))
    if andou > 1000:
        problemas.append(f"o deslocamento de captura andou {andou / 1000:.1f} ms na corrida")
    violacoes = (mv.get("violacoes_da_guarda") or 0) + (ms.get("violacoes_da_guarda") or 0)
    if violacoes:
        problemas.append(f"{violacoes} violação(ões) da guarda do relógio comum")
    atraso_codec = int(ms.get("atraso_do_conteudo_us", 0))
    sr, canais = int(ms["taxa_hz"]), int(ms["canais"])
    print(f"relógio comum: desloc vídeo {dv} µs, som {ds} µs (andou {andou} µs), atraso do "
          f"conteúdo {atraso_codec} µs ({ms.get('codec')}), guarda: {violacoes} violação(ões)")

    # --- imagem ------------------------------------------------------------------------------
    quadros = ler_csv(P + ".quadros.csv")
    roi = tuple(int(v) for v in a.roi.split(",")) if a.roi else None
    luma = luma_por_pos(P + ".h264", roi)
    tv, y, sem_imagem = [], [], 0
    for q in quadros:
        v = luma.get(int(q["pos"]))
        if v is None:
            sem_imagem += 1
            continue
        tv.append((int(q["timestamp_us"]) + dv) / 1e6)
        y.append(v)
    tv, y = np.array(tv), np.array(y)
    if len(tv) < 10:
        sys.exit(f"!! só {len(tv)} quadros casados com o carimbo ({len(quadros)} no csv, "
                 f"{len(luma)} decodificados)")
    if np.any(np.diff(tv) <= 0):
        problemas.append("carimbos de vídeo fora de ordem")
    dt = np.diff(tv)
    print(f"imagem: {len(quadros)} quadros no csv, {len(luma)} decodificados, {len(tv)} casados "
          f"pelo byte ({sem_imagem} sem imagem); passo mediano {np.median(dt) * 1000:.2f} ms, "
          f"máx {dt.max() * 1000:.1f} ms")

    # --- som ---------------------------------------------------------------------------------
    pacotes = ler_csv(P + ".som.csv")
    if not pacotes:
        sys.exit("!! nenhum pacote de som")
    ta, xa, info_som = linha_do_tempo(P + ".som.pcm", pacotes, sr, canais, ds - atraso_codec)
    print(f"som: {len(pacotes)} pacotes, {len(xa) / sr:.1f} s, {info_som['buracos']} buraco(s), "
          f"{info_som['sobrepostos']} sobreposto(s), cobertura {info_som['cobertura_do_som']:.1%}")

    fl, niveis = claroes(tv, y, a.contraste_minimo)
    bp, nivel_som = bipes(ta, xa, sr, a.rampa_ms)
    print(f"{len(fl)} clarões (luma {niveis['escuro']:.0f} → {niveis['claro']:.0f}), {len(bp)} bipes "
          f"(piso {nivel_som['piso']:.1e}, p99,9 {nivel_som['p999']:.1e})")
    if not fl:
        sys.exit("!! nenhum clarão reconhecido")

    # --- pares -------------------------------------------------------------------------------
    voo_ms = a.distancia_m / VEL_SOM * 1000
    pares, usados = [], set()
    for f in fl:
        cands = [(abs(b["t"] - f["t"] - f["classe_ms"] / 1000), j) for j, b in enumerate(bp)
                 if -0.15 <= b["t"] - f["t"] <= 0.30 and j not in usados]
        if not cands:
            continue
        _, j = min(cands)
        usados.add(j)
        bruto = (bp[j]["t"] - f["t"]) * 1000
        pares.append({"t_clarao_s": f["t"], "t_bipe_s": bp[j]["t"], "classe_ms": f["classe_ms"],
                      "dur_clarao_ms": f["dur_ms"], "bruto_ms": bruto,
                      "delta_ms": bruto - f["classe_ms"] - voo_ms - a.vies_ipad_ms})
    if len(pares) < 3:
        sys.exit(f"!! só {len(pares)} pares clarão/bipe")

    # --- a sequência: contra a semente, ou contra a verdade da sonda ------------------------
    if a.semente is not None:
        cl = classes_da_semente(a.semente, a.eventos)
        esperados = [(i * a.intervalo_s, c) for i, c in enumerate(cl)]
        tolerancia = 0.25 * a.intervalo_s
    else:
        with open(a.verdade_da_sonda) as f:
            v = json.load(f)
        esperados = [(e["t_us"] / 1e6, e["desloc_us"] / 1000.0) for e in v["eventos"]]
        tolerancia = 0.1
    placar = alinhar(fl, esperados, tolerancia)
    classes_ok, tempos_ok, origem, idx = placar[0]
    segundo = placar[1][0] if len(placar) > 1 else 0
    alinhamento = {"acertos": classes_ok, "no_tempo": tempos_ok, "de": len(fl),
                   "fracao": classes_ok / len(fl), "segundo_melhor": segundo, "origem_s": origem}
    for p in pares:
        k = next((idx[i] for i, f in enumerate(fl) if f["t"] == p["t_clarao_s"]), None)
        if k is not None:
            p["evento"] = int(k)
            p["classe_esperada_ms"] = esperados[k][1]
    vistos = [i for i in idx if i is not None]
    if vistos:
        span = [e for e in range(min(vistos), max(vistos) + 1)]
        cobertura = len(pares) / len(span)
    else:
        cobertura = 0.0

    deltas = [p["delta_ms"] for p in pares]
    q = quantis(deltas)
    c0 = [p["bruto_ms"] for p in pares if p["classe_ms"] == 0]
    c40 = [p["bruto_ms"] for p in pares if p["classe_ms"] == 40]
    controle = None
    if len(c0) >= 3 and len(c40) >= 3:
        diff = float(np.median(c40) - np.median(c0))
        controle = {"diferenca_ms": diff, "n0": len(c0), "n40": len(c40),
                    "ok": abs(diff - 40) <= a.tolerancia_controle_ms}
    por_classe = {k: quantis([p["delta_ms"] for p in pares if p["classe_ms"] == c])
                  for k, c in (("classe_0", 0.0), ("classe_40", 40.0))
                  if any(p["classe_ms"] == c for p in pares)}

    print()
    print(f"Δ = t_som − t_imagem, pelo relógio comum; classe, voo do som ({voo_ms:.2f} ms, "
          f"{a.distancia_m} m) e viés do iPad ({a.vies_ipad_ms:+.1f} ms) descontados:")
    print(f"  n {q['n']}, p05 {q['p05']:+.1f} ms, p50 {q['p50']:+.1f} ms, p95 {q['p95']:+.1f} ms, "
          f"desvio {q['desvio']:.1f} ms; cobertura {cobertura:.0%}")
    for k, v in por_classe.items():
        print(f"  {k}: n {v['n']}, p50 {v['p50']:+.1f} ms")
    for linha in histograma(deltas):
        print(linha)
    if controle:
        print(f"controle 0/+40: mediana(+40) − mediana(0) = {controle['diferenca_ms']:+.1f} ms "
              f"(n {controle['n40']}/{controle['n0']}) → {'OK' if controle['ok'] else 'FALHOU'}")
    print(f"sequência de classes: {classes_ok}/{len(fl)} (no tempo {tempos_ok}; segundo melhor "
          f"{segundo})")
    if a.vies_ipad_ms == VIES_IPAD_S_C1_MS:
        print("viés do iPad: o da S-C1 (24/09), −17,4 ms p50 (p05 −20,9, p95 −13,6)")
    passo = float(np.median(dt)) * 1000
    print(f"não coberto: a convenção do carimbo da câmera do emissor (até meio quadro, ±{passo / 2:.1f} "
          f"ms); a fase do clarão na grade de quadros — o clarão cai no vsync de 60 Hz do iPad e a "
          f"câmera o amostra em poucas fases, então o erro da travessia pode ficar como viés fixo "
          f"de até ±{passo / 4:.1f} ms em vez de se espalhar (só a deriva entre os cristais o "
          f"varre); o obturador rolante sem --roi; e o viés do iPad fora do que a S-C1 mediu")

    if controle is None:
        problemas.append("controle 0/+40 sem as duas classes")
    elif not controle["ok"]:
        problemas.append(f"controle 0/+40 deu {controle['diferenca_ms']:+.1f} ms")
    if alinhamento["fracao"] < 0.95:
        problemas.append(f"sequência de classes confere só {alinhamento['fracao']:.0%}")
    if cobertura < 0.9:
        problemas.append(f"cobertura {cobertura:.0%}")
    if q["n"] < 20:
        problemas.append(f"n {q['n']} < 20")
    base = (f"Δ p05 {q['p05']:+.1f} ms, p50 {q['p50']:+.1f}, p95 {q['p95']:+.1f}, n {q['n']}, "
            f"cobertura {cobertura:.0%}")
    if controle:
        base += f"; controle 0/+40 {controle['diferenca_ms']:+.1f} ms"
    passa = q["p05"] >= -45 and q["p95"] <= 125
    if problemas:
        veredito = "VEREDITO: SEM VEREDITO (instrumento) — " + "; ".join(problemas) + " — " + base
    elif passa:
        veredito = "VEREDITO: APROVADO (p05 ≥ −45 e p95 ≤ +125) — " + base
    else:
        veredito = "VEREDITO: REPROVADO (p05 ≥ −45 e p95 ≤ +125) — " + base
    print()
    print(veredito)

    if a.saida:
        with open(a.saida, "w") as f:
            json.dump({"prefixo": os.path.basename(P), "roi": roi, "distancia_m": a.distancia_m,
                       "vies_ipad_ms": a.vies_ipad_ms, "rampa_ms": a.rampa_ms,
                       "semente": a.semente, "deslocamento_us": {"video": dv, "som": ds},
                       "atraso_do_conteudo_us": atraso_codec, "niveis_luma": niveis,
                       "nivel_som": nivel_som, "som": info_som, "claroes": len(fl),
                       "bipes": len(bp), "delta_ms": q, "por_classe": por_classe,
                       "controle": controle, "alinhamento": alinhamento, "cobertura": cobertura,
                       "pares": pares, "veredito": veredito},
                      f, indent=2, ensure_ascii=False)
        print(f"relato: {a.saida}")
    if problemas:
        return 2
    return 0 if passa else 1


if __name__ == "__main__":
    sys.exit(main())
