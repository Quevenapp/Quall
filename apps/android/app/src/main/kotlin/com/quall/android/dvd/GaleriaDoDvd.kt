package com.quall.android.dvd

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import com.quall.android.core.LogSeguro as Log
import java.text.Normalizer

/**
 * O arquivo do título na Galeria (`docs/dvd-para-mp4.md` §2.1 e §2.6, a D1c):
 * `Movies/Quall/Quall-DVD-<volume>-<título>.mp4`, com `IS_PENDING=1` enquanto converte (a Galeria
 * não mostra o arquivo pela metade) e publicado no fim — também quando para no meio: o MP4
 * fragmentado fechado é jogável até onde chegou. O que sobra pendente de um processo morto é
 * remontado e publicado pelo `GravacaoDvService.publicarPendentes` (a mesma pasta), que não mexe
 * enquanto uma conversão está no ar ([ConversaoDvdBus.convertendo]).
 */
object GaleriaDoDvd {
    private const val TAG = "QuallDvd"

    /** `Quall-DVD-<volume>-<título, dois dígitos>.mp4`; o volume sem acento nem símbolo. */
    fun nome(volume: String, titulo: Int): String {
        val v = Normalizer.normalize(volume.trim(), Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "")
            .replace(Regex("[^A-Za-z0-9_-]+"), "_")
            .trim('_')
            .take(40)
            .ifEmpty { "DVD" }
        return "Quall-DVD-$v-${"%02d".format(titulo)}.mp4"
    }

    class Arquivo(val uri: Uri, val pfd: ParcelFileDescriptor, val nome: String)

    /** Um item novo pendente em `Movies/Quall`, aberto em "rw" (o muxer volta ao começo para o `moov`). */
    fun criar(c: Context, nome: String): Arquivo {
        val cv = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, nome)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Quall")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val uri = c.contentResolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), cv)
            ?: throw IllegalStateException("a Galeria não aceitou o arquivo novo")
        val pfd = try {
            c.contentResolver.openFileDescriptor(uri, "rw") ?: throw IllegalStateException("não abri o arquivo da Galeria")
        } catch (e: Exception) {
            runCatching { c.contentResolver.delete(uri, null, null) }
            throw e
        }
        return Arquivo(uri, pfd, nomeReal(c, uri) ?: nome)
    }

    /**
     * O nome que a Galeria deu de fato: com um arquivo de mesmo nome, ela acrescenta " (1)", " (2)"… (medido
     * 29/09: o parcial cancelado saiu "…-01 (2).mp4" e a mensagem dizia "…-01.mp4", o nome do arquivo inteiro).
     */
    fun nomeReal(c: Context, uri: Uri): String? = runCatching {
        c.contentResolver.query(uri, arrayOf(MediaStore.Video.Media.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }.getOrNull()

    fun publicar(c: Context, uri: Uri): Boolean = runCatching {
        c.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null) > 0
    }.getOrElse { Log.w(TAG, "não publiquei $uri: ${Log.erroExterno(it.message)}"); false }

    // ---- a marca de recusado (a revisão do código, 2) ------------------------------------------
    // O id do MediaStore do item recusado, num arquivo da pasta privada: se o processo morrer entre
    // a recusa e o apagar, o `publicarPendentes` acha a marca e apaga, em vez de remontar e publicar
    // um parcial de disco protegido.
    private const val MARCAS = "dvd-recusados.txt"

    @Synchronized
    fun marcarRecusado(c: Context, uri: Uri) {
        val id = runCatching { android.content.ContentUris.parseId(uri) }.getOrNull() ?: return
        runCatching { java.io.File(c.filesDir, MARCAS).appendText("$id\n") }
            .onFailure { Log.w(TAG, "a marca de recusado não foi escrita: ${Log.erroExterno(it.message)}") }
    }

    @Synchronized
    fun recusado(c: Context, id: Long): Boolean = runCatching {
        java.io.File(c.filesDir, MARCAS).takeIf { it.exists() }?.readLines()?.any { it.trim() == id.toString() } ?: false
    }.getOrDefault(false)

    @Synchronized
    fun esquecerRecusado(c: Context, id: Long) {
        runCatching {
            val f = java.io.File(c.filesDir, MARCAS)
            if (!f.exists()) return
            val resto = f.readLines().filter { it.isNotBlank() && it.trim() != id.toString() }
            if (resto.isEmpty()) f.delete() else f.writeText(resto.joinToString("\n", postfix = "\n"))
        }
    }

    /** O item vazio (nada convertido) ou recusado (o disco protegido: §2.1, o parcial é apagado). */
    fun apagar(c: Context, uri: Uri) {
        val ok = runCatching { c.contentResolver.delete(uri, null, null) >= 0 }
            .onFailure { Log.w(TAG, "não apaguei $uri: ${Log.erroExterno(it.message)}") }.getOrDefault(false)
        val id = runCatching { android.content.ContentUris.parseId(uri) }.getOrNull()
        if (ok && id != null) esquecerRecusado(c, id)
    }
}
