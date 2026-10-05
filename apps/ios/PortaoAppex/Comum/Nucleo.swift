#if COM_NUCLEO
import Foundation

/// Casca fina sobre a fronteira C do núcleo, com **exatamente** o que o degrau 4 precisa e nada
/// além. Não é a casca de produto: é o instrumento que responde se o núcleo cabe nos 46,6 MB.
///
/// Três decisões que não são de estilo, e sim consequência direta da dívida registrada em
/// `docs/divida-do-nucleo.md`:
///
/// 1. **Nunca chamar `quall_cleanup()`.** Ele trava a libdatachannel num mutex global, e numa
///    Broadcast Upload Extension não existe "saída do processo" segura — o sistema mata o
///    processo quando a transmissão acaba. Chamar seria trocar um vazamento por um travamento.
///    (dívida 2)
/// 2. **`deveIDR` é da casca, não do núcleo.** `quall_track_take_idr_request` faz `swap(false)`:
///    se o quadro que carregava o pedido for descartado pelo encoder, o pedido some e o receptor
///    fica sem imagem sem que ninguém saiba por quê. Aqui a bandeira só baixa quando o
///    VideoToolbox devolve de fato um quadro chave. (dívida 15)
/// 3. **Sucesso de `quall_track_send_frame` não é sinal de vida.** O `CONSENT_TIMEOUT` do
///    libjuice é de 30 s: o emissor continua recebendo `QUALL_STATUS_OK` por meio minuto depois
///    de o receptor sumir. O contador de sucessos desta classe serve para medir volume, jamais
///    para concluir que alguém está do outro lado. (dívida 13)
final class Nucleo {

    /// O que o núcleo diz de si mesmo antes de qualquer sessão. É a chamada mais barata da
    /// fronteira, e é ela que separa "o binário existe no disco" de "o binário executa".
    static func versaoDoProtocolo() -> UInt16 { quall_protocol_version() }

    static func tipoDeServico() -> String {
        guard let ponteiro = quall_service_type() else { return "?" }
        return String(cString: ponteiro)
    }

    static func ultimoErro() -> String {
        guard let ponteiro = quall_last_error() else { return "" }
        return String(cString: ponteiro)
    }

    // --- estado -------------------------------------------------------------------------

    /// Protege os dois ponteiros da fronteira C contra o cruzamento que existe de verdade aqui:
    /// os quadros saem da thread de saída do VideoToolbox, o relatório de 1 Hz lê contadores de
    /// uma terceira thread, e o desmonte da sessão vem da máquina de fases. Sem esta trava,
    /// `encerrar()` liberaria a track no instante em que um quadro estivesse sendo empacotado —
    /// e o defeito apareceria como um travamento dentro da libdatachannel, longe da causa.
    private let travaDoUso = NSLock()
    private var sessao: OpaquePointer?
    private var track: OpaquePointer?

    /// Strings do C que precisam sobreviver à chamada de `quall_host`. Guardadas em campo — e
    /// não passadas por `withCString` aninhado — porque o aninhamento de cinco níveis de
    /// closure em volta de uma chamada que **bloqueia por minutos** é exatamente o tipo de
    /// código em que um `defer` mal colocado vira ponteiro pendurado.
    private var vivas: [UnsafeMutablePointer<CChar>] = []

    /// Bandeira local de IDR — ver o item 3 do cabeçalho.
    private let travaDoIdr = NSLock()
    private var deveIDR = false

    /// Fotografia dos contadores, tirada sob trava. Ler campo a campo de outra thread daria
    /// números de instantes diferentes na mesma linha de log.
    struct Contadores {
        var enviados: UInt64 = 0
        var recusados: UInt64 = 0
        var ultimoStatus: UInt32 = 0
        var pedidosDeIdr: UInt64 = 0
    }
    private var contadores = Contadores()

    var fotografia: Contadores {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        return contadores
    }

    deinit {
        for p in vivas { free(p) }
    }

    private func guardar(_ texto: String) -> UnsafeMutablePointer<CChar> {
        let copia = strdup(texto)!
        vivas.append(copia)
        return copia
    }

    // --- sessão -------------------------------------------------------------------------

    /// Sobe uma sessão de emissor com **uma** track de tela. **Bloqueia** até o receptor chegar
    /// ou o prazo estourar; chame de uma thread de trabalho.
    ///
    /// Sem anúncio por mDNS de propósito: nenhum dos perfis de provisionamento tem
    /// `com.apple.developer.networking.multicast`, o pedido está com a Apple, e `quall_host` já
    /// é separado de `quall_advertiser_start` justamente para que o caminho por IP digitado —
    /// que é o fallback obrigatório do fluxo — seja o caminho que se exercita.
    func hospedar(pin: String, porta: UInt16, rotulo: String, prazoMs: UInt32) -> Bool {
        let idDoAparelho = guardar("iphone7-degrau4")
        let nome = guardar("Portão iOS — degrau 4")
        let pinC = guardar(pin)
        let rotuloC = guardar(rotulo)

        var descricao = QuallTrackDesc(
            kind: QUALL_TRACK_KIND_SCREEN,
            label: rotuloC,
            // `audio_codec` entrou no struct na rodada de áudio e esta casca não acompanhou:
            // ficou sem compilar no tronco até 30/08, e ninguém viu porque ninguém a compila.
            // Este arranjo é de bancada (mediu o teto de memória da extension) e não emite
            // áudio, então o padrão do núcleo é o valor certo — não é escolha, é ausência.
            audio_codec: QUALL_AUDIO_CODEC_DEFAULT
        )

        return withUnsafePointer(to: &descricao) { tracks -> Bool in
            var opcoes = QuallSessionOptions(
                me: QuallDeviceDesc(device_id: idDoAparelho,
                                    display_name: nome,
                                    screen_source: true,
                                    camera_source: false,
                                    sink: false),
                pin: pinC,
                known_peers_json: nil,
                signaling_port: porta,
                timeout_ms: prazoMs,
                tracks: tracks,
                track_count: 1,
                // Só a casca que **conecta** pede o cabo, e nenhuma tela do iOS oferece isso ainda:
                // `nil` mantém o comportamento de sempre, com o ICE reunindo toda interface. Ver
                // `QuallSessionOptions::bind_address` e `docs/quall-pelo-cabo.md`.
                bind_address: nil)

            // A chamada bloqueia por minutos: fica **fora** da trava, senão o relatório de 1 Hz
            // ficaria pendurado nela durante toda a espera pelo receptor.
            guard let nova = withUnsafePointer(to: &opcoes, { quall_host($0) }) else {
                // `quall_last_error()` tem o motivo; quem chama o lê e registra.
                return false
            }
            let quantas = quall_session_track_count(nova)
            let t = quantas > 0 ? quall_session_track(nova, 0) : nil
            travaDoUso.lock()
            sessao = nova
            track = t
            travaDoUso.unlock()
            if t == nil {
                // Sessão de pé **sem** track é um estado que não produz erro na fronteira C:
                // `quall_last_error()` vem vazio, e quem lesse só o erro concluiria "falhou sem
                // motivo". Dizer o número de tracks aqui é a diferença entre um diagnóstico e um
                // encolher de ombros.
                ultimoMotivo = "sessão subiu mas veio com \(quantas) track(s) de saída"
            }
            return t != nil
        }
    }

    /// Motivo da última falha que a fronteira C **não** reporta em `quall_last_error()`.
    private(set) var ultimoMotivo = ""

    var porta: UInt16 {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let sessao else { return 0 }
        return quall_session_signaling_port(sessao)
    }

    var parJson: String {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let sessao else { return "" }
        return Nucleo.lerTexto { buf, cap in quall_session_peer_json(sessao, buf, cap) }
    }

    var estatisticasDaTrack: String {
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let track else { return "" }
        return Nucleo.lerTexto { buf, cap in quall_track_stats_json(track, buf, cap) }
    }

    /// Desmonta o que a casca pode desmontar. **Não** chama `quall_cleanup()`.
    ///
    /// A dívida 12 diz que `quall_session_close()` não desmonta a sessão quando o par já sumiu:
    /// se existir `mSctpTransport`, ele para o SCTP e volta sem tocar em `closeTransports()`.
    /// Chamamos mesmo assim, porque é o que uma casca de produto faria — e o que se quer medir
    /// é justamente quanto sobra depois.
    func encerrar() {
        travaDoUso.lock()
        let t = track, s = sessao
        track = nil
        sessao = nil
        travaDoUso.unlock()
        // Fora da trava: `quall_session_close` pode demorar, e quem ainda estivesse tentando
        // enviar já viu `track == nil` e desistiu.
        if let t { quall_track_free(t) }
        if let s { quall_session_close(s) }
    }

    // --- quadros ------------------------------------------------------------------------

    /// Lê o pedido de IDR do receptor **uma vez por quadro** e o guarda localmente.
    ///
    /// A leitura é aqui, e não no encoder, porque `quall_track_take_idr_request` consome: quem
    /// lê é dono do pedido e responde por ele.
    func recolherPedidoDeIdr() {
        travaDoUso.lock()
        guard let track else { travaDoUso.unlock(); return }
        let pediu = quall_track_take_idr_request(track)
        if pediu { contadores.pedidosDeIdr += 1 }
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

    /// Só baixa a bandeira quando o encoder **de fato** devolveu um quadro chave.
    func idrEntregue() {
        travaDoIdr.lock(); deveIDR = false; travaDoIdr.unlock()
    }

    /// `enviar_quadro` do contrato: empacota e solta. O buffer é do chamador e o núcleo não o
    /// guarda.
    @discardableResult
    func enviar(annexb: UnsafeRawBufferPointer, timestampUs: UInt64, idr: Bool) -> Bool {
        // A trava fica segurada durante o `send_frame` inteiro. Ela é curta por construção —
        // o contrato diz que o núcleo empacota e solta, sem fila — e é o que garante que a
        // track não seja liberada no meio do empacotamento.
        travaDoUso.lock(); defer { travaDoUso.unlock() }
        guard let track, let base = annexb.baseAddress else { return false }
        var quadro = QuallFrame(annexb: base.assumingMemoryBound(to: UInt8.self),
                                len: UInt(annexb.count),
                                timestamp_us: timestampUs,
                                idr: idr)
        let estado = withUnsafePointer(to: &quadro) { quall_track_send_frame(track, $0) }
        contadores.ultimoStatus = estado.rawValue
        if estado == QUALL_STATUS_OK {
            contadores.enviados += 1
            return true
        }
        contadores.recusados += 1
        return false
    }

    // --- utilidade ----------------------------------------------------------------------

    /// O padrão `(buf, cap)` da fronteira C, **perguntando o tamanho primeiro**.
    ///
    /// O comentário anterior dizia que 1024 bastava porque "par e contadores são dezenas de
    /// bytes". Era verdade quando foi escrito e é o formato de defeito que mordeu duas vezes
    /// nesta casa: `escrever_texto` devolve o tamanho necessário **tanto quando escreve quanto
    /// quando não cabe**, e quando não cabe não escreve nada — então `escritos > 0` passa nos dois
    /// casos e o buffer intacto vira string vazia, em silêncio. O `pares.json` do Mac chegou a
    /// 10.193 bytes e derrubou primeiro um buffer de 256 e depois teria derrubado um de 4096.
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
#endif
