import AVFoundation
import Foundation
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit
import QuallTeleprompterKit
import SwiftUI

/// O estado da gravação, para a tela.
enum EstadoDaGravacao: Equatable {
    case parada
    /// Pedida: esperando o primeiro quadro entrar no arquivo.
    case abrindo
    /// `desde` é `systemUptime` (monotônico) do primeiro quadro.
    case gravando(desde: TimeInterval)
    /// O arquivo está fechando (o som que falta, o writer).
    case fechando

    var gravando: Bool { if case .gravando = self { return true }; return false }
    var ocupada: Bool { self != .parada }
}

/// De onde veio o pedido de gravar (o diário diz; no Mac não muda o que pode ser feito).
enum QuemPedeAGravacao: String {
    case toque, controle, bancada
}

/// **O gravador local do Mac** (R5 fase 4, `docs/teleprompter-com-camera.md` §5 e §8.9, item 7), da
/// tela R5 e da câmera comum. Decide se pode gravar, começa, para, e deixa o arquivo em
/// `~/Movies/Quall`.
///
/// O molde é o `GravadorLocal` do iOS (§8.7 e §8.8), sem o que é do iOS: não há Fotos (o arquivo já
/// nasce na pasta de vídeos), não há segundo plano que pare a câmera, não há giro. O resto é o mesmo:
///
/// - **grava a câmera sem o texto**, com o som do microfone (silêncio com o botão desligado), no
///   tamanho da captura, pelo segundo codificador (`TomadaDeGravacao`, a cópia do iOS);
/// - **não depende da rede**: a tomada assina o dono como qualquer um; o receptor entra, cai e volta,
///   e o arquivo segue;
/// - **recusa com motivo legível** (o texto que o controle remoto mostra, contrato §13.3);
/// - **para sozinho** quando a câmera cai ou para de entregar, quando o espaço cai abaixo de 300 MB,
///   quando o arquivo para de receber imagem, e quando a tela fecha;
/// - **gravar não liga o microfone** (Pessoa Exemplo, 24/09): com ele desligado, "Gravando SEM SOM — ligue o
///   microfone";
/// - **a marca `.Quall-….mp4.gravando`** (com o pid) mora ao lado do arquivo enquanto ele grava; o
///   processo morto a deixa, e a abertura seguinte trata o órfão (`GravacoesPendentes`).
///
/// Só na principal.
final class GravadorLocal: ObservableObject {

    @Published private(set) var estado: EstadoDaGravacao = .parada
    /// A última palavra sobre um arquivo, ou uma recusa. Some sozinha em 15 s.
    @Published private(set) var recado: (texto: String, grave: Bool)?

    /// A gravação começou (`true`, o primeiro quadro está no arquivo) ou fechou (`false`).
    var aoMudar: ((Bool) -> Void)?

    let dono: DonoDaCamera
    let pasta: URL

    static var textoSemSom: String { T("Gravando SEM SOM — ligue o microfone") }
    static let semQuadroPorNoMaximo: Double = 2.0

    private var tomada: TomadaDeGravacao?
    private var ficha: FichaDoDono?
    private var numero = 0
    private var aoComecar: [(String?) -> Void] = []
    private var aoFechar: [() -> Void] = []
    private var supervisor: Timer?
    private var voltas = 0
    private var vezDoRecado = 0

    init(dono: DonoDaCamera, pasta: URL) {
        self.dono = dono
        self.pasta = pasta
    }

    /// `~/Movies/Quall`, ou a da bancada (`--pasta-de-gravacoes`).
    static func pastaPadrao(_ argumentos: Argumentos) -> URL {
        if let p = argumentos.pastaDeGravacoes {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        let filmes = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return filmes.appendingPathComponent("Quall", isDirectory: true)
    }

    private func registrar(_ s: String) { Registro.compartilhado.linha("APP GRAVACAO " + s) }

    // --- começar -------------------------------------------------------------------------------

    /// Pede para gravar. `fim(nil)` quando o primeiro quadro está no arquivo; `fim(motivo)` quando
    /// não vai gravar.
    func comecar(por quem: QuemPedeAGravacao, fim: @escaping (String?) -> Void) {
        switch estado {
        case .gravando: fim(nil); return
        case .abrindo: aoComecar.append(fim); return
        case .fechando:
            // O fecho dura menos de 1 s: o pedido espera ele e começa em seguida.
            aoFechar.append { [weak self] in self?.comecar(por: quem, fim: fim) }
            return
        case .parada: break
        }
        if let motivo = motivoParaNaoGravar() {
            recusar(motivo, quem: quem, fim: fim)
            return
        }
        do {
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        } catch {
            recusar(T("não foi possível criar a pasta %@: %@", pasta.path, error.localizedDescription), quem: quem, fim: fim)
            return
        }
        numero += 1
        var url = pasta.appendingPathComponent(GravadorLocal.nomeDoArquivo(Date()))
        var sufixo = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = pasta.appendingPathComponent(GravadorLocal.nomeDoArquivo(Date(), sufixo: sufixo))
            sufixo += 1
        }
        let n = numero
        let t = TomadaDeGravacao(url: url, numero: n, fps: 30) { Registro.compartilhado.linha($0) }
        tomada = t
        estado = .abrindo
        aoComecar.append(fim)
        GravacoesPendentes.marcar(url)
        t.aoPrimeiroQuadro = { [weak self, weak t] in
            guard let self, let t, self.tomada === t, self.estado == .abrindo else { return }
            self.estado = .gravando(desde: ProcessInfo.processInfo.systemUptime)
            self.registrar("#\(n) gravando (\(quem.rawValue)): o primeiro quadro está no arquivo; microfone="
                           + (self.dono.microfone.ligado ? "ligado" : "desligado (a trilha de som recebe silêncio)"))
            self.aoMudar?(true)
            let fs = self.aoComecar
            self.aoComecar = []
            for f in fs { f(nil) }
        }
        t.aoFalhar = { [weak self, weak t] motivo in
            guard let self, let t, self.tomada === t else { return }
            self.parar(motivo: motivo)
        }
        ficha = dono.assinar(nome: "gravador #\(n)", video: { [weak t] amostra, imagem in t?.quadro(amostra, imagem: imagem) },
                             som: { [weak t] amostra in t?.audio(amostra) })
        registrar("#\(n) pedida (\(quem.rawValue)): captura=\(dono.formatoRecebido) "
                  + "microfone=\(dono.microfone.ligado ? "ligado" : "desligado")")
        subirSupervisor()
        // O primeiro quadro tem 3 s para entrar no arquivo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak t] in
            guard let self, let t, self.tomada === t, self.estado == .abrindo else { return }
            self.parar(motivo: "a câmera não está entregando imagem")
        }
    }

    /// O que impede de gravar agora, conferido **antes** de abrir qualquer coisa. `nil`: pode.
    private func motivoParaNaoGravar() -> String? {
        guard dono.montado else { return T("a câmera não está aberta") }
        if !dono.interrupcao.isEmpty { return T("câmera interrompida: %@", GravadorLocal.curto(dono.interrupcao)) }
        guard let ha = dono.ultimoQuadroHa, ha < 1.0 else { return T("a câmera não está entregando imagem") }
        return nil
    }

    private func recusar(_ motivo: String, quem: QuemPedeAGravacao, fim: (String?) -> Void) {
        registrar("recusada (\(quem.rawValue)): \(motivo)")
        mostrarRecado(T("Não gravou: %@", motivo), grave: true)
        fim(motivo)
    }

    // --- parar ---------------------------------------------------------------------------------

    /// Para (o botão, o controle, a câmera, o espaço, a tela). `fim` quando o arquivo fechou.
    func parar(motivo: String, fim: (() -> Void)? = nil) {
        guard let t = tomada, estado != .parada else { fim?(); return }
        if let fim { aoFechar.append(fim) }
        guard estado != .fechando else { return }
        let comecou = estado.gravando
        estado = .fechando
        registrar("#\(t.numero) parando: \(motivo)")
        let esperando = aoComecar
        aoComecar = []
        for f in esperando { f(motivo) }
        // **Forte, de propósito**: a tela pode fechar com o arquivo fechando; o gravador vive até o
        // arquivo fechar.
        t.parar { resultado in
            if let f = self.ficha { self.dono.desassinar(f) }
            self.ficha = nil
            if self.tomada === t { self.tomada = nil }
            self.supervisor?.invalidate()
            self.supervisor = nil
            self.estado = .parada
            if comecou { self.aoMudar?(false) }
            self.terminar(resultado, motivo: motivo)
            let fs = self.aoFechar
            self.aoFechar = []
            for f in fs { f() }
        }
    }

    private func terminar(_ r: TomadaDeGravacao.Fim, motivo: String) {
        guard r.quadros > 0 else {
            GravacoesPendentes.desmarcar(r.url)
            if let e = r.erro { mostrarRecado(T("A gravação não começou: %@", e), grave: true) }
            return
        }
        let duracao = r.duracao.map { GravadorLocal.duracaoLegivel($0) } ?? "?"
        guard r.erro == nil else {
            // O arquivo não fechou direito: vira órfão e segue o caminho dele agora (a marca fica
            // até a recuperação terminar).
            mostrarRecado(T("A gravação parou com erro (%@); o que foi gravado fica em "
                          + "%@ como \"(interrompido)\".", r.erro ?? "", pasta.path), grave: true)
            GravacoesPendentes.soltarDoProcesso(r.url)
            GravacoesPendentes.recuperar(em: pasta, por: "uma gravação que fechou com erro")
            return
        }
        GravacoesPendentes.desmarcar(r.url)
        registrar("salva (\(duracao), \(r.bytes) bytes, parou por: \(motivo))")
        mostrarRecado(T("Gravação salva em %@ (%@): %@", pasta.lastPathComponent, duracao, r.url.lastPathComponent), grave: false)
    }

    // --- a supervisão, gravando ------------------------------------------------------------------

    private func subirSupervisor() {
        supervisor?.invalidate()
        voltas = 0
        supervisor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.supervisionar() }
    }

    private func supervisionar() {
        guard let t = tomada, estado.ocupada, estado != .fechando else { return }
        voltas += 1
        if !dono.interrupcao.isEmpty {
            parar(motivo: "câmera interrompida: \(GravadorLocal.curto(dono.interrupcao))")
            return
        }
        if estado.gravando, (dono.ultimoQuadroHa ?? 99) > GravadorLocal.semQuadroPorNoMaximo {
            parar(motivo: "a câmera parou de entregar imagem")
            return
        }
        if estado.gravando, (t.ultimoAnexadoHa ?? 99) > GravadorLocal.semQuadroPorNoMaximo {
            parar(motivo: "o arquivo parou de receber imagem (o codificador da gravação não está entregando)")
            return
        }

        if voltas % 10 == 0 { t.relatar() }
    }

    // --- recados e utilidades ----------------------------------------------------------------------

    private func mostrarRecado(_ texto: String, grave: Bool) {
        vezDoRecado += 1
        let vez = vezDoRecado
        recado = (texto, grave)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.vezDoRecado == vez else { return }
            self.recado = nil
        }
    }



    static func nomeDoArquivo(_ d: Date, sufixo: Int? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Quall-\(f.string(from: d))\(sufixo.map { "-\($0)" } ?? "").mp4"
    }

    static func duracaoLegivel(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func curto(_ s: String) -> String {
        let primeira = s.split(separator: ".", maxSplits: 1).first.map(String.init) ?? s
        return String(primeira.prefix(160))
    }
}

/// **Os arquivos que não fecharam** (§5.4): o órfão de um fim abrupto (o processo morto gravando) e o
/// que fechou com erro. Enquanto grava, cada arquivo tem ao lado a marca `.<nome>.gravando` com o pid
/// do processo; a abertura seguinte (a tela R5 ou a câmera comum) trata cada marca **sem processo
/// vivo**:
///
/// - **o som que passa do vídeo é aparado** sem recodificar (o achado da prova do iPhone X, §8.8: o
///   órfão tinha 1,1 s de som além da imagem): uma composição com o vídeo inteiro e o som só até o fim
///   dele, `AVAssetExportPresetPassthrough`;
/// - o arquivo fica como `Quall-… (interrompido).mp4`, na mesma pasta;
/// - sem vídeo legível (morto antes do primeiro fragmento), vira `.ilegivel` e não é mais tentado.
enum GravacoesPendentes {
    private static let fila = DispatchQueue(label: "quall.gravacao.pendentes", qos: .utility)
    private static let trava = NSLock()
    private static var ativos = Set<String>()
    static let sobraDeSomTolerada: Double = 0.05

    private static func marca(de url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".gravando")
    }

    /// Um arquivo começou a ser gravado **por este processo**: a marca (com o pid) vai ao disco.
    static func marcar(_ url: URL) {
        trava.withLock { _ = ativos.insert(url.lastPathComponent) }
        try? "\(getpid())\n".write(to: marca(de: url), atomically: true, encoding: .utf8)
    }

    /// Fechou direito: a marca sai.
    static func desmarcar(_ url: URL) {
        trava.withLock { _ = ativos.remove(url.lastPathComponent) }
        try? FileManager.default.removeItem(at: marca(de: url))
    }

    /// Fechou com erro: deixa de ser deste processo (a recuperação pode tratá-lo), e a marca fica.
    static func soltarDoProcesso(_ url: URL) {
        trava.withLock { _ = ativos.remove(url.lastPathComponent) }
        try? "0\n".write(to: marca(de: url), atomically: true, encoding: .utf8)
    }

    private static func ativo(_ nome: String) -> Bool { trava.withLock { ativos.contains(nome) } }

    /// O pid da marca ainda vive (outra instância gravando)?
    private static func vivo(_ marca: URL) -> Bool {
        guard let t = try? String(contentsOf: marca, encoding: .utf8),
              let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        if pid == getpid() { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Trata os órfãos da pasta, numa fila própria.
    static func recuperar(em pasta: URL, por motivo: String) {
        fila.async {
            let nomes = ((try? FileManager.default.contentsOfDirectory(atPath: pasta.path)) ?? [])
                .filter { $0.hasPrefix(".") && $0.hasSuffix(".mp4.gravando") }
            var achados: [URL] = []
            for m in nomes {
                let marcaURL = pasta.appendingPathComponent(m)
                let nome = String(m.dropFirst().dropLast(".gravando".count))
                guard !ativo(nome), !vivo(marcaURL) else { continue }
                achados.append(pasta.appendingPathComponent(nome))
            }
            guard !achados.isEmpty else { return }
            Registro.compartilhado.linha("APP GRAVACAO pendentes: \(achados.count) achados (\(motivo)): "
                                          + "lista de nomes omitida")
            var feitos = 0
            for url in achados where tratarUm(url) { feitos += 1 }
            Registro.compartilhado.linha("APP GRAVACAO pendentes: \(feitos) de \(achados.count) recuperados")
        }
    }

    /// Síncrono, na `fila`. `true` quando o arquivo ficou legível como "(interrompido)".
    private static func tratarUm(_ url: URL) -> Bool {
        let nome = url.lastPathComponent
        defer { try? FileManager.default.removeItem(at: marca(de: url)) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Registro.compartilhado.linha("APP GRAVACAO pendente: o arquivo não existe (só a marca); marca apagada")
            return false
        }
        let asset = AVURLAsset(url: url)
        let video = asset.tracks(withMediaType: .video).first
        let audio = asset.tracks(withMediaType: .audio).first
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        let dur = CMTimeGetSeconds(asset.duration)
        let fimDoVideo = video.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRange)) } ?? -1
        let fimDoSom = audio.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRange)) } ?? -1
        Registro.compartilhado.linha(String(format: "APP GRAVACAO pendente: bytes=%lld duracao=%.3f s video=%@ som=%@"
                                            + " fim_do_video=%.3f s fim_do_som=%.3f s",
                                            bytes, dur.isFinite ? dur : -1, video == nil ? "não" : "sim",
                                            audio == nil ? "não" : "sim", fimDoVideo.isFinite ? fimDoVideo : -1,
                                            fimDoSom.isFinite ? fimDoSom : -1))
        let base = (nome as NSString).deletingPathExtension
        let destino = url.deletingLastPathComponent().appendingPathComponent("\(base) (interrompido).mp4")
        guard let v = video, dur.isFinite, dur > 0 else {
            let novo = url.appendingPathExtension("ilegivel")
            try? FileManager.default.moveItem(at: url, to: novo)
            Registro.compartilhado.linha("APP GRAVACAO pendente sem vídeo legível: renomeado para arquivo ilegível")
            return false
        }
        if let a = audio, fimDoVideo.isFinite, fimDoSom.isFinite, fimDoSom - fimDoVideo > sobraDeSomTolerada {
            let aparado = url.deletingLastPathComponent().appendingPathComponent(".aparado-" + nome)
            if aparar(asset, video: v, audio: a, nome: nome, saida: aparado) {
                try? FileManager.default.removeItem(at: destino)
                if (try? FileManager.default.moveItem(at: aparado, to: destino)) != nil {
                    try? FileManager.default.removeItem(at: url)
                    Registro.compartilhado.linha("APP GRAVACAO pendente recuperado com o som aparado ao fim do vídeo")
                    return true
                }
                try? FileManager.default.removeItem(at: aparado)
            }
            // Aparar falhou: fica como está, com o som sobrando (melhor que o arquivo perdido).
        }
        try? FileManager.default.removeItem(at: destino)
        guard (try? FileManager.default.moveItem(at: url, to: destino)) != nil else {
            Registro.compartilhado.linha("APP GRAVACAO pendente: não consegui renomear; fica como está")
            return false
        }
        Registro.compartilhado.linha("APP GRAVACAO pendente recuperado como está")
        return true
    }

    /// **Apara o som ao fim do último quadro de vídeo**, sem recodificar (a regra do iOS, §8.8).
    private static func aparar(_ asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack, nome: String,
                               saida: URL) -> Bool {
        try? FileManager.default.removeItem(at: saida)
        let composicao = AVMutableComposition()
        guard let cv = composicao.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = composicao.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return false
        }
        let faixaDoVideo = video.timeRange
        let fim = CMTimeRangeGetEnd(faixaDoVideo)
        let faixaDoSom = CMTimeRangeGetIntersection(audio.timeRange, otherRange: CMTimeRange(start: .zero, end: fim))
        do {
            try cv.insertTimeRange(faixaDoVideo, of: video, at: faixaDoVideo.start)
            if faixaDoSom.isEmpty {
                composicao.removeTrack(ca)
            } else {
                try ca.insertTimeRange(faixaDoSom, of: audio, at: faixaDoSom.start)
            }
        } catch {
            Registro.compartilhado.linha("APP GRAVACAO pendente: a composição recusou as trilhas (\(SanitizacaoDoLog.erro(error))); fica como está")
            return false
        }
        guard let exp = AVAssetExportSession(asset: composicao, presetName: AVAssetExportPresetPassthrough) else { return false }
        exp.outputURL = saida
        exp.outputFileType = .mp4
        let s = DispatchSemaphore(value: 0)
        exp.exportAsynchronously { s.signal() }
        s.wait()
        guard exp.status == .completed else {
            try? FileManager.default.removeItem(at: saida)
            Registro.compartilhado.linha("APP GRAVACAO pendente: aparar o som falhou "
                                         + "(\(exp.error.map { SanitizacaoDoLog.erro($0) } ?? "indisponível")); fica como está")
            return false
        }
        Registro.compartilhado.linha(String(format: "APP GRAVACAO pendente: som aparado ao fim do vídeo — video=%.3f s, som de %.3f s"
                                            + " para %.3f s (sem recodificar)", CMTimeGetSeconds(fim),
                                            CMTimeGetSeconds(CMTimeRangeGetEnd(audio.timeRange)),
                                            CMTimeGetSeconds(CMTimeRangeGetEnd(faixaDoSom))))
        return true
    }
}

/// **A gravação vista pelo prompter** (contrato §13.8; o molde é `GravacaoNaTelaComCamera.swift` do
/// iOS, §8.7): a ponte entre o `GravadorLocal` e a réplica do teleprompter.
///
/// - Ao abrir a tela, `ligarGravacao(true)`; ao fechar, `false` (o núcleo recusa o pedido aberto).
/// - **O arquivo começou → `definirGravando(true)`; fechou → `definirGravando(false)`**, venha de
///   onde vier. É o que o controle vê.
/// - **O pedido do controle** (bit `gravacao`): relê `"pedido_de_gravacao"` e decide pelo mais novo.
///   Já está como se pede: aceita; não está: grava ou para, e o arquivo começando/fechando responde;
///   não dá: `recusarGravacao(n, motivo)`.
///
/// Só na principal.
final class GravacaoDoPrompter {
    let gravador: GravadorLocal
    private var replica: ReplicaDoTeleprompter?
    private var atendendo: UInt64?
    private var ultimoTentado: UInt64?

    init(gravador: GravadorLocal) {
        self.gravador = gravador
    }

    private func dizer(_ s: String) { Registro.compartilhado.linha("teleprompter: gravação: " + s) }

    func ligar(replica r: ReplicaDoTeleprompter) {
        replica = r
        let st = r.ligarGravacao(true)
        dizer("a tela grava (ligarGravacao → \(st.nome))")
        gravador.aoMudar = { [weak self] gravando in
            guard let self else { return }
            if let r = self.replica {
                let st = r.definirGravando(gravando)
                self.dizer("definirGravando(\(gravando)) → \(st.nome)")
            }
            self.decidir()
        }
        decidir()
    }

    /// A tela fecha: a gravação para (o arquivo fecha com a tela já fechada), o controle ouve
    /// `definirGravando(false)` **agora**, enquanto ainda há sessão, e o prompter deixa de dizer que
    /// grava.
    func desligar(motivo: String) {
        let gravava = gravador.estado.ocupada
        gravador.parar(motivo: motivo)
        guard let r = replica else { return }
        if gravava {
            let st = r.definirGravando(false)
            dizer("definirGravando(false) antes de a sessão cair (\(motivo)) → \(st.nome)")
        }
        let st = r.ligarGravacao(false)
        dizer("a tela não grava mais (ligarGravacao(false) → \(st.nome))")
        replica = nil
    }

    /// O botão Gravar/Parar da tela.
    func tocar() {
        switch gravador.estado {
        case .parada: gravador.comecar(por: .toque) { _ in }
        case .gravando, .abrindo: gravador.parar(motivo: "o botão Parar")
        case .fechando: break
        }
    }

    /// Relê o pedido do controle e decide (§13.2, passo 4).
    func decidir() {
        guard let r = replica, let p = r.estado()?.pedidoDeGravacao else { return }
        if let n = atendendo {
            // Um "parar" mais novo enquanto um "gravar" espera o primeiro quadro: para já.
            if p.n != n, !p.gravar, gravador.estado == .abrindo {
                dizer("pedido n=\(p.n) parar chegou com o gravar n=\(n) abrindo; para já")
                gravador.parar(motivo: "pedido do controle remoto")
            }
            return
        }
        let jaAssim = p.gravar ? gravador.estado.gravando : gravador.estado == .parada
        if jaAssim {
            let st = r.definirGravando(p.gravar)
            dizer("pedido n=\(p.n) \(p.gravar ? "gravar" : "parar") — já estava assim; aceito (\(st.nome))")
            return
        }
        guard ultimoTentado != p.n else {
            dizer("pedido n=\(p.n) já tentado e ainda aberto; não tento de novo em laço")
            return
        }
        ultimoTentado = p.n
        atendendo = p.n
        dizer("pedido do controle n=\(p.n) \(p.gravar ? "gravar" : "parar") (estado aqui: \(gravador.estado))")
        if p.gravar {
            gravador.comecar(por: .controle) { [weak self] motivo in
                guard let self else { return }
                self.atendendo = nil
                if let motivo, let r = self.replica {
                    // A causa detalhada fica neste aparelho. Toda falha de início tem a mesma
                    // recusa remota, sem expor espaço livre nem outro diagnóstico ao controle.
                    let texto = T("não foi possível iniciar a gravação; veja o aviso no aparelho que grava")
                    let st = r.recusarGravacao(n: p.n, motivo: texto)
                    self.dizer("pedido n=\(p.n) recusado: causa=\(SanitizacaoDoLog.causaExterna(motivo)) (\(st.nome))")
                }
                self.decidir()
            }
        } else {
            gravador.parar(motivo: "pedido do controle remoto") { [weak self] in
                guard let self else { return }
                self.atendendo = nil
                self.decidir()
            }
        }
    }

    /// O motivo no teto do contrato (256 bytes de UTF-8), cortado numa fronteira de caractere.
    static func caber(_ s: String) -> String {
        guard s.utf8.count > 250 else { return s }
        var r = ""
        for c in s {
            if (r + String(c)).utf8.count > 250 { break }
            r.append(c)
        }
        return r
    }
}
