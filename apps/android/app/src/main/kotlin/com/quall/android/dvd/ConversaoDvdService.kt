package com.quall.android.dvd

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import androidx.core.app.NotificationCompat
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.capture.dv.QuallDv
import java.io.File
import java.util.Locale
import kotlin.concurrent.thread

/**
 * **A conversão do título, em primeiro plano** (`docs/dvd-para-mp4.md` §2.7, a D4): o tipo
 * `mediaProcessing` (Android 15+, feito para transcodificar; abaixo, `dataSync`), o
 * `PARTIAL_WAKE_LOCK` (o telefone apaga a tela no meio), a notificação com a barra (setores lidos
 * sobre os do título) e o Cancelar, o estado para a tela pelo [ConversaoDvdBus].
 *
 * O caminho: o leitor e o disco vêm da tela ([SessaoDoDvd]); a [LeituraDoTitulo] empurra as células
 * para o pipeline em C ([QuallDvd]); o [ConversorDvd] faz o H.264 e os AAC e escreve o MP4 na
 * Galeria ([GaleriaDoDvd]).
 *
 * Como termina:
 * - **o fim do título**: o MP4 é publicado;
 * - **o Cancelar, o limite do sistema** (6 h por dia no `mediaProcessing`: [onTimeout]) **ou o
 *   leitor que parou**: o MP4 fecha como parcial jogável e é publicado (§2.2, a revisão, 15);
 * - **a proteção** (o setor cifrado, o sense 0x6F, o prensado com setor ilegível): o parcial é
 *   **apagado** e a tela diz a frase (§2.1);
 * - **o espaço**: conferido antes (a duração × as taxas × 1,1) e durante.
 *
 * **A bancada da D1** (`EXTRA_ARQUIVO`, só pela `BancadaDoDvdActivity` do APK de `debug`): um VOB na
 * pasta do app (`Android/data/com.quall.android/files/`) no lugar do disco, sem IFO (as faixas no
 * modo automático do C).
 */
class ConversaoDvdService : Service() {
    @Volatile private var parar = false
    /** O disco tinha som num canal só, e o C copiou para os dois (a frase do fim diz). */
    @Volatile private var umCanal = false
    @Volatile private var motivoDaParada: Frase? = null
    @Volatile private var trabalho: Thread? = null
    @Volatile private var leitura: LeituraDoTitulo? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACAO_PARAR) {
            pedirParada(Frase(R.string.dvd_conversao_cancelada))
            if (trabalho == null) stopSelf()
            return START_NOT_STICKY
        }
        if (trabalho != null) return START_NOT_STICKY
        val titulo = intent?.getIntExtra(EXTRA_TITULO, -1) ?: -1
        val arquivo = intent?.getStringExtra(EXTRA_ARQUIVO)
        if (titulo < 0 && arquivo == null) { stopSelf(); return START_NOT_STICKY }
        primeiroPlano(Frase(R.string.dvd_notificacao_preparando), null)
        parar = false
        motivoDaParada = null
        ConversaoDvdBus.publicar(ConversaoDvdBus.Estado(fase = ConversaoDvdBus.Fase.PREPARANDO))
        trabalho = thread(name = "quall-dvd-conversao") { converter(titulo, arquivo) }
        return START_NOT_STICKY
    }

    /** O limite do `mediaProcessing` (6 h em 24 h): o parcial fecha em segundos (senão o sistema derruba). */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "conversão: o sistema pediu o fim (onTimeout, tipo $fgsType)")
        pedirParada(Frase(R.string.dvd_limite_6h))
        // O primeiro plano sai **na hora** (a revisão do código, 4): o sistema dá segundos, e o
        // fechamento do MP4 pode passar disso. A thread termina sozinha; se o processo morrer antes,
        // o MP4 fragmentado fica pendente e a próxima abertura o remonta.
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun pedirParada(motivo: Frase) {
        if (motivoDaParada == null) motivoDaParada = motivo
        parar = true
        leitura?.parar()
    }

    private fun converter(numero: Int, nomeDoArquivo: String?) {
        umCanal = false
        val trava = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "quall:conversao-dvd")
        trava.acquire(12 * 60 * 60 * 1000L)
        var h = 0L
        var conversor: ConversorDvd? = null
        var arquivo: GaleriaDoDvd.Arquivo? = null
        var setoresDoArquivo: SetoresDeArquivo? = null
        var doLeitor = false
        var progresso: Thread? = null
        // A frase do fim, sem idioma (a tela monta na hora de desenhar). [pronto]: o título inteiro, sem
        // nada a dizer — era a comparação `mensagem == "pronto"`, que parava de valer em inglês.
        var mensagem = Frase(R.string.dvd_conversao_encerrada)
        var pronto = false
        var apagar = false
        var publicado = false
        val inicio = SystemClock.elapsedRealtime()
        try {
            // O serviço também pode vir direto da bancada, sem a tela que consulta `disponivel`.
            // Carrega a biblioteca antes de qualquer JNI; sem ela, o motivo chega ao Bus e ao log.
            if (!disponivel) {
                mensagem = Frase(R.string.dvd_nao_converte_64_bits)
                Log.w(TAG, "conversão indisponível neste APK/aparelho; nenhuma chamada ao pipeline")
                return
            }
            // 1. De onde, e o quê.
            val setores: Setores
            val trechos: List<TrechoDoTitulo>
            val titulo: TituloDoDvd?
            val nome: String
            if (nomeDoArquivo != null) {
                val f = File(getExternalFilesDir(null), File(nomeDoArquivo).name)
                val s = SetoresDeArquivo(f)
                setoresDoArquivo = s
                setores = s
                trechos = listOf(TrechoDoTitulo(0, s.setores - 1, 0))
                titulo = null
                nome = GaleriaDoDvd.nome(f.nameWithoutExtension, 0)
                Log.i(TAG, "conversão (bancada): $f, ${s.setores} setores, sem IFO")
            } else {
                val (l, d) = SessaoDoDvd.entregarAoServico() ?: throw ErroDoDvd(Frase(R.string.dvd_leitor_nao_aberto_conversao), "o leitor não está aberto")
                doLeitor = true
                titulo = d.titulos.firstOrNull { it.numero == numero }
                    ?: throw ErroDoDvd(Frase(R.string.dvd_titulo_nao_existe, numero), "o título $numero não existe")
                if (titulo.recusa != null) throw RecusaDoDisco(titulo.recusa)
                // A reconferência (a revisão do código, 3): entre a tela e o Converter o disco pode ter
                // sido trocado. Pronto de novo, a proteção de novo (CPST e perfil), e o mesmo volume.
                SessaoDoDvd.reconferir(l, d)
                setores = l
                trechos = titulo.trechos
                nome = GaleriaDoDvd.nome(d.volume, titulo.numero)
                Log.i(TAG, "conversão: título ${titulo.numero}, ${titulo.trechos.size} célula(s), " +
                    "${titulo.setores} setores, ${"%.1f".format(Locale.US, titulo.duracao90k / 90000.0 / 60)} min, " +
                    "${if (titulo.pal) "PAL" else "NTSC"} ${if (titulo.aspecto169) "16:9" else "4:3"}, " +
                    "som ${titulo.faixas.joinToString { "0x%x %s %s".format(it.substream, it.formato, it.idioma ?: "?") }}")
            }
            val faixas = titulo?.faixasConvertiveis
            // 2. O espaço (a duração × as taxas × 1,1), antes de gastar a leitura.
            if (titulo != null) {
                val bps = ConversorDvd.BITRATE_VIDEO + (faixas?.size ?: 0) * ConversorDvd.BITRATE_SOM
                val precisa = (titulo.duracao90k / 90_000.0 * bps / 8 * 1.1).toLong() + MARGEM
                val livre = espacoLivre()
                if (livre < precisa) {
                    mensagem = Frase(R.string.dvd_espaco_insuficiente, precisa / 1_000_000, livre / 1_000_000)
                    return
                }
            }
            // 3. O pipeline, a leitura e o primeiro quadro.
            h = QuallDvd.abrir(faixas?.map { it.substream }?.toIntArray())
            if (h == 0L) throw IllegalStateException("sem memória para o pipeline")
            val l = LeituraDoTitulo(setores, trechos, DestinoQuallDvd(h)).comecar()
            leitura = l
            if (parar) l.parar()
            val total = l.total
            ConversaoDvdBus.publicar(ConversaoDvdBus.Estado(fase = ConversaoDvdBus.Fase.PREPARANDO, nome = nome,
                setoresDoTitulo = total, duracao90k = titulo?.duracao90k ?: 0))
            val p = QuallDvd.preparar(h)
            if (p < 0) { mensagem = motivoDoFim(p, l); apagar = p == QuallDvd.ERRO_CIFRADO || l.falha is RecusaDoDisco; return }
            val info = QuallDvd.Info.de(QuallDvd.info(h))
            Log.i(TAG, "conversão: o fluxo diz ${info.largura}x${info.altura} ${info.fpsNum}/${info.fpsDen} " +
                "${if (info.aspecto169) "16:9" else "4:3"}, ${if (info.entrelacado) "entrelaçado" else "progressivo"}, " +
                "faixas ${info.faixas.joinToString { "0x%x".format(it) }} (vistas ${info.vistas})")
            // 4. O arquivo e os codificadores.
            val a = GaleriaDoDvd.criar(this, nome)
            arquivo = a
            val idiomas = if (faixas != null) faixas.map { ConversorDvd.idioma639_2(it.idioma) } else info.faixas.map { "und" }
            val c = ConversorDvd(h, a.pfd.fd, titulo?.pal ?: info.pal, titulo?.aspecto169 ?: info.aspecto169,
                info.faixas.size, idiomas)
            conversor = c
            ConversaoDvdBus.atualizar { it.copy(fase = ConversaoDvdBus.Fase.CONVERTENDO, nome = a.nome) }
            primeiroPlano(Frase(R.string.dvd_notificacao_convertendo, a.nome), 0)
            // 5. O progresso, de segundo em segundo, fora desta thread.
            progresso = thread(name = "quall-dvd-progresso") {
                while (!parar) {
                    if (ConversaoDvdBus.estado.fase != ConversaoDvdBus.Fase.CONVERTENDO) break
                    val lidos = l.lidos
                    val f = if (total > 0) lidos.toDouble() / total else 0.0
                    val passado = SystemClock.elapsedRealtime() - inicio
                    val resta = if (f > 0.01) (passado * (1 - f) / f).toLong() else -1L
                    ConversaoDvdBus.atualizar {
                        it.copy(setoresLidos = lidos, tempo90k = c.tempo90k, restanteMs = resta,
                            setoresPulados = (setores as? LeitorDeDisco)?.setoresPulados ?: 0)
                    }
                    // O espaço também durante (a revisão do código, 15): a estimativa do começo pode errar.
                    val livre = espacoLivre()
                    if (livre < ESPACO_MINIMO) {
                        pedirParada(Frase(R.string.dvd_espaco_acabou, livre / 1_000_000))
                        break
                    }
                    primeiroPlano(
                        if (resta >= 0) Frase(R.string.dvd_notificacao_convertendo_falta, a.nome, duracao(resta))
                        else Frase(R.string.dvd_notificacao_convertendo, a.nome),
                        (f * 1000).toInt(),
                    )
                    try { Thread.sleep(1000) } catch (_: InterruptedException) { break }
                }
            }
            // 6. O laço.
            val r = c.converter { parar }
            mensagem = when {
                r != null -> motivoDoFim(r, l)
                motivoDaParada != null -> motivoDaParada!!
                c.erro != null -> c.erro!!
                else -> { pronto = true; Frase(R.string.dvd_pronto) }
            }
            apagar = r == QuallDvd.ERRO_CIFRADO || l.falha is RecusaDoDisco
            if (r == null && motivoDaParada == null && c.erro == null) {
                val pulados = (setores as? LeitorDeDisco)?.setoresPulados ?: 0
                if (pulados > 0) {
                    // Não é mais o "pronto" sozinho: a frase do fim diz o que foi pulado.
                    pronto = false
                    mensagem = Frase(if (pulados == 1L) R.string.dvd_pronto_pulado_um else R.string.dvd_pronto_pulados, pulados)
                }
            }
        } catch (e: RecusaDoDisco) {
            mensagem = e.recusa
            apagar = true
            Log.w(TAG, "conversão recusada: ${Log.erroExterno(e.message)}")
        } catch (e: LinkageError) {
            // Uma biblioteca carregada com JNI incompatível não é `Exception`. O erro continua
            // explícito, em vez de o `finally` anunciar só um encerramento e o processo cair.
            mensagem = Frase(R.string.dvd_conversao_falhou, e.fraseDoDvd())
            Log.e(TAG, "a conversão falhou ao chamar a biblioteca: ${Log.erroExterno(e.message)}", e)
        } catch (e: Exception) {
            mensagem = Frase(R.string.dvd_conversao_falhou, e.fraseDoDvd())
            Log.e(TAG, "a conversão falhou: ${Log.erroExterno(e.message)}", e)
        } finally {
            // A ordem: o progresso para (ele mexe na notificação), a leitura para (acorda o C), o
            // conversor fecha o MP4, o pipeline é solto, o arquivo é publicado (ou apagado), e o
            // leitor volta.
            progresso?.let { it.interrupt(); runCatching { it.join(3000) } }
            val l = leitura
            if (l != null && !l.terminou) { l.parar(); l.esperar(10_000) }
            // Depois de a leitura parar (a revisão do código, 1): uma recusa que ela viu no fim também
            // apaga; e com ela ainda viva, nada é publicado.
            if (l?.falha is RecusaDoDisco) apagar = true
            val leituraSaiu = l == null || l.terminou
            val erroDoConversor = conversor?.encerrar()
            if (erroDoConversor != null && pronto) { mensagem = erroDoConversor; pronto = false }
            val c = conversor
            val soltou = c == null || c.terminou
            if (h != 0L) {
                // O diário por célula (o defeito do A07: onde a conta do tempo erra) e os contadores do
                // pipeline (dvd.c, `dvd_contadores`): a prova da bancada.
                runCatching { QuallDvd.diario(h) }
                umCanal = runCatching { QuallDvd.canalCopiado(h) }.getOrDefault(0) != 0
                val v = runCatching { QuallDvd.contadores(h) }.getOrNull()
                if (v != null && v.size >= 17) {
                    val faixas = (0 until 8).filter { 17 + 4 * it + 3 < v.size && v[17 + 4 * it] > 0 }
                        .joinToString(" ") { k -> "f$k=${v[17 + 4 * k]}/sil${v[18 + 4 * k]}/cort${v[19 + 4 * k]}/falhas${v[20 + 4 * k]}" }
                    Log.i(TAG, "pipeline: setores=${v[0]} fora_do_formato=${v[1]} zerados=${v[2]} navs=${v[3]} " +
                        "navs_invalidos=${v[4]} quadros=${v[5]}/${v[6]} entrelacados=${v[7]} progressivos=${v[8]} " +
                        "pulldown=${v[9]} carimbos_corrigidos=${v[10]} antes_do_zero=${v[11]} falhas_video=${v[12]} " +
                        "pacotes_sem_faixa=${v[13]} voltas_no_anel=${v[14]} bytes=${v[16]} " +
                        "descontinuidades=${v.getOrElse(49) { -1 }} som_cortado_s=${"%.3f".format(Locale.US, v.getOrElse(50) { 0 } / 1000.0)} " +
                        "correcao_maior_ms=${v.getOrElse(51) { -1 }} correcao_mediana_ms=${v.getOrElse(52) { -1 }} " +
                        "som_rebaseado=${v.getOrElse(53) { -1 }} som: $faixas")
                    if (v.getOrElse(50) { 0 } > 1000) Log.w(TAG, "pipeline: mais de 1 s de som cortado no título")
                }
            }
            if (h != 0L && soltou && (l == null || l.terminou)) QuallDvd.fechar(h)
            else if (h != 0L) Log.w(TAG, "conversão: o pipeline fica sem soltar (uma thread não saiu)")
            val a = arquivo
            if (a != null) {
                if (apagar) {
                    // A recusa apaga **sempre** (a revisão do código, 2), mesmo com o MP4 ainda aberto
                    // (o item some; o que a thread ainda escrever vai para um arquivo sem nome). A marca
                    // vem antes: se o processo morrer aqui, o `publicarPendentes` apaga em vez de publicar.
                    GaleriaDoDvd.marcarRecusado(this, a.uri)
                    if (soltou) runCatching { a.pfd.close() }
                    GaleriaDoDvd.apagar(this, a.uri)
                } else if (!soltou || !leituraSaiu) {
                    // O MP4 ainda pode ser escrito, ou a leitura não saiu: o arquivo fica pendente, e a
                    // próxima abertura o remonta (GravacaoDvService.publicarPendentes).
                    mensagem = Frase(R.string.dvd_arquivo_pendente, mensagem)
                    pronto = false
                } else {
                    runCatching { a.pfd.close() }
                    val vazio = (c?.bytes ?: 0L) == 0L
                    if (vazio) GaleriaDoDvd.apagar(this, a.uri)
                    else publicado = GaleriaDoDvd.publicar(this, a.uri)
                }
            }
            runCatching { setoresDoArquivo?.close() }
            if (doLeitor) {
                // O leitor só fecha com a leitura parada (a revisão do código, 12; o mesmo critério do
                // `fechar(h)`): senão, quando ela sair.
                if (leituraSaiu) SessaoDoDvd.devolverDoServico()
                else thread(name = "quall-dvd-devolver") { l?.esperar(0); SessaoDoDvd.devolverDoServico() }
            }
            leitura = null
            if (trava.isHeld) trava.release()
            val final = if (publicado) {
                // O nome depois de publicar: a Galeria só acrescenta o " (1)" ao tirar o IS_PENDING (medido 29/09).
                val nomeFinal = a?.let { GaleriaDoDvd.nomeReal(this, it.uri) ?: it.nome }.orEmpty()
                val salvo = if (pronto) Frase(R.string.dvd_salvo_na_galeria, nomeFinal)
                    else Frase(R.string.dvd_parcial_na_galeria, mensagem, nomeFinal)
                if (umCanal) Frase(R.string.dvd_com_um_canal, salvo, QuallDvd.UM_CANAL_SO) else salvo
            } else mensagem
            // A frase vai ao Bus sem idioma ([ConversaoDvdBus.Estado.fim]) e, para quem ainda lê texto, montada agora.
            val texto = final.em(Idioma.textos(Idioma.contexto(this)))
            Log.i(TAG, "conversão encerrada; pronto=$pronto quadros=${conversor?.quadros ?: 0} bytes=${conversor?.bytes ?: 0} " +
                "publicado=$publicado apagado=$apagar em ${(SystemClock.elapsedRealtime() - inicio) / 1000} s")
            ConversaoDvdBus.atualizar { it.copy(fase = ConversaoDvdBus.Fase.PARADA, mensagem = texto, fim = final, publicado = publicado) }
            stopForeground(STOP_FOREGROUND_REMOVE)
            trabalho = null
            stopSelf()
        }
    }

    /** A frase do fim pelo código do C e pelo que a leitura viu (a leitura sabe o motivo de verdade). */
    private fun motivoDoFim(r: Int, l: LeituraDoTitulo): Frase {
        val f = l.falha
        return when {
            f is RecusaDoDisco -> f.recusa
            f is LeitorParou -> FrasesDoDvd.LEITOR_PAROU
            r == QuallDvd.ERRO_CANCELADO && motivoDaParada != null -> motivoDaParada!!
            r == QuallDvd.ERRO_LEITOR && f != null -> Frase(R.string.dvd_leitura_falhou, Frase.cru("${f.message}"))
            else -> QuallDvd.motivo(r)
        }
    }

    private fun duracao(ms: Long): Frase {
        val min = (ms + 59_999) / 60_000
        return if (min >= 60) Frase(R.string.dvd_tempo_h_min, min / 60, min % 60) else Frase(R.string.dvd_tempo_min, min)
    }

    private fun espacoLivre(): Long = runCatching {
        StatFs(Environment.getExternalStorageDirectory().path).availableBytes
    }.getOrDefault(Long.MAX_VALUE)

    /**
     * A notificação (a barra em milésimos; `null` sem barra), e o primeiro plano no tipo certo. Os textos no
     * idioma escolhido (`Idioma.contexto`: abaixo do Android 13 o AppCompat não alcança o serviço), pedidos a
     * cada vez; o canal é recriado com o nome traduzido (o mesmo id só renomeia).
     */
    private fun primeiroPlano(frase: Frase, milesimos: Int?) {
        val ctx = Idioma.contexto(this)
        val texto = frase.em(Idioma.textos(ctx))
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CANAL, ctx.getString(R.string.dvd_canal_da_notificacao), NotificationManager.IMPORTANCE_LOW))
        val cancelar = PendingIntent.getService(
            this, 0, Intent(this, ConversaoDvdService::class.java).setAction(ACAO_PARAR), PendingIntent.FLAG_IMMUTABLE,
        )
        val abrir = PendingIntent.getActivity(
            this, 0, Intent(this, com.quall.android.ui.ConversaoDvdActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val n: Notification = NotificationCompat.Builder(this, CANAL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(ctx.getString(R.string.dvd_titulo_da_notificacao))
            .setContentText(texto)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(abrir)
            .apply { if (milesimos != null) setProgress(1000, milesimos.coerceIn(0, 1000), false) }
            .addAction(0, ctx.getString(R.string.cancelar), cancelar)
            .build()
        val tipo = if (Build.VERSION.SDK_INT >= 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
        else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        // O tipo no `startForeground` é do 29; o DVD só existe do 30 em diante, mas o lint não sabe disso.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(NOTIFICACAO, n, tipo)
        else startForeground(NOTIFICACAO, n)
    }

    companion object {
        private const val TAG = "QuallDvd"
        private const val CANAL = "quall-conversao-dvd"
        private const val NOTIFICACAO = 7703
        /** O que sobra além da estimativa: o sistema não pode ficar sem espaço por causa de nós. */
        private const val MARGEM = 300_000_000L
        /** Abaixo disto, durante a conversão, ela para (e o parcial é publicado). */
        private const val ESPACO_MINIMO = 200_000_000L
        const val EXTRA_TITULO = "titulo"
        const val EXTRA_ARQUIVO = "arquivo"
        const val ACAO_PARAR = "com.quall.android.PARAR_CONVERSAO_DVD"

        fun comecar(c: Context, titulo: Int) {
            androidx.core.content.ContextCompat.startForegroundService(
                c, Intent(c, ConversaoDvdService::class.java).putExtra(EXTRA_TITULO, titulo),
            )
        }

        /** A bancada da D1: um VOB em `Android/data/com.quall.android/files/`. */
        fun comecarDoArquivo(c: Context, nome: String) {
            androidx.core.content.ContextCompat.startForegroundService(
                c, Intent(c, ConversaoDvdService::class.java).putExtra(EXTRA_ARQUIVO, nome),
            )
        }

        fun parar(c: Context) {
            c.startService(Intent(c, ConversaoDvdService::class.java).setAction(ACAO_PARAR))
        }

        /** A `libqualldv` (e com ela o FFmpeg) está neste APK e aparelho (só arm64). */
        val disponivel: Boolean get() = QuallDv.disponivel
    }
}
