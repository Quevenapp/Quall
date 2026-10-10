// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import AppKit
import QuallCaptureKit
import QuallIdiomaKit
import SwiftUI

/// **Os retratos das telas** (`docs/telas-estudio.md` §9): `--retratos-de-bancada=<pasta>` desenha
/// as vistas de apresentação com dados de exemplo, por `ImageRenderer`, em PNG a 2x — a janela de
/// 880 × 580, o vídeo também no mínimo dele (520 × 400) e os Ajustes a 560 × 460 — e sai.
///
/// **Não cria janela, não abre sessão e não pede permissão nenhuma**: os modelos (`Emissor`,
/// `Receptor`, `Teleprompter`) nem nascem, o `Registro` não abre, e o nome deste Mac é o de exemplo.
/// É o jeito de olhar a tela sem abrir o app na tela do Pessoa Exemplo.
///
/// O `ImageRenderer` não desenha vista do AppKit: o vídeo e a prévia da câmera saem como um retângulo
/// com o nome (`LugarDaIlha`), e as peças nativas (campo, interruptor, segmentado, menu, deslizante)
/// desenham a imitação delas (`\.emRetrato`).

enum Retratos {
    private struct Retrato {
        let nome: String
        let tamanho: CGSize
        let vista: AnyView
    }

    private static let janela = CGSize(width: 880, height: 580)
    private static let nome = "Mac de exemplo"

    /// Desenha todos e diz quantos saíram. Falso se algum falhou.
    @MainActor static func desenhar(em pasta: String) -> Bool {
        let destino = URL(fileURLWithPath: (pasta as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        } catch {
            print("!! retratos: não consegui criar \(destino.path): \(error.localizedDescription)")
            return false
        }
        var falhas = 0
        for r in todos {
            if !salvar(r, em: destino.appendingPathComponent(r.nome + ".png")) { falhas += 1 }
        }
        print("retratos: \(todos.count - falhas) de \(todos.count) em \(destino.path)")
        return falhas == 0
    }

    @MainActor private static func salvar(_ r: Retrato, em arquivo: URL) -> Bool {
        let conteudo = r.vista
            .frame(width: r.tamanho.width, height: r.tamanho.height)
            .environment(\.emRetrato, true)
            .environment(\.colorScheme, .dark)
            .tint(Estilo.acento)
        let desenhista = ImageRenderer(content: conteudo)
        desenhista.scale = 2
        guard let cg = desenhista.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("!! retratos: \(r.nome) não desenhou")
            return false
        }
        do {
            try png.write(to: arquivo)
            print("retrato: \(arquivo.lastPathComponent) \(cg.width)x\(cg.height)")
            return true
        } catch {
            print("!! retratos: \(r.nome): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - a moldura

    /// A janela do estúdio: a barra lateral e o painel.
    private static func estudio<P: View>(_ escolhido: ItemDaBarra, sessao: SessaoNaBarra? = nil,
                                         desligados: Set<ItemDaBarra> = [], @ViewBuilder _ painel: () -> P) -> AnyView {
        AnyView(
            HStack(spacing: 0) {
                BarraLateral(escolhido: escolhido, sessao: sessao, nome: nome, desligados: desligados,
                             aoEscolher: { _ in }, aoAbrirAjustes: {})
                painel().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Estilo.fundo))
    }

    private static func retrato(_ nome: String, _ vista: AnyView, tamanho: CGSize = janela) -> Retrato {
        Retrato(nome: nome, tamanho: tamanho, vista: vista)
    }

    // MARK: - os dados de exemplo

    private static let fontes: [PainelEspelhar.Fonte] = [
        .init(id: "tela:1", icone: "laptopcomputer", nome: "Tela interna", detalhe: "1512 × 982", detalheMono: true),
        .init(id: "tela:2", icone: "display", nome: "Monitor externo", detalhe: "1920 × 1200", detalheMono: true),
    ] + fontesDaTelaEstendida + [
        .init(id: "camera:1", icone: "web.camera", nome: "Câmera integrada", detalhe: T("Câmera"), detalheMono: false),
        .init(id: "camera:2", icone: "web.camera", nome: "Câmera do telefone de exemplo", detalhe: T("Câmera"), detalheMono: false),
    ]

    // A primeira release não oferece monitor virtual; a fixture segue o mesmo portão do produto.
    private static var fontesDaTelaEstendida: [PainelEspelhar.Fonte] {
#if QUALL_TELA_ESTENDIDA_FUTURA
        return [
            .init(id: "tela-estendida", icone: "display.2", nome: T("Tela estendida"),
                  detalhe: T("Um monitor novo para cada aparelho"), detalheMono: false),
        ]
#else
        return []
#endif
    }

    private static let muitasFontes: [PainelEspelhar.Fonte] = fontes + [
        .init(id: "tela:3", icone: "display", nome: "Segundo monitor", detalhe: "2560 × 1440", detalheMono: true),
        .init(id: "camera:3", icone: "web.camera", nome: "Câmera virtual de exemplo", detalhe: T("Câmera"), detalheMono: false),
        .init(id: "camera:4", icone: "web.camera", nome: "Câmera USB de exemplo", detalhe: T("Câmera"), detalheMono: false),
    ]

    private static func espelhar(fontes f: [PainelEspelhar.Fonte] = fontes, escolhida: String? = "tela:1",
                                 carregando: Bool = false, som: Bool = true, avisos: [ItemDeAviso] = [],
                                 rede: PainelEspelhar.LinhaDaRede = .init(ok: true, rotulo: T("Rede automática · "), ip: "192.0.2.3")) -> some View {
        PainelEspelhar(fontes: f, escolhida: escolhida, carregando: carregando, podeAtualizar: !carregando,
                       mostrarSom: escolhida?.hasPrefix("tela") == true, comSom: .constant(som), somDesligado: false,
                       avisos: avisos, rede: rede, podeEspelhar: escolhida != nil,
                       aoEscolher: { _ in }, aoAtualizar: {}, aoEspelhar: {}, aoAbrirAjustes: {})
    }

    private static func dados(transmitindo: Bool = false, haPares: Bool = false, anunciando: Bool = true,
                               origem: String = "Tela interna", tela: Bool = true, comSom: Bool = true,
                               par: String = "Tablet de exemplo", receptores: [Emissor.ReceptorAtivo] = [],
                               maisUm: Bool = false, imagem: String = "1512×982", detalhes: [String] = [],
                               avisos: [ItemDeAviso] = [], encerrando: Bool = false, gravando: Bool = false) -> DadosDaEspera {
        DadosDaEspera(
            transmitindo: transmitindo, encerrando: encerrando, nome: nome, origem: origem, origemEhTela: tela,
            comSom: comSom, anunciando: anunciando, pin: "482719", endereco: "192.0.2.3:7877", haPares: haPares,
            par: par, noArDesde: transmitindo ? Date(timeIntervalSinceNow: -252) : nil, receptores: receptores,
            esperandoMaisUm: maisUm, imagem: imagem, rede: T("Automática"), detalhes: detalhes, avisos: avisos,
            rotuloDoParar: encerrando ? T("Encerrando…")
                : (gravando ? T("Parar e salvar a gravação") : (transmitindo ? T("Parar de espelhar") : T("Cancelar"))))
    }

    private static func receptores(_ n: Int) -> [Emissor.ReceptorAtivo] {
        let nomes = ["Tablet de exemplo", "Tablet 2 de exemplo", "Telefone 1 de exemplo", "Telefone 2 de exemplo", "Telefone 3 de exemplo", "Telefone 4 de exemplo",
                     "Telefone 5 de exemplo", "Tablet 3 de exemplo"]
        let telas = ["1180 × 820 @2x", "1920 × 1200 @2x", "1218 × 562 @2x", "1600 × 720", "1560 × 720 @2x",
                     "667 × 375 @2x", "1520 × 720", "1133 × 744 @2x"]
        return (0..<n).map { i in
            Emissor.ReceptorAtivo(id: i, nome: nomes[i % nomes.count],
                                  monitor: "Quall — \(nomes[i % nomes.count]) · \(telas[i % telas.count])",
                                  resumo: "\(1800 + i * 137) quadros · \(3 + i % 3) IDR · captura+encode \(8 + i).4 ms")
        }
    }

    private static let contadores = [
        "1842 quadros · 4 IDR · captura+encode 9.8 ms",
        "som: 3120 quadros · 62.4 s capturados",
    ]

    private static func painel(_ dados: DadosDaEspera, detalhes: Bool = false) -> some View {
        PainelDaEspera(dados: dados, detalhesAbertos: .constant(detalhes), aoParar: {}, aoDesconectar: { _ in })
    }

    private static func camera(_ dados: DadosDaEspera, microfone: MicrofoneNaTela, gravacao: GravacaoNaTela,
                               avisos: [ItemDeAviso] = [], espacoLivre: String? = nil,
                               detalhes: Bool = false) -> some View {
        PainelDaCameraNaEspera(
            dados: dados,
            camera: DadosDaCamera(nome: "Câmera integrada", montada: true, microfone: microfone,
                                  gravacao: gravacao, avisos: avisos, espacoLivre: espacoLivre),
            previa: AnyView(LugarDaIlha(nome: "PreviaDaCamera (AppKit)")),
            espelharPrevia: .constant(true), detalhesAbertos: .constant(detalhes),
            aoMicrofone: {}, aoGravar: {}, aoParar: {}, aoAjustesDaCamera: {})
    }

    private static func sessao(_ emissor: Emissor.Fase = .inicial, receptor: Receptor.Fase = .fechado,
                               controle: Teleprompter.Fase? = nil) -> SessaoNaBarra? {
        RaizDaJanela.sessao(emissor: emissor, receptor: receptor, controle: controle)
    }

    private static func exibir(endereco: String = "192.0.2.4:7877", pin: String = "482", mensagem: String = "",
                               tipo: Aviso.Tipo = .ambar, precisaDePin: Bool = false, conectando: Bool = false) -> some View {
        PainelExibir(endereco: .constant(endereco), pin: .constant(pin), ultimoEndereco: "192.0.2.11:7877",
                     mensagem: mensagem, tipoDaMensagem: tipo, precisaDePin: precisaDePin, conectando: conectando,
                     ocupado: conectando,
                     focoNoPinNoRetrato: !conectando, aoConectar: {})
    }

    private static func video(numeros: Bool, acusacao: String?, tamanho: CGSize, caladoPelaCamera: Bool = false,
                              engrenagem: Bool = false) -> AnyView {
        let linhas: [LinhaDeNumero] = [
            .init("1920x1200 · High 5.2 · recebidos 18422 · enfileirados 18420 · 29.9 fps"),
            .init("primeira imagem 212 ms · decode p50 3.10 ms · p95 5.42 ms · marca ok 612 / erro 0 / repetida 3"),
            .init("idrs 5 · sem_parametros 0 · falhas_sessao 0"),
            .init("imagem: rupturas 0 · suspeitos 0 · pior rajada 0 · retidos 0 · sem_referencia_ms [n=0]"),
        ] + (acusacao.map { [LinhaDeNumero($0, forte: true, marcada: true)] } ?? []) + [
            .init("perda: exata 0.02 % · teto 0.31 % · tarde demais 0"),
            .init("{\"rtp_recebidos\":18422,\"nack_enviados\":4,\"pli_enviados\":1,\"jitter_ms\":2.1}", linhas: 2),
        ]
        return AnyView(
            ZStack(alignment: .bottom) {
                LugarDaIlha(nome: "VistaDeVideo (AppKit)")
                BarraDoVideo(nome: "Tablet de exemplo", detalhe: "Tela · " + T("pareado agora"), temSom: true,
                             somComProblema: caladoPelaCamera, somAMostra: caladoPelaCamera,
                             mudo: .constant(false), volume: .constant(0.8), podeControlar: true, parando: false,
                             numerosAbertos: .constant(numeros), numeros: linhas, acusacao: acusacao,
                             estadoDoSom: caladoPelaCamera ? "som: mudo: a câmera do Quall está ligada (numa chamada, ou pelo app dela)"
                                                           : "som: tocando, volume 80%",
                             somComACamera: .constant(false),
                             aoControlar: {}, aoAjustesDaCamera: engrenagem ? {} : nil, aoParar: {})
                    .padding(12)
            }
            .frame(width: tamanho.width, height: tamanho.height)
            .background(Color.black))
    }

    private static let prompters: [PainelControlar.Prompter] = [
        .init(id: "a", nome: "Tablet de exemplo", endpoint: "192.0.2.6:7979"),
        .init(id: "b", nome: "Tablet 2 de exemplo", endpoint: "192.0.2.5:7979"),
    ]

    private static func controlar(prompters p: [PainelControlar.Prompter] = prompters, endereco: String = "192.0.2.20:7979",
                                  mensagem: String = "", conectando: Bool = false) -> some View {
        PainelControlar(prompters: p, procurando: !conectando, endereco: .constant(endereco), pin: .constant(""),
                        ultimoEndereco: "192.0.2.6:7979", mensagem: mensagem, conectando: conectando,
                        encerrando: false, listaLigada: !conectando, mostrarVoltar: false,
                        aoConectarEm: { _ in }, aoConectar: {}, aoCancelar: {}, aoAbrirRoteiros: {}, aoVoltar: {})
    }

    private static func ajustes(sessao: Bool = false, rede: String? = nil, haPares: Bool = true) -> some View {
#if QUALL_TELA_ESTENDIDA_FUTURA
        PainelDeAjustes(
            redes: [(T("Automática"), nil), ("Wi-Fi · 192.0.2.3", "en0"), ("Ethernet — AX88179B · 192.0.2.8", "en12")],
            rede: .constant(rede),
            legendaDaRede: rede == nil ? T("O sistema escolhe o caminho a cada sessão.")
                : T("O vídeo sai só por esta rede. Se o outro aparelho não alcançar este Mac por ela, "
                  + "a sessão não sobe — escolha Automática."),
            escala: .constant(.dobro), escalaFixada: false,
            legendaDaEscala: T("Letra do tamanho da do Mac. Se a tela do aparelho tem menos de 1060 pixels de altura, o "
                + "macOS não aceita 2x nela: o monitor é desenhado maior e reduzido para a tela, sem sair 1:1."),
            a60: .constant(false), espelharDesligado: sessao, haPares: haPares, esquecerDesligado: sessao,
            versao: TelaDeAjustes.versao, aoEsquecer: {})
#else
        PainelDeAjustes(
            redes: [(T("Automática"), nil), ("Wi-Fi · 192.0.2.3", "en0"), ("Ethernet — AX88179B · 192.0.2.8", "en12")],
            rede: .constant(rede),
            legendaDaRede: rede == nil ? T("O sistema escolhe o caminho a cada sessão.")
                : T("O vídeo sai só por esta rede. Se o outro aparelho não alcançar este Mac por ela, "
                  + "a sessão não sobe — escolha Automática."),
            espelharDesligado: sessao, haPares: haPares, esquecerDesligado: sessao,
            versao: TelaDeAjustes.versao, aoEsquecer: {})
#endif
    }

    // MARK: - a lista

    private static var todos: [Retrato] {
        let conselho = ItemDeAviso(id: "c", texto: T("A conexão com %@ caiu.", "Tablet de exemplo") + " " + T("Esperando de novo com o mesmo PIN."),
                                   tipo: .ambar)
        return [
            retrato("01-espelhar", estudio(.espelhar) { espelhar() }),
            retrato("02-espelhar-avisos", estudio(.espelhar) {
                espelhar(escolhida: "camera:1", avisos: [
                    ItemDeAviso(id: "camera", texto: T("Falta a permissão de Câmera. Abra Ajustes do Sistema > Privacidade "
                                + "e Segurança > Câmera e habilite o Quall Studio."), tipo: .ambar, acao: T("Abrir os Ajustes do Sistema")),
                    ItemDeAviso(id: "conselho", texto: T("O outro aparelho não reconheceu este Mac."), tipo: .ambar,
                                acao: T("Esquecer aparelhos pareados")),
                    ItemDeAviso(id: "tp", texto: T("Não consegui reservar uma porta de rede neste Mac."), tipo: .vermelho),
                ], rede: .init(ok: false, rotulo: T("%@ — sem endereço agora", "en12"), ip: nil))
            }),
            retrato("03-espelhar-procurando", estudio(.espelhar) {
                espelhar(fontes: [], escolhida: nil, carregando: true, avisos: [
                    ItemDeAviso(id: "tp", texto: T("Não consegui reservar uma porta de rede neste Mac."), tipo: .vermelho,
                                aoFechar: {}),
                ], rede: .init(ok: false, rotulo: T("Sem rede"), ip: nil))
            }),
            retrato("04-espelhar-muitas-fontes", estudio(.espelhar) { espelhar(fontes: muitasFontes, escolhida: "tela:2") }),
            retrato("05-espera-sem-pares", estudio(.espelhar, sessao: sessao(.esperando)) { painel(dados()) }),
            retrato("06-espera-com-pares", estudio(.espelhar, sessao: sessao(.esperando)) {
                painel(dados(haPares: true, anunciando: false, comSom: false, avisos: [conselho]))
            }),
            retrato("07-no-ar", estudio(.espelhar, sessao: sessao(.transmitindo)) {
                painel(dados(transmitindo: true, detalhes: contadores))
            }),
        ] + retratosDaTelaEstendida + [
            retrato("12-camera-aguardando", estudio(.espelhar, sessao: sessao(.esperando)) {
                camera(dados(origem: "Câmera integrada", tela: false, comSom: false, imagem: "1920×1080"),
                       microfone: .desligado, gravacao: .parada)
            }),
            retrato("13-camera-no-ar-gravando", estudio(.espelhar, sessao: sessao(.transmitindo)) {
                camera(dados(transmitindo: true, origem: "Câmera integrada", tela: false, imagem: "1920×1080",
                              detalhes: ["1804 quadros · 4 IDR · captura+encode 6.1 ms",
                                         "som: 2210 quadros · 44.2 s capturados"], gravando: true),
                       microfone: .ligado, gravacao: .gravando(desde: ProcessInfo.processInfo.systemUptime - 768),
                       avisos: [ItemDeAviso(id: "r", texto: T("Gravando na pasta de gravações."), tipo: .info)],
                       espacoLivre: nil, detalhes: true)
            }),
            retrato("14-camera-gravando-sem-som", estudio(.espelhar, sessao: sessao(.esperando)) {
                camera(dados(haPares: true, origem: "Câmera integrada", tela: false, imagem: "1920×1080", gravando: true),
                       microfone: .semAcesso, gravacao: .gravando(desde: ProcessInfo.processInfo.systemUptime - 95),
                       avisos: [ItemDeAviso(id: "s", texto: GravadorLocal.textoSemSom, tipo: .ambar),
                                ItemDeAviso(id: "m", texto: T("O macOS negou o microfone ao Quall Studio."), tipo: .ambar)])
            }),
            retrato("15-exibir", estudio(.exibir) { exibir() }),
            retrato("16-exibir-pin-errado", estudio(.exibir) {
                exibir(pin: "", mensagem: T("PIN errado. Confira os seis dígitos na tela do outro aparelho e toque em "
                       + "Conectar de novo — cada tentativa vale por uma conexão."), tipo: .vermelho, precisaDePin: true)
            }),
            retrato("17-exibir-conectando", estudio(.exibir, sessao: sessao(receptor: .conectando)) {
                exibir(pin: "482719", mensagem: T("conectando e pareando…"), tipo: .info, conectando: true)
            }),
            retrato("18-video", video(numeros: false, acusacao: nil, tamanho: janela)),
            retrato("19-video-numeros-acusacao",
                    video(numeros: true, acusacao: "*** 3 quadro(s) exibidos com a referência quebrada — pior rajada 2 seguidos ***",
                          tamanho: janela)),
            retrato("20-video-minimo", video(numeros: false, acusacao: nil, tamanho: CGSize(width: 520, height: 400)),
                    tamanho: CGSize(width: 520, height: 400)),
            retrato("26-video-calado-pela-camera", video(numeros: false, acusacao: nil, tamanho: janela, caladoPelaCamera: true)),
            retrato("21-controlar", estudio(.controlar) { controlar() }),
            retrato("22-controlar-vazio-aviso", estudio(.controlar) {
                controlar(prompters: [], endereco: "192.0.2",
                          mensagem: T("Digite o endereço que a tela do prompter mostra (por exemplo 192.168.56.20:7979).")
                              .replacingOccurrences(of: "192.168.56.20", with: "192.0.2.20"))
            }),
            retrato("23-controlar-conectando", estudio(.controlar, sessao: sessao(controle: .abrindo)) {
                controlar(endereco: "192.0.2.6:7979", conectando: true)
            }),
            retrato("24-ajustes", AnyView(ajustes()), tamanho: PainelDeAjustes.tamanho),
            retrato("25-ajustes-com-sessao", AnyView(ajustes(sessao: true, rede: "en12", haPares: false)),
                    tamanho: PainelDeAjustes.tamanho),
            // R9: os ajustes da câmera, com uma câmera de foco fixo que trava exposição e balanço (o caso
            // provável da embutida) e com uma câmera que faz tudo o que o Mac deixa.
            retrato("27-ajustes-da-camera-exposicao", ajustesDaCamera(.exposicao, AjustesDaCamera(travaExposicao: true)),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("28-ajustes-da-camera-iso", ajustesDaCamera(.isoEObturador, .padrao), tamanho: tamanhoDosAjustesDaCamera),
            retrato("29-ajustes-da-camera-balanco", ajustesDaCamera(.balanco, AjustesDaCamera(travaBalanco: true)),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("30-ajustes-da-camera-foco-fixo", ajustesDaCamera(.foco, .padrao), tamanho: tamanhoDosAjustesDaCamera),
            retrato("31-ajustes-da-camera-foco", ajustesDaCamera(.foco, AjustesDaCamera(foco: .travado), completa: true,
                                                                 pilula: TextosDosAjustes.pilulaDoFoco),
                    tamanho: tamanhoDosAjustesDaCamera),
            // R9b: o Mac que filma com a opção ligada e um receptor acabando de mexer; o vídeo recebido com a
            // engrenagem; e a janela da câmera do outro lado — um iPhone (tudo), um Windows (brilho, ganho,
            // obturador em log2), o próprio Mac (só as travas) e a opção desligada no filmador.
            retrato("32-ajustes-da-camera-controlado-por", controladoPorRemoto(), tamanho: tamanhoDoFilmadorRemoto),
            retrato("33-video-com-ajustes-da-camera", video(numeros: false, acusacao: nil, tamanho: janela, engrenagem: true)),
            retrato("34-camera-remota-iphone-iso", cameraRemota(.isoEObturador, Retratos.estadoDoIphone()),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("35-camera-remota-iphone-balanco", cameraRemota(.balanco, Retratos.estadoDoIphone()),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("36-camera-remota-iphone-foco", cameraRemota(.foco, Retratos.estadoDoIphone()),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("37-camera-remota-windows-exposicao", cameraRemota(.exposicao, Retratos.estadoDoWindows()),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("38-camera-remota-windows-ganho", cameraRemota(.isoEObturador, Retratos.estadoDoWindows()),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("39-camera-remota-mac-exposicao", cameraRemota(.exposicao, Retratos.estadoDoMac()),
                    tamanho: tamanhoDosAjustesDaCamera),
            retrato("40-camera-remota-nao-permitido", cameraRemota(.exposicao, Retratos.estadoDoIphone(situacao: "nao_permitido",
                                                                                                         auto: true)),
                    tamanho: tamanhoDosAjustesDaCamera),
            // 07/10: a câmera abriu no automático e há um ajuste guardado — "Usar meus ajustes" ao lado do
            // "Restaurar automático".
            retrato("41-ajustes-da-camera-meus-ajustes", ajustesDaCamera(.exposicao, .padrao, oferecerMeus: true),
                    tamanho: tamanhoDosAjustesDaCamera),
        ]
    }

    private static var retratosDaTelaEstendida: [Retrato] {
#if QUALL_TELA_ESTENDIDA_FUTURA
        return [
            retrato("08-no-ar-estendida-detalhes", estudio(.espelhar, sessao: sessao(.transmitindo)) {
                painel(dados(transmitindo: true, origem: T("Tela estendida"), receptores: receptores(1), maisUm: true,
                              imagem: "1180×820 · 30", detalhes: contadores), detalhes: true)
            }),
            retrato("09-varios-2", estudio(.espelhar, sessao: sessao(.transmitindo)) {
                painel(dados(transmitindo: true, origem: T("Tela estendida"), receptores: receptores(2), maisUm: true))
            }),
            retrato("10-varios-7", estudio(.espelhar, sessao: sessao(.transmitindo)) {
                painel(dados(transmitindo: true, origem: T("Tela estendida"), receptores: receptores(7), maisUm: true))
            }),
            retrato("11-varios-8-limite", estudio(.espelhar, sessao: sessao(.transmitindo)) {
                painel(dados(transmitindo: true, origem: T("Tela estendida"), receptores: receptores(8), maisUm: false))
            }),
        ]
#else
        return []
#endif
    }

    private static let tamanhoDosAjustesDaCamera = CGSize(width: PainelDosAjustesDaCamera.largura, height: 430)
    private static let tamanhoDoFilmadorRemoto = CGSize(width: PainelDosAjustesDaCamera.largura, height: 510)

    /// O painel do Mac que filma, com "Controlado por" e a opção ligada no pé (R9b).
    private static func controladoPorRemoto() -> AnyView {
        let caps = CapacidadesDaCamera(exposicaoContinua: true, exposicaoUmaVez: true, exposicaoTravada: true,
                                       pontoDeExposicao: true, balancoContinuo: true, balancoUmaVez: true,
                                       balancoTravado: true, focoContinuo: true, focoUmaVez: true, focoTravado: true,
                                       pontoDeFoco: true)
        return AnyView(VStack(spacing: 0) {
            PainelDosAjustesDaCamera(nome: "Câmera integrada", plano: PlanoDoPainel.doMac(caps),
                                     ajustes: AjustesDaCamera(travaExposicao: true), pilula: nil, recado: nil,
                                     controladoPor: "Tablet de exemplo", aba: .constant(.exposicao), aoMudar: { _ in },
                                     aoRestaurar: {}, aoEfeitos: {})
            LinhaDoControleRemoto(ligadaNoRetrato: true)
        }
        .background(Estilo.fundo))
    }

    private static func cameraRemota(_ aba: AbaDosAjustes, _ e: EstadoDaCameraRemota?) -> AnyView {
        guard let e, let p = PlanoRemotoDoPainel.de(e) else { return AnyView(Text(verbatim: "sem painel")) }
        return AnyView(PainelRemotoDaCamera(plano: p, aba: .constant(aba), aoPedir: { _ in }, aoRestaurar: {})
            .background(Estilo.fundo))
    }

    /// Um iPhone filmando (as capacidades do exemplo do contrato, à moda do iOS).
    private static func estadoDoIphone(situacao: String = "pronto", auto: Bool = false) -> EstadoDaCameraRemota? {
        let ajuste = auto ? #"{"exposicao":"auto","ev":0.333,"travaExposicao":false,"balanco":"luzDoDia","foco":"auto"}"#
            : #"{"exposicao":"manual","iso":400,"obturadorNs":16666667,"balanco":"kelvin","kelvin":5200,"foco":"manual","focoPosicao":0.35}"#
        return EstadoDaCameraRemota.ler(#"""
            {"situacao":"\#(situacao)","capacidades":{"plataforma":"ios","nomeDaCamera":"Telefone de exemplo — Traseira",
              "controles":{"exposicao":{"valores":["auto","manual"]},"ev":{"min":-2,"max":2,"passo":0.333},
               "travaExposicao":{},"iso":{"min":25,"max":2000,"inteiro":true},
               "obturadorNs":{"min":100000,"max":33333333,"inteiro":true},
               "balanco":{"valores":["auto","incandescente","fluorescente","luzDoDia","nublado","kelvin"]},
               "kelvin":{"min":2000,"max":10000,"passo":100,"inteiro":true},"travaBalanco":{},
               "foco":{"valores":["auto","travado","manual"]},"focoPosicao":{"min":0,"max":1,"passo":0.01},"toque":{}},
              "limites":{"antiCintilacao":"ios_cintilacao"}},
             "ajuste":\#(ajuste),
             "lido":{"iso":400,"obturadorNs":16666667,"kelvin":5150,"abertura":1.8,"divergentes":[]},"autor":null}
            """#)
    }

    private static func estadoDoWindows() -> EstadoDaCameraRemota? {
        EstadoDaCameraRemota.ler(#"""
            {"situacao":"pronto","capacidades":{"plataforma":"windows","nomeDaCamera":"Logi C920 HD Pro",
              "controles":{"exposicao":{"valores":["auto","manual"]},
               "ev":{"min":-64,"max":64,"passo":1,"inteiro":true,"unidade":"brilho","origem":128},
               "iso":{"min":0,"max":255,"passo":1,"inteiro":true,"unidade":"ganho"},
               "obturadorNs":{"min":1000000,"max":33333333,"inteiro":true,"escala":"log2"},
               "antiCintilacao":{"valores":["50","60","desligada"]},
               "balanco":{"valores":["auto","kelvin"]},"kelvin":{"min":2000,"max":6500,"passo":10,"inteiro":true}},
              "limites":{"travaExposicao":"camera_nao_oferece","travaBalanco":"camera_nao_oferece",
                         "foco":"camera_nao_oferece","focoPosicao":"camera_nao_oferece","toque":"camera_nao_oferece"}},
             "ajuste":{"exposicao":"manual","ev":4,"iso":64,"obturadorNs":31250000,"antiCintilacao":"60"},
             "lido":{"iso":64,"obturadorNs":31250000},"autor":"Mac de exemplo"}
            """#)
    }

    private static func estadoDoMac() -> EstadoDaCameraRemota? {
        let caps = CapacidadesDaCamera(exposicaoContinua: true, exposicaoTravada: true, pontoDeExposicao: true,
                                       balancoContinuo: true, balancoTravado: true)
            .jsonRemoto(nomeDaCamera: "Câmera integrada")
        return EstadoDaCameraRemota.ler(#"{"situacao":"pronto","capacidades":\#(caps),"ajuste":{"exposicao":"auto","travaExposicao":true,"balanco":"auto","travaBalanco":false,"foco":"auto"},"lido":{}}"#)
    }

    private static func ajustesDaCamera(_ aba: AbaDosAjustes, _ a: AjustesDaCamera, completa: Bool = false,
                                        pilula: String? = nil, oferecerMeus: Bool = false) -> AnyView {
        let caps = completa
            ? CapacidadesDaCamera(exposicaoContinua: true, exposicaoUmaVez: true, exposicaoTravada: true, pontoDeExposicao: true,
                                  balancoContinuo: true, balancoUmaVez: true, balancoTravado: true, focoContinuo: true,
                                  focoUmaVez: true, focoTravado: true, pontoDeFoco: true)
            : CapacidadesDaCamera(exposicaoContinua: true, exposicaoTravada: true, pontoDeExposicao: true,
                                  balancoContinuo: true, balancoTravado: true)
        return AnyView(PainelDosAjustesDaCamera(nome: "Câmera integrada", plano: PlanoDoPainel.doMac(caps), ajustes: a,
                                                pilula: pilula, recado: nil, aba: .constant(aba), aoMudar: { _ in },
                                                aoRestaurar: {}, aoEfeitos: {}, oferecerMeus: oferecerMeus)
            .background(Estilo.fundo))
    }
}
