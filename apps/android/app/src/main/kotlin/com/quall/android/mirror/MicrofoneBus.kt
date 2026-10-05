package com.quall.android.mirror

import android.os.Handler
import android.os.Looper
import androidx.annotation.StringRes
import com.quall.android.R
import com.quall.android.core.Textos

/**
 * **O botão do microfone da câmera**, do serviço para as telas (R5, fase 2;
 * `docs/teleprompter-com-camera.md` §4.2). Separado do [MirrorBus] porque aquele é republicado
 * inteiro a cada volta da espera e a cada segundo da sessão, e o estado do botão não é da sessão: ele
 * atravessa as sessões de um mesmo espelhamento de câmera (o receptor cai e volta, o botão fica).
 *
 * Quem escreve é o [MirrorService] (e a tela, só para dizer por que a permissão não veio); quem lê
 * são a tela R5 e a tela inicial.
 */
object MicrofoneBus {

    private val principal by lazy { Handler(Looper.getMainLooper()) }

    @Volatile
    var atual = EstadoDoMicrofone()
        private set

    /**
     * **Um ouvinte por dono**, e não um só (a revisão, menor): com um só, o `onStop` de uma tela
     * que sai depois de a outra entrar apagava o ouvinte da que entrou.
     */
    private val ouvintes = java.util.concurrent.ConcurrentHashMap<Any, (EstadoDoMicrofone) -> Unit>()

    /** Registra (ou, com `null`, tira) o ouvinte de [dono]. */
    fun ouvir(dono: Any, l: ((EstadoDoMicrofone) -> Unit)?) {
        if (l == null) {
            ouvintes.remove(dono)
            return
        }
        ouvintes[dono] = l
        val e = atual
        principal.post { l(e) }
    }

    @Synchronized
    fun atualizar(bloco: (EstadoDoMicrofone) -> EstadoDoMicrofone) {
        val e = bloco(atual)
        atual = e
        for (l in ouvintes.values) principal.post { l(e) }
    }
}

/**
 * **Por que o botão não ligou, tipado** (`docs/traducao.md`, Android): a tela decide pelo código, e não
 * procurando "permissão" ou "Ajustes" na frase — que em inglês não tem essas palavras. A frase sai de
 * [frase] no idioma de quem desenha.
 */
enum class MotivoDoMicrofone(
    @StringRes val frase: Int,
    /** A permissão de microfone faltou (o botão fica âmbar com "Sem acesso"). */
    val permissao: Boolean,
    /** Só os Ajustes do aparelho resolvem: a tela oferece abri-los. */
    val pedeAjustes: Boolean,
) {
    /** Sem vídeo de câmera no ar não há o que ligar. */
    SEM_VIDEO_NO_AR(R.string.cam_mic_motivo_sem_video, permissao = false, pedeAjustes = false),
    /** Negada, e o Android ainda deixa pedir de novo. */
    PERMISSAO_NEGADA(R.string.cam_mic_motivo_negada, permissao = true, pedeAjustes = false),
    /** Negada sem pedido possível ("não perguntar de novo", ou o diálogo fechado): nos Ajustes. */
    PERMISSAO_NOS_AJUSTES(R.string.cam_mic_motivo_nos_ajustes, permissao = true, pedeAjustes = true),
    /** O serviço viu que não há `RECORD_AUDIO`. */
    SEM_PERMISSAO(R.string.cam_mic_motivo_sem_permissao, permissao = true, pedeAjustes = false),
}

/**
 * O estado do botão. Pura, para a frase ser testada na JVM.
 */
data class EstadoDoMicrofone(
    /** Há um espelhamento de câmera em curso: a track `MICROPHONE` vai na oferta, e o botão existe. */
    val disponivel: Boolean = false,
    /** O botão: o que a pessoa pediu. **Começa desligado** a cada espelhamento de câmera. */
    val ligado: Boolean = false,
    /** Há captura aberta agora, mandando pela track (o microfone, ou o tom da bancada). */
    val capturando: Boolean = false,
    /** Por que desligou sozinho, ou por que não ligou. Vazio sem nada a dizer. */
    val motivo: String = "",
    /**
     * O mesmo [motivo], tipado, quando quem escreveu o sabia ([comMotivo]). Vale só enquanto [motivo]
     * for o texto escrito junto ([motivoDoCodigo]): quem escreve só a frase depois (`it.copy(motivo = …)`)
     * não herda um código velho. Leia por [motivoTipado].
     */
    val codigoDoMotivo: MotivoDoMicrofone? = null,
    val motivoDoCodigo: String = "",
    /** A origem que está mandando, para o diário e a tela ("microfone (MIC, cru)" ou o tom). */
    val origem: String = "",
    /** Um aviso com o microfone aberto (o silêncio digital de outro app com ele). */
    val aviso: String = "",
    /** A tela R5: o microfone abre também para a gravação local, sem receptor (fase 3). */
    val abreAoGravar: Boolean = false,
    /**
     * A fonte é a placa de captura: o botão é o **"Som da placa"** (a entrada de áudio dela, e não o
     * microfone do telefone; `docs/placa-de-captura-usb.md` §11, item 3), e começa ligado.
     */
    val daPlaca: Boolean = false,
    /**
     * A fonte é a filmadora DV: o botão é o **"Som da fita"** (o som que vem dentro do DV, sem
     * microfone nenhum; `docs/placa-de-captura-usb.md` §13.8), e começa ligado.
     */
    val daFita: Boolean = false,
    /** O som desta sessão não abre microfone nenhum (a fita; a placa pelo usbfs): o botão não pede a permissão. */
    val semMicrofone: Boolean = false,
) {
    /** O motivo tipado, se o [motivo] de agora veio com ele (ver [codigoDoMotivo]). */
    val motivoTipado: MotivoDoMicrofone? get() = codigoDoMotivo?.takeIf { motivo.isNotBlank() && motivo == motivoDoCodigo }

    /**
     * Não ligou por falta da permissão de microfone. Pelo código; a frase só decide quando quem
     * escreveu não deu código (o `MirrorService` de hoje escreve "sem permissão de microfone").
     */
    val semPermissao: Boolean get() = motivo.isNotBlank() &&
        (motivoTipado?.permissao ?: motivo.contains("permissão")) // i18n-fora: legado, até o MirrorService escrever o código

    /** Só os Ajustes do aparelho resolvem (a tela oferece abri-los). */
    val pedeAjustes: Boolean get() = motivoTipado?.pedeAjustes == true

    /** O motivo na língua de [t]: a frase do código, ou o texto como veio. */
    fun motivo(t: Textos): String = motivoTipado?.let { t.s(it.frase) } ?: motivo

    /** Escreve o motivo com o código e a frase (na língua de [t]) juntos. */
    fun comMotivo(t: Textos, codigo: MotivoDoMicrofone): EstadoDoMicrofone {
        val texto = t.s(codigo.frase)
        return copy(motivo = texto, codigoDoMotivo = codigo, motivoDoCodigo = texto)
    }

    /** "Som da placa", "Som da fita" ou "Microfone", o nome do botão e das frases, na língua de [t]. */
    fun nome(t: Textos): String = t.s(
        if (daPlaca) R.string.cam_som_da_placa else if (daFita) R.string.cam_som_da_fita else R.string.cam_microfone,
    )

    /**
     * A frase da tela, na língua de [t]. **O microfone abre com alguém para ouvir**: um receptor, ou (na
     * tela R5) a gravação local. "Ligado" sem nenhum dos dois diz isso, em vez de deixar a pessoa achar
     * que o microfone está aberto.
     */
    fun frase(t: Textos): String {
        val n = nome(t)
        return when {
            !disponivel -> ""
            ligado && capturando -> t.s(R.string.cam_mic_ligado, n) +
                // A origem só quando não é o microfone: o tom da bancada (o nome dele é de diário).
                (if (!daPlaca && !daFita && origem.isNotBlank() && !origem.startsWith("microfone")) " ($origem)" else "") +
                (if (aviso.isNotBlank()) ": $aviso" else "")
            ligado -> t.s(if (abreAoGravar) R.string.cam_mic_ligado_espera_ou_gravar else R.string.cam_mic_ligado_espera, n)
            motivo.isNotBlank() -> t.s(R.string.cam_mic_desligado_porque, n, motivo(t))
            else -> t.s(R.string.cam_mic_desligado, n)
        }
    }

    /**
     * **Legado, em português**: o nome de antes, para quem ainda não passa [Textos] (a `MainActivity`).
     * Use [nome] com os textos.
     */
    val nome: String get() = if (daPlaca) "Som da placa" else if (daFita) "Som da fita" else "Microfone"

    /** **Legado, em português** (a `VideoUsbActivity`): use [frase] com os textos. */
    fun frase(): String = when {
        !disponivel -> ""
        ligado && capturando -> "$nome ligado" +
            (if (!daPlaca && !daFita && origem.isNotBlank() && !origem.startsWith("microfone")) " ($origem)" else "") +
            (if (aviso.isNotBlank()) ": $aviso" else "")
        ligado -> "$nome ligado · abre quando o receptor conectar" + if (abreAoGravar) " ou ao gravar" else ""
        motivo.isNotBlank() -> "$nome desligado: $motivo"
        else -> "$nome desligado"
    }
}
