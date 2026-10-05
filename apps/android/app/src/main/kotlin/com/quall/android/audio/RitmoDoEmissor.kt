package com.quall.android.audio

/**
 * **Quanto o laço do [EmissorDeAudio] dorme depois de cada quadro**, e a vaga do próximo.
 *
 * ## Duas fontes, dois ritmos
 *
 * - **O tom sintético não bloqueia**: quem dá o ritmo é o acumulador. A vaga anda um quadro por
 *   volta, o laço dorme até ela, e, se ficar mais de dez quadros para trás, religa na hora de agora
 *   em vez de mandar rajada. Um `sleep(20)` fixo acumularia o erro de cada volta.
 * - **A captura do próprio app bloqueia no ritmo do dispositivo**: o `AudioRecord.read` só volta
 *   quando há um quadro. Dormir ainda até a vaga do host fazia o laço consumir no ritmo do host.
 *   Com o dispositivo mais rápido que o host, a fila do `AudioRecord` crescia (2,4 amostras por
 *   segundo a 50 ppm) até transbordar os 160 ms dele em ~53 min, e o som saía cada vez mais tarde
 *   — atraso de envio que a janela do receptor herda (§6), e que carimbo nenhum conserta (crítica
 *   da disciplina da deriva, M6). Aqui o laço não dorme: a leitura seguinte é que espera.
 *
 * Pura, sem relógio: quem chama passa a hora.
 */
class RitmoDoEmissor(
    private val quadroUs: Long,
    /** A fonte bloqueia no ritmo do dispositivo ([FonteDeAudio.ritmadaPeloDispositivo]). */
    private val ritmadaPeloDispositivo: Boolean,
    inicioUs: Long,
) {
    /** A vaga do próximo quadro, no relógio do host. */
    var vagaUs: Long = inicioUs
        private set

    /** Vezes em que o acumulador religou (o laço ficou mais de dez quadros para trás). */
    var religadas = 0
        private set

    /** Um quadro saiu (ou falhou) agora. Devolve quanto dormir, em µs (0: nada). */
    fun depoisDoQuadro(agoraUs: Long): Long {
        if (ritmadaPeloDispositivo) {
            // A leitura seguinte espera o dispositivo; a vaga é só a hora em que ela começa.
            vagaUs = agoraUs
            return 0
        }
        vagaUs += quadroUs
        val espera = vagaUs - agoraUs
        if (espera > 0) return espera
        if (espera < -quadroUs * 10) {
            // Atrasou mais de dez quadros: religa em vez de recuperar mandando rajada, que é o que
            // encheria o jitter buffer do outro lado.
            vagaUs = agoraUs
            religadas++
        }
        return 0
    }
}
