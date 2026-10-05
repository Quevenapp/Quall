import Foundation

// Bancada do R9b iOS em 127.0.0.1, sem câmera: os embrulhos de verdade (`FilmadorRemoto`,
// `CameraRemotaDaSessao`) e as regras puras (`CapacidadesRemotas.doIOS`, `RegrasDoControleRemoto`,
// `MoldeDoPainel.remoto`) contra o núcleo de verdade, numa sessão de vídeo hospedar/conectar sem
// track. A câmera do filmador é imaginária: o registro e o lido são deste programa.

enum Compartilhado { static let grupo = "group.br.com.queven.quall.bancada" }
enum Diagnostico {
    static func nota(_ texto: @autoclosure () -> String) { print("    [filmador] " + texto()) }
    static func falha(_ texto: @autoclosure () -> String) { print("    [FALHA] " + texto()) }
}
enum ReplicaDoTeleprompter {
    static func lerAteCaber(_ chamar: (UnsafeMutablePointer<CChar>?, UInt) -> Int) -> String? {
        var precisa = chamar(nil, 0)
        var voltas = 0
        while precisa > 0, voltas < 8 {
            voltas += 1
            var buffer = [CChar](repeating: 0, count: precisa)
            let n = buffer.withUnsafeMutableBufferPointer { p in chamar(p.baseAddress, UInt(p.count)) }
            if n <= 0 { return nil }
            if n <= precisa {
                return buffer.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: n) {
                        String(decoding: UnsafeBufferPointer(start: $0, count: n - 1), as: UTF8.self)
                    }
                }
            }
            precisa = n
        }
        return nil
    }
}
func naPrincipal(_ b: @escaping () -> Void) { b() }

var falhas = 0
func conferir(_ c: Bool, _ o: String) { print((c ? "  ok   " : "  FALHA ") + o); if !c { falhas += 1 } }

Idioma.usarTabelas(de: [], idioma: .pt)
// A opção na memória do processo (domínio de registro): nada vai a disco.
UserDefaults.standard.register(defaults: [PermissaoDoControleRemoto.chave: true])

let porta: UInt16 = {
    let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
    var t = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, t) } }
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &t) } }
    return UInt16(bigEndian: a.sin_port)
}()

func opcoes(_ id: String, _ nome: String, _ f: (inout QuallSessionOptions) -> Void) {
    id.withCString { i in nome.withCString { n in "482913".withCString { pin in
        var o = QuallSessionOptions(me: QuallDeviceDesc(device_id: i, display_name: n, screen_source: false,
                                                        camera_source: true, sink: true),
                                    pin: pin, known_peers_json: nil, signaling_port: porta, timeout_ms: 30_000,
                                    tracks: nil, track_count: 0, bind_address: nil)
        f(&o)
    } } }
}

// --- o filmador ---------------------------------------------------------------------------------
var cheia = CapacidadesDaCamera()
cheia.exposicaoCustom = true; cheia.exposicaoUmaVez = true; cheia.exposicaoContinua = true
cheia.exposicaoTravada = true; cheia.pontoDeExposicao = true; cheia.focoContinuo = true
cheia.focoUmaVez = true; cheia.focoTravado = true; cheia.pontoDeFoco = true; cheia.lenteCustom = true
cheia.balancoContinuo = true; cheia.balancoUmaVez = true; cheia.balancoTravado = true; cheia.ganhosCustom = true
let faixas = FaixasDaCamera(isoMin: 22.5, isoMax: 1840.7, obturadorMinNs: 14_000, obturadorMaxNs: 500_000_000,
                            evMin: -8, evMax: 8, ganhoMax: 4, fps: 30)
let filmador = FilmadorRemoto()!
var registro = AjustesDaCamera()
let caps = CapacidadesRemotas.json(CapacidadesRemotas.doIOS(cheia, faixas, nome: "Câmera traseira"))!
let st0 = filmador.definirCamera(capacidades: caps, ajuste: String(data: registro.json()!, encoding: .utf8)!)
print("Bancada R9b iOS — 127.0.0.1:\(porta), sem câmera")
conferir(st0 == QUALL_STATUS_OK, "o núcleo aceita as capacidades do iOS (\(caps.utf8.count) bytes) no set_camera")
let lido = RegrasDoControleRemoto.Lido(iso: 320, obturadorNs: 16_666_667, ganhos: [2, 1, 1.6], kelvin: 4870, focoPosicao: 0.42)

let travaF = NSLock()
var fimF = false
var controladoPorVisto: String?
var toqueVisto: (Double, Double, Bool)?
var pedidosAplicados = 0
let tFilmador = Thread {
    var s: OpaquePointer?
    opcoes("filmador-ios", "iPhone de teste") { o in s = withUnsafePointer(to: &o) { quall_host($0) } }
    guard let s, let m = quall_session_messages(s) else { print("  FALHA o filmador não hospedou"); return }
    var ultimoLido = 0.0
    while true {
        travaF.lock(); let acabou = fimF; travaF.unlock()
        if acabou { break }
        let (st, mudou) = filmador.bombear(m, prazoMs: 50)
        if mudou & QUALL_CAMERA_HOST_CHANGE_REQUEST.rawValue != 0 {
            while let t = filmador.proximoPedido() {
                guard let p = RegrasDoControleRemoto.Pedido.de(json: t) else { continue }
                guard var novo = RegrasDoControleRemoto.aplicar(p, sobre: registro, lido: lido, evMin: -8, evMax: 8) else {
                    filmador.recusar(p.n, "nao_aplicado"); continue
                }
                if let toque = p.toque {
                    travaF.lock(); toqueVisto = toque; travaF.unlock()
                    novo = RegrasDosControles.decidirToque(novo, cheia, longo: toque.longo).ajustes
                }
                registro = novo
                filmador.definirAjuste(String(data: registro.json()!, encoding: .utf8)!, pedido: p.n)
                travaF.lock(); pedidosAplicados += 1; travaF.unlock()
            }
        }
        if let e = filmador.estado(), let quem = FilmadorRemoto.controladoPor(e) {
            travaF.lock(); controladoPorVisto = quem; travaF.unlock()
        }
        let agora = CFAbsoluteTimeGetCurrent()
        if agora - ultimoLido > 0.25 {
            ultimoLido = agora
            filmador.definirLido("{\"iso\":320,\"obturadorNs\":16666667,\"kelvin\":4870,\"abertura\":1.8,\"focoPosicao\":0.42,\"divergentes\":[]}")
        }
        if st == QUALL_STATUS_CLOSED { break }
        _ = quall_session_next_event(s, 0)
    }
    filmador.esquecer(m)
    quall_messages_free(m)
    quall_session_close(s)
}
tFilmador.start()
Thread.sleep(forTimeInterval: 0.5)

// --- o receptor ---------------------------------------------------------------------------------
var sR: OpaquePointer?
opcoes("receptor-ios", "Receptor de teste") { o in
    "127.0.0.1:\(porta)".withCString { d in sR = withUnsafePointer(to: &o) { quall_connect(d, $0) } }
}
guard let sR, let mR = quall_session_messages(sR), let remota = CameraRemotaDaSessao() else {
    print("  FALHA o receptor não conectou"); exit(1)
}
func esperar(_ segundos: Double, _ ate: (RegrasDoControleRemoto.EstadoDoReceptor) -> Bool) -> RegrasDoControleRemoto.EstadoDoReceptor? {
    let fim = CFAbsoluteTimeGetCurrent() + segundos
    var ultimo: RegrasDoControleRemoto.EstadoDoReceptor?
    while CFAbsoluteTimeGetCurrent() < fim {
        _ = remota.bombear(mR, prazoMs: 50)
        _ = quall_session_next_event(sR, 0)
        if let j = remota.estadoJson(), let e = RegrasDoControleRemoto.EstadoDoReceptor.de(json: j) {
            ultimo = e
            if ate(e) { return e }
        }
    }
    return ultimo
}
let t0 = CFAbsoluteTimeGetCurrent()
let pronto = esperar(5) { $0.situacao == "pronto" }
conferir(pronto?.situacao == "pronto", String(format: "o receptor fica pronto em %.0f ms (ola → capacidades → estado)",
                                               (CFAbsoluteTimeGetCurrent() - t0) * 1000))
let molde = pronto?.capacidades.map { MoldeDoPainel.remoto($0) }
conferir(molde == MoldeDoPainel.remoto(CapacidadesRemotas.doIOS(cheia, faixas, nome: "Câmera traseira")),
         "o molde que chegou é o do iOS (as capacidades atravessam o núcleo sem perder nada)")
conferir(molde?.escalaDoObturador().first?.texto == "1/30 s" && molde?.limite(.antiCintilacao) == "O iOS ajusta a cintilação sozinho.",
         "o receptor desenha o obturador até 1/30 s e a linha da anti-cintilação do iOS")

// Um gesto: Manual com ISO 800 (o diff do painel).
let campos0 = RegrasDoControleRemoto.camposPedidos(pronto?.capacidades ?? [:])
var depois = pronto?.ajuste ?? AjustesDaCamera()
depois.exposicao = .manual; depois.iso = 800
let pedido = RegrasDoControleRemoto.camposMudados(de: pronto?.ajuste ?? AjustesDaCamera(), para: depois, pedidos: campos0)
let stP = remota.pedir(CapacidadesRemotas.json(pedido)!)
conferir(stP == QUALL_STATUS_OK, "o pedido {exposicao: manual, iso: 800} sai (\(CapacidadesRemotas.json(pedido)!))")
let t1 = CFAbsoluteTimeGetCurrent()
let aplicado = esperar(5) { $0.ajuste?.iso == 800 && $0.ajuste?.exposicao == .manual && $0.autor != nil }
conferir(aplicado?.ajuste?.iso == 800 && aplicado?.ajuste?.obturadorNs == 16_666_667,
         String(format: "volta aplicado em %.0f ms: ISO 800 e o obturador partindo do lido (16.666.667 ns)",
                (CFAbsoluteTimeGetCurrent() - t1) * 1000))
conferir(aplicado?.autor == "Receptor de teste", "o autor é o receptor (\(aplicado?.autor ?? "nil"))")
Thread.sleep(forTimeInterval: 0.3)
travaF.lock(); let cp = controladoPorVisto; travaF.unlock()
conferir(cp == "Receptor de teste", "o filmador viu \"Controlado por \(cp ?? "nil")\"")
conferir(aplicado?.leitura.iso == 320 && aplicado?.leitura.abertura == 1.8, "o lido do filmador chega ao receptor (ISO 320, f/1,8)")

// O toque: o ponto no quadro decodificado chega ao filmador.
let stT = remota.tocar(x: 0.25, y: 0.75, longo: true)
_ = esperar(1.5) { _ in false }
travaF.lock(); let tv = toqueVisto; travaF.unlock()
conferir(stT == QUALL_STATUS_OK && tv?.0 == 0.25 && tv?.1 == 0.75 && tv?.2 == true, "o toque longo (0,25; 0,75) chega ao filmador")

// A opção desligada: nao_permitido com os valores, e o pedido recusado aqui.
UserDefaults.standard.register(defaults: [PermissaoDoControleRemoto.chave: false])
NotificationCenter.default.post(name: PermissaoDoControleRemoto.mudou, object: nil)
let bloqueado = esperar(3) { $0.situacao == "nao_permitido" }
conferir(bloqueado?.situacao == "nao_permitido" && bloqueado?.ajuste?.iso == 800,
         "desligar a opção leva o receptor a nao_permitido, com os valores")
conferir(remota.pedir("{\"iso\":400}") == QUALL_STATUS_INVALID, "e o pedido não sai (INVALID aqui, sem rede)")

// A câmera fecha: sem_camera.
filmador.definirCamera(capacidades: nil, ajuste: nil)
let semCamera = esperar(3) { $0.situacao == "sem_camera" }
conferir(semCamera?.situacao == "sem_camera", "a câmera fechada leva o receptor a sem_camera")

travaF.lock(); fimF = true; travaF.unlock()
_ = remota.bombear(mR, prazoMs: 0)
quall_messages_free(mR)
quall_session_close(sR)
tFilmador.cancel()
Thread.sleep(forTimeInterval: 0.5)
travaF.lock(); let n = pedidosAplicados; travaF.unlock()
print(falhas == 0 ? "bancada: tudo passou (\(n) pedidos aplicados no filmador)" : "bancada: \(falhas) falha(s)")
exit(falhas == 0 ? 0 : 1)
