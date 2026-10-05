import Darwin
import Foundation

/// O fio entre os dois processos.
///
/// Soquete de domínio Unix, `SOCK_STREAM`. Não é a rede e não pretende ser: é o menor elo
/// possível entre os dois processos, e o seu custo é **medido** (`t_envio_ns` no emissor contra
/// `t_chegada_ns` no receptor, mesmo relógio) em vez de suposto. Quando a track de verdade
/// entrar no lugar dele, o cabeçalho de quadro não muda.
public enum Fio {
    public static let magico: UInt32 = 0x5156_4431  // "QVD1"
    public static let tamanhoDoCabecalho = 64

    public struct Cabecalho {
        /// Índice do quadro lido **nos pixels capturados** — não o que o emissor achava que tinha
        /// desenhado. A diferença entre os dois é defeito, e defeito tem de aparecer.
        public var indice: UInt32
        /// Instante previsto de varredura do quadro do emissor que carregava esse índice.
        /// Estimativa do CADisplayLink, não fóton — é o que o laço local consegue.
        public var desenhoNs: UInt64
        /// Instante em que o desenho foi **entregue ao render server** (retorno do
        /// `CATransaction.flush()`). Essa é a âncora certa para "a janela mudou" quando o
        /// consumidor é o compositor, e não o painel: medido, o ScreenCaptureKit toca no
        /// compositor ANTES da varredura prevista, o que fazia `desenho → pts` sair negativo.
        public var commitNs: UInt64
        /// Instante em que o quadro chegou ao processo, no retorno do ScreenCaptureKit.
        public var capturaNs: UInt64
        /// `presentationTimeStamp` do ScreenCaptureKit já trazido para a base canônica.
        public var ptsNs: UInt64
        /// Instante em que o VideoToolbox devolveu o quadro codificado.
        public var encodeNs: UInt64
        /// Instante imediatamente antes do `write` no fio.
        public var envioNs: UInt64
        public var idr: Bool
        public var tamanho: UInt32

        public init(
            indice: UInt32, desenhoNs: UInt64, commitNs: UInt64, capturaNs: UInt64, ptsNs: UInt64,
            encodeNs: UInt64, envioNs: UInt64, idr: Bool, tamanho: UInt32
        ) {
            self.indice = indice
            self.desenhoNs = desenhoNs
            self.commitNs = commitNs
            self.capturaNs = capturaNs
            self.ptsNs = ptsNs
            self.encodeNs = encodeNs
            self.envioNs = envioNs
            self.idr = idr
            self.tamanho = tamanho
        }

        public func serializar() -> Data {
            var d = Data(capacity: tamanhoDoCabecalho)
            func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
            func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
            u32(magico)
            u32(indice)
            u64(desenhoNs)
            u64(commitNs)
            u64(capturaNs)
            u64(ptsNs)
            u64(encodeNs)
            u64(envioNs)
            d.append(idr ? 1 : 0)
            d.append(contentsOf: [0, 0, 0])
            u32(tamanho)
            precondition(d.count == tamanhoDoCabecalho, "cabeçalho com \(d.count) bytes")
            return d
        }

        public static func desserializar(_ d: Data) -> Cabecalho? {
            guard d.count == tamanhoDoCabecalho else { return nil }
            return d.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Cabecalho? in
                func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
                func u64(_ o: Int) -> UInt64 { UInt64(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
                guard u32(0) == magico else { return nil }
                return Cabecalho(
                    indice: u32(4),
                    desenhoNs: u64(8),
                    commitNs: u64(16),
                    capturaNs: u64(24),
                    ptsNs: u64(32),
                    encodeNs: u64(40),
                    envioNs: u64(48),
                    idr: b[56] == 1,
                    tamanho: u32(60)
                )
            }
        }
    }

    // MARK: - Soquete

    public static func ouvir(em caminho: String) throws -> Int32 {
        unlink(caminho)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ErroDeFio.chamada("socket", errno) }
        var end = sockaddr_un()
        end.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(caminho.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: end.sun_path) else {
            close(fd)
            throw ErroDeFio.caminhoLongoDemais(caminho)
        }
        withUnsafeMutableBytes(of: &end.sun_path) { destino in
            destino.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
        }
        let tam = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &end) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, tam) }
        }
        guard ok == 0 else { close(fd); throw ErroDeFio.chamada("bind", errno) }
        guard listen(fd, 1) == 0 else { close(fd); throw ErroDeFio.chamada("listen", errno) }
        return fd
    }

    public static func conectar(em caminho: String, tentativasPorSegundo: Int = 20, segundos: Double = 20) throws -> Int32 {
        let limite = Date().addingTimeInterval(segundos)
        var ultimo: Int32 = 0
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ErroDeFio.chamada("socket", errno) }
            var end = sockaddr_un()
            end.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(caminho.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: end.sun_path) else {
                close(fd)
                throw ErroDeFio.caminhoLongoDemais(caminho)
            }
            withUnsafeMutableBytes(of: &end.sun_path) { destino in
                destino.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
            }
            let tam = socklen_t(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &end) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, tam) }
            }
            if r == 0 {
                desligarNagle(fd)
                return fd
            }
            ultimo = errno
            close(fd)
            usleep(useconds_t(1_000_000 / max(1, tentativasPorSegundo)))
        } while Date() < limite
        throw ErroDeFio.chamada("connect", ultimo)
    }

    public static func aceitar(_ ouvinte: Int32) throws -> Int32 {
        let fd = accept(ouvinte, nil, nil)
        guard fd >= 0 else { throw ErroDeFio.chamada("accept", errno) }
        desligarNagle(fd)
        return fd
    }

    private static func desligarNagle(_ fd: Int32) {
        // AF_UNIX não tem Nagle, mas o buffer de envio pequeno atrasa quadro grande.
        var tam: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &tam, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &tam, socklen_t(MemoryLayout<Int32>.size))
        var um: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &um, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func escreverTudo(_ fd: Int32, _ dados: Data) throws {
        try dados.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var restante = b.count
            var p = b.baseAddress!
            while restante > 0 {
                let n = write(fd, p, restante)
                if n > 0 {
                    restante -= n
                    p = p.advanced(by: n)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw ErroDeFio.chamada("write", errno)
                }
            }
        }
    }

    public static func lerTudo(_ fd: Int32, _ quantos: Int) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: quantos)
        var lidos = 0
        while lidos < quantos {
            let n = buffer.withUnsafeMutableBytes { b -> Int in
                read(fd, b.baseAddress!.advanced(by: lidos), quantos - lidos)
            }
            if n > 0 {
                lidos += n
            } else if n == 0 {
                return nil  // fim de fio
            } else if errno == EINTR {
                continue
            } else {
                throw ErroDeFio.chamada("read", errno)
            }
        }
        return Data(buffer)
    }

    public enum ErroDeFio: Error, CustomStringConvertible {
        case chamada(String, Int32)
        case caminhoLongoDemais(String)
        public var description: String {
            switch self {
            case .chamada(let nome, let e): return "\(nome) falhou: \(String(cString: strerror(e))) (\(e))"
            case .caminhoLongoDemais(let c): return "caminho de soquete longo demais: \(c)"
            }
        }
    }
}
