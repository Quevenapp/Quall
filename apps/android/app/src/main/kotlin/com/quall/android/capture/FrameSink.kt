package com.quall.android.capture

import java.nio.Buffer
import java.nio.ByteBuffer

/**
 * Para onde vai um quadro que saiu do encoder.
 *
 * Existe para que o mesmo [H264ScreenEncoder] sirva aos dois destinos sem `if` interno: o
 * arquivo `.h264`+`.json` do `docs/contrato-sidecar.md` (verificação sem rede) e a track de mídia
 * do núcleo (`quall_track_send_frame`). O encoder não sabe qual dos dois está usando — e é isso
 * que garante que a captura provada na bancada sem rede seja **a mesma** que emite.
 *
 * O buffer entregue em [aoQuadro] é emprestado: ele vale só durante a chamada, e pode ser o
 * próprio buffer de saída do `MediaCodec`. Quem precisar guardar, copia ali.
 */
interface FrameSink {

    /**
     * O destino quer um IDR agora?
     *
     * Chamado uma vez por volta do laço de dreno — inclusive nas voltas em que nenhum quadro
     * saiu, porque um pedido de IDR não pode esperar o próximo quadro para ser notado. Na track,
     * isto é `quall_track_take_idr_request`: uma leitura atômica que **consome** a bandeira. Não
     * há callback do Rust para o Java em lugar nenhum deste caminho.
     */
    fun querIdr(): Boolean = false

    /**
     * Um quadro completo em Annex-B, com SPS/PPS na frente quando for IDR.
     *
     * `deslocamento` é explícito porque o `MediaCodec.BufferInfo.offset` do encoder OMX legado do
     * Galaxy A10s não é zero, e porque o endereço direto que o JNI usa lá embaixo ignora
     * `position()`.
     */
    fun aoQuadro(dados: ByteBuffer, deslocamento: Int, tamanho: Int, timestampUs: Long, idr: Boolean)

    /**
     * `true` quando o destino desistiu e não adianta continuar capturando — na track, é o
     * receptor tendo saído. O encoder para o laço por conta própria, sem esperar prazo.
     */
    fun desistiu(): Boolean = false

    fun fechar() {}
}

/**
 * Uma fatia `[deslocamento, deslocamento+tamanho)` do buffer, pronta para `write`/`get`, sem
 * mexer na posição do original.
 *
 * `position`/`limit` são chamados através de [Buffer] de propósito: as sobrecargas covariantes
 * que devolvem `ByteBuffer` existem no `android.jar` do `compileSdk` 36, mas o `NoSuchMethodError`
 * correspondente em aparelho antigo é um clássico. Chamando pela classe base, o bytecode gerado
 * vale em todo `minSdk`.
 */
fun fatiar(dados: ByteBuffer, deslocamento: Int, tamanho: Int): ByteBuffer {
    val copia = dados.duplicate()
    (copia as Buffer).position(deslocamento)
    (copia as Buffer).limit(deslocamento + tamanho)
    return copia
}
