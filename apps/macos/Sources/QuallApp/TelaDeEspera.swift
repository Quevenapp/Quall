import QuallCaptureKit
import QuallIdiomaKit
import SwiftUI

/// A peça central do fluxo, herdada de `apps/ios/Quall/App/TelaDeEspera.swift` — que é o único
/// lugar do projeto onde este discurso já está provado em produto.
///
/// > "A espera precisa ser visível e cancelável. Sem isso, o usuário concede gravação de tela, vê
/// > o indicador vermelho do sistema e não entende por que nada acontece. Uma tela de espera muda
/// > é a diferença entre 'está esperando você' e 'travou'."
///
/// # A frase que esta tela nunca diz
///
/// "Escolha para onde mandar." Ela não diz porque não pode: `tracks` só vale em `quall_host` e não
/// há renegociação, então **quem espelha hospeda e espera** (dívida 1). O app não tem uma lista de
/// destinos porque não existe uma. O que ele mostra é o que basta para **ser encontrado**: PIN,
/// endereço, nome. (O QR que repetia o PIN e o endereço saiu em 24/09/2026, por decisão do Pessoa Exemplo.)
///
/// # A manchete muda com o que este Mac já sabe
///
/// | | manchete | secundário |
/// |---|---|---|
/// | sem pares conhecidos | **o letreiro do PIN** | "ou pelo endereço" e o chip |
/// | com pares conhecidos | "Aparelhos pareados entram direto." e o chip | "Aparelho novo? PIN 482 719" |
///
/// **O PIN nunca some.** `haParesConhecidos` quer dizer "conheço **algum** par", não "conheço
/// **este**": quem está chegando pode ser um aparelho novo, e para ele os seis dígitos são o
/// único caminho. Ele desce de tamanho, nunca fica atrás de um toque.
///
/// # Os estados (`docs/telas-estudio.md` §7.4)
///
/// Esperando (com e sem pares), no ar com um aparelho, a tela estendida com vários (uma linha por
/// receptor, e o cartão "mais um aparelho" enquanto houver vaga) e a câmera pela espera, em duas
/// colunas: a prévia com os três controles redondos à esquerda, a informação à direita (§11.4).
///
/// Esta vista só adapta o `Emissor` ao `PainelDaEspera` e ao `PainelDaCameraNaEspera`, que recebem
/// valores simples (e são o que os retratos de bancada desenham).
struct TelaDeEspera: View {
    @EnvironmentObject private var emissor: Emissor
    /// Os contadores começam abertos numa corrida de bancada (as capturas da janela os leem) e
    /// fechados no produto (§6.6: "contadores ficam no diagnóstico").
    @State private var detalhesAbertos = Argumentos.lidos().modoDeBancada

    var body: some View {
        if let d = emissor.dono, let g = emissor.gravador {
            CameraDaEspera(dono: d, gravador: g, dados: dados, detalhesAbertos: $detalhesAbertos)
        } else {
            PainelDaEspera(dados: dados, detalhesAbertos: $detalhesAbertos,
                           aoParar: { emissor.encerrar() },
                           aoDesconectar: { emissor.desconectar($0) })
        }
    }

    private var dados: DadosDaEspera {
        let encerrando = emissor.fase == .encerrando
        let transmitindo = emissor.fase == .transmitindo || (encerrando && !emissor.receptores.isEmpty)
        let fonte = emissor.fonteEscolhida
        let gravando = emissor.gravador?.estado.ocupada == true
        var avisos: [ItemDeAviso] = []
        if !emissor.conselho.isEmpty {
            avisos.append(ItemDeAviso(id: "conselho", texto: emissor.conselho, tipo: .ambar,
                                      acao: emissor.ofereceDesparear ? T("Esquecer aparelhos pareados") : nil,
                                      aoTocar: { emissor.esquecerPares() }))
        }
        return DadosDaEspera(
            transmitindo: transmitindo,
            encerrando: encerrando,
            nome: emissor.nome,
            origem: fonte?.nome ?? "",
            origemEhTela: fonte?.ehTela ?? true,
            comSom: emissor.comSom,
            anunciando: emissor.anunciandoPorMDNS,
            pin: emissor.pin,
            endereco: emissor.enderecoParaDigitar,
            haPares: emissor.haParesConhecidos,
            par: emissor.par,
            noArDesde: emissor.noArDesde,
            receptores: emissor.receptores,
            esperandoMaisUm: emissor.esperandoMaisUm,
            imagem: DadosDaEspera.imagem(de: fonte),
            rede: rede,
            detalhes: [emissor.resumoDaTransmissao, emissor.resumoDoAudio].filter { !$0.isEmpty },
            avisos: avisos,
            rotuloDoParar: encerrando ? T("Encerrando…")
                : (gravando ? T("Parar e salvar a gravação") : (transmitindo ? T("Parar de espelhar") : T("Cancelar"))))
    }

    /// Por onde o vídeo sai: a rede escolhida nos Ajustes, ou "Automática".
    private var rede: String {
        guard let bsd = emissor.redeEscolhida else { return T("Automática") }
        switch emissor.redes.first(where: { $0.bsd == bsd })?.tipo {
        case .wifi?: return T("Wi-Fi")
        case .ethernet?: return T("Cabo")
        case .outra?: return bsd
        case nil: return T("%@, sem endereço", bsd)
        }
    }
}

/// O que a espera mostra, em valores simples.
struct DadosDaEspera {
    var transmitindo: Bool
    var encerrando: Bool
    var nome: String
    var origem: String
    var origemEhTela: Bool
    var comSom: Bool
    var anunciando: Bool
    var pin: String
    var endereco: String?
    var haPares: Bool
    var par: String
    var noArDesde: Date?
    var receptores: [Emissor.ReceptorAtivo]
    var esperandoMaisUm: Bool
    var imagem: String
    var rede: String
    var detalhes: [String]
    var avisos: [ItemDeAviso]
    var rotuloDoParar: String

    /// A imagem da origem no formato do cartão (§7.4, "L×A · fps"): "1512×982" numa tela, "1180×820 · 30"
    /// na tela estendida (o detalhe dela é "novo monitor · 1180 × 820 @2x · 30 fps"). O fps da tela
    /// comum não é dito, porque a origem não o carrega.
    static func imagem(de fonte: FonteDeCaptura?) -> String {
        guard var d = fonte?.detalhe, !d.isEmpty else { return "—" }
        #if QUALL_TELA_ESTENDIDA_FUTURA
        // O prefixo nas duas línguas: o catálogo pode ter sido montado antes de o seletor trocar o idioma.
        for prefixo in Idioma.allCases.map({ T("novo monitor · ", em: $0) }) where d.hasPrefix(prefixo) {
            d = String(d.dropFirst(prefixo.count))
        }
        #endif
        return d.replacingOccurrences(of: " × ", with: "×")
            .replacingOccurrences(of: " @2x", with: "")
            .replacingOccurrences(of: " fps", with: "")
    }
}

/// **A instrução da espera** (§6.4 e §11.1): "No outro aparelho, abra o Quall Studio em **Exibir** e
/// escolha **{nome}** na lista, ou digite o endereço abaixo." — e, na tela, "A **Tela interna** vai
/// com o som." Montada por pedaços, e não por markdown: o nome do aparelho é texto de fora.
struct InstrucaoDaEspera: View {
    let nome: String
    let anunciando: Bool
    let origem: String?
    let comSom: Bool
    var tamanho: CGFloat = 15

    var body: some View {
        // As frases inteiras, com `%@` onde entra o destaque: a ordem das palavras é da língua.
        var t = anunciando
            ? Text.comDestaques(T("No outro aparelho, abra o Quall Studio em %@ e escolha %@ na lista, ou digite o endereço abaixo."),
                                [T("Exibir"), nome], forte)
            : Text.comDestaques(T("No outro aparelho, abra o Quall Studio em %@ e digite o endereço abaixo."), [T("Exibir")], forte)
        if let origem, !origem.isEmpty {
            t = t + Text(" ") + Text.comDestaques(comSom ? T("A %@ vai com o som.") : T("A %@ vai sem som."), [origem], forte)
        }
        return t
            .font(.system(size: tamanho))
            .foregroundColor(Estilo.texto2)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func forte(_ s: String) -> Text {
        Text(s).fontWeight(.semibold).foregroundColor(Estilo.texto)
    }
}

/// O "há 04:12" ao lado da pílula NO AR.
struct TempoNoAr: View {
    let desde: Date?

    var body: some View {
        if let desde {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(T("há %@", GravadorLocal.duracaoLegivel(max(0, ctx.date.timeIntervalSince(desde)))))
                    .font(Estilo.mono(13))
                    .foregroundColor(Estilo.texto2)
            }
        }
    }
}

/// **A espera, só a vista** (§7.4): esperando, no ar com um aparelho, e a tela estendida com vários.
struct PainelDaEspera: View {
    let dados: DadosDaEspera
    @Binding var detalhesAbertos: Bool
    let aoParar: () -> Void
    let aoDesconectar: (Int) -> Void

    var body: some View {
        Group {
            if dados.transmitindo {
                noAr
            } else {
                esperando
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, dados.transmitindo ? 32 : 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrilhoDeFundo(cor: dados.transmitindo ? Estilo.noAr : Estilo.aguardando, intensidade: 0.12,
                                  centro: UnitPoint(x: 0.5, y: 0)))
    }

    // MARK: - esperando

    private var esperando: some View {
        VStack(spacing: 0) {
            PilulaDeEstado(luz: .aguardando, palavra: T("Aguardando"))
            Text(T("Pronto para espelhar"))
                .font(Estilo.titulo(32))
                .foregroundColor(Estilo.texto)
                .padding(.top, 14)
            InstrucaoDaEspera(nome: dados.nome, anunciando: dados.anunciando,
                              origem: dados.origemEhTela ? dados.origem : nil, comSom: dados.comSom)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.top, 10)

            if dados.haPares {
                Text(T("Aparelhos pareados entram direto."))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Estilo.texto)
                    .padding(.top, 28)
                ChipDeEndereco(endereco: dados.endereco, tamanho: 17).padding(.top, 12)
                (Text(T("Aparelho novo? PIN") + " ") + Text(Estilo.pinEspacado(dados.pin)).font(Estilo.mono(14, peso: .semibold)))
                    .font(.system(size: 14))
                    .foregroundColor(Estilo.texto2)
                    .textSelection(.enabled)
                    .accessibilityLabel(T("Aparelho novo?") + " " + Estilo.pinFalado(dados.pin))
                    .padding(.top, 14)
            } else {
                RotuloDeSecao(T("Na primeira vez, o PIN")).padding(.top, 24)
                LetreiroDoPin(pin: dados.pin).padding(.top, 10)
                HStack(spacing: 10) {
                    Text(T("ou pelo endereço")).font(.system(size: 13)).foregroundColor(Estilo.texto3)
                    ChipDeEndereco(endereco: dados.endereco)
                }
                .padding(.top, 16)
            }

            if !dados.avisos.isEmpty {
                ListaDeAvisos(itens: dados.avisos).frame(maxWidth: 520).padding(.top, 16)
            }

            Spacer(minLength: 14)

            HStack(spacing: 12) {
                Text(dados.anunciando ? T("Aparecendo na lista dos outros aparelhos")
                                      : T("Sem anúncio na rede — use o endereço"))
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.texto3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: aoParar) { RotuloDeBotao(dados.rotuloDoParar, atalho: "esc") }
                    .buttonStyle(.quall(.secundario))
                    .keyboardShortcut(.cancelAction)
                    .disabled(dados.encerrando)
            }
        }
    }

    // MARK: - no ar

    private var varios: Bool { dados.receptores.count > 1 }
    /// A partir de três receptores, as linhas encolhem para 36 e o "mais um" vira uma linha (§11.4).
    private var compacto: Bool { dados.receptores.count >= 3 }

    private var noAr: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PilulaDeEstado(luz: .noAr, palavra: T("No ar"))
                TempoNoAr(desde: dados.noArDesde)
            }
            Text(T("Espelhando para"))
                .font(.system(size: 15))
                .foregroundColor(Estilo.texto2)
                .padding(.top, compacto ? 12 : 16)
            Text(varios ? T("%@ aparelhos", dados.receptores.count) : (dados.par.isEmpty ? T("outro aparelho") : dados.par))
                .font(Estilo.titulo(compacto ? 28 : 34))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)

            if varios {
                listaDeReceptores.padding(.top, compacto ? 12 : 16)
            } else {
                HStack(spacing: 10) {
                    CartaoDeNumero(chave: T("Origem"), valor: dados.origem.isEmpty ? "—" : dados.origem)
                    CartaoDeNumero(chave: T("Imagem"), valor: dados.imagem, mono: true)
                    CartaoDeNumero(chave: T("Rede"), valor: dados.rede)
                    CartaoDeNumero(chave: T("Som"), valor: dados.comSom && dados.origemEhTela ? T("Indo junto") : T("Sem som"),
                                   cor: dados.comSom && dados.origemEhTela ? Estilo.conectadoTexto : Estilo.texto2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                if dados.origemEhTela {
                    Aviso(texto: T("Tudo o que aparece nesta tela vai junto. Conteúdo protegido aparece preto do outro "
                          + "lado — é o macOS que faz isso, em qualquer app de espelhamento."), tipo: .info)
                        .padding(.top, 14)
                }
            }

            if dados.esperandoMaisUm {
                maisUm.padding(.top, compacto ? 10 : 12)
            }

            if !dados.avisos.isEmpty {
                ListaDeAvisos(itens: dados.avisos).padding(.top, 12)
            }

            Spacer(minLength: 12)

            if detalhesAbertos && !dados.detalhes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(dados.detalhes, id: \.self) { linha in
                        Text(linha).font(Estilo.mono(11)).foregroundColor(Estilo.texto2).lineLimit(1)
                    }
                }
                .textSelection(.enabled)
                .padding(.bottom, 10)
            }

            HStack(spacing: 12) {
                if !dados.detalhes.isEmpty {
                    BotaoRedondo(icone: "info", rotulo: detalhesAbertos ? T("Esconder os números") : T("Mostrar os números"),
                                 tamanho: 32) { detalhesAbertos.toggle() }
                }
                Spacer(minLength: 0)
                Button(action: aoParar) { RotuloDeBotao(dados.rotuloDoParar, parar: true, atalho: "esc") }
                    .buttonStyle(.quall(.perigo))
                    .keyboardShortcut(.cancelAction)
                    .disabled(dados.encerrando)
            }
        }
    }

    /// **Vários receptores** (tela estendida): um por linha, com o monitor dele e o que já passou.
    /// Desconectar tira aquele aparelho — e o monitor dele sai do Mac junto.
    private var listaDeReceptores: some View {
        VStack(spacing: compacto ? 6 : 8) {
            ForEach(dados.receptores) { r in
                HStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.system(size: compacto ? 13 : 15, weight: .medium))
                        .foregroundColor(Estilo.acentoClaro)
                        .frame(width: compacto ? 26 : 32, height: compacto ? 26 : 32)
                        .background(RoundedRectangle(cornerRadius: compacto ? 8 : 10, style: .continuous).fill(Estilo.acentoFundo))
                    VStack(alignment: .leading, spacing: compacto ? 0 : 2) {
                        HStack(spacing: 8) {
                            Text(r.nome).font(.system(size: compacto ? 13 : 14, weight: .semibold)).foregroundColor(Estilo.texto)
                                .lineLimit(1)
                            if compacto && !r.monitor.isEmpty {
                                Text(r.monitor).font(.system(size: 11)).foregroundColor(Estilo.texto2).lineLimit(1)
                            }
                        }
                        if !compacto && !r.monitor.isEmpty {
                            Text(r.monitor).font(.system(size: 12)).foregroundColor(Estilo.texto2).lineLimit(1)
                        }
                        if !r.resumo.isEmpty {
                            Text(r.resumo).font(Estilo.mono(10)).foregroundColor(Estilo.texto3).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(T("Desconectar")) { aoDesconectar(r.id) }
                        .buttonStyle(.quall(.secundario, altura: compacto ? 26 : 30))
                        .disabled(dados.encerrando)
                }
                .padding(.horizontal, 12)
                .frame(height: compacto ? 36 : 62)
                .background(RoundedRectangle(cornerRadius: compacto ? 10 : 14, style: .continuous).fill(Estilo.superficie))
                .overlay(RoundedRectangle(cornerRadius: compacto ? 10 : 14, style: .continuous)
                    .strokeBorder(Estilo.contorno, lineWidth: 1))
            }
        }
    }

    /// **Mais um aparelho**: a espera que fica aberta enquanto a tela estendida transmite. Cada
    /// aparelho que entra ganha o próprio monitor, com o formato da tela dele. Some no limite de 8,
    /// como antes (quem decide é o `Emissor`).
    private var maisUm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RotuloDeSecao(T("Mais um aparelho"))
                Spacer(minLength: 0)
                Text(T("Ele ganha um monitor só dele, no formato da tela dele."))
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.texto3)
                    .lineLimit(1)
            }
            if compacto {
                HStack(spacing: 18) {
                    (Text("PIN  ").font(.system(size: 12, weight: .semibold)).foregroundColor(Estilo.texto3)
                     + Text(Estilo.pinEspacado(dados.pin)).font(Estilo.mono(18, peso: .semibold)).foregroundColor(Estilo.texto))
                        .accessibilityLabel(Estilo.pinFalado(dados.pin))
                    Text(dados.endereco ?? T("sem rede"))
                        .font(Estilo.mono(18, peso: .semibold))
                        .foregroundColor(dados.endereco == nil ? Estilo.aguardandoTexto : Estilo.texto)
                }
                .textSelection(.enabled)
            } else {
                HStack(spacing: 14) {
                    LetreiroDoPin(pin: dados.pin, casa: CGSize(width: 34, height: 44), fonte: 24)
                    ChipDeEndereco(endereco: dados.endereco)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Estilo.superficie))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Estilo.contorno, lineWidth: 1))
    }
}

// MARK: - a câmera pela espera

/// **A câmera da espera** (a câmera comum com dono, R5 fase 4): a prévia (como espelho, o ajuste
/// local de sempre), o microfone, o Gravar e o Parar — gravar sem receptor, e o receptor entrando e
/// saindo sem tocar na câmera nem no arquivo. Adapta o dono e o gravador ao `PainelDaCameraNaEspera`.
private struct CameraDaEspera: View {
    @EnvironmentObject private var emissor: Emissor
    @Environment(\.openWindow) private var abrirJanela
    let dono: DonoDaCamera
    @ObservedObject var gravador: GravadorLocal
    let dados: DadosDaEspera
    @Binding var detalhesAbertos: Bool

    var body: some View {
        PainelDaCameraNaEspera(
            dados: dados,
            camera: DadosDaCamera(
                nome: dono.nomeDaCamera.isEmpty ? dados.origem : dono.nomeDaCamera,
                montada: dono.montado,
                microfone: DadosDaCamera.microfone(dono.microfone),
                gravacao: DadosDaCamera.gravacao(gravador.estado),
                avisos: avisosDaCamera,
                // O espaço que sobra no disco, gravando — estava no botão Gravar de antes.
                espacoLivre: gravador.estado.gravando
                    ? gravador.espacoLivre.map { String(format: T("%.1f GB livres"), Double($0) / 1_000_000_000) } : nil,
                pilula: dono.pilulaSobreAPrevia?.texto,
                iconeDaPilula: dono.pilulaSobreAPrevia?.icone ?? "lock.fill"),
            previa: AnyView(PreviaDaCamera(dono: dono, espelhar: emissor.espelharPrevia, escondida: false)),
            espelharPrevia: $emissor.espelharPrevia,
            detalhesAbertos: $detalhesAbertos,
            aoMicrofone: { dono.alternarMicrofone() },
            aoGravar: {
                if gravador.estado.ocupada { gravador.parar(motivo: "o botão Parar") }
                else { gravador.comecar(por: .toque) { _ in } }
            },
            aoParar: { emissor.encerrar() },
            aoAjustesDaCamera: { abrirJanela(id: JanelaDosAjustesDaCamera.id) })
    }

    /// Os recados da câmera, na ordem de antes: sem som, o microfone, o gravador, e o conselho.
    private var avisosDaCamera: [ItemDeAviso] {
        var a: [ItemDeAviso] = []
        if gravador.estado.gravando && !dono.microfone.ligado {
            a.append(ItemDeAviso(id: "semsom", texto: GravadorLocal.textoSemSom, tipo: .ambar))
        }
        if let m = dono.microfone.motivo { a.append(ItemDeAviso(id: "mic", texto: m, tipo: .ambar)) }
        if let r = gravador.recado { a.append(ItemDeAviso(id: "recado", texto: r.texto, tipo: r.grave ? .ambar : .info)) }
        return a + dados.avisos
    }
}

/// O que a câmera da espera mostra, em valores simples.
struct DadosDaCamera {
    var nome: String
    var montada: Bool
    var microfone: MicrofoneNaTela
    var gravacao: GravacaoNaTela
    var avisos: [ItemDeAviso]
    var espacoLivre: String?
    /// Sobre a prévia: o recado de 3 s depois de reaplicar uma trava, ou a pílula do ⌥-clique (R9).
    var pilula: String? = nil
    /// O ícone dela: o cadeado das travas, ou as ondas do "Controlado por" (R9b).
    var iconeDaPilula = "lock.fill"

    static func microfone(_ m: EstadoDoMicrofone) -> MicrofoneNaTela {
        switch m {
        case .desligado: return .desligado
        case .pedindo: return .ligando
        case .ligado: return .ligado
        case .recusado: return .semAcesso
        case .falhou: return .naoAbriu
        }
    }

    static func gravacao(_ e: EstadoDaGravacao) -> GravacaoNaTela {
        switch e {
        case .parada: return .parada
        case .abrindo: return .abrindo
        case .gravando(let desde): return .gravando(desde: desde)
        case .fechando: return .fechando
        }
    }
}

/// **A câmera pela espera, só a vista** (§7.4 e §11.4): duas colunas — a prévia num cartão de cantos
/// 14, "Prévia como espelho" e os três controles redondos à esquerda; a pílula, o título, o PIN e os
/// avisos à direita.
struct PainelDaCameraNaEspera: View {
    let dados: DadosDaEspera
    let camera: DadosDaCamera
    let previa: AnyView
    @Binding var espelharPrevia: Bool
    /// Os números (os contadores da sessão e, gravando, o espaço livre) atrás do ⓘ, abertos na bancada.
    @Binding var detalhesAbertos: Bool
    let aoMicrofone: () -> Void
    let aoGravar: () -> Void
    let aoParar: () -> Void
    /// O botão "Ajustes da câmera" junto da prévia (R9, `docs/controles-de-camera.md` §4.1). Sem ele, o
    /// botão não aparece.
    var aoAjustesDaCamera: (() -> Void)? = nil

    private static let larguraDaPrevia: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            // As duas colunas no meio da altura: a prévia é baixa (16:9 em 300 de largura) e, no alto,
            // deixaria meio painel vazio embaixo.
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 26) {
                colunaDaPrevia
                colunaDaInformacao
            }
            Spacer(minLength: 12)
            if detalhesAbertos && !numeros.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(numeros, id: \.self) { linha in
                        Text(linha).font(Estilo.mono(11)).foregroundColor(Estilo.texto2).lineLimit(1)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            }
            HStack(spacing: 12) {
                Text(dados.transmitindo ? T("O receptor pode sair e voltar: a câmera e a gravação continuam.")
                     : (dados.anunciando ? T("Aparecendo na lista dos outros aparelhos") : T("Sem anúncio na rede — use o endereço")))
                    .font(.system(size: 12))
                    .foregroundColor(Estilo.texto3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !numeros.isEmpty {
                    BotaoRedondo(icone: "info", rotulo: detalhesAbertos ? T("Esconder os números") : T("Mostrar os números"),
                                 tamanho: 32) { detalhesAbertos.toggle() }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrilhoDeFundo(cor: dados.transmitindo ? Estilo.noAr : Estilo.aguardando, intensidade: 0.12,
                                  centro: UnitPoint(x: 0.5, y: 0)))
    }

    private var numeros: [String] {
        dados.detalhes + (camera.espacoLivre.map { [$0] } ?? [])
    }

    private var colunaDaPrevia: some View {
        VStack(spacing: 10) {
            previa
                .frame(width: Self.larguraDaPrevia, height: Self.larguraDaPrevia * 9 / 16)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Estilo.contorno, lineWidth: 1))
                // O nome da câmera sobre a imagem: vidro preto a 85 % e só `texto` por cima (§11.1).
                .overlay(alignment: .topLeading) {
                    Text(camera.nome)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Estilo.texto)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if let aoAjustesDaCamera, camera.montada {
                        BotaoDosAjustesDaCamera(acao: aoAjustesDaCamera).padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let p = camera.pilula {
                        PilulaDaCamera(texto: p, icone: camera.iconeDaPilula).padding(.bottom, 8).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(T("Prévia como espelho")).font(.system(size: 12)).foregroundColor(Estilo.texto2)
                    .fixedSize()
                Interruptor(titulo: T("Prévia como espelho"), ligado: $espelharPrevia, pequeno: true)
            }
            .frame(width: Self.larguraDaPrevia)
            ControlesRedondos(
                microfone: camera.microfone,
                gravacao: camera.gravacao,
                semSom: camera.microfone != .ligado,
                montada: camera.montada,
                rotuloDoParar: dados.encerrando ? T("Encerrando…")
                    : (camera.gravacao.ocupada ? T("Parar e salvar") : (dados.transmitindo ? T("Parar") : T("Cancelar"))),
                pararDesligado: dados.encerrando,
                dicaDoMicrofone: T("O som do microfone vai junto da câmera, cru. Começa desligado; desligar fecha de verdade."),
                aoMicrofone: aoMicrofone, aoGravar: aoGravar, aoParar: aoParar)
                .padding(.top, 8)
        }
        .frame(width: Self.larguraDaPrevia)
    }

    private var colunaDaInformacao: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if dados.transmitindo {
                    PilulaDeEstado(luz: .noAr, palavra: T("No ar"))
                    TempoNoAr(desde: dados.noArDesde)
                } else {
                    PilulaDeEstado(luz: .aguardando, palavra: camera.montada ? T("Aguardando") : T("Abrindo"))
                }
            }
            if dados.transmitindo {
                Text(T("Enviando para"))
                    .font(.system(size: 14))
                    .foregroundColor(Estilo.texto2)
                    .padding(.top, 16)
                Text(dados.par.isEmpty ? T("outro aparelho") : dados.par)
                    .font(Estilo.titulo(28))
                    .foregroundColor(Estilo.texto)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 2)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        CartaoDeNumero(chave: T("Origem"), valor: camera.nome)
                        CartaoDeNumero(chave: T("Imagem"), valor: dados.imagem, mono: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        CartaoDeNumero(chave: T("Rede"), valor: dados.rede)
                        CartaoDeNumero(chave: T("Som"), valor: camera.microfone == .ligado ? T("Indo junto") : T("Sem som"),
                                       cor: camera.microfone == .ligado ? Estilo.conectadoTexto : Estilo.texto2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            } else {
                Text(T("Pronto para espelhar"))
                    .font(Estilo.titulo(24))
                    .foregroundColor(Estilo.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 12)
                InstrucaoDaEspera(nome: dados.nome, anunciando: dados.anunciando, origem: nil, comSom: false, tamanho: 13)
                    .padding(.top, 8)
                if dados.haPares {
                    Text(T("Aparelhos pareados entram direto."))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Estilo.texto)
                        .padding(.top, 16)
                    ChipDeEndereco(endereco: dados.endereco).padding(.top, 10)
                    (Text(T("Aparelho novo? PIN") + " ") + Text(Estilo.pinEspacado(dados.pin)).font(Estilo.mono(13, peso: .semibold)))
                        .font(.system(size: 13))
                        .foregroundColor(Estilo.texto2)
                        .accessibilityLabel(T("Aparelho novo?") + " " + Estilo.pinFalado(dados.pin))
                        .padding(.top, 10)
                } else {
                    RotuloDeSecao(T("Na primeira vez, o PIN")).padding(.top, 16)
                    LetreiroDoPin(pin: dados.pin, casa: CGSize(width: 34, height: 46), fonte: 25).padding(.top, 8)
                    ChipDeEndereco(endereco: dados.endereco).padding(.top, 12)
                }
            }
            if !camera.avisos.isEmpty {
                ListaDeAvisos(itens: camera.avisos).padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
