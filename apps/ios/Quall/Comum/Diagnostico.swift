import Foundation
import os

/// O que sobrou do arnês de medição depois que ele **matou o processo que media**.
///
/// Na corrida de 464 s do degrau 4 o instrumento derrubou a appex: `relatar()` calculava um
/// delta de janela sobre `UInt64`, os contadores do núcleo são por track, a segunda sessão
/// reinicia o contador em zero, e `UInt64(0) - UInt64(27000)` estoura — o Swift derruba o
/// processo por desenho. De fora, isso é indistinguível de um defeito do produto.
///
/// O produto **não leva o arnês junto**. O que sobrou obedece a três regras, e cada uma existe
/// por causa daquela corrida:
///
/// 1. **Desligável.** `nota` só escreve quando a chave `diagnostico` está ligada no App Group.
///    Ela é lida **uma vez** — não por quadro, não por segundo — e no caminho normal do produto
///    a variável é `false` e o `os_log` nunca é montado (o texto vem em `@autoclosure`, então
///    nem a interpolação roda).
/// 2. **Incapaz de derrubar o processo.** Não há aritmética de inteiro sem sinal em lugar
///    nenhum daqui, não há `!`, não há índice de coleção, não há `try!`. A única operação é
///    entregar uma `String` pronta ao `os_log`.
/// 3. **Separado do caminho do quadro.** Nada nesta enum é chamado de dentro de
///    `processSampleBuffer` nem do callback de saída do VideoToolbox. Quem chama é a supervisão
///    de 1 Hz e as transições de estado, que acontecem dezenas de vezes numa transmissão
///    inteira.
///
/// `falha` é a exceção deliberada à regra 1: ela sai sempre. Um caminho que só corre quando
/// algo deu errado não é o instrumento que estraga a medição — é a única testemunha de por que
/// a transmissão não começou, num processo que só se observa de fora.
public enum Diagnostico {
    public static let grupo = "group.br.com.queven.quall"
    public static let subsistema = "br.com.queven.quall"

    private static let registro = Logger(subsystem: subsistema, category: "quall")

    /// Ligado ou desligado pela opção escondida da tela inicial (sete toques no título), que
    /// grava a chave no App Group. Sem chave gravada, o padrão vem da **configuração do build**:
    /// ligado em `Debug`, que é o que a bancada instala, e desligado em `Release`, que é o que
    /// uma pessoa usaria.
    ///
    /// A chave gravada vence o padrão: pode desligar notas em Debug ou ligá-las em Release.
    /// Sanitização de credenciais e endereços é independente dessa opção e da configuração.
    /// A bancada deve receber o PIN por um canal explícito, nunca extraí-lo dos logs.
    ///
    /// Constante por execução de propósito: consultar `UserDefaults` a cada linha seria pôr o
    /// instrumento de volta no caminho quente, que é exatamente o erro que esta rodada corrige.
    public static let ligado: Bool = {
        if let escolhido = UserDefaults(suiteName: grupo)?.object(forKey: "diagnostico") as? Bool {
            return escolhido
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// O padrão desta build, para a tela inicial mostrar o estado certo sem duplicar a regra.
    public static var padraoDaBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// A `String` é materializada numa variável **antes** de entrar no `os_log`: a interpolação
    /// do `Logger` é `@escaping`, e um autoclosure não-escapante não pode ser capturado por ela.
    /// O ganho da lazidez continua de pé — com o diagnóstico desligado, `texto()` nunca roda.
    public static func nota(_ texto: @autoclosure () -> String) {
        guard ligado else { return }
        let linha = SanitizacaoDoLog.mensagem(texto())
        registro.notice("\(linha, privacy: .public)")
    }

    /// Sai sempre. Ver o cabeçalho.
    public static func falha(_ texto: @autoclosure () -> String) {
        let linha = SanitizacaoDoLog.mensagem(texto())
        registro.error("\(linha, privacy: .public)")
    }

    /// Memória que ainda resta ao processo antes do jetsam.
    ///
    /// Não é instrumento: é o insumo da sentinela da appex, que prefere encerrar a transmissão
    /// com um motivo legível a ser morta em silêncio. Medido no iPhone 7: o orçamento é de
    /// 50,00 MB e o regime do produto ficou entre 5,23 e 7,06 MB — **~43 MB de folga**. (O pico
    /// de 12,97 MB da mesma corrida era da calibragem de retenção, instrumento puro: o maior
    /// consumidor de memória daquela corrida foi o arnês.) A sentinela existe para o caso que a
    /// medição não viu, não para o que ela viu.
    public static var memoriaDisponivel: Int { os_proc_available_memory() }

    /// `phys_footprint`: a página suja que o jetsam de fato conta.
    ///
    /// Sozinha ela não diz nada — o número que importa é a **soma** com `memoriaDisponivel`, que é
    /// o orçamento do processo. No iPhone 7 essa soma deu 50,00 MB de forma consistente em 621
    /// amostras (degrau 4, 2026-08-22), e foi assim que os "~50 MB" deixaram de ser dado de
    /// enunciado e viraram medição deste projeto. Mas isso foi medido **pelo arnês**, que não
    /// convive com o produto no aparelho: sem esta linha aqui, o orçamento de um aparelho novo só
    /// se descobre reinstalando o `PortaoAppex` e gastando outra sequência de toques.
    ///
    /// Custa uma chamada mach por segundo, na mesma passada da sentinela, fora do caminho do
    /// quadro. É a mesma leitura de `PortaoAppex/Comum/Diario.swift`, copiada por escolha antiga
    /// deste projeto (alvos de build diferentes) e não por descuido.
    public static var pegadaEmBytes: Int {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let situacao = withUnsafeMutablePointer(to: &info) { ponteiro in
            ponteiro.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) { reapontado in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reapontado, &contagem)
            }
        }
        // `Int(clamping:)` e não `Int(_:)`: a regra 2 do cabeçalho proíbe aritmética de inteiro
        // sem sinal capaz de derrubar o processo, e converter um `UInt64` para `Int` **trapeia**
        // se não couber. Aqui nunca vai não caber; a conversão que não trapeia custa o mesmo.
        return situacao == KERN_SUCCESS ? Int(clamping: info.phys_footprint) : 0
    }
}
