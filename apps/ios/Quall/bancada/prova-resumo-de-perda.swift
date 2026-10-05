import Foundation

// Banco de prova de `Receber/ResumoDePerda.swift`, sem Xcode e sem projeto.
//
// As duas cascas Swift que recebem — o papel de exibir do Quall no iOS e o app de câmera do macOS
// — carregam o mesmo arquivo de formatação, e compilar qualquer um dos dois projetos inteiros
// custa muito mais do que exercitar a única parte que tem aritmética dentro. Este banco existe
// para que "a formatação está certa" seja uma afirmação medida, e não uma leitura.
//
// A saída esperada é **byte a byte igual** à do banco em C (`plugins/obs/bancada/prova-perda.c`) e
// à linha que o Kotlin produz no Android. Se as três divergirem, a bancada passa a ter três
// formatos para o mesmo número, que é meio caminho para o próximo mal-entendido.
//
// Os caminhos abaixo mudaram na unificação de 2026-08-30: eram `apps/ios/Receptor/Comum/` e
// `apps/ios/Receptor/bancada/`, do segundo aplicativo, e a pasta `Receptor/` não existe mais. Não
// é só renomeação — a formatação passou a morar em `Receber/`, que é compilado **só no alvo do
// app** e nunca dentro da Broadcast Upload Extension, cujo teto medido de jetsam é de 50,00 MB.
// Nenhuma linha do arquivo medido mudou, e por isso nenhum dos casos abaixo foi tocado.
//
//     xcrun swiftc -O -o /tmp/prova-perda \
//       apps/ios/Quall/Receber/ResumoDePerda.swift \
//       apps/ios/Quall/bancada/prova-resumo-de-perda.swift && /tmp/prova-perda
//
//     # a cópia do app de câmera do macOS, que tem de dar o mesmo resultado
//     xcrun swiftc -O -o /tmp/prova-perda-camera \
//       integrations/camera-macos/Fontes/App/ResumoDePerda.swift \
//       apps/ios/Quall/bancada/prova-resumo-de-perda.swift && /tmp/prova-perda-camera

@main
struct ProvaDeResumoDePerda {

    static var falhas = 0

    static func confere(_ caso: String, _ json: String, _ esperado: String) {
        let obtido = ResumoDePerda.formatar(json)
        if obtido != esperado {
            print("FALHOU \(caso)\n  esperado: \(esperado)\n  obtido  : \(obtido)")
            falhas += 1
        } else {
            print("ok \(caso)\n  \(obtido)")
        }
    }

    static func main() {
        // A corrida de 29/08 que derrubou a leitura antiga: 486 no teto, cinquenta perdidos.
        confere(
            "o teto exagera dez vezes",
            #"{"packets_lost_for_real":50,"packets_missing_upper_bound":486,"packets_too_late":0,"packets_seen":27729}"#,
            "perda exata 50 (0.180%) · teto 486 (1.722%) · tarde demais 0 · vistos 27729")

        // O contador novo admitindo que ele próprio superestima. Sem esta linha,
        // `packets_too_late` seria mais um número mudo no meio de um JSON.
        confere(
            "janela curta se declara",
            #"{"packets_lost_for_real":120,"packets_missing_upper_bound":400,"packets_too_late":7,"packets_seen":10000}"#,
            "perda exata 120 (1.186%) · teto 400 (3.846%) · tarde demais 7 · vistos 10000"
                + " — JANELA CURTA: a perda exata está superestimada em até 7")

        // Uma `.so`/`.a` velha, sem o contador novo: a chave não vem. `?` diz "não sei"; `0` diria
        // "medi e não perdi nada", que é a mentira mais cara que este relatório poderia contar.
        confere(
            "chave ausente vira ? e não zero",
            #"{"packets_missing_upper_bound":486,"packets_seen":27729}"#,
            "perda exata ? · teto 486 (1.722%) · tarde demais ? · vistos 27729")

        // A dívida 25: o primeiro pacote visto fixa a linha de base, e sem nenhum pacote visto o
        // contador não afirma coisa nenhuma.
        confere(
            "nada chegou, nada se afirma",
            #"{"packets_lost_for_real":0,"packets_missing_upper_bound":0,"packets_too_late":0,"packets_seen":0}"#,
            "perda: nenhum pacote chegou ainda (packets_seen=0) — nada a afirmar")

        // Um resumo que some do relatório é pior que um que se declara ausente.
        confere("json ilegível se declara", "isto não é json",
                "perda: contadores do núcleo ilegíveis")

        print("\n" + (falhas == 0 ? "verde: 5/5" : "VERMELHO"))
        exit(falhas == 0 ? 0 : 1)
    }
}
