import Foundation

/// **A distribuição dos intervalos entre entregas ao sumidouro da câmera** — a fluidez desta
/// casca, e ela não é a mesma coisa que a do app.
///
/// ## Por que a média não serve, e por que ela existia
///
/// Em 01/09/2026 o usuário olhou para a tela e disse que faltava fluidez. A média de `fila→tela`
/// da mesma corrida dizia **6,4 ms** e estava **certa** — e não respondia nada: o pior caso era
/// **226 ms**. Média não vê tranco: um segundo com 29 quadros pontuais e um buraco de 200 ms tem a
/// mesma média de um segundo regular. Com o instrumento pronto, o mesmo A10s deu:
///
///     Wi-Fi 2,4 GHz : fluidez_ms=[n=2541 p50=32 p95=115 max=241]  trancos=208
///     cabo USB      : fluidez_ms=[n=2639 p50=34 p95=39  max=83 ]  trancos=0
///
/// `p50` idêntico nos dois. Toda a diferença está na cauda.
///
/// Esta casca tinha o mesmo buraco de instrumento, e num caso que já mordeu: numa corrida de seis
/// câmeras num MacBook a CPU somada foi 20 % de um núcleo e o `fps` não se moveu, enquanto o Dell,
/// na mesma carga, teve 87 estouros de fila local com zero pacote perdido. O custo do host não
/// aparece na CPU; aparece na cauda e na fila. `entregues` e `descartados` diziam "o host
/// aguentou" — que é exatamente o instrumento que quase fez o orquestrador responder errado.
///
/// ## Aqui não há tela: há um consumidor do outro lado
///
/// No app do macOS o ponto de marca é a aceitação pela `AVSampleBufferDisplayLayer`. Aqui **não
/// existe camada de exibição**. O ponto é a **entrega ao sumidouro** — o `CMSimpleQueueEnqueue` no
/// fluxo de entrada do CoreMediaIO, em ``ClienteDoSumidouro/empurrar(_:)`` —, que é o que um Zoom
/// ou um OBS de fato recebe. Depois dele o quadro atravessa a extensão, o `registerassistantservice`
/// e o AVFoundation do app consumidor, e nada disso é medido por este número.
///
/// A consequência é que os dois `fluidez_ms` do macOS **não são intercambiáveis**: medem o mesmo
/// tipo de grandeza em pontos diferentes do caminho. Comparar uma corrida do app com uma corrida da
/// câmera pelo `p95` é comparar duas perguntas.
///
/// ## Honestidade obrigatória: "entregue", não "consumido"
///
/// Quem lê o quadro é a extensão, e depois dela o app consumidor — **depois** de nós entregarmos.
/// O instante que entra aqui é *"a hora em que este quadro foi entregue à fila"*, não *"a hora em
/// que ele apareceu para alguém"*. Está escrito porque um número que se apresenta como uma coisa e
/// é outra já custou uma semana a este projeto (`packets_missing`), e porque esta casca em
/// particular tem três processos entre a fila e o olho.
///
/// ## O intervalo é entre entregas, e isso é escolha
///
/// Não entre chegadas da rede, não entre decodificações. É o único ponto do caminho deste processo
/// que corresponde ao que o consumidor recebe, e é por isso que ele mede também o custo das
/// políticas desta casca — a porta de ``Receptor/entregar(_:suspeito:)``, que **não** empurra o
/// quadro de cadeia condenada, aparece aqui como intervalo maior. É exatamente o que ela custa e o
/// que precisava ficar visível; medir chegadas a esconderia. O mesmo vale para o quadro largado
/// quando a fila de 3 está cheia: ele não foi entregue, e o preço dele é o intervalo seguinte.
///
/// ## `trancos` é convenção de comparação, não afirmação perceptual
///
/// A 30 fps o orçamento é 33 ms. `trancos` conta os intervalos acima de ``trancoMs`` — três tempos
/// de quadro. **Não** se está afirmando que 100 ms é o limiar em que uma pessoa percebe; o que se
/// afirma é que duas corridas com o mesmo emissor e a mesma origem podem ser comparadas por esse
/// número. Quem quiser outro corte tem os percentis ao lado.
///
/// ## Cópia declarada, e onde está a prova
///
/// A peça de referência é `apps/windows/src/fluidez.rs`, onde o contrato está escrito. A cópia do
/// app macOS é `apps/macos/Sources/QuallReceptorKit/Fluidez.swift`, e ela tem suíte de unidade;
/// esta não tem alvo de teste no portão — `project.yml` tem dois alvos, o app e a extensão, e
/// criar um terceiro mexeria no conjunto de fontes, que já derrubou a câmera do sistema três vezes
/// nesta máquina. A prova vem por fora, no molde de `bancada/provar-janela`: um `main.swift`
/// compilado **junto deste arquivo**, e não copiando dele. Ver `bancada/provar-fluidez/`.
///
/// Este arquivo mora em `Fontes/App` e **não** em `Fontes/Comum` de propósito: `construir.sh`
/// calcula a impressão digital da extensão sobre `Fontes/Extensao` + `Fontes/Comum`, e um arquivo
/// novo ali trocaria a versão de uma extensão já aprovada por nada.
struct Fluidez {

    /// O corte de `trancos`: três tempos de quadro a 30 fps. Ver a doc do tipo — é **convenção de
    /// comparação**, e a distribuição completa sai ao lado para quem quiser outro corte.
    static let trancoMs: UInt64 = 100

    /// Teto de amostras guardadas. A 30 fps são ~5 minutos de sessão; passado isso a distribuição
    /// para de crescer em vez de a sessão longa comer memória. Mesmo teto da peça do Windows.
    ///
    /// O que passa do teto é **dito** — ver o sufixo em ``linha`` —, e não fingido: um `n` que se
    /// apresenta como a sessão inteira quando não é seria o mesmo defeito de sempre, com outra
    /// roupa.
    static let maximoDeAmostras = 10_000

    /// O instante da entrega anterior, em microssegundos de `CLOCK_UPTIME_RAW`. `nil` até a
    /// primeira — ver ``entregou(agoraUs:)``.
    private var anteriorUs: UInt64?
    private var intervalosUs: [UInt64] = []
    /// Quantas amostras foram descartadas por teto.
    private var descartadas: UInt64 = 0

    init() {}

    /// Marca que um quadro foi **entregue** à fila do sumidouro agora.
    ///
    /// O nome é `entregou` e não `apresentou` — que é o da cópia do app — porque esta casca não
    /// apresenta nada: ela entrega a um consumidor. A diferença está na doc do tipo, e ela é a
    /// razão de os dois números não serem intercambiáveis.
    ///
    /// A primeira chamada **só ancora**: não existe intervalo antes do primeiro quadro, e contar o
    /// tempo desde a abertura da sessão como se fosse um poria a subida do ICE e a espera pelo
    /// primeiro IDR dentro da distribuição da imagem — um `max` de segundos em toda corrida
    /// saudável, que é um instrumento que ninguém lê duas vezes.
    ///
    /// A subtração é **saturante**. O relógio é monotônico e não deveria andar para trás, mas uma
    /// casca que assume isso e erra publica dezoito quintilhões em vez de um zero.
    mutating func entregou(agoraUs: UInt64) {
        if let antes = anteriorUs {
            let us = agoraUs > antes ? agoraUs - antes : 0
            if intervalosUs.count < Fluidez.maximoDeAmostras {
                intervalosUs.append(us)
            } else {
                descartadas &+= 1
            }
        }
        anteriorUs = agoraUs
    }

    /// Zera para uma sessão nova, **âncora inclusive**. Sem largar a âncora, o intervalo entre duas
    /// sessões entraria na distribuição como o maior tranco da corrida.
    mutating func reiniciar() {
        anteriorUs = nil
        intervalosUs.removeAll(keepingCapacity: true)
        descartadas = 0
    }

    /// Quantos intervalos passaram de ``trancoMs``. Corte **estrito**: exatamente no limiar não
    /// conta. Fica fixado para que a comparação entre duas corridas não dependa de arredondamento.
    var trancos: UInt64 {
        UInt64(intervalosUs.lazy.filter { $0 > Fluidez.trancoMs * 1_000 }.count)
    }

    /// `fluidez_ms=[n p50 p95 max] trancos=…`, em milissegundos.
    ///
    /// Quatro números e não um, de propósito, e na mesma forma de `sem_referencia_ms`: numa medida
    /// de dano visual **a cauda é o dano**, e este repositório já pagou por relatório que mostrava
    /// só o centro.
    ///
    /// O índice do percentil é `floor(q · (n-1))`, que é literalmente o da peça do Windows — a
    /// referência do contrato, e não a convenção local de `Receptor.resumo`, porque este número é
    /// comparado entre plataformas.
    var linha: String {
        let sufixo = descartadas > 0 ? " (+\(descartadas) além do teto)" : ""
        guard !intervalosUs.isEmpty else {
            return "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0" + sufixo
        }
        let ordenados = intervalosUs.sorted()
        func q(_ p: Double) -> Double {
            let i = min(Int(p * Double(ordenados.count - 1)), ordenados.count - 1)
            return Double(ordenados[i]) / 1000
        }
        return String(format: "fluidez_ms=[n=%d p50=%.0f p95=%.0f max=%.0f] trancos=%llu%@",
                      ordenados.count, q(0.50), q(0.95),
                      Double(ordenados[ordenados.count - 1]) / 1000,
                      trancos, sufixo)
    }
}
