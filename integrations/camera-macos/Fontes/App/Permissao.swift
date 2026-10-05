import AVFoundation
import Foundation

/// **Pedir a permissão de Câmera — e pedir com o rosto certo.**
///
/// Medido em 2026-08-24. Foram TRÊS descobertas, e as duas primeiras não bastavam:
///
/// 1. Ler `AVCaptureDevice.authorizationStatus` **não** faz o sistema perguntar nada. O estado
///    ficava `notDetermined` para sempre, o app não aparecia em Privacidade e Segurança > Câmera,
///    e a sessão abria e entregava zero quadro — sem erro em canto nenhum. O painel não tinha o
///    que ligar porque **ninguém nunca pediu**. Só `requestAccess` cria a linha.
///
/// 2. Quem aparece na linha não é necessariamente este app. O TCC atribui o pedido ao *processo
///    responsável*, e um binário lançado direto por um shell herda o responsável de quem abriu o
///    shell — o terminal, ou o agente que rodou o script. Pelo LaunchServices (`open -a`) o app é
///    o próprio responsável, e a linha sai com o nome dele.
///
/// 3. E nada disso adiantava sozinho. Sob `ENABLE_HARDENED_RUNTIME: YES` o TCC exige o entitlement
///    `com.apple.security.device.camera` **mesmo num app que não é sandboxed**, e recusa antes de
///    existir diálogo — `denied` em milissegundos, sem gravar registro. O `tccd` dizia isso em
///    nível `Error` desde a primeira corrida; `log show` esconde `Info`/`Debug` por padrão e eu
///    concluí que não havia rastro. Ver `App.entitlements` e `docs/bancada.md`.
///
/// Por isso este arquivo checa `getppid()` antes de pedir: se não veio do `launchd`, o diálogo vai
/// ter o nome errado, e é melhor dizer isso do que o usuário conceder câmera a um programa que não
/// é este.
enum Permissao {
    /// `true` quando o processo foi lançado pelo LaunchServices (`open -a`) ou pelo Finder — o
    /// `launchd` reparenta, então o pai é 1. Um `exec` direto de um shell tem o shell como pai.
    static var lancadoPeloSistema: Bool { getppid() == 1 }

    /// Pede a permissão e **espera a resposta**. Devolve o estado final.
    ///
    /// O prazo existe porque o diálogo é modal e humano: sem ninguém na frente da tela a espera
    /// seria eterna, e um script de bancada que nunca termina é pior que um que falha.
    @discardableResult
    static func pedirCamera(prazo: TimeInterval = 120) -> AVAuthorizationStatus {
        let estado = AVCaptureDevice.authorizationStatus(for: .video)
        dizer("permissão de Câmera: \(nome(estado))")

        switch estado {
        case .authorized:
            return estado

        case .denied, .restricted:
            dizer("  negada antes. Ajustes do Sistema > Privacidade e Segurança > Câmera,")
            dizer("  ligar \"\(nomeDoApp)\". Não há comando: o TCC só aceita clique humano.")
            return estado

        case .notDetermined:
            if !lancadoPeloSistema {
                dizer("  ATENÇÃO: este processo não veio do LaunchServices (pai=\(getppid()), não 1).")
                dizer("  O diálogo vai sair com o nome de quem abriu o shell, não \"\(nomeDoApp)\".")
                dizer("  Para pedir com o rosto certo: open -a QuallCamera --args ...")
            }
            dizer("  pedindo agora; um diálogo do sistema vai aparecer (prazo de \(Int(prazo)) s)")

            let porta = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in porta.signal() }
            if porta.wait(timeout: .now() + prazo) == .timedOut {
                dizer("  ninguém respondeu ao diálogo em \(Int(prazo)) s")
                return AVCaptureDevice.authorizationStatus(for: .video)
            }
            let depois = AVCaptureDevice.authorizationStatus(for: .video)
            dizer("  resposta: \(nome(depois))")
            return depois

        @unknown default:
            return estado
        }
    }

    private static var nomeDoApp: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "QuallCamera"
    }

    private static func nome(_ e: AVAuthorizationStatus) -> String {
        switch e {
        case .notDetermined: return "notDetermined (ninguém perguntou ainda)"
        case .restricted:    return "restricted (bloqueada por política)"
        case .denied:        return "denied (negada)"
        case .authorized:    return "authorized"
        @unknown default:    return "desconhecido"
        }
    }
}
