import CoreMedia
import CoreMediaIO
import Foundation
import os

/// O dispositivo `Quall`, com os dois fluxos:
///
/// - **saída** (`.source`) — o que Zoom, Meet, Chrome e OBS leem;
/// - **entrada** (`.sink`) — por onde o app anfitrião empurra o vídeo que veio da rede.
///
/// Quem manda no ritmo é a entrada: quadro que chega é repassado na hora, sem fila e sem
/// carimbar de novo. O relógio de 30 Hz só existe para o caso de **não** haver entrada — é ele
/// que mantém a câmera viva quando o app não está aberto, que é metade da pergunta de ciclo de
/// vida que esta frente precisava responder.
final class DispositivoQuall: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var descricao: CMFormatDescription!
    private(set) var saida: FluxoDeSaida!
    private(set) var entrada: FluxoDeEntrada!

    private var reservatorio: CVPixelBufferPool?
    private var relogio: DispatchSourceTimer?
    private let fila = DispatchQueue(label: "\(Identidade.idDaExtensao).bomba", qos: .userInteractive)

    private var contador = 0
    /// Estado tocado por **duas** threads: o relógio de 30 Hz corre na `fila` e o repasse corre
    /// numa thread do CoreMediaIO. Sem esta trava, "faz quanto tempo que não chega quadro?" é
    /// corrida de dados de verdade — e o sintoma seria a placa de espera piscando por cima do
    /// vídeo, que ninguém atribuiria a isto.
    private let travaDoEstado = NSLock()
    private var enviados: UInt64 = 0
    private var consumidos: UInt64 = 0
    private var ultimoDaEntradaNs: UInt64 = 0
    private var jaVeioAlgoDaEntrada = false
    private var clientesNaSaida = 0

    /// Custo por quadro do caminho entrada → saída, em microssegundos. Sem alocar: soma e conta.
    private var somaDoRepasseUs: UInt64 = 0
    private var contagemDoRepasse: UInt64 = 0
    private var piorRepasseUs: UInt64 = 0

    override init() {
        super.init()

        device = CMIOExtensionDevice(localizedName: Identidade.nomeDaCamera,
                                     deviceID: Identidade.idDoDispositivo,
                                     legacyDeviceID: Identidade.idDoDispositivo.uuidString,
                                     source: self)

        // Faixa limitada, BT.709 declarado — o padrão do projeto, aqui posto na descrição de
        // formato para que o consumidor receba a marcação em vez de adivinhar.
        let extensoes: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        var descricaoLocal: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       width: Identidade.largura,
                                       height: Identidade.altura,
                                       extensions: extensoes as CFDictionary,
                                       formatDescriptionOut: &descricaoLocal)
        descricao = descricaoLocal

        let duracao = CMTime(value: 1, timescale: CMTimeScale(Identidade.quadrosPorSegundo))
        let formato = CMIOExtensionStreamFormat(formatDescription: descricao,
                                                maxFrameDuration: duracao,
                                                minFrameDuration: duracao,
                                                validFrameDurations: nil)

        saida = FluxoDeSaida(dispositivo: self, formato: formato)
        entrada = FluxoDeEntrada(dispositivo: self, formato: formato)

        do {
            try device.addStream(saida.stream)
            try device.addStream(entrada.stream)
        } catch {
            registro.error("EXT addStream falhou código=\((error as NSError).code, privacy: .public); contexto omitido")
        }

        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: Identidade.largura,
            kCVPixelBufferHeightKey: Identidade.altura,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reservatorio)
    }

    // MARK: - CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' — o mesmo `kIOAudioDeviceTransportTypeVirtual` do IOKit, escrito como
            // literal para não arrastar o cabeçalho de áudio para dentro de uma extensão de vídeo.
            p.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) {
            p.model = "Quall — câmera virtual"
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Ciclo do fluxo de saída

    func comecarSaida() {
        fila.sync {
            clientesNaSaida += 1
            guard relogio == nil else { return }
            registro.info("EXT saída iniciou; pegada=\(Medidas.pegadaDeMemoria(), privacy: .public)")
            let t = DispatchSource.makeTimerSource(queue: fila)
            let periodo = 1.0 / Double(Identidade.quadrosPorSegundo)
            t.schedule(deadline: .now(), repeating: periodo, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.bater() }
            relogio = t
            t.resume()
            Sonda.dispararSeConfigurada()
        }
    }

    func pararSaida() {
        fila.sync {
            clientesNaSaida = max(0, clientesNaSaida - 1)
            guard clientesNaSaida == 0 else { return }
            relogio?.cancel()
            relogio = nil
            travaDoEstado.lock()
            let e = enviados, c = consumidos
            travaDoEstado.unlock()
            registro.info("EXT saída parou; enviados=\(e, privacy: .public) consumidos=\(c, privacy: .public) pegada=\(Medidas.pegadaDeMemoria(), privacy: .public)")
        }
    }

    /// Uma batida do relógio: só desenha se a entrada estiver muda. Quadro que veio da rede é
    /// repassado no instante em que chega, não aqui — enfileirar para o próximo tique somaria até
    /// 33 ms de latência a um caminho que o projeto mede em milissegundos.
    private func bater() {
        let agora = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        travaDoEstado.lock()
        let jaVeio = jaVeioAlgoDaEntrada
        let ultimo = ultimoDaEntradaNs
        travaDoEstado.unlock()
        if jaVeio, agora - ultimo < 200_000_000 { return }
        guard let reservatorio else { return }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &buffer) == kCVReturnSuccess,
              let buffer else { return }

        if jaVeio {
            Placa.desenharEspera(em: buffer, marca: contador)
        } else {
            Placa.desenharPlacaDeTeste(numero: contador, em: buffer)
        }
        contador += 1
        marcarCor(buffer)
        despachar(buffer, hostNs: agora)
    }

    /// Chamado pelo fluxo de entrada, na thread do CoreMediaIO, com o quadro que o app empurrou.
    func repassar(_ amostra: CMSampleBuffer, hostNs: UInt64) {
        let inicio = Medidas.agoraUs()
        saida.stream.send(amostra, discontinuity: [], hostTimeInNanoseconds: hostNs)
        let custo = Medidas.agoraUs() - inicio

        travaDoEstado.lock()
        consumidos += 1
        enviados += 1
        ultimoDaEntradaNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        jaVeioAlgoDaEntrada = true
        somaDoRepasseUs += custo
        contagemDoRepasse += 1
        piorRepasseUs = max(piorRepasseUs, custo)
        let n = contagemDoRepasse
        let media = somaDoRepasseUs / max(1, contagemDoRepasse)
        let pior = piorRepasseUs
        travaDoEstado.unlock()

        if n % 300 == 0 {
            registro.info("EXT repasse n=\(n, privacy: .public) media_us=\(media, privacy: .public) pior_us=\(pior, privacy: .public) pegada=\(Medidas.pegadaDeMemoria(), privacy: .public)")
        }
    }

    private func marcarCor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private func despachar(_ buffer: CVPixelBuffer, hostNs: UInt64) {
        var tempo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(Identidade.quadrosPorSegundo)),
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var amostra: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                             imageBuffer: buffer,
                                                             formatDescription: descricao,
                                                             sampleTiming: &tempo,
                                                             sampleBufferOut: &amostra)
        guard status == noErr, let amostra else { return }
        saida.stream.send(amostra, discontinuity: [], hostTimeInNanoseconds: hostNs)
        travaDoEstado.lock()
        enviados += 1
        let n = enviados
        travaDoEstado.unlock()
        if n % 300 == 0 {
            registro.info("EXT placa enviados=\(n, privacy: .public) pegada=\(Medidas.pegadaDeMemoria(), privacy: .public) residente=\(Medidas.residente(), privacy: .public)")
        }
    }
}
