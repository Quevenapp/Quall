import CoreMedia
import CoreVideo
import Foundation

/// **Emissor de bancada.** Hospeda uma sessão, gera 720p30 com o relógio desenhado dentro do
/// quadro, codifica em hardware e manda pela track de mídia.
///
/// Por que ele existe, sendo que o produto desta frente é só receber: para medir o caminho
/// inteiro é preciso saber **quando o quadro saiu**, e nenhum emissor da bancada diz isso num
/// relógio que este Mac possa ler. Com o emissor aqui, emissor e consumidor rodam na mesma
/// máquina, `CLOCK_UPTIME_RAW` é do sistema — não do processo —, e a subtração vale sem
/// sincronizar relógio nenhum.
///
/// O que ele **não** substitui: a prova de que vídeo de um aparelho de verdade atravessa. Essa é
/// feita com um Android por `adb`, e é outra corrida.
final class Emissor {
    private let nucleo = Nucleo()
    private var codificador: CodificadorH264?

    private var enviados: UInt64 = 0
    private var recusados: UInt64 = 0
    private var custosDaFaixa: [UInt64] = []

    func correr(pin: String, porta: UInt16, segundos: Double, fps: Double, prazoMs: UInt32) -> Int32 {
        dizer("emissor de bancada: porta=\(porta) autenticação configurada — esperando alguém conectar (prazo \(prazoMs / 1000) s)")
        let inicioDaEspera = Medidas.agoraUs()
        let noDisco = try? String(contentsOf: Self.arquivoDePares(), encoding: .utf8)
        guard nucleo.hospedar(deviceId: identidadeDoAparelho(),
                              nome: "\(Host.current().localizedName ?? "MacBook") (bancada)",
                              pin: pin,
                              porta: porta,
                              rotuloDaTrack: "Placa de bancada do Mac",
                              paresConhecidos: noDisco,
                              prazoMs: prazoMs) else {
            dizer("não subiu: status=\(quall_last_status().rawValue) \(RegistroSeguro.motivo(nucleo.ultimoMotivo))")
            return 1
        }
        dizer("sessão de pé em \((Medidas.agoraUs() - inicioDaEspera) / 1000) ms; pareamento \(nucleo.pareamentoNovo() ? "novo (PIN)" : "retomado")")
        // O anfitrião também persiste. Sem isto, a segunda corrida quebra duro: o receptor grava o
        // pareamento, tenta retomar, e o emissor não reconhece — que é exatamente o beco sem saída
        // da dívida 22, reproduzido na bancada.
        if let daSessao = nucleo.paresConhecidos(base: noDisco) {
            let fundido = Nucleo.fundirPares(noDisco, daSessao) ?? daSessao
            try? fundido.write(to: Self.arquivoDePares(), atomically: true, encoding: .utf8)
        }

        let codificador = CodificadorH264(largura: Identidade.largura,
                                          altura: Identidade.altura,
                                          fps: Int32(fps)) { [weak self] annexb, ts, idr in
            guard let self else { return }
            let status = self.nucleo.enviarQuadro(annexb, timestampUs: ts, idr: idr)
            if status == QUALL_STATUS_OK { self.enviados += 1 } else { self.recusados += 1 }
        }
        guard let codificador else {
            dizer("VTCompressionSessionCreate falhou")
            nucleo.encerrar()
            return 1
        }
        self.codificador = codificador
        dizer("encoder: \(codificador.nomeDoEncoder) hardware=\(codificador.emHardware)")

        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: Identidade.largura,
            kCVPixelBufferHeightKey: Identidade.altura,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var reservatorio: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reservatorio)
        guard let reservatorio else {
            dizer("sem reservatório de pixels")
            nucleo.encerrar()
            return 1
        }

        let periodo = 1.0 / fps
        let fim = Date().addingTimeInterval(segundos)
        var proximo = Date()
        var numero = 0
        var primeiro = true

        while Date() < fim {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &buffer) == kCVReturnSuccess,
               let buffer {
                Placa.desenharPlacaDeTeste(numero: numero, em: buffer)
                marcarCor(buffer)

                // O carimbo é lido **imediatamente antes** de a faixa ser desenhada, e a faixa é a
                // última coisa antes de submeter ao encoder. O que fica entre o carimbo e a
                // submissão é só o custo de desenhar a faixa, medido aqui ao lado para poder ser
                // declarado em vez de suposto.
                let carimbo = Medidas.agoraUs()
                Faixa.desenhar(valorMs: carimbo / 1_000, em: buffer)
                let depoisDaFaixa = Medidas.agoraUs()
                if custosDaFaixa.count < 100_000 { custosDaFaixa.append(depoisDaFaixa - carimbo) }

                let forcar = primeiro || nucleo.pedidoDeIdrPendente()
                primeiro = false
                codificador.codificar(buffer, timestampUs: carimbo, forcarIdr: forcar)
                numero += 1
            }

            proximo = proximo.addingTimeInterval(periodo)
            let espera = proximo.timeIntervalSinceNow
            if espera > 0 {
                Thread.sleep(forTimeInterval: espera)
            } else {
                proximo = Date()
            }
        }

        codificador.encerrar()
        let custo = codificador.resumoDeCusto()
        dizer("encode: n=\(custo.n) média=\(custo.media)us p50=\(custo.p50)us p95=\(custo.p95)us max=\(custo.max)us")
        dizer("faixa: \(resumo(custosDaFaixa))")
        dizer("gerados=\(numero) codificados=\(codificador.quadrosCodificados) idrs=\(codificador.idrsEmitidos) enviados=\(enviados) recusados=\(recusados)")
        // O que o remendo de SPS fez, dito em voz alta: um remendo que desiste em silêncio é pior
        // do que remendo nenhum, e é este número que separa 4 ms de 170 ms do outro lado.
        dizer(codificador.remendoDeSPS.resumo())
        dizer("contadores do núcleo: \(RegistroSeguro.metricas(nucleo.contadores()))")
        nucleo.encerrar()
        return 0
    }

    private func resumo(_ v: [UInt64]) -> String {
        guard !v.isEmpty else { return "n=0" }
        let o = v.sorted()
        return "n=\(v.count) média=\(v.reduce(0, +) / UInt64(v.count))us p95=\(o[min(o.count - 1, Int(Double(o.count) * 0.95))])us max=\(o.last!)us"
    }

    private func marcarCor(_ b: CVPixelBuffer) {
        CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// Arquivo de pares do **emissor**, separado do do receptor pelo mesmo motivo da identidade:
    /// são dois aparelhos lógicos na mesma máquina, e um arquivo só faria um sobrescrever o outro.
    static func arquivoDePares() -> URL {
        Receptor.arquivoDePares().deletingLastPathComponent().appendingPathComponent("pares-emissor.json")
    }

    /// Identidade separada da do receptor: as duas metades rodam na mesma máquina, e dois papéis
    /// com o mesmo `DeviceId` seriam um aparelho pareando consigo mesmo.
    private func identidadeDoAparelho() -> String {
        let chave = "br.com.queven.quall.camera.deviceId.emissor"
        if let existente = UserDefaults.standard.string(forKey: chave) { return existente }
        let novo = UUID().uuidString.lowercased()
        UserDefaults.standard.set(novo, forKey: chave)
        return novo
    }
}
