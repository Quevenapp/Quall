package com.quall.android.capture

import com.quall.android.teleprompter.JsonSimples

/**
 * **O ajuste de uma câmera** (R9, `docs/controles-de-camera.md` §2): um registro por câmera, guardado
 * pelo `cameraId` em SharedPreferences `quall-camera-ajustes`, com o JSON deste arquivo. A frontal tem
 * um registro só, que vale para a câmera comum e para a R5 (mesma câmera, mesma luz).
 *
 * Os nomes dos campos e os valores são **literais da especificação** (camelCase no Kotlin e no JSON).
 * O ponto de toque não mora aqui (§4.4): ele vive só enquanto a câmera está aberta.
 *
 * Puro, sem tipo do Android: o leitor é o [JsonSimples] do teleprompter, e o escritor é à mão, porque
 * o registro é plano.
 */
data class AjusteDaCamera(
    val exposicao: Exposicao = Exposicao.AUTO,
    /** Em EV. Na hora de aplicar é arredondado ao passo da câmera (§3.3). */
    val ev: Double = 0.0,
    /** Só vale com [exposicao] = auto. */
    val travaExposicao: Boolean = false,
    /** Os valores **lidos** da câmera no instante de travar (§2.1). */
    val travaIso: Int? = null,
    val travaObturadorNs: Long? = null,
    /** Só vale com [exposicao] = manual; nasce do lido ao passar a manual. */
    val iso: Int? = null,
    val obturadorNs: Long? = null,
    val antiCintilacao: AntiCintilacao = AntiCintilacao.AUTO,
    val balanco: Balanco = Balanco.AUTO,
    /** 2000 a 10000, de 100 em 100. Só vale com [balanco] = kelvin. */
    val kelvin: Int? = null,
    /** Só vale com [balanco] = auto. */
    val travaBalanco: Boolean = false,
    /** Os ganhos RGGB **lidos** no instante de travar o balanço (§2.1). */
    val travaGanhos: List<Double>? = null,
    val foco: Foco = Foco.AUTO,
    /** 0,0 (longe) a 1,0 (o mais perto que a lente chega). Vale com manual e guarda a lida ao travar. */
    val focoPosicao: Double? = null,
) {
    enum class Exposicao(val json: String) { AUTO("auto"), MANUAL("manual") }

    enum class AntiCintilacao(val json: String) { AUTO("auto"), HZ50("50"), HZ60("60"), DESLIGADA("desligada") }

    enum class Balanco(val json: String) {
        AUTO("auto"), INCANDESCENTE("incandescente"), FLUORESCENTE("fluorescente"),
        LUZ_DO_DIA("luzDoDia"), NUBLADO("nublado"), KELVIN("kelvin"),
    }

    enum class Foco(val json: String) { AUTO("auto"), TRAVADO("travado"), MANUAL("manual") }

    /** O registro é o padrão da tabela do §2 ("Restaurar automático" volta a ele). */
    val ehPadrao: Boolean get() = this == AjusteDaCamera()

    fun paraJson(): String {
        val partes = ArrayList<String>()
        fun txt(k: String, v: String) = partes.add("\"$k\":\"$v\"")
        fun num(k: String, v: Number?) = partes.add("\"$k\":" + (v?.let { numero(it) } ?: "null"))
        txt("exposicao", exposicao.json)
        num("ev", ev)
        partes.add("\"travaExposicao\":$travaExposicao")
        num("travaIso", travaIso)
        num("travaObturadorNs", travaObturadorNs)
        num("iso", iso)
        num("obturadorNs", obturadorNs)
        txt("antiCintilacao", antiCintilacao.json)
        txt("balanco", balanco.json)
        num("kelvin", kelvin)
        partes.add("\"travaBalanco\":$travaBalanco")
        partes.add("\"travaGanhos\":" + (travaGanhos?.joinToString(",", "[", "]") { numero(it) } ?: "null"))
        txt("foco", foco.json)
        num("focoPosicao", focoPosicao)
        return partes.joinToString(",", "{", "}")
    }

    companion object {
        const val KELVIN_MIN = 2000
        const val KELVIN_MAX = 10000
        const val KELVIN_PASSO = 100

        private fun numero(v: Number): String = when (v) {
            is Int, is Long -> v.toString()
            else -> {
                val d = v.toDouble()
                if (d == Math.rint(d) && Math.abs(d) < 1e15) d.toLong().toString()
                else java.math.BigDecimal.valueOf(d).stripTrailingZeros().toPlainString()
            }
        }

        /**
         * Lê o JSON do registro. Um campo que falta, ou com valor que não se reconhece, fica no padrão:
         * uma versão futura que acrescente um valor não apaga o resto do ajuste. `null` só se o texto
         * não for um objeto JSON.
         */
        fun deJson(texto: String?): AjusteDaCamera? {
            if (texto.isNullOrBlank()) return null
            return deMapa(JsonSimples.objeto(texto) ?: return null)
        }

        /**
         * O registro de um objeto JSON já lido (o `"ajuste"` do estado do receptor, R9b): as mesmas regras
         * de [deJson]. O registro de outra plataforma (o Mac grava cinco campos, o iOS e o Windows omitem
         * o nulo) vira o padrão no que falta.
         */
        fun deMapa(o: Map<String, Any?>): AjusteDaCamera {
            fun d(k: String): Double? = (o[k] as? Double)?.takeIf { it.isFinite() }
            fun b(k: String): Boolean = o[k] as? Boolean ?: false
            fun s(k: String): String? = o[k] as? String
            val p = AjusteDaCamera()
            return AjusteDaCamera(
                exposicao = Exposicao.entries.firstOrNull { it.json == s("exposicao") } ?: p.exposicao,
                ev = d("ev") ?: p.ev,
                travaExposicao = b("travaExposicao"),
                travaIso = d("travaIso")?.toInt(),
                travaObturadorNs = d("travaObturadorNs")?.toLong(),
                iso = d("iso")?.toInt(),
                obturadorNs = d("obturadorNs")?.toLong(),
                antiCintilacao = AntiCintilacao.entries.firstOrNull { it.json == s("antiCintilacao") } ?: p.antiCintilacao,
                balanco = Balanco.entries.firstOrNull { it.json == s("balanco") } ?: p.balanco,
                kelvin = d("kelvin")?.toInt(),
                travaBalanco = b("travaBalanco"),
                travaGanhos = (o["travaGanhos"] as? List<*>)?.mapNotNull { (it as? Double)?.takeIf { v -> v.isFinite() } }
                    ?.takeIf { it.size == 4 },
                foco = Foco.entries.firstOrNull { it.json == s("foco") } ?: p.foco,
                focoPosicao = d("focoPosicao"),
            )
        }
    }
}
