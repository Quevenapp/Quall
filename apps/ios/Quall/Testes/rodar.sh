#!/bin/zsh
# Testes do emissor que rodam no MacBook, sem aparelho e sem toque humano.
#
# Custam poucos segundos e já pegaram três defeitos que teriam custado corrida:
#   * a subtração de `UInt64` que matou a corrida de 464 s do degrau 4 — uma função pura de duas
#     entradas, que só aparecia depois de dez minutos de transmissão e de um toque humano;
#   * a faixa de cor completa que passou pela primeira corrida do produto sem ninguém notar,
#     porque "o vídeo funciona" — só que lavado ou esmagado no receptor;
#   * a **faixa de cor que só muda de rótulo** (2026-08-23): o caminho que o emissor de tela usa
#     etiqueta o fluxo como limitado sem comprimir os valores. Ver a seção do mecanismo adiante.
#
# Compila **só** o que é puro mais o encoder: nada de App Group, ReplayKit ou núcleo. Os arquivos
# de `Testes/` não entram em alvo nenhum do app — separação por lista de fontes, não por bandeira.
#
# ## Três testemunhas, e nenhuma é o programa que produziu o fluxo
#
#   * `ffprobe` — lê o rótulo declarado (`color_range`, `pix_fmt`);
#   * `confere-h264.py` — lê o **bitstream**: o `video_full_range_flag` do VUI, a dimensão do SPS,
#     e se cada IDR leva SPS/PPS na mesma unidade de acesso. Essa última pergunta o `ffprobe` não
#     responde, e ela é a que decide se quem entra no meio da sessão vê imagem;
#   * `signalstats` — decodifica e mede a **luma de verdade**. É a única que pega o caso em que o
#     rótulo diz limitado e os valores são completos, que é o defeito medido no emissor de tela.
#
# ## Controles negativos
#
# Três fluxos são gerados **errados de propósito**, e o roteiro exige que o veredito os REPROVE.
# Um validador que só aprova não prova nada: pode estar certo, ou pode estar quebrado.

set -u
AQUI=${0:A:h}
COMUM="$AQUI/../Comum"
RECEBER="$AQUI/../Receber"
TMP=$(mktemp -d)
BIN="$TMP/testes"
CONFERE="$AQUI/confere-h264.py"

# `Enderecos.swift` entrou em 01/09/2026, com a classificação que destravou o cabo. Ele fala com o
# sistema em `ipv4()` (`getifaddrs`), e é justamente por isso que a **decisão** foi tirada de dentro
# dela: `classificar`, `escolher`, `destaque` e `notaDoEnlace` são funções puras de texto, e o que
# elas respondem não depende do que estiver plugado neste MacBook enquanto o teste roda.
#
# `Fluidez.swift` é o primeiro arquivo de `Receber/` a entrar aqui, e entra pela mesma porta: ele
# **não lê relógio nenhum** — recebe o instante de quem o tem, que é o `Exibidor`. Por isso a
# distribuição inteira (o buraco de 226 ms, o corte do tranco, a porta de congelamento, o teto de
# amostras) é exercitável no MacBook, sem aparelho e sem toque humano. Vem junto o `Medidas.swift`
# porque é dele a subtração guardada de `UInt64` — a conta cuja versão sem guarda matou a corrida
# de 464 s do degrau 4, e que este arquivo não vai reescrever por conta própria.
#
# As três contas puras do teleprompter (F6b) entram pela mesma porta: `NomeDaInstancia` (o alias
# mDNS efêmero v3, sem identidade pessoal), `LinkDePareamento` (o endereço digitado) e `GeometriaDoRoteiro` (a
# posição do contrato em pontos). Nenhuma fala com sistema, núcleo ou UIKit. Em 14/09 vieram mais
# duas, do tranco do layout: `LinhasDoRoteiro` (no mesmo arquivo da geometria: o ponto de leitura
# que sobrevive ao layout novo) e `MedidorDoRoteiro` (os quadros perdidos pelo relógio da tela).
#
# `DiagnosticoDeMesa.swift` entrou em 13/09/2026: o `CodificadorH264.swift` passou a chamar
# `Diagnostico.nota`/`falha` (commit 4f00725) e este roteiro não acompanhou — ele parou de compilar
# ("cannot find 'Diagnostico' in scope") e ninguém viu, porque o portão não o roda. O
# `Comum/Diagnostico.swift` de verdade não compila no MacBook (`os_proc_available_memory` é só do
# iOS); o de mesa tem só as duas funções que o codificador chama.
#
# O R9 (`docs/controles-de-camera.md` §3, 01/10/2026) entra pela mesma porta: `RegrasDosControles`
# (as escalas, o registro e o JSON, o corte que evita a `NSRangeException`, os textos de quem limita
# e a divergência) não importa AVFoundation; `MediaDeLuma` só lê um `CVPixelBuffer`, e é cronometrada
# aqui antes de virar prova no aparelho. Os testes estão em `TestesDosControles.swift`.
#
# O R9b (`docs/controle-remoto-da-camera.md`, 02/10/2026) entra pela mesma porta:
# `RegrasDoControleRemoto` (o molde do painel, local e remoto; as capacidades do iOS no fio; o pedido
# aplicado na ordem do §6; o pedido parcial; o estado do receptor; o ponto do toque) não fala com a
# fronteira C nem com a câmera. Os testes estão em `TestesDoControleRemoto.swift`.
TELEPROMPTER="$AQUI/../Teleprompter"
swiftc -O \
  "$COMUM/Carimbo.swift" \
  "$COMUM/Idioma.swift" \
  "$COMUM/SanitizacaoDoLog.swift" \
  "$AQUI/DiagnosticoDeMesa.swift" \
  "$COMUM/CodificadorH264.swift" \
  "$COMUM/Enderecos.swift" \
  "$COMUM/RemendoDeSPS.swift" \
  "$COMUM/NomeDaInstancia.swift" \
  "$COMUM/TetosDoCardapio.swift" \
  "$RECEBER/Medidas.swift" \
  "$RECEBER/Fluidez.swift" \
  "$TELEPROMPTER/LinkDePareamento.swift" \
  "$TELEPROMPTER/GeometriaDoRoteiro.swift" \
  "$TELEPROMPTER/MedidorDoRoteiro.swift" \
  "$TELEPROMPTER/RegraDaFonteAutomatica.swift" \
  "$TELEPROMPTER/DedosNosBotoes.swift" \
  "$TELEPROMPTER/PerguntaDoTexto.swift" \
  "$TELEPROMPTER/DivisaoDaTelaComCamera.swift" \
  "$TELEPROMPTER/ZonaDaBordaDaDivisao.swift" \
  "$TELEPROMPTER/FechoDaTela.swift" \
  "$TELEPROMPTER/RepeticaoDoBotao.swift" \
  "$AQUI/../App/EscolhaDaMelhorImagem.swift" \
  "$AQUI/../App/SolturaDaPorta.swift" \
  "$AQUI/../App/PoliticaDeCalor.swift" \
  "$AQUI/../App/RegrasDosControles.swift" \
  "$AQUI/../App/MediaDeLuma.swift" \
  "$AQUI/../App/RegrasDoControleRemoto.swift" \
  "$AQUI/TestesDosControles.swift" \
  "$AQUI/TestesDoControleRemoto.swift" \
  "$AQUI/TestesDaTraducao.swift" \
  "$AQUI/main.swift" \
  -o "$BIN" || { echo "!! não compilou"; exit 1; }

"$BIN" "$TMP"
FALHAS=$?

# A tradução PT/EN (`docs/traducao.md`, seção iOS): paridade das chaves `tr("…")` com as tabelas
# `en.lproj`, placeholders, chaves órfãs, texto de interface ainda literal e os `InfoPlist.strings`.
echo ""
echo "confere-traducao.py"
python3 "$AQUI/confere-traducao.py" "$AQUI/.." || FALHAS=$((FALHAS + 1))

for FERRAMENTA in ffprobe python3; do
  command -v "$FERRAMENTA" > /dev/null || {
    echo "  FALHA $FERRAMENTA não encontrado — sem conferência externa"
    rm -rf "$TMP"; exit $((FALHAS + 1)); }
done

# ---------------------------------------------------------------------------------------------
# A luma de verdade, decodificada. A entrada é pintada nos extremos LEGAIS do formato de entrada
# (0 e 255 para 420f; 16 e 235 para 420v), então um fluxo genuinamente limitado sai dentro de
# 16–235 e um fluxo completo sai fora. É isto que distingue "converteu" de "só etiquetou".
# ---------------------------------------------------------------------------------------------
# `YLOW`/`YHIGH` (percentis 10 e 90), e **não** `YMIN`/`YMAX`.
#
# Os extremos absolutos não servem: o H.264 é com perda, e uma aresta dura de 16 para 235 produz
# oscilação de codificação que estoura os dois lados em alguns valores. Medido aqui: o fluxo de
# 420v legítimo dá YMIN/YMAX de 13–238, contra 16–235 na entrada. Um limiar apertado o
# reprovaria; um limiar frouxo o bastante para aprová-lo também aprovaria o fluxo completo com
# reescala, que dá 6–245. Os dois casos ficariam separados por três unidades de ruído.
#
# Os percentis não têm esse problema: a oscilação vive nos poucos pixels da borda, e o corpo da
# imagem fica onde foi pintado. Limitado dá ~16 e ~235; completo dá ~0 e ~255.
luma() {
  ffprobe -v error -f lavfi -i "movie=$1,signalstats" \
    -show_entries frame_tags=lavfi.signalstats.YLOW,lavfi.signalstats.YHIGH \
    -of csv=p=0 2>/dev/null | awk -F, '
      NR == 1 { baixo = $1; alto = $2 }
      { if ($1 < baixo) baixo = $1; if ($2 > alto) alto = $2 }
      END { if (NR == 0) print "?,?"; else print baixo "," alto }'
}

rotulo() {
  ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,color_range \
    -of csv=p=0 "$1" 2>/dev/null | tr -d ' \n'
}

# ---------------------------------------------------------------------------------------------
# Um fluxo que o produto entrega: precisa passar nas três ferramentas.
# ---------------------------------------------------------------------------------------------
aprovar_fluxo() {
  ARQ="$TMP/$1"
  echo ""
  echo "$1 — precisa PASSAR"
  if [ ! -s "$ARQ" ]; then
    echo "  FALHA o fluxo não foi escrito"; FALHAS=$((FALHAS + 1)); return
  fi

  FICHA=$(rotulo "$ARQ")
  case "$FICHA" in
    yuv420p,tv) echo "  ok   ffprobe: $FICHA" ;;
    *)          echo "  FALHA ffprobe: $FICHA — esperado yuv420p,tv (limitada e declarada)"
                FALHAS=$((FALHAS + 1)) ;;
  esac

  # `--minimo-idr 2` porque o que decide se quem entra no meio vê imagem é o **segundo** IDR em
  # diante. Um fluxo com um IDR só não exercita a pergunta.
  if python3 "$CONFERE" "$ARQ" --minimo-idr 2; then
    echo "  ok   bitstream aprovado"
  else
    echo "  FALHA o veredito do bitstream reprovou um fluxo do produto"
    FALHAS=$((FALHAS + 1))
  fi

  L=$(luma "$ARQ")
  BAIXO=${L%%,*}; ALTO=${L##*,}
  if [ "$BAIXO" -ge 12 ] 2>/dev/null && [ "$ALTO" -le 240 ] 2>/dev/null; then
    echo "  ok   luma de verdade em $BAIXO–$ALTO: o conteúdo é mesmo limitado, não só etiquetado"
  else
    echo "  FALHA luma de verdade em $BAIXO–$ALTO, fora dos 16–235 legais. O fluxo DECLARA faixa"
    echo "        limitada e carrega valores completos: um receptor que honre o VUI vai expandir"
    echo "        16–235 para 0–255 e esmagar pretos e estourar brancos."
    FALHAS=$((FALHAS + 1))
  fi
}

# ---------------------------------------------------------------------------------------------
# Um controle negativo: precisa ser REPROVADO. Se ele passar, o veredito não sabe reprovar — e um
# veredito que não sabe reprovar é pior que nenhum, porque dá confiança.
# ---------------------------------------------------------------------------------------------
#   reprovar_fluxo <arquivo> <o que está errado> <trecho que o veredito precisa dizer>
#
# O terceiro argumento não é enfeite. Um controle que reprova **pelo motivo errado** não prova
# nada sobre o defeito que ele existe para exercitar — e isso aconteceu aqui: o controle de faixa
# de cor foi gerado com poucos quadros, reprovou por "tem 1 IDR, mínimo 2", e passou por controle
# bom sem nunca ter exercitado a faixa de cor.
reprovar_fluxo() {
  ARQ="$TMP/$1"
  echo ""
  echo "$1 — precisa SER REPROVADO ($2)"
  if [ ! -s "$ARQ" ]; then
    echo "  FALHA o controle não foi escrito"; FALHAS=$((FALHAS + 1)); return
  fi
  if python3 "$CONFERE" "$ARQ" --minimo-idr 2 > "$TMP/veredito.txt" 2>&1; then
    echo "  FALHA o veredito APROVOU um fluxo errado — ele não sabe pegar este defeito:"
    sed 's/^/       /' "$TMP/veredito.txt"
    FALHAS=$((FALHAS + 1))
    return
  fi
  grep '✗' "$TMP/veredito.txt" | sed 's/^  /  ok   reprovou: /'
  if ! grep -q "$3" "$TMP/veredito.txt"; then
    echo "  FALHA reprovou, mas não pelo motivo que este controle exercita ($3)"
    FALHAS=$((FALHAS + 1))
  fi
}

# O que a câmera passa a entregar, e o que a tela já entrega.
aprovar_fluxo "camera-420v.h264"
aprovar_fluxo "tela-como-esta-hoje.h264"
# A tela do iPhone X: 590x1280, o primeiro fluxo desta bancada com `frame_cropping` no SPS.
# Ver o comentário longo em `main.swift`. Se o remendo se perder no corte, é aqui que aparece —
# no MacBook, e não depois do toque humano no aparelho.
aprovar_fluxo "tela-iphone-x.h264"

# ---------------------------------------------------------------------------------------------
# O mecanismo da faixa de cor, medido em vez de suposto.
#
# `imageBufferAttributes` do `VTCompressionSessionCreate` foi registrado neste projeto como a
# alavanca que "faz a sessão de transferência converter a faixa no mesmo passo do
# reescalonamento". Ele converte mesmo — a parte que faltava é o **"no mesmo passo"**: a sessão de
# transferência só existe quando há o que transferir. Sem mudança de dimensão, o buffer vai cru
# para o encoder e a faixa sai a do formato de entrada.
#
# As três primeiras linhas são o mesmo encoder, a mesma declaração, e a única diferença é a
# reescala. A quarta é o caminho da câmera, que não depende disso.
#
# Isso importa porque a câmera cai **exatamente** no caso sem reescala: `.hd1280x720` com
# orientação em pé entrega 720x1280, que é a dimensão de saída.
# ---------------------------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo " matriz do mecanismo — entrada 420f (o que o ReplayKit entrega)"
echo "=========================================================================="
printf "  %-9s %-4s %-9s %-14s %s\n" "imgBufAttr" "cor" "reescala" "rótulo" "luma P10–P90"
for F in $(ls "$TMP" | grep '^matriz-' | sort); do
  N=${F%.h264}
  E=$(echo "$N" | sed 's/.*entrada\([01]\).*/\1/')
  C=$(echo "$N" | sed 's/.*cor\([01]\).*/\1/')
  R=$(echo "$N" | sed 's/.*reescala\([01]\).*/\1/')
  printf "  %-10s %-4s %-9s %-14s %s\n" \
    "$([ "$E" = 1 ] && echo sim || echo não)" \
    "$([ "$C" = 1 ] && echo sim || echo não)" \
    "$([ "$R" = 1 ] && echo sim || echo não)" \
    "$(rotulo "$TMP/$F")" "$(luma "$TMP/$F")"
done
printf "  %-10s %-4s %-9s %-14s %s\n" "—" "—" "420v" \
  "$(rotulo "$TMP/camera-420v.h264")" "$(luma "$TMP/camera-420v.h264")"
echo ""
echo "  Leitura, das oito células:"
echo "   1. imageBufferAttributes CONVERTE de verdade — a luma vai a 16–236, não é só rótulo;"
echo "   2. mas só quando há RESCALA: sem mudança de dimensão a chave é ignorada e o fluxo sai"
echo "      completo, e é aí que a câmera cairia (720x1280 entra, 720x1280 sai);"
echo "   3. as três chaves de cor NÃO mexem na faixa — decidem se o VUI é escrito, ou seja se o"
echo "      color_range sai 'tv' ou 'unknown'. É a ressalva que contrato-sidecar.md deixou aberta;"
echo "   4. a entrada 420v (última linha) não depende de nenhuma das colunas."

# Toda célula sem reescala com entrada 420f precisa ser reprovada: é o caso em que a câmera cairia
# se dependesse do encoder para a faixa de cor.
for F in matriz-entrada1-cor1-reescala0 matriz-entrada1-cor0-reescala0 \
         matriz-entrada0-cor1-reescala0 matriz-entrada0-cor0-reescala0; do
  reprovar_fluxo "$F.h264" "420f sem reescala — onde a câmera cairia" "faixa de cor"
done
reprovar_fluxo "controle-fora-do-teto.h264" "dimensão fora do teto de 1080x1920" "passa do teto"
reprovar_fluxo "controle-sem-parametros.h264" "IDR sem SPS/PPS" "SEM SPS/PPS"

echo ""
if [ "$FALHAS" -eq 0 ]; then
  echo "todos os testes do MacBook passaram"
else
  echo "$FALHAS teste(s) falharam"
fi
rm -rf "$TMP"
exit "$FALHAS"
