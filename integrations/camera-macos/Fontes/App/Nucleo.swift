import Foundation

/// Casca do **receptor** sobre a fronteira C. O app da câmera virtual só exibe: pelo fluxo de uso
/// do projeto, quem espelha anuncia e espera, quem exibe escolhe e conecta. Então aqui há
/// `quall_connect`, nunca `quall_host`.
///
/// Três regras da dívida do núcleo estão codificadas nesta classe, e nenhuma é de estilo:
///
/// 1. **Nunca chamar a API C com um id que possa estar morto.** No Windows a exceção da
///    libdatachannel não solta o mutex global e a próxima chamada trava o processo *para sempre*.
///    A regra vale como disciplina em toda casca: aqui, uma trava e um par de ponteiros que são
///    zerados **antes** do `close`.
/// 2. **`quall_session_close` VIROU barreira em 26/08/2026** (dívida 24). Quando devolve
///    `QUALL_STATUS_OK`, nenhum tratador daquela sessão está correndo nem voltará a correr, e
///    `quall_track_on_frame(t, NULL, NULL)` desregistra com a mesma garantia por track. O código
///    abaixo é anterior a isso: o `user_data` é uma `Caixa` retida **para sempre**
///    (`passRetained`, sem `release`), com uma bandeira que o tratador lê antes de tocar em
///    qualquer coisa. **Isso deixou de ser preço de segurança e virou vazamento puro** — dá para
///    liberar a `Caixa` depois do `close` com `OK`, mas trocar exige reconstruir e reprovar esta
///    extensão na bancada, e ninguém fez ainda.
/// 3. **Nunca chamar `quall_cleanup()`.** Ele espera 10 s, desiste e deixa uma thread de limpeza
///    presa que impede o processo de morrer.
final class Nucleo {

    /// O que sobrevive à sessão para o tratador de quadro poder ser chamado com segurança.
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

        func desligar() {
            trava.lock(); _vivo = false; trava.unlock()
        }
    }

    private let travaDoUso = NSLock()
    private var sessao: OpaquePointer?
    private var track: OpaquePointer?
    private var caixa: Caixa?
    private var vivas: [UnsafeMutablePointer<CChar>] = []

    private(set) var ultimoMotivo = ""

    static func ultimoErro() -> String {
        guard let p = quall_last_error() else { return "" }
        return String(cString: p)
    }

    static func versaoDoProtocolo() -> UInt16 { quall_protocol_version() }

    deinit {
        encerrar()
        for p in vivas { free(p) }
    }

    private func guardar(_ texto: String) -> UnsafeMutablePointer<CChar> {
        let copia = strdup(texto) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
        vivas.append(copia)
        return copia
    }

    /// Conecta no emissor. **Bloqueia** até parear e o transporte subir, ou o prazo estourar.
    func conectar(endereco: String,
                  pin: String?,
                  deviceId: String,
                  nome: String,
                  paresConhecidos: String?,
                  prazoMs: UInt32) -> Bool {
        let idC = guardar(deviceId)
        let nomeC = guardar(nome)
        let pinC: UnsafeMutablePointer<CChar>? = pin.map { guardar($0) }
        let paresC: UnsafeMutablePointer<CChar>? = paresConhecidos.map { guardar($0) }
        let enderecoC = guardar(endereco)

        var opcoes = QuallSessionOptions(
            me: QuallDeviceDesc(device_id: idC,
                                display_name: nomeC,
                                screen_source: false,
                                camera_source: false,
                                sink: true),
            pin: pinC.map { UnsafePointer($0) },
            known_peers_json: paresC.map { UnsafePointer($0) },
            signaling_port: 0,
            timeout_ms: prazoMs,
            tracks: nil,
            track_count: 0,
            // **Este app não pede o cabo.** `nil` é o comportamento de sempre: o ICE reúne
            // todas as interfaces. Quem prende a mídia a uma delas é quem trata cabo como
            // escolha do usuário — hoje, só o plugin do OBS.
            bind_address: nil)

        // Fora da trava: a chamada bloqueia por dezenas de segundos e nada mais pode ficar
        // pendurado nela.
        guard let nova = withUnsafePointer(to: &opcoes, { quall_connect(enderecoC, $0) }) else {
            ultimoMotivo = Nucleo.ultimoErro()
            return false
        }
        travaDoUso.lock()
        sessao = nova
        travaDoUso.unlock()
        return true
    }

    /// **Hospeda** uma sessão e abre uma track de saída. É o outro lado do fluxo de uso: quem
    /// espelha anuncia e espera, quem exibe conecta.
    ///
    /// O app de câmera virtual **não** usa isto em produto — ele só exibe. Existe para o emissor
    /// de bancada, que é o que permite medir o caminho inteiro com **um único relógio**: emissor e
    /// consumidor na mesma máquina, `CLOCK_UPTIME_RAW` é do sistema e não do processo, e a
    /// subtração é válida sem sincronizar nada.
    func hospedar(deviceId: String, nome: String, pin: String, porta: UInt16,
                  rotuloDaTrack: String, paresConhecidos: String?, prazoMs: UInt32) -> Bool {
        let idC = guardar(deviceId)
        let nomeC = guardar(nome)
        let pinC = guardar(pin)
        let rotuloC = guardar(rotuloDaTrack)
        let paresC: UnsafeMutablePointer<CChar>? = paresConhecidos.map { guardar($0) }

        var descricaoDaTrack = QuallTrackDesc(
            kind: QUALL_TRACK_KIND_SCREEN,
            label: UnsafePointer(rotuloC),
            // Ver a nota igual em apps/ios/PortaoAppex: o campo entrou na rodada de áudio e
            // três das quatro cascas não acompanharam. A câmera virtual entrega vídeo para um
            // consumidor local (OBS, Zoom) e não negocia áudio; o padrão do núcleo é o certo.
            audio_codec: QUALL_AUDIO_CODEC_DEFAULT
        )
        let nova: OpaquePointer? = withUnsafePointer(to: &descricaoDaTrack) { td in
            var opcoes = QuallSessionOptions(
                me: QuallDeviceDesc(device_id: idC,
                                    display_name: nomeC,
                                    screen_source: true,
                                    camera_source: false,
                                    sink: false),
                pin: UnsafePointer(pinC),
                known_peers_json: paresC.map { UnsafePointer($0) },
                signaling_port: porta,
                timeout_ms: prazoMs,
                tracks: td,
                track_count: 1,
                // **Este app não pede o cabo.** `nil` é o comportamento de sempre: o ICE reúne
                // todas as interfaces. Quem prende a mídia a uma delas é quem trata cabo como
                // escolha do usuário — hoje, só o plugin do OBS.
                bind_address: nil)
            return withUnsafePointer(to: &opcoes) { quall_host($0) }
        }
        guard let nova else {
            ultimoMotivo = Nucleo.ultimoErro()
            return false
        }
        travaDoUso.lock()
        sessao = nova
        track = quall_session_track(nova, 0)
        travaDoUso.unlock()
        return true
    }

    /// `enviar_quadro` do contrato. Devolve o status para o chamador **descartar e seguir** —
    /// enfileirar para tentar de novo é exatamente o que não se faz com vídeo ao vivo.
    @discardableResult
    func enviarQuadro(_ dados: Data, timestampUs: UInt64, idr: Bool) -> QuallStatus {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return QUALL_STATUS_CLOSED }
        return dados.withUnsafeBytes { bruto -> QuallStatus in
            guard let base = bruto.bindMemory(to: UInt8.self).baseAddress else { return QUALL_STATUS_CLOSED }
            var quadro = QuallFrame(annexb: base, len: UInt(bruto.count), timestamp_us: timestampUs, idr: idr)
            return withUnsafePointer(to: &quadro) { quall_track_send_frame(t, $0) }
        }
    }

    /// A bandeira de pedido de IDR, consumida uma vez por rajada. O header recomenda esta forma
    /// para quem já tem um laço por quadro — e o laço de captura é exatamente isso.
    func pedidoDeIdrPendente() -> Bool {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return false }
        return quall_track_take_idr_request(t)
    }

    /// Espera a track que o emissor abriu. Devolve o rótulo e o tipo quando ela chega.
    func esperarTrack(prazoMs: UInt32) -> (rotulo: String, tipo: QuallTrackKind)? {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return nil }

        guard let t = quall_session_next_track(s, prazoMs) else { return nil }
        // **Pergunta o tamanho antes.** Era um buffer fixo de 256 bytes lido como sucesso quando
        // o retorno era positivo — e um retorno maior que a capacidade também é positivo, com o
        // buffer intocado. O rótulo vem do SDP do emissor e carrega o nome que a outra ponta
        // escolheu; teto nenhum aqui é nosso. Mesmo defeito que apagou o `pares.json` do app do
        // macOS em 26/08, só que num rótulo em vez do estado de pareamento.
        let rotulo = Nucleo.comBuffer { buf, cap in Int(quall_track_label(t, buf, cap)) } ?? ""
        let tipo = quall_track_kind(t)

        travaDoUso.lock()
        track = t
        travaDoUso.unlock()
        return (rotulo, tipo)
    }

    /// Registra o tratador de quadro. Roda numa thread da libdatachannel: não bloqueie dentro.
    func ouvirQuadros(_ tratador: @escaping (UnsafeRawBufferPointer, UInt64, Bool) -> Void) -> Bool {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return false }

        let nova = Caixa(aoQuadro: tratador)
        caixa = nova
        // `passRetained` sem `release` correspondente, de propósito: não há desregistro de
        // tratador na fronteira, e liberar depois do `close` é uso-após-liberação. Ver a dívida.
        let opaco = Unmanaged.passRetained(nova).toOpaque()

        let status = quall_track_on_frame(t, { quadro, dados in
            guard let quadro, let dados else { return }
            let caixa = Unmanaged<Caixa>.fromOpaque(dados).takeUnretainedValue()
            guard caixa.vivo else { return }
            let q = quadro.pointee
            guard let bytes = q.annexb, q.len > 0 else { return }
            caixa.aoQuadro(UnsafeRawBufferPointer(start: bytes, count: Int(q.len)),
                           q.timestamp_us, q.idr)
        }, opaco)
        return status == QUALL_STATUS_OK
    }

    /// `pedir_idr()` do contrato: emite PLI. Devolve erro enquanto a track não abriu, e tentar de
    /// novo por alguns milissegundos é o comportamento certo — o receptor Windows mediu 44 ms
    /// para a primeira imagem com o pedido contra 3,71 s sem ele.
    @discardableResult
    func pedirIdr() -> QuallStatus {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return QUALL_STATUS_CLOSED }
        return quall_track_request_idr(t)
    }

    /// O pareamento foi novo (o usuário digitou PIN) ou retomado de `pares.json`?
    func pareamentoNovo() -> Bool {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return false }
        return quall_session_pairing_is_new(s)
    }

    /// O estado de pareamento atualizado, para a casca **persistir**. Sem gravar isto, o usuário
    /// digita o PIN toda vez — que era o estado desta frente até agora.
    func paresConhecidos(base: String?) -> String? {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return nil }
        return comBuffer { buf, cap in
            if let base {
                return base.withCString { quall_session_known_peers_json(s, $0, buf, cap) }
            }
            return quall_session_known_peers_json(s, nil, buf, cap)
        }
    }

    /// **Funde** dois estados de pareamento; na colisão vence o mais recente (dívida 23).
    ///
    /// A casca lê o disco de novo na hora de gravar e funde com o que tem na mão, em vez de
    /// sobrescrever com um instantâneo velho. Não substitui uma trava entre processos — reduz o
    /// estrago de quando ela faltar, que aqui é sempre, porque o app e o receptor de bancada podem
    /// estar correndo ao mesmo tempo.
    static func fundirPares(_ a: String?, _ b: String?) -> String? {
        comBuffer { buf, cap in
            comC(a) { pa in comC(b) { pb in Int(quall_known_peers_merge(pa, pb, buf, cap)) } }
        }
    }

    /// **Esquece um par**, para o produto poder oferecer "parear de novo" em vez do beco sem
    /// saída da dívida 22 — funcionou ontem, hoje não funciona, e não há como digitar o PIN.
    static func esquecerPar(_ conhecidos: String?, deviceId: String) -> String? {
        comBuffer { buf, cap in
            comC(conhecidos) { pc in
                deviceId.withCString { pd in Int(quall_known_peers_forget(pc, pd, buf, cap)) }
            }
        }
    }

    /// `String?` como `const char *`, com nulo para ausente. Sem isto, cada chamada da fronteira
    /// que aceita nulo vira um `if` aninhado.
    private static func comC<R>(_ s: String?, _ corpo: (UnsafePointer<CChar>?) -> R) -> R {
        if let s { return s.withCString { corpo($0) } }
        return corpo(nil)
    }

    /// O padrão `(buf, cap)` da fronteira C, numa função só: chama com buffer nulo para saber o
    /// tamanho, aloca, chama de novo.
    private static func comBuffer(_ chamar: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String? {
        let precisa = chamar(nil, 0)
        guard precisa > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: precisa)
        let n = buffer.withUnsafeMutableBufferPointer { p in
            chamar(p.baseAddress, UInt(p.count))
        }
        // `n <= precisa` junto: `n > 0` sozinho é a leitura errada que apagou o `pares.json` do
        // app do macOS, e daqui é que a próxima casca copia o padrão.
        return n > 0 && n <= precisa ? String(cString: buffer) : nil
    }

    private func comBuffer(_ chamar: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String? {
        Nucleo.comBuffer(chamar)
    }

    func contadores() -> String {
        travaDoUso.lock()
        let t = track
        travaDoUso.unlock()
        guard let t else { return "{}" }
        let precisa = Int(quall_track_stats_json(t, nil, 0))
        guard precisa > 0 else { return "{}" }
        var buffer = [CChar](repeating: 0, count: precisa)
        let n = buffer.withUnsafeMutableBufferPointer { p in
            Int(quall_track_stats_json(t, p.baseAddress, UInt(p.count)))
        }
        return n > 0 ? String(cString: buffer) : "{}"
    }

    /// `frames_dropped` do receptor, sozinho e já em número.
    ///
    /// É o gatilho do pedido de IDR na perda (`contrato-track.md`: "ou quando o decoder perde
    /// sincronia"), e por isso ele é lido a cada 50 ms — não a cada relatório. Sai daqui, e não do
    /// `contadores()` de texto, porque quem chama precisa comparar com o valor anterior, não
    /// imprimir.
    ///
    /// Devolve `nil` quando não deu para ler; quem chama trata como "sem informação nesta volta" e
    /// **não** como zero — zerar levaria a um pedido de IDR espúrio na volta seguinte.
    func quadrosPerdidos() -> UInt64? {
        guard let dados = contadores().data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let n = obj["frames_dropped"] as? NSNumber else { return nil }
        return n.uint64Value
    }

    /// **O caminho de volta do sinal**: o receptor conta ao emissor o que viu do enlace numa
    /// janela, e é sobre isso que o controlador de taxa do outro lado decide.
    ///
    /// Os cinco números são **deltas da janela**, nunca acumulados desde o começo da sessão —
    /// quem escuta o enlace precisa da derivada, não da integral. `pacotes` é o que o **emissor**
    /// mandou (`vistos + perdidos`): dividir pelo que chegou já inverteu a conclusão de uma frente
    /// inteira desta bancada.
    ///
    /// O header exige que isto seja chamado **da mesma thread** que chama
    /// `quall_session_next_event`, porque a fronteira não põe cadeado na sinalização para deixar o
    /// caminho quente livre. Nesta casca essa thread é o laço de supervisão de
    /// `Receptor.correr(...)`, e é de lá que ele sai — nunca do tratador de quadro.
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

    /// O detector de queda. Chame do laço de supervisão com prazo pequeno.
    func evento(prazoMs: UInt32) -> QuallSessionEvent {
        travaDoUso.lock()
        let s = sessao
        travaDoUso.unlock()
        guard let s else { return QUALL_SESSION_EVENT_FAILED }
        return quall_session_next_event(s, prazoMs)
    }

    /// Ordem obrigatória: desligar a caixa, soltar a track, fechar a sessão. Os ponteiros são
    /// zerados **antes** das chamadas de liberação, para que nenhuma outra thread possa entrar na
    /// API C com um id que está morrendo.
    func encerrar() {
        travaDoUso.lock()
        let t = track
        let s = sessao
        track = nil
        sessao = nil
        travaDoUso.unlock()

        caixa?.desligar()
        if let t { quall_track_free(t) }
        if let s { quall_session_close(s) }
        // `quall_cleanup()` **não** é chamado: ver o cabeçalho desta classe.
    }
}
