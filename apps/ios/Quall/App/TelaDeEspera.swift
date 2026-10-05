import SwiftUI

/// A peça central do fluxo.
///
/// > "A espera precisa ser visível e cancelável. Sem isso, o usuário concede gravação de tela, vê
/// > o indicador vermelho do sistema e não entende por que nada acontece. Uma tela de espera muda
/// > é a diferença entre 'está esperando você' e 'travou'."
///
/// Ela mostra quatro coisas, e o fluxo nomeia as quatro:
///
/// 1. **o PIN de 6 dígitos**, grande, porque é o que a pessoa vai ler em pé, do outro lado da
///    sala, e digitar em outro aparelho;
/// 2. **o nome** com que este aparelho aparece na rede;
/// 3. **o endereço IP em destaque** — que não é recurso avançado escondido: é o fallback
///    obrigatório, porque mDNS não é garantido (rede com multicast bloqueado, AP isolation);
/// 4. **o que fazer no outro aparelho**, em uma frase.
///
/// **O QR saiu em 24/09/2026, por decisão do Pessoa Exemplo.** O endereço e o PIN por extenso eram o
/// caminho garantido desde sempre, e agora são o único.
///
/// E um **Cancelar que funciona de verdade** — que aqui significa: o indicador vermelho apaga.
///
/// # A cara desde 30/09/2026 (`docs/telas-estudio.md` §6.4)
///
/// Esperando: o farol âmbar com dois anéis, a pílula AGUARDANDO, "Pronto para espelhar", a instrução
/// com o nome deste aparelho, o **letreiro** do PIN e o **chip** do endereço (que copia). Com pares, a
/// manchete vira "Aparelhos pareados entram direto." e o PIN desce para uma linha — **nunca some**:
/// `haParesConhecidos` quer dizer "conheço algum par", não "conheço este". No ar: a pílula NO AR,
/// "Espelhando para" e o par, o aviso do conteúdo protegido e o botão de perigo.
///
/// **A animação é só da espera, e só enquanto ninguém entrou.** Esta é a tela que fica no ar durante
/// a transmissão, e portanto é ela que aparece espelhada: conteúdo que muda a 60 Hz numa tela que
/// existe para esperar é bitrate gasto à toa. A appex só codifica depois que alguém entra
/// (`enviando`, em `ManipuladorDeTela.processSampleBuffer`), mas o app só fica sabendo pelo estado que
/// ela publica a 1 Hz: entre a appex começar a enviar e a fase virar `.transmitindo` passa até ~1 s,
/// e nesse intervalo o pulso vai junto para o codificador. Por isso o pulso para no primeiro sinal
/// que o app tem (a fase, com o par) e não volta no Encerrando, e a pílula ENCERRANDO não gira. Com
/// "reduzir movimento" ligado, fica parado sempre.
///
/// A tela só adapta o estado; o desenho é `VistaDaEspera`, que recebe valores simples.
struct TelaDeEspera: View {
    @EnvironmentObject private var emissor: Emissor
    private static let donoDaTelaAcesa = "espelhamento"

    var body: some View {
        VistaDaEspera(estado: estado,
                      nome: emissor.nome,
                      par: emissor.par,
                      pin: emissor.pin,
                      endereco: emissor.enderecoParaDigitar,
                      notaDoEnlace: emissor.notaDoEnlace,
                      temPares: emissor.haParesConhecidos,
                      conselho: emissor.conselho,
                      // O botão só aparece no caso em que ele é a ação certa: a retomada do
                      // pareamento falhou, e o núcleo não cai de volta para o PIN sozinho (dívida
                      // 22). Oferecer "esquecer pareamentos" o tempo todo seria convidar a pessoa a
                      // jogar fora o que faz o PIN ser pedido uma vez só.
                      ofereceDesparear: emissor.ofereceDesparear,
                      mostrarSocorro: emissor.fase != .transmitindo && emissor.segundosSemAppex >= 8,
                      aoDesparear: { emissor.esquecerPares() },
                      aoAbrirSeletor: { emissor.abrirOSeletorDeNovo() },
                      aoCancelar: { emissor.cancelar() })
            .overlay(alignment: .topTrailing) {
                MenuDaTelaAcesa()
                    .padding(.trailing, Estilo.margem)
                    .padding(.top, 8)
            }
            .onAppear { TelaAcesa.pedir(TelaDeEspera.donoDaTelaAcesa) }
            .onDisappear { TelaAcesa.soltar(TelaDeEspera.donoDaTelaAcesa) }
    }

    private var estado: VistaDaEspera.Estado {
        switch emissor.fase {
        case .transmitindo: return .noAr
        case .encerrando: return .encerrando
        default: return .aguardando
        }
    }
}

/// **A Espera**, só desenho (§6.4, com as emendas da §11.1 e §11.2).
///
/// O alto muda com os avisos: sem aviso, o farol com os dois anéis pulsando; com o conselho à vista,
/// o ícone fica sem os anéis; com o socorro de 8 s, o socorro aparece **no lugar** do farol. Deitado,
/// duas colunas: pílula, título, instrução e o conselho à esquerda; letreiro, chip e Cancelar à direita.
///
/// Conta de altura no iPhone 7, escala padrão, esperando e sem pares. Em pé (647 pt): 12 + farol 120
/// + 14 + pílula 28 + 12 + título 34 + 8 + instrução 63 + 18 + rótulo 16 + 10 + letreiro 60 + 14 +
/// "ou pelo endereço" 18 + 8 + chip 40 + nota 16 + 16 (espaço mínimo) + Cancelar 56 + 12 ≈ 575. Com o
/// conselho, o ícone sem anéis (60 no lugar de 120) e o aviso (~80): ≈ 609. Com o socorro no lugar do
/// farol (~158): ≈ 599. Com os dois ao mesmo tempo (raro), ≈ 690: aí a tela rola. Deitado (375 pt):
/// 12 + farol 120 + 14 + pílula 28 + 12 + título 34 + 8 +
/// instrução 63 + 12 ≈ 303 à esquerda; 12 + rótulo 16 + 10 + letreiro 60 + 14 + 18 + 8 + chip 40 + 16
/// + Cancelar 56 + 12 ≈ 262 à direita.
struct VistaDaEspera: View {
    enum Estado { case aguardando, noAr, encerrando }

    let estado: Estado
    let nome: String
    let par: String
    let pin: String
    let endereco: String?
    let notaDoEnlace: String?
    let temPares: Bool
    let conselho: String
    let ofereceDesparear: Bool
    let mostrarSocorro: Bool
    let aoDesparear: () -> Void
    let aoAbrirSeletor: () -> Void
    let aoCancelar: () -> Void

    @Environment(\.verticalSizeClass) private var classeVertical

    private var deitado: Bool { classeVertical == .compact }

    var body: some View {
        ZStack {
            FundoDoQuall(brilho: estado == .noAr ? Estilo.noAr : Estilo.aguardando, intensidade: 0.12)
            TelaQueCabe {
                Group {
                    if deitado {
                        HStack(alignment: .top, spacing: 28) {
                            // O conselho fica na coluna da esquerda, que é a mais baixa: na da direita,
                            // com o letreiro e o Cancelar, ele passava dos 375 pt do iPhone 7 deitado.
                            VStack(spacing: 0) {
                                if estado == .noAr { cabecaNoAr } else { cabecaAguardando }
                                avisoDoConselho
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: 0) {
                                if estado == .noAr {
                                    avisoDoConteudo
                                } else {
                                    BlocoDaEspera(nome: nome, pin: pin, endereco: endereco,
                                                  notaDoEnlace: notaDoEnlace, temPares: temPares,
                                                  parte: .codigos)
                                }
                                Spacer(minLength: 16)
                                botao
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        VStack(spacing: 0) {
                            if estado == .noAr {
                                cabecaNoAr
                                avisoDoConteudo.padding(.top, 24)
                            } else {
                                cabecaAguardando
                                BlocoDaEspera(nome: nome, pin: pin, endereco: endereco,
                                              notaDoEnlace: notaDoEnlace, temPares: temPares,
                                              parte: .codigos)
                            }
                            avisoDoConselho
                            Spacer(minLength: 16)
                            botao
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .colunaDoQuall(larga: deitado)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
        .dynamicTypeSize(...Estilo.tetoDaLetra)
    }

    // --- esperando ---------------------------------------------------------------------------------

    private var cabecaAguardando: some View {
        VStack(spacing: 0) {
            if mostrarSocorro {
                // No lugar do farol (§11.2): é a coisa a fazer agora, e fica onde o olho já está.
                socorroDoSeletor
                    .padding(.bottom, 16)
            } else {
                // `id` pelo pulso: um `repeatForever` só para quando a vista que o carrega sai da
                // árvore.
                FarolDaEspera(comAneis: conselho.isEmpty, pulsando: estado == .aguardando && par.isEmpty)
                    .id(estado == .aguardando && par.isEmpty)
                    .padding(.bottom, 14)
            }
            // Sem girar no Encerrando: vindo do ar, a appex ainda pode estar codificando esta tela.
            PilulaDeEstado(tom: .aguardando,
                           palavra: estado == .encerrando ? tr("Encerrando") : tr("Aguardando"))
            Text(tr("Pronto para espelhar"))
                .font(Estilo.titulo(.title))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            BlocoDaEspera(nome: nome, pin: pin, endereco: endereco, notaDoEnlace: notaDoEnlace,
                          temPares: temPares, parte: .instrucao)
                .padding(.top, 8)
        }
    }

    /// Aparece quando a appex não deu sinal de vida em oito segundos.
    ///
    /// A folha do sistema se dispensa com um toque para fora, e **nada avisa o app** quando isso
    /// acontece: o delegado do `RPBroadcastActivityViewController` nunca é chamado, e a folha é
    /// desenhada por outro processo. Sem esta saída, a pessoa ficaria numa tela de espera para
    /// uma transmissão que nunca começou — que é o mesmo sintoma que a tela existe para evitar.
    private var socorroDoSeletor: some View {
        VStack(spacing: 8) {
            Text(tr("A transmissão ainda não começou."))
                .font(Estilo.corpo(.subheadline, .semibold))
                .foregroundColor(Estilo.aguardandoTexto)
            // "Iniciar Transmissão" e o nome da appex são da folha do sistema: na língua dele.
            Text(LocalizedStringKey(tr("Toque abaixo e depois em **%@**, com **%@** marcado.",
                                       trSistema("Iniciar Transmissão"), Estilo.nomeDaAppex)))
                .font(Estilo.corpo(.footnote))
                .foregroundColor(Estilo.texto2)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("Abrir o seletor de transmissão"), action: aoAbrirSeletor)
                .buttonStyle(.secundarioPequeno)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Estilo.aguardando.opacity(0.12)))
    }

    // --- no ar -------------------------------------------------------------------------------------

    private var cabecaNoAr: some View {
        VStack(spacing: 0) {
            PilulaDeEstado(tom: .noAr, palavra: tr("No ar"))
                .padding(.top, 24)
            Text(tr("Espelhando para"))
                .font(Estilo.corpo(.callout))
                .foregroundColor(Estilo.texto2)
                .padding(.top, 20)
            Text(par.isEmpty ? tr("outro aparelho") : par)
                .font(Estilo.titulo(.title))
                .foregroundColor(Estilo.texto)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 4)
        }
    }

    private var avisoDoConteudo: some View {
        Aviso(texto: tr("Tudo o que aparece nesta tela vai junto. Conteúdo protegido aparece preto do "
              + "outro lado — é o iOS que faz isso, em qualquer app de espelhamento."),
              tom: .informacao, icone: "eye")
    }

    // --- comum -------------------------------------------------------------------------------------

    /// O conselho de hoje. O botão só aparece no caso em que ele é a ação certa: a retomada falhou, e
    /// o núcleo não cai de volta para o PIN sozinho (dívida 22).
    @ViewBuilder
    private var avisoDoConselho: some View {
        if !conselho.isEmpty {
            Aviso(texto: conselho,
                  acao: ofereceDesparear ? tr("Esquecer aparelhos pareados") : nil,
                  aoTocar: aoDesparear)
                .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var botao: some View {
        switch estado {
        case .aguardando:
            Button(tr("Cancelar"), action: aoCancelar)
                .buttonStyle(.secundario)
        case .noAr:
            Button(tr("Parar de espelhar"), action: aoCancelar)
                .buttonStyle(.perigo)
        case .encerrando:
            Button(tr("Encerrando…"), action: {})
                .buttonStyle(.secundario)
                .disabled(true)
        }
    }
}

/// O que se diz e mostra para quem vai entrar — o miolo da Espera, **o mesmo** na tela de espera do
/// espelhamento e no cartão de vidro da câmera (§6.4, §6.5).
///
/// A instrução, e então: sem pares, "NA PRIMEIRA VEZ, O PIN" com o letreiro e "ou pelo endereço" com o
/// chip; com pares, "Aparelhos pareados entram direto." com o chip e o PIN numa linha ("Aparelho novo?
/// PIN 482 719"). A nota do cabo fica embaixo do chip nos dois casos. `parte` separa a instrução dos
/// códigos, para as duas colunas da paisagem.
///
/// **A instrução fala da lista e do endereço** porque os dois emissores do iOS anunciam por
/// `NetService` sempre que esperam (`AnuncianteBonjour`), mas o iOS e o Mac não têm lista no Exibir:
/// quem exibe num deles digita o endereço, que está logo abaixo. `anunciando` falso é para quem não
/// anunciar.
struct BlocoDaEspera: View {
    enum Parte { case tudo, instrucao, codigos }

    let nome: String
    let pin: String
    let endereco: String?
    let notaDoEnlace: String?
    let temPares: Bool
    var anunciando = true
    var casa = CGSize(width: 44, height: 60)
    var parte: Parte = .tudo

    var body: some View {
        VStack(spacing: 0) {
            if parte != .codigos {
                instrucao
                    .font(Estilo.corpo(.callout))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if parte != .instrucao {
                if temPares { codigosComPares } else { codigosSemPares }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var codigosSemPares: some View {
        VStack(spacing: 0) {
            RotuloDeSecao(tr("Na primeira vez, o PIN"))
                .padding(.top, parte == .codigos ? 12 : 18)
            LetreiroDoPin(pin: pin, casa: casa)
                .padding(.top, 10)
            Text(tr("ou pelo endereço"))
                .font(Estilo.corpo(.footnote))
                .foregroundColor(Estilo.texto3)
                .padding(.top, 14)
            ChipDeEndereco(endereco: endereco)
                .padding(.top, 8)
            nota
        }
    }

    private var codigosComPares: some View {
        VStack(spacing: 0) {
            Text(tr("Aparelhos pareados entram direto."))
                .font(Estilo.corpo(.subheadline, .semibold))
                .foregroundColor(Estilo.texto)
                .padding(.top, parte == .codigos ? 12 : 16)
            ChipDeEndereco(endereco: endereco)
                .padding(.top, 10)
            nota
            (Text(tr("Aparelho novo?") + " ") + Text(verbatim: "PIN " + Estilo.pinEspacado(pin)).font(Estilo.mono(.subheadline, .semibold)))
                .font(Estilo.corpo(.subheadline))
                .foregroundColor(Estilo.texto2)
                .padding(.top, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("Aparelho novo?") + " " + Estilo.pinSoletrado(pin))
        }
    }

    private var instrucao: Text {
        let forte = { (s: String) in Text(s).bold().foregroundColor(Estilo.texto) }
        if anunciando {
            return Text(tr("No outro aparelho, abra o Quall em ")) + forte(tr("Exibir"))
                + Text(tr(" e escolha ")) + forte(nome) + Text(tr(" na lista, ou digite o endereço abaixo."))
        }
        return Text(tr("No outro aparelho, abra o Quall em ")) + forte(tr("Exibir"))
            + Text(tr(" e digite o endereço abaixo."))
    }

    @ViewBuilder
    private var nota: some View {
        if let notaDoEnlace {
            Text(notaDoEnlace)
                .font(Estilo.corpo(.caption))
                .foregroundColor(Estilo.texto3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
}

/// O ícone de espelhar num círculo âmbar a 16 %, com dois anéis âmbar em volta, pulsando devagar
/// (2 s). Com "reduzir movimento" ligado, fica parado; sem anéis (um aviso à vista, §11.1), é só o
/// círculo.
private struct FarolDaEspera: View {
    var comAneis = true
    var pulsando = true
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento
    @State private var aceso = false

    var body: some View {
        ZStack {
            if comAneis {
                ZStack {
                    Circle()
                        .stroke(Estilo.aguardando.opacity(0.18), lineWidth: 1.5)
                        .frame(width: 120, height: 120)
                        .scaleEffect(aceso ? 1 : 0.88)
                        .opacity(aceso ? 1 : 0.45)
                    Circle()
                        .stroke(Estilo.aguardando.opacity(0.32), lineWidth: 1.5)
                        .frame(width: 88, height: 88)
                        .scaleEffect(aceso ? 1 : 0.93)
                }
                // A animação presa aos anéis e ao `aceso`, e não num `withAnimation` no `onAppear`:
                // uma mudança de leiaute no mesmo quadro (o teclado do nome fechando) entraria na
                // transação sem fim e deixaria a coluna inteira flutuando.
                .animation(reduzirMovimento || !pulsando
                           ? nil : .easeInOut(duration: 2).repeatForever(autoreverses: true),
                           value: aceso)
            }
            Image(systemName: Estilo.iconeDeEspelhar)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Estilo.aguardandoTexto)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Estilo.aguardando.opacity(0.16)))
        }
        .frame(width: comAneis ? 120 : 60, height: comAneis ? 120 : 60)
        .accessibilityHidden(true)
        .onAppear { aceso = true }
    }
}
