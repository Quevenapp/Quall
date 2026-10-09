package com.quall.android.capture

import com.quall.android.core.LogSeguro as Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.CRC32

/**
 * **A cópia crua ao lado da gravação do `MediaMuxer`** (`docs/teleprompter-com-camera.md` §14.4,
 * proposta 1, e §14.10–§14.12). O `MediaMuxer` só escreve o índice (`moov`) no `stop()`: um processo
 * morto gravando deixa um MP4 que não abre. Enquanto grava, cada amostra codificada também vai a este
 * arquivo, na pasta privada do app (`getExternalFilesDir("gravacao-crua")`, o mesmo volume), só de
 * acrescentar; o Parar normal fecha o MP4 e **apaga a cópia**; na volta depois de um fim abrupto, a
 * cópia é remontada num MP4 pelo próprio `MediaMuxer` ([remontar]).
 *
 * ## O formato (big-endian)
 *
 * - cabeçalho: `QUALLCRU`, versão, o id do MediaStore, o nome, o tamanho, o som, a cor, o SPS, o PPS
 *   e o ASC, e o CRC32 de tudo isso;
 * - um registro por amostra: `[espécie 1 B: 0 vídeo, 1 som][IDR 1 B][pts µs 8 B][tamanho 4 B]
 *   [CRC32 4 B][bytes]`. A leitura para no primeiro registro cortado **ou** que não confere: depois
 *   de um desligamento brusco o fim pode ter zeros ou lixo com um tamanho plausível (a revisão, 8).
 *
 * ## Threads
 *
 * O [Escritor] recebe as amostras da thread do gravador e escreve numa thread própria
 * (`quall-copia-crua`), com `flush` e `fsync` a cada 2 s: um `fsync` de ~7 MB num eMMC barato na
 * thread de dreno seguraria o vídeo (a revisão, 10). A fila tem teto em bytes; cheia, a cópia fica
 * **incompleta** (para de receber) e a gravação segue — num acidente, recupera-se até ali.
 */
object CopiaCrua {
    private const val TAG = "QuallGravacao"
    private val MAGICA = "QUALLCRU".toByteArray(Charsets.US_ASCII)
    private const val VERSAO = 1
    const val EXTENSAO = ".quallcru"
    private const val EXTENSAO_TENTATIVAS = ".tentativas"

    /** O maior tamanho de uma amostra que a leitura aceita (um IDR de 4K a 60 Mbit/s cabe folgado). */
    private const val MAIOR_AMOSTRA = 16 * 1024 * 1024

    /** Quanto a fila do escritor segura antes de desistir (~18 s a 14 Mbit/s). */
    const val TETO_DA_FILA_BYTES = 32L * 1024 * 1024

    const val FSYNC_A_CADA_MS = 2_000L

    fun diretorio(c: android.content.Context): File? =
        c.getExternalFilesDir("gravacao-crua")?.also { it.mkdirs() }

    fun arquivoDe(dir: File, id: Long): File = File(dir, "$id$EXTENSAO")

    /** As cópias da pasta, pelo id do MediaStore do nome do arquivo. */
    fun listar(dir: File?): Map<Long, File> {
        val saida = HashMap<Long, File>()
        dir?.listFiles()?.forEach { f ->
            if (f.name.endsWith(EXTENSAO)) f.name.removeSuffix(EXTENSAO).toLongOrNull()?.let { saida[it] = f }
        }
        return saida
    }

    /** Apaga a cópia e o contador de tentativas dela. */
    fun apagar(f: File) {
        f.delete()
        File(f.path + EXTENSAO_TENTATIVAS).delete()
    }

    /**
     * Soma uma tentativa de remontar **antes** de remontar, e devolve quantas já houve contando esta.
     * Um `MPEG4Writer` que aborta num registro ruim derrubaria o processo em toda abertura; o
     * contador faz a terceira desistir (a revisão, 8).
     */
    fun contarTentativa(f: File): Int {
        val t = File(f.path + EXTENSAO_TENTATIVAS)
        val n = (runCatching { t.readText().trim().toInt() }.getOrDefault(0)) + 1
        runCatching { t.writeText(n.toString()) }
        return n
    }

    // --- o cabeçalho e os registros (puros: a JVM testa) ------------------------------------------

    class Cabecalho(val id: Long, val nome: String, val formatos: FormatosDaGravacao)

    fun escreverCabecalho(id: Long, nome: String, f: FormatosDaGravacao): ByteArray {
        val corpo = ByteArrayOutputStream()
        DataOutputStream(corpo).use { o ->
            o.write(MAGICA)
            o.writeInt(VERSAO)
            o.writeLong(id)
            o.writeUTF(nome)
            o.writeInt(f.largura); o.writeInt(f.altura)
            o.writeInt(f.taxaDoSom); o.writeInt(f.canaisDoSom); o.writeInt(f.bitrateDoSom)
            o.writeInt(f.padraoDeCor); o.writeInt(f.faixaDeCor); o.writeInt(f.transferencia)
            for (b in listOf(f.sps, f.pps, f.asc)) { o.writeInt(b.size); o.write(b) }
        }
        val bytes = corpo.toByteArray()
        val crc = CRC32().apply { update(bytes) }.value.toInt()
        return bytes + ByteBuffer.allocate(4).putInt(crc).array()
    }

    /** Lê o cabeçalho; `null` se cortado, de outra versão ou sem conferir. */
    fun lerCabecalho(entrada: DataInputStream): Cabecalho? = try {
        val crc = CRC32()
        val m = ByteArray(MAGICA.size).also { entrada.readFully(it) }
        if (!m.contentEquals(MAGICA)) null else {
            crc.update(m)
            val d = DataInputStream(CrcInputStream(entrada, crc))
            if (d.readInt() != VERSAO) null else {
                val id = d.readLong()
                val nome = d.readUTF()
                val w = d.readInt(); val h = d.readInt()
                val taxa = d.readInt(); val canais = d.readInt(); val br = d.readInt()
                val pad = d.readInt(); val faixa = d.readInt(); val transf = d.readInt()
                fun bloco(): ByteArray {
                    val n = d.readInt()
                    if (n < 0 || n > 1 shl 16) throw EOFException("bloco do cabeçalho de $n bytes")
                    return ByteArray(n).also { d.readFully(it) }
                }
                val sps = bloco(); val pps = bloco(); val asc = bloco()
                val esperado = crc.value.toInt()
                if (entrada.readInt() != esperado) null
                else Cabecalho(id, nome, FormatosDaGravacao(w, h, sps, pps, taxa, canais, br, asc, pad, faixa, transf))
            }
        }
    } catch (_: java.io.IOException) {
        null
    }

    /** Um registro já conferido. */
    class Registro(val video: Boolean, val chave: Boolean, val ptsUs: Long, val dados: ByteArray)

    fun escreverRegistro(o: DataOutputStream, video: Boolean, chave: Boolean, ptsUs: Long, dados: ByteArray, n: Int = dados.size) {
        o.writeByte(if (video) 0 else 1)
        o.writeByte(if (chave) 1 else 0)
        o.writeLong(ptsUs)
        o.writeInt(n)
        o.writeInt(CRC32().apply { update(dados, 0, n) }.value.toInt())
        o.write(dados, 0, n)
    }

    /** O próximo registro, ou `null` no fim, num corte ou num que não confere (a leitura para aí). */
    fun lerRegistro(d: DataInputStream): Registro? = try {
        val especie = d.read()
        if (especie != 0 && especie != 1) null else {
            val chave = d.readByte().toInt()
            val pts = d.readLong()
            val n = d.readInt()
            val crc = d.readInt()
            if ((chave != 0 && chave != 1) || n <= 0 || n > MAIOR_AMOSTRA) null else {
                val dados = ByteArray(n).also { d.readFully(it) }
                if (CRC32().apply { update(dados) }.value.toInt() != crc) null
                else Registro(especie == 0, chave == 1, pts, dados)
            }
        }
    } catch (_: java.io.IOException) {
        null
    }

    /** O que a primeira passada achou: onde parar, e o fim da imagem (o som não passa dele). */
    class Varredura(
        val cabecalho: Cabecalho,
        val registros: Int,
        val quadros: Int,
        val idrs: Int,
        /** O carimbo do primeiro IDR: o som anterior a ele cai, como na gravação (§5.2). */
        val inicioDoVideoUs: Long,
        val fimDoVideoUs: Long,
    ) {
        /** Pacotes de som dentro da imagem: sem nenhum, a remontagem sai sem trilha de som. */
        var sonsNaFaixa: Int = 0

        /** Há o que remontar: um IDR pelo menos. */
        val legivel: Boolean get() = idrs > 0 && quadros > 0
    }

    /**
     * A primeira passada: confere o cabeçalho e cada registro, e acha o fim da imagem (o carimbo do
     * último quadro mais a duração do anterior, como o `MediaMuxer` conta o último).
     */
    fun varrer(entrada: InputStream): Varredura? {
        val d = DataInputStream(entrada)
        val cab = lerCabecalho(d) ?: return null
        var registros = 0
        var quadros = 0
        var idrs = 0
        var ultimo = -1L
        var penultimo = -1L
        var inicio = -1L
        val sonsVistos = ArrayList<Long>()
        while (true) {
            val r = lerRegistro(d) ?: break
            registros++
            if (!r.video) sonsVistos.add(r.ptsUs)
            if (r.video) {
                if (quadros == 0 && !r.chave) continue
                if (quadros == 0) inicio = r.ptsUs
                quadros++
                if (r.chave) idrs++
                penultimo = ultimo
                ultimo = r.ptsUs
            }
        }
        val passo = if (ultimo >= 0 && penultimo >= 0 && ultimo > penultimo) ultimo - penultimo else 33_333L
        val fim = if (ultimo >= 0) ultimo + passo else 0L
        return Varredura(cab, registros, quadros, idrs, inicio, fim).also { it.sonsNaFaixa = sonsVistos.count { p -> p in inicio until fim } }
    }

    /** O resultado de [remontar], para o diário. */
    class Remontagem(val quadros: Int, val pacotesDeSom: Int, val duracaoUs: Long, val erro: String?)

    /**
     * **Remonta a cópia num MP4** pelo `MediaMuxer`, sobre [fd] (o pendente truncado, ou um item novo).
     * Duas passadas: [varrer], e a escrita até o último registro que conferiu, com o vídeo começando
     * no primeiro IDR e o som aparado no fim da imagem.
     */
    fun remontar(arquivo: File, fd: java.io.FileDescriptor): Remontagem {
        val v = BufferedInputStream(FileInputStream(arquivo), 1 shl 16).use { varrer(it) }
            ?: return Remontagem(0, 0, 0, "a cópia não tem cabeçalho legível") // i18n-fora: detalhe técnico da remontagem (diário)
        if (!v.legivel) return Remontagem(0, 0, 0, "a cópia não tem nenhum quadro inteiro a partir de um IDR") // i18n-fora: detalhe técnico da remontagem (diário)
        val m = MuxerMediaMuxer(fd, copia = null, comSom = v.sonsNaFaixa > 0)
        var quadros = 0
        var sons = 0
        var primeiroVideo = -1L
        var ultimoVideo = 0L
        var ultimoSom = -1L
        var erro: String? = null
        try {
            m.abrir(v.cabecalho.formatos)
            val taxa = v.cabecalho.formatos.taxaDoSom
            DataInputStream(BufferedInputStream(FileInputStream(arquivo), 1 shl 16)).use { d ->
                lerCabecalho(d)
                var lidos = 0
                var direto: ByteBuffer? = null
                while (lidos < v.registros) {
                    val r = lerRegistro(d) ?: break
                    lidos++
                    if (r.video && quadros == 0 && !r.chave) continue
                    if (!r.video && (r.ptsUs < v.inicioDoVideoUs || r.ptsUs >= v.fimDoVideoUs || r.ptsUs <= ultimoSom)) continue
                    var b = direto
                    if (b == null || b.capacity() < r.dados.size) {
                        b = ByteBuffer.allocateDirect(maxOf(r.dados.size, 1 shl 20)); direto = b
                    }
                    b!!.clear(); b.put(r.dados); b.flip()
                    val res = if (r.video) {
                        m.video(b, ParametrosDaGravacao.us90k(r.ptsUs), 0, r.chave)
                    } else {
                        m.som(b, r.ptsUs * taxa / 1_000_000L, 1024)
                    }
                    if (res < 0) { erro = "o MediaMuxer recusou uma amostra da cópia"; break } // i18n-fora: detalhe técnico da remontagem (diário)
                    if (r.video) {
                        quadros++
                        if (primeiroVideo < 0) primeiroVideo = r.ptsUs
                        ultimoVideo = r.ptsUs
                    } else {
                        sons++; ultimoSom = r.ptsUs
                    }
                }
            }
        } catch (e: Exception) {
            erro = "a remontagem falhou: ${e.javaClass.simpleName}: ${e.message}"
        }
        val f = m.fechar()
        if (erro == null) erro = f
        return Remontagem(quadros, sons, if (primeiroVideo >= 0) ultimoVideo - primeiroVideo else 0, erro)
    }

    /** Um `InputStream` que soma ao [crc] o que passa. */
    private class CrcInputStream(private val base: InputStream, private val crc: CRC32) : java.io.FilterInputStream(base) {
        override fun read(): Int = base.read().also { if (it >= 0) crc.update(it) }
        override fun read(b: ByteArray, off: Int, len: Int): Int = base.read(b, off, len).also { if (it > 0) crc.update(b, off, it) }
    }

    // --- o escritor ---------------------------------------------------------------------------------

    /**
     * Escreve a cópia de uma gravação. [abrir] e [amostra] são da thread do gravador; [fechar]
     * também, no fim. O arquivo só nasce no [abrir] (os formatos chegaram): antes disso não há MP4
     * a recuperar.
     */
    class Escritor(
        private val arquivo: File, private val id: Long, private val nome: String,
        /** The receiver serializes parts: a slow disk must never leave a writer behind per part. */
        private val esperarFechamento: Boolean = false,
    ) {
        private class Item(val video: Boolean, val chave: Boolean, val pts: Long, val dados: ByteArray)
        private val fim = Item(false, false, -1, ByteArray(0))
        private val fila = LinkedBlockingQueue<Item>()
        private val emFila = AtomicLong(0)
        @Volatile private var incompleta = false
        @Volatile private var erroDeEscrita: String? = null
        private var thread: Thread? = null
        private var aberta = false
        @Volatile var amostras = 0L; private set
        @Volatile var bytes = 0L; private set

        fun abrir(f: FormatosDaGravacao) {
            val cab = escreverCabecalho(id, nome, f)
            val fos = FileOutputStream(arquivo)
            val o = DataOutputStream(BufferedOutputStream(fos, 1 shl 18))
            o.write(cab)
            o.flush()
            fos.fd.sync()
            aberta = true
            thread = Thread({ escrever(fos, o) }, "quall-copia-crua").also { it.start() }
            Log.i(TAG, "gravador: cópia crua em ${arquivo.path} (fsync a cada ${FSYNC_A_CADA_MS / 1000} s)")
        }

        /** Copia e enfileira; nunca bloqueia. Fila cheia: a cópia fica incompleta, e a gravação segue. */
        fun amostra(video: Boolean, chave: Boolean, ptsUs: Long, b: ByteBuffer) {
            if (!aberta || incompleta) return
            val n = b.remaining()
            if (emFila.get() + n > TETO_DA_FILA_BYTES) {
                incompleta = true
                Log.w(TAG, "gravador: a cópia crua não acompanhou (${emFila.get() / 1_000_000} MB na fila); " +
                    "ela para aqui, e um acidente daqui em diante perde o resto")
                return
            }
            val dados = ByteArray(n).also { b.duplicate().get(it) }
            emFila.addAndGet(n.toLong())
            fila.put(Item(video, chave, ptsUs, dados))
        }

        private fun escrever(fos: FileOutputStream, o: DataOutputStream) {
            var ultimo = android.os.SystemClock.elapsedRealtime()
            try {
                while (true) {
                    val it = fila.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS)
                    if (it === fim) break
                    if (it != null) {
                        emFila.addAndGet(-it.dados.size.toLong())
                        escreverRegistro(o, it.video, it.chave, it.pts, it.dados)
                        amostras++
                        bytes += it.dados.size
                    }
                    val agora = android.os.SystemClock.elapsedRealtime()
                    if (agora - ultimo >= FSYNC_A_CADA_MS) {
                        ultimo = agora
                        o.flush()
                        fos.fd.sync()
                    }
                }
                o.flush()
                fos.fd.sync()
            } catch (e: Exception) {
                erroDeEscrita = "${e.javaClass.simpleName}: ${e.message}"
                incompleta = true
                Log.w(TAG, "gravador: a cópia crua falhou", e)
            } finally {
                runCatching { o.close() }
            }
        }

        /**
         * Fecha, **sem apagar**: quem apaga é a `GravacaoDaTela`, depois de publicar o MP4 (a revisão do
         * código, 1). Devolve o que houve, para o diário: `guardada`, `guardada_incompleta` ou
         * `nao_aberta`.
         */
        fun fechar(): String {
            if (!aberta) return "nao_aberta"
            aberta = false
            fila.put(fim)
            thread?.join(if (esperarFechamento) 0L else 10_000L)
            return if (incompleta) "guardada_incompleta" else "guardada"
        }
    }
}
