package com.quall.android.capture.dv

import com.quall.android.R
import com.quall.android.core.Textos
import com.quall.android.mirror.MirrorBus
import java.util.Locale

/**
 * **A tela "Placa de captura e filmadora"** (`docs/placa-de-captura-usb.md` §13), o que é puro nela:
 * quem aparece, qual é escolhido, que botões existem e o que dizem, e as frases da gravação e da
 * transmissão. A `VideoUsbActivity` só lê o estado (o [GravacaoBus], o [MirrorBus], o [DonoDaPlaca])
 * e desenha o que sai daqui; os testes JVM conferem as decisões sem aparelho.
 *
 * As frases vêm de [Textos] (`docs/traducao.md`, Android): no app, o idioma escolhido; nos testes,
 * `TextosDeTeste.PT`/`EN`.
 */
object PainelDoVideoUsb {
    /** O que se sabe do aparelho escolhido: pela fonte aberta, ou pelo lembrado por `vid:pid`. */
    enum class Tipo { PLACA, FILMADORA_DV, DESCONHECIDO }

    fun tipo(c: VideoUsb.Conhecido): Tipo = when (c) {
        VideoUsb.Conhecido.PLACA -> Tipo.PLACA
        VideoUsb.Conhecido.FILMADORA_DV -> Tipo.FILMADORA_DV
        else -> Tipo.DESCONHECIDO
    }

    /**
     * Aparece na tela? **A placa e a filmadora DV** (a tela é das duas, e o cartão diz), e o ainda
     * desconhecido (a primeira abertura diz o que ele é). O recusado pela [RegraDaPlaca] (uma webcam)
     * só com a chave de bancada `camera_dv`, como na lista de Espelhar.
     */
    fun naTela(c: VideoUsb.Conhecido, chaveDv: Boolean): Boolean =
        c != VideoUsb.Conhecido.RECUSADO || chaveDv

    /** Um aparelho candidato: o id da opção (`usb-dv:<deviceName>`), o que se sabe dele, e se tem som. */
    data class Candidato(val id: String, val conhecido: VideoUsb.Conhecido, val temSom: Boolean)

    /**
     * Qual mostrar: o [anterior] se ele ainda está plugado (a tela não troca sozinha); senão a placa,
     * a filmadora, o desconhecido com som (o palpite de placa), o desconhecido, e o recusado por
     * último — na ordem do sistema dentro de cada grupo.
     */
    fun escolher(lista: List<Candidato>, anterior: String?): Candidato? {
        lista.firstOrNull { it.id == anterior }?.let { return it }
        return lista.minByOrNull { c ->
            when {
                c.conhecido == VideoUsb.Conhecido.PLACA -> 0
                c.conhecido == VideoUsb.Conhecido.FILMADORA_DV -> 1
                c.conhecido == VideoUsb.Conhecido.DESCONHECIDO && c.temSom -> 2
                c.conhecido == VideoUsb.Conhecido.DESCONHECIDO -> 3
                else -> 4
            }
        }
    }

    // ------------------------------------------------------------------------------ os botões

    /** A transmissão no ar, vista pelo [MirrorBus]: a deste aparelho, outra, ou nenhuma. */
    enum class Transmissao { NENHUMA, ESTA, OUTRA }

    fun transmissao(m: MirrorBus.Estado): Transmissao {
        val noAr = m.fase == MirrorBus.Fase.ESPERANDO || m.fase == MirrorBus.Fase.ESPELHANDO
        return when {
            !noAr -> Transmissao.NENHUMA
            // O vídeo USB abre um aparelho só (o dono único): uma sessão de vídeo USB é deste.
            m.videoUsb && !m.daTelaR5 -> Transmissao.ESTA
            else -> Transmissao.OUTRA
        }
    }

    data class Entrada(
        val tipo: Tipo,
        /** As permissões (câmera e USB) dadas e o aparelho plugado: a prévia pode abrir. */
        val pronto: Boolean,
        val gravando: Boolean,
        val transmissao: Transmissao,
        /** O rótulo da outra transmissão ("a tela", "a câmera Traseira"), para a frase. */
        val outraFonte: String = "",
        val ouvindo: Boolean = false,
    )

    data class Botoes(
        val gravarTexto: String,
        val gravarHabilitado: Boolean,
        val transmitirTexto: String,
        val transmitirHabilitado: Boolean,
        val ouvirVisivel: Boolean,
        val ouvirTexto: String,
        val fotoVisivel: Boolean,
        /** Por que um botão está apagado, ou o que ainda não dá (vazio sem nada a dizer). */
        val nota: String,
    )

    /** A frase da filmadora com um dono só entre gravar e transmitir (o [DonoDaPlaca.exclusividade]). */
    fun fraseDvUmaCoisa(t: Textos): String = t.s(R.string.placa_dv_uma_coisa)

    fun botoes(t: Textos, e: Entrada): Botoes {
        val dv = e.tipo == Tipo.FILMADORA_DV
        val transmitindo = e.transmissao == Transmissao.ESTA
        val notas = ArrayList<String>()
        var podeGravar = e.pronto
        var podeTransmitir = e.pronto
        if (e.transmissao == Transmissao.OUTRA) {
            podeTransmitir = false
            notas += t.s(R.string.placa_nota_outra_transmissao, e.outraFonte.ifBlank { t.s(R.string.placa_outra_fonte) })
        }
        if (dv && e.gravando && !transmitindo) { podeTransmitir = false; notas += fraseDvUmaCoisa(t) }
        if (dv && transmitindo && !e.gravando) { podeGravar = false; notas += fraseDvUmaCoisa(t) }
        // Parar é sempre possível: o que está no ar se para daqui, pronto ou não.
        if (e.gravando) podeGravar = true
        if (transmitindo) podeTransmitir = true
        return Botoes(
            gravarTexto = when {
                e.gravando -> t.s(R.string.placa_parar_gravacao)
                dv -> t.s(R.string.placa_gravar_a_fita)
                else -> t.s(R.string.placa_gravar)
            },
            gravarHabilitado = podeGravar,
            transmitirTexto = t.s(if (transmitindo) R.string.placa_parar_transmissao else R.string.placa_transmitir),
            transmitirHabilitado = podeTransmitir,
            // O som da placa é um `AudioRecord` da entrada USB dela; o da fita vem dentro do DV, e a
            // fonte o toca quadro a quadro (§13.7).
            ouvirVisivel = (e.tipo == Tipo.PLACA || dv) && e.pronto,
            ouvirTexto = t.s(if (e.ouvindo) R.string.placa_parar_de_ouvir else R.string.placa_ouvir),
            fotoVisivel = e.tipo != Tipo.DESCONHECIDO && e.pronto,
            nota = notas.joinToString("\n"),
        )
    }

    // ------------------------------------------------------------------------------ as frases

    /** `h:mm:ss`. */
    fun tempo(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0)
        return "%d:%02d:%02d".format(Locale.US, s / 3600, s / 60 % 60, s % 60)
    }

    /** "12,3 MB" até 1 GB, depois "1,23 GB": a vírgula do português, o ponto do inglês (o formato no recurso). */
    fun tamanho(t: Textos, bytes: Long): String =
        if (bytes < 1_000_000_000L) t.s(R.string.placa_tamanho_mb, bytes / 1e6)
        else t.s(R.string.placa_tamanho_gb, bytes / 1e9)

    /** A caixa da gravação: vazia quando não há o que dizer. */
    fun textoDaGravacao(t: Textos, g: GravacaoBus.Estado): String = when (g.fase) {
        GravacaoBus.Fase.NADA -> ""
        GravacaoBus.Fase.PREPARANDO -> t.s(R.string.placa_preparando_gravacao)
        GravacaoBus.Fase.GRAVANDO -> buildString {
            append(t.s(R.string.placa_gravando_arquivo, g.nome)).append('\n')
            append(tempo(g.decorridoMs)).append(" · ").append(tamanho(t, g.bytes))
            if (g.espacoLivre > 0) append(" · ").append(t.s(R.string.placa_livre, tamanho(t, g.espacoLivre)))
            if (g.pausada) append('\n').append(
                t.s(if (g.daPlaca) R.string.placa_pausa_placa else R.string.placa_pausa_fita)
            )
            g.avisoDoSom?.let { append('\n').append(t.s(R.string.placa_som_aviso, it)) }
        }
        GravacaoBus.Fase.PARADA -> if (g.mensagem.isBlank()) "" else t.s(R.string.placa_gravacao_parada, g.mensagem)
    }

    /** O bloco da transmissão desta fonte: a manchete, o PIN e os endereços, ou para quem vai. */
    data class Espera(
        val manchete: String,
        /** O PIN em dois grupos ("123 456"), vazio quando não se mostra (enviando, ou ainda sem PIN). */
        val pin: String,
        val endereco: String,
        val outros: String,
        val para: String,
        /** Sem endereço nenhum: [endereco] diz "sem rede" e não se copia. */
        val semRede: Boolean = false,
    )

    fun espera(t: Textos, m: MirrorBus.Estado): Espera? {
        if (transmissao(m) != Transmissao.ESTA) return null
        if (m.fase == MirrorBus.Fase.ESPELHANDO) {
            return Espera(t.s(R.string.placa_transmitindo), "", "", "",
                t.s(R.string.placa_enviando_para, m.par.ifBlank { t.s(R.string.placa_outro_aparelho) }))
        }
        val pin = m.pin.filter { it.isDigit() }.let { if (it.length == 6) it.substring(0, 3) + " " + it.substring(3) else it }
        return Espera(
            manchete = t.s(R.string.placa_esperando_outro_aparelho),
            pin = pin,
            endereco = m.enderecos.firstOrNull() ?: t.s(R.string.placa_sem_rede),
            outros = m.enderecos.drop(1).takeIf { it.isNotEmpty() }
                ?.let { t.s(R.string.placa_tambem_enderecos, it.joinToString("  ·  ")) } ?: "",
            para = "",
            semRede = m.enderecos.isEmpty(),
        )
    }
}
