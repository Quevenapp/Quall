import AVFoundation
import Foundation

/// O sumidouro: PCM → alto-falante. É o **primeiro consumidor de tempo real** que o jitter buffer
/// deste projeto encontra.
///
/// # Por que isto é mais do que "tocar som"
///
/// `docs/audio.md` §14 registra, em voz alta, o que nunca foi exercido:
///
/// > *"**Nada foi reproduzido por um DAC** … **subconsumo (underrun) nunca foi observado** … **a
/// > profundidade 2 nunca foi validada contra um consumidor de tempo real.**"*
/// > *"Um jitter buffer de verdade é **puxado pelo relógio do DAC**. O daqui é empurrado pelas
/// > chegadas."*
///
/// Esse desencontro — buffer empurrado, DAC puxando — é exatamente o que produz subconsumo, e é a
/// única grandeza nova que um receptor de áudio consegue trazer para este projeto. Por isso este
/// arquivo **conta subconsumo** em vez de só tocar: `pendentes` é decrementado no retorno de cada
/// buffer entregue, e toda vez que ele chega a zero com a sessão viva é um instante em que o DAC
/// pediu e não havia. Um número, não uma impressão.
///
/// # Float32 e não Int16, e a conversão é nossa de propósito
///
/// A libopus entrega `int16` intercalado. O `AVAudioEngine` conecta nós no formato que a conexão
/// declara, e o formato que ele aceita sem discussão em toda versão de iOS é `pcmFormatFloat32`
/// não-intercalado. Converter aqui — uma multiplicação por 1/32768 — custa menos que descobrir,
/// num aparelho, que a conexão em `pcmFormatInt16` funcionou no simulador e não no ferro.
///
/// # A sessão de áudio: `.playback`, e o que isso significa para quem está do outro lado
///
/// Categoria `.playback` porque quem exibe um espelhamento quer ouvir com o interruptor de
/// silêncio ligado — é a mesma expectativa de um app de vídeo. **`.mixWithOthers` não é usado**: o
/// som do aparelho espelhado é o conteúdo principal, e deixá-lo somar com a música que já estava
/// tocando produziria uma mistura que ninguém pediu.
///
/// **Nada disto é do lado que emite.** `apps/ios/Quall/App/EmissorDeCamera.swift` registra a
/// decisão oposta, e ela continua valendo: o emissor não abre sessão de áudio nenhuma, porque
/// tomar a sessão interromperia música e chamadas de quem só queria mostrar a câmera.
final class SaidaDeAudio {

    struct Instantaneo {
        var entregues: UInt64 = 0
        var amostras: UInt64 = 0
        /// Quantas vezes a fila do tocador esvaziou com a sessão ainda viva. **A grandeza nova.**
        var subconsumos: UInt64 = 0
        /// Quantos buffers estão na fila do tocador agora. Ocupação instantânea.
        var pendentes: Int = 0
        /// Pico de ocupação. Com profundidade 2 no núcleo, isto deveria ficar em torno de 2–3.
        var picoDePendentes: Int = 0
        var motorNoAr = false
        /// A última falha do subsistema de áudio, em texto, para o relato não dizer só "não tocou".
        var ultimaFalha = ""
    }

    private let motor = AVAudioEngine()
    private let tocador = AVAudioPlayerNode()
    private var formato: AVAudioFormat?
    private let trava = NSLock()
    private var contadores = Instantaneo()
    private var ligado = false

    func instantaneo() -> Instantaneo {
        trava.lock(); defer { trava.unlock() }
        return contadores
    }

    /// Sobe a sessão de áudio, o motor e o tocador. Devolve `false` com o motivo em
    /// `instantaneo().ultimaFalha` — **nunca lança**, porque um receptor sem som ainda é um
    /// receptor, e derrubar a exibição de vídeo por causa do áudio seria trocar um defeito por um
    /// pior.
    @discardableResult
    func abrir(taxaHz: Double, canais: Int) -> Bool {
        trava.lock()
        guard !ligado else { trava.unlock(); return true }
        trava.unlock()

        do {
            let sessao = AVAudioSession.sharedInstance()
            try sessao.setCategory(.playback, mode: .moviePlayback, options: [])
            try sessao.setActive(true)
        } catch {
            anotarFalha("sessão de áudio: \(error)",
                        diagnostico: "sessão de áudio: \(SanitizacaoDoLog.erro(error))")
            return false
        }

        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: taxaHz,
                                    channels: AVAudioChannelCount(canais),
                                    interleaved: false) else {
            anotarFalha("formato \(taxaHz) Hz / \(canais) ch recusado")
            return false
        }

        motor.attach(tocador)
        motor.connect(tocador, to: motor.mainMixerNode, format: f)
        do {
            // `prepare` antes de `start`: sem ele o primeiro `scheduleBuffer` pode cair num motor
            // que ainda está alocando, e o sintoma é um estalo no começo de toda sessão.
            motor.prepare()
            try motor.start()
        } catch {
            anotarFalha("motor de áudio: \(error)",
                        diagnostico: "motor de áudio: \(SanitizacaoDoLog.erro(error))")
            return false
        }
        tocador.play()

        trava.lock()
        formato = f
        ligado = true
        contadores.motorNoAr = true
        trava.unlock()
        Diario.dizer("saída de áudio de pé: \(Int(taxaHz)) Hz, \(canais) canal(is), "
                     + "float32 não-intercalado, categoria playback")
        return true
    }

    /// Enfileira 20 ms. Chamado **da thread da libdatachannel**, dentro do tratador de slot — daí
    /// não haver nada bloqueante aqui: `scheduleBuffer` devolve na hora e a entrega acontece no
    /// relógio do motor.
    func tocar(_ pcm: [Int16]) {
        trava.lock()
        let f = formato
        let pronto = ligado
        trava.unlock()
        guard pronto, let f, !pcm.isEmpty else { return }

        let canais = Int(f.channelCount)
        let porCanal = pcm.count / max(1, canais)
        guard porCanal > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: f,
                                            frameCapacity: AVAudioFrameCount(porCanal)),
              let destino = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(porCanal)

        // Intercalado (o que a libopus produz) → planar (o que a conexão declara).
        for q in 0..<porCanal {
            for c in 0..<canais {
                destino[c][q] = Float(pcm[q * canais + c]) / 32768.0
            }
        }

        trava.lock()
        contadores.pendentes += 1
        contadores.picoDePendentes = max(contadores.picoDePendentes, contadores.pendentes)
        trava.unlock()

        tocador.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.trava.lock()
            self.contadores.pendentes -= 1
            self.contadores.entregues &+= 1
            self.contadores.amostras &+= UInt64(porCanal)
            // **O subconsumo, medido e não estimado.** Se a fila zerou no instante em que um
            // buffer acabou de tocar, o motor não tem o que tocar em seguida: ou o próximo slot
            // chega antes do fim do quadro corrente, ou há silêncio no meio. Com profundidade 2
            // no núcleo (40 ms) e quadros de 20 ms, a folga é de um quadro — e é justamente isso
            // que `docs/audio.md` §14 diz nunca ter sido validado contra um DAC.
            if self.contadores.pendentes == 0 { self.contadores.subconsumos &+= 1 }
            self.trava.unlock()
        }
    }

    func fechar() {
        trava.lock()
        guard ligado else { trava.unlock(); return }
        ligado = false
        contadores.motorNoAr = false
        trava.unlock()

        tocador.stop()
        motor.stop()
        motor.detach(tocador)
        // **Desativar com `.notifyOthersOnDeactivation`.** Sem isso, o app que estava tocando
        // música antes desta sessão não volta sozinho — e um receptor que rouba o som do aparelho
        // e não devolve é pior que um receptor mudo.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        Diario.dizer("saída de áudio desmontada")
    }

    private func anotarFalha(_ texto: String, diagnostico: String? = nil) {
        trava.lock(); contadores.ultimaFalha = texto; trava.unlock()
        Diario.dizer("!! saída de áudio: \(diagnostico ?? texto)")
    }
}
