package com.quall.android.capture.dv

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import com.quall.android.core.LogSeguro as Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A prévia da DV (e da placa de captura) na GPU: recebe os três planos do C (`QuallDv.planos`,
 * **sem cópia**: os `ByteBuffer` são a memória do C), com a geometria de `QuallDv.geometria` — na
 * DV, Y 720×480 e U/V 180×480, 4:1:1 progressivo; no MJPEG da placa, Y 640×480 e o croma que o
 * JPEG trouxer (4:2:2 medido) — e desenha na superfície da tela. A gravação não passa por aqui:
 * ela vai em YUV (ImageWriter) ao encoder, sem RGB no meio (o super-branco e a matriz de cor ficam
 * como a fita).
 *
 * O shader faz:
 * - Catmull-Rom 4×4 no luma (480 → 720 na gravação é ampliação, e o bilinear amolece);
 * - bilinear no croma: na DV a amostra 4:1:1 à esquerda (a amostra k do croma fica no luma 4k),
 *   como a fase A mediu; no JPEG no centro dos lumas que ela cobre;
 * - YCbCr BT.601 de faixa limitada → RGB (a placa também é faixa limitada, medido na P0, §8.1);
 * - o encaixe no aspecto do quadro (16:9 ou 4:3), com faixas pretas.
 *
 * **Uma thread só**, a `quall-dv`, que é a mesma que decodifica: o contexto EGL é dela.
 */
class RenderizadorDv {
    private var dpy: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var ctx: EGLContext = EGL14.EGL_NO_CONTEXT
    private var cfg: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var programa = 0
    private val tex = IntArray(3)
    private var vbo = 0
    private var pronto = false
    /** A geometria das texturas de agora; `null` até o primeiro [configurar]. */
    private var geometria: Geometria? = null

    /** Uma superfície de destino. */
    class Alvo internal constructor(val superficie: Surface, internal val egl: EGLSurface, val largura: Int, val altura: Int)

    fun iniciar(): Boolean {
        if (pronto) return true
        dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val v = IntArray(2)
        if (!EGL14.eglInitialize(dpy, v, 0, v, 1)) return falha("eglInitialize")
        val atributos = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        if (!EGL14.eglChooseConfig(dpy, atributos, 0, cfgs, 0, 1, n, 0) || n[0] < 1) return falha("eglChooseConfig")
        cfg = cfgs[0]
        ctx = EGL14.eglCreateContext(dpy, cfg, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (ctx == EGL14.EGL_NO_CONTEXT) return falha("eglCreateContext")
        // Um pbuffer de 1×1 para o contexto ter onde ficar corrente quando nenhum alvo existe.
        pbuffer = EGL14.eglCreatePbufferSurface(dpy, cfg, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        if (!EGL14.eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)) return falha("eglMakeCurrent")
        programa = compilar()
        if (programa == 0) return falha("shader")
        // As texturas nascem em `configurar`, com o tamanho dos planos.
        val quad = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        val b = ByteBuffer.allocateDirect(quad.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().put(quad)
        b.position(0)
        val ids = IntArray(1)
        GLES30.glGenBuffers(1, ids, 0)
        vbo = ids[0]
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, quad.size * 4, b, GLES30.GL_STATIC_DRAW)
        GLES30.glUseProgram(programa)
        for (i in 0 until 3) {
            GLES30.glUniform1i(GLES30.glGetUniformLocation(programa, arrayOf("tY", "tU", "tV")[i]), i)
        }
        pronto = true
        Log.i(TAG, "GPU: EGL ${v[0]}.${v[1]}, ${GLES30.glGetString(GLES30.GL_RENDERER)}")
        return true
    }

    private fun falha(o: String): Boolean {
        Log.e(TAG, "GPU: $o falhou (egl 0x${Integer.toHexString(EGL14.eglGetError())})")
        liberar()
        return false
    }

    /**
     * (Re)faz as texturas no tamanho dos planos de [g] (o `glTexStorage2D` é imutável: um tamanho
     * novo pede texturas novas) e passa a geometria ao shader. Chamado antes do primeiro [subir] e
     * sempre que a geometria mudar.
     */
    fun configurar(g: Geometria) {
        if (!pronto) return
        EGL14.eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)
        if (geometria != null) GLES30.glDeleteTextures(3, tex, 0)
        GLES30.glGenTextures(3, tex, 0)
        for (i in 0 until 3) {
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[i])
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_R8,
                if (i == 0) g.larguraY else g.larguraC, if (i == 0) g.alturaY else g.alturaC)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        }
        GLES30.glUseProgram(programa)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(programa, "tamY"), g.larguraY.toFloat(), g.alturaY.toFloat())
        GLES30.glUniform2f(GLES30.glGetUniformLocation(programa, "tamC"), g.larguraC.toFloat(), g.alturaC.toFloat())
        GLES30.glUniform1i(GLES30.glGetUniformLocation(programa, "centrado"), if (g.cromaCentrado) 1 else 0)
        // A alta definição (as placas HDMI) é BT.709; a DV e a placa analógica, BT.601.
        GLES30.glUniform1i(GLES30.glGetUniformLocation(programa, "hd"), if (g.alturaY >= 720) 1 else 0)
        geometria = g
        Log.i(TAG, "prévia: Y ${g.larguraY}x${g.alturaY}, croma ${g.larguraC}x${g.alturaC} " +
            "(${if (g.cromaCentrado) "centrado" else "à esquerda"}), aspecto ${g.aspectoN}:${g.aspectoD}")
    }

    /** Uma superfície nova (a prévia, ou a entrada do encoder da gravação). */
    fun alvo(s: Surface, largura: Int, altura: Int): Alvo? {
        if (!pronto) return null
        val e = EGL14.eglCreateWindowSurface(dpy, cfg, s, intArrayOf(EGL14.EGL_NONE), 0)
        if (e == EGL14.EGL_NO_SURFACE) {
            Log.w(TAG, "GPU: eglCreateWindowSurface falhou (0x${Integer.toHexString(EGL14.eglGetError())})")
            return null
        }
        return Alvo(s, e, largura, altura)
    }

    fun soltar(a: Alvo) {
        if (!pronto) return
        EGL14.eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)
        EGL14.eglDestroySurface(dpy, a.egl)
    }

    /** Sobe os três planos do quadro que o C acabou de decodificar (depois de [configurar]). */
    fun subir(planos: Array<ByteBuffer>) {
        val g = geometria ?: return
        EGL14.eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 1)
        for (i in 0 until 3) {
            planos[i].position(0)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + i)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[i])
            GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, 0, 0,
                if (i == 0) g.larguraY else g.larguraC, if (i == 0) g.alturaY else g.alturaC,
                GLES30.GL_RED, GLES30.GL_UNSIGNED_BYTE, planos[i])
        }
    }

    /**
     * Desenha o último quadro subido em [a], encaixado no aspecto [an]:[ad] (a DV: 16:9 ou 4:3; a
     * placa: o do quadro).
     */
    fun desenhar(a: Alvo, an: Int, ad: Int): Boolean {
        if (geometria == null || an <= 0 || ad <= 0) return false
        if (!EGL14.eglMakeCurrent(dpy, a.egl, a.egl, ctx)) return false
        // A prévia não espera o vsync: um quadro que o compositor ainda não pegou é trocado pelo
        // seguinte, o que numa prévia é o certo (e o swap nunca prende a thread da câmera).
        EGL14.eglSwapInterval(dpy, 0)
        GLES30.glViewport(0, 0, a.largura, a.altura)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        // O maior retângulo com o aspecto do quadro, centrado.
        var rw = a.largura
        var rh = a.largura * ad / an
        if (rh > a.altura) { rh = a.altura; rw = a.altura * an / ad }
        GLES30.glViewport((a.largura - rw) / 2, (a.altura - rh) / 2, rw, rh)
        GLES30.glUseProgram(programa)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 8, 0)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        return EGL14.eglSwapBuffers(dpy, a.egl)
    }

    fun liberar() {
        if (dpy != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, pbuffer)
            if (ctx != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(dpy, ctx)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(dpy)
        }
        dpy = EGL14.EGL_NO_DISPLAY
        ctx = EGL14.EGL_NO_CONTEXT
        pbuffer = EGL14.EGL_NO_SURFACE
        pronto = false
        geometria = null
    }

    private fun compilar(): Int {
        fun sombreador(tipo: Int, fonte: String): Int {
            val s = GLES30.glCreateShader(tipo)
            GLES30.glShaderSource(s, fonte)
            GLES30.glCompileShader(s)
            val ok = IntArray(1)
            GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) {
                Log.e(TAG, "GPU: shader: ${GLES30.glGetShaderInfoLog(s)}")
                return 0
            }
            return s
        }
        val v = sombreador(GLES30.GL_VERTEX_SHADER, VERTICE)
        val f = sombreador(GLES30.GL_FRAGMENT_SHADER, FRAGMENTO)
        if (v == 0 || f == 0) return 0
        val p = GLES30.glCreateProgram()
        GLES30.glAttachShader(p, v)
        GLES30.glAttachShader(p, f)
        GLES30.glBindAttribLocation(p, 0, "pos")
        GLES30.glLinkProgram(p)
        val ok = IntArray(1)
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) {
            Log.e(TAG, "GPU: link: ${GLES30.glGetProgramInfoLog(p)}")
            return 0
        }
        return p
    }

    companion object {
        private const val TAG = "QuallDv"

        private const val VERTICE = """#version 300 es
in vec2 pos;
out vec2 uv;
void main() {
    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
"""

        // Y tamY e U/V tamC (DV: 720x480 e 180x480, 4:1:1 progressivo; a placa: 640x480 e o croma
        // do JPEG). A linha 0 da imagem é a de cima.
        private const val FRAGMENTO = """#version 300 es
precision highp float;
in vec2 uv;
out vec4 cor;
uniform sampler2D tY;
uniform sampler2D tU;
uniform sampler2D tV;
uniform vec2 tamY;
uniform vec2 tamC;
uniform int centrado;
uniform int hd;

float amostra(sampler2D t, ivec2 p, ivec2 lim) {
    return texelFetch(t, clamp(p, ivec2(0), lim), 0).r;
}

// Catmull-Rom (a = -0.5)
vec4 pesos(float f) {
    float f2 = f * f, f3 = f2 * f;
    return vec4(-0.5 * f3 + f2 - 0.5 * f,
                1.5 * f3 - 2.5 * f2 + 1.0,
                -1.5 * f3 + 2.0 * f2 + 0.5 * f,
                0.5 * f3 - 0.5 * f2);
}

void main() {
    // posição em pixels de luma, com o centro do pixel em .0
    float xl = uv.x * tamY.x - 0.5;
    float yl = (1.0 - uv.y) * tamY.y - 0.5;
    ivec2 lim = ivec2(tamY) - 1;
    vec2 b = floor(vec2(xl, yl));
    vec2 f = vec2(xl, yl) - b;
    vec4 wx = pesos(f.x), wy = pesos(f.y);
    float y = 0.0;
    for (int j = 0; j < 4; j++) {
        float linha = 0.0;
        for (int i = 0; i < 4; i++) {
            linha += wx[i] * amostra(tY, ivec2(b) + ivec2(i - 1, j - 1), lim);
        }
        y += wy[j] * linha;
    }
    // croma: na DV a amostra k fica no luma 4k (à esquerda), uma linha por linha de luma; no JPEG
    // no centro dos lumas que cobre
    vec2 razao = tamY / tamC;
    vec2 pc = centrado == 1 ? (vec2(xl, yl) + 0.5) / razao - 0.5 : vec2(xl, yl) / razao;
    ivec2 limc = ivec2(tamC) - 1;
    vec2 bc = floor(pc);
    vec2 fc = pc - bc;
    ivec2 c0 = ivec2(bc);
    float u = mix(mix(amostra(tU, c0, limc), amostra(tU, c0 + ivec2(1, 0), limc), fc.x),
                  mix(amostra(tU, c0 + ivec2(0, 1), limc), amostra(tU, c0 + ivec2(1, 1), limc), fc.x), fc.y);
    float v = mix(mix(amostra(tV, c0, limc), amostra(tV, c0 + ivec2(1, 0), limc), fc.x),
                  mix(amostra(tV, c0 + ivec2(0, 1), limc), amostra(tV, c0 + ivec2(1, 1), limc), fc.x), fc.y);
    // BT.601, faixa limitada
    float yy = 1.164383 * (y - 16.0 / 255.0);
    float cb = u - 128.0 / 255.0, cr = v - 128.0 / 255.0;
    // (as placas HDMI, 720 linhas ou mais: BT.709)
    vec3 rgb = hd == 1
        ? vec3(yy + 1.792741 * cr, yy - 0.213249 * cb - 0.532909 * cr, yy + 2.112402 * cb)
        : vec3(yy + 1.596027 * cr, yy - 0.391762 * cb - 0.812968 * cr, yy + 2.017232 * cb);
    cor = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
"""
    }
}
