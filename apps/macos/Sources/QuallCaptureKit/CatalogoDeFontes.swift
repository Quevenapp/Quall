import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import QuallIdiomaKit
import ScreenCaptureKit

/// O que uma fonte de captura é, por trás do nome que a pessoa lê.
///
/// `tela` carrega o `CGDirectDisplayID` e não o índice na lista: monitor que é desconectado
/// enquanto o app está aberto reordena a lista, e um índice guardado passaria a apontar para
/// outro monitor em silêncio. `camera` carrega o `uniqueID` do `AVCaptureDevice` pela mesma
/// razão — é o identificador que a Apple promete estável para o mesmo aparelho físico.
public enum TipoDeFonte: Hashable, Sendable {
    case tela(CGDirectDisplayID)
    case camera(String)
    #if QUALL_TELA_ESTENDIDA_FUTURA
    /// Um monitor que **ainda não existe**: é criado quando o receptor conecta e some quando a
    /// sessão acaba (`MonitorVirtualAuxiliar`). Por isso não carrega id — carrega o modo.
    case telaEstendida(ModoDoMonitorVirtual)
    #endif
}

/// Uma linha do seletor "O que transmitir" (`docs/ux-m6.md`, §1.6).
///
/// `docs/fluxo-de-uso.md` fixa que a origem é escolhida **antes** do PIN e é **fixa pela sessão**
/// — não há renegociação no protocolo, então trocar de origem é encerrar e começar de novo. Esta
/// estrutura existe para que essa escolha seja um dado concreto passado adiante, e não um enum de
/// duas opções que esconde o caso real do desktop: **mais de um monitor**.
public struct FonteDeCaptura: Identifiable, Hashable, Sendable {
    public let id: String
    public let tipo: TipoDeFonte
    /// O que a pessoa lê na lista. Ex.: "Tela interna", "DELL U2415", "FaceTime HD Camera".
    public let nome: String
    /// Uma linha curta de contexto — resolução, ou "câmera do iPhone". Pode ser vazia.
    public let detalhe: String

    public init(id: String, tipo: TipoDeFonte, nome: String, detalhe: String) {
        self.id = id
        self.tipo = tipo
        self.nome = nome
        self.detalhe = detalhe
    }

    public var ehTela: Bool {
        switch tipo {
        case .tela: return true
        #if QUALL_TELA_ESTENDIDA_FUTURA
        case .telaEstendida: return true
        #endif
        case .camera: return false
        }
    }

    #if QUALL_TELA_ESTENDIDA_FUTURA
    /// O modo do monitor a criar, quando esta fonte é a tela estendida.
    public var modoDaTelaEstendida: ModoDoMonitorVirtual? {
        if case .telaEstendida(let modo) = tipo { return modo }
        return nil
    }

    /// A linha "Tela estendida" do seletor. O id **não** carrega o modo, de propósito: a escala pode
    /// mudar entre duas leituras do catálogo, e a escolha da pessoa não pode "sumir da lista" por isso.
    public static func telaEstendida(_ modo: ModoDoMonitorVirtual) -> FonteDeCaptura {
        FonteDeCaptura(id: "tela-estendida", tipo: .telaEstendida(modo), nome: T("Tela estendida"),
                       detalhe: T("novo monitor · %@ · %@ fps", modo.rotulo, modo.fps))
    }
    #endif

    /// A espécie que `CaptureSession`/`TransmissaoAoVivo` usam para escolher o capturador.
    public var especie: CaptureSourceKind { ehTela ? .screen : .camera }

    /// O preset de encode que combina com esta origem. Tela e câmera medem coisas diferentes —
    /// ver `H264Encoder.configure` e `docs/ux-m6.md`, tarefa 3. A interface não pergunta isto:
    /// escolher a origem já escolheu o preset.
    public var presetSugerido: CapturePreset { ehTela ? .screen : .camera }

    /// O rótulo que vai na `QuallTrackDesc` e que o receptor mostra na lista de tracks.
    public func rotuloDaTrack(nomeDoAparelho: String) -> String {
        ehTela ? "\(nome) — \(nomeDoAparelho)" : "\(nome) — \(nomeDoAparelho)"
    }
}

/// Enumera o que este Mac pode transmitir.
///
/// # Ler o estado de uma permissão não é pedi-la
///
/// `docs/regras-de-frente.md` fixa isso depois de custar meia manhã na câmera virtual: consultar
/// `AVCaptureDevice.authorizationStatus` é diagnóstico; **só `requestAccess` cria a linha em
/// Ajustes do Sistema > Privacidade e Segurança**. Por isso `listar(pedindoPermissoes:)` tem esse
/// parâmetro e o app de produto sempre passa `true` — é ele quem tem o direito de pedir, porque é
/// ele o processo responsável quando aberto pelo LaunchServices.
///
/// **Corrigido em 2026-08-27.** O texto aqui dizia que a Gravação de Tela "não tem `requestAccess`"
/// e que quem dispara o diálogo é a primeira consulta ao `SCShareableContent`. A segunda metade é
/// verdade; a primeira não: `CGRequestScreenCaptureAccess()` existe desde o macOS 10.15, é a
/// chamada documentada que **cria a linha no painel**, e agora é ela que `listarTelas` chama antes
/// de enumerar (ver `PermissaoDeTela`). Depender do efeito colateral de uma consulta que falha é
/// justamente a forma de pedir que a regra da casa desaconselha — e deixa o app invisível no
/// painel enquanto ninguém tropeçar naquele caminho.
///
/// A consulta continua podendo falhar *e* agendar o diálogo, então o erro daqui não quer dizer
/// "nunca vai funcionar", quer dizer "responda o diálogo e peça de novo". A interface precisa
/// dizer isso com essas palavras, não "falhou".
///
/// **A mesma concessão cobre a tela e o áudio de sistema**, porque as duas saem da mesma
/// `SCStream`. O painel deste macOS tem uma segunda seção, "Apenas Gravação do Áudio do Sistema",
/// que **não** é a nossa — ver `PermissaoDeTela` para o que foi confirmado e o que é hipótese.
public enum CatalogoDeFontes {
    /// O que uma metade do catálogo devolveu: as fontes, e o motivo quando não veio nenhuma.
    public struct Metade: Sendable {
        public let fontes: [FonteDeCaptura]
        public let bloqueio: String?
        /// O que a consulta de permissão respondeu, para o registro. **Distingue os dois casos
        /// que o `-3801` do TCC confunde**: "ninguém pediu ainda" e "o usuário disse não" pedem
        /// ações opostas, e antes disto chegavam com a mesma cara.
        public let diagnostico: String

        public init(fontes: [FonteDeCaptura], bloqueio: String?, diagnostico: String = "") {
            self.fontes = fontes
            self.bloqueio = bloqueio
            self.diagnostico = diagnostico
        }
    }

    // MARK: - telas

    /// As duas metades são **pedidas em separado, de propósito**, e não por uma função só.
    ///
    /// `AVCaptureDevice.requestAccess` **bloqueia** até a pessoa responder o diálogo do sistema.
    /// Enquanto as duas metades voltavam juntas, a lista inteira ficava presa atrás dessa
    /// resposta: na primeira abertura do app a janela mostraria "Procurando telas e câmeras…"
    /// até alguém clicar em Permitir numa caixa sobre a permissão de **câmera** — para ver as
    /// **telas**, que não dependem dela em nada. Separadas, cada metade aparece quando fica
    /// pronta.
    ///
    /// `telaEstendida`, quando dado, acrescenta a linha "Tela estendida" **depois** dos monitores
    /// reais — desde que a API de monitor virtual e o auxiliar existam neste Mac. Depois, e não antes:
    /// `--fonte=tela` da bancada escolhe a primeira tela da lista, e ela tem de continuar sendo um
    /// monitor de verdade.
    #if QUALL_TELA_ESTENDIDA_FUTURA
    public static func telas(telaEstendida: ModoDoMonitorVirtual? = nil) async -> Metade {
        let (reais, bloqueio, diagnostico) = await listarTelas()
        var fontes = reais
        if let modo = telaEstendida, !reais.isEmpty, MonitorVirtualAuxiliar.disponivel {
            fontes.append(.telaEstendida(modo))
        }
        return Metade(fontes: fontes, bloqueio: bloqueio, diagnostico: diagnostico)
    }
    #else
    public static func telas() async -> Metade {
        let (fontes, bloqueio, diagnostico) = await listarTelas()
        return Metade(fontes: fontes, bloqueio: bloqueio, diagnostico: diagnostico)
    }
    #endif

    public static func cameras(pedindoPermissao: Bool) async -> Metade {
        let (fontes, bloqueio, diagnostico) = await listarCameras(pedindoPermissao: pedindoPermissao)
        return Metade(fontes: fontes, bloqueio: bloqueio, diagnostico: diagnostico)
    }

    static func listarTelas() async -> ([FonteDeCaptura], String?, String) {
        // **Pedir, e não só consultar.** `docs/regras-de-frente.md`: o painel de Privacidade só
        // lista quem pediu pelo menos uma vez, então um app que apenas lê o estado fica invisível
        // lá para sempre — e a pessoa não tem onde marcar a caixinha.
        //
        // Isto não estava aqui antes. O comentário de tipo desta enum dizia que a Gravação de Tela
        // "não tem `requestAccess`" e que quem agenda o diálogo é a primeira consulta ao
        // `SCShareableContent`. Está incompleto: `CGRequestScreenCaptureAccess()` existe desde o
        // macOS 10.15 e é a chamada documentada que cria a linha no painel. Depender do efeito
        // colateral de uma consulta que falha é exatamente a forma de pedir que a regra da casa
        // desaconselha.
        //
        // O `SCShareableContent` continua sendo chamado logo abaixo, e continua sendo ele que
        // enumera. O que mudou é que agora existe um pedido explícito antes dele.
        let permissao = PermissaoDeTela.conferirEPedir()

        let conteudo: SCShareableContent
        do {
            conteudo = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Quando o pedido acabou de ser feito, o texto dele explica melhor o que fazer do que
            // o `-3801` genérico do TCC, que não distingue "ninguém perguntou" de "o usuário
            // disse não".
            let motivo = permissao.estado == .faltando
                ? permissao.texto
                : mensagemDeTelaBloqueada(error)
            return ([], motivo, permissao.texto)
        }
        guard !conteudo.displays.isEmpty else {
            return ([], T("Nenhum monitor encontrado — o que não deveria acontecer num Mac ligado."),
                    permissao.texto)
        }

        // O nome do monitor não vem do ScreenCaptureKit: `SCDisplay` só tem id e tamanho. Quem
        // sabe o nome que o usuário reconhece ("Tela interna", "DELL U2415") é o AppKit, e a
        // ponte entre os dois é o `NSScreenNumber` do `deviceDescription`.
        var nomePorID: [CGDirectDisplayID: String] = [:]
        for tela in NSScreen.screens {
            guard let numero = tela.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            nomePorID[CGDirectDisplayID(truncating: numero)] = tela.localizedName
        }

        // **O monitor da tela estendida não é oferecido como monitor comum.** Ele só existe durante
        // uma sessão, e escolhê-lo como "tela" transmitiria um monitor que some quando a sessão
        // que o criou acabar. Quem o quer escolhe "Tela estendida".
        #if QUALL_TELA_ESTENDIDA_FUTURA
        let reais = conteudo.displays.filter { !MonitorVirtual.ehNosso($0.displayID) }
        #else
        let reais = conteudo.displays
        #endif
        let varias = reais.count > 1
        let fontes = reais.enumerated().map { indice, display -> FonteDeCaptura in
            let apelido = nomePorID[display.displayID] ?? (varias ? T("Monitor %@", indice + 1) : T("A tela"))
            return FonteDeCaptura(
                id: "tela:\(display.displayID)",
                tipo: .tela(display.displayID),
                nome: apelido,
                detalhe: "\(display.width) × \(display.height)")
        }
        return (fontes, nil, permissao.texto)
    }

    private static func mensagemDeTelaBloqueada(_ erro: Error) -> String {
        // O TCC devolve `SCStreamError.userDeclined` (código -3801) tanto para "o usuário disse
        // não" quanto para "ninguém perguntou ainda" — a distinção não chega aqui. A frase serve
        // aos dois casos e não afirma qual é.
        let codigo = (erro as NSError).code
        let falta = codigo == -3801 ? T("Falta a permissão de Gravação de Tela.")
            : T("Falta a permissão de Gravação de Tela (erro %@).", codigo)
        return falta + " " + T("Se o macOS acabou de perguntar, responda Permitir e toque em Atualizar. Se não "
            + "perguntou, abra Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela e habilite o Quall Studio.")
    }

    // MARK: - câmeras

    static func listarCameras(pedindoPermissao: Bool) async -> ([FonteDeCaptura], String?, String) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // **Aqui é onde a permissão nasce.** Sem esta chamada o Quall nunca aparece em
            // Ajustes do Sistema > Privacidade e Segurança > Câmera — o painel só lista quem
            // pediu pelo menos uma vez. Ver `docs/regras-de-frente.md`.
            guard pedindoPermissao else {
                return ([], T("A permissão de Câmera ainda não foi pedida por este processo."), "")
            }
            let concedida = await AVCaptureDevice.requestAccess(for: .video)
            guard concedida else {
                return ([], T("Permissão de Câmera negada. Abra Ajustes do Sistema > Privacidade e "
                    + "Segurança > Câmera e habilite o Quall Studio."), "")
            }
        case .denied, .restricted:
            return ([], T("Permissão de Câmera negada. Abra Ajustes do Sistema > Privacidade e "
                + "Segurança > Câmera e habilite o Quall Studio."), "")
        @unknown default:
            return ([], T("Estado de permissão de Câmera desconhecido nesta versão do macOS."), "")
        }

        var tipos: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            tipos += [.external, .continuityCamera, .deskViewCamera]
        } else {
            tipos += [.externalUnknown]
        }
        let sessao = AVCaptureDevice.DiscoverySession(deviceTypes: tipos, mediaType: .video, position: .unspecified)

        // **A câmera do próprio Quall fica fora**, e o registro diz que ficou (`CameraDoQuall`).
        let (nossas, aparelhos) = separarADoQuall(sessao.devices, uniqueID: \.uniqueID)
        let diagnostico = nossas.isEmpty ? "" : "fora da lista (câmera do próprio Quall): "
            + nossas.map { "\($0.uniqueID) (\($0.localizedName))" }.joined(separator: ", ")
        let fontes = aparelhos.map { aparelho -> FonteDeCaptura in
            let dim = CMVideoFormatDescriptionGetDimensions(aparelho.activeFormat.formatDescription)
            return FonteDeCaptura(
                id: "camera:\(aparelho.uniqueID)",
                tipo: .camera(aparelho.uniqueID),
                nome: aparelho.localizedName,
                detalhe: dim.width > 0 ? "\(dim.width) × \(dim.height)" : T("câmera"))
        }
        if fontes.isEmpty {
            return ([], T("Permissão concedida, mas nenhuma câmera foi encontrada neste Mac."), diagnostico)
        }
        return (fontes, nil, diagnostico)
    }

    /// Separa a câmera do Quall das outras, **sem mudar a ordem** das que ficam. Genérica no
    /// elemento para o teste não precisar de `AVCaptureDevice`.
    static func separarADoQuall<T>(_ todos: [T], uniqueID: (T) -> String) -> (nossas: [T], outras: [T]) {
        var nossas: [T] = []
        var outras: [T] = []
        for x in todos {
            if CameraDoQuall.ehDoQuall(uniqueID: uniqueID(x)) { nossas.append(x) } else { outras.append(x) }
        }
        return (nossas, outras)
    }
}
