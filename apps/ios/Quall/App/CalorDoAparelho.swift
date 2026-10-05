import Foundation

/// **O calor do aparelho, observado** (R5 fase 5, `docs/teleprompter-com-camera.md` §8.12.1): o
/// `ProcessInfo.thermalState` pela `thermalStateDidChangeNotification`, publicado na principal para a
/// faixa (o aviso do `.critical`) e para o gravador (a gravação que começa quente sai em 720p).
///
/// A rede **não** depende disto: o laço de 1 Hz do `EmissorDeCamera` lê o estado direto, e uma
/// notificação perdida não deixa a rede no tamanho errado. Aqui fica a testemunha: uma linha no
/// diário por troca (`APP CALOR térmico: 1 (fair) → 2 (serious)`).
///
/// Só na principal.
final class CalorDoAparelho: ObservableObject {
    static let compartilhado = CalorDoAparelho()

    /// O `rawValue` de `ProcessInfo.ThermalState` (0 nominal … 3 critical).
    @Published private(set) var termico: Int

    var quente: Bool { termico >= PoliticaDeCalor.quente }
    var aviso: String? { PoliticaDeCalor.aviso(termico: termico) }

    private var observador: NSObjectProtocol?

    private init() {
        termico = ProcessInfo.processInfo.thermalState.rawValue
        observador = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reler() }
    }

    /// Relê o estado agora (a notificação, ou quem precisa decidir e não quer esperar por ela).
    func reler() {
        let novo = ProcessInfo.processInfo.thermalState.rawValue
        guard novo != termico else { return }
        Diagnostico.nota("APP CALOR térmico: \(termico) (\(PoliticaDeCalor.nome(termico))) → "
                         + "\(novo) (\(PoliticaDeCalor.nome(novo)))")
        termico = novo
    }
}
