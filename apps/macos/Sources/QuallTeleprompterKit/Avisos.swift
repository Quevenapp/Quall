import Foundation

/// Em que pé está a ligação com o outro aparelho, **do ponto de vista da tela**.
///
/// Não é o estado da sessão do núcleo: é o que a tela precisa para decidir o aviso. A diferença
/// que importa é entre "nunca houve sessão nesta tela" (o prompter esperando o primeiro controle,
/// mostrando o PIN) e "houve, e caiu" (o prompter rolando sozinho, esperando a volta) — só a
/// segunda é "controle sumido".
public enum LigacaoDaTela: Equatable, Sendable {
    /// Nenhuma sessão ainda nesta abertura da tela.
    case semSessao
    /// Uma sessão de pé desde este instante (segundos monotônicos). `depoisDeQueda`: a sessão é a
    /// volta de um par que tinha caído — o aviso só some com a primeira mensagem dele (§2).
    case conectada(desde: Double, depoisDeQueda: Bool)
    /// Houve sessão, e ela caiu: o prompter espera a volta, o controle tenta de novo.
    case caiu
}

/// **Os avisos da tela**, derivados do estado do núcleo e da ligação. Uma função pura, para que a
/// regra seja uma só nas duas telas e testável sem janela.
public struct AvisosDaTela: Equatable, Sendable {
    /// O outro lado sumiu. No prompter: "controle sumido"; no controle: "o prompter não responde"
    /// (conectado) ou "conexão perdida" (caiu).
    public var parSumido = false
    /// Uma edição daqui não voltou confirmada em 1,5 s: "o comando não chegou".
    public var semConfirmacao = false
    /// O outro lado fala outra versão do contrato (`v` ≠ 1): nada vai sincronizar.
    public var atualizeOApp = false
    /// Carimbos mais de 24 h à frente foram recusados: o relógio de um dos dois está errado.
    public var relogioErrado = false
    /// O roteiro foi reenviado 20 vezes e o outro lado continuou sem ele.
    public var textoNaoPassou = false

    public init() {}

    /// `docs/contrato-teleprompter.md` §2 e §3: `PAR_SUMIDO` é 2,5 s, a confirmação 1,5 s.
    public static let parSumidoMs: UInt64 = 2_500
    public static let semConfirmacaoMs: UInt64 = 1_500

    /// # O intervalo que piscaria errado
    ///
    /// `par_visto_ha_ms` é nulo **antes da primeira mensagem de uma sessão nova** — e também
    /// depois de `quall_teleprompter_peer_lost`. Ler "nulo = sumido" na primeira sessão acenderia
    /// o aviso por alguns milissegundos a cada conexão. A regra:
    ///
    /// - na **primeira** sessão da tela, nulo só vale como sumido depois de 2,5 s de sessão sem
    ///   mensagem nenhuma — o mesmo prazo que valeria para uma mensagem que parou de chegar;
    /// - na sessão que é a **volta depois de uma queda**, o aviso que já estava aceso continua até a
    ///   primeira mensagem do par: "o aviso some quando chega a primeira mensagem do controle de
    ///   volta" (§2), e não quando o TCP sobe.
    public static func calcular(estado: EstadoDoTeleprompter, ligacao: LigacaoDaTela,
                                agora: Double) -> AvisosDaTela {
        var a = AvisosDaTela()
        switch ligacao {
        case .semSessao:
            a.parSumido = false
        case .caiu:
            a.parSumido = true
        case .conectada(let desde, let depoisDeQueda):
            if let visto = estado.parVistoHaMs {
                a.parSumido = visto > parSumidoMs
            } else {
                a.parSumido = depoisDeQueda || (agora - desde) * 1000 > Double(parSumidoMs)
            }
            if let pendente = estado.semConfirmacaoHaMs {
                a.semConfirmacao = pendente > semConfirmacaoMs
            }
        }
        a.atualizeOApp = estado.contadores.deOutraVersao > 0
        a.relogioErrado = estado.contadores.carimbosDoFuturo > 0
        a.textoNaoPassou = estado.contadores.reenviosDesistidos > 0
        return a
    }
}
