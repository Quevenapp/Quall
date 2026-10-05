import Foundation

/// **O controle remoto da câmera, na fronteira C** (R9b, `docs/controle-remoto-da-camera.md` §11.1):
/// os embrulhos de `QuallCameraHost` (o filmador) e de `QuallCameraRemote` (o receptor), e a opção
/// "Permitir controle remoto da câmera". As regras são de `RegrasDoControleRemoto` (puras, testadas
/// no MacBook); aqui só os ponteiros, as threads e o padrão `(buf, cap)`.
///
/// Os ponteiros vivem o mesmo tanto que o embrulho, e toda chamada C passa por `comPonteiro`, que
/// segura o embrulho vivo até a chamada voltar (`withExtendedLifetime`): o ARC pode soltar um objeto
/// depois da última leitura do campo, e o ponteiro seria liberado no meio da chamada.

// MARK: - A opção

/// **"Permitir controle remoto da câmera"**, desligada por padrão (contrato §12, filmador 1). Mora
/// nos Ajustes do app (`FolhaDaEngrenagem`), junto das outras preferências, e vale para a câmera comum
/// e para a R5. Cada filmador vivo ouve a mudança (`mudou`) e a passa ao núcleo na hora.
enum PermissaoDoControleRemoto {
    static let chave = "camera.controleRemoto"
    static let mudou = Notification.Name("br.com.queven.quall.camera.controleRemoto")

    static var ligada: Bool {
        get { UserDefaults.standard.bool(forKey: chave) }
        set {
            guard newValue != ligada else { return }
            UserDefaults.standard.set(newValue, forKey: chave)
            Diagnostico.nota("APP CAMERA remoto: \"Permitir controle remoto da câmera\" " + (newValue ? "ligada" : "desligada"))
            NotificationCenter.default.post(name: mudou, object: nil)
        }
    }
}

// MARK: - O filmador

/// **Um `QuallCameraHost` por câmera em uso** (contrato §7.1): um por `DonoDaCaptura`, que é de uma
/// tela e de uma câmera só. Quem o alimenta é `ControlesDaCamera` (o registro, as capacidades, o lido);
/// quem o bombeia é o laço de hospedagem do `EmissorDeCamera`, uma vez por sessão de vídeo.
final class FilmadorRemoto {
    private let ponteiro: OpaquePointer
    private var observador: NSObjectProtocol?

    init?() {
        guard let p = quall_camera_host_new() else { return nil }
        ponteiro = p
        _ = quall_camera_host_set_allowed(p, PermissaoDoControleRemoto.ligada)
        observador = NotificationCenter.default.addObserver(forName: PermissaoDoControleRemoto.mudou, object: nil,
                                                            queue: nil) { [weak self] _ in
            self?.comPonteiro { _ = quall_camera_host_set_allowed($0, PermissaoDoControleRemoto.ligada) }
        }
    }

    deinit {
        if let observador { NotificationCenter.default.removeObserver(observador) }
        quall_camera_host_free(ponteiro)
    }

    private func comPonteiro<T>(_ f: (OpaquePointer) -> T) -> T {
        withExtendedLifetime(self) { f(ponteiro) }
    }

    /// A câmera em uso (capacidades e registro), ou nenhuma (os dois nulos).
    @discardableResult
    func definirCamera(capacidades: String?, ajuste: String?) -> QuallStatus {
        comPonteiro { p in
            guard let capacidades, let ajuste else { return quall_camera_host_set_camera(p, nil, nil) }
            return capacidades.withCString { c in ajuste.withCString { a in quall_camera_host_set_camera(p, c, a) } }
        }
    }

    @discardableResult
    func definirCapacidades(_ json: String) -> QuallStatus {
        comPonteiro { p in json.withCString { quall_camera_host_set_capabilities(p, $0) } }
    }

    /// `pedido` 0: uma mudança feita aqui; senão o `n` do pedido que ficou valendo.
    @discardableResult
    func definirAjuste(_ json: String, pedido: UInt64) -> QuallStatus {
        comPonteiro { p in json.withCString { quall_camera_host_set_settings(p, $0, pedido) } }
    }

    /// A escrita automática da casca (o lido que a trava guarda): ninguém vira dono de campo.
    @discardableResult
    func atualizarAjuste(_ json: String) -> QuallStatus {
        comPonteiro { p in json.withCString { quall_camera_host_update_settings(p, $0) } }
    }

    @discardableResult
    func definirLido(_ json: String) -> QuallStatus {
        comPonteiro { p in json.withCString { quall_camera_host_set_read(p, $0) } }
    }

    @discardableResult
    func recusar(_ pedido: UInt64, _ motivo: String) -> QuallStatus {
        comPonteiro { p in motivo.withCString { quall_camera_host_reject(p, pedido, $0) } }
    }

    /// O próximo pedido aceito, ou `nil` com a fila vazia. O padrão `(buf, cap)` do header: com `buf`
    /// nulo ele diz o tamanho **sem tirar da fila**, e só tira quando coube.
    func proximoPedido() -> String? {
        comPonteiro { p in
            ReplicaDoTeleprompter.lerAteCaber { buf, cap in Int(quall_camera_host_next_request(p, buf, UInt(cap))) }
        }
    }

    /// A bombeada numa sessão de vídeo. **Só da thread da sessão.**
    func bombear(_ mensagens: OpaquePointer, prazoMs: UInt32) -> (status: QuallStatus, mudou: UInt32) {
        comPonteiro { p in
            var mudou: UInt32 = 0
            let st = quall_camera_host_pump(p, mensagens, prazoMs, &mudou)
            return (st, mudou)
        }
    }

    func esquecer(_ mensagens: OpaquePointer) {
        comPonteiro { _ = quall_camera_host_forget($0, mensagens) }
    }

    /// O estado para a tela (`controlado_por`, `receptores`).
    func estado() -> [String: Any]? {
        comPonteiro { p in
            guard let json = ReplicaDoTeleprompter.lerAteCaber({ buf, cap in Int(quall_camera_host_state_json(p, buf, UInt(cap))) }),
                  let d = json.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
    }

    /// O nome de quem mexeu há menos de 4 s (`controlado_por`), ou `nil`.
    static func controladoPor(_ estado: [String: Any]) -> String? {
        guard let c = estado["controlado_por"] as? [String: Any], let nome = c["nome"] as? String else { return nil }
        return nome.isEmpty ? tr("outro aparelho") : nome
    }

    static func temReceptores(_ estado: [String: Any]) -> Bool {
        !((estado["receptores"] as? [Any]) ?? []).isEmpty
    }
}

// MARK: - O receptor, por sessão

/// **Um `QuallCameraRemote` por sessão de recepção** (contrato §11.1). Por sessão, e não um só para o
/// app: a sessão que acaba ainda bombeia a última vez depois de a pessoa ter conectado de novo, e um
/// objeto compartilhado seria zerado pela sessão velha. A tela fala com `ControleRemotoDaCamera`, que
/// segue a sessão de agora.
final class CameraRemotaDaSessao {
    private let ponteiro: OpaquePointer

    init?() {
        guard let p = quall_camera_remote_new() else { return nil }
        ponteiro = p
    }

    deinit { quall_camera_remote_free(ponteiro) }

    private func comPonteiro<T>(_ f: (OpaquePointer) -> T) -> T {
        withExtendedLifetime(self) { f(ponteiro) }
    }

    /// Só os campos que a pessoa mexeu. `QUALL_STATUS_INVALID`: o que o filmador recusaria.
    func pedir(_ json: String) -> QuallStatus {
        comPonteiro { p in json.withCString { quall_camera_remote_request(p, $0) } }
    }

    func restaurar() -> QuallStatus { comPonteiro { quall_camera_remote_restore($0) } }

    func tocar(x: Double, y: Double, longo: Bool) -> QuallStatus {
        comPonteiro { quall_camera_remote_touch($0, x, y, longo) }
    }

    /// **Só da thread da sessão.**
    func bombear(_ mensagens: OpaquePointer, prazoMs: UInt32) -> (status: QuallStatus, mudou: UInt32) {
        comPonteiro { p in
            var mudou: UInt32 = 0
            let st = quall_camera_remote_pump(p, mensagens, prazoMs, &mudou)
            return (st, mudou)
        }
    }

    func estadoJson() -> String? {
        comPonteiro { p in
            ReplicaDoTeleprompter.lerAteCaber { buf, cap in Int(quall_camera_remote_state_json(p, buf, UInt(cap))) }
        }
    }
}
