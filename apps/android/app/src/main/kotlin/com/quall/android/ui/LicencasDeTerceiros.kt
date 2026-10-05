package com.quall.android.ui

import android.app.AlertDialog
import android.content.Context
import android.widget.ScrollView
import android.widget.TextView
import com.quall.android.R

/**
 * "Licenças de terceiros": o aviso que a LGPL 2.1 pede para o FFmpeg da câmera DV (e, desde a D1a do
 * DVD, `docs/dvd-para-mp4.md` §2.4, do conversor de DVD). O som do DVD é dito **"AC-3"**, nunca pela
 * marca do dono do formato: é nome de formato, e a marca não é nossa.
 *
 * **Decisão do usuário, 22/09/2026**: o FFmpeg (só o decodificador DV) entra no app de produto como
 * `.so` separada e trocável. As obrigações que o app cumpre:
 * - o aviso, a versão e o texto da licença, sempre à vista, fora da bandeira de bancada, porque a
 *   `.so` vai em todo APK arm64;
 * - a ligação dinâmica, sem modificação no fonte e sem verificação de integridade das `.so`;
 * - as instruções de troca (com `useLegacyPackaging = false` as `.so` não são extraídas: a troca é
 *   desempacotar, substituir, alinhar, assinar e reinstalar);
 * - a oferta do fonte exato e do script de compilação (`apps/android/tools/compila-ffmpeg-dv.sh`).
 *
 * Fica de fora e é do usuário: a cláusula nos termos de uso (permitir a modificação e a engenharia
 * reversa para depurá-la) e onde o fonte fica hospedado.
 */
object LicencasDeTerceiros {
    const val VERSAO_DO_FFMPEG = "9.0.1"
    const val SHA256_DO_FONTE = "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

    /**
     * O aviso no idioma da tela (`docs/traducao.md`): os parágrafos moram nos recursos (`lic_*`), com a
     * versão e o sha256 entrando por argumento.
     */
    fun aviso(c: Context): String = listOf(
        c.getString(R.string.lic_titulo, VERSAO_DO_FFMPEG),
        c.getString(R.string.lic_uso),
        c.getString(R.string.lic_troca),
        c.getString(R.string.lic_fonte, VERSAO_DO_FFMPEG, SHA256_DO_FONTE),
    ).joinToString("\n\n")

    fun mostrar(c: Context) {
        val lgpl = runCatching {
            c.assets.open("licencas/LGPL-2.1.txt").bufferedReader().use { it.readText() }
        }.getOrElse { c.getString(R.string.lic_sem_lgpl, it.message.toString()) }
        val texto = TextView(c).apply {
            text = aviso(c) + "\n\n" + lgpl
            textSize = 12f
            setTextIsSelectable(true)
            val p = (16 * c.resources.displayMetrics.density).toInt()
            setPadding(p, p, p, p)
        }
        AlertDialog.Builder(c)
            .setTitle(R.string.in_licencas)
            .setView(ScrollView(c).apply { addView(texto) })
            .setNeutralButton(R.string.lic_avisos_completos) { _, _ -> mostrarAvisosCompletos(c) }
            .setPositiveButton(R.string.fechar, null)
            .show()
    }

    /** Os avisos consolidados, copiados da raiz pelo build, sem baixar nada ao abrir. */
    private fun mostrarAvisosCompletos(c: Context) {
        val avisos = runCatching {
            c.assets.open("licencas/THIRD_PARTY_NOTICES.txt").bufferedReader(Charsets.UTF_8).use { it.readText() }
        }.getOrElse { c.getString(R.string.lic_sem_avisos, it.message.toString()) }
        val texto = TextView(c).apply {
            text = avisos
            textSize = 12f
            setTextIsSelectable(true)
            // O arquivo completo pode ter megabytes: o próprio TextView rola dentro da janela,
            // em vez de um ScrollView medir uma vista com a altura de todas as linhas.
            maxHeight = (c.resources.displayMetrics.heightPixels * 0.6f).toInt()
            isVerticalScrollBarEnabled = true
            val p = (16 * c.resources.displayMetrics.density).toInt()
            setPadding(p, p, p, p)
        }
        AlertDialog.Builder(c)
            .setTitle(R.string.lic_avisos_completos)
            .setView(texto)
            .setPositiveButton(R.string.fechar, null)
            .show()
    }
}
