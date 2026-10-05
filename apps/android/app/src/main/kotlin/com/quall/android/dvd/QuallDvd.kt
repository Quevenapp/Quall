package com.quall.android.dvd

import com.quall.android.R
import com.quall.android.capture.dv.QuallDv
import java.nio.ByteBuffer

/**
 * A ponte com o pipeline do DVD em C (`cpp/dv/dvd.c`, na `libqualldv.so`; `docs/dvd-para-mp4.md`,
 * a D1b): o fluxo MPEG-PS do título entra em blocos ([empurrar]), e sai o quadro progressivo
 * escalado ([escrever]) e o PCM estéreo de 48 kHz de cada faixa ([som]).
 *
 * **Só arm64, e só depois de [disponivel]**: a `.so` é a da DV (o mesmo FFmpeg), carregada sob
 * demanda por [QuallDv].
 *
 * Duas threads: a do leitor ([celula], [empurrar], [fimDaEntrada]) e a da conversão ([preparar],
 * [passo], [quadro], [escrever], [som]). [abortar] vale de qualquer uma, e [fechar] só depois de as
 * duas saírem.
 */
object QuallDvd {
    val disponivel: Boolean get() = QuallDv.disponivel

    // dvd_passo
    const val NADA = 0
    const val QUADRO = 1
    const val FIM = 2

    // Os erros de `dvd.h`.
    const val ERRO_CIFRADO = -1001
    const val ERRO_CANCELADO = -1002
    const val ERRO_POSICAO = -1003
    const val ERRO_DEMUX = -1004
    const val ERRO_VIDEO = -1005
    const val ERRO_MEMORIA = -1006
    const val ERRO_LEITOR = -1007
    const val ERRO_CELULAS = -1008

    /**
     * [faixas]: os substreams de som na ordem do IFO (0x80+n AC-3, 0xA0+n LPCM, 0x1C0+n MPEG); `null`
     * é o modo automático da bancada (as que aparecerem antes do primeiro quadro). 0 sem memória.
     */
    @JvmStatic external fun abrir(faixas: IntArray?): Long

    /** A célula começa no byte [pos] do fluxo, com [acumulado90k] de tempo antes dela. 0 ou erro. */
    @JvmStatic external fun celula(h: Long, pos: Long, acumulado90k: Long): Int

    /** [n] bytes (setores inteiros) do ByteBuffer direto [buf], no byte [pos]. Bloqueia com a fila cheia. */
    @JvmStatic external fun empurrar(h: Long, buf: ByteBuffer, n: Int, pos: Long): Int

    @JvmStatic external fun fimDaEntrada(h: Long)

    @JvmStatic external fun abortar(h: Long, erro: Int)

    /** Até o primeiro quadro de vídeo. 0 ou erro. */
    @JvmStatic external fun preparar(h: Long): Int

    /** Ver [Info.de]. */
    @JvmStatic external fun info(h: Long): IntArray

    /** [QUADRO], [NADA], [FIM] ou um erro. */
    @JvmStatic external fun passo(h: Long): Int

    /** 1 com quadro: `tempos[0]` o pts, `tempos[1]` a duração nominal (90 kHz). */
    @JvmStatic external fun quadro(h: Long, tempos: LongArray): Int

    @JvmStatic external fun escrever(
        h: Long, y: ByteBuffer, yStride: Int, u: ByteBuffer, v: ByteBuffer, uvStride: Int,
        uvPixelStride: Int, largura: Int, altura: Int,
    ): Int

    /** Até [max] amostras estéreo s16 da [faixa] em [saida] (direto, 4 bytes por amostra). */
    @JvmStatic external fun som(h: Long, faixa: Int, saida: ByteBuffer, max: Int): Int

    /** Ver `dvd_contadores` em `dvd.c`. */
    @JvmStatic external fun contadores(h: Long): LongArray

    /** As faixas cujo disco tem som num canal só, copiado para os dois lados (bit k = a faixa k). */
    @JvmStatic external fun canalCopiado(h: Long): Int

    /** A frase para a tela quando o disco tem som num canal só. */
    val UM_CANAL_SO: Frase get() = Frase(R.string.dvd_um_canal_so)

    @JvmStatic external fun fechar(h: Long)

    /** O diário por célula e o resumo das correções no logcat (`dvd_diario`). */
    @JvmStatic external fun diario(h: Long)

    /**
     * O MP4 do DVD (`midia.c`, `mp4_abre_faixas`): o da câmera (vídeo em 1/90000 com a duração de
     * cada quadro, pelo [QuallDv.mp4VideoComDuracao]; fechado por [QuallDv.mp4Fechar]) com uma faixa
     * AAC 48 kHz estéreo por ASC em [ascs], cada uma com o idioma em [idiomas] (ISO 639-2). A primeira
     * é a padrão. 0 se não abriu.
     */
    @JvmStatic external fun mp4AbrirFaixas(
        fd: Int, largura: Int, altura: Int, spsPps: ByteArray, ascs: Array<ByteArray>, idiomas: Array<String>,
        bitrate: Int, padrao: Int, faixa: Int, transferencia: Int,
    ): Long

    /** Um pacote AAC da [faixa]: [pts] e [duracao] em amostras de 48 kHz. */
    @JvmStatic external fun mp4SomDaFaixa(m: Long, faixa: Int, dados: ByteBuffer, off: Int, n: Int, pts: Long, duracao: Int): Int

    /** O que [preparar] descobriu (`dvd_info`). */
    data class Info(
        val largura: Int,
        val altura: Int,
        val fpsNum: Int,
        val fpsDen: Int,
        val aspecto169: Boolean,
        val entrelacado: Boolean,
        val faixas: List<Int>,
        val vistas: List<Boolean>,
    ) {
        val pal: Boolean get() = fpsNum == 25 && fpsDen == 1

        companion object {
            fun de(v: IntArray): Info {
                val n = v[6].coerceIn(0, 8)
                return Info(
                    v[0], v[1], v[2], v[3], v[4] != 0, v[5] != 0,
                    (0 until n).map { v[7 + it] }, (0 until n).map { v[15 + it] != 0 },
                )
            }
        }
    }

    /** A frase de cada erro, para a tela e o diário (as de proteção são as do §2.1). */
    fun motivo(erro: Int): Frase = when (erro) {
        ERRO_CIFRADO -> FrasesDoDvd.PROTEGIDO
        ERRO_CANCELADO -> Frase(R.string.dvd_conversao_cancelada)
        ERRO_POSICAO -> Frase(R.string.dvd_erro_posicao)
        ERRO_DEMUX -> Frase(R.string.dvd_erro_demux)
        ERRO_VIDEO -> Frase(R.string.dvd_erro_video)
        ERRO_MEMORIA -> Frase(R.string.dvd_erro_memoria)
        ERRO_LEITOR -> Frase(R.string.dvd_erro_leitor)
        ERRO_CELULAS -> Frase(R.string.dvd_erro_celulas)
        else -> Frase(R.string.dvd_erro_codigo, erro)
    }
}

/**
 * As frases de recusa do desenho (`docs/dvd-para-mp4.md` §2.1 e §2.3), num lugar só, sem idioma: o texto
 * mora em `res/values-pt/strings_dvd.xml` (o português, o texto-fonte) e `res/values/strings_dvd.xml`.
 */
object FrasesDoDvd {
    val PROTEGIDO get() = Frase(R.string.dvd_recusa_protegido)
    val ANGULOS get() = Frase(R.string.dvd_recusa_angulos)
    val SO_DTS get() = Frase(R.string.dvd_recusa_so_dts)
    val NAO_FINALIZADO get() = Frase(R.string.dvd_recusa_nao_finalizado)
    val NAO_E_DVD_DE_VIDEO get() = Frase(R.string.dvd_recusa_sem_video_ts)
    val SEM_VIDEO_TS_IFO get() = Frase(R.string.dvd_recusa_sem_video_ts_ifo)
    val SEM_CELULAS get() = Frase(R.string.dvd_recusa_sem_celulas)
    // O leitor que se desconecta sozinho ao acelerar o disco é o caso medido (A07, 29/09): 5 min parado,
    // o Converter, e 1,4 s depois o USB caiu e voltou com outro endereço — o pico do motor.
    val LEITOR_PAROU get() = Frase(R.string.dvd_leitor_parou)
    val LEITOR_PRESO get() = Frase(R.string.dvd_leitor_preso)
    val DISCO_TROCADO get() = Frase(R.string.dvd_disco_trocado)
    val FORA_DO_DISCO get() = Frase(R.string.dvd_recusa_fora_do_disco)
    val CELULAS_DEMAIS get() = Frase(R.string.dvd_recusa_celulas_demais)
    val SEM_LEITOR get() = Frase(R.string.dvd_sem_leitor)
}

/**
 * **Compatibilidade, para sair** (a tradução de 02/10, `docs/traducao.md`): as mesmas frases em português,
 * como `String`, para quem ainda não lê a [Frase] — o `MirrorService` (`Recusas.LEITOR_PAROU`,
 * `LEITOR_PRESO`, `RecusaDoDisco.frase`) e a vitrine de depuração (`SEM_LEITOR`, `PROTEGIDO`, `ANGULOS`).
 * Quando eles passarem a [FrasesDoDvd], este objeto some. A tela do DVD não usa nada daqui.
 */
object Recusas {
    const val PROTEGIDO = "Este DVD tem proteção contra cópia. O Quall só converte discos sem proteção, como os gravados em casa." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val ANGULOS = "Este título tem vários ângulos; o Quall ainda não converte." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val SO_DTS = "O som deste título é DTS, que o Quall ainda não converte." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val NAO_FINALIZADO = "Este disco não foi finalizado. Finalize-o no aparelho que gravou e tente de novo." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val LEITOR_PAROU = "O leitor de DVD parou de responder. Se ele desligou sozinho ao acelerar o disco, é falta de energia: confira o carregador no hub (ou a fonte do leitor) e toque em Ler o disco de novo." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val LEITOR_PRESO = "O leitor de DVD ficou preso numa leitura. Desligue-o e ligue de novo (e toque em Ler o disco de novo)." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val DISCO_TROCADO = "O disco foi trocado no leitor. Volte à tela do DVD e leia o disco de novo." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val FORA_DO_DISCO = "Este título aponta para fora do disco (o IFO está danificado); o Quall não converte." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val CELULAS_DEMAIS = "Este título tem células demais; o Quall ainda não converte." // i18n-fora: compatibilidade (ver FrasesDoDvd)
    const val SEM_LEITOR = "Ligue o leitor de DVD. Ele precisa do carregador ligado no hub: sem ele, o telefone não consegue alimentar o leitor." // i18n-fora: compatibilidade (ver FrasesDoDvd)

    private val EM_PORTUGUES: Map<Frase, String> by lazy {
        mapOf(
            FrasesDoDvd.PROTEGIDO to PROTEGIDO, FrasesDoDvd.ANGULOS to ANGULOS, FrasesDoDvd.SO_DTS to SO_DTS,
            FrasesDoDvd.NAO_FINALIZADO to NAO_FINALIZADO, FrasesDoDvd.LEITOR_PAROU to LEITOR_PAROU,
            FrasesDoDvd.LEITOR_PRESO to LEITOR_PRESO, FrasesDoDvd.DISCO_TROCADO to DISCO_TROCADO,
            FrasesDoDvd.FORA_DO_DISCO to FORA_DO_DISCO, FrasesDoDvd.CELULAS_DEMAIS to CELULAS_DEMAIS,
            FrasesDoDvd.SEM_LEITOR to SEM_LEITOR,
        )
    }

    /** A [Frase] em português, sem `Context` (só para a compatibilidade e o diário). */
    fun emPortugues(f: Frase): String =
        EM_PORTUGUES[f] ?: (f.args.singleOrNull() as? String)?.takeIf { f.id == R.string.dvd_cru } ?: f.toString()
}
