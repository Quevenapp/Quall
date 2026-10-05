import Foundation
import os

/// Relógio monotônico, pegada de memória e o canal de observação da bancada.
///
/// O relógio é `CLOCK_UPTIME_RAW` e não `Date()`: um ajuste de horário no meio de uma corrida de
/// 40 s produziria latência negativa, que num `UInt64` vira um número gigante e é exatamente a
/// família de defeito que derrubou a corrida de 464 s do degrau 4. Aqui **não há subtração de
/// inteiro sem sinal** sem guarda em lugar nenhum.
enum Medidas {
    static func agoraUs() -> UInt64 {
        var t = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &t)
        return UInt64(t.tv_sec) &* 1_000_000 &+ UInt64(t.tv_nsec) / 1_000
    }

    /// `a - b` que nunca estoura. Devolve 0 quando `b` é maior, em vez de 18 quintilhões.
    static func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

    /// `phys_footprint` — o número que o jetsam olha, e o mesmo que o degrau 4 mediu na appex.
    static func pegadaDeMemoria() -> String {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let estado = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &contagem)
            }
        }
        guard estado == KERN_SUCCESS else { return "?" }
        return String(format: "%.2f MB", Double(info.phys_footprint) / 1_048_576)
    }

    /// Percentis de uma amostra já coletada. Devolve zeros para amostra vazia — nunca `nil` e
    /// nunca um número inventado, porque "não medi" e "medi zero" precisam ser distinguíveis pelo
    /// `n` que sai junto.
    static func percentis(_ amostra: [UInt64]) -> (n: Int, p50: UInt64, p95: UInt64, max: UInt64) {
        guard !amostra.isEmpty else { return (0, 0, 0, 0) }
        let o = amostra.sorted()
        return (o.count, o[o.count / 2], o[min(o.count - 1, Int(Double(o.count) * 0.95))], o[o.count - 1])
    }
}

/// Saída da corrida.
///
/// Vai para **dois** canais de propósito. `os_log` é o que `idevicesyslog` lê e é o único canal
/// que sobrevive quando o app é aberto pela pessoa, sem nada anexado. `print` é o que
/// `devicectl device process launch --console` mostra, e é ele que torna possível uma corrida sem
/// toque nenhum — que é a pergunta desta frente.
enum Diario {
    // O subsistema é o do app unificado; era `…quall.receptor`, bundle que deixou de existir.
    // **A etiqueta `[quall-rx]` da mensagem não muda**, e isso é deliberado: `provar-receptor.sh`
    // filtra o syslog por ela (`idevicesyslog -m quall-rx`), que é o filtro **com alvo** que esta
    // bancada exige. Trocar a etiqueta junto com o subsistema faria a corrida parecer vazia
    // enquanto o app trabalhava — e o roteiro reprovaria um build bom.
    private static let log = OSLog(subsystem: "br.com.queven.quall", category: "receptor")

    /// A etiqueta `[quall-rx]` vai nos **dois** canais, e é a mesma nos dois de propósito: o
    /// roteiro de prova filtra por ela, e uma etiqueta só no `print` faria a corrida observada por
    /// `idevicesyslog` parecer vazia enquanto o app trabalhava.
    static func dizer(_ texto: String) {
        let linha = "[quall-rx] " + SanitizacaoDoLog.mensagem(texto)
        os_log("%{public}@", log: log, type: .default, linha)
        print(linha)
        fflush(stdout)
    }

    // ============================================================================================
    // O terceiro canal: um arquivo que **sobrevive à sessão**
    // ============================================================================================
    //
    // Os dois canais acima são fluxo ao vivo. `os_log` sai por `idevicesyslog`, que é uma torneira
    // aberta, não um histórico; `print` só existe enquanto `devicectl … --console` estiver
    // segurando o processo. **Quem não estava com o cabo na mão quando a sessão rodou não tem como
    // buscar o que aconteceu.**
    //
    // Isso não é hipótese. Em 31/08/2026 o orquestrador pediu os contadores da sessão iOS → iPad
    // que o usuário rodou à mão e que ficou limpa, e ela era **irrecuperável**: sem `sysdiagnose`
    // — que traz o aparelho inteiro do usuário junto e não é proporcional — não havia de onde
    // tirar. A frase *"aparentemente não houve falha visual"* virou a base de uma célula da
    // matriz sem um número por trás.
    //
    // Toda sessão que o usuário roda à mão era, até aqui, **inmensurável depois do fato**. É a
    // mesma família do defeito que esta rodada conserta — a bancada tem instrumento e não tem
    // registro — e é a peça mais barata que fecha o pedido: não adianta a medida existir se ela
    // morre quando a sessão termina.
    //
    // **O que entra no arquivo é contador, e só.** As linhas arquivadas são as de relato — nomes
    // de contador e números —, nunca o endereço do outro lado, nunca nome de par, nunca um byte de
    // imagem ou de som. Um arquivo de relato que carregasse a rede do usuário seria a mesma
    // troca ruim que `docs/regras-de-frente.md` já pagou duas vezes.

    /// Onde o relato desta sessão mora. `Documents` do contêiner do app — é o que
    /// `devicectl device copy from --domain-type appDataContainer` sabe puxar sem `sysdiagnose`.
    private static let arquivoDoRelato: URL? = {
        guard let pasta = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return pasta.appendingPathComponent("relato-\(f.string(from: Date())).txt")
    }()

    private static let travaDoArquivo = NSLock()
    private static var abriuOArquivo = false

    /// Guarda uma linha de **contadores** no arquivo desta sessão, além dos dois canais ao vivo.
    ///
    /// Chamada só de `relatar`: quem decide o que é contador é quem monta a linha, não esta
    /// função. Falha em silêncio de propósito — um aparelho sem espaço não pode derrubar a
    /// sessão de espelhamento por causa do diário dela.
    static func arquivar(_ linha: String) {
        guard let url = arquivoDoRelato else { return }
        travaDoArquivo.lock()
        defer { travaDoArquivo.unlock() }
        guard let dados = (SanitizacaoDoLog.mensagem(linha) + "\n").data(using: .utf8) else { return }
        if !abriuOArquivo {
            // A primeira linha nomeia o que virá depois: sem cabeçalho, um arquivo de trinta
            // campos por linha é ilegível para quem o abrir daqui a um mês.
            let cabecalho = "# quall receptor iOS — contadores da sessão, sem endereço e sem mídia\n"
            try? (cabecalho.data(using: .utf8)! + dados).write(to: url, options: .atomic)
            abriuOArquivo = true
            dizer("relato desta sessão arquivado em Documents")
            return
        }
        guard let punho = try? FileHandle(forWritingTo: url) else { return }
        defer { try? punho.close() }
        _ = try? punho.seekToEnd()
        try? punho.write(contentsOf: dados)
    }
}
