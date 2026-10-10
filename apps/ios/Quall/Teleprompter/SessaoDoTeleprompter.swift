import Foundation

/// Em que pé está a conexão com o outro lado. É o que as duas telas desenham no alto.
enum FaseDaConexao: Equatable {
    /// Nada no ar.
    case parada
    /// Prompter: hospedando, e **nenhum controle entrou ainda** nesta tela.
    case esperando
    /// Controle: a primeira tentativa, antes de a sessão subir alguma vez.
    case conectando
    /// A sessão está de pé.
    case conectada(par: String)
    /// A sessão caiu depois de ter subido: o prompter espera o controle voltar (mesma porta, mesmo
    /// PIN); o controle tenta de novo sozinho, sem PIN. **É o estado do aviso nas duas telas.**
    case semPar(motivo: String)
    /// Parou de tentar, e diz por quê (controle: PIN errado, não é um teleprompter, versão;
    /// prompter: erro que se repetiria para sempre).
    case falhou(motivo: String)

    var conectada: Bool { if case .conectada = self { return true } else { return false } }
}

/// **A thread da sessão**: hospeda (prompter) ou conecta (controle), bombeia, e faz o fim da sessão
/// **na ordem do contrato** (`docs/contrato-teleprompter.md` §6 e §7):
///
/// 1. `QUALL_STATUS_CLOSED` da bombeada vem com `changed` preenchido: aplica. Se a queda chegou por
///    `quall_session_next_event`, antes faz **uma bombeada final com prazo zero** e aplica;
/// 2. só então `quall_teleprompter_peer_lost`;
/// 3. `quall_session_close` na sessão velha — é ele que solta a porta;
/// 4. no prompter, hospeda de novo **na mesma porta**: com o **mesmo PIN** depois de uma queda, e com
///    **PIN novo** depois de `QUALL_STATUS_WRONG_PIN` ou `QUALL_STATUS_PAIRING` numa espera.
///
/// # Uma thread só avança o estado
///
/// `quall_teleprompter_pump`, `quall_session_next_event` e `quall_session_close` vêm todas deste
/// laço: o header exige thread única para as duas primeiras, e `next_event` noutra thread durante o
/// `close` seria uso depois de liberar. A interface interfere por dois caminhos só: as edições da
/// réplica (que o núcleo manda da thread dela) e `parar()`.
///
/// # `parar()` e o cancelador, sem prompter fantasma
///
/// A bandeira e o cancelador ficam **sob a mesma trava**: ao guardar o cancelador de uma espera
/// nova, a bandeira é conferida ali mesmo e, se já subiu, a espera nasce cancelada. Sem isso, um
/// `parar()` que caísse entre a volta do laço e o cancelador novo deixaria uma espera de um minuto
/// sem tela nenhuma, segurando a porta e capaz de parear um controle — o fantasma que o
/// `EmissorDeCamera` já documentou. E quando `host`/`connect` volta com sessão, a bandeira é olhada
/// de novo antes de qualquer outra coisa.
final class SessaoDoTeleprompter {

    /// O que a sessão conta à tela. Chamados **da thread da sessão**: quem recebe passa para a
    /// principal — menos `salto`, que é entregue ali mesmo (ver `CaixaDeSalto`).
    struct Ouvintes {
        var fase: (FaseDaConexao) -> Void = { _ in }
        /// Uma frase para a tela, que não é fase: "alguém errou o PIN", "ocupado, tentando de novo".
        var aviso: (String) -> Void = { _ in }
        var pin: (String) -> Void = { _ in }
        var anuncio: (String?) -> Void = { _ in }
        /// Bits de `QuallTeleprompterChange` do que mudou por causa do outro lado. **Só os bits**:
        /// quem recebe relê estado e texto da réplica na hora de aplicar (ver `aplicar`).
        var mudou: (UInt32) -> Void = { _ in }
        /// "Releia o estado", a cada ~250 ms com a sessão de pé: `par_visto_ha_ms` e
        /// `sem_confirmacao_ha_ms` andam com o tempo sem bit nenhum, e o aviso de 1,5 s depende disso.
        var estado: () -> Void = {}
        /// `_JUMP` no prompter: o alvo, **nesta thread**, antes de qualquer publicação.
        var salto: (Double) -> Void = { _ in }
    }

    enum Modo {
        /// Hospeda na `porta`, com o `pin` inicial.
        case prompter(porta: UInt16, pin: String)
        /// Conecta em `endereco` (`host:porta`); `pin` só no primeiro pareamento.
        case controle(endereco: String, pin: String?)
    }

    // --- prazos -------------------------------------------------------------------------------

    /// A espera do prompter por um controle, re-armada em laço com o mesmo PIN quando estoura
    /// (§6: "um prompter que espera muito passa um prazo longo, ou hospeda de novo com o mesmo
    /// PIN"). O prazo cobre também o aperto de mão e a negociação: um controle que bate nos últimos
    /// ~1,5 s perde a corrida e tenta de novo. Um minuto: longo o bastante para isso ser raro, curto
    /// para um candidato que diz `Hello` e emudece não segurar a espera por muito tempo.
    static let esperaDoPrompterMs: UInt32 = 60_000
    /// Uma tentativa de conexão do controle.
    static let prazoDoControleMs: UInt32 = 10_000
    /// A bombeada: o contrato pede no máximo 250, e recomenda 50 a 100.
    static let bombeadaMs: UInt32 = 80
    /// O controle tenta de novo "a cada ~1 s até entrar" (§2).
    static let intervaloDeNovaTentativa: Double = 1.0
    /// Na **primeira** conexão, quantas vezes a rede tem direito de falhar antes de a tela dizer
    /// que não deu (um prompter que ainda está abrindo a porta, um pacote perdido).
    static let tentativasDaPrimeira = 3

    // --- estado -------------------------------------------------------------------------------

    let replica: ReplicaDoTeleprompter
    private let modo: Modo
    private let ouvintes: Ouvintes
    private let anunciante = AnuncianteBonjour()
    private var thread: Thread?

    /// A bandeira de parada **e** o cancelador da espera em curso, sob uma trava só.
    private let trava = NSLock()
    private var _parar = false
    private var cancelador: OpaquePointer?

    var parou: Bool { trava.lock(); defer { trava.unlock() }; return _parar }

    private var ultimaFase: FaseDaConexao = .parada

    init(replica: ReplicaDoTeleprompter, modo: Modo, ouvintes: Ouvintes) {
        self.replica = replica
        self.modo = modo
        self.ouvintes = ouvintes
    }

    func iniciar() {
        guard thread == nil else { return }
        // A thread segura esta sessão (e a réplica) **com força** até o fim do laço: é o que
        // garante que `quall_teleprompter_free` nunca aconteça com a bombeada em curso.
        let t = Thread { [self] in
            switch modo {
            case let .prompter(porta, pin): laçoDoPrompter(porta: porta, pinInicial: pin)
            case let .controle(endereco, pin): laçoDoControle(endereco: endereco, pinInicial: pin)
            }
            if case .falhou = ultimaFase {} else { publicarFase(.parada) }
            DiarioDoTeleprompter.dizer("sessão: a thread terminou")
        }
        t.name = "quall.teleprompter"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    /// Chamável de qualquer thread. Não toca em handle de sessão: levanta a bandeira e, se houver
    /// espera em curso, aciona o cancelador — os dois sob a mesma trava.
    func parar() {
        trava.lock()
        _parar = true
        if let c = cancelador { quall_session_cancel(c) }
        trava.unlock()
    }

    private func publicarFase(_ f: FaseDaConexao) {
        ultimaFase = f
        ouvintes.fase(f)
    }

    /// Dorme até `segundos`, acordando cedo se `parar()` vier.
    private func cochilar(_ segundos: Double) {
        let ate = Date().addingTimeInterval(segundos)
        while !parou && Date() < ate { Thread.sleep(forTimeInterval: 0.05) }
    }

    static func nome(_ s: QuallStatus) -> String {
        switch s {
        case QUALL_STATUS_BUSY: return "BUSY"
        case QUALL_STATUS_WRONG_PIN: return "WRONG_PIN"
        default: return NucleoReceptor.nome(s)
        }
    }

    // =========================================================================================
    // O prompter: hospeda, e hospeda de novo
    // =========================================================================================

    private func laçoDoPrompter(porta: UInt16, pinInicial: String) {
        var pin = pinInicial
        ouvintes.pin(pin)
        publicarFase(.esperando)
        // O anúncio vive enquanto a tela hospeda, e não só a espera: é com ele que um controle de
        // volta de uma queda (ou um controle novo) acha o prompter — e o atendente do núcleo
        // responde "ocupado" enquanto a sessão está de pé. **As três capacidades vão falsas**
        // (`c` vazio), como no `me` do `quall_host_with_role`: é o que faz as listas de vídeo o
        // esconderem (§2, §7).
        anunciante.comecar(deviceId: Identidade.deviceId, nome: Identidade.nome, porta: porta,
                           emiteTela: false, emiteCamera: false, exibe: false,
                           papel: ReplicaDoTeleprompter.Papel.teleprompter.rawValue)
        ouvintes.anuncio(anunciante.nomePublico)
        defer { anunciante.parar(); ouvintes.anuncio(nil) }
        DiarioDoTeleprompter.dizer("prompter: hospedando na porta \(porta)")

        var recuo = 0.0
        var tentativa = 0
        var semPares = false
        while !parou {
            tentativa += 1
            let pares = semPares ? nil : Compartilhado.lerPares()
            let inicio = Date()
            guard let s = hospedar(porta: porta, pin: pin, pares: pares) else {
                let (st, motivo) = (ultimoStatus, ultimoMotivo)
                let gastou = Date().timeIntervalSince(inicio)
                if parou || st == QUALL_STATUS_CANCELLED { break }
                DiarioDoTeleprompter.dizer(String(format: "prompter: espera %d sem sessão em %.1f s: %@ (%@)",
                                                  tentativa, gastou, SessaoDoTeleprompter.nome(st), SanitizacaoDoLog.causaExterna(motivo)))
                switch st {
                case QUALL_STATUS_TIMEOUT:
                    // O caso normal de quem espera: ninguém entrou. Mesmo PIN, de novo, na hora.
                    recuo = 0
                case QUALL_STATUS_WRONG_PIN, QUALL_STATUS_PAIRING:
                    // **PIN novo**: o PIN de seis dígitos é segurado por uma tentativa por conexão, e
                    // repeti-lo depois de erro abriria força bruta online (§2). Quem estiver
                    // digitando lê o número novo na tela.
                    let novo = Nucleo.sortearPin()
                    if novo.count == 6 { pin = novo }
                    ouvintes.pin(pin)
                    ouvintes.aviso(tr("Alguém tentou entrar e o pareamento não fechou. Por segurança, o PIN mudou."))
                    if Diagnostico.ligado { DiarioDoTeleprompter.dizer("prompter: PIN renovado") }
                    recuo = 0
                case QUALL_STATUS_NEEDS_PIN:
                    // Um controle sem PIN que este prompter não conhece. Nenhum PIN foi gasto: a
                    // espera volta **na hora**, com o mesmo — é justamente quando a pessoa vai
                    // digitá-lo lá.
                    ouvintes.aviso(tr("Um controle que não está pareado com este aparelho tentou entrar. "
                                      + "Digite nele o PIN desta tela."))
                    recuo = 0
                case QUALL_STATUS_PROTOCOL:
                    ouvintes.aviso(tr("Um aparelho com outra versão do Quall tentou entrar. Atualize o app nos dois."))
                    recuo = 0
                case QUALL_STATUS_IO:
                    // A porta não abriu (ocupada — a sessão anterior ainda soltando, ou outra coisa
                    // nela). É o único caso que merece recuo crescente.
                    ouvintes.aviso(tr("A porta %@ está ocupada neste aparelho. Tentando de novo…", String(porta)))
                    recuo = min(5, max(1, recuo * 2))
                case QUALL_STATUS_INVALID where !semPares:
                    // O `pares.json` ilegível derruba toda espera com INVALID. Uma vez sem ele:
                    // controles já pareados vão precisar do PIN, mas o prompter não morre.
                    DiarioDoTeleprompter.dizer("prompter: INVALID na espera; tentando sem os pares conhecidos")
                    semPares = true
                    recuo = 0
                case QUALL_STATUS_INVALID, QUALL_STATUS_NULL_POINTER, QUALL_STATUS_NOT_UTF8:
                    // Erro que se repetiria para sempre: para e diz.
                    publicarFase(.falhou(motivo: tr("O teleprompter não conseguiu esperar o controle: %@", motivo)))
                    return
                default:
                    // Depois do pareamento (NO_ROUTE, TRANSPORT, SIGNALING): o controle entrou e o
                    // caminho não fechou. Mesmo PIN (nenhum foi gasto errado), com um respiro.
                    ouvintes.aviso(st == QUALL_STATUS_NO_ROUTE
                                   ? tr("O controle entrou, mas os dois aparelhos não acharam caminho um até o outro.")
                                   : tr("A espera recomeçou: %@", motivo))
                    recuo = min(5, max(0.5, recuo * 2))
                }
                if recuo > 0 { cochilar(recuo) }
                continue
            }

            // --- de pé -------------------------------------------------------------------------
            recuo = 0
            guardarPares(s, base: pares)
            let par = SessaoDoTeleprompter.nomeDoPar(s)
            DiarioDoTeleprompter.dizer("prompter: sessão de pé na espera \(tentativa); "
                                       + "candidatos descartados antes: \(quall_session_descartados(s))")
            tentativa = 0
            ouvintes.aviso("")
            publicarFase(.conectada(par: par))
            let motivo = correr(sessao: s)
            fechar(s)
            replica.salvar(motivo: "fim de sessão")
            if parou { break }
            // Mesma porta, mesmo PIN: a sessão que caiu tinha subido (§2).
            DiarioDoTeleprompter.dizer("prompter: o controle saiu (\(SanitizacaoDoLog.causaExterna(motivo))); hospedando de novo na "
                                       + "porta \(porta) com o mesmo PIN")
            publicarFase(.semPar(motivo: motivo))
        }
    }

    private var ultimoStatus: QuallStatus = QUALL_STATUS_OK
    private var ultimoMotivo = ""

    /// Cópias em C que vivem só durante a chamada bloqueante. A fronteira converte tudo para Rust
    /// em `montar_config` antes de bloquear, então liberar na volta é seguro — e não acumula uma
    /// cópia por volta do laço de um prompter que espera o dia inteiro.
    private final class TextosEmC {
        private var vivos: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafeMutablePointer<CChar> {
            let p = strdup(s) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
            vivos.append(p)
            return p
        }
        deinit { for p in vivos { free(p) } }
    }

    /// Cria o cancelador da espera e o guarda **conferindo a bandeira sob a mesma trava**.
    private func armarCancelador() -> OpaquePointer {
        let novo = quall_canceller_new()!
        trava.lock()
        cancelador = novo
        if _parar { quall_session_cancel(novo) }
        trava.unlock()
        return novo
    }

    private func desarmarCancelador(_ c: OpaquePointer) {
        trava.lock(); cancelador = nil; trava.unlock()
        quall_canceller_free(c)
    }

    private func hospedar(porta: UInt16, pin: String, pares: String?) -> OpaquePointer? {
        let textos = TextosEmC()
        let papelC = textos.c(ReplicaDoTeleprompter.Papel.teleprompter.rawValue)
        var opcoes = QuallSessionOptions(
            // O prompter não é fonte de vídeo nem receptor de vídeo: não anuncia capacidade
            // nenhuma, e é por isso que as listas de vídeo o escondem (§7).
            me: QuallDeviceDesc(device_id: textos.c(Identidade.deviceId), display_name: textos.c(Identidade.nome),
                                screen_source: false, camera_source: false, sink: false),
            pin: UnsafePointer(textos.c(pin)),
            known_peers_json: pares.map { UnsafePointer(textos.c($0)) },
            signaling_port: porta,
            timeout_ms: SessaoDoTeleprompter.esperaDoPrompterMs,
            // Um teleprompter não emite tracks: `track_count > 0` é `INVALID`.
            tracks: nil,
            track_count: 0,
            bind_address: nil)
        let c = armarCancelador()
        let s = withUnsafePointer(to: &opcoes) { quall_host_with_role($0, c, papelC) }
        if s == nil {
            // Logo depois da chamada que falhou, antes de qualquer outra `quall_`.
            ultimoStatus = quall_last_status()
            ultimoMotivo = ReplicaDoTeleprompter.ultimoErro()
        }
        desarmarCancelador(c)
        return s
    }

    // =========================================================================================
    // O controle: conecta, e conecta de novo
    // =========================================================================================

    private func laçoDoControle(endereco: String, pinInicial: String?) {
        // O PIN vale **só até o primeiro pareamento**. Com PIN o núcleo sempre pareia de novo
        // (`pairing.rs`, o PIN tem precedência sobre a retomada); depois do primeiro, a reconexão
        // vai sem PIN. Repetir um PIN velho contra um prompter que já trocou o dele seria uma
        // tentativa de PIN errado — que faz o prompter trocar de novo, a cada segundo, para sempre.
        var pin = pinInicial
        var jaSubiu = false
        var tentativa = 0
        var falhasDaPrimeira = 0
        var ocupadoDesde: Date?
        publicarFase(.conectando)
        while !parou {
            tentativa += 1
            let pares = Compartilhado.lerPares()
            let inicio = Date()
            guard let s = conectar(endereco: endereco, pin: pin, pares: pares) else {
                let (st, motivo) = (ultimoStatus, ultimoMotivo)
                let gastou = Date().timeIntervalSince(inicio)
                if parou || st == QUALL_STATUS_CANCELLED { break }
                DiarioDoTeleprompter.dizer(String(format: "controle: tentativa %d sem sessão em %.1f s: %@ (%@)",
                                                  tentativa, gastou, SessaoDoTeleprompter.nome(st), SanitizacaoDoLog.causaExterna(motivo)))
                switch st {
                case QUALL_STATUS_BUSY:
                    // O prompter ainda segura a sessão velha (até 5 s, o detector dele) ou já tem
                    // outro controle. "Tente de novo em instantes" — é o que se faz. Passando de
                    // ~6 s, não é mais a sessão velha: diz o que o prompter disse.
                    let desde = ocupadoDesde ?? Date()
                    ocupadoDesde = desde
                    ouvintes.aviso(Date().timeIntervalSince(desde) > 6
                                   ? tr("O prompter continua ocupado: %@. Tentando de novo…", motivo)
                                   : tr("O prompter está ocupado — tentando de novo…"))
                case QUALL_STATUS_WRONG_PIN:
                    publicarFase(.falhou(motivo: tr("PIN errado. O prompter trocou o PIN por segurança: "
                                           + "digite o número que aparece na tela dele agora.")))
                    return
                case QUALL_STATUS_NEEDS_PIN, QUALL_STATUS_PAIRING:
                    // Os dois pedem o PIN: com PIN digitado, o pareamento novo cura até um segredo
                    // guardado que discorda do prompter. **Tentar de novo sozinho, aqui, faria o
                    // prompter trocar o PIN a cada volta** (ele troca depois de `PAIRING`).
                    publicarFase(.falhou(motivo: st == QUALL_STATUS_NEEDS_PIN
                        ? tr("O prompter não reconhece este aparelho. Digite o PIN que aparece na tela dele.")
                        : tr("O pareamento foi recusado (%@). Digite o PIN que aparece na tela do prompter.", motivo)))
                    return
                case QUALL_STATUS_PROTOCOL:
                    publicarFase(.falhou(motivo: tr("Esse aparelho não é um teleprompter do Quall, ou fala "
                                           + "outra versão. %@", motivo)))
                    return
                case QUALL_STATUS_INVALID, QUALL_STATUS_NULL_POINTER, QUALL_STATUS_NOT_UTF8:
                    publicarFase(.falhou(motivo: tr("Endereço inválido: %@", motivo)))
                    return
                case QUALL_STATUS_NO_ROUTE where !jaSubiu:
                    // Na primeira vez é quase sempre a permissão de Rede Local, ou rede isolada:
                    // tentar de novo não muda nada.
                    publicarFase(.falhou(motivo: SessaoDoTeleprompter.textoDeRede(st, motivo)))
                    return
                default:
                    // IO, TIMEOUT, CLOSED, SIGNALING, TRANSPORT: rede. Seguro repetir — nenhum
                    // desses troca o PIN do prompter. Na primeira conexão, poucas vezes (um endereço
                    // errado precisa virar frase na tela); depois de uma sessão que subiu, sempre.
                    if !jaSubiu {
                        falhasDaPrimeira += 1
                        if falhasDaPrimeira >= SessaoDoTeleprompter.tentativasDaPrimeira {
                            publicarFase(.falhou(motivo: SessaoDoTeleprompter.textoDeRede(st, motivo)))
                            return
                        }
                    }
                    ouvintes.aviso(SessaoDoTeleprompter.textoDeRede(st, motivo))
                }
                cochilar(SessaoDoTeleprompter.intervaloDeNovaTentativa)
                continue
            }

            // --- de pé -------------------------------------------------------------------------
            jaSubiu = true
            pin = nil
            ocupadoDesde = nil
            guardarPares(s, base: pares)
            let par = SessaoDoTeleprompter.nomeDoPar(s)
            DiarioDoTeleprompter.dizer("controle: sessão de pé na tentativa \(tentativa)")
            tentativa = 0
            ouvintes.aviso("")
            publicarFase(.conectada(par: par))
            let motivo = correr(sessao: s)
            fechar(s)
            replica.salvar(motivo: "fim de sessão")
            if parou { break }
            DiarioDoTeleprompter.dizer("controle: a sessão caiu (\(SanitizacaoDoLog.causaExterna(motivo))); tentando de novo sem PIN")
            publicarFase(.semPar(motivo: motivo))
            cochilar(SessaoDoTeleprompter.intervaloDeNovaTentativa)
        }
    }

    static func textoDeRede(_ st: QuallStatus, _ motivo: String) -> String {
        switch st {
        case QUALL_STATUS_NO_ROUTE:
            return tr("Os dois aparelhos não acharam caminho um até o outro. Confira se estão na mesma "
                + "rede Wi‑Fi e se \"%@\" está ligada para o Quall nos %@.",
                      trSistema("Rede Local"), trSistema("Ajustes"))
        case QUALL_STATUS_IO, QUALL_STATUS_TIMEOUT:
            return tr("Ninguém atendeu nesse endereço. Confira se o prompter está com a tela aberta e se "
                + "o endereço e a porta estão certos.")
        default:
            return tr("Não deu para conectar: %@", motivo)
        }
    }

    private func conectar(endereco: String, pin: String?, pares: String?) -> OpaquePointer? {
        let textos = TextosEmC()
        let enderecoC = textos.c(endereco)
        let papelC = textos.c(ReplicaDoTeleprompter.Papel.controleRemoto.rawValue)
        var opcoes = QuallSessionOptions(
            me: QuallDeviceDesc(device_id: textos.c(Identidade.deviceId), display_name: textos.c(Identidade.nome),
                                screen_source: false, camera_source: false, sink: false),
            pin: pin.map { UnsafePointer(textos.c($0)) },
            known_peers_json: pares.map { UnsafePointer(textos.c($0)) },
            signaling_port: 0,
            timeout_ms: SessaoDoTeleprompter.prazoDoControleMs,
            tracks: nil,
            track_count: 0,
            bind_address: nil)
        let c = armarCancelador()
        let s = withUnsafePointer(to: &opcoes) { quall_connect_with_role(enderecoC, $0, c, papelC) }
        if s == nil {
            ultimoStatus = quall_last_status()
            ultimoMotivo = ReplicaDoTeleprompter.ultimoErro()
        }
        desarmarCancelador(c)
        return s
    }

    // =========================================================================================
    // A sessão de pé: a bombeada, e o fim na ordem
    // =========================================================================================

    /// Bombeia até a sessão acabar ou `parar()` vir. Devolve o motivo do fim, para o diário e para
    /// o aviso. **Faz os passos 1 e 2 do fim** (bombeada final e `peer_lost`); o 3 é `fechar`.
    private func correr(sessao s: OpaquePointer) -> String {
        guard let m = quall_session_messages(s) else {
            let motivo = "o núcleo não deu o handle de mensagens: \(ReplicaDoTeleprompter.ultimoErro())"
            aplicar(replica.perdeuOPar())
            return motivo
        }
        defer { quall_messages_free(m) }

        var motivo = ""
        var ultimaPublicacao = Date.distantPast
        var voltas: UInt64 = 0
        let comeco = Date()
        while true {
            // A bandeira primeiro: uma sessão que subiu depois de `parar()` não bombeia nada.
            if parou { motivo = "parado aqui"; break }
            voltas &+= 1
            let (st, mudou) = replica.bombear(m, prazoMs: SessaoDoTeleprompter.bombeadaMs)
            // 1. O que mudou vale **também** na bombeada que diz que a sessão acabou: a pausa que o
            //    outro lado tocou antes de cair chega nela.
            if mudou != 0 { aplicar(mudou); ultimaPublicacao = Date() }
            if st == QUALL_STATUS_CLOSED {
                // Mais uma, com prazo zero: a leitura pode ter terminado vazia e só o envio final
                // ter descoberto o fechamento — uma mensagem que chegou nesse meio ficaria de fora.
                // É idempotente: com a fila vazia, não muda nada.
                let (_, fim) = replica.bombear(m, prazoMs: 0)
                if fim != 0 { aplicar(fim) }
                motivo = "a sessão fechou"
                break
            }
            if st != QUALL_STATUS_OK {
                // Só o cadeado envenenado do núcleo chega aqui. Girar nisso seria queimar CPU.
                motivo = "a bombeada falhou: \(SessaoDoTeleprompter.nome(st)) \(ReplicaDoTeleprompter.ultimoErro())"
                break
            }
            let evento = quall_session_next_event(s, 0)
            if evento != QUALL_SESSION_EVENT_NONE {
                // A queda chegou pelo evento: **uma bombeada final com prazo zero** antes de dar o
                // par por perdido — o que estava na fila entra.
                let (_, fim) = replica.bombear(m, prazoMs: 0)
                if fim != 0 { aplicar(fim) }
                motivo = evento == QUALL_SESSION_EVENT_DISCONNECTED ? "o outro lado saiu" : "o transporte falhou"
                break
            }
            if Date().timeIntervalSince(ultimaPublicacao) >= 0.25 {
                ouvintes.estado()
                ultimaPublicacao = Date()
            }
        }
        // 2. Só então o par é dado por perdido.
        aplicar(replica.perdeuOPar())
        let contadores = SessaoDoTeleprompter.contadoresDeMensagens(m)
        DiarioDoTeleprompter.dizer(String(format: "sessão: fim em %.1f s depois de %llu bombeadas (%@); "
                                          + "mensagens %@", Date().timeIntervalSince(comeco), voltas,
                                          SanitizacaoDoLog.causaExterna(motivo), contadores))
        // O estado com que esta ponta ficou — para comparar, pelo diário, com o da outra ponta.
        if let e = replica.estado() {
            let texto = replica.texto()
            DiarioDoTeleprompter.dizer("sessão: estado no fim: rolando=\(e.rolando) velocidade=\(e.velocidade) "
                + "fonte=\(e.fonte) margem=\(e.margem) linha=\(e.linhaDeLeitura) espelho=\(e.espelho) "
                + "posicao=\(e.posicao) texto=\(texto.utf8.count) bytes resumo=\(ResumoDoTexto.de(texto)) "
                + "contadores: estados_enviados=\(e.contadores.estadosEnviados) "
                + "textos_enviados=\(e.contadores.textosEnviados) recebidas=\(e.contadores.recebidas) "
                + "invalidas=\(e.contadores.invalidas) campos_recusados=\(e.contadores.camposRecusados) "
                + "carimbos_do_futuro=\(e.contadores.carimbosDoFuturo)")
        }
        return motivo
    }

    /// 3. Fecha a sessão velha. É isto que solta a porta de sinalização. Pode levar ~2 s (a espera
    /// do atendente do núcleo): nunca na principal — aqui é a thread da sessão.
    private func fechar(_ s: OpaquePointer) {
        let inicio = Date()
        let st = quall_session_close(s)
        DiarioDoTeleprompter.dizer(String(format: "sessão: quall_session_close=%@ em %.0f ms",
                                          SessaoDoTeleprompter.nome(st), Date().timeIntervalSince(inicio) * 1000))
    }

    /// Entrega os bits. O salto sai antes, **nesta thread**, direto para a vista (`CaixaDeSalto`).
    ///
    /// # Por que só os bits, e não o estado e o texto lidos aqui
    ///
    /// A primeira versão lia estado e texto nesta thread e os publicava na principal. Medido na
    /// corrida iPhone 7 → iPhone X de 13/09: o controle pôs o roteiro dele às 44,50; a bombeada
    /// anterior tinha lido o texto **velho** do prompter, e a publicação chegou à principal às 44,62
    /// — a tela do controle mostrou por um instante um roteiro que a réplica já não tinha. O mesmo
    /// valia para o estado: um "pausar" tocado entre a leitura e a publicação voltava a "rolando" na
    /// tela até a publicação seguinte. Relendo na principal, na hora de aplicar, a tela mostra
    /// sempre o que a réplica tem **agora**.
    private func aplicar(_ mudou: UInt32) {
        guard mudou != 0 else { return }
        if case .prompter = modo, mudou & QUALL_TELEPROMPTER_CHANGE_JUMP.rawValue != 0,
           let alvo = replica.estado()?.salto {
            ouvintes.salto(alvo)
        }
        ouvintes.mudou(mudou)
    }

    // --- o que o núcleo sabe da sessão --------------------------------------------------------

    static func nomeDoPar(_ s: OpaquePointer) -> String {
        guard let json = ReplicaDoTeleprompter.lerAteCaber({ quall_session_peer_json(s, $0, $1) }),
              let dados = json.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let nome = objeto["display_name"] as? String
        else { return "" }
        return nome
    }

    static func contadoresDeMensagens(_ m: OpaquePointer) -> String {
        ReplicaDoTeleprompter.lerAteCaber({ quall_messages_stats_json(m, $0, $1) }) ?? "{}"
    }

    /// Funde o pareamento recém-fechado com o `pares.json` do App Group **agora**, sob coordenação
    /// (o mesmo arquivo que a appex e o receptor escrevem — `Compartilhado.atualizarPares`). É o que
    /// deixa o controle voltar de uma queda **sem PIN**.
    private func guardarPares(_ s: OpaquePointer, base: String?) {
        var gravados = 0
        Compartilhado.atualizarPares { noDisco in
            let atualizado = ReplicaDoTeleprompter.lerAteCaber { buf, cap in
                if let noDisco { return noDisco.withCString { quall_session_known_peers_json(s, $0, buf, cap) } }
                return quall_session_known_peers_json(s, nil, buf, cap)
            }
            guard let atualizado, !atualizado.isEmpty else { return noDisco ?? "" }
            gravados = atualizado.utf8.count
            return atualizado
        }
        if gravados > 0 { DiarioDoTeleprompter.dizer("pareamento gravado (\(gravados) bytes)") }
    }
}

/// **O salto, da thread da sessão direto para o relógio de quadro da vista**, sem passar pela
/// publicação na principal.
///
/// # Por que existe (achado da revisão adversarial de 13/09, item 7)
///
/// Ao fundir o salto, o núcleo já põe a posição do prompter no alvo e responde. Se a vista só
/// soubesse do salto quando a publicação chegasse à principal, o relógio de quadro continuaria
/// relatando `set_position` do lugar **velho** nesse meio — com carimbo novo —, e isso sairia em até
/// 250 ms. O controle, que já viu o salto reconhecido, tomaria o relato velho como base de um "pular":
/// o defeito 3 da revisão do núcleo, de volta pela casca. Com a caixa, o quadro seguinte ao salto já
/// o consome **antes** de calcular e relatar a posição.
final class CaixaDeSalto {
    private let trava = NSLock()
    private var alvo: Double?

    func pedir(_ a: Double) { trava.lock(); alvo = a; trava.unlock() }

    /// O salto pendente, uma vez.
    func tomar() -> Double? {
        trava.lock(); defer { trava.unlock() }
        let a = alvo
        alvo = nil
        return a
    }
}
