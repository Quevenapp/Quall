package com.quall.android.mirror

import android.os.Handler
import android.os.Looper

/**
 * Estado do espelhamento, do serviço para a tela. Mesma ideia do `CaptureBus`, mas com estado
 * estruturado em vez de string: a tela precisa mostrar o PIN grande, o endereço para digitar e os
 * contadores ao vivo, e formatar isso a partir de texto seria pior.
 *
 * O último estado fica guardado ([atual]) para a Activity conseguir se redesenhar depois de uma
 * rotação sem esperar o próximo evento do serviço.
 */
object MirrorBus {

    enum class Fase { PARADO, ESPERANDO, ESPELHANDO, ERRO }

    data class Estado(
        val fase: Fase = Fase.PARADO,
        val pin: String = "",
        /** `ip:porta` de cada interface, para quem for digitar do outro lado. */
        val enderecos: List<String> = emptyList(),
        /**
         * O que está sendo transmitido, para ler: "a tela" ou "a câmera <rótulo>", no idioma do momento
         * em que o serviço publicou (`docs/traducao.md`). A origem é escolhida antes do PIN
         * (`docs/fluxo-de-uso.md`) e fica fixa pela sessão inteira — esta string só informa, nunca
         * oferece trocar, e **nunca decide nada**: quem decide é [daTela].
         */
        val fonteRotulo: String = "",
        /**
         * A origem é a tela. **Campo**, e não uma comparação com o texto do rótulo: o rótulo é traduzido,
         * e conteúdo animado e prévia de câmera são mutuamente exclusivos por este campo.
         */
        val daTela: Boolean = true,
        /** O nome da câmera no ar, sem artigo ("Traseira", "Placa de captura (…)"); vazio na tela. */
        val nomeDaCamera: String = "",
        /**
         * A fonte é o vídeo USB (a filmadora DV ou a placa de captura), e se é a placa. **Campos**, e
         * não uma busca no texto do rótulo (`docs/placa-de-captura-usb.md` §11, item 2): o rótulo
         * mudou ("Vídeo USB", "Placa de captura", "Filmadora DV") e a decisão não pode ir junto.
         */
        val videoUsb: Boolean = false,
        val daPlaca: Boolean = false,
        val par: String = "",
        val pareamentoNovo: Boolean = false,
        /** Quantas vezes o emissor voltou a esperar um receptor nesta sessão de consentimento. */
        val tentativa: Int = 0,
        val quadrosEnviados: Long = 0,
        val falhasDeEnvio: Long = 0,
        val pedidosDeIdr: Long = 0,
        val idrsEnviados: Int = 0,
        val fpsPedido: Int = 0,
        val fpsObtido: Double = 0.0,
        val latenciaP50Ms: Double = 0.0,
        val latenciaP95Ms: Double = 0.0,
        /**
         * `false` quando a fonte não tem relógio comparável a `presentationTimeUs` — medido, não
         * presumido (ver `H264SurfaceEncoder.LATENCIA_IMPLAUSIVEL_ACIMA_DE_US`). Câmera em alguns
         * aparelhos; tela sempre confiável até hoje.
         */
        val latenciaConfiavel: Boolean = true,
        val encoder: String = "",
        val estatisticasDoNucleo: String = "",
        /**
         * Uma linha com a origem e os contadores do áudio emitido, ou vazio quando a oferta não
         * levou som. Ver [com.quall.android.audio.EmissorDeAudio.resumo].
         */
        val resumoDeAudio: String = "",
        /**
         * **O que foi pedido, o que está no ar, e por quê** — ver `core/Entrega.kt`. Vazios até a
         * geometria ser conhecida; `motivoDaEntrega` vazio quando a entrega é a pedida.
         */
        val pedido: String = "",
        val entregue: String = "",
        /**
         * A rede da câmera foi para 720p porque o codificador do aparelho não dá conta de 1080p
         * (`core/TransmissaoLeve.kt`). Campo para a tela decidir a faixa sem procurar a frase no motivo.
         */
        val transmissaoLeve: Boolean = false,
        /** O [entregue] curto, para a linha do alto da espera: "1920×1080 · 60 fps". */
        val entregueCurto: String = "",
        val motivoDaEntrega: String = "",
        val mensagem: String = "",
        /**
         * A [mensagem] é o estado do anúncio ("anunciando como…", "sem anúncio mDNS…", a última recusa),
         * e não um aviso: o iOS não a mostra (`mensagemDoVideoEhAviso`). Campo porque a frase é traduzida.
         */
        val mensagemEhAnuncio: Boolean = false,
        /** O anúncio na rede desta espera: `true` anunciando, `false` sem mDNS, `null` sem notícia nova. */
        val anunciando: Boolean? = null,
        /** Alias efêmero da lista LAN desta publicação, consultado com o handle ainda vivo. */
        val aliasNaRede: String = "",
        /**
         * A sessão é a da câmera do teleprompter (a R5), e não a de Espelhar. A home não a desenha:
         * sem isto, fechar a R5 no X deixava a home em Espelhar, porque o fim da sessão era lido
         * como o fim de um espelhamento (a conferência do Pessoa Exemplo, 28/09).
         */
        val daTelaR5: Boolean = false,
        /**
         * A sessão é a do DVD transmitido (`docs/dvd-para-mp4.md` §9), aberta pela tela "Converter DVD".
         * A home não a desenha, como a da tela R5; a tela do DVD a desenha.
         */
        val doDvd: Boolean = false,
    )

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var atual = Estado()
        private set

    /**
     * Os ouvintes, **um por tela** (a chave é a tela). Um só não serve desde a tela "Placa de captura e
     * filmadora" (`docs/placa-de-captura-usb.md` §13): abrir uma tela por cima de outra chama o
     * `onStart` da nova antes do `onStop` da velha, e a velha, ao se tirar, tiraria a nova.
     */
    private val ouvintes = java.util.concurrent.ConcurrentHashMap<Any, (Estado) -> Unit>()

    /** Registra (ou, com `null`, tira) o ouvinte de [dono]; o registrado recebe o [atual] logo. */
    fun ouvir(dono: Any, l: ((Estado) -> Unit)?) {
        if (l == null) {
            ouvintes.remove(dono)
            return
        }
        ouvintes[dono] = l
        val e = atual
        mainHandler.post { l(e) }
    }

    /** Carimbada pelo serviço ao aceitar um pedido novo, e em todo estado até o próximo. */
    @Volatile
    var sessaoDaTelaR5 = false

    /** Como [sessaoDaTelaR5], para a sessão do DVD. */
    @Volatile
    var sessaoDoDvd = false

    fun publicar(estado: Estado) {
        @Suppress("NAME_SHADOWING")
        val estado = if (estado.daTelaR5 == sessaoDaTelaR5 && estado.doDvd == sessaoDoDvd) estado
            else estado.copy(daTelaR5 = sessaoDaTelaR5, doDvd = sessaoDoDvd)
        atual = estado
        for (l in ouvintes.values) mainHandler.post { l(estado) }
    }

    fun atualizar(bloco: (Estado) -> Estado) {
        publicar(bloco(atual))
    }
}
