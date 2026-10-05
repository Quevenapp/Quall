package com.quall.android.dvd

import android.content.Context
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.Idioma
import kotlin.concurrent.thread

/**
 * **Assistir aqui** (o pedido do Pessoa Exemplo, 29/09: "no A07 não tem prévia para ver/escutar antes"): o
 * título no próprio aparelho, sem sessão de rede — a [TransmissaoDoDvd] com `local = true` (o mesmo
 * pipeline, o mesmo relógio, Pausar e ±30 s), a prévia na tela e o Ouvir. É da tela: ela para quando
 * a tela sai de vista, e o Transmitir a para e segue do mesmo ponto no Espelhar.
 *
 * O leitor vem da [SessaoDoDvd] (como no Converter e no Transmitir) e volta **sem fechar** no fim: a
 * tela segue com o disco lido. A recusa (§2.1) fecha o leitor, como sempre.
 */
object AssistirAqui {
    private const val TAG = "QuallDvd"

    @Volatile private var atual: TransmissaoDoDvd? = null
    @Volatile private var abrindo = false
    /** O contexto da aplicação, para as frases do fim no idioma escolhido ([Idioma.contexto], pedido a cada vez). */
    @Volatile private var aplicacao: Context? = null

    val noAr: Boolean get() = atual != null || abrindo

    /** Começa (numa thread: a reconferência fala com o leitor). */
    fun comecar(c: Context, numero: Int, faixa: Int) {
        synchronized(this) {
            if (atual != null || abrindo) return
            abrindo = true
        }
        val contexto = c.applicationContext
        aplicacao = contexto
        TransmissaoDvdBus.publicar(TransmissaoDvdBus.Estado(fase = TransmissaoDvdBus.Fase.PREPARANDO, local = true, titulo = numero))
        thread(name = "quall-dvd-assistir") {
            val entregue = SessaoDoDvd.entregarAoServico()
            if (entregue == null) {
                synchronized(this) { abrindo = false }
                parado(Frase(R.string.dvd_leitor_nao_aberto_assistir))
                return@thread
            }
            val (l, d) = entregue
            val frase = try {
                if (!QuallDvd.disponivel) throw ErroDoDvd(Frase(R.string.dvd_nao_toca_64_bits), "QuallDvd indisponível")
                val titulo = d.titulos.firstOrNull { it.numero == numero }
                    ?: throw ErroDoDvd(Frase(R.string.dvd_titulo_nao_existe, numero), "o título $numero não existe")
                titulo.recusa?.let { throw RecusaDoDisco(it) }
                SessaoDoDvd.reconferir(l, d)
                val f = if (faixa in titulo.faixasConvertiveis.indices) faixa else if (titulo.faixasConvertiveis.isEmpty()) -1 else 0
                val ouvinte = object : TransmissaoDoDvd.Ouvinte {
                    override fun aoCair(motivo: String) {
                        thread(name = "quall-dvd-assistir-caiu") { parar(motivo, fechar = true) }
                    }
                }
                val t = TransmissaoDoDvd(contexto, l, d.volume, titulo, f, aceita854 = ConversorDvd.aceita854(), ouvinte = ouvinte, local = true)
                synchronized(this) { atual = t; abrindo = false }
                t.comecar()
                Log.i(TAG, "assistir aqui: título $numero")
                null
            } catch (e: RecusaDoDisco) {
                e.recusa
            } catch (e: Exception) {
                Frase(R.string.dvd_nao_abriu, e.fraseDoDvd())
            }
            if (frase != null) {
                synchronized(this) { abrindo = false }
                SessaoDoDvd.devolverDoServico()
                parado(frase)
            }
        }
    }

    /**
     * Para (fora da thread principal: a leitura pode levar segundos para sair). [depois] roda na
     * principal com a posição onde parou (90 kHz), para o Transmitir seguir dali.
     */
    fun parar(motivo: String = "", fechar: Boolean = false, depois: ((Long) -> Unit)? = null) {
        val t = synchronized(this) { atual.also { atual = null } }
        if (t == null) {
            depois?.let { d -> android.os.Handler(android.os.Looper.getMainLooper()).post { d(0) } }
            return
        }
        val trabalho = {
            val posicao = t.posicao90k()
            t.encerrar()
            if (!t.esperarTerminar(30_000)) {
                parado(FrasesDoDvd.LEITOR_PRESO)
                t.esperarTerminar(0)
                SessaoDoDvd.devolverDoServico()
            } else {
                if (fechar) SessaoDoDvd.devolverDoServico() else SessaoDoDvd.devolverSemFechar()
                parado(motivo.takeIf { it.isNotEmpty() }?.let { Frase.cru(it) })
                depois?.let { d -> android.os.Handler(android.os.Looper.getMainLooper()).post { d(posicao) } }
            }
        }
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) thread(name = "quall-dvd-assistir-parar") { trabalho() }
        else trabalho()
    }

    /**
     * O fim no Bus. A frase vai montada no idioma de agora (o `MirrorService` também publica texto no mesmo
     * campo); `null`, só o fim, sem frase nova.
     */
    private fun parado(frase: Frase?) {
        val ctx = aplicacao
        val texto = if (frase == null || ctx == null) "" else frase.em(Idioma.textos(Idioma.contexto(ctx)))
        TransmissaoDvdBus.atualizar { it.copy(fase = TransmissaoDvdBus.Fase.PARADA, local = true, mensagem = it.mensagem.ifEmpty { texto }) }
    }
}
