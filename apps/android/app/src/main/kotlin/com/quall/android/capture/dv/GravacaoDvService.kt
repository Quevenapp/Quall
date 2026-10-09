package com.quall.android.capture.dv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.provider.MediaStore
import com.quall.android.core.LogSeguro as Log
import androidx.core.app.NotificationCompat
import com.quall.android.R
import com.quall.android.core.Idioma
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

/**
 * **Gravar a fita no S24, sem espelhar.** Serviço em primeiro plano (tipo `camera`) com
 * `PARTIAL_WAKE_LOCK`: a fita de mais de uma hora grava com a tela desligada.
 *
 * O arquivo vai para a Galeria (MediaStore, `Movies/Quall`), com `IS_PENDING=1` enquanto grava. O
 * MP4 é `hybrid_fragmented` (ver [GravadorMp4]): cada fragmento de ~1 s já é legível, e ao fechar
 * vira MP4 comum. Um pendente que sobrou de um processo morto é publicado na próxima abertura
 * ([publicarPendentes]).
 *
 * Quando para:
 * - o botão Parar (ou a notificação);
 * - o cabo puxado, ou a filmadora desligada: o MP4 é fechado e publicado;
 * - 5 min sem quadro (a fita parada): fecha e publica;
 * - menos de [ESPACO_MINIMO] livre: fecha e publica.
 *
 * **A fonte é do dono único** ([DonoDaPlaca]): a gravação pega uma posse e a solta, e a prévia
 * parada da tela convive com ela. **A placa grava e transmite junto** (§11, item 4: o mesmo quadro e
 * o mesmo som vão à rede e ao arquivo); a filmadora DV não corre junto com o espelhamento (o dono
 * recusa a segunda posse).
 *
 * **A placa de captura** (MJPEG, a P4 adiantada, `docs/placa-de-captura-usb.md` §9.6) grava pelo
 * mesmo serviço: o vídeo no tamanho nativo (640x480) a [GravacaoDaPlaca.taxa], carimbado pela
 * chegada, e o som pelo `AudioRecord` da placa ([SomDaPlaca]), com o serviço também do tipo
 * `microphone` quando há a permissão. O nome do arquivo diz "Placa".
 */
class GravacaoDvService : Service() {
    @Volatile private var parar = false
    @Volatile private var trabalho: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACAO_PARAR) {
            parar = true
            if (trabalho == null) stopSelf()
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra(EXTRA_ID)
        if (id == null || trabalho != null) return START_NOT_STICKY
        comecarPrimeiroPlano(tx(R.string.placa_notif_preparando))
        parar = false
        trabalho = thread(name = "quall-gravacao") { gravar(id) }
        return START_NOT_STICKY
    }

    private fun gravar(id: String) {
        val pm = getSystemService(PowerManager::class.java)
        val trava = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "quall:gravacao-dv")
        trava.acquire(12 * 60 * 60 * 1000L)
        var fonte: FonteDv? = null
        var posse: DonoDaPlaca.Posse? = null
        var gravador: GravadorMp4? = null
        var somDaPlaca: SomDaPlaca? = null
        var placa = false
        var inicioDaGravacao = 0L
        var arquivo: Uri? = null
        var pfd: ParcelFileDescriptor? = null
        // `null`: a parada comum ("gravação encerrada"), dita no fim. Um dado, e não a frase, para a
        // decisão de baixo não depender do idioma (`docs/traducao.md`, Android).
        var motivo: String? = null
        GravacaoBus.publicar(GravacaoBus.Estado(fase = GravacaoBus.Fase.PREPARANDO))
        try {
            val livre = espacoLivre()
            if (livre < ESPACO_PARA_COMECAR) {
                motivo = tx(R.string.placa_motivo_sem_espaco, livre / 1_000_000, ESPACO_PARA_COMECAR / 1_000_000_000)
                return
            }
            var caiu: String? = null
            // A posse da gravação no dono único: a prévia parada da tela (e, na placa, a rede) podem
            // estar com a mesma fonte aberta (`DonoDaPlaca`).
            val p = DonoDaPlaca.pegar(this, id, DonoDaPlaca.Uso.GRAVACAO, object : FonteDv.Ouvinte {
                override fun aoPausar() { GravacaoBus.atualizar { it.copy(pausada = true) } }
                override fun aoVoltar(pausaMs: Long) { GravacaoBus.atualizar { it.copy(pausada = false) } }
                override fun aoCair(motivo: String) { caiu = motivo; parar = true }
            })
            posse = p
            val f = p.fonte
            fonte = f
            placa = f.mjpeg
            GravacaoBus.atualizar { it.copy(daPlaca = placa) }
            if (f.desconectada) throw IllegalStateException(tx(R.string.placa_camera_desconectada))
            val nome = (if (placa) "Quall-Placa-" else "Quall-DV-") + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".mp4"
            val cv = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, nome)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Quall")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), cv)
                ?: throw IllegalStateException(tx(R.string.placa_motivo_galeria_recusou))
            arquivo = uri
            // "rw": o muxer volta ao começo no fim para escrever o `moov` (hybrid_fragmented).
            pfd = contentResolver.openFileDescriptor(uri, "rw")
                ?: throw IllegalStateException(tx(R.string.placa_motivo_galeria_nao_abriu))
            // O som da placa pelo usbfs (§13.10) não precisa da permissão do microfone; pelo `AudioRecord`, sim.
            val comSom = placa && (f.temSomUsb || checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED)
            val codec = GravacaoDaPlaca.codec(this)
            val qualidade = GravacaoDaPlaca.qualidade(this)
            val taxaDaPlaca = GravacaoDaPlaca.taxaEscolhida(f.larguraDoQuadro, f.alturaDoQuadro, f.quadrosPorSegundo, codec, qualidade)
            val g = if (placa) {
                GravadorMp4(pfd.fd, f.larguraDoQuadro, f.alturaDoQuadro, taxaDaPlaca, daPlaca = true, comSom = comSom,
                    fps = f.quadrosPorSegundo, hd = f.hd, hevc = codec == GravacaoDaPlaca.Codec.HEVC)
            } else {
                GravadorMp4(pfd.fd)
            }
            gravador = g
            if (placa) {
                // O som da placa pelo `AudioRecord`: o serviço passa a ser também do tipo microphone
                // (Android 14+ exige; sem a permissão não se pede o tipo, e grava sem som). Pelo usbfs
                // (§13.10) não há `AudioRecord`: nem a permissão, nem o tipo.
                if (comSom && !f.temSomUsb && !microfoneNoPrimeiroPlano()) g.semSom(tx(R.string.placa_motivo_sistema_sem_microfone))
                if (!comSom) g.semSom(tx(R.string.placa_gravando_sem_permissao_microfone))
            }
            f.ligarGravador(g)
            // O som da placa é um ramal do `AudioRecord` dela, o mesmo da rede e do ouvir (§11).
            if (placa && g.avisoDoSom == null) somDaPlaca = SomDaPlaca.comecar(this, g)
            val inicio = SystemClock.elapsedRealtime()
            inicioDaGravacao = inicio
            if (placa) {
                Log.i(TAG, "gravação da placa: ${f.larguraDoQuadro}x${f.alturaDoQuadro} a ${GravacaoDaPlaca.FPS}, " +
                    "${taxaDaPlaca / 1_000_000} Mbit/s, som=${if (somDaPlaca != null) "o da placa" else "nenhum (${g.avisoDoSom})"}" +
                    (DonoDaPlaca.avisoDoSom?.let { " AVISO: $it" } ?: ""))
            }
            Log.i(TAG, "gravando em $uri ($nome)")
            GravacaoBus.publicar(GravacaoBus.Estado(fase = GravacaoBus.Fase.GRAVANDO, nome = nome, daPlaca = placa))
            atualizarNotificacao(tx(R.string.placa_notif_gravando, nome))
            var ultimoQuadroEm = SystemClock.elapsedRealtime()
            var quadrosAntes = -1L
            while (!parar) {
                Thread.sleep(1000)
                val agora = SystemClock.elapsedRealtime()
                if (g.quadros != quadrosAntes) { quadrosAntes = g.quadros; ultimoQuadroEm = agora }
                val livreAgora = espacoLivre()
                GravacaoBus.atualizar {
                    it.copy(quadros = g.quadros, bytes = g.bytes, espacoLivre = livreAgora,
                        decorridoMs = agora - inicio,
                        // A falha do som no gravador; senão o que o dono diz dele (o silêncio da
                        // entrada, ou a entrada que não é a placa).
                        avisoDoSom = g.avisoDoSom ?: if (somDaPlaca != null) DonoDaPlaca.avisoDoSom else null)
                }
                if (g.erro != null) { motivo = g.erro!!; break }
                if (livreAgora < ESPACO_MINIMO) { motivo = tx(R.string.placa_motivo_espaco_acabou, livreAgora / 1_000_000); break }
                if (agora - ultimoQuadroEm > PAUSA_MAXIMA_MS) {
                    motivo = tx(if (placa) R.string.placa_motivo_placa_parada else R.string.placa_motivo_fita_parada)
                    break
                }
            }
            caiu?.let { motivo = tx(R.string.placa_motivo_arquivo_fechado, it) }
        } catch (e: Exception) {
            val m = tx(R.string.placa_gravacao_falhou, e.message ?: e.javaClass.simpleName)
            motivo = m
            Log.e(TAG, m, e)
        } finally {
            // A ordem: nenhum quadro (nem som) a mais para o gravador, o gravador fecha o MP4, o
            // arquivo é publicado, e só então a posse volta ao dono (a fonte fecha se ninguém mais a
            // tem, e o aparelho volta ao kernel).
            // A placa: o vídeo para primeiro, e o som segue até o fim dele (§11, item 3: terminava
            // ~51 ms antes); só então o gravador fecha.
            fonte?.desligarGravador()
            somDaPlaca?.let { runCatching { it.encerrar() } }
            val erro = gravador?.parar()
            if (erro != null && motivo == null) motivo = erro
            val g = gravador
            var publicado = false
            if (g != null && !g.terminou) {
                // O gravador não terminou: o fd fica aberto (fechá-lo com a thread escrevendo
                // mandaria bytes para outro arquivo que herdasse o número), e o arquivo fica
                // pendente; a próxima abertura do app o remonta e publica.
                motivo = tx(R.string.placa_motivo_recuperar_depois, motivo ?: tx(R.string.placa_motivo_encerrada))
            } else {
                runCatching { pfd?.close() }
                publicado = arquivo?.let { uri ->
                    if ((g?.bytes ?: 0L) == 0L) {
                        // Nada foi gravado: o item vazio não vai para a Galeria.
                        runCatching { contentResolver.delete(uri, null, null) }
                        false
                    } else publicar(uri)
                } ?: false
            }
            posse?.let { runCatching { DonoDaPlaca.soltar(it) } }
            if (trava.isHeld) trava.release()
            val quadros = gravador?.quadros ?: 0
            if (placa) {
                val dur = if (inicioDaGravacao > 0) (SystemClock.elapsedRealtime() - inicioDaGravacao) / 1000.0 else 0.0
                Log.i(TAG, "gravação da placa: parada; quadros=$quadros duração=${"%.1f".format(Locale.US, dur)} s " +
                    "som=${gravador?.amostrasDeSom ?: 0} amostras (${"%.2f".format(Locale.US, (gravador?.amostrasDeSom ?: 0) / 48000.0)} s) " +
                    "bytes=${gravador?.bytes ?: 0} publicado=$publicado")
            }
            val fim = motivo ?: tx(R.string.placa_motivo_encerrada)
            Log.i(TAG, "gravação: $fim; quadros=$quadros publicado=$publicado")
            GravacaoBus.publicar(GravacaoBus.Estado(
                fase = GravacaoBus.Fase.PARADA, quadros = quadros, bytes = gravador?.bytes ?: 0, daPlaca = placa,
                mensagem = if (publicado) tx(R.string.placa_motivo_salvo, fim) else fim,
            ))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            trabalho = null
        }
    }

    private fun publicar(uri: Uri): Boolean = runCatching {
        val cv = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
        contentResolver.update(uri, cv, null, null) > 0
    }.getOrElse { Log.w(TAG, "não publiquei $uri: ${Log.erroExterno(it.message)}"); false }

    private fun espacoLivre(): Long = runCatching {
        StatFs(Environment.getExternalStorageDirectory().path).availableBytes
    }.getOrDefault(Long.MAX_VALUE)

    /**
     * O texto no idioma escolhido **agora** (`docs/traducao.md`, Android): abaixo do Android 13 o
     * AppCompat não alcança o serviço, e [Idioma.contexto] monta o contexto pedido a cada frase.
     */
    private fun tx(id: Int, vararg args: Any): String {
        val c = Idioma.contexto(this)
        return if (args.isEmpty()) c.getString(id) else c.getString(id, *args)
    }

    private fun comecarPrimeiroPlano(texto: String) {
        val n = notificacao(texto)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICACAO, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(NOTIFICACAO, n)
        }
    }

    /**
     * Refaz o primeiro plano com o tipo `microphone` junto do `camera` (a placa grava o som por um
     * `AudioRecord`). `false` se o sistema recusou.
     */
    private fun microfoneNoPrimeiroPlano(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return runCatching {
            startForeground(NOTIFICACAO, notificacao(tx(R.string.placa_notif_gravando_placa)),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        }.onFailure { Log.w(TAG, "primeiro plano com microfone recusado: ${Log.erroExterno(it.message)}") }.isSuccess
    }

    private fun atualizarNotificacao(texto: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICACAO, notificacao(texto))
    }

    private fun notificacao(texto: String): Notification {
        // O canal recriado a cada notificação: com o mesmo id, só troca o nome, que segue o idioma escolhido.
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CANAL, tx(R.string.placa_canal_gravacao), NotificationManager.IMPORTANCE_LOW))
        val pararPi = PendingIntent.getService(
            this, 0, Intent(this, GravacaoDvService::class.java).setAction(ACAO_PARAR),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CANAL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Quall")  // i18n-fora: o nome do app
            .setContentText(texto)
            .setOngoing(true)
            .addAction(0, tx(R.string.placa_notif_parar), pararPi)
            .build()
    }

    companion object {
        private const val TAG = "QuallDv"
        private const val CANAL = "quall-gravacao-dv"
        private const val NOTIFICACAO = 7702
        const val EXTRA_ID = "id"
        const val ACAO_PARAR = "com.quall.android.PARAR_GRAVACAO_DV"
        const val ESPACO_PARA_COMECAR = 2_000_000_000L
        const val ESPACO_MINIMO = 500_000_000L
        const val PAUSA_MAXIMA_MS = 5 * 60 * 1000L

        fun comecar(c: Context, id: String) {
            val i = Intent(c, GravacaoDvService::class.java).putExtra(EXTRA_ID, id)
            androidx.core.content.ContextCompat.startForegroundService(c, i)
        }

        fun parar(c: Context) {
            c.startService(Intent(c, GravacaoDvService::class.java).setAction(ACAO_PARAR))
        }

        @Volatile private var pendentesFeitos = false

        /**
         * Os vídeos deste app que ficaram pendentes (`IS_PENDING=1`) de uma gravação interrompida
         * (processo morto): o sistema apaga pendentes em 7 dias, e o MP4 deles é o fragmentado do
         * `hybrid_fragmented`, cujo `moov` só conta o primeiro fragmento (a Galeria mostraria ~1 s).
         * Cada um é **remontado** em MP4 comum num arquivo novo (sem recodificar), publicado, e o
         * pendente apagado. Se a remontagem falhar, o pendente é publicado como está.
         *
         * Uma vez por processo, e nunca com a gravação no ar (seria publicar o arquivo que está
         * sendo escrito; a revisão, A5) — a da fita **e a da tela R5** (fase 3 do R5: os arquivos
         * dela moram na mesma pasta, e os pendentes dela são remontados aqui também). Uma gravação da
         * tela R5 que **começou** depois da busca faz desistir: o arquivo dela acabou de nascer
         * pendente e não é órfão. `@Synchronized`: a tela inicial e a tela R5 chamam, cada uma na sua
         * thread.
         *
         * **Desde a D1 (§14.4, §14.10), os do `MediaMuxer`**: um pendente com a cópia crua ao lado
         * (`CopiaCrua`, pelo id do MediaStore) é remontado **por ela**, no próprio item (truncado),
         * e publicado; sem a cópia e sem a `libqualldv` (um MP4 sem `moov` não abre em lugar nenhum), é
         * apagado, com um recado. Uma cópia legível sem pendente (o sistema apaga pendentes em 7 dias)
         * vira um item novo `…-recuperado.mp4`; uma ilegível é apagada.
         */
        @Synchronized
        fun publicarPendentes(c: Context) {
            val r5 = com.quall.android.mirror.GravacaoDaTelaBus
            // O DVD (docs/dvd-para-mp4.md §2.6): o arquivo da conversão em curso também é pendente.
            val dvd = com.quall.android.dvd.ConversaoDvdBus
            val rx = com.quall.android.receive.GravacaoRecebidaBus
            if (pendentesFeitos || GravacaoBus.gravando || r5.atual.ocupada || dvd.arquivoNoAr || rx.atual.ocupada) return
            pendentesFeitos = true
            // **Antes** de listar as cópias (a revisão, 13d): uma gravação que começar depois disto faz
            // desistir, e a cópia dela nasce depois da lista.
            val comecosAntes = r5.comecos
            val comecosRx = rx.comecos
            val dirDasCopias = com.quall.android.capture.CopiaCrua.diretorio(c)
            val copias = HashMap(com.quall.android.capture.CopiaCrua.listar(dirDasCopias))
            var perdidas = 0
            val cr = c.contentResolver
            val colecao = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val achados = ArrayList<Pair<Uri, String>>()
            runCatching {
                val args = android.os.Bundle().apply {
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_ONLY)
                    putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,
                        "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?")
                    putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,
                        arrayOf(Environment.DIRECTORY_MOVIES + "/Quall%"))
                }
                cr.query(colecao, arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME), args, null)?.use { cur ->
                    while (cur.moveToNext()) {
                        achados += android.content.ContentUris.withAppendedId(colecao, cur.getLong(0)) to cur.getString(1)
                    }
                }
            }.onFailure { Log.w(TAG, "pendentes: ${Log.erroExterno(it.message)}") }
            for ((velho, nome) in achados) {
                if (GravacaoBus.gravando || r5.atual.ocupada || r5.comecos != comecosAntes || dvd.arquivoNoAr || rx.atual.ocupada || rx.comecos != comecosRx) return
                // O parcial de um DVD recusado (a proteção, §2.1 do docs/dvd-para-mp4.md) nunca é
                // publicado: a marca persistente diz, e ele é apagado (a revisão do código, 2).
                val idDoPendente = android.content.ContentUris.parseId(velho)
                if (com.quall.android.dvd.GaleriaDoDvd.recusado(c, idDoPendente)) {
                    com.quall.android.dvd.GaleriaDoDvd.apagar(c, velho)
                    Log.i(TAG, "pendente $nome: de um DVD recusado; apagado")
                    continue
                }
                val copia = copias.remove(android.content.ContentUris.parseId(velho))
                if (copia != null) {
                    if (recuperarDaCopia(c, copia, velho, nome) == Recuperacao.PERDIDA) perdidas++
                    continue
                }
                if (!QuallDv.disponivel) {
                    // Um pendente do `MediaMuxer` sem a cópia. Se ele abre (o `stop` saiu e só a
                    // publicação faltou), vai como está; sem `moov`, não há o que remontar.
                    if (mp4Legivel(c, velho)) {
                        val ok = runCatching {
                            cr.update(velho, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null) > 0
                        }.getOrDefault(false)
                        Log.i(TAG, "gravação interrompida publicada como está: $nome (o MP4 abre; $ok)")
                    } else {
                        runCatching { cr.delete(velho, null, null) }
                        Log.w(TAG, "gravação interrompida sem a cópia crua: $nome apagado (o MP4 sem índice não abre)")
                        perdidas++
                    }
                    continue
                }
                var publicado = false
                runCatching {
                    val novoNome = nome.removeSuffix(".mp4") + "-recuperado.mp4"
                    val cv = ContentValues().apply {
                        put(MediaStore.Video.Media.DISPLAY_NAME, novoNome)
                        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                        put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Quall")
                        put(MediaStore.Video.Media.IS_PENDING, 1)
                    }
                    val novo = cr.insert(colecao, cv) ?: throw IllegalStateException("insert")
                    val pacotes = cr.openFileDescriptor(velho, "r")!!.use { ent ->
                        cr.openFileDescriptor(novo, "rw")!!.use { sai -> QuallDv.mp4Remontar(ent.fd, sai.fd) }
                    }
                    val parcial = pacotes >= (1L shl 40)
                    val n = if (parcial) pacotes - (1L shl 40) else pacotes
                    if (n > 0) {
                        cr.update(novo, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
                        // Parcial (a leitura parou num erro): o original fica também, publicado.
                        if (!parcial) { cr.delete(velho, null, null); publicado = true }
                        Log.i(TAG, "gravação interrompida remontada: $nome -> $novoNome ($n pacotes${if (parcial) ", parcial" else ""})")
                    } else {
                        cr.delete(novo, null, null)
                    }
                }.onFailure { Log.w(TAG, "remontar $nome: ${Log.erroExterno(it.message)}") }
                if (!publicado) {
                    val ok = runCatching {
                        cr.update(velho, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null) > 0
                    }.getOrDefault(false)
                    Log.i(TAG, "gravação interrompida publicada como está: $nome ($ok)")
                }
            }
            // As cópias sem pendente: só se nenhuma gravação começou no meio.
            for ((_, copia) in copias) {
                if (GravacaoBus.gravando || r5.atual.ocupada || r5.comecos != comecosAntes || dvd.arquivoNoAr || rx.atual.ocupada || rx.comecos != comecosRx) return
                if (recuperarDaCopia(c, copia, null, null) == Recuperacao.PERDIDA) perdidas++
            }
            if (perdidas > 0) {
                val frase = Idioma.contexto(c).getString(R.string.placa_recuperacao_perdida)
                r5.atualizar { it.copy(mensagem = frase) }
            }
        }

        /** Na terceira tentativa a cópia desiste: uma remontagem que derruba o processo não vira laço. */
        private const val TENTATIVAS_DA_COPIA = 2

        private enum class Recuperacao { RECUPERADA, PERDIDA, ADIADA }

        /** O MP4 abre: o `MediaExtractor` acha trilha e duração. */
        private fun mp4Legivel(c: Context, uri: Uri): Boolean = runCatching {
            val ex = android.media.MediaExtractor()
            try {
                ex.setDataSource(c, uri, null)
                (0 until ex.trackCount).any { i ->
                    val f = ex.getTrackFormat(i)
                    f.containsKey(android.media.MediaFormat.KEY_DURATION) && f.getLong(android.media.MediaFormat.KEY_DURATION) > 0
                }
            } finally {
                ex.release()
            }
        }.getOrDefault(false)

        /**
         * Remonta [copia] no pendente [velho] (truncado) e o publica; sem [velho], num item novo
         * `…-recuperado.mp4`. Devolve `false` se a gravação se perdeu (a cópia ilegível ou a
         * remontagem que falhou), com o pendente e a cópia apagados. Chamada por [publicarPendentes].
         */
        private fun recuperarDaCopia(c: Context, copia: java.io.File, velho: Uri?, nomeDoPendente: String?): Recuperacao {
            val cc = com.quall.android.capture.CopiaCrua
            val cr = c.contentResolver
            val colecao = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val r5 = com.quall.android.mirror.GravacaoDaTelaBus
            fun perder(motivo: String): Recuperacao {
                if (velho != null) runCatching { cr.delete(velho, null, null) }
                cc.apagar(copia)
                Log.w(TAG, "gravação interrompida perdida: ${nomeDoPendente ?: copia.name} — ${Log.erroExterno(motivo)}")
                return Recuperacao.PERDIDA
            }
            val tentativa = cc.contarTentativa(copia)
            if (tentativa > TENTATIVAS_DA_COPIA) return perder("a remontagem já falhou ${tentativa - 1} vezes") // i18n-fora: diário (o perder só anota)
            val varredura = runCatching {
                java.io.BufferedInputStream(java.io.FileInputStream(copia), 1 shl 16).use { cc.varrer(it) }
            }.getOrNull()
            if (varredura == null || !varredura.legivel) return perder("a cópia crua não tem o que remontar") // i18n-fora: diário (o perder só anota)
            val recuperando = Idioma.contexto(c).getString(R.string.placa_recuperando)
            r5.atualizar { it.copy(mensagem = recuperando) }
            val nome = nomeDoPendente ?: varredura.cabecalho.nome.removeSuffix(".mp4") + "-recuperado.mp4"
            val alvo = velho ?: runCatching {
                cr.insert(colecao, ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, nome)
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Quall")
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                })
            }.getOrNull() ?: run {
                Log.w(TAG, "a Galeria não aceitou o item da cópia ${copia.name}; fica para a próxima")
                r5.atualizar { it.copy(mensagem = "") }
                return Recuperacao.ADIADA
            }
            // "rwt": o pendente é truncado e reescrito do zero. A cópia só sai **depois** de publicar.
            val r = runCatching {
                cr.openFileDescriptor(alvo, "rwt")!!.use { sai -> cc.remontar(copia, sai.fileDescriptor) }
            }.getOrElse { com.quall.android.capture.CopiaCrua.Remontagem(0, 0, 0, "${it.javaClass.simpleName}: ${it.message}") }
            if (r.erro != null || r.quadros == 0) {
                if (velho == null) runCatching { cr.delete(alvo, null, null) }
                return perder("a remontagem falhou: ${r.erro ?: "nenhum quadro"}")
            }
            val ok = runCatching {
                cr.update(alvo, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null) > 0
            }.getOrDefault(false)
            if (!ok) {
                // O item novo não fica para trás pendente sem cópia (a revisão do código, 8).
                if (velho == null) runCatching { cr.delete(alvo, null, null) }
                Log.w(TAG, "pendente $nome remontado, mas a Galeria não publicou; a cópia fica para a próxima")
                r5.atualizar { it.copy(mensagem = "") }
                return Recuperacao.ADIADA
            }
            cc.apagar(copia)
            Log.i(TAG, "pendente $nome recuperado da cópia: ${r.duracaoUs / 1_000_000} s " +
                "(${r.quadros} quadros, ${r.pacotesDeSom} pacotes de som; tentativa $tentativa)")
            val recuperada = Idioma.contexto(c).getString(R.string.placa_recuperada, nome)
            r5.atualizar { it.copy(mensagem = recuperada) }
            return Recuperacao.RECUPERADA
        }
    }
}

/** O estado da gravação para a tela, no molde do `MirrorBus`. */
object GravacaoBus {
    enum class Fase { NADA, PREPARANDO, GRAVANDO, PARADA }

    data class Estado(
        val fase: Fase = Fase.NADA,
        val nome: String = "",
        val quadros: Long = 0,
        val bytes: Long = 0,
        val espacoLivre: Long = 0,
        val decorridoMs: Long = 0,
        val pausada: Boolean = false,
        val avisoDoSom: String? = null,
        val mensagem: String = "",
        /** A gravação é da placa de captura (e não da fita DV): a tela diz as coisas dela. */
        val daPlaca: Boolean = false,
    )

    @Volatile var estado = Estado()
        private set
    /** Um ouvinte por tela (a chave é a tela; a razão é a do `MirrorBus.ouvir`). */
    private val ouvintes = java.util.concurrent.ConcurrentHashMap<Any, (Estado) -> Unit>()
    private val principal = android.os.Handler(android.os.Looper.getMainLooper())

    val gravando: Boolean get() = estado.fase == Fase.GRAVANDO || estado.fase == Fase.PREPARANDO

    @Synchronized fun publicar(e: Estado) {
        estado = e
        for (o in ouvintes.values) principal.post { o(e) }
    }

    @Synchronized fun atualizar(bloco: (Estado) -> Estado) = publicar(bloco(estado))

    /** Registra (ou, com `null`, tira) o ouvinte de [dono]; o registrado recebe o estado logo. */
    @Synchronized fun ouvir(dono: Any, o: ((Estado) -> Unit)?) {
        if (o == null) { ouvintes.remove(dono); return }
        ouvintes[dono] = o
        val e = estado
        principal.post { o(e) }
    }
}
