#!/usr/bin/env python3
"""S-C1: o viés tela × áudio da claquete do iPad, por um vídeo em câmera lenta.

A testemunha é um iPhone (o X) gravando a 240 fps o iPad que roda a Claquete R5, com o
microfone do próprio iPhone ouvindo o bipe. Por evento:

    bruto_i = t_bipe_i − t_clarão_i          (no relógio do arquivo)
    Δ_i     = bruto_i − d_i − distância/343  (d_i = 0 ou 40 ms, da classe)

e o viés do iPad é a distribuição de Δ (p05, p50, p95). Positivo: o som sai depois da imagem.

Como cada tempo é medido:

* clarão: luminância média de cada quadro (ffmpeg, reduzido a 64x64, opcionalmente só a ROI).
  O instante é a travessia de 50 % entre o nível escuro e o claro, interpolada entre os dois
  quadros vizinhos pelo PTS real de cada um (a câmera lenta não tem PTS exatamente constante);
* bipe: demodulação em 3150 Hz (produto por e^{−j2πft}, média móvel centrada de 4 ms, módulo).
  O instante é a travessia de 50 % do pico, menos meia rampa (a rampa do bipe é um cosseno
  simétrico de 2 ms, e a média centrada preserva o ponto médio dela);
* a classe de cada evento vem da **duração do clarão** (100 ms = classe 0, 200 ms = +40), sem
  usar o som. Por isso o controle 0/+40 não é circular. A sequência de classes vista é alinhada
  contra a da semente (o JSON da claquete), e o alinhamento é publicado.

O que isto **não** cobre, e o relato repete:

* o viés da própria testemunha (a câmera e o microfone do iPhone X não têm sincronia conhecida
  entre si); ele entra inteiro no número;
* a convenção de PTS da câmera lenta (início, meio ou fim da exposição) desloca o clarão de até
  meio quadro, ±2,1 ms a 240 fps; o controle 0/+40 não vê esse erro (ele cancela na diferença);
* o obturador rolante: uma ROI pequena reduz o erro, a tela inteira o espalha pelo quadro.

Uso:
    analisar.py VIDEO.MOV [--claquete claquete-....json] [--roi x,y,w,h] [--distancia-m 0.5]
                          [--saida relato.json] [--aceitar-fps-baixo]
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile

import numpy as np

BIPE_HZ = 3150.0
JANELA_MS = 4.0
VEL_SOM = 343.0
MASCARA = (1 << 64) - 1


def splitmix64(estado):
    """Igual ao `SplitMix64` do app. Devolve (novo_estado, valor)."""
    estado = (estado + 0x9E3779B97F4A7C15) & MASCARA
    z = estado
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASCARA
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASCARA
    return estado, z ^ (z >> 31)


def classes_da_semente(semente, n):
    e, out = semente, []
    for _ in range(n):
        e, v = splitmix64(e)
        out.append(40.0 if (v >> 63) == 1 else 0.0)
    return out


def sondar(video):
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=index,codec_type,codec_name,avg_frame_rate,r_frame_rate,start_time,duration,"
         "sample_rate,nb_frames,width,height", "-of", "json", video],
        capture_output=True, text=True, check=True)
    return json.loads(r.stdout)["streams"]


def fracao(s):
    try:
        a, b = s.split("/")
        return float(a) / float(b) if float(b) else 0.0
    except (ValueError, AttributeError):
        return 0.0


RE_INFO = re.compile(r"n:\s*(\d+)\s+pts:\s*(-?\d+)\s+pts_time:\s*(-?[0-9.eE+-]+)")
RE_AMOSTRAS = re.compile(r"nb_samples:\s*(\d+)")


def luminancia(video, roi, tmp):
    """Luminância média por quadro, e o PTS de cada quadro como o ffmpeg o entrega."""
    filtros = ["showinfo"]
    if roi:
        x, y, w, h = roi
        filtros.append(f"crop={w}:{h}:{x}:{y}")
    filtros += ["scale=64:64:flags=area", "format=gray"]
    bruto = os.path.join(tmp, "luma.raw")
    log = os.path.join(tmp, "video.log")
    with open(log, "w") as err:
        subprocess.run(["ffmpeg", "-v", "info", "-nostats", "-i", video, "-map", "0:v:0",
                        "-vf", ",".join(filtros), "-fps_mode", "passthrough",
                        "-f", "rawvideo", "-y", bruto], stderr=err, check=True)
    pts = []
    with open(log) as f:
        for linha in f:
            if "Parsed_showinfo" in linha:
                m = RE_INFO.search(linha)
                if m:
                    pts.append(float(m.group(3)))
    dados = np.fromfile(bruto, dtype=np.uint8)
    n = len(dados) // (64 * 64)
    y = dados[: n * 64 * 64].reshape(n, 64 * 64).mean(axis=1)
    if n != len(pts):
        sys.exit(f"!! {n} quadros decodificados e {len(pts)} PTS lidos; não confio no alinhamento")
    return np.array(pts), y


def audio(video, tmp):
    """Amostras mono em float e o tempo de cada uma, pelo PTS de cada quadro de áudio."""
    bruto = os.path.join(tmp, "audio.raw")
    log = os.path.join(tmp, "audio.log")
    with open(log, "w") as err:
        subprocess.run(["ffmpeg", "-v", "info", "-nostats", "-i", video, "-map", "0:a:0",
                        "-af", "ashowinfo,aformat=sample_fmts=flt:channel_layouts=mono",
                        "-f", "f32le", "-y", bruto], stderr=err, check=True)
    quadros = []
    with open(log) as f:
        for linha in f:
            if "Parsed_ashowinfo" in linha:
                m, k = RE_INFO.search(linha), RE_AMOSTRAS.search(linha)
                if m and k:
                    quadros.append((float(m.group(3)), int(k.group(1))))
    x = np.fromfile(bruto, dtype=np.float32).astype(np.float64)
    return x, quadros


def tempos_do_audio(quadros, sr, n_total):
    """t de cada amostra. Confere que os quadros são contíguos (sem buraco no som)."""
    t = np.empty(n_total)
    i = 0
    buracos = 0
    esperado = None
    for pts, k in quadros:
        if esperado is not None and abs(pts - esperado) > 1.5 / sr:
            buracos += 1
        k2 = min(k, n_total - i)
        t[i:i + k2] = pts + np.arange(k2) / sr
        i += k2
        esperado = pts + k / sr
    if i < n_total:
        t[i:] = t[i - 1] + (np.arange(n_total - i) + 1) / sr
    return t, buracos


def clarões(t, y):
    lo, hi = np.percentile(y, 10), np.percentile(y, 99.5)
    if hi - lo < 10:
        sys.exit(f"!! sem clarão visível: luminância de {lo:.1f} a {hi:.1f}")
    meio = (lo + hi) / 2

    def cruza(k):
        a, b = y[k - 1], y[k]
        return t[k - 1] + (meio - a) / (b - a) * (t[k] - t[k - 1])

    sobe = [k for k in range(1, len(y)) if y[k - 1] < meio <= y[k]]
    desce = [k for k in range(1, len(y)) if y[k - 1] >= meio > y[k]]
    eventos = []
    j = 0
    for k in sobe:
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
        eventos.append({"t": ts, "dur_ms": dur * 1000, "classe_ms": 40.0 if dur > 0.15 else 0.0})
    return eventos, {"escuro": lo, "claro": hi, "meio": meio}


def bipes(t, x, sr, rampa_ms):
    n = np.arange(len(x))
    z = x * np.exp(-2j * np.pi * BIPE_HZ * n / sr)
    w = max(3, int(round(JANELA_MS / 1000 * sr)) | 1)
    h = w // 2
    c = np.concatenate([[0], np.cumsum(z)])
    env = np.zeros(len(x))
    env[h:len(x) - h] = np.abs(c[w + np.arange(len(x) - 2 * h)] - c[np.arange(len(x) - 2 * h)]) / w
    piso = float(np.median(env))
    topo = float(np.percentile(env, 99))
    if topo < piso * 4:
        sys.exit(f"!! sem bipe audível em {BIPE_HZ:.0f} Hz (piso {piso:.2e}, p99 {topo:.2e})")
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
        eventos.append({"t": tc - rampa_ms / 2000, "pico": float(pico)})
        ultimo = i0
    return eventos, {"piso": piso, "p99": topo}


def quantis(v):
    v = np.asarray(v)
    return {"n": int(len(v)), "p05": float(np.percentile(v, 5)), "p50": float(np.median(v)),
            "p95": float(np.percentile(v, 95)), "media": float(v.mean()),
            "desvio": float(v.std(ddof=1)) if len(v) > 1 else 0.0}


def histograma(v, passo=2.0):
    v = np.asarray(v)
    lo, hi = math.floor(v.min() / passo) * passo, math.ceil(v.max() / passo) * passo
    linhas = []
    b = lo
    while b < hi + 1e-9:
        k = int(((v >= b) & (v < b + passo)).sum())
        linhas.append(f"  {b:+7.1f} ms | {'#' * k} {k}")
        b += passo
    return linhas


def alinhar(obs, esperado):
    """obs: lista de (índice relativo, classe). Devolve o deslocamento com mais acertos."""
    melhor = []
    ultimo = max(i for i, _ in obs)
    for o in range(0, len(esperado) - ultimo):
        acertos = sum(1 for i, c in obs if esperado[o + i] == c)
        melhor.append((acertos, o))
    melhor.sort(reverse=True)
    return melhor


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("--claquete", help="o JSON que a Claquete R5 gravou em Documents")
    ap.add_argument("--roi", help="x,y,w,h da tela do iPad no quadro (após a rotação)")
    ap.add_argument("--distancia-m", type=float, default=0.0,
                    help="distância do alto-falante do iPad ao microfone da testemunha")
    ap.add_argument("--saida", help="grava o relato em JSON")
    ap.add_argument("--aceitar-fps-baixo", action="store_true")
    ap.add_argument("--tolerancia-controle-ms", type=float, default=5.0)
    a = ap.parse_args()

    cfg = {}
    if a.claquete:
        with open(a.claquete) as f:
            cfg = json.load(f)
    intervalo = float(cfg.get("intervalo_s", 2.0))
    rampa = float(cfg.get("rampa_ms", 2.0))
    roi = tuple(int(v) for v in a.roi.split(",")) if a.roi else None

    fluxos = sondar(a.video)
    v = next((s for s in fluxos if s["codec_type"] == "video"), None)
    s = next((s for s in fluxos if s["codec_type"] == "audio"), None)
    if not v or not s:
        sys.exit("!! o arquivo precisa de vídeo e de som")
    fps = fracao(v.get("avg_frame_rate"))
    dur_v, dur_a = float(v.get("duration", 0)), float(s.get("duration", 0))
    sr = int(s["sample_rate"])
    print(f"vídeo {v.get('codec_name')} {v.get('width')}x{v.get('height')} a {fps:.1f} fps, "
          f"{dur_v:.1f} s; som {s.get('codec_name')} {sr} Hz, {dur_a:.1f} s")
    if fps < 200 and not a.aceitar_fps_baixo:
        sys.exit(f"!! {fps:.1f} fps: não é o original da câmera lenta (esperado ~240). Um vídeo "
                 "exportado já desacelerado muda a escala do tempo. Use o original.")
    if abs(dur_v - dur_a) > 1.0:
        sys.exit(f"!! vídeo com {dur_v:.1f} s e som com {dur_a:.1f} s: um dos dois foi esticado")

    with tempfile.TemporaryDirectory() as tmp:
        tv, y = luminancia(a.video, roi, tmp)
        x, quadros = audio(a.video, tmp)
    ta, buracos_som = tempos_do_audio(quadros, sr, len(x))
    dt = np.diff(tv)
    print(f"{len(tv)} quadros, intervalo mediano {np.median(dt) * 1000:.2f} ms "
          f"(máx {dt.max() * 1000:.2f}); som com {buracos_som} descontinuidades")

    fl, niveis = clarões(tv, y)
    bp, nivel_som = bipes(ta, x, sr, rampa)
    print(f"{len(fl)} clarões, {len(bp)} bipes")
    if not fl:
        sys.exit("!! nenhum clarão reconhecido")

    voo = a.distancia_m / VEL_SOM
    pares = []
    usados = set()
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
                      "delta_ms": bruto - f["classe_ms"] - voo * 1000})
    if len(pares) < 10:
        sys.exit(f"!! só {len(pares)} pares clarão/bipe")

    # Alinhamento contra a semente: índice de cada clarão pelo tempo desde o primeiro.
    alinhamento = None
    t_primeiro = fl[0]["t"]
    obs = [(int(round((f["t"] - t_primeiro) / intervalo)), f["classe_ms"]) for f in fl]
    if cfg:
        esperado = [float(e["classe_ms"]) for e in cfg.get("eventos", [])]
        if "semente" in cfg and esperado:
            recalc = classes_da_semente(int(cfg["semente"]), len(esperado))
            if recalc != esperado:
                print("!! as classes do JSON não batem com a semente: gerador divergente")
        if esperado and obs[-1][0] < len(esperado):
            ranking = alinhar(obs, esperado)
            acertos, desloc = ranking[0]
            segundo = ranking[1][0] if len(ranking) > 1 else 0
            alinhamento = {"deslocamento": desloc, "acertos": acertos, "de": len(obs),
                           "fracao": acertos / len(obs), "segundo_melhor": segundo}
            evs = cfg["eventos"]
            for p in pares:
                i = int(round((p["t_clarao_s"] - t_primeiro) / intervalo)) + desloc
                if 0 <= i < len(evs):
                    e = evs[i]
                    p["evento"] = i
                    p["classe_esperada_ms"] = float(e["classe_ms"])
                    if e.get("t_clarao_alvo_s", -1) > 0:
                        p["quantizacao_clarao_ms"] = (e["t_clarao_alvo_s"] - e["t_programado_s"]) * 1000
                        p["bipe_agendado_menos_programado_ms"] = (
                            e["t_bipe_agendado_s"] - e["t_programado_s"]) * 1000
                        p["atrasado"] = bool(e.get("atrasado"))

    deltas = [p["delta_ms"] for p in pares]
    q = quantis(deltas)
    c0 = [p["bruto_ms"] for p in pares if p["classe_ms"] == 0]
    c40 = [p["bruto_ms"] for p in pares if p["classe_ms"] == 40]
    controle = None
    if len(c0) >= 3 and len(c40) >= 3:
        diff = float(np.median(c40) - np.median(c0))
        controle = {"diferenca_ms": diff, "n0": len(c0), "n40": len(c40),
                    "ok": abs(diff - 40) <= a.tolerancia_controle_ms}
    # A quantização do quadro do iPad (o clarão só acende em fronteira de quadro): Δ sem ela,
    # para separar o degrau da tela do resto do viés.
    q_sem = None
    com_q = [p["delta_ms"] + p["quantizacao_clarao_ms"] for p in pares if "quantizacao_clarao_ms" in p]
    if len(com_q) >= 10:
        q_sem = quantis(com_q)

    span = fl[-1]["t"] - fl[0]["t"]
    esperados = int(round(span / intervalo)) + 1
    cobertura = len(pares) / esperados

    print()
    print(f"Δ = t_som − t_imagem, classe descontada, voo do som {voo * 1000:.2f} ms descontado:")
    print(f"  n {q['n']}, p05 {q['p05']:+.1f} ms, p50 {q['p50']:+.1f} ms, p95 {q['p95']:+.1f} ms, "
          f"desvio {q['desvio']:.1f} ms; cobertura {len(pares)}/{esperados} ({cobertura:.0%})")
    for linha in histograma(deltas):
        print(linha)
    if controle:
        print(f"controle 0/+40: mediana(+40) − mediana(0) = {controle['diferenca_ms']:+.1f} ms "
              f"(n {controle['n40']}/{controle['n0']}) → {'OK' if controle['ok'] else 'FALHOU'}")
    if alinhamento:
        print(f"sequência de classes: {alinhamento['acertos']}/{alinhamento['de']} no deslocamento "
              f"{alinhamento['deslocamento']} (segundo melhor: {alinhamento['segundo_melhor']})")
    if q_sem:
        print(f"Δ sem a quantização do quadro do iPad: p50 {q_sem['p50']:+.1f} ms, "
              f"p05 {q_sem['p05']:+.1f}, p95 {q_sem['p95']:+.1f}")
    print("não coberto: o viés da própria testemunha (câmera × microfone do gravador) e ±meio "
          "quadro da convenção de PTS da câmera lenta")

    problemas = []
    if controle is None:
        problemas.append("controle 0/+40 sem as duas classes")
    elif not controle["ok"]:
        problemas.append(f"controle 0/+40 deu {controle['diferenca_ms']:+.1f} ms")
    if alinhamento and alinhamento["fracao"] < 0.95:
        problemas.append(f"sequência de classes confere só {alinhamento['fracao']:.0%}")
    if cobertura < 0.9:
        problemas.append(f"cobertura {cobertura:.0%}")
    base = (f"viés do iPad (som − tela) p50 {q['p50']:+.1f} ms, p05 {q['p05']:+.1f}, "
            f"p95 {q['p95']:+.1f}, n {q['n']}, cobertura {cobertura:.0%}")
    if controle:
        base += f"; controle 0/+40 {controle['diferenca_ms']:+.1f} ms"
    veredito = ("VEREDITO: CALIBRADO — " + base) if not problemas else \
        ("VEREDITO: CALIBRAÇÃO REPROVADA — " + "; ".join(problemas) + " — " + base)
    print()
    print(veredito)

    if a.saida:
        with open(a.saida, "w") as f:
            json.dump({"sonda": "S-C1", "video": os.path.basename(a.video), "fps": fps,
                       "roi": roi, "distancia_m": a.distancia_m, "niveis_luma": niveis,
                       "nivel_som": nivel_som, "claroes": len(fl), "bipes": len(bp),
                       "delta_ms": q, "delta_sem_quantizacao_ms": q_sem, "controle": controle,
                       "alinhamento": alinhamento, "cobertura": cobertura,
                       "buracos_no_som": buracos_som, "pares": pares, "veredito": veredito,
                       "nao_coberto": ["viés câmera × microfone da testemunha",
                                       "±meio quadro da convenção de PTS da câmera lenta",
                                       "obturador rolante (sem ROI)"]},
                      f, indent=2, ensure_ascii=False)
        print(f"relato: {a.saida}")
    return 0 if not problemas else 1


if __name__ == "__main__":
    sys.exit(main())
