import Foundation

/// O tom sintético do projeto, e o Goertzel que confere se ele chegou inteiro.
///
/// # Por que este arquivo existe no app, e não só na sonda
///
/// `docs/audio.md` §8.1 fixa a origem: **prova de áudio de bancada se faz com tom sintético, nunca
/// com o som da sala.** (O produto abre o microfone pelo botão da câmera desde a R5 fase 2; a prova
/// de caminho dele troca o conteúdo por estas mesmas notas, `--microfone-tom`.) O `quall-probe` (`crates/quall-probe/src/audio.rs`) e o app Android
/// (`TomSintetico.kt`) já têm as mesmas quatro notas com os mesmos números; esta é a terceira
/// cópia, e a duplicação é deliberada pela mesma razão que a régua de blocos do vídeo existe duas
/// vezes: **o gerador e o conferidor precisam ser independentes**, senão um defeito comum aos dois
/// passa despercebido. `provar-receptor.sh` confere as constantes das duas cópias, como já faz com
/// a `Marca`.
///
/// # Os números, e por que nenhum deles é arbitrário
///
/// - **400, 500, 800 e 1000 Hz**: cada uma tem um número **inteiro** de ciclos dentro de um quadro
///   de 20 ms a 8 kHz (160 amostras) — 8000/400 = 20 amostras por ciclo, 160/20 = 8 ciclos
///   exatos. Sem isso há um salto de fase na emenda entre quadros, que vira um estalo audível a
///   cada 20 ms, e alguém gastaria uma tarde procurando esse estalo na rede. A mesma propriedade
///   vale a 48 kHz (960 amostras).
/// - **25 quadros por nota** (0,5 s), 2 s por volta: a troca de nota é o que impede o VAD do SILK
///   de derrubar o LBRR num tom estacionário (§11 do `audio.md`), e é o que permite ao conferidor
///   perguntar "a linha do tempo anda?" além de "o conteúdo é o certo?".
/// - **amplitude 0,5**: longe do teto para não recortar no µ-law.
enum TomSintetico {

    /// As quatro notas, em Hz.
    static let notasHz: [Double] = [400, 500, 800, 1000]

    /// Quantos quadros cada nota dura. 25 × 20 ms = 0,5 s por nota.
    static let quadrosPorNota = 25

    /// Amplitude, em fração do fundo de escala.
    static let amplitude = 0.5

    /// Gera as amostras PCM de **um** quadro, deterministicamente a partir do índice.
    ///
    /// A fase sai do índice **absoluto** da amostra e não é reiniciada por quadro: é o que mantém
    /// a onda contínua na emenda. O resultado é intercalado quando `canais > 1`, com os canais
    /// idênticos — o que permite ao outro lado provar que dois canais atravessaram e voltaram
    /// como dois.
    static func quadro(indice: Int, amostrasPorCanal: Int, taxaHz: Double,
                       canais: Int) -> [Int16] {
        let nota = notasHz[(indice / quadrosPorNota) % notasHz.count]
        let amostrasPorCiclo = taxaHz / nota
        let base = indice * amostrasPorCanal
        var saida = [Int16](repeating: 0, count: amostrasPorCanal * canais)
        for i in 0..<amostrasPorCanal {
            let fase = 2.0 * Double.pi * Double(base + i) / amostrasPorCiclo
            let v = Int16(sin(fase) * amplitude * Double(Int16.max))
            for c in 0..<canais { saida[i * canais + c] = v }
        }
        return saida
    }
}

/// O conferidor: um Goertzel nas quatro raias sobre o PCM **decodificado**, antes de ele virar som.
///
/// # Por que Goertzel, e por que ele responde três perguntas e não uma
///
/// É a mesma escolha de `apps/android/.../AnalisadorDeTom.kt`, e a razão está em
/// `docs/audio-no-android.md`: um contador de slots prova que **bytes** chegaram; ele não prova
/// que **som** chegou. Três modos de falha distintos, três perguntas:
///
/// 1. **a energia está numa das quatro raias?** — chegou conteúdo, não só bytes. PCM zerado, ruído
///    ou um decodificador confuso reprovam aqui;
/// 2. **as quatro notas apareceram?** — não travou numa só;
/// 3. **elas trocam?** — a linha do tempo anda. Um decodificador que repete o último quadro passa
///    em (1) e (2) e reprova aqui.
///
/// # O que ele não faz, e é regra
///
/// **Ele lê as amostras e não guarda nenhuma.** Mesma escolha de `apps/windows/src/audio.rs` e do
/// Android. Não há `.wav`, não há buffer de sessão, não há nada que possa virar artefato de áudio
/// no disco de um aparelho — e a origem aqui é sintética, então nem o argumento de privacidade
/// precisa ser invocado: simplesmente não há por que guardar.
///
/// # Por que não se compara byte a byte, como a sonda faz
///
/// A sonda compara o **pacote codificado** contra uma tabela de quatro quadros de referência, o
/// que é exato. Aqui o que se tem é PCM depois do `opus_decode` — e Opus é com perdas: o PCM que
/// sai **não** é bit a bit igual ao que entrou no encoder do outro lado. Comparar amostras exigiria
/// um limiar arbitrário; medir energia por raia não exige nenhum, e responde a pergunta que
/// importa ("é este tom?") em vez de uma pergunta que não tem resposta certa ("quão parecido?").
final class AnalisadorDeTom {

    struct Instantaneo {
        var quadros: UInt64 = 0
        /// Quadros em que a raia mais forte era uma das quatro notas com folga sobre as outras.
        var comNota: UInt64 = 0
        /// Quantas vezes a nota reconhecida mudou. Numa corrida de N segundos, ~N/0,5.
        var trocas: UInt64 = 0
        /// Quais das quatro notas já apareceram.
        var notasVistas: Int = 0
        /// Média da razão "energia da raia vencedora / energia total das quatro". 1,0 é perfeito.
        var razaoMedia: Double = 0
        /// RMS do PCM, em fração do fundo de escala. Zero significa silêncio digital.
        var rms: Double = 0
        /// O veredito de uma linha: as três perguntas responderam sim.
        var verde: Bool {
            quadros > 0 && notasVistas == TomSintetico.notasHz.count
                && trocas >= 2 && comNota * 10 >= quadros * 8 && rms > 0.01
        }
    }

    private let taxaHz: Double
    private let canais: Int
    private let trava = NSLock()
    private var contadores = Instantaneo()
    private var somaDaRazao: Double = 0
    private var somaDosQuadrados: Double = 0
    private var amostrasSomadas: UInt64 = 0
    private var vistas = Set<Int>()
    private var ultimaNota = -1

    init(taxaHz: Double, canais: Int) {
        self.taxaHz = taxaHz
        self.canais = max(1, canais)
    }

    func instantaneo() -> Instantaneo {
        trava.lock(); defer { trava.unlock() }
        var c = contadores
        c.notasVistas = vistas.count
        c.razaoMedia = contadores.quadros > 0 ? somaDaRazao / Double(contadores.quadros) : 0
        c.rms = amostrasSomadas > 0
            ? (somaDosQuadrados / Double(amostrasSomadas)).squareRoot() / Double(Int16.max)
            : 0
        return c
    }

    /// Mede um quadro de PCM intercalado. **Só o canal 0** — os canais do tom são idênticos por
    /// construção, e medir os dois dobraria o custo para responder a mesma pergunta. (A prova de
    /// que os dois canais atravessaram é outra, e é do emissor: ver `docs/audio-no-android.md`.)
    func medir(_ pcm: [Int16]) {
        let n = pcm.count / canais
        guard n > 8 else { return }

        var energias = [Double](repeating: 0, count: TomSintetico.notasHz.count)
        for (i, nota) in TomSintetico.notasHz.enumerated() {
            energias[i] = AnalisadorDeTom.goertzel(pcm, canais: canais, amostras: n,
                                                   alvoHz: nota, taxaHz: taxaHz)
        }
        var quadrados: Double = 0
        for i in 0..<n { let v = Double(pcm[i * canais]); quadrados += v * v }

        let total = energias.reduce(0, +)
        let vencedora = energias.enumerated().max(by: { $0.element < $1.element })
        // **A folga é o que separa "tem energia nessa raia" de "é essa nota".** Ruído branco põe
        // energia nas quatro; um tom põe quase tudo numa. 0,6 é folgado — o Opus a 128 kbit/s
        // devolve ~0,98 (medido no Android) e o µ-law devolve 1,000.
        let razao = total > 0 ? (vencedora?.element ?? 0) / total : 0

        trava.lock()
        contadores.quadros &+= 1
        somaDaRazao += razao
        somaDosQuadrados += quadrados
        amostrasSomadas &+= UInt64(n)
        if let v = vencedora, razao >= 0.6, total > 0 {
            contadores.comNota &+= 1
            vistas.insert(v.offset)
            if ultimaNota >= 0, ultimaNota != v.offset { contadores.trocas &+= 1 }
            ultimaNota = v.offset
        }
        trava.unlock()
    }

    /// Goertzel de uma raia. Ele custa uma multiplicação e duas somas por amostra e não precisa de
    /// FFT nem de biblioteca — é o algoritmo certo quando se conhece de antemão quais raias
    /// interessam, que é exatamente o caso de um tom que nós mesmos geramos.
    private static func goertzel(_ pcm: [Int16], canais: Int, amostras: Int,
                                 alvoHz: Double, taxaHz: Double) -> Double {
        // O `k` é arredondado para o bin mais próximo, como manda o algoritmo: com 960 amostras a
        // 48 kHz a resolução é 50 Hz, e as quatro notas caem em bins inteiros por construção.
        let k = (Double(amostras) * alvoHz / taxaHz).rounded()
        let w = 2.0 * Double.pi * k / Double(amostras)
        let coef = 2.0 * cos(w)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in 0..<amostras {
            s0 = Double(pcm[i * canais]) + coef * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coef * s1 * s2
    }
}
