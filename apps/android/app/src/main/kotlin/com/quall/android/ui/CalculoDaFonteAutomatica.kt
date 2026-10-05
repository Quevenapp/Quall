package com.quall.android.ui

import android.os.SystemClock
import android.text.StaticLayout
import android.util.DisplayMetrics
import android.util.TypedValue
import com.quall.android.teleprompter.FonteAutomatica
import com.quall.android.teleprompter.LinhasDiagramadas

/**
 * A conta da **"Fonte automática"** ([FonteAutomatica]) com o motor de quebra de linha da vista
 * ([VistaDoRoteiro.diagramar]) — a fonte escolhida quebra na tela exatamente como quebrou aqui. Roda
 * **fora da thread principal** (quem chama põe numa thread própria): um roteiro de 100 KB são algumas
 * dezenas de ms por diagrama, e a busca binária entre 8 e 400 faz nove.
 *
 * **O texto inteiro, sem amostra**: a regra é por parágrafo e uma amostra deixaria de fora justo o
 * parágrafo com a palavra curta que sobra — o custo medido está no README da rodada 11.
 */
internal class CalculoDaFonteAutomatica(private val metricas: DisplayMetrics) {

    class Resultado(
        val sp: Int,
        val ms: Long,
        val diagramas: Int,
        val linhas: Int,
        val porTipo: Map<FonteAutomatica.Linha, Int>,
        /** Na fonte seguinte (`sp + 1`), as primeiras linhas que quebram a regra: [início, fim). */
        val quebrasNaSeguinte: List<IntRange>,
        /** A tabela de linhas da fonte escolhida e da seguinte, para a bancada conferir a regra. */
        val tabela: () -> String,
    )

    private class Linhas(val l: StaticLayout) : LinhasDiagramadas {
        override val quantas get() = l.lineCount
        override fun inicio(linha: Int) = l.getLineStart(linha)
        override fun fim(linha: Int) = l.getLineEnd(linha)
    }

    fun calcular(texto: String, larguraDaColuna: Int): Resultado {
        val comecou = SystemClock.elapsedRealtime()
        val feitos = HashMap<Int, StaticLayout>()
        fun diagrama(sp: Int) = feitos.getOrPut(sp) {
            VistaDoRoteiro.diagramar(texto, TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp.toFloat(), metricas), larguraDaColuna)
        }
        val sp = FonteAutomatica.maiorFonte { FonteAutomatica.respeita(texto, Linhas(diagrama(it))) }
        val escolhido = Linhas(diagrama(sp))
        val (porTipo, _) = FonteAutomatica.contar(texto, escolhido)
        val quebras = if (sp < FonteAutomatica.MAXIMA) {
            val seguinte = Linhas(diagrama(sp + 1))
            FonteAutomatica.contar(texto, seguinte).second.map { seguinte.inicio(it) until seguinte.fim(it) }
        } else emptyList()
        val ms = SystemClock.elapsedRealtime() - comecou
        val diagramas = feitos.size
        return Resultado(sp, ms, diagramas, escolhido.quantas, porTipo, quebras) {
            buildString {
                append("fonte\tlinha\tinicio\tfim\tpalavras\ttipo\n")
                for (f in listOf(sp, sp + 1)) {
                    val l = feitos[f]?.let { Linhas(it) } ?: continue
                    for (i in 0 until l.quantas) {
                        append(f).append('\t').append(i).append('\t').append(l.inicio(i)).append('\t').append(l.fim(i)).append('\t')
                        append(FonteAutomatica.contarPalavras(texto, l.inicio(i), l.fim(i))).append('\t')
                        append(FonteAutomatica.classificar(texto, l, i).name).append('\n')
                    }
                }
            }
        }
    }
}
