import Foundation
import AVFoundation

/// O que este aparelho vai transmitir nesta sessão: a tela, ou **uma** câmera física.
///
/// ## A escolha vem antes do PIN
///
/// Decidido em 2026-08-22 (`docs/fluxo-de-uso.md`). O problema que ele resolve é das "duas
/// origens": no iOS a tela vem da Broadcast Upload Extension e a câmera vem do app, e uma
/// `QuallSession` não atravessa processos — então tela e câmera seriam **duas** entradas na lista
/// do receptor, com dois PINs. A saída escolhida não foi ensinar o receptor a lidar com isso: foi
/// **o emissor escolher antes**. Uma entrada na lista, um PIN, uma sessão.
///
/// Duas consequências que este arquivo existe para sustentar:
///
/// 1. **A origem é fixa pela sessão.** Não há renegociação no protocolo (dívida 1), então trocar
///    de origem é encerrar e começar de novo. Não existe botão de trocar de câmera durante a
///    transmissão — e é melhor não ter o botão do que ter um que falha.
/// 2. **Uma origem por vez.** Não por limitação da plataforma, por desenho. O app recusa começar
///    a câmera enquanto houver espelhamento de tela vivo, porque o contrário produziria as duas
///    entradas na lista que a decisão veio apagar.
///
/// O consentimento de gravação de tela do sistema **só** aparece no caminho da tela: quem escolheu
/// uma câmera nunca vê a folha do `RPSystemBroadcastPickerView` nem o indicador vermelho.
enum Origem: Identifiable, Hashable {
    case tela
    /// `id` é o `uniqueID` do `AVCaptureDevice`, que é estável para o mesmo aparelho físico.
    case camera(id: String, nome: String)

    var id: String {
        switch self {
        case .tela: return "tela"
        case .camera(let id, _): return id
        }
    }

    /// O que a pessoa lê no seletor.
    var nome: String {
        switch self {
        case .tela: return "A tela deste iPhone"
        case .camera(_, let nome): return nome
        }
    }

    /// O mesmo nome, no idioma da interface (`tr`): é o que as telas mostram. `nome` continua em
    /// português porque vai ao diário e ao rótulo da track (protocolo), que não se traduzem.
    var nomeNaTela: String {
        switch self {
        case .tela: return tr("A tela deste %@", Estilo.modeloDoAparelho)
        case .camera(_, let nome): return Origem.traduzirNome(nome)
        }
    }

    /// Traduz o nome montado por `nome(de:comTipo:)` ("Câmera traseira (teleobjetiva)"), pedaço por
    /// pedaço. O que não for um dos pedaços conhecidos (o `localizedName` do sistema) fica como está.
    static func traduzirNome(_ nome: String) -> String {
        guard Idioma.atual != .pt else { return nome }
        // A ordem importa: "Câmera" sozinha por último, depois das que começam com ela.
        let lados = [("Câmera frontal", tr("Câmera frontal")),
                     ("Câmera traseira", tr("Câmera traseira")),
                     ("Câmera", tr("Câmera"))]
        let tipos = [("(teleobjetiva)", tr("(teleobjetiva)")),
                     ("(ultra-angular)", tr("(ultra-angular)")),
                     ("(grande-angular)", tr("(grande-angular)"))]
        guard let lado = lados.first(where: { nome.hasPrefix($0.0) }) else { return nome }
        var resto = String(nome.dropFirst(lado.0.count))
        for (tipo, tipoTraduzido) in tipos where resto == " " + tipo {
            resto = " " + tipoTraduzido
        }
        return lado.1 + resto
    }

    var ehCamera: Bool {
        if case .camera = self { return true }
        return false
    }

    /// O rótulo que viaja na track e que o receptor mostra. É por ele que a pessoa do outro lado
    /// sabe o que está recebendo sem precisar olhar a imagem.
    func rotulo(doAparelho nome: String) -> String {
        switch self {
        case .tela: return "Tela de \(nome)"
        case .camera(_, let camera): return "\(camera) de \(nome)"
        }
    }

    // --- enumeração ---------------------------------------------------------------------------

    /// As câmeras **físicas** do aparelho, na ordem em que fazem sentido para quem escolhe.
    ///
    /// **Físicas, e não lógicas.** `builtInDualCamera`, `builtInDualWideCamera` e
    /// `builtInTripleCamera` são aparelhos *virtuais*: o sistema os apresenta como um dispositivo
    /// só que troca de lente sozinho, e eles são **compostos** das mesmas câmeras que já estão na
    /// lista. Sem o filtro de `isVirtualDevice`, um iPhone com três lentes apareceria com cinco ou
    /// seis linhas, várias delas a mesma coisa com nome diferente — que é exatamente o tipo de
    /// escolha que o fluxo proíbe.
    ///
    /// **Enumerado do aparelho, nunca fixado em duas.** No iPhone 7 são duas; no iPhone X são
    /// três (traseira grande-angular, traseira teleobjetiva, frontal TrueDepth); em aparelhos mais
    /// novos são mais. Escrever "frontal e traseira" seria acertar por acidente nos dois aparelhos
    /// da bancada e errar em todos os outros.
    ///
    /// Não pede permissão: enumerar aparelhos de captura não exige TCC, e é por isso que o seletor
    /// pode ser montado antes de qualquer alerta do sistema. O que exige permissão é **abrir** a
    /// câmera, e isso acontece depois da escolha.
    static func cameras() -> [Origem] {
        let tipos = tiposDisponiveis()
        let sessao = AVCaptureDevice.DiscoverySession(
            deviceTypes: tipos, mediaType: .video, position: .unspecified)
        let fisicas = sessao.devices.filter { !$0.isVirtualDevice }

        // Quantas câmeras há de cada lado decide o nome: com uma só, "Câmera traseira" basta e é
        // o que a pessoa entende. Com duas ou mais do mesmo lado, o lado deixa de distinguir e o
        // tipo de lente precisa entrar.
        var porLado: [AVCaptureDevice.Position: Int] = [:]
        for aparelho in fisicas { porLado[aparelho.position, default: 0] += 1 }

        return fisicas.map { aparelho in
            let precisaDoTipo = (porLado[aparelho.position] ?? 0) > 1
            return .camera(id: aparelho.uniqueID,
                           nome: nome(de: aparelho, comTipo: precisaDoTipo))
        }
    }

    /// Os tipos que este iOS conhece. `builtInUltraWideCamera` e as combinações existem desde o
    /// iOS 13, e `builtInLiDARDepthCamera` desde o 15.4 — pedir um tipo que a versão não conhece é
    /// erro de compilação, não de execução, então a lista é conservadora de propósito: o filtro de
    /// `isVirtualDevice` já derruba as compostas, e uma lente física que não esteja aqui não
    /// aparece no seletor, o que é uma falha visível e não um comportamento estranho.
    /// **A câmera frontal**, para a tela "Teleprompter com câmera" (R5): só a frontal, sem seletor
    /// (decisão do Pessoa Exemplo, 24/09, `docs/teleprompter-com-camera.md` §0). Primeiro a grande-angular
    /// frontal, que é o que o sistema oferece como padrão; senão, a primeira frontal física da
    /// descoberta. `nil` num aparelho sem frontal.
    static func frontal() -> Origem? {
        let aparelho = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.DiscoverySession(deviceTypes: tiposDisponiveis(), mediaType: .video,
                                                position: .front).devices.first { !$0.isVirtualDevice }
        guard let aparelho else { return nil }
        return .camera(id: aparelho.uniqueID, nome: nome(de: aparelho, comTipo: false))
    }

    private static func tiposDisponiveis() -> [AVCaptureDevice.DeviceType] {
        [
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInUltraWideCamera,
            .builtInTrueDepthCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
        ]
    }

    /// Nome em português, montado do lado e do tipo de lente.
    ///
    /// `localizedName` do sistema seria o caminho óbvio, e ele é registrado no diagnóstico — mas
    /// ele segue o **idioma do aparelho**, então num iPhone em inglês o seletor do produto diria
    /// "Back Camera" no meio de uma interface em português. O nome que a pessoa lê é do produto.
    static func nome(de aparelho: AVCaptureDevice, comTipo: Bool) -> String {
        let lado: String
        switch aparelho.position {
        case .front: lado = "Câmera frontal"
        case .back: lado = "Câmera traseira"
        default: lado = "Câmera"
        }
        guard comTipo else { return lado }
        return "\(lado) \(tipo(de: aparelho))"
    }

    private static func tipo(de aparelho: AVCaptureDevice) -> String {
        switch aparelho.deviceType {
        case .builtInTelephotoCamera: return "(teleobjetiva)"
        case .builtInUltraWideCamera: return "(ultra-angular)"
        case .builtInWideAngleCamera: return "(grande-angular)"
        case .builtInTrueDepthCamera: return "(TrueDepth)"
        default: return "(\(aparelho.localizedName))"
        }
    }
}
