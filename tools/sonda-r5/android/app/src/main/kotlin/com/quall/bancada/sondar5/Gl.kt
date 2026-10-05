package com.quall.bancada.sondar5

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Size
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val EGL_RECORDABLE_ANDROID = 0x3142

/**
 * Um contexto EGL numa thread própria. Tudo o que toca GL roda por [executar] ou no [handler].
 * A configuração é `RECORDABLE`, a que o `MediaCodec` exige numa superfície de janela.
 */
class NucleoGl(nome: String) {
    private val thread = HandlerThread(nome).apply { start() }
    val handler = Handler(thread.looper)
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var contexto: EGLContext = EGL14.EGL_NO_CONTEXT
    private lateinit var config: EGLConfig
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE

    init { executar { iniciar() } }

    fun <T> executar(bloco: () -> T): T {
        if (Looper.myLooper() == thread.looper) return bloco()
        var r: Result<T>? = null
        val l = CountDownLatch(1)
        handler.post { r = runCatching(bloco); l.countDown() }
        check(l.await(10, TimeUnit.SECONDS)) { "a thread GL não respondeu em 10 s" }
        return r!!.getOrThrow()
    }

    private fun iniciar() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val v = IntArray(2)
        check(EGL14.eglInitialize(display, v, 0, v, 1)) { "eglInitialize falhou" }
        val atrib = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        check(EGL14.eglChooseConfig(display, atrib, 0, cfgs, 0, 1, n, 0) && n[0] > 0) { "eglChooseConfig falhou" }
        config = cfgs[0]!!
        contexto = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(contexto != EGL14.EGL_NO_CONTEXT) { "eglCreateContext falhou" }
        pbuffer = EGL14.eglCreatePbufferSurface(
            display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        correntePbuffer()
    }

    fun correntePbuffer() {
        check(EGL14.eglMakeCurrent(display, pbuffer, pbuffer, contexto)) { "eglMakeCurrent(pbuffer) falhou" }
    }

    fun superficieDeJanela(s: Surface): EGLSurface {
        val e = EGL14.eglCreateWindowSurface(display, config, s, intArrayOf(EGL14.EGL_NONE), 0)
        check(e != null && e != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface falhou: 0x${Integer.toHexString(EGL14.eglGetError())}" }
        return e
    }

    fun corrente(e: EGLSurface) {
        check(EGL14.eglMakeCurrent(display, e, e, contexto)) { "eglMakeCurrent falhou" }
    }

    fun carimbar(e: EGLSurface, ns: Long): Boolean = EGLExt.eglPresentationTimeANDROID(display, e, ns)
    fun trocar(e: EGLSurface): Boolean = EGL14.eglSwapBuffers(display, e)
    fun destruir(e: EGLSurface) { EGL14.eglDestroySurface(display, e) }

    fun liberar() {
        runCatching {
            executar {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(display, pbuffer)
                EGL14.eglDestroyContext(display, contexto)
                EGL14.eglTerminate(display)
            }
        }
        thread.quitSafely()
    }
}

/** O desenho de uma textura externa (a da câmera) num retângulo que cobre a superfície. */
class ProgramaOes {
    private val programa: Int
    private val aPos: Int
    private val aTex: Int
    private val uTex: Int
    private val vertices: FloatBuffer = buffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val coords: FloatBuffer = buffer(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))

    init {
        val vs = compilar(GLES20.GL_VERTEX_SHADER, """
            attribute vec4 aPos;
            attribute vec4 aTex;
            uniform mat4 uTex;
            varying vec2 v;
            void main() { gl_Position = aPos; v = (uTex * aTex).xy; }
        """.trimIndent())
        val fs = compilar(GLES20.GL_FRAGMENT_SHADER, """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 v;
            uniform samplerExternalOES s;
            void main() { gl_FragColor = texture2D(s, v); }
        """.trimIndent())
        programa = GLES20.glCreateProgram()
        GLES20.glAttachShader(programa, vs)
        GLES20.glAttachShader(programa, fs)
        GLES20.glLinkProgram(programa)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(programa, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] == GLES20.GL_TRUE) { "link: ${GLES20.glGetProgramInfoLog(programa)}" }
        aPos = GLES20.glGetAttribLocation(programa, "aPos")
        aTex = GLES20.glGetAttribLocation(programa, "aTex")
        uTex = GLES20.glGetUniformLocation(programa, "uTex")
    }

    fun desenhar(textura: Int, matriz: FloatArray, largura: Int, altura: Int) {
        GLES20.glViewport(0, 0, largura, altura)
        GLES20.glUseProgram(programa)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textura)
        GLES20.glUniformMatrix4fv(uTex, 1, false, matriz, 0)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, vertices)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, coords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun compilar(tipo: Int, fonte: String): Int {
        val s = GLES20.glCreateShader(tipo)
        GLES20.glShaderSource(s, fonte)
        GLES20.glCompileShader(s)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        check(ok[0] == GLES20.GL_TRUE) { "shader: ${GLES20.glGetShaderInfoLog(s)}" }
        return s
    }

    private fun buffer(v: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(v); position(0) }
}

/**
 * Uma `SurfaceTexture` que consome os quadros da câmera e anota o carimbo e a hora da chegada.
 * Não desenha nada na tela e não guarda pixel: é o sorvedouro da prévia (S-A1, S-A4) e a entrada
 * do divisor (S-A3, S-A4).
 */
class Sumidouro(val gl: NucleoGl, val nome: String) {
    class Quadro(val carimboNs: Long, val chegadaNs: Long)

    private val quadros = ArrayList<Quadro>()
    @Volatile var aoQuadro: ((Long) -> Unit)? = null
    var textura = 0; private set
    lateinit var st: SurfaceTexture; private set
    lateinit var surface: Surface; private set
    val matriz = FloatArray(16)
    @Volatile var tamanho: Size? = null; private set
    @Volatile private var liberado = false

    init {
        gl.executar {
            val t = IntArray(1)
            GLES20.glGenTextures(1, t, 0)
            textura = t[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textura)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            st = SurfaceTexture(textura)
            st.setOnFrameAvailableListener({ chegou() }, gl.handler)
            surface = Surface(st)
        }
    }

    /** Erros na thread GL: contados, nunca propagados (uma exceção aqui derrubaria o processo). */
    @Volatile var erros = 0; private set
    @Volatile var ultimoErro: String? = null; private set

    private fun chegou() {
        val chegada = System.nanoTime()
        if (liberado) return
        try {
            st.updateTexImage()
            st.getTransformMatrix(matriz)
            val carimbo = st.timestamp
            synchronized(quadros) { quadros.add(Quadro(carimbo, chegada)) }
            aoQuadro?.invoke(carimbo)
        } catch (t: Throwable) {
            erros++
            ultimoErro = "${t.javaClass.simpleName}: ${t.message}"
            android.util.Log.w(ETIQUETA, "sumidouro $nome: $ultimoErro")
        }
    }

    fun ajustar(s: Size) = gl.executar { st.setDefaultBufferSize(s.width, s.height); tamanho = s }

    fun copia(): List<Quadro> = synchronized(quadros) { ArrayList(quadros) }
    fun entre(t0: Long, t1: Long): List<Quadro> = copia().filter { it.chegadaNs in t0..t1 }

    fun liberar() {
        runCatching {
            gl.executar {
                liberado = true
                aoQuadro = null
                st.release()
                surface.release()
                GLES20.glDeleteTextures(1, intArrayOf(textura), 0)
            }
        }
    }
}

/**
 * O divisor GL do desenho (§2.1, braço a): cada quadro da [fonte] é desenhado em cada saída de
 * codificador ligada, no tamanho dela. Com `carimbar`, cada troca leva
 * `eglPresentationTimeANDROID` com o carimbo da `SurfaceTexture`; sem, o codificador carimba
 * sozinho na troca. Ligar e desligar uma saída **não toca na câmera**.
 */
class Divisor(private val gl: NucleoGl, private val fonte: Sumidouro) {
    class Saida(val nome: String, val cod: Codificador, val egl: EGLSurface, val carimbar: Boolean) {
        /** (carimbo da câmera, `nanoTime` logo antes da troca) de cada quadro desenhado. */
        val trocas = ArrayList<LongArray>()
        val custoNs = ArrayList<Long>()
        var falhasDoCarimbo = 0
        var falhasDaTroca = 0
    }

    private val saidas = CopyOnWriteArrayList<Saida>()
    private val programa: ProgramaOes = gl.executar { ProgramaOes() }

    init { fonte.aoQuadro = { ts -> desenhar(ts) } }

    fun ligar(nome: String, cod: Codificador, carimbar: Boolean): Saida = gl.executar {
        Saida(nome, cod, gl.superficieDeJanela(cod.entrada), carimbar).also { saidas.add(it) }
    }

    fun desligar(s: Saida) = gl.executar {
        saidas.remove(s)
        gl.correntePbuffer()
        gl.destruir(s.egl)
    }

    private fun desenhar(ts: Long) {
        for (s in saidas) try {
            val t0 = System.nanoTime()
            gl.corrente(s.egl)
            programa.desenhar(fonte.textura, fonte.matriz, s.cod.largura, s.cod.altura)
            if (s.carimbar && !gl.carimbar(s.egl, ts)) s.falhasDoCarimbo++
            val antesDaTroca = System.nanoTime()
            if (!gl.trocar(s.egl)) s.falhasDaTroca++
            synchronized(s) {
                s.trocas.add(longArrayOf(ts, antesDaTroca))
                s.custoNs.add(System.nanoTime() - t0)
            }
        } catch (t: Throwable) {
            s.falhasDaTroca++
            android.util.Log.w(ETIQUETA, "divisor ${s.nome}: ${t.javaClass.simpleName}: ${t.message}")
        }
        if (saidas.isNotEmpty()) runCatching { gl.correntePbuffer() }
    }
}
