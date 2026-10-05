import CoreGraphics

/// **As decisões do "minimizar para a barra de menus"**, puras: o que o botão amarelo e o ⌘M fazem com
/// a janela da vez, se o ícone do Dock fica, se o ícone da barra está atrás do entalhe, onde a janela
/// volta, e quando o processo segura o App Nap.
public enum RegraDaBarra {

    /// O que fazer com um pedido de minimizar.
    public enum Minimizar: Equatable {
        /// `orderOut`: a janela sai da tela (e do Dock) com a árvore de vistas inteira, e só a barra de
        /// menus a traz de volta. Nada é encerrado.
        case esconderNaBarra
        /// O minimizar de sempre, para o Dock.
        case minimizarNoDock
        /// Nada (o sistema também não minimiza aqui).
        case nada
    }

    /// O pedido de minimizar vindo da janela `ehAPrincipal` (a do estúdio) ou de outra.
    ///
    /// - **Só a principal vai para a barra.** O "Controle do teleprompter" e os Ajustes minimizam para o
    ///   Dock como sempre: a pessoa minimizou *aquela* janela, e uma janela sumida sem ícone no Dock e
    ///   sem item no menu do ícone ficaria sem volta.
    /// - **Em tela cheia, nada.** O macOS desliga o amarelo e o ⌘M em tela cheia; tirar da tela uma
    ///   janela em tela cheia deixaria um espaço vazio no Mission Control.
    /// - **Com uma folha aberta** (o editor do roteiro, uma pergunta, o aviso da primeira vez), para o
    ///   Dock: a folha é uma decisão pendente presa à janela, e escondê-la sem Dock é perder a pergunta.
    /// - **Sem o ícone à vista na barra** (`NSStatusItem.isVisible` falso, ou atrás do entalhe —
    ///   `atrasDoEntalhe`), para o Dock: sem ele não há volta pela barra.
    /// - **Com a janela mostrando o texto do prompter** (`mostraOTexto`), para o Dock: o texto é a coisa
    ///   a ser vista, a rolagem anda pelo relógio de quadros da vista e provavelmente para com a janela
    ///   fora da tela, e o Dock deixa a miniatura e o lugar de sempre. Esconder o prompter "fora do
    ///   caminho" não é um uso; a barra é para as sessões que não precisam da janela (o pedido de 01/10
    ///   era a tela estendida).
    public static func minimizar(ehAPrincipal: Bool, emTelaCheia: Bool, comFolha: Bool,
                                 minimizavel: Bool = true, iconeAVista: Bool = true,
                                 mostraOTexto: Bool = false) -> Minimizar {
        guard ehAPrincipal else { return minimizavel && !emTelaCheia ? .minimizarNoDock : .nada }
        if emTelaCheia { return .nada }
        if comFolha || !iconeAVista || mostraOTexto { return .minimizarNoDock }
        return .esconderNaBarra
    }

    /// O ícone no Dock (`NSApp.setActivationPolicy`).
    public enum Dock: Equatable {
        /// `.regular`: o de sempre.
        case comIcone
        /// `.accessory`: só a barra de menus.
        case soNaBarra
    }

    /// **O Dock só some quando não sobra janela nenhuma à mostra.**
    ///
    /// Com a principal escondida na barra e o "Controle do teleprompter" (ou os Ajustes) à mostra — ou
    /// minimizado no Dock —, o ícone fica: um app sem Dock não entra no ⌘Tab nem tem barra de menus
    /// própria, e a janela que sobrou ficaria perdida atrás das outras; a minimizada sumiria junto com o
    /// ícone. Quando a última delas fecha, a regra é consultada de novo e aí o Dock sai.
    ///
    /// `outrasJanelas` conta as janelas de conteúdo do app que estão na tela ou minimizadas, sem a
    /// principal, as folhas dela e as janelas da barra de menus (uma por monitor, inclusive os virtuais
    /// da tela estendida). `iconeAVista`: sem o ícone na barra não há volta pela barra, e o Dock fica.
    public static func dock(principalNaBarra: Bool, outrasJanelas: Int, iconeAVista: Bool = true) -> Dock {
        principalNaBarra && outrasJanelas == 0 && iconeAVista ? .soNaBarra : .comIcone
    }

    /// **O ícone está atrás do entalhe?** Num painel com entalhe, os ícones da barra moram à direita
    /// dele (`NSScreen.auxiliaryTopRightArea`); um ícone cujo meio não cai ali não está à vista.
    ///
    /// Medido em 01/10 neste MacBook (painel de 1470 pt com entalhe; a área da direita de 825 a 1470):
    /// o ícone de uma sonda ficou em x 895–933, dentro dela. **Só o caso à vista foi medido**: onde o
    /// macOS põe a janela de um ícone que não coube não se sabe, e então esta regra pega o ícone posto
    /// sob o entalhe ou à esquerda dele, e deixa passar o resto. Só o meio horizontal conta: a janela do
    /// ícone tinha 33 pt de altura contra os 32 da área, e uma conta de "contido" erraria por um ponto.
    /// Sem entalhe (`ladoDireito` nulo, como nos monitores virtuais), não há o que dizer: à vista.
    public static func atrasDoEntalhe(icone: CGRect, ladoDireito: CGRect?) -> Bool {
        guard let d = ladoDireito, !d.isEmpty, !icone.isEmpty else { return false }
        return icone.midX < d.minX || icone.midX > d.maxX
    }

    /// **Onde a janela volta.** Escondida num monitor virtual da tela estendida que sumiu enquanto ela
    /// estava na barra, ela voltaria fora de qualquer tela. Se o `quadro` não toca nenhuma das `telas`,
    /// devolve o quadro no meio da `areaUtil` (a da tela principal), encolhido se não couber; senão,
    /// `nil` — ela fica onde estava.
    public static func quadroDeVolta(_ quadro: CGRect, telas: [CGRect], areaUtil: CGRect) -> CGRect? {
        guard !telas.contains(where: { $0.intersects(quadro) }), !areaUtil.isEmpty else { return nil }
        let largura = min(quadro.width, areaUtil.width)
        let altura = min(quadro.height, areaUtil.height)
        return CGRect(x: (areaUtil.midX - largura / 2).rounded(), y: (areaUtil.midY - altura / 2).rounded(),
                      width: largura, height: altura)
    }

    /// O que fazer com a atividade que segura o App Nap (`ProcessInfo.beginActivity`).
    public enum Atividade: Equatable {
        case segurar, soltar, manter
    }

    /// **Sessão de pé, App Nap segurado; "Pronto", solto.** Escondido na barra, em `.accessory` e
    /// escondido (`hide`), o app é o caso clássico do App Nap — e ele já foi medido atrasando
    /// temporizadores aqui (14/09, `Teleprompter.agendarAcoesDeBancada`: ações até 1 s atrasadas).
    public static func atividade(segurando: Bool, sessaoDePe: Bool) -> Atividade {
        switch (segurando, sessaoDePe) {
        case (false, true): return .segurar
        case (true, false): return .soltar
        default: return .manter
        }
    }
}
