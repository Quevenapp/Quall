package com.quall.android.capture

/**
 * Formato do sidecar `.json` — contrato canônico em `docs/contrato-sidecar.md`. Não solte campo
 * novo nem renomeie sem atualizar aquele documento e `tools/valida-sidecar.py`; são a fonte de
 * verdade, não este comentário.
 *
 * Sem biblioteca de JSON de propósito: o formato é fixo e pequeno, e uma dependência a mais é
 * bytes de APK e superfície de bug num aparelho de 1,79 GB. Serialização é feita à mão abaixo,
 * escapando string do jeito mínimo que os valores que passam por aqui (nomes de API, de
 * encoder, nome de arquivo) podem precisar.
 */
data class CaptureSidecarHeader(
    val width: Int,
    val height: Int,
    val targetFps: Int,
    val preset: String,
    val captureApi: String,
    val encoder: String,
    val encoderIsHardware: Boolean,
    val targetBitrateBps: Int,
    val gopFrames: Int,
    val colorRange: String,
    val videoFile: String,
)

data class FrameRecord(
    val number: Int,
    val timestampUs: Long,
    val bytes: Int,
    val idr: Boolean,
    val encodeLatencyUs: Long,
)

class CaptureSidecar(
    private val header: CaptureSidecarHeader,
    private val frames: List<FrameRecord>,
) {
    fun toJson(): String {
        val sb = StringBuilder()
        sb.append("{\n  \"header\": {\n")
        sb.append("    \"width\": ${header.width},\n")
        sb.append("    \"height\": ${header.height},\n")
        sb.append("    \"target_fps\": ${header.targetFps},\n")
        sb.append("    \"preset\": ${jsonString(header.preset)},\n")
        sb.append("    \"capture_api\": ${jsonString(header.captureApi)},\n")
        sb.append("    \"encoder\": ${jsonString(header.encoder)},\n")
        sb.append("    \"encoder_is_hardware\": ${header.encoderIsHardware},\n")
        sb.append("    \"target_bitrate_bps\": ${header.targetBitrateBps},\n")
        sb.append("    \"gop_frames\": ${header.gopFrames},\n")
        sb.append("    \"color_range\": ${jsonString(header.colorRange)},\n")
        sb.append("    \"video_file\": ${jsonString(header.videoFile)}\n")
        sb.append("  },\n  \"frames\": [\n")
        for ((i, f) in frames.withIndex()) {
            sb.append("    { \"number\": ${f.number}, \"timestamp_us\": ${f.timestampUs}, ")
            sb.append("\"bytes\": ${f.bytes}, \"idr\": ${f.idr}, ")
            sb.append("\"encode_latency_us\": ${f.encodeLatencyUs} }")
            sb.append(if (i == frames.size - 1) "\n" else ",\n")
        }
        sb.append("  ]\n}\n")
        return sb.toString()
    }

    private fun jsonString(s: String): String {
        val out = StringBuilder("\"")
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (c.code < 0x20) out.append("\\u%04x".format(c.code)) else out.append(c)
            }
        }
        out.append('"')
        return out.toString()
    }
}
