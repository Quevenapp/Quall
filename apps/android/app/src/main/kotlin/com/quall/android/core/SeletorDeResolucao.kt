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
        /** As resoluções que a câmera escolhida não oferece: o botão fica apagado. */
        val resolucoesFora: Set<Resolucao> = emptySet(),
        /** As taxas que a câmera escolhida não alcança na resolução escolhida: o botão fica apagado. */
        val taxasFora: Set<Int> = emptySet(),
        /** O fps que vai de fato na resolução escolhida, quando a escolha salva passa do teto da câmera. */
        val fpsEfetivo: Int? = null,
    )

    /**
     * [fonteEhFilmadoraDv]: a fonte é o vídeo USB; [daPlaca]: e é (ou parece ser) a placa de captura.
     *
     * [tetos]: com uma câmera do aparelho escolhida, o fps máximo de cada resolução (`null` = a câmera
     * não oferece o tamanho; resolução ausente = não se sabe, fica disponível). **O que a câmera não faz
     * fica apagado** (pedido de produto, 06/10): o A07 não faz 60 fps em faixa nenhuma, e escolher 60 dava
     * 720p a 30 fixos, com a imagem escura. A escolha salva não muda; [Estado.fpsEfetivo] diz o que vai.
     */
    fun estado(
        fonteEhFilmadoraDv: Boolean,
        daPlaca: Boolean = false,
        tetos: Map<Resolucao, Int?> = emptyMap(),
        escolhida: Resolucao = Resolucao.P1080,
        fps: Int = 30,
    ): Estado = when {
        !fonteEhFilmadoraDv -> {
            val fora = tetos.filterValues { it == null }.keys
            val teto = tetos[escolhida]
            // A menor taxa nunca se apaga: numa câmera que faz 4K só a 24, o "30" continua e vai a 24.
            val menor = Resolucao.TAXAS.minOrNull()
            val taxasFora = if (teto != null) Resolucao.TAXAS.filter { it > teto && it != menor }.toSet() else emptySet()
            val efetivo = if (teto != null && fps > teto) teto else null
            Estado(ativo = true, nota = null, resolucoesFora = fora, taxasFora = taxasFora, fpsEfetivo = efetivo)
        }
        daPlaca -> Estado(ativo = false, nota = R.string.in_nota_da_placa)
        else -> Estado(ativo = false, nota = R.string.in_nota_da_fita)
    }
}
