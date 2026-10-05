package com.quall.bancada.espiaodv

/** A parte em C (usbfs direto): transferência e contagem. Ver `src/main/cpp/espiao.c`. */
object Nativo {
    init { System.loadLibrary("espiaodv") }

    /** Bloqueia até o fim e devolve a linha do VEREDITO. */
    @JvmStatic external fun rodar(
        fd: Int, endpoint: Int, bulk: Boolean, psize: Int, tamBulk: Int, segundos: Int,
        gravar: Int, caminho: String?,
        nUrbs: Int, nPacotes: Int, usarMmap: Boolean, pastaJpeg: String?,
    ): String

    @JvmStatic external fun parar()
    /** O som cru do endpoint isócrono da placa, em [caminho] (s16le). Devolve o resumo. */
    @JvmStatic external fun som(fd: Int, endpoint: Int, psize: Int, segundos: Int, caminho: String): String

    /** `USBDEVFS_RESET` no fd do aparelho: 0 ou -errno. */
    @JvmStatic external fun resetar(fd: Int): Int

    /** Bancada: ler os pacotes isócronos juntos no buffer (a soma dos comprimentos reais). */
    @JvmStatic external fun compacto(sim: Boolean)

    /** `USBDEVFS_GET_SPEED`: 2 = total (12 Mbit/s), 3 = alta (480 Mbit/s); negativo = -errno. */
    @JvmStatic external fun velocidade(fd: Int): Int
}
