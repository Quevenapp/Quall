import Darwin
import Foundation
import QuartzCore

/// O relógio único da medição.
///
/// `mach_absolute_time` é do **sistema**, não do processo: dois processos que o leem leem a mesma
/// linha do tempo, sem sincronização nenhuma. É essa propriedade que torna o método possível.
///
/// Cuidado que custou dinheiro em outra frente deste projeto: existem **duas** bases mach.
/// `mach_absolute_time` (= `CACurrentMediaTime()`, = `DispatchTime.uptimeNanoseconds`) **para**
/// durante o sono profundo; `mach_continuous_time` **não** para. O `presentationTimeStamp` que o
/// ScreenCaptureKit carrega no `CMSampleBuffer` é da base **contínua**. Subtrair uma da outra
/// devolve o tempo de sono acumulado desde o boot disfarçado de latência.
///
/// Aqui a base canônica é `mach_absolute_time`, e a conversão da base contínua é explícita,
/// medida uma vez e registrada no cabeçalho da corrida.
public enum Relogio {
    private static let base: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    @inline(__always)
    private static func paraNs(_ ticks: UInt64) -> UInt64 {
        if base.numer == base.denom { return ticks }
        // Multiplicação em 128 bits para não estourar em máquinas com numer > 1.
        let alto = ticks.multipliedFullWidth(by: base.numer)
        let (q, _) = base.denom.dividingFullWidth(alto)
        return q
    }

    /// Agora, em nanossegundos, na base canônica (`mach_absolute_time`).
    @inline(__always)
    public static func agoraNs() -> UInt64 { paraNs(mach_absolute_time()) }

    /// Agora, em nanossegundos, na base **contínua** (`mach_continuous_time`).
    @inline(__always)
    public static func agoraContinuoNs() -> UInt64 { paraNs(mach_continuous_time()) }

    /// `contínuo - absoluto`, em nanossegundos. Constante enquanto a máquina não dormir.
    /// Medido no início da corrida e gravado; é o que permite trazer o pts do ScreenCaptureKit
    /// para a base canônica sem misturar relógios às cegas.
    public static func deslocamentoContinuoNs() -> Int64 {
        // Amostra intercalada para reduzir o erro de leitura entre as duas chamadas.
        let a1 = agoraNs()
        let c = agoraContinuoNs()
        let a2 = agoraNs()
        let a = (a1 / 2) + (a2 / 2)
        return Int64(bitPattern: c) - Int64(bitPattern: a)
    }

    /// `CACurrentMediaTime()` (segundos) → nanossegundos na base canônica.
    /// `CADisplayLink.targetTimestamp` vem nessa unidade.
    @inline(__always)
    public static func nsDeMediaTime(_ segundos: CFTimeInterval) -> UInt64 {
        UInt64((segundos * 1_000_000_000.0).rounded())
    }

    /// Conferência de que `CACurrentMediaTime()` e `mach_absolute_time` são de fato a mesma base.
    /// Devolve o desvio observado em nanossegundos — deve ficar na casa das dezenas de micro.
    /// Não confio na documentação para isso: confiro no fluxo.
    public static func desvioMediaTimeNs() -> Int64 {
        let a1 = agoraNs()
        let m = nsDeMediaTime(CACurrentMediaTime())
        let a2 = agoraNs()
        let a = (a1 / 2) + (a2 / 2)
        return Int64(bitPattern: m) - Int64(bitPattern: a)
    }
}
