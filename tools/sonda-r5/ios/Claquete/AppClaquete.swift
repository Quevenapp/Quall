import SwiftUI
import UIKit
import AVFoundation
import QuartzCore

/// S-C1 (`docs/teleprompter-com-camera.md` §8 G4 e §8.1): a claquete do iPad.
///
/// A cada `intervaloS` (padrão 2 s) um **clarão branco em tela cheia** e um **bipe sintético de
/// 3150 Hz** no mesmo instante programado. Cada evento leva um deslocamento sorteado de uma
/// semente impressa, **0 ou +40 ms** (o bipe atrasado em relação ao clarão), que é o controle 1 do
/// `som-no-receptor.md` §9.3: a diferença entre as classes tem de dar 40 ms.
///
/// **A classe também vai na imagem**: o clarão dura 100 ms na classe 0 e 200 ms na classe +40.
/// Assim o analisador sabe a classe de cada evento pelo vídeo sozinho — sem usar o som, o que
/// tornaria o controle circular — e confere a sequência contra a semente.
///
/// Argumentos (`NSArgumentDomain`):
///   -semente <u64>  -intervaloS 2  -eventos 150  -bipeMs 50  -compensar 1  -auto 1
@main
struct AppClaquete: App {
    var body: some Scene {
        WindowGroup {
            Representavel()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct Representavel: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ControladorDaClaquete { ControladorDaClaquete() }
    func updateUIViewController(_ c: ControladorDaClaquete, context: Context) {}
}

/// O gerador da semente, idêntico ao `splitmix64` de `tools/sonda-r5/claquete/analisar.py`.
struct SplitMix64 {
    var estado: UInt64
    mutating func proximo() -> UInt64 {
        estado &+= 0x9E37_79B9_7F4A_7C15
        var z = estado
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class ControladorDaClaquete: UIViewController {
    // parâmetros
    private let padrao = UserDefaults.standard
    private var semente: UInt64 = 0
    private var intervaloS = 2.0
    private var totalDeEventos = 150
    private var bipeMs = 50.0
    private let bipeHz = 3150.0
    private let rampaMs = 2.0
    private let claraoMsClasse0 = 100.0
    private let claraoMsClasse40 = 200.0
    private var compensar = true

    // estado
    private struct Evento {
        var i: Int
        var classeMs: Double
        var tProgramado: Double
        var tBipeAgendado = -1.0
        var margemDeAgendamento = -1.0
        var tClaraoAlvo = -1.0
        var tClaraoCallback = -1.0
        var tApagadoAlvo = -1.0
        var atrasado = false
    }
    private var eventos: [Evento] = []
    private var proximoAgendar = 0
    private var proximoClarao = 0
    private var aceso = false
    private var apagarEm = 0.0
    private var rodando = false
    private var t0 = 0.0

    private let motor = AVAudioEngine()
    private let tocador = AVAudioPlayerNode()
    private var bipe: AVAudioPCMBuffer?
    private var latenciaDeSaida = 0.0
    private var elo: CADisplayLink?
    private var relogio: Timer?
    private let rotulo = UILabel()
    private var urlRelato: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        rotulo.textColor = UIColor(white: 0.35, alpha: 1)
        rotulo.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        rotulo.numberOfLines = 0
        rotulo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rotulo)
        NSLayoutConstraint.activate([
            rotulo.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            rotulo.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            rotulo.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
        ])
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toque)))
        view.addGestureRecognizer(UILongPressGestureRecognizer(target: self,
                                                               action: #selector(toqueLongo(_:))))
        lerParametros()
        rotulo.text = "Claquete R5 · S-C1\nsemente \(semente)\n"
            + "\(totalDeEventos) eventos a cada \(intervaloS) s, bipe \(Int(bipeMs)) ms a 3150 Hz\n"
            + "toque para começar · toque longo para parar"
        if padrao.bool(forKey: "auto") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.comecar() }
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private func lerParametros() {
        if let s = padrao.string(forKey: "semente"), let v = UInt64(s) {
            semente = v
        } else {
            semente = UInt64.random(in: 1...UInt64(UInt32.max))
        }
        if padrao.object(forKey: "intervaloS") != nil { intervaloS = padrao.double(forKey: "intervaloS") }
        if padrao.object(forKey: "eventos") != nil { totalDeEventos = padrao.integer(forKey: "eventos") }
        if padrao.object(forKey: "bipeMs") != nil { bipeMs = padrao.double(forKey: "bipeMs") }
        if padrao.object(forKey: "compensar") != nil { compensar = padrao.bool(forKey: "compensar") }
    }

    @objc private func toque() { if !rodando { comecar() } }

    @objc private func toqueLongo(_ g: UILongPressGestureRecognizer) {
        if g.state == .began && rodando { terminar(motivo: "toque longo") }
    }

    // MARK: - som

    private func prepararSom() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [])
        try? s.setPreferredSampleRate(48_000)
        try s.setActive(true)
        let formato = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        motor.attach(tocador)
        motor.connect(tocador, to: motor.mainMixerNode, format: formato)
        let n = AVAudioFrameCount(48_000 * bipeMs / 1000)
        guard let b = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: n) else { return }
        b.frameLength = n
        let rampa = Int(48_000 * rampaMs / 1000)
        let p = b.floatChannelData![0]
        for k in 0..<Int(n) {
            var env = 1.0
            if k < rampa { env = 0.5 - 0.5 * cos(Double.pi * Double(k) / Double(rampa)) }
            let fim = Int(n) - 1 - k
            if fim < rampa { env = 0.5 - 0.5 * cos(Double.pi * Double(fim) / Double(rampa)) }
            p[k] = Float(0.9 * env * sin(2 * Double.pi * bipeHz * Double(k) / 48_000))
        }
        bipe = b
        try motor.start()
        tocador.play()
        latenciaDeSaida = s.outputLatency
    }

    // MARK: - corrida

    private func comecar() {
        do { try prepararSom() } catch {
            rotulo.text = "o som não abriu: \(error)"
            return
        }
        var g = SplitMix64(estado: semente)
        t0 = CACurrentMediaTime() + 3.0
        eventos = (0..<totalDeEventos).map { i in
            let classe = (g.proximo() >> 63) == 1 ? 40.0 : 0.0
            return Evento(i: i, classeMs: classe, tProgramado: t0 + Double(i) * intervaloS)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        urlRelato = docs.appendingPathComponent("claquete-\(f.string(from: Date()))-\(semente).json")
        rodando = true
        UIApplication.shared.isIdleTimerDisabled = true
        rotulo.text = "semente \(semente)"
        let e = CADisplayLink(target: self, selector: #selector(quadro(_:)))
        if #available(iOS 15.0, *) {
            let m = Float(UIScreen.main.maximumFramesPerSecond)
            e.preferredFrameRateRange = CAFrameRateRange(minimum: m, maximum: m, preferred: m)
        }
        e.add(to: .main, forMode: .common)
        elo = e
        relogio = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.agendarSom()
        }
        agendarSom()
    }

    /// Agenda o bipe de cada evento que cai no próximo 1,5 s, pelo relógio de host.
    /// `compensar` tira a latência de saída que a sessão de áudio declara; o resto (o que a sessão
    /// não declara, e o alto-falante) é o viés que a calibração mede.
    private func agendarSom() {
        guard rodando, let bipe = bipe else { return }
        let agora = CACurrentMediaTime()
        while proximoAgendar < eventos.count {
            var ev = eventos[proximoAgendar]
            let alvo = ev.tProgramado + ev.classeMs / 1000 - (compensar ? latenciaDeSaida : 0)
            if alvo > agora + 1.5 { break }
            ev.tBipeAgendado = alvo
            ev.margemDeAgendamento = alvo - agora
            if alvo - agora < 0.05 { ev.atrasado = true }
            let quando = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: alvo))
            tocador.scheduleBuffer(bipe, at: quando, options: [], completionHandler: nil)
            eventos[proximoAgendar] = ev
            proximoAgendar += 1
        }
    }

    /// O clarão acende no quadro cujo `targetTimestamp` é o primeiro a meio período ou menos do
    /// instante programado, e apaga do mesmo jeito. O que a tela faz depois do `targetTimestamp`
    /// (composição, painel) é parte do viés medido, e não é corrigido aqui.
    @objc private func quadro(_ e: CADisplayLink) {
        let alvo = e.targetTimestamp
        let meio = (e.targetTimestamp - e.timestamp) / 2
        if aceso {
            if alvo >= apagarEm - meio {
                view.backgroundColor = .black
                aceso = false
                eventos[proximoClarao - 1].tApagadoAlvo = alvo
                if proximoClarao >= eventos.count { terminar(motivo: "fim dos eventos"); return }
                if proximoClarao % 10 == 0 { gravarRelato(final: false) }
            }
            return
        }
        guard proximoClarao < eventos.count else { return }
        var ev = eventos[proximoClarao]
        if alvo >= ev.tProgramado - meio {
            view.backgroundColor = .white
            aceso = true
            ev.tClaraoAlvo = alvo
            ev.tClaraoCallback = e.timestamp
            if alvo > ev.tProgramado + meio { ev.atrasado = true }
            apagarEm = ev.tProgramado + (ev.classeMs > 0 ? claraoMsClasse40 : claraoMsClasse0) / 1000
            eventos[proximoClarao] = ev
            proximoClarao += 1
            rotulo.text = "semente \(semente) · \(proximoClarao)/\(eventos.count)"
        }
    }

    private func terminar(motivo: String) {
        rodando = false
        elo?.invalidate()
        relogio?.invalidate()
        tocador.stop()
        motor.stop()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = false
        gravarRelato(final: true, motivo: motivo)
        let atrasados = eventos.filter { $0.atrasado }.count
        let v = "VEREDITO: CLAQUETE TOCADA — \(proximoClarao) de \(eventos.count) eventos, "
            + "\(atrasados) atrasados, semente \(semente) (o viés sai do analisar.py)"
        NSLog("SONDA-R5 %@", v)
        rotulo.text = v + "\nrelato: Documents/\(urlRelato?.lastPathComponent ?? "?")"
    }

    private func gravarRelato(final: Bool, motivo: String = "") {
        guard let url = urlRelato else { return }
        let s = AVAudioSession.sharedInstance()
        var u = utsname()
        uname(&u)
        let modelo = withUnsafeBytes(of: &u.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let r: [String: Any] = [
            "sonda": "S-C1",
            "aparelho": modelo,
            "sistema": UIDevice.current.systemVersion,
            "semente": String(semente),
            "gerador": "splitmix64; classe = (proximo() >> 63) == 1 ? +40 ms : 0",
            "intervalo_s": intervaloS,
            "bipe_hz": bipeHz,
            "bipe_ms": bipeMs,
            "rampa_ms": rampaMs,
            "clarao_ms_classe0": claraoMsClasse0,
            "clarao_ms_classe40": claraoMsClasse40,
            "compensar_latencia_de_saida": compensar,
            "output_latency_s": latenciaDeSaida,
            "io_buffer_s": s.ioBufferDuration,
            "taxa_hw": s.sampleRate,
            "saidas": s.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" },
            "display_max_fps": UIScreen.main.maximumFramesPerSecond,
            "t0_s": t0,
            "final": final,
            "motivo": motivo,
            "eventos": eventos.map { e -> [String: Any] in
                [
                    "i": e.i, "classe_ms": e.classeMs, "t_programado_s": e.tProgramado,
                    "t_bipe_agendado_s": e.tBipeAgendado,
                    "margem_agendamento_s": e.margemDeAgendamento,
                    "t_clarao_alvo_s": e.tClaraoAlvo, "t_clarao_callback_s": e.tClaraoCallback,
                    "t_apagado_alvo_s": e.tApagadoAlvo, "atrasado": e.atrasado,
                ]
            },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url, options: .atomic)
        }
    }
}
