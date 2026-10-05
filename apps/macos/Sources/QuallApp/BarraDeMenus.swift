import AppKit
import QuallBarraDeMenusKit
import QuallIdiomaKit

/// **O Quall na barra de menus** (01/10/2026). O pedido do Pessoa Exemplo: *"No Windows e Mac deixar o Quall
/// minimizado no tray"* — ele usava a tela estendida (Mac → tablet e A07) havia mais de uma hora e
/// queria o app fora do caminho, com as sessões vivas. Até aqui o Mac nunca teve ícone na barra
/// (`docs/ux-m6.md` §1.6 desenhou, `docs/app-macos.md` deixou de fora).
///
/// # O que faz
///
/// - **O ícone** fica na barra enquanto o app roda: a marca (anel com o corte e a bolinha), modelo
///   quando nada está no ar e com a bolinha **vermelha** quando algo deste Mac está indo para outro
///   aparelho (`SituacaoNaBarra.noAr`, `MarcaNaBarra`).
/// - **O menu**: as linhas de estado (desabilitadas), "Abrir o Quall Studio" e "Sair do Quall Studio" (⌘Q, o mesmo
///   `terminate` de sempre — e portanto o mesmo `applicationShouldTerminate`, que espera o arquivo da
///   câmera fechar).
/// - **Minimizar → barra**: o botão amarelo e o ⌘M (Janela > Minimizar) da janela **principal** a
///   tiram da tela com `orderOut` — não `miniaturize` — e, sem outra janela à mostra, o ícone sai do
///   Dock (`.accessory`). **Nada é encerrado**: a janela e a árvore de vistas continuam existindo, e o
///   `Emissor`, o `Receptor` e o `Teleprompter` nem ficam sabendo.
/// - **Voltar**: "Abrir o Quall Studio", ou o Dock quando ele está lá (`applicationShouldHandleReopen`, que o
///   delegado do SwiftUI repassa — medido numa sonda em 01/10), ou abrir o `Quall.app` de novo.
///
/// # O que não faz
///
/// - **O botão vermelho não mudou**: fecha a janela, e o app e as sessões seguem, com o ícone no Dock
///   (o comportamento de antes; ver `docs/teleprompter-com-camera.md`, "Não consertados": o ⌘W deixa a
///   câmera aberta sem interface). O que mudou é a volta: "Abrir o Quall Studio" recria a janela
///   (`Janela.abrirNova`).
/// - As outras janelas (o "Controle do teleprompter", os Ajustes) minimizam para o Dock como sempre.
/// - Em tela cheia, com uma folha aberta, sem o ícone à vista (inclusive atrás do entalhe) ou com a
///   janela mostrando o texto do prompter, o minimizar é o de sempre (`RegraDaBarra.minimizar`).
///
/// # Três cuidados da revisão de 01/10
///
/// - **App Nap**: escondido, em `.accessory` e com `hide`, o app é o caso clássico, e o App Nap já foi
///   medido atrasando temporizadores aqui (14/09). Enquanto houver sessão de pé (`sessaoDePe`, tudo o
///   que não é "Pronto"), o processo segura uma atividade `[.userInitiated, .latencyCritical]`; em
///   "Pronto", solta. Efeito colateral, escolhido: com sessão de pé o Mac não dorme sozinho (a tela
///   pode apagar).
/// - **O aviso da primeira vez**: o `isVisible` do ícone não sabe do entalhe nem do ícone desligado nos
///   ajustes da barra do macOS 26. Então, na primeira ida para a barra (guardada em
///   `UserDefaults`, onde o app guarda as preferências), uma folha diz onde o Quall ficou e como
///   voltar, antes de esconder. O entalhe é conferido pela geometria (`RegraDaBarra.atrasDoEntalhe`);
///   a oclusão da janela do ícone **não** serve (medido: falsa com o ícone no lugar).
/// - **A volta dentro de uma tela**: escondida num monitor virtual que sumiu, a janela volta no meio da
///   tela principal (`Janela.aparecer`, `RegraDaBarra.quadroDeVolta`).
///
/// # Como o minimizar é tomado (e por que por três portas)
///
/// O SwiftUI é o dono da janela e do delegado dela, então não há `windowShouldMiniaturize` a responder.
/// - **O botão amarelo**: alvo e ação trocados (`cuidarDaPrincipal`), reaplicados a cada segundo e a
///   cada vez que a janela vira chave — o SwiftUI pode refazer a barra de título.
/// - **Janela > Minimizar**: o item do sistema fica onde está, com o título e a tradução dele; só o
///   **alvo** passa a ser este objeto (`performMiniaturize(_:)`, a mesma ação). O SwiftUI pode refazer o
///   menu; o alvo é retomado ao abrir qualquer menu, a cada janela que vira chave e a cada segundo. Se
///   ele escapar, o clique cai no minimizar de sempre — o comportamento de antes, nunca pior.
/// - **O ⌘M pelo teclado**: um monitor local de teclas, que não depende do alvo do item estar no lugar.
final class BarraDeMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static weak var atual: BarraDeMenus?

    private let item: NSStatusItem
    private let menu = NSMenu()
    private var itensDoEstado: [NSMenuItem] = []
    private let imagemPronto = MarcaNaBarra.imagem(noAr: false)
    private let imagemNoAr = MarcaNaBarra.imagem(noAr: true)
    private var ultima: SituacaoNaBarra?
    /// O idioma das linhas mostradas: a situação igual num idioma novo também redesenha (o seletor PT | EN).
    private var idiomaDasLinhas = Idioma.atual
    private var relogio: Timer?
    private var monitorDoTeclado: Any?
    private var observadores: [NSObjectProtocol] = []

    /// A principal foi escondida **por nós** (`orderOut`), e não fechada.
    private(set) var principalNaBarra = false
    /// Os Ajustes da câmera estavam à mostra e foram escondidos junto da principal: voltam com ela.
    private var ajustesDaCameraEscondidos: [JanelasDeAjustes.Tipo] = []
    /// A atividade que segura o App Nap, enquanto houver sessão de pé.
    private var atividade: NSObjectProtocol?
    /// O aviso da primeira vez está na tela: os pedidos de minimizar esperam ele fechar.
    private var avisoAberto = false
    /// "Abrir o Quall Studio" e "Sair do Quall Studio", guardados para o título seguir o idioma da vez.
    private var abrir = NSMenuItem()
    private var sair = NSMenuItem()
    /// A primeira ida para a barra já foi avisada (`UserDefaults`, como as outras preferências do app).
    static let chaveDoAviso = "barra.avisoDaPrimeiraVez"

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        BarraDeMenus.atual = self
        // Lembra a posição que a pessoa escolher (⌘-arrastar). Sem `.removalAllowed` no `behavior`: um
        // ícone arrastado para fora deixaria um app escondido sem volta.
        item.autosaveName = "quall.barra"
        if let b = item.button {
            b.image = imagemPronto
            b.imagePosition = .imageOnly
            b.toolTip = "Quall Studio"
            b.setAccessibilityLabel("Quall Studio")
        }
        montarMenu()
        item.menu = menu
        atualizar()

        let c = NotificationCenter.default
        // Uma janela que fecha com a principal na barra pode ser a última à mostra: o Dock sai. Na volta
        // do laço, porque no `willClose` ela ainda está na tela.
        observadores.append(c.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.principalNaBarra else { return }
            DispatchQueue.main.async { self.reavaliarODock() }
        })
        observadores.append(c.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cuidarDaPrincipal(Janela.principal)
            self?.tomarOMinimizarDoMenu()
        })
        observadores.append(c.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cuidarDaPrincipal(Janela.principal)
        })
        observadores.append(c.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tomarOMinimizarDoMenu()
        })

        monitorDoTeclado = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "m",
                  let chave = NSApp.keyWindow, self.ehDaPrincipal(chave) else { return e }
            // Em tela cheia a regra diz "nada": o ⌘M segue para o menu, que está desligado ali.
            return self.minimizar(chave, origem: "⌘M") ? nil : e
        }

        // Uma vez por segundo: a cor da bolinha e as linhas, e as duas tomadas do minimizar.
        let r = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tique() }
        r.tolerance = 0.3
        RunLoop.main.add(r, forMode: .common)
        relogio = r

        cuidarDaPrincipal(Janela.principal)
        tomarOMinimizarDoMenu()
        Registro.compartilhado.linha("barra de menus: ícone criado — \(ultima?.linhas.joined(separator: " · ") ?? "")")
    }

    // MARK: - o estado

    private func tique() {
        atualizar()
        cuidarDaPrincipal(Janela.principal)
        tomarOMinimizarDoMenu()
        // Alguém trouxe a principal de volta por outro caminho (o menu Janela, o SwiftUI): ela não está
        // mais na barra, e o Dock volta.
        if principalNaBarra, Janela.principal?.isVisible ?? true {
            principalNaBarra = false
            reavaliarODock()
        }
    }

    private func atualizar() {
        let s = BarraDeMenus.situacao()
        acertarAtividade(s)
        guard s != ultima || idiomaDasLinhas != Idioma.atual else { return }
        idiomaDasLinhas = Idioma.atual
        let antes = ultima
        ultima = s
        let texto = s.linhas.joined(separator: " · ")
        if let b = item.button {
            b.image = s.noAr ? imagemNoAr : imagemPronto
            b.toolTip = "Quall Studio — " + texto
            b.setAccessibilityLabel(s.noAr ? T("Quall Studio, no ar: %@", texto) : "Quall Studio: " + texto)
        }
        mostrarLinhas(s.linhas)
        if antes != nil {
            Registro.compartilhado.linha("barra de menus: \(texto)\(s.noAr ? " [no ar]" : "")")
        }
    }

    /// Segura o App Nap com sessão de pé e solta em "Pronto" (`RegraDaBarra.atividade`), com uma linha
    /// no registro a cada troca.
    private func acertarAtividade(_ s: SituacaoNaBarra) {
        switch RegraDaBarra.atividade(segurando: atividade != nil, sessaoDePe: s.sessaoDePe) {
        case .segurar:
            let texto = s.linhas.joined(separator: " · ")
            atividade = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Quall: sessão de pé (\(texto))")
            Registro.compartilhado.linha("barra de menus: App Nap segurado (userInitiated, latencyCritical) — \(texto)")
        case .soltar:
            if let a = atividade { ProcessInfo.processInfo.endActivity(a) }
            atividade = nil
            Registro.compartilhado.linha("barra de menus: App Nap solto — Pronto")
        case .manter:
            break
        }
    }

    /// O que o app está fazendo, lido dos três modelos (só na main).
    static func situacao() -> SituacaoNaBarra {
        var s = SituacaoNaBarra()
        if let e = Emissor.atual {
            let f = e.fonteEscolhida
            #if QUALL_TELA_ESTENDIDA_FUTURA
            let origem: SituacaoNaBarra.Origem = f?.modoDaTelaEstendida != nil ? .telaEstendida
                : ((f?.ehTela ?? true) ? .tela : .camera)
            #else
            let origem: SituacaoNaBarra.Origem = (f?.ehTela ?? true) ? .tela : .camera
            #endif
            switch e.fase {
            case .inicial: break
            case .esperando: s.emissao = .esperando(origem)
            case .transmitindo: s.emissao = .noAr(origem, aparelhos: e.receptores.map(\.nome))
            case .encerrando: s.emissao = .encerrando
            }
        }
        if let r = Receptor.atual {
            switch r.fase {
            case .fechado, .formulario: break
            case .conectando: s.exibicao = .conectando
            case .esperandoTrack: s.exibicao = .esperandoImagem(de: r.par)
            case .exibindo: s.exibicao = .exibindo(r.par)
            case .encerrando: s.exibicao = .encerrando
            }
        }
        if let t = Teleprompter.atual {
            switch t.tela {
            case .fechada:
                break
            case .prompter:
                switch t.fase {
                case .abrindo: s.prompter = .esperandoOControle
                case .conectado: s.prompter = .controladoPor(t.par)
                case .semPar: s.prompter = .semOControle
                case .formulario: s.prompter = .parado
                case .encerrando: s.prompter = .saindo
                }
                if t.comCamera, let espera = t.camera?.espera {
                    switch espera.fase {
                    case .esperando: s.cameraDoTexto = .esperando
                    case .transmitindo: s.cameraDoTexto = .noAr(espera.par)
                    case .parada, .desistiu: break
                    }
                }
            case .controle:
                switch t.fase {
                case .formulario: break
                case .abrindo: s.controle = .conectando
                case .conectado: s.controle = .controlando(t.par)
                case .semPar: s.controle = .semConexao
                case .encerrando: s.controle = .saindo
                }
            }
        }
        return s
    }

    // MARK: - o menu

    private func montarMenu() {
        menu.delegate = self
        // As linhas de estado são desabilitadas à mão; "Abrir" e "Sair" ficam sempre ligados.
        menu.autoenablesItems = false
        menu.addItem(.separator())
        abrir = NSMenuItem(title: T("Abrir o Quall Studio"), action: #selector(abrirOQuall(_:)), keyEquivalent: "")
        abrir.target = self
        menu.addItem(abrir)
        menu.addItem(.separator())
        // O mesmo caminho do ⌘Q do app: `terminate` → `applicationShouldTerminate`.
        sair = NSMenuItem(title: T("Sair do Quall Studio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        sair.target = NSApp
        menu.addItem(sair)
    }

    private func mostrarLinhas(_ linhas: [String]) {
        for i in itensDoEstado { menu.removeItem(i) }
        itensDoEstado = linhas.enumerated().map { k, texto in
            let i = NSMenuItem(title: texto, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.insertItem(i, at: k)
            return i
        }
    }

    /// O menu abre sempre com o estado de agora, sem esperar o segundo do relógio.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // No idioma da vez: o seletor PT | EN pode ter trocado depois de o menu ser montado.
        abrir.title = T("Abrir o Quall Studio")
        sair.title = T("Sair do Quall Studio")
        atualizar()
    }

    // MARK: - minimizar

    /// A principal, ou uma folha presa a ela.
    private func ehDaPrincipal(_ janela: NSWindow) -> Bool {
        guard let p = Janela.principal else { return false }
        return (janela.sheetParent ?? janela) === p
    }

    private func decisao(para janela: NSWindow) -> (RegraDaBarra.Minimizar, NSWindow) {
        let alvo = janela.sheetParent ?? janela
        let principal = ehDaPrincipal(alvo)
        let d = RegraDaBarra.minimizar(ehAPrincipal: principal, emTelaCheia: alvo.styleMask.contains(.fullScreen),
                                       comFolha: alvo.attachedSheet != nil,
                                       minimizavel: alvo.styleMask.contains(.miniaturizable), iconeAVista: iconeAVista,
                                       mostraOTexto: principal && mostraOTexto)
        return (d, alvo)
    }

    /// A janela principal está mostrando o texto do prompter ("Mostrar o texto" ou "Texto com a câmera").
    private var mostraOTexto: Bool { Teleprompter.atual?.tela == .prompter }

    /// O ícone à vista, até onde dá para saber: o `isVisible` do item e, num painel com entalhe, o meio
    /// da janela do ícone à direita dele. O ícone desligado nos ajustes da barra do macOS 26 não é
    /// detectável por aqui (o aviso da primeira vez cobre esse caso).
    private var iconeAVista: Bool {
        guard item.isVisible else { return false }
        guard let w = item.button?.window, let tela = w.screen else { return true }
        return !RegraDaBarra.atrasDoEntalhe(icone: w.frame, ladoDireito: tela.auxiliaryTopRightArea)
    }

    /// Por que a principal foi para o Dock, e não para a barra (para o registro).
    private func motivoDoDock(_ alvo: NSWindow) -> String {
        if alvo.attachedSheet != nil { return "folha aberta" }
        if mostraOTexto { return "a janela mostra o texto do prompter" }
        if !item.isVisible { return "ícone fora de vista (isVisible falso)" }
        if let w = item.button?.window, let t = w.screen {
            return "ícone atrás do entalhe (meio em x=\(Int(w.frame.midX)), "
                + "área da direita \(t.auxiliaryTopRightArea.map { "\(Int($0.minX))–\(Int($0.maxX))" } ?? "nenhuma"))"
        }
        return "ícone fora de vista"
    }

    /// Devolve se fez alguma coisa.
    @discardableResult
    private func minimizar(_ janela: NSWindow?, origem: String) -> Bool {
        guard let janela else { return false }
        // O aviso da primeira vez está aberto: o pedido espera (o OK dele é que esconde).
        if avisoAberto { return true }
        let (d, alvo) = decisao(para: janela)
        switch d {
        case .nada:
            return false
        case .minimizarNoDock:
            // `miniaturize`, e **não** `performMiniaturize`: este simula o clique no botão amarelo, cujo
            // alvo é este objeto — e voltaria aqui para sempre.
            if ehDaPrincipal(alvo) {
                Registro.compartilhado.linha("barra de menus: \(origem) minimizou a principal para o Dock, "
                                             + "e não para a barra: \(motivoDoDock(alvo))")
            }
            alvo.miniaturize(nil)
            return true
        case .esconderNaBarra:
            if UserDefaults.standard.bool(forKey: BarraDeMenus.chaveDoAviso) {
                esconderNaBarra(alvo, origem: origem)
            } else {
                avisarEEsconder(alvo, origem: origem)
            }
            return true
        }
    }

    /// O botão amarelo da principal.
    @objc private func botaoAmarelo(_ sender: Any?) {
        minimizar(Janela.principal, origem: "o botão amarelo")
    }

    /// Janela > Minimizar (o item do sistema, com este objeto como alvo; a ação é a mesma).
    @objc func performMiniaturize(_ sender: Any?) {
        if !minimizar(NSApp.keyWindow, origem: "Janela > Minimizar") { NSSound.beep() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performMiniaturize(_:)) else { return true }
        guard let chave = NSApp.keyWindow else { return false }
        return decisao(para: chave).0 != .nada
    }

    /// O botão amarelo da principal passa a chamar `botaoAmarelo`. Idempotente.
    func cuidarDaPrincipal(_ janela: NSWindow?) {
        guard let b = janela?.standardWindowButton(.miniaturizeButton) else { return }
        if b.target !== self || b.action != #selector(botaoAmarelo(_:)) {
            b.target = self
            b.action = #selector(botaoAmarelo(_:))
        }
    }

    /// O item Janela > Minimizar (achado pela ação, onde quer que o SwiftUI o ponha) passa a ter este
    /// objeto como alvo. Idempotente; o título, o atalho e a posição continuam os do sistema.
    private func tomarOMinimizarDoMenu() {
        guard let principal = NSApp.mainMenu else { return }
        func varrer(_ m: NSMenu) {
            for i in m.items {
                if i.action == #selector(NSWindow.performMiniaturize(_:)), i.target !== self { i.target = self }
                if let sub = i.submenu { varrer(sub) }
            }
        }
        varrer(principal)
    }

    // MARK: - esconder e voltar

    /// **A primeira ida para a barra**: uma folha curta diz onde o Quall ficou e como voltar, e só o OK
    /// esconde. Folha, e não `runModal`: o laço da main segue livre para as sessões.
    private func avisarEEsconder(_ janela: NSWindow, origem: String) {
        avisoAberto = true
        let aviso = NSAlert()
        aviso.alertStyle = .informational
        aviso.messageText = T("O Quall Studio continua rodando na barra de menus, no ícone do Q.")
        aviso.informativeText = T("Para voltar, clique nele ou abra o Quall Studio de novo.")
        aviso.addButton(withTitle: "OK")
        Registro.compartilhado.linha("barra de menus: primeira ida para a barra (\(origem)) — o aviso antes de esconder")
        aviso.beginSheetModal(for: janela) { [weak self, weak janela] _ in
            UserDefaults.standard.set(true, forKey: BarraDeMenus.chaveDoAviso)
            guard let self else { return }
            self.avisoAberto = false
            guard let janela, Janela.principal === janela, !janela.styleMask.contains(.fullScreen) else { return }
            self.esconderNaBarra(janela, origem: origem + ", depois do aviso")
        }
    }

    private func esconderNaBarra(_ janela: NSWindow, origem: String) {
        janela.orderOut(nil)
        principalNaBarra = true
        // **Os Ajustes da câmera vão junto** (R9, `docs/controles-de-camera.md` §4.2): sem a prévia à
        // vista, ajustar a câmera não serve, e a janela solta seguraria o ícone no Dock. Volta com a
        // principal (`abrirOQuall`).
        // A da câmera do outro lado (R9b) também: ela ajusta o vídeo que a principal mostra.
        for tipo in [JanelasDeAjustes.Tipo.ajustesDaCamera, .ajustesDaCameraRemota] {
            if let camera = JanelasDeAjustes.janela(tipo), camera.isVisible {
                camera.orderOut(nil)
                ajustesDaCameraEscondidos.append(tipo)
                Registro.compartilhado.linha("barra de menus: os Ajustes da câmera foram junto para a barra")
            }
        }
        Registro.compartilhado.linha("barra de menus: a janela principal foi para a barra (\(origem)) — "
                                     + "nada encerrado: \(ultima?.linhas.joined(separator: " · ") ?? "")")
        reavaliarODock()
    }

    /// "Abrir o Quall Studio", o Dock com a principal na barra, ou o `Quall.app` aberto de novo.
    @objc func abrirOQuall(_ sender: Any?) {
        let estava = principalNaBarra
        principalNaBarra = false
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        for tipo in ajustesDaCameraEscondidos { JanelasDeAjustes.janela(tipo)?.orderFront(nil) }
        ajustesDaCameraEscondidos = []
        if Janela.principal != nil {
            Janela.aparecer()
        } else if let abrirNova = Janela.abrirNova {
            // Fechada no X: o SwiftUI cria outra, a raiz dela se marca como principal, e então ela vem
            // para a frente.
            abrirNova()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if Janela.principal != nil { Janela.aparecer() }
            }
        } else {
            Janela.aparecerEDizer()
        }
        // De `.accessory` para `.regular` o AppKit às vezes só mostra a barra de menus do app na segunda
        // ativação: uma a mais, na volta do laço.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Registro.compartilhado.linha("barra de menus: \"Abrir o Quall Studio\"\(estava ? " (estava na barra)" : "") — "
                                         + Janela.inventario())
        }
    }

    /// A principal fechou (X ou ⌘W): ela não está mais "na barra", e o Dock é o de sempre.
    func principalFechou() {
        principalNaBarra = false
        DispatchQueue.main.async { self.reavaliarODock() }
    }

    /// O ícone do Dock segue `RegraDaBarra.dock`. Quando ele sai, o app também se esconde (`hide`): um
    /// app em `.accessory` que continua ativo fica sem barra de menus e sem janela, com o teclado indo
    /// para lugar nenhum; escondido, o sistema ativa o app de baixo, como no ⌘H.
    func reavaliarODock() {
        let principal = Janela.principal
        let outras = NSApp.windows.filter { j in
            j !== principal && j.sheetParent !== principal && j.parent !== principal
                && Janela.ehDeConteudo(j) && (j.isVisible || j.isMiniaturized)
        }.count
        let regra = RegraDaBarra.dock(principalNaBarra: principalNaBarra, outrasJanelas: outras,
                                      iconeAVista: item.isVisible)
        let politica: NSApplication.ActivationPolicy = regra == .soNaBarra ? .accessory : .regular
        guard NSApp.activationPolicy() != politica else { return }
        NSApp.setActivationPolicy(politica)
        if politica == .accessory { NSApp.hide(nil) }
        Registro.compartilhado.linha(politica == .accessory
            ? "barra de menus: sem janela à mostra — o ícone sai do Dock"
            : "barra de menus: o ícone volta ao Dock (\(outras) outra(s) janela(s) à mostra ou a principal de volta)")
    }
}
