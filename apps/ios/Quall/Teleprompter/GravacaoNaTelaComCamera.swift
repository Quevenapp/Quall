import SwiftUI
import UIKit

/// **A gravação vista pelo prompter** (R5 fase 3; `docs/contrato-teleprompter.md` §13.8): a ponte
/// entre o `GravadorLocal` e a réplica do teleprompter.
///
/// - Ao abrir a tela, `ligarGravacao(true)`: o estado passa a dizer `"entende_gravar": true`, e só
///   então um controle mostra o botão. Ao fechar, `false` (o núcleo recusa o pedido aberto).
/// - **O arquivo começou → `definirGravando(true)`; fechou → `definirGravando(false)`**, venha de
///   onde vier (o botão, o controle, a câmera, o espaço, o segundo plano). É o que o controle vê.
/// - **O pedido do controle** (bit `_RECORDING`): relê `"pedido_de_gravacao"` e decide pelo mais novo
///   — já está como se pede: aceita (`definirGravando` com o valor dele); não está: grava ou para, e o
///   arquivo começando/fechando responde; não dá: `recusarGravacao(n, motivo)`. `BUSY` na recusa é
///   "chegou outro": relê e decide de novo.
/// - Gravando, a orientação da interface trava (`EscolhaDeOrientacao.prenderPelaGravacao`) e o
///   ângulo da conexão congela (o gravador faz): §5.2 e a revisão M-d.
///
/// Só na principal.
final class GravacaoDoPrompter {
    let gravador: GravadorLocal
    private weak var modelo: ModeloDoTeleprompter?
    /// O `n` do pedido que está sendo atendido (gravando ou parando): outro bit nesse meio espera.
    private var atendendo: UInt64?
    /// O último `n` já tentado: um pedido que não saiu do estado (a recusa voltou outra coisa) não é
    /// tentado em laço.
    private var ultimoTentado: UInt64?

    init(gravador: GravadorLocal) {
        self.gravador = gravador
    }

    func ligar(modelo: ModeloDoTeleprompter, orientacao: EscolhaDeOrientacao) {
        self.modelo = modelo
        let st = modelo.replica.ligarGravacao(true)
        DiarioDoTeleprompter.dizer("gravação: a tela grava (ligarGravacao → \(SessaoDoTeleprompter.nome(st)))")
        modelo.aoMudarGravacao = { [weak self] in self?.decidir() }
        gravador.aoMudar = { [weak self] gravando in
            guard let self else { return }
            if let r = self.modelo?.replica {
                let st = r.definirGravando(gravando)
                DiarioDoTeleprompter.dizer("gravação: definirGravando(\(gravando)) → \(SessaoDoTeleprompter.nome(st))")
            }
            self.decidir()
        }
        gravador.aoTravar = { [weak orientacao] sim in
            if sim { orientacao?.prenderPelaGravacao() } else { orientacao?.soltarDaGravacao() }
        }
        // Um pedido que ficou aberto de antes (o núcleo o guarda através da queda, §13.4).
        decidir()
    }

    /// A tela fecha: a gravação para (o arquivo fecha e vai ao rolo mesmo com a tela fechada) e o
    /// prompter deixa de dizer que grava.
    func desligar(motivo: String) {
        pararAntesDaSessaoCair(motivo: motivo)
        guard let m = modelo else { return }
        m.aoMudarGravacao = nil
        let st = m.replica.ligarGravacao(false)
        DiarioDoTeleprompter.dizer("gravação: a tela não grava mais (ligarGravacao(false) → \(SessaoDoTeleprompter.nome(st)))")
    }

    /// **A sessão do prompter vai cair** (a tela fecha, o app vai ao segundo plano): a gravação para,
    /// e o controle ouve `definirGravando(false)` **agora**, enquanto ainda há sessão para levar — o
    /// arquivo fecha depois, e o `false` dele chegaria sem ninguém para ouvir, deixando o controle com
    /// "gravando" até a sessão seguinte (revisão de 24/09, M1).
    func pararAntesDaSessaoCair(motivo: String) {
        let gravava = gravador.estado.ocupada
        gravador.parar(motivo: motivo)
        guard gravava, let r = modelo?.replica else { return }
        let st = r.definirGravando(false)
        DiarioDoTeleprompter.dizer("gravação: definirGravando(false) antes de a sessão cair (\(SanitizacaoDoLog.causaExterna(motivo))) → "
                                   + "\(SessaoDoTeleprompter.nome(st))")
    }

    /// O botão Gravar/Parar da tela.
    func tocar() {
        switch gravador.estado {
        case .parada:
            gravador.comecar(por: .toque) { _ in }
        case .gravando, .abrindo:
            gravador.parar(motivo: "o botão Parar")
        case .fechando:
            break
        }
    }

    /// Relê o pedido do controle e decide (§13.2, passo 4).
    func decidir() {
        guard let r = modelo?.replica, let p = r.estado()?.pedidoDeGravacao else { return }
        if let n = atendendo {
            // Um "parar" mais novo enquanto um "gravar" espera o primeiro quadro: para já (o gravador
            // trata o `.abrindo`), sem esperar os 3 s do primeiro quadro (revisão, menor 3). O resto
            // espera o pedido em curso terminar.
            if p.n != n, !p.gravar, gravador.estado == .abrindo {
                DiarioDoTeleprompter.dizer("gravação: pedido n=\(p.n) parar chegou com o gravar n=\(n) abrindo; para já")
                gravador.parar(motivo: "pedido do controle remoto")
            }
            return
        }
        let jaAssim = p.gravar ? gravador.estado.gravando : gravador.estado == .parada
        if jaAssim {
            let st = r.definirGravando(p.gravar)
            DiarioDoTeleprompter.dizer("gravação: pedido n=\(p.n) \(p.gravar ? "gravar" : "parar") — já estava assim; "
                                       + "aceito (\(SessaoDoTeleprompter.nome(st)))")
            return
        }
        guard ultimoTentado != p.n else {
            DiarioDoTeleprompter.dizer("gravação: pedido n=\(p.n) já tentado e ainda aberto; não tento de novo em laço")
            return
        }
        ultimoTentado = p.n
        atendendo = p.n
        DiarioDoTeleprompter.dizer("gravação: pedido do controle n=\(p.n) \(p.gravar ? "gravar" : "parar") "
                                   + "(estado aqui: \(gravador.estado))")
        if p.gravar {
            gravador.comecar(por: .controle) { [weak self] motivo in
                guard let self else { return }
                self.atendendo = nil
                if let motivo, let r = self.modelo?.replica {
                    let texto = GravacaoDoPrompter.caber(motivo)
                    let st = r.recusarGravacao(n: p.n, motivo: texto)
                    DiarioDoTeleprompter.dizer("gravação: pedido n=\(p.n) recusado: \(SanitizacaoDoLog.causaExterna(texto)) (\(SessaoDoTeleprompter.nome(st)))")
                }
                // Aceito, o `definirGravando(true)` do arquivo começando já respondeu. `BUSY`: outro
                // pedido chegou; e, de todo jeito, pode ter chegado um "parar" nesse meio.
                self.decidir()
            }
        } else {
            gravador.parar(motivo: "pedido do controle remoto") { [weak self] in
                guard let self else { return }
                self.atendendo = nil
                self.decidir()
            }
        }
    }

    /// O motivo no teto do contrato (256 bytes de UTF-8), cortado numa fronteira de caractere.
    static func caber(_ s: String) -> String {
        guard s.utf8.count > 250 else { return s }
        var r = ""
        for c in s {
            if (r + String(c)).utf8.count > 250 { break }
            r.append(c)
        }
        return r
    }
}

/// **O botão Gravar/Parar**, na linha de estado da faixa (nada entre o texto e a lente): parado, um
/// círculo vermelho; gravando, vermelho cheio com o tempo e o espaço que sobra (§5.5), e "SEM SOM"
/// com o microfone desligado (a faixa ainda põe "Gravando SEM SOM — ligue o microfone" nos avisos).
struct BotaoDeGravar: View {
    @ObservedObject var gravador: GravadorLocal
    @ObservedObject var dono: DonoDaCaptura
    let tocar: () -> Void

    var body: some View {
        Button(action: tocar) {
            conteudo
                .foregroundColor(.white)
                .frame(minWidth: 48, minHeight: 44)
                .padding(.horizontal, gravador.estado.gravando ? 8 : 0)
                .background(fundo)
                .cornerRadius(9)
        }
        .buttonStyle(.plain)
        .disabled(!dono.montado || gravador.estado == .fechando)
        .opacity(dono.montado ? 1 : 0.45)
        .accessibilityLabel(gravador.estado.ocupada ? tr("Parar a gravação") : tr("Gravar"))
        .accessibilityValue(valorAcessivel)
    }

    @ViewBuilder private var conteudo: some View {
        switch gravador.estado {
        case .parada:
            Image(systemName: "record.circle").font(.title3.weight(.semibold)).foregroundColor(Estilo.noAr)
        case .abrindo, .fechando:
            ProgressView().tint(.white)
        case .gravando(let desde):
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.footnote.weight(.bold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(GravadorLocal.duracaoLegivel(ProcessInfo.processInfo.systemUptime - desde))
                            .font(.system(.footnote, design: .monospaced).weight(.bold))
                        // **Sem som, dito por extenso** (decisão do Pessoa Exemplo, 24/09 à noite): gravar não
                        // liga o microfone, e o ícone riscado sozinho não bastava.
                        HStack(spacing: 2) {
                            if !dono.microfone.ligado {
                                Image(systemName: "mic.slash")
                                Text(tr("SEM SOM ·"))
                            }
                            Text(espaco)
                        }
                        .font(.caption2)
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private var espaco: String {
        guard let l = gravador.espacoLivre else { return "" }
        return String(format: "%.1f GB", Double(l) / 1_000_000_000)
    }

    private var fundo: Color {
        gravador.estado.gravando ? Estilo.noAr.opacity(0.85) : Color.white.opacity(0.14)
    }

    private var valorAcessivel: String {
        switch gravador.estado {
        case .parada: return tr("Parado")
        case .abrindo: return tr("Começando")
        case .fechando: return tr("Fechando o arquivo")
        case .gravando(let desde):
            let duracao = GravadorLocal.duracaoLegivel(ProcessInfo.processInfo.systemUptime - desde)
            return dono.microfone.ligado ? tr("Gravando há %@", duracao)
                : tr("Gravando há %@, sem som (microfone desligado)", duracao)
        }
    }
}

/// **A bancada da gravação**, sem toque, só com o diagnóstico ligado (o mesmo cuidado dos outros
/// argumentos de bancada). A frontal filma a sala: cada corrida pede o sim do Pessoa Exemplo, e o cartão fica
/// na frente da câmera.
///
/// - `--gravar-apos S`: pede para gravar S s depois de a câmera montar (o mesmo caminho do botão, com
///   a origem `bancada`: sem a permissão de Fotos dada, recusa em vez de perguntar);
/// - `--gravar-por D`: **toda** gravação desta tela para D s depois de começar, venha de quem vier
///   (o toque, o controle, a bancada) — `GravadorLocal.pararDepoisDe` (§8.12);
/// - `--matar-gravando-apos M`: M s depois de começar, **`SIGKILL` no próprio processo** — o fim
///   abrupto da prova M7 (o arquivo órfão; a abertura seguinte o leva ao rolo);
/// - `--guardar-copia`: o arquivo que foi ao rolo não é apagado, e sim movido para
///   `Documents/GravacoesDeProva` (para o `ffprobe` no Mac). Vale também na abertura seguinte, para o
///   órfão recuperado.
struct BancadaDaGravacao {
    var apos: Double?
    var por: Double?
    var matarApos: Double?
    var guardarCopia = false

    static let opcoes: BancadaDaGravacao = {
        var o = BancadaDaGravacao()
        guard Diagnostico.ligado else { return o }
        let args = CommandLine.arguments
        func valor(_ nome: String) -> Double? {
            guard let i = args.firstIndex(of: nome), i + 1 < args.count else { return nil }
            return Double(args[i + 1]).map { max(0, $0) }
        }
        o.apos = valor("--gravar-apos")
        o.por = valor("--gravar-por")
        o.matarApos = valor("--matar-gravando-apos")
        o.guardarCopia = args.contains("--guardar-copia")
        return o
    }()

    /// Agenda o que foi pedido. `vivo` diz se a tela ainda está aberta.
    static func ligar(_ g: GravadorLocal, vivo: @escaping () -> Bool) {
        let b = opcoes
        // A parada vale para a gravação de pé, e não só para a que a bancada pediu: o pedido da
        // bancada pode ser recusado (Fotos por decidir) e a pessoa tocar em Gravar.
        g.pararDepoisDe = b.por
        guard let apos = b.apos else { return }
        Diagnostico.nota("APP GRAVACAO bancada: grava em \(apos) s"
            + (b.por.map { ", para \($0) s depois" } ?? "")
            + (b.matarApos.map { ", MATA o processo \($0) s depois de começar" } ?? ""))
        DispatchQueue.main.asyncAfter(deadline: .now() + apos) {
            guard vivo() else { return }
            g.comecar(por: .bancada) { motivo in
                guard motivo == nil else { return }
                if let m = b.matarApos {
                    DispatchQueue.main.asyncAfter(deadline: .now() + m) {
                        Diagnostico.nota("APP GRAVACAO bancada: SIGKILL agora, gravando (--matar-gravando-apos \(m))")
                        // O diário precisa de um instante para sair do processo.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { kill(getpid(), SIGKILL) }
                    }
                }
            }
        }
    }
}
