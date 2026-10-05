import Foundation
import AVFoundation

/// A leitura de volta do MP4, e a conferência dos órfãos de um fim abrupto.
///
/// A pergunta do §5.4 é se `movieFragmentInterval` deixa o arquivo legível até o último fragmento
/// quando o processo some. A sonda responde duas vezes: aqui, lendo **cada amostra** pelo
/// `AVAssetReader` na abertura seguinte (o que o app do produto faria para publicar o pendente), e
/// no Mac com `ffprobe` (o que qualquer editor faria). Uma leitura que só olhasse `duration`
/// confiaria no cabeçalho, que é justamente o que um fim abrupto pode deixar errado.
enum Orfao {

    /// Lê o arquivo inteiro. Síncrono e demorado (segundos): chame fora da fila principal.
    static func ler(_ url: URL) -> [String: Any] {
        var r: [String: Any] = ["arquivo": url.lastPathComponent]
        let tamanho = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        r["bytes"] = tamanho
        let asset = AVURLAsset(url: url)
        r["duracao_s"] = CMTimeGetSeconds(asset.duration)
        r["legivel_pelo_avasset"] = asset.isReadable
        for (nome, tipo) in [("video", AVMediaType.video), ("audio", AVMediaType.audio)] {
            guard let trilha = asset.tracks(withMediaType: tipo).first else {
                r[nome] = ["existe": false]
                continue
            }
            r[nome] = contar(asset: asset, trilha: trilha)
        }
        return r
    }

    private static func contar(asset: AVAsset, trilha: AVAssetTrack) -> [String: Any] {
        var r: [String: Any] = ["existe": true, "nominal_fps": trilha.nominalFrameRate]
        do {
            let leitor = try AVAssetReader(asset: asset)
            let saida = AVAssetReaderTrackOutput(track: trilha, outputSettings: nil)
            saida.alwaysCopiesSampleData = false
            leitor.add(saida)
            guard leitor.startReading() else {
                r["erro"] = "\(String(describing: leitor.error))"
                return r
            }
            var n = 0
            var primeiro = CMTime.invalid
            var ultimo = CMTime.invalid
            while let a = saida.copyNextSampleBuffer() {
                let k = CMSampleBufferGetNumSamples(a)
                if k == 0 { continue }
                n += k
                let p = CMSampleBufferGetPresentationTimeStamp(a)
                if !primeiro.isValid { primeiro = p }
                ultimo = p
            }
            r["amostras"] = n
            r["estado_do_leitor"] = leitor.status.rawValue
            if leitor.status == .failed { r["erro"] = "\(String(describing: leitor.error))" }
            if primeiro.isValid {
                r["primeiro_pts_s"] = CMTimeGetSeconds(primeiro)
                r["ultimo_pts_s"] = CMTimeGetSeconds(ultimo)
                r["extensao_s"] = CMTimeGetSeconds(CMTimeSubtract(ultimo, primeiro))
            }
        } catch {
            r["erro"] = "\(error)"
        }
        return r
    }

    /// Procura relatos de fim abrupto ainda não conferidos, lê o MP4 de cada um, grava o
    /// resultado no mesmo JSON (chave `orfao`) e devolve as linhas de veredito.
    static func conferirPendentes() -> [String] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let arquivos = (try? FileManager.default.contentsOfDirectory(at: docs,
                                                                    includingPropertiesForKeys: nil)) ?? []
        var linhas: [String] = []
        for j in arquivos where j.pathExtension == "json" {
            guard let d = try? Data(contentsOf: j),
                  var r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  (r["fim_abrupto"] as? Bool) == true, r["orfao"] == nil,
                  let nome = r["arquivo"] as? String else { continue }
            let leitura = ler(docs.appendingPathComponent(nome))
            let writer = r["writer"] as? [String: Any] ?? [:]
            let anexados = writer["video_anexados"] as? Int ?? 0
            let esperadoS = writer["ultimo_pts_gravado_s"] as? Double ?? 0
            let fragmento = r["fragmento_s"] as? Double ?? 2
            let video = leitura["video"] as? [String: Any] ?? [:]
            let audio = leitura["audio"] as? [String: Any] ?? [:]
            let lidos = video["amostras"] as? Int ?? 0
            let extensao = video["extensao_s"] as? Double ?? 0
            let faltamS = esperadoS - extensao
            var v: String
            if lidos == 0 || video["erro"] != nil {
                v = "VEREDITO ÓRFÃO: ILEGÍVEL — \(nome): \(lidos) quadros lidos"
                    + (video["erro"].map { ", erro \($0)" } ?? "")
            } else {
                let dentro = faltamS <= 2 * fragmento + 1
                v = String(format: "VEREDITO ÓRFÃO: LEGÍVEL%@ — %@: %d de %d quadros, "
                           + "%.1f s de %.1f s (faltam %.1f s; fragmento de %.0f s), som %d pacotes AAC",
                           dentro ? "" : " COM PERDA ACIMA DE 2 FRAGMENTOS", nome, lidos, anexados,
                           extensao, esperadoS, faltamS, fragmento, audio["amostras"] as? Int ?? 0)
            }
            r["orfao"] = leitura
            r["orfao_faltam_s"] = faltamS
            r["veredito_orfao"] = v
            if let novo = try? JSONSerialization.data(withJSONObject: r,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? novo.write(to: j, options: .atomic)
            }
            NSLog("SONDA-R5 %@", v)
            linhas.append(v)
        }
        return linhas
    }
}
