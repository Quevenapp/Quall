package com.quall.android.audio

import java.io.File
import java.io.RandomAccessFile

/**
 * Um `.wav` de 16 bits, **só de bancada**.
 *
 * ## Ele não liga sozinho, e a origem é a razão
 *
 * `docs/audio.md` §8 e `docs/regras-de-frente.md` fecham a porta: *"um `.wav` não carrega no nome
 * o que tem dentro"*, e o precedente já existe no repositório — uma frente abriu um quadro de um
 * `.h264` cuja origem era a tela do usuário. A distinção que sobreviveu lá é a mesma aqui:
 * `prova-laco.ps1` manteve `--salvar` porque a origem dele é **padrão sintético nosso**;
 * `prova-rede.ps1` perdeu o `--salvar` porque a origem dele não é.
 *
 * Este escritor só é chamado quando a preferência de bancada `gravar_audio_em` aponta um caminho
 * — o que a bancada só faz com o **tom sintético do `quall-probe`** do outro lado. Nunca há
 * caminho para arquivo com origem de captura de sistema: [ReprodutorDeAudio] o recusa, e o motivo
 * está lá.
 */
class EscritorDeWav private constructor(
    private val arquivo: RandomAccessFile,
    private val canais: Int,
) {
    private var amostrasEscritas = 0L

    fun escrever(pcm: ShortArray, amostras: Int) {
        val bytes = ByteArray(amostras * 2)
        for (i in 0 until amostras) {
            val v = pcm[i].toInt()
            bytes[i * 2] = (v and 0xFF).toByte()
            bytes[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        arquivo.write(bytes)
        amostrasEscritas += amostras
    }

    /** Fecha o cabeçalho com os tamanhos de verdade. Devolve quantas amostras por canal saíram. */
    fun finalizar(): Long {
        val dados = amostrasEscritas * 2
        arquivo.seek(4)
        escreverLe32(36 + dados)
        arquivo.seek(40)
        escreverLe32(dados)
        arquivo.close()
        return amostrasEscritas / canais
    }

    private fun escreverLe32(v: Long) {
        arquivo.write(
            byteArrayOf(
                (v and 0xFF).toByte(),
                ((v shr 8) and 0xFF).toByte(),
                ((v shr 16) and 0xFF).toByte(),
                ((v shr 24) and 0xFF).toByte(),
            )
        )
    }

    companion object {
        fun criar(caminho: String, taxaHz: Int, canais: Int): EscritorDeWav? = runCatching {
            val f = File(caminho)
            f.parentFile?.mkdirs()
            val raf = RandomAccessFile(f, "rw")
            raf.setLength(0)
            val bytesPorSegundo = taxaHz * canais * 2
            raf.write("RIFF".toByteArray())
            raf.write(ByteArray(4)) // tamanho, preenchido em finalizar()
            raf.write("WAVEfmt ".toByteArray())
            val cab = ByteArray(20)
            fun le16(pos: Int, v: Int) {
                cab[pos] = (v and 0xFF).toByte(); cab[pos + 1] = ((v shr 8) and 0xFF).toByte()
            }
            fun le32(pos: Int, v: Int) {
                le16(pos, v and 0xFFFF); le16(pos + 2, (v shr 16) and 0xFFFF)
            }
            le32(0, 16)                    // tamanho do bloco fmt
            le16(4, 1)                     // PCM
            le16(6, canais)
            le32(8, taxaHz)
            le32(12, bytesPorSegundo)
            le16(16, canais * 2)           // alinhamento de bloco
            le16(18, 16)                   // bits por amostra
            raf.write(cab)
            raf.write("data".toByteArray())
            raf.write(ByteArray(4))        // tamanho, preenchido em finalizar()
            EscritorDeWav(raf, canais)
        }.getOrNull()
    }
}
