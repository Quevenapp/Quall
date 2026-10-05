import AVFoundation
import SwiftUI

/// A tela de quem vai **espelhar**: o nome na rede, **o seletor de origem**, e um botão.
///
/// **Deixou de ser a primeira tela do app em 2026-08-30**, com a unificação: antes dela vem
/// `TelaDeModo`, que pergunta espelhar ou exibir. O que está aqui dentro **não mudou** — o fluxo
/// de três toques provado no iPhone 7 (seletor de origem, Espelhar, consentimento do sistema) é
/// exatamente o mesmo. O que a unificação acrescentou foi um botão de voltar, porque uma tela que
/// não é mais a primeira precisa ter como sair.
///
/// O fluxo, atualizado em 2026-08-22, é literal sobre o que ela tem: "Abrir o app, **escolher o
/// que transmitir** (tela ou uma das câmeras) e tocar em **Espelhar**". Sem conta, sem login, sem
/// cadastro, sem tela de configuração obrigatória. O nome está aqui porque é a única coisa que a
/// outra pessoa vai ver na lista, e porque é a primeira pergunta de quem abre o app: "de qual
/// aparelho eu sou?".
///
/// ## O seletor é o que faz o receptor ver este aparelho uma vez só
///
/// Antes desta decisão, tela e câmera eram duas sessões que podiam existir juntas — duas entradas
/// na lista, dois PINs, dois pareamentos, contra a promessa de "PIN uma vez por par de
/// aparelhos". Escolher **antes** do PIN resolve pelo lado do emissor: uma entrada, um PIN, uma
/// sessão, uma porta.
///
/// As câmeras são **enumeradas do aparelho** (ver `Origem.cameras()`), nunca fixadas em duas: no
/// iPhone 7 são duas, no iPhone X são três, e em aparelhos mais novos são mais. A enumeração não
/// pede permissão nenhuma — o que pede é abrir a câmera, e isso só acontece depois da escolha, o
/// que mantém a tela inicial livre de qualquer alerta do sistema.
///
/// ## A cara desde 30/09/2026 (`docs/telas-estudio.md` §6.2)
///
/// "O que vamos espelhar?" com as origens em **ladrilhos** de duas colunas, o nome editável, a linha
/// de rede com o chip da qualidade (que abre a engrenagem) e o botão Espelhar no pé. Os dois
/// seletores de QUALIDADE, a nota de custo e "Esquecer aparelhos pareados" foram para Ajustes
/// (`FolhaDaEngrenagem`), e as duas frases que repetiam a Espera saíram de vez. A tela só adapta o
/// estado; o desenho é `VistaDeEspelhar`, que recebe valores simples.
struct TelaInicial: View {
    /// Volta à tela de escolha de papel. Existe desde a unificação: esta tela deixou de ser a
    /// primeira do app, e uma tela que não tem como voltar prende quem tocou "Espelhar" por
    /// engano num caminho que só sai fechando o app.
    let voltar: () -> Void

    @EnvironmentObject private var emissor: Emissor
    @State private var origens: [Origem] = [.tela]
    /// Os ladrilhos das origens, montados uma vez por enumeração: o ícone pergunta ao AVFoundation de
    /// que lado a câmera está, e isso não tem por que rodar a cada `body` (a cada tecla no nome).
    @State private var origensNaTela: [VistaDeEspelhar.OrigemNaTela] = [TelaInicial.naTela(.tela)]
    @State private var escolhida: Origem = .tela
    @State private var cameraNoAr: Origem?
    @State private var toquesNoTitulo = 0
    @State private var diagnosticoLigado = Diagnostico.ligado
    @State private var temPares = Compartilhado.haParesConhecidos
    @State private var ajustes = false
    /// Relido quando a folha de Ajustes fecha: o chip mostra o que está escolhido lá.
    @State private var qualidade = TelaInicial.qualidadeEscolhida

    var body: some View {
        VistaDeEspelhar(origens: origensNaTela,
                        escolhida: escolhida.id,
                        nome: $emissor.nome,
                        rede: rede,
                        // Só quando há cabo **e** LAN: quem não tem cabo não vê linha nenhuma.
                        notaDoEnlace: emissor.ip != nil ? emissor.notaDoEnlace : nil,
                        qualidade: qualidade,
                        conselho: emissor.conselho,
                        acaoDoConselho: emissor.fase == .permissaoNegada ? tr("Abrir os Ajustes") : nil,
                        diagnosticoLigado: diagnosticoLigado,
                        // **`enderecoParaDigitar`, e não `ip`.** Era `.disabled(emissor.ip == nil)`, e
                        // `ip` é só a LAN: com o cabo plugado e o Wi-Fi desligado — a instalação de
                        // estúdio inteira — o botão de emitir ficava **desabilitado** sobre um enlace
                        // provado com perda 0,000 %. A condição certa não é "tem Wi-Fi", é "existe um
                        // endereço para entregar ao outro aparelho": LAN, ou cabo, ou nada.
                        podeEspelhar: emissor.enderecoParaDigitar != nil,
                        aoEscolher: { id in
                            if let o = origens.first(where: { $0.id == id }) { escolhida = o }
                        },
                        aoAcaoDoConselho: abrirAjustes,
                        aoEspelhar: espelhar,
                        aoVoltar: voltar,
                        aoAbrirAjustes: { ajustes = true },
                        aoTocarNoTitulo: revelarDiagnostico)
            .onAppear(perform: enumerarOrigens)
            .sheet(isPresented: $ajustes, onDismiss: { qualidade = TelaInicial.qualidadeEscolhida }) {
                FolhaDaEngrenagem(fechar: { ajustes = false },
                                  aoEsquecerPares: { temPares = Compartilhado.haParesConhecidos })
            }
            // `item:` e não `isPresented:` de propósito: a câmera escolhida vai **junto** com a
            // apresentação, e a tela nunca pode subir sem saber qual é. Com uma bandeira booleana e
            // uma variável à parte, existe o instante em que uma está certa e a outra não.
            .fullScreenCover(item: $cameraNoAr) { origem in TelaDaCamera(origem: origem) }
    }

    /// **A frase deixou de citar Wi-Fi em 01/09/2026, e isso é conserto de defeito.** Com só o cabo
    /// USB plugado ela dizia "Sem Wi‑Fi" de pé sobre um enlace que acabara de entregar 19 255 pacotes
    /// sem perder um (`docs/bancada.md`, o estúdio). Três estados, e nenhum deles mente: LAN, cabo, e
    /// nada.
    private var rede: VistaDeEspelhar.Rede {
        if let ip = emissor.ip { return .wifi(ip) }
        if let cabo = emissor.ipDoCabo { return .cabo(cabo) }
        return .nenhuma
    }

    /// "1080p · 30": o cardápio gravado (`Resolucao`), que a folha de Ajustes muda.
    private static var qualidadeEscolhida: String {
        "\(Resolucao.escolhida.rotulo) · \(Resolucao.quadros)"
    }

    /// O ladrilho de cada origem: o nome de sempre e o ícone do que ela é (tela, câmera, rosto). A
    /// tela diz o modelo ("deste iPad" no iPad); o `Origem.nome` do diagnóstico continua o mesmo.
    private static func naTela(_ o: Origem) -> VistaDeEspelhar.OrigemNaTela {
        switch o {
        case .tela:
            let modelo = Estilo.modeloDoAparelho
            return .init(id: o.id, nome: tr("A tela deste %@", modelo),
                         icone: modelo == "iPad" ? "ipad" : "iphone")
        case .camera(let id, let nome):
            let frontal = AVCaptureDevice(uniqueID: id)?.position == .front
            return .init(id: o.id, nome: Origem.traduzirNome(nome),
                         icone: frontal ? "person.crop.square" : "camera")
        }
    }

    /// Enumera as origens toda vez que a tela aparece.
    ///
    /// Não uma vez só: câmeras somem e voltam. Uma sessão de captura de outro app, um acessório,
    /// ou uma restrição do sistema mudam o que `DiscoverySession` devolve, e um seletor que
    /// mostrasse a lista da primeira abertura ofereceria uma câmera que não existe mais — que é
    /// exatamente a falha que `EmissorDeCamera` trata com "a câmera escolhida não está mais
    /// disponível", e que é melhor não chegar a acontecer.
    private func enumerarOrigens() {
        let cameras = Origem.cameras()
        origens = [.tela] + cameras
        origensNaTela = origens.map(TelaInicial.naTela)
        if !origens.contains(escolhida) { escolhida = .tela }
        temPares = Compartilhado.haParesConhecidos
        if cameraNoAr == nil, let pedida = BancadaDaCameraComum.consumir(de: cameras) {
            escolhida = pedida
            // Fora do `onAppear`: apresentar no meio da transição pode ser descartado (revisão, menor 7).
            DispatchQueue.main.async { cameraNoAr = pedida }
        }
        Diagnostico.nota("APP origens_disponiveis=\(origens.count)"
            + " pares_conhecidos=\(temPares)")
    }

    private func espelhar() {
        switch escolhida {
        case .tela:
            emissor.espelhar()
        case .camera:
            cameraNoAr = escolhida
        }
    }

    private func abrirAjustes() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// A opção avançada escondida que o fluxo permite: sete toques no título ligam o diagnóstico.
    ///
    /// Ele fica **desligado por padrão** porque o arnês de medição, rodando dentro do processo
    /// que media, foi o que derrubou uma corrida do degrau 4. O que sobrou dele no produto só
    /// escreve `os_log`, e só quando alguém pediu.
    private func revelarDiagnostico() {
        toquesNoTitulo += 1
        guard toquesNoTitulo >= 7 else { return }
        toquesNoTitulo = 0
        let defaults = UserDefaults(suiteName: Compartilhado.grupo)
        let atual = (defaults?.object(forKey: "diagnostico") as? Bool) ?? Diagnostico.padraoDaBuild
        defaults?.set(!atual, forKey: "diagnostico")
        diagnosticoLigado = !atual
    }
}

/// **Espelhar**, só desenho (§6.2). Cabeçalho (voltar · "Espelhar" · engrenagem); "O que vamos
/// espelhar?"; as origens em ladrilhos de duas colunas; "APARECER NA LISTA COMO" com o nome editável;
/// a linha de rede com o chip da qualidade; no máximo um aviso à vista (o resto em "+N", §11.1); e,
/// no pé, o botão Espelhar e a frase de uma origem por vez. Deitado, duas colunas: ladrilhos à
/// esquerda; nome, rede, avisos e botão à direita.
///
/// Conta de altura no iPhone 7, escala padrão, três origens (duas fileiras; "A tela deste iPhone"
/// quebra em duas linhas, 106, e as câmeras cabem em uma, 86). Em pé (647 pt): 4 + cabeçalho 44 + 8 +
/// título 34 + 12 + ladrilhos 106 + 10 + 86 + 12 + rótulo 16 + 8 + campo 52 + 12 + rede 32 + 12
/// (espaço mínimo) + botão 56 + 8 + frase em duas linhas 36 + 12 ≈ 560; com um aviso (12 + ~60),
/// ≈ 632. Deitado (375 pt): 4 + cabeçalho 44 + a coluna da esquerda, a mais alta (8 + título 34 + 14
/// + ladrilhos 202) + 12 ≈ 318.
struct VistaDeEspelhar: View {
    struct OrigemNaTela: Identifiable {
        let id: String
        let nome: String
        let icone: String
    }

    enum Rede {
        case wifi(String)
        case cabo(String)
        case nenhuma
    }

    let origens: [OrigemNaTela]
    let escolhida: String
    @Binding var nome: String
    let rede: Rede
    let notaDoEnlace: String?
    let qualidade: String
    let conselho: String
    let acaoDoConselho: String?
    let diagnosticoLigado: Bool
    let podeEspelhar: Bool
    let aoEscolher: (String) -> Void
    let aoAcaoDoConselho: () -> Void
    let aoEspelhar: () -> Void
    let aoVoltar: () -> Void
    let aoAbrirAjustes: () -> Void
    let aoTocarNoTitulo: () -> Void

    @Environment(\.verticalSizeClass) private var classeVertical

    private let colunas = [GridItem(.flexible(), spacing: 10, alignment: .top),
                           GridItem(.flexible(), spacing: 10, alignment: .top)]

    var body: some View {
        ZStack {
            FundoDoQuall()
            TelaQueCabe {
                VStack(alignment: .leading, spacing: 0) {
                    CabecalhoDaTela(titulo: tr("Espelhar")) {
                        BotaoRedondo(icone: "chevron.left", rotulo: tr("Voltar"), acao: aoVoltar)
                    } direita: {
                        BotaoRedondo(icone: "gearshape", rotulo: tr("Ajustes"), acao: aoAbrirAjustes)
                    }
                    if classeVertical == .compact {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 0) {
                                titulo.padding(.top, 8)
                                origensEmGrade.padding(.top, 14)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                nomeNaLista.padding(.top, 8)
                                redeEAvisos
                                Spacer(minLength: 14)
                                pe
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        titulo.padding(.top, 8)
                        origensEmGrade.padding(.top, 12)
                        nomeNaLista.padding(.top, 12)
                        redeEAvisos
                        Spacer(minLength: 12)
                        pe
                    }
                }
                .colunaDoQuall(larga: classeVertical == .compact)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        }
        .dynamicTypeSize(...Estilo.tetoDaLetra)
    }

    private var titulo: some View {
        Text(tr("O que vamos espelhar?"))
            .font(Estilo.titulo(.title))
            .foregroundColor(Estilo.texto)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .onTapGesture(perform: aoTocarNoTitulo)
            .accessibilityAddTraits(.isHeader)
    }

    private var origensEmGrade: some View {
        LazyVGrid(columns: colunas, alignment: .leading, spacing: 10) {
            ForEach(origens) { o in
                Ladrilho(icone: o.icone, titulo: o.nome, escolhido: o.id == escolhida,
                         alturaMinima: 84) { aoEscolher(o.id) }
            }
        }
    }

    private var nomeNaLista: some View {
        VStack(alignment: .leading, spacing: 8) {
            RotuloDeSecao(tr("Aparecer na lista como"))
            HStack(spacing: 10) {
                TextField(tr("Nome do aparelho"), text: $nome)
                    .disableAutocorrection(true)
                    .submitLabel(.done)
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Estilo.acentoClaro)
                    .accessibilityHidden(true)
            }
            .estiloDeCampo()
        }
    }

    private var redeEAvisos: some View {
        VStack(alignment: .leading, spacing: 0) {
            linhaDeRede
                .padding(.top, 12)
            if let notaDoEnlace {
                // Só quando há cabo **e** LAN: é a segunda linha que uma instalação de estúdio —
                // hub USB, vários celulares — precisa ler.
                Text(notaDoEnlace)
                    .font(Estilo.corpo(.caption))
                    .foregroundColor(Estilo.texto3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if !avisos.isEmpty {
                PilhaDeAvisos(itens: avisos, maximo: 1)
                    .padding(.top, 12)
            }
            if diagnosticoLigado {
                // A leitura do estado é feita **uma vez** por execução, para não pôr uma consulta ao
                // `UserDefaults` no caminho de cada linha. Trocar aqui vale da próxima abertura em
                // diante, e dizer isso é mais honesto que mentir sobre o efeito.
                Text(tr("Diagnóstico ligado — registros no console do sistema. "
                     + "Mudanças valem na próxima abertura do app."))
                    .font(Estilo.corpo(.caption))
                    .foregroundColor(Estilo.aguardandoTexto)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    private var pe: some View {
        VStack(spacing: 8) {
            Button(action: aoEspelhar) {
                Label(tr("Espelhar"), systemImage: Estilo.iconeDeEspelhar)
            }
            .buttonStyle(.principal)
            .disabled(!podeEspelhar)

            // Dito **antes** de começar, e não depois de a pessoa procurar o botão que não existe:
            // a origem é fixa pela sessão porque o protocolo não renegocia.
            Text(tr("Uma origem por vez. Para trocar, pare e escolha de novo."))
                .font(Estilo.corpo(.footnote))
                .foregroundColor(Estilo.texto3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    /// Ícone e bolinha + "Wi-Fi · {ip}" ou "Cabo USB · {ip}", e à direita o chip da qualidade, que
    /// abre a engrenagem. Sem rede, a bolinha fica âmbar e a frase inteira vai para um aviso.
    private var linhaDeRede: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                switch rede {
                case .wifi(let ip):
                    Image(systemName: "wifi").foregroundColor(Estilo.texto2)
                    Circle().fill(Estilo.conectado).frame(width: 8, height: 8)
                    Text(verbatim: "Wi-Fi · ") + Text(ip).font(Estilo.mono(.subheadline))
                case .cabo(let ip):
                    Image(systemName: "cable.connector").foregroundColor(Estilo.texto2)
                    Circle().fill(Estilo.conectado).frame(width: 8, height: 8)
                    Text(tr("Cabo USB") + " · ") + Text(ip).font(Estilo.mono(.subheadline))
                case .nenhuma:
                    Image(systemName: "wifi.slash").foregroundColor(Estilo.aguardando)
                    Circle().fill(Estilo.aguardando).frame(width: 8, height: 8)
                    Text(tr("Sem rede"))
                }
            }
            .font(Estilo.corpo(.subheadline))
            .foregroundColor(Estilo.texto2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            ChipPequeno(texto: qualidade, mono: true, iconeDepois: "chevron.right",
                        acao: aoAbrirAjustes)
                .accessibilityLabel(tr("Qualidade %@ quadros por segundo", qualidade))
                .accessibilityHint(tr("Abre os Ajustes"))
        }
    }

    /// O que importa mais primeiro: sem rede, nada funciona; o conselho do emissor depois.
    private var avisos: [ItemDeAviso] {
        var v: [ItemDeAviso] = []
        if case .nenhuma = rede {
            v.append(ItemDeAviso(id: "rede",
                                 texto: tr("Sem rede. Entre no mesmo Wi-Fi do outro aparelho, ou ligue o cabo."),
                                 icone: "wifi.slash"))
        }
        if !conselho.isEmpty {
            v.append(ItemDeAviso(id: "conselho", texto: conselho, acao: acaoDoConselho,
                                 aoTocar: aoAcaoDoConselho))
        }
        return v
    }
}

/// Tela curtinha de "estou pedindo a permissão". Existe porque o alerta do sistema pode demorar,
/// e uma tela que não muda depois de um toque é indistinguível de um app travado.
///
/// Desde 30/09 fica na moldura da Espera (§11.1): o brilho âmbar, a pílula AGUARDANDO girando e as
/// frases de sempre. Negada, a fase volta à `TelaInicial`, que mostra o aviso âmbar com "Abrir os
/// Ajustes".
struct TelaDePermissao: View {
    var body: some View {
        ZStack {
            FundoDoQuall(brilho: Estilo.aguardando, intensidade: 0.12)
            VStack(spacing: 14) {
                PilulaDeEstado(tom: .aguardando, palavra: tr("Aguardando"), girando: true)
                Text(tr("Verificando o acesso à rede local…"))
                    .font(Estilo.titulo(.title2))
                    .foregroundColor(Estilo.texto)
                    .fixedSize(horizontal: false, vertical: true)
                Text(permissao)
                    .font(Estilo.corpo(.subheadline))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: Estilo.larguraMaxima)
        }
        .dynamicTypeSize(...Estilo.tetoDaLetra)
    }

    /// "Se o iPhone perguntar" dizia iPhone no iPad também: agora é o modelo do aparelho.
    private var permissao: AttributedString {
        // "Permitir" é o botão do alerta do sistema: na língua do sistema (`trSistema`).
        let texto = tr("Se o %@ perguntar, toque em **%@**. Sem isso, os dois "
            + "aparelhos não se acham — e a falha só apareceria depois, como “não conectou”.",
            Estilo.modeloDoAparelho, trSistema("Permitir"))
        return (try? AttributedString(markdown: texto)) ?? AttributedString(texto)
    }
}
