import Foundation

/// A lista "O que transmitir" e a escolha dentro dela, com as duas levas do catálogo.
///
/// # O defeito que isto conserta
///
/// A lista chega em duas metades (`CatalogoDeFontes.telas` e `.cameras`), e cada metade que chegava
/// recompunha `fontes = telas + cameras` e conferia a escolha **contra a lista pela metade**. O
/// Atualizar zerava as duas metades antes de pedir, então a primeira que voltava não tinha a outra, a
/// escolha dada como "sumiu" era dela, e o recuo `fontes.first` escolhia outra coisa. O registro
/// deste MacBook mostra: em 10/09 às 16:51:42, "Tela estendida" escolhida, Atualizar, as câmeras
/// voltaram 13 ms antes das telas, e a escolha virou "Câmera do MacBook Air" (a revisão de código de
/// 18/09, achado 1 do catálogo). Um clique em Espelhar transmitiria a câmera da pessoa no lugar da
/// tela, sem nada ter sido desplugado.
///
/// # As regras
///
/// 1. **Só o "sumiu" espera a lista inteira** (nenhuma metade pendente), e as metades velhas ficam até
///    as novas chegarem. O que depende só do que **está** na lista (a escolha que continua, a que
///    volta, o padrão da abertura) é decidido na chegada da metade que o traz.
/// 2. **Depois de uma escolha, nunca se escolhe outra no lugar.** A que sumiu deixa o seletor sem
///    escolha, com o aviso. Se **a mesma** voltar — o mesmo id **e** o mesmo nome —, ela volta
///    escolhida e o aviso sai. Com o nome dela na lista e **outro id** (o Sidecar volta assim:
///    `tela:64` saiu e `tela:66` voltou, registro de 10/09), nada é escolhido, mas o aviso sai,
///    porque diria que ela sumiu com o nome dela na tela. É a regra do Windows
///    (`apps/windows/src/catalogo_de_cameras.rs`, `reescolher`).
/// 3. **O padrão da abertura é a primeira tela**, decidido quando **as telas** chegam, sem esperar as
///    câmeras: na primeira abertura a metade das câmeras espera a pessoa responder o diálogo de
///    permissão, e o Espelhar ficaria cinza até lá (a reconferência de 18/09). Nunca uma câmera: sem
///    tela nenhuma (a Gravação de Tela negada), fica sem escolha.
public struct SeletorDeFontes {
    public private(set) var telas: [FonteDeCaptura] = []
    public private(set) var cameras: [FonteDeCaptura] = []
    /// Quantas metades foram pedidas e ainda não voltaram.
    public private(set) var pendentes = 0
    public private(set) var escolhida: FonteDeCaptura?
    /// A escolhida que saiu da lista, enquanto a pessoa não escolher outra.
    public private(set) var sumida: FonteDeCaptura?
    /// Já houve escolha nesta vida do app (o padrão da abertura conta): daqui em diante, nada é
    /// escolhido por conta própria.
    public private(set) var jaHouveEscolha = false

    public init() {}

    /// Telas primeiro: num Mac é o que a pessoa quase sempre quer transmitir, e a ordem não pode
    /// depender de qual metade voltou antes.
    public var fontes: [FonteDeCaptura] { telas + cameras }
    public var completo: Bool { pendentes <= 0 }

    /// O que a chegada de uma metade fez com a escolha.
    public enum Mudanca: Equatable {
        case nenhuma
        /// A primeira tela, na abertura.
        case padrao(FonteDeCaptura)
        /// A escolhida saiu da lista inteira: sem escolha, e o aviso.
        case sumiu(FonteDeCaptura)
        /// A que tinha sumido voltou, com o mesmo id e o mesmo nome: escolhida de novo, e o aviso sai.
        case voltou(FonteDeCaptura)
        /// Uma fonte com o nome da que sumiu, e outro id: continua sem escolha, e o aviso sai.
        case reapareceu(FonteDeCaptura)
    }

    /// O Atualizar: as duas metades. **Não zera** as metades velhas: a lista continua de pé até as
    /// novas chegarem. **Soma** às pendentes: um Atualizar por cima de uma metade de telas ainda em
    /// voo não pode dar a lista por inteira antes de as câmeras voltarem (a reconferência).
    public mutating func pedirAsDuas() {
        pendentes += 2
    }

    /// Só a metade das telas (o aviso do AppKit de que as telas mudaram).
    public mutating func pedirMaisUma() {
        pendentes += 1
    }

    /// A pessoa (ou o `--fonte` da bancada) escolheu.
    public mutating func escolher(_ fonte: FonteDeCaptura) {
        escolhida = fonte
        sumida = nil
        jaHouveEscolha = true
    }

    /// A linha "Tela estendida" trocou de modo: troca na lista e na escolha, sem mexer em mais nada.
    public mutating func trocar(_ antiga: (FonteDeCaptura) -> Bool, por nova: FonteDeCaptura) {
        telas = telas.map { antiga($0) ? nova : $0 }
        if let e = escolhida, antiga(e) { escolhida = nova }
        if let s = sumida, antiga(s) { sumida = nova }
    }

    /// Uma metade voltou.
    public mutating func receber(_ fontes: [FonteDeCaptura], saoTelas: Bool) -> Mudanca {
        if saoTelas { telas = fontes } else { cameras = fontes }
        pendentes = max(0, pendentes - 1)
        let lista = self.fontes
        if let e = escolhida {
            if let atual = lista.first(where: { $0.id == e.id }) {
                // A mesma fonte, com o detalhe (a resolução) de agora.
                escolhida = atual
                return .nenhuma
            }
            // Fora da lista só vale como "sumiu" com a lista inteira: pela metade, ela pode estar na
            // metade que ainda não voltou.
            guard completo else { return .nenhuma }
            escolhida = nil
            sumida = e
            return .sumiu(e)
        }
        if let s = sumida {
            if let volta = lista.first(where: { $0.id == s.id && $0.nome == s.nome }) {
                escolhida = volta
                sumida = nil
                return .voltou(volta)
            }
            if let parecida = lista.first(where: { $0.nome == s.nome }) {
                return .reapareceu(parecida)
            }
            return .nenhuma
        }
        if !jaHouveEscolha, let tela = telas.first(where: { $0.ehTela }) {
            escolhida = tela
            jaHouveEscolha = true
            return .padrao(tela)
        }
        return .nenhuma
    }

    // MARK: - o aviso no conselho

    /// O conselho com o aviso da fonte que sumiu **acrescentado**: o que já estava (o motivo do fim de
    /// uma sessão) fica na frente.
    public static func comOAviso(_ conselho: String, _ aviso: String) -> String {
        let atual = conselho.trimmingCharacters(in: .whitespacesAndNewlines)
        return atual.isEmpty ? aviso : "\(atual) \(aviso)"
    }

    /// O conselho sem o aviso, e com o resto intacto. Se o aviso não está mais lá (o fim de uma
    /// sessão escreveu por cima dele), volta igual: o motivo do fim nunca é apagado junto.
    public static func semOAviso(_ conselho: String, _ aviso: String) -> String {
        guard !aviso.isEmpty, let faixa = conselho.range(of: aviso) else { return conselho }
        var resto = conselho
        resto.removeSubrange(faixa)
        return resto.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
