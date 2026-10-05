package com.quall.android.audio

import com.quall.android.core.QuallNative
import org.json.JSONObject

/**
 * Os números do preset de áudio, **perguntados ao núcleo** e não fixados aqui.
 *
 * `quall_audio_preset_json` responde com a mesma `TrackKind::preset_de_audio` que gera o `a=fmtp`
 * do SDP. Fixar 48 000 e 2 canais neste arquivo criaria uma segunda fonte de verdade que diverge
 * em silêncio da primeira — é literalmente a classe de defeito que custou a §11 do
 * `docs/audio.md` (`useinbandfec=1` anunciado num fluxo sem LBRR nenhum) e o SPS sem
 * `bitstream_restriction` do M4.
 *
 * Os canais saem do **codec negociado**, não da espécie da track: PCMU é mono por RFC 3551 §6,
 * e uma track de áudio de sistema negociada em PCMU é mono mesmo o preset da espécie dizendo
 * estéreo. Por isso [de] recebe os dois.
 */
data class PresetDeAudio(
    val codec: String,
    val taxaHz: Int,
    val canais: Int,
    val quadroMs: Int,
    /** Amostras **por canal** num quadro. 960 a 48 kHz, 160 a 8 kHz. */
    val amostrasPorCanal: Int,
    val bitsPorSegundo: Int,
    val fec: Boolean,
    val perdaEsperadaPct: Int,
    val ehFala: Boolean,
    val payloadType: Int,
    val fmtp: String,
) {
    /** Quantos `i16` tem um quadro intercalado. */
    val amostrasPorQuadro: Int get() = amostrasPorCanal * canais

    fun linha(): String =
        "$codec ${taxaHz}Hz ${canais}ch ${quadroMs}ms ${bitsPorSegundo / 1000}kbps " +
            "fec=$fec pt=$payloadType"

    companion object {
        /**
         * Lê o preset da fronteira. Devolve `null` quando a espécie não é de áudio — que é o
         * mesmo caso em que `quall_audio_preset_json` devolve `-1`.
         *
         * `codec` é o **negociado**, vindo de [QuallNative.trackAudioCodec] no receptor ou da
         * escolha da casca no emissor. [QuallNative.AudioCodec.DEFAULT] deixa o núcleo usar o
         * codec do preset da espécie.
         */
        fun de(kind: Int, codec: Int = QuallNative.AudioCodec.DEFAULT): PresetDeAudio? {
            val texto = runCatching { QuallNative.audioPresetJson(kind, codec) }.getOrNull()
                ?: return null
            val j = runCatching { JSONObject(texto) }.getOrNull() ?: return null
            if (!j.has("sample_rate_hz")) return null
            return PresetDeAudio(
                codec = j.optString("codec", "?"),
                taxaHz = j.optInt("sample_rate_hz"),
                canais = j.optInt("channels", 1).coerceAtLeast(1),
                quadroMs = j.optInt("frame_ms", 20),
                amostrasPorCanal = j.optInt("frame_samples", 0),
                bitsPorSegundo = j.optInt("bitrate_bps", 0),
                fec = j.optBoolean("fec", false),
                perdaEsperadaPct = j.optInt("expected_loss_pct", 0),
                ehFala = j.optBoolean("is_speech", false),
                payloadType = j.optInt("payload_type", -1),
                fmtp = j.optString("fmtp", ""),
            ).takeIf { it.taxaHz > 0 && it.amostrasPorCanal > 0 }
        }
    }
}
