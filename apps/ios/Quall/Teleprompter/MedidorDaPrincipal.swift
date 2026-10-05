import Foundation

/// **Quanto a thread principal ficou presa** (§8.12.10): uma fila de fundo manda **um** bloco à
/// principal de cada vez, a cada 50 ms, e mede quanto ele demorou a correr; enquanto ele não volta,
/// não manda outro (a revisão de 27/09 viu a soma inflar quadraticamente com um bloco por tique). No
/// fim, o atraso maior e a soma dos atrasos acima de 50 ms, a quem pediu, na principal.
enum MedidorDaPrincipal {
    static func medir(por segundos: Double, fim: @escaping (_ maior: Double, _ soma: Double) -> Void) {
        let fila = DispatchQueue(label: "br.com.queven.quall.medidor-da-principal", qos: .utility)
        // Tudo abaixo só na `fila`.
        var maior = 0.0, soma = 0.0, emVoo = false
        let inicio = CFAbsoluteTimeGetCurrent()
        let t = DispatchSource.makeTimerSource(queue: fila)
        t.schedule(deadline: .now(), repeating: 0.05)
        t.setEventHandler {
            let enviado = CFAbsoluteTimeGetCurrent()
            guard enviado - inicio < segundos else {
                guard !emVoo else { return }
                t.cancel()
                let (m, s) = (maior, soma)
                DispatchQueue.main.async { fim(m, s) }
                return
            }
            guard !emVoo else { return }
            emVoo = true
            DispatchQueue.main.async {
                let atraso = CFAbsoluteTimeGetCurrent() - enviado
                fila.async {
                    maior = max(maior, atraso)
                    if atraso > 0.05 { soma += atraso }
                    emVoo = false
                }
            }
        }
        t.resume()
    }
}
