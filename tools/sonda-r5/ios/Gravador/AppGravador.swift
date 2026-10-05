import SwiftUI
import AVFoundation

/// Argumentos de lançamento (pelo `NSArgumentDomain`, então `-duracaoS 60` funciona):
///   -duracaoS <s>      duração da corrida (padrão 600)
///   -abruptoS <s>      chama exit() neste segundo (fim abrupto)
///   -modo <m>          vt_passagem (padrão) | writer_codifica
///   -auto 1            começa sozinho ao abrir, sem toque (a permissão de câmera ainda pede um)
@main
struct AppGravador: App {
    @StateObject private var sonda = Sonda()

    var body: some Scene {
        WindowGroup {
            TelaDaSonda(sonda: sonda)
        }
    }
}

struct TelaDaSonda: View {
    @ObservedObject var sonda: Sonda
    @State private var modo: Sonda.ModoGravacao = .vtPassagem
    @State private var orfaos: [String] = []
    @State private var jaAbriu = false

    private let padrao = UserDefaults.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sonda R5 · S-I1").font(.headline)
            PreviaDaCamera(sessao: sonda.sessao)
                .frame(height: 160)
                .background(Color.black)
            if !sonda.rodando {
                Picker("gravação", selection: $modo) {
                    Text("VT → writer").tag(Sonda.ModoGravacao.vtPassagem)
                    Text("writer codifica").tag(Sonda.ModoGravacao.writerCodifica)
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("Correr 10 min") { sonda.iniciar(config(abrupto: false)) }
                    Spacer()
                    Button("Fim abrupto (exit aos 5 min)") { sonda.iniciar(config(abrupto: true)) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Parar agora") { sonda.parar(motivo: "botão") }
                    .buttonStyle(.bordered)
            }
            ForEach(orfaos, id: \.self) { Text($0).font(.caption.bold()).foregroundColor(.orange) }
            if !sonda.veredito.isEmpty {
                Text(sonda.veredito).font(.caption.bold())
                    .foregroundColor(sonda.veredito.contains("PASSOU") ? .green : .red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sonda.linhas.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
        .padding()
        .onAppear {
            guard !jaAbriu else { return }
            jaAbriu = true
            DispatchQueue.global(qos: .userInitiated).async {
                let linhas = Orfao.conferirPendentes()
                DispatchQueue.main.async {
                    orfaos = linhas
                    if padrao.bool(forKey: "auto") {
                        sonda.iniciar(config(abrupto: padrao.object(forKey: "abruptoS") != nil))
                    }
                }
            }
        }
    }

    private func config(abrupto: Bool) -> Sonda.Config {
        var c = Sonda.Config()
        if let d = padrao.object(forKey: "duracaoS") { c.duracaoS = (d as? NSNumber)?.doubleValue
            ?? Double("\(d)") ?? 600 }
        if let m = padrao.string(forKey: "modo"), let mm = Sonda.ModoGravacao(rawValue: m) {
            c.modo = mm
        } else {
            c.modo = modo
        }
        if abrupto {
            let a = padrao.object(forKey: "abruptoS").flatMap { Double("\($0)") }
            c.abruptoS = a ?? c.duracaoS / 2
        }
        return c
    }
}

struct PreviaDaCamera: UIViewRepresentable {
    let sessao: AVCaptureSession

    final class Vista: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var camada: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Vista {
        let v = Vista()
        v.camada.session = sessao
        v.camada.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: Vista, context: Context) {}
}
