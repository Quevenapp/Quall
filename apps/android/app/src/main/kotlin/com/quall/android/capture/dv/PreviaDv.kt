package com.quall.android.capture.dv

import android.view.Surface
import android.view.SurfaceHolder

/**
 * A superfície da prévia da DV: a `SurfaceView` da tela a entrega e a thread `quall-dv` desenha
 * nela (`RenderizadorDv`), com a `FonteDv` aberta pelo espelhamento ou pela gravação.
 *
 * **A trava é a mesma do desenho.** O desenho de um quadro corre com [trava] presa, e
 * `surfaceDestroyed` também a pega antes de voltar: quando o sistema destrói a superfície, nenhum
 * desenho está no meio, e o próximo quadro já a vê nula. Desenhar numa superfície destruída é erro
 * de EGL (e, em alguns aparelhos, queda).
 */
object PreviaDv : SurfaceHolder.Callback {
    val trava = java.util.concurrent.locks.ReentrantLock()

    /** A superfície ligada, e o seu tamanho. Lidos com [trava] presa. */
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

    /**
     * Espera o quadro em curso terminar, com prazo de 500 ms (a tela não pode travar: ANR). Sem a
     * trava no prazo, solta assim mesmo; o próximo quadro vê a superfície nula.
     */
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
