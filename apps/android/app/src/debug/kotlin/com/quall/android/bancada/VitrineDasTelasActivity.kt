// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
package com.quall.android.bancada

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import com.quall.android.R
import com.quall.android.capture.dv.GravacaoBus
import com.quall.android.capture.dv.PainelDoVideoUsb
import com.quall.android.dvd.ConversaoDvdBus
import com.quall.android.dvd.DiscoDvd
import com.quall.android.dvd.FaixaDeSom
import com.quall.android.dvd.Recusas
import com.quall.android.dvd.TituloDoDvd
import com.quall.android.dvd.TransmissaoDvdBus
import com.quall.android.mirror.EstadoDoMicrofone
import com.quall.android.mirror.GravacaoDaTelaBus
import com.quall.android.mirror.MicrofoneBus
import com.quall.android.mirror.MirrorBus
import com.quall.android.receive.ReceptorBus
import com.quall.android.teleprompter.Replicas
import com.quall.android.ui.AvisoDaTela
import com.quall.android.ui.ControleActivity
import com.quall.android.ui.ConversaoDvdActivity
import com.quall.android.ui.EstadoDasTelas
import com.quall.android.ui.MainActivity
import com.quall.android.ui.ReceptorActivity
import com.quall.android.ui.VideoUsbActivity
import com.quall.android.ui.VitrineDaPlaca
import com.quall.android.ui.VitrineDoDvd

/**
 * **A vitrine das telas, sem transmitir** — só no APK de `debug`. Põe nos barramentos de estado
 * (`MirrorBus`, `MicrofoneBus`, `GravacaoDaTelaBus`, `ReceptorBus`) um estado **de mentira** e abre a tela
 * que o desenha, para `apps/android/tools/retratos-das-telas.py` fotografar cada estado do "Estúdio de
 * bolso" (`docs/telas-estudio.md` §9) sem serviço, sem câmera, sem microfone e sem rede: nenhuma sessão
 * sobe, e nada vai ao ar.
 *
 * Recusa quando há sessão de verdade de pé: o `MirrorBus` ou o `ReceptorBus` fora do repouso sem ter sido
 * ela, ou uma tela do teleprompter com a réplica em uso (o `limpar()` e o `CLEAR_TOP` a derrubariam). O PIN e o
 * endereço são inventados; `limpar` devolve os barramentos ao repouso. Os pares da espera ("com pares" e
 * "sem pares") vêm de `EstadoDasTelas.paresDaVitrine`, sem mexer no pareamento de verdade.
 *
 * ```
 * adb -s <serial> shell am start -n com.quall.android/.bancada.VitrineDasTelasActivity --es tela <nome>
 * ```
 *
 * `<nome>`: `limpar`, `inicio`, `inicio_pares`, `espera_tela`, `espera_tela_pares`, `noar_tela`,
 * `espera_camera` (os primeiros 8 s são o ABRINDO), `espera_camera_pares`, `noar_camera`,
 * `noar_camera_gravando`, `noar_camera_mic_ligado`, `espera_placa`, `exibindo`, `exibindo_numeros`,
 * `exibir`, `controle`.
 *
 * **A placa e o DVD** (30/09, a rodada do R16 dessas telas): um aparelho de vídeo USB e um leitor de DVD de
 * mentira ([EstadoDasTelas.placaDaVitrine], [EstadoDasTelas.dvdDaVitrine]), mais a gravação, a conversão e a
 * transmissão nos barramentos de sempre. Nada é aberto no USB, nenhum serviço sobe, e a prévia mostra barras
 * de cor. Funciona também no A10s (32 bits), que não lê a placa nem o DVD de verdade.
 *
 * - placa: `placa_esperando` (sem aparelho), `placa_imagem` (a EasyCap com imagem), `placa_hdmi` (uma HDMI,
 *   NV12 1080p a 30 tirados de 60), `placa_hdmi_opcoes` (a mesma, com a engrenagem aberta nas opções),
 *   `placa_erro` (a imagem que parou: a câmera desconectada), `placa_sem_permissao` (o USB negado),
 *   `placa_transmitindo` (esperando o receptor: o PIN e o endereço), `placa_no_ar` (enviando e gravando),
 *   `filmadora_gravando` (a GS500 gravando a fita: o Transmitir apagado com a frase da DV);
 * - DVD: `dvd_sem_leitor`, `dvd_disco` (o disco lido, os títulos para escolher, duas faixas de som),
 *   `dvd_convertendo` (42 %), `dvd_pronto` (salvo na Galeria), `dvd_erro` (o disco com proteção),
 *   `dvd_transmitindo` (esperando o receptor: o PIN), `dvd_no_ar` (enviando e gravando).
 */
class VitrineDasTelasActivity : Activity() {

    companion object {
        private const val TAG = "QuallVitrine"

        /** O estado nos barramentos é desta vitrine (e não de uma sessão de verdade). */
        @Volatile
        private var fingindo = false

        private const val PIN = "482719"
        private val ENDERECOS = listOf("192.168.57.11:7877", "192.168.60.129:7877")
        private const val PAR = "MacBook do Pessoa Exemplo"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val tela = intent?.getStringExtra("tela").orEmpty()
        Log.i(TAG, "vitrine: $tela")
        // O `limpar()` e o `CLEAR_TOP` derrubariam uma sessão de verdade: com qualquer uma de pé (espelhar,
        // exibir, ou uma tela do teleprompter com a réplica em uso), a vitrine não faz nada.
        val espelhando = MirrorBus.atual.fase != MirrorBus.Fase.PARADO && MirrorBus.atual.fase != MirrorBus.Fase.ERRO
        val exibindo = ReceptorBus.atual.fase.let {
            it == ReceptorBus.Fase.PROCURANDO || it == ReceptorBus.Fase.CONECTANDO || it == ReceptorBus.Fase.EXIBINDO
        }
        // A gravação da placa, a conversão e a transmissão do DVD de verdade também (o `limpar()` as apagaria
        // da tela, e o `CLEAR_TOP` derrubaria a tela delas).
        val capturando = GravacaoBus.gravando || ConversaoDvdBus.convertendo || TransmissaoDvdBus.transmitindo
        if (((espelhando || exibindo || capturando) && !fingindo) || Replicas.emUso) {
            Log.w(TAG, "vitrine: RECUSADA — há uma sessão de verdade de pé (espelhar=${MirrorBus.atual.fase}, " +
                "exibir=${ReceptorBus.atual.fase}, teleprompter=${Replicas.emUso}, placa/DVD=$capturando)")
            finish()
            return
        }
        when (tela) {
            "limpar" -> limpar()
            "inicio" -> { limpar(); abrir(MainActivity::class.java) }
            "inicio_pares" -> { limpar(); EstadoDasTelas.paresDaVitrine = true; abrir(MainActivity::class.java) }
            "espera_tela" -> espera(daTela = true, pares = false)
            "espera_tela_pares" -> espera(daTela = true, pares = true)
            "noar_tela" -> noAr(daTela = true)
            "espera_camera" -> espera(daTela = false, pares = false)
            "espera_camera_pares" -> espera(daTela = false, pares = true)
            "noar_camera" -> noAr(daTela = false)
            "noar_camera_mic_ligado" -> noAr(daTela = false, microfone = true)
            "noar_camera_gravando" -> noAr(daTela = false, gravando = true)
            "espera_placa" -> espera(daTela = false, pares = false, placa = true)
            "exibindo" -> exibindo(numeros = false)
            "exibindo_numeros" -> exibindo(numeros = true)
            "exibir" -> { limpar(); abrir(ReceptorActivity::class.java) }
            "controle" -> { limpar(); abrir(ControleActivity::class.java) }
            "placa_esperando", "placa_imagem", "placa_hdmi", "placa_hdmi_opcoes", "placa_erro", "placa_sem_permissao",
            "placa_transmitindo", "placa_no_ar", "filmadora_gravando" -> placa(tela)
            "dvd_sem_leitor", "dvd_disco", "dvd_convertendo", "dvd_pronto", "dvd_erro", "dvd_transmitindo", "dvd_no_ar" -> dvd(tela)
            else -> Log.w(TAG, "vitrine: tela desconhecida \"$tela\"")
        }
        finish()
    }

    private fun limpar() {
        fingindo = false
        EstadoDasTelas.paresDaVitrine = null
        EstadoDasTelas.diagnosticoLigado = false
        EstadoDasTelas.placaDaVitrine = null
        EstadoDasTelas.dvdDaVitrine = null
        MirrorBus.publicar(MirrorBus.Estado())
        MicrofoneBus.atualizar { EstadoDoMicrofone() }
        GravacaoDaTelaBus.atualizar { GravacaoDaTelaBus.Estado() }
        ReceptorBus.publicar(ReceptorBus.Estado())
        GravacaoBus.publicar(GravacaoBus.Estado())
        ConversaoDvdBus.publicar(ConversaoDvdBus.Estado())
        TransmissaoDvdBus.publicar(TransmissaoDvdBus.Estado())
    }

    private fun abrir(tela: Class<*>) {
        startActivity(Intent(this, tela).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
    }

    /** O nome da câmera sem artigo (`MirrorBus.Estado.nomeDaCamera`); a tela decide por `daTela`. */
    private fun nomeDaCamera(daTela: Boolean, placa: Boolean) = when {
        daTela -> ""
        placa -> getString(R.string.placa_rotulo_placa, "USB2.0 HD UVC")
        else -> getString(R.string.cam_traseira)
    }

    private fun rotulo(daTela: Boolean, placa: Boolean) =
        if (daTela) getString(R.string.esp_fonte_tela) else getString(R.string.esp_fonte_camera, nomeDaCamera(false, placa))

    private fun camera(placa: Boolean) {
        MicrofoneBus.atualizar { EstadoDoMicrofone(disponivel = true, daPlaca = placa) }
        GravacaoDaTelaBus.atualizar { GravacaoDaTelaBus.Estado(disponivel = !placa, daCameraComum = !placa, espacoLivre = 23_400_000_000) }
    }

    private fun espera(daTela: Boolean, pares: Boolean, placa: Boolean = false) {
        limpar()
        fingindo = true
        EstadoDasTelas.paresDaVitrine = pares
        if (!daTela) camera(placa)
        MirrorBus.publicar(MirrorBus.Estado(
            fase = MirrorBus.Fase.ESPERANDO, pin = PIN, enderecos = ENDERECOS,
            fonteRotulo = rotulo(daTela, placa), daTela = daTela, nomeDaCamera = nomeDaCamera(daTela, placa),
            videoUsb = placa, daPlaca = placa, tentativa = 1, fpsPedido = 30,
            mensagem = getString(R.string.esp_anunciando, "Galaxy A07", "_quall._tcp"), mensagemEhAnuncio = true, anunciando = true,
        ))
        abrir(MainActivity::class.java)
    }

    private fun noAr(daTela: Boolean, microfone: Boolean = false, gravando: Boolean = false) {
        limpar()
        fingindo = true
        EstadoDasTelas.paresDaVitrine = false
        if (!daTela) {
            camera(placa = false)
            if (microfone) MicrofoneBus.atualizar { it.copy(ligado = true, capturando = true) }
            if (gravando) GravacaoDaTelaBus.atualizar {
                it.copy(fase = GravacaoDaTelaBus.Fase.GRAVANDO, desdeMs = SystemClock.elapsedRealtime() - 83_000)
            }
        }
        MirrorBus.publicar(MirrorBus.Estado(
            fase = MirrorBus.Fase.ESPELHANDO, pin = PIN, enderecos = ENDERECOS, fonteRotulo = rotulo(daTela, false),
            daTela = daTela, nomeDaCamera = nomeDaCamera(daTela, false),
            par = PAR, fpsPedido = 30, pedido = "1920x1080 a 30 fps", entregue = "1920x1080 a 30 fps", entregueCurto = "1920×1080 · 30 fps",
        ))
        abrir(MainActivity::class.java)
    }

    private fun exibindo(numeros: Boolean) {
        limpar()
        fingindo = true
        EstadoDasTelas.diagnosticoLigado = numeros
        ReceptorBus.publicar(ReceptorBus.Estado(
            fase = ReceptorBus.Fase.EXIBINDO, par = PAR, endpoint = "192.168.57.3:7877", rotuloDaTrack = "tela",
            largura = 1920, altura = 1080, perfil = "high", faixaDeCor = "limitada", fpsObtido = 30.0,
        ))
        abrir(ReceptorActivity::class.java)
    }

    // --- a placa de captura e a filmadora (30/09) ---------------------------------------------------

    private val easycap get() = getString(R.string.placa_rotulo_placa, "USB2.0 PC CAMERA")

    private fun placa(tela: String) {
        limpar()
        fingindo = true
        val sd = VitrineDaPlaca.Opcoes(formato = "MJPEG", largura = 640, altura = 480, quadros = 30, quadrosDaPlaca = 30, chegando = 30.0)
        val hdmi = VitrineDaPlaca.Opcoes(formato = "NV12", largura = 1920, altura = 1080, quadros = 30, quadrosDaPlaca = 60, chegando = 30.0)
        val comImagem = VitrineDaPlaca(rotulo = easycap, tipo = PainelDoVideoUsb.Tipo.PLACA, pronto = true, opcoes = sd)
        EstadoDasTelas.placaDaVitrine = when (tela) {
            "placa_esperando" -> VitrineDaPlaca(
                rotulo = getString(R.string.placa_nenhum_aparelho_rotulo), tipo = PainelDoVideoUsb.Tipo.DESCONHECIDO, pronto = false,
                mensagem = getString(R.string.placa_nenhum_aparelho),
                tipoDaMensagem = AvisoDaTela.Tipo.AMBAR, acao = getString(R.string.placa_procurar_de_novo),
            )
            "placa_hdmi", "placa_hdmi_opcoes" -> VitrineDaPlaca(
                rotulo = getString(R.string.placa_rotulo_placa, "ezcap GAMEDOCK ULTRA"), tipo = PainelDoVideoUsb.Tipo.PLACA, pronto = true,
                opcoes = hdmi, abrirAjustes = tela == "placa_hdmi_opcoes",
            )
            "placa_erro" -> comImagem.copy(falha = getString(R.string.placa_camera_desconectada))
            "placa_sem_permissao" -> VitrineDaPlaca(
                rotulo = easycap, tipo = PainelDoVideoUsb.Tipo.PLACA, pronto = false,
                mensagem = getString(R.string.placa_sem_permissao_usb, getString(R.string.in_a_placa_de_captura)),
                tipoDaMensagem = AvisoDaTela.Tipo.VERMELHO, acao = getString(R.string.placa_permitir_usb),
            )
            "filmadora_gravando" -> VitrineDaPlaca(rotulo = getString(R.string.placa_rotulo_filmadora, "DVC"), tipo = PainelDoVideoUsb.Tipo.FILMADORA_DV, pronto = true)
            else -> comImagem
        }
        val dv = tela == "filmadora_gravando"
        if (tela == "placa_transmitindo" || tela == "placa_no_ar") {
            val noAr = tela == "placa_no_ar"
            MicrofoneBus.atualizar {
                EstadoDoMicrofone(disponivel = true, ligado = true, capturando = noAr, daPlaca = true, semMicrofone = true)
            }
            MirrorBus.publicar(MirrorBus.Estado(
                fase = if (noAr) MirrorBus.Fase.ESPELHANDO else MirrorBus.Fase.ESPERANDO, pin = PIN, enderecos = ENDERECOS,
                fonteRotulo = getString(R.string.esp_fonte_camera, easycap), daTela = false, nomeDaCamera = easycap, videoUsb = true, daPlaca = true, par = if (noAr) PAR else "",
                tentativa = 1, fpsPedido = 30,
            ))
        }
        if (tela == "placa_no_ar" || dv) {
            GravacaoBus.publicar(GravacaoBus.Estado(
                fase = GravacaoBus.Fase.GRAVANDO, nome = if (dv) "Quall-DV-20260930-2214.mp4" else "Quall-Placa-20260930-2214.mp4",
                bytes = 48_300_000, espacoLivre = 23_400_000_000, decorridoMs = 83_000, daPlaca = !dv,
            ))
        }
        abrir(VideoUsbActivity::class.java)
    }

    // --- o DVD (30/09) --------------------------------------------------------------------------------

    private val leitorDvd get() = getString(R.string.dvd_leitor_nome, "hp HLDS DVDRW GTB0N")

    private fun discoDeExemplo(): DiscoDvd {
        fun titulo(n: Int, minutos: Long, largo: Boolean, faixas: List<FaixaDeSom>, recusa: String? = null) = TituloDoDvd(
            numero = n, vts = n, angulos = if (recusa != null) 2 else 1, capitulos = 6, duracao90k = minutos * 60 * 90_000,
            trechos = emptyList(), pal = false, aspecto169 = largo, largura = 720, altura = 480, faixas = faixas, recusa = recusa,
        )
        val pt = FaixaDeSom(0x80, "AC-3", 2, 48_000, "pt")
        val en = FaixaDeSom(0x81, "AC-3", 6, 48_000, "en")
        return DiscoDvd(
            volume = "FERIAS_2009", sistema = "NTSC",
            titulos = listOf(
                titulo(1, 92, true, listOf(pt, en)),
                titulo(2, 12, false, listOf(pt)),
                titulo(3, 3, false, listOf(pt)),
                titulo(4, 7, true, listOf(pt), recusa = Recusas.ANGULOS),
            ),
            avisos = emptyList(),
        )
    }

    private fun dvd(tela: String) {
        limpar()
        fingindo = true
        val disco = discoDeExemplo()
        EstadoDasTelas.dvdDaVitrine = when (tela) {
            "dvd_sem_leitor" -> VitrineDoDvd(com.quall.android.dvd.FrasesDoDvd.SEM_LEITOR.em(com.quall.android.core.Idioma.textos(this)), AvisoDaTela.Tipo.AMBAR, getString(R.string.dvd_procurar_de_novo))
            "dvd_erro" -> VitrineDoDvd(com.quall.android.dvd.FrasesDoDvd.PROTEGIDO.em(com.quall.android.core.Idioma.textos(this)), AvisoDaTela.Tipo.VERMELHO, getString(R.string.dvd_tentar_de_novo))
            "dvd_pronto" -> VitrineDoDvd(getString(R.string.dvd_conversao_terminou), AvisoDaTela.Tipo.INFO, getString(R.string.dvd_converter_outro))
            else -> VitrineDoDvd(leitorDvd, null, getString(R.string.dvd_ler_de_novo), disco = disco)
        }
        val nome = "Quall-DVD-FERIAS_2009-1.mp4"
        when (tela) {
            "dvd_convertendo" -> ConversaoDvdBus.publicar(ConversaoDvdBus.Estado(
                fase = ConversaoDvdBus.Fase.CONVERTENDO, nome = nome, setoresLidos = 420, setoresDoTitulo = 1000,
                tempo90k = 39L * 60 * 90_000, duracao90k = 92L * 60 * 90_000, restanteMs = 18L * 60_000,
            ))
            "dvd_pronto" -> ConversaoDvdBus.publicar(ConversaoDvdBus.Estado(
                fase = ConversaoDvdBus.Fase.PARADA, nome = nome, mensagem = getString(R.string.dvd_salvo_na_galeria, nome), publicado = true,
            ))
            "dvd_transmitindo", "dvd_no_ar" -> {
                val noAr = tela == "dvd_no_ar"
                TransmissaoDvdBus.publicar(TransmissaoDvdBus.Estado(
                    fase = TransmissaoDvdBus.Fase.NO_AR, volume = "FERIAS_2009", titulo = 1,
                    posicao90k = if (noAr) 754L * 90_000 else 0, duracao90k = 92L * 60 * 90_000, semReceptor = !noAr,
                    som = "português AC-3", gravando = noAr, gravacao90k = 83L * 90_000, gravacaoBytes = 31_200_000,
                ))
                MirrorBus.publicar(MirrorBus.Estado(
                    fase = if (noAr) MirrorBus.Fase.ESPELHANDO else MirrorBus.Fase.ESPERANDO, pin = PIN, enderecos = ENDERECOS,
                    fonteRotulo = getString(R.string.esp_fonte_dvd), daTela = false, par = if (noAr) PAR else "", tentativa = 1, fpsPedido = 30, doDvd = true,
                ))
            }
        }
        abrir(ConversaoDvdActivity::class.java)
    }
}
