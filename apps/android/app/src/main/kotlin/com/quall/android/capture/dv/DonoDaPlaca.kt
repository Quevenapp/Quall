package com.quall.android.capture.dv

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.quall.android.core.LogSeguro as Log
import com.quall.android.R
import com.quall.android.core.Idioma
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * **O dono único do vídeo USB** (a placa de captura e a filmadora DV; `docs/placa-de-captura-usb.md`
 * §11). O aparelho USB só abre uma vez: a mesma [FonteDv] serve à prévia parada da tela
 * ([Uso.PREVIA]), à rede (o `MirrorService`, [Uso.REDE]) e à gravação (o `GravacaoDvService`,
 * [Uso.GRAVACAO]). Cada um pega uma [Posse] e a solta; a fonte fecha quando a última sai.
 *
 * Antes (até a P4) cada serviço abria a sua, e a segunda abertura esbarrava na interface já
 * reivindicada — por isso a tela barrava gravar e transmitir juntos. **A placa grava e transmite
 * junto** (§11, item 4): o mesmo quadro decodificado vai ao encoder da rede e ao da gravação (os dois
 * `ImageWriter` da [FonteDv]), e o mesmo som ao Opus e ao AAC (os ramais do som, abaixo). A barreira
 * da **filmadora DV** continua aqui ([exclusividade]): a gravação da fita põe a fila do C em FIFO
 * funda, entrega o quadro com erro de USB e ancora o som no quadro, e isso não foi provado com a
 * rede puxando o mesmo quadro.
 *
 * **A prévia parada** ([quererPrevia]) é pedida por tela, cada uma com a sua chave: a de Espelhar só
 * da placa, a tela "Placa de captura e filmadora" (`VideoUsbActivity`, §13) da placa e da filmadora DV.
 *
 * **Threads**: [pegar] e [soltar] bloqueiam (abrir o USB leva centenas de ms; fechar espera a
 * thread `quall-dv` até 2 s) e nunca rodam na principal: a rede e a gravação chamam das threads
 * delas, e a prévia da tela passa por [obras]. O fechamento corre com a [trava] presa, de propósito:
 * uma abertura que viesse no meio acharia a interface ainda reivindicada.
 *
 * **O ouvinte da fonte** é um só (o [FonteDv.ouvinte]); aqui ele é repassado a cada posse, lendo a
 * lista sem a trava (a thread `quall-dv` avisa a queda enquanto quem fecha espera por ela).
 */
object DonoDaPlaca {
    private const val TAG = "QuallDv"

    enum class Uso { PREVIA, REDE, GRAVACAO }

    /** Uma posse da fonte aberta. Só [soltar] a devolve. */
    class Posse internal constructor(
        val fonte: FonteDv,
        val uso: Uso,
        internal val aberta: Aberta,
        internal val ouvinte: FonteDv.Ouvinte?,
    )

    internal class Aberta(val id: String, val fonte: FonteDv) {
        val posses = CopyOnWriteArrayList<Posse>()
    }

    private val trava = Any()
    private var atual: Aberta? = null

    /** A fonte aberta agora (para o som, a foto e o ouvir), ou `null`. */
    val fonte: FonteDv? get() = synchronized(trava) { atual?.fonte }

    /**
     * O som da fonte aberta não passa pelo microfone do Android (a fita, de dentro do DV; a placa lida
     * pelo usbfs, §13.10): gravar, transmitir e ouvir **não pedem a permissão do microfone**.
     */
    val somSemMicrofone: Boolean get() = fonte?.let { !it.mjpeg || it.temSomUsb } == true

    /**
     * Pega a fonte do aparelho [id] (`usb-dv:<deviceName>`), abrindo-a se ninguém a tem. Lança
     * [IllegalStateException] com a frase para o usuário. Bloqueia: nunca na principal.
     */
    fun pegar(contexto: Context, id: String, uso: Uso, ouvinte: FonteDv.Ouvinte?): Posse {
        synchronized(trava) {
            var a = atual
            if (a != null && a.fonte.desconectada) {
                // A que caiu fica com quem a tem (cada um a solta quando vê a queda); esta é nova.
                Log.i(TAG, "dono do vídeo USB: a fonte aberta caiu; abrindo de novo para ${uso.name.lowercase()}")
                atual = null
                a = null
            }
            if (a != null && a.id != id) {
                throw IllegalStateException(Idioma.contexto(contexto).getString(R.string.placa_outro_aberto,
                    a.posses.joinToString { it.uso.name.lowercase() }))
            }
            if (a == null) {
                val f = FonteDv.abrir(contexto, id)
                val nova = Aberta(id, f)
                f.ouvinte = repassador(nova)
                atual = nova
                a = nova
                Log.i(TAG, "dono do vídeo USB: aberta ($id, ${f.tipo}) para ${uso.name.lowercase()}")
            } else {
                exclusividade(a, uso)
            }
            val p = Posse(a.fonte, uso, a, ouvinte)
            a.posses += p
            Log.i(TAG, "dono do vídeo USB: ${uso.name.lowercase()} pegou (posses: ${a.posses.joinToString { it.uso.name.lowercase() }})")
            return p
        }
    }

    /** Devolve a posse; a última fecha a fonte (e devolve o aparelho ao kernel). Bloqueia até 2 s. */
    fun soltar(p: Posse) {
        synchronized(trava) {
            val a = p.aberta
            if (!a.posses.remove(p)) return
            Log.i(TAG, "dono do vídeo USB: ${p.uso.name.lowercase()} soltou (restam: ${a.posses.joinToString { it.uso.name.lowercase() }.ifEmpty { "nenhuma" }})")
            if (a.posses.isNotEmpty()) return
            if (atual === a) atual = null
            runCatching { a.fonte.fechar() }.onFailure { Log.w(TAG, "dono do vídeo USB: fechar falhou: ${Log.erroExterno(it.message)}") }
        }
    }

    /** A outra posse não deixa (a filmadora DV com um dono só); a mensagem é a frase para a tela. */
    class Ocupada(frase: String) : IllegalStateException(frase)

    /**
     * A filmadora DV tem um dono só entre a rede e a gravação (o "Gravar a fita" muda a fila do C e
     * ancora o som no quadro; não foi provado com a rede junto). A prévia convive com as duas, e a
     * placa, com tudo (§11, item 4).
     */
    private fun exclusividade(a: Aberta, uso: Uso) {
        if (a.fonte.mjpeg) return
        val outros = a.posses.map { it.uso }
        if (uso == Uso.REDE && Uso.GRAVACAO in outros) {
            throw Ocupada(UsbDv.frase(R.string.placa_dv_gravando_nao_espelha))
        }
        if (uso == Uso.GRAVACAO && Uso.REDE in outros) {
            throw Ocupada(UsbDv.frase(R.string.placa_dv_espelhando_nao_grava))
        }
    }

    private fun repassador(a: Aberta) = object : FonteDv.Ouvinte {
        override fun aoPausar() { for (p in a.posses) runCatching { p.ouvinte?.aoPausar() } }
        override fun aoVoltar(pausaMs: Long) { for (p in a.posses) runCatching { p.ouvinte?.aoVoltar(pausaMs) } }
        override fun aoCair(motivo: String) { for (p in a.posses) runCatching { p.ouvinte?.aoCair(motivo) } }
    }

    // ------------------------------------------------------------------------------ o som da placa

    /**
     * **O som da placa, um `AudioRecord` só** (§11, itens 3 a 5): a entrada USB da placa (§1: 48 kHz
     * mono), pedida por `setPreferredDevice` num [MicrofoneCru] (a linha crua, sem NS/AEC/AGC),
     * repartida por um [MicrofoneCompartilhado] em ramais: a rede (o emissor Opus do `MirrorService`),
     * a gravação (o AAC do [GravadorMp4], por [SomDaPlaca]) e o ouvir no telefone. Abre no primeiro
     * ramal e fecha quando o último sai ([RamalDaPlaca.fechar]).
     *
     * Depois do `start`, o `getRoutedDevice` diz de onde o som vem de fato: se não for a placa, o
     * [avisoDoSom] diz ("o som está vindo de …, e não da placa"). O silêncio digital (a placa sem
     * nada na entrada de áudio manda zeros exatos) vira *"a placa não está recebendo som (confira o
     * cabo de áudio)"*.
     */
    private val travaDoSom = Any()
    private var som: com.quall.android.audio.MicrofoneCompartilhado? = null
    private var ramaisDoSom = 0
    /** A fonte cujo som pelo USB está em [som] (sob [travaDoSom]); `null` com o `AudioRecord`. */
    private var fonteDoSomUsb: FonteDv? = null
    /**
     * O som que não vem da placa: sem a entrada USB dela, ou roteado para outra. Guardado como dado
     * (e não como frase) para o [avisoDoSom] sair no idioma de quando é lido (`docs/traducao.md`).
     */
    private class RotaErrada(val semEntradaUsb: Boolean, val de: String?)
    @Volatile private var rotaErrada: RotaErrada? = null
    @Volatile private var emSilencio = false
    private val ouvintesDoSom = CopyOnWriteArrayList<(String?) -> Unit>()

    /**
     * A frase do silêncio em português, para o `EstadoDoMicrofoneTest` (de outra área) que a compara.
     * A tela usa o [avisoDoSom], no idioma escolhido.
     */
    const val FRASE_DO_SILENCIO = "a placa não está recebendo som (confira o cabo de áudio)"  // i18n-fora: compatibilidade de teste; a tela lê placa_som_sem_sinal

    /** O que dizer do som da placa agora (o silêncio, ou a entrada errada), ou `null`. */
    val avisoDoSom: String? get() = if (emSilencio) UsbDv.frase(R.string.placa_som_sem_sinal) else avisoDoRoteamento

    /** A [rotaErrada] em frase, no idioma de agora. */
    private val avisoDoRoteamento: String? get() = rotaErrada?.let {
        val de = it.de ?: UsbDv.frase(R.string.placa_som_desconhecido)
        UsbDv.frase(if (it.semEntradaUsb) R.string.placa_som_sem_entrada_usb else R.string.placa_som_vindo_de_outro, de)
    }

    /** Quem quer saber quando o [avisoDoSom] muda (chamado na thread do som). */
    fun ouvirAvisoDoSom(o: (String?) -> Unit) { ouvintesDoSom += o }
    fun pararDeOuvirAvisoDoSom(o: (String?) -> Unit) { ouvintesDoSom -= o }

    private fun avisarSom() {
        val a = avisoDoSom
        for (o in ouvintesDoSom) runCatching { o(a) }
    }

    /** O som abre com 20 ms por quadro a 48 kHz mono: o preset do microfone do núcleo, se ele responder. */
    private fun presetDoSom(): com.quall.android.audio.PresetDeAudio =
        com.quall.android.audio.PresetDeAudio.de(com.quall.android.core.QuallNative.TrackKind.MICROPHONE)
            ?.takeIf { it.taxaHz == TAXA_DO_SOM && it.canais == 1 }
            ?: com.quall.android.audio.PresetDeAudio("opus", TAXA_DO_SOM, 1, 20, TAXA_DO_SOM / 50, 32_000,
                fec = false, perdaEsperadaPct = 0, ehFala = false, payloadType = -1, fmtp = "")

    const val TAXA_DO_SOM = 48_000

    /**
     * Um ramal novo do som da placa aberta (abrindo o `AudioRecord` se é o primeiro), ou `null` com o
     * porquê em [motivo] (sem a placa aberta, sem a permissão do microfone, o `AudioRecord` recusado).
     * Bloqueia até ~0,5 s na primeira abertura (a espera do roteado): nunca na principal.
     */
    @android.annotation.SuppressLint("MissingPermission")
    fun ramalDoSom(
        contexto: Context,
        /**
         * Chamado (antes de [motivo]) quando falta a permissão do microfone: o dado tipado para quem
         * decidia pelo texto do motivo (`contains("permissão")`), que muda com o idioma.
         */
        semPermissao: () -> Unit = {},
        motivo: (String) -> Unit,
    ): com.quall.android.audio.FonteDeAudio? {
        UsbDv.lembrarEm(contexto)
        val t = Idioma.textos(Idioma.contexto(contexto))
        synchronized(travaDoSom) {
            // O som pelo USB é da fonte que o abriu: fechada ela, o microfone velho só lê vazio (e sai
            // sozinho em segundos); a fonte nova abre o dela.
            val aberto = som?.takeIf { it.vivo && (fonteDoSomUsb == null || fonteDoSomUsb === fonte) }
            if (aberto != null) {
                ramaisDoSom++
                return RamalDaPlaca(aberto.ramal(), aberto)
            }
            som = null
            val f = fonte
            if (f == null || !f.mjpeg) { motivo(t.s(R.string.placa_placa_nao_aberta)); return null }
            // **O som pelo usbfs** (§13.10): a fonte lê o endpoint de som da placa; sem `AudioRecord`
            // (nem a permissão do microfone), sem o ganho que o Android põe no som baixo.
            f.somUsb()?.let { cru ->
                val preset = presetDoSom()
                emSilencio = false
                rotaErrada = null
                Log.i(TAG, "som da placa: aberto pelo USB (48 kHz mono, sem o AudioRecord)")
                var eu: com.quall.android.audio.MicrofoneCompartilhado? = null
                val m = com.quall.android.audio.MicrofoneCompartilhado(cru, preset, aoSairSozinho = { porqueSaiu ->
                    Log.w(TAG, "som da placa: a leitura parou sozinha (${Log.erroExterno(porqueSaiu)})")
                    synchronized(travaDoSom) { if (som === eu) som = null }
                })
                eu = m
                m.iniciar()
                som = m
                fonteDoSomUsb = f
                ramaisDoSom = 1
                avisarSom()
                return RamalDaPlaca(m.ramal(), m)
            }
            fonteDoSomUsb = null
            if (contexto.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                semPermissao(); motivo(t.s(R.string.placa_sem_permissao_microfone)); return null
            }
            val am = contexto.getSystemService(android.media.AudioManager::class.java)
            val entradas = am?.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS).orEmpty()
            val escolhida = GravacaoDaPlaca.escolherEntrada(
                entradas.map { GravacaoDaPlaca.Entrada(it.id, it.type == android.media.AudioDeviceInfo.TYPE_USB_DEVICE, it.productName?.toString().orEmpty()) },
                f.nomeDoAparelho,
            )
            val dispositivo = escolhida?.let { e -> entradas.firstOrNull { it.id == e.id } }
            val preset = presetDoSom()
            var porque = ""
            emSilencio = false
            val cru = com.quall.android.audio.MicrofoneCru.abrir(
                preset.taxaHz, 1, preset.amostrasPorCanal,
                falha = { porque = com.quall.android.core.Idioma.contexto(contexto).getString(it.frase) },
                aoSilencioDigital = { s -> emSilencio = s; avisarSom() },
                preferido = dispositivo,
                nome = "som da placa",
                porqueDoSilencio = "a placa sem som na entrada de áudio?",  // i18n-fora: diário (o MicrofoneCru só o anota)
            )
            if (cru == null) { motivo(porque.ifBlank { t.s(R.string.placa_som_nao_abriu) }); return null }
            // O roteado aparece logo depois do start; espera até 500 ms.
            var rot: android.media.AudioDeviceInfo? = null
            val limite = System.nanoTime() + 500_000_000L
            while (rot == null && System.nanoTime() < limite) {
                rot = cru.dispositivoRoteado
                if (rot == null) Thread.sleep(20)
            }
            val nomeRot = rot?.let { "${it.productName} (tipo ${it.type})" }
            rotaErrada = when {
                dispositivo == null -> RotaErrada(semEntradaUsb = true, de = nomeRot)
                rot != null && rot.id != dispositivo.id -> RotaErrada(semEntradaUsb = false, de = nomeRot)
                else -> null
            }
            Log.i(TAG, "som da placa: aberto, roteado_tipo=${rot?.type} pedida_tipo=${dispositivo?.type} " +
                "aviso_rota=${avisoDoRoteamento != null}")
            var eu: com.quall.android.audio.MicrofoneCompartilhado? = null
            val m = com.quall.android.audio.MicrofoneCompartilhado(cru, preset, aoSairSozinho = { porqueSaiu ->
                Log.w(TAG, "som da placa: a leitura parou sozinha (${Log.erroExterno(porqueSaiu)})")
                synchronized(travaDoSom) { if (som === eu) som = null }
            })
            eu = m
            m.iniciar()
            som = m
            ramaisDoSom = 1
            avisarSom()
            return RamalDaPlaca(m.ramal(), m)
        }
    }

    /** Solta um ramal; o último fecha o `AudioRecord` (até 2 s, na thread de quem solta). */
    private fun soltarRamal(r: RamalDaPlaca) {
        val fechar = synchronized(travaDoSom) {
            if (som !== r.dono) return
            ramaisDoSom--
            if (ramaisDoSom > 0) return
            som = null
            r.dono
        }
        if (!fechar.fechar()) Log.w(TAG, "som da placa: a leitura não saiu em 2 s")
        Log.i(TAG, "som da placa: fechado (lidos=${fechar.quadrosLidos} quadros de 20 ms)")
        emSilencio = false
        rotaErrada = null
        avisarSom()
    }

    /** Um ramal do som da placa como [FonteDeAudio]: `fechar` o devolve ao dono (uma vez). */
    private class RamalDaPlaca(
        private val ramal: com.quall.android.audio.MicrofoneCompartilhado.Ramal,
        val dono: com.quall.android.audio.MicrofoneCompartilhado,
    ) : com.quall.android.audio.FonteDeAudio {
        private val fechado = java.util.concurrent.atomic.AtomicBoolean(false)
        override val nome: String get() = "som da placa"
        override fun proximoQuadro(pcm: ShortArray): Int = ramal.proximoQuadro(pcm)
        val naFila: Int get() = ramal.naFila
        override fun instanteDoQuadroUs(): Long? = ramal.instanteDoQuadroUs()
        override val ritmadaPeloDispositivo: Boolean get() = true
        override fun interromper() = ramal.interromper()
        override fun fechar() {
            if (!fechado.compareAndSet(false, true)) return
            ramal.fechar()
            soltarRamal(this)
        }
    }

    // ------------------------------------------------------------------------------ ouvir a placa

    /**
     * **Ouvir o som da placa no telefone** (§11, item 5; o "monitor de som" do EasyCap Recorder, §10):
     * um ramal do mesmo `AudioRecord` (item 3) tocado num `AudioTrack` de baixa latência (48 kHz mono,
     * `PERFORMANCE_MODE_LOW_LATENCY`). Funciona na prévia, gravando e transmitindo (os ramais não se
     * atrapalham). **Desligado por padrão**; a tela o solta ao sair (troca de fonte, sair de Espelhar,
     * segundo plano).
     *
     * A latência não cresce: o relógio da placa e o da saída não são o mesmo, e a fila do ramal
     * encheria devagar; com mais de [FILA_DO_OUVIR] quadros esperando (60 ms), o mais velho cai.
     */
    val ouvindo: Boolean get() = ouvindoAPlaca || fonte?.ouvindoAFita == true
    @Volatile private var ouvindoAPlaca = false
    private var threadDoOuvir: Thread? = null  // só em [obras]
    @Volatile private var pararDeOuvir = false
    private const val FILA_DO_OUVIR = 3

    /**
     * Liga ou desliga o ouvir. Não bloqueia; [aoMudar] é chamado na principal com o estado e, se não
     * ligou, o porquê.
     */
    fun ouvir(contexto: Context, ligar: Boolean, aoMudar: (ligado: Boolean, porque: String?) -> Unit) {
        val c = contexto.applicationContext
        obras.execute {
            if (!ligar) {
                pararOuvir()
                fonte?.ouvirFita(false)
                principal.post { aoMudar(false, null) }
                return@execute
            }
            // A filmadora DV: o som vem dentro do quadro, e quem o toca é a própria fonte (§13.7).
            fonte?.takeIf { !it.mjpeg && !it.desconectada }?.let { f ->
                f.ouvirFita(true)
                principal.post { aoMudar(true, null) }
                return@execute
            }
            if (threadDoOuvir?.isAlive == true) { principal.post { aoMudar(true, null) }; return@execute }
            var motivo = ""
            val r = ramalDoSom(c) { motivo = it } as? RamalDaPlaca
            if (r == null) {
                principal.post { aoMudar(false, motivo.ifBlank { Idioma.contexto(c).getString(R.string.placa_som_nao_abriu) }) }
                return@execute
            }
            val taxa = TAXA_DO_SOM
            val trilha = runCatching {
                val min = android.media.AudioTrack.getMinBufferSize(taxa, android.media.AudioFormat.CHANNEL_OUT_MONO,
                    android.media.AudioFormat.ENCODING_PCM_16BIT)
                android.media.AudioTrack.Builder()
                    .setAudioAttributes(android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build())
                    .setAudioFormat(android.media.AudioFormat.Builder()
                        .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(taxa)
                        .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO)
                        .build())
                    .setPerformanceMode(android.media.AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .setTransferMode(android.media.AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(maxOf(min, taxa / 50 * 2 * 2))
                    .build()
            }.getOrNull()
            if (trilha == null || trilha.state != android.media.AudioTrack.STATE_INITIALIZED) {
                trilha?.release()
                r.fechar()
                principal.post { aoMudar(false, Idioma.contexto(c).getString(R.string.placa_saida_de_som_nao_abriu)) }
                return@execute
            }
            pararDeOuvir = false
            ouvindoAPlaca = true
            val t = Thread({ tocar(r, trilha) }, "quall-ouvir-placa")
            threadDoOuvir = t
            t.start()
            Log.i(TAG, "ouvir a placa: ligado (AudioTrack ${taxa} Hz mono, baixa latência, buffer ${trilha.bufferSizeInFrames} quadros)")
            principal.post { aoMudar(true, null) }
        }
    }

    private fun tocar(r: RamalDaPlaca, trilha: android.media.AudioTrack) {
        val pcm = ShortArray(TAXA_DO_SOM / 50)
        var caidos = 0L
        var tocados = 0L
        try {
            trilha.play()
            while (!pararDeOuvir) {
                // A fila do ramal não passa de [FILA_DO_OUVIR]: o mais velho cai (latência fixa).
                while (r.naFila > FILA_DO_OUVIR && !pararDeOuvir && r.dono.vivo) { if (r.proximoQuadro(pcm) > 0) caidos++ }
                val n = r.proximoQuadro(pcm)
                if (n <= 0) {
                    // O ramal espera até 200 ms por quadro; voltar vazio com o som morto é o fim.
                    if (!r.dono.vivo) { Log.w(TAG, "ouvir a placa: o som da placa parou"); break }
                    continue
                }
                trilha.write(pcm, 0, n, android.media.AudioTrack.WRITE_BLOCKING)
                tocados++
            }
        } catch (t: Throwable) {
            Log.w(TAG, "ouvir a placa: parou (${t.javaClass.simpleName}: ${Log.erroExterno(t.message)})")
        } finally {
            runCatching { trilha.pause(); trilha.flush() }
            runCatching { trilha.release() }
            r.fechar()
            ouvindoAPlaca = false
            Log.i(TAG, "ouvir a placa: desligado; tocados=$tocados quadros de 20 ms, caidos_pela_latencia=$caidos")
        }
    }

    /** Em [obras]: para o ouvir e espera a thread (até 1 s). */
    private fun pararOuvir() {
        val t = threadDoOuvir ?: return
        threadDoOuvir = null
        pararDeOuvir = true
        t.join(1000)
        if (t.isAlive) Log.w(TAG, "ouvir a placa: a thread não saiu em 1 s")
    }

    // ------------------------------------------------------------------------------ a foto

    /**
     * **A foto do quadro atual** (§11, item 6): o próximo quadro decodificado da placa aberta (na
     * prévia, gravando ou transmitindo), em NV21 com a faixa expandida ([FotoDaPlaca]), JPEG pelo
     * `YuvImage.compressToJpeg` (qualidade 92), salvo em `Pictures/Quall/Quall-Placa-AAAAMMDD-HHMMSS.jpg`
     * pelo MediaStore (pendente até terminar). **A filmadora DV também** (§13): o quadro desentrelaçado,
     * esticado de 720x480 ao aspecto dela (640x480 em 4:3, 854x480 em 16:9), `Quall-DV-….jpg`. Não
     * bloqueia; [aoTerminar] é chamado na principal com o nome salvo, ou o porquê de não ter salvo.
     */
    fun foto(contexto: Context, aoTerminar: (nome: String?, porque: String?) -> Unit) {
        val c = contexto.applicationContext
        obras.execute {
            val f = fonte
            if (f == null || f.desconectada) {
                principal.post { aoTerminar(null, Idioma.contexto(c).getString(R.string.placa_foto_sem_aparelho)) }
                return@execute
            }
            val trinco = java.util.concurrent.CountDownLatch(1)
            var quadro: FonteDv.QuadroYuv? = null
            f.pedirFoto { q -> quadro = q; trinco.countDown() }
            if (!trinco.await(2, TimeUnit.SECONDS)) {
                f.esquecerFoto()
                val porque = Idioma.contexto(c).getString(
                    if (f.mjpeg) R.string.placa_foto_placa_sem_imagem else R.string.placa_foto_filmadora_sem_imagem)
                principal.post { aoTerminar(null, porque) }
                return@execute
            }
            val q = quadro ?: run {
                val porque = Idioma.contexto(c).getString(R.string.placa_foto_sem_quadro)
                principal.post { aoTerminar(null, porque) }; return@execute
            }
            val nome = FotoDaPlaca.nome(prefixo = if (f.mjpeg) "Quall-Placa-" else "Quall-DV-")
            val r = runCatching {
                val g = q.geometria
                val n0 = FotoDaPlaca.nv21(q.y, q.u, q.v, g.larguraY, g.alturaY, g.larguraC, g.alturaC)
                // A DV é 720x480 para 4:3 ou 16:9 (pixel não quadrado): esticada ao aspecto dela. A
                // placa (640x480, 4:3) já é quadrada e passa igual.
                val alvo = FotoDaPlaca.larguraQuadrada(n0.altura, g.aspectoN, g.aspectoD)
                val n = if (alvo >= 2 && alvo != n0.largura) FotoDaPlaca.redimensionar(n0, alvo) else n0
                val jpeg = java.io.ByteArrayOutputStream(n.largura * n.altura / 4)
                val img = android.graphics.YuvImage(n.dados, android.graphics.ImageFormat.NV21, n.largura, n.altura, null)
                if (!img.compressToJpeg(android.graphics.Rect(0, 0, n.largura, n.altura), QUALIDADE_DA_FOTO, jpeg)) {
                    throw IllegalStateException(Idioma.contexto(c).getString(R.string.placa_foto_jpeg))
                }
                salvarFoto(c, nome, jpeg.toByteArray())
                Log.i(TAG, "foto ${if (f.mjpeg) "da placa" else "da filmadora"}: $nome ${n.largura}x${n.altura} ${jpeg.size()} bytes " +
                    "(quadro ${g.larguraY}x${g.alturaY}, croma ${g.larguraC}x${g.alturaC} → 4:2:0, aspecto ${g.aspectoN}:${g.aspectoD}, faixa expandida)")
            }
            principal.post {
                r.fold({ aoTerminar(nome, null) }, { aoTerminar(null, it.message ?: it.javaClass.simpleName) })
            }
            r.exceptionOrNull()?.let { Log.w(TAG, "foto: não salvou: ${Log.erroExterno(it.message)}") }
        }
    }

    private const val QUALIDADE_DA_FOTO = 92

    private fun salvarFoto(c: Context, nome: String, jpeg: ByteArray) {
        val cr = c.contentResolver
        val cv = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, nome)
            put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, android.os.Environment.DIRECTORY_PICTURES + "/Quall")
            put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = cr.insert(android.provider.MediaStore.Images.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY), cv)
            ?: throw IllegalStateException(Idioma.contexto(c).getString(R.string.placa_galeria_recusou_foto))
        try {
            (cr.openOutputStream(uri) ?: throw IllegalStateException(Idioma.contexto(c).getString(R.string.placa_galeria_nao_abriu_foto))).use { it.write(jpeg) }
            cr.update(uri, android.content.ContentValues().apply { put(android.provider.MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (t: Throwable) {
            runCatching { cr.delete(uri, null, null) }
            throw t
        }
    }

    // ------------------------------------------------------------------------------ a prévia

    /**
     * Onde a prévia da tela abre e fecha (e, depois, o ouvir e a foto): uma thread, fora da
     * principal. A soltura da prévia espera [ESPERA_PARA_SOLTAR_MS]: a tela recriada (girar o
     * aparelho) pede de novo antes disso, e a placa não fecha e reabre à toa.
     */
    private val obras = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "quall-placa") }
    private const val ESPERA_PARA_SOLTAR_MS = 1500L
    private val principal by lazy { Handler(Looper.getMainLooper()) }

    // só em [obras]
    private var previa: Posse? = null
    private var falhouPara: String? = null
    private var soltura: ScheduledFuture<*>? = null

    /**
     * Um pedido de prévia de uma tela: o aparelho [id], se ela aceita a filmadora DV ([aceitaDv]; a
     * prévia parada de Espelhar é só da placa, a tela "Placa de captura e filmadora" mostra as duas),
     * e o [aoFalhar] dela (na principal).
     */
    private class PedidoDePrevia(val id: String, val aceitaDv: Boolean, val aoFalhar: (String) -> Unit)

    /**
     * Os pedidos de cada tela, pela chave dela (só em [obras]). **Uma chave por tela**, e não um valor
     * só: abrir uma tela por cima de outra chama o `onStart` da nova **antes** do `onStop` da velha, e a
     * velha, ao deixar de querer, apagaria o pedido da nova. Vale o pedido mais recente.
     */
    private val pedidos = LinkedHashMap<String, PedidoDePrevia>()

    private fun querida(): PedidoDePrevia? = pedidos.values.lastOrNull()

    /**
     * A tela [dono] quer a prévia parada do aparelho [id], ou nenhuma (`null`). Não bloqueia.
     * [aoFalhar] é chamado na principal com a frase, quando o aparelho não abriu ou caiu; uma falha
     * não se repete para o mesmo id até a tela deixar de querer, ou pedir de novo com [deNovo]. Sem
     * [aceitaDv], uma filmadora DV (o palpite de placa errou) é solta sem aviso.
     */
    fun quererPrevia(
        dono: String,
        contexto: Context,
        id: String?,
        aceitaDv: Boolean = false,
        deNovo: Boolean = false,
        aoFalhar: (String) -> Unit,
    ) {
        val c = contexto.applicationContext
        obras.execute {
            val antes = pedidos[dono]
            if (id == null) {
                pedidos.remove(dono)
            } else if (antes == null || antes.id != id || antes.aceitaDv != aceitaDv) {
                // Um pedido novo desta tela (e o mais recente de todos): a falha de antes não vale.
                pedidos.remove(dono)
                pedidos[dono] = PedidoDePrevia(id, aceitaDv, aoFalhar)
                falhouPara = null
            } else {
                pedidos[dono] = PedidoDePrevia(id, aceitaDv, aoFalhar)  // a mesma posição; o ouvinte novo
            }
            if (deNovo) falhouPara = null
            soltura?.cancel(false)
            soltura = null
            if (querida() == null) {
                falhouPara = null
                if (previa != null) {
                    soltura = obras.schedule({ aplicarPrevia(c) }, ESPERA_PARA_SOLTAR_MS, TimeUnit.MILLISECONDS)
                }
            } else {
                aplicarPrevia(c)
            }
        }
    }

    /**
     * **Fecha e abre de novo a prévia** (a pessoa trocou o formato, o tamanho ou os quadros, §14.4): só
     * com a prévia sozinha no aparelho (gravando ou transmitindo, a fonte é de outro uso e não fecha).
     * Não bloqueia; devolve na principal se reabriu.
     */
    fun reabrirPrevia(contexto: Context, aoTerminar: (Boolean) -> Unit) {
        val c = contexto.applicationContext
        obras.execute {
            val tem = previa
            val so = tem != null && synchronized(trava) { atual?.posses?.size == 1 }
            if (tem != null && so) {
                previa = null
                soltar(tem)
                Log.i(TAG, "prévia da placa: solta para reabrir com outro formato")
                falhouPara = null
                aplicarPrevia(c)
            }
            val ok = so && previa != null
            principal.post { aoTerminar(ok) }
        }
    }

    /** Em [obras]: a frase a cada tela que quer a prévia de [id]. */
    private fun avisarFalha(id: String, motivo: String) {
        for (p in pedidos.values) if (p.id == id) principal.post { p.aoFalhar(motivo) }
    }

    private fun aplicarPrevia(c: Context) {
        val quer = querida()
        val tem = previa
        if (tem != null && (quer == null || tem.aberta.id != quer.id || tem.fonte.desconectada ||
                (!tem.fonte.mjpeg && !quer.aceitaDv))) {
            previa = null
            soltar(tem)
            Log.i(TAG, "prévia da ${if (tem.fonte.mjpeg) "placa" else "filmadora"}: solta")
        }
        if (quer == null || previa != null || falhouPara == quer.id) return
        val id = quer.id
        try {
            var eu: Posse? = null
            val p = pegar(c, id, Uso.PREVIA, object : FonteDv.Ouvinte {
                override fun aoPausar() {}
                override fun aoVoltar(pausaMs: Long) {}
                override fun aoCair(motivo: String) {
                    obras.execute {
                        val minha = eu
                        if (minha != null && previa === minha) {
                            previa = null
                            falhouPara = id
                            soltar(minha)
                        }
                        avisarFalha(id, motivo)
                    }
                }
            })
            eu = p
            if (!p.fonte.mjpeg && !quer.aceitaDv) {
                // A prévia parada de Espelhar é da placa; uma filmadora DV (o palpite errou) não fica
                // aberta à toa.
                Log.i(TAG, "prévia da placa: o aparelho é uma filmadora DV; solta")
                falhouPara = id
                soltar(p)
                return
            }
            previa = p
            Log.i(TAG, "prévia da ${if (p.fonte.mjpeg) "placa" else "filmadora"}: aberta")
        } catch (e: Exception) {
            falhouPara = id
            val motivo = e.message ?: e.javaClass.simpleName
            Log.w(TAG, "prévia do vídeo USB: não abriu: ${Log.erroExterno(motivo)}")
            avisarFalha(id, motivo)
        }
    }
}
