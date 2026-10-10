import SwiftUI
import AVFoundation
import UIKit

// MARK: - O toque na prévia (§4.4)

/// **A zona de toque da prévia**: um toque foca e mede, um toque longo faz o mesmo e trava. O ponto
/// vai ao sensor por `captureDevicePointConverted(fromLayerPoint:)` da camada de prévia do dono, que
/// já trata espelho e rotação (§4.4: o referencial é o do sensor, e não o da imagem que vai ao ar). O
/// quadrado de 64 pt aparece por 1,5 s onde o dedo tocou, e a pílula enquanto as travas do toque
/// longo estiverem de pé.
///
/// Gestos do UIKit, e não do SwiftUI: no iOS 15 o `onTapGesture` não dá o ponto, e o ponto na camada
/// é o que importa. Quem usa põe a zona onde a prévia está à vista e nada de botão por cima.
struct ZonaDeToqueDaPrevia: View {
    let dono: DonoDaCaptura
    @ObservedObject var controles: ControlesDaCamera
    /// Onde a pílula fica, na zona: no alto, ou embaixo (na R5 com a prévia embaixo, perto da borda
    /// longe do texto).
    var pilulaEmCima = true

    @State private var quadrado: CGPoint?
    @State private var vezDoQuadrado = 0

    var body: some View {
        CamadaDeToque(dono: dono) { local, sensor, longo in
            guard controles.tocar(pontoDoSensor: sensor, longo: longo) else { return false }
            vezDoQuadrado += 1
            let vez = vezDoQuadrado
            quadrado = local
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if vezDoQuadrado == vez { quadrado = nil }
            }
            return true
        }
        .overlay(alignment: .topLeading) {
            if let q = quadrado {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Estilo.aguardando, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .offset(x: q.x - 32, y: q.y - 32)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: pilulaEmCima ? .top : .bottom) {
            VStack(spacing: 0) {
                if let p = controles.pilula {
                    PilulaDosControles(texto: p)
                }
                // R9b (contrato §12, filmador 6): "Controlado por <aparelho>" enquanto o núcleo diz
                // que um receptor mexeu há menos de 4 s — a mesma pílula do toque longo.
                if let quem = controles.controladoPor {
                    PilulaDosControles(texto: RegrasDoControleRemoto.textoDoControladoPor(quem))
                }
                // A pouca luz (§3.1) só quando nenhuma das outras está à vista: é uma frase inteira, em
                // até duas linhas.
                if controles.pilula == nil, controles.controladoPor == nil, let luz = controles.poucaLuz {
                    PilulaDosControles(texto: luz, linhas: 2)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// A pílula âmbar da prévia (R9 §4.4): "Exposição e foco travados", e no R9b "Controlado por …".
struct PilulaDosControles: View {
    let texto: String
    var linhas = 1

    var body: some View {
        Text(texto)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.black)
            .lineLimit(linhas)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: linhas > 1 ? 420 : nil)
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Estilo.aguardando))
            .padding(8)
    }
}

/// **O `UIView` que recebe o toque e o toque longo**, e converte o ponto para o sensor. Tem nome
/// próprio para a sonda de bancada (R9, a prova na R5) achá-lo pelo `hitTest` da janela: é ele, e só
/// ele, que transforma um toque em ponto de foco e medida.
final class VistaDoToqueNaPrevia: UIView {
    weak var dono: DonoDaCaptura?
    /// O ponto nesta vista (para o quadrado), o ponto no sensor e se foi longo; devolve se gerou ponto.
    var tocou: ((CGPoint, CGPoint, Bool) -> Bool)?

    @objc fileprivate func toque(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        _ = entregar(naJanela: g.location(in: nil), longo: false)
    }

    @objc fileprivate func longo(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        _ = entregar(naJanela: g.location(in: nil), longo: true)
    }

    /// **A sonda de bancada** "toca" aqui, num ponto da janela, pelo mesmo caminho do dedo (a camada,
    /// `captureDevicePointConverted`, `ControlesDaCamera.tocar`). Devolve se gerou ponto.
    func simularToque(naJanela p: CGPoint) -> Bool { entregar(naJanela: p, longo: false) }

    private func entregar(naJanela: CGPoint, longo: Bool) -> Bool {
        guard let janela = window, let camada = dono?.camadaDePrevia else { return false }
        let local = convert(naJanela, from: nil)
        let naCamada = camada.convert(naJanela, from: janela.layer)
        let sensor = camada.captureDevicePointConverted(fromLayerPoint: naCamada)
        // Fora da imagem (as barras do `.resizeAspect`): não é um ponto do sensor.
        guard sensor.x >= 0, sensor.x <= 1, sensor.y >= 0, sensor.y <= 1 else {
            Diagnostico.nota("APP CAMERA toque fora da imagem (nas barras): nada a fazer")
            return false
        }
        return tocou?(local, sensor, longo) ?? false
    }
}

private struct CamadaDeToque: UIViewRepresentable {
    let dono: DonoDaCaptura
    let tocou: (CGPoint, CGPoint, Bool) -> Bool

    func makeUIView(context: Context) -> VistaDoToqueNaPrevia {
        let v = VistaDoToqueNaPrevia()
        v.backgroundColor = .clear
        let toque = UITapGestureRecognizer(target: v, action: #selector(VistaDoToqueNaPrevia.toque(_:)))
        let longo = UILongPressGestureRecognizer(target: v, action: #selector(VistaDoToqueNaPrevia.longo(_:)))
        longo.minimumPressDuration = 0.5
        toque.require(toFail: longo)
        v.addGestureRecognizer(toque)
        v.addGestureRecognizer(longo)
        return v
    }

    func updateUIView(_ v: VistaDoToqueNaPrevia, context: Context) {
        v.dono = dono
        v.tocou = tocou
    }
}

/// O botão "Ajustes da câmera" (§4.1): o `BotaoRedondo` com `gearshape` (a engrenagem, decisão do Pessoa Exemplo de 01/10, spec §4.1). Apagado enquanto a
/// câmera não montou (não há o que ajustar).
struct BotaoDosAjustesDaCamera: View {
    @ObservedObject var controles: ControlesDaCamera
    let aberto: Bool
    let tocar: () -> Void

    var body: some View {
        BotaoRedondo(icone: "gearshape", rotulo: tr("Ajustes da câmera"),
                     fundo: aberto ? Estilo.acento : Estilo.superficie, acao: tocar)
            .disabled(!controles.prontos)
            .opacity(controles.prontos ? 1 : 0.4)
            .accessibilityAddTraits(aberto ? [.isSelected] : [])
    }
}
