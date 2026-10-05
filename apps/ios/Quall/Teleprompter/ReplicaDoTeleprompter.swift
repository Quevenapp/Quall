import CryptoKit
import Foundation
import os

/// O diário do teleprompter: `os_log` (o que `idevicesyslog -m quall-tp` lê) e `print`.
///
/// Etiqueta própria, e não a `[quall-rx]` do receptor: a bancada filtra por ela, e misturar as duas
/// faria uma corrida de vídeo e uma de teleprompter no mesmo aparelho parecerem uma só. **Não entra
/// endereço de ninguém nem texto do roteiro** — só contadores e estados. A saída é sanitizada
/// igualmente em Debug e Release; resumos do roteiro também são removidos.
enum DiarioDoTeleprompter {
    private static let log = OSLog(subsystem: "br.com.queven.quall", category: "teleprompter")

    static func dizer(_ texto: String) {
        let linha = "[quall-tp] " + SanitizacaoDoLog.mensagem(texto)
        os_log("%{public}@", log: log, type: .default, linha)
        print(linha)
        fflush(stdout)
    }
}

/// O estado para a tela, lido de `quall_teleprompter_state_json` — os nomes são os literais do
/// contrato (§6), e é por isso que as chaves estão em português e com `_`.
struct EstadoDoTeleprompter: Decodable, Equatable {
    var rolando = false
    var velocidade = 1.0
    var fonte = 48.0
    var margem = 0.1
    var linhaDeLeitura = 0.3
    var espelho = false
    var posicao = 0.0
    var salto: Double?
    /// "Segurar para rolar" (`docs/contrato-teleprompter.md` §12): com `rolando`, para trás.
    var paraTras = false
    /// O dedo no botão do controle (§12).
    var segurando = false
    /// O outro lado disse, no último estado dele, que entende o segurar (§12.2): só então o controle
    /// segura.
    var parEntendeSegurar = false
    var textoBytes = 0
    /// `nil`: o outro lado não mandou nada nesta sessão (ou a sessão caiu).
    var parVistoHaMs: UInt64?
    /// `nil`: toda edição daqui já apareceu no estado do outro lado. **Com o texto retido** pela
    /// pergunta (§11.3), o texto sai dessa conta: nulo não quer dizer que ele chegou.
    var semConfirmacaoHaMs: UInt64?
    var contadores = Contadores()
    /// "A pergunta do texto" (§11.6): `nil` sem nada retido.
    var perguntaDoTexto: PerguntaDoTexto?
    /// As cópias do que saiu (§11.5), a mais nova primeiro. Até três.
    var copiasDoTexto: [CopiaDoTexto] = []
    /// A gravação (§13.7): há quanto tempo o prompter grava; `nil` parado.
    var gravandoHaMs: UInt64?
    /// No prompter, o pedido do controle que a tela decide; no controle, o daqui sem resposta.
    var pedidoDeGravacao: PedidoDeGravacao?
    /// A última recusa (no prompter, a que ele deu; no controle, a do último pedido daqui).
    var gravacaoRecusada: RecusaDeGravacao?
    /// O prompter diz que grava (§13.5): só então o controle mostra o botão.
    var parEntendeGravar = false

    struct PedidoDeGravacao: Decodable, Equatable {
        var n: UInt64
        var gravar: Bool
        var haMs: UInt64
        enum CodingKeys: String, CodingKey { case n, gravar, haMs = "ha_ms" }
    }

    struct RecusaDeGravacao: Decodable, Equatable {
        var n: UInt64
        var gravar: Bool
        var motivo: String
    }

    struct Contadores: Decodable, Equatable {
        var estadosEnviados: UInt64 = 0
        var textosEnviados: UInt64 = 0
        var recebidas: UInt64 = 0
        var invalidas: UInt64 = 0
        var deOutroApp: UInt64 = 0
        var deOutraVersao: UInt64 = 0
        var camposRecusados: UInt64 = 0
        var carimbosDoFuturo: UInt64 = 0
        var mensagensImpossiveis: UInt64 = 0
        var reenviosDesistidos: UInt64 = 0

        init() {}

        enum CodingKeys: String, CodingKey {
            case estadosEnviados = "estados_enviados", textosEnviados = "textos_enviados"
            case recebidas, invalidas
            case deOutroApp = "de_outro_app", deOutraVersao = "de_outra_versao"
            case camposRecusados = "campos_recusados", carimbosDoFuturo = "carimbos_do_futuro"
            case mensagensImpossiveis = "mensagens_impossiveis"
            case reenviosDesistidos = "reenvios_desistidos"
        }

        /// Campo a campo e tolerante: um contador novo no núcleo, ou um que falte, não pode
        /// derrubar a leitura do estado inteiro — o mesmo princípio do fio (§3).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func ler(_ k: CodingKeys) -> UInt64 { (try? c.decodeIfPresent(UInt64.self, forKey: k)) ?? 0 }
            estadosEnviados = ler(.estadosEnviados); textosEnviados = ler(.textosEnviados)
            recebidas = ler(.recebidas); invalidas = ler(.invalidas)
            deOutroApp = ler(.deOutroApp); deOutraVersao = ler(.deOutraVersao)
            camposRecusados = ler(.camposRecusados); carimbosDoFuturo = ler(.carimbosDoFuturo)
            mensagensImpossiveis = ler(.mensagensImpossiveis)
            reenviosDesistidos = ler(.reenviosDesistidos)
        }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case rolando, velocidade, fonte, margem, espelho, posicao, salto, contadores
        case linhaDeLeitura = "linha_de_leitura"
        case paraTras = "para_tras"
        case segurando
        case parEntendeSegurar = "par_entende_segurar"
        case textoBytes = "texto_bytes"
        case parVistoHaMs = "par_visto_ha_ms"
        case semConfirmacaoHaMs = "sem_confirmacao_ha_ms"
        case perguntaDoTexto = "pergunta_do_texto"
        case copiasDoTexto = "copias_do_texto"
        case gravandoHaMs = "gravando_ha_ms"
        case pedidoDeGravacao = "pedido_de_gravacao"
        case gravacaoRecusada = "gravacao_recusada"
        case parEntendeGravar = "par_entende_gravar"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rolando = try c.decode(Bool.self, forKey: .rolando)
        velocidade = try c.decode(Double.self, forKey: .velocidade)
        fonte = try c.decode(Double.self, forKey: .fonte)
        margem = try c.decode(Double.self, forKey: .margem)
        linhaDeLeitura = try c.decode(Double.self, forKey: .linhaDeLeitura)
        espelho = try c.decode(Bool.self, forKey: .espelho)
        posicao = try c.decode(Double.self, forKey: .posicao)
        salto = try c.decodeIfPresent(Double.self, forKey: .salto)
        // Aditivos (§12.1): um núcleo que não os tem não derruba a leitura.
        paraTras = (try? c.decodeIfPresent(Bool.self, forKey: .paraTras)) ?? false
        segurando = (try? c.decodeIfPresent(Bool.self, forKey: .segurando)) ?? false
        parEntendeSegurar = (try? c.decodeIfPresent(Bool.self, forKey: .parEntendeSegurar)) ?? false
        textoBytes = (try? c.decodeIfPresent(Int.self, forKey: .textoBytes)) ?? 0
        parVistoHaMs = try? c.decodeIfPresent(UInt64.self, forKey: .parVistoHaMs)
        semConfirmacaoHaMs = try? c.decodeIfPresent(UInt64.self, forKey: .semConfirmacaoHaMs)
        contadores = (try? c.decodeIfPresent(Contadores.self, forKey: .contadores)) ?? Contadores()
        // Aditivos (§11.6).
        perguntaDoTexto = (try? c.decodeIfPresent(PerguntaDoTexto.self, forKey: .perguntaDoTexto)) ?? nil
        copiasDoTexto = (try? c.decodeIfPresent([CopiaDoTexto].self, forKey: .copiasDoTexto)) ?? []
        // Aditivos (§13.7).
        gravandoHaMs = (try? c.decodeIfPresent(UInt64.self, forKey: .gravandoHaMs)) ?? nil
        pedidoDeGravacao = (try? c.decodeIfPresent(PedidoDeGravacao.self, forKey: .pedidoDeGravacao)) ?? nil
        gravacaoRecusada = (try? c.decodeIfPresent(RecusaDeGravacao.self, forKey: .gravacaoRecusada)) ?? nil
        parEntendeGravar = (try? c.decodeIfPresent(Bool.self, forKey: .parEntendeGravar)) ?? false
    }
}

/// **A réplica deste aparelho**, sobre `QuallTeleprompter` da fronteira C.
///
/// Uma por tela de teleprompter (a do prompter ou a do controle), com o papel dela, e **a mesma**
/// passada a cada sessão nova enquanto a tela vive (`docs/contrato-teleprompter.md` §3, "Uma réplica
/// por aparelho, que vive mais que a sessão"). O papel é fixado na criação e decide o que acontece
/// com `rolando`, `posicao` e `salto` quando uma sessão nova começa.
///
/// # Threads
///
/// As edições (`set_*`, `jump`, `jump_by`) vêm da thread da interface e **saem na hora** — o núcleo
/// guarda o mensageiro da última bombeada e manda dali. A bombeada vem da thread da sessão. A
/// fronteira põe o cadeado; aqui não há trava nenhuma, e nenhuma é precisa.
///
/// # A liberação
///
/// `quall_teleprompter_free` só no `deinit`, e o `deinit` só acontece quando **ninguém** segura esta
/// classe: a tela a segura pelo modelo, e a thread da sessão a segura enquanto o laço dela existe.
/// O header exige que a réplica não esteja em uso noutra thread ao ser liberada; a contagem de
/// referência do Swift é o que garante isso.
final class ReplicaDoTeleprompter {
    enum Papel: String {
        case teleprompter = "teleprompter"
        case controleRemoto = "controle_remoto"
    }

    let papel: Papel
    private let t: OpaquePointer

    /// `nil` só se o núcleo recusar até a réplica sem salvo — autor vazio ou maior que 256 bytes,
    /// que o `device_id` do App Group nunca é.
    init?(papel: Papel, autor: String, salvo: String?) {
        self.papel = papel
        var criada: OpaquePointer?
        if let salvo, !salvo.isEmpty {
            criada = autor.withCString { a in
                papel.rawValue.withCString { p in salvo.withCString { s in quall_teleprompter_new(a, p, s) } }
            }
            if criada == nil {
                // Salvo ilegível ou de outra versão: o contrato manda chamar de novo com nulo
                // (§3, Persistência). O salvo ruim é esquecido no próximo `salvar()`.
                DiarioDoTeleprompter.dizer("salvo recusado (\(SanitizacaoDoLog.causaExterna(ReplicaDoTeleprompter.ultimoErro()))); "
                    + "começando do padrão")
            }
        }
        if criada == nil {
            criada = autor.withCString { a in
                papel.rawValue.withCString { p in quall_teleprompter_new(a, p, nil) }
            }
        }
        guard let criada else { return nil }
        t = criada
    }

    deinit { quall_teleprompter_free(t) }

    static func ultimoErro() -> String {
        guard let p = quall_last_error() else { return "" }
        return String(cString: p)
    }

    static var tetoDoTexto: Int { Int(quall_teleprompter_max_text_bytes()) }

    // --- edições ------------------------------------------------------------------------------

    /// **Ao confirmar a edição, nunca a cada tecla** (§6). Um NUL no meio seria cortado em silêncio
    /// pela ponte do Swift para C — e o contrato manda recusar texto com NUL —, então a recusa é
    /// aqui, antes da ponte.
    @discardableResult
    func definirTexto(_ texto: String) -> QuallStatus {
        if texto.utf8.contains(0) { return QUALL_STATUS_INVALID }
        return texto.withCString { quall_teleprompter_set_text(t, $0) }
    }
    @discardableResult func definirRolando(_ v: Bool) -> QuallStatus { quall_teleprompter_set_scrolling(t, v) }
    @discardableResult func definirVelocidade(_ v: Double) -> QuallStatus { quall_teleprompter_set_speed(t, v) }
    @discardableResult func definirFonte(_ v: Double) -> QuallStatus { quall_teleprompter_set_font_size(t, v) }
    @discardableResult func definirMargem(_ v: Double) -> QuallStatus { quall_teleprompter_set_margin(t, v) }
    @discardableResult func definirLinhaDeLeitura(_ v: Double) -> QuallStatus { quall_teleprompter_set_reading_line(t, v) }
    @discardableResult func definirEspelho(_ v: Bool) -> QuallStatus { quall_teleprompter_set_mirror(t, v) }
    /// Só o prompter. Pode ser chamada a cada quadro: o núcleo limita o envio a 4 Hz.
    @discardableResult func definirPosicao(_ v: Double) -> QuallStatus { quall_teleprompter_set_position(t, v) }
    @discardableResult func saltar(_ v: Double) -> QuallStatus { quall_teleprompter_jump(t, v) }
    @discardableResult func pular(_ delta: Double) -> QuallStatus { quall_teleprompter_jump_by(t, delta) }

    // --- "Segurar para rolar" (§12) ------------------------------------------------------------

    /// **A tela do prompter diz que entende o segurar**: rola para trás com `para_tras` e para quando
    /// `rolando` cai. Só a tela que faz isso chama (`VistaDoRoteiro`).
    @discardableResult func habilitarSegurar() -> QuallStatus { quall_teleprompter_enable_hold(t) }
    /// O dedo no botão: `rolando`, `para_tras` e `segurando` numa mensagem. `PROTOCOL`: o prompter
    /// não entende; `CLOSED`: sem sessão.
    @discardableResult func segurar(paraTras: Bool) -> QuallStatus { quall_teleprompter_hold(t, paraTras) }
    /// O dedo saiu: o texto para. Sem nada seguro, não faz nada.
    @discardableResult func soltar() -> QuallStatus { quall_teleprompter_release(t) }

    // --- A gravação (§13) ------------------------------------------------------------------------

    /// **Só a tela do prompter que grava** (a do teleprompter com câmera): liga ao abrir e desliga ao
    /// fechar. Ligada, o estado diz `"entende_gravar": true`, e só então um controle pede.
    @discardableResult func ligarGravacao(_ ligada: Bool) -> QuallStatus { quall_teleprompter_enable_recording(t, ligada) }
    /// **Só o prompter**: o arquivo começou (`true`) ou fechou (`false`). Aceitar um pedido do
    /// controle é chamar isto com o `gravar` dele, mesmo que já esteja assim. `INVALID` no controle.
    @discardableResult func definirGravando(_ gravando: Bool) -> QuallStatus { quall_teleprompter_set_recording(t, gravando) }
    /// **Só o prompter**: recusa o pedido aberto `n` (o `"n"` de `"pedido_de_gravacao"` que a tela
    /// leu) com um motivo legível (1 a 256 bytes). `BUSY`: outro pedido o substituiu — releia e decida.
    /// `INVALID` sem pedido aberto ou com motivo vazio, longo demais ou com NUL.
    @discardableResult
    func recusarGravacao(n: UInt64, motivo: String) -> QuallStatus {
        if motivo.utf8.contains(0) { return QUALL_STATUS_INVALID }
        return motivo.withCString { quall_teleprompter_refuse_recording(t, n, $0) }
    }
    /// **O controle pede que grave.** `PROTOCOL`: o prompter não diz que grava; `CLOSED`: sem sessão.
    @discardableResult func pedirGravar() -> QuallStatus { quall_teleprompter_request_record(t) }
    /// **O controle pede que pare.** As mesmas regras de `pedirGravar`.
    @discardableResult func pedirParar() -> QuallStatus { quall_teleprompter_request_stop(t) }

    // --- "A pergunta do texto" (§11) -----------------------------------------------------------

    /// **A trava** (§11.10): só a tela que tem a caixa da pergunta liga, logo depois de criar a
    /// réplica do controle, a cada vida. Não vai no salvo. No prompter, não muda nada.
    @discardableResult func ligarPerguntaDoTexto() -> QuallStatus { quall_teleprompter_enable_text_question(t) }

    /// A escolha: `manterOMeu` falso é "Usar o do prompter"; verdadeiro, "Mandar o meu". `resumoVisto`
    /// é o `"resumo"` de `"do_prompter"` **que a caixa mostrou**. `OK`; `BUSY` (mudou); `CLOSED` (sem
    /// o prompter); `INVALID` (sem pergunta aberta).
    @discardableResult
    func resolverTexto(manterOMeu: Bool, resumoVisto: String) -> QuallStatus {
        resumoVisto.withCString { quall_teleprompter_resolve_text(t, manterOMeu, $0) }
    }

    /// O texto **do prompter** na pergunta aberta, ou `nil`.
    func textoDaPergunta() -> String? {
        ReplicaDoTeleprompter.lerAteCaber({ quall_teleprompter_question_text(t, $0, $1) })
    }

    /// O texto inteiro de uma cópia, pelo resumo, ou `nil` se ela não está mais na lista.
    func copiaDoTexto(resumo: String) -> String? {
        resumo.withCString { r in ReplicaDoTeleprompter.lerAteCaber({ quall_teleprompter_text_copy(t, r, $0, $1) }) }
    }

    /// Apaga uma cópia. `INVALID`: ela não está mais na lista.
    @discardableResult
    func esquecerCopia(resumo: String) -> QuallStatus {
        resumo.withCString { quall_teleprompter_forget_text_copy(t, $0) }
    }

    // --- sessão ------------------------------------------------------------------------------

    /// A bombeada. **Só da thread da sessão.** `QUALL_STATUS_CLOSED` vem **com** `changed`
    /// preenchido: aplique antes de qualquer outra coisa (§6).
    func bombear(_ m: OpaquePointer, prazoMs: UInt32) -> (status: QuallStatus, mudou: UInt32) {
        var mudou: UInt32 = 0
        let st = quall_teleprompter_pump(t, m, prazoMs, &mudou)
        return (st, mudou)
    }

    /// O outro lado sumiu. Sempre traz `QUALL_TELEPROMPTER_CHANGE_PEER`.
    func perdeuOPar() -> UInt32 {
        var mudou: UInt32 = 0
        _ = quall_teleprompter_peer_lost(t, &mudou)
        return mudou
    }

    // --- leitura -----------------------------------------------------------------------------

    func estado() -> EstadoDoTeleprompter? {
        guard let json = ReplicaDoTeleprompter.lerAteCaber({ quall_teleprompter_state_json(t, $0, $1) }),
              let dados = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(EstadoDoTeleprompter.self, from: dados)
    }

    func texto() -> String {
        ReplicaDoTeleprompter.lerAteCaber({ quall_teleprompter_text(t, $0, $1) }) ?? ""
    }

    func salvoJson() -> String? {
        ReplicaDoTeleprompter.lerAteCaber({ quall_teleprompter_saved_json(t, $0, $1) })
    }

    /// **O padrão `(buf, cap)`, repetido até caber** (§6). O conteúdo pode crescer entre a chamada
    /// que pergunta e a que escreve — medido no próprio teste da fronteira: o estado passou de 357
    /// para 360 bytes porque `par_visto_ha_ms` ganhou um dígito; e o texto pode mudar no meio por
    /// uma edição que chegou. Devolvido maior que `cap` quer dizer "não escrevi": aloca o novo
    /// tamanho e chama de novo. Oito voltas é teto contra laço, não expectativa.
    static func lerAteCaber(_ chamar: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String? {
        var precisa = chamar(nil, 0)
        var voltas = 0
        while precisa > 0, voltas < 8 {
            voltas += 1
            var buffer = [CChar](repeating: 0, count: precisa)
            let n = buffer.withUnsafeMutableBufferPointer { p in chamar(p.baseAddress, UInt(p.count)) }
            if n <= 0 { return nil }
            if n <= precisa {
                // `n` inclui o NUL.
                return buffer.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: n) {
                        String(decoding: UnsafeBufferPointer(start: $0, count: n - 1), as: UTF8.self)
                    }
                }
            }
            precisa = n
        }
        return nil
    }

    // --- persistência ------------------------------------------------------------------------

    /// Onde o salvo mora: `Application Support` do app, **um arquivo por papel**. Não é o App
    /// Group: a appex não tem o que fazer com um roteiro, e o salvo chega a ~260 KiB.
    ///
    /// # Por que um por papel (achado da revisão adversarial de 13/09, item 4)
    ///
    /// Com um arquivo só, o roteiro que este iPhone mostrava **como prompter** iria junto quando
    /// ele passasse a **controlar** outro aparelho — e, sendo mais novo pelo carimbo, substituiria o
    /// roteiro do outro lado inteiro, sem editor aberto e sem aviso. Separados, cada papel carrega o
    /// que era dele. O caso que sobra (o controle que ontem controlou o prompter A e hoje conecta no
    /// B com um roteiro mais velho) é da regra "vale o último que mudou" do contrato (§3) e está
    /// relatado como pergunta, não decidido aqui.
    private static func arquivo(_ papel: Papel) -> URL? {
        guard let pasta = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return pasta.appendingPathComponent(papel == .teleprompter ? "teleprompter-prompter.json"
                                                                   : "teleprompter-controle.json")
    }

    /// O salvo da vida anterior deste papel, ou `nil`.
    static func lerSalvo(papel: Papel) -> String? {
        guard let url = arquivo(papel), let dados = try? Data(contentsOf: url) else { return nil }
        let texto = String(decoding: dados, as: UTF8.self)
        return texto.isEmpty ? nil : texto
    }

    /// Guarda o salvo (ao ir para o segundo plano, ao fechar cada sessão, ao sair da tela e ao
    /// confirmar um texto). Falha em silêncio de propósito: disco cheio não pode derrubar a tela.
    func salvar(motivo: String) {
        guard let url = ReplicaDoTeleprompter.arquivo(papel), let json = salvoJson() else { return }
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            DiarioDoTeleprompter.dizer("salvo gravado (\(json.utf8.count) bytes, \(motivo))")
        } catch {
            DiarioDoTeleprompter.dizer("!! salvo não gravado (\(motivo)): \(SanitizacaoDoLog.erro(error))")
        }
    }
}

/// O resumo que o fio usa para o texto (`teleprompter::resumo`, §4): os primeiros 8 bytes do
/// SHA-256, em hex. Só para o diário: é o que deixa comparar, pelo log, o texto de dois aparelhos
/// sem pôr o roteiro no log.
enum ResumoDoTexto {
    static func de(_ texto: String) -> String {
        let h = SHA256.hash(data: Data(texto.utf8))
        return h.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
