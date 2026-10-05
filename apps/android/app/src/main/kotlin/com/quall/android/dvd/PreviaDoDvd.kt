package com.quall.android.dvd

import android.view.Surface
import android.view.SurfaceHolder

/**
 * A superfície da prévia do DVD na tela "Converter DVD" (o pedido do Pessoa Exemplo, 29/09: ver no A07 o que
 * vai à rede): a `SurfaceView` a entrega, e a thread do ritmo da [TransmissaoDoDvd] desenha nela (o
 * `RenderizadorDv` da DV e da placa). O mesmo contrato do `PreviaDv`: o desenho corre com [trava]
 * presa, e `surfaceDestroyed` a pega antes de voltar (desenhar numa superfície destruída é erro de EGL).
 */
object PreviaDoDvd : SurfaceHolder.Callback {
    val trava = java.util.concurrent.locks.ReentrantLock()

    @Volatile var superficie: Surface? = null
        private set
    var largura = 0
        private set
    var altura = 0
        private set

    /** Muda a cada troca, para a thread saber que a superfície EGL dela envelheceu. */
    @Volatile var versao = 0
        private set

    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        trava.lock()
        try {
            superficie = holder.surface
            largura = width
            altura = height
            versao++
        } finally {
            trava.unlock()
        }
    }

    /** Espera o quadro em curso (até 500 ms: a tela não pode travar). */
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        val pegou = trava.tryLock(500, java.util.concurrent.TimeUnit.MILLISECONDS)
        try {
            if (superficie === holder.surface) {
                superficie = null
                versao++
            }
        } finally {
            if (pegou) trava.unlock()
        }
    }
}
