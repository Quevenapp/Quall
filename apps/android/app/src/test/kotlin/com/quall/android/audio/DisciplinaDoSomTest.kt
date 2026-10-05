package com.quall.android.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Testes da disciplina da deriva do Android (`som-no-receptor.md` §19.6.6): o [ReamostradorSinc], a
 * [DisciplinaDaDeriva] e a [LinhaDoSomRitmado]. **Rodam na JVM, sem aparelho**: a captura do próprio
 * app só roda em teste, pela regra do som só sintético.
 *
 * A fonte de mentira é ritmada por um dispositivo que anda `ppm` mais depressa que o host: o quadro
 * `k` (960 amostras, 20 ms nominais) tem a primeira amostra na hora `k · 20 ms / (1 + ppm)`. A hora
 * que a fonte entrega tem o ruído do cenário. A testemunha é a hora verdadeira da primeira amostra
 * de cada quadro contra o carimbo que a linha deu a ela.
 */
class DisciplinaDoSomTest {

    private class Lcg(var s: Long) {
        fun unif(): Double {
            s = s * 6364136223846793005L + 1442695040888963407L
            return (s ushr 11).toDouble() / (1L shl 53).toDouble()
        }

        fun gauss(sigma: Double): Double {
            val u1 = maxOf(unif(), 1e-300)
            val u2 = unif()
            return sigma * sqrt(-2 * ln(u1)) * cos(2 * PI * u2)
        }
    }

    /** O ruído da hora que a fonte entrega. */
    sealed class Ruido {
        object Nenhum : Ruido()

        /** Gaussiano, independente por quadro. */
        data class Gauss(val sigmaUs: Double) : Ruido()

        /** Gaussiano mais 1 % de picos de ±5 ms. */
        data class Cauda(val sigmaUs: Double) : Ruido()

        /**
         * **Por período de buffer**: o par (posição, hora) do `getTimestamp` só muda a cada
         * `quadros`, com ruído gaussiano na hora; entre um par e outro a hora é extrapolada no ritmo
         * nominal, como `CapturaDoProprioApp.instanteDoQuadroUs` faz.
         */
        data class Periodo(val quadros: Int, val sigmaUs: Double) : Ruido()
    }

    data class Cenario(
        val segundos: Double,
        val ppm: Double,
        var ruido: Ruido = Ruido.Nenhum,
        var disciplina: Boolean = true,
        /** Quadros perdidos: nem o conteúdo nem a hora chegam (a lacuna de conteúdo). */
        var perdidos: IntRange? = null,
        /** Picos só na hora: quadro → µs somados à hora dele. */
        var picos: Map<Int, Double> = emptyMap(),
        /** Quadros sem par (a hora não veio). */
        var semHora: IntRange? = null,
        var quadrosParaConfirmar: Int = LinhaDoSomRitmado.QUADROS_PARA_CONFIRMAR,
        var regraDoDesenho: Boolean = false,
        /** A hora da vaga (a leitura) atrasada este tanto da verdadeira; `null`: não passa. */
        var vagaAtrasadaUs: Double? = null,
    )

    class Resultado(val linha: LinhaDoSomRitmado) {
        var pior = 0.0
        var depoisDe10Min = 0.0
        var final = 0.0
        var incrementosErrados = 0
        var paraTras = 0
        var quadrosDeSaida = 0
        /** Quadros de saída enquanto os quadros de entrada vinham sem par. */
        var saidasSemPar = 0
        /** O maior |f − ppm| depois da última rajada sem par, e o ε verdadeiro na volta dela. */
        var maiorDesvioDeFDepois = 0.0
        var erroNaVolta: Double? = null
        /** (s, erro µs) de cada quadro com hora. */
        val serie = ArrayList<Pair<Double, Double>>()
    }

    private fun correr(c: Cenario): Resultado {
        val linha = LinhaDoSomRitmado(
            48_000, 1, 960, disciplina = c.disciplina, soContar = true,
            quadrosParaConfirmar = c.quadrosParaConfirmar, regraDoDesenho = c.regraDoDesenho,
        )
        val r = Resultado(linha)
        val rnd = Lcg(7)
        val t0 = 1_000_000_000_000.0
        val d = c.ppm * 1e-6
        val quadros = (c.segundos * 50 * (1 + d)).toInt()
        val pcm = ShortArray(960)
        var ultimo: Long? = null
        var degrausAntes = 0
        var parHora = 0.0
        var parQuadro = 0
        for (k in 0 until quadros) {
            val verdadeira = t0 + k * 20_000.0 / (1 + d)
            if (c.perdidos?.contains(k) == true) continue
            val ruido = when (val z = c.ruido) {
                Ruido.Nenhum -> 0.0
                is Ruido.Gauss -> rnd.gauss(z.sigmaUs)
                is Ruido.Cauda -> rnd.gauss(z.sigmaUs) + if (rnd.unif() < 0.01) (if (rnd.unif() < 0.5) 5_000.0 else -5_000.0) else 0.0
                is Ruido.Periodo -> {
                    if (k == 0 || k - parQuadro >= z.quadros) {
                        parQuadro = k
                        parHora = verdadeira + rnd.gauss(z.sigmaUs)
                    }
                    parHora + (k - parQuadro) * 20_000.0 - verdadeira
                }
            }
            val semPar = c.semHora?.contains(k) == true
            val hora = if (semPar) null else (verdadeira + ruido + (c.picos[k] ?: 0.0)).toLong()
            val vaga = c.vagaAtrasadaUs?.let { (verdadeira + it).toLong() }
            val saidas = linha.quadro(pcm, 960, hora, vaga)
            if (semPar) r.saidasSemPar += saidas.size
            if (hora != null && c.semHora != null && k > c.semHora!!.last) {
                r.maiorDesvioDeFDepois = maxOf(r.maiorDesvioDeFDepois, abs(linha.disc.fPpm - c.ppm))
                if (r.erroNaVolta == null) r.erroNaVolta = verdadeira - linha.ultimoSUs
            }
            if (hora != null) {
                val erro = verdadeira - linha.ultimoSUs
                val t = (verdadeira - t0) / 1e6
                r.final = erro
                r.pior = maxOf(r.pior, abs(erro))
                if (t > 600) r.depoisDe10Min = maxOf(r.depoisDe10Min, abs(erro))
                if (k % 10 == 0) r.serie.add(t to erro)
            }
            for ((_, carimbo) in saidas) {
                r.quadrosDeSaida++
                val u = ultimo
                if (u != null) {
                    if (carimbo < u) r.paraTras++
                    else if (carimbo - u != 20_000L && linha.degraus == degrausAntes) r.incrementosErrados++
                }
                degrausAntes = linha.degraus
                ultimo = carimbo
            }
        }
        return r
    }

    private fun pior(r: Resultado, de: Double, ate: Double = Double.MAX_VALUE): Double =
        r.serie.filter { it.first >= de && it.first < ate }.maxOfOrNull { abs(it.second) } ?: 0.0

    // --- 1. o controle, e o laço ---

    @Test
    fun sem_disciplina_300_ppm_derivam_18_ms_por_minuto_e_com_ela_o_carimbo_fica_no_host() {
        val controle = correr(Cenario(600.0, 300.0, disciplina = false))
        println("controle, 300 ppm por 10 min: final ${"%.1f".format(controle.final / 1000)} ms")
        assertTrue("o controle: ${controle.final}", abs(controle.final) > 150_000)
        val r = correr(Cenario(600.0, 300.0, ruido = Ruido.Gauss(100.0)))
        println("300 ppm, ruído de 0,1 ms: pior ${"%.3f".format(r.pior / 1000)} ms, f ${"%.2f".format(r.linha.disc.fPpm)} ppm, Δu máx ${"%.1f".format(r.linha.disc.maiorDuPpm)} ppm")
        assertTrue("pior ${r.pior}", r.pior < 1_000)
        assertEquals(300.0, r.linha.disc.fPpm, 1.0)
        assertEquals(0, r.incrementosErrados + r.paraTras)
        assertEquals(0, r.linha.lacunas)
    }

    // --- 2. ±50, ±100 e ±300 ppm com a faixa gaussiana ---

    @Test
    fun a_faixa_gaussiana_por_1_h_fica_nos_numeros_do_desenho() {
        // Os limites do §19.6.5 (a mesma regra do Windows), com folga para a âncora ruidosa: com
        // 1 ms de ruído, o pior da partida é o da âncora, uma hora só (L7), e o laço o tira em ~T.
        for ((ppm, sigma, piorMax, depoisMax) in listOf(
            listOf(50.0, 100.0, 900.0, 20.0),
            listOf(-300.0, 100.0, 900.0, 20.0),
            listOf(300.0, 500.0, 1_200.0, 60.0),
            listOf(-100.0, 1_000.0, 3_000.0, 120.0),
        )) {
            val r = correr(Cenario(3_600.0, ppm, ruido = Ruido.Gauss(sigma)))
            println("$ppm ppm, gaussiano de $sigma µs: pior ${"%.3f".format(r.pior / 1000)} ms, depois de 10 min ${"%.1f".format(r.depoisDe10Min)} µs, f ${"%.2f".format(r.linha.disc.fPpm)}, Δu máx ${"%.1f".format(r.linha.disc.maiorDuPpm)} ppm, lacunas ${r.linha.lacunas}")
            assertTrue("$ppm/$sigma: pior ${r.pior}", r.pior < piorMax)
            assertTrue("$ppm/$sigma: ${r.depoisDe10Min}", r.depoisDe10Min < depoisMax)
            assertTrue("flutter ${r.linha.disc.maiorDuPpm}", r.linha.disc.maiorDuPpm <= 25.0 + 1e-6)
            assertEquals(0, r.linha.lacunas)
            assertEquals(0, r.incrementosErrados + r.paraTras)
        }
    }

    // --- 3. o reamostrador ---

    @Test
    fun o_sinc_guarda_o_tom_a_mais_e_menos_500_ppm() {
        // Com `Int16` e amplitude de 16 000, o piso é ~92 dB (±0,5 LSB); o sinc em ponto flutuante
        // dá ≥ 90 dB até 16 kHz no Windows.
        for (f in listOf(1_000.0, 8_000.0, 16_000.0)) {
            for (u in listOf(500e-6, -500e-6)) {
                val s = ReamostradorSinc(48_000, 48_000, 1)
                s.definirAjuste(u)
                val x = ShortArray(48_000) { (sin(2 * PI * f * it / 48_000) * 16_000).let { v -> Math.round(v).toInt().toShort() } }
                val y = SaidaDeAmostras()
                var i = 0
                while (i < x.size) {
                    val n = minOf(480, x.size - i)
                    s.empurrar(x.copyOfRange(i, i + n), n)
                    s.produzir(y)
                    i += n
                }
                var sinal = 0.0
                var erro = 0.0
                for (k in 500 until minOf(40_000, y.tamanho)) {
                    val ideal = sin(2 * PI * f * k * s.passo / 48_000) * 16_000
                    sinal += ideal * ideal
                    erro += (y.dados[k] - ideal) * (y.dados[k] - ideal)
                }
                val db = 10 * log10(sinal / erro)
                println("sinc, $f Hz, u $u: ${"%.1f".format(db)} dB")
                assertTrue("$f Hz, $u: $db dB", db > 85)
            }
        }
    }

    @Test
    fun o_pulso_sai_na_posicao_de_entrada_dele() {
        // Um pulso gaussiano na posição 3 000,25 da entrada sai centrado no índice de saída que a
        // linha dá a essa posição: nada se desconta da hora pelo sinc (L-c).
        for (u in listOf(0.0, 500e-6, -1_000e-6)) {
            val s = ReamostradorSinc(48_000, 48_000, 1)
            s.definirAjuste(u)
            val centro = 3_000.25
            val x = ShortArray(6_000) { (20_000 * Math.exp(-((it - centro) * (it - centro)) / (2 * 6.0 * 6.0))).toInt().toShort() }
            val esperado = s.indiceDeSaida(centro)
            val y = SaidaDeAmostras()
            s.empurrar(x, x.size)
            s.produzir(y)
            var soma = 0.0
            var pesos = 0.0
            for (k in 0 until y.tamanho) {
                soma += k * y.dados[k].toDouble()
                pesos += y.dados[k].toDouble()
            }
            val centroide = soma / pesos
            assertEquals("u $u", esperado, centroide, 0.05)
        }
    }

    // --- 4. os saltos de conteúdo (N6) ---

    @Test
    fun cinco_quadros_perdidos_dao_um_degrau_do_tamanho_deles() {
        for (ppm in listOf(0.0, 300.0, -300.0)) {
            val c = Cenario(600.0, ppm, ruido = Ruido.Gauss(100.0))
            c.perdidos = 15_000 until 15_005
            val r = correr(c)
            println("5 quadros perdidos a $ppm ppm: lacunas ${r.linha.lacunas}, degraus ${r.linha.degraus}, pior depois ${"%.1f".format(pior(r, 301.0))} µs, final ${"%.1f".format(r.final)} µs")
            assertEquals("$ppm", 1, r.linha.lacunas)
            assertEquals("$ppm", 1, r.linha.degraus)
            assertTrue("$ppm: pior depois ${pior(r, 301.0)}", pior(r, 301.0) < 1_000)
            assertTrue("$ppm: final ${r.final}", abs(r.final) < 100)
            assertEquals(0, r.paraTras)
        }
    }

    @Test
    fun um_pico_de_50_ms_so_na_hora_nao_da_degrau() {
        val c = Cenario(120.0, 50.0, ruido = Ruido.Gauss(100.0))
        c.picos = mapOf(3_000 to 50_000.0)
        val r = correr(c)
        assertEquals(0, r.linha.degraus)
        assertEquals(1, r.linha.picosIgnorados)
        assertTrue("final ${r.final}", abs(r.final) < 500)
        // O controle: sem confirmar, par a par, o pico vira degrau, e a volta dele corta a entrada.
        c.quadrosParaConfirmar = 1
        val a = correr(c)
        println("pico de 50 ms, controle par a par: degraus ${a.linha.degraus}")
        assertTrue("o controle: ${a.linha.degraus}", a.linha.degraus >= 1)
    }

    @Test
    fun a_cauda_pesada_por_10_min_nao_da_lacuna_falsa() {
        val c = Cenario(600.0, 100.0, ruido = Ruido.Cauda(500.0))
        val r = correr(c)
        println("cauda pesada: lacunas ${r.linha.lacunas}, picos ${r.linha.picosIgnorados}, depois de 5 min ${"%.1f".format(pior(r, 300.0))} µs")
        assertEquals(0, r.linha.lacunas)
        assertTrue("${pior(r, 300.0)}", pior(r, 300.0) < 1_000)
        // O controle: a regra do desenho. Um pico abaixo do limiar vira o nível, e a volta ao normal
        // é um salto que fica (medido: 26 lacunas falsas, com a entrada cortada em cada uma).
        c.regraDoDesenho = true
        val a = correr(c)
        println("cauda pesada, controle (a regra do desenho): lacunas ${a.linha.lacunas}")
        assertTrue("o controle: ${a.linha.lacunas}", a.linha.lacunas > 10)
    }

    @Test
    fun o_par_por_periodo_de_buffer_nao_da_lacuna_falsa() {
        // Um par novo a cada 5 quadros (100 ms), com 0,5 ms de ruído. Entre os pares a diferença de
        // quadro a quadro é ~0, e o MAD de todas elas desaba: com a regra do desenho, o limiar cai
        // no piso de 2 ms, e o salto de um par que dura o período inteiro vira lacuna.
        val c = Cenario(600.0, 100.0, ruido = Ruido.Periodo(5, 500.0))
        val r = correr(c)
        println("par por período: lacunas ${r.linha.lacunas}, depois de 5 min ${"%.1f".format(pior(r, 300.0))} µs")
        assertEquals(0, r.linha.lacunas)
        assertTrue("${pior(r, 300.0)}", pior(r, 300.0) < 1_000)
        c.regraDoDesenho = true
        val a = correr(c)
        println("par por período, controle (a regra do desenho): lacunas ${a.linha.lacunas}")
        assertTrue("o controle: ${a.linha.lacunas}", a.linha.lacunas >= 3)
        // E a lacuna de verdade ainda sai, com o par por período.
        val g = Cenario(600.0, 100.0, ruido = Ruido.Periodo(5, 500.0))
        g.perdidos = 15_000 until 15_005
        val rg = correr(g)
        assertEquals(1, rg.linha.lacunas)
        assertTrue("final ${rg.final}", abs(rg.final) < 1_000)
    }

    // --- a revisão do código (21/09): A e D ---

    /**
     * A: uma rajada longa sem par deixava o período da agregação aberto, e a primeira atualização
     * depois dela tinha `dt` = a rajada inteira: `f ← f − ε·dt/T²` multiplicava o ruído de uma
     * medida pela duração dela.
     */
    @Test
    fun uma_rajada_de_1_h_sem_par_nao_puxa_o_f() {
        val c = Cenario(600.0 + 3_600.0 + 600.0, 50.0, ruido = Ruido.Gauss(500.0))
        c.semHora = 30_000 until 30_000 + 180_000
        val r = correr(c)
        println("rajada de 1 h sem par, 500 µs: |f − 50| máx depois ${"%.2f".format(r.maiorDesvioDeFDepois)} ppm, erro verdadeiro na volta ${"%.0f".format(r.erroNaVolta)} µs, lacunas ${r.linha.lacunas}, socorros ${r.linha.disc.socorros}")
        assertTrue("${r.maiorDesvioDeFDepois}", r.maiorDesvioDeFDepois < 2.0)
        assertEquals(0, r.linha.lacunas)
        assertEquals(0, r.linha.disc.socorros)
        assertEquals(0, r.incrementosErrados + r.paraTras)
    }

    /**
     * D: a captura do próprio app num aparelho em que o `getTimestamp` nunca dá par ficava muda a
     * sessão inteira (a âncora esperava o par, sem prazo). Antes da S8, esse aparelho mandava som.
     * Agora: 1 s de prazo, depois a hora da vaga (a leitura), contada; quando o par aparece, a
     * troca corrige a fase uma vez.
     */
    @Test
    fun sem_nenhum_par_o_som_sai_pela_hora_da_vaga() {
        val c = Cenario(60.0, 100.0, ruido = Ruido.Gauss(100.0))
        c.semHora = 0 until 500
        c.vagaAtrasadaUs = 30_000.0
        val r = correr(c)
        println("sem par nos primeiros 10 s: quadros de saída ${r.saidasSemPar} (de 500), pela vaga ${r.linha.quadrosPelaVaga}, trocas para o par ${r.linha.trocasParaOPar}, degraus ${r.linha.degraus}, cortadas ${r.linha.amostrasCortadas}, pior depois de 12 s ${"%.1f".format(pior(r, 12.0))} µs")
        assertTrue("${r.saidasSemPar}", r.saidasSemPar >= 440)
        assertTrue("${r.linha.quadrosPelaVaga}", r.linha.quadrosPelaVaga >= 440)
        assertEquals(1, r.linha.trocasParaOPar)
        assertTrue("${pior(r, 12.0)}", pior(r, 12.0) < 1_000)
        assertEquals(0, r.paraTras)
        // Sem vaga nenhuma (o controle, a regra de antes): mudo.
        c.vagaAtrasadaUs = null
        val a = correr(c)
        println("sem par e sem vaga (o controle): quadros de saída ${a.saidasSemPar}")
        assertEquals(0, a.saidasSemPar)
    }

    // --- 7. fora do alcance ---

    @Test
    fun fora_do_alcance_o_socorro_age_sem_carimbo_para_tras() {
        for (ppm in listOf(1_500.0, -1_500.0)) {
            val r = correr(Cenario(1_800.0, ppm, ruido = Ruido.Gauss(100.0)))
            println("$ppm ppm: socorros ${r.linha.disc.socorros}, pior depois de 1 min ${"%.1f".format(pior(r, 60.0) / 1000)} ms")
            assertTrue("$ppm", r.linha.disc.socorros > 0)
            assertTrue("$ppm: ${pior(r, 60.0)}", pior(r, 60.0) < 41_500)
            assertEquals("$ppm", 0, r.incrementosErrados + r.paraTras)
        }
    }

    // --- 8. quadros sem par (M2) ---

    @Test
    fun uma_rajada_sem_par_nao_mexe_no_laco_e_a_ancora_espera_o_primeiro_par() {
        // A âncora espera: os 10 primeiros quadros sem par não saem.
        val c = Cenario(300.0, 300.0, ruido = Ruido.Gauss(100.0))
        c.semHora = 0 until 10
        val r = correr(c)
        assertEquals(10, r.linha.semHora)
        assertEquals(1_000_000_000_000.0 + 10 * 20_000.0 / (1 + 300e-6), r.linha.ancoraUs!!, 1_000.0)
        // Uma rajada de 1 s sem par no meio: o laço não anda nela.
        val l = LinhaDoSomRitmado(48_000, 1, 960, soContar = true)
        val pcm = ShortArray(960)
        val t0 = 1_000_000_000_000L
        for (k in 0 until 3_000) l.quadro(pcm, 960, t0 + k * 20_000L)
        val f = l.disc.f
        val u = l.disc.u
        for (k in 3_000 until 3_050) l.quadro(pcm, 960, null)
        assertEquals(f, l.disc.f, 0.0)
        assertEquals(u, l.disc.u, 0.0)
        assertEquals(50, l.maiorRajadaSemHora)
        for (k in 3_050 until 3_100) l.quadro(pcm, 960, t0 + k * 20_000L)
        assertEquals(0, l.lacunas)
        assertTrue("ε ${l.epsUs}", abs(l.epsUs) < 100)
    }

    // --- 12. o dispositivo de mentira da bancada ---

    @Test
    fun o_tom_ritmado_entrega_no_ritmo_do_dispositivo_de_mentira_com_a_hora_exata() {
        var agora = 5_000_000L
        val dormidas = ArrayList<Long>()
        val tom = TomRitmado(48_000, 2, 960, 300.0, relogioUs = { agora }, dormirUs = { dormidas.add(it); agora += it })
        assertTrue(tom.ritmadaPeloDispositivo)
        val pcm = ShortArray(960 * 2)
        val periodo = 20_000.0 / (1 + 300e-6)
        for (n in 0 until 3_000) {
            assertEquals(960, tom.proximoQuadro(pcm))
            assertEquals(5_000_000L + (n * periodo).toLong(), tom.instanteDoQuadroUs())
            // A leitura só volta quando o quadro está pronto.
            assertTrue(agora >= 5_000_000L + ((n + 1) * periodo).toLong())
        }
        // 3 000 quadros em 60 s / (1 + 300 ppm): 18 ms antes do host.
        assertEquals(60_000_000.0 / (1 + 300e-6), (agora - 5_000_000L).toDouble(), 1.0)
    }
}
