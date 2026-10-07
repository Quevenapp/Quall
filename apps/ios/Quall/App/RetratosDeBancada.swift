// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import SwiftUI

/// **Os retratos das telas** (`docs/telas-estudio.md` §9 e §11.1): `--retrato-de-bancada <tela>` abre
/// o app direto numa tela do Estúdio de bolso desenhada com **valores de exemplo** — sem sessão, sem
/// câmera, sem rede e sem toque —, para o `retratos-das-telas.sh` fotografar com o
/// `idevicescreenshot`. `--retrato-deitado` prende a interface em paisagem antes (`Orientacao`).
///
/// É o que as vistas de valores simples compram: `VistaDoInicio`, `VistaDeEspelhar`, `VistaDaEspera`,
/// `MoldeDeConectar` e `FolhaDaEngrenagem` não leem o emissor nem a recepção, então dá para mostrá-las
/// em qualquer estado sem provocar o estado de verdade. A câmera no ar e a barra do vídeo não estão
/// aqui: elas só existem com a captura e a sessão de pé (o roteiro diz como chegar nelas).
///
/// **A exceção é "r5"** (30/09, para fotografar o pedido do Pessoa Exemplo para a horizontal): é a tela
/// "Teleprompter com câmera" **de verdade** — abre a câmera frontal (autorizada nas sondas da R5),
/// hospeda o prompter e espera um receptor na rede, como `--prompter-camera` —, presa em retrato ou,
/// com `--retrato-deitado`, em Paisagem (`.landscapeRight`: a lente à esquerda). A orientação vai
/// numa chave de jogar fora (`chaveDaOrientacaoDaR5`), e os ajustes da tela (lado do texto, divisão,
/// espelho da prévia) ficam nos padrões, só em memória: a foto mostra o automático e o 50/50, e as
/// escolhas da pessoa para a R5 não mudam. O texto é o roteiro guardado no aparelho. Por abrir câmera
/// e rede, o roteiro só a fotografa quando pedida (`QUALL_TELAS=r5`).
///
/// Nada disto roda sem o argumento, e o argumento só vale com o diagnóstico ligado (o mesmo cuidado
/// de `--camera-comum`; o padrão da compilação Debug) e só chega por `devicectl`/`idevicedebug`:
/// nenhum toque da pessoa abre esta tela. Com ele, `QuallApp.abrir` não faz nada (nem recupera
/// gravações, nem entra em papel de bancada), e a folha de Ajustes do retrato não grava nada.
enum RetratosDeBancada {
    /// As telas e estados, na ordem em que o roteiro fotografa.
    static let telas = [
        "inicio", "inicio-pares",
        "espelhar", "espelhar-cabo", "espelhar-sem-rede", "espelhar-conselho",
        "ajustes", "ajustes-limite", "permissao",
        "espera", "espera-pares", "espera-conselho", "espera-socorro", "no-ar", "encerrando",
        "exibir", "exibir-conectando", "exibir-erro",
        "controlar", "controlar-erro",
        // Fora da lista padrão do roteiro: abre a câmera e a rede (ver o cabeçalho).
        "r5",
        // O painel dos ajustes da câmera (R9, `docs/controles-de-camera.md` §4.2), com valores de
        // exemplo e **sem câmera**: a conta de "cabe sem rolar no iPhone 7" conferida na foto. Fora da
        // lista padrão (`QUALL_TELAS="ajustes-camera-exposicao …"`).
        "ajustes-camera-exposicao", "ajustes-camera-iso", "ajustes-camera-balanco", "ajustes-camera-foco",
        // O mesmo painel no receptor (R9b, `docs/controle-remoto-da-camera.md` §12), com o estado de
        // exemplo de um Android que filma: pronto, e com o controle remoto não permitido.
        "ajustes-camera-remota", "ajustes-camera-remota-bloqueada",
    ]

    /// A chave de jogar fora da orientação da R5 no retrato (a da pessoa é
    /// `OrientacaoDoPrompter.chaveDaTelaComCamera`).
    static let chaveDaOrientacaoDaR5 = "retrato-de-bancada.orientacao-da-r5"

    static var pedido: String? {
        guard Diagnostico.ligado else { return nil }
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--retrato-de-bancada"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static var deitado: Bool { CommandLine.arguments.contains("--retrato-deitado") }
}

/// A tela pedida, com os valores de exemplo. Os textos de aviso são frases que o app já diz.
struct TelaDeRetrato: View {
    let nome: String

    @State private var nomeDoAparelho = tr("iPhone de exemplo")
    @State private var endereco = ""
    @State private var pin = ""
    @State private var folha = true

    private let ip = "192.168.57.4"
    private let cabo = "169.254.81.198"
    private let porta: UInt16 = 7877

    var body: some View {
        conteudo
            .onAppear {
                Diario.dizer("retrato de bancada: \(nome)\(RetratosDeBancada.deitado ? " (deitado)" : "")")
                // A R5 prende a própria orientação (só a Paisagem de `.landscapeRight`); a máscara das
                // duas paisagens daqui, chegando depois, deixaria o sensor escolher entre elas.
                if RetratosDeBancada.deitado, nome != "r5" {
                    Orientacao.prender(.landscape, preferida: .landscapeRight) { porque in
                        Diario.dizer("retrato de bancada: o sistema não deitou a interface — \(porque)")
                    }
                }
            }
    }

    @ViewBuilder
    private var conteudo: some View {
        switch nome {
        case "inicio", "inicio-pares":
            inicio(pares: nome == "inicio-pares")
        case "ajustes":
            inicio(pares: false)
                .sheet(isPresented: $folha) { FolhaDaEngrenagem(fechar: {}, somenteLeitura: true) }
        case "ajustes-limite":
            // Uma câmera até 1080p30, sem 2K nem 4K (06/10): o cardápio apagado e a nota do limite.
            inicio(pares: false)
                .sheet(isPresented: $folha) {
                    FolhaDaEngrenagem(fechar: {}, somenteLeitura: true,
                                      tetosDeExemplo: [3_600: Optional(30), 8_160: Optional(30), 14_400: Optional<Int>.none, 32_400: Optional<Int>.none])
                }
        case "espelhar", "espelhar-cabo", "espelhar-sem-rede", "espelhar-conselho":
            espelhar
        case "permissao":
            TelaDePermissao()
        case "espera", "espera-pares", "espera-conselho", "espera-socorro", "no-ar", "encerrando":
            espera
        case "exibir", "exibir-conectando", "exibir-erro":
            exibir
        case "controlar", "controlar-erro":
            controlar
        case "r5":
            TelaDoPrompterComCamera(voltar: {}, orientacaoDoRetrato: RetratosDeBancada.deitado ? .paisagem : .retrato)
        case "ajustes-camera-exposicao", "ajustes-camera-iso", "ajustes-camera-balanco", "ajustes-camera-foco":
            ajustesDaCamera
        case "ajustes-camera-remota", "ajustes-camera-remota-bloqueada":
            ajustesDaCameraRemota
        default:
            Text(verbatim: "Retrato desconhecido: \(nome)\n\n" + RetratosDeBancada.telas.joined(separator: " "))
                .font(Estilo.mono(.footnote))
                .foregroundColor(Estilo.texto)
                .padding(24)
        }
    }

    /// O painel dos ajustes da câmera onde a câmera comum o põe (em pé, a metade de baixo; deitado, a
    /// metade direita), sobre o preto onde estaria a prévia. A aba de ISO em Manual, a do balanço em
    /// Kelvin e a do foco em Manual: os estados mais altos de cada uma.
    private var ajustesDaCamera: some View {
        let aba: PainelDosAjustesDaCamera.Aba
        var a = AjustesDaCamera()
        switch nome {
        case "ajustes-camera-iso": aba = .isoEObturador; a.exposicao = .manual; a.iso = 400; a.obturadorNs = 16_666_667
        case "ajustes-camera-balanco": aba = .balanco; a.balanco = .kelvin; a.kelvin = 5200
        case "ajustes-camera-foco": aba = .foco; a.foco = .manual; a.focoPosicao = 0.4
        default: aba = .exposicao
        }
        var c = CapacidadesDaCamera()
        c.exposicaoCustom = true; c.exposicaoUmaVez = true; c.exposicaoContinua = true; c.exposicaoTravada = true
        c.pontoDeExposicao = true; c.pontoDeFoco = true; c.focoContinuo = true; c.focoUmaVez = true
        c.focoTravado = true; c.lenteCustom = true; c.balancoContinuo = true; c.balancoUmaVez = true
        c.balancoTravado = true; c.ganhosCustom = true
        let controles = ControlesDaCamera()
        controles.preencherParaRetrato(a, c, FaixasDaCamera(isoMin: 23, isoMax: 736, obturadorMinNs: 22_000,
                                                            obturadorMaxNs: 1_000_000_000, evMin: -8, evMax: 8,
                                                            ganhoMax: 4, fps: 30),
                                       RegrasDosControles.Leitura(iso: 400, obturadorNs: 16_666_667, kelvin: 5200,
                                                                  abertura: 1.8, lente: 0.6))
        return ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { g in
                let painel = PainelDosAjustesDaCamera(controles: controles, abaInicial: aba) {}
                if g.size.width > g.size.height {
                    HStack(spacing: 0) { Spacer(minLength: 0); painel.frame(width: g.size.width / 2) }
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        painel.frame(height: min(g.size.height, max(g.size.height / 2, PainelDosAjustesDaCamera.alturaMinima)))
                    }
                }
            }
        }
    }

    /// O painel da câmera de quem filma, no receptor (R9b): as capacidades e o estado de exemplo de um
    /// Android com `MANUAL_SENSOR` (o exemplo do contrato §3.2), na aba ISO e obturador em Manual; o
    /// "bloqueada" com o controle remoto não permitido (tudo apagado, com os valores).
    private var ajustesDaCameraRemota: some View {
        let estado = RegrasDoControleRemoto.EstadoDoReceptor.de(json: """
        {"situacao":"\(nome == "ajustes-camera-remota-bloqueada" ? "nao_permitido" : "pronto")",
         "capacidades":{"plataforma":"android","nomeDaCamera":"Traseira","controles":{
          "exposicao":{"valores":["auto","manual"]},"ev":{"min":-2.0,"max":2.0,"passo":0.1},"travaExposicao":{},
          "antiCintilacao":{"valores":["auto","50","60","desligada"]},
          "iso":{"min":50,"max":3200,"inteiro":true,"analogicoMax":800},
          "obturadorNs":{"min":100000,"max":33333333,"inteiro":true},
          "balanco":{"valores":["auto","incandescente","fluorescente","luzDoDia","nublado","kelvin"]},
          "kelvin":{"min":2000,"max":10000,"passo":100,"inteiro":true},"travaBalanco":{},
          "foco":{"valores":["auto","travado","manual"]},"focoPosicao":{"min":0.0,"max":1.0,"passo":0.01},"toque":{}},
          "limites":{}},
         "ajuste":{"exposicao":"manual","iso":1600,"obturadorNs":16666666,"antiCintilacao":"60"},
         "lido":{"iso":1600,"obturadorNs":16666666,"kelvin":5150,"abertura":1.8,"divergentes":[]},
         "autor":null,"recusa":null}
        """)
        let camera = ControleRemotoDaCamera()
        if let estado { camera.preencherParaRetrato(estado) }
        return ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { g in
                let painel = PainelDaCamera(controles: camera, abaInicial: .isoEObturador) {}
                if g.size.width > g.size.height {
                    HStack(spacing: 0) { Spacer(minLength: 0); painel.frame(width: g.size.width / 2) }
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        painel.frame(height: min(g.size.height, max(g.size.height / 2, AbaDoPainelDaCamera.alturaMinima)))
                    }
                }
            }
        }
    }

    private func inicio(pares: Bool) -> some View {
        VistaDoInicio(nome: nomeDoAparelho, ip: ip, temPares: pares, diagnosticoLigado: false,
                      aoTocarNaMarca: {}, aoAbrirAjustes: {}, aoEscolher: { _ in })
    }

    private var espelhar: some View {
        let rede: VistaDeEspelhar.Rede
        switch nome {
        case "espelhar-sem-rede": rede = .nenhuma
        default: rede = .wifi(ip)
        }
        let modelo = Estilo.modeloDoAparelho
        return VistaDeEspelhar(
            origens: [.init(id: "tela", nome: tr("A tela deste %@", modelo), icone: modelo == "iPad" ? "ipad" : "iphone"),
                      .init(id: "traseira", nome: tr("Câmera traseira"), icone: "camera"),
                      .init(id: "frontal", nome: tr("Câmera frontal"), icone: "person.crop.square")],
            escolhida: "tela",
            nome: $nomeDoAparelho,
            rede: rede,
            notaDoEnlace: nome == "espelhar-cabo" ? Enderecos.notaDoEnlace(lan: ip, cabo: cabo, porta: porta) : nil,
            qualidade: "1080p · 30",
            conselho: nome == "espelhar-conselho"
                ? tr("Pareamentos esquecidos. Agora peça para o outro aparelho entrar de novo e "
                    + "digitar o PIN que está nesta tela.")
                : "",
            acaoDoConselho: nil,
            diagnosticoLigado: false,
            podeEspelhar: nome != "espelhar-sem-rede",
            aoEscolher: { _ in }, aoAcaoDoConselho: {}, aoEspelhar: {}, aoVoltar: {},
            aoAbrirAjustes: {}, aoTocarNoTitulo: {})
    }

    private var espera: some View {
        let estado: VistaDaEspera.Estado
        switch nome {
        case "no-ar": estado = .noAr
        case "encerrando": estado = .encerrando
        default: estado = .aguardando
        }
        return VistaDaEspera(
            estado: estado,
            nome: nomeDoAparelho,
            par: tr("MacBook de exemplo"),
            pin: "482719",
            endereco: "\(ip):\(porta)",
            notaDoEnlace: nil,
            temPares: nome == "espera-pares",
            conselho: nome == "espera-conselho"
                ? tr("Pareamentos esquecidos. Agora peça para o outro aparelho entrar de novo e "
                    + "digitar o PIN que está nesta tela.")
                : "",
            ofereceDesparear: false,
            mostrarSocorro: nome == "espera-socorro",
            aoDesparear: {}, aoAbrirSeletor: {}, aoCancelar: {})
    }

    private var exibir: some View {
        let conectando = nome == "exibir-conectando"
        var avisos: [ItemDeAviso] = []
        if conectando {
            avisos = [ItemDeAviso(id: "m", texto: tr("conectando e pareando…"), tom: .informacao, icone: "hourglass")]
        } else if nome == "exibir-erro" {
            avisos = [ItemDeAviso(id: "m", texto: tr("PIN errado. O emissor mantém o mesmo PIN — confira os seis dígitos."),
                                  tom: .vermelho)]
        }
        return MoldeDeConectar(
            tituloDoCabecalho: tr("Exibir"),
            titulo: tr("Assistir outro aparelho"),
            frase: tr("Digite o endereço e o PIN que aparecem na tela de quem está espelhando."),
            exemplo: "192.168.55.10:7877",
            endereco: $endereco,
            pin: $pin,
            ultimoEndereco: "192.168.57.2:7877",
            conectando: conectando,
            podeCancelar: conectando,
            avisos: avisos,
            voltar: conectando ? nil : {},
            cancelar: {},
            abrirAjustes: {},
            conectar: {}) { EmptyView() }
            .onAppear {
                if nome != "exibir" { endereco = "\(ip):\(porta)"; pin = "4827" }
            }
    }

    private var controlar: some View {
        MoldeDeConectar(
            tituloDoCabecalho: tr("Controlar"),
            titulo: tr("Controlar um teleprompter"),
            frase: tr("Do outro lado: Quall → Teleprompter → Mostrar o texto."),
            exemplo: "192.168.55.10:7979",
            endereco: $endereco,
            pin: $pin,
            ultimoEndereco: "192.168.57.2:7979",
            conectando: false,
            podeCancelar: false,
            avisos: nome == "controlar-erro"
                ? [ItemDeAviso(id: "f", texto: tr("O PIN tem seis dígitos."), tom: .vermelho)] : [],
            voltar: {},
            cancelar: {},
            abrirAjustes: nil,
            conectar: {}) {
            HStack(spacing: 10) {
                Button(tr("Colar endereço"), action: {})
                    .buttonStyle(.secundarioPequeno)
                Button(TextosDaPergunta.roteirosGuardados + " (2)", action: {})
                    .buttonStyle(.secundarioPequeno)
            }
        }
    }
}
