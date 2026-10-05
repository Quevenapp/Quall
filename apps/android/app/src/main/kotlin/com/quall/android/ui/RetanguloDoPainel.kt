package com.quall.android.ui

/**
 * **Onde o painel "Ajustes da câmera" fica, com as barras do sistema** (R9, `docs/controles-de-camera.md`
 * §4.2), em px da janela, puro para o teste.
 *
 * As duas telas são de ponta a ponta (targetSdk 36): a janela passa por baixo da barra de status, da
 * barra de navegação e do recorte da tela. A primeira versão do painel usava retângulos da janela inteira,
 * e no A10s deitado (a barra de navegação à direita, 139 px) o "Pronto", no canto de cima à direita, ficou
 * quase todo debaixo da barra: o `dumpsys activity top` da sessão principal (01/10) mostrou o painel em
 * 0,0-1520,360 e o "Pronto" em 1369..1478, numa área útil que acaba em 1381. A vista do roteiro da R5 também
 * vai de ponta a ponta (0,0-1520,360), então copiar o retângulo dela não bastava.
 *
 * Aqui o painel fica sempre **dentro da área útil** — a janela menos os recuos das barras e do recorte
 * (`WindowInsetsCompat.Type.systemBars() or displayCutout()`) —, seja qual for o lado da barra (em pé,
 * embaixo; deitado, à direita na rotação 90 e à esquerda na 270).
 */
object RetanguloDoPainel {

    /** Um retângulo em px da janela, com a origem em cima à esquerda. */
    data class Ret(val esquerda: Int, val topo: Int, val direita: Int, val baixo: Int) {
        val largura: Int get() = (direita - esquerda).coerceAtLeast(0)
        val altura: Int get() = (baixo - topo).coerceAtLeast(0)
    }

    /** Os recuos das barras do sistema e do recorte, em px. */
    data class Recuos(val esquerda: Int = 0, val topo: Int = 0, val direita: Int = 0, val baixo: Int = 0)

    /** A área útil de uma janela de [largura] × [altura] com os [recuos]. */
    fun areaUtil(largura: Int, altura: Int, recuos: Recuos): Ret =
        Ret(recuos.esquerda, recuos.topo, (largura - recuos.direita).coerceAtLeast(recuos.esquerda),
            (altura - recuos.baixo).coerceAtLeast(recuos.topo))

    /** Na R5: o retângulo da vista do texto **cortado pela área útil**. */
    fun daR5(texto: Ret, larguraDaJanela: Int, alturaDaJanela: Int, recuos: Recuos): Ret {
        val u = areaUtil(larguraDaJanela, alturaDaJanela, recuos)
        val e = maxOf(texto.esquerda, u.esquerda)
        val t = maxOf(texto.topo, u.topo)
        return Ret(e, t, maxOf(e, minOf(texto.direita, u.direita)), maxOf(t, minOf(texto.baixo, u.baixo)))
    }

    /**
     * Na câmera comum: a metade de baixo da área útil, em pé; a metade direita, deitado. E a prévia na
     * outra metade, até a borda da janela do lado oposto ao painel (ela pode passar por baixo das barras:
     * é imagem, e não controle).
     */
    fun daCameraComum(larguraDaJanela: Int, alturaDaJanela: Int, recuos: Recuos, deitado: Boolean): Pair<Ret, Ret> {
        val u = areaUtil(larguraDaJanela, alturaDaJanela, recuos)
        return if (deitado) {
            val meio = (u.esquerda + u.direita) / 2
            Ret(meio, u.topo, u.direita, u.baixo) to Ret(0, 0, meio, alturaDaJanela)
        } else {
            val meio = (u.topo + u.baixo) / 2
            Ret(u.esquerda, meio, u.direita, u.baixo) to Ret(0, 0, larguraDaJanela, meio)
        }
    }
}
