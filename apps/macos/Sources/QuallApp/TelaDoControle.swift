import QuallIdiomaKit
import QuallTeleprompterKit
import SwiftUI

/// **A tela do controle**: achar o prompter (lista do mDNS, ou endereço), e depois comandá-lo.
///
/// O Mac como controle é teclado: espaço toca e pausa, ↑↓ mudam a velocidade, ←→ pulam, Home volta
/// ao começo, M liga o espelho (`AtalhosDoTeleprompter`). Os botões fazem o mesmo, pelo mesmo
/// caminho do modelo.
struct TelaDoControle: View {
    @EnvironmentObject private var tp: Teleprompter

    var body: some View {
        Group {
            if tp.controleNoFormulario {
                // O formulário é um painel do estúdio (`docs/telas-estudio.md` §7.3); o painel de
                // comandar e o modo segurar mantêm a geometria de antes (§6.8: só cores e peças).
                PainelControlar(
                    prompters: tp.prompters.map { .init(id: $0.id, nome: $0.nome, endpoint: $0.endpoint) },
                    procurando: tp.procurando,
                    endereco: $tp.enderecoDigitado,
                    pin: $tp.pinDigitado,
                    ultimoEndereco: tp.ultimoEndereco,
                    mensagem: tp.mensagem,
                    conectando: tp.fase == .abrindo,
                    encerrando: tp.fase == .encerrando,
                    listaLigada: tp.fase == .formulario,
                    mostrarVoltar: tp.controleEmJanela,
                    aoConectarEm: { id in
                        if let p = tp.prompters.first(where: { $0.id == id }) { tp.conectar(a: p) }
                    },
                    aoConectar: { tp.conectar() },
                    aoCancelar: { tp.desconectar() },
                    aoAbrirRoteiros: { tp.abrirRoteiros() },
                    aoVoltar: { tp.sair() })
            } else if tp.segurarParaRolar {
                // "Segurar para rolar" (§12.5): a tela fica só com os dois botões grandes.
                ModoSegurar().padding(24)
            } else {
                painel.padding(24)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Estilo.fundo)
        .sheet(isPresented: $tp.editorAberto) {
            EditorDoRoteiro().environmentObject(tp)
        }
        // A pergunta do texto e os "Roteiros guardados" (§11.7): uma folha por vez, nas três telas do
        // controle (formulário, painel e modo segurar).
        .modifier(FolhasDoControle(tp: tp))
    }

    // MARK: - comandar

    private var painel: some View {
        VStack(alignment: .leading, spacing: 14) {
            cabecalho
            gravacaoRemota
            avisos
            transporte
            Divider()
            ajustes
            Divider()
            roteiro
            Spacer(minLength: 4)
            Text(T("Teclado: espaço tocar/pausar · ↑↓ velocidade (⇧ = 1) · ←→ pular (⇧ = 10%) · Home ou 0 começo · "
                 + "M espelho · +/− fonte · [ ] margem · , . linha de leitura · E editar"))
                .font(.caption2)
                .foregroundColor(Estilo.texto3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(T("Desconectar")) { tp.desconectar() }
                    .disabled(tp.fase == .encerrando)
                Spacer()
                Button(tp.fase == .encerrando ? T("Saindo…") : T("Sair")) { tp.sair() }
                    .disabled(tp.fase == .encerrando)
            }
        }
    }

    private var cabecalho: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tp.fase == .conectado && !tp.avisos.parSumido ? Estilo.conectado : Estilo.aguardando)
                .frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(tp.fase == .conectado ? T("Controlando %@", tp.par) : T("Conexão perdida"))
                    .font(.title2.weight(.semibold))
                Text(tp.endereco ?? "")
                    .font(.caption.monospaced())
                    .foregroundColor(Estilo.texto2)
            }
            Spacer()
            // Ajuste local deste Mac (§12.5): ligado, a tela troca pelos dois botões grandes.
            Toggle(T("Segurar para rolar"), isOn: $tp.segurarParaRolar)
                .toggleStyle(.switch)
                .help(T("A tela fica só com dois botões grandes, Rolar para cima e Rolar para baixo: "
                      + "o texto rola enquanto um deles está apertado, na velocidade ajustada."))
        }
    }

    /// **Gravar e parar pelo controle** (contrato §13.8, R5): o botão só existe com
    /// `"par_entende_gravar": true` (o prompter é a tela com câmera); o indicador conta o tempo que o
    /// prompter relata; o pedido sem resposta aparece esperando, e a recusa vira aviso com o motivo.
    @ViewBuilder
    private var gravacaoRemota: some View {
        let e = tp.estado
        if e.parEntendeGravar || e.gravandoHaMs != nil || !tp.recadoDaGravacao.isEmpty {
            HStack(spacing: 10) {
                if let ha = e.gravandoHaMs {
                    Circle().fill(Estilo.noAr).frame(width: 10, height: 10)
                    Text(T("Gravando há %@", GravadorLocal.duracaoLegivel(Double(ha) / 1000)))
                        .font(.headline.monospacedDigit())
                } else {
                    Image(systemName: "record.circle").foregroundColor(Estilo.texto2)
                    Text(T("O prompter não está gravando")).foregroundColor(Estilo.texto2)
                }
                if let p = e.pedidoDeGravacao {
                    ProgressView().controlSize(.small)
                    Text(p.haMs > 1500 ? T("o prompter ainda não respondeu") : (p.gravar ? T("pedindo para gravar…") : T("pedindo para parar…")))
                        .font(.caption).foregroundColor(p.haMs > 1500 ? Estilo.aguardandoTexto : Estilo.texto2)
                }
                Spacer()
                if e.parEntendeGravar {
                    Button(e.gravandoHaMs == nil ? T("Gravar") : T("Parar a gravação")) {
                        tp.pedirGravacao(e.gravandoHaMs == nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(e.gravandoHaMs == nil ? Estilo.noArCheio : Estilo.superficieAlta)
                    .disabled(tp.fase != .conectado)
                }
            }
            if !tp.recadoDaGravacao.isEmpty {
                faixa(tp.recadoDaGravacao, cor: Estilo.aguardando)
            }
        }
    }

    @ViewBuilder
    private var avisos: some View {
        if tp.fase == .semPar || tp.fase == .abrindo {
            faixa((tp.tentativas > 1 ? T("Conexão perdida — tentando de novo (tentativa %@).", tp.tentativas)
                                     : T("Conexão perdida — tentando de novo."))
                  + " " + T("O prompter continua como estava; os comandos vão quando a conexão voltar."),
                  cor: Estilo.aguardando)
        } else if tp.avisos.parSumido {
            faixa(T("O prompter não responde há mais de 2,5 s. Os comandos vão quando ele voltar."), cor: Estilo.aguardando)
        }
        if tp.avisos.semConfirmacao && tp.fase == .conectado {
            faixa(T("O último comando ainda não chegou ao prompter."), cor: Estilo.aguardandoTexto)
        }
        if tp.avisos.atualizeOApp {
            faixa(T("O prompter fala outra versão do teleprompter: atualize o app nos dois aparelhos."), cor: Estilo.noAr)
        }
        if tp.avisos.relogioErrado {
            faixa(T("O relógio de um dos dois aparelhos está mais de um dia errado: algumas edições foram recusadas."),
                  cor: Estilo.noAr)
        }
        if tp.avisos.textoNaoPassou {
            faixa(T("O roteiro não chegou ao prompter depois de 20 tentativas."), cor: Estilo.noAr)
        }
        // O detalhe da última tentativa (o "ocupado", por exemplo), sem repetir a faixa de cima.
        if !tp.mensagem.isEmpty && tp.fase != .conectado && !comecaComo(tp.mensagem, "Conexão perdida") {
            Text(tp.mensagem).font(.footnote).foregroundColor(Estilo.texto2)
        }
    }

    private func faixa(_ texto: String, cor: Color) -> some View {
        Text(texto)
            .font(.callout.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cor.opacity(0.22))
            .cornerRadius(8)
    }

    private var transporte: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button { tp.saltar(0) } label: {
                    Label(T("Início"), systemImage: "backward.end.fill")
                }
                .help(T("Voltar ao começo (Home ou 0)"))
                Button { tp.pular(-0.05) } label: { Label("5%", systemImage: "backward.fill") }
                    .help(T("Pular 5% para trás (← pula 2%, ⇧← 10%)"))
                Button { tp.tocarOuPausar() } label: {
                    Label(tp.estado.rolando ? T("Pausar") : T("Tocar"),
                          systemImage: tp.estado.rolando ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 120, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .help(T("Tocar ou pausar (espaço)"))
                Button { tp.pular(0.05) } label: { Label("5%", systemImage: "forward.fill") }
                    .help(T("Pular 5% para a frente (→ pula 2%, ⇧→ 10%)"))
            }
            // O progresso é o relato do prompter: 0,5 é o meio do percurso **no layout dele** (§3).
            HStack(spacing: 10) {
                ProgressView(value: min(1, max(0, tp.estado.posicao)))
                Text(String(format: "%.1f%%", tp.estado.posicao * 100))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private var ajustes: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(T("Velocidade"))
                Slider(value: Binding(get: { tp.estado.velocidade }, set: { tp.definirVelocidade($0) }),
                       in: 0.05...8)
                Text(String(format: T("%.2f linhas/s"), tp.estado.velocidade))
                    .font(.system(size: 12, design: .monospaced))
                Stepper("", onIncrement: { tp.mudarVelocidade(0.1) }, onDecrement: { tp.mudarVelocidade(-0.1) })
                    .labelsHidden()
            }
            GridRow {
                Text(T("Fonte"))
                Slider(value: Binding(get: { tp.estado.fonte }, set: { tp.definirFonte($0) }), in: 16...200)
                Text(String(format: "%.0f pt", tp.estado.fonte))
                    .font(.system(size: 12, design: .monospaced))
                Stepper("", onIncrement: { tp.definirFonte(tp.estado.fonte + 2) },
                        onDecrement: { tp.definirFonte(tp.estado.fonte - 2) })
                    .labelsHidden()
            }
            GridRow {
                Text(T("Margem"))
                Slider(value: Binding(get: { tp.estado.margem }, set: { tp.definirMargem($0) }),
                       in: EstadoDoTeleprompter.faixaDaMargem)
                Text(String(format: T("%.0f%% de cada lado"), tp.estado.margem * 100))
                    .font(.system(size: 12, design: .monospaced))
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                Text(T("Linha de leitura"))
                Slider(value: Binding(get: { tp.estado.linhaDeLeitura }, set: { tp.definirLinhaDeLeitura($0) }),
                       in: EstadoDoTeleprompter.faixaDaLinha)
                Text(String(format: T("%.0f%% do topo"), tp.estado.linhaDeLeitura * 100))
                    .font(.system(size: 12, design: .monospaced))
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                Text(T("Espelho"))
                Toggle(T("Inverter o texto na horizontal (para ler pelo vidro)"),
                       isOn: Binding(get: { tp.estado.espelho }, set: { _ in tp.alternarEspelho() }))
                    .toggleStyle(.switch)
                    .gridCellColumns(3)
            }
        }
    }

    private var roteiro: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(T("Roteiro")).font(.headline)
                Text(T("%@ bytes", tp.texto.utf8.count.formatted()))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Estilo.texto2)
                Spacer()
                Button(T("Editar…")) { tp.abrirEditor() }
                Button(T("Colar da área de transferência…")) { tp.abrirEditor(comAreaDeTransferencia: true) }
                Button(TextosDaPergunta.roteirosGuardados + "…") { tp.abrirRoteiros() }
            }
            Text(tp.texto.isEmpty ? T("Sem roteiro ainda.") : String(tp.texto.prefix(240)))
                .font(.callout)
                .foregroundColor(Estilo.texto2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
