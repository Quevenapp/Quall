package com.quall.android.core

import android.content.Context
import android.util.Size

/**
 * A resolução que o usuário escolheu emitir — o cardápio de `docs/fluxo-de-uso.md`.
 *
 * Pedido do usuário em 07/09/2026: *"o Quall tem que permitir o usuário escolher a resolução
 * câmera / tela 720p 1080p 2k 4k"*, com a diretiva que veio junto: *"vamos ao extremo máximo…
 * o usuário que decide, o que importa é o Quall oferecer o recurso"*.
 *
 * # Por que o valor é `maxFs` e não um par de dimensões
 *
 * Porque a escolha e o teto da norma são **a mesma grandeza**, e o núcleo já sabe combiná-las:
 * `quall_teto_ajustar_para` recebe os macroblocos aceitos e aplica **o menor** entre a escolha e o
 * nível anunciado no SDP. Guardar um par de dimensões obrigaria cada casca a decidir o que fazer
 * quando o aparelho é retrato — e é aí que este projeto já perdeu tempo, com cinco cascas
 * escrevendo o mesmo número à mão.
 *
 * Em macroblocos, a proporção do aparelho sobrevive: um telefone em pé que escolhe 1080p recebe
 * **1080x1920**, e não 1920x1080 deitado.
 *
 * # Isto NÃO é chave de bancada
 *
 * `Bancada.kt` é ajuste de bancada e o arquivo inteiro se declara assim. Esta preferência é de
 * **produto**: aparece na tela inicial, é escolhida com o dedo, e sobrevive a fechar o app. Por
 * isso mora aqui e não lá.
 */
enum class Resolucao(val maxFs: Int, val rotulo: String, val pedido: Size) {
    /** 1280x720 — 3.600 macroblocos. */
    P720(3_600, "720p", Size(1280, 720)),

    /**
     * 1920x1080 — 8.160 macroblocos. **O padrão**, e o comportamento de antes do cardápio.
     *
     * Não é o meio da lista por acaso: é exatamente o teto que valia até 07/09/2026, e mantê-lo
     * como padrão é o que faz abrir o cardápio não mexer em quem não abrir o menu.
     */
    P1080(8_160, "1080p", Size(1920, 1080)),

    /** 2560x1440 — 14.400 macroblocos. */
    P1440(14_400, "2K", Size(2560, 1440)),

    /**
     * 3840x2160 — 32.400 macroblocos.
     *
     * Custa **36 Mbps** e leva o quadro-chave de 103 para ~411 pacotes, contra um joelho de
     * truncamento de ~50 (`docs/idr-que-sobrevive.md`). No rádio isso é sério; no fio a §8.13
     * mediu 75,5 Mbps agregados com 0,023 % e 321 IDR, nenhum quebrado. É por isso que a escolha
     * de resolução e a de transporte são a mesma conversa.
     */
    P2160(32_400, "4K", Size(3840, 2160));

    companion object {
        private const val CHAVE = "resolucao_max_fs"
        private const val PREFS = "quall_produto"

        val PADRAO = P1080

        private fun prefs(c: Context) =
            c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun escolhida(c: Context): Resolucao {
            val fs = prefs(c).getInt(CHAVE, PADRAO.maxFs)
            return entries.firstOrNull { it.maxFs == fs } ?: PADRAO
        }

        fun escolher(c: Context, r: Resolucao) {
            prefs(c).edit().putInt(CHAVE, r.maxFs).apply()
        }

        private const val CHAVE_FPS = "quadros_por_segundo"

        /**
         * A taxa de quadros escolhida. **30 é o padrão**, e é o que valia antes do cardápio.
         *
         * O eixo é separado do da resolução na interface porque a pessoa pensa nos dois
         * separadamente — mas os dois viajam juntos até o núcleo, no mesmo `Alvo`, porque lá são
         * a mesma decisão e separá-los faria cada casca combiná-los na mão.
         */
        fun quadros(c: Context): Int = prefs(c).getInt(CHAVE_FPS, 30)

        /**
         * Grava a taxa escolhida.
         *
         * **O filtro é [TAXAS], e não um literal.** Até 08/09/2026 esta linha era
         * `if (fps == 60) 60 else 30`: qualquer valor que não fosse exatamente 60 virava 30
         * **em silêncio, na preferência persistida**. O efeito só apareceria no dia em que o
         * cardápio crescesse — acrescentar `120` a [TAXAS] é uma mudança de três dígitos, e o
         * seletor mostraria 120 enquanto o aparelho gravava 30, sem log e sem erro. É a mesma
         * família de defeito que custou uma célula publicada em 07/09: um valor que devia ser um
         * só, escrito em dois lugares, com só um deles atualizado.
         *
         * Agora a lista é a única fonte. Um valor fora dela cai no padrão **e diz que caiu**.
         */
        fun escolherQuadros(c: Context, fps: Int) {
            val valido = fps in TAXAS
            if (!valido) {
                com.quall.android.core.LogSeguro.w("Resolucao", "taxa $fps não está no cardápio $TAXAS — gravando 30") // i18n-fora: diário técnico de taxa inválida; não é texto da interface
            }
            prefs(c).edit().putInt(CHAVE_FPS, if (valido) fps else 30).apply()
        }

        /**
         * As taxas oferecidas.
         *
         * **Acrescentar um valor aqui não basta para o produto oferecê-lo.** Antes de 120 entrar,
         * três coisas têm de estar de pé, e estão registradas em `docs/bancada.md` §8.54:
         *  1. o caminho de captura precisa **alcançar** a taxa — no S24 o caminho normal para em
         *     60 (`aeAvailableTargetFpsRanges` = `[60,60]`), e 120 só existe pela
         *     `CameraConstrainedHighSpeedCaptureSession`, que é outra API;
         *  2. o orçamento de bits precisa sair da taxa **negociada**, não da pedida — hoje
         *     `MirrorService` recalcula a geometria negociada e ainda passa `fpsEscolhido`;
         *  3. o caminho de câmera precisa passar pelo portão de nível, que hoje só a tela
         *     atravessa: 4K a 120 são 3.888.000 macroblocos/s contra os 2.073.600 do nível 5.2.
         */
        val TAXAS = listOf(30, 60)

        /**
         * O que o núcleo entrega para esta escolha e esta entrada, ou `null` se a fronteira
         * recusar.
         *
         * `null` **não** é "use o que você tem": é erro. Cair para a entrada em silêncio é o
         * defeito que o teto de tela do Android tinha até 07/09/2026, quando o S24 emitiu
         * 1440x3120 — 2,14x acima do nível que o próprio SDP anuncia.
         */
        fun ajustar(entrada: Size, fps: Int, r: Resolucao): Pair<Int, Int>? =
            QuallNative.tetoDeResolucaoPar(entrada.width, entrada.height, fps, r.maxFs)
    }
}
