import UIKit
import ReplayKit

/// Sonda da folha do seletor de transmissão.
///
/// Pergunta única: a folha que o `RPSystemBroadcastPickerView` abre é desenhada **no nosso
/// processo** ou é uma vista remota de outro processo? Se for nossa, dá para tocar em
/// "Iniciar transmissão" por código, e o iPhone 7 — que o `xcodebuild test` recusa — volta a ser
/// automatizável. Se for remota, o toque é humano e isso fica registrado com prova.
///
/// Ligada por argumento de linha de comando (`--args sondar`), nunca no uso normal.
enum Sonda {
    static let rotulosDeInicio = ["Iniciar transmissão", "Iniciar Transmissão", "Start Broadcast",
                                  "Iniciar Transmissão de Tela", "Start Screen Broadcast"]

    static func talvezSondar() {
        guard CommandLine.arguments.contains("sondar") else { return }
        Diario.anotar("SONDA ligada")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            abrirSeletor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                despejar()
                tentarTocar()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { despejar() }
            }
        }
    }

    static func janelas() -> [UIWindow] {
        var todas: [UIWindow] = []
        for cena in UIApplication.shared.connectedScenes {
            guard let cenaDeJanela = cena as? UIWindowScene else { continue }
            todas.append(contentsOf: cenaDeJanela.windows)
        }
        return todas
    }

    static func abrirSeletor() {
        for janela in janelas() {
            if let botao = procurarBotaoDoSeletor(janela) {
                botao.sendActions(for: .touchUpInside)
                Diario.anotar("SONDA seletor disparado por código")
                return
            }
        }
        Diario.anotar("SONDA não achei o botão do seletor")
    }

    private static func procurarBotaoDoSeletor(_ vista: UIView) -> UIButton? {
        if vista is RPSystemBroadcastPickerView {
            for filha in vista.subviews { if let b = filha as? UIButton { return b } }
        }
        for filha in vista.subviews {
            if let achado = procurarBotaoDoSeletor(filha) { return achado }
        }
        return nil
    }

    /// Despeja a hierarquia inteira. É a evidência: se a folha do sistema aparecer aqui com
    /// controles nossos, é local; se aparecer só como `_UIRemoteView`, é de outro processo.
    static func despejar() {
        let js = janelas()
        Diario.anotar("SONDA janelas=\(js.count)")
        for (i, janela) in js.enumerated() {
            Diario.anotar("SONDA janela[\(i)] classe=\(type(of: janela)) nivel=\(janela.windowLevel.rawValue) oculta=\(janela.isHidden)")
            descer(janela, profundidade: 1, janela: i)
            var vc = janela.rootViewController
            var n = 0
            while let atual = vc {
                Diario.anotar("SONDA janela[\(i)] vc[\(n)]=\(type(of: atual))")
                vc = atual.presentedViewController
                n += 1
            }
        }
    }

    private static func descer(_ vista: UIView, profundidade: Int, janela: Int) {
        guard profundidade < 12 else { return }
        for filha in vista.subviews {
            let nome = String(describing: type(of: filha))
            var extra = ""
            if let controle = filha as? UIControl {
                extra = " CONTROLE rotulo=\(controle.accessibilityLabel ?? "-")"
                if let b = controle as? UIButton {
                    extra += " titulo=\(b.title(for: .normal) ?? "-")"
                }
            } else if let rotulo = filha as? UILabel {
                extra = " TEXTO=\(rotulo.text ?? "-")"
            } else if nome.contains("Remote") {
                extra = " <<< VISTA REMOTA"
            }
            if !extra.isEmpty || nome.contains("Remote") || nome.contains("RP") {
                Diario.anotar("SONDA j\(janela) p\(profundidade) \(nome)\(extra)")
            }
            descer(filha, profundidade: profundidade + 1, janela: janela)
        }
    }

    static func tentarTocar() {
        for janela in janelas() {
            if let alvo = procurarPorRotulo(janela) {
                Diario.anotar("SONDA achei controle de início: \(type(of: alvo))")
                if let controle = alvo as? UIControl {
                    controle.sendActions(for: .touchUpInside)
                    Diario.anotar("SONDA TOQUEI por sendActions")
                }
                return
            }
        }
        Diario.anotar("SONDA nenhum controle de início no nosso processo")
    }

    private static func procurarPorRotulo(_ vista: UIView) -> UIView? {
        let rotulo = vista.accessibilityLabel ?? ""
        let titulo = (vista as? UIButton)?.title(for: .normal) ?? ""
        let texto = (vista as? UILabel)?.text ?? ""
        for alvo in rotulosDeInicio where rotulo == alvo || titulo == alvo || texto == alvo {
            return vista is UIControl ? vista : (vista.superview as? UIControl ?? vista)
        }
        for filha in vista.subviews {
            if let achado = procurarPorRotulo(filha) { return achado }
        }
        return nil
    }
}
