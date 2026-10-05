#if COM_NUCLEO
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox em H.264 baseline, dentro da Broadcast Upload Extension.
///
/// É irmão do `H264Encoder` do macOS (`apps/macos/Sources/QuallCaptureKit/H264Encoder.swift`) e
/// nasceu dele, mas **não** é o mesmo código, por três diferenças que não são cosméticas:
///
/// 1. **Teto de 720x1280.** O `PERFIL_H264` que o núcleo anuncia no SDP é
///    `profile-level-id=42e028` — baseline, nível 4.0, que comporta 1920x1080 a 30 fps. Os
///    750x1334 nativos do iPhone 7 já violam esse nível (ver dívida 16). A sessão é criada nas
///    dimensões de destino e o VideoToolbox escala o `CVPixelBuffer` de entrada; o resultado é
///    **conferido** na format description da saída, e não assumido.
/// 2. **Sem `Data`.** O caminho AVCC → Annex-B escreve num buffer reaproveitado, alocado uma vez
///    e crescido geometricamente. Um `Data` novo por quadro seriam 10 800 alocações em seis
///    minutos, e elas apareceriam na medição como se fossem crescimento do núcleo. O que se
///    quer medir é o churn da libdatachannel, não o meu.
/// 3. **Teto de quadros em voo.** "Empacota e solta" vale para o encoder também: se o A10 não
///    acompanhar, a casca descarta em vez de deixar o VideoToolbox enfileirar dentro dos 50 MB.
final class CodificadorH264 {

    /// O buffer entregue vale **só durante a chamada** — mesma regra da fronteira C do núcleo.
    typealias Saida = (UnsafeRawBufferPointer, CMTime, Bool) -> Void

    enum Falha: Error, CustomStringConvertible {
        case sessaoNaoCriou(OSStatus)
        var description: String {
            switch self {
            case .sessaoNaoCriou(let s): return "VTCompressionSessionCreate falhou: \(s)"
            }
        }
    }

    private let sessao: VTCompressionSession
    /// `"sim"`, `"nao"` ou `"nao-consultavel"`.
    ///
    /// As três chaves que respondem isso — `EnableHardwareAcceleratedVideoEncoder`,
    /// `RequireHardwareAcceleratedVideoEncoder` e
    /// `UsingHardwareAcceleratedVideoEncoder` — **só existem no iOS a partir do 17.4**; no
    /// macOS existem desde sempre, e é por isso que o encoder do macOS as usa e este não pode.
    /// No iPhone 7 (iOS 15.8) a resposta honesta é "não consultável": o iOS não expõe encoder
    /// H.264 por software, mas afirmar hardware sem poder perguntar seria repetir o erro que
    /// este projeto já corrigiu — conclusão provável, argumento inexistente.
    let porHardware: String
    let largura: Int32
    let altura: Int32

    private let travaDoBuffer = NSLock()
    /// Reescreve o SPS para declarar que aqui não se reordena quadro. Ver `RemendoDeSPS`.
    let remendoDeSPS = RemendoDeSPS()
    private var buffer: UnsafeMutableRawPointer
    private var capacidade: Int
    /// Quanto o buffer de conversão nasceu valendo. Sai no log para que o orçamento de memória
    /// tenha esse número na conta em vez de tê-lo escondido.
    private(set) var capacidadeInicial: Int = 0

    private let travaDoVoo = NSLock()
    private var emVoo = 0
    private let tetoEmVoo: Int

    private(set) var descartadosPorFila: UInt64 = 0
    private(set) var descartadosPeloEncoder: UInt64 = 0
    /// Quantas vezes o buffer de conversão precisou crescer. Em regime tem de ser **zero**: se
    /// não for, cada crescimento é uma alocação de megabytes no meio da medição, e o número que
    /// se estaria medindo passaria a ser o meu, não o do núcleo.
    private(set) var crescimentosDoBuffer = 0
    private var _maiorQuadro: Int = 0
    /// Dimensão que a **saída** declarou, não a que foi pedida. Ver o item 1 do cabeçalho.
    private var _dimensaoDaSaida = "?"

    /// Lidos pelo relatório de 1 Hz, escritos na thread de saída do VideoToolbox: passam pela
    /// mesma trava do buffer. Uma `String` lida sem trava enquanto outra thread a substitui é
    /// crash, não número errado.
    var maiorQuadro: Int {
        travaDoBuffer.lock(); defer { travaDoBuffer.unlock() }
        return _maiorQuadro
    }
    var dimensaoDaSaida: String {
        travaDoBuffer.lock(); defer { travaDoBuffer.unlock() }
        return _dimensaoDaSaida
    }

    var aoSair: Saida?

    init(largura: Int32, altura: Int32, fps: Int32, bitrate: Int, tetoEmVoo: Int) throws {
        self.largura = largura
        self.altura = altura
        self.tetoEmVoo = max(1, tetoEmVoo)
        // Capacidade derivada do teto de bitrate, não chutada: um IDR em rajada cabe em ~1 s de
        // bitrate alvo, e o dobro disso ainda é ruído contra 46,6 MB. O piso de 1 MB existe
        // porque um bitrate baixo não muda o tamanho de um IDR de tela cheia.
        self.capacidade = max(1024 * 1024, (bitrate / 8) * 2)
        self.capacidadeInicial = self.capacidade
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacidade, alignment: 16)

        var criada: VTCompressionSession?
        let estado = VTCompressionSessionCreate(
            allocator: nil, width: largura, height: altura,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &criada)
        guard estado == noErr, let sessao = criada else {
            buffer.deallocate()
            throw Falha.sessaoNaoCriou(estado)
        }
        self.sessao = sessao

        func por(_ chave: CFString, _ valor: CFTypeRef) {
            VTSessionSetProperty(sessao, key: chave, value: valor)
        }
        // Preset de tela do contrato: zero filas, sem reordenamento (sem B-frames), baseline —
        // o denominador comum entre as quatro plataformas — e GOP de ~1 s, para que uma mudança
        // brusca não fique presa esperando o próximo IDR agendado.
        por(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        por(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        por(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        // Sem isto o VideoToolbox **retém buffers de entrada por construção**, e o modo de morte
        // não é vazamento lento: é rajada. Basta o envio passar de um intervalo de quadro uma
        // vez — throttle térmico do A10, retransmissão do Wi-Fi — para a fila de entrada
        // estourar dentro de um orçamento de 50 MB. Um quadro de atraso é o mínimo aceito.
        por(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1))
        por(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        por(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))
        por(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        por(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(sessao)

        if #available(iOS 17.4, *) {
            var usaHardware: CFTypeRef?
            VTSessionCopyProperty(
                sessao,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil, valueOut: &usaHardware)
            self.porHardware = ((usaHardware as? Bool) ?? false) ? "sim" : "nao"
        } else {
            self.porHardware = "nao-consultavel"
        }
    }

    deinit {
        VTCompressionSessionInvalidate(sessao)
        buffer.deallocate()
    }

    func encerrar() {
        VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
    }

    /// Submete um quadro. Devolve `false` quando descartou por fila cheia — que é
    /// comportamento certo, não erro.
    @discardableResult
    func encodar(_ imagem: CVPixelBuffer, pts: CMTime, duracao: CMTime, forcarIDR: Bool) -> Bool {
        travaDoVoo.lock()
        if emVoo >= tetoEmVoo {
            descartadosPorFila += 1
            travaDoVoo.unlock()
            return false
        }
        emVoo += 1
        travaDoVoo.unlock()

        let propriedades: CFDictionary? = forcarIDR
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil

        // O sinal de vídeo é lido aqui, do buffer que está sendo submetido: o callback não recebe
        // o pixel buffer, e a format description comprimida do VideoToolbox não propaga faixa nem
        // cor quando a origem é `420v` — medido em 2026-08-24.
        let sinal = RemendoDeSPS.SinalDeVideo.doPixelBuffer(imagem)

        let estado = VTCompressionSessionEncodeFrame(
            sessao, imageBuffer: imagem, presentationTimeStamp: pts, duration: duracao,
            frameProperties: propriedades, infoFlagsOut: nil
        ) { [weak self] estado, sinalizadores, amostra in
            guard let self else { return }
            defer {
                self.travaDoVoo.lock(); self.emVoo -= 1; self.travaDoVoo.unlock()
            }
            guard estado == noErr, !sinalizadores.contains(.frameDropped), let amostra,
                  CMSampleBufferGetNumSamples(amostra) > 0
            else {
                self.descartadosPeloEncoder += 1
                return
            }
            self.entregar(amostra, pts: pts, sinal: sinal)
        }
        if estado != noErr {
            travaDoVoo.lock(); emVoo -= 1; travaDoVoo.unlock()
            descartadosPeloEncoder += 1
            return false
        }
        return true
    }

    // --- AVCC → Annex-B, num buffer reaproveitado ----------------------------------------

    private func entregar(_ amostra: CMSampleBuffer, pts: CMTime,
                          sinal: RemendoDeSPS.SinalDeVideo?) {
        let chave = CodificadorH264.eQuadroChave(amostra)
        guard let blocos = CMSampleBufferGetDataBuffer(amostra) else { return }

        var total = 0
        var dados: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blocos, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &dados) == noErr,
              let dados else { return }

        travaDoBuffer.lock()
        defer { travaDoBuffer.unlock() }

        if _dimensaoDaSaida == "?", let formato = CMSampleBufferGetFormatDescription(amostra) {
            let d = CMVideoFormatDescriptionGetDimensions(formato)
            _dimensaoDaSaida = "\(d.width)x\(d.height)"
        }

        var escrito = 0

        // Todo IDR leva SPS e PPS junto — sem isso quem entra na sessão depois fica sem imagem,
        // que é exatamente o defeito medido no Windows no M1 e o que
        // `idrs_without_parameters` denuncia do lado do núcleo.
        if chave, let formato = CMSampleBufferGetFormatDescription(amostra) {
            var quantos = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formato, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &quantos,
                nalUnitHeaderLengthOut: nil)
            for i in 0..<quantos {
                var ponteiro: UnsafePointer<UInt8>?
                var tamanho = 0
                let e = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formato, parameterSetIndex: i, parameterSetPointerOut: &ponteiro,
                    parameterSetSizeOut: &tamanho, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                guard e == noErr, let ponteiro else { continue }
                // O SPS sai reescrito para **declarar** que este encoder não reordena quadro; sem
                // isso o decodificador do outro lado infere o teto do nível e empilha até nove
                // quadros antes de entregar o primeiro. Ver `RemendoDeSPS`.
                if (ponteiro[0] & 0x1F) == 7 {
                    let novo = remendoDeSPS.spsParaEnviar(
                        UnsafeRawBufferPointer(start: ponteiro, count: tamanho), sinal: sinal)
                    garantir(escrito + 4 + novo.count)
                    escreverInicio(em: escrito); escrito += 4
                    novo.withUnsafeBytes { (buffer + escrito).copyMemory(from: $0.baseAddress!, byteCount: novo.count) }
                    escrito += novo.count
                    continue
                }
                garantir(escrito + 4 + tamanho)
                escreverInicio(em: escrito); escrito += 4
                (buffer + escrito).copyMemory(from: ponteiro, byteCount: tamanho)
                escrito += tamanho
            }
        }

        dados.withMemoryRebound(to: UInt8.self, capacity: total) { bytes in
            var deslocamento = 0
            while deslocamento + 4 <= total {
                let tamanho = (Int(bytes[deslocamento]) << 24) | (Int(bytes[deslocamento + 1]) << 16)
                    | (Int(bytes[deslocamento + 2]) << 8) | Int(bytes[deslocamento + 3])
                deslocamento += 4
                guard tamanho > 0, deslocamento + tamanho <= total else { break }
                garantir(escrito + 4 + tamanho)
                escreverInicio(em: escrito); escrito += 4
                (buffer + escrito).copyMemory(from: bytes + deslocamento, byteCount: tamanho)
                escrito += tamanho
                deslocamento += tamanho
            }
        }

        guard escrito > 0 else { return }
        if escrito > _maiorQuadro { _maiorQuadro = escrito }
        aoSair?(UnsafeRawBufferPointer(start: buffer, count: escrito), pts, chave)
    }

    private func escreverInicio(em posicao: Int) {
        let p = (buffer + posicao).assumingMemoryBound(to: UInt8.self)
        p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 1
    }

    /// Cresce geometricamente e só cresce: em regime não realoca nunca, que é o ponto.
    private func garantir(_ preciso: Int) {
        guard preciso > capacidade else { return }
        crescimentosDoBuffer += 1
        var nova = capacidade
        while nova < preciso { nova *= 2 }
        let novo = UnsafeMutableRawPointer.allocate(byteCount: nova, alignment: 16)
        novo.copyMemory(from: buffer, byteCount: capacidade)
        buffer.deallocate()
        buffer = novo
        capacidade = nova
    }

    /// Convenção do VideoToolbox: sem o attachment `NotSync` (ou com ele em `false`), é sync
    /// sample — isto é, IDR.
    static func eQuadroChave(_ amostra: CMSampleBuffer) -> Bool {
        guard let lista = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false)
                as? [[CFString: Any]], let primeiro = lista.first
        else { return true }
        return !((primeiro[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }
}
#endif
