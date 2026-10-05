package com.quall.android.capture.dv

import android.content.Context
import android.content.SharedPreferences
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import com.quall.android.core.LogSeguro as Log
import androidx.annotation.StringRes
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.core.Textos

/**
 * O vídeo pelo USB, sem root: achar, abrir, negociar (probe/commit UVC) e escolher a alternativa
 * isócrona, como o `uvcvideo` do kernel faz. Veio do espião de bancada (`tools/espiao-dv-s24`), que
 * mediu cada passo:
 * - na **filmadora DV**, a Panasonic GS500 em modo DV (`04da:231e`) no S24: UVC 1.0, um formato só
 *   (`VS_FORMAT_DV`, SD-DV 60 Hz), alt 1 com psize 492, 29,97 quadros/s;
 * - na **placa de captura** (`docs/placa-de-captura-usb.md`, a P0), a EasyCap Arkmicro
 *   (`18ec:5555`): UVC 1.0, um formato só (`VS_FORMAT_MJPEG`), um quadro só (640x480, intervalos
 *   166666/333333/666666/2000000, padrão 333333), alt 11 high-bandwidth com psize 3000.
 *
 * O formato é escolhido na ordem **DV, depois MJPEG** ([EscolhaDeFormato]). Antes da permissão USB
 * só dá para ver a **classe** das interfaces: o formato está nos descritores crus, que exigem
 * `openDevice`. A lista mostra "Vídeo USB (…)"; se o aparelho não tiver nem DV nem uma placa que a
 * [RegraDaPlaca] aceite, a abertura diz. O tipo visto (ou a recusa) fica lembrado por `vid:pid`
 * ([tipoConhecido], [recusado]), no processo e nas preferências ([lembrarEm]): a lista passa a dizer
 * "Placa de captura (…)" ou "Filmadora DV (…)" ([VideoUsb]).
 */
object UsbDv {
    private const val TAG = "QuallDv"
    const val PREFIXO_DO_ID = "usb-dv:"
    /** Bancada: `usb-dv:arquivo:<caminho>` lê quadros DV de um arquivo (ver `Bancada.cameraDvArquivo`). */
    const val PREFIXO_DO_ARQUIVO = PREFIXO_DO_ID + "arquivo:"

    /** Aparelhos USB com interface de vídeo (classe 0x0E), na ordem do sistema. */
    fun candidatos(usb: UsbManager): List<UsbDevice> =
        usb.deviceList.values.filter { d ->
            (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_VIDEO }
        }

    fun produto(d: UsbDevice): String =
        d.productName?.takeIf { it.isNotBlank() } ?: "%04x:%04x".format(d.vendorId, d.productId)

    /** "Placa de captura (…)", "Filmadora DV (…)", ou "Vídeo USB (…)" antes da primeira abertura. */
    fun rotulo(t: Textos, d: UsbDevice): String = VideoUsb.rotulo(t, conhecido(d), produto(d))

    /**
     * O [rotulo] no idioma escolhido agora, para quem não tem os [Textos] à mão (a lista de Espelhar,
     * na `MainActivity`). Antes de [lembrarEm], só o produto.
     */
    fun rotulo(d: UsbDevice): String = textos()?.let { rotulo(it, d) } ?: produto(d)

    /**
     * O contexto do app, guardado por [lembrarEm] para as frases de quem não recebe um (a abertura,
     * o gravador, o som da placa). O idioma é pedido **na hora** a [Idioma.contexto]: a escolha do
     * seletor PT | EN vale sem reabrir o processo (`docs/traducao.md`, Android).
     */
    @Volatile private var app: Context? = null

    /** Os textos no idioma escolhido agora, ou `null` antes de [lembrarEm]. */
    internal fun textos(): Textos? = app?.let { Idioma.textos(Idioma.contexto(it)) }

    /**
     * A frase [id] no idioma escolhido agora. Antes de [lembrarEm] sai vazia — não acontece na
     * prática: quem abre o USB, grava ou ouve passa por ele antes (`FonteDv.abrir`, as telas).
     */
    internal fun frase(@StringRes id: Int, vararg args: Any): String = textos()?.s(id, *args) ?: ""

    fun conhecido(d: UsbDevice): VideoUsb.Conhecido = VideoUsb.conhecido(tipoConhecido(d), recusado(d))

    /** O aparelho tem interface de som (a placa tem UAC; a filmadora DV leva o som no DV). */
    fun temSom(d: UsbDevice): Boolean =
        (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_AUDIO }

    /** O palpite de "é placa" (o tipo lembrado, senão a interface de som). */
    fun pareceSerPlaca(d: UsbDevice): Boolean = VideoUsb.pareceSerPlaca(conhecido(d), temSom(d))

    fun porId(usb: UsbManager, id: String): UsbDevice? =
        usb.deviceList.values.firstOrNull { PREFIXO_DO_ID + it.deviceName == id }

    private val tiposVistos = java.util.concurrent.ConcurrentHashMap<String, TipoUsb>()
    private val recusados = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    @Volatile private var preferencias: SharedPreferences? = null

    private fun chave(d: UsbDevice) = "%04x:%04x".format(d.vendorId, d.productId)

    /**
     * Carrega (uma vez) e passa a gravar o que já se viu de cada `vid:pid` nas preferências do app:
     * a lista diz "Placa de captura (…)" já na próxima abertura do app, sem esperar a permissão.
     */
    fun lembrarEm(c: Context) {
        if (app == null) {
            val a = c.applicationContext
            app = a
            VideoUsb.textosAgora = { Idioma.textos(Idioma.contexto(a)) }
        }
        if (preferencias != null) return
        synchronized(this) {
            if (preferencias != null) return
            val p = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            for ((k, v) in p.all) {
                // As escolhas da pessoa ([preferencia], `GravacaoDaPlaca`) moram no mesmo arquivo: não são tipos.
                if (k.startsWith("fmt:") || k.startsWith("gravacao:")) continue
                when (v) {
                    RECUSADO -> recusados += k
                    is String -> runCatching { TipoUsb.valueOf(v) }.getOrNull()?.let { tiposVistos.putIfAbsent(k, it) }
                }
            }
            preferencias = p
        }
    }

    /**
     * O formato que a última abertura deste `vid:pid` escolheu, ou `null` se ele ainda não abriu
     * (neste processo ou, com [lembrarEm], antes).
     */
    fun tipoConhecido(d: UsbDevice): TipoUsb? = tiposVistos[chave(d)]

    /** A [RegraDaPlaca] recusou este `vid:pid` (uma webcam): some da lista sem a chave de bancada. */
    fun recusado(d: UsbDevice): Boolean = chave(d) in recusados

    private fun lembrar(d: UsbDevice, tipo: TipoUsb?) {
        val k = chave(d)
        val mudou = if (tipo == null) recusados.add(k) else (tiposVistos.put(k, tipo) != tipo).also { recusados.remove(k) }
        if (!mudou) return
        preferencias?.edit()?.putString(k, tipo?.name ?: RECUSADO)?.apply()
        for (o in ouvintesDoTipo.values) runCatching { o() }
    }

    /** A escolha de formato/tamanho/quadros da pessoa para este `vid:pid` (§14.4), ou `null` (a regra escolhe). */
    fun preferencia(d: UsbDevice): Preferencia? = Preferencia.de(preferencias?.getString("fmt:" + chave(d), null))

    fun preferir(d: UsbDevice, p: Preferencia?) {
        val e = preferencias?.edit() ?: return
        if (p == null) e.remove("fmt:" + chave(d)) else e.putString("fmt:" + chave(d), p.texto())
        e.apply()
    }

    private const val PREFS = "quall_video_usb"
    private const val RECUSADO = "RECUSADO"

    /**
     * Chamado (na thread que abriu) quando uma abertura descobre um tipo novo (ou a recusa) para um
     * `vid:pid`: a tela troca o rótulo da lista e o texto do "Gravar" já no primeiro Espelhar (a
     * revisão do código da P1, 6). **Um ouvinte por tela** (como o `MirrorBus`): com um só, a tela
     * "Placa de captura e filmadora" ficava em "Vídeo USB (…)" na primeira abertura (S24, 30/09).
     */
    fun ouvirTipo(dono: Any, o: (() -> Unit)?) {
        if (o == null) ouvintesDoTipo.remove(dono) else ouvintesDoTipo[dono] = o
    }

    private val ouvintesDoTipo = java.util.concurrent.ConcurrentHashMap<Any, () -> Unit>()

    class Aberta(
        val conexao: UsbDeviceConnection,
        val vc: UsbInterface,
        val vs0: UsbInterface,
        val endpoint: Int,
        val psize: Int,
        val alt: Int,
        val tipo: TipoUsb = TipoUsb.DV,
        /** O quadro negociado (a DV é sempre 720x480; o MJPEG, o quadro escolhido). */
        val largura: Int = 720,
        val altura: Int = 480,
        /** O `dwMaxVideoFrameSize` do commit (0 se a câmera não disse). */
        val quadroMax: Long = 0,
        /** O som pelo usbfs (§13.10): o endpoint isócrono e o pacote; 0 sem ele. */
        val somEndpoint: Int = 0,
        val somPsize: Int = 0,
        private val somAlt0: UsbInterface? = null,
        /** O controle de som reivindicado, e os volumes de antes (unidade, canal, valor), para devolver. */
        private val somControle: UsbInterface? = null,
        private val volumesDeAntes: List<Triple<Int, Int, Int>> = emptyList(),
        /** Amostras da placa por amostra de saída do som ([SomUac.passo]). */
        val somPasso: Int = 1,
        /** As placas HDMI (§14): o endpoint de vídeo é bulk, com payloads de até [payloadMax]; [cru] = NV12. */
        val bulk: Boolean = false,
        val payloadMax: Int = 0,
        val cru: Int = 0,
        /** O formato aberto pelo nome ("MJPEG", "NV12", "YUY2", "DV") e o cardápio da placa (§14.4). */
        val formato: String = "",
        val ofertas: List<Oferta> = emptyList(),
        /** Os quadros por segundo que a fonte guarda, se menos que os da placa (§14.6); 0 = todos. */
        val fpsAlvo: Int = 0,
        /** O intervalo de quadro negociado, em 100 ns (0 = o da câmera, a DV). */
        val intervalo: Long = 0,
    ) {
        /** Devolve o aparelho ao kernel: VS antes da VC (o uvcvideo casa pela VC e pega a VS no probe). */
        fun soltar() {
            somControle?.let { ac ->
                for ((unidade, canal, valor) in volumesDeAntes) runCatching { escreverVolume(conexao, ac.id, unidade, canal, valor) }
                runCatching { conexao.releaseInterface(ac) }
            }
            somAlt0?.let { s -> runCatching { conexao.setInterface(s) }; runCatching { conexao.releaseInterface(s) } }
            runCatching { conexao.setInterface(vs0) }
            runCatching { conexao.releaseInterface(vs0) }
            runCatching { conexao.releaseInterface(vc) }
            runCatching { conexao.close() }
        }
    }

    /**
     * O teto do volume de captura da placa, em 1/256 dB: **+37,5 dB** (a EasyCap vem em +43,5 dB, e a
     * fita batia em 0 dBFS; 6 dB de folga). Um volume que já esteja abaixo disso não é mexido.
     */
    private const val VOLUME_ALVO = 9600

    /** GET_CUR (0x81) / GET_MIN (0x82) do volume (UAC 1.0, seletor 2), em 1/256 dB; `null` se falhar. */
    private fun lerVolume(con: UsbDeviceConnection, ac: Int, pedido: Int, unidade: Int, canal: Int): Int? {
        val b = ByteArray(2)
        val r = con.controlTransfer(0xA1, pedido, (2 shl 8) or canal, (unidade shl 8) or ac, b, 2, 500)
        return if (r == 2) ((b[0].toInt() and 0xFF) or (b[1].toInt() shl 8)).toShort().toInt() else null
    }

    private fun escreverVolume(con: UsbDeviceConnection, ac: Int, unidade: Int, canal: Int, valor: Int): Boolean {
        val b = byteArrayOf((valor and 0xFF).toByte(), ((valor shr 8) and 0xFF).toByte())
        return con.controlTransfer(0x21, 0x01, (2 shl 8) or canal, (unidade shl 8) or ac, b, 2, 500) == 2
    }

    /**
     * Abre, reivindica (tirando o `uvcvideo`), negocia o formato (DV, senão MJPEG) e liga a
     * alternativa. Lança [IllegalStateException] com a frase para o usuário quando algo não dá.
     */
    fun abrir(usb: UsbManager, dev: UsbDevice, alturaMax: Int = EscolhaDeFormato.ALTURA_MAX): Aberta {
        // Antes dos descritores, o nome é o do que já se sabe dele; depois da escolha, o do tipo.
        // As frases vão à tela ("A imagem parou: …"): no idioma escolhido ([frase]).
        var nome = textos()?.let { VideoUsb.nome(it, conhecido(dev)) } ?: produto(dev)
        if (!usb.hasPermission(dev)) throw IllegalStateException(frase(R.string.placa_abrir_sem_permissao, nome))
        val con = usb.openDevice(dev) ?: throw IllegalStateException(frase(R.string.placa_abrir_nao_abriu, nome))
        try {
            val raw = con.rawDescriptors ?: throw IllegalStateException(frase(R.string.placa_abrir_sem_descritores, nome))
            val d = Descritores.analisar(raw)
            Log.i(TAG, "descritores: ${d.resumo()}")
            // Antes de reivindicar: uma webcam UVC comum não é tirada do `uvcvideo` (a revisão do
            // código da P1, 2).
            val pref = preferencia(dev)
            val escolha = EscolhaDeFormato.escolher(d, alturaMax, pref)
            // A taxa menor só vale se a escolha da pessoa foi a que abriu, e se fica abaixo da da placa.
            val fpsAlvo = pref?.takeIf {
                it.fps > 0 && escolha?.formato?.detalhe == it.formato && escolha.quadro?.largura == it.largura &&
                    escolha.quadro.altura == it.altura && it.fps < TaxasDeQuadros.fpsDe(escolha.intervalo ?: 0)
            }?.fps ?: 0
            val ofertas = EscolhaDeFormato.ofertas(d)
            if (escolha == null) {
                Log.w(TAG, "nem DV nem placa de captura: ${EscolhaDeFormato.porQueNao(d)}")
                lembrar(dev, null)
                throw IllegalStateException(frase(R.string.placa_abrir_nao_e_placa))
            }
            nome = textos()?.let { VideoUsb.nome(it, VideoUsb.conhecido(escolha.tipo, false)) } ?: nome
            val vs = escolha.vs
            val vcNum = d.vcInterface ?: throw IllegalStateException(frase(R.string.placa_abrir_sem_videocontrol, nome))
            Log.i(TAG, "formato escolhido: ${escolha.descricao()}")
            fun iface(num: Int, alt: Int): UsbInterface? = (0 until dev.interfaceCount)
                .map { dev.getInterface(it) }.firstOrNull { it.id == num && it.alternateSetting == alt }
            val vc = iface(vcNum, 0) ?: throw IllegalStateException(frase(R.string.placa_abrir_sem_interface, "VC $vcNum"))
            val vs0 = iface(vs.numero, 0) ?: throw IllegalStateException(frase(R.string.placa_abrir_sem_interface, "VS ${vs.numero}"))
            // force=true: USBDEVFS_DISCONNECT + CLAIMINTERFACE (tira o uvcvideo).
            if (!con.claimInterface(vc, true) || !con.claimInterface(vs0, true)) {
                throw IllegalStateException(frase(R.string.placa_abrir_em_uso, nome))
            }
            val neg = Negociacao(con, vs.numero, d.bcdUvc)
                .negociar(escolha.formato, escolha.quadro?.indice, escolha.intervalo)
                ?: throw IllegalStateException(
                    if (escolha.tipo == TipoUsb.DV) frase(R.string.placa_abrir_dv_recusou)
                    else frase(R.string.placa_abrir_placa_recusou, escolha.formato.detalhe)
                )
            // O som (o endpoint, o pacote, as interfaces e os volumes de antes), tomado depois de o vídeo abrir.
            class Som(val ep: Int, val psize: Int, val alt0: UsbInterface?, val controle: UsbInterface?, val antes: List<Triple<Int, Int, Int>>, val passo: Int)
            fun tomarSom(): Som {
            // **O som da placa pelo usbfs** (§13.10): o caminho do Android (o `AudioRecord`)
            // levanta o som baixo em ~20 dB neste S24 (o chiado). Só a placa, e só no formato
            // que o C lê; tomar a interface tira o driver de som do kernel (o `AudioRecord`
            // dela passa a dar zeros até replugar, medido). Se algo não der, fica o `AudioRecord`.
            var somEp = 0; var somPsize = 0; var somAlt0: UsbInterface? = null
            var somControle: UsbInterface? = null
            val volumesDeAntes = mutableListOf<Triple<Int, Int, Int>>()
            val s = d.som
            if (escolha.tipo == TipoUsb.MJPEG && s != null && s.lidoPeloQuall) {
                val s0 = iface(s.numero, 0)
                val s1 = (0 until dev.interfaceCount).map { dev.getInterface(it) }
                    .firstOrNull { it.id == s.numero && it.endpointCount == 1 }
                val e = s1?.getEndpoint(0)
                if (s0 != null && s1 != null && e != null && e.direction == UsbConstants.USB_DIR_IN &&
                    e.type == UsbConstants.USB_ENDPOINT_XFER_ISOC && con.claimInterface(s1, true)) {
                    if (con.setInterface(s1)) {
                        somEp = e.address; somPsize = e.maxPacketSize; somAlt0 = s0
                    } else {
                        runCatching { con.releaseInterface(s1) }
                    }
                }
                // **O volume de captura** (§13.11): a EasyCap vem em +43,5 dB e a fita bate no
                // teto; desce para [VOLUME_ALVO] (sem passar do mínimo, e nunca sobe). O valor de antes é
                // devolvido ao soltar (a placa o guarda até ser desplugada).
                val ac = d.acInterface?.let { iface(it, 0) }
                if (somEp != 0 && ac != null && d.volumesDoSom.isNotEmpty() && con.claimInterface(ac, true)) {
                    somControle = ac
                    // Todos lidos antes de escrever: na EasyCap os dois canais andam juntos
                    // (escrever um muda o outro), e ler depois descia 6 dB duas vezes (medido).
                    val lidos = d.volumesDoSom.flatMap { (unidade, canais) ->
                        canais.mapNotNull { canal ->
                            val cur = lerVolume(con, ac.id, 0x81, unidade, canal) ?: return@mapNotNull null
                            val min = lerVolume(con, ac.id, 0x82, unidade, canal) ?: return@mapNotNull null
                            listOf(unidade, canal, cur, min)
                        }
                    }
                    for ((unidade, canal, cur, min) in lidos) {
                        // Um alvo fixo, e só para baixo: se o app morreu com o volume já baixo (a
                        // placa o guarda até desplugar), a abertura seguinte não desce de novo.
                        val novo = maxOf(min, VOLUME_ALVO)
                        if (novo >= cur) continue
                        volumesDeAntes += Triple(unidade, canal, cur)
                        val ok = escreverVolume(con, ac.id, unidade, canal, novo)
                        Log.i(TAG, "volume do som: unidade $unidade canal $canal %.1f dB -> %.1f dB (mínimo %.1f): %s; relido %.1f dB"
                            .format(cur / 256.0, novo / 256.0, min / 256.0, if (ok) "ok" else "recusado",
                                (lerVolume(con, ac.id, 0x81, unidade, canal) ?: cur) / 256.0))
                    }
                }
                Log.i(TAG, "som pelo USB: " + if (somEp != 0) "interface ${s.numero} alt ${s1?.alternateSetting}, endpoint 0x%02x psize $somPsize".format(somEp)
                    else "não deu (fica o AudioRecord)")
            } else if (escolha.tipo == TipoUsb.MJPEG) {
                Log.i(TAG, "som pelo USB: fora (${s?.let { "${it.canais} canal(is), ${it.bytesPorAmostra} bytes, ${it.taxas} Hz" } ?: "sem fluxo de som"}); fica o AudioRecord")
            }
                return Som(somEp, somPsize, somAlt0, somControle, volumesDeAntes, s?.passo ?: 1)
            }
            val maxPayload = neg.payloadMax
            val banda = if (maxPayload <= 0L) 1L else maxPayload
            val ep = vs.endpointDoCabecalho
            val nAlts = (0 until dev.interfaceCount).count { dev.getInterface(it).id == vs.numero }
            val altsIso = vs.alts.filter { it.alt > 0 && it.endpoint == ep && it.tipo == 1 }.sortedBy { it.psize }
            if (altsIso.isEmpty()) {
                // **Bulk** (a MS2109 `345f` e a ezcap, §12): o endpoint do cabeçalho na alternativa 0,
                // sem banda a reservar; cada payload UVC é uma URB de até o dwMaxPayloadTransferSize.
                val bulk0 = vs.alts.firstOrNull { it.alt == 0 && it.endpoint == ep && it.tipo == 2 }
                    ?: throw IllegalStateException(frase(R.string.placa_abrir_sem_iso_nem_bulk, nome))
                // (Sem `setInterface` depois do commit: no bulk ele para o fluxo — medido na ezcap, nenhuma URB voltava.)
                lembrar(dev, escolha.tipo)
                val q = neg.quadro
                val som = tomarSom()
                val payload = maxPayload.coerceIn(0L, 1L shl 20).toInt()
                Log.i(TAG, "VS ${vs.numero} bulk, endpoint 0x%02x psize ${bulk0.psize}, payload $payload".format(ep))
                return Aberta(
                    con, vc, vs0, ep, bulk0.psize, 0, escolha.tipo,
                    largura = q?.largura ?: 720, altura = q?.altura ?: 480, quadroMax = neg.quadroMax,
                    somEndpoint = som.ep, somPsize = som.psize, somAlt0 = som.alt0,
                    somControle = som.controle, volumesDeAntes = som.antes, somPasso = som.passo,
                    bulk = true, payloadMax = payload, cru = escolha.cru, intervalo = escolha.intervalo ?: 0,
                    formato = escolha.formato.detalhe, ofertas = ofertas, fpsAlvo = fpsAlvo,
                )
            }
            if (nAlts < 2) throw IllegalStateException(frase(R.string.placa_abrir_sem_iso, nome))
            val candidatas = altsIso.filter { it.psize >= banda }.ifEmpty { altsIso.reversed() }
            for (a in candidatas) {
                val ui = iface(vs.numero, a.alt) ?: continue
                if (con.setInterface(ui)) {
                    Log.i(TAG, "VS ${vs.numero} alt ${a.alt} psize ${a.psize} (pedido $banda), endpoint 0x%02x".format(ep))
                    lembrar(dev, escolha.tipo)
                    // O tamanho é o do quadro que a câmera aceitou (o `bFrameIndex` do GET_CUR), e
                    // não o do pedido (a revisão do código da P1, 1).
                    val q = neg.quadro
                    val som = tomarSom()
                    return Aberta(
                        con, vc, vs0, ep, a.psize, a.alt, escolha.tipo,
                        largura = q?.largura ?: 720, altura = q?.altura ?: 480, quadroMax = neg.quadroMax,
                        somEndpoint = som.ep, somPsize = som.psize, somAlt0 = som.alt0,
                        somControle = som.controle, volumesDeAntes = som.antes, somPasso = som.passo,
                        cru = escolha.cru, intervalo = escolha.intervalo ?: 0,
                        formato = escolha.formato.detalhe, ofertas = ofertas, fpsAlvo = fpsAlvo,
                    )
                }
                Log.w(TAG, "setInterface alt ${a.alt} recusado")
            }
            throw IllegalStateException(frase(R.string.placa_abrir_sem_banda, nome))
        } catch (t: Throwable) {
            runCatching { con.close() }
            throw t
        }
    }
}

/** O formato de vídeo aberto; o [codigo] é o `FORMATO_*` do C (`cpp/dv/remontagem.h`). */
enum class TipoUsb(val codigo: Int) { DV(0), MJPEG(1) }

class Formato(val subtipo: Int, val indice: Int, val detalhe: String) {
    /** Os descritores de quadro que seguem o formato (só os do MJPEG, `VS_FRAME_MJPEG` 0x07). */
    val quadros = mutableListOf<Quadro>()
}

/**
 * Um `VS_FRAME_MJPEG`: o índice, o tamanho, o intervalo padrão e os intervalos (em 100 ns). Com
 * [continuo] (bFrameIntervalType 0), os intervalos são [mínimo, máximo, passo].
 */
class Quadro(
    val indice: Int,
    val largura: Int,
    val altura: Int,
    val intervaloPadrao: Long,
    val intervalos: List<Long>,
    val continuo: Boolean = false,
    val bufferMax: Long = 0,
)

class Alt(val alt: Int, val endpoint: Int, val tipo: Int, val psize: Int)

/** A escolha do formato, do quadro e do intervalo. Pura: testada em JVM. */
object EscolhaDeFormato {
    const val SUBTIPO_DV = 0x0C
    const val SUBTIPO_MJPEG = 0x06
    /** 30 quadros/s, em 100 ns. */
    const val INTERVALO_30 = 333_333L

    class Escolha(
        val vs: Vs, val formato: Formato, val tipo: TipoUsb, val quadro: Quadro?, val intervalo: Long?,
        /**
         * O quadro não comprimido (as placas HDMI, §14): 0 = MJPEG, 1 = NV12, 2 = YUY2 (o `cru` do C). O
         * tipo continua [TipoUsb.MJPEG] (a "placa").
         */
        val cru: Int = 0,
    ) {
        fun descricao(): String = when (tipo) {
            TipoUsb.DV -> "DV (formato ${formato.indice}, ${formato.detalhe}; quadro e intervalo herdados)"
            TipoUsb.MJPEG -> "${formato.detalhe} (formato ${formato.indice}, quadro ${quadro?.indice} " +
                "${quadro?.largura}x${quadro?.altura}, intervalo $intervalo)"
        }
    }

    /**
     * DV primeiro (a GS500: o quadro e o intervalo ficam como vieram, o que foi provado); senão o
     * MJPEG de uma **placa de captura**, e aí quadro e intervalo **explícitos**. `null` sem nenhum
     * dos dois.
     *
     * **Placa de captura**: o que a [RegraDaPlaca] aceita (isolada, para mudar com as placas HDMI).
     */
    fun escolher(d: Descritores, alturaMax: Int = ALTURA_MAX, pref: Preferencia? = null): Escolha? {
        for (v in d.vss.values) {
            val dv = v.formatos.firstOrNull { it.subtipo == SUBTIPO_DV } ?: continue
            return Escolha(v, dv, TipoUsb.DV, null, null)
        }
        for (v in d.vss.values) {
            if (!ehPlacaDeCaptura(v, d)) continue
            // A escolha da pessoa (§14.4), se a placa ainda a oferece: o formato, o tamanho e o intervalo.
            if (pref != null) {
                val f = v.formatos.firstOrNull { codigoCru(it) != null && it.detalhe == pref.formato }
                val q = f?.quadros?.firstOrNull { it.largura == pref.largura && it.altura == pref.altura }
                if (f != null && q != null) {
                    return Escolha(v, f, TipoUsb.MJPEG, q, intervalo(q, pref.intervalo), cru = codigoCru(f)!!)
                }
            }
            // NV12 primeiro (sem decodificar; a ezcap só tem não comprimido), depois o MJPEG (as
            // MS2109, cujo YUY2 é lento: 1 quadro/s em 1080p, §12.1). YUY2, P010 e RGB ficam fora.
            for (f in v.formatos) {
                if (f.subtipo != SUBTIPO_NAO_COMPRIMIDO || f.detalhe != "NV12") continue
                val q = quadro(f.quadros, alturaMax) ?: continue
                return Escolha(v, f, TipoUsb.MJPEG, q, intervalo(q), cru = 1)
            }
            for (f in v.formatos) {
                if (f.subtipo != SUBTIPO_MJPEG) continue
                val q = quadro(f.quadros, alturaMax) ?: continue
                return Escolha(v, f, TipoUsb.MJPEG, q, intervalo(q))
            }
        }
        return null
    }

    const val SUBTIPO_NAO_COMPRIMIDO = 0x04

    /** O `cru` do C para um formato que o Quall lê: 0 MJPEG, 1 NV12, 2 YUY2; `null` para os outros. */
    fun codigoCru(f: Formato): Int? = when {
        f.subtipo == SUBTIPO_MJPEG -> 0
        f.subtipo == SUBTIPO_NAO_COMPRIMIDO && f.detalhe == "NV12" -> 1
        f.subtipo == SUBTIPO_NAO_COMPRIMIDO && f.detalhe == "YUY2" -> 2
        else -> null
    }

    /**
     * **O cardápio da placa** (§14.4): o que ela oferece e o Quall lê (MJPEG, NV12, YUY2), até
     * 3840x2160 (a regra, sem escolha da pessoa, fica em 720 linhas), com os intervalos de cada tamanho. Vazio fora de uma placa de captura.
     */
    fun ofertas(d: Descritores): List<Oferta> {
        val v = d.vss.values.firstOrNull { ehPlacaDeCaptura(it, d) } ?: return emptyList()
        return v.formatos.filter { codigoCru(it) != null }.flatMap { f ->
            f.quadros.filter { it.largura in 1..3840 && it.altura in 1..2160 }.map { q ->
                val ints = if (q.continuo) listOf(intervalo(q)) else q.intervalos.filter { it > 0 }.distinct().sorted()
                Oferta(f.detalhe, q.largura, q.altura, ints.ifEmpty { listOf(intervalo(q)) })
            }
        }
    }
    /**
     * O teto da altura do quadro pedido à placa: **720** (1280x720). As placas HDMI oferecem até 4K; o
     * 1080p custa ~2,25x no USB, na decodificação do MJPEG e no encoder, e a bancada (`placa_altura_max`)
     * o sobe. A EasyCap (640x480, 720x576) cabe sempre.
     */
    const val ALTURA_MAX = 720

    fun ehPlacaDeCaptura(v: Vs, d: Descritores? = null): Boolean =
        RegraDaPlaca.aceita(v.formatos, temSom = d?.temSom == true, controlesDeCamera = d?.controlesDeCamera != false)

    /** Por que nenhuma VS serviu (o diário da recusa; o dado que a troca da regra vai querer). */
    fun porQueNao(d: Descritores): String =
        if (d.vss.isEmpty()) "sem VideoStreaming"
        else d.vss.values.joinToString("; ") {
            "VS ${it.numero}: ${RegraDaPlaca.julgar(it.formatos, d.temSom, d.controlesDeCamera).porque}"
        }

    /** O maior (em área) até 1920 de largura e [alturaMax] de altura; se nenhum cabe, o menor. */
    fun quadro(qs: List<Quadro>, alturaMax: Int = 1080): Quadro? {
        val validos = qs.filter { it.largura > 0 && it.altura > 0 }
        return validos.filter { it.largura <= 1920 && it.altura <= alturaMax }
            .maxByOrNull { it.largura.toLong() * it.altura }
            ?: validos.minByOrNull { it.largura.toLong() * it.altura }
    }

    /** O intervalo oferecido mais perto de [alvo] (30/s); no empate, o mais curto. */
    fun intervalo(q: Quadro, alvo: Long = INTERVALO_30): Long {
        if (q.continuo && q.intervalos.size >= 3) {
            val (min, max, passo) = q.intervalos
            var v = alvo.coerceIn(min, maxOf(min, max))
            if (passo > 0) v = (min + Math.round((v - min).toDouble() / passo) * passo).coerceAtMost(max)
            return v
        }
        val lista = q.intervalos.filter { it > 0 }
        if (lista.isEmpty()) return if (q.intervaloPadrao > 0) q.intervaloPadrao else alvo
        return lista.sortedWith(compareBy<Long>({ Math.abs(it - alvo) }, { it })).first()
    }
}

/** Um item do cardápio da placa: o formato, o tamanho e os intervalos de quadro (100 ns). */
class Oferta(val formato: String, val largura: Int, val altura: Int, val intervalos: List<Long>)

/** O que a pessoa escolheu para uma placa (lembrado por `vid:pid`). */
data class Preferencia(
    val formato: String, val largura: Int, val altura: Int, val intervalo: Long,
    /**
     * Os quadros por segundo que o Quall guarda, quando são menos que os da placa (§14.6): a placa manda
     * no [intervalo] dela e a fonte solta os quadros a mais. 0 = todos os da placa.
     */
    val fps: Int = 0,
) {
    fun texto(): String = "$formato;$largura;$altura;$intervalo;$fps"
    companion object {
        fun de(s: String?): Preferencia? {
            val p = s?.split(';') ?: return null
            if (p.size != 4 && p.size != 5) return null
            return Preferencia(p[0], p[1].toIntOrNull() ?: return null, p[2].toIntOrNull() ?: return null,
                p[3].toLongOrNull() ?: return null, p.getOrNull(4)?.toIntOrNull() ?: 0)
        }
    }
}

/** Uma taxa de quadros oferecida à pessoa: a da placa, ou uma menor que o Quall tira dela. */
data class TaxaDeQuadros(val fps: Int, val intervaloDaPlaca: Long, val daPlaca: Boolean, val regular: Boolean)

object TaxasDeQuadros {
    /** As taxas menores que o Quall oferece além das da placa. */
    val ALVOS = listOf(60, 50, 30, 25, 24)

    fun fpsDe(intervalo: Long): Int = if (intervalo <= 0) 0 else Math.round(10_000_000.0 / intervalo).toInt()

    /**
     * O cardápio de quadros por segundo de um tamanho: as taxas da placa, mais as de [ALVOS] abaixo da
     * maior dela. Para cada alvo, a taxa da placa de que ele sai: a menor que seja **múltiplo exato**
     * (60 → 30, 120 → 24: cadência regular), senão a menor acima dele (60 → 24: dois de cada cinco,
     * cadência irregular). Da maior para a menor. Puro: testado em JVM.
     */
    fun cardapio(intervalos: List<Long>): List<TaxaDeQuadros> {
        val placa = intervalos.filter { it > 0 }.distinct().map { fpsDe(it) to it }.filter { it.first > 0 }
        val r = placa.map { TaxaDeQuadros(it.first, it.second, daPlaca = true, regular = true) }.toMutableList()
        for (alvo in ALVOS) {
            if (placa.any { it.first == alvo } || placa.none { it.first > alvo }) continue
            val acima = placa.filter { it.first > alvo }.sortedBy { it.first }
            val exato = acima.firstOrNull { it.first % alvo == 0 }
            val de = exato ?: acima.first()
            r += TaxaDeQuadros(alvo, de.second, daPlaca = false, regular = exato != null)
        }
        return r.sortedByDescending { it.fps }
    }
}

class Vs(val numero: Int) {
    var endpointDoCabecalho = -1
    val formatos = mutableListOf<Formato>()
    val alts = mutableListOf<Alt>()
}

class SomUac(val numero: Int, val canais: Int, val bytesPorAmostra: Int, val taxas: List<Int>) {
    /**
     * O que o som pelo usbfs sabe ler (§13.10, §14): 16 bits, mono ou estéreo, **uma taxa só**, 48 ou
     * 96 kHz (a EasyCap: 48 mono; a ezcap e a MS2109 bulk: 48 estéreo; a MS2109 isócrona: 96 mono). Com
     * mais de uma taxa a placa pediria o controle de frequência do endpoint, que não se escreve.
     */
    val lidoPeloQuall: Boolean get() = canais in 1..2 && bytesPorAmostra == 2 && taxas.size == 1 && taxas[0] in listOf(48_000, 96_000)
    /** Amostras da placa por amostra de saída (48 kHz mono): os canais vezes a taxa sobre 48 kHz. */
    val passo: Int get() = canais * (taxas.firstOrNull() ?: 48_000) / 48_000
}

/** Os descritores crus da configuração (UVC 1.0/1.1/1.5). Puro: testado em JVM. */
class Descritores {
    var bcdUvc = 0x0100
    var vcInterface: Int? = null
    val vss = linkedMapOf<Int, Vs>()
    /** O fluxo de som (UAC 1.0, `FORMAT_TYPE_I`): a interface, os canais, os bytes por amostra e as taxas. */
    var som: SomUac? = null
    /** O controle de som (UAC 1.0): a interface, e os canais com volume de cada `FEATURE_UNIT` (id → canais). */
    var acInterface: Int? = null
    val volumesDoSom = linkedMapOf<Int, List<Int>>()
    /** O terminal de entrada da VC declara algum controle de câmera (exposição, foco…): é uma webcam. */
    var controlesDeCamera = false
    /** Há interface de som (UAC) no mesmo aparelho: o que uma placa de captura tem e uma filmadora DV não. */
    val temSom: Boolean get() = som != null || acInterface != null

    fun resumo(): String = buildString {
        append("bcdUVC %x.%02x VC=%s".format(bcdUvc shr 8, bcdUvc and 0xFF, vcInterface))
        for (v in vss.values) {
            append("; VS ${v.numero} ep 0x%02x".format(v.endpointDoCabecalho))
            append(" formatos=").append(v.formatos.joinToString(",") { f ->
                "${f.indice}:${f.detalhe}" + f.quadros.joinToString("") { q ->
                    "[${q.indice}:${q.largura}x${q.altura} padrão ${q.intervaloPadrao} " + // i18n-fora: diário (o resumo dos descritores)
                        "${if (q.continuo) "contínuo " else ""}${q.intervalos.joinToString("/")}]" // i18n-fora: diário (o resumo dos descritores)
                }
            })
            append(" alts=").append(v.alts.joinToString(",") { "${it.alt}/${it.tipo}/${it.psize}" })
        }
    }

    companion object {
        fun analisar(b: ByteArray): Descritores {
            val r = Descritores()
            fun u8(i: Int) = b[i].toInt() and 0xFF
            fun u16(i: Int) = u8(i) or (u8(i + 1) shl 8)
            fun u32(i: Int) = u16(i).toLong() or (u16(i + 2).toLong() shl 16)
            var i = 0
            var ifNum = -1; var ifAlt = -1; var ifClasse = -1; var ifSub = -1
            while (i + 2 <= b.size) {
                val len = u8(i)
                val tipo = u8(i + 1)
                if (len < 2 || i + len > b.size) break
                when (tipo) {
                    0x04 -> if (len >= 9) {
                        ifNum = u8(i + 2); ifAlt = u8(i + 3); ifClasse = u8(i + 5); ifSub = u8(i + 6)
                        if (ifClasse == 0x0E && ifSub == 0x01) r.vcInterface = ifNum
                        if (ifClasse == 0x01 && ifSub == 0x01) r.acInterface = ifNum
                        if (ifClasse == 0x0E && ifSub == 0x02) r.vss.getOrPut(ifNum) { Vs(ifNum) }
                    }
                    0x24 -> if (ifClasse == 0x01 && ifSub == 0x01 && len >= 7 && u8(i + 2) == 0x06) {
                        // FEATURE_UNIT: bmaControls por canal (o 0 é o mestre); o bit 1 é o volume.
                        val tam = u8(i + 5)
                        if (tam in 1..2) {
                            val canais = (0 until (len - 7) / tam).filter { k -> u8(i + 6 + k * tam) and 0x02 != 0 }
                            if (canais.isNotEmpty()) r.volumesDoSom[u8(i + 3)] = canais
                        }
                    } else if (ifClasse == 0x01 && ifSub == 0x02 && len >= 8 && u8(i + 2) == 0x02 && u8(i + 3) == 0x01) {
                        val n = u8(i + 7)
                        r.som = SomUac(ifNum, u8(i + 4), u8(i + 5), (0 until n).map { i + 8 + 3 * it }
                            .filter { it + 3 <= i + len }.map { u8(it) or (u8(it + 1) shl 8) or (u8(it + 2) shl 16) })
                    } else if (ifClasse == 0x0E && len >= 3) {
                        val st = u8(i + 2)
                        if (ifSub == 0x01 && st == 0x01 && len >= 5) {
                            r.bcdUvc = u16(i + 3)
                        } else if (ifSub == 0x01 && st == 0x02 && len >= 16 && u16(i + 4) == 0x0201) {
                            // INPUT_TERMINAL de câmera: o bmControls (bControlSize em 14) diz se há
                            // exposição, foco, zoom… As quatro placas medidas o trazem zerado (§12.4).
                            val n = u8(i + 14)
                            if ((0 until n).any { i + 15 + it < i + len && u8(i + 15 + it) != 0 }) r.controlesDeCamera = true
                        } else if (ifSub == 0x02) {
                            val vs = r.vss.getOrPut(ifNum) { Vs(ifNum) }
                            when {
                                st == 0x01 && len >= 7 -> vs.endpointDoCabecalho = u8(i + 6)
                                st == 0x0C && len >= 9 -> {
                                    val ft = u8(i + 8)
                                    val nome = when (ft and 0x7F) { 0 -> "SD-DV"; 1 -> "SDL-DV"; 2 -> "HD-DV"; else -> "DV?" }
                                    vs.formatos += Formato(st, u8(i + 3), "$nome-${if (ft and 0x80 != 0) "60Hz" else "50Hz"}")
                                }
                                st == 0x06 && len >= 4 -> vs.formatos += Formato(st, u8(i + 3), "MJPEG")
                                // VS_FORMAT_UNCOMPRESSED: o GUID começa pelo fourcc (NV12, YUY2, P010…).
                                st == 0x04 && len >= 21 -> {
                                    val cc = (0 until 4).map { u8(i + 5 + it) }
                                    val nome = if (cc.all { it in 0x20..0x7E }) cc.map { it.toChar() }.joinToString("") else "subtipo-0x04"
                                    vs.formatos += Formato(st, u8(i + 3), nome)
                                }
                                (st == 0x04 || st == 0x0A || st == 0x10 || st == 0x12) && len >= 4 ->
                                    vs.formatos += Formato(st, u8(i + 3), "subtipo-0x%02x".format(st))
                                // VS_FRAME_MJPEG (0x07) e VS_FRAME_UNCOMPRESSED (0x05), o mesmo leiaute:
                                // pertence ao formato (MJPEG ou não comprimido) que veio antes dele
                                (st == 0x07 || st == 0x05) && len >= 26 -> {
                                    val f = vs.formatos.lastOrNull()?.takeIf { it.subtipo == (if (st == 0x07) 0x06 else 0x04) }
                                    if (f != null) {
                                        val tipoInt = u8(i + 25)
                                        val continuo = tipoInt == 0
                                        val n = if (continuo) 3 else tipoInt
                                        val ints = (0 until n).map { 26 + 4 * it }
                                            .filter { it + 4 <= len }.map { u32(i + it) }
                                        f.quadros += Quadro(
                                            indice = u8(i + 3), largura = u16(i + 5), altura = u16(i + 7),
                                            intervaloPadrao = u32(i + 21), intervalos = ints,
                                            continuo = continuo, bufferMax = u32(i + 17),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    0x05 -> if (len >= 7 && ifClasse == 0x0E && ifSub == 0x02) {
                        val mps = u16(i + 4)
                        val psize = (mps and 0x7FF) * (1 + ((mps shr 11) and 3))
                        r.vss.getOrPut(ifNum) { Vs(ifNum) }.alts += Alt(ifAlt, u8(i + 2), u8(i + 3) and 3, psize)
                    }
                }
                i += len
            }
            return r
        }
    }
}

/** Probe/commit como o `uvcvideo` (`uvc_probe_video`/`uvc_commit_video`). */
class Negociacao(private val con: UsbDeviceConnection, private val vsNum: Int, bcdUvc: Int) {
    private val tamanho = when {
        bcdUvc >= 0x0150 -> 48
        bcdUvc >= 0x0110 -> 34
        else -> 26
    }

    private fun get(n: Int): ByteArray? {
        val b = ByteArray(n)
        val r = con.controlTransfer(0xA1, 0x81, 1 shl 8, vsNum, b, n, 1000)
        return if (r >= 26) b.copyOf(r) else null
    }

    private fun set(sel: Int, b: ByteArray): Boolean =
        con.controlTransfer(0x21, 0x01, sel shl 8, vsNum, b, b.size, 1000) == b.size

    /**
     * O que o commit fixou: o `dwMaxPayloadTransferSize`, o `dwMaxVideoFrameSize` e, no MJPEG, o
     * quadro que a câmera aceitou (o do `bFrameIndex` do GET_CUR).
     */
    class Negociado(val payloadMax: Long, val quadroMax: Long, val quadro: Quadro? = null)

    /**
     * Probe e commit; `null` se a câmera recusou o commit. Sem [quadro] (a DV), o `bFrameIndex` e o
     * `dwFrameInterval` ficam como vieram (o que a GS500 provou); com ele (o MJPEG), os dois vão
     * explícitos, com o `bmHint` dizendo que o intervalo é fixo, como o `uvcvideo`.
     */
    fun negociar(fmt: Formato, quadro: Int? = null, intervalo: Long? = null): Negociado? {
        val formato = fmt.indice
        val p = get(tamanho) ?: get(26) ?: ByteArray(tamanho)
        p[0] = 0; p[1] = 0
        p[2] = formato.toByte()
        if (quadro != null) {
            p[0] = 1  // bmHint: dwFrameInterval fixo
            p[3] = quadro.toByte()
            val iv = intervalo ?: 0L
            for (k in 0 until 4) p[4 + k] = ((iv shr (8 * k)) and 0xFF).toByte()
            if (!set(1, p)) Log.w("QuallDv", "SET_CUR(PROBE) do MJPEG recusado; seguindo com o commit do que a câmera tem")
        } else if (!set(1, p)) {
            // bFrameIndex e dwFrameInterval como vieram; se recusar, bFrameIndex 0 (o que o
            // uvcvideo manda em DV, pelo quadro fictício zerado).
            p[3] = 0
            if (!set(1, p)) Log.w("QuallDv", "SET_CUR(PROBE) recusado; seguindo com o commit")
        }
        val cur = get(p.size) ?: return null
        var max = u32(cur, 22)
        if ((max and 0xFFFF0000L) == 0xFFFF0000L) max = max and 0xFFFFL
        val quadroMax = u32(cur, 18)
        Log.i("QuallDv", "probe: formato ${cur[2].toInt() and 0xFF} quadro ${cur[3].toInt() and 0xFF} " +
            "intervalo ${u32(cur, 4)} quadro_max $quadroMax payload_max $max")
        var aceito: Quadro? = null
        if (quadro != null) {
            // MJPEG: o commit só vai com o formato pedido, e o tamanho é o do quadro que a câmera
            // aceitou (a revisão do código da P1, 1); nada de commit calado de outra coisa.
            aceito = quadroAceito(fmt, cur)
            if (aceito.indice != quadro) {
                Log.w("QuallDv", "a placa aceitou o quadro ${aceito.indice} (${aceito.largura}x${aceito.altura}) em vez do $quadro")
            }
        }
        return if (set(2, cur)) Negociado(max, quadroMax, aceito) else null
    }

    private fun u32(b: ByteArray, i: Int): Long =
        (0 until 4).fold(0L) { acc, k -> acc or ((b[i + k].toLong() and 0xFF) shl (8 * k)) }

    companion object {
        /**
         * O quadro que o GET_CUR do probe diz aceito (`bFrameIndex`), dentro de [fmt]. Lança
         * [IllegalStateException] com a frase se a câmera respondeu outro formato ou um quadro que
         * ela não descreve. Puro: testado em JVM.
         */
        fun quadroAceito(fmt: Formato, cur: ByteArray): Quadro {
            val f = cur[2].toInt() and 0xFF
            val qi = cur[3].toInt() and 0xFF
            if (f != fmt.indice) {
                throw IllegalStateException("a placa de captura respondeu o formato $f em vez do MJPEG (${fmt.indice}) na negociação")
            }
            return fmt.quadros.firstOrNull { it.indice == qi }
                ?: throw IllegalStateException("a placa de captura aceitou o quadro $qi, que ela não descreve")
        }
    }
}
