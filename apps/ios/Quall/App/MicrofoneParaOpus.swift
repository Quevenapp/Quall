import AVFoundation
import CoreMedia
import Foundation

/// **Do `CMSampleBuffer` do microfone ao pacote Opus carimbado** (R5 fase 2,
/// `docs/teleprompter-com-camera.md` §4.3 e §8.4).
///
/// O microfone chega por uma `AVCaptureSession` **só dele**, dentro do `DonoDaCaptura` (na da câmera,
/// ligar parou a imagem por 434 ms: `docs/teleprompter-com-camera.md` §8.5). O dono converte o PTS
/// de cada buffer do relógio da sessão do microfone para o da sessão da câmera
/// (`CMSyncConvertTime`, `noRelogioDaCamera`) antes de entregar: o que chega aqui já está no relógio
/// dos quadros. O vídeo vai ao núcleo como
/// `Carimbo.microssegundos(de: pts)`; o som vai pela mesma conta, a partir do PTS do buffer de
/// captura — **o carimbo é o da captura, e não o do envio** (`docs/contrato-track.md`).
///
/// # O que acontece com cada buffer
///
/// 1. **Reamostragem** para o preset do núcleo (`PresetDeAudioLido`, Opus 48 kHz mono em quadros de
///    20 ms), por `AVAudioConverter`. O iOS não deixa a `AVCaptureAudioDataOutput` escolher o
///    formato (`audioSettings` é só do macOS), e o microfone entrega o que o hardware usa: em geral
///    48 kHz (a sessão de áudio pede 48 kHz), às vezes 44,1.
/// 2. **Fila** de amostras reamostradas, cortada em quadros de exatamente `amostrasPorQuadro`.
/// 3. **O carimbo**, pela disciplina do contrato (fixada em 21/09 para as outras cascas):
///    - anda **exatamente um quadro por pacote** (20 000 µs);
///    - a hora real da primeira amostra de cada quadro sai da **âncora** do último buffer (o PTS
///      dele e quantas amostras de entrada vieram antes), e o **erro** entre ela e o carimbo é
///      tirado do **conteúdo**: acima de +0,5 ms o quadro usa uma amostra real a menos (repete a
///      última); abaixo de −0,5 ms, uma a mais (pula uma). Uma amostra por quadro é ~1 000 ppm, o
///      alcance da "razão" do contrato;
///    - **fora desse alcance** (erro acima de 5 ms): degrau para a frente, ou corte da entrada
///      quando o carimbo está adiantado. Nunca para trás;
///    - **descontinuidade de captura** (o PTS de um buffer longe do previsto por mais de 10 ms: o
///      botão desligado e ligado de novo, uma interrupção): a fila e o conversor recomeçam, e o
///      carimbo é reancorado **para a frente**.
///
///    Isto **não** é o laço de razão do Windows e do Android (a reamostragem contínua com `f` em
///    ppm): é uma correção de uma amostra por vez. Fica dito no §8.4.
/// 4. **Opus** por `quall_audio_encoder_new(MICROPHONE, OPUS)`: o preset do encoder e o do fio saem
///    da mesma função do núcleo.
///
/// # Bancada: o tom no lugar da sala
///
/// Com `--microfone-tom` (só com o diagnóstico ligado), o conteúdo de cada quadro é trocado pelo
/// `TomSintetico` **depois** da disciplina do carimbo: o carimbo continua sendo o da captura, e o
/// som da sala nunca sai do aparelho. É a prova de caminho da regra de bancada
/// (`docs/audio.md` §8.1). O microfone abre do mesmo jeito (o indicador laranja acende).
///
/// **Uma thread só**: a `filaDoOpus` do emissor (§8.12.11). O estado do Opus é preditivo e o encoder não pode
/// ser chamado de duas threads (`quall.h`). Os contadores têm trava própria, para o relato de 10 s.
final class MicrofoneParaOpus {

    let preset: PresetDeAudioLido
    private let encoder: OpaquePointer
    private let formatoDeSaida: AVAudioFormat
    private let taxaDeSaida: Double
    private let tom: Bool

    private var formatoDeEntrada: AVAudioFormat?
    private var assinaturaDaEntrada = ""
    private var conversor: AVAudioConverter?
    private var taxaDeEntrada: Double = 0

    /// Amostras reamostradas esperando virar quadro.
    private var fila: [Int16] = []
    /// O índice, em amostras de **saída** contadas desde o último recomeço, de `fila[0]`.
    private var indiceDoInicio: Int64 = 0
    /// Amostras de **entrada** desde o último recomeço, e a âncora: o PTS do último buffer e quantas
    /// amostras de entrada vieram antes dele.
    private var totalDeEntrada: Int64 = 0
    /// O diário da descontinuidade: uma linha a cada 5 s (na fila de quem consome).
    private var ultimaLinhaDeDescontinuidade: Double = -10
    private var descontinuidadesCaladas = 0
    private var ancoraPts: Double = 0
    private var ancoraEntrada: Int64 = 0
    private var ancorado = false

    /// O carimbo do próximo pacote, e o do último que saiu (para o recomeço nunca andar para trás).
    private var proximoCarimboUs: Int64?
    private var ultimoCarimboUs: Int64 = 0
    private let quadroUs: Int64
    private var indiceDoTom = 0
    private var pacote = [UInt8](repeating: 0, count: 4000)

    private let trava = NSLock()
    private var _quadros: UInt64 = 0
    private var _enviados: UInt64 = 0
    private var _recusados: UInt64 = 0
    private var _falhasDoEncoder: UInt64 = 0
    private var _descontinuidades: UInt64 = 0
    private var _degraus: UInt64 = 0
    private var _cortes: UInt64 = 0
    private var _inseridas: UInt64 = 0
    private var _tiradas: UInt64 = 0
    private var _erroUs: Double = 0
    private var _erroMaximoUs: Double = 0
    /// O tempo de cada `quall_audio_encoder_encode` (um quadro Opus), por janela de relato: o custo do
    /// encoder no aparelho quente (§8.12.13). Sob `trava`.
    private var _encodeMaximoMs: Double = 0
    private var _encodeSomaMs: Double = 0
    private var _encodes = 0
    private var _entrada = "?"

    // --- a complexidade do Opus (§8.12.17) ---------------------------------------------------------

    /// **A complexidade do Opus no calor**: 4 (o padrão é 10, e não pode baixar sem perder o LBRR que o fio
    /// promete — `PresetDeAudio::complexidade_do_encoder`). Em 4 a libopus decide o LBRR com histerese: um
    /// encoder que já o emitia segue emitindo (medido na fronteira, tom de quatro notas: 90 de 90), um que
    /// não emitia não liga; a volta a 10 devolve (190 de 190, `a_complexidade_do_calor_tira_o_lbrr_e_a_volta_o_devolve`).
    /// No iPhone 7 quente o som se perdia por falta de CPU, não pela rede. Medido no MacBook: 10 ≈ 0,8 ms por
    /// quadro, 4 entre 0,16 e 0,2 — hipótese para o A10: a mesma proporção.
    static let complexidadeQuente: UInt8 = 4
    /// A padrão da espécie (7 para o microfone), lida do núcleo.
    let complexidadePadrao: UInt8
    /// A pedida (de qualquer thread) e a aplicada (só na fila de quem consome). Sob `trava`.
    private var _complexidadePedida: UInt8
    private var complexidadeAplicada: UInt8
    /// A aplicada, para o relato (de outra thread). Sob `trava`.
    private var _complexidadeNoRelato: UInt8

    /// Pede a complexidade do calor (`quente`) ou a padrão; vale no próximo quadro, na fila do Opus.
    func pedirComplexidade(quente: Bool) {
        trava.lock(); _complexidadePedida = quente ? MicrofoneParaOpus.complexidadeQuente : complexidadePadrao; trava.unlock()
    }

    /// `nil` quando o núcleo recusa o preset ou o encoder (o motivo vai ao diagnóstico).
    init?(tom: Bool) {
        let especie = QUALL_TRACK_KIND_MICROPHONE
        guard let p = PresetDeAudioLido.ler(especie: especie, codec: QUALL_AUDIO_CODEC_OPUS) else {
            Diagnostico.falha("APP MICROFONE o núcleo recusou o preset de microfone: \(SanitizacaoDoLog.causaExterna(Nucleo.ultimoErro()))")
            return nil
        }
        // Mono: é o que o preset de microfone diz, e o único caso que este arquivo trata. Um preset
        // que mude isso tem de mudar este arquivo junto, e a recusa aqui é o que faz isso aparecer.
        guard p.canais == 1, p.amostrasPorQuadro > 0, p.taxaHz > 0 else {
            Diagnostico.falha("APP MICROFONE preset inesperado (\(p.resumo)): só mono é tratado aqui")
            return nil
        }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(p.taxaHz),
                                      channels: 1, interleaved: true) else { return nil }
        guard let e = quall_audio_encoder_new(especie, QUALL_AUDIO_CODEC_OPUS) else {
            Diagnostico.falha("APP MICROFONE quall_audio_encoder_new recusou: \(SanitizacaoDoLog.causaExterna(Nucleo.ultimoErro()))")
            return nil
        }
        let padrao = quall_audio_default_complexity(especie)
        complexidadePadrao = padrao >= 0 ? UInt8(min(10, padrao)) : 10
        _complexidadePedida = complexidadePadrao
        complexidadeAplicada = complexidadePadrao
        _complexidadeNoRelato = complexidadePadrao
        preset = p
        encoder = e
        formatoDeSaida = fmt
        taxaDeSaida = Double(p.taxaHz)
        quadroUs = Int64(p.amostrasPorQuadro) * 1_000_000 / Int64(p.taxaHz)
        self.tom = tom
        Diagnostico.nota("APP MICROFONE encoder de pé: \(p.resumo)\(tom ? " — TOM SINTÉTICO no lugar da sala" : "")")
    }

    deinit { quall_audio_encoder_free(encoder) }

    // --- o caminho do buffer ------------------------------------------------------------------

    /// Um buffer do microfone. `enviar` recebe um pacote Opus e o carimbo, e devolve se o núcleo
    /// aceitou. Chamado **só** da fila do áudio.
    func consumir(_ amostra: CMSampleBuffer,
                  enviar: (UnsafeRawBufferPointer, UInt64) -> Bool) {
        guard let desc = CMSampleBufferGetFormatDescription(amostra),
              let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let n = CMSampleBufferGetNumSamples(amostra)
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(amostra))
        guard n > 0, pts.isFinite, pts > 0 else { return }

        let asbd = asbdP.pointee
        let assinatura = "\(asbd.mSampleRate)|\(asbd.mChannelsPerFrame)|\(asbd.mFormatID)"
            + "|\(asbd.mFormatFlags)|\(asbd.mBitsPerChannel)"
        if assinatura != assinaturaDaEntrada {
            let f = AVAudioFormat(cmAudioFormatDescription: desc)
            guard let c = AVAudioConverter(from: f, to: formatoDeSaida) else {
                Diagnostico.falha("APP MICROFONE AVAudioConverter recusou \(f) → \(formatoDeSaida)")
                return
            }
            // Mais de um canal (um microfone estéreo, um adaptador): a mistura, e não o primeiro.
            c.downmix = true
            // Sem latência de reamostragem: a amostra de saída k corresponde à hora da amostra de
            // entrada k × entrada/saída, que é a conta do carimbo abaixo. (O padrão já é este; dito
            // porque a conta depende dele.)
            c.primeMethod = .normal
            formatoDeEntrada = f
            conversor = c
            taxaDeEntrada = asbd.mSampleRate
            assinaturaDaEntrada = assinatura
            let rotulo = "\(Int(asbd.mSampleRate)) Hz \(asbd.mChannelsPerFrame) ch"
                + " \(asbd.mBitsPerChannel) bits\((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? " float" : "")"
            trava.lock(); _entrada = rotulo; trava.unlock()
            Diagnostico.nota("APP MICROFONE entrada: \(rotulo), \(n) amostras por buffer → "
                + "\(preset.taxaHz) Hz mono em quadros de \(preset.amostrasPorQuadro)")
            recomecar()
        }
        guard let formatoDeEntrada, let conversor, taxaDeEntrada > 0 else { return }

        // A continuidade: o PTS deste buffer contra o previsto pela âncora anterior.
        if ancorado {
            let previsto = ancoraPts + Double(totalDeEntrada - ancoraEntrada) / taxaDeEntrada
            let desvio = pts - previsto
            if abs(desvio) > 0.010 {
                trava.lock(); _descontinuidades &+= 1; trava.unlock()
                // **Uma linha a cada 5 s, no máximo**, com as caladas contadas (bancada de 27/09 à
                // tarde: várias por segundo no iPhone 7 quente, e o diário perdeu linhas — entre
                // elas o motivo de uma gravação parando). O total segue no relato (`descontinuidades=`).
                let agora = ProcessInfo.processInfo.systemUptime
                if agora - ultimaLinhaDeDescontinuidade >= 5 {
                    Diagnostico.nota(String(format: "APP MICROFONE descontinuidade de %.1f ms: a fila recomeça e o carimbo reancora para a frente",
                                            desvio * 1000)
                        + (descontinuidadesCaladas > 0 ? " (+\(descontinuidadesCaladas) sem linha desde a anterior)" : ""))
                    ultimaLinhaDeDescontinuidade = agora
                    descontinuidadesCaladas = 0
                } else {
                    descontinuidadesCaladas += 1
                }
                recomecar()
            }
        }
        // O CPU por pedaço (§8.12.18): a cópia e a conversão, o quadro, o encode, o envio — a fila do Opus
        // gastava 30–52 % de um núcleo quente com o encode puro em ~1 ms por quadro.
        let cpuDaConversao = MedidorDeCpu.agora()
        guard let entrada = AVAudioPCMBuffer(pcmFormat: formatoDeEntrada,
                                             frameCapacity: AVAudioFrameCount(n)) else { return }
        // **`frameLength` antes da cópia**: é ele que dá o `mDataByteSize` da lista de buffers, e
        // com 0 (o valor de nascença) a cópia é recusada. (Revisão de 24/09.)
        entrada.frameLength = AVAudioFrameCount(n)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            amostra, at: 0, frameCount: Int32(n), into: entrada.mutableAudioBufferList)
        guard st == noErr else {
            Diagnostico.falha("APP MICROFONE CMSampleBufferCopyPCMDataIntoAudioBufferList: \(st)")
            return
        }
        // A âncora e a contagem andam juntas, e só com o buffer de fato copiado: um buffer
        // recusado não pode virar uma descontinuidade falsa no seguinte.
        ancoraPts = pts
        ancoraEntrada = totalDeEntrada
        ancorado = true
        totalDeEntrada &+= Int64(n)

        let capacidade = AVAudioFrameCount(Double(n) * taxaDeSaida / taxaDeEntrada) + 64
        guard let saida = AVAudioPCMBuffer(pcmFormat: formatoDeSaida, frameCapacity: capacidade) else { return }
        var entregue = false
        var erro: NSError?
        let estado = conversor.convert(to: saida, error: &erro) { _, situacao in
            if entregue { situacao.pointee = .noDataNow; return nil }
            entregue = true
            situacao.pointee = .haveData
            return entrada
        }
        guard estado != .error, let canal = saida.int16ChannelData else {
            Diagnostico.falha("APP MICROFONE a conversão falhou: \(erro.map { SanitizacaoDoLog.erro($0) } ?? "?")")
            return
        }
        let m = Int(saida.frameLength)
        if m > 0 { fila.append(contentsOf: UnsafeBufferPointer(start: canal[0], count: m)) }
        MedidorDeCpu.somar("opus_conversao", desde: cpuDaConversao)

        // Uma amostra a mais do que o quadro: é o que o caso "tira uma" consome.
        let q = preset.amostrasPorQuadro
        while fila.count >= q + 1 {
            emitirUmQuadro(enviar: enviar)
        }
    }

    /// A fila e o conversor do zero, e a âncora solta. O carimbo **não** volta: o próximo pacote sai
    /// no maior entre a hora real e o sucessor do último.
    private func recomecar() {
        fila.removeAll(keepingCapacity: true)
        indiceDoInicio = 0
        totalDeEntrada = 0
        ancoraEntrada = 0
        ancorado = false
        conversor?.reset()
        proximoCarimboUs = nil
    }

    private func emitirUmQuadro(enviar: (UnsafeRawBufferPointer, UInt64) -> Bool) {
        let q = preset.amostrasPorQuadro
        // A hora real (µs do relógio da sessão de captura) da primeira amostra da fila.
        let realUs = (ancoraPts + Double(indiceDoInicio) / taxaDeSaida
                      - Double(ancoraEntrada) / taxaDeEntrada) * 1_000_000
        if proximoCarimboUs == nil {
            let r = Int64(realUs.rounded(.down))
            proximoCarimboUs = ultimoCarimboUs > 0 ? max(r, ultimoCarimboUs &+ quadroUs) : r
        }
        guard var carimbo = proximoCarimboUs else { return }
        var erro = realUs - Double(carimbo)

        if erro > 5_000 {
            // O carimbo ficou para trás além do alcance da correção por amostra: degrau para a frente.
            carimbo = max(Int64(realUs.rounded(.down)), carimbo)
            erro = realUs - Double(carimbo)
            trava.lock(); _degraus &+= 1; trava.unlock()
        } else if erro < -5_000 {
            // O carimbo está adiantado: corta a entrada até a hora real alcançá-lo. Nunca para trás.
            let tirar = min(fila.count - (q + 1), Int((-erro) / 1_000_000 * taxaDeSaida))
            if tirar > 0 {
                fila.removeFirst(tirar)
                indiceDoInicio &+= Int64(tirar)
                trava.lock(); _cortes &+= 1; trava.unlock()
                return   // o laço de fora confere de novo se ainda cabe um quadro
            }
        }

        let cpuDoQuadro = MedidorDeCpu.agora()
        var quadro = [Int16](repeating: 0, count: q)
        let consumidas: Int
        // Cópias em bloco (`update(from:count:)`), e não amostra a amostra: o app de bancada é Debug
        // (`-Onone`), onde um laço de 960 subscritos por quadro custa (§8.12.18).
        if erro > 500 {
            // A hora real está à frente do carimbo: o quadro anda uma amostra real a menos.
            fila.withUnsafeBufferPointer { f in
                quadro.withUnsafeMutableBufferPointer { d in
                    d.baseAddress!.update(from: f.baseAddress!, count: q - 1)
                    d[q - 1] = f[q - 2]
                }
            }
            consumidas = q - 1
            trava.lock(); _inseridas &+= 1; trava.unlock()
        } else if erro < -500 {
            // O carimbo está à frente da hora real: o quadro anda uma amostra real a mais (pula a do meio).
            let meio = q / 2
            fila.withUnsafeBufferPointer { f in
                quadro.withUnsafeMutableBufferPointer { d in
                    d.baseAddress!.update(from: f.baseAddress!, count: meio)
                    (d.baseAddress! + meio).update(from: f.baseAddress! + meio + 1, count: q - meio)
                }
            }
            consumidas = q + 1
            trava.lock(); _tiradas &+= 1; trava.unlock()
        } else {
            fila.withUnsafeBufferPointer { f in
                quadro.withUnsafeMutableBufferPointer { d in
                    d.baseAddress!.update(from: f.baseAddress!, count: q)
                }
            }
            consumidas = q
        }
        fila.removeFirst(consumidas)
        indiceDoInicio &+= Int64(consumidas)

        if tom {
            quadro = TomSintetico.quadro(indice: indiceDoTom, amostrasPorCanal: q,
                                         taxaHz: taxaDeSaida, canais: 1)
            indiceDoTom &+= 1
        }
        MedidorDeCpu.somar(tom ? "opus_quadro_com_tom" : "opus_quadro", desde: cpuDoQuadro)

        // A complexidade pedida (o calor), aplicada aqui, na única thread que usa o encoder.
        trava.lock(); let pedida = _complexidadePedida; trava.unlock()
        if pedida != complexidadeAplicada {
            let st = quall_audio_encoder_set_complexity(encoder, pedida)
            Diagnostico.nota("APP MICROFONE complexidade do Opus: \(complexidadeAplicada) → \(pedida)"
                + (st == 0 ? "" : " RECUSADA (\(SanitizacaoDoLog.causaExterna(Nucleo.ultimoErro())))")
                + (pedida < complexidadePadrao ? " (o LBRR segue só se já estava ligado: a troca do calor)" : ""))
            if st == 0 {
                complexidadeAplicada = pedida
                trava.lock(); _complexidadeNoRelato = pedida; trava.unlock()
            }
            else { trava.lock(); _complexidadePedida = complexidadeAplicada; trava.unlock() }
        }
        let antesDoEncode = CFAbsoluteTimeGetCurrent()
        let cpuDoEncode = MedidorDeCpu.agora()
        let bytes = quadro.withUnsafeBufferPointer { entrada -> Int in
            pacote.withUnsafeMutableBufferPointer { destino in
                quall_audio_encoder_encode(encoder, entrada.baseAddress, UInt(entrada.count),
                                           destino.baseAddress, UInt(destino.count))
            }
        }
        MedidorDeCpu.somar("opus_encode", desde: cpuDoEncode)
        let encodeMs = (CFAbsoluteTimeGetCurrent() - antesDoEncode) * 1000
        proximoCarimboUs = carimbo &+ quadroUs
        trava.lock()
        _encodeMaximoMs = max(_encodeMaximoMs, encodeMs)
        _encodeSomaMs += encodeMs
        _encodes += 1
        _quadros &+= 1
        _erroUs = erro
        _erroMaximoUs = max(_erroMaximoUs, abs(erro))
        trava.unlock()
        guard bytes > 0, carimbo > 0 else {
            trava.lock(); _falhasDoEncoder &+= 1; trava.unlock()
            return
        }
        ultimoCarimboUs = carimbo
        let cpuDoEnvio = MedidorDeCpu.agora()
        let aceito = pacote.withUnsafeBytes { tudo in
            enviar(UnsafeRawBufferPointer(rebasing: tudo[0..<bytes]), UInt64(carimbo))
        }
        MedidorDeCpu.somar("opus_envio", desde: cpuDoEnvio)
        trava.lock()
        if aceito { _enviados &+= 1 } else { _recusados &+= 1 }
        trava.unlock()
    }

    /// Uma linha para o relato de 10 s e para o desmonte. `erro_max` zera a cada leitura.
    func resumo() -> String {
        trava.lock(); defer { trava.unlock() }
        let s = "entrada=\(_entrada) quadros=\(_quadros) enviados=\(_enviados) recusados=\(_recusados)"
            + " falhas_encoder=\(_falhasDoEncoder) descontinuidades=\(_descontinuidades)"
            + " degraus=\(_degraus) cortes=\(_cortes) inseridas=\(_inseridas) tiradas=\(_tiradas)"
            + String(format: " erro=%.0f us erro_max=%.0f us", _erroUs, _erroMaximoUs)
            + String(format: " encode_max=%.2f ms encode_medio=%.2f ms", _encodeMaximoMs,
                     _encodes > 0 ? _encodeSomaMs / Double(_encodes) : 0)
            + " complexidade=\(_complexidadeNoRelato)"
            + (tom ? " TOM" : "")
        _erroMaximoUs = 0
        _encodeMaximoMs = 0; _encodeSomaMs = 0; _encodes = 0
        return s
    }
}
