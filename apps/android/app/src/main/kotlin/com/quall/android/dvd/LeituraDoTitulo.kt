package com.quall.android.dvd

import com.quall.android.core.LogSeguro as Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/** Um trecho de setores do título (uma célula do IFO), com o tempo das células anteriores (90 kHz). */
data class TrechoDoTitulo(val primeiro: Long, val ultimo: Long, val acumulado90k: Long) {
    val setores: Long get() = ultimo - primeiro + 1
}

/** Para onde a leitura empurra (o pipeline em C; nos testes, um de mentira). */
interface DestinoDaLeitura {
    fun celula(pos: Long, acumulado90k: Long): Int
    /** Bloqueia com a fila cheia (8 MB, em C). 0 ou o erro do C. */
    fun empurrar(buf: ByteBuffer, n: Int, pos: Long): Int
    fun fimDaEntrada()
    fun abortar(erro: Int)
}

/** O destino de verdade: o `Dvd` do C. */
class DestinoQuallDvd(private val h: Long) : DestinoDaLeitura {
    override fun celula(pos: Long, acumulado90k: Long) = QuallDvd.celula(h, pos, acumulado90k)
    override fun empurrar(buf: ByteBuffer, n: Int, pos: Long) = QuallDvd.empurrar(h, buf, n, pos)
    override fun fimDaEntrada() = QuallDvd.fimDaEntrada(h)
    override fun abortar(erro: Int) = QuallDvd.abortar(h, erro)
}

/**
 * **A thread de leitura** (`docs/dvd-para-mp4.md` §2.2, a D2): lê os trechos do título em ordem, em
 * comandos de 64 KB ([LeitorDeDisco.SETORES_POR_COMANDO], sem passar da ponta de um trecho), e os
 * empurra para o pipeline, que segura no máximo 8 MB à frente do demuxer (o `empurrar` bloqueia).
 * Cada trecho é anunciado ([DestinoDaLeitura.celula]) antes do primeiro setor dele, com a posição
 * no fluxo e o acumulado (o carimbo pelo NAV e pelo C_PBTM, §2.4).
 *
 * O fim: [DestinoDaLeitura.fimDaEntrada] quando leu tudo; senão [DestinoDaLeitura.abortar] com o
 * motivo — a recusa (§2.1) como `ERRO_CIFRADO`, o leitor que parou como `ERRO_LEITOR`, o
 * [parar] como `ERRO_CANCELADO` — e [falha] diz o que foi.
 */
class LeituraDoTitulo(
    private val setores: Setores,
    private val trechos: List<TrechoDoTitulo>,
    private val destino: DestinoDaLeitura,
) {
    val total: Long = trechos.sumOf { it.setores }
    @Volatile var lidos = 0L
        private set
    @Volatile var falha: Throwable? = null
        private set
    @Volatile private var parado = false
    private var thread: Thread? = null

    fun comecar(): LeituraDoTitulo {
        thread = Thread({ ler() }, "quall-dvd-leitura").also { it.start() }
        return this
    }

    /** Para (e acorda o pipeline); a thread sai no próximo comando. */
    fun parar() {
        parado = true
        destino.abortar(QuallDvd.ERRO_CANCELADO)
    }

    fun esperar(ms: Long) { thread?.join(ms) }

    val terminou: Boolean get() = thread?.isAlive != true

    /** A leitura, na thread de quem chama (os testes; [comecar] a põe numa thread própria). */
    fun ler() {
        val buf = ByteBuffer.allocateDirect(LeitorDeDisco.SETORES_POR_COMANDO * 2048)
        var pos = 0L
        try {
            for (t in trechos) {
                require(t.ultimo >= t.primeiro) { "trecho vazio ${t.primeiro}..${t.ultimo}" }
                val r = destino.celula(pos, t.acumulado90k)
                if (r < 0) throw IllegalStateException("o pipeline recusou a célula no byte $pos ($r)")
                var lba = t.primeiro
                while (lba <= t.ultimo) {
                    if (parado) return
                    val n = minOf(LeitorDeDisco.SETORES_POR_COMANDO.toLong(), t.ultimo - lba + 1).toInt()
                    val dados = setores.ler(lba, n)
                    buf.clear()
                    buf.put(dados, 0, n * 2048)
                    val e = destino.empurrar(buf, n * 2048, pos)
                    if (e < 0) {
                        // O pipeline parou (o setor cifrado, o cancelar): ele já sabe; aqui só sai.
                        if (falha == null && e == QuallDvd.ERRO_CIFRADO) falha = RecusaDoDisco(FrasesDoDvd.PROTEGIDO, "setor cifrado no byte $pos")
                        return
                    }
                    pos += n * 2048L
                    lba += n
                    lidos += n
                }
            }
            destino.fimDaEntrada()
        } catch (e: RecusaDoDisco) {
            falha = e
            destino.abortar(QuallDvd.ERRO_CIFRADO)
        } catch (e: LeitorParou) {
            falha = e
            destino.abortar(QuallDvd.ERRO_LEITOR)
        } catch (e: Throwable) {
            Log.w(TAG, "leitura: ${e.javaClass.simpleName}: ${Log.erroExterno(e.message)}")
            falha = e
            destino.abortar(QuallDvd.ERRO_LEITOR)
        }
    }

    companion object {
        private const val TAG = "QuallDvd"
    }
}

/**
 * Setores de um arquivo (a bancada da D1: um VOB copiado para a pasta privada do app, §2.8), como
 * se fosse o disco: o setor 0 é o byte 0.
 */
class SetoresDeArquivo(arquivo: File) : Setores, AutoCloseable {
    private val f = RandomAccessFile(arquivo, "r")
    val setores: Long = f.length() / 2048

    override fun ler(lba: Long, n: Int): ByteArray {
        val b = ByteArray(n * 2048)
        f.seek(lba * 2048)
        f.readFully(b)
        return b
    }

    override fun close() = f.close()
}
