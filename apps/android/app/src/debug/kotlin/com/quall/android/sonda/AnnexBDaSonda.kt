package com.quall.android.sonda

/**
 * Leitura de Annex-B **da sonda**, deliberadamente separada de `capture/AnnexB.kt`.
 *
 * O produto precisa saber *se* um buffer tem IDR; a sonda precisa saber *onde cada fatia começa e
 * termina* — que é outra pergunta e outra conta. Misturar as duas faria o instrumento e o objeto
 * medido compartilharem o mesmo defeito, que é a regra que `tools/fatias.py` já segue em relação a
 * `crates/quall-core/src/track.rs` ("quem confere não pode ser o mesmo código que escreve").
 *
 * Nada aqui decodifica imagem. Lê cabeçalho de NAL e o primeiro campo do cabeçalho de fatia
 * (`first_mb_in_slice`), pela mesma regra de `tools/fatias.py` e de `sonda-fatias` no macOS.
 */
internal object AnnexBDaSonda {

    /** 1..5 carregam fatia de imagem. */
    val VCL = 1..5
    const val NAL_IDR = 5
    const val NAL_SPS = 7
    const val NAL_PPS = 8

    /**
     * Um NAL dentro do fluxo.
     *
     * [inicioComPrefixo] inclui o start code, para que recortar o fluxo por fatia produza um
     * Annex-B válido sem remontagem.
     */
    data class Nal(
        val tipo: Int,
        val inicioComPrefixo: Int,
        val fim: Int,
        /** Índice do byte de cabeçalho do NAL — o primeiro depois do start code. */
        val cabecalho: Int,
    ) {
        val bytes: Int get() = fim - cabecalho
    }

    /** Divide um Annex-B em NALs. Aceita prefixo de 3 e de 4 bytes. */
    fun nals(b: ByteArray, ate: Int = b.size): List<Nal> {
        val inicios = ArrayList<Int>()
        var i = 0
        while (i + 3 <= ate) {
            if (b[i] == 0.toByte() && b[i + 1] == 0.toByte() && b[i + 2] == 1.toByte()) {
                inicios.add(i)
                i += 3
            } else {
                i++
            }
        }
        val saida = ArrayList<Nal>(inicios.size)
        for ((k, tres) in inicios.withIndex()) {
            var prefixo = tres
            // Um prefixo de 4 bytes é um de 3 com um zero na frente; o zero pertence ao prefixo.
            if (prefixo > 0 && b[prefixo - 1] == 0.toByte()) prefixo--
            val cabecalho = tres + 3
            if (cabecalho >= ate) continue
            val fim = if (k + 1 < inicios.size) {
                var f = inicios[k + 1]
                if (f > 0 && b[f - 1] == 0.toByte()) f--
                f
            } else {
                ate
            }
            saida.add(Nal(b[cabecalho].toInt() and 0x1F, prefixo, fim, cabecalho))
        }
        return saida
    }

    /**
     * `first_mb_in_slice` — o primeiro campo do cabeçalho de fatia, um Exp-Golomb sem sinal.
     * Zero significa "primeira fatia de uma imagem nova", que é a fronteira de unidade de acesso.
     *
     * Lê os bits **crus**: `first_mb_in_slice` vem antes de qualquer sequência `00 00 03`
     * possível, então desescapar não muda o resultado e acrescentaria uma cópia do NAL inteiro.
     */
    fun primeiroMacroblocoDaFatia(b: ByteArray, cabecalho: Int): Int? {
        var bit = 0
        fun u1(): Int {
            val idx = cabecalho + 1 + (bit shr 3)
            if (idx >= b.size) return 0
            val v = (b[idx].toInt() shr (7 - (bit and 7))) and 1
            bit++
            return v
        }
        var zeros = 0
        while (u1() == 0 && zeros < 32) zeros++
        if (zeros >= 32) return null
        var resto = 0
        for (i in 0 until zeros) resto = (resto shl 1) or u1()
        return (1 shl zeros) - 1 + resto
    }

    /**
     * Reparte o fluxo em unidades de acesso: nova unidade a cada fatia com
     * `first_mb_in_slice == 0` depois de já ter havido fatia.
     */
    fun unidadesDeAcesso(b: ByteArray): List<IntRange> {
        val lista = nals(b)
        val saida = ArrayList<IntRange>()
        var inicio = if (lista.isEmpty()) 0 else lista.first().inicioComPrefixo
        var fim = inicio
        var temFatia = false
        for (n in lista) {
            if (n.tipo in VCL) {
                val primeira = primeiroMacroblocoDaFatia(b, n.cabecalho) == 0
                if (temFatia && primeira) {
                    saida.add(inicio until fim)
                    inicio = n.inicioComPrefixo
                    temFatia = false
                }
                temFatia = true
            }
            fim = n.fim
        }
        if (fim > inicio) saida.add(inicio until fim)
        return saida
    }
}
