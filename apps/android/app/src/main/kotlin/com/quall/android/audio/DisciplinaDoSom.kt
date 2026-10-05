package com.quall.android.audio

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * **O reamostrador do som**: sinc com janela de Kaiser (β = 8, 32 pontos) numa tabela polifásica de
 * 256 fases, com interpolação linear entre elas (`docs/som-no-receptor.md` §19.6.2). É a mesma peça
 * de `apps/windows/src/reamostrador_sinc.rs` e do Mac, com os mesmos números.
 *
 * - É o **atuador** da disciplina da deriva: a razão `ρ = 1 + u` (entrada por saída) faz o tempo de
 *   mídia seguir o relógio do host, e o carimbo anda um quadro exato por pacote.
 * - **Sem normalizar pela soma dos pesos**: normalizar modula o ganho com a fase fracionária
 *   (medido no Windows: 87,8 dB em vez de 95 a 1 kHz).
 * - O atraso de grupo é zero em relação à posição de entrada: nada se desconta da hora.
 * - A tabela é calculada uma vez (16 KiB): o núcleo exato por amostra (32 Bessel) seria caro demais.
 *
 * `soContar`: as posições andam iguais e a saída é zero — os testes longos.
 */
class ReamostradorSinc(taxaEntrada: Int, taxaSaida: Int, val canais: Int, private val soContar: Boolean = false) {
    companion object {
        const val MEIA_LARGURA = 16
        const val FASES = 256
        const val BETA = 8.0

        private fun besselI0(x: Double): Double {
            var soma = 1.0
            var termo = 1.0
            val q = x * x / 4
            for (k in 1 until 60) {
                termo *= q / (k.toDouble() * k)
                soma += termo
                if (termo < 1e-17 * soma) break
            }
            return soma
        }

        private val TABELA: FloatArray by lazy {
            val n = MEIA_LARGURA * FASES + 2
            val i0b = besselI0(BETA)
            FloatArray(n) { i ->
                val t = i.toDouble() / FASES
                if (t >= MEIA_LARGURA) return@FloatArray 0f
                val s = if (t == 0.0) 1.0 else sin(PI * t) / (PI * t)
                val r = t / MEIA_LARGURA
                (s * besselI0(BETA * sqrt(maxOf(0.0, 1 - r * r))) / i0b).toFloat()
            }
        }
    }

    private val razaoNominal = taxaEntrada.toDouble() / taxaSaida
    private val corte = minOf(1.0, 1.0 / razaoNominal)
    var u = 0.0
        private set
    private var entrada = FloatArray(0)
    private var guardadas = 0 // quadros guardados em `entrada`
    private var base = 0L
    var pos = 0.0
        private set
    var produzidas = 0L
        private set
    private var guardadasContadas = 0L

    val passo: Double get() = razaoNominal * (1 + u)
    fun definirAjuste(u: Double) { this.u = u }
    private val meiaLarguraDeEntrada: Double get() = MEIA_LARGURA / corte

    val fimDaEntrada: Long get() = if (soContar) base + guardadasContadas else base + guardadas

    /** O índice de saída (fracionário) cuja posição de entrada é `x`. */
    fun indiceDeSaida(x: Double): Double = produzidas + (x - pos) / passo

    fun empurrar(amostras: ShortArray, quadros: Int, de: Int = 0) {
        val n = quadros - de
        if (n <= 0) return
        if (soContar) { guardadasContadas += n; return }
        garantir(guardadas + n)
        for (i in 0 until n * canais) entrada[guardadas * canais + i] = amostras[de * canais + i] / 32768f
        guardadas += n
    }

    fun pularEntrada(quadros: Long) { pos += quadros }

    private fun garantir(quadros: Int) {
        if (entrada.size < quadros * canais) entrada = entrada.copyOf(maxOf(quadros * canais, entrada.size * 2))
    }

    /** Produz toda a saída que a entrada permite, em `saida`. */
    fun produzir(saida: SaidaDeAmostras) {
        val l = meiaLarguraDeEntrada
        val p = passo
        val fim = fimDaEntrada.toDouble()
        while (Math.floor(pos + l) < fim) {
            if (soContar) saida.zeros(canais) else umaSaida(l, saida)
            pos += p
            produzidas++
        }
        descartarHistoria(l)
    }

    /** O acumulador de uma amostra de saída, reusado: alocar um por amostra custava 96 mil objetos
     *  por segundo a 48 kHz estéreo (a revisão do código, leve 8). */
    private val acc = DoubleArray(canais)

    private fun umaSaida(l: Double, saida: SaidaDeAmostras) {
        val c = corte
        val tab = TABELA
        val i0 = maxOf(Math.ceil(pos - l).toLong(), base)
        val i1 = Math.floor(pos + l).toLong()
        java.util.Arrays.fill(acc, 0.0)
        var i = i0
        while (i <= i1) {
            val t = abs(i - pos) * c * FASES
            val k = t.toInt()
            if (k + 1 < tab.size) {
                val fr = (t - k).toFloat()
                val w = (tab[k] + (tab[k + 1] - tab[k]) * fr).toDouble()
                val j = ((i - base) * canais).toInt()
                for (ch in 0 until canais) acc[ch] += entrada[j + ch] * w
            }
            i++
        }
        // Arredondar, e não truncar: o `toInt()` corta para o zero, e a primeira versão dava 82 dB
        // a 8 kHz em vez de ~89 (o piso do `Int16`), com distorção de cruzamento (o teste).
        for (ch in 0 until canais) saida.uma(Math.round((acc[ch] * c * 32768).coerceIn(-32768.0, 32767.0)).toInt().toShort())
    }

    private fun descartarHistoria(l: Double) {
        val primeira = Math.floor(pos - l) - 1
        if (primeira <= base) return
        val descartar = minOf(primeira.toLong() - base, fimDaEntrada - base)
        if (soContar) {
            guardadasContadas -= descartar
        } else {
            val d = descartar.toInt()
            System.arraycopy(entrada, d * canais, entrada, 0, (guardadas - d) * canais)
            guardadas -= d
        }
        base += descartar
    }
}

/** A saída do reamostrador: amostras `Int16` intercaladas, crescendo. */
class SaidaDeAmostras {
    var dados = ShortArray(4096)
        private set
    var tamanho = 0
        private set

    fun uma(v: Short) {
        if (tamanho == dados.size) dados = dados.copyOf(dados.size * 2)
        dados[tamanho++] = v
    }

    fun zeros(n: Int) { repeat(n) { uma(0) } }

    /** Tira os primeiros `n` valores. */
    fun tirar(n: Int): ShortArray {
        val q = dados.copyOf(n)
        System.arraycopy(dados, n, dados, 0, tamanho - n)
        tamanho -= n
        return q
    }

    fun limpar(): Int { val n = tamanho; tamanho = 0; return n }
}

/**
 * **O laço da disciplina da deriva** (`som-no-receptor.md` §19.6.4), o mesmo de
 * `apps/windows/src/disciplina.rs`: as medidas de ε (µs) se agregam por segundo (a média recortada a
 * ±4 MAD), e a cada segundo `f` e `u` andam, com T = 5 s nos primeiros 20 s e 60 s depois, e `u`
 * limitado a ±1 000 ppm e a 20 ppm por atualização. Com |ε| > 40 ms por 1 s, devolve o socorro.
 */
class DisciplinaDaDeriva(val ligada: Boolean = true) {
    companion object {
        const val U_MAX = 1_000e-6
        const val F_MAX = 500e-6
        const val PASSO_MAXIMO_DE_U = 20e-6
        const val LIMIAR_DO_SOCORRO_US = 40_000.0
        const val ATUALIZACAO_S = 1.0
        const val T_CURTO_S = 5.0
        const val T_LONGO_S = 60.0
        const val PARTIDA_S = 20.0
    }

    var f = 0.0
        private set
    var u = 0.0
        private set
    private var inicioUs: Double? = null
    private var inicioDoPeriodoUs: Double? = null
    private val medidas = ArrayList<Double>(128)
    private var acimaDesdeUs: Double? = null
    var socorros = 0
        private set
    var maiorDuPpm = 0.0
        private set

    val fPpm: Double get() = f * 1e6

    /** Uma medida. Devolve o ε do socorro, quando ele dispara. */
    fun medir(agoraUs: Double, epsUs: Double): Double? {
        val inicio = inicioUs ?: agoraUs.also { inicioUs = it }
        val periodo = inicioDoPeriodoUs ?: agoraUs.also { inicioDoPeriodoUs = it }
        if (ligada && abs(epsUs) > LIMIAR_DO_SOCORRO_US) {
            val desde = acimaDesdeUs ?: agoraUs.also { acimaDesdeUs = it }
            if (agoraUs - desde >= 1e6) {
                socorros++
                acimaDesdeUs = null
                return epsUs
            }
        } else {
            acimaDesdeUs = null
        }
        medidas.add(epsUs)
        if (agoraUs - periodo >= ATUALIZACAO_S * 1e6 - 1) {
            // O `dt` tem teto de dois períodos: depois de uma rajada longa sem par, o período aberto
            // antes dela fecharia com a rajada inteira, e `f ← f − ε·dt/T²` multiplicaria o ruído de
            // uma medida pela duração dela (o controle, no teste: 450 ppm fora depois de 1 h).
            val dt = minOf((agoraUs - periodo) / 1e6, 2 * ATUALIZACAO_S)
            val e = agregar()
            medidas.clear()
            inicioDoPeriodoUs = agoraUs
            if (ligada) atualizar(e, dt, (agoraUs - inicio) / 1e6)
        }
        return null
    }

    private fun agregar(): Double {
        val s = medidas.sorted()
        val med = s[s.size / 2]
        val mad = maxOf(10.0, 1.4826 * s.map { abs(it - med) }.sorted()[s.size / 2])
        val lim = 4 * mad
        return s.sumOf { it.coerceIn(med - lim, med + lim) } / s.size
    }

    private fun atualizar(eUs: Double, dt: Double, desdeS: Double) {
        val naPartida = desdeS < PARTIDA_S
        val t = if (naPartida) T_CURTO_S else T_LONGO_S
        val kp = 2 / t
        val ki = 1 / (t * t)
        val e = eUs * 1e-6
        f = (f - ki * e * dt).coerceIn(-F_MAX, F_MAX)
        val alvo = (f - kp * e).coerceIn(-U_MAX, U_MAX)
        val novo = if (naPartida) alvo else alvo.coerceIn(u - PASSO_MAXIMO_DE_U, u + PASSO_MAXIMO_DE_U)
        if (desdeS > 60) maiorDuPpm = maxOf(maiorDuPpm, abs(novo - u) * 1e6)
        u = novo
    }

    /** Depois de um degrau: a fase recomeça, a frequência fica. */
    fun reancorar() {
        medidas.clear()
        inicioDoPeriodoUs = null
        acimaDesdeUs = null
        u = f
    }
}

/**
 * **A linha do som de uma fonte ritmada pelo dispositivo** (`som-no-receptor.md` §19.6.4): a
 * captura do próprio app, e o dispositivo de mentira do teste de bancada (`TomRitmado`).
 *
 * - Cada quadro da fonte chega com a hora do host da primeira amostra (`instanteDoQuadroUs`). O erro
 *   é `ε = H − S`, contra o carimbo que a linha de saída dá a ela; o laço reamostra o conteúdo, e o
 *   carimbo anda um quadro exato por quadro de saída.
 * - **Quadro sem hora** (M2): não alimenta nada; antes do primeiro par, é jogado fora (a âncora
 *   espera o primeiro par).
 * - **A lacuna** (N6): ε longe do **nível** (a mediana dos últimos 5 ε aceitos) mais que
 *   max(10 ms, 6σ), por 5 quadros seguidos e coerentes entre si. Para a frente, degrau no carimbo;
 *   para trás, corte na entrada. Enquanto se confirma, o laço não é alimentado. Não se sabe se o
 *   `framePosition` do `AudioRecord` conta o que o servidor jogou fora num transbordo; se contasse,
 *   o sinal sairia da contagem. A regra do desenho (§19.6.4: o quadro anterior como nível, 2 ms,
 *   σ pela mediana) reprovou nos testes, e fica como controle (`regraDoDesenho`):
 *   - um pico abaixo do limiar virava o nível, e a volta ao normal era um salto confirmado: 26
 *     lacunas falsas em 10 min com a cauda pesada;
 *   - com o par do `getTimestamp` por período de buffer, a diferença de quadro a quadro é ~0 entre
 *     um par e outro, a mediana desaba, e o par que dura o período inteiro confirmava: 20 lacunas
 *     falsas em 10 min.
 *
 *   O piso de 10 ms é o de uma lacuna da captura, que é um buffer inteiro jogado fora pelo
 *   servidor (um buffer do Android é de 10 ms ou mais: suposição, não medida). Abaixo dele, o erro
 *   vai ao laço, que o tira em ~T.
 * - O socorro, como no Windows. Depois dele (e de uma lacuna), o nível recomeça: sem isso, a volta
 *   de ε depois do degrau do socorro era confirmada como lacuna para trás, cortava a entrada, e o
 *   socorro voltava (1 536 socorros em 30 min a −1 500 ppm, no teste).
 *
 * Pura, sem relógio: quem chama passa as horas.
 */
class LinhaDoSomRitmado(
    taxa: Int,
    val canais: Int,
    private val amostrasPorQuadro: Int,
    disciplina: Boolean = true,
    soContar: Boolean = false,
    /** Quantos quadros seguidos confirmam uma lacuna; `1` é o controle par a par. */
    private val quadrosParaConfirmar: Int = QUADROS_PARA_CONFIRMAR,
    /** O controle: a regra da lacuna do desenho (§19.6.4), que reprovou nos testes. */
    private val regraDoDesenho: Boolean = false,
) {
    companion object {
        const val PISO_DO_SALTO_US = 10_000.0
        const val PISO_DO_SALTO_DO_DESENHO_US = 2_000.0
        const val QUADROS_PARA_CONFIRMAR = 5
        const val QUADROS_DO_NIVEL = 5
        /**
         * O prazo sem nenhum par antes do recuo para a hora da vaga (D), e a rajada sem par depois
         * da qual o laço recomeça a medir (A): 1 s de quadros.
         */
        const val QUADROS_ATE_O_RECUO = 50
        /** O teto da correção de fase para trás na troca da vaga para o par (1 s). */
        const val MAXIMO_DE_CORTE_US = 1_000_000.0
    }

    /** A hora vem da vaga (o recuo de D): o `getTimestamp` não deu par nenhum no prazo. */
    var pelaVaga = false
        private set

    private val taxa = taxa.toDouble()
    val sinc = ReamostradorSinc(taxa, taxa, canais, soContar)
    val disc = DisciplinaDaDeriva(disciplina)
    private val saida = SaidaDeAmostras()
    var ancoraUs: Double? = null
        private set
    private var degrausUs = 0.0
    private var descartadas = 0L
    private var quadrosFeitos = 0L
    private val quadroUs = amostrasPorQuadro * 1e6 / this.taxa

    // A lacuna (N6).
    private val recentes = ArrayDeque<Double>()
    private val suspeitos = ArrayList<Double>()
    private val diferencas = ArrayDeque<Double>()
    // A regra do desenho (o controle).
    private var epsAnterior: Double? = null
    private var suspeito: Double? = null
    private var epsAntesDoSalto = 0.0
    private var confirmacoes = 0

    var semHora = 0
        private set
    var semHoraSeguidos = 0
        private set
    var maiorRajadaSemHora = 0
        private set
    var lacunas = 0
        private set
    var degraus = 0
        private set
    var picosIgnorados = 0
        private set
    var quadrosPelaVaga = 0
        private set
    var trocasParaOPar = 0
        private set
    var amostrasCortadas = 0L
        private set
    var epsUs = 0.0
        private set
    var ultimoSUs = 0.0
        private set

    private fun s(y: Double): Double = (ancoraUs ?: 0.0) + (y - descartadas) / taxa * 1e6 + degrausUs

    /**
     * Um quadro da fonte (`quadros` amostras por canal, intercaladas em `pcm`), com a hora da primeira
     * amostra (`null`: sem par). Devolve os quadros de saída prontos, com o carimbo (µs do host).
     */
    fun quadro(pcm: ShortArray, quadros: Int, horaUs: Long?, horaDeRecuoUs: Long? = null): List<Pair<ShortArray, Long>> {
        var hora = horaUs
        var trocaParaOPar = false
        if (hora == null) {
            semHora++
            semHoraSeguidos++
            maiorRajadaSemHora = maxOf(maiorRajadaSemHora, semHoraSeguidos)
            // **O recuo (a revisão do código, D)**: sem nenhum par do `getTimestamp` em 1 s, a
            // captura ficava muda a sessão inteira. Agora a hora da vaga (a leitura, que carrega a
            // latência do buffer, como o carimbo de antes da S8) ancora e segue até o par aparecer.
            if (horaDeRecuoUs != null && (pelaVaga || (ancoraUs == null && semHoraSeguidos > QUADROS_ATE_O_RECUO))) {
                pelaVaga = true
                quadrosPelaVaga++
                hora = horaDeRecuoUs
            } else {
                if (ancoraUs == null) return emptyList()
                if (semHoraSeguidos == QUADROS_ATE_O_RECUO) {
                    // Sem par há 1 s: sem medida, a fase não tem como ser seguida, e a razão fica
                    // na frequência estimada. Congelado, o termo de fase (o ruído da última
                    // medida) virava deriva pela rajada inteira (o teste: 3,4 ms em 1 h).
                    disc.reancorar()
                    sinc.definirAjuste(disc.u)
                }
                sinc.empurrar(pcm, quadros)
                return produzir()
            }
        } else {
            if (pelaVaga) {
                pelaVaga = false
                trocasParaOPar++
                trocaParaOPar = true
            } else if (semHoraSeguidos >= QUADROS_ATE_O_RECUO && ancoraUs != null) {
                // O par voltou depois de uma rajada longa (A): o laço recomeça a medir daqui, a
                // frequência fica, e o nível do N6 recomeça (o que a rajada acumulou vai ao laço).
                disc.reancorar()
                esquecerONivel()
            }
            semHoraSeguidos = 0
        }
        val h = hora!!.toDouble()
        if (ancoraUs == null) ancoraUs = h
        val x0 = sinc.fimDaEntrada.toDouble()
        val sq = s(sinc.indiceDeSaida(x0))
        ultimoSUs = sq
        val eps = h - sq
        epsUs = eps
        if (trocaParaOPar) {
            // A troca da vaga para o par: a fase é corrigida uma vez. A vaga chega depois da
            // captura (a latência do buffer), então o carimbo estava à frente: a entrada é cortada
            // nesse tanto, até 1 s. Atrás, um degrau para a frente.
            if (eps > 0) {
                degrausUs += Math.round(eps).toDouble()
                degraus++
            } else {
                val n = Math.round(minOf(-eps, MAXIMO_DE_CORTE_US) * taxa / 1e6)
                sinc.pularEntrada(n)
                amostrasCortadas += n
            }
            disc.reancorar()
            esquecerONivel()
            sinc.definirAjuste(disc.u)
            sinc.empurrar(pcm, quadros)
            return produzir()
        }
        if (!detectarLacuna(eps)) {
            disc.medir(h, eps)?.let { socorro(it, x0, h) }
        }
        sinc.definirAjuste(disc.u)
        sinc.empurrar(pcm, quadros)
        return produzir()
    }

    /** Devolve `true` enquanto um salto se confirma (e o laço não deve ver a medida). */
    private fun detectarLacuna(eps: Double): Boolean {
        if (regraDoDesenho) return detectarLacunaDoDesenho(eps)
        if (recentes.size < 3) {
            aceitar(eps, null)
            return false
        }
        val nivel = recentes.sorted()[recentes.size / 2]
        val d = eps - nivel
        val escala = escala()
        if (abs(d) <= maxOf(PISO_DO_SALTO_US, 6 * escala)) {
            if (suspeitos.isNotEmpty()) {
                // Não ficou: eram picos da hora.
                picosIgnorados++
                suspeitos.clear()
            }
            aceitar(eps, d)
            return false
        }
        // Longe do nível: um salto que fica, ou um pico. Os suspeitos têm de ser coerentes entre si.
        if (suspeitos.isNotEmpty() && abs(eps - suspeitos[0]) > maxOf(1_000.0, 3 * escala)) {
            picosIgnorados++
            suspeitos.clear()
        }
        suspeitos.add(eps)
        if (suspeitos.size >= quadrosParaConfirmar) {
            val ordenados = suspeitos.sorted()
            confirmarLacuna(ordenados[ordenados.size / 2] - nivel)
        }
        return true
    }

    private fun aceitar(eps: Double, d: Double?) {
        recentes.addLast(eps)
        if (recentes.size > QUADROS_DO_NIVEL) recentes.removeFirst()
        if (d != null) {
            diferencas.addLast(d)
            if (diferencas.size > 200) diferencas.removeFirst()
        }
    }

    /** Depois de um degrau (lacuna ou socorro), o nível recomeça. */
    private fun esquecerONivel() {
        recentes.clear()
        suspeitos.clear()
        epsAnterior = null
        suspeito = null
    }

    private fun confirmarLacuna(salto: Double) {
        lacunas++
        degraus++
        if (salto > 0) {
            // A sobra da saída **fica**: a confirmação leva 5 quadros, e ela já é som de depois da
            // lacuna, que o degrau põe na hora certa. (A primeira versão a jogava fora e somava só o
            // salto: o som de depois ficava atrás do tamanho da sobra, 19 ms, no teste.)
            degrausUs += Math.round(salto).toDouble()
        } else {
            val n = Math.round(-salto * taxa / 1e6)
            sinc.pularEntrada(n)
            amostrasCortadas += n
        }
        disc.reancorar()
        esquecerONivel()
    }

    /**
     * A escala do ruído de ε em volta do nível (µs, como um desvio-padrão), pelo **quantil de 95 %**
     * de |d| (÷ 1,96): a mediana desaba quando o par do `getTimestamp` só muda a cada período de
     * buffer, e o quantil de 95 % aguenta até 5 % de picos.
     */
    private fun escala(): Double {
        if (diferencas.size < 20) return 0.0
        val s = diferencas.map { abs(it) }.sorted()
        return s[(s.size * 95) / 100] / 1.96
    }

    /** A regra do desenho (§19.6.4), o controle: o quadro anterior como nível, 2 ms, σ pela mediana. */
    private fun detectarLacunaDoDesenho(eps: Double): Boolean {
        val anterior = epsAnterior
        epsAnterior = eps
        val sus = suspeito
        if (sus != null) {
            val tolerancia = maxOf(1_000.0, 3 * madDoDesenho())
            if (abs(eps - sus) <= tolerancia) {
                confirmacoes++
                if (confirmacoes >= quadrosParaConfirmar) confirmarLacunaDoDesenho(sus)
                return true
            }
            picosIgnorados++
            suspeito = null
            return false
        }
        if (anterior != null) {
            val d = eps - anterior
            if (abs(d) > maxOf(PISO_DO_SALTO_DO_DESENHO_US, 6 * madDoDesenho())) {
                suspeito = eps
                epsAntesDoSalto = anterior
                confirmacoes = 1
                if (confirmacoes >= quadrosParaConfirmar) confirmarLacunaDoDesenho(eps)
                return true
            }
            diferencas.addLast(d)
            if (diferencas.size > 200) diferencas.removeFirst()
        }
        return false
    }

    private fun confirmarLacunaDoDesenho(sus: Double) {
        val salto = sus - epsAntesDoSalto
        confirmarLacuna(salto)
    }

    private fun madDoDesenho(): Double {
        if (diferencas.size < 20) return 0.0
        val s = diferencas.map { abs(it) }.sorted()
        return 1.4826 * s[s.size / 2]
    }

    private fun socorro(eps: Double, x0: Double, h: Double) {
        degraus++
        if (eps > 0) {
            descartadas += saida.limpar() / canais
            degrausUs += maxOf(0.0, Math.round(h - s(sinc.indiceDeSaida(x0))).toDouble())
        } else {
            val n = Math.round(-eps * taxa / 1e6)
            sinc.pularEntrada(n)
            amostrasCortadas += n
        }
        disc.reancorar()
        esquecerONivel()
    }

    private fun produzir(): List<Pair<ShortArray, Long>> {
        sinc.produzir(saida)
        val prontos = ArrayList<Pair<ShortArray, Long>>(2)
        val porQuadro = amostrasPorQuadro * canais
        while (saida.tamanho >= porQuadro) {
            val carimbo = ((ancoraUs ?: 0.0) + quadrosFeitos * quadroUs + degrausUs).toLong()
            quadrosFeitos++
            prontos.add(saida.tirar(porQuadro) to carimbo)
        }
        return prontos
    }
}
