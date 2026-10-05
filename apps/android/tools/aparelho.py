#!/usr/bin/env python3
"""
Dirige o app pela interface, por `adb`, num aparelho escolhido por serial.

Existe por uma razão só, e ela está registrada em `docs/bancada.md`: **`am start` numa Activity
não exportada é recusado com `SecurityException`**, então a única maneira honesta de exercitar o
fluxo de produto é tocar na tela — e tocar na coordenada que o `uiautomator dump` reporta é o que
funciona, desde que a coordenada seja procurada pelo `resource-id` e não decorada (a barra de
tarefas do Samsung muda de altura entre aparelhos, e o teclado desloca tudo).

Uso como biblioteca (é assim que `aa-corrida.py` o usa) ou na mão:

    apps/android/tools/aparelho.py <serial> dump
    apps/android/tools/aparelho.py <serial> toca buttonMirror
    apps/android/tools/aparelho.py <serial> escreve editEndereco 192.168.1.159:7921
"""
from __future__ import annotations

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "com.quall.android"


class Aparelho:
    def __init__(self, serial: str, nome: str = ""):
        self.serial = serial
        self.nome = nome or serial

    # --- adb cru -------------------------------------------------------------------------

    def sh(self, cmd: str, timeout: int = 60) -> str:
        r = subprocess.run(
            ["adb", "-s", self.serial, "shell", cmd],
            capture_output=True, text=True, timeout=timeout,
        )
        return r.stdout

    def sh_ok(self, cmd: str, timeout: int = 60) -> str:
        r = subprocess.run(
            ["adb", "-s", self.serial, "shell", cmd],
            capture_output=True, text=True, timeout=timeout,
        )
        if r.returncode != 0:
            raise RuntimeError(f"{self.nome}: `{cmd}` falhou: {r.stderr.strip()}")
        return r.stdout

    # --- estado do aparelho --------------------------------------------------------------

    def acorda(self) -> None:
        """Acorda e **mantém** a tela acesa.

        `KEYCODE_WAKEUP` acorda e não reinicia o temporizador de desligamento — armadilha 3 do
        `docs/bancada.md`, que já custou um braço inteiro medido com a tela apagada. Quem segura a
        tela é `svc power stayon usb`.
        """
        self.sh("svc power stayon usb")
        self.sh("input keyevent KEYCODE_WAKEUP")
        time.sleep(0.6)
        if "isKeyguardShowing=true" in self.sh("dumpsys window | grep -m1 mDreamingLockscreen"):
            # Deslizar em fração da tela, não em pixel decorado: o tablet fica em paisagem
            # (1920×1080) e um `swipe 360 1200 …` decorado do celular sai pela borda de baixo sem
            # erro nenhum — a tela simplesmente continua trancada.
            w, h = self.tamanho()
            self.sh(f"input swipe {w // 2} {int(h * 0.8)} {w // 2} {int(h * 0.2)} 200")
            time.sleep(0.8)

    def tamanho(self) -> tuple[int, int]:
        """Largura e altura da tela **como ela está agora**, orientação incluída."""
        saida = self.sh("wm size")
        m = re.findall(r"(\d+)x(\d+)", saida)
        w, h = (int(m[-1][0]), int(m[-1][1])) if m else (720, 1280)
        # `wm size` reporta sempre o retrato natural. Quem sabe a orientação de agora é a captura
        # de tela, que sai do compositor já girada — e ela não depende de qual `dumpsys` deste
        # fabricante traz `SurfaceOrientation`.
        png = subprocess.run(
            ["adb", "-s", self.serial, "exec-out", "screencap", "-p"],
            capture_output=True, timeout=60,
        ).stdout
        if len(png) > 24 and png[12:16] == b"IHDR":
            lp = int.from_bytes(png[16:20], "big")
            ap = int.from_bytes(png[20:24], "big")
            if lp and ap:
                return lp, ap
        return w, h

    def solta_tela(self) -> None:
        self.sh("svc power stayon false")

    def tela_acesa(self) -> bool:
        """`Display Power: state=` não existe no `dumpsys power` do tablet (Android 16).

        A armadilha 4 do `docs/bancada.md` diz para usar `Display Power: state=` em vez de
        `mWakefulness=`, e ela vale — para o A10s. No `SM-X230` essa linha simplesmente não
        aparece, e uma checagem que só a procura devolve "apagada" com a tela acesa. Aqui os dois
        padrões contam, e basta um deles dizer que está acesa.
        """
        saida = self.sh("dumpsys power | grep -m2 -E 'Display Power: state=|mWakefulness='")
        return "state=ON" in saida or "mWakefulness=Awake" in saida

    def wifi(self) -> dict:
        linha = self.sh("dumpsys wifi | grep -m1 'mWifiInfo SSID'")
        def campo(nome, padrao=""):
            m = re.search(rf"{nome}: ([^,]+)", linha)
            return m.group(1).strip().strip('"') if m else padrao
        return {
            "ssid": campo("SSID"),
            # **O BSSID entrou em 03/09/2026 e não é detalhe.** Com dois AP vivos e o mesmo SSID
            # nos dois, o nome da rede não diz por qual rádio a corrida passou — e em 02/09 essa
            # lacuna já custou uma hipótese inteira (`docs/bancada.md`, hipótese morta nº 7: dois
            # BSSID comparados errado deram falso negativo). Quem registra o enlace registra o AP.
            "bssid": campo("BSSID"),
            "frequencia": campo("Frequency"),
            "rssi": campo("RSSI"),
            "link": campo("Link speed"),
        }

    def ip(self) -> str:
        saida = self.sh("ip -4 addr show wlan0")
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", saida)
        return m.group(1) if m else ""

    # --- app -----------------------------------------------------------------------------

    def para_app(self) -> None:
        self.sh(f"am force-stop {PKG}")

    def abre_app(self) -> None:
        self.fixa_portugues()
        self.sh(f"monkey -p {PKG} -c android.intent.category.LAUNCHER 1")
        time.sleep(2.0)

    # --- o idioma do app (docs/traducao.md, Android) ---------------------------------------
    #
    # Os roteiros acham botões pelo **texto em português** ("Pronto", "Restaurar automático"…). Desde a
    # tradução o app fala inglês num sistema que não é `pt-*`, ou quando alguém toca em "EN" no Início.
    # No Android 13+ o idioma do app se fixa por `cmd locale` **antes de abrir** (com a tela aberta a
    # troca a recria); no 9–12 não há comando: vale o idioma do sistema e a escolha guardada pelo app.

    def sdk(self) -> int:
        try:
            return int(self.sh("getprop ro.build.version.sdk").strip() or 0)
        except ValueError:
            return 0

    def idioma_do_app(self) -> str:
        """A etiqueta do idioma do app (13+: o escolhido; 9–12: o do sistema), ou "" se não se sabe."""
        if self.sdk() >= 33:
            saida = self.sh(f"cmd locale get-app-locales {PKG}")
            m = re.search(r"are \[([^\]]*)\]", saida)  # "Locales for <pacote> for user 0 are [pt-BR]"
            if m and m.group(1).strip():
                return m.group(1).split(",")[0].strip()
        return (self.sh("getprop persist.sys.locale").strip() or self.sh("getprop ro.product.locale").strip())

    # Quem pede outro idioma de propósito (os retratos com `--idioma en`) põe `False` aqui, e o
    # `abre_app` deixa de devolver o app ao português por cima da escolha.
    fixar_portugues = True

    def fixa_portugues(self) -> None:
        """Deixa o app em português para os roteiros que procuram texto (13+), ou avisa (9–12)."""
        if not self.fixar_portugues:
            return
        if self.sdk() >= 33:
            if not self.idioma_do_app().startswith("pt"):
                self.sh(f"cmd locale set-app-locales {PKG} --locales pt-BR")
            return
        idioma = self.idioma_do_app()
        if idioma and not idioma.startswith("pt"):
            print(f"{self.nome}: AVISO — sistema em {idioma}; o app pode abrir em inglês e os toques por "
                  "texto em português falham. Ponha o sistema em português ou toque em PT no Início.",
                  file=sys.stderr)

    def limpa_logcat(self) -> None:
        subprocess.run(["adb", "-s", self.serial, "logcat", "-c"], capture_output=True)

    def logcat(self, tags: str = "QuallMirror:I QuallReceptor:I QuallDecoder:I QuallNative:I *:S") -> str:
        r = subprocess.run(
            ["adb", "-s", self.serial, "logcat", "-d", "-s"] + tags.split(),
            capture_output=True, text=True, timeout=60,
        )
        return r.stdout

    # --- interface -----------------------------------------------------------------------

    def dump(self, pacote: str = "") -> ET.Element:
        """Árvore da tela atual. Tenta de novo, por dois motivos diferentes.

        O primeiro é conhecido: o dump falha enquanto há animação em curso — é por isso que uma
        tela com vídeo nunca é lida.

        O segundo custou dois lotes nesta rodada. **O `uiautomator` lê a janela ativa, e uma bolha
        de dica do sistema é uma janela.** A dica do "Circle to Search" da Samsung aparece sozinha
        ao voltar para a tela inicial e, enquanto ela está no ar, o dump devolve **só ela** — com o
        app resumido logo atrás. O sintoma foi "não achei o botão Espelhar", que não fala em janela
        nenhuma. Daí o argumento [pacote]: quem sabe qual app espera ver diz, e o dump insiste até
        a árvore ser a dele.
        """
        # **O serial vira nome de arquivo, e por Wi-Fi ele tem `:`.** `adb connect` dá seriais como
        # `192.168.1.138:5555`, e `:` não vale em nome de arquivo no sdcard: o `uiautomator dump`
        # falha e o sintoma que chega é "não devolveu XML", que fala de XML e não de nome. Custou
        # uma corrida em 01/09/2026, quando o aparelho estava plugado no Dell e só havia Wi-Fi para
        # alcançá-lo.
        seguro = re.sub(r"[^A-Za-z0-9_.-]", "_", self.serial)
        dispensou = False
        for _ in range(14):
            saida = self.sh(f"uiautomator dump /sdcard/ui-{seguro}.xml", timeout=30)
            if "dumped to" in saida:
                xml = self.sh(f"cat /sdcard/ui-{seguro}.xml", timeout=30)
                if xml.strip().startswith("<?xml"):
                    try:
                        raiz = ET.fromstring(xml)
                    except ET.ParseError:
                        raiz = None
                    if raiz is not None:
                        pacotes = {no.get("package") for no in raiz.iter("node")}
                        if not pacote or pacote in pacotes:
                            return raiz
                        # A bolha não some sozinha — ela ficou no ar minutos a fio na bancada. Um
                        # `BACK` a dispensa, e só é enviado quando a árvore inteira é do
                        # `systemui`: no app ele navegaria para trás, e no diálogo de
                        # consentimento (que também é `systemui`) este caminho nem roda, porque lá
                        # ninguém pede pacote.
                        if pacotes == {"com.android.systemui"} and not dispensou:
                            dispensou = True
                            self.sh("input keyevent KEYCODE_BACK")
            time.sleep(0.7)
        alvo = f" com pacote {pacote}" if pacote else ""
        raise RuntimeError(f"{self.nome}: uiautomator dump não devolveu XML{alvo}")

    @staticmethod
    def _centro(no: ET.Element):
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", no.get("bounds", ""))
        if not m:
            return None
        x1, y1, x2, y2 = (int(g) for g in m.groups())
        return (x1 + x2) // 2, (y1 + y2) // 2

    def acha(self, *, rid: str = "", texto: str = "", contem: str = "", raiz=None, pacote: str = ""):
        raiz = raiz if raiz is not None else self.dump(pacote)
        for no in raiz.iter("node"):
            if rid and no.get("resource-id", "").endswith("/" + rid):
                return no
            if texto and no.get("text", "") == texto:
                return no
            if contem and contem.lower() in no.get("text", "").lower():
                return no
        return None

    def texto_de(self, rid: str, raiz=None) -> str:
        no = self.acha(rid=rid, raiz=raiz)
        return no.get("text", "") if no is not None else ""

    def toca(self, *, rid: str = "", texto: str = "", contem: str = "", espera: float = 1.2,
             pacote: str = "") -> bool:
        no = self.acha(rid=rid, texto=texto, contem=contem, pacote=pacote)
        if no is None:
            return False
        c = self._centro(no)
        if c is None:
            return False
        self.sh(f"input tap {c[0]} {c[1]}")
        time.sleep(espera)
        return True

    def escreve(self, rid: str, valor: str, pacote: str = PKG) -> bool:
        """Foca o campo pelo `resource-id` e digita.

        Limpa antes com `Ctrl+A`+`Del`: um campo pré-preenchido (o endereço vem do `EXTRA_ENDPOINT`
        quando se chega pela lista) somaria o texto novo ao velho, e o erro sairia como "não
        consegui conectar" — que é a mensagem errada para o defeito certo.
        """
        no = self.acha(rid=rid, pacote=pacote)
        if no is None:
            return False
        c = self._centro(no)
        if c is None:
            return False
        self.sh(f"input tap {c[0]} {c[1]}")
        time.sleep(0.5)
        self.sh("input keyevent KEYCODE_MOVE_END")
        for _ in range(24):
            self.sh("input keyevent KEYCODE_DEL")
        self.sh(f"input text '{valor}'")
        time.sleep(0.4)
        self.sh("input keyevent KEYCODE_BACK")  # fecha o teclado: ele desloca as coordenadas
        time.sleep(0.6)
        return True


def _main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    a = Aparelho(argv[1])
    cmd = argv[2]
    if cmd == "dump":
        raiz = a.dump()
        for no in raiz.iter("node"):
            rid, txt = no.get("resource-id", ""), no.get("text", "")
            if rid or txt:
                print(f"{rid:60s} {no.get('bounds','')}  {txt[:70]!r}")
    elif cmd == "toca":
        print(a.toca(rid=argv[3]))
    elif cmd == "escreve":
        print(a.escreve(argv[3], argv[4]))
    elif cmd == "wifi":
        print(a.wifi())
    else:
        print(f"comando desconhecido: {cmd}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
