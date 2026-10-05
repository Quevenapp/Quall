import AVFoundation
import Foundation
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit
import SwiftUI

/// De que lado da tela fica o texto na tela R5 (o ajuste local "lado do texto", §2.5).
enum LadoDoTexto: String, CaseIterable, Identifiable {
    case cima, baixo, esquerda, direita
    var id: String { rawValue }
    var vertical: Bool { self == .cima || self == .baixo }
    var rotulo: String {
        switch self {
        case .cima: return T("Em cima")
        case .baixo: return T("Embaixo")
        case .esquerda: return T("À esquerda")
        case .direita: return T("À direita")
        }
    }
}

/// **As peças da tela "Teleprompter com câmera" no Mac** (R5 fase 4,
/// `docs/teleprompter-com-camera.md` §8.9): o dono da câmera, a espera da sessão de vídeo, o
/// gravador e a ponte da gravação com o prompter. A sessão do prompter (7979) é do `Teleprompter`, o
/// mesmo da tela comum (um prompter por aparelho): esta classe nasce com a tela e morre com ela.
///
/// - **Abrir**: a permissão de câmera (pedida), o dono montado com a **melhor imagem** e posto para
///   rodar, a espera da câmera na 7877 (ou livre), os órfãos de gravação tratados, e a bancada
///   agendada.
/// - **Fechar**: a gravação para (o controle ouve `definirGravando(false)` antes de a sessão cair), a
///   espera desmonta a sessão de vídeo, e só então o dono fecha a câmera e o microfone.
///
/// Só na principal.
final class TelaComCamera: ObservableObject {
    @Published private(set) var dono: DonoDaCamera?
    @Published private(set) var espera: EsperaDaCamera?
    @Published private(set) var gravador: GravadorLocal?
    @Published private(set) var erroDaCamera: String?
    @Published var previaEscondida = false {
        didSet {
            guard previaEscondida != oldValue else { return }
            Registro.compartilhado.linha("APP PREVIA \(previaEscondida ? "escondida" : "à mostra") "
                                         + "(a sessão continua: rodando=\(dono?.sessao.isRunning ?? false))")
        }
    }
    /// "Prévia como espelho": ligado por padrão (§6). Só a prévia; a rede e o arquivo nunca espelham.
    @Published var espelharPrevia: Bool {
        didSet { if !bancada { UserDefaults.standard.set(espelharPrevia, forKey: TelaComCamera.chaveDoEspelho) } }
    }
    @Published var ladoDoTexto: LadoDoTexto {
        didSet {
            if !bancada { UserDefaults.standard.set(ladoDoTexto.rawValue, forKey: TelaComCamera.chaveDoLado) }
            fracao = TelaComCamera.fracaoGuardada(ladoDoTexto, bancada: bancada)
            Registro.compartilhado.linha("APP PREVIA lado do texto: \(ladoDoTexto.rawValue)")
        }
    }
    /// A fração da tela que o texto ocupa, **por lado**: 50 % por padrão, de 20 % a 80 %.
    @Published var fracao: Double
    /// As câmeras que o seletor oferece (a do Quall fica de fora), e a escolhida.
    @Published private(set) var cameras: [(id: String, nome: String)] = []
    /// Os microfones que o menu oferece no produto (na bancada, só o de `--microfone=`).
    @Published private(set) var microfones: [AparelhoDeAudio] = []
    @Published var microfoneEscolhido: String? {
        didSet {
            if !bancada { UserDefaults.standard.set(microfoneEscolhido, forKey: TelaComCamera.chaveDoMicrofone) }
            aplicarModoDoMicrofone()
        }
    }

    private(set) var gravacao: GravacaoDoPrompter?
    private let argumentos: Argumentos
    private let bancada: Bool
    private weak var teleprompter: Teleprompter?
    private var gerador: GeradorNoDispositivo?
    private var aberta = false
    private var agendados: [DispatchWorkItem] = []

    static let chaveDoEspelho = "teleprompter.camera.previa_espelho"
    static let chaveDoLado = "teleprompter.camera.lado_do_texto"
    static let chaveDaFracao = "teleprompter.camera.fracao."
    static let chaveDaCamera = "teleprompter.camera.uniqueID"
    static let chaveDoMicrofone = "camera.microfone.uniqueID"

    /// Quantas câmeras estão fechando (o arquivo, a sessão, a câmera), da tela R5 e da câmera comum:
    /// o `--sair-apos` espera zerar. Só na principal.
    private(set) static var emFecho = 0
    static func contarFecho(_ d: Int) { emFecho += d }

    init(teleprompter: Teleprompter, argumentos: Argumentos) {
        self.teleprompter = teleprompter
        self.argumentos = argumentos
        bancada = argumentos.microfoneNaRegraDaBancada
        let d = UserDefaults.standard
        espelharPrevia = bancada ? true : (d.object(forKey: TelaComCamera.chaveDoEspelho) as? Bool ?? true)
        let lado = argumentos.ladoDoTexto.flatMap(LadoDoTexto.init(rawValue:))
            ?? (bancada ? nil : d.string(forKey: TelaComCamera.chaveDoLado).flatMap(LadoDoTexto.init(rawValue:)))
            ?? .cima
        ladoDoTexto = lado
        fracao = TelaComCamera.fracaoGuardada(lado, bancada: bancada)
        microfoneEscolhido = bancada ? nil : d.string(forKey: TelaComCamera.chaveDoMicrofone)
    }

    static func fracaoGuardada(_ lado: LadoDoTexto, bancada: Bool) -> Double {
        guard !bancada, let v = UserDefaults.standard.object(forKey: chaveDaFracao + lado.rawValue) as? Double else { return 0.5 }
        return min(0.8, max(0.2, v))
    }

    func guardarFracao() {
        fracao = min(0.8, max(0.2, fracao))
        if !bancada { UserDefaults.standard.set(fracao, forKey: TelaComCamera.chaveDaFracao + ladoDoTexto.rawValue) }
        Registro.compartilhado.linha(String(format: "APP PREVIA divisão: texto %.0f%% (%@)", fracao * 100, ladoDoTexto.rawValue))
    }

    // MARK: - abrir e fechar

    func abrir() {
        guard !aberta else { return }
        aberta = true
        Registro.compartilhado.linha("APP CAMERA tela com câmera: aberta")
        if argumentos.modoDeBancada {
            // A testemunha do G5 antes de qualquer toque: os aparelhos de entrada que o AVFoundation
            // lista (só lê, não abre nada), o que a bancada pediu, e as saídas do sistema. **Fora da
            // principal**: listar e ler o CoreAudio pode esperar o `coreaudiod` (a prova de 25/09).
            let pedido = argumentos.microfoneSintetico ? "sintético (nenhum aparelho)"
                : (argumentos.microfone ?? "nenhum (o microfone não abre)")
            DispatchQueue.global(qos: .utility).async {
                let lista = DonoDaCamera.aparelhosDeAudio()
                    .map { "\"\($0.nome)\" uid=\($0.uniqueID) transporte=\($0.nomeDoTransporte)" }
                Registro.compartilhado.linha("APP MICROFONE aparelhos: \(lista.isEmpty ? "nenhum" : lista.joined(separator: " | ")) "
                    + "— pedido na bancada: \(pedido); " + DispositivosDeAudio.relatoDasSaidas())
            }
        }
        GravacoesPendentes.recuperar(em: GravadorLocal.pastaPadrao(argumentos), por: "a tela com câmera abriu")
        listarCameras()
        DonoDaCamera.pedirPermissaoDaCamera { [weak self] negada in
            guard let self, self.aberta else { return }
            if let negada {
                self.erroDaCamera = negada
                Registro.compartilhado.linha("APP CAMERA sem permissão: \(negada)")
                return
            }
            let pedida = self.argumentos.camera
                ?? (self.bancada ? nil : UserDefaults.standard.string(forKey: TelaComCamera.chaveDaCamera))
            self.montar(uniqueID: pedida)
        }
    }

    private func listarCameras() {
        var tipos: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { tipos += [.external, .continuityCamera] } else { tipos.append(.externalUnknown) }
        let s = AVCaptureDevice.DiscoverySession(deviceTypes: tipos, mediaType: .video, position: .unspecified)
        cameras = s.devices.filter { !CameraDoQuall.ehDoQuall(uniqueID: $0.uniqueID) }.map { ($0.uniqueID, $0.localizedName) }
    }

    private func montar(uniqueID: String?, pinAnterior: String? = nil, portaAnterior: UInt16? = nil) {
        guard aberta else { return }
        func tentar(_ id: String?) -> (DonoDaCamera, String?) {
            let d = DonoDaCamera { Registro.compartilhado.linha($0) }
            d.microfoneSintetico = argumentos.microfoneSintetico
            d.aoMudar = { [weak self] in self?.objectWillChange.send() }
            BancadaDosAjustesDaCamera.configurar(d, argumentos)
            return (d, d.montar(uniqueID: id, melhorImagem: true))
        }
        var (d, erro) = tentar(uniqueID)
        if erro != nil, uniqueID != nil {
            // A lembrada sumiu (a Continuity Camera longe, a USB fora): a padrão, dizendo. Outro dono:
            // o primeiro pode ter ficado pela metade.
            Registro.compartilhado.linha("APP CAMERA a câmera \(uniqueID ?? "") não abriu (\(erro ?? "")); tentando a padrão")
            (d, erro) = tentar(nil)
        }
        if let erro {
            erroDaCamera = erro
            return
        }
        erroDaCamera = nil
        // O controle remoto da câmera (R9b): o filmador desta câmera, que a espera bombeia.
        CameraRemotaDoDono.anexar(a: d)
        dono = d
        aplicarModoDoMicrofone()
        d.ligar()
        let g = GravadorLocal(dono: d, pasta: GravadorLocal.pastaPadrao(argumentos))
        gravador = g
        let ponte = GravacaoDoPrompter(gravador: g)
        gravacao = ponte
        if let r = teleprompter?.replicaDoPrompter() { ponte.ligar(replica: r) }
        let e = EsperaDaCamera(dono: d, argumentos: argumentos)
        espera = e
        e.comecar(pinAnterior: pinAnterior, portaAnterior: portaAnterior)
        // O gerador do laço (bancada) sobe **depois** da câmera e da espera, fora da principal e com
        // prazo: a câmera e a porta nunca esperam pelo CoreAudio. Até ele responder, o laço não está
        // fechado e o microfone recusa; quando ele sobe, o modo do microfone é reaplicado. Uma vez por
        // tela, e não a cada troca de câmera.
        if estadoDoGerador == .nenhum, let uid = argumentos.tomNoDispositivo { tocarTomNoDispositivo(uid) }
        // A bancada é agendada uma vez por tela (a troca de câmera não a reagenda).
        if !bancadaAgendada {
            bancadaAgendada = true
            agendarBancada()
        }
    }

    private var bancadaAgendada = false

    /// Na bancada o microfone é o de `--microfone=` (só virtual abre, G5); no produto, o escolhido ou o
    /// padrão do sistema.
    private func aplicarModoDoMicrofone() {
        if argumentos.microfoneNaRegraDaBancada {
            // O laço só conta fechado se o **nosso** gerador está tocando nele agora.
            dono?.modoDoMicrofone = .bancada(pedido: argumentos.microfone,
                                             laco: gerador?.tocando == true ? gerador?.uid : nil)
        } else {
            dono?.modoDoMicrofone = .produto(escolhido: microfoneEscolhido)
        }
    }

    /// O menu de microfones (produto): lido quando a pessoa o abre. Só lista, não abre nada.
    func atualizarMicrofones() {
        // Fora da principal (listar pode esperar o `coreaudiod`).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lista = DonoDaCamera.aparelhosDeAudio()
            DispatchQueue.main.async { self?.microfones = lista }
        }
    }

    /// Troca de câmera: **não gravando** (o arquivo tem o tamanho da câmera). Fecha a espera e o
    /// dono, e monta outro — a troca é outra câmera, e a sessão de vídeo recomeça com o mesmo PIN.
    func trocarCamera(_ uid: String) {
        guard gravador?.estado.ocupada != true, uid != dono?.uniqueID else { return }
        if !bancada { UserDefaults.standard.set(uid, forKey: TelaComCamera.chaveDaCamera) }
        Registro.compartilhado.linha("APP CAMERA trocando de câmera para \(uid)")
        let velhaEspera = espera, velhoDono = dono
        let pinAnterior = espera?.pin, portaAnterior = espera?.porta
        // O registro de um pedido remoto adiado vai já (o próximo dono pode ser da mesma câmera).
        velhoDono?.descarregarGravacaoAdiada()
        gravacao?.desligar(motivo: "a câmera foi trocada")
        espera = nil
        dono = nil
        gravador = nil
        gravacao = nil
        TelaComCamera.emFecho += 1
        let remontar = { [weak self] in
            TelaComCamera.emFecho -= 1
            self?.montar(uniqueID: uid, pinAnterior: pinAnterior, portaAnterior: portaAnterior)
        }
        let fecharDono = {
            if let d = velhoDono { d.fechar(fim: remontar) } else { remontar() }
        }
        if let e = velhaEspera { e.parar(fim: fecharDono) } else { fecharDono() }
    }

    /// Fecha tudo, na ordem: a gravação (o controle ouve o `false` antes da sessão cair), a espera
    /// (a sessão de vídeo desmonta), e só então o dono (o microfone, depois a câmera).
    func fechar(motivo: String) {
        guard aberta else { return }
        aberta = false
        agendados.forEach { $0.cancel() }
        agendados = []
        gravacao?.desligar(motivo: motivo)
        let e = espera, d = dono, g = gravador, ger = gerador
        d?.descarregarGravacaoAdiada()
        gerador = nil
        estadoDoGerador = .nenhum
        TelaComCamera.emFecho += 1
        Registro.compartilhado.linha("APP CAMERA tela com câmera: fechando (\(motivo))")
        let terminou = {
            // O gerador do laço para por último (o microfone já fechou com o dono), fora da principal.
            ger?.pararForaDaMain()
            TelaComCamera.emFecho -= 1
            Registro.compartilhado.linha("APP CAMERA tela com câmera: fechada")
        }
        let fecharDono = {
            if let d { d.fechar(fim: terminou) } else { terminou() }
        }
        let depoisDoArquivo = {
            if let e { e.parar(fim: fecharDono) } else { fecharDono() }
        }
        // **O arquivo fecha primeiro** (a revisão de 25/09: o `--sair-apos` e o fecho da câmera não
        // podem cortar o `finishWriting`), depois a sessão de vídeo, e só então a câmera.
        if let g { g.parar(motivo: motivo, fim: depoisDoArquivo) } else { depoisDoArquivo() }
    }

    // MARK: - o gerador de tom no dispositivo virtual (bancada, G5)

    enum EstadoDoGerador { case nenhum, subindo, tocando, recusado }
    private var estadoDoGerador = EstadoDoGerador.nenhum

    private func tocarTomNoDispositivo(_ uid: String) {
        let g = GeradorNoDispositivo(uid: uid)
        g.aoRegistrar = { Registro.compartilhado.linha("APP MICROFONE bancada: " + $0) }
        gerador = g
        estadoDoGerador = .subindo
        Registro.compartilhado.linha("APP MICROFONE bancada: o gerador de tom sobe fora da principal (prazo 10 s)")
        g.comecarForaDaMain(prazo: 10) { [weak self, weak g] recusa in
            guard let self, let g, self.gerador === g else { return }
            if let recusa {
                self.estadoDoGerador = .recusado
                Registro.compartilhado.linha("APP MICROFONE bancada: o gerador de tom RECUSOU tocar — \(recusa)")
            } else {
                self.estadoDoGerador = .tocando
            }
            self.aplicarModoDoMicrofone()
        }
    }

    // MARK: - a bancada, sem toque

    /// Com o gerador do laço ainda subindo, o ligar espera por ele (até 15 s, de meio em meio
    /// segundo): ligar antes seria uma recusa por "laço não fechado" que é só atraso do CoreAudio.
    private func ligarMicrofoneDaBancada(_ d: DonoDaCamera, apos: Double, espera: Double) {
        guard dono === d else { return }
        if estadoDoGerador == .subindo && espera < 15 {
            depois(0.5) { [weak self, weak d] in
                guard let self, let d else { return }
                self.ligarMicrofoneDaBancada(d, apos: apos, espera: espera + 0.5)
            }
            return
        }
        aplicarModoDoMicrofone()
        d.ligarMicrofone(por: "bancada --microfone-apos \(apos)")
        if let por = argumentos.microfonePor {
            depois(por) { [weak d] in d?.desligarMicrofone(por: "bancada --microfone-por \(por)") }
        }
    }

    private func depois(_ s: Double, _ f: @escaping () -> Void) {
        let item = DispatchWorkItem(block: f)
        agendados.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: item)
    }

    private func agendarBancada() {
        guard argumentos.modoDeBancada, let d = dono else { return }
        if let apos = argumentos.microfoneApos {
            Registro.compartilhado.linha("APP MICROFONE bancada: liga em \(apos) s"
                + (argumentos.microfonePor.map { ", desliga \($0) s depois" } ?? "")
                + (argumentos.microfoneSintetico ? " (fonte sintética, nenhum aparelho)" : " (microfone=\(argumentos.microfone ?? "nenhum"))"))
            depois(apos) { [weak self, weak d] in
                guard let self, let d, self.dono === d else { return }
                self.ligarMicrofoneDaBancada(d, apos: apos, espera: 0)
            }
        }
        if let apos = argumentos.esconderPreviaApos {
            depois(apos) { [weak self] in
                self?.previaEscondida = true
                self?.depois(max(apos, 30)) { self?.previaEscondida = false }
            }
        }
        if let g = gravacao { BancadaDaGravacao.agendar(g.gravador, argumentos: argumentos, depois: depois) }
        BancadaDosAjustesDaCamera.agendar(d, argumentos, depois: depois)
    }
}

/// **A bancada da gravação**, sem toque (os mesmos argumentos do iOS, §8.7): `--gravar-apos=S`,
/// `--gravar-por=D`, `--matar-gravando-apos=M` (**`SIGKILL` no próprio processo**, gravando: o fim
/// abrupto da prova M7; a abertura seguinte trata o órfão).
enum BancadaDaGravacao {
    static func agendar(_ g: GravadorLocal, argumentos: Argumentos,
                        depois: @escaping (Double, @escaping () -> Void) -> Void) {
        guard let apos = argumentos.gravarApos else { return }
        Registro.compartilhado.linha("APP GRAVACAO bancada: grava em \(apos) s"
            + (argumentos.gravarPor.map { ", para \($0) s depois" } ?? "")
            + (argumentos.matarGravandoApos.map { ", MATA o processo \($0) s depois de começar" } ?? ""))
        depois(apos) { [weak g] in
            guard let g else { return }
            g.comecar(por: .bancada) { motivo in
                guard motivo == nil else { return }
                if let m = argumentos.matarGravandoApos {
                    depois(m) {
                        Registro.compartilhado.linha("APP GRAVACAO bancada: SIGKILL agora, gravando (--matar-gravando-apos \(m))")
                        // O diário precisa de um instante para sair do processo.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { kill(getpid(), SIGKILL) }
                    }
                }
                if let por = argumentos.gravarPor {
                    depois(por) { [weak g] in
                        guard let g, g.estado.gravando else { return }
                        g.parar(motivo: "bancada --gravar-por \(por)")
                    }
                }
            }
        }
    }
}
