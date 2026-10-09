import SwiftUI

/// O app do Quall no iOS. **Um app, os dois papéis.**
///
/// Até 2026-08-30 eram dois: `Quall` (`br.com.queven.quall`, emitia) e `QuallReceptor`
/// (`br.com.queven.quall.receptor`, exibia). Dois alvos, dois ícones, dois pareamentos, duas
/// concessões de Rede Local para o mesmo aparelho. `docs/receptor-ios.md` já registrava a
/// separação como pendência e não como desenho: *"juntar os dois num app só é trabalho de uma
/// tarde, e deve ser feito quando a sessão de toques dos iPhones fechar"*.
///
/// # As telas, e a ordem entre elas
///
/// ```
/// TelaDeModo ──espelhar──► TelaInicial ──► TelaDePermissao ──► TelaDeEspera
///     │                       │  (seletor de origem)              (PIN, endereço, Cancelar)
///     │                       └──câmera──► TelaDaCamera
///     ├──exibir────► TelaDeRecepcao (endereço, PIN, Conectar → vídeo)
///     ├──teleprompter──► TelaDoPrompter (texto rolando; PIN e endereço; hospeda)
///     ├──teleprompter_com_camera──► TelaDoPrompterComCamera (o texto junto da lente, a prévia da
///     │                              frontal; hospeda o prompter e a câmera, duas sessões)
///     └──controle_remoto──► TelaDoControle (endereço e PIN → controles)
/// ```
///
/// **A tela de escolha vem antes do emissor e não o atravessa.** O fluxo de três toques provado no
/// iPhone 7 continua exatamente o mesmo depois dela: seletor de origem, Espelhar, consentimento do
/// sistema. Nada foi movido para dentro dele, nada foi tirado. O custo da unificação é um toque
/// **antes**, e está dito em voz alta em `TelaDeModo`.
///
/// # As duas portas que pulam a escolha, e por que não são atalhos escondidos
///
/// 1. **Transmissão já viva.** A appex sobrevive ao app — é para isso que ela é autônoma
///    (`docs/arquitetura-ios.md`). Se ela está no ar quando o app abre, o papel deste aparelho já
///    está decidido pelos fatos, e perguntar seria oferecer uma escolha que não existe. `Emissor`
///    já detectava isso (`retomarSeHouverTransmissao`); a raiz só respeita.
/// 2. **Modo automático de bancada** (`--endereco`). É o que mantém viva a corrida sem toque
///    humano do iPad, que é a única corrida de iOS desta bancada que não custa o dedo de alguém.
///
/// # O que **não** mudou, de propósito
///
/// A appex (`Difusao`) não vê nada disto. Ela compila `Extensao/` + `Comum/`, e o código do lado
/// que exibe mora em `Receber/`, que entra **só** no alvo do app. Isso não é higiene: o orçamento
/// medido do jetsam para a Broadcast Upload Extension é de 50,00 MB no iPhone 7 e no X, e o
/// decodificador, a camada de exibição e o SwiftUI da tela de recepção não têm por que existir
/// naquele processo. A guarda contra regressão é o `provar.sh`, que confere símbolos nos dois
/// binários linkados separadamente.
@main
struct QuallApp: App {
    /// Só responde quais orientações valem — a tela cheia do receptor prende a do vídeo. Fora
    /// dela a resposta é a do `Info.plist`. Ver `Orientacao`.
    @UIApplicationDelegateAdaptor(DelegadoDoApp.self) private var delegado
    @StateObject private var emissor = Emissor()
    @StateObject private var recepcao = Recepcao()
    @StateObject private var papel = Papel()
    @StateObject private var idioma = IdiomaDaTela()
    @Environment(\.scenePhase) private var etapaDaCena

    init() {
        // O núcleo registra apenas origem do pânico; não publica seu payload arbitrário.
        // Instalar antes das consultas FFI do arranque e da criação das sessões.
        quall_install_panic_hook(nil, nil)
        // Ditas **sempre**, e não só no modo automático. Uma abertura pela pessoa que não deixa
        // nenhum rastro no `os_log` é uma abertura que não dá para conferir depois — e a linha da
        // tela é justamente a que responde se a família de alvo está fazendo o que deveria, que
        // passou a ser uma pergunta do app inteiro e não só do receptor (ver `IdentidadeDaTela`).
        Diario.dizer("Quall iOS (um app, dois papéis) — protocolo v\(NucleoReceptor.versaoDoProtocolo())")
        Diario.dizer("aparelho: \(Identidade.descricaoDoAparelho())")
        Diario.dizer("tela: \(Identidade.descricaoDaTela())")
        Identidade.medirTelaNativa()
        Estilo.aplicarAparencia()
    }

    var body: some Scene {
        WindowGroup {
            Raiz()
                .environmentObject(emissor)
                .environmentObject(recepcao)
                .environmentObject(papel)
                .environmentObject(idioma)
                // **Escuro sempre** (`docs/telas-estudio.md` §1): a imagem e o roteiro são as
                // estrelas, e a interface fica atrás. O `UIUserInterfaceStyle` do `Info.plist` diz o
                // mesmo ao UIKit (alertas, folhas do sistema abertas pelo app); isto diz ao SwiftUI.
                // O violeta no lugar do azul vale para os controles nativos (`tint`) e para quem lê
                // `Color.accentColor` (o teleprompter).
                .preferredColorScheme(.dark)
                .tint(Estilo.acento)
                .accentColor(Estilo.acento)
                .onAppear {
                    TelaAcesa.atualizarPrimeiroPlano(etapaDaCena == .active)
                    abrir()
                }
                .onChange(of: etapaDaCena) { nova in
                    TelaAcesa.atualizarPrimeiroPlano(nova == .active)
                    // A appex continua transmitindo com o app fora do ar — é para isso que ela é
                    // autônoma. Voltar e encontrar a tela inicial, com o indicador vermelho
                    // ligado, seria a interface mentindo sobre o estado do aparelho.
                    if nova == .active { emissor.aoVoltarAoPrimeiroPlano() }
                }
        }
    }

    /// Decide, uma vez por abertura, se há papel a escolher.
    private func abrir() {
        // O retrato de bancada é só desenho: nenhuma das portas abaixo (as gravações pendentes, a
        // bancada, a retomada da transmissão) roda com ele.
        guard RetratosDeBancada.pedido == nil else { return }
        // As gravações do R5 que não chegaram ao rolo da câmera (o processo morto gravando, a
        // permissão que faltava): vão agora, sem perguntar nada (`GravacoesPendentes`).
        GravacoesPendentes.recuperar(por: "o app abriu")
        // O teleprompter de bancada (`--prompter`, `--controle`): entra direto no papel, sem toque.
        // Ver `BancadaDoTeleprompter`.
        if let b = BancadaDoTeleprompter.ler() {
            if b.prompterComCamera {
                papel.escolher(.teleprompterComCamera, por: "--prompter-camera")
            } else {
                papel.escolher(b.prompter ? .teleprompter : .controleRemoto,
                               por: b.prompter ? "--prompter" : "--controle")
            }
            return
        }
        // A câmera comum de bancada (`--camera-comum frontal|traseira`): o papel de espelhar, e a
        // tela inicial abre a câmera sozinha (`BancadaDaCameraComum`).
        if BancadaDaCameraComum.pedida != nil {
            papel.escolher(.espelhar, por: "--camera-comum")
            return
        }
        if recepcao.lerArgumentos() {
            papel.escolher(.exibir, por: "--endereco")
            recepcao.talvezAutomatico()
            return
        }
        // A transmissão viva decide sozinha — ver o cabeçalho, porta 1.
        if emissor.transmissaoNoAr {
            papel.escolher(.espelhar, por: "transmissão já no ar")
        }
    }
}

struct Raiz: View {
    @EnvironmentObject private var emissor: Emissor
    @EnvironmentObject private var recepcao: Recepcao
    @EnvironmentObject private var papel: Papel
    @EnvironmentObject private var idioma: IdiomaDaTela

    var body: some View {
        ZStack {
            Estilo.fundo.ignoresSafeArea()
            telas
                // **A troca de idioma recria as telas** (`docs/traducao.md`): o seletor só existe na
                // tela inicial, então é ela que renasce, já com os textos do idioma novo. O seletor de
                // transmissão fica fora, montado o tempo todo (ver abaixo).
                .id(idioma.atual)

            // O seletor do sistema mora fora do fluxo das telas, e presente o tempo todo: é ele
            // que carrega o `preferredExtension`, e procurá-lo na hierarquia de vistas no
            // instante do toque é o tipo de coisa que funciona até a hierarquia mudar.
            //
            // **Fica montado nos dois papéis**, e não só em `.espelhar`: `RPSystemBroadcastPickerView`
            // precisa estar na árvore desde antes do toque, e trocar de papel remontaria a
            // hierarquia justamente na transição em que a folha é aberta.
            SeletorDeTransmissao()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        // **A tela com câmera fecha quando o papel muda**, sem depender do `onDisappear` dela, que no
        // iPad de 27/09 não correu: a câmera e a 7979 ficaram 45 min vivas sem tela (§8.12.9).
        .onChange(of: papel.escolha) { nova in
            if nova != .teleprompterComCamera {
                FechoDaTela.comCamera.fechar(motivo: "o papel mudou (\(nova?.rawValue ?? "escolha"))")
            }
        }
    }

    @ViewBuilder
    private var telas: some View {
        // Os retratos de bancada (`--retrato-de-bancada <tela>`, `RetratosDeBancada`): a tela
        // pedida com valores de exemplo, no lugar do fluxo. Sem o argumento, não existe.
        if let retrato = RetratosDeBancada.pedido {
            TelaDeRetrato(nome: retrato)
        } else {
            switch papel.escolha {
            case .none:
                TelaDeModo()

            case .espelhar:
                switch emissor.fase {
                case .inicial, .falhou, .permissaoNegada:
                    TelaInicial(voltar: { papel.voltar() })
                case .pedindoPermissao:
                    TelaDePermissao()
                case .esperando, .transmitindo, .encerrando:
                    TelaDeEspera()
                }

            case .exibir:
                TelaDeRecepcao(painel: recepcao.painel,
                               exibidor: recepcao.exibidor,
                               camera: recepcao.cameraRemota,
                               gravador: recepcao.gravador,
                               conectar: { endereco, pin, segundos in
                                   recepcao.conectar(endereco: endereco, pin: pin,
                                                     segundos: segundos)
                               },
                               parar: { recepcao.parar() },
                               // Sempre o voltar: quem o esconde com sessão no ar é a
                               // `TelaDeRecepcao`, que observa o painel. Calculado aqui, ele
                               // ficava preso no `nil` da última vez que a raiz redesenhou com
                               // vídeo chegando (a raiz não observa o painel), e depois do
                               // Parar o formulário voltava sem voltar e sem Cancelar.
                               voltar: { papel.voltar() })

            // O teleprompter: cada tela é dona do seu modelo (réplica e sessão) e o desmonta ao
            // sair — "Sair" e "Voltar" param a sessão antes de a tela de escolha aparecer. Os
            // argumentos de bancada são consumidos na criação do modelo, que acontece uma vez por
            // tela — e não aqui, num `body` que o SwiftUI reavalia quando quer.
            case .teleprompter:
                TelaDoPrompter(voltar: { papel.voltar() })

            // O prompter **com a câmera frontal** (R5, `docs/teleprompter-com-camera.md`): a tela é
            // dona das duas sessões — a do prompter e a da câmera — e do dono da captura, e fecha os
            // três ao sair. É um papel próprio, e não um modo de `.teleprompter`, porque um prompter
            // por aparelho é regra (§2.5): as duas telas nunca estão abertas juntas.
            case .teleprompterComCamera:
                TelaDoPrompterComCamera(voltar: { papel.voltar() })

            case .controleRemoto:
                TelaDoControle(voltar: { papel.voltar() })
            }
        }
    }
}
