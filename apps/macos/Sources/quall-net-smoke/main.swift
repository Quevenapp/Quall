import CQuall
import Foundation
import QuallNetKit

/// Smoke test da ponte de rede que o M6 escreveu para `apps/macos` (`QuallNetKit`).
///
/// `apps/macos` nunca teve rede — só captura+encode (`QuallCaptureKit`, Frente 3, M1). Esta
/// rodada não constrói o app de produto (janela, seletor de origem — ver `docs/ux-m6.md`, seção
/// 4), porque isso exigiria permissão TCC de tela/câmera que só um app assinado, aberto por um
/// humano, concede (`docs/regras-de-frente.md`, "Ler o estado de uma permissão não é pedi-la").
/// O que dá para provar sem nenhuma permissão de sistema é a parte de maior risco: será que o
/// Swift consegue mesmo chamar `quall_host`/`quall_track_send_frame`/`quall_session_close` e
/// trocar quadros de verdade com o núcleo, pela rede, sem travar?
///
/// Por isso os quadros aqui são **sintéticos** — bytes fabricados com start code Annex-B e um
/// cabeçalho de NAL plausível (SPS/PPS/IDR na primeira "rajada", P-frames depois), nunca pixels
/// da tela ou da câmera deste Mac. Não há H.264 decodificável de verdade, de propósito: o
/// objetivo é exercitar a fronteira C e o transporte, não fingir uma captura que este binário não
/// faz. `quall-probe receber-video` do outro lado só verifica que os bytes chegam e a contagem
/// bate — não decodifica.
///
/// Uso:
///   quall-net-smoke hospedar [--pin 123456] [--porta 0] [--quadros 30] [--prazo-ms 30000]
///
/// Roteiro de verificação (ver `docs/ux-m6.md`, seção 4):
///   Terminal A: .build/release/quall-net-smoke hospedar --pin 314159 --porta 17877 --quadros 20
///   Terminal B: target/release/quall-probe receber-video --ip 127.0.0.1:17877 --pin 314159 \
///               --saida /tmp/quall-smoke.h264
///   Confirma: os dois lados relatam 20 quadros; nenhum trava; `ls -la /tmp/quall-smoke.h264`
///   mostra bytes recebidos (não abro nem "assisto" o arquivo — é sintético, mas a prática de
///   nunca abrir um artefato assim vale igual, e conferir só por tamanho/contagem é hábito bom).

func syntheticFrame(numero: Int) -> (bytes: [UInt8], idr: Bool) {
    let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    if numero == 0 {
        // SPS (0x67) + PPS (0x68) + IDR slice (0x65) na mesma unidade de acesso — é o que o
        // contrato exige de todo IDR (docs/contrato-sidecar.md: "SPS/PPS reemitidos antes de
        // cada IDR"). Payload é lixo determinístico, não H.264 real.
        var bytes: [UInt8] = []
        bytes += startCode + [0x67] + (0..<12).map { UInt8(($0 * 7 + 3) & 0xFF) }
        bytes += startCode + [0x68] + (0..<4).map { UInt8(($0 * 5 + 1) & 0xFF) }
        bytes += startCode + [0x65] + (0..<64).map { UInt8(($0 * 13 + numero) & 0xFF) }
        return (bytes, true)
    } else {
        var bytes: [UInt8] = []
        bytes += startCode + [0x41] + (0..<48).map { UInt8(($0 * 11 + numero) & 0xFF) }
        return (bytes, false)
    }
}

struct Opcoes {
    var pin = NucleoDeRede.sortearPin()
    var porta: UInt16 = 0
    var quadros = 30
    var prazoMs: UInt32 = 30_000
    var rotulo = "smoke-screen"
    var comAudio = false
    /// Abre **só** a track de áudio de sistema.
    ///
    /// Existe porque `quall-probe receber-audio` chama `quall_session_next_track` **uma vez** e
    /// recusa o que vier se não for áudio — numa sessão de duas tracks ele pega a de tela e para.
    /// Com esta opção a única track é a de som, e a sonda tem o que adotar. É o jeito de ler o que
    /// o núcleo negociou no SDP para `SystemAudio` sem tocar em `crates/`.
    var soAudio = false
}

func parseOpcoes(_ args: [String]) -> Opcoes {
    var o = Opcoes()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--pin": i += 1; if i < args.count { o.pin = args[i] }
        case "--porta": i += 1; if i < args.count { o.porta = UInt16(args[i]) ?? 0 }
        case "--quadros": i += 1; if i < args.count { o.quadros = Int(args[i]) ?? 30 }
        case "--prazo-ms": i += 1; if i < args.count { o.prazoMs = UInt32(args[i]) ?? 30_000 }
        // **Prova a sessão de duas tracks sem tocar em permissão nenhuma.** Abre uma track de
        // áudio de sistema junto da de tela e relata o que o núcleo devolveu. Não manda quadro de
        // som: a fronteira C não exporta `quall_track_send_audio` (ver `NucleoDeRede.enviarAudio`).
        // O que isto mede é a **abertura** das duas tracks na mesma sessão, que é a metade que não
        // depende do que falta.
        case "--com-audio": o.comAudio = true
        case "--so-audio": o.soAudio = true; o.comAudio = true
        default: break
        }
        i += 1
    }
    return o
}

quall_install_panic_hook(nil, nil)

let args = Array(CommandLine.arguments.dropFirst())
let comando = args.first ?? "ajuda"

switch comando {
case "hospedar":
    let o = parseOpcoes(Array(args.dropFirst()))
    print("versao_do_protocolo=\(NucleoDeRede.versaoDoProtocolo())")
    print("PIN presente=true prazo_ms=\(o.prazoMs)")
    let nucleo = NucleoDeRede()
    let subiu = nucleo.hospedar(
        pin: o.pin,
        porta: o.porta,
        deviceId: "quall-net-smoke-\(UUID().uuidString.prefix(8))",
        nome: "MacBook (quall-net-smoke)",
        tracksPedidas: [.init(tipo: QUALL_TRACK_KIND_SCREEN, rotulo: o.rotulo)],
        paresConhecidos: nil,
        prazoMs: o.prazoMs)
    guard subiu else {
        print("ERRO ao hospedar: status=\(nucleo.ultimoStatusDeFalha.rawValue)")
        exit(1)
    }
    print("hospedado porta=\(nucleo.porta) pareamento_novo=\(nucleo.pareamentoNovo)")
    print("PARA CONECTAR: quall-probe receber-video --ip 127.0.0.1:\(nucleo.porta) --pin <PIN> --saida <arquivo>.h264")

    var enviados = 0
    var recusados = 0
    let inicio = DispatchTime.now()
    for n in 0..<o.quadros {
        let (bytes, idr) = syntheticFrame(numero: n)
        let agora = DispatchTime.now().uptimeNanoseconds / 1000
        let status = bytes.withUnsafeBytes { buf in
            nucleo.enviar(annexb: buf, timestampUs: agora, idr: idr)
        }
        if status == QUALL_STATUS_OK {
            enviados += 1
        } else {
            recusados += 1
            print("quadro \(n): recusado, status=\(status.rawValue) (detalhe externo omitido)")
        }
        Thread.sleep(forTimeInterval: 1.0 / 30.0)
    }
    let fimNs = DispatchTime.now().uptimeNanoseconds - inicio.uptimeNanoseconds
    print("enviados=\(enviados) recusados=\(recusados) duracao_ms=\(fimNs / 1_000_000)")

    nucleo.encerrar()
    print("encerrado")

case "espelhar":
    // Exercita **a ponte que o app de produto usa**, com quadros sintéticos.
    //
    // O `hospedar` acima prova o mínimo: subir, mandar, fechar. Este prova as quatro peças que o
    // app acrescentou e que são as de maior risco, porque cada uma delas paga uma dívida do
    // núcleo e nenhuma aparece numa medição de vazão:
    //
    //   1. `Anunciante`   — anunciar por mDNS **antes** de hospedar (a porta é escolhida pela
    //                       casca, porque `quall_host` bloqueia e a porta só sairia da sessão
    //                       depois que ela sobe — tarde demais para o anúncio servir).
    //   2. `Cancelador`   — `--cancelar-em N` prova que o Cancelar destrava uma espera bloqueada,
    //                       que é a dívida 10. Sem ele a casca precisaria abrir uma conexão
    //                       descartável contra a própria porta para se destravar.
    //   3. `proximoEvento`— o detector de queda das dívidas 5, 13 e 20: o `Bye` do receptor já
    //                       chega e era jogado fora. Sem ele o emissor fica 30 s cego.
    //   4. `precisaDeIDR` — o pedido de quadro-chave do receptor que entrou no meio do GOP.
    //
    // Os quadros continuam sintéticos de propósito: o objetivo é a fronteira C, não fingir uma
    // captura que este binário não faz.
    let o = parseOpcoes(Array(args.dropFirst()))
    var segundos = 10.0
    var cancelarEm: Double?
    var i = 1
    while i < args.count {
        if args[i] == "--segundos", i + 1 < args.count { segundos = Double(args[i + 1]) ?? 10 }
        if args[i] == "--cancelar-em", i + 1 < args.count { cancelarEm = Double(args[i + 1]) }
        i += 1
    }

    let comAudioPedido = o.comAudio
    let porta = o.porta != 0 ? o.porta : 17879
    let deviceId = "quall-net-smoke-\(UUID().uuidString.prefix(8))"
    let nomeDoAparelho = "MacBook (quall-net-smoke)"

    let anunciante = Anunciante()
    let anunciou = anunciante.comecar(
        deviceId: deviceId, nome: nomeDoAparelho, porta: porta,
        emiteTela: true, emiteCamera: false)
    print("mdns_anunciou=\(anunciou) porta=\(porta)")

    let cancelador = Cancelador()
    if let quando = cancelarEm {
        print("vou cancelar em \(quando)s — a espera tem de destravar sozinha")
        let t = Thread {
            Thread.sleep(forTimeInterval: quando)
            cancelador.cancelar()
            print("cancelar() chamado")
        }
        t.start()
    }

    print("PIN presente=true")
    print("PARA CONECTAR: quall-probe receber-video --ip 127.0.0.1:\(porta) --pin <PIN> --saida /dev/null")

    let nucleo = NucleoDeRede()
    let comecou = DispatchTime.now()
    var pedidas: [NucleoDeRede.DescricaoDeTrack] = o.soAudio ? [] : [
        .init(tipo: QUALL_TRACK_KIND_SCREEN, rotulo: "smoke-screen")
    ]
    if comAudioPedido {
        pedidas.append(.init(tipo: QUALL_TRACK_KIND_SYSTEM_AUDIO, rotulo: "smoke-system-audio",
                             codecDeAudio: QUALL_AUDIO_CODEC_PCMU))
    }
    print("tracks_pedidas=\(pedidas.count)")

    let subiu = nucleo.hospedar(
        pin: o.pin, porta: porta, deviceId: deviceId, nome: nomeDoAparelho,
        tracksPedidas: pedidas,
        paresConhecidos: nil, prazoMs: 5 * 60 * 1000, cancelador: cancelador)
    let esperou = Double(DispatchTime.now().uptimeNanoseconds - comecou.uptimeNanoseconds) / 1e9

    anunciante.parar()
    print("mdns parado")

    guard subiu else {
        // Cancelado é **sucesso** neste teste: a espera de cinco minutos destravou no instante
        // pedido em vez de segurar o processo. `esperou` é a prova, não a mensagem.
        print(String(format: "hospedar voltou em %.2fs — status=%d",
                     esperou, nucleo.ultimoStatusDeFalha.rawValue))
        if nucleo.ultimoStatusDeFalha == QUALL_STATUS_CANCELLED {
            print("VEREDITO: cancelamento funcionou (a espera destravou sem receptor nenhum)")
            exit(0)
        }
        exit(1)
    }
    print(String(format: "hospedado em %.2fs pareamento_novo=%@", esperou, nucleo.pareamentoNovo ? "sim" : "não"))
    print("track_de_audio_aberta=\(nucleo.temTrackDeAudio)")
    print("par: sessão conectada")

    var enviados = 0, recusados = 0, idrsForcados = 0, idrsEnviados = 0
    var queda = "nenhuma"
    let fim = Date().addingTimeInterval(segundos)
    var n = 0
    while Date() < fim {
        let evento = nucleo.proximoEvento()
        if evento == QUALL_SESSION_EVENT_DISCONNECTED { queda = "o receptor saiu (Disconnected)"; break }
        if evento == QUALL_SESSION_EVENT_FAILED { queda = "o transporte falhou (Failed)"; break }

        // Um IDR pedido é um IDR mandado: o quadro 0 sintético é o único que carrega SPS+PPS+IDR.
        let pediu = nucleo.precisaDeIDR()
        if pediu { idrsForcados += 1 }
        let (bytes, idr) = syntheticFrame(numero: (pediu || n == 0) ? 0 : n)

        let agora = DispatchTime.now().uptimeNanoseconds / 1000
        let status = bytes.withUnsafeBytes { nucleo.enviar(annexb: $0, timestampUs: agora, idr: idr) }
        if status == QUALL_STATUS_OK {
            enviados += 1
            if idr { idrsEnviados += 1 }
        } else {
            recusados += 1
        }
        n += 1
        Thread.sleep(forTimeInterval: 1.0 / 30.0)
    }

    print("enviados=\(enviados) recusados=\(recusados) idrs=\(idrsEnviados) idrs_pedidos_pelo_receptor=\(idrsForcados)")
    print("queda detectada: \(queda)")
    print("nucleo: \(nucleo.estatisticasDaTrack())")
    nucleo.encerrar()
    print("encerrado")

case "sortear-pin":
    print(NucleoDeRede.sortearPin())

case "camera-remota":
    // O controle remoto da câmera (R9b) pelas peças do Mac, em 127.0.0.1, sem câmera: `CameraRemota.swift`.
    exit(provaDaCameraRemota(Array(args.dropFirst())))

default:
    print("""
    quall-net-smoke — prova a ponte de rede de QuallNetKit sem tocar tela nem câmera.

      quall-net-smoke hospedar [--pin 123456] [--porta 0] [--quadros 30] [--prazo-ms 30000]
      quall-net-smoke espelhar [--pin 123456] [--porta 17879] [--segundos 10] [--cancelar-em N]
      quall-net-smoke sortear-pin
      quall-net-smoke camera-remota [--porta 17899]
    """)
}
