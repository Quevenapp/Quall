import AppKit
import CQuall
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit
import SwiftUI

extension Notification.Name {
    /// Pedido de encerramento vindo de `--sair-apos`. Passa pelo `NotificationCenter` porque quem
    /// sabe desmontar a sessão é o `Emissor`, e ele vive dentro da cena — não do `init` do `App`.
    static let quallDeveSair = Notification.Name("quall.deve.sair")
}

/// O app macOS de produto — a janela que faltava.
///
/// Até esta rodada `apps/macos` era biblioteca mais duas CLIs de bancada (`quall-capture`,
/// `quall-net-smoke`): ferramenta, não produto. O M6 fechou o polimento de UX sem que houvesse
/// janela para polir neste lado. `docs/ux-m6.md` §1.6 deixou o desenho pronto no papel; isto é a
/// implementação dele.
///
/// # Este binário precisa rodar de dentro de um `.app`
///
/// Não é preciosismo de empacotamento: é o que decide de quem o macOS cobra as permissões. O TCC
/// atribui o pedido ao **processo responsável**, e um binário lançado por `exec` de um shell
/// herda o responsável de quem abriu o shell — o Terminal, ou o agente de bancada. O diálogo sai
/// com o nome errado e a permissão de câmera acaba concedida a um programa que não é o produto.
/// Pelo LaunchServices (`open -n -W -a Quall.app`) o app é o próprio responsável e a linha em
/// Ajustes do Sistema sai com o nome dele. Ver `apps/macos/Empacotar/empacotar.sh` e
/// `docs/regras-de-frente.md`.
struct AplicativoQuall: App {
    @NSApplicationDelegateAdaptor(DelegadoDoApp.self) private var delegado
    @StateObject private var emissor = Emissor()
    /// A outra metade do produto, desde 2026-08-30. Vive ao lado do `Emissor` e não dentro dele:
    /// os dois nunca estão ativos ao mesmo tempo — `tracks` só vale em `quall_host`, e quem chama
    /// `quall_connect` não emite naquela sessão (dívida 1) —, mas os dois existem o processo
    /// inteiro para que a janela possa ir e voltar entre os dois fluxos sem recriar estado.
    @StateObject private var receptor = Receptor()
    /// O teleprompter (`docs/contrato-teleprompter.md`): as duas telas — mostrar o texto e
    /// controlar. Uma terceira metade, ao lado das duas de vídeo, e pelo mesmo motivo: existe o
    /// processo inteiro, e as réplicas dele (uma por papel) atravessam as sessões.
    @StateObject private var teleprompter = Teleprompter()

    init() {
        let args = Argumentos.lidos()
        Registro.compartilhado.abrir(caminho: args.registro)
        Registro.compartilhado.linha(
            "quall-app iniciou — protocolo=\(QuallNetKit.NucleoDeRede.versaoDoProtocolo()) "
            + "bancada=\(args.modoDeBancada)")

        // **A janela existe? Esta linha é a primeira testemunha disso na história deste app.**
        //
        // A rodada anterior fechou dizendo "não afirmo que a janela apareceu na tela", e ninguém
        // jamais a contradisse. Para um emissor isso é lacuna de relato; para um **receptor** é a
        // diferença entre funcionar e não funcionar, porque sem janela não há vista, sem vista a
        // camada de exibição fica fora da árvore, e ela **aceita todo quadro sem desenhar nada**.
        // Ver `Janela` para a causa que esta linha desenterrou em 2026-08-30.
        //
        // Meio segundo depois do arranque, porque a cena do SwiftUI é montada depois do `init` do
        // `App` — pedir agora seria pedir para uma lista de janelas vazia.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Janela.aparecerEDizer()
        }

        if let segundos = args.sairApos {
            // O que faz `open -n -W` voltar. Sem isto, uma corrida de bancada penduraria o
            // chamador para sempre e a única saída seria matar o processo por fora — que é
            // exatamente o jeito de perder o desmontar da sessão e o adeus do mDNS.
            DispatchQueue.main.asyncAfter(deadline: .now() + segundos) {
                Registro.compartilhado.linha("--sair-apos \(segundos)s: encerrando")
                NotificationCenter.default.post(name: .quallDeveSair, object: nil)
                // O `encerrar()` desmonta cada sessão numa thread própria; com vários receptores são
                // vários desmontes, e as linhas finais de cada um (`fim da captura`, `sessao
                // encerrada`) são o que a bancada lê. Então: esperar o emissor voltar ao começo, com
                // teto de 15 s, e não um tempo fixo que servia a uma sessão só (revisão de 10/09).
                let inicio = Date()
                func sairQuandoDesmontar() {
                    // Os dois papéis, e a fila do mDNS: o adeus do anúncio também tem de sair.
                    let emissorPronto = (Emissor.atual?.fase ?? .inicial) == .inicial
                        && (Emissor.atual?.anuncioOcioso ?? true)
                    let faseDoReceptor = Receptor.atual?.fase ?? .fechado
                    // O teleprompter também: a sessão fecha na ordem do contrato, o roteiro é
                    // gravado, a asserção de tela acesa é solta e o adeus do mDNS sai.
                    // E a tela com câmera: a gravação fecha o arquivo, a sessão de vídeo desmonta e o
                    // dono fecha a câmera e o microfone.
                    let teleprompterPronto = (Teleprompter.atual?.ocioso ?? true) && TelaComCamera.emFecho == 0
                        && (Teleprompter.atual?.camera?.espera?.anuncioOcioso ?? true)
                    let pronto = emissorPronto && teleprompterPronto
                        && (faseDoReceptor == .fechado || faseDoReceptor == .formulario)
                    if pronto || Date().timeIntervalSince(inicio) > 15 {
                        // Meio segundo a mais para o registro de quem acabou de fechar.
                        DispatchQueue.main.asyncAfter(deadline: .now() + (pronto ? 0.5 : 0)) {
                            Registro.compartilhado.linha(pronto ? "saindo" : "saindo sem esperar o desmonte (15 s)")
                            Registro.compartilhado.fechar()
                            NSApplication.shared.terminate(nil)
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { sairQuandoDesmontar() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sairQuandoDesmontar() }
            }
        }
    }

    var body: some Scene {
        // Com `id` desde 01/10: é por ele que "Abrir o Quall Studio", na barra de menus, recria a janela depois
        // de ela ser fechada no X (`Janela.abrirNova`). O SwiftUI guarda o lugar da janela pelo `id` da
        // cena, então a primeira abertura depois da troca esquece onde ela estava.
        WindowGroup("Quall Studio", id: Janela.idDaPrincipal) {
            ComAbrirAjustes {
                RaizDaJanela()
            }
            .environmentObject(emissor)
            .environmentObject(receptor)
            .environmentObject(teleprompter)
        }
        // O tamanho acompanha o conteúdo: o estúdio pede no mínimo 880 × 580 (`docs/telas-estudio.md`
        // §7), o vídeo 520 × 400 (§11.4) e o prompter o dele.
        .windowResizability(.contentSize)
        // **Sem a barra de título** (§7: a barra lateral sobe até o alto, com os três botões da
        // janela por cima dela). A primeira janela de verdade (30/09) saiu com a barra cinza
        // (36, 39, 42) e "Quall" por cima da barra lateral: o `titlebarAppearsTransparent` da
        // `JanelaEscura` não pega no macOS 26 (medido na foto da janela). O conteúdo continua dentro
        // da área segura — a marca, o texto do prompter e o vídeo ficam abaixo dos botões; só os
        // fundos, que ignoram a área segura, sobem.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Sem "Nova Janela": duas janelas seriam duas sessões disputando o mesmo `pares.json`
            // e o mesmo `deviceId`, e o produto não tem o que fazer com isso.
            CommandGroup(replacing: .newItem) {}
        }

        // **M4** (`docs/teleprompter-com-camera.md` §12 e §8.9): o controle do teleprompter numa
        // janela própria, para o Mac receber o vídeo de um aparelho e controlar o texto de outro ao
        // mesmo tempo (o caminho de dois aparelhos, §10). Uma janela só (`Window`, não `WindowGroup`).
        Window(T("Controle do teleprompter"), id: JanelaDoControle.id) {
            JanelaDoControle()
                .environmentObject(teleprompter)
                .preferredColorScheme(.dark)
                .tint(Estilo.acento)
        }
        .windowResizability(.contentSize)

        // **Os ajustes da câmera** (R9, `docs/controles-de-camera.md` §4.2): uma janela própria, como a do
        // controle, aberta pelo botão junto da prévia. Ela ajusta o dono vivo (`DonoDaCamera.vigente`).
        Window(TextosDosAjustes.titulo, id: JanelaDosAjustesDaCamera.id) {
            NoIdiomaDaVez { JanelaDosAjustesDaCamera() }
                .preferredColorScheme(.dark)
                .tint(Estilo.acento)
        }
        .windowResizability(.contentSize)

        // **Os ajustes da câmera do outro lado** (R9b, `docs/controle-remoto-da-camera.md` §12): a mesma janela,
        // alimentada pelo estado remoto do receptor, aberta pela engrenagem da barra do vídeo recebido.
        Window(TextosDosAjustes.titulo, id: JanelaDosAjustesDaCameraRemota.id) {
            NoIdiomaDaVez { JanelaDosAjustesDaCameraRemota() }
                .environmentObject(receptor)
                .preferredColorScheme(.dark)
                .tint(Estilo.acento)
        }
        .windowResizability(.contentSize)

        // **Os Ajustes** (§7.5): ⌘, e a engrenagem da barra lateral.
        Settings {
            NoIdiomaDaVez { TelaDeAjustes() }
                .environmentObject(emissor)
                .environmentObject(receptor)
                .environmentObject(teleprompter)
                .preferredColorScheme(.dark)
                .tint(Estilo.acento)
        }
    }
}

/// **A entrada do processo.** Normalmente abre o app (`AplicativoQuall`); com
/// `--retratos-de-bancada=<pasta>`, desenha as telas com dados de exemplo em PNG e sai — sem janela,
/// sem sessão e sem pedir permissão nenhuma (ver `Retratos`). Separada do `App` porque o `App` cria
/// os modelos (e abre o `Registro`) antes de qualquer coisa.
@main
enum Entrada {
    @MainActor static func main() {
        // Antes dos modelos/FFI: pânico preserva origem e ocorrência, nunca payload livre.
        quall_install_panic_hook(nil, nil)
        if let pedido = CommandLine.arguments.first(where: { $0 == "--provar-sandbox" || $0.hasPrefix("--provar-sandbox=") }) {
            let partes = pedido.split(separator: "=", maxSplits: 1).last?.split(separator: ":", maxSplits: 1)
            let etapa = pedido == "--provar-sandbox" ? "simples" : String(partes?.first ?? "")
            let id = partes?.count == 2 ? String(partes![1]) : nil
            exit(ProvaDoSandbox.executar(etapa: etapa, id: id) ? 0 : 1)
        }
        if let pasta = Argumentos.lidos().retratosDeBancada {
            exit(Retratos.desenhar(em: pasta) ? 0 : 1)
        }
        AplicativoQuall.main()
    }
}

/// Troca entre as telas do fluxo: o estúdio (a barra lateral e o painel do papel da vez,
/// `docs/telas-estudio.md` §7), ou a janela inteira para o prompter e para a imagem recebida.
///
/// # Quem tem sessão manda
///
/// A ordem é a de antes de 30/09 — teleprompter, controle, receptor, emissor —, e a barra lateral
/// não a muda: ela só escolhe o papel com tudo parado, abrindo o formulário pelo caminho de sempre
/// do modelo (`Receptor.abrir`, `Teleprompter.abrirControle`). Com uma sessão de pé, os outros itens
/// ficam apagados ("um papel por vez").
///
/// # Por que o receptor decide antes do emissor
///
/// `receptor.fase == .fechado` quer dizer "o app não está no modo de exibir". Enquanto ele estiver
/// aberto, é o fluxo dele que a janela mostra — e o `Emissor` está parado em `.inicial` por
/// construção, porque não há caminho de interface que ligue os dois ao mesmo tempo. Uma sessão de
/// emissão e uma de recepção no mesmo processo não são proibidas pelo núcleo, mas seriam duas
/// disputando o mesmo `pares.json` e o mesmo `deviceId` — a mesma razão que tirou "Nova Janela" do
/// menu.
struct RaizDaJanela: View {
    @Environment(\.openWindow) private var abrirJanela
    @Environment(\.abrirAjustes) private var abrirAjustes
    @EnvironmentObject private var emissor: Emissor
    @EnvironmentObject private var receptor: Receptor
    @EnvironmentObject private var teleprompter: Teleprompter
    /// O seletor PT | EN: a raiz observa para montar de novo as frases que ela mesma passa adiante
    /// (a da sessão de pé, na barra lateral), e o conteúdo troca de identidade logo abaixo.
    @ObservedObject private var idioma = TrocaDeIdioma.compartilhada

    /// O controle está na janela principal (e não na janela própria do M4).
    private var controleAqui: Bool { teleprompter.tela == .controle && !teleprompter.controleEmJanela }

    private var receptorComVideo: Bool { receptor.fase == .exibindo || receptor.fase == .esperandoTrack }

    var body: some View {
        // Um contêiner que não troca, e não um `Group`: os modificadores de um `Group` valem para cada
        // ramo de dentro, e o `onAppear` abaixo dispararia a cada troca de tela — reabrindo a janela
        // do controle (M4) a cada Parar ou queda do vídeo (revisão de 30/09).
        ZStack {
            // O teleprompter decide primeiro, pelo mesmo motivo do receptor: aberto, é o fluxo dele
            // que a janela mostra — e o prompter toma a janela inteira, sem a barra lateral.
            if teleprompter.tela == .prompter {
                if teleprompter.comCamera, let camera = teleprompter.camera {
                    TelaDoPrompterComCamera(cam: camera)
                } else {
                    TelaDoPrompter()
                }
            } else if !controleAqui && receptorComVideo {
                // A imagem também toma a janela inteira; o formulário e ela nunca convivem na árvore
                // (ver `TelaDeExibicao`).
                TelaDoVideo()
            } else {
                estudio
            }
        }
        // O idioma trocou: tudo de dentro é montado de novo, no idioma novo (ver `NoIdiomaDaVez`).
        // Aqui, e não por fora: o `onAppear` abaixo não pode disparar na troca.
        .id(idioma.atual)
        .preferredColorScheme(.dark)
        .tint(Estilo.acento)
        .background(JanelaEscura())
        // A janela que a contém é a principal: o botão amarelo e o ⌘M dela vão para a barra de menus
        // (`BarraDeMenus`), e "Abrir o Quall Studio" é ela que traz.
        .background(MarcaDaJanelaPrincipal())
        .onAppear {
            // Uma vez por janela (o contêiner não troca). Antes de 30/09 a raiz era um `Group` e esta
            // linha saía também a cada troca de tela.
            Registro.compartilhado.linha(
                "janela: a raiz da cena apareceu — \(Janela.inventario())")
            // O jeito de recriar esta janela depois de ela ser fechada no X.
            Janela.abrirNova = { [abrirJanela] in abrirJanela(id: Janela.idDaPrincipal) }
            // M4 pela bancada (`--controle-em-janela`): a janela do controle abre junto.
            if teleprompter.controleEmJanela && teleprompter.tela == .controle {
                abrirJanela(id: JanelaDoControle.id)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: emissor.fase)
        .animation(.easeInOut(duration: 0.18), value: receptor.fase)
        .onReceive(NotificationCenter.default.publisher(for: .quallDeveSair)) { _ in
            // **Os três**, e não só o emissor: uma corrida de bancada do receptor com
            // `--sair-apos` precisa do mesmo desmonte ordenado — desregistrar o tratador com
            // barreira, liberar a track antes da sessão, e só então deixar o processo morrer. O
            // teleprompter fecha a sessão na ordem do contrato e grava o roteiro.
            emissor.encerrar()
            receptor.parar()
            teleprompter.sair()
        }
    }

    /// **O estúdio**: a barra lateral e o painel do papel da vez (`docs/telas-estudio.md` §7).
    private var estudio: some View {
        HStack(spacing: 0) {
            BarraLateral(escolhido: escolhido, sessao: sessao, nome: emissor.nome, desligados: desligados,
                         aoEscolher: escolher, aoAbrirAjustes: abrirAjustes)
            Group {
                // A mesma prioridade de sempre: quem tem sessão (ou formulário aberto) manda.
                if controleAqui {
                    TelaDoControle()
                } else if receptor.fase != .fechado {
                    TelaDeExibicao()
                } else {
                    switch emissor.fase {
                    case .inicial:
                        TelaInicial()
                    case .esperando, .transmitindo, .encerrando:
                        TelaDeEspera()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 580)
        .background(Estilo.fundo)
    }

    /// O item marcado sem sessão de pé: o formulário aberto (Controlar, Exibir) ou o Espelhar.
    private var escolhido: ItemDaBarra {
        if controleAqui { return .controlar }
        if receptor.fase != .fechado { return .exibir }
        return .espelhar
    }

    /// **A sessão de pé**, que apaga os outros itens (§7: "um papel por vez").
    private var sessao: SessaoNaBarra? {
        RaizDaJanela.sessao(emissor: emissor.fase, receptor: receptor.fase,
                            controle: controleAqui ? teleprompter.fase : nil)
    }

    /// A regra da sessão de pé, pura (os retratos a usam também).
    static func sessao(emissor: Emissor.Fase, receptor: Receptor.Fase, controle: Teleprompter.Fase?) -> SessaoNaBarra? {
        let doEspelhar = T("Um papel por vez. Pare de espelhar para usar os outros.")
        switch emissor {
        case .esperando: return SessaoNaBarra(item: .espelhar, luz: .aguardando, estado: T("Aguardando"), nota: doEspelhar)
        case .transmitindo: return SessaoNaBarra(item: .espelhar, luz: .noAr, estado: T("No ar"), nota: doEspelhar)
        case .encerrando: return SessaoNaBarra(item: .espelhar, luz: .aguardando, estado: T("Encerrando"), nota: doEspelhar)
        case .inicial: break
        }
        if let controle, controle != .formulario {
            let nota = T("Um papel por vez. Desconecte o controle para usar os outros.")
            switch controle {
            case .conectado: return SessaoNaBarra(item: .controlar, luz: .conectado, estado: T("Conectado"), nota: nota)
            case .semPar: return SessaoNaBarra(item: .controlar, luz: .aguardando, estado: T("Sem conexão"), nota: nota)
            case .encerrando: return SessaoNaBarra(item: .controlar, luz: .aguardando, estado: T("Saindo"), nota: nota)
            default: return SessaoNaBarra(item: .controlar, luz: .aguardando, estado: T("Conectando"), nota: nota)
            }
        }
        let doExibir = T("Um papel por vez. Pare de exibir para usar os outros.")
        switch receptor {
        case .conectando, .esperandoTrack, .exibindo:
            return SessaoNaBarra(item: .exibir, luz: .aguardando, estado: T("Conectando"), nota: doExibir)
        case .encerrando:
            return SessaoNaBarra(item: .exibir, luz: .aguardando, estado: T("Parando"), nota: doExibir)
        case .fechado, .formulario:
            return nil
        }
    }

    /// Sem sessão, os itens do teleprompter só ficam sem clique quando ele ainda está fechando a
    /// sessão anterior, ou aberto na janela do controle (M4).
    private var desligados: Set<ItemDaBarra> {
        let ocupado = teleprompter.tela != .fechada ? !controleAqui : !teleprompter.ocioso
        return ocupado ? [.mostrarOTexto, .controlar, .textoComCamera] : []
    }

    /// Um clique na barra. Fecha o formulário aberto (Exibir ou Controlar, que não são sessão) e abre o
    /// papel pedido pelo caminho de sempre do modelo. "Mostrar o texto" e "Texto com a câmera" nunca
    /// são o item marcado: eles tomam a janela inteira.
    private func escolher(_ item: ItemDaBarra) {
        guard sessao == nil, item != escolhido else { return }
        Registro.compartilhado.linha("tela: barra lateral → \(item.rawValue)")
        if item != .exibir { receptor.fechar() }
        if item != .controlar, controleAqui, teleprompter.fase == .formulario { teleprompter.sair() }
        switch item {
        case .espelhar: break
        case .exibir: receptor.abrir()
        case .controlar: teleprompter.abrirControle()
        case .mostrarOTexto: teleprompter.abrirPrompter()
        case .textoComCamera: teleprompter.abrirPrompterComCamera()
        }
    }
}

/// **A janela do controle do teleprompter** (M4). Mostra a `TelaDoControle` enquanto o controle
/// estiver na janela própria; fechada pela pessoa, o controle sai (a sessão fecha na ordem do
/// contrato).
struct JanelaDoControle: View {
    static let id = "quall.controle"
    @EnvironmentObject private var tp: Teleprompter
    /// Só pelo título da janela, que o `Window` da cena escreve uma vez na abertura.
    @ObservedObject private var idioma = TrocaDeIdioma.compartilhada

    var body: some View {
        // Um contêiner fixo, e não um `Group`: o `onDisappear` de um `Group` pode disparar na troca do
        // ramo de dentro (o painel sai, a tela do controle entra), e fecharia o controle recém-aberto
        // pelo botão desta janela (a revisão de 25/09). Aqui ele só dispara com a janela fechando.
        VStack(spacing: 0) {
            NoIdiomaDaVez {
                if tp.tela == .controle && tp.controleEmJanela {
                    TelaDoControle()
                } else {
                    VStack(spacing: 12) {
                        Text(T("Controle do teleprompter")).font(Estilo.titulo(22)).foregroundColor(Estilo.texto)
                        Text(T("Controle o texto de outro aparelho enquanto esta janela mostra o vídeo de outro."))
                            .font(.callout).foregroundColor(Estilo.texto2)
                        Button(T("Controlar um teleprompter…")) { tp.abrirControleEmJanela() }
                            .buttonStyle(.quall(.principal))
                            .disabled(tp.tela != .fechada)
                        if tp.tela != .fechada && !tp.controleEmJanela {
                            Text(T("O teleprompter já está aberto na janela principal.")).font(.caption)
                                .foregroundColor(Estilo.aguardandoTexto)
                        }
                    }
                    .padding(28)
                    .frame(minWidth: 460, minHeight: 220)
                    .background(Estilo.fundo)
                }
            }
        }
        .navigationTitle(T("Controle do teleprompter"))
        .background(JanelaEscura())
        .onDisappear {
            if tp.tela == .controle && tp.controleEmJanela {
                Registro.compartilhado.linha("teleprompter: a janela do controle fechou — o controle sai")
                tp.sair()
            }
        }
    }
}

/// **Cmd-Q com a câmera gravando** (R5 fase 4, a revisão de 25/09): sem isto o processo morria com o
/// `finishWriting` no meio, e o arquivo virava órfão "(interrompido)". Agora o fim espera: a tela com
/// câmera e a câmera comum fecham na ordem (o arquivo, a sessão, a câmera), com teto de 8 s.
final class DelegadoDoApp: NSObject, NSApplicationDelegate {
    /// O ícone na barra de menus (01/10), vivo enquanto o app roda.
    private var barra: BarraDeMenus?

    /// **Escuro sempre** (`docs/telas-estudio.md` §1): o app deixa de seguir o tema claro do sistema —
    /// a janela, os Ajustes, as folhas, os alertas e os menus de dentro dele (o do ícone da barra de
    /// menus também; o **ícone** não: a barra decide a aparência dele, ver `MarcaNaBarra`).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        barra = BarraDeMenus()
    }

    /// O Dock (quando ele está lá) ou o `Quall.app` aberto de novo com a principal escondida na barra:
    /// ela volta, e o SwiftUI não cria outra. Sem a principal na barra, o de sempre — inclusive recriar a
    /// janela fechada no X. O delegado do SwiftUI repassa este pedido ao do adaptador e respeita o
    /// `false` (medido numa sonda em 01/10, `docs/app-macos.md`, "Barra de menus").
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let barra, barra.principalNaBarra else { return true }
        barra.abrirOQuall(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let gravandoNaTela = Teleprompter.atual?.camera?.gravador?.estado.ocupada == true
        let gravandoNaEspera = Emissor.atual?.gravador?.estado.ocupada == true
        let recebido = Receptor.atual?.gravacaoRecebida
        let gravandoRecebido = recebido?.ativo == true || recebido?.fechando == true
        guard gravandoNaTela || gravandoNaEspera || gravandoRecebido || TelaComCamera.emFecho > 0 else { return .terminateNow }
        Registro.compartilhado.linha("app vai fechar com a câmera gravando: fechando o arquivo antes (até 8 s)")
        Teleprompter.atual?.sair()
        Emissor.atual?.encerrar()
        Receptor.atual?.parar()
        let inicio = Date()
        func esperar() {
            // O Emissor só abre o fecho da câmera depois de as sessões desmontarem: esperar também a
            // fase dele voltar ao começo, senão o contador ainda estaria em zero.
            let r = Receptor.atual?.gravacaoRecebida
            let pronto = TelaComCamera.emFecho == 0 && (Emissor.atual?.fase ?? .inicial) == .inicial
                && r?.ativo != true && r?.fechando != true
            if pronto || Date().timeIntervalSince(inicio) > 8 {
                Registro.compartilhado.linha(pronto ? "arquivo fechado; saindo"
                                             : "saindo sem esperar o arquivo (8 s): vira pendente na volta")
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: esperar)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: esperar)
        return .terminateLater
    }
}
