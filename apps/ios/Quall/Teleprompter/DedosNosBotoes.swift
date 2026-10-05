import Foundation

/// Os dois botões do "Segurar para rolar" (`docs/contrato-teleprompter.md` §12). **O mapeamento
/// mora aqui, num lugar só**, e a inversão troca o sentido aqui mesmo.
///
/// "Inverter botões" (pedido do usuário, 14/09 à tarde: "como a imagem está invertida no espelho do
/// prompter, os botões do controlador segure para rolar ficam invertidos"): **a seta e o rótulo ficam
/// no lugar** — em cima "Rolar para cima" ↑, embaixo "Rolar para baixo" ↓ —, e **a ação e a legenda
/// trocam juntas**, para a pessoa sempre ver o que o botão faz.
enum BotaoDeSegurar: String, Equatable {
    /// "Rolar para cima": sem inversão, o texto **volta** (`hold(t, true)`).
    case cima
    /// "Rolar para baixo": sem inversão, o texto **avança** (`hold(t, false)`).
    case baixo

    /// O `backwards` do `quall_teleprompter_hold`.
    func paraTras(invertido: Bool) -> Bool { (self == .cima) != invertido }
    /// O que o botão faz, dito embaixo do rótulo: troca junto com a ação.
    func legenda(invertido: Bool) -> String { paraTras(invertido: invertido) ? tr("volta o texto") : tr("avança o texto") }
    var rotulo: String { self == .cima ? tr("Rolar para cima") : tr("Rolar para baixo") }
    var simbolo: String { self == .cima ? "arrow.up" : "arrow.down" }
}

/// **Os dedos nos dois botões**, sem UIKit: testado no MacBook por `Testes/rodar.sh`.
///
/// As regras do pedido (14/09):
///
/// - o dedo que encosta num botão aperta; o que encosta fora deles não faz nada;
/// - **dois dedos: vale o último botão apertado**;
/// - o dedo que **sai do botão** onde encostou deixa de contar (e não aperta o outro ao passar
///   por ele: é o que evita trocar de sentido sem querer);
/// - o que tira o dedo, e o toque cancelado pelo sistema, deixam de contar;
/// - o `release` só vem quando **nenhum** dedo sobra num botão;
/// - **nada aperta de novo sozinho**: quando o texto para sem ninguém soltar (a queda, o silêncio,
///   a pausa no prompter, o fim do texto, o aperto recusado), os dedos que estavam nos botões
///   ficam **mortos** — não voltam a valer nem quando outro dedo sai, só depois de sair da tela. O
///   mesmo vale para o dedo que encostou com os botões desligados (revisão adversarial, 14/09: um
///   segundo dedo que saía fazia o primeiro, já parado, apertar de novo).
///
/// `ativo` é o botão que vale agora; `nil` é soltar.
struct DedosNosBotoes: Equatable {
    private var dedos: [Int: (botao: BotaoDeSegurar, ordem: Int)] = [:]
    private var mortos: Set<Int> = []
    private var contador = 0

    static func == (a: DedosNosBotoes, b: DedosNosBotoes) -> Bool {
        a.ativo == b.ativo && a.quantos == b.quantos && a.mortosNaTela == b.mortosNaTela
    }

    init() {}

    /// O botão do dedo mais recente que ainda está no botão onde encostou.
    var ativo: BotaoDeSegurar? { dedos.values.max(by: { $0.ordem < $1.ordem })?.botao }
    /// Quantos dedos seguram agora.
    var quantos: Int { dedos.count }
    /// Dedos na tela que não contam (ver o cabeçalho).
    var mortosNaTela: Int { mortos.count }
    /// "Inverter botões" só vale **sem dedo nenhum num botão de rolar** — nem o que segura, nem o
    /// morto: trocar o sentido debaixo de um dedo mudaria o que ele faz sem ele saber.
    var podeInverter: Bool { dedos.isEmpty && mortos.isEmpty }

    /// Um dedo encostou (`botao` nil: fora dos dois).
    mutating func encostou(_ dedo: Int, em botao: BotaoDeSegurar?) {
        mortos.remove(dedo)
        guard let botao else { dedos[dedo] = nil; return }
        contador += 1
        dedos[dedo] = (botao, contador)
    }

    /// Um dedo encostou num botão com os botões desligados: não conta, nem quando eles ligarem.
    mutating func encostouSemValer(_ dedo: Int) {
        dedos[dedo] = nil
        mortos.insert(dedo)
    }

    /// Um dedo andou e agora está sobre `botao` (nil: fora dos dois). Se saiu do botão onde
    /// encostou, deixa de contar — mesmo que tenha entrado no outro.
    mutating func moveu(_ dedo: Int, para botao: BotaoDeSegurar?) {
        guard let d = dedos[dedo], d.botao != botao else { return }
        dedos[dedo] = nil
    }

    /// O dedo saiu da tela, ou o sistema cancelou o toque.
    mutating func tirou(_ dedo: Int) {
        dedos[dedo] = nil
        mortos.remove(dedo)
    }

    /// O texto parou sem ninguém soltar: os dedos que estão nos botões morrem.
    mutating func pararTodos() {
        mortos.formUnion(dedos.keys)
        dedos.removeAll()
    }

    /// Tudo solto (segundo plano, a tela fechando, o modo desligado).
    mutating func soltarTudo() {
        dedos.removeAll()
        mortos.removeAll()
    }
}
