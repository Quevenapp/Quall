import Foundation
import QuallNetKit

/// Quem este Mac é na rede, e de quem ele já se lembra.
///
/// Duas coisas moram aqui, e elas têm tempos de vida diferentes:
///
/// - **`deviceId`** — identificador estável, gerado na primeira execução e persistido. É o que o
///   pareamento vincula, *não* o nome: a pessoa pode renomear o Mac em Ajustes e o pareamento
///   tem de sobreviver a isso. Um `deviceId` novo a cada abertura faria todo par salvo virar lixo
///   e o PIN ser pedido para sempre — que é exatamente o defeito que o pareamento existe para
///   evitar.
/// - **`pares.json`** — o estado de pareamento, opaco para a casca. Quem o produz e o consome é o
///   núcleo; aqui ele só é lido, fundido e gravado.
///
/// # Um escritor, e mesmo assim funde
///
/// No iOS há dois escritores (o app e a broadcast extension) e a dívida 23 cobra uma trava entre
/// processos. Aqui há **um** — o app é um processo só, e captura e rede convivem nele. Mesmo
/// assim a gravação passa por `quall_known_peers_merge`, por duas razões: duas janelas do mesmo
/// app abertas por engano deixam de ser catástrofe, e o dia em que o plugin de OBS ou a câmera
/// virtual escreverem no mesmo arquivo não vai depender de alguém lembrar de trocar o caminho de
/// gravação.
enum Identidade {
    private static let fila = DispatchQueue(label: "quall.identidade")

    static var pasta: URL {
        if let daBancada = pastaDaBancada { return daBancada }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let nossa = base.appendingPathComponent("Quall", isDirectory: true)
        try? FileManager.default.createDirectory(at: nossa, withIntermediateDirectories: true)
        return nossa
    }

    /// `--dados=DIR`: a pasta da bancada, no lugar da do usuário. Lida uma vez. **Caminho absoluto**
    /// (sob `open` o diretório atual é `/`, e o `~` depois de `=` não é expandido pelo shell) e
    /// gravável — senão é ignorada, e o registro diz por quê, em vez de a identidade mudar a cada
    /// leitura por não conseguir se gravar.
    static let pastaDaBancada: URL? = {
        guard let pedido = Argumentos.lidos().dados else { return nil }
        let caminho = (pedido as NSString).expandingTildeInPath
        guard caminho.hasPrefix("/") else {
            avisarNoRegistro("!! --dados não é caminho absoluto — usando a pasta de sempre")
            return nil
        }
        let url = URL(fileURLWithPath: caminho, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            avisarNoRegistro("!! --dados não é gravável — usando a pasta de sempre")
            return nil
        }
        return url
    }()

    private static var arquivoDoAparelho: URL { pasta.appendingPathComponent("aparelho.json") }
    private static var arquivoDePares: URL { pasta.appendingPathComponent("pares.json") }

    private struct Registro: Codable {
        var deviceId: String
    }

    /// Gerado uma vez, guardado para sempre — e **lembrado em memória** depois da primeira leitura:
    /// numa pasta que não aceita a gravação, cada leitura inventaria um id novo, e o pareamento, que
    /// é por `device_id`, quebraria no meio da sessão.
    static var deviceId: String {
        fila.sync {
            if let lembrado = idEmMemoria { return lembrado }
            if let dados = try? Data(contentsOf: arquivoDoAparelho),
               let registro = try? JSONDecoder().decode(Registro.self, from: dados),
               !registro.deviceId.isEmpty {
                idEmMemoria = registro.deviceId
                return registro.deviceId
            }
            let novo = "mac-" + UUID().uuidString.lowercased()
            if let dados = try? JSONEncoder().encode(Registro(deviceId: novo)) {
                try? dados.write(to: arquivoDoAparelho, options: .atomic)
            }
            idEmMemoria = novo
            return novo
        }
    }
    /// Só tocado dentro de `fila`.
    private static var idEmMemoria: String?

    /// O nome com que este Mac aparece na rede. É o nome que a pessoa já reconhece — o mesmo que
    /// o Finder e o AirDrop mostram —, não um apelido inventado por nós: o valor da tela de
    /// espera está em a pessoa conseguir apontar para o próprio aparelho na lista do outro.
    static var nomeDoAparelho: String {
        let doSistema = Host.current().localizedName ?? ""
        if !doSistema.isEmpty { return doSistema }
        let hostname = ProcessInfo.processInfo.hostName
        return hostname.isEmpty ? "Mac" : hostname
    }

    // MARK: - pareamento

    static func paresConhecidos() -> String {
        fila.sync {
            (try? String(contentsOf: arquivoDePares, encoding: .utf8)) ?? ""
        }
    }

    /// Verdadeiro quando este Mac conhece **algum** par.
    ///
    /// É este valor, e nenhum outro, que decide a manchete da tela de espera. Ele diz "conheço
    /// algum par", **nunca** "reconheço quem está chegando agora" — a casca não sabe isso antes
    /// de alguém tentar. E é publicado uma vez por sessão, não lido do disco a cada redesenho:
    /// ler arquivo dentro do corpo de uma view é caro e, pior, pode mudar de valor no meio de uma
    /// composição.
    static func haParesConhecidos() -> Bool {
        let texto = paresConhecidos()
        guard !texto.isEmpty else { return false }
        // O formato é do núcleo e opaco para a casca. O que dá para afirmar sem interpretá-lo é
        // que uma tabela vazia não tem par nenhum — qualquer coisa além disso é "tem algo".
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(limpo.isEmpty || limpo == "{}" || limpo == "[]" || limpo == "null")
    }

    /// Grava fundindo com o que já está em disco. Ver o comentário de tipo.
    static func guardarPares(_ novos: String) {
        guard !novos.isEmpty else { return }
        fila.sync {
            let emDisco = (try? String(contentsOf: arquivoDePares, encoding: .utf8)) ?? ""
            let fundido = emDisco.isEmpty ? novos : NucleoDeRede.fundirPares(emDisco, novos)
            let paraGravar = fundido.isEmpty ? novos : fundido
            try? paraGravar.write(to: arquivoDePares, atomically: true, encoding: .utf8)
        }
    }

    /// Joga fora **todos** os pares. É a saída do beco sem saída da dívida 22 — "funcionou ontem,
    /// hoje não funciona" — e por isso ela só é oferecida na interface quando a retomada de fato
    /// falhou, nunca como um botão permanente: convidar a pessoa a apagar o pareamento o tempo
    /// todo é convidá-la a jogar fora justamente o que faz o PIN ser pedido uma vez só.
    static func esquecerTodosOsPares() {
        fila.sync {
            try? FileManager.default.removeItem(at: arquivoDePares)
        }
    }
}

/// O registro do app, visto de fora de `Identidade` — dentro dela, `Registro` é o formato do
/// `aparelho.json`.
private func avisarNoRegistro(_ linha: String) {
    Registro.compartilhado.linha(linha)
}
