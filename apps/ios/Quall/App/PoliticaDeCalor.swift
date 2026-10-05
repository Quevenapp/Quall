import Foundation

/// **A política de calor da câmera no iOS** (R5 fase 5, `docs/teleprompter-com-camera.md` §8.12.1).
///
/// Contas puras, sem relógio e sem sistema: quem as chama passa o estado térmico (o `rawValue` de
/// `ProcessInfo.ThermalState`: 0 nominal, 1 fair, 2 serious, 3 critical) e o instante. Por isso elas
/// rodam no MacBook (`Testes/rodar.sh`), sem aparelho quente.
///
/// A bancada de 27/09 que as motivou: o iPhone 7 (o piso Apple) passou 30 min em `.serious`
/// gravando 1080p30 e transmitindo, e a gravação caiu a 27 fps com buracos de 1,3 s, e o receptor
/// recusou o relógio do vídeo da rede (até 2,7 s atrás do som).
enum PoliticaDeCalor {

    /// `ProcessInfo.ThermalState.serious.rawValue`: daqui para cima, o aparelho está quente.
    static let quente = 2
    /// `ProcessInfo.ThermalState.critical.rawValue`.
    static let critico = 3

    /// O teto da rede e o da gravação quando quente: 720p, em qualquer orientação.
    static let tetoQuente = (maior: 1280, menor: 720)

    /// O teto da **rede**: o do cardápio, ou 720p com a rede reduzida (o menor dos dois — um cardápio
    /// em 720p não sobe).
    static func tetoDaRede(cardapio: (maior: Int, menor: Int), reduzida: Bool) -> (maior: Int, menor: Int) {
        guard reduzida else { return cardapio }
        return (min(cardapio.maior, tetoQuente.maior), min(cardapio.menor, tetoQuente.menor))
    }

    /// **O fps da rede quente**: 15 (§8.12.8). A bancada de 27/09 à tarde (iPhone 7, `.serious` por
    /// 25 min) mostrou a rede em 720p segurando o relógio, e a **gravação** caindo a 25,7 fps com a
    /// captura perdendo quadros por atraso (`FrameWasLate`, ~40/s): a fila da câmera submete cada
    /// quadro a dois encoders. A rede é o encoder a mais; metade dos quadros dela é metade dessa
    /// submissão, e a gravação (o produto) fica com os 30. Hipótese: não medido ainda.
    static let fpsQuente = 15

    static func fpsDaRede(cardapio: Int, reduzida: Bool) -> Int {
        reduzida ? max(1, min(cardapio, fpsQuente)) : max(1, cardapio)
    }

    /// A taxa da rede pelo estado: a metade em `.serious` (e no modo de baixo consumo), um quarto em
    /// `.critical`. É a regra que o `EmissorDeCamera` já tinha desde o começo, agora num lugar só,
    /// para o encoder refeito já nascer com ela (antes nascia com a taxa do tamanho anterior).
    static func taxaDaRede(base: Int, termico: Int, economia: Bool) -> Int {
        if termico >= critico { return base / 4 }
        if termico >= quente || economia { return base / 2 }
        return base
    }

    /// O tamanho do arquivo de uma gravação que **começa** agora: a captura inteira, ou reduzida a
    /// 720p (na mesma orientação e proporção) quando o aparelho está quente ao tocar em Gravar. Uma
    /// gravação de pé nunca muda (o arquivo é um só).
    static func tamanhoDaGravacao(largura: Int32, altura: Int32, quente: Bool) -> (Int32, Int32) {
        guard quente else { return (largura, altura) }
        return CodificadorH264.destino(largura: Int(largura), altura: Int(altura),
                                       tetoMaior: tetoQuente.maior, tetoMenor: tetoQuente.menor)
    }

    /// O aviso da faixa no `.critical` (nunca entre o texto e a lente).
    static func aviso(termico: Int) -> String? {
        guard termico >= critico else { return nil }
        return tr("O aparelho está muito quente: a imagem pode travar. Pare a gravação ou deixe esfriar.")
    }

    /// O nome do estado, para o diário.
    static func nome(_ termico: Int) -> String {
        switch termico {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious"
        case 3: return "critical"
        default: return "?\(termico)"
        }
    }
}

/// **A rede reduzida pelo calor, com histerese.** Reduz na hora em `.serious` ou acima; volta ao
/// cardápio só depois de `esfriarPor` segundos seguidos abaixo disso. Refazer o encoder custa um IDR
/// (uma rajada), e um aparelho na borda entre `.fair` e `.serious` não pode trocar de tamanho a cada
/// leitura.
struct RedeReduzidaPeloCalor {
    static let esfriarPor: Double = 60

    private(set) var reduzida = false
    /// Desde quando (no relógio de quem chama) o estado está abaixo de quente, com a rede reduzida.
    private var frioDesde: Double?

    /// Uma leitura do estado. Devolve `true` quando `reduzida` mudou.
    mutating func observar(termico: Int, agora: Double) -> Bool {
        if termico >= PoliticaDeCalor.quente {
            frioDesde = nil
            guard !reduzida else { return false }
            reduzida = true
            return true
        }
        guard reduzida else { return false }
        guard let desde = frioDesde else { frioDesde = agora; return false }
        guard agora - desde >= RedeReduzidaPeloCalor.esfriarPor else { return false }
        reduzida = false
        frioDesde = nil
        return true
    }
}

/// **O atraso que cresce não sai pela rede** (§8.12.1, §8.12.8): um quadro de vídeo, ou um buffer
/// do microfone, que chega ao emissor com a fila atrasada é pulado antes do encoder — nada foi
/// codificado, então nada se quebra (o vídeo não perde referência; o microfone vê uma
/// descontinuidade e reancora o carimbo para a frente). É o que transforma um atraso que cresce sem
/// fim num atraso com teto.
///
/// - **Pelo piso, e não pela idade de cada um** (bancada de 27/09 à tarde, iPhone 7): quente, o som
///   chega **em rajadas** — vários buffers de uma vez, os primeiros da rajada com 300–440 ms e o último
///   novo. Pular pela idade de cada um cortava o começo de toda rajada (8–10 buffers, 170–213 ms de
///   buraco, várias vezes por segundo: metade do som da rede) sem atraso nenhum a escoar. O que o
///   receptor mede é o **mínimo** do trânsito por janela, e é o mesmo que aqui decide: a regra começa
///   a pular só quando **a menor idade das últimas `janela` entradas** passa de `alto` — uma fila
///   atrasada de verdade, e não o começo de uma rajada.
/// - **Com histerese**: pulando, segue pulando até uma entrada chegar com `baixo` ou menos (a fila
///   se escoou); aí para, e o piso recomeça do zero.
/// - **Só na entrada.** Descartar na saída do encoder e esperar um IDR vira tempestade de IDR com o
///   encoder lento o tempo todo (revisão da política de 27/09, B2).
/// - **Não confia cegamente no relógio** (M1): idade abaixo de −50 ms é relógio incoerente (passa,
///   contada); `desistirDepoisDe` pulados seguidos também — a regra desiste e deixa tudo passar até
///   chegar uma entrada com `baixo` ou menos (o piso cai); para pular de novo, a janela inteira tem
///   de ser velha outra vez. Um relógio errado, ou um atraso constante legítimo (um microfone
///   Bluetooth), não vira apagão.
///
/// Os contadores são da janela do relato: quem relata chama `zerarContadores`. Não é seguro entre
/// threads: quem usa guarda sob a própria trava.
struct DescarteDeVelhos {
    /// Abaixo disto, a idade é impossível: o relógio lido não é o do PTS.
    static let idadeImpossivel: Double = -0.05

    /// Hipóteses de trabalho: um quadro da câmera chega ao emissor com ~30–100 ms (medido 54–100 ms
    /// no iPhone 7, 27/09), e um buffer do microfone com a duração dele (~21 ms) mais isso. O piso
    /// sobre ~1 s de entradas (30 quadros, 47 buffers de 1024 amostras). **Não garantem o relógio do
    /// receptor** (ele recusa acima de 150 ms em duas janelas): limitam o dano.
    static func doVideo() -> DescarteDeVelhos {
        DescarteDeVelhos(alto: 0.25, baixo: 0.15, janela: 30, desistirDepoisDe: 150)
    }
    /// O som: o teto de ~1 s da troca atraso × picote (§8.12.14) — no calor o som da rede atrasa, inteiro,
    /// até ~1 s; só uma fila acima disso (o piso de ~1 s de entradas passando de 1,2 s) é escoada.
    static func doSom() -> DescarteDeVelhos {
        DescarteDeVelhos(alto: 1.2, baixo: 0.8, janela: 47, desistirDepoisDe: 250)
    }

    let alto: Double
    let baixo: Double
    let janela: Int
    let desistirDepoisDe: Int

    private(set) var velhos: UInt64 = 0
    private(set) var relogioIncoerente: UInt64 = 0
    /// Velhos que passaram porque a regra desistiu.
    private(set) var passaramVelhos: UInt64 = 0
    /// O maior piso visto desde o último relato (o atraso de fila, sem as rajadas).
    private(set) var pisoMaximo: Double = 0
    private(set) var pulando = false
    private(set) var desistiu = false
    private var idades: [Double] = []
    private var proxima = 0
    private var seguidos = 0

    init(alto: Double, baixo: Double, janela: Int, desistirDepoisDe: Int) {
        self.alto = alto
        self.baixo = min(baixo, alto)
        self.janela = max(1, janela)
        self.desistirDepoisDe = max(1, desistirDepoisDe)
        idades.reserveCapacity(self.janela)
    }

    /// A menor idade das últimas `janela` entradas; `nil` antes de a janela encher.
    var piso: Double? { idades.count < janela ? nil : idades.min() }

    private mutating func lembrar(_ idade: Double) {
        if idades.count < janela { idades.append(idade) } else { idades[proxima] = idade }
        proxima = (proxima + 1) % janela
    }

    private mutating func esquecer() {
        idades.removeAll(keepingCapacity: true)
        proxima = 0
    }

    /// `true` se segue ao encoder.
    mutating func entrada(idade: Double?) -> Bool {
        guard let idade else { return true }
        if idade < DescarteDeVelhos.idadeImpossivel {
            relogioIncoerente &+= 1
            return true
        }
        lembrar(idade)
        if let p = piso { pisoMaximo = max(pisoMaximo, p) }
        if desistiu {
            // Religa **pelo piso**, e não por novos seguidos (a revisão de 27/09 à tarde: com rajadas,
            // 30 novos seguidos nunca acontecem, e a regra ficaria desligada a sessão inteira).
            if let p = piso, p <= baixo {
                desistiu = false
                esquecer()
            } else if idade > alto {
                passaramVelhos &+= 1
            }
            return true
        }
        if pulando {
            guard idade > baixo else {
                // A fila se escoou: para, e o piso recomeça do zero.
                pulando = false
                seguidos = 0
                esquecer()
                return true
            }
        } else {
            guard let p = piso, p > alto else { return true }
            pulando = true
        }
        seguidos += 1
        if seguidos > desistirDepoisDe {
            desistiu = true
            pulando = false
            seguidos = 0
            passaramVelhos &+= 1
            return true
        }
        velhos &+= 1
        return false
    }

    mutating func zerarContadores() {
        velhos = 0
        relogioIncoerente = 0
        passaramVelhos = 0
        pisoMaximo = 0
    }
}

/// **Os degraus da transmissão** (decisão do Pessoa Exemplo de 27/09, §8.12.15–8.12.16): **com a transmissão de
/// pé, ela é a prioridade**. Cada degrau só se o anterior não bastou, e o sinal é **o som da rede**
/// (a espera na fila do Opus ou a idade na entrada do emissor acima de ~500 ms, ou som descartado), por
/// janela de 10 s:
///
/// 0. nada (o degrau 1 da decisão, a rede em 720p no `.serious`, é da `RedeReduzidaPeloCalor`);
/// 1. **a prévia pausa** ("Prévia pausada: aparelho quente"; um toque mostra de novo);
/// 2. **a gravação para e o arquivo é salvo** — só se houver gravação de pé; sem ela, o degrau é pulado;
/// 3. **a captura em 720p** — o degrau que a medida pediu (§8.12.16): só transmitindo, o iPhone 7 quente
///    ainda perdia 4,6 % do som; sem gravação a captura 1080p só serve para ser reduzida a 720p.
///
/// Sobe depois de `ruinsParaSubir` janelas ruins seguidas (20 s), e **só desce com o calor passado**: um
/// degrau depois de `bonsParaDescer` janelas seguidas sem calor (60 s); a gravação parada não volta (o arquivo já foi salvo), então
/// descer da captura reduzida volta à prévia pausada. **Sem transmissão, tudo volta a zero** — a
/// gravação não para por calor sem transmissão. Puro: roda em `Testes/rodar.sh`.
struct DegrausDaTransmissao {
    enum Degrau: Int, Comparable {
        case nenhum = 0, previaPausada, gravacaoParada, capturaReduzida
        static func < (a: Degrau, b: Degrau) -> Bool { a.rawValue < b.rawValue }
        var nome: String {
            switch self {
            case .nenhum: return "nenhum"
            case .previaPausada: return "prévia pausada"
            case .gravacaoParada: return "gravação parada"
            case .capturaReduzida: return "captura em 720p"
            }
        }
    }

    static let ruinsParaSubir = 2
    static let bonsParaDescer = 6
    /// O limiar do som "atrasando" na janela, em segundos (a decisão: ~0,5 s).
    static let atrasoRuim: Double = 0.5

    private(set) var degrau: Degrau = .nenhum
    private var ruins = 0
    private var bons = 0

    /// A janela é ruim para o som da rede?
    static func ruim(esperaNaFila: Double, idadeNaEntrada: Double, somPerdido: Double) -> Bool {
        esperaNaFila > atrasoRuim || idadeNaEntrada > atrasoRuim || somPerdido > 0
    }

    /// Uma janela de 10 s. Devolve o degrau novo quando mudou. **Só sobe quente** (`quente`: a rede já
    /// reduzida pelo calor, o degrau 1 da decisão — "cada um só se o anterior não bastar"; revisão de
    /// 27/09, B1): num aparelho frio, um soluço do som não pausa a prévia nem para a gravação com um
    /// recado de "esquentou"; frio, a janela conta como boa (e os degraus descem).
    mutating func janela(ruim ruimMedido: Bool, transmitindo: Bool, gravando: Bool, quente: Bool) -> Degrau? {
        let ruim = ruimMedido && quente
        guard transmitindo else {
            ruins = 0; bons = 0
            guard degrau != .nenhum else { return nil }
            degrau = .nenhum
            return degrau
        }
        if ruim {
            bons = 0
            ruins += 1
            guard ruins >= DegrausDaTransmissao.ruinsParaSubir else { return nil }
            ruins = 0
            let novo: Degrau
            switch degrau {
            case .nenhum: novo = .previaPausada
            case .previaPausada: novo = gravando ? .gravacaoParada : .capturaReduzida
            case .gravacaoParada, .capturaReduzida: novo = .capturaReduzida
            }
            guard novo != degrau else { return nil }
            degrau = novo
            return novo
        }
        ruins = 0
        // **Quente, não desce** (bancada de `abd2e9f`, §8.12.17): descer da captura em 720p com o aparelho
        // ainda quente volta ao 1080p, reaquece, e sobe de novo — a oscilação vista (a captura trocada 3
        // vezes, a prévia indo e voltando). Os degraus só descem com o calor passado (`quente` falso: a
        // rede já de volta, 60 s abaixo de `.serious`), e então um degrau a cada `bonsParaDescer` janelas.
        guard !quente else { bons = 0; return nil }
        bons += 1
        guard bons >= DegrausDaTransmissao.bonsParaDescer, degrau != .nenhum else { return nil }
        bons = 0
        degrau = degrau == .previaPausada ? .nenhum : .previaPausada
        return degrau
    }
}
