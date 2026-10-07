package com.quall.android.capture

import androidx.annotation.StringRes
import com.quall.android.R
import com.quall.android.core.Textos
import kotlin.math.abs
import kotlin.math.ln

/**
 * **O que a câmera declara**, lido uma vez na abertura (`Camera2CameraInfo`), em números simples: a
 * [RegrasDosControles] decide tudo a partir daqui, sem tipo do Android. Os valores de enumeração são os
 * da Camera2 (ver [Camera2Valores]).
 */
data class CapacidadesDaCamera(
    /** `REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR`. */
    val manualSensor: Boolean = false,
    /** `REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING`. */
    val manualPosProcessamento: Boolean = false,
    /** `READ_SENSOR_SETTINGS`: o resultado devolve ISO e exposição aplicados. */
    val leSensor: Boolean = false,
    val isoMin: Int = 0,
    val isoMax: Int = 0,
    /** `SENSOR_MAX_ANALOG_SENSITIVITY`, ou `null`. */
    val isoMaxAnalogico: Int? = null,
    val exposicaoMinNs: Long = 0,
    val exposicaoMaxNs: Long = 0,
    /** A faixa e o passo do EV (`ExposureState`). */
    val evIndiceMin: Int = 0,
    val evIndiceMax: Int = 0,
    val evPassoNum: Int = 1,
    val evPassoDen: Int = 1,
    /** `CONTROL_AWB_AVAILABLE_MODES`. */
    val modosDeBalanco: Set<Int> = emptySet(),
    /** `CONTROL_AE_AVAILABLE_ANTIBANDING_MODES`. */
    val modosAntiCintilacao: Set<Int> = emptySet(),
    val travaAe: Boolean = false,
    val travaAwb: Boolean = false,
    /** A lente tem AF: um modo de AF além do `OFF`, e distância mínima de foco > 0. */
    val temAf: Boolean = false,
    /** `LENS_INFO_MINIMUM_FOCUS_DISTANCE`, em dioptrias. */
    val focoMinimoDioptrias: Float = 0f,
    /** `lens.focusDistance` está nas `availableRequestKeys`. */
    val focoNaRequisicao: Boolean = false,
    /**
     * A posição do foco **lida** é de confiar: `READ_SENSOR_SETTINGS` e `lens.focusDistance` nas
     * `availableCaptureResultKeys`. Sem isso o `LENS_FOCUS_DISTANCE` do resultado não precisa ser o que a
     * lente usou: no tablet (sem `READ_SENSOR_SETTINGS`) o toque longo leu 1,0, o mais perto, e a
     * reabertura pôs a lente a 10 cm (a corrida da sessão principal de 01/10).
     */
    val focoLido: Boolean = false,
    /** `LENS_INFO_FOCUS_DISTANCE_CALIBRATION` é `APPROXIMATE` ou `CALIBRATED`: dá para falar em metros. */
    val focoCalibrado: Boolean = false,
    val abertura: Float? = null,
    /** As matrizes de cor e as iluminações de calibração, completas, ou `null`. */
    val calibracao: KelvinDng.Calibracao? = null,
    val regioesAe: Int = 0,
    val regioesAf: Int = 0,
    val regioesAwb: Int = 0,
) {
    val exposicaoManual: Boolean get() = manualSensor && isoMax > 0 && exposicaoMaxNs > 0
    val kelvin: Boolean get() = manualPosProcessamento && calibracao != null
    /** Foco manual: AF **e** `MANUAL_SENSOR` (ou a chave na requisição) (§1). */
    val focoManual: Boolean get() = temAf && focoMinimoDioptrias > 0f && (manualSensor || focoNaRequisicao)
    val ev: Boolean get() = evIndiceMax > evIndiceMin
    val presets: List<AjusteDaCamera.Balanco> get() =
        RegrasDosControles.PRESETS.filter { (_, modo) -> modo in modosDeBalanco }.map { it.first }
    val pontoDeInteresse: Boolean get() = regioesAf > 0 || regioesAe > 0 || regioesAwb > 0
}

/** Os valores de enumeração da Camera2 que o R9 escreve, copiados de `CameraMetadata` (estáveis desde a API 21). */
object Camera2Valores {
    const val AE_MODE_OFF = 0
    const val AWB_MODE_OFF = 0
    const val AWB_MODE_AUTO = 1
    const val AWB_MODE_INCANDESCENT = 2
    const val AWB_MODE_FLUORESCENT = 3
    const val AWB_MODE_DAYLIGHT = 5
    const val AWB_MODE_CLOUDY_DAYLIGHT = 6
    const val AF_MODE_OFF = 0
    const val COLOR_CORRECTION_MODE_TRANSFORM_MATRIX = 0
    const val ANTIBANDING_OFF = 0
    const val ANTIBANDING_50HZ = 1
    const val ANTIBANDING_60HZ = 2
    const val ANTIBANDING_AUTO = 3
    /** `CONTROL_AE_STATE` / `CONTROL_AWB_STATE`: `CONVERGED` = 2 e `LOCKED` = 3 nos dois. */
    const val ESTADO_3A_CONVERGED = 2
    const val ESTADO_3A_LOCKED = 3
}

/**
 * **As regras do R9 no Android** (`docs/controles-de-camera.md` §2.1, §2.2, §3.5, §4.4 e §4.5), puras:
 * do registro e das capacidades às chaves do interop; o toque na prévia; os textos de quem limita.
 */
object RegrasDosControles {

    /** Os presets da grade, com o modo de AWB da Camera2 de cada um (§3.4). */
    val PRESETS = listOf(
        AjusteDaCamera.Balanco.INCANDESCENTE to Camera2Valores.AWB_MODE_INCANDESCENT,
        AjusteDaCamera.Balanco.FLUORESCENTE to Camera2Valores.AWB_MODE_FLUORESCENT,
        AjusteDaCamera.Balanco.LUZ_DO_DIA to Camera2Valores.AWB_MODE_DAYLIGHT,
        AjusteDaCamera.Balanco.NUBLADO to Camera2Valores.AWB_MODE_CLOUDY_DAYLIGHT,
    )

    /** Quanto a trava sem controle manual espera o 3A convergir antes de travar assim mesmo (§2.1). */
    const val ESPERA_DO_3A_MS = 3_000L

    /** "Travado de novo depois de medir a cena." fica 3 s na tela (§2.1). */
    fun textoTravadoDeNovo(t: Textos): String = t.s(R.string.cam_travado_de_novo)

    /** Os envios à câmera são agrupados a no máximo 15 por segundo (§2.2). */
    const val INTERVALO_DOS_ENVIOS_MS = 67L

    /** A linha de leitura se atualiza no máximo 4 vezes por segundo (§3.6). */
    const val INTERVALO_DA_LEITURA_MS = 250L

    /** As chaves que o `setCaptureRequestOptions` pode levar — e **só** estas (§4.5). */
    enum class Chave {
        CONTROL_AE_MODE, SENSOR_SENSITIVITY, SENSOR_EXPOSURE_TIME, SENSOR_FRAME_DURATION,
        CONTROL_AE_LOCK, CONTROL_AE_ANTIBANDING_MODE,
        CONTROL_AWB_MODE, COLOR_CORRECTION_MODE, COLOR_CORRECTION_GAINS, COLOR_CORRECTION_TRANSFORM,
        CONTROL_AWB_LOCK,
        CONTROL_AF_MODE, LENS_FOCUS_DISTANCE,
    }

    /**
     * O que vale no instante de aplicar: o fps negociado (o teto do obturador, §3.1) e se o 3A já
     * convergiu desde a abertura (ou passou o prazo de [ESPERA_DO_3A_MS]) — a trava sem manual só vai
     * depois disso (§2.1).
     */
    data class Momento(val fps: Int, val aeConvergiu: Boolean = true, val awbConvergiu: Boolean = true)

    /** O que de fato vai à câmera, já cortado (§2.2: a tela mostra o aplicado; o guardado fica intacto). */
    data class Plano(
        /** As chaves do interop, com os valores: `Int`, `Long`, `Boolean`, `Float` ou `List<Double>`. */
        val chaves: Map<Chave, Any>,
        /** O índice de EV do `setExposureCompensationIndex`, só com exposição Auto (ou `null`). */
        val indiceDoEv: Int?,
        /** A trava de foco sem manual: `startFocusAndMetering(FLAG_AF)` no centro, sem cancelar (§4.5). */
        val travarFocoNoCentro: Boolean,
        /** Uma trava sem manual espera o 3A: a tela diz [textoTravadoDeNovo] quando ela for. */
        val esperandoAe: Boolean,
        val esperandoAwb: Boolean,
        val isoAplicado: Int?,
        val obturadorAplicadoNs: Long?,
        val kelvinAplicado: Int?,
    )

    /**
     * **As chaves do interop por situação** (§4.5) e o resto do que se aplica. O interop **nunca** leva
     * `CONTROL_AF_MODE` com foco Auto ou Travado-sem-manual (quebraria o disparo do AF no toque), nem
     * regiões, nem `CONTROL_AE_EXPOSURE_COMPENSATION` (o EV vai pelo CameraX, só com exposição Auto).
     *
     * Tudo é **cortado pela faixa do instante** (§2.2): ISO e obturador na faixa e no teto de 1/fps.
     * Um controle que a câmera não declara fica de fora em silêncio — a tela já o mostra apagado.
     */
    fun plano(a: AjusteDaCamera, c: CapacidadesDaCamera, m: Momento): Plano {
        val chaves = LinkedHashMap<Chave, Any>()
        var iso: Int? = null
        var obt: Long? = null
        var kelvin: Int? = null
        var esperandoAe = false
        var esperandoAwb = false
        var indiceDoEv: Int? = null

        fun exposicaoManual(isoPedido: Int, obtPedido: Long) {
            iso = EscalasDaCamera.cortarIso(isoPedido, c.isoMin, c.isoMax)
            obt = EscalasDaCamera.cortarObturador(obtPedido, c.exposicaoMinNs, c.exposicaoMaxNs, m.fps)
            chaves[Chave.CONTROL_AE_MODE] = Camera2Valores.AE_MODE_OFF
            chaves[Chave.SENSOR_SENSITIVITY] = iso!!
            chaves[Chave.SENSOR_EXPOSURE_TIME] = obt!!
            // Com `AE_MODE OFF` o HAL ignora a faixa de fps e usa a duração de quadro do pedido (§3.1).
            chaves[Chave.SENSOR_FRAME_DURATION] = EscalasDaCamera.duracaoDoQuadroNs(m.fps)
        }

        // --- a exposição ---
        when {
            a.exposicao == AjusteDaCamera.Exposicao.MANUAL && c.exposicaoManual && a.iso != null && a.obturadorNs != null ->
                exposicaoManual(a.iso, a.obturadorNs)
            a.exposicao == AjusteDaCamera.Exposicao.MANUAL -> Unit // sem MANUAL_SENSOR, ou sem valores: nada
            a.travaExposicao && c.exposicaoManual && a.travaIso != null && a.travaObturadorNs != null ->
                exposicaoManual(a.travaIso, a.travaObturadorNs)
            a.travaExposicao && c.travaAe -> if (m.aeConvergiu) chaves[Chave.CONTROL_AE_LOCK] = true else esperandoAe = true
            else -> Unit
        }
        if (a.exposicao == AjusteDaCamera.Exposicao.AUTO && c.ev) {
            indiceDoEv = EscalasDaCamera.indiceDoEv(a.ev, c.evPassoNum, c.evPassoDen, c.evIndiceMin, c.evIndiceMax)
        }
        val antiModo = when (a.antiCintilacao) {
            AjusteDaCamera.AntiCintilacao.AUTO -> null
            AjusteDaCamera.AntiCintilacao.HZ50 -> Camera2Valores.ANTIBANDING_50HZ
            AjusteDaCamera.AntiCintilacao.HZ60 -> Camera2Valores.ANTIBANDING_60HZ
            AjusteDaCamera.AntiCintilacao.DESLIGADA -> Camera2Valores.ANTIBANDING_OFF
        }
        if (antiModo != null && antiModo in c.modosAntiCintilacao) chaves[Chave.CONTROL_AE_ANTIBANDING_MODE] = antiModo

        // --- o balanço ---
        fun balancoManual(ganhos: DoubleArray, matriz: DoubleArray) {
            chaves[Chave.CONTROL_AWB_MODE] = Camera2Valores.AWB_MODE_OFF
            chaves[Chave.COLOR_CORRECTION_MODE] = Camera2Valores.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX
            chaves[Chave.COLOR_CORRECTION_GAINS] = ganhos.toList()
            chaves[Chave.COLOR_CORRECTION_TRANSFORM] = matriz.toList()
        }
        val preset = PRESETS.firstOrNull { it.first == a.balanco }?.second
        val cal = c.calibracao
        when {
            preset != null -> if (preset in c.modosDeBalanco) chaves[Chave.CONTROL_AWB_MODE] = preset
            a.balanco == AjusteDaCamera.Balanco.KELVIN -> {
                val k = a.kelvin?.let { EscalasDaCamera.cortarKelvin(it) }
                val g = if (k != null && c.kelvin && cal != null) KelvinDng.ganhos(cal, k.toDouble()) else null
                if (g != null && cal != null && k != null) {
                    balancoManual(g, KelvinDng.matrizDeCorrecao(cal, k.toDouble()))
                    kelvin = k
                }
            }
            a.travaBalanco -> {
                val g = a.travaGanhos?.toDoubleArray()
                val kDaTrava = if (g != null && c.manualPosProcessamento && cal != null) KelvinDng.kelvinDosGanhos(cal, g) else null
                if (g != null && cal != null && kDaTrava != null) {
                    // Reaplicada como manual com os ganhos guardados; a matriz é a da mesma temperatura.
                    balancoManual(g, KelvinDng.matrizDeCorrecao(cal, kDaTrava))
                } else if (c.travaAwb) {
                    if (m.awbConvergiu) chaves[Chave.CONTROL_AWB_LOCK] = true else esperandoAwb = true
                }
            }
            else -> Unit
        }

        // --- o foco ---
        var travarFocoNoCentro = false
        when (a.foco) {
            AjusteDaCamera.Foco.MANUAL -> if (c.focoManual && a.focoPosicao != null) {
                chaves[Chave.CONTROL_AF_MODE] = Camera2Valores.AF_MODE_OFF
                chaves[Chave.LENS_FOCUS_DISTANCE] = EscalasDaCamera.dioptriasDoFoco(a.focoPosicao, c.focoMinimoDioptrias)
            }
            // A trava de foco só volta como manual com uma posição que a câmera de fato informou
            // ([CapacidadesDaCamera.focoLido]); sem isso, o AF no centro sem cancelamento (§4.5).
            AjusteDaCamera.Foco.TRAVADO -> if (c.focoManual && c.focoLido && a.focoPosicao != null) {
                chaves[Chave.CONTROL_AF_MODE] = Camera2Valores.AF_MODE_OFF
                chaves[Chave.LENS_FOCUS_DISTANCE] = EscalasDaCamera.dioptriasDoFoco(a.focoPosicao, c.focoMinimoDioptrias)
            } else if (c.temAf) {
                travarFocoNoCentro = true
            }
            AjusteDaCamera.Foco.AUTO -> Unit
        }
        return Plano(chaves, indiceDoEv, travarFocoNoCentro, esperandoAe, esperandoAwb, iso, obt, kelvin)
    }

    // --- o toque na prévia (§4.4) ------------------------------------------------------------------

    enum class Medida { AF, AE, AWB }

    /**
     * O que um toque mede: tudo o que a câmera tem de ponto de interesse; com exposição Manual, só o
     * foco; com foco Manual ou fixo, só AE e AWB; com os dois em manual, nada (e não aparece quadrado).
     */
    fun medidasDoToque(a: AjusteDaCamera, c: CapacidadesDaCamera): Set<Medida> {
        val exposicaoManual = a.exposicao == AjusteDaCamera.Exposicao.MANUAL && c.exposicaoManual
        val focoManualOuFixo = !c.temAf || (a.foco == AjusteDaCamera.Foco.MANUAL && c.focoManual)
        val r = LinkedHashSet<Medida>()
        if (!focoManualOuFixo && c.regioesAf > 0) r.add(Medida.AF)
        if (!exposicaoManual) {
            if (c.regioesAe > 0) r.add(Medida.AE)
            if (c.regioesAwb > 0) r.add(Medida.AWB)
        }
        return r
    }

    /** O que o toque longo trava: a exposição (se em Auto) e o foco (se em Auto e a lente tiver AF). */
    data class TravasDoToque(val exposicao: Boolean, val foco: Boolean) {
        val alguma: Boolean get() = exposicao || foco
    }

    fun travasDoToqueLongo(a: AjusteDaCamera, c: CapacidadesDaCamera): TravasDoToque = TravasDoToque(
        exposicao = a.exposicao == AjusteDaCamera.Exposicao.AUTO && (c.travaAe || c.exposicaoManual),
        foco = a.foco == AjusteDaCamera.Foco.AUTO && c.temAf,
    )

    /** A pílula do toque longo (§4.4), ou `null` quando nada se trava. */
    fun pilulaDoToqueLongo(t: Textos, travas: TravasDoToque): String? = when {
        travas.exposicao && travas.foco -> t.s(R.string.cam_pilula_exposicao_e_foco)
        travas.exposicao -> t.s(R.string.cam_pilula_exposicao)
        travas.foco -> t.s(R.string.cam_pilula_foco)
        else -> null
    }

    /**
     * O registro depois do toque longo: as travas ligadas, **sem** os valores ainda — eles são lidos
     * depois de a câmera convergir no ponto novo (§2.1), por [comValoresDaTrava].
     */
    fun aposToqueLongo(a: AjusteDaCamera, t: TravasDoToque): AjusteDaCamera = a.copy(
        travaExposicao = a.travaExposicao || t.exposicao,
        travaIso = if (t.exposicao) null else a.travaIso,
        travaObturadorNs = if (t.exposicao) null else a.travaObturadorNs,
        foco = if (t.foco) AjusteDaCamera.Foco.TRAVADO else a.foco,
        focoPosicao = if (t.foco) null else a.focoPosicao,
    )

    /** Um toque simples depois do longo **desfaz as duas travas** (§4.4) e mede no ponto novo. */
    fun aposToqueSimplesQueDestrava(a: AjusteDaCamera, t: TravasDoToque): AjusteDaCamera = a.copy(
        travaExposicao = if (t.exposicao) false else a.travaExposicao,
        travaIso = if (t.exposicao) null else a.travaIso,
        travaObturadorNs = if (t.exposicao) null else a.travaObturadorNs,
        foco = if (t.foco && a.foco == AjusteDaCamera.Foco.TRAVADO) AjusteDaCamera.Foco.AUTO else a.foco,
    )

    /**
     * Grava os valores **lidos** no instante de travar (§2.1): ISO e exposição do `CaptureResult`
     * (com `READ_SENSOR_SETTINGS`), os ganhos de balanço (com `MANUAL_POST_PROCESSING`) e a posição do
     * foco. Só preenche o que está travado e ainda vazio; um valor `null` (não lido) fica vazio, e a
     * trava cai no caminho "depois de convergir".
     */
    fun comValoresDaTrava(
        a: AjusteDaCamera,
        iso: Int?, obturadorNs: Long?, ganhos: List<Double>?, focoPosicao: Double?,
    ): AjusteDaCamera = a.copy(
        travaIso = if (a.travaExposicao && a.travaIso == null) iso else a.travaIso,
        travaObturadorNs = if (a.travaExposicao && a.travaObturadorNs == null) obturadorNs else a.travaObturadorNs,
        travaGanhos = if (a.travaBalanco && a.travaGanhos == null) ganhos?.takeIf { it.size == 4 } else a.travaGanhos,
        focoPosicao = if (a.foco == AjusteDaCamera.Foco.TRAVADO && a.focoPosicao == null) focoPosicao else a.focoPosicao,
    )

    /** Ao passar a exposição a Manual, ISO e obturador partem dos valores lidos naquele instante (§4.3). */
    fun passarParaManual(a: AjusteDaCamera, isoLido: Int?, obturadorLidoNs: Long?, c: CapacidadesDaCamera, fps: Int): AjusteDaCamera {
        val iso = (isoLido ?: a.iso ?: c.isoMin.coerceAtLeast(100)).let { EscalasDaCamera.cortarIso(it, c.isoMin, c.isoMax) }
        val obt = (obturadorLidoNs ?: a.obturadorNs ?: EscalasDaCamera.duracaoDoQuadroNs(fps * 2))
            .let { EscalasDaCamera.cortarObturador(it, c.exposicaoMinNs, c.exposicaoMaxNs, fps) }
        return a.copy(exposicao = AjusteDaCamera.Exposicao.MANUAL, iso = iso, obturadorNs = obt,
            travaExposicao = false, travaIso = null, travaObturadorNs = null)
    }

    // --- quem limita (§3.5) ----------------------------------------------------------------------

    /**
     * Os controles do §3.5, cada um com **a frase inteira** de "o fabricante não libera" (`docs/traducao.md`,
     * Android): em português a frase leva o nome com o artigo ("o obturador", "a anti-cintilação"), e em
     * inglês a composição é outra — por isso uma chave por controle, e não o nome encaixado numa frase.
     */
    enum class Controle(@StringRes val naoLibera: Int) {
        ISO(R.string.cam_nao_libera_iso), OBTURADOR(R.string.cam_nao_libera_obturador),
        KELVIN(R.string.cam_nao_libera_kelvin), PRESETS(R.string.cam_nao_libera_presets),
        FOCO_MANUAL(R.string.cam_nao_libera_foco_manual), ANTI_CINTILACAO(R.string.cam_nao_libera_anti_cintilacao),
        EV(R.string.cam_nao_libera_ev), TOQUE(R.string.cam_nao_libera_toque),
        TRAVA_EXPOSICAO(R.string.cam_nao_libera_trava_exposicao), TRAVA_BALANCO(R.string.cam_nao_libera_trava_balanco),
        TRAVA_FOCO(R.string.cam_nao_libera_trava_foco),
    }

    fun focoFixo(t: Textos): String = t.s(R.string.cam_foco_fixo)
    fun semCalibracao(t: Textos): String = t.s(R.string.cam_sem_calibracao)

    /**
     * A linha embaixo de um controle apagado no Android, ou `null` se a câmera o oferece. O tablet, sem
     * `MANUAL_SENSOR`, cai em "O fabricante deste aparelho não libera ISO para outros apps.".
     */
    fun limite(t: Textos, controle: Controle, c: CapacidadesDaCamera): String? {
        val naoLibera = t.s(controle.naoLibera)
        return when (controle) {
            Controle.ISO, Controle.OBTURADOR -> if (c.exposicaoManual) null else naoLibera
            Controle.KELVIN -> when {
                !c.manualPosProcessamento -> naoLibera
                c.calibracao == null -> semCalibracao(t)
                else -> null
            }
            Controle.PRESETS -> if (c.presets.isEmpty()) naoLibera else null
            Controle.FOCO_MANUAL -> when {
                !c.temAf -> focoFixo(t)
                !c.focoManual -> naoLibera
                else -> null
            }
            Controle.ANTI_CINTILACAO -> if (c.modosAntiCintilacao.size > 1) null else naoLibera
            Controle.EV -> if (c.ev) null else naoLibera
            Controle.TOQUE -> if (c.pontoDeInteresse) null else naoLibera
            Controle.TRAVA_EXPOSICAO -> if (c.travaAe || c.exposicaoManual) null else naoLibera
            Controle.TRAVA_BALANCO -> if (c.travaAwb || c.manualPosProcessamento) null else naoLibera
            Controle.TRAVA_FOCO -> if (c.temAf) null else focoFixo(t)
        }
    }

    /**
     * Um grupo em que nada se aplica **vira uma linha só** (§3.5). No Android, ISO e obturador andam
     * juntos (os dois são o `MANUAL_SENSOR`): sem ele, a aba mostra só esta linha, com os dois nomes do
     * §3.5 ligados por "e".
     */
    fun limiteDaAbaIsoEObturador(t: Textos, c: CapacidadesDaCamera): String? =
        if (c.exposicaoManual) null else t.s(R.string.cam_nao_libera_iso_e_obturador)

    // --- §3.6 o pedido contra o lido -------------------------------------------------------------

    /** O pedido e o lido divergem por mais de um passo: ISO e obturador em terços de stop. */
    fun divergeEmStops(pedido: Double, lido: Double): Boolean =
        pedido > 0 && lido > 0 && abs(ln(lido / pedido) / ln(2.0)) > 1.0 / 3.0 + 1e-6

    /** No Kelvin, o passo é o do deslizante (100 K). */
    fun divergeEmKelvin(pedido: Int, lido: Int): Boolean = abs(pedido - lido) > AjusteDaCamera.KELVIN_PASSO

    /**
     * A divergência só aparece depois de **2 s** seguidos (§3.6): um quadro de transição não acende a
     * linha. Um vigia por controle.
     */
    class VigiaDaDivergencia(private val prazoMs: Long = 2_000L) {
        private var desdeMs: Long? = null

        /** Devolve `true` quando a divergência já dura o prazo. */
        fun observar(agoraMs: Long, diverge: Boolean): Boolean {
            if (!diverge) {
                desdeMs = null
                return false
            }
            val d = desdeMs ?: agoraMs.also { desdeMs = it }
            return agoraMs - d >= prazoMs
        }
    }

    /**
     * **Abrir no automático e lembrar o último manual** (decisão de produto, 07/10). Antes, o registro
     * guardado era reaplicado a cada abertura, e uma câmera deixada em manual (ISO e obturador fixos,
     * Kelvin, foco travado) abria escura no dia seguinte: o S24 das provas do R9, medido em 07/10.
     *
     * - [naAbertura]: a câmera abre sempre no padrão (tudo automático), seja qual for o guardado.
     * - [aGravar]: só um registro diferente do padrão vira "meus ajustes"; voltar ao automático não
     *   apaga a lembrança.
     * - [ofereceMeusAjustes]: o painel mostra "Usar meus ajustes" quando há lembrança diferente do que
     *   está valendo.
     */
    object MeusAjustes {
        fun naAbertura(): AjusteDaCamera = AjusteDaCamera()
        fun aGravar(corrente: AjusteDaCamera): AjusteDaCamera? = corrente.takeUnless { it.ehPadrao }
        fun ofereceMeusAjustes(lembrado: AjusteDaCamera?, corrente: AjusteDaCamera): Boolean =
            lembrado != null && !lembrado.ehPadrao && lembrado != corrente
    }

    /**
     * **O piso da faixa de fps do automático** (§3.1, "pouca luz"): o menor `lower` das faixas que a
     * câmera anuncia com `upper == fps`, preferindo os que não descem da metade do fps (nem de
     * [PISO_MINIMO_FPS]). Sem faixa
     * variável, o próprio [fps] (a faixa fixa de antes).
     *
     * **Por que existe** (medido em 06/10 no tablet, sala escura): sem pedido, o CameraX deixa o modelo
     * de gravação do HAL escolher, e ele escolhe `[30,30]`. O AE fica preso a 33 ms com o ISO no teto
     * (3250), enquanto a câmera nativa, na mesma cena, pedia `[15,30]` e expunha 100 ms. A imagem do
     * Quall recebia um terço da luz. A troca é a do app nativo: no escuro, menos quadros e imagem clara.
     * Quem quer o fps cheio passa a exposição a Manual, e a tela avisa ([VigiaDaPoucaLuz]).
     *
     * As faixas são pares `(lower, upper)`, e não `android.util.Range`, para o teste rodar na JVM.
     */
    /**
     * **O fps que a câmera alcança**: o pedido, se alguma faixa chega a ele; senão o maior teto anunciado.
     * Sem faixas lidas, o pedido.
     *
     * **Por que existe** (A07, 06/10): o A07 não faz 60 fps em faixa nenhuma (`[5,30]`, `[10,30]`...). Com o
     * cardápio em 60, pedia-se `[60,60]`. O CameraX recuava para `[30,30]` **fixo** e ainda escolhia 720p,
     * à procura de um tamanho que fizesse 60. A imagem nascia escura já na espera do PIN. Pedindo até o teto
     * que ela alcança, a faixa variável volta (`[5,30]`) e o tamanho volta a 1080p.
     */
    fun tetoAlcancavel(faixas: List<Pair<Int, Int>>, fps: Int): Int {
        val maior = faixas.maxOfOrNull { it.second } ?: return fps
        return if (maior >= fps) fps else maior
    }

    fun pisoDoAutomatico(faixas: List<Pair<Int, Int>>, fps: Int): Int {
        val variaveis = faixas.filter { it.second == fps && it.first in 1 until fps }.map { it.first }
        val preferido = maxOf(PISO_MINIMO_FPS, fps / 2)
        return variaveis.filter { it >= preferido }.minOrNull() ?: variaveis.maxOrNull() ?: fps
    }

    /**
     * O piso preferido é a **metade do fps**, e nunca abaixo disto: a perda de fluidez fica em 1 stop de
     * luz a mais (no iPad, com o piso em 10, o AE da Apple foi a 15 fps com ISO baixo numa sala só meio
     * escura). Uma faixa que desce mais só entra se for a única (o A07 só anuncia `[5,30]`).
     */
    const val PISO_MINIMO_FPS = 10

    /**
     * **A pouca luz baixou o fps** (§3.1): com a exposição em Auto, o quadro saiu mais longo que 1/fps
     * (mais 15 %, a folga do arredondamento do HAL). Acende depois de 1 s seguido e apaga depois de 2 s
     * seguidos de volta, para não piscar na transição. Devolve o fps de agora enquanto acesa, ou `null`.
     */
    class VigiaDaPoucaLuz(private val acenderMs: Long = 1_000L, private val apagarMs: Long = 2_000L) {
        private var desdeMs: Long? = null
        private var acesa = false

        fun observar(agoraMs: Long, auto: Boolean, duracaoDoQuadroNs: Long?, fps: Int): Int? {
            val teto = 1_000_000_000.0 / fps.coerceAtLeast(1)
            val lento = auto && duracaoDoQuadroNs != null && duracaoDoQuadroNs > teto * 1.15
            if (lento != acesa) {
                val d = desdeMs ?: agoraMs.also { desdeMs = it }
                if (agoraMs - d >= (if (lento) acenderMs else apagarMs)) {
                    acesa = lento
                    desdeMs = null
                }
            } else {
                desdeMs = null
            }
            if (!acesa || duracaoDoQuadroNs == null) return null
            return Math.round(1_000_000_000.0 / duracaoDoQuadroNs).toInt().coerceIn(1, fps)
        }
    }

    /**
     * "Pouca luz: 15 fps para clarear a imagem. Para 30 fps, use a exposição manual na engrenagem." Sem
     * exposição manual (o tablet, LIMITED), o conselho é a luz do ambiente: o Manual estaria apagado.
     */
    fun textoDaPoucaLuz(t: Textos, fpsAgora: Int, fps: Int, temManual: Boolean): String =
        t.s(if (temManual) R.string.cam_pouca_luz else R.string.cam_pouca_luz_sem_manual, fpsAgora, fps)

    /**
     * **A cadência dos envios** (§2.2): no máximo um a cada [intervaloMs]; o último valor vence, porque
     * quem envia lê o registro na hora de enviar. Devolve quanto esperar antes do próximo envio.
     */
    class Cadencia(private val intervaloMs: Long = INTERVALO_DOS_ENVIOS_MS) {
        private var ultimoMs: Long? = null

        fun atraso(agoraMs: Long): Long {
            val u = ultimoMs ?: return 0
            return (intervaloMs - (agoraMs - u)).coerceAtLeast(0)
        }

        fun enviou(agoraMs: Long) {
            ultimoMs = agoraMs
        }
    }
}
