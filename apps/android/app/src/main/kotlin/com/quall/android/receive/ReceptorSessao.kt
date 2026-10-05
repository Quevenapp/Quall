package com.quall.android.receive

import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.audio.ReprodutorDeAudio
import com.quall.android.capture.AnnexB
import com.quall.android.capture.MonotonicClock
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.QuallNative
import org.json.JSONObject
import java.nio.ByteBuffer

/**
 * O outro lado do `MirrorService`: **conecta, pareia, recebe a track e exibe**.
 *
 * `quall_connect` → `quall_session_next_track` → `quall_track_on_frame` → `MediaCodec` →
 * `Surface`. Roda inteiro numa thread própria; a interface só publica no [ReceptorBus] e chama
 * [parar].
 *
 * ## Uma thread só toca a fronteira C
 *
 * `quall_session_next_track` e `quall_session_next_event` **avançam estado** e o header exige que
 * venham de uma thread só. Aqui elas vêm do mesmo laço. A interface nunca toca em handle de
 * sessão ou de track: o único caminho que ela tem para interferir é [parar], que levanta uma
 * bandeira e, atrás de uma trava, aciona o cancelador — a mesma disciplina que `MirrorService`
 * adotou depois do achado do Windows (**nunca chamar a API C com um id que possa estar morto**;
 * lá isso trava o processo para sempre, aqui devolve erro, e a regra vale igual).
 *
 * ## Pedir IDR ao entrar não é otimização, é a diferença entre ter imagem e não ter
 *
 * O primeiro quadro depois de a track abrir se perde em cerca de metade das corridas
 * (`docs/divida-do-nucleo.md`, item 25) — comportamento antecipado pelo desenho, cuja recuperação
 * é o PLI. Um receptor que não pede IDR ao entrar espera o próximo IDR natural do emissor, que
 * com o GOP de 1 s da tela é meio segundo em média e, com um GOP longo, é para sempre. Por isso
 * [pedirIdrAoEntrar] insiste até a track aceitar, em vez de tentar uma vez e desistir — o header
 * avisa que a chamada falha enquanto a track não abriu, e engolir isso em silêncio reproduziria,
 * do lado do receptor, o defeito que o contrato existe para evitar.
 *
 * ## Pedir IDR **na perda** é a outra metade da mesma frase, e ela faltava
 *
 * `docs/contrato-track.md` diz que a casca receptora pede IDR "quando entra na sessão sem ter
 * visto IDR, **ou quando o decoder perde sincronia**". Até esta rodada nenhuma casca do projeto
 * implementava a segunda metade — nem esta. Sem ela, um IDR perdido no rádio deixa o
 * decodificador sem referência até o **próximo IDR programado** do emissor: 1 s na tela, 2 s na
 * câmera.
 *
 * O gatilho é `frames_dropped` do núcleo, e ele é suficiente por um motivo que não é óbvio: um
 * quadro que some inteiro não incrementa nada por si — mas o buraco na sequência é visto no pacote
 * seguinte, que condena o quadro seguinte. Qualquer perda no meio do fluxo produz ao menos um
 * `frames_dropped`. (Até 11/09/2026 havia uma exceção: o quadro que perdia **a cabeça** morria sem
 * contar, porque fragmento sem começo não escreve nada no buffer do núcleo — ver o teste
 * `quadro_que_perde_a_cabeca_conta_como_descartado` em `crates/quall-core/src/rtp.rs`.)
 *
 * **Com piso de intervalo, e o piso não é zelo**: atender um PLI faz o emissor despejar um IDR
 * inteiro em rajada no mesmo rádio que acabou de perder uma rajada. Ver [Bancada.intervaloMinimoIdrMs].
 *
 * ## Supressão é por **causa**, não por relógio — e esta casca tem quatro causas
 *
 * A primeira versão desta política tinha **um** piso e **um** relógio (`ultimoPedidoDeIdr`) para
 * qualquer pedido, e isso é um defeito, não uma simplificação. Quem o mediu foi a frente do
 * desktop, na sonda do Windows: lá há duas origens de PLI e as duas disparam no mesmo soluço — o
 * pedido da fila do decodificador saía primeiro, gastava o orçamento, e a perda de rede, detectada
 * 30 ms depois, esperava os 500 ms inteiros. Três corridas no Dell deram 462 · 519 · 518 ms sem
 * referência, contra 24 e 25 ms na corrida em que a ordem se inverteu.
 *
 * **Um PLI que saiu antes de a perda existir não pode consertá-la, e contá-lo como "já pedi" é
 * contar a resposta errada.** Aqui o problema é maior que no desktop, porque esta casca tem
 * **quatro** origens de pedido — a entrada, o botão manual, a repetição enquanto não há primeira
 * imagem (que o desktop não tem) e a perda — e as três primeiras escreviam no mesmo relógio que a
 * quarta lia.
 *
 * A política agora tem três peças, e cada uma tem motivo:
 *
 * 1. **O relógio da perda é só da perda** ([ultimoPliDePerdaUs]). As outras três causas continuam
 *    com o seu ([ultimoPedidoDeIdr]) e não gastam o orçamento dela.
 * 2. **Dois pisos.** O primeiro pedido de uma perda **nova** tem piso curto
 *    ([Bancada.pisoDoPrimeiroPedidoMs], 100 ms), que é o que limita rajada de perdas distintas; o
 *    piso longo passa a valer só para **insistir** num pedido que ninguém atendeu.
 * 3. **Um IDR que chega sozinho apaga a perda pendente.** Se o GOP do emissor consertou dentro da
 *    janela de supressão — ou se o IDR de outra causa chegou —, pedir seria injetar uma rajada de
 *    IDR por nada. É a metade da supressão que a RFC 4585 não escreve e que a aritmética do
 *    `docs/anomalia-de-sequencia.md` exige: os IDR são 69% dos pacotes.
 *
 * Uma rajada que produza dez `frames_dropped` seguidos vira **um** pedido, e não dez: o piso é
 * sobre o pedido, não sobre a perda.
 *
 * O **tempo sem referência** — da perda detectada até o IDR seguinte chegar — é medido **nos dois
 * braços**, ligado ou desligado. É o número que diz o que o pedido compra: com ele desligado, é o
 * que falta para o IDR programado; com ele ligado, é ida-e-volta do PLI mais o IDR.
 *
 * ## A quinta causa: o descarte na caixa, e ele espera a caixa acalmar
 *
 * Um quadro descartado pela caixa em C — ou tirado dela e jogado fora por não caber no buffer do
 * decodificador — chegou inteiro e o núcleo nunca vai relatá-lo, mas para o decodificador é perda
 * igual. Até 10/09/2026 ele contava ruptura (o que não coube, nem isso) e não pedia nada — a imagem
 * ficava quebrada até o IDR programado, que na tela estendida do Mac vem a cada 10 s. Agora ele anota
 * uma dívida ([DividaDaCaixa]) e o pedido sai quando a caixa passa [calmariaDaCaixaMs] sem descartar
 * — a calmaria do receptor do Windows, onde pedir durante o transbordo alimentou o transbordo. O
 * relógio é o das três primeiras causas ([ultimoPedidoDeIdr]) com o piso longo: é perda **nossa**, e
 * não gasta o orçamento da perda de rede. Um PLI de outra causa que sai durante a dívida a segura, e
 * por isso este pedido é o último da volta.
 *
 * ## Tempo de vida da caixa de quadros
 *
 * A caixa é o `user_data` do tratador registrado no núcleo. Ela só é liberada depois de
 * `quall_track_on_frame(t, NULL, NULL)` **ou** `quall_session_close(s)` devolverem
 * `QUALL_STATUS_OK` — a barreira que a fronteira C passou a dar em 2026-08-26. Se nenhum dos dois
 * der OK, a caixa **vaza de propósito**, com uma linha no logcat: alguns KiB perdidos é preço
 * baixo perto de um tratador escrevendo em memória liberada.
 */
class ReceptorSessao(
    private val eu: DeviceIdentity,
    private val endpoint: String,
    /** `null` quando o par já é conhecido e se quer retomar sem digitar nada. */
    private val pin: String?,
    private val surface: Surface,
    /** Ver [com.quall.android.core.Bancada.pedirIdrNaPerda]. Produto: ligado. */
    private val pedirIdrNaPerda: Boolean = true,
    /** Piso entre **repetições** do pedido, enquanto a mesma perda segue sem resposta. */
    private val intervaloMinimoIdrMs: Long = 500,
    /** Piso antes do **primeiro** pedido de uma perda nova. Ver a doc da classe. */
    private val pisoDoPrimeiroPedidoMs: Long = 100,
    /**
     * Ligado (produto): supressão **por causa**, com relógio próprio da perda e dois pisos.
     * Desligado: a política anterior — um relógio para as quatro causas e um piso só. **Desde
     * 10/09/2026 esse braço se mede com [pedirIdrNaCaixa] desligado**: a quinta causa escreve no
     * mesmo relógio, e com ela ligada o braço deixa de ser a política histórica.
     *
     * Desligar existe por uma razão só, e é de método: o braço "antes" e o braço "depois" precisam
     * rodar no **mesmo binário**, no mesmo aparelho, intercalados. Dois APKs não seriam uma
     * comparação, seriam duas medições.
     */
    private val supressaoPorCausa: Boolean = true,
    /**
     * Se o descarte **na caixa** pede IDR depois de a caixa acalmar. Produto: ligado. Desligado, a
     * dívida continua contada e só o pedido não sai — os dois braços do A/B têm o mesmo relato.
     * Ver [DividaDaCaixa].
     */
    private val pedirIdrNaCaixa: Boolean = true,
    /** Quanto a caixa fica sem descartar antes de o pedido sair. Ver [DividaDaCaixa]. */
    private val calmariaDaCaixaMs: Long = 500,
    /** **Bancada**: soluço provocado no laço. `0` (produto) desliga. Ver [com.quall.android.core.Bancada.solucoDoLacoMs]. */
    private val solucoDoLacoMs: Long = 0,
    private val solucoACadaMs: Long = 3_000,
    /**
     * A porta que **não entrega à tela** um quadro cuja referência foi condenada.
     *
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
     * Ver [com.quall.android.core.Bancada.congelarNaRuptura].
     */
    private val congelarNaRuptura: Boolean = false,
    /**
     * **Braço de controle do anel de reordenação.** `-1` (produto) não toca em nada e o anel
     * segue se ajustando ao regime da rede. Qualquer valor `>= 0` crava a profundidade e
     * desliga o ajuste.
     *
     * Ver [com.quall.android.core.Bancada.profundidadeDoAnel] para por que ele precisou
     * existir — e é a mesma razão de método que criou [supressaoPorCausa]: os dois braços
     * precisam rodar no mesmo binário e no mesmo enlace, senão não são uma comparação.
     */
    private val profundidadeDoAnel: Int = -1,
    /**
     * **Bancada: prende a mídia e a sinalização a uma interface local**, pelo endereço IPv4.
     * Vazio (produto) usa todas.
     *
     * Ver [com.quall.android.core.Bancada.prenderEm] para os dois braços de bancada que ele
     * custou.
     */
    private val prenderEm: String = "",
    /**
     * Pasta onde esta sessão deixa um **arquivo de relato**, ou vazio para não deixar nenhum.
     *
     * Ver [arquivarRelato]. Quem passa é a `ReceptorActivity`, com `getExternalFilesDir` — o
     * contêiner do app que o `adb pull` alcança sem `run-as` e sem root.
     */
    private val relatoEm: String = "",
    /**
     * Caminho de um `.wav` para a bancada gravar o áudio decodificado, ou vazio.
     *
     * **Vazio no produto, e o motivo não é economia.** Ver [com.quall.android.audio.EscritorDeWav]
     * e `docs/audio.md` §8: o som que atravessa uma sessão de produto é o som da máquina do outro
     * lado, e a forma mais barata de nunca vazar é não ter para onde gravar. A bancada só liga
     * isto com o **tom sintético** do `quall-probe` do outro lado.
     */
    private val gravarAudioEm: String = "",
    /**
     * Período da janela do enlace, em ms. `0` desliga (produto).
     *
     * **O piso efetivo é 500 ms**, e não é escolha: a janela fecha dentro do bloco periódico que
     * já existia neste laço, e ele acorda a cada 500 ms. Pedir 200 ms aqui daria janelas de 500.
     * Fica dito porque um controlador projetado contra uma janela que ele acha ser de 200 ms
     * estaria projetado contra outra coisa.
     *
     * Isso não é limitação onde importa. A rajada que destrói um IDR dura menos de um segundo, e
     * **nenhum** controlador de taxa chega a tempo de salvá-la — quem responde a ela é o pedido de
     * IDR, que já tem piso de 100 ms. O que um controlador de taxa pode fazer é reduzir a chance
     * da **próxima**, e para isso meio segundo é rápido e 100 ms seria ruído.
     */
    private val janelaDoEnlaceMs: Long = 0,
    /**
     * Os pixels do painel deste aparelho (largura, altura), ditos ao emissor no aperto de mão.
     * `0 to 0` é "não digo". Ver `QuallNative.connectStart`.
     */
    private val telaDoAparelho: Pair<Int, Int> = 0 to 0,
) {

    companion object {
        private const val TAG = "QuallReceptor"

        /** Prazo total de `quall_connect`: aceitar, parear e o transporte subir. */
        private const val PRAZO_CONEXAO_MS = 30_000

        /** Quanto esperar pela primeira track do emissor depois de a sessão subir. */
        private const val PRAZO_PRIMEIRA_TRACK_MS = 15_000

        /**
         * Com a track de áudio já em mãos, quanto ainda se espera pela de vídeo.
         *
         * As duas tracks de uma sessão de produto entram na **mesma** oferta SDP, então a segunda
         * chega em milissegundos depois da primeira, não em segundos. 2 s é folga de três ordens
         * de grandeza; passado isso, a sessão é de áudio só — que é o que a sonda
         * `quall-probe emitir-audio` manda, e o que um emissor sem tela mandaria.
         */
        private const val ESPERA_PELO_VIDEO_MS = 2_000L

        /** Por quanto tempo insistir no pedido de IDR de entrada até a track aceitar. */
        private const val INSISTIR_IDR_MS = 3_000

        /**
         * Sem nenhum quadro chegando e sem imagem ainda, pedir IDR de novo a cada tanto. É o
         * caso em que o IDR de entrada se perdeu junto com o primeiro quadro.
         */
        private const val REPETIR_IDR_MS = 700L

        /** Silêncio total que conta como "o emissor sumiu", quando nem o detector de queda falou. */
        const val SILENCIO_ATE_DESISTIR_MS = 10_000L

        /** Teto de um quadro na área de espera, antes de o decodificador existir. */
        private const val ESPERA_BYTES = 1 shl 20

        /**
         * Quanto o laço espera por um quadro novo em cada volta. Ver o comentário no uso: como o
         * dreno do decodificador acontece depois desta espera, ela entra direto na latência de
         * exibição.
         */
        private const val ESPERA_POR_QUADRO_MS = 4

        /**
         * De quanto em quanto tempo o laço lê `frames_dropped` do núcleo para saber se houve
         * perda no meio do fluxo. É uma serialização de JSON por leitura, na thread do receptor:
         * a 100 ms são 10 por segundo, contra 30 quadros — abaixo do ruído, e fino o bastante
         * para não somar meio GOP de atraso ao pedido.
         */
        private const val OLHAR_PERDA_MS = 100L

        /**
         * Por quanto tempo, no máximo, a tela fica com o último quadro bom esperando um IDR
         * depois de uma ruptura.
         *
         * A válvula existe porque **um emissor que não reinjeta IDR sob pedido existiu de verdade
         * nesta bancada**: o `quall-app.exe` de 27/08 pôs um único IDR na sessão inteira contra 54
         * pedidos (`docs/matriz-ios.md`). Contra um emissor assim, segurar sem prazo trocaria uma
         * imagem suja por uma imagem parada, que é pior. 2 s é o mesmo valor do receptor iOS, e o
         * dobro do piso longo entre pedidos com folga para o ida e volta.
         */
        private const val CONGELAR_NO_MAXIMO_MS = 2_000L

        /** Quantos arquivos de relato ficam guardados no contêiner. Ver `arquivoDoRelato`. */
        private const val TETO_DE_RELATOS = 20
    }

    @Volatile private var pararPedido = false
    private val cancelLock = Any()
    @Volatile private var cancellerHandle = 0L

    /** Instante do pedido manual de IDR, para medir a recuperação. `0` quando não há pedido. */
    @Volatile private var pedidoManualEm = 0L

    /** `true` entre o toque em "Pedir IDR" e o PLI ter saído de fato. */
    @Volatile private var pedidoManualPorEnviar = false
    @Volatile var recuperacaoMs = 0.0
        private set

    /**
     * Perdas **distintas**: quantas vezes uma perda nova ficou pendente. Uma rajada que produz dez
     * `frames_dropped` seguidos conta **um**, porque é um evento e vira um pedido.
     *
     * Não é comparável ao contador de mesmo nome da rodada anterior, que contava **voltas de
     * sondagem com subida** — o que misturava rajada com evento. [quadrosPerdidosVistos] é o que
     * mais se parece com aquele número.
     */
    @Volatile var eventosDePerda = 0L
        private set

    /** Soma das subidas de `frames_dropped`, sem agrupar rajada. */
    @Volatile var quadrosPerdidosVistos = 0L
        private set

    /** Quantos PLI saíram **por causa de perda** — não conta o de entrada, o botão nem a repetição. */
    @Volatile var pedidosPorPerda = 0L
        private set

    /**
     * Perdas pendentes que um IDR resolveu **sem** pedido nenhum — o GOP do emissor chegou primeiro,
     * ou o IDR de outra causa chegou. Cada uma destas é uma rajada de IDR que não foi injetada no
     * rádio, e é o que a supressão compra.
     */
    @Volatile var perdasResolvidasSemPedido = 0L
        private set

    /** Voltas em que havia perda pendente e o piso segurou o pedido. */
    @Volatile var perdasSuprimidas = 0L
        private set

    /**
     * Amostras de **tempo sem referência**: da perda detectada ao IDR seguinte. Medido nos dois
     * braços — é o que diz o que o pedido compra.
     */
    private val semReferenciaMs = ArrayList<Double>()

    /** A derivada do dano, janela a janela. Ver [JanelaDoEnlace]. */
    private val janelaDoEnlace = JanelaDoEnlace()

    /** Relatos que a sinalização recusou. Só para não repetir o aviso a cada janela. */
    private var relatosRecusados = 0

    private var decoder: H264Decoder? = null

    /**
     * A track de áudio, e quem a toca. `0`/`null` quando o emissor não mandou som — que é o caso
     * de todo emissor deste projeto antes desta rodada, e continua sendo o de qualquer par antigo.
     *
     * O handle é liberado por [exibir], **depois** de [pararAudio]: o desligamento do tratador é
     * barreira e escoa o buffer, e para isso a track precisa estar viva.
     */
    @Volatile private var trackDeAudio = 0L
    @Volatile private var reprodutor: ReprodutorDeAudio? = null

    /**
     * Para a sessão. Chamável de qualquer thread — mas ela **não** toca em handle de sessão, de
     * track nem na caixa de quadros: levanta a bandeira e, se houver espera em curso, aciona o
     * cancelador atrás da trava que [rodar] usa para zerá-lo.
     */
    fun parar() {
        pararPedido = true
        synchronized(cancelLock) {
            if (cancellerHandle != 0L) QuallNative.sessionCancel(cancellerHandle)
        }
    }

    /** Pede um IDR agora e mede quanto tempo até a imagem voltar. Só vale enquanto exibe. */
    fun pedirIdrAgora() {
        pedidoManualEm = MonotonicClock.micros()
        pedidoManualPorEnviar = true
    }

    // -------------------------------------------------------------------------------------

    fun rodar() {
        if (!QuallNative.carregado) {
            erro(ReceptorBus.Aviso.NUCLEO_NAO_CARREGOU, QuallNative.erroDeCarga.toString())
            return
        }

        ReceptorBus.publicar(
            ReceptorBus.Estado(
                fase = ReceptorBus.Fase.CONECTANDO,
                endpoint = endpoint,
                aviso = if (pin == null) ReceptorBus.Aviso.RETOMANDO else ReceptorBus.Aviso.CONECTANDO_E_PAREANDO,
            )
        )

        val canceller = QuallNative.cancellerNew()
        synchronized(cancelLock) { cancellerHandle = canceller }

        val sessao = QuallNative.connectStart(
            endpoint = endpoint,
            deviceId = eu.deviceId,
            displayName = eu.displayName,
            // Este aparelho, nesta sessão, é sumidouro: ele exibe, não transmite.
            caps = QuallNative.CAP_SINK,
            pin = pin,
            knownPeersJson = eu.knownPeersJson(),
            timeoutMs = PRAZO_CONEXAO_MS,
            cancellerHandle = canceller,
            // Vazio vira `null`: o núcleo trata nulo como "todas as interfaces", que é o produto.
            bindAddress = prenderEm.ifBlank { null },
            telaLarguraPx = telaDoAparelho.first,
            telaAlturaPx = telaDoAparelho.second,
        )
        // O cancelador some da vista assim que a chamada bloqueante volta: daqui em diante
        // `parar()` age só pela bandeira, e nunca com um handle já liberado.
        synchronized(cancelLock) { cancellerHandle = 0L }

        if (sessao == 0L) {
            // Os dois são **por thread**, e esta é a thread que falhou. O status vem **antes** do
            // texto: nenhuma das duas leituras limpa o valor, mas ler o código primeiro é a ordem
            // que continua certa se algum dia uma delas passar a chamar a fronteira de novo.
            val status = QuallNative.lastStatus()
            val motivo = QuallNative.lastError()
            QuallNative.cancellerFree(canceller)
            if (pararPedido || status == QuallNative.Status.CANCELLED) {
                ReceptorBus.publicar(ReceptorBus.Estado(fase = ReceptorBus.Fase.PARADO, aviso = ReceptorBus.Aviso.CANCELADO))
                return
            }
            // `NEEDS_PIN` "não é recusa, é convite a recomeçar" (dívida 22): o par esqueceu este
            // aparelho, e o caminho é a tela de PIN, não uma mensagem de falha. Até esta rodada a
            // casca não sabia distinguir isso de "IP errado" sem comparar prefixo de string em
            // português — que é o defeito que fez `QUALL_STATUS_NO_ROUTE` existir.
            when (status) {
                QuallNative.Status.NEEDS_PIN -> ReceptorBus.publicar(
                    ReceptorBus.Estado(
                        fase = ReceptorBus.Fase.PRECISA_DE_PIN,
                        endpoint = endpoint,
                        aviso = ReceptorBus.Aviso.PRECISA_DE_PIN,
                    )
                )
                QuallNative.Status.NO_ROUTE -> erro(ReceptorBus.Aviso.SEM_ROTA)
                QuallNative.Status.TIMEOUT -> erro(ReceptorBus.Aviso.SEM_RESPOSTA, endpoint)
                else -> erro(ReceptorBus.Aviso.NAO_CONECTOU, motivo)
            }
            return
        }
        QuallNative.cancellerFree(canceller)

        try {
            exibir(sessao)
        } catch (e: Throwable) {
            Log.e(TAG, "recepção morreu", e)
            erro(ReceptorBus.Aviso.RECEPCAO_MORREU, "${e.javaClass.simpleName}: ${e.message}")
        } finally {
            // A sessão fecha aqui, na thread do laço — nunca de dentro de um tratador, que o
            // header diz ser o caso em que a barreira recusa esperar (`QUALL_STATUS_INVALID`).
            val st = QuallNative.sessionClose(sessao)
            if (st != QuallNative.Status.OK) {
                Log.w(TAG, "quall_session_close: ${QuallNative.Status.nome(st)}")
            }
        }
    }

    // -------------------------------------------------------------------------------------

    private fun exibir(sessao: Long) {
        val subiuEm = MonotonicClock.micros()

        val parJson = QuallNative.sessionPeerJson(sessao)
        // Vazio quando o par não disse nome: a tela põe "emissor" no idioma dela (`rx_par_sem_nome`).
        val parNome = runCatching { JSONObject(parJson).optString("display_name") }
            .getOrNull()?.takeIf { it.isNotBlank() }.orEmpty()
        val novo = QuallNative.sessionPairingIsNew(sessao)

        // Persistido assim que a sessão sobe, e não no fim: se o app morrer no meio, o
        // pareamento já vale e a próxima conexão não pede PIN. Mesma regra do lado emissor.
        runCatching { QuallNative.sessionKnownPeersJson(sessao, eu.knownPeersJson()) }
            .getOrNull()
            ?.let { eu.saveKnownPeersJson(it) }

        ReceptorBus.atualizar {
            it.copy(
                fase = ReceptorBus.Fase.EXIBINDO,
                par = parNome,
                pareamentoNovo = novo,
                aviso = ReceptorBus.Aviso.ESPERANDO_A_IMAGEM,
                detalhe = "",
            )
        }

        // --- as tracks do outro lado -------------------------------------------------------
        //
        // Uma sessão de produto tem **duas**: tela e som. `proxima_track` entrega na ordem em que
        // a libdatachannel as abre, e essa ordem não é determinística — a sonda de bancada já
        // tinha aprendido isso e drena as que não servem
        // (`quall-probe`, `esperar_track`). Aqui a colheita separa por espécie em vez de pegar a
        // primeira, e o vídeo continua sendo o que decide quando o laço começa.
        var track = 0L
        var limiteTrack = MonotonicClock.micros() + PRAZO_PRIMEIRA_TRACK_MS * 1000L
        while (!pararPedido && track == 0L && MonotonicClock.micros() < limiteTrack) {
            val t = QuallNative.sessionNextTrack(sessao, 200)
            if (t == 0L) continue
            val kind = QuallNative.trackKind(t)
            if (QuallNative.TrackKind.eAudio(kind)) {
                if (trackDeAudio == 0L) {
                    trackDeAudio = t
                    iniciarAudio(t, kind)
                    // Com áudio em mãos, o vídeo tem uma janela curta para aparecer. Passada
                    // ela, a sessão é de áudio só — que é o caso da sonda `emitir-audio`, e
                    // também o de um emissor que mande só som.
                    limiteTrack = minOf(
                        limiteTrack,
                        MonotonicClock.micros() + ESPERA_PELO_VIDEO_MS * 1000L,
                    )
                } else {
                    // Segunda track de áudio: solta. Segurá-la manteria um receptor vivo para um
                    // fluxo que ninguém lê — o mesmo argumento da sonda.
                    Log.w(TAG, "ignorando uma segunda track de áudio (kind=$kind)")
                    QuallNative.trackFree(t)
                }
            } else {
                track = t
            }
        }
        if (track == 0L && trackDeAudio == 0L) {
            if (!pararPedido) erro(ReceptorBus.Aviso.SEM_TRACK, parNome)
            return
        }

        if (track == 0L) {
            // Sessão de áudio só: não há quadro para decodificar, e o laço de vídeo passaria dez
            // segundos esperando um quadro que não vem para então declarar silêncio.
            try {
                lacoSomenteAudio(sessao)
            } finally {
                pararAudio()
                if (trackDeAudio != 0L) QuallNative.trackFree(trackDeAudio)
            }
            return
        }

        val rotulo = QuallNative.trackLabel(track).ifBlank {
            when (QuallNative.trackKind(track)) {
                QuallNative.TrackKind.CAMERA -> "câmera" // i18n-fora: rótulo do diário e do painel de números (bancada); o emissor do Quall sempre manda o dele
                else -> "tela"
            }
        }
        Log.i(TAG, "track recebida: $rotulo (kind=${QuallNative.trackKind(track)})")
        // **Por onde a mídia está indo.** Uma corrida "pelo cabo" pode fechar pela Wi-Fi e
        // parecer sucesso: aconteceu em 01/09/2026 e o braço foi anulado. A linha não diz
        // "cabo" nem "Wi-Fi" — diz o endereço que o ICE escolheu, e quem compara com o
        // enlace que pediu é a bancada.
        Log.i(TAG, "caminho da mídia: ${QuallNative.sessionPathJson(sessao)}")

        // **Braço de controle do anel de reordenação.** `-1` (o padrão) não toca em nada e o anel
        // segue se ajustando ao regime da rede, que é o produto. Qualquer valor `>= 0` crava a
        // profundidade e desliga o ajuste — é o que permite medir "anel fixo em 16" contra "anel
        // adaptativo" **no mesmo enlace**, em vez de comparar corridas de dias diferentes, que
        // este repositório já disse três vezes que não se comparam em 2,4 GHz.
        val anel = profundidadeDoAnel
        if (anel >= 0) {
            val ok = QuallNative.trackSetReorderDepth(track, anel)
            Log.w(TAG, "BANCADA: anel de reordenação cravado em $anel pacote(s) — aceito=$ok")
        }

        // --- o tratador de quadro, e a caixa que ele alimenta -------------------------------
        val caixa = QuallNative.frameBoxNew()
        if (caixa == 0L) {
            pararAudio()
            if (trackDeAudio != 0L) QuallNative.trackFree(trackDeAudio)
            QuallNative.trackFree(track)
            erro(ReceptorBus.Aviso.SEM_CAIXA)
            return
        }
        val stRegistro = QuallNative.trackOnFrame(track, caixa)
        if (stRegistro != QuallNative.Status.OK) {
            // Nunca registrou: a caixa não é `user_data` de ninguém e pode ir embora agora.
            QuallNative.frameBoxFree(caixa)
            pararAudio()
            if (trackDeAudio != 0L) QuallNative.trackFree(trackDeAudio)
            QuallNative.trackFree(track)
            erro(ReceptorBus.Aviso.TRATADOR_RECUSADO, QuallNative.Status.nome(stRegistro))
            return
        }

        // **O controle da câmera do outro lado** (R9b, `docs/controle-remoto-da-camera.md`): um
        // `QuallCameraRemote` por sessão de vídeo, bombeado numa thread própria — o leitor único do canal
        // de dados desta sessão (§2). A tela lê o estado e manda os gestos pelo [CameraRemotaBus].
        val camera = ControleDaCameraRemota.abrir(sessao) { !pararPedido }
        try {
            laco(sessao, track, caixa, subiuEm, rotulo)
        } finally {
            // A bombeada da câmera sai antes de a sessão fechar (o handle das mensagens sobrevive a ela,
            // mas o controle é liberado só com a thread fora dele).
            camera?.fechar()
            // O áudio sai **antes** do vídeo, e antes de qualquer `trackFree`: o desligamento
            // dele é barreira e escoa o buffer, e a track precisa estar viva para isso.
            pararAudio()
            if (trackDeAudio != 0L) QuallNative.trackFree(trackDeAudio)
            // 1. Desligar o tratador **com barreira**. Só `OK` autoriza liberar a caixa.
            val stDesligar = QuallNative.trackOnFrame(track, 0L)
            val caixaLiberavel = stDesligar == QuallNative.Status.OK
            if (!caixaLiberavel) {
                Log.e(TAG, "desregistro do tratador voltou ${QuallNative.Status.nome(stDesligar)} — não libero a caixa")
            }
            decoder?.fechar()
            decoder = null
            // 2. A track vai embora **antes** da sessão, como o header manda. Depois disto o
            //    handle está morto e ninguém mais o toca — nem para ler contador.
            QuallNative.trackFree(track)
            // 3. `sessionClose` acontece no `finally` de `rodar`, e também é barreira: se o
            //    desregistro falhou, ela ainda pode autorizar. Mas a ordem obriga a decidir
            //    aqui, então o caso "falhou" vaza de propósito e diz que vazou.
            if (caixaLiberavel) {
                QuallNative.frameBoxFree(caixa)
            } else {
                Log.e(TAG, "caixa de quadros vazada de propósito (alguns KiB) — ver a doc da classe")
            }
        }
    }

    private fun laco(sessao: Long, track: Long, caixa: Long, subiuEm: Long, rotulo: String) {
        val espera = ByteBuffer.allocateDirect(ESPERA_BYTES)
        val meta = LongArray(6)

        var primeiroIdrUs = 0L
        var primeiraImagemUs = 0L
        var quadrosAntesDoIdr = 0L
        var pedidosEnviados = 0L
        var ultimaChegada = MonotonicClock.micros()
        var ultimoPedidoDeIdr = 0L
        var ultimoRelato = 0L
        var spsInfo: Sps.Info? = null
        /** Por que o laço saiu sem ninguém pedir; o detalhe é [rotulo]. */
        var motivoDaSaida = ReceptorBus.Aviso.NENHUM

        /** `-1` até a primeira leitura, que só fixa a linha de base e nunca conta como perda. */
        var ultimoFramesDropped = -1L
        var ultimaOlhadaNaPerda = 0L
        /** Instante da perda ainda não coberta por um IDR. `0` quando não há nenhuma pendente. */
        var perdaEm = 0L
        /** Já saiu um PLI **para esta perda**? Enquanto for `false`, vale o piso curto. */
        var pediuPorEstaPerda = false
        /**
         * Relógio **da causa perda**, separado de [ultimoPedidoDeIdr] de propósito: um PLI que saiu
         * pela entrada, pelo botão ou pela repetição não pode consertar uma perda que ainda nem
         * existia, e contá-lo como "já pedi" é contar a resposta errada. Ver a doc da classe.
         */
        var ultimoPliDePerdaUs = 0L

        // -----------------------------------------------------------------------------------
        // **A testemunha que faltava: quadro exibido com a referência quebrada.**
        //
        // Todo contador desta casca conta **entrega** — `recebidos`, `enfileirados`,
        // `descartados_na_caixa`, `packets_lost_for_real`, `frames_dropped`. Nenhum contava se a
        // imagem entregue está **certa**. Um quadro P que chega inteiro, decodifica sem erro e sai
        // visualmente podre — porque a referência dele foi descartada por uma perda anterior —
        // conta como sucesso em **todas** as linhas. É "a imagem está falhando" contra "0 falhas".
        //
        // Esta casca já detectava a ruptura desde a rodada anterior, e a usava **só** para pedir
        // IDR: consertava a recuperação e não consertava o que se mostra até ela chegar, nem
        // contava. Os nomes abaixo são os de `docs/contrato-track.md` e são literais.
        //
        // **A granularidade aqui é o quadro, não a volta do laço** — e é a diferença desta casca
        // para o receptor iOS, que condena a 20 Hz e por isso subestima (ver §7 de
        // `docs/ipad-destravado.md`). O que tornou isso possível não foi desenho, foi preço: até
        // 31/08 este contador era lido desserializando o JSON de estatísticas, caro demais para
        // rodar por quadro, e por isso a olhada era a cada 100 ms — três quadros a 30 fps. Com
        // `QuallNative.trackFramesDropped` custando uma trava e um `u64`, a pergunta cabe em todo
        // quadro. O resíduo de granularidade que **sobra** está medido e dito: ver `profundidade`.
        var cadeiaCondenada = false
        var rupturas = 0L
        var suspeitos = 0L
        var suspeitosNaRajada = 0L
        var piorRajada = 0L
        var condenadaDesdeUs = 0L
        /** Linha de base do contador de descarte, **só** da condenação. Ver [framesDropped]. */
        var descartadosNaCondenacao = -1L
        /**
         * Linha de base do que **a caixa local** jogou fora — descartado (`meta[3]`) mais o que não
         * coube no buffer do decodificador (`meta[5]`) —, a segunda origem de ruptura.
         */
        var descartadosNaCaixa = -1L
        /** O pedido que o descarte na caixa deve. Ver a doc da classe. */
        val dividaDaCaixa = DividaDaCaixa(calmariaUs = calmariaDaCaixaMs * 1000)
        var ultimoSolucoUs = 0L
        var solucos = 0L
        if (solucoDoLacoMs > 0) {
            Log.w(TAG, "BANCADA: soluço de $solucoDoLacoMs ms a cada $solucoACadaMs ms no laço — descarte na caixa de propósito")
        }

        Log.i(
            TAG,
            "braço da corrida: pedir_idr_na_perda=$pedirIdrNaPerda " +
                "supressao_por_causa=$supressaoPorCausa congelar_na_ruptura=$congelarNaRuptura " +
                "piso_curto=${pisoDoPrimeiroPedidoMs}ms piso_longo=${intervaloMinimoIdrMs}ms " +
                "pedir_idr_na_caixa=$pedirIdrNaCaixa calmaria_da_caixa=${calmariaDaCaixaMs}ms",
        )

        pedidosEnviados += pedirIdrAoEntrar(track)
        ultimoPedidoDeIdr = MonotonicClock.micros()

        while (!pararPedido) {
            // O detector de queda, com prazo zero: ele olha a sinalização, que sabe em
            // milissegundos, em vez de esperar o `CONSENT_TIMEOUT` de 30 s do libjuice.
            when (QuallNative.sessionNextEvent(sessao, 0)) {
                QuallNative.SessionEvent.DISCONNECTED -> {
                    motivoDaSaida = ReceptorBus.Aviso.EMISSOR_SAIU
                    break
                }

                QuallNative.SessionEvent.FAILED -> {
                    motivoDaSaida = ReceptorBus.Aviso.TRANSPORTE_FALHOU
                    break
                }
            }

            val d = decoder
            var tamanho: Int
            if (d == null) {
                // Antes do decodificador existir, o quadro vai para a área de espera e é lido:
                // só uma unidade de acesso com SPS (+PPS) e IDR pode abrir o decodificador.
                tamanho = QuallNative.frameBoxTake(caixa, espera, meta, 20)
                if (tamanho > 0) {
                    ultimaChegada = MonotonicClock.micros()
                    if (meta[1] == 1L && primeiroIdrUs == 0L) {
                        primeiroIdrUs = MonotonicClock.micros() - subiuEm
                    }
                    val info = Sps.ler(espera, 0, tamanho)
                    val csd = H264Decoder.extrairCsd(espera, tamanho)
                    val temIdr = AnnexB.nalTypes(espera, 0, tamanho).contains(AnnexB.NAL_IDR)
                    if (info != null && csd != null && temIdr) {
                        spsInfo = info
                        val novo = H264Decoder(surface)
                        // **O tamanho novo vai à tela na hora** (o controle da troca de 21/09): o
                        // codec troca de tamanho dentro do fluxo sem reabrir (medido no S24 e no
                        // tablet), e a superfície esticava até o relato seguinte.
                        novo.aoMudarDeTamanho = { l, a ->
                            ReceptorBus.atualizar {
                                if (it.fase == ReceptorBus.Fase.EXIBINDO) it.copy(largura = l, altura = a) else it
                            }
                        }
                        novo.abrir(csd, info.largura, info.altura)
                        decoder = novo
                        // A linha de base da caixa é **deste** quadro, e não da primeira tirada
                        // depois dele: abrir o codec leva tempo, e a caixa de 4 posições (66 ms a
                        // 60 fps) pode descartar os P seguintes nesse meio — uma base tardia os
                        // engoliria sem ruptura e sem dívida. Tudo o que foi contado até aqui é
                        // anterior a este IDR (a caixa descarta o mais velho). Achado da revisão
                        // de 10/09/2026.
                        descartadosNaCaixa = meta[3] + meta[5]
                        // O mesmo quadro que abriu o decodificador é o primeiro a entrar nele.
                        val idx = novo.entradaLivre(200_000)
                        val buf = if (idx >= 0) novo.bufferDeEntrada(idx) else null
                        if (buf != null) {
                            buf.clear()
                            // Conferir antes de copiar, e não descobrir por exceção: este é o
                            // único ponto do receptor em que o quadro vai para o `ByteBuffer` do
                            // codec **sem** passar pela conferência de capacidade que
                            // `frameBoxTake` faz em C. Um `put` maior que o buffer levanta
                            // `BufferOverflowException` e derruba a sessão inteira com "recepção
                            // morreu" — perder o primeiro IDR e pedir outro é infinitamente
                            // melhor. Registrado como aresta em `docs/bancada.md` (26/08) e nunca
                            // observado no SM-X230; um aparelho de buffers apertados acharia.
                            if (buf.capacity() < tamanho) {
                                Log.w(
                                    TAG,
                                    "o buffer de entrada do decodificador (${buf.capacity()} B) " +
                                        "não cabe o primeiro IDR ($tamanho B) — descartado, pedindo outro",
                                )
                                // O decodificador fica **aberto**: ele já está configurado com o
                                // SPS/PPS certos, e o próximo IDR (o `pedirIdrAoEntrar` do laço
                                // insiste) entra por `frameBoxTake`, que confere capacidade em C
                                // e devolve -2 em vez de estourar.
                                quadrosAntesDoIdr++
                                espera.clear()
                            } else {
                                espera.limit(tamanho)
                                espera.position(0)
                                buf.put(espera)
                                espera.clear()
                                novo.enfileirar(idx, tamanho, MonotonicClock.micros())
                            }
                        }
                    } else {
                        // Quadro P (ou IDR sem parâmetros) antes de qualquer SPS: descartar é a
                        // única coisa correta — alimentar o decodificador com ele é o caminho
                        // conhecido para travá-lo de vez (achado do receptor Windows no M2).
                        quadrosAntesDoIdr++
                        espera.clear()
                    }
                }
            } else {
                // BANCADA: parar de tirar da caixa enquanto o núcleo segue enchendo. Ver
                // [com.quall.android.core.Bancada.solucoDoLacoMs].
                if (solucoDoLacoMs > 0 && primeiraImagemUs > 0L) {
                    val t = MonotonicClock.micros()
                    if (ultimoSolucoUs == 0L) {
                        ultimoSolucoUs = t
                    } else if (t - ultimoSolucoUs >= solucoACadaMs * 1000) {
                        ultimoSolucoUs = t
                        solucos++
                        Thread.sleep(solucoDoLacoMs)
                    }
                }
                val idx = d.entradaLivre(2_000)
                if (idx < 0) {
                    d.drenar()
                    continue
                }
                val buf = d.bufferDeEntrada(idx)
                if (buf == null) {
                    d.drenar()
                    continue
                }
                buf.clear()
                // Prazo curto de propósito: `drenar()` só roda quando esta chamada volta, então
                // o prazo daqui é **piso da latência de exibição** — um quadro pronto no
                // decodificador espera até este tanto para ir à tela. Medido no SM-X230: com
                // 10 ms, decode p50 = 22,7 ms; o custo de encurtar é CPU em vigília.
                tamanho = QuallNative.frameBoxTake(caixa, buf, meta, ESPERA_POR_QUADRO_MS)
                if (tamanho == -2 && meta[1] == 1L) {
                    // O quadro que não coube vira ruptura na tirada seguinte (`meta[5]`, abaixo).
                    // Ser um IDR é o caso que merece linha: o pedido de IDR vai trazer outro do
                    // mesmo tamanho, e a `DividaDaCaixa` recua em vez de insistir a cada segundo.
                    Log.w(TAG, "um IDR não coube no buffer de entrada do decodificador (${buf.capacity()} B)")
                }
                if (tamanho > 0) {
                    ultimaChegada = MonotonicClock.micros()

                    // --- a condenação da cadeia de referência, **por quadro** -----------------
                    //
                    // Lido agora, e não na volta de 100 ms: entre a ruptura e a leitura tardia
                    // todo quadro conta como bom, e o rastro que o usuário vê mora exatamente aí.
                    //
                    // O resíduo que sobra é a **profundidade da caixa**: o quadro tirado agora
                    // pode ter sido enfileirado pelo núcleo há alguns quadros, e um descarte
                    // ocorrido depois dele já apareceria nesta leitura. O erro, então, é para o
                    // lado de condenar **cedo demais** — o oposto do iOS, que condena tarde e
                    // subestima. `descartados_na_caixa` e `recebidos` na linha de relato dizem o
                    // tamanho desse resíduo em cada corrida; não é suposição.
                    val agoraNoQuadro = MonotonicClock.micros()
                    var rompeu = false
                    val descartadosAgora = framesDropped(track)
                    if (descartadosAgora >= 0) {
                        if (descartadosNaCondenacao < 0) {
                            descartadosNaCondenacao = descartadosAgora
                        } else if (descartadosAgora > descartadosNaCondenacao) {
                            descartadosNaCondenacao = descartadosAgora
                            rompeu = true
                        }
                    }
                    // **A segunda origem de ruptura, e o núcleo nunca vai relatá-la.**
                    //
                    // `frames_dropped` conta o que o *depacotizador* jogou fora por incompleto.
                    // Estes quadros chegaram inteiros: quem os jogou fora foi a caixa em C, aqui
                    // deste lado, porque o laço não deu conta de tirá-los antes de o anel encher.
                    // Para o decodificador o efeito é idêntico — o quadro seguinte referencia
                    // algo que nunca foi decodificado.
                    //
                    // Não é hipótese: a primeira corrida suja desta rodada (A10s → SM-X230,
                    // 4,3 % de perda) fechou com `descartados_na_caixa=18` ao lado de
                    // `frames_dropped=126`. Sem esta linha, dezoito rupturas reais ficariam fora
                    // de `rupturas` e os quadros seguintes a elas fora de `suspeitos`.
                    //
                    // Esta origem é **exata e por quadro**; a de cima tem o resíduo da caixa.
                    //
                    // Desde 10/09/2026 ela soma o que não coube no buffer do decodificador
                    // (`nao_couberam`): a caixa tirou o quadro e o jogou fora, e para a cadeia é o
                    // mesmo buraco. Até aqui ele não contava ruptura nenhuma.
                    val jogadosNaCaixa = meta[3] + meta[5]
                    if (descartadosNaCaixa < 0) {
                        descartadosNaCaixa = jogadosNaCaixa
                    } else if (jogadosNaCaixa > descartadosNaCaixa) {
                        descartadosNaCaixa = jogadosNaCaixa
                        rompeu = true
                        // Só anota a dívida; o pedido espera a caixa acalmar, lá embaixo.
                        dividaDaCaixa.notarDescarte(agoraNoQuadro)
                    }
                    if (rompeu) {
                        rupturas++
                        if (!cadeiaCondenada) condenadaDesdeUs = agoraNoQuadro
                        cadeiaCondenada = true
                    }
                    if (meta[1] != 1L && cadeiaCondenada) {
                        suspeitos++
                        suspeitosNaRajada++
                        // A válvula. Sem ela, um emissor que não reinjeta IDR sob pedido congela
                        // a tela para sempre — e esse emissor existiu de verdade nesta bancada
                        // (o `quall-app.exe` de 27/08: um IDR na sessão inteira contra 54
                        // pedidos). Trocar imagem suja por imagem parada é trocar por pior.
                        if (condenadaDesdeUs != 0L &&
                            agoraNoQuadro - condenadaDesdeUs > CONGELAR_NO_MAXIMO_MS * 1000
                        ) {
                            // O intervalo entra na conta do mesmo jeito: ele não terminou porque
                            // a imagem se curou, terminou porque desistimos de esperar, e
                            // esconder o pior caso é o oposto do que este contador existe para
                            // fazer.
                            if (semReferenciaMs.size < 4000) {
                                semReferenciaMs.add((agoraNoQuadro - condenadaDesdeUs) / 1000.0)
                            }
                            cadeiaCondenada = false
                            condenadaDesdeUs = 0L
                        }
                    }
                    val suspeito = cadeiaCondenada && meta[1] != 1L && congelarNaRuptura

                    if (meta[1] == 1L) {
                        if (primeiroIdrUs == 0L) primeiroIdrUs = MonotonicClock.micros() - subiuEm
                        val pedido = pedidoManualEm
                        if (pedido != 0L) {
                            recuperacaoMs = (MonotonicClock.micros() - pedido) / 1000.0
                            pedidoManualEm = 0L
                            Log.i(TAG, "IDR pedido chegou em ${"%.1f".format(recuperacaoMs)} ms")
                        }
                        // O IDR fecha a perda pendente — **venha ele do pedido ou do GOP do
                        // emissor**. Se o GOP consertou dentro da janela de supressão, a perda
                        // deixa de existir e nenhum pedido sai por ela: é a metade da supressão
                        // que a RFC 4585 não escreve e que a aritmética dos IDR exige. Medido
                        // igual nos dois braços.
                        if (perdaEm != 0L) {
                            val ms = (MonotonicClock.micros() - perdaEm) / 1000.0
                            perdaEm = 0L
                            if (!pediuPorEstaPerda) perdasResolvidasSemPedido++
                            pediuPorEstaPerda = false
                            Log.i(TAG, "sem referência por ${"%.1f".format(ms)} ms (idr_na_perda=$pedirIdrNaPerda)")
                        }

                        // O IDR é o quadro que não depende de referência nenhuma: ele **cura** a
                        // cadeia, venha do pedido ou do GOP do emissor.
                        //
                        // **`sem_referencia_ms` passa a ser medido daqui, e não do `perdaEm`.**
                        // Os dois medem o mesmo intervalo; a diferença é o começo. `perdaEm` é
                        // fixado pela volta de 100 ms, que é o relógio da política de PLI e
                        // precisa continuar sendo — as 36 corridas que fixaram os pisos foram
                        // medidas com ele. `condenadaDesdeUs` é fixado **no quadro**, e é o mesmo
                        // instante em que `suspeitos` começa a contar. Publicar um número com um
                        // começo e outro com o outro daria dois relatos do mesmo evento que não
                        // fecham entre si, que é o defeito que este contrato existe para evitar.
                        if (condenadaDesdeUs != 0L && semReferenciaMs.size < 4000) {
                            semReferenciaMs.add((MonotonicClock.micros() - condenadaDesdeUs) / 1000.0)
                        }
                        if (suspeitosNaRajada > piorRajada) piorRajada = suspeitosNaRajada
                        suspeitosNaRajada = 0
                        cadeiaCondenada = false
                        condenadaDesdeUs = 0L
                        // A caixa descarta o mais velho: todo descarte já contado é anterior a
                        // este IDR, e ele o cura.
                        dividaDaCaixa.notarIdr(agoraNoQuadro)
                    }
                    d.enfileirar(idx, tamanho, agoraNoQuadro, suspeito)
                }
                val desenhados = d.drenar()
                if (desenhados > 0 && primeiraImagemUs == 0L) {
                    primeiraImagemUs = MonotonicClock.micros() - subiuEm
                    Log.i(TAG, "primeira imagem na tela: ${primeiraImagemUs / 1000.0} ms depois de entrar na sessão")
                }
            }

            val agora = MonotonicClock.micros()

            // Pedido manual da interface (o botão "Pedir IDR"): é o número de recuperação que
            // `docs/contrato-track.md` lista como obrigatório do M2 — receptor pede, quanto tempo
            // até a imagem voltar. O relógio começa no toque, não no PLI, porque é o toque que a
            // pessoa sente.
            if (pedidoManualPorEnviar) {
                if (QuallNative.trackRequestIdr(track) == QuallNative.Status.OK) {
                    pedidosEnviados++
                    pedidoManualPorEnviar = false
                    ultimoPedidoDeIdr = agora
                    dividaDaCaixa.outroPedidoSaiu(agora)
                }
            }

            // Sem imagem e sem quadro chegando: o IDR de entrada provavelmente se perdeu com o
            // primeiro quadro (item 25). Pedir de novo é barato e é a recuperação desenhada.
            if (primeiraImagemUs == 0L && agora - ultimoPedidoDeIdr > REPETIR_IDR_MS * 1000) {
                if (QuallNative.trackRequestIdr(track) == QuallNative.Status.OK) {
                    pedidosEnviados++
                    dividaDaCaixa.outroPedidoSaiu(agora)
                }
                ultimoPedidoDeIdr = agora
            }

            // --- perda no meio do fluxo: a segunda metade do contrato ------------------------
            if (primeiraImagemUs > 0L && agora - ultimaOlhadaNaPerda > OLHAR_PERDA_MS * 1000) {
                ultimaOlhadaNaPerda = agora
                var subiuAgora = false
                val perdidos = framesDropped(track)
                // Leitura que falha devolve -1 e **não** vira linha de base nova: zerar aqui faria
                // a volta seguinte inventar uma perda do tamanho do contador inteiro.
                if (perdidos >= 0) {
                    if (ultimoFramesDropped < 0) {
                        ultimoFramesDropped = perdidos
                    } else if (perdidos > ultimoFramesDropped) {
                        quadrosPerdidosVistos += perdidos - ultimoFramesDropped
                        ultimoFramesDropped = perdidos
                        // Uma rajada que produz dez subidas seguidas continua sendo **uma** perda
                        // pendente, e vira um pedido: o piso é sobre o pedido, não sobre a perda.
                        if (perdaEm == 0L) {
                            perdaEm = agora
                            pediuPorEstaPerda = false
                            eventosDePerda++
                        }
                        subiuAgora = true
                    }
                }

                if (pedirIdrNaPerda && !supressaoPorCausa) {
                    // --- a política **anterior**, guardada só para o braço "antes" -------------
                    // Um relógio para as quatro causas e um piso só. Está aqui para ser medida
                    // contra a de cima, não para ser usada: ver a doc da classe.
                    if (subiuAgora) {
                        if (agora - ultimoPedidoDeIdr >= intervaloMinimoIdrMs * 1000) {
                            if (QuallNative.trackRequestIdr(track) == QuallNative.Status.OK) {
                                pedidosEnviados++
                                pedidosPorPerda++
                                pediuPorEstaPerda = true
                                ultimoPedidoDeIdr = agora
                                dividaDaCaixa.outroPedidoSaiu(agora)
                            }
                        } else {
                            perdasSuprimidas++
                        }
                    }
                } else if (pedirIdrNaPerda && perdaEm != 0L) {
                    // Dois pisos, e a diferença é a estreia: o primeiro pedido de uma perda nova
                    // limita rajada de perdas distintas (curto); do segundo em diante o pedido é
                    // insistência num PLI que ninguém atendeu (longo).
                    val piso = if (pediuPorEstaPerda) intervaloMinimoIdrMs else pisoDoPrimeiroPedidoMs
                    if (ultimoPliDePerdaUs == 0L || agora - ultimoPliDePerdaUs >= piso * 1000) {
                        val st = QuallNative.trackRequestIdr(track)
                        ultimoPliDePerdaUs = agora
                        if (st == QuallNative.Status.OK) {
                            pedidosEnviados++
                            pedidosPorPerda++
                            pediuPorEstaPerda = true
                            dividaDaCaixa.outroPedidoSaiu(agora)
                        } else {
                            // Não engolir: pedido recusado é o receptor ficando sem imagem, e o
                            // header manda insistir. A perda continua pendente para a volta
                            // seguinte tentar de novo.
                            Log.w(TAG, "pedido de IDR na perda recusado: ${QuallNative.Status.nome(st)}")
                        }
                    } else {
                        perdasSuprimidas++
                    }
                }
            }

            // --- descarte na caixa: a caixa acalmou e o IDR ainda não veio ----------------------
            //
            // **Depois** da perda de rede, e de propósito: se as duas estão pendentes na mesma
            // volta, o PLI da perda sai primeiro e avisa a dívida (`outroPedidoSaiu`), e este não
            // sai em cima dele. O relógio é o das causas que não são perda de rede, com o piso
            // longo — ver a doc da classe. A política de perda não muda: ela continua sem saber
            // deste pedido, como não sabe do botão.
            if (pedirIdrNaCaixa && primeiraImagemUs > 0L && dividaDaCaixa.devePedir(agora) &&
                agora - ultimoPedidoDeIdr >= intervaloMinimoIdrMs * 1000
            ) {
                val st = QuallNative.trackRequestIdr(track)
                ultimoPedidoDeIdr = agora
                if (st == QuallNative.Status.OK) {
                    pedidosEnviados++
                    dividaDaCaixa.pediu(agora)
                } else {
                    Log.w(TAG, "pedido de IDR pela caixa recusado: ${QuallNative.Status.nome(st)}")
                }
            }

            if (agora - ultimaChegada > SILENCIO_ATE_DESISTIR_MS * 1000) {
                motivoDaSaida = ReceptorBus.Aviso.SEM_QUADRO
                break
            }

            if (agora - ultimoRelato > 500_000) {
                ultimoRelato = agora
                val estat = relatar(track, rotulo, spsInfo, primeiroIdrUs, primeiraImagemUs,
                    quadrosAntesDoIdr, pedidosEnviados, meta, rupturas, suspeitos,
                    maxOf(piorRajada, suspeitosNaRajada), ultimaChegada)
                // **A fluidez sai aqui, e sai sempre** — inclusive antes de o decodificador
                // existir, quando ela diz `(sem decodificador)`. Uma linha que só aparecesse
                // depois da primeira imagem esconderia justamente a sessão que nunca montou
                // imagem, que é o defeito que o receptor do Windows já registrou.
                //
                // **Vai para o `logcat` e não para o painel, e isso é decisão.** Os cinco
                // contadores da cadeia vão à tela por cláusula do contrato, porque a queixa que os
                // originou era sobre a tela. A fluidez é diagnóstico de bancada: quem a lê está
                // com o `adb` aberto, e mais uma linha no painel de um celular custa a legibilidade
                // dos números que precisam estar lá.
                Log.i(TAG, linhaDeFluidez())
                // A derivada do dano, sobre a **mesma** leitura de contadores que o painel acabou
                // de mostrar. Desligada em produto (`janela_do_enlace_ms=0`).
                janelaDoEnlace.fechar(agora / 1000, janelaDoEnlaceMs, estat, suspeitos, rupturas)
                    ?.let { a ->
                        Log.i(TAG, a.linha())
                        // E o mesmo objeto atravessa até o emissor. **Sai nos dois braços do
                        // A/B**, ligado ou desligado o controlador do outro lado: assim o
                        // tráfego do relato está no ar nas duas medições e não pode explicar a
                        // diferença entre elas. Um emissor de versão antiga descarta a mensagem
                        // sozinho — a sinalização sempre ignorou o que chega depois da
                        // negociação.
                        // O último campo é o que **esta casca** não conseguiu entregar na
                        // janela. O receptor Android ainda não conta isso — ele não tem fila
                        // própria entre a rede e a tela como a do Windows —, e zero é a resposta
                        // honesta: é o valor que diz "não sei", e o controlador do outro lado o
                        // trata como o comportamento de antes desta frente.
                        val st = QuallNative.sessionReportLink(
                            sessao, a.ms, a.pacotes, a.perdidos, a.suspeitos, a.idrsQuebrados,
                            0L,
                        )
                        if (st != QuallNative.Status.OK && relatosRecusados++ < 3) {
                            // Três vezes e cala: um socket que morreu vai ser notado pelo
                            // detector de queda, e não é este laço que decide isso.
                            Log.w(TAG, "o relato do enlace não saiu (status=$st)")
                        }
                    }
                relatarAudio()
                // A track de áudio pode chegar depois da de vídeo: as duas estão na mesma oferta,
                // mas a libdatachannel as abre na ordem que quiser. Meio segundo de atraso para
                // notá-la é irrelevante, e esta é a **mesma thread** que já chama
                // `sessionNextTrack` — a regra de uma thread só continua valendo.
                if (reprodutor == null && trackDeAudio == 0L) {
                    val t = QuallNative.sessionNextTrack(sessao, 0)
                    if (t != 0L) {
                        val kind = QuallNative.trackKind(t)
                        if (QuallNative.TrackKind.eAudio(kind)) {
                            trackDeAudio = t
                            iniciarAudio(t, kind)
                        } else {
                            Log.w(TAG, "ignorando uma segunda track de vídeo (kind=$kind)")
                            QuallNative.trackFree(t)
                        }
                    }
                }
            }
        }

        relatar(track, rotulo, spsInfo, primeiroIdrUs, primeiraImagemUs, quadrosAntesDoIdr,
                    pedidosEnviados, meta, rupturas, suspeitos,
                    maxOf(piorRajada, suspeitosNaRajada), ultimaChegada)
        val i = decoder?.instantaneo()
        // Uma leitura só, usada nas duas formas: a linha mastigada e o JSON cru. Ler duas vezes
        // daria dois instantes e a bancada compararia números que não fecham entre si.
        val estatisticasFinais = QuallNative.trackStatsJson(track)
        val linhaFinal =
            "recepção encerrada ($rotulo): recebidos=" + // i18n-fora: linha de relato do diário, que a bancada procura
                "${meta[2]} enfileirados=${i?.quadrosEnfileirados ?: 0} " +
                "descartados_na_caixa=${meta[3]} nao_couberam=${meta[5]} antes_do_idr=$quadrosAntesDoIdr " +
                // **Os quatro números que nenhum contador desta casca tinha**, com os nomes de
                // `docs/contrato-track.md`. Os de cima dizem se o quadro chegou; estes dizem se a
                // imagem dele tinha como estar certa. Uma prova de recepção **reprova** a corrida
                // com `suspeitos > 0` — não é linha discreta num relatório, é falha.
                "rupturas=$rupturas suspeitos=$suspeitos pior_rajada=${maxOf(piorRajada, suspeitosNaRajada)} " +
                "retidos=${i?.retidos ?: 0} congelar=${if (congelarNaRuptura) "sim" else "NAO"} " +
                "primeiro_idr=${primeiroIdrUs / 1000.0}ms primeira_imagem=${primeiraImagemUs / 1000.0}ms " +
                "fps=${"%.1f".format(i?.fpsObtido ?: 0.0)}${silencio(ultimaChegada)} " +
                "decode_p50=${(i?.latenciaP50Us ?: 0) / 1000.0}ms decode_p95=${(i?.latenciaP95Us ?: 0) / 1000.0}ms " +
                // **O que a média de `fila→tela` escondia.** `decode_p50` acima é o centro, e o
                // centro não vê tranco: no Windows ele dava 6,5 ms numa corrida cujo pior caso era
                // 226 ms. Ver [Fluidez].
                "${linhaDeFluidez()} " +
                "idr_na_perda=$pedirIdrNaPerda eventos_de_perda=$eventosDePerda " +
                "quadros_perdidos_vistos=$quadrosPerdidosVistos " +
                "pedidos_por_perda=$pedidosPorPerda suprimidos=$perdasSuprimidas " +
                "resolvidas_sem_pedido=$perdasResolvidasSemPedido " +
                "supressao_por_causa=$supressaoPorCausa " +
                "piso_curto=${pisoDoPrimeiroPedidoMs}ms piso_longo=${intervaloMinimoIdrMs}ms " +
                "idr_na_caixa=$pedirIdrNaCaixa caixa=[${dividaDaCaixa.linha()}] " +
                (if (solucoDoLacoMs > 0) "solucos=$solucos " else "") +
                "sem_referencia_ms=${resumoSemReferencia()} " +
                "decodificador=${i?.codec} hw=${i?.hardware} " +
                // A linha que a bancada lê com o olho, antes do JSON que ela lê com script.
                "perda=[${ResumoDePerda.formatar(estatisticasFinais)}] " +
                "audio=[${reprodutor?.resumo() ?: "sem track de áudio"}] " + // i18n-fora: linha de relato do diário
                "nucleo=$estatisticasFinais"
        Log.i(TAG, linhaFinal)
        // **E no arquivo, que é o único canal que sobrevive à sessão.** Ver [arquivarRelato].
        arquivarRelato(linhaFinal)
        ReceptorBus.atualizar {
            it.copy(
                fase = if (pararPedido) ReceptorBus.Fase.PARADO else ReceptorBus.Fase.ERRO,
                aviso = when {
                    pararPedido -> ReceptorBus.Aviso.RECEPCAO_ENCERRADA
                    motivoDaSaida == ReceptorBus.Aviso.NENHUM -> ReceptorBus.Aviso.RECEPCAO_TERMINOU
                    else -> motivoDaSaida
                },
                detalhe = rotulo,
            )
        }
    }

    /**
     * `frames_dropped` do núcleo, ou `-1` quando não há track para perguntar.
     *
     * Ele é o gatilho de perda: um quadro que some inteiro não incrementa nada por si, mas o
     * buraco de sequência é visto no pacote seguinte, que condena o quadro seguinte — então
     * qualquer perda no meio do fluxo produz ao menos um `frames_dropped`. `sequence_anomalies`
     * **não** serviria: ele soma perda com troca de ordem, e reordenar não custa referência.
     *
     * **Passou a ler o acessor direto do núcleo em 31/08/2026, e não o JSON.** Era
     * `JSONObject(trackStatsJson(track)).optLong("frames_dropped")`: um alocador e um parser por
     * leitura, para um `u64`. O preço não era teórico — foi ele que fixou a cadência em 100 ms, e
     * com ela a condenação da cadeia de referência ficaria amostrada a três quadros a 30 fps. O
     * header do núcleo já dizia por que a função existe separada: *"é lido no laço de recepção"*,
     * e *"uma casca que ache isso caro vai acabar não perguntando"*. Esta casca era o caso.
     *
     * O número é o mesmo — `quall_track_frames_dropped` e a chave `frames_dropped` do JSON saem
     * os dois de `Contadores::quadros_descartados`. O que mudou foi só quanto custa perguntar.
     */
    private fun framesDropped(track: Long): Long =
        if (track == 0L) -1L else QuallNative.trackFramesDropped(track)

    // --- áudio ---------------------------------------------------------------------------

    /**
     * Sobe o reprodutor para uma track de áudio recém-chegada.
     *
     * **Não é fatal se falhar.** Um receptor com imagem e sem som é meio produto; um receptor sem
     * imagem porque o `AudioTrack` não abriu é produto nenhum. O motivo vai para o logcat e para o
     * painel, e o vídeo segue.
     */
    private fun iniciarAudio(track: Long, kind: Int) {
        val rotulo = QuallNative.trackLabel(track).ifBlank {
            if (kind == QuallNative.TrackKind.MICROPHONE) "microfone" else "som do sistema"
        }
        Log.i(TAG, "track de áudio recebida: $rotulo (kind=$kind)")
        val r = ReprodutorDeAudio(track, kind, gravarAudioEm)
        if (r.iniciar()) {
            reprodutor = r
            ReceptorBus.atualizar { it.copy(rotuloDoAudio = rotulo, audioTocando = true) }
        } else {
            Log.e(TAG, "o áudio não subiu: ${Log.erroExterno(r.motivoDaSaida)}")
            ReceptorBus.atualizar {
                it.copy(rotuloDoAudio = rotulo, audioTocando = false, resumoDeAudio = r.motivoDaSaida)
            }
        }
    }

    private fun pararAudio() {
        val r = reprodutor ?: return
        r.parar()
        reprodutor = null
        Log.i(TAG, "áudio encerrado: ${r.resumo()}")
        ReceptorBus.atualizar { it.copy(audioTocando = false, resumoDeAudio = r.resumo()) }
    }

    /** O painel de áudio, sem tocar em handle nenhum: só lê o que o reprodutor já publicou. */
    private fun relatarAudio() {
        val r = reprodutor ?: return
        ReceptorBus.atualizar { it.copy(audioTocando = true, resumoDeAudio = r.resumo()) }
    }

    /**
     * Sessão de **áudio só**: nenhuma track de vídeo chegou.
     *
     * É o que a sonda `quall-probe emitir-audio` manda, e o que o laço de vídeo trataria como
     * "dez segundos sem quadro" — um erro, quando na verdade está tudo certo e tocando. Aqui a
     * espera é do reprodutor, e a saída é ele desistir ou a casca parar.
     */
    private fun lacoSomenteAudio(sessao: Long) {
        Log.i(TAG, "sessão de áudio só — nenhuma track de vídeo na oferta")
        ReceptorBus.atualizar {
            it.copy(rotuloDaTrack = "só áudio", aviso = ReceptorBus.Aviso.SO_SOM, detalhe = "") // i18n-fora: o rótulo vai ao painel de números (bancada)
        }
        var motivoDaSaida = ReceptorBus.Aviso.NENHUM
        var detalheDaSaida = ""
        var ultimoRelato = MonotonicClock.micros()
        while (!pararPedido) {
            val evento = QuallNative.sessionNextEvent(sessao, 200)
            if (evento != QuallNative.SessionEvent.NONE) {
                motivoDaSaida = ReceptorBus.Aviso.SESSAO_CAIU
                detalheDaSaida = evento.toString()
                break
            }
            val r = reprodutor
            if (r == null || r.motivoDaSaida.isNotBlank()) {
                motivoDaSaida = ReceptorBus.Aviso.AUDIO_PAROU
                detalheDaSaida = r?.motivoDaSaida.orEmpty()
                break
            }
            val agora = MonotonicClock.micros()
            if (agora - ultimoRelato > 500_000) {
                ultimoRelato = agora
                relatarAudio()
            }
        }
        val r = reprodutor
        Log.i(TAG, "recepção encerrada (só áudio): audio=[${r?.resumo() ?: "nenhum"}]")
        ReceptorBus.atualizar {
            it.copy(
                fase = if (pararPedido) ReceptorBus.Fase.PARADO else ReceptorBus.Fase.ERRO,
                resumoDeAudio = r?.resumo() ?: "",
                aviso = if (pararPedido) ReceptorBus.Aviso.RECEPCAO_ENCERRADA else motivoDaSaida,
                detalhe = if (pararPedido) "" else detalheDaSaida,
            )
        }
    }

    // ============================================================================================
    // O arquivo de relato — o único canal que **sobrevive à sessão**
    // ============================================================================================
    //
    // O `logcat` é fluxo ao vivo: quem não estava com o `adb` anexado quando a sessão rodou não
    // tem como buscar o que aconteceu. O buffer circular do aparelho engole uma sessão de 40 s
    // numa tarde de uso normal, e no A10s — 1,79 GB — engole antes disso.
    //
    // Não é hipótese. Em 31/08/2026 o orquestrador pediu os contadores de uma sessão que o
    // usuário tinha rodado à mão e que ficou limpa, e ela era **irrecuperável**. A frase
    // "aparentemente não houve falha visual" virou base de uma célula da matriz sem um número por
    // trás — que é exatamente o modo de falha que esta rodada inteira existe para consertar.
    //
    // **O que entra no arquivo é contador, e só.** A linha arquivada é a mesma linha de relato —
    // nomes de contador e números —, nunca o endereço do outro lado, nunca o nome do par, nunca um
    // byte de imagem ou de som.
    private val arquivoDoRelato: java.io.File? by lazy {
        if (relatoEm.isBlank()) return@lazy null
        val carimbo = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
            .format(java.util.Date())
        runCatching {
            val pasta = java.io.File(relatoEm)
            pasta.mkdirs()
            // Só os relatos recentes ficam: um app que escreve para sempre num aparelho de 1,79 GB
            // é um defeito, não um instrumento.
            pasta.listFiles { f -> f.name.startsWith("relato-") }
                ?.sortedByDescending { it.name }
                ?.drop(TETO_DE_RELATOS)
                ?.forEach { it.delete() }
            java.io.File(pasta, "relato-$carimbo.txt")
        }.getOrNull()
    }

    /**
     * Guarda uma linha de **contadores** no arquivo desta sessão, além do `logcat`.
     *
     * Falha em silêncio de propósito: um aparelho sem espaço não pode derrubar a sessão de
     * espelhamento por causa do diário dela.
     */
    private fun arquivarRelato(linha: String) {
        val f = arquivoDoRelato ?: return
        runCatching {
            if (!f.exists()) {
                f.writeText("# quall receptor Android — contadores da sessão, sem endereço e sem mídia\n") // i18n-fora: cabeçalho do arquivo de relato
                Log.i(TAG, "relato desta sessão em ${f.absolutePath}")
            }
            f.appendText(com.quall.android.core.RedacaoDeLogs.mensagem(linha) + "\n")
        }
    }

    /**
     * `fluidez_ms=[n=… p50=… p95=… max=…] trancos=…`, ou o dito de que não há de onde tirá-la.
     *
     * Sem decodificador não há apresentação, e um `n=0` aqui seria indistinguível de uma sessão
     * que apresentou um quadro só — dois estados bem diferentes. Mesma forma do
     * `fluidez_ms=(sem tela)` do receptor do Windows.
     */
    private fun linhaDeFluidez(): String = decoder?.fluidez?.linha() ?: "fluidez_ms=(sem decodificador)"

    /** `n=… p50=… p95=… max=…` das amostras de tempo sem referência, em ms. */
    private fun resumoSemReferencia(): String {
        if (semReferenciaMs.isEmpty()) return "n=0"
        val v = semReferenciaMs.sorted()
        fun p(q: Int) = v[((q / 100.0) * (v.size - 1)).toInt().coerceIn(0, v.size - 1)]
        return "n=${v.size} p50=${"%.1f".format(p(50))} p95=${"%.1f".format(p(95))} max=${"%.1f".format(v.last())}"
    }

    /**
     * Insiste no pedido de IDR até a track aceitar. Devolve quantos pedidos saíram de fato.
     *
     * O header é explícito: `quall_track_request_idr` "devolve erro enquanto a track não abriu",
     * e "tentar de novo por alguns milissegundos é o comportamento certo".
     */
    private fun pedirIdrAoEntrar(track: Long): Long {
        val limite = MonotonicClock.micros() + INSISTIR_IDR_MS * 1000L
        var tentativas = 0
        while (!pararPedido && MonotonicClock.micros() < limite) {
            val st = QuallNative.trackRequestIdr(track)
            tentativas++
            if (st == QuallNative.Status.OK) {
                Log.i(TAG, "IDR pedido ao entrar (na tentativa $tentativas)")
                return 1
            }
            Thread.sleep(20)
        }
        Log.w(TAG, "a track não aceitou o pedido de IDR de entrada em ${INSISTIR_IDR_MS} ms")
        return 0
    }

    /**
     * `" · SEM QUADRO há N s"` quando o último quadro é velho demais, ou `""` quando está vivo.
     *
     * Dois segundos: mais que qualquer intervalo de IDR do produto (1 s na tela, 2 s na câmera) e
     * menos que o tempo de alguém perceber pela imagem. Mesmo limiar do plugin do OBS.
     */
    private fun silencio(ultimaChegadaUs: Long): String {
        if (ultimaChegadaUs <= 0L) return ""
        val idadeMs = (MonotonicClock.micros() - ultimaChegadaUs) / 1000
        return if (idadeMs >= 2000) " · SEM QUADRO há ${"%.1f".format(idadeMs / 1000.0)} s" else "" // i18n-fora: linha de relato do diário
    }

    private fun relatar(
        track: Long,
        rotulo: String,
        sps: Sps.Info?,
        primeiroIdrUs: Long,
        primeiraImagemUs: Long,
        quadrosAntesDoIdr: Long,
        pedidos: Long,
        meta: LongArray,
        rupturas: Long,
        suspeitos: Long,
        piorRajada: Long,
        /**
         * Quando o último quadro chegou, no relógio monotônico. Entra como parâmetro porque
         * `ultimaChegada` é local do laço de recepção.
         *
         * **Serve para o painel não mostrar número vivo de uma fonte muda.** O plugin do OBS
         * ganhou esta mesma testemunha em 09/09/2026: sem ela, uma fonte que parou de entregar
         * seguia exibindo a taxa acumulada como se nada tivesse acontecido, porque o denominador
         * é a sessão inteira e nada recente o move.
         */
        ultimaChegadaUs: Long,
    ): String {
        val i = decoder?.instantaneo()
        val estatisticas = QuallNative.trackStatsJson(track)
        ReceptorBus.atualizar {
            it.copy(
                fase = ReceptorBus.Fase.EXIBINDO,
                rotuloDaTrack = rotulo,
                primeiroIdrMs = primeiroIdrUs / 1000.0,
                primeiraImagemMs = primeiraImagemUs / 1000.0,
                quadrosRecebidos = meta[2],
                quadrosEnfileirados = i?.quadrosEnfileirados ?: 0,
                retidos = i?.retidos ?: 0,
                rupturas = rupturas,
                suspeitos = suspeitos,
                piorRajada = piorRajada,
                semReferenciaMs = resumoSemReferencia(),
                congelando = congelarNaRuptura,
                quadrosDescartadosNaCaixa = meta[3],
                quadrosAntesDoPrimeiroIdr = quadrosAntesDoIdr,
                pedidosDeIdrEnviados = pedidos,
                fpsObtido = i?.fpsObtido ?: 0.0,
                decodeP50Ms = (i?.latenciaP50Us ?: 0L) / 1000.0,
                decodeP95Ms = (i?.latenciaP95Us ?: 0L) / 1000.0,
                largura = i?.largura ?: 0,
                altura = i?.altura ?: 0,
                perfil = sps?.perfil ?: "",
                faixaDeCor = sps?.faixaDeCor ?: "",
                decodificador = i?.codec ?: "",
                decodificadorEhHardware = i?.hardware ?: false,
                estatisticasDoNucleo = estatisticas,
                // A perda mastigada, ao lado do JSON cru. Sai da **mesma** leitura de contadores,
                // e não de uma segunda chamada: os números desta linha e os do JSON acima têm de
                // ser do mesmo instante, que é a razão de `rtp::Contadores` existir no núcleo.
                resumoDePerda = ResumoDePerda.formatar(estatisticas),
                aviso = ReceptorBus.Aviso.NENHUM,
                detalhe = "",
            )
        }
        // Devolvido, e não relido pelo chamador: `JanelaDoEnlace` precisa desta **mesma** leitura.
        // Uma segunda chamada daria outro instante, e a janela fecharia contra um estado que o
        // painel nunca mostrou.
        return estatisticas
    }

    /** O erro vai ao diário pelo nome do aviso, e à tela como aviso: a frase sai lá, no idioma dela. */
    private fun erro(aviso: ReceptorBus.Aviso, detalhe: String = "") {
        Log.e(TAG, "$aviso: ${Log.erroExterno(detalhe)}")
        ReceptorBus.publicar(
            ReceptorBus.Estado(fase = ReceptorBus.Fase.ERRO, endpoint = endpoint, aviso = aviso, detalhe = detalhe)
        )
    }
}
