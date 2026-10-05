import CQuall
import Foundation
import QuallCaptureKit
import QuallNetKit

/// **Uma sessão do emissor**: uma espera, um receptor, uma transmissão.
///
/// # Por que existe
///
/// Até 10/09/2026 o `Emissor` *era* a sessão: um núcleo, uma transmissão, um cancelador, uma
/// bandeira de parada. Na tela estendida isso quer dizer um aparelho por vez. O pedido do usuário
/// foi o contrário — *"o app atender vários receptores ao mesmo tempo, uma sessão por aparelho,
/// cada uma com seu monitor, captura, codificador e porta"* —, e a medida de que o macOS aguenta
/// vários monitores do Quall juntos já tinha fechado (`sonda-monitor-virtual --juntos=3`).
///
/// Então o que era do Emissor e é **de uma sessão** mora aqui: hospedar (bloqueia, numa thread
/// própria), supervisionar (a mesma thread, que é o que `quall_session_next_event` exige), a
/// transmissão e o desmonte ordenado. O que é **do app** fica no Emissor: a interface, o anúncio
/// mDNS, o arquivo de pareamentos, o tom sintético, a decisão de abrir a espera seguinte.
///
/// # Threads
///
/// As mesmas regras de antes: a thread da sessão faz hospedar e supervisionar; o estado dividido
/// com ela fica atrás de `trava`; tudo o que a interface lê muda **na main**, e os avisos ao
/// Emissor saem na main.
final class SessaoDeEmissao: @unchecked Sendable, Identifiable {
    enum Estado: Equatable {
        case esperando
        case transmitindo
        case encerrando
        case encerrada
    }

    /// O par, como o núcleo o devolveu depois do pareamento.
    struct Par {
        var nome = ""
        var deviceId = ""
        /// Os pixels do painel, quando o receptor os disse (`quall_connect_with_screen`).
        var tela: (largura: Int, altura: Int)?
    }

    let id: Int
    let fonte: FonteDeCaptura
    let pin: String
    let porta: UInt16
    let endereco: String?
    let ligarEm: String?
    /// A sessão **oferece** a track de som. Desde a S4 do som, toda sessão da rodada com som
    /// oferece; quem **manda** pacote é só a do dono (``tocaSom``, D2 do `som-no-receptor.md` §12.1).
    let comAudio: Bool
    /// **A câmera já aberta** (R5 fase 4, G1): com dono, a transmissão assina os quadros dele em vez
    /// de abrir a câmera, e a queda da sessão não fecha nada. `nil`: o caminho de antes.
    let dono: DonoDaCamera?
    /// A sessão oferece a track `MICROPHONE`/Opus (**sempre**, nas sessões de câmera com dono: o botão
    /// pode ligar no meio, e não há renegociação), e manda o som do microfone do dono por ela. Calada
    /// com o botão desligado: nenhum buffer, nenhum pacote.
    let comMicrofone: Bool
    /// **O controle remoto da câmera** (R9b, `docs/controle-remoto-da-camera.md`): o filmador que esta sessão
    /// bombeia — o do dono (câmera comum e R5), ou o "sem câmera" das sessões de tela (§9: o receptor novo
    /// vê `sem_camera`). Lidos na criação, na principal: a thread da sessão não toca no dono.
    private let filmadorRemoto: FilmadorDaCameraRemota?
    private let ponteRemota: CameraRemotaDoDono?
    /// `""` na primeira sessão — o registro de sempre, que as corridas de bancada leem —, e
    /// `"[#2] "` nas seguintes.
    let prefixo: String
    let criadaEm = Date()

    // MARK: - o que o Emissor lê (só muda na main)

    private(set) var estado: Estado = .esperando
    private(set) var par = Par()
    private(set) var resumo = ""
    private(set) var resumoDoAudio = ""
    /// Os contadores de som da última leitura, para o ``VigiaDoSomDasSessoes`` do Emissor (M3). `nil`
    /// numa sessão sem som, e até o primeiro relato.
    private(set) var leituraDoSom: VigiaDoSomDasSessoes.Leitura?
    /// "Quall — iPhone X · 1218 × 562 @2x", quando a sessão tem monitor próprio.
    private(set) var descricaoDoMonitor = ""
    private(set) var indiceDoMonitor: Int?

    // MARK: - avisos ao Emissor (na main)

    var aoConectar: ((SessaoDeEmissao) -> Void)?
    var aoFalharAoHospedar: ((SessaoDeEmissao, QuallStatus, String) -> Void)?
    var aoCair: ((SessaoDeEmissao, _ receptorSaiu: Bool) -> Void)?
    var aoPararSozinho: ((SessaoDeEmissao, Error) -> Void)?
    /// A captura nem chegou a subir (o monitor não nasceu, a permissão caiu) — frase diferente de
    /// "parou sozinha".
    var aoNaoIniciar: ((SessaoDeEmissao, Error) -> Void)?
    var aoAtualizar: ((SessaoDeEmissao) -> Void)?

    // MARK: - estado dividido com a thread da sessão

    private let nucleo = NucleoDeRede()
    private let trava = NSLock()
    private var _tocaSom = false
    private var _quadrosDeSomCalados: UInt64 = 0

    /// Esta sessão é a dona do som (``DonoDoSom``): só ela manda os quadros de som. As outras
    /// capturam e calam — a track delas fica em `IDLE` no receptor, e passar o som é só virar esta
    /// chave, sem renegociar nem reabrir captura. Escrito pelo Emissor, na main; lido pela captura.
    var tocaSom: Bool {
        get { trava.lock(); defer { trava.unlock() }; return _tocaSom }
        set { trava.lock(); _tocaSom = newValue; trava.unlock() }
    }

    /// Quadros de som que a captura produziu e esta sessão não mandou por não ser a dona.
    var quadrosDeSomCalados: UInt64 { trava.lock(); defer { trava.unlock() }; return _quadrosDeSomCalados }
    private var cancelador: Cancelador?
    private var transmissao: TransmissaoAoVivo?
    /// O microfone desta sessão (o som do dono → Opus → a track), e a ficha dele no dono.
    private var microfone: MicrofoneParaOpus?
    private var fichaDoMicrofone: FichaDoDono?
    private var pedidoDeParada = false
    /// Quem pediu para saber do fim do desmonte. **Uma lista, e não um só**: `encerrar` pode ser
    /// pedido de novo enquanto o primeiro desmonte corre (Desconectar e logo Parar; o último
    /// receptor saindo e a pessoa cancelando a espera) — e quem pediu por último também tem de
    /// ouvir o fim, senão o Emissor fica esperando para sempre (revisão de 10/09/2026). Só na main.
    private var aoAcabarODesmonte: [() -> Void] = []

    init(id: Int, fonte: FonteDeCaptura, pin: String, porta: UInt16, endereco: String?,
         ligarEm: String?, comAudio: Bool, dono: DonoDaCamera? = nil, comMicrofone: Bool = false,
         prefixo: String? = nil) {
        self.id = id
        self.fonte = fonte
        self.pin = pin
        self.porta = porta
        self.endereco = endereco
        self.ligarEm = ligarEm
        self.comAudio = comAudio
        self.dono = dono
        self.comMicrofone = comMicrofone && dono != nil
        self.prefixo = prefixo ?? (id == 1 ? "" : "[#\(id)] ")
        ponteRemota = CameraRemotaDoDono.ponte(de: dono)
        filmadorRemoto = dono != nil ? ponteRemota?.filmador : CameraRemotaDoDono.semCamera
    }

    func registrar(_ linha: String) {
        Registro.compartilhado.linha(prefixo + linha)
    }

    private func naMain(_ bloco: @escaping () -> Void) {
        if Thread.isMainThread { bloco() } else { DispatchQueue.main.async(execute: bloco) }
    }

    // MARK: - esperar

    /// Sobe a espera numa thread dedicada. **Uma `Thread`, não uma fila**: `quall_session_next_event`
    /// exige ser chamada sempre da mesma thread, e uma `DispatchQueue` serial não promete isso.
    func esperar(pares: String, rotulo: String, prazoMs: UInt32) {
        let umCancelador = Cancelador()
        trava.lock()
        cancelador = umCancelador
        pedidoDeParada = false
        trava.unlock()

        let thread = Thread { [self] in
            correr(pares: pares, rotulo: rotulo, prazoMs: prazoMs, cancelador: umCancelador)
        }
        thread.name = "quall.sessao.\(id)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func correr(pares: String, rotulo: String, prazoMs: UInt32, cancelador: Cancelador) {
        let nomeDoAparelho = Identidade.nomeDoAparelho

        // **As tracks são pedidas aqui e não podem ser pedidas depois** (dívida 1): a sessão nasce
        // com a lista que vai ter até morrer. Vídeo no índice 0 e som no 1 — é essa a ordem que o
        // `NucleoDeRede` usa para saber em qual track cada quadro entra.
        var tracksPedidas: [NucleoDeRede.DescricaoDeTrack] = [
            .init(tipo: fonte.ehTela ? QUALL_TRACK_KIND_SCREEN : QUALL_TRACK_KIND_CAMERA, rotulo: rotulo)
        ]
        if comAudio {
            // PCMU pedido explicitamente: esta casca não tem encoder de Opus alcançável.
            tracksPedidas.append(.init(tipo: QUALL_TRACK_KIND_SYSTEM_AUDIO,
                                       rotulo: "Som de \(nomeDoAparelho)",
                                       codecDeAudio: QUALL_AUDIO_CODEC_PCMU))
        }
        if comMicrofone {
            // Opus pedido explicitamente: o microfone sai pelo encoder do núcleo (`MicrofoneParaOpus`),
            // e o `a=rtpmap` tem de dizer a verdade (`NucleoDeRede.DescricaoDeTrack`).
            tracksPedidas.append(.init(tipo: QUALL_TRACK_KIND_MICROPHONE,
                                       rotulo: "Microfone de \(nomeDoAparelho)",
                                       codecDeAudio: QUALL_AUDIO_CODEC_OPUS))
        }

        let subiu = nucleo.hospedar(
            pin: pin,
            porta: porta,
            deviceId: Identidade.deviceId,
            nome: nomeDoAparelho,
            tracksPedidas: tracksPedidas,
            paresConhecidos: pares.isEmpty ? nil : pares,
            prazoMs: prazoMs,
            cancelador: cancelador,
            ligarEm: ligarEm)

        guard subiu else {
            let status = nucleo.ultimoStatusDeFalha
            let motivo = nucleo.ultimoMotivo
            registrar("hospedar falhou: status=\(status.rawValue) causa=\(SanitizacaoDoLog.causaExterna(motivo))")
            naMain {
                // Se um desmonte já corre, quem fecha o estado é ele (e avisa quem esperava).
                if self.estado != .encerrando { self.estado = .encerrada }
                self.aoFalharAoHospedar?(self, status, motivo)
            }
            return
        }
        registrar("hospedado: pareamento_novo=\(nucleo.pareamentoNovo) "
                  + "candidatos_descartados=\(nucleo.candidatosDescartados)")

        // O pareamento fechou: grava antes de qualquer outra coisa. `guardarPares` funde com o que
        // está em disco numa fila própria, então duas sessões pareando juntas não se atropelam.
        let novosPares = nucleo.paresParaGuardar(somandoA: pares.isEmpty ? nil : pares)
        if novosPares.isEmpty {
            registrar("!! o núcleo não devolveu estado de pareamento — nada foi gravado, e o PIN vai "
                      + "ser pedido de novo")
        } else {
            registrar("pareamento gravado (\(novosPares.count) bytes)")
        }
        Identidade.guardarPares(novosPares)
        let doPar = SessaoDeEmissao.parVindoDoJson(nucleo.parJson())
        registrar("tracks: pedidas=\(tracksPedidas.count) audio=\(nucleo.temTrackDeAudio)"
                  + (comMicrofone ? " microfone=na oferta" : "")
                  + (doPar.tela.map { " tela_do_par=\($0.largura)x\($0.altura)" } ?? ""))

        naMain {
            // Parar pode ter chegado enquanto o par fechava: aí a sessão já está sendo desmontada.
            guard self.estado == .esperando else { return }
            self.par = doPar
            self.estado = .transmitindo
            self.aoConectar?(self)
        }
        supervisionar()
    }

    /// O núcleo é dono do formato; a casca lê três campos e não interpreta o resto.
    static func parVindoDoJson(_ json: String) -> Par {
        guard let dados = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else { return Par() }
        var par = Par()
        for chave in ["display_name", "name", "nome"] {
            if let valor = obj[chave] as? String, !valor.isEmpty { par.nome = valor; break }
        }
        par.deviceId = obj["device_id"] as? String ?? ""
        if let tela = obj["screen"] as? [String: Any],
           let l = (tela["width_px"] as? NSNumber)?.intValue,
           let a = (tela["height_px"] as? NSNumber)?.intValue, l > 0, a > 0 {
            par.tela = (l, a)
        }
        return par
    }

    // MARK: - transmitir

    /// Liga a captura para este receptor. Chamado pelo Emissor **na main**, depois de `aoConectar` —
    /// é o Emissor quem decide o monitor (formato, nome, identidade), porque ele vê as outras sessões.
    func transmitir(fonteDaSessao: FonteDeCaptura, nomeDoMonitor: String, indiceDoMonitor: Int,
                    fps: Int32, teto: ((Int, Int, Int32) -> TetoDoEmissor.Aplicado)?,
                    escopo: EscopoDaCaptura, janelaDoVigia: Double) {
        guard estado == .transmitindo else { return }
    #if QUALL_TELA_ESTENDIDA_FUTURA
        if let modo = fonteDaSessao.modoDaTelaEstendida {
            self.indiceDoMonitor = indiceDoMonitor
            self.descricaoDoMonitor = "\(nomeDoMonitor) · \(modo.rotulo)"
        }

    #endif
        let enviarUmQuadroDeAudio: TransmissaoAoVivo.SumidouroDeAudio = { [nucleo, weak self] quadro, timestampUs in
            // Só a dona do som manda (D2). Calar não é falha de envio: conta à parte, e a
            // transmissão não vê recusa nenhuma. **Sem a sessão, cala** (fecha, e não abre:
            // crítica 9, miúdo 8).
            guard let self else { return true }
            self.trava.lock()
            let toca = self._tocaSom
            if !toca { self._quadrosDeSomCalados &+= 1 }
            self.trava.unlock()
            if !toca { return true }
            let status = quadro.withUnsafeBytes { buf in
                nucleo.enviarAudio(quadro: buf, timestampUs: timestampUs)
            }
            return status == QUALL_STATUS_OK
        }
        let paraOVideo: TransmissaoAoVivo.Sumidouro = { [nucleo] annexb, timestampUs, idr in
            let status = annexb.withUnsafeBytes { buf in
                nucleo.enviar(annexb: buf, timestampUs: timestampUs, idr: idr)
            }
            return status == QUALL_STATUS_OK
        }

        let viva = TransmissaoAoVivo(
            fonte: fonteDaSessao,
            fps: fps,
            teto: teto,
            presetDeAudio: comAudio ? Emissor.presetDeAudioDaSessao : nil,
            escopo: escopo,
            janelaDeToleranciaDoVigia: janelaDoVigia,
            nomeDoMonitor: nomeDoMonitor,
            indiceDoMonitor: indiceDoMonitor,
            dono: dono,
            sumidouro: paraOVideo,
            sumidouroDeAudio: comAudio ? enviarUmQuadroDeAudio : nil)
        viva.aoRegistrarDiagnostico = { [weak self] linha in self?.registrar(linha) }
        viva.aoPararSozinho = { [weak self] erro in
            guard let self else { return }
            self.naMain { self.aoPararSozinho?(self, erro) }
        }
        trava.lock()
        transmissao = viva
        trava.unlock()

        // **O microfone vai por fora da transmissão**: do dono ao núcleo, pela track `MICROPHONE`
        // (a `TransmissaoAoVivo` só sabe o som de sistema do SCK, em PCMU). Pendurado agora, junto
        // do vídeo, e solto no desmonte; o botão só decide se chega buffer.
        if comMicrofone, let dono {
            if let m = MicrofoneParaOpus(enviar: { [nucleo] pacote, carimbo in
                nucleo.enviarAudio(quadro: pacote, timestampUs: carimbo) == QUALL_STATUS_OK
            }) {
                let ficha = dono.assinar(nome: "microfone da sessão", som: { [weak m] amostra in m?.consumir(amostra) })
                trava.lock(); microfone = m; fichaDoMicrofone = ficha; trava.unlock()
                registrar("microfone: na oferta, \(m.resumoDoPreset); o som sai só com o botão ligado")
            } else {
                registrar("!! microfone: o encoder do núcleo não subiu (\(SanitizacaoDoLog.causaExterna(EncoderDeAudioDoNucleo.ultimoErro))); a track fica calada")
            }
        }

        #if QUALL_TELA_ESTENDIDA_FUTURA
        registrar("conectado: sessão ativa"
                  + (fonteDaSessao.modoDaTelaEstendida.map { " monitor_futuro=\($0.descricao) indice=\(indiceDoMonitor)" } ?? ""))
        #else
        registrar("conectado: sessão ativa")
        #endif

        Task.detached { [self] in
            do {
                let tamanho = try await viva.iniciar()
                // O receptor entrou no meio: pedir um IDR já, em vez de esperar o próximo do GOP.
                viva.pedirIDR()
                registrar(
                    "captura: \(tamanho.largura)x\(tamanho.altura) preset=\(viva.preset) "
                    + "encoder=\(viva.nomeDoEncoder) hardware=\(viva.encoderEhHardware) "
                    + "escopo=\(viva.escopo.rawValue) "
                    + (viva.intervaloMinimoDescrito.isEmpty ? "" : "intervalo_minimo=\(viva.intervaloMinimoDescrito) ")
                    + "gop=\(viva.gopDescrito) teto_quadro=[\(viva.respostaDoTetoDeQuadro)] "
                    + (viva.presetDeAudio.map {
                        "audio=\($0.codec) \($0.canais)ch \(Int($0.taxaDeAmostragem))Hz "
                        + "quadro=\($0.duracaoDoQuadroMs)ms (\($0.amostrasPorQuadro) amostras)"
                    } ?? "audio=desligado"))
            } catch {
                registrar("!! não consegui iniciar a captura: \(SanitizacaoDoLog.erro(error))")
                naMain { self.aoNaoIniciar?(self, error) }
            }
        }
    }

    // MARK: - supervisionar

    /// O detector de queda, o pedido de IDR e os contadores. Mesma thread da sessão, sempre.
    private func supervisionar() {
        var ultimoRelato = Date.distantPast
        // **A bombeada da câmera** é o leitor do canal desta sessão de vídeo (§2: um leitor por sessão).
        // O handle das mensagens sobrevive ao fechamento da sessão, que o desmonte faz em outra thread: a
        // bombeada depois disso só devolve `CLOSED`.
        let mensagens = filmadorRemoto != nil ? nucleo.mensagens() : nil
        var bombeando = mensagens != nil
        defer {
            if let f = filmadorRemoto, let m = mensagens {
                if bombeando { _ = f.bombear(m, prazoMs: 0) }
                f.esquecer(m)
                registrar("camera remota: fim")
            }
        }
        while !devoParar() {
            // O `Bye` do receptor chega aqui (dívida 20). Sem ele, o único sinal seria `enviar`
            // falhar, 30 s depois — capturando e codificando para o vazio (dívida 13).
            let evento = nucleo.proximoEvento()
            if evento == QUALL_SESSION_EVENT_DISCONNECTED || evento == QUALL_SESSION_EVENT_FAILED {
                let saiu = evento == QUALL_SESSION_EVENT_DISCONNECTED
                naMain { self.aoCair?(self, saiu) }
                return
            }

            if bombeando, let f = filmadorRemoto, let m = mensagens {
                let b = f.bombear(m, prazoMs: 0)
                if b.mudou & FilmadorDaCameraRemota.bitDoPedido != 0 { ponteRemota?.avisarPedido() }
                if b.mudou & FilmadorDaCameraRemota.bitDosReceptores != 0 {
                    registrar("camera remota: receptores mudaram")
                }
                if b.acabou { bombeando = false }
            }

            if nucleo.precisaDeIDR() {
                trava.lock()
                let viva = transmissao
                trava.unlock()
                viva?.pedirIDR()
            }

            if Date().timeIntervalSince(ultimoRelato) >= 1 {
                ultimoRelato = Date()
                relatar()
            }
            // 20 ms: rápido para o pedido de IDR não custar quadros, devagar para não disputar a
            // trava com o caminho do quadro.
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func devoParar() -> Bool {
        trava.lock(); defer { trava.unlock() }
        return pedidoDeParada
    }

    private var relatosDoMicrofone = 0

    private func relatar() {
        let doNucleo = nucleo.estatisticasDaTrack()
        trava.lock()
        let viva = transmissao
        let mic = microfone
        trava.unlock()
        // O microfone a cada 10 s (a linha do iOS, `envio: …`), com os contadores do núcleo.
        if let mic {
            relatosDoMicrofone += 1
            if relatosDoMicrofone % 10 == 0 {
                registrar("APP MICROFONE envio: \(mic.resumo()) | nucleo: \(nucleo.estatisticasDaTrackDeAudio())")
            }
        }
        guard let c = viva?.contadores else { return }
        // Contadores dos dois lados da fronteira: o que o encoder produziu e o que a track mandou.
        registrar(
            "casca: capturados=\(c.quadrosCapturados) enviados=\(c.quadrosEnviados) "
            + "recusados=\(c.quadrosRecusados) idrs=\(c.idrsEnviados) "
            + "idrs_forcados=\(c.idrsForcados) bytes=\(c.bytesEnviados) "
            + String(format: "latencia_media_ms=%.2f", c.latenciaMediaUs / 1000)
            + (c.quadrosRepetidos > 0 ? " repetidos=\(c.quadrosRepetidos)" : "")
            + " lacunas_captura=\(c.lacunasDeCaptura) maior_captura_ms=\(c.maiorLacunaDeCapturaMs)"
            + " lacunas_envio=\(c.lacunasDeEnvio) maior_envio_ms=\(c.maiorLacunaDeEnvioMs)"
            + (c.estadosDaCaptura.isEmpty ? "" : " sck=["
               + c.estadosDaCaptura.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
               + "]")
            + " | nucleo: \(doNucleo)")
        if c.blocosDeAudio > 0 || c.quadrosDeAudioEnviados > 0 {
            let segundos = Double(c.amostrasDeAudio) / Emissor.presetDeAudioDaSessao.taxaDeAmostragem
            registrar(
                "casca (audio): blocos=\(c.blocosDeAudio) "
                + String(format: "amostras=%d (%.2f s) ", c.amostrasDeAudio, segundos)
                + "quadros_enviados=\(c.quadrosDeAudioEnviados) "
                + "recusados=\(c.quadrosDeAudioRecusados) "
                + "bytes=\(c.bytesDeAudioEnviados) "
                + "falhas_conversao=\(c.falhasDeConversao) "
                + "conversor_refeito=\(c.reconstrucoesDoConversor) "
                + String(format: "rms=%.0f pico=%d freq=%.1f Hz (fundo de escala 32767)",
                         c.nivelRmsDoAudio, c.picoDoAudio, c.frequenciaEstimadaHz)
                + String(format: " reancoragens=%d lacunas=%d maior_lacuna_ms=%.1f degraus=%d socorros=%d erro_ms=%.2f maior_erro_ms=%.2f f_ppm=%.2f ajuste_ppm=%.2f portao=%@",
                         c.reancoragensDoSom, c.lacunasDoSom, c.maiorLacunaDoSomMs, c.degrausDoSom,
                         c.socorrosDoSom, c.erroDoSomMs, c.maiorErroDoSomMs, c.fDoSomPpm,
                         c.ajusteDoSomPpm, c.portaoDoSomAberto ? "aberto" : "fechado")
                + " | nucleo: \(nucleo.estatisticasDaTrackDeAudio())")
        }
        let (video, audio) = SessaoDeEmissao.resumos(de: c)
        // A hora é a da leitura, aqui na thread da sessão: o vigia compara sessões pelas horas.
        let leitura = comAudio
            ? VigiaDoSomDasSessoes.Leitura(id: id, ms: DispatchTime.now().uptimeNanoseconds / 1_000_000,
                                           amostras: c.amostrasDeAudio, recusados: c.quadrosDeAudioRecusados,
                                           enviados: c.quadrosDeAudioEnviados)
            : nil
        naMain {
            self.resumo = video
            self.resumoDoAudio = audio
            self.leituraDoSom = leitura
            self.aoAtualizar?(self)
        }
    }

    private static func resumos(de c: TransmissaoAoVivo.Contadores) -> (String, String) {
        var audio = ""
        if c.blocosDeAudio > 0 || c.quadrosDeAudioEnviados > 0 {
            let segundos = Double(c.amostrasDeAudio) / Emissor.presetDeAudioDaSessao.taxaDeAmostragem
            audio = String(format: "som: %d quadros · %.1f s capturados", c.quadrosDeAudioEnviados, segundos)
                + (c.quadrosDeAudioRecusados > 0 ? " · \(c.quadrosDeAudioRecusados) recusados" : "")
        }
        var partes: [String] = ["\(c.quadrosEnviados) quadros"]
        if c.quadrosRecusados > 0 { partes.append("\(c.quadrosRecusados) recusados") }
        partes.append("\(c.idrsEnviados) IDR")
        if c.latenciaMediaUs > 0 {
            partes.append(String(format: "captura+encode %.1f ms", c.latenciaMediaUs / 1000))
        }
        return (partes.joined(separator: " · "), audio)
    }

    // MARK: - encerrar

    /// Para a captura, fecha a sessão e avisa quando acabou (na main). **Funciona de verdade**: a
    /// captura para (o indicador do sistema apaga), a espera bloqueada destrava, o monitor sai.
    ///
    /// Nada disto roda na main: `quall_session_close` espera os tratadores da casca saírem.
    func encerrar(quandoAcabar: @escaping () -> Void) {
        switch estado {
        case .encerrada:
            quandoAcabar()
            return
        case .encerrando:
            aoAcabarODesmonte.append(quandoAcabar)
            return
        case .esperando, .transmitindo:
            break
        }
        estado = .encerrando
        aoAcabarODesmonte.append(quandoAcabar)

        trava.lock()
        pedidoDeParada = true
        let umCancelador = cancelador
        let viva = transmissao
        transmissao = nil
        let mic = microfone
        let fichaMic = fichaDoMicrofone
        microfone = nil
        fichaDoMicrofone = nil
        trava.unlock()
        umCancelador?.cancelar()
        // O som sai do dono **antes** de a sessão fechar. Um buffer já em voo ainda pode chamar
        // `enviarAudio` depois disto: com as tracks soltas ele volta `INVALID` e é contado, sem efeito.
        if let fichaMic { dono?.desassinar(fichaMic) }

        let t = Thread { [self] in
            // Parar a captura **antes** de fechar a sessão: mandar um quadro para uma sessão em
            // fechamento é pedir para ela esperar por si mesma.
            let semaforo = DispatchSemaphore(value: 0)
            Task.detached {
                await viva?.parar()
                semaforo.signal()
            }
            semaforo.wait()

            if let viva {
                let c = viva.contadores
                registrar(
                    "fim da captura: capturados=\(c.quadrosCapturados) enviados=\(c.quadrosEnviados) "
                    + "recusados=\(c.quadrosRecusados) idrs=\(c.idrsEnviados) bytes=\(c.bytesEnviados) "
                    + String(format: "latencia_media_ms=%.2f", c.latenciaMediaUs / 1000)
                    + (c.quadrosRepetidos > 0 ? " repetidos=\(c.quadrosRepetidos)" : ""))
                // O que o emissor declarou no bitstream, relido do SPS já reescrito — a única prova,
                // de dentro do processo, de que o `bitstream_restriction` saiu.
                registrar("sps: \(viva.resumoDoSPS)")
                if viva.presetDeAudio != nil {
                    let segundos = Double(c.amostrasDeAudio) / Emissor.presetDeAudioDaSessao.taxaDeAmostragem
                    registrar(
                        "fim do audio: blocos=\(c.blocosDeAudio) "
                        + String(format: "amostras=%d (%.2f s) ", c.amostrasDeAudio, segundos)
                        + "quadros_enviados=\(c.quadrosDeAudioEnviados) "
                        + "recusados=\(c.quadrosDeAudioRecusados) "
                        + "bytes=\(c.bytesDeAudioEnviados) "
                        + "falhas_conversao=\(c.falhasDeConversao) "
                        + "conversor_refeito=\(c.reconstrucoesDoConversor) "
                        + String(format: "rms=%.0f pico=%d freq=%.1f Hz (fundo de escala 32767)",
                                 c.nivelRmsDoAudio, c.picoDoAudio, c.frequenciaEstimadaHz))
                }
            }
            if let mic {
                registrar("APP MICROFONE fim do envio: \(mic.resumo()) | nucleo: \(nucleo.estatisticasDaTrackDeAudio())")
            }
            registrar("nucleo (final): \(nucleo.estatisticasDaTrack())")
            let doAudio = nucleo.estatisticasDaTrackDeAudio()
            if !doAudio.isEmpty { registrar("nucleo audio (final): \(doAudio)") }

            nucleo.encerrar()
            registrar("sessao encerrada")
            naMain {
                self.estado = .encerrada
                let avisos = self.aoAcabarODesmonte
                self.aoAcabarODesmonte = []
                avisos.forEach { $0() }
            }
        }
        t.name = "quall.desmontagem.\(id)"
        t.start()
    }
}
