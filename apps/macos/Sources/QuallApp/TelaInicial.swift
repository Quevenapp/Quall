// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import AppKit
import QuallCaptureKit
import QuallIdiomaKit
import SwiftUI

/// **O painel Espelhar** (`docs/telas-estudio.md` §7.1): "O que vamos espelhar?", os ladrilhos das
/// origens, o som, os avisos, e no pé a rede e o botão Espelhar.
///
/// Três coisas e quase nada mais. Se uma peça não serve ao caminho "abrir → escolher → espelhar", ela
/// não mora aqui — `docs/fluxo-de-uso.md` fecha essa porta de propósito. Desde 30/09 os outros papéis
/// (Exibir, o teleprompter) moram na barra lateral, e o que não é a escolha da origem foi para os
/// Ajustes: "Sair pela rede", "Escala da tela estendida" e "60 fps na tela estendida" (§7.1).
///
/// # A origem é escolhida antes do PIN, e é fixa pela sessão
///
/// Não há renegociação no protocolo: trocar de origem significa encerrar e começar de novo. Por
/// isso os ladrilhos estão **aqui**, antes de qualquer coisa, e não como um menu durante a
/// transmissão — oferecer uma troca que não existe seria pior do que não oferecer.
///
/// # O caso do desktop que o iOS não tem
///
/// Mais de um monitor. Cada monitor é um ladrilho, com o nome que o sistema já dá a ele ("Tela
/// interna", "DELL U2415") — ver `CatalogoDeFontes`. Com mais de seis origens, três colunas (§11.4).
///
/// Esta vista só adapta o `Emissor` ao `PainelEspelhar`, que recebe valores simples (e é o que os
/// retratos de bancada desenham).
struct TelaInicial: View {
    @EnvironmentObject private var emissor: Emissor
    @EnvironmentObject private var teleprompter: Teleprompter
    @Environment(\.abrirAjustes) private var abrirAjustes
    /// As redes lidas agora (ao aparecer, ao voltar para o app e no Atualizar), e não as do último
    /// catálogo: a rede pode mudar com o app aberto, e a linha do pé tem de dizer o endereço que a
    /// Espera vai mostrar (`Enderecos.paraDigitar` usa a primeira desta mesma lista).
    @State private var redesAgora: [Enderecos.Interface]?

    var body: some View {
        PainelEspelhar(
            fontes: emissor.fontes.map(\.naTela),
            escolhida: emissor.fonteEscolhida?.id,
            carregando: emissor.carregandoFontes && emissor.fontes.isEmpty,
            podeAtualizar: !emissor.carregandoFontes,
            mostrarSom: emissor.fonteEscolhida?.ehTela == true,
            comSom: $emissor.comSom,
            somDesligado: emissor.fase != .inicial,
            avisos: avisos,
            rede: linhaDaRede,
            podeEspelhar: emissor.fonteEscolhida != nil,
            aoEscolher: { id in emissor.fonteEscolhida = emissor.fontes.first { $0.id == id } },
            aoAtualizar: { emissor.atualizarFontes(); redesAgora = Enderecos.interfaces() },
            aoEspelhar: { emissor.espelhar() },
            aoAbrirAjustes: abrirAjustes)
        // Aberto para ver (`--exibir`) ou para o teleprompter (`--teleprompter`), o app não monta o
        // catálogo sozinho: montar pede Gravação de Tela e Câmera. O botão Atualizar continua valendo.
        .onAppear {
            redesAgora = Enderecos.interfaces()
            if emissor.fontes.isEmpty && !emissor.argumentos.semEmissao { emissor.atualizarFontes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            redesAgora = Enderecos.interfaces()
        }
    }

    /// Os avisos do painel, na ordem em que pesam: o bloqueio de permissão (sem ele nada sai), o
    /// conselho do emissor, e o teleprompter que não abriu — antes de 30/09 essa frase ia para
    /// `teleprompter.mensagem` e nenhuma tela a mostrava (`Teleprompter.abrirPrompter`/`abrirControle`).
    private var avisos: [ItemDeAviso] {
        var a: [ItemDeAviso] = []
        if let t = emissor.telaBloqueada {
            a.append(ItemDeAviso(id: "tela", texto: retraduzido(t), tipo: .ambar, acao: T("Abrir os Ajustes do Sistema"),
                                 aoTocar: { AjustesDoSistema.abrir(.gravacaoDeTela) }))
        }
        if let c = emissor.cameraBloqueada {
            a.append(ItemDeAviso(id: "camera", texto: retraduzido(c), tipo: .ambar, acao: T("Abrir os Ajustes do Sistema"),
                                 aoTocar: { AjustesDoSistema.abrir(.camera) }))
        }
        if !emissor.conselho.isEmpty {
            a.append(ItemDeAviso(id: "conselho", texto: retraduzido(emissor.conselho), tipo: .ambar,
                                 acao: emissor.ofereceDesparear ? T("Esquecer aparelhos pareados") : nil,
                                 aoTocar: { emissor.esquecerPares() }))
        }
        if teleprompter.tela == .fechada, !teleprompter.mensagem.isEmpty {
            a.append(ItemDeAviso(id: "teleprompter", texto: retraduzido(teleprompter.mensagem), tipo: .vermelho,
                                 aoFechar: { teleprompter.dispensarMensagem() }))
        }
        return a
    }

    /// "Rede automática · 192.168.57.3", ou a rede escolhida nos Ajustes.
    private var linhaDaRede: PainelEspelhar.LinhaDaRede {
        let redes = redesAgora ?? emissor.redes
        if let bsd = emissor.redeEscolhida {
            guard let r = redes.first(where: { $0.bsd == bsd }) else {
                return .init(ok: false, rotulo: T("%@ — sem endereço agora", bsd), ip: nil)
            }
            let prefixo = r.rotulo.hasSuffix(r.ip) ? String(r.rotulo.dropLast(r.ip.count)) : r.rotulo + " · "
            return .init(ok: true, rotulo: prefixo, ip: r.ip)
        }
        guard let ip = redes.first?.ip else { return .init(ok: false, rotulo: T("Sem rede"), ip: nil) }
        return .init(ok: true, rotulo: T("Rede automática · "), ip: ip)
    }
}

extension FonteDeCaptura {
    /// O ladrilho desta origem: ícone, nome e o detalhe da §7.1 ("L × A", "Câmera" ou "Um monitor novo
    /// para cada aparelho").
    var naTela: PainelEspelhar.Fonte {
        switch tipo {
        case .tela(let id):
            return .init(id: self.id, icone: CGDisplayIsBuiltin(id) != 0 ? "laptopcomputer" : "display",
                         nome: nome, detalhe: detalhe, detalheMono: true)
        #if QUALL_TELA_ESTENDIDA_FUTURA
        case .telaEstendida:
            // O nome no idioma da vez, e não o do catálogo: o seletor PT | EN mora nesta tela.
            return .init(id: self.id, icone: "display.2", nome: T("Tela estendida"),
                         detalhe: T("Um monitor novo para cada aparelho"), detalheMono: false)
        #endif
        case .camera:
            return .init(id: self.id, icone: "web.camera", nome: nome, detalhe: T("Câmera"), detalheMono: false)
        }
    }
}

/// Os painéis de privacidade dos Ajustes do Sistema (§11.1: "Abrir os Ajustes do Sistema" no Mac).
enum AjustesDoSistema {
    enum Painel: String {
        case gravacaoDeTela = "Privacy_ScreenCapture"
        case camera = "Privacy_Camera"
    }

    static func abrir(_ painel: Painel) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(painel.rawValue)")
        else { return }
        Registro.compartilhado.linha("tela: abrindo os Ajustes do Sistema (\(painel.rawValue))")
        NSWorkspace.shared.open(url)
    }
}

/// **O painel Espelhar**, só a vista (§7.1). Recebe valores simples e devolve os toques.
struct PainelEspelhar: View {
    struct Fonte: Identifiable, Equatable {
        let id: String
        let icone: String
        let nome: String
        let detalhe: String
        let detalheMono: Bool
    }

    struct LinhaDaRede: Equatable {
        let ok: Bool
        let rotulo: String
        let ip: String?
    }

    let fontes: [Fonte]
    let escolhida: String?
    let carregando: Bool
    let podeAtualizar: Bool
    let mostrarSom: Bool
    @Binding var comSom: Bool
    let somDesligado: Bool
    let avisos: [ItemDeAviso]
    let rede: LinhaDaRede
    let podeEspelhar: Bool
    let aoEscolher: (String) -> Void
    let aoAtualizar: () -> Void
    let aoEspelhar: () -> Void
    let aoAbrirAjustes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(T("O que vamos espelhar?"))
                        .font(Estilo.titulo(28))
                        .foregroundColor(Estilo.texto)
                    Text(T("Uma tela ou uma câmera. Quem exibe escolhe este Mac na lista."))
                        .font(.system(size: 14))
                        .foregroundColor(Estilo.texto2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // O seletor PT | EN mora aqui, no canto de cima da tela inicial (`docs/traducao.md`).
                SeletorDeIdioma()
                    .padding(.top, 5)
                BotaoRedondo(icone: "arrow.clockwise", rotulo: T("Atualizar"), acao: aoAtualizar)
                    .disabled(!podeAtualizar)
            }
            .padding(.bottom, 20)

            if carregando {
                HStack(spacing: 10) {
                    Carregando()
                    Text(T("Procurando telas e câmeras…")).font(.system(size: 14)).foregroundColor(Estilo.texto2)
                }
                .padding(.vertical, 16)
            } else if fontes.isEmpty {
                Text(T("Nada para transmitir ainda."))
                    .font(.system(size: 14))
                    .foregroundColor(Estilo.texto2)
                    .padding(.vertical, 16)
            } else {
                grade
            }

            if mostrarSom {
                linhaDoSom.padding(.top, 12)
            }

            if !avisos.isEmpty {
                ListaDeAvisos(itens: avisos).padding(.top, 12)
            }

            Spacer(minLength: 16)

            HStack(spacing: 14) {
                Button(action: aoAbrirAjustes) {
                    HStack(spacing: 8) {
                        Circle().fill(rede.ok ? Estilo.conectado : Estilo.aguardando).frame(width: 8, height: 8)
                        (Text(rede.rotulo) + Text(rede.ip ?? "").font(Estilo.mono(13)))
                            .font(.system(size: 13))
                            .foregroundColor(rede.ok ? Estilo.texto2 : Estilo.aguardandoTexto)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(EstiloApertado())
                .help(T("Por qual rede o vídeo sai: nos Ajustes"))
                Spacer(minLength: 0)
                Button(action: aoEspelhar) {
                    RotuloDeBotao(T("Espelhar"), icone: "rectangle.on.rectangle", atalho: "↩")
                }
                .buttonStyle(.quall(.principal))
                .keyboardShortcut(.defaultAction)
                .disabled(!podeEspelhar)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrilhoDeFundo())
    }

    /// Duas colunas; três com mais de seis origens (§11.4). Passou de três fileiras, rola.
    private var grade: some View {
        let colunas = fontes.count > 6 ? 3 : 2
        let fileiras = stride(from: 0, to: fontes.count, by: colunas).map { Array(fontes[$0..<min($0 + colunas, fontes.count)]) }
        return PilhaQueRola(quantas: fileiras.count, visiveis: 3, alturaDaLinha: 60, espaco: 10) {
            VStack(spacing: 10) {
                ForEach(Array(fileiras.enumerated()), id: \.offset) { _, fileira in
                    HStack(spacing: 10) {
                        ForEach(fileira) { f in
                            Ladrilho(icone: f.icone, titulo: f.nome, detalhe: f.detalhe, detalheMono: f.detalheMono,
                                     escolhido: f.id == escolhida) { aoEscolher(f.id) }
                        }
                        ForEach(0..<(colunas - fileira.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                    // A fileira inteira na altura do ladrilho mais alto (nome em duas linhas).
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// **O som da tela, e ele se paga** (antes "Transmitir também o som"). Só com origem de tela; a
    /// câmera tem o microfone, na espera. **A legenda diz o escopo, não vende o recurso**: o áudio de
    /// sistema do macOS é a mistura da máquina inteira, mais larga que o monitor escolhido acima.
    private var linhaDoSom: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Mandar o som junto"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Estilo.texto)
                Text(T("O som que o Mac inteiro está tocando. O microfone fica de fora."))
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Interruptor(titulo: T("Mandar o som junto"), ligado: $comSom)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Estilo.superficie))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Estilo.contorno, lineWidth: 1))
        .disabled(somDesligado)
    }
}
