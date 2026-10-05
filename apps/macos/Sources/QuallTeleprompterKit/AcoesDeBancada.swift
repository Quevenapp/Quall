import Foundation

/// **As ações de bancada** do argumento `--teleprompter-acoes`: edições locais programadas no
/// tempo, feitas pelo **mesmo caminho** dos botões da tela (o modelo), para provar sem mão
/// nenhuma que as edições dos dois lados convergem.
///
/// Forma: `segundos:campo=valor`, separadas por vírgula, com o tempo contado a partir de a tela
/// abrir. Exemplo:
///
///     --teleprompter-acoes=3:fonte=64,4:margem=0.2,5:espelho=1,8:texto+=Linha do prompter,12:pular=0.1
///
/// | campo | valor |
/// |---|---|
/// | `fonte`, `margem`, `linha`, `velocidade` | número (ponto decimal) |
/// | `espelho`, `rolando` | `0` ou `1` |
/// | `salto` | fração de 0 a 1 (`jump`) |
/// | `pular` | fração de −1 a 1 (`jump_by`) |
/// | `texto` | `@/caminho/do/arquivo` (o conteúdo) ou o texto literal |
/// | `texto+` | acrescenta uma linha ao fim do texto atual (`texto+=Linha nova`) |
/// | `editor` | `abrir`, `confirmar`, `cancelar`, `usar-novo`, `manter-meu` — os botões do editor |
/// | `rascunho+` | acrescenta uma linha ao rascunho do editor aberto (é "digitar") |
/// | `arrastar` | fração de 0 a 1: arrasta a linha de leitura com o mouse até ela (só no prompter) |
/// | `fonte-automatica` | `0` ou `1`: a "Fonte automática" do prompter |
/// | `enquadrar` | `E/D`, frações da largura: as duas setas laterais do "Enquadramento" (só no prompter) |
/// | `modo-segurar` | `0` ou `1`: o "Segurar para rolar" do controle (ajuste local) |
/// | `mouse-desce`, `mouse-sobe`, `mouse-sai` | `cima` ou `baixo`: o botão do segurar, pelos métodos do mouse da vista dele (`mouseDown`, `mouseUp`, e um `mouseDragged` para fora do botão) |
/// | `tecla-desce`, `tecla-repete`, `tecla-sobe` | `cima` (↑) ou `baixo` (↓): a seta, pelo mesmo tratador das teclas de verdade (`tecla-repete` é a repetição automática) |
/// | `foco` | `0`: a janela perde o foco, pelo mesmo tratador da notificação |
/// | `inverter` | `0` ou `1`: o "Inverter botões" do modo segurar, pelo mesmo caminho do interruptor (recusado com um botão de rolar apertado) |
/// | `escolha` | `prompter` ou `meu`: responde à pergunta do texto pelo mesmo método dos dois botões, com o resumo que a caixa mostra; sem pergunta aberta ainda, fica armada e responde quando ela abrir (uma vez) |
/// | `guardados` | `abrir` ou `fechar`: a folha "Roteiros guardados" |
/// | `copia` | `ver:N`, `usar:N`, `apagar:N` (N = 1 é a mais nova), `confirmar`, `cancelar`, `voltar`: os botões da folha e dos alertas |
///
/// O valor não pode ter vírgula (é o separador). Uma ação ilegível é devolvida em `recusadas`, e o
/// app a escreve no registro em vez de engoli-la.
public enum AcaoDeBancada: Equatable, Sendable {
    case fonte(Double), margem(Double), linha(Double), velocidade(Double)
    case espelho(Bool), rolando(Bool)
    case salto(Double), pular(Double)
    case texto(String), acrescentar(String)
    case editor(ComandoDoEditor), rascunho(String)
    /// Arrastar a linha de leitura com o mouse até esta fração da altura — o mesmo caminho do
    /// gesto (`mouseDown`/`mouseDragged`/`mouseUp` da vista), com eventos sintéticos.
    case arrastarLinha(Double)
    /// A "Fonte automática" liga (1) ou desliga (0) — `docs/teleprompter-ajustes-locais.md` §5.
    case fonteAutomatica(Bool)
    /// O "Enquadramento": as duas setas laterais, em fração da largura (`enquadrar=0.1/0.8`).
    case enquadrar(Double, Double)
    /// O "Segurar para rolar" do controle liga (1) ou desliga (0).
    case modoSegurar(Bool)
    /// Um gesto do mouse num botão do segurar, com eventos sintéticos pelos métodos da vista dele.
    case mouseDoSegurar(GestoDoMouse, BotaoDeSegurar)
    /// Uma seta do teclado, com um evento sintético pelo tratador das teclas de verdade.
    case teclaDoSegurar(GestoDaTecla, BotaoDeSegurar)
    /// A janela perde o foco (`foco=0`).
    case perderOFoco
    /// O "Inverter botões" liga (1) ou desliga (0).
    case inverterBotoes(Bool)
    /// A resposta à pergunta do texto: `true` é "Mandar o meu".
    case escolha(manterOMeu: Bool)
    /// A folha "Roteiros guardados" abre (`true`) ou fecha.
    case roteirosGuardados(Bool)
    /// Um botão da folha "Roteiros guardados" ou dos alertas dela.
    case copia(GestoDaCopia)
}

/// Os botões da folha "Roteiros guardados": três por item (N = 1 é a cópia mais nova), os dois dos
/// alertas de confirmação, e o "Voltar" da vista de uma cópia.
public enum GestoDaCopia: Equatable, Sendable {
    case ver(Int), usar(Int), apagar(Int)
    case confirmar, cancelar, voltar

    public static func ler(_ v: String) -> GestoDaCopia? {
        let partes = v.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cabeca = partes.first else { return nil }
        if partes.count == 1 {
            switch cabeca {
            case "confirmar": return .confirmar
            case "cancelar": return .cancelar
            case "voltar": return .voltar
            default: return nil
            }
        }
        guard let n = Int(partes[1]), n >= 1 else { return nil }
        switch cabeca {
        case "ver": return .ver(n)
        case "usar": return .usar(n)
        case "apagar": return .apagar(n)
        default: return nil
        }
    }
}

/// Os três gestos do mouse num botão do segurar.
public enum GestoDoMouse: String, Equatable, Sendable {
    /// `mouseDown` no meio do botão.
    case desce
    /// `mouseUp` no meio do botão.
    case sobe
    /// `mouseDragged` para fora do botão, com o botão do mouse ainda apertado.
    case sai
}

/// Os três gestos de uma seta.
public enum GestoDaTecla: String, Equatable, Sendable {
    /// `keyDown`, a primeira.
    case desce
    /// `keyDown` com `isARepeat` — a repetição automática da tecla segurada.
    case repete
    /// `keyUp`.
    case sobe
}

/// Os botões do editor do roteiro, para a bancada provar a regra do texto que chega com ele aberto.
public enum ComandoDoEditor: String, Equatable, Sendable {
    case abrir, confirmar, cancelar
    case usarNovo = "usar-novo"
    case manterMeu = "manter-meu"
}

public struct AcoesDeBancada: Equatable, Sendable {
    public var acoes: [(segundos: Double, acao: AcaoDeBancada)]
    public var recusadas: [String]

    public static func == (a: AcoesDeBancada, b: AcoesDeBancada) -> Bool {
        a.recusadas == b.recusadas && a.acoes.count == b.acoes.count
            && zip(a.acoes, b.acoes).allSatisfy { $0.segundos == $1.segundos && $0.acao == $1.acao }
    }

    /// `lerArquivo` existe para os testes não tocarem no disco.
    public static func ler(_ texto: String,
                           lerArquivo: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) })
        -> AcoesDeBancada {
        var r = AcoesDeBancada(acoes: [], recusadas: [])
        for pedaco in texto.split(separator: ",", omittingEmptySubsequences: true) {
            let item = String(pedaco)
            guard let doisPontos = item.firstIndex(of: ":"),
                  let segundos = Double(item[item.startIndex..<doisPontos].trimmingCharacters(in: .whitespaces)),
                  segundos >= 0 else {
                r.recusadas.append(item)
                continue
            }
            let resto = item[item.index(after: doisPontos)...]
            guard let igual = resto.firstIndex(of: "=") else {
                r.recusadas.append(item)
                continue
            }
            let campo = resto[resto.startIndex..<igual].trimmingCharacters(in: .whitespaces)
            let valor = String(resto[resto.index(after: igual)...])
            let numero = Double(valor.trimmingCharacters(in: .whitespaces))
            let acao: AcaoDeBancada?
            switch campo {
            case "fonte": acao = numero.map(AcaoDeBancada.fonte)
            case "margem": acao = numero.map(AcaoDeBancada.margem)
            case "linha": acao = numero.map(AcaoDeBancada.linha)
            case "velocidade": acao = numero.map(AcaoDeBancada.velocidade)
            case "salto": acao = numero.map(AcaoDeBancada.salto)
            case "pular": acao = numero.map(AcaoDeBancada.pular)
            case "espelho": acao = numero.map { AcaoDeBancada.espelho($0 != 0) }
            case "rolando": acao = numero.map { AcaoDeBancada.rolando($0 != 0) }
            case "texto":
                if valor.hasPrefix("@") {
                    acao = lerArquivo(String(valor.dropFirst())).map(AcaoDeBancada.texto)
                } else {
                    acao = .texto(valor)
                }
            case "texto+": acao = .acrescentar(valor)
            case "editor": acao = ComandoDoEditor(rawValue: valor.trimmingCharacters(in: .whitespaces)).map(AcaoDeBancada.editor)
            case "rascunho+": acao = .rascunho(valor)
            case "arrastar": acao = numero.map(AcaoDeBancada.arrastarLinha)
            case "fonte-automatica": acao = numero.map { AcaoDeBancada.fonteAutomatica($0 != 0) }
            case "enquadrar":
                let partes = valor.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                acao = partes.count == 2 ? .enquadrar(partes[0], partes[1]) : nil
            case "modo-segurar": acao = numero.map { AcaoDeBancada.modoSegurar($0 != 0) }
            case "mouse-desce", "mouse-sobe", "mouse-sai":
                let gesto = GestoDoMouse(rawValue: String(campo.dropFirst("mouse-".count)))
                let botao = BotaoDeSegurar(rawValue: valor.trimmingCharacters(in: .whitespaces))
                acao = gesto.flatMap { g in botao.map { AcaoDeBancada.mouseDoSegurar(g, $0) } }
            case "tecla-desce", "tecla-repete", "tecla-sobe":
                let gesto = GestoDaTecla(rawValue: String(campo.dropFirst("tecla-".count)))
                let botao = BotaoDeSegurar(rawValue: valor.trimmingCharacters(in: .whitespaces))
                acao = gesto.flatMap { g in botao.map { AcaoDeBancada.teclaDoSegurar(g, $0) } }
            case "foco": acao = numero == 0 ? .perderOFoco : nil
            case "inverter": acao = numero.map { AcaoDeBancada.inverterBotoes($0 != 0) }
            case "escolha":
                switch valor.trimmingCharacters(in: .whitespaces) {
                case "prompter": acao = .escolha(manterOMeu: false)
                case "meu": acao = .escolha(manterOMeu: true)
                default: acao = nil
                }
            case "guardados":
                switch valor.trimmingCharacters(in: .whitespaces) {
                case "abrir": acao = .roteirosGuardados(true)
                case "fechar": acao = .roteirosGuardados(false)
                default: acao = nil
                }
            case "copia": acao = GestoDaCopia.ler(valor).map(AcaoDeBancada.copia)
            default: acao = nil
            }
            if let acao { r.acoes.append((segundos, acao)) } else { r.recusadas.append(item) }
        }
        // Estável: duas ações no mesmo segundo saem na ordem em que foram escritas.
        r.acoes = r.acoes.enumerated()
            .sorted { ($0.element.segundos, $0.offset) < ($1.element.segundos, $1.offset) }
            .map(\.element)
        return r
    }
}
