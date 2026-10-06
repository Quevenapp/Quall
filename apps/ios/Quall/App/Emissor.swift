// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation
import Combine
import UIKit

/// A máquina de estados do lado do app, e nada além disso.
///
/// Quem hospeda a sessão é a Broadcast Upload Extension (`docs/arquitetura-ios.md`). O app
/// **prepara** (PIN, nome, porta, permissão de rede), **mostra** (a tela de espera, que é a peça
/// central do fluxo) e **cancela**. Nenhum quadro passa por aqui.
///
/// ## Por que espera e cancela existem como estados de primeira classe
///
/// O fluxo é explícito: "A espera precisa ser visível e cancelável. Sem isso, o usuário concede
/// gravação de tela, vê o indicador vermelho do sistema e não entende por que nada acontece. Uma
/// tela de espera muda é a diferença entre 'está esperando você' e 'travou'."
///
/// E o Cancelar precisa funcionar **de verdade**: voltar para a tela inicial com o indicador
/// vermelho ainda ligado seria a pior versão do defeito, porque a pessoa acharia que parou.
/// Por isso existe `.encerrando`: o app pede, a appex executa, e só quando ela confirma — ou
/// quando o batimento dela some, que é o mesmo que dizer que o processo acabou — é que a tela
/// volta ao começo.
///
/// **Sem `@MainActor`, e de propósito.** Tudo aqui já roda na thread principal: os toques vêm da
/// interface, o `Timer` do vigia é agendado no `RunLoop.main`, e o único retorno de fora — o
/// veredito da permissão de rede local — chega despachado para a principal por quem o produz.
/// Marcar a classe traria as regras de isolamento para dentro de closures que a plataforma
/// entrega sem isolamento nenhum, e o conserto seria espalhar `Task { @MainActor in }` por
/// caminhos que já estavam certos.
final class Emissor: ObservableObject {

    enum Fase: Equatable {
        case inicial
        /// Provocando o alerta de Rede Local e esperando o veredito.
        case pedindoPermissao
        /// O sistema recusou a rede local. Sem ela nada atravessa, e a saída é nos Ajustes.
        case permissaoNegada
        /// Tela de espera: PIN, nome, IP, e o Cancelar.
        case esperando
        /// Alguém entrou. A tela mostra para quem.
        case transmitindo
        /// Cancelar pedido; esperando a appex confirmar que a transmissão morreu.
        case encerrando
        /// Deu errado de um jeito que a pessoa precisa ler.
        case falhou
    }

    @Published private(set) var fase: Fase = .inicial {
        didSet {
            guard fase != oldValue else { return }
            // Uma linha por troca de tela — cinco ou seis numa sessão inteira. É o que permite
            // ao relato dizer que a tela de espera de fato virou "espelhando", em vez de afirmar
            // que virou.
            Diagnostico.nota("APP tela=\(fase)"
                + (conselho.isEmpty ? "" : " conselho=\(SanitizacaoDoLog.causaExterna(conselho))"))
        }
    }
    @Published private(set) var pin = ""
    @Published private(set) var porta: UInt16 = Emissor.portaDaSinalizacao
    /// O endereço de **LAN** — Wi-Fi, ou Ethernet com DHCP. `nil` sem LAN, e isso **não** quer
    /// dizer sem rede: pode haver cabo. Ver `ipDoCabo`.
    @Published private(set) var ip: String?
    /// O endereço do **cabo** (USB-Ethernet, `169.254.x.y`), quando há um.
    ///
    /// Existe desde 01/09/2026, quando três iOS entregaram câmera pelo cabo com perda zero e o app
    /// ainda dizia "sem rede Wi‑Fi" com o fio plugado. Anda **junto** com `ip`, e nunca no lugar
    /// dele: quem alcança este endereço é só quem está na outra ponta.
    @Published private(set) var ipDoCabo: String?
    @Published private(set) var par = ""
    @Published private(set) var conselho = "" {
        // Quem escreve o texto direto (o conselho da appex, o vazio) desfaz a origem do app.
        didSet { if !trocandoPeloApp { conselhoDoApp = nil } }
    }
    /// De onde veio o `conselho`, quando foi o próprio app que o escreveu: é o que permite
    /// reescrevê-lo no idioma novo quando o seletor troca (`Idioma.mudou`). O Emissor vive mais que a
    /// tela, e um texto guardado de antes apareceria no idioma antigo.
    private var conselhoDoApp: ConselhoDoApp?
    private var trocandoPeloApp = false
    private var observadorDoIdioma: NSObjectProtocol?

    /// Os conselhos que o app escreve (os outros vêm prontos da appex, no idioma que ela usa).
    private enum ConselhoDoApp {
        case redeLocalNegada, pinNaoSorteado, paresEsquecidos, encerradaPeloSistema, naoComecou

        var texto: String {
            switch self {
            case .redeLocalNegada:
                return tr("O Quall precisa de acesso à rede local para achar o outro "
                    + "aparelho. Abra %@ e ligue.", trSistema("Ajustes → Quall Studio → Rede Local"))
            case .pinNaoSorteado:
                return tr("Não foi possível sortear o PIN da sessão.")
            case .paresEsquecidos:
                return tr("Pareamentos esquecidos. Agora peça para o outro aparelho entrar de novo e "
                    + "digitar o PIN que está nesta tela.")
            case .encerradaPeloSistema:
                return tr("A transmissão foi encerrada pelo sistema.")
            case .naoComecou:
                return tr("A transmissão não pôde começar.")
            }
        }
    }

    private func dizer(_ c: ConselhoDoApp) {
        trocandoPeloApp = true
        conselho = c.texto
        trocandoPeloApp = false
        conselhoDoApp = c
    }
    /// A retomada do pareamento falhou, e a única ação que a casca pode oferecer é esquecer os
    /// pares deste lado para forçar o próximo pareamento a ser por PIN. Ver a dívida 22: o núcleo
    /// **não** cai de volta para o PIN sozinho, e sem este botão a pessoa fica em "funcionou
    /// ontem, hoje não funciona" sem nada para tentar.
    @Published private(set) var ofereceDesparear = false

    /// Existe **algum** par conhecido — não necessariamente o que vai chegar.
    ///
    /// É o que decide se a tela de espera abre com o PIN como manchete ou com o endereço. Fica
    /// aqui, e não como leitura de disco dentro do `body`, por duas razões: o `body` de SwiftUI
    /// roda muitas vezes por segundo e não é lugar de tocar o sistema de arquivos, e o valor
    /// **muda enquanto a tela está no ar** — o botão "Esquecer aparelhos pareados" mora nela.
    /// Como leitura direta, o layout só viraria por acidente de reavaliação.
    @Published private(set) var haParesConhecidos = Compartilhado.haParesConhecidos
    /// Quantos segundos já se passaram desde que a tela de espera subiu sem a appex dar sinal.
    /// A tela usa isto para oferecer o seletor de novo — a folha do sistema é dispensável com um
    /// toque para fora, e nada avisa o app quando isso acontece.
    @Published private(set) var segundosSemAppex = 0

    @Published var nome: String = Identidade.nome {
        didSet { Identidade.nome = nome }
    }

    /// Porta de sinalização, **uma só, para qualquer origem**.
    ///
    /// A versão anterior deste arquivo reservava 7877 para a tela e 7878 para a câmera, porque as
    /// duas eram sessões que podiam existir ao mesmo tempo. A decisão de 2026-08-22 apagou isso:
    /// a origem é escolhida antes do PIN, é **uma por vez** por desenho, e o receptor vê o
    /// aparelho uma vez só.
    ///
    /// Uma entrada na lista significa **um endereço para digitar**. Com o mDNS desligado — nenhum
    /// perfil tem o entitlement de multicast —, "a lista" é literalmente o `ip:porta` que a pessoa
    /// lê nesta tela e digita na outra; duas portas seriam duas entradas, que é o que a decisão
    /// veio remover. Daí a porta ser a mesma, e a origem viajar no rótulo da track em vez de no
    /// número da porta.
    ///
    /// Consequência aceita: se um espelhamento de tela ficou vivo (a appex sobrevive ao app), a
    /// porta está ocupada e a câmera não sobe. O app **recusa antes**, com texto — ver
    /// `haEspelhamentoVivo` —, em vez de deixar a pessoa esbarrar num "e/s: endereço em uso".
    static let portaDaSinalizacao: UInt16 = 7877

    /// O anúncio por mDNS, pelo `mDNSResponder` do sistema. Ver `AnuncianteBonjour` para por que
    /// ele não é o do núcleo: aquele abre socket multicast cru, que no iOS depende de um
    /// entitlement que ainda está com a Apple.
    private let anunciante = AnuncianteBonjour()
    var nomeNaDescoberta: String? { anunciante.nomePublico }

    /// Por quanto tempo um pedido que ninguém consumiu ainda **é** a espera em curso.
    ///
    /// Vale o mesmo teto que a appex usa para desistir de esperar receptor: passado esse tempo,
    /// não há espera nenhuma para retomar, e insistir num PIN velho seria pior que sortear um
    /// novo. Ver o comentário em `prepararEAbrirOSeletor`.
    static let validadeDoPedido: Double = 600

    private var vigia: Timer?
    private var comecouAEsperarEm = Date()

    init() {
        Identidade.semearNome(UIDevice.current.name)
        nome = Identidade.nome
        relerEnderecos()
        // Uma transmissão pode estar de pé desde antes de o app ser reaberto: a appex sobrevive
        // ao app, e é isso que faz o espelhamento continuar quando a pessoa sai para outro
        // aplicativo. Reabrir na tela inicial, com o indicador vermelho ligado, seria mentir.
        retomarSeHouverTransmissao()

        // A troca de idioma (só na tela inicial, sem sessão no ar): o conselho que o app escreveu
        // é refeito no idioma novo; o que veio da appex é sobra de uma tentativa anterior, e sai.
        observadorDoIdioma = NotificationCenter.default.addObserver(
            forName: Idioma.mudou, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let c = self.conselhoDoApp { self.dizer(c) } else if !self.transmissaoNoAr { self.conselho = "" }
        }

        // Uma linha por abertura, fora de qualquer caminho quente. É por ela que o roteiro de
        // bancada descobre o IP do aparelho sem que ninguém precise ler a tela de Ajustes.
        //
        // A tela e a memória entraram aqui em 2026-08-26, quando o segundo aparelho chegou. Elas
        // dizem, **antes** de qualquer toque, duas coisas que até então só se descobriam depois
        // de uma transmissão inteira:
        //
        //   * `tela` é `nativeBounds`, em pixels — a entrada que o ReplayKit vai ter de encodar,
        //     e portanto quanto o encoder vai reescalar. O iPhone 7 é 750x1334 e cai em 720x1280
        //     quase exato; um aparelho mais alongado cai noutro lugar, e é melhor saber disso
        //     lendo uma linha do que descobrindo no veredito;
        //   * `ram` é o contexto que falta para ler a memória da appex. O orçamento do jetsam
        //     para a Broadcast Upload Extension é seu, não do aparelho — mas RAM e pixels puxam
        //     em sentidos opostos, e comparar dois aparelhos sem os dois números é comparar
        //     pela metade.
        //
        // Nenhuma das duas é chamada mais de uma vez por abertura.
        let tela = UIScreen.main.nativeBounds.size
        Diagnostico.nota("APP aberto protocolo=\(Nucleo.versaoDoProtocolo())"
            // A **classe** de cada endereço vai junto desde 01/09/2026, e não é enfeite: é a única
            // testemunha que este projeto tem do nome que a interface do cabo recebe **do lado
            // iOS**. As corridas de cabo nomeiam `en8`/`en10`/`en12`, que são do MacBook; a
            // heurística de `Enderecos.classificar` chuta "cabo é tudo que não é `en0`" e esta
            // linha é onde a primeira corrida com fio a confirma ou a derruba.
            + " interfaces=\(Enderecos.ipv4().map { "\($0.interface)=\($0.enlace.rawValue)" }.joined(separator: " "))"
            + " sistema=\(UIDevice.current.systemVersion)"
            + " tela=\(Int(tela.width))x\(Int(tela.height))"
            + " ram=\(ProcessInfo.processInfo.physicalMemory)")
    }

    // --- começar ----------------------------------------------------------------------------

    /// Há um espelhamento de tela vivo **agora**, possivelmente começado antes desta abertura do
    /// app: a appex é autônoma e sobrevive a ele.
    ///
    /// Serve para a regra "uma origem por vez" ser cumprida com uma frase em vez de um erro de
    /// rede: sem isto, escolher uma câmera com a tela ainda no ar daria `e/s: endereço em uso` —
    /// texto certo para o motivo errado, três camadas longe da causa que a pessoa entende
    /// ("o indicador vermelho ainda está ligado").
    static var haEspelhamentoVivo: Bool {
        guard let estado = Compartilhado.lerEstado() else { return false }
        return estado.idadeEmSegundos <= 6 && estado.etapa != .encerrado
    }

    /// Há espelhamento no ar **agora**, do ponto de vista deste objeto.
    ///
    /// Existe para a raiz do app: `init` já chama `retomarSeHouverTransmissao()`, então a fase
    /// nasce em `.esperando` ou `.transmitindo` quando a appex sobreviveu a uma abertura anterior.
    /// Nesse caso o papel deste aparelho está decidido pelos fatos e a tela de escolha não deve
    /// aparecer — perguntar seria oferecer uma opção que a plataforma já tirou da mesa (a origem é
    /// fixa pela sessão, e a sessão está de pé).
    var transmissaoNoAr: Bool {
        fase == .esperando || fase == .transmitindo || fase == .encerrando
    }

    /// O toque em "Espelhar", com a **tela** escolhida no seletor de origem. Um toque, e o resto
    /// é o sistema.
    func espelhar() {
        guard fase == .inicial || fase == .falhou || fase == .permissaoNegada else { return }
        relerEnderecos()
        conselho = ""
        fase = .pedindoPermissao

        // **Registrado aqui porque agora é o mesmo app dos dois lados.** `PermissaoDeRedeLocal`
        // separa "nunca pediu" de "pediu e foi negado", e a diferença entre os dois muda a
        // instrução que a pessoa recebe: mandar aos Ajustes quem nunca pediu é mandar procurar um
        // interruptor que o painel ainda não lista. Enquanto eram dois bundle ids, o registro do
        // receptor não podia saber que o emissor já havia tocado a LAN. Agora pode, e não saber
        // seria produzir de novo, dentro de um app só, o defeito que a unificação apagou.
        PermissaoDeRedeLocal.marcarQueTentouNaLan()

        PermissaoDeRedeLocal.pedir { [weak self] resposta in
            guard let self else { return }
            switch resposta {
            case .negada:
                self.dizer(.redeLocalNegada)
                self.fase = .permissaoNegada
            case .concedida, .indefinida:
                // `indefinida` segue em frente de propósito: no iOS 15 não há como consultar o
                // estado desta permissão, e o veredito de verdade é o do `quall_host` — que
                // chega à tela de espera com texto acionável. Barrar aqui, por não ter
                // conseguido confirmar, seria impedir o produto de funcionar por causa do
                // instrumento.
                self.prepararEAbrirOSeletor()
            }
        }
    }

    private func prepararEAbrirOSeletor() {
        // **O PIN é sorteado ao entrar na espera, e só troca quando a pessoa cancela e
        // recomeça.** Reabrir o app não é cancelar — e o app pode ser reaberto sem ninguém pedir:
        // o iOS encerra e relança um app a pedido de um depurador, e foi exatamente isso que
        // aconteceu na primeira corrida do produto. O roteiro de bancada lançou o app duas vezes,
        // o SpringBoard registrou `terminate for debugging launch request`, e a pessoa tocou uma
        // vez em cada processo: dois PINs, o receptor com o primeiro, a appex com o segundo, e
        // `pareamento: PIN incorreto`.
        //
        // Cada processo estava certo sozinho — um PIN por entrada na espera. O que faltava era
        // memória entre processos, e ela existe: o pedido já mora no App Group. Se há um pedido
        // recente que ninguém consumiu, ele **é** a espera em curso, e o PIN dele continua
        // valendo. `voltarAoInicio()` — que é o que o Cancelar chama — apaga o pedido, e aí sim
        // o próximo sorteio é novo.
        let pendente = Compartilhado.lerPedido()
        let aproveitavel = pendente.map {
            $0.utilizavel
                && Date().timeIntervalSince1970 - $0.carimbo < Emissor.validadeDoPedido
                && Compartilhado.lerEstado() == nil
        } ?? false

        if aproveitavel, let pendente {
            pin = pendente.pin
            porta = pendente.porta
            Diagnostico.nota("APP reaproveitando pedido pendente porta=\(porta)"
                + String(format: " idade=%.1f s", Date().timeIntervalSince1970 - pendente.carimbo))
        } else {
            let sorteado = Nucleo.sortearPin()
            guard sorteado.count == 6 else {
                dizer(.pinNaoSorteado)
                fase = .falhou
                return
            }
            pin = sorteado
            porta = Emissor.portaDaSinalizacao
        }
        par = ""
        conselho = ""
        segundosSemAppex = 0
        haParesConhecidos = Compartilhado.haParesConhecidos

        Compartilhado.apagarEstado()
        Compartilhado.limparCancelamento()
        Compartilhado.gravarPedido(PedidoDeEspelhamento(
            pin: pin, porta: porta,
            deviceId: Identidade.deviceId, nome: Identidade.nome))

        // **Anunciar antes de esperar**, e não depois: a porta é fixa e conhecida aqui, então este
        // aparelho pode aparecer na lista do outro **enquanto** espera, em vez de só depois que
        // alguém já tiver conectado — que seria inútil. É a mesma ordem do `Anunciante` do macOS.
        anunciante.comecar(deviceId: Identidade.deviceId, nome: Identidade.nome, porta: porta,
                           emiteTela: true, emiteCamera: false)

        comecouAEsperarEm = Date()
        fase = .esperando
        vigiar()

        // PIN e endereço não entram no diário, mesmo com o diagnóstico ligado.
        // `pares_conhecidos` sai aqui porque é ele que decide **a forma da tela de espera**: com
        // pares, o endereço é a manchete e o PIN desce; sem pares, o PIN é a manchete. Uma
        // afirmação sobre layout que a corrida não consegue testemunhar é uma afirmação sem
        // prova, e esta é a que o usuário reclamou.
        Diagnostico.nota("APP pedido gravado porta=\(porta)"
            + " pares_conhecidos=\(haParesConhecidos)")

        // A folha do seletor abre **depois** de a tela de espera estar montada, e não junto: se
        // ela abrisse antes, o toque da pessoa cairia sobre uma hierarquia de vistas que ainda
        // vai mudar — e o que a captura pegaria logo depois do toque seria a folha do sistema,
        // não o conteúdo. Meio segundo é o suficiente para a transição terminar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SeletorDeTransmissao.abrir()
        }
    }

    /// Reabre a folha do sistema. A tela de espera oferece isto quando a appex não dá sinal:
    /// dispensar a folha com um toque para fora é fácil, e nada avisa o app quando acontece.
    func abrirOSeletorDeNovo() {
        SeletorDeTransmissao.abrir()
    }

    // --- cancelar ---------------------------------------------------------------------------

    /// O Cancelar da tela de espera.
    ///
    /// Só a extension pode encerrar a própria transmissão. O app deixa o recado no App Group, e
    /// a supervisão de 1 Hz da appex — que **não** é a thread bloqueada em `quall_host` — chama
    /// `finishBroadcastWithError`. Latência de desenho: até um segundo.
    ///
    /// Quando não há appex nenhuma — a pessoa dispensou a folha sem começar —, não há a quem
    /// mandar recado, e a volta é imediata.
    func cancelar() {
        guard fase == .esperando || fase == .transmitindo else {
            voltarAoInicio()
            return
        }
        guard Compartilhado.lerEstado() != nil else {
            voltarAoInicio()
            return
        }
        Compartilhado.pedirCancelamento()
        fase = .encerrando
    }

    /// A saída do beco sem saída (dívida 22), e a única que a casca tem.
    ///
    /// Apaga os segredos **deste** lado. A espera continua, com o mesmo PIN: quando o outro
    /// aparelho tentar de novo, este não terá segredo nenhum e o núcleo vai pelo caminho do PIN —
    /// que é justamente o caminho que a retomada falhada não oferecia.
    func esquecerPares() {
        Compartilhado.esquecerPares()
        ofereceDesparear = false
        // A tela de espera muda de forma aqui, na mão da pessoa: sem pares, o PIN volta a ser a
        // manchete, porque agora ele é mesmo o único caminho.
        haParesConhecidos = false
        dizer(.paresEsquecidos)
    }

    func voltarAoInicio() {
        vigia?.invalidate()
        vigia = nil
        // O anúncio some junto com a espera. Deixar um anúncio fantasma na lista dos outros
        // aparelhos até o TTL expirar é a dívida 3 do núcleo repetida numa casca — e ali ela
        // custou uma thread de daemon viva por sessão.
        anunciante.parar()
        Compartilhado.apagarPedido()
        Compartilhado.apagarEstado()
        Compartilhado.limparCancelamento()
        pin = ""
        par = ""
        conselho = ""
        fase = .inicial
    }

    // --- vigia --------------------------------------------------------------------------------

    /// Lê o estado que a appex publica, a 1 Hz. É o que faz a tela de espera mudar quando alguém
    /// entra — e o que a faz dizer o motivo quando não entra.
    private func vigiar() {
        vigia?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.olhar()
        }
        RunLoop.main.add(t, forMode: .common)
        vigia = t
    }

    private func olhar() {
        guard let estado = Compartilhado.lerEstado() else {
            segundosSemAppex = Int(Date().timeIntervalSince(comecouAEsperarEm))
            // Sem estado e com cancelamento pedido, não há appex para responder.
            if fase == .encerrando { voltarAoInicio() }
            return
        }
        segundosSemAppex = 0

        // Batimento parado é appex morta — jetsam, ou o sistema encerrando a transmissão. Em
        // qualquer caso não há mais espelhamento, e insistir na tela de espera seria mentir.
        if estado.idadeEmSegundos > 6 {
            if fase == .encerrando { voltarAoInicio(); return }
            if estado.conselho.isEmpty { dizer(.encerradaPeloSistema) } else { conselho = estado.conselho }
            fase = .falhou
            vigia?.invalidate()
            vigia = nil
            return
        }

        if estado.porta > 0 { porta = estado.porta }

        // O erro cru vem junto do conselho de propósito: é ele, e não o texto traduzido, que diz
        // se a ação certa é esquecer o pareamento.
        ofereceDesparear = EstadoDeParConhecido.ehParDesconhecido(estado.erro)

        // Quem grava o `pares.json` é a appex, noutro processo, quando um pareamento fecha. Uma
        // sessão que subiu e caiu devolve a tela de espera com um par a mais do que ela tinha ao
        // nascer — e a forma da tela precisa acompanhar. Só publica quando muda: uma reavaliação
        // de `body` por segundo numa tela que está sendo espelhada é bitrate gasto à toa.
        let agora = Compartilhado.haParesConhecidos
        if agora != haParesConhecidos { haParesConhecidos = agora }

        switch estado.etapa {
        case .preparando, .esperando:
            if fase != .encerrando { fase = .esperando }
            par = ""
            // Um conselho na fase de espera é a permissão de rede local negada, a porta ocupada,
            // ou o PIN recusado. Todos são coisas que a pessoa consegue resolver — se alguém
            // disser quais são.
            conselho = estado.conselho
        case .transmitindo:
            if fase != .encerrando { fase = .transmitindo }
            par = estado.par
            conselho = ""
        case .erro:
            if estado.conselho.isEmpty { dizer(.naoComecou) } else { conselho = estado.conselho }
            fase = .falhou
        case .encerrado:
            voltarAoInicio()
        }
    }

    /// Chamado quando o app volta ao primeiro plano. A appex continuou trabalhando enquanto o app
    /// esteve fora — é para isso que ela é autônoma —, e a tela precisa reencontrar o estado.
    func aoVoltarAoPrimeiroPlano() {
        relerEnderecos()
        retomarSeHouverTransmissao()
        if fase == .esperando || fase == .transmitindo || fase == .encerrando { vigiar() }
    }

    private func retomarSeHouverTransmissao() {
        guard let estado = Compartilhado.lerEstado(), estado.idadeEmSegundos <= 6,
              let pedido = Compartilhado.lerPedido()
        else { return }
        pin = pedido.pin
        porta = estado.porta > 0 ? estado.porta : pedido.porta
        par = estado.par
        conselho = estado.conselho
        fase = estado.etapa == .transmitindo ? .transmitindo : .esperando
        comecouAEsperarEm = Date()
        vigiar()
    }

    /// Relê os dois endereços de uma vez.
    ///
    /// **De uma vez, e não em dois lugares**: `ip` e `ipDoCabo` são lidos da mesma enumeração de
    /// interfaces, e a tela decide entre eles. Duas leituras separadas teriam o instante em que
    /// uma está atualizada e a outra não — que é como o destaque acabaria mostrando cabo com
    /// Wi-Fi de pé.
    private func relerEnderecos() {
        ip = Enderecos.principal()
        ipDoCabo = Enderecos.principalDoCabo()
    }

    /// `192.168.56.42:7877` — o que se digita no outro aparelho. É o fallback obrigatório do
    /// fluxo, e hoje é o **único** caminho: nenhum perfil de provisionamento tem o entitlement de
    /// multicast, então este iPhone não aparece por mDNS em lista nenhuma.
    ///
    /// Deixou de ser só o da LAN em 01/09/2026: sem Wi-Fi e com cabo, é o do cabo. A decisão de
    /// qual dos dois entra aqui mora em `Enderecos.destaque` — uma cópia só, porque são duas telas
    /// e dois emissores. `nil` agora significa **sem rede nenhuma**, e é isso que desabilita o
    /// botão de emitir.
    var enderecoParaDigitar: String? {
        Enderecos.destaque(lan: ip, cabo: ipDoCabo, porta: porta)
    }

    /// A linha pequena debaixo do destaque, ou `nil` quando não há cabo e a tela não tem por que
    /// falar de cabo. Ver `Enderecos.notaDoEnlace`.
    var notaDoEnlace: String? {
        Enderecos.notaDoEnlace(lan: ip, cabo: ipDoCabo, porta: porta)
    }
}
