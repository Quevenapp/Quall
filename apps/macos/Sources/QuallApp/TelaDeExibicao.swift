// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import QuallCaptureKit
import QuallIdiomaKit
import QuallReceptorKit
import SwiftUI

/// O lado que **recebe**: endereço e PIN no painel Exibir (`docs/telas-estudio.md` §7.2), e depois a
/// imagem do outro aparelho na janela inteira (`TelaDoVideo`).
///
/// `docs/ux-m6.md` §2.2 desenha esta tela do lado de quem exibe e é literal sobre a única coisa
/// que não pode faltar: *"um campo 'Não achou? Digite o endereço' fica **sempre visível**"*, porque
/// `docs/fluxo-de-uso.md` já classificou isso como *"o caminho que salva"*. Aqui o campo é o
/// **único** caminho, e a lista por mDNS fica nomeada no documento como o que falta.
///
/// # Por que a imagem e o formulário não convivem na árvore
///
/// A `VistaDeVideo` só entra na árvore nas fases em que há imagem (`RaizDaJanela` escolhe entre esta
/// vista e a `TelaDoVideo`). No receptor iOS, enquanto ela ficava montada o tempo todo, ao cair a
/// sessão a tela de entrada voltava com o último quadro decodificado **pintado por cima dela** —
/// faixas de vídeo sobre os campos de endereço e PIN. Num receptor que exibe a tela de outra pessoa
/// isso não é feiura, é **vazamento de conteúdo entre sessões**. O `if` da raiz é o conserto, e
/// `VistaDeVideo.dismantleNSView` é a outra metade dele.
struct TelaDeExibicao: View {
    @EnvironmentObject private var receptor: Receptor

    var body: some View {
        PainelExibir(
            endereco: $receptor.enderecoDigitado,
            pin: $receptor.pinDigitado,
            ultimoEndereco: receptor.ultimoEndereco,
            mensagem: receptor.mensagem,
            tipoDaMensagem: receptor.precisaDePin ? .vermelho : (receptor.fase == .conectando ? .info : .ambar),
            precisaDePin: receptor.precisaDePin,
            conectando: receptor.fase == .conectando,
            ocupado: receptor.fase != .formulario,
            aoConectar: { receptor.conectar() })
    }
}

/// **O formulário do Exibir, só a vista** (§7.2): "Assistir outro aparelho", o endereço em mono grande,
/// "Usar o último", o PIN em casas e "Conectar" (↩).
struct PainelExibir: View {
    @Binding var endereco: String
    @Binding var pin: String
    let ultimoEndereco: String
    let mensagem: String
    let tipoDaMensagem: Aviso.Tipo
    let precisaDePin: Bool
    let conectando: Bool
    /// Conectando, ou parando uma sessão que acabou: o Conectar fica sem clique.
    let ocupado: Bool
    var focoNoPinNoRetrato = false
    let aoConectar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(T("Assistir outro aparelho"))
                    .font(Estilo.titulo(28))
                    .foregroundColor(Estilo.texto)
                Text(T("Digite o endereço e o PIN que aparecem na tela de quem está espelhando."))
                    .font(.system(size: 14))
                    .foregroundColor(Estilo.texto2)
            }

            // O endereço é o que a tela de espera do **outro** aparelho está mostrando.
            RotuloDeSecao(T("Endereço")).padding(.top, 26)
            HStack(spacing: 12) {
                Campo(dica: "192.168.56.131:7877", texto: $endereco, tamanho: 19, altura: 48, aoConfirmar: aoConectar)
                    .frame(width: 300)
                if !ultimoEndereco.isEmpty, endereco != ultimoEndereco {
                    ChipDoUltimo(endereco: ultimoEndereco) { endereco = ultimoEndereco }
                }
            }
            .padding(.top, 8)

            RotuloDeSecao("PIN").padding(.top, 22)
            EntradaDoPin(texto: $pin, focoNoRetrato: focoNoPinNoRetrato, aoConfirmar: aoConectar).padding(.top, 8)
            // **O PIN é pedido uma vez por par de aparelhos**, e a legenda diz isso em vez de deixar a
            // pessoa adivinhar por que às vezes o campo pode ficar vazio.
            Text(precisaDePin ? T("Peça os seis dígitos que a tela do outro aparelho está mostrando.")
                              : T("Deixe vazio se este Mac e o outro aparelho já parearam."))
                .font(.system(size: 12))
                .foregroundColor(Estilo.texto2)
                .padding(.top, 8)

            if !mensagem.isEmpty {
                Aviso(texto: mensagem, tipo: tipoDaMensagem).padding(.top, 16)
            }

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button(action: aoConectar) {
                    RotuloDeBotao(conectando ? T("Conectando…") : T("Conectar"), atalho: conectando ? nil : "↩")
                }
                .buttonStyle(.quall(.principal))
                .keyboardShortcut(.defaultAction)
                .disabled(ocupado || endereco.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrilhoDeFundo())
    }
}

/// "Usar o último · 192.168.57.11:7877" (§6.6), em `acentoFundo`.
struct ChipDoUltimo: View {
    let endereco: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                (Text(T("Usar o último · ")) + Text(endereco).font(Estilo.mono(12)))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundColor(Estilo.iconeEscolhido)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Estilo.acentoFundo))
            .contentShape(Capsule())
        }
        .buttonStyle(EstiloApertado())
    }
}

// MARK: - o vídeo

/// **A imagem, na janela inteira**, com a barra fina no pé (§7.2 e §6.6). O mínimo de 880 × 580 não
/// vale aqui (§11.4): a janela do vídeo continua podendo encolher até 520 × 400.
struct TelaDoVideo: View {
    @EnvironmentObject private var receptor: Receptor
    @EnvironmentObject private var teleprompter: Teleprompter
    @Environment(\.openWindow) private var abrirJanela
    /// O painel dos números começa fechado no produto e aberto numa corrida de bancada (§6.6).
    @State private var numerosAbertos = Argumentos.lidos().modoDeBancada

    var body: some View {
        ZStack(alignment: .bottom) {
            VistaDeVideo(camada: receptor.exibidor.camada)
            // R9b: o clique na imagem foca e mede na câmera do outro lado, onde ela deixa (§3.4).
            if let p = planoDaCameraRemota, p.toqueDisponivel, receptor.tamanhoDoVideo.width > 0 {
                CliqueNaImagemRecebida(video: receptor.tamanhoDoVideo) { ponto, longo in
                    receptor.tocarNaCameraRemota(ponto, longo: longo)
                }
            }
            BarraDoVideo(
                nome: receptor.par.isEmpty ? receptor.endereco : receptor.par,
                detalhe: [receptor.rotuloDaTrack, receptor.pareamentoNovo ? T("pareado agora") : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                temSom: !receptor.somEstado.isEmpty,
                // O ponto âmbar no botão do som: o som não sai ("sem som: …") ou foi calado pela câmera do
                // Quall ("som: mudo: a câmera do Quall está ligada…"; o mudo da pessoa é só "som: mudo").
                somComProblema: comecaComo(receptor.somEstado, "sem som: %@") || caladoPelaCamera,
                somAMostra: caladoPelaCamera || receptor.somComACamera,
                mudo: $receptor.somMudo,
                volume: $receptor.somVolume,
                // **M4** (e a exceção ao "um papel por vez", §11.4): o controle do teleprompter numa
                // janela própria, com o vídeo aqui — o caminho de dois aparelhos
                // (`docs/teleprompter-com-camera.md` §10): um filma, o outro mostra o texto, e este
                // Mac vê um e controla o outro.
                podeControlar: teleprompter.tela == .fechada || teleprompter.controleEmJanela,
                parando: receptor.fase == .encerrando,
                numerosAbertos: $numerosAbertos,
                numeros: numeros,
                acusacao: acusacao,
                estadoDoSom: receptor.somEstado,
                somComACamera: $receptor.somComACamera,
                aoControlar: {
                    teleprompter.abrirControleEmJanela()
                    abrirJanela(id: JanelaDoControle.id)
                },
                // R9b: a engrenagem dos ajustes da câmera do outro lado, com `pronto` ou `nao_permitido`.
                aoAjustesDaCamera: planoDaCameraRemota == nil ? nil : { abrirJanela(id: JanelaDosAjustesDaCameraRemota.id) },
                aoParar: { receptor.parar() })
                .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 960, maxWidth: .infinity,
               minHeight: 400, idealHeight: 600, maxHeight: .infinity)
        .background(Color.black)
    }

    /// O painel da câmera do outro lado, quando ele aparece (`pronto` ou `nao_permitido`, §5).
    private var planoDaCameraRemota: PlanoRemotoDoPainel? {
        receptor.cameraRemota.flatMap { PlanoRemotoDoPainel.de($0) }
    }

    /// A câmera do Quall calou o som (D3). A frase e o interruptor que o religam não podem ficar atrás
    /// do ⓘ fechado (revisão de 30/09).
    private var caladoPelaCamera: Bool {
        // Nas duas línguas: a linha do som pode ter nascido antes de o seletor trocar o idioma.
        Idioma.allCases.contains {
            receptor.somEstado.contains(T("mudo: a câmera do Quall está ligada (numa chamada, ou pelo app dela)", em: $0))
        }
    }

    /// As linhas de números de sempre, agora atrás do ⓘ.
    private var numeros: [LinhaDeNumero] {
        var l: [LinhaDeNumero] = [
            .init(String(format: "%@ · %@ · recebidos %llu · enfileirados %llu · %.1f fps",
                         receptor.dimensao, receptor.perfil, receptor.recebidos, receptor.enfileirados, receptor.fps)),
            .init(String(format: "primeira imagem %@ · decode p50 %.2f ms · p95 %.2f ms · marca ok %llu / erro %llu / repetida %llu",
                         receptor.primeiraImagemMs > 0 ? String(format: "%.0f ms", receptor.primeiraImagemMs) : "ainda não",
                         receptor.decodeP50Ms, receptor.decodeP95Ms,
                         receptor.marcasCertas, receptor.marcasErradas, receptor.marcasRepetidas)),
            .init(String(format: "idrs %llu · sem_parametros %llu · falhas_sessao %llu%@",
                         receptor.idrs, receptor.semParametros, receptor.falhasDeSessao,
                         receptor.ultimaFalha != 0 ? " · ultima_falha \(receptor.ultimaFalha)" : "")),
            // **A linha da imagem, e ela é sempre escrita.** Ver o comentário de `acusacao`: a queixa
            // que originou esta medida era sobre a tela. `sem_referencia_ms` vem com a cauda à mostra
            // de propósito — p50 de 10 ms é imperceptível e max de 947 ms é quase um segundo de tela
            // errada.
            .init(String(format: "imagem: rupturas %llu · suspeitos %llu · pior rajada %llu · retidos %llu · sem_referencia_ms %@",
                         receptor.rupturas, receptor.suspeitos, receptor.piorRajada, receptor.retidos,
                         receptor.semReferenciaMs), forte: receptor.suspeitos > 0),
        ]
        if let acusacao { l.append(.init(acusacao, forte: true, marcada: true)) }
        // **Acima do JSON cru, e de propósito.** O número de perda que esta tela mostrava em toda
        // casca desta casa vinha do teto, que cobra reordenação como perda. Ver `ResumoDePerda`.
        if !receptor.resumoDePerda.isEmpty { l.append(.init(receptor.resumoDePerda)) }
        l.append(.init(receptor.contadoresDoNucleo, linhas: 2))
        return l
    }

    /// A frase que diz **de qual lado do fio** está o defeito, quando chega quadro e não sai imagem.
    /// `nil` quando não há do que acusar ninguém. Com ela, o ⓘ ganha o ponto âmbar (§6.6).
    ///
    /// Existe por causa da foto de `docs/tela-preta.md` §1: ali estava tudo o que era preciso para
    /// responder — `recebidos 68 · exibidos 0` — e faltava a única coisa que separava as duas
    /// explicações opostas. A ordem dos testes é a ordem em que eles acusam: primeiro a **geometria
    /// da camada**, depois o **receptor** (temos o `OSStatus`), depois o **emissor** (ausência de IDR).
    private var acusacao: String? {
        // **A acusação da imagem quebrada vem primeiro, e não depende de `enfileirados == 0`**: sai
        // imagem, e ela está errada.
        if receptor.suspeitos > 0 {
            return "*** \(receptor.suspeitos) quadro(s) exibidos com a referência quebrada"
                 + " — pior rajada \(receptor.piorRajada) seguidos ***"
        }
        if receptor.camadaInvisivel, receptor.recebidos > 0 {
            return "*** CAMADA INVISÍVEL: decodifica e não mostra — a camada está sem área ou fora da árvore ***"
        }
        guard receptor.recebidos > 0, receptor.enfileirados == 0 else { return nil }
        if receptor.falhasDeSessao > 0 {
            return "*** o decodificador deste Mac recusou montar a sessão (OSStatus \(receptor.ultimaFalha)) ***"
        }
        if receptor.idrs == 0 {
            return "*** nenhum conjunto de parâmetros chegou: o emissor não mandou IDR ***"
        }
        return "*** chega quadro e não sai imagem ***"
    }
}

/// Uma linha do painel de números.
struct LinhaDeNumero {
    let texto: String
    var forte = false
    /// A acusação: um ponto âmbar antes dela (o texto fica em `texto`, que é o que vai sobre a imagem).
    var marcada = false
    var linhas = 1

    init(_ texto: String, forte: Bool = false, marcada: Bool = false, linhas: Int = 1) {
        self.texto = texto
        self.forte = forte
        self.marcada = marcada
        self.linhas = linhas
    }
}

/// **A barra fina do vídeo, só a vista** (§7.2 e §11.1): preto a 85 %, e por cima só `texto`/`texto2`.
/// Nome do par, som e volume, "Controlar um teleprompter…", Parar e o ⓘ, que abre e fecha os números.
struct BarraDoVideo: View {
    let nome: String
    let detalhe: String
    let temSom: Bool
    /// O som não sai ("sem som: …") ou foi calado pela câmera do Quall: o botão do som ganha o ponto âmbar.
    var somComProblema = false
    /// A frase do som e o interruptor da câmera do Quall à mostra, fora do painel de números: com o som
    /// calado pela câmera, e enquanto o interruptor estiver ligado (senão ele sumiria no toque).
    var somAMostra = false
    @Binding var mudo: Bool
    @Binding var volume: Float
    let podeControlar: Bool
    let parando: Bool
    @Binding var numerosAbertos: Bool
    let numeros: [LinhaDeNumero]
    let acusacao: String?
    let estadoDoSom: String
    @Binding var somComACamera: Bool
    let aoControlar: () -> Void
    /// R9b: a engrenagem "Ajustes da câmera" da câmera do outro lado; `nil` esconde (o filmador não oferece).
    var aoAjustesDaCamera: (() -> Void)? = nil
    let aoParar: () -> Void

    private static let vidro = Color.black.opacity(0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if numerosAbertos { painelDosNumeros }
            if somAMostra && !estadoDoSom.isEmpty {
                linhaDoSom
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Self.vidro))
            }
            ViewThatFits(in: .horizontal) {
                barra(compacta: false)
                barra(compacta: true)
            }
        }
    }

    private func barra(compacta: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(nome).font(.system(size: 13, weight: .semibold)).foregroundColor(Estilo.texto).lineLimit(1)
                if !detalhe.isEmpty {
                    Text(detalhe).font(.system(size: 11)).foregroundColor(Estilo.texto2).lineLimit(1)
                }
            }
            .fixedSize()
            Spacer(minLength: 8)
            // D1 do `docs/som-no-receptor.md` §12.1: som ligado por padrão, com mudo e volume aqui.
            // Calar não para o motor: a porta continua puxada e ancorada.
            if temSom {
                BotaoRedondo(icone: mudo ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             rotulo: mudo ? T("Ligar o som") : T("Calar"), tamanho: 32,
                             ponto: somComProblema ? Estilo.aguardando : nil) { mudo.toggle() }
                Deslizante(valor: $volume, largura: compacta ? 64 : 96).disabled(mudo)
            }
            if let aoAjustesDaCamera {
                BotaoRedondo(icone: "gearshape", rotulo: TextosDosAjustes.titulo, tamanho: 32, acao: aoAjustesDaCamera)
            }
            if compacta {
                BotaoRedondo(icone: "text.alignleft", rotulo: T("Controlar um teleprompter…"), tamanho: 32, acao: aoControlar)
                    .disabled(!podeControlar)
            } else {
                Button(T("Controlar um teleprompter…"), action: aoControlar)
                    .buttonStyle(.quall(.secundario, altura: 32))
                    .disabled(!podeControlar)
            }
            Button(action: aoParar) { RotuloDeBotao(parando ? T("Parando…") : T("Parar"), parar: true) }
                .buttonStyle(.quall(.perigo, altura: 32))
                .disabled(parando)
            BotaoRedondo(icone: "info", rotulo: numerosAbertos ? T("Esconder os números") : T("Mostrar os números"),
                         tamanho: 32, ponto: acusacao == nil ? nil : Estilo.aguardando) { numerosAbertos.toggle() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Self.vidro))
        .environment(\.colorScheme, .dark)
    }

    /// A frase do som e o interruptor da D3 (crítica 9, M4): o mudo automático da câmera do Quall numa
    /// chamada pode ser desligado aqui.
    private var linhaDoSom: some View {
        HStack(spacing: 10) {
            Text(estadoDoSom).font(Estilo.mono(11)).foregroundColor(Estilo.texto)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(T("tocar mesmo com a câmera do Quall numa chamada"))
                .font(.system(size: 11)).foregroundColor(Estilo.texto2).lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 180, alignment: .trailing)
            Interruptor(titulo: T("tocar mesmo com a câmera do Quall numa chamada"),
                        ligado: $somComACamera, pequeno: true)
        }
    }

    private var painelDosNumeros: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !estadoDoSom.isEmpty && !somAMostra {
                linhaDoSom.padding(.bottom, 3)
            }
            ForEach(Array(numeros.enumerated()), id: \.offset) { _, n in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if n.marcada { Circle().fill(Estilo.aguardando).frame(width: 7, height: 7) }
                    Text(n.texto)
                        .font(Estilo.mono(11, peso: n.forte ? .bold : .regular))
                        .foregroundColor(n.forte ? Estilo.texto : Estilo.texto2)
                        .lineLimit(n.linhas)
                }
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Self.vidro))
    }
}
