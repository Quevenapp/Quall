package com.quall.android.capture.dv

import android.content.Context
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.Idioma
import com.quall.android.audio.FonteDeAudio
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * O som da placa de captura na gravação (a P4 adiantada, `docs/placa-de-captura-usb.md` §9.6; desde
 * o §11, um **ramal** do som da placa do [DonoDaPlaca]: o mesmo `AudioRecord` vai à rede, ao
 * arquivo e ao ouvir). A placa é uma entrada de áudio USB que o Android já expõe (§1: 48 kHz, mono,
 * 16 bits); o dono pede a entrada dela e confere o roteado.
 *
 * Cada quadro de 20 ms chega com a hora de captura da primeira amostra (`getTimestamp`, no relógio
 * do carimbo do vídeo), é posto na linha do tempo do vídeo ([LinhaDoSomDaPlaca]: o som antes do
 * primeiro quadro cai, um buraco vira silêncio), duplicado para estéreo e entregue ao
 * [GravadorMp4.aoSom].
 *
 * **O fim** ([encerrar], §11, item 3): o som terminava ~51 ms antes da imagem (medido: vídeo 83,742 s,
 * som 83,691 s) — o `AudioRecord` entrega com dezenas de ms de atraso, e parar a leitura junto com o
 * vídeo deixava de fora o som dos últimos quadros (mais a duração do último quadro no MP4). Agora o
 * vídeo para primeiro, e a leitura segue até o som chegar ao fim do vídeo ([LinhaDoSomDaPlaca.alvoDoFim]),
 * no máximo [ESPERA_DO_FIM_MS]; o que passar é cortado, e o que faltar vira silêncio.
 */
class SomDaPlaca private constructor(
    private val gravador: GravadorMp4,
    private val fonte: FonteDeAudio,
) {
    @Volatile private var parar = false
    /** O fim do vídeo em amostras, quando o vídeo parou ([encerrar]); `Long.MAX_VALUE` antes. */
    @Volatile private var alvo = Long.MAX_VALUE
    private val linha = LinhaDoSomDaPlaca(TAXA)
    private val thread = Thread({ laco() }, "quall-som-placa")
    @Volatile var lidas = 0L
        private set

    private fun laco() {
        val bloco = ShortArray(TAXA / 50)  // 20 ms, o quadro do ramal
        val estereo = ByteBuffer.allocateDirect(TAXA * 4).order(ByteOrder.nativeOrder())  // 1 s
        var semCarimbo = 0L
        try {
            while (!parar && linha.enviadas < alvo) {
                val antes = System.nanoTime()
                val n = fonte.proximoQuadro(bloco)
                if (n <= 0) {
                    // O ramal espera até 200 ms; `parar` ou o prazo do fim tiram daqui. Vazio na hora
                    // é o som da placa que parou (o ramal interrompido): sem girar a CPU.
                    if (System.nanoTime() - antes < 2_000_000L) Thread.sleep(20)
                    continue
                }
                val chegada = System.nanoTime()
                lidas += n
                // A hora da primeira amostra do quadro, pelo carimbo do sistema; sem ele, a chegada
                // menos o quadro.
                val inicio = fonte.instanteDoQuadroUs()?.let { it * 1000L } ?: run {
                    semCarimbo++
                    chegada - n * 1_000_000_000L / TAXA
                }
                val t0 = gravador.t0Ns
                if (t0 < 0) continue  // antes do primeiro quadro: cai
                val plano = linha.planejar(inicio, n, t0, alvo)
                // silêncio (em pedaços de até 1 s), e depois o bloco sem as puladas e as cortadas
                silencio(estereo, plano.silencio)
                val ate = n - plano.cortar
                if (ate > plano.pular) {
                    estereo.clear()
                    for (i in plano.pular until ate) { val v = bloco[i]; estereo.putShort(v); estereo.putShort(v) }
                    gravador.aoSom(estereo, ate - plano.pular, 0)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "som da placa: a leitura morreu", t)
            gravador.semSom(UsbDv.frase(R.string.placa_leitura_do_som_falhou, t.javaClass.simpleName))
        }
        if (semCarimbo > 0) Log.i(TAG, "som da placa: $semCarimbo quadros sem getTimestamp (carimbo pela chegada)")
    }

    private fun silencio(estereo: ByteBuffer, amostras: Long) {
        var s = amostras
        while (s > 0) {
            val m = minOf(s, TAXA.toLong()).toInt()
            estereo.clear()
            for (i in 0 until m) estereo.putInt(0)
            gravador.aoSom(estereo, m, 0)
            s -= m
        }
    }

    /**
     * Encerra o som no fim do vídeo. Chame **depois** de [FonteDv.desligarGravador] (nenhum quadro a
     * mais) e **antes** de [GravadorMp4.parar]: a leitura segue até o som chegar ao fim do vídeo (no
     * máximo [ESPERA_DO_FIM_MS]), completa com silêncio o que faltar, e solta o ramal.
     */
    fun encerrar() {
        val t0 = gravador.t0Ns
        val ultimo = gravador.ultimoQuadroNs
        if (t0 >= 0 && ultimo >= 0) {
            alvo = LinhaDoSomDaPlaca.alvoDoFim(ultimo, GravadorMp4.QUADRO_NS, t0, TAXA, multiplo = AMOSTRAS_POR_PACOTE_AAC)
            thread.join(ESPERA_DO_FIM_MS)
        }
        parar = true
        fonte.interromper()
        thread.join(2000)
        // O que o prazo não trouxe vira silêncio (a thread já saiu: a linha é só desta).
        val falta = if (alvo != Long.MAX_VALUE && !thread.isAlive) linha.completar(alvo) else 0L
        if (falta > 0) {
            val estereo = ByteBuffer.allocateDirect(TAXA * 4).order(ByteOrder.nativeOrder())
            silencio(estereo, falta)
        }
        runCatching { fonte.fechar() }
        Log.i(TAG, "som da placa: parado; lidas=$lidas no_arquivo=${linha.enviadas} silencio=${linha.silencioPosto} " +
            "puladas=${linha.puladas} cortadas_no_fim=${linha.cortadas} completadas_no_fim=$falta " +
            "alvo=${if (alvo == Long.MAX_VALUE) "sem vídeo" else "$alvo"} amostras (48 kHz)")  // i18n-fora: diário
    }

    companion object {
        private const val TAG = "QuallDv"
        const val TAXA = DonoDaPlaca.TAXA_DO_SOM
        /** O atraso do `AudioRecord` é de dezenas de ms; meio segundo cobre com folga. */
        const val ESPERA_DO_FIM_MS = 600L
        /** O pacote do AAC: o total de som do arquivo vai num múltiplo dele ([LinhaDoSomDaPlaca.alvoDoFim]). */
        const val AMOSTRAS_POR_PACOTE_AAC = 1024

        /**
         * Pega um ramal do som da placa e começa. Devolve `null` (e diz ao gravador por quê) se não há
         * permissão ou o `AudioRecord` não abriu: a gravação segue sem som. O aviso do roteamento e
         * do silêncio fica no [DonoDaPlaca.avisoDoSom].
         */
        fun comecar(c: Context, g: GravadorMp4): SomDaPlaca? {
            var motivo = ""
            // A falta de permissão vem tipada (o texto do motivo muda com o idioma, `docs/traducao.md`).
            var semPermissao = false
            val f = DonoDaPlaca.ramalDoSom(c, semPermissao = { semPermissao = true }) { motivo = it }
            if (f == null) {
                val t = Idioma.contexto(c)
                g.semSom(if (semPermissao) t.getString(R.string.placa_gravando_sem_permissao_microfone)
                    else t.getString(R.string.placa_som_da_placa_nao_abriu, motivo))
                return null
            }
            return SomDaPlaca(g, f).also { it.thread.start() }
        }
    }
}
