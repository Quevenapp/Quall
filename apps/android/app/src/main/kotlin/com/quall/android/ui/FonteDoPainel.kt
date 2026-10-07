package com.quall.android.ui

import com.quall.android.capture.AjusteDaCamera
import com.quall.android.capture.ControlesDaCamera
import com.quall.android.capture.EscalasDaCamera
import com.quall.android.core.Textos
import com.quall.android.receive.CameraRemotaBus
import com.quall.android.capture.JsonDaCamera
import com.quall.android.receive.EstadoDaCameraRemota

/**
 * **De onde o painel "Ajustes da câmera" tira o que mostra e para onde manda o que a pessoa mexe** (R9 e
 * R9b): a câmera deste aparelho ([Local], os [ControlesDaCamera] do dono aberto) ou a câmera do outro lado
 * ([Remota], o estado do receptor no [CameraRemotaBus]). O [PainelDaCamera] é o mesmo nas duas.
 *
 * As ações são **semânticas**, e não "troque o registro": na câmera local cada uma faz o que o painel
 * sempre fez (o "Passar para Manual" parte do lido agora); na remota cada uma vira o pedido parcial do
 * contrato §5 — só os campos mexidos, e o filmador parte do lido dele no resto.
 */
interface FonteDoPainel {
    /** O que oferecer, no idioma de [t]. */
    fun oferta(t: Textos): OfertaDoPainel

    /** O registro à vista (na remota, o aplicado com o pendente por cima). */
    val ajuste: AjusteDaCamera

    /** `false` = tudo apagado, com os valores à vista (a remota em `nao_permitido`). */
    val vivo: Boolean

    /** O ISO e o obturador que de fato foram à câmera, se a fonte sabe (o plano cortado do R9 §2.2). */
    val isoAplicado: Int?
    val obturadorAplicadoNs: Long?

    /** Onde o deslizante do obturador fica quando o registro não tem valor. */
    val obturadorPadraoNs: Long

    /** A linha do alto (o lido) e a linha de aviso (a divergência, a recusa, o "não permite"). */
    fun leitura(t: Textos): Pair<String, String?>

    fun exposicaoAuto()
    fun passarParaManual()
    fun ev(v: Double)
    fun travarExposicao(ligar: Boolean)
    fun antiCintilacao(a: AjusteDaCamera.AntiCintilacao)
    fun iso(v: Int)
    fun obturador(ns: Long)
    fun balancear(b: AjusteDaCamera.Balanco)
    fun kelvin(k: Int)
    fun travarBalanco(ligar: Boolean)
    fun focar(f: AjusteDaCamera.Foco)
    fun focoPosicao(p: Double)
    fun restaurar()

    /** "Usar meus ajustes" (07/10): só a câmera deste aparelho lembra; o receptor não oferece. */
    val ofereceMeusAjustes: Boolean get() = false
    fun usarMeusAjustes() {}

    /** A câmera deste aparelho: tudo como o painel do R9 sempre fez. */
    class Local(val c: ControlesDaCamera) : FonteDoPainel {
        override fun oferta(t: Textos) = OfertaDoPainel.deLocal(c.capacidades, c.fpsAgora(), t)
        override val ajuste: AjusteDaCamera get() = c.ajuste
        override val vivo = true
        override val isoAplicado: Int? get() = c.planoAtual?.isoAplicado
        override val obturadorAplicadoNs: Long? get() = c.planoAtual?.obturadorAplicadoNs
        override val obturadorPadraoNs: Long get() = EscalasDaCamera.duracaoDoQuadroNs(c.fpsAgora())
        override fun leitura(t: Textos): Pair<String, String?> {
            val l = c.leitura(t)
            return l.linha to (l.divergencia ?: c.aviso(t))
        }

        // Os motivos são do diário.
        override fun exposicaoAuto() = c.editar("exposição auto") { it.copy(exposicao = AjusteDaCamera.Exposicao.AUTO) } // i18n-fora: motivo do diário
        override fun passarParaManual() = c.passarParaManual()
        override fun ev(v: Double) = c.editar("ev") { it.copy(ev = v) }
        override fun travarExposicao(ligar: Boolean) = c.travarExposicao(ligar)
        override fun antiCintilacao(a: AjusteDaCamera.AntiCintilacao) = c.editar("anti-cintilação") { it.copy(antiCintilacao = a) } // i18n-fora: motivo do diário
        override fun iso(v: Int) = c.editar("iso") { it.copy(iso = v) }
        override fun obturador(ns: Long) = c.editar("obturador") { it.copy(obturadorNs = ns) }
        override fun balancear(b: AjusteDaCamera.Balanco) = c.balancear(b)
        override fun kelvin(k: Int) = c.editar("kelvin") { it.copy(kelvin = k) }
        override fun travarBalanco(ligar: Boolean) = c.travarBalanco(ligar)
        override fun focar(f: AjusteDaCamera.Foco) = c.focar(f)
        override fun focoPosicao(p: Double) = c.editar("foco manual") { it.copy(focoPosicao = p) }
        override fun restaurar() = c.restaurar()
        override val ofereceMeusAjustes: Boolean get() = c.ofereceMeusAjustes
        override fun usarMeusAjustes() = c.usarMeusAjustes()
    }

    /**
     * **A câmera do outro lado** (R9b, o receptor): o estado de [estado] e os pedidos pelo
     * [CameraRemotaBus]. Cada gesto manda **só** o campo mexido (contrato §5 e §12: o "Passar para Manual"
     * manda `exposicao` sozinho, e o filmador parte do lido dele no resto). Um pedido que o núcleo
     * recusa na hora (`QUALL_STATUS_INVALID`: o filmador recusaria) não sai, e o painel fica no aplicado.
     */
    class Remota(private val estado: () -> EstadoDaCameraRemota) : FonteDoPainel {
        private var ofertaEm: Pair<String?, java.util.Locale>? = null
        private var ofertaGuardada: OfertaDoPainel? = null

        override fun oferta(t: Textos): OfertaDoPainel {
            val e = estado()
            val chave = e.capacidadesJson to t.locale
            ofertaGuardada?.takeIf { ofertaEm == chave }?.let { return it }
            return OfertaDoPainel.deRemota(e.capacidades.orEmpty(), t).also {
                ofertaGuardada = it
                ofertaEm = chave
            }
        }

        override val ajuste: AjusteDaCamera get() = estado().ajuste ?: AjusteDaCamera()
        override val vivo: Boolean get() = estado().vivo
        override val isoAplicado: Int? get() = null
        override val obturadorAplicadoNs: Long? get() = null
        override val obturadorPadraoNs: Long
            get() = estado().lido.obturadorNs ?: EscalasDaCamera.duracaoDoQuadroNs(30)

        override fun leitura(t: Textos): Pair<String, String?> {
            val e = estado()
            val l = e.lido
            val ganho = oferta(t).isoEhGanho
            val linha = EscalasDaCamera.linhaDeLeitura(t, l.iso.takeIf { !ganho }, l.obturadorNs, l.kelvin, l.abertura)
            val aviso = when {
                e.situacao == EstadoDaCameraRemota.NAO_PERMITIDO -> t.s(com.quall.android.R.string.cam_remoto_nao_permitido)
                e.recusa != null -> EstadoDaCameraRemota.fraseDaRecusa(t, e.recusa)
                else -> divergencia(t, e)
            }
            return linha to aviso
        }

        /** "A câmera usou {lido} em vez de {pedido}." para o primeiro campo que o filmador diz divergir. */
        private fun divergencia(t: Textos, e: EstadoDaCameraRemota): String? {
            val a = e.ajuste ?: return null
            val l = e.lido
            for (campo in l.divergentes) {
                when (campo) {
                    "iso" -> if (l.iso != null && a.iso != null) return EscalasDaCamera.textoDaDivergencia(t,
                        EscalasDaCamera.textoDoIso(l.iso), EscalasDaCamera.textoDoIso(a.iso))
                    "obturadorNs" -> if (l.obturadorNs != null && a.obturadorNs != null) return EscalasDaCamera.textoDaDivergencia(t,
                        EscalasDaCamera.textoDoObturador(t, l.obturadorNs), EscalasDaCamera.textoDoObturador(t, a.obturadorNs))
                    "kelvin" -> if (l.kelvin != null && a.kelvin != null) return EscalasDaCamera.textoDaDivergencia(t,
                        EscalasDaCamera.textoDoKelvin(l.kelvin), EscalasDaCamera.textoDoKelvin(a.kelvin))
                }
            }
            return null
        }

        private fun pedir(campo: String, valor: Any) = pedir(listOf(campo to valor))

        private fun pedir(campos: List<Pair<String, Any>>) {
            val json = JsonDaCamera.objeto(campos.map { (k, v) ->
                k to when (v) {
                    is String -> JsonDaCamera.texto(v)
                    is Boolean -> v.toString()
                    is Number -> JsonDaCamera.num(v)
                    else -> JsonDaCamera.texto(v.toString())
                }
            })
            CameraRemotaBus.pedir(json)
            CameraRemotaBus.reler()
        }

        override fun exposicaoAuto() = pedir("exposicao", AjusteDaCamera.Exposicao.AUTO.json)
        override fun passarParaManual() = pedir("exposicao", AjusteDaCamera.Exposicao.MANUAL.json)
        override fun ev(v: Double) = pedir("ev", v)
        override fun travarExposicao(ligar: Boolean) = pedir("travaExposicao", ligar)
        override fun antiCintilacao(a: AjusteDaCamera.AntiCintilacao) = pedir("antiCintilacao", a.json)
        override fun iso(v: Int) = pedir("iso", v)
        override fun obturador(ns: Long) = pedir("obturadorNs", ns)
        override fun balancear(b: AjusteDaCamera.Balanco) = pedir("balanco", b.json)
        override fun kelvin(k: Int) = pedir("kelvin", k)
        override fun travarBalanco(ligar: Boolean) = pedir("travaBalanco", ligar)
        override fun focar(f: AjusteDaCamera.Foco) = pedir("foco", f.json)
        override fun focoPosicao(p: Double) = pedir("focoPosicao", p)
        override fun restaurar() {
            CameraRemotaBus.restaurar()
            CameraRemotaBus.reler()
        }
    }
}
