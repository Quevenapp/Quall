package com.quall.android.capture

import android.annotation.SuppressLint
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.impl.ConstantObservable
import androidx.camera.core.impl.Observable
import androidx.camera.video.MediaSpec
import androidx.camera.video.VideoOutput

/**
 * O `VideoOutput` que entrega o pedido de superfície da câmera para quem alimenta o `MediaCodec`.
 *
 * ## Por que existe um `VideoOutput` nosso, e não o `Recorder` do CameraX
 *
 * O único `VideoOutput` pronto que o CameraX entrega é o `Recorder`, e ele traz o **próprio**
 * codificador e o próprio muxer, escrevendo em arquivo ou descritor. Não há API nele para ceder a
 * superfície de entrada de um `MediaCodec` de fora. Usá-lo seria jogar fora
 * [H264SurfaceEncoder], [AnnexB] e o [FrameSink] — e com eles o controle de GOP, de taxa e de IDR,
 * que é o M6 inteiro. O que se quer do `VideoCapture` é uma coisa só: **ser o use case que ocupa a
 * superfície da câmera**, para que o `Preview` fique livre para a tela.
 *
 * ## O que o `VideoCapture` faz com esta classe
 *
 * Só [onSurfaceRequested] é chamada em regime: o `VideoCapture` monta o pipeline e entrega um
 * [SurfaceRequest] com a mesma API pública (`getResolution()`, `provideSurface()`) que o do
 * `Preview` entregava antes — é por isso que [H264CameraEncoder] não mudou uma linha.
 *
 * A sobrecarga `onSurfaceRequested(SurfaceRequest, Timebase)` — que é a que o `VideoCapture`
 * realmente invoca — é `default` na interface e o corpo dela delega para a de um argumento só.
 * Implementar a de um argumento basta, e é a única função da interface que **não** é
 * `@RestrictTo`.
 */
class SaidaDeVideoParaCodificador(
    private val aoReceberPedido: (SurfaceRequest) -> Unit,
) : VideoOutput {

    override fun onSurfaceRequested(request: SurfaceRequest) {
        aoReceberPedido(request)
    }

    /**
     * Sem este override, `bindToLifecycle` estoura com
     * `IllegalArgumentException: Unable to update target resolution by null MediaSpec.`
     *
     * Não é precaução: é o bytecode de 1.4.2. `VideoCapture.onMergeConfig` chama
     * `updateCustomOrderedResolutionsByQuality` **sem guarda nenhuma**, e essa função abre com um
     * `Preconditions.checkArgument(getMediaSpec() != null, ...)`. O `getMediaSpec()` privado do
     * `VideoCapture` lê o observable desta interface — e o `default` da interface é literalmente
     * `ConstantObservable.withValue(null)`. Ou seja: um `VideoOutput` mínimo, que só implemente a
     * função abstrata, **não binda**.
     *
     * `MediaSpec.builder()` é API pública e já preenche tudo sozinha (`outputFormat` = -1,
     * `AudioSpec` e `VideoSpec` padrão), então o conserto é esta linha.
     *
     * ## A dívida de API restrita mora aqui, e só aqui
     *
     * `VideoOutput.getMediaSpec()` é `@RestrictTo(LIBRARY)` e o tipo de retorno
     * `androidx.camera.core.impl.Observable` está num pacote `@RestrictTo(LIBRARY_GROUP)`. Não é
     * escolha: sem o override não há bind. O `@SuppressLint` está nesta função para que a dívida
     * seja uma linha auditável, e não algo espalhado — e para que uma subida de versão do CameraX
     * que mude esse contrato quebre em um lugar só.
     *
     * ## O que o padrão de [getMediaCapabilities] faz, e por que é benigno
     *
     * Não sobrescrevemos `getMediaCapabilities`, então ele devolve `VideoCapabilities.EMPTY`, cujo
     * `getSupportedQualities` é lista vazia. Logo depois do `checkArgument` acima,
     * `updateCustomOrderedResolutionsByQuality` vê a lista vazia, loga
     * `Can't find any supported quality on the device.` e **retorna cedo**. Isso é exatamente o que
     * se quer: nenhuma resolução ordenada por qualidade de gravação é imposta, e quem decide o
     * tamanho é o `ResolutionSelector` explícito que [CameraXSource] passa aos dois use cases.
     * Esse log no logcat é esperado — não é sintoma.
     */
    @SuppressLint("RestrictedApi")
    override fun getMediaSpec(): Observable<MediaSpec> =
        ConstantObservable.withValue(MediaSpec.builder().build())
}
