package com.quall.android.bancada

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.core.content.ContextCompat
import com.quall.android.capture.dv.UsbDv
import com.quall.android.mirror.MirrorService

/**
 * **A porta de bancada da câmera DV, sem toque**, só no APK de `debug`, no molde da
 * `BancadaDoTeleprompterActivity`.
 *
 * O `MirrorService` não é exportado, e a tela do S24 fica atrás do bloqueio (que só o Pessoa Exemplo abre).
 * Esta Activity é exportada, aparece por cima do bloqueio (`showWhenLocked`, e com isso o app fica
 * em primeiro plano, que a FGS de câmera exige), sobe o serviço com a fonte DV e fecha.
 *
 * ```
 * # a DV de um arquivo de bancada (Bancada.cameraDvArquivo; a bandeira camera_dv ligada)
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDaCameraDvActivity --es fonte arquivo
 * # a filmadora plugada (a permissão USB já dada ao Quall)
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDaCameraDvActivity --es fonte usb
 * # parar
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDaCameraDvActivity --es fonte parar
 * # gravar (sem espelhar) do arquivo de bancada ou da filmadora, e parar a gravação
 * adb ... BancadaDaCameraDvActivity --es fonte gravar-arquivo | gravar-usb | parar-gravacao
 * ```
 *
 * O PIN sai na notificação ("Esperando um receptor — PIN …"): `dumpsys notification --noredact`.
 */
class BancadaDaCameraDvActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        val fonte = intent.getStringExtra("fonte").orEmpty()
        // A gravação (GravacaoDvService), pelos mesmos ids de fonte do espelhamento.
        when (fonte) {
            "gravar-arquivo", "gravar-usb" -> {
                val id = if (fonte == "gravar-arquivo") {
                    UsbDv.PREFIXO_DO_ARQUIVO + com.quall.android.core.Bancada.cameraDvArquivo(this)
                } else {
                    val usb = getSystemService(android.hardware.usb.UsbManager::class.java)
                    val dev = usb?.let { UsbDv.candidatos(it).firstOrNull() }
                    if (dev == null || !usb.hasPermission(dev)) {
                        Log.w(TAG, "bancada DV: sem filmadora plugada ou sem permissão USB (${dev?.deviceName})")
                        finish()
                        return
                    }
                    UsbDv.PREFIXO_DO_ID + dev.deviceName
                }
                Log.i(TAG, "bancada DV: $fonte")
                com.quall.android.capture.dv.GravacaoDvService.comecar(this, id)
                window.decorView.postDelayed({ finish() }, 1500)
                return
            }
            "parar-gravacao" -> {
                Log.i(TAG, "bancada DV: parar-gravacao")
                com.quall.android.capture.dv.GravacaoDvService.parar(this)
                finish()
                return
            }
        }
        val servico = Intent(this, MirrorService::class.java)
        when (fonte) {
            "parar" -> {
                // Direto ao serviço (`MirrorService.pedirParada`): um `startForegroundService` de
                // parar com o serviço morto derrubava o app por prazo.
                MirrorService.pedirParada(null)
                finish()
                return
            }
            "arquivo" -> {
                val caminho = com.quall.android.core.Bancada.cameraDvArquivo(this)
                servico.putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_CAMERA)
                servico.putExtra(MirrorService.EXTRA_CAMERA_ID, UsbDv.PREFIXO_DO_ARQUIVO + caminho)
                servico.putExtra(MirrorService.EXTRA_CAMERA_LABEL, "Filmadora DV (arquivo de bancada)")
            }
            "usb" -> {
                val usb = getSystemService(android.hardware.usb.UsbManager::class.java)
                val dev = usb?.let { UsbDv.candidatos(it).firstOrNull() }
                if (dev == null || !usb.hasPermission(dev)) {
                    Log.w(TAG, "bancada DV: sem filmadora plugada ou sem permissão USB (${dev?.deviceName})")
                    finish()
                    return
                }
                servico.putExtra(MirrorService.EXTRA_SOURCE_KIND, MirrorService.SOURCE_CAMERA)
                servico.putExtra(MirrorService.EXTRA_CAMERA_ID, UsbDv.PREFIXO_DO_ID + dev.deviceName)
                servico.putExtra(MirrorService.EXTRA_CAMERA_LABEL, UsbDv.rotulo(dev))
            }
            else -> {
                Log.w(TAG, "bancada DV: fonte '$fonte' desconhecida (arquivo | usb | parar)")
                finish()
                return
            }
        }
        Log.i(TAG, "bancada DV: $fonte")
        ContextCompat.startForegroundService(this, servico)
        // Fica de pé um instante: a FGS de câmera exige o app em primeiro plano quando sobe.
        window.decorView.postDelayed({ finish() }, 1500)
    }

    companion object { private const val TAG = "QuallDv" }
}
