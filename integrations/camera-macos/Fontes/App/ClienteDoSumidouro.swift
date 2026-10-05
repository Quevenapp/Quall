import CoreMedia
import CoreMediaIO
import Foundation

/// O lado do **app** da fronteira entre processos: acha o dispositivo `Quall` pelo CoreMediaIO,
/// abre o fluxo de entrada e enfileira `CMSampleBuffer`.
///
/// Não existe API "moderna" para este lado. `CMIOExtension*` é a API de **quem escreve a
/// extensão**; quem escreve na extensão de fora usa a API C do DAL, que é a que Zoom e Meet usam
/// para ler câmera. Daí o código parecer de 2010: ele é de 2010.
final class ClienteDoSumidouro {
    enum Falha: Error, CustomStringConvertible {
        case dispositivoNaoAchado
        case fluxoDeEntradaNaoAchado
        case filaNaoAbriu(OSStatus)
        case naoIniciou(OSStatus)

        var description: String {
            switch self {
            case .dispositivoNaoAchado:
                return "dispositivo Quall não apareceu no CoreMediaIO (a extensão está ativada e aprovada?)"
            case .fluxoDeEntradaNaoAchado:
                return "o dispositivo apareceu mas não tem fluxo de entrada (direção 0)"
            case .filaNaoAbriu(let s):
                return "CMIOStreamCopyBufferQueue falhou: \(s)"
            case .naoIniciou(let s):
                return "CMIODeviceStartStream falhou: \(s)"
            }
        }
    }

    private(set) var idDoDispositivo: CMIOObjectID = 0
    private(set) var idDoFluxo: CMIOStreamID = 0
    private var fila: CMSimpleQueue?
    private(set) var capacidadeDaFila: Int32 = 0

    /// Quantas vezes a fila estava cheia na hora de empurrar. Quadro descartado é o
    /// comportamento certo em espelhamento ao vivo — mas precisa ser contado, não escondido.
    private(set) var descartados: UInt64 = 0
    private(set) var enfileirados: UInt64 = 0

    /// **O intervalo entre entregas** — a fluidez desta casca. Ver ``Fluidez``: a marca é tirada
    /// aqui, no `empurrar` que deu certo, porque é este o instante em que o quadro deixa este
    /// processo e vira alguma coisa que um consumidor pode ler.
    ///
    /// Sob trava, e a trava é obrigatória aqui e não é no app: esta casca decodifica com
    /// `_EnableAsynchronousDecompression`, então `empurrar` roda numa thread do VideoToolbox
    /// enquanto o laço de supervisão lê a linha a 1 Hz. `enfileirados` e `descartados` são
    /// `UInt64` e sobrevivem à corrida com um número torto; um `Array` que cresce, não.
    private var fluidez = Fluidez()
    private let travaDaFluidez = NSLock()

    /// `fluidez_ms=[n=… p50=… p95=… max=…] trancos=…` das entregas até agora.
    var linhaDeFluidez: String {
        travaDaFluidez.lock(); defer { travaDaFluidez.unlock() }
        return fluidez.linha
    }

    /// Quantos intervalos entre entregas passaram do corte de ``Fluidez/trancoMs``.
    var trancos: UInt64 {
        travaDaFluidez.lock(); defer { travaDaFluidez.unlock() }
        return fluidez.trancos
    }

    /// Sem isto o processo não enxerga dispositivos que não sejam câmeras físicas.
    static func permitirDispositivosVirtuais() {
        var endereco = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var permitir: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &endereco, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &permitir)
    }

    static func dispositivos() -> [CMIOObjectID] {
        var endereco = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var tamanho: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &endereco, 0, nil, &tamanho) == noErr,
              tamanho > 0 else { return [] }
        let quantos = Int(tamanho) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: quantos)
        var usado: UInt32 = 0
        let r = ids.withUnsafeMutableBytes { buf -> OSStatus in
            CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &endereco, 0, nil,
                                      tamanho, &usado, buf.baseAddress!)
        }
        return r == noErr ? ids : []
    }

    static func textoDoDispositivo(_ id: CMIOObjectID, seletor: CMIOObjectPropertySelector) -> String? {
        var endereco = CMIOObjectPropertyAddress(
            mSelector: seletor,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var tamanho: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(id, &endereco, 0, nil, &tamanho) == noErr else { return nil }
        var valor: CFString? = nil
        var usado: UInt32 = 0
        let r = withUnsafeMutablePointer(to: &valor) { p -> OSStatus in
            CMIOObjectGetPropertyData(id, &endereco, 0, nil, tamanho, &usado, p)
        }
        guard r == noErr, let valor else { return nil }
        return valor as String
    }

    static func fluxos(de dispositivo: CMIOObjectID) -> [CMIOStreamID] {
        var endereco = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var tamanho: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(dispositivo, &endereco, 0, nil, &tamanho) == noErr, tamanho > 0 else { return [] }
        let quantos = Int(tamanho) / MemoryLayout<CMIOStreamID>.size
        var ids = [CMIOStreamID](repeating: 0, count: quantos)
        var usado: UInt32 = 0
        let r = ids.withUnsafeMutableBytes { buf -> OSStatus in
            CMIOObjectGetPropertyData(dispositivo, &endereco, 0, nil, tamanho, &usado, buf.baseAddress!)
        }
        return r == noErr ? ids : []
    }

    /// 0 = fluxo de saída do ponto de vista do cliente (é onde **nós** escrevemos), 1 = entrada.
    static func direcao(_ fluxo: CMIOStreamID) -> UInt32? {
        var endereco = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var valor: UInt32 = 0
        var usado: UInt32 = 0
        let r = CMIOObjectGetPropertyData(fluxo, &endereco, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &usado, &valor)
        return r == noErr ? valor : nil
    }

    func abrir() throws {
        Self.permitirDispositivosVirtuais()
        let alvo = Identidade.idDoDispositivo.uuidString.lowercased()
        var achado: CMIOObjectID?
        for id in Self.dispositivos() {
            let uid = Self.textoDoDispositivo(id, seletor: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
            if let uid, uid.lowercased() == alvo { achado = id; break }
        }
        guard let dispositivo = achado else { throw Falha.dispositivoNaoAchado }
        idDoDispositivo = dispositivo

        var entrada: CMIOStreamID?
        for fluxo in Self.fluxos(de: dispositivo) where Self.direcao(fluxo) == 0 {
            entrada = fluxo
            break
        }
        guard let entrada else { throw Falha.fluxoDeEntradaNaoAchado }
        idDoFluxo = entrada

        var ponteiro: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(entrada, { _, _, _ in }, nil, &ponteiro)
        guard status == noErr, let ponteiro else { throw Falha.filaNaoAbriu(status) }
        fila = ponteiro.takeRetainedValue()
        capacidadeDaFila = CMSimpleQueueGetCapacity(fila!)

        let inicio = CMIODeviceStartStream(dispositivo, entrada)
        guard inicio == noErr else { throw Falha.naoIniciou(inicio) }
    }

    /// Enfileira um quadro. Devolve `false` quando a fila está cheia — e nesse caso o quadro é
    /// **descartado**, não guardado: é a regra de "zero filas" do contrato do projeto.
    @discardableResult
    func empurrar(_ amostra: CMSampleBuffer) -> Bool {
        guard let fila else { return false }
        guard CMSimpleQueueGetCount(fila) < CMSimpleQueueGetCapacity(fila) else {
            descartados += 1
            return false
        }
        let status = CMSimpleQueueEnqueue(fila, element: Unmanaged.passRetained(amostra).toOpaque())
        if status != noErr {
            descartados += 1
            return false
        }
        enfileirados += 1
        // **O ponto de entrega desta casca.** Só o que entrou na fila conta: um quadro que a fila
        // recusou, ou que a porta de `Receptor.entregar` reteve, não foi entregue a ninguém — e o
        // preço dele aparece onde deve, como um intervalo maior até a entrega seguinte.
        //
        // O relógio é lido **depois** do enqueue e **antes** da trava, para que a espera pela
        // trava não vire cauda de imagem.
        let agoraUs = Medidas.agoraUs()
        travaDaFluidez.lock()
        fluidez.entregou(agoraUs: agoraUs)
        travaDaFluidez.unlock()
        return true
    }

    func fechar() {
        guard idDoDispositivo != 0, idDoFluxo != 0 else { return }
        CMIODeviceStopStream(idDoDispositivo, idDoFluxo)
        fila = nil
        idDoFluxo = 0
        idDoDispositivo = 0
    }
}
