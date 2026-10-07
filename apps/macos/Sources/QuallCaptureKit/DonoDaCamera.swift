import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuallIdiomaKit

/// O botão do microfone (R5). Começa **desligado** em toda abertura de tela.
public enum EstadoDoMicrofone: Equatable, Sendable {
    case desligado
    /// Pedindo a permissão, ou abrindo a entrada.
    case pedindo
    case ligado
    /// Sem permissão, ou a política (G5) recusou: o texto diz por quê.
    case recusado(String)
    case falhou(String)

    public var ligado: Bool { self == .ligado }

    public var nome: String {
        switch self {
        case .desligado: return "desligado"
        case .pedindo: return "pedindo"
        case .ligado: return "ligado"
        case .recusado: return "recusado"
        case .falhou: return "falhou"
        }
    }

    /// O porquê, quando há.
    public var motivo: String? {
        switch self {
        case .recusado(let m), .falhou(let m): return m
        default: return nil
        }
    }
}

/// A ficha de um assinante do dono: quem assinou guarda, e desassina com ela.
public final class FichaDoDono: Hashable, @unchecked Sendable {
    public let nome: String
    init(nome: String) { self.nome = nome }
    public static func == (a: FichaDoDono, b: FichaDoDono) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// **O dono da captura no Mac** (R5 fase 4, G1 de `docs/teleprompter-com-camera.md`; o plano em §8.9).
///
/// # Por que existe
///
/// Até aqui a câmera do Mac nascia **dentro** da sessão: a `TransmissaoAoVivo` criava o
/// `CameraCapturer` depois do pareamento (`TransmissaoAoVivo.swift`, `case .camera`), e sem receptor
/// não havia câmera, prévia nem gravação. A tela R5 (e, desde a fase 4, a câmera comum) precisa do
/// contrário: a câmera abre quando a **tela** abre e fecha quando ela fecha, e a transmissão **se
/// pendura** nela quando o receptor pareia e **se solta** quando ele cai — sem reabrir a câmera.
///
/// # As saídas
///
/// - **a prévia**: `AVCaptureVideoPreviewLayer` sobre a mesma `sessao` (`novaCamadaDePrevia`).
///   Esconder a prévia é esconder a vista; a sessão não sabe;
/// - **os assinantes** (`assinar`/`desassinar`): uma lista, e não vagas fixas como no iOS. A
///   transmissão assina só o vídeo (`FonteDoDono`), o microfone de cada sessão só o som, o gravador
///   os dois. Pendurar ou soltar um não mexe nos outros, nem na câmera.
///
/// # O microfone
///
/// Numa **`AVCaptureSession` só dele** (`sessaoDoMicrofone`), aberta e fechada **de verdade** pelo
/// botão, numa fila de controle própria: no iOS, ligar o microfone na sessão da câmera parou a imagem
/// por 434 ms (§8.5). O PTS de cada buffer vai ao relógio da sessão da câmera
/// (`CMSyncConvertTime`) antes de sair daqui: quem assina recebe o som no relógio dos quadros.
/// O aparelho sai da `PoliticaDoMicrofone` (G5): na bancada, só um dispositivo **virtual** pelo
/// `uniqueID` do argumento, nunca o microfone do MacBook — e o dono confere o transporte de novo,
/// no aparelho de verdade, antes de abrir.
///
/// `microfoneSintetico` (bancada): o botão liga uma **fonte nossa**, sem aparelho de áudio nenhum,
/// que gera o `TomDeQuatroNotas` em buffers de 10 ms carimbados no relógio de host. Prova o caminho
/// inteiro depois da captura sem o BlackHole.
///
/// # Threads
///
/// Os quadros chegam na `fila`; o som na `filaDoAudio`; o microfone liga e desliga na
/// `controleDoMicrofone` (que nunca faz `sync` na `fila`). O que a tela lê (`montado`, `interrupcao`,
/// `microfone`) muda **na principal**, e `aoMudar` avisa lá.
public final class DonoDaCamera: NSObject, @unchecked Sendable {

    // MARK: - o que a tela lê (só na principal)

    public private(set) var montado = false
    /// Por que a câmera parou, quando parou (desconectada, erro de execução). Vazio correndo.
    public private(set) var interrupcao = ""
    public private(set) var microfone: EstadoDoMicrofone = .desligado {
        didSet {
            travaDosContadores.lock(); _estadoDoMicrofone = microfone.nome; travaDosContadores.unlock()
            if microfone != oldValue {
                registrar("APP MICROFONE botão: \(microfone.nome)" + (microfone.motivo.map { _ in " — causa disponível na interface" } ?? ""))
            }
        }
    }
    public private(set) var uniqueID = ""
    public private(set) var nomeDaCamera = ""
    /// A câmera embutida do Mac (a lente fica na borda de cima da tela).
    public private(set) var cameraEmbutida = false
    /// O formato montado, para o diário e a tela ("1920x1080 420v a 30 fps").
    public private(set) var descricaoDoFormato = ""
    /// A melhor imagem foi aplicada por formato (e não ficou o ativo).
    public private(set) var melhorImagemAplicada = false
    /// O nome do microfone aberto (ou "sintético"), para a tela.
    public private(set) var nomeDoMicrofone = ""

    /// Avisa **na principal** que algo que a tela lê mudou.
    public var aoMudar: (() -> Void)?

    // MARK: - os ajustes da câmera (R9, `docs/controles-de-camera.md`), o que a tela lê (só na principal)

    /// O que a câmera declara (`isXModeSupported`, ponto de interesse). `nil` antes de montar.
    public private(set) var capacidades: CapacidadesDaCamera?
    /// O registro corrente desta câmera (§2): o padrão ao montar (`MeusAjustes.aoAbrir`, decisão de
    /// 07/10), e o que a pessoa (ou um receptor) muda.
    public private(set) var ajustes: AjustesDaCamera = .padrao
    /// "Meus ajustes": o último registro diferente do padrão guardado para esta câmera (§2). Lido ao montar
    /// e acompanhado a cada gravação; **não** é aplicado sozinho — o painel o oferece ("Usar meus ajustes").
    public private(set) var meusAjustes: AjustesDaCamera = .padrao
    /// A pílula do ⌥-clique (§4.4): "Exposição e foco travados", "Exposição travada" ou "Foco travado".
    public private(set) var pilula: String?
    /// O recado de 3 s depois de reaplicar uma trava (§2.1): "Travado de novo depois de medir a cena."
    public private(set) var recadoDosAjustes: String?
    /// "Pouca luz: 15 fps…" (§3.1) enquanto o fps que chega está abaixo do pedido, ou `nil`.
    public private(set) var poucaLuz: String?
    /// O dono que a janela "Ajustes da câmera" ajusta: o último montado e ainda não fechado. A R5 e a
    /// câmera comum nunca estão abertas juntas ("um papel por vez"). Só na principal.
    public private(set) static weak var vigente: DonoDaCamera?
    /// Avisado **na principal** (objeto: o dono) quando o vigente, as capacidades, os ajustes, a pílula ou
    /// o recado mudam — a janela dos ajustes não tem o `aoMudar`, que é de quem abriu o dono.
    public static let ajustesMudaram = Notification.Name("quall.camera.ajustes.mudaram")

    // MARK: - o controle remoto (R9b, `docs/controle-remoto-da-camera.md`), só na principal

    /// "Controlado por <aparelho>" (§6): o nome de quem mudou a câmera de longe, enquanto o núcleo disser
    /// (`controlado_por`, 4 s). Escrito pela ponte do app (`mostrarControladoPor`).
    public private(set) var controladoPor: String?
    /// Uma mudança **feita aqui** (o painel, "Restaurar automático", o clique na prévia) mudou o registro:
    /// a ponte do app a publica aos receptores (`set_settings(json, 0)`). Na principal, que é a fila serial
    /// do registro no Mac (§6): toda mudança dele passa por ela.
    public var aoMudarORegistro: ((AjustesDaCamera) -> Void)?
    /// O dono vai fechar: a ponte diz "sem câmera" aos receptores. Na principal, no começo de `fechar`.
    public var aoFechar: (() -> Void)?
    /// A câmera caiu (desconectada, erro de execução; `interrupcao`): a ponte diz "sem câmera" também. Na
    /// principal.
    public var aoInterromper: (() -> Void)?
    /// A ponte do app com o núcleo (o `QuallCameraHost` desta câmera), segura pelo dono: ela vive o quanto
    /// a câmera viver. O `QuallCaptureKit` não conhece o tipo (não depende da fronteira C).
    public var anexoRemoto: AnyObject?

    // MARK: - configuração (antes de montar)

    /// Quem escolhe o microfone (G5). Escrito pela tela antes do primeiro toque. **Nasce na regra da
    /// bancada sem argumento** (recusa tudo): quem esquecer de escrevê-lo tem um microfone que não
    /// abre, e nunca um que abre o embutido. O produto escreve `.produto` de propósito.
    public var modoDoMicrofone: PoliticaDoMicrofone.Modo = .bancada(pedido: nil)
    /// Bancada: o botão liga a fonte sintética, e nenhum aparelho de áudio abre.
    public var microfoneSintetico = false
    /// Onde o registro dos ajustes mora (§2): o `UserDefaults.standard` no produto; a bancada passa um
    /// domínio próprio. Escrito antes de `montar`.
    public var guardaDosAjustes = GuardaDosAjustes()
    /// Bancada (`luma_media`, §5): a média de luma do plano Y, um quadro a cada 30, no diário. Só soma em
    /// contador: nenhum quadro é salvo nem aberto.
    public var lumaMedia = false
    /// Bancada: a leitura de volta dos modos da câmera entra no relato de 10 s.
    public var lerAjustesNoRelato = false

    private let registrar: (String) -> Void

    public init(registrar: @escaping (String) -> Void) {
        self.registrar = registrar
        super.init()
    }

    // MARK: - a câmera

    public let sessao = AVCaptureSession()
    private let saida = AVCaptureVideoDataOutput()
    private let fila = DispatchQueue(label: "quall.camera.dono", qos: .userInitiated)
    private var entrada: AVCaptureDeviceInput?
    private var aparelho: AVCaptureDevice?
    private var formatoEscolhido: AVCaptureDevice.Format?
    private var observadores: [NSObjectProtocol] = []
    private var relogio: DispatchSourceTimer?
    /// O tique da pouca luz (§3.1), a cada 0,5 s, e o que ele lembra entre um e outro. Só na fila dele.
    private var relogioDaLuz: DispatchSourceTimer?
    private var vigiaDaLuz = PoucaLuz.Vigia()
    private var entraramNoTique: UInt64 = 0
    private var tiqueEm: Double = 0
    /// O dono foi fechado: um `ligar` que chegue depois não sobe a câmera. Só na `fila`.
    private var fechado = false
    /// A cópia do registro que a `fila` aplica. Só na `fila`.
    private var ajustesDaFila: AjustesDaCamera = .padrao
    /// A gravação do registro adiada de um pedido remoto (§6.3: 500 ms depois da última mudança). Só na
    /// principal.
    fileprivate var gravacaoAdiada: DispatchWorkItem?
    /// Cada aplicação leva um número: a espera de uma trava sem o modo "uma vez" desiste se outra
    /// aplicação veio depois. Só na `fila`.
    private var vezDosAjustes = 0
    /// Quadros desde o último cálculo da luma. Só na `fila`.
    private var quadrosDaLuma: UInt64 = 0

    /// **Pede**, e não só lê (`docs/regras-de-frente.md`). `fim(nil)` concedida; `fim(motivo)` não.
    /// Na principal.
    public static func pedirPermissaoDaCamera(_ fim: @escaping (String?) -> Void) {
        let negada = T("O Quall Studio não tem acesso à câmera. Abra Ajustes do Sistema → Privacidade e Segurança → "
            + "Câmera e ligue o Quall Studio.")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            naPrincipal { fim(nil) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in naPrincipal { fim(ok ? nil : negada) } }
        case .denied:
            naPrincipal { fim(negada) }
        case .restricted:
            naPrincipal { fim(T("O acesso à câmera está bloqueado neste Mac por um perfil de gerenciamento.")) }
        @unknown default:
            naPrincipal { fim(negada) }
        }
    }

    /// Monta a captura da câmera `uniqueID` (`nil`: a embutida, ou a padrão). **Não** a põe para
    /// rodar: ver `ligar`. Devolve `nil` quando deu certo, e o texto do problema quando não. Na
    /// principal, uma vez por dono.
    public func montar(uniqueID pedido: String?, melhorImagem: Bool) -> String? {
        fila.async { [weak self] in self?.fechado = false }
        let escolhido: AVCaptureDevice
        if let id = pedido {
            if CameraDoQuall.ehDoQuall(uniqueID: id) {
                return T("A câmera do próprio Quall não pode ser a fonte (seria um laço).")
            }
            guard let a = AVCaptureDevice(uniqueID: id) else {
                return T("A câmera escolhida não está mais disponível. Escolha outra.")
            }
            escolhido = a
        } else {
            guard let a = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    ?? AVCaptureDevice.default(for: .video) else {
                return T("Nenhuma câmera encontrada neste Mac.")
            }
            escolhido = a
        }
        uniqueID = escolhido.uniqueID
        nomeDaCamera = escolhido.localizedName
        cameraEmbutida = escolhido.deviceType == .builtInWideAngleCamera

        sessao.beginConfiguration()
        // **A entrada entra antes de qualquer formato** (o conserto do iOS, §8.7: sem entrada, a sessão
        // não tem contra o que conferir).
        guard let nova = try? AVCaptureDeviceInput(device: escolhido), sessao.canAddInput(nova) else {
            sessao.commitConfiguration()
            return T("Não foi possível abrir a câmera %@.", escolhido.localizedName)
        }
        sessao.addInput(nova)
        entrada = nova
        aparelho = escolhido
        // A saída pede 420v (faixa limitada, a mesma escolha do `CameraCapturer`), só se oferecido:
        // pedir o que não está na lista levanta exceção do Objective-C.
        if saida.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            saida.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                   Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
        } else {
            registrar("APP CAMERA !! a saída não oferece 420v; disponíveis: \(saida.availableVideoPixelFormatTypes)")
        }
        saida.alwaysDiscardsLateVideoFrames = true
        saida.setSampleBufferDelegate(self, queue: fila)
        guard sessao.canAddOutput(saida) else {
            sessao.commitConfiguration()
            return T("A saída de vídeo da câmera não pôde ser criada.")
        }
        sessao.addOutput(saida)
        // O fluxo que sai (a rede e o arquivo) **nunca** é espelhado; a prévia espelha pela conexão
        // da camada dela (`aplicarEspelho`).
        if let cx = saida.connection(with: .video), cx.isVideoMirroringSupported {
            cx.automaticallyAdjustsVideoMirroring = false
            cx.isVideoMirrored = false
        }
        sessao.commitConfiguration()

        // **O formato depois do commit**, com a câmera travada: no macOS não há `.inputPriority`
        // (`AVCaptureSessionPresetInputPriority` é `API_UNAVAILABLE(macos)`), e o que o cabeçalho diz
        // é que escrever `activeFormat` passa a sessão a respeitá-lo. Se o `startRunning` o trocar
        // mesmo assim (hipótese não medida), `ligar` o reaplica e diz.
        melhorImagemAplicada = melhorImagem ? aplicarMelhorImagem(em: escolhido) : false
        limitarTaxa(escolhido)
        descricaoDoFormato = DonoDaCamera.descrever(escolhido)
        registrar("APP CAMERA captura montada: "
                  + "tipo=\(escolhido.deviceType.rawValue) embutida=\(cameraEmbutida) formato=\(descricaoDoFormato)"
                  + (melhorImagem ? (melhorImagemAplicada ? " (melhor imagem)" : " (melhor imagem NÃO aplicada: fica o ativo)") : " (formato ativo)"))
        observar(escolhido)
        subirSupervisao()
        // **Os ajustes (R9)**: as capacidades e o registro desta câmera; a aplicação vai para a `fila`,
        // depois do formato (§2.2: "o fim do `montar`"). **Abre no automático** (decisão de 07/10,
        // `MeusAjustes`): o guardado só é lido para o painel oferecê-lo. Aplicar o padrão ainda vale a
        // pena — devolve os modos contínuos que outro app (ou o dono anterior) tenha deixado travados.
        let caps = DonoDaCamera.capacidades(de: escolhido)
        capacidades = caps
        meusAjustes = guardaDosAjustes.ler(escolhido.uniqueID)
        ajustes = MeusAjustes.aoAbrir(guardado: meusAjustes)
        pilula = nil
        // A linha que `Bancada/provar-ajustes-da-camera.sh` lê: as capacidades (`exp=… bal=… foco=…`, bits do
        // que a câmera declara), o registro corrente (o padrão) e o guardado, cada um num campo só. Os
        // estados, e não o JSON: o registro seguro (05/10) tirou o JSON de câmera desta linha, e o
        // `uniqueID` e o nome da câmera da "captura montada"; nada disso volta aqui.
        registrar("APP CAMERA ajustes: capacidades \(caps.resumo) ajuste=\(ajustes.resumoDeUmCampo)"
                  + " guardado=\(meusAjustes.resumoDeUmCampo)")
        let registro = ajustes
        fila.async { [weak self] in self?.aplicarAjustes(registro, reaplicando: true, origem: "montar") }
        DonoDaCamera.vigente = self
        montado = true
        aoMudar?()
        avisarAjustes()
        return nil
    }

    /// Põe a captura para rodar. `startRunning` bloqueia: na `fila`, nunca na principal. **Ligar e
    /// parar passam os dois pela `fila`, em ordem** (o conserto do iOS em §8.3).
    public func ligar() {
        fila.async { [weak self] in
            guard let self, !self.fechado, !self.sessao.isRunning else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            self.sessao.startRunning()
            // A melhor imagem pode ter sido trocada pelo `startRunning` (hipótese): reaplicada e dita.
            if let a = self.aparelho, let f = self.formatoEscolhido, a.activeFormat != f {
                if (try? a.lockForConfiguration()) != nil {
                    a.activeFormat = f
                    a.unlockForConfiguration()
                }
                // Escrever o formato devolve a taxa ao padrão dele: o teto de 30 volta junto (a
                // revisão de 25/09; o gravador conta 30 fps).
                self.limitarTaxa(a)
                self.registrar("APP CAMERA o startRunning trocou o formato escolhido; reaplicado: "
                               + DonoDaCamera.descrever(a))
            }
            self.registrar(String(format: "APP CAMERA dono: a captura começou a rodar em %.0f ms (rodando=%@) vigente=%@",
                                  (CFAbsoluteTimeGetCurrent() - t0) * 1000, self.sessao.isRunning ? "sim" : "NÃO",
                                  self.aparelho.map(DonoDaCamera.descrever) ?? "?"))
            // **Os ajustes depois do formato** (§2.2): reaplicar o formato devolve o ponto ao centro e
            // pode desfazer uma trava; com a câmera rodando, a trava mede a cena antes de travar.
            self.aplicarAjustes(self.ajustesDaFila, reaplicando: true, origem: "ligar")
        }
    }

    /// Fecha tudo: o microfone primeiro (o indicador apaga antes), depois a câmera. **Síncrono**:
    /// chame numa thread própria (`fechar`), nunca na principal nem de dentro das filas do dono.
    public func pararDeRodar() {
        let inicio = CFAbsoluteTimeGetCurrent()
        controleDoMicrofone.sync {
            microfoneFechado = true
            fecharMicrofoneNaFila(motivo: "a câmera fechou")
        }
        let rodava: Bool = fila.sync {
            fechado = true
            let r = sessao.isRunning
            if r { sessao.stopRunning() }
            return r
        }
        naPrincipal { [weak self] in
            guard let self else { return }
            self.vezDoMicrofone += 1
            self.montado = false
            if self.microfone != .desligado { self.microfone = .desligado }
            self.aoMudar?()
        }
        registrar(String(format: "APP CAMERA dono: captura fechada em %.0f ms (rodava=%@)",
                         (CFAbsoluteTimeGetCurrent() - inicio) * 1000, rodava ? "sim" : "não"))
    }

    /// O fim do dono, da principal: para de observar e para a captura numa thread própria. `fim` na
    /// principal, quando a câmera fechou de verdade.
    public func fechar(fim: (() -> Void)? = nil) {
        relogio?.cancel()
        relogio = nil
        relogioDaLuz?.cancel()
        relogioDaLuz = nil
        naPrincipal { [weak self] in
            guard let self, self.poucaLuz != nil else { return }
            self.poucaLuz = nil
            self.avisarAjustes()
        }
        // O controle remoto primeiro: os receptores escondem o painel antes de a câmera parar, e o registro
        // de um pedido remoto ainda adiado vai para o disco agora.
        aoFechar?()
        aoFechar = nil
        descarregarGravacaoAdiada()
        if controladoPor != nil { controladoPor = nil }
        if DonoDaCamera.vigente === self {
            DonoDaCamera.vigente = nil
            avisarAjustes()
        }
        for o in observadores { NotificationCenter.default.removeObserver(o) }
        observadores.removeAll()
        let t = Thread { [self] in
            pararDeRodar()
            if let fim { naPrincipal(fim) }
        }
        t.name = "quall.camera.fechar"
        t.start()
    }

    // MARK: - a melhor imagem

    private func aplicarMelhorImagem(em a: AVCaptureDevice) -> Bool {
        let formatos = a.formats
        let oferecidos = formatos.map { f -> FormatoOferecido in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return FormatoOferecido(largura: Int(d.width), altura: Int(d.height),
                                    subtipo: CMFormatDescriptionGetMediaSubType(f.formatDescription),
                                    faixas: f.videoSupportedFrameRateRanges.map {
                                        FormatoOferecido.Faixa(minima: $0.minFrameRate, maxima: $0.maxFrameRate)
                                    })
        }
        guard let escolha = EscolhaDaMelhorImagem.escolherComQueda(oferecidos, fps: 30, aceitarOutrosSubtipos: true)
        else {
            let lista = oferecidos.map { "\($0.largura)x\($0.altura) \($0.nomeDoSubtipo)" }
            registrar("APP CAMERA melhor imagem: nenhum formato 720p/1080p/4K a 30 fps (\(formatos.count) formatos: "
                      + "\(Array(Set(lista)).sorted().joined(separator: ", "))) — fica o ativo")
            return false
        }
        let f = formatos[escolha.indice]
        do {
            try a.lockForConfiguration()
        } catch {
            registrar("APP CAMERA melhor imagem: a câmera não liberou a configuração (código=\((error as NSError).code)) — fica o ativo")
            return false
        }
        a.activeFormat = f
        a.unlockForConfiguration()
        guard a.activeFormat == f else {
            registrar("APP CAMERA melhor imagem: a câmera não ficou com o formato escolhido — fica o ativo")
            return false
        }
        formatoEscolhido = f
        let o = oferecidos[escolha.indice]
        registrar("APP CAMERA melhor imagem: \(o.largura)x\(o.altura) \(o.nomeDoSubtipo) a \(escolha.fps) fps "
                  + "faixas=\(o.faixas.map { "\(Int($0.minima))-\(Int($0.maxima))" }) de \(formatos.count) formatos")
        return true
    }

    /// Teto de 30 quadros por segundo, no aparelho. Só o **mínimo** de duração: fixar o máximo
    /// desligaria a extensão automática de exposição em pouca luz.
    private func limitarTaxa(_ a: AVCaptureDevice) {
        let alvo = CMTime(value: 1, timescale: 30)
        guard a.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }) else { return }
        guard (try? a.lockForConfiguration()) != nil else { return }
        a.activeVideoMinFrameDuration = alvo
        // **O piso, para o automático clarear em pouca luz** (§3.1, 06/10): o quadro pode durar até
        // 1/piso. O padrão do sistema vai ao diário, porque é o "antes".
        let padrao = CMTimeGetSeconds(a.activeVideoMaxFrameDuration)
        let piso = PoucaLuz.piso(faixas: a.activeFormat.videoSupportedFrameRateRanges.map { (minimo: $0.minFrameRate, maximo: $0.maxFrameRate) }, fps: 30)
        a.activeVideoMaxFrameDuration = CMTime(value: 1000, timescale: CMTimeScale(max(1, (piso * 1000).rounded())))
        a.unlockForConfiguration()
        registrar("APP CAMERA piso do automático: \(String(format: "%.1f", piso)) fps (padrão do sistema era "
                  + "\(padrao.isFinite && padrao > 0 ? String(format: "%.1f", 1 / padrao) : "?") fps)")
    }

    static func descrever(_ a: AVCaptureDevice) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(a.activeFormat.formatDescription)
        let sub = FormatoOferecido(largura: 0, altura: 0,
                                   subtipo: CMFormatDescriptionGetMediaSubType(a.activeFormat.formatDescription),
                                   faixas: []).nomeDoSubtipo
        let dur = a.activeVideoMinFrameDuration
        let fps = dur.value > 0 ? Double(dur.timescale) / Double(dur.value) : 0
        return String(format: "%dx%d %@ a %.0f fps", d.width, d.height, sub, fps)
    }

    // MARK: - a prévia

    /// Uma camada de prévia sobre a mesma sessão. O espelho vale na conexão dela (`aplicarEspelho`).
    public func novaCamadaDePrevia() -> AVCaptureVideoPreviewLayer {
        let c = AVCaptureVideoPreviewLayer(session: sessao)
        c.videoGravity = .resizeAspect
        return c
    }

    /// "Prévia como espelho" (§6): **só na conexão da camada**; a saída de dados nunca espelha.
    /// Devolve o que ficou (`espelhada`), para o diário.
    @discardableResult
    public static func aplicarEspelho(_ camada: AVCaptureVideoPreviewLayer, espelhar: Bool) -> Bool? {
        guard let cx = camada.connection else { return nil }
        guard cx.isVideoMirroringSupported else { return cx.isVideoMirrored }
        cx.automaticallyAdjustsVideoMirroring = false
        cx.isVideoMirrored = espelhar
        return cx.isVideoMirrored
    }

    // MARK: - os assinantes

    private struct Assinante {
        let ficha: FichaDoDono
        let video: ((CMSampleBuffer, CVPixelBuffer) -> Void)?
        let som: ((CMSampleBuffer) -> Void)?
        let perdeu: ((String) -> Void)?
    }
    private let travaDosAssinantes = NSLock()
    private var assinantes: [Assinante] = []

    /// Pendura um assinante. `video` é chamado **na fila da câmera**, `som` **na fila do áudio**
    /// (com o PTS já no relógio da câmera). Nenhum dos dois pode bloquear.
    /// `perdeu`: a câmera parou de vez (desconectada, erro de execução), na principal.
    public func assinar(nome: String, video: ((CMSampleBuffer, CVPixelBuffer) -> Void)? = nil,
                        som: ((CMSampleBuffer) -> Void)? = nil,
                        perdeu: ((String) -> Void)? = nil) -> FichaDoDono {
        let f = FichaDoDono(nome: nome)
        travaDosAssinantes.lock()
        assinantes.append(Assinante(ficha: f, video: video, som: som, perdeu: perdeu))
        let n = assinantes.count
        travaDosAssinantes.unlock()
        registrar("APP CAMERA dono: assinante pendurado (\(n) no total)")
        return f
    }

    /// Solta um assinante, **se ainda estiver**: soltar duas vezes não faz nada.
    public func desassinar(_ f: FichaDoDono) {
        travaDosAssinantes.lock()
        let antes = assinantes.count
        assinantes.removeAll { $0.ficha === f }
        let depois = assinantes.count
        travaDosAssinantes.unlock()
        if depois != antes { registrar("APP CAMERA dono: assinante solto (\(depois) no total)") }
    }

    private var listaDeAssinantes: [Assinante] {
        travaDosAssinantes.lock(); defer { travaDosAssinantes.unlock() }
        return assinantes
    }

    public var resumoDosAssinantes: String {
        let l = listaDeAssinantes
        return l.isEmpty ? "nenhum" : l.map(\.ficha.nome).joined(separator: ",")
    }

    // MARK: - observar a câmera

    private func observar(_ a: AVCaptureDevice) {
        let nc = NotificationCenter.default
        observadores.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: a,
                                           queue: .main) { [weak self] _ in
            guard let self else { return }
            self.interrupcao = T("a câmera %@ foi desconectada", a.localizedName)
            self.registrar("APP CAMERA interrompida: evento de interrupção")
            self.aoMudar?()
            self.aoInterromper?()
            for s in self.listaDeAssinantes { s.perdeu?(self.interrupcao) }
        })
        observadores.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: sessao,
                                           queue: .main) { [weak self] n in
            guard let self else { return }
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.interrupcao = T("a câmera parou com erro: %@", e?.localizedDescription ?? "sem erro")
            self.registrar("APP CAMERA interrompida: evento de interrupção")
            self.aoMudar?()
            self.aoInterromper?()
            for s in self.listaDeAssinantes { s.perdeu?(self.interrupcao) }
        })
        observadores.append(nc.addObserver(forName: .AVCaptureSessionDidStartRunning, object: sessao,
                                           queue: nil) { [weak self] _ in
            self?.registrar("APP CAMERA dono: a captura começou a rodar (aviso da sessão)")
        })
        observadores.append(nc.addObserver(forName: .AVCaptureSessionDidStopRunning, object: sessao,
                                           queue: nil) { [weak self] _ in
            self?.registrar("APP CAMERA dono: a captura parou de rodar (aviso da sessão)")
        })
    }

    // MARK: - supervisão de 10 s

    private let travaDosContadores = NSLock()
    private var _entraram: UInt64 = 0
    private var _entraramNoRelato: UInt64 = 0
    private var _ultimoPts: Double = -1
    private var _buracoMaior: Double = 0
    private var _ultimoQuadroEm: Double = 0
    private var _formatoRecebido = "?"
    private var _dimensao: (Int, Int) = (0, 0)
    private var _estadoDoMicrofone = "desligado"
    private var _buffersDeAudio: UInt64 = 0
    private var _buffersDeAudioNoRelato: UInt64 = 0
    private var _ultimoPtsDeAudio: Double = -1
    private var _buracoMaiorDeAudio: Double = 0
    private var _semConversao: UInt64 = 0
    // A janela do toque (a testemunha de "ligar o microfone não para a imagem", §8.5).
    private var _janelaAberta = false
    private var _janelaAcao = ""
    private var _buracoDaJanela: Double = 0
    private var _quadrosDaJanela = 0
    private var _inicioDaJanela: CFAbsoluteTime = 0
    private var _vezDaJanela = 0

    /// Há quanto tempo chegou o último quadro, em segundos (monotônico). `nil` sem nenhum.
    public var ultimoQuadroHa: Double? {
        travaDosContadores.lock(); defer { travaDosContadores.unlock() }
        guard _ultimoQuadroEm > 0 else { return nil }
        return ProcessInfo.processInfo.systemUptime - _ultimoQuadroEm
    }

    /// O formato do último quadro entregue ("420v 1920x1080").
    public var formatoRecebido: String {
        travaDosContadores.lock(); defer { travaDosContadores.unlock() }
        return _formatoRecebido
    }

    /// O tamanho do último quadro entregue (`(0, 0)` antes do primeiro).
    public var dimensaoRecebida: (largura: Int, altura: Int) {
        travaDosContadores.lock(); defer { travaDosContadores.unlock() }
        return _dimensao
    }

    private func subirSupervisao() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.relatar() }
        t.resume()
        relogio = t
        let luz = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        luz.schedule(deadline: .now() + 1, repeating: 0.5)
        luz.setEventHandler { [weak self] in self?.tiqueDaLuz() }
        luz.resume()
        relogioDaLuz = luz
    }

    /// O fps que chegou no último meio segundo contra o teto do formato: o automático baixou o fps para
    /// clarear (§3.1)? O Mac não lê a exposição, então o sinal é o fps.
    private func tiqueDaLuz() {
        travaDosContadores.lock()
        let entraram = _entraram
        travaDosContadores.unlock()
        let agora = ProcessInfo.processInfo.systemUptime
        defer { entraramNoTique = entraram; tiqueEm = agora }
        guard tiqueEm > 0, agora > tiqueEm, let a = aparelho else { return }
        let medido = Double(entraram &- entraramNoTique) / (agora - tiqueEm)
        let dur = a.activeVideoMinFrameDuration
        let fps = dur.value > 0 ? Double(dur.timescale) / Double(dur.value) : 30
        let texto = vigiaDaLuz.observar(fpsMedido: medido, fps: fps, agora: agora)
            .map { PoucaLuz.texto(fpsAgora: $0, fps: Int(fps.rounded())) }
        naPrincipal { [weak self] in
            guard let self, self.poucaLuz != texto else { return }
            self.poucaLuz = texto
            self.registrar("APP CAMERA pouca luz " + (texto == nil ? "apagada" : "acesa: \(String(format: "%.1f", medido)) fps de \(Int(fps.rounded()))"))
            self.avisarAjustes()
        }
    }

    private func relatar() {
        travaDosContadores.lock()
        let d = _entraram &- _entraramNoRelato
        _entraramNoRelato = _entraram
        let buraco = _buracoMaior
        _buracoMaior = 0
        let dA = _buffersDeAudio &- _buffersDeAudioNoRelato
        _buffersDeAudioNoRelato = _buffersDeAudio
        let buracoA = _buracoMaiorDeAudio
        _buracoMaiorDeAudio = 0
        let mic = _estadoDoMicrofone
        let sem = _semConversao
        travaDosContadores.unlock()
        registrar("APP CAMERA dono: camera=\(String(format: "%.1f", Double(d) / 10)) fps"
                  + " buraco_maior=\(String(format: "%.0f", buraco * 1000)) ms"
                  + " rodando=\(sessao.isRunning) assinantes=\(resumoDosAssinantes)"
                  + " formato=\(formatoRecebido) vigente=\(aparelho.map(DonoDaCamera.descrever) ?? "?")")
        if lerAjustesNoRelato { fila.async { [weak self] in self?.lerDeVolta("relato de 10 s") } }
        registrar("APP MICROFONE dono: botao=\(mic) buffers=\(dA) na janela"
                  + " buraco_maior=\(String(format: "%.0f", buracoA * 1000)) ms"
                  + " sem_conversao_de_relogio=\(sem)" + (microfoneSintetico ? " fonte=sintetica" : ""))
    }

    fileprivate func abrirJanelaDoToque(_ acao: String) -> Int {
        travaDosContadores.lock()
        _vezDaJanela += 1
        let vez = _vezDaJanela
        _janelaAberta = true
        _janelaAcao = acao
        _buracoDaJanela = 0
        _quadrosDaJanela = 0
        _inicioDaJanela = CFAbsoluteTimeGetCurrent()
        travaDosContadores.unlock()
        return vez
    }

    /// Fecha a janela 2 s depois do fim da ação e escreve a linha do critério (< ~70 ms).
    fileprivate func fecharJanelaDoToque(_ vez: Int) {
        let fimDaAcao = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.travaDosContadores.lock()
            guard self._vezDaJanela == vez, self._janelaAberta else { self.travaDosContadores.unlock(); return }
            self._janelaAberta = false
            let b = self._buracoDaJanela, q = self._quadrosDaJanela, acao = self._janelaAcao
            let t = CFAbsoluteTimeGetCurrent() - self._inicioDaJanela
            let acaoMs = (fimDaAcao - self._inicioDaJanela) * 1000
            self.travaDosContadores.unlock()
            self.registrar(String(format: "APP MICROFONE imagem ao %@: buraco_maior_da_camera=%.0f ms quadros=%d em %.1f s acao=%.0f ms",
                                  acao, b * 1000, q, t, acaoMs))
        }
    }

    // MARK: - o microfone

    /// Só lidos e escritos **na `controleDoMicrofone`**.
    private let controleDoMicrofone = DispatchQueue(label: "quall.microfone.controle", qos: .userInitiated)
    private let filaDoAudio = DispatchQueue(label: "quall.microfone", qos: .userInitiated)
    private let sessaoDoMicrofone = AVCaptureSession()
    private let saidaDeAudio = AVCaptureAudioDataOutput()
    private var entradaDeAudio: AVCaptureDeviceInput?
    private var microfoneFechado = false
    private var sintetico: DispatchSourceTimer?
    /// Os relógios da conversão. Sob `travaDosRelogios`.
    private let travaDosRelogios = NSLock()
    private var _relogioDoMicrofone: CMClock?
    private var _relogioDaCamera: CMClock?
    private var _microfoneAberto = false
    /// Cada pedido de ligar ou desligar leva um número: a resposta atrasada de um pedido velho não
    /// passa por cima do botão. Só na principal.
    private var vezDoMicrofone = 0

    /// O toque no botão. Na principal.
    public func alternarMicrofone(por motivo: String = "toque") {
        switch microfone {
        case .ligado, .pedindo: desligarMicrofone(por: motivo)
        default: ligarMicrofone(por: motivo)
        }
    }

    /// Liga: decide o aparelho (G5), **pede** a permissão (no primeiro toque, nunca ao abrir a tela)
    /// e abre a sessão do microfone. Na principal.
    public func ligarMicrofone(por motivo: String) {
        guard montado else {
            registrar("APP MICROFONE ligar recusado (\(motivo)): a câmera ainda não está montada")
            return
        }
        switch microfone {
        case .ligado, .pedindo: return
        default: break
        }
        vezDoMicrofone += 1
        let vez = vezDoMicrofone
        microfone = .pedindo
        aoMudar?()
        registrar("APP MICROFONE ligando (\(motivo))")
        if microfoneSintetico {
            controleDoMicrofone.async { [weak self] in
                guard let self else { return }
                let erro = self.abrirSinteticoNaFila()
                naPrincipal { [weak self] in self?.respostaDoLigar(vez: vez, erro: erro) }
            }
            return
        }
        // **A decisão e a abertura fora da principal** (a prova de 25/09: a principal presa no
        // `coreaudiod` matou a janela): listar os aparelhos pode esperar o servidor de áudio. O modo é
        // lido aqui, na principal, e levado à fila de controle.
        let modo = modoDoMicrofone
        let exigirVirtual: Bool
        if case .bancada = modo { exigirVirtual = true } else { exigirVirtual = false }
        controleDoMicrofone.async { [weak self] in
            let decisao = PoliticaDoMicrofone.decidir(modo, aparelhos: DonoDaCamera.aparelhosDeAudio())
            naPrincipal { [weak self] in
                guard let self, vez == self.vezDoMicrofone else { return }
                if case .recusar(let porque) = decisao {
                    self.microfone = .recusado(porque)
                    self.aoMudar?()
                    return
                }
                DonoDaCamera.pedirPermissaoDoMicrofone { [weak self] negada in
                    guard let self, vez == self.vezDoMicrofone else { return }
                    if let negada {
                        self.microfone = .recusado(negada)
                        self.aoMudar?()
                        return
                    }
                    self.controleDoMicrofone.async { [weak self] in
                        guard let self else { return }
                        let erro = self.abrirMicrofoneNaFila(decisao, exigirVirtual: exigirVirtual)
                        naPrincipal { [weak self] in self?.respostaDoLigar(vez: vez, erro: erro) }
                    }
                }
            }
        }
    }

    private func respostaDoLigar(vez: Int, erro: String?) {
        // Desligado (ou a câmera fechou) enquanto abria: o fechar já está na fila, atrás do abrir.
        guard vez == vezDoMicrofone else { return }
        microfone = erro.map { .falhou($0) } ?? .ligado
        aoMudar?()
    }

    /// Desliga: fecha a sessão do microfone. **Fechar de verdade**, não calar. Na principal.
    public func desligarMicrofone(por motivo: String) {
        vezDoMicrofone += 1
        let estava = microfone
        microfone = .desligado
        aoMudar?()
        registrar("APP MICROFONE desligando (\(motivo)) estava=\(estava.nome)")
        controleDoMicrofone.async { [weak self] in self?.fecharMicrofoneNaFila(motivo: motivo) }
    }

    static let textoDoMicrofoneNegado =
        T("O Quall Studio não tem acesso ao microfone. Abra Ajustes do Sistema → Privacidade e Segurança → "
        + "Microfone e ligue o Quall Studio; a câmera segue sem som enquanto isso.")

    /// **Pede**, e não só lê. `fim(nil)` concedida. Na principal.
    public static func pedirPermissaoDoMicrofone(_ fim: @escaping (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            naPrincipal { fim(nil) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in naPrincipal { fim(ok ? nil : textoDoMicrofoneNegado) } }
        case .denied:
            naPrincipal { fim(textoDoMicrofoneNegado) }
        case .restricted:
            naPrincipal { fim(T("O microfone está bloqueado neste Mac por um perfil de gerenciamento; a câmera segue sem som.")) }
        @unknown default:
            naPrincipal { fim(textoDoMicrofoneNegado) }
        }
    }

    /// Os aparelhos de entrada de áudio que o AVFoundation lista agora, para a política (G5) e para
    /// o menu da tela. Só lista: não abre nada.
    public static func aparelhosDeAudio() -> [AparelhoDeAudio] {
        let tipos: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            tipos = [.microphone, .external]
        } else {
            tipos = [.builtInMicrophone, .externalUnknown]
        }
        let s = AVCaptureDevice.DiscoverySession(deviceTypes: tipos, mediaType: .audio, position: .unspecified)
        return s.devices.map {
            AparelhoDeAudio(uniqueID: $0.uniqueID, nome: $0.localizedName, transporte: UInt32(bitPattern: $0.transportType))
        }
    }

    /// Abre o microfone. **Só na `controleDoMicrofone`**. `nil` quando abriu; o texto quando não.
    private func abrirMicrofoneNaFila(_ decisao: PoliticaDoMicrofone.Decisao, exigirVirtual: Bool) -> String? {
        guard !microfoneFechado else { return T("A câmera já fechou.") }
        if entradaDeAudio != nil { return nil }
        let aparelho: AVCaptureDevice?
        switch decisao {
        case .usar(let a):
            aparelho = AVCaptureDevice(uniqueID: a.uniqueID)
        case .padraoDoSistema:
            aparelho = AVCaptureDevice.default(for: .audio)
        case .recusar(let m):
            return m
        }
        guard let aparelho else { return T("O microfone escolhido não está disponível agora.") }
        // **O G5 conferido de novo, no aparelho de verdade**, e não só na lista: na bancada, nada
        // que não seja virtual abre — nunca o microfone do MacBook.
        let transporte = UInt32(bitPattern: aparelho.transportType)
        if exigirVirtual, transporte != AparelhoDeAudio.virtual {
            return "bancada: \"\(aparelho.localizedName)\" tem transporte \(AparelhoDeAudio.nome(doTransporte: transporte)); "
                + "só dispositivo virtual abre na bancada (G5)"
        }
        guard let nova = try? AVCaptureDeviceInput(device: aparelho) else {
            return T("Não foi possível abrir o microfone %@.", aparelho.localizedName)
        }
        let janela = abrirJanelaDoToque("ligar")
        defer { fecharJanelaDoToque(janela) }
        let inicio = CFAbsoluteTimeGetCurrent()
        let s = sessaoDoMicrofone
        s.beginConfiguration()
        var ok = s.canAddInput(nova)
        if ok {
            s.addInput(nova)
            if !s.outputs.contains(saidaDeAudio) {
                if s.canAddOutput(saidaDeAudio) {
                    // `audioSettings` nulo: o formato nativo do aparelho; quem assina converte.
                    saidaDeAudio.setSampleBufferDelegate(self, queue: filaDoAudio)
                    s.addOutput(saidaDeAudio)
                } else {
                    s.removeInput(nova)
                    ok = false
                }
            }
        }
        s.commitConfiguration()
        guard ok else { return T("A captura não aceitou o microfone.") }
        entradaDeAudio = nova
        travaDosContadores.lock(); _ultimoPtsDeAudio = -1; travaDosContadores.unlock()
        travaDosRelogios.lock()
        _relogioDoMicrofone = nil; _relogioDaCamera = nil
        _microfoneAberto = true
        travaDosRelogios.unlock()
        s.startRunning()
        guard s.isRunning else {
            fecharMicrofoneNaFila(motivo: "a sessão do microfone não rodou")
            return T("O microfone não abriu junto da câmera. Tente de novo.")
        }
        let relogios = lerRelogios()
        let nome = aparelho.localizedName
        naPrincipal { [weak self] in self?.nomeDoMicrofone = nome; self?.aoMudar?() }
        registrar(String(format: "APP MICROFONE aberto em %.0f ms", (CFAbsoluteTimeGetCurrent() - inicio) * 1000)
                  + " sessao=propria"
                  + " transporte=\(AparelhoDeAudio.nome(doTransporte: transporte))"
                  + " camera_rodando=\(sessao.isRunning) \(relogios)")
        return nil
    }

    /// A fonte sintética: o tom de quatro notas em buffers de 10 ms, carimbados no relógio de host,
    /// **sem aparelho nenhum**. Só na `controleDoMicrofone`.
    private func abrirSinteticoNaFila() -> String? {
        guard !microfoneFechado else { return T("A câmera já fechou.") }
        if sintetico != nil { return nil }
        let janela = abrirJanelaDoToque("ligar")
        defer { fecharJanelaDoToque(janela) }
        let host = CMClockGetHostTimeClock()
        travaDosRelogios.lock()
        _relogioDoMicrofone = host; _relogioDaCamera = nil
        _microfoneAberto = true
        travaDosRelogios.unlock()
        let taxa = 48_000.0
        let t0 = CMClockGetTime(host)
        var gerado: Int64 = 0
        let t = DispatchSource.makeTimerSource(queue: filaDoAudio)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let agora = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(host), t0))
            let alvo = Int64(agora * taxa)
            while alvo - gerado >= 480 {
                var pcm = [Int16](repeating: 0, count: 480)
                for i in 0..<480 { pcm[i] = Int16(TomDeQuatroNotas.amostra(gerado + Int64(i), taxaHz: taxa) * Float(Int16.max)) }
                let pts = CMTimeAdd(t0, CMTime(value: gerado, timescale: 48_000))
                gerado += 480
                if let b = DonoDaCamera.bufferDePCM(pcm, pts: pts, taxa: taxa) { self.entregarAudio(b) }
            }
        }
        t.resume()
        sintetico = t
        naPrincipal { [weak self] in self?.nomeDoMicrofone = "sintético (tom de quatro notas)"; self?.aoMudar?() }
        registrar("APP MICROFONE aberto sessao=sintetica (tom de quatro notas, 48 kHz mono, 10 ms, relógio de host; "
                  + "nenhum aparelho de áudio aberto) camera_rodando=\(sessao.isRunning)")
        return nil
    }

    /// Fecha o microfone. **Só na `controleDoMicrofone`.** A câmera não é tocada.
    private func fecharMicrofoneNaFila(motivo: String) {
        if let t = sintetico {
            travaDosRelogios.lock(); _microfoneAberto = false; travaDosRelogios.unlock()
            t.cancel()
            filaDoAudio.sync {}
            sintetico = nil
            registrar("APP MICROFONE fechado (sintético; \(motivo))")
        }
        guard let e = entradaDeAudio else { return }
        let janela = abrirJanelaDoToque("desligar")
        let inicio = CFAbsoluteTimeGetCurrent()
        travaDosRelogios.lock(); _microfoneAberto = false; travaDosRelogios.unlock()
        let s = sessaoDoMicrofone
        if s.isRunning { s.stopRunning() }
        s.beginConfiguration()
        s.removeInput(e)
        s.commitConfiguration()
        entradaDeAudio = nil
        registrar(String(format: "APP MICROFONE fechado em %.0f ms (%@)", (CFAbsoluteTimeGetCurrent() - inicio) * 1000, motivo))
        fecharJanelaDoToque(janela)
    }

    private static func relogio(de s: AVCaptureSession) -> CMClock? {
        s.synchronizationClock
    }

    private func lerRelogios() -> String {
        let doMicrofone = DonoDaCamera.relogio(de: sessaoDoMicrofone)
        let daCamera = sessao.isRunning ? DonoDaCamera.relogio(de: sessao) : nil
        travaDosRelogios.lock()
        _relogioDoMicrofone = doMicrofone
        _relogioDaCamera = daCamera
        travaDosRelogios.unlock()
        guard let doMicrofone else { return "relogios=sem_relogio_do_microfone" }
        guard let daCamera else { return "relogios=sem_relogio_da_camera (a câmera não roda)" }
        if CFEqual(doMicrofone, daCamera) { return "relogios=o_mesmo" }
        let agora = CMClockGetTime(doMicrofone)
        let convertido = CMSyncConvertTime(agora, from: doMicrofone, to: daCamera)
        let dif = CMTimeGetSeconds(CMTimeSubtract(convertido, agora)) * 1000
        let razao = CMSyncGetRelativeRate(doMicrofone, relativeTo: daCamera)
        return String(format: "relogios=convertidos diferenca=%.3f ms razao=%.6f", dif, razao)
    }

    /// **O PTS do som no relógio da câmera.** Na `filaDoAudio`. Sem os dois relógios, o buffer passa
    /// como veio e é contado (`sem_conversao_de_relogio`, que tem de ficar em 0).
    private func noRelogioDaCamera(_ amostra: CMSampleBuffer) -> CMSampleBuffer {
        travaDosRelogios.lock()
        var de = _relogioDoMicrofone, para = _relogioDaCamera
        travaDosRelogios.unlock()
        if de == nil, sessaoDoMicrofone.isRunning, let r = DonoDaCamera.relogio(de: sessaoDoMicrofone) {
            de = r
            travaDosRelogios.lock(); _relogioDoMicrofone = r; travaDosRelogios.unlock()
        }
        if para == nil, sessao.isRunning, let r = DonoDaCamera.relogio(de: sessao) {
            para = r
            travaDosRelogios.lock(); _relogioDaCamera = r; travaDosRelogios.unlock()
        }
        guard let de, let para else { return semConversao(amostra) }
        if CFEqual(de, para) { return amostra }
        return DonoDaCamera.converter(amostra, de: de, para: para) ?? semConversao(amostra)
    }

    private func semConversao(_ amostra: CMSampleBuffer) -> CMSampleBuffer {
        travaDosContadores.lock(); _semConversao &+= 1; travaDosContadores.unlock()
        return amostra
    }

    static func converter(_ amostra: CMSampleBuffer, de: CMClock, para: CMClock) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        guard pts.isValid else { return nil }
        let desloc = CMTimeSubtract(CMSyncConvertTime(pts, from: de, to: para), pts)
        return deslocar(amostra, por: desloc)
    }

    /// Uma cópia do buffer com todos os tempos deslocados de `desloc` (as amostras e a duração
    /// intactas). É o `CMSampleBufferCreateCopyWithNewTiming` que o iOS conferiu em §8.5.
    static func deslocar(_ amostra: CMSampleBuffer, por desloc: CMTime) -> CMSampleBuffer? {
        var n: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(amostra, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &n) == noErr, n > 0 else { return nil }
        var tempos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
        guard CMSampleBufferGetSampleTimingInfoArray(amostra, entryCount: n, arrayToFill: &tempos,
                                                     entriesNeededOut: &n) == noErr else { return nil }
        for k in tempos.indices {
            if tempos[k].presentationTimeStamp.isValid {
                tempos[k].presentationTimeStamp = CMTimeAdd(tempos[k].presentationTimeStamp, desloc)
            }
            if tempos[k].decodeTimeStamp.isValid {
                tempos[k].decodeTimeStamp = CMTimeAdd(tempos[k].decodeTimeStamp, desloc)
            }
        }
        var copia: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: amostra,
                                                    sampleTimingEntryCount: n, sampleTimingArray: &tempos,
                                                    sampleBufferOut: &copia) == noErr else { return nil }
        return copia
    }

    /// Um `CMSampleBuffer` de PCM 16 bits mono a partir de amostras e do PTS da primeira.
    public static func bufferDePCM(_ pcm: [Int16], pts: CMTime, taxa: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: taxa, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var bloco: CMBlockBuffer?
        let bytes = pcm.count * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bloco) == noErr,
              let bloco else { return nil }
        let copiou = pcm.withUnsafeBytes { tudo -> Bool in
            guard let base = tudo.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bloco, offsetIntoDestination: 0,
                                                 dataLength: bytes) == noErr
        }
        guard copiou else { return nil }
        var s: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: fmt, sampleCount: pcm.count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &s) == noErr else { return nil }
        return s
    }

    /// Um buffer de som, no relógio da câmera, para os assinantes. Na `filaDoAudio`.
    private func entregarAudio(_ bruto: CMSampleBuffer) {
        travaDosRelogios.lock(); let aberto = _microfoneAberto; travaDosRelogios.unlock()
        guard aberto else { return }
        let b = noRelogioDaCamera(bruto)
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(b))
        travaDosContadores.lock()
        _buffersDeAudio &+= 1
        if pts.isFinite {
            if _ultimoPtsDeAudio >= 0, pts > _ultimoPtsDeAudio {
                _buracoMaiorDeAudio = max(_buracoMaiorDeAudio, pts - _ultimoPtsDeAudio)
            }
            _ultimoPtsDeAudio = pts
        }
        travaDosContadores.unlock()
        for a in listaDeAssinantes { a.som?(b) }
    }
}

extension DonoDaCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        if output === saidaDeAudio {
            entregarAudio(sampleBuffer)
            return
        }
        guard sampleBuffer.isValid, let imagem = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let l = CVPixelBufferGetWidth(imagem), a = CVPixelBufferGetHeight(imagem)
        travaDosContadores.lock()
        _entraram &+= 1
        _ultimoQuadroEm = ProcessInfo.processInfo.systemUptime
        if pts.isFinite {
            if _ultimoPts >= 0, pts > _ultimoPts {
                _buracoMaior = max(_buracoMaior, pts - _ultimoPts)
                if _janelaAberta { _buracoDaJanela = max(_buracoDaJanela, pts - _ultimoPts) }
            }
            if _janelaAberta { _quadrosDaJanela += 1 }
            _ultimoPts = pts
        }
        var mudouOFormato = false
        if _dimensao.0 != l || _dimensao.1 != a {
            _dimensao = (l, a)
            let sub = FormatoOferecido(largura: 0, altura: 0, subtipo: CVPixelBufferGetPixelFormatType(imagem),
                                       faixas: []).nomeDoSubtipo
            _formatoRecebido = "\(sub) \(l)x\(a)"
            mudouOFormato = true
        }
        let formato = _formatoRecebido
        travaDosContadores.unlock()
        if mudouOFormato { registrar("APP CAMERA formato_da_camera=\(formato)") }
        if lumaMedia { medirLuma(imagem) }
        for s in listaDeAssinantes { s.video?(sampleBuffer, imagem) }
    }
}

// MARK: - os ajustes da câmera (R9, `docs/controles-de-camera.md`)

/// **Os controles do R9 no Mac**: as travas de exposição, balanço e foco, o ponto de exposição e de
/// foco, e a volta ao automático (§1). A decisão é pura (`ControlesDaCamera.swift`); aqui só se lê a
/// câmera e se aplica.
///
/// - **Toda mudança na `fila`**, com `lockForConfiguration` curto e uma guarda `isXModeSupported` (ou
///   `is…PointOfInterestSupported`) antes de cada escrita: sem a guarda, o AVFoundation levanta
///   exceção do Objective-C, que derruba o app.
/// - **Reaplicar** (§2.1, caso "sem manual"): no fim do `montar` e no `ligar`, depois do formato. Desde
///   07/10 o `montar` aplica sempre o padrão (`MeusAjustes.aoAbrir`): a trava só chega aqui reaplicada
///   quando foi ligada na sessão, antes de um `ligar`. Uma
///   trava não é "trave no que estiver agora": vai como `.autoExpose`/`.autoWhiteBalance`/`.autoFocus`,
///   que medem e travam sozinhos ao convergir; onde a câmera trava mas não tem o modo "uma vez", espera
///   parar de ajustar (de 0,5 s a 3 s) e trava.
/// - **Devolver a câmera**: nada a fazer, o sistema devolve ao fechar a sessão (§2.2).
extension DonoDaCamera {

    // MARK: o que a tela pede (na principal)

    /// A pessoa mudou o registro pelo painel. Grava, apaga a pílula se uma trava dela saiu, e aplica
    /// **na hora** (a cena já está medida).
    public func mudarAjustes(_ pedido: AjustesDaCamera, origem: String) {
        guard montado, let c = capacidades else { return }
        let novo = pedido.cortado(por: c)
        if novo != pedido {
            registrar("APP CAMERA ajustes: \(origem) pediu o que a câmera não faz (\(pedido.resumo)); fica \(novo.resumo)")
        }
        let antes = ajustes
        ajustes = novo
        pilula = DecisaoDoClique.pilulaDepoisDoPainel(acesa: pilula, novo: novo)
        gravarJa(novo)
        registrar("APP CAMERA ajustes: \(origem) — \(antes.resumo) → \(novo.resumo); plano "
                  + PlanoDeAplicar.para(novo, c, reaplicando: false).resumo)
        aoMudar?()
        avisarAjustes()
        if novo != antes { aoMudarORegistro?(novo) }
        fila.async { [weak self] in self?.aplicarAjustes(novo, reaplicando: false, origem: origem) }
    }

    /// **"Usar meus ajustes"**: o guardado desta câmera, cortado pelo que ela faz agora, pelo mesmo
    /// caminho de um gesto do painel (grava, apaga a pílula que não vale mais, aplica na hora).
    public func usarMeusAjustes(origem: String) {
        guard montado, let c = capacidades else { return }
        mudarAjustes(MeusAjustes.recuperar(meusAjustes, c), origem: origem + " (meus ajustes)")
    }

    /// "Restaurar automático": a câmera volta ao automático, tira a pílula, volta os modos contínuos e o
    /// ponto ao centro. O guardado fica (`GuardaDosAjustes.gravar` não grava o padrão): o painel passa a
    /// oferecer "Usar meus ajustes".
    public func restaurarAutomatico(origem: String) {
        guard montado else { return }
        let antes = ajustes
        ajustes = .padrao
        pilula = nil
        gravarJa(.padrao)
        registrar("APP CAMERA ajustes: restaurar automático (\(origem))")
        aoMudar?()
        avisarAjustes()
        if antes != .padrao { aoMudarORegistro?(.padrao) }
        fila.async { [weak self] in
            self?.aplicarAjustes(.padrao, reaplicando: false, origem: origem, pontoAoCentro: true)
        }
    }

    /// **O clique na prévia** (§4.4), com o ponto já no referencial do sensor
    /// (`captureDevicePointConverted(fromLayerPoint:)`, que trata o espelho e o enquadramento).
    /// `travarAli`: o ⌥-clique. Devolve se o clique fez algo (para a prévia mostrar o quadrado).
    @discardableResult
    public func cliqueNaPrevia(_ ponto: CGPoint, travarAli: Bool, origem: String) -> Bool {
        guard montado, let c = capacidades else { return false }
        let p = CGPoint(x: min(1, max(0, ponto.x)), y: min(1, max(0, ponto.y)))
        let d = DecisaoDoClique.decidir(ajustes, c, travarAli: travarAli, pilulaAcesa: pilula != nil)
        registrar(String(format: "APP CAMERA clique na prévia (%@%@): ponto=%.3f,%.3f medir=%@ focar=%@ pilula=%@ registro=%@",
                         origem, travarAli ? ", travar ali" : "", p.x, p.y, d.medir ? "sim" : "não",
                         d.focar ? "sim" : "não", d.pilula ?? "nenhuma", d.ajustes.json))
        guard d.quadrado else { return false }
        let mudou = d.ajustes != ajustes
        if mudou {
            ajustes = d.ajustes
            gravarJa(d.ajustes)
        }
        pilula = d.pilula
        aoMudar?()
        avisarAjustes()
        if mudou { aoMudarORegistro?(d.ajustes) }
        let registro = d.ajustes
        fila.async { [weak self] in
            self?.aplicarPonto(p, medir: d.medir, focar: d.focar, registro: registro, origem: origem)
        }
        return true
    }

    /// **Um pedido de um receptor** (R9b, contrato §6), já aceito pelo núcleo. Na principal, a mesma fila
    /// serial de `mudarAjustes`, `restaurarAutomatico` e `cliqueNaPrevia`: o pedido vê o registro de agora.
    /// Aplica na ordem do contrato (`PedidoDaCameraRemota.aplicar`), toca a câmera na `fila` como o painel
    /// e o clique tocam, e **adia a gravação** 500 ms (um interruptor remoto apertado depressa não vira uma
    /// troca de arquivo por toque). Devolve `nil` quando aplicou — o registro novo está em `ajustes` — ou o
    /// código da recusa. **Não** chama `aoMudarORegistro`: quem responde ao núcleo, com o `n`, é a ponte.
    public func aplicarPedidoRemoto(_ p: PedidoDaCameraRemota) -> String? {
        guard montado, let c = capacidades else { return "sem_camera" }
        // A câmera caiu: aplicar seria dizer que aplicou sem câmera nenhuma.
        guard interrupcao.isEmpty else { return "nao_aplicado" }
        switch p.aplicar(sobre: ajustes, c, pilulaAcesa: pilula != nil) {
        case .recusar(let motivo):
            registrar("APP CAMERA remoto: pedido \(p.n) recusado (\(motivo))"
                      + (p.naoAplicaveis.isEmpty ? "" : " campos_nao_aplicaveis=\(p.naoAplicaveis.count)"))
            return motivo
        case .aplicar(let novo, let clique, let ponto, let pontoAoCentro):
            let antes = ajustes
            ajustes = novo
            if p.restaurar { pilula = nil }
            if let clique, clique.quadrado {
                pilula = clique.pilula
            } else {
                pilula = DecisaoDoClique.pilulaDepoisDoPainel(acesa: pilula, novo: novo)
            }
            if novo != antes { gravarAdiado(novo) }
            registrar("APP CAMERA remoto: pedido \(p.n) — \(antes.resumo) → \(novo.resumo)"
                      + (p.restaurar ? " (restaurar)" : "")
                      + (ponto.map { String(format: " toque=%.3f,%.3f%@ medir=%@ focar=%@", $0.x, $0.y,
                                            p.toque?.longo == true ? " longo" : "", clique?.medir == true ? "sim" : "não",
                                            clique?.focar == true ? "sim" : "não") } ?? "")
                      + "; plano " + PlanoDeAplicar.para(novo, c, reaplicando: false).resumo)
            aoMudar?()
            avisarAjustes()
            let origem = "remoto \(p.n)"
            // Só o toque (sem campos nem restaurar): como o clique na prévia, só o ponto — reaplicar os modos
            // antes desmancharia a medição que o toque vai fazer.
            let soToque = ponto != nil && !p.restaurar && p.travaExposicao == nil && p.travaBalanco == nil && p.foco == nil
            let aplicarOsAjustes = !soToque
            fila.async { [weak self] in
                guard let self else { return }
                if aplicarOsAjustes {
                    self.aplicarAjustes(novo, reaplicando: false, origem: origem, pontoAoCentro: pontoAoCentro)
                }
                if let ponto, let clique, clique.quadrado {
                    self.aplicarPonto(ponto, medir: clique.medir, focar: clique.focar, registro: novo, origem: origem)
                }
            }
            return nil
        }
    }

    /// "Controlado por <aparelho>" (§6), ou `nil` para apagar. Na principal.
    public func mostrarControladoPor(_ nome: String?) {
        guard nome != controladoPor else { return }
        controladoPor = nome
        aoMudar?()
        avisarAjustes()
    }

    /// Grava agora, e cancela uma gravação remota adiada (a mudança local é mais nova).
    private func gravarJa(_ a: AjustesDaCamera) {
        gravacaoAdiada?.cancel()
        gravacaoAdiada = nil
        guardaDosAjustes.gravar(a, uniqueID)
        if let g = MeusAjustes.paraGravar(a) { meusAjustes = g }
    }

    /// Grava 500 ms depois da última mudança remota (contrato §6.3).
    private func gravarAdiado(_ a: AjustesDaCamera) {
        gravacaoAdiada?.cancel()
        let id = uniqueID
        let guarda = guardaDosAjustes
        // O vigente **no disparo** (`a` só se o dono já se foi): uma mudança local no meio já gravou e
        // cancelou esta, mas a guarda não custa nada.
        let item = DispatchWorkItem { [weak self] in
            let vigente = self?.ajustes ?? a
            guarda.gravar(vigente, id)
            if let g = MeusAjustes.paraGravar(vigente) { self?.meusAjustes = g }
            self?.gravacaoAdiada = nil
            self?.avisarAjustes()
        }
        gravacaoAdiada = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// A gravação adiada vai agora: o dono fecha, ou quem o fecha (a câmera comum, a troca da R5) vai
    /// abrir outro dono da mesma câmera antes de este terminar de fechar. Na principal.
    public func descarregarGravacaoAdiada() {
        guard let item = gravacaoAdiada else { return }
        gravacaoAdiada = nil
        item.perform()
        item.cancel()
    }

    /// O atalho "Efeitos de vídeo do sistema" (Centro do palco, Retrato, Luz de estúdio): o painel do
    /// próprio macOS, que vale para a câmera inteira e não é guardado pelo Quall.
    public static func mostrarEfeitosDeVideoDoSistema() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    func avisarAjustes() {
        naPrincipal { [weak self] in
            NotificationCenter.default.post(name: DonoDaCamera.ajustesMudaram, object: self)
        }
    }

    // MARK: ler a câmera

    /// O que a câmera declara. Só lê.
    static func capacidades(de d: AVCaptureDevice) -> CapacidadesDaCamera {
        CapacidadesDaCamera(
            exposicaoContinua: d.isExposureModeSupported(.continuousAutoExposure),
            exposicaoUmaVez: d.isExposureModeSupported(.autoExpose),
            exposicaoTravada: d.isExposureModeSupported(.locked),
            pontoDeExposicao: d.isExposurePointOfInterestSupported,
            balancoContinuo: d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
            balancoUmaVez: d.isWhiteBalanceModeSupported(.autoWhiteBalance),
            balancoTravado: d.isWhiteBalanceModeSupported(.locked),
            focoContinuo: d.isFocusModeSupported(.continuousAutoFocus),
            focoUmaVez: d.isFocusModeSupported(.autoFocus),
            focoTravado: d.isFocusModeSupported(.locked),
            pontoDeFoco: d.isFocusPointOfInterestSupported)
    }

    static func nome(_ m: AVCaptureDevice.ExposureMode) -> String {
        switch m {
        case .locked: return "locked"
        case .autoExpose: return "autoExpose"
        case .continuousAutoExposure: return "continuous"
        case .custom: return "custom"
        @unknown default: return "?\(m.rawValue)"
        }
    }

    static func nome(_ m: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch m {
        case .locked: return "locked"
        case .autoWhiteBalance: return "autoWhiteBalance"
        case .continuousAutoWhiteBalance: return "continuous"
        @unknown default: return "?\(m.rawValue)"
        }
    }

    static func nome(_ m: AVCaptureDevice.FocusMode) -> String {
        switch m {
        case .locked: return "locked"
        case .autoFocus: return "autoFocus"
        case .continuousAutoFocus: return "continuous"
        @unknown default: return "?\(m.rawValue)"
        }
    }

    /// **A leitura de volta** (§5, prova 1): os modos que a câmera diz estar usando, o ponto e se ela
    /// ainda está ajustando. Na `fila`. Linha fixa, para o roteiro de prova ler.
    func lerDeVolta(_ motivo: String) {
        guard let d = aparelho else { return }
        func sn(_ v: Bool) -> String { v ? "sim" : "nao" }
        registrar(String(format: "APP CAMERA ajustes lidos (%@): exposicao=%@ balanco=%@ foco=%@ "
                         + "ponto_exposicao=%.3f,%.3f ponto_foco=%.3f,%.3f ajustando=exp:%@,bal:%@,foco:%@ registro=%@",
                         motivo, DonoDaCamera.nome(d.exposureMode), DonoDaCamera.nome(d.whiteBalanceMode),
                         DonoDaCamera.nome(d.focusMode), d.exposurePointOfInterest.x, d.exposurePointOfInterest.y,
                         d.focusPointOfInterest.x, d.focusPointOfInterest.y, sn(d.isAdjustingExposure),
                         sn(d.isAdjustingWhiteBalance), sn(d.isAdjustingFocus), ajustesDaFila.json))
    }

    // MARK: aplicar (na fila)

    /// **`aplicarAjustes`**: o registro na câmera. **Só na `fila`.**
    /// - `reaplicando`: a câmera acabou de montar ou de rodar (o formato pode ter mudado): a trava mede
    ///   antes de travar (§2.1). Pelo painel, trava na hora.
    func aplicarAjustes(_ a: AjustesDaCamera, reaplicando: Bool, origem: String, pontoAoCentro: Bool = false) {
        ajustesDaFila = a
        vezDosAjustes += 1
        let vez = vezDosAjustes
        guard !fechado, let d = aparelho else { return }
        let c = DonoDaCamera.capacidades(de: d)
        let plano = PlanoDeAplicar.para(a, c, reaplicando: reaplicando)
        do {
            try d.lockForConfiguration()
        } catch {
            registrar("APP CAMERA ajustes: a câmera não liberou a configuração (código=\((error as NSError).code)) — "
                      + "\(origem); nada aplicado")
            return
        }
        if pontoAoCentro {
            let centro = CGPoint(x: 0.5, y: 0.5)
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = centro }
            if d.isFocusPointOfInterestSupported && !c.focoFixo { d.focusPointOfInterest = centro }
        }
        DonoDaCamera.porExposicao(plano.exposicao, d)
        DonoDaCamera.porBalanco(plano.balanco, d)
        DonoDaCamera.porFoco(plano.foco, d)
        d.unlockForConfiguration()
        registrar("APP CAMERA ajustes aplicados (\(origem)\(reaplicando ? ", reaplicando" : "")): \(plano.resumo) "
                  + "registro=\(a.json)")
        if plano.exposicao == .esperarETravar || plano.balanco == .esperarETravar || plano.foco == .esperarETravar {
            esperarETravar(plano, vez: vez, inicio: CFAbsoluteTimeGetCurrent(), origem: origem)
        }
        // O recado é do `ligar` (a câmera rodando); o do fim do `montar` é a mesma trava, antes de rodar.
        if reaplicando && origem != "montar" && plano.travaDepoisDeMedir {
            naPrincipal { [weak self] in self?.mostrarRecado(TextosDosAjustes.travadoDeNovo) }
        }
        fila.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.vezDosAjustes == vez else { return }
            self.lerDeVolta("2 s depois de \(origem)")
        }
    }

    /// O ponto do clique. **Só na `fila`.** Mede e foca no ponto com os modos "uma vez", que travam
    /// sozinhos ao convergir (§4.4); sem eles, o contínuo no ponto.
    func aplicarPonto(_ p: CGPoint, medir: Bool, focar: Bool, registro: AjustesDaCamera, origem: String) {
        ajustesDaFila = registro
        vezDosAjustes += 1
        let vez = vezDosAjustes
        guard !fechado, let d = aparelho else { return }
        guard (try? d.lockForConfiguration()) != nil else {
            registrar("APP CAMERA clique: a câmera não liberou a configuração — nada aplicado")
            return
        }
        var feito: [String] = []
        if medir && d.isExposurePointOfInterestSupported {
            d.exposurePointOfInterest = p
            if d.isExposureModeSupported(.autoExpose) {
                d.exposureMode = .autoExpose
                feito.append("exposicao=autoExpose")
            } else if d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
                feito.append("exposicao=continuous")
            }
        }
        if focar && d.isFocusPointOfInterestSupported {
            d.focusPointOfInterest = p
            if d.isFocusModeSupported(.autoFocus) {
                d.focusMode = .autoFocus
                feito.append("foco=autoFocus")
            } else if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
                feito.append("foco=continuous")
            }
        }
        d.unlockForConfiguration()
        registrar("APP CAMERA ponto aplicado (\(origem)): \(feito.joined(separator: " ")) registro=\(registro.json)")
        // A trava do ⌥-clique numa câmera sem o modo "uma vez": mede no contínuo e trava ao parar.
        let c = DonoDaCamera.capacidades(de: d)
        let exp: PassoDoGrupo = medir && registro.travaExposicao && !c.exposicaoUmaVez ? .esperarETravar : .nada
        let foco: PassoDoGrupo = focar && registro.foco == .travado && !c.focoUmaVez ? .esperarETravar : .nada
        if exp != .nada || foco != .nada {
            esperarETravar(PlanoDeAplicar(exposicao: exp, balanco: .nada, foco: foco), vez: vez,
                           inicio: CFAbsoluteTimeGetCurrent(), origem: origem)
        }
        fila.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.vezDosAjustes == vez else { return }
            self.lerDeVolta("2 s depois do clique")
        }
    }

    /// Espera o grupo parar de ajustar (no mínimo 0,5 s, no máximo 3 s) e trava. Na `fila`; desiste se
    /// outra aplicação veio depois.
    private func esperarETravar(_ plano: PlanoDeAplicar, vez: Int, inicio: CFAbsoluteTime, origem: String) {
        fila.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.vezDosAjustes == vez, !self.fechado, let d = self.aparelho else { return }
            let passou = CFAbsoluteTimeGetCurrent() - inicio
            let ajustando = (plano.exposicao == .esperarETravar && d.isAdjustingExposure)
                || (plano.balanco == .esperarETravar && d.isAdjustingWhiteBalance)
                || (plano.foco == .esperarETravar && d.isAdjustingFocus)
            if passou < 0.5 || (ajustando && passou < 3) {
                self.esperarETravar(plano, vez: vez, inicio: inicio, origem: origem)
                return
            }
            guard (try? d.lockForConfiguration()) != nil else { return }
            if plano.exposicao == .esperarETravar { DonoDaCamera.porExposicao(.travarJa, d) }
            if plano.balanco == .esperarETravar { DonoDaCamera.porBalanco(.travarJa, d) }
            if plano.foco == .esperarETravar { DonoDaCamera.porFoco(.travarJa, d) }
            d.unlockForConfiguration()
            self.registrar(String(format: "APP CAMERA ajustes: travado depois de medir (%@) em %.0f ms%@", origem,
                                  passou * 1000, ajustando ? " — ainda ajustando no prazo de 3 s, travado assim mesmo" : ""))
        }
    }

    private static func porExposicao(_ p: PassoDoGrupo, _ d: AVCaptureDevice) {
        switch p {
        case .automatico, .esperarETravar:
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        case .medirETravar:
            if d.isExposureModeSupported(.autoExpose) { d.exposureMode = .autoExpose }
        case .travarJa:
            if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
        case .nada:
            break
        }
    }

    private static func porBalanco(_ p: PassoDoGrupo, _ d: AVCaptureDevice) {
        switch p {
        case .automatico, .esperarETravar:
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        case .medirETravar:
            if d.isWhiteBalanceModeSupported(.autoWhiteBalance) { d.whiteBalanceMode = .autoWhiteBalance }
        case .travarJa:
            if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
        case .nada:
            break
        }
    }

    private static func porFoco(_ p: PassoDoGrupo, _ d: AVCaptureDevice) {
        switch p {
        case .automatico, .esperarETravar:
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        case .medirETravar:
            if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
        case .travarJa:
            if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        case .nada:
            break
        }
    }

    /// O recado de 3 s (§2.1). Na principal.
    private func mostrarRecado(_ texto: String) {
        recadoDosAjustes = texto
        registrar("APP CAMERA ajustes: a tela diz \"\(texto)\" por 3 s")
        aoMudar?()
        avisarAjustes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.recadoDosAjustes == texto else { return }
            self.recadoDosAjustes = nil
            self.aoMudar?()
            self.avisarAjustes()
        }
    }

    // MARK: a luma média (bancada, §5)

    /// Um quadro a cada 30: a média do plano Y subamostrado, e quanto custou. Na `fila`.
    func medirLuma(_ imagem: CVPixelBuffer) {
        quadrosDaLuma &+= 1
        guard quadrosDaLuma % 30 == 0 else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let m = LumaMedia.calcular(imagem)
        let custo = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000
        registrar(m.map { String(format: "APP CAMERA luma_media=%.1f quadro=%llu custo=%.0f us", $0, quadrosDaLuma, custo) }
                  ?? "APP CAMERA luma_media=sem_plano_y quadro=\(quadrosDaLuma)")
    }
}

/// Roda na principal (na hora, se já estiver nela).
func naPrincipal(_ f: @escaping () -> Void) {
    if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
}
