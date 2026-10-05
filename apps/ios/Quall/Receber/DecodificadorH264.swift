import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decode H.264 em hardware no iPad, com o custo de cada quadro medido.
///
/// Porte do `DecodificadorH264` de `integrations/camera-macos`, que é o único VideoToolbox
/// **decodificando** que existia nesta família — em `apps/ios` inteiro não havia nenhum. As
/// diferenças em relação ao original são de plataforma e de propósito, e são três:
///
/// 1. **Sem `IOSurface` obrigatório por outro motivo.** No macOS o atributo existe porque o quadro
///    precisa atravessar para o processo da extensão do CoreMediaIO. Aqui ele continua ligado, mas
///    por outra razão: sem `IOSurface` a `AVSampleBufferDisplayLayer` acaba copiando o buffer para
///    poder compor, e a cópia por quadro a 30 fps aparece na CPU.
/// 2. **Descrição de formato guardada com o SPS/PPS que a gerou.** O original recria a sessão
///    quando o par muda; aqui a comparação é a mesma, e o motivo é o que o receptor Android achou:
///    alimentar o decodificador com um quadro P antes de qualquer SPS é o caminho conhecido para
///    travá-lo de vez.
/// 3. **`recusados` é separado de `semParametros`.** "Chegou quadro e o decodificador recusou" e
///    "chegou quadro antes de existir decodificador" são duas coisas, e somá-las esconde
///    exatamente a metade das corridas em que o primeiro quadro se perde (dívida 25).
final class DecodificadorH264 {
    private var sessao: VTDecompressionSession?
    private var descricao: CMFormatDescription?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private let aoQuadro: (CVPixelBuffer, UInt64) -> Void

    /// Contadores de instrumento, com trava própria — a mesma regra que o `Nucleo` do emissor
    /// adotou: *contador de instrumento é atômico ou tem trava própria; a leitura tem direito a
    /// número velho, jamais a espera*.
    private let travaDoRelato = NSLock()
    private var _recebidos: UInt64 = 0
    private var _decodificados: UInt64 = 0
    private var _recusados: UInt64 = 0
    private var _semParametros: UInt64 = 0
    private var _idrsRecebidos: UInt64 = 0
    private var _sessoesCriadas: UInt64 = 0
    /// Quantas vezes `CMVideoFormatDescriptionCreateFromH264ParameterSets` recusou o par SPS/PPS,
    /// e quantas vezes `VTDecompressionSessionCreate` recusou a descrição que saiu dela.
    ///
    /// **Estes dois contadores existem porque a ausência deles mentia.** Sem eles, os dois
    /// fracassos voltavam por um `return` calado, `sessao` continuava `nil`, e **todo quadro
    /// seguinte era contado em `semParametros`** — que se lê como "o emissor não mandou SPS/PPS".
    /// O sintoma medido na bancada era exatamente esse: `frames_ready` subindo, 100% dos quadros
    /// `sem_parametros`, `exibidos 0`, `decode p50 0,00 ms`. Isso manda quem investiga para o
    /// emissor, que pode estar mandando os parâmetros certos — e o defeito estar aqui, na
    /// recusa do VideoToolbox a montar a sessão.
    private var _falhasDeDescricao: UInt64 = 0
    private var _falhasDeSessao: UInt64 = 0
    /// O `OSStatus` da última recusa, seja de qual das duas for. É o número que diz *por quê*.
    private var _ultimaFalha: OSStatus = 0
    private var custos: [UInt64] = []
    private var _largura: Int32 = 0
    private var _altura: Int32 = 0
    private var _perfil = ""

    init(aoQuadro: @escaping (CVPixelBuffer, UInt64) -> Void) {
        self.aoQuadro = aoQuadro
        custos.reserveCapacity(4096)
    }

    deinit { fechar() }

    /// Espera os quadros assíncronos saírem e invalida. Chamável só depois de o tratador de quadro
    /// do núcleo já estar desregistrado — senão um quadro em voo entraria numa sessão morta.
    func fechar() {
        guard let s = sessao else { return }
        sessao = nil
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        VTDecompressionSessionInvalidate(s)
    }

    struct Instantaneo {
        var recebidos: UInt64 = 0
        var decodificados: UInt64 = 0
        var recusados: UInt64 = 0
        var semParametros: UInt64 = 0
        var idrsRecebidos: UInt64 = 0
        var sessoesCriadas: UInt64 = 0
        var falhasDeDescricao: UInt64 = 0
        var falhasDeSessao: UInt64 = 0
        var ultimaFalha: OSStatus = 0
        var largura: Int32 = 0
        var altura: Int32 = 0
        var perfil = ""
        var n = 0
        var p50Us: UInt64 = 0
        var p95Us: UInt64 = 0
        var maxUs: UInt64 = 0
    }

    func instantaneo() -> Instantaneo {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        let p = Medidas.percentis(custos)
        return Instantaneo(recebidos: _recebidos, decodificados: _decodificados,
                           recusados: _recusados, semParametros: _semParametros,
                           idrsRecebidos: _idrsRecebidos, sessoesCriadas: _sessoesCriadas,
                           falhasDeDescricao: _falhasDeDescricao,
                           falhasDeSessao: _falhasDeSessao, ultimaFalha: _ultimaFalha,
                           largura: _largura, altura: _altura, perfil: _perfil,
                           n: p.n, p50Us: p.p50, p95Us: p.p95, maxUs: p.max)
    }

    // --- entrada -----------------------------------------------------------------------------

    /// Recebe um quadro Annex-B completo do núcleo. **O ponteiro vale só durante a chamada** e esta
    /// função roda numa thread da libdatachannel: nada aqui pode bloquear.
    func alimentar(annexb: UnsafeRawBufferPointer, timestampUs: UInt64, idr: Bool) {
        travaDoRelato.lock()
        _recebidos &+= 1
        if idr { _idrsRecebidos &+= 1 }
        travaDoRelato.unlock()

        var vcl: [(Int, Int)] = []   // (deslocamento, tamanho) de cada NAL de imagem
        var novoSps: [UInt8]?
        var novoPps: [UInt8]?

        percorrerNals(annexb) { inicio, tamanho in
            let tipo = annexb[inicio] & 0x1F
            switch tipo {
            case 7: novoSps = Array(UnsafeRawBufferPointer(rebasing: annexb[inicio..<(inicio + tamanho)]))
            case 8: novoPps = Array(UnsafeRawBufferPointer(rebasing: annexb[inicio..<(inicio + tamanho)]))
            case 1, 5: vcl.append((inicio, tamanho))
            default: break
            }
        }

        // **Sem sessão, todo IDR tenta de novo** (o M9 da crítica de 21/09): o par é guardado antes
        // de a sessão nascer, e uma recusa do VideoToolbox deixava os IDR seguintes com o mesmo
        // par sem tentar — a imagem parava até o SPS mudar. Com a troca de tamanho no meio da
        // sessão virando rotina, uma recusa única na troca congelaria a tela até a troca seguinte.
        if let novoSps, let novoPps, novoSps != sps || novoPps != pps || sessao == nil {
            sps = novoSps
            pps = novoPps
            recriarSessao()
        }

        guard let sessao, let descricao else {
            // Quadro antes de qualquer SPS. **Descartar é a única coisa correta**: alimentar o
            // decodificador com um quadro P sem parâmetros é o caminho conhecido para travá-lo de
            // vez (achado do receptor Windows no M2, repetido pelo Android).
            travaDoRelato.lock(); _semParametros &+= 1; travaDoRelato.unlock()
            return
        }
        guard !vcl.isEmpty else { return }

        // Annex-B -> AVCC: os start codes viram prefixos de tamanho de 4 bytes, big-endian.
        var carga = [UInt8]()
        carga.reserveCapacity(annexb.count + 8)
        for (inicio, tamanho) in vcl {
            let n = UInt32(tamanho).bigEndian
            withUnsafeBytes(of: n) { carga.append(contentsOf: $0) }
            carga.append(contentsOf: UnsafeRawBufferPointer(rebasing: annexb[inicio..<(inicio + tamanho)]))
        }

        // `carga` é uma variável local que sobrevive até o fim desta função, e
        // `VTDecompressionSessionDecodeFrame` com `_EnableAsynchronousDecompression` **volta antes
        // de terminar** — mas ela só volta depois de ter copiado ou retido o bloco, porque o
        // `CMBlockBuffer` abaixo é criado com `kCFAllocatorNull` e o VideoToolbox retém o sample
        // buffer. Para não depender dessa leitura, a chamada fica dentro do
        // `withUnsafeMutableBytes` **e** a sessão é esperada em `fechar()` antes de qualquer
        // desmonte. Copiar aqui seria mais uma cópia por quadro num caminho que já tem oito.
        carga.withUnsafeMutableBytes { p in
            guard let base = p.baseAddress else { return }
            var bloco: CMBlockBuffer?
            let criou = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: base, blockLength: p.count,
                blockAllocator: kCFAllocatorNull, customBlockSource: nil,
                offsetToData: 0, dataLength: p.count, flags: 0, blockBufferOut: &bloco)
            guard criou == noErr, let bloco else {
                travaDoRelato.lock(); _recusados &+= 1; travaDoRelato.unlock()
                return
            }

            var amostra: CMSampleBuffer?
            var tamanho = p.count
            var tempo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMTime(value: CMTimeValue(timestampUs), timescale: 1_000_000),
                decodeTimeStamp: .invalid)
            let fez = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: descricao,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &tempo,
                sampleSizeEntryCount: 1, sampleSizeArray: &tamanho, sampleBufferOut: &amostra)
            guard fez == noErr, let amostra else {
                travaDoRelato.lock(); _recusados &+= 1; travaDoRelato.unlock()
                return
            }

            // O instante da submissão viaja como **valor** no `sourceFrameRefCon`, que nunca é
            // dereferenciado. Evita uma alocação por quadro só para medir latência de decode.
            let submissao = Medidas.agoraUs()
            let marca = UnsafeMutableRawPointer(bitPattern: UInt(submissao))
            var saida = VTDecodeInfoFlags()
            // Síncrono de propósito, ao contrário do original do macOS: com
            // `_EnableAsynchronousDecompression` a chamada volta antes de o VideoToolbox ter
            // acabado com o `CMBlockBuffer`, que aqui aponta para memória de pilha desta função.
            // O custo é que o decode entra no tempo do tratador — e o tratador não pode bloquear,
            // porque a barreira do `close` desiste em 2 s. O decode medido no iPad fica em
            // milissegundos, três ordens de grandeza abaixo desse teto.
            let estado = VTDecompressionSessionDecodeFrame(
                sessao, sampleBuffer: amostra, flags: [._1xRealTimePlayback],
                frameRefcon: marca, infoFlagsOut: &saida)
            if estado != noErr {
                travaDoRelato.lock(); _recusados &+= 1; travaDoRelato.unlock()
            }
        }
    }

    // --- sessão ------------------------------------------------------------------------------

    private func recriarSessao() {
        fechar()

        var nova: CMFormatDescription?
        let estado = sps.withUnsafeBufferPointer { s -> OSStatus in
            pps.withUnsafeBufferPointer { p -> OSStatus in
                let conjuntos = [s.baseAddress!, p.baseAddress!]
                let tamanhos = [s.count, p.count]
                return conjuntos.withUnsafeBufferPointer { cp in
                    tamanhos.withUnsafeBufferPointer { tp in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: cp.baseAddress!, parameterSetSizes: tp.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &nova)
                    }
                }
            }
        }
        // O perfil/nível saem do próprio SPS: byte 1 é `profile_idc`, byte 3 é `level_idc`. É o
        // que permite dizer no relato o que o emissor mandou de verdade, e não o que se supunha.
        //
        // **Lido e guardado antes de qualquer tentativa**, e essa ordem é o conserto: quando a
        // montagem falha é justamente quando se precisa saber que nível o emissor mandou. Guardar
        // só no caminho de sucesso apagava a única pista no exato caso em que ela importa.
        let perfil = sps.count >= 4
            ? "profile_idc=\(sps[1]) level_idc=\(sps[3])"
            : "?"
        travaDoRelato.lock(); _perfil = perfil; travaDoRelato.unlock()

        guard estado == noErr, let nova else {
            travaDoRelato.lock()
            _falhasDeDescricao &+= 1
            _ultimaFalha = estado
            travaDoRelato.unlock()
            return
        }
        descricao = nova

        let dim = CMVideoFormatDescriptionGetDimensions(nova)

        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { eu, refcon, estado, _, imagem, _, _ in
                guard let eu else { return }
                let quem = Unmanaged<DecodificadorH264>.fromOpaque(eu).takeUnretainedValue()
                quem.saiu(estado: estado, imagem: imagem, marca: refcon)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var criada: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: nova, decoderSpecification: nil,
            imageBufferAttributes: atributos as CFDictionary, outputCallback: &callback,
            decompressionSessionOut: &criada)
        guard r == noErr, let criada else {
            // Aqui mora o caso que a bancada procurou o dia inteiro: SPS e PPS **chegaram** e
            // foram aceitos pela descrição, e mesmo assim não há decodificador. Sem este
            // contador, o sintoma vira "sem parâmetros" e a investigação sobe para o emissor.
            travaDoRelato.lock()
            _falhasDeSessao &+= 1
            _ultimaFalha = r
            _largura = dim.width
            _altura = dim.height
            travaDoRelato.unlock()
            return
        }
        VTSessionSetProperty(criada, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        sessao = criada

        travaDoRelato.lock()
        _largura = dim.width
        _altura = dim.height
        _perfil = perfil
        _sessoesCriadas &+= 1
        travaDoRelato.unlock()
    }

    private func saiu(estado: OSStatus, imagem: CVImageBuffer?, marca: UnsafeMutableRawPointer?) {
        guard estado == noErr, let imagem else {
            travaDoRelato.lock(); _recusados &+= 1; travaDoRelato.unlock()
            return
        }
        let submissao = UInt64(UInt(bitPattern: marca))
        let custo = submissao > 0 ? Medidas.delta(Medidas.agoraUs(), submissao) : 0
        travaDoRelato.lock()
        // Teto na amostra: a lista existe para dar percentil, e uma corrida longa não pode fazer
        // o instrumento crescer sem limite dentro do processo que ele mede.
        if custos.count < 100_000 { custos.append(custo) }
        _decodificados &+= 1
        travaDoRelato.unlock()
        aoQuadro(imagem, custo)
    }

    /// Varre os NALs de um quadro Annex-B, aceitando start code de 3 e de 4 bytes.
    private func percorrerNals(_ dados: UnsafeRawBufferPointer, _ visitar: (Int, Int) -> Void) {
        let n = dados.count
        var i = 0
        var inicioDoNal = -1
        while i + 2 < n {
            if dados[i] == 0, dados[i + 1] == 0, dados[i + 2] == 1 {
                if inicioDoNal >= 0 {
                    var fim = i
                    if fim > inicioDoNal, dados[fim - 1] == 0 { fim -= 1 }  // start code de 4 bytes
                    if fim > inicioDoNal { visitar(inicioDoNal, fim - inicioDoNal) }
                }
                i += 3
                inicioDoNal = i
                continue
            }
            i += 1
        }
        if inicioDoNal >= 0, inicioDoNal < n { visitar(inicioDoNal, n - inicioDoNal) }
    }
}
