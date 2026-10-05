#!/usr/bin/env python3
"""
Resume um ou mais lotes de `aa-corrida.py` — por sentido e por braço, nunca só a média.

A regra da bancada é que **uma corrida não decide nada**, e a média sozinha esconde exatamente o
que importa: na rodada anterior nove corridas de Wi-Fi deram `15, 0, 76, 74, 174, 195, 0, 94, 382`.
Por isso cada linha traz `n`, a soma, a mediana e o **pior caso** — e a lista crua fica embaixo.

    apps/android/tools/aa-resumo.py lote1.json lote2.json
"""
from __future__ import annotations

import json
import statistics
import sys


def num(v, padrao=0.0):
    if v is None:
        return padrao
    try:
        return float(str(v).replace("ms", "").replace(",", "."))
    except ValueError:
        return padrao


def resume(caminho, d=None) -> None:
    d = d if d is not None else json.loads(open(caminho).read())
    c = d["condicao"]
    print(f"\n=== {caminho} — {c['sentido']}, {c['segundos']} s por corrida ===")
    for papel in ("emissor", "receptor"):
        w = c[papel]["wifi"]
        print(f"  {papel:9s} {c[papel]['nome']:7s} {c[papel]['ip']:15s} "
              f"{w['ssid']!r} {w['frequencia']} rssi={w['rssi']} link={w['link']}")

    # Qual chave separa os braços deste lote: a rodada do "pedir ou não pedir" usa `idr_na_perda`,
    # a do "por causa ou por relógio" usa `por_causa`.
    chave = "por_causa" if d["condicao"].get("bracos") == "por-causa" else "idr_na_perda"
    for braco in (False, True):
        corridas = [x for x in d["corridas"] if x.get(chave) is braco and "erro" not in x]
        if not corridas:
            continue
        env = [num(x["emissor"].get("enviados")) for x in corridas]
        rec = [num(x["receptor"].get("recebidos")) for x in corridas]
        # `exibidos` até 31/08/2026 — ver H264Decoder.quadrosEnfileirados para a renomeação.
        exi = [num(x["receptor"].get("enfileirados")) for x in corridas]
        perd = [num(x["receptor"].get("nucleo_frames_dropped")) for x in corridas]
        anom = [num(x["receptor"].get("nucleo_sequence_anomalies")) for x in corridas]
        img = [num(x["receptor"].get("primeira_imagem")) for x in corridas]
        fps = [num(x["receptor"].get("fps")) for x in corridas]
        p50 = [num(x["receptor"].get("decode_p50")) for x in corridas]
        p95 = [num(x["receptor"].get("decode_p95")) for x in corridas]
        ev = [num(x["receptor"].get("eventos_de_perda")) for x in corridas]
        ped = [num(x["receptor"].get("pedidos_por_perda")) for x in corridas]
        sup = [num(x["receptor"].get("suprimidos")) for x in corridas]

        # Amostras cruas quando o lote as guardou; senão, o resumo por corrida da linha de
        # encerramento, que é o que os lotes mais antigos têm.
        semref = [v for x in corridas for v in x.get("sem_referencia_amostras", [])]
        porcorrida = [x["receptor"].get("sem_referencia_ms", "n=0") for x in corridas]

        faltaram = sum(env) - sum(rec)
        print(f"\n  -- braço {chave}={braco} · {len(corridas)} corrida(s)")
        print(f"     enviados {int(sum(env))}  recebidos {int(sum(rec))}  enfileirados {int(sum(exi))}"
              f"   não chegaram {int(faltaram)} ({100 * faltaram / max(sum(env), 1):.2f}%)")
        print(f"     frames_dropped total {int(sum(perd))}  por corrida {[int(v) for v in perd]}")
        print(f"     sequence_anomalies total {int(sum(anom))}  por corrida {[int(v) for v in anom]}")

        # A pergunta que a rodada passada não pôde responder: perda de verdade ou reordenação?
        # `sequence_anomalies == packets_missing_upper_bound + reorder_events`, sempre.
        #
        # **`packets_missing` mudou de nome em 29/08/2026, e a mudança é o conserto.** O número
        # nunca foi perda: reordenação entra nele como se fosse pacote sumido, e o erro medido vai
        # de 1,3x a 44x. Ele agora se chama `packets_missing_upper_bound`, e ao lado dele vem
        # `packets_lost_for_real` — a perda exata, com janela de reordenação de 128 posições.
        # Lotes antigos não têm nenhuma das duas chaves e caem no ramo "ausentes".
        teto = [num(x["receptor"].get("nucleo_packets_missing_upper_bound"), -1) for x in corridas]
        exata = [num(x["receptor"].get("nucleo_packets_lost_for_real"), -1) for x in corridas]
        tarde = [num(x["receptor"].get("nucleo_packets_too_late"), -1) for x in corridas]
        reor = [num(x["receptor"].get("nucleo_reorder_events"), -1) for x in corridas]
        vistos = [num(x["receptor"].get("nucleo_packets_seen"), -1) for x in corridas]
        if min(teto) >= 0:
            tot_t, tot_r, tot_v = sum(teto), sum(reor), sum(vistos)
            if min(exata) >= 0:
                tot_e = sum(exata)
                print(f"     PERDA EXATA {int(tot_e)} "
                      f"({100 * tot_e / max(tot_e + tot_v, 1):.3f}%)   "
                      f"teto {int(tot_t)} ({100 * tot_t / max(tot_t + tot_v, 1):.3f}%)   "
                      f"tarde demais {int(sum(tarde))}   packets_seen {int(tot_v)}")
                print(f"       exata por corrida {[int(v) for v in exata]}")
                if sum(tarde) > 0:
                    print("       JANELA CURTA: `packets_too_late` != 0 — a perda exata está "
                          f"superestimada em até {int(sum(tarde))}")
            else:
                print(f"     só o TETO (esta `.so` não tem o contador exato): "
                      f"{int(tot_t)} ({100 * tot_t / max(tot_t + tot_v, 1):.3f}%)   "
                      f"packets_seen {int(tot_v)} — e teto NÃO é perda")
            print(f"     reorder_events {int(tot_r)}")
            print(f"       teto    por corrida {[int(v) for v in teto]}")
            print(f"       reordem por corrida {[int(v) for v in reor]}")
        else:
            print("     contadores de sequência: ausentes (lote de antes do núcleo novo)")

        res = [num(x["receptor"].get("resolvidas_sem_pedido"), -1) for x in corridas]
        if min(res) >= 0:
            print(f"     perdas resolvidas sem pedido (o GOP chegou antes) {int(sum(res))}")
        print(f"     1ª imagem  {min(img):.1f} – {max(img):.1f} ms   fps {min(fps):.1f} – {max(fps):.1f}")
        print(f"     decode p50 {min(p50):.1f} – {max(p50):.1f} ms   p95 {min(p95):.1f} – {max(p95):.1f} ms")
        print(f"     eventos de perda {int(sum(ev))}  pedidos por perda {int(sum(ped))}  "
              f"suprimidos {int(sum(sup))}")

        # O lado emissor, que é a outra metade da conta: `frames_sent` contra `frames_ready`, e o
        # `buffered_bytes` que diria se o emissor ficou para trás (a fila que a dívida 25 recusou).
        buf = max(num(x["emissor"].get("nucleo_buffered_bytes")) for x in corridas)
        idrs = sum(num(x["emissor"].get("nucleo_idrs_sent")) for x in corridas)
        pedidos = sum(num(x["emissor"].get("nucleo_idr_requests")) for x in corridas)
        semsc = sum(num(x["emissor"].get("sem_start_code")) for x in corridas)
        semcsd = sum(num(x["emissor"].get("nucleo_idrs_without_parameters")) for x in corridas)
        encp50 = [num(x["emissor"].get("p50")) for x in corridas]
        encfps = [num(x["emissor"].get("fps_obtido")) for x in corridas]
        print(f"     emissor: fps {min(encfps):.1f} – {max(encfps):.1f}  encode p50 "
              f"{min(encp50):.1f} – {max(encp50):.1f} ms  IDR no fluxo {int(idrs)}  "
              f"PLI atendidos {int(pedidos)}")
        print(f"     emissor: buffered_bytes máx {int(buf)}  sem_start_code {int(semsc)}  "
              f"idrs_without_parameters {int(semcsd)}")
        if semref:
            print(f"     tempo sem referência: n={len(semref)} "
                  f"mediana {statistics.median(semref):.1f} ms  max {max(semref):.1f} ms")
            print(f"       amostras: {[round(v) for v in sorted(semref)]}")
        else:
            print(f"     tempo sem referência, por corrida: {porcorrida}")

    ruins = [x for x in d["corridas"] if "erro" in x]
    if ruins:
        print(f"\n  corridas que falharam: {len(ruins)}")
        for x in ruins:
            print(f"     {x['erro']}")


if __name__ == "__main__":
    # `--juntar` soma lotes do **mesmo sentido** num só. Dois lotes seguidos do mesmo sentido não
    # são o mesmo que um lote de dobro do tamanho (o ambiente andou entre eles), mas continuam
    # sendo braços intercalados dentro de cada um, que é o que a comparação exige.
    args = [a for a in sys.argv[1:] if a != "--juntar"]
    if "--juntar" in sys.argv:
        juntos = {}
        for caminho in args:
            d = json.loads(open(caminho).read())
            s = d["condicao"]["sentido"]
            if s in juntos:
                juntos[s][1]["corridas"] += d["corridas"]
                juntos[s][0].append(caminho)
            else:
                juntos[s] = ([caminho], d)
        for nomes, d in juntos.values():
            resume(" + ".join(nomes), d)
    else:
        for caminho in args:
            resume(caminho)
