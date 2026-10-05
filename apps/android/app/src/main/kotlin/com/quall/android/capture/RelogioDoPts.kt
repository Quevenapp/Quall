package com.quall.android.capture

import java.util.Locale

/**
 * **O relógio do `presentationTimeUs`, medido e não acreditado** (`docs/som-no-receptor.md` §19.4;
 * crítica 3, achado 6).
 *
 * ## Por que existe
 *
 * O vídeo sai com o `presentationTimeUs` do encoder, que é a hora que a **fonte** carimbou no
 * buffer. Na tela ela é `MONOTONIC` (o `BufferQueue` da `VirtualDisplay`). Na câmera ela é o que o
 * aparelho quiser: o A07 declara `REALTIME` (`BOOTTIME`) e ficou a ~2,94 h de `elapsedRealtime` —
 * compatível com `MONOTONIC`, num aparelho que dormiu 2,94 h desde o boot; o A10s declara `UNKNOWN`.
 * O som sai em `MONOTONIC`. Converter `BOOTTIME`→`MONOTONIC` **pela declaração** introduziria 2,94 h
 * de erro no A07 — e nem a declaração nem a plausibilidade do número bastam sozinhas
 * ([H264CameraEncoder]).
 *
 * ## O que ela faz
 *
 * No primeiro quadro, com as duas horas lidas juntas:
 * - `m = MONOTONIC(agora) − PTS` e `b = MONOTONIC(agora) − BOOTTIME(agora)` (`b ≤ 0`: é o tempo que
 *   o aparelho dormiu desde o boot, com o sinal trocado);
 * - `|m − b| ≤ 300 ms` com `|b|` acima de 300 ms: o PTS é `BOOTTIME`. O carimbo recebe `b`, lido na
 *   hora, exato;
 * - senão, `0 ≤ m ≤ 2 s`: o PTS **é** `MONOTONIC`, e `m` é a latência da captura até a saída do
 *   encoder. Nada muda. **O limite de 2 s** (a revisão do código, E; era 300 ms): o primeiro quadro
 *   carrega o encoder e a câmera aquecendo, e o A07 já mostrou 251 ms de encode em regime; com
 *   300 ms, um primeiro quadro lento virava desconhecido, e a correção `m` atrasava o vídeo inteiro
 *   por ele. Um relógio desconhecido de verdade dá `m` de horas (outra época) ou negativo, e não de
 *   centenas de ms; acima de 2 s, o vídeo já não serve de qualquer jeito. A ordem importa: com o
 *   aparelho tendo dormido, o `BOOTTIME` dá `m ≈ b` (negativo) e é pego antes;
 * - qualquer outra coisa: relógio **desconhecido**. O carimbo recebe `m` — que carrega a latência
 *   da captura, então o vídeo fica atrasado por ela —, e o diário diz, com os números.
 *
 * A decisão é tomada **uma vez** (mudar no meio seria um degrau no vídeo), e o `m` mínimo segue
 * medido para o relatório.
 *
 * ## A zona ambígua, e o que a declaração da câmera decide nela (R5, fase 2)
 *
 * Com `|b|` abaixo de 300 ms (o aparelho quase não dormiu desde o boot), `MONOTONIC` e `BOOTTIME`
 * não se distinguem pela medida. Até a fase 2 do R5 isso "não precisava": o erro era menor que a
 * tolerância. **Com o microfone junto da câmera, precisa**: até 300 ms de erro entre a imagem e o
 * som é a boca fora do tempo, e o critério da claquete (`docs/teleprompter-com-camera.md` §8, G4) é
 * p05 ≥ −45 ms. Pior: com `b` de −200 ms e 76 ms de latência (a do S24, S-A1), `m` sai −124 ms,
 * negativo, e o quadro caía em **desconhecido**, com a latência inteira somada ao vídeo.
 *
 * Então, **só nessa zona**, a declaração da câmera desempata ([declaradoBoottime], o
 * `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME`): se ela diz `BOOTTIME` e `m − b` é uma latência plausível
 * (0 a 2 s), o carimbo recebe `b`. A frontal do S24 declara e é `BOOTTIME` (S-A1, §8.2). O preço, num
 * aparelho que declara e mente (o A07), é errar por `|b|` — menos de 300 ms, o mesmo tamanho do erro
 * de não corrigir num aparelho que diz a verdade; fora da zona ambígua a medida continua mandando, e
 * o A07 de 2,94 h continua certo.
 *
 * Pura, sem relógio: quem chama passa as horas.
 */
class RelogioDoPts(
    /**
     * `false` só na bancada (`prova_pts_cru`): mede e classifica igual, mas o carimbo sai com o PTS
     * cru — o comportamento de antes, que é o controle da prova.
     */
    private val corrigir: Boolean = true,
    /**
     * A fonte **declara** `BOOTTIME` (a câmera com `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME`). Só
     * desempata a zona ambígua; ver a classe. A tela passa `false`.
     */
    private val declaradoBoottime: Boolean = false,
) {
    enum class Classe { MONOTONIC, BOOTTIME, DESCONHECIDO }

    companion object {
        /** A tolerância do `BOOTTIME`: `|b|` acima dela, e `|m − b|` abaixo. */
        const val TOLERANCIA_US = 300_000L
        /** A latência máxima do primeiro quadro, da captura à saída do encoder, que ainda conta
         *  como `MONOTONIC` (ver a classe). */
        const val LIMITE_DO_MONOTONIC_US = 2_000_000L

        fun classificar(mUs: Long, bUs: Long, declaradoBoottime: Boolean = false): Classe = when {
            Math.abs(bUs) > TOLERANCIA_US && Math.abs(mUs - bUs) <= TOLERANCIA_US -> Classe.BOOTTIME
            ambigua(mUs, bUs, declaradoBoottime) -> Classe.BOOTTIME
            mUs in 0..LIMITE_DO_MONOTONIC_US -> Classe.MONOTONIC
            else -> Classe.DESCONHECIDO
        }

        /** A zona ambígua desempatada pela declaração: `|b|` pequeno, e `m − b` uma latência. */
        fun ambigua(mUs: Long, bUs: Long, declaradoBoottime: Boolean): Boolean =
            declaradoBoottime && Math.abs(bUs) <= TOLERANCIA_US && (mUs - bUs) in 0..LIMITE_DO_MONOTONIC_US
    }

    /** A classe saiu da declaração, na zona ambígua, e não da medida. Para o diário. */
    var pelaDeclaracao = false
        private set

    var classe: Classe? = null
        private set
    /** O que se soma ao PTS para ele virar `MONOTONIC`. Decidido no primeiro quadro. */
    var correcaoUs = 0L
        private set
    var mPrimeiroUs = 0L
        private set
    var bUs = 0L
        private set
    var mMinimoUs = Long.MAX_VALUE
        private set
    var quadros = 0L
        private set

    /**
     * Um quadro saiu do encoder com [ptsUs]; [monotonicUs] e [boottimeUs] são as duas horas de
     * agora, lidas juntas. Devolve o carimbo do quadro, em `MONOTONIC`.
     */
    fun quadro(ptsUs: Long, monotonicUs: Long, boottimeUs: Long): Long {
        val m = monotonicUs - ptsUs
        if (classe == null) {
            val b = monotonicUs - boottimeUs
            val c = classificar(m, b, declaradoBoottime)
            pelaDeclaracao = c == Classe.BOOTTIME && Math.abs(b) <= TOLERANCIA_US
            classe = c
            mPrimeiroUs = m
            bUs = b
            correcaoUs = when (c) {
                Classe.MONOTONIC -> 0L
                Classe.BOOTTIME -> b
                Classe.DESCONHECIDO -> m
            }
        }
        if (m < mMinimoUs) mMinimoUs = m
        quadros++
        return if (corrigir) ptsUs + correcaoUs else ptsUs
    }

    private fun ms(us: Long) = "%.1f".format(Locale.ROOT, us / 1000.0)

    fun linha(): String =
        "relogio_do_pts classe=${classe ?: "-"} m_ms=${ms(mPrimeiroUs)} b_ms=${ms(bUs)} " +
            "correcao_ms=${ms(correcaoUs)} " +
            "m_min_ms=${if (mMinimoUs == Long.MAX_VALUE) "-" else ms(mMinimoUs)} " +
            "latencia_min_ms=${if (mMinimoUs == Long.MAX_VALUE) "-" else ms(mMinimoUs - correcaoUs)} " +
            "quadros=$quadros corrigir=$corrigir declarado_boottime=$declaradoBoottime " +
            "pela_declaracao=$pelaDeclaracao"
}
