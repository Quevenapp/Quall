import CQuall
import Foundation
import QuallCaptureKit
import QuallIdiomaKit
import QuallNetKit

/// **A sessão de vídeo da tela R5, pendurada no dono da câmera** (R5 fase 4 no Mac,
/// `docs/teleprompter-com-camera.md` §8.9, item 4; o molde é o modo pendurado do iOS, §8.3).
///
/// Uma espera por vez, na mesma porta e com o mesmo PIN pela vida da tela:
///
/// - hospeda (`SessaoDeEmissao`, com o dono e a track de microfone na oferta);
/// - o receptor pareia → a transmissão **se pendura** no dono (a câmera já estava aberta);
/// - o receptor cai → a transmissão **se solta**, a sessão é desmontada **antes** de hospedar de novo
///   (a `QuallSession` guarda o servidor de sinalização pela vida dela: a porta só se solta com ela),
///   e a espera volta **com o mesmo PIN**. A câmera não é tocada;
/// - PIN novo só depois de `WRONG_PIN` (cada PIN vale uma tentativa por conexão), a não ser que a
///   bancada o tenha fixado;
/// - o prazo **sem ninguém** (5 min) é de graça; as outras falhas contam, e contam as sessões que
///   caem em menos de 30 s (um receptor retomando em laço numa rede que isola não vaza sem teto).
///   No 40.º, a espera desiste e diz por quê.
///
/// A sessão do prompter (7979) é outra, independente (`Teleprompter`): a queda de uma não mexe na
/// outra. Só na principal.
final class EsperaDaCamera: ObservableObject {
    enum Fase: Equatable {
        case parada
        case esperando
        case transmitindo
        case desistiu(String)
    }

    @Published private(set) var fase: Fase = .parada
    @Published private(set) var pin = ""
    @Published private(set) var endereco: String?
    @Published private(set) var par = ""
    @Published private(set) var resumo = ""
    @Published private(set) var mensagem = ""
    @Published private(set) var anunciandoPorMDNS = false

    let dono: DonoDaCamera
    private let fonte: FonteDeCaptura
    private let argumentos: Argumentos
    private var sessao: SessaoDeEmissao?
    private(set) var porta: UInt16 = 0
    private var falhas = 0
    private var proximoId = 1
    private var parando = false
    private var pinFixo: String?
    private var inicioDaSessao: Date?
    private let anunciante = Anunciante()
    private let filaDoAnuncio = DispatchQueue(label: "quall.camera.anuncio")
    static let tetoDeFalhas = 40

    init(dono: DonoDaCamera, argumentos: Argumentos) {
        self.dono = dono
        self.argumentos = argumentos
        fonte = FonteDeCaptura(id: "camera:\(dono.uniqueID)", tipo: .camera(dono.uniqueID),
                               nome: dono.nomeDaCamera, detalhe: "")
    }

    private func registrar(_ linha: String) {
        Registro.compartilhado.linha("APP CAMERA " + linha)
    }

    /// Começa a esperar: a porta (a pedida, a 7877, ou uma livre) e o PIN (o pedido, ou sorteado),
    /// fixos pela vida da tela. `pinAnterior`/`portaAnterior`: a troca de câmera mantém os dois.
    func comecar(pinAnterior: String? = nil, portaAnterior: UInt16? = nil) {
        guard fase == .parada else { return }
        parando = false
        pinFixo = argumentos.pinDaCamera
        pin = pinFixo ?? pinAnterior ?? NucleoDeRede.sortearPin()
        if let p = argumentos.portaDaCamera ?? portaAnterior {
            porta = p
        } else {
            let escolhida = Enderecos.portaPreferida(7877)
            porta = escolhida.porta
            if !escolhida.eraAPedida { registrar("a 7877 estava ocupada; o vídeo vai na \(porta)") }
        }
        endereco = Enderecos.paraDigitar(porta: porta)
        esperar()
    }

    private func esperar() {
        guard !parando else { return }
        let s = SessaoDeEmissao(id: proximoId, fonte: fonte, pin: pin, porta: porta, endereco: endereco,
                                ligarEm: nil, comAudio: false, dono: dono, comMicrofone: true,
                                prefixo: "[camera #\(proximoId)] ")
        proximoId += 1
        s.aoConectar = { [weak self] s in self?.conectou(s) }
        s.aoFalharAoHospedar = { [weak self] s, status, motivo in self?.falhou(s, status: status, motivo: motivo) }
        s.aoCair = { [weak self] s, saiu in self?.caiu(s, porque: saiu ? "o receptor saiu" : "o transporte falhou") }
        s.aoPararSozinho = { [weak self] s, e in self?.caiu(s, porque: "a transmissão parou: \(e)") }
        s.aoNaoIniciar = { [weak self] s, e in self?.caiu(s, porque: "a transmissão não subiu: \(e)") }
        s.aoAtualizar = { [weak self] s in self?.resumo = s.resumo }
        sessao = s
        fase = .esperando
        par = ""
        resumo = ""
        anunciar(porta)
        registrar("pedido PIN presente=\(!pin.isEmpty) porta=\(porta) "
                  + "rede_disponivel=\(endereco != nil) modo=pendurado microfone=na oferta — chamando quall_host")
        s.esperar(pares: Identidade.paresConhecidos(), rotulo: fonte.rotuloDaTrack(nomeDoAparelho: Identidade.nomeDoAparelho),
                  prazoMs: 5 * 60 * 1000)
    }

    private func conectou(_ s: SessaoDeEmissao) {
        guard s === sessao, !parando else { s.encerrar {}; return }
        inicioDaSessao = Date()
        par = s.par.nome.isEmpty ? T("outro aparelho") : s.par.nome
        fase = .transmitindo
        mensagem = ""
        anunciar(nil)
        // 30 fps e a cópia local do teto, como a câmera comum; a câmera é a do dono.
        s.transmitir(fonteDaSessao: fonte, nomeDoMonitor: "", indiceDoMonitor: 0, fps: 30, teto: nil,
                     escopo: .aMaquinaInteira, janelaDoVigia: 0)
        registrar("sessão de pé — transmissão pendurada no dono")
    }

    private func falhou(_ s: SessaoDeEmissao, status: QuallStatus, motivo: String) {
        guard s === sessao else { return }
        sessao = nil
        if parando || status == QUALL_STATUS_CANCELLED { return }
        if status == QUALL_STATUS_TIMEOUT && s.par.deviceId.isEmpty {
            // O prazo sem ninguém é de graça: a espera se renova com o mesmo PIN.
            registrar("tempo esgotado: nenhum receptor conectou — a espera se renova (não conta)")
            esperar()
            return
        }
        falhas += 1
        if status == QUALL_STATUS_WRONG_PIN, pinFixo == nil {
            pin = NucleoDeRede.sortearPin()
            mensagem = T("Um aparelho tentou entrar com o PIN errado. O PIN da câmera mudou.")
        } else {
            mensagem = motivo.isEmpty ? T("A espera da câmera falhou (status %@).", status.rawValue) : motivo
        }
        registrar("a espera falhou: status=\(status.rawValue) causa=\(SanitizacaoDoLog.causaExterna(motivo)) falhas=\(falhas)/\(EsperaDaCamera.tetoDeFalhas)")
        reabrirOuDesistir()
    }

    private func caiu(_ s: SessaoDeEmissao, porque: String) {
        guard s === sessao else { s.encerrar {}; return }
        let durou = inicioDaSessao.map { Date().timeIntervalSince($0) } ?? 0
        inicioDaSessao = nil
        if durou < 30 { falhas += 1 } else { falhas = 0 }
        mensagem = T("Quem recebia saiu (%@); esperando de novo com o mesmo PIN.", porque)
        registrar("transmissão solta do dono (\(porque)); durou \(Int(durou)) s — desmontando antes de hospedar de novo")
        let t0 = Date()
        s.encerrar { [weak self] in
            guard let self else { return }
            self.registrar("sessão desmontada em \(Int(Date().timeIntervalSince(t0) * 1000)) ms "
                           + "(assinantes=\(self.dono.resumoDosAssinantes))")
            guard self.sessao === s else { return }
            self.sessao = nil
            self.reabrirOuDesistir()
        }
    }

    private func reabrirOuDesistir() {
        guard !parando else { return }
        guard falhas < EsperaDaCamera.tetoDeFalhas else {
            let texto = T("A câmera parou de esperar receptor depois de %@ falhas seguidas. "
                + "Gravar neste Mac continua funcionando; feche e abra a tela para esperar de novo.", falhas)
            fase = .desistiu(texto)
            mensagem = texto
            anunciar(nil)
            registrar("desisto de esperar: \(falhas) falhas")
            return
        }
        // Um respiro entre uma falha e a próxima espera: sem ele, um receptor em laço vira laço aqui.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.parando, self.sessao == nil else { return }
            self.esperar()
        }
    }

    /// Fecha a espera e a sessão; `fim` na principal quando a sessão desmontou. A câmera não é tocada
    /// (é do dono, e quem o fecha é a tela).
    func parar(fim: @escaping () -> Void) {
        parando = true
        anunciar(nil)
        fase = .parada
        guard let s = sessao else { fim(); return }
        sessao = nil
        s.encerrar(quandoAcabar: fim)
    }

    private func anunciar(_ porta: UInt16?) {
        if argumentos.semMdns { return }
        let id = Identidade.deviceId
        let nome = Identidade.nomeDoAparelho
        travaDoAnuncio.withLock { anunciosPendentes += 1 }
        filaDoAnuncio.async { [weak self, anunciante, travaDoAnuncio] in
            defer { travaDoAnuncio.withLock { self?.anunciosPendentes -= 1 } }
            anunciante.parar()
            guard let porta else {
                DispatchQueue.main.async { self?.anunciandoPorMDNS = false }
                return
            }
            let ok = anunciante.comecar(deviceId: id, nome: nome, porta: porta, emiteTela: false, emiteCamera: true)
            Registro.compartilhado.linha("APP CAMERA mdns: anunciou=\(ok) porta=\(porta)")
            DispatchQueue.main.async { self?.anunciandoPorMDNS = ok }
        }
    }

    /// O anúncio já saiu (o `--sair-apos` espera a fila: sem o adeus do mDNS, os outros aparelhos
    /// ficam com o Mac fantasma na lista).
    var anuncioOcioso: Bool { travaDoAnuncio.withLock { anunciosPendentes == 0 } }
    private let travaDoAnuncio = NSLock()
    private var anunciosPendentes = 0
}
