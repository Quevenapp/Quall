package com.quall.android.capture

import android.os.Handler
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import androidx.camera.core.Preview

/**
 * O encontro entre a `PreviewView` da Activity e o *use case* `Preview` que vive no serviço.
 *
 * Mesma ideia do `MirrorBus`: os dois lados nascem e morrem em ordens diferentes — o serviço abre a
 * câmera quando o receptor conecta, a Activity aparece e some quando o usuário quiser — e nenhum
 * dos dois pode segurar referência do outro. Cada lado registra o que tem aqui, e este objeto liga
 * um ao outro quando os dois existirem.
 *
 * ## Por que não passa mais quadro por aqui
 *
 * Até 03/09 este arquivo era um barramento de `Bitmap`: um segundo *use case* `ImageAnalysis`
 * convertia `ImageProxy` na CPU e a Activity desenhava numa `ImageView` com matriz.
 * `docs/bancada.md` §8.17 mediu que isso **não** custava quadro ao codificador (1629/1634/1634
 * contra 1630/1620/1620, 0 pacote perdido, 0 IDR quebrado nos seis) — mas o preço de não custar
 * era desenhar a ~8 quadros/s, e a ~8 quadros/s a prévia **anda em trancos**. Comparada com o
 * DroidCam e com o iOS na mão do usuário, em trancos não serve.
 *
 * A raiz era de arquitetura: `Preview` tem **uma** superfície, e ela era a entrada do `MediaCodec`.
 * A troca foi inverter a ocupação — o codificador passou a receber a superfície por um
 * `VideoCapture` ([SaidaDeVideoParaCodificador], ver [CameraXSource.ligarCodificador]), e o `Preview` inteiro
 * ficou livre para a tela. Agora o quadro da prévia **não passa por este processo**: a câmera
 * escreve numa `Surface` de `SurfaceView` que o compositor do sistema desenha, que é a mesma classe
 * de caminho que faz a `AVCaptureVideoPreviewLayer` do iOS ser fluida. Não há `Bitmap`, não há
 * conversão, não há alocação por quadro — e o A/B do §8.17 continua sendo a régua do codificador.
 *
 * ## O que se ganhou de lifecycle
 *
 * `Preview.setSurfaceProvider(null)` chama `notifyInactive()`: o fluxo da tela **para de verdade**
 * quando ninguém está olhando. O `ImageAnalysis` de antes não conseguia isso — desfazer o use case
 * exigiria refazer o bind, e refazer o bind reinicia a captura que está no ar; o que ele podia
 * fazer era só não converter o quadro que continuava chegando.
 *
 * ## Quem chama o quê, e de qual thread
 *
 * Tudo aqui é **thread principal**, sem exceção: `Preview.setSurfaceProvider` faz
 * `Threads.checkMainThread()` na entrada e derruba com `IllegalStateException` de qualquer outra
 * (achado no A07, em bancada). [ligar] é chamada da Activity (`onStart`/`onStop`, que são main), e
 * [usarPreview] de dentro do `Handler(Looper.getMainLooper())` que [CameraXSource] já usa para
 * bindar e para desbindar.
 */
object PreviaDaCamera {

    /** Há sessão no ar? Escrito por [CameraXSource], lido aqui e pela tela. */
    @Volatile
    var transmitindo = false

    /**
     * Suspender a prévia quando o app volta com a sessão no ar? **Não, por padrão.**
     *
     * Ligada por `Bancada.suspenderPreviaNaVolta`, para provocar de propósito a enxurrada que o
     * braço antigo produzia. Ver [ligar] e [configurarSuspensao].
     *
     * *(Até 10/09/2026 este comentário citava a chave e a chave não existia: o campo era
     * `private set` e nada o escrevia. Um braço de bancada documentado e inalcançável é pior que
     * nenhum — quem lê acredita que pode medir.)*
     */
    @Volatile
    var suspenderNaVolta = false
        private set

    /**
     * Quem abre a sessão diz em que braço ela roda. Chamada pelo `MirrorService` antes de a câmera
     * abrir, com o valor de `Bancada.suspenderPreviaNaVolta`.
     */
    fun configurarSuspensao(suspender: Boolean) {
        if (suspender != suspenderNaVolta) {
            Log.i(TAG, "bancada: suspender a prévia na volta = $suspender")
        }
        suspenderNaVolta = suspender
    }

    /**
     * A prévia foi recusada porque a sessão está no ar — a tela lê isto para explicar ao usuário
     * em vez de mostrar um retângulo preto sem motivo.
     */
    @Volatile
    var previaSuspensa = false
        private set

    /** O provedor corrente chegou a ser aplicado ao use case? */
    @Volatile
    private var provedorAplicado = false
    private const val TAG = "QuallPrevia"

    private val principal = Handler(Looper.getMainLooper())

    /** Quem desenha. `null` quando não há Activity visível. Só tocado na thread principal. */
    private var provedorDaTela: Preview.SurfaceProvider? = null

    /**
     * `true` enquanto existir uma tela olhando — a mesma coisa que [provedorDaTela] não ser nulo,
     * mas legível de **qualquer** thread.
     *
     * Existe porque virou decisão de produto, e não só de desenho: com a prévia aparecendo na fase
     * ESPERANDO (antes de qualquer pareamento, como no iOS), a câmera fica aberta durante a espera
     * — e o Android, ao contrário do iOS, **não** interrompe a captura sozinho quando o app sai do
     * primeiro plano: o serviço em primeiro plano com tipo `camera` existe justamente para manter
     * o acesso. Sem um sinal como este, a câmera de um emissor que desistiu ficaria aberta até o
     * prazo de espera acabar. Ver `MirrorService.ajustarPreviaDeEspera`.
     */
    @Volatile
    var telaOlhando: Boolean = false
        private set

    /**
     * Quem quer saber quando [telaOlhando] muda. `@Volatile` porque é registrado da thread do
     * espelhamento e invocado da principal; a chamada é sempre **na principal**, dentro de [ligar].
     */
    @Volatile
    private var ouvinteDeTela: ((Boolean) -> Unit)? = null

    /**
     * Registra quem acompanha a presença da tela, ou `null` para parar de acompanhar.
     *
     * O ouvinte é chamado na thread principal e **não pode bloquear**: quem precisa abrir ou
     * fechar câmera a partir dele tem de despachar para uma thread de trabalho, porque
     * `CameraXSource.abrirComPrevia`/`parar` esperam por um `post` na própria thread principal —
     * fazer isso de dentro dela é travar o processo.
     */
    fun observarTela(ouvinte: ((Boolean) -> Unit)?) {
        ouvinteDeTela = ouvinte
    }

    /** O use case da sessão de captura corrente. `null` quando não há câmera aberta. */
    private var previewCorrente: Preview? = null

    /**
     * A tela registra o provedor da sua `PreviewView`, ou `null` ao sumir.
     *
     * **Chame uma vez por aparição da tela, não a cada quadro nem a cada evento do serviço.**
     * `setSurfaceProvider` com provedor não-nulo faz `updateConfigAndOutput` + `notifyReset()`, e
     * um `notifyReset` reconfigura a sessão de captura **enquanto o codificador está no ar**.
     * Alternar `visibility` da view é de graça; trocar provedor não é. Uma rotação de tela destrói
     * e recria a Activity, então ali um reset acontece de qualquer jeito — é risco conhecido e
     * ainda não medido em bancada.
     */
    fun ligar(provedor: Preview.SurfaceProvider?) {
        if (!naPrincipal("ligar")) return
        provedorDaTela = provedor
        val agora = provedor != null
        val mudou = agora != telaOlhando
        telaOlhando = agora
        // **Com a sessão no ar, um provedor NOVO não entra — quando [suspenderNaVolta] manda.**
        //
        // Nasce **desligada** desde 09/09/2026, e a decisão é do usuário, com os dois
        // comportamentos na mão. A guarda foi escrita para o caso do desbloqueio por rosto, que
        // toma a câmera; o preço dela é a tela preta a cada volta ao app, que é o gesto mais comum
        // que existe. E ela **não** evitava a quebra: o CameraX refaz a sessão de captura ao
        // reanexar o use case da prévia, com ou sem provedor novo — medido, `Resetting Capture
        // Session` em `docs/bancada.md` §8.65. Ou seja: custava a prévia e não comprava nada.
        if (agora && transmitindo && suspenderNaVolta && !provedorAplicado) {
            previaSuspensa = true
            Log.i(TAG, "prévia suspensa: a sessão está no ar e ligar o provedor agora " +
                "reestruturaria o caminho de vídeo")
        } else {
            aplicar()
        }
        // Só na transição: `onStart`/`onStop` chegam uma vez por aparição, mas um `ligar` repetido
        // com o mesmo estado não é motivo para abrir ou fechar câmera.
        if (mudou) ouvinteDeTela?.invoke(agora)
    }

    /**
     * [CameraXSource] registra o `Preview` que acabou de bindar, ou `null` quando a câmera fecha —
     * e também quando o bind com os dois *use cases* recua para só o codificador, caso em que não
     * há `Preview` bindado para alimentar tela nenhuma.
     */
    fun usarPreview(preview: Preview?) {
        if (!naPrincipal("usarPreview")) return
        // Solta a superfície do use case que está saindo: sem isto a `PreviewView` ficaria
        // congelada no último quadro, dizendo que o aparelho ainda filma.
        if (preview !== previewCorrente) runCatching { previewCorrente?.setSurfaceProvider(null) }
        previewCorrente = preview
        aplicar()
    }

    /**
     * A sessão que estava no ar terminou. Só limpa se [preview] ainda for o use case corrente —
     * sem essa comparação, um `parar()` chegando atrasado apagaria a prévia de uma sessão nova.
     */
    fun soltar(preview: Preview) {
        if (!naPrincipal("soltar")) return
        if (previewCorrente !== preview) return
        runCatching { preview.setSurfaceProvider(null) }
        previewCorrente = null
    }

    private fun aplicar() {
        val p = previewCorrente ?: return
        runCatching { p.setSurfaceProvider(provedorDaTela) }
            .onSuccess { provedorAplicado = provedorDaTela != null }
            .onFailure { Log.w(TAG, "provedor da prévia recusado", it) }
    }

    /**
     * A transmissão começou. A partir daqui, **ligar um provedor que ainda não estava ligado
     * derruba a transmissão** — e por isso deixa de ser feito.
     *
     * # A medida que produziu esta regra
     *
     * Em 09/09/2026, no S24: câmera transmitindo, app em segundo plano (tela apagada), e ao
     * voltar para o app a transmissão caía. O log mostrou o instante, e o mecanismo é o que o
     * cabeçalho de [CameraXSource] já declarava como risco conhecido e não medido:
     *
     * ```
     * 09:25:37.956  WindowManager: MainActivity ficando visível
     * 09:25:37.961  DeferrableSurface: surface closed ... SurfaceRequest$2
     *               Surface terminated ... SurfaceEdge$SettableSurface
     *               Surface created[total_surfaces=3] ... SurfaceEdge$SettableSurface
     * ```
     *
     * `SurfaceEdge$SettableSurface` é o **`SurfaceProcessorNode`** — a cópia em GL da biblioteca.
     * Dar um provedor ao `Preview` com o codificador no ar faz o CameraX inserir o nó e
     * **reconstruir o caminho do `VideoCapture` através dele**, descartando a superfície do
     * encoder. Ela não é substituída: nenhum `SurfaceRequest` novo chega, porque o CameraX deixou
     * de precisar de superfície nossa.
     *
     * Não era o desbloqueio por rosto: as duas expulsões de câmera daquele dia foram recuperadas
     * sozinhas em 731 e 780 ms. O gatilho é **voltar para o app**, que é muito mais comum.
     *
     * A escolha de produto, do usuário, em 09/09/2026: proteger a transmissão e avisar na tela.
     * Quem transmite a câmera para o OBS está olhando o OBS; a prévia serve para enquadrar
     * **antes**, e essa parte continua inteira.
     */
    fun transmissaoComecou() {
        transmitindo = true
    }

    /** A sessão saiu do ar: a prévia volta a poder ser ligada. */
    fun transmissaoTerminou() {
        transmitindo = false
        previaSuspensa = false
    }

    /**
     * Recusa a chamada fora da thread principal em vez de deixar o `checkMainThread()` do CameraX
     * derrubar o processo. Uma prévia que não liga é um defeito de tela; uma prévia que derruba o
     * processo leva junto a transmissão.
     */
    private fun naPrincipal(chamada: String): Boolean {
        if (Looper.myLooper() === principal.looper) return true
        Log.e(TAG, "$chamada fora da thread principal — ignorada")
        return false
    }
}
