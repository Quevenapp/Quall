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
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Espião do leitor de DVD pelo USB (bancada; `docs/dvd-para-mp4.md`): acha a interface de
 * armazenamento (classe 8, bulk-only), pede a permissão, e manda comandos SCSI/MMC pelo
 * `bulkTransfer`, sem o kernel:
 *
 * - INQUIRY (quem é o leitor), TEST UNIT READY com REQUEST SENSE (o disco girando), READ CAPACITY;
 * - GET CONFIGURATION (o perfil do disco: DVD-ROM, DVD-R, DVD+RW…);
 * - READ DISC STRUCTURE formato 1 (**a proteção**: o CPST diz se o disco usa CSS/CPPM);
 * - READ(10) do setor 16 (o descritor ISO 9660) e a lista da raiz e de `VIDEO_TS`, com os tamanhos;
 * - a velocidade: N MB lidos em sequência do começo do maior VOB (só lidos, **nada é gravado**).
 *
 * `adb shell am start -n com.quall.bancada.espiaodv/.EspiaoDvdActivity --ei mb 32`
 */
class EspiaoDvdActivity : Activity() {
    private lateinit var texto: TextView
    private lateinit var rolagem: ScrollView
    private var setoresPorComando = 32
    private var velocidade = 0
    private var despejar = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        texto = TextView(this).apply { textSize = 12f; setPadding(24, 24, 24, 24) }
        rolagem = ScrollView(this).apply { addView(texto) }
        // O que está acontecendo agora, no alto, e a barra: sem isso a tela parece travada nos 30–60 s em que o
        // leitor acorda ou a leitura corre (o Pessoa Exemplo, 29/09).
        estado = TextView(this).apply { textSize = 16f; setPadding(24, 48, 24, 8); text = "Começando…" }
        barra = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true; max = 1000; setPadding(24, 0, 24, 8)
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // O Android 15+ desenha por baixo das barras (edge-to-edge com targetSdk 36): sem as margens do sistema,
            // a linha e a barra ficavam escondidas atrás do título (medido 29/09 pela hierarquia de views).
            setOnApplyWindowInsetsListener { v, ins ->
                val b = ins.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout())
                v.setPadding(b.left, b.top, b.right, b.bottom)
                ins
            }
            addView(estado); addView(barra)
            addView(rolagem, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        val mb = intent.getIntExtra("mb", 32).coerceIn(0, 1024)
        setoresPorComando = intent.getIntExtra("setores", 32).coerceIn(1, 512)
        velocidade = intent.getIntExtra("velocidade", 0)
        despejar = intent.getIntExtra("despejar", 0) == 1
        Thread({
            log("espião DVD: início (mb=$mb)")
            passo("Procurando o leitor…")
            try { log(corrida(mb)) } catch (t: Throwable) {
                log("VEREDITO falha: exceção ${t.javaClass.simpleName}: ${t.message}")
                Log.w(ETIQUETA, "exceção", t)
            }
            log("espião DVD: fim")
            passo("Terminado.", 1.0)
        }, "espiao-dvd").start()
    }

    private lateinit var estado: TextView
    private lateinit var barra: ProgressBar

    /** A linha do alto e a barra: `fracao` null = sem medida (a barra gira); 0..1 = a parte feita. */
    private fun passo(t: String, fracao: Double? = null) = runOnUiThread {
        estado.text = t
        if (fracao == null) barra.isIndeterminate = true
        else { barra.isIndeterminate = false; barra.progress = (fracao * 1000).toInt().coerceIn(0, 1000) }
    }

    private fun log(s: String) {
        Log.i(ETIQUETA, s)
        runOnUiThread {
            texto.append(s + "\n")
            rolagem.post { rolagem.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    private fun corrida(mb: Int): String {
        val usb = getSystemService(Context.USB_SERVICE) as UsbManager
        val dev = usb.deviceList.values.firstOrNull { d ->
            (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_MASS_STORAGE }
        } ?: return "VEREDITO falha: nenhum aparelho de armazenamento USB (${usb.deviceList.size} aparelho(s))"
        log("USB: ${dev.deviceName} %04x:%04x \"${dev.manufacturerName} ${dev.productName}\"".format(dev.vendorId, dev.productId))
        val itf = (0 until dev.interfaceCount).map { dev.getInterface(it) }
            .first { it.interfaceClass == UsbConstants.USB_CLASS_MASS_STORAGE }
        log("interface ${itf.id}: classe 8 subclasse ${itf.interfaceSubclass} protocolo 0x%02x".format(itf.interfaceProtocol))
        if (itf.interfaceProtocol != 0x50) return "VEREDITO falha: não é bulk-only (protocolo 0x%02x)".format(itf.interfaceProtocol)
        var epIn: UsbEndpoint? = null
        var epOut: UsbEndpoint? = null
        for (i in 0 until itf.endpointCount) {
            val e = itf.getEndpoint(i)
            if (e.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
            if (e.direction == UsbConstants.USB_DIR_IN) epIn = e else epOut = e
        }
        if (epIn == null || epOut == null) return "VEREDITO falha: sem os dois endpoints bulk"
        if (!usb.hasPermission(dev) && !pedirPermissao(usb, dev)) return "VEREDITO falha: permissão USB negada"
        val con = usb.openDevice(dev) ?: return "VEREDITO falha: openDevice null"
        try {
            if (intent.getIntExtra("reset", 0) == 1) {
                log("USBDEVFS_RESET: ${Nativo.resetar(con.fileDescriptor)}")
                Thread.sleep(1500)
            }
            log("claimInterface (force): ${con.claimInterface(itf, true)}")
            val s = Scsi(con, epIn, epOut, itf.id)
            // Sem a recuperação preventiva: o reset da classe fazia o leitor reinicializar e ficar ~60 s mudo (29/09).
            return comLeitor(s, mb)
        } finally {
            con.releaseInterface(itf)
            con.close()
        }
    }

    private fun comLeitor(s: Scsi, mb: Int): String {
        passo("Falando com o leitor (pode levar até 1 min)…")
        s.comando(byteArrayOf(0x12, 0, 0, 0, 36, 0), 36)?.let { b ->
            val fab = String(b, 8, 8).trim(); val prod = String(b, 16, 16).trim(); val rev = String(b, 32, 4).trim()
            log("INQUIRY: tipo 0x%02x (5 = CD/DVD) \"$fab\" \"$prod\" rev $rev".format(b[0].toInt() and 0x1F))
        } ?: log("INQUIRY falhou")

        passo("Esperando o disco girar (até 30 s)…")
        // O disco girando: TEST UNIT READY até 30 s, com o sense de cada recusa.
        val t0 = SystemClock.elapsedRealtime()
        var pronto = false
        var ultimoSense = ""
        while (SystemClock.elapsedRealtime() - t0 < 30_000) {
            if (s.comando(ByteArray(6), 0) != null) { pronto = true; break }
            val sense = s.comando(byteArrayOf(0x03, 0, 0, 0, 18, 0), 18)
            val txt = sense?.let { "chave 0x%x ASC 0x%02x ASCQ 0x%02x".format(it[2].toInt() and 0xF, it[12].toInt() and 0xFF, it[13].toInt() and 0xFF) } ?: "sem sense"
            if (txt != ultimoSense) { log("não pronto: $txt"); ultimoSense = txt }
            if (sense != null && (sense[12].toInt() and 0xFF) == 0x3A) return "VEREDITO sem disco (ASC 0x3A: ponha um DVD)"
            Thread.sleep(500)
        }
        log("pronto: $pronto em ${SystemClock.elapsedRealtime() - t0} ms")
        if (!pronto) return "VEREDITO falha: o leitor não ficou pronto em 30 s ($ultimoSense)"

        val cap = s.comando(byteArrayOf(0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0), 8)
        val ultimo = cap?.let { ByteBuffer.wrap(it).int.toLong() and 0xFFFFFFFFL } ?: -1
        val bloco = cap?.let { ByteBuffer.wrap(it, 4, 4).int } ?: 0
        passo("Lendo o disco e o índice…")
        log("READ CAPACITY: último LBA $ultimo, bloco $bloco (${(ultimo + 1) * bloco / 1_000_000} MB)")

        s.comando(byteArrayOf(0x46, 0x02, 0, 0, 0, 0, 0, 0, 8, 0), 8)?.let { b ->
            val perfil = ((b[6].toInt() and 0xFF) shl 8) or (b[7].toInt() and 0xFF)
            val nome = mapOf(0x08 to "CD-ROM", 0x09 to "CD-R", 0x0A to "CD-RW", 0x10 to "DVD-ROM", 0x11 to "DVD-R",
                0x12 to "DVD-RAM", 0x13 to "DVD-RW (sobrescrita)", 0x14 to "DVD-RW (sequencial)", 0x15 to "DVD-R DL",
                0x1A to "DVD+RW", 0x1B to "DVD+R", 0x2B to "DVD+R DL", 0x40 to "BD-ROM")[perfil] ?: "?"
            log("GET CONFIGURATION: perfil atual 0x%04x ($nome)".format(perfil))
        } ?: log("GET CONFIGURATION falhou")

        // O tipo do disco por outras fontes (o Pessoa Exemplo, 29/09: um DVD-R TDK saiu como "DVD-ROM" no perfil atual).
        // (a) a lista de perfis inteira (cada um com o bit "atual");
        s.comando(byteArrayOf(0x46, 0x00, 0, 0, 0, 0, 0, 0x01, 0, 0), 256)?.let { b ->
            val tam = ByteBuffer.wrap(b).int
            val perfis = mutableListOf<String>()
            if ((b[8].toInt() and 0xFF) == 0 && (b[9].toInt() and 0xFF) == 0) {  // a feature 0000: a lista de perfis
                val n = (b[11].toInt() and 0xFF) / 4
                for (k in 0 until n) {
                    val o = 12 + 4 * k
                    if (o + 3 >= b.size) break
                    val p = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)
                    perfis += "0x%04x%s".format(p, if (b[o + 2].toInt() and 1 != 0) "*" else "")
                }
            }
            log("GET CONFIGURATION (todas): tamanho $tam, perfis ${perfis.joinToString(" ")} (* = atual)")
        } ?: log("GET CONFIGURATION (todas) falhou")
        // (b) o book type e a versão da parte física (READ DISC STRUCTURE formato 0);
        s.comando(byteArrayOf(0xAD.toByte(), 0, 0, 0, 0, 0, 0, 0x00, 0x08, 0x04, 0, 0), 2052)?.let { b ->
            val book = (b[4].toInt() and 0xF0) shr 4
            val nome = mapOf(0 to "DVD-ROM", 1 to "DVD-RAM", 2 to "DVD-R", 3 to "DVD-RW", 9 to "DVD+RW", 0xA to "DVD+R", 0xE to "DVD+R DL")[book] ?: "?"
            log("READ DISC STRUCTURE (física): book type $book ($nome), versão ${b[4].toInt() and 0xF}, camadas ${((b[6].toInt() shr 5) and 3) + 1}")
        } ?: log("READ DISC STRUCTURE (física) falhou")
        // (c) o disco gravável: READ DISC INFORMATION (estado, apagável).
        s.comando(byteArrayOf(0x51, 0, 0, 0, 0, 0, 0, 0, 34, 0), 34)?.let { b ->
            val estado = b[2].toInt() and 3
            val apagavel = (b[2].toInt() shr 4) and 1
            log("READ DISC INFORMATION: estado ${when (estado) { 0 -> "vazio"; 1 -> "incompleto"; 2 -> "finalizado"; else -> "outro" }}, apagável $apagavel")
        } ?: log("READ DISC INFORMATION falhou (disco prensado responde assim em muitos leitores)")
        // (d) o fabricante da mídia gravável (READ DISC STRUCTURE formato 0x0E, pre-recorded info do DVD-R).
        s.comando(byteArrayOf(0xAD.toByte(), 0, 0, 0, 0, 0, 0, 0x0E, 0, 108, 0, 0), 108)?.let { b ->
            val txt = String(b, 4, 104, Charsets.ISO_8859_1).filter { it.code in 32..126 }
            log("READ DISC STRUCTURE (0x0E, fabricante DVD-R): \"$txt\"")
        } ?: log("READ DISC STRUCTURE 0x0E falhou")

        // A proteção: READ DISC STRUCTURE, formato 0x01 (copyright). CPST: 0 nenhuma, 1 CSS/CPPM, 2 CPRM.
        var protegido: Boolean? = null
        s.comando(byteArrayOf(0xAD.toByte(), 0, 0, 0, 0, 0, 0, 0x01, 0, 8, 0, 0), 8)?.let { b ->
            val cpst = b[4].toInt() and 0xFF
            protegido = cpst != 0
            log("READ DISC STRUCTURE (copyright): CPST $cpst (${when (cpst) { 0 -> "sem proteção"; 1 -> "CSS/CPPM"; 2 -> "CPRM"; else -> "?" }}), regiões 0x%02x".format(b[5].toInt() and 0xFF))
        } ?: log("READ DISC STRUCTURE falhou (disco não DVD, ou o leitor recusa)")

        // ISO 9660: o descritor primário no setor 16, a raiz, e VIDEO_TS.
        val pvd = s.ler(16, 1) ?: return "VEREDITO falha: READ(10) do setor 16"
        val ident = String(pvd, 1, 5)
        log("setor 16: tipo ${pvd[0].toInt() and 0xFF} ident \"$ident\" volume \"${String(pvd, 40, 32).trim()}\"")
        var maiorVob: Pair<Long, Long>? = null
        if (ident == "CD001") {
            val raiz = registro(pvd, 156)
            val entradas = listar(s, raiz.first, raiz.second)
            log("raiz: " + entradas.joinToString(", ") { "${it.nome}${if (it.dir) "/" else " (${it.tamanho / 1_000_000} MB)"}" })
            entradas.firstOrNull { it.dir && it.nome.equals("VIDEO_TS", true) }?.let { vts ->
                val arquivos = listar(s, vts.lba, vts.tamanho)
                for (a in arquivos) log("  VIDEO_TS/${a.nome}  ${a.tamanho} bytes  (LBA ${a.lba})")
                arquivos.filter { it.nome.uppercase().endsWith(".VOB") }.maxByOrNull { it.tamanho }?.let { maiorVob = it.lba to it.tamanho }
                val vobs = arquivos.filter { it.nome.uppercase().endsWith(".VOB") }
                log("VIDEO_TS: ${vobs.size} VOB, ${vobs.sumOf { it.tamanho } / 1_000_000} MB de vídeo")
            } ?: log("sem VIDEO_TS na raiz (não é DVD-Video, ou é só UDF)")
        } else {
            log("sem ISO 9660 no setor 16 (só UDF? a próxima versão lê o âncora do setor 256)")
        }

        // A velocidade pedida ao leitor (a "fonte forte", 29/09): o GET PERFORMANCE diz o que ele faz; o SET CD SPEED
        // pede a leitura em kB/s (1× DVD = 1385 kB/s; 0xFFFF = o máximo). `velocidade` = 0 não pede nada.
        s.comando(byteArrayOf(0xAC.toByte(), 0x10, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0), 24)?.let { b ->
            val ini = ByteBuffer.wrap(b, 12, 4).int; val fim = ByteBuffer.wrap(b, 20, 4).int
            log("GET PERFORMANCE: leitura de $ini a $fim kB/s (%.1fx a %.1fx DVD)".format(ini / 1385.0, fim / 1385.0))
        } ?: log("GET PERFORMANCE falhou")
        if (velocidade > 0) {
            val v = velocidade.coerceAtMost(0xFFFF)
            val ok = s.comando(byteArrayOf(0xBB.toByte(), 0, (v shr 8).toByte(), v.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0, 0, 0, 0, 0, 0), 0) != null
            log("SET CD SPEED leitura $v kB/s: ${if (ok) "aceito" else "recusado"}")
        }

        // A velocidade: `mb` MB do maior VOB (ou do começo do disco), em blocos de 32 setores (64 KB).
        if (mb > 0) {
            val inicio = maiorVob?.first ?: 0L
            val total = mb * 1_000_000L / 2048
            var lidos = 0L
            var erros = 0
            val t1 = SystemClock.elapsedRealtime()
            passo("Lendo ${mb} MB…", 0.0)
            val despejo = if (despejar) java.io.FileOutputStream(java.io.File(filesDir, "trecho.vob")) else null
            while (lidos < total) {
                if (lidos % (setoresPorComando * 16L) == 0L) {
                    val feito = lidos * 2048 / 1_000_000
                    val seg = (SystemClock.elapsedRealtime() - t1) / 1000.0
                    passo("Lendo: $feito de $mb MB" + if (seg > 1) " (%.1f MB/s)".format(feito / seg) else "", lidos.toDouble() / total)
                }
                val n = minOf(setoresPorComando.toLong(), total - lidos).toInt()
                val bloco = s.ler(inicio + lidos, n)
                if (bloco == null) { erros++; if (erros > 5) break }
                // `despejar` = 1: os bytes crus lidos vão a files/trecho.vob (bancada: decodificar no Mac e apagar).
                else if (despejar) despejo?.write(bloco)
                lidos += n
            }
            despejo?.close()
            val ms = SystemClock.elapsedRealtime() - t1
            val mbs = lidos * 2048 / 1_000_000.0 / (ms / 1000.0)
            log("leitura ($setoresPorComando setores por comando): ${lidos * 2048 / 1_000_000} MB em $ms ms = %.2f MB/s (%.1fx DVD), erros $erros, recuperações ${s.recuperacoes}".format(mbs, mbs / 1.385))
        }
        return "VEREDITO ok: protegido=${protegido ?: "?"}; maior VOB ${maiorVob?.second?.div(1_000_000) ?: "-"} MB"
    }

    private data class Entrada(val nome: String, val lba: Long, val tamanho: Long, val dir: Boolean)

    private fun registro(b: ByteArray, off: Int): Pair<Long, Long> {
        val bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
        return (bb.getInt(off + 2).toLong() and 0xFFFFFFFFL) to (bb.getInt(off + 10).toLong() and 0xFFFFFFFFL)
    }

    private fun listar(s: Scsi, lba: Long, tamanho: Long): List<Entrada> {
        val setores = ((tamanho + 2047) / 2048).toInt().coerceIn(1, 64)
        val d = s.ler(lba, setores) ?: return emptyList()
        val lista = mutableListOf<Entrada>()
        var i = 0
        while (i < d.size) {
            val len = d[i].toInt() and 0xFF
            if (len == 0) { i = ((i / 2048) + 1) * 2048; continue }
            if (i + len > d.size || len < 34) break
            val (l, t) = registro(d, i)
            val flags = d[i + 25].toInt() and 0xFF
            val nlen = d[i + 32].toInt() and 0xFF
            val nome = String(d, i + 33, nlen, Charsets.ISO_8859_1).substringBefore(';')
            if (nlen == 1 && (d[i + 33].toInt() == 0 || d[i + 33].toInt() == 1)) { i += len; continue }  // . e ..
            lista += Entrada(nome, l, t, flags and 2 != 0)
            i += len
        }
        return lista
    }

    private fun pedirPermissao(usb: UsbManager, dev: UsbDevice): Boolean {
        val acao = "$packageName.PERMISSAO_USB_DVD"
        val trava = CountDownLatch(1)
        var aceita = false
        val receptor = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                aceita = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false); trava.countDown()
            }
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receptor, IntentFilter(acao), Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(receptor, IntentFilter(acao))
        try {
            val pi = PendingIntent.getBroadcast(this, 1, Intent(acao).setPackage(packageName), PendingIntent.FLAG_MUTABLE)
            log("pedindo permissão USB: aceite o diálogo no aparelho")
            passo("Aceite a permissão do USB na tela…")
            usb.requestPermission(dev, pi)
            if (!trava.await(120, TimeUnit.SECONDS)) return false
            log("permissão USB: ${if (aceita) "aceita" else "negada"}")
            return aceita
        } finally { unregisterReceiver(receptor) }
    }

    /** Bulk-only transport: CBW, dado, CSW. `null` quando o CSW não diz sucesso. */
    private class Scsi(val con: UsbDeviceConnection, val epIn: UsbEndpoint, val epOut: UsbEndpoint, val itf: Int) {
        private var tag = 1
        var recuperacoes = 0

        /** A recuperação do bulk-only (a especificação, 5.3.4): o reset da classe e o CLEAR_FEATURE(HALT) dos dois endpoints. */
        fun recuperar() {
            recuperacoes++
            val r = con.controlTransfer(0x21, 0xFF, 0, itf, null, 0, 2000)
            val a = con.controlTransfer(0x02, 0x01, 0, epIn.address, null, 0, 2000)
            val b = con.controlTransfer(0x02, 0x01, 0, epOut.address, null, 0, 2000)
            Log.i(ETIQUETA, "recuperação do bulk-only: reset=$r halt_in=$a halt_out=$b")
        }

        fun comando(cdb: ByteArray, bytesIn: Int): ByteArray? {
            val r = comandoCru(cdb, bytesIn)
            if (r == null && cdb[0].toInt() != 0x00 && cdb[0].toInt() != 0x03) recuperar()
            return r
        }

        private fun comandoCru(cdb: ByteArray, bytesIn: Int): ByteArray? {
            val cbw = ByteBuffer.allocate(31).order(ByteOrder.LITTLE_ENDIAN)
            cbw.putInt(0x43425355).putInt(tag++).putInt(bytesIn).put(if (bytesIn > 0) 0x80.toByte() else 0)
                .put(0).put(cdb.size.toByte()).put(cdb.copyOf(16))
            if (con.bulkTransfer(epOut, cbw.array(), 31, 5000) != 31) { recuperar(); return null }
            val dado = ByteArray(bytesIn)
            var got = 0
            while (got < bytesIn) {
                val n = con.bulkTransfer(epIn, dado, got, bytesIn - got, 20000)
                if (n <= 0) break
                got += n
            }
            val csw = ByteArray(13)
            var n = con.bulkTransfer(epIn, csw, 13, 20000)
            if (n != 13) n = con.bulkTransfer(epIn, csw, 13, 20000)  // um dado curto pode vir antes
            if (n != 13) return null
            return if (csw[12].toInt() == 0) dado else null
        }

        fun ler(lba: Long, setores: Int): ByteArray? {
            val cdb = byteArrayOf(0x28, 0, (lba shr 24).toByte(), (lba shr 16).toByte(), (lba shr 8).toByte(), lba.toByte(),
                0, (setores shr 8).toByte(), setores.toByte(), 0)
            return comando(cdb, setores * 2048)
        }
    }

    companion object { const val ETIQUETA = "EspiaoDVD" }
}
