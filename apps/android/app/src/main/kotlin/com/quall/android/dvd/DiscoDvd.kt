package com.quall.android.dvd

/** O que o disco tem, para a tela (`docs/dvd-para-mp4.md` §2.1, item 1). */
data class DiscoDvd(
    val volume: String,
    val sistema: String,
    val titulos: List<TituloDoDvd>,
    /** O que não pôde ser lido (um VTS com IFO ruim), para o diário. */
    val avisos: List<String>,
) {
    /** O título padrão: o mais longo que o Quall converte. */
    val padrao: TituloDoDvd? get() = titulos.filter { it.recusa == null }.maxByOrNull { it.duracao90k }

    companion object {
        /** O maior IFO que se lê (os de verdade têm dezenas a centenas de KB). */
        private const val MAIOR_IFO = 8L * 1024 * 1024

        /**
         * Lê o sistema de arquivos e os IFO. [RecusaDoDisco] quando não é um DVD de vídeo que o
         * Quall converte (sem `VIDEO_TS`; o DVD-VR não finalizado).
         */
        fun ler(s: Setores, setoresDoDisco: Long? = null): DiscoDvd {
            val c = SistemaDeArquivos.ler(s)
            if (c.videoTs == null) {
                val vr = c.raiz.any { it.nome.equals("DVD_RTAV", true) || it.nome.equals("VIDEO_RM", true) }
                throw RecusaDoDisco(
                    if (vr) FrasesDoDvd.NAO_FINALIZADO else FrasesDoDvd.NAO_E_DVD_DE_VIDEO,
                    "sem VIDEO_TS (${c.sistema}; raiz: ${c.raiz.joinToString { it.nome }})",
                )
            }
            val vmgArq = c.arquivo("VIDEO_TS.IFO") ?: c.arquivo("VIDEO_TS.BUP")
                ?: throw RecusaDoDisco(FrasesDoDvd.SEM_VIDEO_TS_IFO, "sem VIDEO_TS.IFO nem VIDEO_TS.BUP")
            val vmg = SistemaDeArquivos.lerBytes(s, vmgArq.lba, vmgArq.tamanho.coerceIn(2048, MAIOR_IFO))
            val entradas = Ifo.titulosDoVmg(vmg)
            val avisos = ArrayList<String>()
            val cache = HashMap<Int, Pair<ByteArray, Long>?>()
            val titulos = entradas.mapNotNull { e ->
                val ifo = cache.getOrPut(e.vts) {
                    val nome = "VTS_%02d_0.IFO".format(e.vts)
                    val a = c.arquivo(nome) ?: c.arquivo("VTS_%02d_0.BUP".format(e.vts))
                    if (a == null) {
                        avisos += "sem $nome"
                        null
                    } else {
                        if (a.lba != e.inicioDoVts) avisos += "$nome no setor ${a.lba}, o TT_SRPT diz ${e.inicioDoVts}"
                        SistemaDeArquivos.lerBytes(s, a.lba, a.tamanho.coerceIn(2048, MAIOR_IFO)) to a.lba
                    }
                } ?: return@mapNotNull null
                runCatching { Ifo.titulo(e, ifo.first, ifo.second, setoresDoDisco) }
                    .onFailure { avisos += "título ${e.numero}: ${it.message}" } // i18n-fora: diário (os avisos do disco só vão ao logcat)
                    .getOrNull()
            }
            return DiscoDvd(c.volume, c.sistema, titulos, avisos)
        }
    }
}
