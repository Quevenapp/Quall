package com.quall.android.dvd

/**
 * O estado da transmissão do DVD para a tela "Converter DVD" (`docs/dvd-para-mp4.md` §9, a T3), no
 * molde do [ConversaoDvdBus]. O PIN, o endereço e o "enviando para …" são do `MirrorBus` (a sessão
 * é a do Espelhar); aqui fica o que é do disco: o tempo do título, a pausa, o pulo e o fim.
 *
 * [controle] é a transmissão no ar (a tela manda Pausar, −30 s e +30 s direto a ela), ou `null`.
 */
object TransmissaoDvdBus {
    enum class Fase { NADA, PREPARANDO, NO_AR, PARADA }

    data class Estado(
        val fase: Fase = Fase.NADA,
        val volume: String = "",
        val titulo: Int = 0,
        /** O tempo do título que está na tela do receptor, e a duração dele (90 kHz). */
        val posicao90k: Long = 0,
        val duracao90k: Long = 0,
        val pausado: Boolean = false,
        /** Sem receptor: o disco espera (o relógio parado) até alguém conectar. */
        val semReceptor: Boolean = true,
        val pulando: Boolean = false,
        val fimDoTitulo: Boolean = false,
        /** A faixa de som que vai à rede ("português AC-3"), ou vazio sem som. */
        val som: String = "",
        /** O fim: a frase (a recusa do §2.1, o leitor que parou), ou vazio. */
        val mensagem: String = "",
        /** A gravação do que está sendo transmitido (a T4). */
        val gravando: Boolean = false,
        val gravacao90k: Long = 0,
        val gravacaoBytes: Long = 0,
        val gravacaoMensagem: String = "",
        /** Assistir aqui: o disco toca no próprio aparelho, sem rede ([AssistirAqui]). */
        val local: Boolean = false,
        /** O Ouvir (o som do disco no alto-falante do aparelho) está ligado. */
        val ouvindo: Boolean = false,
    )

    @Volatile var estado = Estado()
        private set
    @Volatile var controle: TransmissaoDoDvd? = null

    private val ouvintes = java.util.concurrent.ConcurrentHashMap<Any, (Estado) -> Unit>()
    private val principal by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }

    /** Há uma transmissão do disco no ar (o leitor é dela: a tela não lê nem converte). */
    val transmitindo: Boolean get() = estado.fase == Fase.PREPARANDO || estado.fase == Fase.NO_AR

    @Synchronized fun publicar(e: Estado) {
        estado = e
        for (o in ouvintes.values) principal.post { o(e) }
    }

    @Synchronized fun atualizar(bloco: (Estado) -> Estado) = publicar(bloco(estado))

    fun ouvir(dono: Any, o: ((Estado) -> Unit)?) {
        if (o == null) { ouvintes.remove(dono); return }
        ouvintes[dono] = o
        val e = estado
        principal.post { o(e) }
    }
}
