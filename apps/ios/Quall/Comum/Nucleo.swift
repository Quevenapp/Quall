import Foundation

/// Casca de produto sobre a fronteira C do núcleo.
///
/// Nasceu do `Nucleo` do arnês do degrau 4, que entregou 10.755 quadros numa sessão e 3.599 na
/// seguinte, e mantém dele tudo o que era decisão e não instrumento. Quatro dessas decisões são
/// consequência direta da dívida catalogada em `docs/divida-do-nucleo.md`, e nenhuma é de estilo:
///
/// 1. **Nunca chamar `quall_cleanup()`.** Ele trava a libdatachannel num mutex global, e numa
///    Broadcast Upload Extension não existe "saída do processo" segura — quem mata o processo é
///    o sistema, quando a transmissão acaba. Chamar seria trocar um vazamento por um travamento.
///    (dívida 2)
/// 2. **`deveIDR` é da casca, não do núcleo.** `quall_track_take_idr_request` faz `swap(false)`:
///    se o quadro que carregava o pedido for descartado pelo encoder, o pedido some e o receptor
///    fica sem imagem sem que ninguém saiba por quê. Aqui a bandeira só baixa quando o
///    VideoToolbox devolve de fato um quadro chave. (dívida 15)
/// 3. **Sucesso de `quall_track_send_frame` não é sinal de vida.** O `CONSENT_TIMEOUT` do
///    libjuice é de 30 s: o emissor continua recebendo `QUALL_STATUS_OK` por meio minuto depois
///    de o receptor sumir. O contador de sucessos serve para dizer que há vídeo saindo, jamais
///    para concluir que alguém está do outro lado. (dívida 13)
/// 4. **`quall_host` bloqueia e não tem cancelamento.** (dívida 10) Quem chama precisa de um
///    prazo curto re-armado em laço, e de um caminho de desistência que não dependa desta
///    chamada voltar. Desde 27/09 `hospedar` aceita o cancelador do núcleo (`quall_host_cancelable`),
///    que a tela da câmera usa para soltar a porta ao fechar; a appex continua sem ele.
///
/// O que **não** veio do arnês: contadores de janela, fotografia de pegada, máquina de fases.
/// Foi um delta de janela sobre `UInt64` que derrubou a appex aos 464 s. Aqui não há subtração
/// de inteiro sem sinal em lugar nenhum.
final class Nucleo {

    static func versaoDoProtocolo() -> UInt16 { quall_protocol_version() }

    static func ultimoErro() -> String {
        guard let ponteiro = quall_last_error() else { return "" }
        return String(cString: ponteiro)
    }

    /// PIN de seis dígitos, sorteado pelo núcleo.
    ///
    /// Feito lá e não aqui porque a qualidade do sorteio é o que segura o pareamento: seis
    /// dígitos tirados de um gerador semeado por relógio são adivinháveis, e o pareamento é a
    /// única barreira entre a tela desta pessoa e quem mais estiver na rede.
    ///
    /// **Buffer fixo aqui é julgamento, não descuido.** O PIN é de seis dígitos por contrato —
    /// 7 bytes com o NUL —, e o laço de duas chamadas de `lerTexto` seria *pior* nesta função: a
    /// primeira chamada sortearia um PIN e o jogaria fora, a segunda sortearia outro. O que a
    /// regra exige e que faltava é a segunda metade da comparação: um retorno maior que a
    /// capacidade também é positivo, e sem `escritos <= buffer.count` ele passaria por sucesso
    /// com o buffer zerado. Ver `tools/confere-fronteira.py`, PERMITIDOS.
    static func sortearPin() -> String {
        var buffer = [CChar](repeating: 0, count: 16)
        let escritos = buffer.withUnsafeMutableBufferPointer { p -> Int in
            Int(quall_generate_pin(p.baseAddress, UInt(p.count)))
        }
        guard escritos > 0, escritos <= buffer.count else { return "" }
        return String(cString: buffer)
    }

    // --- estado -----------------------------------------------------------------------------

    /// Protege os dois ponteiros da fronteira C contra o cruzamento que existe de verdade aqui:
    /// os quadros saem da thread de saída do VideoToolbox, a supervisão de 1 Hz lê contadores de
    /// outra thread, e o desmonte vem de uma terceira. Sem esta trava, `encerrar()` liberaria a
    /// track no instante em que um quadro estivesse sendo empacotado — e o defeito apareceria
    /// como um travamento dentro da libdatachannel, longe da causa.
    private let travaDoUso = NSLock()
    private var sessao: OpaquePointer?
    private var track: OpaquePointer?
    /// A track de microfone, quando a sessão a declarou (`hospedar(..., rotuloDoMicrofone:)`). Só
    /// o emissor de câmera a pede; a appex nunca. Ver `enviarAudio`.
    private var trackDoMicrofone: OpaquePointer?

    /// Strings do C que precisam sobreviver à chamada de `quall_host`. Guardadas em campo — e
    /// não passadas por `withCString` aninhado — porque o aninhamento de cinco níveis de closure
    /// em volta de uma chamada que **bloqueia por dezenas de segundos** é exatamente o tipo de
    /// código em que um `defer` mal colocado vira ponteiro pendurado.
    private var vivas: [UnsafeMutablePointer<CChar>] = []

    private let travaDoIdr = NSLock()
    private var deveIDR = false

    /// Contadores de **instrumento**, com trava própria.
    ///
    /// Eles não compartilham a `travaDoUso` de propósito. A regra que esta rodada adotou depois
    /// da análise adversarial: *contador de instrumento é atômico ou tem trava própria; a leitura
    /// tem direito a número velho, jamais a espera*. Compartilhar a trava do `send_frame` com
    /// quem só quer relatar é a mesma doença do "instrumento derrubou o processo", em versão
    /// lenta — e essa aparece como "perdeu 30 quadros", que é bem mais difícil de atribuir.
    ///
    /// A escrita acontece no caminho do quadro e custa um par de `lock`/`unlock` sem disputa
    /// (dezenas de nanossegundos a 30 fps). A leitura nunca segura nada além dela mesma.
    private let travaDoRelato = NSLock()
    private var _enviados: UInt64 = 0
    private var _recusados: UInt64 = 0
    private var _ultimoStatus: UInt32 = 0
    private var _audioEnviados: UInt64 = 0
    private var _audioRecusados: UInt64 = 0

    var enviados: UInt64 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _enviados
    }

    var recusados: UInt64 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _recusados
    }

    var ultimoStatus: UInt32 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _ultimoStatus
    }

    /// Quadros de áudio que o núcleo aceitou e recusou na track de microfone.
    var audioEnviados: UInt64 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _audioEnviados
    }

    var audioRecusados: UInt64 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _audioRecusados
    }

    /// Rede de segurança, e só isso: quem usa esta classe fecha a sessão explicitamente, na ordem
    /// obrigatória. Mas um `Nucleo` largado sem `encerrar()` — o candidato de uma tentativa que
    /// falhou, por exemplo — seguraria a porta de sinalização até o processo morrer, e o laço de
    /// re-hospedar nunca mais conseguiria `bind`.
    deinit {
        encerrar()
        for p in vivas { free(p) }
    }

    private func guardar(_ texto: String) -> UnsafeMutablePointer<CChar> {
        let copia = strdup(texto) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
        vivas.append(copia)
        return copia
    }

    // --- sessão -----------------------------------------------------------------------------

    /// Sobe uma sessão de emissor com **uma** track de vídeo e, quando `rotuloDoMicrofone` vem, uma
    /// segunda de microfone (R5 fase 2). **Bloqueia** até o receptor chegar, parear e
    /// o transporte subir, ou até o prazo estourar. Chame de uma thread de trabalho.
    ///
    /// Anunciar por mDNS é chamada separada no núcleo (`quall_advertiser_start`) e aqui não é
    /// feita: nenhum perfil de provisionamento tem `com.apple.developer.networking.multicast`, e
    /// o pedido depende da Apple. Enquanto isso, o receptor entra pelo IP que a tela de espera
    /// mostra — que é o fallback obrigatório do fluxo, e não um contorno temporário.
    ///
    /// - Returns: `true` quando a sessão subiu **com track de saída**. Sessão sem track é falha:
    ///   ela não produz erro na fronteira C, e quem lesse só `quall_last_error()` concluiria
    ///   "falhou sem motivo".
    func hospedar(pin: String,
                  porta: UInt16,
                  deviceId: String,
                  nome: String,
                  tipo: QuallTrackKind,
                  rotulo: String,
                  paresConhecidos: String?,
                  prazoMs: UInt32,
                  rotuloDoMicrofone: String? = nil,
                  cancelador: OpaquePointer? = nil) -> Bool {
        let idC = guardar(deviceId)
        let nomeC = guardar(nome)
        let pinC = guardar(pin)
        let rotuloC = guardar(rotulo)
        let paresC: UnsafeMutablePointer<CChar>? = paresConhecidos.map { guardar($0) }
        let rotuloDoMicC: UnsafeMutablePointer<CChar>? = rotuloDoMicrofone.map { guardar($0) }

        // **`audio_codec` foi acrescentado ao `QuallTrackDesc` pela rodada de áudio e este arquivo
        // não acompanhou** — `apps/ios/Quall` não compilava contra o `quall.h` do commit
        // `dba20e6` antes desta frente encostar nele. O erro é `missing argument for parameter
        // 'audio_codec' in call`, e ele não aparecia porque ninguém tinha compilado o emissor iOS
        // desde então.
        //
        // `QUALL_AUDIO_CODEC_DEFAULT` (0) é o valor certo e é o único honesto aqui: ele quer dizer
        // "use o codec do preset da espécie", e esta chamada só monta track de **vídeo** (tela ou
        // câmera), onde o campo é ignorado — o próprio header diz que ele "só vale em track de
        // áudio". Escrever `OPUS` aqui seria anunciar uma escolha que este emissor não faz.
        var descricoes = [QuallTrackDesc(kind: tipo, label: rotuloC,
                                         audio_codec: QUALL_AUDIO_CODEC_DEFAULT)]
        // **O microfone vai na oferta sempre que pedido, ligado ou não** (R5 fase 2,
        // `docs/teleprompter-com-camera.md` §4.2): o que não está na oferta só entra com
        // renegociação, e o botão pode ligar no meio da sessão. Calado, custa uma linha `m=`.
        //
        // O codec é dito (`OPUS`), e não `DEFAULT`: é a mesma escolha que o encoder faz
        // (`MicrofoneParaOpus`), e dizê-la nos dois lugares é o que impede o fio de anunciar uma
        // coisa e o encoder fazer outra.
        if let rotuloDoMicC {
            descricoes.append(QuallTrackDesc(kind: QUALL_TRACK_KIND_MICROPHONE, label: rotuloDoMicC,
                                             audio_codec: QUALL_AUDIO_CODEC_OPUS))
        }

        return descricoes.withUnsafeBufferPointer { lista -> Bool in
            let tracks = lista.baseAddress
            var opcoes = QuallSessionOptions(
                me: QuallDeviceDesc(device_id: idC,
                                    display_name: nomeC,
                                    screen_source: tipo == QUALL_TRACK_KIND_SCREEN,
                                    camera_source: tipo == QUALL_TRACK_KIND_CAMERA,
                                    sink: false),
                pin: pinC,
                known_peers_json: paresC.map { UnsafePointer($0) },
                signaling_port: porta,
                timeout_ms: prazoMs,
                tracks: tracks,
                track_count: UInt(lista.count),
                // Só a casca que **conecta** pede o cabo, e nenhuma tela do iOS oferece isso ainda:
                // `nil` mantém o comportamento de sempre, com o ICE reunindo toda interface. Ver
                // `QuallSessionOptions::bind_address` e `docs/quall-pelo-cabo.md`.
                bind_address: nil)

            // A chamada bloqueia: fica **fora** da trava, senão a supervisão de 1 Hz ficaria
            // pendurada nela durante toda a espera pelo receptor — e é ela quem executa o
            // Cancelar da tela de espera.
            //
            // **Com cancelador** (`quall_host_cancelable`; nulo reproduz `quall_host` exatamente):
            // a cutucada TCP que a tela da câmera usava para destravar esta chamada deixou de
            // funcionar com o conserto de 01/09 no núcleo, que descarta o candidato mudo e segue
            // esperando. Ver `SolturaDaPorta`.
            guard let nova = withUnsafePointer(to: &opcoes, { quall_host_cancelable($0, cancelador) }) else {
                statusDaEspera = quall_last_status()
                ultimoMotivo = Nucleo.ultimoErro()
                return false
            }
            let quantas = quall_session_track_count(nova)
            // Pela **espécie**, e não pela posição: o núcleo guarda a ordem da oferta, mas quem
            // procura a de vídeo não precisa depender disso.
            var t: OpaquePointer?
            var mic: OpaquePointer?
            for i in 0..<quantas {
                guard let candidata = quall_session_track(nova, i) else { continue }
                let especie = quall_track_kind(candidata)
                if especie == tipo, t == nil { t = candidata }
                else if especie == QUALL_TRACK_KIND_MICROPHONE, rotuloDoMicC != nil, mic == nil { mic = candidata }
                // O handle é do chamador (`quall.h`): uma track que ninguém vai usar é liberada já.
                else { quall_track_free(candidata) }
            }
            if t == nil {
                // **A sessão precisa morrer aqui.** Guardá-la e devolver `false` deixaria um
                // ouvinte vivo na porta de sinalização, e o laço de re-hospedar — que é o
                // contorno da dívida 10 — passaria a falhar em **todas** as tentativas
                // seguintes com "Address already in use". Uma falha rara viraria uma falha
                // permanente, e o sintoma ("nunca mais conecta, só reinstalar resolve") não
                // aponta para cá.
                ultimoMotivo = "sessão subiu mas veio com \(quantas) track(s) de saída"
                if let mic { quall_track_free(mic) }
                quall_session_close(nova)
                return false
            }
            travaDoUso.lock()
            sessao = nova
            track = t
            trackDoMicrofone = mic
            travaDoUso.unlock()
            return true
        }
    }

    /// Motivo da última falha, já legível. Quando a fronteira C não diz nada — o caso da sessão
    /// sem track —, esta string é a única testemunha.
    private(set) var ultimoMotivo = ""
    /// O código da última falha (`quall_last_status`, por thread: lido na mesma que chamou).
    /// `QUALL_STATUS_CANCELLED` é o cancelador acionado, e não um erro para a pessoa ler.
    private(set) var statusDaEspera: QuallStatus = QUALL_STATUS_OK

    var porta: UInt16 {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let sessao else { return 0 }
        return quall_session_signaling_port(sessao)
    }

    /// Nome do aparelho do outro lado, para a tela dizer "transmitindo para o MacBook da sala".
    var nomeDoPar: String {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return "" }
        let json = Nucleo.lerTexto { buf, cap in quall_session_peer_json(s, buf, cap) }
        guard let dados = json.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let nome = objeto["display_name"] as? String
        else { return "" }
        return nome
    }

    /// O estado de pareamento atualizado, para a casca persistir.
    ///
    /// Sem gravar isto o usuário digita o PIN de novo a cada sessão, e a promessa do fluxo —
    /// "uma vez por par de aparelhos" — vira mentira. `conhecidos` é o que foi passado em
    /// `hospedar`, para que o resultado some ao que já existia em vez de substituí-lo.
    func paresParaGuardar(somandoA conhecidos: String?) -> String {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return "" }
        if let conhecidos, !conhecidos.isEmpty {
            return conhecidos.withCString { antigos in
                Nucleo.lerTexto { buf, cap in quall_session_known_peers_json(s, antigos, buf, cap) }
            }
        }
        return Nucleo.lerTexto { buf, cap in quall_session_known_peers_json(s, nil, buf, cap) }
    }

    /// Contadores do núcleo, como JSON. **Só no desmonte.**
    ///
    /// Ela segura a `travaDoUso` — a mesma do `send_frame` — durante uma chamada de FFI mais
    /// cerca de 1 KB de JSON. Chamada periodicamente, isso põe o relatório e o envio de quadro
    /// disputando a mesma trava: o relatório bloqueia o envio, e o envio bloqueia o relatório. O
    /// resultado apareceria como quadros perdidos, que é um sintoma bem mais difícil de atribuir
    /// ao instrumento do que um processo morto.
    ///
    /// Por isso o produto a chama **uma vez**, em `broadcastFinished`, depois de a bandeira de
    /// envio já estar baixada e nenhum quadro poder estar em voo. Quem quiser contadores durante
    /// a corrida tem o `.h264` do receptor, que é testemunha externa e não custa nada a este
    /// processo.
    var estatisticasDaTrack: String {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let track else { return "" }
        return Nucleo.lerTexto { buf, cap in quall_track_stats_json(track, buf, cap) }
    }

    /// A sessão tem a track de microfone. Não diz se ela está ligada: isso é do botão.
    var temMicrofone: Bool {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        return trackDoMicrofone != nil
    }

    /// Os contadores do núcleo para a track de microfone. **Só no desmonte**, pelo mesmo motivo de
    /// `estatisticasDaTrack`.
    var estatisticasDoMicrofone: String {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let trackDoMicrofone else { return "" }
        return Nucleo.lerTexto { buf, cap in quall_track_stats_json(trackDoMicrofone, buf, cap) }
    }

    /// Desmonta o que a casca pode desmontar. **Não** chama `quall_cleanup()`.
    ///
    /// A ordem é obrigatória e está no cabeçalho do manipulador: a bandeira de encerramento
    /// primeiro, depois `VTCompressionSessionCompleteFrames` (quem chama), e só então isto —
    /// `quall_track_free` antes de `quall_session_close`, como o header da fronteira exige.
    ///
    /// A dívida 12 diz que `quall_session_close()` não desmonta a sessão quando o par já sumiu:
    /// se existir `mSctpTransport`, ele para o SCTP e volta sem tocar em `closeTransports()`.
    /// Chamamos mesmo assim — é o que a casca pode fazer —, e o degrau 4 mediu o que sobra: a
    /// pegada terminou em 5,23 MB, abaixo de onde a fase de envio começou.
    func encerrar() {
        travaDoUso.lock()
        let t = track, s = sessao, m = trackDoMicrofone
        track = nil
        trackDoMicrofone = nil
        sessao = nil
        travaDoUso.unlock()
        // Fora da trava: `quall_session_close` pode demorar, e quem ainda estivesse tentando
        // enviar já viu `track == nil` e desistiu.
        if let t { quall_track_free(t) }
        if let m { quall_track_free(m) }
        if let s { quall_session_close(s) }
    }

    /// **O handle de mensagens da sessão** (`quall_session_messages`), para a bombeada do controle
    /// remoto da câmera (R9b, `docs/controle-remoto-da-camera.md` §2): numa sessão de vídeo, o leitor
    /// do canal é ela. Libere com `quall_messages_free` (antes ou depois de `encerrar`). `nil` sem
    /// sessão, ou se o núcleo não der o handle.
    func abrirMensagens() -> OpaquePointer? {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return nil }
        return quall_session_messages(s)
    }

    /// **O detector de queda** (`quall_session_next_event`), para quem precisa saber que o receptor
    /// saiu: a tela "Teleprompter com câmera" solta a transmissão do dono da captura e hospeda de
    /// novo, sem fechar a câmera (`docs/teleprompter-com-camera.md` §1.1, G1).
    ///
    /// **Uma thread só**, e ela tem de ser a mesma que chamará `encerrar`: a chamada lê a sessão
    /// fora da trava (espera até `prazoMs`), e um `quall_session_close` de outra thread no meio dela
    /// seria uso depois de liberar. Quem usa isto é o laço de hospedagem de `EmissorDeCamera` no modo
    /// pendurado, que também é o único a encerrar a sessão nesse modo.
    ///
    /// Sem sessão, devolve `DISCONNECTED`: não há nada vivo do outro lado.
    func proximoEvento(prazoMs: UInt32) -> QuallSessionEvent {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return QUALL_SESSION_EVENT_DISCONNECTED }
        return quall_session_next_event(s, prazoMs)
    }

    // --- quadros ----------------------------------------------------------------------------

    /// Lê o pedido de IDR do receptor **uma vez por quadro** e o guarda localmente.
    ///
    /// A leitura é aqui, e não no encoder, porque `quall_track_take_idr_request` consome: quem
    /// lê é dono do pedido e responde por ele. Ignorar um PLI é deixar o receptor sem imagem —
    /// é falha de produto, não detalhe, e o contrato das tracks diz isso com todas as letras.
    func recolherPedidoDeIdr() {
        travaDoUso.lock()
        guard let track else { travaDoUso.unlock(); return }
        let pediu = quall_track_take_idr_request(track)
        travaDoUso.unlock()
        guard pediu else { return }
        travaDoIdr.lock()
        deveIDR = true
        travaDoIdr.unlock()
    }

    var precisaDeIdr: Bool {
        travaDoIdr.lock(); defer { travaDoIdr.unlock() }
        return deveIDR
    }

    /// Levanta a bandeira por conta própria. Usado quando a casca sabe que o fluxo perdeu
    /// continuidade sem que o receptor tenha pedido: encoder recriado por rotação de tela,
    /// volta de `broadcastResumed` depois de uma ligação telefônica.
    func exigirIdr() {
        travaDoIdr.lock(); deveIDR = true; travaDoIdr.unlock()
    }

    /// Só baixa a bandeira quando o encoder **de fato** devolveu um quadro chave. (dívida 15)
    func idrEntregue() {
        travaDoIdr.lock(); deveIDR = false; travaDoIdr.unlock()
    }

    /// `enviar_quadro` do contrato: empacota e solta. O buffer é do chamador e o núcleo não o
    /// guarda.
    @discardableResult
    func enviar(annexb: UnsafeRawBufferPointer, timestampUs: UInt64, idr: Bool) -> Bool {
        // A trava fica segurada durante o `send_frame` inteiro. Ela é curta por construção — o
        // contrato diz que o núcleo empacota e solta, sem fila — e é o que garante que a track
        // não seja liberada no meio do empacotamento.
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let track, let base = annexb.baseAddress else { return false }
        var quadro = QuallFrame(annexb: base.assumingMemoryBound(to: UInt8.self),
                                len: UInt(annexb.count),
                                timestamp_us: timestampUs,
                                idr: idr)
        let estado = withUnsafePointer(to: &quadro) { quall_track_send_frame(track, $0) }
        // Contadores em trava própria, e com aritmética que não estoura: `&+` satura em vez de
        // derrubar o processo. Não é paranoia — foi uma conta de `UInt64` num contador que matou
        // a corrida de 464 s do degrau 4.
        travaDoRelato.lock()
        _ultimoStatus = estado.rawValue
        if estado == QUALL_STATUS_OK { _enviados = _enviados &+ 1 } else { _recusados = _recusados &+ 1 }
        travaDoRelato.unlock()
        return estado == QUALL_STATUS_OK
    }

    /// `enviar_audio` do contrato, na track de microfone: **um** pacote Opus por chamada (o
    /// pacotizador de áudio não fragmenta, `quall.h`). O carimbo é o da captura, no mesmo relógio do
    /// vídeo (`docs/contrato-track.md`, "O relógio do `timestamp_us`"). Sem a track, `false`.
    @discardableResult
    func enviarAudio(_ pacote: UnsafeRawBufferPointer, timestampUs: UInt64) -> Bool {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let trackDoMicrofone, let base = pacote.baseAddress, pacote.count > 0 else { return false }
        var amostra = QuallAudioSample(payload: base.assumingMemoryBound(to: UInt8.self),
                                       len: UInt(pacote.count),
                                       timestamp_us: timestampUs)
        let estado = withUnsafePointer(to: &amostra) { quall_track_send_audio(trackDoMicrofone, $0) }
        travaDoRelato.lock()
        if estado == QUALL_STATUS_OK { _audioEnviados = _audioEnviados &+ 1 } else { _audioRecusados = _audioRecusados &+ 1 }
        travaDoRelato.unlock()
        return estado == QUALL_STATUS_OK
    }

    // --- tradução de erro -------------------------------------------------------------------

    /// O que dizer à pessoa quando `hospedar` volta `false`.
    ///
    /// A fronteira C devolve o `Display` do `Error` do núcleo, cujos prefixos são fixos
    /// (`crates/quall-core/src/error.rs`): `transporte:`, `pareamento:`, `tempo esgotado:`,
    /// `sinalização:`, `e/s:`. Casar por **prefixo** é frágil o suficiente para merecer registro
    /// — a leitura certa seria um código de status distinto, e ele não existe: `quall_host`
    /// devolve ponteiro ou nulo, e o motivo só vive em `quall_last_error()`. Fica anotado como
    /// pedido ao núcleo.
    ///
    /// O caso do ICE tem tratamento próprio porque **está medido**: no iPhone 7, com a permissão
    /// de Rede Local ainda não concedida, `quall_host` volta exatamente com
    /// `transporte: o ICE não achou caminho entre os dois aparelhos`; com ela concedida, o mesmo
    /// binário fecha a sessão e o vídeo atravessa. É o erro mais provável do produto e o mais
    /// fácil de a pessoa consertar sozinha — se alguém disser a ela o que fazer.
    /// Um PIN errado **derruba a espera inteira do emissor**, e o núcleo é explícito: uma
    /// tentativa só, sem "tente de novo". A casca repete a hospedagem, e sem uma frase na tela a
    /// pessoa que apresenta é punida pelo erro de digitação de outra e não fica sabendo que houve
    /// erro. Daí cada texto abaixo nomear **o que aconteceu do outro lado**, e não o código.
    ///
    /// E todos dizem, quando cabe, que **o PIN continua o mesmo**: ele é sorteado uma vez, ao
    /// entrar na espera, e sobrevive a todas as tentativas. Sem essa frase, quem estivesse
    /// olhando a tela ficaria em dúvida se precisa ditar os seis dígitos de novo.
    static func conselho(para erro: String) -> String {
        if erro.contains("o ICE não achou caminho") {
            return tr("Este iPhone não conseguiu falar com a rede local. "
                + "Abra %@ e ligue, depois tente de novo. "
                + "Se já estiver ligada, confira se os dois aparelhos estão na mesma rede Wi‑Fi.",
                trSistema("Ajustes → Quall Studio → Rede Local"))
        }
        // **O beco sem saída da dívida 22, e a única frase que dá saída dele.**
        //
        // O outro aparelho mandou `Resume` — ele acha que já pareou com este —, e este não
        // reconhece. O núcleo recusa e **nunca cai de volta para o caminho do PIN**: não há
        // "então digite o PIN", e não há API para esquecer um par. Sem esta frase, a pessoa vive
        // "funcionou ontem, hoje não funciona" sem nada para tentar.
        //
        // Isso deixa de ser hipótese porque o `pares.json` tem dois escritores (dívida 23): uma
        // atualização perdida deixa os dois lados com segredos diferentes para a mesma chave.
        if EstadoDeParConhecido.ehParDesconhecido(erro) {
            return tr("O outro aparelho acha que já está pareado com este, mas este não o reconhece "
                + "mais. Toque em “%@” e peça para ele entrar de novo "
                + "digitando o PIN.", tr("Esquecer aparelhos pareados"))
        }
        if erro.hasPrefix("pareamento:") {
            return tr("Alguém tentou entrar e errou o PIN. "
                + "O PIN continua o mesmo — peça para conferir os seis dígitos e tentar de novo.")
        }
        if erro.hasPrefix("protocolo:") {
            return tr("Alguém tentou entrar com uma versão diferente do Quall. "
                + "Atualize o app nos dois aparelhos.")
        }
        if erro.hasPrefix("tempo esgotado:") {
            return tr("Ninguém entrou ainda. Deixe esta tela aberta e conecte pelo outro aparelho.")
        }
        if erro.hasPrefix("e/s:") {
            return tr("A porta de rede está ocupada. "
                + "Feche uma transmissão anterior que talvez ainda esteja no ar e tente de novo.")
        }
        if erro.contains("a outra ponta fechou") || erro.hasPrefix("sinalização:") {
            return tr("Alguém abriu a conexão e desistiu antes de terminar. "
                + "O PIN continua o mesmo — dá para tentar de novo.")
        }
        if erro.hasPrefix("transporte:") {
            return tr("A conexão com o outro aparelho caiu. "
                + "O PIN continua o mesmo — dá para tentar de novo.")
        }
        return tr("Não foi possível iniciar a transmissão.")
    }

    // --- utilidade --------------------------------------------------------------------------

    /// O padrão `(buf, cap)` da fronteira C, **perguntando o tamanho primeiro**.
    ///
    /// # Por que não um buffer fixo, por maior que seja
    ///
    /// `escrever_texto` (`crates/quall-ffi/src/lib.rs`) devolve **o tamanho necessário em todos os
    /// casos de sucesso** — tanto quando escreveu quanto quando não coube. Quando não cabe, ele
    /// **não escreve nada**. Logo `escritos > 0` é verdadeiro nos dois casos, e um buffer fixo com
    /// um teste de `> 0` devolve **string vazia em silêncio** assim que o conteúdo passa do
    /// tamanho escolhido.
    ///
    /// Isto não é hipótese: a versão anterior desta função pedia 4 KB, e a versão irmã no macOS
    /// pedia 256 bytes. Em 26/08/2026 o `pares.json` do Mac passou de 256 bytes e **o pareamento
    /// parou de ser gravado** — o usuário voltou a digitar o PIN toda vez, e ninguém ligou uma
    /// coisa à outra até 30/08. Aquele arquivo hoje tem 10.193 bytes, o que já teria estourado
    /// também os 4 KB daqui. O comentário que este substitui dizia, corretamente, que "truncá-lo
    /// em silêncio apagaria pareamentos" — e escolhia um número maior em vez do padrão certo.
    ///
    /// O padrão certo é o que `Receber/NucleoReceptor.swift` já usava neste mesmo app: chamar com
    /// `(nil, 0)`, que o núcleo trata como pergunta, e alocar exatamente o que ele pedir. O
    /// tamanho devolvido **já inclui o NUL final**.
    private static func lerTexto(_ chamada: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String {
        let precisa = chamada(nil, 0)
        guard precisa > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: precisa)
        let escritos = buffer.withUnsafeMutableBufferPointer { p -> Int in
            chamada(p.baseAddress, UInt(p.count))
        }
        guard escritos > 0, escritos <= precisa else { return "" }
        return String(cString: buffer)
    }
}

/// Reconhece, na mensagem crua do núcleo, o caso em que **desparear é a ação certa**.
///
/// Casar por texto é frágil e fica registrado como tal — a leitura certa seria um código de status
/// na fronteira C, que não existe: `quall_host` devolve ponteiro ou nulo e o motivo só vive em
/// `quall_last_error()`. Está no pedido ao núcleo, junto com o do ICE.
///
/// São **quatro** frases, e não uma, porque o iPhone é o anfitrião e o `pairing.rs` recusa a
/// retomada em quatro pontos diferentes:
///
/// | frase | o que aconteceu |
/// |---|---|
/// | `aparelho X não está pareado aqui` | este lado não tem segredo nenhum guardado |
/// | `segredo carregado é do aparelho A, não de B` | tem segredo, de outro aparelho |
/// | `prova de retomada inválida` | **os dois lados têm segredos diferentes** — o caso da dívida 23 |
/// | `o aparelho do outro lado não é o que foi pareado` | o mesmo, visto do lado do convidado |
///
/// A terceira é a que importa: é exatamente o resultado de uma atualização perdida no
/// `pares.json`, e é a que a mensagem genérica de "errou o PIN" mandaria a pessoa conferir seis
/// dígitos que ninguém digitou.
enum EstadoDeParConhecido {
    static func ehParDesconhecido(_ erro: String) -> Bool {
        erro.contains("não está pareado aqui")
            || erro.contains("segredo carregado é do aparelho")
            || erro.contains("prova de retomada inválida")
            || erro.contains("não é o que foi pareado")
    }
}
