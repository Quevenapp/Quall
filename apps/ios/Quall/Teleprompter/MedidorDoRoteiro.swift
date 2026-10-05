import Foundation

/// **O instrumento do tranco**: quantos quadros a rolagem perde quando o layout muda, e onde foi o
/// tempo.
///
/// # Por que existe
///
/// O handover de 13/09 registrou "refazer o layout de 100 KB custa 250–340 ms na thread principal
/// do iPhone X" a partir de uma linha só (`layout: … ms`), que media o total da função e nada mais.
/// Um total não diz se o tempo está em medir o texto, em diagramá-lo ou em desenhá-lo — e é isso que
/// decide o conserto. Nem diz o que a pessoa vê, que é **a rolagem parar**: um quadro que não sai.
///
/// # O que conta, e como
///
/// - **Quadros perdidos** pelo relógio da tela: o `CADisplayLink` chama a cada vsync; quando a
///   thread principal fica presa, as chamadas que não aconteceram viram um intervalo maior entre
///   dois `timestamp`s. `perdidos = arredondar(intervalo / período) − 1`. Um tranco de 300 ms a
///   60 Hz são 17 quadros em que o texto não andou.
/// - **Uma janela por evento** (texto chegou, fonte mudou): abre no evento, recebe as etapas que a
///   vista mede (`etapa`), e fecha depois de ``silencioParaFechar`` sem atividade — tempo para o
///   quadro seguinte ao tranco chegar e ser contado dentro dela.
/// - **Fora das janelas**, o mesmo contador serve de piso: quantos quadros a rolagem perde sem
///   evento nenhum. É o que separa o tranco do layout do tranco do aparelho.
///
/// # O que ele não vê
///
/// Só a thread principal. Um quadro que o servidor de renderização (a GPU) atrasa sem a principal
/// travar não aparece aqui — é a mesma honestidade de `Fluidez`: o que se mede é a cadência com
/// que esta casca alimenta a tela.
///
/// # Puro de propósito
///
/// Não lê relógio nem toca UIKit: recebe os instantes de quem os tem (a vista). É o que deixa
/// exercitar as contas no MacBook, em `Testes/rodar.sh`.
final class MedidorDoRoteiro {
    /// Quanto silêncio fecha a janela de um evento, em segundos.
    static let silencioParaFechar = 1.0

    /// Uma etapa medida dentro de uma janela: o nome, a soma e quantas vezes ela aconteceu.
    struct Etapa: Equatable {
        let nome: String
        var ms: Double
        var vezes: Int
    }

    /// O relato de uma janela fechada.
    struct Janela: Equatable {
        var motivos: [String]
        var etapas: [Etapa]
        var notas: [String]
        var quadros: Int
        var perdidos: Int
        var maiorIntervaloMs: Double
        /// Do evento ao fim da última atividade, em ms.
        var duracaoMs: Double

        /// Uma linha `chave=valor`, para o diário e para quem lê o diário com um roteiro.
        func linha() -> String {
            var partes = ["tranco: evento=\(motivos.joined(separator: "+"))",
                          "perdidos=\(perdidos)", "quadros=\(quadros)",
                          String(format: "maior_ms=%.1f", maiorIntervaloMs),
                          String(format: "duracao_ms=%.1f", duracaoMs)]
            for e in etapas {
                partes.append(String(format: "%@_ms=%.1f", e.nome, e.ms) + (e.vezes > 1 ? "(x\(e.vezes))" : ""))
            }
            partes.append(contentsOf: notas)
            return partes.joined(separator: " ")
        }
    }

    // --- o piso: a rolagem fora das janelas -------------------------------------------------------

    private(set) var quadrosFora = 0
    private(set) var perdidosFora = 0
    private(set) var maiorForaMs = 0.0

    // --- a janela aberta --------------------------------------------------------------------------

    private var aberta: Janela?
    private var abertaEm = 0.0
    private var ultimaAtividade = 0.0
    private var ultimoTimestamp: Double?

    init() {}

    /// Um vsync. `contando` diz se o texto deveria estar andando (rolando e sem dedo): parado, um
    /// quadro que não sai não se vê, e não entra na conta — mas o instante fica, para o intervalo
    /// seguinte ser medido do lugar certo.
    ///
    /// Devolve a janela que fechou neste quadro, se alguma.
    @discardableResult
    func quadro(timestamp t: Double, periodo: Double, contando: Bool) -> Janela? {
        defer { ultimoTimestamp = t }
        if let anterior = ultimoTimestamp, contando, periodo > 0, t > anterior {
            let intervalo = t - anterior
            let perdidos = max(0, Int((intervalo / periodo).rounded()) - 1)
            if aberta != nil {
                aberta!.quadros += 1
                aberta!.perdidos += perdidos
                aberta!.maiorIntervaloMs = max(aberta!.maiorIntervaloMs, intervalo * 1000)
            } else {
                quadrosFora += 1
                perdidosFora += perdidos
                maiorForaMs = max(maiorForaMs, intervalo * 1000)
            }
        }
        return fecharSePassou(agora: t)
    }

    /// Um evento começou (ou outro entrou na janela que já estava aberta).
    func abrir(_ motivo: String, agora: Double) {
        if aberta == nil {
            aberta = Janela(motivos: [], etapas: [], notas: [], quadros: 0, perdidos: 0,
                            maiorIntervaloMs: 0, duracaoMs: 0)
            abertaEm = agora
        }
        if !aberta!.motivos.contains(motivo) { aberta!.motivos.append(motivo) }
        ultimaAtividade = max(ultimaAtividade, agora)
    }

    /// Uma etapa medida, terminada em `agora`. Sem janela aberta, abre uma com o nome da etapa: um
    /// layout que ninguém anunciou (a vista mudou de tamanho) também é tranco.
    func etapa(_ nome: String, ms: Double, agora: Double) {
        if aberta == nil { abrir(nome, agora: agora - ms / 1000) }
        if let i = aberta!.etapas.firstIndex(where: { $0.nome == nome }) {
            aberta!.etapas[i].ms += ms
            aberta!.etapas[i].vezes += 1
        } else {
            aberta!.etapas.append(Etapa(nome: nome, ms: ms, vezes: 1))
        }
        ultimaAtividade = max(ultimaAtividade, agora)
        aberta!.duracaoMs = (ultimaAtividade - abertaEm) * 1000
    }

    /// Uma nota `chave=valor` para a janela aberta (o tamanho do texto, o pulo da leitura).
    func nota(_ texto: String) {
        guard aberta != nil else { return }
        aberta!.notas.append(texto)
    }

    var temJanelaAberta: Bool { aberta != nil }

    /// Fecha a janela depois de ``silencioParaFechar`` sem atividade.
    func fecharSePassou(agora: Double) -> Janela? {
        guard let j = aberta, agora - ultimaAtividade >= MedidorDoRoteiro.silencioParaFechar else { return nil }
        aberta = nil
        return j
    }

    /// O piso desde a última chamada, numa linha, e zera.
    func lerPiso() -> String {
        defer { quadrosFora = 0; perdidosFora = 0; maiorForaMs = 0 }
        return String(format: "rolagem sem evento: quadros=%d perdidos=%d maior_ms=%.1f",
                      quadrosFora, perdidosFora, maiorForaMs)
    }
}
