package com.quall.android.ui

import androidx.annotation.StringRes
import com.quall.android.R
import com.quall.android.capture.AjusteDaCamera
import com.quall.android.capture.AjusteDaCamera.AntiCintilacao
import com.quall.android.capture.AjusteDaCamera.Balanco
import com.quall.android.capture.AjusteDaCamera.Foco
import com.quall.android.capture.Camera2Valores
import com.quall.android.capture.CapacidadesDaCamera
import com.quall.android.capture.EscalasDaCamera
import com.quall.android.capture.RegrasDosControles
import com.quall.android.capture.RegrasDosControles.Controle
import com.quall.android.core.Textos
import kotlin.math.roundToInt

/**
 * **O que o painel "Ajustes da câmera" pode oferecer** (R9 §4, R9b §12), pura e igual para as duas
 * fontes: a câmera **deste** aparelho ([deLocal], das [CapacidadesDaCamera], como o painel sempre fez) e
 * a câmera **do outro lado** ([deRemota], das capacidades que o filmador publicou, contrato §3.2). O
 * [PainelDaCamera] desenha só daqui: os degraus de cada deslizante, o que está apagado, e a frase de quem
 * limita, já no idioma da tela.
 *
 * As unidades do Windows (contrato §3.2, achado I7) chegam pelo descritor: `"unidade":"brilho"` no `ev`
 * (o número na tela é `origem + valor`) e `"unidade":"ganho"` no `iso`; com elas a tela diz "Brilho" e
 * "Ganho", nunca "EV" nem "ISO". `"escala":"log2"` no obturador vira os degraus `1/2^k`.
 */
data class OfertaDoPainel(
    /** "Manual" na exposição (com ISO e obturador). */
    val exposicaoManual: Boolean,
    /** Os degraus do deslizante de compensação, em unidades do registro (`ev`); vazio = sem compensação. */
    val evs: List<Double>,
    /** Com o brilho do Windows, o padrão do driver: a tela mostra `origem + valor`. `null` = EV. */
    val origemDoBrilho: Double?,
    val travaExposicao: Boolean,
    /** As opções de anti-cintilação que a câmera tem (com `AUTO`); vazio = nenhuma. */
    val antiCintilacao: Set<AntiCintilacao>,
    /** Os degraus do ISO (ou do ganho). */
    val isos: List<Int>,
    val isoAnalogicoMax: Int?,
    val isoEhGanho: Boolean,
    /** Os degraus do obturador, como denominadores de `1/N s`. */
    val fracoes: List<Int>,
    /** Os balanços da grade que a câmera tem (`AUTO` sempre). */
    val balancos: Set<Balanco>,
    val kelvinMin: Int,
    val kelvinMax: Int,
    val kelvinPasso: Int,
    val travaBalanco: Boolean,
    /** Os modos de foco; vazio = a lente não foca (foco fixo, ou sem foco nenhum). */
    val focos: Set<Foco>,
    /** As dioptrias da posição 1 do foco, quando a lente é calibrada: a tela fala em metros. */
    val dioptriasDoFoco: Float?,
    val toque: Boolean,
    /** A frase de quem limita, por controle apagado (R9 §3.5). */
    val limites: Map<Controle, String>,
    /** A linha da aba "ISO e obturador" quando nada dela se aplica (um grupo vazio vira uma linha só). */
    val limiteDaAbaIsoEObturador: String?,
    /** A linha da aba "Foco" quando a lente não foca. */
    val limiteDoFoco: String?,
) {
    val ev: Boolean get() = evs.size > 1
    val kelvin: Boolean get() = Balanco.KELVIN in balancos
    val focoManual: Boolean get() = Foco.MANUAL in focos
    fun limite(c: Controle): String? = limites[c]

    /** O título do deslizante de compensação: "Compensação", ou "Brilho" no Windows. */
    fun tituloDoEv(t: Textos): String = t.s(if (origemDoBrilho != null) R.string.cam_brilho else R.string.cam_compensacao)

    fun textoDoEv(t: Textos, ev: Double): String =
        origemDoBrilho?.let { (it + ev).roundToInt().toString() } ?: EscalasDaCamera.textoDoEv(t, ev)

    fun tituloDoIso(t: Textos): String = if (isoEhGanho) t.s(R.string.cam_ganho) else "ISO"

    fun textoDoIso(iso: Int): String = if (isoEhGanho) iso.toString() else EscalasDaCamera.textoDoIso(iso)

    companion object {
        /** O nome de cada controle dentro das frases (R9 §3.5: o artigo faz parte do nome). */
        @StringRes
        fun nome(c: Controle): Int = when (c) {
            Controle.ISO -> R.string.cam_nome_iso
            Controle.OBTURADOR -> R.string.cam_nome_obturador
            Controle.KELVIN -> R.string.cam_nome_kelvin
            Controle.PRESETS -> R.string.cam_nome_presets
            Controle.FOCO_MANUAL -> R.string.cam_nome_foco_manual
            Controle.ANTI_CINTILACAO -> R.string.cam_nome_anti_cintilacao
            Controle.EV -> R.string.cam_nome_ev
            Controle.TOQUE -> R.string.cam_nome_toque
            Controle.TRAVA_EXPOSICAO -> R.string.cam_nome_trava_exposicao
            Controle.TRAVA_BALANCO -> R.string.cam_nome_trava_balanco
            Controle.TRAVA_FOCO -> R.string.cam_nome_trava_foco
        }

        /**
         * **A frase de quem limita, do código** (contrato §3.2, a tabela de `limites`). `fabricante` usa a
         * frase inteira do Android por controle (`cam_nao_libera_*`, que já existe); os outros, a frase do
         * código com o nome do controle. Um código que esta build não conhece: "Este aparelho não oferece
         * {controle}.". [nomeRes] troca o nome (o brilho e o ganho do Windows).
         */
        fun frase(t: Textos, codigo: String, c: Controle?, @StringRes nomeRes: Int? = null): String {
            val nome = t.s(nomeRes ?: c?.let { nome(it) } ?: R.string.cam_nome_ajuste)
            return when (codigo) {
                "fabricante" -> if (c != null && nomeRes == null) t.s(c.naoLibera) else t.s(R.string.cam_limite_fabricante, nome)
                "macos" -> t.s(R.string.cam_limite_macos, nome)
                "ios_cintilacao" -> t.s(R.string.cam_limite_ios_cintilacao)
                "camera_nao_oferece" -> t.s(R.string.cam_limite_camera_nao_oferece, nome)
                "foco_fixo" -> t.s(R.string.cam_foco_fixo)
                "sem_calibracao" -> t.s(R.string.cam_sem_calibracao)
                "outro_app" -> t.s(R.string.cam_limite_outro_app)
                else -> t.s(R.string.cam_limite_aparelho_nao_oferece, nome)
            }
        }

        /** O painel da câmera deste aparelho: o mesmo cálculo de sempre ([RegrasDosControles.limite]). */
        fun deLocal(c: CapacidadesDaCamera, fps: Int, t: Textos): OfertaDoPainel {
            val limites = LinkedHashMap<Controle, String>()
            for (k in Controle.entries) RegrasDosControles.limite(t, k, c)?.let { limites[k] = it }
            val anti = linkedSetOf(AntiCintilacao.AUTO).apply {
                if (Camera2Valores.ANTIBANDING_50HZ in c.modosAntiCintilacao) add(AntiCintilacao.HZ50)
                if (Camera2Valores.ANTIBANDING_60HZ in c.modosAntiCintilacao) add(AntiCintilacao.HZ60)
                if (Camera2Valores.ANTIBANDING_OFF in c.modosAntiCintilacao) add(AntiCintilacao.DESLIGADA)
            }.takeIf { limites[Controle.ANTI_CINTILACAO] == null }.orEmpty()
            return OfertaDoPainel(
                exposicaoManual = c.exposicaoManual,
                evs = if (c.ev) (c.evIndiceMin..c.evIndiceMax).map { EscalasDaCamera.evDoIndice(it, c.evPassoNum, c.evPassoDen) } else emptyList(),
                origemDoBrilho = null,
                travaExposicao = limites[Controle.TRAVA_EXPOSICAO] == null,
                antiCintilacao = anti,
                isos = if (c.exposicaoManual) EscalasDaCamera.escalaDoIso(c.isoMin, c.isoMax) else emptyList(),
                isoAnalogicoMax = c.isoMaxAnalogico,
                isoEhGanho = false,
                fracoes = if (c.exposicaoManual) EscalasDaCamera.escalaDoObturador(c.exposicaoMinNs, c.exposicaoMaxNs, fps) else emptyList(),
                balancos = (listOf(Balanco.AUTO) + c.presets + (if (c.kelvin) listOf(Balanco.KELVIN) else emptyList())).toSet(),
                kelvinMin = AjusteDaCamera.KELVIN_MIN,
                kelvinMax = AjusteDaCamera.KELVIN_MAX,
                kelvinPasso = AjusteDaCamera.KELVIN_PASSO,
                travaBalanco = limites[Controle.TRAVA_BALANCO] == null,
                focos = if (!c.temAf) emptySet() else if (c.focoManual) setOf(Foco.AUTO, Foco.TRAVADO, Foco.MANUAL) else setOf(Foco.AUTO, Foco.TRAVADO),
                dioptriasDoFoco = c.focoMinimoDioptrias.takeIf { c.focoCalibrado && it > 0f },
                toque = c.pontoDeInteresse,
                limites = limites,
                limiteDaAbaIsoEObturador = RegrasDosControles.limiteDaAbaIsoEObturador(t, c),
                limiteDoFoco = if (c.temAf) null else RegrasDosControles.focoFixo(t),
            )
        }

        /** Os degraus de um deslizante linear, no máximo [teto] (o passo cresce se precisar). */
        private fun degraus(min: Double, max: Double, passo: Double?, teto: Int = 200): List<Double> {
            if (!(max > min)) return emptyList()
            var p = passo?.takeIf { it > 0 } ?: ((max - min) / 20)
            while ((max - min) / p > teto) p *= 2
            val n = ((max - min) / p + 1e-9).toInt()
            // Do índice (`min + i × passo`) e cortado na faixa: somar passos em `Double` passaria do máximo
            // por um bit, e o núcleo recusaria o pedido da ponta do deslizante.
            val r = (0..n).map { (Math.round((min + it * p) * 1e6) / 1e6).coerceIn(min, max) }.distinct().toMutableList()
            if (r.last() < max - 1e-9) r.add(max)
            return r
        }

        /**
         * **O painel da câmera do outro lado**, das capacidades do contrato §3.2 (o `"capacidades"` do
         * estado do receptor). Só o que veio em `controles` fica vivo; o resto fica apagado com a frase do
         * código que veio em `limites` — ou sem frase, quando o filmador não disse por quê.
         */
        fun deRemota(capacidades: Map<String, Any?>, t: Textos): OfertaDoPainel {
            @Suppress("UNCHECKED_CAST")
            val ctl = (capacidades["controles"] as? Map<String, Any?>).orEmpty()
            @Suppress("UNCHECKED_CAST")
            val lim = (capacidades["limites"] as? Map<String, Any?>).orEmpty()
            fun desc(k: String): Map<*, *>? = ctl[k] as? Map<*, *>
            fun valores(k: String): List<String> = (desc(k)?.get("valores") as? List<*>)?.mapNotNull { it as? String }.orEmpty()
            fun d(m: Map<*, *>?, k: String): Double? = (m?.get(k) as? Double)?.takeIf { it.isFinite() }
            fun cod(k: String): String? = lim[k] as? String

            val evD = desc("ev")
            val brilho = evD?.get("unidade") == "brilho"
            val isoD = desc("iso")
            val ganho = isoD?.get("unidade") == "ganho"
            val obtD = desc("obturadorNs")

            val limites = LinkedHashMap<Controle, String>()
            fun limitar(campo: String, c: Controle, nomeRes: Int? = null) {
                cod(campo)?.let { limites[c] = frase(t, it, c, nomeRes) }
            }
            limitar("ev", Controle.EV)
            limitar("travaExposicao", Controle.TRAVA_EXPOSICAO)
            limitar("antiCintilacao", Controle.ANTI_CINTILACAO)
            limitar("iso", Controle.ISO)
            limitar("obturadorNs", Controle.OBTURADOR)
            limitar("kelvin", Controle.KELVIN)
            limitar("travaBalanco", Controle.TRAVA_BALANCO)
            limitar("focoPosicao", Controle.FOCO_MANUAL)
            limitar("toque", Controle.TOQUE)

            val manual = "manual" in valores("exposicao") && isoD != null && obtD != null
            val evs = evD?.let { m ->
                val min = d(m, "min")
                val max = d(m, "max")
                if (min == null || max == null) emptyList() else degraus(min, max, d(m, "passo"))
            }.orEmpty()

            val isos = isoD?.let { m ->
                val min = d(m, "min")?.roundToInt()
                val max = d(m, "max")?.roundToInt()
                when {
                    min == null || max == null || max < min -> emptyList()
                    ganho -> degraus(min.toDouble(), max.toDouble(), d(m, "passo") ?: 1.0).map { it.roundToInt() }.distinct()
                    else -> EscalasDaCamera.escalaDoIso(min, max)
                }
            }.orEmpty()

            val fracoes = obtD?.let { m ->
                val min = d(m, "min")?.toLong()
                val max = d(m, "max")?.toLong()
                when {
                    min == null || max == null || max < min || max <= 0 -> emptyList()
                    m["escala"] == "log2" -> (0..20).map { 1 shl it }.filter { EscalasDaCamera.nsDaFracao(it) in min..max }
                    // O teto já vem cortado pelo fps do filmador: o "fps" da escala é o do próprio teto.
                    else -> EscalasDaCamera.escalaDoObturador(min, max, (1e9 / max).roundToInt().coerceAtLeast(1))
                }
            }.orEmpty()

            val anti = valores("antiCintilacao").mapNotNull { v -> AntiCintilacao.entries.firstOrNull { it.json == v } }.toSet()
                .let { if (it.isEmpty()) it else it + AntiCintilacao.AUTO }
            val balancos = valores("balanco").mapNotNull { v -> Balanco.entries.firstOrNull { it.json == v } }.toMutableSet()
            balancos.add(Balanco.AUTO)
            val kD = desc("kelvin")
            if (kD == null) balancos.remove(Balanco.KELVIN)
            val focos = valores("foco").mapNotNull { v -> Foco.entries.firstOrNull { it.json == v } }.toMutableSet()
            if (desc("focoPosicao") == null) focos.remove(Foco.MANUAL)
            if (focos.isNotEmpty()) focos.add(Foco.AUTO)

            // O grupo ISO e obturador inteiro de fora vira uma linha só (R9 §3.5), com o código de quem limita.
            val codIso = cod("iso") ?: cod("obturadorNs") ?: cod("exposicao")
            val linhaIso = if (manual) null else when (codIso) {
                null -> null
                "fabricante" -> t.s(R.string.cam_nao_libera_iso_e_obturador)
                else -> frase(t, codIso, null, R.string.cam_nome_iso_e_obturador)
            }
            val linhaFoco = if (focos.isNotEmpty()) null else (cod("foco") ?: cod("focoPosicao"))?.let { frase(t, it, null, R.string.cam_nome_foco) }

            return OfertaDoPainel(
                exposicaoManual = manual,
                evs = evs,
                origemDoBrilho = if (brilho) d(evD, "origem") ?: 0.0 else null,
                travaExposicao = desc("travaExposicao") != null,
                antiCintilacao = anti,
                isos = isos,
                isoAnalogicoMax = d(isoD, "analogicoMax")?.roundToInt(),
                isoEhGanho = ganho,
                fracoes = fracoes,
                balancos = balancos,
                kelvinMin = d(kD, "min")?.roundToInt() ?: AjusteDaCamera.KELVIN_MIN,
                kelvinMax = d(kD, "max")?.roundToInt() ?: AjusteDaCamera.KELVIN_MAX,
                kelvinPasso = d(kD, "passo")?.roundToInt()?.takeIf { it > 0 } ?: AjusteDaCamera.KELVIN_PASSO,
                travaBalanco = desc("travaBalanco") != null,
                focos = focos,
                dioptriasDoFoco = d(desc("focoPosicao"), "calibrado")?.toFloat()?.takeIf { it > 0f },
                toque = desc("toque") != null,
                limites = limites,
                limiteDaAbaIsoEObturador = linhaIso,
                limiteDoFoco = linhaFoco,
            )
        }
    }
}
