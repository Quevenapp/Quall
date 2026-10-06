import AVFoundation
import Combine
import SwiftUI
import UIKit

/// As três peças que a tela com câmera possui, criadas **uma vez** por tela.
///
/// Um objeto só, e não três `@StateObject`: o emissor nasce com o dono (`EmissorDeCamera(dono:)`),
/// e um `@StateObject` não enxerga o outro no `init` da vista. Criar o dono no `init` da vista e
/// passá-lo aos dois alocaria uma `AVCaptureSession` a cada reavaliação da raiz, jogada fora em
/// seguida.
final class PecasDaTelaComCamera: ObservableObject {
    let dono = DonoDaCaptura()
    let camera: EmissorDeCamera
    /// A gravação local (fase 3): o gravador pendura a tomada no mesmo dono, e a ponte fala com a
    /// réplica do prompter (o controle remoto começa, para e vê).
    let gravador: GravadorLocal
    let gravacao: GravacaoDoPrompter
    let ajustesDaCamera: AjustesDaTelaComCamera
    /// O espelho do texto que a réplica tinha ao abrir, quando esta tela o desligou: volta no
    /// fim, para o prompter comum (que usa a mesma réplica salva) não herdar o desligado.
    var espelhoParaDevolver = false
    private var repasse: AnyCancellable?

    // --- os degraus da transmissão (§8.12.16) ---------------------------------------------------

    private var degraus = DegrausDaTransmissao()
    /// O degrau de agora, para a tela.
    @Published private(set) var degrau: DegrausDaTransmissao.Degrau = .nenhum
    /// A pessoa tocou na prévia pausada: ela fica à mostra até os degraus voltarem a zero.
    @Published private(set) var previaMostradaPelaPessoa = false

    /// Uma janela de 10 s do som da rede (`EmissorDeCamera.aoAvaliarSom`). Na principal.
    func avaliar(ruim: Bool, transmitindo: Bool, quente: Bool, resumo: String) {
        if let novo = degraus.janela(ruim: ruim, transmitindo: transmitindo, gravando: gravador.estado.gravando,
                                     quente: quente) {
            let linha = "degraus da transmissão: \(degrau.nome) → \(novo.nome) (\(resumo), transmitindo=\(transmitindo))"
            DiarioDoTeleprompter.dizer(linha)
            Diagnostico.nota("APP CAMERA " + linha)
            degrau = novo
            if novo == .nenhum { previaMostradaPelaPessoa = false }
            if novo == .gravacaoParada { gravador.pararPeloCalor() }
        }
        aplicarDegraus()
    }

    /// Põe a prévia e a captura no estado do degrau (a cada janela: a captura só volta sem gravação de pé).
    func aplicarDegraus() {
        dono.pausarPrevia(degrau >= .previaPausada && !previaMostradaPelaPessoa)
        let reduzir = degrau == .capturaReduzida
        if reduzir != dono.capturaReduzida, gravador.estado == .parada {
            dono.reduzirCaptura(reduzir)
        }
    }

    /// Gravando com a captura em 720p (o degrau 3, e a pessoa tocou em Gravar depois): o arquivo sai em
    /// 720p. A faixa diz (revisão de 27/09, M4; a decisão entre avisar e recusar é do Pessoa Exemplo).
    var gravandoNaCapturaReduzida: Bool { dono.capturaReduzida && gravador.estado.ocupada }

    /// O toque na prévia pausada: mostra de novo (os outros degraus seguem).
    func mostrarPrevia() {
        previaMostradaPelaPessoa = true
        DiarioDoTeleprompter.dizer("degraus da transmissão: a pessoa pediu a prévia de volta")
        aplicarDegraus()
    }

    /// `ajustesGravados: false`: os ajustes da tela só em memória, nos padrões (o retrato de bancada).
    init(ajustesGravados: Bool = true) {
        ajustesDaCamera = AjustesDaTelaComCamera(gravados: ajustesGravados)
        camera = EmissorDeCamera(dono: dono)
        gravador = GravadorLocal(dono: dono)
        gravacao = GravacaoDoPrompter(gravador: gravador)
        // A raiz da tela lê os ajustes (o lado do texto, a divisão): a mudança deles tem de
        // redesenhá-la na hora, e não só quando a folha de Ajustes fecha.
        repasse = ajustesDaCamera.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // R9: o diário diz em que tela os controles estão, e o degrau forçado da bancada passa pelos
        // degraus desta tela (os degraus são dela; por fora, `aplicarDegraus` o desfaria).
        dono.controles.tela = "r5"
        dono.controles.forcarDegrau = { [weak self] sim in self?.forcarDegrauDaBancada(sim) }
    }

    /// **O degrau forçado** (`--degrau-forcado`, o roteiro de prova do R9, §5.3): o degrau da tela vai
    /// a "captura em 720p" (com a prévia pausada, como no calor de verdade) ou volta a nenhum, e
    /// `aplicarDegraus` faz o resto. Só a bancada chama.
    func forcarDegrauDaBancada(_ sim: Bool) {
        let novo: DegrausDaTransmissao.Degrau = sim ? .capturaReduzida : .nenhum
        Diagnostico.nota("APP CAMERA degraus da transmissão: \(degrau.nome) → \(novo.nome) (forçado pela bancada)")
        degrau = novo
        previaMostradaPelaPessoa = false
        aplicarDegraus()
    }
}

/// **O teleprompter com câmera** (R5, fase 1): o roteiro colado à lente e a prévia da frontal na
/// mesma tela, com a câmera transmitida pela rede e o prompter controlável pela 7979.
/// `docs/teleprompter-com-camera.md` §0 e §2.2.
///
/// # O que esta tela possui, e por quanto tempo
///
/// - **O dono da captura** (`DonoDaCaptura`): a câmera frontal abre quando a tela abre e fecha
///   quando ela fecha. A prévia é uma camada sobre a mesma sessão, e existe desde a espera.
/// - **A sessão da câmera** (`EmissorDeCamera` no modo pendurado): hospeda na porta do
///   espelhamento, se pendura no dono quando um receptor pareia, se solta quando ele cai e volta a
///   esperar com o mesmo PIN. **A câmera não reabre**, e a prévia não pisca.
/// - **A sessão do prompter** (`ModeloDoTeleprompter`, papel `"teleprompter"`, a 7979): a mesma do
///   prompter comum. As duas sessões são independentes (§3): derrubar o controle não mexe no
///   vídeo, e derrubar o receptor não mexe no texto.
///
/// # A gravação local (fase 3)
///
/// O botão Gravar/Parar mora na linha de estado da faixa (`BotaoDeGravar`), com o tempo e o espaço
/// que sobra enquanto grava. Grava **a câmera, sem o texto**, com o som do microfone (silêncio com o
/// botão do microfone desligado), na melhor imagem do aparelho (a captura desta tela é montada com
/// `melhorImagem`), num MP4 fragmentado que vai ao rolo da câmera ao terminar (`GravadorLocal`,
/// `TomadaDeGravacao`). Não depende da rede: grava sem receptor, e o receptor entra e sai sem tocar no
/// arquivo. Gravando, a orientação trava e o ângulo da conexão congela (§5.2). O controle remoto
/// começa, para e vê (`GravacaoDoPrompter`, `docs/contrato-teleprompter.md` §13). A tela para a
/// gravação quando vai para o segundo plano e quando fecha (§5.3).
///
/// # O microfone (fase 2)
///
/// Um botão na linha de estado (`BotaoDoMicrofone`, o mesmo da câmera comum), que começa desligado.
/// A entrada de áudio entra numa `AVCaptureSession` **só do microfone**, dentro do dono (ligar na
/// da câmera parou a imagem por 434 ms no iPhone X, §8.5), e a track de microfone vai sempre na
/// oferta da sessão da câmera, calada até o botão ligar (§4.2). Negada a permissão, o
/// aviso diz por quê, e aberto oferece os Ajustes.
///
/// # Nada entre o texto e a lente (pedido do Pessoa Exemplo, 24/09)
///
/// Nenhum aviso, faixa, cartão ou botão fica entre o texto e a lente, nem sobre as primeiras linhas
/// do texto do lado dela — é ali que a pessoa lê. Os avisos (o controle caiu, a câmera, o
/// microfone), o estado das sessões e a barra moram na faixa (`FaixaDaTelaComCamera`), na ponta
/// **oposta** à lente; a barra de estado do iOS some quando a lente está em cima, e o indicador de
/// início quando ela está embaixo. O que fica do sistema e não é nosso: os pontos verde e laranja
/// (câmera e microfone), os alertas de permissão e as folhas abertas por toque.
///
/// # A divisão
///
/// O texto vai **do lado da lente quando ela está em cima ou embaixo**, e **em cima quando ela está
/// de lado** (`LadoDoTexto.doAutomatico`, pedido do Pessoa Exemplo de 30/09): no iPhone em pé e deitado, e no
/// iPad em pé, o texto em cima e a prévia embaixo; no iPad deitado, na borda longa, em cima. O
/// automático nunca põe lado a lado; o ajuste ainda põe. 50/50 por padrão, a borda arrastável (mínimo
/// de 20 % por lado) e gravada por forma (`FormaDaDivisao`). No iPhone deitado a faixa dos controles
/// fica ao lado da prévia, e não no pé (`DivisaoDaTelaComCamera`). **Esconder a prévia** dá a tela
/// inteira ao texto e só esconde a vista: a câmera continua transmitindo.
///
/// # Os globais do app, com cuidado
///
/// - **A tela acesa** é pedida com dono (`TelaAcesa`), não escrita às cegas: uma câmera no ar com a
///   tela apagando suspenderia o app e derrubaria a transmissão.
/// - **A orientação** (`Orientacao`, estático) é presa pela escolha **desta** tela, gravada numa
///   chave própria (`OrientacaoDoPrompter.chaveDaTelaComCamera`): o prompter comum costuma ficar
///   preso em Paisagem sob o vidro, e esta tela não pode herdar isso. Ao sair, a máscara volta ao
///   `Info.plist`.
struct TelaDoPrompterComCamera: View {
    @StateObject private var modelo: ModeloDoTeleprompter
    @StateObject private var orientacao: EscolhaDeOrientacao
    @StateObject private var ajustes = AjustesLocais()
    @StateObject private var pecas: PecasDaTelaComCamera
    let voltar: () -> Void

    @State private var telaCheia = false
    @State private var previaEscondida = false
    /// **O painel "Ajustes da câmera"** (R9, `docs/controles-de-camera.md` §4.2): em cima da metade do
    /// texto — a prévia já ocupa a outra metade, e enquanto se ajusta a câmera o texto não é o assunto.
    @State private var painelDaCamera = false
    /// A última sonda do toque feita (a bancada do R9).
    @State private var sondaFeita = 0
    @State private var folha: Folha?
    /// A altura medida da faixa de controles (avisos, estado e barra). Começa numa estimativa; a
    /// primeira medida a corrige antes de a pessoa ver.
    @State private var alturaDaFaixa: CGFloat = 112
    /// A fração do texto durante um arrasto da borda (antes de gravar).
    @State private var arrastandoDe: Double?
    @State private var comecou = false
    /// A orientação da interface, lida da cena a cada giro: decide o lado da lente. Um giro de
    /// uma paisagem para a outra não muda o tamanho, e sem este estado a divisão não seria refeita.
    @State private var interface: UIInterfaceOrientation = .portrait
    /// A tela saiu: um pedido de permissão que volte depois não abre câmera nenhuma.
    @State private var saiu = SaidaDaTela()
    /// A vez do registro desta tela em `FechoDaTela.comCamera`.
    @State private var vezDoFecho = 0
    /// O que impede a câmera de abrir (permissão, aparelho sem frontal), para a tela dizer.
    @State private var problemaDaCamera: ProblemaDaCamera?
    @Environment(\.scenePhase) private var etapa
    @Environment(\.horizontalSizeClass) private var classeHorizontal

    enum Folha: String, Identifiable {
        case ajustes, editor, endereco, enderecoDaCamera
        var id: String { rawValue }
    }

    struct ProblemaDaCamera: Equatable {
        let texto: String
        let podeAbrirAjustes: Bool
    }

    /// Referência, e não valor: o fecho do pedido de permissão lê isto depois que a tela saiu.
    final class SaidaDaTela { var saiu = false }

    /// O nome com que esta tela pede a tela acesa.
    private static let donoDaTelaAcesa = "teleprompter-com-camera"

    /// `orientacaoDoRetrato`: só o retrato de bancada (`RetratosDeBancada`, "r5", 30/09) — a tela abre
    /// presa nesta orientação, numa chave de jogar fora, com os ajustes dela (lado do texto, divisão,
    /// espelho da prévia) nos padrões e só em memória; a escolha da pessoa
    /// (`OrientacaoDoPrompter.chaveDaTelaComCamera`, `AjustesDaTelaComCamera`) fica como estava.
    init(voltar: @escaping () -> Void, orientacaoDoRetrato: OrientacaoDoPrompter? = nil) {
        self.voltar = voltar
        _modelo = StateObject(wrappedValue: ModeloDoTeleprompter(
            papel: .teleprompter, bancada: BancadaDoTeleprompter.consumir()))
        _orientacao = StateObject(wrappedValue: orientacaoDoRetrato.map {
            EscolhaDeOrientacao(chave: RetratosDeBancada.chaveDaOrientacaoDaR5, inicial: $0)
        } ?? EscolhaDeOrientacao(chave: OrientacaoDoPrompter.chaveDaTelaComCamera))
        _pecas = StateObject(wrappedValue: PecasDaTelaComCamera(ajustesGravados: orientacaoDoRetrato == nil))
    }

    var body: some View {
        GeometryReader { geo in
            let d = divisao(geo.size)
            // O leiaute no diário, uma vez por mudança (30/09): é a testemunha, ao lado da foto, de
            // qual conta valeu (a fração não entra: o arrasto não enche o diário).
            let leiaute = "\(Int(geo.size.width))x\(Int(geo.size.height)) lente \(ladoDaLente.rawValue), "
                + "texto \(d.lado.rawValue), forma \(d.forma.rawValue), faixa "
                + (d.faixaAoLado ? "ao lado da prévia" : previaEscondida ? "no pé (prévia escondida)" : "no pé")
            ZStack(alignment: .topLeading) {
                Color.black

                // A prévia **fica montada** mesmo escondida: esconder é `isHidden` (ver
                // `PreVisualizacao.escondida`), e remontar a camada a cada toque seria o piscar que
                // esta tela existe para não ter.
                PainelDaPrevia(dono: pecas.dono, escondida: previaEscondida, problema: problemaDaCamera,
                               baixa: d.previa.height < 200,
                               pausadaPeloCalor: pecas.degrau >= .previaPausada && !pecas.previaMostradaPelaPessoa,
                               mostrar: { pecas.mostrarPrevia() },
                               abrirAjustes: abrirAjustes)
                    .frame(width: d.previa.width, height: d.previa.height)
                    .clipped()
                    .offset(x: d.previa.minX, y: d.previa.minY)
                    .allowsHitTesting(!previaEscondida)

                painelDoTexto
                    .frame(width: d.texto.width, height: d.texto.height)
                    .clipped()
                    .offset(x: d.texto.minX, y: d.texto.minY)

                // Com a prévia mostrando um problema (a permissão, sem frontal), a zona não entra: o
                // botão "Abrir os Ajustes" dela pode cair nos 44 pt (revisão de 27/09).
                if !previaEscondida && !telaCheia && problemaDaCamera == nil {
                    // **A zona inteira do lado da prévia** (bancada de 27/09, iPad: a zona centrada na
                    // linha entrava 22 pt no texto e roubava o arrasto das marcas do enquadramento).
                    if let z = ZonaDaBordaDaDivisao.zona(texto: d.texto, previa: d.previa) {
                        BordaDaDivisao(ponta: ZonaDaBordaDaDivisao.pontaDaAlca(texto: d.texto, previa: d.previa),
                                       fracao: d.fracao,
                                       ajustar: { passo in
                                           pecas.ajustesDaCamera.dividir(AjustesDaTelaComCamera.limitar(d.fracao + passo),
                                                                         forma: d.forma, gravar: true)
                                       })
                            .frame(width: z.width, height: z.height)
                            .offset(x: z.minX, y: z.minY)
                            .gesture(arrastoDaBorda(d))
                    }
                }

                // R9 (§4.2): o painel dos ajustes da câmera, por cima do texto, sem véu na prévia.
                if painelDaCamera {
                    let r = retanguloDoPainel(d)
                    PainelDosAjustesDaCamera(controles: pecas.dono.controles) { painelDaCamera = false }
                        .frame(width: r.width, height: r.height)
                        .background(GeometryReader { g in
                            // Os quadros no diário (a prova "o painel fica sobre o texto"): o pedido,
                            // o desenhado (o global menos a origem desta vista) e as duas metades.
                            Color.clear.onAppear {
                                let o = geo.frame(in: .global).origin
                                let f = g.frame(in: .global).offsetBy(dx: -o.x, dy: -o.y)
                                Diagnostico.nota("APP CAMERA painel na R5: painel=\(Self.quadro(r)) desenhado=\(Self.quadro(f))"
                                    + " texto=\(Self.quadro(d.texto)) previa=\(Self.quadro(d.previa))"
                                    + " tela=\(Int(geo.size.width))x\(Int(geo.size.height)) minima=\(Int(PainelDosAjustesDaCamera.alturaMinima))")
                            }
                        })
                        .offset(x: r.minX, y: r.minY)
                }

                // **A faixa dos controles é dela**, fora da prévia e fora do texto: a prova de
                // 24/09 (iPhone X, 375x812) mostrou os controles morando na prévia e cobrindo-a
                // quase inteira. A altura é medida (na altura natural, antes do limite abaixo) e entra
                // na divisão.
                //
                // **Ao lado da prévia** (30/09, o iPhone deitado) a faixa fica na banda: mais alta que
                // ela (os avisos abertos, letra grande), é cortada na altura da banda, e o que sobra
                // não cobre o texto nem pega toque nele. O corte guarda o **pé** — a barra, com o X e
                // o rolar — e os avisos abertos ganham rolagem própria (`alturaMaxima`, a altura da
                // banda, e não a da faixa: a medida depende da lista, e a lista do teto). Nos outros
                // leiautes não há teto, e nada muda.
                faixa(alturaMaxima: d.tetoDaFaixa)
                    .frame(width: d.faixa.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: AlturaDaFaixaDaTelaComCamera.self, value: g.size.height)
                    })
                    .frame(height: d.faixaAoLado ? d.faixa.height : nil, alignment: .bottom)
                    .clipped()
                    .contentShape(Rectangle())
                    .offset(x: d.faixa.minX, y: d.faixa.minY)
            }
            // R9, a bancada: o roteiro de prova abre e fecha o painel, e pede a sonda do toque.
            .onReceive(pecas.dono.controles.$pedidoDoPainel) { p in
                if let p, p != painelDaCamera { painelDaCamera = p }
            }
            .onReceive(pecas.dono.controles.$pedidoDaSonda) { p in
                // Uma vez por pedido: o `@Published` repete o valor de agora a quem se inscreve, e uma
                // sonda repetida tocaria na prévia de novo (e desfaria as travas do roteiro).
                guard let p, p.vez > sondaFeita else { return }
                sondaFeita = p.vez
                sondarToque(geo, d, contexto: p.contexto)
            }
            .onPreferenceChange(AlturaDaFaixaDaTelaComCamera.self) { h in
                if abs(h - alturaDaFaixa) > 0.5 { alturaDaFaixa = h }
            }
            // O giro da interface muda a orientação da conexão de captura: a geometria é a
            // testemunha de que a interface já girou (a mesma razão de `TelaDaCamera.tamanho`).
            .onChange(of: geo.size) { _ in acompanharOrientacao() }
            .onAppear { DiarioDoTeleprompter.dizer("tela com câmera: divisão \(leiaute)") }
            .onChange(of: leiaute) { DiarioDoTeleprompter.dizer("tela com câmera: divisão \($0)") }
        }
        .ignoresSafeArea(edges: telaCheia ? .all : [])
        // **Nada do sistema entre o texto e a lente** (pedido do Pessoa Exemplo depois da prova de 24/09):
        // a barra de estado mora na borda de cima, e o indicador de início na de baixo. Com a lente
        // numa delas, o que mora ali sai — sem o relógio, o texto sobe até a borda da lente num
        // aparelho sem entalhe (iPhone 7), e no iPhone X fica logo abaixo do entalhe. Ver
        // `ladoDaLente` e a regra da faixa (`divisao`).
        .statusBar(hidden: telaCheia || ladoDaLente == .cima)
        .modifier(IndicadorDeInicio(escondido: telaCheia || ladoDaLente == .baixo))
        .preferredColorScheme(.dark)
        .sheet(item: $folha) { f in
            switch f {
            case .ajustes:
                FolhaDeAjustes(modelo: modelo, voltarAoComeco: { modelo.voltarAoComeco() },
                               orientacao: orientacao, ajustes: ajustes,
                               ajustesDaCamera: pecas.ajustesDaCamera) { folha = nil }
            case .editor: EditorDoRoteiro(modelo: modelo) { folha = nil }
            case .endereco: FolhaDoEndereco(modelo: modelo) { folha = nil }
            case .enderecoDaCamera: FolhaDoEnderecoDaCamera(camera: pecas.camera) { folha = nil }
            }
        }
        .onReceive(pecas.ajustesDaCamera.$previaEspelhada) { pecas.dono.espelharPrevia = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // A notificação vem antes de a interface terminar de girar (`TelaDaCamera.tamanho`):
            // agora e de novo depois do giro.
            acompanharOrientacao()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { acompanharOrientacao() }
        }
        .onAppear(perform: aparecer)
        .onDisappear(perform: sair)
        .onChange(of: etapa) { nova in
            // O prompter solta a sessão no segundo plano e volta na frente, como o comum. A câmera o
            // iOS interrompe sozinho (o dono diz, e a volta pede um quadro chave); a sessão da
            // câmera que cair nesse meio tempo é solta e volta a esperar pelo laço de hospedagem.
            if nova == .background, !saiu.saiu {
                // §5.3: no iOS a câmera para fora da tela, e o arquivo fecha (e vai ao rolo, com o tempo
                // de segundo plano que o gravador pede). **Gravando no segundo plano: não** (decidido
                // em §8.12.9) — a gravação para, como no iPhone, onde o iOS interrompe a câmera.
                DiarioDoTeleprompter.dizer("tela com câmera: segundo plano — a gravação para, a captura pausa")
                pecas.gravacao.pararAntesDaSessaoCair(motivo: "o app saiu da tela")
                modelo.aoIrParaOSegundoPlano()
                // **A captura pausa** (§8.12.9): no iPad o sistema pode deixar a câmera rodando fora do
                // primeiro plano; câmera nenhuma fica capturando sem a prévia à vista.
                pecas.dono.pausarNoSegundoPlano()
            }
            if nova == .active, !saiu.saiu {
                DiarioDoTeleprompter.dizer("tela com câmera: primeiro plano — a captura volta")
                pecas.dono.retomarDoSegundoPlano()
                TelaAcesa.reafirmar()
                orientacao.aplicar(por: "a tela com câmera voltou ao primeiro plano")
                modelo.aoVoltarAoPrimeiroPlano()
                acompanharOrientacao()
            }
        }
    }

    // --- o ciclo ---------------------------------------------------------------------------------

    private func aparecer() {
        // Fechada (um `onDisappear` espúrio, ou o X) e aparecendo de novo: nada é pedido outra vez —
        // o fecho roda uma vez só, e não haveria quem soltasse a tela acesa e a orientação (revisão de
        // 27/09, M1).
        guard !saiu.saiu else {
            DiarioDoTeleprompter.dizer("tela com câmera: apareceu depois de fechada; nada é reaberto")
            return
        }
        TelaAcesa.pedir(TelaDoPrompterComCamera.donoDaTelaAcesa)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientacao.aplicar(por: "a tela com câmera abriu")
        acompanharOrientacao()
        guard !comecou else { return }
        comecou = true
        DiarioDoTeleprompter.dizer("tela com câmera: aberta (\(Identidade.descricaoDoAparelho()))")
        // Quanto a principal ficou presa nos primeiros 8 s da tela (§8.12.10): a medida do "congelou".
        MedidorDaPrincipal.medir(por: 8) { maior, soma in
            DiarioDoTeleprompter.dizer(String(format: "tela com câmera: a principal ficou presa no máximo %.0f ms"
                                              + " (soma dos atrasos acima de 50 ms: %.0f ms) nos primeiros 8 s", maior * 1000, soma * 1000))
        }
        // **O fecho não depende do `onDisappear`** (§8.12.9, o iPad de 27/09): registrado aqui, com as
        // peças por referência (e não a vista), e chamado pelo X, pela raiz quando o papel muda e pelo
        // `onDisappear` — o primeiro fecha, os outros não fazem nada.
        do {
            let (p, m, o, s) = (pecas, modelo, orientacao, saiu)
            vezDoFecho = FechoDaTela.comCamera.registrar { motivo in
                TelaDoPrompterComCamera.fecharTudo(pecas: p, modelo: m, orientacao: o, saiu: s, motivo: motivo)
            }
        }

        // O prompter, como no comum.
        let st = modelo.replica.habilitarSegurar()
        DiarioDoTeleprompter.dizer("prompter: segurar para rolar ligado (\(SessaoDoTeleprompter.nome(st)))")
        // **O espelho do texto nasce desligado nesta tela** (§2.5): o espelho é o do vidro, e aqui
        // não há vidro — a pessoa lê direto na tela. O controle remoto pode ligá-lo. A réplica é a
        // mesma do prompter comum (o salvo do papel `teleprompter`): o valor de antes volta no fim
        // (`sair`), se ninguém o tiver mudado aqui.
        if modelo.estado.espelho {
            pecas.espelhoParaDevolver = true
            modelo.definirEspelho(false)
        }
        let b = modelo.bancada
        if let porta = b?.porta {
            modelo.hospedar(porta: porta, pin: b?.pin)
        } else {
            modelo.hospedarNaPortaDoTeleprompter(pin: b?.pin)
        }
        BancadaDoTeleprompter.ligarNoPrompter(modelo, opcoes: b)
        if let s = b?.esconderPreviaApos, s > 0 {
            // Escondida por **pelo menos 30 s**: três relatos de 10 s do dono (`escondida=true`,
            // `camera=… fps`) caem inteiros dentro dela. Com 10 s cabia um, ou nenhum.
            let escondidaPor = max(s, 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [saiu] in
                guard !saiu.saiu else { return }
                DiarioDoTeleprompter.dizer("bancada: prévia escondida (--esconder-previa-apos \(s)); "
                    + "volta em \(Int(escondidaPor)) s")
                previaEscondida = true
                DispatchQueue.main.asyncAfter(deadline: .now() + escondidaPor) {
                    guard !saiu.saiu else { return }
                    DiarioDoTeleprompter.dizer("bancada: prévia à mostra de novo")
                    previaEscondida = false
                }
            }
        }

        // A câmera: a permissão é **pedida** (não só lida), e só a frontal.
        pecas.dono.espelharPrevia = pecas.ajustesDaCamera.previaEspelhada
        let s = saiu
        let dono = pecas.dono
        let camera = pecas.camera
        let gravador = pecas.gravador
        // A gravação: a tela diz ao prompter que grava, e os pedidos do controle chegam à ponte.
        pecas.gravacao.ligar(modelo: modelo, orientacao: orientacao)
        // O que ficou de uma vez anterior (o processo morto gravando) vai ao rolo agora.
        GravacoesPendentes.recuperar(por: "a tela com câmera abriu")
        DonoDaCaptura.pedirPermissao(textoDeNegada: TelaDoPrompterComCamera.textoDeNegada) { resposta in
            guard !s.saiu else { return }
            switch resposta {
            case let .recusada(motivo, podeAbrirAjustes):
                Diagnostico.nota("APP CAMERA sem permissão de câmera ajustes=\(podeAbrirAjustes) (tela com câmera)")
                problemaDaCamera = ProblemaDaCamera(texto: motivo, podeAbrirAjustes: podeAbrirAjustes)
            case .concedida:
                guard let frontal = Origem.frontal() else {
                    problemaDaCamera = ProblemaDaCamera(texto: tr("Este aparelho não tem câmera frontal. "
                        + "O texto funciona; a câmera, não."), podeAbrirAjustes: false)
                    return
                }
                // A melhor imagem da frontal: é a que o arquivo grava (a rede reduz ao cardápio).
                // **Fora da principal** (§8.12.10): a tela aparece na hora, com o "Aguarde…".
                dono.montarSemTravar(frontal, melhorImagem: true) { erro in
                    guard !s.saiu else { return }
                    if let erro {
                        Diagnostico.falha("APP CAMERA a captura não montou (tela com câmera): \(SanitizacaoDoLog.causaExterna(erro))")
                        problemaDaCamera = ProblemaDaCamera(texto: erro, podeAbrirAjustes: false)
                        return
                    }
                    dono.ligar()
                    acompanharOrientacao()
                    // Os degraus da transmissão ouvem o som da rede a cada 10 s (§8.12.16).
                    let p = pecas
                    camera.aoAvaliarSom = { [weak p] ruim, transmitindo, quente, resumo in
                        p?.avaliar(ruim: ruim, transmitindo: transmitindo, quente: quente, resumo: resumo)
                    }
                    camera.comecarPendurado()
                    BancadaDaGravacao.ligar(gravador) { !s.saiu }
                }
            }
        }
    }

    private func sair() {
        FechoDaTela.comCamera.esquecer(vez: vezDoFecho)
        TelaDoPrompterComCamera.fecharTudo(pecas: pecas, modelo: modelo, orientacao: orientacao, saiu: saiu,
                                           motivo: "a vista sumiu (onDisappear)")
    }

    /// **O fecho da tela, uma vez**, venha de onde vier (`FechoDaTela`): a gravação, o prompter, a
    /// transmissão e o dono. Estático e com as peças por referência: chamado depois de a vista sumir,
    /// não pode ler `@StateObject` nenhum. Um segundo depois, confere e diz — pela saída padrão, que o
    /// `idevicedebug` guarda sem perda — que a captura e o prompter fecharam.
    static func fecharTudo(pecas: PecasDaTelaComCamera, modelo: ModeloDoTeleprompter,
                           orientacao: EscolhaDeOrientacao, saiu: SaidaDaTela, motivo: String) {
        guard !saiu.saiu else { return }
        saiu.saiu = true
        DiarioDoTeleprompter.dizer("tela com câmera: fechando (\(motivo))")
        TelaAcesa.soltar(TelaDoPrompterComCamera.donoDaTelaAcesa)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        // A gravação para antes de tudo (o arquivo fecha e vai ao rolo mesmo com a tela fechada), e o
        // prompter deixa de dizer que grava antes de a sessão dele parar.
        pecas.gravacao.desligar(motivo: "a tela com câmera fechou")
        orientacao.soltar()
        modelo.sair()
        // O espelho do prompter comum de volta, depois de a sessão parar (o controle não vê esta
        // volta) — e só se continua desligado, isto é, se ninguém o ligou durante a tela.
        if pecas.espelhoParaDevolver, !modelo.estado.espelho {
            modelo.definirEspelho(true)
            modelo.replica.salvar(motivo: "espelho do prompter comum devolvido")
            DiarioDoTeleprompter.dizer("tela com câmera: espelho do texto devolvido ao prompter comum")
        }
        // A transmissão primeiro (ela se solta do dono e o laço desmonta a sessão), a câmera depois.
        pecas.camera.parar()
        pecas.dono.fechar()
        DiarioDoTeleprompter.dizer("tela com câmera: fechada")
        // A conferência, 3 s depois (o `pararDeRodar` espera a fila do microfone e um `startRunning`
        // pendente; o iPad lento de 27/09 pode passar de 1 s). O que se espera ver em menos de 1 s é a
        // linha `dono: captura fechada em N ms`, e esta confirma.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let camera = pecas.dono.sessao.isRunning
            let prompter = modelo.temSessao
            // Parada, ou falhou (a espera cancelada pode terminar como falha): nada no ar.
            let transmissao: Bool
            switch pecas.camera.fase {
            case .esperando, .transmitindo, .encerrando, .pedindoPermissao: transmissao = true
            default: transmissao = false
            }
            if camera || prompter || transmissao {
                let t = "tela com câmera: VAZAMENTO 3 s depois de fechar — captura rodando=\(camera)"
                    + " prompter com sessão=\(prompter) transmissão=\(pecas.camera.fase)"
                Diagnostico.falha("APP CAMERA " + t)
                DiarioDoTeleprompter.dizer(t)
            } else {
                DiarioDoTeleprompter.dizer("tela com câmera: conferido 3 s depois — dono: captura fechada, prompter: fechado,"
                    + " transmissão parada")
            }
        }
    }

    static var textoDeNegada: String {
        tr("O Quall não tem acesso à câmera deste aparelho. Abra %@ e ligue; "
           + "o texto continua funcionando enquanto isso.", trSistema("Ajustes → Quall Studio → Câmera"))
    }

    private func abrirAjustes() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// A orientação da conexão de captura segue a **cena** (ver `TelaDaCamera.acompanharOrientacao`).
    private func acompanharOrientacao() {
        let cena = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let o = cena?.interfaceOrientation ?? .portrait
        if o != interface { interface = o }
        pecas.dono.acompanharOrientacao(o)
    }

    private func alternarTelaCheia() {
        withAnimation(.easeInOut(duration: 0.2)) { telaCheia.toggle() }
        DiarioDoTeleprompter.dizer("tela com câmera: tela cheia \(telaCheia ? "entrou" : "saiu")")
    }

    private func alternarPrevia() {
        previaEscondida.toggle()
        DiarioDoTeleprompter.dizer("tela com câmera: prévia \(previaEscondida ? "escondida" : "à mostra")"
            + " — a câmera continua (rodando=\(pecas.dono.sessao.isRunning))")
    }

    // --- a divisão -------------------------------------------------------------------------------

    /// Onde a lente está agora, **independente do ajuste do lado do texto**.
    private var ladoDaLente: LadoDoTexto {
        LadoDoTexto.daLente(idioma: UIDevice.current.userInterfaceIdiom, interface: interface)
    }

    /// O lado do texto agora: o do ajuste, ou o do automático para a lente onde ela está (30/09: com
    /// a lente de lado, em cima — `LadoDoTexto.doAutomatico`).
    private var ladoAgora: LadoDoTexto {
        pecas.ajustesDaCamera.lado.resolvido(lente: ladoDaLente)
    }

    /// A divisão: **texto | prévia | faixa** (`DivisaoDaTelaComCamera`, a conta pura; o comentário
    /// longo está lá). A fração é a guardada para a forma desta tela — ou a do arrasto.
    ///
    /// **30/09, o pedido do Pessoa Exemplo para a horizontal**: no iPhone deitado o automático deixou de pôr
    /// o texto ao lado da prévia, colado na lente, e passou a pô-lo em cima, na largura toda, como em
    /// pé; a faixa dos controles saiu do pé (os 724x354 da área segura do iPhone X não comportam
    /// texto, prévia e faixa empilhados: o texto parava em 84 pt) e foi para uma coluna ao lado da
    /// prévia. A fração dessa forma tem chave própria (`FormaDaDivisao.empilhadaLarga`). O iPad deitado
    /// e tudo que é mais alto que largo ficam como estavam.
    private func divisao(_ t: CGSize) -> DivisaoDaTelaComCamera {
        let lado = ladoAgora
        let forma = DivisaoDaTelaComCamera.forma(t, lado: lado)
        return DivisaoDaTelaComCamera.calcular(t, lado: lado,
                                               fracao: arrastandoDe ?? pecas.ajustesDaCamera.fracaoDoTexto(forma),
                                               alturaDaFaixa: alturaDaFaixa, previaEscondida: previaEscondida)
    }

    /// "x,y,largura,altura", em pontos inteiros (o diário da bancada).
    static func quadro(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }

    /// **A sonda do toque** (R9, a bancada): no centro do texto e no centro da prévia, pergunta à
    /// janela quem recebe o toque (`hitTest`) e, se for a zona de toque da prévia, toca por ela — o
    /// mesmo caminho do dedo. Prova que o texto (e a prévia pausada) não gera ponto, e que a prévia
    /// gera. Só o roteiro de prova chama.
    private func sondarToque(_ geo: GeometryProxy, _ d: DivisaoDaTelaComCamera, contexto: String) {
        let o = geo.frame(in: .global).origin
        let janela = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let janela else { Diagnostico.nota("APP CAMERA sonda do toque: sem janela"); return }
        for (nome, r) in [("texto", d.texto), ("previa", d.previa)] {
            let p = CGPoint(x: o.x + r.midX, y: o.y + r.midY)
            let v = janela.hitTest(p, with: nil)
            let zona = sequence(first: v, next: { $0?.superview }).compactMap { $0 }
                .first { $0 is VistaDoToqueNaPrevia } as? VistaDoToqueNaPrevia
            let gerou = zona?.simularToque(naJanela: p) ?? false
            Diagnostico.nota("APP CAMERA sonda do toque: contexto=\(contexto) alvo=\(nome)"
                + String(format: " ponto=%.0f,%.0f", p.x, p.y)
                + " recebe=\(zona != nil ? "zona_da_previa" : v.map { String(describing: type(of: $0)) } ?? "nada")"
                + " gera_ponto=\(gerou ? "sim" : "nao") painel=\(painelDaCamera ? "aberto" : "fechado")"
                + " previa_pausada=\(pecas.degrau >= .previaPausada && !pecas.previaMostradaPelaPessoa ? "sim" : "nao")")
        }
    }

    /// Onde o painel dos ajustes da câmera fica: o retângulo do texto, e, quando o texto está baixo
    /// demais para o painel caber sem rolar (a pessoa arrastou a borda até 20 %), a altura mínima do
    /// painel a partir da borda **longe** da prévia — o que passar cobre a ponta da prévia vizinha ao
    /// texto, e não o meio dela.
    private func retanguloDoPainel(_ d: DivisaoDaTelaComCamera) -> CGRect {
        var r = d.texto
        let minima = PainelDosAjustesDaCamera.alturaMinima
        guard r.height < minima else { return r }
        if r.midY <= d.previa.midY {
            r.size.height = minima
        } else {
            r.origin.y = r.maxY - minima
            r.size.height = minima
        }
        return r
    }

    /// Arrastar a borda: a fração do texto segue o dedo, e grava ao soltar.
    private func arrastoDaBorda(_ d: DivisaoDaTelaComCamera) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                let base = pecas.ajustesDaCamera.fracaoDoTexto(d.forma)
                let delta: Double
                switch d.lado {
                case .baixo: delta = -Double(g.translation.height / d.eixo)
                case .esquerda: delta = Double(g.translation.width / d.eixo)
                case .direita: delta = -Double(g.translation.width / d.eixo)
                default: delta = Double(g.translation.height / d.eixo)
                }
                arrastandoDe = AjustesDaTelaComCamera.limitar(base + delta)
            }
            .onEnded { _ in
                if let f = arrastandoDe { pecas.ajustesDaCamera.dividir(f, forma: d.forma, gravar: true) }
                arrastandoDe = nil
            }
    }

    // --- o texto ---------------------------------------------------------------------------------

    private var painelDoTexto: some View {
        ZStack {
            Color.black
            // As setas da linha de leitura por cima das marcas do enquadramento, como no prompter.
            VistaDoRoteiro(modelo: modelo, ajustes: ajustes, aoTocar: alternarTelaCheia)
                // **Nada do lado da lente** (24/09): as guias ciano (uma linha na altura inteira, na
                // borda da coluna — com a lente à esquerda em paisagem, entre o texto e ela) só com a
                // folha de Ajustes aberta ou durante o arrasto, e as marcas no pé do texto, longe da
                // lente, salvo com a lente embaixo. As setas da linha de leitura ficam onde estão.
                .overlay(EnquadramentoDoTexto(modelo: modelo, ajustes: ajustes,
                                              guias: folha == .ajustes,
                                              // A barra não cobre mais o texto (mora na faixa).
                                              fundoDoAlto: 0, topoDaBarra: .greatestFiniteMagnitude,
                                              giro: orientacao.giroDoTexto,
                                              noPe: ladoDaLente != .baixo))
                .overlay(AlcasDaLinhaDeLeitura(modelo: modelo))
                .modifier(GiroDoTexto(escolha: orientacao))
        }
    }

    // --- os controles ----------------------------------------------------------------------------

    /// A faixa: os avisos numa linha, o estado das duas sessões numa linha, e a barra. Fora do
    /// texto e fora da prévia. Na tela cheia, só os avisos (o do controle sumido fica visível até
    /// ele voltar, como no prompter comum).
    private func faixa(alturaMaxima: CGFloat?) -> some View {
        FaixaDaTelaComCamera(modelo: modelo, ajustes: ajustes, camera: pecas.camera, dono: pecas.dono,
                             gravador: pecas.gravador, orientacao: orientacao,
                             giradaGravando: orientacao.presaPelaGravacao.map { $0 != interface } ?? false,
                             calor: CalorDoAparelho.compartilhado,
                             gravandoReduzida: pecas.gravandoNaCapturaReduzida,
                             tocarGravar: { pecas.gravacao.tocar() },
                             telaCheia: telaCheia,
                             abrirEndereco: { folha = .endereco }, abrirEnderecoDaCamera: { folha = .enderecoDaCamera },
                             alturaMaxima: alturaMaxima,
                             barra: barraDeBaixo)
    }

    private var barraDeBaixo: some View {
        HStack(spacing: 4) {
            botao("xmark", tr("Sair")) {
                FechoDaTela.comCamera.esquecer(vez: vezDoFecho)
                TelaDoPrompterComCamera.fecharTudo(pecas: pecas, modelo: modelo, orientacao: orientacao,
                                                   saiu: saiu, motivo: "o X")
                voltar()
            }
            botao("pencil", tr("Editar")) { folha = .editor }
            botao("slider.horizontal.3", tr("Ajustes")) { folha = .ajustes }
            // R9 (§4.1): os ajustes da câmera, na barra, com a engrenagem (`gearshape`, decisão do Pessoa Exemplo
            // de 01/10): o "Ajustes" do teleprompter ao lado segue com `slider.horizontal.3`.
            BotaoDaBarraDosAjustesDaCamera(controles: pecas.dono.controles, aberto: painelDaCamera) {
                painelDaCamera.toggle()
            }
            botaoQueRepete("tortoise.fill", tr("Mais devagar")) { modelo.definirVelocidade(modelo.estado.velocidade - 0.1) }
            Button(action: { [rolando = modelo.estado.rolando] in modelo.pedirRolando(!rolando) }) {
                Image(systemName: modelo.estado.rolando ? "pause.fill" : "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 52, maxWidth: 90, minHeight: 44)
                    .background(Estilo.acento)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(modelo.estado.rolando ? tr("Pausar") : tr("Rolar"))
            botaoQueRepete("hare.fill", tr("Mais depressa")) { modelo.definirVelocidade(modelo.estado.velocidade + 0.1) }
            botao(previaEscondida ? "video.slash" : "video", previaEscondida ? tr("Mostrar a prévia") : tr("Esconder a prévia")) {
                alternarPrevia()
            }
            if classeHorizontal == .regular {
                botao("arrow.up.left.and.arrow.down.right", tr("Tela cheia")) { alternarTelaCheia() }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(Estilo.superficie)
        .cornerRadius(14)
        .padding(.horizontal, 8)
    }

    /// O botão da barra que repete enquanto pressionado (a velocidade; `BotaoQueRepete`).
    private func botaoQueRepete(_ simbolo: String, _ rotulo: String, passo: @escaping () -> Void) -> some View {
        BotaoQueRepete(rotulo, passo: passo) {
            Image(systemName: simbolo)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.14))
                .cornerRadius(10)
        }
    }

    private func botao(_ simbolo: String, _ rotulo: String, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.14))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rotulo)
    }
}

/// O botão "Ajustes da câmera" no desenho da barra (R9, §4.1): apagado até a câmera montar.
private struct BotaoDaBarraDosAjustesDaCamera: View {
    @ObservedObject var controles: ControlesDaCamera
    let aberto: Bool
    let tocar: () -> Void

    var body: some View {
        Button(action: tocar) {
            Image(systemName: "gearshape")
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(aberto ? Estilo.acento : Color.white.opacity(0.14))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(!controles.prontos)
        .opacity(controles.prontos ? 1 : 0.4)
        .accessibilityLabel(tr("Ajustes da câmera"))
        .accessibilityAddTraits(aberto ? [.isSelected] : [])
    }
}

/// A área da prévia: a camada da câmera, ou o que impede a câmera de abrir.
private struct PainelDaPrevia: View {
    @ObservedObject var dono: DonoDaCaptura
    let escondida: Bool
    let problema: TelaDoPrompterComCamera.ProblemaDaCamera?
    /// **A prévia baixa** (menos de 200 pt; revisão de 30/09): o cartão do problema fica compacto. O
    /// iPhone X deitado dá à prévia 177 pt no 50/50 e 150 no teto, e o cartão inteiro (~187 pt)
    /// perdia o "Abrir os Ajustes" no corte da prévia — a única saída com a câmera negada.
    var baixa = false
    /// O degrau 1 da transmissão (§8.12.16): a prévia pausada, e um toque mostra de novo.
    var pausadaPeloCalor = false
    var mostrar: () -> Void = {}
    let abrirAjustes: () -> Void

    var body: some View {
        ZStack {
            PreVisualizacao(dono: dono, escondida: escondida)
            // R9 (§4.4): o toque foca e mede, **só na prévia**, e nunca com ela pausada (o "Toque para
            // mostrar" por cima), escondida, sem câmera ou antes do primeiro quadro.
            if !escondida, problema == nil, !pausadaPeloCalor, dono.entregando {
                ZonaDeToqueDaPrevia(dono: dono, controles: dono.controles)
            }
            // **"Aguarde…"** até o primeiro quadro (§8.12.10): a tela aparece na hora, e a câmera abre
            // fora da principal.
            if pausadaPeloCalor, problema == nil, !escondida {
                Button(action: mostrar) {
                    VStack(spacing: 8) {
                        Image(systemName: "thermometer").font(.title2)
                        Text(tr("Prévia pausada: aparelho quente")).font(.callout.weight(.semibold))
                        Text(tr("Toque para mostrar")).font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Prévia pausada: aparelho quente. Toque para mostrar."))
            } else if problema == nil, !escondida, !dono.entregando {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(tr("Aguarde… abrindo a câmera")).font(.callout)
                }
                .foregroundColor(.white)
                .accessibilityElement(children: .combine)
            }
            if let problema, !escondida {
                VStack(spacing: baixa ? 4 : 10) {
                    Image(systemName: "video.slash").font(baixa ? .title3 : .title)
                    Text(problema.texto)
                        .font(baixa ? .footnote : .callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if problema.podeAbrirAjustes {
                        Button(tr("Abrir os Ajustes"), action: abrirAjustes).font(baixa ? .subheadline.weight(.semibold) : .headline)
                    }
                }
                .foregroundColor(.white)
                .padding(baixa ? 8 : 24)
            }
        }
    }
}

/// A borda arrastável entre o texto e a prévia: uma alça visível **encostada na linha**, e uma zona
/// de toque de 44 pt **do lado da prévia** (`ZonaDaBordaDaDivisao`).
private struct BordaDaDivisao: View {
    let ponta: ZonaDaBordaDaDivisao.Ponta
    /// A fração do texto agora, para o VoiceOver.
    let fracao: Double
    /// O ajuste do VoiceOver: a fração muda por `passo`.
    let ajustar: (Double) -> Void

    var body: some View {
        let empilhado = ponta == .cima || ponta == .baixo
        let alinhamento: Alignment
        switch ponta {
        case .cima: alinhamento = .top
        case .baixo: alinhamento = .bottom
        case .esquerda: alinhamento = .leading
        case .direita: alinhamento = .trailing
        }
        // **A zona inteira se vê** (pedido do Pessoa Exemplo, 27/09: "não aparece uma marca onde apertar"): uma
        // faixa escura que esmaece a partir da linha, um fio na linha, e o pegador no meio da zona —
        // o desenho é a área de toque. Tudo do lado da prévia.
        let inicio: UnitPoint, fim: UnitPoint
        switch ponta {
        case .cima: (inicio, fim) = (.top, .bottom)
        case .baixo: (inicio, fim) = (.bottom, .top)
        case .esquerda: (inicio, fim) = (.leading, .trailing)
        case .direita: (inicio, fim) = (.trailing, .leading)
        }
        return ZStack(alignment: alinhamento) {
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0)],
                           startPoint: inicio, endPoint: fim)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: empilhado ? nil : 1, height: empilhado ? 1 : nil)
            // O pegador, no meio da zona.
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: empilhado ? 64 : 6, height: empilhado ? 6 : 64)
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel(tr("Borda entre o texto e a prévia. Arraste para dividir."))
        .accessibilityValue(tr("texto com %.0f %% da tela", fracao * 100))
        .accessibilityAdjustableAction { direcao in ajustar(direcao == .increment ? 0.05 : -0.05) }
    }
}

/// A altura da faixa dos controles, medida, para a divisão.
private struct AlturaDaFaixaDaTelaComCamera: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Dentro da faixa, com teto (30/09): a altura da lista dos avisos aberta, e a do estado com a barra.
private struct AlturaDaListaDosAvisos: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AlturaDoRestoDaFaixa: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// **A faixa dos controles da tela com câmera**: avisos, estado das duas sessões e a barra, numa
/// faixa própria — nunca por cima da prévia nem do texto.
///
/// O desenho anterior (a prévia "nunca menor que os controles", com eles morando nela) passou na
/// conta e falhou no aparelho: no iPhone X em retrato, o aviso vermelho, as duas linhas de estado
/// e a barra cobriam a prévia quase inteira (prova de 24/09). Agora:
///
/// - **os avisos ocupam uma linha**, a do mais grave, com "+N" quando há mais; um toque abre todos
///   (e o "Esquecer aparelhos pareados", quando é o caso), e eles se recolhem sozinhos em 10 s;
/// - **o estado das duas sessões ocupa uma linha**: um chip por sessão, com a cor, o PIN e o estado
///   em letra pequena; o toque abre o endereço e o PIN daquela sessão em letra grande (era o QR
///   dela até 24/09/2026, quando o QR saiu por decisão do Pessoa Exemplo);
/// - a barra, como antes.
private struct FaixaDaTelaComCamera<Barra: View>: View {
    @ObservedObject var modelo: ModeloDoTeleprompter
    @ObservedObject var ajustes: AjustesLocais
    @ObservedObject var camera: EmissorDeCamera
    @ObservedObject var dono: DonoDaCaptura
    @ObservedObject var gravador: GravadorLocal
    @ObservedObject var orientacao: EscolhaDeOrientacao
    /// A interface está numa orientação diferente da do toque em Gravar (só acontece quando o
    /// sistema recusou a trava): a imagem gravada está de lado em relação ao que a prévia mostra.
    let giradaGravando: Bool
    @ObservedObject var calor: CalorDoAparelho
    /// A captura em 720p pelo degrau 3 com uma gravação de pé.
    var gravandoReduzida = false
    let tocarGravar: () -> Void
    let telaCheia: Bool
    let abrirEndereco: () -> Void
    let abrirEnderecoDaCamera: () -> Void
    /// **O teto da faixa** (30/09): a altura da banda, com a faixa ao lado da prévia (o iPhone
    /// deitado, `DivisaoDaTelaComCamera.tetoDaFaixa`). Com ele, a lista dos avisos aberta rola dentro
    /// do que sobra da banda depois do estado e da barra, em vez de crescer para cima do texto. `nil`:
    /// sem teto, como até 30/09.
    var alturaMaxima: CGFloat?
    let barra: Barra

    @State private var avisosAbertos = false
    /// A vez do recolher automático: um toque novo adia o recolher do toque anterior.
    @State private var vezDoRecolher = 0
    /// As alturas medidas da lista aberta e do estado com a barra, para o teto da lista.
    @State private var alturaDaLista: CGFloat = 0
    @State private var alturaDoResto: CGFloat = 0

    struct Aviso: Identifiable {
        let texto: String
        let cor: Color
        let simbolo: String
        var id: String { simbolo + "|" + texto }
    }

    /// Do mais grave para o menos: o vermelho primeiro, porque é ele que fica na linha recolhida.
    private var avisos: [Aviso] {
        var v: [Aviso] = []
        // O calor (§8.12.1): no `.critical`, o aviso vermelho fica na faixa enquanto durar — primeiro
        // da lista, porque é o que fica na linha recolhida; nunca entre o texto e a lente.
        if let a = calor.aviso { v.append(Aviso(texto: a, cor: Estilo.noArCheio, simbolo: "thermometer")) }
        // Na tela cheia a linha de estado some: o "gravando" vira aviso, para nunca ficar escondido.
        if telaCheia, gravador.estado.ocupada {
            v.append(Aviso(texto: gravador.estado.gravando ? tr("Gravando") : tr("Gravação começando ou fechando"),
                           cor: Estilo.noArCheio, simbolo: "record.circle"))
        }
        // Gravar não liga o microfone (decisão do Pessoa Exemplo, 24/09 à noite): gravando sem ele, o aviso diz
        // por extenso, e ligar no meio grava som dali em diante.
        if gravador.estado.gravando, !dono.microfone.ligado {
            v.append(Aviso(texto: GravadorLocal.textoSemSom, cor: .orange, simbolo: "mic.slash"))
        }
        // A gravação que começou quente diz o tamanho enquanto grava (§8.12.1).
        if gravandoReduzida {
            v.append(Aviso(texto: tr("Gravando em 720p: a transmissão tem prioridade com o aparelho quente."),
                           cor: .orange, simbolo: "thermometer"))
        }
        // Quente e transmitindo: o som da rede pode atrasar até ~1 s (§8.12.14, a troca atraso × picote).
        if calor.quente, camera.fase == .transmitindo {
            v.append(Aviso(texto: tr("Aparelho quente: o som da transmissão pode atrasar."), cor: .orange,
                           simbolo: "thermometer"))
        }
        if gravador.estado.ocupada, let r = gravador.reduzidaPeloCalor {
            v.append(Aviso(texto: r, cor: .orange, simbolo: "thermometer"))
        }
        // A trava não pegou gravando e a pessoa girou (a interface diverge da orientação do toque em
        // Gravar: é a prova de que a trava falhou, com recusa dita pelo sistema ou calada): a prévia
        // segue a interface, e o arquivo fica no ângulo do começo (§8.12.2, revisões M6 e M5 do código).
        if gravador.estado.ocupada, giradaGravando {
            v.append(Aviso(texto: EscolhaDeOrientacao.textoSemTrava, cor: .orange, simbolo: "rotate.right"))
        }
        if let r = gravador.recado { v.append(Aviso(texto: r.texto, cor: r.grave ? .orange : .green, simbolo: "film")) }
        if let a = modelo.avisoDeSemPar { v.append(Aviso(texto: a, cor: Estilo.noArCheio, simbolo: "wifi.exclamationmark")) }
        if !camera.conselho.isEmpty { v.append(Aviso(texto: camera.conselho, cor: Estilo.noArCheio, simbolo: "video.badge.exclamationmark")) }
        if case let .falhou(motivo) = camera.fase { v.append(Aviso(texto: motivo, cor: Estilo.noArCheio, simbolo: "video.slash")) }
        if !dono.interrupcao.isEmpty { v.append(Aviso(texto: dono.interrupcao, cor: .orange, simbolo: "pause.circle")) }
        if let a = dono.microfone.aviso { v.append(Aviso(texto: a.texto, cor: .orange, simbolo: "mic.slash.fill")) }
        if let a = modelo.avisoDeConfirmacao { v.append(Aviso(texto: a, cor: .orange, simbolo: "clock.badge.exclamationmark")) }
        if let a = modelo.avisoDoProtocolo { v.append(Aviso(texto: a, cor: .orange, simbolo: "exclamationmark.triangle")) }
        if let a = ajustes.aviso { v.append(Aviso(texto: a, cor: .orange, simbolo: "textformat.size")) }
        if !modelo.aviso.isEmpty { v.append(Aviso(texto: modelo.aviso, cor: .gray, simbolo: "info.circle")) }
        return v
    }

    var body: some View {
        let lista = avisos
        VStack(spacing: 6) {
            if !lista.isEmpty { linhaDosAvisos(lista) }
            if !telaCheia {
                // Numa pilha própria (o mesmo espaçamento de 6) só para medir: é o que a lista aberta
                // não pode tomar, com teto.
                VStack(spacing: 6) {
                    estadoEmUmaLinha
                    barra
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: AlturaDoRestoDaFaixa.self, value: g.size.height)
                })
            }
        }
        .padding(.vertical, lista.isEmpty && telaCheia ? 0 : 6)
        .onPreferenceChange(AlturaDoRestoDaFaixa.self) { h in if abs(h - alturaDoResto) > 0.5 { alturaDoResto = h } }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .onChange(of: lista.isEmpty) { vazia in if vazia { avisosAbertos = false } }
    }

    // --- os avisos ----------------------------------------------------------------------------

    /// A altura que a lista aberta pode ter, com teto: o teto menos o estado com a barra, os
    /// espaçamentos e as margens. Nunca menos que uma linha.
    private var tetoDaLista: CGFloat? {
        guard let alturaMaxima else { return nil }
        let resto = telaCheia ? 0 : alturaDoResto + 6
        return max(36, alturaMaxima - 12 - resto)
    }

    @ViewBuilder private func linhaDosAvisos(_ lista: [Aviso]) -> some View {
        let primeiro = lista[0]
        Group {
            if avisosAbertos {
                if let teto = tetoDaLista {
                    // Com teto (o iPhone deitado), a lista rola. A altura é a da lista até o teto; até a
                    // primeira medida, o teto.
                    ScrollView(.vertical) {
                        listaAberta(lista)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: AlturaDaListaDosAvisos.self, value: g.size.height)
                            })
                    }
                    .frame(height: min(alturaDaLista > 0 ? alturaDaLista : teto, teto))
                    .onPreferenceChange(AlturaDaListaDosAvisos.self) { h in
                        if abs(h - alturaDaLista) > 0.5 { alturaDaLista = h }
                    }
                } else {
                    listaAberta(lista)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: primeiro.simbolo)
                    Text(primeiro.texto).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if lista.count > 1 { Text(verbatim: "+\(lista.count - 1)").monospacedDigit() }
                    Image(systemName: "chevron.down")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(primeiro.cor.opacity(0.85))
                .cornerRadius(8)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { alternarAvisos() }
        .accessibilityElement(children: .combine)
        .accessibilityHint(avisosAbertos ? tr("Toque para recolher os avisos") : tr("Toque para ler os avisos inteiros"))
    }

    private func listaAberta(_ lista: [Aviso]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lista) { a in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: a.simbolo)
                    Text(a.texto).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(a.cor.opacity(0.85))
                .cornerRadius(8)
            }
            if camera.ofereceDesparear {
                Button(tr("Esquecer aparelhos pareados")) { camera.esquecerPares() }
                    .font(.footnote.weight(.semibold))
            }
            if dono.microfone.aviso?.podeAbrirAjustes == true {
                Button(tr("Abrir os Ajustes (microfone)")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    private func alternarAvisos() {
        withAnimation(.easeInOut(duration: 0.15)) { avisosAbertos.toggle() }
        guard avisosAbertos else { return }
        vezDoRecolher += 1
        let vez = vezDoRecolher
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard vez == vezDoRecolher, avisosAbertos else { return }
            withAnimation(.easeInOut(duration: 0.15)) { avisosAbertos = false }
        }
    }

    // --- o estado, numa linha -----------------------------------------------------------------

    private var estadoEmUmaLinha: some View {
        HStack(spacing: 6) {
            chip(cor: corDoPrompter, titulo: tr("Texto"), pin: modelo.pin, estado: textoDoPrompter, abrir: abrirEndereco)
            chip(cor: corDaCamera, titulo: tr("Câmera"), pin: camera.pin, estado: textoDaCamera, abrir: abrirEnderecoDaCamera)
            // O microfone é da câmera: fica ao lado dela, fora da barra (que já está no limite de
            // largura do iPhone em retrato).
            BotaoDoMicrofone(dono: dono, compacto: true)
            BotaoDeGravar(gravador: gravador, dono: dono, tocar: tocarGravar)
        }
        .padding(.horizontal, 8)
    }

    private func chip(cor: Color, titulo: String, pin: String, estado: String,
                      abrir: @escaping () -> Void) -> some View {
        Button(action: abrir) {
            HStack(spacing: 6) {
                Circle().fill(cor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(titulo).font(.caption.weight(.semibold))
                        Text(pin.count == 6 ? espacado(pin) : "—")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                    }
                    Text(estado).font(.caption2).foregroundColor(Color(white: 0.75))
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "textformat.size").font(.footnote)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Estilo.superficieAlta)
            .cornerRadius(9)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("%@: %@. PIN %@", titulo, estado, pin))
        .accessibilityHint(tr("Mostra o endereço e o PIN em letra grande"))
    }

    private func espacado(_ p: String) -> String { Estilo.pinEspacado(p) }

    private var corDoPrompter: Color {
        switch modelo.fase {
        case .conectada: return modelo.avisoDeSemPar == nil ? Estilo.conectado : Estilo.noAr
        case .semPar: return Estilo.noAr
        case .falhou: return Estilo.aguardando
        default: return Estilo.aguardando
        }
    }

    private var textoDoPrompter: String {
        switch modelo.fase {
        case .parada: return tr("parado")
        case .esperando, .conectando: return tr("esperando o controle")
        case let .conectada(par): return par.isEmpty ? tr("controle conectado") : tr("controlado por %@", par)
        case .semPar: return tr("controle desconectado")
        case let .falhou(motivo): return motivo
        }
    }

    private var corDaCamera: Color {
        switch camera.fase {
        case .transmitindo: return dono.interrupcao.isEmpty ? Estilo.conectado : Estilo.aguardando
        case .semPermissao, .falhou: return Estilo.noAr
        default: return Estilo.aguardando
        }
    }

    private var textoDaCamera: String {
        switch camera.fase {
        case .parada: return tr("abrindo")
        case .pedindoPermissao: return tr("pedindo acesso à rede local…")
        case .semPermissao: return tr("sem acesso")
        case .esperando: return camera.reabrindo ? tr("quem recebia saiu; reabrindo…") : tr("esperando quem recebe")
        case .transmitindo: return camera.par.isEmpty ? tr("enviando") : tr("enviando para %@", camera.par)
        case .encerrando: return tr("saindo…")
        case .falhou: return tr("parou")
        }
    }
}

/// O endereço e o PIN da câmera em letra grande, para quem vai receber digitar. Era a folha do QR
/// da câmera até 24/09/2026, quando o QR saiu por decisão do Pessoa Exemplo.
private struct FolhaDoEnderecoDaCamera: View {
    @ObservedObject var camera: EmissorDeCamera
    let fechar: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(tr("Receber a câmera deste aparelho")).font(.title3.weight(.semibold))
            VStack(spacing: 6) {
                Text(tr("No outro aparelho, abra o Quall → Exibir, e digite:"))
                    .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(camera.enderecoParaDigitar ?? tr("sem rede"))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .foregroundColor(camera.enderecoParaDigitar == nil ? Estilo.aguardandoTexto : Estilo.texto)
                    .lineLimit(1).minimumScaleFactor(0.4)
                Text(verbatim: "PIN \(camera.pin)")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .accessibilityLabel("PIN " + camera.pin.map { String($0) }.joined(separator: " ")) // sem-traducao
            }
            Button(tr("Fechar"), action: fechar).buttonStyle(.bordered)
        }
        .padding(24)
    }
}
