package com.quall.android.mirror

import android.content.ContentValues
import android.content.Context
import android.media.CamcorderProfile
import android.media.EncoderProfiles
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.provider.MediaStore
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.audio.MicrofoneCompartilhado
import com.quall.android.audio.PresetDeAudio
import com.quall.android.capture.CopiaCrua
import com.quall.android.capture.DonoDaCaptura
import com.quall.android.capture.DivisorGl
import com.quall.android.capture.EtapaDaAbertura
import com.quall.android.capture.GravadorDaCamera
import com.quall.android.capture.MuxerDaGravacao
import com.quall.android.capture.MuxerMediaMuxer
import com.quall.android.capture.MuxerQuallDv
import com.quall.android.capture.ParametrosDaGravacao
import com.quall.android.capture.dv.QuallDv
import com.quall.android.core.Idioma
import com.quall.android.core.QuallNative
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * **Quem grava a câmera** — na tela R5 e, desde 24/09, no espelhamento de câmera comum
 * (`docs/teleprompter-com-camera.md` §5, fase 3, e §8.6): abre o arquivo na
 * Galeria, pendura o [GravadorDaCamera] no divisor do [DonoDaCaptura] e o som no microfone, vigia o
 * espaço e a câmera, e fecha e publica. Do [MirrorService], que o chama numa thread própria
 * (`quall-gravacao`): começar e parar nunca rodam juntos.
 *
 * **Reaproveita da fita (`GravacaoDvService`) só a parte de arquivo**: MediaStore em `Movies/Quall`
 * com `IS_PENDING` enquanto grava, o MP4 fragmentado, o `fsync` a cada 10 s, `PARTIAL_WAKE_LOCK`, o
 * limite de espaço, e os pendentes publicados na próxima abertura (`GravacaoDvService.publicarPendentes`,
 * que remonta o fragmentado). O tempo não: é o da câmera ([GravadorDaCamera]).
 *
 * **Sem a `libqualldv`** (o 32 bits, §14.4 da D1) quem escreve é o `MediaMuxer` ([MuxerMediaMuxer]),
 * com a cópia crua ao lado ([CopiaCrua]): o espaço conta em dobro, e o arquivo só é publicado se o
 * `MediaMuxer` fechou legível — senão fica pendente com a cópia, e a próxima abertura o remonta.
 *
 * **Não depende de sessão**: grava sem receptor, e o receptor conecta, cai e volta sem tocar no
 * arquivo (a rede e a gravação são duas saídas do mesmo divisor).
 */
internal class GravacaoDaTela(
    private val contexto: Context,
    /** O começo do nome do arquivo: `Quall-R5` na tela R5, `Quall-Camera` no espelhamento comum. */
    private val prefixo: String,
    /** O microfone da gravação: o serviço pendura (ou solta, com `null`) e abre ou fecha o microfone. */
    private val ligarSom: (MicrofoneCompartilhado.Gravacao?) -> Unit,
) {
    companion object {
        private const val TAG = "QuallGravacao"

        /** Para começar: ~9 min a 14 Mbit/s (1080p30, `ParametrosDaGravacao.taxa`). */
        const val ESPACO_PARA_COMECAR = 1_000_000_000L

        /** Abaixo disto, a gravação para e o arquivo é publicado (o da fita: `GravacaoDvService`). */
        const val ESPACO_MINIMO = 500_000_000L

        /** Sem quadro da câmera há tanto tempo, a gravação para: a câmera caiu. */
        private const val CAMERA_CAIDA_MS = 3_000L

        /** O primeiro quadro tem de chegar ao arquivo, e o MP4 abrir, em até isto. */
        private const val PRAZO_DO_PRIMEIRO_QUADRO_MS = 5_000L
    }

    @Volatile private var gravador: GravadorDaCamera? = null
    private var saida: DivisorGl.Saida? = null
    private var dono: DonoDaCaptura? = null
    private var arquivo: Uri? = null
    private var pfd: ParcelFileDescriptor? = null
    /** A cópia crua desta gravação ([MuxerMediaMuxer]), para apagar junto com um item que não vale. */
    private var arquivoDaCopia: java.io.File? = null

    /** O espaço conta em dobro com a cópia crua ao lado (§14.4). */
    private val fatorDeEspaco: Long get() = if (QuallDv.disponivel) 1L else 2L
    private var trava: PowerManager.WakeLock? = null
    @Volatile private var vigia: Thread? = null
    @Volatile private var pararPedido: String? = null
    private var nome = ""

    val gravando: Boolean get() = gravador != null

    /**
     * As frases que vão à tela (a recusa, a parada), no idioma do app **no momento em que saem**
     * (`docs/traducao.md`, Android): o serviço não é `AppCompatActivity`, daí o [Idioma.contexto].
     */
    private fun s(id: Int, vararg a: Any): String =
        Idioma.contexto(contexto).let { c -> if (a.isEmpty()) c.getString(id) else c.getString(id, *a) }

    /** A tela R5 fechou: nenhum começo mais (a revisão, bloqueio 1). Qualquer thread. */
    @Volatile var encerrada = false
        private set

    fun marcarEncerrada() { encerrada = true }

    /** O fim da tela: marca encerrada e para o que houver. Na thread da gravação. */
    fun encerrar(motivo: String) {
        encerrada = true
        parar(motivo)
    }

    /**
     * Começa. Devolve `null` quando o arquivo começou (o primeiro quadro entrou), ou o motivo legível
     * da recusa. Na thread `quall-gravacao`.
     */
    fun comecar(d: DonoDaCaptura?): String? {
        if (gravador != null) return null
        if (encerrada) return s(R.string.cam_recusa_tela_fechando)
        if (d == null || d.estaFechado) return s(R.string.cam_recusa_camera_fechada)
        // O que nem o `MediaMuxer` cobre (§14.3): a tela já diz antes do toque; isto é o pedido do
        // controle ou da bancada que chegou mesmo assim.
        GravacaoIndisponivel.motivo(contexto)?.let { return it }
        val livre = espacoLivre()
        val precisa = ESPACO_PARA_COMECAR * fatorDeEspaco
        if (livre < precisa) {
            return s(if (fatorDeEspaco > 1) R.string.cam_recusa_sem_espaco_dobro else R.string.cam_recusa_sem_espaco,
                livre / 1_000_000, precisa / 1_000_000)
        }
        if (!d.entregando(1_000)) return s(R.string.cam_recusa_sem_imagem)
        // A rotação lida uma vez, e o tamanho medido nela: lidos em momentos diferentes, um giro no
        // meio daria um quadro deitado com a imagem em pé (a revisão, menor).
        // A tela R5: a da tela; a câmera comum: a do aparelho (a revisão de 24/09, B1).
        val rotacao = d.rotacaoDeReferencia
        val natural = d.tamanhoNaTela(rotacao)
        // O recuo do §14.4, preparado e desligado: só com a chave de bancada.
        val tamanho = if (com.quall.android.core.Bancada.gravacaoTeto720(contexto)) {
            ParametrosDaGravacao.teto720(natural.width, natural.height).let { (w, h) -> android.util.Size(w, h) }
                .also { Log.i(TAG, "recuo de bancada: 720p (${natural.width}x${natural.height} → ${it.width}x${it.height})") }
        } else natural
        val fps = d.quadrosNegociados ?: d.fpsPedido
        val (taxa, deOnde) = ParametrosDaGravacao.taxa(perfis(d.cameraId), tamanho.width, tamanho.height, fps)
        val preset = PresetDeAudio.de(QuallNative.TrackKind.MICROPHONE)
        GravacaoDaTelaBus.atualizar { it.copy(fase = GravacaoDaTelaBus.Fase.COMECANDO, mensagem = "") }
        var falha: String? = null
        var muxer: MuxerDaGravacao? = null
        try {
            nome = "$prefixo-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".mp4"
            val cv = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, nome)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Quall")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val cr = contexto.contentResolver
            val uri = cr.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), cv)
                ?: throw IllegalStateException(s(R.string.cam_falha_galeria))
            arquivo = uri
            // "rw": o muxer volta ao começo no fim para escrever o `moov` (hybrid_fragmented).
            val f = cr.openFileDescriptor(uri, "rw") ?: throw IllegalStateException(s(R.string.cam_falha_arquivo_da_galeria))
            pfd = f
            val m: MuxerDaGravacao = if (QuallDv.disponivel) MuxerQuallDv(f.fd) else {
                // O `id` do MediaStore, e não o nome (que o MediaStore troca em colisão), nomeia a cópia.
                val dir = CopiaCrua.diretorio(contexto) ?: throw IllegalStateException(s(R.string.cam_falha_pasta_da_copia))
                val copia = CopiaCrua.arquivoDe(dir, android.content.ContentUris.parseId(uri))
                arquivoDaCopia = copia
                try {
                    MuxerMediaMuxer(f.fileDescriptor, CopiaCrua.Escritor(copia, android.content.ContentUris.parseId(uri), nome))
                } catch (e: Exception) {
                    throw GravadorDaCamera.FalhaAoAbrir("o MediaMuxer não abriu o arquivo: ${e.javaClass.simpleName}: ${e.message}", e,
                        transitoria = false, etapa = EtapaDaAbertura.ARQUIVO)
                }
            }
            muxer = m
            val g = GravadorDaCamera(
                muxer = m,
                larguraPedida = tamanho.width,
                alturaPedida = tamanho.height,
                fps = fps,
                bitrate = taxa,
                // O desempate da zona ambígua é da tela R5 só (a revisão da fase 2, M5).
                declaradoBoottime = d.timestampSourceRealtime && d.desempatePelaDeclaracao,
                taxaDoSom = preset?.taxaHz ?: 48_000,
                canaisDoSom = preset?.canais ?: 1,
                // A gravação aceita o dobro da rede em trânsito: um quadro velho no arquivo não atrasa
                // ninguém; o que a porta evita aqui é a troca presa na thread GL (§14.11).
                tetoDaFila = 2 * com.quall.android.core.Bancada.filaDoCodificadorQuadros(contexto),
            )
            gravador = g
            dono = d
            saida = d.ligarCodificador("gravacao", g.superficie, g.largura, g.altura, rotacaoFixa = rotacao, fila = g.fila)
            ligarSom(MicrofoneCompartilhado.Gravacao { pcm, n, t -> g.somDaCaptura(pcm, n, t) })
            trava = contexto.getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "quall:gravacao-r5")
                .also { it.acquire(12 * 60 * 60 * 1000L) }
            g.esperarComeco(PRAZO_DO_PRIMEIRO_QUADRO_MS)?.let { falta ->
                val motivo = when (falta) {
                    is GravadorDaCamera.FaltaNoComeco.SemPrimeiroQuadro -> s(R.string.cam_falta_primeiro_quadro, falta.segundos)
                    // O erro do gravador, quando há, é o detalhe técnico (o mesmo do diário).
                    is GravadorDaCamera.FaltaNoComeco.Mp4NaoAbriu -> falta.erro ?: s(R.string.cam_falta_mp4, falta.segundos)
                }
                if (g.falhouAoAbrir) throw GravadorDaCamera.FalhaAoAbrir(motivo, null, transitoria = false, etapa = EtapaDaAbertura.ARQUIVO)
                throw IllegalStateException(motivo)
            }
            GravacaoIndisponivel.gravou(contexto)
            val desde = SystemClock.elapsedRealtime()
            Log.i(TAG, "gravando: $nome em $uri — gravador=${g.nomeDoMuxer} ${g.largura}x${g.altura} a $fps fps, ${g.bitrate / 1000} kbit/s ($deOnde), " +
                "rotação congelada em ${rotacao * 90}° (de ${d.origemDaReferencia}), som ${preset?.taxaHz ?: 48_000} Hz x ${preset?.canais ?: 1}, " +
                "espaço livre ${livre / 1_000_000} MB")
            GravacaoDaTelaBus.atualizar {
                it.copy(fase = GravacaoDaTelaBus.Fase.GRAVANDO, desdeMs = desde, nome = nome, bytes = 0, espacoLivre = livre)
            }
            pararPedido = null
            vigia = Thread({ vigiar(g, d) }, "quall-gravacao-vigia").also { it.isDaemon = true; it.start() }
            return null
        } catch (e: Exception) {
            falha = e.message ?: e.javaClass.simpleName
            Log.e(TAG, "a gravação não começou: ${Log.erroExterno(falha)}", e)
            if (e is GravadorDaCamera.FalhaAoAbrir) {
                // Lembrada só a que não passa, e só na segunda (a revisão, 12): daí a tela já abre dizendo.
                GravacaoIndisponivel.falhouAoAbrir(contexto, falha, e.etapa, e.transitoria)?.let { motivo ->
                    GravacaoDaTelaBus.atualizar { it.copy(indisponivel = motivo) }
                }
            }
        }
        // O gravador que nem nasceu não fecha o muxer por nós: o `MediaMuxer` nasce antes dele.
        if (gravador == null) muxer?.let { m -> runCatching { m.fechar() } }
        fecharArquivo("a gravação não começou: $falha", publicarSeTiverAlgo = false) // i18n-fora: só o diário (sem publicar, a tela não recebe a frase)
        return falha
    }

    /**
     * O vigia, uma vez por segundo: o espaço, o erro do gravador e a câmera caída. Não para nada
     * sozinho: pede ao serviço ([aoPrecisarParar]), que para na thread de sempre.
     */
    @Volatile var aoPrecisarParar: ((String) -> Unit)? = null

    private fun vigiar(g: GravadorDaCamera, d: DonoDaCaptura) {
        try {
            while (gravador === g && pararPedido == null) {
                Thread.sleep(1_000)
                if (gravador !== g) return
                val livre = espacoLivre()
                GravacaoDaTelaBus.atualizar {
                    if (it.fase == GravacaoDaTelaBus.Fase.GRAVANDO) it.copy(bytes = g.bytes, espacoLivre = livre) else it
                }
                val motivo = when {
                    g.erro != null -> g.erro
                    livre < ESPACO_MINIMO * fatorDeEspaco -> s(R.string.cam_parou_sem_espaco, livre / 1_000_000)
                    d.estaFechado || !d.entregando(CAMERA_CAIDA_MS) -> s(R.string.cam_parou_sem_imagem)
                    else -> null
                }
                if (motivo != null) {
                    pararPedido = motivo
                    Log.w(TAG, "a gravação vai parar: ${Log.erroExterno(motivo)}")
                    aoPrecisarParar?.invoke(motivo)
                    return
                }
            }
        } catch (_: InterruptedException) {
        }
    }

    /**
     * Para, fecha e publica. [motivo] vai para a tela ("parada pelo botão", "o espaço acabou").
     * Idempotente. Na thread `quall-gravacao` (ou na de espelhamento, no fim da tela).
     */
    fun parar(motivo: String) {
        if (gravador == null) return
        GravacaoDaTelaBus.atualizar { it.copy(fase = GravacaoDaTelaBus.Fase.PARANDO) }
        fecharArquivo(motivo, publicarSeTiverAlgo = true)
    }

    private fun fecharArquivo(motivo: String, publicarSeTiverAlgo: Boolean) {
        val g = gravador
        // A ordem: nenhum quadro a mais (a saída do divisor sai), o som solto, o gravador fecha o
        // MP4, o arquivo é publicado.
        saida?.let { s -> runCatching { dono?.desligar(s) } }
        saida = null
        vigia?.interrupt()
        vigia = null
        // O som fica pendurado **durante** o fim (a revisão, menor): os últimos quadros do microfone
        // ainda chegam depois do último quadro de vídeo, e o gravador os corta no fim dele — soltar
        // antes deixava os últimos 50–100 ms em silêncio.
        val erro = g?.parar()
        runCatching { ligarSom(null) }
        var frase = motivo
        if (erro != null && !motivo.contains(erro)) frase = "$motivo ($erro)"
        var publicado = false
        val uri = arquivo
        val soComCopia = g != null && g.nomeDoMuxer == "mediamuxer"
        if (g != null && !g.terminou) {
            // O gravador não saiu: o fd fica aberto (fechá-lo com a thread escrevendo mandaria bytes
            // para outro arquivo que herdasse o número) e o arquivo fica pendente, para a próxima
            // abertura remontar e publicar.
            frase = s(R.string.cam_fica_para_recuperar, frase)
        } else if (soComCopia && publicarSeTiverAlgo && g!!.quadros > 0 && g.abriuOMp4 && !g.fechouLegivel) {
            // O `MediaMuxer` não fechou (sem `moov`, o arquivo não abre): ele fica pendente, com a
            // cópia crua guardada, e a próxima abertura remonta (a revisão, 7).
            runCatching { pfd?.close() }
            frase = s(R.string.cam_fica_para_recuperar, frase)
        } else {
            runCatching { pfd?.close() }
            if (uri != null) {
                val cr = contexto.contentResolver
                publicado = if (!publicarSeTiverAlgo || (g?.bytes ?: 0L) == 0L || (g?.quadros ?: 0L) == 0L) {
                    // Nada foi gravado: o item vazio não vai para a Galeria, e a cópia dele também sai
                    // (senão a próxima abertura a remontaria como uma gravação perdida).
                    runCatching { cr.delete(uri, null, null) }
                    arquivoDaCopia?.let { CopiaCrua.apagar(it) }
                    false
                } else runCatching {
                    cr.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null) > 0
                }.getOrElse { Log.w(TAG, "não publiquei $uri: ${Log.erroExterno(it.message)}"); false }
                // A cópia crua sai **só agora**, com o MP4 publicado (a revisão do código, 1). Sem a
                // publicação, o item fica pendente com ela, e a próxima abertura remonta.
                if (publicado) arquivoDaCopia?.let { c ->
                    CopiaCrua.apagar(c)
                    Log.i(TAG, "gravador: cópia crua apagada (o MP4 foi publicado)")
                }
            }
        }
        trava?.let { if (it.isHeld) it.release() }
        trava = null
        Log.i(TAG, "gravação parada: ${Log.erroExterno(frase)}; quadros=${g?.quadros ?: 0} duracao_ms=${g?.duracaoMs ?: 0} " +
            "bytes=${g?.bytes ?: 0} buracos=${g?.buracosDeVideo ?: 0} publicado=$publicado ${uri ?: ""}")
        gravador = null
        dono = null
        arquivo = null
        pfd = null
        arquivoDaCopia = null
        GravacaoDaTelaBus.atualizar {
            it.copy(
                fase = GravacaoDaTelaBus.Fase.PARADA, desdeMs = 0, bytes = 0,
                // Um começo que falhou não deixa frase aqui: quem fala é a recusa, com o motivo.
                mensagem = when {
                    publicado -> if (motivo.isNotBlank()) s(R.string.cam_gravacao_salva_motivo, nome, motivo) else s(R.string.cam_gravacao_salva, nome)
                    !publicarSeTiverAlgo -> ""
                    else -> frase
                },
            )
        }
    }

    private fun espacoLivre(): Long = runCatching {
        StatFs(Environment.getExternalStorageDirectory().path).availableBytes
    }.getOrDefault(Long.MAX_VALUE)

    /** Os perfis de gravação que o aparelho declara para esta câmera. */
    private fun perfis(cameraId: String): List<ParametrosDaGravacao.Perfil> {
        val qualidades = intArrayOf(
            CamcorderProfile.QUALITY_2160P, CamcorderProfile.QUALITY_1080P,
            CamcorderProfile.QUALITY_720P, CamcorderProfile.QUALITY_480P, CamcorderProfile.QUALITY_HIGH,
        )
        val saida = ArrayList<ParametrosDaGravacao.Perfil>()
        for (q in qualidades) {
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val p: EncoderProfiles = CamcorderProfile.getAll(cameraId, q) ?: return@runCatching
                    for (v in p.videoProfiles) {
                        if (v == null) continue
                        // Só H.264 e SDR (a revisão, menor 1): o perfil HEVC ou HDR do mesmo tamanho
                        // tem outra taxa, e o nosso gravador é H.264 BT.709.
                        if (v.codec != android.media.MediaRecorder.VideoEncoder.H264) continue
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            v.hdrFormat != EncoderProfiles.VideoProfile.HDR_NONE) continue
                        saida += ParametrosDaGravacao.Perfil(v.width, v.height, v.frameRate, v.bitrate)
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val p = CamcorderProfile.get(cameraId.toInt(), q)
                    if (p.videoCodec == android.media.MediaRecorder.VideoEncoder.H264) {
                        saida += ParametrosDaGravacao.Perfil(p.videoFrameWidth, p.videoFrameHeight, p.videoFrameRate, p.videoBitRate)
                    }
                }
            }
        }
        return saida
    }
}
