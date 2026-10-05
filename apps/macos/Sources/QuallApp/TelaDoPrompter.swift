import QuallIdiomaKit
import QuallTeleprompterKit
import SwiftUI

/// **A tela do prompter**: o roteiro rolando, e o que o operador precisa por cima dele.
///
/// Duas camadas, com regras de espelho diferentes, de propósito:
///
/// - **o palco** — o texto, a linha de leitura, o aviso de controle sumido e o "sem roteiro" — é o
///   que quem lê vê pelo vidro. Com o espelho ligado, **tudo nele** sai espelhado, inclusive o aviso:
///   quem está lendo pelo reflexo precisa conseguir lê-lo;
/// - **o operador** — o painel do PIN e a barra de controles — é para quem está no teclado do Mac, e
///   nunca espelha. Em tela cheia a barra some depois de 3 s sem mexer o mouse, e volta com ele.
struct TelaDoPrompter: View {
    @EnvironmentObject private var tp: Teleprompter
    @State private var ultimoMovimento = Date()
    @State private var agora = Date()
    private let relogio = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var barraVisivel: Bool {
        !tp.emTelaCheia || agora.timeIntervalSince(ultimoMovimento) < 3 || tp.fase != .conectado
    }

    private var esperando: Bool {
        tp.fase == .abrindo || tp.fase == .semPar || tp.fase == .formulario
    }

    var body: some View {
        ZStack {
            VistaDoTextoRepresentavel(modelo: tp)

            palco
                .scaleEffect(x: tp.estado.espelho ? -1 : 1, y: 1)
                .allowsHitTesting(false)

            if esperando && tp.mostrarPainelDoPin {
                painelDoPin
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if barraVisivel {
                barra
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        // **1040 de mínimo, e não 760**: a barra de baixo, numa linha, pede ~980. Na primeira janela
        // de verdade (30/09, 900 de largura, o tamanho que o estúdio deixou) ela saiu cortada dos
        // dois lados ("argem", o "S" final) e o cartão do PIN perdeu o X — o conteúdo mais largo
        // que a janela fica centralizado e corta. Com o mínimo aqui, a janela cresce ao abrir o
        // prompter (`windowResizability(.contentSize)`).
        .frame(minWidth: 1040, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        .onContinuousHover { _ in ultimoMovimento = Date() }
        .onReceive(relogio) { agora = $0 }
        .animation(.easeInOut(duration: 0.2), value: barraVisivel)
        .sheet(isPresented: $tp.editorAberto) {
            EditorDoRoteiro().environmentObject(tp)
        }
    }

    // MARK: - o palco (espelha com o texto)

    private var palco: some View {
        ZStack {
            if tp.avisos.parSumido && tp.jaHouveSessao {
                VStack(spacing: 4) {
                    Text(T("Controle sumido"))
                        .font(.system(size: 22, weight: .bold))
                    Text(T("O texto continua como estava. Esperando o controle voltar."))
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Estilo.aguardando)
                .cornerRadius(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
            }
            if tp.texto.isEmpty {
                Text(T("Sem roteiro.\nToque em Editar ou cole um texto — aqui ou no controle."))
                    .font(.system(size: 24, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.55))
            }
            if tp.avisos.atualizeOApp {
                Text(T("O controle fala outra versão do teleprompter: atualize o app nos dois aparelhos."))
                    .font(.headline)
                    .foregroundColor(Estilo.aguardandoTexto)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 110)
            }
        }
    }

    // MARK: - o operador (nunca espelha)

    private var painelDoPin: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tp.fase == .semPar ? Estilo.aguardando : (tp.fase == .formulario ? Estilo.noAr : Estilo.aguardandoTexto))
                    .frame(width: 9, height: 9)
                Text(tp.fase == .semPar ? T("Controle sumido — esperando a volta")
                     : (tp.fase == .formulario ? T("A espera parou") : T("Esperando o controle")))
                    .font(.headline)
                Spacer()
                Button {
                    tp.mostrarPainelDoPin = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Estilo.texto3)
                }
                .buttonStyle(.plain)
                .help(T("Esconder (o PIN continua valendo)"))
            }
            if tp.fase != .formulario {
                // O QR que ficava à direita saiu em 24/09/2026 (decisão do Pessoa Exemplo): o endereço ocupa a
                // largura e sobe de 17 para 26 pt, para ser lido de longe e digitado no controle.
                VStack(alignment: .leading, spacing: 6) {
                    Text("PIN").font(.caption2).fontWeight(.semibold).foregroundColor(Estilo.texto2)
                    Text(Estilo.pinEspacado(tp.pin))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(Estilo.pinFalado(tp.pin))
                    Text(T("ENDEREÇO")).font(.caption2).fontWeight(.semibold).foregroundColor(Estilo.texto2)
                        .padding(.top, 4)
                    Text(tp.endereco ?? T("sem rede"))
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                        .foregroundColor(tp.endereco == nil ? Estilo.aguardandoTexto : Estilo.texto)
                    Text(tp.anunciandoPorMDNS
                         ? T("Aparecendo na lista dos outros aparelhos como %@.", tp.nome)
                         : T("Sem anúncio na rede — digite o endereço no controle."))
                        .font(.caption)
                        .foregroundColor(Estilo.texto2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(T("No outro aparelho: Quall Studio → Teleprompter → Controlar."))
                    .font(.caption)
                    .foregroundColor(Estilo.texto2)
            }
            if !tp.mensagem.isEmpty {
                Text(tp.mensagem)
                    .font(.footnote)
                    .foregroundColor(Estilo.aguardandoTexto)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tp.fase == .formulario {
                Button(T("Esperar de novo")) { tp.esperarPeloControle() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Estilo.superficie.opacity(0.96))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Estilo.contorno, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var barra: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                estadoDaLigacao
                Spacer(minLength: 8)
                Button { tp.saltar(0) } label: { Image(systemName: "backward.end.fill") }
                    .help(T("Voltar ao começo (Home ou 0)"))
                Button { tp.pular(-0.05) } label: { Image(systemName: "backward.fill") }
                    .help(T("Pular 5% para trás (← pula 2%, ⇧← 10%)"))
                Button { tp.tocarOuPausar() } label: {
                    Image(systemName: tp.estado.rolando ? "pause.fill" : "play.fill")
                        .frame(width: 34)
                }
                .buttonStyle(.borderedProminent)
                .help(T("Tocar ou pausar (espaço)"))
                Button { tp.pular(0.05) } label: { Image(systemName: "forward.fill") }
                    .help(T("Pular 5% para a frente (→ pula 2%, ⇧→ 10%)"))
                Text(String(format: "%.0f%%", tp.estado.posicao * 100))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 42)
                Spacer(minLength: 8)
                passo(T("Velocidade"), valor: String(format: "%.2f", tp.estado.velocidade),
                      menos: { tp.mudarVelocidade(-0.1) }, mais: { tp.mudarVelocidade(0.1) })
                passo(T("Fonte"), valor: String(format: "%.0f", tp.estado.fonte),
                      menos: { tp.definirFonte(tp.estado.fonte - 4) }, mais: { tp.definirFonte(tp.estado.fonte + 4) })
            }
            HStack(spacing: 14) {
                deslizante(T("Margem"), valor: tp.estado.margem, faixa: EstadoDoTeleprompter.faixaDaMargem) {
                    tp.definirMargem($0)
                }
                deslizante(T("Linha de leitura"), valor: tp.estado.linhaDeLeitura, faixa: EstadoDoTeleprompter.faixaDaLinha) {
                    tp.definirLinhaDeLeitura($0)
                }
                Toggle(T("Espelho"), isOn: Binding(get: { tp.estado.espelho }, set: { _ in tp.alternarEspelho() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle(isOn: $tp.fonteAutomatica) { Text(T("Fonte automática")).lineLimit(1).fixedSize() }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(T("A maior fonte com pelo menos duas palavras por linha. Arraste as setas do alto para enquadrar o texto."))
                if !tp.avisoDaFonte.isEmpty {
                    Text(tp.avisoDaFonte).font(.caption).foregroundColor(Estilo.aguardandoTexto)
                }
                Spacer(minLength: 4)
                Button(T("Editar…")) { tp.abrirEditor() }
                Button(T("Colar")) { tp.abrirEditor(comAreaDeTransferencia: true) }
                    .help(T("Abre o editor com o texto da área de transferência"))
                if esperando && !tp.mostrarPainelDoPin {
                    Button("PIN") { tp.mostrarPainelDoPin = true }
                }
                Button { tp.alternarTelaCheia() } label: {
                    Image(systemName: tp.emTelaCheia ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(T("Tela cheia (F)"))
                Button(tp.fase == .encerrando ? T("Saindo…") : T("Sair")) { tp.sair() }
                    .disabled(tp.fase == .encerrando)
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(Estilo.superficie.opacity(0.94))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Estilo.contorno, lineWidth: 1))
        .padding(12)
        .environment(\.colorScheme, .dark)
    }

    private var estadoDaLigacao: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tp.fase == .conectado && !tp.avisos.parSumido ? Estilo.conectado : Estilo.aguardando)
                .frame(width: 8, height: 8)
            Text(tp.fase == .conectado
                 ? (tp.avisos.parSumido ? T("%@ não responde", tp.par) : T("Controlado por %@", tp.par))
                 : (tp.fase == .semPar ? T("Controle sumido") : (tp.fase == .encerrando ? T("Encerrando…") : T("Sem controle"))))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    private func passo(_ rotulo: String, valor: String, menos: @escaping () -> Void,
                       mais: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(rotulo).font(.system(size: 11)).foregroundColor(Estilo.texto2)
            Button(action: menos) { Image(systemName: "minus") }
            Text(valor).font(.system(size: 12, design: .monospaced)).frame(minWidth: 38)
            Button(action: mais) { Image(systemName: "plus") }
        }
    }

    private func deslizante(_ rotulo: String, valor: Double, faixa: ClosedRange<Double>,
                            mudar: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            // O rótulo não encolhe: na primeira captura da janela, com 900 pt de largura, "Margem"
            // tinha sumido espremido pelo resto da barra.
            Text(rotulo).font(.system(size: 11)).foregroundColor(Estilo.texto2)
                .fixedSize()
            Slider(value: Binding(get: { valor }, set: { mudar($0) }), in: faixa)
                .frame(minWidth: 70, idealWidth: 110, maxWidth: 120)
            Text(String(format: "%.0f%%", valor * 100))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 34)
        }
    }
}

/// **O editor do roteiro**, dos dois papéis. `set_text` só no Confirmar (§6); o texto que chega
/// do outro lado com o editor aberto segue a regra de `RascunhoDoTexto`.
struct EditorDoRoteiro: View {
    @EnvironmentObject private var tp: Teleprompter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(T("Roteiro")).font(.title2.weight(.semibold))
                Spacer()
                let bytes = tp.rascunho.bytes
                Text(T("%@ de %@ bytes", bytes.formatted(), Teleprompter.tetoDoTexto.formatted()))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(bytes > Teleprompter.tetoDoTexto ? Estilo.perigoTexto : Estilo.texto2)
            }

            if let novo = tp.rascunho.textoNovoDoOutroLado {
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("O texto mudou no outro aparelho enquanto você editava."))
                        .font(.headline)
                    Text(T("O texto novo tem %@ bytes e começa com "
                         + "“%@”. "
                         + "Se você confirmar o seu, ele substitui o novo nos dois aparelhos — vale o último que mudou.",
                           novo.utf8.count.formatted(), String(novo.prefix(80)).replacingOccurrences(of: "\n", with: " ")))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(T("Usar o texto novo")) { tp.usarOTextoNovo() }
                            .help(T("O seu rascunho vai para a área de transferência"))
                        Button(T("Manter o meu")) { tp.manterOMeu() }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Estilo.aguardando.opacity(0.18))
                .cornerRadius(10)
            } else if tp.rascunho.atualizadoPeloOutroLado && !tp.rascunho.alterado {
                Text(T("O texto foi atualizado pelo outro aparelho."))
                    .font(.footnote)
                    .foregroundColor(Estilo.texto2)
            }

            TextEditor(text: $tp.rascunho.rascunho)
                .font(.system(size: 15))
                .frame(minWidth: 620, minHeight: 380)
                .border(Estilo.bordaDeCampo)

            if !tp.mensagemDoEditor.isEmpty {
                Text(tp.mensagemDoEditor)
                    .font(.footnote)
                    .foregroundColor(Estilo.aguardandoTexto)
            }

            HStack {
                Button(T("Colar tudo da área de transferência")) { tp.colarNoEditor() }
                Spacer()
                Button(T("Cancelar")) { tp.cancelarEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(T("Confirmar")) { tp.confirmarEditor() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(tp.rascunho.bytes > Teleprompter.tetoDoTexto)
            }
            Text(T("⌘↩ confirma. O texto só vai para o outro aparelho ao confirmar."))
                .font(.caption2)
                .foregroundColor(Estilo.texto3)
        }
        .padding(20)
        .background(Estilo.fundo)
    }
}
