package com.quall.android.core

import com.quall.android.R

/**
 * **O que foi pedido, o que está sendo entregue, e por quê** — o passo 1 de
 * `docs/quem-limita-a-imagem.md`.
 *
 * # O caso que fez isto existir
 *
 * Em 10/09/2026 o usuário escolheu 4K a 60 no cardápio, espelhou a câmera frontal do S24, e o
 * vídeo saiu em 1920x1080 a 60. Não houve erro: o CameraX escolhe o maior tamanho que atende a
 * taxa pedida, e aquela câmera não faz 4K a 60. Mas **nada disse isso na tela**, e a leitura
 * natural de quem vê é *"o sistema errou e baixou a qualidade"*. É o silêncio que
 * `docs/fluxo-de-uso.md` chama de pior modo de falha deste projeto.
 *
 * # O motivo é medido, não adivinhado
 *
 * Cada frase de [motivo] sai de um fato que o aparelho declarou, e só dele:
 *
 * - **a câmera não oferece o tamanho** — ele não está na lista de saídas do Camera2;
 * - **a câmera oferece o tamanho a menos fps** — `getOutputMinFrameDuration` daquele tamanho;
 * - **a câmera negociou menos fps** — o `SurfaceRequest.getExpectedFrameRate` da sessão. (Não o
 *   `KEY_FRAME_RATE` do formato do codificador: ele só ecoa o que foi configurado — a revisão
 *   adversarial de 10/09/2026 derrubou a primeira versão desta peça por isso.)
 * - **a tela do aparelho é menor que o pedido** — no espelhamento de tela o teto é o painel.
 *
 * Quando nenhum desses explica a diferença, a frase **diz que o motivo não foi identificado**, em vez
 * de escolher um. Um motivo inventado é pior que motivo nenhum: manda a pessoa mexer no lugar errado.
 *
 * Aritmética pura, sem `Context` e sem câmera: [EntregaTest] a exercita na JVM. As frases vêm de
 * [Textos] (`docs/traducao.md`): no idioma da tela, e nos testes em português e em inglês.
 */
data class Entrega(
    /** O que a pessoa escolheu no cardápio: `"4K a 60 fps"`. */
    val pedido: String,
    /** O que está no ar: `"1920x1080 a 60 fps"`. Vazio enquanto não se sabe. */
    val entregue: String,
    /** Por que as duas diferem. `null` quando a entrega é a pedida. */
    val motivo: String?,
    /** O [entregue] curto, para a linha do alto da espera: `"1920×1080 · 60 fps"`. */
    val curto: String = "",
) {
    /** A câmera, com o que o Camera2 declarou sobre o tamanho pedido. */
    data class Camera(
        /** O tamanho pedido está entre as saídas do Camera2? */
        val ofereceOTamanhoPedido: Boolean,
        /** Quantos quadros por segundo a câmera faz no tamanho pedido. `null` se não se sabe. */
        val quadrosNoTamanhoPedido: Int?,
    )

    companion object {

        /** Macroblocos de 16x16 de uma geometria — a mesma conta de `Resolucao.maxFs`. */
        fun macroblocos(largura: Int, altura: Int): Int =
            ((largura + 15) / 16) * ((altura + 15) / 16)

        /**
         * `a` é menor que `b` além do arredondamento? **90 %.** O teto de resolução preserva a
         * proporção da fonte, e 1080p pedido num S24 em pé vira 976x2116 — 8113 macroblocos contra
         * 8160. Comparar exato diria "menor que o pedido" de uma entrega que é o pedido.
         */
        private fun menorQue(a: Int, b: Int): Boolean = a.toLong() * 10 < b.toLong() * 9

        /** A taxa como se lê: `60`, ou `29,97` (`29.97` em inglês). */
        fun quadros(t: Textos, q: Double): String =
            if (q == Math.rint(q)) q.toLong().toString() else String.format(t.locale, "%.2f", q)

        /** O par longo e curto de "o que está no ar" ([ate]: a tela, que entrega **até** a taxa). */
        private fun noAr(t: Textos, w: Int, h: Int, q: String, ate: Boolean = false): Pair<String, String> =
            if (ate) t.s(R.string.esp_ent_no_ar_ate, w, h, q) to t.s(R.string.esp_ent_curto_ate, w, h, q)
            else t.s(R.string.esp_ent_no_ar, w, h, q) to t.s(R.string.esp_ent_curto, w, h, q)

        /**
         * Uma entrega que não se negocia (a placa, a filmadora, o DVD, a tela R5): o [pedido] já dito
         * pela fonte, o tamanho dela e a taxa dela.
         */
        fun fixa(t: Textos, pedido: String, largura: Int, altura: Int, quadros: Double, motivo: String? = null): Entrega {
            val (longo, curto) = noAr(t, largura, altura, quadros(t, quadros))
            return Entrega(pedido, longo, motivo, curto)
        }

        /**
         * A entrega de uma sessão de **câmera**.
         *
         * [negociada] é o tamanho que o CameraX entregou ao codificador; [fpsNegociado] é o teto da
         * faixa de fps que a sessão de captura negociou (`null` quando o CameraX não informa).
         */
        fun daCamera(
            t: Textos,
            escolha: Resolucao,
            fpsPedido: Int,
            negociada: Pair<Int, Int>?,
            fpsNegociado: Int?,
            camera: Camera,
        ): Entrega {
            val pedido = t.s(R.string.esp_ent_pedido, escolha.rotulo, fpsPedido)
            if (negociada == null) return Entrega(pedido, "", null)
            val (w, h) = negociada
            val fpsNoAr = fpsNegociado ?: fpsPedido
            val (entregue, curto) = noAr(t, w, h, fpsNoAr.toString())

            val motivos = mutableListOf<String>()
            if (menorQue(macroblocos(w, h), escolha.maxFs)) {
                motivos += when {
                    !camera.ofereceOTamanhoPedido ->
                        t.s(R.string.esp_ent_nao_oferece, escolha.rotulo)
                    camera.quadrosNoTamanhoPedido != null &&
                        camera.quadrosNoTamanhoPedido < fpsPedido ->
                        t.s(R.string.esp_ent_so_ate, escolha.rotulo, camera.quadrosNoTamanhoPedido)
                    else ->
                        t.s(R.string.esp_ent_menor_sem_motivo)
                }
            }
            if (fpsNegociado != null && fpsNegociado < fpsPedido) {
                // Sem culpado nomeado: a faixa é da sessão inteira e sai da interseção com a prévia
                // (`CameraXSource.pedirQuadros`), então "a câmera não faz" pode não ser verdade.
                motivos += t.s(R.string.esp_ent_ficou_em, fpsNegociado)
            }
            return Entrega(pedido, entregue, motivos.joinToString("; ").ifEmpty { null }, curto)
        }

        /**
         * A entrega de uma sessão de **tela**. [painel] é o tamanho do display; [entregue] é o
         * que o teto de resolução deixou chegar ao codificador.
         *
         * **Sem motivo de fps**, de propósito: na tela a taxa não é negociada, e uma tela parada
         * entregar menos quadros que o pedido é o comportamento certo (`docs/contrato-sidecar.md`).
         */
        fun daTela(
            t: Textos,
            escolha: Resolucao,
            fpsPedido: Int,
            painel: Pair<Int, Int>,
            entregue: Pair<Int, Int>,
        ): Entrega {
            val pedido = t.s(R.string.esp_ent_pedido, escolha.rotulo, fpsPedido)
            val (noAr, curto) = noAr(t, entregue.first, entregue.second, fpsPedido.toString(), ate = true)
            val motivos = mutableListOf<String>()
            val painelMb = macroblocos(painel.first, painel.second)
            val entregueMb = macroblocos(entregue.first, entregue.second)
            // O que dava para entregar é o menor entre o pedido e o painel. Abaixo **disso** alguma
            // coisa além dos dois cortou; abaixo só do pedido, quem cortou foi a tela do aparelho.
            val possivel = minOf(escolha.maxFs, painelMb)
            if (menorQue(entregueMb, possivel)) {
                motivos += t.s(R.string.esp_ent_tela_menor_sem_motivo)
            } else if (menorQue(painelMb, escolha.maxFs)) {
                motivos += t.s(R.string.esp_ent_tela_tem, painel.first, painel.second)
            }
            return Entrega(pedido, noAr, motivos.joinToString("; ").ifEmpty { null }, curto)
        }
    }
}
