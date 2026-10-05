package com.quall.android.teleprompter

/**
 * **O texto que chega do outro lado enquanto o editor está aberto** — a regra desta tela (item 3
 * da frente F6b; o contrato deixa a decisão com as telas, §6: "o núcleo não mistura").
 *
 * ## A escolha: nunca apagar o que a pessoa digitou sem perguntar
 *
 * O núcleo funde campo a campo e "vale o último que mudou" — para o texto, o roteiro inteiro. Ele
 * não tem como saber de um **rascunho**, que só existe na tela. Então:
 *
 * 1. **A pessoa não mexeu no rascunho** (ele ainda é o texto de quando o editor abriu): o rascunho
 *    vira o texto que chegou, em silêncio — não há nada a perder, e editar em cima do texto velho
 *    faria a confirmação desfazer a edição do outro lado sem ninguém ver.
 * 2. **A pessoa já mexeu**: o rascunho **fica**, e um aviso pergunta: "usar o texto novo" (joga
 *    fora o que foi digitado aqui) ou "manter o meu" (o aviso some; ao confirmar, o texto daqui vai
 *    para os dois lados, porque é a edição mais recente — a regra do usuário).
 * 3. Cancelar descarta o rascunho: a tela mostra o texto da réplica, que já é o que chegou.
 *
 * O `set_text` sai **só ao confirmar**, nunca a cada tecla (§6), e só se o rascunho difere do texto
 * de base — confirmar sem mudar nada não carimba nada.
 */
class EdicaoDoTexto {

    enum class Reacao {
        /** Nada a fazer na tela (editor fechado, ou o texto que chegou é o que já estava). */
        NADA,

        /** Trocar o rascunho pelo texto novo, sem perguntar: a pessoa ainda não tinha mexido. */
        TROCAR_O_RASCUNHO,

        /** Mostrar o aviso com as duas escolhas; o rascunho fica como está. */
        PERGUNTAR,
    }

    var aberta: Boolean = false
        private set

    /** O texto da réplica que o rascunho conhece: o de quando abriu, ou o último aceito. */
    var base: String = ""
        private set

    /** O texto que chegou e espera a escolha da pessoa; `null` sem pergunta pendente. */
    var chegadoPendente: String? = null
        private set

    /** Abre com o texto atual da réplica; devolve o rascunho inicial. */
    fun abrir(atual: String): String {
        aberta = true
        base = atual
        chegadoPendente = null
        return atual
    }

    /** Chegou um texto novo do outro lado (bit `_TEXT`) e o rascunho está como `rascunho`. */
    fun chegou(novo: String, rascunho: String): Reacao {
        if (!aberta) return Reacao.NADA
        if (novo == base && chegadoPendente == null) return Reacao.NADA
        return when (rascunho) {
            // A pessoa não mexeu: o rascunho acompanha, em silêncio.
            base -> {
                base = novo
                chegadoPendente = null
                Reacao.TROCAR_O_RASCUNHO
            }
            // Coincidência: os dois lados chegaram ao mesmo texto. Nada a perguntar.
            novo -> {
                base = novo
                chegadoPendente = null
                Reacao.NADA
            }
            else -> {
                chegadoPendente = novo
                Reacao.PERGUNTAR
            }
        }
    }

    /** "Usar o texto novo": devolve o texto para o rascunho, ou `null` se não havia pergunta. */
    fun aceitarONovo(): String? {
        val n = chegadoPendente ?: return null
        base = n
        chegadoPendente = null
        return n
    }

    /**
     * "Manter o meu": o aviso some e o rascunho fica. A base passa a ser o texto que chegou — é o
     * que a réplica tem agora —, então um terceiro texto chegando pergunta de novo.
     */
    fun manterOMeu() {
        chegadoPendente?.let { base = it }
        chegadoPendente = null
    }

    /**
     * O que confirmar mandaria, **sem fechar nada**: `null` se o rascunho não muda o texto. A tela
     * pergunta isto antes de chamar o núcleo, e só fecha ([confirmar]) se ele aceitou — uma recusa
     * (texto grande demais) deixa o editor exatamente como estava, com a pergunta pendente e tudo.
     */
    fun aMandar(rascunho: String): String? = if (!aberta || rascunho == base) null else rascunho

    /** Há algo digitado que fechar o editor jogaria fora? (Voltar pergunta antes.) */
    fun temRascunho(rascunho: String): Boolean = aMandar(rascunho) != null

    /** Fecha e devolve o texto a mandar ao núcleo, ou `null` se o rascunho não muda nada. */
    fun confirmar(rascunho: String): String? {
        val mandar = if (rascunho == base) null else rascunho
        aberta = false
        chegadoPendente = null
        return mandar
    }

    fun cancelar() {
        aberta = false
        chegadoPendente = null
    }
}
