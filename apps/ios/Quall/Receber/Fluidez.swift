import Foundation

/// **A distribuição dos intervalos entre apresentações** — o número que faltava para "sem fluidez"
/// deixar de ser impressão.
///
/// Gêmeo de `apps/windows/src/fluidez.rs`, e o contrato é o de lá, literal: a mesma linha, os
/// mesmos nomes, o mesmo corte, a mesma âncora. Duas corridas do mesmo emissor em receptores
/// diferentes só podem ser postas lado a lado se `fluidez_ms` quiser dizer a mesma coisa nos dois
/// — e nomes de contrato deste projeto são fixados, não sugeridos (`docs/regras-de-frente.md`).
///
/// # Por que a média não serve, e por que ela existia
///
/// Em 01/09/2026 o usuário olhou para a tela e disse que faltava fluidez. A média de `fila→tela`
/// da mesma corrida dizia **6,4 ms** e estava **certa** — e não respondia nada: o pior caso era
/// **226 ms**, e é nele que a pessoa vê a imagem parar. Média não vê tranco: um segundo com 29
/// quadros pontuais e um buraco de 200 ms tem a mesma média de um segundo regular.
///
/// O que se vê é o **intervalo entre um quadro e o seguinte na tela**, e o que descreve isso é a
/// distribuição dele, não o centro. Com o instrumento pronto, o mesmo A10s deu `p50` idêntico nos
/// dois enlaces (32 e 34 ms) e `max` de 241 contra 83, `trancos` de 208 contra 0. **Toda a
/// diferença está na cauda**, e é ela que o olho vê.
///
/// # O intervalo é entre **apresentações**, e isso é escolha
///
/// Não entre chegadas, não entre decodificações: entre os instantes em que um quadro de fato foi
/// entregue para a tela. É o único ponto do caminho que corresponde ao que o olho recebe, e é por
/// isso que ele mede também o custo das políticas desta casca — a **porta** de
/// `SessaoDeRecepcao` (o congelamento do quadro cuja referência foi condenada) aparece aqui como
/// intervalo maior, que é exatamente o que ela custa e o que precisava ficar visível. Medir
/// chegadas esconderia a porta: os quadros retidos chegam, decodificam e não vão para o vidro.
///
/// # A honestidade que este arquivo tem de carregar: "entregue" não é "apareceu"
///
/// **No iOS quem põe o pixel na tela é a `AVSampleBufferDisplayLayer`, depois de a gente
/// entregar.** O instante medido aqui é *"a hora em que este quadro foi entregue para a camada de
/// exibição"*, não *"a hora em que ele apareceu"*. Não existe API do iOS que confirme
/// apresentação — é a mesma limitação que fez `exibidos` virar `enfileirados` em 2026-08-28, e a
/// mesma que `docs/receptor-ios.md` já declara em "O que este documento não afirma".
///
/// É o melhor disponível, e fica dito: um número que se apresenta como uma coisa e é outra já
/// custou uma semana a este projeto (`packets_missing`). O que este tipo mede é a **cadência com
/// que esta casca alimenta o vidro**; o que o compositor faz depois dela não está aqui.
///
/// # `trancos` é convenção de comparação, não afirmação perceptual
///
/// A 30 fps o orçamento é 33 ms. `trancos` conta os intervalos acima de ``trancoMs`` — três
/// tempos de quadro. **Não** se está afirmando que 100 ms é o limiar em que uma pessoa percebe; o
/// que se afirma é que duas corridas com o mesmo emissor e a mesma origem podem ser comparadas
/// por esse número. Quem quiser outro corte tem os percentis ao lado.
///
/// # Puro de propósito
///
/// Não toca relógio, não toca camada, não toca núcleo: recebe o instante de quem o tem. É o que
/// permite exercitar a distribuição inteira no MacBook, em `Testes/rodar.sh`, sem aparelho e sem
/// toque humano — a mesma disciplina de `Carimbo` e de `Enderecos`.
struct Fluidez {
    /// O corte de `trancos`: três tempos de quadro a 30 fps. Ver a nota do tipo — é convenção de
    /// comparação, e a distribuição completa sai junto para quem quiser outro corte.
    static let trancoMs: UInt64 = 100

    /// Teto de amostras guardadas. A 30 fps são ~5 minutos de sessão; passado isso a distribuição
    /// para de crescer em vez de a sessão longa comer memória. Mesmo teto do gêmeo do Windows.
    static let maximoDeAmostras = 10_000

    /// A entrega anterior. `nil` **é** o estado de "ainda não houve quadro nenhum", e não zero:
    /// zero é um instante válido de um relógio monotônico recém-zerado.
    private var anteriorUs: UInt64?
    private var intervalosUs: [UInt64] = []
    /// Quantas amostras foram descartadas por teto — dito em voz alta na linha, em vez de fingir
    /// que o `n` é a sessão inteira.
    private var descartadas: UInt64 = 0

    init() {}

    /// Marca que um quadro foi **entregue para a tela** agora, em microssegundos do relógio
    /// monotônico (`Medidas.agoraUs`).
    ///
    /// A primeira chamada **só ancora**: não existe intervalo antes do primeiro quadro, e contar o
    /// tempo desde a abertura da sessão como se fosse um intervalo poria a subida do ICE dentro da
    /// distribuição da imagem — a corrida do iPad de 01/09 sobe em ~50 ms e o pareamento por PIN
    /// custa mais que isso, o que sozinho plantaria um tranco em toda sessão nova.
    mutating func apresentou(_ agoraUs: UInt64) {
        if let antes = anteriorUs {
            // `Medidas.delta` e não `-`: a subtração de `UInt64` sem guarda é a família de defeito
            // que matou a corrida de 464 s do degrau 4, e um relógio que não avança entre duas
            // chamadas é possível.
            let us = Medidas.delta(agoraUs, antes)
            if intervalosUs.count < Fluidez.maximoDeAmostras {
                intervalosUs.append(us)
            } else {
                descartadas &+= 1
            }
        }
        anteriorUs = agoraUs
    }

    /// Quantos intervalos passaram de ``trancoMs``.
    ///
    /// O corte é **estrito**: exatamente no limiar não conta. Fica fixado para que a comparação
    /// entre duas corridas não dependa de arredondamento.
    var trancos: UInt64 {
        UInt64(intervalosUs.lazy.filter { $0 > Fluidez.trancoMs * 1000 }.count)
    }

    /// `fluidez_ms=[n=… p50=… p95=… max=…] trancos=…`, em milissegundos.
    ///
    /// Quatro números e não um, porque este repositório já pagou por relatório que mostrava só o
    /// centro. A forma é a de `sem_referencia_ms`, de propósito.
    ///
    /// **O índice do percentil é o do gêmeo do Windows — truncado, não arredondado.** A
    /// `SessaoDeRecepcao.resumo`, que formata `sem_referencia_ms` na mesma linha, arredonda
    /// (`+ 0,5`); a diferença é de um posto e só aparece em amostra pequena. Aqui manda a
    /// comparabilidade entre os dois receptores, não a simetria com o campo vizinho, porque
    /// `fluidez_ms` é um número que se põe lado a lado com o de outra casca.
    func linha() -> String {
        let sufixo = descartadas > 0 ? " (+\(descartadas) além do teto)" : ""
        // Sessão sem intervalo nenhum não afirma nada — e não divide por zero. `n=0` é o que
        // distingue "não medi" de "medi zero", e é por isso que ele sai por extenso em vez de a
        // linha sumir.
        guard !intervalosUs.isEmpty else {
            return "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0" + sufixo
        }
        let v = intervalosUs.sorted()
        func p(_ q: Double) -> Double {
            Double(v[min(v.count - 1, Int(q * Double(v.count - 1)))]) / 1000
        }
        return String(format: "fluidez_ms=[n=%d p50=%.0f p95=%.0f max=%.0f] trancos=%llu%@",
                      v.count, p(0.50), p(0.95),
                      Double(v[v.count - 1]) / 1000, trancos, sufixo)
    }
}
