import Foundation
import CoreMedia
import AudioToolbox

/// Um tom de 1 kHz a −12 dBFS, PCM 16 bits mono 48 kHz, gerado aqui — **não** do microfone.
///
/// O relógio do tom é o da câmera: o primeiro bloco nasce no PTS do primeiro quadro gravado, e cada
/// quadro que chega puxa blocos de 1024 amostras até alcançá-lo. Assim o som não deriva do vídeo, e
/// o que se mede é o custo do AAC no `AVAssetWriter`, que é o que a fase 0 quer saber.
final class TomSintetico {
    static let taxa: Int32 = 48_000
    static let bloco = 1024
    let frequencia: Double = 1000
    let amplitude: Double = 0.25 // −12 dBFS

    private var formato: CMAudioFormatDescription?
    private var fase: Double = 0
    private var inicio: CMTime = .invalid
    private(set) var amostrasGeradas: Int64 = 0

    init() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.taxa), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &formato)
    }

    /// Os blocos que faltam para o som alcançar `ate` (o PTS do quadro que acabou de chegar).
    func blocos(ate: CMTime) -> [CMSampleBuffer] {
        if !inicio.isValid { inicio = ate }
        var saida: [CMSampleBuffer] = []
        while true {
            let pts = CMTimeAdd(inicio, CMTime(value: amostrasGeradas, timescale: Self.taxa))
            let fim = CMTimeAdd(pts, CMTime(value: Int64(Self.bloco), timescale: Self.taxa))
            if CMTimeCompare(fim, ate) > 0 { break }
            if let b = gerar(pts: pts) { saida.append(b) }
            amostrasGeradas += Int64(Self.bloco)
        }
        return saida
    }

    private func gerar(pts: CMTime) -> CMSampleBuffer? {
        guard let formato = formato else { return nil }
        let n = Self.bloco
        var pcm = [Int16](repeating: 0, count: n)
        let passo = 2 * Double.pi * frequencia / Double(Self.taxa)
        for i in 0..<n {
            pcm[i] = Int16(amplitude * 32767 * sin(fase))
            fase += passo
            if fase > 2 * Double.pi { fase -= 2 * Double.pi }
        }
        var bloco: CMBlockBuffer?
        let bytes = n * 2
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bloco) == noErr,
              let bloco = bloco else { return nil }
        let st = pcm.withUnsafeBytes { p in
            CMBlockBufferReplaceDataBytes(with: p.baseAddress!, blockBuffer: bloco,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard st == noErr else { return nil }
        var amostra: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: bloco, formatDescription: formato, sampleCount: n,
            presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &amostra) == noErr else { return nil }
        return amostra
    }
}
