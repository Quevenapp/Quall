import AVFoundation
import Foundation
import Photos
import UIKit

/// O estado da gravação, para a tela.
enum EstadoDaGravacao: Equatable {
    case parada
    /// Pedida: esperando o primeiro quadro entrar no arquivo.
    case abrindo
    /// `desde` é `systemUptime` (monotônico) do primeiro quadro.
    case gravando(desde: TimeInterval)
    /// O arquivo está fechando (o som que falta, o writer).
    case fechando

    var gravando: Bool { if case .gravando = self { return true }; return false }
    var ocupada: Bool { self != .parada }
}

/// De onde veio o pedido de gravar: muda só o que a permissão de Fotos pode fazer (um pedido do
/// controle remoto não abre o alerta do sistema num aparelho que talvez ninguém esteja olhando).
enum QuemPedeAGravacao: String {
    case toque, controle, bancada
}

/// **O gravador local** (fase 3, `docs/teleprompter-com-camera.md` §5), da tela R5 e — desde 24/09
/// à noite — da tela da câmera comum, frontal ou traseira (§8.8): decide se pode gravar, começa,
/// para, e leva o arquivo ao rolo da câmera. Na câmera comum a captura é a do cardápio (não a melhor
/// imagem), e o arquivo sai no tamanho dela.
///
/// - **Grava a câmera sem o texto**, com o som do microfone (silêncio quando o botão do microfone
///   está desligado), na melhor imagem do aparelho: a captura da tela R5 é montada com
///   `melhorImagem` e o arquivo sai no tamanho dela, pelo segundo codificador (`TomadaDeGravacao`).
/// - **Não depende da rede**: a tomada tem vaga própria no dono. O receptor entra, cai e volta, e o
///   arquivo segue.
/// - **Recusa com motivo legível** (é o texto que o controle remoto mostra, `contrato-teleprompter.md`
///   §13.3): sem permissão de Fotos, sem espaço, câmera interrompida ou sem entregar.
/// - **Para sozinho** (§5.3) quando a câmera é interrompida ou para de entregar, quando o espaço
///   cai abaixo de `espacoParaSeguir`, e quando a tela manda (segundo plano, a tela fechando).
/// - **O arquivo**: `Documents/Gravacoes/Quall-AAAAMMDD-HHMMSS.mp4`, fragmentado enquanto grava; ao
///   fechar, vai a Fotos e é apagado daqui. O que não for (permissão, erro, o processo morto) fica, e
///   é levado na abertura seguinte (`GravacoesPendentes`).
///
/// Só na principal.
final class GravadorLocal: ObservableObject {

    @Published private(set) var estado: EstadoDaGravacao = .parada
    /// O espaço livre no volume do app, lido a cada 5 s gravando (e ao pedir).
    @Published private(set) var espacoLivre: Int64?
    /// A última palavra sobre um arquivo ("salvo no rolo…", "não foi salvo…") ou uma recusa, para a
    /// linha de avisos. Some sozinha em 15 s.
    @Published private(set) var recado: (texto: String, grave: Bool)?
    /// A gravação de agora saiu em 720p porque o aparelho estava quente ao tocar em Gravar (§8.12.1):
    /// o texto para a faixa enquanto ela durar; `nil` sem gravação ou na melhor imagem.
    @Published private(set) var reduzidaPeloCalor: String?

    /// A gravação começou (`true`, o primeiro quadro está no arquivo) ou fechou (`false`). É onde a
    /// tela chama `definirGravando` da réplica, e trava e solta a orientação.
    var aoMudar: ((Bool) -> Void)?
    /// A gravação vai começar (`true`, antes do primeiro quadro: congelar o ângulo e travar a
    /// interface) ou terminou de fechar / não começou (`false`).
    var aoTravar: ((Bool) -> Void)?

    let dono: DonoDaCaptura

    /// O aviso de gravando com o microfone desligado (decisão do Pessoa Exemplo, 24/09 à noite: gravar **não**
    /// liga o microfone; a pessoa liga antes, e ligar no meio grava som dali em diante).
    static var textoSemSom: String { tr("Gravando SEM SOM — ligue o microfone") }

    static let espacoParaComecar: Int64 = 500_000_000
    static let espacoParaSeguir: Int64 = 300_000_000
    /// Sem quadro novo da câmera há mais que isto, gravando: para.
    static let semQuadroPorNoMaximo: Double = 2.0

    private var tomada: TomadaDeGravacao?
    private var numero = 0
    private var aoComecar: [(String?) -> Void] = []
    private var aoFechar: [() -> Void] = []
    private var supervisor: Timer?
    private var voltas = 0
    private var vezDoRecado = 0
    /// Um `parar` chegou enquanto o alerta de Fotos estava aberto: não começa na resposta.
    private var pararNaPermissao = false
    /// **A parada da bancada** (`--gravar-por D`, só com o diagnóstico ligado): cada gravação que
    /// começa — pelo toque, pelo controle ou pela bancada — para D s depois do primeiro quadro.
    /// Até 27/09 a parada só era agendada no sucesso do pedido **da bancada**; no iPad de instalação
    /// nova o pedido da bancada foi recusado (Fotos por decidir), o Pessoa Exemplo tocou em Gravar, e a
    /// gravação passou 13 min do limite (§8.12).
    var pararDepoisDe: Double?

    init(dono: DonoDaCaptura) {
        self.dono = dono
    }

    // --- começar ---------------------------------------------------------------------------------

    /// Pede para gravar. `fim(nil)` quando o primeiro quadro está no arquivo; `fim(motivo)` quando
    /// não vai gravar. Gravando, responde `nil` na hora; fechando, recusa (tente de novo).
    func comecar(por quem: QuemPedeAGravacao, fim: @escaping (String?) -> Void) {
        switch estado {
        case .gravando: fim(nil); return
        case .abrindo: aoComecar.append(fim); return
        case .fechando:
            // O fecho dura menos de 1 s: o pedido espera ele e começa em seguida.
            aoFechar.append { [weak self] in self?.comecar(por: quem, fim: fim) }
            return
        case .parada: break
        }
        if let m = motivoParaNaoGravar() {
            recusar(m.motivo, naTela: m.naTela, quem: quem, fim: fim)
            return
        }
        // A permissão de Fotos por último: é a única que pode esperar uma resposta da pessoa.
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            abrir(por: quem, fim: fim)
        case .notDetermined:
            guard quem == .toque else {
                recusar("sem permissão para salvar no rolo da câmera: toque em Gravar uma vez neste "
                        + "aparelho para o iOS perguntar",
                        naTela: tr("sem permissão para salvar no rolo da câmera: toque em Gravar uma vez neste "
                                   + "aparelho para o iOS perguntar"), quem: quem, fim: fim)
                return
            }
            Diagnostico.nota("APP GRAVACAO pedindo a permissão de Fotos (só adicionar)")
            estado = .abrindo
            aoComecar.append(fim)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                naPrincipal { [weak self] in
                    guard let self else { return }
                    let pendentes = self.aoComecar
                    self.aoComecar = []
                    self.estado = .parada
                    if self.pararNaPermissao {
                        self.pararNaPermissao = false
                        Diagnostico.nota("APP GRAVACAO parada antes de começar (enquanto o iOS perguntava)")
                        for f in pendentes { f("parada antes de começar") }
                        let fs = self.aoFechar
                        self.aoFechar = []
                        for f in fs { f() }
                        return
                    }
                    if status == .authorized || status == .limited {
                        // A câmera pode ter parado enquanto o alerta estava aberto.
                        if let m = self.motivoParaNaoGravar() {
                            for f in pendentes { self.recusar(m.motivo, naTela: m.naTela, quem: quem, fim: f) }
                            return
                        }
                        self.aoComecar = Array(pendentes.dropFirst())
                        if let primeiro = pendentes.first { self.abrir(por: quem, fim: primeiro) }
                        GravacoesPendentes.recuperar(por: "a permissão de Fotos foi dada")
                    } else {
                        for f in pendentes {
                            self.recusar("sem permissão para salvar no rolo da câmera: Ajustes → Quall → Fotos",
                                         naTela: GravadorLocal.semFotosNaTela, quem: quem, fim: f)
                        }
                    }
                }
            }
        case .denied:
            recusar("sem permissão para salvar no rolo da câmera: Ajustes → Quall → Fotos",
                    naTela: GravadorLocal.semFotosNaTela, quem: quem, fim: fim)
        case .restricted:
            recusar("sem permissão para salvar no rolo da câmera: bloqueado por Tempo de Uso ou por um perfil",
                    naTela: tr("sem permissão para salvar no rolo da câmera: bloqueado por Tempo de Uso ou por um perfil"),
                    quem: quem, fim: fim)
        @unknown default:
            recusar("sem permissão para salvar no rolo da câmera",
                    naTela: tr("sem permissão para salvar no rolo da câmera"), quem: quem, fim: fim)
        }
    }

    /// O que impede de gravar agora, conferido **antes** de abrir qualquer coisa. `nil`: pode.
    /// O `motivo` em português vai ao diário e ao controle remoto (o protocolo); `naTela`, no idioma
    /// da interface, vai ao recado desta tela.
    private func motivoParaNaoGravar() -> (motivo: String, naTela: String)? {
        guard dono.montado else { return ("a câmera não está aberta", tr("a câmera não está aberta")) }
        if !dono.interrupcao.isEmpty {
            let curto = GravadorLocal.curto(dono.interrupcao)
            return ("câmera interrompida: \(curto)", tr("câmera interrompida: %@", curto))
        }
        guard let ha = dono.ultimoQuadroHa, ha < 1.0 else {
            return ("a câmera não está entregando imagem", tr("a câmera não está entregando imagem"))
        }
        let livre = GravadorLocal.lerEspacoLivre()
        espacoLivre = livre
        if let livre, livre < GravadorLocal.espacoParaComecar {
            return ("sem espaço: sobram \(livre / 1_000_000) MB (gravar pede 500 MB livres)",
                    tr("sem espaço: sobram %ld MB (gravar pede 500 MB livres)", Int(livre / 1_000_000)))
        }
        return nil
    }

    /// A recusa sem a permissão de Fotos, com o caminho dos Ajustes na língua do sistema.
    private static var semFotosNaTela: String {
        tr("sem permissão para salvar no rolo da câmera: %@", trSistema("Ajustes → Quall → Fotos"))
    }

    /// O diário e a saída padrão (sem perda no `idevicedebug`).
    static func dizerNosDois(_ linha: String) {
        Diagnostico.nota(linha)
        guard Diagnostico.ligado else { return }
        print("[quall-gravacao] " + SanitizacaoDoLog.mensagem(linha))
        fflush(stdout)
    }

    /// `motivo` (em português) vai ao diário e a quem pediu (o controle remoto o recebe pela rede);
    /// `naTela`, no idioma da interface, ao recado.
    private func recusar(_ motivo: String, naTela: String, quem: QuemPedeAGravacao, fim: (String?) -> Void) {
        Diagnostico.nota("APP GRAVACAO recusada (\(quem.rawValue)): \(motivo)")
        mostrarRecado(tr("Não gravou: %@", naTela), grave: true)
        fim(motivo)
    }

    private func abrir(por quem: QuemPedeAGravacao, fim: @escaping (String?) -> Void) {
        guard let pasta = GravacoesPendentes.pasta() else {
            // Todos os que esperavam (o alerta de Fotos) ouvem a mesma recusa: nenhum fica sem resposta.
            let outros = aoComecar
            aoComecar = []
            recusar("não foi possível criar a pasta das gravações",
                    naTela: tr("não foi possível criar a pasta das gravações"), quem: quem, fim: fim)
            for f in outros { f("não foi possível criar a pasta das gravações") }
            return
        }
        numero += 1
        // Nome único (revisão M5): dois no mesmo segundo não disputam o arquivo.
        var url = pasta.appendingPathComponent(GravadorLocal.nomeDoArquivo(Date()))
        var sufixo = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = pasta.appendingPathComponent(GravadorLocal.nomeDoArquivo(Date(), sufixo: sufixo))
            sufixo += 1
        }
        // Quente ao tocar em Gravar: este arquivo sai em 720p (a gravação de pé nunca muda de
        // tamanho, §8.12.1). Relido agora, sem esperar a notificação.
        let calor = CalorDoAparelho.compartilhado
        calor.reler()
        let quente = calor.quente
        let t = TomadaDeGravacao(url: url, numero: numero, fps: Resolucao.quadros, reduzidaPeloCalor: quente)
        tomada = t
        reduzidaPeloCalor = nil
        // O texto só quando o arquivo de fato sai menor que a captura (revisão do código, menor 8).
        t.aoReduzir = { [weak self, weak t] tamanho in
            guard let self, let t, self.tomada === t else { return }
            self.reduzidaPeloCalor = tr("Gravando em %@: o aparelho está quente.", tamanho)
        }
        estado = .abrindo
        aoComecar.append(fim)
        GravacoesPendentes.marcarAtivo(url)
        // O ângulo congela **antes** do primeiro quadro entrar: o tamanho do arquivo é o dele.
        aoTravar?(true)
        dono.congelarAngulo(true)
        let n = numero
        t.aoPrimeiroQuadro = { [weak self, weak t] in
            guard let self, let t, self.tomada === t, self.estado == .abrindo else { return }
            self.estado = .gravando(desde: ProcessInfo.processInfo.systemUptime)
            Diagnostico.nota("APP GRAVACAO #\(n) gravando (\(quem.rawValue)): o primeiro quadro está no arquivo;"
                + " microfone=\(self.dono.microfone.ligado ? "ligado" : "desligado (a trilha de som recebe silêncio)")")
            self.aoMudar?(true)
            if let d = self.pararDepoisDe {
                Diagnostico.nota("APP GRAVACAO #\(n) bancada: para em \(d) s (--gravar-por, vale para qualquer origem)")
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self, weak t] in
                    guard let self, let t, self.tomada === t, self.estado.gravando else { return }
                    self.parar(motivo: "bancada --gravar-por \(d)")
                }
            }
            let fs = self.aoComecar
            self.aoComecar = []
            for f in fs { f(nil) }
        }
        t.aoFalhar = { [weak self, weak t] motivo in
            guard let self, let t, self.tomada === t else { return }
            self.parar(motivo: motivo)
        }
        dono.pendurarGravador(t)
        Diagnostico.nota("APP GRAVACAO #\(n) pedida (\(quem.rawValue))"
            + " captura=\(dono.formatoRecebido) espaco_livre=\(espacoLivre.map { "\($0 / 1_000_000) MB" } ?? "?")"
            + " microfone=\(dono.microfone.ligado ? "ligado" : "desligado")"
            + " termico=\(calor.termico)\(quente ? " (quente: o arquivo sai em 720p)" : "")")
        subirSupervisor()
        // O primeiro quadro tem 3 s para entrar no arquivo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak t] in
            guard let self, let t, self.tomada === t, self.estado == .abrindo else { return }
            self.parar(motivo: "a câmera não está entregando imagem")
        }
    }

    // --- parar -----------------------------------------------------------------------------------

    /// Para (o botão, o controle, a câmera, o espaço, a tela). `fim` quando o arquivo fechou. Parada,
    /// `fim` na hora.
    func parar(motivo: String, fim: (() -> Void)? = nil) {
        if tomada == nil, estado == .abrindo {
            // Esperando o alerta de Fotos: não há arquivo; a resposta dele não começa nada.
            pararNaPermissao = true
            if let fim { aoFechar.append(fim) }
            return
        }
        guard let t = tomada, estado != .parada else { fim?(); return }
        if let fim { aoFechar.append(fim) }
        guard estado != .fechando else { return }
        let comecou = estado.gravando
        estado = .fechando
        // **Todo fecho diz o motivo, e por dois canais** (bancada de 27/09 à tarde: esta linha se
        // perdeu do relay do `idevicesyslog`, e o arquivo fechou "sem motivo"): no diário, e também
        // na saída padrão, que o `idevicedebug` guarda sem perda (o canal do `DiarioDoTeleprompter`);
        // e de novo na linha `fechada` (`parou_por=`).
        GravadorLocal.dizerNosDois("APP GRAVACAO #\(t.numero) parando: \(SanitizacaoDoLog.causaExterna(motivo))")
        // Um pedido que ainda esperava o primeiro quadro não vai gravar.
        let esperando = aoComecar
        aoComecar = []
        for f in esperando { f(motivo) }
        let fundo = GravadorLocal.comecarTarefaDeFundo()
        // **Forte, de propósito**: a tela pode fechar (e soltar o gravador) com o arquivo fechando; o
        // gravador vive até o arquivo ir ao rolo.
        t.parar(motivo: motivo) { resultado in
            self.dono.soltarGravador(t)
            if self.tomada === t { self.tomada = nil }
            self.supervisor?.invalidate()
            self.supervisor = nil
            self.estado = .parada
            if self.tomada == nil { self.reduzidaPeloCalor = nil }
            self.dono.congelarAngulo(false)
            self.aoTravar?(false)
            // O giro que aconteceu gravando foi segurado: a conexão volta à interface de agora, e de
            // novo depois de a interface terminar de girar (revisão M2).
            self.dono.reaplicarOrientacaoDaCena()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.dono.reaplicarOrientacaoDaCena() }
            if comecou { self.aoMudar?(false) }
            let fs = self.aoFechar
            self.aoFechar = []
            for f in fs { f() }
            self.levarAoRolo(resultado, motivo: motivo) { GravadorLocal.terminarTarefaDeFundo(fundo) }
        }
    }

    // --- o rolo da câmera --------------------------------------------------------------------------

    private func levarAoRolo(_ r: TomadaDeGravacao.Fim, motivo: String, terminou: @escaping () -> Void) {
        // O recado do calor vale só para este fecho, qualquer que seja o resultado (revisão de 27/09, M2).
        let recadoDoCalor = recadoAoSalvar
        recadoAoSalvar = nil
        guard r.quadros > 0 else {
            GravacoesPendentes.desmarcar(r.url)
            if let e = r.erroNaTela { mostrarRecado(tr("A gravação não começou: %@", e), grave: true) }
            terminou()
            return
        }
        let duracao = r.duracao.map { GravadorLocal.duracaoLegivel($0) } ?? "?"
        guard r.erro == nil else {
            // O arquivo não fechou direito: fica como pendente e segue o caminho do órfão.
            GravacoesPendentes.desmarcar(r.url)
            mostrarRecado(tr("A gravação parou com erro (%@); o que foi gravado vai ao rolo da câmera "
                             + "pelo caminho dos pendentes.", r.erroNaTela ?? ""), grave: true)
            GravacoesPendentes.recuperar(por: "uma gravação que fechou com erro") { terminou() }
            return
        }
        let inicio = CFAbsoluteTimeGetCurrent()
        GravacoesPendentes.salvarNoRolo(r.url, data: GravacoesPendentes.dataDoArquivo(r.url)) { resultado in
            switch resultado {
            case .success(let id):
                // Apagar antes de desmarcar: uma recuperação no meio não o leva ao rolo de novo.
                GravacoesPendentes.tirarDaPasta(r.url)
                GravacoesPendentes.desmarcar(r.url)
                GravadorLocal.dizerNosDois(String(format: "APP GRAVACAO salva no rolo da câmera em %.0f ms (%@, %lld bytes, parou por: %@)",
                                        (CFAbsoluteTimeGetCurrent() - inicio) * 1000,
                                        duracao, r.bytes, SanitizacaoDoLog.causaExterna(motivo)))
                if let r = recadoDoCalor {
                    self.mostrarRecado(r, grave: true)
                } else {
                    self.mostrarRecado(tr("Gravação salva no rolo da câmera (%@).", duracao), grave: false)
                }
            case .failure(let erro):
                GravacoesPendentes.desmarcar(r.url)
                Diagnostico.falha("APP GRAVACAO não foi ao rolo da câmera: \(SanitizacaoDoLog.erro(erro)); fica em Documents/Gravacoes")
                self.mostrarRecado(tr("A gravação (%@) não foi ao rolo da câmera: %@. "
                                      + "Ela fica guardada no app e vai na próxima abertura.",
                                      duracao, GravadorLocal.curto("\(erro)")), grave: true)
            }
            terminou()
        }
    }

    // --- a supervisão, gravando ----------------------------------------------------------------

    private func subirSupervisor() {
        supervisor?.invalidate()
        voltas = 0
        supervisor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.supervisionar() }
    }

    private func supervisionar() {
        guard let t = tomada, estado.ocupada, estado != .fechando else { return }
        voltas += 1
        // **Uma interrupção curta não fecha a gravação** (§8.12.9): o iPhone 7 quente de 27/09 fechou
        // uma gravação de 20 min sem motivo visível, com a câmera de volta logo depois (um buraco de
        // ~300 ms no relato do dono) — hipótese: uma interrupção breve vista por esta regra. A gravação
        // para só com a interrupção de pé por mais de `semQuadroPorNoMaximo`; o arquivo guarda o buraco
        // (o PTS é o da câmera).
        if !dono.interrupcao.isEmpty, dono.interrompidaDesde > 0,
           ProcessInfo.processInfo.systemUptime - dono.interrompidaDesde > GravadorLocal.semQuadroPorNoMaximo {
            parar(motivo: "câmera interrompida: \(GravadorLocal.curto(dono.interrupcao))")
            return
        }
        if !dono.interrupcao.isEmpty, dono.interrompidaDesde == 0 {
            // Um erro de execução (sem começo de interrupção): como antes, para já.
            parar(motivo: "câmera interrompida: \(GravadorLocal.curto(dono.interrupcao))")
            return
        }
        if estado.gravando, dono.interrupcao.isEmpty, (dono.ultimoQuadroHa ?? 99) > GravadorLocal.semQuadroPorNoMaximo {
            parar(motivo: "a câmera parou de entregar imagem")
            return
        }
        // A câmera entrega e o arquivo não recebe (quadro de outro tamanho, o codificador falhando,
        // o writer recusando): parar e dizer, em vez de seguir "gravando" um arquivo parado (B1).
        if estado.gravando, dono.interrupcao.isEmpty, (t.ultimoAnexadoHa ?? 99) > GravadorLocal.semQuadroPorNoMaximo {
            parar(motivo: "o arquivo parou de receber imagem (o codificador da gravação não está entregando)")
            return
        }
        if voltas % 5 == 0 {
            // Fora da principal: a conta do espaço purgável pode demorar (revisão M6).
            DispatchQueue.global(qos: .utility).async { [weak self, weak t] in
                let l = GravadorLocal.lerEspacoLivre()
                naPrincipal {
                    guard let self, let t, self.tomada === t else { return }
                    self.espacoLivre = l
                    if let l, l < GravadorLocal.espacoParaSeguir, self.estado.gravando {
                        self.parar(motivo: "sem espaço: sobram \(l / 1_000_000) MB")
                    }
                }
            }
        }
        if voltas % 10 == 0 { t.relatar(espacoLivre: espacoLivre) }
    }

    // --- o segundo plano -------------------------------------------------------------------------

    /// Fechar o arquivo e levá-lo a Fotos continua se o app sair da tela no meio. Uma tarefa por
    /// gravação: duas seguidas (a segunda começando com a primeira indo ao rolo) não se soltam uma à
    /// outra. Se o iOS encerrar o tempo antes, o arquivo fica, e a recuperação o leva na volta.
    private final class TarefaDeFundo {
        var id: UIBackgroundTaskIdentifier = .invalid
    }

    private static func comecarTarefaDeFundo() -> TarefaDeFundo {
        let t = TarefaDeFundo()
        t.id = UIApplication.shared.beginBackgroundTask(withName: "quall.gravacao.fechar") {
            Diagnostico.falha("APP GRAVACAO o iOS encerrou o tempo em segundo plano antes de o arquivo ir ao rolo")
            naPrincipal { terminarTarefaDeFundo(t) }
        }
        return t
    }

    /// Na principal. A segunda chamada (o prazo do iOS e o fim normal) não faz nada.
    private static func terminarTarefaDeFundo(_ t: TarefaDeFundo) {
        guard t.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(t.id)
        t.id = .invalid
    }

    // --- recados e utilidades ----------------------------------------------------------------------

    /// **A gravação para porque a transmissão precisa** (o degrau 2, §8.12.16): o arquivo fecha e vai ao
    /// rolo como sempre, e o recado é o da decisão do Pessoa Exemplo.
    private var recadoAoSalvar: String?

    func pararPeloCalor() {
        guard estado.gravando else { return }
        recadoAoSalvar = tr("Gravação parada: o aparelho esquentou. O arquivo foi salvo.")
        parar(motivo: "o aparelho esquentou com a transmissão de pé (degrau 2)")
    }

    private func mostrarRecado(_ texto: String, grave: Bool) {
        vezDoRecado += 1
        let vez = vezDoRecado
        recado = (texto, grave)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.vezDoRecado == vez else { return }
            self.recado = nil
        }
    }

    /// O espaço que o iOS diz estar disponível para uso importante (inclui o que ele pode liberar de
    /// caches). `nil` quando a leitura falha.
    static func lerEspacoLivre() -> Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func nomeDoArquivo(_ d: Date, sufixo: Int? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Quall-\(f.string(from: d))\(sufixo.map { "-\($0)" } ?? "").mp4"
    }

    static func duracaoLegivel(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Um texto longo (a interrupção da câmera) na primeira frase, para caber num motivo de recusa.
    static func curto(_ s: String) -> String {
        let primeira = s.split(separator: ".", maxSplits: 1).first.map(String.init) ?? s
        return String(primeira.prefix(160))
    }
}

/// **Os arquivos que ainda não foram ao rolo da câmera** (§5.4): o órfão de um fim abrupto (o
/// processo morto gravando), o que fechou com erro, e o que o iOS não aceitou (sem permissão). Na
/// abertura do app e depois de cada gravação, cada um é levado a Fotos e apagado daqui; o que não for
/// fica para a próxima.
///
/// O arquivo fragmentado de um fim abrupto é legível até o último fragmento (S-I1, §8.2) — **mas que
/// Fotos o aceita como está é hipótese**. Se recusar, ele é reempacotado sem recodificar
/// (`AVAssetExportPresetPassthrough`) e tentado de novo. Sem trilha de vídeo legível (morto antes do
/// primeiro fragmento), ele é renomeado para `.ilegivel` e não é mais tentado.
///
/// **O som que sobra além da imagem é aparado** (prova de 24/09 no iPhone X: no órfão
/// `Quall-20260924-182456.mp4`, o `ffprobe` deu vídeo 540 pacotes = 18,018 s e som 898 pacotes =
/// 19,157 s — 1,1 s de som sem imagem no fim). Quando o som passa do fim do último quadro legível
/// por mais que `sobraDeSomTolerada`, o pendente vai ao rolo **aparado**: uma composição com as duas
/// trilhas até o fim do vídeo, reempacotada sem recodificar. Se aparar falhar, vai como está (o som
/// sobrando é melhor que o arquivo perdido).
enum GravacoesPendentes {
    private static let fila = DispatchQueue(label: "br.com.queven.quall.gravacao.pendentes", qos: .utility)
    private static let trava = NSLock()
    private static var ativos = Set<String>()
    private static var recuperando = false

    static func pasta() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let p = docs.appendingPathComponent("Gravacoes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            return p
        } catch {
            Diagnostico.falha("APP GRAVACAO a pasta Documents/Gravacoes não foi criada: \(SanitizacaoDoLog.erro(error))")
            return nil
        }
    }

    /// Um arquivo sendo gravado (ou a caminho do rolo): a recuperação não toca nele.
    static func marcarAtivo(_ url: URL) { trava.lock(); ativos.insert(url.lastPathComponent); trava.unlock() }
    static func desmarcar(_ url: URL) { trava.lock(); ativos.remove(url.lastPathComponent); trava.unlock() }
    private static func ativo(_ nome: String) -> Bool { trava.lock(); defer { trava.unlock() }; return ativos.contains(nome) }

    /// Um arquivo que já está no rolo sai da pasta. Em geral o Fotos já o **moveu**
    /// (`shouldMoveFile`); isto apaga o que sobrar.
    static func tirarDaPasta(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    /// Com `--guardar-copia` na bancada: uma cópia em `Documents/GravacoesDeProva`, **antes** de o
    /// Fotos mover o arquivo, de onde a sessão principal a traz para o `ffprobe`
    /// (`afcclient --container`), sem a recuperação a levar ao rolo.
    static func guardarCopiaDeProva(_ url: URL) {
        guard BancadaDaGravacao.opcoes.guardarCopia else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let provas = docs.appendingPathComponent("GravacoesDeProva", isDirectory: true)
        try? FileManager.default.createDirectory(at: provas, withIntermediateDirectories: true)
        let destino = provas.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destino)
        if (try? FileManager.default.copyItem(at: url, to: destino)) != nil {
            Diagnostico.nota("APP GRAVACAO cópia de prova guardada em Documents/GravacoesDeProva")
        }
    }

    static func dataDoArquivo(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
    }

    /// Leva os pendentes ao rolo. Sem a permissão de Fotos dada, não pergunta nada: conta e espera a
    /// próxima gravação (que pergunta). `fim` na principal.
    static func recuperar(por motivo: String, fim: (() -> Void)? = nil) {
        fila.async {
            trava.lock()
            let ja = recuperando
            recuperando = true
            trava.unlock()
            guard !ja else { if let fim { naPrincipal(fim) }; return }
            defer {
                trava.lock(); recuperando = false; trava.unlock()
                if let fim { naPrincipal(fim) }
            }
            guard let p = pasta() else { return }
            let nomes = ((try? FileManager.default.contentsOfDirectory(atPath: p.path)) ?? [])
                .filter { $0.hasSuffix(".mp4") && !$0.hasPrefix("reempacotado-") && !$0.hasPrefix("aparado-")
                          && !ativo($0) }
                .sorted()
            guard !nomes.isEmpty else { return }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Diagnostico.nota("APP GRAVACAO pendentes: \(nomes.count) esperando a permissão de Fotos (\(motivo))")
                return
            }
            Diagnostico.nota("APP GRAVACAO pendentes: \(nomes.count) achados (\(motivo))")
            var salvos = 0
            for nome in nomes {
                if levarUm(p.appendingPathComponent(nome)) { salvos += 1 }
            }
            Diagnostico.nota("APP GRAVACAO pendentes: \(salvos) de \(nomes.count) salvos no rolo da câmera")
        }
    }

    /// O som pode passar do fim do último quadro por até isto (um pacote AAC tem 21,3 ms a 48 kHz)
    /// sem o pendente ser aparado.
    static let sobraDeSomTolerada: Double = 0.05

    /// Síncrono, na `fila`. `true` quando foi ao rolo (e saiu daqui).
    private static func levarUm(_ url: URL) -> Bool {
        let nome = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let video = asset.tracks(withMediaType: .video).first
        let audio = asset.tracks(withMediaType: .audio).first
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        let dur = CMTimeGetSeconds(asset.duration)
        let fimDoVideo = video.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRange)) } ?? -1
        let fimDoSom = audio.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRange)) } ?? -1
        Diagnostico.nota(String(format: "APP GRAVACAO pendente %@: bytes=%lld duracao=%.3f s video=%@ som=%@ legivel=%@"
                                + " fim_do_video=%.3f s fim_do_som=%.3f s",
                                "[arquivo]", bytes, dur.isFinite ? dur : -1, video == nil ? "não" : "sim",
                                audio == nil ? "não" : "sim", asset.isReadable ? "sim" : "não",
                                fimDoVideo.isFinite ? fimDoVideo : -1, fimDoSom.isFinite ? fimDoSom : -1))
        let data = dataDoArquivo(url)
        let legivel = video != nil && dur.isFinite && dur > 0
        // **O som que sobra além da imagem** (o fim abrupto): aparado ao fim do último quadro.
        if legivel, let v = video, let a = audio, fimDoVideo.isFinite, fimDoSom.isFinite, fimDoVideo > 0,
           fimDoSom - fimDoVideo > sobraDeSomTolerada {
            let aparado = url.deletingLastPathComponent().appendingPathComponent("aparado-" + nome)
            if aparar(asset, video: v, audio: a, nome: nome, saida: aparado) {
                switch salvarNoRoloAgora(aparado, data: data) {
                case .success(let id):
                    try? FileManager.default.removeItem(at: aparado)
                    tirarDaPasta(url)
                    Diagnostico.nota("APP GRAVACAO pendente salvo no rolo da câmera com o som aparado ao fim do"
                                     + " vídeo")
                    return true
                case .failure(let e):
                    // Não para aqui (revisão, médio 2): se o Fotos recusasse sempre o aparado, o órfão
                    // nunca chegaria ao rolo. Segue o caminho de antes: como está, depois reempacotado.
                    try? FileManager.default.removeItem(at: aparado)
                    Diagnostico.falha("APP GRAVACAO pendente aparado e recusado por Fotos: \(SanitizacaoDoLog.erro(e)); vai como está")
                }
            }
            // Aparar falhou (dito em `aparar`) ou o aparado foi recusado: segue como está, com o som
            // sobrando.
        }
        if legivel, case .success(let id) = salvarNoRoloAgora(url, data: data) {
            tirarDaPasta(url)
            Diagnostico.nota("APP GRAVACAO pendente salvo no rolo da câmera como está")
            return true
        }
        // Reempacotado sem recodificar, e de novo.
        let saida = url.deletingLastPathComponent().appendingPathComponent("reempacotado-" + nome)
        try? FileManager.default.removeItem(at: saida)
        guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            Diagnostico.falha("APP GRAVACAO pendente: sem sessão de exportação; fica para a próxima")
            return false
        }
        exp.outputURL = saida
        exp.outputFileType = .mp4
        let s = DispatchSemaphore(value: 0)
        exp.exportAsynchronously { s.signal() }
        s.wait()
        guard exp.status == .completed else {
            try? FileManager.default.removeItem(at: saida)
            if !legivel {
                // Sem vídeo legível nem reempacotado (morto antes do primeiro fragmento): não é mais
                // tentado, e não é apagado.
                let novo = url.appendingPathExtension("ilegivel")
                try? FileManager.default.moveItem(at: url, to: novo)
                Diagnostico.falha("APP GRAVACAO pendente sem vídeo legível: marcado como ilegível")
                return false
            }
            Diagnostico.falha("APP GRAVACAO pendente: o reempacotamento falhou (\(exp.error.map { SanitizacaoDoLog.erro($0) } ?? "?")); fica para a próxima")
            return false
        }
        switch salvarNoRoloAgora(saida, data: data) {
        case .success(let id):
            try? FileManager.default.removeItem(at: saida)
            tirarDaPasta(url)
            Diagnostico.nota("APP GRAVACAO pendente salvo no rolo da câmera depois de reempacotado")
            return true
        case .failure(let e):
            try? FileManager.default.removeItem(at: saida)
            Diagnostico.falha("APP GRAVACAO pendente recusado por Fotos também reempacotado: \(SanitizacaoDoLog.erro(e)); fica para a próxima")
            return false
        }
    }

    /// **Apara o som ao fim do último quadro de vídeo**, sem recodificar: uma composição com o vídeo
    /// inteiro e o som só até o fim dele, exportada com `AVAssetExportPresetPassthrough`. Síncrono, na
    /// `fila`. `true` quando `saida` foi escrita; a conferência é o `ffprobe` do roteiro (§8.8), que
    /// tem de dar as duas `duration` iguais a ±1 quadro.
    private static func aparar(_ asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack, nome: String,
                               saida: URL) -> Bool {
        try? FileManager.default.removeItem(at: saida)
        let composicao = AVMutableComposition()
        guard let cv = composicao.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = composicao.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            Diagnostico.falha("APP GRAVACAO pendente: a composição para aparar não nasceu; vai como está")
            return false
        }
        let faixaDoVideo = video.timeRange
        let fim = CMTimeRangeGetEnd(faixaDoVideo)
        let faixaDoSom = CMTimeRangeGetIntersection(audio.timeRange, otherRange: CMTimeRange(start: .zero, end: fim))
        do {
            // Cada trilha no mesmo instante em que estava: o sincronismo não muda, só o fim do som.
            try cv.insertTimeRange(faixaDoVideo, of: video, at: faixaDoVideo.start)
            if faixaDoSom.isEmpty {
                // Nenhum som dentro da imagem: sem trilha de som vazia na composição (revisão, menor 8).
                composicao.removeTrack(ca)
            } else {
                try ca.insertTimeRange(faixaDoSom, of: audio, at: faixaDoSom.start)
            }
        } catch {
            Diagnostico.falha("APP GRAVACAO pendente: a composição para aparar recusou as trilhas (\(SanitizacaoDoLog.erro(error))); vai como está")
            return false
        }
        cv.preferredTransform = video.preferredTransform
        guard let exp = AVAssetExportSession(asset: composicao, presetName: AVAssetExportPresetPassthrough) else {
            Diagnostico.falha("APP GRAVACAO pendente: sem sessão de exportação para aparar; vai como está")
            return false
        }
        exp.outputURL = saida
        exp.outputFileType = .mp4
        let s = DispatchSemaphore(value: 0)
        exp.exportAsynchronously { s.signal() }
        s.wait()
        guard exp.status == .completed else {
            try? FileManager.default.removeItem(at: saida)
            Diagnostico.falha("APP GRAVACAO pendente: aparar o som falhou (\(exp.error.map { SanitizacaoDoLog.erro($0) } ?? "?")); vai como está")
            return false
        }
        Diagnostico.nota(String(format: "APP GRAVACAO pendente %@: som aparado ao fim do vídeo — video=%.3f s, som de %.3f s"
                                + " para %.3f s (sem recodificar)", "[arquivo]", CMTimeGetSeconds(fim),
                                CMTimeGetSeconds(CMTimeRangeGetEnd(audio.timeRange)),
                                CMTimeGetSeconds(CMTimeRangeGetEnd(faixaDoSom))))
        return true
    }

    /// Síncrono (fora da principal).
    private static func salvarNoRoloAgora(_ url: URL, data: Date?) -> Result<String, Error> {
        var r: Result<String, Error> = .failure(NSError(domain: "quall", code: -1))
        let s = DispatchSemaphore(value: 0)
        salvarNoRolo(url, data: data, naPrincipal: false) { r = $0; s.signal() }
        s.wait()
        return r
    }

    /// Cria o vídeo em Fotos a partir do arquivo, **movendo-o** (aceito, ele não está mais aqui;
    /// recusado, continua). `fim` na principal (ou na thread de Fotos, com `naPrincipal: false`).
    static func salvarNoRolo(_ url: URL, data: Date?, naPrincipal: Bool = true,
                             fim: @escaping (Result<String, Error>) -> Void) {
        // **Fora da principal** (bancada de 27/09 à tarde): a cópia de prova de uma gravação de 20 min
        // são 2,3 GB, e ela corria na principal antes do Fotos — o app parado por dezenas de segundos.
        DispatchQueue.global(qos: .utility).async {
            salvarNoRoloJa(url, data: data, naPrincipal: naPrincipal, fim: fim)
        }
    }

    private static func salvarNoRoloJa(_ url: URL, data: Date?, naPrincipal: Bool,
                                       fim: @escaping (Result<String, Error>) -> Void) {
        var id = ""
        guardarCopiaDeProva(url)
        PHPhotoLibrary.shared().performChanges({
            let pedido = PHAssetCreationRequest.forAsset()
            let op = PHAssetResourceCreationOptions()
            // **Mover, e não copiar** (revisão M4): parar por falta de espaço e depois pedir uma cópia
            // do tamanho do arquivo ao Fotos é o jeito certo de o rolo recusar.
            op.shouldMoveFile = true
            pedido.addResource(with: .video, fileURL: url, options: op)
            if let data { pedido.creationDate = data }
            id = pedido.placeholderForCreatedAsset?.localIdentifier ?? "?"
        }) { ok, erro in
            let r: Result<String, Error> = ok ? .success(id) : .failure(erro ?? NSError(domain: "quall", code: -2))
            if naPrincipal { Quall_naPrincipal { fim(r) } } else { fim(r) }
        }
    }
}

/// `naPrincipal` com outro nome, para dentro de funções que têm um parâmetro chamado `naPrincipal`.
private func Quall_naPrincipal(_ f: @escaping () -> Void) { naPrincipal(f) }
