import SwiftUI

/// A primeira tela do Quall: **espelhar ou exibir** — e, desde 13/09/2026, o **teleprompter**, com
/// os dois papéis dele (mostrar o texto, controlar) em dois cartões menores abaixo dos de vídeo.
///
/// # Por que ela existe
///
/// Até 2026-08-30 havia dois aplicativos em `apps/ios`: `Quall` (emitia) e `QuallReceptor`
/// (exibia), com dois bundle ids, dois ícones e dois pareamentos. Na loja seriam dois produtos, e
/// nenhuma outra casca do projeto é assim: `docs/fluxo-de-uso.md` descreve **um** fluxo com dois
/// lados, não dois programas.
///
/// Esta tela é a costura, e ela é literalmente a frase que organiza o fluxo:
///
/// > **Quem espelha anuncia e espera. Quem exibe escolhe e conecta.**
///
/// Isso não é preferência de interface — é imposto pelo protocolo: `tracks` só vale em
/// `quall_host`, não há renegociação, e quem chama `quall_connect` nunca poderá emitir naquela
/// sessão (dívida 1). Perguntar aqui é a única forma honesta de contar essa verdade, porque a
/// escolha é irreversível **dentro de uma sessão**.
///
/// # O que ela custa, dito sem maquiagem
///
/// O emissor iOS é o melhor fluxo do projeto e `docs/fluxo-de-uso.md` conta os toques dele: um no
/// seletor de origem, um em Espelhar, um no consentimento do sistema. **Esta tela acrescenta um
/// quarto toque a esse caminho**, e não há como não acrescentar: a pergunta "qual dos dois lados
/// você é?" não existia porque ela estava respondida pelo ícone que a pessoa tocou na tela de
/// início. Unificar move a pergunta para dentro do app; não a apaga.
///
/// Três coisas foram feitas para que o custo seja só esse um toque, e nenhuma delas esconde nada:
///
/// - **A escolha não é lembrada.** Um "continuar de onde parou" economizaria o toque de quem
///   sempre espelha e deixaria quem exibe procurando o caminho de volta. É a mesma troca ruim que
///   dois ícones fazia.
/// - **A retomada pula esta tela.** Se a appex já está transmitindo quando o app abre, o papel já
///   está decidido pelos fatos, e `Raiz` vai direto para a tela de espera — ver `QuallApp`.
/// - **O modo automático de bancada pula esta tela.** `--endereco` entra em `.exibir` sem toque
///   nenhum, que é o que mantém viva a corrida sem dedo do iPad.
///
/// # Por que não um seletor único ("tela / câmera / exibir") na tela do emissor
///
/// Caberia num toque só, e foi tentado no papel antes desta versão. Foi recusado: o seletor de
/// origem responde *o que transmitir* e só existe para quem já decidiu espelhar. Misturar "exibir"
/// naquela lista põe, na mesma pergunta, uma opção que muda **qual metade do produto** vai rodar e
/// outras que mudam só a fonte de vídeo. E `TelaInicial` mostra nome-na-rede, IP, aviso de Wi-Fi e
/// o botão de esquecer pares — coisas que só fazem sentido para quem vai anunciar. Um toque a mais
/// é mais barato do que uma tela que fala de duas coisas ao mesmo tempo.
///
/// # A cara desde 30/09/2026 (`docs/telas-estudio.md` §6.1)
///
/// A mesma escolha, no "Estúdio de bolso": a marca e a engrenagem no alto, os dois **cartões de
/// papel** (Espelhar em violeta, Exibir em superfície), os três **ladrilhos** do teleprompter numa
/// linha e, no pé, a cápsula com o nome e o IP deste aparelho. A descrição técnica do aparelho que
/// ficava no pé foi para Ajustes › Sobre. Os sete toques na marca continuam ligando o diagnóstico.
///
/// A tela só adapta o estado; o desenho é `VistaDoInicio`, que recebe valores simples.
struct TelaDeModo: View {
    @EnvironmentObject private var papel: Papel
    @EnvironmentObject private var emissor: Emissor
    @State private var temPares = Compartilhado.haParesConhecidos
    @State private var toquesNoTitulo = 0
    @State private var diagnosticoLigado = Diagnostico.ligado
    @State private var ajustes = false

    var body: some View {
        VistaDoInicio(nome: emissor.nome,
                      ip: emissor.ip ?? emissor.ipDoCabo,
                      temPares: temPares,
                      diagnosticoLigado: diagnosticoLigado,
                      aoTocarNaMarca: revelarDiagnostico,
                      aoAbrirAjustes: { ajustes = true },
                      aoEscolher: { papel.escolher($0) })
            .onAppear {
                temPares = Compartilhado.haParesConhecidos
                Diagnostico.nota("APP tela=escolha_de_papel pares_conhecidos=\(temPares)"
                    + " aparelho=\(Identidade.maquina()) tela=\(Identidade.descricaoDaTela())")
            }
            .sheet(isPresented: $ajustes) {
                FolhaDaEngrenagem(fechar: { ajustes = false },
                                  aoEsquecerPares: { temPares = Compartilhado.haParesConhecidos })
            }
    }

    /// O mesmo gesto escondido de `TelaInicial`, e no mesmo lugar (o título), porque agora **esta**
    /// é a primeira tela. Sem isto o diagnóstico só se ligaria depois de escolher espelhar, que é
    /// justamente o papel que menos precisa dele quando o defeito está do lado que exibe.
    private func revelarDiagnostico() {
        toquesNoTitulo += 1
        guard toquesNoTitulo >= 7 else { return }
        toquesNoTitulo = 0
        let defaults = UserDefaults(suiteName: Compartilhado.grupo)
        let atual = (defaults?.object(forKey: "diagnostico") as? Bool) ?? Diagnostico.padraoDaBuild
        defaults?.set(!atual, forKey: "diagnostico")
        diagnosticoLigado = !atual
    }
}

/// **O Início**, só desenho (§6.1). De cima para baixo: marca e engrenagem; "Seu estúdio na rede
/// local."; os dois cartões lado a lado, da mesma altura; "TELEPROMPTER" e os três ladrilhos; e, no pé,
/// a cápsula da rede (verde com rede, âmbar sem) com a frase do PIN embaixo. Deitado (§11.1), duas
/// colunas: marca, frase e pé à esquerda; cartões e ladrilhos à direita.
///
/// Conta de altura no iPhone 7, escala padrão. Em pé (647 pt úteis): 8 + marca 44 + 10 + frase 42 +
/// 20 + cartões 176 (a frase do Exibir em três linhas) + 20 + rótulo 16 + 8 + ladrilhos 141 (título e
/// legenda em duas linhas) + 16 (espaço mínimo) + cápsula 34 + 8 + frase 36 + 12 ≈ 591; a linha do
/// diagnóstico, quando ligada, usa ~42. Deitado (375 pt): 8 + cartões 158 + 16 + rótulo 16 + 8 +
/// ladrilhos 141 + 12 ≈ 359 na coluna da direita, a mais alta.
struct VistaDoInicio: View {
    let nome: String
    /// O IP deste aparelho (a LAN, ou o do cabo), sem porta. `nil` sem rede.
    let ip: String?
    let temPares: Bool
    let diagnosticoLigado: Bool
    let aoTocarNaMarca: () -> Void
    let aoAbrirAjustes: () -> Void
    let aoEscolher: (Papel.Escolha) -> Void

    @Environment(\.verticalSizeClass) private var classeVertical

    var body: some View {
        ZStack {
            FundoDoQuall(brilho: Estilo.acento, intensidade: 0.2)
            TelaQueCabe {
                Group {
                    if classeVertical == .compact { deitado } else { emPe }
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .dynamicTypeSize(...Estilo.tetoDaLetra)
    }

    private var emPe: some View {
        VStack(alignment: .leading, spacing: 0) {
            cabecalho
            frase.padding(.top, 10)
            cartoes.padding(.top, 20)
            teleprompter.padding(.top, 20)
            Spacer(minLength: 16)
            diagnostico
            rodape
        }
        .colunaDoQuall()
    }

    private var deitado: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                cabecalho
                frase.padding(.top, 10)
                Spacer(minLength: 16)
                diagnostico
                rodape
            }
            .frame(maxWidth: 250)
            VStack(alignment: .leading, spacing: 0) {
                cartoes
                teleprompter.padding(.top, 16)
            }
        }
        .colunaDoQuall(larga: true)
    }

    private var cabecalho: some View {
        HStack {
            MarcaDoQuall()
                .contentShape(Rectangle())
                .onTapGesture(perform: aoTocarNaMarca)
            Spacer(minLength: 0)
            // O idioma (`docs/traducao.md`): no canto de cima, ao lado da engrenagem.
            SeletorDeIdioma()
            BotaoRedondo(icone: "gearshape", rotulo: tr("Ajustes"), acao: aoAbrirAjustes)
        }
    }

    private var frase: some View {
        Text(tr("Seu estúdio na rede local.\nSem nuvem, sem cadastro."))
            .font(Estilo.corpo(.callout))
            .foregroundColor(Estilo.texto2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cartoes: some View {
        HStack(spacing: 12) {
            CartaoDePapel(icone: Estilo.iconeDeEspelhar,
                          titulo: tr("Espelhar"),
                          texto: tr("Mande a tela ou uma câmera daqui."),
                          destaque: true) { aoEscolher(.espelhar) }
            CartaoDePapel(icone: "play.tv",
                          titulo: tr("Exibir"),
                          texto: tr("Assista aqui ao que outro aparelho manda.")) { aoEscolher(.exibir) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var teleprompter: some View {
        VStack(alignment: .leading, spacing: 8) {
            RotuloDeSecao(tr("Teleprompter"))
            HStack(spacing: 10) {
                Ladrilho(icone: "text.alignleft", titulo: tr("Mostrar o texto"),
                         legenda: tr("Vira o prompter")) { aoEscolher(.teleprompter) }
                Ladrilho(icone: "slider.horizontal.3", titulo: tr("Controlar"),
                         legenda: tr("Comanda outro prompter")) { aoEscolher(.controleRemoto) }
                Ladrilho(icone: "person.crop.rectangle", titulo: tr("Texto + câmera"),
                         legenda: tr("Lê olhando a lente")) { aoEscolher(.teleprompterComCamera) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var diagnostico: some View {
        if diagnosticoLigado {
            // A leitura do estado é feita **uma vez** por execução; trocar aqui vale da próxima
            // abertura em diante, e dizer isso é mais honesto que mentir sobre o efeito.
            Text(tr("Diagnóstico ligado — registros no console do sistema. "
                    + "Mudanças valem na próxima abertura do app."))
                .font(Estilo.corpo(.caption))
                .foregroundColor(Estilo.aguardandoTexto)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
        }
    }

    /// A cápsula com o nome e o IP, e embaixo a frase do PIN — o mesmo dado que a tela de espera usa
    /// para decidir a manchete, dito aqui pelo mesmo motivo: quem já pareou não precisa procurar o
    /// PIN, e quem não pareou precisa saber que ele existe antes de chegar na tela que o mostra.
    private var rodape: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ip == nil ? Estilo.aguardando : Estilo.conectado)
                    .frame(width: 8, height: 8)
                Text(nome)
                    .font(Estilo.corpo(.footnote))
                    .foregroundColor(Estilo.texto)
                    .lineLimit(1)
                Text(ip ?? tr("sem rede"))
                    .font(Estilo.mono(.footnote))
                    .foregroundColor(Estilo.texto2)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            // Deitado, a coluna tem 250 pt: a cápsula encolhe a letra antes de cortar o nome.
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(Estilo.superficie))
            .overlay(Capsule().stroke(Estilo.contorno, lineWidth: 1))
            .accessibilityElement(children: .combine)

            Text(temPares
                 ? tr("Aparelhos pareados entram direto, sem PIN.")
                 : tr("Na primeira vez, um PIN de 6 dígitos. Depois, entra direto."))
                .font(Estilo.corpo(.footnote))
                .foregroundColor(Estilo.texto3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
