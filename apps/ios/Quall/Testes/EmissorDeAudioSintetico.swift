import Foundation
import Darwin

/// Emissor de bancada Mac → iOS: somente PCMU/8kHz/mono, quatro notas sintéticas, sem captura.
/// Não grava mídia nem pareamentos e não anuncia por mDNS. O receptor usa endereço e PIN.
@main
enum EmissorDeAudioSintetico {
    private static func erro() -> String {
        guard let texto = quall_last_error() else { return "motivo indisponível" }
        return String(cString: texto)
    }

    static func main() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let porta = UInt16(valor("--porta") ?? "") ?? 17893
        let segundos = min(60, max(2, Double(valor("--segundos") ?? "") ?? 25))
        let pin = valor("--pin") ?? "424242"
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }), porta > 0 else {
            print("ERRO: --pin precisa de seis dígitos; --porta precisa ser 1…65535")
            exit(2)
        }
        let id = strdup("quall-audio-sintetico-\(UUID().uuidString)")!
        let nome = strdup("Quall bancada áudio sintético")!
        let pinC = strdup(pin)!
        let rotulo = strdup("PCMU sintético 400/500/800/1000 Hz")!
        defer { free(id); free(nome); free(pinC); free(rotulo) }
        var desc = QuallTrackDesc(kind: QUALL_TRACK_KIND_SYSTEM_AUDIO, label: rotulo,
                                  audio_codec: QUALL_AUDIO_CODEC_PCMU)
        print("ESPERANDO porta=\(porta) pin=\(pin) codec=pcmu taxa=8000 canais=1 slot=160 origem=sintetica")
        let sessao = withUnsafePointer(to: &desc) { tracks in
            var opcoes = QuallSessionOptions(
                me: QuallDeviceDesc(device_id: id, display_name: nome,
                                    screen_source: false, camera_source: false, sink: false),
                pin: pinC, known_peers_json: nil, signaling_port: porta, timeout_ms: 30_000,
                tracks: tracks, track_count: 1, bind_address: nil)
            return withUnsafePointer(to: &opcoes) { quall_host($0) }
        }
        guard let sessao else { print("ERRO host: \(erro())"); exit(1) }
        defer {
            let fechado = quall_session_close(sessao)
            print("ENCERRADO status=\(fechado.rawValue)")
        }
        guard let track = quall_session_track(sessao, 0) else {
            print("ERRO track: \(erro())"); exit(1)
        }
        defer { quall_track_free(track) }
        let encoder = CodificadorPCMU(preset: .audioDoSistema(codec: .pcmu))
        let inicio = DispatchTime.now().uptimeNanoseconds / 1000
        var enviados = 0, recusados = 0
        print("CONECTADO duração=\(segundos)s sem_camera=1 sem_microfone=1 sem_tela=1")
        for indice in 0..<Int(segundos * 50) {
            let evento = quall_session_next_event(sessao, 0)
            if evento == QUALL_SESSION_EVENT_DISCONNECTED || evento == QUALL_SESSION_EVENT_FAILED {
                print("RECEPTOR_SAIU evento=\(evento.rawValue)"); break
            }
            let pcm = TomSintetico.quadro(indice: indice, amostrasPorCanal: 160,
                                          taxaHz: 8_000, canais: 1)
            for pacote in encoder.codificar(pcm) {
                let estado = pacote.withUnsafeBytes { bytes in
                    var amostra = QuallAudioSample(payload: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                   len: UInt(bytes.count), timestamp_us: inicio + UInt64(indice) * 20_000)
                    return withUnsafePointer(to: &amostra) { quall_track_send_audio(track, $0) }
                }
                if estado == QUALL_STATUS_OK { enviados += 1 } else {
                    recusados += 1
                    if recusados <= 3 { print("ERRO envio: \(erro())") }
                }
            }
            let alvo = inicio + UInt64(indice + 1) * 20_000
            let agora = DispatchTime.now().uptimeNanoseconds / 1000
            if alvo > agora { Thread.sleep(forTimeInterval: Double(alvo - agora) / 1_000_000) }
        }
        let precisa = quall_track_stats_json(track, nil, 0)
        var estatisticas = [CChar](repeating: 0, count: max(1, precisa))
        let leu = estatisticas.withUnsafeMutableBufferPointer {
            quall_track_stats_json(track, $0.baseAddress, UInt($0.count))
        }
        print("FIM enviados=\(enviados) recusados=\(recusados)")
        if precisa > 0 && leu > 0 && leu <= estatisticas.count { print(String(cString: estatisticas)) }
    }
}
