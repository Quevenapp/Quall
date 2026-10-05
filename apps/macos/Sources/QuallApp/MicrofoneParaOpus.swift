import AVFoundation
import CoreMedia
import CQuall
import Foundation
import QuallCaptureKit
import QuallNetKit

/// **Do `CMSampleBuffer` do microfone ao pacote Opus carimbado**, uma instância por sessão de câmera
/// (R5 fase 4 no Mac; o do iOS é `apps/ios/Quall/App/MicrofoneParaOpus.swift`, §8.4).
///
/// O dono entrega cada buffer **já no relógio da câmera** (`DonoDaCamera`, `CMSyncConvertTime`), e o
/// vídeo vai ao núcleo com o PTS da câmera em µs (`MonotonicClock.microseconds`, na
/// `TransmissaoAoVivo`): o som vai pela mesma conta, e **o carimbo é o da captura, não o do envio**.
///
/// 1. **Reamostragem** para o preset do núcleo (48 kHz mono) por `AVAudioConverter`, refeito quando o
///    formato de entrada muda (outro aparelho, outra taxa). `primeMethod = .normal`: a conta do
///    carimbo supõe latência zero no conversor (a claquete mediria o que sobrar; no Mac ela não roda,
///    G4).
/// 2. **A disciplina do carimbo** (`DisciplinaDoMicrofone`, pura e testada): um quadro, 20 000 µs;
///    a correção de uma amostra por vez; degrau para a frente; nunca para trás.
/// 3. **Opus pelo núcleo** (`EncoderDeAudioDoNucleo`), e `quall_track_send_audio` um pacote por
///    chamada.
///
/// **Uma thread só**: a fila do áudio do dono (o Opus é preditivo). Os contadores têm trava própria,
/// para o relato.
final class MicrofoneParaOpus: @unchecked Sendable {
    private let encoder: EncoderDeAudioDoNucleo
    private let enviar: (UnsafeRawBufferPointer, UInt64) -> Bool
    private var disciplina: DisciplinaDoMicrofone
    private let formatoDeSaida: AVAudioFormat
    private var formatoDeEntrada: AVAudioFormat?
    private var conversor: AVAudioConverter?
    private var assinatura = ""
    private var taxaDeEntrada: Double = 0

    private let trava = NSLock()
    private var _enviados: UInt64 = 0
    private var _recusados: UInt64 = 0
    private var _falhasDoEncoder: UInt64 = 0
    private var _buffers: UInt64 = 0
    private var _entrada = "nenhuma"
    private var _contadores = DisciplinaDoMicrofone.Contadores()
    /// O relato leu o erro máximo: a fila do áudio zera o da disciplina no próximo buffer.
    private var _zerarMaximo = false

    /// `nil` quando o núcleo recusa o preset ou o encoder (o motivo vai ao diário por quem chama:
    /// `EncoderDeAudioDoNucleo.ultimoErro`).
    init?(enviar: @escaping (UnsafeRawBufferPointer, UInt64) -> Bool) {
        guard let e = EncoderDeAudioDoNucleo(),
              let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(e.taxaHz),
                                      channels: 1, interleaved: true) else { return nil }
        encoder = e
        formatoDeSaida = fmt
        self.enviar = enviar
        disciplina = DisciplinaDoMicrofone(amostrasPorQuadro: e.amostrasPorQuadro, taxaDeSaida: Double(e.taxaHz))
    }

    var resumoDoPreset: String { encoder.resumo }

    /// Um buffer do dono. **Só da fila do áudio do dono.**
    func consumir(_ amostra: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(amostra),
              let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let n = CMSampleBufferGetNumSamples(amostra)
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(amostra))
        guard n > 0, pts.isFinite, pts > 0 else { return }
        let asbd = asbdP.pointee
        let a = "\(asbd.mSampleRate)|\(asbd.mChannelsPerFrame)|\(asbd.mFormatID)|\(asbd.mFormatFlags)|\(asbd.mBitsPerChannel)"
        if a != assinatura {
            let f = AVAudioFormat(cmAudioFormatDescription: desc)
            // **Só um formato de verdade diferente refaz o conversor** (a prova de 25/09 no BlackHole:
            // "entrada: 48000 Hz 2 ch 32 bits float" saía duas vezes em 11 ms a cada abertura — os
            // campos crus do ASBD mudavam entre o primeiro buffer e os seguintes sem o formato mudar,
            // hipótese: os bits de alinhamento das flags). Com o mesmo `AVAudioFormat`, só a
            // assinatura crua é atualizada, e a fila e o carimbo seguem.
            if let atual = formatoDeEntrada, atual.isEqual(f) {
                Registro.compartilhado.linha("APP MICROFONE entrada: o ASBD cru mudou sem o formato mudar "
                                             + "(flags 0x\(String(asbd.mFormatFlags, radix: 16)), antes \(assinatura)); o conversor fica")
                assinatura = a
            } else {
                refazerConversor(f, asbd: asbd, n: n, assinatura: a)
            }
        }
        guard let formatoDeEntrada, let conversor, taxaDeEntrada > 0 else { return }
        consumirConvertendo(amostra, pts: pts, n: n, formatoDeEntrada: formatoDeEntrada, conversor: conversor)
    }

    private func refazerConversor(_ f: AVAudioFormat, asbd: AudioStreamBasicDescription, n: Int, assinatura a: String) {
        do { // (escopo só; nada lança aqui)
            guard let c = AVAudioConverter(from: f, to: formatoDeSaida) else {
                Registro.compartilhado.linha("APP MICROFONE !! AVAudioConverter recusou \(f) → \(formatoDeSaida)")
                return
            }
            // Mais de um canal (um dispositivo de laço estéreo, um microfone de dois canais): a
            // mistura, e não o primeiro.
            c.downmix = true
            c.primeMethod = .normal
            formatoDeEntrada = f
            conversor = c
            taxaDeEntrada = asbd.mSampleRate
            assinatura = a
            disciplina.recomecar()
            let rotulo = "\(Int(asbd.mSampleRate)) Hz \(asbd.mChannelsPerFrame) ch \(asbd.mBitsPerChannel) bits"
                + ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? " float" : "")
            trava.withLock { _entrada = rotulo }
            Registro.compartilhado.linha("APP MICROFONE entrada: \(rotulo) flags=0x\(String(asbd.mFormatFlags, radix: 16)), "
                                         + "\(n) amostras por buffer → \(encoder.taxaHz) Hz mono em quadros de \(encoder.amostrasPorQuadro)")
        }
    }

    private func consumirConvertendo(_ amostra: CMSampleBuffer, pts: Double, n: Int,
                                     formatoDeEntrada: AVAudioFormat, conversor: AVAudioConverter) {
        if trava.withLock({ defer { _zerarMaximo = false }; return _zerarMaximo }) { disciplina.zerarErroMaximo() }
        if disciplina.conferirContinuidade(pts: pts, taxaDeEntrada: taxaDeEntrada) {
            conversor.reset()
            Registro.compartilhado.linha("APP MICROFONE descontinuidade: a fila recomeça e o carimbo reancora para a frente")
        }
        guard let entrada = AVAudioPCMBuffer(pcmFormat: formatoDeEntrada, frameCapacity: AVAudioFrameCount(n)) else { return }
        // **`frameLength` antes da cópia** (a armadilha da revisão do iOS, §8.4): com 0, a cópia é
        // recusada.
        entrada.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(amostra, at: 0, frameCount: Int32(n),
                                                           into: entrada.mutableAudioBufferList) == noErr else { return }
        let capacidade = AVAudioFrameCount(Double(n) * Double(encoder.taxaHz) / taxaDeEntrada) + 64
        guard let saida = AVAudioPCMBuffer(pcmFormat: formatoDeSaida, frameCapacity: capacidade) else { return }
        var entregue = false
        var erro: NSError?
        let estado = conversor.convert(to: saida, error: &erro) { _, situacao in
            if entregue { situacao.pointee = .noDataNow; return nil }
            entregue = true
            situacao.pointee = .haveData
            return entrada
        }
        guard estado != .error, let canal = saida.int16ChannelData else { return }
        let m = Int(saida.frameLength)
        disciplina.acrescentar(pts: pts, amostrasDeEntrada: n, taxaDeEntrada: taxaDeEntrada,
                               convertidas: m > 0 ? Array(UnsafeBufferPointer(start: canal[0], count: m)) : [])
        var enviados: UInt64 = 0, recusados: UInt64 = 0, falhas: UInt64 = 0
        while let q = disciplina.proximoQuadro() {
            guard q.carimboUs > 0 else { falhas &+= 1; continue }
            let r = encoder.codificar(q.quadro) { pacote in enviar(pacote, UInt64(q.carimboUs)) }
            switch r {
            case .some(true): enviados &+= 1
            case .some(false): recusados &+= 1
            case .none: falhas &+= 1
            }
        }
        let c = disciplina.contadores
        trava.withLock {
            _buffers &+= 1
            _enviados &+= enviados
            _recusados &+= recusados
            _falhasDoEncoder &+= falhas
            _contadores = c
        }
    }

    /// Uma linha para o relato de 10 s e para o fim. `erro_max` zera a cada leitura.
    func resumo() -> String {
        let (e, env, rec, fal, buf, c) = trava.withLock {
            _zerarMaximo = true
            return (_entrada, _enviados, _recusados, _falhasDoEncoder, _buffers, _contadores)
        }
        return "entrada=\(e) buffers=\(buf) quadros=\(c.quadros) enviados=\(env) recusados=\(rec) falhas_encoder=\(fal)"
            + " descontinuidades=\(c.descontinuidades) degraus=\(c.degraus) cortes=\(c.cortes)"
            + " inseridas=\(c.inseridas) tiradas=\(c.tiradas)"
            + String(format: " erro=%.0f us erro_max=%.0f us", c.erroUs, c.erroMaximoUs)
    }
}
