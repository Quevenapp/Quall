import Foundation

/// **A câmera de quem filma, vista do receptor** (R9b, `docs/controle-remoto-da-camera.md` §5, §12):
/// o modelo do painel "Ajustes da câmera" (`PainelDaCamera`) na tela de recepção. Ele não fala com
/// câmera nenhuma: mostra o estado que o filmador publica, e cada gesto vira um **pedido** com só o
/// que a pessoa mexeu (o pendente fica por cima do aplicado, e o núcleo reenvia até o recibo).
///
/// Um por `Recepcao` (a tela vive mais que as sessões), seguindo a sessão de agora: cada
/// `SessaoDeRecepcao` tem o seu `CameraRemotaDaSessao` (o `QuallCameraRemote` do núcleo) e o entrega
/// aqui ao começar (`seguir`). O que uma sessão velha publicar depois disso é descartado.
final class ControleRemotoDaCamera: ObservableObject, ModeloDoPainelDaCamera {

    /// `nil`: nenhuma sessão de vídeo de pé. Senão a `situacao` do núcleo (§5): `esperando`,
    /// `sem_resposta`, `sem_camera`, `nao_permitido` ou `pronto`.
    @Published private(set) var situacao: String?
    @Published private(set) var ajustes = AjustesDaCamera.padrao
    @Published private(set) var molde = MoldeDoPainel()
    @Published private(set) var leitura = RegrasDosControles.Leitura()
    @Published private(set) var divergencia: String?
    /// A linha de uma recusa (§3.5), enquanto o núcleo a mostra (3 s).
    @Published private(set) var aviso: String?
    /// Quem mexeu por último (o `autor` do estado), para o diário.
    @Published private(set) var autor: String?

    /// As capacidades chegaram e são da revisão de agora: o painel tem o que desenhar.
    var prontos: Bool { situacao == "pronto" || situacao == "nao_permitido" }
    var textoAntesDePronto: String { tr("Esperando a câmera do outro aparelho…") }
    /// `nao_permitido`: os controles **com os valores**, apagados, e a linha do contrato.
    var bloqueio: String? { situacao == "nao_permitido" ? RegrasDoControleRemoto.textoDoNaoPermitido : nil }
    /// A engrenagem aparece: a câmera do outro respondeu (pronta, ou não permitida).
    var mostraEngrenagem: Bool { prontos }
    /// O painel aberto pode ficar aberto: nas trocas de faixa o núcleo passa por `esperando` até as
    /// capacidades novas chegarem, e fechar no meio do gesto seria pior que apagar por um instante.
    /// Fecha sem câmera, sem resposta, ou sem sessão.
    var painelPodeFicar: Bool { situacao == "pronto" || situacao == "nao_permitido" || situacao == "esperando" }

    // --- a sessão de agora ----------------------------------------------------------------------

    private let trava = NSLock()
    private var _sessao: CameraRemotaDaSessao?
    private var sessao: CameraRemotaDaSessao? {
        trava.lock(); defer { trava.unlock() }
        return _sessao
    }
    /// Os campos que as capacidades deixam pedir (os nomes de `controles`, menos o `toque`).
    private var camposPedidos = Set<String>()
    private var capacidadesJson: String?

    /// Uma sessão de vídeo nova começou: daqui em diante só ela publica. Qualquer thread.
    func seguir(_ s: CameraRemotaDaSessao) {
        trava.lock(); _sessao = s; trava.unlock()
        naPrincipal { [weak self] in self?.limpar(situacao: "esperando") }
    }

    /// A sessão `s` acabou. Se ainda é a de agora, os controles somem. Qualquer thread.
    func soltar(_ s: CameraRemotaDaSessao) {
        trava.lock()
        let era = _sessao === s
        if era { _sessao = nil }
        trava.unlock()
        guard era else { return }
        naPrincipal { [weak self] in self?.limpar(situacao: nil) }
    }

    private func limpar(situacao s: String?) {
        situacao = s
        aviso = nil
        divergencia = nil
        autor = nil
        // Uma sessão nova pode ser de outro filmador: nada da câmera anterior fica à vista.
        molde = MoldeDoPainel()
        ajustes = .padrao
        leitura = RegrasDosControles.Leitura()
        camposPedidos = []
        capacidadesJson = nil
    }

    /// O estado da sessão `s` mudou (a bombeada, na thread dela). O estado é **lido aqui, na
    /// principal**, e não lá: um retrato lido antes de um pedido feito nesta thread chegaria depois
    /// dele e voltaria o deslizante (o pendente por cima do aplicado, §5). `state_json` é de
    /// qualquer thread. Só vale se `s` é a de agora.
    func atualizar(de s: CameraRemotaDaSessao) {
        naPrincipal { [weak self] in
            guard let self, self.sessao === s,
                  let j = s.estadoJson(), let e = RegrasDoControleRemoto.EstadoDoReceptor.de(json: j) else { return }
            self.aplicar(e)
        }
    }

    private func aplicar(_ e: RegrasDoControleRemoto.EstadoDoReceptor) {
        if situacao != e.situacao {
            Diario.dizer("câmera remota: situação \(situacao.map { SanitizacaoDoLog.codigoRemoto($0) } ?? "nenhuma")"
                + " → \(SanitizacaoDoLog.codigoRemoto(e.situacao))")
            situacao = e.situacao
        }
        if let j = e.capacidadesJson, j != capacidadesJson, let c = e.capacidades {
            capacidadesJson = j
            molde = MoldeDoPainel.remoto(c)
            camposPedidos = RegrasDoControleRemoto.camposPedidos(c)
            Diario.dizer("câmera remota: capacidades recebidas (\(j.utf8.count) bytes)")
        }
        if let a = e.ajuste, a != ajustes { ajustes = a }
        if e.leitura != leitura { leitura = e.leitura }
        let d = RegrasDoControleRemoto.textoDaDivergencia(e.divergentes, lido: e.leitura, ajuste: ajustes, molde: molde)
        if d != divergencia { divergencia = d }
        let r = e.recusa.flatMap { RegrasDoControleRemoto.textoDaRecusa(motivo: $0.motivo, campo: $0.campo) }
        if r != aviso {
            aviso = r
            if let m = e.recusa {
                Diario.dizer("câmera remota: recusa \(SanitizacaoDoLog.codigoRemoto(m.motivo))"
                    + " campo_informado=\(m.campo != nil)")
            }
        }
        if e.autor != autor { autor = e.autor }
    }

    // --- os gestos: pedidos (só de gesto da pessoa, §5) -----------------------------------------

    private func pedir(_ campos: [String: Any], _ oQue: String) {
        guard !campos.isEmpty, let s = sessao else { return }
        guard let j = CapacidadesRemotas.json(campos) else { return }
        let st = s.pedir(j)
        Diario.dizer("câmera remota: pedido \(oQue) campos_count=\(campos.count)" + (st == QUALL_STATUS_OK ? "" : " — RECUSADO aqui (status \(st.rawValue))"))
        guard st == QUALL_STATUS_OK else { return }
        // O pendente por cima do aplicado **já**, como o núcleo o mostra (§5): o deslizante não volta
        // enquanto o estado seguinte não chega da thread da sessão. Uma recusa o desfaz.
        var o = RegrasDoControleRemoto.objeto(ajustes)
        for (k, v) in campos { o[k] = v }
        if JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o) {
            let novo = AjustesDaCamera.de(json: d)
            if novo != ajustes { ajustes = novo }
        }
    }

    func mudar(_ grupos: Set<ControlesDaCamera.Grupo>, _ f: (inout AjustesDaCamera) -> Void) {
        var depois = ajustes
        f(&depois)
        pedir(RegrasDoControleRemoto.camposMudados(de: ajustes, para: depois, pedidos: camposPedidos), "do painel")
    }

    /// O "Passar para Manual" manda `exposicao` **sozinho**: o filmador parte do que a câmera dele
    /// está usando (§12, receptor 3).
    func passarParaManual() { pedir(["exposicao": "manual"], "Passar para Manual") }
    func travarExposicao(_ sim: Bool) { pedir(["travaExposicao": sim], "travar a exposição") }
    func travarBalanco(_ sim: Bool) { pedir(["travaBalanco": sim], "travar o balanço") }
    func escolherFoco(_ f: AjustesDaCamera.Foco) { pedir(["foco": f.rawValue], "foco") }
    func escolherBalanco(_ b: AjustesDaCamera.Balanco) { pedir(["balanco": b.rawValue], "balanço") }

    func restaurar() {
        guard let s = sessao else { return }
        let st = s.restaurar()
        Diario.dizer("câmera remota: Restaurar automático" + (st == QUALL_STATUS_OK ? "" : " — RECUSADO aqui (status \(st.rawValue))"))
    }

    /// Um toque na imagem, com o ponto **no quadro decodificado** (`PontoNoQuadro`). Devolve se saiu.
    @discardableResult
    func tocar(x: Double, y: Double, longo: Bool) -> Bool {
        guard molde.toque, bloqueio == nil, let s = sessao else { return false }
        let st = s.tocar(x: x, y: y, longo: longo)
        Diario.dizer(String(format: "câmera remota: toque%@ em (%.3f, %.3f)", longo ? " longo" : "", x, y)
                     + (st == QUALL_STATUS_OK ? "" : " — RECUSADO aqui (status \(st.rawValue))"))
        return st == QUALL_STATUS_OK
    }

    /// A leitura vem do filmador, no ritmo dele: nada a ligar aqui.
    func lerDeVolta(_ sim: Bool) {}

    /// **Só o retrato de bancada** (`RetratosDeBancada`, "ajustes-camera-remota…"): um estado de
    /// exemplo, sem sessão nenhuma.
    func preencherParaRetrato(_ e: RegrasDoControleRemoto.EstadoDoReceptor) { aplicar(e) }
}
