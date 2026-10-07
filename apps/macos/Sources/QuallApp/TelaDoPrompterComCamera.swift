import AVFoundation
import QuallCaptureKit
import QuallIdiomaKit
import QuallTeleprompterKit
import SwiftUI

/// **A tela "Teleprompter com câmera" no Mac** (R5 fase 4, `docs/teleprompter-com-camera.md` §2.5 e
/// §8.9, item 4).
///
/// - **Texto do lado da lente**: num MacBook (e com webcam externa, por padrão) a lente fica na
///   borda de cima, então o texto fica **em cima**; o ajuste local "lado do texto" muda. 50/50 por
///   padrão, borda arrastável, mínimo de 20 % por lado, gravada por lado.
/// - **Nada entre o texto e a lente**: o aviso de controle sumido, os dois PINs, o microfone, o
///   Gravar e a barra ficam numa **faixa** na ponta oposta (lado a lado, no pé da coluna da prévia).
///   As marcas do enquadramento vão ao pé do texto (`VistaDoTexto.marcasNoPe`). A barra de título da
///   janela é do sistema e fica em cima fora da tela cheia (§8.9, a releitura).
/// - **Esconder a prévia** é `isHidden` da vista: a câmera, a transmissão e a gravação seguem.
/// - **A prévia como espelho** é da conexão da camada; a rede e o arquivo nunca espelham.
struct TelaDoPrompterComCamera: View {
    @EnvironmentObject private var tp: Teleprompter
    @ObservedObject var cam: TelaComCamera
    @Environment(\.openWindow) private var abrirJanela

    var body: some View {
        GeometryReader { g in
            let lado = cam.ladoDoTexto
            let total = lado.vertical ? g.size.height : g.size.width
            let doTexto = max(60, total * cam.fracao)
            Group {
                if lado.vertical {
                    VStack(spacing: 0) {
                        if lado == .cima {
                            areaDoTexto.frame(height: doTexto)
                            divisor(total: total, lado: lado)
                            colunaDaPrevia(faixaNoPe: true)
                        } else {
                            colunaDaPrevia(faixaNoPe: false)
                            divisor(total: total, lado: lado)
                            areaDoTexto.frame(height: doTexto)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        if lado == .esquerda {
                            areaDoTexto.frame(width: doTexto)
                            divisor(total: total, lado: lado)
                            colunaDaPrevia(faixaNoPe: true)
                        } else {
                            colunaDaPrevia(faixaNoPe: true)
                            divisor(total: total, lado: lado)
                            areaDoTexto.frame(width: doTexto)
                        }
                    }
                }
            }
            .coordinateSpace(name: "r5")
        }
        .background(Color.black)
        .frame(minWidth: 760, idealWidth: 1024, maxWidth: .infinity, minHeight: 560, idealHeight: 760, maxHeight: .infinity)
        .sheet(isPresented: $tp.editorAberto) { EditorDoRoteiro().environmentObject(tp) }
    }

    // MARK: - o texto

    private var areaDoTexto: some View {
        ZStack {
            VistaDoTextoRepresentavel(modelo: tp)
            if tp.texto.isEmpty {
                Text(T("Sem roteiro.\nToque em Editar ou cole um texto — aqui ou no controle."))
                    .font(.system(size: 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.55))
                    .scaleEffect(x: tp.estado.espelho ? -1 : 1, y: 1)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    // MARK: - a borda

    private func divisor(total: CGFloat, lado: LadoDoTexto) -> some View {
        let vertical = lado.vertical
        return ZStack {
            Rectangle().fill(Estilo.superficieAlta)
            Capsule().fill(Estilo.texto3)
                .frame(width: vertical ? 44 : 4, height: vertical ? 4 : 44)
        }
        .frame(width: vertical ? nil : 10, height: vertical ? 10 : nil)
        .contentShape(Rectangle())
        .onHover { dentro in
            if dentro { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("r5"))
            .onChanged { v in
                guard total > 0 else { return }
                let f: Double
                switch lado {
                case .cima: f = v.location.y / total
                case .baixo: f = (total - v.location.y) / total
                case .esquerda: f = v.location.x / total
                case .direita: f = (total - v.location.x) / total
                }
                cam.fracao = min(0.8, max(0.2, f))
            }
            .onEnded { _ in cam.guardarFracao() })
        .help(T("Arraste para dividir a tela entre o texto e a prévia (de 20 % a 80 %)"))
    }

    // MARK: - a prévia e a faixa

    @ViewBuilder private func colunaDaPrevia(faixaNoPe: Bool) -> some View {
        VStack(spacing: 0) {
            if !faixaNoPe { faixa }
            previa
            if faixaNoPe { faixa }
        }
    }

    private var previa: some View {
        ZStack {
            Color.black
            if let d = cam.dono {
                PreviaDaCamera(dono: d, espelhar: cam.espelharPrevia, escondida: cam.previaEscondida)
            }
            if cam.previaEscondida {
                Text(T("Prévia escondida — a câmera continua transmitindo e gravando."))
                    .font(.callout).foregroundColor(Estilo.texto2)
            } else if cam.dono == nil {
                if let e = cam.erroDaCamera {
                    Text(e).font(.callout).foregroundColor(Estilo.aguardandoTexto).multilineTextAlignment(.center).padding()
                } else {
                    ProgressView(T("Abrindo a câmera…")).controlSize(.small)
                }
            }
        }
        .frame(minHeight: 60, maxHeight: .infinity)
        .clipped()
        // **Os ajustes da câmera** (R9, §4.1): o botão junto da prévia, e a pílula do ⌥-clique ou o recado
        // de 3 s. Do lado da prévia, nunca entre o texto e a lente.
        .overlay(alignment: .topTrailing) {
            if let d = cam.dono, d.montado, !cam.previaEscondida {
                BotaoDosAjustesDaCamera { abrirJanela(id: JanelaDosAjustesDaCamera.id) }.padding(8)
            }
        }
        .overlay(alignment: .top) {
            if let d = cam.dono, !cam.previaEscondida, let p = d.pilulaSobreAPrevia {
                PilulaDaCamera(texto: p.texto, icone: p.icone).padding(.top, 12).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var faixa: some View {
        if let espera = cam.espera, let gravador = cam.gravador {
            FaixaDaTelaComCamera(cam: cam, espera: espera, gravador: gravador)
        } else {
            FaixaSemCamera(cam: cam)
        }
    }
}

/// A faixa enquanto a câmera não abriu (ou não abre): o aviso e o Sair, para a tela nunca prender.
private struct FaixaSemCamera: View {
    @EnvironmentObject private var tp: Teleprompter
    @ObservedObject var cam: TelaComCamera

    var body: some View {
        HStack {
            Text(cam.erroDaCamera ?? T("Abrindo a câmera…"))
                .font(.callout).foregroundColor(cam.erroDaCamera == nil ? Estilo.texto2 : Estilo.aguardandoTexto)
                .lineLimit(2)
            Spacer()
            Button(T("Sair")) { tp.sair() }
        }
        .padding(10)
        .background(Estilo.superficie)
        .environment(\.colorScheme, .dark)
    }
}

/// **A faixa**: os avisos numa linha (o mais grave, "+N"), o estado das duas sessões e os controles.
private struct FaixaDaTelaComCamera: View {
    @EnvironmentObject private var tp: Teleprompter
    @ObservedObject var cam: TelaComCamera
    @ObservedObject var espera: EsperaDaCamera
    @ObservedObject var gravador: GravadorLocal
    @State private var avisosAbertos = false
    @State private var enderecoDoTexto = false
    @State private var enderecoDaCamera = false

    private var avisos: [(texto: String, grave: Bool)] {
        var a: [(String, Bool)] = []
        if tp.avisos.parSumido && tp.jaHouveSessao {
            a.append((T("Controle sumido — o texto continua como estava; esperando o controle voltar."), true))
        }
        if let d = cam.dono, !d.interrupcao.isEmpty { a.append((T("Câmera: %@", d.interrupcao), true)) }
        if let e = cam.erroDaCamera { a.append((e, true)) }
        if gravador.estado.gravando, cam.dono?.microfone.ligado != true { a.append((GravadorLocal.textoSemSom, true)) }
        if let m = cam.dono?.microfone.motivo { a.append((T("Microfone: %@", m), true)) }
        if let r = gravador.recado { a.append((r.texto, r.grave)) }
        if !espera.mensagem.isEmpty { a.append((espera.mensagem, false)) }
        if !tp.mensagem.isEmpty { a.append((tp.mensagem, true)) }
        if tp.avisos.atualizeOApp { a.append((T("O controle fala outra versão do teleprompter: atualize o app nos dois aparelhos."), true)) }
        if !tp.avisoDaFonte.isEmpty { a.append((tp.avisoDaFonte, false)) }
        return a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            linhaDosAvisos
            HStack(spacing: 8) {
                chipDoTexto
                chipDaCamera
                Spacer(minLength: 4)
                if let d = cam.dono { BotaoDoMicrofone(cam: cam, dono: d) }
                BotaoDeGravar(gravador: gravador, dono: cam.dono) { cam.gravacao?.tocar() }
            }
            HStack(spacing: 8) {
                Button { tp.saltar(0) } label: { Image(systemName: "backward.end.fill") }.help(T("Voltar ao começo"))
                Button { tp.pular(-0.05) } label: { Image(systemName: "backward.fill") }
                Button { tp.tocarOuPausar() } label: {
                    Image(systemName: tp.estado.rolando ? "pause.fill" : "play.fill").frame(width: 30)
                }
                .buttonStyle(.borderedProminent)
                Button { tp.pular(0.05) } label: { Image(systemName: "forward.fill") }
                Text(String(format: "%.0f%%", tp.estado.posicao * 100))
                    .font(.system(size: 11, design: .monospaced)).frame(width: 36)
                passo(T("Vel."), String(format: "%.2f", tp.estado.velocidade), { tp.mudarVelocidade(-0.1) }, { tp.mudarVelocidade(0.1) })
                passo(T("Fonte"), String(format: "%.0f", tp.estado.fonte),
                      { tp.definirFonte(tp.estado.fonte - 4) }, { tp.definirFonte(tp.estado.fonte + 4) })
                Spacer(minLength: 4)
                menuDeAjustes
                Button(T("Editar…")) { tp.abrirEditor() }
                Button { tp.alternarTelaCheia() } label: {
                    Image(systemName: tp.emTelaCheia ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(T("Tela cheia (F): a barra de título sai de cima da lente"))
                Button(tp.fase == .encerrando ? T("Saindo…") : (gravador.estado.ocupada ? T("Parar e sair") : T("Sair"))) { tp.sair() }
                    .disabled(tp.fase == .encerrando)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(Estilo.superficie)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var linhaDosAvisos: some View {
        let lista = avisos
        if let primeiro = lista.first {
            Button { avisosAbertos.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: primeiro.grave ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundColor(primeiro.grave ? Estilo.aguardando : Estilo.texto2)
                    Text(primeiro.texto).lineLimit(1).truncationMode(.tail)
                    if lista.count > 1 { Text("+\(lista.count - 1)").foregroundColor(Estilo.texto2) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $avisosAbertos, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lista.enumerated()), id: \.offset) { _, a in
                        Text(a.texto).foregroundColor(a.grave ? Estilo.aguardandoTexto : Estilo.texto)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(width: 420)
            }
        }
    }

    private var chipDoTexto: some View {
        let cor: Color = tp.fase == .conectado && !tp.avisos.parSumido ? Estilo.conectado
            : (tp.fase == .formulario ? Estilo.noAr : Estilo.aguardando)
        let estado = tp.fase == .conectado ? (tp.avisos.parSumido ? T("%@ não responde", tp.par) : T("controlado por %@", tp.par))
            : (tp.fase == .semPar ? T("controle sumido") : (tp.fase == .formulario ? T("a espera parou") : T("esperando o controle")))
        return chip(cor: cor, titulo: T("Texto"), pin: tp.pin, estado: estado, aberto: $enderecoDoTexto) {
            painelDoEndereco(titulo: T("Controle do texto (Quall Studio → Teleprompter → Controlar)"), pin: tp.pin,
                             endereco: tp.endereco, anuncia: tp.anunciandoPorMDNS, alias: tp.nomeNaDescoberta,
                             acao: tp.fase == .formulario ? (T("Esperar de novo"), { tp.esperarPeloControle() }) : nil)
        }
    }

    private var chipDaCamera: some View {
        let cor: Color
        let estado: String
        switch espera.fase {
        case .transmitindo: cor = Estilo.conectado; estado = T("enviando para %@", espera.par)
        case .esperando: cor = Estilo.aguardandoTexto; estado = T("esperando quem recebe")
        case .desistiu: cor = Estilo.noAr; estado = T("parou de esperar")
        case .parada: cor = Estilo.texto3; estado = T("parada")
        }
        return chip(cor: cor, titulo: T("Câmera"), pin: espera.pin, estado: estado, aberto: $enderecoDaCamera) {
            painelDoEndereco(titulo: T("Receber a câmera (Quall Studio → Exibir, ou o OBS)"), pin: espera.pin,
                             endereco: espera.endereco, anuncia: espera.anunciandoPorMDNS, alias: espera.nomeNaDescoberta, acao: nil)
        }
    }

    private func chip<C: View>(cor: Color, titulo: String, pin: String, estado: String, aberto: Binding<Bool>,
                               @ViewBuilder conteudo: @escaping () -> C) -> some View {
        Button { aberto.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(cor).frame(width: 8, height: 8)
                Text(titulo).font(.system(size: 12, weight: .semibold))
                Text(Estilo.pinEspacado(pin)).font(.system(size: 12, design: .monospaced))
                Text(estado).font(.system(size: 11)).foregroundColor(Estilo.texto2).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Estilo.superficieAlta)
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .popover(isPresented: aberto, arrowEdge: .bottom, content: conteudo)
        .help(T("O PIN e o endereço desta sessão, em letra grande"))
    }

    private func painelDoEndereco(titulo: String, pin: String, endereco: String?, anuncia: Bool, alias: String?,
                                  acao: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titulo).font(.headline)
            Text("PIN").font(.caption2).fontWeight(.semibold).foregroundColor(Estilo.texto2)
            Text(Estilo.pinEspacado(pin)).font(.system(size: 34, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Text(T("ENDEREÇO")).font(.caption2).fontWeight(.semibold).foregroundColor(Estilo.texto2)
            Text(endereco ?? T("sem rede")).font(.system(size: 24, weight: .semibold, design: .monospaced))
                .textSelection(.enabled).foregroundColor(endereco == nil ? Estilo.aguardandoTexto : Estilo.texto)
            Text(anuncia ? T("Aparecendo na lista dos outros aparelhos como %@.", alias ?? "Quall") : T("Sem anúncio na rede — digite o endereço."))
                .font(.caption).foregroundColor(Estilo.texto2)
            if let acao { Button(acao.0, action: acao.1).buttonStyle(.borderedProminent) }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var menuDeAjustes: some View {
        Menu {
            Picker(T("Lado do texto"), selection: $cam.ladoDoTexto) {
                ForEach(LadoDoTexto.allCases) { Text($0.rotulo).tag($0) }
            }
            Toggle(T("Prévia como espelho"), isOn: $cam.espelharPrevia)
            Toggle(T("Esconder a prévia (a câmera continua)"), isOn: $cam.previaEscondida)
            Toggle(T("Espelho do texto (vidro)"), isOn: Binding(get: { tp.estado.espelho }, set: { _ in tp.alternarEspelho() }))
            Toggle(T("Fonte automática"), isOn: $tp.fonteAutomatica)
            Divider()
            Menu(T("Câmera")) {
                ForEach(cam.cameras, id: \.id) { c in
                    Button((c.id == cam.dono?.uniqueID ? "✓ " : "") + c.nome) { cam.trocarCamera(c.id) }
                }
            }
            .disabled(gravador.estado.ocupada)
            if !(tp.argumentosDeBancada) {
                Menu(T("Microfone")) {
                    Button((cam.microfoneEscolhido == nil ? "✓ " : "") + T("O padrão do sistema")) { cam.microfoneEscolhido = nil }
                    ForEach(cam.microfones, id: \.uniqueID) { m in
                        Button((m.uniqueID == cam.microfoneEscolhido ? "✓ " : "") + m.nome) { cam.microfoneEscolhido = m.uniqueID }
                    }
                }
                .disabled(cam.dono?.microfone.ligado == true)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
        .onAppear { cam.atualizarMicrofones() }
        .help(T("Ajustes desta tela: lado do texto, espelho, prévia, câmera e microfone"))
    }

    private func passo(_ rotulo: String, _ valor: String, _ menos: @escaping () -> Void,
                       _ mais: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(rotulo).font(.system(size: 11)).foregroundColor(Estilo.texto2)
            Button(action: menos) { Image(systemName: "minus") }
            Text(valor).font(.system(size: 11, design: .monospaced)).frame(minWidth: 34)
            Button(action: mais) { Image(systemName: "plus") }
        }
    }
}

/// **O botão do microfone** (R5): começa desligado; ligado é vermelho; recusado ou com falha diz por
/// quê na linha de avisos. Toque liga e desliga **de verdade** (a sessão do microfone abre e fecha).
struct BotaoDoMicrofone: View {
    @ObservedObject var cam: TelaComCamera
    let dono: DonoDaCamera

    var body: some View {
        Button { dono.alternarMicrofone() } label: {
            HStack(spacing: 5) {
                switch dono.microfone {
                case .pedindo: ProgressView().controlSize(.mini)
                case .ligado: Image(systemName: "mic.fill")
                case .desligado: Image(systemName: "mic.slash")
                case .recusado, .falhou: Image(systemName: "mic.slash.fill")
                }
                Text(dono.microfone.ligado ? T("Microfone ligado") : T("Microfone desligado"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(dono.microfone.ligado ? Estilo.noAr.opacity(0.85) : Color.white.opacity(0.12))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .disabled(!dono.montado)
        .help(dono.microfone.ligado ? T("Desligar o microfone (fecha de verdade)")
              : T("Ligar o microfone: o som vai junto da câmera, cru, sem tratamento"))
    }
}

/// **O botão Gravar/Parar**: parado, um círculo vermelho; gravando, vermelho com o tempo, o espaço
/// que sobra e, com o microfone desligado, "SEM SOM" por extenso (§8.8).
struct BotaoDeGravar: View {
    @ObservedObject var gravador: GravadorLocal
    let dono: DonoDaCamera?
    let tocar: () -> Void

    var body: some View {
        Button(action: tocar) {
            HStack(spacing: 6) {
                switch gravador.estado {
                case .parada:
                    Image(systemName: "record.circle").foregroundColor(Estilo.noAr)
                    Text(T("Gravar")).font(.system(size: 12, weight: .semibold))
                case .abrindo, .fechando:
                    ProgressView().controlSize(.mini)
                    Text(gravador.estado == .abrindo ? T("Começando…") : T("Fechando o arquivo…")).font(.system(size: 12))
                case .gravando(let desde):
                    Image(systemName: "stop.fill")
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(GravadorLocal.duracaoLegivel(ProcessInfo.processInfo.systemUptime - desde))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    if dono?.microfone.ligado != true {
                        Text(T("SEM SOM")).font(.system(size: 11, weight: .heavy))
                    }

                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(gravador.estado.gravando ? Estilo.noAr.opacity(0.85) : Color.white.opacity(0.12))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .disabled(dono?.montado != true || gravador.estado == .fechando)
        .help(gravador.estado.ocupada ? T("Parar a gravação (o arquivo fica na pasta de gravações)")
              : T("Gravar a câmera, sem o texto, na pasta de gravações (o microfone só se estiver ligado)"))
    }
}

/// **A prévia da câmera**: uma `AVCaptureVideoPreviewLayer` sobre a sessão do dono. Esconder é
/// `isHidden` (nada fecha); o espelho é da conexão da camada.
struct PreviaDaCamera: NSViewRepresentable {
    let dono: DonoDaCamera
    let espelhar: Bool
    let escondida: Bool

    func makeNSView(context: Context) -> VistaDaPrevia {
        let v = VistaDaPrevia()
        v.configurar(dono: dono, espelhar: espelhar)
        v.isHidden = escondida
        return v
    }

    func updateNSView(_ v: VistaDaPrevia, context: Context) {
        v.configurar(dono: dono, espelhar: espelhar)
        if v.isHidden != escondida { v.isHidden = escondida }
    }
}

final class VistaDaPrevia: NSView {
    private var camada: AVCaptureVideoPreviewLayer?
    private weak var dono: DonoDaCamera?
    private var espelhar = true
    private var ultimoRelato = ""
    private var relogio: Timer?
    private var quadrado: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        toolTip = TextosDosAjustes.notaDoToque + " " + T("⌥-clique trava ali.")
        // A conexão da camada só existe com a sessão rodando: o espelho é reaplicado a cada segundo
        // até pegar, e dito no diário quando muda.
        relogio = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.aplicarEspelho() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    deinit { relogio?.invalidate() }

    func configurar(dono novo: DonoDaCamera, espelhar e: Bool) {
        if dono !== novo {
            camada?.removeFromSuperlayer()
            let c = novo.novaCamadaDePrevia()
            c.frame = bounds
            layer?.addSublayer(c)
            camada = c
            dono = novo
            ultimoRelato = ""
        }
        espelhar = e
        aplicarEspelho()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        camada?.frame = bounds
        CATransaction.commit()
    }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            Registro.compartilhado.linha("APP PREVIA vista \(isHidden ? "escondida" : "à mostra") (isHidden)")
        }
    }

    // MARK: o clique na prévia (R9, `docs/controles-de-camera.md` §4.4)

    /// O clique que ativa a janela também conta: quem clica na prévia quer medir ali.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// **Clique = medir e focar no ponto; ⌥-clique = travar ali.** O ponto vai ao referencial do sensor
    /// pela própria camada (`captureDevicePointConverted(fromLayerPoint:)`), que trata o enquadramento e
    /// o espelho da prévia. O ponto não é guardado.
    override func mouseDown(with event: NSEvent) {
        guard let camada, let dono, !isHidden else { return super.mouseDown(with: event) }
        let naVista = convert(event.locationInWindow, from: nil)
        let naCamada = camada.convert(naVista, from: layer)
        let noSensor = camada.captureDevicePointConverted(fromLayerPoint: naCamada)
        let travar = event.modifierFlags.contains(.option)
        Registro.compartilhado.linha(String(format: "APP PREVIA clique: vista=%.0f,%.0f de %.0fx%.0f sensor=%.3f,%.3f espelhada=%@%@",
                                            naVista.x, naVista.y, bounds.width, bounds.height, noSensor.x, noSensor.y,
                                            camada.connection?.isVideoMirrored == true ? "sim" : "não",
                                            travar ? " ⌥" : ""))
        guard noSensor.x.isFinite, noSensor.y.isFinite else { return }
        if dono.cliqueNaPrevia(noSensor, travarAli: travar, origem: travar ? "⌥-clique" : "clique") {
            mostrarQuadrado(em: naVista)
        }
    }

    /// O quadrado de 64 pt por 1,5 s (§4.4).
    private func mostrarQuadrado(em p: CGPoint) {
        quadrado?.removeFromSuperlayer()
        let q = CALayer()
        q.frame = CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64)
        q.borderColor = NSColor(Estilo.aguardando).cgColor
        q.borderWidth = 1.5
        q.cornerRadius = 4
        layer?.addSublayer(q)
        quadrado = q
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak q] in
            q?.removeFromSuperlayer()
            if let self, self.quadrado === q { self.quadrado = nil }
        }
    }

    private func aplicarEspelho() {
        guard let camada else { return }
        let ficou = DonoDaCamera.aplicarEspelho(camada, espelhar: espelhar)
        let relato = "pedido=\(espelhar ? "ligado" : "desligado") espelhada=\(ficou.map { "\($0)" } ?? "sem conexão") automatico=false"
        if relato != ultimoRelato, ficou != nil {
            ultimoRelato = relato
            Registro.compartilhado.linha("APP PREVIA espelho aplicado: \(relato)")
        }
    }
}
