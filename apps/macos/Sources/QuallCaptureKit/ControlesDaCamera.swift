import CoreVideo
import Foundation
import QuallIdiomaKit

// **Os controles de câmera do R9 no Mac** (`docs/controles-de-camera.md`), a parte pura: o registro e o
// JSON (§2), as capacidades → o que a tela mostra e que texto de limite (§3.5, §4.3), a decisão do
// clique na prévia (§4.4) e o plano de reaplicar as travas (§2.1). Nada aqui toca em `AVCaptureDevice`:
// quem lê a câmera e aplica é o `DonoDaCamera`; quem desenha é o app. Testado em
// `TestesDosControlesDaCamera`, sem câmera.
//
// # O que existe no Mac (§1)
//
// Só as travas de exposição, balanço e foco (onde a câmera aceita `.locked`), o ponto de exposição e de
// foco (onde a câmera tem ponto de interesse) e a volta ao automático. ISO, obturador, EV, Kelvin, os
// presets de balanço, o foco manual e a anti-cintilação são `API_UNAVAILABLE(macos)` no MacOSX.sdk
// (conferido no 26.5: `setExposureModeCustomWithDuration:ISO:`, `setExposureTargetBias:`,
// `setFocusModeLockedWithLensPosition:`, `deviceWhiteBalanceGainsForTemperatureAndTintValues:`,
// `lensPosition`, `ISO`) — a tela diz isso com o texto do §3.5.

/// **O registro de uma câmera** (§2), só com os campos que valem no Mac. Os nomes são os literais da
/// especificação, e o JSON usa o camelCase: `{"exposicao":"auto","travaExposicao":true,…}`.
///
/// Os campos que o Mac não aplica (`ev`, `iso`, `obturadorNs`, `antiCintilacao`, `kelvin`,
/// `travaIso`, `travaObturadorNs`, `travaGanhos`, `focoPosicao`) **não são escritos**: no Mac não há
/// como ler nem aplicar nenhum deles (`ISO`, `exposureDuration`, `deviceWhiteBalanceGains` e
/// `lensPosition` são `API_UNAVAILABLE(macos)`). Ler um JSON que os traga não falha: eles são
/// ignorados, e um valor que o Mac não conhece (`"manual"`) vira o padrão.
public struct AjustesDaCamera: Equatable, Sendable {
    /// No Mac só existe `auto`: não há exposição manual (§1).
    public enum Exposicao: String, Sendable { case auto }
    /// No Mac só existe `auto`: não há presets nem Kelvin (§1).
    public enum Balanco: String, Sendable { case auto }
    /// `manual` não existe no Mac (§1).
    public enum Foco: String, Sendable { case auto, travado }

    public var exposicao: Exposicao = .auto
    /// Só vale com `exposicao = auto`.
    public var travaExposicao = false
    public var balanco: Balanco = .auto
    /// Só vale com `balanco = auto`.
    public var travaBalanco = false
    public var foco: Foco = .auto

    public init(travaExposicao: Bool = false, travaBalanco: Bool = false, foco: Foco = .auto) {
        self.travaExposicao = travaExposicao
        self.travaBalanco = travaBalanco
        self.foco = foco
    }

    /// O padrão da tabela do §2: tudo automático. "Restaurar automático" volta a ele.
    public static let padrao = AjustesDaCamera()

    public var ehPadrao: Bool { self == .padrao }

    /// Alguma trava ligada (a reaplicação tem o que fazer).
    public var temTrava: Bool { travaExposicao || travaBalanco || foco == .travado }

    /// **O pedido cortado pelo que a câmera faz**: a trava que a câmera não aceita não entra no registro
    /// (o painel já a mostra apagada; isto segura a bancada e qualquer outro caminho). Só para o que a
    /// pessoa pede — o registro **lido** fica intacto mesmo que a câmera mude (§2.1).
    public func cortado(por c: CapacidadesDaCamera) -> AjustesDaCamera {
        var a = self
        if !c.podeTravarExposicao { a.travaExposicao = false }
        if !c.podeTravarBalanco { a.travaBalanco = false }
        if !c.podeTravarFoco { a.foco = .auto }
        return a
    }

    /// Uma linha para o diário: `exposicao=auto travaExposicao=sim travaBalanco=não foco=travado`.
    public var resumo: String {
        "exposicao=\(exposicao.rawValue) travaExposicao=\(travaExposicao ? "sim" : "não") "
            + "balanco=\(balanco.rawValue) travaBalanco=\(travaBalanco ? "sim" : "não") foco=\(foco.rawValue)"
    }
}

extension AjustesDaCamera: Codable {
    private enum Chave: String, CodingKey {
        case exposicao, travaExposicao, balanco, travaBalanco, foco
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Chave.self)
        // Tolerante: campo ausente ou valor desconhecido vira o padrão, e não um registro perdido.
        func texto(_ k: Chave) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func sim(_ k: Chave) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }
        exposicao = texto(.exposicao).flatMap(Exposicao.init(rawValue:)) ?? .auto
        travaExposicao = sim(.travaExposicao)
        balanco = texto(.balanco).flatMap(Balanco.init(rawValue:)) ?? .auto
        travaBalanco = sim(.travaBalanco)
        foco = texto(.foco).flatMap(Foco.init(rawValue:)) ?? .auto
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Chave.self)
        try c.encode(exposicao.rawValue, forKey: .exposicao)
        try c.encode(travaExposicao, forKey: .travaExposicao)
        try c.encode(balanco.rawValue, forKey: .balanco)
        try c.encode(travaBalanco, forKey: .travaBalanco)
        try c.encode(foco.rawValue, forKey: .foco)
    }

    /// O JSON do registro, com as chaves em ordem (o diário e o `defaults read` ficam estáveis).
    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(self), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Lê o JSON de um registro. `nil` só quando nem é um objeto JSON.
    public static func doJSON(_ s: String) -> AjustesDaCamera? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AjustesDaCamera.self, from: d)
    }
}

/// **Onde o registro mora** (§2): `UserDefaults`, chave `camera.ajustes.<uniqueID>`, valor = o JSON
/// (como texto). O `UserDefaults` é injetado: o produto usa o `.standard`; a bancada, um domínio
/// próprio, para uma corrida de prova não mexer no que a pessoa deixou travado.
public struct GuardaDosAjustes {
    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func chave(_ uniqueID: String) -> String { "camera.ajustes.\(uniqueID)" }

    /// O registro da câmera, ou o padrão quando não há (ou quando o guardado não se lê).
    public func ler(_ uniqueID: String) -> AjustesDaCamera {
        guard let s = defaults.string(forKey: GuardaDosAjustes.chave(uniqueID)),
              let a = AjustesDaCamera.doJSON(s) else { return .padrao }
        return a
    }

    /// Grava; o padrão **apaga a chave** ("Restaurar automático" zera o registro daquela câmera, e só
    /// dela).
    public func gravar(_ a: AjustesDaCamera, _ uniqueID: String) {
        if a.ehPadrao {
            defaults.removeObject(forKey: GuardaDosAjustes.chave(uniqueID))
        } else {
            defaults.set(a.json, forKey: GuardaDosAjustes.chave(uniqueID))
        }
    }
}

/// **O que a câmera declara**, lido do `AVCaptureDevice` pelo dono (`isXModeSupported`,
/// `is…PointOfInterestSupported`). Valores simples, para a lógica pura e os testes.
public struct CapacidadesDaCamera: Equatable, Sendable {
    public var exposicaoContinua = false   // .continuousAutoExposure
    public var exposicaoUmaVez = false     // .autoExpose (mede e trava sozinho)
    public var exposicaoTravada = false    // .locked
    public var pontoDeExposicao = false
    public var balancoContinuo = false     // .continuousAutoWhiteBalance
    public var balancoUmaVez = false       // .autoWhiteBalance
    public var balancoTravado = false      // .locked
    public var focoContinuo = false        // .continuousAutoFocus
    public var focoUmaVez = false          // .autoFocus
    public var focoTravado = false         // .locked
    public var pontoDeFoco = false

    public init(exposicaoContinua: Bool = false, exposicaoUmaVez: Bool = false, exposicaoTravada: Bool = false,
                pontoDeExposicao: Bool = false, balancoContinuo: Bool = false, balancoUmaVez: Bool = false,
                balancoTravado: Bool = false, focoContinuo: Bool = false, focoUmaVez: Bool = false,
                focoTravado: Bool = false, pontoDeFoco: Bool = false) {
        self.exposicaoContinua = exposicaoContinua
        self.exposicaoUmaVez = exposicaoUmaVez
        self.exposicaoTravada = exposicaoTravada
        self.pontoDeExposicao = pontoDeExposicao
        self.balancoContinuo = balancoContinuo
        self.balancoUmaVez = balancoUmaVez
        self.balancoTravado = balancoTravado
        self.focoContinuo = focoContinuo
        self.focoUmaVez = focoUmaVez
        self.focoTravado = focoTravado
        self.pontoDeFoco = pontoDeFoco
    }

    /// A trava existe onde a câmera aceita `.locked` (§1, "✅ se a câmera aceitar `.locked`").
    public var podeTravarExposicao: Bool { exposicaoTravada }
    public var podeTravarBalanco: Bool { balancoTravado }
    /// Sem nenhum modo automático de foco, a câmera tem **foco fixo** (§3.5). As embutidas dos Mac
    /// costumam ser assim; a prova de bancada diz.
    public var focoFixo: Bool { !focoContinuo && !focoUmaVez }
    public var podeTravarFoco: Bool { focoTravado && !focoFixo }
    /// O ponto de foco só serve onde há foco automático.
    public var podeFocarNoPonto: Bool { pontoDeFoco && !focoFixo }
    public var podeMedirNoPonto: Bool { pontoDeExposicao && (exposicaoUmaVez || exposicaoContinua) }

    /// Para o diário: `exp=c1u1t1p1 bal=c1u0t1 foco=c0u0t0p0`.
    public var resumo: String {
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        return "exp=c\(b(exposicaoContinua))u\(b(exposicaoUmaVez))t\(b(exposicaoTravada))p\(b(pontoDeExposicao)) "
            + "bal=c\(b(balancoContinuo))u\(b(balancoUmaVez))t\(b(balancoTravado)) "
            + "foco=c\(b(focoContinuo))u\(b(focoUmaVez))t\(b(focoTravado))p\(b(pontoDeFoco))"
    }
}

// MARK: - os textos (§3.5)

/// Os nomes dos controles **como aparecem dentro das frases** (§3.5). O artigo faz parte do nome.
public enum NomeDoControle: String, CaseIterable, Sendable {
    case iso = "ISO"
    case obturador = "o obturador"
    case kelvin = "o Kelvin"
    case presetsDeBalanco = "os presets de balanço"
    case focoManual = "o foco manual"
    case antiCintilacao = "a anti-cintilação"
    case compensacao = "a compensação de exposição"
    case toque = "o toque para focar"
    case travaExposicao = "a trava de exposição"
    case travaBalanco = "a trava de balanço"
    case travaFoco = "a trava de foco"
    case brilho = "o brilho"
    case ganho = "o ganho"

    /// O nome no idioma da vez (o `rawValue` é o português, e é a chave da tradução).
    public var nome: String { T(rawValue) }
}

/// As frases do §3.5, literais.
public enum TextoDoLimite {
    /// "Limite do sistema no Mac". Com mais de um nome (o grupo "ISO e obturador", que no Mac não tem
    /// nada e vira **uma linha só**), os nomes vão juntos com "e": "O macOS não oferece ISO e o
    /// obturador para câmeras."
    public static func doMacOS(_ nomes: [NomeDoControle]) -> String {
        T("O macOS não oferece %@ para câmeras.", juntar(nomes))
    }

    /// A câmera não declara o controle. A especificação dá esta frase para o Windows; no Mac ela serve
    /// para a trava que a câmera não aceita (`isXModeSupported(.locked)` falso) — ver o relatório.
    public static func daCamera(_ nome: NomeDoControle) -> String {
        T("Esta câmera não oferece %@.", nome.nome)
    }

    public static var focoFixo: String { T("Esta câmera tem foco fixo.") }

    static func juntar(_ nomes: [NomeDoControle]) -> String {
        let n = nomes.map(\.nome)
        switch n.count {
        case 0: return ""
        case 1: return n[0]
        default: return T("%@ e %@", n.dropLast().joined(separator: ", "), n[n.count - 1])
        }
    }
}

/// Os textos fixos da tela (§2.1, §4.3, §4.4), literais — no idioma da vez, por isso computados.
public enum TextosDosAjustes {
    public static var titulo: String { T("Ajustes da câmera") }
    public static var travarExposicao: String { T("Travar exposição") }
    public static var travarBalanco: String { T("Travar balanço") }
    public static var restaurar: String { T("Restaurar automático") }
    public static var notaDoToque: String { T("Toque na imagem para focar e medir naquele ponto.") }
    public static var travadoDeNovo: String { T("Travado de novo depois de medir a cena.") }
    public static var pilulaDasDuas: String { T("Exposição e foco travados") }
    public static var pilulaDaExposicao: String { T("Exposição travada") }
    public static var pilulaDoFoco: String { T("Foco travado") }
    public static var passeParaManual: String { T("Passe a exposição para Manual para escolher ISO e obturador.") }
}

// MARK: - pouca luz: imagem clara, e o aviso (§3.1)

/// **A pouca luz** (decisão de produto, 06/10): o automático pode baixar o fps para clarear a imagem, até a
/// metade do fps escolhido (nunca abaixo de 10), e a tela avisa. O Mac não lê exposição nem ISO
/// (`API_UNAVAILABLE(macos)`), então o vigia olha o **fps que chega** da câmera. E o Mac não tem
/// exposição manual: o conselho é a luz do ambiente.
public enum PoucaLuz {
    public static let pisoMinimo = 10.0

    /// O piso do `activeVideoMaxFrameDuration` (1/piso): a metade do [fps], nunca abaixo de
    /// [pisoMinimo], limitada pelo menor `minFrameRate` das faixas do formato que alcançam [fps]. Sem
    /// faixa que desça, o próprio [fps]. A mesma regra do iOS.
    public static func piso(faixas: [(minimo: Double, maximo: Double)], fps: Double) -> Double {
        let mins = faixas.filter { $0.maximo >= fps - 0.01 && $0.minimo < fps }.map(\.minimo)
        guard let menor = mins.min() else { return fps }
        return min(fps, max(menor, pisoMinimo, fps / 2))
    }

    /// Acende depois de 1 s seguido com o fps medido abaixo de 87 % do pedido, e apaga depois de 2 s
    /// seguidos de volta. `observar` devolve o fps medido (arredondado) enquanto acesa, ou `nil`.
    public struct Vigia {
        public private(set) var acesa = false
        private var desde: Double?
        public init() {}

        public mutating func observar(fpsMedido: Double, fps: Double, agora: Double) -> Int? {
            let lento = fps > 0 && fpsMedido > 0 && fpsMedido < fps * 0.87
            if lento != acesa {
                if desde == nil { desde = agora }
                if agora - (desde ?? agora) >= (lento ? 1 : 2) { acesa = lento; desde = nil }
            } else {
                desde = nil
            }
            guard acesa else { return nil }
            return min(max(Int(fpsMedido.rounded()), 1), Int(fps.rounded()))
        }
    }

    /// "Pouca luz: 15 fps para clarear a imagem. Mais luz no ambiente devolve os 30 fps."
    public static func texto(fpsAgora: Int, fps: Int) -> String {
        T("Pouca luz: %@ fps para clarear a imagem. Mais luz no ambiente devolve os %@ fps.", fpsAgora, fps)
    }
}

// MARK: - o painel (§4.3)

/// Um controle da tela: aceso ou apagado, e a linha do limite embaixo quando apagado.
public struct ControleNaTela: Equatable, Sendable {
    public var disponivel: Bool
    public var limite: String?

    public static func aceso() -> ControleNaTela { ControleNaTela(disponivel: true, limite: nil) }
    public static func apagado(_ limite: String) -> ControleNaTela { ControleNaTela(disponivel: false, limite: limite) }
}

/// As abas do painel, na ordem (§4.2).
public enum AbaDosAjustes: String, CaseIterable, Sendable {
    case exposicao = "Exposição"
    case isoEObturador = "ISO e obturador"
    case balanco = "Balanço"
    case foco = "Foco"

    /// O rótulo no idioma da vez.
    public var nome: String { T(rawValue) }
}

/// As seis opções da grade do balanço (§4.2), na ordem: Auto, Incandescente, Fluorescente / Luz do dia,
/// Nublado, Kelvin.
public enum OpcaoDeBalanco: String, CaseIterable, Sendable {
    case auto = "Auto"
    case incandescente = "Incandescente"
    case fluorescente = "Fluorescente"
    case luzDoDia = "Luz do dia"
    case nublado = "Nublado"
    case kelvin = "Kelvin"

    /// O rótulo no idioma da vez.
    public var nome: String { T(rawValue) }
}

/// **O que o painel do Mac mostra**, a partir das capacidades. Puro.
public struct PlanoDoPainel: Equatable, Sendable {
    // Exposição
    /// O "Manual" do segmento "Auto" / "Manual": no Mac, sempre apagado.
    public var exposicaoManual: ControleNaTela
    public var ev: ControleNaTela
    public var travaExposicao: ControleNaTela
    public var antiCintilacao: ControleNaTela
    // ISO e obturador: no Mac o grupo inteiro é uma linha só (§3.5).
    public var linhaDoIsoEObturador: String?
    // Balanço
    public var gradeDoBalanco: [(OpcaoDeBalanco, Bool)]
    public var limitesDoBalanco: [String]
    public var travaBalanco: ControleNaTela
    // Foco
    /// Foco fixo: a aba inteira vira esta linha.
    public var linhaDoFocoFixo: String?
    public var focoTravado: ControleNaTela
    public var focoManual: ControleNaTela
    /// "Toque na imagem…", onde há ponto; senão o limite.
    public var notaDoToque: String
    public var toqueDisponivel: Bool
    /// §3.6: no Mac a linha do que a câmera usou some.
    public var linhaDeLeitura: Bool

    public static func == (a: PlanoDoPainel, b: PlanoDoPainel) -> Bool {
        a.exposicaoManual == b.exposicaoManual && a.ev == b.ev && a.travaExposicao == b.travaExposicao
            && a.antiCintilacao == b.antiCintilacao && a.linhaDoIsoEObturador == b.linhaDoIsoEObturador
            && a.gradeDoBalanco.map { "\($0.0.rawValue)=\($0.1)" } == b.gradeDoBalanco.map { "\($0.0.rawValue)=\($0.1)" }
            && a.limitesDoBalanco == b.limitesDoBalanco && a.travaBalanco == b.travaBalanco
            && a.linhaDoFocoFixo == b.linhaDoFocoFixo && a.focoTravado == b.focoTravado
            && a.focoManual == b.focoManual && a.notaDoToque == b.notaDoToque
            && a.toqueDisponivel == b.toqueDisponivel && a.linhaDeLeitura == b.linhaDeLeitura
    }

    public static func doMac(_ c: CapacidadesDaCamera) -> PlanoDoPainel {
        let toque = c.podeMedirNoPonto || c.podeFocarNoPonto
        return PlanoDoPainel(
            exposicaoManual: .apagado(TextoDoLimite.doMacOS([.iso, .obturador])),
            ev: .apagado(TextoDoLimite.doMacOS([.compensacao])),
            travaExposicao: c.podeTravarExposicao ? .aceso() : .apagado(TextoDoLimite.daCamera(.travaExposicao)),
            antiCintilacao: .apagado(TextoDoLimite.doMacOS([.antiCintilacao])),
            linhaDoIsoEObturador: TextoDoLimite.doMacOS([.iso, .obturador]),
            gradeDoBalanco: OpcaoDeBalanco.allCases.map { ($0, $0 == .auto) },
            limitesDoBalanco: [TextoDoLimite.doMacOS([.presetsDeBalanco]), TextoDoLimite.doMacOS([.kelvin])],
            travaBalanco: c.podeTravarBalanco ? .aceso() : .apagado(TextoDoLimite.daCamera(.travaBalanco)),
            linhaDoFocoFixo: c.focoFixo ? TextoDoLimite.focoFixo : nil,
            focoTravado: c.podeTravarFoco ? .aceso() : .apagado(TextoDoLimite.daCamera(.travaFoco)),
            focoManual: .apagado(TextoDoLimite.doMacOS([.focoManual])),
            notaDoToque: toque ? TextosDosAjustes.notaDoToque : TextoDoLimite.daCamera(.toque),
            toqueDisponivel: toque,
            linhaDeLeitura: false)
    }
}

// MARK: - o clique na prévia (§4.4)

/// **O que um clique na prévia faz.** Puro: o dono aplica.
public struct DecisaoDoClique: Equatable, Sendable {
    /// Mede a exposição no ponto (`exposurePointOfInterest` + `.autoExpose`).
    public var medir: Bool
    /// Foca no ponto (`focusPointOfInterest` + `.autoFocus`).
    public var focar: Bool
    /// O registro depois do clique (as travas que o ⌥-clique liga, ou as que o clique simples desfaz).
    public var ajustes: AjustesDaCamera
    /// A pílula que fica acesa depois (`nil`: apagada).
    public var pilula: String?
    /// Mostra o quadrado de 64 pt por 1,5 s. Sem nada a fazer, o clique não faz nada e não há quadrado.
    public var quadrado: Bool { medir || focar }

    /// - `travarAli`: o ⌥-clique (no Mac, o "toque longo").
    /// - `pilulaAcesa`: as travas do registro vieram de um ⌥-clique (a pílula está na tela).
    ///
    /// As regras:
    /// - **clique simples depois de um ⌥-clique** desfaz as duas travas e mede no ponto novo;
    /// - **com a exposição travada pelo painel** (sem a pílula), o clique só foca — a trava é tratada
    ///   como a exposição Manual do §4.4, para um clique de foco não desmanchar a trava que a pessoa pôs;
    ///   do mesmo jeito, com o foco travado pelo painel o clique só mede. Ver o relatório;
    /// - com foco fixo, o clique só mede; sem ponto de exposição, só foca; sem nenhum dos dois, nada;
    /// - **⌥-clique** faz o mesmo e liga `travaExposicao` (se mediu e a câmera trava exposição) e passa
    ///   o foco a `travado` (se focou e a câmera trava foco), com a pílula do que travou.
    public static func decidir(_ atual: AjustesDaCamera, _ c: CapacidadesDaCamera, travarAli: Bool,
                               pilulaAcesa: Bool) -> DecisaoDoClique {
        var a = atual
        if pilulaAcesa {
            a.travaExposicao = false
            if a.foco == .travado { a.foco = .auto }
        }
        let medir = c.podeMedirNoPonto && !a.travaExposicao
        let focar = c.podeFocarNoPonto && a.foco == .auto
        guard medir || focar else {
            return DecisaoDoClique(medir: false, focar: false, ajustes: atual, pilula: pilulaAcesa ? pilula(atual) : nil)
        }
        var pilulaNova: String?
        if travarAli {
            let travouExposicao = medir && c.podeTravarExposicao
            let travouFoco = focar && c.podeTravarFoco
            if travouExposicao { a.travaExposicao = true }
            if travouFoco { a.foco = .travado }
            pilulaNova = DecisaoDoClique.pilula(exposicao: travouExposicao, foco: travouFoco)
        }
        return DecisaoDoClique(medir: medir, focar: focar, ajustes: a, pilula: pilulaNova)
    }

    public static func pilula(exposicao: Bool, foco: Bool) -> String? {
        switch (exposicao, foco) {
        case (true, true): return TextosDosAjustes.pilulaDasDuas
        case (true, false): return TextosDosAjustes.pilulaDaExposicao
        case (false, true): return TextosDosAjustes.pilulaDoFoco
        case (false, false): return nil
        }
    }

    static func pilula(_ a: AjustesDaCamera) -> String? {
        pilula(exposicao: a.travaExposicao, foco: a.foco == .travado)
    }

    /// **A pílula depois de uma mudança pelo painel**: desligar uma trava que veio do ⌥-clique apaga a
    /// pílula (§4.4, "Desligar a trava pelo painel também tira a pílula").
    public static func pilulaDepoisDoPainel(acesa: String?, novo: AjustesDaCamera) -> String? {
        guard let acesa else { return nil }
        // Nas duas línguas: a pílula pode ter sido acesa antes de o seletor trocar o idioma.
        func eh(_ pt: String) -> Bool { Idioma.allCases.contains { acesa == T(pt, em: $0) } }
        let precisaExposicao = eh("Exposição e foco travados") || eh("Exposição travada")
        let precisaFoco = eh("Exposição e foco travados") || eh("Foco travado")
        if precisaExposicao && !novo.travaExposicao { return nil }
        if precisaFoco && novo.foco != .travado { return nil }
        return acesa
    }
}

// MARK: - aplicar e reaplicar (§2.1)

/// O que fazer com **um grupo** (exposição, balanço ou foco) na câmera.
public enum PassoDoGrupo: String, Equatable, Sendable {
    /// O modo contínuo (destravado).
    case automatico
    /// `.autoExpose` / `.autoWhiteBalance` / `.autoFocus`: mede e **trava sozinho ao convergir**
    /// (§2.1, "iOS e Mac").
    case medirETravar
    /// A câmera trava, mas não tem o modo "uma vez": espera parar de ajustar (no máximo 3 s, como no
    /// Android) e então `.locked`.
    case esperarETravar
    /// `.locked` agora, no valor que estiver: a trava pelo painel, com a cena já medida.
    case travarJa
    /// Nada a fazer (a câmera não tem o modo pedido; o registro fica intacto).
    case nada
}

/// **O plano para a câmera**, um passo por grupo. Puro.
public struct PlanoDeAplicar: Equatable, Sendable {
    public var exposicao: PassoDoGrupo
    public var balanco: PassoDoGrupo
    public var foco: PassoDoGrupo

    /// Algum grupo vai medir antes de travar: a tela diz "Travado de novo depois de medir a cena."
    public var travaDepoisDeMedir: Bool {
        [exposicao, balanco, foco].contains { $0 == .medirETravar || $0 == .esperarETravar }
    }

    public var resumo: String {
        "exposicao=\(exposicao.rawValue) balanco=\(balanco.rawValue) foco=\(foco.rawValue)"
    }

    /// - `reaplicando`: a câmera acabou de abrir ou de trocar de formato. Uma trava **não** é
    ///   reaplicada "no que estiver agora" (travaria antes de convergir, §2.1): ela mede e trava.
    ///   Pelo painel (`reaplicando = false`) a cena já está medida, e a trava é na hora.
    public static func para(_ a: AjustesDaCamera, _ c: CapacidadesDaCamera, reaplicando: Bool) -> PlanoDeAplicar {
        func grupo(travar: Bool, podeTravar: Bool, umaVez: Bool, continuo: Bool) -> PassoDoGrupo {
            if travar {
                guard podeTravar else { return .nada }
                if !reaplicando { return .travarJa }
                return umaVez ? .medirETravar : .esperarETravar
            }
            return continuo ? .automatico : .nada
        }
        return PlanoDeAplicar(
            exposicao: grupo(travar: a.travaExposicao, podeTravar: c.podeTravarExposicao,
                             umaVez: c.exposicaoUmaVez, continuo: c.exposicaoContinua),
            balanco: grupo(travar: a.travaBalanco, podeTravar: c.podeTravarBalanco,
                           umaVez: c.balancoUmaVez, continuo: c.balancoContinuo),
            foco: grupo(travar: a.foco == .travado, podeTravar: c.podeTravarFoco,
                        umaVez: c.focoUmaVez, continuo: c.focoContinuo))
    }
}

// MARK: - a luma média (bancada, §5)

/// **A média de luma de um quadro**, para a prova "no fluxo" (§5): o plano Y de um `CVPixelBuffer`
/// biplanar (420v/420f), subamostrado de `passo` em `passo` nas duas direções. Só soma em contador:
/// não salva nem guarda quadro nenhum. `nil` para um formato sem plano Y separado.
public enum LumaMedia {
    public static func calcular(_ pb: CVPixelBuffer, passo: Int = 8) -> Double? {
        guard CVPixelBufferIsPlanar(pb), CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        let p = max(1, passo)
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let l = CVPixelBufferGetWidthOfPlane(pb, 0)
        let a = CVPixelBufferGetHeightOfPlane(pb, 0)
        let linha = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard l > 0, a > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var soma: UInt64 = 0
        var n: UInt64 = 0
        var y = p / 2
        while y < a {
            let fila = bytes + y * linha
            var x = p / 2
            var s: UInt32 = 0
            var k: UInt32 = 0
            while x < l {
                s &+= UInt32(fila[x])
                k &+= 1
                x += p
            }
            soma &+= UInt64(s)
            n &+= UInt64(k)
            y += p
        }
        return n > 0 ? Double(soma) / Double(n) : nil
    }
}
