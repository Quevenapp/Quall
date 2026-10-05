import ReplayKit
import CoreMedia
import CoreVideo

/// O emissor de tela do Quall: captura por ReplayKit, encode por VideoToolbox, envio por
/// `quall_track_send_frame` — tudo dentro da Broadcast Upload Extension.
///
/// **Por que a sessão inteira mora aqui**, e não no app: decidido em `docs/arquitetura-ios.md`
/// por três projetos independentes julgados em três lentes. A alternativa — o app hospeda e a
/// extension manda quadros por IPC — aposta o produto numa garantia de segundo plano que o iOS
/// **não** oferece: se o app for suspenso enquanto a extension transmite, o espelhamento morre.
/// Aqui o app só configura, mostra e cancela.
///
/// ## O orçamento não é mais o risco
///
/// Medido no iPhone 7 (iOS 15.8.8) em 2026-08-22, corrida de 620 s: o teto do jetsam para esta
/// extension é de **50,00 MB**, e o mesmo caminho de código deste arquivo — núcleo, encoder,
/// buffers do ReplayKit e rede — ficou em regime entre **5,23 e 7,06 MB**, terminando em
/// 5,23 MB. **A folga do produto é de ~43 MB.**
///
/// O pico de 12,97 MB daquela corrida **não conta como pico do produto**: ele é da calibragem de
/// retenção, que segurava `CMSampleBuffer` de propósito para responder se os buffers do ReplayKit
/// já vinham pagos. Era instrumento — e o maior consumidor de memória da corrida foi justamente
/// ele. Este arquivo é escrito para clareza e correção, não para economizar bytes que sobram.
///
/// ## O que este arquivo não tem, de propósito
///
/// Não há arnês. Nem máquina de fases, nem calibragem de retenção, nem relatório de 1 Hz com
/// contadores de janela. Na corrida de 464 s **o instrumento derrubou o processo que ele media**:
/// um delta de `UInt64` estourou porque os contadores do núcleo são por track e a segunda sessão
/// reinicia em zero. De fora, isso é indistinguível de um defeito do produto — e um defeito do
/// produto é o que teria sido relatado. O que sobreviveu está em `Diagnostico`, desligado por
/// padrão e fora do caminho do quadro.
///
/// ## Comportamentos esperados que não são defeito
///
/// * **Conteúdo protegido por DRM sai preto.** É o ReplayKit que faz isso, por desenho, e vale
///   igual em todas as plataformas (`FLAG_SECURE` no Android). Não há contorno, e tentar um
///   seria trabalhar contra a plataforma.
/// * **A pessoa pode parar a transmissão a qualquer instante** pelo indicador vermelho. Isso
///   chega como `broadcastFinished`, sem aviso, e é tratado como encerramento normal.
/// * **Ligação telefônica** chega como `broadcastPaused` / `broadcastResumed`. Na volta, o
///   receptor precisa de um IDR — sem ele, fica com a última imagem congelada até o próximo
///   quadro-chave agendado.
class ManipuladorDeTela: RPBroadcastSampleHandler {

    /// Prazo de cada tentativa de `quall_host`. Curto e re-armado em laço porque a fronteira C
    /// **não tem cancelamento** (dívida 10): uma chamada de três minutos são três minutos em que
    /// nada pode desistir nem relatar. Vinte segundos é o que separa "a permissão de rede local
    /// está negada" de a pessoa ficar olhando uma tela de espera que nunca muda.
    ///
    /// O intervalo entre tentativas é de milissegundos — a sessão nova nasce antes de o laço dar
    /// a volta —, mas ele existe: um receptor que tente conectar exatamente nessa fresta leva
    /// recusa e precisa tentar de novo. É a consequência conhecida de não haver cancelamento.
    private static let prazoPorTentativa: UInt32 = 20_000

    /// Quanto tempo esperar por um receptor antes de encerrar sozinho. Uma transmissão esquecida
    /// é bateria queimando com o indicador vermelho ligado.
    private static let esperaMaxima: Double = 600

    /// Teto absoluto de tentativas de hospedar. Ver o comentário no laço: a dívida 21 diz que a
    /// `Track` vazada da dívida 4 é cobrada **por tentativa**, e que nenhuma casca pode tirar o
    /// teto antes de a dívida 4 ser consertada. Aqui isso pesa mais que no app, porque o processo
    /// tem 50 MB.
    private static let tetoDeTentativas = 40

    /// Piso de memória disponível. O regime medido deixa ~43 MB livres; chegar a 6 MB significa
    /// que algo saiu do previsto, e encerrar com um motivo legível é melhor que ser morto pelo
    /// jetsam — que não deixa recado nenhum.
    private static let pisoDeMemoria = 6 * 1024 * 1024

    // --- estado -----------------------------------------------------------------------------

    private let pedido = Compartilhado.lerPedido()

    /// Levantada antes de qualquer desmonte e no `broadcastFinished`. É o ponto de cancelamento
    /// que a fronteira C não oferece.
    private let travaDoFim = NSLock()
    private var _encerrando = false
    private var encerrando: Bool {
        get { travaDoFim.lock(); defer { travaDoFim.unlock() }; return _encerrando }
        set { travaDoFim.lock(); _encerrando = newValue; travaDoFim.unlock() }
    }

    /// Trava do trio que quatro threads disputam — a do ReplayKit (que entrega quadros), a de
    /// saída do VideoToolbox (que devolve os encodados), a da supervisão de 1 Hz e a que fica
    /// bloqueada em `quall_host`. Não é preciosismo: em Swift, ler uma propriedade de objeto
    /// enquanto outra thread a substitui é retain/release concorrente, e isso derruba o processo.
    private let travaDoEnvio = NSLock()
    private var nucleo: Nucleo?
    private var codificador: CodificadorH264?
    private var enviando = false
    private var pausado = false
    private var ultimoEncodePts: Double = -1
    /// Dimensão da **entrada** com que o encoder atual foi construído. Muda quando a tela gira.
    private var entradaAtual = CGSize.zero
    private var bitrateAtual = 0

    private var relogio: DispatchSourceTimer?
    private var comecouEm = CFAbsoluteTimeGetCurrent()

    /// Última linha publicada. Escrita pela thread de `quall_host` e pela supervisão de 1 Hz, e
    /// por isso sob trava própria: em Swift, substituir uma `String` de dentro de uma struct
    /// enquanto outra thread a lê é retain/release concorrente — derruba o processo, não produz
    /// número errado.
    private let travaDoEstado = NSLock()
    private var estadoPublicado = EstadoDoEmissor(etapa: .preparando)

    /// Só para o diagnóstico: última orientação que o ReplayKit carimbou no quadro.
    private var orientacaoVista: Int = -1
    /// Menor `os_proc_available_memory()` visto na transmissão. Uma comparação de `Int` por
    /// segundo, na thread da supervisão, e sai numa linha única no desmonte.
    private var menorMemoriaLivre = Int.max
    /// Quantas amostras da sentinela já passaram, e de quantas em quantas uma vira linha de log.
    /// Ver o comentário na sentinela: o que decide se a pegada cresce é a **série**, não o pico.
    private var amostrasDaSerie = 0
    private static let amostrasPorLinha = 5

    /// Maior `phys_footprint` visto, e o orçamento (livre + pegada) na mesma amostra.
    ///
    /// Sozinha a pegada não julga nada: o teto do jetsam muda de aparelho para aparelho, e é a
    /// **soma** que o revela. Guardar as duas na mesma amostra é o que impede a conta errada de
    /// somar o pior livre de um segundo com a pior pegada de outro.
    private var maiorPegada = 0
    private var orcamentoNoPico = 0

    deinit {
        relogio?.cancel()
        relogio = nil
    }

    // =========================================================================================
    // Ciclo de vida da transmissão
    // =========================================================================================

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // A extension é outro processo: instala seu próprio gancho antes de usar o núcleo.
        quall_install_panic_hook(nil, nil)
        // O idioma do app (o botão PT | EN, ou o do sistema), antes de qualquer texto: o processo da
        // appex pode ter nascido antes da troca (`Comum/Idioma.swift`).
        Idioma.reler()
        comecouEm = CFAbsoluteTimeGetCurrent()
        encerrando = false
        Compartilhado.limparCancelamento()

        guard let pedido, pedido.utilizavel else {
            // Sem pedido não há PIN, e sem PIN a pessoa digitaria seis dígitos que nunca casam.
            // Falhar aqui, com texto, é a única saída honesta: acontece quando a transmissão é
            // iniciada pela Central de Controle, sem passar pela tela do app.
            Diagnostico.falha("APPEX sem pedido no App Group — transmissão iniciada fora do app?")
            desistir(tr("Comece pelo app Quall, tocando em “Espelhar esta tela”."))
            return
        }

        // A linha de partida da memória, antes de a sessão e o encoder existirem: é contra ela
        // que o regime é lido, e é ela que revela o orçamento do jetsam **deste** aparelho.
        let livreAoNascer = Diagnostico.memoriaDisponivel
        let pegadaAoNascer = Diagnostico.pegadaEmBytes
        Diagnostico.nota("APPEX começou porta=\(pedido.porta)"
            + " memoria_disponivel=\(livreAoNascer)"
            + " pegada=\(pegadaAoNascer)"
            + " orcamento=\(livreAoNascer > 0 ? livreAoNascer + pegadaAoNascer : 0)")
        publicar(EstadoDoEmissor(etapa: .preparando, porta: pedido.porta))

        subirSupervisao()
        subirSessao(pedido)
    }

    /// Chega numa ligação telefônica, entre outras coisas. O ReplayKit para de entregar quadros
    /// sozinho; a bandeira existe para que nada tente encodar no meio do caminho.
    override func broadcastPaused() {
        travaDoEnvio.lock(); pausado = true; travaDoEnvio.unlock()
        Diagnostico.nota("APPEX broadcastPaused")
    }

    /// Na volta, o receptor está com a última imagem congelada. Sem um IDR ele fica assim até o
    /// próximo quadro-chave agendado — até um segundo na tela, dois na câmera. Pedir um agora
    /// custa um quadro maior e devolve a imagem na hora.
    override func broadcastResumed() {
        travaDoEnvio.lock()
        pausado = false
        ultimoEncodePts = -1
        let n = nucleo
        travaDoEnvio.unlock()
        n?.exigirIdr()
        Diagnostico.nota("APPEX broadcastResumed — IDR exigido")
    }

    /// Chega quando a pessoa toca no indicador vermelho, quando o app pede o cancelamento, e
    /// quando o sistema decide. Sem aviso, e com prazo.
    ///
    /// **A ordem do desmonte é obrigatória**: bandeira, depois `VTCompressionSessionCompleteFrames`
    /// (é ela que drena o que está em voo, não `Invalidate`), depois `quall_track_free` e só
    /// então `quall_session_close`. A inversão dos dois últimos é a que a intuição sugere, e é
    /// uso após liberação.
    ///
    /// **Nada de `quall_cleanup()`**: ele trava a libdatachannel num mutex global (dívida 2).
    override func broadcastFinished() {
        encerrando = true
        relogio?.cancel()
        relogio = nil

        travaDoEnvio.lock()
        enviando = false
        let n = nucleo
        let c = codificador
        nucleo = nil
        codificador = nil
        travaDoEnvio.unlock()

        publicar(EstadoDoEmissor(etapa: .encerrado, quadros: n?.enviados ?? 0))
        // **A única linha de instrumento por corrida desta appex.**
        //
        // Ela sai aqui, e não a cada segundo, porque aqui a bandeira de envio já está baixada e
        // nenhum quadro pode estar em voo: `estatisticasDaTrack` segura a mesma trava do
        // `send_frame`, e chamá-la periodicamente poria relatório e quadro disputando a trava —
        // com o resultado aparecendo como quadro perdido, que é bem mais difícil de atribuir ao
        // instrumento do que um processo morto. Durante a corrida quem testemunha é o `.h264`
        // gravado do outro lado, que não custa nada a este processo.
        Diagnostico.nota("APPEX broadcastFinished enviados=\(n?.enviados ?? 0)"
            + " recusados=\(n?.recusados ?? 0)"
            + " saida=\(c?.dimensaoDaSaida ?? "?")"
            + " desc_fila=\(c?.descartadosPorFila ?? 0)"
            + " desc_encoder=\(c?.descartadosPeloEncoder ?? 0)"
            + " cresc_buffer=\(c?.crescimentosDoBuffer ?? 0)"
            + " menor_memoria_livre=\(menorMemoriaLivre == Int.max ? 0 : menorMemoriaLivre)"
            + " maior_pegada=\(maiorPegada) orcamento=\(orcamentoNoPico)"
            + " memoria_disponivel=\(Diagnostico.memoriaDisponivel)"
            + " nucleo={\(n?.estatisticasDaTrack ?? "")}")
        // O que o remendo de SPS fez, dito em voz alta: é o que separa 4 ms de 170 ms no decode do
        // outro lado, e um remendo que desiste em silêncio é pior do que remendo nenhum.
        Diagnostico.nota("APPEX \(c?.remendoDeSPS.resumo() ?? "sem codificador")")

        // Drenar é barato e obrigatório: no máximo dois quadros em voo, pelo teto do encoder.
        c?.encerrar()

        // Fechar a sessão **não** é barato, e este callback tem prazo do sistema:
        // `quall_session_close` desce até `Link::close`, que não tem prazo próprio, e com o par
        // sumido pode pendurar. Fechar numa thread com espera limitada dá ao receptor o
        // encerramento limpo no caso comum e não troca isso por uma appex morta no meio — que é
        // exatamente o mesmo resultado de não fechar, com risco a mais.
        if let n {
            let pronto = DispatchSemaphore(value: 0)
            let t = Thread {
                n.encerrar()
                pronto.signal()
            }
            t.stackSize = 512 * 1024
            t.name = "quall.fechamento"
            t.start()
            if pronto.wait(timeout: .now() + 2.0) == .timedOut {
                Diagnostico.falha("APPEX quall_session_close passou de 2 s; o processo vai morrer antes")
            }
        }
        Compartilhado.apagarPedido()
    }

    // =========================================================================================
    // Quadros
    // =========================================================================================

    /// Barato de propósito: sem log por quadro, sem alocação por quadro, sem chamada de
    /// diagnóstico. O único trabalho é o freio de taxa, a conferência de dimensão e o encode.
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        // Áudio ainda não tem track neste marco. Descartar é o comportamento certo: enfileirar
        // para "quando houver" seria memória crescendo dentro de um teto de 50 MB.
        guard sampleBufferType == .video else { return }
        guard let imagem = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        travaDoEnvio.lock()
        let ativo = enviando && !pausado
        let n = nucleo
        travaDoEnvio.unlock()
        guard ativo, let nucleo = n else { return }

        // Freio de taxa: o ReplayKit entrega ~60 fps (medido: 59,86 no iPhone 7 com a tela
        // imóvel) e o produto quer 30 para tela. Fica no relógio de apresentação, e não num
        // contador, para que uma pausa do ReplayKit não acumule dívida de quadros.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let segundos = CMTimeGetSeconds(pts)
        let alvoFps = Double(pedido?.fps ?? 30)
        let intervaloMinimo = 1.0 / alvoFps - 0.002
        travaDoEnvio.lock()
        let cedoDemais = ultimoEncodePts >= 0 && segundos - ultimoEncodePts < intervaloMinimo
        if !cedoDemais { ultimoEncodePts = segundos }
        travaDoEnvio.unlock()
        if cedoDemais { return }

        guard let codificador = encoderPara(imagem, nucleo: nucleo) else { return }

        anotarOrientacao(sampleBuffer)

        // Uma leitura por quadro, e o pedido fica guardado na casca até o encoder devolver de
        // fato um quadro chave (dívida 15).
        nucleo.recolherPedidoDeIdr()
        codificador.encodar(imagem, pts: pts,
                            duracao: CMTime(value: 1, timescale: Int32(alvoFps)),
                            forcarIDR: nucleo.precisaDeIdr)
    }

    /// Devolve o encoder pronto para esta imagem, construindo-o na primeira vez e
    /// **reconstruindo-o quando a tela gira**.
    ///
    /// O ReplayKit entrega o buffer na orientação corrente. Com um `VTCompressionSession` fixo em
    /// 720x1280, um quadro 1334x750 entra deitado numa sessão em pé e o VideoToolbox o **estica**
    /// — a imagem chega ao receptor deformada, e nada em lugar nenhum reclama. Recriar a sessão
    /// custa 16 KB de pegada (medido) e um punhado de quadros; deformar custa a transmissão
    /// inteira.
    ///
    /// **O que isto não resolve**: se um dia o ReplayKit mantiver a dimensão do buffer e girar só
    /// o carimbo `RPVideoSampleOrientation`, a imagem sai de lado e este caminho não percebe.
    /// Corrigir isso exigiria rotacionar pixels dentro da appex — CoreImage, Metal ou vImage —, e
    /// o caminho errado de reescalonamento já custou 30 MB contra 0,1 MB neste projeto. A saída
    /// certa é o núcleo carregar a orientação junto do quadro; hoje `QuadroCodificado` não tem
    /// esse campo. Está relatado.
    private func encoderPara(_ imagem: CVPixelBuffer, nucleo: Nucleo) -> CodificadorH264? {
        let entrada = CGSize(width: CVPixelBufferGetWidth(imagem),
                             height: CVPixelBufferGetHeight(imagem))

        travaDoEnvio.lock()
        if let atual = codificador, entrada == entradaAtual {
            travaDoEnvio.unlock()
            return atual
        }
        let anterior = codificador
        codificador = nil
        travaDoEnvio.unlock()

        // Drena o anterior **antes** de soltá-lo: um quadro que saísse do VideoToolbox depois de
        // a track ter sido liberada leria uma caixa morta. Aqui a track continua viva, mas a
        // ordem é a mesma e custa nada.
        anterior?.encerrar()

        let teto = (maior: pedido?.tetoMaior ?? 1920, menor: pedido?.tetoMenor ?? 1080)
        let (l, a) = CodificadorH264.destino(largura: Int(entrada.width),
                                             altura: Int(entrada.height),
                                             tetoMaior: teto.maior, tetoMenor: teto.menor)
        let fps = pedido?.fps ?? 30
        // Sem pedido, o teto de taxa sai do mesmo lugar que o de resolução — e do tamanho que de
        // fato vai ser codificado, `l`x`a`, não do teto pedido. `4_000_000` cravado aqui foi um
        // dos cinco literais que não subiram quando a resolução subiu em 01/09/2026.
        let bitrate = bitrateAtual > 0
            ? bitrateAtual
            : (pedido?.bitrate ?? PedidoDeEspelhamento.tetoDeTaxa(
                maior: Int(max(l, a)), menor: Int(min(l, a)), fps: fps,
                alvoMaxFs: Resolucao.escolhida.maxFs))

        do {
            let novo = try CodificadorH264(largura: l, altura: a, fps: fps, bitrate: bitrate,
                                           perfil: .tela, tetoEmVoo: 2)
            // `[weak nucleo]`, e não forte: o encoder é campo desta classe e o núcleo também;
            // um par de referências fortes cruzadas manteria a sessão viva depois do desmonte,
            // dentro de um processo que o sistema mata sem cerimônia.
            novo.aoSair = { [weak nucleo] annexb, pts, chave in
                guard let nucleo else { return }
                // `Carimbo.microssegundos` e não `UInt64(...)` direto: um `CMTime` inválido faz
                // `CMTimeGetSeconds` devolver `NaN`, e `UInt64(NaN)` **derruba o processo**.
                let carimbo = Carimbo.microssegundos(de: pts)
                nucleo.enviar(annexb: annexb, timestampUs: carimbo, idr: chave)
                // Só agora o pedido de IDR pode ser considerado honrado (dívida 15).
                if chave { nucleo.idrEntregue() }
            }
            travaDoEnvio.lock()
            codificador = novo
            entradaAtual = entrada
            bitrateAtual = bitrate
            travaDoEnvio.unlock()
            // Quem já estava assistindo perdeu a referência quando a sessão de compressão trocou.
            nucleo.exigirIdr()
            // O pixel format da entrada é o que decide a faixa de cor do fluxo, e a casca **não
            // escolhe** o que o ReplayKit entrega. Dizê-lo por extenso transforma em medição o
            // que até a primeira corrida do produto era suposição — e foi essa suposição que
            // deixou passar um fluxo em faixa completa, contra o que o contrato padroniza.
            let formato = CVPixelBufferGetPixelFormatType(imagem)
            Diagnostico.nota("APPEX encoder \(anterior == nil ? "criado" : "recriado")"
                + " entrada=\(Int(entrada.width))x\(Int(entrada.height)) saida=\(l)x\(a)"
                + " formato_do_replaykit=\(CodificadorH264.nomeDoFormato(formato))"
                + " fps=\(fps) bitrate=\(bitrate)"
                + " memoria_disponivel=\(Diagnostico.memoriaDisponivel)")
            return novo
        } catch {
            Diagnostico.falha("APPEX VTCompressionSession não subiu: \(SanitizacaoDoLog.erro(error))")
            desistir(tr("O codificador de vídeo deste iPhone não iniciou. Tente de novo."))
            return nil
        }
    }

    /// Lê o carimbo de orientação que o ReplayKit põe no quadro. **Só para diagnóstico** — ele
    /// não muda o caminho do quadro. Fica registrado quando muda, e nunca por quadro.
    private func anotarOrientacao(_ amostra: CMSampleBuffer) {
        guard Diagnostico.ligado else { return }
        let valor = CMGetAttachment(amostra, key: RPVideoSampleOrientationKey as CFString,
                                    attachmentModeOut: nil) as? NSNumber
        let atual = valor?.intValue ?? -1
        guard atual != orientacaoVista else { return }
        orientacaoVista = atual
        Diagnostico.nota("APPEX orientação do ReplayKit mudou para \(atual)")
    }

    // =========================================================================================
    // A sessão
    // =========================================================================================

    /// `quall_host` **bloqueia**. Vai para uma `Thread` própria, e não para uma fila do GCD,
    /// porque uma fila global perde um worker por dezenas de segundos e porque aqui dá para
    /// escolher o tamanho da pilha.
    private func subirSessao(_ pedido: PedidoDeEspelhamento) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            var tentativa = 0
            var recuo: Double = 0
            /// Último instante em que **alguém apareceu** — mesmo que para errar o PIN. O teto de
            /// espera conta a partir daqui, e não do começo da transmissão: quem está tentando
            /// entrar e errando a digitação não deveria ver a transmissão morrer embaixo dele.
            var ultimoSinalDeVida = self.comecouEm
            /// O motivo da última tentativa que falhou por algo que não seja o prazo. Ele
            /// **sobrevive** às voltas seguintes do laço: sem isso, a mensagem "alguém errou o
            /// PIN" seria apagada um instante depois pela publicação de `.esperando` da tentativa
            /// seguinte, e a pessoa que apresenta veria um piscar e nada mais.
            var conselhoVigente = ""

            while !self.encerrando {
                if CFAbsoluteTimeGetCurrent() - ultimoSinalDeVida > ManipuladorDeTela.esperaMaxima {
                    self.desistir(tr("Ninguém entrou na transmissão. Escolha a tela e toque em "
                        + "“%@” de novo quando o outro aparelho estiver pronto.", tr("Espelhar")))
                    return
                }
                // Teto absoluto, pelo mesmo motivo do lado da câmera: `esperaMaxima` conta do
                // último sinal de vida, e "sinal de vida" inclui uma tentativa que falhou por algo
                // que não seja o prazo. Numa rede em que o pareamento fecha e o ICE não, o relógio
                // reinicia a cada volta e o laço nunca acaba — e a dívida 21 diz que o núcleo cobra
                // uma `Track` vazada **por tentativa** (dívida 4), dentro de um processo de 50 MB.
                if tentativa >= ManipuladorDeTela.tetoDeTentativas {
                    // O teto é 40: sempre plural, nas duas línguas.
                    self.desistir(tr("Foram %ld tentativas sem conseguir abrir a conexão. "
                        + "Confira se os dois aparelhos estão na mesma rede Wi‑Fi e se ela não "
                        + "isola os aparelhos entre si.", tentativa))
                    return
                }
                tentativa += 1
                self.publicar(EstadoDoEmissor(etapa: .esperando, porta: pedido.porta,
                                              conselho: conselhoVigente))
                // O roteiro de bancada espera esta linha para subir o receptor no MacBook na
                // hora certa. Uma por tentativa, e a espera tem prazo de 20 s.
                Diagnostico.nota("APPEX chamando quall_host porta=\(pedido.porta)"
                    + " tentativa=\(tentativa)")

                let inicioDaTentativa = CFAbsoluteTimeGetCurrent()
                let candidato = Nucleo()
                let conhecidos = Compartilhado.lerPares()
                let subiu = candidato.hospedar(
                    pin: pedido.pin,
                    porta: pedido.porta,
                    deviceId: pedido.deviceId,
                    nome: pedido.nome,
                    tipo: QUALL_TRACK_KIND_SCREEN,
                    rotulo: "Tela de \(pedido.nome)", // sem-traducao
                    paresConhecidos: conhecidos,
                    prazoMs: ManipuladorDeTela.prazoPorTentativa)

                if self.encerrando { candidato.encerrar(); return }

                guard subiu else {
                    let erro = candidato.ultimoMotivo
                    let gastou = CFAbsoluteTimeGetCurrent() - inicioDaTentativa
                    Diagnostico.nota("APPEX quall_host tentativa=\(tentativa) sem sessão"
                        + String(format: " em %.1f s", gastou) + " status=\(candidato.statusDaEspera.rawValue) erro=\(SanitizacaoDoLog.causaExterna(erro))")

                    // Prazo estourado é o caso **normal** de quem espera: ninguém conectou ainda.
                    // Ele não vira erro na tela; vira mais uma volta do laço, na hora. Qualquer
                    // outro motivo a pessoa precisa ler — em especial o do ICE, que é a permissão
                    // de Rede Local negada e ela consegue consertar sozinha.
                    if !erro.hasPrefix("tempo esgotado:") && !erro.isEmpty {
                        conselhoVigente = Nucleo.conselho(para: erro)
                        // Alguém apareceu — errando o PIN, desistindo no meio, seja o que for. O
                        // relógio do teto de espera reinicia: quem está tentando entrar não pode
                        // ser punido pela própria tentativa.
                        ultimoSinalDeVida = CFAbsoluteTimeGetCurrent()
                        self.publicar(EstadoDoEmissor(
                            etapa: .esperando, porta: pedido.porta,
                            erro: erro, conselho: conselhoVigente))
                    }

                    // **Piso de tempo entre tentativas.** Uma tentativa que consumiu o prazo
                    // inteiro pode repetir na hora: ela passou vinte segundos ouvindo a porta,
                    // que é exatamente o trabalho. Uma que falhou em um décimo do prazo — porta
                    // ocupada, rede caída, ICE recusado de imediato — repetiria em laço ocupado,
                    // com uma linha de `os_log` por volta, dentro de um processo de 50 MB. Recuo
                    // geométrico até cinco segundos, e ele zera assim que uma tentativa volta a
                    // durar o prazo.
                    if gastou >= Double(ManipuladorDeTela.prazoPorTentativa) / 1000 * 0.8 {
                        recuo = 0
                    } else {
                        recuo = min(5, recuo <= 0 ? 0.5 : recuo * 2)
                        let ate = Date().addingTimeInterval(recuo)
                        // Dormir em fatias para o encerramento não ficar preso no recuo.
                        while !self.encerrando && Date() < ate {
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                    }
                    continue
                }

                // Pareamento fechado: guardar para que o PIN seja pedido **uma vez por par de
                // aparelhos**, e não por sessão, que é a promessa do fluxo.
                //
                // A fusão é com o que está **no arquivo agora**, e não com o `conhecidos` lido lá
                // atrás: o app escreve no mesmo `pares.json`, e vinte segundos de janela entre
                // ler e escrever bastam para uma atualização se perder — com o resultado sendo
                // segredos divergentes entre os dois lados e um pareamento que não volta mais
                // (dívidas 22 e 23).
                Compartilhado.atualizarPares { agora in
                    candidato.paresParaGuardar(somandoA: agora)
                }

                let par = candidato.nomeDoPar
                self.travaDoEnvio.lock()
                self.nucleo = candidato
                self.ultimoEncodePts = -1
                self.enviando = !self.encerrando
                self.travaDoEnvio.unlock()

                self.publicar(EstadoDoEmissor(etapa: .transmitindo,
                                              porta: candidato.porta, par: par))
                Diagnostico.nota("APPEX sessão de pé tentativas=\(tentativa) porta=\(candidato.porta)"
                    + " memoria_disponivel=\(Diagnostico.memoriaDisponivel)")
                return
            }
        }
        thread.stackSize = 512 * 1024
        thread.name = "quall.host"
        thread.start()
    }

    // =========================================================================================
    // Supervisão de 1 Hz
    // =========================================================================================

    /// Um relógio, quatro tarefas, todas fora do caminho do quadro:
    ///
    /// 1. **executar o Cancelar** da tela de espera — é aqui, e não na thread bloqueada em
    ///    `quall_host`, que o botão vira ação;
    /// 2. **sentinela de memória** — encerrar com motivo legível é melhor que o jetsam, que não
    ///    deixa recado;
    /// 3. **recuo sob calor ou baixo consumo** — o A10 num iPhone de 2016 transmitindo por meia
    ///    hora chega lá;
    /// 4. **publicar o estado** para a tela de espera, que é a peça central do fluxo.
    ///
    /// Este relógio é o herdeiro do relatório de 1 Hz do arnês, e a diferença está em tudo o que
    /// ele **não** faz: nada de contadores de janela, nada de aritmética sobre `UInt64`, nada de
    /// pegada por fase. Foi um delta de janela que matou a corrida de 464 s.
    private func subirSupervisao() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.supervisionar() }
        t.resume()
        relogio = t
    }

    private func supervisionar() {
        guard !encerrando else { return }

        if Compartilhado.cancelamentoPedido {
            Diagnostico.nota("APPEX cancelamento pedido pelo app")
            desistir(nil)
            return
        }

        // Sentinela de memória, e a única leitura periódica que sobrou nesta appex. Ela não
        // escreve nada: guarda o menor valor visto num `Int` e só fala se o piso for cruzado. O
        // mínimo sai numa linha só, no desmonte — e é o número que o relato usa.
        let livre = Diagnostico.memoriaDisponivel
        if livre > 0 && livre < menorMemoriaLivre { menorMemoriaLivre = livre }
        // A pegada é lida na **mesma amostra** que o livre, e as duas só são guardadas juntas.
        // O orçamento do jetsam é a soma; guardar cada metade do seu próprio segundo produziria
        // um "orçamento" que nenhum instante da corrida viu.
        let pegada = Diagnostico.pegadaEmBytes
        if pegada > maiorPegada {
            maiorPegada = pegada
            orcamentoNoPico = livre > 0 ? livre + pegada : 0
        }
        // **A série, e não só o máximo.** Quatro corridas de ~100 s em 26/08 deram picos de 5,45
        // a 7,94 MiB, e a diferença acompanhou a **duração**, não o aparelho — o que é compatível
        // com a pegada crescer ao longo da sessão. Num processo com teto de 50 MiB medidos, "cresce
        // devagar" é a diferença entre funcionar dois minutos e morrer por jetsam numa reunião de
        // uma hora. O máximo não distingue "subiu e estabilizou" de "está subindo": só a série
        // distingue, e ela não existia.
        //
        // Uma linha a cada `AMOSTRAS_POR_LINHA` segundos, não a cada segundo: o syslog cru do
        // aparelho já é volumoso, e 5 s dá 240 pontos numa corrida de 20 min — resolução de sobra
        // para ver inclinação. Custo: uma linha de log, fora do caminho do quadro.
        amostrasDaSerie += 1
        if amostrasDaSerie % ManipuladorDeTela.amostrasPorLinha == 0 {
            Diagnostico.nota("APPEX serie t=\(amostrasDaSerie)s"
                + " pegada=\(pegada) livre=\(livre)"
                + " orcamento=\(livre > 0 ? livre + pegada : 0)")
        }
        if livre > 0 && livre < ManipuladorDeTela.pisoDeMemoria {
            Diagnostico.falha("APPEX sentinela de memória disparou: \(livre) bytes livres")
            desistir(tr("O iPhone ficou sem memória para a transmissão."))
            return
        }

        ajustarAoAparelho()

        travaDoEnvio.lock()
        let n = nucleo
        let etapa: EstadoDoEmissor.Etapa = enviando ? .transmitindo : .esperando
        travaDoEnvio.unlock()

        travaDoEstado.lock()
        var novo = estadoPublicado
        travaDoEstado.unlock()
        novo.etapa = etapa
        novo.quadros = n?.enviados ?? 0
        if etapa == .transmitindo {
            novo.erro = ""
            novo.conselho = ""
        }
        publicar(novo)
    }

    /// Recuo sob calor ou modo de baixo consumo.
    ///
    /// Não é economia de memória — dela sobram ~43 MB. É o A10: uma transmissão longa esquenta, e
    /// o sistema responde reduzindo o clock do encoder. Cair para metade do bitrate antes disso
    /// entrega vídeo pior de propósito, em vez de vídeo travado por acidente.
    ///
    /// **Escrito, não exercitado**: nenhuma corrida desta rodada chegou a `.serious`. Fica
    /// declarado como não provado.
    private func ajustarAoAparelho() {
        // Ver a nota gêmea em `montarCodificador`: o padrão vem do núcleo, não de um literal.
        let base = pedido?.bitrate
            ?? PedidoDeEspelhamento.tetoDeTaxa(maior: 1920, menor: 1080, fps: pedido?.fps ?? 30,
                                               alvoMaxFs: Resolucao.escolhida.maxFs)
        let estado = ProcessInfo.processInfo.thermalState
        let economia = ProcessInfo.processInfo.isLowPowerModeEnabled
        let alvo: Int
        switch estado {
        case .critical: alvo = base / 4
        case .serious: alvo = base / 2
        default: alvo = economia ? base / 2 : base
        }
        travaDoEnvio.lock()
        let precisa = alvo != bitrateAtual
        if precisa { bitrateAtual = alvo }
        let c = codificador
        travaDoEnvio.unlock()
        guard precisa, let c else { return }
        c.ajustarBitrate(alvo)
        Diagnostico.nota("APPEX bitrate ajustado para \(alvo) (térmico=\(estado.rawValue)"
            + " baixo_consumo=\(economia))")
    }

    // =========================================================================================

    private func publicar(_ estado: EstadoDoEmissor) {
        var copia = estado
        copia.carimbo = Date().timeIntervalSince1970
        travaDoEstado.lock()
        estadoPublicado = copia
        travaDoEstado.unlock()
        Compartilhado.publicar(copia)
    }

    /// Encerra a transmissão de dentro.
    ///
    /// É o que faz o Cancelar da tela de espera funcionar **de verdade**: só a extension pode
    /// chamar `finishBroadcastWithError`, e ela desliga o indicador vermelho do sistema. Chamada
    /// direto da thread da supervisão, sem passar pela fila principal — numa appex não há
    /// garantia de que alguém esteja rodando o run loop principal, e um encerramento que não
    /// acontece deixa a pessoa com uma tela que diz "cancelado" e uma transmissão que continua.
    private func desistir(_ conselho: String?) {
        guard !encerrando else { return }
        encerrando = true
        if let conselho {
            publicar(EstadoDoEmissor(etapa: .erro, conselho: conselho))
        }
        let motivo = NSError(domain: "br.com.queven.quall", code: 0, userInfo: [
            NSLocalizedDescriptionKey: conselho ?? tr("Transmissão encerrada."),
        ])
        finishBroadcastWithError(motivo)
    }
}
