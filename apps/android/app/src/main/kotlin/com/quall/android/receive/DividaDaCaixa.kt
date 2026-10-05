package com.quall.android.receive

/**
 * O quadro descartado **na caixa**, e o pedido de IDR que ele deve — com quando pagar.
 *
 * Aritmética pura: sem JNI, sem relógio do sistema, sem `Log`. O relógio entra por parâmetro, em
 * µs (o do `MonotonicClock`), e é isso que deixa [DividaDaCaixaTest] exercitar na JVM.
 *
 * # O que faltava
 *
 * A caixa de quadros em C descarta o mais velho quando o laço não dá conta de tirá-lo a tempo
 * (`descartados_na_caixa`), e joga fora o quadro que não cabe no buffer do decodificador
 * (`nao_couberam`). O quadro tinha chegado inteiro, o núcleo não vê nada, e para o decodificador é
 * perda do mesmo jeito: o seguinte referencia algo que nunca foi decodificado. O receptor contava a
 * ruptura e **não pedia IDR**: a imagem ficava quebrada até o próximo IDR programado do emissor —
 * até 10 s na tela estendida do Mac. Na sessão do `SM-X230` a 60 fps de 10/09/2026 foram 31
 * descartes, 826 suspeitos e 7 pedidos de IDR na sessão inteira, contando o de entrada — nenhum
 * pela caixa (`docs/tela-estendida.md`).
 *
 * # O pedido espera a caixa acalmar
 *
 * O descarte só **anota a dívida**. O pedido sai quando a caixa passa a calmaria sem descartar. A
 * calmaria é a do receptor do Windows (`CALMARIA_DA_FILA` em `apps/windows/src/receptor.rs`), e o
 * motivo foi medido lá em 09/09/2026: a fila enche porque o laço não dá conta, e o IDR é o quadro
 * mais caro de decodificar. Pedido *durante* o transbordo, ele alimenta o transbordo — 358 IDRs em
 * 105 s, e a imagem virou sujeira de movimento. Os 500 ms também são os de lá, **não medidos nesta
 * casca**; por isso a chave de bancada. O resto desta peça — o IDR que paga, o pedido repetido, o
 * recuo — não existe no Windows.
 *
 * O custo desse cuidado: com a caixa descartando **sem parar**, este pedido nunca sai, e quem cura é
 * o GOP do emissor. É o comportamento do Windows, e o de antes desta peça.
 *
 * # Qualquer IDR paga
 *
 * A caixa descarta **o mais velho** — inclusive quando falta memória para o quadro novo, caso em
 * que ela esvazia (`quall_jni.c`) —, então todo descarte já contado quando um quadro é tirado é
 * anterior a ele. Se esse quadro é um IDR — do nosso pedido, de um pedido por perda de rede ou do
 * GOP —, a cadeia está curada e a dívida some. Sem isto, o pedido sairia depois de a imagem já ter
 * voltado, e injetaria um IDR à toa.
 *
 * # Um pedido de outra causa também conta, se saiu durante a dívida
 *
 * O IDR que ele gerar vai chegar depois do descarte, e paga. Pedir de novo em cima dele seria um
 * segundo IDR para o mesmo buraco. Um pedido que saiu **antes** da dívida não conta: o IDR dele
 * pode já ter passado — é a regra da supressão por causa, em `ReceptorSessao`.
 *
 * # Pedir de novo, com recuo
 *
 * Pedido feito e nenhum IDR em 1 s, pede outra vez: o PLI vai por UDP e pode se perder, ou o IDR
 * pode ter sido justamente o descartado — ou o que não coube. O A/B de 10/09 mediu ≤ 55 ms do pedido
 * ao IDR entrar no decodificador; 1 s é folga de ~18 vezes e ainda curto perto do GOP de 10 s. Cada
 * repetição sem resposta dobra a espera, até [tetoUs]: um IDR que nunca cabe no decodificador não
 * vira um IDR por segundo para sempre.
 *
 * # O recuo contra a espiral
 *
 * A calmaria protege do transbordo contínuo, mas não de um ciclo: o IDR pedido chega, decodificá-lo
 * atrasa o laço, a caixa descarta de novo, e depois da calmaria sai outro pedido — ~1,7 IDR/s de
 * rajadas de 440–580 pacotes. Então um episódio que começa menos de [janelaDeReincidenciaUs] depois
 * de um IDR **nosso** ter pago o anterior dobra a calmaria, até [tetoUs]; um episódio fora dessa
 * janela a devolve ao valor de base. Achado da revisão de 10/09, **não visto em campo**: é teto de
 * dano, não conserto medido.
 */
class DividaDaCaixa(
    private val calmariaUs: Long = 500_000L,
    private val repedirUs: Long = 1_000_000L,
    private val tetoUs: Long = 4_000_000L,
    private val janelaDeReincidenciaUs: Long = 2_000_000L,
) {
    private var devendo = false
    private var ultimoDescarteUs = 0L
    private var calmariaAtualUs = calmariaUs

    private var pediu = false
    private var pediuEmUs = 0L
    private var pedidosSemResposta = 0

    private var outroPediu = false
    private var outroPediuEmUs = 0L

    private var ultimaPagaPorPedido = false
    private var pagaPorPedidoEmUs = 0L

    /** Dívidas **distintas**: uma rajada de descartes antes do IDR conta uma. */
    var episodios = 0L
        private set

    /** Pedidos que saíram por esta causa, contando os repetidos. */
    var pedidos = 0L
        private set

    /** Dívidas que um IDR pagou sem pedido desta causa — GOP, perda de rede ou outra causa. */
    var pagasSemPedido = 0L
        private set

    /** Episódios que começaram logo depois de um IDR nosso — cada um dobrou a calmaria. */
    var reincidencias = 0L
        private set

    val devendoAgora: Boolean get() = devendo

    /** A caixa descartou (o contador subiu entre duas tiradas). */
    fun notarDescarte(agoraUs: Long) {
        if (!devendo) {
            devendo = true
            episodios++
            if (ultimaPagaPorPedido && agoraUs - pagaPorPedidoEmUs < janelaDeReincidenciaUs) {
                reincidencias++
                calmariaAtualUs = minOf(calmariaAtualUs * 2, tetoUs)
            } else {
                calmariaAtualUs = calmariaUs
            }
        }
        ultimoDescarteUs = agoraUs
    }

    /** Um IDR saiu da caixa: paga tudo o que foi descartado antes dele. */
    fun notarIdr(agoraUs: Long) {
        if (devendo) {
            if (!pediu) pagasSemPedido++
            ultimaPagaPorPedido = pediu
            pagaPorPedidoEmUs = agoraUs
        }
        devendo = false
        pediu = false
        pedidosSemResposta = 0
        outroPediu = false
    }

    /**
     * Se o pedido pode sair agora. O piso entre pedidos de causas diferentes não é conta daqui:
     * fica com quem tem o relógio compartilhado (`ReceptorSessao`).
     */
    fun devePedir(agoraUs: Long): Boolean =
        devendo &&
            agoraUs - ultimoDescarteUs >= calmariaAtualUs &&
            (!pediu || agoraUs - pediuEmUs >= esperaParaRepetir()) &&
            (!outroPediu || agoraUs - outroPediuEmUs >= repedirUs)

    /** O pedido desta causa saiu de fato (status OK). */
    fun pediu(agoraUs: Long) {
        pediu = true
        pediuEmUs = agoraUs
        pedidosSemResposta++
        pedidos++
    }

    /** Saiu um pedido de **outra** causa. Só conta se a dívida já existia. */
    fun outroPedidoSaiu(agoraUs: Long) {
        if (!devendo) return
        outroPediu = true
        outroPediuEmUs = agoraUs
    }

    /** 1 s depois do primeiro pedido, 2 s depois do segundo, e assim até o teto. */
    private fun esperaParaRepetir(): Long {
        var espera = repedirUs
        repeat((pedidosSemResposta - 1).coerceIn(0, 8)) { espera = minOf(espera * 2, tetoUs) }
        return minOf(espera, tetoUs)
    }

    fun linha(): String =
        "episodios=$episodios pedidos=$pedidos pagas_sem_pedido=$pagasSemPedido " +
            "reincidencias=$reincidencias pendente=${if (devendo) "sim" else "nao"}"
}
