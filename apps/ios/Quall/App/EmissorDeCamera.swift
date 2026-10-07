import Foundation
import AVFoundation
import Combine
import CoreMedia
import UIKit

/// Publica na thread principal sem re-despachar quando já se está nela.
///
/// Um `DispatchQueue.main.async` incondicional adiaria em um ciclo de run loop toda mudança de
/// interface que já veio do toque — e a tela de espera existe justamente para não parecer parada.
func naPrincipal(_ bloco: @escaping () -> Void) {
    if Thread.isMainThread { bloco() } else { DispatchQueue.main.async(execute: bloco) }
}

/// A câmera: **uma origem por sessão, escolhida antes do PIN**.
///
/// `contrato-track.md` prometia "dois processos, duas tracks, uma sessão". No iOS isso é
/// impossível: uma `QuallSession` vive num processo, e a Broadcast Upload Extension (que captura
/// a tela) e o app (que captura a câmera) são processos separados, com memórias separadas. Três
/// projetos de arquitetura independentes chegaram a essa conclusão por caminhos diferentes.
///
/// A resposta de produto, decidida em 2026-08-22 (`docs/fluxo-de-uso.md`), **não** foi ensinar o
/// receptor a lidar com duas origens: foi o emissor escolher antes. Uma entrada na lista, um PIN,
/// uma sessão, uma porta. Este arquivo hospeda a sessão quando a origem escolhida é uma câmera —
/// e nesse caso **nada de ReplayKit, nada de appex, nada do teto de 50 MB**: é o app do começo ao
/// fim, e a pessoa não vê a folha do sistema nem o indicador vermelho de gravação de tela.
///
/// A origem é **fixa pela sessão**, porque não há renegociação no protocolo (dívida 1): trocar de
/// câmera é encerrar e começar de novo. Por isso não existe botão de trocar aqui — o seletor da
/// tela inicial é onde essa escolha mora.
///
/// ## O que muda por estar no app
///
/// * **Não há teto de 50 MB.** Isto aqui não é a appex; é o processo do app, que também renderiza
///   a pré-visualização. As regras de disciplina de memória continuam valendo por higiene, não
///   por orçamento.
/// * **A câmera para quando o app vai para segundo plano.** É comportamento padrão do iOS, não
///   defeito, e não é só a câmera: o processo inteiro é suspenso, então a **sessão também para**
///   e o receptor vê o fluxo cessar. Este arquivo trata a interrupção pedindo um IDR na volta, e
///   a tela avisa a pessoa antes que ela conclua que quebrou. Não há contorno — o modo de fundo
///   que a Apple oferece para captura contínua é para áudio, e forçar um seria trabalhar contra
///   a plataforma para entregar um comportamento que ela não sustenta.
/// * **A rotação é do pipeline de captura**, não nossa: mudar `videoOrientation` na conexão faz
///   o próprio ISP entregar o quadro já girado. É de graça, e é por isso que a câmera resolve
///   rotação de um jeito que a tela não resolve.
/// * **Aqui existe um botão de parar que a appex não tem.** Parar (e fechar a tela) aciona o
///   cancelador do núcleo (`quall_host_cancelable`, dívida 10), e a porta cai na hora: ver
///   `armarCancelador` e `SolturaDaPorta`. Até 27/09 era uma cutucada TCP, que o núcleo deixou de
///   atender em 01/09 sem ninguém notar.
///
/// ## A câmera não é mais deste arquivo (R5, 24/09/2026)
///
/// A `AVCaptureSession` mudou para `DonoDaCaptura`, e este emissor é um **assinante** dele: recebe
/// os quadros enquanto há sessão do Quall de pé. Nas duas telas de câmera — a comum (`TelaDaCamera`,
/// desde 24/09 à noite, para gravar sem receptor) e a "Teleprompter com câmera" — o dono é **da
/// tela**, e o emissor roda no modo **pendurado**: se pendura quando o receptor pareia, se solta
/// quando ele cai, e hospeda de novo com o mesmo PIN, sem tocar na câmera
/// (`docs/teleprompter-com-camera.md` §1.1 e §8.8). O modo de dono próprio (`init()`) ficou sem
/// chamador.
///
/// Sem `@MainActor`, pelo mesmo motivo do `Emissor`: os quadros chegam numa fila própria e o
/// delegado do `AVCaptureVideoDataOutput` não tem isolamento nenhum. O que precisa aparecer na
/// interface passa por `naPrincipal`.
final class EmissorDeCamera: NSObject, ObservableObject {

    enum Fase: Equatable {
        case parada
        case pedindoPermissao
        /// Negada ou restringida. O texto diz **o que fazer**, e `podeAbrirAjustes` diz se abrir
        /// os Ajustes resolve: com restrição por controle parental, não resolve.
        case semPermissao(motivo: String, podeAbrirAjustes: Bool)
        case esperando
        case transmitindo
        /// Parar pedido; esperando o desmonte terminar fora da thread principal.
        case encerrando
        case falhou(String)
    }

    /// **A mesma porta da tela.** Ver `Emissor.portaDaSinalizacao`: com uma origem por vez, duas
    /// portas seriam duas entradas na lista do receptor, que é justamente o que a decisão de
    /// produto veio apagar.
    static var porta: UInt16 { Emissor.portaDaSinalizacao }

    /// O anúncio por mDNS enquanto a câmera espera. Ver `AnuncianteBonjour`.
    private let anunciante = AnuncianteBonjour()
    var nomeNaDescoberta: String? { anunciante.nomePublico }

    /// Prazo de cada tentativa de `quall_host`, re-armado em laço. O mesmo da appex, e pela mesma
    /// dívida (10) — mas aqui ele **não** é o ponto de cancelamento: ver `armarCancelador`.
    private static let prazoPorTentativa: UInt32 = 20_000

    /// Quanto tempo esperar por um receptor antes de desistir sozinho, contado a partir do último
    /// sinal de vida e não do começo: quem está tentando entrar e errando a digitação não pode
    /// ser punido pela própria tentativa.
    private static let esperaMaxima: Double = 600

    /// **Teto absoluto de tentativas, e ele não é higiene.**
    ///
    /// `esperaMaxima` conta do último sinal de vida, e "sinal de vida" inclui uma tentativa que
    /// falhou por algo que não seja o prazo. Numa rede em que o pareamento **fecha** e o ICE
    /// **não** — Wi-Fi de hóspede, isolamento de AP, permissão de Rede Local negada —, cada volta
    /// reinicia o relógio e o laço nunca acaba.
    ///
    /// Isso seria só desperdício se o núcleo não cobrasse por volta. Ele cobra: a dívida 21 diz
    /// que a `Session` com tracks é criada **depois** do pareamento, dentro do laço, e a dívida 4
    /// diz que `Drop for Session` faz `track.esquecer()` em vez de `track.fechar()` — a `Track`,
    /// com pacotizador H.264, relator RTCP e cadeia de handlers, fica presa em mapas globais do
    /// processo **para sempre**. Uma tentativa, uma track vazada. A dívida 21 é explícita: nenhuma
    /// casca tira o teto antes de a dívida 4 ser consertada.
    ///
    /// Quarenta tentativas de vinte segundos são treze minutos de espera, que é mais do que
    /// qualquer sala real precisa, e um número de vazamentos que cabe na memória do app.
    private static let tetoDeTentativas = 40

    @Published private(set) var fase: Fase = .parada
    @Published private(set) var pin = ""
    @Published private(set) var par = ""
    @Published private(set) var conselho = ""
    /// O `conselho` na tela é o da porta presa (`textoDaPortaPresa`). Uma bandeira, e não a
    /// comparação do texto: o texto muda com o idioma. Só na principal.
    private var conselhoEhDaPortaPresa = false
    /// Por que a captura parou, quando parou. Vazio quando está correndo.
    @Published private(set) var interrupcao = ""
    /// Modo pendurado: o receptor caiu e a sessão velha está sendo desmontada antes de a porta
    /// voltar a atender. A tela diz "reabrindo", e não "enviando".
    @Published private(set) var reabrindo = false
    /// A retomada do pareamento falhou. Ver `Emissor.ofereceDesparear` e a dívida 22.
    @Published private(set) var ofereceDesparear = false
    /// Existe **algum** par conhecido — não necessariamente o que vai chegar. Decide se a tela
    /// abre com o PIN como manchete ou com o endereço. Ver `Emissor.haParesConhecidos`.
    @Published private(set) var haParesConhecidos = Compartilhado.haParesConhecidos


    /// A câmera escolhida no seletor da tela inicial. Fixa pela sessão inteira.
    private(set) var origem: Origem = .tela

    /// **Quem é dono da câmera.** Ver `DonoDaCaptura`.
    ///
    /// - Na tela da câmera comum, o dono é **próprio**: o emissor o monta no Espelhar e o fecha no
    ///   Parar, e a câmera vive o mesmo tanto que antes.
    /// - Na tela "Teleprompter com câmera" (R5) **e, desde 24/09 à noite, na tela da câmera comum**
    ///   (para gravar sem receptor, §8.8), o dono é **da tela** e chega pronto: o emissor só se
    ///   pendura nele quando um receptor pareia e se solta quando ele cai, e **hospeda de novo** com o
    ///   mesmo PIN — sem nunca tocar na câmera (`docs/teleprompter-com-camera.md` §1.1). É o modo
    ///   `pendurado`. O dono próprio ficou sem chamador.
    let dono: DonoDaCaptura
    /// `true` no modo da tela R5: dono de fora, e o laço de hospedagem não acaba na primeira sessão.
    let pendurado: Bool

    /// A sessão de captura do dono. Mantida pelo nome de antes, para a prévia.
    var sessao: AVCaptureSession { dono.sessao }

    private var assinaturaDaInterrupcao: AnyCancellable?

    /// A tela da câmera comum: o emissor monta e fecha a câmera.
    override init() {
        dono = DonoDaCaptura()
        pendurado = false
        recomecar = { tr("comece de novo.") }
        super.init()
        ligarInterrupcao()
    }

    /// O fim do texto de quando o laço desiste (o teto de tentativas): o que a pessoa faz para
    /// tentar de novo, e o que continua funcionando até lá. É de cada tela.
    /// Calculado na hora (e não guardado), para seguir o idioma.
    var textoDeRecomecar: String { recomecar() }
    private let recomecar: () -> String

    static var recomecarNaTelaComCamera: String {
        tr("saia desta tela e abra de novo; o texto continua funcionando até lá.")
    }
    static var recomecarNaTelaDaCamera: String {
        tr("toque em Parar e escolha a câmera de novo; gravar neste aparelho continua funcionando até lá.")
    }

    /// A tela R5 e a da câmera comum: a câmera é da tela, e já está aberta (ou abrindo) quando o
    /// emissor começa.
    init(dono: DonoDaCaptura,
         textoDeRecomecar: @escaping @autoclosure () -> String = EmissorDeCamera.recomecarNaTelaComCamera) {
        self.dono = dono
        self.recomecar = textoDeRecomecar
        pendurado = true
        super.init()
        ligarInterrupcao()
    }

    /// O texto da interrupção é do dono (é a câmera que para), e a tela da câmera comum o lê daqui.
    private func ligarInterrupcao() {
        assinaturaDaInterrupcao = dono.$interrupcao
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.interrupcao = t }
    }

    private let travaDoEnvio = NSLock()
    private var nucleo: Nucleo?
    private var codificador: CodificadorH264?
    private var entradaAtual = CGSize.zero
    private var enviando = false
    private var bitrateAtual = 0
    private var ultimoEncodePts: Double = -1
    /// **A janela de 10 s do som da rede, avaliada** (§8.12.16): `ruim` (a espera na fila do Opus ou a
    /// idade na entrada acima de ~500 ms, ou som descartado) e se há transmissão de pé. Na principal; é
    /// o sinal dos degraus da tela R5 (`DegrausDaTransmissao`).
    var aoAvaliarSom: ((_ ruim: Bool, _ transmitindo: Bool, _ quente: Bool, _ resumo: String) -> Void)?

    /// **A rede reduzida pelo calor** (§8.12.1): o que o laço de 1 Hz decidiu (`redeReduzida`) e
    /// com o que o encoder de agora nasceu (`reduzidaNoEncoder`). Diferentes, o próximo quadro refaz
    /// o encoder (com IDR, como num giro). Sob `travaDoEnvio`.
    private var redeReduzida = false
    private var reduzidaNoEncoder = false
    /// O tamanho de saída do encoder de agora: a rede reduzida só refaz o encoder se o tamanho mudar
    /// (com o cardápio em 720p, reduzir não muda nada — revisão do código de 27/09, M2).
    private var saidaAtual: (Int32, Int32) = (0, 0)
    /// O fps com que o encoder de agora nasceu (`ExpectedFrameRate` e o intervalo de IDR): a rede
    /// quente muda o fps sem mudar o tamanho quando o cardápio já é 720p, e o encoder é refeito.
    private var fpsDoEncoder = 0
    /// **A geração do encoder da rede.** Refeito o encoder, o velho é encerrado **fora** da fila da
    /// câmera (o `CompleteFrames` dele, num A10 quente, seguraria o quadro do arquivo, que vem logo
    /// depois na mesma fila — revisão do código de 27/09, M1), e o que ele ainda devolver é
    /// descartado por aqui: o núcleo não recebe um PTS velho depois do IDR do encoder novo. Sob
    /// `travaDoEnvio`.
    private var geracaoDoEncoder = 0
    /// A histerese da rede reduzida. Só no laço de 1 Hz (`ajustarAoAparelho`).
    private var calorDaRede = RedeReduzidaPeloCalor()

    /// **O velho não sai** (§8.12.1): as regras (vídeo e som, só na entrada) e a maior idade medida
    /// em cada ponto desde o último relato — o vídeo na entrada deste emissor, na saída do encoder e
    /// o tempo dentro do `enviar` do núcleo; o som na entrada e o tempo do Opus até o `enviarAudio`.
    /// São as testemunhas que separam "a captura atrasou", "o encoder segurou", "o envio segurou" e
    /// "o som atrasou" — o relógio recusado no iPhone 7 em 27/09, cujo sinal (resíduo negativo na
    /// track de vídeo, que não era a referência) aponta para o **som** chegando atrasado, e não para o
    /// vídeo (revisão de 27/09, B1).
    private let travaDoDescarte = NSLock()
    /// 150 quadros seguidos (~5 s a 30 fps) antes de desistir: a captura de vídeo descarta o que
    /// atrasa (`alwaysDiscardsLateVideoFrames`), então uma fila longa de velhos é relógio errado.
    private var descarteDoVideo = DescarteDeVelhos.doVideo()
    /// 250 buffers seguidos (~5 s de ~21 ms): o microfone não descarta o que atrasa, e é justamente
    /// uma fila de segundos que esta regra existe para escoar.
    private var descarteDoSom = DescarteDeVelhos.doSom()
    private var _idadeMaxNaEntrada: Double = 0
    private var _idadeMaxNaSaida: Double = 0
    private var _envioMax: Double = 0
    private var _idadeMaxDoSom: Double = 0
    private var _somMax: Double = 0
    /// **O Opus fora da fila da entrega do microfone** (§8.12.11): a entrega só converte o relógio e
    /// passa adiante; a reamostragem, o Opus e o `enviarAudio` (que disputa a trava do núcleo com o
    /// envio de vídeo) correm aqui. Um Opus lento não atrasa mais a entrega (nem a gravação, que
    /// recebe o som da mesma entrega), e a fila que se formar aqui é a que o descarte pelo piso escoa:
    /// a idade é medida ao sair desta fila, e não ao entrar.
    /// **`userInitiated`** (decisão do Pessoa Exemplo, 27/09, §8.12.14): o experimento com `userInteractive`
    /// (`70867dd`) não deu CPU ao Opus no iPhone 7 quente (a espera nesta fila chegou a 2,3 s) e a
    /// gravação piorou (26 fps). O custo do encode é pequeno (4 ms por quadro): falta CPU, e a prioridade
    /// alta só a tira de outro lugar.
    private let filaDoOpus = DispatchQueue(label: "br.com.queven.quall.microfone.opus", qos: .userInitiated)
    /// **O teto da fila em milissegundos de som**, e não em buffers (§8.12.13): a entrega recusa o buffer
    /// que faria o som pendente passar de `pendenteMaximoMs` (e conta, `descartado_por_fila=`). É o que
    /// limita o atraso do som da rede por construção, e o que já foi recusado nunca é codificado. Sob
    /// `travaDoDescarte`.
    /// Em microssegundos inteiros (a soma de 21,333… ms em `Double` deixa resíduo, e o "fila vazia" tem
    /// de ser exato).
    private var _pendenteNoOpusUs: Int64 = 0
    private var _somDescartadoPorFila: UInt64 = 0
    private var _pendenteMaximoVistoMs: Double = 0
    /// O som que não foi à rede nesta janela, pelos dois tetos (µs).
    private var _somPerdidoUs: Int64 = 0
    ///
    /// **A troca atraso × picote** (§8.12.14): com 120/150 ms, o iPhone 7 quente descartou 30–40 % do som
    /// (picotado); a decisão do Pessoa Exemplo é o contrário — no calor o som da rede **atrasa** até ~1 s, inteiro,
    /// e só o que passar disso é descartado (a fila não cresce sem fim). Em regime frio nada é descartado.
    static let pendenteMaximoMs: Double = 1000
    /// Ao sair da fila, um buffer com a espera nela acima disto não é codificado (`velhos_na_fila=`).
    static let esperaMaximaNaFilaMs: Double = 1200
    private var _velhosNaFila: UInt64 = 0
    private var _esperaMaximaNaFilaMs: Double = 0

    /// O caminho do microfone até o Opus, **por sessão**: nasce no primeiro buffer de áudio com a
    /// sessão de pé, e morre com ela. Sob `travaDoEnvio`; consumido só na `filaDoOpus` (§8.12.11).
    private var microfoneParaOpus: MicrofoneParaOpus?
    /// O encoder do microfone já falhou nesta sessão: não tenta de novo a cada buffer.
    private var microfoneSemEncoder = false

    /// **O ponto de parada que a fronteira C não oferece.**
    ///
    /// A versão anterior deste arquivo usava uma bandeira `encerrando`, e ela tinha um defeito de
    /// verdade: `parar()` a levantava e a **baixava de novo** no fim do mesmo método, na thread
    /// principal, enquanto a thread de hospedagem continuava bloqueada dentro de `quall_host` por
    /// até vinte segundos. Quando essa thread finalmente voltava, lia a bandeira já baixada e
    /// **seguia hospedando** — com o PIN velho, na porta de sinalização, sem tela nenhuma na frente. A
    /// próxima tentativa de compartilhar a câmera encontraria a porta ocupada por um fantasma do
    /// processo, e o sintoma ("não conecta mais, só matando o app resolve") não aponta para cá.
    ///
    /// Um contador de geração não tem esse modo de falha: cada corrida carrega o número com que
    /// nasceu, e qualquer mudança — parar, começar de novo — invalida a anterior para sempre. Não
    /// existe estado a restaurar, e por isso não existe restauração errada.
    private let travaDaGeracao = NSLock()
    private var geracao = 0
    /// O cancelador do `quall_host_cancelable` em curso, **sob a trava da geração**: `parar` troca
    /// a geração e aciona o cancelador no mesmo gesto, e o laço, ao armar um cancelador novo, confere
    /// a geração ali mesmo (o mesmo desenho de `SessaoDoTeleprompter.armarCancelador`). Sem isso, um
    /// Parar entre o `while` e o armar deixaria uma espera de vinte segundos na porta.
    private var canceladorDaEspera: OpaquePointer?


    /// Os dois endereços e o que a tela faz com eles. Mesma decisão do espelhamento, mesma origem:
    /// ver `Emissor.enderecoParaDigitar` e `Enderecos.destaque`.
    ///
    /// Aqui são propriedades computadas, e não `@Published` como no `Emissor`: esta tela vive
    /// enquanto a câmera está no ar, e nesse intervalo o endereço não muda. Continuam sendo lidas
    /// **as duas juntas**, da mesma enumeração, a cada avaliação.
    var ip: String? { Enderecos.principal() }
    var ipDoCabo: String? { Enderecos.principalDoCabo() }
    var enderecoParaDigitar: String? {
        Enderecos.destaque(lan: ip, cabo: ipDoCabo, porta: EmissorDeCamera.porta)
    }
    var notaDoEnlace: String? {
        Enderecos.notaDoEnlace(lan: ip, cabo: ipDoCabo, porta: EmissorDeCamera.porta)
    }


    /// O supervisor de 1 Hz do emissor: o bitrate e os contadores do encoder. O da câmera (a prévia,
    /// o formato vigente) é do dono.
    private var relogio: DispatchSourceTimer?

    /// O laço de hospedagem está vivo. No modo pendurado é ele quem desmonta a sessão e avisa
    /// `.parada` quando termina: ver `parar`.
    private let travaDoLaco = NSLock()
    private var lacoVivo = false
    private var _tentativaNoAr = 0
    /// A tentativa cujo `quall_host` está bloqueado agora (0: nenhuma). Escrita pelo laço, lida
    /// pela principal para tirar o aviso da porta presa quando a porta já é nossa.
    private var tentativaNoAr: Int {
        get { travaDoLaco.lock(); defer { travaDoLaco.unlock() }; return _tentativaNoAr }
        set { travaDoLaco.lock(); _tentativaNoAr = newValue; travaDoLaco.unlock() }
    }

    /// A porta continua presa depois da tolerância de `SolturaDaPorta` (uma sessão anterior ainda
    /// desmontando, ou outro app nela). O laço segue tentando sozinho: a pessoa não precisa fazer
    /// nada, e o aviso some quando a porta vier.
    static var textoDaPortaPresa: String {
        tr("A porta de rede da câmera ainda está presa (uma transmissão "
           + "anterior terminando, ou outra no ar). Tentando de novo sozinho — o PIN continua o mesmo.")
    }

    // --- ciclo de vida ----------------------------------------------------------------------

    /// O toque em "Espelhar" com uma câmera escolhida. Permissão de câmera primeiro, rede local
    /// depois, captura e hospedagem por último.
    ///
    /// - Parameter origem: a câmera **física** escolhida no seletor. Fixa daqui até o fim da
    ///   sessão: não há renegociação no protocolo, e oferecer uma troca que o protocolo não
    ///   sustenta seria um botão que falha.
    func comecar(_ origem: Origem) {
        guard fase == .parada, !pendurado else { return }
        guard origem.ehCamera else {
            fase = .falhou(tr("Esta tela é das câmeras. A tela do iPhone vai pela transmissão do "
                + "sistema."))
            return
        }
        // Uma origem por vez, e a recusa é aqui — com texto — em vez de virar "endereço em uso"
        // lá na frente. A appex sobrevive ao app: pode haver espelhamento no ar desde antes.
        guard !Emissor.haEspelhamentoVivo else {
            fase = .falhou(EmissorDeCamera.textoDeEspelhamentoVivo)
            return
        }
        self.origem = origem
        fase = .pedindoPermissao
        DonoDaCaptura.pedirPermissao { [weak self] resposta in
            guard let self else { return }
            switch resposta {
            case .concedida:
                self.pedirRedeEMontar()
            case let .recusada(motivo, podeAbrirAjustes):
                self.recusar(motivo, podeAbrirAjustes: podeAbrirAjustes)
            }
        }
    }

    /// O começo no modo pendurado (a tela R5): a câmera já é do dono, aberta pela tela. Aqui só a
    /// rede local, o PIN, o anúncio e o laço de hospedagem — que se pendura no dono a cada receptor
    /// e se solta a cada queda.
    func comecarPendurado() {
        guard fase == .parada, pendurado else { return }
        guard !Emissor.haEspelhamentoVivo else {
            fase = .falhou(EmissorDeCamera.textoDeEspelhamentoVivo)
            return
        }
        origem = dono.origem
        fase = .pedindoPermissao
        pedirRedeEMontar()
    }

    static var textoDeEspelhamentoVivo: String {
        tr("Há um espelhamento de tela em curso neste iPhone. Pare a transmissão (o indicador vermelho "
           + "no alto da tela) e escolha a câmera de novo — o Quall envia uma origem por vez.")
    }

    static var textoDeNegada: String { DonoDaCaptura.textoDeNegada }

    private func recusar(_ motivo: String, podeAbrirAjustes: Bool) {
        Diagnostico.nota("APP CAMERA sem permissão de câmera ajustes=\(podeAbrirAjustes)")
        fase = .semPermissao(motivo: motivo, podeAbrirAjustes: podeAbrirAjustes)
    }

    private func pedirRedeEMontar() {
        // A permissão de Rede Local é portão medido: sem ela o `quall_host` volta com
        // "o ICE não achou caminho", depois de gastar o prazo inteiro. Ver `PermissaoDeRedeLocal`.
        PermissaoDeRedeLocal.pedir { [weak self] resposta in
            guard let self else { return }
            // O pedido volta depois: a tela pode ter saído no meio (o Parar já passou por aqui).
            guard self.fase == .pedindoPermissao else { return }
            if resposta == .negada {
                self.conselho = tr("O Quall precisa de acesso à rede local para achar o outro "
                    + "aparelho. Abra %@ e ligue.", trSistema("Ajustes → Quall Studio → Rede Local"))
                self.conselhoEhDaPortaPresa = false
            }
            self.montarEHospedar()
        }
    }

    /// O botão Parar, e o fim da tela.
    ///
    /// **Nada de trabalho bloqueante na thread principal.** `quall_session_close` desce até
    /// `Link::close`, que faz escrita sem prazo (dívida 19): com o par sumido, ele pendura pelo
    /// tempo que o TCP do Darwin levar para desistir — minutos. Na appex isso é contornado com
    /// espera limitada porque o sistema mata o processo logo depois; aqui não há quem mate, e uma
    /// thread principal presa é o app inteiro congelado com a interface no ar.
    ///
    /// **No modo pendurado a câmera não é tocada aqui** (ela é da tela, que a fecha), e a sessão do
    /// Quall é desmontada pelo próprio laço de hospedagem, que é a única thread que a lê
    /// (`Nucleo.proximoEvento`): fechar daqui, com o laço dentro de `quall_session_next_event`,
    /// seria liberar a sessão debaixo dele.
    func parar() {
        guard fase != .parada else { return }
        anunciante.parar()
        let minha = novaGeracaoCancelandoAEspera()

        travaDoEnvio.lock()
        enviando = false
        let n = pendurado ? nil : nucleo
        let c = pendurado ? nil : codificador
        let mic = pendurado ? nil : microfoneParaOpus
        if !pendurado {
            nucleo = nil
            codificador = nil
            microfoneParaOpus = nil
            microfoneSemEncoder = false
        }
        travaDoEnvio.unlock()
        dono.soltar(self)

        relogio?.cancel()
        relogio = nil
        if !pendurado { dono.pararObservacao() }

        if !pendurado {
            Diagnostico.nota("APP CAMERA encerrando enviados=\(n?.enviados ?? 0)"
                + " recusados=\(n?.recusados ?? 0)"
                + " saida=\(c?.dimensaoDaSaida ?? "?")"
                + " formato_da_camera=\(dono.formatoRecebido)"
                + " desc_fila=\(c?.descartadosPorFila ?? 0)"
                + " desc_encoder=\(c?.descartadosPeloEncoder ?? 0)"
                + " cresc_buffer=\(c?.crescimentosDoBuffer ?? 0)"
                + " nucleo={\(n?.estatisticasDaTrack ?? "")}")
            // O que o remendo de SPS fez, dito em voz alta: é o que separa 4 ms de 170 ms no decode do
            // outro lado, e um remendo que desiste em silêncio é pior do que remendo nenhum.
            Diagnostico.nota("APP CAMERA \(c?.remendoDeSPS.resumo() ?? "sem codificador")")
            Diagnostico.nota("APP MICROFONE encerrando: \(mic?.resumo() ?? "nenhum buffer nesta sessão")"
                + " nucleo_enviados=\(n?.audioEnviados ?? 0) nucleo_recusados=\(n?.audioRecusados ?? 0)"
                + " nucleo={\(n?.estatisticasDoMicrofone ?? "")}")
        }

        pin = ""
        par = ""
        conselho = ""
        conselhoEhDaPortaPresa = false
        reabrindo = false
        fase = .encerrando

        // A thread que possa estar dentro de `quall_host` já foi destravada acima, pelo cancelador
        // (`novaGeracaoCancelandoAEspera`): o `accept` do núcleo olha a bandeira a cada 20 ms, e o
        // listener da 7877 cai quando a chamada volta. Era a cutucada TCP até 27/09 — ver
        // `SolturaDaPorta` para por que ela parou de funcionar.

        if pendurado {
            // **A linha que o `provar.sh` (QUALL_ALVO=camera) espera para dar a corrida por
            // terminada**, agora que a câmera comum também é pendurada. Sem os contadores da sessão:
            // ela é do laço, que pode estar desmontando-a agora mesmo (ler daqui seria ler uma
            // sessão liberada). Eles saem na linha "transmissão solta do dono" do laço.
            Diagnostico.nota("APP CAMERA encerrando (modo pendurado: a transmissão, se houver, é"
                + " desmontada pelo laço) formato_da_camera=\(dono.formatoRecebido)")
            // O laço vê a geração trocada (em até 100 ms se estiver vigiando a queda; se estiver
            // dentro de `quall_host`, quando o cancelador o fizer voltar), desmonta e avisa
            // `.parada`. Se ele já acabou (desistiu, ou nem começou), ninguém mais vai avisar: é
            // aqui.
            travaDoLaco.lock()
            let vivo = lacoVivo
            travaDoLaco.unlock()
            if !vivo { fase = .parada }
            return
        }

        let d = dono
        let desmonte = Thread { [weak self] in
            d.pararDeRodar()
            // A ordem é a obrigatória, e a mesma da appex: drenar o encoder **antes** de soltar a
            // track. Invertido, um quadro sai do VideoToolbox depois de a track ter sido
            // liberada, e o `send_frame` lê uma caixa morta.
            let inicio = CFAbsoluteTimeGetCurrent()
            c?.encerrar()
            n?.encerrar()
            let gastou = CFAbsoluteTimeGetCurrent() - inicio
            if gastou > 2 {
                Diagnostico.falha(String(format:
                    "APP CAMERA o desmonte levou %.1f s (dívida 19: Link::close sem prazo)", gastou))
            }
            naPrincipal {
                guard let self, self.geracaoAtual() == minha else { return }
                self.fase = .parada
            }
        }
        desmonte.stackSize = 512 * 1024
        desmonte.name = "quall.camera.desmonte"
        desmonte.start()
    }

    /// Muda a orientação da conexão de captura. É do dono; fica aqui pelo nome que a tela da câmera
    /// comum já chama.
    func acompanharOrientacao(_ orientacao: UIInterfaceOrientation) {
        dono.acompanharOrientacao(orientacao)
    }

    /// A saída do beco sem saída (dívida 22). Ver `Emissor.esquecerPares`.
    func esquecerPares() {
        Compartilhado.esquecerPares()
        ofereceDesparear = false
        haParesConhecidos = false
        conselho = tr("Pareamentos esquecidos. Agora peça para o outro aparelho entrar de novo e "
            + "digitar o PIN que está nesta tela.")
        conselhoEhDaPortaPresa = false
    }

    // --- geração ------------------------------------------------------------------------------

    /// A geração nova **e** o cancelador da espera em curso acionado, sob a mesma trava.
    private func novaGeracaoCancelandoAEspera() -> Int {
        travaDaGeracao.lock(); defer { travaDaGeracao.unlock() }
        geracao += 1
        if let c = canceladorDaEspera { quall_session_cancel(c) }
        return geracao
    }

    /// Cria o cancelador de uma tentativa e o guarda, **já acionado** se a geração trocou. `nil` só
    /// se o núcleo não conseguir alocar — e aí a chamada é o `quall_host` de antes.
    private func armarCancelador(_ minha: Int) -> OpaquePointer? {
        guard let novo = quall_canceller_new() else { return nil }
        travaDaGeracao.lock()
        canceladorDaEspera = novo
        if geracao != minha { quall_session_cancel(novo) }
        travaDaGeracao.unlock()
        return novo
    }

    /// Tira o cancelador do alcance de `parar` **antes** de liberá-lo (a chamada já voltou).
    private func desarmarCancelador(_ c: OpaquePointer?) {
        guard let c else { return }
        travaDaGeracao.lock()
        if canceladorDaEspera == c { canceladorDaEspera = nil }
        travaDaGeracao.unlock()
        quall_canceller_free(c)
    }

    private func geracaoAtual() -> Int {
        travaDaGeracao.lock(); defer { travaDaGeracao.unlock() }
        return geracao
    }

    // A cutucada (`destravarHospedagem`, uma conexão TCP descartável para 127.0.0.1:7877 que
    // fazia o `quall_host` voltar com "handshake WebSocket falhou") saiu em 27/09: desde o conserto
    // de 01/09 no núcleo o candidato que morre no handshake é descartado e a espera continua até o
    // prazo, e a tela fechada seguia segurando a porta por até vinte segundos. O ponto de parada
    // agora é o cancelador do núcleo (`armarCancelador`). Ver `SolturaDaPorta`.


    // --- montagem -----------------------------------------------------------------------------

    private func montarEHospedar() {
        let sorteado = Nucleo.sortearPin()
        guard sorteado.count == 6 else {
            fase = .falhou(tr("Não foi possível sortear o PIN da sessão."))
            return
        }
        pin = EmissorDeCamera.pinDaBancada ?? sorteado
        haParesConhecidos = Compartilhado.haParesConhecidos

        // No modo pendurado a câmera já está montada e rodando: é da tela.
        if !pendurado, let erro = dono.montar(origem) {
            Diagnostico.falha("APP CAMERA a captura não montou: \(SanitizacaoDoLog.causaExterna(erro))")
            fase = .falhou(erro)
            return
        }
        // Anunciar **antes** de esperar, com a capacidade certa: aqui a origem é a câmera, e
        // quem lê a lista precisa saber disso para não oferecer "ver a tela deste aparelho".
        anunciante.comecar(deviceId: Identidade.deviceId, nome: Identidade.nome,
                           porta: EmissorDeCamera.porta, emiteTela: false, emiteCamera: true)
        fase = .esperando
        Diagnostico.nota("APP CAMERA pedido porta=\(EmissorDeCamera.porta)"
            + " pares_conhecidos=\(haParesConhecidos)"
            + (pendurado ? " modo=pendurado" : ""))
        subirSupervisao()
        hospedar()
        // A captura sobe já — a pré-visualização precisa existir enquanto a pessoa espera, senão
        // a tela da câmera é uma tela de espera preta. No modo pendurado a tela já a ligou.
        if !pendurado { dono.ligar() }
    }

    /// `--pin-da-camera NNNNNN`: o PIN fixo da sessão de câmera, para a bancada sem toque da tela
    /// R5 (o receptor do Mac conecta com um PIN conhecido). Só com o diagnóstico ligado — o mesmo
    /// cuidado do PIN no diário.
    static var pinDaBancada: String? {
        let args = CommandLine.arguments
        guard Diagnostico.ligado, let i = args.firstIndex(of: "--pin-da-camera"), i + 1 < args.count else {
            return nil
        }
        let p = args[i + 1]
        return p.count == 6 && p.allSatisfy(\.isNumber) ? p : nil
    }

    // --- hospedagem -----------------------------------------------------------------------------

    /// O único erro de `quall_host` que não passou do accept: ninguém conectou no prazo. É o texto
    /// literal do núcleo (`Error::Timeout("nenhum receptor conectou")` em `session.rs`, com o
    /// prefixo do `Display` de `error.rs`); o mesmo prefixo com outro texto já criou sessão.
    static let prazoSemNinguem = "tempo esgotado: nenhum receptor conectou"

    /// Uma sessão do modo pendurado que caiu antes disto conta para o teto de tentativas: ver
    /// `tentativasQueContam`.
    static let sessaoCurta: Double = 30

    /// `quall_host` **bloqueia**. Thread própria, prazo curto re-armado — as mesmas razões do lado
    /// da tela, e a mesma dívida (10). A diferença é que aqui o laço tem um ponto de parada de
    /// verdade: o cancelador (`armarCancelador`) faz a chamada voltar em vez de esperar o prazo.
    ///
    /// **A porta entre uma tela e a seguinte** (`SolturaDaPorta`): no modo pendurado o laço se
    /// registra na porta e, antes, espera até 2 s o laço de uma tela anterior terminar; e uma
    /// porta ainda presa dentro desses 2 s é repetida calada, sem conselho e sem contar.
    ///
    /// **No modo pendurado o laço não acaba na primeira sessão.** Com a sessão de pé ele se pendura
    /// no dono e passa a vigiar a queda (`Nucleo.proximoEvento`, a cada 100 ms); quando o receptor
    /// sai, ele se solta, desmonta a sessão (é ela que segura a porta: ver `soltarSessao`) e volta
    /// a hospedar **com o mesmo PIN** — a câmera e a prévia não ficam sabendo.
    private func hospedar() {
        let minha = geracaoAtual()
        let pinInicial = pin
        let nome = Identidade.nome
        let id = Identidade.deviceId
        let rotuloDaTrack = origem.rotulo(doAparelho: nome)
        let rotuloDoMicrofone = "Microfone — \(nome)"
        let pendurado = self.pendurado

        travaDoLaco.lock(); lacoVivo = true; travaDoLaco.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            var pinAgora = pinInicial // só esta thread altera o PIN da próxima tentativa
            // **A tela anterior soltando a porta** (fechar e reabrir, 27/09): o laço dela sai em
            // milissegundos pelo cancelador, mas uma sessão que estava de pé ainda desmonta (dívida
            // 19). Espera calada, com prazo; o que sobrar, a repetição calada abaixo cobre. Só no
            // modo pendurado: é nele que o laço é dono da sessão até o fim (no próprio, a sessão
            // sobrevive ao laço e quem a fecha é o desmonte de `parar`).
            let soltura = SolturaDaPorta.daCamera
            // A tolerância é uma só (~2 s), contada daqui: a espera pelo laço anterior e a
            // repetição calada da porta presa gastam do mesmo prazo.
            let antes = CFAbsoluteTimeGetCurrent()
            if pendurado {
                let restaram = soltura.esperarOsOutros(prazo: SolturaDaPorta.tolerancia)
                let esperou = CFAbsoluteTimeGetCurrent() - antes
                if esperou > 0.005 || restaram > 0 {
                    Diagnostico.nota(String(format: "APP CAMERA esperei %.0f ms a tela anterior soltar a porta",
                                            esperou * 1000) + " (laços vivos ao fim: \(restaram))")
                }
                soltura.entrar()
            }
            defer {
                // Depois de toda saída do laço, e todas passam por `candidato.encerrar()` ou
                // `soltarSessao` antes: o listener do núcleo já caiu quando isto roda.
                if pendurado { soltura.sair() }
                self.travaDoLaco.lock(); self.lacoVivo = false; self.travaDoLaco.unlock()
                // No modo pendurado, quem avisa o fim do Parar é o laço (ver `parar`).
                if pendurado {
                    naPrincipal {
                        if self.fase == .encerrando { self.fase = .parada }
                    }
                }
            }
            var tentativa = 0
            /// No modo pendurado, só **um** motivo de falha é de graça para o teto: o prazo sem
            /// ninguém (`tempo esgotado: nenhum receptor conectou`, `session.rs`), que não passa do
            /// accept e não cria sessão nem track. O mesmo prefixo `tempo esgotado:` também sai
            /// **depois** do pareamento (`a sessão não fechou dentro do prazo`), com a `Session` e
            /// as tracks já criadas (dívidas 21 e 4): essa conta. E conta também a sessão que subiu
            /// e caiu em menos de `sessaoCurta` — um receptor retomando em laço numa Wi-Fi que isola
            /// os aparelhos vazaria uma track por volta sem teto nenhum. A tela R5 espera um receptor
            /// pela vida dela, e não por treze minutos, mas não vaza sem limite.
            var tentativasQueContam = 0
            var recuo: Double = 0
            var ultimoSinalDeVida = CFAbsoluteTimeGetCurrent()
            /// Sobrevive às voltas do laço: sem isso a mensagem "alguém errou o PIN" seria apagada
            /// um instante depois pela tentativa seguinte, e quem apresenta veria um piscar.
            var conselhoVigente = ""
            /// Desde quando a porta **devia** estar livre: o começo do laço, e o fim de cada
            /// desmonte no modo pendurado. É daqui que conta a tolerância da repetição calada.
            var portaLivreDesde = antes
            /// O conselho na tela é o da porta presa: a próxima tentativa que passar de 1 s no
            /// `quall_host` prova que o `bind` deu certo, e ele sai (ver `tentativaNoAr`).
            var conselhoEraDaPorta = false

            while self.geracaoAtual() == minha {
                let semNinguem = !pendurado && CFAbsoluteTimeGetCurrent() - ultimoSinalDeVida
                    > EmissorDeCamera.esperaMaxima
                let cansou = (pendurado ? tentativasQueContam : tentativa) >= EmissorDeCamera.tetoDeTentativas
                if semNinguem || cansou {
                    let comecoDeNovo = self.textoDeRecomecar
                    let texto = cansou
                        ? tr("Foram %ld tentativas sem "
                            + "conseguir abrir a conexão. Confira se os dois aparelhos estão na mesma "
                            + "rede Wi‑Fi e se ela não isola os aparelhos entre si, e %@",
                             pendurado ? tentativasQueContam : tentativa, comecoDeNovo)
                        : tr("Ninguém entrou. Escolha a câmera e toque em Espelhar de novo quando o "
                            + "outro aparelho estiver pronto.")
                    Diagnostico.nota("APP CAMERA desistindo tentativas=\(tentativa)"
                        + (pendurado ? " que_contam=\(tentativasQueContam)" : "")
                        + " motivo=\(cansou ? "teto de tentativas" : "ninguém entrou")")
                    naPrincipal {
                        guard self.geracaoAtual() == minha else { return }
                        // Desistiu: ninguém mais atende a porta, e o anúncio não pode continuar
                        // oferecendo um aparelho que não aceita conexão.
                        self.anunciante.parar()
                        self.fase = .falhou(texto)
                    }
                    return
                }
                tentativa += 1
                // O roteiro de bancada espera esta linha para subir o receptor na hora certa.
                Diagnostico.nota("APP CAMERA chamando quall_host porta=\(EmissorDeCamera.porta)"
                    + " tentativa=\(tentativa)")

                let inicioDaTentativa = CFAbsoluteTimeGetCurrent()
                let conhecidos = Compartilhado.lerPares()
                let candidato = Nucleo()
                if conselhoEraDaPorta {
                    // O `bind` falha em milissegundos: uma chamada ainda no ar depois de 1 s já
                    // tem a porta, e o aviso da porta presa deixou de ser verdade.
                    conselhoEraDaPorta = false
                    let t = tentativa
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.geracaoAtual() == minha, self.tentativaNoAr == t,
                              self.conselhoEhDaPortaPresa else { return }
                        self.conselho = ""
                        self.conselhoEhDaPortaPresa = false
                    }
                }
                let cancelador = self.armarCancelador(minha)
                self.tentativaNoAr = tentativa
                let subiu = candidato.hospedar(
                    pin: pinAgora, porta: EmissorDeCamera.porta,
                    deviceId: id, nome: nome,
                    tipo: QUALL_TRACK_KIND_CAMERA,
                    // O rótulo nomeia a **origem escolhida**, e é o que o receptor mostra. Com uma
                    // origem por sessão, é ele que responde "o que estou recebendo deste
                    // aparelho?" sem a pessoa precisar deduzir da imagem.
                    rotulo: rotuloDaTrack,
                    paresConhecidos: conhecidos,
                    prazoMs: EmissorDeCamera.prazoPorTentativa,
                    // **Sempre na oferta**, com o botão ligado ou não (R5 fase 2, §4.2): não há
                    // renegociação, e o botão pode ligar no meio. Desligado, nenhum pacote sai.
                    rotuloDoMicrofone: rotuloDoMicrofone,
                    cancelador: cancelador)
                self.tentativaNoAr = 0
                self.desarmarCancelador(cancelador)

                // Antes de qualquer decisão: a geração pode ter trocado enquanto a chamada
                // bloqueava, e nesse caso o erro que ela devolveu é o **nosso** cancelamento.
                guard self.geracaoAtual() == minha else {
                    candidato.encerrar()
                    // A linha que o passo de bancada do fechar-e-reabrir espera (§8.8.1).
                    Diagnostico.nota(String(format: "APP CAMERA espera cancelada (a tela saiu): a tentativa"
                        + " durou %.0f ms", (CFAbsoluteTimeGetCurrent() - inicioDaTentativa) * 1000)
                        + " status=\(candidato.statusDaEspera.rawValue) subiu=\(subiu); a porta \(EmissorDeCamera.porta) está solta")
                    return
                }

                guard subiu else {
                    let erro = candidato.ultimoMotivo
                    let gastou = CFAbsoluteTimeGetCurrent() - inicioDaTentativa
                    let renovarPin = RenovacaoDoPin.exigida(apos: candidato.statusDaEspera)
                    if renovarPin {
                        guard let novo = RenovacaoDoPin.novo(diferenteDe: pinAgora, sortear: Nucleo.sortearPin) else {
                            naPrincipal {
                                guard self.geracaoAtual() == minha else { return }
                                self.anunciante.parar()
                                self.fase = .falhou(tr("Não foi possível sortear o PIN da sessão."))
                            }
                            return
                        }
                        pinAgora = novo
                        naPrincipal {
                            guard self.geracaoAtual() == minha else { return }
                            self.pin = novo
                        }
                    }
                    // **A porta ainda presa pela tela anterior**, dentro da tolerância: de novo em
                    // 200 ms, sem conselho e sem contar. É a soltura em andamento, não um erro.
                    let desdeLivre = CFAbsoluteTimeGetCurrent() - portaLivreDesde
                    if SolturaDaPorta.repetirCalado(erro: erro, desdeOComeco: desdeLivre) {
                        Diagnostico.nota("APP CAMERA porta \(EmissorDeCamera.porta) ainda presa"
                            + String(format: " (%.0f ms de soltura)", desdeLivre * 1000)
                            + "; de novo em 200 ms, sem aviso — erro=\(SanitizacaoDoLog.causaExterna(erro))")
                        let ate = Date().addingTimeInterval(0.2)
                        while self.geracaoAtual() == minha && Date() < ate {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        continue
                    }
                    Diagnostico.nota("APP CAMERA quall_host tentativa=\(tentativa) sem sessão"
                        + String(format: " em %.1f s", gastou) + " status=\(candidato.statusDaEspera.rawValue) erro=\(SanitizacaoDoLog.causaExterna(erro))")

                    // Prazo estourado é o caso **normal** de quem espera: ninguém conectou ainda.
                    // Qualquer outro motivo a pessoa precisa ler — em especial o do ICE, que é a
                    // permissão de Rede Local negada, e que ela conserta sozinha.
                    if erro != EmissorDeCamera.prazoSemNinguem { tentativasQueContam += 1 }
                    if renovarPin || (!erro.hasPrefix("tempo esgotado:") && !erro.isEmpty) {
                        let daPorta = SolturaDaPorta.ehPortaOcupada(erro)
                        conselhoEraDaPorta = daPorta
                        conselhoVigente = renovarPin
                            ? tr("Alguém tentou entrar e o pareamento não fechou. Por segurança, o PIN mudou.")
                            : (daPorta ? EmissorDeCamera.textoDaPortaPresa : Nucleo.conselho(para: erro))
                        ultimoSinalDeVida = CFAbsoluteTimeGetCurrent()
                        let texto = conselhoVigente
                        let desparear = EstadoDeParConhecido.ehParDesconhecido(erro)
                        naPrincipal {
                            guard self.geracaoAtual() == minha else { return }
                            self.conselho = texto
                            self.conselhoEhDaPortaPresa = daPorta
                            if desparear { self.ofereceDesparear = true }
                        }
                    }

                    // Piso de tempo entre tentativas, pelo mesmo motivo da appex: uma falha
                    // instantânea em laço vira processador queimado e log inundado.
                    if gastou >= Double(EmissorDeCamera.prazoPorTentativa) / 1000 * 0.8 {
                        recuo = 0
                    } else {
                        recuo = min(5, recuo <= 0 ? 0.5 : recuo * 2)
                        let ate = Date().addingTimeInterval(recuo)
                        while self.geracaoAtual() == minha && Date() < ate {
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                    }
                    continue
                }

                // Pareamento fechado: guardar para que o PIN seja pedido **uma vez por par de
                // aparelhos**, e não por sessão, que é a promessa do fluxo. O arquivo é o mesmo
                // que a appex escreve — de propósito: o pareamento é chaveado só pelo `DeviceId`,
                // então quem pareou pela tela retoma pela câmera sem digitar nada (dívida 23).
                //
                // A fusão lê **agora**, não o `conhecidos` de vinte segundos atrás, e sob
                // coordenação: são dois processos no mesmo arquivo, e uma atualização perdida
                // deixa os dois lados com segredos diferentes para a mesma chave — que é o beco
                // sem saída da dívida 22.
                Compartilhado.atualizarPares { agora in
                    candidato.paresParaGuardar(somandoA: agora)
                }

                let quem = candidato.nomeDoPar
                self.travaDoEnvio.lock()
                // **A geração de novo, sob a trava do envio.** O Parar pode ter passado entre o
                // `guard` depois do `quall_host` e aqui: ele baixa `enviando` e solta o dono sob
                // esta mesma trava, e ligar tudo de volta depois dele deixaria uma sessão viva
                // que ninguém desmonta (no modo próprio, o laço já teria saído).
                guard self.geracaoAtual() == minha else {
                    self.travaDoEnvio.unlock()
                    candidato.encerrar()
                    return
                }
                self.nucleo = candidato
                self.ultimoEncodePts = -1
                self.microfoneParaOpus = nil
                self.microfoneSemEncoder = false
                self.enviando = true
                self.travaDoEnvio.unlock()
                // A transmissão se pendura no dono: daqui em diante os quadros da câmera vêm para
                // o encoder. A câmera não é tocada — ela já estava rodando para a prévia.
                self.dono.assinar(self)
                Diagnostico.nota("APP CAMERA sessão de pé tentativas=\(tentativa)"
                    + " porta=\(candidato.porta)"
                    + " microfone=\(candidato.temMicrofone ? "na oferta" : "FORA da oferta")"
                    + (pendurado ? " — transmissão pendurada no dono" : ""))
                naPrincipal {
                    guard self.geracaoAtual() == minha else { return }
                    self.par = quem
                    self.conselho = ""
                    self.conselhoEhDaPortaPresa = false
                    self.fase = .transmitindo
                }
                guard pendurado else { return }

                // --- modo pendurado: vigiar a queda, soltar e voltar a esperar -------------------
                let subiuEm = CFAbsoluteTimeGetCurrent()
                let motivo = self.vigiarSessao(candidato, minha: minha)
                // A tela deixa de dizer "enviando" **antes** do desmonte, que pode demorar (dívida
                // 19): a transmissão já acabou, e a porta volta quando ele terminar.
                if self.geracaoAtual() == minha {
                    naPrincipal {
                        guard self.geracaoAtual() == minha else { return }
                        self.par = ""
                        self.reabrindo = true
                        self.fase = .esperando
                    }
                }
                self.soltarSessao(candidato, motivo: motivo)
                portaLivreDesde = CFAbsoluteTimeGetCurrent()
                guard self.geracaoAtual() == minha else { return }
                let durou = CFAbsoluteTimeGetCurrent() - subiuEm
                if durou < EmissorDeCamera.sessaoCurta {
                    tentativasQueContam += 1
                } else {
                    tentativasQueContam = 0
                }
                tentativa = 0
                recuo = 0
                naPrincipal {
                    guard self.geracaoAtual() == minha else { return }
                    self.reabrindo = false
                }
            }
        }
        thread.stackSize = 512 * 1024
        thread.name = "quall.camera.host"
        thread.start()
    }

    /// **A sessão de pé, no modo pendurado**: vigia a queda e, desde o R9b, bombeia o controle remoto
    /// da câmera (`docs/controle-remoto-da-camera.md` §12, filmador 3) com o canal de mensagens dela.
    /// Devolve o motivo do fim. Só pelo laço de hospedagem, a única thread que lê esta sessão.
    ///
    /// - A bombeada espera até 100 ms (a mesma cadência do `proximoEvento(100)` de antes), e o
    ///   `next_event` vem logo depois com prazo zero — o desenho do teleprompter.
    /// - Com pedido na fila, quem consome é a `fila` do dono (`pedidosChegaram`): um consumidor só.
    /// - A cada 250 ms, o estado do núcleo: "Controlado por" e se há receptor ouvindo (o lido a 4 Hz).
    /// - Em **toda** saída — a queda, o fim da tela, a geração trocada —, uma bombeada final com prazo
    ///   zero, o `forget` (a vaga do receptor volta na hora) e o handle liberado.
    /// - Sem o handle de mensagens (ou com a bombeada quebrada), o laço de sempre: só a queda.
    private func vigiarSessao(_ candidato: Nucleo, minha: Int) -> String {
        let controles = dono.controles
        let filmador = controles.remoto
        var mensagens = filmador != nil ? candidato.abrirMensagens() : nil
        if filmador != nil, mensagens == nil {
            Diagnostico.falha("APP CAMERA remoto: o núcleo não deu o handle de mensagens; sem controle remoto nesta sessão")
        }
        defer {
            if let f = filmador, let m = mensagens {
                let (_, fim) = f.bombear(m, prazoMs: 0)
                if fim & QUALL_CAMERA_HOST_CHANGE_REQUEST.rawValue != 0 { controles.pedidosChegaram() }
                f.esquecer(m)
                quall_messages_free(m)
            }
            controles.semReceptor()
        }
        var ultimoEstado = 0.0
        while self.geracaoAtual() == minha {
            guard let f = filmador, let m = mensagens else {
                let ev = candidato.proximoEvento(prazoMs: 100)
                if ev == QUALL_SESSION_EVENT_DISCONNECTED { return "o receptor saiu" }
                if ev == QUALL_SESSION_EVENT_FAILED { return "o transporte falhou" }
                continue
            }
            let (st, mudou) = f.bombear(m, prazoMs: 100)
            if mudou & QUALL_CAMERA_HOST_CHANGE_REQUEST.rawValue != 0 { controles.pedidosChegaram() }
            let agora = CFAbsoluteTimeGetCurrent()
            if mudou & QUALL_CAMERA_HOST_CHANGE_LISTENERS.rawValue != 0 || agora - ultimoEstado >= 0.25 {
                ultimoEstado = agora
                if let e = f.estado() {
                    controles.estadoDoNucleo(controladoPor: FilmadorRemoto.controladoPor(e),
                                             ouvintes: FilmadorRemoto.temReceptores(e))
                }
            }
            if st != QUALL_STATUS_OK, st != QUALL_STATUS_CLOSED {
                // Só o cadeado envenenado do núcleo chega aqui: girar nisso seria queimar CPU. A
                // sessão segue, sem controle remoto.
                Diagnostico.falha("APP CAMERA remoto: a bombeada falhou (status \(st.rawValue)); sem controle remoto nesta sessão")
                f.esquecer(m)
                quall_messages_free(m)
                mensagens = nil
                controles.semReceptor()
                continue
            }
            let ev = candidato.proximoEvento(prazoMs: 0)
            if ev == QUALL_SESSION_EVENT_DISCONNECTED { return "o receptor saiu" }
            if ev == QUALL_SESSION_EVENT_FAILED { return "o transporte falhou" }
            if st == QUALL_STATUS_CLOSED { return "o receptor saiu" }
        }
        return "a tela saiu"
    }

    /// A queda (ou o fim da tela) no modo pendurado: solta do dono, tira a sessão e o encoder do
    /// caminho do quadro, e os desmonta **aqui mesmo, antes de hospedar de novo**.
    ///
    /// Não numa thread à parte, e isso foi conferido no núcleo: a `QuallSession` guarda o servidor
    /// de sinalização (`_servidor`, `quall-ffi/src/lib.rs`, `empacotar(pronto, Some(servidor))`)
    /// pela vida dela, então a porta só fica livre depois de `quall_session_close`. Hospedar antes
    /// seria `Address already in use` em laço. O preço é a dívida 19: com o par sumido sem `Bye`,
    /// o desmonte pode demorar, e a tela fica em "saindo" até ele acabar — dito no diagnóstico.
    ///
    /// Chamado **só** pelo laço de hospedagem, que é o único a ler a sessão nesse modo.
    private func soltarSessao(_ candidato: Nucleo, motivo: String) {
        dono.soltar(self)
        travaDoEnvio.lock()
        let eraEla = nucleo === candidato
        if eraEla { enviando = false; nucleo = nil }
        let c = eraEla ? codificador : nil
        let mic = eraEla ? microfoneParaOpus : nil
        if eraEla { codificador = nil; entradaAtual = .zero; microfoneParaOpus = nil; microfoneSemEncoder = false }
        travaDoEnvio.unlock()
        Diagnostico.nota("APP CAMERA transmissão solta do dono (\(motivo))"
            + " enviados=\(candidato.enviados) recusados=\(candidato.recusados)"
            + " saida=\(c?.dimensaoDaSaida ?? "?")"
            + " formato_da_camera=\(dono.formatoRecebido)"
            + " desc_fila=\(c?.descartadosPorFila ?? 0)"
            + " desc_encoder=\(c?.descartadosPeloEncoder ?? 0)"
            + " cresc_buffer=\(c?.crescimentosDoBuffer ?? 0)"
            + " nucleo={\(candidato.estatisticasDaTrack)}")
        Diagnostico.nota("APP CAMERA \(c?.remendoDeSPS.resumo() ?? "sem codificador")")
        Diagnostico.nota("APP MICROFONE sessão solta: \(mic?.resumo() ?? "nenhum buffer nesta sessão")"
            + " nucleo_enviados=\(candidato.audioEnviados) nucleo_recusados=\(candidato.audioRecusados)"
            + " nucleo={\(candidato.estatisticasDoMicrofone)}")
        let inicio = CFAbsoluteTimeGetCurrent()
        // A ordem é a obrigatória: drenar o encoder **antes** de soltar a track.
        c?.encerrar()
        candidato.encerrar()
        let gastou = CFAbsoluteTimeGetCurrent() - inicio
        Diagnostico.nota(String(format: "APP CAMERA sessão desmontada em %.0f ms", gastou * 1000)
            + (gastou > 2 ? " (dívida 19: Link::close sem prazo)" : ""))
        if gastou > 2 {
            // O mesmo texto do desmonte do modo próprio: é o que o `provar.sh` reprova.
            Diagnostico.falha(String(format:
                "APP CAMERA o desmonte levou %.1f s (dívida 19: Link::close sem prazo)", gastou))
        }
    }


    // --- supervisão de 1 Hz ---------------------------------------------------------------------

    /// Uma tarefa só, e ela **não** lê contador nenhum do núcleo.
    ///
    /// `quall_track_stats_json` segura a mesma trava do `send_frame`; lê-la periodicamente põe
    /// relatório e quadro disputando a trava, e o sintoma é quadro perdido. A appex aprendeu isso
    /// e publica os contadores numa linha só, no desmonte. Aqui vale igual.
    ///
    /// A metade da câmera deste relato (a prévia, o formato vigente) mudou para o dono
    /// (`DonoDaCaptura.supervisionar`), que roda enquanto a câmera estiver aberta — com ou sem
    /// transmissão. Aqui ficam o encoder e o bitrate.
    private func subirSupervisao() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.ajustarAoAparelho() }
        t.resume()
        relogio = t
    }

    /// De quantas voltas do supervisor sai um relato. 1 Hz × 10 = a cada dez segundos.
    private var voltasAteRelatar = 0

    /// Quadros que **entraram** da câmera e que **saíram** do encoder, para separar os dois.
    ///
    /// Em 07/09/2026 o iPhone 17e capturou 4K a 60, não descartou nada em lugar nenhum
    /// (`fila=0 encoder=0`) e entregou **exatamente 30,0 fps** ao receptor. Sem estes dois
    /// contadores não há como distinguir "a câmera entrega 30" de "a câmera entrega 60 e o
    /// encoder emite 30", e as duas exigem consertos em lugares opostos. `&+` porque contador de
    /// instrumento satura, não derruba processo. Os que entraram são contados pelo dono.
    private let travaDosContadores = NSLock()
    private var _sairam: UInt64 = 0
    private var _entraramAntes: UInt64 = 0
    private var _sairamAntes: UInt64 = 0
    /// Quadros que o freio de taxa segurou. Ver `quadroDaCaptura`.
    private var _freados: UInt64 = 0

    /// Recuo sob calor ou modo de baixo consumo, igual ao da appex e pelo mesmo motivo: o A10 de
    /// 2016 encodando câmera por meia hora chega lá.
    ///
    /// **Escrito, não exercitado**: nenhuma corrida chegou a `.serious`.
    private func ajustarAoAparelho() {
        let estado = ProcessInfo.processInfo.thermalState
        let economia = ProcessInfo.processInfo.isLowPowerModeEnabled

        // O teto da rede pelo calor, com histerese (§8.12.1): reduz na hora em `.serious`, volta ao
        // cardápio depois de 60 s seguidos abaixo. O encoder é refeito no próximo quadro.
        if calorDaRede.observar(termico: estado.rawValue, agora: ProcessInfo.processInfo.systemUptime) {
            let r = calorDaRede.reduzida
            travaDoEnvio.lock(); redeReduzida = r; travaDoEnvio.unlock()
            Diagnostico.nota("APP CAMERA calor: a rede \(r ? "vai a 720p" : "volta ao cardápio")"
                + " (térmico=\(estado.rawValue) \(PoliticaDeCalor.nome(estado.rawValue))"
                + "\(r ? "" : ", \(Int(RedeReduzidaPeloCalor.esfriarPor)) s abaixo de serious"))")
        }

        // A complexidade do Opus segue o calor da rede (§8.12.17): quente, 4; frio, a padrão (10). Depois da
        // leitura do calor desta volta (e não da anterior).
        travaDoEnvio.lock(); let micDoCalor = microfoneParaOpus; travaDoEnvio.unlock()
        micDoCalor?.pedirComplexidade(quente: calorDaRede.reduzida)

        voltasAteRelatar -= 1
        if voltasAteRelatar <= 0 {
            voltasAteRelatar = 10
            // **Os contadores de descarte entram no relato periódico.** Em 07/09/2026 o iPhone 15
            // capturou 4K a 60, a rede não perdeu um pacote, e chegaram **26 fps** ao receptor. A
            // pergunta "quem come os outros 34" não tinha testemunha nenhuma até esta linha.
            let entraram = dono.quadrosQueEntraram
            travaDosContadores.lock()
            let dEnt = entraram &- _entraramAntes
            let dSai = _sairam &- _sairamAntes
            _entraramAntes = entraram
            _sairamAntes = _sairam
            let freados = _freados
            travaDosContadores.unlock()
            // Dez segundos entre relatos: a taxa é a diferença dividida por dez.
            Diagnostico.nota("APP CAMERA taxas: camera=\(String(format: "%.1f", Double(dEnt)/10))"
                + " encoder=\(String(format: "%.1f", Double(dSai)/10)) fps"
                + " · freados=\(freados)")
            travaDoEnvio.lock()
            let c = codificador
            travaDoEnvio.unlock()
            Diagnostico.nota("APP CAMERA descartes: fila=\(c?.descartadosPorFila ?? 0)"
                + " encoder=\(c?.descartadosPeloEncoder ?? 0)"
                + " cresc_buffer=\(c?.crescimentosDoBuffer ?? 0)"
                + " saida=\(c?.dimensaoDaSaida ?? "?")")
            travaDoEnvio.lock()
            let mic = microfoneParaOpus
            let temSessao = nucleo != nil
            travaDoEnvio.unlock()
            if temSessao {
                Diagnostico.nota("APP MICROFONE envio: \(mic?.resumo() ?? "nenhum buffer (botão desligado?)")")
            }
            travaDoDescarte.lock()
            let dv = descarteDoVideo, ds = descarteDoSom
            descarteDoVideo.zerarContadores(); descarteDoSom.zerarContadores()
            let (ie, isai, ev) = (_idadeMaxNaEntrada, _idadeMaxNaSaida, _envioMax)
            let (isom, tsom) = (_idadeMaxDoSom, _somMax)
            let somPorFila = _somDescartadoPorFila
            _somDescartadoPorFila = 0
            let (velhosNaFila, esperaNaFila, pendenteMax) = (_velhosNaFila, _esperaMaximaNaFilaMs, _pendenteMaximoVistoMs)
            let perdidoMs = Double(_somPerdidoUs) / 1000
            _velhosNaFila = 0; _esperaMaximaNaFilaMs = 0; _pendenteMaximoVistoMs = 0; _somPerdidoUs = 0
            _idadeMaxNaEntrada = 0; _idadeMaxNaSaida = 0; _envioMax = 0; _idadeMaxDoSom = 0; _somMax = 0
            travaDoDescarte.unlock()
            travaDoEnvio.lock()
            let reduzida = redeReduzida
            travaDoEnvio.unlock()
            if temSessao {
                Diagnostico.nota("APP CAMERA idade: video"
                    + String(format: " entrada_max=%.0f ms saida_max=%.0f ms envio_max=%.0f ms",
                             ie * 1000, isai * 1000, ev * 1000)
                    + " velhos=\(dv.velhos) passaram_velhos=\(dv.passaramVelhos) incoerente=\(dv.relogioIncoerente)"
                    + (dv.desistiu ? " DESISTIU" : "")
                    + String(format: " piso_max=%.0f ms", dv.pisoMaximo * 1000)
                    + String(format: " · som entrada_max=%.0f ms opus_e_envio_max=%.0f ms", isom * 1000, tsom * 1000)
                    + " velhos=\(ds.velhos) passaram_velhos=\(ds.passaramVelhos) incoerente=\(ds.relogioIncoerente)"
                    + (ds.desistiu ? " DESISTIU" : "")
                    + String(format: " piso_max=%.0f ms", ds.pisoMaximo * 1000)
                    + " descartado_por_fila=\(somPorFila) velhos_na_fila=\(velhosNaFila)"
                    + String(format: " espera_na_fila_max=%.0f ms pendente_max=%.0f ms som_perdido=%.0f ms (%.1f%%)",
                             esperaNaFila, pendenteMax, perdidoMs, perdidoMs / 100)
                    + " · termico=\(estado.rawValue) rede=\(reduzida ? "720p(calor)" : "cardapio")")
            }
            // O sinal dos degraus: o som perdido conta os dois descartes (a fila e o piso).
            let perdido = perdidoMs + Double(ds.velhos) * 21.3
            let ruim = temSessao && DegrausDaTransmissao.ruim(esperaNaFila: esperaNaFila / 1000, idadeNaEntrada: isom,
                                                              somPerdido: perdido / 1000)
            let resumo = String(format: "espera=%.0f ms entrada=%.0f ms perdido=%.0f ms", esperaNaFila, isom * 1000, perdido)
                + " incoerente=\(ds.relogioIncoerente) quente=\(reduzida)"
            naPrincipal { [weak self] in self?.aoAvaliarSom?(ruim, temSessao, reduzida, resumo) }
        }

        travaDoEnvio.lock()
        guard let c = codificador else { travaDoEnvio.unlock(); return }
        // **A geometria vem do codificador em uso, e não de um literal.** Até 07/09/2026 esta
        // linha era `bitrateBase(largura: 1920, altura: 1080, fps: 30)` cravado, e um fluxo
        // 1280x720 passava a pedir 6,75 Mbps um segundo depois do primeiro quadro — 2,25 vezes o
        // que a regra do produto reserva para aquela geometria (a corrida de sete emissores de
        // 07/09 é a testemunha de campo).
        let base = EmissorDeCamera.bitrateBase(largura: Int(c.largura), altura: Int(c.altura),
                                              fps: Int32(PoliticaDeCalor.fpsDaRede(cardapio: dono.quadrosDoEspelhamento,
                                                                                   reduzida: reduzidaNoEncoder)))
        let alvo = PoliticaDeCalor.taxaDaRede(base: base, termico: estado.rawValue, economia: economia)
        let precisa = alvo != bitrateAtual
        if precisa { bitrateAtual = alvo }
        travaDoEnvio.unlock()
        guard precisa else { return }
        c.ajustarBitrate(alvo)
        Diagnostico.nota("APP CAMERA bitrate ajustado para \(alvo) (térmico=\(estado.rawValue)"
            + " baixo_consumo=\(economia))")
    }

    /// Menor que o da tela porque a câmera não tem texto fino nas bordas, que é o que faz a tela
    /// custar caro.
    ///
    /// **Era `3_000_000` cravado até 02/09/2026**, e a razão "menor que o da tela" não sobrevive
    /// a um literal: quando o teto de resolução subiu para 1080p em 01/09, a tela ganhou pixels e
    /// este número não. Agora ele é a razão que sempre foi — **três quartos** do teto de tela para
    /// a mesma geometria, que a 720p dá exatamente os 3 Mbps de sempre — e acompanha o quadro.
    ///
    /// **O alvo entra aqui desde 08/09/2026.** Sem ele, `tetoDeTaxa` grampeava em 1080p30 por
    /// dentro e este encoder pedia 6,68 Mbps para um quadro 4K a 60 — ver a nota da função em
    /// `Comum/Compartilhado.swift`.
    static func bitrateBase(largura: Int, altura: Int, fps: Int32) -> Int {
        PedidoDeEspelhamento.tetoDeTaxa(maior: max(largura, altura), menor: min(largura, altura),
                                        fps: fps, alvoMaxFs: Resolucao.escolhida.maxFs)
            * 3 / 4
    }
}


extension EmissorDeCamera: AssinanteDaCaptura {
    /// A retomada depois de uma interrupção: um quadro chave, e o freio zerado.
    func capturaRetomada() {
        travaDoEnvio.lock()
        ultimoEncodePts = -1
        let n = nucleo
        travaDoEnvio.unlock()
        n?.exigirIdr()
    }

    /// O microfone, entregue na fila do áudio do dono e consumido na `filaDoOpus`: reamostra, carimba e codifica (`MicrofoneParaOpus`) e
    /// manda pela track de microfone. Sem sessão de pé, o buffer é descartado — o botão ligado sem
    /// receptor não acumula nada.
    func audioDaCaptura(_ amostra: CMSampleBuffer) {
        travaDoEnvio.lock()
        guard enviando, let n = nucleo, n.temMicrofone else { travaDoEnvio.unlock(); return }
        var m = microfoneParaOpus
        if m == nil && !microfoneSemEncoder {
            m = MicrofoneParaOpus(tom: BancadaDoMicrofone.opcoes.tom)
            microfoneParaOpus = m
            microfoneSemEncoder = m == nil
        }
        travaDoEnvio.unlock()
        guard let m else { return }
        let us = Int64((EmissorDeCamera.duracaoMs(amostra) * 1000).rounded())
        travaDoDescarte.lock()
        let cabe = _pendenteNoOpusUs == 0
            || Double(_pendenteNoOpusUs + us) <= EmissorDeCamera.pendenteMaximoMs * 1000
        if cabe {
            _pendenteNoOpusUs += us
            _pendenteMaximoVistoMs = max(_pendenteMaximoVistoMs, Double(_pendenteNoOpusUs) / 1000)
        } else {
            _somDescartadoPorFila &+= 1
            _somPerdidoUs += us
        }
        travaDoDescarte.unlock()
        guard cabe else { return }
        let entrouEm = CFAbsoluteTimeGetCurrent()
        filaDoOpus.async { [weak self] in
            guard let self else { return }
            let esperaMs = (CFAbsoluteTimeGetCurrent() - entrouEm) * 1000
            let velho = esperaMs > EmissorDeCamera.esperaMaximaNaFilaMs
            // A idade também do que vai ser descartado: senão o `entrada_max` só veria quem passou
            // (a revisão de 27/09 viu o critério ficar cego pelo próprio descarte).
            let idade = velho ? self.dono.idadeDoQuadro(CMSampleBufferGetPresentationTimeStamp(amostra)) : nil
            self.travaDoDescarte.lock()
            self._pendenteNoOpusUs -= us
            assert(self._pendenteNoOpusUs >= 0, "a conta da fila do Opus ficou negativa")
            self._esperaMaximaNaFilaMs = max(self._esperaMaximaNaFilaMs, esperaMs)
            if velho {
                self._velhosNaFila &+= 1
                self._somPerdidoUs += us
                if let idade { self._idadeMaxDoSom = max(self._idadeMaxDoSom, idade) }
            }
            self.travaDoDescarte.unlock()
            // Esperou demais nesta fila: não é codificado (não se gasta Opus com o que chegaria atrasado).
            guard !velho else { return }
            // A sessão trocou com este buffer na fila: não gasta Opus com um núcleo que já foi.
            self.travaDoEnvio.lock(); let viva = self.nucleo === n; self.travaDoEnvio.unlock()
            guard viva else { return }
            let cpu = MedidorDeCpu.agora()
            self.opus(amostra, m: m, n: n)
            MedidorDeCpu.somar("opus", desde: cpu)
        }
    }

    /// A duração de um buffer de som em milissegundos (as amostras pela taxa do formato); 21,3 ms quando
    /// o formato não diz.
    static func duracaoMs(_ amostra: CMSampleBuffer) -> Double {
        let n = Double(CMSampleBufferGetNumSamples(amostra))
        guard let f = CMSampleBufferGetFormatDescription(amostra),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee,
              asbd.mSampleRate > 0, n > 0 else { return 1024.0 / 48 }
        return n / asbd.mSampleRate * 1000
    }

    /// Na `filaDoOpus`, em ordem (o `MicrofoneParaOpus` é usado só aqui).
    private func opus(_ amostra: CMSampleBuffer, m: MicrofoneParaOpus, n: Nucleo) {
        // **O som velho não sai** (§8.12.1): o buffer que chega aqui atrasado além do teto é pulado
        // (o `MicrofoneParaOpus` vê a descontinuidade e reancora para a frente), e uma fila de
        // segundos se escoa em vez de virar atraso. O PTS já está no relógio da câmera (o dono
        // converte), o mesmo da idade dos quadros.
        let idade = dono.idadeDoQuadro(CMSampleBufferGetPresentationTimeStamp(amostra))
        travaDoDescarte.lock()
        if let idade { _idadeMaxDoSom = max(_idadeMaxDoSom, idade) }
        let entra = descarteDoSom.entrada(idade: idade)
        travaDoDescarte.unlock()
        guard entra else { return }
        let antes = ProcessInfo.processInfo.systemUptime
        m.consumir(amostra) { pacote, carimbo in
            n.enviarAudio(pacote, timestampUs: carimbo)
        }
        let gasto = ProcessInfo.processInfo.systemUptime - antes
        travaDoDescarte.lock(); _somMax = max(_somMax, gasto); travaDoDescarte.unlock()
    }

    func quadroDaCaptura(_ sampleBuffer: CMSampleBuffer, imagem: CVPixelBuffer) {
        travaDoEnvio.lock()
        let ativo = enviando
        let n = nucleo
        travaDoEnvio.unlock()
        guard ativo, let nucleo = n else { return }

        // Freio de taxa, no relógio de apresentação e não num contador — uma pausa da captura não
        // pode acumular dívida de quadros. É a rede de segurança para o caso de um formato ativo
        // mudar por baixo, e custa duas comparações.
        //
        // **O 30 aqui era literal, e virou o teto de verdade no dia em que a taxa virou escolha.**
        // Medido no iPhone 17e em 07/09/2026, com 4K a 60 pedidos e concedidos pelo formato:
        // `camera=60,0 encoder=30,0 fps`, com `fila=0` e `encoder=0` — nada descartado em lugar
        // nenhum, e metade dos quadros sumindo. Era esta linha, e ela voltava calada.
        //
        // O contador existe pela mesma razão: um `return` sem testemunha é indistinguível de um
        // caminho que não roda, e essa confusão custou o dia inteiro neste arquivo.
        // Quente, a rede anda a 15 fps (§8.12.8): o freio é o mesmo, com o alvo menor.
        travaDoEnvio.lock()
        let quenteNaRede = redeReduzida
        travaDoEnvio.unlock()
        let alvoDeFps = PoliticaDeCalor.fpsDaRede(cardapio: dono.quadrosDoEspelhamento, reduzida: quenteNaRede)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // **O quadro velho não entra** (§8.12.1): pulado antes do encoder, nada se quebra.
        let idade = dono.idadeDoQuadro(pts)
        travaDoDescarte.lock()
        if let idade { _idadeMaxNaEntrada = max(_idadeMaxNaEntrada, idade) }
        let entra = descarteDoVideo.entrada(idade: idade)
        travaDoDescarte.unlock()
        guard entra else { return }
        let segundos = CMTimeGetSeconds(pts)
        travaDoEnvio.lock()
        let cedoDemais = segundos.isFinite && ultimoEncodePts >= 0
            && segundos - ultimoEncodePts < (1.0 / Double(alvoDeFps) - 0.002)
        if !cedoDemais && segundos.isFinite { ultimoEncodePts = segundos }
        travaDoEnvio.unlock()
        if cedoDemais {
            travaDosContadores.lock(); _freados = _freados &+ 1; travaDosContadores.unlock()
            return
        }

        guard let codificador = encoderPara(imagem, nucleo: nucleo) else { return }
        nucleo.recolherPedidoDeIdr()
        codificador.encodar(imagem, pts: pts,
                            duracao: CMTime(value: 1, timescale: CMTimeScale(alvoDeFps)),
                            forcarIDR: nucleo.precisaDeIdr)
    }

    /// Mesmo mecanismo do lado da tela: o encoder segue a dimensão da entrada, e girar o aparelho
    /// o reconstrói em vez de esticar a imagem.
    private func encoderPara(_ imagem: CVPixelBuffer, nucleo: Nucleo) -> CodificadorH264? {
        let entrada = CGSize(width: CVPixelBufferGetWidth(imagem),
                             height: CVPixelBufferGetHeight(imagem))
        // O teto do encoder é o do cardápio, e não mais um literal. Ver `Comum/Resolucao.swift`.
        // Com o aparelho quente, 720p (§8.12.1).
        travaDoEnvio.lock()
        let reduzida = redeReduzida
        let teto = PoliticaDeCalor.tetoDaRede(cardapio: Resolucao.escolhida.teto, reduzida: reduzida)
        let (l, a) = CodificadorH264.destino(largura: Int(entrada.width),
                                             altura: Int(entrada.height),
                                             tetoMaior: teto.maior, tetoMenor: teto.menor)
        let fpsDaRede = PoliticaDeCalor.fpsDaRede(cardapio: dono.quadrosDoEspelhamento, reduzida: reduzida)
        if let atual = codificador, entrada == entradaAtual, (l, a) == saidaAtual, fpsDaRede == fpsDoEncoder {
            reduzidaNoEncoder = reduzida
            travaDoEnvio.unlock()
            return atual
        }
        let anterior = codificador
        codificador = nil
        geracaoDoEncoder += 1
        let geracao = geracaoDoEncoder
        travaDoEnvio.unlock()
        // Fora da fila da câmera: ver `geracaoDoEncoder`.
        if let anterior {
            DispatchQueue.global(qos: .userInitiated).async { anterior.encerrar() }
        }

        // A taxa do tamanho **novo** e do calor de agora: antes o encoder refeito herdava a do
        // anterior até o laço de 1 Hz corrigir (num giro dava no mesmo; na troca de tamanho, não).
        let bitrate = PoliticaDeCalor.taxaDaRede(
            base: EmissorDeCamera.bitrateBase(largura: Int(l), altura: Int(a), fps: Int32(fpsDaRede)),
            termico: ProcessInfo.processInfo.thermalState.rawValue,
            economia: ProcessInfo.processInfo.isLowPowerModeEnabled)
        do {
            // Preset de câmera do contrato: movimento contínuo e ruído, GOP mais longo.
            let novo = try CodificadorH264(largura: l, altura: a, fps: Int32(fpsDaRede),
                                           bitrate: bitrate, perfil: .camera, tetoEmVoo: 2)
            novo.aoSair = { [weak nucleo, weak self] annexb, pts, chave in
                if let eu = self {
                    eu.travaDoEnvio.lock()
                    let vigente = eu.geracaoDoEncoder == geracao
                    eu.travaDoEnvio.unlock()
                    // Um encoder já trocado, esvaziando fora da fila: o que sobra dele não vai.
                    guard vigente else { return }
                    eu.travaDosContadores.lock()
                    eu._sairam = eu._sairam &+ 1
                    eu.travaDosContadores.unlock()
                }
                guard let nucleo else { return }
                // A idade na saída do encoder: **só medida** (descartar aqui vira tempestade de IDR,
                // revisão de 27/09, B2).
                let idade = self?.dono.idadeDoQuadro(pts)
                let antes = ProcessInfo.processInfo.systemUptime
                let cpu = MedidorDeCpu.agora()
                // Ver `Carimbo`: `UInt64(NaN)` derruba o processo, e `CMTime` inválido acontece.
                nucleo.enviar(annexb: annexb, timestampUs: Carimbo.microssegundos(de: pts),
                              idr: chave)
                if chave { nucleo.idrEntregue() }
                MedidorDeCpu.somar("rede_envio", desde: cpu)
                let gasto = ProcessInfo.processInfo.systemUptime - antes
                if let eu = self {
                    eu.travaDoDescarte.lock()
                    if let idade { eu._idadeMaxNaSaida = max(eu._idadeMaxNaSaida, idade) }
                    eu._envioMax = max(eu._envioMax, gasto)
                    eu.travaDoDescarte.unlock()
                }
            }
            travaDoEnvio.lock()
            // **A sessão pode ter ido embora enquanto o encoder nascia** (o Parar, ou a queda no
            // modo pendurado, que tira `nucleo` e `codificador` do caminho sob esta trava). Guardar
            // o encoder novo agora deixaria um VideoToolbox vivo que ninguém mais encerra.
            guard enviando, self.nucleo === nucleo else {
                travaDoEnvio.unlock()
                novo.encerrar()
                return nil
            }
            codificador = novo
            entradaAtual = entrada
            reduzidaNoEncoder = reduzida
            saidaAtual = (l, a)
            fpsDoEncoder = fpsDaRede
            bitrateAtual = bitrate
            travaDoEnvio.unlock()
            nucleo.exigirIdr()
            Diagnostico.nota("APP CAMERA encoder \(anterior == nil ? "criado" : "recriado")"
                + " entrada=\(Int(entrada.width))x\(Int(entrada.height)) saida=\(l)x\(a)"
                + " formato_da_camera=\(dono.formatoRecebido) bitrate=\(bitrate)"
                + (reduzida ? " (720p a \(fpsDaRede) fps pelo calor)" : "")
                // **O que a sessão respondeu**, e não o que pedimos. Ver `tetoVigente`.
                + " vigente=[\(novo.tetoVigente())]")
            return novo
        } catch {
            Diagnostico.falha("APP CAMERA VTCompressionSession não subiu: \(SanitizacaoDoLog.erro(error))")
            return nil
        }
    }
}
