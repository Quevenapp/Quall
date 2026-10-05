// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import AppKit
import CryptoKit
import Foundation
import QuallIdiomaKit
import QuallNetKit
import QuallTeleprompterKit
import SwiftUI

/// **O teleprompter do Mac, nos dois papéis** (`docs/contrato-teleprompter.md`).
///
/// Decisões do usuário que valem aqui (13/09): todo aparelho faz os dois papéis — este Mac mostra
/// o texto (o notebook atrás do vidro) ou controla outro aparelho; o texto se edita dos dois lados
/// e vale o último que mudou (a fusão é do núcleo: esta classe só edita, bombeia e lê); e se o
/// controle cai, o prompter continua como estava, com aviso visível nas duas telas.
///
/// # Threads
///
/// O mesmo desenho do `Emissor` e do `Receptor`, com uma diferença que conserta um precedente:
///
/// - **a `Thread` do laço é dona exclusiva da sessão** (`FronteiraDoTeleprompter`): hospedar ou
///   conectar, bombear, `next_event`, `peer_lost` e fechar saem todos dela. A main só levanta a
///   bandeira e aciona o cancelador (`pedirParada`), e nunca toca num ponteiro de sessão;
/// - **as edições saem da main**, direto na réplica (`ReplicaDoTeleprompter`), que o núcleo
///   protege com um cadeado e manda na hora — um "pausar" não espera a bombeada;
/// - tudo o que a tela lê é `@Published` e só muda na main.
///
/// # Uma réplica por papel, pelo processo inteiro
///
/// O contrato manda criar a réplica ao abrir o app "e passar a mesma a cada sessão nova" (§3). Aqui
/// são duas — a do prompter e a do controle —, criadas na primeira vez que cada tela abre e
/// guardadas até o app fechar, cada uma com o seu arquivo salvo. Um arquivo só para os dois papéis
/// faria o espelho e a fonte que este Mac usou **como prompter** vencerem, pelo carimbo mais novo,
/// no iPhone que ele passasse a **controlar** (revisão adversarial de 13/09).
final class Teleprompter: ObservableObject, @unchecked Sendable {

    enum Tela: Equatable { case fechada, prompter, controle }

    /// Em que pé está a ligação, para a tela.
    enum Fase: Equatable {
        /// Controle: o formulário (lista e endereço). Prompter: a espera parou (erro que precisa
        /// da pessoa, ou ela desistiu) — o painel oferece "Esperar de novo".
        case formulario
        /// Prompter: esperando o controle, com o PIN na tela. Controle: conectando.
        case abrindo
        case conectado
        /// Houve sessão e ela caiu: o prompter espera a volta (rolando como estava); o controle
        /// tenta de novo a cada ~1 s.
        case semPar
        case encerrando
    }

    // MARK: - o que a interface lê (só muda na main)

    @Published private(set) var tela: Tela = .fechada
    /// **A tela do prompter com a câmera** (R5, `docs/teleprompter-com-camera.md` §8.9): a mesma tela
    /// `.prompter`, com a mesma réplica e a mesma sessão na 7979 — então o prompter comum e o R5 nunca
    /// abrem juntos (um prompter por aparelho, §2.5) —, mais as peças da câmera (`camera`).
    @Published private(set) var comCamera = false
    /// As peças da câmera (dono, espera, gravador), enquanto a tela R5 estiver aberta.
    @Published private(set) var camera: TelaComCamera?
    /// **M4**: o controle numa janela própria, ao lado do receptor na janela principal (§12). A raiz
    /// da janela principal não mostra o controle quando isto está ligado.
    @Published var controleEmJanela = false
    /// O recado do botão Gravar do controle (§13.8): `PROTOCOL`, `CLOSED`, a recusa do prompter.
    @Published private(set) var recadoDaGravacao = ""
    @Published private(set) var fase: Fase = .formulario
    @Published private(set) var estado = EstadoDoTeleprompter()
    @Published private(set) var texto = ""
    @Published private(set) var avisos = AvisosDaTela()
    @Published private(set) var pin = ""
    /// Prompter: o `ip:porta` para digitar no controle. Controle: o endereço em que está ligado.
    @Published private(set) var endereco: String?
    @Published private(set) var par = ""
    @Published private(set) var mensagem = ""
    @Published private(set) var anunciandoPorMDNS = false
    @Published private(set) var prompters: [PrompterAchado] = []
    /// O navegador do mDNS está pedido (o "procurando" do formulário do controle): liga com a lista,
    /// desliga ao conectar e ao fechar a tela.
    @Published private(set) var procurando = false
    @Published private(set) var tentativas = 0
    @Published private(set) var jaHouveSessao = false
    @Published private(set) var ocioso = true
    @Published private(set) var emTelaCheia = false
    @Published var mostrarPainelDoPin = true

    @Published var enderecoDigitado = ""
    @Published var pinDigitado = ""

    @Published var editorAberto = false
    @Published var rascunho = RascunhoDoTexto(textoAtual: "")

    /// A "Fonte automática" do prompter (`docs/teleprompter-ajustes-locais.md` §5): ajuste **local**,
    /// guardado nas preferências deste Mac (na bancada, `--dados`, só na memória). Ligada, a vista
    /// escolhe a fonte; uma fonte mudada à mão ou pelo controle a desliga.
    @Published var fonteAutomatica = false {
        didSet {
            guard fonteAutomatica != oldValue else { return }
            vista?.fonteAutomatica = fonteAutomatica
            if argumentos.dados == nil { UserDefaults.standard.set(fonteAutomatica, forKey: Teleprompter.chaveDaFonteAutomatica) }
            registrar("fonte automática: \(fonteAutomatica ? "ligada" : "desligada")")
        }
    }
    /// O aviso de que o controle desligou a fonte automática, por alguns segundos.
    @Published private(set) var avisoDaFonte = ""
    @Published private(set) var mensagemDoEditor = ""

    /// O **"Segurar para rolar"** do controle (`docs/contrato-teleprompter.md` §12.5): ajuste
    /// **local**, guardado nas preferências deste Mac (na bancada, `--dados`, só na memória).
    /// Ligado, a tela do controle fica só com os dois botões grandes.
    @Published var segurarParaRolar = false {
        didSet {
            guard segurarParaRolar != oldValue else { return }
            if !segurarParaRolar { sairDoModoSegurar() }
            if argumentos.dados == nil { UserDefaults.standard.set(segurarParaRolar, forKey: Teleprompter.chaveDoSegurar) }
            registrar("segurar para rolar: modo \(segurarParaRolar ? "ligado" : "desligado")")
        }
    }
    /// Os apertos de pé, o `hold` aceito e o "o texto parou" (a regra, pura, em `SegurarParaRolar`).
    @Published private(set) var segurar = SegurarParaRolar()
    /// O núcleo recusou o `hold` com `PROTOCOL` nesta sessão: o prompter não entende.
    @Published private(set) var recusouOSegurarPorProtocolo = false
    /// O núcleo recusou o `hold` com `CLOSED`: a sessão acabou, mesmo que o laço ainda não tenha dado
    /// o par por perdido — a tela diz "sem conexão" (§12.5, revisão de 14/09) até a sessão seguinte.
    @Published private(set) var recusouOSegurarPorSessaoFechada = false
    private var ultimaDisponibilidadeDoSegurar: DisponibilidadeDoSegurar?
    /// As vistas dos dois botões, registradas por elas ao nascer: a bancada aperta por elas.
    private var vistasDoSegurar: [BotaoDeSegurar: ReferenciaFraca<VistaDoBotaoDeSegurar>] = [:]

    // MARK: a pergunta do texto e os roteiros guardados (o controle, §11.7)

    /// O status da última escolha que não passou, enquanto vale: `.fechado` (o prompter não está
    /// conectado) ou `.ocupado` (o roteiro dele mudou). Some quando a pergunta fecha, quando uma
    /// sessão nova sobe e na escolha seguinte.
    @Published private(set) var recusaDaEscolha: StatusDaFronteira?
    /// Palavras de cada texto que a tela mostra, pelo resumo — contadas **no texto inteiro** (o da
    /// pergunta por `question_text`, o daqui por `text`, as cópias por `text_copy`), uma vez por
    /// resumo.
    @Published private(set) var palavras: [String: Int] = [:]
    /// A folha "Roteiros guardados" aberta pela pessoa.
    @Published var roteirosAbertos = false
    /// "Ver": a cópia aberta, só leitura.
    @Published private(set) var copiaVista: CopiaVista?
    /// O alerta de "Usar este" ou "Apagar", esperando a pessoa.
    @Published private(set) var confirmacaoDaCopia: ConfirmacaoDaCopia?
    /// Bancada (`escolha=`): a resposta armada para quando a pergunta abrir.
    private var escolhaArmada: Bool?
    private var ultimaCaixaRegistrada: CaixaDaPergunta = .nenhuma
    private var escolhendoPorta = false

    let nome = Identidade.nomeDoAparelho
    private let argumentos = Argumentos.lidos()
    static weak var atual: Teleprompter?
    static var tetoDoTexto: Int { PonteDoTeleprompter.tetoDoTexto }

    // MARK: - estado da main

    private var replicas: [PapelDoTeleprompter: ReplicaDoTeleprompter] = [:]
    private var replica: ReplicaDoTeleprompter?
    private var fronteira: FronteiraDoTeleprompter?
    private var lacoRodando = false
    private var ligacao: LigacaoDaTela = .semSessao
    private var fecharAoTerminar = false
    private var relogioDeEstado: Timer?
    private var ultimoRegistroDeEstado = 0.0
    private var anunciosPendentes = 0
    private var portaDoPrompter: UInt16 = 0
    private var acoesAgendadas: [DispatchSourceTimer] = []
    private var envioLimitado: [String: (quando: Double, pendente: DispatchWorkItem?)] = [:]
    private var observadores: [NSObjectProtocol] = []
    private var salvoAgendado: DispatchWorkItem?

    private let anunciante = Anunciante()
    private let filaDoAnuncio = DispatchQueue(label: "quall.teleprompter.anuncio")
    private let filaDoSalvo = DispatchQueue(label: "quall.teleprompter.salvo")
    private let navegador = NavegadorDePrompters()
    private let telaAcesa = TelaAcesa()
    private let atalhos = AtalhosDoTeleprompter()

    /// A vista do texto do prompter, registrada por ela mesma ao nascer.
    weak var vista: VistaDoTexto?

    // MARK: - o salto que ainda não chegou à vista
    //
    // **O relato de posição não pode passar na frente de um salto remoto** (revisão adversarial de
    // 13/09). O núcleo põe a posição no alvo ao fundir o salto, dentro da bombeada; a vista só vai
    // até lá quando a main aplica o bit. Um `set_position` com o deslocamento antigo nesse meio
    // recarimbaria a posição velha, e o `jump_by` seguinte do controle partiria dela — o defeito 3
    // da revisão de 13/09 de volta. Então a thread do laço conta os saltos que viu **antes** de
    // mandar o aviso para a main, e a vista não relata posição enquanto a main não aplicou todos.
    private let travaDosSaltos = NSLock()
    private var saltosVistos = 0
    private var saltosAplicados = 0

    // MARK: - início

    init() {
        Teleprompter.atual = self
        if argumentos.dados == nil {
            fonteAutomatica = UserDefaults.standard.bool(forKey: Teleprompter.chaveDaFonteAutomatica)
            segurarParaRolar = UserDefaults.standard.bool(forKey: Teleprompter.chaveDoSegurar)
            segurar = SegurarParaRolar(invertido: UserDefaults.standard.bool(forKey: Teleprompter.chaveDaInversao))
        }
        observadores.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.soltarTudoDoSegurar(porque: "o app vai fechar")
            self?.salvarTudoAgora()
        })
        // "Quando o app vai para o segundo plano" (§3): no Mac, quando ele perde o foco — com um
        // atraso, para não gravar 260 KB a cada troca de janela.
        observadores.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.perdeuOFoco(porque: "o app foi para o segundo plano")
            self?.agendarSalvo(em: 2)
        })
        // O segurar solta **ao perder o foco da janela** (§12.5): o `mouseUp` ou o `keyUp` de um
        // botão seguro podem nunca chegar a esta janela.
        observadores.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.perdeuOFoco(porque: "a janela perdeu o foco")
        })
        // Um menu aberto (a barra de menus, um menu de contexto) roda o laço de eventos dele: o
        // `keyUp` da seta segurada pode ir para o menu e nunca chegar aqui, sem a janela perder o
        // foco (revisão de 14/09). Soltar ao abrir é o lado seguro.
        observadores.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.perdeuOFoco(porque: "um menu abriu")
        })
        for nome in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observadores.append(NotificationCenter.default.addObserver(
                forName: nome, object: nil, queue: .main) { [weak self] n in
                let janela = n.object as? NSWindow
                let cheia = janela?.styleMask.contains(.fullScreen) ?? false
                self?.emTelaCheia = cheia
                self?.registrar("tela cheia: \(cheia ? "entrou" : "saiu") — "
                                + "\(Int(janela?.frame.width ?? 0))x\(Int(janela?.frame.height ?? 0)) pt")
            })
        }

        // Aberto direto no teleprompter, **a primeira tela que a janela mostra é a dele**: a tela
        // é marcada aqui, antes do primeiro desenho, e a sessão sobe na volta seguinte da main. Com
        // o `asyncAfter` de antes, a tela inicial aparecia por 0,3 s e o `onAppear` dela montava o
        // catálogo de fontes — pedindo Gravação de Tela e Câmera para mostrar um roteiro (medido
        // na primeira corrida de bancada, 13/09).
        switch argumentos.teleprompter {
        case "prompter":
            tela = .prompter
            DispatchQueue.main.async { [weak self] in self?.abrirPrompter(naPartida: true) }
        case "prompter-camera":
            // A tela R5 direto: a câmera abre com a tela, independente da sessão (G1).
            tela = .prompter
            comCamera = true
            let c = TelaComCamera(teleprompter: self, argumentos: argumentos)
            camera = c
            DispatchQueue.main.async { [weak self] in
                self?.abrirPrompter(naPartida: true)
                guard self?.tela == .prompter else {
                    self?.comCamera = false
                    self?.camera = nil
                    return
                }
                c.abrir()
            }
        case "controle":
            tela = .controle
            controleEmJanela = argumentos.controleEmJanela
            DispatchQueue.main.async { [weak self] in self?.abrirControle(naPartida: true) }
        case nil:
            break
        case let outro?:
            registrar("!! --teleprompter não é prompter nem controle")
        }
    }

    private func registrar(_ linha: String) {
        Registro.compartilhado.linha("teleprompter: " + linha)
    }

    private static func agora() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - a tela com câmera (R5)

    /// O espelho do texto estava ligado ao abrir a tela R5 (ela o desliga, §2.5), e ninguém mexeu nele
    /// durante a tela: ao sair, volta.
    private var espelhoAntesDaCamera = false
    private var espelhoMexidoNaCamera = false

    /// Abre a tela R5: a do prompter, com a câmera. A câmera abre **com a tela** (G1), e a sessão do
    /// prompter sobe como sempre.
    func abrirPrompterComCamera() {
        guard tela == .fechada, ocioso, !escolhendoPorta else { return }
        comCamera = true
        let c = TelaComCamera(teleprompter: self, argumentos: argumentos)
        camera = c
        abrirPrompter()
        guard tela == .prompter else {
            comCamera = false
            camera = nil
            return
        }
        c.abrir()
    }

    /// **M4**: o controle na janela própria, com o receptor (ou o que for) na principal.
    func abrirControleEmJanela() {
        guard tela == .fechada, ocioso else { return }
        controleEmJanela = true
        abrirControle()
        if tela != .controle { controleEmJanela = false }
    }

    /// A tela foi aberta pela bancada: o menu de microfones some (na bancada, só `--microfone=`).
    var argumentosDeBancada: Bool { argumentos.microfoneNaRegraDaBancada }

    /// A réplica do prompter (a mesma da tela comum), para a gravação dizer ao controle que grava.
    func replicaDoPrompter() -> ReplicaDoTeleprompter? { replicaPara(.prompter) }

    // MARK: - o controle pede a gravação (§13.8)

    /// O botão Gravar/Parar do controle: `request_record` / `request_stop`. O recado diz o que a
    /// fronteira respondeu quando não foi `OK`.
    func pedirGravacao(_ gravar: Bool) {
        guard tela == .controle, let replica else { return }
        let st = gravar ? replica.pedirGravar() : replica.pedirParar()
        registrar("gravação: \(gravar ? "pedir_gravar" : "pedir_parar") → \(st.nome)")
        switch st {
        case .ok: recadoDaGravacao = ""
        case .protocolo: recadoDaGravacao = T("O prompter não grava (atualize o app, ou abra a tela com câmera).")
        case .fechado: recadoDaGravacao = T("Sem conexão com o prompter.")
        default: recadoDaGravacao = T("O pedido não saiu: %@.", st.nome)
        }
        atualizarEstado()
    }

    /// Os primeiros 8 bytes do SHA-256 do texto, em hex — o mesmo `resumo` do núcleo
    /// (`teleprompter::resumo`) e o que a `quall-probe` imprime: é por ele que a bancada confere que
    /// um roteiro de 100 KB atravessou inteiro, sem abrir o texto no registro.
    static func resumo(_ texto: String) -> String {
        SHA256.hash(data: Data(texto.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - abrir e fechar as telas

    /// **O prompter**: hospeda com o papel `teleprompter`, anuncia, mostra PIN e endereço, e segura a
    /// tela acesa enquanto estiver aberto.
    func abrirPrompter(naPartida: Bool = false) {
        guard !escolhendoPorta,
              (tela == .fechada && ocioso) || (naPartida && tela == .prompter && replica == nil) else { return }
        guard let r = replicaPara(.prompter) else {
            tela = .fechada
            mensagem = T("Não consegui criar o teleprompter: %@", PonteDoTeleprompter.ultimoErro())
            return
        }
        if let porta = argumentos.porta {
            abrirPrompter(r, naPorta: porta, comoEscolhida: "a de --porta")
            return
        }
        // **A porta do teleprompter** (§11.1): `quall_teleprompter_pick_port(2000)` — a 7979,
        // esperando por ela até 2 s; senão 7980…7988; senão uma efêmera. Uma vez por tela, e a mesma
        // a vida inteira dela (a volta depois de uma queda hospeda de novo nela). A espera bloqueia:
        // fora da main, com a tela já aberta em "esperando".
        escolhendoPorta = true
        tela = .prompter
        fase = .abrindo
        mensagem = ""
        // O PIN e o endereço da abertura anterior não ficam no painel enquanto a porta é
        // escolhida (até 2 s) (revisão de 14/09).
        pin = ""
        endereco = nil
        recalcularOcioso()
        let inicio = Teleprompter.agora()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let porta = PonteDoTeleprompter.escolherPortaDoPrompter(esperaMs: 2_000)
            DispatchQueue.main.async {
                guard let self else { return }
                self.escolhendoPorta = false
                // A pessoa saiu enquanto a porta era escolhida: nada a abrir.
                guard self.tela == .prompter, self.replica == nil else {
                    self.recalcularOcioso()
                    return
                }
                let ms = Int((Teleprompter.agora() - inicio) * 1000)
                self.abrirPrompter(r, naPorta: porta,
                                   comoEscolhida: "quall_teleprompter_pick_port(2000), em \(ms) ms"
                                       + (porta == PonteDoTeleprompter.portaDoTeleprompter ? "" : " — a 7979 estava ocupada"))
            }
        }
    }

    private func abrirPrompter(_ r: ReplicaDoTeleprompter, naPorta porta: UInt16, comoEscolhida: String) {
        registrar("prompter: porta \(porta) (\(comoEscolhida))")
        guard porta != 0 else {
            if comCamera {
                // A câmera da tela R5 não fica aberta sem tela (a revisão de 25/09).
                camera?.fechar(motivo: "sem porta para o prompter")
                comCamera = false
                camera = nil
            }
            tela = .fechada
            fase = .formulario
            mensagem = T("Não consegui reservar uma porta de rede neste Mac.")
            registrar("!! sem porta livre")
            recalcularOcioso()
            return
        }
        replica = r
        // **Esta tela rola para trás** com `rolando` e `para_tras`, para no começo sem mudar
        // `rolando`, e para quando `rolando` cai (`VistaDoTexto.passo`): só por isso ela diz que
        // entende o "segurar para rolar" (§12.2). A réplica é a mesma pelo processo: ligar de novo
        // a cada abertura não muda nada.
        let segurar = r.ligarSegurar()
        registrar("segurar para rolar: enable_hold=\(segurar.nome) (a vista rola para trás e para quando rolando cai)")
        portaDoPrompter = porta
        tela = .prompter
        prepararTela()
        if comCamera {
            // **O espelho do texto nasce desligado** na tela R5 (§2.5): o texto é lido direto na tela,
            // não pelo vidro. O controle remoto pode ligá-lo. Volta ao sair, se ninguém mexeu.
            espelhoAntesDaCamera = estado.espelho
            espelhoMexidoNaCamera = false
            if estado.espelho { editar("espelho=false (tela com câmera)") { $0.definirEspelho(false) } }
            vista?.marcasNoPe = true
            registrar("tela com câmera: o espelho do texto desligado ao abrir (estava \(espelhoAntesDaCamera ? "ligado" : "desligado"))")
        }
        endereco = Enderecos.paraDigitar(porta: porta)
        mostrarPainelDoPin = true

        let acesa = telaAcesa.ligar()
        registrar("tela acesa: IOPMAssertionCreateWithName=\(acesa) (\(acesa == 0 ? "ligada" : "FALHOU")) "
                  + "nome=\"\(TelaAcesa.nome)\"")
        if argumentos.semMdns {
            registrar("mdns: desligado (--sem-mdns)")
        } else {
            anunciar(porta: porta)
        }
        esperarPeloControle(pin: argumentos.pin ?? NucleoDeRede.sortearPin())
        if argumentos.telaCheia {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.alternarTelaCheia(ligar: true) }
        }
    }

    /// Prompter: abre (ou reabre) a espera, na porta da tela.
    func esperarPeloControle(pin novo: String? = nil) {
        guard tela == .prompter, !lacoRodando else { return }
        let pinDaEspera = novo ?? NucleoDeRede.sortearPin()
        pin = pinDaEspera
        mensagem = ""
        fase = jaHouveSessao ? .semPar : .abrindo
        let config = FronteiraDoTeleprompter.Configuracao(
            deviceId: Identidade.deviceId, nome: nome, porta: portaDoPrompter,
            // Uma espera longa, e renovada com o mesmo PIN quando estoura sem erro de PIN (§6).
            prazoMs: 5 * 60 * 1000)
        registrar("prompter: esperando o controle porta=\(portaDoPrompter) rede_disponivel=\(endereco != nil) PIN presente=true")
        iniciarLaco(.prompter, config, pin: pinDaEspera)
    }

    /// **O controle**: a lista do mDNS e o formulário.
    func abrirControle(naPartida: Bool = false) {
        guard (tela == .fechada && ocioso) || (naPartida && tela == .controle && replica == nil) else { return }
        guard let r = replicaPara(.controle) else {
            tela = .fechada
            mensagem = T("Não consegui criar o controle: %@", PonteDoTeleprompter.ultimoErro())
            return
        }
        replica = r
        tela = .controle
        prepararTela()
        fase = .formulario
        if enderecoDigitado.isEmpty { enderecoDigitado = ultimoEndereco }
        comecarNavegador()
        if let alvo = argumentos.prompter {
            enderecoDigitado = alvo
            // M4 (`--controle-em-janela` com `--exibir`): o `--pin` é do receptor de vídeo, e o do
            // prompter vem em `--pin-do-prompter`.
            pinDigitado = argumentos.pinDoPrompter ?? argumentos.pin ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.registrar("bancada: conectando sem esperar o dedo de ninguém")
                self?.conectar()
            }
        }
    }

    private func prepararTela() {
        ligacao = .semSessao
        jaHouveSessao = false
        mensagem = ""
        par = ""
        tentativas = 0
        texto = replica?.texto() ?? ""
        atualizarEstado()
        // Aberto pela bancada (`--teleprompter=prompter`), a vista nasce no primeiro desenho, antes
        // desta volta da main, e se registrou com o texto vazio e o estado padrão: o roteiro salvo
        // ficava na réplica e fora da tela — "0 linhas", o controle vendo 0 % para sempre e o salto
        // da volta perdido (medido em 14/09, Mac prompter reaberto com o A07 controlando).
        if tela == .prompter, let v = vista {
            v.trocarTexto(texto)
            v.aplicar(estado: estado)
        }
        relogioDeEstado?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.aCadaQuarto() }
        RunLoop.main.add(t, forMode: .common)
        relogioDeEstado = t
        atalhos.ligar({ [weak self] acao in self?.tratar(acao) ?? false },
                      segurar: { [weak self] botao, desce, repeticao in
                          self?.teclaDoSegurar(botao, desce: desce, repeticao: repeticao) ?? false
                      })
        // Os apertos recomeçam; a inversão é ajuste do aparelho e fica.
        segurar = SegurarParaRolar(invertido: segurar.invertido)
        recusouOSegurarPorProtocolo = false
        recusouOSegurarPorSessaoFechada = false
        ultimaDisponibilidadeDoSegurar = nil
        recusaDaEscolha = nil
        escolhaArmada = nil
        ultimaCaixaRegistrada = .nenhuma
        copiaVista = nil
        confirmacaoDaCopia = nil
        recalcularOcioso()
        registrar("tela \(tela == .prompter ? "do prompter" : "do controle") aberta: texto=\(texto.utf8.count) bytes")
        if let caminho = argumentos.teleprompterTexto {
            let absoluto = (caminho as NSString).expandingTildeInPath
            if let t = try? String(contentsOfFile: absoluto, encoding: .utf8) {
                registrar("bancada: roteiro lido (\(t.utf8.count) bytes)")
                _ = aplicarTextoLocal(t)
            } else {
                registrar("!! --teleprompter-texto: não consegui ler (use caminho absoluto)")
            }
        }
        agendarAcoesDeBancada()
    }

    /// Controle: conecta no prompter escolhido da lista, ou no endereço digitado.
    func conectar(a achado: PrompterAchado? = nil) {
        guard tela == .controle, fase == .formulario, !lacoRodando else { return }
        guard let alvo = EnderecoDoPrompter.ler(achado?.endpoint ?? enderecoDigitado) else {
            mensagem = T("Digite o endereço que a tela do prompter mostra (por exemplo 192.168.56.20:7979).")
            return
        }
        let digitado = pinDigitado.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinUsado = alvo.pin ?? (digitado.isEmpty ? nil : digitado)
        if achado == nil { enderecoDigitado = alvo.endereco }
        endereco = alvo.endereco
        mensagem = ""
        // Conectar pelo formulário é começar de novo, talvez noutro prompter: sem isto, a pergunta
        // aberta com o prompter anterior (ela fica na réplica depois da queda) apareceria como
        // "O prompter <anterior> tem outro roteiro." até a primeira bombeada do novo (revisão de 14/09).
        jaHouveSessao = false
        ligacao = .semSessao
        fase = .abrindo
        navegador.parar()
        procurando = false
        let config = FronteiraDoTeleprompter.Configuracao(
            deviceId: Identidade.deviceId, nome: nome, endereco: alvo.endereco, prazoMs: 15_000)
        registrar("controle: conectando " + (pinUsado == nil ? "sem PIN (par conhecido)" : "com PIN"))
        iniciarLaco(.controle, config, pin: pinUsado)
    }

    /// A frase de uma abertura que falhou (`abrirPrompter`, `abrirControle`) fica com a tela fechada
    /// até a próxima abertura; o X do aviso no painel Espelhar a dispensa antes disso.
    func dispensarMensagem() {
        guard tela == .fechada, !mensagem.isEmpty else { return }
        mensagem = ""
    }

    /// Controle: volta ao formulário (a sessão fecha; a tela fica).
    func desconectar() {
        guard tela == .controle else { return }
        // O soltar sai **antes** de a sessão fechar: o prompter para pelo soltar, e não pela queda.
        soltarTudoDoSegurar(porque: "desconectou")
        guard lacoRodando else { fase = .formulario; return }
        fase = .encerrando
        fronteira?.pedirParada()
    }

    /// Sai da tela do teleprompter (os dois papéis). A sessão fecha na ordem do contrato, e só
    /// então a tela volta.
    func sair() {
        guard tela != .fechada else { return }
        // A câmera fecha **primeiro**: a gravação para e o controle ouve `definirGravando(false)`
        // enquanto a sessão do prompter ainda está de pé (a revisão M1 do iOS, §8.7).
        camera?.fechar(motivo: "a tela com câmera fechou")
        soltarTudoDoSegurar(porque: "a tela vai fechar")
        fecharAoTerminar = true
        if lacoRodando {
            fase = .encerrando
            fronteira?.pedirParada()
            return
        }
        fecharTela()
    }

    private func fecharTela() {
        soltarTudoDoSegurar(porque: "a tela fechou")
        atalhos.desligar()
        relogioDeEstado?.invalidate()
        relogioDeEstado = nil
        acoesAgendadas.forEach { $0.cancel() }
        acoesAgendadas = []
        navegador.parar()
        procurando = false
        if tela == .prompter {
            telaAcesa.desligar()
            registrar("tela acesa: asserção solta")
            if !argumentos.semMdns { pararAnuncio() }
            if emTelaCheia { alternarTelaCheia(ligar: false) }
        }
        if comCamera {
            camera?.fechar(motivo: "a tela com câmera fechou")
            if espelhoAntesDaCamera, !espelhoMexidoNaCamera, !estado.espelho {
                editar("espelho=true (a tela com câmera fechou; volta como estava)") { $0.definirEspelho(true) }
            }
            vista?.marcasNoPe = false
            comCamera = false
            camera = nil
        }
        salvarAgora()
        editorAberto = false
        fecharAoTerminar = false
        tela = .fechada
        controleEmJanela = false
        fase = .formulario
        replica = nil
        mensagem = ""
        registrar("tela fechada")
        recalcularOcioso()
    }

    private func recalcularOcioso() {
        let agora = tela == .fechada && !lacoRodando && anunciosPendentes == 0 && !escolhendoPorta
        if agora != ocioso { ocioso = agora }
    }

    // MARK: - as réplicas e o salvo

    private func arquivoDoSalvo(_ papel: PapelDoTeleprompter) -> URL {
        Identidade.pasta.appendingPathComponent(papel == .prompter ? "teleprompter-prompter.json"
                                                                  : "teleprompter-controle.json")
    }

    /// A réplica do papel, criada na primeira vez a partir do salvo e guardada pelo processo.
    private func replicaPara(_ papel: PapelDoTeleprompter) -> ReplicaDoTeleprompter? {
        if let r = replicas[papel] { return r }
        let url = arquivoDoSalvo(papel)
        let salvo = try? String(contentsOf: url, encoding: .utf8)
        guard let r = ReplicaDoTeleprompter(autor: Identidade.deviceId, papel: papel, salvo: salvo) else {
            registrar("!! quall_teleprompter_new falhou: \(SanitizacaoDoLog.causaExterna(PonteDoTeleprompter.ultimoErro()))")
            return nil
        }
        if let recusa = r.salvoRecusado {
            // O ilegível é **guardado de lado**, e não sobrescrito pela primeira gravação: é o
            // roteiro de alguém.
            let deLado = url.deletingPathExtension()
                .appendingPathExtension("recusado-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: deLado)
            registrar("!! o salvo do \(papel.rawValue) foi recusado (\(SanitizacaoDoLog.causaExterna(recusa))); preservado de lado, "
                      + "e a réplica começa do padrão")
        }
        if papel == .controle {
            // **A trava da pergunta do texto** (§11.10), logo depois de criar a réplica, a cada vida do
            // app: esta build tem a caixa da pergunta (`CaixaDaPerguntaNaTela`) e os "Roteiros
            // guardados". No prompter, a trava não muda nada, e não se liga.
            let s = r.ligarPerguntaDoTexto()
            registrar("pergunta do texto: enable_text_question=\(s.nome) (a caixa da pergunta existe nesta tela)")
        }
        replicas[papel] = r
        return r
    }

    /// Grava o `saved_json` da réplica da tela, numa fila serial, com escrita atômica — e **nunca
    /// vazio**: um salvo vazio faria a próxima vida nascer sem o roteiro.
    private func salvarAgora() {
        salvoAgendado?.cancel()
        salvoAgendado = nil
        guard let replica else { return }
        gravar(replica)
    }

    private func gravar(_ r: ReplicaDoTeleprompter) {
        guard let json = r.salvoJSON(), !json.isEmpty else {
            registrar("!! saved_json vazio ou com erro — nada gravado")
            return
        }
        let url = arquivoDoSalvo(r.papel)
        filaDoSalvo.async {
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Registro.compartilhado.linha("teleprompter: !! não consegui gravar estado: \(SanitizacaoDoLog.erro(error))")
            }
        }
    }

    private func agendarSalvo(em segundos: Double) {
        guard replica != nil else { return }
        salvoAgendado?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.salvarAgora() }
        salvoAgendado = item
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: item)
    }

    private func salvarTudoAgora() {
        for r in replicas.values { gravar(r) }
        filaDoSalvo.sync {}
    }

    // MARK: - o laço

    private func iniciarLaco(_ papel: PapelDoTeleprompter, _ config: FronteiraDoTeleprompter.Configuracao,
                             pin: String?) {
        guard let replica, !lacoRodando else { return }
        let f = FronteiraDoTeleprompter(
            papel: papel, replica: replica, configuracao: config,
            // Relidos **a cada volta**: o controle que pareou numa sessão volta pelo par gravado.
            paresConhecidos: { Identidade.paresConhecidos() },
            aoSubir: { [weak self] pares, par in
                if pares.isEmpty {
                    Registro.compartilhado.linha("teleprompter: !! o núcleo não devolveu estado de pareamento — "
                                                 + "nada foi gravado")
                } else {
                    Identidade.guardarPares(pares)
                }
                Registro.compartilhado.linha(
                    "teleprompter: sessão de pé "
                    + "papel_presente=\(par.papel != nil) pareamento=\(par.pareamentoNovo ? "novo (PIN)" : "retomado")"
                    + " pares_gravados=\(pares.count) bytes")
                DispatchQueue.main.async { self?.par = par.nome.isEmpty ? T("outro aparelho") : par.nome }
            })
        fronteira = f
        lacoRodando = true
        recalcularOcioso()
        let laco = LacoDoTeleprompter(
            papel: papel, fronteira: f,
            deveParar: { f.deveParar },
            relogio: { Teleprompter.agora() },
            avisar: { [weak self] aviso in self?.doLaco(aviso, papel: papel, fronteira: f) })
        let t = Thread { [weak self] in
            laco.correr(pinInicial: pin)
            DispatchQueue.main.async { self?.lacoAcabou(f) }
        }
        t.name = "quall.teleprompter.sessao"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// **Na thread do laço.** Conta o salto antes de a main saber dele, escreve o registro e leva o
    /// aviso para a main.
    private func doLaco(_ aviso: AvisoDoLaco, papel: PapelDoTeleprompter, fronteira f: FronteiraDoTeleprompter) {
        if case .mudou(let m) = aviso, m.contains(.salto), papel == .prompter {
            travaDosSaltos.lock(); saltosVistos += 1; travaDosSaltos.unlock()
        }
        switch aviso {
        case .mudou(let m):
            // O relato de posição chega ao controle a 4 Hz: fica fora do registro.
            if !m.subtracting([.posicao]).isEmpty {
                var linha = "mudou [\(m.nomes.joined(separator: " "))]"
                if m.contains(.texto), let t = f.replica.texto() {
                    linha += " texto=\(t.utf8.count) bytes"
                }
                if let e = f.replica.estado() {
                    linha += " | rolando=\(e.rolando) velocidade=\(e.velocidade) fonte=\(e.fonte) margem=\(e.margem) "
                        + "linha=\(e.linhaDeLeitura) espelho=\(e.espelho) posicao=\(e.posicao) "
                        + "salto=\(e.salto.map { String($0) } ?? "-") par_visto_ha_ms=\(e.parVistoHaMs.map { String($0) } ?? "null")"
                        + " para_tras=\(e.paraTras) segurando=\(e.segurando) par_entende_segurar=\(e.parEntendeSegurar)"
                }
                registrar(linha)
            }
        case .abrindo(let p, let tentativa):
            if tentativa > 1 || papel == .controle {
                registrar("\(papel == .prompter ? "esperando" : "conectando") (tentativa \(tentativa))"
                          + " PIN presente=\(p != nil)")
            }
        case .conectou:
            registrar("conectou")
        case .caiu(let porque):
            registrar("a sessão acabou: \(porque) — ordem do fim cumprida (bombeada final, peer_lost, close)"
                      )
        case .falhou(let s, let motivo, let decisao):
            registrar("não abriu: status=\(s.nome) causa=\(SanitizacaoDoLog.causaExterna(motivo)) decisao=\(decisao)")
        case .terminou(let porque):
            registrar("laço terminou: \(porque)")
        }
        DispatchQueue.main.async { [weak self] in self?.receber(aviso, papel: papel) }
    }

    /// **Na main.**
    private func receber(_ aviso: AvisoDoLaco, papel: PapelDoTeleprompter) {
        guard tela != .fechada else { return }
        switch aviso {
        case .abrindo(let p, let tentativa):
            tentativas = tentativa
            if papel == .prompter, let p { pin = p }
            if fase != .encerrando { fase = jaHouveSessao ? .semPar : .abrindo }
        case .conectou:
            ligacao = .conectada(desde: Teleprompter.agora(), depoisDeQueda: jaHouveSessao)
            jaHouveSessao = true
            // Sessão nova, prompter possivelmente outro: o que ele entende se lê de novo.
            recusouOSegurarPorProtocolo = false
            recusouOSegurarPorSessaoFechada = false
            // A pergunta vale por sessão (§11.4): a nova recomeça comparando, e a recusa de antes
            // (o prompter que saiu, o roteiro que mudou) não vale mais.
            recusaDaEscolha = nil
            recadoDaGravacao = ""
            if fase != .encerrando { fase = .conectado }
            mensagem = ""
            tentativas = 0
            // Na bancada (`--dados`) o endereço não vai para as preferências do usuário: as corridas
            // de 14/09 deixaram "127.0.0.1:17982" como o último endereço do app de verdade (o mesmo
            // bundle id), porque esta linha, ao contrário da leitura em `ultimoEndereco`, não olhava.
            if papel == .controle, argumentos.dados == nil, let endereco {
                UserDefaults.standard.set(endereco, forKey: Teleprompter.chaveDoUltimoEndereco)
            }
        case .mudou(let m):
            aplicar(m)
        case .caiu:
            ligacao = .caiu
            if fase != .encerrando { fase = .semPar }
            salvarAgora()
        case .falhou(let s, let motivo, let decisao):
            let texto = Teleprompter.conselho(papel: papel, status: s, motivo: motivo, decisao: decisao,
                                             jaHouveSessao: jaHouveSessao, porta: portaDoPrompter)
            if !texto.isEmpty { mensagem = texto }
        case .terminou:
            break
        }
        atualizarEstado()
    }

    private func lacoAcabou(_ f: FronteiraDoTeleprompter) {
        guard fronteira === f else { return }
        fronteira = nil
        lacoRodando = false
        ligacao = .semSessao
        salvarAgora()
        if fecharAoTerminar || tela == .fechada {
            fecharTela()
        } else if tela == .controle {
            fase = .formulario
            comecarNavegador()
        } else {
            // O prompter parou de esperar sozinho (cinco PINs errados, sinalização quebrada): a
            // tela fica, com o motivo e o botão "Esperar de novo".
            fase = .formulario
        }
        recalcularOcioso()
    }

    /// Os bits que chegaram, **na main**. A ordem importa: o texto novo primeiro (o layout mantém o
    /// lugar de quem lê), e o salto por último (ele manda na posição).
    private func aplicar(_ m: MudancasDoTeleprompter) {
        guard let replica else { return }
        if m.contains(.texto), let novo = replica.texto() {
            texto = novo
            if editorAberto {
                let alterado = rascunho.alterado
                rascunho.chegou(textoNovo: novo)
                registrar("editor aberto: chegou texto do outro lado (\(novo.utf8.count) bytes) — rascunho "
                          + (alterado ? "alterado: aviso de conflito, o rascunho fica como está"
                                      : "sem alteração: o texto novo entrou no editor")
                          + " (conflito=\(rascunho.emConflito))")
            }
            if tela == .prompter { vista?.trocarTexto(novo) }
        }
        if tela == .controle, m.contains(.perguntaDoTexto) {
            // A pergunta abriu, mudou ou fechou — e fechando por adoção (o mesmo texto, ou o
            // controle vazio), o roteiro daqui passa a ser o do prompter.
            recarregarTexto()
        }
        if tela == .prompter, comCamera {
            if m.contains(.espelho) { espelhoMexidoNaCamera = true }
            // O pedido do controle (§13.2): a tela relê e decide.
            if m.contains(.gravacao) { camera?.gravacao?.decidir() }
        }
        if tela == .controle, m.contains(.gravacao), let r = replica.estado()?.gravacaoRecusada {
            recadoDaGravacao = T("O prompter recusou: %@", r.motivo)
        }
        if m.contains(.copiaDoTexto) {
            // **Grave o salvo** a cada cópia nova (§11.5, achado B7): sem isto ela só existe na memória.
            salvarAgora()
        }
        atualizarEstado()
        if m.contains(.copiaDoTexto) {
            registrar("cópias do texto: \(estado.copiasDoTexto.count) (salvo gravado)")
        }
        if tela == .prompter, m.contains(.fonte), fonteAutomatica {
            fonteAutomatica = false
            avisoDaFonte = T("Fonte automática desligada: o controle mudou a fonte")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.avisoDaFonte = "" }
        }
        if tela == .prompter {
            vista?.aplicar(estado: estado)
            if m.contains(.salto) {
                travaDosSaltos.lock(); let vistos = saltosVistos; travaDosSaltos.unlock()
                if let alvo = estado.salto { irAoSalto(alvo) }
                travaDosSaltos.lock(); saltosAplicados = vistos; travaDosSaltos.unlock()
            }
        }
    }

    /// `_JUMP` no prompter: vai até o alvo, chama `set_position` com ele e mantém `rolando`.
    private func irAoSalto(_ alvo: Double) {
        vista?.saltar(para: alvo)
        replica?.definirPosicao(alvo)
    }

    private func aCadaQuarto() {
        atualizarEstado()
        let t = Teleprompter.agora()
        if argumentos.modoDeBancada, t - ultimoRegistroDeEstado >= 2 {
            ultimoRegistroDeEstado = t
            var linha = "estado (\(tela == .prompter ? "prompter" : "controle"), fase=\(fase)): "
                + "rolando=\(estado.rolando) velocidade=\(estado.velocidade) fonte=\(estado.fonte) margem=\(estado.margem) "
                + "linha=\(estado.linhaDeLeitura) espelho=\(estado.espelho) posicao=\(estado.posicao) "
                + "texto=\(estado.textoBytes) par_visto_ha_ms=\(estado.parVistoHaMs.map { String($0) } ?? "null") "
                + "sem_confirmacao_ha_ms=\(estado.semConfirmacaoHaMs.map { String($0) } ?? "null") "
                + "aviso_par_sumido=\(avisos.parSumido) aviso_sem_confirmacao=\(avisos.semConfirmacao) "
                + "para_tras=\(estado.paraTras) segurando=\(estado.segurando) par_entende_segurar=\(estado.parEntendeSegurar)"
            if tela == .controle {
                linha += " | pergunta=\(Teleprompter.descrever(caixaDaPergunta)) copias=\(estado.copiasDoTexto.count)"
                    + " texto=\(texto.utf8.count) bytes"
                linha += " | segurar: modo=\(segurarParaRolar) invertido=\(segurar.invertido) disponibilidade=\(disponibilidadeDoSegurar) "
                    + "apertos=[\(segurar.apertos.map { "\($0.fonte.rawValue):\($0.botao.rawValue)" }.joined(separator: " "))] "
                    + "seguro=\(segurar.seguro) texto_parou=\(segurar.textoParou)"
            }
            if tela == .prompter, let v = vista {
                // `janela_visivel`: uma janela coberta por outras recebe menos quadros do sistema, e
                // os atrasados de uma janela escondida não dizem nada sobre a rolagem na tela.
                let visivel = v.window.map { $0.occlusionState.contains(.visible) ? "sim" : "NAO" } ?? "sem janela"
                linha += " | vista: janela_visivel=\(visivel) posicao_mostrada=\(String(format: "%.4f", v.posicao)) linhas=\(v.quantasLinhas) "
                    + "quadros=\(v.quadros) atrasados=\(v.quadrosAtrasados) "
                    + "maior_intervalo_ms=\(String(format: "%.1f", v.maiorIntervaloMs)) blocos=\(v.blocosVivos)"
            }
            registrar(linha)
        }
    }

    private func atualizarEstado() {
        guard let replica else { return }
        // Um erro do `(buf, cap)` volta `nil` e **não** é lido como estado padrão: a tela fica com
        // o último estado bom.
        guard let e = replica.estado() else { return }
        if e != estado { estado = e }
        let a = AvisosDaTela.calcular(estado: e, ligacao: ligacao, agora: Teleprompter.agora())
        if a != avisos {
            if a.parSumido != avisos.parSumido, tela != .fechada {
                registrar("aviso \(tela == .prompter ? "de controle sumido" : "de prompter sumido"): "
                          + (a.parSumido ? "LIGADO" : "desligado"))
            }
            avisos = a
        }
        if tela == .controle {
            acompanharOSegurar(e)
            acompanharAPergunta(e)
        }
    }

    // MARK: - edições locais (os botões, o teclado e as ações de bancada)

    /// Uma edição na réplica, **da main**, que sai na hora. No prompter, a vista é atualizada já —
    /// o bit `changed` só diz o que veio do outro lado, e a tecla daqui não geraria nenhum.
    @discardableResult
    private func editar(_ nome: String, _ f: (ReplicaDoTeleprompter) -> StatusDaFronteira) -> Bool {
        guard let replica else { return false }
        let s = f(replica)
        if s != .ok {
            registrar("!! edição recusada: \(s.nome) \(SanitizacaoDoLog.causaExterna(PonteDoTeleprompter.ultimoErro()))")
        }
        atualizarEstado()
        if tela == .prompter { vista?.aplicar(estado: estado) }
        agendarSalvo(em: 3)
        return s == .ok
    }

    /// Um controle deslizante manda dezenas de valores por segundo; a fonte e a margem fazem o
    /// prompter refazer o layout do roteiro inteiro a cada um. No máximo um envio a cada
    /// `intervalo`, e o último valor sempre sai.
    private func limitado(_ chave: String, intervalo: Double = 0.12, _ acao: @escaping () -> Void) {
        let t = Teleprompter.agora()
        var e = envioLimitado[chave] ?? (0, nil)
        e.pendente?.cancel()
        if t - e.quando >= intervalo {
            e = (t, nil)
            envioLimitado[chave] = e
            acao()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.envioLimitado[chave] = (Teleprompter.agora(), nil)
            acao()
        }
        e.pendente = item
        envioLimitado[chave] = e
        DispatchQueue.main.asyncAfter(deadline: .now() + (intervalo - (t - e.quando)), execute: item)
    }

    func tocarOuPausar() {
        // O estado **de agora**, da réplica, e não o publicado há até 250 ms: um "tocar" lido de um
        // estado velho reafirmaria `set_scrolling(true)` com o texto já rolando (regra do
        // coordenador, 14/09, da revisão do núcleo).
        let atual = replica?.estado() ?? estado
        // No controle, **nunca durante o segurar**: o play e a pausa saem do modo (§12.3), e quem
        // está com o dedo no botão não pediu nenhum dos dois. Inalcançável pela tela (no modo o
        // painel some e o espaço não faz nada); a guarda é o cinto.
        if tela == .controle, !segurar.apertos.isEmpty || atual.segurando {
            registrar("tocar/pausar ignorado: o segurar está de pé (apertos=\(segurar.apertos.count) segurando=\(atual.segurando))")
            return
        }
        let rolar = !atual.rolando
        editar("rolando=\(rolar)") { $0.definirRolando(rolar) }
    }

    func definirVelocidade(_ v: Double) {
        let c = min(EstadoDoTeleprompter.faixaDaVelocidade.upperBound,
                    max(EstadoDoTeleprompter.faixaDaVelocidade.lowerBound, (v * 100).rounded() / 100))
        limitado("velocidade", intervalo: 0.05) { [weak self] in self?.editar("velocidade=\(c)") { $0.definirVelocidade(c) } }
    }

    func mudarVelocidade(_ delta: Double) { definirVelocidade(estado.velocidade + delta) }

    func definirFonte(_ v: Double) {
        if fonteAutomatica { fonteAutomatica = false }
        let c = min(EstadoDoTeleprompter.faixaDaFonte.upperBound,
                    max(EstadoDoTeleprompter.faixaDaFonte.lowerBound, (v * 10).rounded() / 10))
        limitado("fonte") { [weak self] in self?.editar("fonte=\(c)") { $0.definirFonte(c) } }
    }

    func definirMargem(_ v: Double) {
        let c = min(EstadoDoTeleprompter.faixaDaMargem.upperBound, max(0, (v * 10_000).rounded() / 10_000))
        limitado("margem") { [weak self] in self?.editar("margem=\(c)") { $0.definirMargem(c) } }
    }

    func definirLinhaDeLeitura(_ v: Double) {
        let c = min(1, max(0, (v * 10_000).rounded() / 10_000))
        limitado("linha", intervalo: 0.05) { [weak self] in self?.editar("linha=\(c)") { $0.definirLinhaDeLeitura(c) } }
    }

    func alternarEspelho() {
        if comCamera { espelhoMexidoNaCamera = true }
        let novo = !estado.espelho
        editar("espelho=\(novo)") { $0.definirEspelho(novo) }
    }

    /// "Voltar ao começo" é `jump(0)`; duas vezes são dois saltos (§3).
    func saltar(_ p: Double) {
        let alvo = min(1, max(0, p))
        guard editar("salto=\(alvo)", { $0.saltar(alvo) }) else { return }
        if tela == .prompter, let s = estado.salto { irAoSalto(s) }
    }

    /// "Pular" é `jump_by` (§3): parte de onde o texto **vai estar**.
    func pular(_ delta: Double) {
        let d = min(1, max(-1, delta))
        guard editar("pular=\(d)", { $0.pular(d) }) else { return }
        if tela == .prompter, let s = estado.salto { irAoSalto(s) }
    }

    /// A vista relata onde o texto está. **Só o prompter**, e nunca entre um salto remoto e a
    /// aplicação dele (ver `travaDosSaltos`).
    func relatarPosicao(_ p: Double) {
        guard tela == .prompter, let replica, p.isFinite else { return }
        travaDosSaltos.lock()
        let emDia = saltosVistos == saltosAplicados
        travaDosSaltos.unlock()
        guard emDia else { return }
        replica.definirPosicao(min(1, max(0, p)))
    }

    /// O texto chegou ao fim rolando: o prompter para ali, e os dois lados veem "parado". Rolando
    /// para trás, nunca (quem chega ao começo fica lá, com `rolando` de pé — §12.5).
    func chegouAoFim() {
        guard tela == .prompter, estado.rolando, !estado.paraTras else { return }
        registrar("o texto chegou ao fim rolando: parando")
        editar("rolando=false (fim do texto)") { $0.definirRolando(false) }
    }

    @discardableResult
    private func aplicarTextoLocal(_ t: String) -> Bool {
        let limpo = t.replacingOccurrences(of: "\u{0}", with: "")
        guard limpo.utf8.count <= Teleprompter.tetoDoTexto else {
            registrar("!! roteiro de \(limpo.utf8.count) bytes passa do teto de \(Teleprompter.tetoDoTexto)")
            return false
        }
        guard let replica else { return false }
        let s = replica.definirTexto(limpo)
        guard s == .ok else {
            registrar("!! set_text recusado: \(s.nome) \(SanitizacaoDoLog.causaExterna(PonteDoTeleprompter.ultimoErro()))")
            return false
        }
        texto = limpo
        if tela == .prompter { vista?.trocarTexto(limpo) }
        atualizarEstado()
        salvarAgora()
        registrar("texto confirmado aqui: \(limpo.utf8.count) bytes")
        return true
    }

    // MARK: - o editor do roteiro

    func abrirEditor(comAreaDeTransferencia: Bool = false) {
        guard tela != .fechada else { return }
        rascunho = RascunhoDoTexto(textoAtual: texto)
        if comAreaDeTransferencia, let colado = NSPasteboard.general.string(forType: .string) {
            rascunho.rascunho = colado
        }
        mensagemDoEditor = ""
        editorAberto = true
    }

    func colarNoEditor() {
        guard let colado = NSPasteboard.general.string(forType: .string) else {
            mensagemDoEditor = T("A área de transferência não tem texto.")
            return
        }
        rascunho.rascunho = colado
    }

    /// "Usar o texto novo": o rascunho descartado vai para a área de transferência.
    func usarOTextoNovo() {
        guard let descartado = rascunho.usarOTextoNovo() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(descartado, forType: .string)
        mensagemDoEditor = T("O seu rascunho foi para a área de transferência.")
        registrar("editor: a pessoa usou o texto do outro lado (rascunho de \(descartado.utf8.count) bytes "
                  + "copiado para a área de transferência)")
    }

    func manterOMeu() {
        rascunho.manterOMeu()
        registrar("editor: a pessoa manteve o rascunho dela contra o texto do outro lado")
    }

    func confirmarEditor() {
        guard let t = rascunho.paraConfirmar(textoDaReplica: texto) else {
            editorAberto = false
            return
        }
        guard t.utf8.count <= Teleprompter.tetoDoTexto else {
            mensagemDoEditor = T("O roteiro tem %@ bytes; o máximo é "
                + "%@ (cerca de 20 mil palavras).", t.utf8.count.formatted(), Teleprompter.tetoDoTexto.formatted())
            return
        }
        guard aplicarTextoLocal(t) else {
            mensagemDoEditor = T("O texto foi recusado: %@", PonteDoTeleprompter.ultimoErro())
            return
        }
        editorAberto = false
    }

    func cancelarEditor() {
        editorAberto = false
        mensagemDoEditor = ""
    }

    // MARK: - tela cheia e teclado

    func alternarTelaCheia(ligar: Bool? = nil) {
        // De conteúdo: as janelas do ícone da barra de menus também são visíveis e têm vista (`Janela.ehDeConteudo`).
        guard let janela = NSApp.windows.first(where: { Janela.ehDeConteudo($0) && $0.isVisible && !$0.isSheet })
                ?? NSApp.keyWindow else { return }
        let esta = janela.styleMask.contains(.fullScreen)
        if let ligar, ligar == esta { return }
        janela.collectionBehavior.insert(.fullScreenPrimary)
        janela.toggleFullScreen(nil)
    }

    private func tratar(_ acao: AtalhosDoTeleprompter.Acao) -> Bool {
        guard tela != .fechada, !editorAberto else { return false }
        // No modo "Segurar para rolar" a tela é só os dois botões, e o teclado é só ↑ e ↓
        // (`teclaDoSegurar`): as outras teclas do teleprompter não fazem nada — um passador de
        // slides que manda "." ou espaço não pode mexer na linha de leitura nem dar play (derivado).
        if modoSegurarNaTela { return true }
        // No formulário do controle as teclas são dos campos.
        if tela == .controle && !(fase == .conectado || fase == .semPar) { return false }
        switch acao {
        case .tocarOuPausar: tocarOuPausar()
        case .velocidade(let d): mudarVelocidade(d)
        case .pular(let d): pular(d)
        case .inicio: saltar(0)
        case .espelho: alternarEspelho()
        case .fonte(let d): definirFonte(estado.fonte + d)
        case .margem(let d): definirMargem(estado.margem + d)
        case .linha(let d): definirLinhaDeLeitura(estado.linhaDeLeitura + d)
        case .telaCheia:
            guard tela == .prompter else { return false }
            alternarTelaCheia()
        case .sairDaTelaCheia:
            guard emTelaCheia else { return false }
            alternarTelaCheia(ligar: false)
        case .editar: abrirEditor()
        }
        return true
    }

    // MARK: - anúncio e lista

    private func anunciar(porta: UInt16) {
        anunciosPendentes += 1
        recalcularOcioso()
        let id = Identidade.deviceId
        let nomeDoAparelho = nome
        filaDoAnuncio.async { [weak self, anunciante] in
            anunciante.parar()
            let ok = anunciante.comecarComoTeleprompter(deviceId: id, nome: nomeDoAparelho, porta: porta)
            Registro.compartilhado.linha("teleprompter: mdns: anunciou=\(ok) porta=\(porta) papel=teleprompter")
            DispatchQueue.main.async {
                self?.anunciandoPorMDNS = ok
                self?.anunciosPendentes -= 1
                self?.recalcularOcioso()
            }
        }
    }

    private func pararAnuncio() {
        anunciosPendentes += 1
        filaDoAnuncio.async { [weak self, anunciante] in
            anunciante.parar()
            Registro.compartilhado.linha("teleprompter: mdns: parado")
            DispatchQueue.main.async {
                self?.anunciandoPorMDNS = false
                self?.anunciosPendentes -= 1
                self?.recalcularOcioso()
            }
        }
    }

    private func comecarNavegador() {
        procurando = true
        navegador.comecar(excluindo: Identidade.deviceId) { [weak self] lista in
            DispatchQueue.main.async {
                guard let self, self.tela == .controle else { return }
                if lista != self.prompters {
                    Registro.compartilhado.linha("teleprompter: lista: \(lista.count) prompter(s)")
                }
                self.prompters = lista
            }
        }
    }

    private static let chaveDoUltimoEndereco = "teleprompter.controle.ultimo_endereco"
    private static let chaveDaFonteAutomatica = "teleprompter.prompter.fonte_automatica"
    private static let chaveDoEnquadramento = "teleprompter.prompter.enquadramento"
    private static let chaveDoSegurar = "teleprompter.controle.segurar_para_rolar"
    private static let chaveDaInversao = "teleprompter.controle.inverter_botoes"

    /// O "Enquadramento" guardado neste Mac (as duas setas laterais, em fração da largura). Na
    /// bancada, a largura inteira.
    var enquadramentoGuardado: (esquerda: Double, direita: Double) {
        guard argumentos.dados == nil,
              let v = UserDefaults.standard.array(forKey: Teleprompter.chaveDoEnquadramento) as? [Double], v.count == 2
        else { return (0, 1) }
        return (v[0], v[1])
    }

    func guardarEnquadramento(_ esquerda: Double, _ direita: Double) {
        registrar(String(format: "enquadramento: %.3f / %.3f", esquerda, direita))
        if argumentos.dados == nil { UserDefaults.standard.set([esquerda, direita], forKey: Teleprompter.chaveDoEnquadramento) }
    }

    /// A fonte que a vista escolheu (fonte automática): pelo mesmo caminho da edição, sem desligar
    /// a automática — é ela mesma quem muda.
    func definirFonteAutomatica(escolhida f: Double) {
        guard fonteAutomatica else { return }
        editar("fonte automática=\(f)") { $0.definirFonte(f) }
    }
    var ultimoEndereco: String {
        // Na bancada (`--dados`), a conveniência não vem das preferências do usuário.
        argumentos.dados == nil ? (UserDefaults.standard.string(forKey: Teleprompter.chaveDoUltimoEndereco) ?? "") : ""
    }

    // MARK: - "Segurar para rolar" (o controle, §12.5)

    /// O controle está no formulário (achar o prompter), e não no painel.
    var controleNoFormulario: Bool {
        fase == .formulario || (fase == .abrindo && !jaHouveSessao) || (fase == .encerrando && !jaHouveSessao)
    }

    /// A tela do controle mostra o modo agora (e é ele que recebe as setas).
    var modoSegurarNaTela: Bool { tela == .controle && segurarParaRolar && !controleNoFormulario }

    var disponibilidadeDoSegurar: DisponibilidadeDoSegurar {
        DisponibilidadeDoSegurar.calcular(conectado: fase == .conectado && !recusouOSegurarPorSessaoFechada,
                                          parSumido: avisos.parSumido,
                                          estado: estado, recusouPorProtocolo: recusouOSegurarPorProtocolo)
    }

    /// **"Inverter botões"** (pedido de 14/09 à tarde), pelo interruptor da tela e pela bancada. Ajuste
    /// local do controle, guardado junto com o modo (na bancada, `--dados`, só na memória), e vale para
    /// qualquer prompter. **Recusado com um botão de rolar apertado** — a regra está em
    /// `SegurarParaRolar.definirInversao`, e o interruptor fica desligado enquanto isso.
    func definirInversao(_ v: Bool) {
        guard tela == .controle, v != segurar.invertido else { return }
        guard mudarSegurar({ $0.definirInversao(v) }) else {
            registrar("inverter botões: recusado (\(v ? "ligar" : "desligar")) — há um botão de rolar apertado "
                      + "(apertos=[\(segurar.apertos.map { "\($0.fonte.rawValue):\($0.botao.rawValue)" }.joined(separator: " "))])")
            return
        }
        if argumentos.dados == nil { UserDefaults.standard.set(v, forKey: Teleprompter.chaveDaInversao) }
        registrar("inverter botões: \(v ? "ligado" : "desligado") — Rolar para cima: \(segurar.legenda(.cima)) "
                  + "(para_tras=\(segurar.paraTras(.cima))), Rolar para baixo: \(segurar.legenda(.baixo)) "
                  + "(para_tras=\(segurar.paraTras(.baixo)))")
    }

    /// Muda a regra dos apertos e só publica se algo mudou — ela é lida a cada quarto de segundo.
    @discardableResult
    private func mudarSegurar<R>(_ f: (inout SegurarParaRolar) -> R) -> R {
        var s = segurar
        let r = f(&s)
        if s != segurar { segurar = s }
        return r
    }

    /// **Um aperto**: o `mouseDown` num botão, ou a seta que desce. Com os botões desligados, nada.
    func apertarDoSegurar(_ botao: BotaoDeSegurar, por fonte: FonteDoAperto) {
        guard tela == .controle else { return }
        let d = disponibilidadeDoSegurar
        guard modoSegurarNaTela, d.botoesLigados else {
            registrar("segurar: \(botao.rawValue) apertado (\(fonte.rawValue)) com os botões desligados (\(d)) — nada sai")
            return
        }
        let comando = mudarSegurar { $0.apertar(botao, por: fonte) }
        registrar("segurar: apertou \(botao.rawValue) (\(fonte.rawValue))"
                  + (segurar.invertido ? " [botões invertidos: \(segurar.legenda(botao))]" : "")
                  + (comando == nil ? " — já estava apertado, nada sai" : ""))
        if let comando { mandar(comando, porque: "apertou \(botao.rawValue)") }
    }

    /// **Um aperto que acabou**: soltou, saiu do botão, a seta subiu.
    func soltarDoSegurar(_ botao: BotaoDeSegurar, por fonte: FonteDoAperto, porque: String) {
        guard tela == .controle else { return }
        guard let comando = mudarSegurar({ $0.soltar(botao, por: fonte) }) else { return }
        registrar("segurar: \(porque) (\(botao.rawValue), \(fonte.rawValue))")
        mandar(comando, porque: porque)
    }

    /// Solta tudo: perdeu o foco, fechou, desconectou, saiu do modo. Sem aperto nenhum, nada.
    func soltarTudoDoSegurar(porque: String) {
        guard let comando = mudarSegurar({ $0.soltarTudo() }) else { return }
        registrar("segurar: soltou tudo — \(porque)")
        mandar(comando, porque: porque)
    }

    private func sairDoModoSegurar() {
        let comando = mudarSegurar { $0.sairDoModo() }
        if let comando {
            registrar("segurar: soltou tudo — saiu do modo")
            mandar(comando, porque: "saiu do modo")
        }
    }

    /// A janela perdeu o foco, ou o app foi para o segundo plano.
    func perdeuOFoco(porque: String) {
        soltarTudoDoSegurar(porque: porque)
    }

    private func mandar(_ c: ComandoDoSegurar, porque: String) {
        guard let replica else { return }
        switch c {
        case .segurar(let paraTras):
            let s = replica.segurar(paraTras: paraTras)
            mudarSegurar { $0.segurou(aceito: s == .ok) }
            if s == .protocolo { recusouOSegurarPorProtocolo = true }
            if s == .fechado { recusouOSegurarPorSessaoFechada = true }
            registrar("segurar: hold(para_tras=\(paraTras)) = \(s.nome)"
                      + (s == .ok ? "" : " — \(SanitizacaoDoLog.causaExterna(PonteDoTeleprompter.ultimoErro()))"))
        case .soltar:
            let s = replica.soltar()
            registrar("segurar: release = \(s.nome) (\(porque))")
        }
        atualizarEstado()
    }

    /// A cada leitura do estado, no controle: o texto parou sozinho com o dedo no botão?
    private func acompanharOSegurar(_ e: EstadoDoTeleprompter) {
        if e.parEntendeSegurar, recusouOSegurarPorProtocolo { recusouOSegurarPorProtocolo = false }
        let avisoAntes = segurar.textoParou
        if mudarSegurar({ $0.observar(segurando: e.segurando, rolando: e.rolando) }) {
            registrar("segurar: O TEXTO PAROU com o dedo no botão (segurando=false rolando=\(e.rolando) "
                      + "posicao=\(e.posicao) par_visto_ha_ms=\(e.parVistoHaMs.map { String($0) } ?? "null") fase=\(fase)) — "
                      + "a tela diz \"\(segurar.avisoDoTextoParado(posicao: e.posicao) ?? "?")\"")
        } else if avisoAntes, !segurar.textoParou {
            registrar("segurar: o texto voltou a rolar sem aperto daqui — o aviso de texto parado some")
        }
        let d = disponibilidadeDoSegurar
        if d != ultimaDisponibilidadeDoSegurar {
            ultimaDisponibilidadeDoSegurar = d
            registrar("segurar: disponibilidade=\(d) (modo \(segurarParaRolar ? "ligado" : "desligado"), "
                      + "par_entende_segurar=\(e.parEntendeSegurar))")
        }
    }

    /// **As setas no modo** (Mac e Windows): ↑ segura "Rolar para cima", ↓ "Rolar para baixo"; a
    /// repetição automática da tecla não faz nada. Fora do modo, as setas são da velocidade.
    private func teclaDoSegurar(_ botao: BotaoDeSegurar, desce: Bool, repeticao: Bool) -> Bool {
        guard modoSegurarNaTela, !editorAberto else { return false }
        if desce {
            if !repeticao { apertarDoSegurar(botao, por: .tecla) }
        } else {
            soltarDoSegurar(botao, por: .tecla, porque: "soltou a tecla")
        }
        return true
    }

    /// A vista de um botão, ao nascer.
    func registrar(vistaDoSegurar v: VistaDoBotaoDeSegurar) {
        vistasDoSegurar[v.botao] = ReferenciaFraca(v)
    }

    // MARK: - a pergunta do texto e os roteiros guardados (o controle, §11.7)

    /// **A caixa da pergunta**, pela regra pura (`CaixaDaPergunta.calcular`). Só no painel e no modo
    /// segurar: no formulário não há sessão, e a pessoa precisa dos campos.
    var caixaDaPergunta: CaixaDaPergunta {
        guard tela == .controle, !controleNoFormulario else { return .nenhuma }
        return CaixaDaPergunta.calcular(pergunta: estado.perguntaDoTexto, parVistoHaMs: estado.parVistoHaMs,
                                        conectado: fase == .conectado, recusa: recusaDaEscolha)
    }

    enum FolhaDoControle: String, Identifiable {
        case pergunta, roteiros
        var id: String { rawValue }
    }

    /// **Uma folha por vez** na janela do controle. A pergunta tem a vez sobre os roteiros; o editor
    /// do roteiro, que já é uma folha, fica na frente dela — e confirmar nele muda o "meu" da pergunta
    /// (§11.4), que aparece quando o editor fecha.
    var folhaDoControle: FolhaDoControle? {
        guard tela == .controle, !editorAberto else { return nil }
        if caixaDaPergunta != .nenhuma { return .pergunta }
        return roteirosAbertos ? .roteiros : nil
    }

    /// A folha foi fechada (o "Fechar" dos roteiros). A pergunta não se fecha pela pessoa: some
    /// quando se resolve, ou quando fecha pelo outro lado.
    func fecharFolha() {
        if roteirosAbertos { fecharRoteiros() }
    }

    /// **A escolha**, pelos dois botões da caixa e pela bancada — com o resumo do texto do prompter
    /// **que a caixa mostrou**, e nunca um relido na hora do toque (§11.4).
    @discardableResult
    func escolherTexto(manterOMeu: Bool, resumoVisto: String, porque: String) -> StatusDaFronteira? {
        guard tela == .controle, let replica else { return nil }
        let s = replica.resolverTexto(manterOMeu: manterOMeu, resumoVisto: resumoVisto)
        registrar("pergunta: \(manterOMeu ? TextosDaPergunta.mandarOMeu : TextosDaPergunta.usarODoPrompter) "
                  + "(\(porque), resumo visto \(resumoVisto)) = \(s.nome)"
                  + (s == .ok ? "" : " — \(SanitizacaoDoLog.causaExterna(PonteDoTeleprompter.ultimoErro()))"))
        switch s {
        case .ok:
            recusaDaEscolha = nil
            // Grave o salvo agora (§11.5): a cópia do que saiu só existe na memória até isto.
            salvarAgora()
            recarregarTexto()
        case .ocupado, .fechado:
            recusaDaEscolha = s
        default:
            // `INVALID`: a pergunta já tinha fechado; a caixa some com o estado.
            break
        }
        atualizarEstado()
        return s
    }

    /// O roteiro deste controle, relido da réplica — depois da escolha e quando a pergunta fecha
    /// por adoção, o texto daqui passa a ser o do prompter sem bit `_TEXT` (a mudança é daqui).
    private func recarregarTexto() {
        guard let novo = replica?.texto(), novo != texto else { return }
        texto = novo
        registrar("roteiro deste controle: \(novo.utf8.count) bytes")
    }

    private func acompanharAPergunta(_ e: EstadoDoTeleprompter) {
        if e.perguntaDoTexto == nil, recusaDaEscolha != nil { recusaDaEscolha = nil }
        contarPalavras(e)
        let caixa = caixaDaPergunta
        if caixa != ultimaCaixaRegistrada {
            let antes = ultimaCaixaRegistrada
            ultimaCaixaRegistrada = caixa
            registrar("pergunta: \(Teleprompter.descrever(caixa))"
                      + (antes == .nenhuma ? "" : " (era: \(Teleprompter.descrever(antes)))"))
            if antes == .nenhuma, caixa != .nenhuma, roteirosAbertos {
                // A pergunta toma a vez da folha dos roteiros: um alerta de "Usar este" ou "Apagar"
                // aberto nela não pode ficar preso na folha que sai, nem voltar depois (revisão de 14/09).
                if confirmacaoDaCopia != nil { cancelarCopia() }
                fecharRoteiros()
                registrar("roteiros guardados: fechados — a pergunta do texto tomou a vez")
            }
            if caixa != .nenhuma {
                // A folha é outra janela: o número dela vai para o registro (`screencapture -l`).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Registro.compartilhado.linha("janela: pergunta na tela — \(Janela.inventario())")
                }
            }
        }
        // Bancada: a escolha armada responde quando a caixa tiver as escolhas ligadas — e rearma
        // depois de `BUSY` ou `CLOSED`, senão a bancada ficaria esperando um dedo (§11.7).
        if let manter = escolhaArmada, caixa.escolhasLigadas, let visto = caixa.resumoMostrado {
            escolhaArmada = nil
            let s = escolherTexto(manterOMeu: manter, resumoVisto: visto, porque: "bancada: escolha armada")
            if s == .ocupado || s == .fechado {
                escolhaArmada = manter
                registrar("bancada: escolha=\(manter ? "meu" : "prompter") rearmada depois de \(s?.nome ?? "?")")
            }
        }
    }

    /// As palavras de cada texto na tela, **no texto inteiro**, uma vez por resumo. O texto lido é
    /// conferido pelo resumo antes de contar: entre ler o estado e ler o texto, a bombeada pode ter
    /// trocado a pergunta.
    private func contarPalavras(_ e: EstadoDoTeleprompter) {
        guard let replica else { return }
        var novas: [String: Int] = [:]
        func contar(_ resumo: String, _ ler: () -> String?) {
            guard palavras[resumo] == nil, novas[resumo] == nil, let t = ler(), Teleprompter.resumo(t) == resumo else { return }
            novas[resumo] = Palavras.contar(t)
        }
        if let p = e.perguntaDoTexto, p.aberta {
            if let d = p.doPrompter { contar(d.resumo) { replica.textoDaPergunta() } }
            if let m = p.meu { contar(m.resumo) { replica.texto() } }
        }
        for c in e.copiasDoTexto { contar(c.resumo) { replica.copiaDoTexto(resumo: c.resumo) } }
        if !novas.isEmpty { palavras.merge(novas) { $1 } }
    }

    static func descrever(_ c: CaixaDaPergunta) -> String {
        switch c {
        case .nenhuma: return "nenhuma"
        case .conferindo: return "conferindo (\"\(TextosDaPergunta.conferindo)\")"
        case .perguntando(_, let p, let m, let ligadas, let aviso):
            return "aberta no_prompter=\(p.bytes) bytes neste_aparelho=\(m.bytes) bytes escolhas=\(ligadas) aviso_presente=\(aviso != nil)"
        }
    }

    // MARK: "Roteiros guardados"

    struct CopiaVista: Equatable {
        let resumo: String
        let deOnde: String
        let texto: String
    }

    enum ConfirmacaoDaCopia: Equatable {
        case usar(String), apagar(String)
        var resumo: String {
            switch self { case .usar(let r), .apagar(let r): return r }
        }
    }

    func abrirRoteiros() {
        guard tela == .controle else { return }
        copiaVista = nil
        confirmacaoDaCopia = nil
        roteirosAbertos = true
        registrar("roteiros guardados: abertos, \(estado.copiasDoTexto.count) cópia(s)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Registro.compartilhado.linha("janela: roteiros guardados — \(Janela.inventario())")
        }
    }

    func fecharRoteiros() {
        roteirosAbertos = false
        copiaVista = nil
        confirmacaoDaCopia = nil
    }

    /// "Ver": o texto inteiro, só leitura, por `text_copy`.
    func verCopia(_ resumo: String) {
        guard let replica, let t = replica.copiaDoTexto(resumo: resumo) else {
            registrar("!! roteiros guardados: a cópia não está mais na lista")
            return
        }
        let c = estado.copiasDoTexto.first { $0.resumo == resumo }
        copiaVista = CopiaVista(resumo: resumo, deOnde: c?.deOnde ?? "", texto: t)
        registrar("roteiros guardados: ver cópia — \(t.utf8.count) bytes, \(Palavras.contar(t)) palavras, "
                  + "resumo conferido=\(Teleprompter.resumo(t) == resumo)")
    }

    func fecharCopiaVista() { copiaVista = nil }

    /// "Usar este" e "Apagar" pedem confirmação: o alerta mostra, e `confirmarCopia` faz.
    func pedirUsarCopia(_ resumo: String) {
        confirmacaoDaCopia = .usar(resumo)
        registrar("roteiros guardados: pede confirmação para usar cópia")
    }

    func pedirApagarCopia(_ resumo: String) {
        confirmacaoDaCopia = .apagar(resumo)
        registrar("roteiros guardados: pede confirmação para apagar cópia")
    }

    func confirmarCopia() {
        guard let c = confirmacaoDaCopia, let replica else { return }
        confirmacaoDaCopia = nil
        switch c {
        case .usar(let r):
            // "Usar este" é um `set_text` comum com o texto da cópia (§11.5).
            guard let t = replica.copiaDoTexto(resumo: r) else {
                registrar("!! roteiros guardados: a cópia sumiu antes de usar")
                return
            }
            if aplicarTextoLocal(t) {
                copiaVista = nil
                registrar("roteiros guardados: usou cópia como o roteiro (\(t.utf8.count) bytes)")
            }
        case .apagar(let r):
            let s = replica.esquecerCopiaDoTexto(resumo: r)
            registrar("roteiros guardados: apagou cópia = \(s.nome)")
            if copiaVista?.resumo == r { copiaVista = nil }
            salvarAgora()
            atualizarEstado()
        }
    }

    func cancelarCopia() {
        if let c = confirmacaoDaCopia { registrar("roteiros guardados: cancelou confirmação") }
        confirmacaoDaCopia = nil
    }

    // MARK: - ações de bancada

    private func agendarAcoesDeBancada() {
        guard let texto = argumentos.teleprompterAcoes else { return }
        let lidas = AcoesDeBancada.ler(texto) { caminho in
            try? String(contentsOfFile: (caminho as NSString).expandingTildeInPath, encoding: .utf8)
        }
        for r in lidas.recusadas { registrar("!! ação de bancada ilegível: \(r)") }
        for (segundos, acao) in lidas.acoes {
            // **Temporizador estrito**: com o app em segundo plano, o App Nap junta os
            // `asyncAfter` — medido em 14/09, as ações chegaram até 1 s atrasadas, e duas marcadas
            // com 0,7 s de distância saíram no mesmo milissegundo (um "segurar" de 0,7 s virou zero).
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            t.schedule(deadline: .now() + segundos, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.executar(acao) }
            t.resume()
            acoesAgendadas.append(t)
        }
        registrar("bancada: \(lidas.acoes.count) ação(ões) agendada(s)")
    }

    private func executar(_ a: AcaoDeBancada) {
        guard tela != .fechada else { return }
        switch a {
        case .texto(let t): registrar("bancada: ação texto=\(t.utf8.count) bytes")
        case .acrescentar(let l): registrar("bancada: ação acrescentar=\(l.utf8.count) bytes")
        default: registrar("bancada: ação sem texto")
        }
        // Pelo mesmo caminho dos botões — mas sem o limitador, que atrasaria a medida.
        switch a {
        case .fonte(let v):
            if fonteAutomatica { fonteAutomatica = false }
            editar("fonte=\(v)") { $0.definirFonte(v) }
        case .fonteAutomatica(let v): fonteAutomatica = v
        case .enquadrar(let e, let d):
            if tela == .prompter, let vista {
                let esquerda = vista.simularArrastoDoQuadro(.esquerda, ate: e)
                let direita = vista.simularArrastoDoQuadro(.direita, ate: d)
                registrar("bancada: enquadrar \(e)/\(d): \(esquerda) · \(direita)")
            }
        case .margem(let v): editar("margem=\(v)") { $0.definirMargem(v) }
        case .linha(let v): editar("linha=\(v)") { $0.definirLinhaDeLeitura(v) }
        case .arrastarLinha(let v):
            if tela == .prompter, let vista {
                registrar("bancada: arrastar a linha de leitura até \(v): \(vista.simularArrastoDaLinha(ate: v))")
            }
        case .velocidade(let v): editar("velocidade=\(v)") { $0.definirVelocidade(v) }
        case .espelho(let v): editar("espelho=\(v)") { $0.definirEspelho(v) }
        case .rolando(let v): editar("rolando=\(v)") { $0.definirRolando(v) }
        case .salto(let v): saltar(v)
        case .pular(let v): pular(v)
        case .texto(let t): aplicarTextoLocal(t)
        case .modoSegurar(let v):
            segurarParaRolar = v
            // A janela dos botões, para a bancada capturar só ela (`screencapture -l`).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Registro.compartilhado.linha("janela: modo segurar \(v ? "ligado" : "desligado") — \(Janela.inventario())")
            }
        case .mouseDoSegurar(let gesto, let botao):
            // Pelos três métodos do mouse da vista do botão, com eventos sintéticos — o mesmo
            // caminho do dedo no trackpad.
            guard let v = vistasDoSegurar[botao]?.objeto, v.window != nil else {
                registrar("!! bancada: o botão \(botao.rawValue) não está na tela (o modo está ligado e o controle, no painel?)")
                return
            }
            registrar("bancada: mouse-\(gesto.rawValue) em \"\(botao.rotulo)\": \(v.simular(gesto))")
        case .teclaDoSegurar(let gesto, let botao):
            registrar("bancada: tecla-\(gesto.rawValue) \(botao == .cima ? "↑" : "↓"): \(simularTecla(gesto, botao))")
        case .inverterBotoes(let v):
            definirInversao(v)
        case .escolha(let meu):
            // Pelo mesmo método dos dois botões, com o resumo que a caixa mostra agora. Sem a caixa
            // aberta ainda, a escolha fica armada e responde quando ela abrir — a bancada que dá
            // texto ao controle antes de conectar não fica parada esperando um dedo (§11.7).
            let caixa = caixaDaPergunta
            if caixa.escolhasLigadas, let visto = caixa.resumoMostrado {
                escolherTexto(manterOMeu: meu, resumoVisto: visto, porque: "bancada: escolha=\(meu ? "meu" : "prompter")")
            } else {
                escolhaArmada = meu
                registrar("bancada: escolha=\(meu ? "meu" : "prompter") armada — a caixa está em \(Teleprompter.descrever(caixa)); "
                          + "responde quando ela abrir")
            }
        case .roteirosGuardados(let abrir):
            if abrir { abrirRoteiros() } else { fecharRoteiros() }
        case .copia(let gesto):
            let copias = estado.copiasDoTexto
            func resumo(_ n: Int) -> String? { n >= 1 && n <= copias.count ? copias[n - 1].resumo : nil }
            switch gesto {
            case .ver(let n), .usar(let n), .apagar(let n):
                guard let r = resumo(n) else {
                    registrar("!! bancada: não há cópia \(n) (a lista tem \(copias.count))")
                    return
                }
                switch gesto {
                case .ver: verCopia(r)
                case .usar: pedirUsarCopia(r)
                default: pedirApagarCopia(r)
                }
            case .confirmar: confirmarCopia()
            case .cancelar: cancelarCopia()
            case .voltar: fecharCopiaVista()
            }
            // O alerta e a folha são janelas: o número delas vai para o registro.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Registro.compartilhado.linha("janela: roteiros guardados — \(Janela.inventario())")
            }
        case .perderOFoco:
            perdeuOFoco(porque: "a janela perdeu o foco (bancada: foco=0)")
        case .acrescentar(let l):
            let separador = texto.isEmpty || texto.hasSuffix("\n") ? "" : "\n"
            aplicarTextoLocal(texto + separador + l)
        case .rascunho(let l):
            guard editorAberto else { registrar("!! rascunho+ com o editor fechado"); return }
            let separador = rascunho.rascunho.isEmpty || rascunho.rascunho.hasSuffix("\n") ? "" : "\n"
            rascunho.rascunho += separador + l
        case .editor(let comando):
            switch comando {
            case .abrir:
                abrirEditor()
                // A folha é outra janela: o número dela vai para o registro, para a bancada poder
                // capturar só ela (`screencapture -l`).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Registro.compartilhado.linha("janela: editor aberto — \(Janela.inventario())")
                }
            case .confirmar: confirmarEditor()
            case .cancelar: cancelarEditor()
            case .usarNovo: usarOTextoNovo()
            case .manterMeu: manterOMeu()
            }
            registrar("editor: \(comando.rawValue) → aberto=\(editorAberto) conflito=\(rascunho.emConflito) "
                      + "rascunho=\(rascunho.bytes) bytes texto=\(texto.utf8.count) bytes")
        }
    }

    /// Bancada: uma seta com um evento sintético, pelo **mesmo tratador** das teclas de verdade
    /// (`AtalhosDoTeleprompter.processar`). A janela é a do app, e não a `keyWindow`: numa corrida sem
    /// ninguém no teclado outro app pode estar na frente.
    private func simularTecla(_ gesto: GestoDaTecla, _ botao: BotaoDeSegurar) -> String {
        guard let janela = NSApp.windows.first(where: { Janela.ehDeConteudo($0) && $0.isVisible && !$0.isSheet }) else {
            return "sem janela"
        }
        let seta = String(Character(UnicodeScalar(botao == .cima ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!))
        guard let e = NSEvent.keyEvent(with: gesto == .sobe ? .keyUp : .keyDown, location: .zero,
                                       modifierFlags: [.function, .numericPad],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: janela.windowNumber, context: nil,
                                       characters: seta, charactersIgnoringModifiers: seta,
                                       isARepeat: gesto == .repete, keyCode: botao.codigoDaTecla) else {
            return "sem evento"
        }
        let consumida = atalhos.processar(e, janela: janela) == nil
        return "\(consumida ? "consumida" : "passou adiante") — apertos=[\(segurar.apertos.map { "\($0.fonte.rawValue):\($0.botao.rawValue)" }.joined(separator: " "))]"
    }

    // MARK: - os conselhos

    /// A frase da tela para cada falha, **pelo código**, nunca pelo texto do núcleo — que só
    /// aparece como complemento.
    static func conselho(papel: PapelDoTeleprompter, status: StatusDaFronteira, motivo: String,
                         decisao: DecisaoDoLaco, jaHouveSessao: Bool, porta: UInt16) -> String {
        let parou = decisao == .parar
        switch papel {
        case .prompter:
            switch status {
            case .pinErrado, .pareamento:
                return parou
                    ? T("Cinco tentativas seguidas com o PIN errado: a espera parou, para ninguém ficar "
                      + "adivinhando o PIN. Toque em Esperar de novo.")
                    : T("Um aparelho tentou entrar com o PIN errado. O PIN mudou: passe os seis dígitos novos.")
            case .prazo, .cancelado:
                return ""
            case .precisaDePin:
                return T("Um aparelho tentou entrar com um pareamento que este Mac não reconhece mais: ele "
                    + "precisa digitar o PIN.")
            case .protocolo:
                return T("Um aparelho que não é controle do Quall Studio, ou de outra versão, tentou entrar e foi recusado.")
            case .io:
                return T("Não consegui abrir a porta %@ (%@). Tentando de novo.", porta, motivo)
            case .sinalizacao:
                return parou ? T("A espera parou: %@", motivo) : T("A sinalização falhou (%@). Tentando de novo.", motivo)
            default:
                return parou ? T("A espera parou: %@", motivo) : motivo
            }
        case .controle:
            switch status {
            case .pinErrado:
                return T("PIN errado. Confira os seis dígitos na tela do prompter e conecte de novo — cada "
                    + "tentativa vale por uma conexão, e o PIN do prompter muda depois de um erro.")
            case .precisaDePin:
                return T("O prompter não reconhece mais este Mac. Digite o PIN que a tela dele mostra.")
            case .pareamento:
                return T("O pareamento não fechou. Confira o PIN na tela do prompter e tente de novo.")
            case .protocolo, .sinalizacao:
                return T("Esse aparelho não aceitou este Mac como controle: %@", motivo)
            case .ocupado:
                return parou
                    ? T("O prompter já tem outro controle conectado.")
                    : T("O prompter ainda está com a sessão anterior — tentando de novo (ele percebe a queda em até 5 s).")
            case .cancelado:
                return ""
            case .io, .prazo:
                return jaHouveSessao
                    ? T("Conexão perdida — tentando de novo. Os comandos vão quando a conexão voltar.")
                    : T("Ninguém atendeu neste endereço. Confira se o prompter está aberto e se o endereço e a porta estão certos.")
            case .semRota:
                return jaHouveSessao
                    ? T("Conexão perdida — tentando de novo. Os comandos vão quando a conexão voltar.")
                    : T("Os dois aparelhos não acharam caminho um até o outro. Confira se estão na mesma rede.")
            default:
                return jaHouveSessao
                    ? T("Conexão perdida (%@) — tentando de novo.", status.nome)
                    : T("Não deu para conectar: %@", motivo.isEmpty ? status.nome : motivo)
            }
        }
    }
}
