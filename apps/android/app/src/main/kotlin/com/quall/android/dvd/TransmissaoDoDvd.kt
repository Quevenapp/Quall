package com.quall.android.dvd

import com.quall.android.escritorYuv420
import android.hardware.HardwareBuffer
import android.content.Context
import android.hardware.DataSpace
import android.media.Image
import android.media.ImageWriter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import com.quall.android.R
import com.quall.android.audio.FonteDeAudio
import com.quall.android.core.Idioma
import com.quall.android.capture.MonotonicClock
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * **O DVD como fonte do Espelhar** (`docs/dvd-para-mp4.md` §9, a T1): o disco que está no leitor
 * vai ao receptor (o do Quall, o OBS) **sem gravar** — o mesmo caminho da conversão até o quadro
 * pronto (a [LeituraDoTitulo] → a fila de 8 MB em C → o `mpegps`, o MPEG-2, o som, o adapt2, o corte
 * de 704 e a escala), e dali ao **encoder H.264 da rede** (o `ImageWriter` na superfície dele, como a
 * placa e a DV) e à **trilha de som da sessão** ([fonteDeSom]).
 *
 * **O ritmo** (§9): a conversão corre o mais rápido possível; aqui cada quadro sai quando o carimbo
 * dele chega no [RelogioDoDisco]. Três threads:
 * - **a leitura** ([LeituraDoTitulo]): empurra as células para o C, e **para quando a fila enche**
 *   (o `dvd_empurrar` bloqueia) — o leitor lê ~4× mais rápido que o vídeo;
 * - **a decodificação** (`quall-dvd-decodifica`): o passo do C, cada quadro escalado para um dos
 *   [quadros] quadros da fila (1,5 s à frente da tela: o som do DVD vem atrás do vídeo no fluxo,
 *   [PoliticaDoRitmo]), e o
 *   PCM da faixa escolhida para a [FilaDoSomDoDisco];
 * - **o ritmo** (`quall-dvd-ritmo`): o quadro na hora dele vai ao encoder; sem saída (nenhum
 *   receptor), o relógio para e o disco espera — ninguém perde o começo do filme.
 *
 * **A proteção é a da conversão** (§2.1, falha fechado): o CPST e o perfil conferidos na abertura
 * (pelo `MirrorService`), o PES cifrado que para o C, o sense 0x6F e o prensado com setor ilegível
 * que param a leitura — tudo vira [Ouvinte.aoCair] com a frase, e a sessão termina. Nada vai à
 * Galeria.
 */
class TransmissaoDoDvd(
    private val contexto: Context,
    leitor: Setores,
    val volume: String,
    val titulo: TituloDoDvd,
    /** O índice da faixa da rede em [TituloDoDvd.faixasConvertiveis], ou -1 sem som. */
    val faixaDaRede: Int,
    /** O encoder da rede aceita 854 de largura (senão 848, como a DV). */
    aceita854: Boolean,
    private val ouvinte: Ouvinte,
    /**
     * **Assistir aqui** (o pedido do Pessoa Exemplo, 29/09: "no A07 não tem prévia para ver/escutar antes"): o
     * mesmo pipeline no ritmo do vídeo, sem sessão de rede — a prévia e o Ouvir são a saída, e o
     * relógio anda sem receptor ([AssistirAqui]).
     */
    val local: Boolean = false,
    /** O tempo do título onde começa (o Transmitir que vem do Assistir aqui segue do mesmo ponto). */
    inicio90k: Long = 0,
) {
    interface Ouvinte {
        /** A transmissão não pode seguir (a recusa, o leitor que parou): a frase para a pessoa. */
        fun aoCair(motivo: String)
    }

    val largura: Int
    val altura: Int
    val pal: Boolean = titulo.pal
    /** A taxa da rede: 30 (29,97) no NTSC, 25 no PAL. */
    val fps: Int = if (titulo.pal) 25 else 30
    private val intervaloUs: Long = if (titulo.pal) 40_000L else 33_367L
    /** A fila de quadros prontos: [PoliticaDoRitmo.SEGUNDOS_DE_FOLGA] à frente da tela (o som vai junto). */
    private val quadros: Int = PoliticaDoRitmo.quadrosDeFolga(fps)

    private val setores = SetoresComTrava(leitor)
    /** O `vobu_s_ptm` do primeiro VOBU de cada célula (pelo índice), visto quando a leitura passou. */
    private val sPtmDasCelulas = java.util.concurrent.ConcurrentHashMap<Int, Long>()
    private val celulaPeloPrimeiro: Map<Long, Int> = titulo.trechos.withIndex().associate { (i, t) -> t.primeiro to i }
    private val relogio = RelogioDoDisco()
    private val som = FilaDoSomDoDisco()
    private val faixas: List<FaixaDeSom> = titulo.faixasConvertiveis

    /** O pulo (a T2) troca a geração: os quadros e o som de uma geração velha caem. */
    private val geracao = AtomicInteger(0)
    /** O tempo do título onde o pipeline da próxima geração começa. */
    @Volatile private var alvoDoPulo = inicio90k.coerceIn(0, maxOf(0, titulo.duracao90k - 90_000))

    /** O pipeline no ar: o handle do C, a leitura, e o tempo do título do zero da saída dele. */
    private class Pipeline(val h: Long, val leitura: LeituraDoTitulo, val geracao: Int, val origem90k: Long)
    private val travaDoPipeline = Any()
    @Volatile private var avisouUmCanal = false
    @Volatile private var pipeline: Pipeline? = null

    /** Um quadro escalado (I420, [largura]×[altura]) e o carimbo dele. */
    private class Quadro(w: Int, h: Int) {
        val y: ByteBuffer = ByteBuffer.allocateDirect(w * h)
        val u: ByteBuffer = ByteBuffer.allocateDirect(w * h / 4)
        val v: ByteBuffer = ByteBuffer.allocateDirect(w * h / 4)
        var pts90k = 0L
        var dur90k = 3003L
        var geracao = -1
    }
    private val livres = LinkedBlockingQueue<Quadro>()
    private val prontos = LinkedBlockingQueue<Quadro>()

    @Volatile private var encerrado = false
    /** Pausar (a T2): o relógio para, a rede repete o último quadro, e o disco recebe a manutenção. */
    @Volatile var pausado = false
        private set
    /** Um pulo pedido ainda sem o primeiro quadro da geração nova na tela. */
    @Volatile private var pulando = false
    /** O último quadro do título já foi à tela (o ritmo escreve). */
    @Volatile private var fimNaTela = false
    /** A geração cujo título acabou (o C deu FIM), ou -1. */
    @Volatile private var fimDaGeracao = -1

    // a saída da rede (o ImageWriter na superfície do encoder), sob [travaDaSaida]
    private val travaDaSaida = Any()
    private var escritor: ImageWriter? = null
    private var livresNoEscritor = 0
    @Volatile private var temSaida = false
    private val threadDasImagens = HandlerThread("quall-dvd-imagens").also { it.start() }

    private var threadDecodifica: Thread? = null
    private var threadRitmo: Thread? = null
    private val trava: PowerManager.WakeLock =
        contexto.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "quall:transmissao-dvd")

    // o diário
    @Volatile var quadrosNaRede = 0L; private set
    @Volatile var repeticoes = 0L; private set
    @Volatile private var semImagem = 0L
    @Volatile private var quadrosDecodificados = 0L

    init {
        val (w, a) = ConversorDvd.tamanhoDeSaida(titulo.pal, titulo.aspecto169)
        largura = if (w == 854 && !aceita854) 848 else w
        altura = a
        repeat(quadros) { livres.add(Quadro(largura, altura)) }
    }

    /** O rótulo da faixa da rede, para a tela ("pt AC-3"), ou vazio sem som. */
    val rotuloDoSom: String get() = faixas.getOrNull(faixaDaRede)?.let { "${it.idioma ?: "?"} ${it.formato}" } ?: ""

    /** A leitura e a decodificação começam já: o primeiro quadro fica pronto antes de o receptor conectar. */
    fun comecar() {
        setores.aoLer = { lba, dados ->
            val c = celulaPeloPrimeiro[lba]
            if (c != null && !sPtmDasCelulas.containsKey(c)) Reposicionamento.navDoSetor(dados)?.let { sPtmDasCelulas[c] = it }
        }
        trava.acquire(12 * 60 * 60 * 1000L)
        TransmissaoDvdBus.controle = this
        TransmissaoDvdBus.publicar(TransmissaoDvdBus.Estado(
            fase = TransmissaoDvdBus.Fase.PREPARANDO, volume = volume, titulo = titulo.numero, local = local,
            duracao90k = titulo.duracao90k, som = rotuloDoSom,
        ))
        Log.i(TAG, "transmissão: título ${titulo.numero}, ${titulo.trechos.size} célula(s), " +
            "${if (pal) "PAL" else "NTSC"} ${if (titulo.aspecto169) "16:9" else "4:3"} -> ${largura}x$altura a $fps, " +
            "som ${faixas.getOrNull(faixaDaRede)?.let { "0x%x %s %s".format(it.substream, it.formato, it.idioma ?: "?") } ?: "nenhum"} " +
            "(${faixas.size} faixa(s) decodificada(s))")
        threadDecodifica = Thread({ decodificar() }, "quall-dvd-decodifica").also { it.start() }
        threadRitmo = Thread({ ritmo() }, "quall-dvd-ritmo").also { it.start() }
        threadGirando = Thread({ manterGirando() }, "quall-dvd-girando").also { it.start() }
    }

    private var threadGirando: Thread? = null

    /**
     * **O disco parado** (§8 e §9): com a leitura parada (pausado, sem receptor, o fim do título, ou a
     * fila cheia por muito tempo), um setor perto a cada [INTERVALO_DE_MANUTENCAO_NS] — o motor do hp
     * GTB0N para ~45 s depois do último acesso, e a partida dele derrubou o leitor com a fonte de 2 A.
     */
    private fun manterGirando() {
        var n = 0L
        try {
            while (!encerrado) {
                Thread.sleep(1_000)
                if (System.nanoTime() - setores.ultimoAcessoNs < INTERVALO_DE_MANUTENCAO_NS) continue
                val lba = Reposicionamento.setorDeManutencao(titulo.trechos, setores.ultimoLba, n++)
                try {
                    setores.lerParaManter(lba)
                    Log.i(TAG, "disco girando: setor $lba lido (transmissão ${if (pausado) "pausada" else "parada"})")
                } catch (e: RecusaDoDisco) {
                    cair(e.recusa, recusa = true); return
                } catch (e: LeitorParou) {
                    cair(FrasesDoDvd.LEITOR_PAROU); return
                }
            }
        } catch (_: InterruptedException) {
        }
    }

    // ---- os controles (a T2) -------------------------------------------------------------------

    /**
     * Pausar/Continuar: o relógio para (o ritmo aplica), a rede repete o último quadro como a câmera
     * parada, o som vai em silêncio, e a leitura para com a fila cheia — o disco recebe a leitura de
     * manutenção. Continuar no fim do título recomeça do começo.
     */
    fun pausar(p: Boolean) {
        if (!p && fimNaTela) {
            Log.i(TAG, "transmissão: continuar no fim do título — do começo")
            pausado = false
            pularPara(0)
            return
        }
        if (pausado == p) return
        pausado = p
        Log.i(TAG, "transmissão: ${if (p) "pausada" else "continua"} em ${segundos(posicao90k())}")
        TransmissaoDvdBus.atualizar { it.copy(pausado = p) }
    }

    /** Pular [delta90k] (±30 s): a partir do pulo em curso, se há um, senão de onde está a tela. */
    fun pular(delta90k: Long) {
        val base = if (pulando) alvoDoPulo else posicao90k()
        pularPara(base + delta90k)
    }

    private fun pularPara(t90k: Long) {
        val alvo = t90k.coerceIn(0, maxOf(0, titulo.duracao90k - 90_000))
        synchronized(travaDoPipeline) {
            if (encerrado) return
            alvoDoPulo = alvo
            pulando = true
            val g = geracao.incrementAndGet()
            // O C acorda (a decodificação pode estar esperando dado dele) e o pipeline velho fecha.
            pipeline?.leitura?.parar()
            Log.i(TAG, "transmissão: pular para ${segundos(alvo)} (geração $g)")
        }
        TransmissaoDvdBus.atualizar { it.copy(pulando = true, posicao90k = alvo, fimDoTitulo = false) }
    }

    // ---- a gravação do que está sendo transmitido (a T4) ----------------------------------------

    /**
     * **Gravar a transmissão** (o pedido do Pessoa Exemplo, 29/09: "opção de gravar também… como as câmeras na
     * transmissão"): o que vai à rede vai também a um MP4 na Galeria
     * (`Movies/Quall/Quall-DVD-<volume>-<título>-<hora>.mp4`), o mesmo da conversão ([ConversorDvd]:
     * H.264 3 Mbit/s GOP 1 s, **todas as faixas de som** em AAC, `IS_PENDING` até o fim, parcial
     * jogável) — o pipeline de C decodifica uma vez, e o quadro escalado vai aos dois encoders.
     *
     * **O carimbo do arquivo é contínuo**: ele anda pelo conteúdo de cada quadro novo que vai à tela
     * (a distância ao anterior da mesma geração), e não pelo relógio — pausado, nada entra e o
     * carimbo segue do ponto; o pulo grava a costura sem salto (um quadro nominal); a repetição da
     * câmera parada não entra. O som de cada faixa acompanha o vídeo do arquivo amostra a amostra,
     * tirado da fila dela pelo tempo de conteúdo ([FilaDoSomDoDisco]).
     */
    private class Gravacao(val conversor: ConversorDvd, val arquivo: GaleriaDoDvd.Arquivo) {
        /** O carimbo do arquivo do último quadro gravado (90 kHz), e as amostras de som já escritas. */
        var pts90k = -1L
        var amostras = 0L
        var ultimaDuracao90k = 3003L
        /** O conteúdo do último quadro gravado (geração e carimbo), e o do próximo som (amostra). */
        var geracao = -1
        var conteudo90k = 0L
        var somGeracao = -1
        var somConteudo = 0L
        var quadrosCaidos = 0L
    }

    private val somDaGravacao: List<FilaDoSomDoDisco> = faixas.map { FilaDoSomDoDisco() }
    private val travaDaGravacao = Any()
    @Volatile private var gravacao: Gravacao? = null
    @Volatile private var abrindoGravacao = false
    /** A recusa (§2.1) viu o disco: a gravação é apagada, e não publicada. */
    @Volatile private var recusado = false
    private val pcmDaGravacao = ShortArray(2 * 48_000)
    private val bufDaGravacao: ByteBuffer = ByteBuffer.allocateDirect(4 * 48_000).order(ByteOrder.nativeOrder())

    /** Gravar ou parar de gravar (a tela). O arquivo abre e fecha fora da thread de quem chama. */
    fun gravar(ligar: Boolean) {
        if (!ligar) { Thread({ pararDeGravar() }, "quall-dvd-gravar-parar").start(); return }
        synchronized(travaDaGravacao) {
            if (gravacao != null || abrindoGravacao || encerrado || recusado) return
            abrindoGravacao = true
        }
        // Marcado antes do arquivo existir: o `publicarPendentes` não remonta um MP4 no ar.
        TransmissaoDvdBus.atualizar { it.copy(gravando = true, gravacao90k = 0, gravacaoBytes = 0, gravacaoMensagem = "") }
        Thread({ abrirGravacao() }, "quall-dvd-gravar").start()
    }

    private fun abrirGravacao() {
        var arquivo: GaleriaDoDvd.Arquivo? = null
        try {
            val livre = runCatching {
                android.os.StatFs(android.os.Environment.getExternalStorageDirectory().path).availableBytes
            }.getOrDefault(Long.MAX_VALUE)
            if (livre < ESPACO_MINIMO) {
                throw ErroDoDvd(Frase(R.string.dvd_gravacao_pouco_espaco, livre / 1_000_000), "${livre / 1_000_000} MB livres")
            }
            val hora = java.text.SimpleDateFormat("HHmmss", java.util.Locale.US).format(java.util.Date())
            val nome = GaleriaDoDvd.nome(volume, titulo.numero).removeSuffix(".mp4") + "-$hora.mp4"
            val a = GaleriaDoDvd.criar(contexto, nome)
            arquivo = a
            val c = ConversorDvd(0L, a.pfd.fd, pal, titulo.aspecto169, faixas.size,
                faixas.map { ConversorDvd.idioma639_2(it.idioma) }, larguraPedida = largura)
            if (c.largura != largura || c.altura != altura) {
                c.encerrar()
                throw IllegalStateException("o encoder da gravação ficou em ${c.largura}x${c.altura}, e a transmissão em ${largura}x$altura")
            }
            synchronized(travaDaGravacao) {
                abrindoGravacao = false
                if (recusado) {
                    // A recusa chegou enquanto o arquivo abria: marcado e apagado (o `catch` apaga).
                    GaleriaDoDvd.marcarRecusado(contexto, a.uri)
                    c.encerrar(); throw ErroDoDvd(FrasesDoDvd.PROTEGIDO, "a recusa chegou durante a abertura")
                }
                if (encerrado) { c.encerrar(); throw ErroDoDvd(Frase(R.string.dvd_transmissao_acabou), "a transmissão acabou") }
                gravacao = Gravacao(c, a)
                comecarThreadDaGravacao()
            }
            Log.i(TAG, "gravação: começou (${largura}x$altura, ${faixas.size} faixa(s) AAC)")
        } catch (e: Exception) {
            synchronized(travaDaGravacao) { abrindoGravacao = false }
            Log.w(TAG, "gravação: não começou: ${Log.erroExterno(e.message)}")
            arquivo?.let { runCatching { it.pfd.close() }; GaleriaDoDvd.apagar(contexto, it.uri) }
            val frase = texto(Frase(R.string.dvd_gravacao_nao_comecou, e.fraseDoDvd()))
            TransmissaoDvdBus.atualizar { it.copy(gravando = false, gravacaoMensagem = frase) }
        }
    }

    // A fila da gravação (a revisão, 3): o ritmo copia o quadro para um destes e segue; a thread da
    // gravação o leva ao encoder. Cheia (o encoder da gravação atrás), o quadro cai e conta — o ritmo
    // da rede nunca espera o codec da gravação.
    private val livresDaGravacao = LinkedBlockingQueue<Quadro>()
    private val filaDaGravacao = LinkedBlockingQueue<Quadro>()
    @Volatile private var quadrosDaGravacaoCriados = 0
    @Volatile private var descartadosNaFila = 0L
    @Volatile private var fecharFilaDaGravacao = false
    private var threadDaGravacao: Thread? = null

    /** Sob [travaDaGravacao]. */
    private fun comecarThreadDaGravacao() {
        if (quadrosDaGravacaoCriados == 0) {
            repeat(QUADROS_DA_GRAVACAO) { livresDaGravacao.add(Quadro(largura, altura)) }
            quadrosDaGravacaoCriados = QUADROS_DA_GRAVACAO
        }
        fecharFilaDaGravacao = false
        threadDaGravacao = Thread({
            try {
                while (true) {
                    val q = filaDaGravacao.poll(50, TimeUnit.MILLISECONDS)
                    if (q == null) { if (fecharFilaDaGravacao) break else continue }
                    try { gravarQuadro(q) } finally { livresDaGravacao.offer(q) }
                }
            } catch (_: InterruptedException) {
            }
        }, "quall-dvd-gravacao").also { it.start() }
    }

    /** Na thread do ritmo: uma cópia do quadro para a fila da gravação, sem esperar nada. */
    private fun oferecerAGravacao(q: Quadro) {
        if (gravacao == null) return
        val b = livresDaGravacao.poll() ?: run { descartadosNaFila++; return }
        for ((de, para) in listOf(q.y to b.y, q.u to b.u, q.v to b.v)) {
            para.clear(); para.put(de.duplicate().apply { clear() })
        }
        b.pts90k = q.pts90k; b.dur90k = q.dur90k; b.geracao = q.geracao
        filaDaGravacao.offer(b)
    }

    /** Na thread da gravação: o quadro vai ao arquivo, e o som até ele. */
    private fun gravarQuadro(q: Quadro) {
        synchronized(travaDaGravacao) {
            val g = gravacao ?: return
            val (pts, continua) = Reposicionamento.carimboDaGravacao(
                g.pts90k, g.geracao, g.conteudo90k, g.ultimaDuracao90k, q.geracao, q.pts90k,
            )
            // O som até o começo deste quadro no arquivo (o conteúdo do anterior); na primeira vez, nada.
            if (g.pts90k >= 0) escreverSom(g, pts)
            if (!continua) { g.somGeracao = q.geracao; g.somConteudo = Math.floorDiv(q.pts90k * 8, 15L) }
            if (g.conversor.gravarQuadro(pts, q.dur90k) { img -> copiar(q, img) }) {
                g.pts90k = pts
                g.geracao = q.geracao
                g.conteudo90k = q.pts90k
                g.ultimaDuracao90k = q.dur90k
            } else {
                g.quadrosCaidos++
                // O carimbo não anda sem quadro: o som já escrito até `pts` fica, e o próximo quadro sai
                // colado a ele pelo conteúdo.
                if (g.pts90k < 0) return
                g.pts90k = pts; g.geracao = q.geracao; g.conteudo90k = q.pts90k
            }
            val e = g.conversor.erro
            if (e != null) {
                Log.w(TAG, "gravação: o encoder parou: ${Log.erroExterno(e)}")
                Thread({ pararDeGravar(e) }, "quall-dvd-gravar-parar").start()
                return
            } else if (g.pts90k / 90_000 != TransmissaoDvdBus.estado.gravacao90k / 90_000) {
                TransmissaoDvdBus.atualizar { it.copy(gravacao90k = g.pts90k, gravacaoBytes = g.conversor.bytes) }
            }
        }
    }

    /** O som de todas as faixas até o carimbo [ate90k] do arquivo, tirado de cada fila pelo conteúdo. */
    private fun escreverSom(g: Gravacao, ate90k: Long) {
        val alvo = Math.floorDiv(ate90k * 8, 15L)
        var falta = (alvo - g.amostras).coerceAtMost(48_000L).toInt()
        if (falta <= 0) return
        while (falta > 0) {
            val n = minOf(falta, 4_096)
            for (k in faixas.indices) {
                somDaGravacao[k].tirar(g.somGeracao, g.somConteudo, pcmDaGravacao, n, 2)
                bufDaGravacao.clear()
                bufDaGravacao.asShortBuffer().put(pcmDaGravacao, 0, 2 * n)
                g.conversor.gravarSom(k, bufDaGravacao, n)
            }
            g.amostras += n
            g.somConteudo += n
            falta -= n
        }
    }

    /** Fecha a gravação: o som do último quadro, o MP4, e publica (ou apaga, na recusa). */
    fun pararDeGravar(motivo: Frase? = null) {
        // A fila esvazia antes (os quadros que já foram à tela entram no arquivo), com prazo.
        val t = synchronized(travaDaGravacao) { threadDaGravacao.also { threadDaGravacao = null } }
        if (t != null && t !== Thread.currentThread()) {
            fecharFilaDaGravacao = true
            t.join(5_000)
            if (t.isAlive) { Log.w(TAG, "gravação: a fila não esvaziou em 5 s"); t.interrupt(); t.join(2_000) }
        }
        filaDaGravacao.drainTo(livresDaGravacao)
        val g = synchronized(travaDaGravacao) {
            val x = gravacao ?: return
            gravacao = null
            if (x.pts90k >= 0) escreverSom(x, x.pts90k + x.ultimaDuracao90k)
            x
        }
        val erro = g.conversor.encerrar()
        val soltou = g.conversor.terminou
        val fim: Frase = if (recusado) {
            GaleriaDoDvd.marcarRecusado(contexto, g.arquivo.uri)
            if (soltou) runCatching { g.arquivo.pfd.close() }
            GaleriaDoDvd.apagar(contexto, g.arquivo.uri)
            Frase(R.string.dvd_gravacao_apagada, FrasesDoDvd.PROTEGIDO)
        } else if (!soltou) {
            Frase(R.string.dvd_gravacao_pendente)
        } else {
            runCatching { g.arquivo.pfd.close() }
            if (g.conversor.bytes == 0L) {
                GaleriaDoDvd.apagar(contexto, g.arquivo.uri)
                Frase(R.string.dvd_gravacao_sem_quadros)
            } else if (GaleriaDoDvd.publicar(contexto, g.arquivo.uri)) {
                val nome = GaleriaDoDvd.nomeReal(contexto, g.arquivo.uri) ?: g.arquivo.nome
                (motivo ?: erro)?.let { Frase(R.string.dvd_gravacao_parcial, it, nome) } ?: Frase(R.string.dvd_salvo_na_galeria, nome)
            } else Frase(R.string.dvd_gravacao_nao_publicada)
        }
        val mensagem = texto(fim)
        Log.i(TAG, "gravação: $mensagem; ${g.pts90k / 90_000} s, ${g.conversor.bytes} bytes, quadros caídos ${g.quadrosCaidos} " +
            "(fila cheia: $descartadosNaFila), " +
            "som de ${g.amostras} amostras por faixa")
        TransmissaoDvdBus.atualizar { it.copy(gravando = false, gravacaoMensagem = mensagem) }
    }

    // ---- a saída da rede (o encoder: `H264DvdEncoder`) -----------------------------------------

    /** Liga a superfície de entrada do encoder (a sessão com um receptor). Na thread do encoder. */
    fun ligar(surface: Surface, w: Int, h: Int) {
        synchronized(travaDaSaida) {
            require(w == largura && h == altura) { "o encoder em ${w}x$h, e a transmissão em ${largura}x$altura" }
            val e = if (Build.VERSION.SDK_INT >= 33) {
                // O formato pelo HardwareBuffer (YCBCR_420_888), como a conversão e a DV.
                ImageWriter.Builder(surface)
                    .setMaxImages(MAX_IMAGENS)
                    .setHardwareBufferFormat(HardwareBuffer.YCBCR_420_888)
                    .setDataSpace(if (pal) DataSpace.DATASPACE_BT601_625 else DataSpace.DATASPACE_BT601_525)
                    .build()
            } else {
                escritorYuv420(surface, MAX_IMAGENS)
            }
            // Por escritor (a revisão, 9): o Image devolvido pelo escritor de uma sessão velha não conta no novo.
            e.setOnImageReleasedListener({ synchronized(travaDaSaida) { if (escritor === e) livresNoEscritor++ } }, Handler(threadDasImagens.looper))
            escritor = e
            livresNoEscritor = MAX_IMAGENS
            temSaida = true
            Log.i(TAG, "transmissão: ligada ao encoder ${w}x$h")
        }
        TransmissaoDvdBus.atualizar { it.copy(semReceptor = false) }
    }

    /** Solta a superfície (o receptor saiu): o relógio para, e o disco espera o próximo. */
    fun desligar() {
        synchronized(travaDaSaida) {
            val e = escritor ?: return
            escritor = null
            temSaida = false
            runCatching { e.close() }
            Log.i(TAG, "transmissão: desligada do encoder; na rede=$quadrosNaRede repetidos=$repeticoes sem_imagem=$semImagem")
        }
        TransmissaoDvdBus.atualizar { it.copy(semReceptor = true) }
    }

    // ---- o som da sessão -----------------------------------------------------------------------

    /** Há som para a rede (o título tem uma faixa que o Quall decodifica). */
    val temSom: Boolean get() = faixaDaRede in faixas.indices

    /**
     * A origem da trilha de som da sessão (Opus 48 kHz), no lugar do microfone: cada quadro de 20 ms
     * leva as amostras da hora que o relógio do vídeo diz ([FilaDoSomDoDisco]). **Não bloqueia**: o
     * ritmo é o acumulador do emissor, como o tom; a hora do quadro é a nossa, e anda 20 ms por quadro.
     */
    fun fonteDeSom(taxaHz: Int, canais: Int, amostrasPorCanal: Int): FonteDeAudio? {
        if (!temSom || taxaHz != 48_000 || canais !in 1..2) {
            Log.w(TAG, "transmissão: sem som na rede (faixa $faixaDaRede, preset ${taxaHz}Hz ${canais}ch)")
            return null
        }
        return object : FonteDeAudio {
            override val nome = texto(Frase(R.string.dvd_fonte_de_som, rotuloDoSom))
            private var horaUs = Long.MIN_VALUE
            private val quadroUs = amostrasPorCanal * 1_000_000L / taxaHz

            override fun proximoQuadro(pcm: ShortArray): Int {
                val agora = MonotonicClock.micros()
                // A hora deste quadro: a do anterior + 20 ms, e de volta a agora se escorregou (o
                // emissor dormiu a mais, ou é o primeiro).
                horaUs = if (horaUs == Long.MIN_VALUE || kotlin.math.abs(horaUs + quadroUs - agora) > 3 * quadroUs) agora
                else horaUs + quadroUs
                val g = relogio.geracao
                som.tirar(g, relogio.amostraEm(g, horaUs), pcm, amostrasPorCanal, canais)
                return amostrasPorCanal
            }

            override fun instanteDoQuadroUs(): Long? = if (horaUs == Long.MIN_VALUE) null else horaUs

            override fun fechar() {}
        }
    }

    // ---- a decodificação -----------------------------------------------------------------------

    private fun decodificar() {
        val tempos = LongArray(2)
        val pcm = ByteBuffer.allocateDirect(PCM_POR_VEZ * 4).order(ByteOrder.nativeOrder())
        val pcmCurto = ShortArray(PCM_POR_VEZ * 2)
        var p: Pipeline? = null
        try {
            while (!encerrado) {
                val g = geracao.get()
                if (p == null || p.geracao != g) {
                    // A falha da leitura velha (a recusa, o leitor parado) **antes** de descartá-la (a
                    // revisão da transmissão, 1): um prensado com setor ilegível + "+30 s" não pode
                    // trocar a recusa por um pipeline novo.
                    val velho = p
                    p = null
                    if (velho != null) naoEngolir(fecharPipeline(velho))
                    // Os quadros da geração velha voltam (o ritmo descarta o que ainda segura).
                    val velhos = ArrayList<Quadro>()
                    prontos.drainTo(velhos)
                    livres.addAll(velhos)
                    som.reiniciar(g)
                    somLocal.reiniciar(g)
                    for (f in somDaGravacao) f.reiniciar(g)
                    fimDaGeracao = -1
                    p = abrirPipeline(g, alvoDoPulo) ?: return
                    val r = QuallDvd.preparar(p.h)
                    if (r < 0) {
                        if (geracao.get() != g || encerrado) continue
                        cairPeloFim(r, p.leitura)
                        return
                    }
                    val info = QuallDvd.Info.de(QuallDvd.info(p.h))
                    Log.i(TAG, "transmissão: o fluxo diz ${info.largura}x${info.altura} ${info.fpsNum}/${info.fpsDen}, " +
                        "${if (info.entrelacado) "entrelaçado" else "progressivo"}, faixas ${info.faixas.joinToString { "0x%x".format(it) }}")
                    continue
                }
                if (fimDaGeracao == g) {
                    Thread.sleep(20)
                    continue
                }
                val r = QuallDvd.passo(p.h)
                if (r < 0) {
                    if (geracao.get() != g || encerrado) continue
                    cairPeloFim(r, p.leitura)
                    return
                }
                if (r == QuallDvd.QUADRO) {
                    while (QuallDvd.quadro(p.h, tempos) == 1) {
                        val q = pegarLivre(g) ?: break
                        val e = QuallDvd.escrever(p.h, q.y, largura, q.u, q.v, largura / 2, 1, largura, altura)
                        if (e != 0) {
                            Log.w(TAG, "transmissão: o quadro em ${tempos[0]} não foi escrito (${Log.erroExterno(e)})")
                            livres.offer(q)
                            continue
                        }
                        q.pts90k = tempos[0]
                        q.dur90k = tempos[1]
                        q.geracao = g
                        prontos.offer(q)
                        quadrosDecodificados++
                    }
                }
                for (k in faixas.indices) {
                    while (true) {
                        val n = QuallDvd.som(p.h, k, pcm, PCM_POR_VEZ)
                        if (n <= 0) break
                        pcm.asShortBuffer().get(pcmCurto, 0, n * 2)
                        if (k == faixaDaRede) {
                            som.empurrar(g, pcmCurto, n)
                            if (ouvindo != null) somLocal.empurrar(g, pcmCurto, n)
                        }
                        // Todas as faixas para a gravação (a T4), na hora do quadro que as leva.
                        somDaGravacao[k].empurrar(g, pcmCurto, n)
                        pcm.clear()
                    }
                }
                if (r == QuallDvd.FIM) {
                    Log.i(TAG, "transmissão: o fim do título (geração $g)")
                    fimDaGeracao = g
                }
            }
        } catch (e: InterruptedException) {
            // o encerrar
        } catch (e: RecusaDoDisco) {
            cair(e.recusa, recusa = true)
        } catch (e: LeitorParou) {
            cair(FrasesDoDvd.LEITOR_PAROU)
        } catch (e: Throwable) {
            Log.e(TAG, "transmissão: a decodificação morreu", e)
            cair(Frase(R.string.dvd_transmissao_falhou, Frase.cru("${e.javaClass.simpleName}: ${e.message}")))
        } finally {
            // O último pipeline também: a recusa que ele viu no fechamento (o Parar logo depois de um
            // setor cifrado) ainda apaga a gravação, que só fecha depois disto (o `encerrar`).
            val f = p?.let { fecharPipeline(it) }
            if (f is RecusaDoDisco) marcarRecusa(f.recusa)
        }
    }

    /** Um quadro livre para a [g]; `null` se a geração mudou ou a transmissão acabou. */
    private fun pegarLivre(g: Int): Quadro? {
        while (!encerrado && geracao.get() == g) {
            val q = livres.poll(50, TimeUnit.MILLISECONDS)
            if (q != null) return q
        }
        return null
    }

    /**
     * O pipeline da geração [g] a partir do tempo [alvo90k] do título: o começo lê as células como
     * estão; um pulo (a T2) procura o VOBU. `null` quando a transmissão já acabou.
     */
    private fun abrirPipeline(g: Int, alvo90k: Long): Pipeline? {
        val (trechos, origem) = trechosPara(alvo90k)
        val h = QuallDvd.abrir(faixas.map { it.substream }.toIntArray())
        if (h == 0L) throw IllegalStateException("sem memória para o pipeline do DVD")
        val l = LeituraDoTitulo(setores, trechos, DestinoQuallDvd(h))
        val p = Pipeline(h, l, g, origem)
        synchronized(travaDoPipeline) {
            if (encerrado) { QuallDvd.fechar(h); return null }
            pipeline = p
        }
        l.comecar()
        Log.i(TAG, "transmissão: pipeline $g a partir de ${segundos(origem)} (alvo ${segundos(alvo90k)})")
        return p
    }

    /**
     * **O reposicionamento** (a T2, `Reposicionamento`): o começo lê as células como estão; um pulo
     * acha a célula do tempo pedido e o setor estimado nela, procura dali para a frente o NAV pack do
     * VOBU (até 1 MB, sem sair da célula) e começa nele, com o tempo dele (pelo `vobu_s_ptm` e o do
     * primeiro VOBU da célula) como a origem. Sem NAV achado, a célula inteira.
     */
    private fun trechosPara(alvo90k: Long): Pair<List<TrechoDoTitulo>, Long> {
        val todos = titulo.trechos
        if (alvo90k <= 0) {
            val c = todos.first()
            return Reposicionamento.trechosDesde(todos, 0, c.primeiro, c.acumulado90k) to c.acumulado90k
        }
        val a = Reposicionamento.alvo(todos, titulo.duracao90k, alvo90k)
        val c = todos[a.celula]
        val durCelula = Reposicionamento.duracoes(todos, titulo.duracao90k)[a.celula]
        // O `vobu_s_ptm` do primeiro VOBU da célula, **guardado quando a leitura passou por ele** (a
        // revisão, 4): ler o começo da célula agora seria um salto longo da cabeça — o pico que derruba
        // o leitor com a fonte fraca. Sem ele, o tempo do VOBU é a estimativa pela fração da célula.
        val sPtmCelula = sPtmDasCelulas[a.celula]
        var lba = a.lba
        val limite = minOf(c.ultimo, a.lba + PROCURA_DO_NAV - 1)
        while (lba <= limite && !encerrado) {
            val n = minOf(LeitorDeDisco.SETORES_POR_COMANDO.toLong(), limite - lba + 1).toInt()
            val b = setores.ler(lba, n)
            for (i in 0 until n) {
                val sPtm = Reposicionamento.navDoSetor(b, i * 2048) ?: continue
                val vobu = lba + i
                val origem = Reposicionamento.tempoDoVobu(c.acumulado90k, durCelula, sPtmCelula, sPtm, a.tempo90k)
                Log.i(TAG, "transmissão: pulo para ${segundos(a.tempo90k)}: célula ${a.celula + 1}, VOBU no setor $vobu " +
                    "(estimado ${a.lba}), ${segundos(origem)} do título")
                return Reposicionamento.trechosDesde(todos, a.celula, vobu, origem) to origem
            }
            lba += n
        }
        Log.w(TAG, "transmissão: pulo para ${segundos(a.tempo90k)}: sem NAV de ${a.lba} a $limite; a célula ${a.celula + 1} do começo")
        return Reposicionamento.trechosDesde(todos, a.celula, c.primeiro, c.acumulado90k) to c.acumulado90k
    }

    /**
     * Para a leitura (acorda o C), espera ela sair e solta o C; se ela não sair, o C fica (vazamento
     * consciente) e a leitura entra nas [presas] (o leitor só volta à tela quando ela sair). Devolve a
     * falha que a leitura viu — a recusa ou o leitor parado —, que quem chama não pode descartar.
     */
    private fun fecharPipeline(p: Pipeline): Throwable? {
        synchronized(travaDoPipeline) {
            if (pipeline === p) pipeline = null
            p.leitura.parar()
        }
        p.leitura.esperar(10_000)
        if (p.leitura.terminou) QuallDvd.fechar(p.h)
        else {
            Log.w(TAG, "transmissão: a leitura não saiu em 10 s; o pipeline fica sem soltar")
            presas += p.leitura
        }
        return p.leitura.falha
    }

    /** As leituras que não saíram no prazo: o leitor não volta à tela enquanto uma delas viver. */
    private val presas = java.util.concurrent.CopyOnWriteArrayList<LeituraDoTitulo>()

    /** A falha do pipeline que sai (o pulo): a recusa e o leitor parado seguem como se fossem do novo. */
    private fun naoEngolir(f: Throwable?) {
        when (f) {
            is RecusaDoDisco -> { Log.w(TAG, "transmissão: a leitura velha viu a recusa: ${Log.erroExterno(f)}"); throw f }
            is LeitorParou -> throw f
        }
    }

    /** A frase do fim pelo código do C e pelo que a leitura viu (como a conversão). */
    private fun motivoDoFim(r: Int, l: LeituraDoTitulo): Frase {
        l.esperar(2_000)
        val f = l.falha
        return when {
            f is RecusaDoDisco -> f.recusa
            f is LeitorParou -> FrasesDoDvd.LEITOR_PAROU
            r == QuallDvd.ERRO_CIFRADO -> FrasesDoDvd.PROTEGIDO
            r == QuallDvd.ERRO_LEITOR && f != null -> Frase(R.string.dvd_leitura_falhou, Frase.cru("${f.message}"))
            else -> QuallDvd.motivo(r)
        }
    }

    /** O fim de um pipeline pelo código do C: a frase, e se é recusa (a leitura sabe o motivo de verdade). */
    private fun cairPeloFim(r: Int, l: LeituraDoTitulo) {
        val m = motivoDoFim(r, l)
        cair(m, recusa = l.falha is RecusaDoDisco || r == QuallDvd.ERRO_CIFRADO)
    }

    /**
     * A transmissão não segue. **A recusa** (§2.1, falha fechado) marca e apaga a gravação em curso,
     * como o parcial da conversão — a marca persistente já aqui (a revisão, 2), antes de o arquivo
     * fechar: se o processo morrer no meio, o `publicarPendentes` apaga em vez de publicar.
     */
    private fun cair(motivo: Frase, recusa: Boolean = false) {
        if (recusa) marcarRecusa(motivo)
        if (encerrado) return
        // A frase no idioma de agora: o Bus e o `MirrorService` (o Espelhar) recebem texto pronto.
        val frase = texto(motivo)
        Log.w(TAG, "transmissão: parou — ${Log.erroExterno(frase)}")
        TransmissaoDvdBus.atualizar { it.copy(mensagem = frase) }
        runCatching { ouvinte.aoCair(frase) }
    }

    /**
     * Uma [Frase] no idioma escolhido (`docs/traducao.md`, Android): o [contexto] é o do serviço (ou o da
     * aplicação, no Assistir aqui), que o AppCompat não alcança abaixo do Android 13. Pedido a cada vez.
     */
    private fun texto(f: Frase): String = f.em(Idioma.textos(Idioma.contexto(contexto)))

    private fun marcarRecusa(motivo: Frase) {
        recusado = true
        synchronized(travaDaGravacao) {
            gravacao?.let {
                GaleriaDoDvd.marcarRecusado(contexto, it.arquivo.uri)
                Log.w(TAG, "gravação: marcada como recusada (${Log.erroExterno(motivo)})")
            }
        }
    }

    // ---- o ritmo -------------------------------------------------------------------------------

    private fun ritmo() {
        var pendente: Quadro? = null
        var ultimo: Quadro? = null
        var ultimaSaidaUs = 0L
        var ultimoTsUs = Long.MIN_VALUE
        var ultimoPublicado = 0L
        // A carga antes de ancorar (a geração nova espera a fila encher) e o diário de 10 s do som.
        var geracaoDaCarga = -1
        var cargaDesdeUs = 0L
        var diarioEmUs = MonotonicClock.micros() + DIARIO_US
        var caidasAntes = 0L
        var silencioAntes = 0L
        try {
            while (!encerrado) {
                val agora = MonotonicClock.micros()
                val g = geracao.get()
                if (g != geracaoDaCarga) { geracaoDaCarga = g; cargaDesdeUs = agora }
                if (agora >= diarioEmUs) {
                    diarioEmUs = agora + DIARIO_US
                    val c = som.caidas
                    val si = som.silencio
                    val alvo = relogio.amostraEm(relogio.geracao, agora)
                    val frente = if (alvo != null && som.geracao == relogio.geracao) (som.fim - alvo) / 48 else null
                    Log.i(TAG, "som (10 s): caídas +${c - caidasAntes} silêncio +${si - silencioAntes} " +
                        "fila ${som.tamanho} amostras (${frente?.let { "$it ms à frente da hora" } ?: "sem hora"}), " +
                        "quadros prontos ${prontos.size}/$quadros")
                    caidasAntes = c
                    silencioAntes = si
                    // Um canal só no disco (29/09): o C espelha, e a tela diz. Sob a trava: o `fechar(h)` só
                    // corre depois de o pipeline sair dela.
                    if (!avisouUmCanal) {
                        val copiado = synchronized(travaDoPipeline) { pipeline?.let { QuallDvd.canalCopiado(it.h) } ?: 0 }
                        if (copiado != 0) {
                            avisouUmCanal = true
                            val som = texto(Frase(R.string.dvd_som_um_canal, rotuloDoSom, QuallDvd.UM_CANAL_SO))
                            TransmissaoDvdBus.atualizar { it.copy(som = som) }
                        }
                    }
                }
                if (relogio.ancorado && relogio.geracao != g) relogio.soltar()
                pendente?.let { if (it.geracao != g) { livres.offer(it); pendente = null } }
                val fim = fimDaGeracao == g && pendente == null && prontos.isEmpty()
                fimNaTela = fim
                val haSaida = temSaida || local
                val parado = !haSaida || fim || pausado
                if (parado) relogio.pausar(agora) else relogio.continuar(agora)
                if (agora - ultimoPublicado > 250_000) {
                    ultimoPublicado = agora
                    publicarPosicao(agora, fim)
                }
                if (parado && haSaida && (pulando || ultimo == null)) {
                    // Pausado, o pulo mostra o quadro de onde ele caiu (e o relógio ancora ali, parado);
                    // e o receptor que chega com a transmissão pausada antes do primeiro quadro vê o
                    // primeiro, e não uma tela preta (a revisão, 8).
                    if (pendente == null) {
                        pendente = prontos.poll()?.let { if (it.geracao != g) { livres.offer(it); null } else it }
                    }
                    val q = pendente
                    if (q != null) {
                        pendente = null
                        relogio.ancorar(g, q.pts90k, agora)
                        pulando = false
                        val ts = maxOf(agora, if (ultimoTsUs == Long.MIN_VALUE) agora else ultimoTsUs + 1_000)
                        if (apresentar(q, ts)) { ultimoTsUs = ts; quadrosNaRede++ }
                        desenharPrevia(q)
                        ultimo?.let { livres.offer(it) }
                        ultimo = q
                        ultimaSaidaUs = agora
                        continue
                    }
                }
                if (!parado) {
                    if (pendente == null) {
                        pendente = prontos.poll()?.let { if (it.geracao != g) { livres.offer(it); null } else it }
                    }
                    val q = pendente
                    if (q != null) {
                        if (!relogio.ancorado) {
                            // A carga (o som pipocando, 29/09): o relógio só ancora com a fila de quadros
                            // cheia, para o som — que vem atrás do vídeo no fluxo — chegar antes da hora.
                            if (!PoliticaDoRitmo.podeAncorar(prontos.size + 1, quadros, fimDaGeracao == g, agora - cargaDesdeUs)) {
                                dormirUs(5_000)
                                continue
                            }
                            relogio.ancorar(g, q.pts90k, agora); pulando = false
                        }
                        else if (relogio.alinharSeAtrasado(q.pts90k, agora, ATRASO_US)) {
                            Log.i(TAG, "transmissão: o quadro chegou atrasado (a leitura engasgou?); o relógio andou " +
                                "(${relogio.reancoragens} vez(es))")
                        }
                        val hora = relogio.instanteUs(q.pts90k)
                        if (hora - agora > 1_000) {
                            dormirUs(minOf(hora - agora, 10_000L))
                            continue
                        }
                        pendente = null
                        val ts = maxOf(hora, if (ultimoTsUs == Long.MIN_VALUE) hora else ultimoTsUs + 1_000)
                        if (apresentar(q, ts)) { ultimoTsUs = ts; quadrosNaRede++ }
                        oferecerAGravacao(q)
                        desenharPrevia(q)
                        ultimo?.let { livres.offer(it) }
                        ultimo = q
                        ultimaSaidaUs = agora
                        continue
                    }
                }
                // Parado (sem receptor, fim do título) ou sem quadro (a leitura atrás): o último quadro
                // de novo, como a câmera parada — no intervalo de um quadro parado, e depois de
                // [ESPERA_ANTES_DE_REPETIR_US] quando falta quadro.
                val u = ultimo
                // A prévia trocou de superfície (a tela girou, voltou): o último quadro de novo nela.
                if (u != null && PreviaDoDvd.versao != versaoDaPrevia) desenharPrevia(u)
                val espera = if (parado) intervaloUs else ESPERA_ANTES_DE_REPETIR_US
                if (u != null && temSaida && agora - ultimaSaidaUs >= espera) {
                    val ts = maxOf(agora, if (ultimoTsUs == Long.MIN_VALUE) agora else ultimoTsUs + 1_000)
                    if (apresentar(u, ts)) { ultimoTsUs = ts; repeticoes++ }
                    ultimaSaidaUs = agora
                }
                dormirUs(5_000)
            }
        } catch (_: InterruptedException) {
        } catch (e: Throwable) {
            Log.e(TAG, "transmissão: o ritmo morreu", e)
            cair(Frase(R.string.dvd_transmissao_falhou, Frase.cru("${e.javaClass.simpleName}: ${e.message}")))
        } finally {
            soltarGpu()
        }
    }

    // ---- a prévia no próprio aparelho (a tela do DVD) --------------------------------------------

    // O `RenderizadorDv` da DV e da placa (o YCbCr BT.601 limitado → RGB na GPU), com o contexto EGL da
    // thread do ritmo: a prévia mostra o quadro que acabou de ir à rede, no mesmo relógio.
    private var gpu: com.quall.android.capture.dv.RenderizadorDv? = null
    private var gpuFalhou = false
    private var alvoDaPrevia: com.quall.android.capture.dv.RenderizadorDv.Alvo? = null
    private var versaoDaPrevia = -1

    /** Na thread do ritmo. Uma falha desliga a prévia, e não a transmissão. */
    private fun desenharPrevia(q: Quadro) {
        if (gpuFalhou || (PreviaDoDvd.superficie == null && alvoDaPrevia == null)) return
        try {
            val r = gpu ?: com.quall.android.capture.dv.RenderizadorDv().also {
                if (!it.iniciar()) { gpuFalhou = true; Log.e(TAG, "prévia: a GPU não subiu"); return }
                // Os planos da fila: I420 do tamanho de saída (pixels quadrados), o croma 4:2:0 no centro.
                it.configurar(com.quall.android.capture.dv.Geometria(largura, altura, largura / 2, altura / 2, largura, altura, true))
                gpu = it
            }
            if (!PreviaDoDvd.trava.tryLock(50, TimeUnit.MILLISECONDS)) return
            try {
                if (PreviaDoDvd.versao != versaoDaPrevia) {
                    alvoDaPrevia?.let { r.soltar(it) }
                    alvoDaPrevia = PreviaDoDvd.superficie?.let { r.alvo(it, PreviaDoDvd.largura, PreviaDoDvd.altura) }
                    versaoDaPrevia = PreviaDoDvd.versao
                }
                val a = alvoDaPrevia ?: return
                r.subir(arrayOf(q.y.duplicate(), q.u.duplicate(), q.v.duplicate()))
                r.desenhar(a, largura, altura)
            } finally {
                PreviaDoDvd.trava.unlock()
            }
        } catch (t: Throwable) {
            gpuFalhou = true
            Log.e(TAG, "prévia: falhou e foi desligada (a transmissão segue)", t)
        }
    }

    private fun soltarGpu() {
        val r = gpu ?: return
        runCatching { alvoDaPrevia?.let { r.soltar(it) } }
        alvoDaPrevia = null
        runCatching { r.liberar() }
        gpu = null
    }

    // ---- ouvir no próprio aparelho -------------------------------------------------------------

    /** O som da faixa da rede para o alto-falante do aparelho (o Ouvir), na hora do mesmo relógio. */
    private val somLocal = FilaDoSomDoDisco()
    @Volatile private var ouvindo: Thread? = null
    @Volatile private var pararDeOuvir = false

    /**
     * **Ouvir** (desligado por padrão, como o Ouvir da placa): um `AudioTrack` de baixa latência com o
     * PCM do disco. A escrita bloqueia no ritmo do aparelho; a hora de cada quadro de 20 ms anda com
     * ele, e as amostras saem da fila pela hora do [RelogioDoDisco] — o que se ouve aqui é o que vai à
     * rede.
     */
    fun ouvir(ligar: Boolean) {
        synchronized(this) {
            if (ligar) {
                if (ouvindo != null || !temSom || encerrado) return
                pararDeOuvir = false
                somLocal.reiniciar(geracao.get())
                ouvindo = Thread({ tocar() }, "quall-dvd-ouvir").also { it.start() }
            } else {
                val t = ouvindo ?: return
                pararDeOuvir = true
                ouvindo = null
                t.join(1_000)
            }
        }
        TransmissaoDvdBus.atualizar { it.copy(ouvindo = ligar && ouvindo != null) }
    }

    private fun tocar() {
        val taxa = 48_000
        val quadro = 960
        val trilha = runCatching {
            val min = android.media.AudioTrack.getMinBufferSize(taxa, android.media.AudioFormat.CHANNEL_OUT_STEREO,
                android.media.AudioFormat.ENCODING_PCM_16BIT)
            android.media.AudioTrack.Builder()
                .setAudioAttributes(android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build())
                .setAudioFormat(android.media.AudioFormat.Builder()
                    .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(taxa)
                    .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_STEREO)
                    .build())
                .setPerformanceMode(android.media.AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .setTransferMode(android.media.AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(min, quadro * 4 * 2))
                .build()
        }.getOrNull()
        if (trilha == null || trilha.state != android.media.AudioTrack.STATE_INITIALIZED) {
            trilha?.release()
            Log.w(TAG, "ouvir: o telefone não abriu a saída de som")
            synchronized(this) { ouvindo = null }
            TransmissaoDvdBus.atualizar { it.copy(ouvindo = false) }
            return
        }
        val pcm = ShortArray(quadro * 2)
        val quadroUs = quadro * 1_000_000L / taxa
        var hora = Long.MIN_VALUE
        Log.i(TAG, "ouvir: ligado (AudioTrack $taxa Hz estéreo, baixa latência, ${trilha.bufferSizeInFrames} quadros)")
        try {
            trilha.play()
            while (!pararDeOuvir && !encerrado) {
                // A hora do quadro: a do anterior + 20 ms (a escrita bloqueia no ritmo do aparelho); de
                // volta a agora se escorregou mais de meio segundo (a thread parada, o aparelho trocado).
                val agora = MonotonicClock.micros()
                hora = if (hora == Long.MIN_VALUE || kotlin.math.abs(hora + quadroUs - agora) > 500_000) agora else hora + quadroUs
                val g = relogio.geracao
                somLocal.tirar(g, relogio.amostraEm(g, hora), pcm, quadro, 2)
                if (trilha.write(pcm, 0, pcm.size) < 0) break
            }
        } finally {
            runCatching { trilha.pause(); trilha.flush(); trilha.stop() }
            trilha.release()
            Log.i(TAG, "ouvir: desligado; caídas=${somLocal.caidas} silêncio=${somLocal.silencio}")
        }
    }

    /** O tempo do título agora (90 kHz): a origem do pipeline + o relógio. */
    fun posicao90k(agoraUs: Long = MonotonicClock.micros()): Long {
        val p = pipeline
        val t = relogio.posicao90k(agoraUs) ?: return p?.origem90k ?: alvoDoPulo
        val origem = if (p != null && p.geracao == relogio.geracao) p.origem90k else alvoDoPulo
        return (origem + t).coerceIn(0, titulo.duracao90k)
    }

    private fun publicarPosicao(agora: Long, fim: Boolean) {
        val pos = posicao90k(agora)
        val e = TransmissaoDvdBus.estado
        val fase = if (quadrosNaRede > 0 || relogio.ancorado) TransmissaoDvdBus.Fase.NO_AR else TransmissaoDvdBus.Fase.PREPARANDO
        if (e.posicao90k / 90_000 != pos / 90_000 || e.fimDoTitulo != fim || e.fase != fase ||
            e.pausado != pausado || e.pulando != pulando) {
            TransmissaoDvdBus.atualizar { it.copy(fase = fase, posicao90k = pos, fimDoTitulo = fim, pausado = pausado, pulando = pulando) }
        }
    }

    /** O quadro no `Image` do escritor da rede, carimbado em [tsUs] (µs do monotônico). */
    private fun apresentar(q: Quadro, tsUs: Long): Boolean = synchronized(travaDaSaida) {
        val e = escritor ?: return false
        if (livresNoEscritor <= 0) { semImagem++; return false }
        val img = try { e.dequeueInputImage() } catch (x: Exception) {
            Log.w(TAG, "transmissão: o escritor recusou: ${Log.erroExterno(x)}")
            return false
        }
        livresNoEscritor--
        var foi = false
        try {
            copiar(q, img)
            img.timestamp = tsUs * 1000L
            e.queueInputImage(img)
            foi = true
        } catch (x: Exception) {
            Log.w(TAG, "transmissão: o quadro não foi à rede: ${Log.erroExterno(x)}")
        } finally {
            if (!foi) { runCatching { img.close() }; livresNoEscritor++ }
        }
        foi
    }

    /** O I420 do quadro nos planos do `Image` (o passo de linha e de pixel dele). */
    private fun copiar(q: Quadro, img: Image) {
        val p = img.planes
        require(p.size >= 3) { "o Image não é YUV de 3 planos (formato ${img.format})" }
        copiarPlano(q.y, largura, largura, altura, p[0])
        copiarPlano(q.u, largura / 2, largura / 2, altura / 2, p[1])
        copiarPlano(q.v, largura / 2, largura / 2, altura / 2, p[2])
    }

    private fun copiarPlano(src: ByteBuffer, passo: Int, w: Int, h: Int, dst: Image.Plane) {
        val d = dst.buffer
        val rs = dst.rowStride
        val ps = dst.pixelStride
        if (ps == 1) {
            val s = src.duplicate()
            for (y in 0 until h) {
                s.limit(y * passo + w).position(y * passo)
                d.position(y * rs)
                d.put(s)
            }
        } else {
            for (y in 0 until h) {
                val o = y * rs
                val so = y * passo
                for (x in 0 until w) d.put(o + x * ps, src.get(so + x))
            }
        }
    }

    private fun dormirUs(us: Long) {
        if (us <= 0) return
        Thread.sleep(us / 1000, ((us % 1000) * 1000).toInt())
    }

    /** Para tudo: as threads saem, a leitura para, o C é solto. O leitor volta a quem o deu. */
    fun encerrar() {
        if (encerrado) return
        encerrado = true
        ouvir(false)
        synchronized(travaDoPipeline) { pipeline?.leitura?.parar() }
        threadRitmo?.let { it.interrupt(); it.join(3_000) }
        threadGirando?.let { it.interrupt(); it.join(3_000) }
        threadDecodifica?.let { it.join(12_000); if (it.isAlive) Log.w(TAG, "transmissão: a decodificação não saiu em 12 s") }
        // Depois das threads (a revisão, 1): a recusa que o último pipeline viu ao fechar já marcou.
        pararDeGravar()
        desligar()
        threadDasImagens.quitSafely()
        if (trava.isHeld) trava.release()
        if (TransmissaoDvdBus.controle === this) TransmissaoDvdBus.controle = null
        Log.i(TAG, "transmissão: encerrada; decodificados=$quadrosDecodificados na_rede=$quadrosNaRede " +
            "repetidos=$repeticoes sem_imagem=$semImagem reancoragens=${relogio.reancoragens} " +
            "som: caídas=${som.caidas} silêncio=${som.silencio} recusadas=${som.recusadas}")
    }

    /**
     * Todas as threads que tocam o leitor já saíram — a decodificação, o ritmo, a manutenção e as
     * leituras (também as [presas] de um pulo): só então o leitor pode voltar à tela (a revisão, 6).
     */
    val terminou: Boolean
        get() = listOfNotNull(threadDecodifica, threadRitmo, threadGirando).none { it.isAlive } &&
            presas.all { it.terminou } && pipeline?.leitura?.terminou != false

    /** Espera [terminou] até [prazoMs] (0: sem prazo). `true` se terminou. */
    fun esperarTerminar(prazoMs: Long): Boolean {
        val limite = if (prazoMs <= 0) Long.MAX_VALUE else System.nanoTime() + prazoMs * 1_000_000
        while (!terminou) {
            if (System.nanoTime() > limite) return false
            Thread.sleep(100)
        }
        return true
    }

    private fun segundos(t90k: Long) = "%.1f s".format(java.util.Locale.US, t90k / 90_000.0)

    companion object {
        private const val TAG = "QuallDvd"
        /** A fila de quadros prontos: ~0,4 s à frente da tela a 29,97 (o som decodificado vai junto). */
        private const val MAX_IMAGENS = 4
        private const val PCM_POR_VEZ = 4096
        /** O quadro atrasado além disto empurra o relógio (a leitura engasgou). */
        private const val ATRASO_US = 60_000L
        /** Sem quadro (a leitura atrás) por mais que isto, o último vai de novo. */
        private const val ESPERA_ANTES_DE_REPETIR_US = 150_000L
        /** Até onde o pulo procura o NAV pack à frente do setor estimado: 1 MB. */
        private const val PROCURA_DO_NAV = 512L
        /** O diário do som a cada 10 s (a prova do conserto do som pipocando). */
        private const val DIARIO_US = 10_000_000L
        /** A fila da gravação: ~0,25 s de quadros entre o ritmo e o encoder dela. */
        private const val QUADROS_DA_GRAVACAO = 8
        /** Abaixo disto a gravação não começa (a conversão confere a estimativa; aqui não há duração). */
        private const val ESPACO_MINIMO = 500_000_000L
        /** A cada 20 s, e não 45 (§7: o motor nem para). */
        private const val INTERVALO_DE_MANUTENCAO_NS = 20_000_000_000L
    }
}

/**
 * O leitor com uma trava (a leitura, o pulo e a leitura de manutenção são threads diferentes, e o
 * bulk-only é um comando por vez), e o último setor pedido (onde a cabeça está).
 */
class SetoresComTrava(private val s: Setores) : Setores {
    @Volatile var ultimoLba = 0L
        private set
    /** `System.nanoTime` do último acesso (a manutenção, §8: o motor para ~45 s depois dele). */
    @Volatile var ultimoAcessoNs = System.nanoTime()
        private set

    /** Quem quer ver os setores lidos (o NAV do começo de cada célula, para o pulo). */
    @Volatile var aoLer: ((Long, ByteArray) -> Unit)? = null

    @Synchronized
    override fun ler(lba: Long, n: Int): ByteArray {
        try {
            return s.ler(lba, n).also { d -> aoLer?.let { runCatching { it(lba, d) } } }
        } finally {
            ultimoLba = lba
            ultimoAcessoNs = System.nanoTime()
        }
    }

    /** Um setor só para o disco girar: conta como acesso, mas não mexe em [ultimoLba]. */
    @Synchronized
    fun lerParaManter(lba: Long) {
        try {
            s.ler(lba, 1)
        } finally {
            ultimoAcessoNs = System.nanoTime()
        }
    }
}
