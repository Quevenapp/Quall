import QuallIdiomaKit
import SwiftUI

/// Os itens da barra lateral (`docs/telas-estudio.md` §7): os dois papéis de vídeo e, sob o rótulo
/// TELEPROMPTER, os três do teleprompter. A mesma lista, na mesma ordem, da janela do Windows (que
/// junta os três num item só).
enum ItemDaBarra: String, CaseIterable, Identifiable {
    case espelhar, exibir, mostrarOTexto, controlar, textoComCamera

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .espelhar: return T("Espelhar")
        case .exibir: return T("Exibir")
        case .mostrarOTexto: return T("Mostrar o texto")
        case .controlar: return T("Controlar")
        case .textoComCamera: return T("Texto com a câmera")
        }
    }

    var icone: String {
        switch self {
        case .espelhar: return "rectangle.on.rectangle"
        case .exibir: return "play.rectangle"
        case .mostrarOTexto: return "text.alignleft"
        case .controlar: return "slider.horizontal.3"
        case .textoComCamera: return "person.crop.square"
        }
    }

    var doTeleprompter: Bool { self == .mostrarOTexto || self == .controlar || self == .textoComCamera }
}

/// **A sessão de pé**, do jeito que a barra a mostra: o item dela com a bolinha e a palavra do
/// estado, e a nota que explica por que os outros estão apagados.
struct SessaoNaBarra: Equatable {
    let item: ItemDaBarra
    let luz: Luz
    let estado: String
    let nota: String
}

/// **A barra lateral de 230** (§7): a marca, os itens, e no pé o nome deste Mac com a engrenagem.
/// Com sessão de pé, os outros itens ficam apagados e sem clique, e o pé vira a nota "Um papel por
/// vez". Vista de apresentação: recebe valores simples; `RaizDaJanela` adapta os modelos a ela.
struct BarraLateral: View {
    static let largura: CGFloat = 230

    let escolhido: ItemDaBarra
    let sessao: SessaoNaBarra?
    let nome: String
    /// Itens sem clique mesmo sem sessão (o teleprompter ainda fechando a sessão anterior, ou aberto
    /// na janela do controle).
    var desligados: Set<ItemDaBarra> = []
    let aoEscolher: (ItemDaBarra) -> Void
    let aoAbrirAjustes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarcaDoQuall(tamanho: 24)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                linha(.espelhar)
                linha(.exibir)
            }

            RotuloDeSecao(T("Teleprompter"))
                .foregroundColor(sessao == nil ? Estilo.texto3 : Estilo.itemApagado)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                linha(.mostrarOTexto)
                linha(.controlar)
                linha(.textoComCamera)
            }

            Spacer(minLength: 12)

            if let sessao {
                Text(sessao.nota)
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.texto3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            } else {
                pe
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: BarraLateral.largura)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Estilo.barraLateral)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
        }
    }

    private var pe: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Este Mac aparece como"))
                    .font(.system(size: 11))
                    .foregroundColor(Estilo.texto3)
                // Até duas linhas: na primeira janela de verdade (30/09) "MacBook Air de Pessoa Exemplo" saiu
                // "MacBoo…de Pessoa Exemplo" numa linha só, ao lado da engrenagem.
                Text(nome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Estilo.texto)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            BotaoRedondo(icone: "gearshape", rotulo: T("Ajustes"), acao: aoAbrirAjustes)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(rgb: 0x1A1A22)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func linha(_ item: ItemDaBarra) -> some View {
        if let sessao, sessao.item == item {
            linhaDaSessao(item, sessao)
        } else {
            let apagado = sessao != nil || desligados.contains(item)
            let marcado = sessao == nil && escolhido == item
            Button { aoEscolher(item) } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.icone)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 18)
                        .foregroundColor(apagado ? Estilo.itemApagado : (marcado ? Estilo.iconeEscolhido : Estilo.texto2))
                    Text(item.titulo)
                        .font(.system(size: 13, weight: marcado ? .semibold : .regular))
                        .foregroundColor(apagado ? Estilo.itemApagado : (marcado ? .white : Estilo.itemComum))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(marcado ? Estilo.itemEscolhido : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(apagado)
            .accessibilityAddTraits(marcado ? .isSelected : [])
        }
    }

    private func linhaDaSessao(_ item: ItemDaBarra, _ s: SessaoNaBarra) -> some View {
        let clara: Color = {
            switch s.luz {
            case .noAr: return Color(rgb: 0xFFD2CE)
            case .aguardando: return Color(rgb: 0xFFE3B3)
            case .conectado: return Color(rgb: 0xC9F5D1)
            }
        }()
        return HStack(spacing: 10) {
            Circle().fill(s.luz.cor)
                .frame(width: 8, height: 8)
                .background(Circle().fill(s.luz.cor.opacity(0.25)).frame(width: 14, height: 14))
                .frame(width: 18)
            Text(item.titulo)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(clara)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(s.estado)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(clara.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(s.luz.cor.opacity(s.luz == .noAr ? 0.16 : 0.14)))
        .accessibilityElement(children: .combine)
    }
}
