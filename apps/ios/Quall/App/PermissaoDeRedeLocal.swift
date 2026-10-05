import Foundation
import Network
import UIKit

/// A permissão de Rede Local do iOS 14+, **pedida, observada e explicada** — uma vez só, para os
/// dois papéis do app.
///
/// # Por que este arquivo existe agora com este nome
///
/// Até 2026-08-30 havia dois: `App/PermissaoDeRedeLocal.swift` (o emissor, `NWBrowser` de Bonjour)
/// e `Receber/SondaDeRedeLocal.swift` (o receptor, sonda TCP). Eram dois porque eram dois apps com
/// dois bundle ids, e **a permissão de Rede Local é concedida por app**. A unificação de 30/08
/// apagou a razão; este arquivo apaga a duplicação. É um bundle, uma concessão, uma linha nos
/// Ajustes, um registro de "já pediu" — e um único lugar onde a leitura do veredito mora.
///
/// O que sobrevive dos dois é o que foi **medido** em cada um, e nada mais:
///
/// - do emissor, o `NWBrowser` como **provocador** para quem ainda não sabe o endereço do par
///   (`docs/matriz-ios.md`: nas duas corridas do iPhone 7 o alerta apareceu com o gatilho de
///   Bonjour desligado — quem o disparou foi o tráfego cru do ICE — mas o navegador é o único
///   tráfego de LAN que este app sabe emitir antes de ter um destino);
/// - do receptor, a **sonda TCP para o host de destino**, que é o mesmo tráfego que o núcleo vai
///   gerar e o único detector confiável dos dois;
/// - de nenhum dos dois, `.ready` do `NWBrowser` como sinal de "concedida". Ele é **falso
///   positivo**, medido no iPhone 7 em 27/08: `.ready` em 51,5 ms numa corrida em que o TCP para
///   a LAN estava comprovadamente bloqueado. Aqui `.ready` não decide nada.
///
/// # Pedir e responder são estados diferentes
///
/// O sistema pode enfileirar um pedido enquanto já existe um alerta de Rede Local pendente.
/// O pedido ter chegado ao sistema não significa que o alerta foi apresentado ou respondido.
/// Nesse caso, repetir uma operação de rede pode repetir a fila sem resolver o acesso.
/// Por isso os conselhos distinguem o pedido pendente da permissão recusada e orientam a pessoa
/// a verificar o estado do app nos Ajustes quando não há uma resposta conclusiva.
///
/// # A testemunha de primeira classe, que substitui o casamento por texto
///
/// `NWPath.unsatisfiedReason == .localNetworkDenied` (iOS 14.2+) é o sistema dizendo, com um
/// valor de enumeração, *"o caminho está insatisfeito porque o acesso à rede local está negado"*.
/// É melhor que tudo o que este projeto usava antes:
///
/// | evidência | o que vale |
/// |---|---|
/// | `NWPath.unsatisfiedReason == .localNetworkDenied` | **o sistema nomeia a causa**. Decide. |
/// | `ECONNREFUSED` da sonda | o pacote atravessou. Decide (concedida). |
/// | `EHOSTUNREACH`/`ENETDOWN`/`EACCES` num endereço da LAN | compatível com a permissão, e com outras coisas |
/// | `kDNSServiceErr_PolicyDenied` (−65570) | verdadeiro quando aparece; não confiável por ausência |
/// | `.ready` do `NWBrowser` | **nada** — falso positivo medido |
///
/// Medido no iPad em 30/08: o erro POSIX que a sonda vê para um endereço da LAN bloqueado é
/// **50 (`ENETDOWN`)**, enquanto o núcleo, pelo socket cru, vê **65 (`EHOSTUNREACH`)**. Dois
/// errnos para a mesma causa — motivo bastante para não deixar o diagnóstico depender de qual
/// deles chegou.
///
/// # `NSLocalNetworkUsageDescription` está no bundle, e isso foi conferido no artefato
///
/// Não no `Info.plist` do fonte — no `Info.plist` **do `.app` assinado**, que é o que o
/// sistema lê. As chaves de descrição de uso e Bonjour precisam constar no artefato final.
enum PermissaoDeRedeLocal {

    // ---------------------------------------------------------------------------------------
    // O veredito
    // ---------------------------------------------------------------------------------------

    enum Resposta: String {
        /// O tráfego da sonda atravessou: o app alcança a rede local.
        case concedida
        /// O sistema barrou o pacote antes de ele sair do aparelho.
        case negada
        /// Não deu para concluir dentro do prazo.
        case indefinida
    }

    /// O que dizer para a pessoa, e é a peça que a medição de 30/08 obrigou a refazer.
    ///
    /// Quatro estados, e cada um exige uma instrução **diferente**. Mandar aos Ajustes quem nunca
    /// pediu é mandar procurar um interruptor que o painel ainda não lista (defeito medido em
    /// 27/08, fotografado pelo usuário no iPhone X). Mandar responder ao diálogo quem tem um
    /// pedido pendente é mandar esperar um diálogo que o sistema **não vai mais apresentar**
    /// (defeito medido em 30/08, no log do `nehelper` do iPad).
    enum Conselho {
        /// Nunca pediu nesta instalação. O caminho é o diálogo, e ele vai aparecer.
        case respondaAoDialogo
        /// O diálogo está na tela agora — o app ficou inativo durante o pedido.
        case dialogoNaTela
        /// Já pediu antes, e o sistema não apresentou diálogo nenhum desta vez. Só os Ajustes
        /// resolvem.
        case abraOsAjustes
        /// Bloqueio sem testemunha: pode ser permissão, pode ser o par ausente.
        case talvezPermissao
    }

    // ---------------------------------------------------------------------------------------
    // O registro de "este app já tocou a LAN"
    // ---------------------------------------------------------------------------------------

    /// **O app é quem sabe.** Não há API para perguntar ao iOS se o painel já lista este bundle,
    /// mas quem faz o pedido chegar ao `nehelper` é a nossa própria tentativa. Registrar que ela
    /// aconteceu é a única forma honesta de separar "nunca pediu" de "pediu e ficou sem resposta".
    ///
    /// Fica em `UserDefaults` porque morre com o app: instalação nova nasce com `false`, que é
    /// exatamente o estado que se quer representar.
    ///
    /// **A chave perdeu o `rx_` em 30/08.** Ela era `quall_rx_ja_tentou_rede_local`, de quando o
    /// receptor era outro app; num app só o registro é do app, e os dois papéis o marcam. Trocar o
    /// nome custa **um** falso "nunca pediu" por instalação já existente, que produz a instrução
    /// mais suave das quatro — preço menor que carregar para sempre um prefixo que mente sobre
    /// quem escreve ali.
    private static let chaveJaTentou = "quall_ja_tentou_rede_local"

    static var jaTentouNaLan: Bool { UserDefaults.standard.bool(forKey: chaveJaTentou) }

    /// Marca que uma tentativa **real** de falar com a rede local vai acontecer agora.
    ///
    /// Chamado pelos dois papéis: `Emissor.espelhar`, `EmissorDeCamera` e `SessaoDeRecepcao`
    /// imediatamente antes de `quall_connect`. E também pela própria sonda, desde 30/08 —
    /// **porque ela pede**, e a medição do `nehelper` é o que derrubou a afirmação anterior de que
    /// não.
    ///
    /// A primeira chamada de cada execução do app guarda o valor **anterior** em
    /// `jaTinhaTentadoAoPedir`. É esse instantâneo, e não o valor de agora, que diz se o alerta do
    /// sistema ainda pode aparecer — porque a própria marcação o destruiria um instante depois.
    static func marcarQueTentouNaLan() {
        if !marcouNestaExecucao {
            marcouNestaExecucao = true
            jaTinhaTentadoAoPedir = jaTentouNaLan
        }
        UserDefaults.standard.set(true, forKey: chaveJaTentou)
    }

    private static var marcouNestaExecucao = false

    /// O nome do app **como ele aparece nos Ajustes**: `CFBundleDisplayName`, lido do bundle e
    /// nunca escrito à mão. Uma cópia em código-fonte diverge em silêncio na primeira vez que
    /// alguém renomeia o alvo — que já foi defeito desta mesma mensagem, mandando procurar
    /// "Quall Receptor", nome que não existe em painel nenhum.
    static var nomeNosAjustes: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Quall"
    }

    // ---------------------------------------------------------------------------------------
    // O que a última rodada observou
    // ---------------------------------------------------------------------------------------

    /// O último veredito desta execução do app, ou `nil` se ninguém pediu ainda.
    ///
    /// Precisa sobreviver até o momento em que `quall_connect` falha — possivelmente 30 s depois,
    /// em outra thread —, porque é ele que permite `explicarFalhaDeConexao` dizer "permissão" em
    /// vez de "rede" **com uma testemunha**.
    private(set) static var ultimaResposta: Resposta?

    /// O sistema pôs um alerta na tela durante o pedido.
    ///
    /// Medido de dentro do app, sem captura de tela: quando o iOS apresenta um alerta modal, o app
    /// **perde o estado ativo** (`willResignActive`) sem perder a cena. É o sinal mais barato que
    /// existe para separar "o diálogo apareceu e ninguém respondeu" de "o diálogo não apareceu" —
    /// e essa separação é a diferença entre as duas instruções opostas de `Conselho`.
    ///
    /// **Não é prova de que o alerta era o de Rede Local.** É prova de que *algum* alerta do
    /// sistema cobriu o app no meio do pedido, o que num app de bancada lançado sem toque não
    /// acontece por outro motivo. O relato diz assim.
    private(set) static var dialogoNaTela = false

    /// `NWPath.unsatisfiedReason` do caminho da sonda, em texto, para o relato dizer **qual** foi
    /// a testemunha.
    private(set) static var razaoDoCaminho = "não observada"

    /// O caminho da sonda foi recusado com `.localNetworkDenied`. É a testemunha forte.
    private(set) static var caminhoNegouRedeLocal = false

    private static var ultimoErroDeSonda: NWError?

    /// O erro que a sonda viu, em texto.
    static var ultimoErroDito: String {
        guard let erro = ultimoErroDeSonda else { return "nenhum erro registrado" }
        if case .posix(let codigo) = erro { return "POSIX \(codigo.rawValue) (\(codigo))" }
        return "\(erro)"
    }

    /// Uma linha com tudo o que se observou, para o `Diario` e para o rodapé do relato.
    static var testemunho: String {
        "resposta=\(ultimaResposta?.rawValue ?? "nao_pedida")"
        + " caminho=\(razaoDoCaminho) erro=\(ultimoErroDito)"
        + " dialogo_na_tela=\(dialogoNaTela) ja_tentou_antes=\(jaTinhaTentadoAoPedir)"
    }

    /// O valor de `jaTentouNaLan` **antes da primeira marcação desta execução do app**. É o que
    /// separa `respondaAoDialogo` de `abraOsAjustes`.
    private(set) static var jaTinhaTentadoAoPedir = false

    /// Algum alerta do sistema cobriu o app em **qualquer** pedido desta execução. Grudento de
    /// propósito: se o alerta já apareceu uma vez nesta execução e o tráfego continua barrado, a
    /// resposta foi "Não permitir" — e mandar a pessoa esperar um alerta que ela acabou de recusar
    /// seria a mesma família de defeito, com o sinal trocado.
    private(set) static var dialogoJaApareceuNestaExecucao = false

    /// O conselho que corresponde ao que foi observado. Ver `Conselho`.
    ///
    /// **O discriminante é "o alerta apareceu?", e não "é a primeira vez?".** A versão anterior
    /// usava `jaTentouNaLan` para escolher entre "responda ao aviso" e "abra os Ajustes", e a
    /// corrida de 30/08 no iPad mostrou que isso erra exatamente no caso que interessa: numa
    /// instalação **recém-feita** (`ja_tentou_antes=false`), com o sistema nomeando
    /// `localNetworkDenied`, o alerta **não apareceu** — porque o `nehelper` guarda um pedido
    /// pendente que sobrevive até à desinstalação do app. Dizer "responda ao aviso" ali é mandar
    /// esperar um aviso que não vem, que é a mesma família do defeito de 27/08 com o sinal
    /// trocado.
    ///
    /// O alerta, quando existe, aparece em ~1 s e o app perde o estado ativo. Doze segundos sem
    /// isso é resposta: **não veio**.
    static var conselho: Conselho {
        // Ninguém pediu ainda nesta execução: o conselho é o de antes do pedido.
        guard let resposta = ultimaResposta else {
            return jaTentouNaLan ? .talvezPermissao : .respondaAoDialogo
        }
        if dialogoNaTela { return .dialogoNaTela }
        guard resposta == .negada || caminhoNegouRedeLocal else { return .talvezPermissao }
        // Barrado, e **nenhum alerta está na tela**. Duas histórias levam aqui e as duas terminam
        // no mesmo lugar: ou o alerta apareceu nesta execução e a resposta foi "Não permitir", ou
        // ele nunca apareceu porque o sistema já tinha um pedido pendente
        // (`nehelper: prompt outstanding`). Nos dois casos só o interruptor resolve.
        return .abraOsAjustes
    }

    // ---------------------------------------------------------------------------------------
    // Os textos, um por estado
    // ---------------------------------------------------------------------------------------

    static var texto: String {
        switch conselho {
        case .respondaAoDialogo:  return textoPrimeiraVez
        case .dialogoNaTela:      return textoDialogoNaTela
        case .abraOsAjustes:      return textoAjustes
        case .talvezPermissao:    return textoProvavel
        }
    }

    /// **Primeira vez: o caminho é o diálogo, não os Ajustes.** O painel só lista quem pediu pelo
    /// menos uma vez, e mandar procurar um item que não existe é o defeito que o usuário
    /// fotografou no iPhone X em 27/08.
    static var textoPrimeiraVez: String {
        // Os nomes entre aspas são da interface do sistema: na língua dele (`trSistema`).
        tr("O iOS pede sua autorização na primeira vez que este app fala com a rede local. Responda "
           + "\"%@\" ao aviso do sistema. Enquanto esse primeiro pedido não for respondido, o "
           + "app nem aparece na lista de %@ dos %@ — então não adianta procurá-lo por "
           + "lá ainda.", trSistema("Permitir"), trSistema("Rede Local"), trSistema("Ajustes"))
    }

    /// O alerta está na tela **agora**. Nada a fazer além de responder.
    static var textoDialogoNaTela: String {
        tr("O iOS está pedindo sua autorização para a rede local agora, por cima desta tela. Toque em "
           + "\"%@\" para continuar.", trSistema("Permitir"))
    }

    /// **O estado que faltava, e ele é o achado de 30/08.** O pedido foi feito, o sistema barrou, e
    /// o aviso **não está na tela**. Ou ele já foi recusado, ou o iOS não o apresentou — e em
    /// nenhum dos dois casos esperar adianta.
    ///
    /// A segunda frase existe porque o app **não tem como saber** se ele consta no painel: não há
    /// API para perguntar. Dizer as duas saídas, na ordem de probabilidade, é mais honesto que
    /// escolher uma e estar errado metade das vezes — que foi o defeito de 27/08 e o de hoje, um
    /// de cada lado.
    static var textoAjustes: String {
        tr("Falta a permissão de Rede Local, e o aviso do sistema não está na tela: um pedido já "
           + "recusado, ou que ficou sem resposta, não é remostrado. Abra %@ e ligue \"%@\". Se o "
           + "app não estiver na lista, o pedido ficou pendente no sistema e só reiniciar o aparelho "
           + "o libera. Enquanto isso o iOS bloqueia a conexão antes de ela sair do aparelho e "
           + "informa \"%@\" — parece problema de Wi-Fi ou de roteador, e não é.",
           trSistema("Ajustes → Privacidade e Segurança → Rede Local"), nomeNosAjustes,
           trSistema("sem rota para o host"))
    }

    /// **Hedge, e o hedge é conserto de um defeito, não timidez.** Quando não há testemunha e a
    /// única evidência é "não conectou" para um endereço da LAN, "falta a permissão" é a causa
    /// *mais provável*, não a única. Um app que acusa falta de permissão concedida ensina a pessoa
    /// a ignorar avisos, e o próximo, verdadeiro, ela não lê.
    static var textoProvavel: String {
        tr("Não deu para falar com o outro aparelho. A causa mais comum é a permissão de Rede Local: "
           + "abra %@ e confira se \"%@\" está ligado. Se já estiver, confira se o outro aparelho "
           + "ainda está esperando neste mesmo endereço e na mesma Wi-Fi.",
           trSistema("Ajustes → Privacidade e Segurança → Rede Local"), nomeNosAjustes)
    }

    // ---------------------------------------------------------------------------------------
    // O pedido
    // ---------------------------------------------------------------------------------------

    private static var sonda: NWConnection?
    private static var navegador: NWBrowser?
    private static var monitor: NWPathMonitor?
    private static var respondido = false
    /// Um pedido correndo, e quem chegou no meio dele. Ver o começo de `pedir`.
    private static var pedidoEmCurso = false
    private static var numeroDoPedido = 0
    private static var fila: [(String?, Double, (Resposta) -> Void)] = []
    private static var jaEstendeu = false
    private static var observadores: [NSObjectProtocol] = []
    private static var comecouEm = Date()

    /// **A porta 9 (discard), e não a porta real da sinalização**, de propósito: abrir e fechar
    /// uma conexão na porta que o emissor está escutando mexeria no estado do servidor de
    /// sinalização no instante anterior à corrida — instrumento entrando na medição, que é o
    /// defeito que `docs/regras-de-frente.md` nomeia. A porta 9 não é escutada por ninguém e
    /// devolve `ECONNREFUSED`, que é exatamente o sinal desejado.
    private static let portaDeDescarte: NWEndpoint.Port = 9

    /// Provoca o pedido de Rede Local com tráfego de verdade e observa o veredito.
    ///
    /// - Parameters:
    ///   - destino: o endereço do par (`host` ou `host:porta`), quando ele já é conhecido — o caso
    ///     de quem **exibe**. `nil` quando ainda não é — o caso de quem **espelha**, que anuncia
    ///     antes de saber quem vem. Sem destino, o alvo da sonda é o **gateway do caminho atual**,
    ///     lido de `NWPath.gateways`: é um endereço da LAN de verdade, escolhido pelo sistema, e
    ///     não um palpite sobre a topologia.
    ///   - prazo: quanto esperar antes de fechar o veredito. Doze segundos, e o prazo **se estende
    ///     uma vez** se o alerta do sistema aparecer no meio: concluir "negada" porque a pessoa
    ///     está lendo o diálogo seria mandá-la aos Ajustes sem motivo.
    static func pedir(destino: String? = nil, prazo: Double = 12,
                      entao resposta: @escaping (Resposta) -> Void) {
        // **Um pedido de cada vez.** O estado deste tipo é estático (a sonda, o prazo,
        // `respondido`), e um segundo `pedir` no meio do primeiro desmontava a sonda dele: a
        // resposta do primeiro nunca chegava. Até o R5 ninguém pedia dois ao mesmo tempo; a tela
        // "Teleprompter com câmera" pede dois — o prompter e a câmera, cada um com a sua sessão.
        // Quem chega com um pedido em curso **entra na fila e é pedido de novo** quando o corrente
        // terminar, com o destino dele: o veredito de um destino não vale para outro (um endereço
        // público responde "concedida" sem perguntar nada). Chamado sempre da principal, como
        // antes — o estado estático não tem trava.
        if pedidoEmCurso {
            fila.append((destino, prazo, resposta))
            Diario.dizer("permissão de Rede Local: pedido em curso — este entra na fila (\(fila.count))")
            return
        }
        pedidoEmCurso = true
        numeroDoPedido += 1
        /// **O número deste pedido.** Todo fecho deste pedido — o prazo, a extensão do prazo, a
        /// resposta da sonda — confere o número antes de mexer no estado estático: um prazo velho
        /// de um pedido já respondido, disparando no meio do seguinte, desmontaria a sonda dele e
        /// deixaria `pedidoEmCurso` preso para sempre.
        let meu = numeroDoPedido
        let entregar: (Resposta) -> Void = { r in
            guard numeroDoPedido == meu, pedidoEmCurso else { return }
            pedidoEmCurso = false
            resposta(r)
            if !fila.isEmpty {
                let (d, p, r2) = fila.removeFirst()
                DispatchQueue.main.async { pedir(destino: d, prazo: p, entao: r2) }
            }
        }
        desmontar()
        respondido = false
        jaEstendeu = false
        dialogoNaTela = false
        caminhoNegouRedeLocal = false
        razaoDoCaminho = "não observada"
        ultimoErroDeSonda = nil
        comecouEm = Date()
        jaTinhaTentadoAoPedir = jaTentouNaLan

        // **A sonda pede.** Medido em 30/08 no `nehelper` do iPad: o primeiro SYN para a LAN faz o
        // sistema receber a mensagem em nome deste bundle e enfileirar o alerta. A afirmação
        // anterior deste repositório — "a sonda não cria a linha no painel" — era ausência de
        // evidência (o painel não foi conferido), não evidência de ausência.
        marcarQueTentouNaLan()
        observarOAlerta()

        func responder(_ r: Resposta) {
            guard numeroDoPedido == meu, !respondido else { return }
            respondido = true
            ultimaResposta = r
            desmontar()
            DispatchQueue.main.async { entregar(r) }
        }

        func fecharOPrazo() {
            guard numeroDoPedido == meu, !respondido else { return }
            // O alerta está na tela: **estender uma vez**, e só uma. A conexão continua em
            // `.waiting` e volta sozinha para `.ready`/`ECONNREFUSED` no instante em que a pessoa
            // toca "Permitir" — é assim que o caminho feliz se fecha sem ninguém apertar nada
            // aqui dentro.
            if dialogoNaTela, !jaEstendeu {
                jaEstendeu = true
                Diario.dizer("permissão de Rede Local: o alerta do sistema está na tela; "
                             + "esperando mais \(Int(prazoDoAlerta)) s pela resposta")
                DispatchQueue.main.asyncAfter(deadline: .now() + prazoDoAlerta) { fecharOPrazo() }
                return
            }
            if let erro = ultimoErroDeSonda, let r = veredito(de: erro) { responder(r) }
            if caminhoNegouRedeLocal { responder(.negada) }
            responder(.indefinida)
        }

        // Sem destino, o alvo sai do sistema: o gateway do caminho atual.
        guard let destino else {
            provocarSemDestino(prazo: prazo, responder: responder, fecharOPrazo: fecharOPrazo)
            return
        }

        let anfitriao = host(de: destino)
        guard enderecoEhDaRedeLocal(anfitriao) else {
            // Endereço público: o iOS não pede permissão de Rede Local para ele, e provocar um
            // alerta que não vai existir só gastaria o prazo inteiro.
            razaoDoCaminho = "endereço fora da rede local — a pergunta não se aplica"
            responder(.concedida)
            return
        }
        sondar(anfitriao, responder: responder)
        DispatchQueue.main.asyncAfter(deadline: .now() + prazo) { fecharOPrazo() }
    }

    /// Quanto esperar **depois** de ver o alerta aparecer. Trinta segundos: é tempo de ler duas
    /// frases e tocar um botão, e não é tempo de a pessoa desistir da tela.
    private static let prazoDoAlerta: Double = 30

    // ---------------------------------------------------------------------------------------

    /// O caminho de quem **espelha**: ainda não há par, então o alvo é o gateway do caminho atual.
    ///
    /// `NWPath.gateways` é o sistema dizendo qual é o roteador — não um palpite do tipo "troque o
    /// último octeto por 1", que erra em toda sub-rede que não é /24. Se não houver gateway (rede
    /// caindo, Wi-Fi subindo), sobra o `NWBrowser` de Bonjour como provocador, que é o que o
    /// emissor sempre usou; ele **não decide** o veredito, só põe tráfego de LAN no ar para o
    /// sistema ter o que avaliar.
    private static func provocarSemDestino(prazo: Double,
                                           responder: @escaping (Resposta) -> Void,
                                           fecharOPrazo: @escaping () -> Void) {
        let m = NWPathMonitor()
        monitor = m
        var jaSondou = false
        m.pathUpdateHandler = { caminho in
            guard !jaSondou else { return }
            guard case .hostPort(let h, _) = caminho.gateways.first else { return }
            jaSondou = true
            sondar("\(h)", responder: responder)
        }
        m.start(queue: .main)

        // O provocador de reserva, e é o do emissor de sempre. `NSBonjourServices` está no
        // `Info.plist`; sem a chave o navegador nem sobe.
        let parametros = NWParameters()
        parametros.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_quall._tcp", domain: nil), using: parametros)
        b.stateUpdateHandler = { estado in
            // **`.ready` não decide nada** — falso positivo medido no iPhone 7 em 27/08. Só o erro
            // de política conta, e mesmo ele só como anotação para o fim do prazo.
            if case .waiting(let erro) = estado { anotar(erro, caminho: nil) }
            if case .failed(let erro) = estado { anotar(erro, caminho: nil) }
        }
        b.start(queue: .main)
        navegador = b

        DispatchQueue.main.asyncAfter(deadline: .now() + prazo) { fecharOPrazo() }
    }

    /// A sonda: uma conexão TCP de verdade para um endereço da rede local, na porta de descarte.
    ///
    /// | resultado | leitura |
    /// |---|---|
    /// | `ECONNREFUSED` (ou `.ready`) | **concedida** — o pacote chegou ao host |
    /// | `NWPath.unsatisfiedReason == .localNetworkDenied` | **negada**, com o sistema nomeando a causa |
    /// | `EHOSTUNREACH` / `ENETDOWN` / `EACCES` / `EPERM` | **negada** por errno, compatível com a causa |
    /// | nada conclusivo até o prazo | **indefinida** |
    ///
    /// `ECONNREFUSED` como sinal de sucesso não é truque: é a única resposta que **prova que o
    /// pacote atravessou**.
    private static func sondar(_ anfitriao: String, responder: @escaping (Resposta) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(anfitriao), port: portaDeDescarte, using: .tcp)
        c.stateUpdateHandler = { estado in
            switch estado {
            case .ready:
                // Alguém escuta a porta 9. Improvável, e ainda assim é a melhor notícia possível:
                // o pacote atravessou.
                responder(.concedida)
            case .waiting(let erro):
                // **Não conclui aqui.** `.waiting` é o estado em que a conexão fica enquanto o
                // alerta está na tela esperando a pessoa — e é também o estado em que ela volta
                // sozinha a tentar quando a permissão é concedida. Anota e deixa o prazo decidir.
                anotar(erro, caminho: c.currentPath)
                if case .posix(let codigo) = erro, codigo == .ECONNREFUSED { responder(.concedida) }
            case .failed(let erro):
                anotar(erro, caminho: c.currentPath)
                if case .posix(let codigo) = erro, codigo == .ECONNREFUSED { responder(.concedida) }
            default:
                break
            }
        }
        c.start(queue: .main)
        sonda = c
    }

    /// Anota o erro e, quando houver, a razão que o **sistema** dá para o caminho estar
    /// insatisfeito. A razão é a testemunha forte; o errno é a fraca.
    private static func anotar(_ erro: NWError, caminho: NWPath?) {
        ultimoErroDeSonda = erro
        guard let caminho else { return }
        switch caminho.unsatisfiedReason {
        case .localNetworkDenied:
            caminhoNegouRedeLocal = true
            razaoDoCaminho = "localNetworkDenied"
        case .wifiDenied:      razaoDoCaminho = "wifiDenied"
        case .cellularDenied:  razaoDoCaminho = "cellularDenied"
        case .notAvailable:    razaoDoCaminho = "notAvailable"
        default:               razaoDoCaminho = "outra (\(caminho.unsatisfiedReason))"
        }
    }

    /// Traduz o errno em veredito, ou `nil` quando ele não diz nada sobre a permissão.
    ///
    /// Os dois códigos que este projeto já viu para a mesma causa: **65 (`EHOSTUNREACH`)**, que é
    /// o que o socket cru do núcleo devolve, e **50 (`ENETDOWN`)**, que é o que o
    /// `Network.framework` devolveu no iPad em 30/08. Cobrir os dois custa uma linha; descobrir a
    /// diferença custou uma corrida.
    private static func veredito(de erro: NWError) -> Resposta? {
        switch erro {
        case .posix(let codigo):
            switch codigo {
            case .ECONNREFUSED: return .concedida
            case .EHOSTUNREACH, .EACCES, .EPERM, .ENETDOWN, .ENETUNREACH: return .negada
            default: return nil
            }
        case .dns(let codigo):
            // `kDNSServiceErr_PolicyDenied` (−65570): quando aparece, é verdadeiro. O que ele não
            // é, é confiável por ausência.
            return codigo == -65570 ? .negada : nil
        default:
            return nil
        }
    }

    // ---------------------------------------------------------------------------------------
    // A observação do alerta, de dentro do app
    // ---------------------------------------------------------------------------------------

    /// Quando o iOS apresenta um alerta modal do sistema, o app **resigna o estado ativo** sem
    /// perder a cena. É o único sinal de dentro do processo que existe para "o diálogo apareceu",
    /// e ele vale ouro: separa os dois estados que pedem instruções opostas.
    ///
    /// O meio segundo de carência existe porque a própria abertura do app passa por
    /// `willResignActive` uma vez, e contá-la seria transformar toda corrida em "o diálogo está na
    /// tela".
    private static func observarOAlerta() {
        let c = NotificationCenter.default
        observadores.append(c.addObserver(forName: UIApplication.willResignActiveNotification,
                                          object: nil, queue: .main) { _ in
            guard Date().timeIntervalSince(comecouEm) > 0.5 else { return }
            guard !dialogoNaTela else { return }
            dialogoNaTela = true
            dialogoJaApareceuNestaExecucao = true
            Diario.dizer("permissão de Rede Local: o app ficou inativo "
                         + String(format: "%.1f s", Date().timeIntervalSince(comecouEm))
                         + " depois do pedido — há um alerta do sistema por cima da tela")
        })
        observadores.append(c.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                          object: nil, queue: .main) { _ in
            guard dialogoNaTela else { return }
            // **Limpo aqui, e o grudento fica.** `dialogoNaTela` descreve o agora e não pode
            // sobreviver ao alerta, senão o veredito final diria "responda ao aviso" para uma tela
            // vazia. `dialogoJaApareceuNestaExecucao` é o que a memória precisa guardar.
            dialogoNaTela = false
            Diario.dizer("permissão de Rede Local: o app voltou a ficar ativo — o alerta saiu da tela")
        })
    }

    private static func desmontar() {
        sonda?.cancel(); sonda = nil
        navegador?.cancel(); navegador = nil
        monitor?.cancel(); monitor = nil
        let c = NotificationCenter.default
        observadores.forEach { c.removeObserver($0) }
        observadores.removeAll()
    }

    // ---------------------------------------------------------------------------------------
    // A leitura do endereço
    // ---------------------------------------------------------------------------------------

    /// O host de `host`, `host:porta` ou `[v6]:porta`.
    static func host(de endereco: String) -> String {
        var host = endereco.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") {
            if let fim = host.firstIndex(of: "]") {
                return String(host[host.index(after: host.startIndex)..<fim])
            }
        }
        if host.filter({ $0 == ":" }).count == 1, let ultimo = host.lastIndex(of: ":") {
            host = String(host[host.startIndex..<ultimo])
        }
        return host
    }

    /// O endereço é da **rede local** (RFC 1918, link-local, ou um nome `.local`).
    ///
    /// Serve a um propósito só: decidir se "não há rota" para este endereço é diagnosticável como
    /// permissão. Para um endereço da LAN, com o par respondendo, "sem rota" é uma afirmação que
    /// quase nunca é verdade — o aparelho tem rota para a própria sub-rede por construção. Para um
    /// endereço público, é literal.
    ///
    /// **Não é prova, é um filtro** — a testemunha de verdade é `ultimaResposta` e
    /// `caminhoNegouRedeLocal`.
    static func enderecoEhDaRedeLocal(_ endereco: String) -> Bool {
        let host = self.host(de: endereco).lowercased()

        if host.hasSuffix(".local") || host == "localhost" { return true }

        let partes = host.split(separator: ".").compactMap { Int($0) }
        guard partes.count == 4, partes.allSatisfy({ $0 >= 0 && $0 <= 255 }) else {
            // Também há IPv6 global no enlace local. Faixas e comparação de máscara devem
            // ler IPv6 válido; prefixos textuais deixavam fe81::/10 e LAN global sem sondagem.
            return Enderecos.ipv6EhDaRedeLocal(host)
        }
        switch (partes[0], partes[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        case (127, _): return true
        default: return false
        }
    }
}
