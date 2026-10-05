import Foundation

/// O dano do enlace numa **janela**, e não desde o começo da sessão.
///
/// Todo contador de recepção deste projeto é acumulado desde o início — `packets_seen`,
/// `packets_lost_for_real`, `suspeitos`, `idrs_broken`. Isso é certo para o relato final e é
/// inútil para decidir alguma coisa **agora**: uma sessão que perdeu 8 % nos primeiros dez
/// segundos e nada depois continua dizendo 8 % meia hora adiante. Quem escuta o enlace precisa da
/// derivada, não da integral.
///
/// ## Por que esta peça existe nesta casca, e por que ela não existia
///
/// O controlador de taxa do emissor (`quall_core::taxa`, e a curva em `docs/taxa-que-escuta.md`)
/// só decide sobre o que o receptor lhe conta. Sem esta peça a casca da câmera virtual é
/// receptora **muda**: o emissor nunca recebe amostra, `quall_session_take_link_report` devolve
/// `false` em toda chamada, e o controlador fica inerte **por construção** — não porque o enlace
/// esteja bom.
///
/// Não é hipótese. Em 31/08/2026, no par que o usuário usa (A10s espelhando para o iPad), o
/// controlador tinha acabado de virar padrão e mediu `trocas_de_bitrate=0` com **2,95 %** de perda
/// e **881** quadros exibidos com a referência quebrada — porque o relato existia **só** na casca
/// Android. A metade iOS foi escrita no mesmo dia; esta é a terceira.
///
/// É a mesma peça do Android (`JanelaDoEnlace.kt`) e do iOS
/// (`apps/ios/Quall/Receber/JanelaDoEnlace.swift`), com a mesma forma e os mesmos nomes, de
/// propósito: um controlador alimentado por um número diferente do que a bancada mediu é um
/// controlador projetado contra outra curva.
///
/// ## O denominador vem do emissor, e isso não é detalhe
///
/// `pacotes` é `vistos + perdidos`, que é **o que o emissor mandou** na janela — os dois termos
/// saem de números de sequência RTP, que são contíguos. Dividir a perda pelo que **chegou**
/// responde outra pergunta, e o viés não é constante: em 31/08/2026 esta bancada quase publicou a
/// conclusão oposta sobre a perda de regime porque um instrumento dividia pelo que chegou — o
/// braço que parecia o melhor da matriz era o pior, e o laudo já estava escrito.
///
/// ## Contador que anda para trás é track recriada, não perda negativa
///
/// Os deltas são subtração **saturante**. Contador de núcleo não regride, mas uma casca que
/// assume isso e erra publica um número absurdo em vez de um zero — e um delta negativo
/// alimentando um controlador é como se sobe o bitrate exatamente quando não se deve.
struct JanelaDoEnlace {

    /// Uma janela fechada. **Todos os campos são deltas da janela**, exceto que `ms` é a duração
    /// dela.
    struct Amostra {
        /// Duração **real** da janela, em ms — nunca a nominal. Ver `fechar`.
        let ms: UInt64
        /// O que o emissor mandou na janela: `vistos + perdidos`.
        let pacotes: UInt64
        /// Perda **exata** (`packets_lost_for_real`), e não o teto `packets_missing_upper_bound`.
        let perdidos: UInt64
        /// Quadros exibíveis cuja cadeia de referência estava condenada, contados por esta casca.
        let suspeitos: UInt64
        /// `idrs_broken`: quadros de recuperação que chegaram destruídos pela mesma perda que
        /// eles existem para consertar.
        let idrsQuebrados: UInt64

        /// A linha de diário. Mesmo texto do receptor iOS, para as duas cascas serem comparáveis
        /// numa corrida sem ninguém traduzir nada.
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
    /// A primeira chamada **só ancora**: os acumulados de uma sessão que já rodou meio segundo
    /// antes de a primeira janela abrir medem o arranque (o primeiro IDR, a subida do ICE) como se
    /// fosse regime.
    ///
    /// `ms` é o decorrido **real** e não o período nominal: quem chama é um laço que acorda quando
    /// acorda — aqui, a cada ~50 ms —, e dividir pelo nominal daria uma taxa sistematicamente
    /// alta.
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

    /// Os três acumulados do núcleo que a janela precisa, do JSON de `quall_track_stats_json`.
    ///
    /// `packets_lost_for_real` e **não** `packets_missing_upper_bound`: o segundo cobra
    /// reordenação como perda, e foi lido como perda em todas as medições desta bancada até
    /// 29/08/2026 — de 1,3× a 44× de inflação (`docs/contador-nas-cascas.md`). Um controlador
    /// alimentado por ele reduziria o bitrate por causa de pacotes que chegaram.
    ///
    /// # Leitura falha devolve `nil`, e a janela **não** é fechada
    ///
    /// A primeira versão desta função devolvia zeros, nas três cascas Swift. Parecia inofensivo:
    /// o delta de um acumulado que não se moveu é zero, e uma janela de `pacotes=0` é descartada
    /// pelo controlador, que exige `pacotes_minimos`. O dano não está nessa janela — está na
    /// **seguinte**. Zerar aqui zera a âncora, e a janela seguinte entrega como dano de 500 ms
    /// tudo o que a sessão acumulou desde o começo. O controlador soma `pacotes` e `perdidos` ao
    /// longo de um trecho (`ControladorDeTaxa::pacotes_desde_a_mudanca`), e uma janela dessas
    /// domina o trecho inteiro: é a integral entrando pela porta que existe para entregar a
    /// derivada.
    ///
    /// `nil` custa **um tique**. A âncora fica de pé, a janela seguinte mede o intervalo maior e
    /// o `ms` real diz isso em voz alta. É a política que a casca do OBS já tinha
    /// (`ler_acumulados_do_enlace`), e agora as quatro concordam.
    static func acumulados(_ json: String) -> (vistos: UInt64, perdidos: UInt64,
                                               idrsQuebrados: UInt64)? {
        guard let dados = json.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
        else { return nil }
        // Contador de núcleo não é negativo. Se vier assim é lixo, e zero é o único valor que não
        // inventa dano nem o esconde debaixo de um `UInt64` gigante.
        func inteiro(_ chave: String) -> UInt64? {
            guard let n = d[chave] as? NSNumber else { return nil }
            let v = n.int64Value
            return v > 0 ? UInt64(v) : 0
        }
        guard let vistos = inteiro("packets_seen"),
              let perdidos = inteiro("packets_lost_for_real"),
              let idrs = inteiro("idrs_broken")
        else { return nil }
        return (vistos, perdidos, idrs)
    }
}
