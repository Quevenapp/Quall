#if COM_NUCLEO
import Foundation
import CoreVideo
import CoreMedia

/// Ensaio geral do degrau 4, **no processo do app** e sem toque humano.
///
/// A medição que importa acontece na extension, e cada transmissão custa um toque em "Iniciar
/// Transmissão" que o iPhone 7 não automatiza. Mas quase tudo o que pode dar errado entre
/// "compila" e "o vídeo atravessa a LAN" falha igual num app comum:
///
/// * a permissão de rede local do iOS 14+ foi concedida de verdade;
/// * `quall_host` consegue `bind` na 7877 e aceitar a conexão do MacBook;
/// * o pareamento por PIN fecha, o ICE do libjuice fecha, o DTLS-SRTP sobe;
/// * a track de tela abre e o receptor a enxerga;
/// * o VideoToolbox do A10 encoda 720x1280 baseline em tempo real;
/// * `quall_track_send_frame` atravessa e o `.h264` do outro lado passa no `ffprobe`.
///
/// Nada disso precisa de ReplayKit — precisa de **quadros**, e o ensaio os fabrica: um
/// `CVPixelBuffer` 4:2:0 com padrão em movimento, encodado pelo **mesmo** `CodificadorH264` que
/// a appex usa e mandado pelo **mesmo** `Nucleo`.
///
/// O que o ensaio **não** prova, e por isso não entra no relato como se provasse: o teto de
/// 50 MB da extension, a pegada sob os buffers do ReplayKit, e o comportamento do processo que
/// o `replayd` cria. É pré-voo, não medição.
enum EnsaioDeSessao {

    private static var nucleo: Nucleo?
    private static var codificador: CodificadorH264?
    private static var pool: CVPixelBufferPool?
    private static var enviados: UInt64 = 0
    private static var giro = 0
    /// Teto de buffers vivos no pool do arnês. Seis a 720x1280 4:2:0 são ~8,3 MB.
    private static let tetoDoPool = 6
    private static var recusasDoPool: UInt64 = 0

    static func rodar(_ plano: Plano) {
        let thread = Thread {
            Diario.anotar("ENSAIO começando porta=\(plano.porta) pin=\(plano.pin)"
                + " dim=\(plano.largura)x\(plano.altura) fps=\(plano.fps)"
                + " enderecos=\(Enderecos.ipv4().joined(separator: " "))")
            Diario.anotar("ENSAIO chamando quall_host porta=\(plano.porta)"
                + " pegada=\(Diario.pegadaEmBytes)")

            let n = Nucleo()
            guard n.hospedar(pin: plano.pin, porta: plano.porta,
                             rotulo: "Ensaio do iPhone 7", prazoMs: 120_000) else {
                Diario.anotar("ENSAIO quall_host FALHOU erro=\(Nucleo.ultimoErro())"
                    + " motivo=\(n.ultimoMotivo)")
                return
            }
            Diario.anotar("ENSAIO sessao de pe porta=\(n.porta) par={\(n.parJson)}"
                + " pegada=\(Diario.pegadaEmBytes)")

            do {
                let c = try CodificadorH264(largura: plano.largura, altura: plano.altura,
                                            fps: plano.fps, bitrate: plano.bitrate,
                                            tetoEmVoo: plano.encodes_em_voo)
                c.aoSair = { annexb, pts, chave in
                    let carimbo = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
                    if n.enviar(annexb: annexb, timestampUs: carimbo, idr: chave) {
                        enviados += 1
                    }
                    if chave { n.idrEntregue() }
                }
                codificador = c
                nucleo = n
                Diario.anotar("ENSAIO encoder pronto hardware=\(c.porHardware)"
                    + " pegada=\(Diario.pegadaEmBytes)")
                bombear(plano, n, c)
            } catch {
                Diario.anotar("ENSAIO encoder FALHOU \(error)")
            }
        }
        thread.stackSize = 512 * 1024
        thread.name = "quall.ensaio"
        thread.start()
    }

    /// Gera, encoda e manda por `ensaio_s` segundos, relatando a cada segundo.
    private static func bombear(_ plano: Plano, _ n: Nucleo, _ c: CodificadorH264) {
        guard let pool = criarPool(Int(plano.largura), Int(plano.altura)) else {
            Diario.anotar("ENSAIO não consegui criar o pool de CVPixelBuffer")
            return
        }
        EnsaioDeSessao.pool = pool
        Diario.anotar("ENSAIO pool criado teto=\(tetoDoPool)"
            + " pegada=\(Diario.pegadaEmBytes)")

        let inicio = CFAbsoluteTimeGetCurrent()
        let intervalo = 1.0 / Double(plano.fps)
        var proximo = inicio
        var ultimoRelato = inicio

        while CFAbsoluteTimeGetCurrent() - inicio < plano.ensaio_s {
            proximo += intervalo
            // Teto no pool, e não `CVPixelBufferPoolCreatePixelBuffer` puro.
            //
            // `kCVPixelBufferPoolMinimumBufferCountKey` é **mínimo**: o pool cresce sem limite
            // enquanto alguém segurar buffers, e cada um custa 1,38 MB em 720x1280 4:2:0. Numa
            // corrida a 70 MB de pegada contra outra a 39 MB, com o mesmo código, o pool é o
            // primeiro suspeito — e um suspeito que não dá para descartar por raciocínio, porque
            // ninguém publica quantos buffers ele guardou.
            //
            // Com o teto, o pool **recusa** em vez de crescer, o arnês descarta o quadro (que é
            // o comportamento certo de "empacota e solta") e a recusa aparece no log. Isto é do
            // ensaio, não do produto: a appex recebe os `CVPixelBuffer` do ReplayKit e não
            // aloca pool nenhum.
            var imagem: CVPixelBuffer?
            let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: tetoDoPool]
            let estado = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                nil, pool, aux as CFDictionary, &imagem)
            if estado == kCVReturnWouldExceedAllocationThreshold {
                recusasDoPool += 1
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            guard estado == kCVReturnSuccess, let imagem else { break }
            pintar(imagem)

            giro += 1
            let pts = CMTime(value: CMTimeValue(giro), timescale: plano.fps)
            n.recolherPedidoDeIdr()
            c.encodar(imagem, pts: pts, duracao: CMTime(value: 1, timescale: plano.fps),
                      forcarIDR: n.precisaDeIdr)

            let agora = CFAbsoluteTimeGetCurrent()
            if agora - ultimoRelato >= 1.0 {
                ultimoRelato = agora
                let f = n.fotografia
                Diario.anotar(String(format:
                    "ENSAIO t=%.1f gerados=%d enviados=%llu recusados=%llu status=%d"
                    + " saida=%@ maior_quadro=%d cresc=%d desc_fila=%llu desc_enc=%llu"
                    + " pool_recusou=%llu pegada=%llu nucleo{%@}",
                    agora - inicio, giro, f.enviados, f.recusados, Int(f.ultimoStatus),
                    c.dimensaoDaSaida, c.maiorQuadro, c.crescimentosDoBuffer,
                    c.descartadosPorFila, c.descartadosPeloEncoder,
                    recusasDoPool, Diario.pegadaEmBytes, n.estatisticasDaTrack))
            }

            let sobra = proximo - CFAbsoluteTimeGetCurrent()
            if sobra > 0 { Thread.sleep(forTimeInterval: sobra) } else { proximo = CFAbsoluteTimeGetCurrent() }
        }

        Diario.anotar("ENSAIO drenando o VideoToolbox")
        c.encerrar()
        let f = n.fotografia
        Diario.anotar("ENSAIO fim gerados=\(giro) enviados=\(f.enviados)"
            + " recusados=\(f.recusados) nucleo{\(n.estatisticasDaTrack)}")
        // Fecha a sessão aqui, e não no `deinit`: no app não há prazo de sistema, então é o
        // lugar seguro para exercitar `quall_session_close` com o par ainda vivo.
        n.encerrar()
        Diario.anotar("ENSAIO sessao fechada pegada=\(Diario.pegadaEmBytes)")
    }

    private static func criarPool(_ largura: Int, _ altura: Int) -> CVPixelBufferPool? {
        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey: largura,
            kCVPixelBufferHeightKey: altura,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let estado = CVPixelBufferPoolCreate(
            nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            atributos as CFDictionary, &pool)
        return estado == kCVReturnSuccess ? pool : nil
    }

    /// Duas linhas de padrão, refeitas por quadro e copiadas por linha. Ver `pintar`.
    private static var risco: UnsafeMutablePointer<UInt8>?
    private static var riscoLargura = 0

    /// Padrão em movimento com muita aresta: um tabuleiro que anda.
    ///
    /// Conteúdo importa. Uma tela chapada comprime a quase nada, e o ensaio mediria um caminho
    /// de quadros de 200 bytes — que não é o caminho que o produto vai percorrer.
    ///
    /// **Duas linhas por quadro, memcpy no resto.** A primeira versão escrevia pixel a pixel, em
    /// Swift, os 921 600 bytes do plano Y: o ensaio rodou a **1,9 fps** e mediu o meu gerador em
    /// vez do encoder. O gargalo do instrumento vira resultado do sistema se ninguém olhar — é
    /// exatamente o tipo de erro que este projeto já cometeu três vezes.
    private static func pintar(_ imagem: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(imagem, [])
        defer { CVPixelBufferUnlockBaseAddress(imagem, []) }

        let largura = CVPixelBufferGetWidthOfPlane(imagem, 0)
        let altura = CVPixelBufferGetHeightOfPlane(imagem, 0)
        let passo = CVPixelBufferGetBytesPerRowOfPlane(imagem, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(imagem, 0) else { return }
        let y = base.assumingMemoryBound(to: UInt8.self)
        let deslocamento = giro * 7

        if riscoLargura != largura {
            risco?.deallocate()
            risco = UnsafeMutablePointer<UInt8>.allocate(capacity: largura * 2)
            riscoLargura = largura
        }
        guard let risco else { return }
        for coluna in 0..<largura {
            let quadra = ((coluna + deslocamento) / 24) % 2
            let ruido = UInt8(truncatingIfNeeded: (coluna &* 37 &+ giro) & 0x1F)
            risco[coluna] = (quadra == 0 ? 16 : 210) &+ ruido
            risco[largura + coluna] = (quadra == 0 ? 210 : 16) &+ ruido
        }

        for linha in 0..<altura {
            let faixa = ((linha + deslocamento) / 24) % 2
            memcpy(y + linha * passo, risco + (faixa == 0 ? 0 : largura), largura)
        }

        // Croma cinza: o teste é de arestas e movimento, não de cor.
        if CVPixelBufferGetPlaneCount(imagem) > 1,
           let uv = CVPixelBufferGetBaseAddressOfPlane(imagem, 1) {
            memset(uv, 128,
                   CVPixelBufferGetBytesPerRowOfPlane(imagem, 1)
                       * CVPixelBufferGetHeightOfPlane(imagem, 1))
        }
    }
}
#endif
