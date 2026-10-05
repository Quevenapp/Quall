package com.quall.android.dvd

import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R

/**
 * **O leitor aberto e o disco lido, entre a tela e o serviço** (a D4): a tela abre o leitor, confere
 * o disco (a proteção, §2.1) e lê os títulos; o Converter passa os dois ao [ConversaoDvdService], que
 * fica dono deles até o fim (a tela pode fechar no meio). Um processo, um leitor: o bulk-only é um
 * comando por vez, e a interface é reivindicada com força.
 */
object SessaoDoDvd {
    private const val TAG = "QuallDvd"

    @Volatile var leitor: LeitorDeDisco? = null
        private set
    @Volatile var disco: DiscoDvd? = null
        private set
    /** O serviço pegou o leitor: a tela não o fecha. */
    @Volatile var doServico = false
        private set

    @Synchronized
    fun abrir(usb: UsbManager, d: UsbDevice): LeitorDeDisco {
        // O leitor ainda é de um serviço (a transmissão cuja leitura ficou presa; a revisão, 6): nada de
        // reaproveitar nem fechar a conexão embaixo dele.
        if (doServico) throw ErroDoDvd(FrasesDoDvd.LEITOR_PRESO, "o leitor ainda é de um serviço")
        leitor?.let { if (it.dispositivo.deviceName == d.deviceName) return it }
        fecharAgora()
        return LeitorDeDisco.abrir(usb, d).also { leitor = it; disco = null }
    }

    @Synchronized fun guardar(d: DiscoDvd) { disco = d }

    /** A tela está lendo o disco (a revisão do código, 11): o serviço não pega o leitor nesse meio. */
    @Volatile var lendo = false
        private set

    /** `false` se já há uma leitura, ou se o leitor é do serviço. */
    @Synchronized
    fun comecarLeitura(): Boolean {
        if (lendo || doServico) return false
        lendo = true
        return true
    }

    @Synchronized fun terminarLeitura() { lendo = false }

    /**
     * O serviço pega o leitor e o disco (null se a tela não os tem, ou se outro serviço já os tem).
     * **A leitura curta da tela** (a manutenção a cada 20 s, algumas centenas de ms) é esperada até
     * [esperaMs] (a revisão da transmissão, 11): o toque que cai no meio dela não vira "o leitor não
     * está aberto".
     */
    fun entregarAoServico(esperaMs: Long = 3_000): Pair<LeitorDeDisco, DiscoDvd>? {
        val limite = System.nanoTime() + esperaMs * 1_000_000
        while (true) {
            synchronized(this) {
                // Um serviço por vez (a T3): converter e transmitir não rodam juntos — o leitor é um só.
                if (doServico) return null
                if (!lendo) {
                    val l = leitor ?: return null
                    val d = disco ?: return null
                    doServico = true
                    return l to d
                }
            }
            if (System.nanoTime() > limite) return null
            Thread.sleep(50)
        }
    }

    /**
     * **A reconferência** (a revisão do código, 3), do Converter e do Transmitir: entre a tela e o
     * toque o disco pode ter sido trocado. Pronto de novo, a proteção de novo (CPST e perfil, §2.1) e o
     * mesmo volume; senão [RecusaDoDisco] ou [ErroDoDvd] com a frase.
     */
    fun reconferir(l: LeitorDeDisco, d: DiscoDvd) {
        if (l.esperarPronto(15_000) != LeitorDeDisco.Pronto.PRONTO) {
            throw ErroDoDvd(Frase(R.string.dvd_disco_nao_pronto), "o disco não ficou pronto na reconferência")
        }
        l.conferir()
        val volumeAgora = SistemaDeArquivos.ler(l).volume
        if (volumeAgora != d.volume) {
            throw RecusaDoDisco(FrasesDoDvd.DISCO_TROCADO, "o volume era \"${d.volume}\" e agora é \"$volumeAgora\"")
        }
    }

    /** O Assistir aqui terminou: o leitor e o disco lido ficam com a tela (nada foi trocado por ele). */
    @Synchronized
    fun devolverSemFechar() {
        doServico = false
    }

    /** O serviço terminou: o leitor fecha (o disco lido some junto: pode ter sido trocado). */
    @Synchronized
    fun devolverDoServico() {
        doServico = false
        fecharAgora()
    }

    /** O leitor saiu do USB: a conexão velha fecha mesmo com uma leitura curta em curso (ela falha sozinha). */
    @Synchronized
    fun fecharQuandoSair() {
        if (!doServico) fecharAgora()
    }

    /** A tela saiu sem converter. */
    @Synchronized
    fun fecharSeLivre() {
        if (!doServico) fecharAgora()
    }

    private fun fecharAgora() {
        leitor?.let { runCatching { it.close() }.onFailure { e -> Log.w(TAG, "fechar o leitor: ${Log.erroExterno(e.message)}") } }
        leitor = null
        disco = null
    }
}
