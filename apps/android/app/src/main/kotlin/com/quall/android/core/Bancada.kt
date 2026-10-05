// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.core

import android.content.Context

/**
 * Ajustes **de bancada**, e só de bancada.
 *
 * Todos têm valor de produto embutido, e sem o arquivo de preferências nada muda: o app se comporta
 * exatamente como se esta classe não existisse. Ela existe por dois motivos concretos, os dois
 * medidos numa rodada Android↔Android:
 *
 * 1. **A rede da bancada é compartilhada entre frentes.** A regra da rodada é porta na faixa
 *    7920–7929 e `display_name` prefixado — sem isso, dois aparelhos de frentes diferentes se
 *    acham por mDNS e contaminam a medição um do outro. Recompilar o APK só para trocar a porta
 *    tornaria o binário medido diferente do binário de produto, que é pior.
 * 2. **Braço antes/depois.** O pedido de IDR na perda ([pedirIdrNaPerda]) precisa ser medido
 *    com e sem, no mesmo APK, no mesmo aparelho, na mesma janela de tempo. Um `if` de compilação
 *    daria dois binários e nenhuma comparação honesta.
 *
 * Quem escreve o arquivo é o `adb` (`run-as com.quall.android`, APK de depuração), nunca o app —
 * não há tela para nada disto, de propósito: a seção de diagnóstico da tela inicial já é o limite
 * do que um usuário deve conseguir alcançar sem querer.
 *
 * ```
 * adb -s <serial> shell "run-as com.quall.android sh -c 'cat > \
 *   /data/data/com.quall.android/shared_prefs/quall-bancada.xml'" <<'XML'
 * <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
 * <map>
 *     <int name="porta" value="7921" />
 *     <string name="prefixo_nome">aa-</string>
 *     <boolean name="pedir_idr_na_perda" value="true" />
 * </map>
 * XML
 * ```
 *
 * O arquivo é lido **na hora de usar**, não guardado em campo estático: trocar de braço entre
 * corridas é reiniciar a Activity, não reinstalar o app.
 */
object Bancada {

    private const val ARQUIVO = "quall-bancada"

    private const val CHAVE_PORTA = "porta"
    private const val CHAVE_CAMERA_DV = "camera_dv"
    private const val CHAVE_CAMERA_DV_ARQUIVO = "camera_dv_arquivo"
    private const val CHAVE_PREFIXO = "prefixo_nome"
    private const val CHAVE_IDR_NA_PERDA = "pedir_idr_na_perda"
    private const val CHAVE_INTERVALO_IDR = "intervalo_minimo_idr_ms"
    private const val CHAVE_PISO_CURTO = "piso_primeiro_pedido_ms"
    private const val CHAVE_POR_CAUSA = "supressao_por_causa"
    private const val CHAVE_IDR_NA_CAIXA = "pedir_idr_na_caixa"
    private const val CHAVE_CALMARIA_DA_CAIXA = "calmaria_da_caixa_ms"
    private const val CHAVE_SOLUCO = "soluco_do_laco_ms"
    private const val CHAVE_SOLUCO_A_CADA = "soluco_a_cada_ms"
    private const val CHAVE_CONGELAR = "congelar_na_ruptura"
    private const val CHAVE_EMITIR_AUDIO = "emitir_audio"
    private const val CHAVE_TOM_DE_PROVA = "audio_tom_de_prova"
    private const val CHAVE_MICROFONE_DE_PROVA = "microfone_de_prova"
    private const val CHAVE_GRAVAR_AUDIO = "gravar_audio_em"
    private const val CHAVE_SEM_MDNS = "sem_mdns"
    private const val CHAVE_PROVA_CARIMBO_NO_ENVIO = "prova_carimbo_no_envio"
    private const val CHAVE_PROVA_SEM_REANCORAR = "prova_sem_reancorar"
    private const val CHAVE_PROVA_LACUNA_NO_SOM = "prova_lacuna_no_som_ms"
    private const val CHAVE_PROVA_PTS_CRU = "prova_pts_cru"
    private const val CHAVE_PROVA_SEM_DISCIPLINA = "prova_sem_disciplina"
    private const val CHAVE_PROVA_PPM_NO_SOM = "prova_ppm_no_som"
    private const val CHAVE_REFRESH_INTRA = "refresh_intra_quadros"
    private const val CHAVE_MODO_DE_TAXA = "modo_de_taxa"
    private const val CHAVE_GIRO_RESIZE = "giro_resize"
    private const val CHAVE_FORNECEDOR = "chaves_de_fornecedor"
    private const val CHAVE_ORIGEM_DENSA = "origem_densa"
    private const val CHAVE_CONTEUDO_ANIMADO = "conteudo_animado"
    private const val CHAVE_DIAGNOSTICO = "diagnostico_visivel"
    private const val CHAVE_BITRATE = "bitrate_kbps"
    private const val CHAVE_RADIO_ACORDADO = "radio_acordado"
    private const val CHAVE_ANEL = "anel_pacotes"
    private const val CHAVE_PRENDER = "prender_em"
    private const val CHAVE_ESCADA = "escada_kbps"
    private const val CHAVE_ESCADA_PASSO = "escada_passo_ms"
    private const val CHAVE_JANELA_DO_FIO = "janela_do_fio_ms"
    private const val CHAVE_JANELA_DO_ENLACE = "janela_do_enlace_ms"
    private const val CHAVE_TAXA_QUE_ESCUTA = "taxa_que_escuta"
    private const val CHAVE_BIND_DA_CAMERA = "bind_da_camera"
    private const val CHAVE_CAMERA_COMUM_PELO_CAMERAX = "camera_comum_pelo_camerax"
    private const val CHAVE_SUSPENDER_PREVIA = "suspender_previa_na_volta"
    private const val CHAVE_TETO_INSTANTANEO = "teto_instantaneo"
    private const val CHAVE_CAMERA_PELO_MAIS_NOVO = "camera_pelo_mais_novo"
    private const val CHAVE_FILA_DO_CODIFICADOR = "fila_do_codificador_quadros"
    private const val CHAVE_SEM_GRAVADOR = "sem_gravador"
    private const val CHAVE_TRANSMISSAO_LEVE = "transmissao_leve"
    private const val CHAVE_GRAVACAO_TETO_720 = "gravacao_teto_720"
    private const val CHAVE_LUMA_MEDIA = "luma_media"

    /**
     * **A bancada está ativa**: existe `quall-bancada.xml` com qualquer chave. Só de leitura, e só para
     * a tela: com ela, a tela de exibir abre o painel de números e o "Pedir IDR" já na barra
     * (`docs/telas-estudio.md` §11.3) — `laco-de-audio.py` e `laco-no-aparelho.py` leem
     * `textReceptorStats` por `uiautomator`, e `aa-corrida.py` calibra o "Pedir IDR". Produto: falso
     * (ninguém escreve o arquivo sem `run-as` num APK de depuração).
     */
    fun ativa(c: Context): Boolean = prefs(c).all.isNotEmpty()

    /**
     * Porta de sinalização do emissor. Produto: [QuallNative.PORTA_SINALIZACAO].
     *
     * O receptor não lê isto: a porta dele vem do endereço digitado ou do anúncio mDNS.
     */
    fun porta(c: Context): Int {
        val p = prefs(c).getInt(CHAVE_PORTA, QuallNative.PORTA_SINALIZACAO)
        return if (p in 1..65535) p else QuallNative.PORTA_SINALIZACAO
    }

    /** Prefixo colado no `display_name` deste aparelho. Produto: vazio. */
    fun prefixoDeNome(c: Context): String = prefs(c).getString(CHAVE_PREFIXO, "").orEmpty()

    /**
     * Se o receptor pede IDR quando o núcleo acusa quadro perdido no meio do fluxo.
     *
     * O padrão é **ligado**: é o que `docs/contrato-track.md` manda ("a casca receptora chama
     * quando entra na sessão sem ter visto IDR, **ou quando o decoder perde sincronia**") e o que a
     * decisão de recusar NACK pressupõe. Desligar existe para medir o braço "antes".
     */
    fun pedirIdrNaPerda(c: Context): Boolean = prefs(c).getBoolean(CHAVE_IDR_NA_PERDA, true)

    /**
     * Piso de intervalo entre dois pedidos de IDR por perda, em milissegundos.
     *
     * Não é zelo: atender um PLI faz o emissor injetar um IDR inteiro — dezenas de fragmentos em
     * rajada — no mesmo rádio que acabou de perder uma rajada. Sem piso, uma perda vira tempestade
     * de pedido, que gera mais rajada. O RFC 4585 pede supressão pela mesma razão.
     *
     * **250 ms, e deixou de ser palpite em 27/08/2026.** Os 500 ms daqui eram declaradamente um
     * chute de partida. A varredura (`docs/android-para-android.md`, seção 17) rodou 36 corridas
     * de 30 s nos dois sentidos, com os pontos rotacionados, e achou o seguinte: **a mediana não
     * se move em faixa nenhuma** (70–86 ms de 100 a 2000 ms) — quem decide é a **cauda**. No
     * sentido do produto, p95 de 432 ms no piso 100 e 490 ms no 250, contra 1147 a 2597 ms nos
     * pisos de 500 para cima, e a fração de recuperações acima de meio segundo pula de 4–5% para
     * 16–20%.
     *
     * O custo do piso baixo é **chamado**, não perda: 172,7 PLI/min no piso de 100 ms contra 85,3
     * no de 250 e 56–65 nos altos. Por isso 250 e não 100 — preserva quase toda a cauda pela
     * metade do chamado, e mantém distância do piso de abertura (100 ms) em vez de colapsar os
     * dois relógios num só.
     *
     * O sentido descendo saiu não-monotônico e a varredura **recusou fechá-lo**; o veredito vale
     * para um sentido e está escrito assim no documento.
     */
    fun intervaloMinimoIdrMs(c: Context): Long =
        prefs(c).getInt(CHAVE_INTERVALO_IDR, 250).coerceAtLeast(0).toLong()

    /**
     * Piso antes do **primeiro** pedido de uma perda nova, em milissegundos.
     *
     * É o piso curto da supressão por causa. O longo ([intervaloMinimoIdrMs]) só vale para insistir
     * num pedido que ninguém atendeu; este limita rajada de perdas **distintas**.
     *
     * **Os 100 ms são medidos, não emprestados.** Eles entraram por analogia com uma corrida do
     * Dell, noutro sistema operacional e noutro sentido; uma varredura de 0, 100, 200, 300, 500 e
     * 1000 ms — 18 corridas subindo e 36 descendo, em dois regimes de perda a uma ordem de
     * grandeza de distância — confirmou o valor por dois motivos distintos:
     *
     * - **Subindo** (2–4% de perda), a mediana do tempo sem referência segue o piso quase
     *   linearmente (80 · 80 · 120 · 150 · 176 · 907 ms): o piso **é** o limite, e 100 ms é o
     *   menor valor que não custa nada — zero empata com ele e não compra mais.
     * - **Descendo** (14–38% de perda), a mediana é plana de 0 a 500 ms porque o limite passa a
     *   ser a **resposta** chegar; 100 ms tem a menor fração acima de meio segundo (4,5%).
     *
     * Um valor só serve aos dois regimes, então **não há piso adaptativo a escrever**. Ver
     * `docs/android-para-android.md`, seções 15 e 16.
     */
    fun pisoDoPrimeiroPedidoMs(c: Context): Long =
        prefs(c).getInt(CHAVE_PISO_CURTO, 100).coerceAtLeast(0).toLong()

    /**
     * Supressão de PLI **por causa** (produto: ligada). Desligar volta à política anterior — um
     * relógio para todas as causas e um piso só — e existe para o braço "antes" do A/B.
     */
    fun supressaoPorCausa(c: Context): Boolean = prefs(c).getBoolean(CHAVE_POR_CAUSA, true)

    /**
     * Se o quadro descartado **na caixa** do receptor pede IDR (produto: ligado). Desligar é o
     * braço "antes" — o de até 10/09/2026, que só contava a ruptura. Ver
     * `com.quall.android.receive.DividaDaCaixa`.
     */
    fun pedirIdrNaCaixa(c: Context): Boolean = prefs(c).getBoolean(CHAVE_IDR_NA_CAIXA, true)

    /**
     * Quanto a caixa precisa ficar sem descartar antes de o pedido sair, em milissegundos.
     *
     * **500 ms emprestados do receptor do Windows (`CALMARIA_DA_FILA`), não medidos no Android.**
     * Lá o motivo foi medido: pedir durante o transbordo alimentou o transbordo.
     */
    fun calmariaDaCaixaMs(c: Context): Long =
        prefs(c).getInt(CHAVE_CALMARIA_DA_CAIXA, 500).coerceIn(0, 10_000).toLong()

    /**
     * **Bancada: o laço do receptor para de tirar quadros da caixa por tanto tempo**, a cada
     * [solucoACadaMs], depois da primeira imagem. `0` (produto) desliga.
     *
     * Existe para provocar descarte na caixa quando se quer, e medir [pedirIdrNaCaixa] contra ele:
     * a carga sintética na tela estendida não reproduziu os descartes da sessão real do `SM-X230` a
     * 60 fps (`docs/tela-estendida.md`). É o papel do `--receptor-lento-fps` do receptor do
     * Windows. A caixa tem 4 posições — 66 ms a 60 fps —, então um soluço de 150 ms descarta ~5.
     */
    fun solucoDoLacoMs(c: Context): Long =
        prefs(c).getInt(CHAVE_SOLUCO, 0).coerceIn(0, 2_000).toLong()

    fun solucoACadaMs(c: Context): Long =
        prefs(c).getInt(CHAVE_SOLUCO_A_CADA, 3_000).coerceIn(500, 60_000).toLong()

    /**
     * A porta nasce **DESLIGADA**, e isso é reversão medida, não gosto.
     *
     * Ela entrou ligada com o argumento de que todo produto de espelhamento congela o último quadro bom
     * e espera o IDR em vez de mostrar lixo. O argumento tem uma premissa escondida: **que o IDR chega.**
     * Em 31/08/2026, A10s espelhando tela real para o iPad em 2,4 GHz, o emissor mandou 31 IDR e o
     * receptor viu 13 — 58 % dos quadros de recuperação destruídos pela mesma perda que eles existem
     * para consertar. `sem_referencia_ms [n=8 p50=1959 p95=2083 max=2083]`: todos os intervalos
     * terminaram na válvula de 2 s, nenhum porque a imagem se curou. `fps` na tela: 0,0.
     *
     * Onde o IDR não chega, a porta troca imagem suja por tela parada, que é pior. Ela fica desligada
     * até a entrega do IDR sobreviver à perda. Os contadores contam dos dois lados — `suspeitos` não
     * depende da porta, só `retidos` depende.
     *
     * `congelar_na_ruptura=true` liga, para o braço "depois" do A/B no mesmo APK.
     */
    fun congelarNaRuptura(c: Context): Boolean = prefs(c).getBoolean(CHAVE_CONGELAR, false)

    /**
     * Se o emissor põe uma track de **som do sistema** na oferta, junto com a de tela.
     *
     * **Produto: desligado, e isto é honestidade, não timidez.** Capturar o som do sistema no
     * Android exige `MediaProjection` **e** a permissão de tempo de execução `RECORD_AUDIO` —
     * um diálogo que só o usuário toca. Ligar por padrão faria toda sessão de espelhamento
     * anunciar uma track de áudio que na maioria dos aparelhos nunca entregaria byte nenhum, e o
     * receptor ficaria com um `AudioTrack` aberto esperando som que não vem. Ver
     * `apps/android/README.md`, seção do áudio.
     *
     * Com [tomDeProva] ligado, esta track é alimentada pelo **tom sintético** e não precisa de
     * permissão nenhuma — é o braço que a bancada mede.
     */
    fun emitirAudio(c: Context): Boolean = prefs(c).getBoolean(CHAVE_EMITIR_AUDIO, false)

    /**
     * Alimenta a track de áudio com o **tom sintético de quatro notas**, e não com o som do
     * aparelho.
     *
     * `docs/audio.md` §8 é literal: *"a origem de áudio da bancada é sintética. Sempre."* O som
     * real da máquina do usuário não é material de bancada, e um `.wav` não carrega no nome o que
     * tem dentro. Este é o braço que prova o caminho de emissão de ponta a ponta sem tocar em
     * captura nenhuma — e sem `RECORD_AUDIO`.
     */
    fun tomDeProva(c: Context): Boolean = prefs(c).getBoolean(CHAVE_TOM_DE_PROVA, false)

    /**
     * **O tom injetado no lugar do microfone da câmera** (R5, fase 2; `docs/audio.md` §8, a regra
     * que fica). A track `MICROPHONE` vai na oferta como em produto, o botão liga e desliga como em
     * produto, e o que entra no encoder é o tom de quatro notas **ritmado como uma captura**
     * ([com.quall.android.audio.TomRitmado], a `prova_ppm_no_som` dele, 0 por padrão): bloqueia no
     * ritmo de um dispositivo de mentira e diz a hora da primeira amostra, então o caminho do
     * carimbo na captura e da disciplina da deriva roda inteiro. **Nenhum `AudioRecord`, nenhum
     * `RECORD_AUDIO`, nenhum tipo `microphone` no serviço.** O que isto não prova: o microfone de
     * verdade e o atraso dele contra a câmera — isso é a claquete física (§8, G4).
     */
    fun microfoneDeProva(c: Context): Boolean = prefs(c).getBoolean(CHAVE_MICROFONE_DE_PROVA, false)

    /**
     * Caminho de um `.wav` onde gravar o áudio **decodificado** na recepção. Produto: vazio.
     *
     * Ligar isto numa sessão cuja origem não seja o tom sintético grava o som da máquina do outro
     * lado num arquivo. A regra que decide é a mesma de `prova-laco.ps1` contra `prova-rede.ps1`:
     * **a origem manda**. A bancada só liga com o `quall-probe` emitindo tom do outro lado.
     */
    fun gravarAudioEm(c: Context): String = prefs(c).getString(CHAVE_GRAVAR_AUDIO, "").orEmpty()

    /**
     * Desliga o anúncio mDNS do emissor. Produto: **ligado** (isto é `false`).
     *
     * Existe por um motivo medido em 30/08/2026, e ele não é economia: o laço de prova dentro do
     * aparelho (`tools/laco-de-audio.py`) promete que **nada vai ao ar**, e a promessa era falsa
     * pela metade. A sonda já tinha `--sem-mdns`; o app não tinha equivalente, então toda corrida
     * do sentido "emitir" punha anúncios multicast na Wi-Fi compartilhada com outras frentes —
     * poucos pacotes, mas pacotes.
     *
     * O caminho por endereço digitado continua inteiro sem o anúncio; é o mesmo caminho de código
     * que o A10s já era obrigado a usar (`docs/divida-do-nucleo.md`, item 9).
     */
    fun semMdns(c: Context): Boolean = prefs(c).getBoolean(CHAVE_SEM_MDNS, false)

    /**
     * **Os braços da prova dos carimbos** (`docs/som-no-receptor.md` §19.3 e §19.4). Todos
     * desligados em produto; cada um é o controle de um conserto, no mesmo APK:
     *
     * - `prova_carimbo_no_envio`: o som carimbado com a hora do **envio**, depois do encode — o
     *   comportamento até 21/09/2026;
     * - `prova_sem_reancorar`: o carimbo do som em tempo de mídia puro desde a primeira âncora, sem
     *   reancorar — o controle da reancoragem;
     * - `prova_lacuna_no_som_ms`: uma lacuna desse tamanho na fonte de som, uma vez, 10 s depois do
     *   primeiro quadro (a retomada que a reancoragem existe para pegar). `0` desliga;
     * - `prova_pts_cru`: o vídeo sai com o `presentationTimeUs` cru, sem o [com.quall.android.capture.RelogioDoPts]
     *   (que mede e classifica igual, e diz no diário);
     * - `prova_ppm_no_som` (int): o tom de prova vira uma fonte ritmada por um dispositivo de mentira
     *   que anda tantos ppm mais depressa que o host ([com.quall.android.audio.TomRitmado]), e a
     *   disciplina da deriva roda para ela (§19.6.6, teste 12). `0` desliga;
     * - `prova_sem_disciplina`: o controle da disciplina (a razão fica em 1).
     */
    fun provaDoSom(c: Context): com.quall.android.audio.EmissorDeAudio.ProvaDoSom =
        com.quall.android.audio.EmissorDeAudio.ProvaDoSom(
            carimboNoEnvio = prefs(c).getBoolean(CHAVE_PROVA_CARIMBO_NO_ENVIO, false),
            semReancorar = prefs(c).getBoolean(CHAVE_PROVA_SEM_REANCORAR, false),
            lacunaMs = prefs(c).getInt(CHAVE_PROVA_LACUNA_NO_SOM, 0).coerceIn(0, 10_000).toLong(),
            semDisciplina = prefs(c).getBoolean(CHAVE_PROVA_SEM_DISCIPLINA, false),
            ppmNoSom = prefs(c).getInt(CHAVE_PROVA_PPM_NO_SOM, 0).coerceIn(-2_000, 2_000),
        )

    fun provaPtsCru(c: Context): Boolean = prefs(c).getBoolean(CHAVE_PROVA_PTS_CRU, false)

    /**
     * Período do refresh intra gradual, em quadros. **Produto: 0 (desligado)** — e a medida de
     * `docs/idr-pequeno.md` é o que decide se ele deixa de ser zero.
     *
     * Existe como preferência, e não como constante, porque o A/B honesto é o mesmo APK no mesmo
     * aparelho na mesma janela de rádio: `docs/bancada.md` já registrou que duas corridas
     * seguidas em 2,4 GHz não são comparáveis entre si.
     */
    fun refreshIntraQuadros(c: Context): Int =
        prefs(c).getInt(CHAVE_REFRESH_INTRA, 0).coerceIn(0, 600)

    /**
     * `KEY_BITRATE_MODE` do `MediaCodec`, para varrer os braços no mesmo binário.
     *
     * O produto é `-1` — automático, que escreve **CBR quando o encoder declara suportar**. Este
     * valor deixou de ser "nada escrito" em 08/09/2026, quando o S24 fechou uma sessão de 1080p60
     * com `pedido=13500000 obtido=16881469`: sem chave nenhuma o padrão do AVC é VBR, que trata o
     * alvo como média e estoura 25 %.
     *
     * Os braços que interessam medir:
     *  - `-1` produto (CBR se suportado)
     *  - `-2` não escrever nada (o comportamento anterior, para o braço "antes")
     *  - ` 0` CQ · ` 1` VBR · ` 2` CBR · ` 3` CBR_FD — os valores de
     *    `MediaCodecInfo.EncoderCapabilities`, escritos só se o encoder declarar suporte
     *
     * A tela é o caso a vigiar: cena parada sob CBR pode gastar o orçamento inteiro sem ter o que
     * mostrar, e é por isso que este braço existe em vez de a escolha ser cravada.
     */
    fun modoDeTaxa(c: Context): Int =
        prefs(c).getInt(CHAVE_MODO_DE_TAXA, -1).coerceIn(-2, 3)

    /**
     * Braço de bancada: ao girar a tela, chamar `VirtualDisplay.resize()` **sem tocar no
     * `MediaCodec`**.
     *
     * Existe para responder UMA pergunta binária antes de qualquer frente de giro: com o display
     * redimensionado e o encoder parado na geometria antiga, a imagem no receptor **preenche** ou
     * sai **anamórfica**? As duas respostas levam a caminhos opostos — se preencher, a frente do
     * giro encolhe para dois arquivos; se distorcer, ela exige trocar a geometria do fluxo no ar,
     * com SPS novo e IDR, o que nunca foi feito nesta bancada.
     *
     * O experimento é seguro por construção: nenhum SPS novo sai, nenhum receptor é reconfigurado,
     * e o pior caso é a imagem sair torta durante a corrida.
     *
     * `false` em produto. O giro segue como está: a tela deitada desenhada dentro da superfície em
     * pé, escalada para caber.
     */
    fun giroResize(c: Context): Boolean = prefs(c).getBoolean(CHAVE_GIRO_RESIZE, false)

    /**
     * Chaves de fornecedor a pedir ao `MediaCodec`, no formato `nome=inteiro`, separadas por
     * vírgula. Produto: vazio.
     *
     * O Android não tem chave padrão de tamanho de fatia, só chave de fornecedor, com nome
     * diferente por SoC. Esta preferência existe para a bancada **procurar** o nome certo sem
     * recompilar o APK — o que importa quando a resposta esperada, nas cinco vezes anteriores
     * deste projeto, foi "aceitou e ignorou".
     *
     * Valor mal formado é descartado par a par, e não derruba a corrida.
     */
    fun chavesDeFornecedor(c: Context): Map<String, Int> {
        val cru = prefs(c).getString(CHAVE_FORNECEDOR, "").orEmpty()
        if (cru.isBlank()) return emptyMap()
        return cru.split(',').mapNotNull { par ->
            val i = par.indexOf('=')
            if (i <= 0) return@mapNotNull null
            val nome = par.substring(0, i).trim()
            val valor = par.substring(i + 1).trim().toIntOrNull() ?: return@mapNotNull null
            if (nome.isEmpty()) null else nome to valor
        }.toMap()
    }

    /**
     * Enche a tela de teste de captura com um mosaico **denso e estático**, em vez do fundo liso.
     * Produto: desligado.
     *
     * Existe porque a origem animada padrão (bola sobre fundo escuro) produz IDR de meia dúzia
     * de pacotes, e a pergunta desta frente é sobre IDR de ~60 — o regime da tela real que o
     * usuário filmou. O mosaico é gerado por um gerador congruencial de semente fixa: é
     * **sintético e reproduzível**, que é o que `docs/regras-de-frente.md` exige de qualquer
     * origem que vire número neste repositório, e o oposto de apontar o instrumento para a tela
     * de alguém.
     *
     * Detalhe espacial alto com movimento baixo é de propósito: é exatamente o regime da tela
     * parada de um celular — IDR grande, quadro P pequeno.
     */
    fun origemDensa(c: Context): Boolean = prefs(c).getBoolean(CHAVE_ORIGEM_DENSA, false)

    /**
     * Pinta a view animada em tela cheia enquanto se espelha **a tela**. Produto: desligado.
     *
     * **Até 07/09/2026 isto era o comportamento de produto, e não devia ser.** O
     * `MediaProjection` captura o display inteiro: com o app em primeiro plano pintando uma bola
     * quicando, é a bola que atravessa o fio, e a tela do aparelho — que é o que a pessoa pediu
     * para espelhar — fica atrás dela. O usuário nomeou isso na corrida de sete emissores:
     * *"tirar o modo teste do espelhamento da tela, exibir a tela original"*.
     *
     * As duas razões escritas para ela existir continuam válidas **para a bancada**, e é por isso
     * que a chave existe em vez de a view sumir: (1) é prova visual de que há imagem indo, e
     * (2) dá à `VirtualDisplay` algo que muda, o que uma corrida de taxa precisa. Nenhuma das
     * duas é razão de produto — a primeira é o que a linha de estatísticas já diz com números, e
     * a segunda é justamente o que **não** se quer medir quando o assunto é a tela de verdade:
     * uma tela parada tem de custar quase nada, e uma bola quicando esconde isso.
     *
     * Ligada, ela se combina com [origemDensa] como antes.
     */
    fun conteudoAnimado(c: Context): Boolean = prefs(c).getBoolean(CHAVE_CONTEUDO_ANIMADO, false)

    /**
     * Revela a seção de diagnóstico da tela inicial sem o gesto secreto. Produto: desligado.
     *
     * O gesto de produto são **sete toques no título dentro de uma janela de 3 s**, e ele não é
     * alcançável por `adb`: no A10s cada `input tap` custa ~1,1 s de JVM, então sete toques
     * levam 8 s e a janela expira antes do terceiro. Medido nesta bancada em 31/08/2026, ao
     * tentar dirigir a captura de bancada por roteiro.
     *
     * A alternativa seria alargar a janela do gesto, o que mudaria o produto para servir ao
     * instrumento. Esta preferência não muda nada para quem não a escreve.
     */
    fun diagnosticoVisivel(c: Context): Boolean = prefs(c).getBoolean(CHAVE_DIAGNOSTICO, false)

    /**
     * Bitrate inicial do encoder, em kbps, **para tela e para câmera**. `0` é produto: o teto de
     * taxa da geometria (`QuallNative.tetoDeTaxaBps` — 4000 kbps a 720p30) na tela, e esse teto
     * vezes 3/2 na câmera.
     *
     * Existe para varrer a curva de resposta do enlace sem recompilar o APK. O valor entra no
     * `configure()` do `MediaCodec`; para trocar **em voo** é [escadaKbps].
     *
     * **Alcançou a câmera em 04/09/2026** (§8.28). O caminho de câmera pede 13,5 Mbps a 1080p30 —
     * um número que `teto_de_taxa` calculou como *teto* de nível H.264 e que o `MediaCodec` recebe
     * como *alvo*. Medido: numa cena simples o controlador desce a QP 6 para gastar o orçamento,
     * contra QP 16 quando a taxa é ~3 Mbps. QP 6 é faixa de masterização; ninguém precisa dela
     * para espelhar, e são esses 13 Mbps que dão ao IDR os 151 pacotes que a rajada destrói.
     */
    fun bitrateKbps(c: Context): Int = prefs(c).getInt(CHAVE_BITRATE, 0).coerceIn(0, 20_000)

    /**
     * Segurar o `WifiLock` de baixa latência enquanto o emissor está no ar. **Ligado é produto**;
     * a chave existe para o braço de controle.
     *
     * Sem ele o rádio dorme entre beacons e o pareamento pode levar dez segundos (§8.33) — mas
     * "pode" não é medida, e medir exige os dois braços **no mesmo APK**, senão a comparação é
     * entre dois binários. Ver [RadioAcordado].
     */
    fun radioAcordado(c: Context): Boolean = prefs(c).getBoolean(CHAVE_RADIO_ACORDADO, true)

    /**
     * **A filmadora DV por USB como fonte de câmera** (fase B do DV no S24, 22/09/2026). Desligada
     * em produto: a filmadora existe só atrás desta bandeira até a prova com o Pessoa Exemplo. **A placa de
     * captura não depende dela** desde 28/09 (a P3, `docs/placa-de-captura-usb.md` §11): aparece
     * para todos. Ligada, a lista mostra todo aparelho de vídeo USB plugado ("Vídeo USB (…)",
     * "Filmadora DV (…)", "Placa de captura (…)", `capture/dv/RegraDaPlaca.kt`), com a
     * `libqualldv.so` carregada (só arm64). Ver `capture/dv/FonteDv.kt`.
     */
    fun cameraDv(c: Context): Boolean = prefs(c).getBoolean(CHAVE_CAMERA_DV, false)

    /**
     * **O teto da altura do quadro pedido à placa de captura** (`docs/placa-de-captura-usb.md` §14):
     * 720 em produto (1280x720); 1080 pede 1920x1080 às placas HDMI. Inteiro, `placa_altura_max`.
     */
    fun placaAlturaMax(c: Context): Int =
        prefs(c).getInt("placa_altura_max", com.quall.android.capture.dv.EscolhaDeFormato.ALTURA_MAX).coerceIn(480, 1080)

    /**
     * **A DV sem filmadora**: caminho de um arquivo de quadros DV (gravado pelo espião,
     * `tools/espiao-dv-s24`) que a `libqualldv` toca em laço a 29,97 no lugar do USB. Vazio em
     * produto. Com [cameraDv] ligada e isto preenchido, a lista ganha "Filmadora USB (arquivo de
     * bancada)": prova o caminho inteiro (decodificação, ImageWriter, encoder, receptor) sem
     * diálogo de permissão USB.
     */
    fun cameraDvArquivo(c: Context): String = prefs(c).getString(CHAVE_CAMERA_DV_ARQUIVO, "") ?: ""

    /**
     * **Braço de controle do anel de reordenação**, em pacotes. `-1` é produto: o anel se ajusta
     * sozinho ao regime da rede.
     *
     * Qualquer valor `>= 0` **crava** a profundidade e desliga o ajuste; `0` desliga a fila
     * inteira e reproduz o comportamento anterior a 01/09/2026.
     *
     * # Por que ele precisou existir
     *
     * O anel passou a se ajustar sozinho em 02/09/2026 e, na primeira corrida de Wi-Fi, terminou
     * em 4 medindo mais que o dobro de `suspeitos` por mil quadros que a corrida do dia anterior
     * com o anel fixo em 16 — com a mesma perda. Só que dias diferentes: este repositório repete
     * que duas corridas de 2,4 GHz separadas no tempo não se comparam, porque o rádio anda ao
     * longo da medição. Sem braço de controle **no mesmo enlace**, aquilo continua sendo anedota,
     * e um controlador acusado por anedota é pior que controlador nenhum.
     *
     * `-1` como padrão, e não `0`, porque `0` é um valor legítimo (fila desligada) e um padrão
     * que colide com um valor de bancada é o tipo de armadilha que só aparece na corrida em que
     * ela importa.
     */
    fun profundidadeDoAnel(c: Context): Int =
        prefs(c).getInt(CHAVE_ANEL, -1).coerceIn(-1, 512)

    /**
     * **Prende a mídia e a sinalização a UMA interface local**, pelo endereço IPv4 dela. Vazio
     * (produto) usa todas.
     *
     * # O que ele conserta, e custou dois braços de bancada
     *
     * Numa corrida "pelo cabo" — Android ancorado por USB no emissor — o telefone disca o
     * endereço da ancoragem, mas o **ICE** escolhe o par que quiser entre todos os candidatos.
     * Com o Wi-Fi ligado ele escolhe o rádio, e a corrida mede rádio achando que mediu cabo.
     * Aconteceu em 01/09/2026 (braço anulado) e de novo em 02/09: perda exata de 3,069 % num
     * "cabo", com `local_address 192.168.56.159` e `remote_address 192.168.56.41` — os dois no
     * Wi-Fi.
     *
     * A saída conhecida era desligar o Wi-Fi do aparelho, o que **derruba o adb** e obriga alguém
     * a tocar na tela para conectar. Prender a interface faz o mesmo sem sacrificar a depuração.
     *
     * O núcleo já tinha isto (`TransportConfig::bind_address`, e a sinalização sai pela mesma
     * interface por `connect_de`); o que faltava era a casca alcançar. Ver
     * `QuallNative.connectStart`.
     */
    fun prenderEm(c: Context): String = prefs(c).getString(CHAVE_PRENDER, "").orEmpty()

    /**
     * Escada de bitrates a percorrer **dentro de uma sessão só**, em kbps, separados por vírgula.
     * Vazio desliga (produto).
     *
     * # Por que a curva se mede numa sessão e não em N corridas
     *
     * `docs/bancada.md` repete, em três frentes diferentes, que **duas corridas seguidas em
     * 2,4 GHz não são comparáveis entre si**: o rádio anda ao longo da medição, e um lote de N
     * pontos medidos em sequência mede N horas diferentes. A resposta padrão deste repositório é
     * intercalar e rotacionar os braços — que funciona, e custa N vezes o tempo.
     *
     * Com a troca em voo isso deixa de ser necessário para **esta** pergunta: os N pontos da
     * curva cabem numa sessão de poucos minutos, no mesmo encoder, na mesma associação DTLS, com
     * a mesma janela de rádio. É a diferença entre comparar horas e comparar minutos.
     *
     * O que a escada **não** resolve é ordem: um ponto medido depois de outro pode herdar o
     * estado do anterior (fila do rádio, térmica do encoder). Por isso a escada aceita qualquer
     * ordem, e uma corrida descendente e outra ascendente sobre os mesmos pontos é o par que
     * denuncia histerese. A primeira parte de cada degrau é transitório e não é ponto de curva —
     * quem descarta é quem lê, com o carimbo de cada janela na mão.
     */
    fun escadaKbps(c: Context): List<Int> =
        prefs(c).getString(CHAVE_ESCADA, "").orEmpty()
            .split(',')
            .mapNotNull { it.trim().toIntOrNull() }
            .filter { it in 1..20_000 }

    /** Duração de cada degrau de [escadaKbps], em ms. */
    fun escadaPassoMs(c: Context): Long =
        prefs(c).getInt(CHAVE_ESCADA_PASSO, 20_000).coerceAtLeast(1_000).toLong()

    /**
     * Período da janela do fio no emissor, em ms. `0` desliga (produto).
     *
     * Ver `H264SurfaceEncoder.janelaDoFioMs`: é o instrumento que diz se o botão de bitrate move
     * o que sai, e ele não pode ser o retorno da API.
     */
    fun janelaDoFioMs(c: Context): Long =
        prefs(c).getInt(CHAVE_JANELA_DO_FIO, 0).coerceAtLeast(0).toLong()

    /**
     * Período da janela do enlace no **receptor**, em ms. **500 por padrão desde 31/08/2026**;
     * `0` desliga.
     *
     * ## Por que o padrão mudou, e o defeito que a mudança conserta
     *
     * O controlador de taxa foi ligado por padrão em 31/08 ([taxaQueEscuta]) — e **não fez nada**,
     * porque este relato continuava desligado. Sem ele o receptor nunca conta o que viu, o emissor
     * nunca recebe uma amostra, e o controlador fica inerte. Medido na primeira corrida
     * ponta a ponta depois de ligar: A10s → iPad, `trocas_de_bitrate=0` no emissor com **4,3 % de
     * perda** e 1018 quadros suspeitos do outro lado.
     *
     * O A/B da frente nunca viu isso porque `aa-taxa.py` liga o relato **nos dois braços**, de
     * propósito — para que o tráfego dele não explicasse a diferença. A escolha estava certa para o
     * A/B e escondeu que o produto não o ligava sozinho.
     *
     * **Ligar por padrão só ficou possível com o `PROTOCOL_VERSION 2`**: um par da versão 1 morre
     * ao receber a etiqueta `enlace`, e a versão nova o recusa antes disso, com prosa.
     *
     * Custo medido: ~129 bytes no ar por janela, 2 janelas por segundo, **~2,1 kbps contra os
     * 4 000 kbps do vídeo — 0,05 %**, abaixo do ruído da própria medida.
     *
     * O piso efetivo é 500 ms — ver `ReceptorSessao.janelaDoEnlaceMs`, que explica por quê e por
     * que isso não é limitação onde importa.
     */
    fun janelaDoEnlaceMs(c: Context): Long =
        prefs(c).getInt(CHAVE_JANELA_DO_ENLACE, 500).coerceAtLeast(0).toLong()

    /**
     * O controlador de taxa do emissor. **Nasce LIGADO desde 2026-08-31**, por decisão do usuário
     * e com o A/B que a sustenta.
     *
     * Ele nasceu desligado, como todas as portas deste projeto, e virou padrão quando o A/B em
     * aparelho fechou com as faixas **sem se tocar** — seis corridas de 60 s intercaladas, A10s →
     * tablet em 2,4 GHz:
     *
     * | | desligada | LIGADA |
     * |---|---|---|
     * | `suspeitos` | 434 · 446 · 735 | 83 · 114 · 139 |
     * | na válvula de 2 s | 4 de 228 | **0 de 63** |
     * | maior `sem_referencia_ms` | 2006 ms | 882 ms |
     * | fps no receptor | 24,2 · 29,0 · 27,3 | 29,9 · 29,1 · 30,1 |
     *
     * E o braço de aferição negativo passa em aparelho: em 5 GHz, com **0 perda em 53 001
     * pacotes**, `setParameters` foi chamado **zero vezes em 181 janelas**. Num enlace limpo ele
     * não se mexe — não por sintonia, mas porque o teto é o valor de produto e não há caminho que
     * o leve acima. Ver o cabeçalho de `quall_core::taxa`.
     *
     * **A SUBIDA ficou sem aparelho até 10/09/2026.** As corridas do A/B deram 27 descidas e
     * **zero** subidas em 540 janelas de decisão, porque aquele enlace nunca acalmou o suficiente.
     * Em 10/09, S24 → Dell a 1080p30, um evento de rádio (22 % e 15 % em duas janelas) derrubou o
     * alvo de 6,75 para 5,06 Mbps, e ele **voltou ao teto em sete degraus**, um a cada ~8,6 s
     * (`docs/bancada.md` §8.69). O risco que este parágrafo registrava — preso embaixo depois de o
     * enlace melhorar — não apareceu na primeira vez que pôde aparecer.
     *
     * `taxa_que_escuta=false` desliga, e o A/B continua possível **no mesmo APK** — agora com os
     * papéis trocados.
     *
     * O **relato do receptor não depende desta chave** — ele sai sempre que
     * [janelaDoEnlaceMs] estiver ligada. É de propósito: nos dois braços do A/B o mesmo tráfego
     * de relato está no ar, então a diferença entre eles não pode ser explicada por ele.
     */
    fun taxaQueEscuta(c: Context): Boolean = prefs(c).getBoolean(CHAVE_TAXA_QUE_ESCUTA, true)

    /**
     * Como o `VideoCapture` entra na câmera que a prévia da espera já abriu.
     *
     * O padrão é `rebind_junto` porque **a medida decidiu**, e decidiu nos dois eixos ao mesmo
     * tempo. Dezoito corridas, três aparelhos, o mesmo APK (`docs/bancada.md` §8.20):
     *
     * | aparelho | nível | codificador: incremental → rebind | 1ª imagem: incremental → rebind |
     * |---|---|---|---|
     * | A10s   | FULL    | 1280x720 → **1920x1080** | 1033,7 → 819,6 ms |
     * | A07    | LEVEL_3 | 1280x720 → **1920x1080** |  896,7 → 720,3 ms |
     * | Tablet | LIMITED | 1920x1080 nos dois       |  671,6 → 499,3 ms |
     *
     * O `incremental` fica aqui como **braço**, não como alternativa de produto: quem for medir
     * de novo precisa dos dois no mesmo binário, e um `if` de compilação daria dois APKs e
     * nenhuma comparação honesta — a mesma razão que fez [pedirIdrNaPerda] existir.
     *
     * Valores: `rebind_junto` (produto), `so_codificador`, `incremental`, `incremental_estrito`.
     * Qualquer outro texto cai no padrão.
     *
     * **`so_codificador` existe e não é o padrão, por escolha do usuário.** Com a prévia no mesmo
     * `bindToLifecycle`
     * do codificador, sair do app e voltar faz o CameraX **refazer a sessão de captura inteira** —
     * medido no S24 em 09/09/2026, com as linhas do próprio CameraX:
     * `Resetting Capture Session` → `Releasing session in state OPENED` → `Opening capture
     * session`, 280 ms. O codificador está nessa sessão e para junto; quando ela volta, sai uma
     * enxurrada que o receptor mediu em **8 572 pacotes numa janela de 509 ms, 50,92% perdidos**,
     * e a imagem vira verde nas duas cascas receptoras.
     *
     * **E mesmo assim o padrão é `rebind_junto`, porque quem usa decidiu.** Pessoa Exemplo, em 09/09/2026,
     * depois de ver os dois: *"no meu ponto de vista é melhor funcionar igual o A07, saindo e
     * voltando entre apps e continuar a prévia do que ficar a tela com fundo preto. Se o aparelho
     * desligar e religar vai usar a câmera para reconhecimento facial e vai cair a câmera do
     * Quall, o que é mais improvável de acontecer."* Trocar o gesto comum (alternar app) pelo raro
     * (desbloqueio por rosto) é o negócio errado. O conserto certo é a enxurrada não derrubar a
     * imagem — e esse é do controle de taxa, não daqui.
     */
    fun bindDaCamera(c: Context): String =
        prefs(c).getString(CHAVE_BIND_DA_CAMERA, "rebind_junto").orEmpty()
            .takeIf {
                it in setOf("incremental", "rebind_junto", "incremental_estrito", "so_codificador")
            }
            ?: "rebind_junto"

    /**
     * **O braço de controle da câmera comum**: `true` volta ao `CameraXSource` de antes de 24/09 (a
     * prévia num `Preview`, o codificador num `VideoCapture` bindado junto com [bindDaCamera], a
     * câmera fechando e reabrindo ao ligar o codificador), e **sem o botão Gravar**. Produto:
     * `false` — a câmera comum pelo `DonoDaCaptura`, como a tela R5 (`docs/teleprompter-com-camera.md`
     * §8.6). Existe para medir o que o dono mudou (o buraco ao conectar, a S-A4) no mesmo APK.
     */
    fun cameraComumPeloCameraX(c: Context): Boolean = prefs(c).getBoolean(CHAVE_CAMERA_COMUM_PELO_CAMERAX, false)

    /**
     * **Religa a guarda da prévia de 08/09** — a que recusa o provedor da prévia quando o app volta
     * com a sessão no ar. Produto: desligada.
     *
     * # Por que um braço que já se provou ruim volta a existir
     *
     * Porque ele é a **única enxurrada conhecida** que esta bancada sabe provocar. Com a guarda
     * ligada, sair do app e voltar parava o codificador e soltava o atraso de uma vez: o receptor
     * mediu **8 572 pacotes numa janela de 509 ms, 50,92% perdidos** (`docs/bancada.md` §8.65). É
     * exatamente o que o teto instantâneo ([tetoInstantaneo]) existe para conter, e ele nunca foi
     * exercitado: 210 janelas, zero quadro barrado, porque a enxurrada deixou de acontecer.
     *
     * O comentário de `PreviaDaCamera.suspenderNaVolta` dizia desde 09/09 que esta chave existia.
     * **Não existia** — o campo era `private set` e ninguém o escrevia. Foi achado em 10/09, na
     * hora de provocar a enxurrada.
     *
     * **E o que ela provoca é mais do que enxurrada** (`docs/bancada.md` §8.69). Com o teto ligado a
     * enxurrada foi contida — perda de 0,009 % — e a imagem ficou verde do mesmo jeito, nos três
     * receptores: neste estado o **S24 codifica verde**. Uma corrida com esta chave mede o teto na
     * janela do gesto, e não a imagem depois dela.
     */
    fun suspenderPreviaNaVolta(c: Context): Boolean =
        prefs(c).getBoolean(CHAVE_SUSPENDER_PREVIA, false)

    /**
     * O teto instantâneo de saída do emissor (`TrackFrameSink.tetoInstantaneoBps`). **Produto:
     * ligado.**
     *
     * Desligar existe para o braço de controle da corrida que provoca a enxurrada com
     * [suspenderPreviaNaVolta]: sem o braço em que o teto **não** age, "o teto conteve a enxurrada"
     * seria indistinguível de "a enxurrada não veio desta vez".
     */
    fun tetoInstantaneo(c: Context): Boolean = prefs(c).getBoolean(CHAVE_TETO_INSTANTANEO, true)

    /**
     * O divisor GL pega o quadro **mais novo** da câmera ao acordar, e pula os acumulados
     * (`docs/teleprompter-com-camera.md` §14.11, conserto 1). **Desligado até a prova** (a revisão do
     * código da D1, 6: muda o caminho que hoje funciona no A07 e no S24, e a gravação passa a pular
     * quadro quando a thread GL atrasa). Desligado é o
     * controle da prova: um quadro por aviso, como era até 28/09.
     */
    fun cameraPeloMaisNovo(c: Context): Boolean = prefs(c).getBoolean(CHAVE_CAMERA_PELO_MAIS_NOVO, false)

    /**
     * **A porta dos codificadores do divisor** (§14.11, §14.12): o máximo de quadros em trânsito na
     * rede (a gravação leva o dobro). **0 desliga, e é o padrão até a prova** no A10s, no A07 e no
     * S24; a conta em trânsito vai para o diário do mesmo jeito.
     */
    fun filaDoCodificadorQuadros(c: Context): Int = prefs(c).getInt(CHAVE_FILA_DO_CODIFICADOR, 0).coerceIn(0, 32)

    /**
     * Força a mensagem "este aparelho não grava" (§14.3, caso 1; a prova 7 da D1): o Gravar abre
     * desabilitado com o motivo, e o controle não vê o botão.
     */
    fun semGravador(c: Context): Boolean = prefs(c).getBoolean(CHAVE_SEM_GRAVADOR, false)

    /**
     * O recuo do §14.4, **preparado e desligado**: a gravação com o maior lado ≤ 1280 e o menor ≤ 720
     * (a vertical 720×1280 no A10s), só se a prova 5 da D1 pedir.
     */
    fun gravacaoTeto720(c: Context): Boolean = prefs(c).getBoolean(CHAVE_GRAVACAO_TETO_720, false)

    /**
     * A regra do aparelho fraco (`core/TransmissaoLeve.kt`): `"auto"` (o padrão, pelo que o codificador
     * declara), `"sim"` (força 720p na rede da câmera, para provar a frase num aparelho forte) ou `"nao"`.
     */
    fun transmissaoLeve(c: Context): String = prefs(c).getString(CHAVE_TRANSMISSAO_LEVE, "auto") ?: "auto"

    /**
     * **A luma média do quadro** (R9, `docs/controles-de-camera.md` §5): o divisor GL desenha um quadro a
     * cada 30 num FBO de 16 × 16, lê 1 KB e registra `r9: luma_media=… fps=… custo_us=…` no logcat
     * (`QuallDivisor`). É a testemunha "no fluxo" dos controles — o brilho sobe e desce com EV, ISO e
     * obturador — sem salvar nem abrir quadro nenhum. Produto: desligada; vale na abertura da câmera.
     */
    fun lumaMedia(c: Context): Boolean = prefs(c).getBoolean(CHAVE_LUMA_MEDIA, false)

    /** Resumo de uma linha, para o logcat de cada corrida dizer em que braço ela rodou. */
    fun resumo(c: Context): String =
        "porta=${porta(c)} prefixo='${prefixoDeNome(c)}' camera_dv=${cameraDv(c)} camera_dv_arquivo='${cameraDvArquivo(c)}' " +
            "idr_na_perda=${pedirIdrNaPerda(c)} por_causa=${supressaoPorCausa(c)} " +
            "congelar_na_ruptura=${congelarNaRuptura(c)} " +
            "piso_curto=${pisoDoPrimeiroPedidoMs(c)}ms " +
            "piso_longo=${intervaloMinimoIdrMs(c)}ms " +
            "idr_na_caixa=${pedirIdrNaCaixa(c)} calmaria_da_caixa=${calmariaDaCaixaMs(c)}ms " +
            "soluco_do_laco_ms=${solucoDoLacoMs(c)} soluco_a_cada_ms=${solucoACadaMs(c)} " +
            "emitir_audio=${emitirAudio(c)} tom_de_prova=${tomDeProva(c)} microfone_de_prova=${microfoneDeProva(c)} " +
            "gravar_audio='${gravarAudioEm(c)}' sem_mdns=${semMdns(c)} " +
            "refresh_intra_quadros=${refreshIntraQuadros(c)} " +
            "modo_de_taxa=${modoDeTaxa(c)} giro_resize=${giroResize(c)} " +
            "chaves_de_fornecedor=${chavesDeFornecedor(c)} origem_densa=${origemDensa(c)} " +
            "conteudo_animado=${conteudoAnimado(c)} " +
            "diagnostico_visivel=${diagnosticoVisivel(c)} " +
            "bitrate_kbps=${bitrateKbps(c)} radio_acordado=${radioAcordado(c)} " +
            "escada_kbps=${escadaKbps(c)} " +
            "escada_passo_ms=${escadaPassoMs(c)} janela_do_fio_ms=${janelaDoFioMs(c)} " +
            "janela_do_enlace_ms=${janelaDoEnlaceMs(c)} " +
            "taxa_que_escuta=${taxaQueEscuta(c)} bind_da_camera=${bindDaCamera(c)} " +
            "camera_comum_pelo_camerax=${cameraComumPeloCameraX(c)} " +
            "suspender_previa_na_volta=${suspenderPreviaNaVolta(c)} " +
            "teto_instantaneo=${tetoInstantaneo(c)} " +
            "camera_pelo_mais_novo=${cameraPeloMaisNovo(c)} fila_do_codificador_quadros=${filaDoCodificadorQuadros(c)} " +
            "sem_gravador=${semGravador(c)} gravacao_teto_720=${gravacaoTeto720(c)} " +
            "transmissao_leve=${transmissaoLeve(c)} luma_media=${lumaMedia(c)}"

    private fun prefs(c: Context) =
        c.applicationContext.getSharedPreferences(ARQUIVO, Context.MODE_PRIVATE)
}
