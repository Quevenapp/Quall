import SwiftUI
import UIKit

/// **O botão do microfone** de todo emissor de câmera (R5 fase 2, `docs/teleprompter-com-camera.md`
/// §4.2 e §10): a "Teleprompter com câmera" (compacto). A `TelaDaCamera` comum usou o largo até
/// 30/09/2026; desde então ela tem o controle redondo com legenda (`ControlesDaTelaDaCamera`,
/// `docs/telas-estudio.md` §6.5), com o mesmo estado e as mesmas frases na acessibilidade.
///
/// Começa **desligado** em toda abertura de tela. O toque liga a captura de verdade (o ponto
/// laranja do iOS acende) e o seguinte a fecha (o ponto apaga): não é mudo por software. A permissão
/// é pedida no **primeiro toque**, nunca ao abrir a tela. Negada, o botão diz por quê, e a tela
/// oferece os Ajustes quando eles resolvem.
///
/// Só fica ativo com a câmera montada (`DonoDaCaptura.montado`): antes disso não há captura onde
/// pôr a entrada de áudio.
struct BotaoDoMicrofone: View {
    @ObservedObject var dono: DonoDaCaptura
    /// Compacto: só o ícone (a linha de estado da tela R5). Largo: ícone e frase (a tela comum).
    var compacto = false

    var body: some View {
        Button(action: { dono.alternarMicrofone() }) {
            if compacto {
                Image(systemName: simbolo)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 44)
                    .background(fundo)
                    .cornerRadius(9)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: simbolo).font(.body.weight(.semibold))
                    Text(frase).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(fundo)
                .cornerRadius(22)
            }
        }
        .buttonStyle(.plain)
        .disabled(!dono.montado)
        .opacity(dono.montado ? 1 : 0.45)
        // `.pedindo` também desliga no toque (`alternarMicrofone`).
        .accessibilityLabel(dono.microfone == .ligado || dono.microfone == .pedindo
                            ? tr("Desligar o microfone") : tr("Ligar o microfone"))
        .accessibilityValue(frase)
    }

    private var simbolo: String {
        switch dono.microfone {
        case .ligado: return "mic.fill"
        case .pedindo: return "mic"
        case .recusado, .falhou: return "mic.slash.fill"
        case .desligado: return "mic.slash"
        }
    }

    /// Ligado é vermelho, como o "no ar" de uma filmadora: quem fala precisa ver que está sendo ouvido.
    private var fundo: Color {
        switch dono.microfone {
        case .ligado: return Estilo.noAr.opacity(0.85)
        case .recusado, .falhou: return Estilo.aguardando.opacity(0.55)
        default: return Color.white.opacity(0.14)
        }
    }

    private var frase: String {
        switch dono.microfone {
        case .desligado: return dono.montado ? tr("Microfone desligado") : tr("Microfone (depois da câmera)")
        case .pedindo: return tr("Ligando o microfone…")
        case .ligado: return tr("Microfone ligado")
        case .recusado: return tr("Sem acesso ao microfone")
        case .falhou: return tr("O microfone não abriu")
        }
    }
}

/// O porquê do microfone não estar ligado, quando há um: a permissão negada ou a falha ao abrir.
extension EstadoDoMicrofone {
    var aviso: (texto: String, podeAbrirAjustes: Bool)? {
        switch self {
        case let .recusado(motivo, ajustes): return (motivo, ajustes)
        case let .falhou(motivo): return (motivo, false)
        default: return nil
        }
    }
}
