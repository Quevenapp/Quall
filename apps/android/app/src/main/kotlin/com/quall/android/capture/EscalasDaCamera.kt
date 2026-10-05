package com.quall.android.capture

import com.quall.android.R
import com.quall.android.core.Textos
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * **As regras de valor do R9** (`docs/controles-de-camera.md` §3.1–§3.3 e §3.6): as escalas do
 * obturador, do ISO e do EV, os cortes pela faixa da câmera e os textos que a tela mostra. Pura, sem
 * tipo do Android, no molde da [GeometriaDoDivisor].
 *
 * **Números na tela no idioma do app** (`docs/traducao.md`, Android): vírgula decimal em português (§3) e
 * ponto em inglês, pelo `locale` dos [Textos] — nunca pelo `Locale` do sistema, que pode ser outro.
 */
object EscalasDaCamera {

    // --- §3.1 o obturador -------------------------------------------------------------------------

    /** As frações de cinema e vídeo do §3.1, como denominadores de `1/N s`. */
    val FRACOES = listOf(24, 25, 30, 48, 50, 60, 100, 120, 125, 250, 500, 1000, 2000, 4000, 8000)

    /** `1/N s` em ns, arredondado. */
    fun nsDaFracao(n: Int): Long = (1e9 / n).roundToLong()

    /** A duração de um quadro a [fps], em ns: o `SENSOR_FRAME_DURATION` da exposição manual (§3.1). */
    fun duracaoDoQuadroNs(fps: Int): Long = (1e9 / fps.coerceAtLeast(1)).roundToLong()

    /** **O teto do obturador**: `min(1/fps, máximo da câmera)`, com o fps negociado da sessão. */
    fun tetoDoObturadorNs(fps: Int, maximoDaCameraNs: Long): Long = minOf(duracaoDoQuadroNs(fps), maximoDaCameraNs)

    /**
     * **A escala do obturador** (§3.1), da exposição mais longa para a mais curta: as [FRACOES] que cabem
     * entre o mínimo da câmera e o teto, mais o próprio 1/fps se ele não estiver na lista. Cada item é o
     * denominador `N` de `1/N s`.
     */
    fun escalaDoObturador(minimoNs: Long, maximoNs: Long, fps: Int): List<Int> {
        val teto = tetoDoObturadorNs(fps, maximoNs)
        val dentro = FRACOES.filter { nsDaFracao(it) in minimoNs..teto }.toMutableSet()
        if (duracaoDoQuadroNs(fps) <= maximoNs && duracaoDoQuadroNs(fps) >= minimoNs) dentro.add(fps)
        return dentro.sorted()
    }

    /** O degrau da [escala] mais perto de [ns] (para pôr o deslizante onde a câmera está). */
    fun degrauMaisPerto(escala: List<Int>, ns: Long): Int? =
        escala.minByOrNull { abs(Math.log(nsDaFracao(it).toDouble() / ns.coerceAtLeast(1))) }

    /** O texto do obturador: sempre `1/N s`, com o N arredondado (`1/80 s`). */
    fun textoDoObturador(t: Textos, ns: Long): String {
        if (ns <= 0) return "—"
        val n = 1e9 / ns
        return if (n >= 1.0) "1/${n.roundToInt()} s" else "${decimal(t, ns / 1e9, 1)} s"
    }

    /** O corte do obturador ao reaplicar (§2.2): na faixa da câmera e no teto de 1/fps. */
    fun cortarObturador(ns: Long, minimoNs: Long, maximoNs: Long, fps: Int): Long =
        ns.coerceIn(minimoNs, maxOf(minimoNs, tetoDoObturadorNs(fps, maximoNs)))

    /** A anti-cintilação que vale para a sugestão de frações: a escolhida, ou a da região em `auto`. */
    enum class Rede { HZ50, HZ60 }

    /**
     * **A sugestão contra cintilação** (§3.1): 60 Hz com `antiCintilacao` em 60, ou em `auto` com o
     * aparelho na região BR; 50 Hz com 50. `null` (sem legenda) nos outros casos.
     */
    fun redeDaSugestao(anti: AjusteDaCamera.AntiCintilacao, regiao: String?): Rede? = when (anti) {
        AjusteDaCamera.AntiCintilacao.HZ60 -> Rede.HZ60
        AjusteDaCamera.AntiCintilacao.HZ50 -> Rede.HZ50
        AjusteDaCamera.AntiCintilacao.AUTO -> if (regiao.equals("BR", ignoreCase = true)) Rede.HZ60 else null
        AjusteDaCamera.AntiCintilacao.DESLIGADA -> null
    }

    /** As frações que levam o ponto da sugestão, e a legenda dele. É legenda, não trava. */
    fun fracoesSemCintilacao(rede: Rede?): Set<Int> = when (rede) {
        Rede.HZ60 -> setOf(60, 120)
        Rede.HZ50 -> setOf(50, 100)
        null -> emptySet()
    }

    fun legendaDaCintilacao(t: Textos, rede: Rede): String = when (rede) {
        Rede.HZ60 -> t.s(R.string.cam_sem_cintilacao_60)
        Rede.HZ50 -> t.s(R.string.cam_sem_cintilacao_50)
    }

    // --- §3.2 o ISO -------------------------------------------------------------------------------

    /** Os terços de stop do §3.2. */
    val TERCOS_DE_ISO = listOf(50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
        2000, 2500, 3200, 4000, 5000, 6400)

    /** A escala do ISO: os terços cortados pela faixa da câmera, mais o mínimo e o máximo exatos dela. */
    fun escalaDoIso(minimo: Int, maximo: Int): List<Int> =
        (TERCOS_DE_ISO.filter { it in minimo..maximo } + minimo + maximo).distinct().sorted()

    /** Acima do fim do ganho analógico (`SENSOR_MAX_ANALOG_SENSITIVITY`), o ISO leva a marca "ganho digital". */
    fun ganhoDigital(iso: Int, maximoAnalogico: Int?): Boolean = maximoAnalogico != null && maximoAnalogico > 0 && iso > maximoAnalogico

    fun marcaDoGanhoDigital(t: Textos): String = t.s(R.string.cam_ganho_digital)

    fun textoDoIso(iso: Int): String = "ISO $iso"

    fun cortarIso(iso: Int, minimo: Int, maximo: Int): Int = iso.coerceIn(minimo, maxOf(minimo, maximo))

    // --- §3.3 o EV --------------------------------------------------------------------------------

    /**
     * O índice de compensação que [ev] pede, no passo da câmera ([passoNum]/[passoDen] EV por índice) e
     * cortado pela faixa dela.
     */
    fun indiceDoEv(ev: Double, passoNum: Int, passoDen: Int, indiceMin: Int, indiceMax: Int): Int {
        if (passoNum <= 0 || passoDen <= 0) return 0
        val i = Math.round(ev * passoDen / passoNum).toInt()
        return i.coerceIn(indiceMin, maxOf(indiceMin, indiceMax))
    }

    fun evDoIndice(indice: Int, passoNum: Int, passoDen: Int): Double =
        if (passoDen == 0) 0.0 else indice.toDouble() * passoNum / passoDen

    /**
     * O texto do EV: `+0,3 EV`, com sinal sempre visível; o 0 é `0 EV`. Uma casa decimal, sem o ",0"
     * dos inteiros (`+1 EV`). O sinal de menos é o tipográfico, como nos botões do prompter ("−5%").
     */
    fun textoDoEv(t: Textos, ev: Double): String {
        val r = Math.round(ev * 10) / 10.0
        if (r == 0.0) return "0 EV"
        val sinal = if (r > 0) "+" else "−"
        return sinal + decimal(t, abs(r), 1) + " EV"
    }

    fun evComTrava(t: Textos): String = t.s(R.string.cam_ev_com_trava)

    // --- §3.4 o Kelvin (o deslizante) ---------------------------------------------------------------

    fun cortarKelvin(k: Int): Int {
        val c = k.coerceIn(AjusteDaCamera.KELVIN_MIN, AjusteDaCamera.KELVIN_MAX)
        return (Math.round(c / AjusteDaCamera.KELVIN_PASSO.toDouble()) * AjusteDaCamera.KELVIN_PASSO).toInt()
    }

    fun textoDoKelvin(k: Int): String = "$k K"

    // --- §2 o foco --------------------------------------------------------------------------------

    /** `focoPosicao` (0 longe, 1 o mais perto) em dioptrias: `× LENS_INFO_MINIMUM_FOCUS_DISTANCE` (§2). */
    fun dioptriasDoFoco(posicao: Double, minimaDistanciaDioptrias: Float): Float =
        (posicao.coerceIn(0.0, 1.0) * minimaDistanciaDioptrias).toFloat()

    /** O inverso: a posição lida do `LENS_FOCUS_DISTANCE` do resultado. */
    fun posicaoDoFoco(dioptrias: Float, minimaDistanciaDioptrias: Float): Double =
        if (minimaDistanciaDioptrias <= 0f) 0.0 else (dioptrias / minimaDistanciaDioptrias).toDouble().coerceIn(0.0, 1.0)

    /** O deslizante "Perto ↔ Longe" anda de 0,01 em 0,01 (§4.3). */
    fun cortarFoco(p: Double): Double = (Math.round(p.coerceIn(0.0, 1.0) * 100) / 100.0)

    /** Metros, só com calibração `APPROXIMATE` ou `CALIBRATED` (§1): 1/dioptrias; infinito no 0. */
    fun textoDoFocoEmMetros(t: Textos, dioptrias: Float): String =
        if (dioptrias <= 0.001f) "∞" else decimal(t, 1.0 / dioptrias, if (1.0 / dioptrias < 1) 2 else 1) + " m"

    // --- §3.6 a linha de leitura ------------------------------------------------------------------

    /**
     * A linha de leitura: `ISO 400 · 1/60 s · 5200 K · f/1,7`, só com o que a plataforma conseguiu ler
     * (um `null` sai da linha).
     */
    fun linhaDeLeitura(t: Textos, iso: Int?, obturadorNs: Long?, kelvin: Int?, abertura: Float?): String = listOfNotNull(
        iso?.let { textoDoIso(it) },
        obturadorNs?.takeIf { it > 0 }?.let { textoDoObturador(t, it) },
        kelvin?.let { textoDoKelvin(it) },
        abertura?.takeIf { it > 0f }?.let { "f/" + decimal(t, it.toDouble(), 1) },
    ).joinToString(" · ")

    /** "A câmera usou {lido} em vez de {pedido}." (§3.6). */
    fun textoDaDivergencia(t: Textos, lido: String, pedido: String): String = t.s(R.string.cam_divergencia, lido, pedido)

    // --- os números ------------------------------------------------------------------------------

    /**
     * [v] com [casas] decimais no idioma de [t]: vírgula em português, ponto nos outros (`1,7` / `1.7`).
     */
    fun decimal(t: Textos, v: Double, casas: Int): String {
        val pt = virgula(v, casas)
        return if (t.locale.language == "pt") pt else pt.replace(',', '.')
    }

    /**
     * [v] com [casas] decimais e **vírgula**, sem os zeros à direita da parte decimal (`1,7`, `2`).
     */
    fun virgula(v: Double, casas: Int): String {
        val fator = Math.pow(10.0, casas.toDouble())
        val r = Math.round(v * fator) / fator
        val bd = java.math.BigDecimal.valueOf(r).setScale(casas, java.math.RoundingMode.HALF_UP).stripTrailingZeros()
        return bd.toPlainString().replace('.', ',')
    }
}
