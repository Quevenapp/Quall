import Foundation
import QuallCaptureKit

/// **A bancada dos ajustes da câmera** (R9, `docs/controles-de-camera.md` §5), sem toque: os mesmos
/// caminhos do painel e do clique na prévia, disparados por argumentos. Vale na tela R5 e na câmera
/// comum. O roteiro que a usa é `Bancada/provar-ajustes-da-camera.sh`.
///
/// - **Onde o registro mora**: com qualquer argumento (`microfoneNaRegraDaBancada`), num domínio próprio
///   (`dominio`), para uma corrida de prova não mexer no que a pessoa deixou travado no produto. Sem
///   argumento, o `UserDefaults.standard` da especificação (§2).
/// - **O que ela prova**: a leitura de volta (os modos do device), a luma média e os fps, todos no
///   diário — nenhum quadro é salvo nem aberto.
enum BancadaDosAjustesDaCamera {
    /// O domínio do registro na bancada.
    static let dominio = "br.com.queven.quall.bancada.ajustes"
    private static var limpou = false

    /// Antes de `montar`: onde o registro mora, a luma e a leitura de volta no relato de 10 s.
    static func configurar(_ d: DonoDaCamera, _ a: Argumentos) {
        guard a.microfoneNaRegraDaBancada else { return }
        if a.cameraAjustesLimpos && !limpou {
            limpou = true
            UserDefaults.standard.removePersistentDomain(forName: dominio)
            Registro.compartilhado.linha("APP CAMERA bancada: registro dos ajustes limpo (\(dominio))")
        }
        if let ud = UserDefaults(suiteName: dominio) { d.guardaDosAjustes = GuardaDosAjustes(ud) }
        d.lumaMedia = a.lumaMedia
        d.lerAjustesNoRelato = true
    }

    /// Depois de `montar` e `ligar`: o clique e os ajustes agendados.
    static func agendar(_ d: DonoDaCamera, _ a: Argumentos, depois: @escaping (Double, @escaping () -> Void) -> Void) {
        guard a.modoDeBancada else { return }
        if let texto = a.cameraPonto {
            let partes = texto.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if partes.count == 2 {
                let p = CGPoint(x: partes[0], y: partes[1])
                let apos = a.cameraPontoApos ?? 4
                let travar = a.cameraPontoTravar
                Registro.compartilhado.linha("APP CAMERA bancada: \(travar ? "⌥-clique" : "clique") em \(texto) daqui a \(apos) s")
                depois(apos) { [weak d] in
                    d?.cliqueNaPrevia(p, travarAli: travar, origem: "bancada --camera-ponto")
                }
            } else {
                Registro.compartilhado.linha("APP CAMERA bancada: --camera-ponto=\(texto) não é x,y — ignorado")
            }
        }
        if let lista = a.cameraAjustes {
            let apos = a.cameraAjustesApos ?? 6
            Registro.compartilhado.linha("APP CAMERA bancada: ajustes \"\(lista)\" daqui a \(apos) s")
            depois(apos) { [weak d] in
                guard let d else { return }
                let itens = Set(lista.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                if itens.contains("restaurar") {
                    d.restaurarAutomatico(origem: "bancada --camera-ajustes")
                    return
                }
                var novo = d.ajustes
                novo.travaExposicao = itens.contains("trava-exposicao")
                novo.travaBalanco = itens.contains("trava-balanco")
                novo.foco = itens.contains("trava-foco") ? .travado : .auto
                d.mudarAjustes(novo, origem: "bancada --camera-ajustes")
            }
        }
    }
}
