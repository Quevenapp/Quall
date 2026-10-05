import CQuall
import Foundation
import QuallCaptureKit
import QuallNetKit

/// **`quall-net-smoke camera-remota`**: o controle remoto da câmera (R9b) pelas peças do Mac, numa sessão de
/// vídeo de verdade por 127.0.0.1 — **sem câmera nenhuma**. O filmador é o `FilmadorDaCameraRemota` com as
/// capacidades e o registro que o `DonoDaCamera` publicaria (`CapacidadesDaCamera.jsonRemoto`, o
/// `AjustesDaCamera` do R9) e a casca de mentira aplica os pedidos com o mesmo puro do dono
/// (`PedidoDaCameraRemota.aplicar`); o receptor é o `ControleDaCameraRemota`, lido pelo
/// `EstadoDaCameraRemota` e pelo `PlanoRemotoDoPainel` que a janela do receptor desenha.
///
/// Prova o caminho de mensagens das cascas do Mac — a bombeada nos dois lados, o `(buf, cap)`, o consumidor
/// único, `set_settings(n)` e `reject` —, e não a câmera nem a travessia por rádio.
///
///     quall-net-smoke camera-remota [--porta 17899]
func provaDaCameraRemota(_ args: [String]) -> Int32 {
    var porta: UInt16 = 17899
    if let i = args.firstIndex(of: "--porta"), i + 1 < args.count { porta = UInt16(args[i + 1]) ?? porta }
    let pin = "314159"

    let caps = CapacidadesDaCamera(
        exposicaoContinua: true, exposicaoUmaVez: true, exposicaoTravada: true, pontoDeExposicao: true,
        balancoContinuo: true, balancoUmaVez: true, balancoTravado: true,
        focoContinuo: true, focoUmaVez: true, focoTravado: true, pontoDeFoco: true)
    guard let filmador = FilmadorDaCameraRemota(), let controle = ControleDaCameraRemota() else {
        print("ERRO: o núcleo não criou o filmador ou o controle")
        return 1
    }
    /// O registro da "câmera", tocado pela casca de mentira e pela mudança local do passo 8.
    final class Registro: @unchecked Sendable {
        private let trava = NSLock()
        private var _a = AjustesDaCamera.padrao
        var a: AjustesDaCamera {
            get { trava.lock(); defer { trava.unlock() }; return _a }
            set { trava.lock(); _a = newValue; trava.unlock() }
        }
    }
    let registro = Registro()
    let capsJson = caps.jsonRemoto(nomeDaCamera: "Câmera de prova (sintética)")
    print("capacidades=\(capsJson)")
    print("set_camera=\(filmador.definirCamera(capacidades: capsJson, ajuste: registro.a.json).rawValue) (permissão desligada: o padrão)")

    let emissor = NucleoDeRede()
    let receptor = NucleoReceptor()
    let travaDoFim = NSLock()
    var fim = false
    func acabou() -> Bool { travaDoFim.lock(); defer { travaDoFim.unlock() }; return fim }
    var aplicados = 0, recusados = 0
    /// A fila serial do "dono": a mudança local (passo 8) entra por ela, como no app entra pela principal.
    var tarefasDoFilmador: [() -> Void] = []
    func noFilmador(_ f: @escaping () -> Void) { travaDoFim.lock(); tarefasDoFilmador.append(f); travaDoFim.unlock() }
    func quantosAplicados() -> Int { travaDoFim.lock(); defer { travaDoFim.unlock() }; return aplicados }

    // O filmador: hospeda e bombeia na thread dele, e é o consumidor único dos pedidos.
    let filmadorAcabou = DispatchSemaphore(value: 0)
    let t = Thread {
        defer { filmadorAcabou.signal() }
        let subiu = emissor.hospedar(pin: pin, porta: porta, deviceId: "smoke-filmador", nome: "Filmador de prova",
                                     tracksPedidas: [.init(tipo: QUALL_TRACK_KIND_CAMERA, rotulo: "camera-sintetica")],
                                     paresConhecidos: nil, prazoMs: 20_000)
        guard subiu, let m = emissor.mensagens() else {
            print("ERRO ao hospedar: status=\(emissor.ultimoStatusDeFalha.rawValue)")
            return
        }
        while !acabou() {
            travaDoFim.lock(); let tarefas = tarefasDoFilmador; tarefasDoFilmador = []; travaDoFim.unlock()
            tarefas.forEach { $0() }
            _ = emissor.proximoEvento()
            let b = filmador.bombear(m, prazoMs: 20)
            if b.mudou & FilmadorDaCameraRemota.bitDoPedido != 0 {
                while let json = filmador.proximoPedido() {
                    guard let p = PedidoDaCameraRemota.ler(json) else { continue }
                    switch p.aplicar(sobre: registro.a, caps, pilulaAcesa: false) {
                    case .aplicar(let novo, _, _, _):
                        registro.a = novo
                        let st = filmador.definirAjuste(novo.json, pedido: p.n)
                        travaDoFim.lock(); aplicados += 1; travaDoFim.unlock()
                        print("  filmador: pedido \(p.n) aplicado → \(novo.json) (set_settings=\(st.rawValue))")
                    case .recusar(let motivo):
                        filmador.recusar(p.n, motivo: motivo)
                        recusados += 1
                        print("  filmador: pedido \(p.n) recusado (\(motivo))")
                    }
                }
            }
            if b.acabou { break }
        }
        _ = filmador.bombear(m, prazoMs: 0)
        filmador.esquecer(m)
    }
    t.start()
    Thread.sleep(forTimeInterval: 0.5)

    guard receptor.conectar(endereco: "127.0.0.1:\(porta)", pin: pin, deviceId: "smoke-receptor",
                            nome: "Receptor de prova", paresConhecidos: nil, prazoMs: 20_000),
          let m = receptor.mensagens() else {
        print("ERRO ao conectar: status=\(receptor.ultimoStatus.rawValue)")
        travaDoFim.lock(); fim = true; travaDoFim.unlock()
        return 1
    }
    print("conectado em 127.0.0.1:\(porta)")

    var ultimo = EstadoDaCameraRemota()
    /// Bombeia o receptor até `condicao` valer, ou `prazo` segundos.
    func esperar(_ passo: String, prazo: Double = 8, _ condicao: (EstadoDaCameraRemota) -> Bool) -> Bool {
        let limite = Date().addingTimeInterval(prazo)
        while Date() < limite {
            _ = receptor.evento(prazoMs: 0)
            _ = controle.bombear(m, prazoMs: 50)
            if let e = EstadoDaCameraRemota.ler(controle.estadoJson()) {
                ultimo = e
                if condicao(e) {
                    print("OK  \(passo)")
                    return true
                }
            }
        }
        print("FALHOU  \(passo) — situação \(ultimo.situacao), ajuste \(ultimo.ajuste)")
        return false
    }
    func plano(_ e: EstadoDaCameraRemota) -> String {
        guard let p = PlanoRemotoDoPainel.de(e) else { return "sem painel" }
        return "aviso=\(p.aviso ?? "-") travaExposicao=\(p.travaExposicao?.ligado == true) "
            + "foco=\(p.foco.first { $0.escolhida }?.valor ?? "-") toque=\(p.toqueDisponivel)"
    }

    var ok = true
    ok = esperar("1. a opção desligada chega: nao_permitido, com os valores") {
        $0.situacao == "nao_permitido" && $0.capacidades?.plataforma == "macos"
    } && ok
    print("    painel: \(plano(ultimo))")
    filmador.permitir(true)
    ok = esperar("2. a opção ligada: pronto") { $0.situacao == "pronto" } && ok

    let st1 = controle.pedir(#"{"travaExposicao":true}"#)
    print("    pedir travaExposicao = \(st1.rawValue)")
    ok = esperar("3. o pedido volta aplicado, com o autor") {
        $0.ajuste.travaExposicao == true && $0.autor == "Receptor de prova"
    } && ok
    let estadoDoFilmador = (try? JSONSerialization.jsonObject(with: Data(filmador.estadoJson().utf8))) as? [String: Any]
    let controladoPor = (estadoDoFilmador?["controlado_por"] as? [String: Any])?["nome"] as? String
    print("    filmador: controlado_por_presente=\(controladoPor != nil) — o \"Controlado por\" do Mac que filma")
    ok = controladoPor == "Receptor de prova" && ok

    let st2 = controle.pedir(#"{"foco":"manual"}"#)
    print("    pedir foco=manual (o Mac não anuncia) = \(st2.rawValue) — esperado INVALID (\(QUALL_STATUS_INVALID.rawValue)), sem rede")
    ok = st2 == QUALL_STATUS_INVALID && ok

    let st3 = controle.tocar(x: 0.25, y: 0.75, longo: true)
    print("    toque longo 0,25 × 0,75 = \(st3.rawValue)")
    ok = esperar("4. o toque longo trava foco e exposição ali") { $0.ajuste.foco == "travado" } && ok

    filmador.permitir(false)
    ok = esperar("5. a opção desligada de novo: nao_permitido") { $0.situacao == "nao_permitido" } && ok
    let st4 = controle.pedir(#"{"travaBalanco":true}"#)
    print("    pedir com a opção desligada = \(st4.rawValue) — esperado INVALID")
    ok = st4 == QUALL_STATUS_INVALID && ok

    filmador.permitir(true)
    ok = esperar("6. pronto de novo") { $0.situacao == "pronto" } && ok
    _ = controle.restaurar()
    ok = esperar("7. restaurar automático, aplicado no filmador") {
        $0.ajuste.travaExposicao != true && $0.ajuste.focoEfetivo == "auto" && quantosAplicados() == 3
    } && ok

    noFilmador {
        var local = registro.a
        local.travaBalanco = true
        registro.a = local
        filmador.definirAjuste(local.json, pedido: 0)
    }
    ok = esperar("8. a mudança feita no filmador chega, sem autor") { $0.ajuste.travaBalanco == true && $0.autor == nil } && ok
    print("    painel: \(plano(ultimo))")

    print("receptor: fim")
    print("filmador: fim")
    print("aplicados=\(aplicados) recusados=\(recusados)")
    travaDoFim.lock(); fim = true; travaDoFim.unlock()
    receptor.parar()
    _ = receptor.encerrar()
    _ = filmadorAcabou.wait(timeout: .now() + 5)
    emissor.encerrar()
    print(ok ? "PROVA OK" : "PROVA FALHOU")
    return ok ? 0 : 1
}
