#!/bin/bash
# Prova o **receptor do macOS** de ponta a ponta, sozinho, dentro do MacBook.
#
# ## O que ele faz, e o que ele nunca faz
#
# Sobe um emissor (`quall-probe emitir-video`) e o app de produto (`Quall.app`) no **mesmo Mac**,
# em laço local por `127.0.0.1`, e julga a corrida pelos contadores dos dois lados. **Nenhum byte
# sai da máquina**: nenhuma outra frente medindo Wi-Fi é afetada.
#
# A origem é **sintética nossa**, sempre — nunca captura de tela. As duas opções:
#
#   --fonte regua     (padrão) o gerador de `apps/ios/Receptor/Ferramentas/gerar-fonte.swift`, que
#                     desenha o número do quadro em quatro blocos de 64x64. É o que permite provar
#                     **por contador** que o pixel decodificado é o pixel mandado.
#   --fonte testsrc2  `tools/fonte-sintetica.py`, o padrão do libavfilter. Não carrega régua: a
#                     corrida vale pelos contadores de transporte e pela captura da janela.
#
# ## A captura de tela, e por que ela é legítima AQUI
#
# `docs/regras-de-frente.md` proíbe capturar a tela do MacBook anfitrião — é a máquina de trabalho
# do usuário. A saída que a regra deixa aberta é capturar **apenas a janela**, e é o que este
# roteiro faz: `screencapture -l <id da janela do Quall>`, com o id vindo de
# `Bancada/janela-do-app.swift`. Se a janela não puder ser isolada, ele **não captura** e diz que
# não houve confirmação visual.
#
# É a mesma distinção que faz `prova-laco.ps1` manter `--salvar`: o que aparece naquela janela é o
# padrão sintético que este roteiro acabou de gerar, e nada mais.
#
# ## A armadilha dos argumentos, que custou uma investigação
#
# Todos os argumentos do app vão na forma `--chave=valor`. O `NSUserDefaults` do AppKit consome a
# linha de comando em pares, e uma bandeira sem valor desalinha o pareamento até sobrar um token
# sem `-` — que o AppKit trata como **arquivo a abrir**, e um app lançado para abrir um documento
# não ganha a janela do `WindowGroup`. Sem janela não há vista, e a camada de exibição aceita todo
# quadro sem desenhar nada. Ver `Sources/QuallApp/Janela.swift`.
#
# Uso:
#   apps/macos/Bancada/provar-receptor.sh
#   apps/macos/Bancada/provar-receptor.sh --segundos 30 --fonte testsrc2 --porta 17910

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$MACOS/../.." && pwd)"
SAIDA="${QUALL_SAIDA:-/tmp/quall-prova-receptor}"

SEGUNDOS=25
PORTA=17902
PIN=314159
FONTE=regua
LARGURA=1280
ALTURA=720
FPS=30

while [ $# -gt 0 ]; do
    case "$1" in
        --segundos) SEGUNDOS="$2"; shift 2 ;;
        --porta) PORTA="$2"; shift 2 ;;
        --pin) PIN="$2"; shift 2 ;;
        --fonte) FONTE="$2"; shift 2 ;;
        *) echo "argumento desconhecido: $1"; exit 2 ;;
    esac
done

mkdir -p "$SAIDA"
RX="$SAIDA/receptor.log"
TX="$SAIDA/emissor.log"
JANELA="$SAIDA/janela-do-receptor.png"
rm -f "$RX" "$TX" "$JANELA"

echo "==> 1. o núcleo"
if [ ! -f "$RAIZ/target/release/libquall.a" ]; then
    (cd "$RAIZ" && MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
        cargo build --release -p quall-ffi) || exit 1
fi
[ -x "$RAIZ/target/release/quall-probe" ] || (cd "$RAIZ" && cargo build --release -p quall-probe) || exit 1

echo "==> 2. o app (sem instalar em ~/Applications — este é um worktree)"
QUALL_DESTINO= "$MACOS/Empacotar/empacotar-dev.sh" > "$SAIDA/empacotar.log" 2>&1 || {
    echo "!! empacotar falhou; ver $SAIDA/empacotar.log"; exit 1; }
APP="$MACOS/.build/Quall.app"

echo "==> 3. o localizador de janela (ele imprime geometria, nunca título nem pixel)"
swiftc -O "$AQUI/janela-do-app.swift" -o "$SAIDA/janela-do-app" 2>/dev/null || {
    echo "!! não compilou janela-do-app.swift"; exit 1; }

echo "==> 4. a origem sintética ($FONTE)"
if [ "$FONTE" = "regua" ]; then
    GERADOR="$RAIZ/apps/ios/Receptor/Ferramentas/gerar-fonte.swift"
    [ -f "$GERADOR" ] || { echo "!! $GERADOR não existe"; exit 1; }
    # Compilado a partir do arquivo de outra frente, **sem tocá-lo**: `apps/ios/**` não é desta
    # frente. Se ele sumir, este braço da prova sai do ar e o `--fonte testsrc2` continua.
    swiftc -O "$GERADOR" -o "$SAIDA/gerar-fonte" 2>/dev/null || {
        echo "!! não compilou gerar-fonte.swift"; exit 1; }
    "$SAIDA/gerar-fonte" --saida "$SAIDA/fonte" --quadros $((FPS * 40)) \
        --largura "$LARGURA" --altura "$ALTURA" --fps "$FPS" --gop "$FPS" | sed 's/^/    /'
    ENTRADA="$SAIDA/fonte.json"
else
    "$RAIZ/tools/fonte-sintetica.py" --saida "$SAIDA/fonte-testsrc2" --segundos 40 \
        | sed 's/^/    /' || exit 1
    ENTRADA="$SAIDA/fonte-testsrc2/sintetico.json"
fi
[ -f "$ENTRADA" ] || { echo "!! a origem não saiu em $ENTRADA"; exit 1; }

echo "==> 5. o emissor, em laço local"
"$RAIZ/target/release/quall-probe" emitir-video \
    --entrada "$ENTRADA" --porta "$PORTA" --pin "$PIN" --sem-mdns \
    --segundos $((SEGUNDOS + 25)) --repetir \
    --id mac-emissor-bancada --nome "Emissor de bancada" > "$TX" 2>&1 &
PID_TX=$!
sleep 2

echo "==> 6. o receptor — o app de produto, pelo LaunchServices"
# `-n` é obrigatório: com uma instância já aberta, o `open` só a traz para a frente e **descarta
# os argumentos em silêncio**. `--chave=valor` em tudo: ver o cabeçalho.
open -n -a "$APP" --args \
    --registro="$RX" --exibir --endereco="127.0.0.1:$PORTA" --pin="$PIN" \
    --conectar-ja --esperar=1 --segundos="$SEGUNDOS" --sair-apos=$((SEGUNDOS + 12))

echo "==> 7. a janela, no meio da corrida"
sleep 8
ID_JANELA="$("$SAIDA/janela-do-app" Quall | head -1 | cut -d' ' -f1)"
if [ -n "$ID_JANELA" ] && [ "$ID_JANELA" -eq "$ID_JANELA" ] 2>/dev/null; then
    # `-o` sem sombra, `-x` sem som. **Só esta janela**, nunca a tela.
    if screencapture -o -x -l "$ID_JANELA" "$JANELA" 2>/dev/null && [ -s "$JANELA" ]; then
        echo "    janela $ID_JANELA capturada em $JANELA"
    else
        echo "    !! screencapture recusou (permissão de Gravação de Tela do chamador?)."
        echo "       SEM CONFIRMAÇÃO VISUAL — a prova fica só nos contadores."
    fi
else
    echo "    !! não achei a janela do Quall. SEM CONFIRMAÇÃO VISUAL."
fi

echo "==> 8. esperando a corrida fechar"
for _ in $(seq 1 $((SEGUNDOS + 40))); do
    grep -q "receptor FIM" "$RX" 2>/dev/null && break
    sleep 1
done
wait $PID_TX 2>/dev/null

echo
echo "==================== o julgamento ===================="
FIM="$(grep "receptor FIM" "$RX" | tail -1)"
if [ -z "$FIM" ]; then
    echo "REPROVADO: o receptor não chegou a escrever a linha FIM."
    exit 1
fi

campo() { echo "$FIM" | grep -o "$1=[^ ]*" | head -1 | cut -d= -f2; }

RECEBIDOS="$(campo recebidos)"
ENFILEIRADOS="$(campo enfileirados)"
DECODIFICADOS="$(campo decodificados)"
SEM_PARAM="$(campo sem_parametros)"
FALHAS_SESSAO="$(campo falhas_sessao)"
CERTAS="$(campo marca_certas)"
ERRADAS="$(campo marca_erradas)"
NA_ARVORE="$(campo na_arvore)"
CAMADA="$(campo camada)"
ENVIADOS="$(grep -o "quadros enviados *: *[0-9]*" "$TX" | tail -1 | grep -o "[0-9]*$")"

echo "  emissor  : enviados=$ENVIADOS"
echo "  receptor : recebidos=$RECEBIDOS decodificados=$DECODIFICADOS enfileirados=$ENFILEIRADOS"
echo "  régua    : certas=$CERTAS erradas=$ERRADAS"
echo "  camada   : $CAMADA na_arvore=$NA_ARVORE"
echo "  $(grep -o "perda=\[[^]]*\]" "$RX" | tail -1)"
echo "  $(grep "desmonte" "$RX" | tail -1 | sed 's/.*desmonte/desmonte/')"

REPROVA=0
[ "${RECEBIDOS:-0}" -gt 0 ] || { echo "REPROVADO: nenhum quadro chegou"; REPROVA=1; }
[ "${ENFILEIRADOS:-0}" -gt 0 ] || { echo "REPROVADO: nenhum quadro entrou na camada"; REPROVA=1; }
[ "$NA_ARVORE" = "sim" ] || { echo "REPROVADO: a camada não está na árvore — decodifica e não mostra"; REPROVA=1; }
case "$CAMADA" in 0x*|*x0) echo "REPROVADO: a camada tem área zero"; REPROVA=1 ;; esac
[ "${FALHAS_SESSAO:-0}" -eq 0 ] || { echo "REPROVADO: o decodificador recusou montar a sessão"; REPROVA=1; }
[ "${SEM_PARAM:-0}" -eq 0 ] || echo "AVISO: $SEM_PARAM quadros chegaram antes de qualquer SPS (dívida 25)"
if [ "$FONTE" = "regua" ]; then
    [ "${CERTAS:-0}" -gt 0 ] || { echo "REPROVADO: a régua nunca bateu"; REPROVA=1; }
    [ "${ERRADAS:-0}" -eq 0 ] || { echo "REPROVADO: a régua saltou ($ERRADAS vezes) — houve perda"; REPROVA=1; }
fi
grep -q "caixa=liberada" "$RX" || { echo "REPROVADO: a caixa do tratador vazou"; REPROVA=1; }
[ -s "$JANELA" ] && echo "  confirmação visual: $JANELA" || echo "  SEM confirmação visual (ver acima)"

if [ "$REPROVA" -eq 0 ]; then
    echo "APROVADO"
else
    echo "REPROVADO"
fi
exit "$REPROVA"
