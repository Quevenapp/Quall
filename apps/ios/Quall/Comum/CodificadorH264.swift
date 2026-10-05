import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox em H.264 baseline, para a tela e para a câmera.
///
/// É o encoder do arnês do degrau 4, promovido quase inteiro: ele entregou 10.755 quadros com
/// zero `idrs_without_parameters`, zero descartes por fila, zero descartes do encoder e **zero**
/// crescimentos do buffer de conversão, com o `VTCompressionSession` custando 16 KB de pegada.
/// O que mudou no caminho para o produto:
///
/// * **teto em vez de dimensão fixa** — o produto encontra rotação de tela, e o arnês não;
/// * **dois perfis**, tela e câmera, como o contrato pede;
/// * **bitrate ajustável em voo**, para o produto poder recuar sob calor ou modo de baixo consumo
///   em vez de ser desligado pelo sistema.
///
/// As quatro decisões que o arnês custou a descobrir continuam intactas, e nenhuma é de estilo:
///
/// 1. **Teto de 1080x1920, desde 01/09/2026.** O `PERFIL_H264` que o núcleo anuncia no SDP é
///    `profile-level-id=42e028` — baseline, **nível 4.0**, que comporta 1920x1080 a 30 fps. Era
///    3.1 (1280x720), e sob aquele teto os 750x1334 nativos do iPhone 7 já violavam o nível
///    (dívida 16); hoje passam inteiros. A sessão é criada nas dimensões de destino, o
///    VideoToolbox escala a entrada, e o resultado é **conferido** na format description da
///    saída.
/// 2. **`MaxFrameDelayCount = 1`.** Sem isto o VideoToolbox retém buffers de entrada por
///    construção, e o modo de morte não é vazamento lento: é rajada. Basta o envio passar de um
///    intervalo de quadro uma vez — throttle térmico do A10, retransmissão do Wi-Fi — para a fila
///    de entrada estourar dentro de um orçamento de 50 MB.
/// 3. **Sem `Data`.** O caminho AVCC → Annex-B escreve num buffer **único**, alocado uma vez e
///    crescido geometricamente. O VideoToolbox emite AVCC e a rede quer Annex-B: essa é a nona
///    cópia do caminho do quadro, e um `Data` novo por quadro seriam dezenas de milhares de
///    alocações por sessão.
/// 4. **Teto de quadros em voo.** "Empacota e solta" vale para o encoder também: se o A10 não
///    acompanhar, a casca descarta em vez de deixar o VideoToolbox enfileirar.
final class CodificadorH264 {

    /// Preset do contrato. A diferença que importa é a expectativa de movimento: tela tem
    /// conteúdo estático com mudanças bruscas, câmera tem ruído e movimento contínuo.
    enum Perfil {
        case tela
        case camera
    }

    /// O buffer entregue vale **só durante a chamada** — mesma regra da fronteira C do núcleo.
    typealias Saida = (UnsafeRawBufferPointer, CMTime, Bool) -> Void

    enum Falha: Error, CustomStringConvertible {
        case sessaoNaoCriou(OSStatus)
        var description: String {
            switch self {
            case .sessaoNaoCriou(let s): return "VTCompressionSessionCreate falhou: \(s)"
            }
        }
    }

    private let sessao: VTCompressionSession
    let largura: Int32
    let altura: Int32

    /// Protege **só** o buffer de conversão, e é segurada durante a conversão inteira. Nenhuma
    /// leitura de instrumento a toca — ver `travaDoRelato`.
    private let travaDoBuffer = NSLock()
    /// Reescreve o SPS para declarar que aqui não se reordena quadro. Ver `RemendoDeSPS`.
    let remendoDeSPS = RemendoDeSPS()
    private var buffer: UnsafeMutableRawPointer
    private var capacidade: Int

    private let travaDoVoo = NSLock()
    private var emVoo = 0
    private let tetoEmVoo: Int

    /// Trava **só do instrumento**, e nunca segurada durante trabalho.
    ///
    /// A versão anterior guardava a dimensão da saída e os contadores atrás da `travaDoBuffer` —
    /// que fica presa durante a conversão AVCC→Annex-B inteira de cada quadro. Uma leitura de
    /// diagnóstico ficaria esperando o quadro terminar, e o quadro seguinte ficaria esperando a
    /// leitura. Isso não derruba o processo; produz quadro perdido, que é um sintoma bem mais
    /// difícil de atribuir ao instrumento.
    private let travaDoRelato = NSLock()
    private var _descartadosPorFila: UInt64 = 0
    private var _descartadosPeloEncoder: UInt64 = 0
    private var _crescimentosDoBuffer = 0
    /// Dimensão que a **saída** declarou, não a que foi pedida. Ver o item 1 do cabeçalho.
    private var _dimensaoDaSaida = "?"

    var dimensaoDaSaida: String {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _dimensaoDaSaida
    }
    var descartadosPorFila: UInt64 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _descartadosPorFila
    }
    var descartadosPeloEncoder: UInt64 {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _descartadosPeloEncoder
    }
    /// Quantas vezes o buffer de conversão precisou crescer. Em regime tem de ser **zero**.
    var crescimentosDoBuffer: Int {
        travaDoRelato.lock(); defer { travaDoRelato.unlock() }
        return _crescimentosDoBuffer
    }

    // `&+` em vez de `+`: contador de instrumento satura, não derruba o processo. É a regra que
    // a corrida de 464 s do degrau 4 comprou com uma corrida inteira.
    private func contarDescartePorFila() {
        travaDoRelato.lock(); _descartadosPorFila = _descartadosPorFila &+ 1; travaDoRelato.unlock()
    }
    private func contarDescartePeloEncoder() {
        travaDoRelato.lock(); _descartadosPeloEncoder = _descartadosPeloEncoder &+ 1; travaDoRelato.unlock()
    }

    var aoSair: Saida?

    // --- teto de resolução ------------------------------------------------------------------

    /// Traduz a dimensão que a plataforma entrega para a dimensão que o SDP comporta.
    ///
    /// O iPhone 7 entrega 750x1334 em pé e — se a tela girar — 1334x750 deitado. O nível 4.0 do
    /// perfil anunciado comporta 1920x1080 em qualquer orientação, então o cálculo é sobre o
    /// **maior** e o **menor** lado, e não sobre largura e altura.
    ///
    /// A caixa nunca estoura o `MaxFS` do nível: 1920x1080 são 8160 macroblocos contra 8192, e
    /// qualquer outra proporção que caiba na caixa ocupa menos. Ainda assim esta é uma
    /// **aproximação por caixa**, e a regra canônica é `quall_core::teto::ajustar`, em
    /// macroblocos — se um dia esta casca passar a consultar a fronteira C, é aqui que ela
    /// entra.
    ///
    /// Dimensões ímpares não existem em 4:2:0 — o arredondamento para baixo é obrigatório, não
    /// higiene.
    static func destino(largura: Int, altura: Int, tetoMaior: Int, tetoMenor: Int) -> (Int32, Int32) {
        guard largura > 0, altura > 0, tetoMaior > 0, tetoMenor > 0 else { return (1080, 1920) }
        let emPe = altura >= largura
        let maior = Double(max(largura, altura))
        let menor = Double(min(largura, altura))
        let escala = min(1.0, min(Double(tetoMaior) / maior, Double(tetoMenor) / menor))
        var m = Int((maior * escala).rounded())
        var n = Int((menor * escala).rounded())
        m -= m % 2
        n -= n % 2
        m = max(2, m)
        n = max(2, n)
        return emPe ? (Int32(n), Int32(m)) : (Int32(m), Int32(n))
    }

    /// O que decide a faixa de cor do fluxo: **o pixel format da entrada**.
    ///
    /// No VideoToolbox não existe propriedade de sessão para faixa de cor — quem manda é o
    /// formato do `CVPixelBuffer` que entra: `…420YpCbCr8BiPlanarVideoRange` ('420v') produz
    /// limitada, `…FullRange` ('420f') produz completa. Foi assim que a Frente 3 consertou o
    /// macOS, e é a mesma alavanca aqui.
    ///
    /// **A diferença do iOS é que a casca não escolhe a entrada.** O ReplayKit entrega o
    /// `CVPixelBuffer` que quiser — e entregou '420f', que é por que a primeira corrida do
    /// produto saiu em `color_range=pc` — e a appex não pode converter por conta própria:
    /// CoreImage, Metal e vImage estão fora, porque o caminho errado de reescalonamento custou
    /// 30 MB contra 0,1 MB neste projeto.
    ///
    /// ## Precisão de 2026-08-23: isto converte, mas SÓ quando há reescala
    ///
    /// A versão anterior deste comentário dizia que declarar a entrada aqui faz a sessão de
    /// transferência do VideoToolbox converter a faixa "no mesmo passo" do reescalonamento. A
    /// parte que faltava é justamente **"no mesmo passo"**: a sessão de transferência só existe
    /// quando há o que transferir. Sem mudança de dimensão, o `CVPixelBuffer` vai cru para o
    /// encoder e o `video_full_range_flag` sai da faixa do **formato de entrada**, ignorando o
    /// que foi declarado aqui.
    ///
    /// Medido com o encoder do produto em `Testes/rodar.sh`, pela **matriz** de duas chaves vezes
    /// dois casos de dimensão, sempre com entrada `420f` — a mesma que o ReplayKit entrega. A
    /// luma é o percentil 10–90 do fluxo decodificado, com a entrada pintada em 0 e 255:
    ///
    /// | `imageBufferAttributes` | 3 chaves de cor | reescala | `color_range` | luma |
    /// |---|---|---|---|---|
    /// | não | qualquer | qualquer | `pc` | 0–255 |
    /// | **sim** | não | **sim** | **`unknown`** | **16–236** |
    /// | **sim** | sim | **sim** | **`tv`** | **16–236** |
    /// | sim | qualquer | não | `pc` | 0–255 |
    ///
    /// Três leituras, e nenhuma é suposição:
    ///
    /// 1. `imageBufferAttributes` **converte de verdade** — a luma vai para dentro da faixa, não
    ///    é só etiqueta;
    /// 2. **só quando há reescala**, porque só então a sessão de transferência existe;
    /// 3. as três chaves de cor **não mexem na faixa**: elas decidem se o VUI é escrito, isto é,
    ///    se o `color_range` sai `tv` ou `unknown`. É exatamente a ressalva do `unknown` que
    ///    `contrato-sidecar.md` registrou como tarefa em aberto no macOS.
    ///
    /// A linha do meio-fim é onde a **câmera** cairia: com `videoOrientation = .portrait` a
    /// captura entrega exatamente a dimensão de saída — 1080x1920 em `.hd1920x1080` desde
    /// 07/09/2026, e 720x1280 em `.hd1280x720` antes disso —, então não há reescala e não há
    /// sessão de transferência. **Subir o preset não mudou nada aqui, e é o ponto:** a coincidência
    /// de dimensões vale nos dois tamanhos. Daí a câmera escolher `420v` na captura em vez de
    /// confiar nisto.
    ///
    /// O emissor de tela está **certo**, e agora pelo argumento certo: os 750x1334 do iPhone 7
    /// nunca coincidem com 720x1280, então a transferência sempre roda. A fragilidade que fica
    /// registrada é que essa correção depende de as dimensões **diferirem** — num aparelho cuja
    /// captura entregasse 720x1280 nativos, o mesmo código sairia em faixa completa sem nada
    /// reclamar.
    ///
    /// As três chaves de descrição de cor abaixo são independentes disso: elas fazem o VUI
    /// existir, e é por elas que `color_primaries` e `color_space` saem declarados.
    static let entradaEmFaixaLimitada: CFDictionary = [
        kCVPixelBufferPixelFormatTypeKey:
            Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ] as CFDictionary

    /// Os quatro caracteres do `OSType`, com os dois que importam nomeados.
    ///
    /// `420f` é faixa **completa** e `420v` é **limitada**. O contrato padroniza limitada, e é o
    /// pixel format da entrada que decide — por isso este nome sai no log dos **dois** emissores:
    /// a appex registra o que o ReplayKit entrega, o app registra o que a câmera entrega. Se um
    /// dia qualquer um dos dois mudar, a linha muda junto e o veredito explica por quê.
    ///
    /// Mora aqui, e não na appex, porque a appex não existe para o app: `Extensao/` não entra na
    /// lista de fontes do alvo `Quall`. Em `Comum/` os dois alcançam — e, de quebra, isto vira
    /// função pura testável no MacBook.
    static func nomeDoFormato(_ tipo: OSType) -> String {
        switch tipo {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420f(faixa-completa)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "420v(faixa-limitada)"
        default:
            let bytes = [UInt8((tipo >> 24) & 0xFF), UInt8((tipo >> 16) & 0xFF),
                         UInt8((tipo >> 8) & 0xFF), UInt8(tipo & 0xFF)]
            let texto = String(decoding: bytes, as: UTF8.self)
            return texto.allSatisfy { $0.isASCII && !$0.isNewline && !$0.isWhitespace }
                ? texto : "\(tipo)"
        }
    }

    /// - Parameter declararEntrada: declara o pixel format de entrada em `imageBufferAttributes`,
    ///   que é **o** mecanismo que faz a faixa de cor sair limitada. Sempre `true` no produto; o
    ///   parâmetro existe para que o **controle negativo** do teste seja automático em vez de um
    ///   experimento que alguém rodou uma vez à mão e descreveu num relatório.
    ///
    ///   Sem controle negativo, um teste de faixa de cor que passa não prova nada: ele pode estar
    ///   passando porque o encoder acerta ou porque o teste não sabe reprovar. Passando `false`, o
    ///   teste **reproduz o defeito** que custou uma corrida inteira no iPhone 7 — e é a corrida
    ///   reprovada que dá valor à aprovada.
    /// - Parameter declararCor: escreve `ColorPrimaries`, `TransferFunction` e `YCbCrMatrix` na
    ///   sessão. Sempre `true` no produto; como `declararEntrada`, o parâmetro existe para o teste
    ///   poder medir a **matriz** de combinações em vez de atribuir o efeito a uma delas por
    ///   suposição. Foi assim que se descobriu que o efeito atribuído a `imageBufferAttributes`
    ///   não era dele.
    init(largura: Int32, altura: Int32, fps: Int32, bitrate: Int,
         perfil: Perfil, tetoEmVoo: Int,
         declararEntrada: Bool = true, declararCor: Bool = true) throws {
        self.largura = largura
        self.altura = altura
        self.tetoEmVoo = max(1, tetoEmVoo)
        // Capacidade derivada do teto de bitrate, não chutada: um IDR em rajada cabe em ~1 s de
        // bitrate alvo, e o dobro disso ainda é ruído contra ~43 MB de folga. O piso de 1 MB
        // existe porque um bitrate baixo não muda o tamanho de um IDR de tela cheia.
        self.capacidade = max(1024 * 1024, (bitrate / 8) * 2)
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacidade, alignment: 16)

        var criada: VTCompressionSession?
        let estado = VTCompressionSessionCreate(
            allocator: nil, width: largura, height: altura,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: declararEntrada
                ? CodificadorH264.entradaEmFaixaLimitada : nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &criada)
        guard estado == noErr, let sessao = criada else {
            buffer.deallocate()
            throw Falha.sessaoNaoCriou(estado)
        }
        self.sessao = sessao

        // **O `OSStatus` deixou de ser jogado fora em 08/09/2026.** `VTSessionSetProperty`
        // devolve erro quando o encoder recusa a chave, e esta função descartava o retorno: uma
        // propriedade recusada não aparecia em lugar nenhum, e o log seguia afirmando o que foi
        // *pedido*. É o mesmo defeito que o Android tinha do outro lado — lá a chave não
        // reconhecida é ignorada em silêncio; aqui ela devolvia um número que ninguém lia.
        var recusadas: [String] = []
        func por(_ chave: CFString, _ valor: CFTypeRef, _ nome: String) {
            let estado = VTSessionSetProperty(sessao, key: chave, value: valor)
            if estado != noErr { recusadas.append("\(nome)=\(estado)") }
        }
        // Zero filas, sem reordenamento (sem B-frames), baseline — o denominador comum entre as
        // quatro plataformas — e GOP curto, para que quem entra na sessão veja imagem depressa.
        por(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        por(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        por(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel, "ProfileLevel")
        por(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1), "MaxFrameDelayCount")
        por(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps), "ExpectedFrameRate")
        por(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2), "MaxKeyFrameInterval")
        // Um IDR por segundo na tela: é o que faz "conectar" virar "imagem" depressa mesmo quando
        // o PLI se perde. Na câmera o movimento é contínuo e o custo de um IDR por segundo é alto
        // demais para o mesmo benefício — quem entra depois espera até dois segundos.
        por(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            NSNumber(value: perfil == .tela ? 1.0 : 2.0),
            "MaxKeyFrameIntervalDuration")
        // **A média E o teto saem do mesmo número, por uma função só.** Ver `aplicarTeto`.
        for r in CodificadorH264.aplicarTeto(sessao, bps: bitrate) { recusadas.append(r) }

        // --- faixa de cor: limitada, e **declarada** -----------------------------------------
        //
        // `contrato-sidecar.md` padroniza faixa **limitada**, e o argumento é do Android: faixa
        // completa só funciona ponta a ponta se todo decoder da matriz honrar o
        // `video_full_range_flag` do VUI, e o MediaCodec é conhecido por ignorá-lo. O Galaxy
        // A10s é justamente o aparelho que acha o defeito que os outros escondem.
        //
        // Estas três chaves fazem o VideoToolbox **escrever a descrição de cor no VUI**. Sem
        // elas o fluxo sai sem `video_signal_type`, o `ffprobe` reporta `color_range=unknown` —
        // que é exatamente a ressalva que o contrato registrou como tarefa em aberto no macOS —
        // e o receptor cai no padrão do H.264. Com elas, a faixa é dita por extenso.
        //
        // Faixa e descrição são coisas **separadas**: estas chaves fazem o VUI existir; quem
        // decide se o `video_full_range_flag` sai 0 ou 1 é o pixel format da entrada, declarado
        // em `entradaEmFaixaLimitada`. Mexer numa sem a outra dá um fluxo que declara com
        // precisão a faixa errada.
        if declararCor {
            por(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2,
                "ColorPrimaries")
            por(kVTCompressionPropertyKey_TransferFunction,
                kCVImageBufferTransferFunction_ITU_R_709_2, "TransferFunction")
            por(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                "YCbCrMatrix")
        }

        VTCompressionSessionPrepareToEncodeFrames(sessao)
        if !recusadas.isEmpty {
            Diagnostico.falha("APP ENCODER propriedades recusadas: \(recusadas.joined(separator: " "))")
        }
    }

    deinit {
        VTCompressionSessionInvalidate(sessao)
        buffer.deallocate()
    }

    /// Drena o que está em voo. É **ela** que esvazia o encoder, não `Invalidate`: sem este passo
    /// um quadro sai do VideoToolbox depois de a track já ter sido liberada, e o `send_frame` lê
    /// uma caixa morta. A inversão é a que a intuição sugere, e é uso após liberação.
    func encerrar() {
        VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
    }

    /// Recuo sob calor ou modo de baixo consumo. O VideoToolbox aceita a mudança em voo; recriar
    /// a sessão custaria um IDR e um engasgo visível.
    func ajustarBitrate(_ novo: Int) {
        // **Os dois juntos, sempre.** Mexer só na média deixaria o teto no valor antigo, e o
        // recuo térmico viraria mais uma ocorrência de "um valor que devia ser um só, escrito em
        // dois lugares" — a família que custou cinco defeitos a este repositório em dois dias.
        let recusadas = CodificadorH264.aplicarTeto(sessao, bps: max(200_000, novo))
        if !recusadas.isEmpty {
            Diagnostico.nota("APP ENCODER teto recusado ao ajustar: \(recusadas.joined(separator: " "))")
        }
    }

    /// Escreve **a média e o teto instantâneo** a partir de um número só.
    ///
    /// `AverageBitRate` sozinho não é teto: em 08/09/2026, no S24, o Android mediu 25 % acima do
    /// alvo por não escrever `KEY_BITRATE_MODE`, e a mesma pergunta feita ao VideoToolbox
    /// devolveu 4 % acima (54 Mbps pedidos, ~56 medidos no receptor a 4K60). Menor, e da mesma
    /// natureza: a média é uma média, e o rádio recebe o pico.
    ///
    /// `DataRateLimits` é o teto de verdade — um par `[bytes, segundos]` que o encoder não
    /// ultrapassa naquela janela. A janela é de **um segundo**, e não menor, porque o quadro-chave
    /// de 4K mede ~997 pacotes (~1,1 MB) contra os 6,75 MB de um segundo a 54 Mbps: cabe com
    /// folga em um segundo e não caberia em janela curta, onde o teto estrangularia justamente o
    /// IDR — que é o quadro que menos pode ser estrangulado.
    ///
    /// Devolve a lista de chaves recusadas, vazia quando tudo passou. **Nada de silêncio.**
    /// **Desligado por padrão, e a medida é o motivo.**
    ///
    /// O teto rígido foi escrito, rodado no iPhone 17e a 4K60 em 08/09/2026, e **reprovado em
    /// campo**. O VideoToolbox não responde a `DataRateLimits` baixando a qualidade: ele **segura
    /// os quadros**. Medido, contra a mesma célula sem teto no mesmo aparelho e mesmo cardápio:
    ///
    /// | | sem teto | com teto |
    /// |---|---|---|
    /// | câmera → encoder | 60,0 → 57,9 fps | 60,0 → **34,1 fps** |
    /// | receptor | 57,8 fps | **37,7 fps** |
    /// | pacotes por janela de 504 ms | 2.939 | 2.037 |
    /// | descartes na fila do emissor | ~1 | **989, crescendo ~26/s** |
    ///
    /// `freados=0` e `encoder=0` nos descartes: não era o nosso freio nem a fila do encoder — com
    /// `tetoEmVoo = 2`, o encoder deixou de devolver a tempo e a submissão passou a recusar.
    /// **Quarenta por cento da taxa de quadros para economizar quatro por cento de bits**, porque
    /// o excesso do VideoToolbox era 4 % (54 Mbps pedidos, ~56 medidos) e não os 25 % que o
    /// MediaCodec tinha do outro lado.
    ///
    /// Calibrar o fator até o número ficar bonito seria ajustar a uma cena. A medida diz que a
    /// troca está errada para este produto, então o padrão é **não escrever a chave** — e o código
    /// fica, com a medida ao lado, para quem um dia tiver motivo para reabrir.
    static let tetoRigidoLigado = false

    /// Escreve a média e — se [tetoRigidoLigado] — o teto instantâneo, **a partir de um número só**.
    ///
    /// Existe como função única porque `ajustarBitrate` (o recuo térmico de 1 Hz) também a chama:
    /// mexer só na média deixaria o teto no valor antigo, e seria mais uma ocorrência de "um valor
    /// que devia ser um só, escrito em dois lugares".
    static func aplicarTeto(_ sessao: VTCompressionSession, bps: Int) -> [String] {
        var recusadas: [String] = []
        let media = VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AverageBitRate,
                                         value: NSNumber(value: bps))
        if media != noErr { recusadas.append("AverageBitRate=\(media)") }
        guard tetoRigidoLigado else { return recusadas }
        let bytesPorSegundo = NSNumber(value: bps / 8)
        let limites = [bytesPorSegundo, NSNumber(value: 1.0)] as CFArray
        let teto = VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_DataRateLimits,
                                        value: limites)
        if teto != noErr { recusadas.append("DataRateLimits=\(teto)") }
        return recusadas
    }

    /// O que a sessão **respondeu**, e não o que nós pedimos — o `getInputFormat()` do iOS.
    ///
    /// `VTSessionCopyProperty` é a única testemunha de que a chave pegou. Este repositório já
    /// publicou uma célula de bancada por confiar no valor escrito em vez do lido de volta.
    func tetoVigente() -> String {
        func ler(_ chave: CFString) -> String {
            var valor: CFTypeRef?
            let estado = VTSessionCopyProperty(sessao, key: chave, allocator: nil, valueOut: &valor)
            guard estado == noErr, let v = valor else { return "ausente(\(estado))" }
            if let n = v as? NSNumber { return "\(n)" }
            if let a = v as? [NSNumber] { return "[\(a.map { "\($0)" }.joined(separator: ","))]" }
            return "?"
        }
        return "media=\(ler(kVTCompressionPropertyKey_AverageBitRate))"
            + " teto=\(ler(kVTCompressionPropertyKey_DataRateLimits))"
    }

    /// Submete um quadro. Devolve `false` quando descartou por fila cheia — que é comportamento
    /// certo, não erro.
    @discardableResult
    func encodar(_ imagem: CVPixelBuffer, pts: CMTime, duracao: CMTime, forcarIDR: Bool) -> Bool {
        travaDoVoo.lock()
        if emVoo >= tetoEmVoo {
            travaDoVoo.unlock()
            contarDescartePorFila()
            return false
        }
        emVoo += 1
        travaDoVoo.unlock()

        let propriedades: CFDictionary? = forcarIDR
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil

        // O sinal de vídeo é lido aqui, do buffer que está sendo submetido: o callback não recebe
        // o pixel buffer, e a format description comprimida do VideoToolbox não propaga faixa nem
        // cor quando a origem é `420v` — medido em 2026-08-24.
        let sinal = RemendoDeSPS.SinalDeVideo.doPixelBuffer(imagem)

        let estado = VTCompressionSessionEncodeFrame(
            sessao, imageBuffer: imagem, presentationTimeStamp: pts, duration: duracao,
            frameProperties: propriedades, infoFlagsOut: nil
        ) { [weak self] estado, sinalizadores, amostra in
            guard let self else { return }
            defer {
                self.travaDoVoo.lock(); self.emVoo -= 1; self.travaDoVoo.unlock()
            }
            guard estado == noErr, !sinalizadores.contains(.frameDropped), let amostra,
                  CMSampleBufferGetNumSamples(amostra) > 0
            else {
                self.contarDescartePeloEncoder()
                return
            }
            self.entregar(amostra, pts: pts, sinal: sinal)
        }
        if estado != noErr {
            travaDoVoo.lock(); emVoo -= 1; travaDoVoo.unlock()
            contarDescartePeloEncoder()
            return false
        }
        return true
    }

    // --- AVCC → Annex-B, num buffer reaproveitado ---------------------------------------------

    private func entregar(_ amostra: CMSampleBuffer, pts: CMTime,
                          sinal: RemendoDeSPS.SinalDeVideo?) {
        let chave = CodificadorH264.eQuadroChave(amostra)
        guard let blocos = CMSampleBufferGetDataBuffer(amostra) else { return }

        var total = 0
        var dados: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blocos, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &dados) == noErr,
              let dados else { return }

        // A dimensão da saída é anotada **fora** da trava do buffer: ela é instrumento, e
        // instrumento não entra na seção crítica do caminho do quadro.
        if let formato = CMSampleBufferGetFormatDescription(amostra) {
            travaDoRelato.lock()
            if _dimensaoDaSaida == "?" {
                let d = CMVideoFormatDescriptionGetDimensions(formato)
                _dimensaoDaSaida = "\(d.width)x\(d.height)"
            }
            travaDoRelato.unlock()
        }

        travaDoBuffer.lock()
        defer { travaDoBuffer.unlock() }

        var escrito = 0

        // Todo IDR leva SPS e PPS junto — sem isso quem entra na sessão depois fica sem imagem,
        // que é exatamente o defeito medido no Windows no M1 e o que `idrs_without_parameters`
        // denuncia do lado do núcleo.
        if chave, let formato = CMSampleBufferGetFormatDescription(amostra) {
            var quantos = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formato, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &quantos,
                nalUnitHeaderLengthOut: nil)
            for i in 0..<quantos {
                var ponteiro: UnsafePointer<UInt8>?
                var tamanho = 0
                let e = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formato, parameterSetIndex: i, parameterSetPointerOut: &ponteiro,
                    parameterSetSizeOut: &tamanho, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                guard e == noErr, let ponteiro else { continue }
                // O SPS sai reescrito para **declarar** que este encoder não reordena quadro; sem
                // isso o decodificador do outro lado infere o teto do nível e empilha até nove
                // quadros antes de entregar o primeiro. Ver `RemendoDeSPS`.
                if (ponteiro[0] & 0x1F) == 7 {
                    let novo = remendoDeSPS.spsParaEnviar(
                        UnsafeRawBufferPointer(start: ponteiro, count: tamanho), sinal: sinal)
                    garantir(escrito + 4 + novo.count)
                    escreverInicio(em: escrito); escrito += 4
                    novo.withUnsafeBytes { (buffer + escrito).copyMemory(from: $0.baseAddress!, byteCount: novo.count) }
                    escrito += novo.count
                    continue
                }
                garantir(escrito + 4 + tamanho)
                escreverInicio(em: escrito); escrito += 4
                (buffer + escrito).copyMemory(from: ponteiro, byteCount: tamanho)
                escrito += tamanho
            }
        }

        dados.withMemoryRebound(to: UInt8.self, capacity: total) { bytes in
            var deslocamento = 0
            while deslocamento + 4 <= total {
                let tamanho = (Int(bytes[deslocamento]) << 24) | (Int(bytes[deslocamento + 1]) << 16)
                    | (Int(bytes[deslocamento + 2]) << 8) | Int(bytes[deslocamento + 3])
                deslocamento += 4
                guard tamanho > 0, deslocamento + tamanho <= total else { break }
                garantir(escrito + 4 + tamanho)
                escreverInicio(em: escrito); escrito += 4
                (buffer + escrito).copyMemory(from: bytes + deslocamento, byteCount: tamanho)
                escrito += tamanho
                deslocamento += tamanho
            }
        }

        guard escrito > 0 else { return }
        aoSair?(UnsafeRawBufferPointer(start: buffer, count: escrito), pts, chave)
    }

    private func escreverInicio(em posicao: Int) {
        let p = (buffer + posicao).assumingMemoryBound(to: UInt8.self)
        p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 1
    }

    /// Cresce geometricamente e só cresce: em regime não realoca nunca, que é o ponto.
    private func garantir(_ preciso: Int) {
        guard preciso > capacidade else { return }
        travaDoRelato.lock(); _crescimentosDoBuffer += 1; travaDoRelato.unlock()
        var nova = capacidade
        while nova < preciso { nova *= 2 }
        let novo = UnsafeMutableRawPointer.allocate(byteCount: nova, alignment: 16)
        novo.copyMemory(from: buffer, byteCount: capacidade)
        buffer.deallocate()
        buffer = novo
        capacidade = nova
    }

    /// Convenção do VideoToolbox: sem o attachment `NotSync` (ou com ele em `false`), é sync
    /// sample — isto é, IDR.
    static func eQuadroChave(_ amostra: CMSampleBuffer) -> Bool {
        guard let lista = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: false)
                as? [[CFString: Any]], let primeiro = lista.first
        else { return true }
        return !((primeiro[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }
}
