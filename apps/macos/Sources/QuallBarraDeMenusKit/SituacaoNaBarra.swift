import Foundation
import QuallIdiomaKit

/// **O que o menu do ícone diz**, em valores simples (o mesmo padrão de `DadosDaEspera`): o app lê o
/// `Emissor`, o `Receptor` e o `Teleprompter` e monta isto; daqui saem as linhas de estado do menu e a
/// cor da bolinha. Puro, para ser testado sem app, sem rede e sem janela.
///
/// # Uma linha por coisa de pé, e não uma linha só
///
/// O caso comum é uma coisa por vez ("um papel por vez", `docs/telas-estudio.md` §7), mas há dois que
/// convivem de propósito: o controle do teleprompter na janela própria enquanto a principal exibe o
/// vídeo de outro aparelho (M4, `docs/teleprompter-com-camera.md` §12), e o "Texto com a câmera", que
/// tem duas sessões — o prompter (7979) e o vídeo da câmera (7877). Cada uma ganha a sua linha.
///
/// # O vermelho é "sai daqui", e não "tem sessão"
///
/// A bolinha fica vermelha quando algo **deste Mac** está indo para outro aparelho: a tela espelhada, a
/// tela estendida com aparelho, a câmera transmitindo (a comum ou a do "Texto com a câmera"). Esperando
/// alguém conectar não é vermelho (nada saiu ainda), e exibir o vídeo de outro aparelho ou mostrar e
/// controlar texto também não: é o mesmo sentido do NO AR da janela.
public struct SituacaoNaBarra: Equatable {

    /// O que está sendo espelhado (o item Espelhar).
    public enum Origem: Equatable {
        case tela, camera
        #if QUALL_TELA_ESTENDIDA_FUTURA
        case telaEstendida
        #endif
    }

    public enum Emissao: Equatable {
        case parada
        case esperando(Origem)
        /// No ar, com o nome de cada receptor (vazio vira "outro aparelho").
        case noAr(Origem, aparelhos: [String])
        case encerrando
    }

    /// Este Mac exibindo a imagem de outro aparelho (o item Exibir).
    public enum Exibicao: Equatable {
        case parada
        case conectando
        case esperandoImagem(de: String)
        case exibindo(String)
        case encerrando
    }

    /// Este Mac mostrando o texto ("Mostrar o texto" e "Texto com a câmera").
    public enum Prompter: Equatable {
        case fechado
        case esperandoOControle
        case controladoPor(String)
        case semOControle
        /// A espera parou (PIN errado demais, ou um erro que precisa da pessoa).
        case parado
        case saindo
    }

    /// O vídeo da câmera do "Texto com a câmera".
    public enum CameraDoTexto: Equatable {
        case fechada
        case esperando
        case noAr(String)
    }

    /// Este Mac controlando o texto de outro aparelho (o item Controlar).
    public enum Controle: Equatable {
        case fechado
        case conectando
        case controlando(String)
        case semConexao
        case saindo
    }

    public var emissao: Emissao
    public var exibicao: Exibicao
    public var prompter: Prompter
    public var cameraDoTexto: CameraDoTexto
    public var controle: Controle

    public init(emissao: Emissao = .parada, exibicao: Exibicao = .parada, prompter: Prompter = .fechado,
                cameraDoTexto: CameraDoTexto = .fechada, controle: Controle = .fechado) {
        self.emissao = emissao
        self.exibicao = exibicao
        self.prompter = prompter
        self.cameraDoTexto = cameraDoTexto
        self.controle = controle
    }

    /// A frase de quando nada está de pé.
    public static var pronto: String { T("Pronto") }

    /// A bolinha vermelha: algo deste Mac indo para outro aparelho.
    public var noAr: Bool {
        if case .noAr = emissao { return true }
        if case .noAr = cameraDoTexto { return true }
        return false
    }

    /// Alguma coisa de pé — tudo o que não é "Pronto": uma emissão (esperando, no ar ou encerrando),
    /// uma exibição, o prompter aberto, a câmera do texto, o controle. É o que segura o App Nap
    /// (`RegraDaBarra.atividade`).
    public var sessaoDePe: Bool {
        emissao != .parada || exibicao != .parada || prompter != .fechado || cameraDoTexto != .fechada
            || controle != .fechado
    }

    /// As linhas de estado do menu, na ordem da barra lateral (Espelhar, Exibir, o teleprompter). Nunca
    /// vazia: sem nada de pé, "Pronto".
    public var linhas: [String] {
        var l: [String] = []
        if let e = SituacaoNaBarra.linha(emissao) { l.append(e) }
        if let x = SituacaoNaBarra.linha(exibicao) { l.append(x) }
        if let p = SituacaoNaBarra.linha(prompter) { l.append(p) }
        if let c = SituacaoNaBarra.linha(cameraDoTexto) { l.append(c) }
        if let c = SituacaoNaBarra.linha(controle) { l.append(c) }
        return l.isEmpty ? [SituacaoNaBarra.pronto] : l
    }

    // MARK: - as frases

    /// O nome que o núcleo deu ao par, ou "outro aparelho" quando ele não disse (o mesmo da janela).
    static func nome(_ n: String) -> String {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? T("outro aparelho") : t
    }

    /// "iPad" com um; "2 aparelhos" com mais (o "Espelhando para" da tela de espera).
    static func quem(_ aparelhos: [String]) -> String {
        aparelhos.count > 1 ? T("%@ aparelhos", aparelhos.count) : nome(aparelhos.first ?? "")
    }

    static func linha(_ e: Emissao) -> String? {
        switch e {
        case .parada: return nil
        case .esperando(.tela): return T("Espelhar: esperando um aparelho")
        #if QUALL_TELA_ESTENDIDA_FUTURA
        case .esperando(.telaEstendida): return T("Tela estendida: esperando um aparelho")
        #endif
        case .esperando(.camera): return T("Câmera: esperando um aparelho")
        case .noAr(.tela, let a): return T("Espelhando para %@", quem(a))
        #if QUALL_TELA_ESTENDIDA_FUTURA
        case .noAr(.telaEstendida, let a): return T("Tela estendida: %@", quem(a))
        #endif
        case .noAr(.camera, let a): return T("Câmera indo para %@", quem(a))
        case .encerrando: return T("Encerrando a transmissão…")
        }
    }

    static func linha(_ x: Exibicao) -> String? {
        switch x {
        case .parada: return nil
        case .conectando: return T("Exibir: conectando…")
        case .esperandoImagem(let de): return T("Exibir: esperando a imagem de %@", nome(de))
        case .exibindo(let de): return T("Exibindo %@", nome(de))
        case .encerrando: return T("Parando de exibir…")
        }
    }

    static func linha(_ p: Prompter) -> String? {
        switch p {
        case .fechado: return nil
        case .esperandoOControle: return T("Teleprompter: esperando o controle")
        case .controladoPor(let quem): return T("Teleprompter: controlado por %@", nome(quem))
        case .semOControle: return T("Teleprompter: sem o controle")
        case .parado: return T("Teleprompter: a espera parou")
        case .saindo: return T("Teleprompter: saindo…")
        }
    }

    static func linha(_ c: CameraDoTexto) -> String? {
        switch c {
        case .fechada: return nil
        case .esperando: return T("Texto com a câmera: esperando um aparelho")
        case .noAr(let para): return T("Texto com a câmera: indo para %@", nome(para))
        }
    }

    static func linha(_ c: Controle) -> String? {
        switch c {
        case .fechado: return nil
        case .conectando: return T("Controlar: conectando…")
        case .controlando(let de): return T("Controlando o texto de %@", nome(de))
        case .semConexao: return T("Controlar: sem conexão")
        case .saindo: return T("Controlar: saindo…")
        }
    }
}
