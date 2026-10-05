package com.quall.android.receive

import com.quall.android.aceleradoPorHardware

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.capture.AnnexB
import com.quall.android.capture.MonotonicClock
import java.nio.ByteBuffer

/**
 * Decodifica H.264 em **hardware** com `MediaCodec` e desenha direto numa `Surface`.
 *
 * É o espelho do `H264SurfaceEncoder` do lado emissor, e usa o mesmo componente do aparelho: no
 * A07 e no A10s quem encoda é `c2.mtk.avc.encoder`/`OMX.MTK.VIDEO.ENCODER.AVC`, e quem decodifica
 * é a peça irmã do mesmo fornecedor.
 *
 * ## Nenhuma cópia para memória Java
 *
 * `configure(..., surface, ...)` põe o decodificador em modo de saída para `Surface`: os buffers
 * de saída **não** têm bytes legíveis do lado do Java, e `releaseOutputBuffer(idx, true)` entrega
 * o quadro direto ao compositor. Não há `ByteBuffer` de imagem, não há conversão de YUV, não há
 * `Bitmap`. Na entrada é a mesma disciplina: `frameBoxTake` copia do anel em C **direto para o
 * `ByteBuffer` de entrada do codec**, sem passar por `ByteArray`.
 *
 * ## O `presentationTimeUs` que entra é o relógio de chegada, e é isso que dá a latência
 *
 * O `timestamp_us` que o núcleo entrega é o relógio **do emissor** — outro aparelho, outro
 * relógio, incomparável com o daqui (a frente da câmera já pagou essa conta do outro lado, ver
 * `H264SurfaceEncoder.latenciaComparavel`). Então o que se carimba na entrada do decodificador é
 * o instante local de chegada, e `agora − presentationTimeUs` na saída é uma latência honesta:
 * **da chegada do quadro à imagem entregue ao compositor**. Não é vidro a vidro, e este arquivo
 * não finge que seja.
 */
class H264Decoder(private val surface: Surface) {

    companion object {
        private const val TAG = "QuallDecoder"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        /** Janela deslizante de amostras de latência. ~30 s a 30 fps, e teto de memória. */
        private const val AMOSTRAS = 900
        /** Janela para a taxa obtida. Curta de propósito: fps é medida instantânea. */
        private const val AMOSTRAS_FPS = 120

        /**
         * Teto da fila de quadros condenados à espera da saída correspondente.
         *
         * O pipeline do `MediaCodec` segura poucos quadros; uma fila que passe disto quer dizer
         * que a saída parou, e aí reter mais não conserta nada. Ver [enfileirar].
         */
        private const val TETO_DE_SUSPEITOS = 64

        /**
         * Extrai o SPS+PPS (em Annex-B, com os start codes) de uma unidade de acesso que os
         * traga — é o `csd-0` que [abrir] põe no `MediaFormat`. `null` quando não há parâmetros.
         *
         * Corta exatamente onde começa o **start code** do NAL seguinte, e não onde
         * `AnnexB.nalStarts` aponta: aquele índice é o byte depois do start code, e um start code
         * de quatro bytes deixaria um `0x00` sobrando no fim do `csd`.
         */
        fun extrairCsd(buffer: ByteBuffer, tamanho: Int): ByteArray? {
            val inicios = AnnexB.nalStarts(buffer, 0, tamanho)
            if (inicios.isEmpty()) return null
            var fimDosParametros = -1
            for ((i, inicio) in inicios.withIndex()) {
                val tipo = AnnexB.nalType(buffer.get(inicio))
                if (tipo == AnnexB.NAL_SPS || tipo == AnnexB.NAL_PPS) {
                    fimDosParametros =
                        if (i + 1 < inicios.size) inicioDoStartCode(buffer, inicios[i + 1]) else tamanho
                }
            }
            if (fimDosParametros <= 0) return null
            val csd = ByteArray(fimDosParametros)
            for (i in 0 until fimDosParametros) csd[i] = buffer.get(i)
            return csd
        }

        /** Onde começa o start code que precede o NAL cujo primeiro byte está em [inicioDoNal]. */
        private fun inicioDoStartCode(buffer: ByteBuffer, inicioDoNal: Int): Int {
            val tresBytes = inicioDoNal - 3
            return if (tresBytes > 0 && buffer.get(tresBytes - 1) == 0.toByte()) tresBytes - 1 else tresBytes
        }
    }

    data class Instantaneo(
        val quadrosEnfileirados: Long,
        val retidos: Long,
        val fpsObtido: Double,
        val latenciaP50Us: Long,
        val latenciaP95Us: Long,
        val largura: Int,
        val altura: Int,
        val codec: String,
        val hardware: Boolean,
    )

    private var codec: MediaCodec? = null
    private val info = MediaCodec.BufferInfo()

    /** Índice de entrada já retirado do codec e ainda não devolvido. Ver a doc de [entradaLivre]. */
    private var entradaPendente = -1

    @Volatile var nomeDoCodec: String = ""
        private set

    @Volatile var ehHardware: Boolean = false
        private set

    /** `false` quando o componente recusou `KEY_LOW_LATENCY` e foi configurado sem ela. */
    @Volatile var baixaLatencia: Boolean = false
        private set

    @Volatile var largura: Int = 0
        private set

    @Volatile var altura: Int = 0
        private set

    /**
     * **Chamado na hora em que o tamanho da imagem muda no meio da sessão** (o formato de saída
     * novo, antes do primeiro quadro dele). Até 21/09 a tela só sabia do tamanho novo pelo relato de
     * 500 ms, e a superfície esticava a imagem nova no tamanho velho por 60 a 400 ms: o Pessoa Exemplo viu
     * esse esticão em cada troca no S24 e no tablet. Roda na thread da recepção.
     */
    @Volatile var aoMudarDeTamanho: ((Int, Int) -> Unit)? = null

    /**
     * Quadros entregues ao **compositor** por `releaseOutputBuffer(idx, true)`.
     *
     * **Chamava-se `exibidos` até 31/08/2026, e o nome prometia o que não entrega.** Entregar o
     * buffer à Surface é enfileirá-lo na `BufferQueue` do SurfaceFlinger: o compositor ainda pode
     * descartá-lo (app não visível, buffer velho substituído pelo seguinte), e nada nesta camada
     * observa o vidro. É a mesma correção que o receptor iOS fez em 28/08 quando renomeou o
     * `exibidos` dele — lá o enfileiramento era o da `AVSampleBufferDisplayLayer` — e o nome é o
     * mesmo **de propósito**: as duas cascas contam a mesma coisa e agora dizem a mesma palavra.
     *
     * O caminho daqui é mais curto que o do iOS (uma fila, não duas), e ainda assim não é a tela.
     */
    @Volatile var quadrosEnfileirados = 0L
        private set

    /**
     * `retidos` do contrato: quadros decodificados que a porta **impediu** de ir ao compositor,
     * por terem a referência condenada. Ver [enfileirar] e [drenar].
     */
    @Volatile var retidos = 0L
        private set

    /**
     * **A distribuição dos intervalos entre apresentações.** Ver [Fluidez] para o contrato inteiro
     * e para por que a média de `fila→tela` não respondia "falta fluidez".
     *
     * ## Onde a marca é tirada, e o que ela vale nesta casca
     *
     * No `releaseOutputBuffer(idx, true)` de [drenar], que é o ponto de apresentação do Android: a
     * chamada que manda o quadro para a `Surface`. **É só o que fica de fora da porta** — o quadro
     * condenado sai por `releaseOutputBuffer(idx, false)`, que não é apresentação nenhuma, e é
     * assim que o congelamento que a porta custa aparece aqui como intervalo maior. Medir chegadas
     * ou decodificações esconderia a porta.
     *
     * **A marca é tirada depois de a chamada voltar, e não do `agora` que a latência de decode já
     * lê antes dela.** Os dois medem coisas diferentes: a latência quer o instante em que o quadro
     * ficou pronto, o intervalo quer o instante em que ele foi entregue. Quando a `BufferQueue`
     * estiver cheia e a entrega segurar, é o segundo instante que anda — e ele é o que o olho
     * sente.
     *
     * ## A vantagem sobre as cascas Apple, e o que ela **não** garante
     *
     * `releaseOutputBuffer(idx, true)` entrega o quadro à `Surface` **de forma síncrona, no ponto
     * em que a gente chama**: quando ela volta, o buffer está na `BufferQueue` do SurfaceFlinger.
     * Não há uma camada de exibição do sistema com fila e relógio próprios entre a nossa chamada e
     * o compositor, como há na `AVSampleBufferDisplayLayer` do iOS e do macOS — lá se entrega a um
     * enfileirador que decide sozinho quando (e se) mostra, e a marca fica um passo mais longe do
     * vidro. Aqui o caminho é uma fila, não duas.
     *
     * **Isso não é o vidro, e este arquivo não finge que seja.** O compositor tem a palavra final:
     * ele pode descartar o buffer (app não visível, buffer velho substituído pelo seguinte) e ele
     * mostra na batida do `VSYNC`, que é dele e não nossa. Um intervalo de 33 ms medido aqui pode
     * ter virado 16 ms ou 50 ms na tela. É a mesma ressalva que fez `exibidos` virar
     * [quadrosEnfileirados] em 31/08/2026, e vale igual para esta distribuição: **o que se afirma
     * é o intervalo entre entregas, e ele é o mais perto do vidro que esta casca alcança sem
     * instrumentar o SurfaceFlinger.**
     */
    val fluidez = Fluidez()

    /**
     * Carimbos de entrada dos quadros condenados, na ordem. Um quadro sai da fila quando o
     * `MediaCodec` devolve a saída com o mesmo `presentationTimeUs`.
     *
     * Só a thread do laço do receptor toca isto — [enfileirar] e [drenar] são chamados de lá, um
     * depois do outro.
     */
    private val suspeitos = ArrayDeque<Long>()

    /**
     * Este quadro de saída estava condenado? Consome a marca, e **as mais velhas que ela**.
     *
     * Casar por `presentationTimeUs` em vez de contar posições sobrevive a um quadro que entre e
     * nunca saia (o codec engoliu, ou o `flush` levou): uma fila por posição dessincronizaria de
     * vez e passaria a reter quadro bom para sempre. Não achar a marca devolve `false` — **a porta
     * abre no que não se sabe**, que é o lado seguro do erro.
     */
    private fun consumirSuspeito(ptsUs: Long): Boolean {
        while (suspeitos.isNotEmpty() && suspeitos.first() <= ptsUs) {
            if (suspeitos.removeFirst() == ptsUs) return true
        }
        return false
    }

    @Volatile var quadrosEntregues = 0L
        private set

    private val latencias = LongArray(AMOSTRAS)
    private var nLatencias = 0
    private var proximaLatencia = 0

    private val renderizados = LongArray(AMOSTRAS_FPS)
    private var nRenderizados = 0
    private var proximoRenderizado = 0

    /**
     * Cria e inicia o decodificador. `csd` é o SPS+PPS em Annex-B, tirado do primeiro IDR que
     * chegou — o mesmo buffer que será enfileirado logo em seguida como primeiro quadro.
     */
    fun abrir(csd: ByteArray, largura: Int, altura: Int) {
        fun formato(baixaLatencia: Boolean) =
            MediaFormat.createVideoFormat(MIME, largura, altura).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(csd))
                // Modo de baixa latência: pede ao decodificador para não segurar quadros
                // esperando reordenação. O fluxo do Quall é Baseline sem B-frames, então não há
                // nada a reordenar — e foi exatamente esse empilhamento que custou 169,5 ms de
                // decode no receptor Windows (`docs/divida-do-nucleo.md`, o achado do SPS sem
                // VUI). É **pedido**, não exigido: nem todo componente aceita a chave, e um
                // decodificador que recusa a configuração inteira por causa dela deixaria o app
                // sem imagem por um ganho de latência. Daí a segunda tentativa sem a chave.
                if (baixaLatencia) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }

        var c = MediaCodec.createDecoderByType(MIME)
        var comBaixaLatencia = true
        try {
            c.configure(formato(true), surface, null, 0)
        } catch (e: Exception) {
            Log.w(TAG, "o decodificador recusou KEY_LOW_LATENCY; tentando sem", e)
            runCatching { c.release() }
            c = MediaCodec.createDecoderByType(MIME)
            c.configure(formato(false), surface, null, 0)
            comBaixaLatencia = false
        }
        c.start()
        baixaLatencia = comBaixaLatencia
        codec = c
        this.largura = largura
        this.altura = altura
        nomeDoCodec = runCatching { c.name }.getOrDefault("desconhecido")
        ehHardware = decodificadorEhHardware(nomeDoCodec)
        Log.i(
            TAG,
            "decodificador aberto: $nomeDoCodec (hw=$ehHardware, baixa_latencia=$baixaLatencia) " +
                "${largura}x$altura",
        )
    }

    val aberto: Boolean get() = codec != null

    /**
     * Um índice de buffer de entrada livre, ou `-1`.
     *
     * O índice fica **guardado** entre chamadas quando nenhum quadro chega para preenchê-lo. Sem
     * isso, a alternativa seria enfileirar um buffer vazio só para devolvê-lo ao codec — que é
     * pedir para um decodificador legado se perder.
     */
    fun entradaLivre(timeoutUs: Long): Int {
        val c = codec ?: return -1
        if (entradaPendente >= 0) return entradaPendente
        entradaPendente = try {
            c.dequeueInputBuffer(timeoutUs)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "dequeueInputBuffer falhou", e)
            -1
        }
        return entradaPendente
    }

    fun bufferDeEntrada(idx: Int): ByteBuffer? = codec?.getInputBuffer(idx)

    /**
     * Entrega ao decodificador o buffer preenchido por `frameBoxTake`.
     *
     * [suspeito] diz que a referência deste quadro foi condenada — ele chegou depois de uma
     * ruptura da cadeia e antes do IDR que a cura. Ele **é decodificado assim mesmo** (parar de
     * alimentar o `MediaCodec` dessincronizaria a sessão e o IDR seguinte chegaria num
     * decodificador com buraco); o que muda é o `render` do [drenar], lá na frente.
     *
     * A marca viaja pelo `presentationTimeUs`, e não por uma variável de instante: entre a entrada
     * e a saída correspondente do `MediaCodec` há **pipeline**, e um sinalizador lido na saída
     * pertenceria ao quadro errado. É o ponto onde esta casca não pode copiar o iOS, onde o decode
     * é síncrono dentro do tratador.
     */
    fun enfileirar(idx: Int, tamanho: Int, chegadaUs: Long, suspeito: Boolean = false) {
        val c = codec ?: return
        c.queueInputBuffer(idx, 0, tamanho, chegadaUs, 0)
        entradaPendente = -1
        quadrosEntregues++
        if (suspeito) {
            // Teto de sanidade: numa sessão de 30 fps o pipeline do MediaCodec segura poucos
            // quadros, e uma fila que cresça sem limite aqui é sinal de que a saída parou — caso
            // em que reter mais nada ajuda. Descartar o mais velho **abre a porta**, que é o lado
            // seguro do erro: uma imagem suja é melhor que uma tela parada por contabilidade.
            if (suspeitos.size >= TETO_DE_SUSPEITOS) suspeitos.removeFirst()
            suspeitos.addLast(chegadaUs)
        }
    }

    /**
     * Tira o que estiver pronto na saída e **desenha**. Devolve quantos quadros foram para a tela
     * nesta chamada.
     */
    fun drenar(): Int {
        val c = codec ?: return 0
        var desenhados = 0
        while (true) {
            val idx = try {
                c.dequeueOutputBuffer(info, 0)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "dequeueOutputBuffer falhou", e)
                return desenhados
            }
            when {
                idx >= 0 -> {
                    val agora = MonotonicClock.micros()
                    // **A porta: um quadro cuja referência foi condenada não vai para a tela.**
                    //
                    // `releaseOutputBuffer(idx, false)` devolve o buffer ao codec **sem** entregá-lo
                    // à Surface: o quadro foi decodificado (a sessão segue sincronizada, o IDR
                    // seguinte chega num decodificador inteiro) e o compositor continua com o
                    // último quadro bom na tela. É o análogo exato de não chamar `oferecer` no iOS.
                    val condenado = consumirSuspeito(info.presentationTimeUs)
                    c.releaseOutputBuffer(idx, !condenado)
                    if (condenado) {
                        retidos++
                        continue
                    }
                    // **O instante em que o quadro foi entregue para ser mostrado.** Ver [fluidez]
                    // para por que a marca é tirada **depois** da chamada, e não do `agora` acima.
                    fluidez.apresentou(MonotonicClock.micros())
                    quadrosEnfileirados++
                    desenhados++
                    val latencia = agora - info.presentationTimeUs
                    if (latencia in 0..5_000_000) {
                        latencias[proximaLatencia] = latencia
                        proximaLatencia = (proximaLatencia + 1) % AMOSTRAS
                        if (nLatencias < AMOSTRAS) nLatencias++
                    }
                    renderizados[proximoRenderizado] = agora
                    proximoRenderizado = (proximoRenderizado + 1) % AMOSTRAS_FPS
                    if (nRenderizados < AMOSTRAS_FPS) nRenderizados++
                }

                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = c.outputFormat
                    fun chave(k: String): Int? = runCatching { f.getInteger(k) }.getOrNull()
                    val chaveL = chave(MediaFormat.KEY_WIDTH)
                    val chaveA = chave(MediaFormat.KEY_HEIGHT)
                    val novo = TamanhoDaSaida.de(chaveL, chaveA, chave("crop-left"), chave("crop-right"),
                        chave("crop-top"), chave("crop-bottom"))
                    // **Toda mudança de formato vai ao registro, com as chaves cruas** (a revisão do
                    // `23eb480`, B3): o recorte do S24 era suposto, e a linha só saía quando o
                    // tamanho mudava — a primeira, a 854, não saía nunca.
                    Log.i(TAG, "formato de saída: KEY ${chaveL}x$chaveA, recorte ${chave("crop-left")}..${chave("crop-right")} x " +
                        "${chave("crop-top")}..${chave("crop-bottom")} -> imagem ${novo?.first}x${novo?.second}")
                    if (novo != null && (novo.first != largura || novo.second != altura)) {
                        Log.i(TAG, "formato de saída mudou: ${largura}x$altura -> ${novo.first}x${novo.second}")
                        largura = novo.first
                        altura = novo.second
                        // A tela sabe **agora**, e não no relato de 500 ms (o esticão de 21/09).
                        aoMudarDeTamanho?.invoke(novo.first, novo.second)
                    }
                }

                else -> return desenhados // INFO_TRY_AGAIN_LATER e afins
            }
        }
    }

    fun instantaneo(): Instantaneo = Instantaneo(
        quadrosEnfileirados = quadrosEnfileirados,
        retidos = retidos,
        fpsObtido = fpsObtido(),
        latenciaP50Us = percentil(50),
        latenciaP95Us = percentil(95),
        largura = largura,
        altura = altura,
        codec = nomeDoCodec,
        hardware = ehHardware,
    )

    private fun fpsObtido(): Double {
        if (nRenderizados < 2) return 0.0
        val amostras = LongArray(nRenderizados)
        for (i in 0 until nRenderizados) {
            amostras[i] = renderizados[(proximoRenderizado - nRenderizados + i + AMOSTRAS_FPS * 2) % AMOSTRAS_FPS]
        }
        val duracao = amostras[nRenderizados - 1] - amostras[0]
        if (duracao <= 0) return 0.0
        return (nRenderizados - 1) * 1_000_000.0 / duracao
    }

    private fun percentil(p: Int): Long {
        if (nLatencias == 0) return 0
        val copia = latencias.copyOf(nLatencias)
        copia.sort()
        val idx = ((p / 100.0) * (copia.size - 1)).toInt().coerceIn(0, copia.size - 1)
        return copia[idx]
    }

    fun fechar() {
        val c = codec ?: return
        codec = null
        runCatching { c.stop() }
        runCatching { c.release() }
    }

    /**
     * Se o componente escolhido é de hardware. Perguntado ao `MediaCodecList` pelo nome real do
     * que o sistema entregou — não deduzido do prefixo, e não presumido: o contrato do sidecar
     * separa `encoder` de `encoder_is_hardware` justamente porque "o pretendido" e "o que
     * aconteceu" divergem (no Dell, o NVENC enumera e não ativa).
     */
    private fun decodificadorEhHardware(nome: String): Boolean {
        val lista = MediaCodecList(MediaCodecList.ALL_CODECS)
        for (info in lista.codecInfos) {
            if (info.name != nome) continue
            // Abaixo do 29, o critério antigo por prefixo (`aceleradoPorHardware`).
            return info.aceleradoPorHardware
        }
        return false
    }
}
