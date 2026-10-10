#!/bin/bash
# Prova o **teleprompter do Mac** (`docs/contrato-teleprompter.md`) nos dois papéis, sozinho, dentro
# do MacBook, em laço local por 127.0.0.1 — nenhum byte sai da máquina e nenhum aparelho da bancada
# é usado.
#
#   A. o PROMPTER do app (aberto pelo LaunchServices) e a `quall-probe controle` como controle:
#      1. um controle entra com PIN, manda um roteiro de 100 000 bytes, a velocidade, o rolar e 20
#         edições; o prompter edita dos dois lados ao mesmo tempo (fonte, espelho, margem, linha) e,
#         com o editor aberto, recebe o roteiro do controle — o aviso de conflito aparece, a pessoa
#         (a ação de bancada) mantém o dela e confirma: vale o último que mudou, nos dois lados;
#      2. o controle sai: o prompter segue rolando, com o aviso de controle sumido;
#      3. o controle volta **sem PIN** (par lembrado) na mesma porta: o aviso some;
#      4. um aparelho erra o PIN: o prompter troca o PIN; um controle entra com o PIN novo, e um
#         segundo, ao mesmo tempo, ouve "ocupado" (BUSY).
#   B. o CONTROLE do app e a `quall-probe teleprompter` como prompter: o app manda roteiro, velocidade,
#      rolar, pular, espelho, fonte e salto; o prompter cai, o app mostra a conexão perdida e tenta de
#      novo; o prompter volta na mesma porta e o app entra de novo **sem PIN**.
#
# ## A captura, e por que ela é legítima aqui
#
# `docs/regras-de-frente.md` proíbe capturar a tela do MacBook: é a máquina de trabalho do usuário.
# Este roteiro captura **só a janela do app**, com `screencapture -l <número da janela>`, e o número
# vem do registro do próprio app (`janela: … [n=…]`). Na janela só há o que este roteiro gerou: os
# roteiros sintéticos, o PIN da bancada e o endereço. Sem número de janela, não captura.
#
# ## O que ele não toca
#
# Não instala nada em `~/Applications` (`QUALL_DESTINO=` vazio) e não usa a pasta de dados do
# usuário: `--dados=` põe `device_id`, pares e roteiro salvo dentro de `$SAIDA`.
#
# Uso:
#   apps/macos/Bancada/provar-teleprompter.sh              # A e B
#   apps/macos/Bancada/provar-teleprompter.sh --so a       # só a metade A (ou b)
#   QUALL_SAIDA=/caminho apps/macos/Bancada/provar-teleprompter.sh --sem-empacotar

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$AQUI/.." && pwd)"
RAIZ="$(cd "$MACOS/../.." && pwd)"
SAIDA="${QUALL_SAIDA:-/tmp/quall-prova-teleprompter}"
APP="$MACOS/.build/Quall.app"
SONDA="$RAIZ/target/release/quall-probe"

SO=ab
EMPACOTAR=1
PORTA_A=17979
PORTA_B=17980
PIN_A=424242
PIN_B=525252

while [ $# -gt 0 ]; do
    case "$1" in
        --so) SO="$2"; shift 2 ;;
        --sem-empacotar) EMPACOTAR=0; shift ;;
        --porta-a) PORTA_A="$2"; shift 2 ;;
        --porta-b) PORTA_B="$2"; shift 2 ;;
        *) echo "argumento desconhecido: $1"; exit 2 ;;
    esac
done

case "$SAIDA" in /*) ;; *) echo "QUALL_SAIDA precisa ser caminho absoluto (sob open o diretório é /)"; exit 2 ;; esac
mkdir -p "$SAIDA"

# `pgrep` com colchete: o padrão não acha a própria linha de comando.
if pgrep -f "MacOS/quall-ap[p]" >/dev/null; then
    echo "!! já há um quall-app rodando — este roteiro não mexe em app aberto. Feche e rode de novo."
    exit 1
fi

echo "==> 1. o núcleo e a sonda"
if [ ! -f "$RAIZ/target/release/libquall.a" ] || [ ! -x "$SONDA" ]; then
    (cd "$RAIZ" && MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_PROFILE_RELEASE_LTO=false \
        cargo build --release -p quall-ffi -p quall-probe) || exit 1
fi

if [ "$EMPACOTAR" = 1 ]; then
    echo "==> 2. o app (sem instalar em ~/Applications)"
    QUALL_DESTINO= "$MACOS/Empacotar/empacotar-dev.sh" > "$SAIDA/empacotar.log" 2>&1 || {
        echo "!! empacotar falhou — ver $SAIDA/empacotar.log"; exit 1; }
fi
[ -x "$APP/Contents/MacOS/quall-app" ] || { echo "!! $APP não existe"; exit 1; }

# Um roteiro sintético, com acento e emoji, de ~$2 bytes.
roteiro() {
    local rotulo="$1" bytes="$2" arquivo="$3" i=0
    : > "$arquivo"
    while [ "$(wc -c < "$arquivo")" -lt "$bytes" ]; do
        for _ in $(seq 1 50); do
            printf '%s linha %d: boa noite, ação e emoção no teleprompter. 🎬\n' "$rotulo" "$i" >> "$arquivo"
            i=$((i + 1))
        done
    done
}

# Espera uma linha no registro, por até N segundos. Imprime a linha.
esperar_linha() {
    local arquivo="$1" padrao="$2" segundos="$3" fim=$((SECONDS + $3))
    while [ $SECONDS -lt $fim ]; do
        if [ -f "$arquivo" ] && grep -q -- "$padrao" "$arquivo"; then
            grep -- "$padrao" "$arquivo" | tail -1
            return 0
        fi
        sleep 0.2
    done
    echo "(não apareceu em ${segundos}s: $padrao)"
    return 1
}

# O número da janela principal do app, do registro dele (a linha sai meio segundo depois do arranque).
janela_principal() {
    esperar_linha "$1" "janela: ordenada" 10 >/dev/null
    grep "janela: ordenada" "$1" | head -1 | grep -o "n=[0-9]*" | head -1 | cut -d= -f2
}

# A folha do editor: a janela **visível** do inventário que não é a principal (o processo também
# tem janelas internas, invisíveis, que não servem de testemunha).
janela_da_folha() {
    grep "janela: editor aberto" "$1" | tail -1 | grep -o "\[n=[0-9]* [0-9x]* visivel=sim" \
        | grep -o "n=[0-9]*" | cut -d= -f2 | grep -v "^$2$" | head -1
}

capturar() {
    local numero="$1" destino="$2"
    if [ -z "$numero" ]; then
        echo "   (sem número de janela — não capturo; sem confirmação visual para $destino)"
        return
    fi
    screencapture -o -x -l "$numero" "$destino" && echo "   janela $numero → $destino"
}

assercao() {
    local l
    l="$(pmset -g assertions | grep "Quall: teleprompter" | head -1)"
    echo "${l:-(nenhuma asserção do Quall)}"
}

# ================================================================================================
if [[ "$SO" == *a* ]]; then
    A="$SAIDA/a"
    rm -rf "$A"; mkdir -p "$A/dados"
    roteiro "Prompter" 60000 "$A/roteiro-prompter.txt"
    APPLOG="$A/prompter.log"
    SEGREDOS="$A/sonda-segredos.json"

    echo "==> A. o prompter do app ($PORTA_A, PIN $PIN_A) e a quall-probe como controle"
    open -n -W -a "$APP" --args \
        --registro="$APPLOG" --teleprompter=prompter --pin="$PIN_A" --porta="$PORTA_A" --sem-mdns \
        --dados="$A/dados" --sair-apos=48 --teleprompter-texto="$A/roteiro-prompter.txt" \
        --teleprompter-acoes="0.5:editor=abrir,0.8:rascunho+=Rascunho do prompter: esta linha foi digitada aqui.,3.5:editor=manter-meu,3.8:editor=confirmar,4.1:fonte=64,4.4:espelho=1,4.7:margem=0.15,5:linha=0.4" \
        > "$A/open.log" 2>&1 &
    ABERTO=$!

    esperar_linha "$APPLOG" "prompter: esperando o controle" 20 || { wait $ABERTO; exit 1; }
    JANELA="$(janela_principal "$APPLOG")"
    echo "   janela principal: ${JANELA:-?}"
    echo "   asserção com o prompter aberto: $(assercao)"

    # O controle entra depois de o editor abrir e o rascunho mudar (0,5 e 0,8 s): o roteiro dele
    # chega com o editor aberto e alterado — é o caso do conflito.
    sleep 1.5
    echo "--- A1. controle com PIN, roteiro de 100 000 bytes e 20 edições"
    "$SONDA" controle --ip "127.0.0.1:$PORTA_A" --pin "$PIN_A" --carga 100000 --id sonda-controle \
        --segredos "$SEGREDOS" > "$A/sonda-1.log" 2>&1 &
    S1=$!
    esperar_linha "$APPLOG" "conflito=true" 8
    sleep 0.3
    capturar "$(janela_da_folha "$APPLOG" "$JANELA")" "$A/janela-editor-conflito.png"
    wait $S1; echo "   sonda 1 saiu: exit=$?"

    echo "--- A2. o controle saiu: o prompter segue rolando, com o aviso"
    esperar_linha "$APPLOG" "aviso de controle sumido: LIGADO" 8
    sleep 1.5
    capturar "$JANELA" "$A/janela-queda-espelhada.png"
    sleep 7

    echo "--- A3. o controle volta sem PIN (par lembrado), na mesma porta"
    "$SONDA" controle --ip "127.0.0.1:$PORTA_A" --carga 100000 --id sonda-controle \
        --segredos "$SEGREDOS" > "$A/sonda-2.log" 2>&1
    echo "   sonda 2 saiu: exit=$?"
    sleep 2

    echo "--- A4. PIN errado: o prompter troca o PIN"
    "$SONDA" controle --ip "127.0.0.1:$PORTA_A" --pin 000000 --carga 100000 --id sonda-intrusa \
        > "$A/sonda-3.log" 2>&1
    echo "   sonda 3 saiu: exit=$? ($(grep -o "erro \[[A-Z_]*\]" "$A/sonda-3.log" | head -1))"
    LINHA="$(esperar_linha "$APPLOG" "esperando (tentativa [0-9]*) pin=" 6)"
    PIN_NOVO="$(echo "$LINHA" | grep -o "pin=[0-9]*" | tail -1 | cut -d= -f2)"
    echo "   PIN novo: ${PIN_NOVO:-?}"

    echo "--- A5. um controle entra com o PIN novo; um segundo, junto, ouve BUSY"
    "$SONDA" controle --ip "127.0.0.1:$PORTA_A" --pin "$PIN_NOVO" --carga 100000 --id sonda-controle-4 \
        > "$A/sonda-4.log" 2>&1 &
    S4=$!
    sleep 1.5
    "$SONDA" controle --ip "127.0.0.1:$PORTA_A" --pin "$PIN_NOVO" --carga 100000 --id sonda-controle-5 \
        > "$A/sonda-5.log" 2>&1
    echo "   sonda 5 saiu: exit=$? ($(grep -o "erro \[[A-Z_]*\]" "$A/sonda-5.log" | head -1))"
    wait $S4; echo "   sonda 4 saiu: exit=$?"

    wait $ABERTO
    echo "   app saiu: exit=$?"
    echo "   asserção depois de o app sair: $(assercao)"
fi

# ================================================================================================
if [[ "$SO" == *b* ]]; then
    B="$SAIDA/b"
    rm -rf "$B"; mkdir -p "$B/dados"
    roteiro "Controle" 80000 "$B/roteiro-controle.txt"
    APPLOG="$B/controle.log"
    SEGREDOS="$B/sonda-prompter-segredos.json"

    echo "==> B. o controle do app e a quall-probe como prompter ($PORTA_B, PIN $PIN_B)"
    "$RAIZ/target/release/quall-probe" teleprompter --pin "$PIN_B" --porta "$PORTA_B" --segundos 16 --sem-mdns \
        --id sonda-prompter --segredos "$SEGREDOS" > "$B/sonda-prompter-1.log" 2>&1 &
    P1=$!
    sleep 1
    open -n -W -a "$APP" --args \
        --registro="$APPLOG" --teleprompter=controle --prompter="127.0.0.1:$PORTA_B" --pin="$PIN_B" \
        --dados="$B/dados" --sair-apos=45 \
        --teleprompter-acoes="2:texto=@$B/roteiro-controle.txt,2.5:velocidade=2,3:rolando=1,4:pular=0.1,5:espelho=1,6:fonte=72,7:salto=0,8:pular=0.05,8.2:pular=0.05" \
        > "$B/open.log" 2>&1 &
    ABERTO=$!

    esperar_linha "$APPLOG" "teleprompter: conectou" 20
    JANELA="$(janela_principal "$APPLOG")"
    sleep 9
    capturar "$JANELA" "$B/janela-controle.png"
    wait $P1; echo "   sonda-prompter 1 saiu: exit=$?"

    echo "--- B2. o prompter caiu: o controle mostra a conexão perdida e tenta de novo"
    esperar_linha "$APPLOG" "a sessão acabou" 10
    sleep 2
    capturar "$JANELA" "$B/janela-controle-queda.png"
    sleep 3

    echo "--- B3. o prompter volta na mesma porta: o controle entra de novo, sem PIN"
    "$RAIZ/target/release/quall-probe" teleprompter --pin "$PIN_B" --porta "$PORTA_B" --segundos 12 --sem-mdns \
        --id sonda-prompter --segredos "$SEGREDOS" > "$B/sonda-prompter-2.log" 2>&1
    echo "   sonda-prompter 2 saiu: exit=$?"

    wait $ABERTO
    echo "   app saiu: exit=$?"
fi

echo
echo "==> registros em $SAIDA"
