package com.quall.android.receive

import com.quall.android.capture.AnnexB

/**
 * Leitura do SPS de um fluxo H.264 Annex-B recebido.
 *
 * ## Por que a casca receptora precisa disto
 *
 * `MediaCodec.createDecoderByType` exige um `MediaFormat` **com largura e altura** antes de
 * `configure`. O quadro que chega da rede não vem com esses números do lado de fora: eles estão
 * dentro do SPS. Há duas saídas, e só uma é honesta:
 *
 * 1. Chutar um tamanho e esperar que o decodificador se conserte no
 *    `INFO_OUTPUT_FORMAT_CHANGED`. Funciona em Codec2 moderno e é exatamente o tipo de aposta que
 *    o A10s (OMX legado) existe para reprovar.
 * 2. Ler o SPS. É a mesma disciplina que o emissor desta casca já segue — "a decisão «é IDR?» sai
 *    do bitstream, não da flag da API" (README) — aplicada do outro lado.
 *
 * Este arquivo faz (2). Não decodifica imagem nenhuma: percorre os NALs, acha o do tipo 7 e lê
 * campos. Além do tamanho, devolve perfil, nível e `video_full_range_flag`, porque a faixa de cor
 * é o campo que `docs/contrato-sidecar.md` diz ter divergido entre plataformas — e um receptor
 * que a lê pode dizer o que recebeu em vez de supor.
 *
 * É deliberadamente independente de `tools/ler-sps.py`, que faz a mesma leitura em Python para a
 * bancada: quem confere não deve ser o mesmo código que escreve.
 */
object Sps {

    data class Info(
        val largura: Int,
        val altura: Int,
        val profileIdc: Int,
        val levelIdc: Int,
        /** `null` quando o SPS não traz VUI com `video_signal_type` — é o caso comum. */
        val faixaCompleta: Boolean?,
    ) {
        val perfil: String
            get() = when (profileIdc) {
                66 -> "Baseline"
                77 -> "Main"
                88 -> "Extended"
                100 -> "High"
                else -> "perfil $profileIdc"
            }

        val faixaDeCor: String
            get() = when (faixaCompleta) {
                true -> "completa (full)"
                false -> "limitada (tv)"
                null -> "não declarada no VUI" // i18n-fora: vai só ao painel de números de bancada e ao diário
            }
    }

    /**
     * Acha o primeiro NAL de tipo 7 em `[offset, offset+tamanho)` e o interpreta. `null` quando
     * não há SPS no buffer ou quando ele não é legível.
     */
    fun ler(buffer: java.nio.ByteBuffer, offset: Int, tamanho: Int): Info? {
        val inicios = AnnexB.nalStarts(buffer, offset, tamanho)
        val fim = offset + tamanho
        for ((i, inicio) in inicios.withIndex()) {
            if (inicio >= fim) continue
            if (AnnexB.nalType(buffer.get(inicio)) != AnnexB.NAL_SPS) continue
            val fimDoNal = if (i + 1 < inicios.size) inicios[i + 1] - 3 else fim
            val cru = ByteArray(fimDoNal - inicio - 1)
            for (j in cru.indices) cru[j] = buffer.get(inicio + 1 + j)
            return runCatching { interpretar(desescapar(cru)) }.getOrNull()
        }
        return null
    }

    /** Tira os bytes `0x03` de anti-emulação: `00 00 03` volta a ser `00 00`. */
    private fun desescapar(b: ByteArray): ByteArray {
        val out = ByteArray(b.size)
        var n = 0
        var i = 0
        while (i < b.size) {
            if (i + 2 < b.size && b[i] == 0.toByte() && b[i + 1] == 0.toByte() && b[i + 2] == 3.toByte()) {
                out[n++] = 0
                out[n++] = 0
                i += 3
            } else {
                out[n++] = b[i]
                i++
            }
        }
        return out.copyOf(n)
    }

    private class Bits(private val b: ByteArray) {
        private var i = 0

        fun u(n: Int): Int {
            var v = 0
            repeat(n) {
                val byte = b[i ushr 3].toInt() and 0xFF
                v = (v shl 1) or ((byte shr (7 - (i and 7))) and 1)
                i++
            }
            return v
        }

        fun ue(): Int {
            var z = 0
            while (u(1) == 0) {
                z++
                // Um SPS corrompido não pode virar laço infinito nem estouro: 32 zeros já é
                // impossível em qualquer fluxo legítimo.
                if (z > 32) throw IllegalArgumentException("exp-golomb inválido")
            }
            return (1 shl z) - 1 + if (z > 0) u(z) else 0
        }

        fun se(): Int {
            val k = ue()
            return if (k % 2 == 1) (k + 1) / 2 else -(k / 2)
        }
    }

    private fun interpretar(rbsp: ByteArray): Info {
        val r = Bits(rbsp)
        val profileIdc = r.u(8)
        r.u(8) // constraint_set flags + reserved
        val levelIdc = r.u(8)
        r.ue() // seq_parameter_set_id

        var chromaFormatIdc = 1 // 4:2:0 é o default quando o perfil não carrega o campo
        if (profileIdc in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
            chromaFormatIdc = r.ue()
            if (chromaFormatIdc == 3) r.u(1) // separate_colour_plane_flag
            r.ue() // bit_depth_luma_minus8
            r.ue() // bit_depth_chroma_minus8
            r.u(1) // qpprime_y_zero_transform_bypass_flag
            if (r.u(1) == 1) { // seq_scaling_matrix_present_flag
                val listas = if (chromaFormatIdc != 3) 8 else 12
                for (i in 0 until listas) {
                    if (r.u(1) == 1) pularListaDeEscala(r, if (i < 6) 16 else 64)
                }
            }
        }

        r.ue() // log2_max_frame_num_minus4
        when (r.ue()) { // pic_order_cnt_type
            0 -> r.ue() // log2_max_pic_order_cnt_lsb_minus4
            1 -> {
                r.u(1) // delta_pic_order_always_zero_flag
                r.se() // offset_for_non_ref_pic
                r.se() // offset_for_top_to_bottom_field
                val n = r.ue()
                repeat(n) { r.se() }
            }
        }
        r.ue() // max_num_ref_frames
        r.u(1) // gaps_in_frame_num_value_allowed_flag
        val larguraEmMbs = r.ue() + 1
        val alturaEmUnidades = r.ue() + 1
        val frameMbsOnly = r.u(1)
        if (frameMbsOnly == 0) r.u(1) // mb_adaptive_frame_field_flag
        r.u(1) // direct_8x8_inference_flag

        var cropEsq = 0
        var cropDir = 0
        var cropTopo = 0
        var cropBase = 0
        if (r.u(1) == 1) { // frame_cropping_flag
            cropEsq = r.ue()
            cropDir = r.ue()
            cropTopo = r.ue()
            cropBase = r.ue()
        }

        var faixaCompleta: Boolean? = null
        if (r.u(1) == 1) { // vui_parameters_present_flag
            if (r.u(1) == 1) { // aspect_ratio_info_present_flag
                if (r.u(8) == 255) { // Extended_SAR
                    r.u(16)
                    r.u(16)
                }
            }
            if (r.u(1) == 1) r.u(1) // overscan_info_present / overscan_appropriate
            if (r.u(1) == 1) { // video_signal_type_present_flag
                r.u(3) // video_format
                faixaCompleta = r.u(1) == 1 // video_full_range_flag
            }
            // O resto do VUI não interessa a esta casca; parar aqui é de propósito.
        }

        // Unidades de recorte, conforme a tabela 6-1 do padrão: em 4:2:0 (o único caso desta
        // bancada) SubWidthC = SubHeightC = 2.
        val subLargura = if (chromaFormatIdc == 1 || chromaFormatIdc == 2) 2 else 1
        val subAltura = if (chromaFormatIdc == 1) 2 else 1
        val unidadeX = if (chromaFormatIdc == 0) 1 else subLargura
        val unidadeY = (if (chromaFormatIdc == 0) 1 else subAltura) * (2 - frameMbsOnly)

        val largura = larguraEmMbs * 16 - unidadeX * (cropEsq + cropDir)
        val altura = (2 - frameMbsOnly) * alturaEmUnidades * 16 - unidadeY * (cropTopo + cropBase)

        require(largura in 16..8192 && altura in 16..8192) { "tamanho implausível: ${largura}x$altura" }
        return Info(largura, altura, profileIdc, levelIdc, faixaCompleta)
    }

    private fun pularListaDeEscala(r: Bits, tamanho: Int) {
        var ultimo = 8
        var proximo = 8
        for (j in 0 until tamanho) {
            if (proximo != 0) {
                proximo = (ultimo + r.se() + 256) % 256
            }
            ultimo = if (proximo == 0) ultimo else proximo
        }
    }
}
