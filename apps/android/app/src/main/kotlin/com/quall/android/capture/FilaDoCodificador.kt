package com.quall.android.capture

/**
 * **Quantos quadros estão dentro de um codificador** que o [DivisorGl] alimenta, e a porta que
 * limita isso (`docs/teleprompter-com-camera.md` §14.11 e §14.12, achado 1).
 *
 * ## Por que existe
 *
 * O A10s (28/09): o codificador da rede dá ~25 fps a 1080×1920, a câmera entrega 30, e a superfície
 * de entrada do `MediaCodec` aceita uma dezena de quadros antes de a troca bloquear. A fila enche,
 * o vídeo sai ~0,37 s mais velho do que sairia, e o receptor recusa o relógio. A regra do projeto é
 * "zero filas": o quadro velho que ninguém vai ver a tempo não deve entrar.
 *
 * ## Como conta
 *
 * O divisor anota o carimbo de cada quadro que **desenhou** na saída ([desenhou]); o codificador, na
 * thread de dreno dele, anota o carimbo cru de cada quadro que **saiu** ([saiu]). Em trânsito são os
 * desenhados mais novos que o último que saiu. Um quadro que o próprio codificador descarta (o
 * `KEY_MAX_FPS_TO_ENCODER`) sai da conta quando um mais novo sai: a conta se refaz pelo carimbo, e
 * não deriva. **Antes do primeiro quadro sair nada é barrado**: um codificador que precisa de
 * alguns quadros para soltar o primeiro não pode ser esperado.
 *
 * ## A porta
 *
 * Com [teto] > 0, um quadro **não é desenhado** naquela saída quando já há [teto] em trânsito. Ela
 * reabre assim que o codificador solta um (a revisão, achado 1: a porta pelo atraso de carimbo não
 * reabria sozinha). Contra o impasse (um codificador que só solta com mais entrada): passados
 * [SONDA_US] sem desenhar ali, um quadro passa mesmo assim ([sondas]).
 *
 * Com [teto] 0 (o padrão até a prova, §14.12) nada é barrado, e a conta vai para o diário do mesmo
 * jeito: é ela que mostra, no A07 e no S24, quantos quadros um codificador que dá conta segura.
 *
 * Pura: a JVM testa. [saiu] é de uma thread (a do dreno); o resto, da thread GL.
 */
class FilaDoCodificador(
    /** O máximo em trânsito; 0 desliga a porta. */
    @Volatile var teto: Int = 0,
) {
    companion object {
        /** Sem desenhar há tanto tempo (no relógio da câmera), um quadro passa. */
        const val SONDA_US = 250_000L
        /** Quantos carimbos desenhados a conta guarda; acima disso o mais velho sai (o codificador perdido). */
        const val GUARDADOS = 64
    }

    /** O carimbo cru (µs) do último quadro que saiu do codificador; `Long.MIN_VALUE` antes do primeiro. */
    @Volatile var ultimoSaidoUs = Long.MIN_VALUE
        private set

    /** Da thread de dreno: um quadro com este carimbo cru saiu. */
    fun saiu(ptsUs: Long) {
        if (ptsUs > ultimoSaidoUs) ultimoSaidoUs = ptsUs
    }

    // --- só da thread GL ------------------------------------------------------------------------
    private val anel = LongArray(GUARDADOS)
    private var inicio = 0
    private var n = 0
    private var ultimoDesenhoUs = Long.MIN_VALUE

    /** Lidos no fim por outra thread (o `fechado` do gravador): só o diário. */
    @Volatile var pulados = 0L; private set
    @Volatile var sondas = 0L; private set

    // A janela do relato.
    private val naJanela = IntArray(GUARDADOS + 1)
    private var amostrasNaJanela = 0
    private var maiorNaJanela = 0
    private var puladosNaJanela = 0L

    /** Quantos estão em trânsito agora: tira da conta os que já saíram. */
    fun emTransito(): Int {
        val s = ultimoSaidoUs
        while (n > 0 && anel[inicio] <= s) {
            inicio = (inicio + 1) % GUARDADOS
            n--
        }
        return n
    }

    /**
     * Antes de desenhar o quadro de carimbo [carimboUs] nesta saída: desenha ou não. Conta para o
     * relato em qualquer caso.
     */
    fun deveDesenhar(carimboUs: Long): Boolean {
        val agora = emTransito()
        amostrasNaJanela++
        naJanela[minOf(agora, GUARDADOS)]++
        if (agora > maiorNaJanela) maiorNaJanela = agora
        val t = teto
        if (t <= 0 || ultimoSaidoUs == Long.MIN_VALUE || agora < t) return true
        if (ultimoDesenhoUs != Long.MIN_VALUE && carimboUs - ultimoDesenhoUs >= SONDA_US) {
            sondas++
            return true
        }
        pulados++
        puladosNaJanela++
        return false
    }

    /** O quadro foi trocado na superfície do codificador. */
    fun desenhou(carimboUs: Long) {
        ultimoDesenhoUs = carimboUs
        if (n == GUARDADOS) {
            inicio = (inicio + 1) % GUARDADOS
            n--
        }
        anel[(inicio + n) % GUARDADOS] = carimboUs
        n++
    }

    /** A linha da janela (e zera a janela): `em_transito p50/max`, e os pulados nela. */
    fun linhaDaJanela(): String {
        var p50 = 0
        var acumulado = 0
        for (i in naJanela.indices) {
            acumulado += naJanela[i]
            if (acumulado * 2 >= amostrasNaJanela) { p50 = i; break }
        }
        val s = "em_transito p50/max=$p50/$maiorNaJanela pulados=$puladosNaJanela" +
            (if (teto > 0) " (porta em $teto)" else " (porta desligada)")
        naJanela.fill(0)
        amostrasNaJanela = 0
        maiorNaJanela = 0
        puladosNaJanela = 0
        return s
    }
}
