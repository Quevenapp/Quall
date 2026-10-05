import Foundation

/// O laço de áudio **dentro do próprio aparelho**: o app hospeda uma track de som sintético e o
/// mesmo app a recebe, por `127.0.0.1`. Nada vai ao rádio.
///
/// # Por que ele existe, e por que ele existe agora
///
/// `docs/ios-um-app.md` fechou a rodada de 29–30/08 dizendo, em voz alta, o que faltava:
///
/// > *"o `AVAudioEngine` nunca tocou uma amostra … o contador de subconsumo nunca subiu nem ficou
/// > em zero por mérito"* … *"A alternativa — uma fonte sintética hospedada dentro do app, sem
/// > câmera — é trabalho real … **É a próxima coisa a fazer**, e vale para as duas tarefas: com
/// > uma track de áudio sintética junto, ela provaria o caminho de som inteiro sem tocar na rede."*
///
/// Isto é essa coisa. E ela deixou de ser conveniência e virou **o único caminho** em 30/08: a
/// permissão de Rede Local do iPad está com um pedido pendente no `nehelper` que sobrevive à
/// desinstalação do app (ver `PermissaoDeRedeLocal`), e destravá-la exige um toque humano que esta
/// frente não pode dar. Loopback não passa por essa permissão — medido em 29/08, e remedido aqui:
/// `127.0.0.1` fecha o veredito da sonda em milissegundos.
///
/// É o equivalente iOS do `laco-de-audio.py` do Android (`docs/audio-no-android.md` §6), com uma
/// diferença que vale dizer: lá o emissor é o `quall-probe` cruzado para o aparelho, um processo
/// separado; aqui os **dois lados moram no mesmo processo**, porque não há como pôr um binário de
/// linha de comando dentro de um iPad. Duas sessões do núcleo no mesmo processo é coisa que o
/// desenho já permitia (`EmissorDeCamera` hospeda no processo do app) e que nunca tinha sido
/// exercitada — se ela quebrar, quebra aqui, e isso também é resultado.
///
/// # A origem é o tom sintético, e o microfone não é tocado **aqui**
///
/// Este laço não abre `AVAudioSession` de gravação nem `AVCaptureDevice` de áudio: a regra de
/// **bancada** de `docs/audio.md` §8.1 é literal — **prova de áudio se faz com tom sintético.** As
/// quatro notas são as de `TomSintetico`, que são as mesmas do `quall-probe` e as mesmas do Android.
///
/// Até 24/09/2026 isto dizia também que o app não tinha microfone nenhum. **Não vale mais para o
/// produto**: a regra "este app nunca abre o microfone" caiu em todo emissor de câmera (decisão do
/// Pessoa Exemplo, `docs/teleprompter-com-camera.md` §4.1), e o app ganhou `NSMicrophoneUsageDescription` e
/// um botão de microfone na câmera (`DonoDaCaptura`, `MicrofoneParaOpus`). O que continua é a
/// regra de bancada: nenhuma prova usa o som da sala sem o sim do Pessoa Exemplo por corrida, e a prova de
/// caminho do microfone troca o conteúdo pelo mesmo `TomSintetico` (`--microfone-tom`).
///
/// # Bancada, e só bancada
///
/// Entra por `--laco-de-audio` na linha de comando e não tem nenhuma porta na interface. Um app de
/// produto que hospedasse som sintético para si mesmo seria um app com um modo que ninguém pediu.
enum LacoDeAudio {

    /// Porta de sinalização do laço. Diferente da porta do produto (7877) de propósito: se um
    /// espelhamento estiver vivo, a appex é dona daquela porta e o laço morreria com "endereço em
    /// uso" — erro certo, motivo errado, três camadas longe da causa.
    static let porta: UInt16 = 7893

    private static var thread: Thread?
    private static var parar = false

    /// Sobe o emissor do laço numa thread própria e devolve na hora.
    ///
    /// `quall_host` **bloqueia** até alguém entrar (é o contrato do header), então quem chama
    /// segue em frente e o papel de exibir se conecta logo depois — os dois lados sobem em
    /// paralelo, que é a única ordem possível quando os dois são o mesmo processo.
    static func hospedar(pin: String, segundos: Double) {
        guard thread == nil else { return }
        parar = false
        let t = Thread { correr(pin: pin, segundos: segundos) }
        t.name = "quall.laco-de-audio"
        t.stackSize = 1 << 19
        thread = t
        t.start()
    }

    static func encerrar() { parar = true }

    // -------------------------------------------------------------------------------------------

    private static func correr(pin: String, segundos: Double) {
        defer { thread = nil }

        let especie = QUALL_TRACK_KIND_SYSTEM_AUDIO
        // **O preset vem do núcleo, com o codec dito.** Uma casca que fixasse 48 000/2/960 seria o
        // quinto lugar onde o preset do fio e o do codificador podem divergir em silêncio — a
        // classe de defeito da §11 de `docs/audio.md`. E o codec é dito porque
        // `CodecDeAudio::canais_no_fio` existe: pedir o preset de `SYSTEM_AUDIO` sem dizer o codec
        // devolveria 2 canais mesmo numa sessão PCMU, onde o fio é mono.
        guard let preset = PresetDeAudioLido.ler(especie: especie, codec: QUALL_AUDIO_CODEC_OPUS) else {
            Diario.dizer("!! laço de áudio: o núcleo recusou o preset de áudio do sistema")
            return
        }
        Diario.dizer("laço de áudio: hospedando em 127.0.0.1:\(porta) — preset \(preset.resumo)")

        guard let encoder = quall_audio_encoder_new(especie, QUALL_AUDIO_CODEC_OPUS) else {
            Diario.dizer("!! laço de áudio: quall_audio_encoder_new recusou — \(SanitizacaoDoLog.causaExterna(NucleoReceptor.ultimoErro()))")
            return
        }
        defer { quall_audio_encoder_free(encoder) }

        var idC = Array("laco-de-audio-\(Identidade.deviceId)".utf8CString)
        var nomeC = Array("laço de áudio (\(Identidade.nome))".utf8CString)
        var pinC = Array(pin.utf8CString)
        var rotuloC = Array("tom sintético — 400/500/800/1000 Hz".utf8CString)

        let sessao: OpaquePointer? = idC.withUnsafeMutableBufferPointer { id in
            nomeC.withUnsafeMutableBufferPointer { nome in
                pinC.withUnsafeMutableBufferPointer { pinp in
                    rotuloC.withUnsafeMutableBufferPointer { rotulo in
                        // **`audio_codec` explícito, e é o campo que o `Nucleo` do emissor deixa em
                        // `DEFAULT`.** Lá a track é de vídeo e o campo é ignorado; aqui ele é o
                        // que faz a oferta anunciar `opus/48000/2` em vez do padrão da espécie.
                        var desc = QuallTrackDesc(kind: especie,
                                                  label: rotulo.baseAddress,
                                                  audio_codec: QUALL_AUDIO_CODEC_OPUS)
                        return withUnsafePointer(to: &desc) { tracks -> OpaquePointer? in
                            var opcoes = QuallSessionOptions(
                                me: QuallDeviceDesc(device_id: id.baseAddress,
                                                    display_name: nome.baseAddress,
                                                    screen_source: false,
                                                    camera_source: false,
                                                    sink: false),
                                pin: pinp.baseAddress,
                                known_peers_json: nil,
                                signaling_port: porta,
                                timeout_ms: 30_000,
                                tracks: tracks,
                                track_count: 1,
                                // Só a casca que **conecta** pede o cabo, e nenhuma tela do iOS oferece isso ainda:
                                // `nil` mantém o comportamento de sempre, com o ICE reunindo toda interface. Ver
                                // `QuallSessionOptions::bind_address` e `docs/quall-pelo-cabo.md`.
                                bind_address: nil)
                            return withUnsafePointer(to: &opcoes) { quall_host($0) }
                        }
                    }
                }
            }
        }
        guard let sessao else {
            Diario.dizer("!! laço de áudio: quall_host falhou — \(SanitizacaoDoLog.causaExterna(NucleoReceptor.ultimoErro()))")
            return
        }
        defer { quall_session_close(sessao) }

        guard quall_session_track_count(sessao) > 0,
              let track = quall_session_track(sessao, 0) else {
            Diario.dizer("!! laço de áudio: a sessão subiu sem track de saída")
            return
        }
        defer { quall_track_free(track) }
        Diario.dizer("laço de áudio: receptor entrou; começando a emitir o tom")

        // --- o laço de emissão -----------------------------------------------------------------
        //
        // Um quadro a cada `quadroMs`, com o alvo calculado a partir do **início** e não somado a
        // cada volta: um acumulador de `sleep` deriva, e a deriva apareceria do outro lado como
        // subconsumo — que é justamente o número que esta corrida existe para medir. O relógio tem
        // de ser o menos suspeito da sala.
        let amostrasPorCanal = preset.amostrasPorQuadro
        let canais = preset.canais
        let intervalo = Double(preset.quadroMs) / 1000.0
        var saida = [UInt8](repeating: 0, count: 4000)
        let inicio = Medidas.agoraUs()
        let fim = inicio &+ UInt64(segundos * 1_000_000)
        var indice = 0
        var enviados: UInt64 = 0
        var recusados: UInt64 = 0

        while !parar, Medidas.agoraUs() < fim {
            let pcm = TomSintetico.quadro(indice: indice, amostrasPorCanal: amostrasPorCanal,
                                          taxaHz: Double(preset.taxaHz), canais: canais)
            let n = pcm.withUnsafeBufferPointer { entrada -> Int in
                saida.withUnsafeMutableBufferPointer { destino in
                    quall_audio_encoder_encode(encoder, entrada.baseAddress, UInt(entrada.count),
                                               destino.baseAddress, UInt(destino.count))
                }
            }
            if n > 0 {
                let ts = Medidas.agoraUs()
                saida.withUnsafeBufferPointer { bytes in
                    var amostra = QuallAudioSample(payload: bytes.baseAddress,
                                                   len: UInt(n),
                                                   timestamp_us: ts)
                    if withUnsafePointer(to: &amostra, { quall_track_send_audio(track, $0) })
                        == QUALL_STATUS_OK {
                        enviados &+= 1
                    } else {
                        recusados &+= 1
                    }
                }
            } else {
                recusados &+= 1
            }
            indice += 1

            let alvo = inicio &+ UInt64(Double(indice) * intervalo * 1_000_000)
            let agora = Medidas.agoraUs()
            if alvo > agora { Thread.sleep(forTimeInterval: Double(alvo - agora) / 1_000_000) }
        }

        Diario.dizer("laço de áudio: FIM emissor quadros_enviados=\(enviados) "
                     + "recusados=\(recusados) notas=\(TomSintetico.notasHz.map { Int($0) })")
    }
}
