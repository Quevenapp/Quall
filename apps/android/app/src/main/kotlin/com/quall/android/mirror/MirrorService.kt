package com.quall.android.mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import androidx.core.app.NotificationCompat
import androidx.lifecycle.LifecycleService
import com.quall.android.R
import com.quall.android.audio.CapturaDoProprioApp
import com.quall.android.audio.EmissorDeAudio
import com.quall.android.audio.FonteDeAudio
import com.quall.android.audio.MicrofoneCompartilhado
import com.quall.android.audio.MicrofoneCru
import com.quall.android.audio.PresetDeAudio
import com.quall.android.audio.TomSintetico
import com.quall.android.capture.CameraXSource
import com.quall.android.capture.H264CameraEncoder
import com.quall.android.capture.H264ScreenEncoder
import com.quall.android.capture.H264SurfaceEncoder
import com.quall.android.capture.PreviaDaCamera
import com.quall.android.capture.TrackFrameSink
import com.quall.android.core.Bancada
import com.quall.android.core.DeviceIdentity
import com.quall.android.core.EnderecosLocais
import com.quall.android.core.QuallNative
import com.quall.android.discovery.MulticastLockManager
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Espelhamento de verdade: (`MediaProjection`+`VirtualDisplay`) ou (CameraX) → `MediaCodec` →
 * `quall_track_send_frame`.
 *
 * ## A origem é escolhida antes do PIN
 *
 * Decisão de `docs/fluxo-de-uso.md`: um seletor no emissor, na Activity, escolhe **antes** de
 * gerar o PIN entre a tela e cada câmera física do aparelho. Só depois disso este serviço sobe —
 * ele recebe a origem já decidida em [Fonte], nunca decide sozinho, e a origem fica **fixa pela
 * sessão inteira**: não há renegociação no protocolo, então trocar de origem é encerrar e começar
 * de novo, e por isso não existe aqui um caminho de "trocar" no meio de uma espera ou sessão.
 *
 * ## Quem hospeda é o emissor
 *
 * A fronteira C só aceita tracks de saída em `quall_host` (`QuallSessionOptions::tracks`: "Só
 * vale em [`quall_host`]"). Quem chama `quall_connect` recebe lista de tracks vazia e **nunca**
 * poderá emitir naquela sessão. Consequência de produto: o aparelho que quer espelhar é
 * obrigatoriamente quem **espera**, mostrando PIN e endereço, e quem disca é o receptor.
 *
 * O que dá para fazer aqui, e está feito: a espera é **visível** (PIN, endereço, tentativa) e
 * **cancelável de verdade**, e a mesma `MediaProjection` (quando a origem é a tela) é reaproveitada
 * entre tentativas — o usuário consente uma vez só, mesmo que o receptor erre o PIN ou desista.
 *
 * ## Cancelamento
 *
 * O núcleo ganhou `quall_canceller_new` + `quall_host_cancelable` + `quall_session_cancel` nesta
 * rodada (dívida 10 paga). O contorno anterior — abrir e fechar uma conexão TCP descartável para
 * `127.0.0.1:7877` só para destravar o `accept` do `quall_host` — saiu: agora um
 * [QuallCanceller][com.quall.android.core.QuallNative.cancellerNew] de verdade é criado antes do
 * laço de espera e liberado depois dele, guardado atrás de [cancelLock] para nunca ser chamado
 * (nem liberado duas vezes) com um handle morto — regra de plataforma depois do achado do Windows
 * em `docs/divida-do-nucleo.md`.
 *
 * ## MulticastLock
 *
 * Segurado por **toda a vida do serviço**, não só na descoberta. É o emissor que anuncia; sem o
 * lock, o Android pode filtrar o multicast que carrega as consultas mDNS e o celular
 * simplesmente some da lista dos desktops — em silêncio, do mesmo jeito que o firewall do
 * Windows some com o UDP 5353.
 *
 * ## `LifecycleService`, não `Service`
 *
 * A origem câmera usa CameraX, e `ProcessCameraProvider.bindToLifecycle` exige um
 * `LifecycleOwner`. Um `Service` comum não é um; `LifecycleService` é.
 */
class MirrorService : LifecycleService() {

    companion object {
        /** O Android revogou o consentimento de captura — a causa mais comum de a tela parar. */

        private const val TAG = "QuallMirror"

        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_DPI = "dpi"

        /** "screen" (padrão) ou "camera" — ver [Fonte]. */
        const val EXTRA_SOURCE_KIND = "source_kind"
        const val SOURCE_SCREEN = "screen"
        const val SOURCE_CAMERA = "camera"
        const val EXTRA_CAMERA_ID = "camera_id"
        const val EXTRA_CAMERA_LABEL = "camera_label"

        /**
         * A câmera da tela **"Teleprompter com câmera"** (R5, `docs/teleprompter-com-camera.md`):
         * a frontal, aberta **uma vez** pelo [DonoDaCaptura] quando a tela abre e mantida até ela
         * fechar, sem seguir a presença da tela. A sessão de vídeo se pendura no dono quando o
         * receptor pareia e se solta quando ele cai. Ver [Fonte.CameraDoPrompter].
         */
        const val SOURCE_PROMPTER_CAMERA = "prompter_camera"

        /**
         * **O DVD caseiro** (`docs/dvd-para-mp4.md` §9): o título do disco que está no leitor, sem
         * gravar. O leitor e o disco vêm da tela "Converter DVD" pela [com.quall.android.dvd.SessaoDoDvd]
         * (como no Converter); [EXTRA_DVD_TITULO] é o número do título e [EXTRA_DVD_FAIXA] o índice da
         * faixa de som da rede nas convertíveis (-1 sem som). Ver [Fonte.Dvd].
         */
        const val SOURCE_DVD = "dvd"
        const val EXTRA_DVD_TITULO = "dvd_titulo"
        const val EXTRA_DVD_FAIXA = "dvd_faixa"
        /** O tempo do título (90 kHz) onde começa: o Transmitir que vem do Assistir aqui segue dali. */
        const val EXTRA_DVD_INICIO = "dvd_inicio"

        /**
         * Quem é a tela R5 dona deste serviço agora. Uma tela recriada (a bancada abre com
         * `CLEAR_TOP`) sobe o serviço de novo antes de a velha ser destruída; o `onDestroy` da velha
         * manda [ACAO_PARAR] com o marcador dela, e o serviço, que já adotou o da nova, ignora.
         * Um [ACAO_PARAR] sem marcador (a notificação, a tela inicial) para sempre.
         */
        const val EXTRA_DONO_DA_TELA = "dono_da_tela"

        const val ACAO_PARAR = "com.quall.android.PARAR_ESPELHAMENTO"

        /** A ação da notificação que desliga o microfone da câmera (a revisão, M6). */
        const val ACAO_DESLIGAR_MICROFONE = "com.quall.android.DESLIGAR_MICROFONE"

        /** O serviço vivo neste processo, ou `null`. Só para [pedirParada]. */
        @Volatile private var instancia: MirrorService? = null

        /**
         * Pede ao serviço que pare — [deQuem] é o marcador da tela R5, ou `null` (a tela inicial,
         * que para qualquer espelhamento).
         *
         * **Sem `Intent`, e de propósito** (a revisão da tela R5): `startForegroundService` com o
         * serviço morto obriga a um `startForeground` que um pedido de parar não tem como fazer, e o
         * app caía por prazo; `startService` é recusado com o app em segundo plano, que é
         * justamente quando uma tela pode estar sendo destruída. O serviço mora no mesmo processo,
         * então o pedido vai direto a ele, na thread principal.
         */
        fun pedirParada(deQuem: String?) {
            val s = instancia ?: return
            android.os.Handler(android.os.Looper.getMainLooper()).post { s.pedidoDeParar(deQuem) }
        }

        /**
         * **Só leitura, para a tela**: a câmera do dono entregou quadro nos últimos [ms] ms. É o que
         * tira o "Aguarde… abrindo a câmera" das telas no modelo do iOS (`docs/telas-android-como-ios.md`
         * §1.3 e §2.3), como o `dono.entregando` de lá. Não toca na câmera nem na gravação.
         */
        fun cameraEntregando(ms: Long): Boolean = instancia?.donoDaCaptura?.entregando(ms) == true

        /**
         * **Só leitura, para a tela**: por que o dono da câmera não abriu (a câmera ocupada por outro
         * app, o `CameraAccessException`), ou `null`. Sem isto o "Aguarde…" das telas ficaria para
         * sempre numa câmera que falhou (a revisão do código de 28/09).
         */
        fun falhaDaCamera(): String? = instancia?.falhaDoDono

        /**
         * **O canal de controle da câmera** (R9, `docs/controles-de-camera.md` §6): os controles do dono
         * aberto, para a tela que o mostra — [daTelaR5] diz quem pergunta, e a tela inicial não recebe os
         * da R5 (nem o contrário), como a prévia ([com.quall.android.capture.PreviaDoDono]). `null` sem
         * dono aberto: a DV, o braço de bancada `camera_comum_pelo_camerax`, a câmera ainda abrindo.
         * Na thread principal.
         */
        fun controlesDaCamera(daTelaR5: Boolean): com.quall.android.capture.ControlesDaCamera? =
            donoParaATela(daTelaR5)?.controles

        /** O toque na prévia da tela [daTelaR5] (§4.4). `false` sem dono, na tarja, ou sem nada a medir. */
        fun tocarNaPrevia(daTelaR5: Boolean, x: Float, y: Float, largura: Int, altura: Int, longo: Boolean): Boolean =
            donoParaATela(daTelaR5)?.tocarNaPrevia(x, y, largura, altura, longo) == true

        private fun donoParaATela(daTelaR5: Boolean): com.quall.android.capture.DonoDaCaptura? {
            val s = instancia ?: return null
            val d = s.donoDaCaptura ?: return null
            return d.takeIf { (s.fonteEmCurso is Fonte.CameraDoPrompter) == daTelaR5 && !d.estaFechado }
        }

        /**
         * O botão do microfone da câmera (R5, fase 2): liga ou desliga. Devolve `false` sem serviço
         * vivo. **A permissão já foi pedida pela tela**: o serviço só a lê, e sem ela recusa e diz
         * por quê no [MicrofoneBus]. Na thread principal, como [pedirParada].
         */
        fun pedirMicrofone(ligar: Boolean): Boolean {
            val s = instancia ?: return false
            android.os.Handler(android.os.Looper.getMainLooper()).post { s.microfone(ligar) }
            return true
        }

        /**
         * **Gravar a câmera** (fase 3 e §8.6, `docs/teleprompter-com-camera.md` §5): começa ou para. [daTelaR5]
         * diz quem pede: a tela R5 só grava a sessão dela, e a tela inicial só a câmera comum. O
         * resultado sai no [GravacaoDaTelaBus] — o arquivo que começou, o que fechou, ou a recusa com
         * o motivo. Devolve `false` sem serviço vivo (a câmera nunca abriu: sem permissão de câmera,
         * ou a tela sem frontal). Na thread principal, como [pedirParada].
         */
        fun pedirGravacao(gravar: Boolean, daTelaR5: Boolean): Boolean {
            val s = instancia ?: return false
            android.os.Handler(android.os.Looper.getMainLooper()).post { s.gravacao(gravar, daTelaR5) }
            return true
        }

        private const val CHANNEL_ID = "quall-mirror"
        private const val NOTIF_ID = 2

        /**
         * O padrão de quadros por segundo. **Deixou de ser a última palavra em 07/09/2026**: a
         * taxa passou a ser escolha do usuário (`core/Resolucao.quadros`), e esta constante é o
         * que vale para quem não abriu o menu. Ver `docs/fluxo-de-uso.md`.
         */
        // **`TARGET_FPS = 30` foi removida em 08/09/2026, e a remoção é o conserto.** Ela era
        // publicada como `fpsPedido` na interface e como `fps_pedido` no log, coladinha em
        // `fps_obtido`, enquanto o encoder rodava com `Resolucao.quadros` — 30 **ou 60**. Quem
        // escolhia 60 lia `pedido=30 obtido=58`: o único par que este repositório construiu para
        // pegar uma API que aceita e não faz estava ele próprio mentindo, com a assinatura exata
        // do defeito do A07. O padrão de 30 agora mora num lugar só, `Resolucao.quadros`, e a
        // constante não existe para ninguém copiar. Ver `docs/bancada.md` §8.54.

        // Dois presets, não um: tela é conteúdo estático com mudanças bruscas (prioriza IDR
        // rápido e recompõe bem em áreas planas); câmera é ruído de sensor com movimento
        // contínuo (já é redundante quadro a quadro, mas cada quadro custa mais bits). Antes do
        // M6 os dois usavam os mesmos números (ver o histórico deste arquivo e o comentário que
        // ficava em H264CameraEncoder.kt) — os valores abaixo alinham com o que o macOS já mede e
        // declara desde o M1 (`apps/macos/Sources/QuallCaptureKit/H264Encoder.swift`,
        // `PresetTuning` de `.screen` e `.camera`), que é hoje a referência do projeto para esta
        // divisão. **Não medido no A07 nem no A10s por esta frente** — M6 não teve aparelho
        // Android; a mudança é decisão de design (docs/ux-m6.md), não número recalibrado aqui.
        /**
         * **Os dois deixaram de ser números em 02/09/2026 e viraram razões.**
         *
         * Eram `4_000_000` e `6_000_000` cravados, e não sabiam nada sobre o tamanho do quadro:
         * quando o teto de resolução subiu para 1080p em 01/09, a tela ganhou 2,25 vezes os
         * pixels e o orçamento de bits ficou onde estava. O número agora vem de
         * `QuallNative.tetoDeTaxaBps` — a mesma regra que decide a geometria —, e a diferença
         * entre tela e câmera sobrevive como a razão que ela sempre foi: a referência do núcleo é
         * densidade de tela.
         *
         * **A razão virou 3/4 em 06/09/2026, e antes era 3/2** — "a câmera pede metade a mais para
         * absorver o ruído de sensor", com a ressalva honesta *"não medido no A07 nem no A10s"*
         * logo abaixo. Foi medido (§8.38, §8.40), e o argumento não se sustenta:
         *
         * - a 1080p30 o 3/2 pedia **13,5 Mbps** e o codificador descia a **QP 3,1** para gastar o
         *   orçamento; codificação de streaming vive entre QP 23 e 28 (§8.28, §8.31);
         * - no **piso** de 4,67 Mbps, que é o mínimo que este codificador aceita produzir, o QP
         *   ainda fica em 7,6–8,6 — ele **nunca chega perto de sofrer** com o ruído (§8.31);
         * - o emissor **iOS já usava 3/4** desde sempre, para a mesma geometria e o mesmo
         *   `teto_de_taxa`, e ninguém havia notado que as duas metades da frota pediam o dobro
         *   uma da outra (§8.38).
         *
         * O que isto compra: metade da carga oferecida ao rádio, e o alvo de IDR caindo de ~172
         * para ~89 pacotes — que é a exposição ao truncamento que a §8.28 mediu.
         *
         * A 720p a tela continua em exatamente 4 Mbps, que é o que o macOS mede e declara desde
         * o M1; a câmera passa de 6 para 3 Mbps.
         */
        private const val FATOR_CAMERA_NUM = 3
        private const val FATOR_CAMERA_DEN = 4
        /** Fallback se a fronteira recusar: os 4 Mbps históricos, nunca zero. */
        private const val BITRATE_BPS_TELA_HISTORICO = 4_000_000
        /** GOP curto para tela: mudança brusca de cena pede IDR logo. */
        private const val GOP_SEGUNDOS_TELA = 1f
        /** GOP mais largo para câmera: conteúdo já redundante, refresh frequente não ajuda. */
        private const val GOP_SEGUNDOS_CAMERA = 2f
        /** Prazo de uma tentativa de espera. Longo de propósito — cancelar é pelo cancelador. */
        private const val ESPERA_MS = 300_000
        /** Abaixo disto, `hostStart` não esperou ninguém: falhou de saída (porta ocupada etc.). */
        private const val FALHA_IMEDIATA_MS = 1_000L
        private const val FALHAS_IMEDIATAS_ATE_DESISTIR = 5
        /** O pior caso de `DonoDaCaptura.abrir` (três prazos de 6 s), com folga. */
        private const val PRAZO_DO_DONO_S = 20L
    }

    /** A origem escolhida pela Activity, antes do PIN. Fixa pela sessão — ver a doc da classe. */
    private sealed class Fonte {
        data class Tela(
            val resultCode: Int,
            val resultData: Intent,
            val width: Int,
            val height: Int,
            val dpi: Int,
        ) : Fonte()

        data class Camera(
            val cameraId: String,
            val label: String,
            /**
             * **A câmera comum pelo [DonoDaCaptura]** (§8.6 do `teleprompter-com-camera.md`, 24/09): a
             * câmera abre uma vez, e a prévia, a rede e a gravação são saídas do divisor — ligar o
             * codificador não fecha nem reabre a câmera. Falso na DV e no braço de controle de
             * bancada (`camera_comum_pelo_camerax`), que seguem o `CameraXSource` de antes.
             */
            val peloDono: Boolean = false,
        ) : Fonte() {
            /** A filmadora DV por USB (`capture/dv/`), e não uma câmera do CameraX. */
            val dv: Boolean get() = cameraId.startsWith(com.quall.android.capture.dv.UsbDv.PREFIXO_DO_ID)
        }

        /**
         * A frontal da tela R5. Outra fonte, e não um modo de [Camera], porque o dono da câmera é
         * outro: aqui ela não é da espera nem da sessão, é da tela — ver [donoDaCaptura].
         */
        data class CameraDoPrompter(val cameraId: String, val label: String) : Fonte()

        /**
         * O título [titulo] do DVD no leitor USB (`docs/dvd-para-mp4.md` §9), com a faixa de som
         * [faixa]. Vai como a câmera (a track de vídeo `CAMERA`), e o som do disco na track de som da
         * sessão (`SYSTEM_AUDIO`: estéreo, Opus a 128 kbit/s, não é fala), no lugar do microfone.
         */
        data class Dvd(val titulo: Int, val faixa: Int, val inicio90k: Long = 0) : Fonte()
    }

    @Volatile private var cancelado = false

    /**
     * O sistema encerrou o consentimento de gravação. Só existe para [Fonte.Tela]: a câmera não
     * tem consentimento por sessão do sistema, só a permissão de câmera, já checada pela Activity
     * antes de o serviço subir.
     */
    @Volatile private var projecaoParada = false

    /**
     * A filmadora DV caiu (cabo puxado, ou ela se desligou e sumiu do USB). Como [projecaoParada]:
     * encerra o serviço em vez de voltar à espera, porque a volta pediria de novo o diálogo de
     * permissão USB, e uma espera sem câmera só giraria sessões mortas (a revisão da fase B, A1).
     */
    @Volatile private var cameraDvCaiu = false

    /**
     * O vídeo USB (a filmadora DV ou a placa de captura), quando a fonte é ele: a posse da rede no
     * dono único ([com.quall.android.capture.dv.DonoDaPlaca]), que a prévia parada da tela e a
     * gravação também pegam. Do serviço, como [cameraSource].
     */
    @Volatile private var posseDv: com.quall.android.capture.dv.DonoDaPlaca.Posse? = null
    private val fonteDv: com.quall.android.capture.dv.FonteDv? get() = posseDv?.fonte

    /**
     * O DVD, quando a fonte é ele ([Fonte.Dvd]): a leitura e a decodificação do título, abertas na
     * thread de espelhamento antes da espera e fechadas no fim dela (o leitor volta à tela).
     */
    @Volatile private var transmissaoDvd: com.quall.android.dvd.TransmissaoDoDvd? = null

    /**
     * **Por que a sessão parou**, em uma frase pronta para a tela — ou `null` quando não houve
     * motivo especial.
     *
     * Existe porque `espelhar` tem **duas** saídas com fase PARADO e elas diziam coisas
     * diferentes: a de dentro do laço (depois de `conduzirSessao`) explicava o consentimento
     * revogado, e a do fim da função dizia só *"espelhamento encerrado"*. Quem bloqueava o
     * telefone **durante a espera**, antes de qualquer receptor conectar, caía na segunda — e lia
     * uma frase que não diz o que houve nem o que fazer.
     *
     * A razão passa a ser escrita **onde ela é conhecida** (`MediaProjection.onStop` e o
     * `SecurityException` do Android 14+) e lida nas duas saídas.
     */
    @Volatile private var motivoDaParada: String? = null

    private val cancelLock = Any()

    /** `0` quando não há espera em curso ou depois de liberado — nunca chamado nesse estado. */
    @Volatile private var cancellerHandle: Long = 0L

    private var encoder: H264SurfaceEncoder? = null
    private var multicastLock: MulticastLockManager? = null
    /** Ver [RadioAcordado]: sem ele, o rádio dorme e o pareamento leva dez segundos (§8.33). */
    private var radioAcordado: com.quall.android.core.RadioAcordado? = null
    private var projection: MediaProjection? = null
    private var projectionThread: HandlerThread? = null
    /**
     * A câmera aberta, quando há. **Ela é do serviço, não da sessão** — e essa troca de dono é a
     * mudança de 03/09.
     *
     * Antes ela nascia dentro de [conduzirSessao] e morria no `finally` dela, o que significava
     * que a pessoa que ia transmitir a câmera **não via nada** até alguém parear. No iOS a
     * `AVCaptureSession` da `TelaDaCamera` roda independente da sessão do Quall, e quem emite
     * acerta o enquadramento enquanto espera; aqui passa a ser igual — a fonte abre antes do laço
     * de espera, atravessa a sessão e sobrevive a ela. As transições são atrás de [travaDaCamera],
     * porque agora existem duas threads mexendo nela: a de espelhamento e a de [obrasDaCamera].
     * `@Volatile` para o `onDestroy`, que a lê **sem** a trava — ver lá o porquê.
     */
    @Volatile private var cameraSource: CameraXSource? = null

    /** Protege [cameraSource], [cameraDaEspera] e [codificandoCamera] — ver [ajustarPreviaDeEspera]. */
    private val travaDaCamera = Any()

    /**
     * O id da câmera enquanto a fase de espera pode mostrar prévia; `null` fora disso (origem tela,
     * ou espelhamento já encerrado).
     */
    @Volatile private var cameraDaEspera: String? = null

    /**
     * `true` entre [subirFonteDaCamera] e o fim da sessão. Enquanto for `true`, o sinal de "a tela
     * sumiu" é **ignorado**: quem apoia o telefone e sai do app está transmitindo de propósito, e
     * fechar a câmera ali seria derrubar a transmissão em vez de economizar bateria.
     */
    @Volatile private var codificandoCamera = false

    /**
     * Onde a câmera abre e fecha fora da thread de espelhamento.
     *
     * Precisa existir por dois motivos. O primeiro é que a thread `quall-mirror` fica **presa**
     * dentro de `QuallNative.hostStart` por até [ESPERA_MS], então ela não pode ser quem reage à
     * tela aparecer e sumir durante a espera. O segundo é que o sinal chega na thread principal
     * (`PreviaDaCamera.ligar`, de `onStart`/`onStop`) e `CameraXSource` espera por `post`s na
     * própria principal — reagir ali travaria o processo.
     *
     * Uma thread só, de propósito: abrir e fechar a mesma câmera ficam serializados sem trava
     * extra. Ela só nasce no primeiro `execute`, então a origem tela não paga nada por isto.
     */
    private val obrasDaCamera = Executors.newSingleThreadExecutor { r -> Thread(r, "quall-mirror-camera") }

    /**
     * O sinal de presença da tela, vindo de [PreviaDaCamera.observarTela]. Chega na thread
     * principal e **não pode bloquear**: só despacha.
     */
    private val aoMudarTela: (Boolean) -> Unit = { olhando ->
        val id = cameraDaEspera
        if (id != null) {
            runCatching { obrasDaCamera.execute { ajustarPreviaDeEspera(id, olhando) } }
        }
    }

    /**
     * O emissor de áudio da sessão corrente, ou `null` quando a oferta não levou som.
     *
     * `@Volatile` porque [parar] o lê de outra thread, e porque o `finally` de `conduzirSessao` o
     * zera. Ele **não** entra em [parar]: quem o encerra é o `finally` da sessão, na ordem certa
     * (áudio antes de `trackFree`), e chamá-lo de duas threads seria a corrida que o Windows
     * ensinou a evitar — nunca tocar a fronteira com um id que pode estar morto.
     */
    @Volatile private var emissorDeAudio: EmissorDeAudio? = null

    // --- o microfone da câmera (R5, fase 2; `docs/teleprompter-com-camera.md` §4) -------------------

    /**
     * O botão: o que a tela pediu. **Começa desligado** a cada espelhamento de câmera e atravessa as
     * sessões dele (o receptor cai e volta, o botão fica). Escrito na principal.
     */
    @Volatile private var microfonePedido = false

    /**
     * Protege [trackDoMicrofone], [emissorDoMicrofone] e [trackComEmissorPreso]. A abertura e o
     * fechamento correm em [obrasDoMicrofone]; o fim da sessão (a thread de espelhamento) pega a
     * mesma trava antes de liberar a track — nunca uma track liberada embaixo do laço do som.
     */
    private val travaDoMicrofone = Any()

    /** A track `MICROPHONE` da sessão no ar, ou `0` sem sessão. */
    private var trackDoMicrofone = 0L

    /**
     * O emissor do microfone **para a rede**, só com o botão ligado **e** uma sessão no ar. Ele lê um
     * ramal do [microfoneAberto]: fechá-lo não fecha o microfone da gravação.
     */
    private var emissorDoMicrofone: EmissorDeAudio? = null

    /**
     * **O microfone aberto** (fase 3): a leitura da fonte, uma só, repartida entre a rede e a
     * gravação ([MicrofoneCompartilhado]). Aberto com o botão ligado **e** alguém para ouvir — um
     * receptor, ou a gravação da tela R5 (§5.3: a gravação funciona sem receptor, e o microfone abre
     * para ela). Sob [travaDoMicrofone], aberto e fechado em [obrasDoMicrofone].
     */
    private var microfoneAberto: MicrofoneCompartilhado? = null

    /** O som da gravação da tela R5, pendurado no microfone quando ele abre; `null` sem gravação. */
    @Volatile private var somDaGravacao: MicrofoneCompartilhado.Gravacao? = null

    /**
     * A track de um emissor que não saiu em 2 s ao ser parado: ela **não** é liberada (vazar é
     * melhor que liberar embaixo de uma thread viva que chama `quall_track_send_audio`).
     */
    private var trackComEmissorPreso = 0L

    /** O tipo `microphone` está no serviço em primeiro plano agora. Escrito na principal. */
    @Volatile private var tipoMicrofoneNoServico = false

    /** Onde o microfone abre e fecha: abrir um `AudioRecord` leva dezenas de ms, fora da principal. */
    private val obrasDoMicrofone = Executors.newSingleThreadExecutor { r -> Thread(r, "quall-microfone") }

    /**
     * A fonte tem um [DonoDaCaptura] (a tela R5, ou a câmera comum pelo dono): a câmera é aberta uma
     * vez, e a rede e a gravação se penduram no divisor dela.
     */
    private fun Fonte?.usaDono(): Boolean = this is Fonte.CameraDoPrompter || (this is Fonte.Camera && peloDono)

    /**
     * Uma gravação está começando ou gravando com a câmera comum: a câmera não fecha pela tela sumir
     * (como [codificandoCamera] para a sessão). Sob [travaDaCamera].
     */
    @Volatile private var gravacaoUsaCamera = false

    /** O tipo da fonte em curso e o texto da notificação: o `startForeground` de novo precisa dos dois. */
    @Volatile private var tipoDaFonte = SOURCE_SCREEN
    @Volatile private var textoDaNotificacao = "Preparando…"

    // --- a tela R5 ---------------------------------------------------------------------------------

    /**
     * O dono da câmera da tela R5, quando a fonte é [Fonte.CameraDoPrompter]. **Da tela, não da
     * sessão**: abre antes do laço de espera, atravessa as sessões (elas se penduram e se soltam
     * nele) e fecha no fim da thread de espelhamento, que é quando a tela fecha.
     */
    @Volatile private var donoDaCaptura: com.quall.android.capture.DonoDaCaptura? = null

    /** Cai quando a abertura do [donoDaCaptura] terminou, bem ou mal. */
    @Volatile private var donoAberto: java.util.concurrent.CountDownLatch? = null

    /** Por que o [donoDaCaptura] não abriu, para a frase da sessão. */
    @Volatile private var falhaDoDono: String? = null

    /** O marcador da tela R5 dona do serviço agora. Ver [EXTRA_DONO_DA_TELA]. */
    @Volatile private var donoDaTela: String? = null

    /** A fonte da thread de espelhamento em curso, ou `null` sem nenhuma. */
    @Volatile private var fonteEmCurso: Fonte? = null

    /** Um pedido de espelhar que chegou enquanto a sessão anterior fechava. Ver `onStartCommand`. */
    @Volatile private var pedidoPendente: Pair<Intent, Int>? = null

    /** A geração da thread de espelhamento em curso. Ver [abrirDonoDaCaptura]. */
    private val geracao = java.util.concurrent.atomic.AtomicInteger(0)

    // --- a gravação da tela R5 (fase 3) -----------------------------------------------------------

    /** Quem grava, só na tela R5. Tocado só em [obrasDaGravacao] (e no fim da thread de espelhamento). */
    @Volatile private var gravacaoDaTela: GravacaoDaTela? = null

    /** Onde a gravação começa e para: abrir o arquivo e o codificador leva centenas de ms. Uma thread só. */
    private val obrasDaGravacao = Executors.newSingleThreadExecutor { r -> Thread(r, "quall-gravacao") }

    override fun onCreate() {
        super.onCreate()
        instancia = this
    }

    /**
     * Um pedido de parar, na thread principal. [deQuem] é o marcador de uma tela R5, ou `null`.
     *
     * Três casos (a revisão da tela R5, B3 e B1):
     * - **o pedido pendente é derrubado** quando o parar é geral ou vem da tela dele: senão a
     *   frontal abriria depois, sem tela nenhuma;
     * - uma tela R5 que já não é a dona (a velha de uma recriação) não para a sessão da nova;
     * - sem nada em curso, o serviço sai — e não fica vivo esperando um `stopSelf` que ninguém chama.
     */
    internal fun pedidoDeParar(deQuem: String?) {
        val (emCurso, dona) = synchronized(cancelLock) {
            val pend = pedidoPendente
            if (pend != null && (deQuem == null || pend.first.getStringExtra(EXTRA_DONO_DA_TELA) == deQuem)) {
                pedidoPendente = null
                Log.i(TAG, "pedido pendente de espelhar derrubado por um pedido de parar")
            }
            fonteEmCurso to donoDaTela
        }
        if (emCurso == null) {
            if (synchronized(cancelLock) { pedidoPendente == null }) stopSelf()
            return
        }
        if (deQuem != null && deQuem != dona) {
            Log.i(TAG, "pedido de parar de uma tela R5 que já não é a dona — ignorado")
            return
        }
        parar()
    }

    override fun onBind(intent: Intent): IBinder? {
        super.onBind(intent)
        return null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACAO_DESLIGAR_MICROFONE) {
            // Da notificação: o serviço já está em primeiro plano (a notificação é dele).
            microfone(false)
            return START_NOT_STICKY
        }
        if (intent?.action == ACAO_PARAR) {
            // A notificação e quem ainda mande `Intent`: o mesmo caminho de [pedirParada].
            pedidoDeParar(intent.getStringExtra(EXTRA_DONO_DA_TELA))
            return START_NOT_STICKY
        }
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val sourceKind = intent.getStringExtra(EXTRA_SOURCE_KIND) ?: SOURCE_SCREEN
        // **Uma espera por vez.** A tela R5 recriada sobe o serviço de novo com a sessão de pé: o
        // serviço adota a tela nova e segue, sem abrir outra câmera nem outra espera. Qualquer
        // outra combinação com uma thread em curso é recusada, e a tela que pediu lê o motivo.
        // A leitura de `fonteEmCurso` e a guarda do pendente são sob a mesma trava que o `finally`
        // da thread usa para soltar a fonte e ler o pendente: senão o pedido cairia entre os dois.
        val emCurso = synchronized(cancelLock) {
            fonteEmCurso.also { if (it != null && cancelado) pedidoPendente = intent to startId }
        }
        if (emCurso != null) {
            if (cancelado) {
                // A thread anterior está fechando (a tela R5 fechou e abriu de novo em seguida):
                // o pedido novo espera ela sair, e sai do `finally` dela. Nunca duas câmeras.
                Log.i(TAG, "pedido de espelhar ($sourceKind) enquanto a sessão anterior fecha — fica para depois dela")
            } else if (emCurso is Fonte.CameraDoPrompter && sourceKind == SOURCE_PROMPTER_CAMERA) {
                donoDaTela = intent.getStringExtra(EXTRA_DONO_DA_TELA)
                Log.i(TAG, "tela R5 nova adotada; a câmera e a espera seguem como estavam")
            } else {
                Log.w(TAG, "pedido de espelhar ($sourceKind) com outro espelhamento em curso — recusado")
                MirrorBus.atualizar { it.copy(mensagem = tx(R.string.esp_ja_ha_espelhamento)) }
                // A tela do DVD espera o estado da transmissão: sem isto ficava em "Preparando…".
                if (sourceKind == SOURCE_DVD) recusarDvd(tx(R.string.esp_ja_ha_espelhamento_dvd))
            }
            return START_NOT_STICKY
        }
        // Daqui em diante todo estado publicado diz de quem é a sessão (inclusive o erro e o PARADO).
        MirrorBus.sessaoDaTelaR5 = sourceKind == SOURCE_PROMPTER_CAMERA
        MirrorBus.sessaoDoDvd = sourceKind == SOURCE_DVD
        startForegroundCompat(tx(R.string.esp_preparando), sourceKind)
        // Sem o tipo `microphone`: o botão começa desligado, e ele entra só quando o botão liga.
        tipoMicrofoneNoServico = false

        if (!QuallNative.carregado) {
            // O modo de falha que só aparece no A10s: APK sem a ABI do aparelho. Precisa ser dito
            // com todas as letras, não virar "não conectou".
            publicarErro(tx(R.string.esp_nucleo_nao_carregou, QuallNative.erroDeCarga.toString(), Build.SUPPORTED_ABIS.firstOrNull().orEmpty()))
            if (sourceKind == SOURCE_DVD) recusarDvd(tx(R.string.esp_nucleo_nao_carregou_curto))
            stopSelf()
            return START_NOT_STICKY
        }

        val fonte: Fonte = if (sourceKind == SOURCE_PROMPTER_CAMERA) {
            val id = intent.getStringExtra(EXTRA_CAMERA_ID)
            if (id == null) {
                publicarErro("sem id de câmera") // i18n-fora: pedido malformado, só de quem programa
                stopSelf()
                return START_NOT_STICKY
            }
            donoDaTela = intent.getStringExtra(EXTRA_DONO_DA_TELA)
            Fonte.CameraDoPrompter(id, intent.getStringExtra(EXTRA_CAMERA_LABEL)?.takeIf { it.isNotBlank() } ?: tx(R.string.esp_frontal))
        } else if (sourceKind == SOURCE_DVD) {
            val titulo = intent.getIntExtra(EXTRA_DVD_TITULO, -1)
            if (titulo < 0) {
                publicarErro("sem título do DVD") // i18n-fora: pedido malformado, só de quem programa
                recusarDvd(tx(R.string.esp_escolha_um_titulo))
                stopSelf()
                return START_NOT_STICKY
            }
            Fonte.Dvd(titulo, intent.getIntExtra(EXTRA_DVD_FAIXA, 0), intent.getLongExtra(EXTRA_DVD_INICIO, 0))
        } else if (sourceKind == SOURCE_CAMERA) {
            val id = intent.getStringExtra(EXTRA_CAMERA_ID)
            val label = intent.getStringExtra(EXTRA_CAMERA_LABEL)?.takeIf { it.isNotBlank() } ?: tx(R.string.esp_camera)
            if (id == null) {
                publicarErro("sem id de câmera") // i18n-fora: pedido malformado, só de quem programa
                stopSelf()
                return START_NOT_STICKY
            }
            val dv = Fonte.Camera(id, label).dv
            val peloCameraX = Bancada.cameraComumPeloCameraX(this)
            if (!dv && peloCameraX) Log.i(TAG, "bancada: a câmera comum pelo CameraXSource (o braço de controle), sem gravação")
            Fonte.Camera(id, label, peloDono = !dv && !peloCameraX)
        } else {
            val resultData: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
            if (resultData == null) {
                publicarErro("sem dados de consentimento do MediaProjection") // i18n-fora: pedido malformado
                stopSelf()
                return START_NOT_STICKY
            }
            Fonte.Tela(
                resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                resultData = resultData,
                width = intent.getIntExtra(EXTRA_WIDTH, 720),
                height = intent.getIntExtra(EXTRA_HEIGHT, 1280),
                dpi = intent.getIntExtra(EXTRA_DPI, 320),
            )
        }

        multicastLock = MulticastLockManager(this).also { it.acquire() }
        radioAcordado = com.quall.android.core.RadioAcordado(this).also {
            if (com.quall.android.core.Bancada.radioAcordado(this)) it.adquirir()
        }

        // Nenhuma thread em curso daqui para baixo (a guarda acima): um `cancelado` que tenha
        // ficado da sessão anterior, neste mesmo serviço, não pode fazer a espera nova sair na
        // primeira volta. O mesmo para a fonte USB (ou o DVD) que caiu na sessão anterior e o motivo
        // dela (a T1 do DVD: a segunda transmissão no mesmo serviço saía na primeira volta).
        cancelado = false
        cameraDvCaiu = false
        motivoDaParada = null
        fonteEmCurso = fonte
        tipoDaFonte = sourceKind
        // **O botão começa desligado** a cada espelhamento (§4.2), e só existe com a câmera.
        microfonePedido = false
        MicrofoneBus.atualizar {
            // O DVD não tem microfone: o som dele vai na track de som da sessão (§9).
            EstadoDoMicrofone(disponivel = fonte !is Fonte.Tela && fonte !is Fonte.Dvd, abreAoGravar = fonte.usaDono())
        }
        gravacaoUsaCamera = false
        if (fonte.usaDono()) {
            // A gravação existe onde há dono: a tela R5 e, desde 24/09, a câmera comum (§8.6). A DV
            // grava pelo caminho dela ("Gravar a fita", `GravacaoDvService`).
            val prefixo = if (fonte is Fonte.CameraDoPrompter) "Quall-R5" else "Quall-Camera"
            gravacaoDaTela = GravacaoDaTela(this, prefixo) { g -> pendurarSomDaGravacao(g) }.also { gr ->
                // **O `gr` capturado, e não o campo** (a revisão da fase 3, bloqueio 1): o vigia pode
                // pedir a parada depois de o fim da thread ter zerado o campo.
                gr.aoPrecisarParar = { motivo ->
                    runCatching { obrasDaGravacao.execute { gr.parar(motivo); cameraSoltaPelaGravacao(); renotificar() } }
                        .onFailure { gr.encerrar(tx(R.string.esp_servico_fechando_porque, motivo.toString())) }
                }
            }
            // O número da recusa não volta a zero: a tela compara com o último que viu. O motivo de
            // não gravar vem logo abaixo, conferido fora da principal.
            GravacaoDaTelaBus.atualizar {
                GravacaoDaTelaBus.Estado(
                    disponivel = true, daCameraComum = fonte is Fonte.Camera,
                    numeroDaRecusa = it.numeroDaRecusa, recusa = it.recusa,
                    indisponivel = it.indisponivel, indisponivelConferido = false,
                    // O recado dos pendentes ("não pôde ser recuperada") não some com a abertura.
                    mensagem = it.mensagem,
                )
            }
            // O aparelho que não grava diz antes do toque (§14.3, caso 1); o que grava diz com quê
            // (§14.10): uma linha por abertura, no formato das quatro cascas. **Fora da principal**
            // (a revisão de 28/09): a primeira conta consulta o `MediaCodecList` e o pacote.
            thread(name = "quall-gravacao-indisponivel") {
                val indisponivel = runCatching { GravacaoIndisponivel.motivo(this) }.getOrNull()
                if (indisponivel != null) {
                    Log.i(TAG, "APP GRAVACAO indisponível: $indisponivel")
                } else {
                    Log.i(TAG, "APP GRAVACAO gravador=${if (com.quall.android.capture.dv.QuallDv.disponivel) "qualldv" else "mediamuxer"}")
                }
                GravacaoDaTelaBus.atualizar {
                    if (!it.disponivel) it else it.copy(indisponivel = indisponivel, indisponivelConferido = true)
                }
            }
            // Os arquivos de uma gravação interrompida (processo morto) são publicados agora: uma vez
            // por processo (§5.4, M2). **Numa thread própria, e não na fila da gravação** (a revisão,
            // médio 2): remontar leva minutos com um arquivo grande, e o primeiro Gravar esperaria.
            // Uma gravação que começa no meio faz a remontagem desistir (`GravacaoDaTelaBus.comecos`).
            thread(name = "quall-pendentes") {
                runCatching { com.quall.android.capture.dv.GravacaoDvService.publicarPendentes(applicationContext) }
                    .onFailure { Log.w(TAG, "pendentes: ${Log.erroExterno(it.message)}") }
            }
        }
        val minhaGeracao = geracao.incrementAndGet()
        thread(name = "quall-mirror") {
            try {
                espelhar(fonte, minhaGeracao)
            } catch (e: Throwable) {
                Log.e(TAG, "espelhamento morreu", e)
                // **A causa, quando ela é conhecida, vem antes da consequência.**
                //
                // A exceção que chega aqui é quase sempre a ÚLTIMA da cadeia — em 09/09/2026, no
                // S24, foi `IllegalStateException: Pending dequeue output buffer request
                // cancelled`, que é o `dequeueOutputBuffer` sendo cancelado depois de a câmera ter
                // sido tomada quatro segundos antes pelo desbloqueio por rosto. Mandar essa frase
                // para o usuário é mandá-lo procurar defeito no lugar errado.
                val motivo = if ((fonte as? Fonte.Camera)?.dv == true) null
                    else com.quall.android.capture.CameraXSource.ultimoMotivoDaCamera
                publicarErro(
                    if (motivo != null) tx(R.string.esp_transmissao_parou, motivo)
                    else tx(R.string.esp_espelhamento_parou, e.javaClass.simpleName, e.message.toString())
                )
            } finally {
                runCatching { projection?.stop() }
                projection = null
                runCatching { projectionThread?.quitSafely() }
                projectionThread = null
                synchronized(travaDaCamera) {
                    runCatching { cameraSource?.parar() }
                    cameraSource = null
                }
                // **A gravação fecha antes da câmera** (§5.3: "pela tela R5 fechando"): o arquivo
                // recebe o fim de fluxo com a saída do divisor ainda viva, e é publicado. Na fila da
                // gravação, e esperando: um começo em curso termina antes.
                //
                // **Encerrada, e não só parada** (a revisão, bloqueio 1): um "gravar" que já estava na
                // fila atrás deste fim, ou que chegue depois, é recusado pelo próprio controlador — sem
                // isso ele abria um arquivo com a câmera fechando, e ninguém o fechava mais.
                gravacaoDaTela?.let { g ->
                    g.marcarEncerrada()
                    val fim = java.util.concurrent.CountDownLatch(1)
                    val postou = runCatching {
                        obrasDaGravacao.execute {
                            try { g.encerrar(tx(R.string.esp_tela_com_camera_fechou)) } finally { fim.countDown() }
                        }
                    }.isSuccess
                    if (!postou) {
                        g.encerrar(tx(R.string.esp_tela_com_camera_fechou))
                    } else if (!fim.await(15, java.util.concurrent.TimeUnit.SECONDS)) {
                        Log.e(TAG, "a gravação não fechou em 15 s — a câmera fecha assim mesmo; o arquivo fica pendente")
                    }
                }
                gravacaoDaTela = null
                GravacaoDaTelaBus.atualizar { it.copy(disponivel = false) }
                // A geração avança antes de fechar: uma abertura desta thread que ainda esteja em
                // curso em `obrasDaCamera` vê a geração velha e fecha o que abriu (a revisão, M1).
                geracao.incrementAndGet()
                fecharDonoDaCaptura()
                // Na thread de espelhamento, e nunca no `onDestroy`: fechar a lib com a thread
                // `quall-dv` dentro dela seria uso depois de liberar (a revisão, A3). A posse volta
                // ao dono: a fonte só fecha se a prévia e a gravação também não a têm.
                posseDv?.let { p -> runCatching { com.quall.android.capture.dv.DonoDaPlaca.soltar(p) } }
                posseDv = null
                val tinhaDvd = transmissaoDvd != null
                fecharDvd()
                // A thread que caiu com o DVD sem transmissão aberta (a revisão, 5): a tela do DVD sai do
                // "Preparando…" com o erro, e não fica esperando um PARADA que ninguém publica.
                if (fonte is Fonte.Dvd && !tinhaDvd && com.quall.android.dvd.TransmissaoDvdBus.transmitindo) {
                    recusarDvd(MirrorBus.atual.mensagem.ifBlank { tx(R.string.esp_dvd_parou) })
                }
                com.quall.android.capture.dv.DonoDaPlaca.pararDeOuvirAvisoDoSom(avisoDoSomDaPlaca)
                runCatching { multicastLock?.release() }
                runCatching { radioAcordado?.liberar() }
                // O pedido que esperava esta sessão fechar sobe agora, pelo caminho de sempre, na
                // principal (onde o `onStartCommand` roda). Sem ele, o serviço sai.
                val principal = android.os.Handler(mainLooper)
                // A sessão já soltou o microfone da rede (o `finally` dela) e a gravação já fechou;
                // o botão deixa de existir, e o microfone fecha se ainda estiver aberto.
                microfonePedido = false
                somDaGravacao = null
                runCatching { obrasDoMicrofone.execute { aplicarMicrofone() } }
                MicrofoneBus.atualizar { EstadoDoMicrofone() }
                val proximo = synchronized(cancelLock) {
                    fonteEmCurso = null
                    donoDaTela = null
                    pedidoPendente.also { pedidoPendente = null }
                }
                // Na principal, que é onde o `onStartCommand` e os pedidos de parar rodam: ali a
                // decisão de sair não cruza com um pedido novo. **`stopSelf()` e não
                // `stopSelf(startId)`** (a revisão, B1): qualquer pedido de parar tem `startId`
                // maior que o da espera, e com ele o serviço nunca saía.
                principal.post {
                    if (proximo != null) {
                        onStartCommand(proximo.first, 0, proximo.second)
                    } else if (synchronized(cancelLock) { fonteEmCurso == null && pedidoPendente == null }) {
                        stopSelf()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    // ---------------------------------------------------------------------------------------

    private fun espelhar(fonte: Fonte, minhaGeracao: Int) {
        val proj: MediaProjection? = if (fonte is Fonte.Tela) {
            val mpm = getSystemService(MediaProjectionManager::class.java)
            val p = try {
                mpm.getMediaProjection(fonte.resultCode, fonte.resultData)
                    ?: throw IllegalStateException("getMediaProjection devolveu null")
            } catch (e: Exception) {
                publicarErro(tx(R.string.esp_captura_recusada, e.message.toString()))
                return
            }
            projection = p

            // Callback de nível de serviço, separado do que o encoder registra: é ele que revela a
            // morte do consentimento **entre** sessões, quando não há encoder nenhum vivo para
            // ouvir. Só existe para a tela — a câmera não tem esse conceito.
            val ht = HandlerThread("quall-mirror-projection").also { it.start() }
            projectionThread = ht
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "MediaProjection.onStop — o consentimento de gravação terminou")
                    projecaoParada = true
                    motivoDaParada = tx(R.string.esp_consentimento_encerrado)
                    // **Acordar a espera, e pelo caminho que o `parar()` já usa.**
                    //
                    // `hostStart` prende a thread `quall-mirror` por até `ESPERA_MS` (300 s). Sem
                    // isto, bloquear o telefone antes de um receptor conectar deixava a sessão
                    // pendurada cinco minutos com o consentimento já morto — o usuário volta ao
                    // app e encontra "esperando um aparelho" para uma captura que não existe mais.
                    //
                    // O `cancelLock` não é higiene: em toda parada limpa, o `finally` de
                    // `espelhar` faz `cancellerFree` e só depois o `finally` da thread chama
                    // `projection.stop()` — que dispara **este** `onStop`. Ler o campo solto aqui
                    // seria uso após liberação a cada sessão encerrada. O trinco zera o campo
                    // antes de liberar, e por isso a leitura dentro dele é segura.
                    synchronized(cancelLock) {
                        if (cancellerHandle != 0L) QuallNative.sessionCancel(cancellerHandle)
                    }
                }
            }, Handler(ht.looper))
            p
        } else null

        val eu = DeviceIdentity.load(this)
        // WRONG_PIN/PAIRING renovam o PIN antes da próxima espera por política conservadora,
        // sem inferir fase ou modo pelo status. Outros erros preservam o valor; os pares
        // salvos e o segredo forte usado na retomada permanecem intactos.
        var pin = QuallNative.generatePin()
        val porta = Bancada.porta(this)
        Log.i(TAG, "bancada: ${Bancada.resumo(this)}")
        // Antes de a câmera abrir: é na volta ao app, com a sessão já no ar, que a guarda age.
        com.quall.android.capture.PreviaDaCamera.configurarSuspensao(
            Bancada.suspenderPreviaNaVolta(this),
        )
        val enderecos = enderecosLocais().map { EnderecosLocais.comPorta(it, porta) }

        val caps = if (fonte !is Fonte.Tela) QuallNative.CAP_CAMERA else QuallNative.CAP_SCREEN
        val trackKind = if (fonte !is Fonte.Tela) QuallNative.TrackKind.CAMERA else QuallNative.TrackKind.SCREEN
        // O do vídeo USB é refeito depois de abrir: o tipo (placa ou filmadora) só se sabe ali.
        // Para ler (a notificação, a espera): no idioma de agora. Quem decide é `MirrorBus.Estado.daTela`.
        var fonteRotulo = when (fonte) {
            is Fonte.Camera -> tx(R.string.esp_fonte_camera, fonte.label)
            is Fonte.CameraDoPrompter -> tx(R.string.esp_fonte_camera, fonte.label)
            is Fonte.Tela -> tx(R.string.esp_fonte_tela)
            is Fonte.Dvd -> tx(R.string.esp_fonte_dvd)
        }
        var nomeDaCamera = when (fonte) {
            is Fonte.Camera -> fonte.label
            is Fonte.CameraDoPrompter -> fonte.label
            else -> ""
        }
        // O nome da track vai pelo protocolo e aparece no receptor, que pode estar em outro idioma:
        // fica como sempre foi (`docs/traducao.md`, "Fora").
        val rotulo = when (fonte) {
            is Fonte.Camera -> "Câmera ${fonte.label} do ${eu.displayName}" // i18n-fora: protocolo (nome da track)
            is Fonte.CameraDoPrompter -> "Câmera ${fonte.label} do ${eu.displayName}" // i18n-fora: protocolo (nome da track)
            is Fonte.Tela -> "Tela do ${eu.displayName}"
            is Fonte.Dvd -> "DVD do ${eu.displayName}"
        }

        // **O DVD abre antes do PIN** (§9): o leitor e o disco vêm da tela (a [SessaoDoDvd]), a proteção
        // é conferida de novo, e a leitura e a decodificação começam já — o primeiro quadro fica pronto
        // antes de o receptor conectar, e o relógio só anda com ele.
        if (fonte is Fonte.Dvd) {
            val t = abrirDvd(fonte) ?: return
            transmissaoDvd = t
            fonteRotulo = tx(R.string.esp_fonte_dvd_titulo, t.volume, t.titulo.numero)
        }

        // --- as tracks de som: a da tela é opcional, a do microfone da câmera vai sempre --------
        //
        // **A tela: desligada no produto**, e isso é honestidade e não timidez: capturar o som do
        // sistema no Android exige `MediaProjection` **e** a permissão de tempo de execução
        // `RECORD_AUDIO`, que é um diálogo que só o usuário toca. Anunciar uma track de áudio que
        // na maioria dos aparelhos nunca entregaria byte nenhum deixaria o receptor com um
        // `AudioTrack` aberto esperando som que não vem — pior do que não anunciar. Com
        // `audio_tom_de_prova` ligado, a origem é o tom sintético e não há permissão nenhuma no
        // caminho: é o braço que a bancada mede (`docs/audio.md` §8).
        //
        // **A câmera: a track `MICROPHONE` vai sempre na oferta** (R5, fase 2;
        // `docs/teleprompter-com-camera.md` §4.2), porque o botão do microfone pode ligar no meio
        // da sessão e o que não está na oferta só entra com renegociação. Com o botão desligado ela
        // fica calada: nenhum pacote sai, e o receptor que puxa o som fica ocioso — estado normal,
        // não defeito. Vale para todo emissor de câmera (a tela R5, a câmera comum, a filmadora DV).
        // O tom de prova da tela não vale para a câmera (a oferta só leva uma track de som): a
        // bancada da câmera troca o microfone pelo tom com `microfone_de_prova`.
        val tomDeProva = Bancada.tomDeProva(this)
        val comMicrofone = fonte !is Fonte.Tela && fonte !is Fonte.Dvd
        // O DVD: o som do disco na track de som da sessão (estéreo, `SYSTEM_AUDIO`), sem permissão
        // nenhuma — não há captura (§9). Sem faixa que o Quall decodifique, a oferta vai sem som.
        val comAudio = (fonte is Fonte.Tela && (Bancada.emitirAudio(this) || tomDeProva) &&
            (tomDeProva || temPermissaoDeGravacao())) || (fonte is Fonte.Dvd && transmissaoDvd?.temSom == true)
        // O da placa de captura é refeito depois de abrir ("Som da placa do …").
        var rotuloDoAudio = when {
            fonte is Fonte.Dvd -> "Som do DVD do ${eu.displayName}" // i18n-fora: protocolo (nome da track)
            comMicrofone -> "Microfone do ${eu.displayName}"
            tomDeProva -> "Tom de prova do ${eu.displayName}"
            else -> "Som do ${eu.displayName}"
        }
        if (comAudio) {
            Log.i(TAG, "a oferta leva track de áudio: origem=${when {
                fonte is Fonte.Dvd -> "o som do DVD" // i18n-fora: diário
                tomDeProva -> "tom sintético" // i18n-fora: diário
                else -> "AudioPlaybackCapture"
            }}")
        }
        if (comMicrofone) {
            Log.i(TAG, "a oferta leva a track do microfone (MICROPHONE), calada até o botão ligar" +
                if (Bancada.microfoneDeProva(this)) " — bancada: o tom no lugar do microfone" else "")
        }

        // `sem_mdns` é de bancada e existe para uma promessa poder ser verdadeira: o laço dentro
        // do aparelho diz que nada vai ao ar, e um anúncio multicast é tráfego no ar.
        val anunciante = if (Bancada.semMdns(this)) {
            Log.i(TAG, "anúncio mDNS desligado por bancada — só o endereço digitado funciona")
            0L
        } else {
            QuallNative.advertiserStart(eu.deviceId, eu.displayName, caps, porta)
        }
        if (anunciante == 0L && !Bancada.semMdns(this)) {
            // Não é fatal: o caminho por IP digitado existe justamente para redes que barram
            // multicast, e é o mesmo caminho de código do mDNS do outro lado.
            Log.w(TAG, "anúncio mDNS não subiu status=${QuallNative.lastStatus()}: ${Log.erroExterno(QuallNative.lastError())} — só o IP digitado vai funcionar")
        }
        val aliasNaRede = if (anunciante != 0L) QuallNative.advertiserLabel(anunciante) else ""

        val canceller = QuallNative.cancellerNew()
        synchronized(cancelLock) { cancellerHandle = canceller }

        // --- a prévia, ANTES de qualquer receptor -------------------------------------------
        //
        // A pessoa que vai transmitir a câmera precisa acertar o enquadramento **enquanto espera**,
        // e não descobrir o que estava filmando só quando o receptor entra. No iOS já é assim: a
        // `AVCaptureSession` da `TelaDaCamera` roda independente da sessão do Quall. Até 03/09 a
        // câmera só abria dentro de `conduzirSessao`, ou seja depois do pareamento — quem emitia
        // câmera emitia às cegas até ali (`docs/bancada.md` §8.15, defeito 2).
        //
        // Fora do laço porque `hostStart` prende esta thread por até `ESPERA_MS`; e no executor
        // porque abrir câmera leva centenas de milissegundos e o PIN não pode esperar por ela.
        if (fonte is Fonte.Camera && fonte.dv) {
            // A placa transmite com a gravação no ar (a mesma fonte, pelo dono); a filmadora DV não:
            // o dono recusa a posse da rede com a gravação dela ([DonoDaPlaca.Ocupada]).
            // O vídeo USB abre aqui (ou já está aberto pela prévia parada da tela), na thread de
            // espelhamento, e atravessa as sessões. A desconexão, também durante a espera, acorda o
            // `hostStart` como o `MediaProjection.onStop` acorda.
            // A frase da pausa, uma por sessão: a volta a apaga comparando com **esta** (e não com um
            // literal, que muda com o idioma).
            val fraseDaPausa = tx(R.string.esp_camera_parada)
            val ouvinte = object : com.quall.android.capture.dv.FonteDv.Ouvinte {
                override fun aoPausar() {
                    MirrorBus.atualizar { it.copy(mensagem = fraseDaPausa) }
                }
                override fun aoVoltar(pausaMs: Long) {
                    // O receptor que ficou sem quadro recomeça de um IDR.
                    encoder?.requestSyncFrame()
                    MirrorBus.atualizar {
                        if (it.mensagem == fraseDaPausa) it.copy(mensagem = "") else it
                    }
                }
                override fun aoCair(motivo: String) {
                    cameraDvCaiu = true
                    motivoDaParada = tx(R.string.esp_sessao_terminou, motivo)
                    encoder?.stop()
                    synchronized(cancelLock) {
                        if (cancellerHandle != 0L) QuallNative.sessionCancel(cancellerHandle)
                    }
                }
            }
            val posse = try {
                com.quall.android.capture.dv.DonoDaPlaca.pegar(
                    this, fonte.cameraId, com.quall.android.capture.dv.DonoDaPlaca.Uso.REDE, ouvinte,
                )
            } catch (e: Exception) {
                // Qualquer exceção, e não só a nossa: um `SecurityException` do aparelho que saiu
                // entre `hasPermission` e `openDevice` também tem de liberar o anúncio.
                publicarErro(
                    if (e is com.quall.android.capture.dv.DonoDaPlaca.Ocupada) e.message!!
                    else tx(R.string.esp_nao_abriu, nomeDoVideoUsb(fonte.cameraId), e.message ?: e.javaClass.simpleName)
                )
                synchronized(cancelLock) { cancellerHandle = 0L }
                QuallNative.cancellerFree(canceller)
                if (anunciante != 0L) QuallNative.advertiserStop(anunciante)
                return
            }
            posseDv = posse
            // "Placa de captura (…)" ou "Filmadora DV (…)", pelo que abriu (e não pelo rótulo da lista,
            // que antes da primeira abertura diz "Vídeo USB").
            nomeDaCamera = com.quall.android.capture.dv.VideoUsb.rotulo(
                com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this)),
                com.quall.android.capture.dv.VideoUsb.conhecido(posse.fonte.tipo, false),
                // Sem nome de produto (a MS2109 `345f`): o `vid:pid`, e não o rótulo da lista, que já diz
                // "Placa de captura (…)" e saía em dobro no diário e no rótulo da sessão.
                posse.fonte.nomeDoAparelho ?: posse.fonte.aparelhoUsb?.let { com.quall.android.capture.dv.UsbDv.produto(it) } ?: fonte.label,
            )
            fonteRotulo = tx(R.string.esp_fonte_camera, nomeDaCamera)
            if (posse.fonte.mjpeg) {
                // **O som da placa** (§11, item 3): a track do "microfone" leva o som da entrada USB da
                // placa (um ramal do `AudioRecord` do dono), o botão diz "Som da placa" e **começa
                // ligado** (decisão do Pessoa Exemplo, 28/09: na placa o som é parte do sinal). Sem a permissão
                // do microfone, ele fica desligado com o motivo, e o toque a pede.
                rotuloDoAudio = "Som da placa do ${eu.displayName}" // i18n-fora: protocolo (nome da track)
                com.quall.android.capture.dv.DonoDaPlaca.ouvirAvisoDoSom(avisoDoSomDaPlaca)
                val pelaUsb = posse.fonte.temSomUsb
                MicrofoneBus.atualizar { it.copy(daPlaca = true, semMicrofone = pelaUsb) }
                android.os.Handler(mainLooper).post {
                    // Pelo usbfs (§13.10) o som da placa não é um `AudioRecord`: sem a permissão.
                    if (pelaUsb || temPermissaoDeGravacao() || Bancada.microfoneDeProva(this)) microfone(true)
                    else MicrofoneBus.atualizar { it.copy(ligado = false, capturando = false).comMotivo(com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this@MirrorService)), MotivoDoMicrofone.SEM_PERMISSAO) }
                }
            } else {
                // **O som da fita** (§13.8): a track do "microfone" leva o som que vem dentro do DV (um
                // ramal da `FonteDv`), o botão diz "Som da fita" e começa ligado. Sem microfone nenhum:
                // nem a permissão, nem o tipo `microphone` no serviço.
                rotuloDoAudio = "Som da fita do ${eu.displayName}" // i18n-fora: protocolo (nome da track)
                MicrofoneBus.atualizar { it.copy(daFita = true, semMicrofone = true) }
                android.os.Handler(mainLooper).post { microfone(true) }
            }
            // A thread da fonte já corria antes de a posse existir: uma queda nesse intervalo não
            // chamou ninguém.
            if (posse.fonte.desconectada) ouvinte.aoCair(tx(R.string.esp_camera_desconectada))
        } else if (fonte is Fonte.CameraDoPrompter) {
            // A câmera da tela R5 abre já, e fora desta thread: o PIN não espera por ela. Ela não
            // segue a presença da tela (`PreviaDaCamera.observarTela` não é registrado): fica aberta
            // enquanto a tela R5 existir.
            abrirDonoDaCaptura(fonte.cameraId, minhaGeracao)
        } else if (fonte is Fonte.Camera) {
            cameraDaEspera = fonte.cameraId
            // Registrar **depois** de `cameraDaEspera`, senão um sinal que chegue no meio é
            // descartado por não saber de qual câmera se trata.
            PreviaDaCamera.observarTela(aoMudarTela)
            if (PreviaDaCamera.telaOlhando) {
                obrasDaCamera.execute { ajustarPreviaDeEspera(fonte.cameraId, true) }
            }
        }

        var tentativa = 0
        var falhasImediatas = 0
        // **A razão da última recusa sobrevive à volta seguinte.** Sem isto ela era escrita no
        // `MirrorBus` e apagada pela publicação do topo do laço antes de qualquer olho ver — o
        // defeito que a §8.36 registrou e a §8.49 mediu. "tentativa 5" sozinho não diz que alguém
        // errou o PIN quatro vezes.
        var ultimaRecusa: String? = null
        try {
            while (!cancelado && !projecaoParada && !cameraDvCaiu) {
                tentativa++
                MirrorBus.publicar(
                    MirrorBus.Estado(
                        fase = MirrorBus.Fase.ESPERANDO,
                        pin = pin,
                        enderecos = enderecos,
                        fonteRotulo = fonteRotulo,
                        daTela = fonte is Fonte.Tela,
                        nomeDaCamera = nomeDaCamera,
                        // O vídeo USB e a placa ditos por campo, e não pelo texto do rótulo (§11, item 2).
                        videoUsb = (fonte as? Fonte.Camera)?.dv == true,
                        daPlaca = fonteDv?.mjpeg == true,
                        tentativa = tentativa,
                        // A taxa que **vai** ser pedida, lida agora: nesta fase a sessão ainda não
                        // subiu e não existe `fpsEscolhido` congelado.
                        fpsPedido = com.quall.android.core.Resolucao.quadros(this@MirrorService),
                        mensagem = buildString {
                            append(
                                if (anunciante == 0L) tx(R.string.esp_sem_anuncio)
                                else tx(R.string.esp_anunciando, aliasNaRede, QuallNative.serviceType())
                            )
                            ultimaRecusa?.let { append('\n').append(tx(R.string.esp_ultima_recusa, it)) }
                        },
                        // Estado, não aviso; e o anúncio dito por campo (a frase é traduzida).
                        mensagemEhAnuncio = true,
                        anunciando = anunciante != 0L,
                        aliasNaRede = aliasNaRede,
                    )
                )
                atualizarNotificacao(tx(R.string.esp_notif_esperando, pin), fonteRotulo)

                val comecou = SystemClock.elapsedRealtime()
                val sessao = QuallNative.hostStart(
                    deviceId = eu.deviceId,
                    displayName = eu.displayName,
                    caps = caps,
                    pin = pin,
                    knownPeersJson = eu.knownPeersJson(),
                    porta = porta,
                    timeoutMs = ESPERA_MS,
                    trackKind = trackKind,
                    trackLabel = rotulo,
                    audioTrackKind = when {
                        comAudio -> QuallNative.TrackKind.SYSTEM_AUDIO
                        comMicrofone -> QuallNative.TrackKind.MICROPHONE
                        else -> -1
                    },
                    audioTrackLabel = rotuloDoAudio,
                    cancellerHandle = canceller,
                )
                val decorrido = SystemClock.elapsedRealtime() - comecou

                if (sessao == 0L) {
                    // Cancelado é checado primeiro: `parar()` já marcou `cancelado = true` antes
                    // de chamar `quall_session_cancel`, então o laço já sai por aqui sem tentar
                    // interpretar o motivo — cancelamento não é uma falha para relatar.
                    if (cancelado || cameraDvCaiu) break
                    // `lastError` é por thread; esta é a mesma thread que chamou `hostStart`.
                    val status = QuallNative.lastStatus()
                    val motivo = QuallNative.lastError()
                    val proximoPin = pinDepoisDaFalhaDaEspera(pin, status) { QuallNative.generatePin() }
                    if (proximoPin == null) {
                        val erro = tx(R.string.esp_pin_geracao_falhou)
                        // Retirar o PIN também da notificação antes de liberar a captura:
                        // o finally externo pode precisar aguardar o fechamento da gravação.
                        atualizarNotificacao(erro, fonteRotulo)
                        publicarErro(erro)
                        // Executa ambos os finally, preservando ERRO em vez do PARADO abaixo.
                        return
                    }
                    val pinRenovado = proximoPin != pin
                    if (pinRenovado) {
                        pin = proximoPin
                        ultimaRecusa = tx(R.string.esp_pin_renovado)
                        // Estado e notificação mudam antes de atender outra tentativa.
                        // O aviso não contém o PIN recusado nem dados da conexão.
                        MirrorBus.atualizar {
                            it.copy(pin = pin, fase = MirrorBus.Fase.ESPERANDO,
                                mensagem = ultimaRecusa.orEmpty(), mensagemEhAnuncio = false)
                        }
                        atualizarNotificacao(tx(R.string.esp_notif_esperando, pin), fonteRotulo)
                        Log.w(TAG, "pareamento encerrado (${QuallNative.Status.nome(status)}); PIN renovado")
                    }
                    // A rotação não isenta a falha do teto/recuo que já existia.
                    if (decorrido < FALHA_IMEDIATA_MS) {
                        falhasImediatas++
                        Log.w(TAG, "hostStart falhou em ${decorrido}ms: ${Log.erroExterno(motivo)}")
                        if (falhasImediatas >= FALHAS_IMEDIATAS_ATE_DESISTIR) {
                            publicarErro(tx(R.string.esp_sinalizacao_falhou, porta, motivo))
                            break
                        }
                        Thread.sleep(400)
                    } else {
                        falhasImediatas = 0
                        // Outras recusas mantêm o PIN. A razão permanece na próxima volta
                        // para a UI não apagar o diagnóstico antes de ele poder ser lido.
                        Log.w(TAG, "hostStart voltou em ${decorrido}ms sem sessão (tentativa " +
                            "$tentativa, alguém conectou e foi recusado): ${Log.erroExterno(motivo)}")
                        if (!pinRenovado) {
                            ultimaRecusa = motivo
                            MirrorBus.atualizar {
                                it.copy(fase = MirrorBus.Fase.ESPERANDO, mensagem = tx(R.string.esp_tentativa_anterior, motivo), mensagemEhAnuncio = false)
                            }
                        }
                    }
                    continue
                }
                falhasImediatas = 0

                try {
                    conduzirSessao(sessao, fonte, proj, eu, fonteRotulo, nomeDaCamera, comAudio, tomDeProva, comMicrofone, minhaGeracao)
                } catch (e: SecurityException) {
                    // Medido no A07 (Android 16), e **não** no A10s (Android 11), e só para a tela:
                    // terminada a primeira sessão, o sistema encerra o consentimento por conta
                    // própria e a `MediaProjection` fica inutilizável. A segunda
                    // `createVirtualDisplay` morre com "Don't take multiple captures by invoking
                    // MediaProjection#createVirtualDisplay multiple times on the same instance".
                    // Comportamento do Android 14+, não defeito nosso — e não existe para câmera,
                    // que não passa por `MediaProjection`.
                    if (fonte is Fonte.Tela) {
                        Log.w(TAG, "consentimento de gravação morreu com a sessão anterior", e)
                        projecaoParada = true
                        motivoDaParada = tx(R.string.esp_consentimento_encerrado)
                    } else {
                        throw e
                    }
                } finally {
                    // `quall_session_close` virou `QuallStatus` em 2026-08-26 (dívida 24). Este
                    // lado não registra tratador nenhum no núcleo — o pedido de IDR vem pela
                    // bandeira atômica —, então a barreira aqui não libera `user_data` de
                    // ninguém. Ainda assim o status é relatado: um `TIMEOUT` significaria que
                    // existe um tratador desta casca que não volta, e isso precisa aparecer.
                    val st = QuallNative.sessionClose(sessao)
                    if (st != QuallNative.Status.OK) {
                        Log.w(TAG, "quall_session_close: ${QuallNative.Status.nome(st)}")
                    }
                }

                if (projecaoParada || cameraDvCaiu) {
                    MirrorBus.publicar(
                        MirrorBus.Estado(fase = MirrorBus.Fase.PARADO, mensagem = mensagemDaParada())
                    )
                    return
                }
            }
        } finally {
            // A espera acabou: ninguém mais precisa da prévia, e o sinal da tela deixa de ter
            // câmera para abrir. Quem fecha a câmera de fato é o `finally` da thread, logo acima
            // desta chamada na pilha.
            PreviaDaCamera.observarTela(null)
            cameraDaEspera = null
            synchronized(cancelLock) { cancellerHandle = 0L }
            QuallNative.cancellerFree(canceller)
            if (anunciante != 0L) QuallNative.advertiserStop(anunciante)
        }

        MirrorBus.publicar(MirrorBus.Estado(fase = MirrorBus.Fase.PARADO, mensagem = mensagemDaParada()))
    }

    /**
     * A frase que o usuário lê quando a sessão termina.
     *
     * **"Quem já estava conectado volta sozinho, sem PIN" não é conforto: é o que o núcleo faz.**
     * O pareamento é chaveado pelo `DeviceId` e sobrevive à sessão, então um receptor já pareado
     * retoma sem digitar nada — e o plugin do OBS religa por conta própria a cada 3 s. A frase
     * anterior dizia *"toque em Espelhar para receber **outro** aparelho"*, que se lê como se o
     * aparelho que acabou de cair não pudesse voltar, e mandava o usuário mexer no receptor sem
     * necessidade.
     */
    private fun mensagemDaParada(): String =
        motivoDaParada?.let {
            // O DVD: a frase dele sozinha (a recusa do §2.1, o leitor que parou) — voltar é pela tela do DVD.
            if (fonteEmCurso is Fonte.Dvd) it
            else tx(R.string.esp_fim_com_motivo, it)
        } ?: tx(R.string.esp_espelhamento_encerrado)

    /** Sessão de pé: pega a track, roda o encoder até o receptor sair, e relata. */
    private fun conduzirSessao(
        sessao: Long,
        fonte: Fonte,
        proj: MediaProjection?,
        eu: DeviceIdentity,
        fonteRotulo: String,
        nomeDaCamera: String,
        comAudio: Boolean,
        tomDeProva: Boolean,
        comMicrofone: Boolean,
        minhaGeracao: Int,
    ) {
        val parJson = QuallNative.sessionPeerJson(sessao)
        val parNome = runCatching { JSONObject(parJson).optString("display_name") }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: tx(R.string.esp_receptor)
        val novo = QuallNative.sessionPairingIsNew(sessao)

        // Persistir aqui, e não no fim: se o app morrer no meio do espelhamento, o pareamento já
        // vale, e a próxima sessão não pede PIN.
        runCatching { QuallNative.sessionKnownPeersJson(sessao, eu.knownPeersJson()) }
            .getOrNull()
            ?.let { eu.saveKnownPeersJson(it) }

        if (QuallNative.sessionTrackCount(sessao) < 1) {
            publicarErro("a sessão subiu sem track de saída") // i18n-fora: defeito do núcleo, para quem programa
            return
        }
        val track = QuallNative.sessionTrack(sessao, 0)
        if (track == 0L) {
            publicarErro("quall_session_track falhou: ${QuallNative.lastError()}")
            return
        }

        // **A escolha do usuário, lida uma vez por sessão.** Ver `core/Resolucao.kt`.
        //
        // Subiu para cá em 08/09/2026 porque o limiar do `TrackFrameSink` passou a depender dela:
        // a leitura ficava depois da criação do sink, e o limiar era a constante 30.
        // A escolha do usuário, lida uma vez por sessão. Ver `core/Resolucao.kt`.
        val escolhida = com.quall.android.core.Resolucao.escolhida(this)
        val dv = (fonte as? Fonte.Camera)?.dv == true
        // A DV é 29,97 entrelaçado, e o cardápio de resolução e de fps não vale para ela; nem para a
        // placa de captura (MJPEG a 30, `docs/placa-de-captura-usb.md` §3.7), que vai pelo mesmo
        // caminho (`Fonte.Camera.dv` é "vídeo USB").
        val dvd = transmissaoDvd.takeIf { fonte is Fonte.Dvd }
        // O DVD anda na taxa do disco (29,97 ou 25), como a DV.
        val fpsEscolhido = if (dv) 30 else dvd?.fps ?: com.quall.android.core.Resolucao.quadros(this)
        // O tamanho da DV: o exibido pelo aspecto da câmera na abertura (854x480 em 16:9, 640x480
        // em 4:3), ou 848 se o codec não aceitar 854 (854 não é múltiplo de 16; a revisão, B9). O
        // da placa: o do quadro negociado (640x480), sem tarja e sem o aspecto da DV (o `disp_169`
        // leria o JPEG como VAUX e abriria o encoder em 854x480; a revisão, 6).
        val placaDeCaptura = dv && fonteDv?.mjpeg == true
        val geometriaDv: Pair<Int, Int>? = if (dv) {
            val fdv = fonteDv
            if (fdv != null && fdv.mjpeg) {
                val w = fdv.larguraDoQuadro and 1.inv()
                val h = fdv.alturaDoQuadro and 1.inv()
                Log.i(TAG, "placa de captura: MJPEG ${fdv.larguraDoQuadro}x${fdv.alturaDoQuadro} -> ${w}x$h a 30")
                w to h
            } else {
                val a = fdv?.aspectoDaAbertura() ?: 1
                val w = if (a == 1) larguraDv169() else 640
                Log.i(TAG, "câmera DV: aspecto ${if (a == 1) "16:9" else "4:3"} na abertura -> ${w}x480")
                w to 480
            }
        } else null
        // **A tela R5 e a câmera comum pelo dono** (§8.6): a câmera já está aberta (desde que a tela
        // R5 abriu, ou desde a prévia da espera) ou abre agora, e a sessão só se pendura no divisor.
        // A rede codifica a imagem em pé na tela, neste instante, dentro do teto do nível — e fica
        // nesse tamanho pela sessão; um giro no meio vira tarja, desenhada pelo divisor.
        //
        // Na câmera comum isso é uma mudança: pelo `CameraXSource` a rede levava o buffer do sensor
        // como veio (deitado, com o aparelho em pé); pelo dono ela vai em pé, como na tela R5 e no iOS.
        val comumPeloDono = fonte is Fonte.Camera && fonte.peloDono
        // A câmera comum não fecha por falta de tela enquanto a sessão a usa (marcado antes de ler o
        // dono: um fechamento por ociosidade já na fila vê a marca, ou já fechou e a sessão reabre).
        if (comumPeloDono) synchronized(travaDaCamera) { codificandoCamera = true }
        // **O aparelho fraco transmite a câmera em 720p** (`core/TransmissaoLeve.kt`, §14.15): só nas
        // fontes pelo dono (a tela R5 e a câmera comum), onde a rede é um codificador a mais sobre o
        // divisor. O braço de bancada pelo CameraX e a tela não mudam.
        val motivoLeve = if (fonte is Fonte.CameraDoPrompter || comumPeloDono) {
            com.quall.android.core.TransmissaoLeve.motivo(this)
                ?.takeIf { escolhida.maxFs > com.quall.android.core.TransmissaoLeve.TETO.maxFs }
        } else null
        val resolucao = com.quall.android.core.Resolucao.entries.first {
            it.maxFs == com.quall.android.core.TransmissaoLeve.maxFs(escolhida, motivoLeve != null)
        }
        if (resolucao != escolhida) Log.i(TAG, "transmissão leve: a rede da câmera em ${resolucao.rotulo}, e não ${escolhida.rotulo} ($motivoLeve)")
        val donoR5 = if (fonte is Fonte.CameraDoPrompter || comumPeloDono) {
            val id = (fonte as? Fonte.CameraDoPrompter)?.cameraId ?: (fonte as Fonte.Camera).cameraId
            esperarDonoDaCaptura(id, minhaGeracao) ?: run {
                publicarErro(tx(if (comumPeloDono) R.string.esp_camera_nao_abriu else R.string.esp_camera_frontal_nao_abriu,
                    falhaDoDono ?: tx(R.string.esp_motivo_desconhecido)))
                if (comumPeloDono) {
                    synchronized(travaDaCamera) { codificandoCamera = false }
                    reavaliarCameraComum()
                }
                QuallNative.trackFree(track)
                return
            }
        } else null
        // **A rotação da rede**: na tela R5, a da tela (e um giro no meio vira tarja); na câmera comum,
        // a do APARELHO no pareamento, congelada pela sessão (a revisão de 24/09, B1) — o app fica
        // atrás no tripé, e a tela do momento é a de outro app, a do bloqueio, ou retrato fixo.
        val rotacaoDaRede: Int? = if (comumPeloDono) donoR5?.rotacaoDeReferencia else null
        val geometriaR5: Pair<Int, Int>? = donoR5?.let { d ->
            val naTela = d.tamanhoNaTela(rotacaoDaRede ?: d.rotacaoDaTela)
            val g = QuallNative.tetoDeResolucaoPar(naTela.width, naTela.height, fpsEscolhido, resolucao.maxFs)
                ?: (naTela.width to naTela.height)
            Log.i(TAG, "${if (comumPeloDono) "câmera comum pelo dono" else "tela R5"}: câmera em ${d.resolucaoDaCamera}, imagem em pé ${naTela.width}x${naTela.height} " +
                "(rotação ${(rotacaoDaRede ?: d.rotacaoDaTela) * 90}°, de ${if (comumPeloDono) d.origemDaReferencia else "a tela"}" +
                "${if (comumPeloDono) ", fixa pela sessão" else ""}), rede em ${g.first}x${g.second}")
            g
        }
        Log.i(TAG, "resolução escolhida: ${resolucao.rotulo} (maxFs=${resolucao.maxFs}) " +
            "a ${fpsEscolhido} fps")

        // **Um segundo de vídeo, e não trinta quadros.** `TrackFrameSink` documenta o limiar
        // como "um segundo"; passá-lo como a constante 30 só era verdade a 30 fps. A 60 já vale
        // meio segundo, e a 120 valeria 250 ms — e a entrega em rajada (o `lote` de 2 a 8 da
        // sessão de alta velocidade) torna trinta falhas seguidas plausíveis dentro de um quarto
        // de segundo. A sessão morreria por uma constante e o relatório diria "o receptor caiu".
        val sink = TrackFrameSink(track, falhasParaDesistir = fpsEscolhido)
        // **O teto do controlador é o valor de produto**, e é isso que faz o braço de aferição
        // negativo passar por construção: o controlador nasce aqui e nunca passa daqui. Ver
        // `QuallNative.rateNew` e `quall_core::taxa`.
        //
        // `Bancada.bitrateKbps` é 0 em produto, e aí vale a constante. A varredura da curva de
        // resposta troca isto sem recompilar; ver `docs/taxa-que-escuta.md`.
        // O teto de taxa da geometria que de fato vai ser codificada. `0` é recusa da fronteira,
        // e aí vale o valor histórico — um alvo ausente é um encoder sem alvo.
        // **A geometria da tela passa pelo teto antes de virar encoder.** Até 07/09/2026 não
        // passava: `H264ScreenEncoder` recebia `fonte.width`/`fonte.height` crus, e no S24 isso é
        // 1440x3120 — 17.550 macroblocos por quadro contra os 8192 do `MaxFS` do nível 4.0 que o
        // nosso SDP anuncia. O receptor do OBS decodificou sem reclamar porque o VideoToolbox do
        // macOS é tolerante; um receptor que respeitasse o nível teria recusado, e a culpa teria
        // parecido dele.
        //
        // A incoerência tinha uma segunda metade, e ela é aritmética: `tetoDeTaxaBps(1440, 3120,
        // 30)` devolve 8.963.611 — a taxa calculada para a geometria **já ajustada** (976x2116).
        // Era esse o número que ia ao encoder, junto com 2,24 vezes os pixels que ele previa.
        //
        // `null` da fronteira não vira "use o que veio": vira erro. Codificar acima do nível que
        // anunciamos é o defeito que esta linha conserta, e cair nele em silêncio o repetiria.
        val geometriaDaTela = when (fonte) {
            is Fonte.Tela ->
                QuallNative.tetoDeResolucaoPar(fonte.width, fonte.height, fpsEscolhido, resolucao.maxFs)
                ?: run {
                    publicarErro(tx(R.string.esp_geometria_recusada, fonte.width, fonte.height))
                    QuallNative.trackFree(track)
                    return
                }
            is Fonte.Camera, is Fonte.CameraDoPrompter, is Fonte.Dvd -> null
        }
        if (geometriaDaTela != null && fonte is Fonte.Tela &&
            (geometriaDaTela.first != fonte.width || geometriaDaTela.second != fonte.height)) {
            Log.i(TAG, "teto de resolução da tela: ${fonte.width}x${fonte.height} -> " +
                "${geometriaDaTela.first}x${geometriaDaTela.second}")
        }
        val (larguraDaFonte, alturaDaFonte) = when (fonte) {
            is Fonte.Tela -> geometriaDaTela!!.first to geometriaDaTela.second
            // Este 1920x1080 era suposição até 03/09 — a câmera negociava sozinha e podia entregar
            // outra coisa. Deixou de ser: `CameraXSource.GEOMETRIA_PEDIDA` pede exatamente
            // 1920x1080 aos dois use cases, com fallback para o tamanho mais próximo. Continua
            // sendo um número escrito em dois lugares, e o log de `CameraXSource.ligarCodificador` é onde se
            // confere que os dois concordam.
            // **A geometria da câmera é a escolhida, e não mais um literal.** O 1920x1080 que
            // estava aqui casava com o `GEOMETRIA_PEDIDA` cravado do `CameraXSource`; agora os
            // dois vêm da mesma escolha, e o comentário antigo — "continua sendo um número
            // escrito em dois lugares" — deixa de valer. O log de `CameraXSource.ligarCodificador`
            // continua sendo onde se confere que os dois concordam.
            is Fonte.Camera -> geometriaDv ?: geometriaR5 ?: (resolucao.pedido.width to resolucao.pedido.height)
            is Fonte.CameraDoPrompter -> geometriaR5!!
            // O DVD: pixels quadrados pelo aspecto (640 ou 854 × 480; 768 ou 1024 × 576 no PAL).
            is Fonte.Dvd -> (dvd?.largura ?: 640) to (dvd?.altura ?: 480)
        }
        val doTeto = QuallNative.tetoDeTaxaBps(larguraDaFonte, alturaDaFonte, fpsEscolhido, resolucao.maxFs)
            .takeIf { it > 0 } ?: BITRATE_BPS_TELA_HISTORICO
        // **O desvio de bancada vale para as duas fontes desde 04/09.** Até aqui ele alcançava só
        // a tela, e a §8.28 mostrou por que isso doía: o caminho de câmera pede
        // `doTeto * FATOR_CAMERA_NUM / FATOR_CAMERA_DEN` — **3/4**, e não o `3/2` que este
        // comentário afirmou até 08/09/2026, defasado desde que 13b35d5 trocou o fator. A 1080p30
        // são 6,77 Mbps, e não 13,5: quem copiasse o comentário em vez da constante escreveria o
        // dobro do orçamento. O `MediaCodec` trata `KEY_BIT_RATE` como **alvo** e não como teto,
        // e numa cena simples o controlador derruba o QP até 6 para gastar o orçamento. Sem um
        // desvio na câmera, varrer a curva de resposta exigiria recompilar — e dois binários não
        // fazem comparação honesta. `0` continua sendo produto, nas duas fontes.
        val deBancadaBps = com.quall.android.core.Bancada.bitrateKbps(this)
            .takeIf { it > 0 }?.times(1000)
        val bitrateDaTela = deBancadaBps ?: doTeto
        val bitrateDaCamera = deBancadaBps ?: (doTeto * FATOR_CAMERA_NUM / FATOR_CAMERA_DEN)
        // **Var, e não val, porque a geometria negociada pode corrigi-lo.** Ver o ajuste logo
        // abaixo, onde a câmera sobe: o teto do controlador e o bitrate inicial do encoder são
        // **as duas metades do mesmo número**, e em 07/09/2026 eu consertei uma e deixei a outra
        // — o encoder nasceu em 13,5 Mbps e o controlador o empurrou de volta para 54, que é o
        // teto de uma geometria que a câmera não entregou.
        var tetoDoControleBps = when (fonte) {
            is Fonte.Tela -> bitrateDaTela
            is Fonte.Camera, is Fonte.CameraDoPrompter, is Fonte.Dvd -> bitrateDaCamera
        }
        // **Pedido × entregue** (`core/Entrega.kt`). A geometria negociada da câmera só existe
        // depois que ela sobe, logo abaixo; o que a câmera declara sobre o tamanho pedido pode ser
        // lido já — é característica do aparelho, não da sessão.
        var negociadaDaCamera: android.util.Size? = null
        val capacidadeDaCamera = (fonte as? Fonte.Camera)?.takeIf { !it.dv }?.let {
            com.quall.android.capture.CameraXSource.capacidadeNoTamanho(this, it.cameraId, resolucao.pedido)
        }
        if (fonte is Fonte.CameraDoPrompter) negociadaDaCamera = android.util.Size(larguraDaFonte, alturaDaFonte)
        // A câmera comum pelo dono: o que a câmera entrega (o tamanho do buffer), para a frase da entrega.
        if (comumPeloDono) negociadaDaCamera = donoR5?.resolucaoDaCamera
        val enc: H264SurfaceEncoder = if (donoR5 != null) {
            // A câmera não é tocada: a rede se pendura no divisor do dono, e se solta dele no fim.
            com.quall.android.capture.H264DivisorEncoder(
                dono = donoR5,
                sink = sink,
                width = larguraDaFonte,
                height = alturaDaFonte,
                targetFps = fpsEscolhido,
                bitrateBps = bitrateDaCamera,
                gopSeconds = GOP_SEGUNDOS_CAMERA,
                refreshIntraQuadros = com.quall.android.core.Bancada.refreshIntraQuadros(this),
                modoDeTaxa = com.quall.android.core.Bancada.modoDeTaxa(this),
                chavesDeFornecedor = com.quall.android.core.Bancada.chavesDeFornecedor(this),
                rotacaoFixa = rotacaoDaRede,
                tetoDaFila = com.quall.android.core.Bancada.filaDoCodificadorQuadros(this),
            )
        } else when (fonte) {
            // Sem dono aqui é impossível: a tela R5 saiu acima, pelo dono, ou retornou.
            is Fonte.CameraDoPrompter -> error("a tela R5 sem o dono da captura")
            is Fonte.Dvd -> {
                val t = dvd ?: run {
                    publicarErro("o DVD não está aberto") // i18n-fora: estado interno inconsistente, só de quem programa
                    QuallNative.trackFree(track)
                    return
                }
                negociadaDaCamera = android.util.Size(larguraDaFonte, alturaDaFonte)
                com.quall.android.capture.H264DvdEncoder(
                    fonte = t,
                    sink = sink,
                    width = larguraDaFonte,
                    height = alturaDaFonte,
                    bitrateBps = bitrateDaCamera,
                    gopSeconds = GOP_SEGUNDOS_CAMERA,
                    refreshIntraQuadros = com.quall.android.core.Bancada.refreshIntraQuadros(this),
                    modoDeTaxa = com.quall.android.core.Bancada.modoDeTaxa(this),
                    chavesDeFornecedor = com.quall.android.core.Bancada.chavesDeFornecedor(this),
                )
            }
            is Fonte.Tela -> H264ScreenEncoder(
                mediaProjection = proj ?: run {
                    publicarErro("origem tela sem MediaProjection — estado interno inconsistente")
                    QuallNative.trackFree(track)
                    return
                },
                sink = sink,
                // Ver `geometriaDaTela` acima: o que vai ao encoder é o que o teto permite, e a
                // `VirtualDisplay` é criada nessa mesma dimensão — o `MediaProjection` reduz o
                // display para dentro dela preservando a proporção, que é a reescala certa e a
                // única do caminho.
                width = larguraDaFonte,
                height = alturaDaFonte,
                densityDpi = fonte.dpi,
                giroResize = com.quall.android.core.Bancada.giroResize(this),
                contexto = this,
                targetFps = fpsEscolhido,
                bitrateBps = bitrateDaTela,
                gopSeconds = GOP_SEGUNDOS_TELA,
                colecionarQuadros = false,
                janelaDoFioMs = com.quall.android.core.Bancada.janelaDoFioMs(this),
                // Ver `Bancada.refreshIntraQuadros`: 0 em produto até a medida de
                // `docs/idr-pequeno.md` dizer outra coisa.
                refreshIntraQuadros = com.quall.android.core.Bancada.refreshIntraQuadros(this),
                modoDeTaxa = com.quall.android.core.Bancada.modoDeTaxa(this),
                chavesDeFornecedor = com.quall.android.core.Bancada.chavesDeFornecedor(this),
            )
            is Fonte.Camera -> if (fonte.dv) {
                val fdv = fonteDv ?: run {
                    publicarErro("o vídeo USB não está aberto") // i18n-fora: estado interno inconsistente, só de quem programa
                    QuallNative.trackFree(track)
                    return
                }
                negociadaDaCamera = android.util.Size(larguraDaFonte, alturaDaFonte)
                com.quall.android.capture.H264DvEncoder(
                    fonte = fdv,
                    sink = sink,
                    width = larguraDaFonte,
                    height = alturaDaFonte,
                    bitrateBps = bitrateDaCamera,
                    gopSeconds = GOP_SEGUNDOS_CAMERA,
                    refreshIntraQuadros = com.quall.android.core.Bancada.refreshIntraQuadros(this),
                    modoDeTaxa = com.quall.android.core.Bancada.modoDeTaxa(this),
                    chavesDeFornecedor = com.quall.android.core.Bancada.chavesDeFornecedor(this),
                )
            } else {
                // A câmera **já está aberta** desde a fase de espera, com o use case da tela. Aqui
                // só entra o use case do codificador — ver `CameraXSource.ligarCodificador` para o
                // porquê de a ordem ser essa (o `MediaCodec` ainda não existe neste ponto, então a
                // reconfiguração da `CaptureSession` acontece fora da janela que a régua do
                // §8.18 mede). O instrumento de bancada (`CameraCaptureService`) continua no
                // caminho de uma fase e sem prévia, porque um segundo fluxo saindo da mesma câmera
                // mudaria o que ele mede.
                val src = subirFonteDaCamera(fonte.cameraId)
                if (!src.timestampSourceRealtime) {
                    // Achado em bancada (A07): sem REALTIME, `encode_latency_us` desta câmera não
                    // é comparável a relógio de sistema nenhum — ver H264CameraEncoder. Fica só no
                    // logcat, não na tela ao vivo: repetir isso a cada segundo na UI de
                    // espelhamento seria ruído; o instrumento de bancada (CameraCaptureService) já
                    // é onde essa ressalva precisa aparecer com destaque.
                    Log.w(TAG, "câmera ${fonte.cameraId}: timestamp_source=UNKNOWN — encode_latency_us não é confiável")
                }
                // **O orçamento é da geometria NEGOCIADA, e não da pedida.**
                //
                // `bitrateDaCamera` foi calculado antes de a câmera existir, a partir do que o
                // usuário escolheu. O CameraX pode entregar outra coisa — e entrega: em
                // 07/09/2026, com 4K a 60 pedidos, o S24 negociou **1920x1080** a 60, porque 4K
                // no aparelho vai só a 30 e o `setTargetFrameRate` escolhe o maior tamanho que
                // atende a taxa. O encoder recebeu **54 Mbps** (o teto de 4K60) para um quadro de
                // 1080p, que precisa de 13,5: **quatro vezes** os bits que a regra do produto
                // reserva para aquela geometria.
                //
                // É o espelho exato do defeito da manhã, quando a geometria subiu e o orçamento
                // ficou. As duas metades do teto andam juntas, e a única forma de garantir isso é
                // as duas saírem do **mesmo** número — o que a câmera de fato entregou.
                val negociada = runCatching { src.resolution }.getOrNull()
                negociadaDaCamera = negociada
                val bitrateReal = if (negociada != null) {
                    val t = QuallNative.tetoDeTaxaBps(negociada.width, negociada.height,
                                                      fpsEscolhido, resolucao.maxFs)
                        .takeIf { it > 0 } ?: doTeto
                    val b = deBancadaBps ?: (t * FATOR_CAMERA_NUM / FATOR_CAMERA_DEN)
                    if (b != bitrateDaCamera) {
                        Log.i(TAG, "orçamento ajustado à geometria negociada " +
                            "${negociada.width}x${negociada.height}@$fpsEscolhido: " +
                            "$bitrateDaCamera -> $b bps (teto do controlador junto)")
                        // **O teto do controlador vai junto, e é isto que faltava.** Sem esta
                        // linha o controlador nasce com o teto da geometria PEDIDA e empurra o
                        // encoder de volta para ela: medido em 07/09, encoder em 13,5 Mbps subindo
                        // para 54 em onze segundos, e o rádio desabando de 0,00 % para 16 % de
                        // perda em quatro. O controlador só sabe tirar e devolver o que tirou —
                        // se o teto está errado, ele devolve até o erro.
                        tetoDoControleBps = b
                    }
                    b
                } else {
                    bitrateDaCamera
                }
                H264CameraEncoder(
                    cameraSource = src,
                    sink = sink,
                    targetFps = fpsEscolhido,
                    bitrateBps = bitrateReal,
                    gopSeconds = GOP_SEGUNDOS_CAMERA,
                    colecionarQuadros = false,
                    refreshIntraQuadros = com.quall.android.core.Bancada.refreshIntraQuadros(this),
                    modoDeTaxa = com.quall.android.core.Bancada.modoDeTaxa(this),
                    chavesDeFornecedor = com.quall.android.core.Bancada.chavesDeFornecedor(this),
                )
            }
        }
        // Produto: o carimbo do vídeo vai para o relógio do som (`RelogioDoPts`). A bancada desliga
        // para o controle do §19.4 do `som-no-receptor.md`.
        enc.corrigirRelogioDoPts = !com.quall.android.core.Bancada.provaPtsCru(this)
        encoder = enc
        // A DV que caiu antes desta linha chamou `encoder?.stop()` sobre `null`: sem isto o
        // encoder subiria sem quadro nenhum até o receptor desistir (a revisão do código, A2).
        if (cameraDvCaiu || fonteDv?.desconectada == true) enc.stop()
        atualizarNotificacao(tx(R.string.esp_notif_espelhando_para, parNome), fonteRotulo)

        // Publica taxa **e** latência juntas, uma vez por segundo. É o par que denuncia fila; sem
        // ele, o defeito do A07 (30 pedidos, 67 obtidos, 251 ms) ficou escondido uma rodada
        // inteira.
        val relator = thread(name = "quall-mirror-stats", isDaemon = true) {
            var primeiraVolta = true
            var entregaDita: com.quall.android.core.Entrega? = null
            while (encoder === enc && !cancelado) {
                val i = enc.instantaneo()
                // As frases da entrega no idioma de agora (`docs/traducao.md`).
                val textos = com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this@MirrorService))
                var entrega = when (fonte) {
                    is Fonte.Camera -> if (fonte.dv) com.quall.android.core.Entrega.fixa(
                        textos,
                        pedido = tx(if (placaDeCaptura) R.string.esp_pedido_placa else R.string.esp_pedido_filmadora),
                        largura = larguraDaFonte, altura = alturaDaFonte, quadros = if (placaDeCaptura) 30.0 else 29.97,
                    ) else com.quall.android.core.Entrega.daCamera(
                        textos, escolhida, fpsEscolhido,
                        negociadaDaCamera?.let { it.width to it.height },
                        if (fonte.peloDono) donoR5?.quadrosNegociados else cameraSource?.quadrosNegociados,
                        capacidadeDaCamera ?: com.quall.android.core.Entrega.Camera(true, null),
                    )
                    is Fonte.CameraDoPrompter -> com.quall.android.core.Entrega.fixa(
                        textos,
                        pedido = tx(R.string.esp_pedido_r5),
                        largura = larguraDaFonte, altura = alturaDaFonte, quadros = fpsEscolhido.toDouble(),
                        motivo = motivoLeve,
                    ).let { e ->
                        donoR5?.resolucaoDaCamera?.let { e.copy(entregue = tx(R.string.esp_entregue_com_camera, e.entregue, it.width, it.height)) } ?: e
                    }
                    is Fonte.Dvd -> com.quall.android.core.Entrega.fixa(
                        textos,
                        pedido = tx(R.string.esp_fonte_dvd),
                        largura = larguraDaFonte, altura = alturaDaFonte, quadros = if (dvd?.pal == true) 25.0 else 29.97,
                    )
                    is Fonte.Tela -> com.quall.android.core.Entrega.daTela(
                        textos, escolhida, fpsEscolhido,
                        painel = fonte.width to fonte.height,
                        entregue = larguraDaFonte to alturaDaFonte,
                    )
                }
                // A câmera comum pelo dono: o "entregue" é o buffer da câmera, e a rede leve precisa
                // ser dita à parte (o tamanho dela e o porquê).
                if (comumPeloDono && motivoLeve != null && entrega.entregue.isNotEmpty()) {
                    entrega = entrega.copy(
                        entregue = tx(R.string.esp_entregue_com_rede, entrega.entregue, larguraDaFonte, alturaDaFonte),
                        curto = tx(R.string.esp_entregue_com_rede, entrega.curto, larguraDaFonte, alturaDaFonte),
                        motivo = listOfNotNull(entrega.motivo, motivoLeve).joinToString("; "),
                    )
                }
                if (entrega != entregaDita && entrega.entregue.isNotEmpty()) {
                    entregaDita = entrega
                    Log.i(TAG, "entrega: pedido=${entrega.pedido} entregue=${entrega.entregue} " +
                        "motivo=${entrega.motivo ?: "(como pedido)"}")
                }
                val limparMensagem = primeiraVolta
                primeiraVolta = false
                MirrorBus.atualizar {
                    it.copy(
                        fase = MirrorBus.Fase.ESPELHANDO,
                        fonteRotulo = fonteRotulo,
                        daTela = fonte is Fonte.Tela,
                        nomeDaCamera = nomeDaCamera,
                        par = parNome,
                        pareamentoNovo = novo,
                        quadrosEnviados = sink.enviados,
                        falhasDeEnvio = sink.falhas,
                        pedidosDeIdr = sink.pedidosDeIdr,
                        idrsEnviados = i.idrs,
                        fpsPedido = fpsEscolhido,
                        fpsObtido = i.fpsObtido,
                        latenciaP50Ms = i.p50Us / 1000.0,
                        latenciaP95Ms = i.p95Us / 1000.0,
                        latenciaConfiavel = i.latenciaConfiavel,
                        estatisticasDoNucleo = sink.estatisticasDoNucleo(),
                        pedido = entrega.pedido,
                        entregue = entrega.entregue,
                        entregueCurto = entrega.curto,
                        transmissaoLeve = motivoLeve != null,
                        motivoDaEntrega = entrega.motivo.orEmpty(),
                        // **Uma vez, na entrada no ar — e não a cada segundo.** Esta linha apagava a
                        // `mensagem` a cada volta, e com isso as frases do controlador de taxa (a do
                        // piso da rede, desde 31/08, e a do receptor afogado, de 10/09) duravam
                        // menos de um segundo. O que ela precisa limpar é o recado da espera
                        // ("errou o PIN", "sem anúncio mDNS"), e isso é na primeira volta.
                        mensagem = if (limparMensagem) "" else it.mensagem,
                        mensagemEhAnuncio = if (limparMensagem) false else it.mensagemEhAnuncio,
                    )
                }
                runCatching { Thread.sleep(1000) }
            }
        }

        // **A taxa que escuta.** Nasce LIGADA desde 31/08/2026; `taxa_que_escuta=false` desliga,
        // e o A/B continua possível no mesmo APK com os papéis trocados. A política não está aqui
        // — é `quall_core::taxa`, no núcleo, onde `cargo test` a exercita contra a curva que esta
        // bancada mediu. O que sustenta o padrão, e o que ainda falta nele (a subida, nunca
        // exercitada em aparelho), está em `Bancada.taxaQueEscuta`.
        val controle = if (com.quall.android.core.Bancada.taxaQueEscuta(this)) {
            QuallNative.rateNew(tetoDoControleBps)
        } else {
            0L
        }
        val ouvinte = if (controle == 0L) null else thread(
            name = "quall-mirror-taxa", isDaemon = true,
        ) {
            // Arrays reaproveitados: uma janela por 200 ms durante meia hora seriam nove mil
            // alocações num aparelho de 1,79 GB, no caminho quente do emissor.
            // Seis: o sexto é `nao_decodificados`, o que o receptor não conseguiu entregar.
            val relato = LongArray(6)
            val novoBps = IntArray(1)
            var noPisoDito = false
            // **Quem não está dando conta**, para a frase ao usuário não mentir a causa. Até
            // 10/09/2026 todo piso dizia "a rede", e um receptor afogado em quadros por segundo
            // levava o emissor ao piso em 12 s — com a rede perfeita.
            var ultimaDescidaFoiDoReceptor = false
            var afogamentoDito = false
            // **A medida do que sai.** O controlador decide sobre o alvo que ele pede; o fio
            // carrega outro número. Medido no S24 em 09/09/2026, na linha de encerramento:
            // `bitrate_pedido=8343750 bitrate_obtido=14893648` — 78% a mais. Enquanto o emissor
            // não olhar para o que sai, toda decisão dele é tomada sobre um valor que não existe.
            var bytesAntes = sink.bytesEnviados
            var relogioDaMedida = System.nanoTime()
            // Fator de aferição: quanto o codificador entrega a mais do que se pede. Começa em 1
            // (nada aferido) e é corrigido devagar, porque medir uma janela de 200 ms de vídeo
            // real é medir também a cena — um movimento brusco não é um encoder mentindo.
            var fatorDoEncoder = 1.0
            // Lida uma vez por sessão, como as outras chaves de bancada: trocar de braço é
            // reiniciar a transmissão, não mexer no meio dela.
            val comTeto = com.quall.android.core.Bancada.tetoInstantaneo(this)
            // **O que está saindo, em média lenta** — a base do teto. Ver o uso, logo abaixo.
            var medidoLento = 0.0
            try {
                while (encoder === enc && !cancelado) {
                    // O prazo do `take` **é** a espera deste laço: ele bloqueia na sinalização
                    // até 200 ms e volta. Um `sleep` separado somaria duas esperas — o erro que
                    // fez o laço do receptor iOS ser de 100 ms quando o comentário dizia 50.
                    //
                    // E isto aqui foi esse mesmo erro por um dia: o núcleo cortava o prazo a
                    // 10 ms (`FATIA_DE_ESCUTA`) e este laço girava a 100 Hz enquanto a linha
                    // acima dizia 200 ms. As corridas de A/B de 31/08 rodaram assim; o corte saiu
                    // depois. Ver `Ready::relato_do_enlace`.
                    if (!QuallNative.sessionTakeLinkReport(sessao, 200, relato)) continue
                    val motivo = QuallNative.rateSample(
                        controle, relato[0], relato[1], relato[2], relato[3], relato[4], relato[5],
                        novoBps,
                    )
                    // --- o que de fato saiu nesta janela --------------------------------------
                    val agoraNs = System.nanoTime()
                    val bytesAgora = sink.bytesEnviados
                    val dtS = (agoraNs - relogioDaMedida).coerceAtLeast(1) / 1_000_000_000.0
                    val medidoBps = ((bytesAgora - bytesAntes) * 8 / dtS).toLong()
                    bytesAntes = bytesAgora
                    relogioDaMedida = agoraNs
                    val alvo = QuallNative.rateCurrentBps(controle)
                    if (alvo > 0 && medidoBps > 0 && dtS > 0.1) {
                        // Média móvel lenta (1/8 por janela): a aferição persegue o viés do
                        // codificador, não o conteúdo da cena.
                        val desteQuadro = medidoBps.toDouble() / alvo.toDouble()
                        fatorDoEncoder += (desteQuadro - fatorDoEncoder) / 8.0
                        // **Só corrige para baixo, nunca para cima.** O alvo é um **teto**, não
                        // uma meta: se o codificador entrega menos que o pedido — cena parada, um
                        // rosto imóvel — não há nada a consertar. Corrigir para cima faria o
                        // emissor pedir mais e mais numa cena estática, e o pedido inflado viraria
                        // rajada no instante em que a cena se mexesse. Medido em campo minutos
                        // depois de escrever isto: com o S24 na frontal e cena parada, a aferição
                        // caiu para 0,88 e o pedido teria subido 14% sem motivo.
                        fatorDoEncoder = fatorDoEncoder.coerceIn(1.0, 4.0)
                    }
                    // **O teto instantâneo corta enxurrada, não a média.** Ele existe para o atraso
                    // de uma pausa não sair de uma vez (`docs/bancada.md` §8.65: 12× o alvo em meio
                    // segundo). A primeira versão seguia o **alvo** do controlador, e em 10/09/2026
                    // o campo mostrou o preço: com o alvo em 1,8 Mbps e o codificador incapaz de
                    // entregar menos de ~3,5 a 1080p60 (aferição em 1,9–2,1x), o balde passou a
                    // barrar tráfego **normal** — e cada barrado pedia IDR: 815 pedidos, 683 IDRs
                    // em 1667 quadros do lado de quem recebia.
                    //
                    // A base agora é o maior entre o alvo e o que está saindo em média lenta (1/8
                    // por janela, uns 4 s). Uma enxurrada de meio segundo quase não mexe na média,
                    // e é barrada; um codificador que não desce até o alvo não é enxurrada, e passa.
                    // Zero é "sem teto" — o braço de controle.
                    if (medidoBps > 0 && dtS > 0.1) {
                        medidoLento = if (medidoLento == 0.0) {
                            medidoBps.toDouble()
                        } else {
                            medidoLento + (medidoBps - medidoLento) / 8.0
                        }
                    }
                    val baseDoTeto = maxOf(alvo.toLong(), medidoLento.toLong())
                        .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                    sink.tetoInstantaneoBps = if (comTeto) baseDoTeto else 0

                    val receptorAfogado = relato[5] >= 3
                    if (motivo == QuallNative.RateReason.DOWN) {
                        ultimaDescidaFoiDoReceptor = receptorAfogado
                    }
                    // O controlador **segura** quando o receptor continua afogado e descer não
                    // aliviou (`Motivo::AfogadoSemAlivio`): ele está preso em quadros por segundo,
                    // e isso é do outro aparelho — dito uma vez.
                    if (receptorAfogado && motivo == QuallNative.RateReason.HOLD && !afogamentoDito) {
                        afogamentoDito = true
                        Log.w(TAG, "taxa: o receptor não está dando conta, e descer não aliviou — segurando")
                        MirrorBus.atualizar {
                            it.copy(mensagem = tx(R.string.esp_receptor_afogado), mensagemEhAnuncio = false)
                        }
                    }
                    if (motivo == QuallNative.RateReason.DOWN ||
                        motivo == QuallNative.RateReason.UP
                    ) {
                        // **Pede-se o alvo dividido pelo viés medido**, e não o alvo cru: se este
                        // codificador entrega 1,8x o que se pede, pedir 8 Mbps põe 14,4 no ar e a
                        // autoridade do controlador vira ficção na mesma proporção.
                        val pedido = (novoBps[0] / fatorDoEncoder).toInt().coerceAtLeast(1)
                        enc.definirBitrate(pedido)
                    }
                    val perda = if (relato[1] > 0) relato[2] * 100.0 / relato[1] else 0.0
                    Log.i(
                        TAG,
                        "taxa: janela ms=${relato[0]} pacotes=${relato[1]} " +
                            "perdidos=${relato[2]} perda=${"%.2f".format(perda)}% " +
                            "suspeitos=${relato[3]} idrs_quebrados=${relato[4]} " +
                            "nao_entregues=${relato[5]} -> " +
                            "${QuallNative.RateReason.nome(motivo)} " +
                            "alvo=$alvo medido=$medidoBps " +
                            "afericao=${"%.2f".format(fatorDoEncoder)}x " +
                            "barrados=${sink.descartadosPeloTeto} " +
                            "condenados=${sink.condenadosAteIdr} " +
                            "teto=${sink.tetoInstantaneoBps}",
                    )
                    // O piso é a única condição em que a resposta é para o usuário e não para o
                    // encoder. Dito uma vez, e no lugar em que a casca mostra estado.
                    if (!noPisoDito && QuallNative.rateAtFloor(controle)) {
                        noPisoDito = true
                        val frase = tx(if (ultimaDescidaFoiDoReceptor) R.string.esp_receptor_no_piso else R.string.esp_rede_no_piso)
                        Log.w(TAG, "taxa: no piso — ${Log.erroExterno(frase)}")
                        MirrorBus.atualizar { it.copy(mensagem = frase, mensagemEhAnuncio = false) }
                    }
                }
            } finally {
                // Liberado **aqui**, e não no `finally` externo: quem criou o handle é esta
                // thread e é ela que para de usá-lo. Liberar de fora enquanto o laço ainda roda
                // seria uso depois da liberação no caminho quente.
                QuallNative.rateFree(controle)
            }
        }

        // **O controle remoto da câmera** (R9b, `docs/controle-remoto-da-camera.md`): o filmador bombeia o
        // canal de dados de **toda** sessão de vídeo — é o leitor único dele (§2). Na câmera pelo dono (a
        // comum e a R5) com a câmera; o toque do receptor é um ponto do quadro que esta rede leva. Na tela,
        // no DVD, na placa e no braço CameraX, sem câmera: o receptor fica em `sem_camera` (§9).
        val comCameraRemota = donoR5 != null
        val mensagensDaCamera = QuallNative.sessionMessages(sessao)
        if (comCameraRemota) {
            com.quall.android.capture.FilmadorDaCamera.saidaDaRede =
                com.quall.android.capture.FilmadorDaCamera.SaidaDaRede(larguraDaFonte, alturaDaFonte, rotacaoDaRede)
        }
        val bombaDaCamera = if (mensagensDaCamera == 0L) null else thread(name = "quall-mirror-camera-remota", isDaemon = true) {
            com.quall.android.capture.FilmadorDaCamera.bombear(this, mensagensDaCamera, comCameraRemota) { encoder === enc && !cancelado }
        }

        // A escada de bitrate: um degrau a cada `escadaPassoMs`, dentro da mesma sessão. Vazia em
        // produto, e então esta thread nem nasce. Ver `Bancada.escadaKbps` para o motivo de a
        // curva ser medida assim e não em N corridas.
        val escada = com.quall.android.core.Bancada.escadaKbps(this)
        val passoMs = com.quall.android.core.Bancada.escadaPassoMs(this)
        if (escada.isNotEmpty() && controle != 0L) {
            // Os dois mexem no mesmo botão e a corrida não mediria nem um nem outro. Avisar é o
            // que resta: recusar a sessão por causa de uma preferência de bancada seria pior.
            Log.e(
                TAG,
                "escada E taxa_que_escuta ligadas ao mesmo tempo: as duas escrevem o bitrate, " +
                    "e esta corrida não mede nenhuma das duas",
            )
        }
        val escadeiro = if (escada.isEmpty()) null else thread(
            name = "quall-mirror-escada", isDaemon = true,
        ) {
            for ((i, kbps) in escada.withIndex()) {
                if (encoder !== enc || cancelado) return@thread
                enc.definirBitrate(kbps * 1000)
                Log.i(TAG, "escada: degrau ${i + 1}/${escada.size} = $kbps kbps por $passoMs ms")
                // Dormir em fatias para o degrau final não segurar a sessão depois de `parar()`.
                var resta = passoMs
                while (resta > 0 && encoder === enc && !cancelado) {
                    val fatia = minOf(resta, 250L)
                    runCatching { Thread.sleep(fatia) }
                    resta -= fatia
                }
            }
            Log.i(TAG, "escada: fim dos ${escada.size} degraus")
        }

        // --- a track de áudio, que é a de índice 1 da mesma oferta ---------------------------
        //
        // Ela **não** é fatal: uma sessão com imagem e sem som é meio produto, mas uma sessão que
        // não sobe porque o `AudioRecord` não abriu é produto nenhum. Todo caminho de falha aqui
        // registra e segue.
        //
        // **Aqui, logo antes do `try`, e não no começo da sessão** (a fase 2 do R5): os retornos
        // antecipados de cima (a câmera que não abriu, a geometria recusada) liberam só a track de
        // vídeo, e um som já subido ali ficava mandando — o microfone aberto — sem ninguém para
        // fechá-lo. Daqui para baixo, o `finally` fecha sempre.
        var trackDeAudio = 0L
        if (comAudio && QuallNative.sessionTrackCount(sessao) >= 2) {
            trackDeAudio = QuallNative.sessionTrack(sessao, 1)
            if (trackDeAudio == 0L) {
                Log.w(TAG, "a track de áudio não veio: ${Log.erroExterno(QuallNative.lastError())}")
            } else {
                subirAudio(trackDeAudio, proj, tomDeProva)
            }
        } else if (comMicrofone && QuallNative.sessionTrackCount(sessao) >= 2) {
            // O microfone da câmera: a track fica registrada, e o botão decide se o som sai.
            trackDeAudio = QuallNative.sessionTrack(sessao, 1)
            if (trackDeAudio == 0L) {
                Log.w(TAG, "a track do microfone não veio: ${Log.erroExterno(QuallNative.lastError())}")
            } else {
                synchronized(travaDoMicrofone) { trackDoMicrofone = trackDeAudio }
                Log.i(TAG, "microfone: a track está na sessão; o botão está ${if (microfonePedido) "ligado" else "desligado"}")
                runCatching { obrasDoMicrofone.execute { aplicarMicrofone() } }
            }
        } else if (comAudio || comMicrofone) {
            Log.w(TAG, "a oferta pedia áudio e a sessão subiu com ${QuallNative.sessionTrackCount(sessao)} track(s)")
        }

        try {
            // Sem prazo: espelha até o receptor sair (`sink.desistiu()`), até `parar()`, ou até o
            // usuário revogar o consentimento na notificação do sistema (só para a tela).
            val r = enc.run(0)
            val estat = sink.estatisticasDoNucleo()
            Log.i(
                TAG,
                "sessão encerrada ($fonteRotulo): enviados=${sink.enviados} falhas=${sink.falhas} " +
                    "pedidos_de_idr=${sink.pedidosDeIdr} fps_pedido=$fpsEscolhido " +
                    "fps_obtido=${"%.1f".format(r.achievedFps)} " +
                    "p50=${r.encodeLatencyP50Us / 1000.0}ms p95=${r.encodeLatencyP95Us / 1000.0}ms " +
                    "idr_com_csd_colado=${r.idrsComParametrosColados} " +
                    "sem_start_code=${r.quadrosSemStartCode} " +
                    // O bitrate **obtido** ao lado do pedido, pela mesma razão que `fps_obtido`
                    // sai ao lado de `fps_pedido`: o par é que denuncia a API que aceita e não faz.
                    "bitrate_pedido=${r.bitrateFinalBps} " +
                    "bitrate_obtido=${bitrateObtidoBps(r)} " +
                    "trocas_de_bitrate=${r.trocasDeBitrate} " +
                    "bytes_de_saida=${r.bytesDeSaida} nucleo=$estat",
            )
            MirrorBus.atualizar {
                it.copy(
                    fase = if (cancelado) MirrorBus.Fase.PARADO else MirrorBus.Fase.ESPERANDO,
                    quadrosEnviados = sink.enviados,
                    falhasDeEnvio = sink.falhas,
                    pedidosDeIdr = sink.pedidosDeIdr,
                    idrsEnviados = r.idrFrameNumbers.size,
                    fpsObtido = r.achievedFps,
                    latenciaP50Ms = r.encodeLatencyP50Us / 1000.0,
                    latenciaP95Ms = r.encodeLatencyP95Us / 1000.0,
                    latenciaConfiavel = r.latenciaConfiavel,
                    encoder = "${r.encoderName} (hw=${r.encoderIsHardware})",
                    estatisticasDoNucleo = estat,
                    mensagem = tx(R.string.esp_receptor_saiu, sink.enviados),
                )
            }
        } finally {
            encoder = null
            if (comumPeloDono) {
                // A rede já se soltou do divisor (`pararFonte`); a câmera fica se há tela ou gravação.
                synchronized(travaDaCamera) { codificandoCamera = false }
                reavaliarCameraComum()
            } else if (fonte is Fonte.Camera && !fonte.dv) {
                devolverFonteDaCameraAEspera()
            }
            runCatching { relator.join(1500) }
            runCatching { escadeiro?.join(1500) }
            // Junta **antes** de `trackFree`/`sessionClose`: a thread da taxa toca a **sessão**,
            // e não só a track. A diferença importa: `quall_session_close` promete que um handle
            // de track continua válido depois dela, e não promete nada parecido sobre a sessão —
            // ali o ponteiro é liberado.
            //
            // O argumento de que 1500 ms bastam: `encoder = null` acima faz a condição do laço
            // ser falsa, e a única chamada bloqueante dele espera no máximo 200 ms. A thread sai
            // em ≤200 ms; a espera é sete vezes isso. Se mesmo assim ela não sair, o aviso
            // aparece — um `use after free` silencioso no caminho de mídia é pior que uma linha
            // feia no log.
            runCatching { ouvinte?.join(1500) }
            if (ouvinte?.isAlive == true) {
                Log.e(TAG, "a thread da taxa não saiu em 1,5 s — a sessão vai fechar embaixo dela")
            }
            // A bombeada da câmera espera no máximo 100 ms por volta: sai logo depois de `encoder = null`.
            // O handle das mensagens sobrevive ao `sessionClose`; só é liberado com a thread fora dele.
            runCatching { bombaDaCamera?.join(1500) }
            if (bombaDaCamera?.isAlive == true) {
                Log.e(TAG, "r9b: a bombeada da câmera não saiu em 1,5 s — as mensagens dela ficam vazadas")
            } else if (mensagensDaCamera != 0L) {
                QuallNative.messagesFree(mensagensDaCamera)
            }
            if (comCameraRemota) com.quall.android.capture.FilmadorDaCamera.saidaDaRede = null
            // O áudio para **antes** de a track dele ser liberada, e antes da de vídeo: o laço
            // dele chama `quall_track_send_audio` com este handle.
            var liberarAudio = trackDeAudio != 0L
            emissorDeAudio?.let {
                if (!it.parar()) {
                    Log.e(TAG, "o emissor de áudio não saiu em 2 s — a track dele fica vazada, e não liberada embaixo dele")
                    liberarAudio = false
                }
                Log.i(TAG, "áudio da sessão: ${it.resumo()}")
                MirrorBus.atualizar { e -> e.copy(resumoDeAudio = it.resumo()) }
            }
            emissorDeAudio = null
            if (comMicrofone && trackDeAudio != 0L) {
                // O som da rede fecha com a sessão (o botão fica como está, para a próxima); o
                // microfone continua aberto se a gravação o usa, e fecha se não ([aplicarMicrofone]).
                val preso = synchronized(travaDoMicrofone) {
                    trackDoMicrofone = 0L
                    val e = emissorDoMicrofone
                    emissorDoMicrofone = null
                    val saiu = e?.parar() ?: true
                    if (e != null) {
                        Log.i(TAG, "microfone da sessão: ${e.resumo()}")
                        MirrorBus.atualizar { x -> x.copy(resumoDeAudio = e.resumo()) }
                    }
                    val p = !saiu || trackComEmissorPreso == trackDeAudio
                    if (trackComEmissorPreso == trackDeAudio) trackComEmissorPreso = 0L
                    p
                }
                if (preso) {
                    Log.e(TAG, "o emissor do microfone não saiu em 2 s — a track dele fica vazada, e não liberada embaixo dele")
                    liberarAudio = false
                }
                runCatching { obrasDoMicrofone.execute { aplicarMicrofone() } }
            }
            if (liberarAudio) QuallNative.trackFree(trackDeAudio)
            QuallNative.trackFree(track)
        }
    }

    // --- a câmera da tela R5 -----------------------------------------------------------------

    /**
     * Abre o [donoDaCaptura] em [obrasDaCamera] — abrir leva centenas de milissegundos e o PIN não
     * espera por isso. A sessão que parear antes de a câmera terminar de abrir espera por
     * [esperarDonoDaCaptura].
     */
    private fun abrirDonoDaCaptura(cameraId: String, minhaGeracao: Int) {
        val pronto = java.util.concurrent.CountDownLatch(1)
        donoAberto = pronto
        falhaDoDono = null
        obrasDaCamera.execute {
            try {
                abrirDonoAgora(cameraId, minhaGeracao)
            } finally {
                pronto.countDown()
            }
        }
    }

    /**
     * A abertura em si, em [obrasDaCamera] (a única thread que abre e fecha o dono). Um dono já
     * aberto não abre outro: a câmera comum pede a abertura a cada volta da tela, e a sessão pode
     * pedir de novo ao mesmo tempo.
     */
    private fun abrirDonoAgora(cameraId: String, minhaGeracao: Int) {
        val fonte = fonteEmCurso
        val daTelaR5 = fonte is Fonte.CameraDoPrompter
        val deQuem = if (daTelaR5) "da tela R5" else "do espelhamento de câmera" // i18n-fora: só no diário
        try {
            if (minhaGeracao != geracao.get() || cancelado) return
            if (donoDaCaptura != null) return
            // O motivo de processo é de quem falhou antes: só vale o que esta abertura escrever.
            com.quall.android.capture.CameraXSource.ultimoMotivoDaCamera = null
            val d = com.quall.android.capture.DonoDaCaptura.abrir(
                this, this, cameraId,
                // O desempate da zona ambígua do relógio só na tela R5 (a revisão da fase 2, M5).
                desempatePelaDeclaracao = daTelaR5,
                deQuem = deQuem,
            )
            synchronized(travaDaCamera) {
                // **A geração, e não o `cancelado` global** (a revisão, M1): a sessão que pediu
                // esta abertura pode ter acabado e outra começado (o `cancelado` volta a
                // falso); publicar aqui deixaria dois donos, e o primeiro vazado.
                if (minhaGeracao != geracao.get() || cancelado || donoDaCaptura != null) {
                    Log.i(TAG, "a câmera $deQuem abriu para uma sessão que já acabou — fechando")
                    d.fechar()
                } else {
                    donoDaCaptura = d
                    // A câmera comum espelha a prévia só na frontal (como a `PreviewView` fazia); a
                    // tela R5 segue o ajuste "Prévia espelhada".
                    com.quall.android.capture.PreviaDoDono.registrar(d, espelhoFixo = if (daTelaR5) null else d.frontal, daTelaR5 = daTelaR5)
                }
            }
            // Um "abrir" e um "fechar" da espera na fila, nessa ordem, deixavam a câmera comum aberta
            // sem tela, sessão nem gravação (a revisão, M2): aberta, ela confere de novo.
            if (!daTelaR5) fecharDonoSeOcioso("a câmera abriu e já não há quem a use") // i18n-fora: só no diário
        } catch (e: Throwable) {
            Log.e(TAG, "a câmera $deQuem não abriu", e)
            falhaDoDono = com.quall.android.capture.CameraXSource.ultimoMotivoDaCamera
                ?: "${e.javaClass.simpleName}: ${e.message}"
            MirrorBus.atualizar {
                it.copy(mensagem = tx(if (daTelaR5) R.string.esp_camera_frontal_nao_abriu_maiuscula else R.string.esp_camera_nao_abriu_maiuscula, falhaDoDono.toString()),
                    mensagemEhAnuncio = false)
            }
        }
    }

    /**
     * **A câmera comum pelo dono, na espera** (§8.6): abre quando há tela olhando (a prévia), e fecha
     * quando não há tela, sessão nem gravação — a mesma regra de [ajustarPreviaDeEspera] de antes
     * (a câmera de quem desistiu e guardou o telefone não fica aberta), com a gravação somada: quem
     * grava e sai do app continua gravando. Em [obrasDaCamera].
     */
    private fun ajustarDonoDaEspera(cameraId: String, olhando: Boolean) {
        synchronized(travaDaCamera) {
            if (cancelado || cameraDaEspera != cameraId) return
            if (olhando) {
                if (donoDaCaptura == null) abrirDonoDaCaptura(cameraId, geracao.get())
            } else {
                fecharDonoSeOcioso("nenhuma tela olhando") // i18n-fora: só no diário
            }
        }
    }

    /**
     * Fecha a câmera comum pelo dono se ninguém a usa: nem tela olhando, nem sessão
     * ([codificandoCamera]), nem gravação ([gravacaoUsaCamera]). A tela R5 não passa por aqui: a
     * câmera dela é da tela. Em [obrasDaCamera], ou sob [travaDaCamera] vindo dela.
     */
    private fun fecharDonoSeOcioso(motivo: String) {
        synchronized(travaDaCamera) {
            val f = fonteEmCurso
            if (f !is Fonte.Camera || !f.peloDono) return
            if (codificandoCamera || gravacaoUsaCamera || PreviaDaCamera.telaOlhando) return
            if (donoDaCaptura == null) return
            Log.i(TAG, "${Log.erroExterno(motivo)}, sem sessão e sem gravação — fechando a câmera do espelhamento")
            fecharDonoDaCaptura()
        }
    }

    /** A sessão ou a gravação largou a câmera comum: ela fecha se mais ninguém a usa (em [obrasDaCamera]). */
    private fun reavaliarCameraComum() {
        val f = fonteEmCurso
        if (f !is Fonte.Camera || !f.peloDono) return
        runCatching { obrasDaCamera.execute { fecharDonoSeOcioso("a câmera ficou sem uso") } } // i18n-fora: só no diário
    }

    /** A gravação da câmera comum parou (ou não começou): a câmera pode fechar. */
    private fun cameraSoltaPelaGravacao() {
        synchronized(travaDaCamera) { gravacaoUsaCamera = false }
        reavaliarCameraComum()
    }

    /**
     * O dono aberto. Espera a abertura em curso até [PRAZO_DO_DONO_S] — o pior caso de
     * `DonoDaCaptura.abrir` são três prazos de 6 s — e, se ela falhou, **tenta de novo uma vez**:
     * uma abertura que falhou (a câmera tomada por outro app no instante em que a tela abriu) não
     * condena a tela inteira (a revisão, M5). `null` se nem assim.
     */
    private fun esperarDonoDaCaptura(cameraId: String, minhaGeracao: Int): com.quall.android.capture.DonoDaCaptura? {
        donoDaCaptura?.let { return it }
        donoAberto?.let { runCatching { it.await(PRAZO_DO_DONO_S, java.util.concurrent.TimeUnit.SECONDS) } }
        donoDaCaptura?.let { return it }
        if (cancelado || minhaGeracao != geracao.get()) return null
        Log.w(TAG, "a câmera do dono não estava aberta (${falhaDoDono ?: "fechada, ou a abertura não terminou"}); abrindo")
        abrirDonoDaCaptura(cameraId, minhaGeracao)
        donoAberto?.let { runCatching { it.await(PRAZO_DO_DONO_S, java.util.concurrent.TimeUnit.SECONDS) } }
        return donoDaCaptura
    }

    /**
     * Fecha a câmera do dono. Da thread de espelhamento, no fim dela; do `onDestroy`; ou, na câmera
     * comum, de [fecharDonoSeOcioso].
     */
    private fun fecharDonoDaCaptura() {
        val d = synchronized(travaDaCamera) { donoDaCaptura.also { donoDaCaptura = null } } ?: return
        runCatching { d.fechar() }.onFailure { Log.w(TAG, "fechar a câmera do dono: ${Log.erroExterno(it.message)}") }
    }

    // --- a câmera da espera ------------------------------------------------------------------

    /**
     * Abre ou fecha a prévia da fase ESPERANDO conforme haja ou não uma tela olhando.
     *
     * ## Por que fechar, e por que este é o critério
     *
     * No iOS o sistema resolve isso sozinho: a `AVCaptureSession` é interrompida
     * (`AVCaptureSessionWasInterrupted`) quando o app sai do primeiro plano, e
     * `apps/ios/Quall/App/EmissorDeCamera.swift` só observa. No Android é o oposto — o serviço em
     * primeiro plano com tipo `camera` existe **justamente** para manter o acesso à câmera com o
     * app em segundo plano. Sem esta regra, tocar em "Espelhar", desistir e guardar o telefone no
     * bolso deixaria a câmera aberta até o prazo de espera acabar, e o laço tentaria de novo.
     *
     * **Não há prazo inventado aqui, e é de propósito.** O critério é "há uma tela olhando", que é
     * a única coisa para que a prévia serve; e o teto de tempo já existe e é um número que o
     * usuário escolheu — o tempo de tela do próprio aparelho, que ao apagar leva a Activity a
     * `onStop` e fecha a câmera por este mesmo caminho. Enquanto a câmera está aberta a pessoa vê:
     * a prévia na tela, a notificação em primeiro plano e o indicador de privacidade do sistema.
     *
     * Custo conhecido: sair do app e voltar durante a espera fecha e reabre a câmera, o que é uma
     * abertura a mais no log e uma piscada a mais no indicador de privacidade. A alternativa —
     * deixar aberta — troca isso por bateria e por "o telefone está filmando e ninguém sabe". O
     * mesmo vale para rotação de tela, que destrói e recria a Activity; medir esse caso na fase de
     * espera é passo do protocolo, não coisa suposta aqui.
     *
     * Roda sempre em [obrasDaCamera], nunca na principal nem na de espelhamento.
     */
    private fun ajustarPreviaDeEspera(cameraId: String, olhando: Boolean) {
        if ((fonteEmCurso as? Fonte.Camera)?.peloDono == true) {
            ajustarDonoDaEspera(cameraId, olhando)
            return
        }
        synchronized(travaDaCamera) {
            // Em ESPELHANDO o sinal é ignorado: ver [codificandoCamera].
            if (codificandoCamera || cancelado) return
            if (cameraDaEspera != cameraId) return
            if (olhando) {
                if (cameraSource != null) return
                runCatching { CameraXSource.abrirComPrevia(this, this, cameraId) }
                    .onSuccess { cameraSource = it }
                    // Sem prévia a espera continua valendo: o PIN, o endereço e o `hostStart` não
                    // dependem da câmera. É a mesma política do recuo de bind em `CameraXSource`.
                    .onFailure { Log.w(TAG, "a prévia da espera não subiu; a espera segue sem ela", it) }
            } else {
                Log.i(TAG, "nenhuma tela olhando — fechando a câmera da espera")
                cameraSource?.let { runCatching { it.parar() } }
                cameraSource = null
            }
        }
    }

    /**
     * A fonte pronta para codificar: acrescenta o `VideoCapture` à câmera que a espera deixou
     * aberta, ou abre do zero se não houver nenhuma.
     *
     * Três degraus, e o último é o que garante que **nunca** se troque "sem prévia" por "sem
     * transmissão" — a mesma política que o recuo de bind de `CameraXSource` já seguia.
     */
    private fun subirFonteDaCamera(cameraId: String): CameraXSource = synchronized(travaDaCamera) {
        codificandoCamera = true

        // 1. O caso normal: a câmera está aberta desde a espera, só falta o use case do
        //    codificador. É aqui que a `CaptureSession` é reconfigurada — com o `MediaCodec`
        //    ainda inexistente, portanto fora da janela que a régua do §8.18 mede.
        cameraSource?.let { aberta ->
            runCatching { aberta.ligarCodificador(estrategia = Bancada.bindDaCamera(this@MirrorService)) }
                .onSuccess { return@synchronized aberta }
                .onFailure {
                    Log.w(TAG, "o codificador não entrou na câmera da espera; reabrindo do zero", it)
                    runCatching { aberta.parar() }
                    cameraSource = null
                }
        }

        // 2. Sem câmera aberta (a tela sumiu durante a espera, ou a prévia nunca subiu): abre
        //    agora, ainda em duas fases, para que a sessão também tenha prévia.
        runCatching { CameraXSource.abrirComPrevia(this, this, cameraId) }
            .onFailure { Log.w(TAG, "a prévia não subiu para esta sessão", it) }
            .getOrNull()
            ?.let { nova ->
                cameraSource = nova
                runCatching { nova.ligarCodificador(estrategia = Bancada.bindDaCamera(this@MirrorService)) }
                    .onSuccess { return@synchronized nova }
                    .onFailure {
                        Log.w(TAG, "o codificador não entrou na câmera recém-aberta", it)
                        runCatching { nova.parar() }
                        cameraSource = null
                    }
            }

        // 3. Último recuo: o caminho de uma fase, um use case só. Transmite sem prévia — nunca
        //    "não transmite".
        Log.w(TAG, "abrindo a câmera $cameraId sem prévia: só o codificador")
        CameraXSource.abrir(this, this, cameraId).also { cameraSource = it }
    }

    /**
     * Fim da sessão: a fonte volta a ser da espera, não da sessão.
     *
     * O `pararFonte` do encoder já desbindou o `VideoCapture` (ver
     * `CameraXSource.soltarCodificador`); esta função repete a chamada — que é idempotente —
     * porque é aqui que se decide o **estado seguinte**: se ainda há tela olhando, a câmera fica
     * aberta em prévia-só e a pessoa continua enquadrando enquanto o serviço espera outro
     * receptor; se não há, ela fecha pela mesma regra de [ajustarPreviaDeEspera].
     */
    private fun devolverFonteDaCameraAEspera() = synchronized(travaDaCamera) {
        codificandoCamera = false
        val src = cameraSource
        when {
            src == null -> Unit
            src.temPrevia && PreviaDaCamera.telaOlhando && !cancelado ->
                runCatching { src.desligarCodificador() }
            else -> {
                runCatching { src.parar() }
                cameraSource = null
                // **Reabrir aqui, e não esperar um sinal de presença que não vem.**
                // `ajustarPreviaDeEspera` só age quando a presença de tela MUDA; se a sessão que
                // acabou tinha sido montada sem prévia (recuo de bind), a espera voltaria com
                // `cameraSource` nulo e ninguém tentaria de novo enquanto a pessoa não saísse e
                // voltasse do app. O sintoma seria "a prévia funcionou uma vez e nunca mais",
                // que é pior que nunca ter funcionado. Ver a revisão de 03/09, risco 1.
                if (PreviaDaCamera.telaOlhando && !cancelado) {
                    cameraDaEspera?.let { id ->
                        obrasDaCamera.execute { ajustarPreviaDeEspera(id, olhando = true) }
                    }
                }
            }
        }
    }

    /**
     * Escolhe a origem e sobe o [EmissorDeAudio]. Nada aqui é fatal.
     *
     * **A ordem das duas origens não é gosto.** O tom sintético vem primeiro porque é o braço de
     * bancada e não pede permissão nenhuma; a captura do próprio app vem depois e pode devolver
     * `null` — falta de `RECORD_AUDIO` é o caso esperado num aparelho onde ninguém tocou o
     * diálogo, e é **estado**, não defeito.
     */
    private fun subirAudio(trackDeAudio: Long, proj: MediaProjection?, tomDeProva: Boolean) {
        val preset = PresetDeAudio.de(QuallNative.TrackKind.SYSTEM_AUDIO)
        if (preset == null) {
            Log.e(TAG, "não consegui ler o preset de áudio do núcleo")
            return
        }
        val prova = com.quall.android.core.Bancada.provaDoSom(this)
        val dvd = transmissaoDvd
        val fonte: FonteDeAudio? = if (dvd != null) {
            // O DVD (§9): o som do disco, no relógio do vídeo; o tom de prova não entra no lugar dele.
            dvd.fonteDeSom(preset.taxaHz, preset.canais, preset.amostrasPorCanal)
        } else if (tomDeProva && prova.ppmNoSom != 0) {
            com.quall.android.audio.TomRitmado(preset.taxaHz, preset.canais, preset.amostrasPorCanal, prova.ppmNoSom.toDouble())
        } else if (tomDeProva) {
            TomSintetico(preset.taxaHz, preset.canais, preset.amostrasPorCanal)
        } else if (proj != null) {
            CapturaDoProprioApp.abrir(proj, preset.taxaHz, preset.canais, preset.amostrasPorCanal)
        } else {
            Log.w(TAG, "sem MediaProjection: AudioPlaybackCapture não existe para esta origem")
            null
        }
        if (fonte == null) {
            Log.w(TAG, "sem origem de áudio — a track fica anunciada e muda. Ver o README.")
            return
        }
        val e = EmissorDeAudio(
            trackDeAudio, QuallNative.TrackKind.SYSTEM_AUDIO, fonte, preset,
            prova = prova,
        )
        if (e.iniciar()) {
            emissorDeAudio = e
            MirrorBus.atualizar { it.copy(resumoDeAudio = "origem: ${fonte.nome}") }
        } else {
            Log.e(TAG, "o emissor de áudio não subiu: ${e.motivoDaSaida}")
            fonte.fechar()
        }
    }

    // --- o DVD (`docs/dvd-para-mp4.md` §9) ----------------------------------------------------

    /**
     * Pega o leitor e o disco da tela ([com.quall.android.dvd.SessaoDoDvd], como o Converter), confere
     * de novo (pronto, CPST e perfil, o mesmo volume: o disco pode ter sido trocado) e começa a leitura.
     * `null` quando não deu, com a frase publicada (no `MirrorBus` e na tela do DVD) e o leitor devolvido.
     */
    private fun abrirDvd(fonte: Fonte.Dvd): com.quall.android.dvd.TransmissaoDoDvd? {
        val bus = com.quall.android.dvd.TransmissaoDvdBus
        val (l, d) = com.quall.android.dvd.SessaoDoDvd.entregarAoServico() ?: run {
            val frase = tx(R.string.esp_dvd_leitor_fechado)
            publicarErro(frase)
            bus.publicar(com.quall.android.dvd.TransmissaoDvdBus.Estado(fase = com.quall.android.dvd.TransmissaoDvdBus.Fase.PARADA, mensagem = frase))
            return null
        }
        val frase = try {
            if (!com.quall.android.dvd.QuallDvd.disponivel) {
                throw IllegalStateException("este aparelho não transmite DVD (precisa de um aparelho de 64 bits)")
            }
            val titulo = d.titulos.firstOrNull { it.numero == fonte.titulo }
                ?: throw IllegalStateException("o título ${fonte.titulo} não existe no disco")
            titulo.recusa?.let { throw com.quall.android.dvd.RecusaDoDisco(it) }
            com.quall.android.dvd.SessaoDoDvd.reconferir(l, d)
            val faixa = when {
                fonte.faixa in titulo.faixasConvertiveis.indices -> fonte.faixa
                titulo.faixasConvertiveis.isNotEmpty() -> 0
                else -> -1
            }
            val ouvinte = object : com.quall.android.dvd.TransmissaoDoDvd.Ouvinte {
                override fun aoCair(motivo: String) {
                    // Como a DV que cai: a sessão termina com a frase, e a espera não recomeça (o
                    // disco recusado ou o leitor parado não voltam sozinhos).
                    cameraDvCaiu = true
                    motivoDaParada = motivo
                    encoder?.stop()
                    synchronized(cancelLock) {
                        if (cancellerHandle != 0L) QuallNative.sessionCancel(cancellerHandle)
                    }
                }
            }
            val t = com.quall.android.dvd.TransmissaoDoDvd(
                this, l, d.volume, titulo, faixa, aceita854 = larguraDv169() == 854, ouvinte = ouvinte,
                inicio90k = fonte.inicio90k,
            )
            t.comecar()
            return t
        } catch (e: com.quall.android.dvd.RecusaDoDisco) {
            Log.w(TAG, "DVD recusado: ${Log.erroExterno(e.message)}")
            e.recusa.em(com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this)))
        } catch (e: com.quall.android.dvd.LeitorParou) {
            Log.w(TAG, "DVD: ${Log.erroExterno(e.message)}")
            com.quall.android.dvd.FrasesDoDvd.LEITOR_PAROU.em(com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this)))
        } catch (e: Exception) {
            Log.e(TAG, "DVD: não abriu", e)
            tx(R.string.esp_dvd_nao_abriu, e.message ?: e.javaClass.simpleName)
        }
        com.quall.android.dvd.SessaoDoDvd.devolverDoServico()
        publicarErro(frase)
        bus.publicar(com.quall.android.dvd.TransmissaoDvdBus.Estado(fase = com.quall.android.dvd.TransmissaoDvdBus.Fase.PARADA, mensagem = frase))
        return null
    }

    /** O pedido de transmitir o DVD não subiu: a tela do DVD sai do "Preparando…" com a [frase]. */
    private fun recusarDvd(frase: String) {
        com.quall.android.dvd.TransmissaoDvdBus.publicar(
            com.quall.android.dvd.TransmissaoDvdBus.Estado(fase = com.quall.android.dvd.TransmissaoDvdBus.Fase.PARADA, mensagem = frase)
        )
    }

    /**
     * O fim da thread de espelhamento com o DVD: a leitura e a decodificação param, e o leitor volta
     * (fecha: o disco pode ser trocado, e a tela lê de novo, como depois do Converter). Se a leitura
     * não sair, o leitor só fecha quando ela sair.
     */
    private fun fecharDvd() {
        val t = transmissaoDvd ?: return
        transmissaoDvd = null
        t.encerrar()
        val frase = motivoDaParada ?: tx(R.string.esp_dvd_terminou)
        // O leitor volta **antes** do PARADA: a tela, ao ver o fim, pode abrir o leitor de novo, e o
        // devolver atrasado fecharia a conexão nova embaixo dela.
        val publicar = {
            com.quall.android.dvd.TransmissaoDvdBus.atualizar {
                it.copy(fase = com.quall.android.dvd.TransmissaoDvdBus.Fase.PARADA, mensagem = it.mensagem.ifEmpty { frase })
            }
        }
        if (t.terminou) {
            com.quall.android.dvd.SessaoDoDvd.devolverDoServico()
            publicar()
        } else thread(name = "quall-dvd-devolver") {
            // Com prazo (a revisão, 6): uma leitura presa no USB não deixa a tela em "Transmitindo" para
            // sempre. Passado o prazo, a frase diz o que fazer; o leitor só volta quando ela sair.
            if (!t.esperarTerminar(30_000)) {
                Log.w(TAG, "DVD: a leitura não saiu em 30 s — o leitor ficou preso")
                com.quall.android.dvd.TransmissaoDvdBus.atualizar {
                    it.copy(fase = com.quall.android.dvd.TransmissaoDvdBus.Fase.PARADA,
                        mensagem = com.quall.android.dvd.FrasesDoDvd.LEITOR_PRESO.em(com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this))))
                }
                t.esperarTerminar(0)
                com.quall.android.dvd.SessaoDoDvd.devolverDoServico()
            } else {
                com.quall.android.dvd.SessaoDoDvd.devolverDoServico()
                publicar()
            }
        }
    }

    /**
     * `RECORD_AUDIO` **concedida**, lida e não pedida.
     *
     * `docs/regras-de-frente.md`: *"ler o estado de uma permissão não é pedi-la"* — e o corolário
     * vale aqui na direção certa. Quem **pede** é a Activity, com o usuário na frente; um Service
     * não tem como mostrar diálogo. Se falta, a track de áudio simplesmente não é anunciada, e o
     * README diz o que o usuário precisa tocar.
     */
    /** "a placa de captura", "a filmadora" ou "o aparelho de vídeo USB", pelo que se sabe dele. */
    private fun nomeDoVideoUsb(id: String): String {
        com.quall.android.capture.dv.UsbDv.lembrarEm(this)
        val usb = getSystemService(android.hardware.usb.UsbManager::class.java)
        val dev = usb?.let { com.quall.android.capture.dv.UsbDv.porId(it, id) }
        return com.quall.android.capture.dv.VideoUsb.nome(
            com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this)),
            dev?.let { com.quall.android.capture.dv.UsbDv.conhecido(it) } ?: com.quall.android.capture.dv.VideoUsb.Conhecido.DESCONHECIDO
        )
    }

    private fun temPermissaoDeGravacao(): Boolean =
        androidx.core.content.ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

    // --- o microfone da câmera ---------------------------------------------------------------

    /**
     * O botão, na thread principal ([pedirMicrofone]). Ligar pede o tipo `microphone` ao serviço em
     * primeiro plano **antes** de abrir o `AudioRecord` (a S-A5: o Android 14+ aceita acrescentar o
     * tipo a um serviço de câmera já em primeiro plano); desligar fecha a captura e depois tira o
     * tipo. A captura em si abre e fecha em [obrasDoMicrofone] ([aplicarMicrofone]), com alguém para
     * ouvir: um receptor, ou a gravação da tela R5.
     */
    internal fun microfone(ligar: Boolean) {
        val fonte = synchronized(cancelLock) { fonteEmCurso }
        if (fonte == null || fonte is Fonte.Tela || fonte is Fonte.Dvd || cancelado) {
            Log.w(TAG, "microfone: pedido (${if (ligar) "ligar" else "desligar"}) sem espelhamento de câmera — ignorado")
            MicrofoneBus.atualizar {
                val parado = it.copy(ligado = false, capturando = false, motivo = "")
                if (ligar) parado.comMotivo(com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this@MirrorService)), MotivoDoMicrofone.SEM_VIDEO_NO_AR) else parado
            }
            return
        }
        // O tom da bancada, o som da fita (de dentro do DV) e o da placa pelo usbfs (§13.10) não abrem
        // microfone nenhum.
        val semMic = fonteDv?.let { !it.mjpeg || it.temSomUsb } == true
        val deProva = Bancada.microfoneDeProva(this) || semMic
        if (ligar && !deProva) {
            // Ler, e não pedir: quem pede é a tela, no toque (`docs/regras-de-frente.md`).
            if (!temPermissaoDeGravacao()) {
                Log.w(TAG, "microfone: sem RECORD_AUDIO — recusado")
                MicrofoneBus.atualizar { it.copy(ligado = false, capturando = false).comMotivo(com.quall.android.core.Idioma.textos(com.quall.android.core.Idioma.contexto(this@MirrorService)), MotivoDoMicrofone.SEM_PERMISSAO) }
                return
            }
            if (!tipoMicrofoneNoServico) {
                val r = runCatching { startForegroundCompat(textoDaNotificacao, tipoDaFonte, comMicrofone = true) }
                if (r.isFailure) {
                    val e = r.exceptionOrNull()
                    Log.w(TAG, "microfone: o Android recusou o tipo microphone no serviço", e)
                    MicrofoneBus.atualizar {
                        it.copy(ligado = false, capturando = false,
                            motivo = tx(R.string.esp_mic_android_recusou, e?.javaClass?.simpleName.toString()))
                    }
                    return
                }
                tipoMicrofoneNoServico = true
                Log.i(TAG, "microfone: tipo microphone acrescentado ao serviço em primeiro plano")
            }
        }
        microfonePedido = ligar
        Log.i(TAG, "microfone: botão ${if (ligar) "ligado" else "desligado"}${if (semMic) " (o som da fita ou da placa pelo USB, sem microfone)" else if (deProva) " (bancada: tom no lugar do microfone)" else ""}")
        MicrofoneBus.atualizar { it.copy(ligado = ligar, motivo = "", aviso = "") }
        renotificar()
        runCatching { obrasDoMicrofone.execute { aplicarMicrofone() } }
    }

    /**
     * Abre ou fecha o microfone e o som da rede conforme o botão, a sessão e a gravação. Em
     * [obrasDoMicrofone], sob [travaDoMicrofone].
     *
     * - **o microfone** ([microfoneAberto]) abre com o botão ligado e alguém para ouvir: uma track no
     *   ar (a rede), **ou a gravação da tela R5** (§5.3: grava sem receptor, e com o microfone). Até
     *   a fase 2 ele abria só com receptor; a gravação é o segundo consumidor, e o desvio caiu;
     * - **o som da rede** ([emissorDoMicrofone]) sobe com o microfone aberto e uma track no ar, e lê
     *   um ramal dele: o receptor que conecta no meio de uma gravação não reabre o microfone, e o que
     *   cai não o fecha;
     * - **o som da gravação** fica pendurado no microfone enquanto houver os dois.
     */
    private fun aplicarMicrofone() {
        synchronized(travaDoMicrofone) {
            val atual = emissorDoMicrofone
            if (atual != null && !atual.vivo) emissorDoMicrofone = null // saiu sozinho
            val aberto = microfoneAberto
            if (aberto != null && !aberto.vivo) microfoneAberto = null // a leitura parou sozinha
            val track = trackDoMicrofone
            if (microfonePedido && track != 0L && trackComEmissorPreso == track) {
                // Um emissor desta sessão não saiu ao ser parado: não se abre outro na mesma track.
                recusarMicrofone(tx(R.string.esp_mic_anterior_aberto))
            }
            val gravacao = somDaGravacao
            val querRede = microfonePedido && track != 0L && trackComEmissorPreso != track
            val querMicrofone = querRede || (microfonePedido && gravacao != null)
            // A rede sai primeiro: o ramal dela é do microfone que pode fechar logo abaixo.
            val e = emissorDoMicrofone
            if (!querRede && e != null) {
                emissorDoMicrofone = null
                if (!e.parar()) {
                    Log.e(TAG, "microfone: o emissor não saiu em 2 s — a track fica presa até a sessão acabar")
                    trackComEmissorPreso = track
                }
                Log.i(TAG, "microfone: o som da rede parou: ${e.resumo()}")
            }
            val m = microfoneAberto
            if (!querMicrofone && m != null) {
                microfoneAberto = null
                m.gravacao = null
                if (!m.fechar()) Log.e(TAG, "microfone: a leitura não saiu em 2 s (${m.nome})")
                Log.i(TAG, "microfone fechado: lidos=${m.quadrosLidos} sem_fonte=${m.quadrosSemFonte}")
            }
            if (querMicrofone && microfoneAberto == null) abrirMicrofone()
            microfoneAberto?.gravacao = gravacao
            val aberta = microfoneAberto
            if (querRede && emissorDoMicrofone == null && aberta != null) subirSomDaRede(track, aberta)
            val capturando = microfoneAberto != null
            MicrofoneBus.atualizar {
                it.copy(capturando = capturando, origem = if (capturando) it.origem else "")
            }
        }
        if (!microfonePedido) tirarTipoMicrofone()
    }

    /** O aviso do som da placa (o silêncio da entrada, a entrada que não é a placa) vai ao botão. */
    private val avisoDoSomDaPlaca: (String?) -> Unit = { a ->
        MicrofoneBus.atualizar { if (it.daPlaca) it.copy(aviso = a ?: "") else it }
    }

    /**
     * A entrada `TYPE_BUILTIN_MIC`, pedida explicitamente nas câmeras que não são a placa (§8, medido:
     * com a placa plugada, o `MIC` sem preferência lia dela), ou `null` sem nenhuma.
     */
    private fun microfoneEmbutido(): android.media.AudioDeviceInfo? {
        val am = getSystemService(android.media.AudioManager::class.java) ?: return null
        val entradas = am.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
        val e = com.quall.android.capture.dv.GravacaoDaPlaca.escolherEmbutido(entradas.map {
            com.quall.android.capture.dv.GravacaoDaPlaca.Entrada(
                it.id, it.type == android.media.AudioDeviceInfo.TYPE_USB_DEVICE, it.productName?.toString().orEmpty(),
                embutido = it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC,
            )
        }) ?: return null
        return entradas.firstOrNull { it.id == e.id }
    }

    /** Sob [travaDoMicrofone]: abre a fonte (o microfone cru, o som da placa, ou o tom da bancada) e a leitura dela. */
    private fun abrirMicrofone() {
        val preset = PresetDeAudio.de(QuallNative.TrackKind.MICROPHONE)
        if (preset == null) {
            Log.e(TAG, "microfone: não consegui ler o preset MICROPHONE do núcleo")
            recusarMicrofone(tx(R.string.esp_mic_sem_formato))
            return
        }
        val prova = Bancada.provaDoSom(this)
        var motivo = ""
        val daPlaca = fonteDv?.mjpeg == true
        val daFita = fonteDv?.mjpeg == false
        if (daPlaca && (preset.taxaHz != com.quall.android.capture.dv.DonoDaPlaca.TAXA_DO_SOM || preset.canais != 1)) {
            // O som da placa é 48 kHz mono em quadros do preset; outro preset não casa com o ramal.
            Log.w(TAG, "som da placa: o preset do microfone é ${preset.linha()}, e não 48 kHz mono — vai o microfone do telefone")
        }
        val fonte: FonteDeAudio? = if (Bancada.microfoneDeProva(this)) {
            // **Bancada** (`docs/audio.md` §8): o tom, ritmado como uma captura e com a hora da
            // primeira amostra — o caminho do carimbo na captura roda inteiro, sem microfone nenhum.
            com.quall.android.audio.TomRitmado(preset.taxaHz, preset.canais, preset.amostrasPorCanal, prova.ppmNoSom.toDouble())
        } else if (daFita) {
            // A filmadora DV: o som de dentro do quadro, um ramal da fonte (§13.8). Nunca o microfone
            // do telefone: com outro preset, ou sem a fonte, o som não abre.
            if (preset.taxaHz == com.quall.android.capture.dv.FonteDv.TAXA_DA_REDE && preset.canais == 1) fonteDv?.ramalDoSomDaFita()
            else { motivo = tx(R.string.esp_mic_formato_errado); null }
        } else if (daPlaca && preset.taxaHz == com.quall.android.capture.dv.DonoDaPlaca.TAXA_DO_SOM && preset.canais == 1) {
            // A placa: um ramal do `AudioRecord` da placa (a entrada USB dela pedida), o mesmo da
            // gravação e do ouvir (§11). O silêncio e a entrada errada chegam por [avisoDoSomDaPlaca].
            com.quall.android.capture.dv.DonoDaPlaca.ramalDoSom(this) { motivo = it }
        } else {
            MicrofoneCru.abrir(
                preset.taxaHz, preset.canais, preset.amostrasPorCanal,
                falha = { motivo = tx(it.frase) },
                aoSilencioDigital = { silencio ->
                    MicrofoneBus.atualizar {
                        it.copy(aviso = if (silencio) tx(R.string.esp_mic_so_silencio) else "")
                    }
                },
                // Com uma placa (ou um fone USB) plugada, o `MIC` do sistema leria dela (§8).
                preferido = microfoneEmbutido(),
            )
        }
        if (fonte == null) {
            recusarMicrofone(motivo.ifBlank { tx(R.string.esp_mic_nao_abriu) })
            return
        }
        // A identidade vai junto (a revisão, M1): o aviso de um microfone velho que morreu não pode
        // desligar o botão de um novo que já abriu no lugar dele.
        var eu: MicrofoneCompartilhado? = null
        val m = MicrofoneCompartilhado(fonte, preset, aoSairSozinho = { motivoDaSaida ->
            val quem = eu
            runCatching { obrasDoMicrofone.execute { microfoneSaiuSozinho(quem, null, motivoDaSaida) } }
        })
        eu = m
        m.iniciar()
        microfoneAberto = m
        val efeitos = (fonte as? MicrofoneCru)?.efeitos?.let { " efeitos=[$it]" } ?: ""
        Log.i(TAG, "microfone aberto: ${preset.linha()} origem=${fonte.nome}$efeitos " +
            "(para ${listOfNotNull(if (trackDoMicrofone != 0L) "a rede" else null, if (somDaGravacao != null) "a gravação" else null).joinToString(" e ")})") // i18n-fora: diário
        MicrofoneBus.atualizar {
            it.copy(capturando = true, origem = fonte.nome, motivo = "",
                aviso = if (daPlaca) com.quall.android.capture.dv.DonoDaPlaca.avisoDoSom ?: "" else "")
        }
    }

    /** Sob [travaDoMicrofone]: o som da rede, lendo um ramal do microfone aberto. */
    private fun subirSomDaRede(track: Long, m: MicrofoneCompartilhado) {
        val preset = PresetDeAudio.de(QuallNative.TrackKind.MICROPHONE) ?: run {
            falhouOSomDaRede(tx(R.string.esp_mic_sem_formato))
            return
        }
        val ramal = m.ramal()
        var eu: EmissorDeAudio? = null
        val e = EmissorDeAudio(
            track, QuallNative.TrackKind.MICROPHONE, ramal, preset,
            prova = Bancada.provaDoSom(this),
            aoSairSozinho = { motivo ->
                val quem = eu
                runCatching { obrasDoMicrofone.execute { microfoneSaiuSozinho(null, quem, motivo) } }
            },
        )
        eu = e
        if (!e.iniciar()) {
            ramal.fechar()
            falhouOSomDaRede(e.motivoDaSaida)
            return
        }
        emissorDoMicrofone = e
        Log.i(TAG, "microfone aberto e mandando: ${preset.linha()} origem=${m.nome}")
    }

    /**
     * O som da rede não subiu (a revisão, menor): sem gravação, o microfone ficaria aberto para
     * ninguém — o botão desliga e diz por quê; gravando, o microfone segue para o arquivo e a tela
     * avisa. Sob [travaDoMicrofone].
     */
    private fun falhouOSomDaRede(motivo: String) {
        Log.e(TAG, "microfone: o som da rede não subiu: ${Log.erroExterno(motivo)}")
        if (somDaGravacao == null) {
            recusarMicrofone(tx(R.string.esp_mic_som_nao_subiu, motivo))
            runCatching { obrasDoMicrofone.execute { aplicarMicrofone() } }
        } else {
            MicrofoneBus.atualizar { it.copy(aviso = tx(R.string.esp_mic_so_na_gravacao, motivo)) }
        }
    }

    /** O microfone não abriu: o botão volta a desligado, com o motivo, e o tipo sai do serviço. */
    private fun recusarMicrofone(motivo: String) {
        microfonePedido = false
        Log.w(TAG, "microfone: ${Log.erroExterno(motivo)} — o botão volta a desligado")
        MicrofoneBus.atualizar { it.copy(ligado = false, capturando = false, origem = "", motivo = motivo, aviso = "") }
        renotificar()
    }

    /**
     * A leitura do microfone ([microfone]) ou o som da rede ([emissor]) saiu sozinho (a fonte parou,
     * o codificador não nasceu): o botão desliga e diz por quê — a menos que o aviso seja de um que já
     * foi trocado por outro.
     */
    private fun microfoneSaiuSozinho(microfone: MicrofoneCompartilhado?, emissor: EmissorDeAudio?, motivo: String) {
        val meu = synchronized(travaDoMicrofone) {
            if (microfone != null) {
                val atual = microfoneAberto
                when {
                    atual != null && atual !== microfone -> false
                    atual === microfone -> { microfoneAberto = null; true }
                    else -> true
                }
            } else {
                val atual = emissorDoMicrofone
                when {
                    atual != null && atual !== emissor -> false
                    atual === emissor -> { emissorDoMicrofone = null; true }
                    else -> true
                }
            }
        }
        if (!meu) {
            Log.i(TAG, "microfone: aviso de saída de um anterior (${Log.erroExterno(motivo)}) — ignorado")
            return
        }
        recusarMicrofone(tx(R.string.esp_mic_parou, motivo))
        aplicarMicrofone()
    }

    // --- a gravação (a tela R5, e a câmera comum pelo dono) ---------------------------------------

    /**
     * O botão Gravar — da tela R5 ou, desde 24/09, da tela inicial no espelhamento de câmera comum
     * (§8.6) — e o pedido do controle que a tela R5 aceitou (§5.5), na principal. Começar e parar
     * vão para [obrasDaGravacao]; o resultado sai no [GravacaoDaTelaBus]. **Gravar não liga o
     * microfone** (decisão do Pessoa Exemplo, 24/09): o som entra se o botão dele estiver ligado, e o
     * indicador diz "SEM SOM" se não estiver.
     */
    internal fun gravacao(gravar: Boolean, daTelaR5: Boolean) {
        val g = gravacaoDaTela
        val fonte = fonteEmCurso
        if (g == null || cancelado || !fonte.usaDono() || daTelaR5 != (fonte is Fonte.CameraDoPrompter)) {
            if (gravar) recusarGravacao(
                when {
                    fonte is Fonte.Camera && fonte.dv && fonteDv?.mjpeg == true ->
                        tx(R.string.esp_grav_placa_tem_botao)
                    fonte is Fonte.Camera && fonte.dv -> tx(R.string.esp_grav_filmadora_tem_botao)
                    fonte != null && fonte !is Fonte.Tela && daTelaR5 != (fonte is Fonte.CameraDoPrompter) ->
                        tx(R.string.esp_grav_camera_ocupada)
                    else -> tx(R.string.esp_grav_sem_espelhamento)
                }
            )
            return
        }
        val comum = fonte is Fonte.Camera
        // O aparelho que não grava (§14.3): a tela já não oferece; o pedido que chegou mesmo assim
        // (o controle de uma versão anterior, a bancada) é recusado com o motivo.
        if (gravar) {
            // A conta ainda não voltou da thread (um pedido logo na abertura): faz aqui, uma vez.
            val e = GravacaoDaTelaBus.atual
            val motivo = if (e.indisponivelConferido) e.indisponivel else GravacaoIndisponivel.motivo(this)
            motivo?.let { recusarGravacao(it); return }
        }
        runCatching {
            obrasDaGravacao.execute {
                if (gravar) {
                    if (g.gravando) return@execute
                    // A tela pode ter fechado entre o pedido e esta vez da fila (o bloqueio 1).
                    if (gravacaoDaTela !== g || cancelado) {
                        recusarGravacao(tx(R.string.esp_grav_fechando))
                        return@execute
                    }
                    // A câmera comum não fecha pela tela sumir enquanto a gravação começa ou grava
                    // (marcado antes de ler o dono, como a sessão).
                    if (comum) synchronized(travaDaCamera) { gravacaoUsaCamera = true }
                    val d = donoDaCaptura ?: run {
                        // A câmera comum abrindo agora (a prévia acabou de pedir): espera um pouco.
                        donoAberto?.let { runCatching { it.await(6, java.util.concurrent.TimeUnit.SECONDS) } }
                        donoDaCaptura
                    }
                    val motivo = g.comecar(d)
                    if (motivo != null) {
                        if (comum) cameraSoltaPelaGravacao()
                        recusarGravacao(motivo)
                    } else {
                        renotificar()
                    }
                } else {
                    pararGravacao(tx(R.string.esp_grav_parada_pelo_botao))
                }
            }
        }.onFailure { if (gravar) recusarGravacao(tx(R.string.esp_servico_fechando)) }
    }

    /** Em [obrasDaGravacao]: para, fecha e publica. */
    private fun pararGravacao(motivo: String) {
        val g = gravacaoDaTela ?: return
        if (!g.gravando) return
        g.parar(motivo)
        cameraSoltaPelaGravacao()
        renotificar()
    }

    private fun recusarGravacao(motivo: String) {
        Log.w(TAG, "gravação recusada: ${Log.erroExterno(motivo)}")
        GravacaoDaTelaBus.atualizar { it.copy(recusa = motivo, numeroDaRecusa = it.numeroDaRecusa + 1) }
    }

    /** O som da gravação pendurado (ou solto) no microfone; o microfone abre ou fecha por isso. */
    private fun pendurarSomDaGravacao(g: MicrofoneCompartilhado.Gravacao?) {
        somDaGravacao = g
        // Sem esperar: quem chama é a thread da gravação, e ela não pode ficar atrás da abertura
        // do microfone (a gravação começa com silêncio e o som entra quando o microfone abrir).
        runCatching { obrasDoMicrofone.execute { aplicarMicrofone() } }
    }

    /** Tira o tipo `microphone` do serviço, na principal, se ele estiver lá e o botão desligado. */
    private fun tirarTipoMicrofone() {
        android.os.Handler(mainLooper).post {
            if (!tipoMicrofoneNoServico || microfonePedido || fonteEmCurso == null) return@post
            runCatching { startForegroundCompat(textoDaNotificacao, tipoDaFonte, comMicrofone = false) }
                .onSuccess {
                    tipoMicrofoneNoServico = false
                    Log.i(TAG, "microfone: tipo microphone tirado do serviço em primeiro plano")
                }
                .onFailure { Log.w(TAG, "microfone: não consegui tirar o tipo microphone do serviço", it) }
        }
    }

    // ---------------------------------------------------------------------------------------

    /**
     * Para o espelhamento. Se estiver capturando, para o encoder; se estiver **esperando** em
     * `quall_host_cancelable`, cancela pelo [cancellerHandle] — nunca com um handle que já foi
     * liberado: [cancelLock] garante que a leitura e a chamada acontecem atrás da mesma trava que
     * zera o campo em [espelhar].
     */
    private fun parar() {
        cancelado = true
        encoder?.stop()
        synchronized(cancelLock) {
            if (cancellerHandle != 0L) {
                QuallNative.sessionCancel(cancellerHandle)
            }
        }
        MirrorBus.atualizar { it.copy(fase = MirrorBus.Fase.PARADO, mensagem = "parando…") }
    }

    /**
     * Bitrate **obtido** na sessão, em bps: bytes que saíram do encoder divididos pela duração.
     *
     * A duração vem do `achievedFps` e da contagem de quadros, e não de um relógio de parede,
     * porque é a mesma base do `fps_obtido` que sai ao lado — dois números da mesma corrida têm
     * de vir do mesmo relógio.
     *
     * **Numa corrida com escada este número é uma média sobre degraus diferentes**, e não
     * descreve nenhum deles. Quem quer o ponto da curva lê as linhas `janela_do_fio`.
     */
    private fun bitrateObtidoBps(r: H264SurfaceEncoder.Result): Long {
        if (r.frameCount < 2 || r.achievedFps <= 0.0) return 0
        val segundos = (r.frameCount - 1) / r.achievedFps
        return if (segundos <= 0) 0 else (r.bytesDeSaida * 8 / segundos).toLong()
    }

    /** 854 se o encoder AVC aceitar 854x480; senão 848 (múltiplo de 16). */
    private fun larguraDv169(): Int {
        val lista = android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS)
        val f = android.media.MediaFormat.createVideoFormat(android.media.MediaFormat.MIMETYPE_VIDEO_AVC, 854, 480)
        val aceita = runCatching { lista.findEncoderForFormat(f) != null }.getOrDefault(false)
        if (!aceita) Log.i(TAG, "câmera DV: o encoder não aceita 854x480; usando 848x480")
        return if (aceita) 854 else 848
    }

    private fun publicarErro(msg: String) {
        Log.e(TAG, "estado=ERRO causa=${Log.erroExterno(msg)}")
        MirrorBus.publicar(MirrorBus.Estado(fase = MirrorBus.Fase.ERRO, mensagem = msg))
    }

    /**
     * IP que um aparelho **da mesma LAN** consegue discar: IPv4 primeiro, Wi-Fi na frente,
     * e IPv6 ULA/global da LAN como fallback.
     *
     * A ordem e o filtro não são estética: o primeiro endereço desta lista é o que a tela de
     * espera mostra em destaque e o que a pessoa digita do outro lado.
     *
     * ## O que o Galaxy S24 achou, e nenhum aparelho da bancada tinha achado antes
     *
     * Ele é o primeiro aparelho aqui com **dados móveis ativos**, e numa operadora IPv6-only o
     * Android sobe o 464XLAT: a `rmnet_data0` ganha um IPv4 em **`192.0.0.2/27`**, que é a faixa
     * de *IETF Protocol Assignments* — um endereço de tradução, local ao aparelho, que **nenhum
     * par da LAN alcança**. A enumeração de interfaces trouxe essa antes da `wlan0`, e a tela de
     * espera passou a anunciar `192.0.0.2:7923`. O receptor digitou exatamente o que estava
     * escrito e levou `connection timed out`.
     *
     * A regra compartilhada por Espelhar, teleprompter e a linha de rede da tela:
     *
     * 1. **Fora a 192.0.0.0/24.** É a faixa do clat, e ela não é endereço de LAN em aparelho
     *    nenhum. CGNAT, celular e VPN também não devem virar o endereço da espera.
     * 2. **`wlan` primeiro.** Espelhar é caso de rede local; se houver Wi-Fi, é por ele que o par
     *    chega. As outras continuam listadas embaixo — esconder o resto esconderia o produto em
     *    rede que não seja Wi-Fi (Ethernet por USB, por exemplo).
     */
    private fun enderecosLocais(): List<String> = EnderecosLocais.listar().map { it.ip }

    // ---------------------------------------------------------------------------------------

    /**
     * O texto de interface no idioma escolhido (`docs/traducao.md`, Android): abaixo do Android 13 o
     * AppCompat não alcança o serviço, e [Idioma.contexto] monta o contexto certo. Pedido na hora, e
     * nunca guardado: a pessoa pode trocar de idioma com o serviço no ar.
     */
    private fun tx(@androidx.annotation.StringRes id: Int, vararg args: Any): String {
        val c = com.quall.android.core.Idioma.contexto(this)
        return if (args.isEmpty()) c.getString(id) else c.getString(id, *args)
    }

    private fun startForegroundCompat(texto: String, sourceKind: String, comMicrofone: Boolean = false) {
        textoDaNotificacao = texto
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    // O nome do canal também no idioma de agora: recriar com o mesmo id só renomeia.
                    tx(R.string.notification_channel_capture),
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }
        val notification = construirNotificacao(texto)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // O manifesto declara os três tipos (`mediaProjection|camera|microphone`); em runtime
            // só se pede o que a sessão em curso está de fato usando.
            var tipo = if (sourceKind == SOURCE_CAMERA || sourceKind == SOURCE_PROMPTER_CAMERA) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            } else if (sourceKind == SOURCE_DVD) {
                // O DVD (§9): um vídeo tocado para outro aparelho, sem câmera nem captura de tela.
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            }
            // O tipo `microphone` só entra quando vai existir um `AudioRecord` de verdade: na tela, a
            // captura do próprio app; na câmera, o microfone com o botão ligado ([microfone], que
            // chama isto de novo — a S-A5 mediu que o Android 14+ aceita acrescentar o tipo com o
            // serviço já em primeiro plano). **O tom sintético não pede tipo nenhum**, porque não
            // abre captura nenhuma; e pedir um tipo que não se usa é declarar no sistema o que não
            // se faz, que é a mesma classe de defeito do `useinbandfec` sem LBRR e do SPS sem
            // `bitstream_restriction`.
            if (sourceKind == SOURCE_SCREEN && Bancada.emitirAudio(this) && !Bancada.tomDeProva(this) && temPermissaoDeGravacao()) {
                tipo = tipo or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (comMicrofone && sourceKind != SOURCE_SCREEN) {
                tipo = tipo or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            startForeground(NOTIF_ID, notification, tipo)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /**
     * **O botão Parar, sempre; com o microfone ligado, a notificação diz, e tem o botão de desligar** (a revisão, M6): o
     * app pode estar atrás de outro, e o indicador do sistema diz que *algum* app ouve, não qual
     * botão desliga.
     */
    private fun construirNotificacao(texto: String): Notification {
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(
                (if (GravacaoDaTelaBus.atual.fase == GravacaoDaTelaBus.Fase.GRAVANDO) tx(R.string.esp_notif_gravando) else "") +
                    if (microfonePedido) tx(R.string.esp_notif_com_microfone, texto) else texto
            )
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
        // **Parar**, sempre (o pedido do Pessoa Exemplo, 30/09, para a declaração do `mediaPlayback` no Play Console):
        // o [ACAO_PARAR] sem marcador para a sessão em curso, qualquer que seja a fonte.
        val parar = android.app.PendingIntent.getService(
            this, 2,
            Intent(this, MirrorService::class.java).setAction(ACAO_PARAR),
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
        )
        b.addAction(0, tx(R.string.esp_parar), parar)
        if (microfonePedido) {
            val pi = android.app.PendingIntent.getService(
                this, 1,
                Intent(this, MirrorService::class.java).setAction(ACAO_DESLIGAR_MICROFONE),
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
            )
            b.addAction(0, tx(R.string.microfone_desligar), pi)
        }
        return b.build()
    }

    /** A notificação de novo, com o texto de agora: o estado do microfone mudou. */
    private fun renotificar() {
        if (fonteEmCurso == null) return
        runCatching {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, construirNotificacao(textoDaNotificacao))
        }
    }

    private fun atualizarNotificacao(texto: String, fonteRotulo: String) {
        runCatching {
            textoDaNotificacao = tx(R.string.esp_notif_com_fonte, texto, fonteRotulo)
            getSystemService(NotificationManager::class.java)
                .notify(NOTIF_ID, construirNotificacao(textoDaNotificacao))
        }
    }

    /**
     * O app tirado dos recentes. A câmera da tela R5 é **da tela**: sem a tela, ela fecha — o
     * `onDestroy` da Activity nem sempre roda nesse caminho. O espelhamento comum segue como sempre
     * seguiu (quem apoia o telefone e sai do app está transmitindo de propósito).
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (fonteEmCurso is Fonte.CameraDoPrompter) {
            Log.i(TAG, "o app saiu dos recentes com a tela R5 aberta — fechando a câmera dela")
            parar()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (instancia === this) instancia = null
        cancelado = true
        encoder?.stop()
        // Antes de fechar a câmera: enquanto o ouvinte estiver registrado, um `onStop`/`onStart`
        // da Activity ainda mandaria abrir de novo o que se está fechando aqui.
        PreviaDaCamera.observarTela(null)
        cameraDaEspera = null
        runCatching { obrasDaCamera.shutdownNow() }
        // `shutdown` e não `shutdownNow`: interromper o `join` de um emissor no meio deixaria a
        // track sem dono claro. O fim da sessão já fechou o microfone antes daqui.
        runCatching { obrasDoMicrofone.shutdown() }
        // A gravação já fechou no fim da thread de espelhamento; a fila só termina o que tiver.
        runCatching { obrasDaGravacao.shutdown() }
        // **Sem [travaDaCamera], e de propósito.** Este método roda na thread principal, e quem
        // segura a trava (espelhamento ou [obrasDaCamera]) pode estar esperando um `post` nessa
        // mesma thread principal — `CameraXSource` abre e fecha por lá. Pegar a trava aqui seria
        // travar a principal contra alguém que só sai quando a principal andar: ANR de verdade.
        // `parar()` é idempotente e guarda o próprio estado, então a corrida com um `shutdownNow`
        // ainda em curso custa, no pior caso, uma chamada que volta de imediato.
        runCatching { cameraSource?.parar() }
        cameraSource = null
        // Sem a trava, pelo mesmo motivo; `fechar` é idempotente e, na principal, desbinda direto.
        donoDaCaptura?.let { runCatching { it.fechar() } }
        donoDaCaptura = null
        runCatching { multicastLock?.release() }
        runCatching { radioAcordado?.liberar() }
        super.onDestroy()
    }
}
