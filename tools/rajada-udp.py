#!/usr/bin/env python3
# Os identificadores e endereços de exemplos/fixtures são sintéticos.
"""Emissor de trem de pacotes UDP, para medir perda de rede SEM o Quall no meio.

Existe porque a perda medida no enlace Dell -> A10s (52 pacotes em 1190, 28/08) precisava ser
separada em "a rede perde" e "o nosso empacotador perde". Este emissor não tem nada do Quall
dentro: abre um socket UDP, manda N datagramas para uma **porta fechada** do alvo e sai.

A testemunha do outro lado é o kernel do alvo, não código nosso: `/proc/net/snmp`, campo
`Udp: NoPorts`, conta **um por datagrama que chegou ao IP e não achou socket**. Medido nesta
bancada: 0 de ruído de fundo em três janelas de 10 s no A10s. Ou seja, o delta do contador é
exatamente quantos dos meus pacotes chegaram — sem instalar nada no aparelho, e sem depender de
nenhum instrumento nosso, que é a razão de este caminho existir (ver `bancada.md`, "O dia em que
o instrumento era o defeito").

O mesmo arquivo roda no macOS e no Windows do Dell, de propósito: trocar de emissor sem trocar
de instrumento é o que separa "é do Windows" de "é da rede".

    python3 tools/rajada-udp.py --destino 192.168.56.159:9911 --pacotes 200 --tamanho 1200
    python3 tools/rajada-udp.py --destino 192.168.56.159:9911 --rajadas 5 --pacotes 163 \
                                --pausa-ms 33

`--pacotes` sem `--intervalo-us` manda em rajada colada, que é a forma que um IDR tem no fio:
o conjunto de parâmetros de 1080p do emissor do Windows são 163 pacotes que saem de uma vez
(`bancada.md`, 27/08). `--intervalo-us` espaça, e a diferença entre os dois é a medida.

A saída é uma linha por rajada, em TSV, para o roteiro do outro lado casar com o contador.
"""

import argparse
import socket
import sys
import time


def espera_ate(alvo):
    """Espera ocupada. `time.sleep` no Windows tem grão de ~15 ms, e o que se quer medir aqui
    tem grão de dezenas de microssegundos — dormir mediria o relógio do sistema, não a rede."""
    while time.perf_counter() < alvo:
        pass


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--destino", required=True, help="IP:PORTA (use porta FECHADA no alvo)")
    p.add_argument("--pacotes", type=int, default=200, help="datagramas por rajada")
    p.add_argument("--tamanho", type=int, default=1200, help="bytes de carga por datagrama")
    p.add_argument("--intervalo-us", type=int, default=0, help="espaçamento entre pacotes (0 = colado)")
    p.add_argument("--rajadas", type=int, default=1)
    p.add_argument("--pausa-ms", type=float, default=1000.0, help="pausa entre rajadas")
    p.add_argument("--sndbuf", type=int, default=0, help="SO_SNDBUF em bytes (0 = padrão do SO)")
    # O braço que separa "a fila do caminho é rasa" de "o rádio do alvo estava dormindo". Um
    # aparelho Android em economia de energia só é servido pelo ponto de acesso nos beacons
    # (DTIM), e o que não couber no buffer do AP até lá morre. Um fio fino de pacotes antes da
    # rajada tira o rádio do sono sem encher fila nenhuma — se a perda cair, a causa é o sono, e
    # não a profundidade da fila. `bancada.md` já mediu o sono por outro caminho: Mac->A10s com a
    # tela apagada entrega 0 de 20 pings, e 232 ms de média com ela acesa contra 35 ms quando o
    # próprio aparelho fala primeiro.
    p.add_argument("--aquecimento-ms", type=float, default=0.0,
                   help="antes da rajada, manda 1 pacote a cada --aquecimento-passo-ms por este tempo")
    p.add_argument("--aquecimento-passo-ms", type=float, default=20.0)
    # Silêncio entre o aquecimento e a rajada. É o que mede **quanto tempo o caminho leva para
    # voltar ao estado ruim**, e essa é a pergunta que decide se isto dói no produto: uma sessão
    # de 30 fps manda um pacote a cada 33 ms e nunca fica ociosa depois que abre. Precisa ser
    # medido dentro do MESMO processo — duas invocações por SSH têm ~1,5 s de partida entre elas,
    # que é maior que o efeito que se quer resolver.
    p.add_argument("--ocio-ms", type=float, default=0.0)
    # **A forma de uma sessão do Quall, e não um trem uniforme.**
    #
    # O lote de 30/08 varreu o tamanho da rajada com trens uniformes e achou o penhasco entre 40 e
    # 80 pacotes colados, com a taxa média presa em ~133 pac/s. Mas a sessão do produto não é
    # uniforme: são ~31 quadros por segundo de ~8 pacotes cada e, a cada ~1,3 s, um IDR de ~20.
    # A pergunta que o trem uniforme não responde é se **o IDR mata os vizinhos** — se os 20
    # pacotes colados enchem a fila do ponto de acesso e o que morre é o quadro que vem atrás, e
    # não o IDR (que em 29/08 chegou inteiro em 71 de 79 vezes).
    #
    # Com `--rajada-grande G --a-cada K`, uma rajada em cada K tem G pacotes em vez de `--pacotes`.
    # O A/B de uma variável só é rodar o mesmo trem com e sem a rajada grande.
    p.add_argument("--rajada-grande", type=int, default=0,
                   help="tamanho da rajada periódica maior (0 = trem uniforme)")
    p.add_argument("--a-cada", type=int, default=0,
                   help="de quantas em quantas rajadas a grande acontece")
    a = p.parse_args()

    ip, porta = a.destino.rsplit(":", 1)
    alvo = (ip, int(porta))

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if a.sndbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, a.sndbuf)
    sndbuf = s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)

    print(f"# emissor {sys.platform} sndbuf={sndbuf} destino={a.destino} "
          f"pacotes={a.pacotes} tamanho={a.tamanho} intervalo_us={a.intervalo_us}", flush=True)
    print("rajada\tenviados\terros\tms\tmbps", flush=True)

    # O aquecimento é contado à parte e NÃO entra no total da rajada: ele é a condição do
    # experimento, não a medida. Quem soma o contador do outro lado precisa somar estes também,
    # e por isso o número sai na saída.
    aquecidos = 0
    if a.aquecimento_ms > 0:
        n = max(1, int(a.aquecimento_ms / a.aquecimento_passo_ms))
        t0 = time.perf_counter()
        for i in range(n):
            try:
                s.sendto(b"aquece", alvo)
                aquecidos += 1
            except OSError:
                pass
            espera_ate(t0 + (i + 1) * a.aquecimento_passo_ms / 1000.0)
    print(f"# aquecimento={aquecidos} pacotes ocio_ms={a.ocio_ms}", flush=True)
    if a.ocio_ms > 0:
        espera_ate(time.perf_counter() + a.ocio_ms / 1000.0)

    # **A pausa é agendada em relógio absoluto, e não dormida.** `time.sleep` no Windows tem grão
    # de ~15 ms: com as pausas de 75 a 600 ms dos trens de 30/08 isso é erro de poucos por cento,
    # mas a cadência de uma sessão de 31 fps é de **32 ms** — ali o grão do `sleep` é erro de
    # 50 %, e o experimento mediria o relógio do Windows em vez da rede. `espera_ate` é a mesma
    # espera ocupada que o espaçamento entre pacotes já usava.
    total_enviados = 0
    inicio_do_trem = time.perf_counter()
    for r in range(a.rajadas):
        if r:
            espera_ate(inicio_do_trem + r * a.pausa_ms / 1000.0)
        quantos = a.pacotes
        if a.rajada_grande and a.a_cada and r % a.a_cada == 0:
            quantos = a.rajada_grande
        # A carga carrega o número de sequência em ASCII no começo. Este emissor não tem quem
        # leia isso (a testemunha é um contador do kernel), mas um `tcpdump` do lado de lá — se
        # um dia houver root nesta bancada — consegue dizer QUAIS faltaram, e não só quantos.
        enviados = erros = 0
        t0 = time.perf_counter()
        for i in range(quantos):
            carga = b"%06d " % i + b"x" * max(0, a.tamanho - 7)
            try:
                s.sendto(carga, alvo)
                enviados += 1
            except OSError:
                erros += 1
            if a.intervalo_us:
                espera_ate(t0 + (i + 1) * a.intervalo_us / 1e6)
        dur = time.perf_counter() - t0
        total_enviados += enviados
        mbps = (enviados * a.tamanho * 8) / dur / 1e6 if dur > 0 else 0.0
        print(f"{r}\t{enviados}\t{erros}\t{dur*1000:.2f}\t{mbps:.1f}", flush=True)

    # **A taxa média MEDIDA, e não a pretendida.** Um braço que se propõe a comparar formas de
    # tráfego com a taxa média presa tem de provar que ela ficou presa; sem esta linha, "mesma
    # taxa média" seria aritmética de intenção.
    decorrido = time.perf_counter() - inicio_do_trem
    print(f"# trem: pacotes={total_enviados} duracao_s={decorrido:.3f} "
          f"taxa_media_pac_s={total_enviados/decorrido if decorrido else 0:.1f}", flush=True)


if __name__ == "__main__":
    main()
