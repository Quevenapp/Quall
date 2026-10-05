package com.quall.android.dvd

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.SystemClock
import com.quall.android.core.LogSeguro as Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Quem lê setores de 2048 bytes: o leitor de verdade, ou um disco de mentira nos testes. */
interface Setores {
    /** [n] setores a partir de [lba]; exceção se não leu (as de [LeitorDeDisco] dizem por quê). */
    fun ler(lba: Long, n: Int): ByteArray
}

/**
 * O disco foi recusado: a [recusa] vai para a tela no idioma de quem desenha ([Frase.em]); o detalhe,
 * para o diário.
 */
class RecusaDoDisco(val recusa: Frase, detalhe: String = Recusas.emPortugues(recusa)) : Exception(detalhe) {
    /**
     * **Compatibilidade, para sair**: a recusa em português, como `String`, para o `MirrorService` (que
     * ainda lê `e.frase`). Quem desenha usa [recusa].
     */
    val frase: String get() = Recusas.emPortugues(recusa)
}

/** O leitor parou de responder (§1.1): só religando a energia. */
class LeitorParou(detalhe: String) : Exception(detalhe)

/**
 * **As regras do disco que falham fechado** (`docs/dvd-para-mp4.md` §2.1 e a revisão, 1–3), fora do
 * USB para os testes JVM.
 */
object PoliticaDoDisco {
    /** Os perfis graváveis do MMC (DVD-R, -RAM, -RW, -R DL, +RW, +R, +RW DL, +R DL). */
    private val GRAVAVEIS = setOf(0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x1A, 0x1B, 0x2A, 0x2B)

    /** Só o disco gravável pode ter setor pulado; o perfil desconhecido é tratado como prensado. */
    fun gravavel(perfil: Int?): Boolean = perfil != null && perfil in GRAVAVEIS

    /**
     * **O tipo pelo próprio disco** (o *book type* do READ DISC STRUCTURE formato 0, a parte física):
     * 0 DVD-ROM, 1 DVD-RAM, 2 DVD-R, 3 DVD-RW, 9 DVD+RW, 0xA DVD+R, 0xD DVD+RW DL, 0xE DVD+R DL. **Medido em
     * 29/09**: o hp GTB0N declara o perfil atual 0x0010 (DVD-ROM) para um DVD-R TDK **finalizado**, e o book
     * type diz 2 (DVD-R) — o perfil sozinho chamava de "prensado" o disco gravado em casa do Pessoa Exemplo. O book type
     * manda quando é legível; o perfil fica de reserva. Um DVD+R com o book type trocado para DVD-ROM
     * (*bitsetting*) cai como prensado, que é o lado seguro.
     */
    fun gravavel(perfil: Int?, book: Int?): Boolean =
        if (book != null) book in BOOKS_GRAVAVEIS else gravavel(perfil)

    private val BOOKS_GRAVAVEIS = setOf(1, 2, 3, 9, 0xA, 0xD, 0xE)

    fun nomeDoBook(book: Int?): String? = when (book) {
        0 -> "DVD-ROM"; 1 -> "DVD-RAM"; 2 -> "DVD-R"; 3 -> "DVD-RW"; 9 -> "DVD+RW"; 0xA -> "DVD+R"
        0xD -> "DVD+RW DL"; 0xE -> "DVD+R DL"; else -> null
    }

    fun nomeDoPerfil(perfil: Int?): String = when (perfil) {
        null -> "desconhecido"
        0x08 -> "CD-ROM"; 0x09 -> "CD-R"; 0x0A -> "CD-RW"
        0x10 -> "DVD-ROM"; 0x11 -> "DVD-R"; 0x12 -> "DVD-RAM"; 0x13 -> "DVD-RW (sobrescrita)"
        0x14 -> "DVD-RW (sequencial)"; 0x15 -> "DVD-R DL"; 0x16 -> "DVD-R DL (salto)"
        0x1A -> "DVD+RW"; 0x1B -> "DVD+R"; 0x2A -> "DVD+RW DL"; 0x2B -> "DVD+R DL"
        0x40 -> "BD-ROM"
        else -> "perfil 0x%04x".format(perfil)
    }

    /**
     * O CPST do READ DISC STRUCTURE (formato 1): **ilegível ou diferente de 0 recusa** — 1 é
     * CSS/CPPM, 2 é CPRM, e qualquer outro valor é desconhecido. `null` é ilegível.
     */
    fun recusaPeloCpst(cpst: Int?): Boolean = cpst != 0

    /** O sense de proteção (ASC 0x6F: a troca de chaves, o setor cifrado sem autenticação). */
    fun senseDeProtecao(asc: Int): Boolean = asc == 0x6F

    /** UNIT ATTENTION "o meio pode ter mudado" (ASC 0x28) numa leitura: o disco foi trocado. */
    fun senseDeDiscoTrocado(asc: Int): Boolean = asc == 0x28

    /** O que fazer com o bloco que não leu em três tentativas: pular (gravável) ou recusar (prensado). */
    fun pulaBlocoRuim(gravavel: Boolean): Boolean = gravavel
}

/**
 * **O leitor de DVD pelo USB, sem o kernel** (`docs/dvd-para-mp4.md` §2.2, a D2): o bulk-only do
 * espião que funcionou (§1: o CBW, o dado e o CSW pelo `bulkTransfer`), a recuperação (o reset da
 * classe e os dois `CLEAR_FEATURE(HALT)`), e o READ(10) **fixo em 64 KB** (§1.1: 256 setores
 * travaram o leitor até religar a energia; a revisão, 4).
 *
 * - **o bloco ruim**: três tentativas; depois, no gravável, o bloco é pulado (zeros, contado); no
 *   prensado, [RecusaDoDisco] (setor ilegível de propósito é proteção estrutural; a revisão, 2);
 * - **o sense 0x6F** numa leitura: [RecusaDoDisco] (proteção);
 * - **o leitor que não responde**: [LeitorParou] (três falhas de transporte seguidas, cada uma com a
 *   recuperação).
 *
 * Uma thread só usa um leitor (o bulk-only é um comando por vez).
 */
/** A espera depois da recuperação do bulk-only (ver `transporte`). */
private const val ESPERA_DEPOIS_DO_RESET_MS = 1_000L

class LeitorDeDisco private constructor(
    private val con: UsbDeviceConnection,
    private val itf: UsbInterface,
    private val epIn: UsbEndpoint,
    private val epOut: UsbEndpoint,
    val dispositivo: UsbDevice,
) : Setores, AutoCloseable {
    private var tag = 1
    var recuperacoes = 0
        private set
    var blocosPulados = 0L
        private set
    var setoresPulados = 0L
        private set
    var tentativasRepetidas = 0L
        private set
    private var falhasDeTransporte = 0
    /** Definido depois de [conferir]: só o gravável pula bloco. */
    var gravavel = false
        private set

    /** O tipo do disco para a tela ("DVD-R", "DVD-ROM"…), depois de [conferir]. */
    var nome: String = "desconhecido"
        private set

    // ---- o bulk-only ---------------------------------------------------------------------------

    private sealed class Resposta {
        class Ok(val dados: ByteArray) : Resposta()
        /** O CSW disse falha (status 1): o sense diz por quê. */
        object Falhou : Resposta()
        /** O transporte falhou (sem CSW, ou erro de fase): houve recuperação. */
        object Transporte : Resposta()
    }

    /** A recuperação do bulk-only (a especificação, 5.3.4). `false` se o aparelho nem responde. */
    private fun recuperar(): Boolean {
        recuperacoes++
        val r = con.controlTransfer(0x21, 0xFF, 0, itf.id, null, 0, 2000)
        val a = con.controlTransfer(0x02, 0x01, 0, epIn.address, null, 0, 2000)
        val b = con.controlTransfer(0x02, 0x01, 0, epOut.address, null, 0, 2000)
        Log.i(TAG, "recuperação do bulk-only: reset=$r halt_in=$a halt_out=$b")
        // **O leitor precisa de ~1 s depois do reset** (medido no A07, 29/09: o hp GTB0N recusa o 1º comando
        // depois da recuperação e responde ao seguinte; sem a espera, cada falha resetava de novo e as três
        // tentativas caíam dentro do mesmo religamento — "o leitor não responde" com o leitor bom).
        Thread.sleep(ESPERA_DEPOIS_DO_RESET_MS)
        return r >= 0 || a >= 0 || b >= 0
    }

    private fun executar(cdb: ByteArray, bytesIn: Int, prazoMs: Int = 20_000): Resposta {
        val cbw = ByteBuffer.allocate(31).order(ByteOrder.LITTLE_ENDIAN)
        val meuTag = tag++
        cbw.putInt(0x43425355).putInt(meuTag).putInt(bytesIn).put(if (bytesIn > 0) 0x80.toByte() else 0)
            .put(0).put(cdb.size.toByte()).put(cdb.copyOf(16))
        if (con.bulkTransfer(epOut, cbw.array(), 31, 5000) != 31) return transporte("CBW")
        val dado = ByteArray(bytesIn)
        var got = 0
        while (got < bytesIn) {
            val n = con.bulkTransfer(epIn, dado, got, bytesIn - got, prazoMs)
            if (n <= 0) {
                // O leitor pode parar o dado (STALL) numa falha: limpa o halt e vai ao CSW.
                con.controlTransfer(0x02, 0x01, 0, epIn.address, null, 0, 2000)
                break
            }
            got += n
        }
        val csw = ByteArray(13)
        var n = con.bulkTransfer(epIn, csw, 13, prazoMs)
        if (n != 13) n = con.bulkTransfer(epIn, csw, 13, prazoMs)  // um dado curto pode vir antes
        if (n != 13) return transporte("CSW")
        // A assinatura "USBS" e o tag do CBW (a revisão do código, 8): um CSW que não é deste comando
        // é o protocolo fora de passo, e não uma resposta.
        val cb = ByteBuffer.wrap(csw).order(ByteOrder.LITTLE_ENDIAN)
        if (cb.getInt(0) != 0x53425355 || cb.getInt(4) != meuTag) {
            return transporte("CSW inválido (assinatura 0x%08x, tag %d em vez de %d)".format(cb.getInt(0), cb.getInt(4), meuTag)) // i18n-fora: diário (o detalhe do LeitorParou)
        }
        val status = csw[12].toInt() and 0xFF
        return when {
            status == 0 && got == bytesIn -> { falhasDeTransporte = 0; Resposta.Ok(dado) }
            status == 0 || status == 1 -> { falhasDeTransporte = 0; Resposta.Falhou }
            else -> transporte("erro de fase (CSW $status)")
        }
    }

    private fun transporte(onde: String): Resposta {
        falhasDeTransporte++
        Log.w(TAG, "bulk-only: falha no $onde ($falhasDeTransporte seguida(s))")
        if (!recuperar() || falhasDeTransporte >= 3) {
            throw LeitorParou("o leitor não responde ($onde, $falhasDeTransporte falhas seguidas)")
        }
        return Resposta.Transporte
    }

    /** O sense da última falha: (chave, ASC, ASCQ), ou `null`. */
    private fun sense(): Triple<Int, Int, Int>? {
        val r = executar(byteArrayOf(0x03, 0, 0, 0, 18, 0), 18, 5000)
        if (r !is Resposta.Ok) return null
        val b = r.dados
        return Triple(b[2].toInt() and 0xF, b[12].toInt() and 0xFF, b[13].toInt() and 0xFF)
    }

    private fun comando(cdb: ByteArray, bytesIn: Int): ByteArray? = (executar(cdb, bytesIn) as? Resposta.Ok)?.dados

    // ---- o que se pergunta ao leitor -----------------------------------------------------------

    /** O tipo do INQUIRY (5 é CD/DVD; 0 é disco, o pendrive), depois de [quem]; -1 antes. */
    var tipo = -1
        private set

    /** INQUIRY: "fabricante produto revisão", ou `null`. Guarda o [tipo]. */
    // O INQUIRY com os prazos normais (medido no A07, 29/09): reabrir depressa (3 s e fechar) nunca acordou o leitor
    // em 12 tentativas; esperar a resposta, com a recuperação e as 3 falhas antes de reabrir, abriu em 41 e 63 s.
    fun quem(): String? = comando(byteArrayOf(0x12, 0, 0, 0, 36, 0), 36)?.let { b ->
        tipo = b[0].toInt() and 0x1F
        if (tipo != 5) Log.w(TAG, "INQUIRY: tipo $tipo (5 é CD/DVD)")
        "${String(b, 8, 8).trim()} ${String(b, 16, 16).trim()} ${String(b, 32, 4).trim()}"
    }

    enum class Pronto { PRONTO, SEM_DISCO, NAO_FICOU_PRONTO }

    /** TEST UNIT READY até [prazoMs] (o disco girando; os senses do religamento são normais). */
    fun esperarPronto(prazoMs: Long = 30_000): Pronto {
        val t0 = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - t0 < prazoMs) {
            if (executar(ByteArray(6), 0, 5000) is Resposta.Ok) return Pronto.PRONTO
            val s = sense()
            if (s != null && s.second == 0x3A) return Pronto.SEM_DISCO
            Thread.sleep(500)
        }
        return Pronto.NAO_FICOU_PRONTO
    }

    /** O perfil atual do GET CONFIGURATION (0x10 DVD-ROM, 0x11 DVD-R, 0x1B DVD+R…), ou `null`. */
    fun perfil(): Int? = comando(byteArrayOf(0x46, 0x02, 0, 0, 0, 0, 0, 0, 8, 0), 8)?.let { b ->
        ((b[6].toInt() and 0xFF) shl 8) or (b[7].toInt() and 0xFF)
    }

    /** O *book type* do READ DISC STRUCTURE formato 0 (a parte física do disco), ou `null`. */
    fun bookType(): Int? = comando(byteArrayOf(0xAD.toByte(), 0, 0, 0, 0, 0, 0, 0x00, 0x08, 0x04, 0, 0), 2052)?.let { b ->
        (b[4].toInt() and 0xF0) shr 4
    }

    /** O CPST do READ DISC STRUCTURE formato 1 (0 sem proteção), ou `null` se ilegível. */
    fun cpst(): Int? = comando(byteArrayOf(0xAD.toByte(), 0, 0, 0, 0, 0, 0, 0x01, 0, 8, 0, 0), 8)?.let { b ->
        b[4].toInt() and 0xFF
    }

    /** O número de setores do disco (READ CAPACITY: o último LBA + 1), ou `null`. */
    fun setoresDoDisco(): Long? = comando(byteArrayOf(0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0), 8)?.let {
        (ByteBuffer.wrap(it).int.toLong() and 0xFFFFFFFFL) + 1
    }

    /**
     * **A conferência antes de qualquer leitura de conteúdo** (§2.1): o perfil (gravável ou
     * prensado) e o CPST — ilegível ou diferente de 0 é [RecusaDoDisco]. Devolve o perfil.
     */
    fun conferir(): Int? {
        val p = perfil()
        val book = bookType()
        gravavel = PoliticaDoDisco.gravavel(p, book)
        nome = PoliticaDoDisco.nomeDoBook(book) ?: PoliticaDoDisco.nomeDoPerfil(p)
        val c = cpst()
        Log.i(TAG, "disco: $nome (${if (gravavel) "gravável" else "prensado"}; book type ${book ?: "ilegível"}, " +
            "perfil ${PoliticaDoDisco.nomeDoPerfil(p)}), CPST ${c ?: "ilegível"}")
        if (PoliticaDoDisco.recusaPeloCpst(c)) {
            throw RecusaDoDisco(FrasesDoDvd.PROTEGIDO, "CPST ${c ?: "ilegível"} (${PoliticaDoDisco.nomeDoPerfil(p)})")
        }
        return p
    }

    // ---- a leitura -----------------------------------------------------------------------------

    private fun read10(lba: Long, n: Int) = byteArrayOf(
        0x28, 0, (lba shr 24).toByte(), (lba shr 16).toByte(), (lba shr 8).toByte(), lba.toByte(),
        0, (n shr 8).toByte(), n.toByte(), 0,
    )

    /**
     * [n] setores (no máximo [SETORES_POR_COMANDO]) a partir de [lba], em até três tentativas. O
     * bloco que não lê: no gravável, zeros (e conta); no prensado, [RecusaDoDisco]. O sense 0x6F é
     * sempre [RecusaDoDisco].
     */
    override fun ler(lba: Long, n: Int): ByteArray {
        require(n in 1..SETORES_POR_COMANDO) { "$n setores por comando (o máximo é $SETORES_POR_COMANDO)" }
        var ultimo = "sem sense"
        for (tentativa in 1..3) {
            if (tentativa > 1) tentativasRepetidas++
            when (val r = executar(read10(lba, n), n * 2048)) {
                is Resposta.Ok -> return r.dados
                is Resposta.Falhou -> {
                    val s = sense()
                    if (s != null && PoliticaDoDisco.senseDeProtecao(s.second)) {
                        throw RecusaDoDisco(FrasesDoDvd.PROTEGIDO, "sense de proteção no setor $lba (ASC 0x6F ASCQ 0x%02x)".format(s.third))
                    }
                    // UNIT ATTENTION de meio trocado (a revisão do código, 3): o disco conferido não é
                    // mais o que está no leitor.
                    if (s != null && PoliticaDoDisco.senseDeDiscoTrocado(s.second)) {
                        throw RecusaDoDisco(FrasesDoDvd.DISCO_TROCADO, "o meio mudou no setor $lba (ASC 0x28)")
                    }
                    ultimo = s?.let { "chave 0x%x ASC 0x%02x ASCQ 0x%02x".format(it.first, it.second, it.third) } ?: "sem sense"
                }
                is Resposta.Transporte -> ultimo = "falha de transporte"
            }
        }
        Log.w(TAG, "setores $lba..${lba + n - 1} não leram em 3 tentativas ($ultimo)")
        if (!PoliticaDoDisco.pulaBlocoRuim(gravavel)) {
            throw RecusaDoDisco(FrasesDoDvd.PROTEGIDO, "disco prensado com setor ilegível em $lba ($ultimo)")
        }
        blocosPulados++
        setoresPulados += n
        return ByteArray(n * 2048)
    }

    override fun close() {
        runCatching { con.releaseInterface(itf) }
        runCatching { con.close() }
    }

    companion object {
        private const val TAG = "QuallDvd"
        /** 64 KB por READ(10): fixo no produto (§1.1). */
        const val SETORES_POR_COMANDO = 32

        /**
         * Os aparelhos USB com uma interface de armazenamento bulk-only (classe 8, protocolo 0x50),
         * na ordem em que se confere (a revisão do código, 7): a subclasse ATAPI (2, a do leitor
         * medido no §1) ou SFF-8070i (5) primeiro, a SCSI transparente (6, também a do pendrive)
         * depois — e a 6 fica de fora quando há [umPendriveMontado]: reivindicar a interface com
         * força tiraria o pendrive do sistema. Quem confirma que é leitor é o INQUIRY ([tipo] 5).
         */
        fun candidatos(usb: UsbManager, pendriveMontado: Boolean): List<UsbDevice> = usb.deviceList.values
            .mapNotNull { d -> interfaceDe(d)?.let { d to it.interfaceSubclass } }
            .filter { (_, sub) -> sub == 2 || sub == 5 || !pendriveMontado }
            .sortedBy { (_, sub) -> if (sub == 2 || sub == 5) 0 else 1 }
            .map { it.first }

        /** Algum aparelho de armazenamento USB aparece como `ATAPI/SFF` ou `SCSI` (sem o filtro). */
        fun algumArmazenamento(usb: UsbManager): Boolean = usb.deviceList.values.any { interfaceDe(it) != null }

        /**
         * Há um volume removível montado que o sistema descreve como USB (o pendrive; o cartão SD não
         * diz "USB"). Heurística: a `StorageVolume` não diz de qual aparelho USB veio.
         */
        fun umPendriveMontado(c: android.content.Context): Boolean = runCatching {
            val sm = c.getSystemService(android.os.storage.StorageManager::class.java)
            sm.storageVolumes.any { v ->
                v.isRemovable && !v.isPrimary && v.state == android.os.Environment.MEDIA_MOUNTED &&
                    v.getDescription(c).contains("USB", ignoreCase = true)
            }
        }.getOrDefault(false)

        private fun interfaceDe(d: UsbDevice): UsbInterface? = (0 until d.interfaceCount).map { d.getInterface(it) }
            .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_MASS_STORAGE && it.interfaceProtocol == 0x50 }

        /** Abre (a permissão já dada), reivindica a interface com força e recupera o protocolo. */
        fun abrir(usb: UsbManager, d: UsbDevice): LeitorDeDisco {
            val itf = interfaceDe(d) ?: throw IllegalStateException("sem interface bulk-only")
            var epIn: UsbEndpoint? = null
            var epOut: UsbEndpoint? = null
            for (i in 0 until itf.endpointCount) {
                val e = itf.getEndpoint(i)
                if (e.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (e.direction == UsbConstants.USB_DIR_IN) epIn = e else epOut = e
            }
            if (epIn == null || epOut == null) throw IllegalStateException("sem os dois endpoints bulk")
            val con = usb.openDevice(d) ?: throw IllegalStateException("o sistema não abriu o leitor")
            if (!con.claimInterface(itf, true)) {
                con.close()
                throw IllegalStateException("a interface do leitor não foi liberada")
            }
            val l = LeitorDeDisco(con, itf, epIn, epOut, d)
            // **Sem a recuperação preventiva** (a experiência de 29/09, 19:07): o reset da classe na abertura fazia o
            // leitor reinicializar (o sense 0x29, "reset aconteceu") e ficar 40–90 s sem responder; a recuperação
            // fica para quando um comando falha.
            return l
        }
    }
}
