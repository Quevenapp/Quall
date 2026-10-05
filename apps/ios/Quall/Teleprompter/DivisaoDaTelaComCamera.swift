import CoreGraphics

// ================================================================================================
// **A conta da divisão da tela R5** ("Teleprompter com câmera", `docs/teleprompter-com-camera.md`
// §2.5), pura: sem SwiftUI nem UIKit, para rodar em `Testes/rodar.sh`. A vista
// (`TelaDoPrompterComCamera`) só aplica. Até 30/09 a conta morava dentro da vista e os testes de
// mesa a copiavam à mão; saiu para cá com o pedido do Pessoa Exemplo para a horizontal (ver
// `DivisaoDaTelaComCamera`), que é o primeiro que mexe nela por inteiro.
// ================================================================================================

/// **De que lado da tela fica o texto.** O olhar de quem lê fica perto da câmera: o texto vai para
/// a borda da lente quando ela está em cima ou embaixo, e em cima quando ela está de lado.
enum LadoDoTexto: String, CaseIterable, Identifiable {
    /// O da lente em cima ou embaixo; em cima com a lente de lado (`doAutomatico`).
    case automatico
    case cima
    case baixo
    case esquerda
    case direita

    var id: String { rawValue }

    /// Os nomes na tela. **"Automático"** desde 30/09 (era "Do lado da lente", e deixou de ser
    /// verdade com a lente de lado); o `rawValue` gravado (`automatico`) não mudou.
    var nome: String {
        switch self {
        case .automatico: return "Automático"
        case .cima: return "Em cima"
        case .baixo: return "Embaixo"
        case .esquerda: return "À esquerda"
        case .direita: return "À direita"
        }
    }

    /// O nome na tela, no idioma escolhido (`nome` fica em PT: o diário e os testes o leem).
    var rotulo: String {
        switch self {
        case .automatico: return tr("Automático")
        case .cima: return tr("Em cima")
        case .baixo: return tr("Embaixo")
        case .esquerda: return tr("À esquerda")
        case .direita: return tr("À direita")
        }
    }

    /// O texto e a prévia empilhados (em cima e embaixo), e não lado a lado.
    var empilhado: Bool { self == .cima || self == .baixo }

    /// **Onde a lente frontal está, na tela, agora.** Nunca devolve `.automatico`.
    ///
    /// A borda da lente é uma propriedade do aparelho **em pé** (o quadro nativo), e a orientação da
    /// interface só a gira:
    ///
    /// - **iPhone**: a lente fica na borda de cima em pé. Em Paisagem (`.landscapeRight`, o topo do
    ///   aparelho à esquerda) ela fica à esquerda; em Paisagem invertida, à direita.
    /// - **iPad (A16)**: a frontal fica na **borda longa** (a mesma mudança que o `EmissorDeCamera`
    ///   já registrou ao girar a imagem, 07/09), e em pé ela fica **à direita**; em `.landscapeRight`
    ///   ela fica em cima, que é o uso de paisagem para que a Apple a mudou. **Conferido pelo Pessoa Exemplo no
    ///   iPad em 27/09** (a bancada do §8.12.7, com o texto em cima no iPad deitado; era hipótese pela
    ///   ficha até ali). iPads mais velhos têm a lente na borda
    ///   curta: por isso existe o ajuste, e quem vê o texto do lado errado escolhe o lado.
    static func daLente(ipad: Bool, interface: InterfaceDaTela) -> LadoDoTexto {
        // Sentido horário a partir do alto: cima, direita, baixo, esquerda.
        let ordem: [LadoDoTexto] = [.cima, .direita, .baixo, .esquerda]
        let nativo = ipad ? 1 : 0
        let passos: Int
        switch interface {
        case .landscapeRight: passos = -1 // o topo do aparelho foi para a esquerda
        case .landscapeLeft: passos = 1   // o topo do aparelho foi para a direita
        case .portraitUpsideDown: passos = 2
        case .portrait, .desconhecida: passos = 0
        }
        return ordem[((nativo + passos) % 4 + 4) % 4]
    }

    /// **O lado do texto no automático** (pedido do Pessoa Exemplo, 30/09: "na horizontal o texto do
    /// teleprompter precisa ficar no centro embaixo da camera, não no lado esquerdo e a camera no
    /// lado direito, ai segue o mesmo modelo da vertical").
    ///
    /// O texto vai para o lado da lente **só quando ela está em cima ou embaixo**. Com a lente de
    /// lado — o iPhone deitado, o iPad em pé —, o texto vai **em cima**, empilhado como em pé, e a
    /// prévia embaixo dele. **O automático nunca põe lado a lado**; "À esquerda" e "À direita"
    /// continuam no ajuste para quem quiser. No iPad deitado a lente já fica em cima (borda longa),
    /// e nada muda ali.
    ///
    /// Até 30/09 o automático era "do lado da lente" sempre: no iPhone deitado o texto ia para a
    /// esquerda ou a direita, encostado na lente, e a prévia do outro lado.
    static func doAutomatico(lente: LadoDoTexto) -> LadoDoTexto {
        lente.empilhado ? lente : .cima
    }

    /// O lado que vale agora: o do ajuste, ou o do automático para a lente onde ela está.
    func resolvido(lente: LadoDoTexto) -> LadoDoTexto {
        self == .automatico ? LadoDoTexto.doAutomatico(lente: lente) : self
    }
}

/// **A orientação da interface**, sem UIKit: os casos de `UIInterfaceOrientation`, com os mesmos
/// nomes, para a conta da lente rodar no MacBook. A ponte (`init` a partir do UIKit) fica em
/// `AjustesDaTelaComCamera.swift`.
enum InterfaceDaTela {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case desconhecida
}

/// **Qual fração guardada vale**, uma por forma da divisão, cada uma numa chave do `UserDefaults`
/// (`AjustesDaTelaComCamera.chave(da:)`).
///
/// - `retrato`: a tela mais alta que larga (o que for: empilhado, ou lado a lado escolhido à mão).
/// - `paisagem`: a tela mais larga que alta, lado a lado (o iPhone deitado com "À esquerda" ou
///   "À direita"), e o empilhado de tela larga e **alta** (o iPad deitado), como até 30/09.
/// - `empilhadaLarga` (30/09): empilhado numa tela larga e **baixa**, com a faixa ao lado da prévia
///   (o iPhone deitado no automático). Chave própria porque a fração dela é da **altura**, e a do
///   lado a lado é da **largura**: dividir as duas faria a troca de "À esquerda" para o automático
///   abrir o texto com a fração da outra conta.
///
/// As duas primeiras chaves são as de antes, com o mesmo texto: o que estava gravado continua valendo.
enum FormaDaDivisao: String, CaseIterable {
    case retrato
    case paisagem
    case empilhadaLarga = "empilhada-larga"

    /// Para o diário.
    var nome: String {
        switch self {
        case .retrato: return "retrato"
        case .paisagem: return "paisagem"
        case .empilhadaLarga: return "empilhada na tela larga"
        }
    }
}

/// **A divisão: texto | prévia | faixa**, nesta ordem a partir do texto.
///
/// - **O texto é uma fração da tela inteira** (a gravada, por forma), e **só a prévia** absorve a
///   faixa. Assim um aviso que aparece (o controle caiu) ou que se abre encolhe a prévia, e **nunca
///   move a linha de leitura** de quem está lendo.
/// - **Empilhado numa tela alta** (o retrato, e o iPad deitado): o texto na sua borda, a prévia ao
///   lado dele, a faixa na outra ponta, na largura toda. A borda para antes de a prévia ficar menor
///   que `previaMinima` com `reservaDaFaixa` para a faixa.
/// - **Empilhado numa tela larga e baixa** (30/09, o iPhone deitado; `faixaAoLadoDaPrevia`): o texto na
///   largura toda, e a banda que sobra é da prévia **e** da faixa, lado a lado — a faixa numa coluna
///   à direita, com a largura da coluna do lado a lado, encostada no pé (no alto, com o texto
///   embaixo); a prévia com o resto da banda, na altura toda. A faixa fica na banda: a altura dela é
///   a medida até a altura da banda, e nunca cobre o texto.
/// - **Lado a lado** (escolhido à mão): o texto de um lado; do outro, a coluna com a prévia em cima e
///   a faixa no pé.
/// - **Prévia escondida**: o texto fica com tudo menos a faixa, que vai para o pé da tela (para o
///   alto, com o texto embaixo), na largura toda. A **moldura da prévia não muda** (só a vista some,
///   e o texto a cobre): esconder e mostrar não refazem o leiaute da camada.
struct DivisaoDaTelaComCamera: Equatable {
    var lado: LadoDoTexto
    var texto: CGRect
    var previa: CGRect
    /// A faixa dos controles (avisos, estado, barra): ver o comentário do tipo.
    var faixa: CGRect
    /// A coordenada da borda entre o texto e a prévia, no eixo da divisão.
    var borda: CGFloat
    /// O comprimento que a fração divide (a tela inteira no eixo da divisão): o arrasto da borda mede
    /// contra ele.
    var eixo: CGFloat
    var forma: FormaDaDivisao
    /// A fração do texto que valeu: a pedida, limitada e presa ao teto desta tela.
    var fracao: Double
    /// O teto da fração nesta tela.
    var teto: Double
    /// **A altura em que a faixa tem de caber**, com ela ao lado da prévia: a da banda. `nil` com a
    /// faixa no pé da tela (ou ao pé da coluna lado a lado), que não tem teto — como até 30/09.
    var tetoDaFaixa: CGFloat?

    /// A faixa mora ao lado da prévia (empilhado na tela larga e baixa, com a prévia à mostra).
    var faixaAoLado: Bool { tetoDaFaixa != nil }

    /// Nenhum dos dois lados fica menor que isto (fração da tela). **Hipótese** do desenho (§2.5):
    /// abaixo disso nem o texto se lê nem a prévia enquadra.
    static let minimo = 0.2
    /// O menor pedaço de prévia que a borda deixa, empilhada, com a faixa no tamanho de referência.
    static let previaMinima: CGFloat = 120
    /// O que a borda reserva para a faixa, empilhada. **Constante de propósito**: o limite da borda
    /// não pode depender da altura medida da faixa, senão um aviso que aparece mexe no texto.
    static let reservaDaFaixa: CGFloat = 150
    /// A largura da coluna que leva a faixa fora do pé: lado a lado, e empilhado na tela larga e baixa.
    /// A barra de oito botões pede isto.
    static let larguraDaColunaLadoALado: CGFloat = 340
    /// **Abaixo desta altura a tela é baixa** (30/09): 540 pt, o dobro do que a faixa no pé pede
    /// embaixo do texto (prévia mínima 120 + reserva 150) — a altura em que o 50/50 de padrão ainda
    /// comporta as duas empilhadas. **Constante própria**, e não a soma calculada: o ajuste fino
    /// daquelas duas não pode reclassificar aparelho. A folga é larga dos dois lados: o iPhone deitado
    /// mais alto tem 440 pt (o Pro Max, inteiro); o iPad deitado mais baixo, 700 (o mini, na área
    /// segura). Uma **janela** de iPad (o modo de janelas) mais baixa que isto é baixa como um iPhone
    /// deitado e ganha a faixa ao lado; redimensioná-la através dos 540 troca a forma e a fração
    /// guardada, e a linha de leitura pula uma vez.
    static let alturaDaTelaBaixa: CGFloat = 540

    static func limitar(_ f: Double) -> Double { min(1 - minimo, max(minimo, f)) }

    /// O lado que a conta usa: `.automatico` aqui é engano de quem chama (ele é resolvido antes, em
    /// `LadoDoTexto.resolvido`), e cai em `.cima`, como caía o `default` da conta antiga.
    private static func normal(_ l: LadoDoTexto) -> LadoDoTexto { l == .automatico ? .cima : l }

    /// **A faixa vai para o lado da prévia** (30/09): empilhado numa tela **mais larga que alta e
    /// baixa** (`alturaDaTelaBaixa`) — tão baixa que, no 50/50 de padrão, a banda da prévia não
    /// comporta a prévia mínima e a reserva da faixa uma sobre a outra. É o iPhone deitado: o mais
    /// alto deitado tem 440 pt, e a área segura do iPhone X deitado é 724×354.
    ///
    /// **A altura entra de propósito, e não só "largura > altura"**: o iPad deitado também é largo e
    /// empilhado (a lente em cima), e com a faixa ao lado ele mudaria — o pedido de 30/09 é que nada
    /// mude nele. O iPad deitado mais baixo tem 744 pt (o mini); com a faixa no pé ele tem a prévia
    /// e o texto de sobra, como na bancada de 27/09.
    ///
    /// E a coluna tem de deixar pelo menos `previaMinima` de prévia ao lado dela.
    static func faixaAoLadoDaPrevia(_ t: CGSize, lado: LadoDoTexto) -> Bool {
        normal(lado).empilhado && t.width > t.height
            && t.height < alturaDaTelaBaixa
            && t.width - larguraDaColunaLadoALado >= previaMinima
    }

    /// A forma desta tela com este lado: diz qual fração guardada vale (`FormaDaDivisao`).
    static func forma(_ t: CGSize, lado: LadoDoTexto) -> FormaDaDivisao {
        guard t.width > t.height else { return .retrato }
        return faixaAoLadoDaPrevia(t, lado: lado) ? .empilhadaLarga : .paisagem
    }

    /// **A conta.** `lado` já resolvido (`LadoDoTexto.resolvido`); `fracao`, a guardada para
    /// `forma(t, lado:)` ou a do arrasto; `alturaDaFaixa`, a medida.
    static func calcular(_ t: CGSize, lado l: LadoDoTexto, fracao pedida: Double, alturaDaFaixa hF: CGFloat,
                         previaEscondida: Bool) -> DivisaoDaTelaComCamera {
        let lado = normal(l)
        let W = t.width, H = t.height
        let forma = forma(t, lado: lado)
        let aoLado = forma == .empilhadaLarga
        let empilhado = lado.empilhado
        let eixo = max(1, empilhado ? H : W)
        // O teto do texto: o que a outra ponta precisa. Empilhado com a faixa ao lado, a banda leva a
        // prévia **ou** a faixa na altura (as duas ficam lado a lado), e não a soma: com a soma o texto
        // do iPhone X deitado parava em 84 pt, duas linhas.
        let precisa: CGFloat
        if aoLado {
            precisa = max(previaMinima, reservaDaFaixa)
        } else if empilhado {
            precisa = previaMinima + reservaDaFaixa
        } else {
            precisa = larguraDaColunaLadoALado
        }
        let teto = max(minimo, min(1 - minimo, Double(1 - precisa / eixo)))
        let f = min(teto, limitar(pedida))
        let n = (eixo * CGFloat(f)).rounded()
        // A coluna da faixa ao lado: sem nada nela (a tela cheia sem avisos mede a faixa em zero), a
        // prévia fica com a banda inteira, em vez de deixar 340 pt de preto ao lado dela. Na tela
        // cheia, então, um aviso que chega ou sai muda a largura da prévia — o mesmo "só a prévia
        // absorve a faixa" que, empilhado no pé, muda a altura dela.
        //
        // **A coluna fica à direita nas duas paisagens**, como pedido (30/09). Em `.landscapeLeft` a
        // lente está à direita: a faixa fica na banda de baixo, abaixo da altura do texto, e não
        // entre o texto e a lente (a regra de 24/09); fica, sim, do lado da lente. Pô-la do lado
        // oposto à lente seria uma linha (`lente` em vez de "à direita"), e a barra trocaria de lado
        // a cada meia-volta.
        let coluna: CGFloat = hF >= 1 ? larguraDaColunaLadoALado : 0
        var texto: CGRect, previa: CGRect, faixa: CGRect
        let borda: CGFloat
        var tetoDaFaixa: CGFloat?
        switch lado {
        case .baixo:
            texto = CGRect(x: 0, y: H - n, width: W, height: n)
            if aoLado {
                let banda = max(0, H - n)
                previa = CGRect(x: 0, y: 0, width: W - coluna, height: banda)
                faixa = CGRect(x: W - larguraDaColunaLadoALado, y: 0, width: larguraDaColunaLadoALado,
                               height: min(hF, banda))
                tetoDaFaixa = banda
            } else {
                faixa = CGRect(x: 0, y: 0, width: W, height: hF)
                previa = CGRect(x: 0, y: hF, width: W, height: max(0, H - n - hF))
            }
            borda = H - n
        case .esquerda:
            texto = CGRect(x: 0, y: 0, width: n, height: H)
            previa = CGRect(x: n, y: 0, width: W - n, height: max(0, H - hF))
            faixa = CGRect(x: n, y: H - hF, width: W - n, height: hF)
            borda = n
        case .direita:
            texto = CGRect(x: W - n, y: 0, width: n, height: H)
            previa = CGRect(x: 0, y: 0, width: W - n, height: max(0, H - hF))
            faixa = CGRect(x: 0, y: H - hF, width: W - n, height: hF)
            borda = W - n
        default: // .cima
            texto = CGRect(x: 0, y: 0, width: W, height: n)
            if aoLado {
                let banda = max(0, H - n)
                let hc = min(hF, banda)
                previa = CGRect(x: 0, y: n, width: W - coluna, height: banda)
                faixa = CGRect(x: W - larguraDaColunaLadoALado, y: H - hc, width: larguraDaColunaLadoALado,
                               height: hc)
                tetoDaFaixa = banda
            } else {
                previa = CGRect(x: 0, y: n, width: W, height: max(0, H - n - hF))
                faixa = CGRect(x: 0, y: H - hF, width: W, height: hF)
            }
            borda = n
        }
        if previaEscondida {
            tetoDaFaixa = nil
            if lado == .baixo {
                faixa = CGRect(x: 0, y: 0, width: W, height: hF)
                texto = CGRect(x: 0, y: hF, width: W, height: max(0, H - hF))
            } else {
                faixa = CGRect(x: 0, y: H - hF, width: W, height: hF)
                texto = CGRect(x: 0, y: 0, width: W, height: max(0, H - hF))
            }
        }
        return DivisaoDaTelaComCamera(lado: lado, texto: texto, previa: previa, faixa: faixa, borda: borda,
                                      eixo: eixo, forma: forma, fracao: f, teto: teto, tetoDaFaixa: tetoDaFaixa)
    }
}
