import Foundation

/// O dano do enlace numa **janela**, e não desde o começo da sessão.
///
/// Todo contador de recepção deste projeto é acumulado desde o início — `packets_seen`,
/// `packets_lost_for_real`, `suspeitos`, `idrs_broken`. Isso é certo para o relato final e é
/// inútil para decidir alguma coisa **agora**: uma sessão que perdeu 8 % nos primeiros dez
/// segundos e nada depois continua dizendo 8 % meia hora adiante. Quem escuta o enlace precisa da
/// derivada, não da integral.
///
/// ## Por que esta peça existe no iOS, e por que ela não existia
///
/// O controlador de taxa foi ligado por padrão em 31/08/2026 e, no par que o usuário usa — A10s
/// espelhando para o iPad —, ele **não fez nada**: `trocas_de_bitrate=0` com 2,95 % de perda e 881
/// quadros exibidos com a referência quebrada. O relato existia **só na casca Android**, então com
/// receptor iOS o emissor nunca recebia amostra e o controlador era inerte por construção.
///
/// É a mesma peça do Android (`JanelaDoEnlace.kt`), com a mesma forma e os mesmos nomes, de
/// propósito: um controlador alimentado por um número diferente do que a bancada mediu é um
/// controlador projetado contra outra curva.
///
/// ## O denominador vem do emissor
///
/// `pacotes` é `vistos + perdidos`, que é **o que o emissor mandou** na janela. Dividir a perda
/// pelo que chegou responde outra pergunta, e o viés não é constante: numa medição desta bancada
/// ele inverteu a ordem entre dois braços, e o laudo já estava escrito.
struct JanelaDoEnlace {
    struct Amostra {
        let ms: UInt64
        /// O que o emissor mandou na janela: `vistos + perdidos`.
        let pacotes: UInt64
        let perdidos: UInt64
        let suspeitos: UInt64
        let idrsQuebrados: UInt64

        var linha: String {
            let pct = pacotes == 0 ? 0.0 : Double(perdidos) * 100.0 / Double(pacotes)
            return String(format: "janela_do_enlace ms=%llu pacotes=%llu perdidos=%llu (%.2f%%) "
                          + "suspeitos=%llu idrs_quebrados=%llu",
                          ms, pacotes, perdidos, pct, suspeitos, idrsQuebrados)
        }
    }

    private var abertaEmUs: UInt64 = 0
    private var vistos: UInt64 = 0
    private var perdidos: UInt64 = 0
    private var suspeitos: UInt64 = 0
    private var idrsQuebrados: UInt64 = 0
    private var primeira = true

    /// Fecha a janela se ela já durou `periodoMs`, e devolve a **derivada**.
    ///
    /// A primeira chamada só ancora: os acumulados de uma sessão que já rodou meio segundo antes
    /// de a primeira janela abrir não são dano desta janela.
    ///
    /// Os deltas são calculados com subtração saturante. Contador de núcleo não anda para trás,
    /// mas uma casca que assume isso e erra publica um número absurdo em vez de um zero — e esta
    /// bancada já teve um contador imprimindo 296 pacotes numa origem cujo maior quadro tem 115.
    mutating func fechar(agoraUs: UInt64, periodoMs: UInt64,
                         vistosAcum: UInt64, perdidosAcum: UInt64,
                         suspeitosAcum: UInt64, idrsQuebradosAcum: UInt64) -> Amostra? {
        if primeira {
            primeira = false
            ancorar(agoraUs, vistosAcum, perdidosAcum, suspeitosAcum, idrsQuebradosAcum)
            return nil
        }
        let decorridoMs = (agoraUs &- abertaEmUs) / 1000
        guard periodoMs > 0, decorridoMs >= periodoMs else { return nil }

        let dv = vistosAcum &- min(vistos, vistosAcum)
        let dp = perdidosAcum &- min(perdidos, perdidosAcum)
        let ds = suspeitosAcum &- min(suspeitos, suspeitosAcum)
        let di = idrsQuebradosAcum &- min(idrsQuebrados, idrsQuebradosAcum)
        ancorar(agoraUs, vistosAcum, perdidosAcum, suspeitosAcum, idrsQuebradosAcum)

        return Amostra(ms: decorridoMs, pacotes: dv &+ dp, perdidos: dp,
                       suspeitos: ds, idrsQuebrados: di)
    }

    private mutating func ancorar(_ agoraUs: UInt64, _ v: UInt64, _ p: UInt64,
                                  _ s: UInt64, _ i: UInt64) {
        abertaEmUs = agoraUs
        vistos = v; perdidos = p; suspeitos = s; idrsQuebrados = i
    }
}
