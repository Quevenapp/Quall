#!/usr/bin/env python3
"""Prova se multicast atravessa entre os segmentos da LAN — cabo e Wi-Fi.

ICMP atravessar não garante que multicast atravesse: quem encaminha ICMP é o roteador, quem
encaminha multicast é a ponte L2 do AP, e as duas coisas falham separadamente. A descoberta do
Quall depende de multicast, então isso precisa ser fato medido, não suposição.

Usa o grupo e a porta reais do mDNS (224.0.0.251:5353) porque é exatamente esse tráfego que
precisa passar. TTL 1, como manda o mDNS — os dois lados estão na mesma sub-rede, e o que está em
questão é a ponte entre os meios, não roteamento.

    python3 tools/multicast-probe.py escuta
    python3 tools/multicast-probe.py envia "de: dell"
"""

import socket
import struct
import sys
import time

GRUPO = "224.0.0.251"
PORTA = 5353
MARCA = b"QUALL-PROBE "


def escuta(segundos=30.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # O mDNSResponder do macOS já ocupa a 5353; sem SO_REUSEPORT o bind falha.
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("", PORTA))
    s.setsockopt(
        socket.IPPROTO_IP,
        socket.IP_ADD_MEMBERSHIP,
        struct.pack("4sl", socket.inet_aton(GRUPO), socket.INADDR_ANY),
    )
    s.settimeout(1.0)

    print(f"escutando {GRUPO}:{PORTA} por {segundos:.0f}s")
    limite = time.monotonic() + segundos
    recebidos = 0
    while time.monotonic() < limite:
        try:
            dados, origem = s.recvfrom(2048)
        except socket.timeout:
            continue
        if dados.startswith(MARCA):
            recebidos += 1
            print(f"  recebido de {origem[0]}: {dados[len(MARCA):].decode(errors='replace')}")
    print(f"total de pacotes do probe: {recebidos}")
    return 0 if recebidos else 1


def envia(rotulo, repeticoes=10):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    carga = MARCA + rotulo.encode()
    for i in range(repeticoes):
        s.sendto(carga, (GRUPO, PORTA))
        print(f"  enviado {i + 1}/{repeticoes}")
        time.sleep(1)
    return 0


if __name__ == "__main__":
    modo = sys.argv[1] if len(sys.argv) > 1 else "escuta"
    if modo == "escuta":
        sys.exit(escuta(float(sys.argv[2]) if len(sys.argv) > 2 else 30.0))
    elif modo == "envia":
        sys.exit(envia(sys.argv[2] if len(sys.argv) > 2 else "sem rótulo"))
    else:
        print(__doc__)
        sys.exit(2)
