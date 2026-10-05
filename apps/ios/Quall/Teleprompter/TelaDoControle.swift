// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import SwiftUI
import UIKit

/// **O controle remoto**: conecta num prompter com papel `"controle_remoto"` e o comanda.
///
/// O iPhone **não lista aparelhos** — o entitlement de multicast segue pendente na Apple
/// (`docs/contrato-teleprompter.md` §2, "Como o controle acha o prompter") —, então a entrada é por
/// endereço e PIN digitados (ou colados), os que a tela do prompter mostra por extenso. O leitor de
/// QR que ficava aqui saiu em 24/09/2026, junto com o QR de todas as telas, por decisão do Pessoa Exemplo.
/// Do outro lado pode estar um iPhone, um iPad, um Android, um Mac ou um Windows: o que se fala é o contrato.
///
/// # Quando a conexão cai
///
/// A tela **não volta ao formulário**: fica nos controles, com o aviso vermelho no alto, e a sessão
/// tenta de novo sozinha a cada ~1 s, **sem PIN** (o par ficou conhecido no primeiro pareamento). O
/// prompter continua como estava enquanto isso (§2). Quem quiser desistir toca em Desconectar.
///
/// # A tela fica acesa enquanto está conectada
///
/// Um celular que bloqueia sozinho suspende o app, e a sessão cai em 5 s (o detector do prompter):
/// o controle deixaria de controlar no meio da apresentação. Por isso `isIdleTimerDisabled` enquanto
/// há sessão — e só enquanto há.
struct TelaDoControle: View {
    @StateObject private var modelo: ModeloDoTeleprompter
    let voltar: () -> Void

    @AppStorage("teleprompter_ultimo_endereco") private var ultimoEndereco = ""
    /// "Segurar para rolar" (§12): ajuste local deste controle.
    @AppStorage(SegurarParaRolar.chave) private var modoSegurar = false
    @StateObject private var segurar = ControleDeSegurar()
    /// "A pergunta do texto" e "Roteiros guardados" (§11.7).
    @StateObject private var pergunta = ControleDaPergunta()
    @StateObject private var guardados = ControleDosGuardados()
    @State private var endereco = ""
    @State private var pin = ""
    @State private var erroDoFormulario = ""
    @State private var folha: Folha?
    @State private var comecou = false
    @Environment(\.scenePhase) private var etapa

    enum Folha: String, Identifiable {
        case editor, guardados
        var id: String { rawValue }
    }

    init(voltar: @escaping () -> Void) {
        self.voltar = voltar
        _modelo = StateObject(wrappedValue: ModeloDoTeleprompter(
            papel: .controleRemoto, bancada: BancadaDoTeleprompter.consumir()))
    }

    private var noAr: Bool {
        switch modelo.fase {
        case .conectada, .semPar, .esperando: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Estilo.fundo.ignoresSafeArea()
            switch modelo.fase {
            case .parada, .falhou: formulario
            case .conectando: conectando
            case .esperando, .conectada, .semPar:
                if modoSegurar {
                    ModoSegurar(modelo: modelo, controle: segurar) { sairDoModoSegurar() }
                } else {
                    painel
                }
                // A pergunta por cima do painel e do modo segurar. Não por cima do formulário: com a
                // pessoa tentando conectar de novo, a caixa (sem botões, sem prompter) a prenderia.
                CaixaDaPerguntaView(modelo: modelo, controle: pergunta)
            }
        }
        .sheet(item: $folha) { f in
            switch f {
            case .editor: EditorDoRoteiro(modelo: modelo) { folha = nil }
            case .guardados:
                FolhaDosGuardados(modelo: modelo, controle: guardados) { folha = nil }
            }
        }
        .onChange(of: modelo.estado) { pergunta.estadoMudou($0) }
        .onAppear {
            if noAr { TelaAcesa.pedir("controle-do-teleprompter", respeitandoPreferencia: false) }
            else { TelaAcesa.soltar("controle-do-teleprompter") }
            guard !comecou else { return }
            comecou = true
            segurar.ligar(modelo)
            pergunta.ligar(modelo)
            guardados.ligar(modelo)
            BancadaDoSegurar.ligar(modelo, segurar, modo: { modoSegurar = $0 }, fecharTela: { voltar() })
            // Antes de conectar: `--controle-sem-roteiro` esvazia o roteiro daqui.
            BancadaDaPergunta.ligar(modelo, pergunta, guardados,
                                    abrirGuardados: { folha = .guardados }, fecharFolha: { folha = nil })
            if let b = modelo.bancada, let alvo = b.controle {
                endereco = alvo
                pin = b.pin ?? ""
                DiarioDoTeleprompter.dizer("tela: controle aberto pela bancada (--controle)")
                conectar()
                BancadaDoTeleprompter.ligarNoControle(modelo, opcoes: b)
            } else {
                DiarioDoTeleprompter.dizer("tela: controle aberto")
            }
        }
        .onDisappear {
            TelaAcesa.soltar("controle-do-teleprompter")
            // A sessão acaba e o par é dado por perdido **antes** de qualquer outra edição (ver
            // `ModeloDoTeleprompter.parar`); com o dedo no botão, é o `peer_lost` que para o texto, e
            // o soltar que vem depois só limpa os dedos daqui.
            modelo.sair()
            segurar.soltarTudo(porque: "a tela fechou")
        }
        .onChange(of: noAr) { ligado in
            if ligado { TelaAcesa.pedir("controle-do-teleprompter", respeitandoPreferencia: false) }
            else { TelaAcesa.soltar("controle-do-teleprompter") }
        }
        .onChange(of: etapa) { nova in
            // O controle não solta a sessão: suspenso, ela cai sozinha, e na volta a própria sessão
            // tenta de novo sem PIN. Só o salvo é gravado — e o dedo do "segurar", que sai do botão.
            if nova == .background {
                segurar.soltarTudo(porque: "segundo plano")
                modelo.aoIrParaOSegundoPlano()
            }
        }
    }

    private func sairDoModoSegurar() {
        segurar.soltarTudo(porque: "saiu do modo")
        modoSegurar = false
        DiarioDoTeleprompter.dizer("controle: saiu do modo segurar para rolar")
    }

    // --- o formulário ---------------------------------------------------------------------------

    /// O formulário (§6.7): **o mesmo molde do Exibir** (`MoldeDeConectar`), sem engrenagem. Por
    /// baixo do Conectar, os dois botões pequenos: "Colar endereço" e "Roteiros guardados" (visível
    /// sem conexão: as cópias moram neste aparelho, §11.5). O Conectar fica logo abaixo do PIN pela
    /// mesma razão da tela de exibir: o teclado numérico não tem tecla de confirmar.
    private var formulario: some View {
        MoldeDeConectar(tituloDoCabecalho: tr("Controlar"),
                        titulo: tr("Controlar um teleprompter"),
                        frase: tr("Do outro lado: Quall → Teleprompter → Mostrar o texto."),
                        exemplo: "192.168.55.10:7979",
                        endereco: $endereco,
                        pin: $pin,
                        ultimoEndereco: ultimoEndereco,
                        conectando: false,
                        podeCancelar: false,
                        avisos: avisosDoFormulario,
                        voltar: voltar,
                        cancelar: {},
                        abrirAjustes: nil,
                        conectar: conectar) {
            HStack(spacing: 10) {
                Button {
                    if let colado = UIPasteboard.general.string { usar(colado, origem: tr("área de transferência")) }
                } label: { Text(tr("Colar endereço")) }
                    .buttonStyle(.secundarioPequeno)
                BotaoDosGuardados(modelo: modelo, pequeno: true) { folha = .guardados }
            }
        }
    }

    /// O erro do formulário e o motivo da falha, as frases de sempre: vermelho, no máximo um à vista.
    private var avisosDoFormulario: [ItemDeAviso] {
        var v: [ItemDeAviso] = []
        if !erroDoFormulario.isEmpty {
            v.append(ItemDeAviso(id: "formulario", texto: erroDoFormulario, tom: .vermelho))
        }
        if case let .falhou(motivo) = modelo.fase {
            v.append(ItemDeAviso(id: "falhou", texto: motivo, tom: .vermelho))
        }
        return v
    }

    /// Um `host:porta` colado — ou um link `quall://PIN@host:porta` antigo, que `LinkDePareamento`
    /// ainda aceita. Com PIN, conecta já.
    private func usar(_ entrada: String, origem: String) {
        guard let alvo = LinkDePareamento.ler(entrada) else {
            erroDoFormulario = tr("Isso não é um endereço do Quall (%@).", origem)
            return
        }
        endereco = alvo.endereco
        if let p = alvo.pin { pin = p; conectar() }
    }

    private func conectar() {
        erroDoFormulario = ""
        guard let alvo = LinkDePareamento.ler(endereco) else {
            erroDoFormulario = tr("Digite o endereço que aparece no prompter, como 192.168.55.10:7979.")
            return
        }
        let pinLimpo = (alvo.pin ?? pin).trimmingCharacters(in: .whitespaces)
        if !pinLimpo.isEmpty, pinLimpo.count != 6 || !pinLimpo.allSatisfy(\.isNumber) {
            erroDoFormulario = tr("O PIN tem seis dígitos.")
            return
        }
        ultimoEndereco = alvo.endereco
        DiarioDoTeleprompter.dizer("controle: conectando \(pinLimpo.isEmpty ? "sem PIN (par conhecido)" : "com PIN")")
        modelo.conectar(endereco: alvo.endereco, pin: pinLimpo.isEmpty ? nil : pinLimpo)
    }

    /// Conectando (§6.7): o indicador violeta, "Conectando em {x}…", o aviso de sempre e "Cancelar".
    private var conectando: some View {
        ZStack {
            FundoDoQuall(brilho: Estilo.acento, intensidade: 0.12)
            VStack(spacing: 18) {
                ProgressView()
                    .tint(Estilo.acentoClaro)
                    .scaleEffect(1.4)
                Text(tr("Conectando em %@…", modelo.enderecoDoPrompter))
                    .font(Estilo.titulo(.title3))
                    .foregroundColor(Estilo.texto)
                    .fixedSize(horizontal: false, vertical: true)
                if !modelo.aviso.isEmpty {
                    Text(modelo.aviso)
                        .font(Estilo.corpo(.subheadline))
                        .foregroundColor(Estilo.texto2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(tr("Cancelar")) { modelo.parar() }
                    .buttonStyle(.secundario)
                    .frame(maxWidth: 320)
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: Estilo.larguraMaxima)
        }
        .dynamicTypeSize(...Estilo.tetoDaLetra)
    }

    // --- conectado ------------------------------------------------------------------------------

    private var painel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cabecalho
                AvisosDoTeleprompter(modelo: modelo).padding(.horizontal, -12)
                progresso
                transporte
                OpcaoSegurarParaRolar(ligada: $modoSegurar)
                Divider()
                ControlesDoTexto(modelo: modelo)
                Divider()
                roteiro
                Button(role: .destructive) { modelo.parar() } label: {
                    Text(tr("Desconectar")).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: 560)
        }
    }

    private var cabecalho: some View {
        HStack(spacing: 8) {
            Circle().fill(modelo.fase.conectada && modelo.avisoDeSemPar == nil ? Estilo.conectado : Estilo.noAr)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(tituloDaConexao).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Text(modelo.enderecoDoPrompter).font(.caption.monospaced()).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var tituloDaConexao: String {
        switch modelo.fase {
        case let .conectada(par): return par.isEmpty ? tr("Conectado ao prompter") : tr("Conectado a %@", par)
        case .semPar: return tr("Conexão perdida — tentando de novo")
        default: return tr("Conectando…")
        }
    }

    private var progresso: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("Leitura")).font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f %%", modelo.estado.posicao * 100))
                    .font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }
            ProgressView(value: min(1, max(0, modelo.estado.posicao)))
        }
    }

    private var transporte: some View {
        // O que o botão mostra é o que ele manda (`pedirRolando`): nada de alternar na hora do toque.
        let rolando = modelo.estado.rolando
        return HStack(spacing: 8) {
            botao("backward.end.fill", tr("Voltar ao começo")) { modelo.voltarAoComeco() }
            botao("gobackward", tr("Voltar 5 %"), texto: "−5%") { modelo.pular(-0.05) }
            botao("chevron.backward", tr("Voltar 1 %"), texto: "−1%") { modelo.pular(-0.01) }
            Button(action: { modelo.pedirRolando(!rolando) }) {
                Image(systemName: rolando ? "pause.fill" : "play.fill")
                    .font(.title.weight(.bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 64, maxWidth: 110, minHeight: 56)
                    .background(Estilo.acento)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rolando ? tr("Pausar") : tr("Rolar"))
            botao("chevron.forward", tr("Pular 1 %"), texto: "+1%") { modelo.pular(0.01) }
            botao("goforward", tr("Pular 5 %"), texto: "+5%") { modelo.pular(0.05) }
        }
    }

    private func botao(_ simbolo: String, _ rotulo: String, texto: String? = nil,
                       acao: @escaping () -> Void) -> some View {
        // Flexível e sem largura mínima própria: seis `.bordered` lado a lado passavam da largura do
        // iPhone (a mesma lição da barra do prompter).
        Button(action: acao) {
            VStack(spacing: 2) {
                Image(systemName: simbolo).font(.body.weight(.semibold))
                if let texto { Text(texto).font(.caption2.monospacedDigit()) }
            }
            .foregroundColor(Estilo.acentoClaro)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Estilo.superficie)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rotulo)
    }

    private var roteiro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Roteiro")).font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f KiB", Double(modelo.estado.textoBytes) / 1024))
                    .font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }
            Text(modelo.texto.isEmpty ? tr("Sem roteiro.") : String(modelo.texto.prefix(160)))
                .font(.footnote).foregroundColor(.secondary).lineLimit(3)
            Button { folha = .editor } label: {
                Label(tr("Editar ou colar o roteiro"), systemImage: "pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            BotaoDosGuardados(modelo: modelo) { folha = .guardados }
        }
    }
}
