import SwiftUI
import UIKit
import ReplayKit

/// App hospedeiro do degrau 2. Ele não é o produto: existe para carregar a appex até o aparelho,
/// dar um seletor de transmissão para o sistema criar a extension, e servir de carteiro do
/// diário que a extension escreve no App Group.
@main
struct PortaoAppexApp: App {
    var body: some Scene {
        WindowGroup { Tela() }
    }
}

let idDaExtension = "br.com.queven.quall.broadcast"

struct Tela: View {
    @State private var diario = ""
    @State private var recado = ""
    /// Durante a corrida do degrau 4 a interface some e dá lugar ao `Agitador`. Ver lá o porquê:
    /// tela parada mede uma pergunta mais fácil que a verdadeira.
    @State private var agitar = false

    var body: some View {
        if agitar {
            TelaAgitada().ignoresSafeArea().onAppear { Diario.anotar("APP agitador de pé") }
        } else {
            painel
        }
    }

    private var painel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Portão da appex").font(.title2).bold()
            Text("app \(Bundle.main.bundleIdentifier ?? "?")").font(.caption)
            Text("appex \(idDaExtension)").font(.caption)
            Text(Diario.pastaDoGrupo == nil ? "APP GROUP: NÃO" : "APP GROUP: SIM").font(.caption).bold()

            SeletorDeTransmissao().frame(width: 200, height: 70)

            HStack {
                Button("Abrir seletor") { tocarNoSeletor() }
                Button("Atualizar") { atualizar() }
                Button("Zerar") { Diario.zerar(); atualizar() }
            }
            .buttonStyle(.bordered)

            Text(recado).font(.caption2)
            ScrollView {
                Text(diario.isEmpty ? "(diário vazio)" : diario)
                    .font(.system(size: 9, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onAppear {
            // Diário limpo por corrida, **antes** de a tela ler o arquivo: ver
            // `Degrau4.haPlanoPendente`. Um diário acumulado renderizado num `Text` só fez a
            // pegada do app parecer custo do núcleo.
            if Degrau4.haPlanoPendente { Diario.zerar() }
            Diario.anotar("APP aberto \(Sistema.descricao)"
                + " memoria_disponivel=\(Diario.memoriaDisponivel)"
                + " pegada=\(Diario.pegadaEmBytes)")
            #if COM_NUCLEO
            ProvaDoNucleo.rodar()
            #endif
            atualizar()
            Sonda.talvezSondar()
            SondaDeAtividade.talvezSondar()
            // O agitador entra quando a **extension** avisa que a transmissão começou, e não
            // num prazo fixo: um prazo seria palpite sobre o tempo de reação de uma pessoa, e
            // erraria justamente quando ela demorasse — trocando a hierarquia de vistas com a
            // folha do seletor ainda aberta e o `RPSystemBroadcastPickerView` no ar.
            if Degrau4.talvezPreparar() {
                Diario.marcarTransmissao(false)
                esperarATransmissaoComecar()
            }
        }
    }

    /// Vigia a bandeira que a extension põe no App Group ao começar a transmitir.
    private func esperarATransmissaoComecar() {
        let vigia = Timer(timeInterval: 1.0, repeats: true) { relogio in
            guard Diario.transmitindo else { return }
            relogio.invalidate()
            DispatchQueue.main.async {
                Diario.anotar("APP transmissão detectada — trocando pela tela agitada")
                agitar = true
            }
        }
        RunLoop.main.add(vigia, forMode: .common)
    }

    /// Copia o diário do App Group para o `Documents` do app, que é a única pasta que o
    /// `ios-deploy --download` alcança. O container do App Group não é servido pelo house arrest.
    private func atualizar() {
        diario = Diario.ler()
        let destino = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("difusao.log")
        do {
            try Data(diario.utf8).write(to: destino, options: .atomic)
            recado = "copiado para Documents/difusao.log (\(diario.utf8.count) bytes)"
        } catch {
            recado = "falhou a cópia: \(error)"
        }
    }

    /// O seletor do sistema é um `RPSystemBroadcastPickerView` com um `UIButton` dentro.
    /// Disparar o botão só abre a folha do sistema — quem toca em "Iniciar transmissão"
    /// ainda é uma pessoa. Isto poupa um toque, não os dois.
    private func tocarNoSeletor() {
        guard let janela = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first else { return }
        if let botao = procurarBotao(janela) {
            botao.sendActions(for: .touchUpInside)
            recado = "seletor aberto por código"
        } else {
            recado = "não achei o botão do seletor"
        }
    }

    private func procurarBotao(_ vista: UIView) -> UIButton? {
        if vista is RPSystemBroadcastPickerView {
            for filha in vista.subviews { if let b = filha as? UIButton { return b } }
        }
        for filha in vista.subviews {
            if let achado = procurarBotao(filha) { return achado }
        }
        return nil
    }
}

struct SeletorDeTransmissao: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let vista = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 200, height: 70))
        vista.preferredExtension = idDaExtension
        vista.showsMicrophoneButton = false
        return vista
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
