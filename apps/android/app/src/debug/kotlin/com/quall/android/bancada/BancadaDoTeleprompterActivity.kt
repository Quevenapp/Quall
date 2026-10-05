// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.bancada

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.quall.android.ui.ControleActivity
import com.quall.android.ui.PrompterActivity
import com.quall.android.ui.PrompterComCameraActivity

/**
 * **A porta de bancada do teleprompter, sem toque** — só no APK de `debug`.
 *
 * `am start` numa Activity não exportada é recusado com `SecurityException` (`tools/aparelho.py`),
 * e as duas telas do teleprompter **não** são exportadas: um app qualquer do aparelho que abrisse o
 * prompter com um PIN escolhido por ele abriria a porta a um controle da LAN. Esta Activity, sim, é
 * exportada — e mora no conjunto `debug`, como a `SondaDeFatiasActivity`: some do `release` sem
 * `if` nenhum. Ela confere os extras e repassa para a tela de verdade, dentro do app.
 *
 * ```
 * # o prompter, hospedando com PIN e porta dados
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel teleprompter --es pin 424242 --ei porta 7979 [--ez sem_mdns true] [--es roteiro r.txt] \
 *     [--es orientacao paisagem] [--es posicao 0.5]
 *
 * # `--ez guardar false` em qualquer papel com `--es orientacao`: a orientação vale só nesta abertura
 * # (ou neste comando) e **não** é guardada — sem ele, aplica e guarda, como o botão. As provas usam
 * # `false`, para não deixar a escolha do Pessoa Exemplo mudada (01/10: o tablet ficou com o texto girado)
 *
 * # comandos para o prompter que já está de pé, sem recriar a tela (a sessão com o controle fica):
 * # a orientação vale como escolher no botão — aplica e guarda (automatica | retrato | paisagem |
 * # paisagem_invertida); o roteiro, rolar e a posição, como os toques
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel prompter_de_pe [--es orientacao paisagem_invertida] [--es roteiro r.txt] \
 *     [--ez rolar false] [--es posicao 0.5] [--ez fonte_automatica true] [--ez tabela_da_fonte true]
 *
 * # a tela "Teleprompter com câmera" (R5): o mesmo prompter, com a frontal transmitindo. A porta e
 * # o PIN são os do prompter; os do vídeo saem na tela (e no `MirrorBus`, no logcat `QuallMirror`)
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel prompter_com_camera --es pin 424242 --ei porta 7979 [--es orientacao retrato] \
 *     [--es lado_do_texto automatico|cima|baixo|esquerda|direita]
 *
 * # comandos para a tela R5 de pé, sem recriá-la: esconder/mostrar a prévia, o espelho da prévia, o
 * # lado do texto (como o ajuste: aplica e guarda), e tudo o que `prompter_de_pe` aceita
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel prompter_com_camera_de_pe [--ez previa false] [--ez espelho_da_previa true] \
 *     [--ez microfone true] [--ez gravar true|false] [--es lado_do_texto automatico]
 *
 * # o microfone do espelhamento de câmera COMUM (a tela inicial), direto ao serviço. LIGAR por aqui
 * # (e pelo `--ez microfone true` da R5) só com `microfone_de_prova` nas preferências de bancada: o
 * # tom entra no lugar do microfone e nada é pedido nem aberto. Sem ele, recusado — esta Activity é
 * # exportada, e o microfone real só abre pelo toque de quem está com o aparelho
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel microfone --ez ligar true
 *
 * # o espelhamento de câmera COMUM (a tela inicial), com a frontal ou a traseira: o serviço sobe
 * # com a câmera escolhida e a tela inicial abre (a prévia; com ela a câmera abre). A permissão de
 * # câmera tem de estar dada. `parar` para o espelhamento
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel camera_comum --es lente frontal|traseira|parar
 *
 * # gravar ou parar no espelhamento de câmera comum (o caminho do botão Gravar da tela inicial).
 * # GRAVAR por aqui só com `microfone_de_prova` (o modo bancada), como na tela R5; parar vale sempre
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel gravar_comum --ez gravar true|false
 *
 * # o controle, conectando num IP dado
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel controle --es endereco 192.168.57.8:7979 --es pin 424242 [--es roteiro r.txt] \
 *     [--ez segurar_para_rolar true] [--es escolha prompter|meu|nenhuma]
 *
 * # a pergunta do texto: a resposta pelo mesmo botão da caixa, quando ela abrir (com `roteiro` e
 * # sem `escolha`, "meu": a bancada que dá o roteiro não fica parada esperando um dedo)
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel controle_de_pe --es escolha prompter
 *
 * # "Segurar para rolar" no controle que já está de pé: o modo, e um dedo (0 se não disser) que
 * # encosta num botão (cima | baixo) ou fora deles (cabecalho), segura "Inverter botões" o tempo de
 * # um toque longo (inverter), levanta (soltar), escorrega para fora (fora) ou é cancelado
 * # (cancelar) — um MotionEvent com todos os dedos da bancada, entregue à janela: o mesmo caminho
 * # do toque
 * adb -s <serial> shell am start -n com.quall.android/.bancada.BancadaDoTeleprompterActivity \
 *     --es papel controle_de_pe [--ez segurar_para_rolar true] [--es segurar baixo] [--ei dedo 1]
 * ```
 *
 * `roteiro` é o **nome** de um arquivo em `/sdcard/Android/data/com.quall.android/files/` (o
 * contêiner externo do app: `adb push` o alcança, e o app o lê sem permissão nenhuma). O PIN só
 * vale se tiver seis dígitos; um erro de PIN troca o PIN de qualquer jeito (§2 do contrato) — leia
 * o novo pela tela (`exec-out screencap`) ou pelo `uiautomator dump`.
 */
class BancadaDoTeleprompterActivity : Activity() {

    /** A orientação pedida, e se ela é guardada (`--ez guardar false`: só nesta abertura). */
    private fun orientacao(destino: Intent) {
        val o = intent.getStringExtra("orientacao") ?: return
        destino.putExtra(PrompterActivity.EXTRA_ORIENTACAO, o)
        if (intent.hasExtra("guardar")) {
            destino.putExtra(PrompterActivity.EXTRA_GUARDAR_ORIENTACAO, intent.getBooleanExtra("guardar", true))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val papel = intent.getStringExtra("papel").orEmpty()
        val pin = intent.getStringExtra("pin")?.takeIf { it.length == 6 && it.all(Char::isDigit) }
        val roteiro = intent.getStringExtra("roteiro")?.takeIf { it.isNotBlank() }
        val destino = when (papel) {
            "teleprompter", "prompter" -> Intent(this, PrompterActivity::class.java).apply {
                pin?.let { putExtra(PrompterActivity.EXTRA_PIN, it) }
                val porta = intent.getIntExtra("porta", 0)
                if (porta in 1..65535) putExtra(PrompterActivity.EXTRA_PORTA, porta)
                if (intent.getBooleanExtra("sem_mdns", false)) putExtra(PrompterActivity.EXTRA_SEM_MDNS, true)
                roteiro?.let { putExtra(PrompterActivity.EXTRA_ROTEIRO, it) }
                orientacao(this)
                intent.getStringExtra("posicao")?.let { putExtra(PrompterActivity.EXTRA_POSICAO, it) }
                ajustesLocais(this)
            }
            // A tela R5: os mesmos extras do prompter, noutra classe.
            "prompter_com_camera", "r5" -> Intent(this, PrompterComCameraActivity::class.java).apply {
                pin?.let { putExtra(PrompterActivity.EXTRA_PIN, it) }
                val porta = intent.getIntExtra("porta", 0)
                if (porta in 1..65535) putExtra(PrompterActivity.EXTRA_PORTA, porta)
                if (intent.getBooleanExtra("sem_mdns", false)) putExtra(PrompterActivity.EXTRA_SEM_MDNS, true)
                roteiro?.let { putExtra(PrompterActivity.EXTRA_ROTEIRO, it) }
                orientacao(this)
                intent.getStringExtra("posicao")?.let { putExtra(PrompterActivity.EXTRA_POSICAO, it) }
                ajustesLocais(this)
                camera(this)
            }
            "prompter_com_camera_de_pe", "r5_de_pe" -> Intent(this, PrompterComCameraActivity::class.java).apply {
                orientacao(this)
                roteiro?.let { putExtra(PrompterActivity.EXTRA_ROTEIRO, it) }
                intent.getStringExtra("posicao")?.let { putExtra(PrompterActivity.EXTRA_POSICAO, it) }
                if (intent.hasExtra("rolar")) putExtra(PrompterActivity.EXTRA_ROLAR, intent.getBooleanExtra("rolar", false))
                ajustesLocais(this)
                camera(this)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            // Comandos para a tela do prompter que já está de pé: com SINGLE_TOP (mais o CLEAR_TOP
            // de baixo) chegam por `onNewIntent`, e a tela não é recriada — a sessão fica.
            "prompter_de_pe", "orientacao" -> Intent(this, PrompterActivity::class.java).apply {
                orientacao(this)
                roteiro?.let { putExtra(PrompterActivity.EXTRA_ROTEIRO, it) }
                intent.getStringExtra("posicao")?.let { putExtra(PrompterActivity.EXTRA_POSICAO, it) }
                if (intent.hasExtra("rolar")) putExtra(PrompterActivity.EXTRA_ROLAR, intent.getBooleanExtra("rolar", false))
                ajustesLocais(this)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            "controle", "controle_remoto" -> Intent(this, ControleActivity::class.java).apply {
                intent.getStringExtra("endereco")?.takeIf { it.isNotBlank() }?.let { putExtra(ControleActivity.EXTRA_ENDERECO, it) }
                pin?.let { putExtra(ControleActivity.EXTRA_PIN, it) }
                roteiro?.let { putExtra(ControleActivity.EXTRA_ROTEIRO, it) }
                segurar(this)
            }
            // "Segurar para rolar" na tela do controle que já está de pé (a sessão fica): o modo, e
            // os dedos pelo mesmo caminho do toque.
            "controle_de_pe" -> Intent(this, ControleActivity::class.java).apply {
                segurar(this)
                intent.getStringExtra("segurar")?.let { putExtra(ControleActivity.EXTRA_SEGURAR, it) }
                if (intent.hasExtra("dedo")) putExtra(ControleActivity.EXTRA_DEDO, intent.getIntExtra("dedo", 0))
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            // O espelhamento de câmera comum (§8.6): o serviço com a câmera escolhida, e a tela inicial
            // por cima (a prévia; é a tela olhando que abre a câmera na espera).
            "camera_comum" -> {
                val lente = intent.getStringExtra("lente").orEmpty()
                if (lente == "parar") {
                    com.quall.android.mirror.MirrorService.pedirParada(null)
                    Log.i("QuallMirror", "bancada: parar o espelhamento de câmera comum")
                    finish()
                    return
                }
                // A permissão de câmera é do toque (a revisão, menor 4): sem ela, a bancada não pede
                // nem sobe o serviço — quem concede é o Pessoa Exemplo, pela tela inicial.
                if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    Log.w("QuallMirror", "bancada: sem permissão de câmera — conceda pela tela inicial (Espelhar com a câmera) e repita")
                    finish()
                    return
                }
                val quer = if (lente == "traseira") android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK
                    else android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
                val opcao = com.quall.android.capture.CameraEnumerator.listar(this).firstOrNull { it.lensFacing == quer }
                if (opcao == null) {
                    Log.e("QuallMirror", "bancada: nenhuma câmera ${lente.ifBlank { "frontal" }} neste aparelho")
                    finish()
                    return
                }
                val servico = Intent(this, com.quall.android.mirror.MirrorService::class.java).apply {
                    putExtra(com.quall.android.mirror.MirrorService.EXTRA_SOURCE_KIND, com.quall.android.mirror.MirrorService.SOURCE_CAMERA)
                    putExtra(com.quall.android.mirror.MirrorService.EXTRA_CAMERA_ID, opcao.id)
                    putExtra(com.quall.android.mirror.MirrorService.EXTRA_CAMERA_LABEL, opcao.label)
                }
                Log.i("QuallMirror", "bancada: espelhamento de câmera comum com a ${opcao.label} (${opcao.id})")
                androidx.core.content.ContextCompat.startForegroundService(this, servico)
                Intent(this, com.quall.android.ui.MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            // Gravar ou parar no espelhamento comum, direto ao serviço (o caminho do botão).
            "gravar_comum" -> {
                val gravar = intent.getBooleanExtra("gravar", false)
                // Exportada: pôr a câmera a gravar para a Galeria por Intent só no modo bancada.
                if (gravar && !com.quall.android.core.Bancada.microfoneDeProva(this)) {
                    Log.w("QuallMirror", "bancada: gravar recusado — sem microfone_de_prova (o modo bancada), só o toque grava")
                    finish()
                    return
                }
                val ok = com.quall.android.mirror.MirrorService.pedirGravacao(gravar, daTelaR5 = false)
                Log.i("QuallMirror", "bancada: ${if (gravar) "gravar" else "parar a gravação"} no espelhamento comum pedido ao serviço" +
                    if (ok) "" else " — sem serviço vivo, nada feito")
                finish()
                return
            }
            // O botão do microfone do espelhamento comum, sem tela nova: direto ao serviço.
            "microfone" -> {
                val ligar = intent.getBooleanExtra("ligar", false)
                // **Esta Activity é exportada** (a revisão, M3): qualquer app do aparelho a alcança.
                // Ligar o microfone de verdade por aqui seria abrir a sala por Intent; só o tom passa.
                if (ligar && !com.quall.android.core.Bancada.microfoneDeProva(this)) {
                    Log.w("QuallMirror", "bancada: microfone recusado — sem microfone_de_prova, este caminho não liga o microfone real")
                    finish()
                    return
                }
                val ok = com.quall.android.mirror.MirrorService.pedirMicrofone(ligar)
                Log.i("QuallMirror", "bancada: microfone ${if (ligar) "ligado" else "desligado"} pedido ao serviço" +
                    if (ok) "" else " — sem serviço vivo, nada feito")
                finish()
                return
            }
            else -> null
        }
        if (destino == null) {
            Log.e("QuallTeleprompter", "bancada: papel \"$papel\" desconhecido — use teleprompter ou controle")
        } else {
            Log.i("QuallTeleprompter", "bancada: abrindo ${destino.component?.shortClassName} (papel $papel, " +
                "pin ${if (pin != null) "dado" else "sorteado/nenhum"})")
            // Uma tela nova por pedido: a bancada que repete o `am start` quer a sessão nova.
            startActivity(destino.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        finish()
    }

    /**
     * A prévia da tela R5 (`--ez previa false` esconde), o espelho dela (`--ez espelho_da_previa`), o
     * lado do texto (`--es lado_do_texto`) e o microfone (`--ez microfone true`, pelo mesmo caminho do
     * botão). **Ligar por aqui só com
     * `microfone_de_prova`**: esta Activity é exportada, e o microfone real só abre pelo toque.
     */
    private fun camera(destino: Intent) {
        // O "Lado do texto" (30/09): os retratos da R5 deitada não dependem do que ficou escolhido.
        intent.getStringExtra("lado_do_texto")?.let { destino.putExtra(PrompterComCameraActivity.EXTRA_LADO_DO_TEXTO, it) }
        if (intent.hasExtra("previa")) {
            destino.putExtra(PrompterComCameraActivity.EXTRA_PREVIA, intent.getBooleanExtra("previa", true))
        }
        if (intent.hasExtra("espelho_da_previa")) {
            destino.putExtra(PrompterComCameraActivity.EXTRA_ESPELHO_DA_PREVIA, intent.getBooleanExtra("espelho_da_previa", true))
        }
        // Gravar ou parar (R5, fase 3): o mesmo caminho do botão Gravar. O microfone entra na
        // gravação só se o botão dele já estiver ligado — e ligá-lo por aqui continua sendo só com o tom.
        // **Gravar por aqui só no modo bancada** (a revisão, menor): esta Activity é exportada, e um
        // app qualquer do aparelho não pode pôr a câmera a gravar para a Galeria. Parar vale sempre.
        if (intent.hasExtra("gravar")) {
            val gravar = intent.getBooleanExtra("gravar", false)
            if (!gravar || com.quall.android.core.Bancada.microfoneDeProva(this)) {
                destino.putExtra(PrompterComCameraActivity.EXTRA_GRAVAR, gravar)
            } else {
                Log.w("QuallTeleprompter", "bancada: gravar recusado — sem microfone_de_prova (o modo bancada), só o toque grava")
            }
        }
        if (intent.hasExtra("microfone")) {
            val ligar = intent.getBooleanExtra("microfone", false)
            // Exportada (a revisão, M3): ligar por Intent só com o tom; o microfone real é do toque.
            if (!ligar || com.quall.android.core.Bancada.microfoneDeProva(this)) {
                destino.putExtra(PrompterComCameraActivity.EXTRA_MICROFONE, ligar)
            } else {
                Log.w("QuallTeleprompter", "bancada: microfone recusado — sem microfone_de_prova, só o toque liga o microfone real")
            }
        }
    }

    /** "Fonte automática" (`--ez fonte_automatica true`) e a tabela de linhas da próxima conta (`--ez tabela_da_fonte true`). */
    private fun ajustesLocais(destino: Intent) {
        if (intent.hasExtra("fonte_automatica")) {
            destino.putExtra(PrompterActivity.EXTRA_FONTE_AUTOMATICA, intent.getBooleanExtra("fonte_automatica", false))
        }
        if (intent.getBooleanExtra("tabela_da_fonte", false)) destino.putExtra(PrompterActivity.EXTRA_TABELA_DA_FONTE, true)
    }

    /**
     * O modo "Segurar para rolar" do controle (`--ez segurar_para_rolar true|false`) e a resposta da
     * pergunta do texto (`--es escolha prompter|meu|nenhuma`).
     */
    private fun segurar(destino: Intent) {
        if (intent.hasExtra("segurar_para_rolar")) {
            destino.putExtra(ControleActivity.EXTRA_SEGURAR_PARA_ROLAR, intent.getBooleanExtra("segurar_para_rolar", false))
        }
        intent.getStringExtra("escolha")?.let { destino.putExtra(ControleActivity.EXTRA_ESCOLHA, it) }
    }
}
