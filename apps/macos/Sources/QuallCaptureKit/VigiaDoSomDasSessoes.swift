import Foundation

/// **A sessão cujo som falha sozinha**, na tela estendida com som (`docs/som-no-receptor.md` §12.1,
/// D2; crítica 13 e 15, M3, o lado do Mac).
///
/// # Por que existe
///
/// O ``DonoDoSom`` dá o som ao primeiro receptor que toca. Se o som **dessa** sessão falha — a
/// captura de som dela para ou nunca começa, o conversor dela falha, a track dela recusa os
/// quadros — e o vídeo segue, ninguém toca: as outras sessões capturam e calam. No Windows o M3
/// fechou pelo `sem_som` do receptor. No Mac, a sessão que não consegue abrir a track de som nem
/// chega a transmitir (`NucleoDeRede` falha a sessão quando a contagem de tracks não bate), então o
/// que sobra é o som que falha **depois**: é isto que este vigia vê, e o `Emissor` chama
/// ``DonoDoSom/naoToca(_:)`` com o que ele disser.
///
/// # O que conta como "ficou sem som"
///
/// 1. **A captura**: nenhuma amostra nova em ``janelaMs``, enquanto **outra** sessão com som trouxe
///    amostras dentro dessa mesma janela. É uma comparação de propósito: não está medido que o
///    ScreenCaptureKit entrega blocos durante o silêncio (§13 do `som-no-receptor.md`), e sem
///    comparação um Mac em silêncio tiraria o som de todo mundo. As amostras da outra sessão têm de
///    ter chegado **entre** duas leituras dela que caem dentro da janela desta — as leituras de cada
///    sessão saem do relato dela, uma por segundo, fora de fase, e um som que começa na borda não
///    pode parecer falha. A sessão só é julgada depois de ``janelaMs`` no ar (o arranque da captura).
/// 2. **A track**: ``recusasParaFalhar`` quadros recusados em ``janelaMs`` sem nenhum aceito. Só a
///    dona manda quadro; a calada não recusa nada (`SessaoDeEmissao.enviarUmQuadroDeAudio`). O
///    primeiro quadro recusado de toda sessão (a dívida 25) fica muito abaixo do limiar.
///
/// Uma sessão sozinha não é julgada pela captura (não há com quem comparar, e também não há a quem
/// passar o som). Puro, sem relógio: quem chama passa as horas.
///
/// # A volta (crítica 18, F2)
///
/// A falta **pela captura** volta: quando as amostras da sessão voltam a crescer, ela sai de
/// ``semSom`` e o `Emissor` a faz candidata de novo (``DonoDoSom/voltouOSom(_:toca:)``), **sem tomar
/// o som** de quem o ganhou. É o conserto da borda de silêncio para som: se o SCK não entrega blocos
/// no silêncio, cada `SCStream` recebe o primeiro bloco na sua fila, e a sessão cujo relato cai logo
/// depois do da outra, antes do bloco dela chegar, era julgada sem som para sempre (o revisor
/// reproduziu 3 em 9 900 transições). A falta **pela track** não volta: uma sessão calada devolve
/// "aceito" a todo quadro (`SessaoDeEmissao.enviarUmQuadroDeAudio`), então os aceitos dela não dizem
/// nada da track.
public struct VigiaDoSomDasSessoes: Equatable {
    /// A janela de cada julgamento.
    public static let janelaMs: UInt64 = 3_000
    /// Quadros recusados na janela, sem nenhum aceito, para dizer que a track não leva o som. O
    /// quadro de som do Mac é de 20 ms: 3 s são 150 quadros.
    public static let recusasParaFalhar = 25

    /// O que uma sessão contou até `ms` (o relógio monotônico de quem chama).
    public struct Leitura: Equatable {
        public var id: Int
        public var ms: UInt64
        /// Amostras por canal que saíram do conversor (`Contadores.amostrasDeAudio`).
        public var amostras: Int
        public var recusados: Int
        public var enviados: Int

        public init(id: Int, ms: UInt64, amostras: Int, recusados: Int, enviados: Int) {
            self.id = id
            self.ms = ms
            self.amostras = amostras
            self.recusados = recusados
            self.enviados = enviados
        }
    }

    /// Uma sessão que ficou sem som, e o porquê, em português, para o registro.
    public struct Falta: Equatable {
        public var id: Int
        public var motivo: String
    }

    /// O que mudou numa leitura: quem ficou sem som, e quem, sem som pela captura, voltou a ter.
    public struct Veredito: Equatable {
        public var faltas: [Falta] = []
        public var voltas: [Int] = []
    }

    private var historico: [Int: [Leitura]] = [:]
    private var primeira: [Int: UInt64] = [:]
    /// As amostras da sessão quando ela ficou sem som pela captura (a da track não volta).
    private var amostrasNaFalta: [Int: Int] = [:]
    /// As sessões que estão sem som.
    public private(set) var semSom: Set<Int> = []

    public init() {}

    /// As leituras mais novas das sessões com som no ar (quem não vem mais é esquecido). Devolve as
    /// que ficaram sem som **agora**, e as que voltaram a ter.
    public mutating func observar(_ leituras: [Leitura], agoraMs: UInt64) -> Veredito {
        let presentes = Set(leituras.map(\.id))
        for id in historico.keys where !presentes.contains(id) { esquecer(id) }
        for l in leituras {
            var pontos = historico[l.id] ?? []
            if let ultimo = pontos.last, l.ms <= ultimo.ms { continue }
            if primeira[l.id] == nil { primeira[l.id] = l.ms }
            pontos.append(l)
            // Guarda o bastante para uma janela inteira atrás da mais nova, e um ponto antes dela.
            let limite = agoraMs > 3 * VigiaDoSomDasSessoes.janelaMs ? agoraMs - 3 * VigiaDoSomDasSessoes.janelaMs : 0
            while pontos.count > 2, pontos[1].ms < limite { pontos.removeFirst() }
            historico[l.id] = pontos
        }

        var veredito = Veredito()
        // A volta: sem som pela captura, e as amostras cresceram desde a falta.
        for id in historico.keys.sorted() where semSom.contains(id) {
            guard let na = amostrasNaFalta[id], let fim = historico[id]?.last, fim.amostras > na else { continue }
            semSom.remove(id)
            amostrasNaFalta[id] = nil
            veredito.voltas.append(id)
        }

        var faltas: [Falta] = []
        for id in historico.keys.sorted() where !semSom.contains(id) && !veredito.voltas.contains(id) {
            guard let pontos = historico[id], let fim = pontos.last,
                  let base = pontos.last(where: { $0.ms + VigiaDoSomDasSessoes.janelaMs <= fim.ms }) else { continue }
            let segundos = String(format: "%.1f", Double(fim.ms - base.ms) / 1000)

            let recusados = fim.recusados - base.recusados
            if recusados >= VigiaDoSomDasSessoes.recusasParaFalhar && fim.enviados == base.enviados {
                faltas.append(Falta(id: id, motivo: "a track recusou os \(recusados) quadros de som dos últimos \(segundos) s"))
                continue
            }

            guard let nasceu = primeira[id], base.ms >= nasceu + VigiaDoSomDasSessoes.janelaMs,
                  fim.amostras == base.amostras else { continue }
            let outra = historico.keys.sorted().first { outra in
                guard outra != id, !semSom.contains(outra), let dela = historico[outra] else { return false }
                let dentro = dela.filter { $0.ms >= base.ms && $0.ms <= fim.ms }
                guard let a = dentro.first, let b = dentro.last else { return false }
                return b.amostras > a.amostras
            }
            if let outra {
                faltas.append(Falta(id: id, motivo: "a captura desta sessão não trouxe amostra de som em \(segundos) s, "
                                    + "e a sessão #\(outra) trouxe"))
                amostrasNaFalta[id] = fim.amostras
            }
        }
        for f in faltas { semSom.insert(f.id) }
        veredito.faltas = faltas
        return veredito
    }

    /// A sessão saiu.
    public mutating func esquecer(_ id: Int) {
        historico[id] = nil
        primeira[id] = nil
        amostrasNaFalta[id] = nil
        semSom.remove(id)
    }

    /// Recomeça a rodada.
    public mutating func zerar() {
        historico = [:]
        primeira = [:]
        amostrasNaFalta = [:]
        semSom = []
    }
}
