import Foundation

/// Condição do aparelho no instante da medição.
///
/// Existe por um viés concreto: **uma rodada num iPhone recém-reiniciado mede o caso mais
/// fácil**. Com a memória do sistema recém-liberada, o teto de 50 MB da extension não é o que
/// morde primeiro; num aparelho ligado há dias, com pressão de memória real, o mesmo código pode
/// encontrar outra realidade. O `uptime` sai na primeira linha do log para que o relato diga em
/// que condição o número foi obtido — e para que uma rodada com o aparelho recém-ligado possa
/// ser invalidada por quem lê, e não defendida por quem mediu.
public enum Sistema {
    /// Segundos desde o boot, por `kern.boottime` — que conta tempo de parede, e não o relógio
    /// monotônico de `ProcessInfo.systemUptime`, que congela em sono profundo.
    public static var uptimeSegundos: Int {
        var tempo = timeval()
        var tamanho = MemoryLayout<timeval>.size
        var chave: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&chave, 2, &tempo, &tamanho, nil, 0) == 0 else { return -1 }
        return Int(Date().timeIntervalSince1970) - Int(tempo.tv_sec)
    }

    public static var descricao: String {
        let s = uptimeSegundos
        guard s >= 0 else { return "uptime=?" }
        return "uptime_s=\(s) (\(s / 3600)h\((s % 3600) / 60)m)"
    }
}
