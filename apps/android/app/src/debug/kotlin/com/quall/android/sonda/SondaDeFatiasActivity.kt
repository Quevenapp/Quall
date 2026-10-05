package com.quall.android.sonda

import com.quall.android.aceleradoPorHardware

import android.app.Activity
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * **O `MediaCodec` do Android aceita uma unidade de acesso com fatias faltando?**
 *
 * A pergunta decide um eixo inteiro do projeto, e o Android é o único receptor da matriz cujo
 * decodificador ninguém tinha perguntado. `docs/idr-que-sobrevive.md` mediu que a fila do enlace de
 * 2,4 GHz **trunca a cauda** de uma rajada acima de ~35 pacotes e entrega a cabeça inteira (34 dos
 * 37 quadros grandes quebrados têm a forma `N+M−`); `docs/idr-pequeno.md` mediu que o
 * `VTDecompressionSession` da Apple **recusa** a unidade truncada com `-12909`, e que o libavcodec
 * a decodifica nos mesmos quatro cortes. Se o `MediaCodec` recusar como a Apple, fatiar não tem
 * para que servir nesta matriz e o eixo morre.
 *
 * Esta sonda é a réplica exata do experimento de `apps/macos/Sources/sonda-fatias/main.swift`, §2,
 * neste aparelho:
 *
 *  1. lê um Annex-B de **origem sintética nossa** (mosaico de semente fixa, gerado por
 *     `tools/origem-fatiada.py` — nenhum pixel de tela de ninguém entra aqui);
 *  2. acha o IDR e **confere no artefato** quantas fatias ele tem, lendo `first_mb_in_slice`;
 *  3. trunca nas K primeiras **fatias completas** e alimenta um `MediaCodec` recém-aberto;
 *  4. diz se saiu imagem, com que erro, e — nas bandas de linhas que a fatia faltante cobria —
 *     **o que foi pintado ali**.
 *
 * ## Por que esta sonda lê pixel, quando o resto do projeto não lê
 *
 * `docs/regras-de-frente.md` manda medir por contador e nunca por pixel, porque as origens da
 * bancada são telas de máquinas do usuário. A exceção que o briefing desta frente abre é
 * explícita e estreita: **origem sintética nossa pode ser olhada**, e a pergunta "a imagem parcial
 * sai suja, verde, ou congelada?" não tem resposta por contador de buffer. Ainda assim, o que
 * atravessa a fronteira do processo é **estatística de banda** — média, desvio, moda e fração
 * igual à referência —, nunca um quadro: nenhum `Bitmap`, nenhum PNG, nenhum arquivo de imagem é
 * criado por este arquivo.
 *
 * ## Por que ela mora no conjunto de fontes `debug`
 *
 * A Activity é `exported` (um `am start` numa Activity não exportada é recusado com
 * `SecurityException`, e isso já custou uma rodada a este projeto — ver `tools/aparelho.py`).
 * Uma Activity exportada é superfície de ataque, e esta não serve ao produto para nada. No
 * conjunto `debug` ela entra no APK que `tools/portao.sh` compila e some do `release` sem nenhum
 * `if`.
 *
 * ```
 * adb -s <serial> shell am start -n com.quall.android/com.quall.android.sonda.SondaDeFatiasActivity \
 *     --es arquivo /sdcard/Android/data/com.quall.android/files/fatiado.h264 \
 *     --es saida   /sdcard/Android/data/com.quall.android/files/fatias-sonda.json
 * ```
 */
class SondaDeFatiasActivity : Activity() {

    private companion object {
        const val TAG = "QuallSondaFatias"
        const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC

        /** Teto de espera por saída de um único corte, em microssegundos de `dequeueOutputBuffer`. */
        const val ESPERA_TOTAL_US = 2_000_000L
        const val ESPERA_PASSO_US = 20_000L

        /** Passo de amostragem do plano Y. 4x4 = 1/16 dos pixels, e o desvio não muda na 3ª casa. */
        const val PASSO = 4
    }

    /** Componente a abrir por nome; vazio deixa o sistema escolher, como o produto faz. */
    private var codecPedido: String = ""

    /**
     * Configurar com `Surface`, como o `H264Decoder` do produto faz, em vez de modo `ByteBuffer`.
     *
     * Existe porque as duas configurações **não são o mesmo caminho** dentro do componente: em
     * modo `Surface` o quadro vai para uma `BufferQueue` do SurfaceFlinger e nunca passa por
     * memória do Java, e um decodificador pode aceitar num modo e recusar no outro. Medir só o
     * modo que o produto **não** usa seria responder à pergunta errada com precisão.
     *
     * O preço é que aqui não há pixel para ler: neste braço a medida é contador — saiu buffer?
     * quantos? com que erro? — e a cor do buraco continua vindo do braço de `ByteBuffer`.
     */
    private var comSurface: Boolean = false
    private var textura: SurfaceTexture? = null
    private var superficie: Surface? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val arquivo = intent.getStringExtra("arquivo")
            ?: "${getExternalFilesDir(null)}/fatiado.h264"
        val saida = intent.getStringExtra("saida")
            ?: "${getExternalFilesDir(null)}/fatias-sonda.json"
        val cortesPedidos = intent.getStringExtra("cortes").orEmpty()
        val comMeiaFatia = intent.getBooleanExtra("meia_fatia", true)
        val comSeguintes = intent.getIntExtra("quadros_seguintes", 0)
        codecPedido = intent.getStringExtra("codec").orEmpty()
        comSurface = intent.getBooleanExtra("surface", false)
        val repeticoes = intent.getIntExtra("repeticoes", 0)

        Thread {
            val relatorio = runCatching {
                if (repeticoes > 0) {
                    vazao(File(arquivo), repeticoes)
                } else {
                    correr(File(arquivo), cortesPedidos, comMeiaFatia, comSeguintes)
                }
            }.getOrElse { e ->
                Log.e(TAG, "a sonda caiu", e)
                JSONObject().put("erro_fatal", "${e.javaClass.simpleName}: ${e.message}")
            }
            File(saida).writeText(relatorio.toString(2))
            Log.i(TAG, "PRONTO $saida")
            runOnUiThread { finish() }
        }.start()
    }

    // --------------------------------------------------------------------------------------
    // A corrida
    // --------------------------------------------------------------------------------------

    private fun correr(
        arquivo: File,
        cortesPedidos: String,
        comMeiaFatia: Boolean,
        quadrosSeguintes: Int,
    ): JSONObject {
        val bytes = arquivo.readBytes()
        val relatorio = JSONObject()
            .put("arquivo", arquivo.path)
            .put("bytes_do_arquivo", bytes.size)
            .put("aparelho", "${android.os.Build.MODEL} · Android ${android.os.Build.VERSION.RELEASE} / API ${android.os.Build.VERSION.SDK_INT}")

        val unidades = AnnexBDaSonda.unidadesDeAcesso(bytes)
        val indiceDoIdr = unidades.indexOfFirst { faixa ->
            AnnexBDaSonda.nals(bytes, faixa.last + 1).any {
                it.inicioComPrefixo >= faixa.first && it.tipo == AnnexBDaSonda.NAL_IDR
            }
        }
        if (indiceDoIdr < 0) return relatorio.put("erro_fatal", "não achei IDR no fluxo")

        val idr = bytes.copyOfRange(unidades[indiceDoIdr].first, unidades[indiceDoIdr].last + 1)
        val nalsDoIdr = AnnexBDaSonda.nals(idr)
        val fatias = nalsDoIdr.filter { it.tipo in AnnexBDaSonda.VCL }
        val n = fatias.size

        // As bandas de linhas que cada fatia cobre, tiradas do `first_mb_in_slice` de cada uma —
        // não presumidas iguais. É o que permite dizer *onde* a imagem parcial acaba.
        val primeirosMb = fatias.map { AnnexBDaSonda.primeiroMacroblocoDaFatia(idr, it.cabecalho) ?: -1 }

        relatorio.put("unidades_de_acesso", unidades.size)
            .put("idr_bytes", idr.size)
            .put("idr_fatias", n)
            .put("idr_first_mb", JSONArray(primeirosMb))
            .put("idr_maior_fatia_bytes", fatias.maxOfOrNull { it.bytes } ?: 0)

        val cortes = if (cortesPedidos.isBlank()) {
            listOf(1, max(1, n / 2), max(1, n - 1), n).distinct().sorted()
        } else {
            cortesPedidos.split(',').mapNotNull { it.trim().toIntOrNull() }
                .filter { it in 1..n }.distinct().sorted()
        }
        Log.i(TAG, "IDR com $n fatias, ${idr.size} B; cortes = $cortes")

        // A referência é o corte completo, e ela roda PRIMEIRO de propósito: sem uma imagem que
        // saia, "não saiu imagem" seria defeito do arnês em vez de resposta do decodificador. É a
        // mesma aferição que a linha 8/8 faz na tabela do `sonda-fatias`.
        val referencia = decodificar(idr, "referencia", null)
        relatorio.put("referencia", referencia.json)
        // Em Surface não há plano para ler; a aferição passa a ser "saiu buffer de quadro?", que
        // é o mesmo critério que o braço mede nos cortes. Trocar o critério **e** a pergunta ao
        // mesmo tempo seria comparar duas coisas diferentes.
        val aferiu = if (comSurface) referencia.json.optInt("saidas") > 0 else referencia.plano != null
        if (!aferiu) {
            relatorio.put("aferição", "FALHOU — a unidade COMPLETA não decodificou; nada abaixo vale")
            return relatorio
        }
        relatorio.put("aferição", "ok — a unidade completa decodifica; os cortes abaixo são resposta do decodificador")

        val braços = JSONArray()
        for (k in cortes) {
            val truncado = truncar(idr, k)
            val seguintes = if (quadrosSeguintes > 0) {
                (indiceDoIdr + 1..min(unidades.size - 1, indiceDoIdr + quadrosSeguintes))
                    .map { bytes.copyOfRange(unidades[it].first, unidades[it].last + 1) }
            } else {
                emptyList()
            }
            val r = decodificar(truncado, "corte $k/$n", referencia.plano, seguintes, idr)
            braços.put(
                r.json
                    .put("corte", k)
                    .put("de", n)
                    .put("bytes", truncado.size)
                    .put("linhas_cobertas_pelas_fatias_entregues", linhaDaFatia(primeirosMb, k, referencia.altura, referencia.largura)),
            )
        }

        if (comMeiaFatia && n >= 2) {
            // O corte que o depacotizador de hoje produziria se apenas parasse de descartar: a
            // cabeça chega, mas a última fatia vem pela metade. O briefing avisa que entregar meia
            // fatia troca uma recusa por outra — esta linha mede se é verdade **neste** codec.
            val k = max(1, n / 2)
            val meio = truncarNoMeioDaFatia(idr, k)
            val r = decodificar(meio, "corte $k/$n + meia fatia", referencia.plano, emptyList(), idr)
            braços.put(r.json.put("corte", -1).put("de", n).put("bytes", meio.size)
                .put("rotulo", "$k fatias completas + metade da fatia ${k + 1}"))
        }

        return relatorio.put("braços", braços).put("codecs", enumerarDecodificadores())
    }

    /**
     * Recorta a unidade nas `k` primeiras fatias completas, mantendo todos os NALs não-VCL que
     * vierem antes. É a forma `N+M−` que `docs/idr-que-sobrevive.md` mediu no ar.
     */
    private fun truncar(au: ByteArray, k: Int): ByteArray {
        val saida = java.io.ByteArrayOutputStream()
        var vistas = 0
        for (nal in AnnexBDaSonda.nals(au)) {
            if (nal.tipo in AnnexBDaSonda.VCL) {
                if (vistas >= k) break
                vistas++
            }
            saida.write(au, nal.inicioComPrefixo, nal.fim - nal.inicioComPrefixo)
        }
        return saida.toByteArray()
    }

    /** `k` fatias completas mais **metade** da fatia seguinte, cortada em byte arbitrário. */
    private fun truncarNoMeioDaFatia(au: ByteArray, k: Int): ByteArray {
        val lista = AnnexBDaSonda.nals(au)
        val saida = java.io.ByteArrayOutputStream()
        var vistas = 0
        for (nal in lista) {
            if (nal.tipo in AnnexBDaSonda.VCL) {
                if (vistas == k) {
                    val metade = (nal.fim - nal.inicioComPrefixo) / 2
                    saida.write(au, nal.inicioComPrefixo, max(8, metade))
                    break
                }
                vistas++
            }
            saida.write(au, nal.inicioComPrefixo, nal.fim - nal.inicioComPrefixo)
        }
        return saida.toByteArray()
    }

    /** Primeira linha de pixel **não coberta** pelas `k` primeiras fatias. */
    private fun linhaDaFatia(primeirosMb: List<Int>, k: Int, altura: Int, largura: Int): Int {
        if (k >= primeirosMb.size) return altura
        val mbPorLinha = (largura + 15) / 16
        if (mbPorLinha <= 0) return altura
        return min(altura, primeirosMb[k] / mbPorLinha * 16)
    }

    /**
     * **Quanto custa decodificar em software?**
     *
     * A recomendação de produto que sai de `docs/pintar-a-cabeca.md` para o `SM-X230` é trocar o
     * componente do fornecedor pelo `c2.android.avc.decoder` do AOSP, que nunca branqueia o
     * quadro. Uma recomendação sem o preço ao lado é meia recomendação: um decodificador de
     * software a 720x1520 pode simplesmente não dar conta de 30 fps num aparelho de entrada.
     *
     * Este braço alimenta **todas** as unidades de acesso do arquivo, `repeticoes` vezes, num
     * codec só, e mede o relógio de parede do primeiro `queueInputBuffer` ao último buffer de
     * saída. Não é perfil de CPU — é vazão, que é a grandeza que decide se cabe no orçamento de
     * 33,3 ms por quadro.
     */
    private fun vazao(arquivo: File, repeticoes: Int): JSONObject {
        val bytes = arquivo.readBytes()
        val unidades = AnnexBDaSonda.unidadesDeAcesso(bytes)
            .map { bytes.copyOfRange(it.first, it.last + 1) }
        val j = JSONObject()
            .put("arquivo", arquivo.path)
            .put("aparelho", "${android.os.Build.MODEL} · Android ${android.os.Build.VERSION.RELEASE} / API ${android.os.Build.VERSION.SDK_INT}")
            .put("unidades_de_acesso", unidades.size)
            .put("repeticoes", repeticoes)
        if (unidades.isEmpty()) return j.put("erro_fatal", "nenhuma unidade de acesso no arquivo")

        val idr = unidades.first { au -> AnnexBDaSonda.nals(au).any { it.tipo == AnnexBDaSonda.NAL_IDR } }
        val csd = parametros(idr) ?: return j.put("erro_fatal", "sem SPS/PPS")
        val dim = dimensoesDoSps(idr) ?: return j.put("erro_fatal", "SPS ilegível")

        var codec: MediaCodec? = null
        try {
            val formato = MediaFormat.createVideoFormat(MIME, dim.first, dim.second).apply {
                setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd))
                if (!comSurface) {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
                    )
                }
            }
            val c = if (codecPedido.isNotBlank()) {
                MediaCodec.createByCodecName(codecPedido)
            } else {
                MediaCodec.createDecoderByType(MIME)
            }
            codec = c
            c.configure(formato, if (comSurface) superficieDeProva(dim) else null, null, 0)
            c.start()
            j.put("codec", runCatching { c.name }.getOrDefault("?"))
                .put("largura", dim.first).put("altura", dim.second)

            val info = MediaCodec.BufferInfo()
            var saidas = 0
            var entradas = 0
            fun drenar(esperaUs: Long) {
                while (true) {
                    val idx = c.dequeueOutputBuffer(info, esperaUs)
                    if (idx < 0) return
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0) saidas++
                    c.releaseOutputBuffer(idx, comSurface)
                }
            }

            val inicio = android.os.SystemClock.elapsedRealtimeNanos()
            for (r in 0 until repeticoes) {
                for (au in unidades) {
                    var idx = -1
                    while (idx < 0) {
                        idx = c.dequeueInputBuffer(10_000)
                        if (idx < 0) drenar(0)
                    }
                    val buf = c.getInputBuffer(idx)!!
                    buf.clear()
                    buf.put(au)
                    val ehIdr = AnnexBDaSonda.nals(au).any { it.tipo == AnnexBDaSonda.NAL_IDR }
                    c.queueInputBuffer(
                        idx, 0, au.size, entradas * 33_333L,
                        if (ehIdr) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                    )
                    entradas++
                    drenar(0)
                }
            }
            val idx = c.dequeueInputBuffer(500_000)
            if (idx >= 0) {
                c.queueInputBuffer(idx, 0, 0, entradas * 33_333L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
            drenar(2_000_000)
            val decorrido = (android.os.SystemClock.elapsedRealtimeNanos() - inicio) / 1_000_000.0

            return j.put("quadros_entrados", entradas)
                .put("quadros_saidos", saidas)
                .put("ms_total", (decorrido * 10).toInt() / 10.0)
                .put("ms_por_quadro", (decorrido / saidas.coerceAtLeast(1) * 100).toInt() / 100.0)
                .put("fps", (saidas / (decorrido / 1000.0) * 10).toInt() / 10.0)
                .put("orcamento_30fps_ms", 33.3)
        } catch (e: Exception) {
            return j.put("erro", "${e.javaClass.simpleName}: ${e.message}")
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
        }
    }

    // --------------------------------------------------------------------------------------
    // O decodificador
    // --------------------------------------------------------------------------------------

    private class Resposta(
        val json: JSONObject,
        val plano: ByteArray?,
        val largura: Int = 0,
        val altura: Int = 0,
    )

    /**
     * Abre um `MediaCodec` **novo**, alimenta a unidade, e conta o que aconteceu.
     *
     * Um codec por corte, e não um reaproveitado: estado de decodificador é contagioso, e um braço
     * que herde o buraco do anterior mede a soma dos dois. O `sonda-fatias` do macOS faz igual.
     *
     * Modo `ByteBuffer` (sem `Surface`), ao contrário do `H264Decoder` do produto: é a única forma
     * de responder "o que foi pintado onde faltou fatia?" sem olhar a tela do aparelho.
     */
    private fun decodificar(
        unidade: ByteArray,
        rotulo: String,
        referencia: ByteArray?,
        seguintes: List<ByteArray> = emptyList(),
        idrCompleto: ByteArray? = null,
    ): Resposta {
        val j = JSONObject().put("rotulo", rotulo)
        val fonteDosParametros = idrCompleto ?: unidade
        val csd = parametros(fonteDosParametros)
        if (csd == null) {
            return Resposta(j.put("erro", "sem SPS/PPS no fluxo"), null)
        }
        val dim = dimensoesDoSps(fonteDosParametros)
        if (dim == null) {
            return Resposta(j.put("erro", "não consegui ler largura/altura do SPS"), null)
        }
        j.put("largura_pedida", dim.first).put("altura_pedida", dim.second)

        var codec: MediaCodec? = null
        try {
            val formato = MediaFormat.createVideoFormat(MIME, dim.first, dim.second).apply {
                setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd))
                if (!comSurface) {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
                    )
                }
            }
            // `createByCodecName` quando a corrida nomeia o componente. Existe porque "o
            // `MediaCodec` aceita?" e "**este** componente aceita?" são perguntas diferentes, e a
            // segunda é a que decide se há saída de produto quando a primeira dá uma resposta
            // desconfortável: o `c2.android.avc.decoder` é o decodificador de software que todo
            // aparelho Android carrega, e ele é o controle deste experimento.
            val c = if (codecPedido.isNotBlank()) {
                MediaCodec.createByCodecName(codecPedido)
            } else {
                MediaCodec.createDecoderByType(MIME)
            }
            codec = c
            c.configure(formato, if (comSurface) superficieDeProva(dim) else null, null, 0)
            c.start()
            j.put("codec", runCatching { c.name }.getOrDefault("?"))
                .put("saida", if (comSurface) "surface" else "bytebuffer")

            fun enfileirar(dados: ByteArray, pts: Long, flags: Int) {
                val idx = c.dequeueInputBuffer(500_000)
                if (idx < 0) throw IllegalStateException("sem buffer de entrada em 500 ms")
                val buf = c.getInputBuffer(idx)!!
                buf.clear()
                buf.put(dados)
                c.queueInputBuffer(idx, 0, dados.size, pts, flags)
            }

            enfileirar(unidade, 0L, MediaCodec.BUFFER_FLAG_KEY_FRAME)
            for ((i, s) in seguintes.withIndex()) enfileirar(s, (i + 1) * 33_333L, 0)
            // EOS: sem ele um decodificador que segure o quadro no pipeline pareceria tê-lo
            // recusado, e "não saiu imagem" mediria a minha paciência em vez da política dele.
            enfileirar(ByteArray(0), (seguintes.size + 1) * 33_333L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)

            var saidas = 0
            var esperado = 0L
            var planoY: ByteArray? = null
            var planoU: ByteArray? = null
            var planoV: ByteArray? = null
            var larguraSaida = 0
            var alturaSaida = 0
            val info = MediaCodec.BufferInfo()
            laço@ while (esperado < ESPERA_TOTAL_US) {
                val idx = c.dequeueOutputBuffer(info, ESPERA_PASSO_US)
                when {
                    idx >= 0 -> {
                        // Em Surface o buffer de saída não tem tamanho legível, então `info.size`
                        // não serve de critério; o que **não** conta é o buffer que só carrega o
                        // fim do fluxo, e contá-lo faria toda corrida dizer um quadro a mais.
                        val ehQuadro = if (comSurface) {
                            (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0
                        } else {
                            info.size > 0
                        }
                        if (ehQuadro) {
                            saidas++
                            if (!comSurface && planoY == null) {
                                val img = runCatching { c.getOutputImage(idx) }.getOrNull()
                                if (img != null && img.format == ImageFormat.YUV_420_888) {
                                    larguraSaida = img.width
                                    alturaSaida = img.height
                                    planoY = copiarPlano(img, 0, larguraSaida, alturaSaida)
                                    // Croma, e ele não é luxo: **"verde" é uma resposta de croma.**
                                    // Um buraco preenchido com Y=0 e croma 128 é preto; o mesmo
                                    // Y=0 com croma 0 é o verde clássico de decodificador. Medir
                                    // só a luminância responderia "escuro" a uma pergunta que é
                                    // "de que cor".
                                    planoU = copiarPlano(img, 1, larguraSaida / 2, alturaSaida / 2)
                                    planoV = copiarPlano(img, 2, larguraSaida / 2, alturaSaida / 2)
                                }
                                runCatching { img?.close() }
                            }
                        }
                        val fim = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        // Com Surface, `render = true` é o caminho do produto: é ele que entrega o
                        // quadro ao compositor, e é nele que um componente que "aceitou e não fez"
                        // se denunciaria.
                        c.releaseOutputBuffer(idx, comSurface)
                        if (fim) break@laço
                    }
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = c.outputFormat
                        j.put("formato_de_saida", f.toString())
                        larguraSaida = runCatching { f.getInteger(MediaFormat.KEY_WIDTH) }.getOrDefault(0)
                        alturaSaida = runCatching { f.getInteger(MediaFormat.KEY_HEIGHT) }.getOrDefault(0)
                    }
                    else -> esperado += ESPERA_PASSO_US
                }
            }

            j.put("saidas", saidas)
                .put(
                    "imagem",
                    when {
                        planoY != null -> "SIM ${larguraSaida}x$alturaSaida"
                        comSurface && saidas > 0 -> "buffer SIM (surface: sem pixel para ler)"
                        else -> "não"
                    },
                )
                .put("erro", JSONObject.NULL)
            if (planoY != null) {
                j.put(
                    "bandas",
                    bandas(planoY, planoU, planoV, larguraSaida, alturaSaida, referencia),
                )
            }
            return Resposta(j, planoY, larguraSaida, alturaSaida)
        } catch (e: MediaCodec.CodecException) {
            // O modo de falha que interessa: o codec **recusou**, e disse por quê.
            j.put("erro", "CodecException")
                .put("erro_codigo", e.errorCode)
                .put("erro_diagnostico", e.diagnosticInfo)
                .put("erro_recuperavel", e.isRecoverable)
                .put("erro_transitorio", e.isTransient)
                .put("imagem", "não")
            Log.w(TAG, "$rotulo: CodecException ${e.errorCode} ${e.diagnosticInfo}", e)
            return Resposta(j, null)
        } catch (e: Exception) {
            j.put("erro", "${e.javaClass.simpleName}: ${e.message}").put("imagem", "não")
            Log.w(TAG, "$rotulo: exceção", e)
            return Resposta(j, null)
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
        }
    }

    /**
     * Uma `Surface` de prova, apoiada numa `SurfaceTexture` fora da tela.
     *
     * Fora da tela de propósito: o que se quer saber é o que o **decodificador** faz, e pôr isto
     * numa janela acrescentaria o compositor à cadeia sem acrescentar resposta — e obrigaria a
     * capturar a tela de um aparelho para conferir.
     */
    private fun superficieDeProva(dim: Pair<Int, Int>): Surface {
        superficie?.let { return it }
        val t = SurfaceTexture(0).apply { setDefaultBufferSize(dim.first, dim.second) }
        val s = Surface(t)
        textura = t
        superficie = s
        return s
    }

    /**
     * Copia um plano de uma `Image` para um array contíguo `largura*altura`.
     *
     * `pixelStride` não é 1 no croma semiplanar (NV12/NV21), que é o formato que os três
     * aparelhos desta bancada entregam: U e V vivem intercalados no mesmo buffer, e ler o plano
     * como se fosse contíguo daria a metade do outro componente.
     */
    private fun copiarPlano(
        img: android.media.Image,
        indice: Int,
        largura: Int,
        altura: Int,
    ): ByteArray? {
        if (indice >= img.planes.size || largura <= 0 || altura <= 0) return null
        val p = img.planes[indice]
        val buf = p.buffer
        val passo = p.rowStride
        val passoPixel = p.pixelStride
        val saida = ByteArray(largura * altura)
        val linha = ByteArray(max(passo, 1))
        for (y in 0 until altura) {
            val restante = buf.capacity() - y * passo
            if (restante <= 0) break
            buf.position(y * passo)
            val n = min(passo, restante)
            buf.get(linha, 0, n)
            if (passoPixel == 1) {
                System.arraycopy(linha, 0, saida, y * largura, min(largura, n))
            } else {
                for (x in 0 until largura) {
                    val i = x * passoPixel
                    if (i < n) saida[y * largura + x] = linha[i]
                }
            }
        }
        return saida
    }

    // --------------------------------------------------------------------------------------
    // O que foi pintado onde faltou fatia — por estatística de banda, nunca por quadro
    // --------------------------------------------------------------------------------------

    /**
     * Divide a imagem em 8 bandas horizontais e, para cada uma, devolve média, desvio, o valor
     * mais frequente e a fração de amostras iguais à referência.
     *
     * Como ler:
     * - `igual_a_referencia` perto de 100 % → a banda foi pintada com a imagem certa;
     * - desvio ~0 com `moda` em 16 (ou 0) → banda **lisa**, preenchida pelo ocultador; 16 é preto
     *   de faixa limitada e é o que a maioria dos decodificadores escreve num buraco;
     * - desvio alto e `igual_a_referencia` baixo → **lixo**: macrobloco decodificado com resíduo
     *   errado, que é a "imagem suja" da pergunta.
     */
    private fun bandas(
        y: ByteArray,
        u: ByteArray?,
        v: ByteArray?,
        largura: Int,
        altura: Int,
        referencia: ByteArray?,
    ): JSONArray {
        val saida = JSONArray()
        if (largura <= 0 || altura <= 0) return saida
        val nBandas = 8
        for (b in 0 until nBandas) {
            val y0 = altura * b / nBandas
            val y1 = altura * (b + 1) / nBandas
            var soma = 0.0
            var soma2 = 0.0
            var n = 0
            var iguais = 0
            val hist = IntArray(256)
            var linha = y0
            while (linha < y1) {
                var col = 0
                while (col < largura) {
                    val i = linha * largura + col
                    if (i >= y.size) break
                    val v = y[i].toInt() and 0xFF
                    soma += v
                    soma2 += v.toDouble() * v
                    hist[v]++
                    n++
                    if (referencia != null && i < referencia.size &&
                        referencia[i] == y[i]
                    ) iguais++
                    col += PASSO
                }
                linha += PASSO
            }
            if (n == 0) continue
            // Croma da mesma banda, em resolução pela metade nos dois eixos.
            val mediaU = mediaDoPlano(u, largura / 2, y0 / 2, y1 / 2)
            val mediaV = mediaDoPlano(v, largura / 2, y0 / 2, y1 / 2)
            val media = soma / n
            val variancia = max(0.0, soma2 / n - media * media)
            var moda = 0
            for (v in 0..255) if (hist[v] > hist[moda]) moda = v
            saida.put(
                JSONObject()
                    .put("banda", b)
                    .put("linhas", "$y0..${y1 - 1}")
                    .put("media", (media * 10).toInt() / 10.0)
                    .put("desvio", (sqrt(variancia) * 10).toInt() / 10.0)
                    .put("moda", moda)
                    .put("media_u", if (mediaU == null) JSONObject.NULL else mediaU)
                    .put("media_v", if (mediaV == null) JSONObject.NULL else mediaV)
                    .put("pct_na_moda", hist[moda] * 1000 / n / 10.0)
                    .put(
                        "igual_a_referencia_pct",
                        if (referencia == null) JSONObject.NULL else iguais * 1000 / n / 10.0,
                    ),
            )
        }
        return saida
    }

    /** Média de um plano de croma nas linhas `[y0, y1)`. `null` quando o plano não veio. */
    private fun mediaDoPlano(plano: ByteArray?, largura: Int, y0: Int, y1: Int): Double? {
        if (plano == null || largura <= 0) return null
        var soma = 0.0
        var n = 0
        var linha = y0
        while (linha < y1) {
            var col = 0
            while (col < largura) {
                val i = linha * largura + col
                if (i >= plano.size) break
                soma += (plano[i].toInt() and 0xFF)
                n++
                col += PASSO
            }
            linha += PASSO
        }
        return if (n == 0) null else (soma / n * 10).toInt() / 10.0
    }

    // --------------------------------------------------------------------------------------
    // SPS/PPS
    // --------------------------------------------------------------------------------------

    /** SPS+PPS em Annex-B, com start codes — o `csd-0` que o `MediaFormat` quer. */
    private fun parametros(au: ByteArray): ByteArray? {
        val saida = java.io.ByteArrayOutputStream()
        var achou = false
        for (nal in AnnexBDaSonda.nals(au)) {
            if (nal.tipo == AnnexBDaSonda.NAL_SPS || nal.tipo == AnnexBDaSonda.NAL_PPS) {
                saida.write(au, nal.inicioComPrefixo, nal.fim - nal.inicioComPrefixo)
                achou = true
            }
        }
        return if (achou) saida.toByteArray() else null
    }

    /**
     * Largura e altura do SPS. Leitura própria e mínima — o `Sps` do produto lê de `ByteBuffer` e
     * este arquivo já é um `ByteArray`; duplicar vinte linhas é mais barato que uma conversão que
     * esconderia um erro de deslocamento.
     */
    private fun dimensoesDoSps(au: ByteArray): Pair<Int, Int>? {
        val sps = AnnexBDaSonda.nals(au).firstOrNull { it.tipo == AnnexBDaSonda.NAL_SPS }
            ?: return null
        val cru = ByteArray(sps.fim - sps.cabecalho - 1)
        for (i in cru.indices) cru[i] = au[sps.cabecalho + 1 + i]
        val b = desescapar(cru)
        val r = Bits(b)
        val perfil = r.u(8); r.u(8); r.u(8)
        r.ue()  // seq_parameter_set_id
        if (perfil in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
            val chroma = r.ue()
            if (chroma == 3) r.u(1)
            r.ue(); r.ue(); r.u(1)
            if (r.u(1) == 1) {
                val n = if (chroma != 3) 8 else 12
                for (i in 0 until n) if (r.u(1) == 1) return null  // listas de escala: não preciso
            }
        }
        r.ue()  // log2_max_frame_num_minus4
        val pocTipo = r.ue()
        if (pocTipo == 0) r.ue()
        else if (pocTipo == 1) {
            r.u(1); r.se(); r.se()
            val n = r.ue()
            for (i in 0 until n) r.se()
        }
        r.ue()  // max_num_ref_frames
        r.u(1)  // gaps_in_frame_num_value_allowed_flag
        val larguraMbs = r.ue() + 1
        val alturaMapa = r.ue() + 1
        val frameMbsOnly = r.u(1)
        if (frameMbsOnly == 0) r.u(1)
        r.u(1)  // direct_8x8_inference_flag
        var cropE = 0; var cropD = 0; var cropC = 0; var cropB = 0
        if (r.u(1) == 1) { cropE = r.ue(); cropD = r.ue(); cropC = r.ue(); cropB = r.ue() }
        val largura = larguraMbs * 16 - (cropE + cropD) * 2
        val altura = (2 - frameMbsOnly) * alturaMapa * 16 - (cropC + cropB) * 2
        return largura to altura
    }

    private fun desescapar(b: ByteArray): ByteArray {
        val out = ByteArray(b.size)
        var n = 0
        var i = 0
        while (i < b.size) {
            if (i + 2 < b.size && b[i] == 0.toByte() && b[i + 1] == 0.toByte() && b[i + 2] == 3.toByte()) {
                out[n++] = 0; out[n++] = 0; i += 3
            } else {
                out[n++] = b[i]; i++
            }
        }
        return out.copyOf(n)
    }

    private class Bits(val b: ByteArray) {
        var bit = 0
        fun u(n: Int): Int {
            var v = 0
            for (i in 0 until n) {
                val idx = bit shr 3
                val x = if (idx < b.size) (b[idx].toInt() shr (7 - (bit and 7))) and 1 else 0
                v = (v shl 1) or x
                bit++
            }
            return v
        }
        fun ue(): Int {
            var zeros = 0
            while (u(1) == 0 && zeros < 32) zeros++
            return (1 shl zeros) - 1 + if (zeros == 0) 0 else u(zeros)
        }
        fun se(): Int {
            val k = ue()
            return if (k % 2 == 0) -(k / 2) else (k + 1) / 2
        }
    }

    /** Os decodificadores AVC que este aparelho declara — para o relatório dizer quem respondeu. */
    private fun enumerarDecodificadores(): JSONArray {
        val saida = JSONArray()
        for (info in MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos) {
            if (info.isEncoder) continue
            if (!info.supportedTypes.any { it.equals(MIME, ignoreCase = true) }) continue
            saida.put(
                JSONObject()
                    .put("nome", info.name)
                    .put("hardware", runCatching { info.aceleradoPorHardware }.getOrDefault(false)),
            )
        }
        return saida
    }
}
