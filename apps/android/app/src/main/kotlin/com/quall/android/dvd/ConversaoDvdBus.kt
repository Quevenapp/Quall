package com.quall.android.dvd

/** O estado da conversão para a tela e a notificação, no molde do `GravacaoBus`. */
object ConversaoDvdBus {
    enum class Fase { NADA, PREPARANDO, CONVERTENDO, PARADA }

    data class Estado(
        val fase: Fase = Fase.NADA,
        val nome: String = "",
        /** Setores do título já lidos, e o total (a barra, §2.7). */
        val setoresLidos: Long = 0,
        val setoresDoTitulo: Long = 0,
        /** O tempo do título já convertido, e a duração dele (90 kHz). */
        val tempo90k: Long = 0,
        val duracao90k: Long = 0,
        /** A estimativa do que falta, em ms (-1 sem estimativa ainda). */
        val restanteMs: Long = -1,
        val setoresPulados: Long = 0,
        /**
         * O fim: a frase para a pessoa (a recusa, o erro, ou "salvo em Movies/Quall/…"), montada no idioma
         * de quando foi publicada. A tela prefere [fim], que ela monta no idioma do momento.
         */
        val mensagem: String = "",
        val publicado: Boolean = false,
        /** O fim sem idioma (`docs/traducao.md`, Android); `null` quando quem publicou só deu [mensagem]. */
        val fim: Frase? = null,
    ) {
        val fracao: Float get() = if (setoresDoTitulo > 0) (setoresLidos.toFloat() / setoresDoTitulo).coerceIn(0f, 1f) else 0f
    }

    @Volatile var estado = Estado()
        private set
    private var ouvinte: ((Estado) -> Unit)? = null
    private val principal by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }

    /** Há uma conversão no ar (o arquivo pendente dela não é órfão; `publicarPendentes` espera). */
    val convertendo: Boolean get() = estado.fase == Fase.PREPARANDO || estado.fase == Fase.CONVERTENDO

    /**
     * Um MP4 do DVD está sendo escrito: a conversão, ou a gravação da transmissão (a T4). O
     * `publicarPendentes` não remonta nada com um deles no ar.
     */
    val arquivoNoAr: Boolean get() = convertendo || TransmissaoDvdBus.estado.gravando

    @Synchronized fun publicar(e: Estado) {
        estado = e
        val o = ouvinte ?: return
        principal.post { o(e) }
    }

    @Synchronized fun atualizar(bloco: (Estado) -> Estado) = publicar(bloco(estado))

    @Synchronized fun ouvir(o: ((Estado) -> Unit)?) {
        ouvinte = o
        if (o != null) { val e = estado; principal.post { o(e) } }
    }
}
