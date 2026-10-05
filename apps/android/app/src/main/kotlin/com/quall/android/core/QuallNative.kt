// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.core

import java.nio.ByteBuffer

/**
 * Ligação com o núcleo Rust, via `libqualljni.so` → `libquall.so`
 * (`crates/quall-ffi/include/quall.h`).
 *
 * ## Nenhum callback do Rust para cá
 *
 * A fronteira C tem duas formas de receber o pedido de IDR do receptor:
 * `quall_track_on_idr_request` (tratador chamado de uma thread da libdatachannel) e
 * [trackTakeIdrRequest] (bandeira atômica que o emissor consome). **Só a segunda é usada.** A
 * primeira exigiria `AttachCurrentThread` + `NewGlobalRef` + desanexar na saída da thread da
 * libdatachannel — três chances de derrubar o processo num aparelho de 1,79 GB, por causa de um
 * pedido de quadro-chave. O emissor já tem um laço por quadro, o do `MediaCodec`; uma leitura
 * atômica por volta não custa nada. O mesmo vale para descoberta, sinalização e pareamento: são
 * laços síncronos que rodam na thread de quem chamou, não callbacks.
 *
 * **Receber é o único caso em que não há alternativa a um callback** — `quall_track_on_frame` é a
 * única porta por onde o quadro remontado sai do núcleo. A regra acima continua valendo mesmo
 * assim: o tratador registrado é uma função **em C** ([frameBoxNew], a "caixa de quadros"), que
 * copia os bytes para um anel e sinaliza uma condvar sem tocar em `JNIEnv` nenhum. Quem cruza
 * para o Java é a thread do receptor, chamando [frameBoxTake] — uma thread Java, que já está
 * anexada. Nenhuma thread da libdatachannel é anexada à JVM em nenhum caminho deste app.
 *
 * ## Toda string atravessa como `ByteArray`
 *
 * `GetStringUTFChars`/`NewStringUTF` do JNI usam **UTF-8 modificado** (CESU-8), que não é UTF-8:
 * um caractere fora do BMP (emoji num nome de aparelho, por exemplo) vira uma sequência que o
 * Rust recusa com `QUALL_STATUS_NOT_UTF8`. Aqui a conversão é explícita, com [Charsets.UTF_8],
 * dos dois lados. As funções `external` de baixo nível são privadas justamente para que ninguém
 * as chame direto e reintroduza o problema; use os invólucros públicos.
 *
 * ## `quall_cleanup` não existe aqui
 *
 * O header o descreve como "chame **uma vez**, na saída do processo", e adverte que chamar com
 * uma sessão viva **trava o processo**. No Android não existe "saída do processo": o Service
 * para e o processo continua vivo, e `System.loadLibrary` não descarrega a `.so`. Logo não há
 * instante seguro nem ganho — a função foi deixada de fora de propósito, não por esquecimento.
 *
 * ## Erros
 *
 * Funções que devolvem ponteiro devolvem `0L` em erro; o motivo sai em [lastError], que é
 * **por thread** — chame da mesma thread que falhou, antes de qualquer outra chamada que possa
 * falhar.
 */
object QuallNative {

    /** Espelha `QuallStatus` de `quall.h`. */
    object Status {
        const val OK = 0
        const val INVALID = 1
        const val PROTOCOL = 2
        const val DISCOVERY = 3
        const val SIGNALING = 4
        const val TRANSPORT = 5
        const val PAIRING = 6
        const val TIMEOUT = 7
        const val CLOSED = 8
        const val IO = 9
        const val NULL_POINTER = 10
        const val NOT_UTF8 = 11
        const val NO_ROUTE = 12
        const val NEEDS_PIN = 13
        const val CANCELLED = 14

        /** O PIN digitado não conferiu (dívida 29). Uma tentativa por conexão. */
        const val WRONG_PIN = 15

        /**
         * **Ocupado, tente de novo** (`docs/contrato-teleprompter.md` §2): o teleprompter já tem
         * controle — ou é o mesmo controle voltando de uma queda que o prompter ainda não percebeu
         * (até 5 s). Nunca é queda.
         */
        const val BUSY = 16

        fun nome(codigo: Int): String = when (codigo) {
            OK -> "ok" // i18n-fora: nome do status, só no diário
            INVALID -> "entrada inválida" // i18n-fora: nome do status, só no diário
            PROTOCOL -> "protocolo" // i18n-fora: nome do status, só no diário
            DISCOVERY -> "descoberta" // i18n-fora: nome do status, só no diário
            SIGNALING -> "sinalização" // i18n-fora: nome do status, só no diário
            TRANSPORT -> "transporte" // i18n-fora: nome do status, só no diário
            PAIRING -> "pareamento" // i18n-fora: nome do status, só no diário
            TIMEOUT -> "prazo estourado" // i18n-fora: nome do status, só no diário
            CLOSED -> "fechado" // i18n-fora: nome do status, só no diário
            IO -> "io" // i18n-fora: nome do status, só no diário
            NULL_POINTER -> "ponteiro nulo" // i18n-fora: nome do status, só no diário
            NOT_UTF8 -> "texto não é UTF-8" // i18n-fora: nome do status, só no diário
            NO_ROUTE -> "o ICE não achou caminho entre os dois aparelhos" // i18n-fora: nome do status, só no diário
            NEEDS_PIN -> "o outro lado não reconhece mais este aparelho — digite o PIN de novo" // i18n-fora: nome do status, só no diário
            CANCELLED -> "cancelado" // i18n-fora: nome do status, só no diário
            WRONG_PIN -> "o PIN não conferiu" // i18n-fora: nome do status, só no diário
            BUSY -> "ocupado — tente de novo em instantes" // i18n-fora: nome do status, só no diário
            else -> "código $codigo" // i18n-fora: nome do status, só no diário
        }
    }

    /**
     * Os bits de `changed` da bombeada do teleprompter (`QuallTeleprompterChange` de `quall.h`): o
     * que mudou **por causa do outro lado**. **Os valores são ABI** — bit novo entra no fim.
     */
    object MudouNoTeleprompter {
        const val TEXTO = 1
        const val ROLANDO = 2
        const val VELOCIDADE = 4
        const val FONTE = 8
        const val MARGEM = 16
        const val LINHA_DE_LEITURA = 32
        const val ESPELHO = 64

        /** O relato de posição do prompter. **Quem mostra o texto ignora**; o controle desenha. */
        const val POSICAO = 128

        /** Um salto novo: quem mostra o texto vai até `"salto"` e mantém `rolando` como está. */
        const val SALTO = 256

        /** Mudou o contato com o outro lado: releia `par_visto_ha_ms` e `sem_confirmacao_ha_ms`. */
        const val PAR = 512

        /** A pergunta do texto (§11.4) — a tela dela vem depois; o bit fica aqui para o espelho da ABI. */
        const val PERGUNTA_DO_TEXTO = 1024

        /** Cópia nova do roteiro: grave o salvo agora (§11.5) — idem. */
        const val COPIA_DO_TEXTO = 2048

        /**
         * "Segurar para rolar" (§12): mudou `"para_tras"` ou `"segurando"`. Quem mostra o texto relê
         * `rolando` e `para_tras`; o controle relê `segurando`.
         */
        const val SEGURAR = 4096

        /**
         * A gravação (§13). No prompter: chegou um pedido do controle (`"pedido_de_gravacao"`). No
         * controle: a gravação começou ou parou, o pedido daqui foi respondido, ou o prompter passou
         * a dizer (ou deixou de dizer) que grava (`"par_entende_gravar"`).
         */
        const val GRAVACAO = 8192
    }

    /** Os papéis no fio, literais (`docs/contrato-teleprompter.md` §2). */
    const val PAPEL_TELEPROMPTER = "teleprompter"
    const val PAPEL_CONTROLE_REMOTO = "controle_remoto"

    /**
     * Espelha `QuallTrackKind` de `quall.h`. **Os valores são ABI** — espécie nova entra no fim.
     *
     * [MICROPHONE] é o som da **câmera** (desde 24/09/2026, fase 2 do R5): todo emissor de câmera
     * põe uma track desta espécie na oferta — sempre, porque o botão do microfone pode ligar no
     * meio e não há renegociação —, e ela fica calada com o botão desligado
     * (`docs/teleprompter-com-camera.md` §4). Até ali este comentário dizia que o app nunca a usava;
     * a regra caiu para a câmera por decisão do Pessoa Exemplo, e o que fica é a da bancada: prova só com
     * tom sintético (`docs/audio.md` §8). A tela continua sem microfone ([SYSTEM_AUDIO]).
     */
    object TrackKind {
        const val SCREEN = 0
        const val CAMERA = 1
        const val MICROPHONE = 2
        const val SYSTEM_AUDIO = 3

        fun eAudio(kind: Int): Boolean = kind == MICROPHONE || kind == SYSTEM_AUDIO
    }

    /** Espelha `QuallAudioCodec` de `quall.h`. */
    object AudioCodec {
        /** Em [trackAudioCodec] isto é **"não sei"**, e não "o padrão". */
        const val DEFAULT = 0
        const val OPUS = 1
        const val PCMU = 2
    }

    /**
     * Espelha `QuallAudioOrder`: o que fazer com um slot de 20 ms. **Os valores são ABI.**
     *
     * Um DAC não aceita "pulei este aqui" — ele vai consumir 20 ms de alguma coisa, e a única
     * escolha é de qual coisa. É por isso que são exatamente três.
     */
    object AudioOrder {
        const val FRAME = 0
        const val FEC = 1
        const val SILENCE = 2
    }

    /** Bits de `QuallDeviceDesc`. */
    const val CAP_SCREEN = 1
    const val CAP_CAMERA = 2
    const val CAP_SINK = 4

    /** Porta padrão de sinalização — `DEFAULT_SIGNALING_PORT` de `quall-core/src/discovery.rs`. */
    const val PORTA_SINALIZACAO = 7877

    /**
     * `true` se `libqualljni.so` (e, por dependência, `libquall.so` e `libc++_shared.so`)
     * carregou. Falso significa APK sem a ABI deste aparelho — o modo de falha que só aparece no
     * A10s, e só em execução.
     */
    val carregado: Boolean

    val erroDeCarga: String?

    init {
        var ok = false
        var erro: String? = null
        try {
            System.loadLibrary("qualljni")
            ok = true
        } catch (e: Throwable) {
            erro = "${e.javaClass.simpleName}: ${e.message}"
        }
        carregado = ok
        erroDeCarga = erro
    }

    // --- ficha ----------------------------------------------------------------------------

    external fun protocolVersion(): Int

    private external fun serviceTypeBytes(): ByteArray
    private external fun lastErrorBytes(): ByteArray

    /**
     * `QuallStatus` da última falha **nesta thread**. Ver a doc de [lastError]: mesma regra, e a
     * mesma armadilha — chamada que deu certo não limpa o valor, então isto só significa alguma
     * coisa logo depois de uma chamada que **falhou**.
     */
    external fun lastStatus(): Int
    private external fun generatePinBytes(): ByteArray

    fun serviceType(): String = String(serviceTypeBytes(), Charsets.UTF_8)

    /** Mensagem do último erro **desta thread**. Vazia quando não houve erro. */
    fun lastError(): String = String(lastErrorBytes(), Charsets.UTF_8)

    /**
     * PIN de seis dígitos com o gerador do sistema. Vem do núcleo, e não do Kotlin, porque a
     * qualidade do sorteio é o que segura o pareamento.
     */
    fun generatePin(): String = String(generatePinBytes(), Charsets.UTF_8)

    // --- anúncio mDNS ---------------------------------------------------------------------

    private external fun advertiserStart(
        deviceId: ByteArray,
        displayName: ByteArray,
        caps: Int,
        porta: Int,
    ): Long

    /** Enquanto o handle existir, o aparelho aparece na LAN. `0` em erro. */
    fun advertiserStart(deviceId: String, displayName: String, caps: Int, porta: Int): Long =
        advertiserStart(deviceId.utf8(), displayName.utf8(), caps, porta)

    external fun advertiserStop(handle: Long)

    // --- navegação mDNS -------------------------------------------------------------------

    external fun browserStart(): Long

    /** **Bloqueia** por `ms`. Devolve quantos aparelhos há, ou negativo em erro. */
    external fun browserCollect(handle: Long, ms: Int): Int

    private external fun browserDevicesJsonBytes(handle: Long): ByteArray

    fun browserDevicesJson(handle: Long): String =
        String(browserDevicesJsonBytes(handle), Charsets.UTF_8)

    external fun browserStop(handle: Long)

    // --- cancelamento -----------------------------------------------------------------------

    /**
     * `quall_canceller_new`: cria um cancelador ainda não acionado. É o que substitui o truque da
     * conexão TCP descartável que `MirrorService.kt` usava para destravar `quall_host` — agora o
     * núcleo oferece cancelamento de verdade (dívida 10). Devolve `0` em erro.
     */
    external fun cancellerNew(): Long

    /** Libera o cancelador. `0`/handle já liberado é ignorado pelo núcleo. */
    external fun cancellerFree(handle: Long)

    /**
     * **Cancela a espera.** Pode ser chamada de qualquer thread, quantas vezes quiser. A chamada
     * bloqueante (`hostStart`) que estiver segurando este cancelador volta com `0` e
     * `QUALL_STATUS_CANCELLED` em [lastError].
     *
     * Cancelar é irreversível: para uma nova tentativa, é preciso um cancelador novo — por isso a
     * casca guarda o handle atrás de uma trava e o zera assim que a chamada de espera volta (ver
     * `MirrorService.kt`), para nunca chamar esta função com um handle que já foi liberado — regra
     * de plataforma depois do achado do Windows em `docs/divida-do-nucleo.md`.
     */
    external fun sessionCancel(handle: Long)

    // --- sessão emissora ------------------------------------------------------------------

    private external fun hostStart(
        deviceId: ByteArray,
        displayName: ByteArray,
        caps: Int,
        pin: ByteArray,
        knownPeersJson: ByteArray?,
        porta: Int,
        timeoutMs: Int,
        trackKind: Int,
        trackLabel: ByteArray,
        audioTrackKind: Int,
        audioTrackLabel: ByteArray?,
        audioCodec: Int,
        cancellerHandle: Long,
    ): Long

    /**
     * Sobe a sessão como **emissor**, com uma track de saída declarada na oferta.
     *
     * **Bloqueia** até um receptor conectar, parear e o transporte subir, até `timeoutMs`, ou até
     * [sessionCancel] ser chamado com o mesmo [cancellerHandle]. Chame de uma thread de trabalho.
     * Devolve `0` em erro — o motivo em [lastError], na mesma thread.
     *
     * A track entra aqui, e não depois, porque ela faz parte da oferta SDP: o que não está na
     * oferta só entra com renegociação, que o Quall não implementa.
     *
     * `cancellerHandle` é `0` por padrão, que o núcleo trata como "sem cancelador" — chamada
     * idêntica a `quall_host` sem cancelamento algum.
     *
     * `audioTrackKind` negativo é "sem áudio", e é exatamente o comportamento que existia antes
     * desta rodada. Com áudio, a oferta leva **duas** tracks, e pelo mesmo motivo de a primeira
     * entrar aqui: o que não está na oferta só entra com renegociação.
     */
    fun hostStart(
        deviceId: String,
        displayName: String,
        caps: Int,
        pin: String,
        knownPeersJson: String?,
        porta: Int,
        timeoutMs: Int,
        trackKind: Int,
        trackLabel: String,
        audioTrackKind: Int = -1,
        audioTrackLabel: String = "",
        audioCodec: Int = AudioCodec.DEFAULT,
        cancellerHandle: Long = 0L,
    ): Long = hostStart(
        deviceId.utf8(),
        displayName.utf8(),
        caps,
        pin.utf8(),
        knownPeersJson?.utf8(),
        porta,
        timeoutMs,
        trackKind,
        trackLabel.utf8(),
        audioTrackKind,
        if (audioTrackKind >= 0) audioTrackLabel.utf8() else null,
        audioCodec,
        cancellerHandle,
    )

    // --- sessão receptora -----------------------------------------------------------------

    private external fun connectStart(
        endpoint: ByteArray,
        deviceId: ByteArray,
        displayName: ByteArray,
        caps: Int,
        pin: ByteArray?,
        knownPeersJson: ByteArray?,
        timeoutMs: Int,
        cancellerHandle: Long,
        bindAddress: ByteArray?,
        screenWidthPx: Int,
        screenHeightPx: Int,
    ): Long

    /**
     * Sobe a sessão como **receptor**: conecta no `endpoint`, pareia e responde.
     *
     * `endpoint` é `"192.168.56.131:7877"` ou só `"192.168.56.131"` (a porta padrão entra sozinha).
     * É a **mesma** função para o endereço que veio do mDNS e para o que o usuário digitou — o
     * header diz que isso é de propósito, e o A10s é a prova de por quê: lá o mDNS do núcleo não
     * funciona dentro do app (`docs/divida-do-nucleo.md`, item 9) e o caminho digitado é o único.
     *
     * `pin` nulo é válido e significa "o par já é conhecido, retome". Quando o outro lado não
     * reconhece mais este aparelho, a chamada falha com [Status.NEEDS_PIN] — que **não é recusa**,
     * é convite a pedir o PIN de novo (dívida 22).
     *
     * **Bloqueia**; devolve `0` em erro, com o motivo em [lastError] na mesma thread.
     *
     * Não recebe tracks a declarar: `QuallSessionOptions::tracks` "só vale em `quall_host`". Quem
     * conecta **recebe** tracks, por [sessionNextTrack].
     */
    fun connectStart(
        endpoint: String,
        deviceId: String,
        displayName: String,
        caps: Int,
        pin: String?,
        knownPeersJson: String?,
        timeoutMs: Int,
        cancellerHandle: Long = 0L,
        bindAddress: String? = null,
        /**
         * Os pixels do painel deste aparelho, que vão no aperto de mão (`quall_connect_with_screen`).
         * `0` é "não digo". A tela estendida do Mac usa isso para o formato do monitor.
         */
        telaLarguraPx: Int = 0,
        telaAlturaPx: Int = 0,
    ): Long = connectStart(
        endpoint.utf8(),
        deviceId.utf8(),
        displayName.utf8(),
        caps,
        pin?.utf8(),
        knownPeersJson?.utf8(),
        timeoutMs,
        cancellerHandle,
        bindAddress?.utf8(),
        telaLarguraPx,
        telaAlturaPx,
    )

    /**
     * Próxima track que chegou **do outro lado**, esperando até `timeoutMs`. `0` quando nada
     * chegou a tempo — estado normal, não erro. O handle é do chamador: libere com [trackFree].
     *
     * Esta e [sessionNextEvent] **avançam estado** e, pelo header, precisam ser chamadas de uma
     * thread só. Quem garante isso aqui é `ReceptorSessao`, que roda as duas no mesmo laço.
     */
    external fun sessionNextTrack(sessao: Long, timeoutMs: Int): Long

    /** Espelha `QuallSessionEvent`. */
    object SessionEvent {
        const val NONE = 0
        const val DISCONNECTED = 1
        const val FAILED = 2
    }

    /**
     * O detector de queda. Sem ele, o único sinal de sessão morta é o envio voltar a falhar — e
     * o `CONSENT_TIMEOUT` do libjuice é de 30 s. Chame do mesmo laço, com prazo pequeno.
     */
    external fun sessionNextEvent(sessao: Long, timeoutMs: Int): Int

    // ---------------------------------------------------------------------------------------

    external fun sessionSignalingPort(sessao: Long): Int
    external fun sessionPairingIsNew(sessao: Long): Boolean
    external fun sessionTrackCount(sessao: Long): Int
    external fun sessionTrack(sessao: Long, idx: Int): Long

    /**
     * Fecha a sessão e **espera os tratadores da casca saírem**. Devolve um código de [Status].
     *
     * Desde 2026-08-26 isto **é barreira** (dívida 24): com [Status.OK], nenhum tratador desta
     * sessão está rodando e nenhum voltará a rodar — e só então o `user_data` (aqui, a caixa de
     * quadros de [frameBoxNew]) pode ser liberado. Qualquer outro status quer dizer **não libere
     * nada**: a sessão foi fechada de qualquer jeito, o que falhou foi a promessa sobre os
     * tratadores.
     *
     * Libere as tracks **antes**, e nunca chame de dentro de um tratador.
     */
    external fun sessionClose(sessao: Long): Int

    private external fun sessionPeerJsonBytes(sessao: Long): ByteArray
    private external fun sessionKnownPeersJsonBytes(sessao: Long, knownJson: ByteArray?): ByteArray

    fun sessionPeerJson(sessao: Long): String =
        String(sessionPeerJsonBytes(sessao), Charsets.UTF_8)

    /**
     * O estado de pareamento atualizado, para a casca **persistir**. Sem gravar isto, o usuário
     * digita o PIN de novo na próxima sessão.
     */
    fun sessionKnownPeersJson(sessao: Long, knownJson: String?): String =
        String(sessionKnownPeersJsonBytes(sessao, knownJson?.utf8()), Charsets.UTF_8)

    // --- track ----------------------------------------------------------------------------

    /**
     * `enviar_quadro` do contrato. Empacota e solta um quadro; devolve um código de [Status].
     *
     * `buffer` precisa ser **direto** (`ByteBuffer.allocateDirect`, ou o buffer de saída do
     * `MediaCodec`, que é direto). `deslocamento` é explícito porque `GetDirectBufferAddress`
     * devolve a base do buffer e ignora `position()` — e o `BufferInfo.offset` do encoder OMX
     * legado do Galaxy A10s não é zero.
     *
     * Erro aqui é a track ainda não estar aberta ou o transporte ter caído. Nos dois casos a
     * casca **descarta o quadro e segue**: enfileirar para tentar de novo é exatamente o que não
     * se faz com vídeo ao vivo.
     */
    external fun trackSendFrame(
        track: Long,
        buffer: ByteBuffer,
        deslocamento: Int,
        tamanho: Int,
        timestampUs: Long,
        idr: Boolean,
    ): Int

    /**
     * `pegar_pedido_de_idr` do contrato: **consome** um pedido de IDR pendente (PLI/FIR do
     * receptor) e baixa a bandeira. `true` no máximo uma vez por rajada.
     */
    external fun trackTakeIdrRequest(track: Long): Boolean

    /** `QuallTrackKind` desta track, ou `-1` para handle nulo. Ver [TrackKind]. */
    external fun trackKind(track: Long): Int

    /**
     * `pedir_idr` do contrato: emite PLI. O receptor chama **ao entrar na sessão**, antes de ter
     * visto qualquer IDR — sem isso o primeiro quadro perdido (que se perde em cerca de metade
     * das corridas, `docs/divida-do-nucleo.md`, item 25) deixaria a tela preta até o próximo IDR
     * natural do emissor.
     *
     * Devolve erro enquanto a track não abriu, o que é estado normal por alguns milissegundos —
     * insistir por um instante é o comportamento certo, engolir em silêncio não é.
     */
    external fun trackRequestIdr(track: Long): Int

    external fun trackFree(track: Long)

    // --- caixa de quadros (recepção) --------------------------------------------------------

    /**
     * Cria a caixa de quadros: o anel em C que recebe os quadros remontados do núcleo sem que
     * nenhuma thread da libdatachannel precise ser anexada à JVM (ver a doc desta classe e o
     * comentário em `quall_jni.c`). `0` em erro.
     *
     * **Ela é o `user_data` do tratador.** Só pode ser liberada com [frameBoxFree] depois de
     * [trackOnFrame] com `caixa = 0` **ou** [sessionClose] terem devolvido [Status.OK] — a
     * barreira da fronteira C. Com qualquer outro status, a regra é não liberar: vazar alguns
     * KiB é preferível a um tratador escrevendo em memória liberada.
     */
    external fun frameBoxNew(): Long

    external fun frameBoxFree(caixa: Long)

    /**
     * Copia o quadro mais antigo da caixa **direto para o `ByteBuffer` de entrada do
     * `MediaCodec`** e devolve o tamanho; `-1` quando nada chegou no prazo (normal), `-2` quando
     * o quadro não coube no destino (descartado — `meta[0]` e `meta[1]` dizem qual era), `-3` para
     * argumento inválido.
     *
     * `meta` precisa ter pelo menos 6 posições e volta com
     * `[timestamp_us, idr, recebidos, descartados, grandes_demais, nao_couberam]`.
     */
    external fun frameBoxTake(caixa: Long, destino: ByteBuffer, meta: LongArray, timeoutMs: Int): Int

    /**
     * Liga (`caixa != 0`) ou desliga (`caixa == 0`) o tratador de quadro desta track. Devolve um
     * código de [Status]; no desligamento, [Status.OK] é a barreira que autoriza [frameBoxFree].
     */
    external fun trackOnFrame(track: Long, caixa: Long): Int

    /**
     * **Quantos quadros o depacotizador jogou fora por estarem incompletos.** `0` para track nula
     * ou de emissão — e `0` não é erro.
     *
     * Cada unidade é uma **ruptura da cadeia de referência**: daí até o IDR seguinte, todo quadro
     * P decodifica sem erro nenhum e sai visualmente podre, porque a referência dele não existe.
     *
     * Existe separado de [trackStatsJson] porque é lido **no laço de recepção, uma vez por
     * quadro**. Ler o mesmo número pelo JSON custa um alocador e um parser por leitura, e foi por
     * causa desse preço que esta casca perguntava a cada 100 ms — três quadros a 30 fps — em vez
     * de a cada quadro. O header do núcleo já avisava: *"uma casca que ache isso caro vai acabar
     * não perguntando"*.
     *
     * **Não pode ser chamada de dentro de um tratador de quadro.** Ela pega o cadeado do
     * depacotizador, e o núcleo despacha o tratador com esse mesmo cadeado na mão. Aqui a casca
     * não corre esse risco — o tratador é em C e só copia para a caixa —, mas quem for portar isto
     * para uma casca de callback precisa saber.
     */
    external fun trackFramesDropped(track: Long): Long

    // --- a taxa que escuta ------------------------------------------------------------------
    //
    // O caminho de volta do sinal e a política de taxa. A política **não** está aqui: ela é
    // `quall_core::taxa`, no núcleo, porque esta casca não tem suíte de testes e um laço de
    // realimentação sem teste determinístico é a coisa mais cara que se pode pôr no caminho
    // quente — o modo de falha dele é oscilar, e oscilação só aparece com o rádio na frente.

    /**
     * **Receptor:** conta ao emissor o que esta janela viu do enlace. Ver `RelatoDoEnlace` no
     * núcleo para por que o carimbo é a sinalização e não RTCP, e o que a escolha custa.
     *
     * `pacotes` é o que o **emissor mandou** na janela (`packets_seen + packets_lost_for_real`),
     * nunca o que chegou: o denominador de uma taxa de perda vem do emissor, e dividir pelo que
     * chegou já inverteu a conclusão de uma frente inteira desta bancada em 31/08/2026.
     *
     * Chame da **mesma thread** que chama [sessionNextEvent]. Devolve [Status]; falhar não é
     * motivo para o receptor parar nada — um emissor de versão antiga ignora a mensagem sozinho.
     */
    external fun sessionReportLink(
        sessao: Long,
        ms: Long,
        pacotes: Long,
        perdidos: Long,
        suspeitos: Long,
        idrsQuebrados: Long,
        /** Quadros que **esta casca** não conseguiu entregar na janela. Ver `rateSample`. */
        naoEntregues: Long,
    ): Int

    /**
     * **Emissor:** consome o relato mais recente do receptor, ou devolve `false`.
     *
     * `saida` é um `LongArray(5)` **reaproveitado** — `{ms, pacotes, perdidos, suspeitos,
     * idrs_quebrados}`. Alocar por janela seria lixo por janela num aparelho de 1,79 GB.
     *
     * `false` é a resposta na maioria das chamadas, e é a resposta **sempre** quando o outro lado
     * é uma versão que não relata. Um emissor novo com um receptor velho fica com o bitrate fixo,
     * que é exatamente o comportamento de hoje.
     */
    external fun sessionTakeLinkReport(sessao: Long, prazoMs: Int, saida: LongArray): Boolean

    /**
     * Cria o controlador de taxa. `tetoBps` **tem de ser** o bitrate que o produto usaria sem ele.
     *
     * O controlador nasce no teto e nunca passa dele: só sabe tirar e devolver o que tirou. É
     * isso que faz o braço de aferição negativo passar por construção — num enlace de 5 GHz, onde
     * esta bancada mediu 0 perda em 9 003 pacotes, ele não tem o que fazer e a sessão é byte a
     * byte a mesma que sem ele.
     */
    /**
     * **Quantos bits por segundo pedir ao encoder para esta geometria** — `quall_teto_ajustar`.
     *
     * A casca não recalcula a regra: pergunta, que é a mesma disciplina do teto de resolução.
     * Até 02/09/2026 este número era literal aqui e em mais quatro cascas (`4_000_000` para tela,
     * `6_000_000` para câmera), e quando o teto de resolução subiu para 1080p em 01/09 nenhum
     * deles subiu junto — 2,25 vezes os pixels pelo mesmo orçamento de bits.
     *
     * 720p30 devolve exatamente 4 000 000, que é o valor de produto de sempre; 1080p30 devolve
     * 9 000 000. Devolve `0` se a fronteira recusar.
     */
    external fun tetoDeTaxaBps(largura: Int, altura: Int, fps: Int, alvoMaxFs: Int = 0): Int

    /**
     * **Que geometria codificar** — o outro metade do mesmo `quall_teto_ajustar`.
     *
     * Devolve largura nos 32 bits altos e altura nos baixos; `0` é recusa da fronteira. Use
     * [tetoDeResolucaoPar], que desempacota.
     */
    external fun tetoDeResolucao(largura: Int, altura: Int, fps: Int, alvoMaxFs: Int): Long

    /**
     * A geometria que o teto permite, ou `null` se a fronteira recusar.
     *
     * **A casca perguntava só metade, e isso custou uma medida de campo.** [tetoDeTaxaBps] já
     * chamava `quall_teto_ajustar` e descartava a geometria, então o caminho de tela entregava ao
     * encoder o tamanho cru do aparelho. Em 07/09/2026 o S24 espelhou a tela em **1440x3120** —
     * 17.550 macroblocos por quadro contra os 8192 do `MaxFS` do nível 4.0 que o nosso SDP
     * anuncia, 2,14x acima —, e o receptor decodificou sem reclamar porque o VideoToolbox do
     * macOS é tolerante. Um receptor que respeitasse o nível anunciado teria recusado, e a culpa
     * teria parecido dele.
     *
     * `null` **não** significa "use o que você tem": significa que não há resposta, e quem chama
     * tem de decidir explicitamente. Cair para a entrada em silêncio é o defeito de origem.
     */
    fun tetoDeResolucaoPar(largura: Int, altura: Int, fps: Int, alvoMaxFs: Int = 0): Pair<Int, Int>? {
        val v = tetoDeResolucao(largura, altura, fps, alvoMaxFs)
        if (v == 0L) return null
        return ((v ushr 32).toInt()) to (v and 0xFFFF_FFFFL).toInt()
    }

    /**
     * **Bancada: crava a profundidade do anel de reordenação**, em pacotes, e desliga o ajuste
     * automático. `0` desliga a fila inteira.
     *
     * Existe para o **braço de controle**. O anel passou a se ajustar sozinho em 02/09/2026, e a
     * primeira corrida de Wi-Fi levantou uma dúvida contra o próprio ajuste — mas contra uma
     * corrida de outro dia, e duas corridas de 2,4 GHz separadas no tempo não se comparam. Sem
     * este botão a acusação fica sendo anedota.
     *
     * Nenhum caminho de produto chama isto: `Bancada.profundidadeDoAnel` é `0` por padrão.
     */
    external fun trackSetReorderDepth(track: Long, pacotes: Int): Boolean

    external fun rateNew(tetoBps: Int): Long

    /**
     * Alimenta uma janela. Devolve [RateReason]; escreve o bitrate novo em `saida[0]` **só** com
     * [RateReason.DOWN] ou [RateReason.UP].
     */
    external fun rateSample(
        controle: Long,
        ms: Long,
        pacotes: Long,
        perdidos: Long,
        suspeitos: Long,
        idrsQuebrados: Long,
        /**
         * Quadros que o **receptor** recebeu inteiros e não conseguiu entregar na janela. Três ou
         * mais fazem o alvo descer, mesmo com perda de rede zero — ver `docs/bancada.md` §8.63,
         * onde o emissor **subia** enquanto o outro lado descartava 17 quadros por segundo.
         */
        naoEntregues: Long,
        saida: IntArray,
    ): Int

    external fun rateCurrentBps(controle: Long): Int

    /**
     * O controlador chegou ao piso e a perda continua alta?
     *
     * É a única condição em que a resposta certa é para o **usuário** e não para o encoder:
     * abaixo do piso a imagem não vale a pena, e dizer isso é melhor que entregar lodo.
     */
    external fun rateAtFloor(controle: Long): Boolean

    /** `{janelas, descidas, subidas}` num `LongArray(3)` reaproveitado. Para o relato. */
    external fun rateCounters(controle: Long, saida: LongArray)

    external fun rateFree(controle: Long)

    /** Espelha `QuallRateReason` do header. */
    object RateReason {
        /** Janela ignorada: carência depois de uma mudança, ou pacotes de menos. */
        const val SKIPPED = 0
        const val DOWN = 1
        /** Queria descer e já está no piso. O enlace não dá para este vídeo. */
        const val FLOOR = 2
        const val UP = 3
        /** Queria subir e já está no teto. **É o estado permanente num enlace limpo.** */
        const val CEILING = 4
        const val HOLD = 5

        fun nome(v: Int): String = when (v) {
            SKIPPED -> "ignorada"
            DOWN -> "desceu"
            FLOOR -> "no_piso"
            UP -> "subiu"
            CEILING -> "no_teto"
            else -> "segurou"
        }
    }

    // --- áudio ------------------------------------------------------------------------------

    /**
     * `QuallAudioCodec` que **esta track de áudio negociou**, lido do `a=rtpmap`.
     *
     * [AudioCodec.DEFAULT] (`0`) aqui é **"não sei"**, e não "o padrão": track nula, de emissão,
     * de vídeo, ou de áudio que ainda não adotou codec. Ler o zero como "então é Opus"
     * decodificaria G.711 com o relógio numa escala 6× errada — sai som, e todo alinhamento com
     * o vídeo fica errado, sem erro em lugar nenhum. O motivo sai em [lastError].
     */
    external fun trackAudioCodec(track: Long): Int

    private external fun audioPresetJsonBytes(kind: Int, codec: Int): ByteArray

    /**
     * O preset que o núcleo anuncia no SDP para esta espécie e codec, em JSON.
     *
     * Chaves: `codec`, `sample_rate_hz`, `channels`, `frame_ms`, `frame_samples` (**por canal**),
     * `bitrate_bps`, `fec`, `expected_loss_pct`, `is_speech`, `payload_type`, `fmtp`.
     *
     * A casca **pergunta** em vez de fixar os números: preset do fio e preset da captura fixados
     * em dois lugares divergem em silêncio, que é a classe de defeito da §11 de `docs/audio.md`.
     */
    fun audioPresetJson(kind: Int, codec: Int = AudioCodec.DEFAULT): String =
        String(audioPresetJsonBytes(kind, codec), Charsets.UTF_8)

    /**
     * Cria a caixa de slots de áudio: o anel em C que recebe os slots de 20 ms já ordenados pelo
     * jitter buffer do núcleo, sem anexar thread nenhuma da libdatachannel à JVM. `0` em erro.
     *
     * Mesma disciplina de tempo de vida da caixa de quadros: ela é o `user_data`, e só pode ser
     * liberada com [audioBoxFree] depois de [trackOnAudio] com `caixa = 0` **ou** [sessionClose]
     * terem devolvido [Status.OK].
     */
    external fun audioBoxNew(): Long

    external fun audioBoxFree(caixa: Long)

    /**
     * Tira o slot mais antigo. Devolve o tamanho do payload em bytes — **e `0` é resposta
     * válida**: é a ordem [AudioOrder.SILENCE], que pede ocultação de perda. `-1` é "nada chegou
     * no prazo" (normal), `-2` "não coube", `-3` argumento inválido.
     *
     * `meta` precisa ter pelo menos 6 posições e volta com
     * `[order, sequence, timestamp_us, fec_has_lbrr, recebidos, descartados]`.
     */
    external fun audioBoxTake(caixa: Long, destino: ByteBuffer, meta: LongArray, timeoutMs: Int): Int

    /**
     * Liga (`caixa != 0`) ou desliga (`caixa == 0`) o tratador de áudio desta track.
     *
     * **Desligar escoa o buffer antes de voltar**, chamando o tratador da thread de quem chamou.
     * Quem desliga deve drenar a caixa depois de [Status.OK] e antes de [audioBoxFree]: são os
     * últimos ~40 ms da sessão, que atravessaram a rede e nunca tocariam.
     */
    external fun trackOnAudio(track: Long, caixa: Long): Int

    /**
     * `quall_audio_decoder_new`: decodificador de Opus configurado pelo preset da espécie. `0` em
     * erro, com o motivo em [lastError].
     *
     * **Não é o `MediaCodec`, e a diferença é a ordem [AudioOrder.FEC].** O decodificador do
     * Android não expõe `decode_fec` nem ocultação de perda explícita; com ele, o socorro que o
     * jitter buffer entrega atravessaria a rede para ser jogado fora.
     *
     * Devolve `0` para PCMU de propósito: G.711 µ-law é uma tabela de consulta de 8 bits, e ela
     * mora na casca ([UlawG711]).
     */
    external fun audioDecoderNew(kind: Int, codec: Int): Long

    /**
     * Decodifica um slot em PCM intercalado de 16 bits. Devolve amostras **por canal**, ou `-1`.
     *
     * `entrada` nula (ou `tamanho` 0) é [AudioOrder.SILENCE] e vira ocultação de perda.
     *
     * **`fec = true` só depois de conferir `fec_has_lbrr == 1`.** Sem LBRR, o `opus_decode` com
     * `decode_fec` cai na ocultação de perda **em silêncio** e devolve sucesso — quem não
     * conferir conta como "curado por FEC" um quadro que o decoder inventou.
     */
    external fun audioDecoderDecode(
        decoder: Long,
        entrada: ByteBuffer?,
        deslocamento: Int,
        tamanho: Int,
        fec: Boolean,
        saida: ShortArray,
    ): Int

    external fun audioDecoderFree(decoder: Long)

    /**
     * `quall_audio_encoder_new`: encoder de Opus **já configurado pelo preset da espécie** — taxa
     * de bits, canais, FEC, perda esperada e sinal. `0` em erro.
     *
     * Configurar na casca é a classe de defeito da §11 de `docs/audio.md`: sem
     * `OPUS_SET_PACKET_LOSS_PERC`, o `useinbandfec=1` do SDP produz um fluxo sem LBRR nenhum, e
     * o outro lado dimensiona o buffer contando com uma recuperação que nunca vem.
     */
    external fun audioEncoderNew(kind: Int, codec: Int): Long

    /**
     * Codifica um quadro de PCM intercalado em `saida` (um `ByteBuffer` **direto**, o mesmo que
     * vai para [trackSendAudio]). `amostras` é `frame_samples × channels` do preset. Devolve
     * bytes escritos, ou `-1`.
     */
    external fun audioEncoderEncode(
        encoder: Long,
        pcm: ShortArray,
        amostras: Int,
        saida: ByteBuffer,
    ): Int

    external fun audioEncoderFree(encoder: Long)

    /**
     * `enviar_audio` do contrato: **um** quadro codificado por chamada.
     *
     * O pacotizador da libdatachannel não fragmenta — uma mensagem entra, um pacote RTP sai. Dois
     * quadros de Opus numa chamada viram um pacote que o outro lado decodifica errado, **sem erro
     * nenhum no caminho**, porque para o RTP é só um payload maior.
     */
    external fun trackSendAudio(
        track: Long,
        buffer: ByteBuffer,
        deslocamento: Int,
        tamanho: Int,
        timestampUs: Long,
    ): Int

    // ---------------------------------------------------------------------------------------

    private external fun sessionPathJsonBytes(sessao: Long): ByteArray

    /**
     * **Por onde a mídia está indo**: o par de candidatos ICE escolhido, como JSON
     * (`local_candidate`, `remote_candidate`, `local_address`, `remote_address`; todos podem vir
     * `null` enquanto o ICE não fecha).
     *
     * Existe porque **uma corrida "pelo cabo" pode fechar pela Wi-Fi e parecer sucesso**. Foi o
     * que aconteceu em 01/09/2026 e o braço foi anulado; em 02/09 o braço do cabo ia ser rodado
     * de novo sem nenhuma testemunha do caminho. Um braço que não diz por onde a mídia saiu não é
     * um braço de cabo, é uma esperança.
     */
    fun sessionPathJson(sessao: Long): String =
        String(sessionPathJsonBytes(sessao), Charsets.UTF_8)

    private external fun trackStatsJsonBytes(track: Long): ByteArray
    private external fun trackLabelBytes(track: Long): ByteArray

    /**
     * Contadores da track. No emissor: `frames_sent`, `idrs_sent`, `idrs_without_parameters`,
     * `idr_requests`, `buffered_bytes`.
     *
     * `idrs_without_parameters` diferente de zero é **defeito desta casca**: o contrato manda
     * todo IDR levar SPS e PPS.
     */
    fun trackStatsJson(track: Long): String =
        String(trackStatsJsonBytes(track), Charsets.UTF_8)

    fun trackLabel(track: Long): String = String(trackLabelBytes(track), Charsets.UTF_8)

    // --- teleprompter (F6b) -------------------------------------------------------------------
    //
    // `docs/contrato-teleprompter.md` §6 e §7. Os nomes do C são os do header; aqui só se traduz.
    // Quem decide o que fazer com cada status e cada bit é `teleprompter/` — nunca esta camada.

    private external fun advertiserStartWithRole(
        deviceId: ByteArray,
        displayName: ByteArray,
        caps: Int,
        porta: Int,
        role: ByteArray?,
    ): Long

    /** `quall_advertiser_start_with_role`: o TXT ganha `pa`, e o nome da instância o papel. */
    fun advertiserStartWithRole(deviceId: String, displayName: String, caps: Int, porta: Int, papel: String): Long =
        advertiserStartWithRole(deviceId.utf8(), displayName.utf8(), caps, porta, papel.utf8())

    private external fun hostWithRole(
        deviceId: ByteArray,
        displayName: ByteArray,
        caps: Int,
        pin: ByteArray,
        knownPeersJson: ByteArray?,
        porta: Int,
        timeoutMs: Int,
        cancellerHandle: Long,
        role: ByteArray?,
    ): Long

    /**
     * `quall_host_with_role`: **bloqueia** até um controle entrar, o prazo estourar ou o
     * cancelador acionar. `0` em erro, com o motivo em [lastStatus]/[lastError] **nesta** thread.
     * Sem track nenhuma — um teleprompter não emite.
     */
    fun hostWithRole(
        deviceId: String,
        displayName: String,
        caps: Int,
        pin: String,
        knownPeersJson: String?,
        porta: Int,
        timeoutMs: Int,
        cancellerHandle: Long,
        papel: String,
    ): Long = hostWithRole(
        deviceId.utf8(), displayName.utf8(), caps, pin.utf8(), knownPeersJson?.utf8(),
        porta, timeoutMs, cancellerHandle, papel.utf8(),
    )

    private external fun connectWithRole(
        endpoint: ByteArray,
        deviceId: ByteArray,
        displayName: ByteArray,
        caps: Int,
        pin: ByteArray?,
        knownPeersJson: ByteArray?,
        timeoutMs: Int,
        cancellerHandle: Long,
        bindAddress: ByteArray?,
        role: ByteArray?,
    ): Long

    /**
     * `quall_connect_with_role`: **bloqueia**. Diante de um prompter que já tem controle,
     * [Status.BUSY]; diante de um aparelho que não é teleprompter, [Status.PROTOCOL].
     */
    fun connectWithRole(
        endpoint: String,
        deviceId: String,
        displayName: String,
        caps: Int,
        pin: String?,
        knownPeersJson: String?,
        timeoutMs: Int,
        cancellerHandle: Long,
        bindAddress: String?,
        papel: String,
    ): Long = connectWithRole(
        endpoint.utf8(), deviceId.utf8(), displayName.utf8(), caps, pin?.utf8(),
        knownPeersJson?.utf8(), timeoutMs, cancellerHandle, bindAddress?.utf8(), papel.utf8(),
    )

    /** O teto de uma mensagem (262 144 bytes). */
    external fun messageMaxBytes(): Long

    /** O handle das mensagens da sessão. É do chamador: [messagesFree]. Sobrevive a [sessionClose]. */
    external fun sessionMessages(sessao: Long): Long

    private external fun messagesSend(handle: Long, mensagem: ByteArray): Int

    /** Qualquer thread, não bloqueia. [Status.TRANSPORT] antes de o canal abrir é "tente de novo". */
    fun messagesSend(handle: Long, mensagem: String): Int = messagesSend(handle, mensagem.utf8())

    private external fun messagesNextBytes(handle: Long, timeoutMs: Int, estado: IntArray): ByteArray?

    /**
     * A próxima mensagem, ou `null`. `estado[0]`: `1` mensagem, `0` nada no prazo, negativo o
     * `QuallStatus` com sinal trocado. **Numa sessão de teleprompter quem lê é a bombeada**: esta
     * função fica para quem usar o canal fora dele.
     */
    fun messagesNext(handle: Long, timeoutMs: Int, estado: IntArray): String? =
        messagesNextBytes(handle, timeoutMs, estado)?.let { String(it, Charsets.UTF_8) }

    private external fun messagesStatsJsonBytes(handle: Long): ByteArray

    fun messagesStatsJson(handle: Long): String = String(messagesStatsJsonBytes(handle), Charsets.UTF_8)

    external fun messagesFree(handle: Long)

    /** O teto do roteiro, em bytes de UTF-8 (131 072). */
    external fun teleprompterMaxTextBytes(): Long

    private external fun teleprompterNew(authorId: ByteArray, role: ByteArray, savedJson: ByteArray?): Long

    /**
     * `quall_teleprompter_new`. `0` em erro; com `savedJson` ilegível ou de outra versão o status é
     * [Status.INVALID], e quem chama tenta de novo com `null` (o padrão).
     */
    fun teleprompterNew(authorId: String, papel: String, savedJson: String?): Long =
        teleprompterNew(authorId.utf8(), papel.utf8(), savedJson?.utf8())

    external fun teleprompterFree(t: Long)

    private external fun teleprompterSetText(t: Long, texto: ByteArray): Int

    /** Ao **confirmar** a edição, nunca a cada tecla. Acima do teto: [Status.INVALID]. */
    fun teleprompterSetText(t: Long, texto: String): Int = teleprompterSetText(t, texto.utf8())

    external fun teleprompterSetScrolling(t: Long, rolando: Boolean): Int

    /**
     * "Segurar para rolar" (§12.7). **Só a tela do prompter que rola para trás e para quando
     * `rolando` cai** chama [teleprompterEnableHold], ao abrir: o estado dela passa a dizer que entende.
     */
    external fun teleprompterEnableHold(t: Long): Int

    /** O controle, ao encostar o dedo: `rolando`, `para_tras` e `segurando` numa mensagem. [Status.PROTOCOL] se o prompter não entende. */
    external fun teleprompterHold(t: Long, backwards: Boolean): Int

    /** O controle, ao tirar o dedo: para. Sem nada seguro, não faz nada. */
    external fun teleprompterRelease(t: Long): Int

    /**
     * A gravação (§13). **Só a tela do prompter que grava** (a do teleprompter com câmera) liga ao
     * abrir e desliga ao fechar: o estado dela passa a dizer `"entende_gravar": true`.
     */
    external fun teleprompterEnableRecording(t: Long, enabled: Boolean): Int

    /**
     * **Só o prompter**: o arquivo começou (`true`) ou fechou (`false`). Aceitar um pedido do controle
     * é chamar isto com o `gravar` dele, mesmo que já esteja assim. [Status.INVALID] no controle.
     */
    external fun teleprompterSetRecording(t: Long, recording: Boolean): Int

    private external fun teleprompterRefuseRecording(t: Long, n: Long, reason: ByteArray): Int

    /**
     * **Só o prompter**: recusa o pedido aberto `n` (o `"n"` de `"pedido_de_gravacao"` que a tela leu)
     * com um motivo legível (1 a 256 bytes de UTF-8). [Status.BUSY]: outro pedido o substituiu — releia
     * e decida o novo. [Status.INVALID] sem pedido aberto, com motivo vazio, longo demais ou com NUL.
     */
    fun teleprompterRefuseRecording(t: Long, n: Long, reason: String): Int =
        teleprompterRefuseRecording(t, n, reason.utf8())

    /** **O controle pede que grave.** [Status.PROTOCOL]: o prompter não diz que grava; [Status.CLOSED]: sem sessão. */
    external fun teleprompterRequestRecord(t: Long): Int

    /** **O controle pede que pare.** As mesmas regras de [teleprompterRequestRecord]. */
    external fun teleprompterRequestStop(t: Long): Int

    /**
     * A trava da pergunta do texto (§11.10). **Só a réplica do controle** a liga, logo depois de
     * criada e com a tela da pergunta de pé (`ControleActivity`); a do prompter, não. Não vai no
     * salvo: liga-se a cada vida.
     */
    external fun teleprompterEnableTextQuestion(t: Long): Int

    private external fun teleprompterResolveText(t: Long, keepMine: Boolean, seenDigest: ByteArray): Int

    /**
     * A escolha da pergunta (§11.4): `keepMine` falso é "usar o do prompter". `seenDigest` é o
     * `"resumo"` de `"do_prompter"` **que a tela mostrou** — nunca um relido na hora do toque.
     * [Status.BUSY]: a pergunta mudou; [Status.CLOSED]: sem o prompter; [Status.INVALID]: sem pergunta.
     */
    fun teleprompterResolveText(t: Long, keepMine: Boolean, seenDigest: String): Int =
        teleprompterResolveText(t, keepMine, seenDigest.utf8())

    private external fun teleprompterQuestionTextBytes(t: Long): ByteArray?

    /** O texto **do prompter** na pergunta aberta; `null` sem pergunta aberta. O daqui é [teleprompterText]. */
    fun teleprompterQuestionText(t: Long): String? =
        teleprompterQuestionTextBytes(t)?.let { String(it, Charsets.UTF_8) }

    private external fun teleprompterTextCopyBytes(t: Long, digest: ByteArray): ByteArray?

    /** O texto inteiro de uma cópia, pelo `"resumo"` dela; `null` se ela não está mais na lista. */
    fun teleprompterTextCopy(t: Long, digest: String): String? =
        teleprompterTextCopyBytes(t, digest.utf8())?.let { String(it, Charsets.UTF_8) }

    private external fun teleprompterForgetTextCopy(t: Long, digest: ByteArray): Int

    /** Apaga uma cópia pelo `"resumo"`; [Status.INVALID] se ela não está na lista. */
    fun teleprompterForgetTextCopy(t: Long, digest: String): Int = teleprompterForgetTextCopy(t, digest.utf8())

    external fun teleprompterSetSpeed(t: Long, linhasPorSegundo: Double): Int
    external fun teleprompterSetFontSize(t: Long, pontos: Double): Int
    external fun teleprompterSetMargin(t: Long, fracao: Double): Int
    external fun teleprompterSetReadingLine(t: Long, fracao: Double): Int
    external fun teleprompterSetMirror(t: Long, espelho: Boolean): Int

    /** **Só o prompter.** Pode ser chamada a cada quadro; o núcleo limita o envio a 4 Hz. */
    external fun teleprompterSetPosition(t: Long, fracao: Double): Int
    external fun teleprompterJump(t: Long, fracao: Double): Int
    external fun teleprompterJumpBy(t: Long, delta: Double): Int

    /**
     * A bombeada. Devolve o status e escreve os bits de [MudouNoTeleprompter] em `mudou[0]` —
     * **também com [Status.CLOSED]**, que vem com a última mensagem do outro lado já fundida.
     */
    external fun teleprompterPump(t: Long, mensagens: Long, timeoutMs: Int, mudou: IntArray): Int

    /** A regra de queda; `mudou[0]` sempre traz [MudouNoTeleprompter.PAR]. */
    external fun teleprompterPeerLost(t: Long, mudou: IntArray): Int

    private external fun teleprompterStateJsonBytes(t: Long): ByteArray
    /** `null` em falha — diferente de `""`, que é um roteiro vazio. */
    private external fun teleprompterTextBytes(t: Long): ByteArray?
    private external fun teleprompterSavedJsonBytes(t: Long): ByteArray

    fun teleprompterStateJson(t: Long): String = String(teleprompterStateJsonBytes(t), Charsets.UTF_8)
    fun teleprompterText(t: Long): String? = teleprompterTextBytes(t)?.let { String(it, Charsets.UTF_8) }
    fun teleprompterSavedJson(t: Long): String = String(teleprompterSavedJsonBytes(t), Charsets.UTF_8)

    // --- o controle remoto da câmera (`docs/controle-remoto-da-camera.md`, R9b) -------------------

    /** Os bits de `changed` do filmador (`QuallCameraHostChange`). */
    object MudouNoFilmador {
        /** Há pedido aceito: [cameraHostNextRequest] até `null`. Um consumidor só. */
        const val PEDIDO = 1
        /** Um receptor disse `ola` ou saiu. */
        const val RECEPTORES = 2
    }

    /** Os bits de `changed` do receptor (`QuallCameraRemoteChange`). */
    object MudouNoReceptor {
        const val CAPACIDADES = 1
        const val AJUSTE = 2
        const val LIDO = 4
        const val RECUSA = 8
        const val SITUACAO = 16
    }

    /**
     * O que uma bombeada da câmera devolve: o [Status] e os bits. O JNI empacota os dois num `jint`
     * (`changed | status << 16`); os bits vêm preenchidos **também** com [Status.CLOSED].
     */
    data class Bombeada(val status: Int, val mudou: Int) {
        companion object {
            fun de(r: Int): Bombeada = Bombeada(r ushr 16, r and 0xFFFF)
        }
    }

    /** `quall_camera_host_new`: o filmador, com a permissão desligada e sem câmera. `0` em erro. */
    external fun cameraHostNew(): Long
    external fun cameraHostFree(h: Long)
    external fun cameraHostSetAllowed(h: Long, permite: Boolean): Int

    private external fun cameraHostSetCamera(h: Long, capacidades: ByteArray?, ajuste: ByteArray?): Int

    /** A câmera em uso (as capacidades do contrato §3.2 e o registro do R9), ou os dois `null` = sem câmera. */
    fun cameraHostSetCamera(h: Long, capacidades: String?, ajuste: String?): Int =
        cameraHostSetCamera(h, capacidades?.utf8(), ajuste?.utf8())

    private external fun cameraHostSetCapabilities(h: Long, capacidades: ByteArray): Int

    /** As faixas novas da mesma câmera (o teto do obturador que segue o fps). */
    fun cameraHostSetCapabilities(h: Long, capacidades: String): Int = cameraHostSetCapabilities(h, capacidades.utf8())

    private external fun cameraHostSetSettings(h: Long, ajuste: ByteArray, pedido: Long): Int

    /** O registro que ficou valendo. [pedido] `0` = mudança feita aqui; senão o `"n"` do pedido. */
    fun cameraHostSetSettings(h: Long, ajuste: String, pedido: Long): Int = cameraHostSetSettings(h, ajuste.utf8(), pedido)

    private external fun cameraHostUpdateSettings(h: Long, ajuste: ByteArray): Int

    /** O registro que a casca escreveu sozinha (o lido que a trava guarda): não muda o dono de nada. */
    fun cameraHostUpdateSettings(h: Long, ajuste: String): Int = cameraHostUpdateSettings(h, ajuste.utf8())

    private external fun cameraHostSetRead(h: Long, lido: ByteArray): Int

    fun cameraHostSetRead(h: Long, lido: String): Int = cameraHostSetRead(h, lido.utf8())

    private external fun cameraHostReject(h: Long, pedido: Long, motivo: ByteArray): Int

    /** Recusa o pedido `n` com um código `[a-z0-9_]{1,32}` (`nao_aplicado`, `fora_da_imagem`). */
    fun cameraHostReject(h: Long, pedido: Long, motivo: String): Int = cameraHostReject(h, pedido, motivo.utf8())

    private external fun cameraHostNextRequestBytes(h: Long, estado: IntArray): ByteArray?

    /**
     * O próximo pedido aceito, ou `null` com a fila vazia (`estado[0] = 0`) ou em erro (`estado[0]`
     * negativo, o status com sinal trocado). Laço próprio no JNI: o pedido só sai da fila quando coube.
     */
    fun cameraHostNextRequest(h: Long, estado: IntArray): String? =
        cameraHostNextRequestBytes(h, estado)?.let { String(it, Charsets.UTF_8) }

    private external fun cameraHostPump(h: Long, mensagens: Long, timeoutMs: Int): Int

    /** A bombeada do filmador numa sessão de vídeo (`timeoutMs` de 0 a 250). */
    fun cameraHostBombear(h: Long, mensagens: Long, timeoutMs: Int): Bombeada =
        Bombeada.de(cameraHostPump(h, mensagens, timeoutMs))

    external fun cameraHostForget(h: Long, mensagens: Long): Int

    private external fun cameraHostStateJsonBytes(h: Long): ByteArray

    /** O estado para a tela do filmador; vazio em falha. */
    fun cameraHostStateJson(h: Long): String = String(cameraHostStateJsonBytes(h), Charsets.UTF_8)

    /** `quall_camera_remote_new`: o controle da câmera do outro lado, um por sessão de recepção. */
    external fun cameraRemoteNew(): Long
    external fun cameraRemoteFree(r: Long)

    private external fun cameraRemoteRequest(r: Long, ajuste: ByteArray): Int

    /** Um ajuste parcial (só os campos mexidos). **Só de gesto da pessoa.** */
    fun cameraRemoteRequest(r: Long, ajuste: String): Int = cameraRemoteRequest(r, ajuste.utf8())

    external fun cameraRemoteRestore(r: Long): Int

    /** Um toque em ([x], [y]) de 0 a 1 **no quadro decodificado**. */
    external fun cameraRemoteTouch(r: Long, x: Double, y: Double, longo: Boolean): Int

    private external fun cameraRemotePump(r: Long, mensagens: Long, timeoutMs: Int): Int

    fun cameraRemoteBombear(r: Long, mensagens: Long, timeoutMs: Int): Bombeada =
        Bombeada.de(cameraRemotePump(r, mensagens, timeoutMs))

    private external fun cameraRemoteStateJsonBytes(r: Long): ByteArray

    /** O estado para a tela do receptor; vazio em falha. */
    fun cameraRemoteStateJson(r: Long): String = String(cameraRemoteStateJsonBytes(r), Charsets.UTF_8)

    private fun String.utf8(): ByteArray = toByteArray(Charsets.UTF_8)
}
