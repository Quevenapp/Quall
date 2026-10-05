package com.quall.android.teleprompter

import com.quall.android.R
import com.quall.android.core.QuallNative
import com.quall.android.core.Textos

/**
 * **"Segurar para rolar", o lado do controle** (`docs/contrato-teleprompter.md` §12.5) — os dedos
 * nos dois botões e o que sai para a réplica, sem uma linha de Android.
 *
 * O pedido do usuário: dois botões grandes, "Rolar para cima" e "Rolar para baixo"; segurando, o
 * texto rola na velocidade ajustada; soltou, o texto para. As regras daqui:
 *
 * - **Encostar** num botão segura (`hold`), sempre — é o único aperto que existe. Escorregar para
 *   dentro de um botão não aperta.
 * - **Dois dedos: vale o último botão apertado.** Se ele sai e sobra um dedo no outro botão, o
 *   sentido volta para o desse dedo — ele continua segurando.
 * - **Soltar** (`release`) só quando nenhum dedo sobra num botão: levantou, o toque foi cancelado,
 *   escorregou para fora, a tela foi para o segundo plano ou fechou ([soltarTudo]).
 * - **O texto que parou sozinho** — `"segurando"` voltou a `false` com o dedo no botão: a queda, o
 *   silêncio de 2,5 s, a pausa no prompter (§12.4) — fica parado. Nada aperta de novo sozinho,
 *   nem o dedo que sobra quando o outro sai: a pessoa solta e aperta de novo ([parou]).
 *
 * - **"Inverter botões"** ([inverter]): o de cima passa a avançar e o de baixo a voltar — setas e
 *   rótulos no lugar, as legendas trocando junto. **Com um dedo num botão de rolar, a troca não
 *   vale** ("fica desligada até soltar"), e por isso o sentido nunca muda no meio de um aperto.
 *
 * Quem chama passa cada toque ([encostou], [saiu]) e, a cada desenho, o `"segurando"` da réplica
 * ([conferir]). A [Porta] é a réplica (`ReplicaDoTeleprompter.segurar`/`soltar`).
 */
class SegurarParaRolar(private val porta: Porta, invertido: Boolean = false) {

    enum class Botao { CIMA, BAIXO }

    /** Por onde o gesto chega à réplica. Devolve o `QuallStatus` de cada chamada. */
    interface Porta {
        fun segurar(paraTras: Boolean): Int
        fun soltar(): Int
    }

    /** Cada dedo num botão, **na ordem em que encostou**: o último manda. */
    private val dedos = LinkedHashMap<Int, Botao>()

    /** O botão do último `hold` que deu `OK`, enquanto ele vale; `null` sem nada seguro daqui. */
    var seguro: Botao? = null
        private set

    /** O texto parou com o dedo ainda no botão: "Solte e aperte de novo." */
    var parou = false
        private set

    /** O `QuallStatus` do último `hold` (`PROTOCOL`: o prompter não entende; `CLOSED`: sem sessão). */
    var ultimoStatus = QuallNative.Status.OK
        private set

    /** O botão do último dedo que encostou e ainda está nele — o que se desenha apertado. */
    val ativo: Botao? get() = dedos.values.lastOrNull()

    val algumDedo: Boolean get() = dedos.isNotEmpty()

    /** Este dedo está num botão (encostou e ainda não saiu). */
    fun conhece(dedo: Int): Boolean = dedos.containsKey(dedo)

    /** "Inverter botões" ligado: o de cima avança e o de baixo volta. */
    var invertido: Boolean = invertido
        private set

    /**
     * Liga ou desliga a inversão. **Com um dedo num botão de rolar, não vale**: devolve `false` e
     * nada muda — o pedido do usuário, "fica desligada até soltar".
     */
    fun inverter(sim: Boolean): Boolean {
        if (dedos.isNotEmpty()) return false
        invertido = sim
        return true
    }

    /** O `para_tras` que este botão manda agora, com a inversão de agora. */
    fun paraTrasDe(botao: Botao): Boolean = paraTras(botao, invertido)

    /**
     * Um dedo encostou num botão (ligado: quem chama não passa o toque de botão desligado). É um
     * aperto de verdade — segura, mesmo depois de "o texto parou".
     */
    fun encostou(dedo: Int, botao: Botao): Int {
        dedos.remove(dedo)
        dedos[dedo] = botao
        parou = false
        return segurar(botao)
    }

    /**
     * Um dedo saiu do botão: levantou, o toque foi cancelado ou ele escorregou para fora. Devolve
     * o status do que saiu para a réplica, ou `null` se nada saiu (dedo desconhecido, ou sobrou
     * outro dedo no mesmo sentido).
     */
    fun saiu(dedo: Int): Int? {
        if (dedos.remove(dedo) == null) return null
        val resta = ativo ?: return soltar()
        // Sobrou um dedo em outro botão: ele segura, se ainda há o que segurar. Depois de "o texto
        // parou" (ou de um aperto recusado), não — seria apertar de novo sozinho.
        if (parou || seguro == null || seguro == resta) return null
        return segurar(resta)
    }

    /** A tela foi para o segundo plano, fechou, ou saiu do modo: solta o que houver. */
    fun soltarTudo(): Int? {
        if (dedos.isEmpty()) return null
        dedos.clear()
        return soltar()
    }

    /**
     * O `"segurando"` da réplica, a cada desenho. Devolve `true` quando o texto **acabou** de parar
     * com o dedo no botão (para quem chama registrar uma vez só).
     */
    fun conferir(segurando: Boolean): Boolean {
        if (seguro == null || dedos.isEmpty() || segurando) return false
        seguro = null
        parou = true
        return true
    }

    private fun segurar(botao: Botao): Int {
        val st = porta.segurar(paraTrasDe(botao))
        ultimoStatus = st
        seguro = if (st == QuallNative.Status.OK) botao else null
        return st
    }

    /** Sem nada seguro, o núcleo não faz nada (nem pausa um play normal): chamar sempre é seguro. */
    private fun soltar(): Int {
        val st = porta.soltar()
        seguro = null
        parou = false
        return st
    }

    /** O que o modo mostra: se os botões funcionam, e o aviso (ou nenhum). */
    data class Situacao(val botoesLigados: Boolean, val aviso: String?)

    companion object {
        /**
         * **O mapeamento da §12.5, num lugar só.** "Rolar para cima" volta o texto
         * (`hold(t, true)`); "Rolar para baixo" avança (`hold(t, false)`). Com **"Inverter botões"**
         * ([invertido]; pedido do usuário, 14/09 à tarde: no espelho do suporte o texto pode andar ao
         * contrário da seta) os dois trocam — e é só aqui que trocam. As legendas embaixo de cada
         * botão ("volta o texto", "avança o texto") saem de [efeito], e trocam junto.
         */
        fun paraTras(botao: Botao, invertido: Boolean = false): Boolean = when (botao) {
            Botao.CIMA -> true
            Botao.BAIXO -> false
        } != invertido

        /** A legenda pequena embaixo de cada botão, derivada do mapeamento: o que ele faz agora. */
        fun efeito(botao: Botao, t: Textos, invertido: Boolean = false): String =
            t.s(if (paraTras(botao, invertido)) R.string.tp_efeito_volta else R.string.tp_efeito_avanca)

        /**
         * **O "Rolar"/"Parar" de sempre, nas duas telas** (regra da revisão do núcleo, 14/09): manda
         * só o que a pessoa apertou — o rótulo que ela via ([querRolar]) — contra o estado **relido
         * agora**, e nada se ele já está assim. Um alternar calculado com estado velho reafirmaria
         * `set_scrolling(true)` com o texto já rolando; no meio de um segurar, isso tira o texto do
         * segurar (`set_scrolling` zera `segurando`), e ele seguiria rolando depois do soltar.
         * No controle, nunca durante o segurar ([segurandoAgora]); no prompter, a pausa no meio
         * de um segurar vale — é a pessoa do prompter parando o texto (§12.3).
         *
         * Devolve o valor a mandar, ou `null` para não mandar nada.
         */
        fun rolarOuParar(querRolar: Boolean, rolandoAgora: Boolean, segurandoAgora: Boolean = false): Boolean? = when {
            segurandoAgora -> null
            querRolar == rolandoAgora -> null
            else -> querRolar
        }

        /**
         * O aviso do modo e se os botões funcionam, por ordem de importância:
         *
         * 1. sem sessão ([semConexao], o estado da conexão): botões desligados — e, se o texto parou
         *    com o dedo no botão (a queda, o silêncio), o aviso diz as duas coisas;
         * 2. a sessão acabou de subir e o prompter ainda não falou: desligados — sem isso o aviso de
         *    atualizar piscaria a cada conexão;
         * 3. o prompter não diz que entende (`"par_entende_segurar"` falso, ou `PROTOCOL`):
         *    desligados, "atualize o app do prompter" — um prompter de 13/09 rolaria para a frente
         *    no "Rolar para cima" (§12.2);
         * 4. o texto parou com o dedo no botão; 5. o comando sem confirmação. Nesses, ligados.
         *
         * Os avisos são as chaves `tp_segurar_*`, no idioma de [t] (`docs/traducao.md`, Android).
         */
        fun situacao(
            semConexao: String?,
            parVisto: Boolean,
            entende: Boolean,
            recusado: Boolean,
            parou: Boolean,
            comandoNaoChegou: Boolean,
            t: Textos,
        ): Situacao = when {
            // A queda com o dedo no botão: as duas coisas, o texto parado e a conexão.
            semConexao != null && parou -> Situacao(false, t.s(R.string.tp_segurar_parou_e, semConexao))
            semConexao != null -> Situacao(false, semConexao)
            !parVisto -> Situacao(false, t.s(R.string.tp_segurar_esperando))
            !entende || recusado -> Situacao(false, t.s(R.string.tp_segurar_atualize))
            parou -> Situacao(true, t.s(R.string.tp_segurar_parou))
            comandoNaoChegou -> Situacao(true, t.s(R.string.tp_segurar_nao_chegou))
            else -> Situacao(true, null)
        }
    }
}
