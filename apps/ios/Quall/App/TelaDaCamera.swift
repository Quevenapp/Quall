import SwiftUI
import AVFoundation
import Combine
import UIKit

/// As peças da tela da câmera comum, criadas **uma vez** por tela (o mesmo motivo de
/// `PecasDaTelaComCamera`): o emissor e o gravador nascem com o dono.
final class PecasDaTelaDaCamera: ObservableObject {
    let dono = DonoDaCaptura()
    let camera: EmissorDeCamera
    let gravador: GravadorLocal
    private var repasse: AnyCancellable?

    init() {
        camera = EmissorDeCamera(dono: dono, textoDeRecomecar: EmissorDeCamera.recomecarNaTelaDaCamera)
        gravador = GravadorLocal(dono: dono)
        // A tela lê o estado do emissor (a fase, o PIN, o par): a mudança dele a redesenha.
        repasse = camera.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// A tela da câmera: a mesma tela de espera do espelhamento, com a pré-visualização atrás.
///
/// O PIN, o endereço e o Parar estão aqui pelo mesmo motivo que estão na tela de espera da tela:
/// quem exibe escolhe e conecta, e quem emite anuncia e espera. **O endereço é o mesmo** — a
/// porta de sinalização não muda com a origem, porque o receptor vê este aparelho uma vez só.
///
/// A câmera vem escolhida de fora, do seletor da tela inicial, e é fixa daqui em diante: não há
/// botão de trocar, porque não há renegociação no protocolo para acompanhar a troca. Quem quer
/// outra câmera para, volta e escolhe.
///
/// ## A câmera é da tela, e grava sem receptor (24/09 à noite, decisão do Pessoa Exemplo)
///
/// A câmera **abre com a tela** e fecha com ela (`DonoDaCaptura`, dono da tela, como na
/// "Teleprompter com câmera"): a prévia existe na espera, a transmissão **se pendura** no dono
/// quando um receptor pareia e **se solta** quando ele cai, e a espera volta com o mesmo PIN
/// (`EmissorDeCamera` no modo pendurado). Até aqui a câmera nascia e morria com a sessão.
///
/// **Gravar** (`GravadorLocal`, o mesmo da tela R5) funciona sem receptor nenhum, na frontal e na
/// traseira: a captura é a do cardápio (não a melhor imagem da R5, para o espelhamento não mudar), o
/// arquivo vai ao rolo da câmera ao parar, e o que ficar (o processo morto gravando) vai na abertura
/// seguinte. Gravando, a orientação da interface trava onde estava e o ângulo da conexão congela
/// (um arquivo, um tamanho). **Gravar não liga o microfone**: a pessoa liga antes, e sem ele a tela
/// diz "Gravando SEM SOM — ligue o microfone" (ligar no meio grava som dali em diante).
/// `docs/teleprompter-com-camera.md` §8.8.
///
/// ## Nenhum estado desta tela é uma tela em branco
///
/// Cada fase tem texto, e as que a pessoa pode consertar têm botão. Isso não é capricho: no macOS
/// a permissão de câmera negada travou uma frente inteira porque não havia interface para pedir
/// nem para explicar. Aqui há as duas coisas — e o caso de **restrição** (Tempo de Uso, perfil de
/// gerenciamento) não oferece o botão de Ajustes, porque lá o botão está desligado e a pessoa não
/// pode ligá-lo.
struct TelaDaCamera: View {
    let origem: Origem

    @Environment(\.presentationMode) private var apresentacao
    @Environment(\.scenePhase) private var etapa
    @StateObject private var pecas = PecasDaTelaDaCamera()
    private var camera: EmissorDeCamera { pecas.camera }

    /// O que impede a câmera de abrir (a permissão, a captura que não montou), para a tela dizer.
    @State private var problema: ProblemaDaCamera?
    @State private var comecou = false
    /// A tela saiu: um pedido de permissão que volte depois não abre câmera nenhuma.
    @State private var saiu = SaidaDaTela()

    struct ProblemaDaCamera: Equatable {
        let texto: String
        let podeAbrirAjustes: Bool
    }

    /// Referência, e não valor: o fecho do pedido de permissão lê isto depois que a tela saiu.
    final class SaidaDaTela { var saiu = false }

    /// O tamanho da área desenhada, e é ele que dispara o acompanhamento da orientação.
    ///
    /// **A notificação do aparelho não serve sozinha, e o motivo é uma corrida.**
    /// `UIDevice.orientationDidChangeNotification` é emitida quando o **aparelho** gira; a
    /// `interfaceOrientation` da cena — que é o que `acompanharOrientacao` lê, deliberadamente —
    /// só é atualizada depois, quando o sistema termina de girar a interface. Ler no instante da
    /// notificação devolve o valor **anterior**, e o efeito é uma correção que nunca chega: em
    /// 07/09/2026 o iPad seguiu espelhando em pé mesmo com a notificação já ligada.
    ///
    /// A geometria não tem essa corrida: quando ela muda, a interface **já** girou. Por isso o
    /// gatilho é o tamanho, e não o giroscópio.
    @State private var tamanho: CGSize = .zero
    /// Deitado (o celular em paisagem), os três controles vão para uma coluna na borda direita (§11.1).
    @Environment(\.verticalSizeClass) private var classeVertical
    /// **O painel "Ajustes da câmera"** (R9, `docs/controles-de-camera.md` §4.2): uma vista própria por
    /// cima desta tela, sem véu — em pé na metade de baixo, deitado na metade direita. A prévia fica na
    /// outra metade, e um toque nela continua sendo um toque na prévia.
    @State private var painelDaCamera = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreVisualizacao(dono: pecas.dono).ignoresSafeArea()

            // Véu sobre a imagem: o texto branco por cima de uma cena clara some, e esta tela
            // existe para ser lida de longe. Desde 30/09 (§6.5) são dois degradês, no alto (0,72 → 0)
            // e no pé (0 → 0,82); o meio fica limpo, e o que vai no meio vai num cartão de vidro.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
                Spacer(minLength: 0)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 320)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            conteudo
                .padding(.horizontal, Estilo.margem)
                .padding(.vertical, 12)
                .foregroundColor(Estilo.texto)
                .dynamicTypeSize(...Estilo.tetoDaLetra)

            if painelDaCamera {
                painelDosAjustes
            }
        }
        .onAppear {
            // **A notificação de orientação não existe até alguém pedir.**
            // `UIDevice.orientationDidChangeNotification` só é emitida enquanto houver um
            // `beginGeneratingDeviceOrientationNotifications` de pé — sem isso o `.onReceive`
            // logo abaixo fica ligado a um sinal que nunca dispara, e `acompanharOrientacao` só
            // roda aqui, no `.onAppear`. Foi assim até 07/09/2026: a orientação congelava na que
            // valia quando a tela apareceu, e girar o aparelho depois não mudava nada. O usuário
            // achou pelo sintoma que o comentário abaixo já previa — o iPad espelhando em pé,
            // deitado, sem nada reclamar em lugar nenhum.
            //
            // Quem responde continua sendo a **cena**, e não o aparelho: ver `acompanharOrientacao`.
            // Isto aqui é só o gatilho.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            // **A tela acesa enquanto esta tela estiver aberta** (revisão de 24/09 à noite, B1): o
            // caso novo é gravar sem receptor e sem tocar na tela, e o bloqueio automático levaria o
            // app ao segundo plano — que para a gravação e a câmera. Com dono, como na R5.
            TelaAcesa.pedir(TelaDaCamera.donoDaTelaAcesa)
            acompanharOrientacao()
            abrirACamera()
        }
        .onDisappear(perform: sair)
        .onChange(of: etapa) { nova in
            // §5.3: no iOS a câmera para fora da tela; o arquivo fecha e vai ao rolo com o tempo de
            // segundo plano que o gravador pede.
            if nova == .background { pecas.gravador.parar(motivo: "o app saiu da tela") }
            if nova == .active { TelaAcesa.reafirmar() }
        }
        // A rotação da câmera é resolvida **na conexão de captura**: o ISP entrega o quadro já
        // girado, sem custo nosso, e a troca de dimensão faz o encoder ser reconstruído no
        // formato certo. É de graça, e é o que a tela não consegue fazer — lá o ReplayKit decide.
        //
        // Sem isto, o aparelho deitado continuaria mandando um quadro em pé com a cena de lado, e
        // nada em lugar nenhum reclamaria.
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in acompanharOrientacao() }
        // O gatilho que **não** tem corrida: ver `tamanho`. O `GeometryReader` num
        // `background` mede a área desenhada sem participar do leiaute, e a mudança de tamanho é
        // a testemunha de que a interface terminou de girar.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { tamanho = g.size }
                .onChange(of: g.size) { novo in
                    guard novo != tamanho else { return }
                    tamanho = novo
                    acompanharOrientacao()
                }
        })
    }

    /// **A câmera no ar** (§6.5, com a §11.1): no alto, a pílula (ABRINDO, AGUARDANDO, NO AR, SEM
    /// CÂMERA) e o nome da câmera — sem a resolução da §6.5: o dono da captura não publica o formato
    /// montado, e o cardápio mentiria quando a montagem desce (4K pedido numa câmera que só dá 1080p,
    /// ou o calor); embaixo dele,
    /// esperando, o miolo da Espera num cartão de vidro (preto a 85 %); enviando, "Enviando para" e o
    /// par. No pé, a frase de ficar na tela, os avisos (dois à vista, o resto em "+N"; um só com o
    /// vidro da espera na tela, ou deitado) e os três controles redondos. Deitado, os controles vão
    /// para uma coluna na borda direita.
    ///
    /// Na escala padrão a conta fecha e nada rola. No iPhone 7, esperando sem pares. Em pé (647 pt): 12 + pílula 28 + 12 + vidro 273 (instrução em três
    /// linhas, letreiro de 40 × 54, chip) + 12 (espaço mínimo) + frase 36 + 12 + controles 100 + 12 ≈
    /// 497; com um aviso e o "+N" (12 + 60 + 10 + 28), ≈ 607. No ar, sem o vidro (~55 no lugar de 273),
    /// dois avisos e o "+N" cabem com folga (≈ 459). Deitado (375 pt): 12 + pílula 28 + 12 + vidro em
    /// duas partes 194 (letreiro de 32 × 44) + 8 + frase 18 + 10 + um aviso 60 + "+N" 38 + 12 ≈ 372 à
    /// esquerda; controles em coluna 284 à direita.
    ///
    /// **Os controles ficam fora da rolagem**, presos na borda (`safeAreaInset`): o Parar é a única
    /// saída desta tela, e com letra grande ou o "+N" aberto o resto passaria da altura — aí o alto, o
    /// vidro e os avisos rolam por cima da prévia, e os três botões continuam onde estavam.
    @ViewBuilder
    private var conteudo: some View {
        if classeVertical == .compact {
            TelaQueCabe {
                VStack(alignment: .leading, spacing: 0) {
                    alto(deitado: true)
                    Spacer(minLength: 8)
                    fraseDeFicar
                        .frame(maxWidth: .infinity, alignment: .leading)
                    avisos(maximo: 1)
                        .padding(.top, 10)
                }
                .background(zonaDeToque)
            }
            .safeAreaInset(edge: .trailing, spacing: 16) {
                controles(emColuna: true)
                    .frame(maxHeight: .infinity)
            }
        } else {
            // No iPad a coluna fica em até 520 pt, centrada: o vidro e os controles de um lado a
            // outro de uma tela de 1024 ficariam longe do olho e do dedo.
            TelaQueCabe {
                VStack(spacing: 0) {
                    alto(deitado: false)
                    Spacer(minLength: 12)
                    fraseDeFicar
                    avisos(maximo: comVidroDaEspera ? 1 : 2)
                        .padding(.top, 12)
                }
                .padding(.bottom, 12)
                .background(zonaDeToque)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controles(emColuna: false)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// **O toque na prévia** (R9, §4.4), no fundo do conteúdo que rola: o `ScrollView` da
    /// `TelaQueCabe` fica por cima da prévia e pega todo toque, então a zona mora dentro dele, atrás
    /// dos cartões e dos botões (que continuam recebendo o toque deles).
    @ViewBuilder
    private var zonaDeToque: some View {
        if origem.ehCamera, problema == nil {
            ZonaDeToqueDaPrevia(dono: pecas.dono, controles: pecas.dono.controles)
        }
    }

    /// O painel por cima (§4.2): em pé, a metade de baixo (no mínimo a altura que ele precisa para não
    /// rolar); deitado, a metade direita. O fundo é opaco e não há véu do lado da prévia.
    private var painelDosAjustes: some View {
        GeometryReader { g in
            let painel = PainelDosAjustesDaCamera(controles: pecas.dono.controles) { painelDaCamera = false }
            if classeVertical == .compact {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    painel.frame(width: g.size.width / 2)
                }
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    painel.frame(height: min(g.size.height, max(g.size.height / 2, PainelDosAjustesDaCamera.alturaMinima)))
                }
            }
        }
    }

    private func avisos(maximo: Int) -> some View {
        AvisosDaTelaDaCamera(dono: pecas.dono, gravador: pecas.gravador,
                             interrupcao: camera.interrupcao, conselho: camera.conselho,
                             ofereceDesparear: camera.ofereceDesparear,
                             aoDesparear: { camera.esquecerPares() },
                             abrirAjustes: abrirAjustes, maximo: maximo)
    }

    private func controles(emColuna: Bool) -> some View {
        ControlesDaTelaDaCamera(dono: pecas.dono, gravador: pecas.gravador,
                                transmitindo: camera.fase == .transmitindo,
                                emColuna: emColuna, fechar: fechar)
    }

    /// A câmera para quando o app sai do primeiro plano, e isso precisa estar escrito **antes** de
    /// acontecer: quem descobre no meio de uma apresentação conclui que quebrou. A frase longa de
    /// antes (o iPhone desliga a câmera de quem sai; a gravação vai ao rolo) virou a curta de §6.5.
    private var fraseDeFicar: some View {
        Text(tr("Deixe o Quall aberto nesta tela enquanto estiver no ar."))
            .font(Estilo.corpo(.footnote))
            .foregroundColor(Estilo.texto2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alto(deitado: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                pilula
                Spacer(minLength: 0)
                // Qual câmera está no ar, dito por extenso: com três lentes traseiras, a imagem
                // sozinha não responde, e é este nome que o receptor também vê no rótulo da track.
                Text(origem.nomeNaTela)
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(Estilo.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // R9 (§4.1): os ajustes da câmera, no alto, ao lado do nome dela.
                if origem.ehCamera {
                    BotaoDosAjustesDaCamera(controles: pecas.dono.controles, aberto: painelDaCamera) {
                        painelDaCamera.toggle()
                    }
                }
                MenuDaTelaAcesa()
            }
            miolo(deitado: deitado)
        }
    }

    @ViewBuilder
    private func miolo(deitado: Bool) -> some View {
        if let p = problema {
            vidro { semCamera(tr("Sem a câmera"), p.texto, ajustes: p.podeAbrirAjustes) }
        } else {
            switch camera.fase {
            case .semPermissao(let motivo, let podeAbrirAjustes):
                vidro { semCamera(tr("Sem acesso à câmera"), motivo, ajustes: podeAbrirAjustes) }
            case .falhou(let motivo):
                vidro { semCamera(tr("Não deu"), motivo, ajustes: false) }
            case .transmitindo:
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Enviando para"))
                        .font(Estilo.corpo(.subheadline))
                        .foregroundColor(Estilo.texto2)
                    Text(camera.par.isEmpty ? tr("outro aparelho") : camera.par)
                        .font(Estilo.titulo(.title))
                        .foregroundColor(Estilo.texto)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
            case .pedindoPermissao:
                vidro {
                    Text(tr("Pedindo acesso à câmera…"))
                        .font(Estilo.corpo(.callout))
                        .foregroundColor(Estilo.texto)
                        .frame(maxWidth: .infinity)
                }
            case .encerrando, .parada:
                // `.parada` é o instante antes de o emissor começar: a câmera ainda abrindo. A pílula
                // (ABRINDO / ENCERRANDO, girando) já diz; o meio fica limpo para a prévia.
                EmptyView()
            default:
                // A manchete muda com o que este aparelho já sabe — mesmo motivo e mesma forma da
                // tela de espera do espelhamento (`BlocoDaEspera`). O endereço é o mesmo: a porta
                // de sinalização não muda com a origem.
                vidro {
                    if deitado {
                        HStack(alignment: .center, spacing: 16) {
                            blocoDaEspera(.instrucao, casa: CGSize(width: 32, height: 44))
                            blocoDaEspera(.codigos, casa: CGSize(width: 32, height: 44))
                        }
                    } else {
                        blocoDaEspera(.tudo, casa: CGSize(width: 40, height: 54))
                    }
                }
            }
        }
    }

    private func blocoDaEspera(_ parte: BlocoDaEspera.Parte, casa: CGSize) -> some View {
        BlocoDaEspera(nome: Identidade.nome, pin: camera.pin, endereco: camera.enderecoParaDigitar,
                      notaDoEnlace: camera.notaDoEnlace, temPares: camera.haParesConhecidos,
                      casa: casa, parte: parte)
            .frame(maxWidth: .infinity)
    }

    /// O cartão de vidro sobre a imagem: preto a 85 %, cantos 22 (§6.5, §11.1).
    private func vidro<C: View>(@ViewBuilder _ conteudo: () -> C) -> some View {
        conteudo()
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Estilo.vidro))
    }

    /// Nenhum estado desta tela é uma tela em branco: o que impede a câmera, com o texto de hoje, e
    /// "Abrir os Ajustes" quando os Ajustes resolvem (na restrição, não resolvem).
    private func semCamera(_ titulo: String, _ texto: String, ajustes: Bool) -> some View {
        VStack(spacing: 8) {
            Text(titulo)
                .font(Estilo.corpo(.body, .semibold))
                .foregroundColor(Estilo.texto)
            Text(texto)
                .font(Estilo.corpo(.subheadline))
                .foregroundColor(Estilo.texto2)
                .fixedSize(horizontal: false, vertical: true)
            if ajustes {
                Button(tr("Abrir os Ajustes"), action: abrirAjustes)
                    .buttonStyle(.secundarioPequeno)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// A luz de estúdio desta tela. SEM CÂMERA em vermelho para o que impede a câmera (§11.1); a
    /// interrupção no ar (o app saiu, outra câmera tomou) é âmbar, como era a bolinha.
    private var pilula: PilulaDeEstado {
        if problema != nil { return PilulaDeEstado(tom: .noAr, palavra: tr("Sem câmera")) }
        switch camera.fase {
        case .semPermissao, .falhou:
            return PilulaDeEstado(tom: .noAr, palavra: tr("Sem câmera"))
        case .transmitindo:
            return camera.interrupcao.isEmpty
                ? PilulaDeEstado(tom: .noAr, palavra: tr("No ar"))
                : PilulaDeEstado(tom: .aguardando, palavra: tr("Câmera parada"))
        case .pedindoPermissao, .parada:
            return PilulaDeEstado(tom: .aguardando, palavra: tr("Abrindo"), girando: true)
        case .encerrando:
            return PilulaDeEstado(tom: .aguardando, palavra: tr("Encerrando"), girando: true)
        default:
            return PilulaDeEstado(tom: .aguardando, palavra: tr("Aguardando"))
        }
    }

    /// O vidro da espera (instrução, letreiro, chip) está na tela: é o estado mais alto, e com ele só
    /// um aviso fica à vista (a conta de altura em `conteudo`).
    private var comVidroDaEspera: Bool {
        problema == nil && camera.fase == .esperando
    }

    /// O botão de parar fecha a tela inteira (e, gravando, salva: o arquivo vai ao rolo).
    private func fechar() {
        apresentacao.wrappedValue.dismiss()
    }

    // --- o ciclo ---------------------------------------------------------------------------------

    /// A câmera abre **com a tela** (a prévia na espera), e a transmissão começa pendurada nela: a
    /// ordem é a da tela R5 — a permissão de câmera **pedida**, a captura montada e ligada, o
    /// emissor (rede local, PIN, anúncio, laço) por último.
    private func abrirACamera() {
        guard !comecou else { return }
        comecou = true
        guard origem.ehCamera else {
            problema = ProblemaDaCamera(texto: tr("Esta tela é das câmeras. A tela do iPhone vai pela "
                                        + "transmissão do sistema."), podeAbrirAjustes: false)
            return
        }
        let s = saiu
        let dono = pecas.dono
        let camera = pecas.camera
        let gravador = pecas.gravador
        // Gravando, a interface fica onde estava (um arquivo, um tamanho): §5.2.
        gravador.aoTravar = { sim in TelaDaCamera.prenderPelaGravacao(sim) }
        Diagnostico.nota("APP CAMERA tela da câmera: aberta"
            + " (a câmera abre com a tela; a transmissão se pendura nela)")
        // O que ficou de uma vez anterior (o processo morto gravando) vai ao rolo agora.
        GravacoesPendentes.recuperar(por: "a tela da câmera abriu")
        DonoDaCaptura.pedirPermissao { resposta in
            guard !s.saiu else { return }
            switch resposta {
            case let .recusada(motivo, podeAbrirAjustes):
                // O mesmo texto de antes: o `provar.sh` o procura.
                Diagnostico.nota("APP CAMERA sem permissão de câmera ajustes=\(podeAbrirAjustes)")
                problema = ProblemaDaCamera(texto: motivo, podeAbrirAjustes: podeAbrirAjustes)
            case .concedida:
                // O cardápio, e não a melhor imagem da R5: o espelhamento comum não muda de formato.
                if let erro = dono.montar(origem) {
                    Diagnostico.falha("APP CAMERA a captura não montou: \(SanitizacaoDoLog.causaExterna(erro))")
                    problema = ProblemaDaCamera(texto: erro, podeAbrirAjustes: false)
                    return
                }
                dono.ligar()
                acompanharOrientacao()
                camera.comecarPendurado()
                BancadaDaGravacao.ligar(gravador) { !s.saiu }
            }
        }
    }

    /// O nome com que esta tela pede a tela acesa.
    static let donoDaTelaAcesa = "camera-comum"

    private func sair() {
        saiu.saiu = true
        TelaAcesa.soltar(TelaDaCamera.donoDaTelaAcesa)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        // A gravação para antes de tudo: o arquivo fecha e vai ao rolo mesmo com a tela fechada (o
        // gravador se segura até lá). A transmissão depois (ela se solta do dono e o laço desmonta a
        // sessão), a câmera por último.
        pecas.gravador.parar(motivo: "a tela da câmera fechou")
        TelaDaCamera.prenderPelaGravacao(false)
        // O gravador vive até o arquivo ir ao rolo, e o `aoTravar(false)` dele chegaria depois — a
        // tempo de soltar a trava de **outra** tela que tenha prendido nesse meio (revisão, menor 5).
        pecas.gravador.aoTravar = nil
        pecas.camera.parar()
        pecas.dono.fechar()
        Diagnostico.nota("APP CAMERA tela da câmera: fechada")
    }

    /// **A trava da orientação gravando**, sem o `EscolhaDeOrientacao` do prompter (esta tela não
    /// tem escolha de orientação): a máscara do app vira só a orientação da interface de agora, e
    /// volta ao `Info.plist` quando a gravação termina de fechar (ou a tela sai). No iPad em modo de
    /// janelas o sistema pode recusar: o ângulo da conexão está congelado do mesmo jeito
    /// (`DonoDaCaptura.congelarAngulo`), e o arquivo não muda de tamanho — só a interface gira.
    static func prenderPelaGravacao(_ sim: Bool) {
        if sim {
            let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let cena = cenas.first { $0.activationState == .foregroundActive } ?? cenas.first
            let o = cena?.interfaceOrientation ?? .portrait
            Orientacao.prender(EscolhaDeOrientacao.mascara(de: o), preferida: o) { porque in
                Diagnostico.nota("APP GRAVACAO orientação: o sistema não prendeu a interface — \(porque)")
            }
            Diagnostico.nota("APP GRAVACAO orientação: gravando, a interface presa em \(o.rawValue)"
                + " (\(Orientacao.descricao))")
        } else {
            guard Orientacao.mascara != Orientacao.padrao else { return }
            Orientacao.soltar { porque in
                Diagnostico.nota("APP GRAVACAO orientação: o sistema não soltou a interface — \(porque)")
            }
            Diagnostico.nota("APP GRAVACAO orientação: solta (\(Orientacao.descricao))")
        }
    }

    /// A orientação vem da **cena**, e não de `UIDevice.current.orientation`.
    ///
    /// O aparelho tem orientações que a interface não tem — `faceUp` e `faceDown` são as óbvias, e
    /// aparecem toda vez que alguém deita o iPhone na mesa. Traduzi-las para uma orientação de
    /// vídeo produziria um giro que ninguém pediu, no meio da transmissão, com IDR e engasgo
    /// junto. A cena só reporta o que está realmente desenhado.
    private func acompanharOrientacao() {
        let cena = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        // **Instrumento, e ele diz o que eu estava adivinhando.** Em 07/09/2026 o iPad seguiu
        // espelhando em pé por quatro consertos seguidos, e cada um deles foi proposto sem
        // ninguém saber o que a cena respondia. Isto custa uma linha por giro e responde de uma
        // vez: se `interface` for 1 num aparelho deitado, o problema é a janela e não a câmera.
        let janela = cena?.coordinateSpace.bounds ?? .zero
        Diagnostico.nota("APP CAMERA cena: interface=\(cena?.interfaceOrientation.rawValue ?? -1)"
            + " janela=\(Int(janela.width))x\(Int(janela.height))"
            + " tela=\(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))"
            + " aparelho=\(UIDevice.current.orientation.rawValue)")
        camera.acompanharOrientacao(cena?.interfaceOrientation ?? .portrait)
    }

    private func abrirAjustes() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// **Os três controles redondos** da tela da câmera comum (§6.5), com a legenda embaixo de cada um:
/// o microfone, o Gravar e o Parar. Numa linha em pé; numa coluna na borda direita, deitado.
///
/// Observa o dono da captura e o gravador — o que a tela de cima não observa (ela só repassa o
/// emissor): o estado do microfone e da gravação muda aqui sem esperar o emissor mudar.
///
/// - **Microfone** (56, branco a 16 %; ligado, `noAr` a 85 %; recusado ou falhou, âmbar): "Mic
///   desligado", "Mic ligado", "Ligando…", "Sem acesso", "Não abriu". As frases longas de antes
///   ficam na acessibilidade e no aviso. Só liga com a câmera montada (`BotaoDoMicrofone`).
/// - **Gravar** (78, anel branco de 4 e miolo `noAr`; gravando, o miolo vira quadrado): grava neste
///   aparelho, com ou sem receptor (`GravadorLocal`, §8.8). Gravando, a legenda é o tempo em mono, com
///   "· SEM SOM" sem o microfone — gravar não liga o microfone (decisão do Pessoa Exemplo, 24/09 à noite).
/// - **Parar** (56, vermelho a 24 %): fecha a tela. "Cancelar" esperando, "Parar" no ar, "Parar e
///   salvar" gravando — o arquivo vai ao rolo, e "Cancelar" diria o contrário (revisão, médio 4).
struct ControlesDaTelaDaCamera: View {
    @ObservedObject var dono: DonoDaCaptura
    @ObservedObject var gravador: GravadorLocal
    let transmitindo: Bool
    let emColuna: Bool
    let fechar: () -> Void

    var body: some View {
        if emColuna {
            VStack(spacing: 14) { microfone; gravar; parar }
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                microfone.frame(maxWidth: .infinity)
                gravar.frame(maxWidth: .infinity)
                parar.frame(maxWidth: .infinity)
            }
        }
    }

    // --- microfone -----------------------------------------------------------------------------------

    private var microfone: some View {
        controle(legenda: legendaDoMicrofone) {
            Button(action: { dono.alternarMicrofone() }) {
                Image(systemName: simboloDoMicrofone)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(fundoDoMicrofone))
                    .contentShape(Circle())
            }
            .buttonStyle(.toque)
            .disabled(!dono.montado)
            .opacity(dono.montado ? 1 : 0.4)
            // `.pedindo` também desliga no toque (`alternarMicrofone`).
            .accessibilityLabel(dono.microfone == .ligado || dono.microfone == .pedindo
                                ? tr("Desligar o microfone") : tr("Ligar o microfone"))
            .accessibilityValue(fraseDoMicrofone)
        }
    }

    private var simboloDoMicrofone: String {
        switch dono.microfone {
        case .ligado: return "mic.fill"
        case .pedindo: return "mic"
        case .recusado, .falhou: return "mic.slash.fill"
        case .desligado: return "mic.slash"
        }
    }

    /// Ligado é vermelho, como o "no ar" de uma filmadora: quem fala precisa ver que está sendo ouvido.
    private var fundoDoMicrofone: Color {
        switch dono.microfone {
        case .ligado: return Estilo.noAr.opacity(0.85)
        case .recusado, .falhou: return Estilo.aguardando.opacity(0.55)
        default: return Color.white.opacity(0.16)
        }
    }

    private var legendaDoMicrofone: String {
        switch dono.microfone {
        case .desligado: return tr("Mic desligado")
        case .pedindo: return tr("Ligando…")
        case .ligado: return tr("Mic ligado")
        case .recusado: return tr("Sem acesso")
        case .falhou: return tr("Não abriu")
        }
    }

    /// As frases de antes (`BotaoDoMicrofone`), para o leitor de tela.
    private var fraseDoMicrofone: String {
        switch dono.microfone {
        case .desligado: return dono.montado ? tr("Microfone desligado") : tr("Microfone (depois da câmera)")
        case .pedindo: return tr("Ligando o microfone…")
        case .ligado: return tr("Microfone ligado")
        case .recusado: return tr("Sem acesso ao microfone")
        case .falhou: return tr("O microfone não abriu")
        }
    }

    // --- gravar --------------------------------------------------------------------------------------

    private var gravar: some View {
        VStack(spacing: 6) {
            Button(action: tocarEmGravar) {
                ZStack {
                    Circle().strokeBorder(Color.white, lineWidth: 4)
                    RoundedRectangle(cornerRadius: gravador.estado.gravando ? 8 : 30, style: .continuous)
                        .fill(Estilo.noAr)
                        .frame(width: gravador.estado.gravando ? 30 : 60,
                               height: gravador.estado.gravando ? 30 : 60)
                    if gravador.estado == .abrindo || gravador.estado == .fechando {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 78, height: 78)
                .contentShape(Circle())
                .animation(.easeInOut(duration: 0.2), value: gravador.estado.gravando)
            }
            .buttonStyle(.toque)
            .disabled(!dono.montado || gravador.estado == .fechando)
            .opacity(dono.montado ? 1 : 0.4)
            .accessibilityLabel(gravador.estado.ocupada ? tr("Parar a gravação") : tr("Gravar neste aparelho"))
            .accessibilityValue(valorAcessivelDoGravar)

            legendaDoGravar
                .font(Estilo.corpo(.caption, .medium))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var legendaDoGravar: some View {
        switch gravador.estado {
        case .parada: Text(tr("Gravar"))
        case .abrindo: Text(tr("Começando…"))
        case .fechando: Text(tr("Salvando…"))
        case .gravando(let desde):
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(GravadorLocal.duracaoLegivel(ProcessInfo.processInfo.systemUptime - desde))
                    .font(Estilo.mono(.caption, .bold))
                    + Text(dono.microfone.ligado ? "" : tr(" · SEM SOM")).font(Estilo.corpo(.caption, .bold))
            }
        }
    }

    private func tocarEmGravar() {
        switch gravador.estado {
        case .parada: gravador.comecar(por: .toque) { _ in }
        case .gravando, .abrindo: gravador.parar(motivo: "o botão Parar")
        case .fechando: break
        }
    }

    private var espaco: String? {
        gravador.espacoLivre.map { String(format: "%.1f GB", Double($0) / 1_000_000_000) }
    }

    private var valorAcessivelDoGravar: String {
        switch gravador.estado {
        case .parada: return tr("Parado")
        case .abrindo: return tr("Começando")
        case .fechando: return tr("Fechando o arquivo")
        case .gravando(let desde):
            return tr("Gravando há %@", GravadorLocal.duracaoLegivel(ProcessInfo.processInfo.systemUptime - desde))
                + (dono.microfone.ligado ? "" : tr(", sem som: ligue o microfone"))
                + (espaco.map { tr(", %@ livres", $0) } ?? "")
        }
    }

    // --- parar ---------------------------------------------------------------------------------------

    private var parar: some View {
        controle(legenda: legendaDoParar) {
            Button(action: fechar) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Estilo.perigoTexto)
                    .frame(width: 18, height: 18)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Estilo.noAr.opacity(0.24)))
                    .contentShape(Circle())
            }
            .buttonStyle(.toque)
            .accessibilityLabel(gravador.estado.ocupada ? tr("Parar e salvar a gravação") : legendaDoParar)
        }
    }

    private var legendaDoParar: String {
        if gravador.estado.ocupada { return tr("Parar e salvar") }
        return transmitindo ? tr("Parar") : tr("Cancelar")
    }

    private func controle<B: View>(legenda: String, @ViewBuilder _ botao: () -> B) -> some View {
        VStack(spacing: 6) {
            botao()
            Text(legenda)
                .font(Estilo.corpo(.caption, .medium))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
        }
    }
}

/// **Os avisos da tela da câmera** (§6.5): a interrupção, o conselho (com "Esquecer aparelhos
/// pareados" quando é a ação certa), gravando sem som, o microfone que não abriu (com "Abrir os
/// Ajustes" quando resolve) e o recado do gravador. No máximo dois à vista (um deitado), o resto em
/// "+N". As frases são as de sempre.
struct AvisosDaTelaDaCamera: View {
    @ObservedObject var dono: DonoDaCaptura
    @ObservedObject var gravador: GravadorLocal
    let interrupcao: String
    let conselho: String
    let ofereceDesparear: Bool
    let aoDesparear: () -> Void
    let abrirAjustes: () -> Void
    var maximo = 2

    var body: some View {
        if !itens.isEmpty {
            PilhaDeAvisos(itens: itens, maximo: maximo)
        }
    }

    private var itens: [ItemDeAviso] {
        var v: [ItemDeAviso] = []
        if !interrupcao.isEmpty {
            v.append(ItemDeAviso(id: "interrupcao", texto: interrupcao, icone: "pause.circle"))
        }
        if !conselho.isEmpty {
            // Só no caso em que é a ação certa: a retomada falhou e o núcleo não volta ao PIN sozinho
            // (dívida 22).
            v.append(ItemDeAviso(id: "conselho", texto: conselho, tom: .vermelho,
                                 acao: ofereceDesparear ? tr("Esquecer aparelhos pareados") : nil,
                                 aoTocar: ofereceDesparear ? aoDesparear : nil))
        }
        // Gravar não liga o microfone (decisão do Pessoa Exemplo, 24/09 à noite): dito por extenso, e ligar
        // no meio grava som dali em diante.
        if gravador.estado.gravando, !dono.microfone.ligado {
            v.append(ItemDeAviso(id: "semsom", texto: GravadorLocal.textoSemSom, icone: "mic.slash"))
        }
        if let a = dono.microfone.aviso {
            v.append(ItemDeAviso(id: "microfone", texto: a.texto, icone: "mic.slash.fill",
                                 acao: a.podeAbrirAjustes ? tr("Abrir os Ajustes") : nil,
                                 aoTocar: a.podeAbrirAjustes ? abrirAjustes : nil))
        }
        if let r = gravador.recado {
            v.append(ItemDeAviso(id: "recado", texto: r.texto, tom: r.grave ? .ambar : .informacao,
                                 icone: "film"))
        }
        return v
    }
}

/// **A bancada da câmera comum**, sem toque, só com o diagnóstico ligado (o mesmo cuidado de
/// `--pin-da-camera`): `--camera-comum frontal|traseira` abre o app direto na tela da câmera, com a
/// grande-angular daquele lado. Os outros argumentos valem como na tela R5 (`--pin-da-camera`,
/// `--microfone-apos`, `--microfone-tom`, `--gravar-apos`, `--gravar-por`, `--matar-gravando-apos`,
/// `--guardar-copia`). A câmera filma a sala: cada corrida pede o sim do Pessoa Exemplo.
enum BancadaDaCameraComum {
    private static var consumida = false

    /// O lado pedido, se houver.
    static var pedida: AVCaptureDevice.Position? {
        guard Diagnostico.ligado else { return nil }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--camera-comum"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "frontal": return .front
        case "traseira": return .back
        default: return nil
        }
    }

    /// Uma vez por vida do app: a origem pedida, dentre as que o seletor oferece (`cameras`).
    static func consumir(de cameras: [Origem]) -> Origem? {
        guard !consumida, let lado = pedida else { return nil }
        consumida = true
        let padrao = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lado)?.uniqueID
        let escolhida = cameras.first { o in
            if case .camera(let id, _) = o { return id == padrao }
            return false
        } ?? cameras.first { o in
            if case .camera(let id, _) = o { return AVCaptureDevice(uniqueID: id)?.position == lado }
            return false
        }
        Diagnostico.nota("APP CAMERA bancada: --camera-comum \(lado == .front ? "frontal" : "traseira")"
            + " → \(escolhida?.nome ?? "nenhuma câmera desse lado")")
        return escolhida
    }
}

/// A camada de pré-visualização, que é do AVFoundation e não do SwiftUI.
struct PreVisualizacao: UIViewRepresentable {
    /// O **dono da captura**, e não um ângulo copiado dele.
    ///
    /// A primeira versão recebia `angulo: CGFloat`, e não funcionava: `anguloDaPrevia` é
    /// propriedade computada e não `@Published`, então o SwiftUI não re-renderizava quando o
    /// coordenador de rotação nascia — a view ficava com o valor que existia no momento em que
    /// foi criada, que é antes de a câmera estar montada. Guardar a referência e **ler na hora do
    /// leiaute** tira essa corrida, que é a mesma que já me pegou três vezes hoje neste arquivo.
    ///
    /// Era o `EmissorDeCamera` até o R5; a câmera mudou para `DonoDaCaptura`, e a prévia com ela —
    /// é o que deixa a tela "Teleprompter com câmera" mostrar a prévia sem sessão nenhuma de pé.
    let dono: DonoDaCaptura
    /// **Esconder a prévia é esconder a vista** (`isHidden`), e nada mais: a camada continua presa
    /// à mesma `AVCaptureSession`, e a câmera, a transmissão e (na fase 3) a gravação não ficam
    /// sabendo (`docs/teleprompter-com-camera.md` §2.5, G2). Só a tela R5 esconde.
    var escondida = false

    func makeUIView(context: Context) -> VistaDePreVisualizacao {
        let v = VistaDePreVisualizacao()
        v.camada.session = dono.sessao
        // **`.resizeAspect`, e as barras são o preço — de propósito.** O `.resizeAspectFill` que
        // estava aqui corta o que não couber na proporção da vista, e o que o encoder manda é o
        // quadro inteiro da sessão: a pessoa enquadra pelo que vê e transmite outra coisa.
        // **Observado** em 03/09/2026, com o aparelho na mão e sem instrumento (`docs/bancada.md`
        // §8.15) — a imagem que chegou ao Mac tinha mais cena do que a que o iPhone exibia. E nem
        // era recorte fixo, que desse para aprender: `VistaDePreVisualizacao` não fixa proporção
        // nenhuma, então quanto se cortava dependia do layout.
        //
        // No caso dominante — iPhone em retrato, sessão 720x1280 numa tela ~9:19,5 — as barras
        // ficam **em cima e embaixo**; nas laterais só num 4:3, como o iPad. Elas ficam pretas
        // pelo `Color.black` do `ZStack` de `TelaDaCamera`, que até aqui só aparecia antes do
        // primeiro quadro. A vista e a camada seguem transparentes.
        //
        // **O que isto NÃO conserta, e vale saber antes de deitar o aparelho:** a conexão desta
        // camada nunca recebe orientação — `acompanharOrientacao` (EmissorDeCamera.swift) escreve
        // em `saida.connection`, não aqui. Em paisagem a prévia continua em retrato, e com
        // `.resizeAspect` isso passa a aparecer como uma tira central em vez de preencher. É
        // defeito anterior a esta linha, e fica registrado em vez de mascarado.
        v.camada.videoGravity = .resizeAspect
        return v
    }

    /// A prévia se orienta sozinha, em `VistaDePreVisualizacao.layoutSubviews`. Ver lá o porquê
    /// de não ser aqui.
    func updateUIView(_ uiView: VistaDePreVisualizacao, context: Context) {
        uiView.dono = dono
        // A linha de "escondida"/"à mostra" sai do `didSet` da vista, e não daqui: assim ela
        // testemunha **qualquer** escritor, e não só este caminho.
        if uiView.isHidden != escondida { uiView.isHidden = escondida }
        // **A camada se registra no dono**, que a orienta no laço de 1 Hz. Ver
        // `DonoDaCaptura.camadaDePrevia`: depender de `layoutSubviews` não funcionou porque ele
        // só dispara quando o tamanho muda, e o ângulo certo só existe depois de a câmera montar.
        dono.camadaDePrevia = uiView.camada
        uiView.setNeedsLayout()
    }
}

final class VistaDePreVisualizacao: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    /// **A prévia tem conexão própria, e ela se orienta aqui — não no `updateUIView`.**
    ///
    /// O comentário de `makeUIView` registrava isto como defeito conhecido: `acompanharOrientacao`
    /// escreve em `saida.connection`, que é a do **encoder**, e a camada continuava em retrato.
    /// Com `.resizeAspect` o efeito era uma tira central em vez de tela cheia.
    ///
    /// A primeira tentativa foi no `updateUIView`, e caiu na **mesma armadilha** que a conexão de
    /// captura já tinha me custado cinco tentativas no mesmo dia: ele roda logo depois do
    /// `makeUIView`, quando `camada.connection` ainda é `nil`, volta calado, e depois não roda
    /// mais porque nada no estado do SwiftUI mudou.
    ///
    /// `layoutSubviews` não tem esse problema: o UIKit o chama quando a vista **tem** tamanho, e
    /// de novo a cada giro. É o gatilho que existe pelo mesmo motivo pelo qual eu precisava de um.
    /// De quem ler o ângulo, na hora do leiaute. Ver `PreVisualizacao`.
    weak var dono: DonoDaCaptura?

    /// **Esconder é só isto**, e a linha sai daqui — de quem quer que escreva. Na prova de 24/09
    /// (iPhone X) o diário tinha "à mostra" e não tinha "escondida"; a causa provável é o
    /// `idevicesyslog` ter começado depois dos 10 s de `--esconder-previa-apos` (não medido). Com a
    /// linha no `didSet` e o `escondida=` no relato de 10 s do dono, a ausência deixa de ser
    /// ambígua.
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            Diagnostico.nota("APP PREVIA \(isHidden ? "escondida" : "à mostra")"
                + " (a sessão continua: rodando=\(dono?.sessao.isRunning.description ?? "?"))")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // **O registro vem ANTES do guard.** Pela quarta vez em 07/09/2026 eu pus um
        // `Diagnostico.nota` depois de uma cláusula que volta calada, e li a ausência de linha
        // como "não foi chamado". Um ramo que desiste sem dizer é indistinguível de um ramo que
        // não roda, e essa confusão custou o dia inteiro neste arquivo.
        Diagnostico.nota("APP PREVIA leiaute: tamanho=\(Int(bounds.width))x\(Int(bounds.height))"
            + " conexao=\(camada.connection == nil ? "nil" : "ok")"
            + " camera=\(dono == nil ? "nil" : "ok")"
            + " sessao=\(camada.session == nil ? "nil" : "ok")")
        guard let conexao = camada.connection else { return }
        // A montagem sem travar ainda na fila da câmera: nada nas conexões daqui (a volta dela
        // redesenha e este leiaute roda de novo).
        guard dono?.montado != false else { return }
        // O espelho da prévia (o ajuste local da tela R5), agora que a conexão existe.
        dono?.aplicarEspelhoNaPrevia()
        let orientacao = window?.windowScene?.interfaceOrientation
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.interfaceOrientation
            ?? .portrait
        if #available(iOS 17.0, *) {
            let angulo = dono?.anguloDaPrevia
                ?? DonoDaCaptura.anguloPara(orientacao)
            Diagnostico.nota("APP PREVIA angulo: pedido=\(Int(angulo))"
                + " atual=\(Int(conexao.videoRotationAngle))"
                + " suportado=\(conexao.isVideoRotationAngleSupported(angulo))"
                + " interface=\(orientacao.rawValue)")
            guard conexao.isVideoRotationAngleSupported(angulo),
                  conexao.videoRotationAngle != angulo else { return }
            conexao.videoRotationAngle = angulo
        } else {
            let nova: AVCaptureVideoOrientation
            switch orientacao {
            case .landscapeLeft: nova = .landscapeLeft
            case .landscapeRight: nova = .landscapeRight
            case .portraitUpsideDown: nova = .portraitUpsideDown
            default: nova = .portrait
            }
            guard conexao.isVideoOrientationSupported, conexao.videoOrientation != nova else { return }
            conexao.videoOrientation = nova
        }
    }
    var camada: AVCaptureVideoPreviewLayer {
        // `layerClass` acima garante o tipo; o `as!` aqui seria a única forma de o compilador
        // saber disso, e um `as!` num caminho de interface é uma queda de app à espera de
        // acontecer. O `guard` devolve uma camada nova no caso impossível, e a tela fica preta em
        // vez de o app morrer.
        guard let l = layer as? AVCaptureVideoPreviewLayer else { return AVCaptureVideoPreviewLayer() }
        return l
    }
}
