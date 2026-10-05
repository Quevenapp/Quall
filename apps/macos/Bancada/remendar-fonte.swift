// Reescreve o SPS de uma origem sintética de bancada (`gerar-fonte.swift`: VideoToolbox, SPS de
// 10 bytes **sem VUI**) para ele declarar `bitstream_restriction` com `max_num_reorder_frames = 0`,
// pelo **mesmo** `RemendoDeSPS` que o emissor do Mac usa antes de mandar (a S7, `docs/som-no-receptor.md`
// §20.15). É o controle da hipótese dos −81 ms da T2: sem a restrição, o decodificador da Microsoft
// segura ~5 quadros (`apps/windows/src/sps.rs`, `RemendoDeSPS.swift`); com ela, não deveria.
//
// Só o SPS muda: cada NAL de tipo 7 é trocado pelo reescrito, o resto do Annex-B passa igual, e o
// sidecar sai com o `bytes` de cada quadro recontado. Recusa (saída 2) se algum SPS não reescrever.
//
// Uso (compilar junto com o remendo, que é interno ao `QuallCaptureKit`):
//   swiftc -O apps/macos/Bancada/remendar-fonte.swift apps/macos/Sources/QuallCaptureKit/RemendoDeSPS.swift \
//     -o /tmp/quall-exemplo
//   remendar-fonte ENTRADA.json SAIDA.json      (o .h264 de saída fica ao lado, com o nome do .json)
import Foundation

@main
struct RemendarFonte {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write("uso: remendar-fonte ENTRADA.json SAIDA.json\n".data(using: .utf8)!)
            exit(2)
        }
        let entrada = URL(fileURLWithPath: args[1])
        let saida = URL(fileURLWithPath: args[2])
        guard var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: entrada))) as? [String: Any],
              var header = json["header"] as? [String: Any],
              let quadros = json["frames"] as? [[String: Any]],
              let arquivo = header["video_file"] as? String,
              let video = try? Data(contentsOf: entrada.deletingLastPathComponent().appendingPathComponent(arquivo))
        else { falhar("não li a origem \(entrada.path)") }
        let cheia = (header["color_range"] as? String) == "full"
        let sinal = RemendoDeSPS.SinalDeVideo(faixaCheia: cheia, cor: nil)

        let bytes = [UInt8](video)
        var novo = [UInt8]()
        var novosQuadros = [[String: Any]]()
        var pos = 0
        var reescritos = 0
        var tamanhos = Set<String>()
        for var q in quadros {
            guard let n = q["bytes"] as? Int, pos + n <= bytes.count else { falhar("o sidecar passa do .h264") }
            let quadro = Array(bytes[pos..<(pos + n)])
            pos += n
            var saidaDoQuadro = [UInt8]()
            for (prefixo, nal) in nals(quadro) {
                saidaDoQuadro += prefixo
                if let t = nal.first, (t & 0x1F) == 7 {
                    switch RemendoDeSPS.comVui(nal, sinal: sinal) {
                    case .success(let r):
                        saidaDoQuadro += r
                        reescritos += 1
                        tamanhos.insert("\(nal.count)->\(r.count)")
                    case .failure(let f):
                        falhar("um SPS não reescreveu: \(f)")
                    }
                } else {
                    saidaDoQuadro += nal
                }
            }
            q["bytes"] = saidaDoQuadro.count
            novo += saidaDoQuadro
            novosQuadros.append(q)
        }
        guard reescritos > 0 else { falhar("nenhum SPS na origem") }
        let nomeDoVideo = saida.deletingPathExtension().lastPathComponent + ".h264"
        header["video_file"] = nomeDoVideo
        json["header"] = header
        json["frames"] = novosQuadros
        do {
            try Data(novo).write(to: saida.deletingLastPathComponent().appendingPathComponent(nomeDoVideo))
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: saida)
        } catch { falhar("não gravei: \(error)") }
        print("remendar-fonte: \(reescritos) SPS reescritos (\(tamanhos.sorted().joined(separator: ", ")) bytes), "
              + "\(quadros.count) quadros, \(bytes.count) -> \(novo.count) bytes; faixa \(cheia ? "cheia" : "de vídeo")")
    }

    /// Os NAL de um quadro Annex-B, cada um com o prefixo (start code de 3 ou 4 bytes) que o precede.
    static func nals(_ b: [UInt8]) -> [([UInt8], [UInt8])] {
        var inicios = [(Int, Int)]()   // (onde começa o start code, tamanho dele)
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let quatro = i > 0 && b[i - 1] == 0
                inicios.append((quatro ? i - 1 : i, quatro ? 4 : 3))
                i += 3
            } else {
                i += 1
            }
        }
        var r = [([UInt8], [UInt8])]()
        for (k, (s, t)) in inicios.enumerated() {
            let fim = k + 1 < inicios.count ? inicios[k + 1].0 : b.count
            r.append((Array(b[s..<(s + t)]), Array(b[(s + t)..<fim])))
        }
        return r
    }

    static func falhar(_ m: String) -> Never {
        FileHandle.standardError.write("remendar-fonte: \(m)\n".data(using: .utf8)!)
        exit(2)
    }
}
