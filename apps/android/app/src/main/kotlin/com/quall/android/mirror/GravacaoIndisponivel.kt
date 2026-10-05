package com.quall.android.mirror

import com.quall.android.aceleradoPorHardware
import com.quall.android.R
import com.quall.android.capture.EtapaDaAbertura
import com.quall.android.core.Idioma
import com.quall.android.core.Textos

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import com.quall.android.core.LogSeguro as Log

/**
 * **O aparelho que não grava, dito antes do toque** (`docs/teleprompter-com-camera.md` §14.3, caso 1,
 * e §14.10–§14.12). Desde a D1 o 32 bits grava pelo `MediaMuxer`; a mensagem fica só para o que nem
 * ele cobre:
 *
 * 1. a bandeira de bancada `sem_gravador` (a prova 7 da D1);
 * 2. **a gravação que falhou ao abrir** neste aparelho, nesta versão do app e neste sistema — **duas
 *    vezes**, em aberturas diferentes, e nunca por erro de recurso ou passageiro (a revisão, 12);
 * 3. o codificador H.264 que a gravação escolheria declarando menos de 2 instâncias ao mesmo tempo
 *    (`getMaxSupportedInstances`: a rede e a gravação pedem 2) — **só** se este aparelho ainda não
 *    gravou nesta versão (há fabricante que declara 1 e aguenta).
 *
 * Um toque longo no botão apagado ("tentar mesmo assim") apaga a marca do item 2 ([esquecer]).
 *
 * **Guardado é código, não frase** (`docs/traducao.md`, Android): a marca do item 2 guarda a etapa
 * que falhou ([EtapaDaAbertura.codigo]); a frase sai de [motivo] no idioma do momento.
 */
object GravacaoIndisponivel {
    private const val TAG = "QuallGravacao"
    private const val ARQUIVO = "quall-gravador"
    private const val CHAVE_FALHAS = "falhas_ao_abrir"
    /** A etapa da última falha ao abrir ([EtapaDaAbertura.codigo]); a frase técnica fica no diário. */
    private const val CHAVE_MOTIVO = "motivo"
    private const val CHAVE_ASSINATURA = "assinatura"
    private const val CHAVE_GRAVOU = "gravou_nesta_assinatura"
    private const val CHAVE_PROCESSO = "processo_da_ultima_falha"

    /** A primeira linha da mensagem (§14.3), na língua de [t]. */
    fun texto(t: Textos): String = t.s(R.string.cam_nao_grava)

    /** A segunda, honesta com o que existe: nenhum receptor grava antes do R8-1 (§14.3, §14.6). */
    fun texto2(t: Textos): String = t.s(R.string.cam_nao_grava_2)

    /** As duas juntas, para o indicador e o toque. */
    fun mensagem(t: Textos): String = texto(t) + "\n" + texto2(t)

    /**
     * **Legado, em português**, para quem ainda não passa [Textos] (`MainActivity`,
     * `PrompterComCameraActivity`): use [texto] e [mensagem].
     */
    const val TEXTO = "Este aparelho não grava vídeo; ele só transmite." // i18n-fora: legado, ver texto(t)
    const val TEXTO_2 = "Para gravar, use o OBS no computador que recebe."
    const val MENSAGEM = "$TEXTO\n$TEXTO_2"

    /** Quantas falhas ao abrir, em aberturas diferentes, fazem o aparelho "não gravar". */
    const val FALHAS_PARA_MARCAR = 2

    // --- a decisão, pura (a JVM testa) --------------------------------------------------------

    /**
     * O motivo na língua de [t], ou `null` se grava. [falhas]/[etapaGuardada] valem só com a [assinatura]
     * certa (quem chama já confere); [etapaGuardada] é o [EtapaDaAbertura.codigo] (outro texto não diz a
     * etapa); [instancias] `null` quando o aparelho não diz.
     */
    fun decidir(
        t: Textos,
        semGravadorDaBancada: Boolean,
        falhas: Int,
        etapaGuardada: String?,
        instancias: Int?,
        nomeDoCodificador: String?,
        jaGravou: Boolean,
    ): String? = when {
        semGravadorDaBancada -> "bancada: sem_gravador"
        falhas >= FALHAS_PARA_MARCAR -> EtapaDaAbertura.deCodigo(etapaGuardada)?.takeIf { it != EtapaDaAbertura.OUTRA }
            ?.let { t.s(R.string.cam_indisponivel_falhas_na_etapa, falhas, t.s(it.frase)) }
            ?: t.s(R.string.cam_indisponivel_falhas, falhas)
        instancias != null && instancias < 2 && !jaGravou ->
            t.s(R.string.cam_indisponivel_instancias, nomeDoCodificador ?: "", instancias)
        else -> null
    }

    // --- o aparelho -----------------------------------------------------------------------------

    /** O codificador que a gravação escolheria e quantas instâncias ele declara; lido uma vez. */
    private val codificador: Pair<String, Int>? by lazy {
        runCatching {
            val tipo = MediaFormat.MIMETYPE_VIDEO_AVC
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(tipo, ignoreCase = true) } }
                .sortedBy { if (it.aceleradoPorHardware) 0 else 1 }
                .firstOrNull()
                ?.let { info: MediaCodecInfo -> info.name to info.getCapabilitiesForType(tipo).maxSupportedInstances }
        }.getOrNull()
    }

    /** Aquece a consulta ao `MediaCodecList` fora da principal (o serviço chama na thread dele). */
    fun aquecer() {
        codificador
    }

    /** A versão do app e o sistema: uma marca de outra assinatura não vale (§14.3: uma atualização apaga). */
    private fun assinatura(c: Context): String {
        val p = runCatching { c.packageManager.getPackageInfo(c.packageName, 0) }.getOrNull()
        return "${p?.longVersionCode ?: 0}/${p?.lastUpdateTime ?: 0}/${Build.FINGERPRINT}"
    }

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(ARQUIVO, Context.MODE_PRIVATE)

    /** A marca, se for desta assinatura; a de outra é apagada aqui. */
    private fun lerMarca(c: Context): Triple<Int, String?, Boolean> {
        val p = prefs(c)
        if (p.getString(CHAVE_ASSINATURA, null) != assinatura(c)) {
            p.edit().clear().putString(CHAVE_ASSINATURA, assinatura(c)).apply()
            return Triple(0, null, false)
        }
        return Triple(p.getInt(CHAVE_FALHAS, 0), p.getString(CHAVE_MOTIVO, null), p.getBoolean(CHAVE_GRAVOU, false))
    }

    /**
     * O motivo de não gravar neste aparelho, no idioma do app agora, ou `null`. Barato depois da
     * primeira consulta.
     */
    fun motivo(c: Context): String? {
        val (falhas, motivo, gravou) = lerMarca(c)
        // As instâncias só no aparelho do `MediaMuxer` (a revisão do código, 5): no arm64 o Gravar já
        // funciona, e um número do fabricante não pode apagá-lo.
        val cod = if (com.quall.android.capture.dv.QuallDv.disponivel) null else codificador
        return decidir(
            Idioma.textos(Idioma.contexto(c)),
            com.quall.android.core.Bancada.semGravador(c), falhas, motivo, cod?.second, cod?.first, gravou,
        )
    }

    /** Este processo: duas falhas no mesmo processo contam uma (a revisão do código, 4). */
    private val esteProcesso: String by lazy {
        "${android.os.Process.myPid()}/${android.os.Process.getStartElapsedRealtime()}"
    }

    /**
     * Uma gravação falhou **ao abrir** (§14.3) na [etapa]. A transitória não conta. Guarda a etapa (o
     * [motivo] técnico vai só para o diário). Devolve o motivo novo de não gravar, se esta falha o criou.
     */
    fun falhouAoAbrir(c: Context, motivo: String, etapa: EtapaDaAbertura, transitoria: Boolean): String? {
        if (transitoria) {
            Log.w(TAG, "APP GRAVACAO falha ao abrir, passageira (não lembrada): ${Log.erroExterno(motivo)}")
            return null
        }
        lerMarca(c)
        val p = prefs(c)
        if (p.getString(CHAVE_PROCESSO, null) == esteProcesso) {
            Log.w(TAG, "APP GRAVACAO falha ao abrir de novo neste processo (conta uma vez só): ${Log.erroExterno(motivo)}")
            p.edit().putString(CHAVE_MOTIVO, etapa.codigo).apply()
            return motivo(c)
        }
        val n = p.getInt(CHAVE_FALHAS, 0) + 1
        p.edit().putInt(CHAVE_FALHAS, n).putString(CHAVE_MOTIVO, etapa.codigo).putString(CHAVE_PROCESSO, esteProcesso).apply()
        Log.w(TAG, "APP GRAVACAO falha ao abrir ($n de $FALHAS_PARA_MARCAR para marcar o aparelho): ${Log.erroExterno(motivo)}")
        return motivo(c)
    }

    /** O arquivo de fato começou: o aparelho grava nesta versão, e as falhas de antes não contam. */
    fun gravou(c: Context) {
        lerMarca(c)
        prefs(c).edit().putBoolean(CHAVE_GRAVOU, true).putInt(CHAVE_FALHAS, 0).remove(CHAVE_MOTIVO).apply()
    }

    /** "Tentar mesmo assim": esquece as falhas guardadas (a bandeira de bancada continua valendo). */
    fun esquecer(c: Context) {
        lerMarca(c)
        prefs(c).edit().putInt(CHAVE_FALHAS, 0).remove(CHAVE_MOTIVO).putBoolean(CHAVE_GRAVOU, true).apply()
        Log.i(TAG, "APP GRAVACAO a marca de falha foi esquecida (tentar mesmo assim)")
    }
}
