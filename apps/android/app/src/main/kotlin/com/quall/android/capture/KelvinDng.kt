package com.quall.android.capture

import kotlin.math.ln

/**
 * **O balanço em Kelvin pela receita do DNG** (`docs/controles-de-camera.md` §3.4), puro e testado sem
 * aparelho. Nenhum aparelho da bancada declara o Kelvin da Camera2 (o `COLOR_CORRECTION_MODE_CCT` da
 * API 36; `bancada.md` §8.76), então a conta é do app: de K aos ganhos RGGB e à matriz de correção, com
 * as matrizes de calibração que a câmera publica (`SENSOR_COLOR_TRANSFORM1/2`,
 * `SENSOR_FORWARD_MATRIX1/2`, `SENSOR_REFERENCE_ILLUMINANT1/2`).
 *
 * As matrizes são 3×3 **por linhas** (o `ColorSpaceTransform` da Camera2 também é), em `DoubleArray(9)`.
 *
 * Fontes:
 * - Kim et al., "Design of advanced color temperature control system for HDTV applications", J. Korean
 *   Phys. Soc. 41 (2002): a aproximação cúbica do lugar de Planck, de 1667 a 25000 K;
 * - CIE 15:2004, §3.1: o lugar da luz do dia (`x_D` em duas faixas e `y_D = −3x² + 2,87x − 0,275`);
 * - Adobe, "Digital Negative Specification" 1.4, cap. 6 ("Mapping Camera Color Space to CIE XYZ
 *   Space"): a interpolação das matrizes em 1/K, o neutro da câmera e a forward matrix;
 * - B. Lindbloom, "RGB/XYZ Matrices" (brucelindbloom.com): XYZ D50 → sRGB linear com a adaptação de
 *   Bradford, que é a [XYZ_D50_PARA_SRGB].
 */
object KelvinDng {

    /** XYZ (D50, adaptado por Bradford) → sRGB linear, por linhas (Lindbloom). */
    val XYZ_D50_PARA_SRGB = doubleArrayOf(
        3.1338561, -1.6168667, -0.4906146,
        -0.9787684, 1.9161415, 0.0334540,
        0.0719453, -0.2289914, 1.4052427,
    )

    /**
     * A temperatura de cada `SENSOR_REFERENCE_ILLUMINANT` (os valores da tag `LightSource` do EXIF, que
     * a Camera2 reusa). A e D65 com os números que a especificação cita (2856 K e 6504 K); os outros com
     * a tabela do DNG SDK (`dng_camera_profile.cpp`, `TemperatureForIlluminant`). `null`: iluminação que
     * não tem temperatura (o código 0, "desconhecida", e o 255, "outra").
     */
    fun temperaturaDaIluminacao(codigo: Int): Double? = when (codigo) {
        1 -> 5500.0   // DAYLIGHT
        2 -> 4150.0   // FLUORESCENT
        3 -> 2850.0   // TUNGSTEN
        4 -> 5500.0   // FLASH
        9 -> 5500.0   // FINE_WEATHER
        10 -> 6500.0  // CLOUDY_WEATHER
        11 -> 7500.0  // SHADE
        12 -> 6430.0  // DAYLIGHT_FLUORESCENT
        13 -> 5000.0  // DAY_WHITE_FLUORESCENT
        14 -> 4150.0  // COOL_WHITE_FLUORESCENT
        15 -> 3525.0  // WHITE_FLUORESCENT
        17 -> 2856.0  // STANDARD_A
        18 -> 4874.0  // STANDARD_B
        19 -> 6774.0  // STANDARD_C
        20 -> 5503.0  // D55
        21 -> 6504.0  // D65
        22 -> 7504.0  // D75
        23 -> 5003.0  // D50
        24 -> 3200.0  // ISO_STUDIO_TUNGSTEN
        else -> null
    }

    /** A calibração de cor de uma câmera: duas iluminações, cada uma com a matriz de cor e a forward. */
    data class Calibracao(
        val temperatura1: Double,
        val matrizDeCor1: DoubleArray,
        val forward1: DoubleArray,
        val temperatura2: Double,
        val matrizDeCor2: DoubleArray,
        val forward2: DoubleArray,
    ) {
        override fun equals(other: Any?): Boolean = other is Calibracao && temperatura1 == other.temperatura1 &&
            temperatura2 == other.temperatura2 && matrizDeCor1.contentEquals(other.matrizDeCor1) &&
            matrizDeCor2.contentEquals(other.matrizDeCor2) && forward1.contentEquals(other.forward1) &&
            forward2.contentEquals(other.forward2)

        override fun hashCode(): Int = temperatura1.hashCode() * 31 + temperatura2.hashCode()

        companion object {
            /**
             * A calibração a partir do que a câmera publica, ou `null` quando falta alguma peça (o
             * texto do §3.5: "Esta câmera não publica a calibração de cor que o Kelvin precisa.").
             */
            fun de(
                iluminacao1: Int?, cor1: DoubleArray?, forward1: DoubleArray?,
                iluminacao2: Int?, cor2: DoubleArray?, forward2: DoubleArray?,
            ): Calibracao? {
                val t1 = iluminacao1?.let { temperaturaDaIluminacao(it) } ?: return null
                val t2 = iluminacao2?.let { temperaturaDaIluminacao(it) } ?: return null
                if (cor1?.size != 9 || cor2?.size != 9 || forward1?.size != 9 || forward2?.size != 9) return null
                if (t1 == t2) return null
                return Calibracao(t1, cor1, forward1, t2, cor2, forward2)
            }
        }
    }

    // --- 1. K → xy → XYZ ---------------------------------------------------------------------------

    /**
     * **K → xy** (§3.4, passo 1): abaixo de 4000 K, a cúbica de Kim et al. sobre o lugar de Planck; de
     * 4000 K em diante, o lugar da luz do dia da CIE. A conta vale de 1667 a 25000 K e é cortada ali.
     */
    fun xyDoKelvin(kelvin: Double): Pair<Double, Double> {
        val t = kelvin.coerceIn(1667.0, 25000.0)
        if (t < 4000.0) {
            val x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            val y = if (t < 2222.0) {
                -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
            } else {
                -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
            }
            return x to y
        }
        val x = if (t <= 7000.0) {
            -4.6070e9 / (t * t * t) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
        } else {
            -2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        }
        val y = -3.000 * x * x + 2.870 * x - 0.275
        return x to y
    }

    /** O XYZ de [kelvin] com Y = 1. */
    fun xyzDoKelvin(kelvin: Double): DoubleArray {
        val (x, y) = xyDoKelvin(kelvin)
        return doubleArrayOf(x / y, 1.0, (1.0 - x - y) / y)
    }

    // --- 2. a interpolação em 1/K ------------------------------------------------------------------

    /**
     * O peso da matriz 1 em [kelvin] (DNG, cap. 6): linear em 1/K entre as duas iluminações; fora do
     * intervalo, a matriz da ponta (peso 0 ou 1).
     */
    fun pesoDa1(c: Calibracao, kelvin: Double): Double {
        val inv = 1.0 / kelvin
        val i1 = 1.0 / c.temperatura1
        val i2 = 1.0 / c.temperatura2
        return ((inv - i2) / (i1 - i2)).coerceIn(0.0, 1.0)
    }

    fun interpolar(m1: DoubleArray, m2: DoubleArray, peso1: Double): DoubleArray =
        DoubleArray(9) { peso1 * m1[it] + (1.0 - peso1) * m2[it] }

    fun matrizDeCor(c: Calibracao, kelvin: Double): DoubleArray = interpolar(c.matrizDeCor1, c.matrizDeCor2, pesoDa1(c, kelvin))

    fun forward(c: Calibracao, kelvin: Double): DoubleArray = interpolar(c.forward1, c.forward2, pesoDa1(c, kelvin))

    // --- 3. o neutro e os ganhos -------------------------------------------------------------------

    /** **Neutro da câmera** = matriz de cor × XYZ (§3.4, passo 3). */
    fun neutro(c: Calibracao, kelvin: Double): DoubleArray = vezes(matrizDeCor(c, kelvin), xyzDoKelvin(kelvin))

    /**
     * **Os ganhos RGGB** de [kelvin]: 1/neutro, normalizados para o verde valer 1, com os dois verdes
     * iguais. `null` se o neutro sair não positivo (uma matriz absurda).
     */
    fun ganhos(c: Calibracao, kelvin: Double): DoubleArray? {
        val n = neutro(c, kelvin)
        if (n.any { it <= 0.0 || !it.isFinite() }) return null
        return doubleArrayOf(n[1] / n[0], 1.0, 1.0, n[1] / n[2])
    }

    // --- 4. a matriz de correção -------------------------------------------------------------------

    /**
     * **A matriz de correção** = `XYZ D50 → sRGB linear` × forward interpolada (§3.4, passo 4). A forward
     * leva a cor da câmera já balanceada a XYZ com branco D50. **Nunca a identidade**: com ela a conversão
     * para sRGB fica de fora, e a saturação some (o DroidCam, `bancada.md` §8.77).
     */
    fun matrizDeCorrecao(c: Calibracao, kelvin: Double): DoubleArray = vezes3(XYZ_D50_PARA_SRGB, forward(c, kelvin))

    // --- a conta inversa: ganhos → K ----------------------------------------------------------------

    /**
     * **A leitura em Kelvin** (§3.4): dos `COLOR_CORRECTION_GAINS` do resultado ao neutro (1/ganho, com
     * o verde na média dos dois), e do neutro a K **por bisseção em 1/K**, com a mesma interpolação. O
     * critério é a razão vermelho/azul do neutro, que anda num sentido só ao longo do lugar; o tom
     * (verde–magenta) fica de fora. Cortado em 1667–25000 K. `null` com ganhos inválidos.
     */
    fun kelvinDosGanhos(c: Calibracao, ganhosRggb: DoubleArray): Double? {
        if (ganhosRggb.size != 4 || ganhosRggb.any { it <= 0.0 || !it.isFinite() }) return null
        val verde = (ganhosRggb[1] + ganhosRggb[2]) / 2.0
        // neutro ∝ 1/ganho: ln(nR/nB) = ln(gB/gR); o verde se cancela.
        val alvo = ln(ganhosRggb[3] / ganhosRggb[0])
        if (!alvo.isFinite() || verde <= 0.0) return null
        fun razao(k: Double): Double? {
            val n = neutro(c, k)
            if (n[0] <= 0.0 || n[2] <= 0.0) return null
            return ln(n[0] / n[2])
        }
        // A bisseção anda em u = 1/K: `lo` é o 25000 K e `hi` o 1667 K.
        var lo = 1.0 / 25000.0
        var hi = 1.0 / 1667.0
        val rLo = razao(1.0 / lo) ?: return null
        val rHi = razao(1.0 / hi) ?: return null
        val sobe = rHi > rLo
        // Fora do lugar: a ponta mais perto.
        if (sobe && alvo <= rLo || !sobe && alvo >= rLo) return 1.0 / lo
        if (sobe && alvo >= rHi || !sobe && alvo <= rHi) return 1.0 / hi
        repeat(60) {
            val meio = (lo + hi) / 2.0
            val r = razao(1.0 / meio) ?: return null
            if ((r < alvo) == sobe) lo = meio else hi = meio
        }
        return 1.0 / ((lo + hi) / 2.0)
    }

    // --- álgebra ------------------------------------------------------------------------------------

    fun vezes(m: DoubleArray, v: DoubleArray): DoubleArray = DoubleArray(3) { i ->
        m[3 * i] * v[0] + m[3 * i + 1] * v[1] + m[3 * i + 2] * v[2]
    }

    fun vezes3(a: DoubleArray, b: DoubleArray): DoubleArray = DoubleArray(9) { k ->
        val i = k / 3
        val j = k % 3
        a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j]
    }
}
