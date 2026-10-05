import AppKit
import Foundation
import QuallBarraDeMenusKit
import SwiftUI

/// O inventário das janelas do processo, e a única coisa que faz uma delas aparecer numa corrida
/// sem ninguém no teclado.
///
/// # Por que isto existe, e o defeito de bancada que ele desenterrou
///
/// `docs/app-macos.md` fechou a rodada anterior com a frase *"Não afirmo que a janela apareceu na
/// tela"*, e nenhuma corrida deste app jamais a contradisse. Para um **emissor** isso é uma lacuna
/// de relato; para um **receptor** é a diferença entre o produto funcionar e não funcionar, porque
/// uma `AVSampleBufferDisplayLayer` que não está numa janela **aceita todo quadro e não desenha
/// nada** — todos os contadores fecham e a tela fica preta.
///
/// Medido em 2026-08-30, nesta bancada: com o app aberto por
/// `open -n -W -a Quall.app --args --registro /tmp/x.log --exibir --sair-apos 40`, a corrida de
/// recepção deu `recebidos=753 decodificados=753 enfileirados=751` com `camada=0x0 na_arvore=NAO`
/// do começo ao fim, e `NSApp.windows` **vazio**. O `CGWindowListCopyWindowInfo` do sistema
/// listava só a barra de menus. A raiz da cena SwiftUI nunca chegou a aparecer: o `onAppear` dela
/// não escreveu uma linha sequer.
///
/// ## A causa não era o app: era a forma dos argumentos
///
/// Reproduzida num app SwiftUI de vinte linhas, fora deste repositório, para separar o que é nosso
/// do que é da plataforma:
///
/// | argumentos passados por `--args` | janelas |
/// |---|---|
/// | *(nenhum)* | **1** |
/// | `--exibir` | **1** |
/// | `--sair-apos 6` | **1** |
/// | `oi` | **0** |
/// | `--registro /tmp/x.log --exibir --sair-apos 6` | **0** |
/// | `--registro=/tmp/x.log --exibir --sair-apos=6` | **1** |
///
/// O `NSUserDefaults` do AppKit consome a linha de comando **em pares**: um token que começa com
/// `-` é chave e o **próximo token é o valor dele**, seja ele qual for. Numa lista com uma
/// bandeira sem valor no meio, o pareamento desanda e sobra um token sem `-` na posição de chave —
/// e um token solto é, para o AppKit, **um arquivo a abrir**. Um app lançado "para abrir um
/// documento" não ganha a janela padrão do `WindowGroup`.
///
/// Na linha que falhava: `--registro`=`/tmp/x.log`, `--exibir`=`--sair-apos`, e `40` sobrou. O
/// conserto é usar `--chave=valor`, que faz **todo** token começar com `-` e nunca sobrar nada —
/// e `Argumentos` aceita as duas formas para que nenhum roteiro antigo quebre.
///
/// **Isto explica retroativamente por que ninguém nunca viu esta janela.** As corridas de bancada
/// que `docs/app-macos.md` registra passavam
/// `--registro X --pin N --fonte tela --espelhar-ja --sair-apos 45` — a mesma forma, o mesmo
/// desalinhamento, a mesma janela ausente. Para o emissor não fazia diferença: ele captura e manda
/// sem precisar de vista nenhuma.
///
/// [`aparecerEDizer`] é o conserto **e** a testemunha, e as duas ficam: um receptor que decodifica
/// sem mostrar é o pior defeito que este app pode ter, e ele não dá erro em lugar nenhum.
enum Janela {

    /// Uma linha por janela do processo: tamanho, visível, e se está numa tela.
    ///
    /// **Não lê título de janela nenhuma**, nem desta nem de outro processo: o que sai daqui é
    /// geometria. Ver `apps/macos/Bancada/janela-do-app.swift`, que aplica a mesma regra do lado
    /// de fora.
    ///
    /// **Sem as janelas da barra de menus** (01/10): o ícone do Quall na barra é uma `NSStatusBarWindow`
    /// **por monitor** — três numa sonda deste Mac com a tela estendida no ar (o painel e os dois
    /// monitores virtuais, "Quall — SM-X230" e "Quall — SM-A075M") —, visível, com vista, e dentro de
    /// `NSApp.windows`. Listadas, a primeira `n=` da linha podia ser a do ícone, e é a primeira `n=` que
    /// `Bancada/provar-teleprompter.sh` captura. Elas (e um menu ou uma dica abertos) viram só uma
    /// contagem no fim, sem `n=`.
    static func inventario() -> String {
        let janelas = NSApp.windows.filter(ehDeConteudo)
        let doSistema = NSApp.windows.count - janelas.count
        let sufixo = doSistema > 0 ? " (+\(doSistema) da barra de menus e afins)" : ""
        guard !janelas.isEmpty else { return "nenhuma janela de conteúdo neste processo" + sufixo }
        return janelas.map { j in
            let c = j.frame
            // `n` é o `CGWindowID` (o `windowNumber` de uma janela na tela): é o que
            // `screencapture -l` pede para capturar **só esta janela**, e nunca a tela do Mac.
            return "[n=\(j.windowNumber) \(Int(c.width))x\(Int(c.height)) visivel=\(j.isVisible ? "sim" : "NAO")"
                + " tela=\(j.screen == nil ? "NENHUMA" : "sim")]"
        }.joined(separator: " ") + sufixo
    }

    /// Uma janela de conteúdo do app — a principal, a do controle, os Ajustes, uma folha —, e não uma
    /// das que o sistema põe em `NSApp.windows` por nós: o ícone da barra de menus (nível 25, uma por
    /// monitor), um menu aberto, uma dica. O nível separa as duas famílias sem depender do nome de uma
    /// classe privada (`NSStatusBarWindow`); a classe, o nível e o `isVisible` foram lidos numa sonda em
    /// 01/10.
    static func ehDeConteudo(_ j: NSWindow) -> Bool {
        j.contentView != nil && j.level.rawValue < NSWindow.Level.statusBar.rawValue
    }

    // MARK: - a janela principal

    /// O `id` do `WindowGroup` da janela principal: é por ele que `abrirNova` a recria.
    static let idDaPrincipal = "quall.principal"

    /// **A janela principal** (a do estúdio, do `WindowGroup`), marcada pela própria raiz da cena
    /// (`MarcaDaJanelaPrincipal`) — e não procurada em `NSApp.windows`, onde moram também o "Controle do
    /// teleprompter", os Ajustes e as janelas do ícone da barra de menus.
    ///
    /// **Solta no `willClose`**, e não só pelo `weak`: medido numa sonda em 01/10, o SwiftUI **não
    /// solta** a janela fechada no X (ela segue em `NSApp.windows`, invisível, e o `weak` não zera). Sem
    /// isto, "Abrir o Quall Studio" ordenaria para a frente uma janela que o SwiftUI já deu por fechada.
    private(set) static weak var principal: NSWindow?
    private static var observadorDoFechar: NSObjectProtocol?

    /// Recria a janela principal depois de ela ser fechada no X: o `openWindow` da raiz da cena,
    /// guardado no `onAppear` dela. A mesma sonda de 01/10 mostrou que ele **continua abrindo** depois
    /// de a vista que o guardou ter ido embora junto com a janela.
    static var abrirNova: (() -> Void)?

    static func registrarPrincipal(_ janela: NSWindow) {
        guard principal !== janela else { return }
        principal = janela
        if let o = observadorDoFechar { NotificationCenter.default.removeObserver(o) }
        observadorDoFechar = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: janela, queue: .main) { [weak janela] _ in
            guard let janela, principal === janela else { return }
            principal = nil
            Registro.compartilhado.linha(
                "janela: a principal fechou (o botão vermelho ou ⌘W) — o app e as sessões seguem; "
                + "\"Abrir o Quall Studio\" na barra de menus (ou o Dock) a recria")
            BarraDeMenus.atual?.principalFechou()
        }
        BarraDeMenus.atual?.cuidarDaPrincipal(janela)
    }

    /// Traz a janela do app para a frente. **Idempotente e barata**; chamável de qualquer momento
    /// da main.
    ///
    /// Os dois passos são necessários por razões diferentes, e o primeiro sozinho não basta:
    ///
    /// - `activate` diz ao sistema que este app é o da frente. Sem ele, um app aberto por
    ///   `open`/LaunchServices enquanto outro está ativo pode ficar sem foco;
    /// - `makeKeyAndOrderFront` é o que de fato **ordena a janela para a tela**. Uma janela do
    ///   `WindowGroup` que nunca é ordenada não existe para o servidor de janelas — ela não
    ///   aparece nem em `CGWindowListCopyWindowInfo` com `.optionAll` —, e a árvore de vistas dela
    ///   nunca é montada. É exatamente esse o caminho pelo qual `camadaNaArvore` fica `false` com
    ///   todos os outros contadores fechando.
    @discardableResult
    static func aparecer() -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // A principal marcada; antes de ela se marcar, a primeira janela de conteúdo — e não
        // `keyWindow`: numa corrida sem ninguém no teclado não há janela-chave para pedir. **De
        // conteúdo**: desde 01/10 o ícone da barra de menus põe uma janela por monitor em
        // `NSApp.windows`, visível e com vista, e a primeira da lista podia ser uma delas.
        guard let janela = principal ?? NSApp.windows.first(where: { ehDeConteudo($0) && !$0.isSheet }) else {
            return false
        }
        if janela.isMiniaturized { janela.deminiaturize(nil) }
        // Escondida na barra num monitor virtual da tela estendida que sumiu nesse meio-tempo, ela
        // voltaria fora de qualquer tela: no meio da principal (a do alto da lista, a da barra de menus).
        if let tela = NSScreen.screens.first,
           let novo = RegraDaBarra.quadroDeVolta(janela.frame, telas: NSScreen.screens.map(\.frame),
                                                 areaUtil: tela.visibleFrame) {
            Registro.compartilhado.linha("janela: estava fora de qualquer tela (\(Int(janela.frame.minX)),"
                                         + "\(Int(janela.frame.minY))) — volta no meio da tela principal")
            janela.setFrame(novo, display: false)
        }
        janela.makeKeyAndOrderFront(nil)
        return true
    }

    /// Ordena a janela e **escreve no registro o que aconteceu** — inclusive a causa provável
    /// quando não há janela nenhuma.
    ///
    /// A frase que ela escreve nesse caso não é "não achei janela": é o nome da armadilha, porque
    /// o custo de redescobri-la foi uma investigação inteira e o sintoma dela (contadores fechando
    /// com a tela preta) aponta para todo lugar menos para os argumentos.
    static func aparecerEDizer() {
        if aparecer() {
            Registro.compartilhado.linha("janela: ordenada — \(inventario())")
            return
        }
        Registro.compartilhado.linha(
            "janela: !! NENHUMA JANELA NESTE PROCESSO — sem janela não há vista, e a camada de "
            + "exibição aceita quadro sem desenhar nada. Causa provável: algum argumento sobrou "
            + "sem par e o AppKit o tratou como arquivo a abrir. Use --chave=valor. Ver `Janela`.")
    }
}

/// Marca a janela que a contém como a principal (`Janela.principal`). Vai **só** na raiz do
/// `WindowGroup` (`RaizDaJanela`): o "Controle do teleprompter" e os Ajustes não a têm. O mesmo
/// desenho de `MarcaDaJanelaDeAjustes`.
struct MarcaDaJanelaPrincipal: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Vista() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Vista: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { Janela.registrarPrincipal(w) }
        }

        /// Fundo que não pega clique.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
