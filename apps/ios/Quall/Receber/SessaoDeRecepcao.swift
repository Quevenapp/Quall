// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Combine
import Foundation

/// O caminho de produto inteiro, num objeto: rede → decode → tela.
///
/// `quall_connect` → `quall_session_next_track` → `quall_track_on_frame` → `VTDecompressionSession`
/// → `AVSampleBufferDisplayLayer`. Roda inteiro numa thread própria; a interface só lê o [Painel] e
/// chama [parar].
///
/// É o gêmeo do `ReceptorSessao.kt` do Android, e as decisões que ele tomou valem aqui pelos mesmos
/// motivos:
///
/// - **Uma thread só toca a fronteira C.** `quall_session_next_track` e `quall_session_next_event`
///   avançam estado e o header exige thread única. Aqui vêm as duas deste laço.
/// - **Pedir IDR ao entrar não é otimização.** O primeiro quadro depois de a track abrir se perde
///   em cerca de metade das corridas (dívida 25), e a recuperação desenhada é o PLI. Um receptor
///   que não pede espera o próximo IDR natural do emissor — com GOP de 1 s, meio segundo em média;
///   com GOP longo, para sempre.
/// - **Repetir o pedido enquanto não há imagem.** O IDR de entrada pode ter se perdido junto com o
///   primeiro quadro, que é exatamente o caso que a dívida 25 descreve.
final class Painel: ObservableObject {
    /// `pedindoPermissao` e `permissaoNegada` entraram em 2026-08-27, e são a fase que o receptor
    /// **não tinha** enquanto o emissor tinha desde sempre (`Emissor.Fase.pedindoPermissao`). Ver
    /// `PermissaoDeRedeLocal` para o defeito que a ausência delas produziu.
    enum Fase: String {
        case parado, pedindoPermissao, permissaoNegada, conectando, esperandoTrack, exibindo, erro
    }

    @Published var fase: Fase = .parado
    /// O aviso da tela de conexão, **já no idioma da interface**. Só muda por `dizer`, que guarda
    /// também como refazê-lo: o painel é da `Recepcao` e vive mais que a tela, e um aviso guardado
    /// de antes de trocar o idioma (`Idioma.mudou`) é refeito no idioma novo, e não fica no antigo.
    @Published private(set) var mensagem = ""
    private var fazerMensagem: () -> String = { "" }
    private var observadorDoIdioma: NSObjectProtocol?

    init() {
        observadorDoIdioma = NotificationCenter.default.addObserver(
            forName: Idioma.mudou, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.mensagem = self.fazerMensagem()
        }
    }

    deinit {
        if let observadorDoIdioma { NotificationCenter.default.removeObserver(observadorDoIdioma) }
    }

    /// Troca o aviso. `fazer` monta o texto com `tr(...)` e é chamado de novo a cada troca de idioma
    /// (na fila principal, como toda escrita no painel).
    func dizer(_ fazer: @escaping () -> String) {
        fazerMensagem = fazer
        mensagem = fazer()
    }

    /// Apaga o aviso.
    func calar() { dizer { "" } }
    @Published var endereco = ""
    @Published var par = ""
    @Published var pareamentoNovo = false
    @Published var rotuloDaTrack = ""
    @Published var podeGravarVideo = false
    @Published var dimensao = ""
    @Published var perfil = ""
    @Published var primeiraImagemMs: Double = 0
    @Published var primeiroIdrMs: Double = 0
    @Published var recebidos: UInt64 = 0
    /// Quadros que a camada de exibição **aceitou** — não pixels confirmados no vidro.
    /// Renomeado de `exibidos` em 2026-08-28; ver o cabeçalho de `Exibidor`.
    @Published var enfileirados: UInt64 = 0
    @Published var fps: Double = 0
    @Published var decodeP50Ms: Double = 0
    @Published var decodeP95Ms: Double = 0
    @Published var marcasCertas: UInt64 = 0
    @Published var marcasErradas: UInt64 = 0
    @Published var contadoresDoNucleo = "{}"
    /// A perda em uma linha: exata, teto e tarde demais juntos. Ver ``ResumoDePerda``.
    ///
    /// Campo próprio, e não algo que a tela derive de ``contadoresDoNucleo``, porque os dois vêm
    /// da **mesma** leitura de contadores: derivar na tela abriria a porta para a linha e o JSON
    /// serem de instantes diferentes, que é a razão de `rtp::Contadores` existir no núcleo.
    @Published var resumoDePerda = ""

    // --- por que a tela está preta, **na própria tela** ----------------------------------------
    //
    // Estes quatro já existiam na linha de `os_log` e **não** existiam no rodapé. A consequência
    // está fotografada em `docs/tela-preta.md` §1: uma tela preta com `recebidos 68 · exibidos 0`
    // e nada que dissesse de qual dos lados vinha o defeito. Três pessoas leram aquela foto e as
    // três foram para o lado errado do fio.
    //
    // Com `idrs` e `sem_parametros` à vista, a mesma foto se responde sozinha: `idrs 0` acusa o
    // **emissor**, que não mandou conjunto de parâmetros nenhum; `falhas_sessao > 0` acusa o
    // **receptor**, e o `OSStatus` diz por quê. É a mesma lição do `camada=0x0` da §6.0 — o
    // número que teria respondido a frente na primeira leitura pertence ao lugar onde alguém olha.
    @Published var idrs: UInt64 = 0

    // --- a imagem que estava errada e não aparecia em tela nenhuma -----------------------------
    //
    // **Estes cinco existiam só na linha de relato, e isso não bastava.** Em 31/08/2026, com os
    // contadores já medindo certo no log, o usuário olhou para o iPad no meio de uma corrida com
    // 1,27 % de perda — 33 rupturas, 124 quadros suspeitos, pior rajada de 26 — e disse:
    // *"continua falhando e 0 falhas"*. Ele estava certo: a **tela** continuava dizendo zero,
    // porque o painel não carregava nenhum destes números.
    //
    // A queixa original dele era literalmente sobre a tela — *"em nenhuma tela aparece nos
    // contadores falhas, sempre é 0"*. Uma medida que existe no log e não chega ao vidro não
    // responde a essa queixa.
    @Published var rupturas: UInt64 = 0
    @Published var suspeitos: UInt64 = 0
    @Published var piorRajada: UInt64 = 0
    @Published var retidos: UInt64 = 0
    /// `[n p50 p95 max]` já formatado — a cauda é o dano, e um número só a esconderia.
    @Published var semReferenciaMs = "[n=0]"
    @Published var semParametros: UInt64 = 0
    @Published var falhasDeSessao: UInt64 = 0
    @Published var ultimaFalha: Int32 = 0
    /// Só na tela do PIN: `quall_last_status()` disse `NEEDS_PIN`, que **não é recusa**.
    @Published var precisaDePin = false
    /// A falha foi diagnosticada como **permissão de Rede Local**, não como rede. A tela usa isto
    /// para oferecer o botão que abre os Ajustes — sem ele, a mensagem certa ainda deixaria a
    /// pessoa procurando o painel sozinha.
    @Published var precisaDeRedeLocal = false

    // --- áudio ---------------------------------------------------------------------------------
    //
    // Vazio quando a sessão não trouxe track de áudio, que é **toda** sessão que este projeto já
    // mediu — nenhuma casca mandava áudio para o iOS antes desta rodada. Uma linha vazia no rodapé
    // é a resposta certa para "não havia áudio", e é distinguível de "havia e não tocou", que é
    // uma linha com zeros.
    @Published var audio = ""
}

/// Se o receptor segura o quadro cuja referência foi condenada, em vez de mandá-lo para a tela.
///
/// **Isto é um interruptor e não uma constante porque a pergunta que falta é de olho, não de
/// contador.** Está medido que a porta retém exatamente os quadros que `suspeitos` acusa; se a
/// tela fica *melhor* para quem assiste, nenhum número deste projeto responde. O usuário pediu
/// para comparar as duas metades, e comparar exige poder virar a chave **na mesma sessão, com o
/// mesmo enlace e o mesmo conteúdo** — duas corridas seguidas num rádio de 2,4 GHz não são
/// comparáveis entre si, como esta bancada já mediu à própria custa.
///
/// `--congelar` liga na linha de lançamento; `--sem-congelar` é o padrão desde 31/08 e continua
/// aceito para quem já o escrevia. O interruptor da tela muda daí em diante.
///
/// A trava não é zelo: quem escreve é a thread da interface e quem lê é a thread de mídia, uma vez
/// por quadro. `NSLock` a 30 Hz não custa nada e uma corrida de dados aqui produziria exatamente o
/// tipo de defeito que ninguém reproduz.
enum Congelamento {
    private static let trava = NSLock()
    // **Nasce DESLIGADA, e isso é uma reversão medida, não uma escolha de gosto.**
    //
    // Ela entrou ligada por padrão com o argumento de que todo produto de espelhamento congela o
    // último quadro bom e espera o IDR, em vez de mostrar lixo. O argumento tem uma premissa
    // escondida: **que o IDR chega.** Em 31/08/2026, com o A10s espelhando a tela real para o
    // iPad em 2,4 GHz, o usuário filmou a bancada e disse "terrível". Os números da própria tela
    // dizem por quê:
    //
    // - o emissor mandou **31 IDR** e o receptor viu **13** — 58 % dos quadros de recuperação
    //   foram destruídos pela mesma perda que eles existem para consertar;
    // - `sem_referencia_ms [n=8 p50=1959 p95=2083 max=2083]` — **todos** os intervalos terminaram
    //   na válvula de 2 s. Nenhum terminou porque a imagem se curou;
    // - `fps` na tela: **0,0**. Com a porta ligada e nenhum IDR chegando, a imagem simplesmente
    //   para.
    //
    // Com a fonte sintética desta bancada, cujo IDR tem 3 pacotes, a mesma perda dá
    // `[n=33 p50=109 p95=825 max=926]` e a cadeia **se cura**. A diferença entre "a porta
    // funciona" e "a porta congela a tela" é o tamanho do IDR, não a política.
    //
    // Então ela fica **desligada até a entrega do IDR sobreviver à perda**. O interruptor continua
    // na tela e os contadores continuam contando dos dois lados: `suspeitos` não depende da porta.
    // Quando alguém consertar a recuperação — refresh intra gradual, fatias menores, FEC ou
    // retransmissão —, este padrão se reabre com uma medida, do mesmo jeito que fechou.
    private static var ligado = ProcessInfo.processInfo.arguments.contains("--congelar")

    static var ativo: Bool {
        trava.lock(); defer { trava.unlock() }
        return ligado
    }

    static func definir(_ valor: Bool) {
        trava.lock(); ligado = valor; trava.unlock()
        Diario.dizer("porta de congelamento: \(valor ? "ligada" : "desligada") (interruptor da tela)")
    }
}

final class SessaoDeRecepcao {

    // Prazos, todos nomeados. Os quatro primeiros são os mesmos do receptor Android, de propósito:
    // se um deles estiver errado, é melhor que esteja errado igual nos dois e o defeito apareça
    // duas vezes do que ficar escondido numa plataforma só.
    private static let prazoDeConexaoMs: UInt32 = 30_000
    private static let prazoDaPrimeiraTrackMs: UInt32 = 15_000
    private static let insistirIdrMs: UInt64 = 3_000
    private static let repetirIdrMs: UInt64 = 700

    /// A chave da folga de exibição nas preferências — escrita pela tela de conexão, lida no começo
    /// de cada sessão. Em milissegundos; zero é sem folga. Ver `Exibidor`.
    static let chaveDaFolga = "recepcao.folga_ms"

    /// **A folga padrão: 50 ms**, desde 11/09/2026. O usuário comparou no iPhone X, com conteúdo que
    /// se move pelo Core Animation: "nenhuma × 30 ms, pouca diferença; nenhuma × 50 ms, bastante
    /// diferença". Com 50 ms somem as pausas do aparelho e quase todas as da rede (I1–I4 em
    /// `docs/tela-estendida.md`). Custa 50 ms a mais na tela; o seletor fica para quem preferir menos.
    static let folgaPadraoMs = 50

    /// A folga desta sessão: a escolhida na tela de conexão, ou a padrão se ninguém escolheu ainda.
    static func folgaEscolhidaMs() -> Int {
        (UserDefaults.standard.object(forKey: chaveDaFolga) as? Int) ?? folgaPadraoMs
    }
    private static let silencioAteDesistirMs: UInt64 = 10_000

    /// Período da janela do enlace, em ms — a cadência com que o receptor conta ao emissor o que
    /// viu.
    ///
    /// **500 ms, e não é escolha livre**: é a janela contra a qual a política do controlador de
    /// taxa foi medida (`quall_core::taxa`, e a curva de resposta em `docs/taxa-que-escuta.md`).
    /// Alimentar o controlador com uma janela diferente da que produziu a curva é projetá-lo
    /// contra outra curva. O receptor Android usa a mesma, de propósito.
    private static let janelaDoEnlaceMs: UInt64 = 500

    /// Os três acumulados do núcleo que a janela do enlace precisa, do JSON de estatísticas.
    ///
    /// `packets_lost_for_real` e **não** `packets_missing_upper_bound`: o segundo cobra
    /// reordenação como perda, e foi lido como perda em todas as medições desta bancada até
    /// 29/08/2026 — de 1,3× a 44× de inflação. Um controlador alimentado por ele reduziria o
    /// bitrate por causa de pacotes que chegaram.
    ///
    /// # Leitura falha devolve `nil`, e a janela **não** é fechada
    ///
    /// Esta função devolvia zeros. Parecia inofensivo: o delta de um acumulado que não se moveu é
    /// zero, e uma janela de `pacotes=0` é descartada pelo controlador, que exige
    /// `pacotes_minimos`. O dano não está nessa janela — está na **seguinte**. Zerar aqui zera a
    /// âncora de `JanelaDoEnlace`, e a janela seguinte entrega como dano de 500 ms tudo o que a
    /// sessão acumulou desde o começo. O controlador soma `pacotes` e `perdidos` ao longo de um
    /// trecho (`ControladorDeTaxa::pacotes_desde_a_mudanca`), e uma janela dessas domina o trecho
    /// inteiro: é a integral entrando pela porta que existe para entregar a derivada.
    ///
    /// `nil` custa **um tique**. A âncora fica de pé, a janela seguinte mede o intervalo maior e o
    /// `ms` real diz isso em voz alta. As quatro cascas receptoras concordam nisto.
    static func doEnlace(_ json: String) -> (UInt64, UInt64, UInt64)? {
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

    /// Por quanto tempo, no máximo, a tela fica congelada esperando um IDR depois de uma ruptura.
    ///
    /// A válvula existe porque **um emissor que não reinjeta IDR sob pedido existe de verdade
    /// nesta bancada** — `docs/matriz-ios.md` mediu o `quall-app.exe` de 27/08 pondo um único IDR
    /// na sessão inteira contra 54 pedidos. Contra um emissor assim, congelar sem prazo trocaria
    /// uma imagem suja por uma imagem parada, que é pior. 2 s é o dobro do intervalo entre
    /// pedidos de IDR (`repetirIdrMs` = 700 ms) com folga para o ida e volta.
    private static let congelarNoMaximoMs: UInt64 = 2_000

    /// Se a porta de congelamento está ligada. `--sem-congelar` a desliga, e o comportamento antigo
    /// — exibir todo quadro decodificado, com referência condenada ou não — volta inteiro.
    ///
    /// Existe como sinalizador, e não como constante, porque a bancada deste projeto mede porta
    /// ligada contra porta desligada em vez de argumentar. Ver `docs/quinta-porta.md`.
    static var congelarNaRuptura: Bool { Congelamento.ativo }

    /// `n`, `p50`, `p95` e `max` de uma lista de durações em microssegundos, em milissegundos.
    ///
    /// Quatro números e não um: `docs/regras-de-frente.md` já pagou por relatórios que mostravam
    /// média de latência e escondiam a cauda. Numa medida de dano visual a cauda **é** o dano — um
    /// p50 de 30 ms com um máximo de 2 000 ms é uma sessão em que a pessoa viu a tela travar.
    static func resumo(_ us: [UInt64]) -> String {
        guard !us.isEmpty else { return "[n=0]" }
        let ms = us.map { Double($0) / 1000 }.sorted()
        func q(_ p: Double) -> Double { ms[min(ms.count - 1, Int(p * Double(ms.count - 1) + 0.5))] }
        return String(format: "[n=%d p50=%.0f p95=%.0f max=%.0f]", ms.count, q(0.5), q(0.95), ms[ms.count - 1])
    }

    /// O valor de `PermissaoDeRedeLocal.jaTentouNaLan` **antes** desta tentativa.
    ///
    /// Tem de ser lido antes, porque a própria tentativa marca o registro: lido depois, seria
    /// sempre `true` e o estado "nunca pediu" nunca seria reconhecido.
    private var jaTinhaTentadoNaLan = false

    private let nucleo = NucleoReceptor()
    private let painel: Painel
    let exibidor: Exibidor
    private var decodificador: DecodificadorH264?
    private var thread: Thread?
    private let gravador: GravadorDoReceptor?
    private let travaDaGravacao = NSLock()
    private var gravacaoQuerIdr = false

    // --- o lado do som -------------------------------------------------------------------------
    //
    // Os três nascem `nil` e continuam `nil` numa sessão sem áudio, que é o caso de tudo o que
    // esta bancada já mediu. Nada aqui roda antes de uma track de áudio existir — nem a sessão de
    // áudio do iOS é aberta, o que importa: abri-la interromperia a música de quem só queria ver
    // uma tela espelhada.
    private var decodificadorDeAudio: DecodificadorDeAudio?
    private var saidaDeAudio: SaidaDeAudio?
    private var presetDeAudio: PresetDeAudioLido?
    /// A conferência do fio, feita **uma vez**, no primeiro pacote de verdade. Ver
    /// `conferirPrimeiroPacoteOpus`. PCMU nunca é inspecionado como Opus.
    private var conferiuOFio = false
    /// O Goertzel sobre o PCM decodificado. **Contador antes de artefato**: ele responde se
    /// chegou *som* — e não só bytes — sem guardar uma amostra sequer. Ver `AnalisadorDeTom`.
    private var analisadorDeTom: AnalisadorDeTom?

    // --- a janela da taxa de quadros ----------------------------------------------------------
    //
    // A taxa era `enfileirados / (agora - subiuEm)` — uma **média desde o começo da sessão**, que
    // não sabe cair. Um espelhamento que travasse aos 10 s de uma sessão de 60 s continuaria
    // exibindo cinco sextos da taxa nominal, e a tela diria que está tudo bem.
    //
    // Passa a ser a taxa **da última volta**: quantos quadros entraram na camada desde o relato
    // anterior, dividido pelo tempo entre os dois. Com o relato a 1 Hz, é a taxa do último
    // segundo — que é a grandeza que alguém olhando para a tela pensa estar lendo.
    private var relatoAnteriorUs: UInt64 = 0
    private var enfileiradosNoRelatoAnterior: UInt64 = 0
    /// O contador de UDP do aparelho no começo da sessão — ver `UDPDoAparelho`.
    private var udpNoInicio: UDPDoAparelho.Leitura?
    private var udpIndisponivelDito = false

    // --- onde o pareamento mora, depois da unificação -----------------------------------------
    //
    // **Era `Application Support/Quall/pares.json` deste app; passou a ser o `pares.json` do App
    // Group**, o mesmo arquivo que a appex escreve quando um pareamento fecha do lado que emite.
    //
    // Isto não é arrumação: era um defeito de produto que só existia por causa dos dois apps. Com
    // `br.com.queven.quall` e `br.com.queven.quall.receptor` separados, o mesmo aparelho físico
    // tinha **dois** pareamentos com o mesmo par — parear para espelhar não valia para exibir, e
    // `docs/fluxo-de-uso.md` promete o contrário ("PIN uma vez por par de aparelhos, nunca por
    // sessão"). Num app só, um arquivo só.
    //
    // E vem de graça a coordenação que este arquivo não tinha: `Compartilhado.atualizarPares` faz
    // a leitura-modificação-escrita **dentro** de um `NSFileCoordinator`, que é a barreira contra
    // a corrida entre o app e a appex descrita em `Compartilhado.swift`. A versão anterior deste
    // arquivo lia e escrevia direto, sem coordenação nenhuma — o que era correto quando o
    // processo era único e deixaria de ser agora.

    /// **O controle remoto da câmera de quem filma** (R9b): a tela segue a câmera desta sessão por
    /// ele. `nil` só nos testes de bancada que montam a sessão sem tela.
    private let cameraRemota: ControleRemotoDaCamera?

    init(painel: Painel, exibidor: Exibidor, cameraRemota: ControleRemotoDaCamera? = nil,
         gravador: GravadorDoReceptor? = nil) {
        self.painel = painel
        self.exibidor = exibidor
        self.cameraRemota = cameraRemota
        self.gravador = gravador
    }

    // --- o controle remoto da câmera (R9b) ------------------------------------------------------

    /// O `QuallCameraRemote` desta sessão e o canal de mensagens dela. Só nesta thread.
    private var camera: (remota: CameraRemotaDaSessao, mensagens: OpaquePointer)?
    private var ultimoEstadoDaCameraUs: UInt64 = 0

    /// Abre o controle da câmera do outro lado, **numa sessão de vídeo**: o canal de mensagens da
    /// sessão (o leitor dele é a bombeada; ninguém mais lê, contrato §2) e um `QuallCameraRemote`
    /// novo. Um filmador de build anterior nunca responde, e os controles não aparecem (§9).
    private func abrirCamera() {
        guard let tela = cameraRemota, camera == nil else { return }
        guard let r = CameraRemotaDaSessao() else { return }
        guard let m = nucleo.abrirMensagens() else {
            Diario.dizer("câmera remota: o núcleo não deu o handle de mensagens; sem controle da câmera nesta sessão")
            return
        }
        camera = (r, m)
        tela.seguir(r)
        Diario.dizer("câmera remota: bombeada de pé (ola a cada 1 s até o filmador responder)")
    }

    /// Uma bombeada: o `ola`, o pedido devido, o que chegou. Com mudança (ou a cada meio segundo, para
    /// a recusa sumir perto dos 3 s), a tela relê o estado. `prazoMs` 0 a 250. Devolve `false` se a sessão
    /// fechou ou a bombeada quebrou (a câmera sai de cena; a sessão de vídeo segue).
    @discardableResult
    private func bombearCamera(prazoMs: UInt32) -> Bool {
        guard let (r, m) = camera else { return false }
        let (st, mudou) = r.bombear(m, prazoMs: prazoMs)
        let agora = Medidas.agoraUs()
        if mudou != 0 || Medidas.delta(agora, ultimoEstadoDaCameraUs) >= 500_000 {
            ultimoEstadoDaCameraUs = agora
            cameraRemota?.atualizar(de: r)
        }
        if st != QUALL_STATUS_OK {
            if st != QUALL_STATUS_CLOSED {
                Diario.dizer("câmera remota: a bombeada falhou (\(NucleoReceptor.nome(st))); sem controle da câmera")
            }
            fecharCamera()
            return false
        }
        return true
    }

    /// O fim: uma bombeada final com prazo zero, o handle liberado, e a tela sem controles.
    private func fecharCamera() {
        guard let (r, m) = camera else { return }
        camera = nil
        _ = r.bombear(m, prazoMs: 0)
        quall_messages_free(m)
        cameraRemota?.soltar(r)
    }

    // --- controle ----------------------------------------------------------------------------

    /// Até quando a sessão roda. **`segundos <= 0` é sem prazo**: é o que a tela de exibir passa
    /// desde 10/09/2026, e o que faz do iPhone um monitor — a sessão acaba quando o emissor sai ou
    /// quando a pessoa toca em Parar. Até então a tela passava 40 s fixos, sobra da bancada, e a
    /// tela estendida do Mac caía sozinha aos 40,1 s no iPhone X do usuário. As corridas
    /// automáticas continuam com prazo (`--segundos`), que é o que faz a linha `FIM` sair sozinha.
    static func prazo(segundos: Double, agoraUs: UInt64 = Medidas.agoraUs()) -> UInt64 {
        guard segundos > 0, segundos.isFinite else { return UInt64.max }
        return agoraUs &+ UInt64(segundos * 1_000_000)
    }

    func iniciar(endereco: String, pin: String?, segundos: Double) {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.correr(endereco: endereco, pin: pin, segundos: segundos) }
        t.name = "quall.receptor"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func parar() { nucleo.parar() }

    private func publicar(_ mudanca: @escaping (Painel) -> Void) {
        DispatchQueue.main.async { [painel] in mudanca(painel) }
    }

    // --- a corrida ---------------------------------------------------------------------------

    private func correr(endereco: String, pin: String?, segundos: Double) {
        defer { thread = nil }
        gravador?.preparar { [weak self] in
            guard let self else { return }
            self.travaDaGravacao.lock(); self.gravacaoQuerIdr = true; self.travaDaGravacao.unlock()
        }

        publicar { $0.fase = .conectando; $0.endereco = endereco; $0.precisaDePin = false
                   $0.podeGravarVideo = false
                   $0.precisaDeRedeLocal = false
                   $0.dizer { pin == nil ? tr("retomando pareamento…") : tr("conectando e pareando…") } }

        let pares = Compartilhado.lerPares()

        // **Antes de conectar, e nesta ordem.** `quall_connect` é o tráfego que faz o iOS criar a
        // linha deste app no painel de Rede Local; registrar isso agora é o que permite, numa
        // falha futura, saber se a pessoa já tem um interruptor para ligar ou se ela ainda vai ver
        // o diálogo pela primeira vez. Só conta para endereço da LAN: conectar a um endereço
        // público não cria linha nenhuma.
        jaTinhaTentadoNaLan = PermissaoDeRedeLocal.jaTentouNaLan
        if PermissaoDeRedeLocal.enderecoEhDaRedeLocal(endereco) {
            PermissaoDeRedeLocal.marcarQueTentouNaLan()
        }

        Diario.dizer("conectando\(pin == nil ? " sem PIN (par conhecido)" : " com PIN")"
                     + "\(jaTinhaTentadoNaLan ? "" : " — primeira vez desta instalação na rede local")…")
        let inicioDaConexao = Medidas.agoraUs()

        guard nucleo.conectar(endereco: endereco,
                              pin: pin,
                              // **A mesma identidade dos dois papéis.** Antes o receptor tinha
                              // `ios-rx-…` e nome `rx-ios-…` próprios, porque era outro app com
                              // outro bundle id. Um aparelho é um aparelho: o `device_id` e o
                              // nome são os do App Group, os mesmos que a tela de espera mostra
                              // e que a appex anuncia.
                              deviceId: Identidade.deviceId,
                              nome: Identidade.nome,
                              paresConhecidos: pares,
                              prazoMs: SessaoDeRecepcao.prazoDeConexaoMs,
                              tela: Identidade.telaNativa) else {
            explicarFalhaDeConexao(endereco: endereco)
            nucleo.encerrar()
            return
        }

        let subiuEm = Medidas.agoraUs()

        // **O `Exibidor` vive o processo; esta sessão, não.** Sem este zeramento os contadores
        // dele carregam o resíduo de toda tentativa anterior no mesmo lançamento do app, e o
        // rodapé passa a comparar um numerador de vida-do-processo com um `recebidos` de
        // vida-da-sessão. Foi o que produziu `recebidos 639 · enfileirados 1749 · 77,4 fps` numa
        // origem de 30 fps. Ver o cabeçalho de `Exibidor`.
        // A folga de exibição é da tela de conexão (`TelaDeRecepcao`), lida uma vez por sessão.
        // Ver `Exibidor`, "a folga de exibição".
        let folgaMs = SessaoDeRecepcao.folgaEscolhidaMs()
        exibidor.reiniciar(folgaMs: folgaMs)
        Diario.dizer(folgaMs > 0
                     ? "folga de exibição: \(folgaMs) ms — cada quadro na tela no ritmo do carimbo"
                     : "folga de exibição: nenhuma — cada quadro na tela assim que decodifica")
        relatoAnteriorUs = 0
        enfileiradosNoRelatoAnterior = 0
        udpNoInicio = UDPDoAparelho.ler()

        let msDaConexao = Double(Medidas.delta(subiuEm, inicioDaConexao)) / 1000
        let par = nucleo.nomeDoPar
        let novo = nucleo.pareamentoNovo()
        Diario.dizer(String(format: "sessão de pé em %.1f ms; pareamento %@",
                            msDaConexao, novo ? "novo (PIN digitado)" : "retomado"))

        // Gravado **agora**, e não no fim: se a sessão cair, o pareamento que já aconteceu não pode
        // se perder — era exatamente esse o defeito do PIN pedido toda vez.
        guardarPares()

        publicar { $0.fase = .esperandoTrack; $0.par = par; $0.pareamentoNovo = novo
                   $0.dizer { tr("esperando a track do emissor…") } }

        guard let (rotulo, tipo) = nucleo.esperarTrack(prazoMs: SessaoDeRecepcao.prazoDaPrimeiraTrackMs) else {
            let cancelado = nucleo.parou
            // **Sessão só de áudio.** `esperarTrack` devolve `nil` quando o vídeo não vem — mas
            // ele pode ter adotado uma track de som no caminho, e aí a sessão não é vazia: é uma
            // sessão de som. Tratá-la como falha foi o que aconteceu na primeira corrida do laço
            // de áudio em 30/08, com o log dizendo as duas coisas em sequência ("track de áudio
            // adotada antes do vídeo" e, 15 s depois, "não abriu nenhuma track de mídia").
            //
            // Não é só bancada: um emissor que ofereça só som é uma sessão legítima do protocolo,
            // e um receptor que a recusasse estaria recusando algo que o núcleo entrega.
            if !cancelado, let audio = nucleo.audioAdotada {
                correrSoAudio(rotulo: audio.rotulo, especie: audio.tipo, par: par,
                              endereco: endereco, segundos: segundos, subiuEm: subiuEm)
                return
            }
            // O diário fica com o português; a tela, no idioma da interface.
            let motivo = cancelado ? "cancelado" : "\(par) conectou mas não abriu nenhuma track de mídia"
            Diario.dizer(motivo)
            publicar { $0.fase = cancelado ? .parado : .erro
                       $0.dizer { cancelado ? tr("cancelado")
                                            : tr("%@ conectou mas não abriu nenhuma track de mídia", par) } }
            desmontar()
            return
        }
        let nomeDaTrack = rotulo.isEmpty ? (tipo == QUALL_TRACK_KIND_CAMERA ? "câmera" : "tela") : rotulo
        Diario.dizer("track recebida (kind=\(tipo.rawValue))")
        publicar { $0.podeGravarVideo = true }
        // O rótulo que o emissor deu vai como veio; só o nome padrão segue o idioma da interface.
        let nomeNaTela = rotulo.isEmpty
            ? (tipo == QUALL_TRACK_KIND_CAMERA ? tr("câmera") : tr("tela")) : rotulo
        publicar { $0.fase = .exibindo; $0.rotuloDaTrack = nomeNaTela; $0.calar() }

        // --- o decodificador e o tratador de quadro -------------------------------------------
        var primeiraImagemUs: UInt64 = 0
        /// Quantos quadros o núcleo já havia descartado na volta anterior. A diferença entre duas
        /// voltas é o que dispara o pedido de IDR — ver o comentário no laço.
        var descartadosNaUltimaVolta: UInt64 = 0
        var ultimaChegadaUs = Medidas.agoraUs()
        let travaDoTempo = NSLock()
        var marcasCertas: UInt64 = 0
        var marcasErradas: UInt64 = 0
        var marcasRepetidas: UInt64 = 0
        var marcasAusentes: UInt64 = 0
        var ultimaMarca = -1

        // -----------------------------------------------------------------------------------
        // **A testemunha que faltava: quadro exibido com a referência quebrada.**
        //
        // Todo contador desta casa conta **entrega** — `recebidos`, `enfileirados`,
        // `decodificados`, `packets_lost_for_real`, `frames_dropped`. Nenhum conta se a imagem
        // exibida está **certa**. Um quadro P que chega inteiro, decodifica sem erro e sai
        // visualmente podre — porque a referência dele foi descartada por uma perda anterior —
        // conta como sucesso em **todas** as linhas. É exatamente o que o olho vê como "a imagem
        // está falhando" e o relatório vê como "0 falhas".
        //
        // O mecanismo já estava escrito neste arquivo desde 28/08, no comentário do pedido de IDR
        // do laço: *"o decodificador segue decodificando quadros P contra uma referência que nunca
        // chegou: retângulos velhos ficam parados atrás do que se move — o rastro que o usuário
        // fotografou"*. O que se fez naquele dia foi consertar a **recuperação** (pedir IDR quando
        // o núcleo acusa descarte). O que nunca se fez foi **contar** os quadros exibidos nesse
        // intervalo, nem **deixar de exibi-los**.
        //
        // - `rupturas`: quantas vezes a cadeia de referência foi quebrada (o núcleo descartou
        //   quadro desde a volta anterior).
        // - `suspeitos`: quantos quadros chegaram **depois** de uma ruptura e **antes** do próximo
        //   IDR. São os quadros cuja imagem é provavelmente errada.
        // - `pior_rajada`: o maior número de suspeitos seguidos, que é a duração do pior rastro.
        // - `retidos`: quantos deles a política de congelamento impediu de ir para a tela.
        //
        // **Isto não é a régua, e não substitui a régua — mas cobre o que ela não vê.** A régua lê
        // quatro blocos chapados de 64x64 num canto: um quadro cujo canto veio certo e cujo resto
        // está sujo é contado por ela como `certa`. Medido nesta bancada em 2026-08-31, numa
        // corrida com **116 pacotes perdidos de verdade (1,272 %), 119 anomalias de sequência e 23
        // quadros descartados**, a régua reportou `marca_erradas=0`. Ela é honesta sobre o que
        // mede — identidade do quadro — e cega para corrupção fora do canto.
        var cadeiaCondenada = false
        var rupturas: UInt64 = 0
        var suspeitos: UInt64 = 0
        var suspeitosNaRajada: UInt64 = 0
        var piorRajada: UInt64 = 0
        var retidos: UInt64 = 0
        var condenadaDesdeUs: UInt64 = 0
        /// Quanto tempo cada intervalo "sem referência utilizável" durou, em microssegundos.
        ///
        /// O contador de quadros diz **quantos** saíram errados; este diz **por quanto tempo** a
        /// tela ficou errada, que é a grandeza que a pessoa sente. O receptor Android já publica
        /// um `sem_referencia_ms` — foi ele que mostrou 10 162 ms de mediana antes da quinta porta
        /// — e esta casca não tinha nada equivalente. Agora tem, com o mesmo nome, de propósito.
        var duracoesSemReferenciaUs: [UInt64] = []
        /// A derivada do dano, que é o que atravessa até o emissor. Ver `JanelaDoEnlace`.
        var janelaDoEnlace = JanelaDoEnlace()
        var ultimoEnlaceUs: UInt64 = 0
        var relatosRecusados = 0
        /// Lido pelo tratador de saída do decodificador, escrito pelo tratador de quadro. Os dois
        /// rodam **na mesma thread** (o decode é síncrono dentro do tratador — ver
        /// `docs/receptor-ios.md`), então não há corrida a proteger aqui.
        var segurarEsteQuadro = false

        // **De onde vem cada tranco** (11/09/2026). `Fluidez` conta os intervalos acima de 100 ms
        // entre entregas à tela, mas não diz onde eles nascem — e no iPhone X eram 54–96 por
        // corrida de 4 min com perda quase zero. Para cada um, a linha `tranco:` põe lado a lado
        // três intervalos entre os mesmos dois quadros entregues: o do **carimbo** (quando o Mac
        // capturou), o da **chegada** aqui (quando o núcleo entregou o quadro remontado) e o da
        // **tela**. Carimbo grande é o emissor, ou quadro perdido no caminho; carimbo normal e
        // chegada grande é a rede; chegada normal e tela grande é esta casca.
        //
        // Tudo na thread do tratador, sem trava: o decode é síncrono nela (ver
        // `DecodificadorH264`), e a saída dele roda antes de `alimentar` voltar.
        var entregaAnterior: (chegadaUs: UInt64, carimboUs: UInt64, entregueUs: UInt64)?
        var entregueAgoraUs: UInt64 = 0
        var chegadosSemEntrega = 0
        /// A chegada do quadro anterior, entregue ou não — para a linha `idr:`, que diz quanto cada
        /// IDR atrasou em relação ao quadro que veio antes dele, junto do tamanho.
        var chegadaAnteriorUs: UInt64 = 0
        /// **As pausas pequenas**, acima de 50 ms (um quadro faltando a 30 fps) — abaixo do corte de
        /// `trancos`, e é o que o usuário vê: "a imagem fica pouco tempo fluída, sempre aparecem
        /// pequenos trancos" (11/09/2026). Contadas por origem, na mesma régua da linha `tranco:`, e
        /// escritas a cada 300 entregas na linha `pausas:`, acumuladas desde o começo.
        var pausas = (entregas: 0, acima50: 0, emissor: 0, rede: 0, receptor: 0, retido: 0)
        /// O carimbo do quadro que está sendo decodificado, para a saída do decode passar ao
        /// `Exibidor` — a folga precisa dele. Mesma thread, sem trava.
        var carimboEmCurso: UInt64 = 0
        /// **Quanto cada etapa acrescenta** ao intervalo entre dois quadros entregues, em µs, numa
        /// janela de 300 entregas: o carimbo (o ritmo da captura no Mac), a rede (chegada − carimbo)
        /// e este aparelho (entrega − chegada). A régua de `pausas` aponta um culpado por pausa e erra
        /// perto do corte (E1); esta soma as três partes de cada intervalo.
        var etapas = (carimbo: [Int64](), rede: [Int64](), aparelho: [Int64]())

        let decodificador = DecodificadorH264 { [weak self] imagem, _ in
            guard let self else { return }
            // A régua: prova, por contador, que o pixel decodificado é o pixel mandado.
            if let valor = Marca.ler(de: imagem) {
                travaDoTempo.lock()
                // Três classes, e não duas. A segunda existe porque a primeira medição a produziu
                // e chamá-la de erro teria reprovado o produto por ele estar certo:
                //
                // - **certa**: a marca avança em relação à anterior dentro de um passo plausível,
                //   ou é a primeira de todas.
                // - **repetida**: passo zero ou para trás. **É o comportamento desenhado**, não
                //   defeito: o pedido de IDR de entrada faz o emissor reenviar o último IDR já
                //   emitido, que é um quadro *anterior* ao da vez. Aconteceu exatamente uma vez em
                //   cada corrida que recebeu o quadro 0 — e nenhuma na corrida que o perdeu.
                //   `repetidas` deve casar com os `IDR forçados por pedido` do emissor.
                // - **errada**: um salto para a frente maior que o plausível. Aí houve perda, e
                //   `packets_missing` do núcleo é a segunda testemunha.
                let passo = ultimaMarca < 0 ? 1 : (valor - ultimaMarca + Marca.modulo) % Marca.modulo
                if ultimaMarca < 0 || (passo >= 1 && passo <= 90) {
                    marcasCertas &+= 1
                } else if passo == 0 || passo > Marca.modulo - 90 {
                    marcasRepetidas &+= 1
                } else {
                    marcasErradas &+= 1
                }
                ultimaMarca = valor
                travaDoTempo.unlock()
            } else {
                travaDoTempo.lock(); marcasAusentes &+= 1; travaDoTempo.unlock()
            }

            // **A porta: um quadro cuja referência foi condenada não vai para a tela.**
            //
            // Todo produto de espelhamento congela o último quadro bom e espera a recuperação, em
            // vez de mostrar lixo que se acumula até o próximo IDR. Este receptor não fazia isso:
            // `oferecer` era chamado para todo quadro decodificado, sem estado nenhum de
            // condenação. O resultado é o rastro.
            //
            // Ele continua **decodificando** o quadro suspeito — só não o exibe. Parar de
            // alimentar o VideoToolbox deixaria a sessão dessincronizada e o IDR seguinte chegaria
            // num decodificador com buraco; e é o decode que mantém o `p50` desta corrida
            // comparável com as anteriores.
            //
            // `--sem-congelar` desliga a porta e deixa o comportamento antigo de pé, para que o
            // A/B seja medível em vez de argumentado — a mesma disciplina das cinco portas do
            // emissor. E há uma válvula: passado `congelarNoMaximoMs` sem IDR, a porta abre. Um
            // emissor que não reinjeta IDR sob pedido existe de verdade nesta bancada
            // (`docs/matriz-ios.md`), e com ele a porta sem válvula congelaria a tela para sempre,
            // trocando um defeito visível por um pior.
            if segurarEsteQuadro {
                travaDoTempo.lock(); retidos &+= 1; travaDoTempo.unlock()
                return
            }
            if let quando = self.exibidor.oferecer(imagem, carimboUs: carimboEmCurso) {
                entregueAgoraUs = quando
                travaDoTempo.lock()
                if primeiraImagemUs == 0 { primeiraImagemUs = Medidas.agoraUs() }
                travaDoTempo.unlock()
            }
        }
        self.decodificador = decodificador

        // Declarada **antes** do tratador porque agora é ele quem a escreve, no instante exato em
        // que o IDR chega. Ver a nota lá dentro: amostrada no laço ela não podia ser comparada com
        // `primeiraImagemUs`, que sempre foi exata.
        var primeiroIdrUs: UInt64 = 0

        let registro = nucleo.ouvirQuadros { [weak decodificador, weak gravador] bytes, ts, idr in
            gravador?.quadro(bytes, ts: ts, idr: idr)
            let agora = Medidas.agoraUs()
            travaDoTempo.lock()
            ultimaChegadaUs = agora
            if idr {
                // **O instante em que o IDR chegou, e não o instante em que o laço reparou nele.**
                //
                // Isto era amostrado no laço de supervisão (`decodificador.instantaneo()
                // .idrsRecebidos > 0`), que gira a ~100 ms — e `primeira_imagem`, ao lado dele na
                // mesma linha e na mesma unidade, é exato. Os dois **não podiam ser subtraídos**, e
                // numa corrida de 01/09/2026 a linha do iPad marcou `primeira_imagem=54,8ms
                // primeiro_idr=76,8ms`: imagem 22 ms *antes* do primeiro IDR, que seria imagem
                // decodificada sem referência nenhuma — um defeito grave, e falso. O IDR tinha
                // chegado antes; o laço só o notou depois.
                //
                // Dois números na mesma linha, na mesma unidade, que não se comparam, são um
                // instrumento que mente em silêncio. Medido aqui, os dois passam a ser exatos e a
                // ordem entre eles volta a significar o que parece significar.
                if primeiroIdrUs == 0 { primeiroIdrUs = Medidas.delta(agora, subiuEm) }
                // O IDR é o quadro que não depende de referência nenhuma: ele **cura** a cadeia.
                if suspeitosNaRajada > piorRajada { piorRajada = suspeitosNaRajada }
                if condenadaDesdeUs != 0 {
                    duracoesSemReferenciaUs.append(Medidas.delta(agora, condenadaDesdeUs))
                }
                suspeitosNaRajada = 0
                cadeiaCondenada = false
                condenadaDesdeUs = 0
            } else if cadeiaCondenada {
                suspeitos &+= 1
                suspeitosNaRajada &+= 1
                // A válvula. Sem ela, um emissor que não atende ao pedido de IDR congela a tela
                // para sempre — e esse emissor existe nesta bancada.
                if condenadaDesdeUs != 0,
                   Medidas.delta(agora, condenadaDesdeUs) > SessaoDeRecepcao.congelarNoMaximoMs * 1000 {
                    // A válvula abriu sem IDR: o intervalo **não** terminou porque a imagem se
                    // curou, terminou porque desistimos de esperar. Ele entra na conta do mesmo
                    // jeito — esconder o pior caso é o oposto do que este contador existe para
                    // fazer.
                    duracoesSemReferenciaUs.append(Medidas.delta(agora, condenadaDesdeUs))
                    cadeiaCondenada = false
                    condenadaDesdeUs = 0
                }
            }
            segurarEsteQuadro = cadeiaCondenada && SessaoDeRecepcao.congelarNaRuptura
            travaDoTempo.unlock()
            carimboEmCurso = ts
            decodificador?.alimentar(annexb: bytes, timestampUs: ts, idr: idr)
            segurarEsteQuadro = false

            // Todo IDR, e não só o que virou tranco: é o par tamanho × atraso que diz se encolher o
            // IDR adianta. `chegada` é contra o quadro que chegou antes dele, qualquer que seja.
            if idr, chegadaAnteriorUs != 0 {
                var tela = "nao_entregue"
                if entregueAgoraUs != 0, let antes = entregaAnterior {
                    tela = String(format: "%.0fms",
                                  Double(Medidas.delta(entregueAgoraUs, antes.entregueUs)) / 1000)
                }
                Diario.dizer(String(format: "idr: tamanho=%dKB chegada=%.0fms tela=%@",
                                    bytes.count / 1024,
                                    Double(Medidas.delta(agora, chegadaAnteriorUs)) / 1000, tela))
            }
            chegadaAnteriorUs = agora

            if entregueAgoraUs != 0 {
                if let antes = entregaAnterior {
                    pausas.entregas += 1
                    let dCarimbo = Int64(bitPattern: ts) - Int64(bitPattern: antes.carimboUs)
                    let dChegada = Int64(bitPattern: agora) - Int64(bitPattern: antes.chegadaUs)
                    let dEntrega = Int64(bitPattern: entregueAgoraUs) - Int64(bitPattern: antes.entregueUs)
                    etapas.carimbo.append(dCarimbo)
                    etapas.rede.append(dChegada - dCarimbo)
                    etapas.aparelho.append(dEntrega - dChegada)
                    if Medidas.delta(entregueAgoraUs, antes.entregueUs) > 50_000 {
                        pausas.acima50 += 1
                        if chegadosSemEntrega > 0 {
                            pausas.retido += 1
                        } else if Medidas.delta(ts, antes.carimboUs) > 50_000 {
                            pausas.emissor += 1
                        } else if Medidas.delta(agora, antes.chegadaUs) > 50_000 {
                            pausas.rede += 1
                        } else {
                            pausas.receptor += 1
                        }
                    }
                    if pausas.entregas % 300 == 0 {
                        // O estado térmico junto, porque na D4 as pausas do "receptor" triplicaram na
                        // segunda metade da corrida com decode e memória estáveis.
                        let termico: String
                        switch ProcessInfo.processInfo.thermalState {
                        case .nominal: termico = "nominal"
                        case .fair: termico = "morno"
                        case .serious: termico = "quente"
                        case .critical: termico = "critico"
                        @unknown default: termico = "desconhecido"
                        }
                        Diario.dizer("pausas: entregas=\(pausas.entregas) acima_50ms=\(pausas.acima50) "
                                     + "emissor=\(pausas.emissor) rede=\(pausas.rede) "
                                     + "receptor=\(pausas.receptor) retido=\(pausas.retido) "
                                     + "atrasados_da_folga=\(self.exibidor.atrasadosDaFolga) "
                                     + "termico=\(termico)")
                        // As três partes de cada intervalo, nesta janela. `rede` e `aparelho` podem
                        // ser negativos (quadros que chegam colados); o que importa é a cauda.
                        func resumo(_ valores: [Int64]) -> String {
                            let v = valores.sorted()
                            guard let ultimo = v.last else { return "-" }
                            let em = { (q: Double) -> Double in Double(v[min(v.count - 1, Int(Double(v.count) * q))]) / 1000 }
                            return String(format: "p50=%.0f p95=%.0f max=%.0f", em(0.5), em(0.95), Double(ultimo) / 1000)
                        }
                        Diario.dizer("etapas_ms: carimbo=[\(resumo(etapas.carimbo))] rede=[\(resumo(etapas.rede))] "
                                     + "aparelho=[\(resumo(etapas.aparelho))]")
                        etapas = ([], [], [])
                    }
                }
                if let antes = entregaAnterior,
                   Medidas.delta(entregueAgoraUs, antes.entregueUs) > Fluidez.trancoMs * 1000 {
                    Diario.dizer(String(
                        format: "tranco: tela=%.0fms chegada=%.0fms carimbo=%.0fms decode=%.1fms "
                            + "nao_entregues=%d idr=%@ tamanho=%dKB",
                        Double(Medidas.delta(entregueAgoraUs, antes.entregueUs)) / 1000,
                        Double(Medidas.delta(agora, antes.chegadaUs)) / 1000,
                        Double(Medidas.delta(ts, antes.carimboUs)) / 1000,
                        Double(Medidas.delta(entregueAgoraUs, agora)) / 1000,
                        chegadosSemEntrega, idr ? "sim" : "nao", bytes.count / 1024))
                }
                entregaAnterior = (agora, ts, entregueAgoraUs)
                entregueAgoraUs = 0
                chegadosSemEntrega = 0
            } else {
                chegadosSemEntrega += 1
            }
        }
        guard registro == QUALL_STATUS_OK else {
            let motivo = "quall_track_on_frame recusou: \(NucleoReceptor.nome(registro))"
            Diario.dizer(motivo)
            let codigo = NucleoReceptor.nome(registro)
            publicar { $0.fase = .erro; $0.dizer { tr("quall_track_on_frame recusou: %@", codigo) } }
            desmontar()
            return
        }

        // --- o controle remoto da câmera (R9b) -------------------------------------------------
        // Só numa sessão de vídeo. A tela pede, o filmador aplica e publica o estado (§1).
        abrirCamera()
        defer { fecharCamera() }

        // --- pedir IDR ao entrar ---------------------------------------------------------------
        var pedidosEnviados: UInt64 = 0
        pedidosEnviados += pedirIdrAoEntrar()
        var ultimoPedidoUs = Medidas.agoraUs()

        // --- laço de supervisão ----------------------------------------------------------------
        let fimUs = SessaoDeRecepcao.prazo(segundos: segundos)
        // `motivoDaSaida` vai ao diário em português; `motivoNaTela`, o mesmo motivo no idioma da
        // interface, vai ao painel.
        var motivoDaSaida = ""
        var motivoNaTela: (() -> String)?
        var ultimoRelatoUs: UInt64 = 0

        while !nucleo.parou, Medidas.agoraUs() < fimUs {
            // O detector de queda, com prazo pequeno: ele olha a sinalização, que sabe em
            // milissegundos, em vez de esperar o `CONSENT_TIMEOUT` de 30 s do libjuice.
            let e = nucleo.evento(prazoMs: 50)
            travaDaGravacao.lock(); let pedirParaGravar = gravacaoQuerIdr; gravacaoQuerIdr = false; travaDaGravacao.unlock()
            if pedirParaGravar { nucleo.pedirIdr() }
            let o = nucleo.deslocamentosBrutos()
            gravador?.relogio(video: o.video, audio: o.audio)
            // R9b: a câmera de quem filma, na mesma thread do `next_event` (contrato §11.1).
            bombearCamera(prazoMs: 0)
            // As duas mensagens de saída nomeiam **o quê, onde e o que fazer**. A anterior era
            // só "o transporte falhou": não dizia com quem, nem em que camada, nem o que tentar
            // — e mandava a pessoa reconectar às cegas. O receptor Android já fazia isto certo
            // ("não consegui conectar em $endpoint: $motivo"), e é o padrão copiado aqui.
            // **E no arquivo, sem endereço** (a regra dele): numa corrida sem USB — o iPhone X no
            // cabo Ethernet em 11/09 caiu ~1 min depois de conectar, e não havia registro nenhum
            // de quando nem de qual das duas saídas foi.
            let decorridoS = Double(Medidas.delta(Medidas.agoraUs(), subiuEm)) / 1_000_000
            if e == QUALL_SESSION_EVENT_DISCONNECTED {
                motivoDaSaida = "o emissor em \(endereco) encerrou a transmissão"
                motivoNaTela = { tr("o emissor em %@ encerrou a transmissão", endereco) }
                Diario.arquivar(String(format: "SAIDA t=%.1fs evento=emissor_encerrou", decorridoS))
                break
            }
            if e == QUALL_SESSION_EVENT_FAILED {
                motivoDaSaida = "a conexão de mídia com \(endereco) caiu — o pareamento tinha " +
                    "dado certo, o que falhou foi o transporte. Confira se os dois estão na " +
                    "mesma Wi-Fi e toque em Conectar de novo."
                motivoNaTela = {
                    tr("a conexão de mídia com %@ caiu — o pareamento tinha dado certo, o que falhou "
                       + "foi o transporte. Confira se os dois estão na mesma Wi-Fi e toque em "
                       + "Conectar de novo.", endereco)
                }
                Diario.arquivar(String(format: "SAIDA t=%.1fs evento=transporte_falhou", decorridoS))
                break
            }

            // **A track de áudio pode chegar depois da de vídeo, e chega em quase todo emissor:**
            // ela é declarada como a segunda no `tracks` do `quall_host` (macOS e Windows fazem
            // assim), então sai do `quall_session_next_track` depois. Uma espiada com prazo zero
            // por volta do laço custa uma chamada de FFI a ~10 Hz e não passa perto do caminho do
            // quadro, que vive no tratador.
            //
            // A espiada para assim que uma é adotada: `temTrackDeAudio` vira `true` e a condição
            // não é reavaliada. Não há custo em regime.
            if !nucleo.temTrackDeAudio, decodificadorDeAudio == nil {
                if let nova = nucleo.adotarProximaTrack(prazoMs: 0),
                   nova.tipo == QUALL_TRACK_KIND_MICROPHONE || nova.tipo == QUALL_TRACK_KIND_SYSTEM_AUDIO {
                    montarAudio(rotulo: nova.rotulo, especie: nova.tipo)
                }
            }

            let agora = Medidas.agoraUs()
            travaDoTempo.lock()
            let temImagem = primeiraImagemUs != 0
            let silencio = Medidas.delta(agora, ultimaChegadaUs)
            travaDoTempo.unlock()

            // Quando pedir um IDR, e por que a condição mudou em 2026-08-28.
            //
            // **Antes**: só `!temImagem` — o receptor pedia IDR até a primeira imagem aparecer e
            // **nunca mais**, por mais que perdesse depois disso. Um quadro incompleto é
            // descartado inteiro pelo núcleo (`rtp.rs`, `abortar`), e nada no caminho pede
            // reparo. O decodificador segue decodificando quadros P contra uma referência que
            // nunca chegou: retângulos velhos ficam parados atrás do que se move — **o rastro que
            // o usuário fotografou** — e os macroblocos se sujam, até o IDR espontâneo seguinte
            // do emissor, que pode estar a ~128 quadros de distância.
            //
            // Os dois números da tela dele dizem exatamente isso: `frames_dropped: 14` são
            // catorze rupturas da cadeia de referência, e `idr_requests: 1` é o único pedido que
            // saiu — o de entrada.
            //
            // **Agora**: também pede quando o núcleo acusa quadro descartado desde a última volta.
            // A supressão continua sendo a mesma (`repetirIdrMs`), então uma rajada de perda
            // custa um pedido, não um por quadro — é a política que a bancada já mediu para o
            // piso do PLI, e não uma nova.
            //
            // **Isto não conserta a perda**, conserta a recuperação. E ele depende do emissor
            // saber atender: o do Windows não sabe (`docs/tela-preta.md` §6.2), e para ele este
            // pedido continua caindo no vazio — de propósito, e medido, não suposto.
            let descartados = nucleo.quadrosDescartados()
            let houveRuptura = descartados > descartadosNaUltimaVolta
            descartadosNaUltimaVolta = descartados

            // A mesma ruptura que dispara o pedido de IDR passa a **condenar a cadeia de
            // referência**. Os dois usos são o mesmo fato lido de dois jeitos: pedir IDR conserta
            // a recuperação; condenar a cadeia conserta o que se mostra até ela chegar.
            //
            // A granularidade é a do laço, e ela é **~100 ms, não 50** — o `next_event` espera
            // 50 ms e o `Thread.sleep` logo abaixo espera outros 50. Este comentário dizia 20 Hz
            // e estava errado; quem mediu foi a frente que levou esta medida para as outras
            // cascas, e o macOS teria herdado o mesmo erro. A condenação pode entrar até ~100 ms
            // depois do quadro que a causou, e os quadros dessa janela contam como bons.
            //
            // É um piso, não uma medida exata, e o número real de suspeitos é **maior ou igual**
            // ao relatado. Digo isto aqui porque um contador que se apresenta como exato e não é
            // já custou uma semana a este projeto (`packets_missing`).
            //
            // **E dá para fazer melhor**: o receptor Android condena **por quadro**, lendo
            // `quall_track_frames_dropped` direto pela JNI dentro do tratador. Aqui não dá pelo
            // mesmo motivo que quase pegou aquela casca: o núcleo despacha o quadro segurando o
            // mutex do desempacotador, e o acessor o tranca de novo. Ler o contador dentro do
            // tratador **trava**. A posição do laço não é escolha de granularidade — é a única
            // segura desta casca.
            if houveRuptura {
                travaDoTempo.lock()
                rupturas &+= 1
                if !cadeiaCondenada { condenadaDesdeUs = agora }
                cadeiaCondenada = true
                travaDoTempo.unlock()
            }

            if !temImagem || houveRuptura,
               Medidas.delta(agora, ultimoPedidoUs) > SessaoDeRecepcao.repetirIdrMs * 1000 {
                if nucleo.pedirIdr() == QUALL_STATUS_OK { pedidosEnviados &+= 1 }
                ultimoPedidoUs = agora
            }

            if silencio > SessaoDeRecepcao.silencioAteDesistirMs * 1000 {
                let segundosSemQuadro = Int(SessaoDeRecepcao.silencioAteDesistirMs / 1000)
                motivoDaSaida = "\(segundosSemQuadro) s sem nenhum quadro"
                motivoNaTela = { tr("%ld s sem nenhum quadro", segundosSemQuadro) }
                break
            }

            // **O caminho de volta do sinal**, a 2 Hz. Sai **sempre**, com o controlador do
            // outro lado ligado ou desligado: nos dois braços de um A/B o mesmo tráfego de relato
            // está no ar, então a diferença entre eles não pode ser explicada por ele. Custa ~129
            // bytes por janela — 0,05 % de um vídeo de 4 Mbps.
            //
            // Daqui, e não do tratador de quadro, porque o header exige a **mesma thread** que
            // chama `quall_session_next_event`. E a 2 Hz, porque é a janela contra a qual a
            // política do controlador foi medida.
            if Medidas.delta(agora, ultimoEnlaceUs) >= SessaoDeRecepcao.janelaDoEnlaceMs * 1000 {
                ultimoEnlaceUs = agora
                travaDoTempo.lock()
                let susAcum = suspeitos
                travaDoTempo.unlock()
                let cru = nucleo.contadores()
                // Leitura falha custa **um tique** e não fecha a janela — ver `doEnlace`.
                if let (vistos, perdidosAcum, idrsQuebradosAcum) = SessaoDeRecepcao.doEnlace(cru),
                   let a = janelaDoEnlace.fechar(
                    agoraUs: agora, periodoMs: SessaoDeRecepcao.janelaDoEnlaceMs,
                    vistosAcum: vistos, perdidosAcum: perdidosAcum,
                    suspeitosAcum: susAcum, idrsQuebradosAcum: idrsQuebradosAcum,
                ) {
                    Diario.dizer(a.linha)
                    let st = nucleo.relatarEnlace(ms: a.ms, pacotes: a.pacotes,
                                                  perdidos: a.perdidos, suspeitos: a.suspeitos,
                                                  idrsQuebrados: a.idrsQuebrados)
                    if st != QUALL_STATUS_OK, relatosRecusados < 3 {
                        relatosRecusados += 1
                        // Três vezes e cala: socket morto aparece no detector de queda, e não é
                        // este laço que decide isso.
                        Diario.dizer("o relato do enlace não saiu (status=\(NucleoReceptor.nome(st)))")
                    }
                }
            }

            if Medidas.delta(agora, ultimoRelatoUs) > 1_000_000 {
                ultimoRelatoUs = agora
                travaDoTempo.lock()
                let img = primeiraImagemUs
                let certas = marcasCertas, erradas = marcasErradas
                let repetidas = marcasRepetidas, ausentes = marcasAusentes
                let sus = (rupturas, suspeitos, max(piorRajada, suspeitosNaRajada), retidos)
                let dur = duracoesSemReferenciaUs
                travaDoTempo.unlock()
                relatar(subiuEm: subiuEm, primeiraImagemUs: img, primeiroIdrUs: primeiroIdrUs,
                        pedidos: pedidosEnviados, marcas: (certas, erradas, repetidas, ausentes),
                        suspeita: sus, semReferenciaUs: dur, fim: false)
            }

            // Uma pausa curta: o `next_event` já esperou 50 ms, e o caminho do quadro não passa por
            // este laço em lugar nenhum — ele vive no tratador do núcleo. Com o controle da câmera de
            // pé, a pausa **é** a bombeada dela (a mesma espera, e o estado que chega nela vai à tela
            // na hora, R9b).
            if !bombearCamera(prazoMs: 50) { Thread.sleep(forTimeInterval: 0.05) }
        }

        travaDoTempo.lock()
        let img = primeiraImagemUs
        let certas = marcasCertas, erradas = marcasErradas
        let repetidas = marcasRepetidas, ausentes = marcasAusentes
        let sus = (rupturas, suspeitos, max(piorRajada, suspeitosNaRajada), retidos)
        let dur = duracoesSemReferenciaUs
        travaDoTempo.unlock()
        relatar(subiuEm: subiuEm, primeiraImagemUs: img, primeiroIdrUs: primeiroIdrUs,
                pedidos: pedidosEnviados, marcas: (certas, erradas, repetidas, ausentes),
                suspeita: sus, semReferenciaUs: dur, fim: true)

        if !motivoDaSaida.isEmpty { Diario.dizer("saída: \(motivoDaSaida)") }
        let houveFalha = !motivoDaSaida.isEmpty && !nucleo.parou
        let naTela: () -> String = motivoNaTela ?? { tr("recepção encerrada") }
        // A câmera remota sai antes de a tela voltar ao formulário e antes de a sessão fechar: a
        // bombeada final ainda lê o que chegou.
        fecharCamera()
        publicar { p in
            p.fase = houveFalha ? .erro : .parado
            p.dizer(naTela)
        }
        desmontar()
    }

    // --- pedaços -----------------------------------------------------------------------------

    /// Uma sessão que trouxe **só som**: monta o caminho de áudio e supervisiona até o prazo.
    ///
    /// É o laço de vídeo sem o vídeo, e o que ele perde ao ser separado é justamente o que não se
    /// aplica: pedido de IDR, régua de blocos, detector de silêncio de quadro. Escrever isso como
    /// `if` dentro do laço grande espalharia quatro condicionais por um caminho quente que já é o
    /// mais delicado deste arquivo.
    private func correrSoAudio(rotulo: String, especie: QuallTrackKind, par: String,
                               endereco: String, segundos: Double, subiuEm: UInt64) {
        Diario.dizer("sessão só de áudio (kind=\(especie.rawValue))")
        publicar { $0.fase = .exibindo; $0.rotuloDaTrack = rotulo
                   $0.dizer { tr("som, sem imagem — o emissor não abriu track de vídeo") } }
        montarAudio(rotulo: rotulo, especie: especie)

        let fimUs = SessaoDeRecepcao.prazo(segundos: segundos)
        var motivoDaSaida = ""
        var motivoNaTela: (() -> String)?
        var ultimoRelatoUs: UInt64 = 0

        while !nucleo.parou, Medidas.agoraUs() < fimUs {
            let e = nucleo.evento(prazoMs: 50)
            if e == QUALL_SESSION_EVENT_DISCONNECTED {
                motivoDaSaida = "o emissor em \(endereco) encerrou a transmissão"
                motivoNaTela = { tr("o emissor em %@ encerrou a transmissão", endereco) }
                break
            }
            if e == QUALL_SESSION_EVENT_FAILED {
                motivoDaSaida = "a conexão de mídia com \(endereco) caiu"
                motivoNaTela = { tr("a conexão de mídia com %@ caiu", endereco) }
                break
            }
            let agora = Medidas.agoraUs()
            if Medidas.delta(agora, ultimoRelatoUs) > 1_000_000 {
                ultimoRelatoUs = agora
                if let linha = linhaDeAudio() {
                    Diario.dizer(String(format: "t=%.1fs · %@",
                                        Double(Medidas.delta(agora, subiuEm)) / 1_000_000, linha))
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // O `FIM` sai com o mesmo prefixo do laço de vídeo, e de propósito: é por ele que os
        // roteiros de bancada sabem que a corrida chegou ao fim em vez de morrer.
        let linha = linhaDeAudio() ?? "áudio: nada montado"
        Diario.dizer("FIM so_audio=1 \(linha)")
        if !motivoDaSaida.isEmpty { Diario.dizer("saída: \(motivoDaSaida)") }
        let naTela: () -> String = motivoNaTela ?? { tr("recepção encerrada") }
        publicar { p in
            p.fase = motivoDaSaida.isEmpty ? .parado : .erro
            p.dizer(naTela)
        }
        desmontar()
    }

    // --- áudio ------------------------------------------------------------------------------------

    /// Monta o caminho do som: preset → decodificador → saída → tratador de slot.
    ///
    /// **Nada aqui pode derrubar a exibição de vídeo.** Um receptor sem som ainda é um receptor;
    /// um receptor sem imagem não é nada. Toda falha deste caminho vira uma linha no `Diario` e um
    /// texto no rodapé, e a corrida segue.
    ///
    /// O codec vem da track adotada (`quall_track_audio_codec`), antes de abrir decoder ou saída.
    /// O preset DEFAULT da espécie não descreve uma oferta PCMU: usá-lo trocava 8 kHz mono por
    /// Opus 48 kHz no caminho Mac → iOS. A leitura do TOC só confere uma track já declarada Opus.
    private func montarAudio(rotulo: String, especie: QuallTrackKind) {
        let nome = rotulo.isEmpty
            ? (especie == QUALL_TRACK_KIND_MICROPHONE ? "microfone" : "áudio do sistema")
            : rotulo
        Diario.dizer("track de áudio recebida (kind=\(especie.rawValue))")

        guard let codec = nucleo.codecDeAudio() else {
            Diario.dizer("!! a track não informou o codec negociado: " + SanitizacaoDoLog.causaExterna(NucleoReceptor.ultimoErro()))
            publicar { $0.audio = tr("áudio: codec negociado indisponível") }
            return
        }
        guard let preset = PresetDeAudioLido.ler(especie: especie, codec: codec) else {
            Diario.dizer("!! quall_audio_preset_json recusou a espécie \(especie.rawValue): "
                         + SanitizacaoDoLog.causaExterna(NucleoReceptor.ultimoErro()))
            publicar { $0.audio = "áudio: preset recusado pelo núcleo" }
            return
        }
        presetDeAudio = preset
        conferiuOFio = false
        Diario.dizer("preset de áudio (codec negociado \(codec.rawValue)): \(preset.resumo)")

        guard let dec = DecodificadorDeAudio(codec: codec, taxaHz: preset.taxaHz,
                                          canais: preset.canais,
                                          amostrasPorQuadro: preset.amostrasPorQuadro) else {
            Diario.dizer("!! o decodificador \(preset.codec) recusou \(preset.taxaHz) Hz / \(preset.canais) canal(is)")
            publicar { $0.audio = tr("áudio: o decodificador recusou o formato") }
            return
        }
        decodificadorDeAudio = dec
        gravador?.configurarSom(taxa: Int(preset.taxaHz), canais: preset.canais)

        let saida = SaidaDeAudio()
        guard saida.abrir(taxaHz: Double(preset.taxaHz), canais: preset.canais) else {
            publicar { [t = saida.instantaneo().ultimaFalha] in $0.audio = "áudio: \(t)" }
            dec.fechar()
            decodificadorDeAudio = nil
            return
        }
        saidaDeAudio = saida
        analisadorDeTom = AnalisadorDeTom(taxaHz: Double(preset.taxaHz), canais: preset.canais)

        let registro = nucleo.ouvirAudio { [weak self] ordem, bytes, sequencia, timestamp, temLbrr in
            guard let self else { return }
            // TOC só existe em Opus. PCMU pode coincidir com um TOC válido e nunca serve para
            // inferir codec. Se o Opus exigir remontagem, usa os novos decoder e saída abaixo.
            if codec == QUALL_AUDIO_CODEC_OPUS, ordem == QUALL_AUDIO_ORDER_FRAME,
               !self.conferiuOFio, let b = bytes {
                self.conferiuOFio = true
                self.conferirPrimeiroPacoteOpus(b)
            }
            guard let d = self.decodificadorDeAudio, let s = self.saidaDeAudio else { return }
            guard let pcm = d.traduzir(ordem: ordem, payload: bytes, temLbrr: temLbrr) else {
                // O decodificador falhou. **O DAC ainda precisa de 20 ms**: um buraco na fila do tocador
                // é um estalo, e a política do núcleo é justamente "sempre, sem buraco". Silêncio
                // explícito é a única saída honesta, e o contador de falhas já registrou o quê.
                let silencio = [Int16](repeating: 0, count: d.amostrasPorQuadro * d.canais)
                self.gravador?.som(silencio, taxa: Int(d.taxaHz), canais: d.canais, ordem: sequencia, ts: timestamp)
                s.tocar(silencio)
                return
            }
            // **Medido antes de tocar, e sobre o mesmo vetor que vai para o alto-falante.** Medir
            // depois exigiria uma cópia; medir outra coisa mediria outra coisa. O analisador lê e
            // não guarda nada.
            self.analisadorDeTom?.medir(pcm)
            self.gravador?.som(pcm, taxa: Int(d.taxaHz), canais: d.canais, ordem: sequencia, ts: timestamp)
            s.tocar(pcm)
        }
        guard registro == QUALL_STATUS_OK else {
            Diario.dizer("!! quall_track_on_audio recusou: \(NucleoReceptor.nome(registro))")
            publicar { $0.audio = "áudio: on_audio recusou (\(NucleoReceptor.nome(registro)))" }
            desmontarAudio()
            return
        }
        Diario.dizer("caminho de áudio de pé: \(preset.codec) → AVAudioEngine")
    }

    /// Confere canais e duração de uma track que o SDP já declarou Opus. Esta leitura não
    /// identifica codecs: um payload G.711 também pode passar pelas funções de inspeção Opus.
    private func conferirPrimeiroPacoteOpus(_ pacote: UnsafeRawBufferPointer) {
        guard let base = pacote.baseAddress?.assumingMemoryBound(to: UInt8.self),
              pacote.count > 0, let preset = presetDeAudio else { return }
        let n = Int32(pacote.count)
        let canaisNoFio = opus_packet_get_nb_channels(base)
        let quadros = opus_packet_get_nb_frames(base, n)
        let porQuadro = opus_packet_get_samples_per_frame(base, preset.taxaHz)

        guard canaisNoFio > 0, quadros > 0, porQuadro > 0 else {
            Diario.dizer("!! pacote da track Opus recusado: canais="
                         + "\(canaisNoFio) quadros=\(quadros) amostras=\(porQuadro); áudio desligado")
            publicar { $0.audio = tr("áudio: pacote Opus inválido — desligado") }
            desmontarAudio()
            return
        }

        let amostras = quadros * porQuadro
        Diario.dizer("primeiro pacote de áudio, lido do fio: \(canaisNoFio) canal(is), "
                     + "\(quadros) quadro(s) de \(porQuadro) amostras = \(amostras) por canal "
                     + "a \(preset.taxaHz) Hz (preset dizia \(preset.canais) canal(is), "
                     + "\(preset.amostrasPorQuadro) amostras)")

        if Int(canaisNoFio) != preset.canais {
            Diario.dizer("!! canais do fio (\(canaisNoFio)) diferentes do preset "
                         + "(\(preset.canais)) — remontando o decodificador pelo fio. É a mesma "
                         + "família do defeito que fez `canais_no_fio` existir, pelo outro lado.")
            remontarAudio(canais: Int(canaisNoFio), amostrasPorQuadro: Int(amostras))
        } else if Int(amostras) != preset.amostrasPorQuadro {
            Diario.dizer("!! amostras por quadro do fio (\(amostras)) diferentes do preset "
                         + "(\(preset.amostrasPorQuadro)) — remontando o decodificador pelo fio")
            remontarAudio(canais: preset.canais, amostrasPorQuadro: Int(amostras))
        }
    }

    /// Troca decodificador e saída pelo que o fio disse. Chamado **de dentro do tratador**, o que
    /// é seguro porque nada aqui toca a fronteira C do núcleo — só a libopus e o `AVAudioEngine`.
    private func remontarAudio(canais: Int, amostrasPorQuadro: Int) {
        guard let preset = presetDeAudio else { return }
        decodificadorDeAudio?.fechar()
        decodificadorDeAudio = DecodificadorDeAudio(codec: QUALL_AUDIO_CODEC_OPUS, taxaHz: preset.taxaHz,
                                                 canais: canais,
                                                 amostrasPorQuadro: amostrasPorQuadro)
        if decodificadorDeAudio == nil {
            Diario.dizer("!! a libopus recusou o formato do fio; áudio desligado")
            publicar { $0.audio = "áudio: formato do fio recusado pela libopus" }
            return
        }
        // A saída é remontada junto, **sempre**: um `AVAudioEngine` conectado em mono não aceita
        // buffer estéreo, e o sintoma seria silêncio sem erro nenhum — a mesma família muda de
        // defeito que a `AVSampleBufferDisplayLayer` de quadro zero produziu do lado do vídeo.
        saidaDeAudio?.fechar()
        let nova = SaidaDeAudio()
        saidaDeAudio = nova.abrir(taxaHz: Double(preset.taxaHz), canais: canais) ? nova : nil
        // O analisador também: ele desintercala pelo número de canais, e medir estéreo como mono
        // leria uma amostra a cada duas, o que dobra a frequência aparente e faria o Goertzel
        // acusar a nota errada. Mesmo defeito do fator de 6, uma camada acima.
        analisadorDeTom = AnalisadorDeTom(taxaHz: Double(preset.taxaHz), canais: canais)
        gravador?.configurarSom(taxa: Int(preset.taxaHz), canais: canais)
        presetDeAudio?.canais = canais
        presetDeAudio?.amostrasPorQuadro = amostrasPorQuadro
    }

    private func desmontarAudio() {
        decodificadorDeAudio?.fechar()
        decodificadorDeAudio = nil
        saidaDeAudio?.fechar()
        saidaDeAudio = nil
    }

    /// A linha de áudio do relato, em uma frase. `nil` quando não houve track de áudio nenhuma.
    private func linhaDeAudio() -> String? {
        guard let dec = decodificadorDeAudio, let s = saidaDeAudio?.instantaneo(),
              let p = presetDeAudio
        else { return nil }
        let d = dec.instantaneo()
        // Os canais vêm do **decodificador**, não do preset: se a conferência do fio remontou o
        // decodificador (ver `conferirPrimeiroPacoteOpus`), é o número dele que descreve o que
        // de fato está sendo tocado. Relatar o do preset seria repetir na tela a suposição que a
        // conferência existe para desmentir.
        let canais = dec.canais
        // `subconsumos` é a grandeza que `docs/audio.md` §14 registra como nunca observada, e a
        // razão de este receptor existir para o áudio: é o primeiro consumidor de tempo real que o
        // jitter buffer do núcleo encontra. Vem primeiro na linha de propósito.
        // O tom entra na mesma linha, e vem por último de propósito: os contadores dizem que
        // **bytes** atravessaram; só o Goertzel diz que **som** atravessou. `tom_verde` é o
        // veredito de uma palavra, e `notas`/`trocas` são o que o sustenta.
        let tom: String
        if let t = analisadorDeTom?.instantaneo(), t.quadros > 0 {
            tom = String(format: " · tom notas %d/%d trocas %llu razão %.3f rms %.4f "
                                 + "com_nota %llu/%llu tom_verde=%@",
                         t.notasVistas, TomSintetico.notasHz.count, t.trocas, t.razaoMedia, t.rms,
                         t.comNota, t.quadros, t.verde ? "sim" : "NÃO")
        } else {
            tom = " · tom não medido"
        }
        return String(format: "áudio %@ %dHz %dch · slots %llu · quadros %llu · fec %llu · "
                            + "sem_lbrr %llu · ocultados %llu · falhas %llu(%d) · "
                            + "entregues %llu · amostras %llu · SUBCONSUMOS %llu · fila %d (pico %d)",
                      p.codec, Int(p.taxaHz), canais,
                      d.slots, d.quadros, d.curadosPorFec, d.socorroSemLbrr, d.ocultados,
                      d.falhas, d.ultimaFalha,
                      s.entregues, s.amostras, s.subconsumos, s.pendentes, s.picoDePendentes)
            + tom
    }

    /// Insiste no pedido de IDR até a track aceitar. Devolve quantos pedidos saíram de fato.
    ///
    /// O header é explícito: `quall_track_request_idr` devolve erro enquanto a track não abriu, e
    /// tentar de novo por alguns milissegundos é o comportamento certo.
    private func pedirIdrAoEntrar() -> UInt64 {
        let limite = Medidas.agoraUs() &+ SessaoDeRecepcao.insistirIdrMs &* 1000
        var tentativas = 0
        while !nucleo.parou, Medidas.agoraUs() < limite {
            let st = nucleo.pedirIdr()
            tentativas += 1
            if st == QUALL_STATUS_OK {
                Diario.dizer("IDR pedido ao entrar (na tentativa \(tentativas))")
                return 1
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Diario.dizer("!! a track não aceitou o pedido de IDR de entrada em \(SessaoDeRecepcao.insistirIdrMs) ms "
                     + "(\(tentativas) tentativas) — a primeira imagem vai depender do IDR natural do emissor")
        return 0
    }

    /// A falha de conexão é, na verdade, a permissão de Rede Local negada.
    ///
    /// **Três testemunhas, em ordem decrescente de força.**
    ///
    /// 1. `PermissaoDeRedeLocal.caminhoNegouRedeLocal` — o `NWPath` da sonda voltou
    ///    `.localNetworkDenied`. É **o sistema nomeando a causa** com um valor de enumeração, e
    ///    não há evidência melhor disponível em iOS. Decide sozinha.
    /// 2. `PermissaoDeRedeLocal.ultimaResposta == .negada` — a sonda foi barrada por errno
    ///    (`ENETDOWN`, `EHOSTUNREACH`, `EACCES`). Compatível com a causa, e forte o bastante para
    ///    uma frase afirmativa.
    /// 3. Sem nenhuma das duas, vale a inferência: "sem rota" para um endereço da **própria LAN**.
    ///    Um aparelho tem rota para a própria sub-rede por construção.
    ///
    /// **O casamento por texto encolheu em 30/08, e a razão é boa: o núcleo passou a produzir o
    /// código certo.** A versão anterior deste comentário registrava que `QUALL_STATUS_NO_ROUTE`
    /// existia e **não alcançava** este caminho — a permissão matava a conexão TCP da sinalização
    /// uma camada antes do ICE, e aquilo saía como `QUALL_STATUS_IO` com o texto do `strerror`.
    /// Medido no iPad A16 em 2026-08-30, com a LAN bloqueada:
    ///
    ///     não conectou: status=NO_ROUTE motivo=transporte: não há rota até 192.168.56.131:7951
    ///                   (No route to host (os error 65))
    ///
    /// O pedido foi atendido: hoje chega `NO_ROUTE`. O ramo de texto fica **só** para o `IO`, como
    /// rede de segurança contra um núcleo mais velho, e não é mais o caminho principal.
    private func ehBloqueioDeRedeLocal(motivo: String, endereco: String) -> Bool {
        if PermissaoDeRedeLocal.caminhoNegouRedeLocal { return true }
        if PermissaoDeRedeLocal.ultimaResposta == .negada { return true }
        if !PermissaoDeRedeLocal.enderecoEhDaRedeLocal(endereco) { return false }
        if nucleo.ultimoStatus == QUALL_STATUS_NO_ROUTE { return true }
        let m = motivo.lowercased()
        return m.contains("os error 65") || m.contains("no route to host") || m.contains("sem rota")
    }

    /// **Ramifica pelo código, não pelo texto.** `quall_last_status()` existe desde 2026-08-26
    /// (dívida 27); antes dela a única saída era comparar prefixo de string em português, que é o
    /// que o `Nucleo` do emissor iOS ainda faz e registra como pedido ao núcleo.
    private func explicarFalhaDeConexao(endereco: String) {
        let status = nucleo.ultimoStatus
        let cru = nucleo.ultimoMotivo
        Diario.dizer("não conectou: status=\(NucleoReceptor.nome(status)) motivo=\(SanitizacaoDoLog.causaExterna(cru))"
                     + " permissao_rede_local[\(PermissaoDeRedeLocal.testemunho)]")

        if nucleo.parou {
            publicar { $0.fase = .parado; $0.dizer { tr("cancelado") } }
            return
        }

        // **Antes do `switch`, e de propósito.** A permissão negada se apresenta como `IO` (a
        // sinalização), e pode se apresentar como `NO_ROUTE` (o ICE) se a sinalização passar por
        // outro caminho. As duas portas levam ao mesmo texto, e ele é mais específico que
        // qualquer um dos dois ramos genéricos abaixo.
        // **Quatro estados, e a força da frase acompanha a força da evidência.** A escolha do
        // texto mora inteira em `PermissaoDeRedeLocal.conselho`, e não aqui: é ela que sabe se o
        // alerta apareceu, se este app já pediu antes e se o sistema nomeou a causa. Duplicar essa
        // decisão nesta função foi exatamente como a mensagem errada nasceu em 27/08.
        if status == QUALL_STATUS_IO || status == QUALL_STATUS_NO_ROUTE,
           ehBloqueioDeRedeLocal(motivo: cru, endereco: endereco) {
            let conselho = PermissaoDeRedeLocal.conselho
            Diario.dizer("!! diagnóstico de Rede Local: \(conselho) — \(PermissaoDeRedeLocal.testemunho)")
            publicar {
                $0.fase = .erro
                // O botão "Abrir os Ajustes" só faz sentido para quem tem o que ligar lá. Quem
                // nunca pediu não tem linha no painel, e quem está com o diálogo na tela não
                // precisa sair da tela para nada.
                $0.precisaDeRedeLocal = (conselho == .abraOsAjustes || conselho == .talvezPermissao)
                // Refeito a cada troca de idioma a partir do estado da permissão.
                $0.dizer { PermissaoDeRedeLocal.texto }
            }
            return
        }

        switch status {
        case QUALL_STATUS_NEEDS_PIN:
            // **Não é recusa, é convite a recomeçar** — e é a saída do beco sem saída da dívida 22.
            publicar { $0.fase = .erro; $0.precisaDePin = true
                       $0.dizer { tr("O emissor não reconhece mais este aparelho. Peça o PIN de seis "
                                     + "dígitos que a tela dele mostra e digite aqui.") } }
        // Só chega aqui o `NO_ROUTE` que **não** passou no filtro de permissão acima: endereço
        // que não é da LAN, ou permissão comprovadamente concedida. Aí a leitura certa é a outra
        // metade do que o núcleo documenta para este código — isolamento de AP, Wi-Fi de hóspede.
        case QUALL_STATUS_NO_ROUTE:
            publicar { $0.fase = .erro; $0.precisaDeRedeLocal = true
                       $0.dizer {
                           tr("Os dois aparelhos não acharam caminho um até o outro. Confira "
                              + "se estão na mesma rede Wi-Fi e se ela não isola os aparelhos "
                              + "entre si (rede de hóspedes). Confira também se \"%@\" "
                              + "está ligado em %@.",
                              PermissaoDeRedeLocal.nomeNosAjustes,
                              trSistema("Ajustes → Privacidade e Segurança → Rede Local"))
                       } }
        case QUALL_STATUS_PAIRING:
            publicar { $0.fase = .erro; $0.precisaDePin = true
                       $0.dizer { tr("PIN errado. O emissor mantém o mesmo PIN — confira os seis dígitos.") } }
        // `IO` junto com `TIMEOUT` porque é o mesmo erro para quem digitou: medido no iPad, um
        // endereço certo com porta errada volta `status=IO motivo=e/s: Connection refused`. Sem
        // esta linha a pessoa recebia "e/s: Connection refused (os error 61)" na tela, que não diz
        // o que fazer — e é o erro mais provável de todos, porque o endereço é digitado à mão.
        case QUALL_STATUS_TIMEOUT, QUALL_STATUS_IO:
            publicar { $0.fase = .erro
                       $0.dizer { tr("Ninguém atendeu neste endereço. Confira se o outro aparelho "
                                     + "já está esperando e se o endereço e a porta estão certos.") } }
        case QUALL_STATUS_PROTOCOL:
            publicar { $0.fase = .erro; $0.dizer { tr("O outro aparelho fala outra versão do Quall. Atualize os dois.") } }
        case QUALL_STATUS_CANCELLED:
            publicar { $0.fase = .parado; $0.dizer { tr("cancelado") } }
        default:
            // `cru` é o motivo do núcleo, como veio.
            publicar { $0.fase = .erro; $0.dizer { tr("Não deu para conectar: %@", cru) } }
        }
    }

    /// Funde o pareamento recém-fechado com o que estiver no `pares.json` do App Group **agora**.
    ///
    /// A fusão roda dentro da coordenação de arquivo (ver `Compartilhado.atualizarPares`), que é o
    /// que impede a corrida entre este processo e a appex — os dois escrevem o mesmo arquivo desde
    /// a unificação. Um `nil` do núcleo devolve o texto atual sem tocá-lo: perder pareamentos por
    /// causa de uma leitura falha seria trocar um defeito raro por um pior.
    private func guardarPares() {
        var gravados = 0
        Compartilhado.atualizarPares { noDisco in
            guard let atualizado = nucleo.paresConhecidos(base: noDisco) else {
                Diario.dizer("o núcleo não devolveu estado de pareamento para gravar")
                return noDisco ?? ""
            }
            gravados = atualizado.count
            return atualizado
        }
        if gravados > 0 { Diario.dizer("pareamento gravado (\(gravados) bytes)") }
    }

    private func relatar(subiuEm: UInt64, primeiraImagemUs: UInt64, primeiroIdrUs: UInt64,
                         pedidos: UInt64, marcas: (UInt64, UInt64, UInt64, UInt64),
                         suspeita: (UInt64, UInt64, UInt64, UInt64), semReferenciaUs: [UInt64],
                         fim: Bool) {
        let d = decodificador?.instantaneo() ?? DecodificadorH264.Instantaneo()
        let e = exibidor.instantaneo()
        let agoraUs = Medidas.agoraUs()
        let decorrido = Double(Medidas.delta(agoraUs, subiuEm)) / 1_000_000

        // Taxa da última volta, não média da sessão — ver `relatoAnteriorUs`. Na primeira volta
        // não há volta anterior, e a base é o arranque da sessão.
        let baseUs = relatoAnteriorUs == 0 ? subiuEm : relatoAnteriorUs
        let janela = Double(Medidas.delta(agoraUs, baseUs)) / 1_000_000
        let novos = e.enfileirados >= enfileiradosNoRelatoAnterior
            ? e.enfileirados - enfileiradosNoRelatoAnterior
            : e.enfileirados
        let fps = janela > 0 ? Double(novos) / janela : 0
        relatoAnteriorUs = agoraUs
        enfileiradosNoRelatoAnterior = e.enfileirados
        let primeiraMs = primeiraImagemUs > 0 ? Double(Medidas.delta(primeiraImagemUs, subiuEm)) / 1000 : 0
        let contadores = nucleo.contadores()

        publicar { p in
            p.recebidos = d.recebidos
            p.enfileirados = e.enfileirados
            p.fps = fps
            p.decodeP50Ms = Double(d.p50Us) / 1000
            p.decodeP95Ms = Double(d.p95Us) / 1000
            p.primeiraImagemMs = primeiraMs
            p.primeiroIdrMs = primeiroIdrUs > 0 ? Double(primeiroIdrUs) / 1000 : 0
            p.dimensao = "\(d.largura)x\(d.altura)"
            p.perfil = d.perfil
            p.marcasCertas = marcas.0
            p.marcasErradas = marcas.1
            p.contadoresDoNucleo = contadores
            p.resumoDePerda = ResumoDePerda.formatar(contadores)
            p.idrs = d.idrsRecebidos
            p.semParametros = d.semParametros
            p.falhasDeSessao = d.falhasDeSessao
            p.ultimaFalha = Int32(d.ultimaFalha)
            p.rupturas = suspeita.0
            p.suspeitos = suspeita.1
            p.piorRajada = suspeita.2
            p.retidos = suspeita.3
            p.semReferenciaMs = SessaoDeRecepcao.resumo(semReferenciaUs)
        }

        // Vazio quando não houve track de áudio — que é toda sessão que este projeto já mediu. Uma
        // linha vazia é "não havia som"; uma linha com zeros é "havia e não tocou", e as duas
        // pedem investigações opostas.
        let som = linhaDeAudio()
        publicar { $0.audio = som ?? "" }

        let linha = String(
            format: "%@ t=%.1fs recebidos=%llu decodificados=%llu enfileirados=%llu nao_couberam=%llu "
                  + "sem_parametros=%llu recusados=%llu idrs=%llu pedidos_idr=%llu "
                  + "sessoes_criadas=%llu falhas_descricao=%llu falhas_sessao=%llu ultima_falha=%d "
                  + "primeira_imagem=%@ primeiro_idr=%@ fps=%.1f "
                  + "decode_n=%d p50=%.2fms p95=%.2fms max=%.2fms dim=%dx%d %@ "
                  + "marca_certas=%llu marca_erradas=%llu marca_repetidas=%llu marca_ausentes=%llu "
                  // **Os quatro números que nenhum contador desta casa tinha.** A régua acima diz
                  // se o quadro é o quadro certo; estes dizem se a imagem dele tem chance de estar
                  // certa. Ver as declarações em `correr`.
                  + "rupturas=%llu suspeitos=%llu pior_rajada=%llu retidos=%llu congelar=%@ "
                  + "sem_referencia_ms=%@ "
                  // **A cadência com que a tela foi alimentada, e não só quantos quadros foram.**
                  // `fps` acima é média da última volta e não vê tranco; `enfileirados` diz
                  // quantos e nunca quando. Esta é a distribuição dos intervalos entre entregas,
                  // com o mesmo nome e o mesmo corte do receptor Windows, para que as duas cascas
                  // possam ser postas lado a lado. O campo já vem formatado como
                  // `fluidez_ms=[…] trancos=…` — ver `Fluidez.swift`, inclusive para o que ele
                  // **não** afirma: entregue à camada não é aparecido no vidro.
                  + "%@ "
                  // A pergunta que faltava o dia inteiro: a camada tem área e está na árvore?
                  // `camada=0x0` ou `na_arvore=nao` explica sozinho uma tela preta com todos os
                  // outros contadores fechando. Ver `Exibidor.Instantaneo.camadaInvisivel`.
                  + "camada=%.0fx%.0f na_arvore=%@%@ "
                  // A linha que se lê com o olho, antes do JSON que se lê com script. Até 29/08 o
                  // único número de perda aqui era o teto, e ele era lido como perda.
                  + "pegada=%@ perda=[%@] nucleo=%@",
            fim ? "FIM" : "1Hz", decorrido,
            d.recebidos, d.decodificados, e.enfileirados, e.naoCouberam,
            d.semParametros, d.recusados, d.idrsRecebidos, pedidos,
            // `sem_parametros` sozinho é ambíguo: ele sobe tanto quando o emissor não mandou
            // SPS/PPS quanto quando eles chegaram e o VideoToolbox recusou montar a sessão.
            // Estes quatro separam os dois casos. Ver `DecodificadorH264._falhasDeSessao`.
            d.sessoesCriadas, d.falhasDeDescricao, d.falhasDeSessao, Int32(d.ultimaFalha),
            primeiraMs > 0 ? String(format: "%.1fms", primeiraMs) : "NUNCA",
            primeiroIdrUs > 0 ? String(format: "%.1fms", Double(primeiroIdrUs) / 1000) : "NUNCA",
            fps, d.n, Double(d.p50Us) / 1000, Double(d.p95Us) / 1000, Double(d.maxUs) / 1000,
            d.largura, d.altura, d.perfil,
            marcas.0, marcas.1, marcas.2, marcas.3,
            suspeita.0, suspeita.1, suspeita.2, suspeita.3,
            SessaoDeRecepcao.congelarNaRuptura ? "sim" : "NAO",
            SessaoDeRecepcao.resumo(semReferenciaUs),
            e.fluidez,
            e.larguraDaCamada, e.alturaDaCamada,
            e.camadaNaArvore ? "sim" : "NAO",
            e.camadaInvisivel ? "  *** CAMADA INVISIVEL: decodifica e nao mostra ***" : "",
            Medidas.pegadaDeMemoria(), ResumoDePerda.formatar(contadores), contadores)
        // **O descarte por socket cheio, contado pelo sistema.** Linha própria, antes da de 1 Hz
        // (que continua a última da volta para quem lê com `tail`), e sem o prefixo dela. Ver
        // `UDPDoAparelho`: separa "o pacote não chegou ao aparelho" de "chegou e o socket não coube".
        if let agora = UDPDoAparelho.ler(), let base = udpNoInicio {
            Diario.dizer(String(format: "udp do aparelho t=%.1fs socket_cheio=+%u datagramas=+%u",
                                decorrido, agora.socketCheio &- base.socketCheio, agora.datagramas &- base.datagramas))
        } else if !udpIndisponivelDito {
            udpIndisponivelDito = true
            Diario.dizer("udp do aparelho: net.inet.udp.stats indisponível neste aparelho")
        }
        Diario.dizer(linha)
        // **E no arquivo, que é o único canal que sobrevive à sessão.** Ver `Diario.arquivar`: a
        // sessão limpa do iPhone 7 que o usuário rodou à mão em 30/08 não pôde ser buscada porque
        // este canal não existia. Só esta linha — contadores, sem endereço e sem mídia.
        Diario.arquivar(linha)

        // **Linha própria, e não colada na de vídeo.** A de cima já tem trinta campos e é lida por
        // script; enfiar áudio no meio dela quebraria todo leitor existente. E os contadores do
        // núcleo para áudio são outros — `jitter_us` só existe em track de áudio, e é `null` em
        // vídeo, que o header avisa querer dizer **não medido**, não zero.
        if let som {
            Diario.dizer("\(fim ? "FIM" : "1Hz") \(som) nucleo_audio=\(nucleo.contadoresDeAudio())")
        }
    }

    /// A ordem obrigatória, e o destino da caixa dito em voz alta.
    ///
    /// O decodificador só é fechado **depois** de o tratador de quadro estar desregistrado com
    /// barreira: fechar antes deixaria um quadro em voo entrando numa sessão de VideoToolbox morta.
    private func desmontar() {
        let r = nucleo.encerrar()
        Diario.dizer("desmonte: on_frame(NULL)=\(r.desregistro.map(NucleoReceptor.nome) ?? "n/a") "
                     + "session_close=\(r.fechamento.map(NucleoReceptor.nome) ?? "n/a") "
                     + "caixa=\(r.caixaLiberada ? "liberada" : "VAZADA de propósito")")
        decodificador?.fechar()
        decodificador = nil
        // **Depois do `encerrar()`, e a ordem não é arbitrária.**
        //
        // `quall_track_on_audio(t, NULL, NULL)` escoa o jitter buffer antes de voltar, entregando
        // os slots retidos pelo tratador **antigo**, desta thread. São os últimos 40 ms da sessão.
        // Fechar a saída de áudio antes disso os jogaria fora — a mesma razão de o decodificador
        // de vídeo já ser fechado depois da barreira, e não antes.
        if let som = linhaDeAudio() { Diario.dizer("FIM \(som)") }
        desmontarAudio()
        if let gravador { DispatchQueue.main.async { gravador.parar() } }
        Diario.dizer("pegada final: \(Medidas.pegadaDeMemoria())")
    }
}
