package com.quall.android.capture.dv

import com.quall.android.core.LogSeguro as Log
import java.nio.ByteBuffer

/**
 * A ponte com `libqualldv.so` (`cpp/dv/qualldv.c`): USB isócrono pelo usbfs, decodificação DV ou
 * MJPEG (a placa de captura) pelo FFmpeg mínimo (LGPL, `.so` separada) e a imagem pronta para o
 * encoder.
 *
 * **Carregada sob demanda, e nunca pelo núcleo.** A `.so` só existe em arm64 (o FFmpeg da DV não é
 * construído para armv7, o A10s) e só quando `tools/compila-ffmpeg-dv.sh` rodou antes do build. Um
 * `System.loadLibrary` que falha aqui deixa a DV indisponível; o resto do app segue.
 */
object QuallDv {
    private const val TAG = "QuallDv"

    /** A lib carregou? Lido uma vez, na primeira pergunta. */
    val disponivel: Boolean by lazy {
        // Abaixo do Android 11 o `dlopen` falharia por `memfd_create` (ver `capturaUsbPossivel`).
        if (!com.quall.android.capturaUsbPossivel) return@lazy false
        try {
            System.loadLibrary("qualldv")
            true
        } catch (t: Throwable) {
            Log.i(TAG, "câmera DV indisponível neste APK/aparelho: ${t.javaClass.simpleName}: ${Log.erroExterno(t.message)}")
            false
        }
    }

    const val DESCONECTADA = -2L
    const val PRAZO = -1L

    /**
     * Sobe a thread de USB sobre o fd já com a interface reivindicada e a alternativa escolhida.
     * [formato] é o [TipoUsb.codigo]; [largura], [altura] e [quadroMax] (o `dwMaxVideoFrameSize`)
     * valem no MJPEG (a DV é sempre 720x480 de 120 000 bytes). 0 se não subiu.
     */
    @JvmStatic external fun abrir(
        fd: Int, endpoint: Int, psize: Int, formato: Int, largura: Int, altura: Int, quadroMax: Long,
        /** As placas HDMI (§14): o endpoint é bulk e [payloadMax] é o tamanho de cada payload; [cru] = NV12. */
        bulk: Int = 0, payloadMax: Int = 0, cru: Int = 0,
    ): Long

    /**
     * **O som da placa pelo usbfs** (`docs/placa-de-captura-usb.md` §13.10): pede à thread do USB que
     * leia o endpoint isócrono de som (s16; [passo] amostras da placa por amostra de saída: estéreo e
     * 96 kHz viram 48 kHz mono pela média; a interface já reivindicada e na alternativa
     * do fluxo). 0, ou -1.
     */
    @JvmStatic external fun ligarSom(h: Long, endpoint: Int, psize: Int, passo: Int): Int

    /**
     * Espera até [timeoutMs] por [amostras] amostras e as copia em [saida] (direto, ordem nativa).
     * Devolve [amostras], 0 no prazo, -1 se o som acabou; `instante[0]` é a hora da primeira amostra
     * (µs de `MONOTONIC`).
     */
    @JvmStatic external fun lerSom(h: Long, saida: ByteBuffer, amostras: Int, timeoutMs: Int, instante: LongArray): Int

    /** Destrava quem está em [lerSom] (antes de [fechar]). */
    @JvmStatic external fun pararSom(h: Long)

    /** Carimbo (CLOCK_MONOTONIC, ns) do quadro mais novo, [PRAZO] ou [DESCONECTADA]. */
    @JvmStatic external fun esperar(h: Long, timeoutMs: Int): Long

    /** Bancada: quadros de um arquivo `.dv` em laço a 29,97, no lugar do USB. */
    @JvmStatic external fun abrirArquivo(caminho: String): Long

    /** Esvazia a fila; devolve quantos quadros caíram. */
    @JvmStatic external fun descartar(h: Long): Int

    /** 1 = 16:9, 0 = 4:3, -1 = sem o pacote VSC, do quadro que está com a consumidora. */
    @JvmStatic external fun aspecto(h: Long): Int

    /** Decodifica e desentrelaça o quadro atual nos planos internos. 0 ok, -1 sem quadro, -2 falhou. */
    @JvmStatic external fun decodificar(h: Long): Int

    /** 1 = 16:9, 0 = 4:3, do último quadro decodificado. */
    @JvmStatic external fun aspectoDecodificado(h: Long): Int

    /**
     * Os três planos do último quadro decodificado sobre a memória do C, sem cópia: na DV, Y 720×480
     * e U/V 180×480 desentrelaçados; no MJPEG, os do JPEG (ver [geometria]).
     */
    @JvmStatic external fun planos(h: Long): Array<Any>

    /**
     * `[luma_w, luma_h, croma_w, croma_h, aspecto_n, aspecto_d, croma_centrado, formato]` dos
     * [planos] depois do último [decodificar] (ver [Geometria]).
     */
    @JvmStatic external fun geometria(h: Long): IntArray

    /** Escala e encaixa o último quadro decodificado num Image W×H. 0 ok, -1 nada decodificado, -3 destino inválido. */
    @JvmStatic external fun escrever(
        h: Long, y: ByteBuffer, yStride: Int, u: ByteBuffer, v: ByteBuffer, uvStride: Int,
        uvPixelStride: Int, largura: Int, altura: Int,
    ): Int

    /** O som do quadro atual (s16 estéreo intercalado, 8000 bytes): amostras por canal; taxa[0] = Hz. */
    @JvmStatic external fun som(h: Long, saida: ByteBuffer, taxa: IntArray): Int

    /** Gravação: fila FIFO funda, quadro com erro de USB entregue, e a âncora do som zerada. */
    @JvmStatic external fun modoGravacao(h: Long, ligado: Boolean)

    /** Quadros na fila agora. */
    @JvmStatic external fun naFila(h: Long): Int

    /** O som do quadro atual para o quadro [n] da gravação: 48 kHz estéreo, ancorado (32 KB). */
    @JvmStatic external fun somGravacao(h: Long, n: Long, saida: ByteBuffer, corrigidas: LongArray): Int

    /** Como [escrever], com o luma em Catmull-Rom (a gravação 1280×720). Só DV: -4 no MJPEG. */
    @JvmStatic external fun escreverHq(
        h: Long, y: ByteBuffer, yStride: Int, u: ByteBuffer, v: ByteBuffer, uvStride: Int,
        uvPixelStride: Int, largura: Int, altura: Int,
    ): Int

    /** fsync; 0 ou -errno. */
    @JvmStatic external fun sincronizar(fd: Int): Int

    /** Remonta o MP4 fragmentado de uma gravação interrompida em MP4 comum; pacotes, ou <0. */
    @JvmStatic external fun mp4Remontar(entrada: Int, saida: Int): Long

    /** MP4 (libavformat, hybrid_fragmented) sobre o fd; 0 se não abriu (ver logcat). */
    @JvmStatic external fun mp4Abrir(
        fd: Int, largura: Int, altura: Int, spsPps: ByteArray, taxa: Int, canais: Int, bitrate: Int,
        asc: ByteArray?, atraso: Int,
    ): Long

    /**
     * A câmera da tela R5 (`midia.h`, `mp4_abre_camera`): o mesmo MP4 fragmentado, com o vídeo em
     * 1/90000 s e a duração de cada quadro ([mp4VideoComDuracao]); a cor pelas constantes do
     * `MediaFormat` que o codificador declarou (0 = não declarada). 0 se não abriu.
     */
    @JvmStatic external fun mp4AbrirCamera(
        fd: Int, largura: Int, altura: Int, spsPps: ByteArray, taxa: Int, canais: Int, bitrate: Int,
        asc: ByteArray?, padrao: Int, faixa: Int, transferencia: Int,
    ): Long

    /** Um quadro da câmera: [pts] e [duracao] em 1/90000 s, a duração > 0. */
    @JvmStatic external fun mp4VideoComDuracao(
        m: Long, dados: ByteBuffer, off: Int, n: Int, pts: Long, duracao: Long, chave: Boolean,
    ): Int

    /** Vídeo em 1/30000 s. */
    @JvmStatic external fun mp4Video(m: Long, dados: ByteBuffer, off: Int, n: Int, pts: Long, chave: Boolean): Int

    /** Som em 1/taxa. */
    @JvmStatic external fun mp4Som(m: Long, dados: ByteBuffer, off: Int, n: Int, pts: Long, duracao: Int): Int

    /** Trailer (o arquivo vira MP4 comum) e libera. */
    @JvmStatic external fun mp4Fechar(m: Long): Int

    /** Ver o comentário de `contadores` em `qualldv.c`. */
    @JvmStatic external fun contadores(h: Long): LongArray

    /** Para a thread de USB e libera; só depois que ninguém mais chama [esperar]/[converter]. */
    @JvmStatic external fun fechar(h: Long)
}

/** A geometria dos planos de [QuallDv.planos] (`QuallDv.geometria`). */
data class Geometria(
    val larguraY: Int,
    val alturaY: Int,
    val larguraC: Int,
    val alturaC: Int,
    val aspectoN: Int,
    val aspectoD: Int,
    /** O croma no centro dos lumas que cobre (JPEG); senão co-situado à esquerda (DV 4:1:1). */
    val cromaCentrado: Boolean,
) {
    companion object {
        fun de(v: IntArray) = Geometria(v[0], v[1], v[2], v[3], v[4], v[5], v[6] != 0)
    }
}
