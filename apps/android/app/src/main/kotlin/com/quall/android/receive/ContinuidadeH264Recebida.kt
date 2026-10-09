package com.quall.android.receive

import com.quall.android.capture.AnnexB

/** Reads reference frame_num, so a lost complete access unit cannot contaminate the MP4. */
class ContinuidadeH264Recebida {
    private data class Param(val bits: Int, val plano: Boolean)
    private val sps = HashMap<Int, Param>()
    private val pps = HashMap<Int, Int>()
    private var ultimo: Int? = null
    private var modulo = 0
    private var esperarIdr = true

    fun ruptura() { esperarIdr = true }

    fun aceitar(b: ByteArray): Boolean = runCatching {
        val nals = nals(b)
        for (nal in nals) {
            val tipo = nal[0].toInt() and 31
            val r = Bits(rbsp(nal.copyOfRange(1, nal.size)))
            if (tipo == 7) {
                val perfil = r.u(8); r.u(16)
                val id = r.ue()
                var plano = false
                if (perfil in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
                    val chroma = r.ue()
                    if (chroma == 3) plano = r.u(1) == 1
                    r.ue(); r.ue(); r.u(1)
                    if (r.u(1) == 1) repeat(if (chroma == 3) 12 else 8) { i ->
                        if (r.u(1) == 1) {
                            var ultimo = 8; var proximo = 8
                            repeat(if (i < 6) 16 else 64) {
                                if (proximo != 0) proximo = (ultimo + r.se() + 256) % 256
                                if (proximo != 0) ultimo = proximo
                            }
                        }
                    }
                }
                val bits = r.ue() + 4
                require(bits in 4..16)
                sps[id] = Param(bits, plano)
            } else if (tipo == 8) pps[r.ue()] = r.ue()
        }
        val nal = nals.firstOrNull { (it[0].toInt() and 31) in intArrayOf(1, 5) } ?: return false
        val idr = (nal[0].toInt() and 31) == 5
        val r = Bits(rbsp(nal.copyOfRange(1, nal.size)))
        r.ue(); r.ue()
        val param = sps[pps[r.ue()]] ?: return false
        if (param.plano) r.u(2)
        val num = r.u(param.bits)
        val novoModulo = 1 shl param.bits
        val referencia = (nal[0].toInt() and 0x60) != 0
        if (idr) {
            esperarIdr = false
            ultimo = num
            modulo = novoModulo
            true
        } else if (esperarIdr) false else {
            val anterior = ultimo
            val continuo = modulo == novoModulo && (anterior == null || num == anterior || num == (anterior + 1) % modulo)
            if (!continuo) esperarIdr = true
            if (referencia && continuo) ultimo = num
            continuo
        }
    }.getOrElse { esperarIdr = true; false }

    companion object {
        /** MPEG4Writer's Annex-B conversion needs four-byte prefixes for every NAL. */
        fun paraMediaMuxer(b: ByteArray): ByteArray {
            val nals = nals(b)
            val saida = java.nio.ByteBuffer.allocate(nals.sumOf { 4 + it.size })
            for (nal in nals) { saida.putInt(1); saida.put(nal) }
            return saida.array()
        }
        fun nals(b: ByteArray): List<ByteArray> {
            val starts = AnnexB.nalStarts(b, b.size)
            return starts.mapIndexedNotNull { i, inicio ->
                var fim = if (i + 1 == starts.size) b.size else starts[i + 1] - 3
                while (fim > inicio && b[fim - 1] == 0.toByte()) fim--
                if (fim > inicio) b.copyOfRange(inicio, fim) else null
            }
        }
        private fun rbsp(b: ByteArray): ByteArray {
            val out = ByteArray(b.size); var n = 0; var zeros = 0
            for (v in b) {
                if (zeros >= 2 && v == 3.toByte()) { zeros = 0; continue }
                out[n++] = v
                zeros = if (v == 0.toByte()) zeros + 1 else 0
            }
            return out.copyOf(n)
        }
    }
    private class Bits(private val b: ByteArray) {
        private var pos = 0
        fun u(n: Int): Int {
            require(n in 0..24)
            var v = 0
            repeat(n) { require(pos < b.size * 8); v = (v shl 1) or ((b[pos / 8].toInt() ushr (7 - pos % 8)) and 1); pos++ }
            return v
        }
        fun ue(): Int { var z = 0; while (u(1) == 0) { require(++z <= 24) }; return (1 shl z) - 1 + u(z) }
        fun se(): Int { val n = ue(); return if (n % 2 == 1) (n + 1) / 2 else -n / 2 }
    }
}
