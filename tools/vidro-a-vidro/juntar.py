#!/usr/bin/env python3
"""Junta os registros do emissor e do receptor e imprime a distribuição.

O join é feito por fora, sobre NDJSON bruto, de propósito: o dado sobrevive à aritmética e
qualquer pessoa pode reconferir o número sem confiar no arnês.

Âncoras, todas no mesmo relógio (`mach_absolute_time`, base canônica):

    T0  desenho_ns              varredura PREVISTA do quadro do emissor que carregava o índice
    T0c commit_ns               o desenho foi entregue ao render server (retorno do flush)
    Tp  pts_ns                  pts do ScreenCaptureKit, trazido da base contínua para a canônica
    T1  captura_ns              o quadro chegou ao processo, no retorno do ScreenCaptureKit
    T2  encode_ns               o VideoToolbox devolveu o quadro codificado
    Ts  envio_ns                imediatamente antes do write no fio
    T3r chegada_ns              o quadro inteiro saiu do fio no receptor
    T3  decodificado_ns         o VideoToolbox devolveu o quadro decodificado
    T4  apresentacao_alvo_ns    varredura PREVISTA do quadro do receptor que ACENDEU o índice
    T4c apresentacao_commit_ns  a superfície decodificada foi entregue ao render server

    manchete = T4 - T0, onset a onset. As duas pontas usam o MESMO estimador (previsão do
    CADisplayLink no mesmo painel), então um viés constante do estimador se cancela na
    subtração — é isso que sustenta a manchete apesar de nenhuma ponta ser um fóton.

    Medido: T0 - T0c fica na casa dos milissegundos e o pts do ScreenCaptureKit cai ENTRE os
    dois. Ou seja, a captura toca no compositor antes de o painel varrer. Por isso "a janela
    mudou" é ancorado em T0c quando o consumidor é o compositor, e em T0 quando o consumidor é
    o olho. Publicar as duas.

Cobertura faz parte do número: quantos índices foram desenhados, quantos o ScreenCaptureKit
entregou, quantos foram codificados, quantos decodificados e quantos **acenderam**. Índice que
não acendeu é dado censurado, não amostra ausente — percentil calculado só sobre quem acendeu
apaga os piores casos.
"""

import argparse
import json
import os
import statistics
import sys


def carregar_ndjson(caminho):
    if not os.path.exists(caminho):
        return []
    linhas = []
    with open(caminho, "r", encoding="utf-8") as f:
        for linha in f:
            linha = linha.strip()
            if not linha:
                continue
            try:
                linhas.append(json.loads(linha))
            except json.JSONDecodeError:
                pass  # linha truncada por encerramento abrupto — conta como perdida, não quebra
    return linhas


def percentis(amostras):
    if not amostras:
        return {}
    ordenadas = sorted(amostras)

    def p(q):
        if len(ordenadas) == 1:
            return ordenadas[0]
        pos = q / 100.0 * (len(ordenadas) - 1)
        baixo = int(pos)
        alto = min(len(ordenadas) - 1, baixo + 1)
        f = pos - baixo
        return ordenadas[baixo] * (1 - f) + ordenadas[alto] * f

    return {
        "n": len(ordenadas),
        "min": ordenadas[0],
        "p50": p(50),
        "p90": p(90),
        "p95": p(95),
        "p99": p(99),
        "max": ordenadas[-1],
        "media": statistics.fmean(ordenadas),
        "desvio": statistics.pstdev(ordenadas) if len(ordenadas) > 1 else 0.0,
    }


def ms(ns):
    return ns / 1_000_000.0


def histograma(amostras, largura_ms=1.0, teto=14):
    """A distribuição da manchete é quantizada pelo refresh do painel: p50 e p95 iguais não
    querem dizer dispersão zero, querem dizer que a maioria caiu no mesmo degrau. Sem o
    histograma esse fato some."""
    if not amostras:
        return []
    baldes = {}
    for a in amostras:
        b = int(a // largura_ms)
        baldes[b] = baldes.get(b, 0) + 1
    ordenados = sorted(baldes.items(), key=lambda kv: -kv[1])[:teto]
    return sorted(ordenados, key=lambda kv: kv[0])


def linha_de_dist(nome, d):
    if not d:
        return f"  {nome:<38} sem amostra"
    return (
        f"  {nome:<38} n={d['n']:<5} p50={d['p50']:8.2f}  p95={d['p95']:8.2f}  "
        f"máx={d['max']:8.2f}  média={d['media']:8.2f}  dp={d['desvio']:7.2f}"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("diretorio")
    ap.add_argument("--json", help="grava o resumo neste arquivo")
    ap.add_argument(
        "--desde", type=float, default=0.0,
        help="descarta os primeiros N segundos da corrida.")
    args = ap.parse_args()
    d = args.diretorio

    emissor = carregar_ndjson(os.path.join(d, "emissor.ndjson"))
    receptor = carregar_ndjson(os.path.join(d, "receptor.ndjson"))
    quadros = carregar_ndjson(os.path.join(d, "receptor-quadros.ndjson"))
    apresentacao = carregar_ndjson(os.path.join(d, "receptor-apresentacao.ndjson"))
    emissor_quadros = carregar_ndjson(os.path.join(d, "emissor-quadros.ndjson"))

    cab_e = next((x for x in emissor if x.get("evento") == "cabecalho"), {})
    cab_r = next((x for x in receptor if x.get("evento") == "cabecalho"), {})
    res_e = next((x for x in emissor if x.get("evento") == "resumo"), {})
    res_r = next((x for x in receptor if x.get("evento") == "resumo"), {})

    # Primeiro acendimento de cada índice — onset, não célula assentada.
    acendeu = {}
    for a in apresentacao:
        if a.get("evento") != "acendeu":
            continue
        i = a["indice"]
        if i not in acendeu or a["apresentacao_alvo_ns"] < acendeu[i]["apresentacao_alvo_ns"]:
            acendeu[i] = a

    retencoes = [a["quadros_de_tela"] for a in apresentacao if a.get("evento") == "retencao"]

    fatias = {
        "T0c→Tp captura interna do ScreenCaptureKit": [],
        "Tp→T1  fila do SCK até o processo": [],
        "T0c→T1 commit do desenho → quadro no processo": [],
        "T0c→T0 commit → varredura prevista do emissor": [],
        "T1→T2  encode (VideoToolbox)": [],
        "T2→Ts  entrega ao fio": [],
        "Ts→T3r fio (soquete unix, NÃO é a rede)": [],
        "T3r→T3 decode (VideoToolbox)": [],
        "T3→T4c decodificado → commit da apresentação": [],
        "T3→T4  decodificado → acendeu na tela": [],
    }
    manchete = []
    ate_decode = []
    trabalho = []
    # Regime ao longo da corrida. Entrou por uma hipótese ERRADA — "o encoder aquece" — que a
    # tabela derrubou: numa corrida de 60 s o encode fica plano em 5,9 ms do primeiro ao último
    # segundo. O que move o encode é CONTENÇÃO da máquina, não tempo de corrida (medido: 2,8 ms
    # com a máquina folgada contra 5,9 ms com ela ocupada, mesmo tamanho de quadro). A tabela
    # fica porque é ela que separa as duas explicações; quem publicar um encode p50 sozinho, sem
    # a carga ao lado, está publicando folclore.
    janelas = [(0, 3), (3, 6), (6, 12), (12, 20), (20, 10**9)]
    por_janela = {j: {"encode": [], "decode": [], "sck": [], "bytes": []} for j in janelas}
    inicio_ns = min((q["captura_ns"] for q in quadros), default=0)
    descartados_por_desde = 0
    censurados = 0
    sem_leitura = 0
    divergentes = 0

    for q in quadros:
        idx = q.get("indice_decodificado")
        if idx is None:
            sem_leitura += 1
            continue
        if idx != q.get("indice_cabecalho"):
            divergentes += 1
            continue
        t0 = q["desenho_ns"]
        t0c = q["commit_ns"]
        tp = q["pts_ns"]
        t1 = q["captura_ns"]
        t2 = q["encode_ns"]
        ts = q["envio_ns"]
        t3r = q["chegada_ns"]
        t3 = q["decodificado_ns"]

        idade = (t1 - inicio_ns) / 1e9
        for j in janelas:
            if j[0] <= idade < j[1]:
                por_janela[j]["encode"].append(ms(t2 - t1))
                por_janela[j]["decode"].append(ms(t3 - t3r))
                por_janela[j]["sck"].append(ms(t1 - t0c))
                por_janela[j]["bytes"].append(float(q["bytes"]))
                break
        if idade < args.desde:
            descartados_por_desde += 1
            continue

        ate_decode.append(ms(t3 - t0))
        # O trecho em que o Quall realmente trabalha: do quadro no processo ao pixel
        # decodificado. Fora dele só há espera pela próxima batida do compositor e do painel,
        # que é quantização de refresh, não custo de software. Sem separar os dois, 33 ms
        # parecem culpa do pipeline e viram decisão de arquitetura errada.
        trabalho.append(ms(t3 - t1))
        fatias["T0c→Tp captura interna do ScreenCaptureKit"].append(ms(tp - t0c))
        fatias["Tp→T1  fila do SCK até o processo"].append(ms(t1 - tp))
        fatias["T0c→T1 commit do desenho → quadro no processo"].append(ms(t1 - t0c))
        fatias["T0c→T0 commit → varredura prevista do emissor"].append(ms(t0 - t0c))
        fatias["T1→T2  encode (VideoToolbox)"].append(ms(t2 - t1))
        fatias["T2→Ts  entrega ao fio"].append(ms(ts - t2))
        fatias["Ts→T3r fio (soquete unix, NÃO é a rede)"].append(ms(t3r - ts))
        fatias["T3r→T3 decode (VideoToolbox)"].append(ms(t3 - t3r))
        a = acendeu.get(idx)
        if a is None:
            censurados += 1
            continue
        t4 = a["apresentacao_alvo_ns"]
        if a.get("apresentacao_commit_ns"):
            fatias["T3→T4c decodificado → commit da apresentação"].append(
                ms(a["apresentacao_commit_ns"] - t3))
        fatias["T3→T4  decodificado → acendeu na tela"].append(ms(t4 - t3))
        manchete.append(ms(t4 - t0))

    dist_manchete = percentis(manchete)
    dist_decode = percentis(ate_decode)
    dist_trabalho = percentis(trabalho)
    dist_fatias = {k: percentis(v) for k, v in fatias.items()}
    dist_retencao = percentis([float(r) for r in retencoes])

    desenhados = res_e.get("desenhados", 0)
    capturados = res_e.get("capturados", 0)
    enviados = res_e.get("enviados", 0)
    decodificados = res_r.get("decodificados", 0)
    acesos = len(acendeu)

    print("=" * 96)
    print("LATÊNCIA VIDRO A VIDRO — laço fechado de janela, um relógio só")
    print("=" * 96)
    print(f"  diretório                    {os.path.abspath(d)}")
    print(f"  captura                      {cab_e.get('captura_largura')}x{cab_e.get('captura_altura')} "
          f"@ {cab_e.get('fps_captura')} fps  (desenho a {cab_e.get('hz_desenho')} Hz)")
    print(f"  encoder                      {cab_e.get('encoder')} (hardware={cab_e.get('encoder_hardware')})")
    print(f"  decoder hardware             {res_r.get('decode_hardware')}")
    print(f"  refresh do painel            emissor {cab_e.get('refresh_hz')} Hz · receptor {cab_r.get('refresh_hz')} Hz")
    print(f"  janela capturada             id={cab_e.get('window_id')} dono_pid={cab_e.get('dono_pid')} "
          f"(pid do emissor={cab_e.get('pid')}) título confere={cab_e.get('janela_titulo_confere')}")
    print(f"  desvio CACurrentMediaTime    emissor {cab_e.get('desvio_mediatime_ns')} ns · "
          f"receptor {cab_r.get('desvio_mediatime_ns')} ns")
    print(f"  contínuo − absoluto          emissor {cab_e.get('deslocamento_continuo_ns')} ns · "
          f"receptor {cab_r.get('deslocamento_continuo_ns')} ns")
    ci = cab_e.get("carga_inicio", {})
    cf = res_e.get("carga_fim", {})
    print(f"  carga (load avg 1/5/15)      início {ci.get('load_avg')} · fim {cf.get('load_avg')} "
          f"em {ci.get('nucleos')} núcleos")
    print()
    print("-- cobertura (índices) ------------------------------------------------------------------------")
    print(f"  desenhados pelo emissor      {desenhados}")
    print(f"  entregues pelo SCK           {capturados}")
    print(f"  lidos nos pixels capturados  {res_e.get('lidos_na_captura')}   falhas={res_e.get('falhas_de_leitura')}")
    print(f"  codificados / enviados       {res_e.get('codificados')} / {enviados}   "
          f"submissões recusadas={res_e.get('submissoes_recusadas')}")
    print(f"  decodificados                {decodificados}   recusados={res_r.get('decode_recusados')} "
          f"sem_parametros={res_r.get('decode_sem_parametros')}")
    print(f"  lidos nos pixels decodificados {res_r.get('lidos_no_decode')}   falhas={res_r.get('falhas_de_leitura')}")
    print(f"  ACENDERAM na tela do receptor {acesos}")
    print(f"  decodificados que NÃO acenderam (censurados) {censurados}")
    print(f"  quadros sem leitura possível  {sem_leitura}   divergência cabeçalho×pixels {divergentes}")
    if enviados:
        print(f"  acendeu / enviado             {acesos / enviados * 100:.1f}%")
    if desenhados:
        print(f"  acendeu / desenhado           {acesos / desenhados * 100:.1f}%")
    conf = res_r.get("conferidos_na_composicao")
    print(f"  confirmados na composição do receptor (recaptura da própria janela) "
          f"{conf} de {res_r.get('recapturados')} requadros "
          f"(ilegíveis {res_r.get('recapturados_ilegiveis')})")
    print()
    print("-- MANCHETE (ms) ------------------------------------------------------------------------------")
    print(linha_de_dist("T0→T4  vidro a vidro LOCAL (onset)", dist_manchete))
    print(linha_de_dist("T0→T3  até o pixel decodificado", dist_decode))
    print(linha_de_dist("T1→T3  TRABALHO do pipeline (sem refresh)", dist_trabalho))
    print()
    print("  degraus da manchete (largura 1 ms, os mais populosos):")
    total_m = len(manchete)
    for b, n in histograma(manchete):
        barra = "#" * max(1, round(60 * n / total_m)) if total_m else ""
        print(f"    [{b*1.0:6.1f}, {(b+1)*1.0:6.1f}) ms  {n:5d}  {n/total_m*100:5.1f}%  {barra}")
    print()
    print("-- regime ao longo da corrida (ms; plano = estável, degrau = contenção externa) ----------")
    print(f"  {'janela (s)':>12} {'n':>6} {'encode p50':>11} {'encode p95':>11} {'decode p50':>11} "
          f"{'commit→proc p50':>16} {'bytes p50':>10}")
    for j in janelas:
        v = por_janela[j]
        if not v["encode"]:
            continue
        rot = f"{j[0]}-{'fim' if j[1] > 10**8 else j[1]}"
        pe, pd, ps, pb = (percentis(v["encode"]), percentis(v["decode"]),
                          percentis(v["sck"]), percentis(v["bytes"]))
        print(f"  {rot:>12} {pe['n']:>6} {pe['p50']:>11.2f} {pe['p95']:>11.2f} {pd['p50']:>11.2f} "
              f"{ps['p50']:>16.2f} {pb['p50']:>10.0f}")
    if args.desde:
        print(f"  (--desde {args.desde}s descartou {descartados_por_desde} quadros do aquecimento)")
    print()
    print("-- atribuição por elo (ms) --------------------------------------------------------------------")
    for nome, dd in dist_fatias.items():
        print(linha_de_dist(nome, dd))
    print()
    print("-- idade da tela do receptor (NÃO é latência) -------------------------------------------------")
    print(linha_de_dist("retenção do quadro, em quadros de tela", dist_retencao))
    print()
    print("O que este número NÃO cobre: a rede (é laço local), o painel do emissor até o fóton,")
    print("a varredura do painel do receptor, e qualquer aparelho que não seja este MacBook.")
    print("=" * 96)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "cabecalho_emissor": cab_e,
                    "cabecalho_receptor": cab_r,
                    "resumo_emissor": res_e,
                    "resumo_receptor": res_r,
                    "cobertura": {
                        "desenhados": desenhados,
                        "entregues_sck": capturados,
                        "codificados": res_e.get("codificados"),
                        "enviados": enviados,
                        "decodificados": decodificados,
                        "acenderam": acesos,
                        "censurados": censurados,
                        "sem_leitura": sem_leitura,
                        "divergentes": divergentes,
                        "confirmados_na_composicao": conf,
                        "recapturados": res_r.get("recapturados"),
                    },
                    "manchete_ms": dist_manchete,
                    "manchete_histograma_1ms": histograma(manchete, 1.0, 40),
                    "ate_decode_ms": dist_decode,
                    "trabalho_do_pipeline_ms": dist_trabalho,
                    "fatias_ms": dist_fatias,
                    "retencao_quadros_de_tela": dist_retencao,
                    "desde_s": args.desde,
                    "regime": {
                        f"{j[0]}-{'fim' if j[1] > 10**8 else j[1]}": {
                            "encode": percentis(por_janela[j]["encode"]),
                            "decode": percentis(por_janela[j]["decode"]),
                            "commit_ate_processo": percentis(por_janela[j]["sck"]),
                            "bytes": percentis(por_janela[j]["bytes"]),
                        }
                        for j in janelas if por_janela[j]["encode"]
                    },
                },
                f,
                indent=2,
                ensure_ascii=False,
            )
        print(f"resumo em {args.json}")

    if not manchete:
        print("SEM AMOSTRA — não afirmo número nenhum.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
