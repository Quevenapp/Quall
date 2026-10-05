package com.quall.android.capture

import com.quall.android.teleprompter.JsonSimples

/**
 * **O controle remoto da câmera, do lado de quem filma** (R9b, `docs/controle-remoto-da-camera.md`):
 * as partes puras — as capacidades que o filmador publica (§3.2), o pedido que chega da fila do
 * núcleo (§6) e o que se aplica dele, e o lido (§3.3). Sem tipo do Android, provadas na JVM; quem as
 * liga à câmera é o [FilmadorDaCamera].
 */

/** O escritor de JSON plano das mensagens da câmera: números inteiros sem `.0` (contrato §3). */
internal object JsonDaCamera {
    fun texto(s: String): String {
        val b = StringBuilder("\"")
        for (c in s) {
            when {
                c == '"' -> b.append("\\\"")
                c == '\\' -> b.append("\\\\")
                c < ' ' -> b.append(String.format(java.util.Locale.ROOT, "\\u%04x", c.code))
                else -> b.append(c)
            }
        }
        return b.append('"').toString()
    }

    fun num(v: Number): String = when (v) {
        is Int, is Long -> v.toString()
        else -> {
            val d = v.toDouble()
            if (d == Math.rint(d) && Math.abs(d) < 1e15) d.toLong().toString()
            else java.math.BigDecimal.valueOf(d).stripTrailingZeros().toPlainString()
        }
    }

    /** Um objeto com os pares na ordem dada; os valores já são JSON. */
    fun objeto(pares: List<Pair<String, String>>): String =
        pares.joinToString(",", "{", "}") { (k, v) -> texto(k) + ":" + v }
}

/**
 * **As capacidades que o filmador Android publica** (contrato §3.2), do mesmo cálculo que monta o
 * painel do R9 ([CapacidadesDaCamera] e [RegrasDosControles.limite]): um descritor por campo do ajuste
 * que um receptor pode pedir, e em `limites` o **código** de quem limita cada controle que a câmera
 * não oferece.
 *
 * - **`"inteiro":true` em `iso`, `kelvin` e `obturadorNs`**: o registro do Android lê tudo como
 *   `Double` e trunca com `toInt()` ([AjusteDaCamera.deJson]); sem isto, `800.7` viraria 800 calado.
 * - **Sem `MANUAL_SENSOR`** (o tablet): sem `exposicao` manual, sem `iso` nem `obturadorNs`, e
 *   `limites` com `fabricante` neles (e em `focoPosicao`, que também depende do sensor manual).
 * - **O teto do obturador segue o fps** (R9 §3.1): `max` é `min(1/fps, o máximo da câmera)`. Com o fps
 *   novo, o JSON muda e a casca chama `set_capabilities` (só o `cap` sobe).
 * - `focoPosicao` leva `"calibrado"` = as dioptrias da posição 1 (o mais perto) quando a lente publica
 *   calibração (`APPROXIMATE`/`CALIBRATED`): é a dica para o receptor falar em metros (R9 §1). Sem
 *   calibração, a chave não vai.
 */
object CapacidadesRemotas {
    const val FABRICANTE = "fabricante"
    const val FOCO_FIXO = "foco_fixo"
    const val SEM_CALIBRACAO = "sem_calibracao"

    /** Os valores de `antiCintilacao` no fio, com o modo da Camera2 de cada um (`auto` é o padrão). */
    private val ANTI = listOf(
        "50" to Camera2Valores.ANTIBANDING_50HZ,
        "60" to Camera2Valores.ANTIBANDING_60HZ,
        "desligada" to Camera2Valores.ANTIBANDING_OFF,
    )

    /** O núcleo recusa o `set_camera` inteiro com um `nomeDaCamera` acima de 64 bytes de UTF-8. */
    const val TETO_DO_NOME = 64

    /** [s] cortado em [teto] bytes de UTF-8, sem partir um caractere. */
    fun cortarEmBytes(s: String, teto: Int): String {
        var fim = s.length
        while (fim > 0 && s.substring(0, fim).toByteArray(Charsets.UTF_8).size > teto) {
            fim--
            if (fim > 0 && Character.isLowSurrogate(s[fim]) && Character.isHighSurrogate(s[fim - 1])) fim--
        }
        return s.substring(0, fim)
    }

    fun json(c: CapacidadesDaCamera, fps: Int, nomeDaCamera: String? = null): String {
        val ctl = ArrayList<Pair<String, String>>()
        val lim = ArrayList<Pair<String, String>>()
        val j = JsonDaCamera
        fun valores(vararg v: String) = "{\"valores\":" + v.joinToString(",", "[", "]") { j.texto(it) } + "}"
        fun faixa(min: Number, max: Number, passo: Number? = null, inteiro: Boolean = false, extras: List<Pair<String, String>> = emptyList()): String {
            val p = arrayListOf("min" to j.num(min), "max" to j.num(max))
            if (passo != null) p.add("passo" to j.num(passo))
            if (inteiro) p.add("inteiro" to "true")
            p.addAll(extras)
            return j.objeto(p)
        }
        fun limite(campo: String, codigo: String) = lim.add(campo to j.texto(codigo))

        // --- a exposição ---
        if (c.exposicaoManual) ctl.add("exposicao" to valores("auto", "manual")) else limite("exposicao", FABRICANTE)
        if (c.ev) {
            // Do índice, e não somando passos: `-2 + 40 × 0,1` passaria do máximo por um bit.
            val passo = c.evPassoNum.toDouble() / c.evPassoDen
            ctl.add("ev" to faixa(EscalasDaCamera.evDoIndice(c.evIndiceMin, c.evPassoNum, c.evPassoDen),
                EscalasDaCamera.evDoIndice(c.evIndiceMax, c.evPassoNum, c.evPassoDen), passo))
        } else {
            limite("ev", FABRICANTE)
        }
        if (c.travaAe || c.exposicaoManual) ctl.add("travaExposicao" to "{}") else limite("travaExposicao", FABRICANTE)
        if (c.modosAntiCintilacao.size > 1) {
            val v = listOf("auto") + ANTI.filter { it.second in c.modosAntiCintilacao }.map { it.first }
            ctl.add("antiCintilacao" to valores(*v.toTypedArray()))
        } else {
            limite("antiCintilacao", FABRICANTE)
        }
        if (c.exposicaoManual) {
            val extras = c.isoMaxAnalogico?.takeIf { it > 0 }?.let { listOf("analogicoMax" to j.num(it)) }.orEmpty()
            ctl.add("iso" to faixa(c.isoMin, c.isoMax, inteiro = true, extras = extras))
            val teto = EscalasDaCamera.tetoDoObturadorNs(fps, c.exposicaoMaxNs).coerceAtLeast(c.exposicaoMinNs)
            ctl.add("obturadorNs" to faixa(c.exposicaoMinNs, teto, inteiro = true))
        } else {
            limite("iso", FABRICANTE)
            limite("obturadorNs", FABRICANTE)
        }

        // --- o balanço ---
        val balancos = listOf("auto") + c.presets.map { it.json } + (if (c.kelvin) listOf("kelvin") else emptyList())
        ctl.add("balanco" to valores(*balancos.toTypedArray()))
        if (c.kelvin) {
            ctl.add("kelvin" to faixa(AjusteDaCamera.KELVIN_MIN, AjusteDaCamera.KELVIN_MAX, AjusteDaCamera.KELVIN_PASSO, inteiro = true))
        } else {
            limite("kelvin", if (c.manualPosProcessamento && c.calibracao == null) SEM_CALIBRACAO else FABRICANTE)
        }
        if (c.travaAwb || c.manualPosProcessamento) ctl.add("travaBalanco" to "{}") else limite("travaBalanco", FABRICANTE)

        // --- o foco ---
        if (c.temAf) {
            ctl.add("foco" to if (c.focoManual) valores("auto", "travado", "manual") else valores("auto", "travado"))
            if (c.focoManual) {
                val extras = if (c.focoCalibrado) listOf("calibrado" to j.num(c.focoMinimoDioptrias.toDouble())) else emptyList()
                ctl.add("focoPosicao" to faixa(0, 1, 0.01, extras = extras))
            } else {
                limite("focoPosicao", FABRICANTE)
            }
        } else {
            limite("foco", FOCO_FIXO)
            limite("focoPosicao", FOCO_FIXO)
        }
        if (c.pontoDeInteresse) ctl.add("toque" to "{}") else limite("toque", FABRICANTE)

        val raiz = arrayListOf("plataforma" to j.texto("android"))
        nomeDaCamera?.takeIf { it.isNotBlank() }?.let { raiz.add("nomeDaCamera" to j.texto(cortarEmBytes(it, TETO_DO_NOME))) }
        raiz.add("controles" to j.objeto(ctl))
        raiz.add("limites" to j.objeto(lim))
        return j.objeto(raiz)
    }
}

/**
 * **Um pedido aceito**, como a fila do núcleo o entrega (`quall_camera_host_next_request`, §6):
 * `{"n":5,"autor":"OBS no Dell","autor_id":"…","ajuste":{…},"restaurar":false,"toque":null}`.
 */
data class PedidoRemoto(
    val n: Long,
    val autor: String,
    /** O ajuste **parcial**: só os campos que a pessoa mexeu, como vieram (`Double`, `String`, `Boolean`). */
    val ajuste: Map<String, Any?>,
    val restaurar: Boolean,
    val toque: Toque?,
) {
    /** `x` e `y` de 0 a 1 **no quadro decodificado** (o que a rede leva), e o toque longo. */
    data class Toque(val x: Double, val y: Double, val longo: Boolean)

    companion object {
        /** `null` se o texto não é um pedido (sem `n`). */
        fun ler(json: String): PedidoRemoto? {
            val o = JsonSimples.objeto(json) ?: return null
            val n = (o["n"] as? Double)?.toLong()?.takeIf { it > 0 } ?: return null
            @Suppress("UNCHECKED_CAST")
            val ajuste = (o["ajuste"] as? Map<String, Any?>).orEmpty()
            val toque = (o["toque"] as? Map<*, *>)?.let { t ->
                val x = t["x"] as? Double
                val y = t["y"] as? Double
                if (x == null || y == null) null else Toque(x, y, t["longo"] as? Boolean ?: false)
            }
            return PedidoRemoto(n, o["autor"] as? String ?: "", ajuste, o["restaurar"] as? Boolean ?: false, toque)
        }
    }
}

/**
 * **O que se aplica de um pedido remoto** (contrato §6, a ordem do achado B3), puro: `restaurar` → os
 * modos (`exposicao`, `balanco`, `foco`) → as travas → os valores (`ev`, `iso`, `obturadorNs`,
 * `kelvin`, `focoPosicao`, `antiCintilacao`). O `toque` é da casca, depois.
 *
 * **Partir do lido só no que o pedido não trouxe**: `{"exposicao":"manual","iso":800}` fica com 800, e o
 * obturador parte do lido — é o "Passar para Manual" do painel ([RegrasDosControles.passarParaManual]),
 * com o pedido por cima. Sem lido o Android não fica sem valor: o "Passar para Manual" já tem o recurso
 * do guardado e do mínimo da câmera, o mesmo do painel local.
 *
 * Os cortes são os do R9 §2.2, no registro: o EV ao passo da câmera, o ISO e o obturador na faixa, o
 * Kelvin a 100 e o foco a 0,01. O teto de 1/fps fica para o plano, como no painel local (o registro
 * guarda o pedido, a câmera recebe o cortado).
 *
 * - **Sem lido** (a câmera sem `READ_SENSOR_SETTINGS`), um "Manual" que não traz ISO e obturador, e que
 *   o registro também não tem, é recusado (`null` → `nao_aplicado`, contrato §6): não se inventa um
 *   manual vazio.
 * - **Uma trava ligada no mesmo pedido que troca o modo** (`{"exposicao":"auto","travaExposicao":true}`
 *   vindo de Manual) não grava o lido de agora, que é do modo anterior: os valores da trava ficam vazios
 *   e a câmera trava depois de convergir (R9 §2.1), como a trava sem valores lidos.
 */
object RegrasDoPedidoRemoto {

    /** O que a câmera diz agora, para o que parte do lido. */
    data class Lidos(
        val iso: Int? = null,
        val obturadorNs: Long? = null,
        val ganhos: List<Double>? = null,
        val focoPosicao: Double? = null,
        val kelvin: Int? = null,
    )

    fun aplicar(atual: AjusteDaCamera, p: PedidoRemoto, lidos: Lidos, c: CapacidadesDaCamera, fps: Int): AjusteDaCamera? {
        val q = p.ajuste
        fun txt(k: String): String? = q[k] as? String
        fun num(k: String): Double? = (q[k] as? Double)?.takeIf { it.isFinite() }
        fun bool(k: String): Boolean? = q[k] as? Boolean

        // 1. restaurar
        var a = if (p.restaurar) AjusteDaCamera() else atual

        // 2. os modos
        val exposicaoAntes = a.exposicao
        val balancoAntes = a.balanco
        when (txt("exposicao")) {
            AjusteDaCamera.Exposicao.MANUAL.json -> if (a.exposicao != AjusteDaCamera.Exposicao.MANUAL || a.iso == null || a.obturadorNs == null) {
                val semLido = (lidos.iso == null && a.iso == null && num("iso") == null) ||
                    (lidos.obturadorNs == null && a.obturadorNs == null && num("obturadorNs") == null)
                if (semLido) return null
                a = RegrasDosControles.passarParaManual(a, lidos.iso, lidos.obturadorNs, c, fps)
            }
            AjusteDaCamera.Exposicao.AUTO.json -> a = a.copy(exposicao = AjusteDaCamera.Exposicao.AUTO)
        }
        AjusteDaCamera.Balanco.entries.firstOrNull { it.json == txt("balanco") }?.let { b ->
            a = if (b == AjusteDaCamera.Balanco.KELVIN) {
                // O Kelvin pedido entra nos valores; aqui só o ponto de partida, se o pedido não trouxe.
                a.copy(balanco = b, kelvin = a.kelvin ?: lidos.kelvin?.let { EscalasDaCamera.cortarKelvin(it) } ?: 5500,
                    travaBalanco = false, travaGanhos = null)
            } else {
                a.copy(balanco = b, travaBalanco = if (b == AjusteDaCamera.Balanco.AUTO) a.travaBalanco else false,
                    travaGanhos = if (b == AjusteDaCamera.Balanco.AUTO) a.travaGanhos else null)
            }
        }
        AjusteDaCamera.Foco.entries.firstOrNull { it.json == txt("foco") }?.let { f ->
            a = when (f) {
                AjusteDaCamera.Foco.AUTO -> a.copy(foco = f)
                AjusteDaCamera.Foco.TRAVADO -> a.copy(foco = f, focoPosicao = lidos.focoPosicao)
                AjusteDaCamera.Foco.MANUAL -> a.copy(foco = f, focoPosicao = a.focoPosicao ?: lidos.focoPosicao ?: 0.0)
            }
        }

        // 3. as travas (ligar grava o lido agora, como o painel; §2.1) — o lido só vale se o modo não mudou
        val exposicaoMudou = a.exposicao != exposicaoAntes || p.restaurar
        val balancoMudou = a.balanco != balancoAntes || p.restaurar
        bool("travaExposicao")?.let { ligar ->
            a = if (ligar) {
                RegrasDosControles.comValoresDaTrava(a.copy(travaExposicao = true, travaIso = null, travaObturadorNs = null),
                    lidos.iso.takeIf { !exposicaoMudou }, lidos.obturadorNs.takeIf { !exposicaoMudou }, null, null)
            } else {
                a.copy(travaExposicao = false, travaIso = null, travaObturadorNs = null)
            }
        }
        bool("travaBalanco")?.let { ligar ->
            a = if (ligar) {
                RegrasDosControles.comValoresDaTrava(a.copy(travaBalanco = true, travaGanhos = null), null, null,
                    lidos.ganhos.takeIf { c.manualPosProcessamento && !balancoMudou }, null)
            } else {
                a.copy(travaBalanco = false, travaGanhos = null)
            }
        }

        // 4. os valores
        num("ev")?.let { ev ->
            val i = EscalasDaCamera.indiceDoEv(ev, c.evPassoNum, c.evPassoDen, c.evIndiceMin, c.evIndiceMax)
            a = a.copy(ev = EscalasDaCamera.evDoIndice(i, c.evPassoNum, c.evPassoDen))
        }
        num("iso")?.let { a = a.copy(iso = EscalasDaCamera.cortarIso(Math.round(it).toInt(), c.isoMin, c.isoMax)) }
        num("obturadorNs")?.let {
            a = a.copy(obturadorNs = Math.round(it).coerceIn(c.exposicaoMinNs, maxOf(c.exposicaoMinNs, c.exposicaoMaxNs)))
        }
        num("kelvin")?.let { a = a.copy(kelvin = EscalasDaCamera.cortarKelvin(Math.round(it).toInt())) }
        num("focoPosicao")?.let { a = a.copy(focoPosicao = EscalasDaCamera.cortarFoco(it)) }
        AjusteDaCamera.AntiCintilacao.entries.firstOrNull { it.json == txt("antiCintilacao") }?.let { a = a.copy(antiCintilacao = it) }
        return a
    }

    /**
     * **O lido** (contrato §3.3, R9 §3.6): só o que o Android lê, e `divergentes`, os campos em que a
     * linha "A câmera usou {lido} em vez de {pedido}" está acesa.
     */
    fun lidoJson(iso: Int?, obturadorNs: Long?, kelvin: Int?, abertura: Float?, focoPosicao: Double?, divergentes: List<String>): String {
        val j = JsonDaCamera
        val p = ArrayList<Pair<String, String>>()
        iso?.let { p.add("iso" to j.num(it)) }
        obturadorNs?.let { p.add("obturadorNs" to j.num(it)) }
        kelvin?.let { p.add("kelvin" to j.num(it)) }
        abertura?.takeIf { it > 0f }?.let { p.add("abertura" to j.num(Math.round(it * 100) / 100.0)) }
        focoPosicao?.let { p.add("focoPosicao" to j.num(Math.round(it * 100) / 100.0)) }
        p.add("divergentes" to divergentes.joinToString(",", "[", "]") { j.texto(it) })
        return j.objeto(p)
    }
}
