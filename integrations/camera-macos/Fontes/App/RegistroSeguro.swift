import Foundation

/// Só o canal de diagnóstico: não muda dados, pareamento nem o texto das APIs do núcleo.
/// Segredos nunca ganham uma opção de log detalhado. As causas externas viram categorias;
/// métricas JSON só saem como números de campos explicitamente autorizados.
enum RegistroSeguro {
    private static let regras: [(NSRegularExpression, String)] = [
        (#"\{[\s\S]*\}"#, "[objeto omitido]"),
        (#"\{[\s\S]*$"#, "[objeto incompleto omitido]"),
        (#"\[\s*\"[\s\S]*(?:\]|$)"#, "[lista de dados omitida]"),
        (#"-----BEGIN[\s\S]*?(?:-----END[^\n]*-----|$)"#, "[credencial omitida]"),
        (#"(?i)\b(pin|password|senha|passphrase|psk|secret|token|pwd|ufrag|nonce|mac|ice[_-]?pwd|ice[_-]?ufrag|public[_-]?key|private[_-]?key|session[_-]?key|shared[_-]?key|auth[_-]?key|pairing[_-]?key)\b[\"']?\s*(?:[:=]\s*|\s+)(?:\"(?:\\.|[^\"])*\"|[^,;\n]*?(?=\s+[a-z_][a-z0-9_.]*=|[,;\n]|$))"#, "$1=[omitido]"),
        (#"(?i)\b(nome|name|uid|device[_-]?id|display[_-]?name|signing[_-]?id)[\"']?\s*[:=]\s*.*?(?=\s+[a-z_][a-z0-9_]*=|[,;\n]|$)"#, "$1=[omitido]"),
        (#"(?i)\b[a-z][a-z0-9+.-]*://[^\s]+"#, "[URL omitida]"),
        (#"(?<![A-Za-z0-9_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?(?![A-Za-z0-9_.])"#, "[endereço omitido]"),
        (#"(?i)(?<![a-z0-9_])\[?[0-9a-f]*:[0-9a-f:.]*:[0-9a-f:.]*(?:%[a-z0-9._-]+)?\]?(?::[0-9]{1,5})?(?![a-z0-9_])"#, "[endereço omitido]"),
        (#"(?:file://)?/(?:Users|Volumes|private|tmp|var|home|Library|Applications)/[^,;\n]*"#, "[caminho omitido]"),
        (#"[\x00-\x1f\x7f]"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func texto(_ mensagem: String) -> String {
        var segura = mensagem
        for (regra, substituicao) in regras {
            segura = regra.stringByReplacingMatches(in: segura, range: NSRange(segura.startIndex..., in: segura),
                                                    withTemplate: substituicao)
        }
        return segura
    }

    static func motivo(_ mensagem: String) -> String {
        let m = mensagem.lowercased()
        if ["permission", "permiss", "operation not permitted"].contains(where: m.contains) {
            return "permissão recusada; contexto omitido"
        }
        if ["timeout", "timed out", "prazo"].contains(where: m.contains) {
            return "prazo esgotado; contexto omitido"
        }
        if ["pin", "auth", "autentic", "pareamento", "pairing", "secret", "chave"].contains(where: m.contains) {
            return "autenticação/pareamento recusado; contexto omitido"
        }
        if ["socket", "connect", "conex", "network", "rede", "refused"].contains(where: m.contains) {
            return "falha de conexão/rede; contexto omitido"
        }
        if ["invalid", "inválid", "json"].contains(where: m.contains) {
            return "dados inválidos; contexto omitido"
        }
        return "falha externa; contexto omitido"
    }

    static func erro(_ erro: Error) -> String {
        let ns = erro as NSError
        let dominios = ["NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain",
                        "AVFoundationErrorDomain", "OSSystemExtensionErrorDomain", "CMIOExtensionErrorDomain"]
        let dominio = dominios.contains(ns.domain) ? ns.domain : "NSError"
        var resultado = "domínio=\(dominio) código=\(ns.code)"
        if let sub = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            let causa = dominios.contains(sub.domain) ? sub.domain : "NSError"
            resultado += "; causa domínio=\(causa) código=\(sub.code)"
        }
        return resultado
    }

    private static func motivoDoRelogio(_ mensagem: String) -> String {
        switch mensagem {
        case "o estado do relógio da sessão foi envenenado": return "estado envenenado"
        case "track desconhecida do relógio da sessão": return "track desconhecida"
        case "a taxa do relógio RTP desta track não divide 720 000 Hz": return "taxa não suportada"
        default:
            if mensagem.hasPrefix("a track ") { return "referência recusada por outra track" }
            if mensagem.hasPrefix("o relógio desta track e o da referência se separaram:") { return "guarda recusada" }
            return "causa desconhecida; contexto omitido"
        }
    }

    static func pares(_ texto: String?) -> String {
        guard let texto else { return "pareamentos: arquivo ausente/ilegível" }
        guard let dados = texto.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados) else {
            return "pareamentos: arquivo presente; estrutura inválida; conteúdo omitido"
        }
        let quantidade: Int?
        if let lista = objeto as? [Any] { quantidade = lista.count }
        else if let mapa = objeto as? [String: Any], let lista = mapa["pares"] as? [Any] { quantidade = lista.count }
        else if let mapa = objeto as? [String: Any], let pares = mapa["pares"] as? [String: Any] { quantidade = pares.count }
        else if let mapa = objeto as? [String: Any], let lista = mapa["peers"] as? [Any] { quantidade = lista.count }
        else { quantidade = nil }
        let contagem = quantidade.map { " contagem=\($0);" } ?? ""
        return "pareamentos: arquivo presente;\(contagem) conteúdo omitido"
    }

    private static let camposNumericos: Set<String> = [
        "frames_ready", "frames_dropped", "idrs_ready", "idrs_broken", "idrs_without_parameters", "frames_sent", "idrs_sent",
        "largest_frame_ready_packets", "largest_broken_frame_packets_received", "sequence_anomalies",
        "packets_missing_upper_bound", "reorder_events", "reorderings_absorbed", "reorder_giveups", "reorder_depth",
        "reorder_adjusts", "packets_seen", "packets_lost_for_real", "packets_too_late", "rtcp_ignored", "idr_requests",
        "jitter_us", "buffered_bytes", "reference", "capture_offset_us", "residual_us", "window_residual_us",
        "inter_track_drift_ppm", "guard_violations", "slots", "frames", "holes", "fec_offers", "silences", "too_late",
        "duplicates", "reordered", "resyncs", "max_occupancy", "max_delay_us",
    ]

    static func metricas(_ json: String) -> String {
        guard let dados = json.data(using: .utf8),
              let mapa = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else {
            return "métricas indisponíveis: JSON inválido"
        }
        var campos: [String] = []
        func adicionar(_ objeto: [String: Any], prefixo: String = "") {
            for chave in objeto.keys.sorted() {
                guard let valor = objeto[chave] else { continue }
                if ["clock", "jitter_buffer"].contains(chave), prefixo.isEmpty {
                    if let grupo = valor as? [String: Any] { adicionar(grupo, prefixo: chave + ".") }
                    else if valor is NSNull { campos.append("\(chave)=indisponível") }
                } else if camposNumericos.contains(chave) {
                    if let numero = valor as? NSNumber { campos.append("\(prefixo)\(chave)=\(numero.stringValue)") }
                    else if valor is NSNull { campos.append("\(prefixo)\(chave)=indisponível") }
                } else if chave == "status", prefixo == "clock.", let estado = valor as? String,
                          ["pending", "valid", "refused"].contains(estado) {
                    campos.append("clock.status=\(estado)")
                } else if chave == "reason", prefixo == "clock." {
                    if let causa = valor as? String { campos.append("clock.reason=\(motivoDoRelogio(causa))") }
                    else if valor is NSNull { campos.append("clock.reason=indisponível") }
                }
            }
        }
        adicionar(mapa)
        return campos.isEmpty ? "métricas indisponíveis: nenhum campo autorizado" : campos.joined(separator: " ")
    }
}
