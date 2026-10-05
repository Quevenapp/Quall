package com.quall.android.ui

import android.Manifest
import android.content.pm.PackageManager
import com.quall.android.core.LogSeguro as Log
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.quall.android.core.Bancada
import com.quall.android.core.Idioma
import com.quall.android.mirror.MicrofoneBus
import com.quall.android.mirror.MotivoDoMicrofone
import com.quall.android.mirror.MirrorService

/**
 * **O toque no botão do microfone da câmera**, igual na tela R5 e no espelhamento de câmera comum
 * (R5, fase 2; `docs/teleprompter-com-camera.md` §4.2 e §4.4).
 *
 * - **A permissão é pedida no primeiro toque**, nunca ao abrir a tela. Pedir, e não só ler
 *   (`docs/regras-de-frente.md`): é o pedido que cria a linha no painel de permissões.
 * - **Negada, o botão diz por quê**: negada uma vez (tocar de novo pede de novo), ou sem pedido
 *   possível (aí, nos Ajustes do aparelho). A frase vai para o [MicrofoneBus], que as telas desenham.
 * - Com a permissão, quem liga é o serviço ([MirrorService.pedirMicrofone]), que acrescenta o tipo
 *   `microphone` ao serviço em primeiro plano e abre o microfone quando houver receptor (ou, na
 *   tela R5, gravação).
 * - Na bancada, com `microfone_de_prova`, o tom entra no lugar do microfone e **nada é pedido**.
 *
 * Construída como propriedade da Activity: o `registerForActivityResult` tem de ser chamado antes
 * de ela chegar a `STARTED`.
 */
class BotaoDoMicrofone(private val activity: ComponentActivity) {

    private val pedir = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) ligarJa() else negada()
    }

    /** O toque: liga se está desligado, desliga se está ligado. */
    fun alternar() = aplicar(!MicrofoneBus.atual.ligado)

    /** Liga ou desliga (o toque, e os extras da bancada). */
    fun aplicar(ligar: Boolean) {
        if (!ligar) {
            MirrorService.pedirMicrofone(false)
            return
        }
        // Sem vídeo de câmera no ar não há botão a ligar: não se pede permissão à toa (a revisão).
        if (!MicrofoneBus.atual.disponivel) {
            MicrofoneBus.atualizar { it.copy(ligado = false).comMotivo(Idioma.textos(activity), MotivoDoMicrofone.SEM_VIDEO_NO_AR) }
            return
        }
        val concedida = ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (concedida || Bancada.microfoneDeProva(activity) || MicrofoneBus.atual.semMicrofone) {
            ligarJa()
        } else {
            Log.i(TAG, "microfone: pedindo RECORD_AUDIO (primeiro toque no botão)")
            pedir.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun ligarJa() {
        if (!MirrorService.pedirMicrofone(true)) {
            MicrofoneBus.atualizar {
                it.copy(ligado = false, capturando = false).comMotivo(Idioma.textos(activity), MotivoDoMicrofone.SEM_VIDEO_NO_AR)
            }
        }
    }

    private fun negada() {
        val podePedirDeNovo = ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.RECORD_AUDIO)
        // Sem a justificativa, o Android não diz se foi "não perguntar de novo" ou só o diálogo
        // fechado sem resposta (a revisão, menor): a frase cobre os dois, sem afirmar "bloqueada".
        val motivo = if (podePedirDeNovo) MotivoDoMicrofone.PERMISSAO_NEGADA else MotivoDoMicrofone.PERMISSAO_NOS_AJUSTES
        Log.i(TAG, "microfone: RECORD_AUDIO negada (pode pedir de novo: $podePedirDeNovo)")
        MicrofoneBus.atualizar { it.copy(ligado = false, capturando = false).comMotivo(Idioma.textos(activity), motivo) }
    }

    companion object {
        private const val TAG = "QuallMirror"
    }
}
