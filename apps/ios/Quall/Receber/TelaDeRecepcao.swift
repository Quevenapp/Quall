// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import AVFoundation
import SwiftUI
import UIKit

/// A camada de exibição, embrulhada para o SwiftUI.
///
/// `AVSampleBufferDisplayLayer` é uma `CALayer`, e a única forma correta de a ter numa árvore
/// SwiftUI é uma `UIView` cuja `layerClass` **é** ela — não uma sublayer adicionada à mão, que
/// precisaria de código de `layoutSubviews` para acompanhar o redimensionamento e erraria em toda
/// rotação do iPad.
struct VistaDeVideo: UIViewRepresentable {
    /// A vista que **de fato** carrega a camada, e que acompanha o próprio tamanho.
    ///
    /// # O defeito que esta classe existia para evitar, e não evitava
    ///
    /// Ela já estava escrita aqui, com `layerClass` e tudo — e **nunca foi usada**: o
    /// `makeUIView` devolvia um `UIView()` cru e pendurava a camada como sublayer à mão, que é
    /// exatamente o que a doc acima diz para não fazer. O tamanho da camada era acertado só no
    /// `updateUIView`, que o SwiftUI chama quando o **estado** muda — não a cada passada de
    /// layout. Enquanto a vista ainda não tinha sido medida, `bounds` era `.zero`, e a camada
    /// ficava com quadro zero.
    ///
    /// Uma `AVSampleBufferDisplayLayer` de quadro zero **aceita quadros para sempre e não
    /// desenha nada**: `enqueue` devolve normalmente, `isReadyForMoreMediaData` continua `true`,
    /// `status` nunca vira `.failed`. O sintoma medido na bancada foi
    /// `recebidos 883 · exibidos 883 · decode p50 6,50 ms` com **a tela preta**.
    ///
    /// `layoutSubviews` é chamado em toda passada de layout — a primeira medição real, toda
    /// rotação, toda mudança de tamanho. É o único lugar onde este acerto pertence.
    final class Vista: UIView {
        let camada: AVSampleBufferDisplayLayer

        init(camada: AVSampleBufferDisplayLayer) {
            self.camada = camada
            super.init(frame: .zero)
            backgroundColor = .black
            camada.videoGravity = .resizeAspect
            layer.addSublayer(camada)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("só por código") }

        // A camada não é `layerClass` porque o `Exibidor` é dono dela e vive mais que esta vista:
        // a corrida pode começar antes de a tela montar. O preço é acompanhar o quadro à mão —
        // e o lugar de fazer isso é aqui, não no `updateUIView`.
        override func layoutSubviews() {
            super.layoutSubviews()
            guard camada.frame != bounds else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            camada.frame = bounds
            CATransaction.commit()
        }
    }

    let camada: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> Vista { Vista(camada: camada) }

    func updateUIView(_ v: Vista, context: Context) {
        // De propósito quase vazio: quem acerta o quadro é o `layoutSubviews` da `Vista`. Pedir
        // uma passada aqui cobre o caso de o SwiftUI trocar o tamanho sem invalidar o layout.
        v.setNeedsLayout()
    }

    /// Desmonta a camada quando a vista sai da árvore.
    ///
    /// **A camada é do `Exibidor` e sobrevive a esta vista** — é o que permite a corrida começar
    /// antes de a tela montar. O preço é que largar a vista **não** larga a camada: ela fica
    /// pendurada na `layer` da vista antiga, guardando o **último quadro decodificado**, e volta
    /// a aparecer por cima do que vier depois.
    ///
    /// `flushAndRemoveImage` larga o quadro retido (é conteúdo da tela de outra pessoa, e não
    /// tem por que continuar em memória depois da sessão); `removeFromSuperlayer` tira a camada
    /// da árvore para que ela não pinte nada até ser remontada.
    static func dismantleUIView(_ v: Vista, coordinator: ()) {
        v.camada.flushAndRemoveImage()
        v.camada.removeFromSuperlayer()
    }
}

struct TelaDeRecepcao: View {
    @ObservedObject var painel: Painel
    let exibidor: Exibidor
    /// **A câmera de quem filma** (R9b, `docs/controle-remoto-da-camera.md` §12): a engrenagem na
    /// barra e o painel "Ajustes da câmera" do R9, desenhado a partir das capacidades que chegaram.
    @ObservedObject var camera: ControleRemotoDaCamera
    let conectar: (String, String?, Double) -> Void
    let parar: () -> Void
    /// Volta à tela de escolha de papel. **Escondido enquanto há sessão** (`emSessao`), e isso é a
    /// guarda, não um estilo: sair desta tela com vídeo chegando deixaria a sessão de pé por trás da
    /// tela de escolha, gastando rede e memória sem nada na tela dizendo que ela existe. Quem quer
    /// sair toca em "Parar" (ou no Cancelar, conectando) primeiro — o mesmo contrato do Cancelar do
    /// lado que espelha. A decisão é daqui, que observa o painel, e não de quem cria a tela.
    var voltar: (() -> Void)?

    /// As fases em que há sessão de pé ou a caminho — as mesmas de `Recepcao.noAr`.
    private var emSessao: Bool {
        switch painel.fase {
        case .conectando, .esperandoTrack, .exibindo, .pedindoPermissao: return true
        case .parado, .permissaoNegada, .erro: return false
        }
    }

    private var conectando: Bool { painel.fase == .conectando || painel.fase == .pedindoPermissao }

    @State private var endereco = ""
    @State private var pin = ""
    /// **Zero é sem prazo** — ver `SessaoDeRecepcao.prazo`. Foram 40 s fixos até 10/09/2026.
    private let segundos = 0.0
    /// Espelha `Congelamento.ativo` para a interface. Nasce do valor de lançamento — assim
    /// `--sem-congelar` continua funcionando nas corridas automáticas e a chave aparece na posição
    /// certa quando alguém abre o app com o dedo.
    @State private var congelar = Congelamento.ativo
    @AppStorage("ultimo_endereco") private var ultimoEndereco = ""
    /// A folha da engrenagem (§6.3). A folga de exibição, que morava neste formulário, mora lá.
    @State private var ajustes = false
    /// **O painel de números** (§6.6): fechado no produto, aberto com o diagnóstico ligado ou quando
    /// a sessão foi aberta pela bancada (`--endereco`, `--laco-de-audio`), que fotografa e lê estes
    /// números. O ⓘ da barra abre e fecha.
    @State private var painelAberto = Diagnostico.ligado
        || CommandLine.arguments.contains("--endereco")
        || CommandLine.arguments.contains("--laco-de-audio")
    /// **Tela cheia: sem painel, sem botões, sem barra de status**, e a interface presa na
    /// orientação do vídeo. Pedido do usuário em 10/09/2026, olhando o iPhone X com a tela estendida
    /// do Mac: *"não tem botão tela cheia"* — o mesmo que ele pediu no tablet Android. É a exceção de
    /// `docs/contrato-track.md`: **nada** do painel fica na tela cheia — nem a acusação da imagem, que
    /// ficou presa em laranja na primeira versão (`suspeitos` só sobe, e ele pediu tirar). Os números
    /// seguem no painel, a um toque, no `os_log` e no relato arquivado.
    @State private var telaCheia = false
    @State private var dicaDaTelaCheia = false
    /// **O painel "Ajustes da câmera"** (R9b): por cima do vídeo, sem véu — em pé na metade de baixo,
    /// deitado na metade direita, como na câmera (R9 §4.2). Aberto, um toque na imagem foca e mede
    /// na câmera do outro (o toque longo trava); fechado, a imagem não recebe toque nenhum, para um
    /// toque por acaso não mexer na câmera de ninguém.
    @State private var painelDaCamera = false
    /// O quadrado de 64 pt do toque (R9 §4.4), por 1,5 s.
    @State private var quadradoDoToque: CGPoint?
    @State private var vezDoQuadrado = 0
    @Environment(\.verticalSizeClass) private var classeVertical

    /// Só nestas duas fases existe imagem para mostrar. Fora delas a camada **não entra na
    /// árvore** — ver `VistaDeVideo.dismantleUIView` para o porquê de isto ser estrutural.
    private var exibindoVideo: Bool {
        painel.fase == .exibindo || painel.fase == .esperandoTrack
    }

    /// O vídeo é mais largo que alto — o caso da tela estendida. Falso enquanto o tamanho não veio.
    private var videoDeitado: Bool {
        let lados = painel.dimensao.split(separator: "x").compactMap { Int($0) }
        return lados.count == 2 && lados[0] > lados[1] && lados[1] > 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // **Condicional, e isso é o conserto.** Antes a `VistaDeVideo` ficava sempre na
            // árvore: ao cair a sessão, a tela de entrada voltava com o último quadro
            // decodificado **pintado por cima dela** — faixas de vídeo sobre os campos de
            // endereço e PIN. Num receptor que exibe a tela de outra pessoa isso não é feiura,
            // é **vazamento de conteúdo entre sessões**.
            //
            // Não aparecia antes de 2026-08-27 porque a camada era 0x0 e não desenhava nada: o
            // defeito já existia, escondido atrás do outro.
            if exibindoVideo {
                // **Na tela cheia, o vídeo deitado ocupa a tela mesmo que o iOS não gire.** Em 11/09 o
                // iOS recusou o giro (`BSActionErrorDomain error 1`) com uma cena só, ativa, e o aparelho
                // sem orientação física conhecida (`aparelho=0`) — o vídeo ficava numa faixa em pé.
                // Se a área continua em pé, a própria vista gira 90° e troca largura por altura; se o
                // sistema girou, a área já é deitada e nada muda. Quem olha vira o aparelho.
                GeometryReader { area in
                    let girar = telaCheia && videoDeitado && area.size.height > area.size.width
                    VistaDeVideo(camada: exibidor.camada)
                        .frame(width: girar ? area.size.height : area.size.width,
                               height: girar ? area.size.width : area.size.height)
                        .rotationEffect(.degrees(girar ? -90 : 0))
                        .position(x: area.size.width / 2, y: area.size.height / 2)
                    // R9b: o toque na imagem vai à câmera do outro, só com o painel aberto (e nunca
                    // na tela cheia, que é girada e sai com um toque).
                    if painelDaCamera, !telaCheia, camera.prontos {
                        ZonaDoToqueRemoto { local, longo in tocarNaImagem(local, longo: longo, area: area.size) }
                            .frame(width: area.size.width, height: area.size.height)
                            .overlay(alignment: .topLeading) {
                                if let q = quadradoDoToque {
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Estilo.aguardando, lineWidth: 1.5)
                                        .frame(width: 64, height: 64)
                                        .offset(x: q.x - 32, y: q.y - 32)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .ignoresSafeArea()
                if telaCheia {
                    // Um toque em qualquer ponto sai. Camada própria por cima do vídeo, e não
                    // gesto na `VistaDeVideo`: a vista é UIKit, e o gesto do SwiftUI numa
                    // representável depende de como ela trata toque — aqui não há dúvida.
                    Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                        .onTapGesture { sairDaTelaCheia() }
                    if dicaDaTelaCheia {
                        Text(tr("Toque na tela para sair da tela cheia."))
                            .font(.callout).foregroundColor(.white)
                            .padding(10).background(Color.black.opacity(0.7)).cornerRadius(8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                } else {
                    VStack { Spacer(); barra }
                        .dynamicTypeSize(...Estilo.tetoDaLetra)
                    if painelDaCamera, camera.painelPodeFicar {
                        painelDosAjustesDaCamera
                    }
                }
            } else {
                formulario
            }
        }
        .sheet(isPresented: $ajustes) { FolhaDaEngrenagem(fechar: { ajustes = false }) }
        .statusBar(hidden: telaCheia)
        .modifier(IndicadorDeInicio(escondido: telaCheia))
        // **A tela não apaga enquanto há imagem.** Um monitor que bloqueia sozinho no meio do uso
        // não é monitor; até 10/09/2026 o receptor dependia do Bloqueio Automático estar em
        // "Nunca", que é instrução de bancada e não comportamento de produto.
        .onAppear {
            if exibindoVideo { TelaAcesa.pedir("recepcao", respeitandoPreferencia: false) }
            else { TelaAcesa.soltar("recepcao") }
        }
        .onDisappear {
            TelaAcesa.soltar("recepcao")
            sairDaTelaCheia()
        }
        // O painel da câmera fecha quando a câmera do outro some (sem câmera, sem resposta, sem sessão).
        .onChange(of: camera.painelPodeFicar) { if !$0 { painelDaCamera = false } }
        .onChange(of: exibindoVideo) { exibindo in
            if exibindo { TelaAcesa.pedir("recepcao", respeitandoPreferencia: false) }
            else { TelaAcesa.soltar("recepcao") }
            if !exibindo { sairDaTelaCheia(); painelDaCamera = false }
            // **`--tela-cheia`, argumento de bancada**: entra sozinha 1,5 s depois de haver imagem
            // (o tamanho do vídeo já veio), para provar o giro sem o toque de ninguém. O produto
            // continua sendo o botão.
            if exibindo, CommandLine.arguments.contains("--tela-cheia") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if exibindoVideo, !telaCheia { entrarEmTelaCheia() }
                }
            }
        }
        // **A orientação acompanha o tamanho do vídeo**, e não só o do instante do toque. Em 11/09 a
        // tela cheia entrou com o vídeo ainda "0x0" (antes do primeiro quadro — `exibindoVideo` já vale
        // em `.esperandoTrack`), não prendeu orientação nenhuma e nunca girou. O mesmo vale para um
        // toque rápido da pessoa, e para o vídeo que muda de tamanho no meio. O Android faz igual.
        .onChange(of: painel.dimensao) { dimensao in
            guard telaCheia else { return }
            let lados = dimensao.split(separator: "x").compactMap { Int($0) }
            guard lados.count == 2, lados[0] > 0, lados[1] > 0 else { return }
            Orientacao.travar(larguraDoVideo: lados[0], alturaDoVideo: lados[1])
            Diario.dizer("tela cheia: orientação presa agora (vídeo \(dimensao), \(Orientacao.descricao))")
        }
    }

    private func entrarEmTelaCheia() {
        painelDaCamera = false
        telaCheia = true
        let lados = painel.dimensao.split(separator: "x").compactMap { Int($0) }
        if lados.count == 2 { Orientacao.travar(larguraDoVideo: lados[0], alturaDoVideo: lados[1]) }
        Diario.dizer("tela cheia: entrou (vídeo \(painel.dimensao.isEmpty ? "?" : painel.dimensao), "
                     + "orientação \(Orientacao.descricao))")
        withAnimation { dicaDaTelaCheia = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { dicaDaTelaCheia = false }
        }
    }

    private func sairDaTelaCheia() {
        guard telaCheia else { return }
        telaCheia = false
        dicaDaTelaCheia = false
        Orientacao.soltar()
        Diario.dizer("tela cheia: saiu")
    }

    // --- entrada -------------------------------------------------------------------------------

    /// O formulário (§6.6): o desenho é o `MoldeDeConectar`; aqui só o estado. O endereço digitado é
    /// o **fallback obrigatório do fluxo**, não um contorno: o entitlement de multicast que o mDNS
    /// exige está pendente na Apple, e uma rede que bloqueia multicast existe de qualquer jeito.
    private var formulario: some View {
        MoldeDeConectar(tituloDoCabecalho: tr("Exibir"),
                        titulo: tr("Assistir outro aparelho"),
                        frase: tr("Digite o endereço e o PIN que aparecem na tela de quem está espelhando."),
                        exemplo: "192.168.55.10:7877",
                        endereco: $endereco,
                        pin: $pin,
                        ultimoEndereco: ultimoEndereco,
                        conectando: conectando,
                        // O cancelamento que a sessão já tem (`Recepcao.parar` →
                        // `quall_session_cancel`) só existe com a sessão de pé: enquanto a permissão
                        // de Rede Local é pedida (a sonda pode levar até ~12 s com um IP errado) ainda
                        // não há sessão para cancelar, e o Cancelar fica apagado.
                        podeCancelar: painel.fase == .conectando,
                        avisos: avisos,
                        voltar: emSessao ? nil : voltar,
                        cancelar: parar,
                        // Sem engrenagem conectando: esquecer os pares nesse instante seria desfeito
                        // pelo fim da conexão, que grava o par de novo (`guardarPares`).
                        abrirAjustes: conectando ? nil : { ajustes = true },
                        conectar: {
                            let limpo = endereco.trimmingCharacters(in: .whitespaces)
                            guard !limpo.isEmpty else { return }
                            ultimoEndereco = limpo
                            conectar(limpo, pin.isEmpty ? nil : pin, segundos)
                        }) {
            // A mensagem vazia com a permissão faltando não acontece hoje (as duas andam juntas), mas
            // o botão dos Ajustes não pode depender disso.
            if painel.mensagem.isEmpty, painel.precisaDeRedeLocal {
                Button(textoDoBotaoDosAjustes, action: abrirAjustesDoSistema)
                    .buttonStyle(.secundarioPequeno)
            }
        }
    }

    /// A mensagem de estado ou erro como aviso (§6.6). Erro em vermelho (o "PIN errado" de hoje vira
    /// aviso vermelho, §11.1), permissão negada em âmbar, o resto ("conectando e pareando…",
    /// "cancelado") como informação.
    ///
    /// **O botão dos Ajustes existe porque a frase sozinha não basta.** "Rede Local" mora dentro de
    /// Privacidade e Segurança, três telas fundo adentro nos Ajustes; `openSettingsURLString` abre a
    /// página **deste app**, onde o interruptor aparece — e ele só aparece porque o app pede a
    /// permissão pelo menos uma vez.
    private var avisos: [ItemDeAviso] {
        guard !painel.mensagem.isEmpty else { return [] }
        let tom: Aviso.Tom
        switch painel.fase {
        case .erro: tom = .vermelho
        case .permissaoNegada: tom = .ambar
        default: tom = .informacao
        }
        // A ampulheta só enquanto conecta; "cancelado" e "recepção encerrada" levam o ícone de
        // informação.
        return [ItemDeAviso(id: "mensagem", texto: painel.mensagem, tom: tom,
                            icone: conectando ? "hourglass" : nil,
                            acao: painel.precisaDeRedeLocal
                                ? textoDoBotaoDosAjustes : nil,
                            aoTocar: painel.precisaDeRedeLocal ? abrirAjustesDoSistema : nil)]
    }

    /// O botão que abre a página do app nos Ajustes do sistema.
    private var textoDoBotaoDosAjustes: String {
        tr("Abrir os Ajustes do %@", PermissaoDeRedeLocal.nomeNosAjustes)
    }

    private func abrirAjustesDoSistema() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // --- a câmera de quem filma (R9b) -----------------------------------------------------------

    /// O painel do R9 com os dados remotos (§4.2): em pé, a metade de baixo (no mínimo a altura que
    /// ele precisa para não rolar); deitado, a metade direita. Fundo opaco, sem véu do lado da imagem.
    private var painelDosAjustesDaCamera: some View {
        // Um painel só, com o quadro que muda: girar o aparelho não perde a aba escolhida.
        GeometryReader { g in
            let deitado = classeVertical == .compact
            PainelDaCamera(controles: camera) { painelDaCamera = false }
                .frame(width: deitado ? g.size.width / 2 : g.size.width,
                       height: deitado ? g.size.height
                           : min(g.size.height, max(g.size.height / 2, AbaDoPainelDaCamera.alturaMinima)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: deitado ? .trailing : .bottom)
        }
    }

    /// Um toque na imagem: o ponto **no quadro decodificado** (`PontoNoQuadro`, com o `.resizeAspect`
    /// da camada), e o quadrado onde o dedo tocou. Numa tarja, nada.
    private func tocarNaImagem(_ local: CGPoint, longo: Bool, area: CGSize) {
        let lados = painel.dimensao.split(separator: "x").compactMap { Double($0) }
        guard lados.count == 2,
              let q = PontoNoQuadro.de(toque: (Double(local.x), Double(local.y)),
                                       area: (Double(area.width), Double(area.height)),
                                       video: (lados[0], lados[1])) else {
            Diario.dizer("câmera remota: toque fora da imagem (nas tarjas): nada a fazer")
            return
        }
        guard camera.tocar(x: q.x, y: q.y, longo: longo) else { return }
        vezDoQuadrado += 1
        let vez = vezDoQuadrado
        quadradoDoToque = local
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if vezDoQuadrado == vez { quadradoDoToque = nil }
        }
    }

    // --- durante a corrida ---------------------------------------------------------------------

    /// A frase que diz **de qual lado do fio** está o defeito, quando chega quadro e não sai
    /// imagem. `nil` quando não há do que acusar ninguém.
    ///
    /// Existe por causa da foto de `docs/tela-preta.md` §1. Ali estava tudo o que era preciso
    /// para responder — `recebidos 68 · exibidos 0` — e faltava a única coisa que separava as
    /// duas explicações opostas: se algum conjunto de parâmetros tinha chegado. Sem essa
    /// separação, a frente da matriz, o orquestrador e esta frente foram, em ordem, para o lado
    /// errado (§3.4).
    ///
    /// A ordem dos testes é a ordem em que eles acusam: primeiro o receptor (temos o `OSStatus`,
    /// e ele é prova), depois o emissor (ausência de IDR, que é o caso medido na §9.5).
    private var acusacao: String? {
        // **A acusação da imagem quebrada vem primeiro, e não depende de `enfileirados == 0`.**
        // As acusações abaixo são todas sobre "chega quadro e não sai imagem"; esta é o caso
        // oposto e mais enganoso — sai imagem, e ela está errada. Era exatamente o que o usuário
        // via em quatro pares diferentes enquanto toda a tela dizia zero.
        if painel.suspeitos > 0 {
            return tr("*** %ld quadro(s) exibidos com a referência quebrada"
                      + " — pior rajada %ld seguidos ***", Int(clamping: painel.suspeitos), Int(clamping: painel.piorRajada))
        }
        guard painel.recebidos > 0, painel.enfileirados == 0 else { return nil }
        if painel.falhasDeSessao > 0 {
            return tr("*** o decodificador deste aparelho recusou montar a sessão "
                      + "(OSStatus %ld) ***", Int(painel.ultimaFalha))
        }
        if painel.idrs == 0 {
            return tr("*** nenhum conjunto de parâmetros chegou: o emissor não mandou IDR ***")
        }
        return tr("*** chega quadro e não sai imagem ***")
    }

    /// **A barra fina do vídeo** (§6.6): nome do par (e o rótulo da track) · "Tela cheia" · **Parar** ·
    /// o ⓘ que abre e fecha o painel de números. Vidro preto a 85 % (§11.1). Uma acusação (a linha
    /// laranja do painel) põe um ponto âmbar no ⓘ, para quem está com o painel fechado.
    ///
    /// Não há botão de som: o lado que exibe do iOS não tem mudo nem volume próprios
    /// (`SaidaDeAudio`, `SessaoDeRecepcao`); quem manda é o volume do aparelho.
    private var barra: some View {
        VStack(spacing: 8) {
            if painelAberto {
                painelDeNumeros
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(painel.par.isEmpty ? painel.endereco : painel.par)
                        .font(Estilo.corpo(.subheadline, .semibold))
                        .foregroundColor(Estilo.texto)
                    if !painel.rotuloDaTrack.isEmpty {
                        Text(painel.rotuloDaTrack)
                            .font(Estilo.corpo(.caption))
                            .foregroundColor(Estilo.texto2)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(-1)
                Spacer(minLength: 4)
                Button(tr("Tela cheia"), action: entrarEmTelaCheia)
                    .buttonStyle(BotaoSecundario(pequeno: true, largo: false, fundo: Color.white.opacity(0.14)))
                Button(tr("Parar"), action: parar)
                    .buttonStyle(BotaoDePerigo(pequeno: true, largo: false))
                // R9b: os ajustes da câmera de quem filma — a engrenagem do R9 (§4.1) —, só quando
                // ela respondeu (pronta, ou com o controle remoto não permitido).
                if camera.mostraEngrenagem {
                    BotaoRedondo(icone: "gearshape", rotulo: tr("Ajustes da câmera"),
                                 fundo: painelDaCamera ? Estilo.acento : Color.white.opacity(0.1)) {
                        painelDaCamera.toggle()
                        Diario.dizer("câmera remota: painel \(painelDaCamera ? "aberto" : "fechado")")
                    }
                    .accessibilityAddTraits(painelDaCamera ? [.isSelected] : [])
                }
                BotaoRedondo(icone: "info.circle",
                             rotulo: painelAberto ? tr("Esconder os números") : tr("Mostrar os números"),
                             ponto: acusacao != nil ? Estilo.aguardando : nil,
                             fundo: Color.white.opacity(0.1)) {
                    withAnimation(.easeOut(duration: 0.2)) { painelAberto.toggle() }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Estilo.vidro))
        }
        .padding(10)
    }

    /// Os números de hoje, sem tirar nenhum: esta é a tela que a bancada fotografa.
    private var painelDeNumeros: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%@ · %@ · recebidos %llu · enfileirados %llu · %.1f fps",
                        painel.dimensao, painel.perfil, painel.recebidos, painel.enfileirados, painel.fps))
            Text(String(format: "primeira imagem %@ · decode p50 %.2f ms · p95 %.2f ms · marca ok %llu / erro %llu",
                        painel.primeiraImagemMs > 0 ? String(format: "%.0f ms", painel.primeiraImagemMs) : "ainda não",
                        painel.decodeP50Ms, painel.decodeP95Ms,
                        painel.marcasCertas, painel.marcasErradas))
            Text(String(format: "idrs %llu · sem_parametros %llu · falhas_sessao %llu%@",
                        painel.idrs, painel.semParametros, painel.falhasDeSessao,
                        painel.ultimaFalha != 0 ? " · ultima_falha \(painel.ultimaFalha)" : ""))
            // **A linha da imagem.** Ela existe porque a queixa do usuário era sobre a TELA:
            // *"em nenhuma tela aparece nos contadores falhas, sempre é 0 e em todas estão
            // falhando"*. Em 31/08 os contadores já mediam certo no log e ele, olhando para o
            // iPad no meio de uma corrida com 124 quadros suspeitos, disse *"continua falhando e
            // 0 falhas"* — e continuava certo, porque nada disto chegava aqui.
            //
            // `sem_referencia_ms` vem com a cauda à mostra de propósito: `p50` de 10 ms é
            // imperceptível e `max` de 947 ms é quase um segundo de tela errada, e uma média
            // esconderia justamente o que a pessoa sente.
            Text(String(format: "imagem: rupturas %llu · suspeitos %llu · pior rajada %llu · retidos %llu · sem_referencia_ms %@",
                        painel.rupturas, painel.suspeitos, painel.piorRajada,
                        painel.retidos, painel.semReferenciaMs))
                .foregroundColor(painel.suspeitos > 0 ? Estilo.aguardandoTexto : Estilo.texto)
            if let acusacao {
                Text(acusacao).bold().foregroundColor(Estilo.aguardandoTexto)
            }
            // **O interruptor do A/B.** A pergunta que nenhum contador desta casa responde é se
            // a porta melhora a tela para quem assiste, e responder exige virar a chave **na
            // mesma sessão**: dois enlaces de 2,4 GHz seguidos não são comparáveis entre si.
            //
            // Ligado: quadro com a referência condenada não vai para a tela, e a imagem PARA até
            // o IDR seguinte (no máximo 2 s, pela válvula). Desligado: ele vai, e a imagem escorre
            // suja — que é o comportamento que existiu até 31/08/2026 e que o usuário fotografou
            // como "a bolinha deixa rastro".
            //
            // Os contadores continuam contando dos dois lados: `suspeitos` não depende da porta,
            // só `retidos` depende. Virar a chave muda o que se vê, não o que se mede.
            Toggle(isOn: $congelar) {
                Text(tr("segurar quadro sem referência (imagem para em vez de sujar)"))
                    .font(Estilo.corpo(.footnote))
            }
            .onChange(of: congelar) { Congelamento.definir($0) }
            .tint(Estilo.aguardando)
            // Só aparece quando **há** track de áudio. Uma linha de zeros numa sessão sem som
            // seria a tela afirmando que mediu algo que não existia — e é exatamente a diferença
            // que `docs/audio.md` §7 fixa para os contadores do núcleo: `null` quer dizer "não
            // medido", e não zero.
            if !painel.audio.isEmpty {
                Text(painel.audio)
            }
            // **Acima do JSON cru, e de propósito.** Esta é a tela que a bancada fotografa; o
            // número de perda que ela mostrava vinha do teto, que cobra reordenação como perda.
            // A linha mastigada põe exata, teto e "tarde demais" lado a lado.
            if !painel.resumoDePerda.isEmpty {
                Text(painel.resumoDePerda)
            }
            Text(painel.contadoresDoNucleo).lineLimit(2)
        }
        .font(Estilo.mono(.caption, .regular))
        .foregroundColor(Estilo.texto)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Estilo.vidro))
    }
}

/// **A zona do toque na imagem** (R9b), com o toque e o toque longo do UIKit: no iOS 15 o
/// `onTapGesture` do SwiftUI não dá o ponto (o mesmo motivo de `VistaDoToqueNaPrevia`). Devolve o
/// ponto nesta vista, que tem o tamanho da área do vídeo.
private struct ZonaDoToqueRemoto: UIViewRepresentable {
    let tocou: (CGPoint, Bool) -> Void

    final class Vista: UIView {
        var tocou: ((CGPoint, Bool) -> Void)?

        @objc func toque(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            tocou?(g.location(in: self), false)
        }

        @objc func longo(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            tocou?(g.location(in: self), true)
        }
    }

    func makeUIView(context: Context) -> Vista {
        let v = Vista()
        v.backgroundColor = .clear
        let toque = UITapGestureRecognizer(target: v, action: #selector(Vista.toque(_:)))
        let longo = UILongPressGestureRecognizer(target: v, action: #selector(Vista.longo(_:)))
        longo.minimumPressDuration = 0.5
        toque.require(toFail: longo)
        v.addGestureRecognizer(toque)
        v.addGestureRecognizer(longo)
        return v
    }

    func updateUIView(_ v: Vista, context: Context) { v.tocou = tocou }
}
