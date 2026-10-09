import AVFoundation
import Foundation

/// MP4 do que chegou pela rede. O H.264 passa sem outro codificador; só o PCM recebido vira AAC.
/// A fila tem teto próprio: o disco nunca segura a exibição nem conserva quadros sem limite.
final class TomadaRecebida {
    private static let maxWriters = 3
    struct Resultado { var arquivos: [URL]; var preservados: [URL]; var erro: String? }
    private struct Som {
        let pcm: [Int16], taxa: Int, canais: Int, ts: UInt64, chegada: Double
    }
    private let fila = DispatchQueue(label: "br.com.queven.quall.receber.gravacao", qos: .utility)
    private let porta = NSLock()
    private var aceitaVideo = true, aceitaSom = true, videosPendentes = 0, sonsPendentes = 0, bytesPendentes = 0, perdeuNaFila = false
    private let pasta: URL, nome: String
    private let aoComecar: () -> Void, aoPedirIdr: () -> Void
    private let aoFalhar: (String) -> Void, aoAbrir: (URL) -> Void, aoDescartar: (URL) -> Void
    private var writer: AVAssetWriter?, video: AVAssetWriterInput?, audio: AVAssetWriterInput?
    private var trecho: ParteRecebida?
    private var descricao: CMVideoFormatDescription?, sps = Data(), pps = Data()
    private var leitura = ReferenciasH264Recebidas()
    private var esperandoIdr = true, iniciou = false, parando = false, fechoPedido = false
    private var zero: UInt64?, chegadaZero = 0.0, ultimoVideo: UInt64?
    private var chegadaUltimoVideo = 0.0, chegadaDoFim: Double?, limiteFinalDoSom: Int64?
    private var amostraPendente: CMSampleBuffer?, ptsPendente: Int64 = 0, passoUs: Int64 = 33_333
    private var formatoDoSom: (taxa: Int, canais: Int)?
    private var videoOffset: Int64?, audioOffset: Int64?, audioFallbackOffset: Int64?
    private var somEmEspera: [Som] = [], ultimoFimDoSom: Int64 = 0
    private var parte = 0, finalizando = 0, arquivos: [URL] = [], preservados: [URL] = [], erro: String?
    private var fim: ((Resultado) -> Void)?
    private var ultimaOrdemDoSom: UInt16?

    init(pasta: URL, nome: String, aoComecar: @escaping () -> Void,
         aoPedirIdr: @escaping () -> Void, aoFalhar: @escaping (String) -> Void = { _ in },
         aoAbrir: @escaping (URL) -> Void = { _ in }, aoDescartar: @escaping (URL) -> Void = { _ in }) {
        self.pasta = pasta; self.nome = nome
        self.aoComecar = aoComecar; self.aoPedirIdr = aoPedirIdr
        self.aoFalhar = aoFalhar; self.aoAbrir = aoAbrir; self.aoDescartar = aoDescartar
    }

    func configurarSom(taxa: Int, canais: Int) {
        fila.async { [self] in
            guard !parando, !fechoPedido, (1...2).contains(canais), taxa > 0 else { return }
            if let anterior = formatoDoSom, anterior.taxa == taxa, anterior.canais == canais { return }
            formatoDoSom = (taxa, canais)
            if writer != nil { fecharParte(); esperandoIdr = true; aoPedirIdr() }
        }
    }

    func relogio(video: Int64?, audio: Int64?) {
        fila.async { [self] in
            guard !fechoPedido else { return }
            if let video { videoOffset = video }; if let audio { audioOffset = audio }
            escoarSom()
        }
    }

    func quadro(_ bytes: UnsafeRawBufferPointer, ts: UInt64, idr: Bool) {
        guard reservar(bytes.count, video: true) else { return }
        let copia = Data(bytes), chegada = ProcessInfo.processInfo.systemUptime
        fila.async { [self] in
            defer { liberar(copia.count, video: true) }
            autoreleasepool { escreverVideo(copia, ts: ts, idr: idr, chegada: chegada) }
        }
    }

    func som(_ pcm: [Int16], taxa: Int, canais: Int, ordem: UInt16, ts: UInt64) {
        guard ts <= UInt64(Int64.max), taxa > 0, (1...2).contains(canais),
              pcm.count % canais == 0, reservar(pcm.count * 2, video: false) else { return }
        let chegada = ProcessInfo.processInfo.systemUptime
        fila.async { [self] in
            defer { liberar(pcm.count * 2, video: false) }
            guard !parando, zero != nil else { return }
            if let anterior = ultimaOrdemDoSom {
                let passo = ordem &- anterior
                guard passo > 0, passo < 32_768 else { return }
            }
            ultimaOrdemDoSom = ordem
            somEmEspera.append(Som(pcm: pcm, taxa: taxa, canais: canais, ts: ts, chegada: chegada))
            // Cinco segundos no máximo, mesmo quando o relógio comum ainda não foi medido.
            if somEmEspera.count > 250 { somEmEspera.removeFirst(somEmEspera.count - 250) }
            escoarSom()
        }
    }

    func ruptura() {
        fila.async { [self] in esperandoIdr = true; aoPedirIdr() }
    }

    func fechar(_ fim: @escaping (Resultado) -> Void) {
        // A imagem termina no toque. O som correspondente pode chegar depois pela rede.
        let chegadaDoFim = ProcessInfo.processInfo.systemUptime
        porta.lock(); aceitaVideo = false; porta.unlock()
        fila.async { [self] in
            guard !fechoPedido else { return }
            fechoPedido = true; self.fim = fim; self.chegadaDoFim = chegadaDoFim
            let concluir: () -> Void = { [self] in
                porta.lock(); aceitaSom = false; porta.unlock()
                escoarSom(forcar: true)
                parando = true
                fecharParte(); responderSeFechou()
            }
            if erro != nil { concluir() }
            else { fila.asyncAfter(deadline: .now() + 2, execute: concluir) }
        }
    }

    private func reservar(_ n: Int, video: Bool) -> Bool {
        porta.lock(); defer { porta.unlock() }
        guard video ? aceitaVideo : aceitaSom else { return false }
        if video {
            guard videosPendentes < 120, n <= 32 * 1024 * 1024 - bytesPendentes else {
                perdeuNaFila = true; return false
            }
            videosPendentes += 1; bytesPendentes += n
        } else {
            // A abertura do AAC pode levar mais que um quadro. Som tem sua própria folga;
            // descartar som nunca condena a referência H.264.
            guard sonsPendentes < 250, n <= 7680 else { return false }
            sonsPendentes += 1
        }
        return true
    }
    private func liberar(_ n: Int, video: Bool) {
        porta.lock()
        if video { videosPendentes -= 1; bytesPendentes -= n } else { sonsPendentes -= 1 }
        porta.unlock()
    }
    private func houvePerdaNaFila() -> Bool {
        porta.lock(); defer { porta.unlock() }
        let perdeu = perdeuNaFila; perdeuNaFila = false; return perdeu
    }

    private func escreverVideo(_ bytes: Data, ts: UInt64, idr: Bool, chegada: Double) {
        guard !parando, erro == nil, ts <= UInt64(Int64.max) else { return }
        if houvePerdaNaFila() { esperandoIdr = true; aoPedirIdr() }
        let nals = Self.nals(bytes)
        let novoSps = nals.first { $0.first.map { $0 & 31 == 7 } ?? false }
        let novoPps = nals.first { $0.first.map { $0 & 31 == 8 } ?? false }
        if let novoSps, let novoPps, novoSps != sps || novoPps != pps {
            if writer != nil { fecharParte(ateTs: ts) }
            sps = novoSps; pps = novoPps
            descricao = Self.descricao(sps: sps, pps: pps)
            leitura = ReferenciasH264Recebidas(sps: sps)
            esperandoIdr = true
        }
        let imagem = nals.filter { $0.first.map { $0 & 31 == 1 || $0 & 31 == 5 } ?? false }
        guard !imagem.isEmpty, let descricao else { return }
        if leitura.rompeu(imagem, idr: idr) {
            esperandoIdr = true; aoPedirIdr(); return
        }
        if esperandoIdr {
            guard idr else { return }
            esperandoIdr = false
        }
        if writer == nil {
            guard finalizando < Self.maxWriters else {
                esperandoIdr = true; aoPedirIdr(); return
            }
            guard idr else { return }
            do { try abrirParte(descricao: descricao, zero: ts, chegada: chegada) }
            catch { falhou(error.localizedDescription); return }
        }
        guard let zero, ts >= zero, trecho != nil else { return }
        if let ultimoVideo, ts <= ultimoVideo { return }
        let pts = Int64(ts - zero)
        if let anterior = amostraPendente {
            let duracao = max(1, pts - ptsPendente)
            if trecho?.adicionarVideo(Self.comDuracao(anterior, us: duracao) ?? anterior) != true {
                esperandoIdr = true; aoPedirIdr(); return
            }
            // Um intervalo de tela estática é duração do quadro anterior, não o fps da fonte.
            if duracao <= 250_000 { passoUs = duracao }
            if !iniciou { iniciou = true; aoComecar() }
        }
        guard let amostra = Self.amostra(imagem, descricao: descricao, pts: pts, idr: idr) else {
            esperandoIdr = true; aoPedirIdr(); return
        }
        amostraPendente = amostra; ptsPendente = pts; ultimoVideo = ts; chegadaUltimoVideo = chegada
        if !iniciou { iniciou = true; aoComecar() }
        escoarSom()
    }

    private func abrirParte(descricao: CMVideoFormatDescription, zero: UInt64, chegada: Double) throws {
        parte += 1
        let url = pasta.appendingPathComponent("\(nome)-parte\(parte).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: descricao)
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { throw Self.falha("formato H.264 não aceito para gravação") }
        w.add(v)
        var a: AVAssetWriterInput?
        if let f = formatoDoSom {
            let entrada = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: f.canais, AVEncoderBitRateKey: 128_000])
            entrada.expectsMediaDataInRealTime = true
            guard w.canAdd(entrada) else { throw Self.falha("formato AAC não aceito para gravação") }
            w.add(entrada); a = entrada
        }
        guard w.startWriting() else { throw w.error ?? Self.falha("não foi possível abrir a gravação") }
        w.startSession(atSourceTime: .zero)
        aoAbrir(url)
        writer = w; video = v; audio = a
        trecho = ParteRecebida(writer: w, video: v, audio: a, fila: fila, aoFalhar: { [weak self] texto in
            self?.falhou(texto)
        })
        self.zero = zero; chegadaZero = chegada
        ultimoVideo = nil; amostraPendente = nil; ultimoFimDoSom = 0; ultimaOrdemDoSom = nil; audioFallbackOffset = nil
        chegadaUltimoVideo = chegada; limiteFinalDoSom = nil
        somEmEspera.removeAll(keepingCapacity: true)
    }

    private func escoarSom(forcar: Bool = false) {
        guard let zero, audio != nil else { somEmEspera.removeAll(keepingCapacity: true); return }
        let temRelogio = videoOffset != nil && audioOffset != nil
        if !temRelogio, !forcar, ProcessInfo.processInfo.systemUptime - chegadaZero < 5 { return }
        let limite = limiteFinalDoSom ?? limiteDoSom(duracao: duracaoFinal())
        while let primeiro = somEmEspera.first {
            let pts: Int64
            if let v = videoOffset, let a = audioOffset {
                let absoluto = Int64(primeiro.ts).addingReportingOverflow(a)
                let inicio = Int64(zero).addingReportingOverflow(v)
                guard !absoluto.overflow, !inicio.overflow else { somEmEspera.removeFirst(); continue }
                let relativo = absoluto.partialValue.subtractingReportingOverflow(inicio.partialValue)
                guard !relativo.overflow else { somEmEspera.removeFirst(); continue }
                pts = relativo.partialValue
            } else {
                if audioFallbackOffset == nil {
                    let chegada = Int64((primeiro.chegada - chegadaZero) * 1_000_000)
                    let base = Int64(zero).subtractingReportingOverflow(Int64(primeiro.ts))
                    let deslocamento = base.partialValue.addingReportingOverflow(chegada)
                    guard !base.overflow, !deslocamento.overflow else { somEmEspera.removeFirst(); continue }
                    audioFallbackOffset = deslocamento.partialValue
                }
                let absoluto = Int64(primeiro.ts).addingReportingOverflow(audioFallbackOffset!)
                let relativo = absoluto.partialValue.subtractingReportingOverflow(Int64(zero))
                guard !absoluto.overflow, !relativo.overflow else { somEmEspera.removeFirst(); continue }
                pts = relativo.partialValue
            }
            // Uma tela estática continua exibindo o último quadro; o áudio pode seguir até Parar.
            // A espera por PCM depois de Parar usa o limite congelado, sem alongar o arquivo.
            let fimDoSlot = pts + Int64(primeiro.pcm.count / primeiro.canais) * 1_000_000 / Int64(primeiro.taxa)
            if fimDoSlot > limite, !forcar { return }
            somEmEspera.removeFirst()
            guard pts < limite else { continue }
            let inicio = max(pts, ultimoFimDoSom)
            let recorte = max(0, inicio - pts)
            let cortar = Int(recorte * Int64(primeiro.taxa) / 1_000_000) * primeiro.canais
            guard cortar < primeiro.pcm.count else { continue }
            let disponivel = Int(max(0, limite - inicio) * Int64(primeiro.taxa) / 1_000_000) * primeiro.canais
            let qtd = min(primeiro.pcm.count - cortar, disponivel)
            guard qtd > 0 else { continue }
            // Uma lacuna vira silêncio explícito, com o carimbo certo; não comprime o tempo perdido.
            if inicio > ultimoFimDoSom, inicio - ultimoFimDoSom <= 5_000_000 {
                let amostras = Int((inicio - ultimoFimDoSom) * Int64(primeiro.taxa) / 1_000_000)
                if amostras > 0 {
                    escreverSom([Int16](repeating: 0, count: amostras * primeiro.canais),
                                taxa: primeiro.taxa, canais: primeiro.canais, pts: ultimoFimDoSom)
                }
            }
            escreverSom(Array(primeiro.pcm[cortar..<(cortar + qtd)]), taxa: primeiro.taxa,
                        canais: primeiro.canais, pts: inicio)
        }
    }

    private func escreverSom(_ pcm: [Int16], taxa: Int, canais: Int, pts: Int64) {
        guard pts >= 0, audio != nil,
              let amostra = Self.amostraSom(pcm, taxa: taxa, canais: canais, pts: pts) else { return }
        guard trecho?.adicionarSom(amostra) == true else { return }
        ultimoFimDoSom = pts + Int64(pcm.count / canais) * 1_000_000 / Int64(taxa)
    }

    private func duracaoFinal(ateTs: UInt64? = nil) -> Int64 {
        if let ateTs, let ultimoVideo, ateTs > ultimoVideo { return Int64(ateTs - ultimoVideo) }
        // Só a última amostra usa o host: não há um próximo carimbo da fonte para uma tela parada.
        // O limite também impede uma duração inválida caso o relógio do host tenha saltado.
        let segundos = min(86_400, max(0, (chegadaDoFim ?? ProcessInfo.processInfo.systemUptime) - chegadaUltimoVideo))
        return max(passoUs, Int64(segundos * 1_000_000))
    }
    private func limiteDoSom(duracao: Int64) -> Int64 {
        let soma = ptsPendente.addingReportingOverflow(duracao)
        return soma.overflow ? Int64.max : soma.partialValue
    }
    private func fecharParte(ateTs: UInt64? = nil) {
        guard let writer, let trecho else { return }
        let duracao = duracaoFinal(ateTs: ateTs)
        limiteFinalDoSom = limiteDoSom(duracao: duracao)
        escoarSom(forcar: true)
        if let ultima = amostraPendente {
            if !trecho.adicionarVideo(Self.comDuracao(ultima, us: duracao) ?? ultima), erro == nil {
                erro = "a fila da gravação ficou cheia ao terminar"
                aoFalhar(erro!)
            }
            if !iniciou { iniciou = true; aoComecar() }
        }
        self.writer = nil; self.trecho = nil; video = nil; audio = nil; zero = nil; amostraPendente = nil
        finalizando += 1
        trecho.fechar { [self] terminou in
            finalizando -= 1
            if terminou { arquivos.append(writer.outputURL) }
            else {
                aoDescartar(writer.outputURL)
                if FileManager.default.fileExists(atPath: writer.outputURL.path) { preservados.append(writer.outputURL) }
                if erro == nil { erro = writer.error?.localizedDescription ?? "a gravação não foi concluída"; aoFalhar(erro!) }
            }
            if !parando, !fechoPedido, self.writer == nil, finalizando < Self.maxWriters { aoPedirIdr() }
            responderSeFechou()
        }
    }
    private func falhou(_ texto: String) {
        guard erro == nil else { return }
        erro = texto; porta.lock(); aceitaVideo = false; aceitaSom = false; porta.unlock()
        aoFalhar(texto)
        fecharParte()
    }
    private func responderSeFechou() {
        guard parando, finalizando == 0, let fim else { return }
        self.fim = nil
        fim(Resultado(arquivos: arquivos, preservados: preservados, erro: erro ?? (iniciou ? nil : "nenhuma imagem chegou à gravação")))
    }
    private static func falha(_ texto: String) -> NSError {
        NSError(domain: "br.com.queven.quall.gravacao.recebida", code: 1,
                userInfo: [NSLocalizedDescriptionKey: texto])
    }

    static func nals(_ bytes: Data) -> [Data] {
        let b = [UInt8](bytes); var inicios: [(Int, Int)] = []; var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { inicios.append((i, i + 3)); i += 3; continue }
                if i + 3 < b.count, b[i + 2] == 0, b[i + 3] == 1 {
                    inicios.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        return inicios.enumerated().compactMap { n, inicio in
            var fim = n + 1 < inicios.count ? inicios[n + 1].0 : b.count
            while fim > inicio.1, b[fim - 1] == 0 { fim -= 1 }
            return fim > inicio.1 ? Data(b[inicio.1..<fim]) : nil
        }
    }
    private static func descricao(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var d: CMFormatDescription?
        let st = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p -> OSStatus in
            guard let sb = s.baseAddress, let pb = p.baseAddress else { return -1 }
            var ponteiros = [sb.assumingMemoryBound(to: UInt8.self), pb.assumingMemoryBound(to: UInt8.self)]
            var tamanhos = [s.count, p.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: 2, parameterSetPointers: &ponteiros, parameterSetSizes: &tamanhos,
                nalUnitHeaderLength: 4, formatDescriptionOut: &d)
        } }
        return st == noErr ? d : nil
    }
    private static func bloco(_ data: Data) -> CMBlockBuffer? {
        var b: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &b) == noErr, let b else { return nil }
        let st = data.withUnsafeBytes { p -> OSStatus in
            guard let base = p.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: b, offsetIntoDestination: 0,
                                                 dataLength: data.count)
        }
        return st == noErr ? b : nil
    }
    private static func amostra(_ nals: [Data], descricao: CMFormatDescription,
                                pts: Int64, idr: Bool) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals { var n = UInt32(nal.count).bigEndian; withUnsafeBytes(of: &n) { avcc.append(contentsOf: $0) }; avcc.append(nal) }
        guard let b = bloco(avcc) else { return nil }
        var amostra: CMSampleBuffer?, tamanho = avcc.count
        var tempo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: b, formatDescription: descricao,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &tempo, sampleSizeEntryCount: 1,
            sampleSizeArray: &tamanho, sampleBufferOut: &amostra) == noErr, let amostra else { return nil }
        if let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: true) {
            let primeiro = unsafeBitCast(CFArrayGetValueAtIndex(anexos, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(primeiro, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(idr ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        return amostra
    }
    private static func comDuracao(_ amostra: CMSampleBuffer, us: Int64) -> CMSampleBuffer? {
        var nova: CMSampleBuffer?
        var t = CMSampleTimingInfo(duration: CMTime(value: us, timescale: 1_000_000),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(amostra), decodeTimeStamp: .invalid)
        return CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: amostra,
            sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleBufferOut: &nova) == noErr ? nova : nil
    }
    private static func amostraSom(_ pcm: [Int16], taxa: Int, canais: Int, pts: Int64) -> CMSampleBuffer? {
        guard !pcm.isEmpty else { return nil }
        var formato = AudioStreamBasicDescription(mSampleRate: Double(taxa), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(canais * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(canais * 2),
            mChannelsPerFrame: UInt32(canais), mBitsPerChannel: 16, mReserved: 0)
        var d: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &formato,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &d) == noErr, let d else { return nil }
        let data = pcm.withUnsafeBytes { Data($0) }
        guard let b = bloco(data) else { return nil }
        var amostra: CMSampleBuffer?
        var tempo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(taxa)),
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var tamanho = canais * 2
        return CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: b, formatDescription: d,
            sampleCount: pcm.count / canais, sampleTimingEntryCount: 1, sampleTimingArray: &tempo,
            sampleSizeEntryCount: 1, sampleSizeArray: &tamanho, sampleBufferOut: &amostra) == noErr ? amostra : nil
    }
}


/// AVAssetWriter pode pedir uma pausa, especialmente enquanto abre o AAC. A pausa não é perda:
/// as amostras ficam numa fila limitada e são escoadas antes de marcar as entradas como terminadas.
private final class ParteRecebida {
    private let writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?
    private let fila: DispatchQueue, aoFalhar: (String) -> Void
    private var quadros: [CMSampleBuffer] = [], sons: [CMSampleBuffer] = []
    private var bytes = 0, agendado = false, encerrando = false, terminou = false, falhaDita = false
    private var prazo: Double = 0, fim: ((Bool) -> Void)?
    private var videoTerminou = false, audioTerminou = false
    init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?,
         fila: DispatchQueue, aoFalhar: @escaping (String) -> Void) {
        self.writer = writer; self.video = video; self.audio = audio
        self.fila = fila; self.aoFalhar = aoFalhar
    }
    func adicionarVideo(_ amostra: CMSampleBuffer) -> Bool {
        let n = CMSampleBufferGetTotalSampleSize(amostra)
        guard !encerrando, quadros.count < 120, n <= 32 * 1024 * 1024 - bytes else { return false }
        quadros.append(amostra); bytes += n; drenar(); return true
    }
    func adicionarSom(_ amostra: CMSampleBuffer) -> Bool {
        guard !encerrando, audio != nil, sons.count < 250 else { return false }
        sons.append(amostra); drenar(); return true
    }
    func fechar(_ fim: @escaping (Bool) -> Void) {
        encerrando = true; self.fim = fim; prazo = ProcessInfo.processInfo.systemUptime + 10
        drenar()
    }
    private func drenar() {
        guard !terminou else { return }
        while !videoTerminou, video.isReadyForMoreMediaData, let q = quadros.first {
            guard video.append(q) else { dizerFalha(); break }
            quadros.removeFirst(); bytes -= CMSampleBufferGetTotalSampleSize(q)
        }
        if let audio {
            while !audioTerminou, audio.isReadyForMoreMediaData, let s = sons.first {
                guard audio.append(s) else { dizerFalha(); break }
                sons.removeFirst()
            }
        }
        if writer.status == .failed || writer.status == .cancelled {
            dizerFalha()
            if encerrando { terminar(false) }
            return
        }
        if encerrando {
            if quadros.isEmpty, !videoTerminou { video.markAsFinished(); videoTerminou = true }
            if sons.isEmpty, !audioTerminou { audio?.markAsFinished(); audioTerminou = true }
        }
        if encerrando, videoTerminou, audioTerminou {
            terminou = true
            writer.finishWriting { [self] in fila.async { [self] in
                let f = fim; fim = nil; f?(writer.status == .completed)
            } }
            return
        }
        if encerrando, ProcessInfo.processInfo.systemUptime >= prazo {
            writer.cancelWriting(); dizerFalha(); terminar(false); return
        }
        if !quadros.isEmpty || !sons.isEmpty, !agendado {
            agendado = true
            fila.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in agendado = false; drenar() }
        }
    }
    private func dizerFalha() {
        guard !falhaDita else { return }; falhaDita = true
        let texto = writer.error?.localizedDescription ?? "o gravador parou de aceitar amostras"
        fila.async { [aoFalhar] in aoFalhar(texto) }
    }
    private func terminar(_ sucesso: Bool) {
        terminou = true; let f = fim; fim = nil; f?(sucesso)
    }
}
