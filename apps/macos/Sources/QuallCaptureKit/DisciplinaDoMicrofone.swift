import Foundation

/// **O carimbo do som do microfone, pela disciplina do contrato** (R5 fase 2 do iOS, §8.4 de
/// `docs/teleprompter-com-camera.md`, trazida ao Mac na fase 4 e separada em struct pura para ser
/// testada sem microfone nenhum).
///
/// Entra: o PCM já reamostrado para 48 kHz mono (`Int16`), com o PTS (em segundos, **no relógio da
/// câmera**: o dono converte antes) e quantas amostras de **entrada** o buffer tinha. Sai: quadros
/// de exatamente `amostrasPorQuadro` amostras, cada um com o carimbo em µs.
///
/// - o carimbo anda **exatamente um quadro por pacote** (20 000 µs);
/// - a hora real da primeira amostra de cada quadro sai da **âncora** do último buffer (o PTS dele e
///   quantas amostras de entrada vieram antes), e o erro entre ela e o carimbo é tirado do
///   **conteúdo**: acima de +0,5 ms o quadro anda uma amostra real a menos (repete a última); abaixo
///   de −0,5 ms, uma a mais (pula uma do meio);
/// - fora desse alcance (erro acima de 5 ms): degrau para a frente, ou corte da entrada quando o
///   carimbo está adiantado. **Nunca para trás**;
/// - uma **descontinuidade** de captura (o PTS de um buffer longe do previsto por mais de 10 ms: o
///   botão desligado e ligado, uma interrupção) recomeça a fila e reancora **para a frente**.
///
/// É a conta de `apps/ios/Quall/App/MicrofoneParaOpus.swift` (`emitirUmQuadro`), sem o conversor e
/// sem o encoder, que ficam com quem chama. Não é o laço de razão do Windows e do Android: é uma
/// correção de uma amostra por vez (~1 000 ppm de alcance), com o erro publicado.
public struct DisciplinaDoMicrofone: Sendable {

    public let amostrasPorQuadro: Int
    public let taxaDeSaida: Double
    public let quadroUs: Int64

    /// Amostras reamostradas esperando virar quadro.
    private var fila: [Int16] = []
    /// O índice, em amostras de **saída** contadas desde o último recomeço, de `fila[0]`.
    private var indiceDoInicio: Int64 = 0
    /// Amostras de **entrada** desde o último recomeço, e a âncora.
    private var totalDeEntrada: Int64 = 0
    private var ancoraPts: Double = 0
    private var ancoraEntrada: Int64 = 0
    private var taxaDeEntrada: Double = 0
    private var ancorado = false
    private var proximoCarimboUs: Int64?
    private var ultimoCarimboUs: Int64 = 0

    public struct Contadores: Equatable, Sendable {
        public var quadros: UInt64 = 0
        public var descontinuidades: UInt64 = 0
        public var degraus: UInt64 = 0
        public var cortes: UInt64 = 0
        public var inseridas: UInt64 = 0
        public var tiradas: UInt64 = 0
        public var erroUs: Double = 0
        public var erroMaximoUs: Double = 0
        public init() {}
    }
    public private(set) var contadores = Contadores()

    public init(amostrasPorQuadro: Int = 960, taxaDeSaida: Double = 48_000) {
        precondition(amostrasPorQuadro > 1 && taxaDeSaida > 0)
        self.amostrasPorQuadro = amostrasPorQuadro
        self.taxaDeSaida = taxaDeSaida
        self.quadroUs = Int64((Double(amostrasPorQuadro) * 1_000_000 / taxaDeSaida).rounded())
    }

    /// O erro máximo zera a cada leitura do relato (a janela de 10 s).
    public mutating func zerarErroMaximo() { contadores.erroMaximoUs = 0 }

    /// A fila e a âncora do zero. O carimbo **não** volta: o próximo quadro sai no maior entre a
    /// hora real e o sucessor do último. Quem chama recomeça também o conversor.
    public mutating func recomecar() {
        fila.removeAll(keepingCapacity: true)
        indiceDoInicio = 0
        totalDeEntrada = 0
        ancoraEntrada = 0
        ancorado = false
        proximoCarimboUs = nil
    }

    /// Confere o PTS de um buffer contra o previsto pela âncora anterior. `true` quando houve
    /// descontinuidade (acima de 10 ms): a fila já recomeçou, e quem chama recomeça o conversor
    /// **antes** de converter este buffer.
    public mutating func conferirContinuidade(pts: Double, taxaDeEntrada taxa: Double) -> Bool {
        guard ancorado, taxa > 0, taxa == taxaDeEntrada else { return false }
        let previsto = ancoraPts + Double(totalDeEntrada - ancoraEntrada) / taxaDeEntrada
        guard abs(pts - previsto) > 0.010 else { return false }
        contadores.descontinuidades &+= 1
        recomecar()
        return true
    }

    /// Um buffer convertido. `amostrasDeEntrada` é quantas amostras o buffer tinha **antes** da
    /// conversão, na `taxaDeEntrada` dele.
    public mutating func acrescentar(pts: Double, amostrasDeEntrada n: Int, taxaDeEntrada taxa: Double,
                                     convertidas: [Int16]) {
        guard n > 0, taxa > 0, pts.isFinite else { return }
        if taxa != taxaDeEntrada {
            if ancorado { recomecar() }
            taxaDeEntrada = taxa
        }
        ancoraPts = pts
        ancoraEntrada = totalDeEntrada
        ancorado = true
        totalDeEntrada &+= Int64(n)
        fila.append(contentsOf: convertidas)
    }

    /// O próximo quadro, se couber (uma amostra a mais do que o quadro: é o que o caso "tira uma"
    /// consome). `nil` quando falta amostra.
    public mutating func proximoQuadro() -> (quadro: [Int16], carimboUs: Int64)? {
        let q = amostrasPorQuadro
        while fila.count >= q + 1, ancorado {
            // A hora real (µs do relógio da câmera) da primeira amostra da fila.
            let realUs = (ancoraPts + Double(indiceDoInicio) / taxaDeSaida
                          - Double(ancoraEntrada) / taxaDeEntrada) * 1_000_000
            if proximoCarimboUs == nil {
                let r = Int64(realUs.rounded(.down))
                proximoCarimboUs = ultimoCarimboUs > 0 ? max(r, ultimoCarimboUs &+ quadroUs) : r
            }
            guard var carimbo = proximoCarimboUs else { return nil }
            var erro = realUs - Double(carimbo)

            if erro > 5_000 {
                // O carimbo ficou para trás além do alcance da correção por amostra: degrau para a
                // frente.
                carimbo = max(Int64(realUs.rounded(.down)), carimbo)
                erro = realUs - Double(carimbo)
                contadores.degraus &+= 1
            } else if erro < -5_000 {
                // O carimbo está adiantado: corta a entrada até a hora real alcançá-lo.
                let tirar = min(fila.count - (q + 1), Int((-erro) / 1_000_000 * taxaDeSaida))
                if tirar > 0 {
                    fila.removeFirst(tirar)
                    indiceDoInicio &+= Int64(tirar)
                    contadores.cortes &+= 1
                    continue
                }
            }

            var quadro = [Int16](repeating: 0, count: q)
            let consumidas: Int
            if erro > 500 {
                // A hora real está à frente do carimbo: o quadro anda uma amostra real a menos.
                for i in 0..<(q - 1) { quadro[i] = fila[i] }
                quadro[q - 1] = fila[q - 2]
                consumidas = q - 1
                contadores.inseridas &+= 1
            } else if erro < -500 {
                // O carimbo está à frente da hora real: uma amostra real a mais (pula a do meio).
                let meio = q / 2
                for i in 0..<meio { quadro[i] = fila[i] }
                for i in meio..<q { quadro[i] = fila[i + 1] }
                consumidas = q + 1
                contadores.tiradas &+= 1
            } else {
                for i in 0..<q { quadro[i] = fila[i] }
                consumidas = q
            }
            fila.removeFirst(consumidas)
            indiceDoInicio &+= Int64(consumidas)
            proximoCarimboUs = carimbo &+ quadroUs
            ultimoCarimboUs = carimbo
            contadores.quadros &+= 1
            contadores.erroUs = erro
            contadores.erroMaximoUs = max(contadores.erroMaximoUs, abs(erro))
            return (quadro, carimbo)
        }
        return nil
    }
}
