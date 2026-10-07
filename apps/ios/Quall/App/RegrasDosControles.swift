import Foundation

/// **Os controles de câmera para transmissão** (R9, `docs/controles-de-camera.md`): o registro de
/// cada câmera e as regras de valor, sem AVFoundation. Quem fala com o `AVCaptureDevice` é
/// `AjustesNaCamera.swift`: ele traduz as capacidades e as faixas da câmera para os tipos daqui,
/// pergunta o que fazer e aplica. Assim tudo o que pode lançar `NSRangeException` (um ISO ou uma
/// duração fora da faixa do formato ativo, §2.2) passa por um corte que é **testado no MacBook**
/// (`Testes/rodar.sh`, no molde da `EscolhaDaMelhorImagem`), e não descoberto no aparelho.
///
/// Os nomes dos campos e os textos são **literais** da especificação (§2, §3.5): o JSON é o mesmo
/// das quatro plataformas, em camelCase.

// MARK: - O registro (§2)

/// Um registro por câmera, pelo `uniqueID` (§2). A frontal tem um só, que vale para a câmera comum e
/// para a R5 — é de propósito: mesma câmera, mesma luz.
struct AjustesDaCamera: Codable, Equatable {
    enum Exposicao: String, Codable { case auto, manual }
    enum AntiCintilacao: String, Codable, CaseIterable {
        case auto
        case hz50 = "50"
        case hz60 = "60"
        case desligada
    }
    enum Balanco: String, Codable, CaseIterable {
        case auto, incandescente, fluorescente, luzDoDia, nublado, kelvin
    }
    enum Foco: String, Codable { case auto, travado, manual }

    var exposicao: Exposicao = .auto
    /// Em EV. Arredondado ao passo da câmera (1/3 no iOS) só na hora de aplicar.
    var ev: Double = 0
    /// Só vale com `exposicao = auto`.
    var travaExposicao = false
    /// Os valores **lidos** no instante de travar (§2.1).
    var travaIso: Double?
    var travaObturadorNs: Int64?
    /// Só valem com `exposicao = manual`.
    var iso: Double?
    var obturadorNs: Int64?
    var antiCintilacao: AntiCintilacao = .auto
    var balanco: Balanco = .auto
    /// 2000 a 10000, de 100 em 100. Só vale com `balanco = kelvin`.
    var kelvin: Int?
    /// Só vale com `balanco = auto`.
    var travaBalanco = false
    /// Os ganhos **lidos** ao travar: no iOS, `[vermelho, verde, azul]` (`deviceWhiteBalanceGains`).
    /// O formato é da plataforma (o Android guarda os quatro RGGB): a especificação fixa o nome, e
    /// ganhos de uma câmera não servem a outra.
    var travaGanhos: [Double]?
    var foco: Foco = .auto
    /// 0,0 (longe) a 1,0 (o mais perto). Vale com `manual` e guarda a posição lida ao travar.
    var focoPosicao: Double?

    static let padrao = AjustesDaCamera()

    init() {}

    /// Lê o que houver, e o que faltar ou vier com valor desconhecido fica no padrão: um registro
    /// gravado por uma versão futura (ou por outra frente) não pode derrubar a abertura da câmera.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func valor<T: Decodable>(_ t: T.Type, _ k: CodingKeys) -> T? { (try? c.decodeIfPresent(t, forKey: k)) ?? nil }
        // Um inteiro que veio com casas (`800.0`, o registro de outra plataforma pelo controle
        // remoto, R9b): lido pelo `Double` e arredondado, em vez de cair no padrão calado.
        func inteiro(_ k: CodingKeys) -> Int64? {
            if let i = valor(Int64.self, k) { return i }
            guard let d = valor(Double.self, k), d.isFinite, abs(d) < 9e18 else { return nil }
            return Int64(d.rounded())
        }
        exposicao = valor(Exposicao.self, .exposicao) ?? .auto
        ev = valor(Double.self, .ev).flatMap { $0.isFinite ? $0 : nil } ?? 0
        travaExposicao = valor(Bool.self, .travaExposicao) ?? false
        travaIso = valor(Double.self, .travaIso)
        travaObturadorNs = inteiro(.travaObturadorNs)
        iso = valor(Double.self, .iso)
        obturadorNs = inteiro(.obturadorNs)
        antiCintilacao = valor(AntiCintilacao.self, .antiCintilacao) ?? .auto
        balanco = valor(Balanco.self, .balanco) ?? .auto
        kelvin = inteiro(.kelvin).flatMap { Int(exactly: $0) }
        travaBalanco = valor(Bool.self, .travaBalanco) ?? false
        travaGanhos = valor([Double].self, .travaGanhos)
        foco = valor(Foco.self, .foco) ?? .auto
        focoPosicao = valor(Double.self, .focoPosicao)
    }

    /// A chave do `UserDefaults.standard` (§2): `camera.ajustes.<uniqueID>`.
    static func chave(_ uniqueID: String) -> String { "camera.ajustes." + uniqueID }

    func json() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    /// O registro de um JSON; sem JSON, ou com um JSON ilegível, o padrão.
    static func de(json: Data?) -> AjustesDaCamera {
        guard let json, let a = try? JSONDecoder().decode(AjustesDaCamera.self, from: json) else { return .padrao }
        return a
    }
}

// MARK: - O que a câmera oferece

/// As faixas do **formato ativo** daquele instante (§2.2): é contra elas que todo valor é cortado.
struct FaixasDaCamera: Equatable {
    var isoMin: Double
    var isoMax: Double
    var obturadorMinNs: Int64
    var obturadorMaxNs: Int64
    var evMin: Double
    var evMax: Double
    /// `maxWhiteBalanceGain`.
    var ganhoMax: Double
    /// O fps negociado: `1 / activeVideoMinFrameDuration` (§3.1).
    var fps: Double

    /// Uma faixa neutra para quem ainda não leu a câmera (a tela antes de a câmera montar).
    static let vazia = FaixasDaCamera(isoMin: 0, isoMax: 0, obturadorMinNs: 0, obturadorMaxNs: 0,
                                      evMin: 0, evMax: 0, ganhoMax: 1, fps: 30)
}

/// O que **esta** câmera declara (`is…Supported`). Toda mudança no dono leva a guarda
/// correspondente: fora dela, o AVFoundation lança exceção do Objective-C (§6).
struct CapacidadesDaCamera: Equatable {
    var exposicaoCustom = false        // isExposureModeSupported(.custom)
    var exposicaoUmaVez = false        // .autoExpose: mede uma vez e trava sozinho
    var exposicaoContinua = false      // .continuousAutoExposure
    var exposicaoTravada = false       // .locked
    var pontoDeExposicao = false       // isExposurePointOfInterestSupported
    var focoContinuo = false           // .continuousAutoFocus
    var focoUmaVez = false             // .autoFocus: foca uma vez e trava sozinho
    var focoTravado = false            // .locked
    var pontoDeFoco = false            // isFocusPointOfInterestSupported
    var lenteCustom = false            // isLockingFocusWithCustomLensPositionSupported
    var balancoContinuo = false        // .continuousAutoWhiteBalance
    var balancoUmaVez = false          // .autoWhiteBalance
    var balancoTravado = false         // .locked
    var ganhosCustom = false           // isLockingWhiteBalanceWithCustomDeviceGainsSupported

    /// As frontais de foco fixo não têm nem o contínuo nem o de uma vez.
    var focoFixo: Bool { !focoContinuo && !focoUmaVez }

    /// Nenhuma (a tela antes de a câmera montar).
    static let nenhuma = CapacidadesDaCamera()
}

// MARK: - As regras

enum RegrasDosControles {

    // MARK: Números na tela (§3)

    /// O separador decimal do idioma da interface (`Idioma.atual`), e não o do aparelho: vírgula em
    /// português, ponto em inglês.
    static var separadorDecimal: String { Idioma.atual == .en ? "." : "," }

    /// Com o separador decimal do idioma da interface (vírgula em PT, ponto em EN), independentemente
    /// do idioma do aparelho. O nome ficou de quando o Quall só falava português.
    static func comVirgula(_ v: Double, casas: Int) -> String {
        String(format: "%.\(casas)f", v).replacingOccurrences(of: ".", with: separadorDecimal)
    }

    // MARK: Obturador (§3.1)

    /// As frações de cinema e vídeo, em `1/N s`.
    static let fracoesDoObturador = [24, 25, 30, 48, 50, 60, 100, 120, 125, 250, 500, 1000, 2000, 4000, 8000]

    /// **O teto**: `min(1/fps, máximo da câmera)`, com o fps negociado.
    static func tetoDoObturadorNs(fps: Double, maximoNs: Int64) -> Int64 {
        guard fps.isFinite, fps > 0 else { return maximoNs }
        return min(Int64((1e9 / fps).rounded(.down)), maximoNs)
    }

    struct DegrauDoObturador: Equatable {
        let ns: Int64
        /// O N de `1/N s`.
        let denominador: Int
        let texto: String
        /// A sugestão contra cintilação (§3.1): é legenda, não trava.
        let semCintilacao: Bool
    }

    /// A escala: as frações que cabem entre o mínimo da câmera e o teto, mais o próprio 1/fps se ele
    /// não estiver na lista, da mais longa para a mais curta.
    static func escalaDoObturador(minimoNs: Int64, maximoNs: Int64, fps: Double,
                                  marcados: Set<Int> = []) -> [DegrauDoObturador] {
        let teto = tetoDoObturadorNs(fps: fps, maximoNs: maximoNs)
        guard teto > 0, minimoNs <= teto else { return [] }
        var lista: [(Int, Int64)] = fracoesDoObturador.compactMap { d in
            let ns = nsDaFracao(d)
            // Uma folga de 1 µs no teto: 1/30 s é 33.333.333 ns, e o teto arredondado para baixo
            // de 1/29,97 fica a 33 µs dele — a fração de vídeo é a do quadro, não outra.
            return ns >= minimoNs && ns <= teto + 1_000 ? (d, min(ns, teto)) : nil
        }
        let doFps = Int(fps.rounded())
        if doFps > 0, !lista.contains(where: { $0.0 == doFps }), nsDaFracao(doFps) <= maximoNs + 1_000 {
            lista.append((doFps, teto))
        }
        if lista.isEmpty { lista = [(Int((1e9 / Double(teto)).rounded()), teto)] }
        return lista.sorted { $0.1 > $1.1 }.map {
            DegrauDoObturador(ns: $0.1, denominador: $0.0, texto: "1/\($0.0) s", semCintilacao: marcados.contains($0.0))
        }
    }

    static func nsDaFracao(_ denominador: Int) -> Int64 { Int64((1e9 / Double(denominador)).rounded()) }

    /// `1/N s` (e `X s` de um segundo para cima, que o teto de 1/fps nunca deixa chegar).
    static func textoDoObturador(ns: Int64) -> String {
        guard ns > 0 else { return "?" }
        if ns >= 1_000_000_000 { return comVirgula(Double(ns) / 1e9, casas: 1).replacingOccurrences(of: separadorDecimal + "0", with: "") + " s" }
        return "1/\(Int((1e9 / Double(ns)).rounded())) s"
    }

    /// O obturador cortado pela faixa do formato ativo **e** pelo teto de 1/fps (§2.2). Fora da faixa
    /// o `setExposureModeCustom` lança `NSRangeException`.
    static func cortarObturador(_ ns: Int64, minimoNs: Int64, maximoNs: Int64, fps: Double) -> Int64 {
        let teto = tetoDoObturadorNs(fps: fps, maximoNs: maximoNs)
        return max(minimoNs, min(ns, max(minimoNs, teto)))
    }

    /// **Sugestão contra cintilação** (§3.1): com 60 Hz, ou com `auto` no Brasil, as frações 1/60 e
    /// 1/120 levam um ponto e a legenda; com 50 Hz, 1/50 e 1/100.
    static func sugestaoContraCintilacao(_ a: AjustesDaCamera.AntiCintilacao, regiao: String?)
        -> (fracoes: Set<Int>, legenda: String)? {
        switch a {
        case .hz60: return ([60, 120], tr("sem cintilação em luz de 60 Hz"))
        case .hz50: return ([50, 100], tr("sem cintilação em luz de 50 Hz"))
        case .auto where regiao == "BR": return ([60, 120], tr("sem cintilação em luz de 60 Hz"))
        default: return nil
        }
    }

    // MARK: ISO (§3.2)

    static let isoEmTercos: [Double] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000,
                                        1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400]

    /// Os terços de stop cortados pela faixa da câmera, mais o mínimo e o máximo exatos dela.
    static func escalaDoIso(minimo: Double, maximo: Double) -> [Double] {
        guard minimo > 0, maximo >= minimo else { return [] }
        var v = isoEmTercos.filter { $0 > minimo && $0 < maximo }
        v.insert(minimo, at: 0)
        if maximo > minimo { v.append(maximo) }
        return v
    }

    static func cortarIso(_ iso: Double, minimo: Double, maximo: Double) -> Double {
        guard iso.isFinite else { return minimo }
        return max(minimo, min(iso, maximo))
    }

    static func textoDoIso(_ iso: Double) -> String { "ISO \(Int(iso.rounded()))" }

    /// A marca "ganho digital" acima do fim do ganho analógico, onde a câmera o declara. O iOS não
    /// declara: a função existe pela regra comum, e no iOS recebe `nil`.
    static func ganhoDigital(_ iso: Double, maximoAnalogico: Double?) -> Bool {
        guard let m = maximoAnalogico else { return false }
        return iso > m + 0.5
    }

    // MARK: EV (§3.3)

    /// O passo do iOS: 1/3.
    static let passoDoEv = 1.0 / 3.0

    static func escalaDoEv(minimo: Double, maximo: Double, passo: Double = passoDoEv) -> [Double] {
        guard passo > 0, maximo >= minimo else { return [0] }
        let a = Int((minimo / passo - 1e-6).rounded(.up))
        let b = Int((maximo / passo + 1e-6).rounded(.down))
        guard a <= b else { return [0] }
        return (a...b).map { Double($0) * passo }
    }

    /// O EV arredondado ao passo e cortado pela faixa (fora dela, `setExposureTargetBias` lança
    /// `NSRangeException`).
    static func arredondarEv(_ ev: Double, minimo: Double, maximo: Double, passo: Double = passoDoEv) -> Double {
        let escala = escalaDoEv(minimo: minimo, maximo: maximo, passo: passo)
        guard ev.isFinite else { return escala.min(by: { abs($0) < abs($1) }) ?? 0 }
        return escala.min(by: { abs($0 - ev) < abs($1 - ev) }) ?? 0
    }

    /// `+0,3 EV`, com sinal sempre visível; o 0 é `0 EV`.
    static func textoDoEv(_ ev: Double) -> String {
        if abs(ev) < 0.05 { return "0 EV" }
        return (ev > 0 ? "+" : "-") + comVirgula(abs(ev), casas: 1) + " EV"
    }

    // MARK: Balanço (§3.4)

    /// Os presets são Kelvin fixos no iOS.
    static func kelvinDoPreset(_ b: AjustesDaCamera.Balanco) -> Int? {
        switch b {
        case .incandescente: return 2850
        case .fluorescente: return 4000
        case .luzDoDia: return 5500
        case .nublado: return 6500
        case .auto, .kelvin: return nil
        }
    }

    static let kelvinMinimo = 2000
    static let kelvinMaximo = 10000

    /// 2000 a 10000, de 100 em 100.
    static func arredondarKelvin(_ k: Double) -> Int {
        guard k.isFinite else { return 5500 }
        let r = Int((k / 100).rounded()) * 100
        return max(kelvinMinimo, min(r, kelvinMaximo))
    }

    /// Os ganhos cortados em `[1, maxWhiteBalanceGain]` (fora, exceção).
    static func cortarGanhos(_ g: [Double], maximo: Double) -> [Double] {
        g.map { v in v.isFinite ? max(1, min(v, max(1, maximo))) : 1 }
    }

    // MARK: Foco (§2)

    /// No iOS o 0 do `lensPosition` é o **perto**: `lensPosition = 1 − focoPosicao`.
    static func lentePara(focoPosicao p: Double) -> Double {
        guard p.isFinite else { return 1 }
        return max(0, min(1, 1 - p))
    }

    static func focoPosicao(daLente l: Double) -> Double {
        guard l.isFinite else { return 0 }
        return max(0, min(1, ((1 - l) * 100).rounded() / 100))
    }

    // MARK: Abrir no automático, lembrar o último manual (§2, decisão de 07/10)

    /// **O registro de cada abertura** (a câmera comum e a R5): sempre o padrão da tabela, tudo
    /// automático, **nunca o guardado**. Antes de 07/10 a abertura reaplicava o guardado, e uma câmera
    /// que ficou com ISO e obturador fixos, Kelvin ou foco travado de uma noite abria escura (ou
    /// laranja, ou fora de foco) na manhã seguinte, sem a pessoa entender por quê: a luz mudou e o
    /// ajuste não. O guardado continua no disco, e volta só quando a pessoa pede ("Usar meus
    /// ajustes", `meusAjustes`).
    ///
    /// `bancada`: o registro de `--camera-ajustes`, que vale **em memória**, para aquela sessão. Ele
    /// não vai ao disco: a bancada não pode trocar os ajustes que a pessoa guardou.
    static func registroAoAbrir(bancada: AjustesDaCamera?) -> AjustesDaCamera { bancada ?? .padrao }

    /// **O que gravar** depois de uma escrita no registro (um gesto, um pedido remoto, a trava que
    /// guarda o lido): o registro, se ele for diferente do padrão; `nil` se for o padrão, e aí **o
    /// guardado fica como está**. Voltar ao automático ("Restaurar automático", ou um gesto que deixe
    /// o registro igual ao padrão) não apaga os ajustes da pessoa: é justamente o automático da
    /// abertura que os tornaria inalcançáveis se apagasse.
    static func aGravar(_ registro: AjustesDaCamera) -> AjustesDaCamera? { registro == .padrao ? nil : registro }

    /// **"Usar meus ajustes"**: o guardado a oferecer, ou `nil` para não mostrar o botão. Só aparece
    /// quando há um guardado diferente do padrão (um guardado igual ao padrão é o próprio "Restaurar
    /// automático") **e** diferente do registro de agora (nada a recuperar: já está em uso).
    static func meusAjustes(guardado: AjustesDaCamera?, registro: AjustesDaCamera) -> AjustesDaCamera? {
        guard let g = guardado, g != .padrao, g != registro else { return nil }
        return g
    }

    // MARK: O plano de aplicação (§2.1, §2.2)

    enum PlanoDeExposicao: Equatable {
        /// `.continuousAutoExposure` com o EV.
        case continua(ev: Double)
        /// `.autoExpose`: mede e trava sozinho ao convergir (a trava onde não há manual, §2.1).
        case medirETravar(ev: Double)
        /// `setExposureModeCustom` com valores já cortados.
        case manual(iso: Double, ns: Int64)
        case nada
    }

    enum PlanoDeBalanco: Equatable {
        case continuo
        /// `.autoWhiteBalance`: mede e trava sozinho.
        case medirETravar
        /// Os ganhos já cortados (a trava reaplicada como manual).
        case ganhos([Double])
        /// Os ganhos saem de `deviceWhiteBalanceGains(for:)` no dono, e são cortados lá por
        /// `cortarGanhos`.
        case kelvin(Int)
        case nada
    }

    enum PlanoDeFoco: Equatable {
        case continuo
        /// `.autoFocus`: foca e trava sozinho.
        case medirETravar
        /// `setFocusModeLocked(lensPosition:)`, já no sentido do iOS.
        case lente(Double)
        case nada
    }

    struct Plano: Equatable {
        var exposicao: PlanoDeExposicao
        var balanco: PlanoDeBalanco
        var foco: PlanoDeFoco
        /// Uma trava foi reaplicada medindo de novo (sem manual para aquele grupo): a tela diz
        /// "Travado de novo depois de medir a cena." por 3 s.
        var travadoDeNovo: Bool
    }

    /// **O que aplicar**, com todo valor cortado pela faixa daquele instante (§2.2). `reaplicando`:
    /// a câmera reabriu ou se reconfigurou (os ganchos do §2.2), e não foi a pessoa que mexeu.
    static func plano(_ a: AjustesDaCamera, _ c: CapacidadesDaCamera, _ f: FaixasDaCamera,
                      reaplicando: Bool) -> Plano {
        var deNovo = false
        let ev = arredondarEv(a.ev, minimo: f.evMin, maximo: f.evMax)

        let exposicao: PlanoDeExposicao
        if a.exposicao == .manual, c.exposicaoCustom, let iso = a.iso, let ns = a.obturadorNs {
            exposicao = .manual(iso: cortarIso(iso, minimo: f.isoMin, maximo: f.isoMax),
                                ns: cortarObturador(ns, minimoNs: f.obturadorMinNs, maximoNs: f.obturadorMaxNs, fps: f.fps))
        } else if a.exposicao == .auto, a.travaExposicao {
            if c.exposicaoCustom, let iso = a.travaIso, let ns = a.travaObturadorNs {
                // Onde há manual, a trava volta **como manual com os valores guardados** (§2.1).
                exposicao = .manual(iso: cortarIso(iso, minimo: f.isoMin, maximo: f.isoMax),
                                    ns: cortarObturador(ns, minimoNs: f.obturadorMinNs, maximoNs: f.obturadorMaxNs, fps: f.fps))
            } else if c.exposicaoUmaVez {
                exposicao = .medirETravar(ev: ev)
                deNovo = reaplicando
            } else {
                exposicao = c.exposicaoContinua ? .continua(ev: ev) : .nada
            }
        } else {
            exposicao = c.exposicaoContinua ? .continua(ev: ev) : .nada
        }

        let balanco: PlanoDeBalanco
        switch a.balanco {
        case .auto:
            if a.travaBalanco {
                if c.ganhosCustom, let g = a.travaGanhos, g.count == 3 {
                    balanco = .ganhos(cortarGanhos(g, maximo: f.ganhoMax))
                } else if c.balancoUmaVez {
                    balanco = .medirETravar
                    deNovo = deNovo || reaplicando
                } else {
                    balanco = c.balancoContinuo ? .continuo : .nada
                }
            } else {
                balanco = c.balancoContinuo ? .continuo : .nada
            }
        case .kelvin:
            balanco = c.ganhosCustom ? .kelvin(arredondarKelvin(Double(a.kelvin ?? 5500)))
                : (c.balancoContinuo ? .continuo : .nada)
        default:
            balanco = c.ganhosCustom ? .kelvin(kelvinDoPreset(a.balanco) ?? 5500)
                : (c.balancoContinuo ? .continuo : .nada)
        }

        let foco: PlanoDeFoco
        if c.focoFixo && !c.lenteCustom {
            foco = .nada
        } else {
            switch a.foco {
            case .manual:
                foco = c.lenteCustom ? .lente(lentePara(focoPosicao: a.focoPosicao ?? 0))
                    : (c.focoContinuo ? .continuo : .nada)
            case .travado:
                if c.lenteCustom, let p = a.focoPosicao {
                    foco = .lente(lentePara(focoPosicao: p))
                } else if c.focoUmaVez {
                    foco = .medirETravar
                    deNovo = deNovo || reaplicando
                } else {
                    foco = c.focoContinuo ? .continuo : .nada
                }
            case .auto:
                foco = c.focoContinuo ? .continuo : (c.focoUmaVez ? .medirETravar : .nada)
            }
        }
        return Plano(exposicao: exposicao, balanco: balanco, foco: foco, travadoDeNovo: deNovo)
    }

    // MARK: Quem limita (§3.5)

    /// Os controles, com o nome **como aparece dentro das frases** (o artigo faz parte do nome).
    enum Controle: String, CaseIterable {
        case iso = "ISO"
        case obturador = "o obturador"
        case kelvin = "o Kelvin"
        case presets = "os presets de balanço"
        case focoManual = "o foco manual"
        case antiCintilacao = "a anti-cintilação"
        case compensacao = "a compensação de exposição"
        case toque = "o toque para focar"
        case travaExposicao = "a trava de exposição"
        case travaBalanco = "a trava de balanço"
        case travaFoco = "a trava de foco"
        case brilho = "o brilho"
        case ganho = "o ganho"

        /// O nome dentro da frase, no idioma da interface. O `rawValue` fica em português (é o nome
        /// da especificação, e os testes o conferem).
        var nome: String {
            switch self {
            case .iso: return "ISO"
            case .obturador: return tr("o obturador")
            case .kelvin: return tr("o Kelvin")
            case .presets: return tr("os presets de balanço")
            case .focoManual: return tr("o foco manual")
            case .antiCintilacao: return tr("a anti-cintilação")
            case .compensacao: return tr("a compensação de exposição")
            case .toque: return tr("o toque para focar")
            case .travaExposicao: return tr("a trava de exposição")
            case .travaBalanco: return tr("a trava de balanço")
            case .travaFoco: return tr("a trava de foco")
            case .brilho: return tr("o brilho")
            case .ganho: return tr("o ganho")
            }
        }
    }

    static func textoDoFabricante(_ c: Controle) -> String {
        tr("O fabricante deste aparelho não libera %@ para outros apps.", c.nome)
    }

    static var textoDaCintilacaoNoIOS: String { tr("O iOS ajusta a cintilação sozinho.") }
    static var textoDoFocoFixo: String { tr("Esta câmera tem foco fixo.") }
    static var textoDeTravadoDeNovo: String { tr("Travado de novo depois de medir a cena.") }
    static var textoDoEvTravado: String { tr("Destrave a exposição para compensar.") }
    static var textoDePassarParaManual: String { tr("Passe a exposição para Manual para escolher ISO e obturador.") }
    static var notaDoToque: String { tr("Toque na imagem para focar e medir naquele ponto.") }

    /// A linha que vai embaixo de um controle apagado, ou `nil` se a câmera o oferece.
    static func limite(_ controle: Controle, _ c: CapacidadesDaCamera, _ f: FaixasDaCamera) -> String? {
        switch controle {
        case .iso, .obturador:
            return c.exposicaoCustom ? nil : textoDoFabricante(controle)
        case .kelvin, .presets:
            return c.ganhosCustom ? nil : textoDoFabricante(controle)
        case .focoManual:
            if c.focoFixo && !c.lenteCustom { return textoDoFocoFixo }
            return c.lenteCustom ? nil : textoDoFabricante(controle)
        case .travaFoco:
            if c.focoFixo && !c.lenteCustom { return textoDoFocoFixo }
            return (c.lenteCustom || c.focoUmaVez || c.focoTravado) ? nil : textoDoFabricante(controle)
        case .travaExposicao:
            return (c.exposicaoCustom || c.exposicaoUmaVez || c.exposicaoTravada) ? nil : textoDoFabricante(controle)
        case .travaBalanco:
            return (c.ganhosCustom || c.balancoUmaVez || c.balancoTravado) ? nil : textoDoFabricante(controle)
        case .toque:
            if !c.pontoDeExposicao && !c.pontoDeFoco { return textoDoFabricante(controle) }
            return nil
        case .compensacao:
            return f.evMax > f.evMin ? nil : textoDoFabricante(controle)
        case .antiCintilacao:
            return textoDaCintilacaoNoIOS
        case .brilho, .ganho:
            // Do Windows; no iOS a pergunta não existe.
            return textoDoFabricante(controle)
        }
    }

    // MARK: Leitura de volta (§3.6)

    struct Leitura: Equatable {
        var iso: Double?
        var obturadorNs: Int64?
        var kelvin: Int?
        var abertura: Double?
        /// `lensPosition` cru (o 0 é o perto).
        var lente: Double?
    }

    /// `ISO 400 · 1/60 s · 5200 K · f/1,7`, só o que se conseguiu ler.
    static func linhaDaLeitura(_ l: Leitura) -> String {
        var p: [String] = []
        if let i = l.iso { p.append(textoDoIso(i)) }
        if let n = l.obturadorNs { p.append(textoDoObturador(ns: n)) }
        if let k = l.kelvin { p.append("\(k) K") }
        if let a = l.abertura, a > 0 { p.append(textoDaAbertura(a)) }
        return p.joined(separator: " · ")
    }

    static func textoDaAbertura(_ f: Double) -> String {
        let t = comVirgula(f, casas: 1)
        return "f/" + (t.hasSuffix(separadorDecimal + "0") ? String(t.dropLast(2)) : t)
    }

    /// Mais de um passo de diferença: ISO e obturador em terços de stop; Kelvin em 100 K.
    static func divergeEmStops(pedido: Double, lido: Double) -> Bool {
        guard pedido > 0, lido > 0, pedido.isFinite, lido.isFinite else { return false }
        return abs(log2(lido / pedido)) > 1.0 / 3.0 + 0.02
    }

    static func divergeEmKelvin(pedido: Int, lido: Int) -> Bool { abs(pedido - lido) > 100 }

    static func textoDaDivergencia(lido: String, pedido: String) -> String {
        tr("A câmera usou %@ em vez de %@.", lido, pedido)
    }

    /// **"Durante 2 s"**: a divergência só vira texto depois de durar 2 s seguidos (§3.6).
    // MARK: Pouca luz: imagem clara, e o aviso (§3.1)

    /// **O piso do fps do automático**: o `activeVideoMaxFrameDuration` é 1/piso. É a **metade do
    /// fps** (nunca abaixo de [pisoMinimo]), limitada pelo menor `minFrameRate` das faixas do formato
    /// que alcançam [fps]. Sem faixa que desça, o próprio [fps].
    ///
    /// Medido no iPad A16 em 06/10, a 60 fps: o padrão do sistema era o quadro fixo de 1/60 s (a
    /// exposição presa em 16,7 ms). Com o piso em 10, o AE da Apple foi a 1/15 s com ISO 340 numa sala
    /// só meio escura: ele prefere alongar o quadro a subir o ISO. A metade do fps limita a perda de
    /// fluidez a 1 stop de luz a mais.
    static let pisoMinimo = 10.0

    static func pisoDoAutomatico(faixas: [(minimo: Double, maximo: Double)], fps: Double) -> Double {
        let mins = faixas.filter { $0.maximo >= fps - 0.01 && $0.minimo < fps }.map(\.minimo)
        guard let menor = mins.min() else { return fps }
        return min(fps, max(menor, pisoMinimo, fps / 2))
    }

    /// **A pouca luz baixou o fps**: com a exposição em Auto, o obturador lido passou de 1/fps
    /// (mais 15 %, a folga do arredondamento). Acende depois de 1 s seguido e apaga depois de 2 s
    /// seguidos de volta. `observar` devolve o fps de agora enquanto acesa, ou `nil`.
    struct VigiaDaPoucaLuz {
        private(set) var desde: Double?
        private(set) var acesa = false
        mutating func observar(auto: Bool, obturadorNs: Int64?, fps: Double, agora: Double) -> Int? {
            let teto = 1e9 / Swift.max(fps, 1)
            let lento = auto && (obturadorNs.map { Double($0) > teto * 1.15 } ?? false)
            if lento != acesa {
                if desde == nil { desde = agora }
                if agora - (desde ?? agora) >= (lento ? 1 : 2) { acesa = lento; desde = nil }
            } else {
                desde = nil
            }
            guard acesa, let n = obturadorNs, n > 0 else { return nil }
            return Swift.min(Swift.max(Int((1e9 / Double(n)).rounded()), 1), Int(fps.rounded()))
        }
    }

    /// "Pouca luz: 15 fps para clarear a imagem. Para 30 fps, use a exposição manual na engrenagem."
    /// Sem exposição manual, o conselho é a luz do ambiente.
    static func textoDaPoucaLuz(fpsAgora: Int, fps: Int, temManual: Bool) -> String {
        temManual
            ? tr("Pouca luz: %ld fps para clarear a imagem. Para %ld fps, use a exposição manual na engrenagem.", fpsAgora, fps)
            : tr("Pouca luz: %ld fps para clarear a imagem. Mais luz no ambiente devolve os %ld fps.", fpsAgora, fps)
    }

    struct VigiaDaDivergencia {
        private(set) var desde: Double?
        mutating func observar(diverge: Bool, agora: Double) -> Bool {
            guard diverge else { desde = nil; return false }
            if desde == nil { desde = agora }
            return agora - (desde ?? agora) >= 2
        }
    }

    // MARK: Deslizantes: no máximo 15 envios por segundo (§2.2)

    /// O último valor vence: quem envia lê o registro **na hora de enviar**, então o agrupador só
    /// decide **quando**. `pedir` devolve o atraso até o próximo envio, ou `nil` se já há um marcado.
    struct Agrupador {
        let intervalo: Double
        private(set) var ultimoEnvio = -Double.infinity
        private(set) var marcado = false

        init(porSegundo: Double = 15) { intervalo = 1 / porSegundo }

        mutating func pedir(agora: Double) -> Double? {
            guard !marcado else { return nil }
            marcado = true
            return max(0, ultimoEnvio + intervalo - agora)
        }

        mutating func enviou(agora: Double) {
            ultimoEnvio = agora
            marcado = false
        }
    }

    // MARK: O toque na prévia (§4.4)

    struct DecisaoDoToque: Equatable {
        /// O registro depois do toque (as travas desfeitas, ou as novas marcadas).
        var ajustes: AjustesDaCamera
        var foca: Bool
        var mede: Bool
        /// Depois de convergir, ler e guardar (§2.1): `travaIso`/`travaObturadorNs` e `focoPosicao`.
        var travarExposicao: Bool
        var travarFoco: Bool
        var pilula: String?
        var quadrado: Bool { foca || mede }
    }

    static func textoDaPilula(exposicao: Bool, foco: Bool) -> String? {
        switch (exposicao, foco) {
        case (true, true): return tr("Exposição e foco travados")
        case (true, false): return tr("Exposição travada")
        case (false, true): return tr("Foco travado")
        default: return nil
        }
    }

    /// Um toque foca e mede; um toque longo faz o mesmo e trava ali. **Um toque (simples ou longo)
    /// desfaz as travas de antes** e mede no ponto novo — a pílula sai junto. Com exposição Manual,
    /// só foca; com foco Manual ou fixo, só mede; com os dois, nada (e nem quadrado).
    static func decidirToque(_ a: AjustesDaCamera, _ c: CapacidadesDaCamera, longo: Bool) -> DecisaoDoToque {
        let foca = a.foco != .manual && c.pontoDeFoco && c.focoUmaVez
        let mede = a.exposicao != .manual && c.pontoDeExposicao && c.exposicaoUmaVez
        guard foca || mede else {
            return DecisaoDoToque(ajustes: a, foca: false, mede: false, travarExposicao: false,
                                  travarFoco: false, pilula: nil)
        }
        var n = a
        if mede, n.travaExposicao { n.travaExposicao = false; n.travaIso = nil; n.travaObturadorNs = nil }
        if foca, n.foco == .travado { n.foco = .auto }
        let te = longo && mede
        let tf = longo && foca
        if te { n.travaExposicao = true }
        if tf { n.foco = .travado }
        return DecisaoDoToque(ajustes: n, foca: foca, mede: mede, travarExposicao: te, travarFoco: tf,
                              pilula: longo ? textoDaPilula(exposicao: te, foco: tf) : nil)
    }
}
