import CoreGraphics
import Foundation

// **O controle remoto da câmera, no Mac que filma** (R9b, `docs/controle-remoto-da-camera.md`): a parte
// pura. As capacidades que o filmador anuncia (§3.2) e o pedido que o núcleo entrega à casca (§6), lido e
// aplicado sobre o registro do R9 na ordem do contrato. Nada aqui toca em `AVCaptureDevice` nem na
// fronteira C: quem aplica na câmera é o `DonoDaCamera`, quem fala com o núcleo é o app. Testado em
// `TestesDaCameraRemota`, sem câmera e sem rede.

extension CapacidadesDaCamera {
    /// Os campos que o macOS não oferece para câmeras (R9 §1), com o código `macos` em `limites`: o literal
    /// do exemplo do contrato §3.2.
    public static let camposQueOMacNaoOferece = ["ev", "iso", "obturadorNs", "kelvin", "antiCintilacao", "focoPosicao"]

    /// **As capacidades do contrato §3.2**, do mesmo cálculo que monta o painel do Mac (`PlanoDoPainel.doMac`):
    /// só as travas e o ponto, e `limites` com `macos` no resto.
    ///
    /// - a trava que a câmera não aceita (`isXModeSupported(.locked)` falso) sai de `controles` e entra em
    ///   `limites` com `camera_nao_oferece` — a mesma frase que o painel local mostra;
    /// - foco fixo: `foco` sai, com `foco_fixo`; o foco que não trava, com `camera_nao_oferece`;
    /// - o ponto (`toque`) onde a câmera mede ou foca num ponto.
    ///
    /// O JSON sai com as chaves em ordem (o diário fica estável) e cabe folgado nos 2.048 bytes do teto.
    public func jsonRemoto(nomeDaCamera: String) -> String {
        var controles: [String: Any] = [:]
        var limites: [String: String] = [:]
        for campo in CapacidadesDaCamera.camposQueOMacNaoOferece { limites[campo] = "macos" }
        if podeTravarExposicao { controles["travaExposicao"] = [String: Any]() } else { limites["travaExposicao"] = "camera_nao_oferece" }
        if podeTravarBalanco { controles["travaBalanco"] = [String: Any]() } else { limites["travaBalanco"] = "camera_nao_oferece" }
        if podeTravarFoco {
            controles["foco"] = ["valores": ["auto", "travado"]]
        } else {
            limites["foco"] = focoFixo ? "foco_fixo" : "camera_nao_oferece"
        }
        if podeMedirNoPonto || podeFocarNoPonto { controles["toque"] = [String: Any]() } else { limites["toque"] = "camera_nao_oferece" }
        let tudo: [String: Any] = [
            "plataforma": "macos",
            "nomeDaCamera": CapacidadesDaCamera.cortar(nomeDaCamera, bytes: 64),
            "controles": controles,
            "limites": limites,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: tudo, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{\"controles\":{}}" }
        return s
    }

    /// Corta em `bytes` de UTF-8 numa fronteira de caractere (o teto do nome no contrato, §3.2).
    static func cortar(_ s: String, bytes: Int) -> String {
        var r = ""
        var n = 0
        for c in s {
            let t = String(c).utf8.count
            if n + t > bytes { break }
            r.append(c)
            n += t
        }
        return r
    }
}

/// **Um pedido aceito pelo núcleo**, como `quall_camera_host_next_request` o entrega (contrato §6):
///
/// ```json
/// {"n":5,"autor":"OBS no Dell","autor_id":"dell-7f2a","ajuste":{"travaExposicao":true},
///  "restaurar":false,"toque":null}
/// ```
///
/// O núcleo já validou cada campo contra as capacidades que o Mac publicou; a casca confere de novo o que
/// é dela (o campo que ela não sabe aplicar, a trava que a câmera deixou de aceitar).
public struct PedidoDaCameraRemota: Equatable, Sendable {
    public struct Toque: Equatable, Sendable {
        public var x: Double
        public var y: Double
        /// O toque longo: no Mac, o ⌥-clique (trava ali).
        public var longo: Bool
    }

    public var n: UInt64
    public var autor: String
    public var restaurar: Bool
    public var toque: Toque?
    /// Os campos do ajuste que o Mac conhece, já tipados.
    public var travaExposicao: Bool?
    public var travaBalanco: Bool?
    public var foco: AjustesDaCamera.Foco?
    /// Os campos que o Mac não sabe aplicar (ou com valor que ele não lê), pelo nome.
    public var naoAplicaveis: [String]

    public init(n: UInt64, autor: String = "", restaurar: Bool = false, toque: Toque? = nil,
                travaExposicao: Bool? = nil, travaBalanco: Bool? = nil, foco: AjustesDaCamera.Foco? = nil,
                naoAplicaveis: [String] = []) {
        self.n = n
        self.autor = autor
        self.restaurar = restaurar
        self.toque = toque
        self.travaExposicao = travaExposicao
        self.travaBalanco = travaBalanco
        self.foco = foco
        self.naoAplicaveis = naoAplicaveis
    }

    /// Lê o JSON do núcleo. `nil` quando nem é um pedido (sem `n`).
    public static func ler(_ json: String) -> PedidoDaCameraRemota? {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let n = (o["n"] as? NSNumber)?.uint64Value, n > 0 else { return nil }
        var p = PedidoDaCameraRemota(n: n)
        p.autor = o["autor"] as? String ?? ""
        p.restaurar = (o["restaurar"] as? Bool) ?? false
        if let t = o["toque"] as? [String: Any], let x = (t["x"] as? NSNumber)?.doubleValue,
           let y = (t["y"] as? NSNumber)?.doubleValue {
            p.toque = Toque(x: x, y: y, longo: (t["longo"] as? Bool) ?? false)
        }
        for (campo, valor) in (o["ajuste"] as? [String: Any]) ?? [:] {
            switch campo {
            case "travaExposicao":
                if let b = PedidoDaCameraRemota.simNao(valor) { p.travaExposicao = b } else { p.naoAplicaveis.append(campo) }
            case "travaBalanco":
                if let b = PedidoDaCameraRemota.simNao(valor) { p.travaBalanco = b } else { p.naoAplicaveis.append(campo) }
            case "foco":
                if let f = (valor as? String).flatMap(AjustesDaCamera.Foco.init(rawValue:)) { p.foco = f } else { p.naoAplicaveis.append(campo) }
            default:
                p.naoAplicaveis.append(campo)
            }
        }
        p.naoAplicaveis.sort()
        return p
    }

    /// `true`/`false` do JSON, e não o `1`/`0` que o `NSNumber` também aceitaria como booleano.
    private static func simNao(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// **O que aplicar**, ou por que não.
    public enum Resultado: Equatable, Sendable {
        /// O registro novo; `clique` é a decisão do toque (o mesmo do clique na prévia do R9 §4.4), quando
        /// houve toque; `pontoAoCentro` quando o pedido restaurou (o ponto volta ao centro, como no painel).
        case aplicar(AjustesDaCamera, clique: DecisaoDoClique?, ponto: CGPoint?, pontoAoCentro: Bool)
        /// O código da recusa (`[a-z0-9_]`, contrato §3.5).
        case recusar(String)
    }

    /// **Aplica o pedido sobre o registro**, na ordem do contrato §6: `restaurar` → o modo (`foco`) → as
    /// travas → o `toque`. Puro.
    ///
    /// - O Mac não tem modo de exposição nem de balanço (só `auto`), nem valores (§1): o ajuste dele são as
    ///   duas travas e o foco travado.
    /// - O ponto do toque vem **no quadro decodificado** (§3.4). No Mac ele é o ponto do sensor: a saída da
    ///   câmera nunca espelha (`DonoDaCamera.montar`), não gira e não é recortada no caminho até a rede.
    /// - `pilulaAcesa`: a pílula do ⌥-clique está na tela (um toque simples depois dela desfaz as travas
    ///   dela, como na prévia).
    public func aplicar(sobre atual: AjustesDaCamera, _ c: CapacidadesDaCamera, pilulaAcesa: Bool) -> Resultado {
        guard naoAplicaveis.isEmpty else { return .recusar("campo_desconhecido") }
        var a = restaurar ? AjustesDaCamera.padrao : atual
        if let foco { a.foco = foco }
        if let travaExposicao { a.travaExposicao = travaExposicao }
        if let travaBalanco { a.travaBalanco = travaBalanco }
        // As capacidades mudaram entre o núcleo aceitar e a casca aplicar (a mesma câmera não muda; isto é
        // a guarda): o que a câmera não faz não entra calado.
        if a.cortado(por: c) != a { return .recusar("nao_aplicado") }
        guard let toque else {
            return .aplicar(a, clique: nil, ponto: nil, pontoAoCentro: restaurar)
        }
        guard (0...1).contains(toque.x), (0...1).contains(toque.y) else { return .recusar("fora_da_imagem") }
        let d = DecisaoDoClique.decidir(a, c, travarAli: toque.longo, pilulaAcesa: pilulaAcesa && !restaurar)
        let ponto = CGPoint(x: toque.x, y: toque.y)
        return .aplicar(d.quadrado ? d.ajustes : a, clique: d, ponto: ponto, pontoAoCentro: restaurar)
    }
}
