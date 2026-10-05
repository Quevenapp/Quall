package com.quall.android.core

import android.content.Context
import android.media.MediaCodecList
import android.media.MediaFormat
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R

/**
 * **O aparelho fraco transmite a câmera em 720p, e diz por quê** (decisão do Pessoa Exemplo, 28/09:
 * *"a10s e fracos fica em 720p e avisa o motivo"*; `docs/teleprompter-com-camera.md` §14.15).
 *
 * # O caso
 *
 * No A10s a rede a 1080×1920 custava ~212 ms só no codificador (`OMX.MTK.VIDEO.ENCODER.AVC`, ~25 fps
 * medidos), e o resíduo de sincronia no receptor ficava em 163 ms contra a guarda de 150 ms (§14.12).
 * Em 720×1280 o mesmo codificador folga.
 *
 * # O critério é o que o aparelho declara, e não uma lista de modelos
 *
 * O fabricante publica, por tamanho, a faixa de quadros por segundo **medida** no codificador
 * (`media_codecs_performance.xml`, lida por `VideoCapabilities.getAchievableFrameRatesFor`; o sistema
 * estima pelos tamanhos vizinhos quando o 1080p não está na lista). O aparelho é fraco quando o
 * **piso** da faixa a 1920×1080 fica abaixo de [FPS_DE_REFERENCIA], ou o codificador recusa o tamanho.
 * O que a bancada leu em 28/09:
 *
 * | aparelho | codificador | 1080p declarado | resultado |
 * |---|---|---|---|
 * | A10s | `OMX.MTK.VIDEO.ENCODER.AVC` | **nenhum** (720p: 29–102) | fraco (estimado) |
 * | A07 | `c2.mtk.avc.encoder` | 36–80 | não |
 * | tablet SM-X230 | `c2.mtk.avc.encoder` | 30–66 | não |
 *
 * **Sem declaração nenhuma** (`null`), a regra não age: um motivo inventado é pior que motivo nenhum
 * (o princípio de `Entrega`). A 60 fps a conta **não** é refeita: o A07 declara piso 36 a 1080p, e
 * reprová-lo a 60 mudaria um aparelho que nunca foi medido nisso (fica para a prova).
 *
 * Vale para toda transmissão de câmera (a tela R5 e a câmera comum); a gravação local não muda (ela
 * tem o tamanho escolhido, §14.2). A tela não entra: o custo é do codificador com a câmera.
 */
object TransmissaoLeve {
    private const val TAG = "QuallMirror"

    /** O fps em que o codificador precisa dar conta de 1080p. */
    const val FPS_DE_REFERENCIA = 30

    /** O teto da rede num aparelho fraco. */
    val TETO = Resolucao.P720

    /**
     * O "por quê" da entrega (`Entrega.motivo`, em minúscula como os outros), no idioma de agora. A tela
     * decide pelo campo `MirrorBus.Estado.transmissaoLeve`, e nunca procurando esta frase no motivo.
     */
    fun motivoTraduzido(c: Context): String = Idioma.contexto(c).getString(R.string.esp_leve_motivo)

    /** A frase que a pessoa lê na faixa da tela R5 e em Espelhar. */
    fun frase(c: Context): String = Idioma.contexto(c).getString(R.string.esp_leve_frase, motivoTraduzido(c))

    /** A conta, pura (a JVM testa). [piso] `null` quando o aparelho não declara nada. */
    fun fraco(piso: Double?, recusaOTamanho: Boolean): Boolean =
        recusaOTamanho || (piso != null && piso < FPS_DE_REFERENCIA)

    /** O teto de macroblocos da rede da câmera: o da escolha, ou 720p num aparelho fraco. */
    fun maxFs(escolha: Resolucao, fraco: Boolean): Int =
        if (fraco) minOf(escolha.maxFs, TETO.maxFs) else escolha.maxFs

    /** O que o codificador da rede declara, lido uma vez por processo. */
    private data class Leitura(val nome: String, val piso: Double?, val recusa: Boolean)

    private val leitura: Leitura? by lazy {
        runCatching {
            val tipo = MediaFormat.MIMETYPE_VIDEO_AVC
            // O mesmo que `MediaCodec.createEncoderByType` (a rede, `H264SurfaceEncoder`) abre: o
            // primeiro codificador da lista para o tipo.
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { it.isEncoder && it.supportedTypes.any { t -> t.equals(tipo, ignoreCase = true) } }
                ?: return@runCatching null
            val v = info.getCapabilitiesForType(tipo).videoCapabilities
            val recusa = !v.isSizeSupported(1920, 1080) && !v.isSizeSupported(1080, 1920)
            val faixa = if (recusa) null else runCatching {
                v.getAchievableFrameRatesFor(1920, 1080) ?: v.getAchievableFrameRatesFor(1080, 1920)
            }.getOrNull()
            Leitura(info.name, faixa?.lower, recusa)
        }.getOrNull()
    }

    /**
     * O motivo ([motivoTraduzido]), ou `null` se o aparelho transmite no que foi escolhido. Com a chave de bancada
     * `transmissao_leve` = `sim`/`nao`, a leitura é ignorada.
     */
    fun motivo(c: Context): String? {
        val bancada = Bancada.transmissaoLeve(c)
        val l = leitura
        val fraco = when (bancada) {
            "sim" -> true
            "nao" -> false
            else -> l != null && fraco(l.piso, l.recusa)
        }
        if (!registrado) {
            registrado = true
            Log.i(TAG, "transmissão leve: ${if (fraco) "SIM" else "não"} (codificador ${l?.nome ?: "?"}, " +
                "1080p piso=${l?.piso?.let { "%.0f".format(it) } ?: "não declarado"} fps, recusa=${l?.recusa}, bancada=$bancada)")
        }
        return if (fraco) motivoTraduzido(c) else null
    }

    @Volatile private var registrado = false
}
