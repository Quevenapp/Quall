import AVFoundation
import CoreMedia
import Foundation
import QuallIdiomaKit

/// Records the received elementary stream. The network and audio callbacks only copy into
/// bounded mailboxes; the serial worker owns the file and the source-clock timeline.
public final class GravadorRecebido: @unchecked Sendable {
    public struct Estado: Sendable {
        public var ativo = false
        public var fechando = false
        public var segundos: Double = 0
        public var mensagem = ""
        public var arquivos: [URL] = []
        public init() {}
    }
    public var aoEstado: ((Estado) -> Void)?
    public var aoPedirIDR: (() -> Void)?
    private let fila = DispatchQueue(label: "quall.recebido.gravador", qos: .userInitiated)
    private let trava = NSLock()
    private let travaAudio = NSLock()
    private var aceitaVideo = false, aceitaAudio = false, perdeuVideo = false
    private var videos: [(Data, UInt64, Bool, Double)] = []
    private var bytesVideo = 0
    private let pcm = UnsafeMutablePointer<Float>.allocate(capacity: 256 * 1920)
    private var nAudio = [Int](repeating: 0, count: 256)
    private var tsAudio = [UInt64](repeating: 0, count: 256)
    private var chegadaAudio = [Double](repeating: 0, count: 256)
    private var leituraAudio = 0, escritaAudio = 0, ocupadosAudio = 0
    private var timer: DispatchSourceTimer?
    private var estado = Estado()
    private var nome = "", pasta: URL?
    private var inicio = 0.0, fimPedido: Double?, fimDaMidia: Double?
    private var canais = 1, atrasoAudioUs: Int64 = 0
    private var audioPresente = false
    private var dv: Int64?, da: Int64?, deltaChegada: Int64?
    private var audioEsperando: [([Float], UInt64, Double)] = []
    private var sps: [UInt8] = [], pps: [UInt8] = []
    private var continuidade = ReferenciasH264Recebidas()
    private var esperandoIDR = true
    private var writer: AVAssetWriter?, video: AVAssetWriterInput?, audio: AVAssetWriterInput?
    private var descricao: CMFormatDescription?, formatoAudio: CMAudioFormatDescription?
    private var zero: UInt64 = 0, chegadaZero = 0.0
    private var ultimaVideo: (Data, UInt64, Bool)?
    private var ultimoPts: UInt64 = 0, intervalo: UInt64 = 33_333
    private var ultimaChegadaVideo = 0.0
    private var amostrasAudio: Int64 = 0
    private var parte = 0, finalizando = 0
    private var ultimoRelato = 0.0, ultimoIDR = 0.0
    private var destino: URL?
    private var erroFinal: String?
    private var videoPendente: [CMSampleBuffer] = [], audioPendente: [CMSampleBuffer] = []

    public init() { videos.reserveCapacity(64); pcm.initialize(repeating: 0, count: 256 * 1920) }
    deinit { timer?.cancel(); pcm.deallocate() }

    public func iniciar(nome: String, pasta: URL, canais: Int?, atrasoAudioUs: Int64 = 0) {
        fila.async { [self] in
            guard !estado.ativo, !estado.fechando else { return }
            do {
                try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
                Self.recuperarPendentes(em: pasta)
                let livre = try pasta.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                guard livre >= 500 * 1024 * 1024 else { throw Erro(T("São necessários 500 MB livres para gravar.")) }
            } catch { publicar(mensagem: error.localizedDescription); return }
            self.pasta = pasta; self.nome = Self.nomeSeguro(nome)
            audioPresente = canais != nil; self.canais = min(2, max(1, canais ?? 1))
            self.atrasoAudioUs = atrasoAudioUs
            estado = Estado(); estado.ativo = true; inicio = Self.agora(); fimPedido = nil; fimDaMidia = nil; erroFinal = nil
            parte = 0; sps = []; pps = []; continuidade = ReferenciasH264Recebidas()
            esperandoIDR = true; dv = nil; da = nil; deltaChegada = nil; audioEsperando = []
            trava.lock(); aceitaVideo = true; perdeuVideo = false
            videos.removeAll(keepingCapacity: true); bytesVideo = 0; trava.unlock()
            travaAudio.lock(); aceitaAudio = true; ocupadosAudio = 0
            leituraAudio = 0; escritaAudio = 0; travaAudio.unlock()
            let t = DispatchSource.makeTimerSource(queue: fila)
            t.schedule(deadline: .now(), repeating: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.drenar() }; timer = t; t.resume()
            publicar(mensagem: T("Aguardando imagem para gravar…"))
            pedirIDR()
        }
    }

    /// Source-clock offsets are queried by the session supervisor, never by the audio callback.
    public func relogios(video: Int64?, audio: Int64?) {
        fila.async { [self] in
            guard fimPedido == nil else { return }
            if let video { dv = video }; if let audio { da = audio }
        }
    }

    /// A track of sound may be negotiated after recording has begun. Start a fresh MP4 part
    /// with its format, since an AVAssetWriter cannot add an input after startWriting.
    public func configurarSom(canais: Int, atrasoAudioUs: Int64) {
        fila.async { [self] in
            guard estado.ativo, fimPedido == nil else { return }
            let novos = min(2, max(1, canais))
            guard !audioPresente || self.canais != novos || self.atrasoAudioUs != atrasoAudioUs else { return }
            escoarSom(forcar: true); fecharParte()
            audioPresente = true; self.canais = novos; self.atrasoAudioUs = atrasoAudioUs
            audioEsperando.removeAll(keepingCapacity: true)
            esperandoIDR = true; pedirIDR()
        }
    }

    public func quadro(_ bytes: UnsafeRawBufferPointer, timestampUs: UInt64, idr: Bool) {
        // Only bounded memory copying under this lock; the disk, audio drain and codecs never use it.
        trava.lock()
        defer { trava.unlock() }
        guard aceitaVideo else { return }
        guard videos.count < 64, bytes.count <= 16 * 1024 * 1024 - bytesVideo else {
            perdeuVideo = true; return
        }
        videos.append((Data(bytes), timestampUs, idr, Self.agora())); bytesVideo += bytes.count
    }

    /// Pre-volume PCM, interleaved, 48 kHz. Fixed slots avoid allocating or waiting on the DAC thread.
    public func som(_ origem: UnsafePointer<Float>, amostras: Int, timestampUs: UInt64) {
        guard travaAudio.try() else { return }; defer { travaAudio.unlock() }
        guard aceitaAudio, amostras > 0, amostras <= 1920, ocupadosAudio < 256 else { return }
        pcm.advanced(by: escritaAudio * 1920).update(from: origem, count: amostras)
        nAudio[escritaAudio] = amostras; tsAudio[escritaAudio] = timestampUs
        chegadaAudio[escritaAudio] = Self.agora()
        escritaAudio = (escritaAudio + 1) % 256; ocupadosAudio += 1
    }

    public func parar(receberSomAtrasado: Bool = true) {
        fila.async { [self] in
            if !receberSomAtrasado {
                travaAudio.lock(); aceitaAudio = false; travaAudio.unlock()
            }
            guard estado.ativo, fimPedido == nil else { return }
            trava.lock(); aceitaVideo = false; trava.unlock()
            fimDaMidia = Self.agora(); estado.fechando = true; fimPedido = fimDaMidia! + 2
            publicar(mensagem: T("Salvando gravação…"))
        }
    }

    private func drenar() {
        let agora = Self.agora()
        escoarWriter()
        trava.lock()
        let lote = videos; videos = []; bytesVideo = 0
        let perdeu = perdeuVideo; perdeuVideo = false
        trava.unlock()
        travaAudio.lock()
        var sons: [([Float], UInt64, Double)] = []
        while ocupadosAudio > 0 {
            sons.append((Array(UnsafeBufferPointer(start: pcm.advanced(by: leituraAudio * 1920), count: nAudio[leituraAudio])),
                         tsAudio[leituraAudio], chegadaAudio[leituraAudio]))
            leituraAudio = (leituraAudio + 1) % 256; ocupadosAudio -= 1
        }
        travaAudio.unlock()
        if audioEsperando.count + sons.count > 250 { audioEsperando.removeFirst(min(audioEsperando.count, sons.count)) }
        audioEsperando.append(contentsOf: sons)
        if perdeu { esperandoIDR = true; pedirIDR() }
        for v in lote { consumirVideo(v.0, v.1, v.2, v.3) }
        escoarSom(forcar: fimPedido != nil && agora >= fimPedido!)
        if let fimPedido, agora >= fimPedido {
            trava.lock(); aceitaVideo = false; trava.unlock()
            travaAudio.lock(); aceitaAudio = false; travaAudio.unlock()
            fecharParte(); estado.ativo = false
            timer?.cancel(); timer = nil
            if finalizando == 0 { concluir() }
        } else if agora - ultimoRelato >= 0.5 {
            ultimoRelato = agora; estado.segundos = max(0, agora - inicio)
            publicar()
        }
        if esperandoIDR, fimPedido == nil, agora - ultimoIDR > 0.5 { pedirIDR() }
        if parte == 0, agora - inicio > 10, fimPedido == nil { falhar(T("Não chegou uma imagem completa para gravar.")) }
    }

    private func escoarSom(forcar: Bool) {
        let agora = Self.agora()
        if writer != nil {
            if let dv, let da {
                let d = da.subtractingReportingOverflow(dv)
                if !d.overflow { deltaChegada = d.partialValue }
            }
            if deltaChegada == nil, (agora - inicio >= 5 || forcar), let primeiro = audioEsperando.first {
                deltaChegada = Int64(zero) + Int64((primeiro.2 - chegadaZero) * 1_000_000) - Int64(clamping: primeiro.1)
            }
            if let delta = deltaChegada {
                let loteAudio = audioEsperando; audioEsperando.removeAll(keepingCapacity: true)
                let maximoUs = Int64(clamping: fimDoVideoUs())
                for a in loteAudio {
                    guard let us = audioUs(ts: a.1, delta: delta), abs(Double(us)) < 1e12 else { continue }
                    let fimAudioUs = us + Int64(a.0.count / canais) * 1_000_000 / 48_000
                    if !forcar, fimAudioUs > maximoUs {
                        audioEsperando.append(a)
                    } else { consumirAudio(a.0, a.1, delta) }
                }
            }
        }
    }

    private func consumirVideo(_ dados: Data, _ ts: UInt64, _ idr: Bool, _ chegada: Double) {
        guard ts < UInt64(Int64.max / 4) else { return }
        var novaSps: [UInt8]?, novaPps: [UInt8]?
        var carga = Data()
        var fatias: [Data] = []
        dados.withUnsafeBytes { bytes in
            DecodificadorH264.percorrerNals(bytes) { inicio, tamanho in
                let tipo = bytes[inicio] & 31
                if tipo == 7 { novaSps = Array(bytes[inicio..<(inicio+tamanho)]) }
                if tipo == 8 { novaPps = Array(bytes[inicio..<(inicio+tamanho)]) }
                if tipo == 1 || tipo == 5 {
                    fatias.append(Data(bytes[inicio..<(inicio+tamanho)]))
                    var n = UInt32(tamanho).bigEndian
                    withUnsafeBytes(of: &n) { carga.append(contentsOf: $0) }
                    carga.append(contentsOf: bytes[inicio..<(inicio+tamanho)])
                }
            }
        }
        guard !carga.isEmpty else { return }
        if let novaSps, let novaPps, novaSps != sps || novaPps != pps {
            escoarSom(forcar: true)
            fecharParte(); sps = novaSps; pps = novaPps; esperandoIDR = true
            continuidade = ReferenciasH264Recebidas(sps: Data(novaSps))
        }
        guard !continuidade.rompeu(fatias, idr: idr) else { esperandoIDR = true; pedirIDR(); return }
        if idr { esperandoIDR = false }
        guard !esperandoIDR else { return }
        if writer == nil {
            guard idr, !sps.isEmpty, !pps.isEmpty else { pedirIDR(); return }
            // Slow storage must not accumulate a writer per format change. Resume at a fresh
            // IDR once an older part has finished, while playback continues normally.
            guard finalizando < 4 else { esperandoIDR = true; pedirIDR(); return }
            do { try abrirParte(zero: ts, chegada: chegada) } catch { falhar(error.localizedDescription); return }
        }
        if let anterior = ultimaVideo {
            guard ts > anterior.1 else { return }
            let distancia = ts - anterior.1
            if distancia <= 250_000 { intervalo = distancia }
            guard anexar(anterior.0, ts: anterior.1, idr: anterior.2, duracao: distancia) else {
                esperandoIDR = true; ultimaVideo = nil; pedirIDR(); return
            }
        }
        ultimaVideo = (carga, ts, idr); ultimoPts = ts; ultimaChegadaVideo = chegada
    }

    private func abrirParte(zero: UInt64, chegada: Double) throws {
        guard let pasta else { throw Erro(T("A pasta de gravações não está disponível.")) }
        var formato: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p in
            let pontos = [s.baseAddress!, p.baseAddress!], tamanhos = [s.count, p.count]
            return pontos.withUnsafeBufferPointer { cp in tamanhos.withUnsafeBufferPointer { tp in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: cp.baseAddress!, parameterSetSizes: tp.baseAddress!,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &formato)
            }}
        }}
        guard status == noErr, let formato else { throw Erro(T("O formato recebido não pôde ser gravado.")) }
        parte += 1
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = pasta.appendingPathComponent("Quall-Recebido-\(nome)-\(f.string(from: Date()))-parte\(parte).pending.mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formato)
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { throw Erro(T("Não foi possível criar a trilha de vídeo.")) }; w.add(v)
        var a: AVAssetWriterInput?
        if audioPresente {
            let entrada = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: canais, AVEncoderBitRateKey: 128_000])
            entrada.expectsMediaDataInRealTime = true
            guard w.canAdd(entrada) else { throw Erro(T("Não foi possível criar a trilha de áudio.")) }; w.add(entrada); a = entrada
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4*canais),
                mFramesPerPacket: 1, mBytesPerFrame: UInt32(4*canais), mChannelsPerFrame: UInt32(canais), mBitsPerChannel: 32, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatoAudio) == noErr
                else { throw Erro(T("O formato de áudio não pôde ser gravado.")) }
        }
        guard w.startWriting() else { throw Erro(w.error?.localizedDescription ?? T("Não foi possível iniciar a gravação.")) }
        w.startSession(atSourceTime: .zero)
        writer = w; video = v; audio = a; descricao = formato; destino = url
        self.zero = zero; chegadaZero = chegada; ultimaVideo = nil; amostrasAudio = 0; ultimoPts = zero
        ultimaChegadaVideo = chegada
        publicar(mensagem: audioPresente ? T("Gravando") : T("Gravando sem som"))
    }

    private func anexar(_ dados: Data, ts: UInt64, idr: Bool, duracao: UInt64) -> Bool {
        guard video != nil, let descricao, ts >= zero, videoPendente.count < 64 else { return false }
        guard let s = Self.amostra(dados: dados, formato: descricao, n: 1,
            pts: CMTime(value: Int64(clamping: ts-zero), timescale: 1_000_000),
            duracao: CMTime(value: Int64(clamping: duracao), timescale: 1_000_000)) else { return false }
        if let anexos = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true) {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(anexos, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(idr ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        videoPendente.append(s); escoarWriter()
        return writer?.status == .writing
    }

    private func consumirAudio(_ origem: [Float], _ ts: UInt64, _ delta: Int64) {
        guard audio != nil, let formatoAudio else { return }
        guard let us = audioUs(ts: ts, delta: delta), abs(Double(us)) < 1e12 else { return }
        let posicao = Int64((Double(us) * 48_000 / 1_000_000).rounded())
        var inicioNoBloco = max(0, amostrasAudio - posicao)
        let total = Int64(origem.count / canais)
        guard inicioNoBloco < total else { return }
        let maximo = Int64((Double(fimDoVideoUs()) * 48_000 / 1_000_000).rounded())
        // Refuse an unbounded gap caused by a malformed source clock.
        guard posicao <= maximo + 48_000 else { return }
        while amostrasAudio < max(0, posicao), amostrasAudio < maximo {
            let n = min(960, max(0, posicao) - amostrasAudio, maximo-amostrasAudio)
            guard escreverAudio([Float](repeating: 0, count: Int(n)*canais), formato: formatoAudio) else { return }
        }
        inicioNoBloco = max(inicioNoBloco, -posicao)
        let n = min(total - inicioNoBloco, maximo-amostrasAudio)
        guard n > 0 else { return }
        _ = escreverAudio(Array(origem[Int(inicioNoBloco)*canais..<Int(inicioNoBloco+n)*canais]), formato: formatoAudio)
    }

    private func audioUs(ts: UInt64, delta: Int64) -> Int64? {
        guard let ts = Int64(exactly: ts), let zero = Int64(exactly: zero) else { return nil }
        let a = ts.addingReportingOverflow(delta)
        let b = a.partialValue.subtractingReportingOverflow(zero)
        let c = b.partialValue.subtractingReportingOverflow(atrasoAudioUs)
        return a.overflow || b.overflow || c.overflow ? nil : c.partialValue
    }

    private func escreverAudio(_ valores: [Float], formato: CMFormatDescription) -> Bool {
        guard audio != nil, audioPendente.count < 250 else { return false }
        let dados = valores.withUnsafeBytes { Data($0) }, n = valores.count / canais
        guard let s = Self.amostra(dados: dados, formato: formato, n: n,
            pts: CMTime(value: amostrasAudio, timescale: 48_000), duracao: CMTime(value: 1, timescale: 48_000)) else { return false }
        audioPendente.append(s); amostrasAudio += Int64(n); escoarWriter(); return true
    }

    private func escoarWriter() {
        guard let writer, writer.status == .writing else { return }
        while let video, video.isReadyForMoreMediaData, !videoPendente.isEmpty {
            if !video.append(videoPendente.removeFirst()) { falhar(writer.error?.localizedDescription ?? T("Falha ao salvar o vídeo.")); return }
        }
        while let audio, audio.isReadyForMoreMediaData, !audioPendente.isEmpty {
            if !audio.append(audioPendente.removeFirst()) { falhar(writer.error?.localizedDescription ?? T("Falha ao salvar o áudio.")); return }
        }
    }

    private static func amostra(dados: Data, formato: CMFormatDescription, n: Int, pts: CMTime, duracao: CMTime) -> CMSampleBuffer? {
        var bloco: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dados.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: dados.count,
            flags: 0, blockBufferOut: &bloco) == noErr, let bloco else { return nil }
        let copiou = dados.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bloco,
                                                                          offsetIntoDestination: 0, dataLength: dados.count) }
        guard copiou == noErr else { return nil }
        var tempo = CMSampleTimingInfo(duration: duracao, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var tamanho = dados.count / n, s: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: formato,
            sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &tempo, sampleSizeEntryCount: 1,
            sampleSizeArray: &tamanho, sampleBufferOut: &s) == noErr else { return nil }; return s
    }

    private func fecharParte() {
        guard let w = writer, let url = destino else { return }
        if let v = ultimaVideo {
            let duracao = max(intervalo, fimDoVideoUs() - (v.1-zero))
            _ = anexar(v.0, ts: v.1, idr: v.2, duracao: duracao)
        }
        let v = video, a = audio
        var videos = videoPendente, audios = audioPendente
        videoPendente = []; audioPendente = []
        writer = nil; video = nil; audio = nil; ultimaVideo = nil; destino = nil
        finalizando += 1
        var videoFechado = v == nil, audioFechado = a == nil, terminou = false
        func terminarSePronto() {
            guard videoFechado, audioFechado, !terminou else { return }; terminou = true
            w.finishWriting { [self] in fila.async { [self] in
            finalizando -= 1
            if w.status == .completed {
                let salvo = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".pending.mp4", with: ".mp4"))
                do { try FileManager.default.moveItem(at: url, to: salvo); estado.arquivos.append(salvo) }
                catch { erroFinal = T("O arquivo foi preservado em %@: %@", url.path, error.localizedDescription) }
            } else { erroFinal = T("A gravação não foi concluída: %@. Arquivo preservado em %@.", w.error?.localizedDescription ?? T("erro no arquivo"), url.path) }
            if !estado.ativo && finalizando == 0 { concluir() }
            }}
        }
        if let v {
            v.requestMediaDataWhenReady(on: fila) {
                while v.isReadyForMoreMediaData, !videos.isEmpty {
                    if !v.append(videos.removeFirst()) { videos = []; break }
                }
                if videos.isEmpty || w.status == .failed {
                    v.markAsFinished(); videoFechado = true; terminarSePronto()
                }
            }
        }
        if let a {
            a.requestMediaDataWhenReady(on: fila) {
                while a.isReadyForMoreMediaData, !audios.isEmpty {
                    if !a.append(audios.removeFirst()) { audios = []; break }
                }
                if audios.isEmpty || w.status == .failed {
                    a.markAsFinished(); audioFechado = true; terminarSePronto()
                }
            }
        }
        terminarSePronto()
    }

    private func concluir() {
        estado.fechando = false
        if let erroFinal { estado.mensagem = erroFinal }
        else if !estado.arquivos.isEmpty { estado.mensagem = T("Gravação salva em %@", estado.arquivos.last!.path) }
        else if estado.mensagem == T("Salvando gravação…") { estado.mensagem = T("Não chegou imagem para salvar.") }
        publicar()
    }
    /// A screen can stop producing frames while its pixels are unchanged. Its last image
    /// still occupies the recording timeline, including audio received during that interval.
    private func fimDoVideoUs() -> UInt64 {
        let ate = fimDaMidia ?? Self.agora()
        let parado = UInt64(max(0, min(86_400_000, ate - ultimaChegadaVideo)) * 1_000_000)
        return ultimoPts - zero + max(intervalo, parado)
    }
    private func falhar(_ motivo: String) {
        publicar(mensagem: motivo); fimDaMidia = Self.agora(); fimPedido = fimDaMidia; estado.fechando = true
    }
    private func pedirIDR() { ultimoIDR = Self.agora(); aoPedirIDR?() }
    private func publicar(mensagem: String? = nil) {
        if let mensagem { estado.mensagem = T(mensagem) }
        let e = estado; DispatchQueue.main.async { [weak self] in self?.aoEstado?(e) }
    }
    private static func agora() -> Double { ProcessInfo.processInfo.systemUptime }
    private static func recuperarPendentes(em pasta: URL) {
        let itens = (try? FileManager.default.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil)) ?? []
        for url in itens where url.lastPathComponent.hasPrefix("Quall-Recebido-") && url.lastPathComponent.hasSuffix(".pending.mp4") {
            // Fragmented files survive an interrupted process. Preserve unreadable ones for recovery;
            // never delete a recording just because metadata could not be loaded.
            let asset = AVURLAsset(url: url)
            guard asset.tracks(withMediaType: .video).first != nil, asset.duration.seconds > 0 else { continue }
            let recuperado = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent
                .replacingOccurrences(of: ".pending.mp4", with: "-recuperado.mp4"))
            try? FileManager.default.moveItem(at: url, to: recuperado)
        }
    }
    private static func nomeSeguro(_ nome: String) -> String {
        let limpo = nome.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted).joined(separator: "-")
        return limpo.isEmpty ? "aparelho" : String(limpo.prefix(60))
    }
    private struct Erro: LocalizedError { let texto: String; init(_ texto: String) { self.texto = T(texto) }; var errorDescription: String? { texto } }
}
