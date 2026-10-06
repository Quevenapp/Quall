import AVFoundation
import CQuall
import Foundation
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit
import SwiftUI

/// A máquina de estados do emissor macOS.
///
/// # Quem espelha anuncia e espera
///
/// `docs/fluxo-de-uso.md`, e antes dele a dívida 1: `tracks` só vale em `quall_host`, não há
/// renegociação, e quem chama `quall_connect` nunca poderá emitir naquela sessão. **Isto não é
/// preferência de interface, é imposto pelo protocolo.** A consequência para esta classe é que
/// não existe — e não pode existir — um método "mandar para aquele aparelho ali". Existe
/// `espelhar()`, que sobe uma sessão e **espera**.
///
/// O conserto disso na interface é discurso, não mecanismo: a tela nunca diz "escolha para onde
/// mandar", diz "é assim que os outros te encontram".
///
/// # Por que não é `@MainActor`
///
/// Porque `quall_host` **bloqueia** por até cinco minutos e `quall_session_next_event` exige ser
/// chamada sempre da **mesma** thread. Marcar a classe inteira com `@MainActor` empurraria essas
/// duas coisas para fora dela por contorno, e o contorno é onde os erros moram. Em vez disso: as
/// propriedades `@Published` só mudam na main (por `naMain`), o estado compartilhado com a thread
/// da sessão fica atrás de `trava`, e a marca `@unchecked Sendable` é a afirmação explícita de
/// que a trava é nossa responsabilidade — não uma promessa do compilador.
final class Emissor: ObservableObject, @unchecked Sendable {
    enum Fase: Equatable {
        case inicial
        case esperando
        case transmitindo
        case encerrando
    }

    // MARK: - o que a interface lê (só muda na main)

    @Published private(set) var fase: Fase = .inicial {
        didSet {
            // **O tempo no ar** (`docs/telas-estudio.md` §11.1, lógica nova desta rodada): desde que
            // a primeira sessão subiu; zera quando a transmissão acaba (a espera que reabre conta de novo).
            if fase == .transmitindo {
                if noArDesde == nil { noArDesde = Date() }
            } else if fase != .encerrando, noArDesde != nil {
                noArDesde = nil
            }
        }
    }
    /// Desde quando este Mac está no ar (a pílula "NO AR · há 04:12"). `nil` fora do ar.
    @Published private(set) var noArDesde: Date?
    @Published private(set) var fontes: [FonteDeCaptura] = []
    /// A linha escolhida. A tela a escreve direto (`TelaInicial`); o `didSet` leva a escolha ao
    /// `seletor` e tira o aviso da fonte que sumiu. As escritas que vêm do próprio `seletor` passam
    /// com `sincronizandoAEscolha` ligado e não voltam para ele.
    @Published var fonteEscolhida: FonteDeCaptura? {
        didSet {
            guard !sincronizandoAEscolha, let f = fonteEscolhida else { return }
            seletor.escolher(f)
            tirarAvisoDaFonte()
        }
    }
    @Published private(set) var carregandoFontes = false
    @Published private(set) var telaBloqueada: String?
    @Published private(set) var cameraBloqueada: String?

    @Published private(set) var pin = ""
    @Published private(set) var enderecoParaDigitar: String?
    /// **Publicado, não lido do disco a cada redesenho.** Ler arquivo de pareamento dentro do
    /// corpo de uma view é caro e, pior, pode mudar de valor no meio de uma composição — a
    /// manchete piscaria entre as duas formas. Ver `docs/ux-m6.md`, §1.2.
    @Published private(set) var haParesConhecidos = false
    @Published private(set) var par = ""
    @Published private(set) var conselho = ""
    @Published private(set) var ofereceDesparear = false
    @Published private(set) var anunciandoPorMDNS = false
    @Published private(set) var nomeNaDescoberta: String?
    @Published private(set) var resumoDaTransmissao = ""

    /// **Transmitir o som do sistema junto da tela? Desligado por padrão.**
    ///
    /// A pergunta não é de gosto e a resposta não é a simétrica de "a tela já vai". O argumento
    /// que decidiu é um fato do macOS: **o escopo do áudio é mais largo que o escopo do vídeo que
    /// a pessoa escolheu.** Ela escolhe *um monitor* no seletor acima; o áudio de sistema do
    /// ScreenCaptureKit não é o som daquele monitor — é a mistura da **máquina inteira**. Escolher
    /// "DELL U2415" não limita o som ao que está naquela tela, e nada na interface sugeriria o
    /// contrário.
    ///
    /// E há a assimetria que pesa mais: **a tela compartilhada é visível para quem compartilha.**
    /// A pessoa olha o monitor e sabe o que está indo. O som não tem essa propriedade — não dá
    /// para olhar a tela e saber que uma notificação, uma música de fundo ou uma chamada em outro
    /// app entraram na captura. É a mesma natureza do problema que `docs/audio.md` §8 descreve
    /// para os artefatos: o som não carrega no nome o que tem dentro.
    ///
    /// Ligar por padrão faria o produto emitir, na primeira vez, um conteúdo mais largo do que o
    /// escolhido e invisível para quem escolheu. Desligado, custa **um clique** numa tela que já
    /// exige uma escolha — e o clique é uma decisão informada, que é o que a assimetria pede.
    ///
    /// Isto não contradiz "tela espelhada sem som é meia coisa" (`docs/audio.md` §1). Contradiria
    /// se o som fosse difícil de ligar; ele está aqui, na mesma tela, uma linha abaixo da origem.
    @Published var comSom = false

    /// **Por qual rede o vídeo sai.** `nil` é Automática — o de sempre: o ICE reúne todas as
    /// interfaces e escolhe. Um nome BSD (`en12`) prende a sessão àquela interface e desiste das
    /// outras (`QuallSessionOptions::bind_address`), e o endereço para digitar passa a ser o dela.
    ///
    /// Pedido do usuário em 10/09: *"só exibe o ip da wireless, quero sair pela interface ethernet"*.
    /// O Mac da bancada tinha Wi-Fi e a placa USB Ethernet na mesma rede, e a tela mostrava só o
    /// Wi-Fi. Lembrada entre aberturas: quem pôs o Mac no cabo quer continuar no cabo.
    @Published var redeEscolhida: String? = UserDefaults.standard.string(forKey: Emissor.chaveDaRede) {
        didSet { UserDefaults.standard.set(redeEscolhida, forKey: Emissor.chaveDaRede) }
    }
    /// As interfaces com endereço agora, pelo nome de Ajustes > Rede. Relidas no Atualizar e no Espelhar.
    @Published private(set) var redes: [Enderecos.Interface] = []
    static let chaveDaRede = "rede.bsd"
    /// Quantos quadros de áudio a casca produziu e quantos o núcleo aceitou, em uma linha.
    @Published private(set) var resumoDoAudio = ""

    // MARK: - a câmera comum com dono (R5 fase 4, `docs/teleprompter-com-camera.md` §8.9, item 8)
    //
    // Com uma câmera escolhida, a câmera **é da espera**, e não da sessão: abre no Espelhar, com a
    // prévia, o botão do microfone e o Gravar; o receptor que pareia pendura a transmissão, o que cai
    // a solta, e a espera volta com o mesmo PIN. Só o Parar fecha a câmera (gravando, o arquivo fecha
    // e fica em ~/Movies/Quall). O espelhamento de tela não muda.

    /// O dono da câmera da rodada, com a câmera escolhida. `nil` com uma tela.
    @Published private(set) var dono: DonoDaCamera?
    @Published private(set) var gravador: GravadorLocal?
    /// A prévia da espera como espelho (a mesma chave da tela R5).
    @Published var espelharPrevia: Bool = UserDefaults.standard.object(forKey: TelaComCamera.chaveDoEspelho) as? Bool ?? true {
        didSet { UserDefaults.standard.set(espelharPrevia, forKey: TelaComCamera.chaveDoEspelho) }
    }
    private var agendadosDaCamera: [DispatchWorkItem] = []
    /// Bancada: o gerador do tom na saída do dispositivo virtual (G5, o laço fechado).
    private var geradorDaCamera: GeradorNoDispositivo?
    /// O gerador já respondeu (subiu, recusou ou estourou o prazo).
    private var geradorRespondeu = false
    /// Falhas seguidas da espera da câmera: o mesmo teto da tela R5.
    private var falhasDaCamera = 0

    let nome = Identidade.nomeDoAparelho
    let argumentos = Argumentos.lidos()

    /// O monitor de quem não diz a tela (o tablet da bancada deitado, na escala escolhida — ou na de
    /// `--tela-estendida=1x|2x`), e o dos argumentos de bancada. Quem diz a tela ganha o formato
    /// dela em `modoDoMonitor(para:)`.
    #if QUALL_TELA_ESTENDIDA_FUTURA
    var modoDaTelaEstendida: ModoDoMonitorVirtual {
        let escala = escalaEfetiva
        // O fps é a escolha da tela inicial (30 ou 60), e o monitor nasce com o dobro dele
        // (`ModoDoMonitorVirtual.hertzDoMonitor`, medido em 11/09). A bancada vale por cima:
        // `--tela-estendida-fps` fixa o fps; `--tela-estendida-hz` fixa o monitor — e, sozinho, os
        // dois, como era antes de 11/09. Até 120 Hz pela bancada (o S24 tem painel de 120 Hz, 10/09).
        let hertzDaBancada = argumentos.telaEstendidaHz.map { min(120, max(15, $0)) }
        let fps = argumentos.telaEstendidaFps ?? hertzDaBancada
            ?? (telaEstendidaA60 ? 60 : ModoDoMonitorVirtual.fpsPadrao)
        let hertz = hertzDaBancada ?? ModoDoMonitorVirtual.hertzDoMonitor(paraFps: fps)
        if let tamanho = argumentos.telaEstendidaTamanho {
            let partes = tamanho.lowercased().split(separator: "x").compactMap { Int($0) }
            if partes.count == 2, partes[0] > 0, partes[1] > 0, partes[0] % 2 == 0, partes[1] % 2 == 0 {
                // Sem `--tela-estendida`, a escala escolhida — mas 1x abaixo do piso do 2x: o tamanho
                // de bancada é o do monitor, e não há painel para reduzir. Com ela, vale o pedido — e
                // o auxiliar diz com `!!` se o 2x não existir.
                let daRegra: ModoDoMonitorVirtual.Escala = escalaDaTelaEstendida == .dobro
                    && ModoDoMonitorVirtual.cabeEm2x(larguraPx: partes[0], alturaPx: partes[1]) ? .dobro : .umPraUm
                return ModoDoMonitorVirtual(larguraEmPixels: partes[0], alturaEmPixels: partes[1], hertz: hertz,
                                            fps: fps, escala: argumentos.telaEstendida == nil ? daRegra : escala)
            }
            Registro.compartilhado.linha("!! --tela-estendida-tamanho=\(tamanho) inválido (LxA, pares) — usando o tablet")
        }
        return .tabletDaBancada(escala: escala, fps: fps, hertz: hertz)
    }

    /// **60 fps na tela estendida**, por escolha da pessoa — o padrão é 30 (ver
    /// `ModoDoMonitorVirtual.fpsPadrao`). Lembrada entre aberturas.
    @Published var telaEstendidaA60: Bool = UserDefaults.standard.bool(forKey: Emissor.chaveDos60fps) {
        didSet {
            UserDefaults.standard.set(telaEstendidaA60, forKey: Emissor.chaveDos60fps)
            renovarTelaEstendida()
        }
    }
    static let chaveDos60fps = "telaEstendida.60fps"

    /// **2x ou 1x na tela estendida**, por escolha da pessoa, lembrada entre aberturas. 2x por
    /// padrão — a letra do tamanho da do Mac; nos painéis em que o macOS não aceita o 2x (menos de
    /// 1060 px de altura), o 2x reduzido (`ModoDoMonitorVirtual.paraTela`). 1x é o painel inteiro
    /// como espaço, letra pequena. Vale para os monitores que nascerem depois da troca, e vence a
    /// lembrança do macOS (`MonitorVirtual.criar`); trocar em Ajustes > Monitores vale até a sessão
    /// acabar.
    @Published var escalaDaTelaEstendida: ModoDoMonitorVirtual.Escala =
        UserDefaults.standard.string(forKey: Emissor.chaveDaEscala).flatMap(ModoDoMonitorVirtual.Escala.init(rawValue:)) ?? .dobro {
        didSet {
            UserDefaults.standard.set(escalaDaTelaEstendida.rawValue, forKey: Emissor.chaveDaEscala)
            renovarTelaEstendida()
        }
    }
    static let chaveDaEscala = "telaEstendida.escala"

    /// A linha "Tela estendida" carrega o modo (e o fps) de quando o catálogo foi lido; trocar a opção
    /// de 60 fps depois disso tem de trocar a linha — e a escolha, se for ela —, senão o Espelhar
    /// sairia com o modo velho.
    private func renovarTelaEstendida() {
        let nova = FonteDeCaptura.telaEstendida(modoDaTelaEstendida)
        seletor.trocar({ $0.modoDaTelaEstendida != nil }, por: nova)
        fontes = seletor.fontes
        sincronizarAEscolha()
    }

    /// **O teto da tela estendida é o do núcleo, não o da cópia local.** A cópia (`TetoDoEmissor`,
    /// nível 4.0, 30 fps) reduziria 1920 × 1200 — 9.000 macroblocos contra 8.192 — para ~1830 × 1144 a
    /// 30 fps: letra borrada e o mouse andando aos saltos num monitor. O núcleo anuncia 5.2 e aceita
    /// alvo e fps por sessão (`quall_teto_ajustar_para`); o alvo pedido é a área inteira do monitor.
    ///
    /// Se a fronteira devolver erro, cai na cópia **dizendo isso no registro** — é a regra de
    /// `docs/quem-limita-a-imagem.md`: nunca mudar em silêncio o que foi pedido.
    static func tetoDoNucleo(largura: Int, altura: Int, fps: Int32) -> TetoDoEmissor.Aplicado {
        let area = TetoDoEmissor.macroblocos(largura: largura, altura: altura)
        guard let t = NucleoDeRede.teto(largura: largura, altura: altura, fps: fps,
                                        alvoMaxFs: area, alvoFps: fps) else {
            Registro.compartilhado.linha(
                "!! tela estendida: quall_teto_ajustar_para falhou (\(NucleoDeRede.ultimoErro())) — "
                + "caindo na cópia local, nível 4.0 a 30 fps")
            return .daCopiaLocal(largura: largura, altura: altura, fps: fps)
        }
        let saida = TetoDoEmissor.Saida(
            largura: t.largura, altura: t.altura, fps: t.fps,
            reduziuTamanho: t.reduziuTamanho, reduziuFps: t.reduziuFps,
            macroblocos: t.macroblocos, exigeRecorte: t.exigeRecorte, tetoDeTaxaBps: t.tetoDeTaxaBps)
        return TetoDoEmissor.Aplicado(saida: saida, levelIdc: t.levelIdc, maxFS: t.maxFS, origem: "núcleo")
    }
    #endif
    private var jaEspelhouSozinho = false

    /// As duas levas do catálogo e a escolha dentro delas (`SeletorDeFontes`): a escolha só é
    /// conferida com a lista inteira, e nunca vira outra por conta própria. Só tocado na main.
    private var seletor = SeletorDeFontes()
    /// Uma escrita em `fonteEscolhida` que vem do `seletor`, e não da pessoa.
    private var sincronizandoAEscolha = false
    /// O aviso da fonte que sumiu, **como foi posto** no `conselho`. Guardado à parte para sair
    /// sozinho: o conselho pode trazer junto o motivo do fim de uma sessão, e esse fica (a
    /// reconferência de 18/09). Sai quando a pessoa escolhe, quando a mesma volta, ou quando uma de
    /// mesmo nome aparece.
    private var avisoDaFonte: String?

    /// Tira do conselho **só** o aviso da fonte que sumiu.
    private func tirarAvisoDaFonte() {
        guard let aviso = avisoDaFonte else { return }
        avisoDaFonte = nil
        conselho = SeletorDeFontes.semOAviso(conselho, aviso)
    }
    /// O aviso do AppKit de que o conjunto de telas mudou. Guardado para poder ser solto.
    private var observadorDeTelas: NSObjectProtocol?

    /// O emissor em uso, para o `--sair-apos` esperar o desmonte (o `App` não pode capturar o
    /// `@StateObject` dele numa closure do `init`). Só lido na main.
    static weak var atual: Emissor?

    /// **A saída de vídeo sai espaçada a 60 Mbit/s.** Medido em 11/09/2026 com o Mac no cabo e dois
    /// receptores no mesmo rádio (`docs/tela-estendida.md`, corrida B): a rajada de um IDR chegava
    /// ao roteador de uma vez, e espalhá-la levou a perda do vizinho de 7,4 % para 0,17 %, sem mexer
    /// na taxa média. Com o Mac no Wi-Fi não foi medido. `--espacamento-mbps=0` desliga.
    static let espacamentoPadraoMbps = 60.0
    /// O que esta abertura pediu ao núcleo, para o registro de cada sessão.
    private let espacamentoMbps: Double

    init() {
        espacamentoMbps = max(0, argumentos.espacamentoMbps ?? Emissor.espacamentoPadraoMbps)
        // Vale para as sessões abertas daqui em diante, que são todas as deste processo.
        quall_set_video_pacing_kbps(UInt32((espacamentoMbps * 1000).rounded()))
        #if QUALL_TELA_ESTENDIDA_FUTURA
        TransmissaoAoVivo.capturaComMeioPeriodo = !argumentos.capturaPeriodoInteiro
        #endif
        TransmissaoAoVivo.tetoDeQuadroBytes = argumentos.tetoQuadroKb.map { max(0, $0) * 1024 }
        #if QUALL_TELA_ESTENDIDA_FUTURA
        if let gop = argumentos.gopTelaEstendida, gop >= 1 { TransmissaoAoVivo.gopDaTelaEstendida = gop }
        #endif
        if let pedido = argumentos.comSom { comSom = pedido }
        if let rede = argumentos.rede { redeEscolhida = rede == "auto" ? nil : rede }
        redes = Enderecos.interfaces()
        // `--tom-sintetico` só faz sentido com som: o tom existe para ser capturado.
        if argumentos.tomSintetico { comSom = true }

        // **O modo de bancada não pode depender de a janela aparecer.**
        //
        // Medido em 2026-08-27: rodando o binário solto (fora do `.app`), o catálogo de fontes
        // nunca era pedido e o log parava na primeira linha. A causa não era permissão — era que
        // `atualizarFontes()` só saía de `TelaInicial.onAppear`, e sem bundle o LaunchServices não
        // monta a cena, então **nenhuma view aparece**. O sintoma ("trava sem dizer nada") era
        // idêntico ao de um bloqueio de TCC, e as duas hipóteses custam tempo diferente.
        //
        // Isto não conserta rodar fora do `.app` — nada conserta, e não deveria: sem bundle o TCC
        // atribui o pedido ao processo errado. O que isto conserta é o diagnóstico ficar mudo.
        // **A lista de monitores se recompõe sozinha.**
        //
        // Sem isto ela só era refeita no `onAppear` da tela inicial e no botão Atualizar: quem
        // desplugasse um monitor com o app parado na tela inicial continuaria vendo a linha dele,
        // e escolhê-la falharia depois, no Espelhar, com um erro sobre um monitor que a pessoa
        // acabou de tirar. É o mesmo buraco que a frente do Windows fechou no `WM_DISPLAYCHANGE`.
        //
        // Só na fase inicial: durante a transmissão quem cuida do monitor é o `VigiaDeMonitor`, e
        // reenumerar aqui seria uma segunda voz dizendo a mesma coisa em outro lugar.
        observadorDeTelas = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `--exibir` não pode acordar o catálogo: `atualizarSoAsTelas` chama
            // `PermissaoDeTela.pedir()`, e um app aberto para **ver** a tela de outra pessoa não
            // tem por que pedir Gravação de Tela. Este aviso chega uma vez no arranque, então sem
            // esta guarda toda corrida de recepção pedia a permissão errada.
            guard let self, !self.argumentos.semEmissao else { return }
            guard self.fase == .inicial, !self.carregandoFontes else { return }
            Registro.compartilhado.linha("as telas mudaram — recompondo a lista de fontes")
            self.atualizarSoAsTelas()
        }

        // **Aberto para exibir, este app não pede permissão de tela nenhuma** — e a regra da casa
        // é essa mesma: pedir é o que cria a linha em Ajustes do Sistema, e um app que pede uma
        // permissão que não vai usar é o oposto do que `docs/app-macos.md` defende no resto.
        // `atualizarFontes()` chama `CGRequestScreenCaptureAccess()` e
        // `AVCaptureDevice.requestAccess`; com `--exibir` a tela inicial nem aparece, então não há
        // catálogo a montar. Numa corrida de bancada de recepção, sem isto, o app pediria Gravação
        // de Tela para exibir a tela de outra pessoa.
        Emissor.atual = self
        // `semEmissao` e não só `exibir`: aberto direto no teleprompter (`--teleprompter=…`), o app
        // também não emite, e o `--pin`/`--registro` da corrida ligariam `modoDeBancada` e fariam
        // este `init` pedir Gravação de Tela e Câmera para mostrar um roteiro.
        guard argumentos.modoDeBancada, !argumentos.semEmissao else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.fontes.isEmpty, !self.carregandoFontes else { return }
            Registro.compartilhado.linha("bancada: pedindo o catálogo sem esperar a janela")
            self.atualizarFontes()
        }
    }

    // MARK: - as sessões (só tocadas na main)

    /// **Uma por receptor**, e no máximo uma esperando. Ver `SessaoDeEmissao` para o que é de cada
    /// uma; aqui fica o que é do app — a interface, o anúncio, a decisão de abrir a próxima espera.
    private var sessoes: [SessaoDeEmissao] = []
    private var proximoId = 1
    private var encerrandoTudo = false
    /// A fonte, o som e a rede do Espelhar em curso: valem para todas as esperas que ele abrir.
    private var fonteDaRodada: FonteDeCaptura?
    private var somDaRodada = false
    private var redeDaRodada: (ligarEm: String?, descricao: String) = (nil, "automática")

    /// Mais de um receptor ao mesmo tempo é **só da tela estendida**: cada um ganha o seu monitor.
    /// Nas outras fontes, mandar a mesma tela para vários é outra pergunta, que ninguém fez.
    ///
    /// **8.** Era 4, número escolhido e não medido; o usuário rodou 4 aparelhos em 11/09 e pediu
    /// mais. Medido no laço no mesmo dia (monitor a 60 Hz, 30 fps, os formatos da bancada —
    /// `docs/tela-estendida.md`, "Mais de 4 monitores"): **monitor parado não custa nada** (0,1 Mbps,
    /// ~0 imagens por segundo); com 8 no ar e 2 se mexendo, os dois ficam em ~28 imagens por segundo,
    /// como sozinhos. O teto é o de pixels que mudam: o M4 entrega ~460 milhões por segundo — 6
    /// grandes se mexendo juntos ficam em ~28 (latência da captura ~40 ms); 8, em 21–25 (95–144 ms).
    static let limiteDeMonitores = 8

    /// Os receptores no ar, para a tela de espera. Só muda na main.
    struct ReceptorAtivo: Identifiable, Equatable {
        let id: Int
        let nome: String
        let monitor: String
        let resumo: String
    }
    @Published private(set) var receptores: [ReceptorAtivo] = []
    /// Transmitindo **e** com uma espera aberta para mais um aparelho (tela estendida).
    @Published private(set) var esperandoMaisUm = false

    private let anunciante = Anunciante()
    /// O anúncio mDNS muda de porta a cada espera nova, e parar o anterior bloqueia até ~1 s (dívida
    /// 3): fila serial própria, fora da main, na ordem em que foi pedido.
    private let filaDoAnuncio = DispatchQueue(label: "quall.anuncio")
    private let trava = NSLock()
    /// Anúncios mDNS ainda na fila (sob `trava`): o `--sair-apos` espera zerar, senão o adeus do mDNS
    /// se perde e os outros aparelhos ficam com o Mac fantasma na lista (dívida 3).
    private var anunciosPendentes = 0
    var anuncioOcioso: Bool { trava.withLock { anunciosPendentes == 0 } }
    /// Índices de monitores de sessões que ainda estão saindo (o auxiliar leva até 3 s).
    private var monitoresSaindo: Set<Int> = []
    /// A origem sintética da bancada. Só existe com `--tom-sintetico`, e nesse modo a captura é
    /// limitada a este processo — ver `Argumentos.tomSintetico`. Uma só, com a primeira sessão.
    private var tom: TomSintetico?

    /// Prazo de uma **única** tentativa de hospedar.
    ///
    /// Cinco minutos, e não um laço de tentativas curtas — a escolha importa. A dívida 21 mostra
    /// que `Session::offerer_com_tracks` é criada dentro do laço de tentativas e que a dívida 14 é
    /// cobrada **por tentativa**: numa rede onde o pareamento fecha mas o ICE nunca fecha
    /// (isolamento de AP, Wi-Fi de hóspede), um laço acumularia uma `Track` vazada por volta. A
    /// ordem que a dívida 21 fixa é explícita — consertar a dívida 4 **antes** de qualquer casca
    /// tirar o teto de tentativas. Então: uma tentativa longa e cancelável, que é o que a pessoa
    /// quer de qualquer forma (ela vai pegar o outro aparelho, não ficar olhando a tela).
    private static let prazoDeEspera: UInt32 = 5 * 60 * 1000

    /// **O escopo do conteúdo, e ele só tem dois valores por um motivo de regra.**
    ///
    /// `.somenteEsteApp` existe apenas no modo de prova (`--tom-sintetico`), onde a captura é
    /// limitada a este processo e a origem do som é um tom que nós mesmos geramos. Fora dele o
    /// escopo é a máquina inteira — que é o produto, e é o conteúdo que **nunca** pode ser gravado
    /// ou ouvido por esta frente (`docs/audio.md` §8).
    ///
    /// Não há caminho de interface para `.somenteEsteApp`: ninguém quer espelhar só a janela do
    /// Quall. É instrumento de bancada, e está atrás de um argumento de linha de comando.
    var escopoDaCaptura: EscopoDaCaptura {
        argumentos.tomSintetico ? .somenteEsteApp : .aMaquinaInteira
    }

    /// O preset de áudio desta sessão, ou `nil` quando ela é sem som.
    ///
    /// Espécie `SystemAudio`, e o codec é o **piso** enquanto a fronteira C não expõe um encoder
    /// de Opus — ver `CodificadorPCMU` e `NucleoDeRede.enviarAudio`.
    static let presetDeAudioDaSessao = PresetDeAudio.audioDoSistema(codec: .pcmu)

    private func naMain(_ bloco: @escaping () -> Void) {
        if Thread.isMainThread { bloco() } else { DispatchQueue.main.async(execute: bloco) }
    }

    // MARK: - fontes

    /// Telas e câmeras são pedidas **em separado** e a lista se preenche em duas levas.
    ///
    /// `AVCaptureDevice.requestAccess` bloqueia até a pessoa responder o diálogo do sistema.
    /// Enquanto as duas metades voltavam juntas, a primeira abertura do app mostrava "Procurando
    /// telas e câmeras…" até alguém clicar em Permitir numa caixa sobre a permissão de **câmera**
    /// — para ver as **telas**, que não dependem dela em nada. E numa corrida de bancada, onde
    /// ninguém clica, a lista nunca chegava.
    func atualizarFontes() {
        redes = Enderecos.interfaces()
        carregandoFontes = true
        // As metades velhas **não** são zeradas: com elas zeradas, a primeira metade que voltava
        // montava a lista sem a outra, e a escolha dela era dada como sumida (`SeletorDeFontes`).
        seletor.pedirAsDuas()

        // `pedindoPermissao: true` porque **este** processo é quem tem o direito de pedir.
        // Consultar `authorizationStatus` não cria a linha no painel de Privacidade; só
        // `requestAccess` cria. E quem pede é o processo responsável — por isso o app precisa ser
        // aberto pelo LaunchServices, e não por `exec` de shell.
        #if QUALL_TELA_ESTENDIDA_FUTURA
        let modo = modoDaTelaEstendida
        #endif
        Task.detached { [self] in
            #if QUALL_TELA_ESTENDIDA_FUTURA
            let metade = await CatalogoDeFontes.telas(telaEstendida: modo)
            #else
            let metade = await CatalogoDeFontes.telas()
            #endif
            naMain { self.receber(metade, saoTelas: true) }
        }
        Task.detached { [self] in
            let metade = await CatalogoDeFontes.cameras(pedindoPermissao: true)
            naMain { self.receber(metade, saoTelas: false) }
        }
    }

    /// Recompõe **só a metade das telas**, sem tocar nas câmeras.
    ///
    /// # Por que existe uma versão pela metade
    ///
    /// Porque quem chama isto é o aviso de que as telas mudaram, e as câmeras não têm nada com o
    /// assunto. Passar pelo caminho inteiro chamaria `AVCaptureDevice.requestAccess`, que
    /// **bloqueia** até uma pessoa responder o diálogo — e disparar isso porque alguém mexeu num
    /// cabo HDMI é exatamente o defeito que separou as duas levas do catálogo em 2026-08-27.
    ///
    /// A metade das telas é barata: com a permissão já concedida, `conferirEPedir` devolve na
    /// hora sem pedir nada.
    private func atualizarSoAsTelas() {
        seletor.pedirMaisUma()
        #if QUALL_TELA_ESTENDIDA_FUTURA
        let modo = modoDaTelaEstendida
        #endif
        Task.detached { [self] in
            #if QUALL_TELA_ESTENDIDA_FUTURA
            let metade = await CatalogoDeFontes.telas(telaEstendida: modo)
            #else
            let metade = await CatalogoDeFontes.telas()
            #endif
            naMain { self.receber(metade, saoTelas: true) }
        }
    }

    private func receber(_ metade: CatalogoDeFontes.Metade, saoTelas: Bool) {
        if saoTelas {
            telaBloqueada = metade.bloqueio
        } else {
            cameraBloqueada = metade.bloqueio
        }
        // **A escolha que sumiu é dita, e nunca trocada por outra** (`SeletorDeFontes`). Até 18/09
        // ela era conferida contra a lista pela metade e depois reelegia `fontes.first`: o Atualizar
        // trocava a tela escolhida pela câmera do Mac (registro de 10/09, 16:51:42; a revisão de
        // código de 18/09). Agora ela só é conferida com as duas metades, a que sumiu deixa o
        // seletor sem escolha e com o aviso, e a mesma, se voltar, volta escolhida.
        //
        // A linha "Tela estendida" que chega leva o modo de quando a metade foi **pedida**: se a
        // pessoa trocou a escala no meio, ela chegaria com o modo velho e voltaria para a escolha
        // (a reconferência de 18/09). O modo é sempre o de agora.
    #if QUALL_TELA_ESTENDIDA_FUTURA
        let modo = modoDaTelaEstendida
        let chegou = saoTelas
            ? metade.fontes.map { $0.modoDaTelaEstendida != nil ? FonteDeCaptura.telaEstendida(modo) : $0 }
            : metade.fontes
    #else
        let chegou = metade.fontes
    #endif
        let mudanca = seletor.receber(chegou, saoTelas: saoTelas)
        fontes = seletor.fontes
        switch mudanca {
        case .nenhuma, .padrao:
            break
        case .sumiu(let escolhida):
            // O motivo do fim de uma sessão, se estiver no conselho, fica na frente do aviso.
            let aviso = T("\"%@\" não está mais disponível. Escolha outra fonte.", escolhida.nome)
            tirarAvisoDaFonte()
            conselho = SeletorDeFontes.comOAviso(conselho, aviso)
            avisoDaFonte = aviso
            Registro.compartilhado.linha(
                "fonte escolhida sumiu da lista — sem escolha agora")
        case .voltou(let volta):
            tirarAvisoDaFonte()
            Registro.compartilhado.linha("a fonte escolhida que tinha sumido voltou")
        case .reapareceu(let parecida):
            // O nome dela está na lista com outro id (o Sidecar volta assim): não se escolhe, mas
            // "não está mais disponível" seria falso.
            if avisoDaFonte != nil {
                tirarAvisoDaFonte()
                Registro.compartilhado.linha(
                    "uma fonte com o nome da que sumiu apareceu com outro id — sem escolha, e o aviso sai")
            }
        }
        sincronizarAEscolha()

        Registro.compartilhado.linha(
            "fontes (\(saoTelas ? "telas" : "cameras")): \(metade.fontes.count)"
            + " bloqueado=\(metade.bloqueio != nil) diagnostico_presente=\(!metade.diagnostico.isEmpty)")

        if seletor.completo {
            carregandoFontes = false
            talvezEspelharSozinho()
        }
    }

    /// Leva a escolha do `seletor` para a tela, sem ela voltar ao `seletor` como escolha da pessoa.
    private func sincronizarAEscolha() {
        guard fonteEscolhida != seletor.escolhida else { return }
        sincronizandoAEscolha = true
        fonteEscolhida = seletor.escolhida
        sincronizandoAEscolha = false
    }

    /// O toque em Espelhar que um agente de bancada não tem como dar. Ver `Argumentos`.
    private func talvezEspelharSozinho() {
        guard argumentos.espelharJa, !jaEspelhouSozinho, fase == .inicial else { return }
        if let pedida = argumentos.fonte {
            let escolhida = fontes.first { $0.id == pedida }
                ?? fontes.first { pedida == "tela" && $0.ehTela }
                ?? fontes.first { pedida == "camera" && !$0.ehTela }
            guard let escolhida else {
                Registro.compartilhado.linha("ERRO: --fonte \(pedida) não bate com nenhuma fonte listada")
                return
            }
            fonteEscolhida = escolhida
        }
        guard fonteEscolhida != nil else {
            Registro.compartilhado.linha("ERRO: --espelhar-ja sem nenhuma fonte disponível")
            return
        }
        jaEspelhouSozinho = true
        espelhar()
    }

    // MARK: - espelhar

    func espelhar() {
        guard fase == .inicial, let fonte = fonteEscolhida else { return }

        // A câmera abre **antes** da espera, com a permissão pedida (não só lida): sem ela, a espera
        // abriria uma câmera que entrega quadro preto.
        if !fonte.ehTela, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            DonoDaCamera.pedirPermissaoDaCamera { [weak self] negada in
                guard let self else { return }
                if let negada { self.conselho = negada; return }
                self.espelhar()
            }
            return
        }

        conselho = ""
        avisoDaFonte = nil
        ofereceDesparear = false
        resumoDaTransmissao = ""
        resumoDoAudio = ""
        par = ""

        // O **som de sistema** só quando a pessoa pediu **e** a origem é uma tela: no macOS ele vem do
        // ScreenCaptureKit. A câmera leva o **microfone** (R5 fase 4), pelo botão da espera e pela
        // track de microfone que toda sessão de câmera com dono oferece — não por esta caixa.
        let querSom = comSom && fonte.ehTela
        haParesConhecidos = Identidade.haParesConhecidos()

        // A rede. Escolhida e sem endereço agora (a placa USB saiu, o Wi-Fi caiu) é aviso, e não
        // queda silenciosa para outra interface: a pessoa escolheu **esta**.
        redes = Enderecos.interfaces()
        var ligarEm: String?
        var descricaoDaRede = "automática"
        if let bsd = redeEscolhida {
            guard let rede = redes.first(where: { $0.bsd == bsd }) else {
                conselho = T("A rede escolhida (%@) está sem endereço agora. Escolha outra em "
                    + "\"Sair pela rede\", ou Automática.", bsd)
                return
            }
            ligarEm = rede.ip
            descricaoDaRede = "\(rede.bsd) (\(rede.rotulo)), presa"
        }

        fonteDaRodada = fonte
        somDaRodada = querSom
        redeDaRodada = (ligarEm, descricaoDaRede)
        encerrandoTudo = false
        if case .camera(let uid) = fonte.tipo {
            guard abrirODono(uid) else {
                fonteDaRodada = nil
                return
            }
        }
        guard abrirEspera() else {
            fonteDaRodada = nil
            fecharODono(motivo: "a espera não abriu")
            return
        }
        fase = .esperando
    }

    /// Abre o dono da câmera da rodada: o formato ativo (a câmera comum não muda de formato nem de
    /// carga, §8.8 do iOS), o microfone pela política (G5) e o gravador. `false` com o motivo no
    /// conselho.
    private func abrirODono(_ uid: String) -> Bool {
        let d = DonoDaCamera { Registro.compartilhado.linha($0) }
        d.microfoneSintetico = argumentos.microfoneSintetico
        aplicarModoDoMicrofone(d)
        d.aoMudar = { [weak self] in self?.objectWillChange.send() }
        BancadaDosAjustesDaCamera.configurar(d, argumentos)
        if let erro = d.montar(uniqueID: uid, melhorImagem: false) {
            conselho = erro
            return false
        }
        // O controle remoto da câmera (R9b): o filmador desta câmera, que as sessões bombeiam.
        CameraRemotaDoDono.anexar(a: d)
        d.ligar()
        dono = d
        // O gerador do laço (bancada) sobe **depois** da câmera, fora da principal e com prazo: a
        // câmera e a espera nunca esperam pelo CoreAudio (a prova de 25/09 travou a janela aqui).
        if argumentos.microfoneNaRegraDaBancada, let uid = argumentos.tomNoDispositivo, geradorDaCamera == nil {
            let g = GeradorNoDispositivo(uid: uid)
            g.aoRegistrar = { Registro.compartilhado.linha("APP MICROFONE bancada: " + $0) }
            geradorDaCamera = g
            g.comecarForaDaMain(prazo: 10) { [weak self, weak g, weak d] recusa in
                guard let self, let g, let d, self.geradorDaCamera === g else { return }
                self.geradorRespondeu = true
                if let recusa {
                    Registro.compartilhado.linha("APP MICROFONE bancada: o gerador de tom RECUSOU tocar — \(recusa)")
                }
                self.aplicarModoDoMicrofone(d)
            }
        }
        let pasta = GravadorLocal.pastaPadrao(argumentos)
        gravador = GravadorLocal(dono: d, pasta: pasta)
        GravacoesPendentes.recuperar(em: pasta, por: "a câmera comum abriu")
        Registro.compartilhado.linha("APP CAMERA câmera comum: o dono abriu com a espera (a câmera é da espera, não da sessão)")
        agendarBancadaDaCamera(d)
        return true
    }

    /// Na bancada o microfone é o de `--microfone=`, e só com o laço fechado (o nosso gerador tocando
    /// nele agora, G5); no produto, o escolhido ou o padrão do sistema.
    private func aplicarModoDoMicrofone(_ d: DonoDaCamera) {
        d.modoDoMicrofone = argumentos.microfoneNaRegraDaBancada
            ? .bancada(pedido: argumentos.microfone,
                       laco: geradorDaCamera?.tocando == true ? geradorDaCamera?.uid : nil)
            : .produto(escolhido: UserDefaults.standard.string(forKey: TelaComCamera.chaveDoMicrofone))
    }

    /// Fecha o dono da rodada, **depois** de a gravação fechar o arquivo.
    private func fecharODono(motivo: String) {
        agendadosDaCamera.forEach { $0.cancel() }
        agendadosDaCamera = []
        geradorDaCamera?.pararForaDaMain()
        geradorDaCamera = nil
        geradorRespondeu = false
        falhasDaCamera = 0
        guard let d = dono else { return }
        // O registro de um pedido remoto ainda adiado vai para o disco já: um Espelhar logo em seguida, com
        // a mesma câmera, lê o registro antes de este dono acabar de fechar.
        d.descarregarGravacaoAdiada()
        let g = gravador
        dono = nil
        gravador = nil
        TelaComCamera.contarFecho(+1)
        let fechar = {
            d.fechar {
                TelaComCamera.contarFecho(-1)
                Registro.compartilhado.linha("APP CAMERA câmera comum: fechada (\(motivo))")
            }
        }
        if let g { g.parar(motivo: motivo, fim: fechar) } else { fechar() }
    }

    private func agendarBancadaDaCamera(_ d: DonoDaCamera) {
        guard argumentos.modoDeBancada else { return }
        func depois(_ s: Double, _ f: @escaping () -> Void) {
            let item = DispatchWorkItem(block: f)
            agendadosDaCamera.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: item)
        }
        if let apos = argumentos.microfoneApos {
            // Com o gerador do laço ainda subindo, o ligar espera por ele (até 15 s).
            func ligar(_ espera: Double) {
                guard let d = dono else { return }
                if geradorDaCamera != nil, !geradorRespondeu, espera < 15 {
                    depois(0.5) { [weak self] in if self != nil { ligar(espera + 0.5) } }
                    return
                }
                aplicarModoDoMicrofone(d)
                d.ligarMicrofone(por: "bancada --microfone-apos \(apos)")
                if let por = argumentos.microfonePor {
                    depois(por) { [weak d] in d?.desligarMicrofone(por: "bancada --microfone-por \(por)") }
                }
            }
            depois(apos) { [weak self, weak d] in
                guard let self, let d, self.dono === d else { return }
                ligar(0)
            }
        }
        if let g = gravador { BancadaDaGravacao.agendar(g, argumentos: argumentos, depois: depois) }
        BancadaDosAjustesDaCamera.agendar(d, argumentos, depois: depois)
    }

    /// Abre uma espera: porta (a pedida ou uma livre), PIN (o pedido, o da bancada ou um sorteado),
    /// e o anúncio mDNS passa a apontar para ela. `false` quando não há porta.
    ///
    /// **O PIN sorteado pelo núcleo é o caminho normal**: a qualidade do sorteio é o que segura o
    /// pareamento. `--pin` existe só para a bancada, onde ninguém tem olhos para ler a tela.
    @discardableResult
    private func abrirEspera(porta portaPedida: UInt16? = nil, pin pinPedido: String? = nil) -> Bool {
        guard let fonte = fonteDaRodada else { return false }
        let porta = portaPedida ?? Enderecos.portaLivre()
        guard porta != 0 else {
            conselho = T("Não consegui reservar uma porta de rede neste Mac.")
            return false
        }
        let pinDaEspera = pinPedido ?? argumentos.pin ?? NucleoDeRede.sortearPin()
        let endereco = redeDaRodada.ligarEm.map { Enderecos.comPorta($0, porta: porta) } ?? Enderecos.paraDigitar(porta: porta)
        // **Toda sessão oferece o som; só a do dono manda** (D2 do `docs/som-no-receptor.md`
        // §12.1). O som do sistema é a mistura da máquina inteira, e mandá-lo junto de cada monitor
        // seria o mesmo som tocando em vários aparelhos (revisão de 10/09/2026). Até 18/09 só a
        // primeira espera levava a track — e o som não tinha como passar a quem já estava
        // conectado, porque o Quall não renegocia. Ver `DonoDoSom`.
        let comAudio = somDaRodada
        let sessao = SessaoDeEmissao(id: proximoId, fonte: fonte, pin: pinDaEspera, porta: porta,
                                     endereco: endereco, ligarEm: redeDaRodada.ligarEm, comAudio: comAudio,
                                     dono: dono, comMicrofone: dono != nil)
        proximoId += 1
        ligar(sessao)
        sessoes.append(sessao)

        // PIN, fonte e endereço ficam na interface; o diário só registra a operação.
        sessao.registrar(
            "espelhar: preset=\(fonte.presetSugerido) "
            + "porta=\(porta) rede_disponivel=\(endereco != nil) "
            + "pares_conhecidos=\(haParesConhecidos) com_som=\(comAudio) "
            + "escopo=\(escopoDaCaptura.rawValue) rede_fixa=\(redeDaRodada.ligarEm != nil) "
            + "espacamento=\(espacamentoMbps > 0 ? "\(espacamentoMbps) Mbit/s" : "desligado")")

        // Anunciar **antes** de hospedar, porque `quall_host` bloqueia: se o anúncio esperasse a
        // sessão subir, este Mac só apareceria na lista dos outros depois de já ter recebido a
        // conexão. Falhar é esperado em rede com multicast bloqueado e **não é erro de produto** —
        // o endereço continua na tela e continua funcionando.
        anunciar(porta: porta, fonte: fonte)
        sessao.esperar(pares: Identidade.paresConhecidos(),
                       rotulo: fonte.rotuloDaTrack(nomeDoAparelho: nome),
                       prazoMs: Emissor.prazoDeEspera)
        publicar()
        return true
    }

    private func ligar(_ sessao: SessaoDeEmissao) {
        sessao.aoConectar = { [weak self] s in self?.aoConectar(s) }
        sessao.aoFalharAoHospedar = { [weak self] s, status, motivo in
            self?.aoFalharAoHospedar(s, status: status, motivo: motivo)
        }
        sessao.aoCair = { [weak self] s, saiu in self?.aoSairUmaSessao(s, porque: saiu ? .saiu : .caiu) }
        sessao.aoPararSozinho = { [weak self] s, erro in self?.aoSairUmaSessao(s, porque: .capturaParou(erro)) }
        sessao.aoNaoIniciar = { [weak self] s, erro in self?.aoSairUmaSessao(s, porque: .capturaNaoIniciou(erro)) }
        sessao.aoAtualizar = { [weak self] _ in
            self?.vigiarOSom()
            self?.publicar()
        }
    }

    /// O anúncio mDNS aponta sempre para **a espera aberta**, e some quando não há nenhuma.
    ///
    /// Continuar anunciando uma porta que já conectou convidaria um terceiro aparelho para um
    /// servidor que não aceita mais ninguém. Com a tela estendida isso vira troca de porta a cada
    /// receptor que entra — e parar o anúncio anterior bloqueia até ~1 s (dívida 3), então tudo vai
    /// numa fila serial própria, na ordem em que foi pedido.
    private func anunciar(porta: UInt16?, fonte: FonteDeCaptura?) {
        let deviceId = Identidade.deviceId
        let nomeDoAparelho = Identidade.nomeDoAparelho
        let emiteTela = fonte?.ehTela ?? true
        trava.withLock { anunciosPendentes += 1 }
        filaDoAnuncio.async { [self] in
            defer { trava.withLock { anunciosPendentes -= 1 } }
            anunciante.parar()
            guard let porta else {
                naMain { self.anunciandoPorMDNS = false; self.nomeNaDescoberta = nil }
                Registro.compartilhado.linha("mdns: parado")
                return
            }
            let anunciou = anunciante.comecar(deviceId: deviceId, nome: nomeDoAparelho, porta: porta,
                                              emiteTela: emiteTela, emiteCamera: !emiteTela)
            Registro.compartilhado.linha("mdns: anunciou=\(anunciou) porta=\(porta)")
            let alias = anunciou ? anunciante.nomePublico : nil
            naMain { self.anunciandoPorMDNS = anunciou; self.nomeNaDescoberta = alias }
        }
    }

    // MARK: - de volta na main

    private func aoConectar(_ s: SessaoDeEmissao) {
        // Uma sessão que já não é desta rodada (a pessoa parou e espelhou de novo no meio): fecha
        // e esquece — senão ela transmitiria por fora da lista, onde o Parar não alcança.
        guard sessoes.contains(where: { $0 === s }) else {
            s.registrar("conectou fora da rodada — fechando")
            s.encerrar {}
            return
        }
        guard !encerrandoTudo, fonteDaRodada != nil else { return }
        haParesConhecidos = true
        conselho = ""
        ofereceDesparear = false

        // **O mesmo aparelho de novo, antes de a sessão velha cair** (o Wi-Fi piscou e ele
        // reconectou): a velha sai primeiro, e **só depois** a nova transmite — dois monitores do
        // mesmo aparelho ao mesmo tempo dividiriam identidade, e esperar a velha soltar o monitor é
        // o que deixa a nova herdar a identidade do aparelho (o macOS lembra a arrumação dele).
        let velhas = s.par.deviceId.isEmpty ? [] : sessoes.filter {
            $0 !== s && ($0.estado == .transmitindo || $0.estado == .encerrando)
                && $0.par.deviceId == s.par.deviceId
        }
        guard !velhas.isEmpty else {
            iniciarTransmissao(s)
            return
        }
        // D2: a sessão nova herda a vaga (e o som, se era dela) da velha **antes** de a velha sair —
        // senão o som passaria ao segundo receptor e a nova entraria calada (crítica 9, M2).
        if s.comAudio {
            let toca = QuemTocaOSomDoMac.tocaPCMU(deviceId: s.par.deviceId)
            let antes = donoDoSom.dono
            for velha in velhas {
                donoDoSom.substituir(velha.id, por: s.id, novoToca: toca, aparelho: s.par.deviceId,
                                     agoraMs: Emissor.agoraMs())
            }
            aplicarDonoDoSom(antes, porque: "o mesmo aparelho voltou pela sessão #\(s.id)")
        }
        var faltam = velhas.count
        for velha in velhas {
            velha.registrar("o mesmo aparelho voltou pela sessão #\(s.id) — esta sai antes")
            encerrar(velha) { [weak self] in
                faltam -= 1
                guard faltam == 0, let self, s.estado == .transmitindo,
                      self.sessoes.contains(where: { $0 === s }) else { return }
                self.iniciarTransmissao(s)
            }
        }
        publicar()
    }

    private func iniciarTransmissao(_ s: SessaoDeEmissao) {
        guard !encerrandoTudo, let fonte = fonteDaRodada else { return }

        // D2: o primeiro receptor **que toca** ganha o som; os seguintes oferecem e calam
        // (crítica 9, M3: quem não toca o PCMU do Mac nunca é dono).
        if s.comAudio {
            let toca = QuemTocaOSomDoMac.tocaPCMU(deviceId: s.par.deviceId)
            let antes = donoDoSom.dono
            donoDoSom.conectou(s.id, toca: toca, aparelho: s.par.deviceId, agoraMs: Emissor.agoraMs())
            if donoDoSom.dono != antes {
                aplicarDonoDoSom(antes, porque: "a sessão #\(s.id) começou a transmitir: o primeiro que toca, "
                                 + "o dono que voltou na carência, ou a carência vencida")
            } else if !toca {
                s.registrar("som: este receptor não toca o PCMU do Mac; não é dono do som")
            }
        }

        // A origem sintética sobe **antes** da captura: um tom que começa depois do primeiro bloco
        // capturado deixaria silêncio na frente do artefato, indistinguível de "não capturou nada".
        trava.lock()
        let semTom = tom == nil
        trava.unlock()
        if argumentos.tomSintetico && semTom {
            let gerador = TomSintetico(frequencia: argumentos.tomHz ?? 440)
            gerador.aoRegistrar = { linha in Registro.compartilhado.linha(linha) }
            if let erro = gerador.comecar() {
                Registro.compartilhado.linha("tom sintético NÃO subiu: \(SanitizacaoDoLog.causaExterna(erro))")
            } else {
                trava.lock(); tom = gerador; trava.unlock()
                Registro.compartilhado.linha(
                    "tom sintético: \(gerador.frequencia) Hz, amplitude \(gerador.amplitude) — "
                    + "origem nossa, capturada com escopo \(escopoDaCaptura.rawValue)")
            }
        }

        // O monitor desta sessão: formato da tela do aparelho, nome dele, identidade dele.
    #if QUALL_TELA_ESTENDIDA_FUTURA
        var fonteDaSessao = fonte
        var nomeDoMonitor = T("Quall — tela estendida")
        var indice = 0
        if fonte.modoDaTelaEstendida != nil {
            fonteDaSessao = .telaEstendida(modoDoMonitor(para: s))
            if !s.par.nome.isEmpty { nomeDoMonitor = "Quall — \(s.par.nome)" }
            indice = indiceDoMonitor(para: s)
        }
        // A tela estendida é um monitor: o fps dela e o teto do núcleo. As outras fontes seguem
        // exatamente como antes — 30 fps pedidos e a cópia local do teto.
        let ehEstendida = fonteDaSessao.modoDaTelaEstendida != nil
        s.transmitir(fonteDaSessao: fonteDaSessao, nomeDoMonitor: nomeDoMonitor, indiceDoMonitor: indice,
                     // O fps é o do modo (a escolha, ou a bancada) — e nunca acima do Hz do monitor.
                     fps: ehEstendida ? Int32(fonteDaSessao.modoDaTelaEstendida?.fps ?? 30) : 30,
                     teto: ehEstendida ? Emissor.tetoDoNucleo : nil,
                     escopo: escopoDaCaptura,
                     // Em produto a sessão cai na primeira testemunha; na bancada ela espera 3 s,
                     // para o registro poder dizer quais das outras testemunhas chegaram e quando.
                     janelaDoVigia: argumentos.modoDeBancada ? 3.0 : 0)

        // **A espera seguinte**: tela estendida e abaixo do limite de monitores. Porta nova e PIN
        // novo — a porta da sessão que conectou continua presa ao servidor dela.
        if ehEstendida && vivas().count < Emissor.limiteDeMonitores && espera() == nil {
            if !abrirEspera() { anunciar(porta: nil, fonte: fonte) }
        } else if espera() == nil {
            anunciar(porta: nil, fonte: fonte)
        }
    #else
        s.transmitir(fonteDaSessao: fonte, nomeDoMonitor: "", indiceDoMonitor: 0,
                     fps: 30, teto: nil, escopo: escopoDaCaptura,
                     janelaDoVigia: argumentos.modoDeBancada ? 3.0 : 0)
        if espera() == nil { anunciar(porta: nil, fonte: fonte) }
    #endif
        publicar()
    }

    /// O formato do monitor de uma sessão. `--tela-estendida-tamanho` vale por cima de tudo; depois, a
    /// tela que o receptor disse, na escala de `escalaEfetiva`; sem ela, o de sempre.
    #if QUALL_TELA_ESTENDIDA_FUTURA
    private func modoDoMonitor(para s: SessaoDeEmissao) -> ModoDoMonitorVirtual {
        let padrao = modoDaTelaEstendida
        if argumentos.telaEstendidaTamanho != nil { return padrao }
        guard let tela = s.par.tela,
              let doAparelho = ModoDoMonitorVirtual.paraTela(larguraPx: tela.largura, alturaPx: tela.altura,
                                                             hertz: padrao.hertz, fps: padrao.fps,
                                                             escala: escalaEfetiva)
        else { return padrao }
        return doAparelho
    }

    /// A escala dos monitores desta abertura: a de `--tela-estendida=1x|2x` quando a bancada a fixa —
    /// para uma corrida não herdar em silêncio o que alguém escolheu na tela inicial (revisão de
    /// 11/09) —, senão a escolhida.
    var escalaEfetiva: ModoDoMonitorVirtual.Escala {
        argumentos.telaEstendida.flatMap(ModoDoMonitorVirtual.Escala.init(rawValue:)) ?? escalaDaTelaEstendida
    }

    /// A bancada fixou a escala: o seletor da tela inicial não vale nesta abertura.
    var escalaFixadaPelaBancada: Bool { argumentos.telaEstendida != nil }

    static let chaveDosIndices = "telaEstendida.indices"

    /// A identidade do monitor desta sessão: a do aparelho, gravada (`TabelaDeIndices`). Os índices
    /// dos monitores ainda de pé — inclusive os que estão saindo — ficam de fora.
    private func indiceDoMonitor(para s: SessaoDeEmissao) -> Int {
        let emUso = Set(sessoes.compactMap { outra -> Int? in
            guard outra !== s, outra.estado == .transmitindo || outra.estado == .encerrando else { return nil }
            return outra.indiceDoMonitor
        }).union(monitoresSaindo)
        var tabela = UserDefaults.standard.data(forKey: Emissor.chaveDosIndices)
            .flatMap { try? JSONDecoder().decode(TabelaDeIndices.self, from: $0) } ?? TabelaDeIndices()
        let chave = s.par.deviceId.isEmpty ? "sem-id-\(s.id)" : s.par.deviceId
        let indice = tabela.indice(para: chave, emUso: emUso, agora: Date().timeIntervalSince1970)
        if !s.par.deviceId.isEmpty, let dados = try? JSONEncoder().encode(tabela) {
            UserDefaults.standard.set(dados, forKey: Emissor.chaveDosIndices)
        }
        return indice
    }
    #endif

    private func aoFalharAoHospedar(_ s: SessaoDeEmissao, status: QuallStatus, motivo: String) {
        // Uma espera que já não é desta rodada: nada a fazer, e nenhum aviso.
        guard sessoes.contains(where: { $0 === s }) else { return }
        remover(s)
        // Cancelar é o caminho normal, não uma falha: a pessoa desistiu, ou foi este app que fechou
        // a espera. A tela volta sem aviso vermelho.
        if status == QUALL_STATUS_CANCELLED || encerrandoTudo {
            if sessoes.isEmpty && !encerrandoTudo { voltarAoInicio() }
            return
        }
        // Com a câmera da espera aberta, a espera **sempre** volta (o prazo sem ninguém também):
        // fechar aqui fecharia a câmera no meio de uma gravação sem receptor.
        let reabre = !vivas().isEmpty || dono != nil
        let (texto, desparear) = Emissor.conselho(para: status, motivo: motivo, reabre: reabre)
        if !texto.isEmpty { conselho = texto }
        if desparear { ofereceDesparear = true }

        guard reabre else {
            voltarAoInicio()
            return
        }
        if dono != nil, Date().timeIntervalSince(s.criadaEm) < 3 {
            falhasDaCamera += 1
            guard falhasDaCamera < EsperaDaCamera.tetoDeFalhas else {
                conselho = T("A câmera parou de esperar receptor depois de %@ falhas seguidas. "
                    + "Gravar continua funcionando; toque em Parar e espelhe de novo para esperar.", falhasDaCamera)
                s.registrar("!! a espera da câmera desistiu: \(falhasDaCamera) falhas seguidas")
                anunciar(porta: nil, fonte: nil)
                publicar()
                return
            }
            // Uma falha rápida não vira laço: a espera volta depois de um respiro.
            s.registrar("!! a espera da câmera falhou em menos de 3 s — reabro em 1 s")
            let porta = s.porta, pin = status == QUALL_STATUS_WRONG_PIN ? nil : s.pin
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.encerrandoTudo, self.dono != nil, self.espera() == nil else { return }
                self.abrirEspera(porta: porta, pin: pin)
                self.publicar()
            }
            publicar()
            return
        }
        // **Só a espera caiu; as sessões no ar continuam.** Até esta rodada qualquer falha aqui
        // voltava o app ao começo — um PIN errado na espera de mais um aparelho derrubaria os
        // monitores que já estavam transmitindo (revisão de 10/09/2026). Reabre na mesma porta (a
        // espera que falhou já soltou o servidor dela), com PIN novo quando o problema foi o PIN.
        //
        // Uma espera que falha em menos de 3 s não é reaberta: seria um laço de falhas, e o
        // conselho acima já diz o que houve.
        guard Date().timeIntervalSince(s.criadaEm) >= 3 else {
            s.registrar("!! a espera falhou em menos de 3 s — não reabro")
            anunciar(porta: nil, fonte: nil)
            publicar()
            return
        }
        abrirEspera(porta: s.porta, pin: status == QUALL_STATUS_WRONG_PIN ? nil : s.pin)
        publicar()
    }

    /// Os conselhos de quando a espera falha. **Dívidas 22 e 29**: cada falha classificada pelo
    /// código, com o que fazer — e não o texto cru do núcleo.
    ///
    /// `reabre`: a espera que falhou era a de mais um aparelho, com outros no ar — ela volta sozinha,
    /// e o conselho não pode mandar a pessoa tocar em Espelhar.
    private static func conselho(para status: QuallStatus, motivo: String, reabre: Bool) -> (String, Bool) {
        switch status {
        case QUALL_STATUS_NEEDS_PIN:
            return (T("Um aparelho tentou entrar com um pareamento que este Mac não reconhece mais. Peça "
                    + "para ele digitar o PIN de novo; se continuar falhando, esqueça os pareamentos e "
                    + "comecem do zero."), true)
        case QUALL_STATUS_WRONG_PIN:
            return (reabre
                    ? T("Um aparelho tentou entrar com o PIN errado. O PIN mudou: passe os seis dígitos "
                      + "novos — cada PIN vale uma tentativa por conexão.")
                    : T("Um aparelho tentou entrar com o PIN errado. Toque em Espelhar de novo e passe os "
                      + "seis dígitos novos — cada PIN vale uma tentativa por conexão."), false)
        case QUALL_STATUS_NO_ROUTE:
            return (T("O pareamento fechou, mas os dois aparelhos não acharam caminho um para o outro. "
                    + "Quase sempre é a rede: Wi-Fi de hóspede, isolamento entre aparelhos ou redes "
                    + "diferentes. Ponha os dois na mesma rede e tente de novo."), false)
        case QUALL_STATUS_TIMEOUT:
            // Com aparelhos no ar, a espera de mais um só se renova — não há o que dizer.
            return (reabre ? "" : T("Ninguém entrou em cinco minutos. Toque em Espelhar de novo quando o "
                    + "outro aparelho estiver pronto."), false)
        default:
            return (motivo.isEmpty ? T("Não consegui abrir a sessão.") : motivo, false)
        }
    }

    private enum PorQueSaiu {
        case saiu
        case caiu
        case capturaParou(Error)
        case capturaNaoIniciou(Error)
    }

    /// Uma sessão no ar acabou sozinha. Com mais de uma, só ela sai; com uma só, o app volta ao
    /// começo como sempre voltou — exceto na tela estendida com espera aberta, que continua esperando.
    private func aoSairUmaSessao(_ s: SessaoDeEmissao, porque motivo: PorQueSaiu) {
        guard sessoes.contains(where: { $0 === s }) else {
            s.encerrar {}
            return
        }
        guard s.estado == .transmitindo, !encerrandoTudo else { return }
        // D2, a queda: se a conexão da dona do som caiu, o som espera o aparelho dela por 10 s
        // (decisão do Pessoa Exemplo de 18/09); nas outras saídas, ele passa na remoção, como antes.
        if case .caiu = motivo {
            let antes = donoDoSom.dono
            donoDoSom.caiu(s.id, agoraMs: Emissor.agoraMs())
            aplicarDonoDoSom(antes, porque: "a conexão da sessão #\(s.id) caiu")
            if donoDoSom.carencia != nil { agendarOFimDaCarencia() }
        }
        let quem = s.par.nome.isEmpty ? T("O outro aparelho") : s.par.nome
        switch motivo {
        case .saiu: conselho = T("%@ saiu.", quem)
        case .caiu: conselho = T("A conexão com %@ caiu.", quem)
        case .capturaParou(let erro): conselho = T("A captura parou sozinha: %@", erro.localizedDescription)
        case .capturaNaoIniciou(let erro): conselho = T("Não consegui iniciar a captura: %@", erro.localizedDescription)
        }
        let restam = sessoes.contains { $0 !== s && ($0.estado == .transmitindo || $0.estado == .esperando) }
        #if QUALL_TELA_ESTENDIDA_FUTURA
        let estendida = fonteDaRodada?.modoDaTelaEstendida != nil
        #else
        let estendida = false
        #endif
        if dono != nil {
            // **A câmera é da espera**: o receptor saiu, a transmissão se solta do dono, a sessão
            // desmonta, e a espera volta com o mesmo PIN — sem fechar a câmera nem a gravação.
            let deNovo = T("Esperando de novo com o mesmo PIN.")
            conselho = conselho.hasSuffix(deNovo) ? conselho : conselho + " " + deNovo
            let porta = s.porta, pin = s.pin
            s.registrar("APP CAMERA transmissão solta do dono (\(conselho)) — a espera volta com o mesmo PIN")
            encerrar(s) { [weak self] in
                guard let self, !self.encerrandoTudo, self.dono != nil, self.espera() == nil else { return }
                self.abrirEspera(porta: porta, pin: pin)
            }
        } else if restam && estendida {
            encerrar(s)
        } else {
            encerrar()
        }
    }

    // MARK: - encerrar

    /// Desconecta **um** receptor (a linha dele na tela de espera). O monitor dele sai junto.
    func desconectar(_ id: Int) {
        guard let s = sessoes.first(where: { $0.id == id }), s.estado == .transmitindo else { return }
        s.registrar("desconectado pela pessoa")
        encerrar(s)
    }

    private func encerrar(_ s: SessaoDeEmissao, depois: (() -> Void)? = nil) {
        let indice = s.indiceDoMonitor
        if let indice { monitoresSaindo.insert(indice) }
        s.encerrar { [weak self] in
            guard let self else { return }
            if let indice { self.monitoresSaindo.remove(indice) }
            self.remover(s)
            depois?()
            self.depoisDeUmaSair()
        }
        publicar()
    }

    private func depoisDeUmaSair() {
        guard !encerrandoTudo, fase != .inicial else { return }
        if vivas().isEmpty && espera() == nil && !sessoes.contains(where: { $0.estado == .encerrando }) {
            voltarAoInicio()
            return
        }
        // Tinha batido no limite de monitores: com uma vaga aberta, a espera volta.
    #if QUALL_TELA_ESTENDIDA_FUTURA
        if fonteDaRodada?.modoDaTelaEstendida != nil, espera() == nil,
           vivas().count < Emissor.limiteDeMonitores {
            abrirEspera()
        }
    #endif
        publicar()
    }

    /// O Cancelar/Parar da tela de espera. **Funciona de verdade**, que aqui significa: todas as
    /// capturas param (o indicador de gravação do sistema apaga), as esperas bloqueadas destravam,
    /// o anúncio mDNS sai do ar, os monitores saem, e a tela volta ao começo.
    func encerrar() {
        guard fase == .esperando || fase == .transmitindo else { return }
        encerrandoTudo = true
        fase = .encerrando

        trava.lock()
        let geradorDeTom = tom
        tom = nil
        trava.unlock()
        // O tom para **junto** das capturas: um tom tocando depois de a sessão cair é um som na
        // bancada sem nada do outro lado para ouvi-lo.
        geradorDeTom?.parar()
        anunciar(porta: nil, fonte: nil)

        let todas = sessoes
        guard !todas.isEmpty else {
            voltarAoInicio()
            return
        }
        var faltam = todas.count
        for s in todas {
            let indice = s.indiceDoMonitor
            if let indice { monitoresSaindo.insert(indice) }
            s.encerrar { [weak self] in
                faltam -= 1
                if let indice { self?.monitoresSaindo.remove(indice) }
                self?.remover(s)
                if faltam == 0 { self?.voltarAoInicio() }
            }
        }
    }

    private func remover(_ s: SessaoDeEmissao) {
        sessoes.removeAll { $0 === s }
        let antes = donoDoSom.dono
        donoDoSom.saiu(s.id)
        aplicarDonoDoSom(antes, porque: "o dono #\(s.id) saiu")
        // O cinto do Parar: com tudo desmontado, a tela volta — venha o último aviso de onde vier.
        if encerrandoTudo && sessoes.isEmpty { voltarAoInicio() }
    }

    /// D2 do `docs/som-no-receptor.md` §12.1: quem toca o som na tela estendida. A passagem ao
    /// próximo liga e desliga por `--sem-passar-som` (ver `DonoDoSom`).
    private lazy var donoDoSom = DonoDoSom(passar: !argumentos.semPassarSom)

    /// Leva às sessões a troca de dono, se houve. `antes` é o dono de antes do aviso.
    private func aplicarDonoDoSom(_ antes: Int?, porque motivo: String) {
        let agora = donoDoSom.dono
        guard agora != antes else { return }
        for s in sessoes { s.tocaSom = s.id == agora }
        if let id = agora {
            let nome = sessoes.first { $0.id == id }.map { $0.par.nome.isEmpty ? "outro aparelho" : $0.par.nome } ?? "?"
            Registro.compartilhado.linha("som: a sessão #\(id) passa a tocar — \(motivo)")
        } else {
            let porque: String
            if let c = donoDoSom.carencia {
                porque = " (o som espera \(c.aparelho) voltar por 10 s)"
            } else {
                porque = donoDoSom.passar ? " (não sobrou receptor que toque)" : " (a passagem está desligada)"
            }
            Registro.compartilhado.linha("som: ninguém toca agora — \(motivo)\(porque)")
        }
        publicar()
    }

    /// M3 do Mac (crítica 15): a sessão cujo som falha sozinha — a captura de som dela para enquanto
    /// a de outra traz som, ou a track dela recusa tudo — deixa de ser dona e candidata, e o som
    /// passa na hora. Roda a cada relato de qualquer sessão (um por segundo por sessão).
    private var vigiaDoSom = VigiaDoSomDasSessoes()

    private func vigiarOSom() {
        let leituras = vivas().filter(\.comAudio).compactMap(\.leituraDoSom)
        let veredito = vigiaDoSom.observar(leituras, agoraMs: Emissor.agoraMs())
        for falta in veredito.faltas {
            let antes = donoDoSom.dono
            donoDoSom.naoToca(falta.id)
            sessoes.first { $0.id == falta.id }?
                .registrar("som: esta sessão ficou sem som — \(falta.motivo); não é dona nem candidata enquanto isso")
            aplicarDonoDoSom(antes, porque: "a sessão #\(falta.id) ficou sem som")
        }
        // A captura dela voltou a trazer som (crítica 18, F2): candidata de novo, sem tomar o som.
        for id in veredito.voltas {
            guard let s = sessoes.first(where: { $0.id == id }) else { continue }
            let antes = donoDoSom.dono
            donoDoSom.voltouOSom(id, toca: QuemTocaOSomDoMac.tocaPCMU(deviceId: s.par.deviceId))
            s.registrar("som: a captura desta sessão voltou a trazer som; candidata de novo")
            aplicarDonoDoSom(antes, porque: "o som da sessão #\(id) voltou, e ninguém tocava")
        }
    }

    /// Vence a carência do dono que caiu no fim do prazo (e um pouco depois, para o relógio
    /// passar do limite). Uma volta antes disso já a desfez, e aí o tique não muda nada.
    private func agendarOFimDaCarencia() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(DonoDoSom.carenciaDoDonoMs) + 50)) { [weak self] in
            guard let self, !self.encerrandoTudo else { return }
            let antes = self.donoDoSom.dono
            self.donoDoSom.tique(agoraMs: Emissor.agoraMs())
            self.aplicarDonoDoSom(antes, porque: "a carência de 10 s do dono que caiu acabou")
        }
    }

    /// O relógio da carência: monotônico, em ms.
    private static func agoraMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func vivas() -> [SessaoDeEmissao] { sessoes.filter { $0.estado == .transmitindo } }
    private func espera() -> SessaoDeEmissao? { sessoes.first { $0.estado == .esperando } }

    /// O estado que a interface lê, derivado das sessões. Só na main.
    private func publicar() {
        guard !encerrandoTudo, fase != .inicial || !sessoes.isEmpty else { return }
        let noAr = vivas()
        let aberta = espera()
        if !noAr.isEmpty {
            fase = .transmitindo
        } else if aberta != nil {
            fase = .esperando
        }
        pin = aberta?.pin ?? ""
        enderecoParaDigitar = aberta?.endereco ?? noAr.first?.endereco
        esperandoMaisUm = !noAr.isEmpty && aberta != nil
        par = noAr.map { $0.par.nome.isEmpty ? T("outro aparelho") : $0.par.nome }.joined(separator: ", ")
        receptores = noAr.map {
            ReceptorAtivo(id: $0.id, nome: $0.par.nome.isEmpty ? T("outro aparelho") : $0.par.nome,
                          monitor: $0.descricaoDoMonitor, resumo: $0.resumo)
        }
        resumoDaTransmissao = noAr.count == 1 ? noAr[0].resumo : ""
        resumoDoAudio = noAr.first(where: { $0.tocaSom })?.resumoDoAudio ?? ""
    }

    private func voltarAoInicio() {
        fecharODono(motivo: "o espelhamento da câmera parou")
        donoDoSom.zerar()
        vigiaDoSom.zerar()
        fase = .inicial
        encerrandoTudo = false
        sessoes.removeAll()
        proximoId = 1
        fonteDaRodada = nil
        // O anúncio sai **aqui também**: uma espera que falhou sem ninguém no ar deixava o Mac na
        // lista dos outros apontando para uma porta morta (revisão de 10/09/2026). O código de antes
        // parava o anúncio assim que `quall_host` voltava, com sucesso ou não.
        anunciar(porta: nil, fonte: nil)
        pin = ""
        par = ""
        enderecoParaDigitar = nil
        anunciandoPorMDNS = false
        resumoDaTransmissao = ""
        resumoDoAudio = ""
        receptores = []
        esperandoMaisUm = false
        trava.lock()
        let geradorDeTom = tom
        tom = nil
        trava.unlock()
        geradorDeTom?.parar()
        haParesConhecidos = Identidade.haParesConhecidos()
    }

    /// Só oferecido quando a retomada de fato falhou (`QUALL_STATUS_NEEDS_PIN`). Ver a dívida 22 e
    /// o comentário de `Identidade.esquecerTodosOsPares`.
    func esquecerPares() {
        Identidade.esquecerTodosOsPares()
        haParesConhecidos = false
        ofereceDesparear = false
        conselho = T("Pareamentos esquecidos. Da próxima vez o PIN será pedido.")
    }
}
