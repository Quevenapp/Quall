import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// O app anfitrião. Ele existe por três motivos, e só o primeiro é obrigatório do sistema:
//
// 1. **Instalar a extensão.** Só um app que carrega a extensão dentro de si pode pedir a
//    ativação; não há linha de comando equivalente.
// 2. **Ser o dono da rede e do pareamento.** É aqui que há interface para o PIN e permissão de
//    Rede Local com um responsável visível.
// 3. **Empurrar quadro** para o fluxo de entrada da extensão.
//
// A interface por argumentos existe para a bancada: um app de janela não se dirige por script, e
// toda medição deste projeto precisa ser reproduzível por linha de comando.

let argumentos = Array(CommandLine.arguments.dropFirst())
let comando = argumentos.first ?? "estado"

// Lançado pelo LaunchServices (`open -a`), este app não herda terminal: stdout e stderr não vão
// para lugar nenhum. E lançar pelo LaunchServices deixou de ser opcional — é o que faz o pedido
// de permissão de Câmera sair com o nome deste app, e não com o de quem abriu o shell (ver
// `Permissao`). Sem um destino em arquivo, a medição aconteceria e ninguém leria o resultado.
//
// Os dois fluxos abrem em modo `a`: com `O_APPEND` cada escrita vai para o fim do arquivo, e as
// duas descrições não sobrescrevem uma a outra. E sem enfileiramento, porque um `open -a` pode
// ser morto no meio e o que já foi dito precisa estar em disco.
/// O código com que o app pretende sair. Começa em -1 de propósito: se o sentinela sair com -1, o
/// processo terminou por um caminho que não passou por `sair(_:)`, e o script não deve ler isso
/// como sucesso.
var codigoDeSaida: Int32 = -1

/// Sai gravando o código, para que o sentinela do relatório diga a verdade.
func sair(_ codigo: Int32) -> Never {
    codigoDeSaida = codigo
    exit(codigo)
}

if let i = argumentos.firstIndex(of: "--relatorio"), i + 1 < argumentos.count {
    let caminho = argumentos[i + 1]
    try? FileManager.default.removeItem(atPath: caminho)
    freopen(caminho, "a", stdout)
    freopen(caminho, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)

    // O sentinela. `open -W` deveria esperar o app terminar e falhou em 2026-08-24 com
    // "GetProcessPID() returned 18446744073709551016" — (uint64)(-600), procNotFound: o app sai
    // rápido demais para o LaunchServices conseguir registrá-lo. Noutra corrida o -W funcionou, o
    // que é pior: um `wait` que às vezes espera é um `wait` que não serve para prova.
    //
    // Quem espera passa a ser o script, lendo esta linha. Ela sai por `atexit`, então vale para
    // qualquer caminho de saída, inclusive os que não passam por `sair(_:)` — e nesses o código
    // sai -1, dizendo isso.
    atexit {
        print("APP FIM rc=\(codigoDeSaida)")
        fflush(stdout)
    }
}

// Gancho de pânico (dívida 11). O workspace usa `panic = "abort"` com `strip`: sem isto, um
// pânico do núcleo chega como um `SIGABRT` mudo e o diagnóstico começa do zero. O gancho ainda
// roda antes do abort, então a mensagem sobrevive se alguém a escrever — e aqui ela vai para o
// `os_log`, que é a única janela para dentro deste app quando ele roda sem terminal.
quall_install_panic_hook({ mensagem, _ in
    let texto = mensagem.map { RegistroSeguro.motivo(String(cString: $0)) } ?? "pânico sem mensagem"
    registroDoApp.fault("NÚCLEO EM PÂNICO: \(texto, privacy: .public)")
    FileHandle.standardError.write(("APP NÚCLEO EM PÂNICO: " + texto + "\n").data(using: .utf8)!)
}, nil)

func valor(de bandeira: String, padrao: Double) -> Double {
    guard let i = argumentos.firstIndex(of: bandeira), i + 1 < argumentos.count,
          let v = Double(argumentos[i + 1]) else { return padrao }
    return v
}

switch comando {
case "ativar":
    let a = Ativacao { codigo in exit(codigo) }
    a.ativar()
    RunLoop.main.run()

case "desativar":
    let a = Ativacao { codigo in exit(codigo) }
    a.desativar()
    RunLoop.main.run()

case "estado":
    listarDispositivos()
    exit(0)

case "alimentar":
    alimentar(segundos: valor(de: "--segundos", padrao: 10),
              fps: valor(de: "--fps", padrao: 30))
    exit(0)

case "testemunhar":
    var arquivo = "/tmp/quall-camera-testemunha.png"
    if let i = argumentos.firstIndex(of: "--saida"), i + 1 < argumentos.count { arquivo = argumentos[i + 1] }
    sair(Testemunha.correr(saida: arquivo, segundos: valor(de: "--segundos", padrao: 3)))

case "receber":
    guard let i = argumentos.firstIndex(of: "--ip"), i + 1 < argumentos.count else {
        dizer("receber precisa de --ip ENDEREÇO[:porta]")
        exit(2)
    }
    let endereco = argumentos[i + 1]
    var pin: String?
    if let j = argumentos.firstIndex(of: "--pin"), j + 1 < argumentos.count { pin = argumentos[j + 1] }
    let receptor = Receptor()
    receptor.medirFaixa = argumentos.contains("--medir-faixa")
    exit(receptor.correr(endereco: endereco,
                         pin: pin,
                         segundos: valor(de: "--segundos", padrao: 30),
                         prazoMs: UInt32(valor(de: "--prazo-ms", padrao: 60_000))))

case "emitir":
    var pin = "123456"
    if let j = argumentos.firstIndex(of: "--pin"), j + 1 < argumentos.count { pin = argumentos[j + 1] }
    let emissor = Emissor()
    exit(emissor.correr(pin: pin,
                        porta: UInt16(valor(de: "--porta", padrao: 7877)),
                        segundos: valor(de: "--segundos", padrao: 30),
                        fps: valor(de: "--fps", padrao: 30),
                        prazoMs: UInt32(valor(de: "--prazo-ms", padrao: 60_000))))

case "medir":
    var arquivo: String?
    if let i = argumentos.firstIndex(of: "--saida"), i + 1 < argumentos.count { arquivo = argumentos[i + 1] }
    sair(Cronometro.correr(segundos: valor(de: "--segundos", padrao: 15), saidaPNG: arquivo))

case "esquecer":
    guard let i = argumentos.firstIndex(of: "--id"), i + 1 < argumentos.count else {
        dizer("esquecer precisa de --id DEVICE_ID (ou --id todos)")
        exit(2)
    }
    exit(esquecerPar(argumentos[i + 1]))

case "placa":
    // Desenha as duas placas num PNG, sem câmera e sem rede. Existe porque a placa de espera é a
    // única coisa que a extensão tem para **falar com o usuário** — ela não tem janela nem
    // notificação —, e conferir o texto abrindo a câmera exigiria permissão de Câmera. Aqui o
    // mesmo código de desenho roda no app e o resultado pode ser olhado.
    var pasta = "/tmp/quall-camera-prova"
    if let i = argumentos.firstIndex(of: "--pasta"), i + 1 < argumentos.count { pasta = argumentos[i + 1] }
    exit(desenharPlacas(em: pasta))

case "pares":
    let caminho = Receptor.arquivoDePares()
    // Diagnóstico, não exportação: o arquivo contém segredos de retomada do pareamento.
    dizer(RegistroSeguro.pares(try? String(contentsOf: caminho, encoding: .utf8)))
    exit(0)

default:
    dizer("""
    comandos:
      ativar
      desativar
      estado
      alimentar [--segundos N] [--fps N]
      testemunhar [--saida arquivo.png] [--segundos N]
      receber --ip ENDEREÇO[:porta] [--pin 123456] [--segundos N] [--prazo-ms N] [--medir-faixa]
      emitir [--pin 123456] [--porta 7877] [--segundos N] [--fps N]   (emissor de bancada)
      medir [--segundos N] [--saida arquivo.png]                      (latência ponta a ponta)

    global:
      --relatorio ARQ    manda stdout e stderr para ARQ (obrigatório sob `open -a`)
      placa [--pasta DIR]                                             (as placas em PNG)
      pares
      esquecer --id DEVICE_ID | --id todos
    """)
    exit(2)
}

// MARK: - Placas

func desenharPlacas(em pasta: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: pasta, withIntermediateDirectories: true)
    let atributos: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: Identidade.largura,
        kCVPixelBufferHeightKey: Identidade.altura,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var reservatorio: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reservatorio)
    guard let reservatorio else { dizer("sem reservatório"); return 1 }

    func gravar(_ nome: String, _ desenhar: (CVPixelBuffer) -> Void) -> Bool {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &buffer) == kCVReturnSuccess,
              let buffer else { return false }
        desenhar(buffer)
        let contexto = CIContext()
        let imagem = CIImage(cvPixelBuffer: buffer)
        guard let cg = contexto.createCGImage(imagem, from: imagem.extent),
              let destino = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: "\(pasta)/\(nome)") as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destino, cg, nil)
        guard CGImageDestinationFinalize(destino) else { return false }
        dizer("placa PNG gravada: \(nome)")
        return true
    }

    var ok = gravar("placa-de-espera.png") { Placa.desenharEspera(em: $0, marca: 0) }
    ok = gravar("placa-de-espera-sem-ponto.png") { Placa.desenharEspera(em: $0, marca: 20) } && ok
    ok = gravar("placa-de-teste.png") { b in
        Placa.desenharPlacaDeTeste(numero: 123456, em: b)
        Faixa.desenhar(valorMs: 1_048_575, em: b)
    } && ok
    // Conferência de ida e volta da faixa, sem rede: o que foi desenhado é o que se lê?
    var buffer: CVPixelBuffer?
    if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &buffer) == kCVReturnSuccess,
       let buffer {
        var errados = 0
        for valor in stride(from: UInt64(0), to: Faixa.modulo, by: 977) {
            Faixa.desenhar(valorMs: valor, em: buffer)
            if Faixa.ler(de: buffer) != valor { errados += 1 }
        }
        dizer("faixa ida e volta: \(errados) erro(s) em \(Faixa.modulo / 977) valores")
        ok = ok && errados == 0
    }
    return ok ? 0 : 1
}

// MARK: - Pareamento

func esquecerPar(_ id: String) -> Int32 {
    let caminho = Receptor.arquivoDePares()
    guard let antes = try? String(contentsOf: caminho, encoding: .utf8) else {
        dizer("não há pareamentos gravados/legíveis")
        return 0
    }
    if id == "todos" {
        try? FileManager.default.removeItem(at: caminho)
        dizer("pareamentos apagados; o próximo pareamento pede autenticação")
        return 0
    }
    guard let depois = Nucleo.esquecerPar(antes, deviceId: id) else {
        dizer("o núcleo não devolveu a tabela após o pedido de esquecer um par")
        return 1
    }
    do {
        try depois.write(to: caminho, atomically: true, encoding: .utf8)
        dizer("par esquecido; o próximo pareamento com ele pede autenticação")
        return 0
    } catch {
        dizer("não deu para gravar: \(RegistroSeguro.erro(error))")
        return 1
    }
}

// MARK: - Estado

func listarDispositivos() {
    ClienteDoSumidouro.permitirDispositivosVirtuais()
    let ids = ClienteDoSumidouro.dispositivos()
    dizer("CoreMediaIO enxerga \(ids.count) dispositivo(s)")
    for id in ids {
        let uid = ClienteDoSumidouro.textoDoDispositivo(id, seletor: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) ?? "?"
        let fluxos = ClienteDoSumidouro.fluxos(de: id)
        let direcoes = fluxos.map { ClienteDoSumidouro.direcao($0).map(String.init) ?? "?" }.joined(separator: ",")
        let nosso = uid.lowercased() == Identidade.idDoDispositivo.uuidString.lowercased() ? "  <<< QUALL" : ""
        dizer("  id_local=\(id) fluxos=\(fluxos.count) direções=[\(direcoes)]\(nosso)")
    }
}

// MARK: - Alimentar o fluxo de entrada

func alimentar(segundos: Double, fps: Double) {
    let cliente = ClienteDoSumidouro()
    // `QUALL_SEM_CAMERA=1` mede o **controle negativo**: tudo o que o app faz por quadro menos a
    // travessia entre processos. A diferença entre as duas corridas é o custo real da fronteira,
    // e sem o controle qualquer número que eu medisse do outro lado seria custo de desenhar
    // disfarçado de custo de IPC.
    let semCamera = ProcessInfo.processInfo.environment["QUALL_SEM_CAMERA"] == "1"
    if semCamera {
        dizer("QUALL_SEM_CAMERA=1: controle negativo, sem travessia entre processos")
    } else {
        do {
            try cliente.abrir()
        } catch {
            dizer("não deu para abrir o fluxo de entrada: \(RegistroSeguro.erro(error))")
            exit(1)
        }
        dizer("fluxo de entrada aberto: dispositivo=\(cliente.idDoDispositivo) fluxo=\(cliente.idDoFluxo) capacidade_da_fila=\(cliente.capacidadeDaFila)")
    }

    let atributos: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: Identidade.largura,
        kCVPixelBufferHeightKey: Identidade.altura,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var reservatorio: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, atributos as CFDictionary, &reservatorio)
    guard let reservatorio else { dizer("sem reservatório"); exit(1) }

    let extensoes: [CFString: Any] = [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ]
    var descricao: CMFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                   codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   width: Identidade.largura, height: Identidade.altura,
                                   extensions: extensoes as CFDictionary,
                                   formatDescriptionOut: &descricao)
    guard let descricao else { dizer("sem descrição de formato"); exit(1) }

    let total = Int(segundos * fps)
    let periodo = 1.0 / fps
    var custosDesenho: [UInt64] = []
    var custosEnfileirar: [UInt64] = []
    custosDesenho.reserveCapacity(total)
    custosEnfileirar.reserveCapacity(total)

    let inicioDaCorrida = Medidas.agoraUs()
    var proximo = Date()
    // O contador começa alto de propósito: assim uma captura da testemunha distingue na hora um
    // quadro vindo do app de um quadro de placa gerado dentro da extensão.
    var numero = 900_000

    for _ in 0..<total {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, reservatorio, &buffer) == kCVReturnSuccess,
              let buffer else { continue }

        let t0 = Medidas.agoraUs()
        Placa.desenharPlacaDeTeste(numero: numero, em: buffer)
        numero += 1
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let t1 = Medidas.agoraUs()

        var tempo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var amostra: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: buffer,
                                                 formatDescription: descricao,
                                                 sampleTiming: &tempo,
                                                 sampleBufferOut: &amostra)
        if let amostra {
            cliente.empurrar(amostra)
        }
        let t2 = Medidas.agoraUs()

        custosDesenho.append(t1 - t0)
        custosEnfileirar.append(t2 - t1)

        proximo = proximo.addingTimeInterval(periodo)
        let espera = proximo.timeIntervalSinceNow
        if espera > 0 { Thread.sleep(forTimeInterval: espera) }
    }

    let duracao = Double(Medidas.agoraUs() - inicioDaCorrida) / 1_000_000
    cliente.fechar()

    func resumo(_ nome: String, _ v: [UInt64]) {
        guard !v.isEmpty else { return }
        let ordenado = v.sorted()
        let media = v.reduce(0, +) / UInt64(v.count)
        let p50 = ordenado[ordenado.count / 2]
        let p95 = ordenado[min(ordenado.count - 1, Int(Double(ordenado.count) * 0.95))]
        dizer("\(nome): n=\(v.count) média=\(media)us p50=\(p50)us p95=\(p95)us max=\(ordenado.last!)us")
    }

    var uso = rusage()
    getrusage(RUSAGE_SELF, &uso)
    let cpu = Double(uso.ru_utime.tv_sec) + Double(uso.ru_utime.tv_usec) / 1e6
        + Double(uso.ru_stime.tv_sec) + Double(uso.ru_stime.tv_usec) / 1e6

    dizer("corrida de \(String(format: "%.2f", duracao))s a \(fps) fps")
    resumo("desenhar o quadro", custosDesenho)
    resumo("enfileirar (a travessia entre processos)", custosEnfileirar)
    dizer("enfileirados=\(cliente.enfileirados) descartados=\(cliente.descartados)")
    // A fluidez do mesmo `ClienteDoSumidouro`, aqui alimentado por um laço com `Thread.sleep`.
    // Neste comando ela é **aferição do instrumento**, não medida do produto: a origem é local e
    // cadenciada por nós, então o esperado é `p50 ≈ 1000/fps` e `trancos=0`. Um tranco aqui é
    // tranco desta máquina, e é justamente o que se quer saber antes de culpar a rede. Ver
    // `Fluidez`.
    dizer("\(cliente.linhaDeFluidez)  (origem local cadenciada: é o piso do instrumento)")
    dizer("CPU do app=\(String(format: "%.1f", 100 * cpu / duracao))% de um núcleo; pegada=\(Medidas.pegadaDeMemoria()) bytes")
}
