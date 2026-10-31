# Plugin OBS do Quall Studio — Windows e macOS

Auditoria de distribuição em 05/10/2026: [compatibilidade OBS](../../docs/distribuicao/obs-compatibilidade.md).
Os resultados históricos abaixo não substituem testes do pacote final. OBS/câmera virtual seguem
no produto; a exclusão aprovada da primeira versão é Monitor/Tela estendida, crop e video wall.

Fonte nativa de OBS que **embute o receptor do Quall**: `obs_register_source`, quadros por
`obs_source_output_video()` em modo assíncrono, lista de aparelhos descobertos no painel de
propriedades, cada aparelho como fonte independente. Marco: **M5**.

É este consumidor que proíbe libwebrtc e obriga `libdatachannel` — o receptor inteiro precisa caber
embutido no plugin. **Cabe nos dois:** **10,3 MiB** no macOS (`RelWithDebInfo`, arm64) e **14,65 MiB**
no Windows (x64), com núcleo, libdatachannel, OpenSSL, libsrtp, libjuice e usrsctp dentro e nenhuma
dependência dinâmica além do OBS e do sistema.

Esta pasta está reservada para esta frente. Só o orquestrador integra e commita no tronco.

## Licença e distribuição

O código próprio do plugin é **GPL-3.0-or-later**: GPL versão 3 ou, a seu critério, qualquer
versão posterior. [LICENSE](LICENSE) contém o GPLv3 integral e
[LICENSE-SCOPE.md](LICENSE-SCOPE.md) define a opção or-later e o escopo da combinação.

A combinação do plugin com libobs e o núcleo estático é distribuída sob GPL-3.0-or-later.
O código próprio do núcleo mantém MPL-2.0 como padrão e, nessa combinação, é disponibilizado
adicionalmente sob GPL nos termos da seção 3.3 da MPL. As licenças e atribuições dos componentes
de terceiros permanecem aplicáveis; `.libobs/` é upstream e não recebe a licença própria.
A identificação de Veneri & Quellis Ltda. como responsável não presume cessão de direitos.

Os próximos candidatos devem carregar `LICENSE`, `LICENSE-SCOPE.md`, `LICENSE-MPL-2.0.txt`
e `THIRD_PARTY_NOTICES.txt`: `Contents/Resources/` no bundle macOS ou `build/data/` junto ao
plugin Windows. A configuração/build exige documentos presentes e não vazios; os scripts
conferem a identidade das cópias antes de instalar. Artefatos anteriores permanecem históricos
e não foram reconstruídos por essa mudança. Distribuir exige também disponibilizar o fonte
correspondente de todo o código incorporado e dos scripts/configurações necessários.

## Estado

| | |
|---|---|
| **macOS** | **provado** — ver `docs/bancada.md`. Compila, carrega no OBS 32.2.2, recebe vídeo de aparelho físico e publica no compositor |
| **Windows** | **compila e roda no OBS 32.2.1 do Dell G3.** Três fontes simultâneas, quadro publicado, `Number of memory leaks: 0`. O emissor foi **sonda local e o MacBook pela rede — não houve aparelho** |
| **Áudio** | **implementado**: `som.c` adota o codec negociado Opus/PCMU, publica em `obs_source_output_audio()`; microfone e áudio do sistema, inclusive sessão só de som. A prova atual do pacote final ainda está pendente |
| **Vazamento** | **fechado.** A ponte por sessão virou `bfree`; quem autoriza é o `QuallStatus` da barreira, não um relógio |

## Instalar (quem usa)

Instaladores em `instalador/` (ver [LEIA.md](instalador/LEIA.md)):

- **Windows**: `QuallOBS-<versão>-x64.msi`. Feche o OBS, rode o MSI (pede UAC), abra o OBS. Instala
  em `C:\ProgramData\obs-studio\plugins\quall-obs\`, para todos os usuários; atualiza por cima;
  desinstala por "Aplicativos instalados". Exige OBS 64 bits na versão dos cabeçalhos ou mais nova.
- **macOS**: `QuallOBS-<versão>-macos-arm64.pkg`, assinado e notarizado. Feche o OBS, abra o pacote
  e escolha "Instalar só para mim". Instala em
  `~/Library/Application Support/obs-studio/plugins/quall-obs.plugin`.

O ZIP com cópia à mão continua valendo (o `README.txt` de dentro).

## Compilar e instalar

    ./construir.sh     # macOS
    ./construir.ps1    # Windows

Para compilar sem instalar no macOS, use `./construir.sh --sem-instalar`; no Windows,
`./construir.ps1 -SemInstalar`. Os scripts recompilam o núcleo; aguarde a janela de CPU.

Ele: lê a versão do OBS instalado, busca os cabeçalhos do `libobs` **nessa tag**, compila o núcleo
se faltar, roda o CMake e copia o `.plugin` para
`~/Library/Application Support/obs-studio/plugins`.

Três coisas que o script resolve e que não são óbvias:

1. **Compilamos com a tag dos cabeçalhos do OBS instalado.** O carregador rejeita major/minor
   **mais novos** que o host e ignora patch. Um plugin antigo não é recusado só por ter minor menor;
   isso também não garante que todos os seus recursos funcionem. Conferir carga e fluxo.
2. **Os cabeçalhos não vêm no OBS instalado** — `libobs.framework` traz a biblioteca e zero `.h`. O
   `obs-plugintemplate` resolveria baixando um `libobs` pré-compilado das releases, que pode não ser
   o OBS da máquina. `buscar-libobs.sh` faz *sparse checkout* de `libobs/` na tag certa.
3. **O `simde` não é opcional.** `libobs/util/sse-intrin.h` inclui `<simde/x86/sse2.h>` no arm64, e
   ele chega a qualquer arquivo que inclua `obs.h`, por `vec4.h`. No build do OBS ele vem do pacote
   `obs-deps`; aqui vem do repositório dele, também em tag fixa.

## Compilar e instalar (Windows)

    powershell -NoProfile -ExecutionPolicy Bypass -File .\construir.ps1

Mesma regra de fundo do macOS — **o alvo é o OBS instalado nesta máquina** —, com três coisas que
só existem aqui:

1. **O OBS instalado não traz `obs.lib`.** No macOS dá para linkar direto contra a biblioteca de
   dentro do `OBS.app`. No Windows o linker precisa da biblioteca de **importação**, e o caminho
   oficial para tê-la é compilar o libobs inteiro. `construir.ps1` a gera da própria `obs.dll`
   instalada, por `dumpbin /exports` → `.def` → `lib /def` (1.784 símbolos). O mesmo para
   `w32-pthreads.lib` (120), que o `util/threading.h` exige.
2. **`libobs/util/threading.h` inclui `<pthread.h>` sem condição**, e no MSVC esse cabeçalho é o do
   `deps/w32-pthreads/` do próprio obs-studio. `buscar-libobs.ps1` traz `libobs/` **e** ele.
3. **A pasta de plugins de usuário é `%ProgramData%`, não `%APPDATA%`.** Ver a lista de armadilhas.

### O decodificador de Windows não usa hardware, e o argumento está medido

`integrations/camera-windows` mediu o *Microsoft H264 Video Decoder MFT* neste mesmo Dell com um
`IMFDXGIDeviceManager` registrado: **decode p50 de 4,63 ms**, saída em **textura D3D11**. Aquele
consumidor entrega pixel a um `VideoProcessorBlt` e a um cano — o caminho inteiro é do lado da GPU.

Aqui o consumidor é outro. `obs_source_output_video()` de uma fonte assíncrona lê
`data[]`/`linesize[]` da **CPU**. Pegar textura para depois baixá-la com `CopyResource` + `Map`
acrescentaria uma leitura de volta GPU→CPU de ~1,4 MB por quadro **e** uma sincronização com a GPU
dentro da thread que publica. Então `decodificador-mf.c` **não registra o D3D manager**: pede NV12
em memória de sistema e entrega os dois planos direto ao OBS.

O preço, medido no Dell com o mesmo fluxo de 960x720 do A10s:

| | decode p50 | decode p95 |
|---|---|---|
| uma fonte | 3,5–6,8 ms | 6,4–11,9 ms |
| três fontes simultâneas | 3,4–3,6 ms | 6,2–11,3 ms |

Contra um orçamento de 41,7 ms por quadro a 24 fps. **O que não foi medido é o caminho alternativo**
— MFT em hardware mais leitura de volta —, então esta comparação não é "software ganhou de
hardware": é "software coube, e o outro caminho não foi tentado". A alternativa está escrita no
topo de `src/decodificador-mf.c` para não precisar ser redescoberta.

Dois achados do MFT, medidos e não supostos, no Dell:

- **`MF_LOW_LATENCY` é aceito; `CODECAPI_AVLowLatencyMode` é recusado.** Só um dos dois pega.
- **O decodificador sobe duas vezes por sessão, e está certo.** Ele nasce achando 1920x1080 (não
  declaramos tamanho na entrada — o SPS do Annex-B é que manda) e renegocia para o tamanho real no
  primeiro `MF_E_TRANSFORM_STREAM_CHANGE`. É por isso que o diário mostra `sessão 1` e `sessão 2`.

## A decisão que mais mexeu no desenho: o OBS já tem uma libdatachannel

`OBS.app/Contents/Frameworks/libdatachannel.dylib` existe e exporta **1.159 símbolos `rtc*`**. É a
libdatachannel do próprio OBS, compilada contra mbedTLS, usada pela saída WHIP (`obs-webrtc.plugin`,
que carrega no mesmo processo). O nosso núcleo linka **outra**, estática, compilada contra OpenSSL.

O risco não é o símbolo `rtc*` disputado — o dyld do macOS é de dois níveis e cada binário casa com
a biblioteca de onde importou. O risco é a **coalescência de `weak definition`** do C++: `typeinfo`,
instanciações de template, `operator new`/`delete` de classe. Essas o dyld resolve **por processo**,
escolhendo uma definição para todo mundo. Duas versões da mesma classe `rtc::` com layouts
diferentes, e quem escolhe é a ordem de carga.

Conserto: `-Wl,-exported_symbols_list`, com os **nove** exports OBS implementados (incluindo o lookup de idioma) e mais
nada. `construir.sh` imprime o `nm -gU` no fim, para a lista ser conferida a cada build.

Isto **não foi observado quebrando** — foi evitado por leitura. O que está medido é a existência da
dylib, a contagem de símbolos e o fato de o `obs-webrtc` carregar no mesmo processo.

## Como o plugin está organizado

| Arquivo | O que é |
|---|---|
| `src/plugin.c` | `obs_module_load` / `unload`, gancho de pânico do núcleo |
| `src/fonte.c` | `obs_source_info`, painel de propriedades |
| `src/receptor.c` | uma sessão por fonte: conectar, receber, reconectar, medir |
| `src/descoberta.c` | um navegador mDNS para o módulo inteiro |
| `src/decodificador.h` | a interface: dois planos NV12 e dois passos, sem tipo de plataforma |
| `src/decodificador-vt.c` | macOS: H.264 → NV12 por VideoToolbox |
| `src/decodificador-mf.c` | Windows: H.264 → NV12 por Media Foundation Transform |
| `src/anexob.c` | Annex-B → AVCC, separando SPS/PPS. **Só macOS** — o MFT come Annex-B como veio |
| `src/pares.c` | `pares.json` e a identidade deste OBS |
| `src/medida.c` | percentis sobre as últimas amostras |
| `src/interface-do-cabo.c` | por qual interface o par é alcançado, e o endereço local a prender |
| `src/encaixe.c` | o primeiro tamanho da fonte fica: a imagem de outro tamanho entra encaixada, com faixas (ver abaixo) |
| `src/camera-remota.c` | o grupo "Câmera do aparelho" (R9b): pede ajustes à câmera de quem filma |
| `src/camera-remota-regras.c` | as regras puras dele (degraus, textos de número, limites, recusas, listas do JSON) |
| `bancada/` | roteiros de prova — ver abaixo |

### A troca de tamanho no meio da sessão: a fonte fica no primeiro tamanho

Quando o emissor troca o tamanho da imagem no meio da sessão (a câmera do Windows em 16:9 ↔ 4:3,
por exemplo), a fonte **não muda de tamanho na cena**. Ela publica sempre o primeiro tamanho que
publicou, e uma imagem de outro tamanho entra no maior retângulo com o aspecto dela, centrado, com
faixas pretas (`src/encaixe.c`). Um item de cena com `OBS_BOUNDS_NONE` guarda escala, e não tamanho,
e o enquadramento de quem transmite pularia a cada troca. É a decisão do Bruno de 21/09/2026,
depois do controle da troca de tamanho (`docs/camera-no-windows.md`, M98 e M107).

- **Vale por fonte, e não por sessão de rede.** Uma reconexão com outro tamanho continua encaixada
  no tamanho que a fonte já publicava; o diário diz "a sessão nova nasce publicando …". O tamanho só
  volta a valer de novo quando a pessoa muda com quem a fonte fala (endereço ou PIN) ou a fonte é
  recriada.
- **A imagem é escalada por bilinear**, com as posições e os pesos calculados uma vez por troca; a
  escala 1 é cópia de linha, e o preto só é pintado nas faixas. Medido no Mac
  (`bancada/prova-encaixe.c`): 0,04 ms por quadro quando só há faixas, 0,32 ms de 854×480 para
  640×480, 1,16 ms de 1080p para 720p.
- O diário diz uma linha por troca: "a imagem é 640x480; publicada encaixada, com faixas, em
  854x480, o primeiro tamanho desta fonte". No fim da sessão, quantos quadros saíram encaixados.

### Threads, e por que são essas

- **`quall-descoberta`** (uma por módulo): chama `quall_browser_collect` em laço de 400 ms.
  Ela existe porque `collect` **bloqueia**, e o painel de propriedades roda na thread de interface do
  OBS — uma fonte que coletasse ali congelaria a janela a cada abertura do painel.
- **`quall-receptor`** (uma por fonte): dona da sessão e das tracks do início ao fim. **Toda** chamada
  à fronteira C sai daqui, com as duas exceções que o header autoriza por escrito:
  `quall_session_cancel` (de qualquer thread) e o tratador de quadro.
- **`quall-decode`** (uma por sessão): tira o quadro da fila, decodifica e chama
  `obs_source_output_video()`. Ela é a **única** que publica, e é encerrada e juntada antes de
  `destroy` retornar — que é o que o libobs exige de uma fonte assíncrona.
- **thread da libdatachannel**: entra pelo tratador de quadro, copia os bytes para a fila e sai. O
  header manda não bloquear ali, e decodificar dentro do tratador seguraria a recepção de RTCP da
  sessão inteira.

A fila entre a libdatachannel e o decodificador tem **três lugares** e descarta o mais antigo quando
enche. Vídeo ao vivo não se enfileira para tentar de novo — é o mesmo princípio que o header do
`quall_track_send_frame` escreve do lado do emissor.

### A "ponte", e o vazamento que ela custava — fechado

Ela nasceu de uma dívida: não havia como desregistrar um tratador, e `quall_session_close()` não era
barreira. Um `quall_track_on_frame` que já estava correndo podia ainda estar dentro do nosso código
quando o `close` retornasse, e liberar o `user_data` na linha seguinte era uso-após-liberação. A
saída foi uma `struct ponte` — um mutex e um ponteiro — que **nunca** era liberada. Custo medido:
1 sessão → 1 vazamento.

**A dívida 24 foi paga.** Hoje duas chamadas são barreira, e é o `QuallStatus` delas — não um
relógio — que autoriza o `bfree`:

- `quall_track_on_frame(t, NULL, NULL)` com `QUALL_STATUS_OK`: aquele tratador não está rodando em
  thread nenhuma e não volta a rodar.
- `quall_session_close(s)` com `QUALL_STATUS_OK`: o mesmo, para a sessão inteira.

Basta uma das duas dar OK, porque a única coisa que usa a ponte é `ao_quadro`.

**A ponte não sumiu do código, e isso é deliberado.** Quando o status é `TIMEOUT` (um tratador da
casca não voltou em 2 s) ou `INVALID` (a chamada veio de dentro de um tratador), o header manda não
liberar nada — e é o ponteiro zerado sob o trinco que faz um tratador atrasado não alcançar nada.
Nesse caminho a ponte fica para trás como antes, mas agora é **exceção contada**, com o motivo
escrito no diário sessão a sessão, e `obs_module_unload` diz quantas foram.

**Provado:** três sessões de pé no OBS 32.2.1 do Dell, fechamento limpo, `Number of memory leaks: 0`.

## Painel de propriedades

- **Aparelho** — lista vinda do mDNS (nome — `ip:porta`), mais "Digitar endereço…".
- **Endereço** — o fallback obrigatório do fluxo, visível quando a escolha é manual.
- **PIN** — só no primeiro pareamento. Depois disso `pares.json` responde por ele.
- **Este OBS aparece como** — o nome que o emissor mostra.
- **Latência mínima (sem buffer)** — `obs_source_set_async_unbuffered`, ligado por padrão.
- **Gravar o fluxo recebido** — instrumento de bancada; ver abaixo.
- **Câmera do aparelho** (R9b, `docs/controle-remoto-da-camera.md` §12) — logo abaixo da linha de
  estado, só numa sessão de vídeo cujo filmador responde (`pronto` ou `nao_permitido`). As quatro
  áreas do R9 (Exposição; ISO e obturador, ou Ganho e obturador do Windows; Balanço; Foco), montadas
  a partir das capacidades que chegaram, com "quem limita" em texto, a linha do lido, a recusa por
  3 s e o "Restaurar automático". Com a opção desligada no filmador, os controles ficam apagados com
  os valores e a frase. **Antes de conectar** (e de novo depois de a sessão cair), o grupo aparece
  na prévia: os campos típicos do R9 (`campos_da_previa`, em `camera-remota-regras.c`), cada um um
  combo desabilitado com "—", a frase "Configurar os parâmetros após a conexão" no topo e o
  Restaurar apagado. Nada é escrito no `settings` (o "—" é o padrão da chave `camera.previa.*`),
  nenhum pedido nem `.update` sai; ao conectar, o painel se refaz com o que o filmador declarar. Numa
  sessão de tela (sem filmador) o grupo some, como antes. Três regras que não são estilo, todas em
  `camera-remota.c`:
  - **só de gesto**: o OBS chama os `modified_callback` em toda montagem (`obs_source_properties` →
    `obs_properties_apply_settings`), então o pedido só sai quando o valor difere do que a montagem
    escreveu (o espelho). Um combo leva sempre o valor atual: a view do OBS chama o callback sozinha
    quando o valor não está na lista;
  - **não é salvo**: as chaves `camera.*` saem no `.save` e no `.load`. O Cancelar do diálogo não
    desfaz o que já foi pedido: o pedido é ação ao vivo, como na câmera do próprio aparelho;
  - **o painel se refaz** (`obs_source_update_properties`) quando a situação, as capacidades ou a
    recusa visível mudam, ou quando o ajuste aplicado difere do que a tela mostra — nunca antes de
    1 s depois de um gesto nem de 2 s depois de um `.update` (a pessoa digitando; ver `dizer` em
    `receptor.c`). A linha do lido é um retrato da montagem, como a linha de estado.
  - Fora: o toque na imagem para focar (a fonte não tem `OBS_SOURCE_INTERACTION`, e o quadro é
    encaixado, `encaixe.c`).

O fluxo respeita `docs/fluxo-de-uso.md`: quem espelha anuncia e espera, quem exibe escolhe e conecta.
O OBS é sempre quem **exibe**, então ele sempre chama `quall_connect` — nunca `quall_host`.

## Bancada

    bancada/montar-cena.py montar "A10s=192.168.1.159:7877/438352" [--gravar]
    bancada/gravar.sh 30                 # o OBS grava a cena por 30 s
    swift bancada/extrair-quadro.swift entrada.mp4 saida.png 25
    bancada/montar-cena.py restaurar     # devolve a coleção de cenas do usuário

A câmera do aparelho tem dois bancos de prova sem OBS aberto (o comando de cada um está no
cabeçalho): `bancada/prova-camera-remota.c` (as regras puras, só `cc`) e
`bancada/prova-camera-remota-obs.c`, que sobe a **libobs do OBS.app sem vídeo** e passa pelo mesmo
`obs_source_properties` da janela, contando os pedidos que sairiam (o núcleo é trocado por macro).
Foi ele que achou o `null` do JSON virando `{"kelvin":0}` na montagem: a libobs lê `null` como
objeto nulo, não como `OBS_DATA_NULL`.

**O painel inteiro** tem o dele: `bancada/prova-painel-obs.c` monta as propriedades da fonte com a
libobs, em pt-BR e en-US, e cobra a regra da foto do Dell (13/10): rótulos e botões de até 18
caracteres, a explicação na dica (`long_description`) ou numa linha que quebra, itens da lista
curtos (o alias sem "Quall ", o ip sem a porta de sempre), e os grupos "Conexão" e "Opções" — com a
câmera do aparelho entre os dois. A prova da câmera cobra o mesmo teto nos controles do grupo.

`montar-cena.py` escreve uma coleção de cenas em vez de alguém clicar no painel: a corrida fica
repetível e os ajustes que a fonte recebeu ficam escritos. A coleção do usuário é guardada e devolvida.

**Gravar o fluxo recebido** escreve o par do contrato do sidecar (`docs/contrato-sidecar.md`) na
pasta de configuração do módulo. Ele serve a duas coisas:

1. **Testemunha externa.** `tools/valida-sidecar.py` confere soma de bytes, monotonicidade e a
   contagem de quadros do `ffprobe` contra a do sidecar. Se ele aprova, o que chegou é H.264 coerente
   — não é o nosso contador dizendo que chegou.
2. **Segundo emissor sem segundo aparelho.** O par gravado é entrada de
   `quall-probe emitir-video --entrada … --repetir`, e foi assim que três fontes simultâneas foram
   provadas com um celular só na bancada.

O cabeçalho do sidecar gravado diz a verdade sobre a origem: `capture_api` é
`"quall-obs (recebido pela rede, nao capturado aqui)"` e `encoder_is_hardware` é `false`, porque
**este lado não codificou nada**.

## Bancada (Windows)

    powershell -File bancada\rodar.ps1 -Sondas 3 -Segundos 70 -Gravar -GravarFluxo
    powershell -File bancada\rodar.ps1 -Sondas 0 -Remoto "192.168.1.131:7900/790000" -Segundos 75 -Gravar

`bancada/rodar.ps1` sobe os emissores, monta a coleção com `montar-cena.py`, roda o OBS por Tarefa
Agendada na **sessão interativa**, fecha por `CloseMainWindow()` e devolve tudo — coleção de cenas e
`ConfirmOnExit`. Três diferenças de fundo em relação ao lado macOS:

- **O OBS precisa da sessão interativa.** O OpenSSH Server do Windows entrega a Sessão 0, que tem
  uma área de trabalho própria e headless (ver `docs/windows-acesso.md`).
- **Nada de foto da área de trabalho.** É regra desta bancada, e não é frescura: a frente da câmera
  virtual já capturou conteúdo pessoal do usuário assim. A testemunha visual é a **cena** gravada
  pelo próprio OBS, que só tem fontes do Quall dentro.
- **Fechar limpo é parte da prova.** Matar o `obs64` pula a linha `Number of memory leaks`.

### O que foi medido no Dell G3

OBS Studio 32.2.1, Windows 11 Home 26200, i7-9750H, Wi-Fi. Fluxo de 960x720 Baseline a 24 fps — a
gravação que o próprio plugin fez do Galaxy A10s na rodada do macOS, reproduzida em laço.
**Não houve aparelho nesta rodada**: os emissores foram sondas locais no próprio Dell e o MacBook
pela rede.

| corrida | emissor | quadros | descartes de fila | fps | decode p50 / p95 | rede→pronto p50 / p95 | 1ª imagem | sessão de pé | vazamentos |
|---|---|---|---|---|---|---|---|---|---|
| uma fonte | sonda local | 746 | 0 | 23,74 | 6,77 / 11,92 ms | 6,95 / 12,19 ms | 123 ms | 1086 ms | **0** |
| **três fontes simultâneas** | 3 sondas locais | 1577 / 1578 / 1578 | 0 / 0 / 0 | 23,81 / 23,82 / 23,81 | 3,4–3,6 / 6,2–11,3 ms | 3,6–3,7 / 6,4–11,7 ms | — | — | **0** |
| pela rede | MacBook (cabo, `.131`) → Dell (Wi-Fi, `.41`) | 1693 | 0 | 23,80 | 6,37 / 11,65 ms | 6,57 / 11,94 ms | 97 ms | 1174 ms | **0** |

Binário: **14,65 MiB** (`RelWithDebInfo`, x64), com núcleo, libdatachannel, OpenSSL, libsrtp,
libjuice e usrsctp dentro. Dependências dinâmicas: `obs.dll`, `w32-pthreads.dll`, `MFPlat.DLL` e
bibliotecas do sistema — **nenhuma `datachannel.dll`**, embora o OBS embarque a dele ali do lado.
Exporta **nove** funções, todas `obs_module_*`.

**Testemunhas que não são contadores do próprio plugin:**

- A cena gravada pelo OBS: 71,9 s, 1920x1080, 4313 quadros (`ffprobe`), com a imagem que veio do
  MacBook. No caso das três fontes, um quadro extraído mostra os três painéis lado a lado e **fora
  de fase entre si**.
- `tools/valida-sidecar.py` **aprovou** o par gravado pelo plugin, com `ffprobe` presente.
- `ffprobe` no que chegou: `h264`, `profile=Baseline`, `960x720`, `color_range=tv`.

### O vazamento, antes e depois, na mesma máquina e no mesmo dia

Medido no MacBook Air M4 com OBS 32.2.2, uma sessão de pé, sonda local:

| plugin | quadros | decode p50 | `Number of memory leaks` |
|---|---|---|---|
| `b707705` (antes) | 777 | 1,08 ms | **1** |
| com a barreira (depois) | 781 | 1,11 ms | **0** |

E no Dell, com **três** sessões de pé: **0**. A mesma corrida do macOS serve de regressão: o
VideoToolbox continua em hardware, `decode p50` 1,11 ms, 23,83 fps.

### Armadilhas de bancada que custaram rodada

**macOS**

1. **`quit app "OBS"` não fecha o OBS enquanto ele grava** — abre um diálogo modal, e o AppleScript
   fica pendurado no prazo padrão dele, **120 s**. Um roteiro que "espera 30 s e segue" na verdade
   esperou 150, e o OBS gravou dois minutos e meio. `gravar.sh` usa `with timeout of 6 seconds` e
   encerra por sinal se preciso.
2. **O AVFoundation do macOS não lê Matroska**, que é o formato padrão de gravação desta bancada.
   Gravar em `mkv` é gravar algo de que não se consegue extrair um quadro sem `ffmpeg`.
   `gravar.sh` troca para `mp4` e devolve o ajuste no fim.
3. **`pos_rel` manda, não `pos`.** O OBS 32 guarda as duas posições do item de cena e usa a relativa
   ao canvas. Copiar o `pos_rel` de um exemplo para todos os itens empilha as fontes no mesmo lugar e
   só a de cima aparece — três sessões de pé, três contadores subindo, e um quadro extraído com dois
   terços pretos.

**Windows**

4. **A pasta de plugins de usuário é `%ProgramData%`, não `%APPDATA%`** — e o diário do OBS **não
   diz nada**. O `.dll` estava em `%APPDATA%\obs-studio\plugins\quall-obs\bin\64bit\`, com o
   layout certo, e não havia nem erro nem aviso: ele nunca foi procurado ali. O sintoma apareceu
   três passos adiante, como `Source ID 'quall_fonte' not found`.
   `AddExtraModulePaths()` (`frontend/widgets/OBSBasic.cpp`) usa `GetAppConfigPath` no macOS e
   `GetProgramDataPath` no Windows, e a assimetria não está na documentação de plugin.
5. **O Windows PowerShell 5.1 lê `.ps1` sem BOM como ANSI.** Cada acento vira dois bytes soltos e o
   parser morre reclamando de aspas não terminadas numa linha que está correta. Os roteiros são
   UTF-8 **com BOM**.
6. **Com `$ErrorActionPreference = "Stop"`, um programa nativo que escreve no stderr vira exceção**,
   mesmo terminando com código 0. O `git clone` escreve "Cloning into..." lá. Redirecionar com
   `2>&1` piora: cada linha vira um `ErrorRecord`. Os roteiros passam todo comando nativo por um
   `Rodar` que baixa a guarda e confere o `$LASTEXITCODE`.
7. **`dumpbin /exports` da `obs.dll` imprime `blog = blog`.** Uma regex ancorada no fim da linha
   devolve zero símbolo, e a mensagem de erro fala do `dumpbin`, não da regex.
8. **`Get-ScheduledTask` volta vazio no meio de uma corrida boa.** O laço de espera saiu achando que
   tinha acabado, o diário foi copiado com o OBS ainda de pé e a corrida virou dez linhas. Esperar o
   processo `obs64` é o que funciona.
9. **Sonda sobrevivente de corrida abortada vira um defeito que não existe.** Ela continua ouvindo na
   porta, a corrida nova conecta nela, e quando ela expira o diário mostra "o transporte falhou".

10. **Frentes paralelas continuam se contaminando pela rede.** No meio da corrida das três fontes o
    diário do OBS **no Dell** registrou um anúncio de outra frente — `display_name` `android-rx-mac`
    em `192.168.1.131:7881`. Worktree isola arquivo, não rede. Os emissores desta rodada usaram
    portas 7900–7909 e nome prefixado `obs-win-`, e as sondas locais rodaram com `--sem-mdns`.

Artefatos preservados em `~/Movies/quall-m5-obs-windows/`: os dois `.mp4` gravados pelo OBS do Dell
com o quadro extraído de cada um, os diários das corridas do Dell, e os diários do MacBook antes e
depois da barreira.

## O que esta frente **não** afirma

- **Nenhum aparelho físico entrou no Windows.** Os emissores foram sonda local no próprio Dell e o
  MacBook pela rede. O vídeo é real (gravação do A10s, H.264 de câmera de celular), mas quem o
  colocou na rede foi um `quall-probe`, não um celular capturando ao vivo.
- **Decode em hardware no Windows: não tentado.** O número de 4,63 ms da frente da câmera virtual é
  de outro caminho (textura D3D11) e de outro consumidor. Aqui é software, medido em 3,4–6,8 ms de
  p50. "Software coube" não é "software ganhou de hardware".
- **Não é vidro a vidro.** Mede-se da chegada do quadro no tratador até o `obs_source_output_video`.
- **O painel de propriedades nunca foi visto em nenhum dos dois sistemas.** A lista de aparelhos
  está provada pelo JSON que o módulo registra no diário — mesma origem que alimenta o combo —, não
  pelo combo desenhado. No Windows a descoberta por mDNS **funcionou**: o MacBook apareceu na lista
  com `endpoint` `192.168.1.131:7900`, o que nunca tinha acontecido na rodada do macOS.
- **Áudio não existe.** Nem no Windows nem no macOS.
- **O caminho `DISCONNECTED` (o `Bye` limpo) continua sem prova.** O que apareceu no Windows foi
  `FAILED`, e por acidente — sonda de corrida anterior expirando.
- **CPU, memória e tamanho de instalação do OBS com o plugin: não medidos.** Nem no Windows nem no
  macOS.
- **Uma só máquina Windows**, um só OBS (32.2.1), um só formato (960x720 Baseline). Nada de 1080p,
  nada de GPU AMD. A troca de resolução no meio foi medida **só no OBS do Mac** (21/09,
  `docs/camera-no-windows.md` M107): o custo do encaixe no Windows, compilado pelo MSVC, não foi
  medido.
