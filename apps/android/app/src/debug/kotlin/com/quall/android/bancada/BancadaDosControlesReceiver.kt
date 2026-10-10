package com.quall.android.bancada

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.quall.android.capture.AjusteDaCamera
import com.quall.android.capture.FilmadorDaCamera
import com.quall.android.core.QuallNative
import com.quall.android.mirror.MirrorService
import com.quall.android.receive.CameraRemotaBus

/**
 * **A porta de bancada dos controles de câmera do R9**, só no APK de `debug`: aplica um ajuste na câmera
 * **já aberta** pelo produto (a tela [C] ou a R5), sem toque na tela. É o braço do roteiro
 * `apps/android/tools/prova-r9-controles.py`.
 *
 * ## Por que um receptor, e não uma Activity
 *
 * A primeira versão era uma Activity translúcida, sem tela, que aplicava no `onCreate` e fechava, chamada
 * por `am start -W`. No A07 (Android 16) o `am start -W` voltava; no A10s (Android 11) ele **ficou
 * pendurado mais de 120 s** (a corrida da sessão principal em 01/10), com a `MainActivity` à frente e a
 * câmera aberta. O `-W` espera a Activity lançada se declarar desenhada, e uma que fecha no `onCreate`,
 * numa tarefa própria (`taskAffinity` vazio) e sem histórico, não desenha nunca; a causa exata do lado do
 * Android 11 não foi lida no código do sistema. Um `am broadcast` explícito não depende de janela, de
 * tarefa nem de foco: volta quando o `onReceive` termina ("Broadcast completed").
 *
 * Não abre câmera nenhuma: sem dono aberto, só registra que não havia. Roda na thread principal, como o
 * painel, e não espera nada.
 *
 * ```
 * R=com.quall.android/.bancada.BancadaDosControlesReceiver
 * # troca o registro inteiro da câmera aberta (o JSON do §2) e aplica
 * adb -s <serial> shell am broadcast -n $R --es ajuste '{"exposicao":"manual","iso":400,"obturadorNs":16666667}'
 * # "Restaurar automático"
 * adb ... am broadcast -n $R --ez restaurar true
 * # "Usar meus ajustes" (§2.3, 07/10: a câmera abre no automático e lembra o último manual)
 * adb ... am broadcast -n $R --ez usar_meus_ajustes true
 * # um toque no buffer da câmera (0..1, origem em cima à esquerda), simples ou longo
 * adb ... am broadcast -n $R --es toque 0.5,0.5 --ez longo true
 * # só a leitura de volta, as capacidades e o botão "Usar meus ajustes" (`meus_ajustes=sim|nao`), no diário
 * adb ... am broadcast -n $R --ez ler true
 * # a da R5, em vez da câmera comum
 * adb ... am broadcast -n $R --ez r5 true --es ajuste '...'
 * ```
 *
 * Tudo vai ao logcat com a etiqueta `QuallControles` e o prefixo `r9: bancada`; o fim de cada pedido é a
 * linha `r9: bancada: feito`.
 *
 * ## O controle remoto (R9b, `docs/controle-remoto-da-camera.md`)
 *
 * Os dois lados, sem toque: no filmador, a opção e o estado do `QuallCameraHost`; no receptor (com a tela
 * de Exibir conectada), os gestos do painel pelo `CameraRemotaBus` — o mesmo caminho dos toques.
 *
 * ```
 * # o filmador: liga ou desliga "Permitir controle remoto da câmera", e o estado do host no diário
 * adb ... am broadcast -n $R --ez permitir true
 * adb ... am broadcast -n $R --ez ler_filmador true
 * # o receptor: um pedido parcial, o restaurar, um toque no quadro decodificado, e o estado
 * adb ... am broadcast -n $R --es pedir '{"exposicao":"manual","iso":800}'
 * adb ... am broadcast -n $R --ez restaurar_remoto true
 * adb ... am broadcast -n $R --es tocar_remoto 0.5,0.5 --ez longo true
 * adb ... am broadcast -n $R --ez ler_receptor true
 * ```
 */
class BancadaDosControlesReceiver : BroadcastReceiver() {

    override fun onReceive(contexto: Context, intent: Intent) {
        try {
            atender(intent, contexto)
        } catch (t: Throwable) {
            Log.e(TAG, "r9: bancada: falhou: ${t.javaClass.simpleName}: ${t.message}", t)
        } finally {
            Log.i(TAG, "r9: bancada: feito")
        }
    }

    private fun atender(intent: Intent, contexto: Context) {
        // --- o controle remoto (R9b): não precisa de câmera aberta deste lado ---
        if (intent.hasExtra("permitir")) {
            FilmadorDaCamera.permitir(contexto, intent.getBooleanExtra("permitir", false))
        }
        if (intent.getBooleanExtra("ler_filmador", false)) {
            Log.i(TAG, "r9: bancada: filmador permitido=${FilmadorDaCamera.permitido(contexto)} estado ${FilmadorDaCamera.estadoJson()}")
        }
        intent.getStringExtra("pedir")?.let { json ->
            Log.i(TAG, "r9: bancada: pedido remoto $json -> ${QuallNative.Status.nome(CameraRemotaBus.pedir(json))}")
        }
        if (intent.getBooleanExtra("restaurar_remoto", false)) {
            Log.i(TAG, "r9: bancada: restaurar remoto -> ${QuallNative.Status.nome(CameraRemotaBus.restaurar())}")
        }
        intent.getStringExtra("tocar_remoto")?.split(",")?.mapNotNull { it.trim().toDoubleOrNull() }?.takeIf { it.size == 2 }?.let { (x, y) ->
            val longo = intent.getBooleanExtra("longo", false)
            Log.i(TAG, "r9: bancada: toque remoto ${if (longo) "longo" else "simples"} em $x,$y -> " +
                QuallNative.Status.nome(CameraRemotaBus.tocar(x, y, longo)))
        }
        if (intent.getBooleanExtra("ler_receptor", false)) {
            CameraRemotaBus.reler()
            Log.i(TAG, "r9: bancada: receptor ${CameraRemotaBus.estado}")
        }
        val local = listOf("ajuste", "restaurar", "usar_meus_ajustes", "toque", "ler").any { intent.hasExtra(it) }
        if (!local) return

        val r5 = intent.getBooleanExtra("r5", false)
        val c = MirrorService.controlesDaCamera(daTelaR5 = r5)
        if (c == null) {
            Log.w(TAG, "r9: bancada: nenhuma câmera ${if (r5) "da R5" else "comum"} aberta pelo dono; nada aplicado")
            return
        }
        intent.getStringExtra("ajuste")?.let { json ->
            val a = AjusteDaCamera.deJson(json)
            if (a == null) {
                Log.w(TAG, "r9: bancada: JSON inválido: $json")
            } else {
                Log.i(TAG, "r9: bancada: ajuste ${a.paraJson()}")
                c.substituir(a, "bancada")
            }
        }
        if (intent.getBooleanExtra("restaurar", false)) {
            Log.i(TAG, "r9: bancada: restaurar automático")
            c.restaurar()
        }
        if (intent.getBooleanExtra("usar_meus_ajustes", false)) {
            // O mesmo `usarMeusAjustes` do botão do painel; sem guardado, não faz nada (e o diário diz).
            Log.i(TAG, "r9: bancada: usar meus ajustes ${c.meusAjustes?.paraJson() ?: "nenhum"}")
            c.usarMeusAjustes()
        }
        intent.getStringExtra("toque")?.split(",")?.mapNotNull { it.trim().toDoubleOrNull() }?.takeIf { it.size == 2 }?.let { (x, y) ->
            val longo = intent.getBooleanExtra("longo", false)
            val mediu = c.tocar(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0), longo)
            Log.i(TAG, "r9: bancada: toque ${if (longo) "longo" else "simples"} em $x,$y mediu=$mediu")
        }
        if (intent.getBooleanExtra("ler", false)) {
            Log.i(TAG, "r9: bancada: capacidades ${c.resumoDasCapacidades()}")
            Log.i(TAG, "r9: bancada: leitura ${c.descreverLeitura()} | ${c.leitura().linha} | registro ${c.ajuste.paraJson()}")
            // O botão "Usar meus ajustes" é oferecido? A mesma regra que o painel usa para mostrá-lo.
            Log.i(TAG, "r9: bancada: meus_ajustes=${if (c.ofereceMeusAjustes) "sim" else "nao"} " +
                "guardado ${c.meusAjustes?.paraJson() ?: "nenhum"}")
        }
    }

    companion object {
        private const val TAG = "QuallControles"
    }
}
