import SwiftUI

/// **Ajustes** — a engrenagem (`docs/telas-estudio.md` §6.3). A mesma folha abre das três engrenagens:
/// Início, Espelhar e Exibir.
///
/// É para onde foi o que o R16 tirou das telas: a qualidade do espelhamento e a nota de custo (eram
/// do Espelhar), a folga de exibição (era do formulário de Exibir), esquecer os pareados (era do pé do
/// Espelhar) e as duas linhas técnicas do aparelho e da tela (eram do pé do Início e do formulário de
/// Exibir). Nada mudou de efeito: as mesmas preferências, lidas e gravadas nos mesmos lugares.
///
/// Conta de altura no iPhone 7 (a folha tem ~637 pt): 8 + cabeçalho 40 + 8 + qualidade ~155 + 12 +
/// ao exibir ~141 + 12 + pareamento ~101 + 12 + sobre ~131 + 12 ≈ 632. Por segurança o miolo fica numa
/// rolagem, que só anda se a nota de custo passar de duas linhas.
struct FolhaDaEngrenagem: View {
    @Environment(\.openURL) private var abrirURL
    let fechar: () -> Void
    /// Depois de esquecer os pares, para a tela de trás atualizar o que mostra.
    var aoEsquecerPares: () -> Void = {}
    /// Só para ver (o retrato de bancada): nenhum toque grava preferência nem esquece pares.
    var somenteLeitura = false

    /// O cardápio, lido da preferência na abertura e devolvido a ela a cada troca.
    @State private var resolucao: Resolucao = Resolucao.escolhida
    @State private var quadros: Int = Resolucao.quadros
    /// A folga de exibição: vale a partir da próxima conexão (ver `Exibidor`).
    @AppStorage(SessaoDeRecepcao.chaveDaFolga) private var folgaMs = SessaoDeRecepcao.folgaPadraoMs
    /// Contados no `onAppear`, e não na criação da folha: a leitura coordenada do `pares.json` não
    /// tem por que rodar a cada vez que o SwiftUI recria esta vista.
    @State private var pares: Int?
    @State private var contou = false
    @State private var confirmandoEsquecer = false
    @State private var mostrandoLicencas = false
    @State private var mostrandoErroDoSite = false
    /// "Permitir controle remoto da câmera" (R9b), desligada por padrão.
    @State private var controleRemoto = PermissaoDoControleRemoto.ligada

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(tr("Ajustes"))
                    .font(Estilo.corpo(.body, .semibold))
                    .foregroundColor(Estilo.texto)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Spacer()
                    Button(tr("Pronto"), action: fechar)
                        .font(Estilo.corpo(.body, .semibold))
                        .foregroundColor(Estilo.acentoClaro)
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    qualidade
                    aoExibir
                    tela
                    camera
                    pareamento
                    sobre
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .allowsHitTesting(!somenteLeitura)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Estilo.fundo.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Estilo.acento)
        .dynamicTypeSize(...Estilo.tetoDaLetra)
        .sheet(isPresented: $mostrandoLicencas) {
            FolhaDasLicencas { mostrandoLicencas = false }
        }
        .alert(tr("Não foi possível abrir o site."), isPresented: $mostrandoErroDoSite) {
            Button(tr("Fechar"), role: .cancel) {}
        }
        .onAppear {
            pares = FolhaDaEngrenagem.contarPares()
            contou = true
        }
        .onChange(of: resolucao) { if !somenteLeitura { Resolucao.escolhida = $0 } }
        .onChange(of: quadros) { if !somenteLeitura { Resolucao.quadros = $0 } }
        .onChange(of: controleRemoto) { if !somenteLeitura { PermissaoDoControleRemoto.ligada = $0 } }
        .confirmationDialog(tr("Esquecer os aparelhos pareados?"), isPresented: $confirmandoEsquecer,
                            titleVisibility: .visible) {
            Button(tr("Esquecer"), role: .destructive) { esquecer() }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("Na próxima vez, cada aparelho pede o PIN de novo."))
        }
    }

    // --- os grupos ---------------------------------------------------------------------------------

    /// As duas escolhas do cardápio, e **a frase que diz o custo**.
    ///
    /// A nota não é enfeite: `docs/fluxo-de-uso.md` registra que a promessa do produto é
    /// *combinação testada*, e não *capacidade abstrata* — "suporta 4K" é verdade num cabo e mentira
    /// num Wi-Fi compartilhado. Oferecer a linha sem dizer o preço é oferecer em silêncio, que é o
    /// pior modo de falha deste projeto.
    private var qualidade: some View {
        grupo(tr("Qualidade do espelhamento")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(tr("Resolução"), selection: $resolucao) {
                    ForEach(Resolucao.allCases, id: \.self) { r in Text(r.rotulo).tag(r) }
                }
                .pickerStyle(.segmented)
                Picker(tr("Quadros"), selection: $quadros) {
                    ForEach(Resolucao.taxas, id: \.self) { f in Text(verbatim: "\(f) fps").tag(f) }
                }
                .pickerStyle(.segmented)
                Text(FolhaDaEngrenagem.custo(resolucao: resolucao, quadros: quadros))
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    /// Só o iOS tem a folga, e ela cabe aqui: a mesma chave que a sessão lê (`folgaEscolhidaMs`).
    private var aoExibir: some View {
        grupo(tr("Ao exibir")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Folga de exibição"))
                    .font(Estilo.corpo(.subheadline))
                    .foregroundColor(Estilo.texto)
                Picker(tr("Folga de exibição"), selection: $folgaMs) {
                    Text(tr("nenhuma")).tag(0)
                    Text(verbatim: "30 ms").tag(30)
                    Text(verbatim: "50 ms").tag(50)
                    Text(verbatim: "80 ms").tag(80)
                }
                .pickerStyle(.segmented)
                Text(tr("Mais folga, imagem mais lisa e um pouco mais atrasada."))
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    private var tela: some View {
        grupo(tr("Tela")) {
            SeletorDaTelaAcesa(somenteLeitura: somenteLeitura)
                .padding(10)
        }
    }

    /// **"Permitir controle remoto da câmera"** (R9b, `docs/controle-remoto-da-camera.md` §12):
    /// desligada, quem recebe a imagem vê os ajustes da câmera apagados, com "O aparelho não permite
    /// controle remoto da câmera". Mora aqui, com as preferências, e não no painel "Ajustes da câmera":
    /// o painel não rola e tem a altura contada para o iPhone 7 (R9 §4.2). Vale para a câmera comum e
    /// para a tela "Texto + câmera", e para uma câmera aberta muda na hora.
    private var camera: some View {
        grupo(tr("Câmera")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $controleRemoto) {
                    Text(tr("Permitir controle remoto da câmera"))
                        .font(Estilo.corpo(.subheadline))
                        .foregroundColor(Estilo.texto)
                }
                Text(tr("Quem recebe a imagem desta câmera pode ajustar exposição, balanço e foco."))
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    /// **Onde esquecer aparelhos pareados**, e por que isso é produto e não configuração: sem isto,
    /// um pareamento dessincronizado é definitivo — o núcleo recusa a retomada e **não** cai de volta
    /// para o PIN (dívida 22). A tela de espera oferece o mesmo no momento em que o erro aparece;
    /// este é para quem já saiu de lá.
    private var pareamento: some View {
        grupo(tr("Pareamento")) {
            VStack(spacing: 0) {
                linha(tr("Aparelhos pareados")) {
                    Text(contou ? (pares.map { $0 == 0 ? tr("nenhum") : "\($0)" } ?? "") : "")
                        .font(Estilo.corpo(.subheadline))
                        .foregroundColor(Estilo.texto2)
                }
                divisoria
                Button(action: { confirmandoEsquecer = true }) {
                    Text(tr("Esquecer aparelhos pareados"))
                        .font(Estilo.corpo(.subheadline))
                        .foregroundColor(Estilo.perigoTexto)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.toque)
                .disabled(pares == 0)
                .opacity(pares == 0 ? 0.4 : 1)
            }
        }
    }

    private var sobre: some View {
        grupo(tr("Sobre")) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Este aparelho"))
                        .font(Estilo.corpo(.subheadline))
                        .foregroundColor(Estilo.texto)
                    Text(Identidade.descricaoDoAparelho())
                        .font(Estilo.mono(.caption))
                        .foregroundColor(Estilo.texto2)
                    Text(Identidade.descricaoDaTela())
                        .font(Estilo.mono(.caption))
                        .foregroundColor(Estilo.texto2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                divisoria
                linha(tr("Versão")) {
                    Text(FolhaDaEngrenagem.versao)
                        .font(Estilo.mono(.footnote))
                        .foregroundColor(Estilo.texto2)
                }
                divisoria
                Button(action: { mostrandoLicencas = true }) {
                    HStack {
                        Text(tr("Licenças de terceiros"))
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(Estilo.corpo(.subheadline))
                    .foregroundColor(Estilo.acentoClaro)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.toque)
                divisoria
                ligacaoDoSite(tr("Política de privacidade"), pt: "quall/privacidade/", en: "en/quall/privacy/")
                divisoria
                ligacaoDoSite(tr("Suporte"), pt: "quall/suporte/", en: "en/quall/support/")
            }
        }
    }

    // --- pedaços -------------------------------------------------------------------------------------

    private func ligacaoDoSite(_ titulo: String, pt: String, en: String) -> some View {
        Button {
            guard let url = URL(string: "https://queven.com.br/" + (Idioma.atual == .pt ? pt : en)) else {
                mostrandoErroDoSite = true
                return
            }
            abrirURL(url) { abriu in mostrandoErroDoSite = !abriu }
        } label: {
            HStack {
                Text(titulo)
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(Estilo.corpo(.subheadline))
            .foregroundColor(Estilo.acentoClaro)
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.toque)
    }

    private func grupo<C: View>(_ titulo: String, @ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RotuloDeSecao(titulo).padding(.horizontal, 4)
            conteudo()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Estilo.superficieDoGrupo))
        }
    }

    private func linha<C: View>(_ titulo: String, @ViewBuilder _ valor: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(titulo).font(Estilo.corpo(.subheadline)).foregroundColor(Estilo.texto)
            Spacer(minLength: 0)
            valor()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    private var divisoria: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14)
    }

    private func esquecer() {
        guard !somenteLeitura else { return }
        Compartilhado.esquecerPares()
        pares = FolhaDaEngrenagem.contarPares()
        aoEsquecerPares()
    }

    // --- valores ---------------------------------------------------------------------------------------

    /// O custo da escolha que o dedo está fazendo agora, e não da gravada. O número vem do **núcleo**,
    /// por `PedidoDeEspelhamento.tetoDeTaxa`, e não de uma tabela escrita aqui: num binário que
    /// anunciasse um nível menor, 4K viraria 1080p e a nota diria isso em vez de mentir. (Era
    /// `TelaInicial.custoDaEscolha` até 30/09.)
    static func custo(resolucao: Resolucao, quadros: Int) -> String {
        let teto = resolucao.teto
        let bps = PedidoDeEspelhamento.tetoDeTaxa(maior: teto.maior, menor: teto.menor,
                                                  fps: Int32(quadros), alvoMaxFs: resolucao.maxFs)
        let mbps = Double(bps) / 1_000_000
        let base = tr("%@ a %ld fps pede cerca de %.0f Mbps deste enlace.",
                      resolucao.rotulo, quadros, mbps)
        // O limiar é o joelho agregado do rádio da bancada (§8.10, 32–47 Mbps): acima dele o
        // transporte deixa de ser detalhe.
        return bps >= 30_000_000
            ? base + " " + tr("Num Wi-Fi compartilhado isso é muito; no cabo, folgado.")
            : base
    }

    /// Quantos aparelhos estão no `pares.json` (a tabela `{"pares": {...}}` do núcleo). Zero sem o
    /// arquivo; `nil` se o formato não for o esperado — aí a linha fica sem número em vez de mentir.
    static func contarPares() -> Int? {
        guard Compartilhado.haParesConhecidos else { return 0 }
        guard let texto = Compartilhado.lerPares(),
              let dados = texto.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let tabela = objeto["pares"] as? [String: Any] else { return nil }
        return tabela.count
    }

    static var versao: String {
        let info = Bundle.main.infoDictionary
        let curta = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(curta) (\(build))"
    }
}
