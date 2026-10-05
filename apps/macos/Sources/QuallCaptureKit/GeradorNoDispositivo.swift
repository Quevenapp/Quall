import AVFoundation
import CoreAudio
import Foundation

/// **Leituras do CoreAudio** que a bancada do microfone precisa para não ferir o G5: o id de um
/// dispositivo pelo UID, o transporte, o nome, e quem são a saída padrão e a de efeitos do sistema.
/// Só lê; não abre fluxo nenhum.
public enum DispositivosDeAudio {

    public static func id(doUID uid: String) -> AudioDeviceID? {
        var endereco = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var tamanho = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &endereco,
                                       UInt32(MemoryLayout<CFString>.size), p, &tamanho, &id)
        }
        guard st == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static func uid(de id: AudioDeviceID) -> String? {
        texto(id, kAudioDevicePropertyDeviceUID)
    }

    public static func nome(de id: AudioDeviceID) -> String? {
        texto(id, kAudioObjectPropertyName)
    }

    public static func transporte(de id: AudioDeviceID) -> UInt32 {
        var endereco = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var tamanho = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &endereco, 0, nil, &tamanho, &t) == noErr else { return 0 }
        return t
    }

    /// A saída padrão (`kAudioHardwarePropertyDefaultOutputDevice`) e a de efeitos do sistema
    /// (`kAudioHardwarePropertyDefaultSystemOutputDevice`).
    public static func saidaPadrao() -> AudioDeviceID? { padrao(kAudioHardwarePropertyDefaultOutputDevice) }
    public static func saidaDeEfeitos() -> AudioDeviceID? { padrao(kAudioHardwarePropertyDefaultSystemOutputDevice) }
    public static func entradaPadrao() -> AudioDeviceID? { padrao(kAudioHardwarePropertyDefaultInputDevice) }

    private static func padrao(_ seletor: AudioObjectPropertySelector) -> AudioDeviceID? {
        var endereco = AudioObjectPropertyAddress(mSelector: seletor, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var tamanho = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &endereco, 0, nil,
                                         &tamanho, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func texto(_ id: AudioDeviceID, _ seletor: AudioObjectPropertySelector) -> String? {
        var endereco = AudioObjectPropertyAddress(mSelector: seletor, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var tamanho = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &endereco, 0, nil, &tamanho, &cf) == noErr,
              let valor = cf?.takeRetainedValue() else { return nil }
        return valor as String
    }

    /// Uma linha para o diário: quem é a saída padrão e a de efeitos agora (UID, nome, transporte).
    /// É o que o roteiro da fase 4 confere antes e depois: nenhuma das duas pode ser o dispositivo
    /// de laço.
    public static func relatoDasSaidas() -> String {
        func d(_ id: AudioDeviceID?) -> String {
            guard let id else { return "nenhuma" }
            return "\"\(nome(de: id) ?? "?")\" uid=\(uid(de: id) ?? "?") transporte="
                + AparelhoDeAudio.nome(doTransporte: transporte(de: id))
        }
        return "saida_padrao=\(d(saidaPadrao())) saida_de_efeitos=\(d(saidaDeEfeitos()))"
    }
}

/// **O gerador de tom na saída de um dispositivo virtual** (bancada da fase 4 no Mac, G5 de
/// `docs/teleprompter-com-camera.md` §8): toca o `TomDeQuatroNotas` na **saída** do dispositivo de
/// laço (tipo BlackHole) para que a entrada dele, aberta como microfone pelo dono da câmera, traga o
/// nosso tom — e só ele.
///
/// # A restrição do dispositivo de laço
///
/// Um BlackHole devolve na entrada **tudo** o que qualquer programa escrever na saída dele. Ele só é
/// aceitável se **nada além deste gerador** escrever nele. Então o gerador recusa tocar quando:
///
/// - o dispositivo é a **saída padrão** do sistema (tudo o que toca iria para ele);
/// - o dispositivo é a **saída de efeitos** (os sons do sistema iriam para ele);
/// - o transporte dele não é virtual (`'virt'`): não é um laço, é um alto-falante.
///
/// Conferido na hora de tocar (e dito no diário, `DispositivosDeAudio.relatoDasSaidas`); o roteiro
/// confere também antes e depois, por fora. Que um app qualquer não escolha o BlackHole como saída
/// **dele** (sem ser o padrão) é coisa que este processo não vê: fica no roteiro (fechar os apps de
/// som antes).
public final class GeradorNoDispositivo {
    private let engine = AVAudioEngine()
    private var fonte: AVAudioSourceNode?
    public let uid: String
    /// Tocando de verdade (e não abandonado por prazo). De qualquer thread.
    public var tocando: Bool { trava.withLock { _tocando && !_abandonado } }
    public var aoRegistrar: ((String) -> Void)?

    private let trava = NSLock()
    private var _tocando = false
    private var _abandonado = false
    /// **Tudo o que fala com o CoreAudio corre aqui, nunca na principal** (a prova de 25/09 no
    /// MacBook: o `setDeviceID` no BlackHole ficou preso num `mach_msg` ao `coreaudiod` e a janela
    /// morreu com a câmera sem subir; uma chamada isolada levou 4,7 s). Serial: começar e parar em
    /// ordem.
    private let fila = DispatchQueue(label: "quall.gerador.coreaudio", qos: .userInitiated)

    public init(uid: String) {
        self.uid = uid
    }

    /// **Começa fora da principal, com prazo.** `fim(nil)` subiu; `fim(motivo)` recusou ou não
    /// respondeu em `prazo` segundos — nesse caso o gerador fica **abandonado** (`tocando` falso para
    /// sempre, e se a chamada presa voltar depois, ele para sozinho). `fim` na principal, uma vez.
    public func comecarForaDaMain(prazo: Double = 10, fim: @escaping (String?) -> Void) {
        let t0 = Date()
        var respondido = false
        let responder: (String?) -> Void = { r in
            DispatchQueue.main.async {
                guard !respondido else { return }
                respondido = true
                fim(r)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + prazo) { [weak self] in
            guard !respondido else { return }
            self?.trava.withLock { self?._abandonado = true }
            self?.aoRegistrar?("o gerador de tom não respondeu em \(Int(prazo)) s (o coreaudiod preso?): "
                               + "abandonado; o microfone fica fechado (o laço não está fechado)")
            responder("o coreaudiod não respondeu em \(Int(prazo)) s ao abrir \(self?.uid ?? "?")")
        }
        fila.async { [weak self] in
            guard let self else { return }
            let r = self.comecarNaFila()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if self.trava.withLock({ self._abandonado }) {
                // Voltou depois do prazo: ninguém conta com ele.
                if r == nil { self.pararNaFila() }
                self.aoRegistrar?("o gerador voltou depois do prazo (\(ms) ms) e foi parado")
                return
            }
            if r == nil { self.aoRegistrar?("o gerador subiu em \(ms) ms (fora da principal)") }
            responder(r)
        }
    }

    /// Para, fora da principal. `fim` (opcional) na principal.
    public func pararForaDaMain(fim: (() -> Void)? = nil) {
        fila.async { [weak self] in
            self?.pararNaFila()
            if let fim { DispatchQueue.main.async(execute: fim) }
        }
    }

    /// Começa a tocar. **Só na `fila`.** Devolve o motivo da recusa, ou `nil` se subiu.
    private func comecarNaFila() -> String? {
        guard !trava.withLock({ _tocando }) else { return nil }
        guard let id = DispositivosDeAudio.id(doUID: uid) else {
            return "o dispositivo \(uid) não existe agora"
        }
        let transporte = DispositivosDeAudio.transporte(de: id)
        guard transporte == AparelhoDeAudio.virtual else {
            return "o dispositivo \(uid) tem transporte \(AparelhoDeAudio.nome(doTransporte: transporte)): "
                + "o gerador só toca num dispositivo virtual"
        }
        if DispositivosDeAudio.saidaPadrao() == id {
            return "o dispositivo \(uid) é a SAÍDA PADRÃO do sistema: tudo o que toca iria para o microfone de "
                + "laço. Troque a saída padrão em Ajustes → Som antes de correr"
        }
        if DispositivosDeAudio.saidaDeEfeitos() == id {
            return "o dispositivo \(uid) é a SAÍDA DE EFEITOS do sistema: os sons do sistema iriam para o "
                + "microfone de laço. Troque em Ajustes → Som → Efeitos sonoros antes de correr"
        }
        // A saída do motor vai **para este dispositivo**, e não para a saída padrão.
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(id)
        } catch {
            return "o motor de áudio recusou o dispositivo \(uid): \(error.localizedDescription)"
        }
        let saida = engine.outputNode.inputFormat(forBus: 0)
        guard saida.sampleRate > 0, saida.channelCount > 0,
              let formato = AVAudioFormat(standardFormatWithSampleRate: saida.sampleRate,
                                          channels: saida.channelCount) else {
            return "o dispositivo \(uid) não expôs um formato utilizável"
        }
        let taxa = saida.sampleRate
        var n: Int64 = 0
        let no = AVAudioSourceNode(format: formato) { _, _, quadros, lista in
            let buffers = UnsafeMutableAudioBufferListPointer(lista)
            for q in 0..<Int(quadros) {
                let v = TomDeQuatroNotas.amostra(n, taxaHz: taxa)
                n &+= 1
                for b in buffers {
                    guard let dados = b.mData else { continue }
                    dados.assumingMemoryBound(to: Float.self)[q] = v
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
            return "o motor de áudio não iniciou no dispositivo \(uid): \(error.localizedDescription)"
        }
        fonte = no
        trava.withLock { _tocando = true }
        aoRegistrar?(String(format: "tom de quatro notas tocando na saída de \"%@\" (uid=%@) a %.0f Hz × %u; ",
                            DispositivosDeAudio.nome(de: id) ?? "?", uid, taxa, saida.channelCount)
                     + DispositivosDeAudio.relatoDasSaidas())
        return nil
    }

    private func pararNaFila() {
        guard trava.withLock({ _tocando }) else { return }
        engine.stop()
        if let fonte { engine.detach(fonte) }
        fonte = nil
        trava.withLock { _tocando = false }
        aoRegistrar?("tom de quatro notas parado; " + DispositivosDeAudio.relatoDasSaidas())
    }
}
