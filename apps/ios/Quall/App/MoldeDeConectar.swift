import SwiftUI

/// **O molde dos formulários de conectar** — Exibir (§6.6) e Controlar (§6.7), "o mesmo molde", com
/// as emendas da §11.1 e da §11.2. Só desenho: recebe os valores e devolve os toques.
///
/// Cabeçalho (voltar · título · engrenagem, que o Controlar não tem; conectando, o voltar vira
/// "Cancelar"); o título de tela e a frase; "ENDEREÇO" com o campo em mono e o chip "Usar o último"; o
/// PIN em seis casas; o **Conectar** logo abaixo do PIN — o teclado numérico não tem tecla de
/// confirmar, e com qualquer coisa entre o PIN e o botão ele ficava debaixo do teclado (foto do
/// usuário, 11/09, iPhone X); o que a tela quiser por baixo dele (`extra`); e os avisos, no máximo
/// um à vista, o resto em "+N".
///
/// O teclado fecha sozinho no sexto dígito do PIN e com um toque fora dos campos; com ele aberto no
/// PIN, a frase e o chip saem, para o Conectar ficar acima dos 216 pt do teclado numérico do iPhone 7.
/// O Conectar fica desligado enquanto conecta (guarda contra o toque duplo), e só aí: com o endereço
/// vazio o Controlar ainda diz a frase de sempre ("Digite o endereço que aparece no prompter…"), e o
/// Exibir não faz nada, como antes. Deitado, duas colunas:
/// endereço e avisos à esquerda; PIN, Conectar e o resto à direita. A rolagem continua (`TelaQueCabe`): com o
/// teclado aberto e deitado, é por ela que se chega ao botão.
///
/// Conta de altura no iPhone 7, escala padrão, teclado fechado (647 pt): 8 + cabeçalho 44 + 12 +
/// título 34 + 6 + frase 40 + 16 + rótulo 16 + 8 + campo 52 + 8 + chip 32 + 16 + rótulo 16 + 8 + casas
/// 60 + 8 + frase 18 + 16 + Conectar 56 + 14 + (os dois botões pequenos do Controlar 40 + 14) + aviso
/// ~60 + 12 ≈ 634 no pior caso, com chip, os dois botões e um aviso. Com o teclado no PIN (431 pt acima
/// dele), sem a frase e o chip, o Conectar termina em ≈ 408. Deitado (375 pt), com os espaços mais
/// curtos: 8 + 44 + a coluna mais alta (a da direita: 8 + rótulo 16 + 8 + casas 60 + 8 + frase 18 + 12
/// + Conectar 56 + 10 + botões 40; ou a da esquerda com um aviso e o "+N": ~330) + 12 ≈ 300.
struct MoldeDeConectar<Extra: View>: View {
    enum Campo: Hashable { case endereco, pin }

    let tituloDoCabecalho: String
    let titulo: String
    let frase: String
    let exemplo: String
    @Binding var endereco: String
    @Binding var pin: String
    let ultimoEndereco: String
    let conectando: Bool
    let podeCancelar: Bool
    let avisos: [ItemDeAviso]
    /// `nil` quando não há como sair sem parar (sessão no ar): aí, conectando, o lugar é do Cancelar.
    let voltar: (() -> Void)?
    let cancelar: () -> Void
    /// `nil`: sem engrenagem (o Controlar).
    let abrirAjustes: (() -> Void)?
    let conectar: () -> Void
    @ViewBuilder let extra: () -> Extra

    @FocusState private var foco: Campo?
    @Environment(\.verticalSizeClass) private var classeVertical

    private var deitado: Bool { classeVertical == .compact }

    var body: some View {
        ZStack {
            FundoDoQuall()
            TelaQueCabe {
                VStack(alignment: .leading, spacing: 0) {
                    cabecalho
                    if deitado {
                        HStack(alignment: .top, spacing: 24) {
                            // Os avisos vão para a coluna do endereço, a mais baixa: na do PIN, com o
                            // Conectar e os botões do Controlar, passavam dos 375 pt do iPhone 7.
                            VStack(alignment: .leading, spacing: 0) {
                                cabecaDoTitulo.padding(.top, 8)
                                campoDeEndereco.padding(.top, 10)
                                pilhaDeAvisos.padding(.top, 10)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                campoDePin.padding(.top, 8)
                                acoes
                            }
                        }
                    } else {
                        cabecaDoTitulo.padding(.top, 12)
                        campoDeEndereco.padding(.top, 16)
                        campoDePin.padding(.top, 16)
                        acoes
                        pilhaDeAvisos.padding(.top, 14)
                    }
                    Spacer(minLength: 0)
                }
                .colunaDoQuall(larga: deitado)
                .padding(.top, 8)
                .padding(.bottom, 12)
                // O toque fora dos campos fecha o teclado. Atrás do conteúdo: o que tem toque próprio
                // (campos, botões, casas) recebe primeiro.
                .background(Color.black.opacity(0.001).onTapGesture { foco = nil })
            }
        }
        .dynamicTypeSize(...Estilo.tetoDaLetra)
    }

    private var cabecalho: some View {
        CabecalhoDaTela(titulo: tituloDoCabecalho) {
            if conectando {
                Button(tr("Cancelar"), action: cancelar)
                    .font(Estilo.corpo(.body, .semibold))
                    .foregroundColor(Estilo.acentoClaro)
                    .frame(minHeight: 44)
                    .disabled(!podeCancelar)
                    .opacity(podeCancelar ? 1 : 0.4)
            } else if let voltar {
                BotaoRedondo(icone: "chevron.left", rotulo: tr("Voltar"), acao: voltar)
            }
        } direita: {
            if let abrirAjustes {
                BotaoRedondo(icone: "gearshape", rotulo: tr("Ajustes"), acao: abrirAjustes)
            }
        }
    }

    private var cabecaDoTitulo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titulo)
                .font(Estilo.titulo(.title))
                .foregroundColor(Estilo.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            if foco != .pin {
                Text(frase)
                    .font(Estilo.corpo(.subheadline))
                    .foregroundColor(Estilo.texto2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var campoDeEndereco: some View {
        VStack(alignment: .leading, spacing: 8) {
            RotuloDeSecao(tr("Endereço"))
            TextField(exemplo, text: $endereco)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                .focused($foco, equals: .endereco)
                .onSubmit { foco = .pin }
                .estiloDeCampo(mono: true)
            if !ultimoEndereco.isEmpty, endereco.isEmpty, foco != .pin {
                ChipPequeno(texto: tr("Usar o último") + " ·", detalheMono: ultimoEndereco,
                            icone: "clock.arrow.circlepath", violeta: true) { endereco = ultimoEndereco }
            }
        }
    }

    private var campoDePin: some View {
        VStack(alignment: .leading, spacing: 8) {
            RotuloDeSecao("PIN") // sem-traducao
            CasasDoPin(pin: $pin, foco: $foco, campo: .pin)
            Text(tr("Deixe vazio se os dois já parearam."))
                .font(Estilo.corpo(.footnote))
                .foregroundColor(Estilo.texto3)
        }
    }

    private var acoes: some View {
        VStack(alignment: .leading, spacing: deitado ? 10 : 14) {
            Button(action: { foco = nil; conectar() }) {
                Text(tr("Conectar"))
            }
            .buttonStyle(.principal)
            .disabled(conectando)

            extra()
        }
        .padding(.top, deitado ? 12 : 16)
    }

    @ViewBuilder
    private var pilhaDeAvisos: some View {
        if !avisos.isEmpty {
            PilhaDeAvisos(itens: avisos, maximo: 1)
        }
    }
}
