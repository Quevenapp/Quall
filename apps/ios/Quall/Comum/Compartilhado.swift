import Foundation

/// O contrato entre o app e a Broadcast Upload Extension.
///
/// São **dois processos**, com memórias separadas, e o App Group é a única coisa que os liga. A
/// arquitetura decidida (`docs/arquitetura-ios.md`) põe a sessão inteira dentro da appex — ela
/// hospeda, espera, encoda e envia. Mas o **fluxo** (`docs/fluxo-de-uso.md`) põe o PIN, o nome
/// na rede, o IP e o botão Cancelar na tela do **app**, que é o único dos dois que tem tela.
///
/// Daí a necessidade de um canal, e ele tem três peças, cada uma num sentido:
///
/// | arquivo | quem escreve | quem lê | para quê |
/// |---|---|---|---|
/// | `pedido.json` | app | appex | PIN, porta, nome, teto de resolução |
/// | `estado.json` | appex | app | em que pé está a transmissão, e o erro quando há |
/// | `cancelar` | app | appex | o botão Cancelar da tela de espera |
///
/// **Por que arquivo e não `UserDefaults` compartilhado**: o `estado.json` é reescrito a 1 Hz
/// pela appex e lido a 1 Hz pelo app, e uma escrita atômica de duzentos bytes é a operação mais
/// simples que tem semântica de tudo-ou-nada entre processos. `UserDefaults` de App Group tem
/// cache por processo e latência de propagação que já mordeu outros projetos; aqui o preço de
/// errar é uma tela de espera que mente.
///
/// **O que este canal não é**: caminho de quadro. Nada disto é tocado por
/// `processSampleBuffer` nem pelo callback de saída do VideoToolbox.
public enum Compartilhado {
    public static let grupo = "group.br.com.queven.quall"

    public static var pasta: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: grupo)
    }

    static func arquivo(_ nome: String) -> URL? {
        pasta?.appendingPathComponent(nome)
    }

    // --- pedido: app → appex ----------------------------------------------------------------

    public static func gravarPedido(_ pedido: PedidoDeEspelhamento) {
        guard let alvo = arquivo("pedido.json") else { return }
        guard let dados = try? JSONEncoder().encode(pedido) else { return }
        try? dados.write(to: alvo, options: .atomic)
    }

    /// Devolve `nil` quando não há pedido — que é diferente de "há um pedido com valores
    /// padrão". A appex precisa saber a diferença: sem pedido, o PIN que ela usaria não é o que
    /// está escrito na tela do app, e a pessoa digitaria um PIN que nunca vai casar.
    public static func lerPedido() -> PedidoDeEspelhamento? {
        guard let alvo = arquivo("pedido.json"),
              let dados = try? Data(contentsOf: alvo),
              let pedido = try? JSONDecoder().decode(PedidoDeEspelhamento.self, from: dados)
        else { return nil }
        return pedido
    }

    public static func apagarPedido() {
        guard let alvo = arquivo("pedido.json") else { return }
        try? FileManager.default.removeItem(at: alvo)
    }

    // --- estado: appex → app ----------------------------------------------------------------

    public static func publicar(_ estado: EstadoDoEmissor) {
        guard let alvo = arquivo("estado.json") else { return }
        guard let dados = try? JSONEncoder().encode(estado) else { return }
        try? dados.write(to: alvo, options: .atomic)
    }

    public static func lerEstado() -> EstadoDoEmissor? {
        guard let alvo = arquivo("estado.json"),
              let dados = try? Data(contentsOf: alvo),
              let estado = try? JSONDecoder().decode(EstadoDoEmissor.self, from: dados)
        else { return nil }
        return estado
    }

    public static func apagarEstado() {
        guard let alvo = arquivo("estado.json") else { return }
        try? FileManager.default.removeItem(at: alvo)
    }

    // --- cancelar: app → appex --------------------------------------------------------------

    /// O botão Cancelar da tela de espera.
    ///
    /// Ele precisa funcionar **de verdade** — o fluxo diz isso com todas as letras, e o motivo é
    /// concreto: a pessoa concedeu gravação de tela, está vendo o indicador vermelho do sistema,
    /// e um Cancelar que só troca de tela deixa o indicador ligado e a transmissão correndo.
    ///
    /// Só a extension pode encerrar a própria transmissão (`finishBroadcastWithError`); o app
    /// não tem como. Então o Cancelar é um recado, e quem o executa é a supervisão de 1 Hz da
    /// appex — que **não** é a thread bloqueada em `quall_host`. Latência medida do desenho:
    /// até um segundo, independente de a espera pelo receptor estar no meio de uma tentativa.
    public static func pedirCancelamento() {
        guard let alvo = arquivo("cancelar") else { return }
        try? Data("1".utf8).write(to: alvo, options: .atomic)
    }

    public static var cancelamentoPedido: Bool {
        guard let alvo = arquivo("cancelar") else { return false }
        return FileManager.default.fileExists(atPath: alvo.path)
    }

    public static func limparCancelamento() {
        guard let alvo = arquivo("cancelar") else { return }
        try? FileManager.default.removeItem(at: alvo)
    }

    // --- pareamento persistido --------------------------------------------------------------

    /// `known_peers_json` do núcleo, guardado onde os **dois** processos alcançam.
    ///
    /// O fluxo promete PIN "uma vez por par de aparelhos, nunca por sessão". Quem cumpre essa
    /// promessa é este arquivo: sem gravá-lo, o núcleo trata todo receptor como desconhecido e
    /// a pessoa digita o PIN de novo toda vez.
    ///
    /// Fica no App Group, e não no `Documents` do app, porque no iOS quem hospeda a tela é a
    /// appex — é ela quem fecha o pareamento, e é ela quem precisa gravar o resultado.
    /// ## Dois escritores, e por que a escrita atômica não bastava (dívida 23)
    ///
    /// O pareamento é chaveado **só pelo `DeviceId`** — sem origem, sem porta. Isso é o
    /// comportamento certo e dá de graça a promessa do fluxo: quem pareou pela tela retoma pela
    /// câmera sem digitar nada. O preço é que os **dois processos** escrevem neste arquivo.
    ///
    /// A versão anterior lia no começo da tentativa de hospedar e escrevia depois de a sessão
    /// fechar — uma janela de **até vinte segundos** entre ler e escrever, com escrita atômica de
    /// arquivo e nenhuma trava entre processos. Atômica garante que ninguém lê meio arquivo; não
    /// garante nada sobre duas leituras-modificações-escritas cruzadas.
    ///
    /// E o caso ruim não é perder uma entrada. É este: se as duas origens parearem **por PIN com
    /// o mesmo receptor**, cada pareamento deriva um segredo **diferente** (efêmeras e nonces
    /// novos), e o receptor guarda os dois sob a mesma chave — o segundo sobrescreve o primeiro.
    /// Se o lado do iPhone perdeu a atualização, os dois lados ficam com segredos distintos para
    /// a **mesma** chave, e a retomada seguinte falha duro com "o aparelho do outro lado não é o
    /// que foi pareado". Como não há volta para o PIN no núcleo (dívida 22), isso é um beco sem
    /// saída: funcionou ontem, hoje não funciona, e o produto não oferece parear de novo.
    ///
    /// Daí as duas mudanças: `NSFileCoordinator` em volta da leitura-modificação-escrita, e a
    /// leitura **imediatamente antes** da escrita, dentro do mesmo bloco coordenado. A janela
    /// deixa de ser de vinte segundos e passa a ser a duração da fusão.
    public static func lerPares() -> String? {
        guard let alvo = arquivo("pares.json") else { return nil }
        var texto: String?
        var erro: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: alvo, options: [], error: &erro) { url in
                guard let dados = try? Data(contentsOf: url),
                      let lido = String(data: dados, encoding: .utf8), !lido.isEmpty
                else { return }
                texto = lido
            }
        return texto
    }

    /// Funde o pareamento novo com o que estiver **no arquivo agora**, sob coordenação.
    ///
    /// `fundir` recebe o conteúdo atual (ou `nil`) e devolve o texto a gravar. Ele roda **dentro**
    /// da coordenação, de propósito: é isso que faz a leitura e a escrita serem uma operação só
    /// para o outro processo.
    ///
    /// Um `fundir` que devolva vazio não apaga nada — perder pareamentos por causa de uma falha
    /// de leitura seria trocar um defeito raro por um pior.
    public static func atualizarPares(_ fundir: (String?) -> String) {
        guard let alvo = arquivo("pares.json") else { return }
        var erro: NSError?
        var rodou = false
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: alvo, options: .forMerging, error: &erro) { url in
                rodou = true
                let atual = (try? Data(contentsOf: url))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                let novo = fundir(atual)
                guard !novo.isEmpty else { return }
                try? Data(novo.utf8).write(to: url, options: .atomic)
            }
        // `rodou`, e não "gravou": um `fundir` que devolve vazio é decisão dele, não falha da
        // coordenação. Só a coordenação **não ter acontecido** justifica o caminho de baixo — e
        // chamar `fundir` duas vezes seria uma chamada de FFI a mais por engano.
        guard !rodou else { return }

        // **Sem coordenação é pior; sem gravar é pior ainda.**
        //
        // Se o coordenador não rodar o bloco — e numa Broadcast Upload Extension isso é uma
        // possibilidade real, não teórica —, sair daqui em silêncio significaria não gravar o
        // pareamento. O sintoma seria a pessoa digitando o PIN em toda sessão, que é a promessa
        // do fluxo quebrada de forma visível e permanente, para evitar uma corrida de escrita
        // que é rara e recuperável pelo botão de esquecer pareamentos.
        //
        // Então cai para a escrita atômica de antes, e **avisa**: a linha existe para que a
        // próxima corrida saiba que o caminho coordenado não está funcionando neste processo.
        if let erro {
            Diagnostico.falha("pares.json sem coordenação (\(erro.code)); gravando direto")
        }
        let atual = (try? Data(contentsOf: alvo))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let novo = fundir(atual)
        guard !novo.isEmpty else { return }
        try? Data(novo.utf8).write(to: alvo, options: .atomic)
    }

    public static var haParesConhecidos: Bool {
        guard let alvo = arquivo("pares.json") else { return false }
        return FileManager.default.fileExists(atPath: alvo.path)
    }

    /// A saída do beco sem saída da dívida 22.
    ///
    /// Quando os dois lados divergem no segredo, o núcleo do anfitrião recusa o `Resume` com
    /// "aparelho não está pareado aqui" e **nunca** cai de volta para o caminho do PIN. Esquecer
    /// os pares deste lado força o próximo pareamento a ser por PIN — que é a única coisa que a
    /// casca pode fazer sozinha, e é melhor que "funcionou ontem, hoje não".
    public static func esquecerPares() {
        guard let alvo = arquivo("pares.json") else { return }
        var erro: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: alvo, options: .forDeleting, error: &erro) { url in
                try? FileManager.default.removeItem(at: url)
            }
        Diagnostico.nota("APP pareamentos esquecidos a pedido da pessoa")
    }
}

// =============================================================================================

/// O que o app pede à appex antes de abrir o seletor de transmissão.
///
/// Decodificação **explícita**, campo a campo, com o padrão da struct quando a chave falta. A
/// síntese do `Decodable` exige toda chave presente: um `pedido.json` de uma versão anterior do
/// app, deixado no App Group por uma instalação antiga, faria o decoder lançar e a appex ficar
/// sem pedido — subindo uma sessão com PIN diferente do que está na tela. A pessoa digitaria o
/// PIN certo e ele não casaria, e nada em lugar nenhum diria por quê.
public struct PedidoDeEspelhamento: Codable {
    /// PIN de seis dígitos sorteado pelo núcleo (`quall_generate_pin`), não pela casca: a
    /// qualidade do sorteio é o que segura o pareamento.
    public var pin: String
    public var porta: UInt16
    /// Identidade estável deste aparelho, e o nome com que ele aparece na rede.
    public var deviceId: String
    public var nome: String
    /// Teto de resolução. **1920x1080 desde 01/09/2026** (`07a92b8`): o `PERFIL_H264` anunciado
    /// no SDP é `42e028`, baseline nível 4.0, que comporta 1920x1080 a 30 fps. Era 1280x720 sob o
    /// nível 3.1, e sob aquele teto os 750x1334 nativos do iPhone 7 já violavam o nível (dívida
    /// 16) — hoje passam inteiros. Ver os padrões logo abaixo, que são a fonte da verdade.
    public var tetoMaior: Int
    public var tetoMenor: Int
    public var fps: Int32
    public var bitrate: Int
    /// Instante em que o app escreveu o pedido, para a appex saber se ele é desta transmissão ou
    /// sobrou de outra.
    public var carimbo: Double

    /// **O teto de taxa para uma geometria, perguntado ao núcleo.**
    ///
    /// Até 02/09/2026 o padrão daqui era `4_000_000` literal, e o mesmo literal existia em mais
    /// quatro cascas. Quando o teto de resolução subiu para 1080p em 01/09, nenhum deles subiu
    /// junto — 2,25 vezes os pixels pelo mesmo orçamento de bits, que é imagem pior, não melhor.
    /// A casca não recalcula a regra: pergunta, que é a mesma disciplina do teto de resolução.
    ///
    /// A ordem dos lados não importa para a taxa (a conta é sobre pixels por segundo), então
    /// `maior`/`menor` entram como vierem.
    ///
    /// Se a fronteira recusar — o que não deve acontecer —, cai nos 4 Mbps históricos em vez de
    /// zero: um teto ausente vira um encoder sem alvo, e isso é pior que um alvo defasado.
    /// # `alvoMaxFs` não tem padrão, de propósito
    ///
    /// Até 08/09/2026 esta função chamava `quall_teto_ajustar` — a variante **sem alvo** — e o
    /// núcleo então grampeava em `Alvo::PADRAO` (1080p) e `FPS_MAXIMO` (30) *por dentro*, sem que
    /// nenhuma casca soubesse. O efeito não era teórico: com o cardápio em 4K a 60, a geometria
    /// subia (o encoder recebia 3840x2160@60, lidos de `Resolucao.escolhida`) e **o orçamento de
    /// bits ficava em 1080p30**. Medido rodando o núcleo: `ajustar(2160, 3840, 60)` devolve
    /// `1074x1910@30` e 8.903.385 bps, que vezes 3/4 da câmera dá **6.677.538 bps** — 8,1 vezes
    /// menos que os 54 Mbps que a regra do produto reserva para aquele quadro, e
    /// **0,0134 bit/pixel** contra os 0,145 do produto.
    ///
    /// É a quinta ocorrência da mesma família em dois dias — *um valor que devia ser um só,
    /// escrito em dois lugares, com só um deles atualizado* — e a mais cara, porque contaminou uma
    /// célula que chegou a ser publicada como provada (ver `docs/bancada.md` §8.53).
    ///
    /// Por isso o parâmetro **não tem valor padrão**: um padrão aqui é exatamente o mecanismo que
    /// produziu o defeito. Quem quiser o comportamento de produto passa `0`, e passa dizendo.
    /// Seis chamadores, seis decisões explícitas — o compilador é o portão.
    ///
    /// Se a fronteira recusar — o que não deve acontecer —, cai nos 4 Mbps históricos em vez de
    /// zero: um teto ausente vira um encoder sem alvo, e isso é pior que um alvo defasado.
    public static func tetoDeTaxa(maior: Int, menor: Int, fps: Int32, alvoMaxFs: UInt32) -> Int {
        var t = QuallTeto()
        let estado = quall_teto_ajustar_para(UInt32(max(0, menor)), UInt32(max(0, maior)),
                                             UInt32(max(1, fps)),
                                             alvoMaxFs, alvoMaxFs == 0 ? 0 : UInt32(max(1, fps)),
                                             &t)
        guard estado == QUALL_STATUS_OK, t.teto_de_taxa_bps > 0 else { return 4_000_000 }
        return Int(t.teto_de_taxa_bps)
    }

    public init(pin: String, porta: UInt16, deviceId: String, nome: String,
                tetoMaior: Int = 1920, tetoMenor: Int = 1080,
                fps: Int32 = 30, bitrate: Int? = nil) {
        self.pin = pin
        self.porta = porta
        self.deviceId = deviceId
        self.nome = nome
        self.tetoMaior = tetoMaior
        self.tetoMenor = tetoMenor
        self.fps = fps
        self.bitrate = bitrate ?? PedidoDeEspelhamento.tetoDeTaxa(
            maior: tetoMaior, menor: tetoMenor, fps: fps, alvoMaxFs: Resolucao.escolhida.maxFs)
        self.carimbo = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case pin, porta, deviceId, nome, tetoMaior, tetoMenor, fps, bitrate, carimbo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func ler<T: Decodable>(_ chave: CodingKeys, _ padrao: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: chave)).flatMap { $0 } ?? padrao
        }
        pin = ler(.pin, "")
        porta = ler(.porta, UInt16(7877))
        deviceId = ler(.deviceId, "")
        nome = ler(.nome, "iPhone")
        tetoMaior = ler(.tetoMaior, 1920)
        tetoMenor = ler(.tetoMenor, 1080)
        fps = ler(.fps, Int32(30))
        // O padrão do campo ausente acompanha o teto que acabou de ser lido — um `pedido.json`
        // escrito por uma versão antiga não fica preso nos 4 Mbps de 720p enquanto manda 1080p.
        // `alvoMaxFs: 0` aqui é a resposta certa e não uma omissão: um `pedido.json` sem o
        // campo `bitrate` foi escrito por uma versão **anterior ao cardápio**, que não
        // escolheu resolução nenhuma. O padrão de produto é o que ela teria pedido.
        bitrate = ler(.bitrate, PedidoDeEspelhamento.tetoDeTaxa(
            maior: tetoMaior, menor: tetoMenor, fps: fps, alvoMaxFs: 0))
        carimbo = ler(.carimbo, 0)
    }

    /// Um pedido sem PIN é um pedido que não serve: o PIN é o que a pessoa lê na tela e digita no
    /// outro aparelho.
    public var utilizavel: Bool { pin.count == 6 && !deviceId.isEmpty }
}

// =============================================================================================

/// Em que pé está a transmissão, do ponto de vista de quem a executa.
///
/// A tela de espera é a peça central do fluxo, e a diferença entre "está esperando você" e
/// "travou" é exatamente esta struct chegando ao app.
public struct EstadoDoEmissor: Codable {
    public enum Etapa: String, Codable {
        /// A appex acordou e leu o pedido. Nenhuma rede ainda.
        case preparando
        /// `quall_host` de pé, esperando o receptor. É o estado que a tela de espera mostra.
        case esperando
        /// Sessão fechada, track aberta, quadros atravessando.
        case transmitindo
        /// Parou por um motivo que a pessoa precisa ler. Ver `erro` e `conselho`.
        case erro
        /// A transmissão acabou — pelo Cancelar, pelo indicador vermelho, ou pelo sistema.
        case encerrado
    }

    public var etapa: Etapa
    /// Porta em que a sinalização de fato ficou. Pode diferir da pedida quando ela estava ocupada.
    public var porta: UInt16
    /// Nome do aparelho do outro lado, quando há um.
    public var par: String
    /// Mensagem crua do núcleo, para o diagnóstico.
    public var erro: String
    /// O que dizer à pessoa. Escrito aqui, e não montado na tela, porque quem sabe o que
    /// aconteceu é quem estava lá.
    public var conselho: String
    /// Quadros que já atravessaram. A tela de espera não mostra isso; serve para o app saber que
    /// a coisa está viva mesmo quando o `par` já apareceu.
    public var quadros: UInt64
    /// Batimento: a appex reescreve o estado a cada segundo. Um estado parado há muitos segundos
    /// significa que o processo morreu — que é o que o jetsam faz sem avisar ninguém.
    public var carimbo: Double

    public init(etapa: Etapa, porta: UInt16 = 0, par: String = "", erro: String = "",
                conselho: String = "", quadros: UInt64 = 0) {
        self.etapa = etapa
        self.porta = porta
        self.par = par
        self.erro = erro
        self.conselho = conselho
        self.quadros = quadros
        self.carimbo = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case etapa, porta, par, erro, conselho, quadros, carimbo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func ler<T: Decodable>(_ chave: CodingKeys, _ padrao: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: chave)).flatMap { $0 } ?? padrao
        }
        etapa = ler(.etapa, Etapa.preparando)
        porta = ler(.porta, UInt16(0))
        par = ler(.par, "")
        erro = ler(.erro, "")
        conselho = ler(.conselho, "")
        quadros = ler(.quadros, UInt64(0))
        carimbo = ler(.carimbo, 0)
    }

    /// Há quanto tempo esta linha foi escrita. Vale como sinal de vida da appex.
    public var idadeEmSegundos: Double { max(0, Date().timeIntervalSince1970 - carimbo) }
}
