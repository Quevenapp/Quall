import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Põe o quadro decodificado na tela, e conta o que aconteceu com ele.
///
/// # `AVSampleBufferDisplayLayer`, e não Metal
///
/// A camada aceita `CMSampleBuffer` **já descomprimido**, então o caminho fica
/// `VTDecompressionSession` → `CVPixelBuffer` → camada, com o decode medido no meio. A alternativa
/// — mandar o H.264 direto para a camada e deixar que ela decodifique — é menos código e apaga
/// exatamente o número que o `contrato-track.md` pede: sem sessão de decode própria não há
/// `decode p50/p95`.
///
/// # Sem fila, e o contador que diz isso
///
/// Cada quadro é oferecido à camada na hora e **descartado** se ela não quiser. Espelhamento ao
/// vivo não tem uso para quadro velho — é a mesma decisão do receptor de câmera do macOS, que
/// mediu 250 ms de fila no A07 justamente por não a ter tomado. `naoCouberam` é o preço aparecendo
/// como número em vez de virar latência silenciosa.
///
/// # O que "exibido" quer dizer aqui, exatamente
///
/// `enfileirados` conta os quadros **aceitos pela camada de exibição** com `DisplayImmediately`,
/// não pixels confirmados no vidro — nenhuma API do iOS confirma isso. É a mesma grandeza que o
/// receptor Android relata como `quadrosExibidos` (o `releaseOutputBuffer(render: true)` do
/// MediaCodec, que também entrega ao compositor). A prova de que os pixels certos chegaram até
/// aqui é outra e é independente: a régua de `Marca`, lida do buffer decodificado.
///
/// E `enfileirados` conta **quantos**, nunca *quando*: 1201 quadros em 40 s é a mesma contagem
/// com ou sem um buraco de 226 ms no meio, que é o que o usuário chamou de "falta fluidez" em
/// 01/09/2026. O *quando* é `Fluidez`, alimentada no ponto em que a camada aceita o quadro — ver
/// `oferecer` e o cabeçalho de `Fluidez.swift`.
///
/// # Por que este contador mudou de nome em 2026-08-28
///
/// Ele se chamava `exibidos`, e a tela do usuário mostrou
/// `recebidos 639 · exibidos 1749 · 77,4 fps` numa origem de 30 fps. **Três vezes mais
/// "exibidos" que recebidos é impossível como contagem de quadros**, e o número não era um erro
/// de contagem: era um erro de **escopo**.
///
/// `ReceptorApp` cria **um** `Exibidor` para o processo inteiro (`ReceptorApp.swift:32`) e uma
/// `SessaoDeRecepcao` nova a cada Conectar. `_exibidos` nunca era zerado, então o rodapé punha um
/// numerador de vida-do-processo ao lado de um `recebidos` de vida-da-sessão. Os 1110 quadros de
/// diferença eram o resíduo das tentativas anteriores no mesmo lançamento do app.
///
/// **A aritmética fecha**: 1749 / 77,4 = 22,6 s de sessão, e 639 / 22,6 = 28,3 fps — que é
/// exatamente uma origem de 30 fps menos os 14 `frames_dropped` e os 390 ms de arranque. O
/// "77,4 fps" nunca foi uma taxa: era o total velho dividido pelo relógio desta sessão.
///
/// E o dano não parava no rodapé. `TelaDeRecepcao` acusava o lado errado do fio com
/// `painel.recebidos > 0 && painel.exibidos == 0`; com o contador acumulando, **essa acusação
/// ficava permanentemente desarmada a partir da segunda sessão** — uma tela genuinamente preta
/// nunca mais a imprimiria.
///
/// Dois consertos, e os dois de propósito:
///
/// 1. **[`reiniciar`]**, chamado no arranque de cada sessão: o contador passa a ter o mesmo
///    escopo de tudo que aparece ao lado dele.
/// 2. **O nome.** `exibidos` prometia vidro e entregava enfileiramento — a mesma família do
///    `sem_parametros`, que dizia "não chegou SPS/PPS" e queria dizer "não existe sessão de
///    decode", e que mandou três pessoas para o lado errado do fio. Um contador honesto se chama
///    pelo que mede.
///
/// **O que continua não existindo**: uma testemunha automática de que o pixel apareceu. Não há
/// API no iOS que confirme apresentação, e este arquivo não inventa uma. A testemunha do vidro
/// continua sendo a captura de tela — ver `docs/tela-preta.md` §8.
final class Exibidor {
    let camada = AVSampleBufferDisplayLayer()

    private let trava = NSLock()
    private var _ofertados: UInt64 = 0
    private var _enfileirados: UInt64 = 0
    private var _naoCouberam: UInt64 = 0
    private var _semDescricao: UInt64 = 0
    private var _falhasDaCamada: UInt64 = 0
    /// A distribuição dos intervalos entre as entregas à camada. Ver `Fluidez.swift`: a marca do
    /// tempo é tirada **aqui**, no ponto em que a camada aceitou o quadro, porque é o último ponto
    /// desta casca antes do vidro — e o único em que a porta de `SessaoDeRecepcao` aparece pelo
    /// que ela custa.
    private var _fluidez = Fluidez()
    private var descricao: CMFormatDescription?
    private var larguraDaDescricao: Int = 0
    private var alturaDaDescricao: Int = 0

    // --- a folga de exibição (11/09/2026) ------------------------------------------------------
    //
    // Com folga zero — o de sempre —, cada quadro vai para a tela assim que decodifica
    // (`DisplayImmediately`), e todo tremor da rede e deste aparelho aparece como pausa: ~1 por
    // segundo acima de 50 ms na corrida D4 do iPhone X, 56 % delas de rede e daqui
    // (`docs/tela-estendida.md`, "De onde vêm os trancos").
    //
    // Com folga, o quadro vai para a tela **no ritmo em que o Mac o capturou**, atrasado da folga:
    // a camada recebe o carimbo como PTS e um relógio próprio (`controlTimebase`) que anda no tempo
    // do emissor. Quem chega adiantado espera; quem chega atrasado dentro da folga ainda sai na
    // hora. O custo é o mesmo tanto de atraso na tela — e por isso é escolha da pessoa, na tela de
    // conexão, e não padrão.
    //
    // O zero do relógio é o **caminho mais rápido** visto nos últimos ~5 s (o menor
    // `chegada − carimbo`), e não o do primeiro quadro: um primeiro quadro atrasado atrasaria a
    // sessão inteira, e uma janela deslizante acompanha a deriva entre os relógios das duas máquinas.
    private var folgaUs: UInt64 = 0
    private var relogio: CMTimebase?
    private var atrasoBaseUs: Int64?
    private var atrasosRecentes: [Int64] = []
    private var quadrosDesdeOAjuste = 0
    private var _atrasadosDaFolga: UInt64 = 0

    /// Quantos quadros chegaram **depois** da hora marcada para eles na tela — a folga não bastou.
    /// Zero com folga desligada.
    var atrasadosDaFolga: UInt64 {
        trava.lock(); defer { trava.unlock() }
        return _atrasadosDaFolga
    }

    struct Instantaneo {
        var ofertados: UInt64 = 0
        var enfileirados: UInt64 = 0
        var naoCouberam: UInt64 = 0
        var semDescricao: UInt64 = 0
        var falhasDaCamada: UInt64 = 0
        /// Tamanho da camada **em pontos**, e se ela está pendurada em alguma árvore.
        ///
        /// Existem porque a sua ausência custou o dia inteiro. Uma
        /// `AVSampleBufferDisplayLayer` de quadro zero, ou solta da árvore de camadas, **aceita
        /// todo quadro e não desenha nada**: `enqueue` devolve normal, `isReadyForMoreMediaData`
        /// segue `true`, `status` nunca vira `.failed`. As três guardas que este arquivo já
        /// tinha vigiavam a saúde da camada; nenhuma olhava para o tamanho dela.
        ///
        /// Medido na bancada em 2026-08-27: `recebidos 435 · exibidos 435 · marca ok 421 /
        /// erro 0`, com a tela do iPhone 7 **preta**. `largura x altura` teria dito `0x0` na
        /// primeira leitura.
        var larguraDaCamada: Double = 0
        var alturaDaCamada: Double = 0
        var camadaNaArvore = false

        /// `fluidez_ms=[n=… p50=… p95=… max=…] trancos=…` — já formatada, ver `Fluidez`.
        ///
        /// Sai formatada e não como amostra porque a amostra tem teto de 10 000 e não tem uso
        /// fora daqui: quem lê o relato lê a linha. E porque `enfileirados` sozinho não sabe
        /// dizer *quando* — 1201 quadros em 40 s é a mesma contagem com ou sem um buraco de
        /// 226 ms no meio.
        var fluidez = "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0"

        /// `true` quando a camada não pode desenhar por geometria — a pergunta que faltava.
        var camadaInvisivel: Bool { larguraDaCamada < 1 || alturaDaCamada < 1 || !camadaNaArvore }
    }

    func instantaneo() -> Instantaneo {
        trava.lock()
        var i = Instantaneo(ofertados: _ofertados, enfileirados: _enfileirados, naoCouberam: _naoCouberam,
                            semDescricao: _semDescricao, falhasDaCamada: _falhasDaCamada)
        // Cópia sob a trava, formatação fora dela: `linha()` ordena até 10 000 amostras, e a
        // thread de decode não pode esperar por isso uma vez por segundo. `Fluidez` é `struct`,
        // então a cópia é COW — o vetor só seria duplicado se alguém escrevesse nele.
        let fluidez = _fluidez
        trava.unlock()
        i.fluidez = fluidez.linha()
        // Fora da trava: são propriedades da `CALayer`, com a trava própria do Core Animation.
        let caixa = camada.bounds
        i.larguraDaCamada = Double(caixa.width)
        i.alturaDaCamada = Double(caixa.height)
        i.camadaNaArvore = camada.superlayer != nil
        return i
    }

    /// Zera os contadores para uma sessão nova, **sem** mexer na camada.
    ///
    /// Chamado por `SessaoDeRecepcao` no arranque. Existe porque este objeto vive o processo
    /// inteiro e as sessões não: sem isto, todo número deste objeto tem escopo diferente dos
    /// números impressos ao lado dele, e a diferença aparece como uma taxa de quadros impossível.
    /// Ver o cabeçalho do tipo.
    ///
    /// A `descricao` também é largada: ela é a geometria da sessão anterior, e mantê-la faria o
    /// primeiro quadro de uma origem com outra dimensão ser oferecido com a descrição errada.
    func reiniciar(folgaMs: Int = 0) {
        trava.lock()
        folgaUs = UInt64(max(0, folgaMs)) * 1000
        atrasoBaseUs = nil
        atrasosRecentes.removeAll(keepingCapacity: true)
        quadrosDesdeOAjuste = 0
        _atrasadosDaFolga = 0
        if folgaUs > 0 {
            if relogio == nil {
                var novo: CMTimebase?
                CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                                sourceClock: CMClockGetHostTimeClock(),
                                                timebaseOut: &novo)
                relogio = novo
            }
            // Parado até o primeiro quadro, que é quem diz onde o zero fica.
            if let relogio { CMTimebaseSetRate(relogio, rate: 0) }
            camada.controlTimebase = relogio
        } else {
            camada.controlTimebase = nil
        }
        _ofertados = 0
        _enfileirados = 0
        _naoCouberam = 0
        _semDescricao = 0
        _falhasDaCamada = 0
        // **A fluidez zera junto, e pelo mesmo motivo dos contadores.** Sem isto, o primeiro
        // intervalo de uma sessão nova seria o tempo entre o último quadro da sessão anterior e o
        // primeiro desta — que inclui a pessoa desistindo, tomando café e apertando Conectar de
        // novo. Um tranco de minutos, plantado por escopo, exatamente a família do
        // `recebidos 639 · exibidos 1749` descrito no cabeçalho deste tipo.
        _fluidez = Fluidez()
        descricao = nil
        larguraDaDescricao = 0
        alturaDaDescricao = 0
        trava.unlock()
    }

    init() {
        camada.videoGravity = .resizeAspect
        // Sem isto a camada usa o próprio relógio para agendar a apresentação, e um carimbo de
        // captura vindo de outra máquina — que é o caso de qualquer receptor — a faria segurar ou
        // largar quadro por comparação de relógios que não estão sincronizados.
        camada.controlTimebase = nil
    }

    /// Oferece um quadro decodificado. Chamada da thread de decode; nada aqui bloqueia.
    ///
    /// Devolve o instante, no relógio de `Medidas`, que conta como **a entrega à tela**, ou `nil`
    /// quando a camada não aceitou. Sem folga, é o instante do `enqueue`. Com folga, é a hora marcada
    /// para o quadro — ou o `enqueue`, se ele chegou depois dela.
    ///
    /// `carimboUs` (o do núcleo, no tempo do emissor) só importa com folga: vira o PTS, e a
    /// diferença entre agora e ele diz o quanto este quadro atrasou em relação ao caminho mais rápido.
    @discardableResult
    func oferecer(_ imagem: CVPixelBuffer, carimboUs: UInt64 = 0) -> UInt64? {
        // **O atraso é medido com o quadro já decodificado**, e não na chegada do núcleo: medido lá,
        // o decode (12–30 ms) comia a folga, e na G1 (11/09) 6 % dos quadros passaram da hora com
        // 50 ms de folga.
        let prontoUs = Medidas.agoraUs()
        trava.lock()
        let comFolga = folgaUs > 0 && relogio != nil
        var alvoUs: UInt64?
        if comFolga, let relogio {
            let atraso = Int64(bitPattern: prontoUs) - Int64(bitPattern: carimboUs)
            atrasosRecentes.append(atraso)
            if atrasosRecentes.count > 150 { atrasosRecentes.removeFirst() }
            quadrosDesdeOAjuste += 1
            // Reajusta quando um quadro mais rápido aparece, e a cada 30 para a janela deslizar.
            // Menos de 1 ms de mudança não mexe no relógio: cada ajuste reagenda o que está na fila.
            if atrasoBaseUs.map({ atraso < $0 }) ?? true || quadrosDesdeOAjuste >= 30 {
                let menor = atrasosRecentes.min() ?? atraso
                if atrasoBaseUs.map({ abs(menor - $0) >= 1_000 }) ?? true {
                    atrasoBaseUs = menor
                    // O relógio anda no tempo do carimbo: agora, nele, é `agora − base − folga`.
                    let agora = Int64(bitPattern: Medidas.agoraUs())
                    CMTimebaseSetTime(relogio, time: CMTime(value: agora - menor - Int64(folgaUs),
                                                            timescale: 1_000_000))
                    CMTimebaseSetRate(relogio, rate: 1)
                }
                quadrosDesdeOAjuste = 0
            }
            let alvo = Int64(bitPattern: carimboUs) + (atrasoBaseUs ?? atraso) + Int64(folgaUs)
            alvoUs = UInt64(max(0, alvo))
        }
        _ofertados &+= 1
        let largura = CVPixelBufferGetWidth(imagem)
        let altura = CVPixelBufferGetHeight(imagem)
        if descricao == nil || largura != larguraDaDescricao || altura != alturaDaDescricao {
            var d: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: imagem,
                                                         formatDescriptionOut: &d)
            descricao = d
            larguraDaDescricao = largura
            alturaDaDescricao = altura
        }
        let d = descricao
        trava.unlock()

        guard let d else {
            trava.lock(); _semDescricao &+= 1; trava.unlock()
            return nil
        }

        // A camada pode entrar em falha (perda de contexto gráfico, app suspenso). Quando entra,
        // ela **para de aceitar quadros para sempre** até um `flush`, e sem esta guarda o sintoma
        // seria "recebidos sobe, exibidos congela" sem nenhuma pista do motivo.
        if camada.status == .failed {
            trava.lock(); _falhasDaCamada &+= 1; trava.unlock()
            camada.flush()
        }

        guard camada.isReadyForMoreMediaData else {
            trava.lock(); _naoCouberam &+= 1; trava.unlock()
            return nil
        }

        // Com folga, o carimbo é o PTS e o relógio da camada decide a hora. Sem folga, nenhum PTS.
        var tempo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: comFolga
                ? CMTime(value: Int64(bitPattern: carimboUs), timescale: 1_000_000) : .invalid,
            decodeTimeStamp: .invalid)
        var amostra: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: imagem,
                                                       formatDescription: d,
                                                       sampleTiming: &tempo,
                                                       sampleBufferOut: &amostra) == noErr,
              let amostra else {
            trava.lock(); _naoCouberam &+= 1; trava.unlock()
            return nil
        }

        // `DisplayImmediately`: mostre assim que puder, sem esperar relógio nenhum. É o que
        // espelhamento ao vivo quer sem folga, e é o que dispensa a `controlTimebase`.
        if !comFolga,
           let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: true),
           CFArrayGetCount(anexos) > 0 {
            let dicionario = unsafeBitCast(CFArrayGetValueAtIndex(anexos, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dicionario,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        camada.enqueue(amostra)
        // **A marca do tempo sai daqui, e não de outro lugar do caminho.**
        //
        // Depois do `enqueue`, junto do contador que conta a mesma coisa: é o último instante
        // desta casca antes do vidro. Tirá-la na chegada do quadro, ou na saída do decode,
        // esconderia justamente as duas coisas que esta medida existe para mostrar — os quadros
        // que a porta de `SessaoDeRecepcao` retém e os que a camada recusa (`naoCouberam`)
        // chegam e decodificam, mas não viram imagem, e o intervalo que o olho vê é entre os que
        // viram.
        //
        // E o que ela mede, com todas as letras: **a hora em que este quadro foi entregue para a
        // tela, não a hora em que ele apareceu.** Quem põe o pixel no vidro é a
        // `AVSampleBufferDisplayLayer`, depois desta linha, e nenhuma API do iOS diz quando. Ver
        // o cabeçalho de `Fluidez` e o deste tipo — é a mesma limitação que renomeou `exibidos`.
        //
        // O relógio é lido **antes** da trava e não dentro dela: a espera pela trava é tempo de
        // contenção desta casa, não tempo do quadro, e somá-la ao intervalo seria medir o
        // instrumento. É um `clock_gettime` monotônico, o mesmo de todo carimbo desta casca.
        //
        // **Com folga, a marca é a hora marcada**, e não o `enqueue`: o quadro espera na camada até
        // ela. Se chegou depois dela, a camada o mostra na hora, e a marca é o `enqueue` — e o
        // quadro conta em `atrasadosDaFolga`. Continua sendo a hora da entrega, não a do vidro.
        let entregueEm = Medidas.agoraUs()
        let conta = alvoUs.map { max(entregueEm, $0) } ?? entregueEm
        trava.lock()
        _enfileirados &+= 1
        if let alvoUs, entregueEm > alvoUs { _atrasadosDaFolga &+= 1 }
        _fluidez.apresentou(conta)
        trava.unlock()
        return conta
    }

    func limpar() { camada.flushAndRemoveImage() }
}
