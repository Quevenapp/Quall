package com.quall.android.receive

import android.os.Handler
import android.os.Looper

/**
 * Estado do receptor, da thread de trabalho para a tela. Mesmo desenho do [MirrorBus]
 * [com.quall.android.mirror.MirrorBus] do lado emissor, e pelo mesmo motivo: a tela é uma função
 * pura do estado publicado, sem estado próprio para divergir.
 */
object ReceptorBus {

    enum class Fase { PARADO, PROCURANDO, CONECTANDO, PRECISA_DE_PIN, EXIBINDO, ERRO }

    /**
     * **O que a sessão tem a dizer, como código e não como frase** (`docs/traducao.md`, Android).
     *
     * A sessão não tem `Context` e roda numa thread própria; a frase sai na `ReceptorActivity`, no
     * idioma da hora de desenhar, com [Estado.detalhe] no lugar do pedaço variável. Até 02/10/2026 a
     * sessão publicava a frase em português e a tela decidia comparando prefixo
     * (`startsWith("esperando a track")`) — que em inglês para de funcionar sem erro nenhum.
     */
    enum class Aviso {
        NENHUM,
        RETOMANDO,
        CONECTANDO_E_PAREANDO,
        CANCELADO,
        PRECISA_DE_PIN,
        SEM_ROTA,
        /** [Estado.detalhe]: o endereço. */
        SEM_RESPOSTA,
        /** [Estado.detalhe]: o motivo técnico do núcleo (o endereço vem de [Estado.endpoint]). */
        NAO_CONECTOU,
        /** [Estado.detalhe]: o motivo do carregador. */
        NUCLEO_NAO_CARREGOU,
        /** [Estado.detalhe]: a exceção (classe: mensagem). */
        RECEPCAO_MORREU,
        ESPERANDO_A_IMAGEM,
        /** [Estado.detalhe]: o nome do par, ou vazio (a tela diz "emissor"). */
        SEM_TRACK,
        SEM_CAIXA,
        /** [Estado.detalhe]: o status da fronteira C. */
        TRATADOR_RECUSADO,
        /** [Estado.detalhe] destes três: o rótulo da track. */
        EMISSOR_SAIU,
        TRANSPORTE_FALHOU,
        SEM_QUADRO,
        RECEPCAO_ENCERRADA,
        RECEPCAO_TERMINOU,
        SO_SOM,
        /** [Estado.detalhe]: o número do evento. */
        SESSAO_CAIU,
        /** [Estado.detalhe]: o motivo que o reprodutor deu, ou vazio (a tela diz "o áudio não está tocando"). */
        AUDIO_PAROU,
    }

    data class Estado(
        val fase: Fase = Fase.PARADO,
        val par: String = "",
        val endpoint: String = "",
        val rotuloDaTrack: String = "",
        val pareamentoNovo: Boolean = false,
        /** Do momento em que a sessão subiu ao primeiro **IDR recebido**. Comparável ao `quall-probe`. */
        val primeiroIdrMs: Double = 0.0,
        /** Do momento em que a sessão subiu à primeira **imagem entregue ao compositor**. */
        val primeiraImagemMs: Double = 0.0,
        val quadrosRecebidos: Long = 0,
        /**
         * Quadros entregues ao compositor. **Chamava-se `quadrosExibidos` até 31/08/2026** — ver
         * [H264Decoder.quadrosEnfileirados] para por que o nome antigo prometia o que não entrega.
         */
        val quadrosEnfileirados: Long = 0,
        /** `retidos` do contrato: quadros que a porta impediu de ir à tela. */
        val retidos: Long = 0,
        /** `rupturas` do contrato: quantas vezes a cadeia de referência foi quebrada. */
        val rupturas: Long = 0,
        /** `suspeitos` do contrato: quadros chegados depois de uma ruptura e antes do IDR. */
        val suspeitos: Long = 0,
        /** `pior_rajada` do contrato: o maior número de suspeitos seguidos. */
        val piorRajada: Long = 0,
        /** `sem_referencia_ms` do contrato, já resumido como `n=… p50=… p95=… max=…`. */
        val semReferenciaMs: String = "n=0",
        /** Se a porta está ligada nesta sessão. A tela precisa dizer, senão o A/B é cego. */
        val congelando: Boolean = false,
        val quadrosDescartadosNaCaixa: Long = 0,
        val quadrosAntesDoPrimeiroIdr: Long = 0,
        val pedidosDeIdrEnviados: Long = 0,
        val fpsObtido: Double = 0.0,
        val decodeP50Ms: Double = 0.0,
        val decodeP95Ms: Double = 0.0,
        val largura: Int = 0,
        val altura: Int = 0,
        val perfil: String = "",
        val faixaDeCor: String = "",
        val decodificador: String = "",
        val decodificadorEhHardware: Boolean = false,
        val estatisticasDoNucleo: String = "",
        /**
         * A perda em uma linha: exata, teto e tarde demais juntos. Ver [ResumoDePerda].
         *
         * Existe como campo próprio, e não como algo que a tela deriva de
         * [estatisticasDoNucleo], porque os dois vêm da **mesma** leitura de contadores. Derivar
         * na tela abriria a porta para a linha e o JSON serem de instantes diferentes.
         */
        val resumoDePerda: String = "",
        /** Rótulo da track de áudio, vazio quando o emissor não mandou som. */
        val rotuloDoAudio: String = "",
        /** `true` enquanto o `AudioTrack` está de pé e consumindo slots. */
        val audioTocando: Boolean = false,
        /**
         * Uma linha com os contadores de áudio: slots, quadros tocados, o que o FEC curou, o que
         * caiu na ocultação de perda, e o veredito do tom sintético. Ver
         * [com.quall.android.audio.ReprodutorDeAudio.resumo].
         */
        val resumoDeAudio: String = "",
        /** O aviso da sessão para a linha de estado e o formulário. Ver [Aviso]. */
        val aviso: Aviso = Aviso.NENHUM,
        /** O pedaço variável do [aviso] (endereço, motivo técnico, rótulo), já como chegou. */
        val detalhe: String = "",
        /**
         * Texto pronto, mostrado **só quando [aviso] é [Aviso.NENHUM]**. A sessão não o usa mais (ela
         * publica [aviso]); fica para quem escreve um estado de mentira (a vitrine de `debug`).
         */
        val mensagem: String = "",
    )

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var atual = Estado()
        private set

    @Volatile
    private var listener: ((Estado) -> Unit)? = null

    fun setListener(l: ((Estado) -> Unit)?) {
        listener = l
        if (l != null) {
            val e = atual
            mainHandler.post { l(e) }
        }
    }

    fun publicar(estado: Estado) {
        atual = estado
        val l = listener ?: return
        mainHandler.post { l(estado) }
    }

    fun atualizar(bloco: (Estado) -> Estado) {
        publicar(bloco(atual))
    }
}
