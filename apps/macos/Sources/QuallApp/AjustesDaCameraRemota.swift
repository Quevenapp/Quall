import AppKit
import QuallCaptureKit
import QuallIdiomaKit
import SwiftUI

/// **A janela "Ajustes da câmera" da câmera do outro lado** (R9b, `docs/controle-remoto-da-camera.md` §12,
/// receptor): a mesma janela do R9 (`JanelaDosAjustesDaCamera`), com as mesmas abas e as mesmas peças
/// (`PecasDaCamera`), desenhada **a partir das capacidades que chegaram** (`PlanoRemotoDoPainel`). Um iPhone
/// filmando mostra ISO, obturador, Kelvin e o foco manual aqui, mesmo que este Mac não tenha nenhum.
///
/// - Abre pela engrenagem da barra do vídeo recebido (`BarraDoVideo`), só com `pronto` ou `nao_permitido`.
/// - Marcada (`JanelasDeAjustes`, `.ajustesDaCameraRemota`): as teclas dela não tocam o teleprompter, e a
///   barra de menus a esconde junto da principal.
/// - Cada gesto pede só o campo mexido; nada é pedido ao abrir nem ao redesenhar (§5, "só de gesto").
struct JanelaDosAjustesDaCameraRemota: View {
    static let id = "quall.ajustes-da-camera.remota"
    @EnvironmentObject private var receptor: Receptor
    @State private var aba: AbaDosAjustes = .exposicao

    var body: some View {
        VStack(spacing: 0) {
            if let e = receptor.cameraRemota, let plano = PlanoRemotoDoPainel.de(e) {
                PainelRemotoDaCamera(plano: plano, aba: $aba,
                                     aoPedir: { receptor.pedirNaCameraRemota($0) },
                                     aoRestaurar: { receptor.restaurarCameraRemota() })
            } else {
                VStack(spacing: 10) {
                    Text(TextosDosAjustes.titulo).font(Estilo.titulo(20)).foregroundColor(Estilo.texto)
                    Text(T("O aparelho que filma não oferece os ajustes da câmera agora."))
                        .font(.system(size: 13)).foregroundColor(Estilo.texto2)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(width: PainelDosAjustesDaCamera.largura, height: 200)
            }
        }
        .background(Estilo.fundo)
        .navigationTitle(TextosDosAjustes.titulo)
        .background(JanelaEscura())
        .background(MarcaDaJanelaDeAjustes(tipo: .ajustesDaCameraRemota))
        .onAppear {
            Registro.compartilhado.linha("receptor: camera remota: a janela dos ajustes abriu "
                                         + "(situacao=\(receptor.cameraRemota?.situacao ?? "nenhuma"))")
        }
    }
}

/// **O painel da câmera do outro lado, só a vista** (R9 §4.3 com as capacidades remotas). Quatro abas no
/// alto, "Restaurar automático" no pé. Com `nao_permitido`, os valores à mostra e tudo apagado.
struct PainelRemotoDaCamera: View {
    let plano: PlanoRemotoDoPainel
    @Binding var aba: AbaDosAjustes
    let aoPedir: ([String: Any]) -> Void
    let aoRestaurar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(plano.nome)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
            // O alto: a permissão ou a recusa (§3.5), e a linha do que a câmera diz ter usado (R9 §3.6).
            Group {
                if let aviso = plano.aviso {
                    Label(aviso, systemImage: plano.vivo ? "exclamationmark.circle" : "lock.slash")
                        .foregroundColor(Estilo.aguardandoTexto)
                } else if let lido = plano.lido {
                    Text(lido).font(Estilo.mono(12)).foregroundColor(Estilo.texto2)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(2)
            .frame(minHeight: 18, alignment: .leading)
            .padding(.top, 2)

            Segmentado(titulo: T("Grupo"),
                       opcoes: AbaDosAjustes.allCases.map { ($0 == .isoEObturador ? plano.tituloDaAbaDoIso : $0.nome, $0) },
                       escolha: $aba)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 14) {
                switch aba {
                case .exposicao: abaDaExposicao
                case .isoEObturador: abaDoIso
                case .balanco: abaDoBalanco
                case .foco: abaDoFoco
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .padding(.top, 16)

            ForEach(plano.divergencias, id: \.self) { PecasDaCamera.linha($0, cor: Estilo.aguardandoTexto) }

            Divider().overlay(Estilo.contorno)
            HStack(spacing: 10) {
                Button(TextosDosAjustes.restaurar, action: aoRestaurar)
                    .buttonStyle(.quall(.secundario, altura: 32))
                    .disabled(!plano.vivo)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: PainelDosAjustesDaCamera.largura, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    // MARK: as abas

    @ViewBuilder private var abaDaExposicao: some View {
        PecasDaCamera.controle(T("Exposição"), disponivel: true, limite: plano.linhaDaExposicao) {
            opcoes(plano.exposicao, campo: "exposicao")
        }
        if let ev = plano.ev {
            deslizante(ev)
        } else {
            PecasDaCamera.controle(T("Compensação (EV)"), disponivel: false, limite: plano.linhaDoEv) { EmptyView() }
        }
        if let t = plano.travaExposicao { interruptor(t) }
        PecasDaCamera.controle(T("Anti-cintilação"), disponivel: plano.antiCintilacao.contains { $0.disponivel },
                               limite: plano.linhaDaAntiCintilacao) {
            opcoes(plano.antiCintilacao, campo: "antiCintilacao")
        }
    }

    @ViewBuilder private var abaDoIso: some View {
        if let l = plano.linhaDoIsoEObturador {
            PecasDaCamera.linha(l)
        } else if plano.passeParaManual {
            PecasDaCamera.linha(TextosDosAjustes.passeParaManual, cor: Estilo.texto2)
            Button(TextosDaCameraRemota.passarParaManual) { aoPedir(["exposicao": "manual"]) }
                .buttonStyle(.quall(.secundario, altura: 30))
                .disabled(!plano.exposicao.contains { $0.valor == "manual" && $0.disponivel })
        } else {
            if let iso = plano.iso { deslizante(iso) } else if let l = plano.linhaDoIso { PecasDaCamera.linha(l) }
            if let o = plano.obturador { deslizante(o) } else if let l = plano.linhaDoObturador { PecasDaCamera.linha(l) }
        }
    }

    @ViewBuilder private var abaDoBalanco: some View {
        let grade = plano.balanco
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { l in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { c in
                        if grade.indices.contains(l * 3 + c) {
                            let o = grade[l * 3 + c]
                            PecasDaCamera.opcao(o.rotulo, escolhida: o.escolhida, disponivel: o.disponivel, largura: 120) {
                                if !o.escolhida { aoPedir(["balanco": o.valor]) }
                            }
                        }
                    }
                }
            }
            ForEach(plano.limitesDoBalanco, id: \.self) { PecasDaCamera.linha($0) }
        }
        if let k = plano.kelvin { deslizante(k) }
        if let t = plano.travaBalanco { interruptor(t) }
    }

    @ViewBuilder private var abaDoFoco: some View {
        if let fixo = plano.linhaDoFocoFixo {
            PecasDaCamera.linha(fixo)
        } else {
            opcoes(plano.foco, campo: "foco")
            ForEach(plano.limitesDoFoco, id: \.self) { PecasDaCamera.linha($0) }
            if let p = plano.focoPosicao { deslizante(p) }
        }
        PecasDaCamera.linha(plano.notaDoToque, cor: plano.toqueDisponivel ? Estilo.texto2 : Estilo.texto3)
    }

    // MARK: as peças

    private func opcoes(_ lista: [OpcaoRemota], campo: String) -> some View {
        HStack(spacing: 6) {
            ForEach(lista, id: \.valor) { o in
                PecasDaCamera.opcao(o.rotulo, escolhida: o.escolhida, disponivel: o.disponivel) {
                    if !o.escolhida { aoPedir([campo: o.valor]) }
                }
            }
        }
    }

    private func interruptor(_ t: InterruptorRemoto) -> some View {
        PecasDaCamera.controle(t.titulo, disponivel: t.disponivel, limite: t.linha) {
            Interruptor(titulo: t.titulo, ligado: Binding(get: { t.ligado }, set: { aoPedir([t.campo: $0]) }), pequeno: true)
        }
    }

    private func deslizante(_ d: DeslizanteRemoto) -> some View {
        PecasDaCamera.controle(d.titulo, disponivel: d.disponivel, limite: d.linha) {
            HStack(spacing: 8) {
                Text(d.texto).font(Estilo.mono(12)).foregroundColor(d.disponivel ? Estilo.texto : Estilo.texto3)
                    .frame(minWidth: 64, alignment: .trailing)
                DeslizanteDeDegraus(quantos: d.degraus.count, indice: d.indice) { i in
                    aoPedir([d.campo: PedidoDoReceptor.valor(d, indice: i)])
                }
            }
        }
    }
}

/// O deslizante nativo (`Deslizante`) andando por degraus: o índice vira a fração, e a fração volta ao
/// degrau mais perto. Só chama `aoEscolher` quando o degrau muda (o núcleo junta a 15 por segundo).
struct DeslizanteDeDegraus: View {
    let quantos: Int
    let indice: Int
    let aoEscolher: (Int) -> Void

    var body: some View {
        Deslizante(valor: Binding(
            get: { quantos > 1 ? Float(indice) / Float(quantos - 1) : 0 },
            set: { v in
                guard quantos > 1 else { return }
                let i = Int((v * Float(quantos - 1)).rounded())
                if i != indice { aoEscolher(i) }
            }), largura: 170)
    }
}

/// **O clique na imagem recebida** (R9b, §3.4): com o painel remoto vivo e a câmera do outro lado com ponto
/// de interesse, um clique foca e mede ali, e o ⌥-clique trava (o toque longo do R9 §4.4). O clique na
/// tarja não manda nada. O quadrado de 64 pt mostra onde, por 1,5 s.
struct CliqueNaImagemRecebida: View {
    let video: CGSize
    let aoTocar: (CGPoint, Bool) -> Void
    @State private var quadrado: CGPoint?

    var body: some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { local in
                    guard let p = PontoNoQuadro.doClique(local, vista: g.size, video: video) else { return }
                    aoTocar(p, NSEvent.modifierFlags.contains(.option))
                    quadrado = local
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if quadrado == local { quadrado = nil }
                    }
                }
                .overlay {
                    if let q = quadrado {
                        Rectangle().stroke(Estilo.aguardando, lineWidth: 1.5)
                            .frame(width: 64, height: 64)
                            .position(q)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
