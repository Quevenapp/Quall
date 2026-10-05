import Foundation
import AVFoundation

/// **O roteiro de prova dos controles** (R9, `docs/controles-de-camera.md` §5), sem toque:
/// `--roteiro-dos-controles completo` aplica cada controle pelo mesmo caminho do painel
/// (`ControlesDaCamera`), espera a câmera assentar, e escreve no diário uma linha por passo com o
/// pedido, o que a câmera **diz** ter usado (prova 1), a média de luma e o fps da janela (prova 2):
///
///     APP CAMERA roteiro passo=<nome> luma=<média> n=<contas> fps=<medido> pedido=<json> lido=<linha>
///
/// Quem julga é o `provar-controles.sh`, de fora (a mesma regra do `Testes/rodar.sh`: o programa
/// que produz não é a testemunha). Os passos, em ordem: a base; o EV nos dois sentidos; o ISO baixo
/// e alto com o obturador fixo; o obturador curto e no teto de 1/fps com o ISO fixo; três Kelvin;
/// o foco no perto e no longe; as três travas; o degrau forçado (`reduzirCaptura`) e a volta (prova
/// 3, a sobrevivência). O completo **termina com as travas de pé**, de propósito: o roteiro reabre o
/// app com `--roteiro-dos-controles reabertura`, que mede a trava depois de fechar e reabrir e só
/// então restaura o automático.
///
/// Precisa de `--luma-media` junto (sem ela, `luma=?`). **A câmera filma a sala**: quem roda é a
/// sessão principal, com o sim do Pessoa Exemplo. Nenhum quadro é salvo nem aberto: só números.
final class RoteiroDosControles {
    private weak var dono: DonoDaCaptura?
    private let modo: String
    /// Segundos para a câmera assentar depois de cada pedido, e da janela de medida.
    private let assentar: Double = 2.0
    private let medir: Double = 3.0

    private typealias Passo = (nome: String, fazer: (ControlesDaCamera, FaixasDaCamera) -> Void)

    init(dono: DonoDaCaptura, modo: String) {
        self.dono = dono
        self.modo = modo
    }

    func comecar() {
        let passos = modo == "reabertura" ? passosDaReabertura() : passosCompletos()
        // A tela e o que a câmera declara: o veredito decide por eles o que "não se aplica" (a frontal
        // de foco fixo, a câmera sem ganhos manuais), em vez de reprovar o que não existe.
        let capacidades = (dono?.entrada?.device).map(AjustesNaCamera.linhaDasCapacidades) ?? "?"
        Diagnostico.nota("APP CAMERA roteiro começa: modo=\(modo) tela=\(dono?.controles.tela ?? "?")"
            + " capacidades=\(capacidades) passos=\(passos.map(\.nome).joined(separator: ","))")
        // Três segundos para a primeira aplicação e o 3A assentarem.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in rodar(passos, 0) }
    }

    private func rodar(_ passos: [Passo], _ i: Int) {
        guard let dono, dono.montado else {
            Diagnostico.nota("APP CAMERA roteiro parou: a câmera fechou")
            return
        }
        guard i < passos.count else {
            Diagnostico.nota("APP CAMERA roteiro fim: modo=\(modo)"
                + (modo == "reabertura" ? " (automático restaurado)" : " (travas de pé, para a reabertura)"))
            return
        }
        let p = passos[i]
        let faixas = (dono.entrada?.device).map(AjustesNaCamera.faixas) ?? .vazia
        p.fazer(dono.controles, faixas)
        DispatchQueue.main.asyncAfter(deadline: .now() + assentar) { [self] in
            guard let dono = self.dono else { return }
            _ = dono.janelaDeLuma()
            let q0 = dono.quadrosQueEntraram
            let t0 = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + medir) { [self] in
                guard let dono = self.dono else { return }
                let (luma, n) = dono.janelaDeLuma()
                let fps = Double(dono.quadrosQueEntraram &- q0) / max(0.001, CFAbsoluteTimeGetCurrent() - t0)
                let pedido = String(data: dono.controles.registro.json() ?? Data(), encoding: .utf8) ?? "?"
                dono.fila.async { [self] in
                    let lido = (dono.entrada?.device).map(AjustesNaCamera.linhaLida) ?? "sem câmera"
                    Diagnostico.nota("APP CAMERA roteiro passo=\(p.nome)"
                        + " luma=\(luma.map { String(format: "%.1f", $0) } ?? "?") n=\(n)"
                        + String(format: " fps=%.1f", fps)
                        + " pedido=\(pedido) lido=\(lido)")
                    DispatchQueue.main.async { [self] in rodar(passos, i + 1) }
                }
            }
        }
    }

    private func passosCompletos() -> [Passo] {
        typealias R = RegrasDosControles
        func manual(_ c: ControlesDaCamera, iso: Double, ns: Int64) {
            c.mudar([.exposicao]) { $0.exposicao = .manual; $0.iso = iso; $0.obturadorNs = ns; $0.travaExposicao = false }
        }
        let lista: [Passo] = [
            ("base", { c, _ in c.restaurar() }),
            ("ev-menos", { c, f in c.mudar([.exposicao]) { $0.ev = R.arredondarEv(-2, minimo: f.evMin, maximo: f.evMax) } }),
            ("ev-mais", { c, f in c.mudar([.exposicao]) { $0.ev = R.arredondarEv(2, minimo: f.evMin, maximo: f.evMax) } }),
            // O ISO com o obturador fixo em 1/120 (cortado pela faixa e pelo teto).
            ("iso-baixo", { c, f in
                manual(c, iso: f.isoMin, ns: R.cortarObturador(R.nsDaFracao(120), minimoNs: f.obturadorMinNs,
                                                               maximoNs: f.obturadorMaxNs, fps: f.fps)) }),
            ("iso-alto", { c, f in
                manual(c, iso: R.cortarIso(f.isoMin * 4, minimo: f.isoMin, maximo: f.isoMax),
                       ns: R.cortarObturador(R.nsDaFracao(120), minimoNs: f.obturadorMinNs,
                                             maximoNs: f.obturadorMaxNs, fps: f.fps)) }),
            // O obturador com o ISO fixo no dobro do mínimo: curto (1/1000) e no teto (1/fps), onde o
            // fps que chega não pode cair.
            ("obturador-curto", { c, f in
                manual(c, iso: R.cortarIso(f.isoMin * 2, minimo: f.isoMin, maximo: f.isoMax),
                       ns: R.cortarObturador(R.nsDaFracao(1000), minimoNs: f.obturadorMinNs,
                                             maximoNs: f.obturadorMaxNs, fps: f.fps)) }),
            ("obturador-teto", { c, f in
                manual(c, iso: R.cortarIso(f.isoMin * 2, minimo: f.isoMin, maximo: f.isoMax),
                       ns: R.tetoDoObturadorNs(fps: f.fps, maximoNs: f.obturadorMaxNs)) }),
            ("kelvin-3000", { c, _ in
                c.mudar([.exposicao, .balanco]) { $0.exposicao = .auto; $0.ev = 0; $0.balanco = .kelvin; $0.kelvin = 3000 } }),
            ("kelvin-7500", { c, _ in c.mudar([.balanco]) { $0.balanco = .kelvin; $0.kelvin = 7500 } }),
            ("preset-nublado", { c, _ in c.mudar([.balanco]) { $0.balanco = .nublado } }),
            ("foco-perto", { c, _ in c.mudar([.balanco, .foco]) { $0.balanco = .auto; $0.foco = .manual; $0.focoPosicao = 1 } }),
            ("foco-longe", { c, _ in c.mudar([.foco]) { $0.foco = .manual; $0.focoPosicao = 0 } }),
            // As três travas, guardando o que a câmera estava usando (§2.1). O foco volta ao auto
            // antes, para a trava guardar uma posição medida, e não a do passo anterior.
            ("travas", { c, _ in
                c.mudar([.foco]) { $0.foco = .auto }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    c.travarExposicao(true)
                    c.travarBalanco(true)
                    c.escolherFoco(.travado)
                } }),
            // O degrau de calor, forçado (§5.3): a captura troca de formato e a trava tem de voltar.
            // Na R5 o degrau é da tela (prévia pausada e captura em 720p), e a sonda confere que a
            // prévia pausada não gera ponto.
            ("degrau", { c, _ in
                c.degrauForcado(true)
                if c.tela == "r5" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { c.pedirSonda("degrau (prévia pausada)") }
                } }),
            ("degrau-volta", { c, _ in c.degrauForcado(false) }),
        ]
        return tela == "r5" ? passosDaR5(antesDasTravas: lista) : lista
    }

    /// A tela do dono ("camera" ou "r5"), lida na principal.
    private var tela: String { dono?.controles.tela ?? "camera" }

    /// **Na R5**, antes das travas: a sonda do toque com o painel fechado, o painel aberto (a tela
    /// escreve os quadros dele no diário) e a sonda de novo com ele aberto, e o painel fechado. A sonda
    /// "toca" no centro do texto e da prévia pelo `hitTest` da janela: ela prova onde o toque cai, e
    /// o "toque" na prévia corre pelo mesmo caminho do dedo até `captureDevicePointConverted`.
    private func passosDaR5(antesDasTravas lista: [Passo]) -> [Passo] {
        guard let i = lista.firstIndex(where: { $0.nome == "travas" }) else { return lista }
        let extras: [Passo] = [
            ("sonda-do-toque", { c, _ in c.pedirSonda("painel fechado") }),
            ("painel-aberto", { c, _ in
                c.pedirPainel(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.pedirSonda("painel aberto") } }),
            ("painel-fechado", { c, _ in c.pedirPainel(false) }),
        ]
        return Array(lista[..<i]) + extras + Array(lista[i...])
    }

    private func passosDaReabertura() -> [Passo] {
        [
            ("reaberta", { _, _ in }),
            ("restaurado", { c, _ in c.restaurar() }),
        ]
    }
}

extension DonoDaCaptura {
    /// Os argumentos de bancada do R9 que agem depois de a câmera montar (`BancadaDosControles`):
    /// o degrau forçado e o roteiro de prova. Na principal.
    func agendarBancadaDosControles() {
        let b = BancadaDosControles.opcoes
        if let apos = b.degrauForcadoApos {
            let por = b.degrauForcadoPor
            Diagnostico.nota("APP CAMERA bancada: --degrau-forcado em \(apos) s, volta \(por) s depois")
            // Pelo caminho da tela (na R5 o degrau é dela; ver `ControlesDaCamera.forcarDegrau`).
            DispatchQueue.main.asyncAfter(deadline: .now() + apos) { [weak self] in
                guard let self, self.montado else { return }
                self.controles.degrauForcado(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + por) { [weak self] in
                    guard let self, self.montado else { return }
                    self.controles.degrauForcado(false)
                }
            }
        }
        if let modo = b.roteiro {
            guard modo == "completo" || modo == "reabertura" else {
                Diagnostico.nota("APP CAMERA bancada: --roteiro-dos-controles \(modo) desconhecido (completo|reabertura)")
                return
            }
            // O roteiro se segura pelos próprios fechos agendados, e morre com o último passo.
            RoteiroDosControles(dono: self, modo: modo).comecar()
        }
    }
}
