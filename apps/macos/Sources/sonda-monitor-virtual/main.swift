import CoreGraphics
import Foundation
import QuallCaptureKit

// Sonda de bancada da tela estendida: sobe o monitor virtual pelo **mesmo** caminho do produto
// (`MonitorVirtualAuxiliar`, que roda `quall-monitor-virtual` num processo próprio), confere pelo
// CoreGraphics — **deste** processo, como o app faria — o que o WindowServer aceitou, e solta.
// Repete a volta, porque o defeito que o auxiliar existe para evitar é justamente o da **segunda**
// vez (`docs/tela-estendida.md`).
//
// **Não captura nada.** O que aparece num monitor do Mac é a vida de quem usa o Mac
// (`docs/regras-de-frente.md`); tudo aqui é lido de propriedade de monitor, nunca de pixel.
//
//     swift build -c release --product quall-monitor-virtual   # um produto por vez: com dois
//     swift build -c release --product sonda-monitor-virtual   # `--product`, só o último é montado
//     .build/release/sonda-monitor-virtual                       # 2x e depois 1x, 2 s cada
//     .build/release/sonda-monitor-virtual --escalas=2x,2x,2x --segundos=1
//     .build/release/sonda-monitor-virtual --juntos=3 --segundos=5   # três monitores ao mesmo tempo
//
// Sai com 0 quando **todas** as voltas subiram (o auxiliar confere os pixels), o monitor apareceu
// deste lado com a área de 1x ou 2x, e sumiu depois de solto.
//
// `--juntos=N` é a pergunta de 10/09/2026 — *"daria para fazer mais de um?"*: N auxiliares, um por
// monitor, cada um com a identidade do seu índice. Aprova quando os N sobem **já no modo pedido**,
// ficam de pé juntos com séries distintas, sem sobreposição, sem espelho e sem virar principal, e
// quando soltar um não derruba os outros.
//
//     .build/release/sonda-monitor-virtual --juntos=1 --telas=1440x3120
//
// `--telas=LxA,...` são telas de aparelho (como o receptor as diz), passadas pela regra do produto
// (`ModoDoMonitorVirtual.paraTela`); `--tamanhos=LxA,...` são pixels de monitor pedidos em 2x, crus.
// **O veredito é estrito**: o monitor tem de nascer no modo pedido. Escala lembrada pelo macOS não
// passa — ela é do produto (a pessoa escolheu), mas numa medida da regra é contaminação. Por isso,
// **identidades novas a cada corrida** por padrão (índices a partir de 1000, tirados do relógio): uma
// identidade reusada nasceria da lembrança e passaria um caso que uma nova reprovaria, e um índice
// baixo seria o de um aparelho do produto (`TabelaDeIndices`, 0…31). `--indice-base=N` fixa o
// começo — para medir a lembrança de propósito. Cada identidade fica nas preferências de monitor do
// macOS.

var escalas: [ModoDoMonitorVirtual.Escala] = [.dobro, .umPraUm]
var segundos = 2.0
var juntos = 0
var tamanhos: [(Int, Int)] = []
var telas: [(Int, Int)] = []
var escalaDasTelas = ModoDoMonitorVirtual.Escala.dobro
var indiceBase: Int?
func pares(_ v: String) -> [(Int, Int)] {
    v.split(separator: ",").compactMap { par in
        let n = par.lowercased().split(separator: "x").compactMap { Int($0) }
        return n.count == 2 ? (n[0], n[1]) : nil
    }
}
for argumento in CommandLine.arguments.dropFirst() {
    let partes = argumento.split(separator: "=", maxSplits: 1).map(String.init)
    switch (partes.first, partes.count == 2 ? partes[1] : nil) {
    case ("--escalas", let v?):
        escalas = v.split(separator: ",").compactMap { ModoDoMonitorVirtual.Escala(rawValue: String($0)) }
    case ("--segundos", let v?): segundos = Double(v) ?? segundos
    case ("--juntos", let v?): juntos = max(0, Int(v) ?? 0)
    // Ilegível é erro, e não "sem formato": calada, a sonda mediria o tablet no lugar do pedido.
    case ("--tamanhos", let v?), ("--telas", let v?):
        let lidos = pares(v)
        guard !lidos.isEmpty, lidos.count == v.split(separator: ",").count else {
            FileHandle.standardError.write("\(partes[0])=\(v): use LxA[,LxA...] em pixels\n".data(using: .utf8)!)
            exit(2)
        }
        if partes[0] == "--telas" { telas = lidos } else { tamanhos = lidos }
    // A escala escolhida na tela inicial, para `--telas` (2x por padrão, como no app).
    case ("--escala", let v?): escalaDasTelas = ModoDoMonitorVirtual.Escala(rawValue: v) ?? .dobro
    case ("--indice-base", let v?): indiceBase = max(1, Int(v) ?? 1)
    default:
        FileHandle.standardError.write("argumento desconhecido: \(argumento)\n".data(using: .utf8)!)
        exit(2)
    }
}
let voltas = escalas
let espera = segundos

print("api disponivel: \(MonitorVirtual.disponivel) | auxiliar: \(MonitorVirtualAuxiliar.localizar()?.path ?? "NÃO ACHADO")")

final class Resultado: @unchecked Sendable { var aprovadas = 0; var feito = false; var juntosOk = false }
let resultado = Resultado()
let quantosJuntos = juntos
let tamanhosJuntos = tamanhos
let telasJuntas = telas
let escalaPedida = escalaDasTelas
// Oito índices por segundo de relógio: duas corridas nunca dividem identidade se cada uma subir até 8.
let primeiroIndice = indiceBase ?? (1_000 + 8 * (Int(Date().timeIntervalSince1970) % 1_000_000))

func online(_ id: CGDirectDisplayID) -> Bool {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids.prefix(Int(n)).contains(id)
}

func ativos() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

/// N monitores ao mesmo tempo. Propriedade de monitor, nunca pixel.
func correrJuntos(_ n: Int) async -> Bool {
    // `i` é o índice; a lista de formatos anda a partir do primeiro índice.
    func modo(_ i: Int) -> ModoDoMonitorVirtual {
        let k = i - primeiroIndice
        if !telasJuntas.isEmpty {
            let (l, a) = telasJuntas[k % telasJuntas.count]
            if let m = ModoDoMonitorVirtual.paraTela(larguraPx: l, alturaPx: a, hertz: ModoDoMonitorVirtual.hertzPadrao,
                                                     escala: escalaPedida) {
                return m
            }
            print("!! tela \(l)x\(a): pequena demais para monitor — o produto usaria o tablet")
            return .tabletDaBancada(escala: .dobro)
        }
        guard !tamanhosJuntos.isEmpty else { return .tabletDaBancada(escala: .dobro) }
        let (l, a) = tamanhosJuntos[k % tamanhosJuntos.count]
        return ModoDoMonitorVirtual(larguraEmPixels: l, alturaEmPixels: a,
                                    hertz: ModoDoMonitorVirtual.hertzPadrao, escala: .dobro)
    }
    // Identidades fora das do produto (ver o cabeçalho): uma sessão de verdade que comece no meio da
    // medida nunca sobe um monitor com a mesma identidade de um destes.
    let indices = Array(primeiroIndice..<(primeiroIndice + max(1, n)))
    print("\n== \(n) monitor(es) ao mesmo tempo, índices \(indices.first!)…\(indices.last!): "
          + indices.map { modo($0).descricao }.joined(separator: " | "))
    var monitores: [(indice: Int, aux: MonitorVirtualAuxiliar)] = []
    var falhas: [String] = []
    // Um depois do outro, como receptores chegando em momentos diferentes.
    for i in indices {
        do {
            let aux = try await MonitorVirtualAuxiliar.subir(modo: modo(i), nome: "Quall (sonda \(i))", indice: i)
            print("[\(i)] série \(MonitorVirtual.serie(para: modo(i).escala, indice: i)): \(aux.relato)")
            // **Estrito** (achado 8 da revisão de 10/09): nascer em outra escala e ser aceito é o
            // que o produto faz com a escala lembrada, mas aqui esconderia exatamente a regra medida.
            if !aux.relato.contains("já no modo pedido") {
                falhas.append("[\(i)] não nasceu no modo pedido (\(modo(i).descricao))")
            }
            if aux.relato.contains("!! 2x não existe") {
                falhas.append("[\(i)] caiu para 1x")
            }
            monitores.append((i, aux))
        } catch {
            falhas.append("[\(i)] não subiu: \(error)")
        }
    }

    // Todos de pé: o arranjo que o WindowServer montou, com os monitores do usuário junto.
    let lista = ativos()
    print("monitores ativos: \(lista.count)")
    for id in lista {
        let b = CGDisplayBounds(id)
        let espelho = CGDisplayMirrorsDisplay(id)
        print("   id=\(id) nosso=\(MonitorVirtual.ehNosso(id)) série=\(CGDisplaySerialNumber(id)) "
              + "x=\(Int(b.minX))…\(Int(b.maxX)) y=\(Int(b.minY))…\(Int(b.maxY)) "
              + "principal=\(CGDisplayIsMain(id) != 0) espelha=\(espelho == kCGNullDirectDisplay ? "-" : String(espelho))")
    }
    let nossos = monitores.map(\.aux.displayID)
    for (i, id) in zip(monitores.map(\.indice), nossos) {
        let b = CGDisplayBounds(id)
        if !lista.contains(id) { falhas.append("[\(i)] não está entre os ativos (espelho?)") }
        if CGDisplayIsMain(id) != 0 { falhas.append("[\(i)] virou o monitor principal") }
        if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { falhas.append("[\(i)] está espelhando") }
        // A área em pontos da escala pedida — a estrita, como o relato acima.
        let area = (Int(b.width), Int(b.height))
        let m = modo(i)
        if area != (m.larguraEmPontos, m.alturaEmPontos) {
            falhas.append("[\(i)] área \(area.0)x\(area.1) pt, e não \(m.rotulo)")
        }
    }
    let series = nossos.map { CGDisplaySerialNumber($0) }
    if Set(series).count != series.count { falhas.append("séries repetidas: \(series)") }
    for (a, ia) in lista.enumerated() {
        for ib in lista[(a + 1)...] where CGDisplayBounds(ia).intersection(CGDisplayBounds(ib)).width > 0
            && CGDisplayBounds(ia).intersection(CGDisplayBounds(ib)).height > 0 {
            falhas.append("sobreposição entre \(ia) e \(ib)")
        }
    }

    try? await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000))

    // Soltar um de cada vez: os que ficam têm de continuar de pé.
    for (k, m) in monitores.enumerated() {
        let linha = await m.aux.soltar()
        print("[\(m.indice)] \(linha)")
        if linha.contains("CONTINUA ONLINE") { falhas.append("[\(m.indice)] não sumiu depois de solto") }
        for resto in monitores[(k + 1)...] where !online(resto.aux.displayID) {
            falhas.append("soltar [\(m.indice)] derrubou [\(resto.indice)]")
        }
    }

    for f in falhas { print("FALHA: \(f)") }
    return falhas.isEmpty && monitores.count == n
}

// Fora da main, de propósito: é de uma `Task.detached` que o produto sobe o monitor. A main fica
// girando o run loop, que é o que ela faz no app.
Task.detached {
    defer { DispatchQueue.main.async { resultado.feito = true } }
    if quantosJuntos > 0 {
        resultado.juntosOk = await correrJuntos(quantosJuntos)
        return
    }
    for (i, escala) in voltas.enumerated() {
        let modo = ModoDoMonitorVirtual.tabletDaBancada(escala: escala)
        print("\n== volta \(i + 1)/\(voltas.count): \(modo.descricao)")
        do {
            let monitor = try await MonitorVirtualAuxiliar.subir(modo: modo, nome: "Quall (sonda)")
            let id = monitor.displayID
            print(monitor.relato)

            let limites = CGDisplayBounds(id)
            let atual = CGDisplayCopyDisplayMode(id)
            print("CoreGraphics (visto do app): bounds \(Int(limites.width))x\(Int(limites.height)) | modo "
                  + (atual.map { "\($0.width)x\($0.height) pt / \($0.pixelWidth)x\($0.pixelHeight) px @\(Int($0.refreshRate)) Hz" } ?? "nenhum")
                  + " | ehNosso=\(MonitorVirtual.ehNosso(id)) principal=\(CGDisplayIsMain(id) != 0)")
            // **Quem confere o modo é o auxiliar**, no processo que criou o monitor: ele lança erro se os
            // pixels vierem errados, e o relato acima diz com que modo o monitor nasceu. Visto **deste**
            // processo, `CGDisplayCopyDisplayMode` não é testemunha confiável para monitor virtual de
            // outro processo — medido: devolve nada a partir do segundo monitor numa CLI, e já no
            // primeiro com `NSApplication` inicializado. O que este lado consegue afirmar é que o
            // monitor existe, é nosso e tem a área pedida em pontos (1x ou 2x).
            let pontosAceitos = [(modo.larguraEmPixels, modo.alturaEmPixels),
                                 (modo.larguraEmPixels / 2, modo.alturaEmPixels / 2)]
            let bateu = MonitorVirtual.ehNosso(id)
                && pontosAceitos.contains { $0.0 == Int(limites.width) && $0.1 == Int(limites.height) }
            try await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000))
            let linha = await monitor.soltar()
            print(linha)
            let sumiu = !linha.contains("CONTINUA ONLINE")
            if bateu && sumiu {
                resultado.aprovadas += 1
                print("volta \(i + 1): ok")
            } else {
                print("volta \(i + 1): FALHOU — " + (bateu ? "" : "monitor não é nosso ou tem área fora de 1x/2x; ")
                      + (sumiu ? "" : "monitor não sumiu"))
            }
        } catch {
            print("volta \(i + 1): FALHOU — \(error)")
        }
    }
}
// O run loop principal roda, como no app. (Ele não muda a leitura de modo descrita acima — medido.)
while !resultado.feito {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
if quantosJuntos > 0 {
    print("\nveredito: \(resultado.juntosOk ? "APROVADO" : "REPROVADO") (\(quantosJuntos) monitores juntos)")
    exit(resultado.juntosOk ? 0 : 1)
}
let aprovado = resultado.aprovadas == voltas.count && !voltas.isEmpty
print("\nveredito: \(aprovado ? "APROVADO" : "REPROVADO") (\(resultado.aprovadas)/\(voltas.count) voltas)")
exit(aprovado ? 0 : 1)
