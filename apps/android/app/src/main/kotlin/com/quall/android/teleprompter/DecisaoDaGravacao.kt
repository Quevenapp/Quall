package com.quall.android.teleprompter

import com.quall.android.R
import com.quall.android.core.Textos
import com.quall.android.mirror.GravacaoDaTelaBus.Fase
import java.util.Locale

/**
 * **O que a tela R5 faz com o pedido de gravação do controle** (`docs/contrato-teleprompter.md`
 * §13.2 e §13.8; `docs/teleprompter-com-camera.md` §5.5). Pura. Quem decide é o prompter; o núcleo
 * só carrega o pedido e a resposta.
 *
 * - **[Acao.RESPONDER]**: o arquivo já está como se pede — `definir_gravando(gravar)` responde (e
 *   aceita, mesmo que já esteja assim; o núcleo não recarimba);
 * - **[Acao.COMECAR]** / **[Acao.PARAR]**: pede ao serviço; a resposta sai quando o arquivo de fato
 *   começar ou fechar (o `definir_gravando` da passagem de fase), ou a recusa com o motivo;
 * - **[Acao.ESPERAR]**: o arquivo está abrindo ou fechando. A tela decide de novo na próxima fase:
 *   um "parar" que chega enquanto abre para quando o arquivo começar; um "gravar" que chega enquanto
 *   fecha começa outro quando ele fechar.
 */
object DecisaoDaGravacao {
    enum class Acao { RESPONDER, COMECAR, PARAR, ESPERAR }

    fun decidir(gravar: Boolean, fase: Fase): Acao = when (fase) {
        Fase.GRAVANDO -> if (gravar) Acao.RESPONDER else Acao.PARAR
        Fase.PARADA -> if (gravar) Acao.COMECAR else Acao.RESPONDER
        Fase.COMECANDO, Fase.PARANDO -> Acao.ESPERAR
    }

    /** O teto do motivo no contrato (§13.3, `TETO_DO_MOTIVO`), em bytes de UTF-8. */
    const val TETO_DO_MOTIVO = 256

    /**
     * O motivo como o núcleo aceita (a revisão, médio 5): de 1 a 256 bytes de UTF-8, sem NUL, cortado
     * numa fronteira de caractere com reticências; vazio vira um texto de reserva (no idioma deste
     * aparelho: o controle mostra o motivo como chegou). Sem isso a recusa voltava `INVALID` e o
     * controle ficava sem resposta.
     */
    fun motivo(texto: String, t: Textos): String {
        val limpo = texto.replace('\u0000', ' ').trim().ifEmpty { t.s(R.string.r5_recusa_reserva) }
        if (limpo.toByteArray(Charsets.UTF_8).size <= TETO_DO_MOTIVO) return limpo
        val sb = StringBuilder()
        var bytes = 0
        val reticencias = "…".toByteArray(Charsets.UTF_8).size
        var i = 0
        while (i < limpo.length) {
            val cp = limpo.codePointAt(i)
            val n = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8).size
            if (bytes + n + reticencias > TETO_DO_MOTIVO) break
            sb.appendCodePoint(cp)
            bytes += n
            i += Character.charCount(cp)
        }
        return sb.append('…').toString()
    }

    /** O indicador da tela: o tempo gravando, em `m:ss` (ou `h:mm:ss`). */
    fun tempo(ms: Long): String {
        val s = (ms.coerceAtLeast(0) / 1000)
        val h = s / 3600
        val m = (s % 3600) / 60
        val ss = s % 60
        return if (h > 0) String.format(java.util.Locale.ROOT, "%d:%02d:%02d", h, m, ss)
        else String.format(java.util.Locale.ROOT, "%d:%02d", m, ss)
    }

    /**
     * O espaço que sobra, curto: "12,3 GB" ou "850 MB" — a vírgula ou o ponto do idioma de [locale]
     * (`Textos.locale` da tela; o padrão é o do processo, que o AppCompat acerta com a escolha).
     */
    fun espaco(bytes: Long, locale: Locale = Locale.getDefault()): String =
        if (bytes >= 1_000_000_000L) String.format(locale, "%.1f GB", bytes / 1e9)
        else "${bytes / 1_000_000} MB"

    /**
     * **O indicador de "gravando"** — o mesmo na tela R5 e no espelhamento de câmera comum (§5.5 e
     * §8.6). Vazio sem gravação. **Gravar não liga o microfone** (decisão do Pessoa Exemplo, 24/09): quem liga
     * é a pessoa, antes. Com ele desligado a gravação segue, com silêncio no lugar do som, e o
     * indicador diz isso em maiúsculas e diz o que fazer — ligar no meio passa a gravar o som dali em
     * diante. Com o botão ligado e o microfone ainda abrindo, diz que o som ainda não entrou.
     */
    fun indicador(
        fase: Fase,
        decorridoMs: Long,
        espacoLivre: Long,
        microfoneLigado: Boolean,
        microfoneCapturando: Boolean,
        t: Textos,
    ): String = when (fase) {
        Fase.PARADA -> ""
        Fase.COMECANDO -> t.s(R.string.r5_indicador_abrindo)
        Fase.PARANDO -> t.s(R.string.r5_indicador_fechando)
        Fase.GRAVANDO -> buildString {
            append(t.s(R.string.r5_indicador_gravando, tempo(decorridoMs)))
            when {
                !microfoneLigado -> append(" ").append(t.s(R.string.r5_indicador_sem_som))
                !microfoneCapturando -> append(" · ").append(t.s(R.string.r5_indicador_sem_som_ainda))
            }
            if (espacoLivre > 0) append(" · ").append(t.s(R.string.r5_indicador_sobram, espaco(espacoLivre, t.locale)))
        }
    }

    /**
     * **O rótulo do botão Gravar**: parado, avisa antes do toque que vai gravar sem som se o
     * microfone está desligado; gravando, é o de parar.
     */
    fun rotuloDoBotao(fase: Fase, microfoneLigado: Boolean, t: Textos): String = when (fase) {
        Fase.PARADA -> t.s(if (microfoneLigado) R.string.r5_gravar else R.string.r5_gravar_sem_som)
        Fase.COMECANDO -> t.s(R.string.r5_abrindo)
        Fase.GRAVANDO -> t.s(R.string.r5_parar_gravacao)
        Fase.PARANDO -> t.s(R.string.r5_fechando)
    }
}
