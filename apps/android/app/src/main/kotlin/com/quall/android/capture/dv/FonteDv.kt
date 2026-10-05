package com.quall.android.capture.dv

import com.quall.android.escritorYuv420
import android.hardware.HardwareBuffer
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.ImageFormat
import android.hardware.DataSpace
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.media.ImageWriter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PerformanceHintManager
import android.os.Process
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.Idioma
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A filmadora DV, ou a placa de captura USB (MJPEG, `docs/placa-de-captura-usb.md`), como fonte de
 * câmera: **do serviço, e não da sessão.** Abre uma vez (depois da
 * permissão USB, que a Activity pediu) e atravessa as sessões, como a câmera do CameraX; cada
 * sessão liga a superfície do encoder ([ligar]) e a solta ([desligar]).
 *
 * Uma thread (`quall-dv`) vive do [abrir] ao [fechar]. Ela espera os quadros da `libqualldv`,
 * guarda o aspecto do último, e só converte quando há um [ImageWriter] ligado. Com isso:
 * - o aspecto da abertura da sessão já é conhecido quando o encoder nasce;
 * - a desconexão aparece também durante a espera, e não só com a sessão no ar;
 * - a pausa (a câmera ligada que parou de mandar) é vista pela mesma thread.
 *
 * **A ordem de desligar é rígida** (a revisão da fase B, A3): conversão e `close` do escritor
 * correm sob a mesma [trava], então ninguém escreve num plano de um `Image` já fechado. O
 * [QuallDv.fechar] só roda depois de a thread sair. E nunca se chama `dequeueInputImage` sem
 * imagem livre: [livres] conta as que o encoder devolveu, e sem nenhuma o quadro cai (contado), em
 * vez de a thread dormir dentro do `dequeue` segurando a trava que o encoder precisa para parar.
 */
class FonteDv private constructor(
    private val contexto: Context,
    /** `null` na bancada de arquivo. */
    private val aparelho: UsbDevice?,
    private val aberta: UsbDv.Aberta?,
    private val h: Long,
    /** O som da placa vem pelo usbfs (§13.10), e não pelo `AudioRecord`. */
    val temSomUsb: Boolean = false,
) {
    /** O formato aberto (a bancada de arquivo é DV). */
    val tipo: TipoUsb = aberta?.tipo ?: TipoUsb.DV
    val mjpeg: Boolean get() = tipo == TipoUsb.MJPEG
    /** O quadro que a câmera manda (a DV é 720x480 sempre; o MJPEG, o negociado: 640x480 na placa). */
    val larguraDoQuadro: Int = aberta?.largura ?: 720
    val alturaDoQuadro: Int = aberta?.altura ?: 480
    /** O cardápio da placa e o que está aberto (§14.4): a tela deixa a pessoa trocar. */
    val ofertas: List<Oferta> get() = aberta?.ofertas ?: emptyList()
    val formatoAberto: String get() = aberta?.formato ?: "DV"
    val intervaloAberto: Long get() = aberta?.intervalo ?: 0L
    val aparelhoUsb: UsbDevice? get() = aparelho

    /** Os quadros por segundo negociados com a placa (30 sem saber; as HDMI em 720p dão 60). */
    val quadrosDaPlaca: Int = aberta?.intervalo?.takeIf { it > 0 }?.let { Math.round(10_000_000.0 / it).toInt() }?.coerceIn(5, 120) ?: 30
    /** Os quadros por segundo que a fonte guarda quando a pessoa pediu menos que a placa manda (§14.6); 0 = todos. */
    val fpsAlvo: Int = aberta?.fpsAlvo?.takeIf { it in 1 until quadrosDaPlaca } ?: 0
    /** Os quadros por segundo que saem da fonte: os da placa, ou os que a pessoa pediu. */
    val quadrosPorSegundo: Int = if (fpsAlvo > 0) fpsAlvo else quadrosDaPlaca
    /** A placa manda alta definição (HDMI, 720 linhas ou mais): a cor é BT.709, e não a BT.601 do vídeo analógico. */
    val hd: Boolean get() = mjpeg && alturaDoQuadro >= 720
    /** O `productName` do aparelho USB (o som da placa casa o `AudioDeviceInfo` por ele). */
    val nomeDoAparelho: String? get() = aparelho?.productName

    /** Chamados na thread `quall-dv` (ou na principal, para a desconexão vista pelo broadcast). */
    interface Ouvinte {
        fun aoPausar()
        fun aoVoltar(pausaMs: Long)
        fun aoCair(motivo: String)
    }

    @Volatile var ouvinte: Ouvinte? = null

    /** 1 = 16:9, 0 = 4:3, -1 = ainda sem quadro com o pacote VSC. */
    @Volatile var aspecto169: Int = -1
        private set

    /** Aberta, mas sem quadro há mais de 1 s (a fita parada, a placa sem sinal): a tela diz. */
    @Volatile var semQuadro = false
        private set

    @Volatile private var parar = false
    @Volatile private var caiu = false
    private val primeiroQuadro = CountDownLatch(1)

    private val trava = Any()
    private var escritor: ImageWriter? = null
    private var livres = 0
    private var largura = 0
    private var altura = 0

    private val imagens = HandlerThread("quall-dv-imagens").also { it.start() }

    // contadores desta fonte (os da lib vão em `resumo`)
    @Volatile private var quadrosNaSessao = 0L
    @Volatile private var velhos = 0L
    @Volatile private var semImagem = 0L
    @Volatile private var falhasDeConversao = 0L
    @Volatile private var pausas = 0L

    private val desplugue = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val d: UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
                i.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION") i.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            if (aparelho != null && d?.deviceName == aparelho.deviceName) cair(frase(R.string.placa_camera_desconectada))
        }
    }

    private val thread = Thread({ laco() }, "quall-dv")

    private fun iniciar() {
        if (aparelho == null) { thread.start(); return }
        val filtro = IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED)
        if (Build.VERSION.SDK_INT >= 33) {
            contexto.registerReceiver(desplugue, filtro, Context.RECEIVER_NOT_EXPORTED)
        } else {
            contexto.registerReceiver(desplugue, filtro)
        }
        thread.start()
    }

    /**
     * O motivo de uma queda vai à tela ("A imagem parou: …", a gravação parada): no idioma escolhido
     * agora, pedido a cada frase (`docs/traducao.md`, Android).
     */
    private fun frase(id: Int, vararg args: Any): String = Idioma.textos(Idioma.contexto(contexto)).s(id, *args)

    private fun cair(motivo: String) {
        if (caiu) return
        caiu = true
        Log.w(TAG, "câmera DV: ${Log.erroExterno(motivo)}")
        runCatching { ouvinte?.aoCair(motivo) }
    }

    val desconectada: Boolean get() = caiu

    /**
     * O tamanho da abertura da sessão na DV: 854x480 em 16:9, 640x480 em 4:3, pelo aspecto do
     * último quadro. Espera o primeiro quadro por até [esperaMs]; sem nenhum (a câmera parada desde
     * antes), 16:9, e um quadro 4:3 que chegar depois sai encaixado com faixas, sem distorção. O
     * MJPEG não passa por aqui (a rede vai no tamanho do quadro, [larguraDoQuadro]).
     */
    fun aspectoDaAbertura(esperaMs: Long = 3000): Int {
        if (mjpeg) return 0
        primeiroQuadro.await(esperaMs, TimeUnit.MILLISECONDS)
        return if (aspecto169 == 0) 0 else 1
    }

    /** Liga a superfície de entrada do encoder. Chamado pela thread do encoder. */
    fun ligar(surface: Surface, largura: Int, altura: Int) {
        synchronized(trava) {
            // Nada de quadro guardado de antes da sessão (a revisão, A4) — **menos com a gravação da
            // placa no ar** (§11, item 4): a fila funda dela seria esvaziada, e o arquivo perderia até
            // ~260 ms. O quadro velho não vai à rede de qualquer jeito ([VELHO_NS]).
            if (gravador == null) QuallDv.descartar(h)
            // O dataspace do DV: BT.601 525, faixa limitada (a revisão da fase B, A5).
            val w = novoEscritor(surface)
            w.setOnImageReleasedListener({ synchronized(trava) { livres++ } }, Handler(imagens.looper))
            escritor = w
            livres = MAX_IMAGENS
            this.largura = largura
            this.altura = altura
            quadrosNaSessao = 0; velhos = 0; semImagem = 0; falhasDeConversao = 0
            // O MJPEG da placa também é faixa limitada (medido na P0, §8.1): o mesmo dataspace.
            Log.i(TAG, "ligada ao encoder ${largura}x$altura, fonte $tipo ${larguraDoQuadro}x$alturaDoQuadro " +
                "(${if (Build.VERSION.SDK_INT >= 33) (if (hd) "BT709 limitada" else "BT601_525 limitada") else "dataspace padrão"})")
        }
    }

    /** Solta a superfície. Depois disto nenhum plano de `Image` é escrito. */
    fun desligar() {
        synchronized(trava) {
            val w = escritor ?: return
            escritor = null
            runCatching { w.close() }
            Log.i(TAG, "desligada do encoder: quadros=$quadrosNaSessao velhos=$velhos sem_imagem=$semImagem " +
                "falhas=$falhasDeConversao pausas=$pausas; ${resumo()}")
        }
    }

    // o último resumo: os SUBMITURB aceitos e quando (para os envios por segundo desde ele)
    private val travaDoResumo = Any()
    private var enviosAntes = 0L
    private var enviosAntesNs = 0L

    /** SUBMITURB aceitos por segundo desde o resumo anterior (ou desde a abertura, no primeiro). */
    private fun enviosPorSegundo(envios: Long): Long = synchronized(travaDoResumo) {
        val agora = System.nanoTime()
        val desde = if (enviosAntesNs == 0L) abertaEmNs else enviosAntesNs
        val dt = (agora - desde).coerceAtLeast(1)
        val r = (envios - enviosAntes) * 1_000_000_000L / dt
        enviosAntes = envios; enviosAntesNs = agora
        r
    }

    private val abertaEmNs = System.nanoTime()

    fun resumo(): String {
        val c = runCatching { QuallDv.contadores(h) }.getOrNull() ?: return "(sem contadores)"
        val ent = c[5].coerceAtLeast(1)
        fun k(i: Int) = c.getOrElse(i) { 0 }
        // O custo das URBs curtas da placa (no máximo 3 pacotes: ~2700 SUBMITURB/s; §11): a prova
        // mede a CPU com este número ao lado.
        val base = "integros=${c[0]} tortos=${c[1]} ruins_entregues=${k(11)} caidos_fila=${c[2]} " +
            "erros_pacote=${c[3]} err_bit=${c[4]} reenvio_recusado=${k(12)} tentativas_recusadas=${k(21)} " +
            "envios=${k(24)} envios_por_s=${enviosPorSegundo(k(24))} " +
            "convertidos=${c[5]} falhas_decod=${c[6]} trocas_aspecto=${c[7]} " +
            "us_medio decod=${c[8] / ent} desentrelacar=${c[9] / ent} converter=${c[10] / ent}"
        if (!mjpeg) return base
        // Os motivos dos tortos do MJPEG, as URBs, e o custo do decodificador por JPEG íntegro (o
        // decodificar roda também só para a prévia, então a média por convertido engana; §3.5).
        return "$base; mjpeg sem_soi=${k(13)} sem_eoi=${k(14)} grande_demais=${k(15)} " +
            "descartados_ruins=${k(16)} dois_em_um=${k(17)} so_pela_borda=${k(18)} " +
            "lixo_depois_do_eoi=${k(22)} cabecalho_invalido=${k(23)} " +
            "urbs=${k(19)}x${k(20)} us_decod_por_integro=${c[8] / c[0].coerceAtLeast(1)}"
    }

    private fun laco() {
        var dica: PerformanceHintManager.Session? = null
        if (Build.VERSION.SDK_INT >= 31) {
            // Alvo de um quadro a 29,97. No ritmo real, sem dica, o governador segura os núcleos
            // a 0,6-0,7 GHz e o custo sobe de 1,7 para 13 ms (fase A, §7).
            dica = runCatching {
                contexto.getSystemService(PerformanceHintManager::class.java)
                    ?.createHintSession(intArrayOf(Process.myTid()), 33_366_667L)
            }.getOrNull()
        }
        var ultimoQuadroNs = System.nanoTime()
        var emPausa = false
        var ultimoLog = System.nanoTime()
        try {
            while (!parar) {
                val ts = QuallDv.esperar(h, 200)
                val agora = System.nanoTime()
                if (ts == QuallDv.DESCONECTADA) { cair(frase(R.string.placa_camera_desconectada)); break }
                if (ts == QuallDv.PRAZO) {
                    if (!emPausa && agora - ultimoQuadroNs > PAUSA_NS) {
                        emPausa = true
                        semQuadro = true
                        pausas++
                        Log.i(TAG, "câmera parada, esperando")
                        runCatching { ouvinte?.aoPausar() }
                    }
                    // Parada, os contadores também vão ao diário (os quadros podem estar chegando tortos).
                    if (emPausa && agora - ultimoLog > 10_000_000_000L) {
                        ultimoLog = agora
                        Log.i(TAG, "dv (sem quadro): ${resumo()}")
                    }
                    continue
                }
                val a = QuallDv.aspecto(h)
                if (a >= 0) aspecto169 = a
                primeiroQuadro.countDown()
                if (emPausa) {
                    emPausa = false
                    semQuadro = false
                    val ms = (agora - ultimoQuadroNs) / 1_000_000
                    Log.i(TAG, "a câmera voltou depois de $ms ms")
                    runCatching { ouvinte?.aoVoltar(ms) }
                }
                ultimoQuadroNs = agora
                if (!mjpeg && (querOuvir || trilhaDaFita != null || ramaisDaFita.isNotEmpty())) somDoQuadro(ts)
                if (!guardarQuadro(ts)) { soltosPelaTaxa++; continue }
                contarChegada(agora)
                val t0 = System.nanoTime()
                // Decodifica uma vez, só se alguém vai usar o quadro: o espelhamento (o Image dele),
                // a prévia na tela ou a gravação (as duas pela GPU).
                // O espelhamento só decodifica se o quadro vai de fato: novo e com Image livre.
                val usarEspelho = synchronized(trava) {
                    escritor != null && agora - ts <= VELHO_NS && livres > 0
                }
                val usarGravacao = gravador != null
                val usarFoto = pedidoDeFoto != null
                // (alvoPrevia não nulo com a tela já sem superfície: um quadro a mais solta o alvo)
                val usarPrevia = PreviaDv.superficie != null || alvoPrevia != null
                if ((usarEspelho || usarGravacao || usarPrevia || usarFoto) && QuallDv.decodificar(h) == 0) {
                    if (usarEspelho) converterSeLigada(ts, agora)
                    if (usarGravacao) gravarQuadro(ts)
                    if (usarPrevia) renderizarPrevia()
                    if (usarFoto) entregarFoto()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) dica?.let { runCatching { it.reportActualWorkDuration(System.nanoTime() - t0) } }
                }
                if (agora - ultimoLog > 10_000_000_000L) {
                    ultimoLog = agora
                    Log.i(TAG, "dv: sessao_quadros=$quadrosNaSessao velhos=$velhos sem_imagem=$semImagem " +
                        "falhas=$falhasDeConversao aspecto169=$aspecto169; ${resumo()}")
                }
            }
        } catch (t: Throwable) {
            // Uma exceção aqui mataria o processo (thread sem tratador); vira queda com motivo.
            Log.e(TAG, "a thread da DV morreu", t)
            cair(frase(R.string.placa_leitura_falhou, "${t.javaClass.simpleName}: ${t.message}"))
        } finally {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) runCatching { dica?.close() }
            runCatching { soltarTrilhaDaFita() }
            ouvindoAFita = false
            runCatching { soltarGpu() }
        }
    }

    // ---------------------------------------------------------------- os quadros que chegam (§14.11)

    /**
     * **Os quadros por segundo que de fato saem da fonte** (depois de soltar os a mais, [guardarQuadro]),
     * medidos na última janela de 2 s; 0 antes da primeira. A tela os mostra ao lado do que a placa promete
     * (a ezcap no A07 promete 60 e entrega 16, §14.10).
     */
    @Volatile var quadrosChegando: Double = 0.0
        private set
    private var janelaDesdeNs = 0L
    private var quadrosNaJanela = 0

    private fun contarChegada(agoraNs: Long) {
        if (janelaDesdeNs == 0L) { janelaDesdeNs = agoraNs; quadrosNaJanela = 0; return }
        quadrosNaJanela++
        val dt = agoraNs - janelaDesdeNs
        if (dt >= 2_000_000_000L) {
            quadrosChegando = quadrosNaJanela * 1e9 / dt
            janelaDesdeNs = agoraNs
            quadrosNaJanela = 0
        }
    }

    // ---------------------------------------------------------------- menos quadros que a placa (§14.6)

    private var proximoDevidoNs = 0L
    private var restoDoPassoNs = 0L
    private var contagemDaTaxa = 0L
    @Volatile var soltosPelaTaxa = 0L
        private set

    /**
     * A pessoa pediu menos quadros por segundo do que a placa manda ([fpsAlvo]): vale o quadro que cai na
     * grade do alvo (com meio intervalo da placa de folga para o carimbo, que é o da chegada); os outros
     * são soltos antes de decodificar. 60 → 30 guarda um de cada dois; 60 → 24, dois de cada cinco.
     */
    private fun guardarQuadro(ts: Long): Boolean {
        val alvo = fpsAlvo
        if (alvo <= 0) return true
        // Múltiplo exato (60 → 30, 120 → 24): um de cada N pela contagem, e não pelo carimbo — a chegada
        // dos quadros a 120/s oscila alguns ms, e a grade pelo tempo escolhia o vizinho em ~9 % deles
        // (medido: intervalos de 34 e 50 ms no lugar de 42).
        if (quadrosDaPlaca % alvo == 0) return (contagemDaTaxa++ % (quadrosDaPlaca / alvo)) == 0L
        val passo = 1_000_000_000L / alvo
        if (proximoDevidoNs == 0L || ts - proximoDevidoNs > 2 * passo) { proximoDevidoNs = ts; restoDoPassoNs = 0 }
        if (ts + 500_000_000L / quadrosDaPlaca < proximoDevidoNs) return false
        // O resto da divisão não se perde (24 por segundo: 41 666 666,67 ns).
        restoDoPassoNs += 1_000_000_000L % alvo
        proximoDevidoNs += passo + restoDoPassoNs / alvo
        restoDoPassoNs %= alvo
        return true
    }

    // ---------------------------------------------------------------- gravação e prévia

    /**
     * A gravação: a superfície do encoder dela (a fita: 1280×720 e o som do DV; a placa: o tamanho
     * nativo, e o som por fora, [SomDaPlaca]).
     */
    interface SaidaDeGravacao {
        val superficie: Surface
        val largura: Int
        val altura: Int
        /** O som do quadro [n] em 48 kHz estéreo s16 intercalado, ancorado no quadro. Thread `quall-dv`. */
        fun aoSom(pcm: java.nio.ByteBuffer, amostras: Int, n: Long)
        /** O quadro [n] foi à superfície, com o PTS de mídia n × 1001/30000 s (a placa: pela chegada). */
        fun aoQuadro(n: Long)
        /** Placa: o carimbo (CLOCK_MONOTONIC, ns) do primeiro quadro, o zero do arquivo. */
        fun aoPrimeiroQuadro(tsNs: Long) {}
        /** Placa: o carimbo do quadro que acabou de ir ao encoder (o fim do vídeo, para o som). */
        fun aoQuadroCarimbado(tsNs: Long) {}
    }

    private val travaDaGravacao = Any()
    @Volatile private var gravador: SaidaDeGravacao? = null
    private var escritorDaGravacao: ImageWriter? = null
    private var livresDaGravacao = 0
    private var quadrosGravados = 0L
    /** Placa: o carimbo do primeiro quadro gravado (o zero do arquivo); -1 antes dele. */
    private var t0DaGravacao = -1L
    @Volatile var videoPerdidoNaGravacao = 0L
        private set
    @Volatile var somCorrigido = 0L
        private set
    private val corrigidas = LongArray(1)
    private val bufSom48: java.nio.ByteBuffer =
        java.nio.ByteBuffer.allocateDirect(32000).order(java.nio.ByteOrder.nativeOrder())

    /**
     * Liga a gravação: a fila passa a FIFO funda, e cada quadro vai, pelo caminho YUV provado no
     * espelhamento (ImageWriter com dataspace BT.601, sem RGB no meio: o super-branco da fita passa
     * e a matriz de cor não é a do encoder), para a superfície do encoder da gravação, com o som.
     */
    fun ligarGravador(g: SaidaDeGravacao) {
        synchronized(travaDaGravacao) {
            val w = novoEscritor(g.superficie)
            w.setOnImageReleasedListener({
                synchronized(travaDaGravacao) { livresDaGravacao++; (travaDaGravacao as Object).notifyAll() }
            }, Handler(imagens.looper))
            escritorDaGravacao = w
            livresDaGravacao = MAX_IMAGENS
            quadrosGravados = 0
            t0DaGravacao = -1L
            videoPerdidoNaGravacao = 0
            corrigidas[0] = 0
            QuallDv.modoGravacao(h, true)
            gravador = g
        }
    }

    /** Solta a gravação. Quando volta, nenhum quadro está indo para ela. */
    fun desligarGravador() {
        synchronized(travaDaGravacao) {
            gravador = null
            escritorDaGravacao?.let { runCatching { it.close() } }
            escritorDaGravacao = null
            runCatching { QuallDv.modoGravacao(h, false) }
            Log.i(TAG, "gravação solta: quadros=$quadrosGravados video_perdido=$videoPerdidoNaGravacao " +
                "som_corrigido=${corrigidas[0]} amostras; ${resumo()}")
        }
    }

    /**
     * O quadro decodificado vai à gravação: na fita, o som dele (sempre) e a imagem se houver Image
     * livre; na placa, só a imagem (o som vem do `AudioRecord`, [SomDaPlaca]), no tamanho nativo e
     * carimbada pela chegada ([ts], CLOCK_MONOTONIC, relativo ao primeiro quadro gravado).
     */
    private fun gravarQuadro(ts: Long) {
        synchronized(travaDaGravacao) {
            val g = gravador ?: return
            val w = escritorDaGravacao ?: return
            // O índice anda por quadro recebido, e não por quadro desenhado: o som e o vídeo ficam
            // no mesmo tempo de mídia mesmo quando uma imagem não sai (a revisão, A8).
            val n = quadrosGravados++
            if (mjpeg) {
                if (t0DaGravacao < 0) { t0DaGravacao = ts; g.aoPrimeiroQuadro(ts) }
            } else {
                val a = QuallDv.somGravacao(h, n, bufSom48, corrigidas)
                somCorrigido = corrigidas[0]
                if (a > 0) {
                    bufSom48.position(0).limit(a * 4)
                    g.aoSom(bufSom48, a, n)
                    bufSom48.clear()
                }
            }
            // O encoder pode segurar as Images um pouco: espera até 40 ms (a fila funda do C segura a
            // câmera enquanto isso), em vez de perder o quadro na hora.
            val limite = System.nanoTime() + 40_000_000L
            while (livresDaGravacao <= 0 && System.nanoTime() < limite) {
                (travaDaGravacao as Object).wait(5)
            }
            if (livresDaGravacao <= 0) { videoPerdidoNaGravacao++; return }
            val img = try { w.dequeueInputImage() } catch (e: Exception) {
                videoPerdidoNaGravacao++
                Log.w(TAG, "gravação: o escritor recusou: ${Log.erroExterno(e.message)}")
                return
            }
            livresDaGravacao--
            var foi = false
            try {
                val p = img.planes
                // A fita: 720x480 → 1280x720 com o luma em Catmull-Rom (o HQ). A placa: o tamanho
                // nativo pelo `escrever` do espelhamento (4:2:2/4:2:0 → 4:2:0, sem ampliar e sem
                // compressão de faixa, §3.5).
                val r = if (p.size < 3) -3 else if (mjpeg) QuallDv.escrever(
                    h, p[0].buffer, p[0].rowStride, p[1].buffer, p[2].buffer, p[1].rowStride,
                    p[1].pixelStride, img.width, img.height)
                else QuallDv.escreverHq(
                    h, p[0].buffer, p[0].rowStride, p[1].buffer, p[2].buffer, p[1].rowStride,
                    p[1].pixelStride, img.width, img.height)
                if (r == 0) {
                    img.timestamp = if (mjpeg) ts - t0DaGravacao else n * 1001L * 1_000_000_000L / 30_000L
                    w.queueInputImage(img)
                    foi = true
                    g.aoQuadro(n)
                    if (mjpeg) g.aoQuadroCarimbado(ts)
                } else {
                    videoPerdidoNaGravacao++
                }
            } catch (e: Exception) {
                videoPerdidoNaGravacao++
                Log.w(TAG, "gravação: quadro $n não foi: ${Log.erroExterno(e.message)}")
            } finally {
                if (!foi) { runCatching { img.close() }; livresDaGravacao++ }
            }
        }
    }

    // ---------------------------------------------------------------- o som da placa pelo USB (§13.10)

    private val travaDoSomUsb = Any()
    @Volatile private var somUsbFechado = false

    /**
     * **O som da placa lido do endpoint isócrono** (48 kHz mono, 20 ms por quadro), como
     * [com.quall.android.audio.FonteDeAudio]: o que o `DonoDaPlaca` reparte em ramais no lugar do
     * `AudioRecord`. A hora do quadro é a da chegada do pacote (o relógio do vídeo). A placa manda uma
     * componente contínua (−380 a −420 em 32768, medido): um passa-altas de um polo (~8 Hz) a tira.
     * **Um leitor só** (o anel do C tem um cursor).
     */
    fun somUsb(): com.quall.android.audio.FonteDeAudio? {
        if (!temSomUsb || somUsbFechado) return null
        return object : com.quall.android.audio.FonteDeAudio {
            private val buf = java.nio.ByteBuffer.allocateDirect(QUADRO_DA_REDE * 2).order(java.nio.ByteOrder.nativeOrder())
            private val amostras = buf.asShortBuffer()
            private val instante = LongArray(1)
            private var hora: Long? = null
            private var x1 = 0.0
            private var y1 = 0.0
            private var esvaziado = false
            private var ultimoNs = 0L
            private val intervalos = LongArray(6)
            @Volatile private var fechada = false
            override val nome: String get() = "som da placa (USB)"
            override val ritmadaPeloDispositivo: Boolean get() = true
            override fun instanteDoQuadroUs(): Long? = hora
            override fun proximoQuadro(pcm: ShortArray): Int {
                if (pcm.size < QUADRO_DA_REDE) return 0
                val n = synchronized(travaDoSomUsb) {
                    if (fechada || somUsbFechado) return@synchronized -1
                    if (!esvaziado) {
                        // O anel do C guarda até 1 s enquanto ninguém lê: o leitor novo começa do agora.
                        esvaziado = true
                        var k = 0
                        while (k++ < 60 && QuallDv.lerSom(h, buf, QUADRO_DA_REDE, 0, instante) > 0) { }
                    }
                    QuallDv.lerSom(h, buf, QUADRO_DA_REDE, 200, instante)
                }
                if (n < 0) { Thread.sleep(20); return 0 }
                if (n == 0) return 0
                for (i in 0 until n) {
                    val x = amostras.get(i).toDouble()
                    val y = x - x1 + 0.999 * y1
                    x1 = x; y1 = y
                    pcm[i] = y.coerceIn(-32768.0, 32767.0).toInt().toShort()
                }
                hora = instante[0]
                // A cadência da entrega (§13.11): o intervalo entre quadros, em faixas de ms.
                val agora = System.nanoTime()
                if (ultimoNs != 0L) {
                    val ms = (agora - ultimoNs) / 1_000_000
                    intervalos[if (ms < 10) 0 else if (ms < 18) 1 else if (ms < 23) 2 else if (ms < 30) 3 else if (ms < 50) 4 else 5]++
                }
                ultimoNs = agora
                return n
            }
            override fun interromper() { fechada = true }
            override fun fechar() {
                fechada = true
                Log.i(TAG, "som da placa pelo USB: leitor fechado; intervalo entre quadros: <10ms=${intervalos[0]} 10-18=${intervalos[1]} " +
                    "18-23=${intervalos[2]} 23-30=${intervalos[3]} 30-50=${intervalos[4]} >=50=${intervalos[5]}")
            }
        }
    }

    // ---------------------------------------------------------------- ouvir a fita (§13.7)

    /**
     * **Ouvir o som da fita no telefone**: o PCM de cada quadro DV que chega (o primeiro par de
     * canais, na taxa da fita: 48, 44,1 ou 32 kHz), tocado num `AudioTrack` estéreo. Funciona na
     * prévia, gravando e transmitindo (o som da gravação é outro caminho, [gravarQuadro]).
     *
     * A escrita **não bloqueia** (a thread `quall-dv` não pode esperar a saída de som): a trilha
     * guarda [MS_DA_TRILHA] ms; o que não couber cai, e a latência não passa disso. Um quadro que a
     * fila solta (fora da gravação, só o mais novo fica) é um buraco de 33 ms no som.
     */
    @Volatile var ouvindoAFita = false
        private set
    @Volatile private var querOuvir = false
    private var trilhaDaFita: android.media.AudioTrack? = null  // só na thread `quall-dv`
    private var taxaDaTrilha = 0
    private var tocadasDaFita = 0L
    private var caidasDaFita = 0L
    private val taxaDoQuadro = IntArray(1)
    private val bufOuvir: java.nio.ByteBuffer =
        java.nio.ByteBuffer.allocateDirect(8000).order(java.nio.ByteOrder.nativeOrder())

    /** Liga ou desliga o ouvir da fita; vale no quadro seguinte. Só a filmadora DV. */
    fun ouvirFita(ligar: Boolean) {
        if (mjpeg) return
        querOuvir = ligar
        ouvindoAFita = ligar
    }

    /** O som do quadro que acabou de chegar ([ts], ns de `MONOTONIC`): para o ouvir e para a rede. */
    private fun somDoQuadro(ts: Long) {
        if (!querOuvir) soltarTrilhaDaFita()
        val rede = ramaisDaFita.isNotEmpty()
        if (!querOuvir && !rede) return
        val n = QuallDv.som(h, bufOuvir, taxaDoQuadro)
        if (n <= 0) return
        val taxa = taxaDoQuadro[0]
        if (rede) runCatching { paraOsRamais(n, taxa, ts) }
        if (!querOuvir) return
        if (trilhaDaFita == null || taxa != taxaDaTrilha) {
            soltarTrilhaDaFita()
            val t = runCatching {
                val estereo = android.media.AudioFormat.CHANNEL_OUT_STEREO
                val min = android.media.AudioTrack.getMinBufferSize(taxa, estereo, android.media.AudioFormat.ENCODING_PCM_16BIT)
                android.media.AudioTrack.Builder()
                    .setAudioAttributes(android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build())
                    .setAudioFormat(android.media.AudioFormat.Builder()
                        .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(taxa)
                        .setChannelMask(estereo)
                        .build())
                    .setTransferMode(android.media.AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(maxOf(min, taxa * MS_DA_TRILHA / 1000 * 4))
                    .build()
            }.getOrNull()
            if (t == null || t.state != android.media.AudioTrack.STATE_INITIALIZED) {
                t?.release()
                querOuvir = false
                ouvindoAFita = false
                Log.w(TAG, "ouvir a fita: o telefone não abriu a saída de som ($taxa Hz)")
                return
            }
            t.play()
            trilhaDaFita = t
            taxaDaTrilha = taxa
            Log.i(TAG, "ouvir a fita: ligado (AudioTrack $taxa Hz estéreo, buffer ${t.bufferSizeInFrames} quadros)")
        }
        bufOuvir.position(0).limit(n * 4)
        val w = trilhaDaFita!!.write(bufOuvir, n * 4, android.media.AudioTrack.WRITE_NON_BLOCKING)
        bufOuvir.clear()
        if (w > 0) tocadasDaFita += w / 4
        if (w < n * 4) caidasDaFita += n - maxOf(w, 0) / 4
    }

    // ---------------------------------------------------------------- o som da fita na rede (§13.8)

    /**
     * **O som da fita como [com.quall.android.audio.FonteDeAudio]** (a transmissão): o PCM de cada
     * quadro DV (o primeiro par de canais), somado em mono, levado a 48 kHz (a fita em 32 ou 44,1 kHz
     * por interpolação linear) e cortado em quadros de 20 ms, com a hora da primeira amostra (a da
     * chegada do quadro DV, o mesmo relógio do vídeo). Sem `AudioRecord`: **não pede o microfone**.
     *
     * Com a fita parada (nenhum quadro DV chegando), o ramal entrega **silêncio no ritmo do relógio**:
     * a leitura do `MicrofoneCompartilhado` desiste depois de 500 quadros vazios, e o som não pode
     * desligar sozinho numa pausa longa. Um quadro que a fila do C solta (fora da gravação, só o mais
     * novo fica) é um buraco de 33 ms.
     */
    inner class RamalDaFita internal constructor() : com.quall.android.audio.FonteDeAudio {
        private inner class Q(val pcm: ShortArray, val us: Long)
        private val fila = java.util.concurrent.ArrayBlockingQueue<Q>(FILA_DA_FITA)
        @Volatile private var fechado = false
        private var horaUs: Long? = null
        private var emSilencio = false
        private var proximoSilencioNs = 0L
        private var proximoNs = 0L
        @Volatile var caidos = 0L
            private set

        override val nome: String get() = "som da fita"
        override val ritmadaPeloDispositivo: Boolean get() = true
        override fun instanteDoQuadroUs(): Long? = horaUs

        internal fun entregar(pcm: ShortArray, us: Long) {
            val q = Q(pcm, us)
            while (!fila.offer(q)) { fila.poll(); caidos++ }
        }

        override fun proximoQuadro(pcm: ShortArray): Int {
            if (fechado || pcm.size < QUADRO_DA_REDE) return 0
            val q = try {
                if (emSilencio) fila.poll() else fila.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) { Thread.currentThread().interrupt(); return 0 }
            if (q != null) {
                emSilencio = false
                // Um quadro DV (33 ms) dá um ou dois quadros de 20 ms de uma vez: a saída é cadenciada
                // (20 ms; 19 com mais de três na fila, para o relógio da filmadora não a encher), senão
                // os pacotes chegam ao receptor em rajadas (71 ms de atraso medidos no S24, §13.8).
                val agora = System.nanoTime()
                if (proximoNs < agora - 40_000_000L) proximoNs = agora
                val falta = proximoNs - agora
                if (falta > 0) Thread.sleep(falta / 1_000_000, (falta % 1_000_000).toInt())
                proximoNs += if (fila.size > 3) 19_000_000L else 20_000_000L
                System.arraycopy(q.pcm, 0, pcm, 0, QUADRO_DA_REDE)
                horaUs = q.us
                return QUADRO_DA_REDE
            }
            if (fechado || caiu) { Thread.sleep(20); return 0 }
            // A fita parada: silêncio, 20 ms a cada 20 ms.
            val agora = System.nanoTime()
            if (!emSilencio) { emSilencio = true; proximoSilencioNs = agora }
            val falta = proximoSilencioNs - agora
            if (falta > 0) Thread.sleep(falta / 1_000_000, (falta % 1_000_000).toInt())
            proximoSilencioNs += 20_000_000L
            java.util.Arrays.fill(pcm, 0, QUADRO_DA_REDE, 0)
            horaUs = System.nanoTime() / 1000 - 20_000
            return QUADRO_DA_REDE
        }

        override fun interromper() { fechado = true }

        override fun fechar() {
            fechado = true
            if (ramaisDaFita.remove(this)) Log.i(TAG, "som da fita: ramal solto (caidos_na_fila=$caidos)")
        }
    }

    private val ramaisDaFita = java.util.concurrent.CopyOnWriteArrayList<RamalDaFita>()

    /** Um ramal novo do som da fita (só a filmadora DV), ou `null`. */
    fun ramalDoSomDaFita(): com.quall.android.audio.FonteDeAudio? {
        if (mjpeg || caiu) return null
        return RamalDaFita().also { ramaisDaFita.add(it); Log.i(TAG, "som da fita: ramal aberto (48 kHz mono, 20 ms)") }
    }

    // Só na thread `quall-dv`: o acumulador de 20 ms e o estado do reamostrador.
    private var acumDaFita = ShortArray(QUADRO_DA_REDE)
    private var nAcumDaFita = 0
    private var faseDaFita = 0.0
    private var anteriorDaFita = 0
    private var taxaDaRede = 0

    private fun paraOsRamais(n: Int, taxa: Int, ts: Long) {
        val s = bufOuvir.duplicate().order(java.nio.ByteOrder.nativeOrder()).apply { position(0); limit(n * 4) }.asShortBuffer()
        if (taxa != taxaDaRede) { taxaDaRede = taxa; faseDaFita = 0.0; anteriorDaFita = 0 }
        // A hora da primeira amostra ainda no acumulador: a chegada do quadro menos o que já estava lá.
        var inicioUs = ts / 1000 - nAcumDaFita * 1_000_000L / TAXA_DA_REDE
        fun por(v: Int) {
            acumDaFita[nAcumDaFita++] = v.toShort()
            if (nAcumDaFita == QUADRO_DA_REDE) {
                for (r in ramaisDaFita) r.entregar(acumDaFita.copyOf(), inicioUs)
                nAcumDaFita = 0
                inicioUs += 20_000
            }
        }
        if (taxa == TAXA_DA_REDE) {
            for (i in 0 until n) por((s.get(2 * i) + s.get(2 * i + 1)) / 2)
            return
        }
        // Interpolação linear: [faseDaFita] é a posição da próxima saída, em amostras de entrada,
        // contada a partir da amostra anterior (-1) deste quadro.
        val passo = taxa.toDouble() / TAXA_DA_REDE
        var i = 0
        var a = anteriorDaFita
        var b = (s.get(0) + s.get(1)) / 2
        while (true) {
            while (faseDaFita >= 1.0) {
                faseDaFita -= 1.0
                i++
                if (i >= n) { anteriorDaFita = b; return }
                a = b
                b = (s.get(2 * i) + s.get(2 * i + 1)) / 2
            }
            por((a + (b - a) * faseDaFita).toInt())
            faseDaFita += passo
        }
    }

    private fun soltarTrilhaDaFita() {
        val t = trilhaDaFita ?: return
        trilhaDaFita = null
        runCatching { t.pause(); t.flush() }
        runCatching { t.release() }
        Log.i(TAG, "ouvir a fita: desligado; tocadas=$tocadasDaFita amostras, caidas_pela_latencia=$caidasDaFita")
        tocadasDaFita = 0
        caidasDaFita = 0
    }

    // ---------------------------------------------------------------- a foto (§11, item 6; a DV, §13)

    /** Os planos de um quadro decodificado, copiados (a memória do C muda no quadro seguinte). */
    class QuadroYuv(val y: ByteArray, val u: ByteArray, val v: ByteArray, val geometria: Geometria)

    @Volatile private var pedidoDeFoto: ((QuadroYuv?) -> Unit)? = null

    /**
     * Pede o próximo quadro decodificado: a placa, e a filmadora DV (os planos já desentrelaçados, em
     * 4:1:1; a foto estica para o aspecto dela, `docs/placa-de-captura-usb.md` §13). [aoTer] é chamado
     * **na thread `quall-dv`** (tem de só repassar) com os planos copiados, ou `null` se o pedido não
     * serve. Um pedido novo substitui o anterior.
     */
    fun pedirFoto(aoTer: (QuadroYuv?) -> Unit) {
        pedidoDeFoto = aoTer
    }

    /** Desiste do pedido (o prazo de quem pediu venceu). */
    fun esquecerFoto() { pedidoDeFoto = null }

    private fun entregarFoto() {
        val cb = pedidoDeFoto ?: return
        pedidoDeFoto = null
        val q = runCatching {
            val g = Geometria.de(QuallDv.geometria(h))
            @Suppress("UNCHECKED_CAST")
            val p = QuallDv.planos(h) as Array<java.nio.ByteBuffer>
            fun copia(b: java.nio.ByteBuffer, n: Int) = ByteArray(n).also { b.duplicate().apply { position(0); limit(n) }.get(it) }
            QuadroYuv(copia(p[0], g.larguraY * g.alturaY), copia(p[1], g.larguraC * g.alturaC),
                copia(p[2], g.larguraC * g.alturaC), g)
        }.onFailure { Log.w(TAG, "foto: os planos não vieram: ${Log.erroExterno(it.message)}") }.getOrNull()
        runCatching { cb(q) }
    }

    private fun novoEscritor(s: Surface): ImageWriter =
        if (Build.VERSION.SDK_INT >= 33) {
            // O formato vai pelo HardwareBuffer (YCBCR_420_888 = 0x23): `setImageFormat` seguido de
            // `setDataSpace` deu RGBA no S24 (vale a última chamada).
            ImageWriter.Builder(s)
                .setMaxImages(MAX_IMAGENS)
                .setHardwareBufferFormat(HardwareBuffer.YCBCR_420_888)
                .setDataSpace(if (hd) DataSpace.DATASPACE_BT709 else DataSpace.DATASPACE_BT601_525)
                .build()
        } else {
            escritorYuv420(s, MAX_IMAGENS)
        }

    private var gpu: RenderizadorDv? = null
    private var gpuFalhou = false
    private var planos: Array<java.nio.ByteBuffer>? = null
    private var geometriaDosPlanos: Geometria? = null
    private var alvoPrevia: RenderizadorDv.Alvo? = null
    private var versaoDaPrevia = -1

    /**
     * A prévia na tela, pela GPU. Uma falha aqui desliga a prévia e **não** derruba a câmera: o
     * espelhamento e a gravação seguem (a revisão, A7).
     */
    private fun renderizarPrevia() {
        if (gpuFalhou) return
        try {
            val r = gpu ?: RenderizadorDv().also {
                if (!it.iniciar()) { gpuFalhou = true; Log.e(TAG, "a GPU não subiu: sem prévia"); return }
                gpu = it
                geometriaDosPlanos = null  // um renderizador novo não tem textura nenhuma
            }
            // A geometria dos planos (a do MJPEG só se sabe depois do primeiro JPEG, e segue o que
            // o decodificador disser; a da DV só muda o aspecto): mudou, os ByteBuffers e as
            // texturas são refeitos.
            val g = Geometria.de(QuallDv.geometria(h))
            if (g != geometriaDosPlanos) {
                @Suppress("UNCHECKED_CAST")
                planos = QuallDv.planos(h) as Array<java.nio.ByteBuffer>
                r.configurar(g)
                geometriaDosPlanos = g
            }
            // Prazo de 50 ms na trava: a tela destruindo a superfície não espera o quadro, e o
            // quadro não espera a tela.
            if (!PreviaDv.trava.tryLock(50, java.util.concurrent.TimeUnit.MILLISECONDS)) return
            try {
                if (PreviaDv.versao != versaoDaPrevia) {
                    alvoPrevia?.let { r.soltar(it) }
                    alvoPrevia = PreviaDv.superficie?.let { r.alvo(it, PreviaDv.largura, PreviaDv.altura) }
                    versaoDaPrevia = PreviaDv.versao
                }
                val alvo = alvoPrevia ?: return
                r.subir(planos!!)
                r.desenhar(alvo, g.aspectoN, g.aspectoD)
            } finally {
                PreviaDv.trava.unlock()
            }
        } catch (t: Throwable) {
            gpuFalhou = true
            Log.e(TAG, "a prévia falhou e foi desligada (a câmera segue)", t)
        }
    }

    private fun soltarGpu() {
        val r = gpu ?: return
        runCatching { alvoPrevia?.let { r.soltar(it) } }
        alvoPrevia = null
        runCatching { r.liberar() }
        gpu = null
    }

    /**
     * Devolve `true` se um quadro foi entregue ao encoder. Uma exceção do escritor (a superfície
     * abandonada quando o codec erra, antes de o `pararFonte` pegar a trava) conta como falha do
     * quadro, e não derruba a câmera; muitas seguidas, sim (a revisão do código, B2).
     */
    private fun converterSeLigada(ts: Long, agora: Long): Boolean = synchronized(trava) {
        val w = escritor ?: return false
        if (agora - ts > VELHO_NS) { velhos++; return false }
        if (livres <= 0) { semImagem++; return false }
        val img = try {
            w.dequeueInputImage()
        } catch (e: Exception) {
            falhaDoEscritor(e)
            return false
        }
        livres--
        var enfileirou = false
        try {
            val p = img.planes
            if (quadrosNaSessao == 0L && falhasDeConversao == 0L) {
                Log.i(TAG, "primeiro Image: ${img.width}x${img.height} formato=${img.format} planos=${p.size} " +
                    p.joinToString(" ") { "(row=${it.rowStride},px=${it.pixelStride},cap=${it.buffer.capacity()})" })
            }
            if (p.size < 3) {
                falhasDeConversao++
                if (falhasDeConversao == 1L) {
                    Log.e(TAG, "o Image do escritor não é YUV de 3 planos (formato ${img.format}, ${p.size} plano(s))")
                }
                return false
            }
            val r = QuallDv.escrever(
                h, p[0].buffer, p[0].rowStride, p[1].buffer, p[2].buffer, p[1].rowStride,
                p[1].pixelStride, img.width, img.height,
            )
            if (r == 0) {
                img.timestamp = ts
                w.queueInputImage(img)
                enfileirou = true
                quadrosNaSessao++
                falhasSeguidasDoEscritor = 0
            } else {
                falhasDeConversao++
                if (falhasDeConversao == 1L) Log.w(TAG, "conversão recusada: $r")
            }
        } catch (e: Exception) {
            falhaDoEscritor(e)
        } finally {
            if (!enfileirou) {
                // Fechada sem ir ao encoder: volta direto ao escritor, sem passar pelo ouvinte.
                runCatching { img.close() }
                livres++
            }
        }
        enfileirou
    }

    private var falhasSeguidasDoEscritor = 0

    private fun falhaDoEscritor(e: Exception) {
        falhasDeConversao++
        falhasSeguidasDoEscritor++
        if (falhasSeguidasDoEscritor == 1) Log.w(TAG, "o escritor recusou um quadro: ${e.javaClass.simpleName}: ${Log.erroExterno(e.message)}")
        if (falhasSeguidasDoEscritor == 90) {
            // Três segundos sem conseguir entregar: a superfície do encoder morreu.
            cair(frase(R.string.placa_encoder_parou, e.javaClass.simpleName))
        }
    }

    /** Para tudo e devolve o aparelho ao kernel. Chamado uma vez, pelo dono (o serviço). */
    fun fechar() {
        parar = true
        // Ninguém pode estar dentro do `lerSom` quando o C for liberado.
        somUsbFechado = true
        if (temSomUsb) runCatching { QuallDv.pararSom(h) }
        synchronized(travaDoSomUsb) { }
        runCatching { contexto.unregisterReceiver(desplugue) }
        thread.join(2000)
        desligar()
        if (thread.isAlive) {
            // Não dá para liberar a lib com a thread ainda dentro dela: vaza, e diz. E a conexão
            // fica aberta junto: fechar o fd com a thread de USB viva a poria girando em EBADF, ou
            // mandando ioctl para outro arquivo que herdasse o número (a revisão do código, B1).
            Log.w(TAG, "a thread da DV não saiu em 2 s; a lib e a conexão ficam abertas (vazamento consciente)")
            imagens.quitSafely()
            return
        }
        QuallDv.fechar(h)
        aberta?.soltar()
        imagens.quitSafely()
        Log.i(TAG, "fechada")
    }

    companion object {
        private const val TAG = "QuallDv"
        private const val MAX_IMAGENS = 3
        private const val PAUSA_NS = 1_000_000_000L
        /** O que a trilha do ouvir da fita guarda, em ms (o teto da latência). */
        private const val MS_DA_TRILHA = 200
        /** O som da fita na rede: 48 kHz mono em quadros de 20 ms (o preset do microfone). */
        const val TAXA_DA_REDE = 48_000
        private const val QUADRO_DA_REDE = TAXA_DA_REDE / 50
        /** Quadros de 20 ms que um ramal da fita segura (0,5 s) antes de soltar o mais velho. */
        private const val FILA_DA_FITA = 25
        /** Mais velho que isto não vai ao encoder: a sessão não começa com quadro de antes. */
        private const val VELHO_NS = 100_000_000L

        /**
         * Abre a filmadora pelo id da opção (`usb-dv:<deviceName>`). Lança
         * [IllegalStateException] com a frase para o usuário.
         */
        fun abrir(contexto: Context, id: String): FonteDv {
            val t = Idioma.textos(Idioma.contexto(contexto))
            if (!QuallDv.disponivel) throw IllegalStateException(t.s(R.string.placa_sem_leitor_dv))
            if (id.startsWith(UsbDv.PREFIXO_DO_ARQUIVO)) {
                val caminho = id.removePrefix(UsbDv.PREFIXO_DO_ARQUIVO)
                val h = QuallDv.abrirArquivo(caminho)
                if (h == 0L) throw IllegalStateException("o arquivo de bancada $caminho não abriu")  // i18n-fora: bancada (o arquivo DV da chave de bancada)
                return FonteDv(contexto.applicationContext, null, null, h).also { it.iniciar() }
            }
            val usb = contexto.getSystemService(UsbManager::class.java)
                ?: throw IllegalStateException(t.s(R.string.placa_sem_usb))
            UsbDv.lembrarEm(contexto)
            val dev = UsbDv.porId(usb, id) ?: throw IllegalStateException(t.s(R.string.placa_desplugado))
            val aberta = UsbDv.abrir(usb, dev, com.quall.android.core.Bancada.placaAlturaMax(contexto))
            val h = QuallDv.abrir(
                aberta.conexao.fileDescriptor, aberta.endpoint, aberta.psize, aberta.tipo.codigo,
                aberta.largura, aberta.altura, aberta.quadroMax,
                if (aberta.bulk) 1 else 0, aberta.payloadMax, aberta.cru,
            )
            if (h == 0L) {
                aberta.soltar()
                throw IllegalStateException(t.s(
                    if (aberta.tipo == TipoUsb.MJPEG) R.string.placa_leitura_da_placa_nao_comecou else R.string.placa_leitura_da_filmadora_nao_comecou))
            }
            val somUsb = aberta.somEndpoint != 0 && QuallDv.ligarSom(h, aberta.somEndpoint, aberta.somPsize, aberta.somPasso) == 0
            return FonteDv(contexto.applicationContext, dev, aberta, h, somUsb).also { it.iniciar() }
        }
    }
}
