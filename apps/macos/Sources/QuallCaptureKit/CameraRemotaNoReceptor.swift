import CoreGraphics
import Foundation
import QuallIdiomaKit

// **O controle remoto da câmera, no Mac que recebe** (R9b, `docs/controle-remoto-da-camera.md` §5, §12):
// a parte pura. O estado que o núcleo publica (`quall_camera_remote_state_json`, §11.1) lido em tipos, e
// o plano do painel desenhado **a partir das capacidades que chegaram** — não da câmera deste Mac. Um
// iPhone filmando tem ISO, Kelvin e foco manual, e o painel do receptor mostra tudo isso, mesmo que o Mac
// não tenha nenhum. Os nomes, as abas e as frases são os do R9 (`ControlesDaCamera.swift`).
//
// Mora em `QuallCaptureKit` por reaproveitar as peças do R9 (`NomeDoControle`, `TextoDoLimite`,
// `AbaDosAjustes`, `OpcaoDeBalanco`), e não toca em rede nem em câmera. Testado em `TestesDaCameraRemota`.

/// **Um descritor** de `controles` (contrato §3.2): texto (`valores`), número (`min`/`max`) ou sim/não.
public struct DescritorRemoto: Equatable, Sendable {
    public var valores: [String]?
    public var min: Double?
    public var max: Double?
    public var passo: Double?
    public var inteiro = false
    /// As dicas para a tela (§3.2): a marca "ganho digital", a escala do obturador do Windows, a unidade
    /// do brilho e do ganho, e o padrão do driver (o brilho é guardado como deslocamento dele).
    public var analogicoMax: Double?
    public var escala: String?
    public var unidade: String?
    public var origem: Double?

    public init(valores: [String]? = nil, min: Double? = nil, max: Double? = nil, passo: Double? = nil,
                inteiro: Bool = false, analogicoMax: Double? = nil, escala: String? = nil, unidade: String? = nil,
                origem: Double? = nil) {
        self.valores = valores
        self.min = min
        self.max = max
        self.passo = passo
        self.inteiro = inteiro
        self.analogicoMax = analogicoMax
        self.escala = escala
        self.unidade = unidade
        self.origem = origem
    }

    public var ehNumero: Bool { min != nil && max != nil }

    static func ler(_ o: [String: Any]) -> DescritorRemoto {
        var d = DescritorRemoto()
        d.valores = (o["valores"] as? [Any])?.compactMap { $0 as? String }
        d.min = numero(o["min"])
        d.max = numero(o["max"])
        d.passo = numero(o["passo"])
        d.inteiro = (o["inteiro"] as? Bool) ?? false
        d.analogicoMax = numero(o["analogicoMax"])
        d.escala = o["escala"] as? String
        d.unidade = o["unidade"] as? String
        d.origem = numero(o["origem"])
        return d
    }
}

/// O que o filmador declara (§3.2).
public struct CapacidadesRemotas: Equatable, Sendable {
    public var plataforma: String
    public var nomeDaCamera: String
    public var controles: [String: DescritorRemoto]
    public var limites: [String: String]

    public init(plataforma: String = "", nomeDaCamera: String = "", controles: [String: DescritorRemoto] = [:],
                limites: [String: String] = [:]) {
        self.plataforma = plataforma
        self.nomeDaCamera = nomeDaCamera
        self.controles = controles
        self.limites = limites
    }

    static func ler(_ o: [String: Any]) -> CapacidadesRemotas {
        var c = CapacidadesRemotas()
        c.plataforma = o["plataforma"] as? String ?? ""
        c.nomeDaCamera = o["nomeDaCamera"] as? String ?? ""
        for (k, v) in (o["controles"] as? [String: Any]) ?? [:] {
            if let d = v as? [String: Any] { c.controles[k] = DescritorRemoto.ler(d) }
        }
        for (k, v) in (o["limites"] as? [String: Any]) ?? [:] {
            if let s = v as? String { c.limites[k] = s }
        }
        return c
    }
}

/// **O ajuste da câmera do outro lado** (o registro do R9 §2), só os campos que um receptor mostra. `nil`
/// é o mesmo que ausente (o Android grava `null`, o Mac só cinco campos).
public struct AjusteRemoto: Equatable, Sendable {
    public var exposicao: String?
    public var ev: Double?
    public var travaExposicao: Bool?
    public var iso: Double?
    public var obturadorNs: Double?
    public var antiCintilacao: String?
    public var balanco: String?
    public var kelvin: Double?
    public var travaBalanco: Bool?
    public var foco: String?
    public var focoPosicao: Double?

    public init() {}

    static func ler(_ o: [String: Any]) -> AjusteRemoto {
        var a = AjusteRemoto()
        a.exposicao = o["exposicao"] as? String
        a.ev = numero(o["ev"])
        a.travaExposicao = simNao(o["travaExposicao"])
        a.iso = numero(o["iso"])
        a.obturadorNs = numero(o["obturadorNs"])
        a.antiCintilacao = o["antiCintilacao"] as? String
        a.balanco = o["balanco"] as? String
        a.kelvin = numero(o["kelvin"])
        a.travaBalanco = simNao(o["travaBalanco"])
        a.foco = o["foco"] as? String
        a.focoPosicao = numero(o["focoPosicao"])
        return a
    }

    /// O modo que o registro não grava vale `auto` (§6, item 7).
    public var exposicaoEfetiva: String { exposicao ?? "auto" }
    public var balancoEfetivo: String { balanco ?? "auto" }
    public var focoEfetivo: String { foco ?? "auto" }
}

/// **O que a câmera do outro lado diz estar usando** (R9 §3.6), e os campos em que o filmador está
/// mostrando "A câmera usou … em vez de …".
public struct LidoRemoto: Equatable, Sendable {
    public var iso: Double?
    public var obturadorNs: Double?
    public var kelvin: Double?
    public var abertura: Double?
    public var focoPosicao: Double?
    public var divergentes: [String] = []

    public init() {}

    static func ler(_ o: [String: Any]) -> LidoRemoto {
        var l = LidoRemoto()
        l.iso = numero(o["iso"])
        l.obturadorNs = numero(o["obturadorNs"])
        l.kelvin = numero(o["kelvin"])
        l.abertura = numero(o["abertura"])
        l.focoPosicao = numero(o["focoPosicao"])
        l.divergentes = ((o["divergentes"] as? [Any]) ?? []).compactMap { $0 as? String }
        return l
    }

    public var vazio: Bool { iso == nil && obturadorNs == nil && kelvin == nil && abertura == nil }
}

/// **O estado do receptor**, literal do §11.1.
public struct EstadoDaCameraRemota: Equatable, Sendable {
    /// `esperando`, `sem_resposta`, `sem_camera`, `nao_permitido` ou `pronto` (§5).
    public var situacao: String
    public var capacidades: CapacidadesRemotas?
    /// O aplicado com o pendente por cima: é o que o painel mostra.
    public var ajuste: AjusteRemoto
    public var lido: LidoRemoto?
    public var autor: String?
    public var recusa: (motivo: String, campo: String?)?

    public init(situacao: String = "esperando", capacidades: CapacidadesRemotas? = nil, ajuste: AjusteRemoto = AjusteRemoto(),
                lido: LidoRemoto? = nil, autor: String? = nil, recusa: (motivo: String, campo: String?)? = nil) {
        self.situacao = situacao
        self.capacidades = capacidades
        self.ajuste = ajuste
        self.lido = lido
        self.autor = autor
        self.recusa = recusa
    }

    public static func == (a: EstadoDaCameraRemota, b: EstadoDaCameraRemota) -> Bool {
        a.situacao == b.situacao && a.capacidades == b.capacidades && a.ajuste == b.ajuste && a.lido == b.lido
            && a.autor == b.autor && a.recusa?.motivo == b.recusa?.motivo && a.recusa?.campo == b.recusa?.campo
    }

    public static func ler(_ json: String) -> EstadoDaCameraRemota? {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let situacao = o["situacao"] as? String else { return nil }
        var e = EstadoDaCameraRemota(situacao: situacao)
        e.capacidades = (o["capacidades"] as? [String: Any]).map(CapacidadesRemotas.ler)
        e.ajuste = (o["ajuste"] as? [String: Any]).map(AjusteRemoto.ler) ?? AjusteRemoto()
        e.lido = (o["lido"] as? [String: Any]).map(LidoRemoto.ler)
        e.autor = o["autor"] as? String
        if let r = o["recusa"] as? [String: Any], let m = r["motivo"] as? String {
            e.recusa = (m, r["campo"] as? String)
        }
        return e
    }

    /// Com `pronto` e `nao_permitido` o painel aparece (§5): o resto não mostra controle de câmera nenhum.
    public var mostraOsControles: Bool { (situacao == "pronto" || situacao == "nao_permitido") && capacidades != nil }
    public var permitido: Bool { situacao == "pronto" }
}

private func numero(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite ? d : nil
}

private func simNao(_ v: Any?) -> Bool? {
    guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}

// MARK: - os textos (contrato §3.2, §3.5; R9 §3.5)

/// As frases do controle remoto, no idioma da vez.
public enum TextosDaCameraRemota {
    public static var naoPermitido: String { T("O aparelho não permite controle remoto da câmera") }
    public static var permitir: String { T("Permitir controle remoto da câmera") }
    public static func controladoPor(_ nome: String) -> String { T("Controlado por %@", nome) }
    public static var naoAplicou: String { T("O aparelho não conseguiu aplicar o ajuste.") }
    public static var naoRespondeu: String { T("O aparelho não respondeu.") }
    public static var destraveParaCompensar: String { T("Destrave a exposição para compensar.") }
    public static var passarParaManual: String { T("Passar para Manual") }

    /// O nome do R9 §3.5 do campo do ajuste (ou da ação), com a `unidade` do Windows. `nil` para um campo
    /// que esta build não conhece.
    public static func nomes(do campo: String, _ c: CapacidadesRemotas?) -> [NomeDoControle]? {
        let unidade = c?.controles[campo]?.unidade
        switch campo {
        case "ev": return [unidade == "brilho" ? .brilho : .compensacao]
        case "iso": return [unidade == "ganho" ? .ganho : .iso]
        case "obturadorNs": return [.obturador]
        case "kelvin": return [.kelvin]
        case "balanco": return [.presetsDeBalanco]
        case "antiCintilacao": return [.antiCintilacao]
        case "focoPosicao": return [.focoManual]
        case "foco": return [.travaFoco]
        case "travaExposicao": return [.travaExposicao]
        case "travaBalanco": return [.travaBalanco]
        case "toque": return [.toque]
        case "exposicao":
            return [c?.controles["iso"]?.unidade == "ganho" ? .ganho : .iso, .obturador]
        default: return nil
        }
    }

    /// **A frase de quem limita**, a partir do código (§3.2). Mais de um nome vão juntos com "e" ("O macOS
    /// não oferece ISO e o obturador para câmeras.").
    public static func limite(_ codigo: String, _ nomes: [NomeDoControle]) -> String {
        let juntos = TextoDoLimite.juntar(nomes)
        switch codigo {
        case "fabricante": return T("O fabricante deste aparelho não libera %@ para outros apps.", juntos)
        case "macos": return TextoDoLimite.doMacOS(nomes)
        case "ios_cintilacao": return T("O iOS ajusta a cintilação sozinho.")
        case "camera_nao_oferece": return T("Esta câmera não oferece %@.", juntos)
        case "foco_fixo": return TextoDoLimite.focoFixo
        case "sem_calibracao": return T("Esta câmera não publica a calibração de cor que o Kelvin precisa.")
        case "outro_app": return T("Outro app está controlando esta câmera. Feche-o para ajustar.")
        default: return T("Este aparelho não oferece %@.", juntos)
        }
    }

    /// O limite de um campo: o código de `limites`, ou "Este aparelho não oferece …" quando o filmador não
    /// diz por quê.
    public static func limite(do campo: String, _ c: CapacidadesRemotas) -> String {
        limite(c.limites[campo] ?? "", nomes(do: campo, c) ?? [])
    }

    /// **A linha da recusa** (§3.5), por 3 s; `nil` para os motivos que não mostram nada.
    public static func recusa(_ motivo: String, campo: String?, _ c: CapacidadesRemotas?) -> String? {
        switch motivo {
        case "nao_permitido": return naoPermitido
        case "campo_desconhecido", "fora_da_faixa", "incoerente":
            if let campo, let n = nomes(do: campo, c) { return T("Este aparelho não aceitou %@.", TextoDoLimite.juntar(n)) }
            return T("Este aparelho não aceitou o ajuste.")
        case "sem_resposta": return naoRespondeu
        case "nao_pareado", "sem_camera", "camera_trocada", "superado", "ocupado", "invalido", "fora_da_imagem": return nil
        default: return naoAplicou
        }
    }
}

// MARK: - os números na tela (R9 §3: sempre com vírgula decimal)

public enum NumerosDaCamera {
    /// `0,3` — vírgula decimal sempre, independentemente do idioma (R9 §3).
    public static func comVirgula(_ v: Double, casas: Int) -> String {
        String(format: "%.\(casas)f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// `+0,3 EV`, `-1 EV`, `0 EV` (R9 §3.3): o sinal sempre visível, sem casas a mais.
    public static func ev(_ v: Double) -> String {
        if abs(v) < 0.005 { return "0 EV" }
        let casas = abs(v - v.rounded()) < 0.005 ? 0 : 1
        return (v > 0 ? "+" : "-") + comVirgula(abs(v), casas: casas) + " EV"
    }

    /// `1/60 s` (R9 §3.1); de 1 s para cima, `2 s`.
    public static func obturador(ns: Double) -> String {
        guard ns > 0 else { return "—" }
        if ns >= 1e9 {
            let s = ns / 1e9
            return comVirgula(s, casas: abs(s - s.rounded()) < 0.05 ? 0 : 1) + " s"
        }
        return "1/\(Int((1e9 / ns).rounded())) s"
    }

    public static func iso(_ v: Double) -> String { "ISO \(Int(v.rounded()))" }
    public static func kelvin(_ v: Double) -> String { "\(Int(v.rounded())) K" }
    public static func abertura(_ v: Double) -> String { "f/" + comVirgula(v, casas: 1) }

    /// **As frações de cinema e vídeo** (R9 §3.1), só as que cabem entre o mínimo e o teto, mais o próprio
    /// teto (o 1/fps do filmador vem como `max`).
    public static let fracoesDoObturador = [24, 25, 30, 48, 50, 60, 100, 120, 125, 250, 500, 1000, 2000, 4000, 8000]

    public static func degrausDoObturador(_ d: DescritorRemoto) -> [Double] {
        guard let mn = d.min, let mx = d.max, mx >= mn, mx > 0 else { return [] }
        if d.escala == "log2" {
            // O Windows: 2^v s, só inteiros (R9 §3.1). O filmador arredonda e corta no teto.
            let de = Int((log2(Swift.max(mn, 1) / 1e9)).rounded(.up))
            let ate = Int((log2(mx / 1e9)).rounded(.down))
            guard de <= ate else { return [mx] }
            return (de...ate).map { pow(2, Double($0)) * 1e9 }.sorted(by: >)
        }
        var v = fracoesDoObturador.map { (1e9 / Double($0)).rounded() }.filter { $0 >= mn - 0.5 && $0 <= mx + 0.5 }
        if !v.contains(where: { abs($0 - mx) < 1 }) { v.append(mx) }
        return Array(Set(v)).sorted(by: >)
    }

    /// O texto de um degrau do obturador na escala log2: `1/32 s`, `1 s`, `2 s`.
    public static func obturadorLog2(ns: Double) -> String {
        let v = Int(log2(ns / 1e9).rounded())
        return v < 0 ? "1/\(1 << -v) s" : "\(1 << v) s"
    }

    /// **ISO em terços de stop** (R9 §3.2), cortado pela faixa, mais o mínimo e o máximo exatos.
    public static let isoEmTercos: [Double] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000,
                                               1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400]

    public static func degrausDoIso(_ d: DescritorRemoto) -> [Double] {
        guard let mn = d.min, let mx = d.max, mx >= mn else { return [] }
        if d.unidade == "ganho" { return degrausPorPasso(d) }
        let v = [mn] + isoEmTercos.filter { $0 > mn && $0 < mx } + [mx]
        return Array(Set(v)).sorted()
    }

    /// Da faixa, de passo em passo (o EV, o Kelvin, o foco, o brilho e o ganho do driver), no máximo 400
    /// degraus: um deslizante com mais que isso não tem degrau que o dedo ache.
    public static func degrausPorPasso(_ d: DescritorRemoto, passoPadrao: Double = 1) -> [Double] {
        guard let mn = d.min, let mx = d.max, mx >= mn else { return [] }
        var passo = d.passo ?? (d.inteiro ? 1 : passoPadrao)
        if passo <= 0 { passo = passoPadrao }
        while (mx - mn) / passo > 400 { passo *= 2 }
        var v: [Double] = []
        var x = mn
        while x <= mx + passo * 1e-6 {
            v.append(d.inteiro ? x.rounded() : (x / passo).rounded() * passo)
            x += passo
        }
        if let ultimo = v.last, abs(ultimo - mx) > passo * 1e-6 { v.append(mx) }
        return v
    }

    /// O degrau mais perto de `valor` (o painel mostra o aplicado mesmo que ele não esteja na escala).
    public static func indice(de valor: Double?, em degraus: [Double]) -> Int {
        guard let valor, !degraus.isEmpty else { return 0 }
        var melhor = 0
        for (i, d) in degraus.enumerated() where abs(d - valor) < abs(degraus[melhor] - valor) { melhor = i }
        return melhor
    }
}

// MARK: - o painel (R9 §4.3, desenhado das capacidades remotas)

/// Uma opção de um grupo (Auto / Manual, a grade do balanço, o foco).
public struct OpcaoRemota: Equatable, Sendable {
    public var rotulo: String
    public var valor: String
    public var escolhida: Bool
    public var disponivel: Bool
}

/// Um deslizante por degraus.
public struct DeslizanteRemoto: Equatable, Sendable {
    /// O campo do ajuste que ele pede.
    public var campo: String
    public var titulo: String
    public var degraus: [Double]
    public var indice: Int
    public var textos: [String]
    public var disponivel: Bool
    /// A linha embaixo: por que está apagado, ou a marca "ganho digital".
    public var linha: String?
    /// O número vai como inteiro no pedido (`"inteiro":true`, §3.2).
    public var inteiro: Bool

    public var texto: String { textos.indices.contains(indice) ? textos[indice] : "" }

    /// O valor de um degrau, como vai no pedido.
    public func valor(_ i: Int) -> Double {
        let v = degraus[Swift.max(0, Swift.min(degraus.count - 1, i))]
        return inteiro ? v.rounded() : v
    }
}

/// Um interruptor (as travas).
public struct InterruptorRemoto: Equatable, Sendable {
    public var campo: String
    public var titulo: String
    public var ligado: Bool
    public var disponivel: Bool
    public var linha: String?
}

/// **O que o painel do receptor mostra.** Puro: a vista só desenha.
public struct PlanoRemotoDoPainel: Equatable, Sendable {
    public var nome: String
    /// `pronto`: os controles vivos. `nao_permitido`: os valores, tudo apagado.
    public var vivo: Bool
    /// O alto do painel: "O aparelho não permite…", a recusa de 3 s, ou nada.
    public var aviso: String?
    /// `ISO 400 · 1/60 s · 5200 K · f/1,7` (R9 §3.6); `nil` quando o filmador não lê nada (o Mac).
    public var lido: String?
    /// "A câmera usou … em vez de …", uma por campo divergente.
    public var divergencias: [String]

    // Exposição
    public var exposicao: [OpcaoRemota]
    public var linhaDaExposicao: String?
    public var ev: DeslizanteRemoto?
    public var linhaDoEv: String?
    public var travaExposicao: InterruptorRemoto?
    public var antiCintilacao: [OpcaoRemota]
    public var linhaDaAntiCintilacao: String?
    // ISO e obturador
    public var tituloDaAbaDoIso: String
    /// O grupo inteiro sem nada: uma linha só (R9 §3.5).
    public var linhaDoIsoEObturador: String?
    /// Com Auto: "Passe a exposição para Manual…" e o botão "Passar para Manual" (R9 §4.3).
    public var passeParaManual: Bool
    public var iso: DeslizanteRemoto?
    public var linhaDoIso: String?
    public var obturador: DeslizanteRemoto?
    public var linhaDoObturador: String?
    // Balanço
    public var balanco: [OpcaoRemota]
    public var limitesDoBalanco: [String]
    public var kelvin: DeslizanteRemoto?
    public var travaBalanco: InterruptorRemoto?
    // Foco
    public var linhaDoFocoFixo: String?
    public var foco: [OpcaoRemota]
    public var limitesDoFoco: [String]
    public var focoPosicao: DeslizanteRemoto?
    /// O clique na imagem do receptor manda o toque (§3.4) onde o filmador tem ponto de interesse.
    public var toqueDisponivel: Bool
    /// "Toque na imagem para focar e medir naquele ponto.", ou o limite.
    public var notaDoToque: String

    /// O plano a partir do estado; `nil` quando o painel não aparece (§5).
    public static func de(_ e: EstadoDaCameraRemota) -> PlanoRemotoDoPainel? {
        guard e.mostraOsControles, let c = e.capacidades else { return nil }
        let a = e.ajuste
        let vivo = e.permitido
        func tem(_ campo: String) -> DescritorRemoto? { c.controles[campo] }
        func limite(_ campo: String) -> String { TextosDaCameraRemota.limite(do: campo, c) }
        func opcoes(_ campo: String, _ todas: [(String, String)], escolhida: String) -> [OpcaoRemota] {
            let valores = tem(campo)?.valores ?? []
            return todas.map { rotulo, valor in
                OpcaoRemota(rotulo: rotulo, valor: valor, escolhida: valor == escolhida,
                            disponivel: vivo && valores.contains(valor))
            }
        }

        let manual = a.exposicaoEfetiva == "manual"
        let travada = a.travaExposicao ?? false
        let semIsoNemObturador = tem("iso") == nil && tem("obturadorNs") == nil
        let unidadeDoIso = tem("iso")?.unidade

        // ISO e obturador: o grupo sem nada é uma linha só (R9 §3.5), com os nomes juntos quando o motivo é
        // o mesmo.
        var linhaDoGrupo: String?
        if semIsoNemObturador {
            let ci = c.limites["iso"] ?? "", co = c.limites["obturadorNs"] ?? ""
            if ci == co {
                linhaDoGrupo = TextosDaCameraRemota.limite(ci, TextosDaCameraRemota.nomes(do: "exposicao", c) ?? [])
            } else {
                linhaDoGrupo = limite("iso") + " " + limite("obturadorNs")
            }
        }

        // Exposição
        let exposicao = opcoes("exposicao", [(T("Auto"), "auto"), (T("Manual"), "manual")], escolhida: a.exposicaoEfetiva)
        var linhaDaExposicao: String?
        if !(tem("exposicao")?.valores ?? []).contains("manual") {
            linhaDaExposicao = c.limites["exposicao"].map { TextosDaCameraRemota.limite($0, TextosDaCameraRemota.nomes(do: "exposicao", c) ?? []) }
                ?? linhaDoGrupo ?? limite("exposicao")
        }

        var ev: DeslizanteRemoto?
        var linhaDoEv: String?
        if let d = tem("ev"), d.ehNumero {
            let brilho = d.unidade == "brilho"
            let degraus = NumerosDaCamera.degrausPorPasso(d, passoPadrao: brilho ? 1 : 0.1)
            let textos = degraus.map { v -> String in
                brilho ? "\(Int(((d.origem ?? 0) + v).rounded()))" : NumerosDaCamera.ev(v)
            }
            let livre = !manual && !travada
            ev = DeslizanteRemoto(campo: "ev", titulo: brilho ? T("Brilho") : T("Compensação (EV)"), degraus: degraus,
                                  indice: NumerosDaCamera.indice(de: a.ev ?? 0, em: degraus), textos: textos,
                                  disponivel: vivo && livre, linha: nil, inteiro: d.inteiro)
            if travada && !manual { ev?.linha = TextosDaCameraRemota.destraveParaCompensar }
        } else {
            linhaDoEv = limite("ev")
        }

        var travaExposicao: InterruptorRemoto?
        if tem("travaExposicao") != nil {
            travaExposicao = InterruptorRemoto(campo: "travaExposicao", titulo: TextosDosAjustes.travarExposicao,
                                               ligado: travada, disponivel: vivo && !manual, linha: nil)
        } else {
            travaExposicao = InterruptorRemoto(campo: "travaExposicao", titulo: TextosDosAjustes.travarExposicao,
                                               ligado: false, disponivel: false, linha: limite("travaExposicao"))
        }

        let antiCintilacao = opcoes("antiCintilacao", [(T("Auto"), "auto"), ("50 Hz", "50"), ("60 Hz", "60"),
                                                        (T("Desligada"), "desligada")],
                                    escolhida: a.antiCintilacao ?? "auto")
        let linhaDaAntiCintilacao = tem("antiCintilacao") == nil ? limite("antiCintilacao") : nil

        // ISO e obturador
        var iso: DeslizanteRemoto?
        var linhaDoIso: String?
        if let d = tem("iso"), d.ehNumero {
            let degraus = NumerosDaCamera.degrausDoIso(d)
            let ganho = d.unidade == "ganho"
            let textos = degraus.map { ganho ? "\(Int($0.rounded()))" : NumerosDaCamera.iso($0) }
            var s = DeslizanteRemoto(campo: "iso", titulo: ganho ? T("Ganho") : "ISO", degraus: degraus,
                                     indice: NumerosDaCamera.indice(de: a.iso, em: degraus), textos: textos,
                                     disponivel: vivo && manual, linha: nil, inteiro: d.inteiro || !ganho)
            if let analogico = d.analogicoMax, let v = a.iso, v > analogico { s.linha = T("ganho digital") }
            iso = s
        } else if !semIsoNemObturador {
            linhaDoIso = limite("iso")
        }
        var obturador: DeslizanteRemoto?
        var linhaDoObturador: String?
        if let d = tem("obturadorNs"), d.ehNumero {
            let degraus = NumerosDaCamera.degrausDoObturador(d)
            let textos = degraus.map { d.escala == "log2" ? NumerosDaCamera.obturadorLog2(ns: $0) : NumerosDaCamera.obturador(ns: $0) }
            obturador = DeslizanteRemoto(campo: "obturadorNs", titulo: T("Obturador"), degraus: degraus,
                                         indice: NumerosDaCamera.indice(de: a.obturadorNs, em: degraus), textos: textos,
                                         disponivel: vivo && manual, linha: nil, inteiro: true)
        } else if !semIsoNemObturador {
            linhaDoObturador = limite("obturadorNs")
        }

        // Balanço: a grade 2 × 3 (R9 §4.2).
        let balanco = opcoes("balanco", OpcaoDeBalanco.allCases.map { ($0.nome, PlanoRemotoDoPainel.valor(do: $0)) },
                             escolhida: a.balancoEfetivo)
        var limitesDoBalanco: [String] = []
        let valoresDoBalanco = tem("balanco")?.valores ?? []
        let presets = ["incandescente", "fluorescente", "luzDoDia", "nublado"]
        if !presets.contains(where: valoresDoBalanco.contains) {
            // Sem preset nenhum: o motivo do `balanco`, ou (o Mac, que só diz o do Kelvin) o mesmo do Kelvin.
            let codigo = c.limites["balanco"] ?? (tem("kelvin") == nil ? c.limites["kelvin"] : nil) ?? ""
            limitesDoBalanco.append(TextosDaCameraRemota.limite(codigo, [.presetsDeBalanco]))
        }
        if !valoresDoBalanco.contains("kelvin") || tem("kelvin") == nil {
            limitesDoBalanco.append(limite("kelvin"))
        }
        var kelvin: DeslizanteRemoto?
        if a.balancoEfetivo == "kelvin", let d = tem("kelvin"), d.ehNumero {
            let degraus = NumerosDaCamera.degrausPorPasso(d, passoPadrao: 100)
            kelvin = DeslizanteRemoto(campo: "kelvin", titulo: T("Kelvin"), degraus: degraus,
                                      indice: NumerosDaCamera.indice(de: a.kelvin, em: degraus),
                                      textos: degraus.map(NumerosDaCamera.kelvin), disponivel: vivo, linha: nil, inteiro: true)
        }
        var travaBalanco: InterruptorRemoto?
        // Com Kelvin a trava some (R9 §3.4); com um preset, fica apagada.
        if a.balancoEfetivo != "kelvin" {
            if tem("travaBalanco") != nil {
                travaBalanco = InterruptorRemoto(campo: "travaBalanco", titulo: TextosDosAjustes.travarBalanco,
                                                 ligado: a.travaBalanco ?? false,
                                                 disponivel: vivo && a.balancoEfetivo == "auto", linha: nil)
            } else {
                travaBalanco = InterruptorRemoto(campo: "travaBalanco", titulo: TextosDosAjustes.travarBalanco,
                                                 ligado: false, disponivel: false, linha: limite("travaBalanco"))
            }
        }

        // Foco
        var linhaDoFocoFixo: String?
        var foco: [OpcaoRemota] = []
        var limitesDoFoco: [String] = []
        var focoPosicao: DeslizanteRemoto?
        if tem("foco") == nil, c.limites["foco"] == "foco_fixo" {
            linhaDoFocoFixo = TextoDoLimite.focoFixo
        } else {
            foco = opcoes("foco", [(T("Auto"), "auto"), (T("Travado"), "travado"), (T("Manual"), "manual")],
                          escolhida: a.focoEfetivo)
            if tem("foco") == nil { limitesDoFoco.append(limite("foco")) }
            if let d = tem("focoPosicao"), d.ehNumero {
                if a.focoEfetivo == "manual" {
                    let degraus = NumerosDaCamera.degrausPorPasso(d, passoPadrao: 0.01)
                    focoPosicao = DeslizanteRemoto(campo: "focoPosicao", titulo: T("Perto ↔ Longe"), degraus: degraus,
                                                   indice: NumerosDaCamera.indice(de: a.focoPosicao, em: degraus),
                                                   textos: degraus.map { NumerosDaCamera.comVirgula($0, casas: 2) },
                                                   disponivel: vivo, linha: nil, inteiro: false)
                }
            } else {
                limitesDoFoco.append(limite("focoPosicao"))
            }
        }

        var aviso: String?
        if !vivo {
            aviso = TextosDaCameraRemota.naoPermitido
        } else if let r = e.recusa {
            aviso = TextosDaCameraRemota.recusa(r.motivo, campo: r.campo, c)
        }

        return PlanoRemotoDoPainel(
            nome: c.nomeDaCamera.isEmpty ? TextosDosAjustes.titulo : c.nomeDaCamera,
            vivo: vivo, aviso: aviso, lido: e.lido.flatMap { PlanoRemotoDoPainel.linhaDoLido($0, c) },
            divergencias: e.lido.map { PlanoRemotoDoPainel.divergencias($0, a, c) } ?? [],
            exposicao: exposicao, linhaDaExposicao: linhaDaExposicao, ev: ev, linhaDoEv: linhaDoEv,
            travaExposicao: travaExposicao, antiCintilacao: antiCintilacao, linhaDaAntiCintilacao: linhaDaAntiCintilacao,
            tituloDaAbaDoIso: unidadeDoIso == "ganho" ? T("Ganho e obturador") : AbaDosAjustes.isoEObturador.nome,
            linhaDoIsoEObturador: linhaDoGrupo, passeParaManual: !semIsoNemObturador && !manual,
            iso: iso, linhaDoIso: linhaDoIso, obturador: obturador, linhaDoObturador: linhaDoObturador,
            balanco: balanco, limitesDoBalanco: limitesDoBalanco, kelvin: kelvin, travaBalanco: travaBalanco,
            linhaDoFocoFixo: linhaDoFocoFixo, foco: foco, limitesDoFoco: limitesDoFoco, focoPosicao: focoPosicao,
            toqueDisponivel: vivo && tem("toque") != nil,
            notaDoToque: tem("toque") != nil ? TextosDosAjustes.notaDoToque : limite("toque"))
    }

    /// O valor do registro (`luzDoDia`) de uma opção da grade.
    public static func valor(do o: OpcaoDeBalanco) -> String {
        switch o {
        case .auto: return "auto"
        case .incandescente: return "incandescente"
        case .fluorescente: return "fluorescente"
        case .luzDoDia: return "luzDoDia"
        case .nublado: return "nublado"
        case .kelvin: return "kelvin"
        }
    }

    /// `ISO 400 · 1/60 s · 5200 K · f/1,7`: só o que o filmador lê. No Windows, "Ganho 64" (a `unidade`).
    public static func linhaDoLido(_ l: LidoRemoto, _ c: CapacidadesRemotas? = nil) -> String? {
        var partes: [String] = []
        if let v = l.iso {
            partes.append(c?.controles["iso"]?.unidade == "ganho" ? T("Ganho") + " \(Int(v.rounded()))" : NumerosDaCamera.iso(v))
        }
        if let v = l.obturadorNs { partes.append(NumerosDaCamera.obturador(ns: v)) }
        if let v = l.kelvin { partes.append(NumerosDaCamera.kelvin(v)) }
        if let v = l.abertura { partes.append(NumerosDaCamera.abertura(v)) }
        return partes.isEmpty ? nil : partes.joined(separator: " · ")
    }

    /// "A câmera usou {lido} em vez de {pedido}." para os campos que o filmador diz divergirem (a regra dos
    /// 2 s é dele; aqui só se mostra).
    public static func divergencias(_ l: LidoRemoto, _ a: AjusteRemoto, _ c: CapacidadesRemotas) -> [String] {
        l.divergentes.compactMap { campo -> String? in
            switch campo {
            case "iso":
                guard let lido = l.iso, let pedido = a.iso else { return nil }
                return T("A câmera usou %@ em vez de %@.", NumerosDaCamera.iso(lido), NumerosDaCamera.iso(pedido))
            case "obturadorNs":
                guard let lido = l.obturadorNs, let pedido = a.obturadorNs else { return nil }
                return T("A câmera usou %@ em vez de %@.", NumerosDaCamera.obturador(ns: lido), NumerosDaCamera.obturador(ns: pedido))
            case "kelvin":
                guard let lido = l.kelvin, let pedido = a.kelvin else { return nil }
                return T("A câmera usou %@ em vez de %@.", NumerosDaCamera.kelvin(lido), NumerosDaCamera.kelvin(pedido))
            case "focoPosicao":
                guard let lido = l.focoPosicao, let pedido = a.focoPosicao else { return nil }
                return T("A câmera usou %@ em vez de %@.", NumerosDaCamera.comVirgula(lido, casas: 2),
                         NumerosDaCamera.comVirgula(pedido, casas: 2))
            default:
                return nil
            }
        }
    }
}

/// **O pedido parcial** que a tela do receptor manda (`quall_camera_remote_request`): só os campos mexidos,
/// com o número inteiro sem `.0` onde o descritor diz `"inteiro":true`.
public enum PedidoDoReceptor {
    public static func json(_ campos: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(campos),
              let d = try? JSONSerialization.data(withJSONObject: campos, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// O valor de um deslizante no pedido: `Int` quando inteiro (o Android trunca `800.7`, §3.2).
    public static func valor(_ d: DeslizanteRemoto, indice: Int) -> Any {
        let v = d.valor(indice)
        return d.inteiro ? Int(v) as Any : v as Any
    }
}

/// **O clique na imagem do receptor → o ponto no quadro decodificado** (contrato §3.4): a camada mostra o
/// vídeo inteiro com tarja (`resizeAspect`), sem espelho. O clique e o quadro com a origem no alto à
/// esquerda. Um clique na tarja é `nil` (não se manda).
public enum PontoNoQuadro {
    public static func doClique(_ p: CGPoint, vista: CGSize, video: CGSize) -> CGPoint? {
        guard vista.width > 0, vista.height > 0, video.width > 0, video.height > 0 else { return nil }
        let escala = min(vista.width / video.width, vista.height / video.height)
        let l = video.width * escala, a = video.height * escala
        let x0 = (vista.width - l) / 2, y0 = (vista.height - a) / 2
        let x = (p.x - x0) / l, y = (p.y - y0) / a
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
