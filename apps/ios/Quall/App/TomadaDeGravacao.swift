import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// **Uma gravação, do primeiro quadro ao arquivo fechado** (R5 fase 3,
/// `docs/teleprompter-com-camera.md` §5). Quem decide começar e parar é o `GravadorLocal`; esta
/// classe só grava.
///
/// # O caminho
///
/// - **O vídeo**: cada quadro da câmera (a vaga do gravador no `DonoDaCaptura`, na fila da captura)
///   vai a um **segundo `VTCompressionSession`**, H.264 High, no tamanho da captura — a melhor imagem
///   do aparelho, sem reescala —, e o `CMSampleBuffer` AVCC que sai vai **de passagem** a um
///   `AVAssetWriter` MP4. É a receita da S-I1 (§8.2: dois VideoToolbox + writer fragmentado de
///   passagem, 10 min a 30 fps no iPhone 7, perda 0).
/// - **O PTS é o da câmera**, sem régua: o fps é variável (cai em pouca luz), e cada amostra do MP4
///   dura até a seguinte. O zero do arquivo (`startSession`) é o **primeiro quadro gravado**.
/// - **O som**: os buffers do microfone (já no relógio da câmera: o dono converte) são reamostrados
///   para 48 kHz mono e postos **na régua de amostras do arquivo**: a amostra *k* está em
///   `t0 + k/48000`. Cada buffer cai onde o PTS dele manda; um buraco vira **silêncio** e uma
///   sobreposição é cortada. Com o botão do microfone desligado (ou ainda não ligado), o arquivo
///   recebe silêncio: **a track de som existe desde o começo** (§5.2), e o AAC é do próprio writer.
/// - **Fragmentado** (`movieFragmentInterval` = 2 s): um fim abrupto (o processo morto) deixa o
///   arquivo legível até o último fragmento (S-I1: faltaram 1,5 s). O órfão é salvo na volta
///   (`GravacoesPendentes`).
///
/// # Filas
///
/// - `quadroDaCaptura`: fila da câmera. Só codifica (assíncrono); nunca toca no writer.
/// - a saída do VideoToolbox e `audioDaCaptura`: vão para a `fila` desta tomada, serial, **dona do
///   writer e da régua do som**.
/// - `parar`: de qualquer thread.
final class TomadaDeGravacao: NSObject, AssinanteDaCaptura {

    /// A taxa da régua do som, e a do AAC.
    static let taxaDoSom: Double = 48_000
    /// O fragmento do MP4 (o mesmo da S-I1).
    static let fragmento = CMTime(seconds: 2, preferredTimescale: 600)
    /// Sem som do microfone há mais que isto (em tempo de vídeo), a régua recebe silêncio até aqui
    /// atrás do último quadro. Maior que o atraso de entrega do microfone, para não cortar som real.
    static let folgaDoSilencio: Double = 0.35
    /// O teto da folga viva (`folgaAtual`): o som real mais atrasado que isto vira silêncio.
    static let folgaMaxima: Double = 2.0
    /// Até quanto o som real espera depois do último quadro, no fim.
    static let esperaDoSomNoFim: Double = 0.4

    let url: URL
    let numero: Int
    let criadoEm = Date()

    /// Chamados **na principal**.
    var aoPrimeiroQuadro: (() -> Void)?
    /// O codificador nasceu **menor que a captura** pelo calor (o arquivo sai reduzido). Não é
    /// chamado quando a captura já cabe em 720p (aí quente não muda nada).
    var aoReduzir: ((String) -> Void)?
    var aoFalhar: ((String) -> Void)?

    private let fila: DispatchQueue

    // --- a fila da câmera (e o fim), sob `travaDoCodificador` ------------------------------------
    private let travaDoCodificador = NSLock()
    private var codificador: CodificadorDaGravacao?
    private var semCodificador = false
    /// O `parar` já passou por aqui: nenhum codificador novo nasce depois dele.
    private var codificadorEncerrado = false
    private var dimensao: (largura: Int32, altura: Int32)?
    private let fps: Int

    // --- partilhado, sob `trava` ---------------------------------------------------------------
    private let trava = NSLock()
    private var _aceitaVideo = true
    private var _aceitaSom = true
    private var _quadrosDaCamera: UInt64 = 0
    private var _dimensaoErrada: UInt64 = 0
    private var _dimensaoErradaRelatada = false
    private var _quadroChave = false
    /// `systemUptime` do último quadro que entrou no arquivo: o gravador para quando ele envelhece
    /// (revisão de 24/09, B1: um arquivo que parou de receber não pode seguir "gravando").
    private var _ultimoAnexadoEm: Double = 0
    /// Os quadros seguidos do mesmo tamanho antes de o codificador nascer (B1).
    private var tamanhoCandidato: (Int32, Int32)?
    private var seguidosDoMesmoTamanho = 0
    /// A contagem do codificador guardada antes de ele sumir, para a linha do fim.
    private var contagemFinal: CodificadorDaGravacao.Contagem?

    // --- a `fila` ------------------------------------------------------------------------------
    private var writer: AVAssetWriter?
    private var entradaDeVideo: AVAssetWriterInput?
    private var entradaDeSom: AVAssetWriterInput?
    private var t0: CMTime = .invalid
    private var ultimoPts: CMTime = .invalid
    private var intervalo: CMTime = .invalid
    private var anexados: UInt64 = 0
    private var recusadosPeloWriter: UInt64 = 0
    private var falhasDeAnexo: UInt64 = 0
    private var buracoMaior: Double = 0
    private var buracoMaiorNoRelato: Double = 0
    private var falhou: String?
    /// O mesmo `falhou`, no idioma da interface (o recado da tela). Na `fila`, como ele.
    private var falhouNaTela: String?
    private var fechando = false
    /// O fim do vídeo, fixado no `parar`: o som não passa dele.
    private var fimDoVideo: CMTime = .invalid

    // a régua do som (só na `fila`)
    private var escritas: Int64 = 0
    private var formatoDoSom: CMAudioFormatDescription?
    private let formatoDeSaida = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: TomadaDeGravacao.taxaDoSom,
                                              channels: 1, interleaved: true)
    private var conversor: AVAudioConverter?
    private var formatoDeEntrada: AVAudioFormat?
    private var assinaturaDaEntrada = ""
    private var ultimaAmostra: Int16 = 0
    private var somReal: Int64 = 0
    private var silencio: Int64 = 0
    private var lacunas: UInt64 = 0
    private var inseridas: Int64 = 0
    private var tiradas: Int64 = 0
    private var somRecusado: Int64 = 0
    private var somAntesDoZero: UInt64 = 0
    /// Buffers de som com o PTS mais de 1 s à frente do último quadro: fora da régua.
    private var somForaDoRelogio: UInt64 = 0
    /// **A folga viva** (§8.12.11, a revisão de 27/09, B1): o iPhone 7 quente entregou o microfone com
    /// 0,5–2 s de atraso, e a folga fixa de 350 ms punha silêncio no lugar e depois **cortava** o som real
    /// que chegava (`silencio≈tiradas`: ~397 s de 1800). A folga passa a seguir o atraso do som real visto
    /// nas duas últimas janelas de 10 s, mais 150 ms, entre 350 ms e `folgaMaxima`; sem som real (o
    /// microfone desligado), volta a 350 ms em 20 s. Só na `fila`.
    private var folgaAtual: Double = TomadaDeGravacao.folgaDoSilencio
    private var atrasoDoSomNaJanela: Double = 0
    private var atrasoDoSomAnterior: Double = 0
    private var atrasoDoSomMaximo: Double = 0
    /// Buffers do microfone que o conversor devolveu vazios (ele guardou as amostras para o seguinte).
    private var pcmVazio: UInt64 = 0
    /// O som que chega antes de o writer existir (o primeiro quadro ainda no codificador): guardado
    /// e posto na régua quando ele abre — a parte depois do zero não se perde. Até ~1 s.
    private var somAntesDoWriter: [(pcm: [Int16], pts: CMTime)] = []
    private var entradaDoSom = "nenhuma"

    /// **O aparelho estava quente ao tocar em Gravar** (§8.12.1): o arquivo sai em 720p, e o
    /// VideoToolbox da gravação reduz a captura (que não muda de formato, para não ciclar a câmera).
    /// Fixo pela vida da tomada: o arquivo é um só.
    let reduzidaPeloCalor: Bool

    init(url: URL, numero: Int, fps: Int, reduzidaPeloCalor: Bool = false) {
        self.url = url
        self.numero = numero
        self.fps = max(1, fps)
        self.reduzidaPeloCalor = reduzidaPeloCalor
        fila = DispatchQueue(label: "br.com.queven.quall.gravacao.\(numero)", qos: .userInitiated)
        super.init()
    }

    // --- AssinanteDaCaptura ----------------------------------------------------------------------

    /// Na fila da câmera. Só codifica: o writer é da `fila`.
    func quadroDaCaptura(_ amostra: CMSampleBuffer, imagem: CVPixelBuffer) {
        trava.lock()
        let aceita = _aceitaVideo
        if aceita { _quadrosDaCamera &+= 1 }
        trava.unlock()
        guard aceita else { return }
        let l = Int32(CVPixelBufferGetWidth(imagem)), a = Int32(CVPixelBufferGetHeight(imagem))
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        guard pts.isValid else { return }

        travaDoCodificador.lock()
        defer { travaDoCodificador.unlock() }
        guard !codificadorEncerrado else { return }
        if codificador == nil, !semCodificador {
            // O tamanho do arquivo é o de 3 quadros seguidos iguais: um quadro velho, do ângulo de
            // antes do congelamento, não fixa o arquivo (revisão de 24/09, B1).
            if let c = tamanhoCandidato, c.0 == l, c.1 == a { seguidosDoMesmoTamanho += 1 } else {
                tamanhoCandidato = (l, a)
                seguidosDoMesmoTamanho = 1
            }
            guard seguidosDoMesmoTamanho >= 3 else { return }
            // O tamanho do arquivo: o da captura, ou 720p se o aparelho estava quente ao tocar em
            // Gravar. `dimensao` continua sendo o da **entrada** (é contra ela que cada quadro é
            // conferido); o VideoToolbox reduz.
            let (ls, as_) = PoliticaDeCalor.tamanhoDaGravacao(largura: l, altura: a, quente: reduzidaPeloCalor)
            let taxa = TomadaDeGravacao.bitrate(largura: Int(ls), altura: Int(as_), fps: fps)
            do {
                let c = try CodificadorDaGravacao(largura: ls, altura: as_, fps: fps, bitrate: taxa,
                                                  reescala: ls != l || as_ != a)
                c.saida = { [weak self] s in
                    guard let self else { return }
                    self.fila.async {
                        let cpu = MedidorDeCpu.agora()
                        self.anexarVideo(s)
                        MedidorDeCpu.somar("gravacao_escritor", desde: cpu)
                    }
                }
                codificador = c
                dimensao = (l, a)
                Diagnostico.nota("APP GRAVACAO #\(numero) codificador de pé: \(ls)x\(as_) H.264 High"
                    + " bitrate=\(taxa) fps_esperado=\(fps) IDR a cada 2 s"
                    + (ls != l || as_ != a ? " (reduzido de \(l)x\(a) pelo calor)" : ""))
                if ls != l || as_ != a {
                    let tamanho = "\(ls)x\(as_)"
                    naPrincipal { [weak self] in self?.aoReduzir?(tamanho) }
                }
            } catch {
                semCodificador = true
                let motivo = "O codificador da gravação não abriu (\(error))."
                Diagnostico.falha("APP GRAVACAO #\(numero) codificador não abriu: \(SanitizacaoDoLog.erro(error))")
                naPrincipal { [weak self] in self?.aoFalhar?(motivo) }
                return
            }
        }
        guard let c = codificador, let d = dimensao else { return }
        guard d.largura == l, d.altura == a else {
            // O ângulo está congelado gravando: isto não deveria acontecer. O arquivo tem tamanho
            // fixo, e o quadro de outro tamanho fica de fora — contado, e dito uma vez.
            trava.lock()
            _dimensaoErrada &+= 1
            let dizer = !_dimensaoErradaRelatada
            _dimensaoErradaRelatada = true
            trava.unlock()
            if dizer {
                Diagnostico.falha("APP GRAVACAO #\(numero) quadro \(l)x\(a) num arquivo \(d.largura)x\(d.altura):"
                    + " fica de fora (o ângulo deveria estar congelado)")
            }
            return
        }
        trava.lock(); let chave = _quadroChave; _quadroChave = false; trava.unlock()
        c.codificar(imagem, pts: pts, forcarChave: chave)
    }

    /// Há quanto tempo o último quadro entrou no arquivo (`nil` antes do primeiro). De qualquer thread.
    var ultimoAnexadoHa: Double? {
        trava.lock(); defer { trava.unlock() }
        guard _ultimoAnexadoEm > 0 else { return nil }
        return ProcessInfo.processInfo.systemUptime - _ultimoAnexadoEm
    }

    /// A câmera voltou de uma interrupção **curta** (menos de 2 s: o `GravadorLocal` não fecha mais a
    /// gravação por ela, §8.12.9) ou do segundo plano: o próximo quadro sai IDR, e o buraco fica no
    /// arquivo (o PTS é o da câmera). Um PTS que volte para trás (o relógio da sessão trocado) é
    /// recusado e contado em `falhas_de_anexo`, e a regra "o arquivo parou de receber" fecha em 2 s
    /// se não houver quadro novo depois — com o motivo dito.
    func capturaRetomada() {
        pedirQuadroChave()
        Diagnostico.nota("APP GRAVACAO #\(numero) a câmera voltou: o próximo quadro sai IDR")
    }

    /// Na fila do áudio do dono.
    func audioDaCaptura(_ amostra: CMSampleBuffer) {
        trava.lock(); let aceita = _aceitaSom; trava.unlock()
        guard aceita else { return }
        fila.async { [weak self] in
            let cpu = MedidorDeCpu.agora()
            self?.consumirSom(amostra)
            MedidorDeCpu.somar("gravacao_som", desde: cpu)
        }
    }

    // --- o vídeo, na `fila` -------------------------------------------------------------------

    private func anexarVideo(_ s: CMSampleBuffer) {
        guard falhou == nil, !fechando else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        guard pts.isValid else { return }
        if writer == nil {
            guard criarWriter(dica: CMSampleBufferGetFormatDescription(s), zero: pts) else { return }
        }
        guard let w = writer, let v = entradaDeVideo else { return }
        if w.status == .failed {
            let detalhe = w.error.map { "\($0)" } ?? "sem erro"
            falhar("o arquivo falhou: \(detalhe)", naTela: tr("o arquivo falhou: %@", detalhe))
            return
        }
        // O PTS nunca volta (o VideoToolbox não reordena: `AllowFrameReordering = false`); um que
        // volte seria recusado pelo writer e derrubaria o arquivo.
        if ultimoPts.isValid, CMTimeCompare(pts, ultimoPts) <= 0 { falhasDeAnexo &+= 1; pedirQuadroChave(); return }
        if v.isReadyForMoreMediaData {
            if v.append(s) {
                anexados &+= 1
                if ultimoPts.isValid {
                    intervalo = CMTimeSubtract(pts, ultimoPts)
                    let b = CMTimeGetSeconds(intervalo)
                    buracoMaior = max(buracoMaior, b)
                    buracoMaiorNoRelato = max(buracoMaiorNoRelato, b)
                }
                ultimoPts = pts
                trava.lock(); _ultimoAnexadoEm = ProcessInfo.processInfo.systemUptime; trava.unlock()
                if anexados == 1 {
                    naPrincipal { [weak self] in self?.aoPrimeiroQuadro?() }
                }
            } else {
                falhasDeAnexo &+= 1
                pedirQuadroChave()
                if w.status == .failed {
                    let detalhe = w.error.map { "\($0)" } ?? "sem erro"
                    falhar("o arquivo falhou: \(detalhe)", naTela: tr("o arquivo falhou: %@", detalhe))
                }
            }
        } else {
            recusadosPeloWriter &+= 1
            pedirQuadroChave()
        }
        // Sem som real há mais que a folga: silêncio até ela (a track não pode ter buraco).
        preencherSilencio(ate: CMTimeSubtract(pts, CMTime(seconds: folgaAtual,
                                                          preferredTimescale: 48_000)))
    }

    /// Um quadro H.264 que não entrou no arquivo quebra a referência dos seguintes até o próximo IDR:
    /// o próximo `encode` pede um. (Revisão de 24/09, M3.)
    private func pedirQuadroChave() {
        trava.lock(); _quadroChave = true; trava.unlock()
    }

    private func criarWriter(dica: CMFormatDescription?, zero: CMTime) -> Bool {
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            w.movieFragmentInterval = TomadaDeGravacao.fragmento
            w.shouldOptimizeForNetworkUse = false
            // De passagem: o H.264 já vem do nosso VideoToolbox.
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: dica)
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: TomadaDeGravacao.taxaDoSom,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(a) else {
                falhar("o arquivo não aceitou as trilhas de vídeo e som",
                       naTela: tr("o arquivo não aceitou as trilhas de vídeo e som"))
                return false
            }
            w.add(v)
            w.add(a)
            guard w.startWriting() else {
                let detalhe = w.error.map { "\($0)" } ?? "sem erro"
                falhar("o arquivo não começou: \(detalhe)", naTela: tr("o arquivo não começou: %@", detalhe))
                return false
            }
            w.startSession(atSourceTime: zero)
            writer = w
            entradaDeVideo = v
            entradaDeSom = a
            t0 = zero
            var asbd = AudioStreamBasicDescription(
                mSampleRate: TomadaDeGravacao.taxaDoSom, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                                           layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &formatoDoSom)
            let guardado = somAntesDoWriter
            somAntesDoWriter = []
            for a in guardado { posicionarSom(a.pcm, pts: a.pts) }
            Diagnostico.nota("APP GRAVACAO #\(numero) arquivo aberto"
                + " zero=\(String(format: "%.6f", CMTimeGetSeconds(zero))) s (relógio da câmera)"
                + " fragmento=2 s som=AAC 48 kHz mono 128 kbit/s")
            return true
        } catch {
            falhar("o arquivo não abriu: \(error)", naTela: tr("o arquivo não abriu: %@", "\(error)"))
            return false
        }
    }

    // --- o som, na `fila` ---------------------------------------------------------------------

    private func consumirSom(_ amostra: CMSampleBuffer) {
        guard falhou == nil else { return }
        // Convertido já: o buffer da captura volta ao pool dela na hora (guardar `CMSampleBuffer`s da
        // captura pode esgotar o pool do microfone).
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        guard pts.isValid, let pcm = converter(amostra) else { return }
        guard !pcm.isEmpty else { pcmVazio &+= 1; return }
        // O atraso deste som em relação ao quadro mais novo do arquivo: é o que a folga precisa cobrir.
        if ultimoPts.isValid {
            let atraso = CMTimeGetSeconds(CMTimeSubtract(ultimoPts, pts))
            if atraso.isFinite, atraso > atrasoDoSomNaJanela {
                atrasoDoSomNaJanela = atraso
                atrasoDoSomMaximo = max(atrasoDoSomMaximo, atraso)
                recalcularFolga()
            }
        }
        guard t0.isValid, entradaDeSom != nil else {
            // Antes do primeiro quadro no arquivo: guardado. O zero do arquivo é o vídeo, e o que for
            // anterior a ele cai na régua (§5.2); o que vier depois entra.
            somAntesDoWriter.append((pcm, pts))
            if somAntesDoWriter.count > 50 {
                somAntesDoWriter.removeFirst()
                somAntesDoZero &+= 1
            }
            return
        }
        posicionarSom(pcm, pts: pts)
    }

    /// Põe o PCM (48 kHz mono) na régua, onde o PTS dele manda. Na `fila`.
    private func posicionarSom(_ pcm: [Int16], pts: CMTime) {
        let taxa = TomadaDeGravacao.taxaDoSom
        let k = Int64((CMTimeGetSeconds(CMTimeSubtract(pts, t0)) * taxa).rounded())
        // No fim, nada depois do último quadro — nem o silêncio de um buraco.
        if fimDoVideo.isValid,
           k >= Int64((CMTimeGetSeconds(CMTimeSubtract(fimDoVideo, t0)) * taxa).rounded()) { return }
        // Um PTS de som muito à frente do vídeo (um relógio que não converteu) escreveria horas de
        // silêncio de uma vez e cortaria todo o som real depois: fica de fora, contado.
        if ultimoPts.isValid,
           k > Int64((CMTimeGetSeconds(CMTimeSubtract(ultimoPts, t0)) + 1.0) * taxa) {
            somForaDoRelogio &+= 1
            return
        }
        var inicio = 0
        let erro = k - escritas
        let tolerancia: Int64 = 96          // 2 ms: o jitter do PTS e a reamostragem não mexem na régua
        if erro > 480 {
            // Um buraco de verdade (o botão ligado agora, uma interrupção do microfone): silêncio.
            escreverSilencio(erro)
        } else if erro > tolerancia {
            // Um desvio pequeno: a última amostra repetida, sem clique.
            escreverRepetida(erro)
            inseridas &+= erro
        } else if erro < -tolerancia {
            // O som chegou atrás do que já está escrito (silêncio de folga, ou um desvio): o começo
            // dele sai, e a régua não volta.
            let tirar = Int(min(-erro, Int64(pcm.count)))
            inicio = tirar
            tiradas &+= Int64(tirar)
        }
        guard inicio < pcm.count else { return }
        var fatia = Array(pcm[inicio...])
        // No fim, nada depois do último quadro.
        if fimDoVideo.isValid {
            let teto = Int64((CMTimeGetSeconds(CMTimeSubtract(fimDoVideo, t0)) * taxa).rounded())
            let cabe = Int(max(0, teto - escritas))
            if fatia.count > cabe { fatia.removeLast(fatia.count - cabe) }
        }
        guard !fatia.isEmpty else { return }
        ultimaAmostra = fatia[fatia.count - 1]
        somReal &+= Int64(fatia.count)
        escrever(fatia)
    }

    /// PCM do buffer em 48 kHz mono Int16. O conversor é refeito quando o formato de entrada muda.
    private func converter(_ amostra: CMSampleBuffer) -> [Int16]? {
        guard let desc = CMSampleBufferGetFormatDescription(amostra),
              let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let saida = formatoDeSaida else { return nil }
        let n = CMSampleBufferGetNumSamples(amostra)
        guard n > 0 else { return nil }
        let asbd = asbdP.pointee
        let assinatura = "\(asbd.mSampleRate)|\(asbd.mChannelsPerFrame)|\(asbd.mFormatID)"
            + "|\(asbd.mFormatFlags)|\(asbd.mBitsPerChannel)"
        if assinatura != assinaturaDaEntrada {
            let f = AVAudioFormat(cmAudioFormatDescription: desc)
            guard let c = AVAudioConverter(from: f, to: saida) else {
                Diagnostico.falha("APP GRAVACAO #\(numero) AVAudioConverter recusou \(f)")
                return nil
            }
            c.downmix = true
            c.primeMethod = .normal
            conversor = c
            formatoDeEntrada = f
            assinaturaDaEntrada = assinatura
            entradaDoSom = "\(Int(asbd.mSampleRate)) Hz \(asbd.mChannelsPerFrame) ch \(asbd.mBitsPerChannel) bits"
            Diagnostico.nota("APP GRAVACAO #\(numero) som de entrada: \(entradaDoSom) → 48 kHz mono")
        }
        guard let conversor, let formatoDeEntrada,
              let entrada = AVAudioPCMBuffer(pcmFormat: formatoDeEntrada, frameCapacity: AVAudioFrameCount(n))
        else { return nil }
        // `frameLength` antes da cópia (a armadilha da fase 2, `MicrofoneParaOpus`).
        entrada.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            amostra, at: 0, frameCount: Int32(n), into: entrada.mutableAudioBufferList) == noErr else { return nil }
        let capacidade = AVAudioFrameCount(Double(n) * TomadaDeGravacao.taxaDoSom / max(1, asbd.mSampleRate)) + 64
        guard let convertido = AVAudioPCMBuffer(pcmFormat: saida, frameCapacity: capacidade) else { return nil }
        var entregue = false
        var erro: NSError?
        let estado = conversor.convert(to: convertido, error: &erro) { _, situacao in
            if entregue { situacao.pointee = .noDataNow; return nil }
            entregue = true
            situacao.pointee = .haveData
            return entrada
        }
        guard estado != .error, let canal = convertido.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: canal[0], count: Int(convertido.frameLength)))
    }

    private func recalcularFolga() {
        folgaAtual = min(TomadaDeGravacao.folgaMaxima,
                         max(TomadaDeGravacao.folgaDoSilencio, max(atrasoDoSomNaJanela, atrasoDoSomAnterior) + 0.15))
    }

    /// Silêncio na régua até `ate` (no relógio da câmera), se ela estiver atrás.
    private func preencherSilencio(ate: CMTime) {
        guard t0.isValid, ate.isValid else { return }
        let alvo = Int64((CMTimeGetSeconds(CMTimeSubtract(ate, t0)) * TomadaDeGravacao.taxaDoSom).rounded())
        if alvo > escritas { escreverSilencio(alvo - escritas) }
    }

    private func escreverSilencio(_ n: Int64) {
        guard n > 0 else { return }
        lacunas &+= 1
        silencio &+= n
        var falta = n
        while falta > 0 {
            let k = Int(min(falta, 4_800))
            escrever([Int16](repeating: 0, count: k))
            falta -= Int64(k)
        }
        ultimaAmostra = 0
    }

    private func escreverRepetida(_ n: Int64) {
        guard n > 0 else { return }
        escrever([Int16](repeating: ultimaAmostra, count: Int(n)))
    }

    /// Anexa amostras na posição `escritas` da régua, em pedaços de até 4 800 (100 ms). A régua anda
    /// **mesmo** quando o writer recusa: o que vem depois continua no lugar certo, e a recusa é
    /// contada.
    private func escrever(_ amostras: [Int16]) {
        guard let entrada = entradaDeSom, let fmt = formatoDoSom, t0.isValid else { return }
        var i = 0
        while i < amostras.count {
            let k = min(4_800, amostras.count - i)
            let pts = CMTimeAdd(t0, CMTime(value: escritas, timescale: CMTimeScale(TomadaDeGravacao.taxaDoSom)))
            defer { escritas &+= Int64(k); i += k }
            var bloco: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: k * 2,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: k * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bloco) == noErr,
                  let bloco else { somRecusado &+= Int64(k); continue }
            let copiou = amostras.withUnsafeBytes { tudo -> Bool in
                guard let base = tudo.baseAddress else { return false }
                return CMBlockBufferReplaceDataBytes(with: base + i * 2, blockBuffer: bloco,
                                                     offsetIntoDestination: 0, dataLength: k * 2) == noErr
            }
            guard copiou else { somRecusado &+= Int64(k); continue }
            var s: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: fmt,
                sampleCount: k, presentationTimeStamp: pts, packetDescriptions: nil,
                sampleBufferOut: &s) == noErr, let s else { somRecusado &+= Int64(k); continue }
            if entrada.isReadyForMoreMediaData, entrada.append(s) { continue }
            somRecusado &+= Int64(k)
        }
    }

    // --- o fim ------------------------------------------------------------------------------------

    /// O resultado do fim, na principal.
    struct Fim {
        let url: URL
        /// `nil` sem nenhum quadro gravado (o arquivo foi apagado).
        let duracao: Double?
        let quadros: UInt64
        let bytes: Int64
        /// Em português: vai ao diário.
        let erro: String?
        /// O mesmo erro no idioma da interface: vai ao recado da tela.
        var erroNaTela: String?
    }

    /// Para: o vídeo sai na hora, o som espera o que ainda está a caminho (`esperaDoSomNoFim`) e
    /// completa com silêncio até o último quadro, e o writer fecha. `fim` na principal. De qualquer
    /// thread; a segunda chamada não faz nada.
    func parar(motivo: String, fim: @escaping (Fim) -> Void) {
        trava.lock()
        let jaParava = !_aceitaVideo
        _aceitaVideo = false
        trava.unlock()
        guard !jaParava else { return }
        let t = Thread { [self] in
            // O codificador esvazia (as saídas pendentes vão para a `fila`), e só então some.
            travaDoCodificador.lock()
            let c = codificador
            codificador = nil
            codificadorEncerrado = true
            travaDoCodificador.unlock()
            c?.encerrar()
            let contagem = c?.contagem()
            fila.async { [self] in contagemFinal = contagem }
            fila.async { [self] in
                // O fim do vídeo é o último quadro mais a duração dele.
                if ultimoPts.isValid {
                    let dur = intervalo.isValid && CMTimeGetSeconds(intervalo) > 0 && CMTimeGetSeconds(intervalo) < 1
                        ? intervalo : CMTime(value: 1, timescale: CMTimeScale(fps))
                    fimDoVideo = CMTimeAdd(ultimoPts, dur)
                }
            }
            // O som que ainda está a caminho: pelo menos `esperaDoSomNoFim`, e a folga viva quando o
            // microfone está atrasado (senão o último segundo do arquivo sairia em silêncio).
            fila.async { [self] in
                let espera = max(TomadaDeGravacao.esperaDoSomNoFim, folgaAtual)
                fila.asyncAfter(deadline: .now() + espera) { [self] in
                    trava.lock(); _aceitaSom = false; trava.unlock()
                    fechar(motivo: motivo, fim: fim)
                }
            }
        }
        t.name = "quall.gravacao.parar"
        t.start()
    }

    private func fechar(motivo: String, fim: @escaping (Fim) -> Void) {
        fechando = true
        guard let w = writer, anexados > 0, fimDoVideo.isValid else {
            // Nenhum quadro no arquivo: não há o que salvar.
            // Só apaga o que esta tomada criou (revisão M5: um nome repetido não pode apagar o arquivo
            // de outra).
            if let w = writer {
                w.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
            let e = falhou
            let et = falhouNaTela
            Diagnostico.nota("APP GRAVACAO #\(numero) fechada sem nenhum quadro; arquivo apagado"
                + (e.map { " (\($0))" } ?? "") + " parou_por=\(motivo)")
            naPrincipal { fim(Fim(url: self.url, duracao: nil, quadros: 0, bytes: 0, erro: e, erroNaTela: et)) }
            return
        }
        // O som até o fim do vídeo, para as duas trilhas terminarem juntas.
        preencherSilencio(ate: fimDoVideo)
        let resumo = self.resumo()
        if w.status == .writing {
            entradaDeVideo?.markAsFinished()
            entradaDeSom?.markAsFinished()
            w.endSession(atSourceTime: fimDoVideo)
            let inicio = CFAbsoluteTimeGetCurrent()
            let duracao = CMTimeGetSeconds(CMTimeSubtract(fimDoVideo, t0))
            let quadros = anexados
            w.finishWriting { [self] in
                let ok = w.status == .completed
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
                let detalhe = w.error.map { "\($0)" } ?? "status \(w.status.rawValue)"
                let erro = ok ? falhou : "o arquivo não fechou: \(detalhe)"
                let erroNaTela = ok ? falhouNaTela : tr("o arquivo não fechou: %@", detalhe)
                GravadorLocal.dizerNosDois(String(format: "APP GRAVACAO #%d fechada em %.0f ms: %@ duracao=%.3f s bytes=%lld",
                                        numero, (CFAbsoluteTimeGetCurrent() - inicio) * 1000,
                                        ok ? "completa" : "INCOMPLETA", duracao, bytes)
                    + " \(resumo)" + (erro.map { " erro=\(SanitizacaoDoLog.causaExterna($0))" } ?? "")
                    + " writer_status=\(w.status.rawValue)"
                    + " writer_erro=\(w.error.map { SanitizacaoDoLog.erro($0) } ?? "nenhum")"
                    + " parou_por=\(SanitizacaoDoLog.causaExterna(motivo))")
                naPrincipal { fim(Fim(url: self.url, duracao: duracao, quadros: quadros, bytes: bytes, erro: erro,
                                      erroNaTela: erroNaTela)) }
            }
        } else {
            // O writer já falhou: o arquivo fragmentado fica como está, e é tratado como órfão.
            let detalhe = w.error.map { "\($0)" } ?? "status \(w.status.rawValue)"
            let e = falhou ?? "o arquivo falhou: \(detalhe)"
            let et = falhouNaTela ?? tr("o arquivo falhou: %@", detalhe)
            Diagnostico.falha("APP GRAVACAO #\(numero) não fecha; fica como pendente. \(resumo)"
                + " writer_status=\(w.status.rawValue) writer_erro=\(w.error.map { SanitizacaoDoLog.erro($0) } ?? "nenhum")"
                + " parou_por=\(SanitizacaoDoLog.causaExterna(motivo))")
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            let q = anexados
            naPrincipal { fim(Fim(url: self.url, duracao: nil, quadros: q, bytes: bytes, erro: e, erroNaTela: et)) }
        }
    }

    /// `motivo` em português (o diário e quem pediu para parar); `naTela`, no idioma da interface.
    private func falhar(_ motivo: String, naTela: String) {
        guard falhou == nil else { return }
        falhou = motivo
        falhouNaTela = naTela
        Diagnostico.falha("APP GRAVACAO #\(numero) \(SanitizacaoDoLog.causaExterna(motivo))"
            + " writer_status=\(writer?.status.rawValue ?? -1)"
            + " writer_erro=\(writer?.error.map { SanitizacaoDoLog.erro($0) } ?? "nenhum")")
        naPrincipal { [weak self] in self?.aoFalhar?(motivo) }
    }

    // --- o relato ---------------------------------------------------------------------------------

    /// A linha de 10 s (e a do fim). **Na `fila`**; de fora, `relatar()`.
    private func resumo() -> String {
        trava.lock()
        let camera = _quadrosDaCamera
        let errada = _dimensaoErrada
        trava.unlock()
        let cod = contagemFinal ?? travaDoCodificador.comTrava { codificador?.contagem() } ?? CodificadorDaGravacao.Contagem()
        let segundos = t0.isValid && ultimoPts.isValid ? CMTimeGetSeconds(CMTimeSubtract(ultimoPts, t0)) : 0
        let fpsMedio = segundos > 0 ? Double(anexados > 0 ? anexados - 1 : 0) / segundos : 0
        let somS = Double(escritas) / TomadaDeGravacao.taxaDoSom
        return "camera=\(camera) anexados=\(anexados)"
            + String(format: " fps_medio=%.2f video_s=%.3f som_s=%.3f", fpsMedio, segundos, somS)
            + String(format: " buraco_maior=%.0f ms", buracoMaior * 1000)
            + " descartados_no_codificador=\(cod.descartadosEmVoo) pelo_vt=\(cod.descartadosPeloVT)"
            + " falhas_vt=\(cod.falhas) recusados_pelo_writer=\(recusadosPeloWriter) falhas_de_anexo=\(falhasDeAnexo)"
            + " dimensao_errada=\(errada)"
            + " som: entrada=\(entradaDoSom) real=\(somReal) silencio=\(silencio) lacunas=\(lacunas)"
            + " inseridas=\(inseridas) tiradas=\(tiradas) recusado=\(somRecusado) antes_do_zero=\(somAntesDoZero) fora_do_relogio=\(somForaDoRelogio)"
            + String(format: " folga=%.0f ms atraso_do_som_max=%.0f ms", folgaAtual * 1000, atrasoDoSomMaximo * 1000)
            + " pcm_vazio=\(pcmVazio)"
    }

    /// Escreve a linha de 10 s no diário, pela `fila`.
    func relatar(espacoLivre: Int64?) {
        fila.async { [self] in
            let b = buracoMaiorNoRelato
            buracoMaiorNoRelato = 0
            // A janela da folga viva anda com o relato de 10 s.
            atrasoDoSomAnterior = atrasoDoSomNaJanela
            atrasoDoSomNaJanela = 0
            recalcularFolga()
            let termico = ProcessInfo.processInfo.thermalState.rawValue
            Diagnostico.nota("APP GRAVACAO #\(numero) gravando: \(resumo())"
                + String(format: " buraco_maior_na_janela=%.0f ms", b * 1000)
                + " espaco_livre=\(espacoLivre.map { "\($0 / 1_000_000) MB" } ?? "?") termico=\(termico)")
        }
    }

    /// O bitrate da gravação: ~0,26 bit por pixel por quadro (1080p30 dá 16 Mbit/s, o da S-I1), entre
    /// 6 e 50 Mbit/s.
    static func bitrate(largura: Int, altura: Int, fps: Int) -> Int {
        let b = Double(largura * altura * max(1, min(fps, 60))) * 0.26
        return Int(min(50_000_000, max(6_000_000, b)))
    }
}

/// O `VTCompressionSession` da gravação: H.264 High, sem reordenar, IDR a cada 2 s, e um teto de
/// quadros em voo que descarta e **conta** em vez de enfileirar (a receita da S-I1). A saída é o
/// `CMSampleBuffer` AVCC, que o `AVAssetWriterInput` de passagem aceita.
final class CodificadorDaGravacao {
    private let sessao: VTCompressionSession
    var saida: ((CMSampleBuffer) -> Void)?

    private let trava = NSLock()
    private var emVoo = 0
    private let tetoEmVoo = 3
    private var entregues = 0
    private var descartadosEmVoo = 0
    private var falhas = 0
    private var descartadosPeloVT = 0

    struct Falha: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "VTCompressionSessionCreate: \(status)" }
    }

    struct Contagem {
        var entregues = 0, descartadosEmVoo = 0, falhas = 0, descartadosPeloVT = 0
    }

    /// `reescala`: o arquivo sai menor que a captura (a gravação que começou quente, §8.12.1). Aí a
    /// sessão de transferência do VideoToolbox passa a existir, e ela decide a faixa de cor pelo
    /// `imageBufferAttributes` (a matriz de 23/08 em `CodificadorH264`): declarada limitada, como a
    /// captura (`420v`), para a reescala não trocar a faixa. Sem reescala, como sempre foi (`nil`).
    init(largura: Int32, altura: Int32, fps: Int, bitrate: Int, reescala: Bool = false) throws {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: largura, height: altura, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: reescala ? CodificadorH264.entradaEmFaixaLimitada : nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let sessao = s else { throw Falha(status: st) }
        self.sessao = sessao
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (2 * fps) as CFNumber)
        VTSessionSetProperty(sessao, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(sessao)
    }

    /// Na fila da câmera. A duração fica em aberto: o fps é variável, e o MP4 a tira do PTS seguinte.
    func codificar(_ imagem: CVImageBuffer, pts: CMTime, forcarChave: Bool = false) {
        trava.lock()
        if emVoo >= tetoEmVoo {
            descartadosEmVoo += 1
            trava.unlock()
            return
        }
        emVoo += 1
        trava.unlock()
        let st = VTCompressionSessionEncodeFrame(
            sessao, imageBuffer: imagem, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: forcarChave ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil,
            infoFlagsOut: nil
        ) { [weak self] status, flags, amostra in
            guard let self else { return }
            self.trava.lock()
            self.emVoo = max(0, self.emVoo - 1)
            if status != noErr { self.falhas += 1 }
            else if flags.contains(.frameDropped) || amostra == nil { self.descartadosPeloVT += 1 }
            else { self.entregues += 1 }
            self.trava.unlock()
            if status == noErr, let amostra { self.saida?(amostra) }
        }
        if st != noErr {
            trava.lock(); emVoo = max(0, emVoo - 1); falhas += 1; trava.unlock()
        }
    }

    func contagem() -> Contagem {
        trava.lock(); defer { trava.unlock() }
        return Contagem(entregues: entregues, descartadosEmVoo: descartadosEmVoo, falhas: falhas,
                        descartadosPeloVT: descartadosPeloVT)
    }

    /// Esvazia (as saídas pendentes saem pelo `saida`) e invalida. Depois disto, `codificar` não
    /// pode ser chamado — quem chama segura a trava do codificador (`TomadaDeGravacao`).
    func encerrar() {
        VTCompressionSessionCompleteFrames(sessao, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(sessao)
    }
}

private extension NSLock {
    func comTrava<T>(_ f: () -> T) -> T { lock(); defer { unlock() }; return f() }
}
