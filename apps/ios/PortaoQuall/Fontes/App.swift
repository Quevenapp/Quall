import SwiftUI
import UIKit

/// Portão do M3: prova que o Xcode 26.5 compila com alvo iOS 15.0 e instala num iPhone 7.
/// Ele imprime o que só se sabe em execução — versão do sistema e memória disponível ao processo.
@main
struct PortaoQuallApp: App {
    var body: some Scene {
        WindowGroup { Tela() }
    }
}

struct Tela: View {
    @State private var giro = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Portão Quall").font(.largeTitle).bold()
            Text("iOS \(UIDevice.current.systemVersion)")
            Text("modelo \(UIDevice.current.model)")
            Text("memória física \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))")
            Text("alvo de compilação 15.0")
        }
        .padding()
        .onAppear {
            NSLog("QUALL-PORTAO ios=%@ modelo=%@ memoria=%llu",
                  UIDevice.current.systemVersion,
                  UIDevice.current.model,
                  ProcessInfo.processInfo.physicalMemory)

            // Degrau 1: um alvo de breakpoint que volta sozinho, para o lldb poder chegar
            // depois do lançamento e ainda assim pegar a função em execução.
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                giro += 1
                _ = provaDeDepuracao(giro: giro)
            }
        }
    }
}
