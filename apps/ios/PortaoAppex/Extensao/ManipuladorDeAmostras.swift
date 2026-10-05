import ReplayKit
import CoreMedia

/// Degraus 3 e 4 da escada de portões do M3, no mesmo instrumento.
///
/// O degrau 3 já respondeu à sua pergunta — o ReplayKit **não** para de entregar quando a tela
/// não muda (8142 quadros em 136 s a 59,86 fps, maior intervalo de 83 ms, no iPhone 7) —, e por
/// isso o relógio de 1 Hz continua sendo o narrador: se medisse pelo próprio callback de quadro,
/// a medição pararia junto com o que ela deveria medir.
///
/// O degrau 4 pendura nesse mesmo relógio uma **máquina de fases**, porque cada pedaço do risco
/// falha por motivo diferente e precisa ser separável na curva de memória:
///
/// | fase | o que está de pé | a pergunta |
/// |---|---|---|
/// | `carregado` | binário linkado, zero linhas de Rust executadas | quanto custou **só existir** |
/// | `calibragem` | N quadros do ReplayKit retidos de propósito | eles já estão pagos? |
/// | `versao` | `quall_protocol_version()` chamada | o símbolo executa no aparelho |
/// | `hospedando` | `quall_host` bloqueado esperando receptor | quanto custa a sessão de pé |
/// | `enviando` | VideoToolbox → `quall_track_send_frame` | a curva estabiliza ou sobe |
/// | `entre-sessoes` | primeira sessão fechada, ninguém do outro lado | o que `close()` devolve |
/// | `enviando2` | segunda sessão, outra porta | dívidas 12 e 14, medidas |
///
/// **Cada linha de 1 Hz publica os dois tempos**: o acumulado desde `broadcastStarted` e o
/// delta da janela de um segundo. O instrumento do degrau 3 só tinha o acumulado, e um `fps`
/// que é média de vida não mostra uma queda que começou no minuto seis — nem um `maior
/// intervalo` que já passou. A pergunta do degrau 4 é sobre **inclinação**, e inclinação não se
/// lê num acumulador.
///
/// Tudo é dirigido por `Plano`, lido do App Group: iniciar uma transmissão custa **um toque
/// humano** que não é automatizável no iPhone 7, então recompilar para mudar um prazo custaria
/// um toque por experimento.
///
/// A extension encerra a si mesma com `finishBroadcastWithError` no fim do plano. Sem isso,
/// parar a transmissão seria mais um toque, e instalar por cima de uma appex viva mediria outra
/// coisa.
class ManipuladorDeAmostras: RPBroadcastSampleHandler {

    private let (plano, origemDoPlano) = Plano.carregarComMotivo()

    private let travaDaMedida = NSLock()
    private var inicio = CFAbsoluteTimeGetCurrent()
    private var ultimoQuadro: CFAbsoluteTime = 0
    private var quadrosDeVideo = 0
    private var quadrosDeAudio = 0
    private var maiorIntervalo: Double = 0
    private var maiorIntervaloDaJanela: Double = 0
    private var acimaDe100ms = 0
    private var acimaDe500ms = 0
    private var acimaDe1s = 0
    private var dimensao = "?"
    private var relogio: DispatchSourceTimer?

    /// Última amostra publicada, para que a linha seguinte possa dizer o delta da janela.
    private var marcoT: Double = 0
    private var marcoVideo = 0
    private var marcoPegada: UInt64 = 0
    private var marcoEncodados: UInt64 = 0
    private var marcoEnviados: UInt64 = 0

    private var faseAtual = "carregado"
    private var pegadaNoInicioDaFase: UInt64 = 0
    private var maiorPegadaDaFase: UInt64 = 0

    /// Levantada antes de qualquer desmonte e no `broadcastFinished`. É o ponto de cancelamento
    /// que a fronteira C não oferece: `quall_host` bloqueia sem API de cancelamento (dívida 10),
    /// então quem espera precisa poder desistir por conta própria entre tentativas.
    private let travaDoFim = NSLock()
    private var _encerrando = false
    private var encerrando: Bool {
        get { travaDoFim.lock(); defer { travaDoFim.unlock() }; return _encerrando }
        set { travaDoFim.lock(); _encerrando = newValue; travaDoFim.unlock() }
    }

    private var fezCalibragem = false
    private var fezVersao = false
    private var fezHost = false
    private var fezFimDaSessao1 = false
    private var fezHost2 = false
    private var fezFim = false

    // --- calibragem de retenção dos buffers do ReplayKit ------------------------------------

    private var calibrando = false
    private var querMaisUmQuadro = false
    private var retidos: [CMSampleBuffer] = []
    private var pegadaAntesDaCalibragem: UInt64 = 0

    #if COM_NUCLEO
    /// Trava própria para o trio que quatro threads disputam — a do ReplayKit (que entrega
    /// quadros), a de saída do VideoToolbox (que devolve os encodados), a do relógio de 1 Hz e
    /// a que fica bloqueada em `quall_host`. Não é preciosismo: em Swift, ler uma propriedade de
    /// objeto enquanto outra thread a substitui é retain/release concorrente, e isso derruba o
    /// processo — num experimento de dez minutos que custa um toque humano.
    private let travaDoEnvio = NSLock()
    private var nucleo: Nucleo?
    private var codificador: CodificadorH264?
    private var enviando = false
    private var ultimoEncodePts: Double = -1
    private var quadrosEncodados: UInt64 = 0
    private var idrsEncodados: UInt64 = 0

    /// Pega referências fortes sob trava, para usá-las fora dela.
    private func aparelhagem() -> (Nucleo, CodificadorH264)? {
        travaDoEnvio.lock(); defer { travaDoEnvio.unlock() }
        guard enviando, let n = nucleo, let c = codificador else { return nil }
        return (n, c)
    }
    #endif

    deinit {
        // Um `DispatchSourceTimer` não cancelado sobrevive ao objeto que o armou. Numa appex
        // que o sistema recria a cada transmissão isso é inofensivo; num processo reaproveitado,
        // cada transmissão interrompida deixaria um relógio vivo relatando sobre um manipulador
        // morto. Custa uma linha.
        relogio?.cancel()
        relogio = nil
    }

    // =========================================================================================
    // Ciclo de vida da transmissão
    // =========================================================================================

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        relogio?.cancel()
        relogio = nil
        encerrando = false
        inicio = CFAbsoluteTimeGetCurrent()
        ultimoQuadro = 0
        pegadaNoInicioDaFase = Diario.pegadaEmBytes
        maiorPegadaDaFase = pegadaNoInicioDaFase
        marcoPegada = pegadaNoInicioDaFase
        // Avisa o app hospedeiro de que a pessoa tocou. Ele responde trocando a interface pelo
        // agitador — a tela que muda, que é condição da medição do degrau 4.
        Diario.marcarTransmissao(true)

        #if COM_NUCLEO
        let sabor = "com-nucleo"
        #else
        let sabor = "sem-nucleo"
        #endif

        // Esta é a linha que responde "quanto custou só existir": o binário já foi carregado
        // pelo dyld e os inicializadores estáticos de C++ do OpenSSL, do usrsctp e da
        // libdatachannel já correram, mas **nenhuma** linha de Rust foi chamada ainda.
        //
        // O `uptime` vai junto porque uma rodada num aparelho recém-reiniciado mede o caso mais
        // fácil, e quem lê o relato precisa poder invalidá-la por isso.
        Diario.anotar("DEGRAU4 inicio sabor=\(sabor) \(Sistema.descricao)"
            + " memoria_disponivel=\(Diario.memoriaDisponivel)"
            + " pegada=\(Diario.pegadaEmBytes)"
            + " grupo=\(Diario.pastaDoGrupo == nil ? "SEM-APP-GROUP" : "SIM")"
            + " plano_de=\(origemDoPlano)"
            + " plano{\(plano.resumo)}")
        // O mesmo eco que o app publica, agora do lado da appex: os dois processos leem o plano
        // de lugares diferentes, e um deles pode ler certo enquanto o outro lê errado.
        Diario.anotar("DEGRAU4 plano-eco \(plano.eco)")
        Diario.anotar("DEGRAU4 enderecos \(Enderecos.ipv4().joined(separator: " "))")

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tique() }
        t.resume()
        relogio = t
    }

    override func broadcastPaused() {
        Diario.anotar("DEGRAU4 broadcastPaused memoria_disponivel=\(Diario.memoriaDisponivel)")
    }

    override func broadcastResumed() {
        Diario.anotar("DEGRAU4 broadcastResumed memoria_disponivel=\(Diario.memoriaDisponivel)")
    }

    /// Este callback tem prazo do sistema. Nada de fechar sessão aqui: `quall_session_close`
    /// desce até `Link::close`, que **não tem prazo** — com o par sumido ela pode pendurar, e o
    /// sistema mataria a appex no meio, trocando um encerramento limpo por um relatório
    /// truncado. O desmonte acontece na máquina de fases, com o relógio ainda de pé.
    override func broadcastFinished() {
        encerrando = true
        Diario.marcarTransmissao(false)
        relogio?.cancel()
        relogio = nil
        soltarCalibragem(motivo: "broadcastFinished")
        relatar()
        #if COM_NUCLEO
        // Nada de `quall_cleanup()`: ele trava a libdatachannel num mutex global, e numa
        // extension não existe hora segura de chamar (dívida 2).
        travaDoEnvio.lock()
        enviando = false
        let n = nucleo
        travaDoEnvio.unlock()
        Diario.anotar("DEGRAU4 fim estatisticas{\(n?.estatisticasDaTrack ?? "")}")
        #endif
        Diario.anotar("DEGRAU4 broadcastFinished"
            + " memoria_disponivel=\(Diario.memoriaDisponivel)"
            + " pegada=\(Diario.pegadaEmBytes)")
    }

    // =========================================================================================
    // Quadros
    // =========================================================================================

    /// Barato de propósito: anota, e — quando há sessão — repassa ao encoder. Nenhum log por
    /// quadro, nenhuma alocação por quadro.
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        let agora = CFAbsoluteTimeGetCurrent()
        travaDaMedida.lock()

        switch sampleBufferType {
        case .video:
            if ultimoQuadro > 0 {
                let intervalo = agora - ultimoQuadro
                if intervalo > maiorIntervalo { maiorIntervalo = intervalo }
                if intervalo > maiorIntervaloDaJanela { maiorIntervaloDaJanela = intervalo }
                if intervalo > 0.100 { acimaDe100ms += 1 }
                if intervalo > 0.500 { acimaDe500ms += 1 }
                if intervalo > 1.000 { acimaDe1s += 1 }
            }
            ultimoQuadro = agora
            quadrosDeVideo += 1
            if dimensao == "?", let imagem = CMSampleBufferGetImageBuffer(sampleBuffer) {
                dimensao = "\(CVPixelBufferGetWidth(imagem))x\(CVPixelBufferGetHeight(imagem))"
            }
            if calibrando && querMaisUmQuadro {
                querMaisUmQuadro = false
                retidos.append(sampleBuffer)
            }
        default:
            quadrosDeAudio += 1
        }
        travaDaMedida.unlock()

        #if COM_NUCLEO
        guard sampleBufferType == .video,
              let (nucleo, codificador) = aparelhagem(),
              let imagem = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Freio de taxa: o ReplayKit entrega ~60 fps e o produto quer 30 para tela. Fica no
        // relógio de apresentação, e não num contador, para que uma pausa do ReplayKit não
        // acumule dívida de quadros.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let segundos = CMTimeGetSeconds(pts)
        let intervaloMinimo = 1.0 / Double(plano.fps) - 0.002
        travaDoEnvio.lock()
        let cedoDemais = ultimoEncodePts >= 0 && segundos - ultimoEncodePts < intervaloMinimo
        if !cedoDemais { ultimoEncodePts = segundos }
        travaDoEnvio.unlock()
        if cedoDemais { return }

        // Uma leitura por quadro, e o pedido fica guardado na casca até o encoder devolver de
        // fato um quadro chave (dívida 15).
        nucleo.recolherPedidoDeIdr()
        codificador.encodar(imagem, pts: pts,
                            duracao: CMTime(value: 1, timescale: plano.fps),
                            forcarIDR: nucleo.precisaDeIdr)
        #endif
    }

    // =========================================================================================
    // Máquina de fases, pendurada no relógio de 1 Hz
    // =========================================================================================

    private func tique() {
        let decorrido = CFAbsoluteTimeGetCurrent() - inicio
        relatar()
        avancar(decorrido)
    }

    private func avancar(_ t: Double) {
        if !fezFim && plano.duracao_s > 0 && t >= plano.duracao_s {
            fezFim = true
            encerrarTransmissao()
            return
        }

        conduzirCalibragem(t)

        #if COM_NUCLEO
        if !fezVersao && t >= plano.t_versao_s {
            fezVersao = true
            // A chamada mais barata da fronteira. Separa "o binário existe" de "o binário
            // executa", e o delta de pegada em volta dela é o custo da primeira entrada no Rust.
            let antes = Diario.pegadaEmBytes
            let versao = Nucleo.versaoDoProtocolo()
            let servico = Nucleo.tipoDeServico()
            let depois = Diario.pegadaEmBytes
            Diario.anotar("DEGRAU4 versao protocolo=\(versao) servico=\(servico)"
                + " pegada_antes=\(antes) pegada_depois=\(depois)"
                + " delta=\(Int64(depois) - Int64(antes))")
            mudarFase("versao")
        }

        if !fezHost && plano.t_host_s > 0 && t >= plano.t_host_s {
            fezHost = true
            mudarFase("hospedando")
            subirSessao(porta: plano.porta, rotulo: "sessao1")
        }

        if !fezFimDaSessao1 && plano.t_fim_sessao1_s > 0 && t >= plano.t_fim_sessao1_s {
            fezFimDaSessao1 = true
            desmontarSessao(rotulo: "sessao1")
            mudarFase("entre-sessoes")
        }

        if !fezHost2 && plano.t_host2_s > 0 && t >= plano.t_host2_s {
            fezHost2 = true
            mudarFase("hospedando2")
            subirSessao(porta: plano.porta2, rotulo: "sessao2")
        }
        #endif
    }

    // --- calibragem -------------------------------------------------------------------------

    /// Retém um quadro por segundo e registra a pegada depois de cada retenção.
    ///
    /// Um `CVPixelBuffer` de 750x1334 em 4:2:0 tem ~1,5 MB de plano; se o ReplayKit os entregar
    /// já contabilizados na pegada da appex (respaldados por `IOSurface` compartilhada), reter
    /// meia dúzia quase não move o número. Se não estiverem, seis quadros custam ~9 MB de um
    /// orçamento de 46,6 — e o resto da conta do degrau 4 precisa ser refeito.
    private func conduzirCalibragem(_ t: Double) {
        guard plano.t_calibragem_s > 0, plano.calibragem_quadros > 0 else { return }

        if !fezCalibragem && t >= plano.t_calibragem_s {
            fezCalibragem = true
            travaDaMedida.lock()
            calibrando = true
            querMaisUmQuadro = true
            pegadaAntesDaCalibragem = Diario.pegadaEmBytes
            travaDaMedida.unlock()
            Diario.anotar("DEGRAU4 calibragem inicio pegada=\(pegadaAntesDaCalibragem)"
                + " alvo=\(plano.calibragem_quadros) teto=\(plano.calibragem_teto_bytes)")
            mudarFase("calibragem")
            return
        }

        travaDaMedida.lock()
        let ativa = calibrando
        let quantos = retidos.count
        let base = pegadaAntesDaCalibragem
        travaDaMedida.unlock()
        guard ativa else { return }

        let pegada = Diario.pegadaEmBytes
        let custo = Int64(pegada) - Int64(base)
        Diario.anotar("DEGRAU4 calibragem retidos=\(quantos) pegada=\(pegada)"
            + " custo=\(custo) por_quadro=\(quantos > 0 ? custo / Int64(quantos) : 0)")

        if custo > Int64(plano.calibragem_teto_bytes) {
            soltarCalibragem(motivo: "teto de \(plano.calibragem_teto_bytes) bytes estourado")
            return
        }
        if quantos >= plano.calibragem_quadros {
            soltarCalibragem(motivo: "alvo atingido")
            return
        }
        travaDaMedida.lock()
        querMaisUmQuadro = true
        travaDaMedida.unlock()
    }

    private func soltarCalibragem(motivo: String) {
        travaDaMedida.lock()
        guard calibrando || !retidos.isEmpty else { travaDaMedida.unlock(); return }
        calibrando = false
        querMaisUmQuadro = false
        let quantos = retidos.count
        let base = pegadaAntesDaCalibragem
        retidos.removeAll(keepingCapacity: false)
        travaDaMedida.unlock()

        let pegada = Diario.pegadaEmBytes
        Diario.anotar("DEGRAU4 calibragem fim motivo=\(motivo) retidos_no_pico=\(quantos)"
            + " pegada_base=\(base) pegada_apos_soltar=\(pegada)"
            + " nao_devolvido=\(Int64(pegada) - Int64(base))")
        mudarFase("carregado")
    }

    // --- sessões ----------------------------------------------------------------------------

    private func encerrarTransmissao() {
        Diario.anotar("DEGRAU4 encerrando por plano (duracao=\(plano.duracao_s)s)")
        encerrando = true
        let motivo = NSError(domain: "br.com.queven.quall", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Degrau 4 concluído — a medição terminou sozinha.",
        ])
        // Direto da thread do relógio, sem passar pela fila principal: numa appex não há
        // garantia de que alguém esteja rodando o run loop principal, e um encerramento que
        // não acontece custa um toque humano a mais para parar a transmissão.
        finishBroadcastWithError(motivo)
    }

    private func mudarFase(_ nova: String) {
        travaDaMedida.lock()
        faseAtual = nova
        pegadaNoInicioDaFase = Diario.pegadaEmBytes
        maiorPegadaDaFase = pegadaNoInicioDaFase
        travaDaMedida.unlock()
        Diario.anotar("DEGRAU4 fase=\(nova) pegada=\(Diario.pegadaEmBytes)"
            + " memoria_disponivel=\(Diario.memoriaDisponivel)")
    }

    #if COM_NUCLEO
    /// Ordem de desmonte, e ela é obrigatória:
    ///
    /// 1. baixar a bandeira, para que nenhum quadro novo entre no encoder;
    /// 2. `VTCompressionSessionCompleteFrames` — é **ela** que drena o que está em voo, não
    ///    `Invalidate`. Sem esse passo, um quadro sai do VideoToolbox depois de a track já ter
    ///    sido liberada, e o `send_frame` lê uma caixa morta;
    /// 3. `quall_track_free` e só então `quall_session_close`.
    ///
    /// A inversão dos passos 2 e 3 é a que a intuição sugere, e é uso após liberação.
    private func desmontarSessao(rotulo: String) {
        travaDoEnvio.lock()
        enviando = false
        let n = nucleo, c = codificador
        codificador = nil
        nucleo = nil
        travaDoEnvio.unlock()

        let antes = Diario.pegadaEmBytes
        Diario.anotar("DEGRAU4 \(rotulo) encerrando estatisticas{\(n?.estatisticasDaTrack ?? "")}"
            + " crescimentos_do_buffer=\(c?.crescimentosDoBuffer ?? -1)")
        c?.encerrar()
        // `quall_session_close()` com o par vivo ou morto: a dívida 12 diz que ele volta sem
        // tocar em `closeTransports()` quando existe `mSctpTransport`. O que a fase seguinte
        // mede é exatamente quanto sobrou.
        n?.encerrar()
        let depois = Diario.pegadaEmBytes
        Diario.anotar("DEGRAU4 \(rotulo) encerrada pegada_antes=\(antes) pegada_depois=\(depois)"
            + " devolvido=\(Int64(antes) - Int64(depois))")
    }

    /// `quall_host` **bloqueia** até o receptor chegar. Vai para uma `Thread` própria, e não
    /// para uma fila do GCD, porque uma fila global perde um worker por vários minutos e porque
    /// aqui dá para escolher o tamanho da pilha — que num orçamento de 46,6 MB é linha do
    /// orçamento, não detalhe.
    ///
    /// O prazo é **curto e repetido** em vez de longo e único. Não é preferência: `quall_host`
    /// não tem API de cancelamento (dívida 10), e uma chamada de três minutos é três minutos em
    /// que nada pode desistir — nem a máquina de fases, nem o `broadcastFinished`. Voltar a cada
    /// 45 s cria o ponto de cancelamento que a fronteira não oferece, e de quebra dá uma segunda
    /// chance quando a primeira tentativa esbarra num receptor que ainda não subiu.
    private func subirSessao(porta: UInt16, rotulo: String) {
        let plano = self.plano
        let thread = Thread { [weak self] in
            guard let self else { return }
            let antes = Diario.pegadaEmBytes
            Diario.anotar("DEGRAU4 \(rotulo) chamando quall_host porta=\(porta)"
                + " pin=\(plano.pin) pegada=\(antes)")

            var tentativa = 0
            var pronto: Nucleo?
            while !self.encerrando && tentativa < 4 {
                tentativa += 1
                let candidato = Nucleo()
                if candidato.hospedar(pin: plano.pin, porta: porta,
                                      rotulo: "Tela do iPhone 7", prazoMs: 45_000) {
                    pronto = candidato
                    break
                }
                Diario.anotar("DEGRAU4 \(rotulo) quall_host tentativa=\(tentativa) sem sessão"
                    + " erro=\(Nucleo.ultimoErro()) motivo=\(candidato.ultimoMotivo)"
                    + " pegada=\(Diario.pegadaEmBytes)")
            }

            let depois = Diario.pegadaEmBytes
            guard let novo = pronto else {
                Diario.anotar("DEGRAU4 \(rotulo) quall_host DESISTIU tentativas=\(tentativa)"
                    + " pegada=\(depois)")
                self.mudarFase("\(rotulo)-falhou")
                return
            }
            Diario.anotar("DEGRAU4 \(rotulo) sessao de pe tentativas=\(tentativa)"
                + " porta=\(novo.porta) par={\(novo.parJson)}"
                + " pegada_antes=\(antes) pegada_depois=\(depois)"
                + " delta=\(Int64(depois) - Int64(antes))")

            do {
                let codificador = try CodificadorH264(
                    largura: plano.largura, altura: plano.altura, fps: plano.fps,
                    bitrate: plano.bitrate, tetoEmVoo: plano.encodes_em_voo)
                codificador.aoSair = { [weak self] annexb, pts, chave in
                    guard let self else { return }
                    let carimbo = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
                    novo.enviar(annexb: annexb, timestampUs: carimbo, idr: chave)
                    self.travaDoEnvio.lock()
                    self.quadrosEncodados += 1
                    if chave { self.idrsEncodados += 1 }
                    self.travaDoEnvio.unlock()
                    // Só agora o pedido pode ser considerado honrado (dívida 15).
                    if chave { novo.idrEntregue() }
                }
                self.travaDoEnvio.lock()
                self.codificador = codificador
                self.nucleo = novo
                self.ultimoEncodePts = -1
                self.enviando = !self.encerrando
                self.travaDoEnvio.unlock()
                Diario.anotar("DEGRAU4 \(rotulo) encoder pronto hardware=\(codificador.porHardware)"
                    + " pedido=\(plano.largura)x\(plano.altura)"
                    + " buffer_annexb=\(codificador.capacidadeInicial)"
                    + " pegada=\(Diario.pegadaEmBytes)")
                self.mudarFase(rotulo == "sessao1" ? "enviando" : "enviando2")
            } catch {
                Diario.anotar("DEGRAU4 \(rotulo) encoder FALHOU \(error)")
                self.travaDoEnvio.lock()
                self.nucleo = novo
                self.travaDoEnvio.unlock()
                self.mudarFase("\(rotulo)-sem-encoder")
            }
        }
        thread.stackSize = 512 * 1024
        thread.name = "quall.\(rotulo)"
        thread.start()
    }
    #endif

    // =========================================================================================
    // Relato de 1 Hz — acumulado **e** janela
    // =========================================================================================

    /// Delta de janela para contador que **pode reiniciar**.
    ///
    /// Existe porque a corrida do degrau 4 morreu aqui, aos 464 s, com `EXC_BREAKPOINT`: os
    /// contadores do núcleo são por **track**, e a segunda sessão abre uma track nova cujo
    /// `enviados` recomeça em zero. `UInt64(0) - UInt64(27000)` é estouro, e o Swift derruba o
    /// processo — o instrumento matou o processo que ele media.
    ///
    /// Quando o contador anda para trás, a leitura certa não é zero nem negativo: é que **tudo o
    /// que ele tem agora** apareceu dentro desta janela.
    private func deltaDeJanela(_ atual: UInt64, _ marco: UInt64) -> UInt64 {
        atual >= marco ? atual - marco : atual
    }

    private func relatar() {
        travaDaMedida.lock()
        let agora = CFAbsoluteTimeGetCurrent()
        let decorrido = agora - inicio
        let desdeOUltimo = ultimoQuadro > 0 ? agora - ultimoQuadro : decorrido
        let v = quadrosDeVideo, a = quadrosDeAudio
        let maior = maiorIntervalo, m100 = acimaDe100ms, m500 = acimaDe500ms, m1s = acimaDe1s
        let maiorNaJanela = maiorIntervaloDaJanela
        maiorIntervaloDaJanela = 0
        let dim = dimensao
        let fase = faseAtual
        let pegada = Diario.pegadaEmBytes
        if pegada > maiorPegadaDaFase { maiorPegadaDaFase = pegada }
        let baseDaFase = pegadaNoInicioDaFase
        let picoDaFase = maiorPegadaDaFase

        let janela = max(0.001, decorrido - marcoT)
        let videoNaJanela = v - marcoVideo
        let pegadaNaJanela = Int64(pegada) - Int64(marcoPegada)
        marcoT = decorrido
        marcoVideo = v
        marcoPegada = pegada
        travaDaMedida.unlock()

        var linha = String(format:
            "DEGRAU4 t=%.2f fase=%@ video=%d audio=%d fps_vida=%.2f fps_janela=%.2f"
            + " desde_ultimo=%.3f maior_intervalo=%.3f maior_intervalo_janela=%.3f"
            + " acima100ms=%d acima500ms=%d acima1s=%d dim=%@"
            + " memoria_disponivel=%d pegada=%llu pegada_janela=%lld"
            + " pegada_base_fase=%llu pegada_pico_fase=%llu",
            decorrido, fase, v, a,
            decorrido > 0 ? Double(v) / decorrido : 0, Double(videoNaJanela) / janela,
            desdeOUltimo, maior, maiorNaJanela, m100, m500, m1s, dim,
            Diario.memoriaDisponivel, pegada, pegadaNaJanela, baseDaFase, picoDaFase)

        #if COM_NUCLEO
        travaDoEnvio.lock()
        let nucleo = self.nucleo
        let codificador = self.codificador
        let encodados = quadrosEncodados, idrs = idrsEncodados
        let encodadosNaJanela = deltaDeJanela(encodados, marcoEncodados)
        marcoEncodados = encodados
        travaDoEnvio.unlock()

        if let nucleo {
            let c = nucleo.fotografia
            let enviadosNaJanela = deltaDeJanela(c.enviados, marcoEnviados)
            marcoEnviados = c.enviados
            linha += " encodados=\(encodados) encodados_janela=\(encodadosNaJanela) idrs=\(idrs)"
                + " enviados=\(c.enviados) enviados_janela=\(enviadosNaJanela)"
                + " recusados=\(c.recusados) status=\(c.ultimoStatus)"
                + " pedidos_idr=\(c.pedidosDeIdr)"
            if let codificador {
                linha += " saida=\(codificador.dimensaoDaSaida)"
                    + " maior_quadro=\(codificador.maiorQuadro)"
                    + " desc_fila=\(codificador.descartadosPorFila)"
                    + " desc_encoder=\(codificador.descartadosPeloEncoder)"
                    + " cresc_buffer=\(codificador.crescimentosDoBuffer)"
            }
            // Os contadores do núcleo a cada 10 s: `idrs_without_parameters` diferente de zero é
            // defeito **desta** casca, e é o único jeito de saber sem abrir o `.h264` no outro
            // lado.
            let contadores = nucleo.estatisticasDaTrack
            if Int(decorrido) % 10 == 0 {
                linha += " nucleo{\(contadores)}"
            }

            // Alarmes. Um degrau que roda bonito e mede outra coisa é pior que um que quebra:
            // estas quatro condições produziriam números plausíveis e errados, e nenhuma delas
            // gritava antes.
            var alarmes: [String] = []
            if let codificador {
                let pedida = "\(plano.largura)x\(plano.altura)"
                let saida = codificador.dimensaoDaSaida
                if saida != "?" && saida != pedida {
                    // O VideoToolbox escala o buffer de entrada sozinho — mas se não escalar, o
                    // nível H.264 do fluxo passa do que o SDP anunciou (dívida 16) e o receptor
                    // fica sem imagem por um motivo que não aparece em lugar nenhum.
                    alarmes.append("SAIDA-NAO-E-\(pedida)(\(saida))")
                }
                if codificador.crescimentosDoBuffer > 0 {
                    alarmes.append("BUFFER-CRESCEU-\(codificador.crescimentosDoBuffer)x")
                }
            }
            // `idrs_without_parameters` diferente de zero é IDR sem SPS/PPS: quem entra na
            // sessão depois nunca monta a primeira imagem. É o defeito medido no Windows no M1.
            if !contadores.contains("\"idrs_without_parameters\":0") && !contadores.isEmpty {
                alarmes.append("IDR-SEM-PARAMETROS")
            }
            // Recusa é normal enquanto o ICE não fechou; recusa que domina a janela inteira, com
            // a sessão de pé, é o transporte caído — e `send_frame` devolvendo sucesso com o par
            // morto por 30 s (dívida 13) é exatamente por que isto precisa ser dito em voz alta.
            if enviadosNaJanela == 0 && encodadosNaJanela > 0 {
                alarmes.append("NADA-SAIU-NESTA-JANELA(status=\(c.ultimoStatus))")
            }
            if !alarmes.isEmpty { linha += " ALARME=" + alarmes.joined(separator: ",") }
        }
        #endif

        Diario.anotar(linha)
    }
}
