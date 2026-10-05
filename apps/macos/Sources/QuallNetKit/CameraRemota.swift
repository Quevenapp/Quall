import CQuall
import Foundation

// **A ponte do controle remoto da câmera** (R9b, `docs/controle-remoto-da-camera.md` §11.1): os dois
// objetos do núcleo — `QuallCameraHost` no Mac que filma, `QuallCameraRemote` no Mac que recebe — e o
// handle das mensagens da sessão de vídeo, por onde os dois falam. Só o embrulho: o que fazer com o
// pedido é do app (`CameraRemotaDoDono`), e o que mostrar é do `PlanoRemotoDoPainel`.
//
// # As regras da fronteira que este arquivo segura
//
// - **`free` no `deinit`**, e só nele: quem bombeia (a thread da sessão) segura a referência forte, então
//   nunca há `free` com uma bombeada em curso.
// - **O handle das mensagens sobrevive a `quall_session_close`** (o header): a bombeada depois do fim
//   devolve `QUALL_STATUS_CLOSED` sem tocar na biblioteca. Por isso ele é um objeto à parte, com o próprio
//   `quall_messages_free`.
// - **`(buf, cap)`: repita até caber** (`PonteDoTeleprompter.lerAteCaber`). O estado e o pedido crescem
//   entre a pergunta e a escrita; o `next_request` só tira da fila quando coube, e devolve `0` vazia.

/// **As mensagens de uma sessão** (`quall_session_messages`), para a bombeada da câmera. Numa sessão de
/// vídeo ela é **o** leitor do canal (§2, "um leitor por sessão").
public final class MensagensDaSessao: @unchecked Sendable {
    let ponteiro: OpaquePointer

    init?(sessao: OpaquePointer) {
        guard let m = quall_session_messages(sessao) else { return nil }
        ponteiro = m
    }

    deinit { quall_messages_free(ponteiro) }
}

/// O resultado de uma bombeada: o status e os bits de `changed`.
public struct Bombeada: Sendable, Equatable {
    public let status: QuallStatus
    public let mudou: UInt32

    /// A sessão acabou e a fila foi lida até o fim: pare de bombear.
    public var acabou: Bool { status == QUALL_STATUS_CLOSED }
}

/// **O filmador** (`QuallCameraHost`): um por câmera em uso, vive mais que as sessões. Todas as funções
/// podem vir de qualquer thread (o header).
public final class FilmadorDaCameraRemota: @unchecked Sendable {
    private let h: OpaquePointer

    /// Nasce sem câmera e **com a permissão desligada** (o padrão do contrato).
    public init?() {
        guard let h = quall_camera_host_new() else { return nil }
        self.h = h
    }

    deinit { quall_camera_host_free(h) }

    /// "Permitir controle remoto da câmera".
    @discardableResult
    public func permitir(_ sim: Bool) -> QuallStatus { quall_camera_host_set_allowed(h, sim) }

    /// A câmera em uso: as capacidades (§3.2) e o registro do R9 dela.
    @discardableResult
    public func definirCamera(capacidades: String, ajuste: String) -> QuallStatus {
        capacidades.withCString { c in ajuste.withCString { a in quall_camera_host_set_camera(h, c, a) } }
    }

    /// Sem câmera (a câmera fechou): os receptores escondem o painel.
    @discardableResult
    public func semCamera() -> QuallStatus { quall_camera_host_set_camera(h, nil, nil) }

    /// O registro que ficou valendo: `pedido` 0 é uma mudança feita aqui; senão o `n` do pedido.
    @discardableResult
    public func definirAjuste(_ json: String, pedido: UInt64) -> QuallStatus {
        json.withCString { quall_camera_host_set_settings(h, $0, pedido) }
    }

    /// A casca não aplicou o pedido `n`: o código `[a-z0-9_]` do contrato §3.5.
    @discardableResult
    public func recusar(_ n: UInt64, motivo: String) -> QuallStatus {
        motivo.withCString { quall_camera_host_reject(h, n, $0) }
    }

    /// O próximo pedido aceito, como JSON; `nil` com a fila vazia (ou erro). **Um consumidor só.**
    public func proximoPedido() -> String? {
        PonteDoTeleprompter.lerAteCaber { quall_camera_host_next_request(h, $0, $1) }
    }

    /// A bombeada numa sessão de vídeo, da thread dela, com `prazoMs` de 0 a 250.
    public func bombear(_ m: MensagensDaSessao, prazoMs: UInt32 = 0) -> Bombeada {
        var mudou: UInt32 = 0
        let st = quall_camera_host_pump(h, m.ponteiro, prazoMs, &mudou)
        return Bombeada(status: st, mudou: mudou)
    }

    /// Esquece a sessão (largada sem bombear até o `CLOSED`): libera a vaga na hora.
    public func esquecer(_ m: MensagensDaSessao) { _ = quall_camera_host_forget(h, m.ponteiro) }

    /// O estado para a tela do filmador (`controlado_por`, os receptores, os contadores).
    public func estadoJson() -> String {
        PonteDoTeleprompter.lerAteCaber { quall_camera_host_state_json(h, $0, $1) } ?? ""
    }

    public static var bitDoPedido: UInt32 { UInt32(QUALL_CAMERA_HOST_CHANGE_REQUEST.rawValue) }
    public static var bitDosReceptores: UInt32 { UInt32(QUALL_CAMERA_HOST_CHANGE_LISTENERS.rawValue) }
}

/// **O controle da câmera do outro lado** (`QuallCameraRemote`): um por sessão de recepção de vídeo.
public final class ControleDaCameraRemota: @unchecked Sendable {
    private let r: OpaquePointer

    public init?() {
        guard let r = quall_camera_remote_new() else { return nil }
        self.r = r
    }

    deinit { quall_camera_remote_free(r) }

    /// Um ajuste parcial (só os campos mexidos). `QUALL_STATUS_INVALID` na hora para o que o filmador
    /// recusaria, ou fora de `pronto`. **Só de gesto.**
    @discardableResult
    public func pedir(_ json: String) -> QuallStatus { json.withCString { quall_camera_remote_request(r, $0) } }

    @discardableResult
    public func restaurar() -> QuallStatus { quall_camera_remote_restore(r) }

    @discardableResult
    public func tocar(x: Double, y: Double, longo: Bool) -> QuallStatus { quall_camera_remote_touch(r, x, y, longo) }

    public func bombear(_ m: MensagensDaSessao, prazoMs: UInt32 = 0) -> Bombeada {
        var mudou: UInt32 = 0
        let st = quall_camera_remote_pump(r, m.ponteiro, prazoMs, &mudou)
        return Bombeada(status: st, mudou: mudou)
    }

    public func estadoJson() -> String {
        PonteDoTeleprompter.lerAteCaber { quall_camera_remote_state_json(r, $0, $1) } ?? ""
    }
}

extension NucleoDeRede {
    /// As mensagens da sessão de pé, para a bombeada da câmera. `nil` sem sessão.
    public func mensagens() -> MensagensDaSessao? {
        comSessao { MensagensDaSessao(sessao: $0) }
    }
}

extension NucleoReceptor {
    /// As mensagens da sessão de pé, para a bombeada da câmera. `nil` sem sessão.
    public func mensagens() -> MensagensDaSessao? {
        comSessao { MensagensDaSessao(sessao: $0) }
    }
}
