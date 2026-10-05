package com.quall.android.capture.dv

import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **A regra que diz se uma VS de vídeo USB é uma placa de captura** que o Quall reivindica (tirando
 * o `uvcvideo` do kernel). Pura e isolada de propósito (`docs/placa-de-captura-usb.md` §11, item 2):
 * o Pessoa Exemplo vai trazer placas HDMI (provavelmente UVC com MJPEG **e** YUY2, até 1080p), que a regra de
 * hoje recusa; ela muda **depois** de medir os descritores delas, e só aqui (os testes em
 * `RegraDaPlacaTest` dizem o que ela aceita hoje, e o que muda fica visível no teste).
 *
 * **A regra de hoje** (a revisão do código da P1, 2; medida só na EasyCap Arkmicro `18ec:5555`):
 * - a VS oferece **MJPEG** com ao menos um quadro;
 * - **nenhum** formato não comprimido (`0x04`, YUY2/NV12) nem frame-based (`0x10`, H.264): são o que
 *   denuncia uma webcam, que perderia o `uvcvideo` e sairia com a faixa e os textos errados;
 * - **todo** quadro MJPEG cabe em 720x576 (o PAL de uma placa analógica).
 *
 * O [Veredito] leva o porquê, para o diário dizer por que um aparelho foi recusado (o dado que a
 * troca da regra vai precisar).
 */
object RegraDaPlaca {
    const val SUBTIPO_MJPEG = 0x06
    const val SUBTIPO_NAO_COMPRIMIDO = 0x04
    const val SUBTIPO_FRAME_BASED = 0x10
    /** O maior quadro de uma placa de captura analógica: PAL, 720x576. */
    const val LARGURA_MAX = 720
    const val ALTURA_MAX = 576

    data class Veredito(val aceita: Boolean, val porque: String)

    /**
     * **As placas HDMI** (§12.4 e §14; medidas: MS2109 `345f:2109` e `534d:2109`, ezcap `32ed:3201`):
     * têm não comprimido (YUY2/NV12) e quadros até 4K, o que a regra de cima recusa. São placa de
     * captura quando o aparelho **tem interface de som (UAC)** e o terminal de entrada **não declara
     * controle de câmera nenhum** (exposição, foco: o que uma webcam declara), com MJPEG ou NV12.
     */
    fun julgar(formatos: List<Formato>, temSom: Boolean, controlesDeCamera: Boolean): Veredito {
        val antiga = julgar(formatos)
        if (antiga.aceita) return antiga
        val lido = formatos.any { (it.subtipo == SUBTIPO_MJPEG || (it.subtipo == SUBTIPO_NAO_COMPRIMIDO && it.detalhe == "NV12")) && it.quadros.isNotEmpty() }
        return when {
            !temSom -> Veredito(false, antiga.porque + "; e sem interface de som (não é placa HDMI)")  // i18n-fora: o porquê vai só para o diário (UsbDv.porQueNao)
            controlesDeCamera -> Veredito(false, antiga.porque + "; e o terminal declara controles de câmera (webcam)")  // i18n-fora: o porquê vai só para o diário (UsbDv.porQueNao)
            !lido -> Veredito(false, "placa com som, mas sem MJPEG nem NV12")
            else -> Veredito(true, "placa HDMI: som UAC junto, nenhum controle de câmera, MJPEG ou NV12")  // i18n-fora: o porquê vai só para o diário (UsbDv.porQueNao)
        }
    }

    fun aceita(formatos: List<Formato>, temSom: Boolean, controlesDeCamera: Boolean): Boolean =
        julgar(formatos, temSom, controlesDeCamera).aceita

    fun julgar(formatos: List<Formato>): Veredito {
        formatos.firstOrNull { it.subtipo == SUBTIPO_NAO_COMPRIMIDO || it.subtipo == SUBTIPO_FRAME_BASED }?.let {
            return Veredito(false, "tem o formato ${it.detalhe} (subtipo 0x%02x): webcam, não placa".format(it.subtipo))  // i18n-fora: o porquê vai só para o diário (UsbDv.porQueNao)
        }
        val quadros = formatos.filter { it.subtipo == SUBTIPO_MJPEG }.flatMap { it.quadros }
        if (quadros.isEmpty()) return Veredito(false, "sem quadro MJPEG")
        quadros.firstOrNull { it.largura > LARGURA_MAX || it.altura > ALTURA_MAX }?.let {
            return Veredito(false, "quadro MJPEG ${it.largura}x${it.altura} acima de ${LARGURA_MAX}x$ALTURA_MAX")
        }
        return Veredito(true, "MJPEG só, até ${LARGURA_MAX}x$ALTURA_MAX")  // i18n-fora: o porquê vai só para o diário (UsbDv.porQueNao)
    }

    fun aceita(formatos: List<Formato>): Boolean = julgar(formatos).aceita
}

/**
 * Como o vídeo USB aparece na tela, pelo que se sabe dele (puro, testado em JVM). Antes da primeira
 * abertura só a classe das interfaces é visível (o formato está nos descritores, que pedem a
 * permissão); depois, o tipo fica lembrado por `vid:pid` ([UsbDv.tipoConhecido]).
 */
object VideoUsb {
    /** O que se sabe do aparelho: o tipo aberto, recusado pela regra, ou nada ainda. */
    enum class Conhecido { PLACA, FILMADORA_DV, RECUSADO, DESCONHECIDO }

    fun conhecido(tipo: TipoUsb?, recusado: Boolean): Conhecido = when {
        tipo == TipoUsb.MJPEG -> Conhecido.PLACA
        tipo == TipoUsb.DV -> Conhecido.FILMADORA_DV
        recusado -> Conhecido.RECUSADO
        else -> Conhecido.DESCONHECIDO
    }

    /** "Placa de captura (…)", "Filmadora DV (…)", ou "Vídeo USB (…)" antes de saber. */
    fun rotulo(t: Textos, c: Conhecido, produto: String): String = when (c) {
        Conhecido.PLACA -> t.s(R.string.placa_rotulo_placa, produto)
        Conhecido.FILMADORA_DV -> t.s(R.string.placa_rotulo_filmadora, produto)
        Conhecido.RECUSADO, Conhecido.DESCONHECIDO -> t.s(R.string.placa_rotulo_video_usb, produto)
    }

    /** O nome na frase ("a placa de captura não abriu"). */
    fun nome(t: Textos, c: Conhecido): String = when (c) {
        Conhecido.PLACA -> t.s(R.string.placa_nome_placa)
        Conhecido.FILMADORA_DV -> t.s(R.string.placa_nome_filmadora)
        Conhecido.RECUSADO, Conhecido.DESCONHECIDO -> t.s(R.string.placa_nome_video_usb)
    }

    /**
     * Os [Textos] do idioma escolhido **agora**, para quem ainda chama [rotulo] e [nome] sem eles
     * (`MirrorService`, de outra área; `docs/traducao.md`, Android). [UsbDv.lembrarEm] o põe; é uma
     * função, e não os textos, para a troca de idioma valer sem reabrir o processo.
     */
    @Volatile var textosAgora: (() -> Textos)? = null

    /** O [rotulo] no idioma de agora; sem [textosAgora] (nada abriu o USB ainda), só o produto. */
    @Deprecated("passe os Textos: rotulo(t, c, produto)")
    fun rotulo(c: Conhecido, produto: String): String = textosAgora?.let { rotulo(it(), c, produto) } ?: produto

    /** O [nome] no idioma de agora; sem [textosAgora], vazio. */
    @Deprecated("passe os Textos: nome(t, c)")
    fun nome(c: Conhecido): String = textosAgora?.let { nome(it(), c) } ?: ""

    /**
     * Aparece na lista de "O que transmitir"? **A placa, para todos** (a P3, decisão do Pessoa Exemplo de
     * 28/09); **a filmadora DV, só com a chave de bancada `camera_dv`** (a prova dela é de bancada).
     * Antes de saber, o palpite é a interface de **som** ([temSom]): a placa tem UAC (§1), a
     * filmadora DV leva o som dentro do DV. Um aparelho que a regra recusou (uma webcam) some depois
     * da primeira tentativa. Com a chave, tudo aparece, como antes.
     */
    fun naLista(c: Conhecido, temSom: Boolean, chaveDv: Boolean): Boolean = when {
        chaveDv -> true
        c == Conhecido.PLACA -> true
        c == Conhecido.DESCONHECIDO -> temSom
        else -> false
    }

    /** O palpite de "é placa" para a tela (o texto do botão, a prévia parada, o som). */
    fun pareceSerPlaca(c: Conhecido, temSom: Boolean): Boolean = when (c) {
        Conhecido.PLACA -> true
        Conhecido.DESCONHECIDO -> temSom
        else -> false
    }
}
