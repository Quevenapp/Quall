import CQuall
import Foundation
import QuallTeleprompterKit

/// **A ponte do teleprompter com a fronteira C** (`docs/contrato-teleprompter.md` §6 e §7).
///
/// Três peças, com donos diferentes:
///
/// - [`ReplicaDoTeleprompter`] embrulha o `QuallTeleprompter*`. Vive o tempo da tela, e as edições
///   (`set_*`, `jump`, `jump_by`) saem dela **de qualquer thread** — a interface as chama direto da
///   main, e o núcleo manda na hora pelo mensageiro da última bombeada.
/// - [`FronteiraDoTeleprompter`] é a dona **exclusiva** da `QuallSession*` e do `QuallMessages*`:
///   só a thread do laço (`LacoDoTeleprompter`) chama os métodos dela. A interface tem um caminho só
///   para interferir — [`FronteiraDoTeleprompter/pedirParada()`] —, que levanta a bandeira e aciona o
///   cancelador da espera bloqueada, e **nunca** toca em ponteiro de sessão. É o conserto, por
///   construção, do precedente de `NucleoReceptor.swift:239-247`.
/// - [`NavegadorDePrompters`] é dono do `QuallBrowser*` numa thread própria.
public enum PonteDoTeleprompter {

    /// `QuallStatus` → `StatusDaFronteira`, caso a caso e **sem `default` silencioso**.
    public static func status(_ s: QuallStatus) -> StatusDaFronteira {
        switch s {
        case QUALL_STATUS_OK: return .ok
        case QUALL_STATUS_INVALID: return .invalido
        case QUALL_STATUS_PROTOCOL: return .protocolo
        case QUALL_STATUS_DISCOVERY: return .descoberta
        case QUALL_STATUS_SIGNALING: return .sinalizacao
        case QUALL_STATUS_TRANSPORT: return .transporte
        case QUALL_STATUS_PAIRING: return .pareamento
        case QUALL_STATUS_TIMEOUT: return .prazo
        case QUALL_STATUS_CLOSED: return .fechado
        case QUALL_STATUS_IO: return .io
        case QUALL_STATUS_NULL_POINTER: return .ponteiroNulo
        case QUALL_STATUS_NOT_UTF8: return .naoUTF8
        case QUALL_STATUS_NO_ROUTE: return .semRota
        case QUALL_STATUS_NEEDS_PIN: return .precisaDePin
        case QUALL_STATUS_CANCELLED: return .cancelado
        case QUALL_STATUS_WRONG_PIN: return .pinErrado
        case QUALL_STATUS_BUSY: return .ocupado
        default: return .outro(Int32(bitPattern: s.rawValue))
        }
    }

    /// Os bits de `changed`, traduzidos **pelas constantes do `quall.h`** — não pela tabela do kit:
    /// se um dia os dois divergirem, o bit some do lado de cá em vez de acender o errado.
    public static func mudancas(_ bits: UInt32) -> MudancasDoTeleprompter {
        var m: MudancasDoTeleprompter = []
        let tabela: [(QuallTeleprompterChange, MudancasDoTeleprompter)] = [
            (QUALL_TELEPROMPTER_CHANGE_TEXT, .texto),
            (QUALL_TELEPROMPTER_CHANGE_SCROLLING, .rolando),
            (QUALL_TELEPROMPTER_CHANGE_SPEED, .velocidade),
            (QUALL_TELEPROMPTER_CHANGE_FONT_SIZE, .fonte),
            (QUALL_TELEPROMPTER_CHANGE_MARGIN, .margem),
            (QUALL_TELEPROMPTER_CHANGE_READING_LINE, .linhaDeLeitura),
            (QUALL_TELEPROMPTER_CHANGE_MIRROR, .espelho),
            (QUALL_TELEPROMPTER_CHANGE_POSITION, .posicao),
            (QUALL_TELEPROMPTER_CHANGE_JUMP, .salto),
            (QUALL_TELEPROMPTER_CHANGE_PEER, .par),
            (QUALL_TELEPROMPTER_CHANGE_TEXT_QUESTION, .perguntaDoTexto),
            (QUALL_TELEPROMPTER_CHANGE_TEXT_COPY, .copiaDoTexto),
            (QUALL_TELEPROMPTER_CHANGE_HOLD, .segurar),
            (QUALL_TELEPROMPTER_CHANGE_RECORDING, .gravacao),
        ]
        var restantes = bits
        for (c, s) in tabela where bits & c.rawValue != 0 {
            m.insert(s)
            restantes &= ~c.rawValue
        }
        // Um bit que o `quall.h` desta build não conhece passa adiante cru: o registro o mostra
        // como `desconhecido(n)` em vez de ele sumir.
        if restantes != 0 { m.insert(MudancasDoTeleprompter(rawValue: restantes)) }
        return m
    }

    /// **O padrão `(buf, cap)` de `_state_json`, `_text` e `_saved_json`: repita até caber** (§6).
    ///
    /// Diferente de `NucleoDeRede.lerTexto`, que pergunta uma vez e escreve uma vez: aqui o
    /// conteúdo muda entre as duas chamadas — medido no próprio teste da fronteira, o estado passou
    /// de 357 para 360 bytes porque `par_visto_ha_ms` ganhou um dígito; e o texto pode ser trocado
    /// por uma bombeada na outra thread entre a pergunta e a escrita. Devolvido maior que `cap`
    /// quer dizer "não escrevi": aloca o tamanho novo e pergunta de novo. `nil` é erro (negativo).
    public static func lerAteCaber(_ chamada: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String? {
        var precisa = chamada(nil, 0)
        for _ in 0..<16 {
            guard precisa > 0 else { return nil }
            // Uma folga pequena: o estado cresce de um dígito em um dígito.
            let capacidade = precisa + 64
            var buffer = [CChar](repeating: 0, count: capacidade)
            let escritos = buffer.withUnsafeMutableBufferPointer { p in chamada(p.baseAddress, UInt(p.count)) }
            if escritos < 0 { return nil }
            if escritos > 0 && escritos <= capacidade { return String(cString: buffer) }
            precisa = escritos
        }
        return nil
    }

    public static var tetoDoTexto: Int { Int(quall_teleprompter_max_text_bytes()) }

    /// **A porta do prompter** (§11.1): a 7979, esperando por ela até `esperaMs` (2 000 é o
    /// recomendado); senão a primeira livre de 7980 a 7988; senão uma efêmera; `0` se nem isso.
    /// **Bloqueia** até `esperaMs`: chame fora da main. Uma vez por tela, ao abrir.
    public static func escolherPortaDoPrompter(esperaMs: UInt32) -> UInt16 {
        quall_teleprompter_pick_port(esperaMs)
    }

    /// A porta do teleprompter, 7979 (`quall_teleprompter_default_port`).
    public static var portaDoTeleprompter: UInt16 { quall_teleprompter_default_port() }

    public static func ultimoErro() -> String {
        guard let p = quall_last_error() else { return "" }
        return String(cString: p)
    }
}

// MARK: - a réplica

/// **A réplica deste aparelho** (`QuallTeleprompter*`): uma por tela aberta, com o papel dela, e a
/// mesma a cada sessão nova — ela atravessa as quedas e as reconexões (§3).
///
/// O ponteiro é imutável depois do `init` e só é liberado no `deinit`, quando ninguém mais segura a
/// réplica — a thread do laço segura uma referência forte enquanto roda, então "não estar em uso em
/// outra thread", que o `quall_teleprompter_free` exige, vale por contagem de referência.
public final class ReplicaDoTeleprompter: @unchecked Sendable {
    let ponteiro: OpaquePointer
    public let papel: PapelDoTeleprompter
    /// O salvo não passou (`QUALL_STATUS_INVALID`: ilegível ou de outra versão) e a réplica nasceu do
    /// padrão. O motivo, para o registro.
    public let salvoRecusado: String?

    public init?(autor: String, papel: PapelDoTeleprompter, salvo: String?) {
        self.papel = papel
        var recusado: String?
        var criado: OpaquePointer?
        autor.withCString { a in
            papel.rawValue.withCString { p in
                if let salvo, !salvo.isEmpty {
                    criado = salvo.withCString { s in quall_teleprompter_new(a, p, s) }
                    if criado == nil {
                        recusado = "\(PonteDoTeleprompter.status(quall_last_status()).nome): \(PonteDoTeleprompter.ultimoErro())"
                    }
                }
                if criado == nil { criado = quall_teleprompter_new(a, p, nil) }
            }
        }
        guard let criado else { return nil }
        ponteiro = criado
        salvoRecusado = recusado
    }

    deinit { quall_teleprompter_free(ponteiro) }

    private func st(_ s: QuallStatus) -> StatusDaFronteira { PonteDoTeleprompter.status(s) }

    /// **Só ao confirmar a edição, nunca a cada tecla** (§6).
    @discardableResult public func definirTexto(_ texto: String) -> StatusDaFronteira {
        texto.withCString { st(quall_teleprompter_set_text(ponteiro, $0)) }
    }
    @discardableResult public func definirRolando(_ v: Bool) -> StatusDaFronteira {
        st(quall_teleprompter_set_scrolling(ponteiro, v))
    }
    @discardableResult public func definirVelocidade(_ v: Double) -> StatusDaFronteira {
        st(quall_teleprompter_set_speed(ponteiro, v))
    }
    @discardableResult public func definirFonte(_ v: Double) -> StatusDaFronteira {
        st(quall_teleprompter_set_font_size(ponteiro, v))
    }
    @discardableResult public func definirMargem(_ v: Double) -> StatusDaFronteira {
        st(quall_teleprompter_set_margin(ponteiro, v))
    }
    @discardableResult public func definirLinhaDeLeitura(_ v: Double) -> StatusDaFronteira {
        st(quall_teleprompter_set_reading_line(ponteiro, v))
    }
    @discardableResult public func definirEspelho(_ v: Bool) -> StatusDaFronteira {
        st(quall_teleprompter_set_mirror(ponteiro, v))
    }
    /// **Só o prompter** (no controle é `INVALID`). Pode ser chamada a cada quadro: o núcleo limita.
    @discardableResult public func definirPosicao(_ v: Double) -> StatusDaFronteira {
        st(quall_teleprompter_set_position(ponteiro, v))
    }
    @discardableResult public func saltar(_ v: Double) -> StatusDaFronteira {
        st(quall_teleprompter_jump(ponteiro, v))
    }
    @discardableResult public func pular(_ delta: Double) -> StatusDaFronteira {
        st(quall_teleprompter_jump_by(ponteiro, delta))
    }

    /// **Só a tela do prompter que rola para trás e para quando `rolando` cai** (§12.2): o estado
    /// passa a dizer `"entende_segurar": true`, e só então um controle segura. No controle, nada.
    @discardableResult public func ligarSegurar() -> StatusDaFronteira {
        st(quall_teleprompter_enable_hold(ponteiro))
    }
    /// O aperto do "segurar para rolar" (§12.3): `PROTOCOL` sem o prompter entender, `CLOSED` sem
    /// sessão, `INVALID` numa réplica de prompter.
    @discardableResult public func segurar(paraTras: Bool) -> StatusDaFronteira {
        st(quall_teleprompter_hold(ponteiro, paraTras))
    }
    /// O soltar: o texto para. Sem nada seguro, não faz nada (nem pausa um play normal).
    @discardableResult public func soltar() -> StatusDaFronteira {
        st(quall_teleprompter_release(ponteiro))
    }

    // MARK: a gravação (§13)

    /// **Só a tela do prompter que grava** (a do teleprompter com câmera): liga ao abrir e desliga ao
    /// fechar. Ligada, o estado diz `"entende_gravar": true`, e só então um controle pede. No
    /// controle, nada.
    @discardableResult public func ligarGravacao(_ ligada: Bool) -> StatusDaFronteira {
        st(quall_teleprompter_enable_recording(ponteiro, ligada))
    }
    /// **Só o prompter**: o arquivo começou (`true`) ou fechou (`false`). Aceitar um pedido é chamar
    /// isto com o `gravar` dele, mesmo que já esteja assim. `INVALID` no controle.
    @discardableResult public func definirGravando(_ gravando: Bool) -> StatusDaFronteira {
        st(quall_teleprompter_set_recording(ponteiro, gravando))
    }
    /// **Só o prompter**: recusa o pedido aberto `n` (o `"n"` de `"pedido_de_gravacao"` que a tela
    /// leu) com um motivo legível (1 a 256 bytes). `ocupado`: outro pedido o substituiu — releia e
    /// decida. `INVALID` sem pedido aberto, com motivo vazio ou longo demais, ou no controle.
    @discardableResult public func recusarGravacao(n: UInt64, motivo: String) -> StatusDaFronteira {
        if motivo.utf8.contains(0) { return st(QUALL_STATUS_INVALID) }
        return motivo.withCString { st(quall_teleprompter_refuse_recording(ponteiro, n, $0)) }
    }
    /// **O controle pede que grave.** `PROTOCOL` sem o prompter dizer que grava, `CLOSED` sem
    /// sessão, `INVALID` numa réplica de prompter. A resposta volta pelo estado.
    @discardableResult public func pedirGravar() -> StatusDaFronteira {
        st(quall_teleprompter_request_record(ponteiro))
    }
    /// **O controle pede que pare.** As mesmas regras de `pedirGravar`.
    @discardableResult public func pedirParar() -> StatusDaFronteira {
        st(quall_teleprompter_request_stop(ponteiro))
    }

    // MARK: a pergunta do texto e as cópias (§11)

    /// **A trava** (§11.10): só na réplica do controle, logo depois de criá-la, e só numa build que
    /// tem a tela da pergunta. Não vai no salvo: liga-se a cada vida do app.
    @discardableResult public func ligarPerguntaDoTexto() -> StatusDaFronteira {
        st(quall_teleprompter_enable_text_question(ponteiro))
    }
    /// A escolha (§11.4): `manterOMeu` falso é "Usar o do prompter". `resumoVisto` é o `"resumo"` de
    /// `"do_prompter"` **que a caixa mostrou**. `OK` (grave o salvo), `INVALID` (sem pergunta aberta),
    /// `BUSY` (o roteiro do prompter mudou), `CLOSED` (o prompter não está conectado).
    @discardableResult public func resolverTexto(manterOMeu: Bool, resumoVisto: String) -> StatusDaFronteira {
        resumoVisto.withCString { st(quall_teleprompter_resolve_text(ponteiro, manterOMeu, $0)) }
    }
    /// O texto **do prompter** na pergunta aberta; `nil` sem pergunta aberta (inclusive comparando).
    public func textoDaPergunta() -> String? {
        PonteDoTeleprompter.lerAteCaber { quall_teleprompter_question_text(ponteiro, $0, $1) }
    }
    /// O texto inteiro de uma cópia, pelo resumo; `nil` se ela não está mais na lista.
    public func copiaDoTexto(resumo: String) -> String? {
        resumo.withCString { r in PonteDoTeleprompter.lerAteCaber { quall_teleprompter_text_copy(ponteiro, r, $0, $1) } }
    }
    /// Apaga uma cópia, pelo resumo. `INVALID` se não havia. Grave o salvo depois.
    @discardableResult public func esquecerCopiaDoTexto(resumo: String) -> StatusDaFronteira {
        resumo.withCString { st(quall_teleprompter_forget_text_copy(ponteiro, $0)) }
    }

    public func estadoJSON() -> String? {
        PonteDoTeleprompter.lerAteCaber { quall_teleprompter_state_json(ponteiro, $0, $1) }
    }
    public func estado() -> EstadoDoTeleprompter? { estadoJSON().flatMap(EstadoDoTeleprompter.doJSON) }
    public func texto() -> String? {
        PonteDoTeleprompter.lerAteCaber { quall_teleprompter_text(ponteiro, $0, $1) }
    }
    public func salvoJSON() -> String? {
        PonteDoTeleprompter.lerAteCaber { quall_teleprompter_saved_json(ponteiro, $0, $1) }
    }
}

// MARK: - a fronteira do laço

/// O que o laço sabe do outro lado depois que a sessão sobe.
public struct ParDoTeleprompter: Sendable, Equatable {
    public var nome: String
    public var deviceId: String
    public var papel: String?
    public var pareamentoNovo: Bool
}

/// **A implementação de verdade de `FronteiraDoLaco`.** Dona exclusiva da sessão: só a thread do
/// laço chama `abrir`, `bombear`, `proximoEvento`, `perdeuOPar` e `fechar`.
public final class FronteiraDoTeleprompter: FronteiraDoLaco, @unchecked Sendable {

    public struct Configuracao: Sendable {
        public var deviceId: String
        public var nome: String
        /// Prompter: a porta de sinalização, fixa pela vida da tela (hospedar de novo na mesma).
        public var porta: UInt16
        /// Controle: `host:porta` do prompter.
        public var endereco: String
        /// O prazo de cada espera (prompter) ou de cada tentativa de conectar (controle).
        public var prazoMs: UInt32

        public init(deviceId: String, nome: String, porta: UInt16 = 0, endereco: String = "", prazoMs: UInt32) {
            self.deviceId = deviceId
            self.nome = nome
            self.porta = porta
            self.endereco = endereco
            self.prazoMs = prazoMs
        }
    }

    public let papel: PapelDoTeleprompter
    public let replica: ReplicaDoTeleprompter
    public let configuracao: Configuracao
    /// Lido **a cada abertura**: o controle que pareou numa sessão volta pelo par gravado.
    private let paresConhecidos: () -> String
    /// Chamado da thread do laço logo que a sessão sobe, com o estado de pareamento a gravar (já
    /// somado ao que foi passado) e o par.
    private let aoSubir: (_ pares: String, _ par: ParDoTeleprompter) -> Void

    // Só a thread do laço toca nestes dois.
    private var sessao: OpaquePointer?
    private var mensagens: OpaquePointer?

    // A bandeira e o cancelador, divididos com a interface.
    private let trava = NSLock()
    private var _parar = false
    private var cancelador: OpaquePointer?

    public init(papel: PapelDoTeleprompter, replica: ReplicaDoTeleprompter, configuracao: Configuracao,
                paresConhecidos: @escaping () -> String,
                aoSubir: @escaping (_ pares: String, _ par: ParDoTeleprompter) -> Void) {
        self.papel = papel
        self.replica = replica
        self.configuracao = configuracao
        self.paresConhecidos = paresConhecidos
        self.aoSubir = aoSubir
    }

    deinit {
        // O laço fecha antes de sair; isto é o cinto, para uma fronteira largada no meio.
        if let s = sessao { quall_session_close(s) }
        if let m = mensagens { quall_messages_free(m) }
    }

    /// De qualquer thread: levanta a bandeira e destrava a espera bloqueada. Não toca em sessão.
    public func pedirParada() {
        trava.lock()
        _parar = true
        if let c = cancelador { quall_session_cancel(c) }
        trava.unlock()
    }

    public var deveParar: Bool {
        trava.lock(); defer { trava.unlock() }
        return _parar
    }

    public func abrir(pin: String?) -> (subiu: Bool, status: StatusDaFronteira, motivo: String) {
        precondition(sessao == nil, "abrir com uma sessão de pé: o laço fecha antes de abrir de novo")
        let novo = quall_canceller_new()
        trava.lock()
        cancelador = novo
        let jaParando = _parar
        trava.unlock()
        if jaParando, let novo { quall_session_cancel(novo) }

        let pares = paresConhecidos()
        var resultado: OpaquePointer?
        var falha: (StatusDaFronteira, String) = (.ok, "")
        let prazo = configuracao.prazoMs
        let porta = configuracao.porta

        configuracao.deviceId.withCString { idC in
            configuracao.nome.withCString { nomeC in
                comOpcional(pin) { pinC in
                    comOpcional(pares.isEmpty ? nil : pares) { paresC in
                        papel.rawValue.withCString { papelC in
                            var opcoes = QuallSessionOptions(
                                // O teleprompter não é fonte nem sumidouro de vídeo: sem capacidade
                                // nenhuma, e é assim que as listas de vídeo o deixam de fora (§2).
                                me: QuallDeviceDesc(device_id: idC, display_name: nomeC,
                                                    screen_source: false, camera_source: false, sink: false),
                                pin: pinC,
                                known_peers_json: paresC,
                                signaling_port: papel == .prompter ? porta : 0,
                                timeout_ms: prazo,
                                tracks: nil,
                                track_count: 0,
                                bind_address: nil)
                            resultado = withUnsafePointer(to: &opcoes) { op -> OpaquePointer? in
                                switch papel {
                                case .prompter:
                                    return quall_host_with_role(op, novo, papelC)
                                case .controle:
                                    return configuracao.endereco.withCString { endC in
                                        quall_connect_with_role(endC, op, novo, papelC)
                                    }
                                }
                            }
                            if resultado == nil {
                                // A regra do header: logo depois da chamada que falhou, antes de
                                // qualquer outra função `quall_`.
                                falha = (PonteDoTeleprompter.status(quall_last_status()),
                                         PonteDoTeleprompter.ultimoErro())
                            }
                        }
                    }
                }
            }
        }

        trava.lock()
        cancelador = nil
        trava.unlock()
        if let novo { quall_canceller_free(novo) }

        guard let s = resultado else { return (false, falha.0, falha.1) }
        guard let m = quall_session_messages(s) else {
            let motivo = "a sessão subiu sem handle de mensagens: \(PonteDoTeleprompter.ultimoErro())"
            quall_session_close(s)
            return (false, .invalido, motivo)
        }
        sessao = s
        mensagens = m

        let novosPares: String = {
            if pares.isEmpty {
                return PonteDoTeleprompter.lerAteCaber { quall_session_known_peers_json(s, nil, $0, $1) } ?? ""
            }
            return pares.withCString { antigos in
                PonteDoTeleprompter.lerAteCaber { quall_session_known_peers_json(s, antigos, $0, $1) } ?? ""
            }
        }()
        var par = ParDoTeleprompter(nome: "", deviceId: "", papel: nil,
                                    pareamentoNovo: quall_session_pairing_is_new(s))
        if let json = PonteDoTeleprompter.lerAteCaber({ quall_session_peer_json(s, $0, $1) }),
           let dados = json.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] {
            par.nome = obj["display_name"] as? String ?? ""
            par.deviceId = obj["device_id"] as? String ?? ""
            par.papel = obj["papel"] as? String
        }
        aoSubir(novosPares, par)
        return (true, .ok, "")
    }

    public func bombear(prazoMs: UInt32) -> BombeadaDoLaco {
        guard let m = mensagens else { return BombeadaDoLaco(mudancas: [], fechada: true, status: .fechado) }
        var bits: UInt32 = 0
        let s = quall_teleprompter_pump(replica.ponteiro, m, prazoMs, &bits)
        let status = PonteDoTeleprompter.status(s)
        return BombeadaDoLaco(mudancas: PonteDoTeleprompter.mudancas(bits), fechada: status != .ok, status: status)
    }

    public func proximoEvento() -> EventoDaSessao {
        guard let s = sessao else { return .falhou }
        let e = quall_session_next_event(s, 0)
        switch e {
        case QUALL_SESSION_EVENT_NONE: return .nenhum
        case QUALL_SESSION_EVENT_DISCONNECTED: return .desconectou
        case QUALL_SESSION_EVENT_FAILED: return .falhou
        // Um evento que esta build não conhece não derruba a sessão: a queda de verdade chega pela
        // bombeada (`CLOSED`) ou pelos dois acima.
        default: return .nenhum
        }
    }

    public func perdeuOPar() -> MudancasDoTeleprompter {
        var bits: UInt32 = 0
        _ = quall_teleprompter_peer_lost(replica.ponteiro, &bits)
        return PonteDoTeleprompter.mudancas(bits)
    }

    /// **É o fechamento que solta a porta** (§2): hospedar com a sessão velha de pé falha no `bind`.
    /// O handle de mensagens sobrevive ao fechamento e é liberado depois.
    public func fechar() {
        if let s = sessao { quall_session_close(s) }
        if let m = mensagens { quall_messages_free(m) }
        sessao = nil
        mensagens = nil
    }

    public func sortearPin() -> String { NucleoDeRede.sortearPin() }

    public func dormir(ms: Int) {
        let fim = Date().addingTimeInterval(Double(ms) / 1000)
        while !deveParar && Date() < fim {
            Thread.sleep(forTimeInterval: min(0.05, max(0, fim.timeIntervalSinceNow)))
        }
    }

    /// Os contadores das mensagens da sessão de pé, para o registro. Só da thread do laço.
    public func contadoresDasMensagens() -> String {
        guard let m = mensagens else { return "" }
        return PonteDoTeleprompter.lerAteCaber { quall_messages_stats_json(m, $0, $1) } ?? ""
    }
}

/// `withCString` para um texto opcional: `nil` vira ponteiro nulo.
private func comOpcional<R>(_ texto: String?, _ corpo: (UnsafePointer<CChar>?) -> R) -> R {
    guard let texto else { return corpo(nil) }
    return texto.withCString { corpo($0) }
}

// MARK: - a lista do controle

/// **Os prompters na rede**, pelo mDNS do núcleo. O `QuallBrowser*` é da thread do navegador, e só
/// dela: `quall_browser_collect` avança estado e pede uma thread só, e é a mesma thread que o
/// libera ao sair — a interface só pede para parar.
public final class NavegadorDePrompters: @unchecked Sendable {
    private let trava = NSLock()
    private var _parar = false
    private var rodando = false
    private var tratador: (([PrompterAchado]) -> Void)?

    public init() {}

    /// `aoAtualizar` roda na thread do navegador, a cada mudança da lista (a volta é de ~0,4 s).
    /// Pedir de novo com a thread ainda de pé (parar e começar em seguida) só a mantém viva, com o
    /// tratador novo — nunca duas threads no mesmo navegador.
    public func comecar(excluindo meuId: String, aoAtualizar: @escaping ([PrompterAchado]) -> Void) {
        trava.lock()
        tratador = aoAtualizar
        _parar = false
        guard !rodando else { trava.unlock(); return }
        rodando = true
        trava.unlock()

        let t = Thread { [self] in
            guard let b = quall_browser_start() else {
                trava.lock(); rodando = false; let avisar = tratador; trava.unlock()
                avisar?([])
                return
            }
            var anterior: [PrompterAchado]?
            while true {
                trava.lock()
                if _parar { rodando = false; trava.unlock(); break }
                let avisar = tratador
                trava.unlock()
                _ = quall_browser_collect(b, 400)
                let json = PonteDoTeleprompter.lerAteCaber { quall_browser_devices_json(b, $0, $1) } ?? "[]"
                let lista = PrompterAchado.lista(doJSON: json, excluindo: meuId)
                if lista != anterior {
                    anterior = lista
                    avisar?(lista)
                }
            }
            quall_browser_stop(b)
        }
        t.name = "quall.teleprompter.navegador"
        t.start()
    }

    public func parar() {
        trava.lock(); _parar = true; tratador = nil; trava.unlock()
    }
}
