import Foundation

/// Casca do **receptor** sobre a fronteira C. É o que `apps/ios` não tinha: `apps/ios/Quall`
/// inteiro chama `quall_host` e nunca `quall_connect`, e por isso as linhas **Android → iOS**,
/// **MacBook → iOS** e **Windows → iOS** da matriz obrigatória não tinham lado que recebe.
///
/// O desenho é o do receptor Android (`ReceptorSessao.kt`), que foi escrito e provado em aparelho
/// em 2026-08-26, com três diferenças que a plataforma obriga e uma que o núcleo permitiu:
///
/// 1. **O tratador de quadro é usado, e não a bandeira.** No Android o header recomenda
///    `quall_track_take_idr_request` porque as threads da libdatachannel não estão anexadas à JVM
///    e chamar de volta para o Kotlin exige `AttachCurrentThread`. Em Swift não há JVM: o tratador
///    de `quall_track_on_frame` é um `@convention(c)` que só toca num objeto retido, e essa é a
///    forma barata aqui. (A bandeira de IDR é do outro sentido — do receptor para o emissor — e
///    não se aplica a este lado.)
/// 2. **A caixa é liberada de verdade.** O receptor de câmera do macOS
///    (`integrations/camera-macos`) retém a caixa **para sempre**, com um comentário dizendo que
///    isso deixou de ser preço de segurança e virou vazamento puro quando a dívida 24 foi paga em
///    2026-08-26. Aqui a barreira é usada como ela ficou: a caixa só é liberada depois de
///    `quall_track_on_frame(t, NULL, NULL)` **ou** `quall_session_close(s)` devolverem
///    `QUALL_STATUS_OK`. Se nenhum dos dois der OK, ela vaza de propósito e diz que vazou.
/// 3. **A ramificação é pelo código, não pelo texto.** `quall_last_status()` existe desde
///    2026-08-26 (dívida 27). O `Nucleo` do emissor iOS ainda compara prefixo de string em
///    português e registra isso como pedido ao núcleo; aqui não há nenhuma comparação de texto.
///    `QUALL_STATUS_NEEDS_PIN` é tratado como o header manda: convite a mostrar a tela do PIN, não
///    "falhou".
/// 4. **Nada de `quall_cleanup()`.** Mesma decisão do emissor iOS e do Android: ele espera 10 s,
///    desiste e deixa uma thread de limpeza presa.
///
/// ## Uma thread só toca a fronteira, e a interface nunca toca em handle
///
/// `quall_session_next_track` e `quall_session_next_event` **avançam estado** e o header exige que
/// venham de uma thread só. Aqui vêm as duas do mesmo laço. A interface tem exatamente um caminho
/// para interferir — [`parar()`] —, que levanta uma bandeira e, atrás de uma trava, aciona o
/// cancelador. Nenhum ponteiro de sessão ou de track sai desta classe.
final class NucleoReceptor {

    /// O `user_data` do tratador de quadro. Um objeto retido cujo endereço atravessa a fronteira C.
    ///
    /// A bandeira `vivo` **não** é substituta da barreira — ela é o cinto de segurança para o caso
    /// em que a barreira falha (`QUALL_STATUS_TIMEOUT`, tratador que não voltou) e a caixa precisa
    /// continuar de pé. Com a barreira dando OK, ela nem chega a ser lida.
    final class Caixa {
        let aoQuadro: (UnsafeRawBufferPointer, UInt64, Bool) -> Void
        private let trava = NSLock()
        private var _vivo = true

        init(aoQuadro: @escaping (UnsafeRawBufferPointer, UInt64, Bool) -> Void) {
            self.aoQuadro = aoQuadro
        }

        var vivo: Bool {
            trava.lock(); defer { trava.unlock() }
            return _vivo
        }

        func desligar() { trava.lock(); _vivo = false; trava.unlock() }
    }

    /// O `user_data` do tratador de **slot de áudio**. Gêmeo da [`Caixa`], com a mesma bandeira e
    /// a mesma disciplina — e separada de propósito: são dois `user_data` independentes, com duas
    /// barreiras independentes (`quall_track_on_frame` e `quall_track_on_audio`), e uma delas pode
    /// falhar sem a outra. Uma caixa só, compartilhada, faria a barreira que deu OK autorizar a
    /// liberação de memória que a outra ainda pode estar usando.
    final class CaixaDeAudio {
        let aoSlot: (QuallAudioOrder, UnsafeRawBufferPointer?, UInt16, UInt64, Int8) -> Void
        private let trava = NSLock()
        private var _vivo = true

        init(aoSlot: @escaping (QuallAudioOrder, UnsafeRawBufferPointer?, UInt16, UInt64, Int8) -> Void) {
            self.aoSlot = aoSlot
        }

        var vivo: Bool {
            trava.lock(); defer { trava.unlock() }
            return _vivo
        }

        func desligar() { trava.lock(); _vivo = false; trava.unlock() }
    }

    // --- estado ------------------------------------------------------------------------------

    /// Ponteiros da fronteira C. Só o laço de recepção os toca; a trava existe porque
    /// `pegadaDeMemoria`-style leituras de contador e o `encerrar()` podem vir de outra thread, e
    /// a regra do projeto é **nunca chamar a API C com um id que possa estar morto**.
    private let travaDoUso = NSLock()
    private var sessao: OpaquePointer?
    private var track: OpaquePointer?
    private var caixa: Caixa?
    private var opacoDaCaixa: UnsafeMutableRawPointer?

    /// A segunda track: a de **áudio**, quando o emissor abre uma.
    ///
    /// Duas variáveis e não um dicionário por espécie porque são exatamente duas e cada uma tem
    /// uma fronteira diferente: a de vídeo usa `quall_track_on_frame` e responde a `request_idr`;
    /// a de áudio usa `quall_track_on_audio` e **não** responde — `pedir_idr()` numa track de
    /// áudio é `Error::Invalid`, bloqueado no núcleo, porque não existe quadro-chave de áudio.
    private var trackDeAudio: OpaquePointer?
    private var caixaDeAudio: CaixaDeAudio?
    private var opacoDaCaixaDeAudio: UnsafeMutableRawPointer?

    /// O cancelador vive numa trava própria e é zerado assim que a chamada bloqueante volta —
    /// depois disso `parar()` age só pela bandeira, e nunca com um handle já liberado.
    private let travaDoCancelador = NSLock()
    private var cancelador: OpaquePointer?

    private var vivas: [UnsafeMutablePointer<CChar>] = []

    /// Bandeira de desistência. `volatile` em Swift é uma leitura sob trava; aqui uma
    /// `NSLock` por volta de laço custa nada perto de um `next_event`.
    private let travaDaParada = NSLock()
    private var _parar = false
    var parou: Bool {
        travaDaParada.lock(); defer { travaDaParada.unlock() }
        return _parar
    }

    private(set) var ultimoMotivo = ""
    private(set) var ultimoStatus: QuallStatus = QUALL_STATUS_OK

    // --- utilidade ---------------------------------------------------------------------------

    static func versaoDoProtocolo() -> UInt16 { quall_protocol_version() }

    static func ultimoErro() -> String {
        guard let p = quall_last_error() else { return "" }
        return String(cString: p)
    }

    /// Nome legível de um status, para o relato. Sem `default` silencioso: um código novo no
    /// núcleo aparece como número em vez de virar "desconhecido" e sumir.
    static func nome(_ s: QuallStatus) -> String {
        switch s {
        case QUALL_STATUS_OK: return "OK"
        case QUALL_STATUS_INVALID: return "INVALID"
        case QUALL_STATUS_PROTOCOL: return "PROTOCOL"
        case QUALL_STATUS_DISCOVERY: return "DISCOVERY"
        case QUALL_STATUS_SIGNALING: return "SIGNALING"
        case QUALL_STATUS_TRANSPORT: return "TRANSPORT"
        case QUALL_STATUS_PAIRING: return "PAIRING"
        case QUALL_STATUS_TIMEOUT: return "TIMEOUT"
        case QUALL_STATUS_CLOSED: return "CLOSED"
        case QUALL_STATUS_IO: return "IO"
        case QUALL_STATUS_NULL_POINTER: return "NULL_POINTER"
        case QUALL_STATUS_NOT_UTF8: return "NOT_UTF8"
        case QUALL_STATUS_NO_ROUTE: return "NO_ROUTE"
        case QUALL_STATUS_NEEDS_PIN: return "NEEDS_PIN"
        case QUALL_STATUS_CANCELLED: return "CANCELLED"
        default: return "código \(s.rawValue)"
        }
    }

    private func guardar(_ texto: String) -> UnsafeMutablePointer<CChar> {
        let copia = strdup(texto) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
        vivas.append(copia)
        return copia
    }

    deinit {
        encerrar()
        for p in vivas { free(p) }
    }

    // --- conectar ----------------------------------------------------------------------------

    /// Conecta no emissor. **Bloqueia** até parear e o transporte subir, ou o prazo estourar.
    /// Chame de uma thread de trabalho.
    ///
    /// O cancelador é criado **antes** de largar a thread, como o header pede, para que
    /// [`parar()`] tenha o que acionar durante a espera inteira. Sem ele a única saída era o
    /// contorno que Android e iOS escreveram cada um por sua conta: abrir uma conexão TCP
    /// descartável para o próprio endereço só para o `accept` voltar.
    /// `tela`: os pixels do painel deste aparelho, ditos ao emissor no aperto de mão
    /// (`quall_connect_with_screen`). `(0, 0)` é "não digo". A tela estendida do Mac usa isso para o
    /// formato do monitor que cria para este aparelho.
    func conectar(endereco: String,
                  pin: String?,
                  deviceId: String,
                  nome: String,
                  paresConhecidos: String?,
                  prazoMs: UInt32,
                  tela: (largura: UInt32, altura: UInt32) = (0, 0)) -> Bool {
        let idC = guardar(deviceId)
        let nomeC = guardar(nome)
        let enderecoC = guardar(endereco)
        let pinC: UnsafeMutablePointer<CChar>? = pin.map { guardar($0) }
        let paresC: UnsafeMutablePointer<CChar>? = paresConhecidos.map { guardar($0) }

        let novoCancelador = quall_canceller_new()
        travaDoCancelador.lock()
        cancelador = novoCancelador
        travaDoCancelador.unlock()
        // Parar pode ter acontecido antes de existir o handle. Não perde esse pedido.
        if parou, let novoCancelador { quall_session_cancel(novoCancelador) }

        var opcoes = QuallSessionOptions(
            me: QuallDeviceDesc(device_id: idC,
                                display_name: nomeC,
                                // Este aparelho, nesta sessão, é **sumidouro**: ele exibe, não
                                // transmite. É o oposto exato do que `apps/ios/Quall` declara.
                                screen_source: false,
                                camera_source: false,
                                sink: true),
            pin: pinC.map { UnsafePointer($0) },
            known_peers_json: paresC.map { UnsafePointer($0) },
            // Só vale em `quall_host`. Um receptor não abre porta de sinalização.
            signaling_port: 0,
            timeout_ms: prazoMs,
            // Só vale em `quall_host`. As tracks que interessam aqui vêm do outro lado, por
            // `quall_session_next_track`.
            tracks: nil,
            track_count: 0,
            // Só a casca que **conecta** pede o cabo, e nenhuma tela do iOS oferece isso ainda:
            // `nil` mantém o comportamento de sempre, com o ICE reunindo toda interface. Ver
            // `QuallSessionOptions::bind_address` e `docs/quall-pelo-cabo.md`.
            bind_address: nil)

        // Fora de qualquer trava: a chamada bloqueia por dezenas de segundos e nada mais pode
        // ficar pendurado nela — inclusive o `parar()` da interface, que é quem a destrava.
        let nova = withUnsafePointer(to: &opcoes) {
            quall_connect_with_screen(enderecoC, $0, novoCancelador, tela.largura, tela.altura)
        }

        // O cancelador some da vista assim que a chamada volta. Daqui em diante `parar()` age só
        // pela bandeira, e nunca com um handle já liberado.
        travaDoCancelador.lock()
        cancelador = nil
        travaDoCancelador.unlock()

        guard let nova else {
            // A regra de leitura do header: logo depois da chamada que falhou, antes de qualquer
            // outra função `quall_`, e só porque ela de fato devolveu nulo.
            ultimoStatus = quall_last_status()
            ultimoMotivo = NucleoReceptor.ultimoErro()
            quall_canceller_free(novoCancelador)
            return false
        }
        quall_canceller_free(novoCancelador)

        travaDoUso.lock()
        sessao = nova
        travaDoUso.unlock()
        return true
    }

    /// Levanta a bandeira e, se houver espera em curso, aciona o cancelador. Chamável de qualquer
    /// thread — e **não** toca em handle de sessão, de track nem na caixa.
    func parar() {
        travaDaParada.lock(); _parar = true; travaDaParada.unlock()
        travaDoCancelador.lock()
        if let c = cancelador { quall_session_cancel(c) }
        travaDoCancelador.unlock()
    }

    // --- track -------------------------------------------------------------------------------

    /// Pega **uma** track e a arquiva pela espécie, não pela ordem de chegada.
    ///
    /// # Por que a classificação existe agora e não existia antes
    ///
    /// A versão anterior pegava a primeira track que aparecesse e chamava de "a track", com o
    /// comentário honesto de que compor várias era trabalho para depois de uma existir. Isso
    /// funcionava porque **nenhuma casca do projeto mandava áudio para o iOS**. Com o lado que
    /// exibe passando a tocar som, uma sessão pode trazer duas — e a ordem em que elas saem do
    /// `quall_session_next_track` não é contrato nenhum.
    ///
    /// Chamar `quall_track_on_frame` numa track de áudio seria o defeito silencioso desta porta:
    /// o header diz que ela é de vídeo, e nada no caminho reclamaria. Por isso a espécie decide o
    /// destino, e o `default` não existe — uma espécie nova aparece como `nil` e no relato, em vez
    /// de virar vídeo por acidente.
    ///
    /// `prazoMs` zero é uma espiada: devolve o que já estiver pronto e volta. É como o laço de
    /// supervisão procura a track de áudio sem gastar volta nenhuma.
    @discardableResult
    func adotarProximaTrack(prazoMs: UInt32) -> (rotulo: String, tipo: QuallTrackKind)? {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return nil }

        let limite = Medidas.agoraUs() &+ UInt64(prazoMs) &* 1000
        var achada: OpaquePointer?
        // Uma espiada com prazo zero ainda precisa de **uma** chamada: sem ela um `prazoMs: 0`
        // nunca perguntaria nada e a track de áudio jamais seria adotada.
        repeat {
            if let t = quall_session_next_track(s, prazoMs == 0 ? 0 : 200) { achada = t; break }
        } while !parou && Medidas.agoraUs() < limite
        guard let t = achada else { return nil }

        // **Pergunta o tamanho antes.** Era um buffer fixo de 256 bytes lido como sucesso quando
        // o retorno era positivo — e um retorno maior que a capacidade também é positivo, com o
        // buffer intocado. O rótulo vem do SDP do emissor e carrega o nome que a outra ponta
        // escolheu; teto nenhum aqui é nosso.
        let rotulo = NucleoReceptor.comBuffer { buf, cap in quall_track_label(t, buf, cap) } ?? ""
        let tipo = quall_track_kind(t)

        travaDoUso.lock()
        switch tipo {
        case QUALL_TRACK_KIND_SCREEN, QUALL_TRACK_KIND_CAMERA:
            // Uma segunda track de vídeo na mesma sessão não é o desenho do produto (a origem é
            // fixa pela sessão) e não há como compô-la. Larga e diz.
            if track == nil { track = t } else { travaDoUso.unlock(); quall_track_free(t)
                Diario.dizer("!! segunda track de vídeo descartada: a origem é fixa pela sessão")
                return nil }
        case QUALL_TRACK_KIND_MICROPHONE, QUALL_TRACK_KIND_SYSTEM_AUDIO:
            if trackDeAudio == nil { trackDeAudio = t; audioAdotada = (rotulo, tipo) } else {
                travaDoUso.unlock(); quall_track_free(t)
                Diario.dizer("!! segunda track de áudio descartada: só uma é tocada")
                return nil }
        default:
            travaDoUso.unlock()
            quall_track_free(t)
            Diario.dizer("!! espécie de track desconhecida (\(tipo.rawValue)) — descartada")
            return nil
        }
        travaDoUso.unlock()
        return (rotulo, tipo)
    }

    /// Espera a track de **vídeo**, arquivando pelo caminho qualquer track de áudio que apareça
    /// antes dela.
    ///
    /// Manter este nome e esta assinatura é de propósito: `SessaoDeRecepcao` já dependia deles, e
    /// o comportamento observável para o vídeo é idêntico ao de antes numa sessão que só tem
    /// vídeo — que é toda sessão que este projeto já mediu.
    func esperarTrack(prazoMs: UInt32) -> (rotulo: String, tipo: QuallTrackKind)? {
        var limite = Medidas.agoraUs() &+ UInt64(prazoMs) &* 1000
        while !parou, Medidas.agoraUs() < limite {
            guard let achada = adotarProximaTrack(prazoMs: 200) else { continue }
            switch achada.tipo {
            case QUALL_TRACK_KIND_SCREEN, QUALL_TRACK_KIND_CAMERA:
                return achada
            default:
                // Áudio chegou primeiro. Já está arquivado; continua esperando o vídeo — mas por
                // **três segundos**, e não pelo prazo inteiro.
                //
                // As duas tracks saem da mesma oferta SDP e do mesmo `quall_session_next_track`;
                // se a de vídeo existisse, ela viria em milissegundos, não em quinze segundos.
                // Esperar o prazo cheio custava, na primeira corrida do laço de áudio em 30/08,
                // 15 s dos 25 s da corrida — e o que se ganhava era zero: a track de vídeo não
                // vem depois de a de áudio ter vindo se ela não estava na oferta.
                Diario.dizer("track de áudio adotada antes do vídeo"
                             + " — 3 s para o vídeo aparecer, senão a sessão é só de som")
                let curto = Medidas.agoraUs() &+ 3_000_000
                if curto < limite { limite = curto }
            }
        }
        return nil
    }

    var temTrackDeAudio: Bool {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        return trackDeAudio != nil
    }

    /// O codec adotado do SDP desta track. DEFAULT nesta consulta significa "não sei";
    /// transformar isso em Opus reproduziria o defeito Mac (PCMU) → iOS.
    func codecDeAudio() -> QuallAudioCodec? {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let t = trackDeAudio else { return nil }
        let codec = quall_track_audio_codec(t)
        return codec == QUALL_AUDIO_CODEC_DEFAULT ? nil : codec
    }

    /// Rótulo e espécie da track de áudio adotada, quando houver.
    ///
    /// Existe porque `esperarTrack` **adota** o áudio que chega antes do vídeo e devolve `nil`
    /// enquanto vídeo não vem: sem isto, uma sessão que traz **só** áudio ficava com a track viva
    /// dentro do núcleo e ninguém do lado de fora sabia o rótulo dela para montar o caminho do
    /// som. Foi exatamente o que aconteceu na primeira corrida do laço de áudio, em 30/08 — o log
    /// dizia "track de áudio adotada antes do vídeo" e, 15 s depois, "conectou mas não abriu
    /// nenhuma track de mídia".
    private(set) var audioAdotada: (rotulo: String, tipo: QuallTrackKind)?

    /// Registra o tratador de slot de áudio. Mesmas regras do de quadro: **roda numa thread da
    /// libdatachannel** e não pode bloquear.
    ///
    /// O `payload` do slot aponta para dentro do buffer do núcleo e **vale só durante a chamada**.
    /// O tratador desta casca entrega direto ao decodificador negociado, que copia para PCM — nada é
    /// guardado, e por isso não há cópia aqui.
    func ouvirAudio(_ tratador: @escaping (QuallAudioOrder, UnsafeRawBufferPointer?, UInt16, UInt64, Int8) -> Void) -> QuallStatus {
        travaDoUso.lock()
        let t = trackDeAudio
        travaDoUso.unlock()
        guard let t else { return QUALL_STATUS_CLOSED }

        let nova = CaixaDeAudio(aoSlot: tratador)
        let opaco = Unmanaged.passRetained(nova).toOpaque()

        let estado = quall_track_on_audio(t, { slot, dados in
            guard let slot, let dados else { return }
            let caixa = Unmanaged<CaixaDeAudio>.fromOpaque(dados).takeUnretainedValue()
            guard caixa.vivo else { return }
            let s = slot.pointee
            // `SILENCE` chega com `payload` nulo e `len` 0 — por contrato, e é o caso normal de
            // um buraco. Não é falha e não pode ser filtrado como se fosse: o decodificador
            // precisa ser chamado assim mesmo, para a ocultação de perda produzir os 20 ms.
            let bytes: UnsafeRawBufferPointer? = (s.payload != nil && s.len > 0)
                ? UnsafeRawBufferPointer(start: s.payload, count: Int(s.len))
                : nil
            caixa.aoSlot(s.order, bytes, s.sequence, s.timestamp_us, s.fec_has_lbrr)
        }, opaco)

        if estado == QUALL_STATUS_OK {
            travaDoUso.lock()
            caixaDeAudio = nova
            opacoDaCaixaDeAudio = opaco
            travaDoUso.unlock()
        } else {
            Unmanaged<CaixaDeAudio>.fromOpaque(opaco).release()
        }
        return estado
    }

    /// Contadores da track de áudio, como JSON. `jitter_us` só existe aqui — em vídeo o núcleo
    /// nunca o calcula, e o header avisa que `null` quer dizer **não medido**, não zero.
    func contadoresDeAudio() -> String {
        travaDoUso.lock()
        let t = trackDeAudio
        travaDoUso.unlock()
        guard let t else { return "{}" }
        return NucleoReceptor.comBuffer { buf, cap in quall_track_stats_json(t, buf, cap) } ?? "{}"
    }

    /// Registra o tratador de quadro. **Roda numa thread da libdatachannel**: quem escreve o
    /// corpo dele não pode bloquear — bloquear ali segura a recepção da sessão inteira, e a
    /// barreira do `close` desiste depois de 2 s e devolve `QUALL_STATUS_TIMEOUT`.
    ///
    /// O `annexb` do quadro aponta para o buffer de remontagem do núcleo e vale **só durante a
    /// chamada**. O tratador desta frente entrega direto ao decodificador, sem copiar.
    func ouvirQuadros(_ tratador: @escaping (UnsafeRawBufferPointer, UInt64, Bool) -> Void) -> QuallStatus {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return QUALL_STATUS_CLOSED }

        let nova = Caixa(aoQuadro: tratador)
        let opaco = Unmanaged.passRetained(nova).toOpaque()

        let estado = quall_track_on_frame(t, { quadro, dados in
            guard let quadro, let dados else { return }
            let caixa = Unmanaged<Caixa>.fromOpaque(dados).takeUnretainedValue()
            guard caixa.vivo else { return }
            let q = quadro.pointee
            guard let bytes = q.annexb, q.len > 0 else { return }
            caixa.aoQuadro(UnsafeRawBufferPointer(start: bytes, count: Int(q.len)),
                           q.timestamp_us, q.idr)
        }, opaco)

        if estado == QUALL_STATUS_OK {
            travaDoUso.lock()
            caixa = nova
            opacoDaCaixa = opaco
            travaDoUso.unlock()
        } else {
            // Nunca chegou a ser `user_data` de ninguém: pode ir embora agora, sem barreira.
            Unmanaged<Caixa>.fromOpaque(opaco).release()
        }
        return estado
    }

    /// `pedir_idr()` do contrato: emite PLI.
    ///
    /// Devolve erro enquanto a track não abriu, e o header diz que insistir por alguns
    /// milissegundos é o comportamento certo. Quem insiste é o laço; esta função só repassa o
    /// status, porque engolir o erro aqui seria reproduzir, do lado do receptor, o defeito que o
    /// contrato existe para evitar.
    @discardableResult
    func pedirIdr() -> QuallStatus {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return QUALL_STATUS_CLOSED }
        return quall_track_request_idr(t)
    }

    /// Só na thread da sessão. A guarda da reprodução não altera o tempo capturado no arquivo.
    func deslocamentosBrutos() -> (video: Int64?, audio: Int64?) {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        func ler(_ t: OpaquePointer?) -> Int64? {
            guard let t else { return nil }
            var valor: Int64 = 0, guarda: Int32 = 0
            return quall_track_capture_offset_raw_us(t, &valor, &guarda) == 1 ? valor : nil
        }
        return (ler(track), ler(trackDeAudio))
    }

    /// **O caminho de volta do sinal**: conta ao emissor o que este receptor viu numa janela.
    ///
    /// Os cinco números são **deltas da janela**, nunca acumulados — quem escuta o enlace precisa
    /// da derivada, não da integral. `pacotes` é o que o **emissor** mandou (`vistos + perdidos`):
    /// dividir pelo que chegou já inverteu a conclusão de uma frente inteira desta bancada.
    ///
    /// O header exige que isto seja chamado **da mesma thread** que chama
    /// `quall_session_next_event`, porque a fronteira não põe cadeado na sinalização. No receptor
    /// iOS essa thread é o laço de `correr`, e é de lá que ele sai.
    ///
    /// Falhar aqui não para nada: um emissor de versão anterior descarta a mensagem sozinho, e
    /// socket morto aparece no detector de queda que já existe.
    func relatarEnlace(ms: UInt64, pacotes: UInt64, perdidos: UInt64,
                       suspeitos: UInt64, idrsQuebrados: UInt64,
                       naoEntregues: UInt64 = 0) -> QuallStatus {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return QUALL_STATUS_CLOSED }
        return quall_session_report_link(
            s, ms, pacotes, perdidos, suspeitos, idrsQuebrados, naoEntregues)
    }

    /// **O handle de mensagens da sessão** (`quall_session_messages`), para a bombeada do controle
    /// remoto da câmera (R9b). Libere com `quall_messages_free`, antes ou depois de `encerrar`.
    func abrirMensagens() -> OpaquePointer? {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return nil }
        return quall_session_messages(s)
    }

    /// O detector de queda. Chame do **mesmo** laço do `esperarTrack`, com prazo pequeno.
    func evento(prazoMs: UInt32) -> QuallSessionEvent {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return QUALL_SESSION_EVENT_FAILED }
        return quall_session_next_event(s, prazoMs)
    }

    // --- o que o núcleo sabe ------------------------------------------------------------------

    var nomeDoPar: String {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return "" }
        let json = NucleoReceptor.comBuffer { buf, cap in quall_session_peer_json(s, buf, cap) } ?? ""
        guard let dados = json.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let nome = objeto["display_name"] as? String
        else { return "" }
        return nome
    }

    func pareamentoNovo() -> Bool {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return false }
        return quall_session_pairing_is_new(s)
    }

    func paresConhecidos(base: String?) -> String? {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return nil }
        return NucleoReceptor.comBuffer { buf, cap in
            if let base { return base.withCString { quall_session_known_peers_json(s, $0, buf, cap) } }
            return quall_session_known_peers_json(s, nil, buf, cap)
        }
    }

    /// Contadores da track, como JSON. **Diferente do emissor, aqui dá para ler durante a
    /// corrida.**
    ///
    /// O `Nucleo` do emissor iOS documenta que ler contadores periodicamente põe o relatório e o
    /// `send_frame` disputando a mesma trava, e por isso só lê no desmonte. Aqui não existe
    /// `send_frame`: o caminho do quadro é o **tratador**, que roda numa thread da libdatachannel
    /// e não passa por `travaDoUso` em lugar nenhum. Ler contador segura esta trava por uma
    /// chamada de FFI e nada mais, e não atravessa o caminho do quadro.
    /// Quantos quadros o núcleo descartou por estarem incompletos — cada um é uma ruptura da
    /// cadeia de referência. Lido a cada volta do laço, e por isso não passa por JSON.
    func quadrosDescartados() -> UInt64 {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return 0 }
        return quall_track_frames_dropped(t)
    }

    func contadores() -> String {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return "{}" }
        return NucleoReceptor.comBuffer { buf, cap in quall_track_stats_json(t, buf, cap) } ?? "{}"
    }

    // --- desmonte ----------------------------------------------------------------------------

    /// Desmonta na ordem que o header exige, e libera a caixa **só** quando a barreira autoriza.
    ///
    /// Nunca chame de dentro do tratador de quadro: a fronteira recusa a espera com
    /// `QUALL_STATUS_INVALID` em vez de pendurar o processo, e a barreira não vale.
    ///
    /// Devolve o que aconteceu, para o relato poder dizer a verdade sobre a caixa.
    @discardableResult
    func encerrar() -> (desregistro: QuallStatus?, fechamento: QuallStatus?, caixaLiberada: Bool) {
        travaDoUso.lock()
        let t = track
        let ta = trackDeAudio
        let s = sessao
        let c = caixa
        let ca = caixaDeAudio
        let opaco = opacoDaCaixa
        let opacoA = opacoDaCaixaDeAudio
        track = nil
        trackDeAudio = nil
        sessao = nil
        caixa = nil
        caixaDeAudio = nil
        opacoDaCaixa = nil
        opacoDaCaixaDeAudio = nil
        travaDoUso.unlock()

        guard t != nil || ta != nil || s != nil else { return (nil, nil, false) }

        // 1. Desligar o tratador **com barreira**. Só `OK` autoriza liberar a caixa.
        var desregistro: QuallStatus?
        if let t, opaco != nil {
            desregistro = quall_track_on_frame(t, nil, nil)
        }
        // O cinto de segurança, para o caso de a barreira ter falhado.
        c?.desligar()

        // 1b. **O áudio é desligado primeiro, e a razão está no header.**
        //
        // `quall_track_on_audio(t, NULL, NULL)` **escoa o jitter buffer antes de voltar**: os
        // slots ainda retidos são entregues chamando o tratador antigo, desta thread. São os
        // últimos 40 ms da sessão — que atravessaram a rede e, sem isso, sumiriam sem ninguém
        // saber de onde. O tratador ainda está de pé neste instante, então a saída de áudio
        // precisa continuar viva até esta chamada voltar; quem a fecha é o `SessaoDeRecepcao`,
        // **depois** do `encerrar()`, pela mesma razão que o decodificador de vídeo já era
        // fechado depois.
        var desregistroDeAudio: QuallStatus?
        if let ta, opacoA != nil {
            desregistroDeAudio = quall_track_on_audio(ta, nil, nil)
        }
        ca?.desligar()

        // 2. As tracks vão embora **antes** da sessão, como o header manda.
        if let t { quall_track_free(t) }
        if let ta { quall_track_free(ta) }

        // 3. `quall_session_close` também é barreira: se o desregistro falhou, ela ainda pode
        //    autorizar. Fora da trava — ela pode demorar, e quem quisesse tocar num handle já viu
        //    `nil` e desistiu.
        var fechamento: QuallStatus?
        if let s { fechamento = quall_session_close(s) }

        var liberada = false
        if let opaco {
            if desregistro == QUALL_STATUS_OK || fechamento == QUALL_STATUS_OK {
                Unmanaged<Caixa>.fromOpaque(opaco).release()
                liberada = true
            }
            // Senão a caixa **vaza de propósito**: alguns bytes perdidos é preço baixo perto de um
            // tratador escrevendo em memória liberada. Quem relata diz que vazou.
        }
        // A caixa de áudio tem barreira própria e é julgada por ela — **não** pela do vídeo. Duas
        // barreiras independentes: uma pode dar `TIMEOUT` sem a outra, e liberar as duas porque
        // uma autorizou seria exatamente o defeito que a barreira existe para impedir.
        if let opacoA {
            if desregistroDeAudio == QUALL_STATUS_OK || fechamento == QUALL_STATUS_OK {
                Unmanaged<CaixaDeAudio>.fromOpaque(opacoA).release()
            } else {
                Diario.dizer("!! caixa de áudio VAZADA de propósito: on_audio(NULL)="
                             + (desregistroDeAudio.map(NucleoReceptor.nome) ?? "n/a")
                             + " session_close=" + (fechamento.map(NucleoReceptor.nome) ?? "n/a"))
            }
        }
        // `quall_cleanup()` **não** é chamado: ver o cabeçalho desta classe.
        return (desregistro, fechamento, liberada)
    }

    // --- o padrão `(buf, cap)` -----------------------------------------------------------------

    /// Pergunta o tamanho com buffer nulo, aloca, chama de novo. Sem isto o JSON de pares
    /// conhecidos seria truncado em silêncio quando crescesse — e truncar apaga pareamentos.
    private static func comBuffer(_ chamar: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String? {
        let precisa = chamar(nil, 0)
        guard precisa > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: precisa)
        let n = buffer.withUnsafeMutableBufferPointer { p in chamar(p.baseAddress, UInt(p.count)) }
        // `n <= precisa` junto: `n > 0` sozinho é a leitura errada que apagou o `pares.json` do
        // app do macOS, e daqui é que a próxima casca copia o padrão.
        return n > 0 && n <= precisa ? String(cString: buffer) : nil
    }
}
