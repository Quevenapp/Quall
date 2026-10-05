import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// **Os controles de câmera para transmissão** (R9, `docs/controles-de-camera.md`), do lado do
/// aparelho: o registro da câmera aberta, o que ela oferece, o que ela diz ter usado, e o caminho de
/// cada mudança até o `AVCaptureDevice`.
///
/// As regras (escalas, cortes, o plano de reaplicação, os textos) são puras e testadas no MacBook
/// (`RegrasDosControles`). Aqui fica só o que precisa da câmera, com três regras do §6:
///
/// 1. **Todo `lockForConfiguration` na `fila` do dono**, inclusive na câmera comum, que monta na
///    principal: a montagem termina antes de qualquer ajuste ser enfileirado, e daí em diante só a
///    `fila` escreve na câmera (os degraus, o recuo da melhor imagem, os ajustes).
/// 2. **Toda mudança com a guarda `is…Supported`**, e todo valor cortado pela faixa do formato ativo
///    **naquele instante**: fora dela o AVFoundation lança `NSRangeException`, que em Swift é queda
///    do app, e não erro tratável. O corte é feito duas vezes: pela regra pura e, no fim, em `Float`
///    contra o que a câmera declara (a conversão de tempo e de precisão não pode empurrar um valor
///    para fora por um ulp).
/// 3. **A reaplicação vem sempre depois do `limitarTaxa`** (o teto de quadro encurta a exposição,
///    diz o header), nos ganchos do §2.2: o fim da montagem, o `reduzirCaptura` e a volta, o
///    `recuarDaMelhorImagem` e o fim de interrupção (`aoRetomar`, que também é o fim do segundo
///    plano: `retomarDoSegundoPlano` o chama).
///
/// A anti-cintilação não tem API no iOS (o sistema cuida sozinho): o valor fica no registro, porque
/// é ele que põe o ponto "sem cintilação" nas frações do obturador (§3.1).
final class ControlesDaCamera: ObservableObject, ModeloDoPainelDaCamera {

    /// O registro (o que a pessoa pediu). Na principal; a cópia da `fila` está em `registro`.
    @Published private(set) var ajustes: AjustesDaCamera = .padrao
    @Published private(set) var capacidades: CapacidadesDaCamera = .nenhuma
    @Published private(set) var faixas: FaixasDaCamera = .vazia
    /// A câmera está montada e o registro carregado: o painel tem o que mostrar.
    @Published private(set) var prontos = false
    /// Os valores **lidos de volta** (§3.6), no máximo 4 vezes por segundo, só com o painel aberto.
    @Published private(set) var leitura = RegrasDosControles.Leitura()
    /// "A câmera usou {lido} em vez de {pedido}.", depois de 2 s de divergência.
    @Published private(set) var divergencia: String?
    /// "Travado de novo depois de medir a cena." por 3 s.
    @Published private(set) var aviso: String?
    /// A pílula do toque longo (§4.4).
    @Published private(set) var pilula: String?
    /// **"Controlado por <aparelho>"** (R9b, contrato §12, filmador 6): o nome de quem mudou a câmera
    /// por pedido há menos de 4 s (`controlado_por` do estado do núcleo), ou `nil`.
    @Published private(set) var controladoPor: String?

    // --- o painel (R9b: o mesmo painel serve ao receptor) ---------------------------------------

    /// O que esta câmera oferece, na forma que o painel desenha (o painel de sempre). Guardado, e não
    /// calculado: o painel o lê dezenas de vezes por desenho.
    @Published private(set) var molde = MoldeDoPainel.local(.nenhuma, .vazia)
    var textoAntesDePronto: String { tr("Abrindo a câmera…") }
    /// O filmador nunca está bloqueado: quem filma sempre ajusta a própria câmera.
    var bloqueio: String? { nil }

    /// **O controle remoto desta câmera** (R9b): o `QuallCameraHost` do núcleo. `nil` só se o núcleo
    /// não alocar — e aí a câmera segue como antes, sem controle remoto.
    let remoto = FilmadorRemoto()

    weak var dono: DonoDaCaptura?

    // --- a tela que pendurou o dono, para a bancada (R9, a prova na R5) ------------------------------

    /// "camera" (a câmera comum) ou "r5" (`PecasDaTelaComCamera` escreve no `init`, antes de montar).
    /// Só diz ao diário e ao roteiro de prova onde se está; o produto não decide nada por ele.
    var tela = "camera"
    /// **O degrau forçado da tela** (§5.3): na R5 os degraus são da tela (`DegrausDaTransmissao`), e
    /// o forçado passa por eles — chamar `reduzirCaptura` por fora seria desfeito pela própria R5 na
    /// janela seguinte de 10 s (`aplicarDegraus`). Sem tela que o ofereça, `reduzirCaptura` direto.
    var forcarDegrau: ((Bool) -> Void)?

    /// O roteiro de prova pede o painel aberto ou fechado (só a bancada; a tela observa).
    @Published private(set) var pedidoDoPainel: Bool?
    /// O roteiro de prova pede uma sonda do toque (`contexto` vai ao diário; a tela observa).
    @Published private(set) var pedidoDaSonda: (vez: Int, contexto: String)?

    func pedirPainel(_ aberto: Bool) { pedidoDoPainel = aberto }

    func pedirSonda(_ contexto: String) {
        pedidoDaSonda = ((pedidoDaSonda?.vez ?? 0) + 1, contexto)
    }

    /// O degrau forçado, pelo caminho da tela quando ela tem degraus.
    func degrauForcado(_ sim: Bool) {
        if let f = forcarDegrau {
            Diagnostico.nota("APP CAMERA bancada: degrau forçado pela tela \(tela) → \(sim ? "captura em 720p" : "nenhum")")
            f(sim)
        } else {
            dono?.reduzirCaptura(sim) { ok in
                Diagnostico.nota("APP CAMERA bancada: reduzirCaptura(\(sim)) → \(ok ? "feito" : "recusado")")
            }
        }
    }

    /// O `uniqueID` da câmera aberta: a chave do registro.
    private(set) var idDaCamera: String?

    // --- o registro, também para a `fila` ------------------------------------------------------

    private let trava = NSLock()
    private var _registro = AjustesDaCamera.padrao
    private var _gruposPendentes = Set<Grupo>()
    /// O núcleo já sabe desta câmera (`set_camera`), e com quais capacidades. Sob `trava`: o
    /// anúncio, as escritas do registro e o fechamento passam pela mesma trava, para a ordem das
    /// versões no núcleo ser a ordem das escritas aqui.
    private var _cameraAnunciada = false
    private var _capacidadesAnunciadas: String?
    /// O agrupador dos envios (§2.2: no máximo 15 por segundo). Só na principal.
    private var agrupador = RegrasDosControles.Agrupador()

    /// Um grupo de controles: o que mudou é o que se reenvia (mexer no EV não pode desfazer o foco
    /// que um toque acabou de pôr).
    enum Grupo: Hashable, CaseIterable { case exposicao, balanco, foco }

    var registro: AjustesDaCamera {
        trava.lock(); defer { trava.unlock() }
        return _registro
    }

    // --- carregar e guardar ---------------------------------------------------------------------

    /// O registro desta câmera, do `UserDefaults.standard` (§2). Chamado na montagem, antes da
    /// primeira aplicação; de qualquer thread.
    func carregar(uniqueID: String) {
        // Um registro remoto que esperava a gravação adiada vai ao disco da câmera **anterior** antes.
        descarregarGravacaoAdiada()
        let a = AjustesDaCamera.de(json: UserDefaults.standard.data(forKey: AjustesDaCamera.chave(uniqueID)))
        trava.lock(); _registro = a; _cameraAnunciada = false; _capacidadesAnunciadas = nil; trava.unlock()
        idDaCamera = uniqueID
        naPrincipal { [weak self] in self?.ajustes = a }
        Diagnostico.nota("APP CAMERA controles: registro carregado"
            + " (tela=\(tela)) registro_bytes=\(a.json()?.count ?? 0)")
    }

    private func guardar(_ a: AjustesDaCamera) {
        guard let id = idDaCamera else { return }
        if a == .padrao {
            // "Restaurar automático" zera o registro daquela câmera, e só dela (§2.2).
            UserDefaults.standard.removeObject(forKey: AjustesDaCamera.chave(id))
        } else if let j = a.json() {
            UserDefaults.standard.set(j, forKey: AjustesDaCamera.chave(id))
        }
    }

    /// De onde vem uma escrita do registro, para o núcleo (contrato §4): uma mudança feita aqui (o
    /// painel, o toque na prévia), a escrita automática da casca (o lido que a trava guarda), ou um
    /// pedido de um receptor (o `n` dele).
    enum OrigemDaEscrita { case local, sistema, remoto(UInt64) }

    /// **Lê, muda e escreve o registro sob a trava, de uma vez** (de qualquer thread), e passa o
    /// registro novo ao núcleo **dentro da mesma trava**: duas escritas de threads diferentes (o
    /// painel na principal, um pedido remoto na `fila`) não se apagam, e o núcleo recebe as versões
    /// na ordem em que valeram. `f` devolve `false` para não escrever nada. Guarda e publica.
    @discardableResult
    fileprivate func alterar(_ origem: OrigemDaEscrita, _ f: (inout AjustesDaCamera) -> Bool) -> AjustesDaCamera? {
        trava.lock()
        var a = _registro
        let j = _cameraAnunciada ? a.json().flatMap({ String(data: $0, encoding: .utf8) }) : nil
        if case .remoto = origem, j == nil || remoto == nil {
            // Um pedido só vale se o núcleo recebe o registro com o `n` dele: sem isso, quem chama recusa.
            trava.unlock(); return nil
        }
        guard f(&a) else { trava.unlock(); return nil }
        _registro = a
        if _cameraAnunciada, let r = remoto, let j = a.json().flatMap({ String(data: $0, encoding: .utf8) }) {
            switch origem {
            case .local: r.definirAjuste(j, pedido: 0)
            case .sistema: r.atualizarAjuste(j)
            case .remoto(let n): r.definirAjuste(j, pedido: n)
            }
        }
        trava.unlock()
        if case .remoto = origem { guardarAdiado() } else { guardarAgora() }
        naPrincipal { [weak self] in
            guard let self else { return }
            // O registro **de agora**, e não o `a` desta escrita: duas escritas de threads diferentes
            // podem chegar aqui fora de ordem.
            let atual = self.registro
            if self.ajustes != atual { self.ajustes = atual }
            // A pílula vive enquanto as travas que ela anuncia estiverem de pé.
            if self.pilula != nil, !atual.travaExposicao, atual.foco != .travado { self.pilula = nil }
        }
        return a
    }

    // --- a gravação: na hora, ou adiada para os pedidos remotos ---------------------------------

    private var gravacaoAdiada: DispatchWorkItem?
    private let travaDaGravacao = NSLock()

    /// Um deslizante remoto a 15 por segundo não vira 15 gravações por segundo (contrato §6, passo
    /// 3): o registro **de agora** é gravado 500 ms depois da última escrita remota.
    private func guardarAdiado() {
        let item = DispatchWorkItem { [weak self] in self?.guardarAgora() }
        travaDaGravacao.lock()
        gravacaoAdiada?.cancel()
        gravacaoAdiada = item
        travaDaGravacao.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func guardarAgora() {
        travaDaGravacao.lock()
        gravacaoAdiada?.cancel()
        gravacaoAdiada = nil
        travaDaGravacao.unlock()
        guardar(registro)
    }

    fileprivate func publicar(_ c: CapacidadesDaCamera, _ f: FaixasDaCamera) {
        naPrincipal { [weak self] in
            guard let self else { return }
            if self.capacidades != c || self.faixas != f { self.molde = MoldeDoPainel.local(c, f) }
            if self.capacidades != c { self.capacidades = c }
            if self.faixas != f { self.faixas = f }
            if !self.prontos { self.prontos = true }
        }
    }

    func esquecerCamera() {
        naPrincipal { [weak self] in
            self?.prontos = false
            self?.pilula = nil
            self?.aviso = nil
            self?.divergencia = nil
            self?.controladoPor = nil
        }
    }

    // --- o núcleo do controle remoto (R9b) ------------------------------------------------------

    /// **A câmera e as capacidades ao núcleo**, na `fila`, a cada aplicação (o fim do `montar`, o
    /// degrau de calor, a volta de interrupção): a primeira desta câmera é `set_camera` (com o
    /// registro, lido sob a trava); depois, só quando as capacidades mudam, `set_capabilities` — o
    /// teto do obturador segue o fps e o degrau de calor muda o formato, mas a câmera é a mesma
    /// (contrato §7.2: o degrau de calor não é troca de câmera).
    fileprivate func anunciar(_ c: CapacidadesDaCamera, _ f: FaixasDaCamera, nome: String) {
        guard let r = remoto,
              let caps = CapacidadesRemotas.json(CapacidadesRemotas.doIOS(c, f, nome: nome)) else { return }
        // (Ver `CapacidadesRemotas.nomeDaCamera`: o nome vai no idioma do app, como no Android.)
        trava.lock()
        defer { trava.unlock() }
        if !_cameraAnunciada {
            guard let j = _registro.json().flatMap({ String(data: $0, encoding: .utf8) }) else { return }
            let st = r.definirCamera(capacidades: caps, ajuste: j)
            _cameraAnunciada = st == QUALL_STATUS_OK
            _capacidadesAnunciadas = caps
            Diagnostico.nota("APP CAMERA remoto: câmera anunciada ao núcleo (\(caps.utf8.count) bytes de capacidades)"
                + (st == QUALL_STATUS_OK ? "" : " — RECUSADA, status \(st.rawValue): \(caps)"))
        } else if caps != _capacidadesAnunciadas {
            let st = r.definirCapacidades(caps)
            _capacidadesAnunciadas = caps
            Diagnostico.nota("APP CAMERA remoto: capacidades novas da mesma câmera (faixas)"
                + (st == QUALL_STATUS_OK ? "" : " — RECUSADAS, status \(st.rawValue)"))
        }
    }

    /// A câmera fechou: o núcleo fica sem câmera (`camera` 0, os receptores escondem o painel). Na
    /// `fila`, junto do `fechado` do dono, para nenhum anúncio atrasado passar por cima. E o registro
    /// que esperava a gravação adiada vai ao disco agora.
    func cameraFechou() {
        trava.lock()
        if _cameraAnunciada { remoto?.definirCamera(capacidades: nil, ajuste: nil) }
        _cameraAnunciada = false
        _capacidadesAnunciadas = nil
        trava.unlock()
        descarregarGravacaoAdiada()
    }

    /// A gravação adiada que ainda não aconteceu, agora (o fechamento, a troca de câmera).
    private func descarregarGravacaoAdiada() {
        travaDaGravacao.lock()
        let pendente = gravacaoAdiada != nil
        travaDaGravacao.unlock()
        if pendente { guardarAgora() }
    }

    var cameraAnunciada: Bool {
        trava.lock(); defer { trava.unlock() }
        return _cameraAnunciada
    }

    /// O laço da sessão viu pedido na fila: **um consumidor só**, a `fila` do dono, por onde passa toda
    /// escrita na câmera (contrato §6).
    func pedidosChegaram() {
        dono?.fila.async { [weak self] in self?.drenarPedidos() }
    }

    /// Na `fila`: tira os pedidos até a fila do núcleo esvaziar, e responde a cada um.
    private func drenarPedidos() {
        guard let r = remoto else { return }
        while let texto = r.proximoPedido() {
            guard let p = RegrasDoControleRemoto.Pedido.de(json: texto) else {
                // Respondido assim mesmo, se o `n` se lê: o receptor não espera 5 s pelo `nao_aplicado`.
                Diagnostico.falha("APP CAMERA remoto: pedido ilegível do núcleo (\(texto.utf8.count) bytes)")
                if let d = texto.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let n = RegrasDoControleRemoto.numeroJSON(o["n"]), n >= 1, n < 1.8e19 {
                    r.recusar(UInt64(n), "invalido")
                }
                continue
            }
            if let dono { dono.tratarPedidoRemoto(p) } else { r.recusar(p.n, "nao_aplicado") }
        }
    }

    /// Um pedido remoto aplicado: escreve o registro com o `n` dele (o recibo e o "Controlado por").
    /// `aplicar` devolve `false` para não escrever (falta o lido): quem chama recusa.
    fileprivate func escreverPedido(_ n: UInt64, _ aplicar: (inout AjustesDaCamera) -> Bool) -> Bool {
        alterar(.remoto(n), aplicar) != nil
    }

    /// O que o laço da sessão leu do estado do núcleo (no máximo 4 vezes por segundo).
    func estadoDoNucleo(controladoPor nome: String?, ouvintes: Bool) {
        ouvintesRemotos(ouvintes)
        naPrincipal { [weak self] in
            guard let self, self.controladoPor != nome else { return }
            self.controladoPor = nome
            if nome != nil { Diagnostico.nota("APP CAMERA remoto: controle identificado na tela") }
        }
    }

    /// A sessão acabou: ninguém ouve, e ninguém controla.
    func semReceptor() { estadoDoNucleo(controladoPor: nil, ouvintes: false) }

    /// A pílula do toque longo de um pedido remoto (na principal).
    fileprivate func mostrarPilula(_ p: String?) {
        naPrincipal { [weak self] in self?.pilula = p }
    }

    // --- o que a tela pede (na principal) -------------------------------------------------------

    /// **Uma mudança simples**, sem leitura da câmera: o deslizante, a escolha de modo. Vale na hora
    /// no registro e na tela; o envio à câmera é agrupado a no máximo 15 por segundo, e leva o último
    /// valor (`aplicarPendentes` lê o registro na hora de enviar).
    func mudar(_ grupos: Set<Grupo>, _ f: (inout AjustesDaCamera) -> Void) {
        alterar(.local) { a in f(&a); return true }
        trava.lock(); _gruposPendentes.formUnion(grupos); trava.unlock()
        guard let atraso = agrupador.pedir(agora: CFAbsoluteTimeGetCurrent()) else { return }
        dono?.fila.asyncAfter(deadline: .now() + atraso) { [weak self] in
            guard let self else { return }
            self.trava.lock()
            let g = self._gruposPendentes
            self._gruposPendentes.removeAll()
            self.trava.unlock()
            naPrincipal { [weak self] in self?.agrupador.enviou(agora: CFAbsoluteTimeGetCurrent()) }
            self.dono?.aplicarAjustesNaFila(g, reaplicando: false, motivo: "a pessoa mexeu")
        }
    }

    /// **Uma mudança que precisa ler a câmera** antes (§2.1, §4.3): travar guarda o que a câmera
    /// estava usando; passar a Manual parte do lido; passar a Kelvin parte do estimado. Corre na
    /// `fila`, com a câmera na mão, e aplica na hora.
    func mudarLendo(_ grupos: Set<Grupo>, motivo: String,
                    _ f: @escaping (inout AjustesDaCamera, AVCaptureDevice) -> Void) {
        dono?.fila.async { [weak self] in
            guard let self, let ap = self.dono?.entrada?.device else { return }
            self.alterar(.local) { a in f(&a, ap); return true }
            self.dono?.aplicarAjustesNaFila(grupos, reaplicando: false, motivo: motivo)
        }
    }

    // As mudanças com leitura, com nome (o painel e a bancada as chamam).

    func passarParaManual() {
        mudarLendo([.exposicao], motivo: "passar para Manual") { a, ap in
            a.exposicao = .manual
            a.iso = Double(ap.iso)
            a.obturadorNs = AjustesNaCamera.ns(ap.exposureDuration)
        }
    }

    func travarExposicao(_ sim: Bool) {
        pilula = nil
        mudarLendo([.exposicao], motivo: sim ? "travar a exposição" : "destravar a exposição") { a, ap in
            a.travaExposicao = sim
            if sim {
                a.travaIso = Double(ap.iso)
                a.travaObturadorNs = AjustesNaCamera.ns(ap.exposureDuration)
            } else {
                a.travaIso = nil; a.travaObturadorNs = nil
            }
        }
    }

    func travarBalanco(_ sim: Bool) {
        mudarLendo([.balanco], motivo: sim ? "travar o balanço" : "destravar o balanço") { a, ap in
            a.travaBalanco = sim
            if sim {
                let g = ap.deviceWhiteBalanceGains
                a.travaGanhos = [Double(g.redGain), Double(g.greenGain), Double(g.blueGain)]
            } else {
                a.travaGanhos = nil
            }
        }
    }

    func escolherFoco(_ f: AjustesDaCamera.Foco) {
        pilula = nil
        mudarLendo([.foco], motivo: "foco \(f.rawValue)") { a, ap in
            // Travar guarda a posição lida (§2.1); passar a Manual parte dela, se ainda não havia uma.
            if f == .travado || (f == .manual && (a.foco == .auto || a.focoPosicao == nil)) {
                a.focoPosicao = RegrasDosControles.focoPosicao(daLente: Double(ap.lensPosition))
            }
            a.foco = f
        }
    }

    func escolherBalanco(_ b: AjustesDaCamera.Balanco) {
        mudarLendo([.balanco], motivo: "balanço \(b.rawValue)") { a, ap in
            if b == .kelvin, a.kelvin == nil {
                // O estimado no momento de passar a Kelvin (§2), pela leitura que confere os ganhos
                // antes da conta (fora de [1, máximo] ela lançaria).
                a.kelvin = AjustesNaCamera.leitura(ap).kelvin.map { RegrasDosControles.arredondarKelvin(Double($0)) } ?? 5500
            }
            a.balanco = b
            // Com Kelvin, a trava de balanço não se aplica (§3.4); num preset, também não.
            if b != .auto { a.travaBalanco = false; a.travaGanhos = nil }
        }
    }

    /// "Restaurar automático": o registro volta ao padrão da tabela (só desta câmera), e o ponto de
    /// toque volta ao centro.
    func restaurar() {
        pilula = nil
        // O ponto ao centro **fora** da trava do registro (ele pede a trava da câmera), e antes da
        // aplicação, na `fila`.
        dono?.fila.async { [weak self] in
            guard let self, let ap = self.dono?.entrada?.device else { return }
            self.alterar(.local) { a in a = .padrao; return true }
            AjustesNaCamera.pontoAoCentro(ap)
            self.dono?.aplicarAjustesNaFila(Set(Grupo.allCases), reaplicando: false, motivo: "restaurar automático")
        }
    }

    // --- o toque na prévia (§4.4) ---------------------------------------------------------------

    /// Um toque (ou toque longo) num ponto **do sensor** (`captureDevicePointConverted`). Devolve se
    /// a tela mostra o quadrado. Na principal.
    @discardableResult
    func tocar(pontoDoSensor p: CGPoint, longo: Bool) -> Bool {
        let d = RegrasDosControles.decidirToque(registro, capacidades, longo: longo)
        guard d.quadrado else {
            Diagnostico.nota("APP CAMERA toque: nada a fazer (exposição e foco em manual, ou sem ponto de interesse)")
            return false
        }
        pilula = d.pilula
        // A decisão de novo, sobre o registro **de agora**, dentro da trava (um pedido remoto pode ter
        // escrito no meio).
        let caps = capacidades
        alterar(.local) { a in a = RegrasDosControles.decidirToque(a, caps, longo: longo).ajustes; return true }
        Diagnostico.nota(String(format: "APP CAMERA toque%@ em (%.2f, %.2f): foca=%@ mede=%@%@", longo ? " longo" : "",
                                p.x, p.y, d.foca ? "sim" : "não", d.mede ? "sim" : "não",
                                d.pilula.map { " pílula=\"\($0)\"" } ?? ""))
        dono?.tocarNaFila(p, decisao: d)
        return true
    }

    // --- a leitura de volta (§3.6) --------------------------------------------------------------

    private var relogioDaLeitura: DispatchSourceTimer?
    private var vigias = (iso: RegrasDosControles.VigiaDaDivergencia(), obturador: RegrasDosControles.VigiaDaDivergencia(),
                          kelvin: RegrasDosControles.VigiaDaDivergencia())
    /// Quem quer a leitura de 4 Hz: o painel aberto (a linha do alto) e os receptores que ouvem
    /// (`set_read`, contrato §12, filmador 5). Sob `travaDaLeitura`, lidos pela fila do relógio.
    private let travaDaLeitura = NSLock()
    private var _painelAberto = false
    private var _ouvintesRemotos = false

    /// Liga e desliga a leitura de 4 Hz com o painel aberto. Na principal.
    func lerDeVolta(_ sim: Bool) {
        travaDaLeitura.lock(); _painelAberto = sim; travaDaLeitura.unlock()
        reconfigurarLeitura()
    }

    /// Liga e desliga a leitura de 4 Hz para os receptores (`set_read`). De qualquer thread.
    func ouvintesRemotos(_ sim: Bool) {
        travaDaLeitura.lock()
        let mudou = _ouvintesRemotos != sim
        _ouvintesRemotos = sim
        travaDaLeitura.unlock()
        guard mudou else { return }
        Diagnostico.nota("APP CAMERA remoto: " + (sim ? "receptor ouvindo — o lido vai a ele a 4 Hz" : "nenhum receptor ouvindo"))
        naPrincipal { [weak self] in self?.reconfigurarLeitura() }
    }

    /// O relógio de 4 Hz existe enquanto alguém quer a leitura. Na principal.
    private func reconfigurarLeitura() {
        travaDaLeitura.lock()
        let quer = _painelAberto || _ouvintesRemotos
        travaDaLeitura.unlock()
        if quer == (relogioDaLeitura != nil) { return }
        relogioDaLeitura?.cancel()
        relogioDaLeitura = nil
        guard quer else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 0.25)
        t.setEventHandler { [weak self] in self?.lerUmaVez() }
        t.resume()
        relogioDaLeitura = t
    }

    /// Fora da principal. As propriedades lidas são observáveis por KVO e lidas a qualquer hora,
    /// em qualquer modo (o header): nenhuma trava da câmera é pedida para ler.
    private func lerUmaVez() {
        guard let ap = dono?.entrada?.device else { return }
        let l = AjustesNaCamera.leitura(ap)
        let a = registro
        let agora = CFAbsoluteTimeGetCurrent()
        var texto: String?
        /// Os campos em que esta tela diz "A câmera usou … em vez de …" (o `divergentes` do lido).
        var divergentes: [String] = []
        // Só nos modos manuais e no Kelvin (§3.6).
        if a.exposicao == .manual, let pi = a.iso, let pn = a.obturadorNs, let li = l.iso, let ln = l.obturadorNs {
            let f = faixasAgora(ap)
            let pedidoIso = RegrasDosControles.cortarIso(pi, minimo: f.isoMin, maximo: f.isoMax)
            let pedidoNs = RegrasDosControles.cortarObturador(pn, minimoNs: f.obturadorMinNs, maximoNs: f.obturadorMaxNs, fps: f.fps)
            if vigias.iso.observar(diverge: RegrasDosControles.divergeEmStops(pedido: pedidoIso, lido: li), agora: agora) {
                texto = RegrasDosControles.textoDaDivergencia(lido: RegrasDosControles.textoDoIso(li),
                                                              pedido: RegrasDosControles.textoDoIso(pedidoIso))
                divergentes.append("iso")
            }
            if vigias.obturador.observar(diverge: RegrasDosControles.divergeEmStops(pedido: Double(pedidoNs), lido: Double(ln)), agora: agora) {
                texto = RegrasDosControles.textoDaDivergencia(lido: RegrasDosControles.textoDoObturador(ns: ln),
                                                              pedido: RegrasDosControles.textoDoObturador(ns: pedidoNs))
                divergentes.append("obturadorNs")
            }
        } else {
            _ = vigias.iso.observar(diverge: false, agora: agora)
            _ = vigias.obturador.observar(diverge: false, agora: agora)
        }
        let kPedido = a.balanco == .kelvin ? a.kelvin.map { RegrasDosControles.arredondarKelvin(Double($0)) }
            : RegrasDosControles.kelvinDoPreset(a.balanco)
        if let kp = kPedido, let kl = l.kelvin, ap.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            if vigias.kelvin.observar(diverge: RegrasDosControles.divergeEmKelvin(pedido: kp, lido: kl), agora: agora) {
                texto = RegrasDosControles.textoDaDivergencia(lido: "\(kl) K", pedido: "\(kp) K")
                // Só com Kelvin: num preset o registro não tem `kelvin`, e o receptor não teria o pedido.
                if a.balanco == .kelvin { divergentes.append("kelvin") }
            }
        } else {
            _ = vigias.kelvin.observar(diverge: false, agora: agora)
        }
        travaDaLeitura.lock()
        let painel = _painelAberto, ouvintes = _ouvintesRemotos
        travaDaLeitura.unlock()
        if ouvintes, let r = remoto, cameraAnunciada {
            var lido: [String: Any] = ["divergentes": divergentes]
            if let i = l.iso, i.isFinite { lido["iso"] = Int(i.rounded()) }
            if let n = l.obturadorNs { lido["obturadorNs"] = n }
            if let k = l.kelvin { lido["kelvin"] = k }
            if let ab = l.abertura, ab.isFinite, ab > 0 { lido["abertura"] = (ab * 100).rounded() / 100 }
            if let lente = l.lente, lente.isFinite { lido["focoPosicao"] = RegrasDosControles.focoPosicao(daLente: lente) }
            if let j = CapacidadesRemotas.json(lido) { r.definirLido(j) }
        }
        // A linha do alto só existe com o painel aberto: sem ele, nada vai à principal.
        guard painel else { return }
        naPrincipal { [weak self] in
            guard let self else { return }
            if self.leitura != l { self.leitura = l }
            if self.divergencia != texto { self.divergencia = texto }
        }
    }

    private func faixasAgora(_ ap: AVCaptureDevice) -> FaixasDaCamera { AjustesNaCamera.faixas(ap) }

    /// **Só o retrato de bancada** (`RetratosDeBancada`, "ajustes-camera-…"): valores de exemplo, sem
    /// câmera nenhuma aberta e sem gravar nada.
    func preencherParaRetrato(_ a: AjustesDaCamera, _ c: CapacidadesDaCamera, _ f: FaixasDaCamera,
                              _ l: RegrasDosControles.Leitura) {
        ajustes = a
        trava.lock(); _registro = a; trava.unlock()
        capacidades = c
        faixas = f
        molde = MoldeDoPainel.local(c, f)
        leitura = l
        prontos = true
    }

    // --- o aviso de 3 s -------------------------------------------------------------------------

    private var vezDoAviso = 0

    fileprivate func avisar(_ texto: String) {
        naPrincipal { [weak self] in
            guard let self else { return }
            self.vezDoAviso += 1
            let vez = self.vezDoAviso
            self.aviso = texto
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.vezDoAviso == vez else { return }
                self.aviso = nil
            }
        }
    }
}

/// As traduções entre o `AVCaptureDevice` e os tipos puros, num lugar só.
enum AjustesNaCamera {
    static func ns(_ t: CMTime) -> Int64 {
        let s = CMTimeGetSeconds(t)
        guard s.isFinite, s > 0 else { return 0 }
        return Int64((s * 1e9).rounded())
    }

    /// O mínimo arredondado **para cima** e o máximo **para baixo**: o corte em ns não pode cair um
    /// nanossegundo fora da faixa em `CMTime` (que seria a `NSRangeException` do §2.2).
    private static func nsParaCima(_ t: CMTime) -> Int64 {
        let s = CMTimeGetSeconds(t)
        guard s.isFinite, s > 0 else { return 0 }
        return Int64((s * 1e9).rounded(.up))
    }

    private static func nsParaBaixo(_ t: CMTime) -> Int64 {
        let s = CMTimeGetSeconds(t)
        guard s.isFinite, s > 0 else { return 0 }
        return Int64((s * 1e9).rounded(.down))
    }

    static func tempo(_ ns: Int64) -> CMTime { CMTime(value: ns, timescale: 1_000_000_000) }

    static func capacidades(_ ap: AVCaptureDevice) -> CapacidadesDaCamera {
        var c = CapacidadesDaCamera()
        c.exposicaoCustom = ap.isExposureModeSupported(.custom)
        c.exposicaoUmaVez = ap.isExposureModeSupported(.autoExpose)
        c.exposicaoContinua = ap.isExposureModeSupported(.continuousAutoExposure)
        c.exposicaoTravada = ap.isExposureModeSupported(.locked)
        c.pontoDeExposicao = ap.isExposurePointOfInterestSupported
        c.focoContinuo = ap.isFocusModeSupported(.continuousAutoFocus)
        c.focoUmaVez = ap.isFocusModeSupported(.autoFocus)
        c.focoTravado = ap.isFocusModeSupported(.locked)
        c.pontoDeFoco = ap.isFocusPointOfInterestSupported
        c.lenteCustom = ap.isLockingFocusWithCustomLensPositionSupported && ap.isFocusModeSupported(.locked)
        c.balancoContinuo = ap.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
        c.balancoUmaVez = ap.isWhiteBalanceModeSupported(.autoWhiteBalance)
        c.balancoTravado = ap.isWhiteBalanceModeSupported(.locked)
        c.ganhosCustom = ap.isLockingWhiteBalanceWithCustomDeviceGainsSupported && ap.isWhiteBalanceModeSupported(.locked)
        return c
    }

    /// As faixas do **formato ativo**, e o fps negociado (`activeVideoMinFrameDuration`, §3.1).
    static func faixas(_ ap: AVCaptureDevice) -> FaixasDaCamera {
        let f = ap.activeFormat
        let dur = CMTimeGetSeconds(ap.activeVideoMinFrameDuration)
        return FaixasDaCamera(isoMin: Double(f.minISO), isoMax: Double(f.maxISO),
                              obturadorMinNs: nsParaCima(f.minExposureDuration),
                              obturadorMaxNs: nsParaBaixo(f.maxExposureDuration),
                              evMin: Double(ap.minExposureTargetBias), evMax: Double(ap.maxExposureTargetBias),
                              ganhoMax: Double(ap.maxWhiteBalanceGain),
                              fps: dur.isFinite && dur > 0 ? 1 / dur : 30)
    }

    static func leitura(_ ap: AVCaptureDevice) -> RegrasDosControles.Leitura {
        var l = RegrasDosControles.Leitura()
        l.iso = Double(ap.iso)
        let n = ns(ap.exposureDuration)
        l.obturadorNs = n > 0 ? n : nil
        // Só onde os ganhos fazem sentido para a conta: `temperatureAndTintValues(for:)` com ganhos
        // fora de [1, máximo] lança (o header), e a leitura nunca pode derrubar o app.
        let g = ap.deviceWhiteBalanceGains
        let m = ap.maxWhiteBalanceGain
        if g.redGain >= 1, g.greenGain >= 1, g.blueGain >= 1, g.redGain <= m, g.greenGain <= m, g.blueGain <= m {
            let t = ap.temperatureAndTintValues(for: g).temperature
            if t.isFinite, t > 0 { l.kelvin = Int((Double(t) / 100).rounded()) * 100 }
        }
        l.abertura = Double(ap.lensAperture)
        l.lente = Double(ap.lensPosition)
        return l
    }

    static func nomeDoModo(_ m: AVCaptureDevice.ExposureMode) -> String {
        switch m {
        case .locked: return "travada"
        case .autoExpose: return "medir_e_travar"
        case .continuousAutoExposure: return "continua"
        case .custom: return "manual"
        @unknown default: return "?\(m.rawValue)"
        }
    }

    static func nomeDoModo(_ m: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch m {
        case .locked: return "travado"
        case .autoWhiteBalance: return "medir_e_travar"
        case .continuousAutoWhiteBalance: return "continuo"
        @unknown default: return "?\(m.rawValue)"
        }
    }

    static func nomeDoModo(_ m: AVCaptureDevice.FocusMode) -> String {
        switch m {
        case .locked: return "travado"
        case .autoFocus: return "medir_e_travar"
        case .continuousAutoFocus: return "continuo"
        @unknown default: return "?\(m.rawValue)"
        }
    }

    /// **A linha de leitura de volta para o diário**: o que a câmera diz ter usado, nas unidades do
    /// registro. É a prova 1 do §5 ("as propriedades do device"); o roteiro de prova a lê.
    static func linhaLida(_ ap: AVCaptureDevice) -> String {
        let l = leitura(ap)
        let g = ap.deviceWhiteBalanceGains
        return "iso=\(String(format: "%.0f", l.iso ?? 0)) dur_ns=\(l.obturadorNs ?? 0)"
            + " (\(RegrasDosControles.textoDoObturador(ns: l.obturadorNs ?? 0)))"
            + " ev=\(String(format: "%.2f", ap.exposureTargetBias))"
            + " kelvin=\(l.kelvin.map(String.init) ?? "?")"
            + String(format: " ganhos=%.3f,%.3f,%.3f", g.redGain, g.greenGain, g.blueGain)
            + String(format: " lente=%.3f foco_posicao=%.2f", ap.lensPosition,
                     RegrasDosControles.focoPosicao(daLente: Double(ap.lensPosition)))
            + " modos=exp:\(nomeDoModo(ap.exposureMode)),wb:\(nomeDoModo(ap.whiteBalanceMode)),foco:\(nomeDoModo(ap.focusMode))"
            + String(format: " fps_teto=%.1f", 1 / max(1e-6, CMTimeGetSeconds(ap.activeVideoMinFrameDuration)))
            + " formato=\(CMVideoFormatDescriptionGetDimensions(ap.activeFormat.formatDescription).width)"
            + "x\(CMVideoFormatDescriptionGetDimensions(ap.activeFormat.formatDescription).height)"
    }

    /// O que a câmera declara, numa linha (o roteiro de prova a escreve no começo, e o veredito decide
    /// por ela o que "não se aplica": a frontal de foco fixo, a câmera sem ganhos manuais).
    static func linhaDasCapacidades(_ ap: AVCaptureDevice) -> String {
        let c = capacidades(ap)
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        return "exp_custom:\(b(c.exposicaoCustom)),exp_uma_vez:\(b(c.exposicaoUmaVez)),ponto_exp:\(b(c.pontoDeExposicao))"
            + ",ponto_foco:\(b(c.pontoDeFoco)),foco_uma_vez:\(b(c.focoUmaVez)),foco_fixo:\(b(c.focoFixo))"
            + ",lente:\(b(c.lenteCustom)),ganhos:\(b(c.ganhosCustom)),wb_uma_vez:\(b(c.balancoUmaVez))"
    }

    /// O ponto de interesse volta ao centro (o "Restaurar automático"). Na `fila`: pede e solta a
    /// própria trava da câmera.
    static func pontoAoCentro(_ ap: AVCaptureDevice) {
        guard (try? ap.lockForConfiguration()) != nil else { return }
        defer { ap.unlockForConfiguration() }
        let c = CGPoint(x: 0.5, y: 0.5)
        if ap.isFocusPointOfInterestSupported { ap.focusPointOfInterest = c }
        if ap.isExposurePointOfInterestSupported { ap.exposurePointOfInterest = c }
    }
}

// MARK: - O dono: aplicar, na `fila`

extension DonoDaCaptura {

    /// **Aplica o registro na câmera.** Só na `fila`. `reaplicando`: um gancho do §2.2 (a câmera
    /// reabriu ou se reconfigurou) — todos os grupos, e uma trava que só sabe medir de novo avisa a
    /// pessoa. Sem câmera, ou fechada, não faz nada.
    func aplicarAjustesNaFila(_ grupos: Set<ControlesDaCamera.Grupo> = Set(ControlesDaCamera.Grupo.allCases),
                              reaplicando: Bool, motivo: String) {
        guard !fechado, let ap = entrada?.device else { return }
        guard origem.ehCamera else { return }
        let c = AjustesNaCamera.capacidades(ap)
        let f = AjustesNaCamera.faixas(ap)
        let a = controles.registro
        let p = RegrasDosControles.plano(a, c, f, reaplicando: reaplicando)
        do {
            try ap.lockForConfiguration()
        } catch {
            Diagnostico.falha("APP CAMERA controles: a câmera não liberou a configuração (\(motivo)): \(SanitizacaoDoLog.erro(error))")
            return
        }
        if grupos.contains(.exposicao) { aplicarExposicao(p.exposicao, ap) }
        if grupos.contains(.balanco) { aplicarBalanco(p.balanco, ap) }
        if grupos.contains(.foco) { aplicarFoco(p.foco, ap) }
        ap.unlockForConfiguration()
        controles.publicar(c, f)
        // R9b: a câmera e as faixas ao núcleo, para os receptores (na `fila`, com a câmera aberta).
        controles.anunciar(c, f, nome: CapacidadesRemotas.nomeDaCamera(
            frontal: ap.position == .front ? true : (ap.position == .back ? false : nil), nomeDaOrigem: origem.nome))
        if p.travadoDeNovo { controles.avisar(RegrasDosControles.textoDeTravadoDeNovo) }
        // Uma trava que mediu de novo guarda o que a câmera convergiu (§2.1), para a próxima
        // reaplicação ser como manual onde houver manual.
        if case .medirETravar = p.exposicao, a.travaExposicao { guardarDepoisDeConvergir(ap) }
        else if case .medirETravar = p.foco, a.foco == .travado { guardarDepoisDeConvergir(ap) }
        else if case .medirETravar = p.balanco, a.travaBalanco { guardarDepoisDeConvergir(ap) }
        Diagnostico.nota("APP CAMERA controles aplicados (\(motivo)\(reaplicando ? ", reaplicando" : "")):"
            + " grupos=\(grupos.map { "\($0)" }.sorted().joined(separator: ","))"
            + " plano=exp:\(p.exposicao) wb:\(p.balanco) foco:\(p.foco)"
            + String(format: " faixa=iso %.0f–%.0f, %@–%@, ev %.1f–%.1f, fps %.1f", f.isoMin, f.isoMax,
                     RegrasDosControles.textoDoObturador(ns: f.obturadorMinNs),
                     RegrasDosControles.textoDoObturador(ns: f.obturadorMaxNs), f.evMin, f.evMax, f.fps)
            + (p.travadoDeNovo ? " (travado de novo depois de medir)" : ""))
    }

    /// O EV, só nos modos automáticos e cortado em `Float` contra a câmera.
    private func escreverEv(_ ev: Double, _ ap: AVCaptureDevice) {
        let v = max(ap.minExposureTargetBias, min(Float(ev), ap.maxExposureTargetBias))
        if ap.exposureTargetBias != v { ap.setExposureTargetBias(v, completionHandler: nil) }
    }

    private func aplicarExposicao(_ p: RegrasDosControles.PlanoDeExposicao, _ ap: AVCaptureDevice) {
        switch p {
        case .continua(let ev):
            if ap.isExposureModeSupported(.continuousAutoExposure) { ap.exposureMode = .continuousAutoExposure }
            escreverEv(ev, ap)
        case .medirETravar(let ev):
            escreverEv(ev, ap)
            if ap.isExposureModeSupported(.autoExpose) { ap.exposureMode = .autoExpose }
        case .manual(let iso, let ns):
            guard ap.isExposureModeSupported(.custom) else { return }
            let f = ap.activeFormat
            // O segundo corte, em `Float` e em `CMTime`, contra o formato **de agora**.
            let i = max(f.minISO, min(Float(iso), f.maxISO))
            var d = AjustesNaCamera.tempo(ns)
            if CMTimeCompare(d, f.minExposureDuration) < 0 { d = f.minExposureDuration }
            if CMTimeCompare(d, f.maxExposureDuration) > 0 { d = f.maxExposureDuration }
            ap.setExposureModeCustom(duration: d, iso: i, completionHandler: nil)
        case .nada:
            break
        }
    }

    private func aplicarBalanco(_ p: RegrasDosControles.PlanoDeBalanco, _ ap: AVCaptureDevice) {
        func travarEm(_ g: [Double]) {
            guard ap.isLockingWhiteBalanceWithCustomDeviceGainsSupported, ap.isWhiteBalanceModeSupported(.locked),
                  g.count == 3 else { return }
            let m = ap.maxWhiteBalanceGain
            func c(_ v: Double) -> Float { max(1, min(Float(v), m)) }
            ap.setWhiteBalanceModeLocked(with: AVCaptureDevice.WhiteBalanceGains(redGain: c(g[0]), greenGain: c(g[1]),
                                                                                  blueGain: c(g[2])),
                                         completionHandler: nil)
        }
        switch p {
        case .continuo:
            if ap.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { ap.whiteBalanceMode = .continuousAutoWhiteBalance }
        case .medirETravar:
            if ap.isWhiteBalanceModeSupported(.autoWhiteBalance) { ap.whiteBalanceMode = .autoWhiteBalance }
        case .ganhos(let g):
            travarEm(g)
        case .kelvin(let k):
            // `deviceWhiteBalanceGains(for:)` com o tint em 0, e os ganhos cortados em
            // [1, maxWhiteBalanceGain] (§3.4): a conta pode devolver ganhos fora da faixa.
            let g = ap.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(k), tint: 0))
            travarEm(RegrasDosControles.cortarGanhos([Double(g.redGain), Double(g.greenGain), Double(g.blueGain)],
                                                     maximo: Double(ap.maxWhiteBalanceGain)))
        case .nada:
            break
        }
    }

    private func aplicarFoco(_ p: RegrasDosControles.PlanoDeFoco, _ ap: AVCaptureDevice) {
        switch p {
        case .continuo:
            if ap.isFocusModeSupported(.continuousAutoFocus) { ap.focusMode = .continuousAutoFocus }
        case .medirETravar:
            if ap.isFocusModeSupported(.autoFocus) { ap.focusMode = .autoFocus }
        case .lente(let l):
            guard ap.isLockingFocusWithCustomLensPositionSupported, ap.isFocusModeSupported(.locked) else { return }
            ap.setFocusModeLocked(lensPosition: max(0, min(Float(l), 1)), completionHandler: nil)
        case .nada:
            break
        }
    }

    /// **Depois de convergir** (no máximo 3 s), lê e guarda o que a câmera usou nas travas de pé
    /// (§2.1): `travaIso`/`travaObturadorNs`, `travaGanhos` e `focoPosicao`. Na `fila`, sem segurá-la:
    /// a espera é por reagendamento a cada 100 ms.
    func guardarDepoisDeConvergir(_ ap: AVCaptureDevice, desde: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        fila.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.fechado, self.entrada?.device === ap else { return }
            let ajustando = ap.isAdjustingExposure || ap.isAdjustingFocus || ap.isAdjustingWhiteBalance
            let passou = CFAbsoluteTimeGetCurrent() - desde
            // Um mínimo de 0,3 s: logo depois do pedido a câmera ainda pode não ter começado a ajustar.
            if passou < 0.3 || (ajustando && passou < 3) {
                self.guardarDepoisDeConvergir(ap, desde: desde)
                return
            }
            // O lido antes da trava do registro; a escrita **sobre o registro de agora**, e só nos
            // campos que a trava guarda: um pedido remoto aplicado no meio não é desfeito. É a escrita
            // automática da casca (R9b: `update_settings`, ninguém vira dono de campo).
            let iso = Double(ap.iso)
            let duracao = AjustesNaCamera.ns(ap.exposureDuration)
            let posicao = RegrasDosControles.focoPosicao(daLente: Double(ap.lensPosition))
            let g = ap.deviceWhiteBalanceGains
            let ganhos = [Double(g.redGain), Double(g.greenGain), Double(g.blueGain)]
            self.controles.alterar(.sistema) { a in
                if a.exposicao == .auto, a.travaExposicao {
                    a.travaIso = iso
                    a.travaObturadorNs = duracao
                }
                if a.foco == .travado { a.focoPosicao = posicao }
                if a.balanco == .auto, a.travaBalanco { a.travaGanhos = ganhos }
                return true
            }
            Diagnostico.nota(String(format: "APP CAMERA controles: travas guardadas depois de convergir em %.1f s%@: ",
                                    passou, ajustando ? " (prazo de 3 s)" : "")
                + AjustesNaCamera.linhaLida(ap))
        }
    }

    // --- o pedido de um receptor (R9b, contrato §6) ----------------------------------------------

    /// **Aplica um pedido remoto**, na `fila` (a fila serial por onde passa toda escrita na câmera): o
    /// registro na ordem do §6 (`RegrasDoControleRemoto.aplicar`, partindo do lido só no que o pedido
    /// não trouxe), escrito uma vez com o `n` (o recibo e o "Controlado por"), aplicado na câmera, e o
    /// toque por último. **Todo pedido é respondido** — com o registro (mesmo igual: o núcleo dá o
    /// recibo sem subir a versão) ou com a recusa —, senão o receptor esperaria 5 s pelo `nao_aplicado`.
    func tratarPedidoRemoto(_ p: RegrasDoControleRemoto.Pedido) {
        let c = controles
        guard !fechado, origem.ehCamera, let ap = entrada?.device, c.cameraAnunciada else {
            c.remoto?.recusar(p.n, "nao_aplicado")
            Diagnostico.nota("APP CAMERA remoto: pedido \(p.n) recusado (nao_aplicado: sem câmera aberta)")
            return
        }
        // O que a câmera está usando agora, para "partir do lido".
        let leitura = AjustesNaCamera.leitura(ap)
        let g = ap.deviceWhiteBalanceGains
        let lido = RegrasDoControleRemoto.Lido(
            iso: leitura.iso, obturadorNs: leitura.obturadorNs,
            ganhos: [Double(g.redGain), Double(g.greenGain), Double(g.blueGain)],
            kelvin: leitura.kelvin,
            focoPosicao: RegrasDosControles.focoPosicao(daLente: Double(ap.lensPosition)))
        let f = AjustesNaCamera.faixas(ap)
        let caps = AjustesNaCamera.capacidades(ap)
        // O toque: do quadro decodificado ao sensor. Fora da imagem (não há tarja no iOS, mas a conta
        // pode sair de [0, 1]), `fora_da_imagem`.
        var sensor: CGPoint?
        if let t = p.toque {
            guard let s = pontoDoSensor(doQuadro: t.x, t.y) else {
                c.remoto?.recusar(p.n, "fora_da_imagem")
                Diagnostico.nota(String(format: "APP CAMERA remoto: toque em (%.2f, %.2f) fora da imagem", t.x, t.y))
                return
            }
            sensor = s
        }
        var decisao: RegrasDosControles.DecisaoDoToque?
        let escreveu = c.escreverPedido(p.n) { a in
            guard var novo = RegrasDoControleRemoto.aplicar(p, sobre: a, lido: lido, evMin: f.evMin, evMax: f.evMax) else {
                return false
            }
            if let t = p.toque {
                let d = RegrasDosControles.decidirToque(novo, caps, longo: t.longo)
                decisao = d
                novo = d.ajustes
            }
            a = novo
            return true
        }
        guard escreveu else {
            c.remoto?.recusar(p.n, "nao_aplicado")
            Diagnostico.nota("APP CAMERA remoto: pedido \(p.n) recusado (nao_aplicado: sem o lido da câmera)")
            return
        }
        if p.restaurar {
            // O "Restaurar automático" local também devolve o ponto de interesse ao centro.
            AjustesNaCamera.pontoAoCentro(ap)
            c.mostrarPilula(nil)
        }
        aplicarAjustesNaFila(reaplicando: false, motivo: "pedido \(p.n)")
        if let d = decisao, d.quadrado, let s = sensor {
            c.mostrarPilula(d.pilula)
            tocarNaFila(s, decisao: d)
        }
        Diagnostico.nota("APP CAMERA remoto: pedido \(p.n) aplicado"
            + (p.restaurar ? " (restaurar)" : "")
            + " campos_count=\(p.ajuste.count)"
            + (p.toque.map { String(format: " toque=(%.2f, %.2f)%@ → sensor (%.2f, %.2f)", $0.x, $0.y, $0.longo ? " longo" : "",
                                    sensor?.x ?? -1, sensor?.y ?? -1) } ?? "")
            + " registro_bytes=\(controles.registro.json()?.count ?? 0)")
    }

    /// O toque na prévia, na `fila` (§4.4): o ponto, e `.autoFocus`/`.autoExpose` nele, que travam
    /// sozinhos ao convergir. O toque longo guarda os valores depois de convergir.
    func tocarNaFila(_ p: CGPoint, decisao d: RegrasDosControles.DecisaoDoToque) {
        fila.async { [weak self] in
            guard let self, !self.fechado, let ap = self.entrada?.device else { return }
            guard (try? ap.lockForConfiguration()) != nil else { return }
            let q = CGPoint(x: max(0, min(p.x, 1)), y: max(0, min(p.y, 1)))
            if d.foca, ap.isFocusPointOfInterestSupported, ap.isFocusModeSupported(.autoFocus) {
                ap.focusPointOfInterest = q
                ap.focusMode = .autoFocus
            }
            if d.mede, ap.isExposurePointOfInterestSupported, ap.isExposureModeSupported(.autoExpose) {
                ap.exposurePointOfInterest = q
                ap.exposureMode = .autoExpose
            }
            ap.unlockForConfiguration()
            if d.travarExposicao || d.travarFoco { self.guardarDepoisDeConvergir(ap) }
        }
    }
}

// MARK: - A bancada dos controles

/// **Os argumentos de bancada do R9.** Só valem com o diagnóstico ligado (o mesmo cuidado de
/// `--camera-comum`); a câmera filma a sala, e quem roda com câmera é a sessão principal, com o sim
/// do Pessoa Exemplo.
///
/// - `--luma-media` (a bandeira `luma_media` do §5): a média de luma em contador, um quadro em 30, no
///   diário (`APP CAMERA luma_media=…`), com o custo medido de cada conta;
/// - `--degrau-forcado S` (§5.3): S segundos depois de a câmera montar, chama `reduzirCaptura(true)`,
///   e `--degrau-forcado-por D` segundos depois (padrão 20) a volta. O degrau de calor só nasce de
///   calor de verdade; este é o jeito de provar que a trava sobrevive a ele;
/// - `--camera-ajustes '<json>'`: grava o registro desta câmera antes da primeira aplicação
///   (`'{}'` é o "Restaurar automático");
/// - `--roteiro-dos-controles completo|reabertura`: o roteiro de prova, sem toque (`RoteiroDosControles`).
struct BancadaDosControles {
    var lumaMedia = false
    var degrauForcadoApos: Double?
    var degrauForcadoPor: Double = 20
    var ajustes: String?
    var roteiro: String?

    static let opcoes: BancadaDosControles = {
        var o = BancadaDosControles()
        guard Diagnostico.ligado else { return o }
        let args = CommandLine.arguments
        func valor(_ nome: String) -> String? {
            guard let i = args.firstIndex(of: nome), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        o.lumaMedia = args.contains("--luma-media") || args.contains("--luma_media")
        o.degrauForcadoApos = valor("--degrau-forcado").flatMap { Double($0) }.map { max(0, $0) }
        if let d = valor("--degrau-forcado-por").flatMap({ Double($0) }) { o.degrauForcadoPor = max(1, d) }
        o.ajustes = valor("--camera-ajustes")
        o.roteiro = valor("--roteiro-dos-controles")
        return o
    }()
}
