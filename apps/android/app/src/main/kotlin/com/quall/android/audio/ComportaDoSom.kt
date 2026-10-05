package com.quall.android.audio

/**
 * **A comporta entre a linha do som e o AAC da gravação** (a prova de 24/09 no A07, achado A).
 * Pura: quem chama passa as posições.
 *
 * ## O defeito que ela fecha
 *
 * No arquivo de 10 min o som terminava **+136,4 ms depois da imagem** (o `fase3-ffprobe.py` aceita
 * 50). A [LinhaDoSomDaGravacao] corta o que passa do fim do último quadro — mas o fim só é conhecido
 * quando o fim de fluxo do vídeo **sai do codificador**, e até lá o microfone continua entregando.
 * O gravador mandava cada pedaço ao AAC assim que a linha o soltava, então tudo o que o microfone
 * captou entre o último quadro desenhado e o fim de fluxo processado (a saída do divisor desligando,
 * o `signalEndOfInputStream`, a latência do codificador de vídeo) já estava codificado quando o
 * limite chegou. Não havia como desfazer: o AAC não tem volta.
 *
 * ## A regra
 *
 * O som espera o vídeo. Um pedaço só passa ao AAC até a posição do **último quadro de vídeo que já
 * saiu do codificador** ([teto]); o resto fica aqui. No fim de fluxo o teto vira o **fim do último
 * quadro**, e o que passa dele é jogado fora ([cortarDesde]). Assim o som e a imagem terminam juntos
 * a menos do arredondamento do AAC (o último pacote é inteiro, 1024 amostras, 21 ms).
 *
 * O preço é a latência do codificador de vídeo em som guardado (dezenas de ms, alguns quadros de
 * 20 ms), e, com a câmera parada, o som acumulado até o vigia parar a gravação (3 s).
 */
class ComportaDoSom(val canais: Int) {

    /** Um pedaço contínuo de PCM (intercalado, [canais] canais), a partir da amostra [posicao] do arquivo. */
    class Pedaco(val pcm: ShortArray, var desde: Int, var n: Int, var posicao: Long)

    fun interface Consumidor {
        /**
         * Entrega até [n] amostras por canal de [pcm] a partir de [desde], na posição [posicao]; devolve
         * quantas aceitou (0 = sem lugar agora: o resto espera a próxima vez).
         */
        fun aceitar(pcm: ShortArray, desde: Int, n: Int, posicao: Long): Int
    }

    private val fila = ArrayDeque<Pedaco>()

    /** Amostras por canal jogadas fora por [cortarDesde] (o som depois do fim da imagem). */
    var cortadas = 0L
        private set

    /** Até onde (amostras por canal, exclusivo) o som pode ir ao AAC; `null` = sem limite. */
    var teto: Long? = 0L

    val vazia: Boolean get() = fila.isEmpty()

    /** Amostras por canal esperando. */
    val esperando: Long get() = fila.sumOf { it.n.toLong() }

    /** Um pedaço da linha. Copia: a linha reaproveita o vetor do silêncio. */
    fun entrar(pcm: ShortArray, desde: Int, n: Int, posicao: Long) {
        if (n <= 0) return
        fila.addLast(Pedaco(pcm.copyOfRange(desde * canais, (desde + n) * canais), 0, n, posicao))
    }

    /** Solta ao [consumidor] o que couber abaixo do [teto], em ordem. */
    fun soltar(consumidor: Consumidor) {
        while (true) {
            val p = fila.firstOrNull() ?: return
            val lim = teto
            val cabe = if (lim == null) p.n.toLong() else minOf(p.n.toLong(), lim - p.posicao)
            if (cabe <= 0) return
            val k = consumidor.aceitar(p.pcm, p.desde, cabe.toInt(), p.posicao)
            if (k <= 0) return
            p.desde += k
            p.n -= k
            p.posicao += k
            if (p.n <= 0) fila.removeFirst()
        }
    }

    /** Joga fora tudo o que estiver em [posicao] ou depois (o fim da imagem). */
    fun cortarDesde(posicao: Long) {
        val it = fila.iterator()
        while (it.hasNext()) {
            val p = it.next()
            if (p.posicao >= posicao) {
                cortadas += p.n
                it.remove()
            } else if (p.posicao + p.n > posicao) {
                val fora = (p.posicao + p.n - posicao).toInt()
                p.n -= fora
                cortadas += fora
            }
        }
    }
}
