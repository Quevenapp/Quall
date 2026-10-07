import Combine
import Foundation
import SwiftUI

/// O teleprompter como objeto de tela: dono da réplica e da sessão, e o que as duas telas desenham.
///
/// Uma instância por tela aberta, com o papel dela. **A tela só edita, bombeia e lê** — a fusão é do
/// núcleo (`docs/contrato-teleprompter.md`, "As cascas só editam, bombeiam e leem"). Nada aqui
/// decide quem vence uma edição: a tela chama o `set_*`, e o que aparece é o estado que o núcleo
/// devolve.
///
/// # O texto que chega com o editor aberto (a regra desta tela, item 3 da frente)
///
/// O contrato deixa com a tela o que fazer quando o bit `_TEXT` chega enquanto a pessoa edita
/// (§6: "o núcleo não mistura"). **A escolha aqui é avisar e deixar a pessoa escolher**, sem nunca
/// mexer no rascunho sozinho:
///
/// - o rascunho que está no editor **não é tocado** — perder o que alguém está digitando por causa
///   de uma edição do outro lado seria o pior resultado possível;
/// - o editor mostra uma faixa: *"O roteiro mudou no outro aparelho enquanto você editava"*, com
///   **Carregar o novo** (troca o rascunho pelo texto que chegou) e **Manter o meu** (fecha a faixa);
/// - se a pessoa confirmar o rascunho, ele sai com `set_text` e **vence**, porque passa a ser a edição
///   mais recente — é a regra "vale o último que mudou" que o usuário decidiu, aplicada a quem
///   confirmou por último, e não a quem começou a digitar por último.
///
/// A tela do prompter, atrás do editor, já mostra o texto novo: quem lê não fica com o roteiro
/// velho só porque alguém abriu o editor.
final class ModeloDoTeleprompter: ObservableObject {

    let papel: ReplicaDoTeleprompter.Papel
    let replica: ReplicaDoTeleprompter
    /// Os argumentos de bancada desta abertura, se houver — consumidos na criação, uma vez.
    let bancada: BancadaDoTeleprompter.Opcoes?
    private var sessao: SessaoDoTeleprompter?

    // --- o que a tela desenha ------------------------------------------------------------------

    @Published private(set) var estado = EstadoDoTeleprompter()
    @Published private(set) var texto = ""
    /// Sobe a cada texto novo: a vista do roteiro compara isto, e não 128 KiB de texto, para
    /// saber se precisa refazer o layout.
    @Published private(set) var versaoDoTexto = 0
    @Published private(set) var fase: FaseDaConexao = .parada
    /// Frase avulsa da sessão ("alguém errou o PIN", "ocupado, tentando de novo").
    @Published private(set) var aviso = ""
    @Published private(set) var pin = ""
    @Published private(set) var nomeNaDescoberta: String?
    @Published private(set) var porta: UInt16 = LinkDePareamento.portaPadrao
    /// O endereço para conectar, quando este aparelho é o controle.
    @Published private(set) var enderecoDoPrompter = ""
    /// O salto que a vista do prompter precisa fazer, entregue **fora** da publicação: a thread da
    /// sessão o põe aqui assim que funde o `_JUMP`, e o relógio de quadro da vista o consome antes
    /// de relatar a posição. Ver `CaixaDeSalto`.
    let caixaDeSalto = CaixaDeSalto()
    /// A sessão foi parada porque o app foi para o segundo plano, e volta quando ele voltar.
    private var pausadaPeloSistema = false
    /// Desde quando a sessão atual está de pé — para o "sem sinal" não piscar no primeiro instante,
    /// antes de a primeira mensagem do outro lado chegar.
    private var conectadaDesde: Date?

    // --- o editor ------------------------------------------------------------------------------

    @Published var editorAberto = false {
        didSet { if !editorAberto { textoMudouDuranteEdicao = false } }
    }
    /// O bit `_TEXT` chegou com o editor aberto. Ver o cabeçalho.
    @Published var textoMudouDuranteEdicao = false
    /// O bit `_RECORDING` chegou (§13.8): a tela que grava relê o pedido e decide. Na principal.
    var aoMudarGravacao: (() -> Void)?

    /// Chamado quando um texto chega do outro lado — só a bancada escuta.
    var aoChegarTexto: ((String) -> Void)?
    /// Chamado quando uma sessão sobe — só a bancada escuta.
    var aoConectar: (() -> Void)?

    init(papel: ReplicaDoTeleprompter.Papel, bancada: BancadaDoTeleprompter.Opcoes? = nil) {
        self.papel = papel
        self.bancada = bancada
        // O núcleo só recusa a réplica sem salvo por autor inválido (vazio ou acima de 256 bytes),
        // e o `device_id` do App Group é `ios-` + 8 caracteres. O segundo caminho existe para a
        // tela nunca ficar sem réplica; o `!` nele é sobre um autor constante e válido.
        let r = ReplicaDoTeleprompter(papel: papel, autor: Identidade.deviceId,
                                      salvo: ReplicaDoTeleprompter.lerSalvo(papel: papel))
            ?? ReplicaDoTeleprompter(papel: papel, autor: "ios-anon", salvo: nil)!
        replica = r
        // "A pergunta do texto" (§11.10): a trava liga logo depois de criar a réplica do **controle**,
        // e só aqui — este modelo de controle só nasce com a `TelaDoControle`, que tem a caixa dela.
        if papel == .controleRemoto {
            let st = r.ligarPerguntaDoTexto()
            DiarioDoTeleprompter.dizer("controle: pergunta do texto ligada (\(SessaoDoTeleprompter.nome(st)))")
        }
        texto = r.texto()
        versaoDoTexto = 1
        if let e = r.estado() { estado = e }
        DiarioDoTeleprompter.dizer("réplica de \(papel.rawValue) criada: texto \(texto.utf8.count) bytes "
            + "(resumo \(ResumoDoTexto.de(texto))), velocidade \(estado.velocidade), fonte \(estado.fonte), "
            + "espelho \(estado.espelho)")
    }

    deinit {
        sessao?.parar()
    }

    // =========================================================================================
    // A sessão
    // =========================================================================================

    /// **A porta do prompter, escolhida uma vez ao abrir a tela** (§11.1, §11.7):
    /// `quall_teleprompter_pick_port(2000)` — a 7979, esperando até 2 s por ela (a sessão velha de uma
    /// tela recriada ainda a segura por uma bombeada), depois 7980…7988, depois uma efêmera. A escolha
    /// espera fora da thread principal e então hospeda; a volta depois de uma queda ou do segundo plano
    /// usa a mesma porta (`porta`), a vida inteira da tela.
    func hospedarNaPortaDoTeleprompter(pin: String?) {
        guard papel == .teleprompter, sessao == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let inicio = Date()
            let escolhida = quall_teleprompter_pick_port(2000)
            let ms = Date().timeIntervalSince(inicio) * 1000
            DispatchQueue.main.async {
                // A tela pode ter fechado durante a espera: sem prompter fantasma.
                guard let self, !self.saiu else { return }
                let porta = escolhida != 0 ? escolhida : LinkDePareamento.portaPadrao
                DiarioDoTeleprompter.dizer(String(format: "prompter: porta %d escolhida pelo núcleo em %.0f ms%@",
                                                  Int(porta), ms, escolhida == 0 ? " (nenhuma livre: a padrão)" : ""))
                self.hospedar(porta: porta, pin: pin)
            }
        }
    }

    /// O prompter começa a hospedar. `pin` nulo sorteia pelo núcleo (a qualidade do sorteio é o que
    /// segura o pareamento).
    ///
    /// **A permissão de Rede Local vem antes**, pelo mesmo caminho do espelhamento e do receptor
    /// (`PermissaoDeRedeLocal`): sem ela o controle entra, pareia, e o ICE não acha caminho. O
    /// pedido provoca o alerta do sistema com a tela certa na frente, e não no meio da conexão.
    func hospedar(porta: UInt16, pin: String?) {
        guard papel == .teleprompter, sessao == nil else { return }
        let escolhido = pin ?? (self.pin.count == 6 ? self.pin : Nucleo.sortearPin())
        guard escolhido.count == 6 else {
            fase = .falhou(motivo: tr("Não foi possível sortear o PIN."))
            return
        }
        self.porta = porta
        self.pin = escolhido
        ligarRelato()
        // O endereço só no diagnóstico (ligado nas builds de depuração, que é o que a bancada
        // instala): é o que o roteiro de bancada lê para apontar o controle, e não vai para o log
        // do sistema de ninguém numa build de produto — a mesma regra do PIN.
        if Diagnostico.ligado {
            DiarioDoTeleprompter.dizer("prompter: endereço para o controle disponível=\(enderecoParaDigitar != nil)")
        }
        PermissaoDeRedeLocal.pedir { [weak self] resposta in
            guard let self, self.sessao == nil else { return }
            DiarioDoTeleprompter.dizer("permissão de Rede Local: \(resposta.rawValue) "
                                       + "[\(PermissaoDeRedeLocal.testemunho)]")
            if resposta == .negada {
                // Não bloqueia: o prompter continua esperando (o controle pode vir pelo cabo, ou a
                // pessoa liga a chave e o próximo controle entra). Diz o que fazer.
                self.aviso = PermissaoDeRedeLocal.texto
            }
            let s = SessaoDoTeleprompter(replica: self.replica, modo: .prompter(porta: porta, pin: escolhido),
                                         ouvintes: self.ouvintes())
            self.sessao = s
            s.iniciar()
        }
    }

    /// O controle conecta. `endereco` já em `host:porta` (ver `LinkDePareamento`).
    func conectar(endereco: String, pin: String?) {
        guard papel == .controleRemoto else { return }
        parar()
        enderecoDoPrompter = endereco
        aviso = ""
        fase = .conectando
        let automatico = bancada != nil
        PermissaoDeRedeLocal.pedir(destino: endereco) { [weak self] resposta in
            guard let self, case .conectando = self.fase, self.sessao == nil else { return }
            DiarioDoTeleprompter.dizer("permissão de Rede Local: \(resposta.rawValue) "
                                       + "[\(PermissaoDeRedeLocal.testemunho)]")
            // Com alguém na frente e a permissão negada, conectar gastaria o prazo para chegar à
            // mesma conclusão por um caminho pior. Sem ninguém (a bancada), segue: a falha de
            // conexão é a segunda testemunha — a mesma regra de `Recepcao`.
            if resposta == .negada, !automatico {
                self.fase = .falhou(motivo: PermissaoDeRedeLocal.texto)
                return
            }
            let s = SessaoDoTeleprompter(replica: self.replica, modo: .controle(endereco: endereco, pin: pin),
                                         ouvintes: self.ouvintes())
            self.sessao = s
            s.iniciar()
        }
    }

    /// O app foi para o segundo plano. **No prompter, a sessão para e o anúncio sai**: suspenso, o
    /// iOS pode recolher o socket de escuta, e na volta o `accept` falharia em laço; o `Bye` avisa
    /// o controle na hora, sem ele esperar os 5 s do detector. O salvo é gravado.
    func aoIrParaOSegundoPlano() {
        replica.salvar(motivo: "segundo plano")
        guard papel == .teleprompter, sessao != nil else { return }
        DiarioDoTeleprompter.dizer("prompter: segundo plano — parando a sessão e o anúncio")
        pausadaPeloSistema = true
        parar()
    }

    /// O app voltou: o prompter hospeda de novo na mesma porta e com o mesmo PIN (a sessão que caiu
    /// não foi por erro de PIN).
    func aoVoltarAoPrimeiroPlano() {
        guard papel == .teleprompter, pausadaPeloSistema else { return }
        pausadaPeloSistema = false
        DiarioDoTeleprompter.dizer("prompter: primeiro plano — hospedando de novo com o mesmo PIN")
        hospedar(porta: porta, pin: pin)
    }

    /// Para a sessão (o botão Desconectar, a saída da tela, o segundo plano do prompter, a troca de
    /// endereço). A thread desmonta na ordem e avisa `.parada` quando terminar.
    ///
    /// **O par é dado por perdido aqui mesmo, antes de qualquer outra edição** (regra da revisão do
    /// núcleo, 14/09): a sessão acabou por decisão da pessoa, e um `hold` que entrasse entre esse fim
    /// e o `peer_lost` da thread iria parar no próximo prompter. A thread chama `peer_lost` de novo
    /// depois da bombeada final (§6) — as duas são seguras: sem o dedo no botão, a segunda não muda
    /// nada; com ele, a primeira já parou o texto.
    func parar() {
        guard let s = sessao else { return }
        s.parar()
        sessao = nil
        aplicar(replica.perdeuOPar())
        DiarioDoTeleprompter.dizer("sessão: parada aqui; o par dado por perdido antes de qualquer outra edição")
    }

    /// A tela saiu: nada mais hospeda (a escolha da porta, que espera fora da principal, olha isto).
    private var saiu = false

    /// Há uma sessão do prompter de pé (hospedando ou com par). A conferência do fecho da tela olha isto.
    var temSessao: Bool { sessao != nil }

    /// Sai da tela: para a sessão e guarda o salvo.
    func sair() {
        saiu = true
        parar()
        relogioDoRelato?.invalidate()
        relogioDoRelato = nil
        replica.salvar(motivo: "saiu da tela")
    }

    private func ouvintes() -> SessaoDoTeleprompter.Ouvintes {
        var o = SessaoDoTeleprompter.Ouvintes()
        o.fase = { [weak self] f in DispatchQueue.main.async { self?.mudarFase(f) } }
        o.aviso = { [weak self] a in DispatchQueue.main.async { self?.aviso = a } }
        o.pin = { [weak self] p in DispatchQueue.main.async { self?.pin = p } }
        o.anuncio = { [weak self] alias in DispatchQueue.main.async { self?.nomeNaDescoberta = alias } }
        o.mudou = { [weak self] bits in DispatchQueue.main.async { self?.aplicar(bits) } }
        o.estado = { [weak self] in DispatchQueue.main.async { self?.releitura() } }
        // O salto vai direto para a caixa, desta thread: ver `CaixaDeSalto`.
        let caixa = caixaDeSalto
        o.salto = { alvo in caixa.pedir(alvo) }
        return o
    }

    private func mudarFase(_ f: FaseDaConexao) {
        // A thread que termina avisa `.parada`; uma falha que já está na tela fica.
        if f == .parada, case .falhou = fase { return }
        conectadaDesde = f.conectada ? Date() : nil
        fase = f
        let etapa: String
        switch f {
        case .parada: etapa = "parada"
        case .esperando: etapa = "esperando"
        case .conectando: etapa = "conectando"
        case .conectada: etapa = "conectada"
        case .semPar: etapa = "semPar"
        case .falhou: etapa = "falhou"
        }
        DiarioDoTeleprompter.dizer("tela: fase \(etapa)")
        if f.conectada { aoConectar?() }
    }

    /// O que mudou por causa do outro lado. `_JUMP` no prompter vira pedido de salto para a vista;
    /// `_POSITION` no prompter é ignorado (a posição é daqui); `_TEXT` troca o texto e, com o editor
    /// aberto, acende a faixa (ver o cabeçalho).
    ///
    /// **Estado e texto são relidos aqui, na principal, na hora de aplicar** — nunca os que a thread
    /// da sessão leu antes (ver `SessaoDoTeleprompter.aplicar`). Se uma edição daqui aconteceu no
    /// meio, o que aparece é o que a réplica tem agora, e um texto que já não é o da réplica não é
    /// anunciado como "chegou".
    private func aplicar(_ bits: UInt32) {
        let novo = replica.estado()
        if let novo { estado = novo }
        if bits & QUALL_TELEPROMPTER_CHANGE_TEXT.rawValue != 0 {
            let textoNovo = replica.texto()
            if textoNovo != texto {
                texto = textoNovo
                versaoDoTexto += 1
                if editorAberto { textoMudouDuranteEdicao = true }
                DiarioDoTeleprompter.dizer("texto chegou do outro lado: \(textoNovo.utf8.count) bytes, "
                                           + "resumo \(ResumoDoTexto.de(textoNovo))"
                                           + (editorAberto ? " — com o editor aberto: faixa acesa, rascunho intocado" : ""))
                aoChegarTexto?(textoNovo)
            }
        }
        if papel == .teleprompter, bits & QUALL_TELEPROMPTER_CHANGE_JUMP.rawValue != 0,
           let alvo = novo?.salto {
            // A vista já recebeu pela caixa; aqui é só o diário.
            DiarioDoTeleprompter.dizer("salto pedido pelo controle: \(alvo)")
        }
        if bits & (QUALL_TELEPROMPTER_CHANGE_SCROLLING.rawValue | QUALL_TELEPROMPTER_CHANGE_SPEED.rawValue) != 0,
           let e = novo {
            DiarioDoTeleprompter.dizer("do outro lado: rolando=\(e.rolando) velocidade=\(e.velocidade)")
        }
        if bits & (QUALL_TELEPROMPTER_CHANGE_FONT_SIZE.rawValue | QUALL_TELEPROMPTER_CHANGE_MARGIN.rawValue
                   | QUALL_TELEPROMPTER_CHANGE_READING_LINE.rawValue | QUALL_TELEPROMPTER_CHANGE_MIRROR.rawValue) != 0,
           let e = novo {
            DiarioDoTeleprompter.dizer("do outro lado: fonte=\(e.fonte) margem=\(e.margem) "
                                       + "linha=\(e.linhaDeLeitura) espelho=\(e.espelho)")
        }
        // "A pergunta do texto" (§11.6). O estado já foi relido acima; aqui, o diário — sem texto
        // nenhum, só tamanhos e resumos — e o salvo a cada cópia nova (§11.5, achado B7).
        if bits & QUALL_TELEPROMPTER_CHANGE_TEXT_QUESTION.rawValue != 0 {
            DiarioDoTeleprompter.dizer("pergunta: " + ModeloDoTeleprompter.descrever(novo?.perguntaDoTexto))
        }
        if bits & QUALL_TELEPROMPTER_CHANGE_TEXT_COPY.rawValue != 0 {
            replica.salvar(motivo: "cópia nova do texto")
            DiarioDoTeleprompter.dizer("cópias: " + ModeloDoTeleprompter.descrever(novo?.copiasDoTexto ?? []))
        }
        // A gravação (§13): no prompter, um pedido do controle para a tela decidir.
        if bits & QUALL_TELEPROMPTER_CHANGE_RECORDING.rawValue != 0 {
            let p = novo?.pedidoDeGravacao
            DiarioDoTeleprompter.dizer("gravação: bit do outro lado; pedido="
                + (p.map { "n=\($0.n) \($0.gravar ? "gravar" : "parar") ha \($0.haMs) ms" } ?? "nenhum")
                + " gravando_ha_ms=\(novo?.gravandoHaMs.map(String.init) ?? "null")")
            aoMudarGravacao?()
        }
    }

    /// A pergunta no diário: estado, prompter, tamanhos e resumos.
    static func descrever(_ p: PerguntaDoTexto?) -> String {
        guard let p else { return "nenhuma (nada retido)" }
        let meu = p.meu.map { "\($0.bytes) bytes" } ?? "—"
        let dele = p.doPrompter.map { "\($0.bytes) bytes" } ?? "—"
        return (p.aberta ? "aberta" : "comparando há \(p.retidoHaMs) ms")
            + "; meu=\(meu); do_prompter=\(dele)"
    }

    /// As cópias no diário: só tamanhos, sem identificar aparelho, origem ou roteiro.
    static func descrever(_ copias: [CopiaDoTexto]) -> String {
        copias.isEmpty ? "nenhuma"
            : copias.map { "\($0.bytes) bytes" }.joined(separator: "; ")
    }

    /// Relê o estado depois de uma edição daqui. É barato (um JSON de ~400 bytes) e é o que faz a
    /// tela mostrar o valor **que o núcleo guardou** — quantizado —, e não o que o dedo pediu.
    private func releitura() {
        if let e = replica.estado() { estado = e }
    }

    /// Relê estado e texto — para quem editou a réplica por fora da tela (a bancada).
    func recarregar() {
        let t = replica.texto()
        if t != texto { texto = t; versaoDoTexto += 1 }
        releitura()
    }

    // --- o relato periódico do prompter ---------------------------------------------------------

    /// A última posição que a vista relatou. Só para o relato.
    private var ultimaPosicao: Double = 0
    private var relogioDoRelato: Timer?

    /// A cada 2 s, no diário: rolando, a posição que a vista está relatando, a fase e o contato com
    /// o controle. **É a testemunha de que o texto segue rolando depois de o controle cair** — a
    /// posição continua subindo nas linhas seguintes à queda, sem ninguém bombeando.
    private func ligarRelato() {
        relogioDoRelato?.invalidate()
        relogioDoRelato = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let par = self.estado.parVistoHaMs.map { "\($0) ms" } ?? "nulo"
            DiarioDoTeleprompter.dizer(String(format: "prompter: rolando=%@ posicao=%.4f velocidade=%.2f "
                                              + "fase=%@ par_visto=%@ aviso=%@", self.estado.rolando ? "sim" : "não",
                                              self.ultimaPosicao, self.estado.velocidade,
                                              "\(self.fase)", par, self.avisoDeSemPar == nil ? "não" : "SIM"))
        }
    }

    // =========================================================================================
    // As edições (qualquer papel)
    // =========================================================================================

    /// **O play e a pausa mandam o que a pessoa apertou, e só isso** (regra da revisão do núcleo,
    /// 14/09). O botão diz o que mostrava — "Rolar" é `true`, "Pausar" é `false` —, e não um alternar
    /// calculado aqui com um estado que pode estar velho. O `true` nunca reafirma um texto que a
    /// réplica já tem rolando: `set_scrolling` tira `segurando` e `para_tras` (§12.3), e com o
    /// segurar no ar o texto seguiria rolando depois de o dedo sair. No controle, durante o segurar,
    /// nenhum `set_scrolling`.
    func pedirRolando(_ v: Bool) {
        let agora = replica.estado()
        if v, agora?.rolando == true {
            DiarioDoTeleprompter.dizer("rolar ignorado: a réplica já está rolando (set_scrolling(true) não é reafirmado)")
            releitura()
            return
        }
        if papel == .controleRemoto, agora?.segurando == true {
            DiarioDoTeleprompter.dizer("\(v ? "rolar" : "pausar") ignorado: o segurar está no ar")
            releitura()
            return
        }
        definirRolando(v)
    }

    func definirRolando(_ v: Bool) {
        replica.definirRolando(v); releitura()
    }

    func definirVelocidade(_ v: Double) {
        replica.definirVelocidade(min(20, max(0.05, v))); releitura()
    }

    func definirFonte(_ v: Double) {
        replica.definirFonte(min(400, max(8, v))); releitura()
    }

    func definirMargem(_ v: Double) {
        replica.definirMargem(min(0.45, max(0, v))); releitura()
    }

    func definirLinhaDeLeitura(_ v: Double) {
        replica.definirLinhaDeLeitura(min(1, max(0, v))); releitura()
    }

    func definirEspelho(_ v: Bool) {
        replica.definirEspelho(v); releitura()
    }

    /// "Voltar ao começo" é `jump(0)` (§3).
    func voltarAoComeco() { saltar(0) }

    func saltar(_ fracao: Double) {
        replica.saltar(min(1, max(0, fracao)))
        releitura()
        // No prompter, o salto daqui também move a vista daqui (o núcleo já pôs a posição no alvo).
        if papel == .teleprompter { caixaDeSalto.pedir(estado.posicao) }
    }

    /// "Pular" é `jump_by` (§3): parte de onde o texto **vai estar**.
    func pular(_ delta: Double) {
        replica.pular(min(1, max(-1, delta)))
        releitura()
        if papel == .teleprompter { caixaDeSalto.pedir(estado.posicao) }
    }

    /// **Ao confirmar a edição** (§6, §7). Devolve a frase de erro, ou `nil` se entrou.
    func confirmarTexto(_ novo: String) -> String? {
        let st = replica.definirTexto(novo)
        guard st == QUALL_STATUS_OK else {
            let bytes = novo.utf8.count
            let teto = ReplicaDoTeleprompter.tetoDoTexto
            if bytes > teto {
                return tr("O roteiro tem %ld KiB e o teto é %ld KiB (~20 mil palavras). "
                    + "Corte um pedaço e confirme de novo.", bytes / 1024, teto / 1024)
            }
            return tr("O roteiro não entrou (%@): %@", SessaoDoTeleprompter.nome(st), ReplicaDoTeleprompter.ultimoErro())
        }
        texto = replica.texto()
        versaoDoTexto += 1
        releitura()
        replica.salvar(motivo: "texto confirmado")
        DiarioDoTeleprompter.dizer("texto confirmado aqui: \(texto.utf8.count) bytes, resumo \(ResumoDoTexto.de(texto))")
        return nil
    }

    // =========================================================================================
    // O prompter: o relato de posição, que é só dele
    // =========================================================================================

    /// A vista chama a cada quadro em que a posição mudou. O núcleo limita o envio a 4 Hz.
    func relatarPosicao(_ fracao: Double) {
        guard papel == .teleprompter, fracao.isFinite else { return }
        ultimaPosicao = min(1, max(0, fracao))
        replica.definirPosicao(ultimaPosicao)
    }

    /// O texto chegou ao fim rolando: para. É uma edição daqui (rolando=false), e o controle a vê.
    func chegouAoFim() {
        guard estado.rolando else { return }
        DiarioDoTeleprompter.dizer("o texto chegou ao fim: parando")
        definirRolando(false)
    }

    // =========================================================================================
    // Os avisos, derivados do estado — nunca guardados à parte
    // =========================================================================================

    /// Endereço deste aparelho para quem vai controlar, `ip:porta`.
    var enderecoParaDigitar: String? {
        Enderecos.destaque(lan: Enderecos.principal(), cabo: Enderecos.principalDoCabo(), porta: porta)
    }

    /// O outro lado sumiu: **o aviso das duas telas** (decisão do usuário, §2). `nil` quando está
    /// tudo bem.
    var avisoDeSemPar: String? {
        let sumidoHa: UInt64? = {
            guard fase.conectada else { return nil }
            if let v = estado.parVistoHaMs { return v >= 2500 ? v : nil }
            // Nada do outro lado ainda nesta sessão: só acusa depois de 2,5 s de pé.
            guard let desde = conectadaDesde, Date().timeIntervalSince(desde) >= 2.5 else { return nil }
            return UInt64(Date().timeIntervalSince(desde) * 1000)
        }()
        switch (papel, fase) {
        case (.teleprompter, .semPar):
            return tr("Controle desconectado — o texto continua como estava. Esperando o controle voltar.")
        case (.controleRemoto, .semPar):
            return tr("Conexão perdida com o prompter — tentando de novo. O texto lá continua como estava.")
        default:
            guard let ms = sumidoHa else { return nil }
            let s = Int(ms / 1000)
            return papel == .teleprompter
                ? tr("Controle sem sinal há %ld s — o texto continua como estava.", s)
                : tr("Prompter sem sinal há %ld s.", s)
        }
    }

    /// Acima de 1,5 s, a tela avisa que o comando não chegou (§3, "A confirmação").
    var avisoDeConfirmacao: String? {
        guard fase.conectada, avisoDeSemPar == nil, let ms = estado.semConfirmacaoHaMs, ms > 1500 else { return nil }
        return tr("O último comando ainda não chegou ao outro lado (há %.1f s).", Double(ms) / 1000)
    }

    /// Os contadores que a tela precisa transformar em frase (§4).
    var avisoDoProtocolo: String? {
        let c = estado.contadores
        if c.deOutraVersao > 0 {
            return tr("O outro aparelho fala outra versão do teleprompter. Atualize o app nos dois.")
        }
        if c.carimbosDoFuturo > 0 {
            return tr("O relógio de um dos aparelhos está adiantado mais de um dia: edições dele estão "
                + "sendo recusadas (%@). Acerte a data e a hora.", String(c.carimbosDoFuturo))
        }
        if c.reenviosDesistidos > 0 {
            return tr("O roteiro não passou para o outro lado: o relógio de um dos aparelhos está errado em "
                + "mais de um dia. Acerte a data e a hora.")
        }
        if c.mensagensImpossiveis > 0 {
            return tr("Uma mensagem não coube no canal e foi descartada (%@).", String(c.mensagensImpossiveis))
        }
        return nil
    }
}
