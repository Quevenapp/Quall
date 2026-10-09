import CQuall
import Foundation
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit
import QuallReceptorKit
import SwiftUI

/// A máquina de estados do **receptor** macOS — a metade do produto que faltava.
///
/// `docs/app-macos.md` registra o corte com todas as letras: *"O enunciado pedia emissor **e**
/// receptor. Cortei o receptor."* A consequência era que quem tem Mac não conseguia ver a tela de
/// outro aparelho — e o Mac é a máquina onde a pessoa trabalha, o lugar mais provável de alguém
/// querer *ver*. Esta classe fecha isso.
///
/// # É o gêmeo de `Emissor`, e as diferenças são as que o protocolo obriga
///
/// | | `Emissor` | `Receptor` |
/// |---|---|---|
/// | fronteira | `quall_host` — bloqueia esperando alguém | `quall_connect` — bloqueia tentando alcançar alguém |
/// | tracks | pedidas na abertura (dívida 1) | chegam do outro lado, por `quall_session_next_track` |
/// | quem escolhe | a origem, antes do PIN | o endereço e o PIN |
/// | IDR | lê a bandeira e reencoda | **pede**, e repete enquanto não há imagem |
///
/// # Por que não é `@MainActor`
///
/// Mesma razão do `Emissor`: `quall_connect` **bloqueia** por até trinta segundos e
/// `quall_session_next_event` exige ser chamada sempre da **mesma** thread. As propriedades
/// `@Published` só mudam na main (por `naMain`), o estado partilhado com a thread da sessão fica
/// atrás de `trava`, e `@unchecked Sendable` é a afirmação explícita de que a trava é nossa
/// responsabilidade.
final class Receptor: ObservableObject, @unchecked Sendable {

    /// `.fechado` é "o app não está no modo de exibir" — é ele que decide, em `RaizDaJanela`, se a
    /// janela mostra o fluxo de emissão ou o de recepção. Não é uma fase da sessão: é a ausência
    /// de uma.
    enum Fase: String, Equatable {
        case fechado, formulario, conectando, esperandoTrack, exibindo, encerrando
    }

    // MARK: - o que a interface lê (só muda na main)

    @Published private(set) var fase: Fase = .fechado
    @Published private(set) var mensagem = ""
    @Published private(set) var gravacaoRecebida = GravadorRecebido.Estado()
    private let gravadorRecebido = GravadorRecebido()
    private var pedirIDRDaGravacao = false
    @Published private(set) var endereco = ""
    @Published private(set) var par = ""
    @Published private(set) var pareamentoNovo = false
    @Published private(set) var rotuloDaTrack = ""
    @Published private(set) var dimensao = ""
    @Published private(set) var perfil = ""
    @Published private(set) var primeiraImagemMs: Double = 0
    @Published private(set) var recebidos: UInt64 = 0
    /// Quadros que a camada de exibição **aceitou** — não pixels confirmados no vidro. O nome é o
    /// que o receptor iOS levou uma investigação para adotar; ver `Exibidor`.
    @Published private(set) var enfileirados: UInt64 = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var decodeP50Ms: Double = 0
    @Published private(set) var decodeP95Ms: Double = 0
    // Os cinco do contrato, **na tela** e não só no log. `docs/contrato-track.md`: uma casca que
    // publica os contadores só onde uma ferramenta os lê não cumpre o contrato. A queixa que
    // originou esta medida sempre foi sobre a tela — em 31/08 o usuário olhou para um receptor
    // com 124 quadros suspeitos e disse "continua falhando e 0 falhas", e estava certo.
    @Published private(set) var rupturas: UInt64 = 0
    @Published private(set) var suspeitos: UInt64 = 0
    @Published private(set) var piorRajada: UInt64 = 0
    @Published private(set) var retidos: UInt64 = 0
    @Published private(set) var semReferenciaMs = "[n=0]"

    @Published private(set) var marcasCertas: UInt64 = 0
    @Published private(set) var marcasErradas: UInt64 = 0
    @Published private(set) var marcasRepetidas: UInt64 = 0
    @Published private(set) var contadoresDoNucleo = "{}"
    /// A perda em uma linha: exata, teto e tarde demais **juntos**. Campo próprio, e não algo que
    /// a tela derive de `contadoresDoNucleo`, porque os dois vêm da **mesma** leitura: derivar na
    /// tela abriria a porta para a linha e o JSON serem de instantes diferentes.
    @Published private(set) var resumoDePerda = ""

    // Por que a tela está preta, **na própria tela**. Ver `docs/tela-preta.md` §1: uma foto com
    // `recebidos 68 · exibidos 0` e nada que dissesse de qual lado do fio vinha o defeito mandou
    // três pessoas para o lado errado.
    @Published private(set) var idrs: UInt64 = 0
    @Published private(set) var semParametros: UInt64 = 0
    @Published private(set) var falhasDeSessao: UInt64 = 0
    @Published private(set) var ultimaFalha: Int32 = 0
    @Published private(set) var camadaInvisivel = false

    /// `quall_last_status()` disse `NEEDS_PIN` ou `PAIRING`: a tela oferece o campo do PIN em vez
    /// de só dizer que falhou. É a saída do beco sem saída da dívida 22.
    @Published private(set) var precisaDePin = false

    /// O que a pessoa digitou. Ligados por `@Published` porque a tela escreve neles.
    @Published var enderecoDigitado = ""
    @Published var pinDigitado = ""

    // MARK: - o som (S4 do `docs/som-no-receptor.md`; D1 e D3 do §12.1)

    /// D1: **som ligado por padrão**, com mudo e volume na janela, pela saída padrão do sistema.
    /// Cada sessão nasce com som — o mudo volta a desligado em toda conexão (a não ser com `--mudo`,
    /// da bancada); o volume é lembrado.
    @Published var somMudo = false { didSet { aplicarVontadeDoSom() } }
    /// D3 com saída na janela: tocar mesmo com a câmera do Quall numa chamada (crítica 9, M4).
    @Published var somComACamera = false { didSet { aplicarVontadeDoSom() } }
    @Published var somVolume: Float = 1 {
        didSet {
            UserDefaults.standard.set(somVolume, forKey: Receptor.chaveDoVolume)
            aplicarVontadeDoSom()
        }
    }
    /// Uma linha para a janela: o que toca, ou por que está calado.
    @Published private(set) var somEstado = ""
    /// **A câmera do outro lado** (R9b, `docs/controle-remoto-da-camera.md`): o estado do controle remoto
    /// desta sessão, ou `nil` sem sessão. O painel aparece com `pronto` e `nao_permitido`.
    @Published private(set) var cameraRemota: EstadoDaCameraRemota?
    /// O tamanho do vídeo decodificado, para o clique na imagem virar o ponto no quadro (§3.4).
    @Published private(set) var tamanhoDoVideo: CGSize = .zero
    private static let chaveDoVolume = "quall.receptor.som.volume"

    let nome = Identidade.nomeDoAparelho
    private let argumentos = Argumentos.lidos()
    private var jaConectouSozinho = false

    /// O último endereço que deu certo. `UserDefaults` e não `Application Support`: é conveniência
    /// de digitação, não estado do protocolo — perdê-lo custa uma digitação, não um pareamento.
    private static let chaveDoUltimoEndereco = "quall.receptor.ultimo_endereco"
    var ultimoEndereco: String {
        UserDefaults.standard.string(forKey: Receptor.chaveDoUltimoEndereco) ?? ""
    }

    // MARK: - estado partilhado com a thread da sessão

    private let nucleo = NucleoReceptor()
    /// O motor do som, quando a sessão trouxe som. Atrás de `trava`.
    private var tocador: Tocador?
    /// `--recapturar-janela`: a janela de vídeo recapturada (T1 da S7). Atrás de `trava`.
    private var recaptura: RecapturaDaJanela?
    /// A sessão da recaptura já acabou? Atrás de `trava`. Se o SCK terminar de subir depois do fim
    /// da sessão, a tarefa que o sobe o para na hora, em vez de guardá-lo (revisão da S7, B3: sem
    /// isto, a janela seguia recapturada até o processo sair).
    private var sessaoDaRecapturaAcabou = false
    /// As três vontades do volume (D1 e D3). Atrás de `trava`: a janela escreve o mudo e o volume,
    /// o laço da sessão escreve a câmera.
    private var vontadeDoSom = VontadeDoSom()
    /// Nas duas últimas voltas de relato, a porta só entregou ocioso: a track de som está em `IDLE`
    /// (o D2, o som com outro receptor, ou o emissor que parou de mandar). Uma volta só não basta: o
    /// primeiro segundo da sessão também é todo ocioso. Atrás de `trava`.
    private var somOciosoAgora = false
    private var voltasOciosasSeguidas = 0
    private var puxadasNoRelatoAnterior: UInt64 = 0
    private var ociosasNoRelatoAnterior: UInt64 = 0
    /// A taxa do DAC pelo relógio do host, a testemunha de fora da deriva (crítica 10, M9). Do
    /// laço da sessão, como os dois contadores acima; recomeça quando a saída religa.
    private var testemunhaDaDeriva = TestemunhaDaDeriva()
    private var religamentosNaTestemunha: UInt64 = 0
    /// O refresh da tela da janela, lido na main ao conectar.
    private var refreshDaTelaUs: UInt64 = 16_667
    /// Se a câmera do Quall foi achada no CoreMediaIO na última olhada: `nil` antes da primeira.
    /// Atrás de `trava`. Sem ela instalada, a D3 não tem o que olhar, e o diário diz `ausente`.
    private var cameraDoQuallPresente: Bool?
    /// **Vive o processo inteiro, e as sessões não.** É por isso que `Exibidor.reiniciar()` existe
    /// e é chamado no arranque de cada sessão — sem isso o rodapé põe um numerador de
    /// vida-do-processo ao lado de um `recebidos` de vida-da-sessão, e a taxa de quadros que sai
    /// é impossível (medido no iOS: 77,4 fps numa origem de 30).
    let exibidor = Exibidor()
    private let trava = NSLock()
    private var decodificador: DecodificadorH264?
    private var thread: Thread?
    /// O controle da câmera do outro lado, da sessão de pé. Atrás de `trava`: a tela pede de qualquer
    /// thread (o header deixa), o laço da sessão bombeia.
    private var controleRemoto: ControleDaCameraRemota?

    // Os prazos, todos nomeados. Os quatro primeiros são os **mesmos** do receptor iOS e do
    // Android, de propósito: se um estiver errado, melhor errado nos três.
    private static let prazoDeConexaoMs: UInt32 = 30_000
    private static let prazoDaPrimeiraTrackMs: UInt32 = 15_000
    private static let insistirIdrMs: UInt64 = 3_000
    private static let repetirIdrMs: UInt64 = 700
    private static let silencioAteDesistirMs: UInt64 = 10_000

    /// Período da janela do enlace, em ms — a cadência com que o receptor conta ao emissor o que
    /// viu do fio.
    ///
    /// **500 ms, e não é escolha livre**: é a janela contra a qual a política do controlador de
    /// taxa foi medida (`crates/quall-core/src/taxa.rs`, e a curva de resposta em
    /// `docs/taxa-que-escuta.md`). Alimentar o controlador com uma janela diferente da que
    /// produziu a curva é projetá-lo contra outra curva. Os receptores iOS e Android usam a
    /// mesma, de propósito.
    private static let janelaDoEnlaceMs: UInt64 = 500

    /// Por quanto tempo, no máximo, a tela fica com o último quadro bom esperando um IDR depois
    /// de uma ruptura.
    ///
    /// A válvula existe porque **um emissor que não reinjeta IDR sob pedido existiu de verdade
    /// nesta bancada**: o `quall-app.exe` de 27/08 pôs um único IDR na sessão inteira contra 54
    /// pedidos (`docs/matriz-ios.md`). Contra um emissor assim, congelar sem prazo trocaria uma
    /// imagem suja por uma imagem parada, que é pior. Mesmo valor do receptor iOS e do Android.
    private static let congelarNoMaximoMs: UInt64 = 2_000

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
    static let congelarNaRuptura = ProcessInfo.processInfo.arguments.contains("--congelar")

    /// `n`, `p50`, `p95` e `max` de uma lista de durações em microssegundos, em milissegundos.
    ///
    /// Quatro números e não um: numa medida de dano visual **a cauda é o dano**. Um p50 de 30 ms
    /// com máximo de 2 000 ms é uma sessão em que a pessoa viu a tela travar.
    static func resumo(_ us: [UInt64]) -> String {
        guard !us.isEmpty else { return "[n=0]" }
        let ms = us.map { Double($0) / 1000 }.sorted()
        func q(_ p: Double) -> Double { ms[min(ms.count - 1, Int(p * Double(ms.count - 1) + 0.5))] }
        return String(format: "[n=%d p50=%.0f p95=%.0f max=%.0f]",
                      ms.count, q(0.5), q(0.95), ms[ms.count - 1])
    }

    // A janela da taxa de quadros. A taxa era, no iOS, `enfileirados / (agora - subiu)` — uma
    // média desde o começo da sessão, que **não sabe cair**. Aqui é a taxa da última volta.
    private var relatoAnteriorUs: UInt64 = 0
    private var enfileiradosNoRelatoAnterior: UInt64 = 0

    /// O receptor em uso, para o `--sair-apos` esperar o desmonte dele. Só lido na main.
    static weak var atual: Receptor?

    init() {
        Receptor.atual = self
        gravadorRecebido.aoEstado = { [weak self] e in
            guard let self else { return }
            self.gravacaoRecebida = e
            if !e.ativo, !e.mensagem.isEmpty { self.mensagem = e.mensagem }
        }
        gravadorRecebido.aoPedirIDR = { [weak self] in
            guard let self else { return }; self.trava.lock()
            self.pedirIDRDaGravacao = true; self.trava.unlock()
        }
        if let v = UserDefaults.standard.object(forKey: Receptor.chaveDoVolume) as? Float { somVolume = v }
        if let v = argumentos.somVolume { somVolume = min(max(v, 0), 1) }
        somMudo = argumentos.somMudo
        somComACamera = argumentos.somComCamera
        // O `didSet` não roda dentro do `init`: a vontade é montada aqui, inteira, para o motor
        // nascer com ela (crítica 9, M5).
        trava.lock()
        vontadeDoSom = VontadeDoSom(mudo: somMudo, volume: somVolume, camera: .livre,
                                    tocarComACamera: somComACamera)
        trava.unlock()
        guard argumentos.exibir else { return }
        // Modo de bancada: a janela pode nem aparecer (sem bundle o LaunchServices não monta a
        // cena), e mesmo com ela ninguém tem mão para digitar. Ver `Argumentos`.
        enderecoDigitado = argumentos.endereco ?? ""
        pinDigitado = argumentos.pin ?? ""
        fase = .formulario
        guard argumentos.conectarJa else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (argumentos.esperar ?? 0.5)) { [weak self] in
            guard let self, !self.jaConectouSozinho, self.fase == .formulario else { return }
            self.jaConectouSozinho = true
            guard !self.enderecoDigitado.isEmpty else {
                Registro.compartilhado.linha("ERRO: --conectar-ja sem --endereco")
                return
            }
            Registro.compartilhado.linha("bancada: conectando sem esperar o dedo de ninguém")
            self.conectar()
        }
    }

    private func naMain(_ bloco: @escaping () -> Void) {
        if Thread.isMainThread { bloco() } else { DispatchQueue.main.async(execute: bloco) }
    }

    // MARK: - entrar e sair do modo de exibir

    func abrir() {
        guard fase == .fechado else { return }
        fase = .formulario
        mensagem = ""
        precisaDePin = false
        if enderecoDigitado.isEmpty { enderecoDigitado = ultimoEndereco }
        Registro.compartilhado.linha("receptor: modo exibir aberto")
    }

    /// Volta ao começo do app. Só do formulário — durante uma sessão o botão é **Parar**, e é o
    /// desmonte que traz a tela de volta.
    func fechar() {
        guard fase == .formulario else { return }
        fase = .fechado
        mensagem = ""
    }

    // MARK: - conectar

    func conectar() {
        guard fase == .formulario else { return }
        let alvo = enderecoDigitado.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alvo.isEmpty else {
            mensagem = T("Digite o endereço que o outro aparelho está mostrando.")
            return
        }
        let pin = pinDigitado.trimmingCharacters(in: .whitespacesAndNewlines)

        guard thread == nil else { return }

        nucleo.prepararConexao()

        endereco = alvo
        par = ""
        rotuloDaTrack = ""
        dimensao = ""
        perfil = ""
        precisaDePin = false
        fase = .conectando
        mensagem = pin.isEmpty ? T("retomando pareamento…") : T("conectando e pareando…")

        let paresAgora = Identidade.paresConhecidos()
        // D1: cada sessão nasce com som (crítica 9, miúdo 6).
        somMudo = argumentos.somMudo
        // O refresh da tela **da janela**, lido aqui na main (crítica 9, miúdo 10).
        // A principal, e não `NSApp.windows.first`: desde 01/10 a primeira pode ser o ícone da barra de
        // menus noutro monitor (um virtual da tela estendida, com outra taxa de quadros).
        let tela = NSApp.keyWindow?.screen ?? Janela.principal?.screen
            ?? NSApp.windows.first(where: Janela.ehDeConteudo)?.screen ?? NSScreen.main
        refreshDaTelaUs = UInt64(1_000_000 / Double(max(tela?.maximumFramesPerSecond ?? 60, 1)))
        // A tela deste Mac, lida aqui na main (AppKit não se lê da thread da corrida).
        let telaAgora: (largura: UInt32, altura: UInt32) = NSScreen.main.map {
            (UInt32(($0.frame.width * $0.backingScaleFactor).rounded()),
             UInt32(($0.frame.height * $0.backingScaleFactor).rounded()))
        } ?? (0, 0)
        let t = Thread { [weak self] in
            self?.correr(endereco: alvo, pin: pin.isEmpty ? nil : pin, pares: paresAgora, tela: telaAgora)
        }
        t.name = "quall.receptor"
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    /// O Parar da tela. Levanta a bandeira e destrava a espera bloqueada — de qualquer thread.
    func parar() {
        guard fase != .fechado, fase != .formulario else { return }
        if fase != .encerrando { fase = .encerrando }
        nucleo.parar()
    }

    func alternarGravacaoRecebida() {
        guard !gravacaoRecebida.fechando else { return }
        if gravacaoRecebida.ativo { gravadorRecebido.parar(); return }
        guard fase == .exibindo else { return }
        let formato = nucleo.portaDeSom?.formato
        let pasta = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Quall", isDirectory: true)
        gravadorRecebido.iniciar(nome: par, pasta: pasta, canais: formato?.canais,
            atrasoAudioUs: Int64(formato?.atrasoInternoUs ?? 0))
    }

    // MARK: - a corrida (roda inteira fora da main)

    private func correr(endereco: String, pin: String?, pares: String,
                        tela: (largura: UInt32, altura: UInt32) = (0, 0)) {
        defer { thread = nil }

        Registro.compartilhado.linha(
            "receptor: conectando"
            + (pin == nil ? " sem PIN (par conhecido)" : " com PIN")
            + " pares_conhecidos=\(!pares.isEmpty)")

        let inicioDaConexao = Medidas.agoraUs()
        guard nucleo.conectar(endereco: endereco,
                              pin: pin,
                              deviceId: Identidade.deviceId,
                              nome: Identidade.nomeDoAparelho,
                              paresConhecidos: pares.isEmpty ? nil : pares,
                              prazoMs: Receptor.prazoDeConexaoMs,
                              tela: tela) else {
            explicarFalhaDeConexao(endereco: endereco)
            nucleo.encerrar()
            return
        }
        let subiuEm = Medidas.agoraUs()

        // Zerado **aqui**, e não no fim: ver o comentário de `exibidor`.
        exibidor.reiniciar()
        relatoAnteriorUs = 0
        enfileiradosNoRelatoAnterior = 0

        let msDaConexao = Double(Medidas.delta(subiuEm, inicioDaConexao)) / 1000
        let nomeDoPar = nucleo.nomeDoPar
        let novo = nucleo.pareamentoNovo()
        Registro.compartilhado.linha(String(
            format: "receptor: sessão de pé em %.1f ms; pareamento %@",
            msDaConexao, novo ? "novo (PIN digitado)" : "retomado"))

        // Gravado **agora**, e não no fim: se a sessão cair, o pareamento que já aconteceu não pode
        // se perder — era exatamente esse o defeito do PIN pedido toda vez.
        //
        // A linha de registro não é decoração. Foi a ausência dela que deixou o defeito do
        // `lerTexto` (ver `NucleoDeRede.lerTexto`) invisível por dias: a casca chamava, recebia
        // string vazia, `guardarPares` desistia em silêncio, e o único sintoma era o PIN sendo
        // pedido de novo na corrida seguinte — três passos depois da causa.
        let novosPares = nucleo.paresConhecidos(somandoA: pares.isEmpty ? nil : pares)
        if novosPares.isEmpty {
            Registro.compartilhado.linha(
                "receptor: !! o núcleo não devolveu estado de pareamento — nada foi gravado, "
                + "e o PIN vai ser pedido de novo")
        } else {
            Identidade.guardarPares(novosPares)
            Registro.compartilhado.linha("receptor: pareamento gravado (\(novosPares.count) bytes)")
        }
        UserDefaults.standard.set(endereco, forKey: Receptor.chaveDoUltimoEndereco)

        naMain {
            self.par = nomeDoPar
            self.pareamentoNovo = novo
            self.fase = .esperandoTrack
            self.mensagem = T("esperando a track do emissor…")
        }

        guard let (rotulo, tipo) = nucleo.esperarTrackDeVideo(
            prazoMs: Receptor.prazoDaPrimeiraTrackMs,
            aoPular: { motivo in
                // Nomeada, não engolida: uma track largada sem linha pareceria "não veio".
                Registro.compartilhado.linha("receptor: track largada — \(motivo)")
            },
            aoAdotarSom: { nome, especie in
                Registro.compartilhado.linha(
                    "receptor: track de som adotada ANTES do vídeo (\(especie)); "
                    + "3 s para o vídeo aparecer")
            }) else {
            let cancelado = nucleo.parou
            let soDeSom = nucleo.temTrackDeAudio
            let motivo = cancelado
                ? T("cancelado")
                : soDeSom
                ? T("%@ conectou mas não abriu nenhuma track de vídeo (a sessão só trouxe som)",
                    nomeDoPar.isEmpty ? endereco : nomeDoPar)
                : T("%@ conectou mas não abriu nenhuma track de vídeo", nomeDoPar.isEmpty ? endereco : nomeDoPar)
            Registro.compartilhado.linha("receptor: falha; causa=\(SanitizacaoDoLog.causaExterna(motivo))")
            naMain { self.mensagem = motivo }
            desmontar(voltarAoFormulario: true)
            return
        }

        let nomeDaTrack = rotulo.isEmpty
            ? (tipo == QUALL_TRACK_KIND_CAMERA ? T("câmera") : T("tela"))
            : rotulo
        Registro.compartilhado.linha("receptor: track recebida (kind=\(tipo.rawValue))")
        naMain {
            self.fase = .exibindo
            self.rotuloDaTrack = nomeDaTrack
            self.mensagem = ""
        }

        exibir(subiuEm: subiuEm, endereco: endereco)
    }

    /// O laço de exibição: decodificador, tratador de quadro, pedido de IDR e supervisão.
    private func exibir(subiuEm: UInt64, endereco: String) {
        var primeiraImagemUs: UInt64 = 0
        var descartadosNaUltimaVolta: UInt64 = 0
        var ultimaChegadaUs = Medidas.agoraUs()
        let travaDoTempo = NSLock()
        var certas: UInt64 = 0, erradas: UInt64 = 0, repetidas: UInt64 = 0, ausentes: UInt64 = 0
        var ultimaMarca: Int?

        // -----------------------------------------------------------------------------------
        // **A testemunha que faltava: quadro exibido com a referência quebrada.**
        //
        // Esta casca já detectava a ruptura (o `quall_track_frames_dropped` logo abaixo, que pede
        // o IDR) e **não fazia mais nada com ela**: nem contava, nem deixava de exibir. Entre a
        // ruptura e o IDR seguinte, todo quadro que chega decodifica sem erro nenhum e sai
        // visualmente podre — e conta como sucesso em `recebidos`, `decodificados`,
        // `enfileirados` e na régua de blocos, que lê quatro quadrados num canto e não vê o resto.
        //
        // Medido no receptor iOS, mesmo defeito e mesma semana: numa corrida A10s → iPad com
        // 1,6 % de perda, **301 de 1156 quadros — 26 % da sessão** — foram para a tela com a
        // referência quebrada, em rajadas de até 30 quadros seguidos, enquanto `marca_erradas`,
        // `sem_parametros`, `nao_couberam` e `falhas_sessao` diziam todos zero.
        //
        // Os nomes são os de `docs/contrato-track.md` e são literais.
        var cadeiaCondenada = false
        var rupturas: UInt64 = 0
        var suspeitos: UInt64 = 0
        var suspeitosNaRajada: UInt64 = 0
        var piorRajada: UInt64 = 0
        var retidos: UInt64 = 0
        var condenadaDesdeUs: UInt64 = 0
        /// Quanto tempo cada intervalo "sem referência utilizável" durou, em microssegundos. O
        /// contador de quadros diz **quantos** saíram errados; este diz **por quanto tempo** a
        /// tela ficou errada, que é a grandeza que a pessoa sente.
        var duracoesSemReferenciaUs: [UInt64] = []
        /// Lido pelo tratador de saída do decodificador, escrito pelo tratador de quadro. Os dois
        /// rodam **na mesma thread**: `VTDecompressionSessionDecodeFrame` é chamado aqui com
        /// `[._1xRealTimePlayback]` e **sem** `_EnableAsynchronousDecompression`, então o decode é
        /// síncrono dentro do `alimentar`. Não há corrida a proteger — e é o que permite copiar o
        /// desenho do iOS em vez de carregar a marca por quadro, como a casca da câmera terá de
        /// fazer (ela liga a decodificação assíncrona).
        var segurarEsteQuadro = false
        /// A última imagem que a camada aceitou: `(timestamp_us, hora do host em µs)`. O lado da
        /// imagem do Δ.
        var ultimaImagem: (ts: UInt64, hostUs: UInt64)?
        /// O `timestamp_us` do quadro que está sendo decodificado agora. O segundo argumento do
        /// tratador do decodificador é o **custo** do decode, e não o carimbo; como o decode é
        /// síncrono dentro do `alimentar` (ver `segurarEsteQuadro`), o carimbo vem daqui.
        var tsEmDecodificacao: UInt64 = 0
        /// `--claquete`: o índice da régua de cada imagem aceita pela camada, com a hora.
        let claquete = argumentos.claquete
        var imagensDaClaquete: [(r: Int, hostUs: UInt64, ts: UInt64)] = []
        /// O tamanho do vídeo decodificado, para a recaptura achar a régua na janela.
        var dimensaoDoVideo: (largura: Int, altura: Int) = (0, 0)
        var recapturaTentada = false
        /// A derivada do dano, que é o que atravessa até o emissor. Ver `JanelaDoEnlace`.
        var janelaDoEnlace = JanelaDoEnlace()
        var ultimoEnlaceUs: UInt64 = 0
        var relatosRecusados = 0

        let decodificador = DecodificadorH264 { [weak self] imagem, _ in
            guard let self else { return }
            // A régua: prova, **por contador**, que o pixel decodificado é o pixel mandado. Só dá
            // resultado com a fonte sintética de bancada; numa origem de produto ela devolve `nil`
            // e o contador `ausentes` sobe, que é o caso normal e não é erro.
            let valorDaMarca = Marca.ler(de: imagem)
            if let valor = valorDaMarca {
                travaDoTempo.lock()
                switch Marca.classificar(anterior: ultimaMarca, atual: valor) {
                case .certa: certas &+= 1
                case .repetida: repetidas &+= 1
                case .errada: erradas &+= 1
                }
                ultimaMarca = valor
                travaDoTempo.unlock()
            } else {
                travaDoTempo.lock(); ausentes &+= 1; travaDoTempo.unlock()
            }

            // **A porta: um quadro cuja referência foi condenada não vai para a tela.**
            //
            // Ele continua sendo **decodificado** — parar de alimentar o VideoToolbox deixaria a
            // sessão dessincronizada e o IDR seguinte chegaria num decodificador com buraco. O
            // que ele não faz é ser oferecido à camada: a tela fica com o último quadro bom até
            // a cadeia se curar, que é o que todo produto de espelhamento faz.
            if segurarEsteQuadro {
                travaDoTempo.lock(); retidos &+= 1; travaDoTempo.unlock()
                return
            }
            if self.exibidor.oferecer(imagem) {
                let agora = Medidas.agoraUs()
                travaDoTempo.lock()
                if primeiraImagemUs == 0 { primeiraImagemUs = agora }
                ultimaImagem = (tsEmDecodificacao, agora)
                if claquete, let v = valorDaMarca, imagensDaClaquete.count < 100_000 {
                    imagensDaClaquete.append((v, agora, tsEmDecodificacao))
                }
                dimensaoDoVideo = (CVPixelBufferGetWidth(imagem), CVPixelBufferGetHeight(imagem))
                travaDoTempo.unlock()
            }
        }
        trava.lock(); self.decodificador = decodificador; trava.unlock()

        let registro = nucleo.ouvirQuadros { [weak decodificador] bytes, ts, idr in
            self.gravadorRecebido.quadro(bytes, timestampUs: ts, idr: idr)
            let agora = Medidas.agoraUs()
            travaDoTempo.lock()
            ultimaChegadaUs = agora
            if idr {
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
                // para sempre — e esse emissor existiu nesta bancada.
                if condenadaDesdeUs != 0,
                   Medidas.delta(agora, condenadaDesdeUs) > Receptor.congelarNoMaximoMs * 1000 {
                    // O intervalo entra na conta do mesmo jeito: ele não terminou porque a imagem
                    // se curou, terminou porque desistimos de esperar, e esconder o pior caso é o
                    // oposto do que este contador existe para fazer.
                    duracoesSemReferenciaUs.append(Medidas.delta(agora, condenadaDesdeUs))
                    cadeiaCondenada = false
                    condenadaDesdeUs = 0
                }
            }
            segurarEsteQuadro = cadeiaCondenada && Receptor.congelarNaRuptura
            tsEmDecodificacao = ts
            travaDoTempo.unlock()
            decodificador?.alimentar(annexb: bytes, timestampUs: ts, idr: idr)
            segurarEsteQuadro = false
        }
        guard registro == QUALL_STATUS_OK else {
            let motivo = "quall_track_on_frame recusou: \(NucleoReceptor.nome(registro))"
            Registro.compartilhado.linha("receptor: falha; causa=\(SanitizacaoDoLog.causaExterna(motivo))")
            naMain { self.mensagem = motivo }
            desmontar(voltarAoFormulario: true)
            return
        }

        var pedidos = pedirIdrAoEntrar()
        var ultimoPedidoUs = Medidas.agoraUs()

        // O som: se a track dele chegou antes do vídeo, ele sobe agora; senão, a espiada do laço
        // o adota quando chegar.
        var somTentado = false
        if nucleo.temTrackDeAudio { somTentado = true; montarSom() }
        var deltas = Delta.Acumulador()
        var ultimaCameraUs: UInt64 = 0
        let refreshUs = refreshDaTelaUs

        let fimUs: UInt64? = argumentos.segundos.map { Medidas.agoraUs() &+ UInt64($0 * 1_000_000) }
        var motivoDaSaida = ""
        var ultimoRelatoUs: UInt64 = 0

        // **O controle da câmera do outro lado** (R9b): um por sessão, bombeado neste laço — a bombeada é o
        // leitor do canal desta sessão de vídeo (§2). Um filmador de build anterior nunca responde: aos 5 s
        // a situação vai a `sem_resposta`, e a tela não mostra controle nenhum.
        let controle = ControleDaCameraRemota()
        let mensagensDaCamera = controle != nil ? nucleo.mensagens() : nil
        var bombeandoACamera = mensagensDaCamera != nil
        var tamanhoPublicado = CGSize.zero
        var releituraDaCameraUs: UInt64 = 0
        trava.lock(); controleRemoto = bombeandoACamera ? controle : nil; trava.unlock()

        while !nucleo.parou {
            gravadorRecebido.relogios(video: nucleo.deslocamentoCruDeCaptura(doSom: false),
                                     audio: nucleo.deslocamentoCruDeCaptura(doSom: true))
            trava.lock(); let pedidoGravacao = pedirIDRDaGravacao; pedirIDRDaGravacao = false; trava.unlock()
            if pedidoGravacao { _ = nucleo.pedirIdr() }
            if let fimUs, Medidas.agoraUs() >= fimUs {
                motivoDaSaida = "o tempo de bancada (--segundos) acabou"
                break
            }

            // O detector de queda, com prazo pequeno: ele olha a sinalização, que sabe em
            // milissegundos, em vez de esperar o `CONSENT_TIMEOUT` de 30 s do libjuice.
            let e = nucleo.evento(prazoMs: 50)
            if e == QUALL_SESSION_EVENT_DISCONNECTED {
                motivoDaSaida = T("O aparelho em %@ encerrou a transmissão.", endereco)
                break
            }
            if e == QUALL_SESSION_EVENT_FAILED {
                motivoDaSaida = T("A conexão de mídia com %@ caiu — o pareamento tinha dado "
                    + "certo, o que falhou foi o transporte. Confira se os dois estão na mesma "
                    + "rede e tente conectar de novo.", endereco)
                break
            }

            if bombeandoACamera, let controle, let m = mensagensDaCamera {
                let b = controle.bombear(m, prazoMs: 0)
                // A cada mudança, e uma vez por segundo: a linha da recusa some 3 s depois sem acender bit.
                let agoraUs = Medidas.agoraUs()
                if b.mudou != 0 || Medidas.delta(agoraUs, releituraDaCameraUs) > 1_000_000 {
                    releituraDaCameraUs = agoraUs
                    publicarCameraRemota(controle)
                }
                if b.acabou { bombeandoACamera = false }
            }

            // **A track de som pode chegar depois da de vídeo**, e chega assim em quase todo
            // emissor: é a segunda do `tracks` do `quall_host`. Uma espiada com prazo zero por
            // volta, da mesma thread do `next_event`. Para de espiar quando uma é adotada.
            if !somTentado {
                if !nucleo.temTrackDeAudio {
                    nucleo.adotarProximaTrack(prazoMs: 0, aoLargar: { motivo in
                        Registro.compartilhado.linha("receptor: track largada — \(motivo)")
                    })
                }
                if nucleo.temTrackDeAudio { somTentado = true; montarSom() }
            }

            let agora = Medidas.agoraUs()
            travaDoTempo.lock()
            let temImagem = primeiraImagemUs != 0
            let silencio = Medidas.delta(agora, ultimaChegadaUs)
            let imagemParaODelta = ultimaImagem
            let dimensao = dimensaoDoVideo
            let desdeAPrimeira = primeiraImagemUs == 0 ? 0 : Medidas.delta(agora, primeiraImagemUs)
            travaDoTempo.unlock()
            let tamanho = CGSize(width: dimensao.largura, height: dimensao.altura)
            if tamanho != tamanhoPublicado {
                tamanhoPublicado = tamanho
                naMain { self.tamanhoDoVideo = tamanho }
            }

            // `--recapturar-janela` (T1 da S7): meio segundo depois da primeira imagem, a janela já
            // tem o tamanho dela; uma tentativa só.
            if claquete, argumentos.recapturarJanela, !recapturaTentada, temImagem,
               desdeAPrimeira > 500_000, dimensao.largura > 0 {
                recapturaTentada = true
                ligarARecaptura(largura: dimensao.largura, altura: dimensao.altura, refreshUs: refreshUs)
            }

            // O som a cada volta: a razão do núcleo no Varispeed, a câmera do Quall (1 Hz), e uma
            // amostra do Δ.
            if Medidas.delta(agora, ultimaCameraUs) >= 1_000_000 {
                ultimaCameraUs = agora
                olharACamera()
            }
            if let d = ajustarSomEAmostrarDelta(imagem: imagemParaODelta, refreshUs: refreshUs, agoraUs: agora) {
                deltas.somar(d)
            }

            // **Pedir IDR não é só na entrada.** Um quadro incompleto é descartado inteiro pelo
            // núcleo e nada no caminho pede reparo: o decodificador segue decodificando quadros P
            // contra uma referência que nunca chegou, e o que se vê é rastro e macrobloco sujo até
            // o IDR espontâneo seguinte. `quall_track_frames_dropped` é o gatilho, e a supressão
            // de `repetirIdrMs` faz uma rajada de perda custar **um** pedido, não um por quadro.
            let descartados = nucleo.quadrosDescartados()
            let houveRuptura = descartados > descartadosNaUltimaVolta
            descartadosNaUltimaVolta = descartados

            // A mesma ruptura que dispara o pedido de IDR passa a **condenar a cadeia de
            // referência**. Os dois usos são o mesmo fato lido de dois jeitos: pedir IDR conserta
            // a recuperação; condenar a cadeia conserta o que se mostra até ela chegar.
            //
            // **A granularidade é a do laço, e ela é de ~100 ms — não de 50.**
            //
            // Uma volta custa `nucleo.evento(prazoMs: 50)` **mais** o `Thread.sleep(0.05)` do fim
            // do laço, e numa sessão em regime nenhum evento de sessão chega, então o `evento`
            // gasta o prazo inteiro. O receptor iOS tem exatamente a mesma estrutura e a
            // documenta como *"laço de 20 Hz … até 50 ms"*: **está subestimada pela metade**, e a
            // conta certa é ~100 ms, ou cerca de três quadros a 30 fps contados como bons depois
            // de uma ruptura que já aconteceu.
            //
            // O erro é sempre para o mesmo lado — `suspeitos` é um **piso**, e o número real é
            // maior ou igual ao relatado. Digo isto aqui e na linha de relato porque um contador
            // que se apresenta como exato e não é já custou uma semana a este projeto
            // (`packets_missing`). O receptor Android condena **por quadro** e não tem este erro;
            // ver `docs/medida-universal.md`.
            //
            // `quall_track_frames_dropped` **não pode ser lido do tratador de quadro**: o núcleo
            // despacha o tratador com o cadeado do depacotizador na mão e o acessor pega o mesmo
            // cadeado, que é um travamento na thread da libdatachannel. Por isso a leitura mora
            // aqui, no laço, e o tratador só consulta a bandeira.
            if houveRuptura {
                travaDoTempo.lock()
                rupturas &+= 1
                if !cadeiaCondenada { condenadaDesdeUs = agora }
                cadeiaCondenada = true
                travaDoTempo.unlock()
            }

            if !temImagem || houveRuptura,
               Medidas.delta(agora, ultimoPedidoUs) > Receptor.repetirIdrMs * 1000 {
                if nucleo.pedirIdr() == QUALL_STATUS_OK { pedidos &+= 1 }
                ultimoPedidoUs = agora
            }

            if silencio > Receptor.silencioAteDesistirMs * 1000 {
                motivoDaSaida = T("%@ s sem nenhum quadro.", Receptor.silencioAteDesistirMs / 1000)
                break
            }

            // **O caminho de volta do sinal**, a 2 Hz. Sem ele o controlador de taxa do emissor é
            // inerte por construção quando o receptor é esta casca: ele só age sobre amostra que
            // chega de volta, e nunca chegava nenhuma. Medido em 31/08/2026 com receptor iOS, que
            // então também não tinha esta parte: `trocas_de_bitrate=0` com 2,95 % de perda e 881
            // quadros exibidos com a referência quebrada.
            //
            // Sai **sempre**, sem sinalizador de bancada. Nos dois braços de um A/B o mesmo
            // tráfego de relato precisa estar no ar, senão a diferença entre eles pode ser
            // explicada por ele. Custa ~129 bytes por janela — 0,05 % de um vídeo de 4 Mbps.
            //
            // **Daqui, e não do tratador de quadro**, por duas razões que apontam para o mesmo
            // lugar: o header exige que `quall_session_report_link` saia da mesma thread que
            // chama `quall_session_next_event`, que é esta; e ler contador do núcleo de dentro do
            // tratador **trava** — o núcleo o despacha com o cadeado do depacotizador na mão e
            // `quall_track_stats_json` pega o mesmo cadeado, na thread da libdatachannel, que
            // leva o caminho de mídia inteiro junto. É a mesma razão do `quadrosDescartados()`
            // logo acima.
            if Medidas.delta(agora, ultimoEnlaceUs) >= Receptor.janelaDoEnlaceMs * 1000 {
                ultimoEnlaceUs = agora
                travaDoTempo.lock()
                let suspeitosAcum = suspeitos
                travaDoTempo.unlock()
                // Leitura falha do núcleo custa **um tique** e não fecha a janela: fechar
                // com zeros zeraria a âncora, e a janela seguinte entregaria a sessão inteira
                // como dano de 500 ms. Ver `JanelaDoEnlace.acumulados`.
                if let acum = JanelaDoEnlace.acumulados(nucleo.contadores()),
                   let a = janelaDoEnlace.fechar(
                    agoraUs: agora, periodoMs: Receptor.janelaDoEnlaceMs,
                    vistosAcum: acum.vistos, perdidosAcum: acum.perdidos,
                    suspeitosAcum: suspeitosAcum, idrsQuebradosAcum: acum.idrsQuebrados
                ) {
                    Registro.compartilhado.linha(a.linha)
                    let st = nucleo.relatarEnlace(ms: a.ms, pacotes: a.pacotes,
                                                  perdidos: a.perdidos, suspeitos: a.suspeitos,
                                                  idrsQuebrados: a.idrsQuebrados)
                    if st != QUALL_STATUS_OK, relatosRecusados < 3 {
                        relatosRecusados += 1
                        // Três vezes e cala. Um emissor de versão antiga não escuta por conta
                        // própria e não há nada a fazer sobre isso; um socket morto aparece no
                        // detector de queda logo acima, e não é esta linha que decide isso.
                        Registro.compartilhado.linha(
                            "receptor: o relato do enlace não saiu (status=\(NucleoReceptor.nome(st)))")
                    }
                }
            }

            if Medidas.delta(agora, ultimoRelatoUs) > 1_000_000 {
                ultimoRelatoUs = agora
                travaDoTempo.lock()
                let img = primeiraImagemUs
                let m = (certas, erradas, repetidas, ausentes)
                let sus = (rupturas, suspeitos, max(piorRajada, suspeitosNaRajada), retidos)
                let dur = duracoesSemReferenciaUs
                travaDoTempo.unlock()
                relatar(subiuEm: subiuEm, primeiraImagemUs: img, pedidos: pedidos, marcas: m,
                        suspeita: sus, semReferenciaUs: dur, fim: false)
                relatarSom(subiuEm: subiuEm, deltas: deltas, fim: false)
                if claquete {
                    travaDoTempo.lock()
                    let imagens = imagensDaClaquete
                    imagensDaClaquete.removeAll(keepingCapacity: true)
                    travaDoTempo.unlock()
                    relatarClaquete(imagens: imagens, refreshUs: refreshUs)
                }
            }

            // Uma pausa curta: o `next_event` já esperou 50 ms, e o caminho do quadro não passa
            // por este laço em lugar nenhum — ele vive no tratador do núcleo.
            Thread.sleep(forTimeInterval: 0.05)
        }

        travaDoTempo.lock()
        let img = primeiraImagemUs
        let m = (certas, erradas, repetidas, ausentes)
        let susFim = (rupturas, suspeitos, max(piorRajada, suspeitosNaRajada), retidos)
        let durFim = duracoesSemReferenciaUs
        travaDoTempo.unlock()
        relatar(subiuEm: subiuEm, primeiraImagemUs: img, pedidos: pedidos, marcas: m,
                suspeita: susFim, semReferenciaUs: durFim, fim: true)
        relatarSom(subiuEm: subiuEm, deltas: deltas, fim: true)

        pararARecaptura(refreshUs: refreshUs)
        trava.lock(); controleRemoto = nil; trava.unlock()
        if let controle, mensagensDaCamera != nil {
            Registro.compartilhado.linha("receptor: camera remota: fim")
        }
        naMain {
            self.cameraRemota = nil
            self.tamanhoDoVideo = .zero
        }
        if !motivoDaSaida.isEmpty { Registro.compartilhado.linha("receptor: saída: \(motivoDaSaida)") }
        let texto = nucleo.parou ? T("Recepção encerrada.") : motivoDaSaida
        naMain { self.mensagem = texto }
        desmontar(voltarAoFormulario: true)
    }

    // MARK: - a câmera do outro lado (R9b)

    /// Lê o estado do controle e o publica na principal; diz no diário quando a situação ou a recusa mudam.
    private func publicarCameraRemota(_ controle: ControleDaCameraRemota) {
        let json = controle.estadoJson()
        guard let e = EstadoDaCameraRemota.ler(json) else { return }
        naMain {
            guard self.cameraRemota != e else { return }
            let antes = self.cameraRemota
            self.cameraRemota = e
            if antes?.situacao != e.situacao {
                Registro.compartilhado.linha("receptor: camera remota: situação mudou; capacidades_presentes=\(e.capacidades != nil)")
            }
            if let r = e.recusa, antes?.recusa?.motivo != r.motivo || antes?.recusa?.campo != r.campo {
                Registro.compartilhado.linha("receptor: camera remota: recusa=\(SanitizacaoDoLog.codigoRemoto(r.motivo)) campo_presente=\(r.campo != nil)")
            }
            if antes?.ajuste != e.ajuste || antes?.autor != e.autor {
                Registro.compartilhado.linha("receptor: camera remota: ajuste mudou")
            }
        }
    }

    private var controleDaSessao: ControleDaCameraRemota? {
        trava.lock(); defer { trava.unlock() }
        return controleRemoto
    }

    /// Um gesto no painel: só os campos mexidos (§12, receptor, item 3). Relê o estado logo depois, para o
    /// pendente aparecer por cima sem esperar a volta do laço (o pedido não acende bit nenhum).
    func pedirNaCameraRemota(_ campos: [String: Any]) {
        guard let c = controleDaSessao else { return }
        let json = PedidoDoReceptor.json(campos)
        let st = c.pedir(json)
        Registro.compartilhado.linha("receptor: camera remota: pedir campos=\(campos.count) status=\(NucleoReceptor.nome(st))")
        publicarCameraRemota(c)
    }

    /// "Restaurar automático" na câmera do outro lado.
    func restaurarCameraRemota() {
        guard let c = controleDaSessao else { return }
        let st = c.restaurar()
        Registro.compartilhado.linha("receptor: camera remota: restaurar = \(NucleoReceptor.nome(st))")
        publicarCameraRemota(c)
    }

    /// O clique na imagem: o ponto já no quadro decodificado (`PontoNoQuadro`); ⌥-clique trava (o toque longo).
    func tocarNaCameraRemota(_ p: CGPoint, longo: Bool) {
        guard let c = controleDaSessao else { return }
        let st = c.tocar(x: Double(p.x), y: Double(p.y), longo: longo)
        Registro.compartilhado.linha(String(format: "receptor: camera remota: toque %.3f,%.3f%@ = %@", p.x, p.y,
                                            longo ? " longo" : "", NucleoReceptor.nome(st)))
        publicarCameraRemota(c)
    }

    // MARK: - o som

    /// Abre a porta puxada na track de som e liga o motor. Falhar aqui **não** derruba a imagem:
    /// um receptor sem som ainda exibe, e o diário diz por quê.
    ///
    /// **O ganho vale antes de o motor ligar** (crítica 9, M5): a câmera é lida e o ganho aplicado
    /// antes do `iniciar()`, e o primeiro render já sai mudo quando é para sair mudo.
    private func montarSom() {
        guard let adotado = nucleo.somAdotado else { return }
        let (porta, motivo) = nucleo.abrirSom()
        guard let porta else {
            Registro.compartilhado.linha("receptor: som: !! não abriu — \(SanitizacaoDoLog.causaExterna(motivo))")
            naMain { self.somEstado = T("sem som: %@", motivo) }
            return
        }
        if argumentos.claquete { porta.ligarClaquete() }
        gravadorRecebido.configurarSom(canais: porta.formato.canais,
            atrasoAudioUs: Int64(porta.formato.atrasoInternoUs))
        porta.aoPCM = { [weak self] bytes, n, ts in
            self?.gravadorRecebido.som(bytes, amostras: n, timestampUs: ts)
        }
        let t = Tocador(formato: porta.formato, fonte: porta.fonte)
        t.aoRegistrar = { linha in Registro.compartilhado.linha("receptor: \(linha)") }
        trava.lock()
        tocador = t
        trava.unlock()
        // Um motor novo conta do zero: sem isto, a primeira volta de relato da sessão seguinte
        // subtraía contadores de outro motor.
        puxadasNoRelatoAnterior = 0
        ociosasNoRelatoAnterior = 0
        voltasOciosasSeguidas = 0
        testemunhaDaDeriva.zerar()
        religamentosNaTestemunha = 0
        olharACamera()
        aplicarVontadeDoSom()
        Registro.compartilhado.linha(
            "receptor: som: \(adotado.rotulo) (\(adotado.especie)) \(porta.codec), motor a "
            + "\(Int(porta.formato.taxaHz)) Hz × \(porta.formato.canais), porta puxada com o Varispeed, "
            + String(format: "ganho inicial %.2f", t.retrato().ganho))
        if !t.iniciar() {
            // O `Tocador` tenta de novo sozinho; a janela diz "sem som" enquanto isso (M7).
            Registro.compartilhado.linha("receptor: som: !! a saída não ligou de primeira — "
                                         + t.retrato().ultimaFalha)
        }
        aplicarVontadeDoSom()
    }

    /// Junta mudo, volume, câmera e a chave da câmera no ganho, e a linha da janela. De qualquer
    /// thread.
    private func aplicarVontadeDoSom() {
        trava.lock()
        vontadeDoSom.mudo = somMudo
        vontadeDoSom.volume = somVolume
        vontadeDoSom.tocarComACamera = somComACamera
        let v = vontadeDoSom
        let t = tocador
        let ocioso = somOciosoAgora
        trava.unlock()
        t?.aplicarGanho(v.ganho)
        var texto = ""
        if let t {
            let r = t.retrato()
            if !r.ligado {
                texto = T("sem som: %@", r.ultimaFalha.isEmpty ? T("a saída está sendo remontada") : r.ultimaFalha)
            } else if let calado = v.porQueCalado {
                texto = T("som: %@", calado)
            } else if ocioso {
                // A track em IDLE há duas voltas ou mais. Daqui não se distingue o D2 (o emissor
                // manda o som a outro receptor) do emissor que parou de mandar, e a frase diz as
                // duas coisas (reconferência da S4, miúdo 6).
                texto = T("som: nada chegando do emissor (o som pode estar com outro receptor)")
            } else {
                texto = String(format: T("som: tocando, volume %.0f%%"), v.ganho * 100)
            }
        }
        naMain { if self.somEstado != texto { self.somEstado = texto } }
    }

    /// D3: a câmera do Quall em uso cala o som. Lida a 1 Hz, do laço da sessão, e antes de o motor
    /// ligar. Rodando é em uso, com o app da câmera aberto ou não (ver `EstadoDaCameraDoQuall`).
    private func olharACamera() {
        // Sem motor de som, a câmera não muda nada: o CoreMediaIO não é lido (crítica 9, miúdo 15).
        // O `montarSom` chama esta função logo depois de pôr o `tocador`.
        trava.lock()
        let semSom = tocador == nil
        trava.unlock()
        if semSom { return }
        let estado = CameraDoQuall.emUso()
        trava.lock()
        let anterior = vontadeDoSom.camera
        vontadeDoSom.camera = estado
        let t = tocador
        trava.unlock()
        guard anterior != estado else { return }
        if t != nil {
            Registro.compartilhado.linha("receptor: som: câmera do Quall \(anterior.descricao) → "
                                         + "\(estado.descricao)")
        }
        aplicarVontadeDoSom()
    }

    /// A razão do núcleo no Varispeed, e uma amostra do Δ quando os dois lados têm hora e o relógio
    /// comum vale. Do laço da sessão.
    ///
    /// **O que esta testemunha é** (T1 do §9.4, sem a recaptura da janela): o lado do som é a hora
    /// do DAC que o motor calcula (o ciclo da saída, as latências declaradas e a do Varispeed, e o
    /// filtro do PCMU); o lado da imagem é a hora em que a camada aceitou o quadro **mais um refresh
    /// declarado** — que sai cedo, porque falta o tempo até o compositor pegar o quadro. As capturas
    /// vêm do relógio comum. Não é independente do estimador: latência declarada errada aparece
    /// igual.
    private func ajustarSomEAmostrarDelta(imagem: (ts: UInt64, hostUs: UInt64)?, refreshUs: UInt64,
                                          agoraUs: UInt64) -> Int64? {
        trava.lock()
        let t = tocador
        trava.unlock()
        guard let t, let porta = nucleo.portaDeSom else { return nil }
        t.ajustarRazao(porta.razaoSugerida())
        let som = t.montador.retrato()
        guard som.temUltimo, let imagem,
              Medidas.delta(agoraUs, imagem.hostUs) < 500_000,
              let offSom = nucleo.deslocamentoDeCaptura(doSom: true),
              let offImagem = nucleo.deslocamentoDeCaptura(doSom: false) else { return nil }
        return Delta.us(som: (Int64(som.ultimoCarimboUs) + offSom, som.ultimoNoDacUs),
                        imagem: (Int64(imagem.ts) + offImagem, imagem.hostUs &+ refreshUs))
    }

    /// `--claquete`: as horas cruas, para o roteiro casar com a verdade da sonda.
    /// - imagem, `r:hora:captura`: o índice da régua, a hora do host em que a camada aceitou o
    ///   quadro, e a captura dele pelo relógio comum (`-` sem o relógio);
    /// - som, `hora:captura`: a hora em que o estouro sai no DAC, e a captura dele pelo relógio
    ///   comum. É com as capturas que o roteiro lê o **T0** do §9.4 (crítica 10, M8).
    private func relatarClaquete(imagens: [(r: Int, hostUs: UInt64, ts: UInt64)], refreshUs: UInt64) {
        trava.lock()
        let rec = recaptura
        trava.unlock()
        if let janela = rec?.tirar(), !janela.isEmpty {
            // A janela recapturada, `r:hora`: o índice da régua na primeira imagem composta em que
            // ele apareceu, e a hora do compositor (o `pts` do SCK) no relógio do app. O roteiro
            // soma o refresh, como no lado da camada.
            Registro.compartilhado.linha("receptor claquete janela refresh_us=\(refreshUs) "
                + janela.map { "\($0.r):\($0.hostUs)" }.joined(separator: ","))
        }
        let sons = nucleo.portaDeSom?.tirarEstouros() ?? []
        let offImagem = nucleo.deslocamentoDeCaptura(doSom: false)
        let offSom = nucleo.deslocamentoDeCaptura(doSom: true)
        if !imagens.isEmpty {
            Registro.compartilhado.linha("receptor claquete imagem refresh_us=\(refreshUs) "
                + imagens.map { i in
                    "\(i.r):\(i.hostUs):" + (offImagem.map { String(Int64(i.ts) + $0) } ?? "-")
                }.joined(separator: ","))
        }
        if !sons.isEmpty {
            Registro.compartilhado.linha("receptor claquete som "
                + sons.map { e in "\(e.noDacUs):" + (offSom.map { String(e.carimboUs + $0) } ?? "-") }
                    .joined(separator: ","))
        }
    }

    /// Liga a recaptura da janela (T1 da S7), sem segurar a thread da sessão: a geometria é lida na
    /// main, e o SCK sobe numa tarefa.
    private func ligarARecaptura(largura: Int, altura: Int, refreshUs: UInt64) {
        let camada = exibidor.camada
        // **O dobro da taxa do painel** (S7, §20.6, medido): pedido na taxa do painel, o SCK
        // entregou a imagem composta de 0 a 2 refreshes depois (B − C de 2 a 33 ms por evento); no
        // dobro, a mesma montagem deu 10,9 a 13,9 ms. É o "intervalo mínimo de meio período" que o
        // `ScreenCapturer` já usa pelo mesmo motivo.
        let hz = argumentos.recapturarJanelaHz ?? 2 * Int((1_000_000 / Double(max(refreshUs, 1))).rounded())
        let registrar: (String) -> Void = { Registro.compartilhado.linha("receptor: \($0)") }
        trava.lock(); sessaoDaRecapturaAcabou = false; trava.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let g = RecapturaDaJanela.geometria(camada: camada, largura: largura, altura: altura) else {
                registrar("recaptura: a janela do vídeo não foi achada; nada capturado")
                return
            }
            Task { [weak self] in
                let r = await RecapturaDaJanela.iniciar(geometria: g, hz: hz, registrar: registrar)
                guard let r else { return }
                guard let self, self.guardarARecaptura(r) else {
                    await r.parar()
                    registrar("recaptura: a sessão acabou enquanto o SCK subia; a recaptura foi parada")
                    return
                }
            }
        }
    }

    /// Guarda a recaptura, se a sessão ainda estiver de pé. `false`: ela já acabou, e quem chamou
    /// para o SCK.
    private func guardarARecaptura(_ r: RecapturaDaJanela) -> Bool {
        trava.lock(); defer { trava.unlock() }
        if sessaoDaRecapturaAcabou { return false }
        recaptura = r
        return true
    }

    /// Para a recaptura e escreve o resumo dela: quantas imagens, quantas sem régua, e a entrega do
    /// SCK (a conferência da base do `pts`).
    private func pararARecaptura(refreshUs: UInt64) {
        trava.lock()
        sessaoDaRecapturaAcabou = true
        let r = recaptura
        recaptura = nil
        trava.unlock()
        guard let r else { return }
        let resto = r.tirar()
        if !resto.isEmpty {
            Registro.compartilhado.linha("receptor claquete janela refresh_us=\(refreshUs) "
                + resto.map { "\($0.r):\($0.hostUs)" }.joined(separator: ","))
        }
        let pronto = DispatchSemaphore(value: 0)
        Task { await r.parar(); pronto.signal() }
        _ = pronto.wait(timeout: .now() + 2)
        let m = r.retrato()
        let e = m.entregas.sorted()
        let q: (Double) -> String = { p in
            e.isEmpty ? "?" : String(format: "%.1f", Double(e[min(e.count - 1, Int(p * Double(e.count - 1)))]) / 1000)
        }
        Registro.compartilhado.linha(
            "receptor claquete janela FIM imagens=\(m.imagens) incompletas=\(m.incompletas) "
            + "sem_regua=\(m.semRegua) trocas_de_regua=\(m.trocasDeRegua) "
            + "entrega_ms=[p05=\(q(0.05)) p50=\(q(0.5)) p95=\(q(0.95))]")
    }

    private func relatarSom(subiuEm: UInt64, deltas: Delta.Acumulador, fim: Bool) {
        trava.lock()
        let t = tocador
        let v = vontadeDoSom
        trava.unlock()
        guard let t, let porta = nucleo.portaDeSom else { return }
        let r = t.retrato()
        let m = r.montador
        // A track em IDLE: nesta volta, só puxadas ociosas.
        let puxadasNaVolta = m.puxadas &- puxadasNoRelatoAnterior
        let ociosasNaVolta = m.ociosas &- ociosasNoRelatoAnterior
        puxadasNoRelatoAnterior = m.puxadas
        ociosasNoRelatoAnterior = m.ociosas
        if r.religamentos != religamentosNaTestemunha {
            testemunhaDaDeriva.zerar()
            religamentosNaTestemunha = r.religamentos
        }
        testemunhaDaDeriva.adicionar(horaUs: r.horaDoCicloDoDacUs, quadros: r.quadrosDoDac)
        voltasOciosasSeguidas = puxadasNaVolta > 0 && ociosasNaVolta == puxadasNaVolta
            ? voltasOciosasSeguidas + 1 : 0
        trava.lock()
        somOciosoAgora = voltasOciosasSeguidas >= 2
        trava.unlock()
        aplicarVontadeDoSom()
        let decorrido = Double(Medidas.delta(Medidas.agoraUs(), subiuEm)) / 1_000_000
        // O relógio da track de som: o `clock` do JSON dela, compacto.
        var relogio = "null"
        if let dados = nucleo.contadoresDoSom().data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
           let c = o["clock"], !(c is NSNull),
           let j = try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys]),
           let texto = String(data: j, encoding: .utf8) {
            relogio = texto
        }
        let pico = t.tirarPicoNaSaida()
        let picoDb = pico > 0 ? 20 * log10(Double(pico)) : -.infinity
        Registro.compartilhado.linha(String(
            format: "receptor som %@ t=%.1fs %@ %.0fHz×%d ligado=%@ ganho=%.2f%@ camera_quall=%@ "
                + "tocar_com_camera=%@ razao=%.6f renders=%llu render=[%d..%d] puxadas=%llu ociosas=%llu "
                + "silencios=%llu curas=%llu hora_do_render=valida:%llu,estimada:%llu "
                + "latencia_declarada=%.2fms atraso_interno=%.2fms buffer_saida=%.1fms taxa_da_saida=%.0fHz "
                + "religamentos=%llu tentativas_falhas=%llu ultima_falha=\"%@\" pico_na_saida=%.1fdBFS "
                + "quadros_pedidos=%llu taxa_medida_da_saida=%.3fHz dac_vs_host_ppm=%@ "
                + "delta_ms=%@ porta=%@ relogio=%@",
            fim ? "FIM" : "1Hz", decorrido, porta.codec, porta.formato.taxaHz, porta.formato.canais,
            r.ligado ? "sim" : "NAO", v.ganho, v.porQueCalado.map { " (\($0))" } ?? "",
            v.camera.descricao, v.tocarComACamera ? "sim" : "nao", r.razao,
            m.renders, m.menorRender == Int.max ? 0 : m.menorRender, m.maiorRender,
            m.puxadas, m.ociosas, m.silencios, m.curas,
            r.horaDoRenderValida, r.horaDoRenderEstimada, r.latenciaDeSaidaMs,
            porta.formato.atrasoInternoUs / 1000, r.bufferDeSaidaMs, r.taxaDaSaida,
            r.religamentos, r.tentativasFalhas, r.ultimaFalha, picoDb,
            m.quadrosPedidos, Tocador.taxaMedidaDaSaidaPadrao(),
            testemunhaDaDeriva.descricao(taxaNominalHz: r.taxaDaSaida),
            deltas.resumo, porta.contadores(), relogio))
    }

    // MARK: - pedaços

    /// Insiste no pedido de IDR até a track aceitar. Devolve quantos pedidos saíram de fato.
    ///
    /// O header é explícito: `quall_track_request_idr` devolve erro enquanto a track não abriu, e
    /// tentar de novo por alguns milissegundos é o comportamento certo. **Não é otimização**: o
    /// primeiro quadro depois de a track abrir se perde em cerca de metade das corridas (dívida
    /// 25), e um receptor que não pede espera o próximo IDR natural do emissor — com GOP longo,
    /// para sempre. O receptor Windows mediu 3,71 s de primeira imagem sem o pedido; o iOS mediu
    /// ~50 ms com ele.
    private func pedirIdrAoEntrar() -> UInt64 {
        let limite = Medidas.agoraUs() &+ Receptor.insistirIdrMs &* 1000
        var tentativas = 0
        while !nucleo.parou, Medidas.agoraUs() < limite {
            let st = nucleo.pedirIdr()
            tentativas += 1
            if st == QUALL_STATUS_OK {
                Registro.compartilhado.linha("receptor: IDR pedido ao entrar (na tentativa \(tentativas))")
                return 1
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Registro.compartilhado.linha(
            "receptor: !! a track não aceitou o pedido de IDR de entrada em "
            + "\(Receptor.insistirIdrMs) ms (\(tentativas) tentativas) — a primeira imagem vai "
            + "depender do IDR natural do emissor")
        return 0
    }

    /// **Ramifica pelo código, não pelo texto.** `quall_last_status()` existe desde 2026-08-26
    /// (dívida 27); antes dela a única saída era comparar prefixo de string em português.
    private func explicarFalhaDeConexao(endereco: String) {
        let status = nucleo.ultimoStatus
        let cru = nucleo.ultimoMotivo
        Registro.compartilhado.linha(
            "receptor: não conectou: status=\(NucleoReceptor.nome(status)) motivo=\(cru)")

        if nucleo.parou {
            naMain { self.mensagem = T("Cancelado."); self.precisaDePin = false }
            desmontar(voltarAoFormulario: true)
            return
        }

        let texto: String
        var pedirPin = false
        switch status {
        // **`WRONG_PIN` e `NEEDS_PIN` pedem coisas opostas, e o header é literal sobre isso**
        // (dívida 29). Antes de o código 15 existir os dois chegavam como `PAIRING` e a casca só
        // podia separá-los comparando texto de mensagem — que a frente do Windows recusou fazer,
        // e fez bem. Medido nesta bancada em 2026-08-30: PIN 999999 contra 111111 devolve 15, e
        // esta casca imprimiu `código 15` na primeira corrida porque `nome()` não tem `default`
        // silencioso. Era para ser assim.
        case QUALL_STATUS_WRONG_PIN:
            // Existe um PIN válido do outro lado; a digitação errou. E o PIN vale **uma tentativa
            // por conexão** — é isso que segura seis dígitos —, então o outro aparelho precisa
            // voltar a esperar antes de a próxima tentativa valer.
            texto = T("PIN errado. Confira os seis dígitos na tela do outro aparelho e toque em "
                + "Conectar de novo — cada tentativa vale por uma conexão.")
            pedirPin = true
        case QUALL_STATUS_NEEDS_PIN:
            // **Não é recusa, é convite a recomeçar** — a saída do beco sem saída da dívida 22. E
            // digitar o mesmo PIN de novo não leva a lugar nenhum: o que falta é um PIN **novo**.
            texto = T("O outro aparelho não reconhece mais este Mac. Peça um PIN novo na tela dele e "
                + "digite aqui.")
            pedirPin = true
        case QUALL_STATUS_PAIRING:
            // O caso residual, agora que o PIN errado tem código próprio.
            texto = T("O pareamento não fechou. Confira o PIN na tela do outro aparelho e tente de novo.")
            pedirPin = true
        // `IO` junto com `TIMEOUT` porque é o mesmo erro para quem digitou: um endereço certo com
        // porta errada volta `IO` com `Connection refused`, e "e/s: Connection refused (os error
        // 61)" na tela não diz o que fazer. É o erro mais provável de todos, porque o endereço é
        // digitado à mão.
        case QUALL_STATUS_TIMEOUT, QUALL_STATUS_IO:
            texto = T("Ninguém atendeu neste endereço. Confira se o outro aparelho já está esperando "
                + "e se o endereço e a porta estão certos.")
        case QUALL_STATUS_NO_ROUTE:
            texto = T("Os dois aparelhos não acharam caminho um até o outro. Confira se estão na mesma "
                + "rede Wi-Fi e se ela não isola os aparelhos entre si (rede de hóspedes).")
        case QUALL_STATUS_PROTOCOL:
            texto = T("O outro aparelho fala outra versão do Quall Studio. Atualize os dois.")
        case QUALL_STATUS_CANCELLED:
            texto = T("Cancelado.")
        default:
            texto = cru.isEmpty ? T("Não deu para conectar.") : T("Não deu para conectar: %@", cru)
        }
        let oferecerPin = pedirPin
        naMain { self.mensagem = texto; self.precisaDePin = oferecerPin }
        desmontar(voltarAoFormulario: true)
    }

    private func relatar(subiuEm: UInt64, primeiraImagemUs: UInt64, pedidos: UInt64,
                         marcas: (UInt64, UInt64, UInt64, UInt64),
                         suspeita: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0),
                         semReferenciaUs: [UInt64] = [], fim: Bool) {
        let d = decodificador?.instantaneo() ?? DecodificadorH264.Instantaneo()
        let e = exibidor.instantaneo()
        let agoraUs = Medidas.agoraUs()
        let decorrido = Double(Medidas.delta(agoraUs, subiuEm)) / 1_000_000

        // Taxa da **última volta**, não média da sessão: uma média desde o começo não sabe cair, e
        // um espelhamento que travasse aos 10 s de uma sessão de 60 s continuaria mostrando cinco
        // sextos da taxa nominal.
        let baseUs = relatoAnteriorUs == 0 ? subiuEm : relatoAnteriorUs
        let janela = Double(Medidas.delta(agoraUs, baseUs)) / 1_000_000
        let novos = e.enfileirados >= enfileiradosNoRelatoAnterior
            ? e.enfileirados - enfileiradosNoRelatoAnterior
            : e.enfileirados
        let taxa = janela > 0 ? Double(novos) / janela : 0
        relatoAnteriorUs = agoraUs
        enfileiradosNoRelatoAnterior = e.enfileirados

        let primeiraMs = primeiraImagemUs > 0
            ? Double(Medidas.delta(primeiraImagemUs, subiuEm)) / 1000 : 0
        let contadores = nucleo.contadores()
        let perda = ResumoDePerda.formatar(contadores)

        naMain {
            self.recebidos = d.recebidos
            self.enfileirados = e.enfileirados
            self.fps = taxa
            self.decodeP50Ms = Double(d.p50Us) / 1000
            self.decodeP95Ms = Double(d.p95Us) / 1000
            self.primeiraImagemMs = primeiraMs
            self.dimensao = "\(d.largura)x\(d.altura)"
            self.perfil = d.perfil
            self.marcasCertas = marcas.0
            self.marcasErradas = marcas.1
            self.marcasRepetidas = marcas.2
            self.rupturas = suspeita.0
            self.suspeitos = suspeita.1
            self.piorRajada = suspeita.2
            self.retidos = suspeita.3
            self.semReferenciaMs = Receptor.resumo(semReferenciaUs)
            self.contadoresDoNucleo = contadores
            self.resumoDePerda = perda
            self.idrs = d.idrsRecebidos
            self.semParametros = d.semParametros
            self.falhasDeSessao = d.falhasDeSessao
            self.ultimaFalha = Int32(d.ultimaFalha)
            self.camadaInvisivel = e.camadaInvisivel
        }

        Registro.compartilhado.linha(String(
            format: "receptor %@ t=%.1fs recebidos=%llu decodificados=%llu enfileirados=%llu "
                  + "nao_couberam=%llu sem_parametros=%llu recusados=%llu idrs=%llu pedidos_idr=%llu "
                  + "sessoes_criadas=%llu falhas_descricao=%llu falhas_sessao=%llu ultima_falha=%d "
                  + "primeira_imagem=%@ fps=%.1f decode_n=%d p50=%.2fms p95=%.2fms max=%.2fms "
                  + "dim=%dx%d %@ marca_certas=%llu marca_erradas=%llu marca_repetidas=%llu "
                  + "marca_ausentes=%llu "
                  // **Os cinco números que esta casca não tinha.** A régua acima diz se o quadro
                  // é o quadro certo; estes dizem se a imagem dele tinha **como** estar certa.
                  // `suspeitos` é amostrado a ~100 ms — é um piso. Ver o gatilho em `exibir`.
                  + "rupturas=%llu suspeitos=%llu pior_rajada=%llu retidos=%llu congelar=%@ "
                  + "sem_referencia_ms=%@ "
                  // **A fluidez**, que é a pergunta que `fps` não responde. `fps` acima é a taxa
                  // da última volta — um centro —, e um segundo com 29 quadros pontuais e um
                  // buraco de 200 ms tem o mesmo `fps` de um segundo regular. Estes quatro
                  // números mostram a cauda, que é o que o olho vê. Ver `Fluidez`.
                  + "%@ "
                  + "camada=%.0fx%.0f na_arvore=%@%@ pegada=%@ perda=[%@] nucleo=%@",
            fim ? "FIM" : "1Hz", decorrido,
            d.recebidos, d.decodificados, e.enfileirados, e.naoCouberam,
            // `sem_parametros` sozinho é ambíguo: sobe tanto quando o emissor não mandou SPS/PPS
            // quanto quando eles chegaram e o VideoToolbox recusou montar a sessão. Os quatro
            // seguintes separam os dois casos.
            d.semParametros, d.recusados, d.idrsRecebidos, pedidos,
            d.sessoesCriadas, d.falhasDeDescricao, d.falhasDeSessao, Int32(d.ultimaFalha),
            primeiraMs > 0 ? String(format: "%.1fms", primeiraMs) : "NUNCA",
            taxa, d.n, Double(d.p50Us) / 1000, Double(d.p95Us) / 1000, Double(d.maxUs) / 1000,
            d.largura, d.altura, d.perfil,
            marcas.0, marcas.1, marcas.2, marcas.3,
            suspeita.0, suspeita.1, suspeita.2, suspeita.3,
            Receptor.congelarNaRuptura ? "sim" : "NAO",
            Receptor.resumo(semReferenciaUs),
            e.fluidez,
            // A pergunta que faltava o dia inteiro no iOS: a camada tem área e está na árvore?
            // `camada=0x0` ou `na_arvore=NAO` explica sozinho uma tela preta com todos os outros
            // contadores fechando.
            e.larguraDaCamada, e.alturaDaCamada,
            e.camadaNaArvore ? "sim" : "NAO",
            e.camadaInvisivel ? "  *** CAMADA INVISIVEL: decodifica e nao mostra ***" : "",
            Medidas.pegadaDeMemoria(), perda, contadores))
    }

    /// A ordem obrigatória, e o destino da caixa dito em voz alta.
    ///
    /// O decodificador só é fechado **depois** de o tratador de quadro estar desregistrado com
    /// barreira: fechar antes deixaria um quadro em voo entrando numa sessão de VideoToolbox morta.
    private func desmontar(voltarAoFormulario: Bool) {
        gravadorRecebido.parar(receberSomAtrasado: false)
        // **O motor para antes de a porta ser liberada**: nenhuma puxada pode estar em curso quando
        // `quall_audio_playout_free` roda (`docs/contrato-som-puxado.md` §2).
        trava.lock()
        let t = tocador
        tocador = nil
        trava.unlock()
        if let t {
            t.parar()
            // A testemunha de que o motor parou **de verdade** antes de a porta ser solta: nenhum
            // render nos 50 ms depois do `parar()` (crítica 9, G1: "ninguém mediu"). Se algum
            // escapar, a porta ainda está atrás do cadeado dela e ele só vê ocioso.
            let antes = t.montador.retrato().renders
            Thread.sleep(forTimeInterval: 0.05)
            let depois = t.montador.retrato().renders
            let st = nucleo.encerrarSom()
            Registro.compartilhado.linha(
                "receptor: som desmontado: motor parado, renders_depois_do_parar=\(depois &- antes), "
                + "playout_free=\(st.map(NucleoReceptor.nome) ?? "n/a")")
            naMain { self.somEstado = "" }
        }
        let r = nucleo.encerrar()
        Registro.compartilhado.linha(
            "receptor: desmonte: on_frame(NULL)=\(r.desregistro.map(NucleoReceptor.nome) ?? "n/a") "
            + "session_close=\(r.fechamento.map(NucleoReceptor.nome) ?? "n/a") "
            + "caixa=\(r.caixaLiberada ? "liberada" : "VAZADA de propósito")")

        trava.lock()
        let d = decodificador
        decodificador = nil
        trava.unlock()
        d?.fechar()

        // A camada larga o último quadro decodificado. Num receptor que exibe a tela de outra
        // pessoa isso não é limpeza cosmética: é o conteúdo dela saindo da memória deste processo.
        exibidor.limpar()

        Registro.compartilhado.linha("receptor: pegada final: \(Medidas.pegadaDeMemoria())")
        guard voltarAoFormulario else { return }
        naMain { self.fase = .formulario }
    }
}
