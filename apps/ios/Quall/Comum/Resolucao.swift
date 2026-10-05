import AVFoundation
import Foundation

/// A resolução e a taxa de quadros que o usuário escolheu emitir — o cardápio de
/// `docs/fluxo-de-uso.md`.
///
/// Gêmea de `core/Resolucao.kt` do Android, e de propósito: o mesmo cardápio, os mesmos rótulos e
/// a mesma unidade. O valor guardado é `maxFs` — macroblocos por quadro — porque é o que a
/// fronteira C recebe em `quall_teto_ajustar_para`, e porque a escolha do usuário e o teto da
/// norma são **a mesma grandeza**. Ver a nota de `quall_core::teto::Alvo`.
///
/// # Em macroblocos a proporção sobrevive
///
/// Guardar um par de dimensões obrigaria cada casca a decidir o que fazer quando o aparelho está
/// em pé. Em macroblocos não há essa decisão: um iPhone em retrato que escolhe 1080p recebe
/// **1080x1920**, e não 1920x1080 deitado.
public enum Resolucao: Int, CaseIterable {
    case p720 = 3_600
    /// **O padrão**, e o teto que valia antes do cardápio.
    case p1080 = 8_160
    case p1440 = 14_400
    case p2160 = 32_400

    public var rotulo: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "2K"
        case .p2160: return "4K"
        }
    }

    /// Macroblocos por quadro — o que atravessa a fronteira C.
    public var maxFs: UInt32 { UInt32(rawValue) }

    /// O teto em pixels, para `CodificadorH264.destino`.
    public var teto: (maior: Int, menor: Int) {
        switch self {
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .p2160: return (3840, 2160)
        }
    }

    /// O preset de captura que cobre esta linha.
    ///
    /// **O AVFoundation não tem preset de 2K**, e é a única linha do cardápio sem correspondente
    /// direto: os presets de vídeo são `.hd1280x720`, `.hd1920x1080` e `.hd4K3840x2160`. Para 2K
    /// o caminho é pedir 4K e deixar `CodificadorH264.destino` reduzir — o que **custa uma
    /// reescala**, e o cabeçalho do `CodificadorH264` registra que reescalar do jeito errado custou
    /// 30 MB contra 0,1 MB neste projeto. Aqui é o VideoToolbox reescalando na entrada da sessão,
    /// que é o caminho previsto e não o que estourou; mas é custo que 720p e 1080p não pagam, e
    /// fica dito para a comparação entre as linhas ser honesta.
    public var preset: AVCaptureSession.Preset {
        switch self {
        case .p720: return .hd1280x720
        case .p1080: return .hd1920x1080
        case .p1440, .p2160: return .hd4K3840x2160
        }
    }

    // MARK: - Preferência

    private static let chaveResolucao = "resolucao_max_fs"
    private static let chaveQuadros = "quadros_por_segundo"

    public static let padrao: Resolucao = .p1080

    private static var defaults: UserDefaults? { UserDefaults(suiteName: Compartilhado.grupo) }

    public static var escolhida: Resolucao {
        get {
            guard let v = defaults?.object(forKey: chaveResolucao) as? Int,
                  let r = Resolucao(rawValue: v) else { return padrao }
            return r
        }
        set { defaults?.set(newValue.rawValue, forKey: chaveResolucao) }
    }

    /// A taxa escolhida. **30 é o padrão**, e é o que valia antes do cardápio.
    public static var quadros: Int {
        get { (defaults?.object(forKey: chaveQuadros) as? Int) ?? 30 }
        set { defaults?.set(newValue == 60 ? 60 : 30, forKey: chaveQuadros) }
    }

    /// As taxas oferecidas. Duas, e não uma faixa: o que existe em silício é 30 e 60.
    public static let taxas = [30, 60]
}
