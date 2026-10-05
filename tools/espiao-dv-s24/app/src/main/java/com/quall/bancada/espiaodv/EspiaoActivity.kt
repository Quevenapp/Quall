package com.quall.bancada.espiaodv

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import android.widget.ScrollView
import android.widget.TextView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Espião DV de bancada: acha uma câmera UVC, pede a permissão USB, negocia o formato DV
 * (probe/commit), escolhe a alternativa isócrona e entrega o fd ao C, que conta quadros DV por
 * segundo no logcat (etiqueta `EspiaoDV`). A tela repete o log.
 *
 * `adb shell am start -n com.quall.bancada.espiaodv/.EspiaoActivity --ei segundos 30`
 *
 * A placa de captura (`docs/placa-de-captura-usb.md` P0): sem DV, o formato é o MJPEG. Extras:
 * `urbs` (12) e `pacotes` (64) por URB, `mmap` (0/1), `alt` (força a alternativa; 0 = pela banda),
 * `gravar` (no MJPEG, os N primeiros JPEG bons em `files/jpeg/`).
 */
class EspiaoActivity : Activity() {
    private lateinit var texto: TextView
    private lateinit var rolagem: ScrollView
    @Volatile private var rodando: Thread? = null
    private var gravar = 0
    private var nUrbs = 12
    private var nPacotes = 64
    private var usarMmap = false
    private var altForcada = 0
    private val caminhoGravacao get() = java.io.File(filesDir, "quadros.dv").path
    private val pastaJpeg get() = java.io.File(filesDir, "jpeg")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        texto = TextView(this).apply { textSize = 12f; setPadding(24, 48, 24, 24) }
        rolagem = ScrollView(this).apply { addView(texto) }
        setContentView(rolagem)
        val segundos = intent.getIntExtra("segundos", 30).coerceIn(2, 3600)
        gravar = intent.getIntExtra("gravar", 0).coerceIn(0, 600)
        nUrbs = intent.getIntExtra("urbs", 12).coerceIn(1, 256)
        nPacotes = intent.getIntExtra("pacotes", 64).coerceIn(1, 128)
        usarMmap = intent.getIntExtra("mmap", 0) == 1
        altForcada = intent.getIntExtra("alt", 0)
        volumeDoSom = intent.getIntExtra("volume", Int.MIN_VALUE)
        segundosDeSom = intent.getIntExtra("som", 0).coerceIn(0, 120)
        Nativo.compacto(intent.getIntExtra("compacto", 0) == 1)
        rodando = Thread({ corrida(segundos) }, "espiao-dv").also { it.start() }
    }

    override fun onDestroy() {
        Nativo.parar()
        super.onDestroy()
    }

    private fun log(s: String) {
        Log.i(ETIQUETA, s)
        runOnUiThread {
            texto.append(s + "\n")
            rolagem.post { rolagem.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    private fun corrida(segundos: Int) {
        log("espião DV: início (segundos=$segundos urbs=$nUrbs pacotes=$nPacotes mmap=$usarMmap alt=$altForcada gravar=$gravar)")
        try {
            val veredito = corridaDentro(segundos)
            log(veredito)
        } catch (t: Throwable) {
            log("VEREDITO falha: exceção ${t.javaClass.simpleName}: ${t.message}")
            Log.w(ETIQUETA, "exceção", t)
        }
        log("espião DV: fim")
    }

    private fun corridaDentro(segundos: Int): String {
        val usb = getSystemService(Context.USB_SERVICE) as UsbManager
        val todos = usb.deviceList.values.toList()
        for (d in todos) {
            val classes = (0 until d.interfaceCount).joinToString(",") {
                val f = d.getInterface(it)
                "%d/%02x.%02x".format(f.id, f.interfaceClass, f.interfaceSubclass)
            }
            log("USB: ${d.deviceName} ${"%04x:%04x".format(d.vendorId, d.productId)} " +
                "\"${d.productName ?: ""}\" interfaces(num/classe.sub)=[$classes]")
        }
        val uvc = todos.filter { d ->
            (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_VIDEO }
        }
        if (uvc.isEmpty()) {
            log("nenhum dispositivo UVC (${todos.size} aparelho(s) USB)")
            return "VEREDITO nenhum dispositivo UVC"
        }
        val dev = uvc.firstOrNull { it.vendorId == 0x04da } ?: uvc.first()
        log("escolhido: ${dev.deviceName} ${"%04x:%04x".format(dev.vendorId, dev.productId)}")

        if (!usb.hasPermission(dev) && !pedirPermissao(usb, dev)) {
            return "VEREDITO falha: permissão USB negada ou sem resposta em 120 s"
        }
        val con = usb.openDevice(dev) ?: return "VEREDITO falha: openDevice devolveu null"
        try {
            return comConexao(dev, con, segundos)
        } finally {
            con.close()
            log("conexão fechada (o kernel religa o uvcvideo)")
        }
    }

    private fun pedirPermissao(usb: UsbManager, dev: UsbDevice): Boolean {
        val acao = "$packageName.PERMISSAO_USB"
        val trava = CountDownLatch(1)
        var aceita = false
        val receptor = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                aceita = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                trava.countDown()
            }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receptor, IntentFilter(acao), Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receptor, IntentFilter(acao))
        }
        try {
            // Explícito (setPackage) e mutável: o UsbManager acrescenta os extras.
            val pi = PendingIntent.getBroadcast(
                this, 0, Intent(acao).setPackage(packageName), PendingIntent.FLAG_MUTABLE,
            )
            log("pedindo permissão USB: aceite o diálogo no aparelho")
            usb.requestPermission(dev, pi)
            if (!trava.await(120, TimeUnit.SECONDS)) {
                log("permissão USB: sem resposta em 120 s")
                return false
            }
            log("permissão USB: ${if (aceita) "aceita" else "negada"}")
            return aceita
        } finally {
            unregisterReceiver(receptor)
        }
    }

    /** `--ei volume N` (1/256 dB): escreve o volume de captura nos canais que o têm; sem ele, só lê. */
    private var volumeDoSom = Int.MIN_VALUE
    /** `--ei som N`: grava N segundos do som cru da placa em `files/som.pcm`, e não roda o vídeo. */
    private var segundosDeSom = 0

    /**
     * O valor atual (e a faixa do volume) de cada controle que as FEATURE_UNIT do som
     * declaram. A interface é do driver de som do kernel; se o usbfs recusar, o log diz.
     */
    private fun lerControlesDeSom(dev: UsbDevice, con: UsbDeviceConnection, d: Descritores) {
        val ac = d.acInterface ?: run { log("SOM: sem interface de controle"); return }
        // A interface é do snd-usb-audio: sem tomá-la, o usbfs recusa o pedido (-1, medido no S24).
        // force=true desliga o driver do som; a placa some do som do Android **até replugar**.
        val acIf = (0 until dev.interfaceCount).map { dev.getInterface(it) }.firstOrNull { it.id == ac }
        log("claimInterface AC $ac (force): ${acIf?.let { con.claimInterface(it, true) }}")
        val nomes = listOf("MUDO", "VOLUME", "GRAVE", "MÉDIO", "AGUDO", "EQUALIZADOR", "AGC", "ATRASO", "REFORÇO_DE_GRAVE", "LOUDNESS")
        for ((id, canais) in d.unidadesDeSom) for ((canal, bm) in canais.withIndex()) for (bit in nomes.indices) {
            if (bm and (1 shl bit) == 0) continue
            val cs = bit + 1
            val pedidos = if (cs == 2) listOf(0x81 to "CUR", 0x82 to "MIN", 0x83 to "MAX", 0x84 to "RES") else listOf(0x81 to "CUR")
            val n = if (cs == 2) 2 else 1
            val lidos = pedidos.joinToString(" ") { (req, nome) ->
                val b = ByteArray(n)
                val r = con.controlTransfer(0xA1, req, (cs shl 8) or canal, (id shl 8) or ac, b, n, 1000)
                if (r != n) "$nome=falhou($r)"
                else if (n == 2) { val v = ((b[0].toInt() and 0xFF) or (b[1].toInt() shl 8)).toShort().toInt(); "$nome=$v (%.2f dB)".format(v / 256.0) }
                else "$nome=${b[0].toInt() and 0xFF}"
            }
            log("SOM unidade $id canal $canal ${nomes[bit]}: $lidos")
            if (cs == 2 && volumeDoSom != Int.MIN_VALUE) {
                val b = byteArrayOf((volumeDoSom and 0xFF).toByte(), ((volumeDoSom shr 8) and 0xFF).toByte())
                val w = con.controlTransfer(0x21, 0x01, (cs shl 8) or canal, (id shl 8) or ac, b, 2, 1000)
                val c = ByteArray(2)
                val r = con.controlTransfer(0xA1, 0x81, (cs shl 8) or canal, (id shl 8) or ac, c, 2, 1000)
                val v = ((c[0].toInt() and 0xFF) or (c[1].toInt() shl 8)).toShort().toInt()
                log("SOM unidade $id canal $canal VOLUME escrito $volumeDoSom -> $w; relido($r)=$v (%.2f dB)".format(v / 256.0))
            }
        }
        if (segundosDeSom > 0) {
            // O fluxo de som: a alternativa com endpoint da interface AudioStreaming, e o endpoint dela.
            val asIf = (0 until dev.interfaceCount).map { dev.getInterface(it) }
                .firstOrNull { it.interfaceClass == 1 && it.interfaceSubclass == 2 && it.endpointCount > 0 }
            if (asIf == null) log("SOM: sem alternativa de fluxo com endpoint")
            else {
                val ep = asIf.getEndpoint(0)
                log("claimInterface AS ${asIf.id}: ${con.claimInterface(asIf, true)}; setInterface alt ${asIf.alternateSetting}: ${con.setInterface(asIf)}; " +
                    "endpoint 0x%02x psize ${ep.maxPacketSize}".format(ep.address))
                val arq = java.io.File(filesDir, "som.pcm").path
                log(Nativo.som(con.fileDescriptor, ep.address, ep.maxPacketSize, segundosDeSom, arq))
                (0 until dev.interfaceCount).map { dev.getInterface(it) }
                    .firstOrNull { it.id == asIf.id && it.alternateSetting == 0 }?.let { con.setInterface(it) }
                con.releaseInterface(asIf)
            }
        }
        // Devolve a interface: o Android religa o driver do som do kernel nela.
        log("releaseInterface AC $ac: ${acIf?.let { con.releaseInterface(it) }}")
    }

    private fun comConexao(dev: UsbDevice, con: UsbDeviceConnection, segundos: Int): String {
        val raw = con.rawDescriptors ?: return "VEREDITO falha: rawDescriptors null"
        val bcdUsb = if (raw.size >= 4) (raw[2].toInt() and 0xFF) or ((raw[3].toInt() and 0xFF) shl 8) else 0
        val vel = Nativo.velocidade(con.fileDescriptor)
        val nomeVel = when (vel) { 1 -> "baixa"; 2 -> "total (12 Mbit/s)"; 3 -> "alta (480 Mbit/s)"; 5, 6 -> "super"; else -> "?" }
        log("descritores: ${raw.size} bytes; bcdUSB %x.%02x; velocidade $vel = $nomeVel"
            .format(bcdUsb shr 8, bcdUsb and 0xFF))
        val d = Descritores.analisar(raw) { log(it) }
        lerControlesDeSom(dev, con, d)
        if (segundosDeSom > 0) return "VEREDITO som gravado (sem vídeo)"
        val vs = d.vsEscolhida() ?: return "VEREDITO falha: nenhuma interface VideoStreaming"
        val vcNum = d.vcInterface ?: return "VEREDITO falha: nenhuma interface VideoControl"
        val fmtDv = vs.formatos.firstOrNull { it.subtipo == 0x0C }
        val fmtMjpeg = vs.formatos.firstOrNull { it.subtipo == 0x06 }
        if (fmtDv == null) log("AVISO: a VS ${vs.numero} não tem formato DV; ${if (fmtMjpeg != null) "usando o MJPEG" else "usando o primeiro formato"}")
        val fmt = fmtDv ?: fmtMjpeg ?: vs.formatos.firstOrNull()
            ?: return "VEREDITO falha: a VS ${vs.numero} não tem formato"

        fun iface(num: Int, alt: Int): UsbInterface? = (0 until dev.interfaceCount)
            .map { dev.getInterface(it) }.firstOrNull { it.id == num && it.alternateSetting == alt }

        val vc = iface(vcNum, 0) ?: return "VEREDITO falha: interface VC $vcNum não achada"
        val vs0 = iface(vs.numero, 0) ?: return "VEREDITO falha: interface VS ${vs.numero} alt 0 não achada"
        // force=true: desliga o uvcvideo destas interfaces (USBDEVFS_DISCONNECT + CLAIMINTERFACE).
        // Soltas na ordem inversa (VS antes da VC): o uvcvideo casa pela VC e pega a VS no probe.
        log("claimInterface VC $vcNum: ${con.claimInterface(vc, true)}")
        val claimVs = con.claimInterface(vs0, true)
        log("claimInterface VS ${vs.numero}: $claimVs")
        if (!claimVs) return "VEREDITO falha: claimInterface da VS recusado"
        try {
            val neg = Negociacao(con, vs.numero, d.bcdUvc, ::log).negociar(fmt.indice)
                ?: return "VEREDITO falha: probe/commit recusado (ver o log acima)"
            val banda = neg.dwMaxPayloadTransferSize.let { if (it <= 0L) 1L else it }

            val ep = vs.endpointDoCabecalho
            // Como o kernel (uvc_video_start_transfer): mais de uma alternativa = isócrono.
            val nAlts = (0 until dev.interfaceCount).count { dev.getInterface(it).id == vs.numero }
            val altsIso = vs.alts.filter { it.alt > 0 && it.endpoint == ep && it.tipo == 1 }
                .sortedBy { it.psize }
            val bulk0 = vs.alts.firstOrNull { it.alt == 0 && it.endpoint == ep && it.tipo == 2 }
            log("VS ${vs.numero}: $nAlts alternativa(s); isócronas com o endpoint 0x%02x: ${altsIso.map { "${it.alt}:${it.psize}" }}; bulk na 0: ${bulk0 != null}".format(ep))
            val veredito: String
            if (nAlts > 1) {
                if (altsIso.isEmpty()) return "VEREDITO falha: $nAlts alternativas mas nenhuma isócrona com o endpoint 0x%02x".format(ep)
                val forcada = altsIso.firstOrNull { it.alt == altForcada }
                if (altForcada > 0 && forcada == null) log("AVISO: alternativa $altForcada não existe; pela banda")
                val candidatas = if (forcada != null) listOf(forcada) else altsIso.filter { it.psize >= banda }.ifEmpty {
                    log("AVISO: nenhuma alternativa com psize >= $banda; tentando da maior para a menor")
                    altsIso.reversed()
                }
                var escolhida: Alt? = null
                for (a in candidatas) {
                    val ui = iface(vs.numero, a.alt) ?: continue
                    val ok = con.setInterface(ui)
                    log("setInterface VS ${vs.numero} alt ${a.alt} (psize ${a.psize}): $ok")
                    if (ok) { escolhida = a; break }
                }
                val a = escolhida ?: return "VEREDITO falha: nenhuma alternativa aceita pelo setInterface"
                try {
                    val jpeg = fmt.subtipo == 0x06
                    if (jpeg) { pastaJpeg.deleteRecursively(); pastaJpeg.mkdirs() }
                    veredito = Nativo.rodar(con.fileDescriptor, ep, false, a.psize, 0, segundos,
                        gravar, if (jpeg) null else caminhoGravacao, nUrbs, nPacotes, usarMmap,
                        if (jpeg) pastaJpeg.path else null)
                } finally {
                    log("setInterface VS ${vs.numero} alt 0: ${con.setInterface(vs0)}")
                }
            } else if (bulk0 != null) {
                var tam = neg.dwMaxPayloadTransferSize
                if (tam <= 0L) { log("AVISO: dwMaxPayloadTransferSize 0 no bulk; URB de 16 KiB (fim de payload só pela URB curta)"); tam = 16384L }
                if (tam > (1L shl 20)) { log("AVISO: dwMaxPayloadTransferSize $tam no bulk; URB de 1 MiB"); tam = 1L shl 20 }
                veredito = Nativo.rodar(con.fileDescriptor, ep, true, 0, tam.toInt(), segundos, gravar,
                    caminhoGravacao, nUrbs, 1, usarMmap, null)
            } else {
                return "VEREDITO falha: endpoint 0x%02x sem alternativa isócrona nem bulk".format(ep)
            }
            return veredito
        } finally {
            con.releaseInterface(vs0)
            con.releaseInterface(vc)
        }
    }

    companion object { const val ETIQUETA = "EspiaoDV" }
}

data class Formato(val subtipo: Int, val indice: Int, val detalhe: String)
data class Alt(val alt: Int, val endpoint: Int, val tipo: Int, val wMaxPacketSize: Int, val psize: Int)

class Vs(val numero: Int) {
    var endpointDoCabecalho = -1
    val formatos = mutableListOf<Formato>()
    val alts = mutableListOf<Alt>()
}

class Descritores {
    var bcdUvc = 0x0100
    var vcInterface: Int? = null
    val vss = linkedMapOf<Int, Vs>()
    /** O som (UAC 1.0): a interface de controle e as FEATURE_UNIT (id → bmaControls por canal, o 0 é o mestre). */
    var acInterface: Int? = null
    val unidadesDeSom = linkedMapOf<Int, List<Int>>()

    fun vsEscolhida(): Vs? = vss.values.firstOrNull { v -> v.formatos.any { it.subtipo == 0x0C } }
        ?: vss.values.firstOrNull()

    companion object {
        private val NOMES_FORMATO = mapOf(
            0x04 to "UNCOMPRESSED", 0x06 to "MJPEG", 0x0A to "MPEG2TS", 0x0C to "DV",
            0x10 to "FRAME_BASED", 0x12 to "STREAM_BASED",
        )

        fun analisar(b: ByteArray, log: (String) -> Unit): Descritores {
            val r = Descritores()
            fun u8(i: Int) = b[i].toInt() and 0xFF
            fun u16(i: Int) = u8(i) or (u8(i + 1) shl 8)
            fun u32(i: Int) = u16(i).toLong() or (u16(i + 2).toLong() shl 16)
            var i = 0
            var ifNum = -1; var ifAlt = -1; var ifClasse = -1; var ifSub = -1
            while (i + 2 <= b.size) {
                val len = u8(i)
                val tipo = u8(i + 1)
                if (len < 2 || i + len > b.size) { log("descritor torto em $i (len $len)"); break }
                when (tipo) {
                    0x04 -> if (len >= 9) {
                        ifNum = u8(i + 2); ifAlt = u8(i + 3); ifClasse = u8(i + 5); ifSub = u8(i + 6)
                        log("interface $ifNum alt $ifAlt classe 0x%02x sub 0x%02x endpoints ${u8(i + 4)}"
                            .format(ifClasse, ifSub))
                        if (ifClasse == 0x0E && ifSub == 0x01) r.vcInterface = ifNum
                        if (ifClasse == 0x01 && ifSub == 0x01) r.acInterface = ifNum
                        if (ifClasse == 0x0E && ifSub == 0x02) r.vss.getOrPut(ifNum) { Vs(ifNum) }
                    }
                    0x24 -> if (ifClasse == 0x01 && ifSub == 0x01 && len >= 3) {
                        // As unidades do controle de som, cruas (a placa: há volume, mudo ou AGC? §13.9).
                        val st = u8(i + 2)
                        val nome = when (st) { 0x01 -> "HEADER"; 0x02 -> "INPUT_TERMINAL"; 0x03 -> "OUTPUT_TERMINAL"; 0x04 -> "MIXER_UNIT"; 0x05 -> "SELECTOR_UNIT"; 0x06 -> "FEATURE_UNIT"; else -> "subtipo 0x%02x".format(st) }
                        log("AC $nome: " + (0 until len).joinToString(" ") { "%02x".format(u8(i + it)) })
                        if (st == 0x06 && len >= 7) {
                            val tam = u8(i + 5)
                            if (tam in 1..2) r.unidadesDeSom[u8(i + 3)] = (0 until (len - 7) / tam).map { k ->
                                val o = i + 6 + k * tam
                                if (tam == 2) u16(o) else u8(o)
                            }
                        }
                    } else if (ifClasse == 0x01 && ifSub == 0x02 && len >= 8 && u8(i + 2) == 0x02) {
                        // UAC 1.0 FORMAT_TYPE_I: canais, bytes por amostra, bits, taxas.
                        val nTaxas = u8(i + 7)
                        val taxas = (0 until nTaxas).mapNotNull { k ->
                            val o = i + 8 + 3 * k
                            if (o + 3 <= i + len) u8(o) or (u8(o + 1) shl 8) or (u8(o + 2) shl 16) else null
                        }
                        log("SOM interface $ifNum alt $ifAlt: FORMAT_TYPE ${u8(i + 3)} canais ${u8(i + 4)} " +
                            "bytes/amostra ${u8(i + 5)} bits ${u8(i + 6)} taxas ${if (nTaxas == 0) "contínua" else taxas.joinToString(",")} Hz")
                    } else if (ifClasse == 0x0E && len >= 3) {
                        val st = u8(i + 2)
                        if (ifSub == 0x01 && st == 0x01 && len >= 5) {
                            r.bcdUvc = u16(i + 3)
                            log("VC_HEADER bcdUVC %x.%02x".format(r.bcdUvc shr 8, r.bcdUvc and 0xFF))
                        } else if (ifSub == 0x01) {
                            // As unidades da VC, cruas (a placa: há controle de padrão de vídeo? §10).
                            val nome = when (st) { 0x02 -> "INPUT_TERMINAL"; 0x03 -> "OUTPUT_TERMINAL"; 0x04 -> "SELECTOR"; 0x05 -> "PROCESSING_UNIT"; 0x06 -> "EXTENSION_UNIT"; else -> "subtipo 0x%02x".format(st) }
                            log("VC $nome id ${u8(i + 3)}: " + (0 until len).joinToString(" ") { "%02x".format(u8(i + it)) })
                        } else if (ifSub == 0x02) {
                            val vs = r.vss.getOrPut(ifNum) { Vs(ifNum) }
                            when {
                                st == 0x01 && len >= 7 -> {
                                    vs.endpointDoCabecalho = u8(i + 6)
                                    log("VS_INPUT_HEADER formatos ${u8(i + 3)} endpoint 0x%02x"
                                        .format(vs.endpointDoCabecalho))
                                }
                                st == 0x0C && len >= 9 -> {
                                    val ft = u8(i + 8)
                                    val nome = when (ft and 0x7F) { 0 -> "SD-DV"; 1 -> "SDL-DV"; 2 -> "HD-DV"; else -> "?" }
                                    val det = "$nome ${if (ft and 0x80 != 0) "60Hz" else "50Hz"} " +
                                        "bFormatType 0x%02x dwMaxVideoFrameBufferSize ${u32(i + 4)}".format(ft)
                                    vs.formatos += Formato(st, u8(i + 3), det)
                                    log("FORMAT_DV índice ${u8(i + 3)}: $det")
                                }
                                NOMES_FORMATO.containsKey(st) && len >= 4 -> {
                                    vs.formatos += Formato(st, u8(i + 3), NOMES_FORMATO[st]!!)
                                    // Não comprimido/frame-based: o GUID (o FourCC nos 4 primeiros bytes) e os bits por pixel.
                                    val extra = if ((st == 0x04 || st == 0x10) && len >= 22) {
                                        val cc = (0 until 4).map { u8(i + 5 + it).toChar() }.joinToString("")
                                        " fourcc '$cc' guid " + (0 until 16).joinToString("") { "%02x".format(u8(i + 5 + it)) } + " bpp ${u8(i + 21)}"
                                    } else ""
                                    log("FORMAT_${NOMES_FORMATO[st]} índice ${u8(i + 3)} (${len} bytes)$extra")
                                }
                                st == 0x05 || st == 0x07 || st == 0x11 -> if (len >= 9) {
                                    // VS_FRAME: intervalo padrão em 21, bFrameIntervalType em 25, e os intervalos.
                                    val extra = if (len >= 26) {
                                        val tipos = u8(i + 25)
                                        val ints = (0 until tipos).mapNotNull { k ->
                                            val o = i + 26 + 4 * k
                                            if (o + 4 <= i + len) u32(o) else null
                                        }
                                        " padrão ${u32(i + 21)} intervalos ${if (tipos == 0) "contínuos" else ints.joinToString(",")}"
                                    } else ""
                                    log("  FRAME subtipo 0x%02x índice ${u8(i + 3)} ${u16(i + 5)}x${u16(i + 7)}$extra".format(st))
                                }
                                else -> log("  VS CS subtipo 0x%02x (${len} bytes)".format(st))
                            }
                        }
                    }
                    0x05 -> if (len >= 7) {
                        val end = u8(i + 2)
                        val attr = u8(i + 3)
                        val mps = u16(i + 4)
                        val psize = (mps and 0x7FF) * (1 + ((mps shr 11) and 3))
                        log("  endpoint 0x%02x atributos 0x%02x wMaxPacketSize 0x%04x (psize $psize) intervalo ${u8(i + 6)}"
                            .format(end, attr, mps))
                        if (ifClasse == 0x0E && ifSub == 0x02) {
                            r.vss.getOrPut(ifNum) { Vs(ifNum) }.alts += Alt(ifAlt, end, attr and 3, mps, psize)
                        }
                    }
                    0x0B -> log("IAD primeira ${u8(i + 2)} n ${u8(i + 3)} classe 0x%02x".format(u8(i + 4)))
                }
                i += len
            }
            return r
        }
    }
}

/** Probe/commit como o `uvcvideo` (uvc_probe_video / uvc_commit_video). */
class Negociacao(
    private val con: UsbDeviceConnection,
    private val vsNum: Int,
    bcdUvc: Int,
    private val log: (String) -> Unit,
) {
    private val tamanho = when {
        bcdUvc >= 0x0150 -> 48
        bcdUvc >= 0x0110 -> 34
        else -> 26
    }

    class Resultado(val dwMaxVideoFrameSize: Long, val dwMaxPayloadTransferSize: Long)

    private fun hex(b: ByteArray, n: Int) = b.take(maxOf(n, 0)).joinToString(" ") { "%02x".format(it) }

    private fun get(req: Int, sel: Int, n: Int): ByteArray? {
        val b = ByteArray(n)
        val r = con.controlTransfer(0xA1, req, sel shl 8, vsNum, b, n, 1000)
        log("GET 0x%02x %s len $n -> $r: %s".format(req, if (sel == 1) "PROBE" else "COMMIT", hex(b, r)))
        return if (r >= 26) b.copyOf(r) else null
    }

    private fun set(sel: Int, b: ByteArray): Boolean {
        val r = con.controlTransfer(0x21, 0x01, sel shl 8, vsNum, b, b.size, 1000)
        log("SET_CUR %s len ${b.size} -> $r: %s".format(if (sel == 1) "PROBE" else "COMMIT", hex(b, b.size)))
        return r == b.size
    }

    fun negociar(formato: Int): Resultado? {
        // GET_CUR no tamanho da versão; se vier curto, 26 (UVC 1.0). O GET_CUR aqui é o que o
        // uvcvideo deixou; DEF/MIN/MAX só vão ao log.
        var cur = get(0x81, 1, tamanho) ?: get(0x81, 1, 26)
        val n = cur?.size ?: tamanho
        get(0x87, 1, n); get(0x82, 1, n); get(0x83, 1, n)
        val p = cur ?: ByteArray(tamanho)
        val tam = p.size
        p[0] = 0; p[1] = 0 // bmHint
        p[2] = formato.toByte()
        // bFrameIndex (p[3]) e dwFrameInterval como o aparelho disse; DV não tem quadro. Se o
        // aparelho recusar, de novo com bFrameIndex 0 (o que o uvcvideo manda em DV).
        if (!set(1, p)) {
            p[3] = 0
            if (!set(1, p)) log("AVISO: SET_CUR(PROBE) não aceito nem com bFrameIndex 0; seguindo")
        }
        cur = get(0x81, 1, tam) ?: return null
        var maxPayload = u32(cur, 22)
        if ((maxPayload and 0xFFFF0000L) == 0xFFFF0000L) {
            log("dwMaxPayloadTransferSize com 0xFFFF em cima (defeito conhecido); corrigido")
            maxPayload = maxPayload and 0xFFFFL
        }
        val r = Resultado(u32(cur, 18), maxPayload)
        log("probe final: formato ${cur[2].toInt() and 0xFF} quadro ${cur[3].toInt() and 0xFF} " +
            "dwFrameInterval ${u32(cur, 4)} dwMaxVideoFrameSize ${r.dwMaxVideoFrameSize} " +
            "dwMaxPayloadTransferSize ${r.dwMaxPayloadTransferSize}")
        if (!set(2, cur)) {
            log("SET_CUR(COMMIT) recusado")
            return null
        }
        return r
    }

    private fun u32(b: ByteArray, i: Int): Long =
        (0 until 4).fold(0L) { acc, k -> acc or ((b[i + k].toLong() and 0xFF) shl (8 * k)) }
}
