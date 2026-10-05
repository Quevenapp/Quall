import AppKit
import IOKit.pwr_mgt
import QuallTeleprompterKit

/// **A tela sempre acesa enquanto o prompter mostra o texto.**
///
/// O contrato registra a lacuna (§7): "Mac e Windows apagam no meio da leitura". Uma asserção de
/// energia do tipo `PreventUserIdleDisplaySleep` impede o monitor de apagar por ociosidade — que é
/// exatamente o caso do prompter: ninguém toca no teclado do Mac atrás do vidro por uma hora.
///
/// Só a tela do prompter segura a asserção, e ela é solta ao sair. O controle não precisa: quem
/// controla está tocando no teclado. Conferível por fora sem olhar tela nenhuma:
/// `pmset -g assertions` lista a asserção pelo nome, com o pid do app.
final class TelaAcesa {
    static let nome = "Quall: teleprompter mostrando o texto"

    private var id: IOPMAssertionID = 0
    private(set) var ligada = false

    /// Devolve o resultado para o registro (`kIOReturnSuccess` = 0).
    @discardableResult
    func ligar() -> IOReturn {
        guard !ligada else { return kIOReturnSuccess }
        var novo: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            TelaAcesa.nome as CFString, &novo)
        if r == kIOReturnSuccess {
            id = novo
            ligada = true
        }
        return r
    }

    func desligar() {
        guard ligada else { return }
        IOPMAssertionRelease(id)
        ligada = false
        id = 0
    }

    deinit { desligar() }
}

/// **Os atalhos de teclado do teleprompter.** O Mac como controle é teclado: espaço toca e pausa,
/// as setas mudam a velocidade (↑↓) e pulam (←→). Valem nas duas telas. No modo "Segurar para
/// rolar" do controle, ↑ e ↓ seguram os dois botões, e as outras teclas não fazem nada.
///
/// Um monitor local de teclas, e não `.keyboardShortcut` do SwiftUI: sem modificador, o atalho do
/// SwiftUI disputaria o espaço com os campos de texto. Aqui a tecla só é tomada quando **nenhum
/// campo de texto está com o foco** (o endereço, o PIN, o editor do roteiro) e nenhuma folha está
/// aberta; com Comando, Controle ou Opção ela passa adiante (os atalhos do sistema continuam
/// valendo).
final class AtalhosDoTeleprompter {
    enum Acao: Equatable {
        case tocarOuPausar
        case velocidade(Double)
        case pular(Double)
        case inicio
        case espelho
        case fonte(Double)
        case margem(Double)
        case linha(Double)
        case telaCheia
        case sairDaTelaCheia
        case editar
    }

    private var monitor: Any?
    private var tratar: ((Acao) -> Bool)?
    /// O "Segurar para rolar" (§12.5): `(botão, desce, repetição) -> tomou a tecla`. É consultado
    /// **antes** da tabela — no modo, ↑ e ↓ seguram em vez de mudar a velocidade.
    private var segurar: ((BotaoDeSegurar, Bool, Bool) -> Bool)?

    func ligar(_ tratar: @escaping (Acao) -> Bool,
               segurar: @escaping (_ botao: BotaoDeSegurar, _ desce: Bool, _ repeticao: Bool) -> Bool) {
        desligar()
        self.tratar = tratar
        self.segurar = segurar
        // `keyUp` também: segurar uma seta é `hold` quando ela desce e `release` quando sobe.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] evento in
            guard let self else { return evento }
            return self.processar(evento, janela: NSApp.keyWindow)
        }
    }

    func desligar() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tratar = nil
        segurar = nil
    }

    deinit { desligar() }

    /// **O caminho de toda tecla**: a de verdade (o monitor, com a `keyWindow`) e a da bancada (um
    /// evento sintético, com a janela do app). Devolve `nil` quando a tecla foi tomada.
    func processar(_ evento: NSEvent, janela: NSWindow?) -> NSEvent? {
        guard let janela, janela.attachedSheet == nil, !janela.isSheet else { return evento }
        // As janelas de ajustes (⌘, e os Ajustes da câmera) não comandam o teleprompter: as teclas são delas.
        if JanelasDeAjustes.ehMarcada(janela) { return evento }
        if janela.firstResponder is NSText { return evento }
        if let botao = AtalhosDoTeleprompter.botaoDoSegurar(para: evento), let segurar,
           segurar(botao, evento.type == .keyDown, evento.type == .keyDown && evento.isARepeat) {
            return nil
        }
        guard evento.type == .keyDown, let acao = AtalhosDoTeleprompter.acao(para: evento), let tratar else {
            return evento
        }
        return tratar(acao) ? nil : evento
    }

    /// A seta do "segurar", se for uma: ↑ ou ↓, descendo sem ⌘, ⌃ ou ⌥ — ou **subindo com qualquer
    /// modificador**: a seta que desceu limpa e sobe com ⇧ apertado no meio não pode deixar o texto
    /// rolando.
    static func botaoDoSegurar(para e: NSEvent) -> BotaoDeSegurar? {
        switch e.type {
        case .keyDown:
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !mods.intersection([.command, .control, .option]).isEmpty { return nil }
        case .keyUp:
            break
        default:
            return nil
        }
        return BotaoDeSegurar.daTecla(e.keyCode)
    }

    /// A tabela das teclas. Com Shift, o passo é maior.
    static func acao(para e: NSEvent) -> Acao? {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.intersection([.command, .control, .option]).isEmpty { return nil }
        let grande = mods.contains(.shift)
        switch e.keyCode {
        case 49: return .tocarOuPausar                                  // espaço
        case 126: return .velocidade(grande ? 1.0 : 0.1)                // ↑
        case 125: return .velocidade(grande ? -1.0 : -0.1)              // ↓
        case 124: return .pular(grande ? 0.1 : 0.02)                    // →
        case 123: return .pular(grande ? -0.1 : -0.02)                  // ←
        case 115: return .inicio                                        // Home (fn ←)
        case 53: return .sairDaTelaCheia                                // Esc
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "0": return .inicio
        case "m": return .espelho
        case "=", "+": return .fonte(grande ? 16 : 4)
        case "-", "_": return .fonte(grande ? -16 : -4)
        case "[": return .margem(-0.02)
        case "]": return .margem(0.02)
        case ",", "<": return .linha(-0.02)
        case ".", ">": return .linha(0.02)
        case "f": return .telaCheia
        case "e": return .editar
        default: return nil
        }
    }
}
