package com.quall.android.core

import androidx.annotation.StringRes
import com.quall.android.R

/**
 * O estado do cardápio de resolução e fps na tela, pela fonte escolhida. Puro: testado em JVM.
 *
 * **O vídeo USB não escolhe tamanho** (pedido do Pessoa Exemplo, 22/09/2026, para a filmadora DV; a placa de
 * captura segue a mesma regra, `docs/placa-de-captura-usb.md` §3.7). Na filmadora o arquivo é sempre
 * 1280×720 a 29,97 e o espelhamento vai no tamanho da fita (854×480 em 16:9, 640×480 em 4:3); na
 * placa, a rede e a gravação vão no quadro dela (640×480 a 30 na EasyCap). O cardápio fica
 * desativado, com a frase que diz isso, e **a escolha salva não muda**: ao voltar para uma câmera do
 * celular ou para a tela, o cardápio volta ativo com a escolha de antes.
 */
object SeletorDeResolucao {
    data class Estado(
        /** Os botões de resolução e de fps podem ser tocados? */
        val ativo: Boolean,
        /** A frase no lugar da nota de custo (um recurso, no idioma da tela); `null` quando vale a nota de custo de sempre. */
        @StringRes val nota: Int?,
    )

    /** [fonteEhFilmadoraDv]: a fonte é o vídeo USB; [daPlaca]: e é (ou parece ser) a placa de captura. */
    fun estado(fonteEhFilmadoraDv: Boolean, daPlaca: Boolean = false): Estado = when {
        !fonteEhFilmadoraDv -> Estado(ativo = true, nota = null)
        daPlaca -> Estado(ativo = false, nota = R.string.in_nota_da_placa)
        else -> Estado(ativo = false, nota = R.string.in_nota_da_fita)
    }
}
