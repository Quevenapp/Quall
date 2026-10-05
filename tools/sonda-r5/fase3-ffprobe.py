#!/usr/bin/env python3
"""
R5, fase 3: o MP4 da gravação local, lido pelo ffprobe (docs/teleprompter-com-camera.md §8, M7).

Só os tempos e os contadores — **nenhum quadro é decodificado nem aberto** (a gravação da bancada é o
cartão, mas a regra é a mesma de sempre: mede-se pelos números, não pelos pixels).

    tools/sonda-r5/fase3-ffprobe.py GRAVACAO.mp4 [--buraco-fator 2] [--buracos-aceitos 0]
                                    [--av-tolerancia-ms 50] [--json]

Confere, e diz PASSOU/FALHOU em cada linha:

  - vídeo: PTS começando em 0 e sempre crescendo; os intervalos (mínimo, mediana, p95, máximo); os
    BURACOS — intervalo acima de `--buraco-fator` × a mediana (o critério do §8: "acima de duas
    durações de quadro"), contados e listados com a hora — **acima de `--buracos-aceitos` (padrão
    0), reprova**; o fps médio;
  - som: a CONTINUIDADE (cada pacote começa onde o anterior acabou, a menos de 1 amostra) — o AAC
    num MP4 não tem buraco: um buraco no PTS vira som adiantado para o resto do arquivo;
  - A/V: o fim do vídeo (último PTS + duração) e o fim do som, com a MESMA duração a menos de
    `--av-tolerancia-ms` (padrão 50 ms: um pacote AAC tem 21 ms);
  - a cor declarada, o tamanho e o codec;
  - **a matriz de rotação** (a D1, §14.4: o `MediaMuxer` com `setOrientationHint(0)`, como o fMP4 —
    o quadro já sai de pé do divisor): qualquer rotação declarada reprova;
  - **o som que começa antes do zero** (a D1, §14.4: uma lista de edição do atraso do AAC por cima do
    carimbo que já o desconta adiantaria o som duas vezes): o primeiro pacote de som com PTS negativo
    reprova.

Sai 0 se tudo passou, 1 se algo falhou, 2 em erro de uso ou leitura.
"""
import argparse
import json
import statistics
import subprocess
import sys


def ffprobe(caminho, *args):
    r = subprocess.run(["ffprobe", "-v", "error", *args, "-of", "json", caminho], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"ffprobe falhou: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return json.loads(r.stdout)


def pacotes(caminho, indice):
    d = ffprobe(caminho, "-select_streams", str(indice), "-show_entries", "packet=pts,duration,flags")
    saida = []
    for p in d.get("packets", []):
        if "pts" not in p:
            continue
        saida.append((int(p["pts"]), int(p.get("duration", 0) or 0), "K" in p.get("flags", "")))
    return saida


def pct(v, q):
    if not v:
        return 0.0
    s = sorted(v)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mp4")
    ap.add_argument("--buraco-fator", type=float, default=2.0)
    ap.add_argument("--buracos-aceitos", type=int, default=0)
    ap.add_argument("--av-tolerancia-ms", type=float, default=50.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    info = ffprobe(a.mp4, "-show_streams", "-show_format")
    streams = info.get("streams", [])
    v = next((s for s in streams if s.get("codec_type") == "video"), None)
    s = next((s for s in streams if s.get("codec_type") == "audio"), None)
    rel = {"arquivo": a.mp4, "falhas": []}
    falhas = rel["falhas"]
    if v is None:
        print("FALHOU: sem track de vídeo")
        sys.exit(1)
    if s is None:
        falhas.append("sem track de som (o arquivo nasce com ela, mesmo com o microfone desligado: §5.2)")

    tbv = v["time_base"].split("/")
    tbv = int(tbv[0]) / int(tbv[1])
    pv = pacotes(a.mp4, v["index"])
    rel["video"] = {
        "codec": v.get("codec_name"), "tamanho": f'{v.get("width")}x{v.get("height")}',
        "cor": f'{v.get("color_range")}/{v.get("color_space")}/{v.get("color_primaries")}/{v.get("color_transfer")}',
        "quadros": len(pv), "chaves": sum(1 for p in pv if p[2]),
    }
    rotacao = 0
    for sd in v.get("side_data_list", []) or []:
        if "rotation" in sd:
            rotacao = int(sd["rotation"])
    if "rotate" in (v.get("tags") or {}):
        rotacao = rotacao or int(v["tags"]["rotate"])
    rel["video"]["rotacao"] = rotacao
    if rotacao != 0:
        falhas.append(f"o vídeo declara rotação de {rotacao}° (o arquivo deve sair sem matriz: o quadro já vem de pé)")
    if not pv:
        falhas.append("vídeo sem pacote")
    else:
        pts = [p[0] for p in pv]
        if pts[0] != 0:
            falhas.append(f"o vídeo não começa em 0 (começa em {pts[0] * tbv * 1000:.1f} ms)")
        voltas = [i for i in range(1, len(pts)) if pts[i] <= pts[i - 1]]
        if voltas:
            falhas.append(f"{len(voltas)} PTS de vídeo que não andam (o primeiro no quadro {voltas[0]})")
        ints = [(pts[i] - pts[i - 1]) * tbv * 1000 for i in range(1, len(pts))]
        med = statistics.median(ints) if ints else 0
        limite = a.buraco_fator * med
        buracos = [(i, x) for i, x in enumerate(ints, start=1) if x > limite]
        if len(buracos) > a.buracos_aceitos:
            falhas.append(f"{len(buracos)} buraco(s) de PTS no vídeo acima de {limite:.1f} ms "
                          f"(o maior: {max(x for _, x in buracos):.1f} ms; aceitos: {a.buracos_aceitos})")
        fim_v = (pv[-1][0] + pv[-1][1]) * tbv
        rel["video"].update({
            "fim_s": round(fim_v, 4),
            "intervalo_ms": {"min": round(min(ints), 2) if ints else 0, "mediana": round(med, 2),
                             "p95": round(pct(ints, 0.95), 2), "max": round(max(ints), 2) if ints else 0},
            "fps_medio": round((len(pts) - 1) / ((pts[-1] - pts[0]) * tbv), 3) if len(pts) > 1 and pts[-1] > pts[0] else 0,
            "buracos": len(buracos),
            "buracos_lista": [{"quadro": i, "em_s": round(pts[i - 1] * tbv, 3), "ms": round(x, 1)} for i, x in buracos[:50]],
            "limite_do_buraco_ms": round(limite, 2),
            "duracoes_zeradas": sum(1 for p in pv if p[1] <= 0),
        })

    if s is not None:
        tba = s["time_base"].split("/")
        tba = int(tba[0]) / int(tba[1])
        pa = pacotes(a.mp4, s["index"])
        desc = []
        for i in range(1, len(pa)):
            esperado = pa[i - 1][0] + pa[i - 1][1]
            if abs(pa[i][0] - esperado) > max(1, int(round(1 / (tba * int(s.get("sample_rate", 48000)))))):
                desc.append((i, (pa[i][0] - esperado) * tba * 1000))
        fim_a = (pa[-1][0] + pa[-1][1]) * tba if pa else 0
        rel["som"] = {
            "codec": s.get("codec_name"), "taxa": s.get("sample_rate"), "canais": s.get("channels"),
            "pacotes": len(pa), "comeca_ms": round(pa[0][0] * tba * 1000, 2) if pa else None,
            "fim_s": round(fim_a, 4), "descontinuidades": len(desc),
            "descontinuidades_lista": [{"pacote": i, "salto_ms": round(x, 2)} for i, x in desc[:50]],
        }
        if not pa:
            falhas.append("som sem pacote")
        if desc:
            falhas.append(f"{len(desc)} descontinuidades no som (o primeiro salto: {desc[0][1]:+.1f} ms no pacote {desc[0][0]})")
        if pa and pv:
            dif = (fim_a - rel["video"]["fim_s"]) * 1000
            rel["av_diferenca_do_fim_ms"] = round(dif, 1)
            if abs(dif) > a.av_tolerancia_ms:
                falhas.append(f"o som e a imagem não terminam juntos: {dif:+.1f} ms (tolerância {a.av_tolerancia_ms:.0f} ms)")
            if pa[0][0] * tba * 1000 > a.av_tolerancia_ms:
                falhas.append(f"o som começa {pa[0][0] * tba * 1000:.1f} ms depois da imagem")
            if pa[0][0] * tba * 1000 < -1.0:
                falhas.append(f"o som começa {pa[0][0] * tba * 1000:.1f} ms ANTES do zero "
                              f"(uma lista de edição do atraso do AAC por cima do carimbo? §14.4)")

    if a.json:
        print(json.dumps(rel, ensure_ascii=False, indent=1))
    else:
        vv = rel["video"]
        print(f'{a.mp4}')
        print(f'  vídeo: {vv["codec"]} {vv["tamanho"]} cor {vv["cor"]}, {vv["quadros"]} quadros ({vv["chaves"]} chave), '
              f'fim {vv.get("fim_s")} s, fps médio {vv.get("fps_medio")}, rotação {vv.get("rotacao", 0)}°')
        if "intervalo_ms" in vv:
            i = vv["intervalo_ms"]
            print(f'  intervalos (ms): min {i["min"]} mediana {i["mediana"]} p95 {i["p95"]} max {i["max"]}')
            print(f'  buracos (> {a.buraco_fator:g} × mediana = {vv["limite_do_buraco_ms"]} ms): {vv["buracos"]}' +
                  ("  " + ", ".join(f'{b["ms"]} ms em {b["em_s"]} s' for b in vv["buracos_lista"][:10]) if vv["buracos"] else ""))
        if "som" in rel:
            ss = rel["som"]
            print(f'  som: {ss["codec"]} {ss["taxa"]} Hz x {ss["canais"]}, {ss["pacotes"]} pacotes, começa em {ss["comeca_ms"]} ms, '
                  f'fim {ss["fim_s"]} s, descontinuidades {ss["descontinuidades"]}')
        if "av_diferenca_do_fim_ms" in rel:
            print(f'  A/V: o som termina {rel["av_diferenca_do_fim_ms"]:+.1f} ms em relação à imagem')
        print("PASSOU" if not falhas else "FALHOU:\n  - " + "\n  - ".join(falhas))
    sys.exit(0 if not falhas else 1)


if __name__ == "__main__":
    main()
