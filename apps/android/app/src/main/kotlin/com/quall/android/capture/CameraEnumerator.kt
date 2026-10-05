package com.quall.android.capture

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.Idioma

/**
 * Enumera as câmeras físicas do aparelho pela Camera2 (`CameraManager.getCameraIdList()` +
 * `CameraCharacteristics`), para o seletor de origem de `docs/fluxo-de-uso.md`: "cada câmera
 * física do aparelho — traseira, frontal, e as demais em aparelhos que têm mais de duas. A lista
 * é enumerada do aparelho, não fixada em duas."
 *
 * ## Não há filtro, e houve — a história vale mais que a ausência
 *
 * Este arquivo teve, até 07/09/2026, um filtro que escondia todo id presente no
 * `physicalCameraIds` de outra câmera. A premissa era que a câmera **lógica** já representa as
 * lentes que ela funde, e a analogia era o `AVCaptureDevice.DiscoverySession` do iOS, que de fato
 * lista a mesma lente várias vezes se ninguém filtrar.
 *
 * **A analogia era o erro.** A Camera2 não tem esse problema: o `getCameraIdList()` já exclui o
 * que só pode ser aberto dentro de uma lógica. Filtrar por cima não removia repetição — removia
 * câmera boa.
 *
 * Medido no Galaxy S24, o primeiro aparelho de três-ou-mais lentes que esta bancada viu:
 *
 *     lista=[0, 1, 2, 3]  logicas=[0]  fisicas_de_logicas=[2, 5, 6, 7]
 *
 * As quatro lentes traseiras são 2, 5, 6 e 7, todas dentro da lógica `0`. Dessas, **só a `2` está
 * na lista pública** — e era exatamente ela que o filtro apagava. O usuário via uma traseira num
 * aparelho de quatro. As 5, 6 e 7 o sistema já esconde sozinho, e os dispositivos 20, 21, 23 e 24
 * também não aparecem: o trabalho estava feito.
 *
 * ## Correção do mesmo dia: as outras lentes SÃO alcançáveis, por zoom
 *
 * Esta seção dizia que "não havia como chegar à `2` por outro caminho: abrir a `0` entrega o que
 * o zoom escolher, não a lente que a pessoa escolheu". **A segunda metade é falsa**, e eu a
 * escrevi horas depois de ter errado do mesmo jeito em outros dois lugares: afirmar uma
 * impossibilidade a partir do que eu não tinha procurado.
 *
 * A lógica `0` do S24 declara `android.control.zoomRatioRange = [0.60, 10.00]`, e essa faixa
 * **atravessa as quatro lentes**: 0,6x é a grande-angular, 1x a principal, e o topo só existe
 * porque há 7,90 mm e 18,60 mm atrás dela. Do Android 11 em diante, com a chave presente, o `ZoomControl` do
 * CameraX usa `AndroidRZoomImpl`, que escreve `CaptureRequest.CONTROL_ZOOM_RATIO` — troca de
 * lente no HAL, e não recorte de `SCALER_CROP_REGION`. Então `camera.cameraControl.setZoomRatio()`
 * alcança o que a lista não mostra.
 *
 * As quatro traseiras do S24, medidas por `dumpsys media.camera` em 07/09/2026:
 *
 *     id 2 — 2,20 mm  (grande-angular)  **pública**, já é a "Traseira 2" desta lista
 *     id 5 — 6,30 mm  (principal)       escondida; é a mesma focal da lógica 0
 *     id 6 — 7,90 mm                    escondida
 *     id 7 — 18,60 mm (teleobjetiva)    escondida
 *
 * A `5` é a própria principal, e a `2` já está na lista. **Faltam duas**, não quatro. E o que a
 * interface da Samsung chama de "macro" é a grande-angular — macro não existe neste aparelho.
 *
 * ## O que pedir a física compraria, então
 *
 * **Determinismo, não alcance.** `OutputConfiguration.setPhysicalCameraId` (API 28, e o `minSdk`
 * daqui é 30) garante que o HAL não troque de lente sozinho no meio da transmissão. É uma garantia
 * boa e é outra coisa; quem quiser *chegar* à teleobjetiva chega por zoom, mais barato.
 *
 * E o caminho da física tem um preço que a lista não sugere: no CameraX o id físico é opção de
 * **sessão** e vale para todos os streams dela — não dá para pôr a prévia na lógica e o
 * codificador na física. Além disso a combinação lógico + físico **não é garantida** pela norma
 * (quem decide é o HAL), e o CameraX 1.4.2 nunca chama `isSessionConfigurationSupported`: a recusa
 * aparece quando a sessão falha, em execução.
 *
 * ## O relato
 *
 * `Log.i(TAG, "cameras: ...")` imprime lista, lógicas, físicas e visíveis a cada enumeração. Foi
 * ele que derrubou a **primeira** tentativa de conserto deste filtro, no mesmo dia: a regra
 * "nunca esconder uma lógica" parecia certa e não mudava nada neste aparelho, porque a `0` é a
 * única lógica e não está no conjunto físico de ninguém. Sem o relato eu teria contado como
 * consertado.
 */
object CameraEnumerator {
    private const val TAG = "QuallCameraEnum"

    data class CameraOption(
        val id: String,
        /** Pronto para exibir: "Traseira", "Frontal", "Traseira 2" quando houver mais de uma. */
        val label: String,
        val lensFacing: Int,
    )

    fun listar(context: Context): List<CameraOption> {
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cm == null) {
            Log.w(TAG, "CameraManager indisponível neste aparelho")
            return emptyList()
        }
        return try {
            val todos = cm.cameraIdList.toList()

            // ids que só existem como lente física de alguma câmera lógica: escondidos, porque a
            // lógica já representa o conjunto — mesmo raciocínio do DiscoverySession filtrado no
            // iOS. Em aparelho sem câmera lógica este conjunto sai vazio e nada é escondido.
            // **A lista do sistema é a lista, e não se filtra em cima dela.**
            //
            // Havia aqui um filtro que escondia todo id presente no `physicalCameraIds` de outra
            // câmera, pela premissa de que a lógica que o contém já o representa. **Medido no S24
            // em 07/09/2026, e a premissa é falsa:**
            //
            //     lista=[0, 1, 2, 3]  logicas=[0]  fisicas_de_logicas=[2, 5, 6, 7]
            //
            // As quatro lentes traseiras são 2, 5, 6 e 7, todas dentro da lógica `0`. Dessas, só
            // a `2` está na lista pública — e era exatamente ela que o filtro apagava. O usuário
            // via **uma** traseira num aparelho de quatro, e não havia como chegar às outras:
            // abrir a `0` dá o que o zoom escolher, não a lente que a pessoa escolheu.
            //
            // O argumento que fecha: o `getCameraIdList()` **já** exclui o que só existe dentro de
            // uma lógica. No mesmo S24 os dispositivos 5, 6 e 7 não estão na lista, e 20, 21, 23 e
            // 24 também não. O sistema fez o trabalho; refazê-lo por cima só tirava coisa boa.
            //
            // O caso que o filtro dizia cobrir — o iOS listando a mesma lente várias vezes — é do
            // `AVCaptureDevice.DiscoverySession`, que de fato inclui câmeras virtuais. A Camera2
            // não tem esse problema, e a analogia entre as duas APIs era o erro de origem.
            //
            // O relato fica: é ele que transforma "só aparece uma" numa lista de ids em vez de uma
            // conjectura, e foi ele que derrubou a primeira tentativa de conserto deste filtro.
            val fisicasDeLogicas = mutableSetOf<String>()
            val logicas = mutableSetOf<String>()
            for (id in todos) {
                val chars = runCatching { cm.getCameraCharacteristics(id) }.getOrNull() ?: continue
                fisicasDeLogicas += chars.physicalCameraIds
                val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                if (caps?.contains(
                        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA
                    ) == true
                ) {
                    logicas += id
                }
            }
            val visiveis = todos
            Log.i(TAG, "cameras: lista=$todos logicas=$logicas " +
                "fisicas_de_logicas=$fisicasDeLogicas visiveis=$visiveis")

            // O rótulo no idioma do app (`docs/traducao.md`, Android): quem lista pode ser um serviço.
            val textos = Idioma.contexto(context)
            val contagemPorLado = mutableMapOf<Int, Int>()
            visiveis
                .sortedBy { it.toIntOrNull() ?: Int.MAX_VALUE }
                .mapNotNull { id ->
                    val chars = runCatching { cm.getCameraCharacteristics(id) }.getOrNull()
                        ?: return@mapNotNull null
                    val facing = chars.get(CameraCharacteristics.LENS_FACING)
                        ?: CameraCharacteristics.LENS_FACING_EXTERNAL
                    val n = (contagemPorLado[facing] ?: 0) + 1
                    contagemPorLado[facing] = n
                    val base = textos.getString(when (facing) {
                        CameraCharacteristics.LENS_FACING_FRONT -> R.string.cam_frontal
                        CameraCharacteristics.LENS_FACING_BACK -> R.string.cam_traseira
                        else -> R.string.cam_externa
                    })
                    CameraOption(id, if (n > 1) "$base $n" else base, facing)
                }
        } catch (e: Exception) {
            // `CameraAccessException` e afins: aparelho sem câmera, ou serviço indisponível.
            // Lista vazia é resultado legítimo — a Activity mostra "nenhuma câmera encontrada".
            Log.w(TAG, "getCameraIdList falhou", e)
            emptyList()
        }
    }
}
