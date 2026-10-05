import Foundation
import AVFoundation
import VideoToolbox
import UIKit

/// S-I1 (`docs/teleprompter-com-camera.md` §8.1): a câmera frontal a 1080p30 alimentando, ao
/// mesmo tempo, um codificador de "rede" (720p, baseline, contado e jogado fora) e a gravação
/// (1080p, High) num `AVAssetWriter` com `movieFragmentInterval`, com AAC de um tom sintético.
///
/// O que a sonda responde, e onde:
/// * se as duas saídas seguram 30 fps por 10 min no iPhone 7 — `amostras` a cada 10 s;
/// * quantos quadros se perdem, e **onde** (câmera, voo de cada codificador, VT, writer);
/// * o `thermalState` ao longo do tempo;
/// * se o arquivo é legível depois de um `exit()` no meio — conferido pela própria sonda na
///   abertura seguinte (`Orfao.swift`), e de novo no Mac com `ffprobe`.
///
/// Dois modos de gravação, porque o §5.1 do desenho admite as duas leituras:
/// * `vt_passagem` (padrão): um segundo `VTCompressionSession` 1080p, e o writer só empacota;
/// * `writer_codifica`: o writer recebe o quadro cru e codifica ele mesmo (sem o segundo VT).
final class Sonda: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum ModoGravacao: String, CaseIterable, Identifiable {
        case vtPassagem = "vt_passagem"
        case writerCodifica = "writer_codifica"
        var id: String { rawValue }
    }

    struct Config {
        var duracaoS: Double = 600
        /// Se definido, `exit(0)` neste segundo, sem fechar o arquivo.
        var abruptoS: Double?
        var modo: ModoGravacao = .vtPassagem
        var fragmentoS: Double = 2
        var bitrateRede = 2_500_000
        var bitrateGravacao = 16_000_000
    }

    // Critérios do veredito, publicados no JSON junto do resultado.
    static let fpsMinimo = 29.0
    static let perdaMaxima = 0.01
    static let duracaoMinimaDoArquivo = 0.98

    @Published var linhas: [String] = []
    @Published var veredito = ""
    @Published var rodando = false

    let sessao = AVCaptureSession()
    private let filaSessao = DispatchQueue(label: "sonda.sessao")
    private let filaCaptura = DispatchQueue(label: "sonda.captura")
    private let filaWriter = DispatchQueue(label: "sonda.writer")

    private var config = Config()
    private var rede: Codificador?
    private var gravacao: Codificador?
    private var writer: AVAssetWriter?
    private var entradaVideo: AVAssetWriterInput?
    private var entradaAudio: AVAssetWriterInput?
    private let tom = TomSintetico()
    private var urlVideo: URL!
    private var urlRelato: URL!
    private var nomeDaCorrida = ""

    // --- contadores. `trava` protege os da captura; os do writer só são tocados na `filaWriter`.
    private let trava = NSLock()
    private var capturados = 0
    private var descartadosCamera = 0
    private var razoesDeDescarte: [String: Int] = [:]
    private var buracos = 0
    private var quadrosNosBuracos = 0
    private var ultimoPTS: CMTime = .invalid
    private var dimensaoCaptura = ""

    private var videoAnexados = 0
    private var videoRecusados = 0
    private var audioAnexados = 0
    private var audioRecusados = 0
    private var falhasDeAppend = 0
    private var primeiroPTSGravado: CMTime = .invalid
    private var ultimoPTSGravado: CMTime = .invalid
    private var encerrando = false

    private var inicio = Date()
    private var proximaAmostra = 10.0
    private var relogio: Timer?
    private var amostras: [[String: Any]] = []
    private var anterior: [String: Double] = [:]
    private var eventos: [[String: Any]] = []
    private var piorTermico = ProcessInfo.ThermalState.nominal
    private var dadosDaCamera: [String: Any] = [:]

    // MARK: - Início

    func iniciar(_ c: Config) {
        guard !rodando else { return }
        config = c
        linhas = []
        veredito = ""
        UIDevice.current.isBatteryMonitoringEnabled = true
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { self.montarERodar() } else {
                    self.dizer("câmera recusada: Ajustes > Sonda R5 > Câmera")
                    self.veredito = "VEREDITO: NÃO RODOU — sem permissão de câmera"
                }
            }
        }
    }

    private func montarERodar() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let livre = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if livre < 2_000_000_000 {
            dizer("espaço livre \(livre / 1_000_000) MB < 2000 MB; a corrida de 10 min pede ~1,3 GB")
            veredito = "VEREDITO: NÃO RODOU — pouco espaço"
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        nomeDaCorrida = "r5-\(f.string(from: Date()))-\(config.modo.rawValue)"
            + (config.abruptoS != nil ? "-abrupto" : "")
        urlVideo = docs.appendingPathComponent(nomeDaCorrida + ".mp4")
        urlRelato = docs.appendingPathComponent(nomeDaCorrida + ".json")

        do {
            rede = try Codificador(nome: "rede", largura: 1280, altura: 720,
                                   bitrate: config.bitrateRede, perfilAlto: false,
                                   intervaloDeIDR: 60)
            if config.modo == .vtPassagem {
                let g = try Codificador(nome: "gravacao", largura: 1920, altura: 1080,
                                        bitrate: config.bitrateGravacao, perfilAlto: true,
                                        intervaloDeIDR: 60)
                g.saida = { [weak self] amostra in
                    self?.filaWriter.async { self?.anexarVideo(amostra) }
                }
                gravacao = g
            }
        } catch {
            dizer("\(error)")
            veredito = "VEREDITO: NÃO RODOU — codificador não abriu"
            return
        }

        guard configurarCamera() else {
            veredito = "VEREDITO: NÃO RODOU — câmera frontal 1080p30 não configurou"
            return
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(mudouTermico),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(interrompida(_:)),
                       name: .AVCaptureSessionWasInterrupted, object: sessao)
        nc.addObserver(self, selector: #selector(erroDeSessao(_:)),
                       name: .AVCaptureSessionRuntimeError, object: sessao)
        nc.addObserver(self, selector: #selector(segundoPlano),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)

        UIApplication.shared.isIdleTimerDisabled = true
        rodando = true
        inicio = Date()
        proximaAmostra = 10
        registrar("inicio", ["modo": config.modo.rawValue])
        piorTermico = ProcessInfo.processInfo.thermalState
        dizer("\(nomeDaCorrida): \(Int(config.duracaoS)) s, modo \(config.modo.rawValue)"
              + (config.abruptoS.map { ", exit() aos \(Int($0)) s" } ?? ""))
        filaSessao.async { self.sessao.startRunning() }
        relogio = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tique()
        }
    }

    private func configurarCamera() -> Bool {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                position: .front) else {
            dizer("sem câmera frontal"); return false
        }
        sessao.beginConfiguration()
        defer { sessao.commitConfiguration() }
        guard sessao.canSetSessionPreset(.hd1920x1080) else {
            dizer("a frontal não aceita o preset 1920x1080"); return false
        }
        sessao.sessionPreset = .hd1920x1080
        guard let entrada = try? AVCaptureDeviceInput(device: cam), sessao.canAddInput(entrada) else {
            dizer("não abri a entrada da frontal"); return false
        }
        sessao.addInput(entrada)
        let saida = AVCaptureVideoDataOutput()
        saida.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        saida.alwaysDiscardsLateVideoFrames = true
        saida.setSampleBufferDelegate(self, queue: filaCaptura)
        guard sessao.canAddOutput(saida) else { dizer("não adicionei a saída de vídeo"); return false }
        sessao.addOutput(saida)
        do {
            try cam.lockForConfiguration()
            cam.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            cam.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            cam.unlockForConfiguration()
        } catch {
            dizer("não travei 30 fps: \(error)")
        }
        let d = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
        let faixas = cam.activeFormat.videoSupportedFrameRateRanges
            .map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator: ",")
        dadosDaCamera = [
            "posicao": "frontal",
            "formato_ativo": "\(d.width)x\(d.height)",
            "faixas_fps": faixas,
            "min_frame_duration_s": CMTimeGetSeconds(cam.activeVideoMinFrameDuration),
            "max_frame_duration_s": CMTimeGetSeconds(cam.activeVideoMaxFrameDuration),
            "pixel_format": "420f",
            "always_discards_late": true,
            "previa": true,
        ]
        dizer("frontal \(d.width)x\(d.height), faixas \(faixas)")
        return true
    }

    // MARK: - Captura

    func captureOutput(_ output: AVCaptureOutput, didOutput amostra: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        guard let imagem = CMSampleBufferGetImageBuffer(amostra) else { return }
        trava.lock()
        capturados += 1
        if ultimoPTS.isValid {
            let dt = CMTimeGetSeconds(CMTimeSubtract(pts, ultimoPTS))
            if dt > 1.5 / 30 {
                buracos += 1
                quadrosNosBuracos += max(0, Int((dt * 30).rounded()) - 1)
            }
        } else {
            dimensaoCaptura = "\(CVPixelBufferGetWidth(imagem))x\(CVPixelBufferGetHeight(imagem))"
        }
        ultimoPTS = pts
        trava.unlock()

        let duracao = CMTime(value: 1, timescale: 30)
        rede?.codificar(imagem, pts: pts, duracao: duracao)
        switch config.modo {
        case .vtPassagem:
            gravacao?.codificar(imagem, pts: pts, duracao: duracao)
        case .writerCodifica:
            filaWriter.async { self.anexarVideo(amostra) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop amostra: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let razao = (CMGetAttachment(amostra, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String) ?? "desconhecida"
        trava.lock()
        descartadosCamera += 1
        razoesDeDescarte[razao, default: 0] += 1
        trava.unlock()
    }

    // MARK: - Writer (só na `filaWriter`)

    private func criarWriter(dica: CMFormatDescription?, pts: CMTime) -> Bool {
        do {
            let w = try AVAssetWriter(outputURL: urlVideo, fileType: .mp4)
            w.movieFragmentInterval = CMTime(seconds: config.fragmentoS, preferredTimescale: 600)
            w.shouldOptimizeForNetworkUse = false
            let v: AVAssetWriterInput
            switch config.modo {
            case .vtPassagem:
                v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: dica)
            case .writerCodifica:
                v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 1920,
                    AVVideoHeightKey: 1080,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: config.bitrateGravacao,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 60,
                        AVVideoAllowFrameReorderingKey: false,
                    ],
                ])
            }
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(TomSintetico.taxa),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(a) else {
                registrar("writer_recusou_entradas", [:]); return false
            }
            w.add(v)
            w.add(a)
            guard w.startWriting() else {
                registrar("writer_nao_comecou", ["erro": "\(String(describing: w.error))"])
                return false
            }
            w.startSession(atSourceTime: pts)
            writer = w
            entradaVideo = v
            entradaAudio = a
            primeiroPTSGravado = pts
            registrar("writer_comecou", ["fragmento_s": config.fragmentoS])
            return true
        } catch {
            registrar("writer_nao_criou", ["erro": "\(error)"])
            return false
        }
    }

    private func anexarVideo(_ amostra: CMSampleBuffer) {
        if encerrando { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        if writer == nil {
            if !criarWriter(dica: CMSampleBufferGetFormatDescription(amostra), pts: pts) {
                encerrando = true
                DispatchQueue.main.async { self.parar(motivo: "o writer não abriu") }
                return
            }
        }
        guard let w = writer, let v = entradaVideo, let a = entradaAudio else { return }
        if w.status == .failed {
            falhasDeAppend += 1
            return
        }
        if v.isReadyForMoreMediaData {
            if v.append(amostra) {
                videoAnexados += 1
                ultimoPTSGravado = pts
            } else {
                falhasDeAppend += 1
            }
        } else {
            videoRecusados += 1
        }
        for bloco in tom.blocos(ate: pts) {
            if a.isReadyForMoreMediaData {
                if a.append(bloco) { audioAnexados += 1 } else { falhasDeAppend += 1 }
            } else {
                audioRecusados += 1
            }
        }
    }

    // MARK: - Relógio, amostras, fim

    private func tique() {
        let t = Date().timeIntervalSince(inicio)
        if t >= proximaAmostra {
            amostrar(t)
            proximaAmostra += 10
        }
        if let ab = config.abruptoS, t >= ab {
            fimAbrupto(t)
            return
        }
        if t >= config.duracaoS { parar(motivo: "duração cumprida") }
    }

    private struct Foto {
        var capturados = 0, descartados = 0, buracos = 0, quadrosNosBuracos = 0
        var rede = Codificador.Contagem(), grav = Codificador.Contagem()
        var anexados = 0, recusados = 0, audio = 0, audioRecusados = 0, falhas = 0
        var ultimoGravadoS = 0.0
    }

    private func foto() -> Foto {
        var f = Foto()
        trava.lock()
        f.capturados = capturados
        f.descartados = descartadosCamera
        f.buracos = buracos
        f.quadrosNosBuracos = quadrosNosBuracos
        trava.unlock()
        f.rede = rede?.contagem() ?? .init()
        f.grav = gravacao?.contagem() ?? .init()
        filaWriter.sync {
            f.anexados = videoAnexados
            f.recusados = videoRecusados
            f.audio = audioAnexados
            f.audioRecusados = audioRecusados
            f.falhas = falhasDeAppend
            if primeiroPTSGravado.isValid && ultimoPTSGravado.isValid {
                f.ultimoGravadoS = CMTimeGetSeconds(CMTimeSubtract(ultimoPTSGravado,
                                                                   primeiroPTSGravado))
            }
        }
        return f
    }

    private func amostrar(_ t: Double) {
        let f = foto()
        func taxa(_ chave: String, _ valor: Int) -> Double {
            let a = anterior[chave] ?? 0
            let ta = anterior["t"] ?? 0
            let dt = t - ta
            return dt > 0 ? (Double(valor) - a) / dt : 0
        }
        // Em `vt_passagem` a gravação é o segundo VT; em `writer_codifica` não há segundo VT, e o
        // que conta é o que o writer aceitou.
        let entreguesGrav = config.modo == .vtPassagem ? f.grav.entregues : f.anexados
        let a: [String: Any] = [
            "t_s": (t * 10).rounded() / 10,
            "fps_captura": taxa("cap", f.capturados),
            "fps_rede": taxa("rede", f.rede.entregues),
            "fps_gravacao": taxa("grav", entreguesGrav),
            "fps_writer": taxa("writer", f.anexados),
            "descartes_camera": f.descartados,
            "buracos_pts": f.buracos,
            "rede_descartados_em_voo": f.rede.descartadosEmVoo,
            "grav_descartados_em_voo": f.grav.descartadosEmVoo,
            "writer_recusados": f.recusados,
            "termico": nomeTermico(ProcessInfo.processInfo.thermalState),
            "pegada_mb": pegadaMB(),
            "bateria": Double(UIDevice.current.batteryLevel),
        ]
        anterior = ["t": t, "cap": Double(f.capturados), "rede": Double(f.rede.entregues),
                    "grav": Double(entreguesGrav), "writer": Double(f.anexados)]
        if t >= 1 { amostras.append(a) }
        let fmt = { (x: Any?) in String(format: "%.1f", (x as? Double) ?? 0) }
        dizer("\(Int(t)) s: cap \(fmt(a["fps_captura"])) rede \(fmt(a["fps_rede"])) "
              + "grav \(fmt(a["fps_gravacao"])) writer \(fmt(a["fps_writer"])) · "
              + "\(a["termico"]!) · \(fmt(a["pegada_mb"])) MB")
    }

    private func fimAbrupto(_ t: Double) {
        relogio?.invalidate()
        amostrar(t)
        let f = foto()
        var r = relato(f, duracaoS: t)
        r["fim_abrupto"] = true
        r["fim_abrupto_em_s"] = t
        r["veredito"] = "VEREDITO: FIM ABRUPTO aos \(Int(t)) s — abra a sonda de novo para "
            + "conferir o arquivo (e confira com ffprobe no Mac)"
        gravarRelato(r)
        NSLog("SONDA-R5 %@", r["veredito"] as! String)
        // Sem `finishWriting`, sem parar a sessão, sem invalidar os codificadores: o que se quer
        // saber é o que sobra quando o processo simplesmente some.
        exit(0)
    }

    func parar(motivo: String) {
        guard rodando else { return }
        relogio?.invalidate()
        let t = Date().timeIntervalSince(inicio)
        amostrar(t)
        registrar("parar", ["motivo": motivo])
        dizer("parando: \(motivo)")
        filaSessao.async {
            self.sessao.stopRunning()
            self.filaCaptura.sync {}
            self.rede?.encerrar()
            self.gravacao?.encerrar()
            self.filaWriter.async {
                self.encerrando = true
                guard let w = self.writer else {
                    DispatchQueue.main.async { self.concluir(t, estado: "sem writer", erro: nil) }
                    return
                }
                self.entradaVideo?.markAsFinished()
                self.entradaAudio?.markAsFinished()
                w.finishWriting {
                    let estado = w.status == .completed ? "completed" : "status \(w.status.rawValue)"
                    DispatchQueue.main.async {
                        self.concluir(t, estado: estado, erro: w.error.map { "\($0)" })
                    }
                }
            }
        }
    }

    private func concluir(_ t: Double, estado: String, erro: String?) {
        UIApplication.shared.isIdleTimerDisabled = false
        dizer("writer: \(estado); lendo o arquivo de volta…")
        let url = urlVideo!
        DispatchQueue.global(qos: .userInitiated).async {
            let leitura = Orfao.ler(url)
            DispatchQueue.main.async {
                self.julgar(t, estado: estado, erro: erro, leitura: leitura)
            }
        }
    }

    private func julgar(_ t: Double, estado: String, erro: String?, leitura: [String: Any]) {
        let f = foto()
        var r = relato(f, duracaoS: t)
        r["writer_estado"] = estado
        if let erro = erro { r["writer_erro"] = erro }
        r["leitura_do_arquivo"] = leitura

        var motivos: [String] = []
        var avisos: [String] = []
        if estado != "completed" { motivos.append("writer terminou em \(estado)") }
        let dur = (leitura["duracao_s"] as? Double) ?? 0
        // O arquivo contra o que o writer aceitou, e o que ele aceitou contra o relógio de parede
        // (a partida da câmera come ~1 s, por isso a folga de 5 s).
        if dur < Self.duracaoMinimaDoArquivo * f.ultimoGravadoS {
            motivos.append(String(format: "arquivo com %.1f s de %.1f s anexados", dur,
                                  f.ultimoGravadoS))
        }
        if f.ultimoGravadoS < t - 5 {
            motivos.append(String(format: "anexados só %.1f s de %.1f s de corrida",
                                  f.ultimoGravadoS, t))
        }
        let corpo = amostras.dropFirst() // os primeiros 10 s incluem a partida da câmera
        let medRede = mediana(corpo.compactMap { $0["fps_rede"] as? Double })
        let medGrav = mediana(corpo.compactMap { $0["fps_gravacao"] as? Double })
        if medRede < Self.fpsMinimo { motivos.append(String(format: "rede a %.1f fps", medRede)) }
        if medGrav < Self.fpsMinimo { motivos.append(String(format: "gravação a %.1f fps", medGrav)) }
        let perdidos = (r["perdidos_total"] as? Int) ?? 0
        let perda = f.capturados > 0 ? Double(perdidos) / Double(f.capturados + f.descartados) : 1
        if perda > Self.perdaMaxima {
            motivos.append(String(format: "%.2f %% de quadros perdidos", perda * 100))
        }
        if piorTermico == .critical { motivos.append("térmico chegou a critical") }
        if piorTermico == .serious { avisos.append("térmico chegou a serious") }
        if eventos.contains(where: { ($0["evento"] as? String) == "interrompida"
                                     || ($0["evento"] as? String) == "segundo_plano" }) {
            motivos.append("a sessão foi interrompida ou o app saiu da tela")
        }
        let base = String(format: "rede %.1f fps, gravação %.1f fps, perda %.2f %%, térmico pior %@",
                          medRede, medGrav, perda * 100, nomeTermico(piorTermico))
        veredito = motivos.isEmpty
            ? "VEREDITO: PASSOU — \(base)" + (avisos.isEmpty ? "" : " (aviso: \(avisos.joined(separator: "; ")))")
            : "VEREDITO: REPROVOU — \(motivos.joined(separator: "; ")) — \(base)"
        r["fps_rede_mediana"] = medRede
        r["fps_gravacao_mediana"] = medGrav
        r["perda_fracao"] = perda
        r["veredito"] = veredito
        gravarRelato(r)
        NSLog("SONDA-R5 %@", veredito)
        dizer(veredito)
        rodando = false
    }

    private func relato(_ f: Foto, duracaoS: Double) -> [String: Any] {
        let perdidos = f.descartados + f.quadrosNosBuracos + f.rede.descartadosEmVoo
            + f.rede.descartadosPeloVT + f.grav.descartadosEmVoo + f.grav.descartadosPeloVT
            + f.recusados
        trava.lock()
        let razoes = razoesDeDescarte
        let dim = dimensaoCaptura
        trava.unlock()
        return [
            "sonda": "S-I1",
            "corrida": nomeDaCorrida,
            "aparelho": modeloDoAparelho(),
            "sistema": UIDevice.current.systemVersion,
            "modo_gravacao": config.modo.rawValue,
            "duracao_pedida_s": config.duracaoS,
            "duracao_s": duracaoS,
            "fragmento_s": config.fragmentoS,
            "bitrate_rede": config.bitrateRede,
            "bitrate_gravacao": config.bitrateGravacao,
            "camera": dadosDaCamera,
            "dimensao_captura": dim,
            "arquivo": urlVideo.lastPathComponent,
            "som": "tom sintético 1 kHz −12 dBFS, 48 kHz mono, AAC 128 kbit/s (não é o microfone)",
            "capturados": f.capturados,
            "descartes_camera": f.descartados,
            "razoes_de_descarte": razoes,
            "buracos_pts": f.buracos,
            "quadros_nos_buracos": f.quadrosNosBuracos,
            "rede": ["entregues": f.rede.entregues, "descartados_em_voo": f.rede.descartadosEmVoo,
                     "descartados_pelo_vt": f.rede.descartadosPeloVT, "falhas": f.rede.falhas,
                     "ultima_falha": Int(f.rede.ultimaFalha)],
            "gravacao_vt": ["entregues": f.grav.entregues,
                            "descartados_em_voo": f.grav.descartadosEmVoo,
                            "descartados_pelo_vt": f.grav.descartadosPeloVT,
                            "falhas": f.grav.falhas, "ultima_falha": Int(f.grav.ultimaFalha)],
            "writer": ["video_anexados": f.anexados, "video_recusados": f.recusados,
                       "audio_anexados": f.audio, "audio_recusados": f.audioRecusados,
                       "falhas_de_append": f.falhas, "ultimo_pts_gravado_s": f.ultimoGravadoS],
            "perdidos_total": perdidos,
            "termico_pior": nomeTermico(piorTermico),
            "criterios": ["fps_minimo_mediano": Self.fpsMinimo, "perda_maxima": Self.perdaMaxima,
                          "duracao_minima_do_arquivo": Self.duracaoMinimaDoArquivo,
                          "termico": "critical reprova, serious avisa"],
            "amostras": amostras,
            "eventos": eventos,
        ]
    }

    private func gravarRelato(_ r: [String: Any]) {
        guard let dados = try? JSONSerialization.data(
            withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) else {
            dizer("!! o relato não serializou"); return
        }
        do {
            try dados.write(to: urlRelato, options: .atomic)
            dizer("relato: Documents/\(urlRelato.lastPathComponent)")
        } catch {
            dizer("!! não gravei o relato: \(error)")
        }
    }

    // MARK: - Eventos

    @objc private func mudouTermico() {
        let e = ProcessInfo.processInfo.thermalState
        if e.rawValue > piorTermico.rawValue { piorTermico = e }
        registrar("termico", ["estado": nomeTermico(e)])
    }

    @objc private func interrompida(_ n: Notification) {
        let razao = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
        registrar("interrompida", ["razao": razao])
    }

    @objc private func erroDeSessao(_ n: Notification) {
        registrar("erro_de_sessao", ["erro": "\(String(describing: n.userInfo?[AVCaptureSessionErrorKey]))"])
    }

    @objc private func segundoPlano() {
        if rodando { registrar("segundo_plano", [:]) }
    }

    private func registrar(_ evento: String, _ dados: [String: Any]) {
        var e = dados
        e["evento"] = evento
        e["t_s"] = Date().timeIntervalSince(inicio)
        if Thread.isMainThread { eventos.append(e) } else {
            DispatchQueue.main.async { self.eventos.append(e) }
        }
        if evento != "inicio" { dizer("evento \(evento) \(dados)") }
    }

    func dizer(_ s: String) {
        if Thread.isMainThread {
            linhas.append(s)
            if linhas.count > 80 { linhas.removeFirst(linhas.count - 80) }
        } else {
            DispatchQueue.main.async { self.dizer(s) }
        }
    }
}

// MARK: - utilitários

func nomeTermico(_ e: ProcessInfo.ThermalState) -> String {
    switch e {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "desconhecido"
    }
}

func mediana(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func pegadaMB() -> Double {
    var info = task_vm_info_data_t()
    var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
        }
    }
    return kr == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : -1
}

func modeloDoAparelho() -> String {
    var u = utsname()
    uname(&u)
    return withUnsafeBytes(of: &u.machine) { p in
        String(decoding: p.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
