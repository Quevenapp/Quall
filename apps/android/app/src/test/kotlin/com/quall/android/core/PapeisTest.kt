// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Quem cada lista mostra (`docs/contrato-teleprompter.md` §2): o controle lista só prompters, e as
 * listas de vídeo escondem todo aparelho com papel.
 */
class PapeisTest {

    private fun aparelho(id: String, papel: String?) = QuallBrowser.Device(
        deviceId = id, displayName = id, protocolVersion = 2,
        screenSource = papel == null, cameraSource = false, sink = false,
        endpoint = "192.168.57.10:7877", papel = papel,
    )

    private val lista = listOf(
        aparelho("mac", null),
        aparelho("tablet", "teleprompter"),
        aparelho("a07", "controle_remoto"),
        aparelho("futuro", "desconhecido"),
        aparelho("vazio", ""),
    )

    @Test
    fun o_controle_so_ve_prompters() {
        assertEquals(listOf("tablet"), Papeis.soTeleprompters(lista).map { it.deviceId })
    }

    /** Um papel desconhecido de uma build futura também não é vídeo. */
    @Test
    fun o_video_esconde_todo_papel() {
        assertEquals(listOf("mac", "vazio"), Papeis.soDeVideo(lista).map { it.deviceId })
    }
}
