package com.quall.android.teleprompter

import java.security.MessageDigest

/**
 * O estado para a tela desenhar, lido de `quall_teleprompter_state_json`
 * (`docs/contrato-teleprompter.md` §6, literal):
 *
 * ```json
 * {"rolando":false,"velocidade":1.0,"fonte":48.0,"margem":0.1,"linha_de_leitura":0.3,
 *  "espelho":false,"posicao":0.0,"salto":null,"texto_bytes":0,"par_visto_ha_ms":null,
 *  "sem_confirmacao_ha_ms":null,"contadores":{…}}
 * ```
 *
 * A tela **só lê** este estado; quem o escreve é a réplica do núcleo. Um campo que falta ou vem
 * com tipo errado cai no padrão do contrato — nunca derruba a leitura inteira (a mesma regra que o
 * núcleo aplica na chegada: campo a campo).
 */
data class EstadoDoTeleprompter(
    val rolando: Boolean = false,
    /** Linhas por segundo (linha = altura da linha na fonte do prompter), 0,05 a 20. */
    val velocidade: Double = 1.0,
    /** Pontos lógicos — `sp` no Android. 8 a 400. */
    val fonte: Double = 48.0,
    /** Fração da largura da vista do texto, de cada lado. 0 a 0,45. */
    val margem: Double = 0.1,
    /** Fração da altura da vista do texto, a partir do topo. 0 a 1. */
    val linhaDeLeitura: Double = 0.3,
    val espelho: Boolean = false,
    /** Fração do percurso: 0 = começo na linha de leitura, 1 = fim nela. */
    val posicao: Double = 0.0,
    /** O alvo do salto mais recente, ou `null` se nunca houve. */
    val salto: Double? = null,
    val textoBytes: Long = 0,
    /** Há quantos ms chegou a última mensagem do outro lado; `null` se nada chegou nesta sessão. */
    val parVistoHaMs: Long? = null,
    /** Há quantos ms uma edição daqui espera confirmação; `null` se está tudo confirmado. */
    val semConfirmacaoHaMs: Long? = null,
    val contadores: Map<String, Long> = emptyMap(),
    /**
     * "Segurar para rolar" (§12): com [rolando], rola **para trás**. Fora do fio enquanto ninguém
     * segurou — o padrão `false` é o estado de quem nunca segurou.
     */
    val paraTras: Boolean = false,
    /** O dedo do controle no botão de segurar (§12.1). */
    val segurando: Boolean = false,
    /** O outro lado disse, no último estado dele, que entende o segurar (o prompter que liga `enable_hold`). */
    val parEntendeSegurar: Boolean = false,
    /** A pergunta do texto (§11.6): `null` sem nada retido. Só existe com a trava ligada (o controle). */
    val perguntaDoTexto: PerguntaDoTexto? = null,
    /** "Roteiros guardados" (§11.5): até três, a mais nova primeiro. */
    val copiasDoTexto: List<CopiaDoTexto> = emptyList(),
    /** Há quanto tempo o prompter grava (§13.1), `null` parado. */
    val gravandoHaMs: Long? = null,
    /** No prompter: o pedido que a tela decide; no controle: o daqui sem resposta (§13.7). */
    val pedidoDeGravacao: PedidoDeGravacao? = null,
    /** A recusa do último pedido (§13.3), com o motivo legível. */
    val gravacaoRecusada: RecusaDeGravacao? = null,
    /** O outro lado disse que grava (o prompter da tela com câmera). */
    val parEntendeGravar: Boolean = false,
) {
    /** `"pedido_de_gravacao"`: `n` é o carimbo de Lamport do controle; [haMs] no relógio daqui. */
    data class PedidoDeGravacao(val n: Long, val gravar: Boolean, val haMs: Long)

    data class RecusaDeGravacao(val n: Long, val gravar: Boolean, val motivo: String)

    fun contador(nome: String): Long = contadores[nome] ?: 0L

    /** Um texto como a pergunta o mostra: o tamanho, o resumo (a chave) e a prévia (até 240 bytes). */
    data class VistaDoTexto(val bytes: Long, val resumo: String, val previa: String)

    /**
     * `"pergunta_do_texto"`: comparando (`aberta` falso, sem [doPrompter]) ou perguntando (`aberta`,
     * os dois textos em mãos e diferentes). [retidoHaMs] conta desde que o texto foi retido nesta sessão.
     */
    data class PerguntaDoTexto(
        val aberta: Boolean,
        val retidoHaMs: Long,
        val prompterId: String,
        val prompterNome: String,
        val meu: VistaDoTexto?,
        val doPrompter: VistaDoTexto?,
    )

    /** Uma cópia guardada: `origem` é `"prompter"` (o texto dele) ou `"controle"` (o daqui, antes dele). */
    data class CopiaDoTexto(
        val origem: String,
        val prompterId: String,
        val prompterNome: String,
        /** Relógio de parede da hora da cópia, em ms. */
        val quandoMs: Long,
        val bytes: Long,
        val resumo: String,
        val previa: String,
    ) {
        val doPrompter: Boolean get() = origem == "prompter"
    }

    companion object {
        /** `null` só quando o texto nem é um objeto JSON — aí não há o que desenhar. */
        fun ler(json: String): EstadoDoTeleprompter? {
            val o = JsonSimples.objeto(json) ?: return null
            val padrao = EstadoDoTeleprompter()
            fun num(k: String): Double? = (o[k] as? Double)?.takeIf { it.isFinite() }
            fun bool(k: String): Boolean? = o[k] as? Boolean
            fun inteiro(k: String): Long? = num(k)?.toLong()
            @Suppress("UNCHECKED_CAST")
            val cont = (o["contadores"] as? Map<String, Any?>)
                ?.mapNotNull { (k, v) -> (v as? Double)?.let { k to it.toLong() } }
                ?.toMap()
                .orEmpty()
            return EstadoDoTeleprompter(
                rolando = bool("rolando") ?: padrao.rolando,
                velocidade = num("velocidade") ?: padrao.velocidade,
                fonte = num("fonte") ?: padrao.fonte,
                margem = num("margem") ?: padrao.margem,
                linhaDeLeitura = num("linha_de_leitura") ?: padrao.linhaDeLeitura,
                espelho = bool("espelho") ?: padrao.espelho,
                posicao = num("posicao") ?: padrao.posicao,
                salto = num("salto"),
                textoBytes = inteiro("texto_bytes") ?: 0,
                parVistoHaMs = inteiro("par_visto_ha_ms"),
                semConfirmacaoHaMs = inteiro("sem_confirmacao_ha_ms"),
                contadores = cont,
                paraTras = bool("para_tras") ?: false,
                segurando = bool("segurando") ?: false,
                parEntendeSegurar = bool("par_entende_segurar") ?: false,
                perguntaDoTexto = (o["pergunta_do_texto"] as? Map<*, *>)?.let(::pergunta),
                copiasDoTexto = (o["copias_do_texto"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.let(::copia) }.orEmpty(),
                gravandoHaMs = inteiro("gravando_ha_ms"),
                pedidoDeGravacao = (o["pedido_de_gravacao"] as? Map<*, *>)?.let(::pedido),
                gravacaoRecusada = (o["gravacao_recusada"] as? Map<*, *>)?.let(::recusa),
                parEntendeGravar = bool("par_entende_gravar") ?: false,
            )
        }

        private fun texto(o: Map<*, *>, k: String): String = o[k] as? String ?: ""
        private fun inteiro(o: Map<*, *>, k: String): Long? = (o[k] as? Double)?.takeIf { it.isFinite() }?.toLong()

        private fun vista(o: Map<*, *>?): VistaDoTexto? {
            o ?: return null
            val resumo = o["resumo"] as? String ?: return null
            return VistaDoTexto(inteiro(o, "bytes") ?: 0, resumo, texto(o, "previa"))
        }

        private fun pergunta(o: Map<*, *>): PerguntaDoTexto = PerguntaDoTexto(
            aberta = o["aberta"] as? Boolean ?: false,
            retidoHaMs = inteiro(o, "retido_ha_ms") ?: 0,
            prompterId = texto(o, "prompter_id"),
            prompterNome = texto(o, "prompter_nome"),
            meu = vista(o["meu"] as? Map<*, *>),
            doPrompter = vista(o["do_prompter"] as? Map<*, *>),
        )

        /** Sem `n` não há o que responder: fica de fora. */
        private fun pedido(o: Map<*, *>): PedidoDeGravacao? {
            val n = inteiro(o, "n") ?: return null
            return PedidoDeGravacao(n, o["gravar"] as? Boolean ?: false, inteiro(o, "ha_ms") ?: 0)
        }

        private fun recusa(o: Map<*, *>): RecusaDeGravacao? {
            val n = inteiro(o, "n") ?: return null
            return RecusaDeGravacao(n, o["gravar"] as? Boolean ?: false, texto(o, "motivo"))
        }

        /** Uma cópia sem resumo não tem chave (nem para ver, nem para apagar): fica de fora. */
        private fun copia(o: Map<*, *>): CopiaDoTexto? {
            val resumo = o["resumo"] as? String ?: return null
            return CopiaDoTexto(
                origem = texto(o, "origem"),
                prompterId = texto(o, "prompter_id"),
                prompterNome = texto(o, "prompter_nome"),
                quandoMs = inteiro(o, "quando_ms") ?: 0,
                bytes = inteiro(o, "bytes") ?: 0,
                resumo = resumo,
                previa = texto(o, "previa"),
            )
        }
    }
}

/**
 * O **resumo** do texto, igual ao do núcleo (`teleprompter::resumo`): os primeiros 8 bytes do
 * SHA-256, em hex. Só para o registro: é o que prova, sem gravar o roteiro em lugar nenhum, que o
 * texto que chegou é **o mesmo** que saiu do outro lado — a `quall-probe` imprime o mesmo resumo.
 */
object Resumo {
    fun de(texto: String): String {
        val h = MessageDigest.getInstance("SHA-256").digest(texto.toByteArray(Charsets.UTF_8))
        return h.take(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
