package com.quall.android.receive

/** Pure capture-clock timeline: deduplicates audio slots and preserves source gaps. */
class TempoDaGravacaoRecebida {
    var zeroVideoUs: Long? = null; private set
    var ultimoVideoUs = -1L; private set
    private var ultimaSequencia: Long? = null

    fun video(timestampUs: Long, idr: Boolean): Long? {
        if (zeroVideoUs == null) {
            if (!idr) return null
            zeroVideoUs = timestampUs
        }
        val pts = timestampUs - zeroVideoUs!!
        if (pts < 0 || pts <= ultimoVideoUs) return null
        ultimoVideoUs = pts
        return pts
    }

    fun som(timestampUs: Long, sequencia: Long, offsetSomUs: Long, offsetVideoUs: Long): Long? {
        val zero = zeroVideoUs ?: return null
        // Sequence is extended by the core, not the wrapping RTP u16.
        val anterior = ultimaSequencia
        if (anterior != null && sequencia <= anterior) return null
        ultimaSequencia = sequencia
        return timestampUs + offsetSomUs - (zero + offsetVideoUs)
    }

    /** A static received screen holds its last picture until Stop, excluding finalization time. */
    fun fimUs(agoraUs: Long, ultimaChegadaUs: Long, paradaUs: Long? = null): Long =
        if (ultimoVideoUs < 0) 0 else ultimoVideoUs +
            maxOf(33_333L, ((paradaUs ?: agoraUs) - ultimaChegadaUs).coerceAtLeast(0))
}
