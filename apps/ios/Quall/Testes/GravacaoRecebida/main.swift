import AVFoundation
import Foundation

setbuf(stdout, nil)
let pasta = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func unidades(_ arquivo: String) throws -> [Data] {
    let nals = TomadaRecebida.nals(try Data(contentsOf: pasta.appendingPathComponent(arquivo)))
    var unidades: [Data] = [], atual = Data()
    for nal in nals {
        if nal.first! & 31 == 9, !atual.isEmpty { unidades.append(atual); atual = Data() }
        atual.append(contentsOf: [0, 0, 0, 1]); atual.append(nal)
    }
    if !atual.isEmpty { unidades.append(atual) }
    return unidades
}
let primeira = try unidades("320.h264"), segunda = try unidades("640.h264")
func ehIdr(_ data: Data) -> Bool { TomadaRecebida.nals(data).contains { $0.first! & 31 == 5 } }
func gravar(_ nome: String, perda: Bool = false, mudar: Bool = false,
            semIdr: Bool = false, som: Bool = true, relogio: Bool = true, taxa: Int = 48_000) -> TomadaRecebida.Resultado {
    let terminou = DispatchSemaphore(value: 0)
    let trava = NSLock(); var pedidos = 0, comecos = 0
    let tomada = TomadaRecebida(pasta: pasta, nome: nome, aoComecar: { trava.lock(); comecos += 1; trava.unlock() },
                              aoPedirIdr: { trava.lock(); pedidos += 1; trava.unlock() })
    if som { tomada.configurarSom(taxa: taxa, canais: 1) }
    if relogio { tomada.relogio(video: 2_000_000, audio: 1_500_000) }
    var amostraSom = 0
    let quadros = mudar ? Array(primeira.prefix(60)) + segunda : primeira
    for (i, data) in quadros.enumerated() {
        let pts = UInt64(i * 1_000_000 / 30)
        if !(perda && i == 10) && !(semIdr && ehIdr(data)) {
            data.withUnsafeBytes { tomada.quadro($0, ts: 1_000_000 + pts, idr: ehIdr(data)) }
        }
        if som {
            while amostraSom * 20_000 <= i * 1_000_000 / 30 {
                let numero = amostraSom
                let porSlot = taxa / 50
                let pcm = (0..<porSlot).map { n in Int16(sin(Double(numero * porSlot + n) * 2 * .pi * 440 / Double(taxa)) * 12_000) }
                tomada.som(pcm, taxa: taxa, canais: 1, ordem: UInt16(numero), ts: UInt64(1_500_000 + numero * 20_000))
                amostraSom += 1
            }
        }
        Thread.sleep(forTimeInterval: 1.0 / 30.0)
    }
    var resultado: TomadaRecebida.Resultado?
    tomada.fechar { r in resultado = r; terminou.signal() }
    precondition(terminou.wait(timeout: .now() + 20) == .success, "writer não terminou")
    let r = resultado!
    print("resultado \(nome): \(r.arquivos.count) arquivos; erro=\(String(describing: r.erro))")
    if semIdr { precondition(r.arquivos.isEmpty && r.erro != nil, "sem IDR não pode haver arquivo") }
    else { precondition(r.erro == nil && r.arquivos.count == (mudar ? 2 : 1), "gravação falhou: \(String(describing: r.erro))") }
    if perda { precondition(pedidos > 0, "perda deve pedir IDR") }
    if !semIdr { precondition(comecos == 1, "início tem de ser único") }
    print("\(nome): \(r.arquivos.count) arquivo(s), pedidos_IDR=\(pedidos), erro=\(String(describing: r.erro))")
    return r
}
_ = gravar("normal")
_ = gravar("perda", perda: true)
_ = gravar("troca", mudar: true)
_ = gravar("sem-som", som: false)
_ = gravar("sem-relogio", relogio: false)
_ = gravar("sem-idr", semIdr: true)
_ = gravar("pcm8k", taxa: 8_000)
// A tela pode não mudar por minutos. O arquivo deve conservar esse tempo, e o PCM
// continua durante a imagem parada. Os 2 s que aguardam som tardio não são vídeo.
func telaEstatica() {
    let terminou = DispatchSemaphore(value: 0)
    var resultado: TomadaRecebida.Resultado?
    let tomada = TomadaRecebida(pasta: pasta, nome: "estatica", aoComecar: {}, aoPedirIdr: {})
    tomada.configurarSom(taxa: 48_000, canais: 1)
    tomada.relogio(video: 2_000_000, audio: 1_500_000)
    primeira[0].withUnsafeBytes { tomada.quadro($0, ts: 1_000_000, idr: true) }
    let inicio = ProcessInfo.processInfo.systemUptime
    for numero in 0..<800 {
        let pcm = (0..<960).map { n in Int16(sin(Double(numero * 960 + n) * 2 * .pi * 440 / 48_000) * 12_000) }
        tomada.som(pcm, taxa: 48_000, canais: 1, ordem: UInt16(numero), ts: UInt64(1_500_000 + numero * 20_000))
        let prazo = inicio + Double(numero + 1) * 0.02
        Thread.sleep(forTimeInterval: max(0, prazo - ProcessInfo.processInfo.systemUptime))
    }
    let duracao = ProcessInfo.processInfo.systemUptime - inicio
    tomada.fechar { resultado = $0; terminou.signal() }
    precondition(terminou.wait(timeout: .now() + 20) == .success)
    precondition(resultado?.erro == nil && resultado?.arquivos.count == 1)
    try! String(duracao).write(to: pasta.appendingPathComponent("estatica-duracao.txt"), atomically: true, encoding: .utf8)
    print("estatica: um quadro permaneceu por \(duracao) s, com som")
}
telaEstatica()
// A pausa não redefine o fps: ao retomar e parar, a última amostra não ganha 500 ms extras.
func pausaERetomada() {
    let terminou = DispatchSemaphore(value: 0)
    let tomada = TomadaRecebida(pasta: pasta, nome: "retoma", aoComecar: {}, aoPedirIdr: {})
    primeira[0].withUnsafeBytes { tomada.quadro($0, ts: 1_000_000, idr: true) }
    Thread.sleep(forTimeInterval: 0.5)
    primeira[1].withUnsafeBytes { tomada.quadro($0, ts: 1_500_000, idr: false) }
    Thread.sleep(forTimeInterval: 0.02)
    tomada.fechar { r in
        precondition(r.erro == nil && r.arquivos.count == 1)
        terminou.signal()
    }
    precondition(terminou.wait(timeout: .now() + 15) == .success)
    print("TELA_ESTATICA_RETOMA_E_PARA_APROVADA")
}
pausaERetomada()
// Parsers malformados não podem declarar que a cadeia está boa.
var malformado = ReferenciasH264Recebidas(sps: Data([0x67]))
precondition(malformado.rompeu([Data([0x41, 0xff])], idr: false))
precondition(malformado.rompeu([Data([0x65, 0xff])], idr: true))
print("SONDA_GRAVACAO_RECEBIDA_APROVADA")
