import Foundation

/// A perda, em uma linha, com os **três** números que ela precisa para não mentir.
///
/// Até 29/08/2026 o único número de perda que qualquer casca desta casa mostrava era
/// `packets_missing` — que **nunca foi perda**. Ele é a soma dos saltos de sequência, e uma
/// reordenação de distância `d` entra ali como `1 + d` posições sem que nada tenha se perdido.
/// Numa corrida com 486 nele, o emissor tinha entregado 27.779 pacotes e o receptor visto 27.729:
/// sumiram **cinquenta**. O erro medido vai de 1,3× a 44×, e ele contaminou os laudos da bancada.
///
/// O núcleo publica agora `packets_lost_for_real` (janela de reordenação de 128 posições) e
/// `packets_too_late` (que denuncia quando a própria janela foi curta demais). Esta enum existe
/// para que os três apareçam **juntos**, sempre, e nenhum deles possa ser lido sozinho:
///
/// ```
/// perda exata 50 (0,180%) · teto 486 (1,720%) · tarde demais 0 · vistos 27729
/// ```
///
/// # Duas cópias, e é de propósito
///
/// A mesma função existe em `apps/ios/Receptor/Comum/ResumoDePerda.swift` e em
/// `apps/android/.../receive/ResumoDePerda.kt`. Não há módulo Swift compartilhado entre o
/// receptor iOS e o app de câmera do macOS — eles são dois projetos XcodeGen independentes —, e
/// inventar um por causa de quarenta linhas custaria mais do que resolve. O que amarra as três é
/// o formato da linha, que é o mesmo texto, e a fonte dos números, que é o mesmo JSON da
/// fronteira C.
enum ResumoDePerda {

    /// Formata a linha a partir do JSON de `quall_track_stats_json`.
    ///
    /// Nunca lança: um JSON ilegível vira uma frase que diz que não deu para ler, porque um
    /// resumo de perda que some do relatório é pior que um que se declara ausente.
    static func formatar(_ json: String) -> String {
        guard let dados = json.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados),
              let d = objeto as? [String: Any]
        else { return "perda: contadores do núcleo ilegíveis" }
        return de(d)
    }

    /// A mesma linha, a partir do dicionário já desserializado.
    ///
    /// Chave ausente sai como `?` — **nunca como zero**. Um `0` diria "medi e não perdi nada", que
    /// é a afirmação mais perigosa que este relatório pode fazer por engano; foi para não fazê-la
    /// que a chave antiga não ganhou alias no núcleo.
    static func de(_ d: [String: Any]) -> String {
        let exata = inteiro(d, "packets_lost_for_real")
        let teto = inteiro(d, "packets_missing_upper_bound")
        let tarde = inteiro(d, "packets_too_late")
        let vistos = inteiro(d, "packets_seen")

        if vistos == 0 {
            return "perda: nenhum pacote chegou ainda (packets_seen=0) — nada a afirmar"
        }

        var s = "perda exata \(numero(exata))\(taxa(exata, vistos))"
        s += " · teto \(numero(teto))\(taxa(teto, vistos))"
        s += " · tarde demais \(numero(tarde))"
        s += " · vistos \(numero(vistos))"
        // A janela de reordenação tem 128 posições. Um pacote que chega depois de a posição dele
        // já ter saído dela é uma posição cobrada como perda que não era: quando isto passa de
        // zero, a perda exata está superestimada nesse tanto, e a leitura precisa dizer isso.
        if let t = tarde, t > 0 {
            s += " — JANELA CURTA: a perda exata está superestimada em até \(t)"
        }
        return s
    }

    private static func inteiro(_ d: [String: Any], _ chave: String) -> Int64? {
        (d[chave] as? NSNumber)?.int64Value
    }

    private static func numero(_ v: Int64?) -> String {
        guard let v else { return "?" }
        return String(v)
    }

    /// `(0,180%)` sobre a janela observada, ou nada quando falta um dos dois números.
    private static func taxa(_ v: Int64?, _ vistos: Int64?) -> String {
        guard let v, let vistos, vistos > 0 else { return "" }
        let denominador = Double(v) + Double(vistos)
        guard denominador > 0 else { return "" }
        return String(format: " (%.3f%%)", 100.0 * Double(v) / denominador)
    }
}
