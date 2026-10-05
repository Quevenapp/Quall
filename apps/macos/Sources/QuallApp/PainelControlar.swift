// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import QuallIdiomaKit
import QuallTeleprompterKit
import SwiftUI

/// **O formulário do controle, só a vista** (`docs/telas-estudio.md` §7.3 e §6.7): "Controlar um
/// teleprompter", a lista PROMPTERS NA REDE (a procura já roda com o formulário aberto), o endereço,
/// o PIN em casas, "Roteiros guardados" e "Conectar" (↩). A `TelaDoControle` adapta o `Teleprompter`
/// a ela.
struct PainelControlar: View {
    struct Prompter: Identifiable, Equatable {
        let id: String
        let nome: String
        let endpoint: String
    }

    let prompters: [Prompter]
    /// O navegador do mDNS está de pé (`Teleprompter.procurando`): só então "procurando" acende.
    let procurando: Bool
    @Binding var endereco: String
    @Binding var pin: String
    let ultimoEndereco: String
    let mensagem: String
    let conectando: Bool
    let encerrando: Bool
    let listaLigada: Bool
    /// Na janela própria do controle (M4) não há barra lateral: o "Voltar" de antes fica.
    let mostrarVoltar: Bool
    let aoConectarEm: (String) -> Void
    let aoConectar: () -> Void
    let aoCancelar: () -> Void
    let aoAbrirRoteiros: () -> Void
    let aoVoltar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(T("Controlar um teleprompter"))
                    .font(Estilo.titulo(28))
                    .foregroundColor(Estilo.texto)
                Text(T("Escolha o prompter. Do outro lado: Quall Studio → Teleprompter → Mostrar o texto."))
                    .font(.system(size: 14))
                    .foregroundColor(Estilo.texto2)
            }

            HStack(spacing: 8) {
                RotuloDeSecao(T("Prompters na rede"))
                Spacer(minLength: 0)
                if procurando {
                    HStack(spacing: 7) {
                        Circle().fill(Color(rgb: 0x8B7DFF)).frame(width: 6, height: 6)
                            .background(Circle().fill(Color(rgb: 0x8B7DFF, opacidade: 0.25)).frame(width: 14, height: 14))
                        Text(T("procurando")).font(.system(size: 12)).foregroundColor(Estilo.texto2)
                    }
                }
            }
            .padding(.top, 22)

            Group {
                if prompters.isEmpty {
                    HStack(spacing: 10) {
                        if procurando { Carregando() }
                        Text(procurando ? T("Procurando prompters…") : T("Nenhum prompter na lista."))
                            .font(.system(size: 14)).foregroundColor(Estilo.texto2)
                    }
                    .frame(height: 48)
                } else {
                    PilhaQueRola(quantas: prompters.count, visiveis: 2, alturaDaLinha: 48, espaco: 6) {
                        VStack(spacing: 6) {
                            ForEach(prompters) { p in linha(p) }
                        }
                    }
                }
            }
            .padding(.top, 8)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    RotuloDeSecao(T("Ou digite o endereço"))
                    Campo(dica: "192.168.56.20:7979", texto: $endereco, aoConfirmar: aoConectar)
                    if !ultimoEndereco.isEmpty, endereco != ultimoEndereco {
                        ChipDoUltimo(endereco: ultimoEndereco) { endereco = ultimoEndereco }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    RotuloDeSecao("PIN")
                    EntradaDoPin(texto: $pin, casa: CGSize(width: 38, height: 48), fonte: 24, aoConfirmar: aoConectar)
                }
            }
            .padding(.top, 20)

            Text(T("Deixe vazio se este Mac e o prompter já se parearam antes."))
                .font(.system(size: 12))
                .foregroundColor(Estilo.texto2)
                .padding(.top, 8)

            if !mensagem.isEmpty {
                Aviso(texto: mensagem, tipo: conectando ? .info : .ambar).padding(.top, 14)
            }

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                if mostrarVoltar {
                    Button(T("Voltar"), action: aoVoltar)
                        .buttonStyle(.quall(.secundario))
                        .disabled(encerrando)
                }
                // Visível mesmo sem conexão: as cópias moram na réplica deste controle (§11.5).
                Button(action: aoAbrirRoteiros) {
                    RotuloDeBotao(TextosDaPergunta.roteirosGuardados, icone: "tray.full")
                }
                .buttonStyle(.quall(.secundario))
                Spacer(minLength: 0)
                if conectando || encerrando {
                    Button(T("Cancelar"), action: aoCancelar)
                        .buttonStyle(.quall(.secundario))
                        .disabled(encerrando)
                }
                Button(action: aoConectar) {
                    RotuloDeBotao(conectando ? T("Conectando…") : T("Conectar"), atalho: conectando ? nil : "↩")
                }
                .buttonStyle(.quall(.principal))
                .keyboardShortcut(.defaultAction)
                .disabled(!listaLigada || endereco.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrilhoDeFundo())
    }

    private func linha(_ p: Prompter) -> some View {
        Button { aoConectarEm(p.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Estilo.acentoClaro)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Estilo.acentoFundo))
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.nome).font(.system(size: 14, weight: .semibold)).foregroundColor(Estilo.texto).lineLimit(1)
                    Text(p.endpoint).font(Estilo.mono(12)).foregroundColor(Estilo.texto2).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Estilo.texto3)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Estilo.superficie))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Estilo.contorno, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(EstiloApertado())
        .disabled(!listaLigada)
    }
}
