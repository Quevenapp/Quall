import AVFoundation
import Foundation

/// Um tom que **este processo** gera e toca, para ser capturado como áudio de sistema.
///
/// # Por que uma origem sintética é obrigatória, e não um capricho
///
/// `docs/audio.md` §8 e `docs/regras-de-frente.md`: nunca gravar o som real do MacBook anfitrião.
/// A regra existe porque um `.wav` não carrega no nome o que tem dentro — o precedente do
/// repositório é uma frente que abriu um quadro de um `.h264` cuja origem era a tela do usuário,
/// com o WhatsApp Web dele à mostra.
///
/// Provar um caminho de áudio exige ouvir o que chegou do outro lado. As duas coisas só convivem
/// de um jeito: **o som tem de ser nosso desde o começo**. Este gerador é essa origem. Junto de
/// `EscopoDaCaptura.somenteEsteApp`, que limita o filtro do ScreenCaptureKit a este processo, o
/// caminho inteiro — captura, conversão, codec, RTP, receptor — é exercitado sem que um som da
/// vida do usuário possa entrar no artefato, porque nenhum passa por aqui.
///
/// É a irmã sonora do `SCContentFilter(desktopIndependentWindow:)`, que a frente do vidro a vidro
/// usou para capturar só a própria janela do Quall em vez da tela do usuário. Mesma forma:
/// **estreitar a captura até ela só conter o que nós mesmos produzimos.**
///
/// # Isto sai pelos alto-falantes
///
/// O `AVAudioEngine` toca no dispositivo de saída padrão, e é justamente por tocar que o
/// ScreenCaptureKit tem o que capturar. A amplitude é baixa por padrão e a duração é limitada por
/// quem chama. Não é um efeito colateral escondido: é o mecanismo.
public final class TomSintetico {
    private let engine = AVAudioEngine()
    private var fonte: AVAudioSourceNode?

    /// Frequência em Hz. **440 por padrão, e o número importa**: precisa caber abaixo do Nyquist
    /// do codec mais estreito da matriz. O PCMU trabalha a 8 kHz, então tudo acima de 4 kHz
    /// voltaria rebatido como uma frequência diferente — e o artefato mostraria um tom que nunca
    /// foi emitido, que é pior do que não mostrar nada.
    public let frequencia: Double
    /// Amplitude de 0 a 1. Baixa por padrão: isto toca nos alto-falantes de quem estiver na
    /// bancada.
    public let amplitude: Double

    public private(set) var tocando = false

    /// Quantas vezes o `AVAudioEngine` avisou que a configuração mudou — na prática, que o
    /// **dispositivo de saída padrão trocou** debaixo dele.
    ///
    /// # Por que este contador existe
    ///
    /// Porque este é o ponto onde "o som some sem erro nenhum" mora, e ele não some por defeito
    /// nosso: é comportamento documentado do `AVAudioEngine`. Quando o dispositivo de saída muda,
    /// o motor **para** e o grafo é desfeito. Ninguém lança exceção, nenhum contador de captura
    /// muda de cara — os blocos do ScreenCaptureKit continuam chegando, agora cheios de zeros — e
    /// o artefato do outro lado fica em silêncio com todos os números certos.
    ///
    /// É a forma exata do defeito que `docs/audio.md` §2 chama de o mais traiçoeiro, e a única
    /// defesa é anotar o aviso e remontar.
    public private(set) var mudancasDeConfiguracao = 0

    /// Cada evento do motor, para o registro. Sem isto o aviso do sistema acontece e não deixa
    /// rastro nenhum.
    public var aoRegistrar: ((String) -> Void)?

    private var observador: NSObjectProtocol?

    public init(frequencia: Double = 440, amplitude: Double = 0.25) {
        self.frequencia = frequencia
        self.amplitude = min(max(amplitude, 0), 1)
    }

    /// Começa a tocar. Devolve o motivo da falha, ou `nil` se subiu.
    @discardableResult
    public func comecar() -> String? {
        guard !tocando else { return nil }
        if let erro = montar() { return erro }
        tocando = true

        // O aviso de que o dispositivo de saída mudou. **Registrado depois de o motor subir**,
        // porque antes disso não há grafo para remontar.
        observador = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.reagirAMudancaDeConfiguracao()
        }
        return nil
    }

    /// O que o `AVAudioEngine` faz sozinho quando a saída troca: **para**. Aqui a resposta é
    /// remontar o grafo e subir de novo, anotando as duas metades — o que o sistema fez e se a
    /// remontagem pegou.
    private func reagirAMudancaDeConfiguracao() {
        mudancasDeConfiguracao += 1
        let rodando = engine.isRunning
        let saida = engine.outputNode.inputFormat(forBus: 0)
        aoRegistrar?(String(
            format: "tom: AVAudioEngineConfigurationChange #%d — motor rodando=%@, saída agora %.0f Hz / %u canal(is)",
            mudancasDeConfiguracao, rodando ? "sim" : "NÃO", saida.sampleRate, saida.channelCount))

        guard tocando else { return }
        // Desmonta o que sobrou e monta de novo contra o dispositivo novo. O formato do gerador
        // acompanha a saída de propósito: gerar em 48 kHz para um dispositivo que agora pede
        // 44,1 kHz colocaria uma reamostragem no meio e mudaria a frequência que chega ao
        // capturador — e a frequência é justamente o que a bancada mede.
        if let fonte {
            engine.detach(fonte)
            self.fonte = nil
        }
        engine.stop()
        if let erro = montar() {
            aoRegistrar?("tom: NÃO consegui remontar depois da troca de dispositivo — \(erro). "
                + "Daqui para a frente a captura recebe silêncio, e é isto que explica o zero.")
            tocando = false
            return
        }
        aoRegistrar?("tom: remontado sobre o dispositivo novo; voltou a tocar")
    }

    /// Monta o grafo e sobe o motor. Devolve o motivo da falha, ou `nil`.
    private func montar() -> String? {
        let saida = engine.outputNode.inputFormat(forBus: 0)
        guard saida.sampleRate > 0, saida.channelCount > 0 else {
            return "o dispositivo de saída padrão não expôs um formato utilizável"
        }
        // O nó gera em ponto flutuante não intercalado, no mesmo relógio da saída: assim não há
        // reamostragem no meio e a frequência que chega ao capturador é a que está aqui.
        guard let formato = AVAudioFormat(standardFormatWithSampleRate: saida.sampleRate,
                                          channels: saida.channelCount) else {
            return "não consegui montar o formato do gerador"
        }

        let passoDeFase = 2 * Double.pi * frequencia / saida.sampleRate
        let volume = Float(amplitude)
        var fase = 0.0

        let no = AVAudioSourceNode(format: formato) { _, _, quadros, listaDeBuffers in
            let buffers = UnsafeMutableAudioBufferListPointer(listaDeBuffers)
            for quadro in 0..<Int(quadros) {
                let valor = Float(sin(fase)) * volume
                fase += passoDeFase
                // A fase é mantida dentro de uma volta para não perder precisão em corridas
                // longas: em `Double` a soma sem volta degrada o seno depois de alguns minutos.
                if fase > 2 * Double.pi { fase -= 2 * Double.pi }
                for buffer in buffers {
                    guard let dados = buffer.mData else { continue }
                    dados.assumingMemoryBound(to: Float.self)[quadro] = valor
                }
            }
            return noErr
        }

        engine.attach(no)
        engine.connect(no, to: engine.mainMixerNode, format: formato)
        do {
            try engine.start()
        } catch {
            engine.detach(no)
            return "o AVAudioEngine não iniciou: \(error.localizedDescription)"
        }
        fonte = no
        return nil
    }

    public func parar() {
        if let observador {
            NotificationCenter.default.removeObserver(observador)
            self.observador = nil
        }
        guard tocando else { return }
        engine.stop()
        if let fonte { engine.detach(fonte) }
        fonte = nil
        tocando = false
    }

    deinit { parar() }
}
