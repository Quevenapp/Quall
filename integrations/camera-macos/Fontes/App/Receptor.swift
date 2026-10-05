import CoreMedia
import CoreVideo
import Foundation

/// O caminho de produto inteiro, num objeto: rede → decode → câmera virtual.
///
/// `quall_connect` → `quall_session_next_track` → `quall_track_on_frame` → VideoToolbox →
/// `CMSimpleQueue` do CoreMediaIO → extensão → Zoom.
///
/// **Sem fila em lugar nenhum.** O quadro que chega da rede é decodificado na hora, e o quadro
/// decodificado é enfileirado na fila de 3 do CoreMediaIO ou **descartado**. Espelhamento ao vivo
/// não tem uso para quadro velho, e foi medindo isto que o M2 achou os 250 ms de fila no A07.
final class Receptor {
    private let nucleo = Nucleo()
    private let cliente = ClienteDoSumidouro()
    private var decodificador: DecodificadorH264!
    private let ajustador = Ajustador(largura: Identidade.largura, altura: Identidade.altura)
    private var descricao: CMFormatDescription?

    private(set) var entregues: UInt64 = 0
    private(set) var naoEncaixaram: UInt64 = 0
    private var primeiraImagemUs: UInt64 = 0
    private var conexaoUs: UInt64 = 0

    // ---------------------------------------------------------------------------------------------
    // Pedir IDR quando o núcleo perde quadro
    //
    // O `contrato-track.md` diz que a casca receptora chama `pedir_idr()` "ao entrar na sessão sem
    // ter visto IDR, **ou quando o decoder perde sincronia**". Até 26/08/2026 esta casca fazia só a
    // primeira metade — e a segunda é a que a arquitetura escolheu quando recusou NACK: a dívida 25
    // fecha aquela decisão com "a recuperação de perda aqui é o IDR pedido por PLI, que custa um
    // quadro e não uma fila". Sem o pedido, um buraco na sequência deixa o decodificador sem
    // referência **até o próximo IDR programado do emissor** — 2 s na câmera do Android
    // (`GOP_SEGUNDOS_CAMERA = 2f`).
    //
    // O gatilho é `frames_dropped` do núcleo, e ele é suficiente por um motivo que não é óbvio: um
    // quadro que some inteiro não incrementa ele próprio, mas o buraco na sequência é visto no
    // pacote seguinte, que condena o quadro seguinte. Qualquer perda no meio do fluxo produz pelo
    // menos um `frames_dropped`. Medido nesta bancada: um buraco de 257 posições de sequência dá
    // `frames_dropped = 2` — a maioria dos quadros do buraco nem chega a existir.
    //
    // **Com supressão, e ela não é zelo.** A RFC 4585 pede supressão de rajada, e aqui há motivo
    // medido: atender um PLI injeta um IDR inteiro em rajada no mesmo caminho que acabou de perder
    // pacote. O piso abaixo é o que separa "pedir na perda" de "tempestade de pedidos".
    // ---------------------------------------------------------------------------------------------

    /// De quanto em quanto tempo `frames_dropped` é lido. Não é o relatório: é o gatilho, e cada
    /// milissegundo aqui entra direto no tempo em que o decodificador fica sem referência.
    private static let sondagemDePerdaMs: UInt64 = 50

    /// Período da **janela do enlace**, em ms: a cadência com que esta casca conta ao emissor o
    /// que viu.
    ///
    /// **500 ms, e não é escolha livre.** É a janela contra a qual a política do controlador de
    /// taxa foi medida (`crates/quall-core/src/taxa.rs`, e a curva de resposta em
    /// `docs/taxa-que-escuta.md`); alimentá-lo com outra é projetá-lo contra outra curva. As
    /// cascas Android e iOS usam a mesma, de propósito.
    ///
    /// Não é a batida do laço: o laço continua batendo a `sondagemDePerdaMs` (50 ms), porque é
    /// disso que depende o pedido de IDR na perda. A janela é um **teto de tempo dentro dele**.
    private static let janelaDoEnlaceMs: UInt64 = 500

    /// Piso entre **repetições** do pedido, enquanto a mesma perda continua sem resposta.
    ///
    /// Ajustável por ambiente **para a bancada que mediu o número** — é esta casca que roda o A/B
    /// do piso, e recompilar o app a cada valor mediria a ferramenta.
    ///
    /// **250 ms desde 27/08/2026, e o número é emprestado — diga isso a quem perguntar.** Ele foi
    /// medido em Android→Android (`docs/android-para-android.md`, seção 17): a mediana não se move
    /// de 100 a 2000 ms, mas a cauda sim, e 250 ms é o joelho entre cauda e chamado (p95 de 490 ms
    /// contra 1147+ nos pisos de 500 para cima, por 85 PLI/min em vez de 173). **Nada disso foi
    /// medido neste rádio nem neste sistema**, e a casca que recebe aqui tem uma segunda origem de
    /// PLI que o Android não tem — a fila do decoder. O valor anterior, 500 ms, também nunca foi
    /// medido aqui: era palpite. Trocar palpite por número medido noutro lugar é melhora, não
    /// prova. `QUALL_PLI_INTERVALO_MS` existe justamente para varrer isto aqui.
    private static var intervaloMinimoDePliUs: UInt64 = ambiente("QUALL_PLI_INTERVALO_MS", 250_000)

    /// Piso antes do **primeiro** pedido de uma perda nova, e ele é bem menor. Ver a nota abaixo.
    ///
    /// ## Por que dois pisos, e não um — medido no Dell G3, e o defeito era meu
    ///
    /// A primeira versão desta política tinha um piso só, de 500 ms, para qualquer pedido. Na sonda
    /// do Windows isso saiu **caro e visível**: aquela casca tem uma segunda origem de PLI (a fila
    /// do decoder dela encheu), e o estouro da fila acontece exatamente no mesmo instante que a
    /// perda de rede — os dois vêm do mesmo soluço. O pedido da fila saía primeiro, gastava o
    /// orçamento, e a perda de rede — detectada 30 ms depois — ficava esperando os 500 ms inteiros.
    /// Três corridas seguidas deram **462 · 519 · 518 ms** de decodificador sem referência, contra
    /// 24 e 25 ms na corrida em que a ordem se inverteu.
    ///
    /// O erro conceitual é tratar o piso como um relógio global. **Supressão é por causa:** um PLI
    /// que saiu *antes* de a perda existir não pode consertá-la, e contá-lo como "já pedi" é contar
    /// a resposta errada. O piso longo continua valendo para o que ele foi feito — insistir num
    /// pedido que ninguém atendeu —, e o curto limita a rajada de perdas distintas.
    private static var pisoDoPrimeiroPedidoUs: UInt64 = ambiente("QUALL_PLI_PISO_CURTO_MS", 100_000)

    private static func ambiente(_ chave: String, _ padrao: UInt64) -> UInt64 {
        guard let t = ProcessInfo.processInfo.environment[chave], let ms = UInt64(t) else {
            return padrao
        }
        return ms * 1_000
    }

    /// Já saiu um pedido **para esta perda**? Enquanto for `false`, vale o piso curto; depois, o
    /// longo — porque aí o pedido é insistência, não estreia.
    private var pediuPorEstaPerda = false

    /// Último `frames_dropped` visto. `nil` enquanto ninguém leu — e ler falhando **não** zera,
    /// senão a volta seguinte inventaria uma perda.
    private var ultimosPerdidos: UInt64?
    /// Houve perda que ainda não virou pedido. Some quando o pedido sai **ou** quando um IDR chega
    /// sozinho: se o GOP do emissor consertou dentro da janela de supressão, o pedido seria gasto.
    private var perdaPendente = false
    private var perdaDetectadaUs: UInt64 = 0
    private var ultimoPliUs: UInt64 = 0
    private(set) var pedidosNaPerda: UInt64 = 0
    private(set) var perdasVistas: UInt64 = 0
    /// De cada perda detectada até o IDR seguinte. É o número do A/B: quanto tempo o decodificador
    /// ficou sem referência.
    private(set) var semReferenciaMs: [UInt64] = []

    // -----------------------------------------------------------------------------------------
    // **A testemunha que faltava: quadro entregue com a referência quebrada.**
    //
    // Esta casca já detectava a ruptura (o `conferirPerda` abaixo) e a usava **só** para pedir
    // IDR: consertava a recuperação e não consertava o que se entrega até ela chegar, nem contava.
    // Entre a ruptura e o IDR seguinte, todo quadro P decodifica sem erro nenhum e sai visualmente
    // podre — e vai inteiro para a câmera virtual, ou seja, para a chamada de vídeo da pessoa.
    //
    // Os nomes são os de `docs/contrato-track.md` e são literais. `perdasVistas` **não** é
    // `rupturas`: aquele soma quadros descartados, este conta quebras da cadeia (uma por subida).
    private var cadeiaCondenada = false
    private(set) var rupturas: UInt64 = 0
    private(set) var suspeitos: UInt64 = 0
    private var suspeitosNaRajada: UInt64 = 0
    private(set) var piorRajada: UInt64 = 0
    private(set) var retidos: UInt64 = 0
    private var condenadaDesdeUs: UInt64 = 0
    /// Protege os contadores acima: aqui, ao contrário do receptor do app, o `entregar` roda numa
    /// thread do VideoToolbox e o laço de supervisão na principal. Trava própria, e **não** a
    /// `travaDoIdr`: pegar aquela em volta de uma chamada ao núcleo fecharia um ciclo ABBA contra
    /// a thread da libdatachannel, que já a pede de dentro do tratador de quadro.
    private let travaDaSuspeita = NSLock()

    /// A derivada dos contadores, que é o que o controlador do outro lado escuta. Ver
    /// `JanelaDoEnlace`.
    private var janelaDoEnlace = JanelaDoEnlace()
    private var ultimoEnlaceUs: UInt64 = 0
    /// Quantas vezes o relato já foi recusado. Três e cala — ver `relatarEnlace()`.
    private var relatosRecusados = 0

    /// Por quanto tempo, no máximo, a câmera virtual fica sem quadro novo esperando um IDR.
    ///
    /// Mesmo valor das outras cascas. **E aqui a válvula importa mais que nas outras**: segurar
    /// aqui é não enfileirar no `CMSimpleQueue`, e o consumidor do outro lado (Zoom, Meet) vê um
    /// fluxo parado, não um quadro repetido. A maioria dos clientes segura o último quadro, mas
    /// isso é suposição sobre software de terceiro — e é razão para o prazo ser curto, não longo.
    private static let congelarNoMaximoUs: UInt64 = 2_000_000

    /// A porta nasce **DESLIGADA**, e isso é reversão medida, não gosto.
    ///
    /// Ela entrou ligada com o argumento de que todo produto de espelhamento congela o último quadro bom
    /// e espera o IDR em vez de mostrar lixo. O argumento tem uma premissa escondida: **que o IDR chega.**
    /// Em 31/08/2026, A10s espelhando tela real para o iPad em 2,4 GHz, o emissor mandou **31 IDR** e o
    /// receptor viu **13** — 58 % dos quadros de recuperação destruídos pela mesma perda que eles existem
    /// para consertar. `sem_referencia_ms [n=8 p50=1959 p95=2083 max=2083]`: **todos** os intervalos
    /// terminaram na válvula de 2 s, nenhum porque a imagem se curou. `fps` na tela: **0,0**.
    ///
    /// Onde o IDR não chega, a porta troca imagem suja por tela parada, que é pior. Ela fica desligada
    /// até a entrega do IDR sobreviver à perda. Os contadores contam dos dois lados — `suspeitos` não
    /// depende da porta, só `retidos` depende.
    ///
    /// `--congelar` liga, para o braço "depois" do A/B no mesmo binário.
    private static let congelarNaRuptura = CommandLine.arguments.contains("--congelar")

    /// `n`, `p50`, `p95` e `max` de uma lista de durações **em milissegundos**.
    ///
    /// Quatro números e não um: numa medida de dano visual **a cauda é o dano**. Esta casca já
    /// publicava a lista crua, que é ilegível a partir de algumas dezenas de amostras e não
    /// permite comparar uma corrida com outra.
    static func resumo(_ ms: [UInt64]) -> String {
        guard !ms.isEmpty else { return "[n=0]" }
        let v = ms.sorted()
        func q(_ p: Double) -> UInt64 { v[min(v.count - 1, Int(p * Double(v.count - 1) + 0.5))] }
        return "[n=\(v.count) p50=\(q(0.5)) p95=\(q(0.95)) max=\(v[v.count - 1])]"
    }

    /// Quantos IDR já tinham chegado quando a perda foi detectada. O IDR seguinte a este número é
    /// o que devolve a referência ao decodificador — venha ele do pedido ou do GOP do emissor.
    private var idrsQuandoPerdeu: UInt64 = 0

    /// Escrito pela thread da libdatachannel, lido pelo laço de supervisão.
    ///
    /// O **carimbo** do IDR é tirado ali, e não na volta do laço que o observa: senão o tempo sem
    /// referência sairia quantizado em 50 ms e a medida do conserto seria a medida da sondagem.
    /// O outro lado da conta — a detecção da perda — continua com a granularidade da sondagem, e
    /// isso é de propósito: aquela espera é custo do conserto, não erro de medição.
    private let travaDoIdr = NSLock()
    private var idrsRecebidos: UInt64 = 0
    private var ultimoIdrUs: UInt64 = 0

    /// Quando ligado, o receptor lê a faixa de relógio que o emissor de bancada desenhou dentro do
    /// quadro e mede **emissor → pronto para a câmera virtual**. Fica atrás de bandeira porque
    /// custa uma varredura de 22 células por quadro e não serve para nada em produto: o caminho de
    /// produto carrega vídeo de gente, não faixa de relógio.
    var medirFaixa = false
    private var atrasos: [UInt64] = []
    private var semFaixa: UInt64 = 0

    private let arquivoDePares: URL

    /// Onde o estado de pareamento mora. Estático porque o comando `esquecer` precisa do mesmo
    /// caminho sem subir um receptor.
    static func arquivoDePares() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quall", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pares.json")
    }

    init() {
        arquivoDePares = Receptor.arquivoDePares()
    }

    func correr(endereco: String, pin: String?, segundos: Double, prazoMs: UInt32) -> Int32 {
        // 1. Abrir a câmera virtual **antes** de tocar na rede. Abrir o fluxo de entrada é o que
        //    faz o CoreMediaIO lançar o processo da extensão: se isso for falhar, falha aqui, e
        //    não depois de o usuário já ter digitado o PIN.
        // `QUALL_SEM_CAMERA=1` exercita só a metade de rede. Existe para separar duas falhas que
        // acontecem em ordem — a câmera não abrir e a rede não conectar — e que, juntas, sempre
        // aparecem como a primeira.
        let semCamera = ProcessInfo.processInfo.environment["QUALL_SEM_CAMERA"] == "1"
        if semCamera {
            dizer("QUALL_SEM_CAMERA=1: pulando a câmera virtual, só a rede")
        } else {
            do {
                try cliente.abrir()
            } catch {
                dizer("câmera virtual indisponível: \(RegistroSeguro.erro(error))")
                return 1
            }
            dizer("câmera virtual aberta: dispositivo=\(cliente.idDoDispositivo) fluxo=\(cliente.idDoFluxo) fila=\(cliente.capacidadeDaFila)")
        }

        decodificador = DecodificadorH264 { [weak self] imagem, _, suspeito in
            self?.entregar(imagem, suspeito: suspeito)
        }

        let pares = try? String(contentsOf: arquivoDePares, encoding: .utf8)
        dizer("conectando ao par\(pin == nil ? " conhecido" : " com autenticação digitada")…")
        conexaoUs = Medidas.agoraUs()
        guard nucleo.conectar(endereco: endereco,
                              pin: pin,
                              deviceId: identidadeDoAparelho(),
                              nome: Host.current().localizedName ?? "MacBook",
                              paresConhecidos: pares,
                              prazoMs: prazoMs) else {
            dizer("não conectou: status=\(quall_last_status().rawValue) \(RegistroSeguro.motivo(nucleo.ultimoMotivo))")
            cliente.fechar()
            return 1
        }
        dizer("sessão de pé em \((Medidas.agoraUs() - conexaoUs) / 1000) ms; pareamento \(nucleo.pareamentoNovo() ? "novo (PIN digitado)" : "retomado")")
        // Gravar o pareamento **agora**, e não no fim: se a sessão cair, o usuário não pode perder
        // o pareamento que já aconteceu — era exatamente esse o defeito, o PIN pedido toda vez.
        guardarPares()

        guard let (_, tipo) = nucleo.esperarTrack(prazoMs: 5_000) else {
            dizer("a sessão subiu mas nenhuma track chegou")
            nucleo.encerrar()
            cliente.fechar()
            return 1
        }
        dizer("track recebida (tipo=\(tipo.rawValue)); rótulo omitido")

        guard nucleo.ouvirQuadros({ [weak self] bytes, ts, idr in
            guard let self else { return }
            let agora = Medidas.agoraUs()
            if idr {
                // Thread da libdatachannel: só um contador sob trava, nada mais. Quem decide o que
                // fazer com ele é o laço de supervisão.
                self.travaDoIdr.lock()
                self.idrsRecebidos &+= 1
                self.ultimoIdrUs = agora
                self.travaDoIdr.unlock()
            }
            // **Nunca chame o núcleo daqui.** `nucleo.quadrosPerdidos()` entra em
            // `quall_track_stats_json`, que pega o cadeado do depacotizador — e o núcleo despacha
            // este tratador **com esse mesmo cadeado na mão**. Seria um travamento na thread da
            // libdatachannel, que leva o caminho de mídia inteiro junto. A leitura mora no laço de
            // supervisão (`conferirPerda`); aqui só se consulta a bandeira que ele deixou.
            self.travaDaSuspeita.lock()
            if idr {
                // O IDR é o quadro que não depende de referência nenhuma: ele **cura** a cadeia.
                if self.suspeitosNaRajada > self.piorRajada { self.piorRajada = self.suspeitosNaRajada }
                self.suspeitosNaRajada = 0
                self.cadeiaCondenada = false
                self.condenadaDesdeUs = 0
            } else if self.cadeiaCondenada {
                self.suspeitos &+= 1
                self.suspeitosNaRajada &+= 1
                // A válvula: um emissor que aceita o pedido de IDR e não o atende existiu de
                // verdade nesta bancada, e contra ele congelar sem prazo é pior que a imagem suja.
                if self.condenadaDesdeUs != 0,
                   agora - self.condenadaDesdeUs > Receptor.congelarNoMaximoUs {
                    self.cadeiaCondenada = false
                    self.condenadaDesdeUs = 0
                }
            }
            let suspeito = self.cadeiaCondenada && Receptor.congelarNaRuptura
            self.travaDaSuspeita.unlock()
            self.decodificador.alimentar(annexb: bytes, timestampUs: ts, idr: idr, suspeito: suspeito)
        }) else {
            dizer("não deu para registrar o tratador de quadro")
            nucleo.encerrar()
            cliente.fechar()
            return 1
        }

        // 2. Pedir IDR ao entrar. Sem isto o receptor Windows mediu 3,71 s até a primeira imagem
        //    contra 44 ms com o pedido. A track pode ainda não ter aberto: insistir por alguns
        //    milissegundos é o comportamento certo, engolir o erro é reproduzir o defeito.
        var pedidoAceito = false
        for _ in 0..<200 {
            if nucleo.pedirIdr() == QUALL_STATUS_OK { pedidoAceito = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        dizer("pedido de IDR \(pedidoAceito ? "aceito" : "NÃO aceito em 1 s")")
        // O piso de supressão vale a partir daqui: o pedido de entrada e o primeiro pedido por
        // perda não podem sair colados, ou a entrada na sessão já começa com duas rajadas de IDR.
        if pedidoAceito { ultimoPliUs = Medidas.agoraUs() }

        // 3. Laço de supervisão. O prazo pequeno do `next_event` é de propósito: ele é o detector
        //    de queda, e sem ele o único sinal seria o envio falhar — que também é o estado
        //    normal antes de o ICE fechar.
        //
        //    Ele também é a batida da sondagem de perda: `evento(prazoMs:)` dorme o que falta, e
        //    trocar a espera de 800 ms por uma de 50 ms é o que permite reagir a um buraco na
        //    sequência sem esperar o próximo relatório.
        dizer("pedido de IDR na perda: sondagem \(Self.sondagemDePerdaMs) ms, piso entre pedidos \(Self.intervaloMinimoDePliUs / 1000) ms")
        let fim = Date().addingTimeInterval(segundos)
        var caiu = false
        var proximoRelato = Date().addingTimeInterval(1.0)
        while Date() < fim {
            let e = nucleo.evento(prazoMs: UInt32(Self.sondagemDePerdaMs))
            if e == QUALL_SESSION_EVENT_DISCONNECTED || e == QUALL_SESSION_EVENT_FAILED {
                dizer("sessão caiu: evento=\(e.rawValue)")
                caiu = true
                break
            }
            conferirPerda()
            relatarEnlace()
            if Date() >= proximoRelato {
                proximoRelato = Date().addingTimeInterval(1.0)
                relatar()
            }
        }

        relatar()
        let lista = semReferenciaMs.map(String.init).joined(separator: " ")
        travaDoIdr.lock()
        let idrs = idrsRecebidos
        travaDoIdr.unlock()
        // `idrs` é o que mede o **custo** da política: cada pedido atendido é um IDR a mais no fio,
        // e no clipe desta bancada um IDR vale ~134 pacotes contra ~10 de um quadro P.
        dizer("PERDA: eventos=\(perdasVistas) pedidos de IDR=\(pedidosNaPerda) idrs recebidos=\(idrs) sem referência (ms)= \(lista)")
        let custo = decodificador.resumoDeCusto()
        dizer("decode: n=\(custo.n) média=\(custo.media)us p50=\(custo.p50)us p95=\(custo.p95)us max=\(custo.max)us")
        let enc = ajustador.resumoDeCusto()
        dizer("encaixe: diretos=\(ajustador.passesDiretos) transferências=\(ajustador.transferencias) média=\(enc.media)us p95=\(enc.p95)us")
        // Uma leitura só, nas duas formas: a linha mastigada e o JSON cru. Ler duas vezes daria
        // dois instantes e a bancada compararia números que não fecham entre si.
        let contadoresFinais = nucleo.contadores()
        dizer("PERDA (final): \(ResumoDePerda.formatar(contadoresFinais))")
        dizer("contadores do núcleo: \(RegistroSeguro.metricas(contadoresFinais))")
        if primeiraImagemUs > 0 {
            dizer("primeira imagem: \((primeiraImagemUs - conexaoUs) / 1000) ms depois de conectar")
        }
        dizer("entregues à câmera virtual=\(entregues) descartados pela fila=\(cliente.descartados) não encaixaram=\(naoEncaixaram)")
        // A mesma linha da volta de 1 Hz, agora fechando a sessão inteira — e com a ressalva ao
        // lado, porque ela não cabe no nome do contador: o instante medido é o da **entrega à
        // fila**, não o da exibição. Entre esta fila e o olho de alguém ainda há a extensão, o
        // assistente do CoreMediaIO e o app consumidor. Ver `Fluidez`.
        dizer("\(cliente.linhaDeFluidez)  (intervalo entre ENTREGAS ao sumidouro; "
              + "quem exibe é o app consumidor, depois da extensão)")
        if medirFaixa {
            if atrasos.isEmpty {
                dizer("faixa de relógio: nenhum quadro trouxe faixa (sem faixa=\(semFaixa))")
            } else {
                let o = atrasos.sorted()
                dizer("LATÊNCIA emissor→pronto para a câmera virtual: n=\(o.count) min=\(o.first!)ms média=\(atrasos.reduce(0, +) / UInt64(atrasos.count))ms p50=\(o[o.count / 2])ms p95=\(o[min(o.count - 1, Int(Double(o.count) * 0.95))])ms max=\(o.last!)ms (sem faixa=\(semFaixa))")
            }
        }

        nucleo.encerrar()
        cliente.fechar()
        return caiu ? 2 : 0
    }

    /// Uma volta da política de pedido de IDR na perda. Chamada a cada `sondagemDePerdaMs`.
    ///
    /// Três decisões cabem aqui, e cada uma tem motivo:
    ///
    /// 1. **Só a subida conta.** O contador é cumulativo; o que interessa é a diferença. Leitura
    ///    que falha não conta como zero — ver `Nucleo.quadrosPerdidos()`.
    /// 2. **Um IDR que chega sozinho apaga o pedido pendente.** Se o GOP do emissor consertou
    ///    dentro da janela de supressão, pedir seria injetar uma rajada de IDR por nada. É a metade
    ///    da supressão que a RFC 4585 não escreve mas que a aritmética do `anomalia-de-sequencia.md`
    ///    exige: os IDR são 69% dos pacotes.
    /// 3. **O piso é sobre o pedido, não sobre a perda.** Uma rajada que produza dez
    ///    `frames_dropped` seguidos vira **um** pedido.
    private func conferirPerda() {
        let agora = Medidas.agoraUs()

        travaDoIdr.lock()
        let idrs = idrsRecebidos
        let quandoIdr = ultimoIdrUs
        travaDoIdr.unlock()
        if perdaPendente, idrs > idrsQuandoPerdeu {
            // A referência voltou — venha o IDR do pedido ou do GOP do emissor.
            semReferenciaMs.append(quandoIdr > perdaDetectadaUs ? (quandoIdr - perdaDetectadaUs) / 1_000 : 0)
            perdaPendente = false
        }

        guard let perdidos = nucleo.quadrosPerdidos() else { return }
        defer { ultimosPerdidos = perdidos }
        guard let antes = ultimosPerdidos else { return }
        if perdidos > antes {
            perdasVistas &+= perdidos - antes
            // A mesma ruptura que dispara o pedido de IDR passa a **condenar a cadeia de
            // referência**. A trava vem aqui, **depois** de `nucleo.quadrosPerdidos()` ter
            // voltado: pegá-la antes e entrar no núcleo fecharia o ciclo contra a thread da
            // libdatachannel, que pede esta trava de dentro do tratador de quadro.
            //
            // A granularidade é a da sondagem, 50 ms — `suspeitos` é um **piso**, e o número real
            // é maior ou igual ao relatado.
            travaDaSuspeita.lock()
            rupturas &+= 1
            if !cadeiaCondenada { condenadaDesdeUs = agora }
            cadeiaCondenada = true
            travaDaSuspeita.unlock()
            if !perdaPendente {
                perdaPendente = true
                pediuPorEstaPerda = false
                perdaDetectadaUs = agora
                idrsQuandoPerdeu = idrs
            }
        }

        guard perdaPendente else { return }
        let piso = pediuPorEstaPerda ? Self.intervaloMinimoDePliUs : Self.pisoDoPrimeiroPedidoUs
        guard ultimoPliUs == 0 || agora - ultimoPliUs >= piso else { return }
        let status = nucleo.pedirIdr()
        ultimoPliUs = agora
        if status == QUALL_STATUS_OK {
            pediuPorEstaPerda = true
            pedidosNaPerda &+= 1
        } else {
            // Não engolir: um pedido recusado é o receptor ficando sem imagem, e o header manda
            // insistir. A próxima volta tenta de novo, e o pendente continua de pé.
            dizer("pedido de IDR na perda recusado: status=\(status.rawValue) \(RegistroSeguro.motivo(Nucleo.ultimoErro()))")
        }
    }

    /// **O caminho de volta do sinal**, a 2 Hz: o que esta casca viu do enlace na janela, contado
    /// ao emissor.
    ///
    /// Sem isto o controlador de taxa do emissor é inerte **por construção** quando quem recebe é
    /// a câmera virtual do macOS — ele nunca recebe amostra e nunca ajusta o bitrate. Em 31/08/2026
    /// o par do usuário mediu exatamente isso do outro lado (`trocas_de_bitrate=0` com 2,95 % de
    /// perda e 881 quadros exibidos com a referência quebrada), porque o relato existia só no
    /// Android.
    ///
    /// **Daqui, e não do tratador de quadro**, por dois motivos que se somam:
    ///
    /// 1. `quall_session_report_link` tem de ser chamada da **mesma thread** que chama
    ///    `quall_session_next_event` — a fronteira não põe cadeado na sinalização. Nesta casca essa
    ///    thread é a deste laço.
    /// 2. Ler contador do núcleo de dentro do tratador **trava**: o núcleo despacha o tratador com
    ///    o cadeado do depacotizador na mão e `quall_track_stats_json` pega o mesmo cadeado. É a
    ///    nota que já está escrita em `ouvirQuadros`, e a leitura da janela obedece a ela ficando
    ///    aqui, ao lado de `conferirPerda()`.
    ///
    /// E `travaDaSuspeita` é solta **antes** de entrar no núcleo, nunca segurada em volta da
    /// chamada: o tratador a pede de dentro do cadeado do depacotizador, então segurá-la aqui e
    /// bloquear no núcleo fecharia o mesmo ciclo ABBA que `conferirPerda()` já evita.
    ///
    /// **Sai sempre, sem sinalizador de bancada.** Nos dois braços de um A/B o mesmo tráfego de
    /// relato precisa estar no ar, senão a diferença entre eles pode ser explicada por ele. Custa
    /// ~129 bytes por janela — 0,05 % de um vídeo de 4 Mbps.
    private func relatarEnlace() {
        let agora = Medidas.agoraUs()
        guard agora &- ultimoEnlaceUs >= Receptor.janelaDoEnlaceMs * 1_000 else { return }
        ultimoEnlaceUs = agora

        travaDaSuspeita.lock()
        let susAcum = suspeitos
        travaDaSuspeita.unlock()
        // Uma leitura só, e ela é própria: `conferirPerda()` lê `frames_dropped` a 20 Hz para o
        // gatilho do PLI, e aproveitar aquele instante aqui amarraria duas cadências diferentes.
        // Custa duas chamadas de FFI por segundo sobre as vinte que já acontecem.
        // Leitura falha do núcleo custa **um tique** e não fecha a janela: fechar com zeros
        // zeraria a âncora, e a janela seguinte entregaria a sessão inteira como dano de 500 ms.
        // Ver `JanelaDoEnlace.acumulados`.
        guard let acum = JanelaDoEnlace.acumulados(nucleo.contadores()) else { return }
        guard let a = janelaDoEnlace.fechar(agoraUs: agora, periodoMs: Receptor.janelaDoEnlaceMs,
                                            vistosAcum: acum.vistos, perdidosAcum: acum.perdidos,
                                            suspeitosAcum: susAcum,
                                            idrsQuebradosAcum: acum.idrsQuebrados)
        else { return }

        dizer(a.linha)
        let status = nucleo.relatarEnlace(ms: a.ms, pacotes: a.pacotes, perdidos: a.perdidos,
                                          suspeitos: a.suspeitos, idrsQuebrados: a.idrsQuebrados)
        if status != QUALL_STATUS_OK, relatosRecusados < 3 {
            relatosRecusados += 1
            // Três vezes e cala. Um emissor de versão antiga não escuta por conta própria e não é
            // defeito nosso; um socket morto aparece no detector de queda que já existe, e não é
            // este relato que decide derrubar sessão.
            dizer("o relato do enlace não saiu: status=\(status.rawValue) \(RegistroSeguro.motivo(Nucleo.ultimoErro()))")
        }
    }

    /// **A porta: um quadro cuja referência foi condenada não vai para a câmera virtual.**
    ///
    /// Ele já foi **decodificado** — parar de alimentar o VideoToolbox dessincronizaria a sessão e
    /// o IDR seguinte chegaria num decodificador com buraco. O que ele não faz é ser empurrado
    /// para o `CMSimpleQueue`.
    ///
    /// A condenação chega **por quadro**, no bit 63 do `sourceFrameRefCon`, e não por uma bandeira
    /// desta classe: esta casca decodifica com `_EnableAsynchronousDecompression`, então esta
    /// função roda numa thread do VideoToolbox e uma bandeira lida aqui pertenceria ao quadro
    /// errado. É a diferença desta casca para os receptores do app iOS e do app macOS.
    private func entregar(_ imagem: CVPixelBuffer, suspeito: Bool) {
        if suspeito {
            travaDaSuspeita.lock(); retidos &+= 1; travaDaSuspeita.unlock()
            return
        }
        guard let encaixado = ajustador.ajustar(imagem) else {
            naoEncaixaram += 1
            return
        }
        if medirFaixa {
            if let valor = Faixa.ler(de: encaixado) {
                let agoraMs = Medidas.agoraUs() / 1_000
                if atrasos.count < 100_000 {
                    atrasos.append((agoraMs &+ Faixa.modulo &- valor) % Faixa.modulo)
                }
            } else {
                semFaixa += 1
            }
        }
        if descricao == nil {
            var d: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: encaixado,
                                                         formatDescriptionOut: &d)
            descricao = d
        }
        guard let descricao else { return }
        var tempo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(Identidade.quadrosPorSegundo)),
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var amostra: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: encaixado,
                                                       formatDescription: descricao,
                                                       sampleTiming: &tempo,
                                                       sampleBufferOut: &amostra) == noErr,
              let amostra else { return }
        if cliente.empurrar(amostra) {
            entregues += 1
            if primeiraImagemUs == 0 { primeiraImagemUs = Medidas.agoraUs() }
        }
    }

    /// Persiste o pareamento, **fundindo** com o que estiver no disco na hora.
    ///
    /// Não é ler-modificar-escrever ingênuo de propósito. A dívida 23 registra o caso ruim: duas
    /// origens do mesmo aparelho gravando o mesmo arquivo, uma atualização perdida, e as duas
    /// ficando com segredos diferentes sob a mesma chave — o que leva direto ao beco sem saída da
    /// dívida 22. `quall_known_peers_merge` faz a união com carimbo, e na colisão vence o mais
    /// recente, que é justamente o que o outro lado guardou.
    ///
    /// Isso **não** dispensa trava entre processos, e aqui não há nenhuma; reduz o estrago.
    /// `esquecer` é o caminho de volta ao PIN quando mesmo assim dessincronizar.
    private func guardarPares() {
        let noDisco = try? String(contentsOf: arquivoDePares, encoding: .utf8)
        guard let daSessao = nucleo.paresConhecidos(base: noDisco) else {
            dizer("o núcleo não devolveu estado de pareamento para gravar")
            return
        }
        let fundido = Nucleo.fundirPares(noDisco, daSessao) ?? daSessao
        // Escrita atômica: um arquivo pela metade é pior que arquivo nenhum, porque o núcleo
        // recusa o JSON e o produto passa a pedir PIN sem dizer por quê.
        do {
            try fundido.write(to: arquivoDePares, atomically: true, encoding: .utf8)
            dizer("pareamento gravado (\(fundido.count) bytes); conteúdo e caminho omitidos")
        } catch {
            dizer("não deu para gravar o pareamento: \(RegistroSeguro.erro(error))")
        }
    }

    private func relatar() {
        dizer("recebidos=\(decodificador.recebidos) decodificados=\(decodificador.decodificados) recusados=\(decodificador.recusados) sem_parametros=\(decodificador.semParametros) entregues=\(entregues) descartados=\(cliente.descartados) dim=\(decodificador.largura)x\(decodificador.altura) pegada=\(Medidas.pegadaDeMemoria())")
        // **A perda, a cada volta, e com os três números juntos.** Antes de 29/08 ela só aparecia
        // no fim da corrida e só como JSON cru, onde o teto (`packets_missing`) era lido como se
        // fosse perda. Ler contador aqui custa uma chamada de FFI por segundo e não atravessa o
        // caminho do quadro — ver `Nucleo.contadores()`.
        dizer(ResumoDePerda.formatar(nucleo.contadores()))
        // **Os cinco números que esta casca não tinha**, com os nomes do contrato. Os de cima
        // dizem se o quadro chegou; estes dizem se a imagem dele tinha **como** estar certa.
        travaDaSuspeita.lock()
        let r = rupturas, sus = suspeitos, pr = max(piorRajada, suspeitosNaRajada), ret = retidos
        travaDaSuspeita.unlock()
        dizer("rupturas=\(r) suspeitos=\(sus) pior_rajada=\(pr) retidos=\(ret) "
              + "congelar=\(Receptor.congelarNaRuptura ? "sim" : "NAO") "
              + "sem_referencia_ms=\(Receptor.resumo(semReferenciaMs))")
        // **A fluidez**, que é a pergunta que `entregues` não responde. O contador acima diz
        // **quantos** quadros saíram; este diz o **intervalo entre um e o seguinte**, que é o que
        // um consumidor sente. Numa corrida de seis câmeras num MacBook, `entregues` e a CPU
        // disseram os dois "o host aguentou" enquanto o Dell, na mesma carga, empilhava 87
        // estouros de fila. O custo do host mora na cauda. Ver `Fluidez`.
        dizer(cliente.linhaDeFluidez)
    }

    /// Identidade estável deste Mac para o pareamento. É o que o `DeviceId` do contrato vincula —
    /// não o nome, que o usuário troca.
    private func identidadeDoAparelho() -> String {
        let chave = "br.com.queven.quall.camera.deviceId"
        if let existente = UserDefaults.standard.string(forKey: chave) { return existente }
        let novo = UUID().uuidString.lowercased()
        UserDefaults.standard.set(novo, forKey: chave)
        return novo
    }
}
