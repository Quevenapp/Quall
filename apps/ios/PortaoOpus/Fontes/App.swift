import SwiftUI
import Darwin
import os

/// Quanto o Opus custa de **memória suja** num iPhone, medido em vez de calculado.
///
/// # Por que este alvo existe
///
/// `docs/audio.md` §13 é explícito sobre o buraco: *"iOS não rodou em aparelho"* — o alvo
/// `aarch64-apple-ios` compila, o custo de **tamanho** está medido (+342 KiB), e **nenhum iPhone
/// jamais executou um quadro de Opus**. O número que interessa para o produto não é esse:
///
/// - o teto da Broadcast Upload Extension é **50 MiB** no iPhone 7 e no iPhone X (medido em
///   `apps/ios/README.md`, degrau 4: orçamento 50,00 MB, regime 5,23–7,06 MB, pico 12,97 MB);
/// - **o jetsam conta página suja**, e `__TEXT` é limpo (`PortaoAppex/Comum/Diario.swift`). Então
///   os +342 KiB de binário **não** entram nesse teto quase nada; o que entra é o **estado** do
///   encoder, que ninguém mediu em lugar nenhum deste repositório — `opus_encoder_get_size` nem
///   sequer está ligado em `crates/quall-opus/src/sys.rs`.
///
/// # O que este alvo mede, e o que ele não mede
///
/// **Mede**: o custo de página suja de criar e rodar os encoders de Opus com **os presets reais do
/// núcleo** (`PRESET_MICROFONE` e `PRESET_AUDIO_DO_SISTEMA`, lidos de
/// `crates/quall-core/src/track.rs`), num iPhone, com `phys_footprint` — o mesmo contador que o
/// degrau 4 usou para medir o orçamento da appex.
///
/// **Não mede**, e a diferença importa para quem for citar o número:
///
/// 1. **Não roda dentro de uma Broadcast Upload Extension.** É um app comum, sem o teto de 50 MiB.
///    O delta de página suja de um encoder é propriedade do encoder, não do processo que o
///    hospeda — mas a *soma* com o encoder de vídeo, no mesmo instante, sob pressão de jetsam,
///    não está medida aqui.
/// 2. **Não há captura, nem reamostragem, nem segunda track.** O caminho de áudio do iOS não
///    existe: `ManipuladorDeTela.processSampleBuffer` descarta `.audioApp` e `.audioMic` na
///    primeira linha, e não há FFI de áudio no `quall.h` para alimentar uma track. O que falta
///    para o produto está no relato, não escondido atrás deste número.
/// 3. **O sinal de entrada é sintético.** Ruído e senoide, não áudio real — a taxa de bits do
///    Opus é variável e depende do conteúdo, então o **tamanho dos pacotes** aqui é ilustrativo.
///    A **memória**, que é o que se quer, não depende do conteúdo.
@main
struct PortaoOpusApp: App {
    var body: some Scene { WindowGroup { Tela() } }
}

enum Diario {
    private static let log = OSLog(subsystem: "br.com.queven.quall.portaoopus", category: "opus")

    /// **`type: .default`, e não `.info`.** `docs/regras-de-frente.md` já registra que "ausência de
    /// linha no log não é ausência de evento": `Info` e `Debug` são escondidos por padrão, e a
    /// primeira corrida deste alvo saiu vazia no `idevicesyslog` exatamente por isso. A etiqueta
    /// `[quall-opus]` vai no texto porque é por ela que o filtro `-m` do `idevicesyslog` casa.
    static func dizer(_ t: String) {
        let linha = "[quall-opus] " + t
        os_log("%{public}@", log: log, type: .default, linha)
        print(linha)
        fflush(stdout)
    }

    /// `phys_footprint`, o mesmo contador do degrau 4 — é ele que o jetsam olha.
    static var pegadaEmBytes: Int {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &contagem)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        return Int(clamping: info.phys_footprint)
    }

    static var disponivelEmBytes: Int { os_proc_available_memory() }
}

/// Um encoder de Opus com um preset do núcleo.
final class Encoder {
    private var ptr: OpaquePointer?
    let canais: Int32
    let nome: String

    /// - Parameters:
    ///   - fala: `conteudo_e_fala` do preset. Vira `OPUS_APPLICATION_VOIP` contra
    ///     `OPUS_APPLICATION_AUDIO`, que é a escolha que muda o modo (SILK/híbrido contra CELT) e,
    ///     portanto, o tamanho do estado interno.
    init?(nome: String, canais: Int32, taxaDeBits: Int32, fec: Bool, perdaPct: Int32, fala: Bool) {
        self.nome = nome
        self.canais = canais
        var erro: Int32 = 0
        let aplicacao = fala ? OPUS_APPLICATION_VOIP : OPUS_APPLICATION_AUDIO
        ptr = opus_encoder_create(48_000, canais, aplicacao, &erro)
        guard erro == OPUS_OK, ptr != nil else {
            Diario.dizer("!! opus_encoder_create(\(nome)) falhou: \(erro)")
            return nil
        }
        // Pelo atalho em C: o Swift não chama função variádica. Ver `atalho_opus.h`.
        let cru = UnsafeMutableRawPointer(ptr!)
        _ = quall_opus_set_bitrate(cru, taxaDeBits)
        _ = quall_opus_set_inband_fec(cru, fec ? 1 : 0)
        // Sem isto o FEC não produz LBRR nenhum — o defeito medido em `docs/audio.md` §11.
        _ = quall_opus_set_packet_loss(cru, perdaPct)
        var olhar: Int32 = 0
        _ = quall_opus_get_lookahead(cru, &olhar)
        Diario.dizer("OPUS encoder=\(nome) canais=\(canais) lookahead=\(olhar) amostras "
                     + "(\(Double(olhar) / 48.0) ms)")
    }

    /// O tamanho que a libopus declara para o estado deste encoder. **Não** é a pegada: é o bloco
    /// que o `opus_encoder_create` aloca. Serve de piso e de conferência do número medido.
    static func tamanhoDeclarado(canais: Int32) -> Int32 { opus_encoder_get_size(canais) }

    func codificar(_ pcm: UnsafePointer<opus_int16>, quadros: Int32, saida: UnsafeMutablePointer<UInt8>,
                   capacidade: Int32) -> Int32 {
        guard let ptr else { return -1 }
        return opus_encode(ptr, pcm, quadros, saida, capacidade)
    }

    deinit { if let ptr { opus_encoder_destroy(ptr) } }
}

struct Tela: View {
    @State private var linhas: [String] = ["toque em Medir, ou passe --medir no lançamento"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Portão Opus").font(.largeTitle.bold())
            Text("custo de memória do encoder de Opus, medido no aparelho")
                .font(.caption).foregroundColor(.secondary)
            Button("Medir") { linhas = Medicao.correr() }
                .buttonStyle(.borderedProminent)
            ScrollView {
                Text(linhas.joined(separator: "\n")).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onAppear {
            if CommandLine.arguments.contains("--medir") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { linhas = Medicao.correr() }
            }
        }
    }
}

enum Medicao {
    /// 20 ms a 48 kHz — `DURACAO_DO_QUADRO_MS` do núcleo. 960 amostras por canal.
    static let amostrasPorQuadro: Int32 = 960

    static func correr() -> [String] {
        var saida: [String] = []
        func diz(_ t: String) { saida.append(t); Diario.dizer(t) }

        diz("OPUS versão=\(String(cString: opus_get_version_string()))")
        diz("OPUS aparelho=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) "
            + "ram=\(ProcessInfo.processInfo.physicalMemory)")
        diz("OPUS declarado mono=\(Encoder.tamanhoDeclarado(canais: 1)) B "
            + "estereo=\(Encoder.tamanhoDeclarado(canais: 2)) B")

        let base = Diario.pegadaEmBytes
        diz("OPUS fase=base pegada=\(base) disponivel=\(Diario.disponivelEmBytes) "
            + "orcamento=\(base + Diario.disponivelEmBytes)")

        // PRESET_MICROFONE: 1 canal, 32 kbit/s, FEC ligado, 5% de perda declarada, fala.
        guard let mic = Encoder(nome: "microfone", canais: 1, taxaDeBits: 32_000,
                                fec: true, perdaPct: 5, fala: true) else {
            diz("!! não deu para criar o encoder de microfone"); return saida
        }
        let depoisMic = Diario.pegadaEmBytes
        diz("OPUS fase=criou_microfone pegada=\(depoisMic) delta=\(depoisMic - base)")

        // PRESET_AUDIO_DO_SISTEMA: 2 canais, 128 kbit/s, sem FEC, não é fala.
        guard let sistema = Encoder(nome: "sistema", canais: 2, taxaDeBits: 128_000,
                                    fec: false, perdaPct: 0, fala: false) else {
            diz("!! não deu para criar o encoder de sistema"); return saida
        }
        let depoisSistema = Diario.pegadaEmBytes
        diz("OPUS fase=criou_sistema pegada=\(depoisSistema) delta=\(depoisSistema - depoisMic) "
            + "delta_acumulado=\(depoisSistema - base)")

        // --- rodar de verdade -------------------------------------------------------------------
        // **Criar não é rodar.** A libopus aloca o estado no create, mas as tabelas do CELT/SILK e
        // as pilhas de análise só tocam página na primeira chamada — é por isso que a medição
        // segue depois de encodar, e não para no create.
        let pcmMono = sinal(canais: 1)
        let pcmEstereo = sinal(canais: 2)
        var pacote = [UInt8](repeating: 0, count: 4000)

        var picoDepoisDeRodar = 0
        var bytesMic = 0, bytesSistema = 0
        // 1500 quadros de 20 ms = 30 s de áudio de cada lado.
        let quadros = 1500
        for i in 0..<quadros {
            pcmMono.withUnsafeBufferPointer { m in
                _ = pacote.withUnsafeMutableBufferPointer { p in
                    let n = mic.codificar(m.baseAddress!, quadros: amostrasPorQuadro,
                                          saida: p.baseAddress!, capacidade: Int32(p.count))
                    if n > 0 { bytesMic += Int(n) }
                    return n
                }
            }
            pcmEstereo.withUnsafeBufferPointer { e in
                _ = pacote.withUnsafeMutableBufferPointer { p in
                    let n = sistema.codificar(e.baseAddress!, quadros: amostrasPorQuadro,
                                              saida: p.baseAddress!, capacidade: Int32(p.count))
                    if n > 0 { bytesSistema += Int(n) }
                    return n
                }
            }
            if i % 100 == 0 { picoDepoisDeRodar = max(picoDepoisDeRodar, Diario.pegadaEmBytes) }
        }

        let fim = Diario.pegadaEmBytes
        picoDepoisDeRodar = max(picoDepoisDeRodar, fim)
        diz("OPUS fase=rodou quadros=\(quadros) pegada=\(fim) pico=\(picoDepoisDeRodar) "
            + "delta_total=\(picoDepoisDeRodar - base)")
        diz(String(format: "OPUS taxa_medida microfone=%.1f kbit/s sistema=%.1f kbit/s",
                   Double(bytesMic) * 8 / (Double(quadros) * 0.020) / 1000,
                   Double(bytesSistema) * 8 / (Double(quadros) * 0.020) / 1000))
        diz("OPUS fase=fim disponivel=\(Diario.disponivelEmBytes) "
            + "orcamento=\(fim + Diario.disponivelEmBytes)")
        diz(String(format: "OPUS VEREDITO os dois encoders custam %.2f MB de pegada; "
                   + "o teto da appex no iPhone 7 é 50 MB e o regime dela sem áudio é 5,23–7,06 MB",
                   Double(picoDepoisDeRodar - base) / 1_048_576))
        return saida
    }

    /// Um sinal de entrada plausível: senoide mais ruído. O conteúdo muda a taxa de bits, não a
    /// memória — ver a ressalva no topo do arquivo.
    private static func sinal(canais: Int) -> [opus_int16] {
        var v = [opus_int16](repeating: 0, count: Int(amostrasPorQuadro) * canais)
        for i in 0..<Int(amostrasPorQuadro) {
            let t = Double(i) / 48_000
            let onda = sin(2 * Double.pi * 440 * t) * 0.3 + Double.random(in: -0.05...0.05)
            let amostra = opus_int16(max(-32_000, min(32_000, onda * 32_000)))
            for c in 0..<canais { v[i * canais + c] = amostra }
        }
        return v
    }
}

import UIKit
