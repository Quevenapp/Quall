import Foundation

/// **O controle remoto da câmera** (R9b, `docs/controle-remoto-da-camera.md`): o que é puro dos dois
/// lados, sem AVFoundation, sem UIKit e sem a fronteira C — testado no MacBook (`Testes/rodar.sh`,
/// `TestesDoControleRemoto.swift`), como as regras do R9 (`RegrasDosControles`).
///
/// - **O molde do painel** (`MoldeDoPainel`): o que a câmera oferece, as faixas e quem limita, na
///   forma que o painel do R9 desenha. Sai de dois lugares: da câmera deste aparelho
///   (`MoldeDoPainel.local`, o painel de sempre) e das capacidades que chegaram de outro
///   (`MoldeDoPainel.remoto`, contrato §3.2). Assim o mesmo painel serve ao filmador e ao receptor.
/// - **As capacidades do iOS no fio** (`CapacidadesRemotas.doIOS`), do mesmo cálculo que monta o
///   painel (contrato §12: "do mesmo cálculo que monta o painel do R9").
/// - **O pedido aplicado no filmador** (`RegrasDoControleRemoto.aplicar`), na ordem do §6.
/// - **O pedido parcial do receptor** (`RegrasDoControleRemoto.camposMudados`): só o que a pessoa mexeu.
/// - **O ponto do toque no quadro decodificado** (`PontoNoQuadro`), com o `.resizeAspect` da tela.

// MARK: - O molde do painel

struct MoldeDoPainel: Equatable {
    /// Uma faixa numérica de um descritor (§3.2): `passo` é dica para a tela.
    struct Faixa: Equatable {
        var min: Double
        var max: Double
        var passo: Double?
        /// `"inteiro":true`: o núcleo recusa um pedido com casas.
        var inteiro = false
    }

    /// A unidade de `ev` e de `iso` (achado I7 do contrato): no Windows o registro guarda o **brilho**
    /// do driver em `ev`, como deslocamento do padrão (`origem`), e o **ganho** em `iso`.
    enum Unidade: Equatable {
        case padrao
        case brilho(origem: Double)
        case ganho(origem: Double)
    }

    /// "Manual" está entre os valores de `exposicao`.
    var exposicaoManual = false
    /// A compensação (`nil`: a câmera não oferece, e a linha do limite vai embaixo).
    var ev: Faixa?
    var unidadeDoEv: Unidade = .padrao
    var travaExposicao = false
    /// Os valores de `antiCintilacao` oferecidos; os outros ficam apagados.
    var antiCintilacao: [String] = []
    var iso: Faixa?
    var unidadeDoIso: Unidade = .padrao
    /// O fim do ganho analógico (Android): acima dele, a marca "ganho digital" (R9 §3.2).
    var analogicoMax: Double?
    /// `obturadorNs`, em ns. No filmador local o `max` é o máximo do formato, e o teto de 1/fps vem
    /// de `fps`; no remoto o `max` já é o teto (as capacidades o mandam assim) e `fps` é nulo.
    var obturador: Faixa?
    var fps: Double?
    /// O obturador do Windows anda em potências de 2 (`"escala":"log2"`, R9 §3.1).
    var obturadorLog2 = false
    /// Os valores de `balanco` oferecidos (`auto`, os presets, `kelvin`).
    var balanco: Set<String> = []
    var kelvin: Faixa?
    var travaBalanco = false
    /// Os valores de `foco` oferecidos (`auto`, `travado`, `manual`).
    var foco: Set<String> = []
    var focoPosicao: Faixa?
    /// As dioptrias da posição 1 (o mais perto), quando a lente do outro aparelho é calibrada (o
    /// `"calibrado"` do descritor de `focoPosicao`, o Android): o foco aparece em metros. O iOS não
    /// tem calibração de distância e não o manda (R9 §1).
    var dioptriasDoFoco: Double?
    /// A câmera tem ponto de interesse: o toque na imagem foca e mede.
    var toque = false
    /// Quem limita, **por código** (§3.2: `fabricante`, `macos`, `ios_cintilacao`…), pelo nome do
    /// campo do ajuste (`iso`, `kelvin`, `focoPosicao`…), de `foco` (a trava de foco que falta, ou o
    /// foco fixo) ou da ação (`toque`). A frase sai na hora de mostrar, no idioma da interface.
    var limites: [String: String] = [:]

    // --- o que o painel pergunta ----------------------------------------------------------------

    /// A câmera tem foco fixo: a aba Foco é uma linha só.
    var focoFixo: Bool {
        limites["foco"] == "foco_fixo" || (foco.isEmpty && focoPosicao == nil && limites["focoPosicao"] == "foco_fixo")
    }

    /// O nome do EV e do ISO dentro das frases: "o brilho" e "o ganho" no Windows.
    private func nome(_ c: RegrasDosControles.Controle) -> RegrasDosControles.Controle {
        switch c {
        case .compensacao: if case .brilho = unidadeDoEv { return .brilho }
        case .iso: if case .ganho = unidadeDoIso { return .ganho }
        default: break
        }
        return c
    }

    /// **A linha embaixo de um controle apagado**, ou `nil` se a câmera o oferece (R9 §3.5).
    func limite(_ c: RegrasDosControles.Controle) -> String? {
        typealias C = RegrasDosControles.Controle
        func frase(_ campo: String) -> String {
            RegrasDoControleRemoto.frase(limites[campo], nome(c))
        }
        switch c {
        case .iso: return iso == nil ? frase("iso") : nil
        case .obturador: return obturador == nil ? frase("obturadorNs") : nil
        case .compensacao, .brilho: return ev == nil ? frase("ev") : nil
        case .ganho: return iso == nil ? frase("iso") : nil
        case .travaExposicao: return travaExposicao ? nil : frase("travaExposicao")
        case .travaBalanco: return travaBalanco ? nil : frase("travaBalanco")
        case .antiCintilacao: return limites["antiCintilacao"].map { RegrasDoControleRemoto.frase($0, c) }
        case .kelvin: return kelvin == nil ? frase("kelvin") : nil
        case .presets:
            let presets: Set<String> = ["incandescente", "fluorescente", "luzDoDia", "nublado"]
            guard !presets.isSubset(of: balanco) else { return nil }
            // Sem presets **e** sem Kelvin (o iOS sem ganhos manuais): o mesmo motivo dos dois.
            return RegrasDoControleRemoto.frase(kelvin == nil ? limites["kelvin"] : limites["balanco"], c)
        case .focoManual:
            if focoFixo { return RegrasDosControles.textoDoFocoFixo }
            return foco.contains("manual") && focoPosicao != nil ? nil : frase("focoPosicao")
        case .travaFoco:
            if focoFixo { return RegrasDosControles.textoDoFocoFixo }
            return foco.contains("travado") ? nil : frase("foco")
        case .toque: return toque ? nil : frase("toque")
        }
    }

    // --- as escalas -----------------------------------------------------------------------------

    /// O passo do EV: o do descritor, ou 1/3 (o do iOS).
    var passoDoEv: Double {
        if let p = ev?.passo, p > 0 { return ev?.inteiro == true ? max(1, p.rounded()) : p }
        return ev?.inteiro == true ? 1 : RegrasDosControles.passoDoEv
    }

    func escalaDoEv() -> [Double] {
        let f = ev ?? Faixa(min: 0, max: 0)
        return RegrasDosControles.escalaDoEv(minimo: f.min, maximo: f.max, passo: passoDoEv)
    }

    func evAplicado(_ v: Double) -> Double {
        let f = ev ?? Faixa(min: 0, max: 0)
        return RegrasDosControles.arredondarEv(v, minimo: f.min, maximo: f.max, passo: passoDoEv)
    }

    /// O título do EV: "EV", ou "Brilho" no Windows (escrever "EV" seria mentira, R9 §3.3).
    var tituloDoEv: String {
        if case .brilho = unidadeDoEv { return tr("Brilho") }
        return "EV"  // sem-traducao
    }

    /// `+0,3 EV`; no Windows, o número do driver (`origem + valor`).
    func textoDoEv(_ v: Double) -> String {
        if case .brilho(let origem) = unidadeDoEv { return RegrasDoControleRemoto.numero(origem + v) }
        return RegrasDosControles.textoDoEv(evAplicado(v))
    }

    /// O nome da aba: "ISO e obturador", ou "Ganho e obturador" no Windows (R9 §4.3).
    var tituloDaAbaDoIso: String {
        if case .ganho = unidadeDoIso { return tr("Ganho e obturador") }
        return tr("ISO e obturador")
    }

    var tituloDoIso: String {
        if case .ganho = unidadeDoIso { return tr("Ganho") }
        return "ISO"  // sem-traducao
    }

    /// Os degraus do ISO: os terços de stop (R9 §3.2); no Windows, o passo do driver.
    func escalaDoIso() -> [Double] {
        guard let f = iso else { return [] }
        if case .ganho = unidadeDoIso {
            let passo = max(f.passo ?? 1, (f.max - f.min) / 400, 1e-9)
            var v: [Double] = []
            var x = f.min
            while x <= f.max + passo * 1e-6 && v.count <= 401 { v.append(min(x, f.max)); x += passo }
            if let u = v.last, u < f.max { v.append(f.max) }
            return v
        }
        return RegrasDosControles.escalaDoIso(minimo: f.min, maximo: f.max)
    }

    func isoAplicado(_ v: Double?) -> Double {
        guard let f = iso else { return v ?? 0 }
        return RegrasDosControles.cortarIso(v ?? f.min, minimo: f.min, maximo: f.max)
    }

    func textoDoIso(_ v: Double) -> String {
        if case .ganho(let origem) = unidadeDoIso { return RegrasDoControleRemoto.numero(origem + v) }
        let digital = RegrasDosControles.ganhoDigital(v, maximoAnalogico: analogicoMax)
        return RegrasDosControles.textoDoIso(v) + (digital ? " · " + tr("ganho digital") : "")
    }

    /// O teto do obturador: `min(1/fps, máximo)` no local; o próprio máximo no remoto.
    var tetoDoObturadorNs: Int64 {
        guard let f = obturador else { return 0 }
        guard let fps else { return Int64(f.max) }
        return RegrasDosControles.tetoDoObturadorNs(fps: fps, maximoNs: Int64(f.max))
    }

    /// Os degraus do obturador (R9 §3.1): as frações de cinema e vídeo; no Windows, 2^v s.
    func escalaDoObturador(marcados: Set<Int> = []) -> [RegrasDosControles.DegrauDoObturador] {
        guard let f = obturador, f.max > 0 else { return [] }
        if obturadorLog2 {
            return RegrasDoControleRemoto.escalaLog2(minimoNs: f.min, maximoNs: f.max)
        }
        let fpsDaEscala = fps ?? (1e9 / f.max)
        return RegrasDosControles.escalaDoObturador(minimoNs: Int64(f.min), maximoNs: Int64(f.max),
                                                    fps: fpsDaEscala, marcados: marcados)
    }

    func obturadorAplicado(_ ns: Int64?) -> Int64 {
        guard let f = obturador else { return ns ?? 0 }
        if let fps {
            return RegrasDosControles.cortarObturador(ns ?? Int64(f.max), minimoNs: Int64(f.min),
                                                      maximoNs: Int64(f.max), fps: fps)
        }
        return max(Int64(f.min), min(ns ?? Int64(f.max), Int64(f.max)))
    }

    /// Kelvin: de 2000 a 10000, de 100 em 100 no iOS; a faixa e o passo do descritor no remoto.
    func escalaDoKelvin() -> [Int] {
        guard let f = kelvin else { return [] }
        let passo = max(1, Int((f.passo ?? 100).rounded()))
        let a = Int(f.min.rounded(.up)), b = Int(f.max.rounded(.down))
        guard a <= b else { return [a] }
        return Array(stride(from: a, through: b, by: passo))
    }

    /// Os degraus de `focoPosicao`, do **perto** (o maior) ao longe: "Perto ↔ Longe" (R9 §4.3).
    func escalaDoFoco() -> [Double] {
        let f = focoPosicao ?? Faixa(min: 0, max: 1, passo: 0.01)
        let passo = max(f.passo ?? 0.01, (f.max - f.min) / 1000, 1e-6)
        let n = Int(((f.max - f.min) / passo).rounded())
        return (0...max(0, n)).map { i in
            let v = f.max - Double(i) * passo
            return (max(f.min, v) * 100).rounded() / 100
        }
    }

    /// O valor do foco: em metros com a lente calibrada (distância = 1/(dioptrias × posição), "∞" na
    /// posição 0, como o Android: duas casas abaixo de 1 m, uma acima); senão a posição, 0,00 a 1,00.
    func textoDoFoco(_ p: Double) -> String {
        guard let d = dioptriasDoFoco, d > 0 else { return RegrasDosControles.comVirgula(p, casas: 2) }
        let dp = max(0, p) * d
        if dp <= 0.001 { return "∞" }
        let metros = 1 / dp
        return RegrasDosControles.comVirgula(metros, casas: metros < 1 ? 2 : 1) + " m"
    }

    // --- o local: a câmera deste aparelho -------------------------------------------------------

    /// **O painel de sempre** (R9): o que esta câmera declara e as faixas do formato de agora.
    /// Os limites saem pelos mesmos testes de `RegrasDosControles.limite` (os testes conferem que
    /// as linhas são as mesmas).
    static func local(_ c: CapacidadesDaCamera, _ f: FaixasDaCamera) -> MoldeDoPainel {
        var m = MoldeDoPainel()
        var l: [String: String] = [:]
        m.exposicaoManual = c.exposicaoCustom
        if f.evMax > f.evMin { m.ev = Faixa(min: f.evMin, max: f.evMax, passo: RegrasDosControles.passoDoEv) }
        else { l["ev"] = "fabricante" }
        m.travaExposicao = c.exposicaoCustom || c.exposicaoUmaVez || c.exposicaoTravada
        if !m.travaExposicao { l["travaExposicao"] = "fabricante" }
        // Sem API no iOS (o sistema cuida sozinho): nenhum valor, e a linha do §3.5.
        l["antiCintilacao"] = "ios_cintilacao"
        if c.exposicaoCustom {
            m.iso = Faixa(min: f.isoMin, max: f.isoMax)
            m.obturador = Faixa(min: Double(f.obturadorMinNs), max: Double(f.obturadorMaxNs))
            m.fps = f.fps
        } else {
            l["iso"] = "fabricante"
            l["obturadorNs"] = "fabricante"
        }
        m.balanco = ["auto"]
        if c.ganhosCustom {
            m.balanco.formUnion(["incandescente", "fluorescente", "luzDoDia", "nublado", "kelvin"])
            m.kelvin = Faixa(min: Double(RegrasDosControles.kelvinMinimo), max: Double(RegrasDosControles.kelvinMaximo),
                             passo: 100)
        } else {
            l["kelvin"] = "fabricante"
        }
        m.travaBalanco = c.ganhosCustom || c.balancoUmaVez || c.balancoTravado
        if !m.travaBalanco { l["travaBalanco"] = "fabricante" }
        if c.focoFixo && !c.lenteCustom {
            l["foco"] = "foco_fixo"
            l["focoPosicao"] = "foco_fixo"
        } else {
            m.foco = ["auto"]
            if c.lenteCustom || c.focoUmaVez || c.focoTravado { m.foco.insert("travado") } else { l["foco"] = "fabricante" }
            if c.lenteCustom {
                m.foco.insert("manual")
                m.focoPosicao = Faixa(min: 0, max: 1, passo: 0.01)
            } else {
                l["focoPosicao"] = "fabricante"
            }
        }
        m.toque = c.pontoDeExposicao || c.pontoDeFoco
        if !m.toque { l["toque"] = "fabricante" }
        m.limites = l
        return m
    }

    // --- o remoto: as capacidades que chegaram (§3.2) -------------------------------------------

    /// As capacidades do outro aparelho (o objeto `"capacidades"` do estado do receptor). Um
    /// descritor de forma desconhecida conta como ausente; o núcleo já conferiu a forma.
    static func remoto(_ caps: [String: Any]) -> MoldeDoPainel {
        var m = MoldeDoPainel()
        let controles = caps["controles"] as? [String: Any] ?? [:]
        func objeto(_ k: String) -> [String: Any]? { controles[k] as? [String: Any] }
        func valores(_ k: String) -> [String] { objeto(k)?["valores"] as? [String] ?? [] }
        func num(_ o: [String: Any]?, _ k: String) -> Double? { RegrasDoControleRemoto.numeroJSON(o?[k]) }
        func faixa(_ k: String) -> Faixa? {
            guard let o = objeto(k), let a = num(o, "min"), let b = num(o, "max"), a <= b else { return nil }
            return Faixa(min: a, max: b, passo: num(o, "passo"),
                         inteiro: RegrasDoControleRemoto.booleanoJSON(o["inteiro"]) ?? false)
        }
        func unidade(_ k: String) -> Unidade {
            let o = objeto(k)
            switch o?["unidade"] as? String {
            case "brilho": return .brilho(origem: num(o, "origem") ?? 0)
            case "ganho": return .ganho(origem: num(o, "origem") ?? 0)
            default: return .padrao
            }
        }
        m.exposicaoManual = valores("exposicao").contains("manual")
        m.ev = faixa("ev")
        m.unidadeDoEv = unidade("ev")
        m.travaExposicao = objeto("travaExposicao") != nil
        m.antiCintilacao = valores("antiCintilacao")
        m.iso = faixa("iso")
        m.unidadeDoIso = unidade("iso")
        m.analogicoMax = num(objeto("iso"), "analogicoMax")
        m.obturador = faixa("obturadorNs")
        m.obturadorLog2 = objeto("obturadorNs")?["escala"] as? String == "log2"
        m.balanco = Set(valores("balanco"))
        m.kelvin = faixa("kelvin")
        m.travaBalanco = objeto("travaBalanco") != nil
        m.foco = Set(valores("foco"))
        m.focoPosicao = faixa("focoPosicao")
        m.dioptriasDoFoco = num(objeto("focoPosicao"), "calibrado").flatMap { $0 > 0 ? $0 : nil }
        m.toque = objeto("toque") != nil
        var l: [String: String] = [:]
        for (k, v) in caps["limites"] as? [String: Any] ?? [:] {
            if let codigo = v as? String { l[k] = codigo }
        }
        m.limites = l
        return m
    }
}

// MARK: - As capacidades do iOS no fio (§3.2)

enum CapacidadesRemotas {

    /// O teto do nome da câmera no fio (o núcleo recusa acima de 64 bytes).
    static let tetoDoNome = 64

    /// **As capacidades desta câmera**, do mesmo cálculo que monta o painel (`MoldeDoPainel.local`):
    /// um descritor por campo que um receptor pode pedir, e `limites` com o código de quem limita.
    ///
    /// - `iso` vai com `inteiro` e a faixa **para dentro** (`ceil(min)`, `floor(max)`): o `minISO` de
    ///   uma câmera pode ser fracionário, e um degrau no mínimo exato seria recusado por `inteiro`;
    /// - `obturadorNs` vai com o **teto** (`min(1/fps, máximo)`, R9 §3.1): quando o fps muda, muda a
    ///   faixa, e a casca chama `set_capabilities` (não é troca de câmera);
    /// - a anti-cintilação não entra em `controles` (sem API no iOS): `limites` diz `ios_cintilacao`.
    static func doIOS(_ c: CapacidadesDaCamera, _ f: FaixasDaCamera, nome: String) -> [String: Any] {
        let m = MoldeDoPainel.local(c, f)
        var controles: [String: Any] = [:]
        controles["exposicao"] = ["valores": m.exposicaoManual ? ["auto", "manual"] : ["auto"]]
        if let ev = m.ev { controles["ev"] = ["min": ev.min, "max": ev.max, "passo": RegrasDosControles.passoDoEv] }
        if m.travaExposicao { controles["travaExposicao"] = [String: Any]() }
        var limites = m.limites
        if let iso = m.iso {
            // A folga de 0,01 tira o ruído do `Float` (22,000002 não pode virar 23).
            let a = (iso.min - 0.01).rounded(.up), b = (iso.max + 0.01).rounded(.down)
            if a <= b {
                controles["iso"] = ["min": Int(a), "max": Int(b), "inteiro": true]
            } else {
                limites["iso"] = "fabricante"
            }
        }
        if m.obturador != nil {
            let teto = m.tetoDoObturadorNs
            let minimo = Int64(m.obturador?.min ?? 0)
            if teto >= minimo, teto > 0 {
                controles["obturadorNs"] = ["min": minimo, "max": teto, "inteiro": true]
            } else {
                limites["obturadorNs"] = "fabricante"
            }
        }
        let ordem = ["auto", "incandescente", "fluorescente", "luzDoDia", "nublado", "kelvin"]
        controles["balanco"] = ["valores": ordem.filter { m.balanco.contains($0) }]
        if m.kelvin != nil {
            controles["kelvin"] = ["min": RegrasDosControles.kelvinMinimo, "max": RegrasDosControles.kelvinMaximo,
                                   "passo": 100, "inteiro": true]
        }
        if m.travaBalanco { controles["travaBalanco"] = [String: Any]() }
        if !m.foco.isEmpty {
            controles["foco"] = ["valores": ["auto", "travado", "manual"].filter { m.foco.contains($0) }]
        }
        if m.focoPosicao != nil { controles["focoPosicao"] = ["min": 0, "max": 1, "passo": 0.01] }
        if m.toque { controles["toque"] = [String: Any]() }
        return ["plataforma": "ios", "nomeDaCamera": cortarNome(nome), "controles": controles, "limites": limites]
    }

    /// **O nome da câmera no fio**, como o Android: "Frontal"/"Traseira" no idioma do app (EN
    /// "Front"/"Back"), e o tipo da lente quando o aparelho tem mais de uma atrás ("Traseira
    /// (teleobjetiva)"); uma câmera sem lado (a USB do iPad) leva o nome do seletor. Em até 64 bytes.
    static func nomeDaCamera(frontal: Bool?, nomeDaOrigem: String) -> String {
        guard let frontal else { return cortarNome(nomeDaOrigem) }
        let lado = frontal ? tr("Frontal") : tr("Traseira")
        let tipos = [("(teleobjetiva)", tr("(teleobjetiva)")), ("(ultra-angular)", tr("(ultra-angular)")),
                     ("(grande-angular)", tr("(grande-angular)"))]
        let tipo = tipos.first { nomeDaOrigem.hasSuffix(" " + $0.0) }.map { " " + $0.1 } ?? ""
        return cortarNome(lado + tipo)
    }

    /// O nome em até 64 bytes, numa fronteira de caractere.
    static func cortarNome(_ nome: String) -> String {
        var s = ""
        for ch in nome where !ch.isNewline {
            if s.utf8.count + String(ch).utf8.count > tetoDoNome { break }
            s.append(ch)
        }
        return s
    }

    /// JSON compacto, com as chaves em ordem (comparável entre duas chamadas).
    static func json(_ objeto: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(objeto),
              let d = try? JSONSerialization.data(withJSONObject: objeto, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - As regras dos dois lados

enum RegrasDoControleRemoto {

    // --- quem limita, por código (§3.2, as frases do R9 §3.5) -----------------------------------

    /// A frase de um código de quem limita, no idioma da interface. Código que esta build não
    /// conhece (ou nenhum): "Este aparelho não oferece {controle}."
    static func frase(_ codigo: String?, _ c: RegrasDosControles.Controle) -> String {
        switch codigo {
        case "fabricante": return RegrasDosControles.textoDoFabricante(c)
        case "macos": return tr("O macOS não oferece %@ para câmeras.", c.nome)
        case "ios_cintilacao": return RegrasDosControles.textoDaCintilacaoNoIOS
        case "camera_nao_oferece": return tr("Esta câmera não oferece %@.", c.nome)
        case "foco_fixo": return RegrasDosControles.textoDoFocoFixo
        case "sem_calibracao": return tr("Esta câmera não publica a calibração de cor que o Kelvin precisa.")
        case "outro_app": return tr("Outro app está controlando esta câmera. Feche-o para ajustar.")
        default: return tr("Este aparelho não oferece %@.", c.nome)
        }
    }

    // --- textos do receptor ---------------------------------------------------------------------

    static var textoDoNaoPermitido: String { tr("O aparelho não permite controle remoto da câmera") }

    static func textoDoControladoPor(_ nome: String) -> String { tr("Controlado por %@", nome) }

    /// O controle de um campo do ajuste, para a frase da recusa.
    static func controle(doCampo campo: String?) -> RegrasDosControles.Controle? {
        switch campo {
        case "iso": return .iso
        case "obturadorNs": return .obturador
        case "kelvin": return .kelvin
        case "balanco": return .presets
        case "focoPosicao", "foco": return .focoManual
        case "antiCintilacao": return .antiCintilacao
        case "ev": return .compensacao
        case "travaExposicao": return .travaExposicao
        case "travaBalanco": return .travaBalanco
        case "toque": return .toque
        default: return nil
        }
    }

    /// **A linha de uma recusa** (§3.5), ou `nil` quando a tabela diz "nada" (`superado`, `ocupado`,
    /// `camera_trocada`…). `nao_permitido` tem a linha própria, que fica enquanto a opção estiver
    /// desligada; aqui ela não se repete.
    static func textoDaRecusa(motivo: String, campo: String?) -> String? {
        switch motivo {
        case "campo_desconhecido", "fora_da_faixa", "incoerente":
            if let c = controle(doCampo: campo) { return tr("Este aparelho não aceitou %@.", c.nome) }
            return tr("Este aparelho não aceitou o ajuste.")
        case "sem_resposta":
            return tr("O aparelho não respondeu.")
        case "nao_permitido", "nao_pareado", "sem_camera", "camera_trocada", "superado", "ocupado",
             "invalido", "fora_da_imagem":
            return nil
        default:
            // `nao_aplicado`, e qualquer código que esta build não conheça (§3.5).
            return tr("O aparelho não conseguiu aplicar o ajuste.")
        }
    }

    // --- números ---------------------------------------------------------------------------------

    /// Um número cru do driver (o brilho e o ganho do Windows): inteiro sem casas, senão uma casa,
    /// com o separador do idioma.
    static func numero(_ v: Double) -> String {
        guard v.isFinite else { return "?" }
        if abs(v - v.rounded()) < 1e-6 { return String(Int(v.rounded())) }
        return RegrasDosControles.comVirgula(v, casas: 1)
    }

    /// **O obturador em potências de 2** (Windows, R9 §3.1): 2^v s para `v` inteiro dentro da faixa,
    /// do mais longo ao mais curto; o texto é `1/2^-v s` (1/32 s, 1/64 s…) e `2^v s` de 1 s para cima.
    static func escalaLog2(minimoNs: Double, maximoNs: Double) -> [RegrasDosControles.DegrauDoObturador] {
        guard minimoNs > 0, maximoNs >= minimoNs else { return [] }
        let a = Int((log2(minimoNs / 1e9) - 1e-9).rounded(.up))
        let b = Int((log2(maximoNs / 1e9) + 1e-9).rounded(.down))
        guard a <= b, b - a < 64 else { return [] }
        return (a...b).reversed().map { v in
            let ns = Int64((pow(2, Double(v)) * 1e9).rounded())
            let corte = max(Int64(minimoNs.rounded(.up)), min(ns, Int64(maximoNs.rounded(.down))))
            let den = v < 0 ? 1 << (-v) : 0
            let texto = v < 0 ? "1/\(den) s" : "\(1 << v) s"
            return RegrasDosControles.DegrauDoObturador(ns: corte, denominador: den, texto: texto, semCintilacao: false)
        }
    }

    // --- o pedido parcial do receptor (§5) ------------------------------------------------------

    /// O registro como objeto JSON (o mesmo JSON que a casca grava).
    static func objeto(_ a: AjustesDaCamera) -> [String: Any] {
        guard let d = a.json(), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// **Só o que a pessoa mexeu**: os campos de `depois` diferentes de `antes`, e só os que as
    /// capacidades deixam pedir (os campos de trava lida nunca vão: quem os escreve é o filmador).
    static func camposMudados(de antes: AjustesDaCamera, para depois: AjustesDaCamera,
                              pedidos permitidos: Set<String>) -> [String: Any] {
        let a = objeto(antes), b = objeto(depois)
        var saida: [String: Any] = [:]
        for (k, v) in b where permitidos.contains(k) {
            if !iguais(a[k], v) { saida[k] = v }
        }
        return saida
    }

    /// Os campos que um receptor pode pedir, das capacidades (os nomes de `controles`, menos o
    /// `toque`, que é ação).
    static func camposPedidos(_ caps: [String: Any]) -> Set<String> {
        Set((caps["controles"] as? [String: Any] ?? [:]).keys).subtracting(["toque"])
    }

    /// `null` é o mesmo que ausente, e número se compara por valor (contrato §3).
    static func iguais(_ x: Any?, _ y: Any?) -> Bool {
        let x = x is NSNull ? nil : x, y = y is NSNull ? nil : y
        switch (x, y) {
        case (nil, nil): return true
        case let (a as NSNumber, b as NSNumber): return a == b
        case let (a as String, b as String): return a == b
        case (nil, _), (_, nil): return false
        default:
            guard let a = x, let b = y, JSONSerialization.isValidJSONObject([a]), JSONSerialization.isValidJSONObject([b]),
                  let da = try? JSONSerialization.data(withJSONObject: [a], options: [.sortedKeys]),
                  let db = try? JSONSerialization.data(withJSONObject: [b], options: [.sortedKeys]) else { return false }
            return da == db
        }
    }

    // --- o pedido aceito, no filmador (§6) ------------------------------------------------------

    /// Um pedido que o núcleo entregou (`quall_camera_host_next_request`).
    struct Pedido {
        var n: UInt64
        var autor: String
        /// O ajuste parcial, já conferido pelo núcleo contra as capacidades (os valores do
        /// `JSONSerialization`: `NSNumber` e `String`).
        var ajuste: [String: Any]
        var restaurar: Bool
        var toque: (x: Double, y: Double, longo: Bool)?

        static func de(json: String) -> Pedido? {
            guard let d = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let n = numeroJSON(o["n"]), n >= 1, n < 1.8e19 else { return nil }
            var p = Pedido(n: UInt64(n), autor: o["autor"] as? String ?? "", ajuste: [:],
                           restaurar: booleanoJSON(o["restaurar"]) ?? false, toque: nil)
            for (k, v) in o["ajuste"] as? [String: Any] ?? [:] where !(v is NSNull) { p.ajuste[k] = v }
            if let t = o["toque"] as? [String: Any], let x = numeroJSON(t["x"]), let y = numeroJSON(t["y"]) {
                p.toque = (x, y, booleanoJSON(t["longo"]) ?? false)
            }
            return p
        }
    }

    /// Um número do JSON (`NSNumber` que não é booleano), finito.
    static func numeroJSON(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// Um booleano do JSON.
    static func booleanoJSON(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// O que a câmera diz estar usando **agora**, para "partir do lido" (§6, passo 1).
    struct Lido: Equatable {
        var iso: Double?
        var obturadorNs: Int64?
        /// `deviceWhiteBalanceGains`, `[vermelho, verde, azul]`.
        var ganhos: [Double]?
        /// O Kelvin estimado dos ganhos (só quando eles estão na faixa da conta).
        var kelvin: Int?
        /// `focoPosicao` lida (`1 − lensPosition`).
        var focoPosicao: Double?
    }

    /// **Aplica um pedido sobre o registro**, na ordem do §6: `restaurar` → os modos → as travas → os
    /// valores. "Partir do lido" só para os campos que o pedido **não** trouxe: `{"exposicao":
    /// "manual","iso":800}` fica com 800, e o obturador parte do lido. Os valores são arredondados ao
    /// passo do iOS (EV em 1/3 cortado na faixa, Kelvin de 100 em 100, foco em 0,01); ISO e obturador
    /// ficam como vieram (o plano os corta pela faixa do instante, e o guardado fica intacto, R9
    /// §2.2). Devolve `nil` quando falta o lido que um modo precisa (`nao_aplicado`).
    static func aplicar(_ p: Pedido, sobre registro: AjustesDaCamera, lido: Lido,
                        evMin: Double, evMax: Double) -> AjustesDaCamera? {
        var a = p.restaurar ? AjustesDaCamera.padrao : registro
        let aj = p.ajuste
        func texto(_ k: String) -> String? { aj[k] as? String }
        func numero(_ k: String) -> Double? { numeroJSON(aj[k]) }
        func booleano(_ k: String) -> Bool? { booleanoJSON(aj[k]) }

        // 1. Os modos.
        if let e = texto("exposicao").flatMap(AjustesDaCamera.Exposicao.init(rawValue:)) {
            if e == .manual, a.exposicao != .manual || a.iso == nil || a.obturadorNs == nil {
                // O "Passar para Manual" do R9 §4.3, só no que o pedido não trouxe.
                if numero("iso") == nil {
                    guard let i = lido.iso else { return nil }
                    a.iso = i
                }
                if numero("obturadorNs") == nil {
                    guard let n = lido.obturadorNs, n > 0 else { return nil }
                    a.obturadorNs = n
                }
            }
            a.exposicao = e
        }
        if let b = texto("balanco").flatMap(AjustesDaCamera.Balanco.init(rawValue:)) {
            if b == .kelvin, a.kelvin == nil, numero("kelvin") == nil {
                // O estimado no momento de passar a Kelvin (R9 §2), ou a luz do dia.
                a.kelvin = lido.kelvin.map { RegrasDosControles.arredondarKelvin(Double($0)) } ?? 5500
            }
            a.balanco = b
            // Com Kelvin ou um preset, a trava de balanço não se aplica (R9 §3.4).
            if b != .auto { a.travaBalanco = false; a.travaGanhos = nil }
        }
        if let f = texto("foco").flatMap(AjustesDaCamera.Foco.init(rawValue:)) {
            // Travar guarda a posição lida; passar a Manual parte dela, se ainda não havia uma (R9 §2.1).
            if numero("focoPosicao") == nil,
               f == .travado || (f == .manual && (a.foco == .auto || a.focoPosicao == nil)) {
                if let p = lido.focoPosicao { a.focoPosicao = p }
            }
            a.foco = f
        }

        // 2. As travas, com os valores lidos no instante de travar (R9 §2.1).
        if let t = booleano("travaExposicao") {
            a.travaExposicao = t
            if t {
                a.travaIso = lido.iso
                a.travaObturadorNs = lido.obturadorNs
            } else {
                a.travaIso = nil; a.travaObturadorNs = nil
            }
        }
        if let t = booleano("travaBalanco") {
            a.travaBalanco = t
            a.travaGanhos = t ? lido.ganhos : nil
        }

        // 3. Os valores.
        if let v = numero("ev") { a.ev = RegrasDosControles.arredondarEv(v, minimo: evMin, maximo: evMax) }
        if let v = numero("iso") { a.iso = v }
        if let v = numero("obturadorNs") { a.obturadorNs = Int64(v.rounded()) }
        if let v = numero("kelvin") { a.kelvin = RegrasDosControles.arredondarKelvin(v) }
        if let v = numero("focoPosicao") { a.focoPosicao = (max(0, min(1, v)) * 100).rounded() / 100 }
        if let c = texto("antiCintilacao").flatMap(AjustesDaCamera.AntiCintilacao.init(rawValue:)) {
            a.antiCintilacao = c
        }
        return a
    }

    // --- o estado do receptor (§11.1) -----------------------------------------------------------

    /// O que a tela do receptor precisa do `quall_camera_remote_state_json`.
    struct EstadoDoReceptor: Equatable {
        var situacao: String
        /// O JSON das capacidades, como veio (para saber quando mudou sem comparar dicionários).
        var capacidadesJson: String?
        var capacidades: [String: Any]?
        var ajuste: AjustesDaCamera?
        var leitura = RegrasDosControles.Leitura()
        var divergentes: [String] = []
        var autor: String?
        var recusa: (motivo: String, campo: String?)?

        static func == (a: EstadoDoReceptor, b: EstadoDoReceptor) -> Bool {
            a.situacao == b.situacao && a.capacidadesJson == b.capacidadesJson && a.ajuste == b.ajuste
                && a.leitura == b.leitura && a.divergentes == b.divergentes && a.autor == b.autor
                && a.recusa?.motivo == b.recusa?.motivo && a.recusa?.campo == b.recusa?.campo
        }

        static func de(json: String) -> EstadoDoReceptor? {
            guard let d = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let s = o["situacao"] as? String else { return nil }
            var e = EstadoDoReceptor(situacao: s)
            if let c = o["capacidades"] as? [String: Any] {
                e.capacidades = c
                e.capacidadesJson = CapacidadesRemotas.json(c)
            }
            if let a = o["ajuste"] as? [String: Any], JSONSerialization.isValidJSONObject(a),
               let dados = try? JSONSerialization.data(withJSONObject: a) {
                e.ajuste = AjustesDaCamera.de(json: dados)
            }
            if let l = o["lido"] as? [String: Any] {
                func n(_ k: String) -> Double? { numeroJSON(l[k]) }
                e.leitura.iso = n("iso")
                e.leitura.obturadorNs = n("obturadorNs").map { Int64($0.rounded()) }
                e.leitura.kelvin = n("kelvin").map { Int($0.rounded()) }
                e.leitura.abertura = n("abertura")
                e.divergentes = l["divergentes"] as? [String] ?? []
            }
            e.autor = o["autor"] as? String
            if let r = o["recusa"] as? [String: Any], let m = r["motivo"] as? String {
                e.recusa = (m, r["campo"] as? String)
            }
            return e
        }
    }

    /// "A câmera usou {lido} em vez de {pedido}." para o primeiro campo que o filmador diz estar
    /// divergindo (a regra dos 2 s é dele, R9 §3.6; o receptor só mostra).
    static func textoDaDivergencia(_ divergentes: [String], lido l: RegrasDosControles.Leitura,
                                   ajuste a: AjustesDaCamera, molde m: MoldeDoPainel) -> String? {
        for campo in divergentes {
            switch campo {
            case "iso":
                if let li = l.iso, let pi = a.iso {
                    return RegrasDosControles.textoDaDivergencia(lido: m.textoDoIso(li), pedido: m.textoDoIso(pi))
                }
            case "obturadorNs":
                if let ln = l.obturadorNs, let pn = a.obturadorNs {
                    return RegrasDosControles.textoDaDivergencia(lido: RegrasDosControles.textoDoObturador(ns: ln),
                                                                 pedido: RegrasDosControles.textoDoObturador(ns: pn))
                }
            case "kelvin":
                let kp = a.balanco == .kelvin ? a.kelvin : RegrasDosControles.kelvinDoPreset(a.balanco)
                if let lk = l.kelvin, let kp {
                    return RegrasDosControles.textoDaDivergencia(lido: "\(lk) K", pedido: "\(kp) K")
                }
            default:
                break
            }
        }
        return nil
    }
}

// MARK: - O toque na imagem do receptor (§3.4)

/// **O ponto do toque no quadro decodificado**, de 0 a 1, antes de qualquer transformação deste lado:
/// a imagem é desenhada com `.resizeAspect` (as tarjas dos lados ou de cima e de baixo), e um toque
/// numa tarja não é um ponto do quadro (`nil`: não se manda).
enum PontoNoQuadro {
    static func de(toque p: (x: Double, y: Double), area: (largura: Double, altura: Double),
                   video: (largura: Double, altura: Double)) -> (x: Double, y: Double)? {
        guard area.largura > 0, area.altura > 0, video.largura > 0, video.altura > 0 else { return nil }
        let escala = min(area.largura / video.largura, area.altura / video.altura)
        let w = video.largura * escala, h = video.altura * escala
        let x0 = (area.largura - w) / 2, y0 = (area.altura - h) / 2
        let x = (p.x - x0) / w, y = (p.y - y0) / h
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (x, y)
    }
}
