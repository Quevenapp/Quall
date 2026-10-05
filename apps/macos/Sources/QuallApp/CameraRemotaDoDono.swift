import CQuall
import Foundation
import QuallCaptureKit
import QuallNetKit

/// **"Permitir controle remoto da câmera"** (R9b, `docs/controle-remoto-da-camera.md` §12, item 1): a
/// opção do filmador, **desligada por padrão**, guardada com os ajustes do app. Mudar avisa todas as
/// pontes vivas (`set_allowed`). Só na principal.
enum PermissaoDoControleRemoto {
    static let chave = "camera.controle_remoto"
    static let mudou = Notification.Name("quall.camera.controle_remoto.mudou")

    static var ligada: Bool {
        get { UserDefaults.standard.bool(forKey: chave) }
        set {
            guard newValue != ligada else { return }
            UserDefaults.standard.set(newValue, forKey: chave)
            Registro.compartilhado.linha("APP CAMERA remoto: \"Permitir controle remoto da câmera\" "
                                         + (newValue ? "ligada" : "desligada"))
            NotificationCenter.default.post(name: mudou, object: nil)
        }
    }
}

/// **O filmador do controle remoto, pendurado num dono da câmera** (contrato §12, filmador): um
/// `QuallCameraHost` por câmera em uso. Nasce com o dono montado (a câmera comum no `Emissor`, a R5 na
/// `TelaComCamera`) e morre com ele — uma troca de câmera é outro dono e outro filmador.
///
/// - **Um consumidor só** dos pedidos (§6): a principal, que no Mac é a fila serial do registro (o painel,
///   o "Restaurar automático" e o clique na prévia mudam o registro só nela). Tirar o pedido, aplicar e
///   responder ao núcleo acontecem na mesma volta da principal.
/// - **A bombeada** é de cada sessão de vídeo com este dono (`SessaoDeEmissao.supervisionar`), que avisa
///   com `avisarPedido()` quando o bit `_CHANGE_REQUEST` acende.
/// - O Mac não escreve o registro sozinho (as travas não guardam lido no macOS) e não lê ISO, obturador
///   nem Kelvin: nem `update_settings` nem `set_read` (o `lido` vai vazio, §3.3).
final class CameraRemotaDoDono: @unchecked Sendable {
    let filmador: FilmadorDaCameraRemota
    private weak var dono: DonoDaCamera?
    private var observador: NSObjectProtocol?
    /// Um consumo já agendado na principal (várias bombeadas acendem o bit). Atrás de `trava`.
    private let trava = NSLock()
    private var _consumoAgendado = false
    /// A releitura do "Controlado por" já agendada. Só na principal.
    private var releituraAgendada = false

    /// **O filmador das sessões sem câmera** (a tela, a tela estendida): sem câmera nenhuma, ele responde
    /// ao `ola` de um receptor novo com `camera` 0, e o receptor vai a `sem_camera` em vez de esperar 5 s
    /// por `sem_resposta` (contrato §9). Nunca recebe `set_camera`. `nil` se o núcleo não o criou.
    static let semCamera: FilmadorDaCameraRemota? = FilmadorDaCameraRemota()

    private init(filmador: FilmadorDaCameraRemota, dono: DonoDaCamera) {
        self.filmador = filmador
        self.dono = dono
    }

    deinit {
        if let observador { NotificationCenter.default.removeObserver(observador) }
    }

    /// Pendura o filmador num dono **já montado** (as capacidades e o registro lidos). Na principal.
    @discardableResult
    static func anexar(a d: DonoDaCamera) -> CameraRemotaDoDono? {
        guard d.montado, let caps = d.capacidades else { return nil }
        guard let f = FilmadorDaCameraRemota() else {
            Registro.compartilhado.linha("APP CAMERA remoto: !! o núcleo não criou o filmador; sem controle remoto")
            return nil
        }
        let ponte = CameraRemotaDoDono(filmador: f, dono: d)
        f.permitir(PermissaoDoControleRemoto.ligada)
        let json = caps.jsonRemoto(nomeDaCamera: d.nomeDaCamera)
        let st = f.definirCamera(capacidades: json, ajuste: d.ajustes.json)
        Registro.compartilhado.linha("APP CAMERA remoto: filmador pronto (permitido=\(PermissaoDoControleRemoto.ligada)) "
                                     + "set_camera=\(st.rawValue) capacidades=\(json)")
        d.anexoRemoto = ponte
        d.aoMudarORegistro = { [weak ponte] a in ponte?.publicarMudancaLocal(a) }
        d.aoFechar = { [weak ponte] in ponte?.cameraFechou("o dono fechou") }
        d.aoInterromper = { [weak ponte] in ponte?.cameraFechou("a câmera caiu") }
        ponte.observador = NotificationCenter.default.addObserver(forName: PermissaoDoControleRemoto.mudou, object: nil,
                                                                  queue: .main) { [weak ponte] _ in
            ponte?.filmador.permitir(PermissaoDoControleRemoto.ligada)
        }
        return ponte
    }

    /// O filmador pendurado neste dono, para a sessão bombear.
    static func de(_ d: DonoDaCamera?) -> FilmadorDaCameraRemota? {
        (d?.anexoRemoto as? CameraRemotaDoDono)?.filmador
    }

    static func ponte(de d: DonoDaCamera?) -> CameraRemotaDoDono? { d?.anexoRemoto as? CameraRemotaDoDono }

    // MARK: - o que a câmera faz aqui

    /// Uma mudança feita **neste Mac** (o painel, o restaurar, o clique na prévia): `set_settings(json, 0)`.
    private func publicarMudancaLocal(_ a: AjustesDaCamera) {
        let st = filmador.definirAjuste(a.json, pedido: 0)
        if st != QUALL_STATUS_OK {
            Registro.compartilhado.linha("APP CAMERA remoto: !! set_settings local devolveu \(st.rawValue)")
        }
    }

    /// A câmera fechou ou caiu: os receptores escondem o painel (§7.3).
    private func cameraFechou(_ motivo: String) {
        filmador.semCamera()
        dono?.mostrarControladoPor(nil)
        Registro.compartilhado.linha("APP CAMERA remoto: sem câmera (\(motivo))")
    }

    // MARK: - os pedidos

    /// Uma bombeada viu `_CHANGE_REQUEST`. De qualquer thread: agenda **um** consumo na principal.
    func avisarPedido() {
        trava.lock()
        let jaAgendado = _consumoAgendado
        _consumoAgendado = true
        trava.unlock()
        guard !jaAgendado else { return }
        DispatchQueue.main.async { [weak self] in self?.consumirPedidos() }
    }

    /// **O consumidor único** (§6): tira até a fila esvaziar, aplica, responde. Na principal.
    private func consumirPedidos() {
        // A bandeira cai **antes** de esvaziar: um bit que acender durante o laço agenda outro consumo, e
        // nenhum pedido fica esperando o próximo bit (o bit é global e qualquer bombeada pode levá-lo).
        trava.lock(); _consumoAgendado = false; trava.unlock()
        var tratados = 0
        while let json = filmador.proximoPedido() {
            tratados += 1
            guard let p = PedidoDaCameraRemota.ler(json) else {
                Registro.compartilhado.linha("APP CAMERA remoto: !! pedido ilegível do núcleo (\(json.utf8.count) bytes)")
                continue
            }
            guard let d = dono else {
                filmador.recusar(p.n, motivo: "sem_camera")
                continue
            }
            if let motivo = d.aplicarPedidoRemoto(p) {
                let st = filmador.recusar(p.n, motivo: motivo)
                Registro.compartilhado.linha("APP CAMERA remoto: reject(\(p.n), \(SanitizacaoDoLog.codigoRemoto(motivo))) = \(st.rawValue)")
                continue
            }
            let registro = d.ajustes.json
            let st = filmador.definirAjuste(registro, pedido: p.n)
            Registro.compartilhado.linha("APP CAMERA remoto: set_settings(\(p.n)) = \(st.rawValue) registro=\(registro)")
            if st != QUALL_STATUS_OK {
                // O núcleo já desistiu deste `n` (5 s, ou a câmera trocou): o registro aplicado aqui é o
                // vigente mesmo assim, e o núcleo tem de voltar a tê-lo — como mudança local.
                let st0 = filmador.definirAjuste(registro, pedido: 0)
                Registro.compartilhado.linha("APP CAMERA remoto: o pedido \(p.n) venceu no núcleo; registro republicado "
                                             + "como local (\(st0.rawValue))")
            }
        }
        if tratados > 0 { relerControladoPor() }
    }

    /// "Controlado por <aparelho>" enquanto o núcleo disser (`controlado_por`, 4 s). Na principal.
    private func relerControladoPor() {
        let nome = CameraRemotaDoDono.controladoPor(filmador.estadoJson())
        dono?.mostrarControladoPor(nome)
        guard nome != nil, !releituraAgendada else { return }
        releituraAgendada = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.releituraAgendada = false
            self.relerControladoPor()
        }
    }

    /// O nome em `controlado_por` do estado do filmador, ou `nil`.
    static func controladoPor(_ estado: String) -> String? {
        guard let d = estado.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let c = o["controlado_por"] as? [String: Any], let n = c["nome"] as? String else { return nil }
        return n
    }
}
