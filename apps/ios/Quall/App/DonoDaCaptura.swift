import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// Quem recebe os quadros do dono da captura: a transmissão (`EmissorDeCamera`) e, na tela R5, o
/// gravador local (`TomadaDeGravacao`, fase 3, `docs/teleprompter-com-camera.md` §5), cada um na sua
/// vaga do mesmo dono.
///
/// `quadroDaCaptura` é chamado **na fila da captura**; `capturaRetomada`, na **principal** (vem da
/// notificação de fim de interrupção). Nenhum dos dois pode bloquear.
protocol AssinanteDaCaptura: AnyObject {
    /// Um quadro da câmera, já orientado pela conexão. O `CVPixelBuffer` é do `CMSampleBuffer`:
    /// quem quiser guardá-lo além da chamada retém o buffer.
    func quadroDaCaptura(_ amostra: CMSampleBuffer, imagem: CVPixelBuffer)
    /// A captura voltou de uma interrupção (ligação, segundo plano, outro app com a câmera): o
    /// fluxo perdeu continuidade, e quem codifica precisa de um quadro chave.
    func capturaRetomada()
    /// Um buffer do microfone, **na fila do áudio** (não na da câmera). Só chega com o botão do
    /// microfone ligado. O PTS está no mesmo relógio dos quadros de `quadroDaCaptura`.
    func audioDaCaptura(_ amostra: CMSampleBuffer)
}

extension AssinanteDaCaptura {
    func audioDaCaptura(_ amostra: CMSampleBuffer) {}
}

/// O botão do microfone (R5 fase 2). Começa **desligado** em toda abertura de tela.
enum EstadoDoMicrofone: Equatable {
    case desligado
    /// Pedindo a permissão, ou abrindo a entrada na fila da captura.
    case pedindo
    case ligado
    /// Negada ou restringida: o texto diz por quê, e `podeAbrirAjustes` se os Ajustes resolvem.
    case recusado(motivo: String, podeAbrirAjustes: Bool)
    case falhou(String)

    var ligado: Bool { self == .ligado }
}

/// **O dono da captura**: a `AVCaptureSession` da câmera, fora da sessão do Quall.
///
/// # Por que ele existe (R5, 24/09/2026)
///
/// Até aqui a `AVCaptureSession` morava dentro do `EmissorDeCamera`, e a câmera nascia e morria com
/// o botão Espelhar. A tela "Teleprompter com câmera" precisa de outra coisa: a câmera abre quando a
/// **tela** abre e fecha quando ela fecha, e a transmissão **se pendura** nela quando o receptor
/// pareia e **se solta** quando ele cai — sem reabrir a câmera, sem a prévia piscar
/// (`docs/teleprompter-com-camera.md` §1.1, o bloqueio G1 da revisão). Então a câmera ganhou um
/// dono próprio, e o emissor virou um **assinante** dele (`AssinanteDaCaptura`).
///
/// O dono tem três saídas, que ligam e desligam sem tocar na câmera:
///
/// - **a prévia**: uma `AVCaptureVideoPreviewLayer` sobre a mesma `sessao` (`PreVisualizacao`).
///   Esconder a prévia é esconder a vista; a sessão não sabe;
/// - **a transmissão**: o `EmissorDeCamera`, assinante enquanto há receptor;
/// - **o gravador** (fase 3): a `TomadaDeGravacao`, numa **vaga própria** (`pendurarGravador`),
///   independente da transmissão — grava sem receptor, e o receptor entra e sai sem tocar nele. A
///   fase 0 provou no iPhone 7 que dois VideoToolbox e um `AVAssetWriter` fragmentado cabem juntos
///   (§8.2, S-I1).
///
/// # A tela da câmera comum
///
/// Até 24/09 à tarde a `TelaDaCamera` usava um `EmissorDeCamera` com dono **próprio**, montado no
/// Espelhar e fechado no Parar. Desde 24/09 à noite (decisão do Pessoa Exemplo: gravar também na câmera
/// comum, sem receptor) ela é dona do dono como a tela R5: a câmera abre com a tela, com o cardápio
/// (sem `melhorImagem`), e a transmissão e o gravador se penduram nele (§8.8). O código que montava a
/// captura (o cardápio, o formato, a taxa depois do commit, a rotação e a prévia) **mudou de arquivo
/// e não de conteúdo**: as notas históricas vieram junto, porque são elas que explicam cada linha.
///
/// Sem `@MainActor`, pelo mesmo motivo do emissor: os quadros chegam numa fila própria. O que
/// aparece na interface passa por `naPrincipal`.
final class DonoDaCaptura: NSObject, ObservableObject {

    /// Por que a captura parou, quando parou. Vazio quando está correndo.
    @Published private(set) var interrupcao = ""

    /// O botão do microfone. Ver `ligarMicrofone`.
    @Published private(set) var microfone: EstadoDoMicrofone = .desligado {
        didSet {
            let t: String
            switch microfone {
            case .desligado: t = "desligado"
            case .pedindo: t = "pedindo"
            case .ligado: t = "ligado"
            case .recusado: t = "recusado"
            case .falhou: t = "falhou"
            }
            travaDosContadores.lock(); _estadoDoMicrofone = t; travaDosContadores.unlock()
            if microfone != oldValue { Diagnostico.nota("APP MICROFONE botão: \(t)") }
        }
    }

    /// A câmera está montada. O botão do microfone só vale depois disto. Montada não é rodando: o
    /// `ligar` corre na `fila` depois, e um microfone ligado nesse meio tempo (`--microfone-apos 0`)
    /// guarda o relógio do host como provisório e relê o da câmera quando ela roda
    /// (`noRelogioDaCamera`).
    @Published private(set) var montado = false

    /// A câmera montada. Fixa pela vida do dono: trocar de câmera é outro dono.
    private(set) var origem: Origem = .tela

    /// **A melhor imagem do aparelho** (a tela R5, que grava): a captura usa o maior formato 16:9
    /// que **a câmera escolhida** oferece à taxa do cardápio (`EscolhaDaMelhorImagem`, por
    /// `activeFormat`), e não um preset fixo — o 4K fixo derrubou a frontal do iPhone X em 24/09.
    /// Se a escolha falhar, fica o cardápio, como na fase 2. O cardápio continua sendo o teto **da
    /// rede** (`CodificadorH264.destino` reduz), e o arquivo sai no tamanho da captura, pelo segundo
    /// codificador (decisão do Pessoa Exemplo, 24/09: "a melhor do aparelho, com segundo codificador"). Fixa
    /// pela vida do dono: a captura não muda de formato com a gravação (mudar ciclaria a câmera).
    private(set) var melhorImagem = false

    /// A melhor imagem **foi aplicada** por formato (e não caiu no cardápio na montagem). Só na
    /// principal. Ver `recuarDaMelhorImagem`.
    private var melhorImagemAplicada = false
    /// O recuo para o cardápio depois de um erro de execução acontece **uma vez**: se o cardápio
    /// também falhar, o erro chega à pessoa como sempre chegou. Só na principal.
    private var recuoDaMelhorImagemFeito = false

    let sessao = AVCaptureSession()

    private let saida = AVCaptureVideoDataOutput()
    /// A fila da câmera: os quadros, o ligar e o parar, e **toda escrita na câmera** desde o R9 (os
    /// ajustes de `AjustesNaCamera.swift`, que é outro arquivo — por isso não é `private`).
    let fila = DispatchQueue(label: "br.com.queven.quall.camera", qos: .userInitiated)

    /// **Os controles de câmera do R9** (`docs/controles-de-camera.md`): o registro desta câmera, o
    /// que ela oferece e o que ela diz ter usado. Ver `AjustesNaCamera.swift`.
    let controles = ControlesDaCamera()

    override init() {
        super.init()
        controles.dono = self
    }

    // --- o microfone (R5 fase 2) ----------------------------------------------------------------
    //
    // **Numa `AVCaptureSession` só dele** (`sessaoDoMicrofone`), e não na da câmera. Até `baee307`
    // a entrada de áudio entrava na `sessao` da câmera, e o `beginConfiguration`/`commitConfiguration`
    // com a câmera no ar **parou a imagem por 434 ms** no iPhone X (prova de 24/09, 15:09:52: "APP
    // MICROFONE botão: ligado" e a janela seguinte com `camera=28.8 fps buraco_maior=434 ms`). Com
    // duas sessões, ligar e desligar o microfone não tocam na da câmera. O preço é o relógio: o PTS
    // do som sai no relógio da sessão do microfone, e é convertido para o da câmera antes de sair
    // daqui (`noRelogioDaCamera`). Ver `docs/teleprompter-com-camera.md` §8.5.
    //
    // A entrada e a sessão de áudio só existem com o botão ligado: o ponto laranja do iOS diz a
    // verdade.
    let sessaoDoMicrofone = AVCaptureSession()
    private let saidaDeAudio = AVCaptureAudioDataOutput()
    /// Os buffers do microfone chegam aqui, e não na `fila` da câmera: codificar Opus na fila dos
    /// quadros atrasaria a imagem.
    /// **`.userInteractive`** desde a bancada do iPhone 7 quente (27/09, §8.12.11): o som chegava ao
    /// emissor com até 1 s de atraso e em rajadas de 8 buffers, com a captura sem buraco nenhum no PTS;
    /// a fila da entrega disputava com a da câmera, os dois encoders e a tomada, todos `userInitiated`.
    private let filaDoAudio = DispatchQueue(label: "br.com.queven.quall.microfone", qos: .userInteractive)
    /// **Onde o microfone liga e desliga**: nem a `fila` dos quadros (o `startRunning` da sessão do
    /// microfone bloqueia por centenas de milissegundos, e bloquear a `fila` é perder quadros com
    /// `alwaysDiscardsLateVideoFrames`), nem a `filaDoAudio` (a dos buffers). Serial: ligar e
    /// desligar ficam em ordem. Nunca faz `sync` na `fila`.
    private let controleDoMicrofone = DispatchQueue(label: "br.com.queven.quall.microfone.controle",
                                                    qos: .userInitiated)
    /// Só lidos e escritos **na `controleDoMicrofone`**.
    private var entradaDeAudio: AVCaptureDeviceInput?
    private var sessaoDeAudioAtiva = false
    /// O dono fechou: um ligar atrasado não abre o microfone. Só na `controleDoMicrofone`.
    private var microfoneFechado = false
    /// Os dois relógios da conversão, lidos quando o microfone abre. Sob `travaDosRelogios`.
    private let travaDosRelogios = NSLock()
    private var _relogioDoMicrofone: CMClock?
    private var _relogioDaCamera: CMClock?
    /// O relógio da câmera guardado é o do host porque a sessão da câmera ainda não rodava
    /// (`--microfone-apos 0`): é relido no primeiro buffer com ela rodando.
    private var _relogioDaCameraProvisorio = false
    /// A sessão do microfone está aberta (entre o `startRunning` e o `stopRunning`). Buffers que
    /// chegam atrasados depois do fechar são descartados, e não saem sem conversão.
    private var _microfoneAberto = false
    /// Buffers que saíram **sem** a conversão (o buffer sem tempos legíveis, a cópia recusada, ou
    /// sem os dois relógios). Deve ficar em 0; o relato de 10 s o publica.
    private var _semConversao: UInt64 = 0
    /// Cada pedido de ligar ou desligar leva um número: a resposta atrasada de um pedido velho
    /// (a permissão, a abertura na fila) não passa por cima do botão. Só na principal.
    private var vezDoMicrofone = 0
    /// O microfone estava ligado quando o app saiu da tela, e o iOS o fechou (sem modo de segundo
    /// plano, a sessão do microfone é interrompida fora da tela): volta sozinho no `.active`. Só
    /// na principal.
    private var religarAoVoltar = false
    private(set) var entrada: AVCaptureDeviceInput?
    private var observadores: [NSObjectProtocol] = []
    private var relogio: DispatchSourceTimer?

    /// A prévia como espelho (o ajuste local da tela R5, `docs/teleprompter-com-camera.md` §6).
    /// `nil` é o comportamento de antes: a camada decide sozinha (a frontal sai espelhada). A saída
    /// de dados — a rede e, na fase 3, o arquivo — **nunca** espelha: ver `montarCaptura`.
    var espelharPrevia: Bool? {
        didSet { naPrincipal { [weak self] in self?.aplicarEspelhoNaPrevia() } }
    }

    // --- o assinante --------------------------------------------------------------------------

    private let travaDoAssinante = NSLock()
    private weak var _assinante: AssinanteDaCaptura?

    /// Pendura um assinante. Troca o anterior, se houver (hoje a vaga é uma só).
    func assinar(_ a: AssinanteDaCaptura) {
        travaDoAssinante.lock(); _assinante = a; travaDoAssinante.unlock()
        Diagnostico.nota("APP CAMERA dono: assinante pendurado")
    }

    /// Solta o assinante, **se ainda for ele**: um soltar atrasado de uma sessão velha não pode
    /// derrubar a nova.
    func soltar(_ a: AssinanteDaCaptura) {
        travaDoAssinante.lock()
        let era = _assinante === a
        if era { _assinante = nil }
        travaDoAssinante.unlock()
        if era { Diagnostico.nota("APP CAMERA dono: assinante solto") }
    }

    private var assinante: AssinanteDaCaptura? {
        travaDoAssinante.lock(); defer { travaDoAssinante.unlock() }
        return _assinante
    }

    /// **A vaga do gravador** (fase 3), separada da transmissão: pendurar ou soltar um não mexe no
    /// outro, e a câmera não é tocada.
    private weak var _gravador: AssinanteDaCaptura?

    func pendurarGravador(_ g: AssinanteDaCaptura) {
        travaDoAssinante.lock(); _gravador = g; travaDoAssinante.unlock()
        Diagnostico.nota("APP CAMERA dono: gravador pendurado")
    }

    /// Solta o gravador, **se ainda for ele** (a mesma regra de `soltar`).
    func soltarGravador(_ g: AssinanteDaCaptura) {
        travaDoAssinante.lock()
        let era = _gravador === g
        if era { _gravador = nil }
        travaDoAssinante.unlock()
        if era { Diagnostico.nota("APP CAMERA dono: gravador solto") }
    }

    private var gravador: AssinanteDaCaptura? {
        travaDoAssinante.lock(); defer { travaDoAssinante.unlock() }
        return _gravador
    }

    // --- o ângulo congelado (fase 3, revisão M-d) -----------------------------------------------

    /// **Gravando, o ângulo da conexão não muda** (`docs/teleprompter-com-camera.md` §5.2): o ângulo
    /// muda o tamanho do quadro (em retrato a captura entrega 1080x1920), e o arquivo tem tamanho
    /// fixo. A rede congela junto — é a mesma conexão —, e a interface fica travada pela tela. Só na
    /// principal.
    private(set) var anguloCongelado = false
    private var giroSeguradoRelatado = false

    func congelarAngulo(_ sim: Bool) {
        guard sim != anguloCongelado else { return }
        anguloCongelado = sim
        giroSeguradoRelatado = false
        var atual = "?"
        if let cx = saida.connection(with: .video) {
            if #available(iOS 17.0, *) { atual = "\(Int(cx.videoRotationAngle))" } else { atual = "vo:\(cx.videoOrientation.rawValue)" }
        }
        Diagnostico.nota("APP CAMERA ângulo da conexão \(sim ? "CONGELADO (gravando)" : "solto")"
            + " angulo=\(atual) formato=\(formatoRecebido)")
    }

    /// A conexão volta a seguir a interface de agora (depois de a gravação descongelar o ângulo: o
    /// giro que aconteceu gravando foi segurado, e nenhum aviso novo virá). Só na principal.
    func reaplicarOrientacaoDaCena() {
        let cena = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        acompanharOrientacao(cena?.interfaceOrientation ?? .portrait)
    }

    /// Há quanto tempo chegou o último quadro da câmera, em segundos (monotônico). `nil` sem nenhum.
    var ultimoQuadroHa: Double? {
        travaDosContadores.lock(); defer { travaDosContadores.unlock() }
        guard _ultimoQuadroEm > 0 else { return nil }
        return ProcessInfo.processInfo.systemUptime - _ultimoQuadroEm
    }

    // --- a permissão --------------------------------------------------------------------------

    enum Permissao {
        case concedida
        /// Negada ou restringida. `podeAbrirAjustes` diz se abrir os Ajustes resolve: com
        /// restrição por controle parental, não resolve.
        case recusada(motivo: String, podeAbrirAjustes: Bool)
    }

    static var textoDeNegada: String {
        tr("O Quall não tem acesso à câmera deste iPhone. Abra %@ e ligue, "
           + "depois escolha a câmera e toque em Espelhar de novo.", trSistema("Ajustes → Quall Studio → Câmera"))
    }

    /// **Pede**, e não só lê (`docs/regras-de-frente.md`, "Ler o estado de uma permissão não é
    /// pedi-la"). A resposta volta na principal.
    static func pedirPermissao(textoDeNegada: String = DonoDaCaptura.textoDeNegada,
                               _ fim: @escaping (Permissao) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            naPrincipal { fim(.concedida) }
        case .notDetermined:
            // O alerta do sistema só aparece uma vez na vida do app. Depois disso, quem responde
            // é `authorizationStatus`, e `requestAccess` volta na hora com a resposta guardada.
            AVCaptureDevice.requestAccess(for: .video) { concedida in
                naPrincipal {
                    fim(concedida ? .concedida : .recusada(motivo: textoDeNegada, podeAbrirAjustes: true))
                }
            }
        case .denied:
            naPrincipal { fim(.recusada(motivo: textoDeNegada, podeAbrirAjustes: true)) }
        case .restricted:
            // Controle parental ou perfil de gerenciamento. Mandar a pessoa aos Ajustes seria
            // mandá-la a uma tela onde o botão está desligado e não pode ser ligado por ela.
            naPrincipal {
                fim(.recusada(motivo: tr("O acesso à câmera está bloqueado neste iPhone por Tempo de Uso ou "
                                 + "por um perfil de gerenciamento. Quem administra o aparelho precisa liberar."),
                              podeAbrirAjustes: false))
            }
        @unknown default:
            naPrincipal { fim(.recusada(motivo: textoDeNegada, podeAbrirAjustes: true)) }
        }
    }

    // --- o ciclo ------------------------------------------------------------------------------

    /// **Monta sem travar a principal** (§8.12.10): a montagem (a entrada da câmera, os formatos, o
    /// `lockForConfiguration`) corre na `fila`, e o resto — observar, supervisionar, a camada, o
    /// `montado` — volta à principal. No iPad de 27/09, fechar a tela com câmera e reabrir congelou a
    /// interface: a entrada nova espera a câmera que a sessão anterior ainda está soltando, e isso
    /// acontecia na principal. `fim(nil)` montada, `fim(texto)` não; na principal. Uma tela que fecha
    /// no meio (`fechar`) não recebe `fim`.
    func montarSemTravar(_ origem: Origem, melhorImagem: Bool = false, fim: @escaping (String?) -> Void) {
        self.origem = origem
        self.melhorImagem = melhorImagem
        recuoDaMelhorImagemFeito = false
        let cena = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let interface = cena?.interfaceOrientation ?? .portrait
        MedidorDeCpu.marcarPrincipal()
        controleDoMicrofone.async { [weak self] in self?.microfoneFechado = false }
        let inicio = CFAbsoluteTimeGetCurrent()
        fila.async { [weak self] in
            guard let self else { return }
            self.fechado = false
            self.interfaceParaMontar = interface
            let erro = self.montarCaptura()
            self.interfaceParaMontar = nil
            if erro == nil {
                self.fixarTaxaDepoisDoCommit()
                // R9 (§2.2): o fim do `montar`, depois do `limitarTaxa` — já na `fila`.
                self.aplicarAjustesNaFila(reaplicando: true, motivo: "a câmera montou")
            }
            let ms = (CFAbsoluteTimeGetCurrent() - inicio) * 1000
            naPrincipal { [weak self] in
                guard let self else { return }
                guard !self.fechadoPelaTela else {
                    DonoDaCaptura.dizerNosDois(String(format: "APP CAMERA dono: montagem terminou em %.0f ms com a tela já fechada; nada liga", ms))
                    return
                }
                DonoDaCaptura.dizerNosDois(String(format: "APP CAMERA dono: captura montada fora da principal em %.0f ms", ms)
                    + (erro.map { " (falhou: \($0))" } ?? ""))
                if let erro { fim(erro); return }
                if let ap = self.entrada?.device { self.prepararCoordenador(para: ap) }
                self.observarInterrupcoes()
                self.observarRodando()
                self.subirSupervisao()
                self.aplicarEspelhoNaPrevia()
                self.observarSessaoDeAudio()
                self.montado = true
                self.agendarMicrofoneDaBancada()
                self.agendarBancadaDosControles()
                fim(nil)
            }
        }
    }

    /// A interface na hora do `montarSemTravar`, para a conexão nascer na orientação certa sem ler a
    /// cena fora da principal. Só na `fila`, durante a montagem.
    private var interfaceParaMontar: UIInterfaceOrientation?
    /// `fechar` já passou (principal): uma montagem ainda na `fila` não liga nada ao voltar. Um dono é
    /// de uma tela só (`PecasDaTelaComCamera`): não volta a `false`.
    private var fechadoPelaTela = false

    /// **A câmera entregou o primeiro quadro** desde que começou a rodar: a tela tira o "Aguarde…".
    @Published private(set) var entregando = false
    /// Só na `fila`.
    private var avisouEntrega = false

    /// Monta a captura da câmera `origem` e começa a observá-la. **Não** a põe para rodar: ver
    /// `ligar`. Devolve `nil` quando deu certo, e o texto do problema quando não.
    ///
    /// Chamado na principal, uma vez por dono (a câmera comum; a tela R5 usa `montarSemTravar`).
    func montar(_ origem: Origem, melhorImagem: Bool = false) -> String? {
        self.origem = origem
        self.melhorImagem = melhorImagem
        recuoDaMelhorImagemFeito = false
        // Montar de novo é abrir de novo: o `ligar` seguinte vale. Pela `fila`, na ordem.
        fila.async { [weak self] in self?.fechado = false }
        controleDoMicrofone.async { [weak self] in self?.microfoneFechado = false }
        if let erro = montarCaptura() { return erro }
        // A configuração da sessão já foi comitada pelo `defer` de `montarCaptura`; **agora** a
        // taxa pode ser escrita sem ser apagada. Ver `fixarTaxaDepoisDoCommit`.
        fixarTaxaDepoisDoCommit()
        // R9 (§2.2, §6): o fim do `montar`, depois do `limitarTaxa`, e **na `fila`** — esta montagem
        // corre na principal, e daqui em diante só a `fila` escreve na câmera.
        fila.async { [weak self] in self?.aplicarAjustesNaFila(reaplicando: true, motivo: "a câmera montou") }
        observarInterrupcoes()
        observarRodando()
        subirSupervisao()
        // A conexão da camada nasce agora, com a entrada: o espelho pedido vale já, e não só no
        // próximo leiaute ou relato.
        aplicarEspelhoNaPrevia()
        observarSessaoDeAudio()
        montado = true
        agendarMicrofoneDaBancada()
        agendarBancadaDosControles()
        return nil
    }

    /// O dono foi fechado: um `ligar` que chegue depois (a permissão respondendo tarde) não sobe
    /// a câmera. Só lido e escrito **na `fila`**.
    private(set) var fechado = false

    /// Põe a captura para rodar. `startRunning` bloqueia por centenas de milissegundos e nunca vai
    /// para a thread principal.
    ///
    /// **Ligar e parar passam os dois pela `fila`, em ordem.** Ler `isRunning` de outra thread
    /// enquanto o `startRunning` ainda está na fila dava "não está rodando, nada a parar", e a
    /// câmera subia logo depois, sem dono e com a luz verde acesa.
    func ligar() {
        fila.async { [weak self] in
            guard let self, !self.fechado, !self.sessao.isRunning else { return }
            // No segundo plano: liga quando voltar (§8.12.9).
            if self.noSegundoPlano { self.ligarAoVoltar = true; return }
            self.esquecerRelogioDosQuadros()
            self.sessao.startRunning()
        }
    }

    // --- os degraus da transmissão (§8.12.16) ---------------------------------------------------

    /// **A prévia pausada** (o degrau 1): a conexão da camada desligada — a câmera segue para a rede e a
    /// gravação, e a composição da prévia sai da conta. Só na principal.
    private(set) var previaPausada = false

    func pausarPrevia(_ sim: Bool) {
        let mudou = sim != previaPausada
        previaPausada = sim
        // Escrito sempre (e de novo no relato de 10 s): a camada pode nascer ou ser trocada depois.
        if let cx = camadaDePrevia?.connection, cx.isEnabled == sim { cx.isEnabled = !sim }
        if mudou {
            DonoDaCaptura.dizerNosDois("APP CAMERA prévia " + (sim ? "pausada (a transmissão é a prioridade)" : "de volta"))
        }
    }

    /// **A captura em 720p** (o degrau 3): sem gravação de pé, a captura 1080p só serve para ser reduzida
    /// a 720p na rede. Reduzida: o preset de 720p. De volta: o formato de antes (a melhor imagem) e a taxa.
    /// **Nunca com gravação pendurada** (o arquivo tem tamanho fixo): recusa e diz. Da principal; a
    /// configuração corre na `fila`. `fim(aplicou)` na principal.
    private var formatoCheio: AVCaptureDevice.Format?
    private var presetCheio: AVCaptureSession.Preset?
    private(set) var capturaReduzida = false

    func reduzirCaptura(_ sim: Bool, fim: ((Bool) -> Void)? = nil) {
        guard sim != capturaReduzida, !reconfigurandoCaptura else { fim?(sim == capturaReduzida); return }
        guard gravador == nil else {
            DonoDaCaptura.dizerNosDois("APP CAMERA captura " + (sim ? "em 720p" : "de volta") + ": recusado (gravação pendurada)")
            fim?(false)
            return
        }
        reconfigurandoCaptura = true
        fila.async { [weak self] in
            guard let self else { return }
            // Conferido de novo aqui: uma gravação pode ter pendurado no meio (a fila atrasa no calor).
            let ok = self.reconfigurarCaptura(sim)
            naPrincipal {
                self.reconfigurandoCaptura = false
                if ok { self.capturaReduzida = sim }
                fim?(ok)
            }
        }
    }

    /// Só na principal: uma reconfiguração já pedida e ainda na `fila`.
    private var reconfigurandoCaptura = false

    /// Na `fila`. `true` quando o estado pedido vale agora.
    private func reconfigurarCaptura(_ sim: Bool) -> Bool {
        guard !fechado, gravador == nil, let aparelho = entrada?.device else {
            DonoDaCaptura.dizerNosDois("APP CAMERA captura " + (sim ? "em 720p" : "de volta") + ": não feito (fechada ou gravação pendurada)")
            return false
        }
        let inicio = CFAbsoluteTimeGetCurrent()
        let antes = CMVideoFormatDescriptionGetDimensions(aparelho.activeFormat.formatDescription)
        if sim {
            // Já em 720p ou menos: nada a mexer (e nada a devolver).
            guard max(antes.width, antes.height) > 1280, sessao.canSetSessionPreset(.hd1280x720) else {
                formatoCheio = nil; presetCheio = nil
                DonoDaCaptura.dizerNosDois("APP CAMERA captura em 720p: já está em \(antes.width)x\(antes.height); nada a mexer")
                return true
            }
            formatoCheio = aparelho.activeFormat
            presetCheio = sessao.sessionPreset
            sessao.beginConfiguration()
            sessao.sessionPreset = .hd1280x720
            sessao.commitConfiguration()
        } else {
            guard let f = formatoCheio else { return true }
            sessao.beginConfiguration()
            if (try? aparelho.lockForConfiguration()) != nil {
                aparelho.activeFormat = f
                aparelho.unlockForConfiguration()
            }
            if let p = presetCheio, sessao.canSetSessionPreset(p) { sessao.sessionPreset = p }
            sessao.commitConfiguration()
            formatoCheio = nil; presetCheio = nil
        }
        // A taxa, depois do commit (trocar o preset ou o formato a redefine; revisão de 27/09, M1).
        limitarTaxa(de: aparelho)
        // R9 (§2.2): trocar o preset ou o formato desfaz exposição, balanço e foco; a reaplicação vem
        // depois do `limitarTaxa`, cortada pela faixa do formato novo.
        aplicarAjustesNaFila(reaplicando: true, motivo: sim ? "captura em 720p" : "captura de volta")
        let d = CMVideoFormatDescriptionGetDimensions(aparelho.activeFormat.formatDescription)
        DonoDaCaptura.dizerNosDois(String(format: "APP CAMERA captura %@: %dx%d → %dx%d em %.0f ms",
                                          sim ? "em 720p (a transmissão é a prioridade)" : "de volta",
                                          antes.width, antes.height, d.width, d.height,
                                          (CFAbsoluteTimeGetCurrent() - inicio) * 1000))
        return true
    }

    /// **O app está no segundo plano** (§8.12.9): no iPad, fora do primeiro plano, o sistema pode
    /// deixar a câmera rodando; aqui ela para, e **nada a liga** até o primeiro plano — nem um `ligar`
    /// que ainda estava na fila, nem o recuo da melhor imagem (revisão de 27/09, M3). Só na `fila`.
    private(set) var noSegundoPlano = false
    /// Havia captura rodando (ou por ligar) quando o segundo plano chegou: o primeiro plano a liga.
    private var ligarAoVoltar = false

    /// Para a captura (não fecha o dono). Da principal; o `stopRunning` corre na `fila`.
    func pausarNoSegundoPlano() {
        fila.async { [weak self] in
            guard let self, !self.fechado, !self.noSegundoPlano else { return }
            self.noSegundoPlano = true
            self.ligarAoVoltar = self.sessao.isRunning || self.ligarAoVoltar
            if self.sessao.isRunning { self.sessao.stopRunning() }
            self.avisouEntrega = false
            naPrincipal { [weak self] in self?.entregando = false }
            DonoDaCaptura.dizerNosDois("APP CAMERA dono: captura pausada (o app foi ao segundo plano)")
        }
    }

    /// Volta a captura que o segundo plano pausou, e avisa quem está pendurado como numa volta de
    /// interrupção (o `stopRunning` foi nosso, e o iOS não manda `InterruptionEnded`).
    func retomarDoSegundoPlano() {
        fila.async { [weak self] in
            guard let self, self.noSegundoPlano else { return }
            self.noSegundoPlano = false
            let ligar = self.ligarAoVoltar
            self.ligarAoVoltar = false
            guard !self.fechado, ligar else { return }
            self.esquecerRelogioDosQuadros()
            if !self.sessao.isRunning { self.sessao.startRunning() }
            DonoDaCaptura.dizerNosDois("APP CAMERA dono: captura retomada (primeiro plano)")
            naPrincipal { [weak self] in self?.aoRetomar() }
        }
    }

    /// O diário e a saída padrão (que o `idevicedebug` guarda sem perda).
    static func dizerNosDois(_ linha: String) {
        Diagnostico.nota(linha)
        guard Diagnostico.ligado else { return }
        print("[quall-camera] " + SanitizacaoDoLog.mensagem(linha))
        fflush(stdout)
    }

    /// Para de observar e de relatar. Pode ser chamado de qualquer thread; a captura em si para em
    /// `pararDeRodar`, que bloqueia.
    func pararObservacao() {
        relogio?.cancel()
        relogio = nil
        for o in observadores { NotificationCenter.default.removeObserver(o) }
        observadores.removeAll()
    }

    /// `stopRunning`, **síncrono** e na `fila`, depois de qualquer `ligar` pendente: nunca na
    /// principal, nem de dentro da própria `fila`.
    func pararDeRodar() {
        let inicio = CFAbsoluteTimeGetCurrent()
        // O microfone fecha com a câmera (e antes dela: o ponto laranja apaga primeiro), e a sessão
        // de áudio é devolvida: a música que outro app tocava volta (`.notifyOthersOnDeactivation`).
        // Na fila dele, depois de qualquer ligar pendente; ela nunca espera a `fila`, então o `sync`
        // aqui não trava.
        controleDoMicrofone.sync {
            microfoneFechado = true
            fecharMicrofoneNaFila(motivo: "a câmera fechou")
        }
        let rodava: Bool = fila.sync {
            fechado = true
            // R9b: os receptores ficam sem câmera **aqui**, junto do `fechado`, na `fila`: nenhum
            // anúncio atrasado (um pedido, uma volta de interrupção) passa por cima.
            controles.cameraFechou()
            let r = sessao.isRunning
            if r { sessao.stopRunning() }
            return r
        }
        naPrincipal { [weak self] in
            guard let self else { return }
            self.vezDoMicrofone += 1
            self.religarAoVoltar = false
            self.montado = false
            if self.microfone != .desligado { self.microfone = .desligado }
        }
        DonoDaCaptura.dizerNosDois(String(format: "APP CAMERA dono: captura fechada em %.0f ms (rodava=%@)",
                                          (CFAbsoluteTimeGetCurrent() - inicio) * 1000, rodava ? "sim" : "não"))
    }

    /// O fim do dono, da principal: para de observar e para a captura numa thread própria.
    func fechar() {
        fechadoPelaTela = true
        controles.lerDeVolta(false)
        controles.esquecerCamera()
        pararObservacao()
        let t = Thread { [self] in pararDeRodar() }
        t.stackSize = 256 * 1024
        t.name = "quall.camera.fechar"
        t.start()
    }

    /// Monta a `AVCaptureSession`. Devolve `nil` quando deu certo, e o texto do problema quando
    /// não — texto para a pessoa ler, porque uma tela de câmera em branco não diz nada.
    private func montarCaptura() -> String? {
        sessao.beginConfiguration()
        defer { sessao.commitConfiguration() }

        let escolhida = Resolucao.escolhida

        // Pelo `uniqueID`, e não por posição: o seletor enumerou as câmeras **físicas** do
        // aparelho, e num iPhone com duas lentes traseiras "a traseira" não identifica nada. O
        // `uniqueID` é o que o `DiscoverySession` devolveu e é estável para a mesma lente.
        guard case .camera(let id, _) = origem, let aparelho = AVCaptureDevice(uniqueID: id) else {
            return tr("A câmera escolhida não está mais disponível. Volte e escolha outra.")
        }
        // **A entrada entra ANTES de qualquer preset** (conserto de 24/09, iPhone X 18:06). A ordem
        // errada é anterior ao R5 e valia para os dois caminhos: o preset era escolhido com a
        // sessão vazia, e sem entrada o `canSetSessionPreset` não tem contra o que conferir. Na
        // fase 3 ele disse sim ao 4K da melhor imagem, a frontal do iPhone X não faz 4K, e o
        // `canAddInput` seguinte recusou a câmera: a captura inteira caiu por uma preferência de
        // qualidade. O caminho comum caía pelo mesmo mecanismo com o cardápio em 2K ou 4K
        // (`Resolucao.preset` é `.hd4K3840x2160` para os dois) numa câmera sem 4K; agora ele desce
        // para 1080p. Com a entrada já na sessão (no preset padrão, `.high`, que toda câmera
        // aceita), o `canSetSessionPreset` responde sobre **esta** câmera.
        guard let nova = try? AVCaptureDeviceInput(device: aparelho), sessao.canAddInput(nova) else {
            return tr("Não foi possível abrir a câmera deste iPhone.")
        }
        sessao.addInput(nova)
        entrada = nova
        // R9: o registro desta câmera (`camera.ajustes.<uniqueID>`), antes da primeira aplicação. A
        // bancada pode trocá-lo (`--camera-ajustes`).
        if let j = BancadaDosControles.opcoes.ajustes {
            let a = AjustesDaCamera.de(json: Data(j.utf8))
            if a == .padrao { UserDefaults.standard.removeObject(forKey: AjustesDaCamera.chave(id)) }
            else if let d = a.json() { UserDefaults.standard.set(d, forKey: AjustesDaCamera.chave(id)) }
            Diagnostico.nota("APP CAMERA controles bancada: --camera-ajustes gravou o registro")
        }
        controles.carregar(uniqueID: id)

        // **A melhor imagem (tela R5, que grava)**: o maior formato 16:9 que **esta** câmera
        // oferece à taxa do cardápio, aplicado por `activeFormat` + `.inputPriority` — nunca um
        // preset fixo. Ver `EscolhaDaMelhorImagem`. Se a escolha falhar por qualquer motivo, cai no
        // cardápio abaixo, como a fase 2: a qualidade é preferência, a câmera não.
        var formatoDaMelhorImagem = false
        if melhorImagem {
            formatoDaMelhorImagem = aplicarMelhorImagem(em: aparelho)
        }

        var presetAplicado: AVCaptureSession.Preset?
        if !formatoDaMelhorImagem { presetAplicado = aplicarPresetDoCardapio() }
        // Os tetos do cardápio desta câmera (o que a folha de Ajustes apaga, 06/10), para a prova pelo diário.
        let tetos = TetosDaCamera.tetos(cameraID: id)
        Diagnostico.nota("APP CAMERA tetos do cardápio: " + Resolucao.allCases.map { r in
            "\(r.rotulo)=" + ((tetos[r.rawValue] ?? nil).map { "\($0)" } ?? "não oferece")
        }.joined(separator: " "))
        Diagnostico.nota("APP CAMERA cardápio: \(escolhida.rotulo) a \(Resolucao.quadros) fps"
            + (formatoDaMelhorImagem
                ? " · melhor imagem por formato (preset=\(sessao.sessionPreset.rawValue))"
                : " · preset pedido=\(escolhida.preset.rawValue)"
                    + (melhorImagem ? " (melhor imagem não aplicada: caiu no cardápio)" : "")
                    + " aplicado=\(presetAplicado?.rawValue ?? "nenhum")"))

        // **A taxa NÃO é fixada aqui.** Ver `limitarTaxa`: `activeVideoMinFrameDuration` é
        // redefinido quando o preset da sessão muda, e o `commitConfiguration` do `defer` no topo
        // deste método ainda vai rodar. Escrever agora é escrever para ser apagado.
        // **O formato segue o mesmo contrato da folha**, inclusive a 30: uma resolução salva que
        // esta câmera não faz recua sem mudar a preferência, e 2K pode vir de 4K reduzido.
        //
        // Medido em 07/09/2026 nos dois aparelhos que existem para testar: iPhone 15 pedindo
        // 4K@60 e iPad A16 pedindo 1080p@60 receberam, os dois, um formato com
        // `videoSupportedFrameRateRanges = ["1-30"]`. O iPhone 15 **faz** 4K60 — o que ele não faz
        // é entregá-lo por preset: `AVCaptureSession.Preset` escolhe um formato por você, e
        // escolhe um de 30.
        //
        // Escrever `activeFormat` é o caminho documentado, e ele **substitui** o preset: a sessão
        // passa a `.inputPriority`, que é o que a Apple manda usar quando quem escolhe é o app.
        // Com a melhor imagem aplicada, a taxa já entrou na escolha do formato.
        if !formatoDaMelhorImagem {
            let plano = TetosDaCamera.estado(cameraID: id)
            escolherFormato(para: aparelho,
                             alvo: TetosDaCamera.resolucao(para: plano, preferida: Resolucao.escolhida),
                             fps: plano.fpsEfetivo ?? Resolucao.quadros)
        }
        melhorImagemAplicada = formatoDaMelhorImagem
        aparelhoParaTaxa = aparelho
        // O coordenador de rotação é deste aparelho: recriar quando a câmera muda. Ver `aplicar`.
        // Fora da principal (a montagem sem travar), ele nasce na volta, junto da camada.
        if Thread.isMainThread { prepararCoordenador(para: aparelho) }

        // **A faixa de cor é decidida aqui, e não no encoder.** Ver `medirFormato`.
        //
        // `420v` só é pedido se estiver disponível; pedir um formato fora de
        // `availableVideoCVPixelFormatTypes` levanta exceção do Objective-C, que em Swift é queda
        // do app e não erro tratável.
        let disponiveis = saida.availableVideoPixelFormatTypes
        if disponiveis.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            saida.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ]
        } else {
            saida.videoSettings = nil
            Diagnostico.falha("APP CAMERA esta câmera não oferece 420v — o fluxo vai sair em faixa"
                + " completa. Disponíveis: "
                + disponiveis.map { CodificadorH264.nomeDoFormato($0) }.joined(separator: ","))
        }
        // "Empacota e solta" começa aqui: um quadro atrasado é um quadro velho, e vídeo ao vivo
        // não tem o que fazer com ele.
        saida.alwaysDiscardsLateVideoFrames = true
        saida.setSampleBufferDelegate(self, queue: fila)
        // **A sessão de áudio é nossa, não da captura** (R5 fase 2). Com o padrão (`true`), a
        // `AVCaptureSession` escolhe categoria e modo sozinha quando uma entrada de áudio entra — e
        // o que ela escolhe não é o som cru que o Pessoa Exemplo decidiu. Ver `abrirMicrofoneNaFila`. Sem
        // entrada de áudio, isto não muda nada: a câmera sem som não toca na sessão de áudio.
        sessao.automaticallyConfiguresApplicationAudioSession = false
        if !sessao.outputs.contains(saida) {
            guard sessao.canAddOutput(saida) else {
                return tr("A saída de vídeo da câmera não pôde ser criada.")
            }
            sessao.addOutput(saida)
        }

        if let conexao = saida.connection(with: .video) {
            // **A orientação é aplicada AQUI, onde a conexão nasce — e não só pelo retorno da
            // tela.** Até 07/09/2026 esta linha cravava `.portrait` e quem devia corrigir era o
            // `acompanharOrientacao` do `.onAppear`. Só que `comecar` monta a sessão em outra
            // fila: quando aquela chamada acontece, `saida.connection(with: .video)` ainda é
            // `nil`, ela volta calada, e como a geometria não muda depois (o aparelho já estava
            // deitado quando o app abriu) ninguém chama de novo. A conexão ficava no padrão para
            // sempre — medido no iPad A16 deitado, emitindo 1080x1920 com a cena de lado.
            //
            // Aplicar na origem tira a corrida: a conexão nasce já na orientação certa, e o
            // `acompanharOrientacao` passa a ser só o que o nome dele diz — acompanhar giros
            // depois disso.
            aplicarOrientacaoAtual(em: conexao)
            // O fluxo que sai **não** é espelhado, mesmo na câmera frontal: quem olha do outro
            // lado está vendo a pessoa, e não o espelho dela. A pré-visualização é espelhada por
            // conta própria pelo `AVCaptureVideoPreviewLayer`, que é o comportamento que a pessoa
            // espera de si mesma na tela.
            if conexao.isVideoMirroringSupported {
                conexao.automaticallyAdjustsVideoMirroring = false
                conexao.isVideoMirrored = false
            }
        }

        let nativo = CMFormatDescriptionGetMediaSubType(aparelho.activeFormat.formatDescription)
        let dimensao = CMVideoFormatDescriptionGetDimensions(aparelho.activeFormat.formatDescription)
        Diagnostico.nota("APP CAMERA captura montada"
            + " tipo=\(aparelho.deviceType.rawValue)"
            + " preset=\(sessao.sessionPreset.rawValue)"
            + " formato_nativo=\(CodificadorH264.nomeDoFormato(nativo))"
            + " dimensao_nativa=\(dimensao.width)x\(dimensao.height)"
            + " fps_max=\(String(format: "%.1f", 1 / CMTimeGetSeconds(aparelho.activeVideoMinFrameDuration)))")
        return nil
    }

    /// Teto de 30 quadros por segundo, no aparelho e não num contador nosso.
    ///
    /// `contrato-sidecar.md` é explícito: entregar **menos** que o pedido é legítimo, entregar
    /// **mais** é sempre defeito — e o defeito já aconteceu neste projeto. A captura do Android
    /// entregava 67 quadros por segundo com alvo de 30, a fila do encoder entupia e a latência
    /// ia a 251 ms no A07, com o `.h264` perfeito e o `ffprobe` aprovando.
    ///
    /// Só o **mínimo** de duração é fixado, e não o máximo: fixar os dois desligaria a extensão
    /// automática de exposição em pouca luz, e a imagem sairia escura para economizar um quadro
    /// que ninguém pediu.
    /// Escolhe o `activeFormat` que atende geometria **e** taxa, quando o preset não atende.
    ///
    /// A mesma regra pura do cardápio: cobre o alvo e faz a taxa; prefere a menor área suficiente,
    /// reduzindo no encoder quando preciso. Um formato 4K60 pode servir a 1080p/2K60, sem escolher
    /// 720p60 e anunciar um tamanho que a captura não entregou.
    ///
    /// **Não força nada.** Se nenhum formato tiver a taxa, o preset já escolhido continua valendo
    /// e `limitarTaxa` cai para o que o formato dá — que é o comportamento certo e o que o
    /// relato de 1 Hz vai mostrar.
    private func escolherFormato(para aparelho: AVCaptureDevice, alvo: Resolucao, fps: Int) {
        guard let melhor = TetosDaCamera.formato(em: aparelho, alvo: alvo, fps: fps) else {
            Diagnostico.nota("APP CAMERA formato: nenhum com \(fps) fps cobrindo"
                + " \(alvo.teto.maior)x\(alvo.teto.menor) — fica o preset")
            return
        }
        guard (try? aparelho.lockForConfiguration()) != nil else { return }
        aparelho.activeFormat = melhor
        aparelho.unlockForConfiguration()
        // O preset perde a vez quando o app escolhe o formato; dizê-lo explicitamente evita que
        // uma reconfiguração posterior da sessão o reimponha.
        sessao.sessionPreset = .inputPriority
        let d = CMVideoFormatDescriptionGetDimensions(melhor.formatDescription)
        Diagnostico.nota("APP CAMERA formato escolhido: \(d.width)x\(d.height)"
            + " faixas=\(melhor.videoSupportedFrameRateRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" })"
            + " (cobre \(alvo.rotulo) a \(fps) fps)")
    }

    /// **O preset do cardápio** (o caminho comum, e a queda da melhor imagem). Com a entrada já na
    /// sessão: cada `canSetSessionPreset` é sobre esta câmera. Devolve o preset aplicado.
    ///
    /// 1920x1080 é o teto que o `PERFIL_H264` do SDP comporta: `profile-level-id=42e028`,
    /// baseline **nível 4.0**. Era 3.1 até `07a92b8` (01/09/2026), e sob 3.1 o teto era mesmo
    /// 1280x720 — que é o que o preset daqui pedia, com um comentário que citava o nível velho.
    ///
    /// **O mesmo commit passou por este arquivo** e subiu o teto do *encoder* (`destino(...,
    /// tetoMaior: 1920, tetoMenor: 1080)`, hoje em `EmissorDeCamera`) sem subir a *captura* junto. As
    /// duas metades do arquivo discordaram por seis dias, e a câmera do iOS emitiu 720p num
    /// caminho que já sabia receber 1080p.
    ///
    /// Pedir o preset certo na captura evita reescalonamento — e reescalonar do jeito errado
    /// custou 30 MB contra 0,1 MB neste projeto. O `canSetSessionPreset` não é cerimônia: o
    /// conjunto de presets varia por aparelho e por câmera, e atribuir um preset não suportado
    /// é comportamento indefinido em vez de erro.
    ///
    /// A queda é para 720p **antes** de `.high`, e a ordem importa: `.high` é o que o aparelho
    /// achar melhor, sem teto declarado, então ele pode passar do nível que anunciamos. Um
    /// aparelho que recuse 1080p tem de cair num tamanho que o SDP comporta, não num "o que der".
    /// Por isso a lista começa no preset do cardápio e desce, e `.high` é o último recurso.
    @discardableResult
    private func aplicarPresetDoCardapio() -> AVCaptureSession.Preset? {
        let plano = TetosDaCamera.estado(cameraID: entrada?.device.uniqueID)
        let resolucao = TetosDaCamera.resolucao(para: plano, preferida: Resolucao.escolhida)
        let candidatos: [AVCaptureSession.Preset] =
            [resolucao.preset, .hd1920x1080, .hd1280x720, .high]
        for p in candidatos where sessao.canSetSessionPreset(p) {
            sessao.sessionPreset = p
            return p
        }
        return nil
    }

    /// Aplica a melhor imagem **desta** câmera (`EscolhaDaMelhorImagem`) por `activeFormat` e
    /// `.inputPriority`. Devolve `false` sem mexer em nada que o cardápio não desfaça quando não há
    /// formato que sirva ou a câmera não aceita a configuração — e quem chama cai no cardápio.
    /// Chamado dentro do `beginConfiguration`, com a entrada já na sessão.
    private func aplicarMelhorImagem(em aparelho: AVCaptureDevice) -> Bool {
        let formatos = aparelho.formats
        let oferecidos = formatos.map { f -> FormatoOferecido in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return FormatoOferecido(
                largura: Int(d.width), altura: Int(d.height),
                subtipo: CMFormatDescriptionGetMediaSubType(f.formatDescription),
                faixas: f.videoSupportedFrameRateRanges.map {
                    FormatoOferecido.Faixa(minima: $0.minFrameRate, maxima: $0.maxFrameRate)
                },
                binned: f.isVideoBinned)
        }
        let lado: String
        switch aparelho.position {
        case .front: lado = "frontal"
        case .back: lado = "traseira"
        default: lado = "sem posição"
        }
        guard let escolha = EscolhaDaMelhorImagem.escolherComQueda(oferecidos, fps: Resolucao.quadros) else {
            let taxas = Resolucao.quadros > 30 ? "\(Resolucao.quadros) nem a 30" : "30"
            Diagnostico.nota("APP CAMERA melhor imagem: nenhum formato 720p/1080p/4K 420v/420f a"
                + " \(taxas) fps (\(lado), \(formatos.count) formatos) — fica o cardápio")
            return false
        }
        let formato = formatos[escolha.indice]
        do {
            try aparelho.lockForConfiguration()
        } catch {
            Diagnostico.nota("APP CAMERA melhor imagem: a câmera não liberou a configuração"
                + " (\(SanitizacaoDoLog.erro(error))) — fica o cardápio")
            return false
        }
        aparelho.activeFormat = formato
        aparelho.unlockForConfiguration()
        // Conferir no aparelho, e não no retorno: se a câmera não ficou com o formato, o cardápio
        // abaixo escolhe o preset (e o preset substitui qualquer formato que tenha ficado).
        guard aparelho.activeFormat == formato else {
            Diagnostico.nota("APP CAMERA melhor imagem: a câmera não ficou com o formato escolhido"
                + " — fica o cardápio")
            return false
        }
        // O preset perde a vez quando o app escolhe o formato; dizê-lo explicitamente evita que
        // uma reconfiguração posterior da sessão o reimponha.
        if sessao.canSetSessionPreset(.inputPriority) { sessao.sessionPreset = .inputPriority }
        let o = oferecidos[escolha.indice]
        Diagnostico.nota("APP CAMERA melhor imagem: \(o.largura)x\(o.altura) \(o.nomeDoSubtipo)"
            + " a \(escolha.fps) fps (\(lado))\(o.binned ? " binned" : "")"
            + " faixas=\(o.faixas.map { "\(Int($0.minima))-\(Int($0.maxima))" })"
            + " de \(formatos.count) formatos")
        return true
    }

    /// O aparelho cuja taxa precisa ser fixada **depois** do `commitConfiguration`.
    private var aparelhoParaTaxa: AVCaptureDevice?

    /// Fixa a taxa no aparelho, e **só depois de a configuração da sessão estar comitada**.
    ///
    /// **A ordem é a correção de 07/09/2026, e o defeito era invisível de propósito.** A chamada
    /// ficava dentro de `montarCaptura`, entre o `beginConfiguration` e o `commitConfiguration`
    /// do `defer` — e trocar o preset da sessão **redefine** `activeVideoMinFrameDuration`. Tudo
    /// que `limitarTaxa` escrevia era apagado no commit.
    ///
    /// Ninguém percebeu porque ela sempre escrevia **30**, que já é o padrão: escrever o valor que
    /// já está lá é indistinguível de funcionar. O cardápio expôs isso na primeira vez que alguém
    /// pediu 60 — o iPad continuou a 29,998 fps, medido pelo `FigCaptureFrameCounter` da própria
    /// Apple.
    func fixarTaxaDepoisDoCommit() {
        guard let aparelho = aparelhoParaTaxa else { return }
        aparelhoParaTaxa = nil
        limitarTaxa(de: aparelho)
    }

    private func limitarTaxa(de aparelho: AVCaptureDevice) {
        // **A taxa vem do cardápio**, e o formato ativo tem a última palavra. O teto é por
        // *formato*, e não por câmera: no S24 o Android mostrou que 1080p faz 60 e 4K faz 30 no
        // mesmo sensor, e aqui vale a mesma coisa — `videoSupportedFrameRateRanges` é do
        // `activeFormat`, que já foi escolhido pelo preset. Pedir 60 num formato que não faz 60
        // não vira erro: vira o que o formato dá, e o log diz qual foi.
        let plano = TetosDaCamera.estado(cameraID: aparelho.uniqueID)
        let pedido = Double(melhorImagemAplicada ? Resolucao.quadros : (plano.fpsEfetivo ?? Resolucao.quadros))
        let faixas = aparelho.activeFormat.videoSupportedFrameRateRanges
        let cabe = faixas.contains { $0.maxFrameRate >= pedido && $0.minFrameRate <= pedido }
        let efetivo = cabe ? pedido : (faixas.map(\.maxFrameRate).max() ?? 30)
        Diagnostico.nota("APP CAMERA taxa: pedida=\(Int(pedido)) efetiva=\(Int(efetivo))"
            + " faixas=\(faixas.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" })")
        guard (try? aparelho.lockForConfiguration()) != nil else { return }
        aparelho.activeVideoMinFrameDuration =
            CMTime(value: 1, timescale: CMTimeScale(max(1, Int(efetivo))))
        // **O piso, para o automático clarear a imagem em pouca luz** (§3.1, decisão de 06/10): o
        // quadro pode durar até 1/piso, e a exposição manual não é afetada (o obturador dela é cortado
        // em 1/fps). O padrão do sistema fica no diário: é o "antes" que não foi medido no iOS.
        let padrao = CMTimeGetSeconds(aparelho.activeVideoMaxFrameDuration)
        let piso = RegrasDosControles.pisoDoAutomatico(
            faixas: faixas.map { (minimo: $0.minFrameRate, maximo: $0.maxFrameRate) }, fps: efetivo)
        aparelho.activeVideoMaxFrameDuration = CMTime(value: 1000, timescale: CMTimeScale(max(1, (piso * 1000).rounded())))
        aparelho.unlockForConfiguration()
        // O teto de taxa configurado no formato ativo alimenta também o encoder; não se configura
        // 60 quando esta câmera recuou para 30. Não é a medição dos quadros entregues: pouca luz
        // pode baixar a taxa. Publicado antes de startRunning e sob a trava dos contadores.
        let duracao = CMTimeGetSeconds(aparelho.activeVideoMinFrameDuration)
        if duracao.isFinite && duracao > 0 {
            travaDosContadores.lock()
            _quadrosDoEspelhamento = max(1, Int((1 / duracao).rounded()))
            travaDosContadores.unlock()
        }
        Diagnostico.nota("APP CAMERA piso do automático: \(String(format: "%.1f", piso)) fps"
            + " (padrão do sistema era \(padrao.isFinite && padrao > 0 ? String(format: "%.1f", 1 / padrao) : "?") fps)")
    }

    // --- interrupções ---------------------------------------------------------------------------

    private func observarInterrupcoes() {
        let centro = NotificationCenter.default
        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: sessao, queue: .main
        ) { [weak self] aviso in self?.aoInterromper(aviso) })

        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: sessao, queue: .main
        ) { [weak self] _ in self?.aoRetomar() })

        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: sessao, queue: .main
        ) { [weak self] aviso in
            let erro = aviso.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Diagnostico.falha("APP CAMERA erro de execução da captura: \(erro?.code ?? 0)")
            guard let self else { return }
            if self.recuarDaMelhorImagem() { return }
            self.interrupcao = tr("A câmera parou por um erro do sistema. Toque em Parar e comece "
                + "de novo.")
        })
    }

    /// **A melhor imagem também não derruba a câmera depois do `startRunning`.** As falhas
    /// síncronas (nenhum formato serve, a câmera não libera a configuração, o formato não pega) já
    /// caem no cardápio dentro de `montarCaptura`; um formato que a câmera aceita e depois não
    /// consegue sustentar só aparece aqui, como `AVCaptureSessionRuntimeError`. Com a melhor
    /// imagem aplicada, a captura é reconfigurada **uma vez** com o preset do cardápio (1080p no
    /// padrão) e posta para rodar de novo, na `fila`, em ordem com `ligar` e `pararDeRodar`.
    /// Devolve `true` quando assumiu o erro. Na principal.
    private func recuarDaMelhorImagem() -> Bool {
        guard melhorImagemAplicada, !recuoDaMelhorImagemFeito, let aparelho = entrada?.device else {
            return false
        }
        recuoDaMelhorImagemFeito = true
        melhorImagemAplicada = false
        // O recuo põe o cardápio: a captura reduzida pelos degraus não tem mais o que devolver.
        capturaReduzida = false
        Diagnostico.nota("APP CAMERA melhor imagem: erro de execução com o formato escolhido —"
            + " remontando uma vez com o cardápio (\(Resolucao.escolhida.rotulo) a \(Resolucao.quadros) fps)")
        fila.async { [weak self] in
            guard let self, !self.fechado else { return }
            self.formatoCheio = nil; self.presetCheio = nil
            self.sessao.beginConfiguration()
            // O preset substitui o formato escolhido à mão (a sessão sai de `.inputPriority`).
            let p = self.aplicarPresetDoCardapio()
            let plano = TetosDaCamera.estado(cameraID: aparelho.uniqueID)
            self.escolherFormato(para: aparelho,
                                 alvo: TetosDaCamera.resolucao(para: plano, preferida: Resolucao.escolhida),
                                 fps: plano.fpsEfetivo ?? Resolucao.quadros)
            self.sessao.commitConfiguration()
            // Depois do commit, pelo mesmo motivo de `fixarTaxaDepoisDoCommit`.
            self.limitarTaxa(de: aparelho)
            // R9 (§2.2): o recuo troca o formato; os ajustes voltam depois da taxa.
            self.aplicarAjustesNaFila(reaplicando: true, motivo: "recuo da melhor imagem")
            let d = CMVideoFormatDescriptionGetDimensions(aparelho.activeFormat.formatDescription)
            Diagnostico.nota("APP CAMERA recuo para o cardápio: preset=\(p?.rawValue ?? "nenhum")"
                + " dimensao_nativa=\(d.width)x\(d.height) rodava=\(self.sessao.isRunning ? "sim" : "não")")
            self.esquecerRelogioDosQuadros()
            if self.noSegundoPlano { self.ligarAoVoltar = true }
            else if !self.sessao.isRunning { self.sessao.startRunning() }
        }
        return true
    }

    /// Ligação telefônica, app indo para segundo plano, outro app tomando a câmera. O iOS
    /// interrompe a sessão, e **não há o que fazer além de dizer à pessoa** — é comportamento
    /// padrão da plataforma, documentado como esperado, e tentar contornar seria trabalhar contra
    /// ela.
    private func aoInterromper(_ aviso: Notification) {
        let codigo = (aviso.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let razao = codigo.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
        interrupcao = DonoDaCaptura.textoDaInterrupcao(razao)
        interrompidaDesde = ProcessInfo.processInfo.systemUptime
        entregando = false
        fila.async { [weak self] in self?.avisouEntrega = false }
        DonoDaCaptura.dizerNosDois("APP CAMERA interrompida razao=\(codigo ?? -1)")
        // O microfone tem sessão própria (§8.5), e esta razão não deveria mais chegar à da câmera
        // por causa dele; se chegar, a volta não pode depender do microfone: ele sai, e o botão
        // diz por quê.
        if razao == .audioDeviceInUseByAnotherClient, microfone == .ligado || microfone == .pedindo {
            soltarMicrofonePorInterrupcao("a captura foi interrompida pelo áudio")
        }
    }

    static func textoDaInterrupcao(_ razao: AVCaptureSession.InterruptionReason?) -> String {
        switch razao {
        case .videoDeviceNotAvailableInBackground:
            return tr("O Quall saiu do primeiro plano, e o iOS desliga a câmera de quem não está na "
                + "tela. Isso é comportamento padrão do iPhone, não é falha do Quall: volte para "
                + "o app e a imagem retorna sozinha. Enquanto isso, o outro aparelho fica sem "
                + "receber.")
        case .videoDeviceInUseByAnotherClient:
            return tr("Outro app tomou a câmera. Feche-o e a imagem volta sozinha.")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return tr("Com dois apps dividindo a tela, o iOS não entrega a câmera. Volte para tela "
                + "cheia e a imagem retorna.")
        case .videoDeviceNotAvailableDueToSystemPressure:
            return tr("O iPhone esquentou e o sistema desligou a câmera. Ela volta quando esfriar.")
        case .audioDeviceInUseByAnotherClient:
            // Com o microfone ligado, a interrupção é da sessão inteira, imagem junto: o microfone
            // é desligado (`aoInterromper`) para a imagem poder voltar sem ele.
            return tr("Outro app (ou uma ligação) tomou o áudio, e o iOS parou a câmera junto. O "
                + "microfone foi desligado; a imagem volta sozinha, e o microfone liga de novo no botão.")
        default:
            return tr("A câmera foi interrompida pelo sistema. Ela volta sozinha quando der.")
        }
    }

    /// Muda a orientação **na conexão de captura**: o quadro chega já girado, sem custo nosso, e
    /// a troca de dimensão faz o encoder ser reconstruído no formato certo.
    /// O ângulo de rotação, em graus, para uma orientação **de interface**.
    ///
    /// Esta é a tabela **padrão** para `UIInterfaceOrientation`: `.portrait` → 90,
    /// `.landscapeRight` → 0, `.landscapeLeft` → 180, `.portraitUpsideDown` → 270.
    ///
    /// # Ela foi invertida por engano em 07/09/2026, e a inversão trocou o erro de câmera
    ///
    /// Com a tabela padrão, o usuário relatou a câmera **frontal** de ponta-cabeça. Eu inverti as
    /// duas paisagens, a frontal ficou certa, e algumas horas depois a **traseira** apareceu de
    /// ponta-cabeça — com `angulo=180` e `interface=3` no relato do próprio app, ou seja, ela
    /// queria os 0 que a tabela padrão dá.
    ///
    /// **Uma inversão global não pode consertar uma câmera e quebrar a outra**: se as duas
    /// precisam de ângulos diferentes para a mesma orientação de interface, a diferença é de
    /// câmera e não de tabela, e o lugar de tratá-la é onde se sabe qual câmera é.
    ///
    /// A tabela volta ao padrão. Se a frontal voltar a sair de ponta-cabeça com ela, o suspeito
    /// não é este `switch` — é o espelhamento (`isVideoMirrored`), que a frontal tem e a traseira
    /// não, e que o `montarCaptura` desliga de propósito. **Não provado**, e é a próxima medida.
    static func anguloPara(_ orientacao: UIInterfaceOrientation) -> CGFloat {
        switch orientacao {
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    /// A orientação da interface **agora**, lida da cena, para aplicar na conexão recém-criada.
    ///
    /// Existe porque `montarCaptura` roda fora da `View` e não recebe a orientação de ninguém.
    /// Ler a cena aqui é o mesmo que o `TelaDaCamera` faz — e pela mesma razão registrada lá: a
    /// cena diz o que está **desenhado**, enquanto `UIDevice.current.orientation` inclui
    /// `faceUp`/`faceDown` e produziria um giro que ninguém pediu.
    func aplicarOrientacaoAtual(em conexao: AVCaptureConnection) {
        // Na montagem fora da principal, a interface lida antes (a cena é da principal).
        if !Thread.isMainThread {
            // No iOS 17+ quem sabe o ângulo é o coordenador, que nasce na volta à principal: a tabela
            // erra a frontal do iPad deitado (revisão de 27/09, M2). A volta aplica.
            if #available(iOS 17.0, *) { return }
            aplicar(interfaceParaMontar ?? .portrait, em: conexao)
            return
        }
        let cena = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        aplicar(cena?.interfaceOrientation ?? .portrait, em: conexao)
    }

    func acompanharOrientacao(_ orientacao: UIInterfaceOrientation) {
        // Com a montagem ainda na `fila` (`montarSemTravar`), a principal não mexe nas conexões: a
        // volta dela aplica a orientação (revisão de 27/09, M1).
        guard montado else { return }
        if anguloCongelado {
            // Uma linha por gravação, e não por giro: a interface está travada, e o que chega aqui é
            // o sensor ou um leiaute.
            if !giroSeguradoRelatado {
                giroSeguradoRelatado = true
                Diagnostico.nota("APP CAMERA angulo: gravando, o giro não chega à conexão"
                    + " (interface=\(orientacao.rawValue))")
            }
            return
        }
        guard let conexao = saida.connection(with: .video) else {
            Diagnostico.nota("APP CAMERA angulo: sem conexao de video ainda"
                + " (interface=\(orientacao.rawValue))")
            return
        }
        aplicar(orientacao, em: conexao)
    }

    /// Escreve a orientação numa conexão que já existe. Separado de [`acompanharOrientacao`]
    /// porque `montarCaptura` precisa do mesmo trabalho sobre a conexão que acabou de criar,
    /// **sem** passar pela busca que ali ainda devolveria `nil`.
    /// O coordenador de rotação da Apple, quando existe. Ver [`aplicar`].
    private var coordenador: Any?

    /// A camada de prévia, para orientá-la **no laço de 1 Hz** e não num retorno de leiaute.
    ///
    /// `layoutSubviews` só é chamado quando o tamanho da vista muda — uma vez, no arranque. Em
    /// 07/09/2026 isso me custou três capturas de syslog vazias seguidas: o registro estava lá, o
    /// gatilho é que não voltava a disparar, e eu li a ausência como "não é essa a view". O
    /// supervisor de 1 Hz roda sempre, e é onde as coisas que precisam ser verdade
    /// **continuamente** pertencem.
    weak var camadaDePrevia: AVCaptureVideoPreviewLayer? {
        didSet {
            // **O coordenador precisa da camada, e é por isso que ele é refeito aqui.**
            //
            // `AVCaptureDevice.RotationCoordinator(device:previewLayer:)` recebe a camada porque
            // `videoRotationAngleForHorizonLevelPreview` **depende dela** — o ângulo de prévia é o
            // que põe o horizonte de pé *naquela camada*, não em abstrato. Criado com `nil`, ele
            // devolve um valor que não descreve nada.
            //
            // Medido em 07/09/2026, com o coordenador criado com `nil`: captura em **180** (e o
            // OBS correto), prévia em **0** — exatos 180° de diferença, e a prévia de
            // ponta-cabeça. Eu tinha passado `nil` e depois usado justamente a propriedade que
            // precisa da camada.
            if camadaDePrevia !== oldValue, let ap = aparelhoDoCoordenador {
                prepararCoordenador(para: ap)
            }
        }
    }

    /// O aparelho com que o coordenador foi montado, para poder refazê-lo quando a camada chega.
    private var aparelhoDoCoordenador: AVCaptureDevice?

    /// Cria (ou recria) o coordenador para o aparelho em uso. Chamado quando a câmera é montada.
    func prepararCoordenador(para aparelho: AVCaptureDevice) {
        aparelhoDoCoordenador = aparelho
        if #available(iOS 17.0, *) {
            // A camada entra quando existe: ver o `didSet` de `camadaDePrevia`, que refaz isto.
            coordenador = AVCaptureDevice.RotationCoordinator(device: aparelho,
                                                             previewLayer: camadaDePrevia)
        }
    }

    /// O ângulo da **prévia**, que não é o mesmo da captura.
    ///
    /// **A Apple expõe dois, e a diferença entre eles é literalmente este defeito.**
    /// `videoRotationAngleForHorizonLevelCapture` orienta o que **sai** — o encoder, o que chega
    /// ao OBS. `videoRotationAngleForHorizonLevelPreview` orienta o que a pessoa **vê na mão**.
    /// Em 07/09/2026 o iPad A16 mostrou os dois divergindo na câmera frontal: o fluxo chegou
    /// certo ao OBS e a prévia ficou de ponta-cabeça, e eu passei três tentativas procurando na
    /// conexão errada porque "está de ponta-cabeça" descreve as duas do mesmo jeito.
    ///
    /// A pergunta que teria encurtado isso é uma: **de ponta-cabeça onde?**
    var anguloDaPrevia: CGFloat {
        if #available(iOS 17.0, *), let c = coordenador as? AVCaptureDevice.RotationCoordinator {
            return c.videoRotationAngleForHorizonLevelPreview
        }
        let cena = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return DonoDaCaptura.anguloPara(cena?.interfaceOrientation ?? .portrait)
    }

    private func aplicar(_ orientacao: UIInterfaceOrientation, em conexao: AVCaptureConnection) {
        // **Quem sabe o ângulo é o aparelho, e a Apple expõe isso desde o iOS 17.**
        //
        // `AVCaptureDevice.RotationCoordinator` devolve o ângulo correto **para aquela câmera**,
        // e é a peça que uma tabela de orientação não pode substituir: em 07/09/2026 a traseira e
        // a frontal do iPad A16 pediram ângulos **diferentes para a mesma orientação de
        // interface** — com a tabela padrão a traseira sai certa e a frontal de ponta-cabeça, e
        // invertendo a tabela troca-se qual das duas quebra.
        //
        // A causa provável é o hardware: nos iPads recentes a câmera frontal mudou para a borda
        // **longa**, para uso em paisagem, e o sensor está montado a 90° do que estava. Nenhuma
        // tabela escrita por mim vai saber disso de cada aparelho que existe; o coordenador sabe,
        // porque é o sistema quem monta a câmera.
        //
        // Seis tentativas de rotação neste dia, todas propondo tabela. A sétima pergunta.
        if #available(iOS 17.0, *), let c = coordenador as? AVCaptureDevice.RotationCoordinator {
            let angulo = c.videoRotationAngleForHorizonLevelCapture
            Diagnostico.nota("APP CAMERA angulo do coordenador: \(Int(angulo))"
                + " (interface=\(orientacao.rawValue))")
            guard conexao.isVideoRotationAngleSupported(angulo),
                  conexao.videoRotationAngle != angulo else { return }
            conexao.videoRotationAngle = angulo
            return
        }
        aplicarPelaTabela(orientacao, em: conexao)
    }

    /// O caminho de antes do iOS 17, mantido para o iPhone 7 (15.8) e o iPhone X (16.7).
    ///
    /// A tabela é a padrão e está **certa para esses aparelhos**: eles são anteriores à mudança
    /// da câmera frontal para a borda longa, e neles as duas câmeras concordam.
    private func aplicarPelaTabela(_ orientacao: UIInterfaceOrientation, em conexao: AVCaptureConnection) {
        // **Duas APIs, e a velha some nos aparelhos novos.** `videoOrientation` foi substituída
        // por `videoRotationAngle` no iOS 17, e num aparelho novo `isVideoOrientationSupported`
        // pode devolver `false` — e devolvia: até 07/09/2026 este método tinha um `guard` nessa
        // propriedade e **desistia em silêncio**. O sintoma era exato e enganoso: o iPhone 7
        // (iOS 15) e o iPhone X (iOS 16) giravam, e o iPad A16 (iOS 26) espelhava sempre em pé.
        // Parecia coisa do iPad e era coisa da versão.
        //
        // O ângulo é medido em graus **no sentido anti-horário**, e o mapa não é o mesmo da
        // orientação: `.landscapeLeft` da interface quer 180, `.landscapeRight` quer 0. Escrever
        // os dois lados separados é mais longo e é a única forma de não errar em silêncio de novo.
        if #available(iOS 17.0, *) {
            let angulo = DonoDaCaptura.anguloPara(orientacao)
            // **Todo ramo registra, inclusive o que não faz nada.** Em 07/09/2026 este método
            // tinha três `guard` mudos e um `Diagnostico.nota` no fim: quando ele desistia — e ele
            // desistia — o syslog não trazia linha nenhuma, e a ausência foi lida como "não foi
            // chamado". Custou quatro consertos propostos sobre suposição.
            let suportado = conexao.isVideoRotationAngleSupported(angulo)
            Diagnostico.nota("APP CAMERA angulo: pedido=\(angulo) atual=\(conexao.videoRotationAngle)"
                + " suportado=\(suportado) interface=\(orientacao.rawValue)")
            guard suportado else { return }
            guard conexao.videoRotationAngle != angulo else { return }
            conexao.videoRotationAngle = angulo
            Diagnostico.nota("APP CAMERA angulo escrito: \(angulo)")
            return
        }

        guard conexao.isVideoOrientationSupported else {
            Diagnostico.nota("APP CAMERA orientacao: videoOrientation nao suportada")
            return
        }
        let nova: AVCaptureVideoOrientation
        switch orientacao {
        case .landscapeLeft: nova = .landscapeLeft
        case .landscapeRight: nova = .landscapeRight
        case .portraitUpsideDown: nova = .portraitUpsideDown
        default: nova = .portrait
        }
        guard conexao.videoOrientation != nova else { return }
        conexao.videoOrientation = nova
        Diagnostico.nota("APP CAMERA orientacao -> \(nova.rawValue)")
    }

    /// `systemUptime` do começo da interrupção de agora (0 sem interrupção). Só na principal.
    private(set) var interrompidaDesde: Double = 0

    private func aoRetomar() {
        interrupcao = ""
        if interrompidaDesde > 0 {
            DonoDaCaptura.dizerNosDois(String(format: "APP CAMERA interrupção terminou depois de %.0f ms",
                                              (ProcessInfo.processInfo.systemUptime - interrompidaDesde) * 1000))
        }
        interrompidaDesde = 0
        // A sessão pode ter voltado com outro relógio: relido no próximo quadro (revisão de 27/09, M1).
        esquecerRelogioDosQuadros()
        // R9 (§2.2): o fim de interrupção — a do iOS e a volta do segundo plano
        // (`retomarDoSegundoPlano` chama esta função). A trava sobrevive a tudo o que reabre a câmera.
        fila.async { [weak self] in self?.aplicarAjustesNaFila(reaplicando: true, motivo: "a captura voltou") }
        // Na volta, o receptor está com a última imagem congelada — ou com nada, se o app ficou
        // fora tempo suficiente para o transporte cair.
        assinante?.capturaRetomada()
        gravador?.capturaRetomada()
        Diagnostico.nota("APP CAMERA retomada — IDR exigido")
    }

    /// **As testemunhas de que a câmera não reabriu.** A prova da fase 1 do R5 é "a prévia não
    /// pisca numa conexão, numa queda e numa volta" (`docs/teleprompter-com-camera.md` §8), e a
    /// prévia só pisca se a sessão parar ou se reconfigurar. Estas duas linhas dizem quando ela
    /// começou e parou de rodar; entre elas, com a transmissão se pendurando e se soltando, não pode
    /// haver outra.
    private func observarRodando() {
        let centro = NotificationCenter.default
        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionDidStartRunning, object: sessao, queue: nil
        ) { _ in Diagnostico.nota("APP CAMERA dono: a captura começou a rodar") })
        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionDidStopRunning, object: sessao, queue: nil
        ) { _ in Diagnostico.nota("APP CAMERA dono: a captura parou de rodar") })
    }

    // --- o espelho da prévia --------------------------------------------------------------------

    /// Aplica `espelharPrevia` na conexão da camada. Chamado quando o ajuste muda, na montagem, no
    /// leiaute da vista e a cada relato do supervisor (10 s) — a conexão da camada nasce depois da
    /// vista, e um ajuste escrito antes dela voltaria calado (a armadilha de `VistaDePreVisualizacao`).
    ///
    /// **Só na principal**: a camada é da interface.
    ///
    /// O padrão da frontal já é espelhado (`automaticallyAdjustsVideoMirroring`), então
    /// "espelhada=true" sozinho não prova que este código passou por aqui. A prova é
    /// `automatico=false` na linha de 10 s (só este método o desliga) e a linha "espelho aplicado",
    /// que sai **uma vez por conexão**, com o valor lido de volta.
    func aplicarEspelhoNaPrevia() {
        guard montado else { return }
        guard let quer = espelharPrevia else { return }
        guard let cx = camadaDePrevia?.connection else { return }
        guard cx.isVideoMirroringSupported else {
            if conexaoDoEspelhoRelatada !== cx {
                conexaoDoEspelhoRelatada = cx
                Diagnostico.nota("APP PREVIA espelho: a conexão da camada NÃO aceita espelho (pedido=\(quer ? "ligado" : "desligado"))")
            }
            return
        }
        if cx.automaticallyAdjustsVideoMirroring { cx.automaticallyAdjustsVideoMirroring = false }
        let mudou = cx.isVideoMirrored != quer
        if mudou { cx.isVideoMirrored = quer }
        if mudou || conexaoDoEspelhoRelatada !== cx {
            conexaoDoEspelhoRelatada = cx
            Diagnostico.nota("APP PREVIA espelho aplicado: pedido=\(quer ? "ligado" : "desligado")"
                + " espelhada=\(cx.isVideoMirrored) automatico=\(cx.automaticallyAdjustsVideoMirroring)"
                + (mudou ? "" : " (já estava assim)"))
        }
    }

    /// A conexão da camada sobre a qual o espelho já foi relatado: a linha sai uma vez por
    /// conexão, e de novo a cada mudança.
    private weak var conexaoDoEspelhoRelatada: AVCaptureConnection?

    /// **O estado da prévia, a cada 10 s, na principal.**
    ///
    /// Até 24/09 isto rodava na fila do supervisor, e o `else` de um `if #available(iOS 17.0, *)`
    /// dizia "sem camada ou sem conexão" — no iPhone X (iOS 16.7) **sempre**, com a camada e a
    /// conexão de pé (a mesma linha imprimia `camada=ok espelhada=true`, lidas da conexão que ela
    /// dizia não existir). A linha mentia pela versão do sistema, não pela prévia. Agora cada
    /// ausência tem a sua frase, e a versão sem ângulo diz que é isso.
    ///
    /// `escondida=` vai junto: o "esconder a prévia" deixa testemunha contínua, e não só a linha
    /// da transição (que a prova de 24/09 não achou no diário).
    private func relatarPrevia() {
        aplicarEspelhoNaPrevia()
        // A prévia pausada pelos degraus continua pausada numa camada nova (revisão de 27/09, M5).
        if let cx = camadaDePrevia?.connection, cx.isEnabled == previaPausada { cx.isEnabled = !previaPausada }
        guard let camada = camadaDePrevia else {
            Diagnostico.nota("APP PREVIA: sem camada (nenhuma vista de prévia montada)")
            return
        }
        guard let cx = camada.connection else {
            Diagnostico.nota("APP PREVIA: camada sem conexão (a sessão ainda não ligou a câmera a ela)"
                + " escondida=\(camada.isHidden)")
            return
        }
        var angulo: String
        if #available(iOS 17.0, *) {
            let ap = anguloDaPrevia
            let ok = cx.isVideoRotationAngleSupported(ap)
            if ok && cx.videoRotationAngle != ap { cx.videoRotationAngle = ap }
            angulo = "pedido=\(Int(ap)) atual=\(Int(cx.videoRotationAngle)) suportado=\(ok)"
        } else {
            // Antes do iOS 17 não há ângulo: a orientação é escrita em `layoutSubviews`.
            angulo = "orientacao=\(cx.videoOrientation.rawValue) (iOS<17)"
        }
        let pedido = espelharPrevia.map { $0 ? "ligado" : "desligado" } ?? "automatico"
        Diagnostico.nota("APP PREVIA: \(angulo) espelho=\(pedido) espelhada=\(cx.isVideoMirrored)"
            + " automatico=\(cx.automaticallyAdjustsVideoMirroring) escondida=\(camada.isHidden)")
    }

    // --- supervisão de 1 Hz ---------------------------------------------------------------------

    private func subirSupervisao() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.supervisionar() }
        t.resume()
        relogio = t
    }

    /// De quantas voltas do supervisor sai um relato. 1 Hz × 10 = a cada dez segundos.
    private var voltasAteRelatar = 0

    /// Quadros que **entraram** da câmera. Ver `EmissorDeCamera.ajustarAoAparelho`, que o compara
    /// com os que saíram do encoder. `&+` porque contador de instrumento satura, não derruba processo.
    private let travaDosContadores = NSLock()
    private var _entraram: UInt64 = 0
    private var _entraramNoRelato: UInt64 = 0
    /// O maior intervalo entre dois quadros seguidos desde o último relato, em segundos de
    /// apresentação. É a testemunha de "a prévia não piscou": um ciclo da câmera abre um buraco de
    /// centenas de milissegundos aqui (o Android mediu 279 a 531 ms no `rebind_junto`).
    private var _ultimoPts: Double = -1
    private var _buracoMaior: Double = 0
    /// `systemUptime` do último quadro: a gravação confere que a câmera está entregando.
    private var _ultimoQuadroEm: Double = 0
    /// **O relógio dos PTS dos quadros** (o da sessão da câmera), lido no primeiro quadro com ela
    /// rodando: é contra ele que a idade de um quadro é medida (`idadeDoQuadro`, §8.12.1).
    private var _relogioDosQuadros: CMClock?
    /// A maior idade de um quadro **ao chegar aqui** (o relógio da câmera no `captureOutput` menos o
    /// PTS dele) desde o último relato: é a testemunha de "a captura entregou atrasado" (a primeira
    /// das três hipóteses do vídeo 2,7 s atrás do som no iPhone 7, 27/09).
    private var _idadeMaiorNaEntrega: Double = 0
    /// As medidas da entrega do microfone (§8.12.11), por janela de 10 s. Sob `travaDosContadores`.
    fileprivate var _idadeMaxNaChegadaDoSom: Double = 0
    fileprivate var _trabalhoMaxDoSom: Double = 0
    fileprivate var _trabalhoSomaDoSom: Double = 0
    fileprivate var _trabalhosDoSom = 0
    fileprivate var _rajadasDoSom = 0
    fileprivate var _ultimaChegadaDoSom: Double = 0
    /// O menor passo entre dois PTS seguidos do microfone (já convertidos) na janela: um passo abaixo de
    /// um buffer, ou negativo, é o relógio da conversão andando para trás (revisão de 27/09, B2).
    fileprivate var _menorPassoDeAudio: Double = .infinity

    /// A última `systemPressureState` relatada (só no supervisor).
    private var pressaoRelatada = ""
    /// **Os quadros que a própria captura jogou fora**, pelo motivo que ela dá
    /// (`kCMSampleBufferAttachmentKey_DroppedFrameReason`), desde o último relato. Separa "a fila da
    /// câmera atrasou" (`FrameWasLate`: quem recebe os quadros demorou — os dois encoders na mesma
    /// fila), "acabaram os buffers" (`OutOfBuffers`: alguém segura os pixel buffers do pool) e
    /// "descontinuidade" — o iPhone 7 perdeu ~10 % na captura em 27/09 e o relato não dizia por quê.
    private var _perdidosAtrasados: UInt64 = 0
    private var _perdidosSemBuffer: UInt64 = 0
    private var _perdidosOutros: UInt64 = 0
    /// O microfone, para o relato de 10 s (escritos na fila do áudio e no `didSet` do botão).
    private var _estadoDoMicrofone = "desligado"
    private var _buffersDeAudio: UInt64 = 0
    private var _amostrasDeAudio: UInt64 = 0
    private var _buffersDeAudioNoRelato: UInt64 = 0
    private var _ultimoPtsDeAudio: Double = -1
    private var _buracoMaiorDeAudio: Double = 0
    /// A janela do toque (`abrirJanelaDoToque`).
    private var _janelaDoToque = 0
    private var _janelaAberta = false
    private var _buracoDaJanela: Double = 0
    private var _quadrosDaJanela = 0
    private var _inicioDaJanela: CFAbsoluteTime = 0
    private var _fimDaAcaoDaJanela: CFAbsoluteTime = 0
    private var _sessaoDeAudioDaJanela: Double = -1
    private var _acaoDaJanela = ""

    /// Solta o relógio guardado dos quadros: o próximo quadro o relê da sessão.
    private func esquecerRelogioDosQuadros() {
        travaDosContadores.lock(); _relogioDosQuadros = nil; travaDosContadores.unlock()
    }

    /// **A idade de um quadro agora**, em segundos: o relógio da câmera menos o PTS dele. `nil` antes
    /// do primeiro quadro (sem relógio) ou com um PTS inválido. De qualquer thread.
    func idadeDoQuadro(_ pts: CMTime) -> Double? {
        travaDosContadores.lock()
        let r = _relogioDosQuadros
        travaDosContadores.unlock()
        guard let r, pts.isValid else { return nil }
        let d = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(r), pts))
        return d.isFinite ? d : nil
    }

    var quadrosQueEntraram: UInt64 {
        travaDosContadores.lock(); defer { travaDosContadores.unlock() }
        return _entraram
    }

    private var _quadrosDoEspelhamento = Resolucao.quadros
    var quadrosDoEspelhamento: Int {
        travaDosContadores.lock(); defer { travaDosContadores.unlock() }
        return _quadrosDoEspelhamento
    }

    private func supervisionar() {
        voltasAteRelatar -= 1
        guard voltasAteRelatar <= 0 else { return }
        voltasAteRelatar = 10
        // A prévia é orientada aqui, todo relato, e relatada junto — na principal, que é de quem
        // a camada é. Ver `camadaDePrevia` e `relatarPrevia`.
        naPrincipal { [weak self] in self?.relatarPrevia() }
        travaDosContadores.lock()
        let dEnt = _entraram &- _entraramNoRelato
        _entraramNoRelato = _entraram
        let buraco = _buracoMaior
        _buracoMaior = 0
        let idadeNaEntrega = _idadeMaiorNaEntrega
        _idadeMaiorNaEntrega = 0
        let perdidos = (_perdidosAtrasados, _perdidosSemBuffer, _perdidosOutros)
        _perdidosAtrasados = 0; _perdidosSemBuffer = 0; _perdidosOutros = 0
        travaDosContadores.unlock()
        Diagnostico.nota("APP CAMERA dono: camera=\(String(format: "%.1f", Double(dEnt) / 10)) fps"
            + " buraco_maior=\(String(format: "%.0f", buraco * 1000)) ms"
            + " idade_na_entrega_max=\(String(format: "%.0f", idadeNaEntrega * 1000)) ms"
            + " perdidos_na_captura=atrasado:\(perdidos.0),sem_buffer:\(perdidos.1),outro:\(perdidos.2)"
            + " termico=\(ProcessInfo.processInfo.thermalState.rawValue)"
            + " rodando=\(sessao.isRunning) assinante=\(assinante == nil ? "nenhum" : "pendurado")"
            + " gravador=\(gravador == nil ? "nenhum" : "pendurado")")
        relatarMicrofone()
        // O CPU por etapa (§8.12.16): o que come o aparelho quente, para a próxima medida decidir.
        if let cpu = MedidorDeCpu.relato() { Diagnostico.nota("APP CPU " + cpu) }
        guard let ap = entrada?.device else { return }
        // **A pressão do sistema sobre a câmera** (§8.12.1): é ela que diz se a câmera baixou a taxa
        // sozinha no calor. Não decide nada ainda; uma linha por troca, e o valor no relato.
        let p = ap.systemPressureState
        let pressao = "\(p.level.rawValue) fatores=\(p.factors.rawValue)"
        if pressao != pressaoRelatada {
            Diagnostico.nota("APP CAMERA pressão do sistema: \(pressaoRelatada.isEmpty ? "?" : pressaoRelatada) → \(pressao)"
                + " (fatores: 1 térmico, 2 pico de energia, 4 temperatura do módulo de profundidade)")
            pressaoRelatada = pressao
        }
        // R9 (§3.6, §5): o que a câmera diz ter usado, e a média de luma da janela (com a bandeira).
        Diagnostico.nota("APP CAMERA controles lido: " + AjustesNaCamera.linhaLida(ap))
        relatarLuma()
        let dur = ap.activeVideoMinFrameDuration
        let fpsEfetivo = dur.timescale > 0 && dur.value > 0
            ? Double(dur.timescale) / Double(dur.value) : 0
        let dim = CMVideoFormatDescriptionGetDimensions(ap.activeFormat.formatDescription)
        // O ângulo entra aqui porque a rotação já me custou seis tentativas em 07/09 e **nenhuma
        // delas tinha o número na mão**.
        var anguloAtual = "?"
        if let cx = saida.connection(with: .video) {
            if #available(iOS 17.0, *) {
                anguloAtual = "\(Int(cx.videoRotationAngle))"
            } else {
                anguloAtual = "vo:\(cx.videoOrientation.rawValue)"
            }
        }
        let cena = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        Diagnostico.nota("APP CAMERA vigente: pedido=\(Resolucao.escolhida.rotulo)"
            + "@\(Resolucao.quadros) · formato=\(dim.width)x\(dim.height)"
            + " · minFrameDuration=\(String(format: "%.1f", fpsEfetivo)) fps"
            + " · faixas=\(ap.activeFormat.videoSupportedFrameRateRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" })"
            + " · lado=\(ap.position.rawValue) angulo=\(anguloAtual)"
            + " interface=\(cena?.interfaceOrientation.rawValue ?? -1)"
            + " aparelho=\(UIDevice.current.orientation.rawValue)")
    }

    // --- o formato que a câmera entrega -----------------------------------------------------------

    private let travaDoFormato = NSLock()
    private var _formatoRecebido = "?"
    var formatoRecebido: String {
        travaDoFormato.lock(); defer { travaDoFormato.unlock() }
        return _formatoRecebido
    }
    /// O tamanho do último quadro da saída (já girado pela conexão): é o quadro que a rede leva, e o
    /// referencial do toque de um receptor (R9b).
    private var _dimensaoRecebida = CGSize.zero

    /// **O toque de um receptor, do quadro decodificado ao sensor** (R9b, contrato §3.4): `x` e `y` de
    /// 0 a 1 no quadro que foi à rede, que é o da saída de dados — girado pela conexão e **nunca**
    /// espelhado (`montarCaptura`), escalado sem tarja pelo encoder. A conversão é a da própria saída
    /// (`metadataOutputRectConverted`, o referencial do ponto de interesse), que conhece o giro da
    /// conexão; um retângulo de 1 pixel, e o centro dele. `nil`: sem quadro ainda, ou fora de [0, 1].
    /// Na `fila`.
    func pontoDoSensor(doQuadro x: Double, _ y: Double) -> CGPoint? {
        travaDoFormato.lock()
        let d = _dimensaoRecebida
        travaDoFormato.unlock()
        guard d.width > 0, d.height > 0, x >= 0, x <= 1, y >= 0, y <= 1,
              saida.connection(with: .video) != nil else { return nil }
        let px = CGRect(x: x * d.width - 0.5, y: y * d.height - 0.5, width: 1, height: 1)
        let r = saida.metadataOutputRectConverted(fromOutputRect: px)
        let p = CGPoint(x: r.midX, y: r.midY)
        guard p.x.isFinite, p.y.isFinite, p.x >= -0.01, p.x <= 1.01, p.y >= -0.01, p.y <= 1.01 else { return nil }
        return CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }
}

extension DonoDaCaptura: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    /// O mesmo seletor serve às duas saídas (`captureOutput(_:didOutput:from:)`): quem separa é a
    /// saída. O áudio chega na `filaDoAudio`, o vídeo na `fila`.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === saidaDeAudio {
            // Um buffer atrasado depois do fechar não sai (nem sem conversão).
            travaDosRelogios.lock(); let aberto = _microfoneAberto; let relogioDoMic = _relogioDoMicrofone
            travaDosRelogios.unlock()
            guard aberto else { return }
            // **A idade na chegada, no relógio do próprio microfone, antes de qualquer trabalho nosso**
            // (§8.12.11): separa "o AVFoundation entregou atrasado" de "a nossa fila atrasou".
            let chegada = CFAbsoluteTimeGetCurrent()
            var idade: Double?
            if let r = relogioDoMic {
                let i = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(r), CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
                if i.isFinite { idade = i }
            }
            contarChegadaDeAudio(idade: idade, agora: chegada)
            let cpuDoSom = MedidorDeCpu.agora()
            defer {
                contarTrabalhoDeAudio(CFAbsoluteTimeGetCurrent() - chegada)
                MedidorDeCpu.somar("entrega_som", desde: cpuDoSom)
            }
            // A sessão do microfone é outra: o PTS vai ao relógio da câmera antes de sair daqui.
            let noRelogio = noRelogioDaCamera(sampleBuffer)
            contarAudio(noRelogio)
            assinante?.audioDaCaptura(noRelogio)
            gravador?.audioDaCaptura(noRelogio)
            return
        }
        guard let imagem = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ptsCm = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = CMTimeGetSeconds(ptsCm)
        travaDosContadores.lock()
        var relogioDosQuadros = _relogioDosQuadros
        travaDosContadores.unlock()
        if relogioDosQuadros == nil, let r = DonoDaCaptura.relogio(de: sessao) {
            relogioDosQuadros = r
            travaDosContadores.lock(); _relogioDosQuadros = r; travaDosContadores.unlock()
            Diagnostico.nota("APP CAMERA dono: relógio dos quadros lido"
                + " (\(CFEqual(r, CMClockGetHostTimeClock()) ? "o do host" : "o da sessão, não o do host"))")
        }
        let idade = relogioDosQuadros.map { CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime($0), ptsCm)) }
        travaDosContadores.lock()
        if let idade, idade.isFinite { _idadeMaiorNaEntrega = max(_idadeMaiorNaEntrega, idade) }
        _entraram = _entraram &+ 1
        _ultimoQuadroEm = ProcessInfo.processInfo.systemUptime
        if pts.isFinite {
            if _ultimoPts >= 0, pts > _ultimoPts {
                _buracoMaior = max(_buracoMaior, pts - _ultimoPts)
                if _janelaAberta { _buracoDaJanela = max(_buracoDaJanela, pts - _ultimoPts) }
            }
            if _janelaAberta { _quadrosDaJanela += 1 }
            _ultimoPts = pts
        }
        travaDosContadores.unlock()
        medirFormato(imagem)
        if BancadaDosControles.opcoes.lumaMedia { medirLuma(imagem) }
        if !avisouEntrega {
            avisouEntrega = true
            naPrincipal { [weak self] in self?.entregando = true }
        }
        let cpuRede = MedidorDeCpu.agora()
        assinante?.quadroDaCaptura(sampleBuffer, imagem: imagem)
        MedidorDeCpu.somar("rede_entrada_video", desde: cpuRede)
        let cpuGravacao = MedidorDeCpu.agora()
        gravador?.quadroDaCaptura(sampleBuffer, imagem: imagem)
        MedidorDeCpu.somar("gravacao_entrada_video", desde: cpuGravacao)
    }

    /// **O quadro que a captura jogou fora**, contado pelo motivo (§8.12.1). Só o vídeo: o microfone
    /// é outra saída.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === saida else { return }
        let motivo = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String
        let atrasado = motivo == (kCMSampleBufferDroppedFrameReason_FrameWasLate as String)
        let semBuffer = motivo == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String)
        travaDosContadores.lock()
        if atrasado { _perdidosAtrasados &+= 1 } else if semBuffer { _perdidosSemBuffer &+= 1 } else { _perdidosOutros &+= 1 }
        travaDosContadores.unlock()
    }

    /// **Registra o formato que a câmera de fato entrega, e não o que se supõe que ela entregue.**
    ///
    /// A appex registra `formato_do_replaykit=420f(faixa-completa)`; esta linha é o equivalente da
    /// câmera, e ela é medida **depois** do pedido de `420v`: se a captura ignorar o pedido, a
    /// linha denuncia.
    ///
    /// ## Por que o pedido é na captura, e não só no encoder
    ///
    /// O caminho que a tela usa — declarar `420v` em `imageBufferAttributes` do
    /// `VTCompressionSessionCreate` — converte de verdade, **mas só quando há reescala**: a
    /// sessão de transferência de pixel do VideoToolbox só existe quando há o que transferir.
    /// Medido em `Testes/rodar.sh` com o encoder do produto, por percentis de luma:
    ///
    /// | entrada | saída | rótulo | luma (P10–P90) |
    /// |---|---|---|---|
    /// | 420f 720x1280 | 720x1280 (**sem** reescala) | `pc` | 0–255 |
    /// | 420f 720x1280 | 718x1278 (reescala mínima) | `tv` | 16–236 |
    /// | 420f 750x1334 | 720x1280 (o emissor de tela) | `tv` | 15–236 |
    /// | 420v 720x1280 | 720x1280 | `tv` | 15–235 |
    ///
    /// **A primeira linha é exatamente onde a câmera cai.** Em `.hd1280x720` com
    /// `videoOrientation = .portrait` a captura entrega 720x1280, que é a dimensão de saída: sem
    /// reescala, sem transferência, e o fluxo sairia em faixa completa. A tela escapa porque os
    /// 750x1334 do iPhone 7 nunca coincidem com o destino — o que é sorte de dimensão, não
    /// mecanismo.
    ///
    /// A saída certa é a que a Frente 3 usou no macOS e que a appex não tem, porque quem escolhe
    /// o formato é quem captura: **pedir `420v` na saída de captura**. O
    /// `AVCaptureVideoDataOutput` entrega valores realmente limitados, e aí o resultado não
    /// depende de as dimensões calharem de diferir.
    ///
    /// Chamado por quadro de propósito — é uma comparação de `String` contra `"?"` e um `lock`
    /// sem disputa — porque o formato ativo pode mudar por baixo, e um valor medido uma vez só
    /// mentiria a partir da mudança.
    private func medirFormato(_ imagem: CVPixelBuffer) {
        // A dimensão entra na chave junto com o nome: o formato de pixel não muda quando o
        // aparelho gira, mas a dimensão muda — e era justamente a dimensão que ninguém via.
        let nome = CodificadorH264.nomeDoFormato(CVPixelBufferGetPixelFormatType(imagem))
            + " \(CVPixelBufferGetWidth(imagem))x\(CVPixelBufferGetHeight(imagem))"
        travaDoFormato.lock()
        let mudou = _formatoRecebido != nome
        if mudou { _formatoRecebido = nome }
        _dimensaoRecebida = CGSize(width: CVPixelBufferGetWidth(imagem), height: CVPixelBufferGetHeight(imagem))
        travaDoFormato.unlock()
        guard mudou else { return }
        Diagnostico.nota("APP CAMERA formato_da_camera=\(nome)"
            + " dimensao=\(CVPixelBufferGetWidth(imagem))x\(CVPixelBufferGetHeight(imagem))")
    }
}

// --- o microfone (R5 fase 2) ------------------------------------------------------------------------
//
// `docs/teleprompter-com-camera.md` §4 e §8.4. A regra "este app nunca abre o microfone" caiu em todo
// emissor de câmera (Pessoa Exemplo, 24/09): o microfone é um **botão que começa desligado**, o som é **cru**
// (sem cancelamento de eco, supressor de ruído nem ganho automático), e ligar/desligar **abre e fecha
// de verdade** a entrada — não é um mudo por software: o ponto laranja do iOS diz a verdade.

extension DonoDaCaptura {

    static var textoDoMicrofoneNegado: String {
        tr("O Quall não tem acesso ao microfone. Abra %@ e ligue; "
           + "a câmera continua sem som enquanto isso.", trSistema("Ajustes → Quall Studio → Microfone"))
    }

    static var textoDoMicrofoneRestrito: String {
        tr("O microfone está bloqueado neste aparelho por Tempo de Uso ou por um perfil de "
           + "gerenciamento. Quem administra o aparelho precisa liberar; a câmera segue sem som.")
    }

    /// O toque no botão.
    func alternarMicrofone(por motivo: String = "toque") {
        switch microfone {
        case .ligado, .pedindo: desligarMicrofone(por: motivo)
        default: ligarMicrofone(por: motivo)
        }
    }

    /// Liga: **pede** a permissão de microfone (no primeiro toque, nunca ao abrir a tela), ativa a
    /// sessão de áudio e põe a entrada na captura. Na principal.
    func ligarMicrofone(por motivo: String) {
        religarAoVoltar = false
        guard montado else {
            Diagnostico.nota("APP MICROFONE ligar recusado (\(motivo)): a câmera ainda não está montada")
            return
        }
        switch microfone {
        case .ligado, .pedindo: return
        default: break
        }
        vezDoMicrofone += 1
        let vez = vezDoMicrofone
        microfone = .pedindo
        Diagnostico.nota("APP MICROFONE ligando (\(motivo))")
        DonoDaCaptura.pedirPermissaoDoMicrofone { [weak self] resposta in
            guard let self, vez == self.vezDoMicrofone else { return }
            switch resposta {
            case let .recusada(texto, ajustes):
                Diagnostico.nota("APP MICROFONE sem permissão ajustes=\(ajustes)")
                self.microfone = .recusado(motivo: texto, podeAbrirAjustes: ajustes)
            case .concedida:
                self.controleDoMicrofone.async { [weak self] in
                    guard let self else { return }
                    let erro = self.abrirMicrofoneNaFila()
                    naPrincipal { [weak self] in
                        guard let self else { return }
                        guard vez == self.vezDoMicrofone else {
                            // Desligado (ou a câmera fechou) enquanto abria: o fechar já está na fila,
                            // atrás deste abrir. Nada a mostrar.
                            return
                        }
                        self.microfone = erro.map { .falhou($0) } ?? .ligado
                    }
                }
            }
        }
    }

    /// Desliga: tira a entrada da captura e devolve a sessão de áudio. Na principal.
    func desligarMicrofone(por motivo: String) {
        religarAoVoltar = false
        vezDoMicrofone += 1
        let estava = microfone
        microfone = .desligado
        Diagnostico.nota("APP MICROFONE desligando (\(motivo)) estava=\(estava)")
        // Sempre, e não só de `.ligado`: o fechar é idempotente, e um estado que tenha mudado sem
        // passar pela fila não pode deixar a entrada órfã.
        controleDoMicrofone.async { [weak self] in self?.fecharMicrofoneNaFila(motivo: motivo) }
    }

    /// **Pede**, e não só lê (`docs/regras-de-frente.md`). A resposta volta na principal.
    static func pedirPermissaoDoMicrofone(_ fim: @escaping (Permissao) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            naPrincipal { fim(.concedida) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                naPrincipal {
                    fim(ok ? .concedida
                        : .recusada(motivo: DonoDaCaptura.textoDoMicrofoneNegado, podeAbrirAjustes: true))
                }
            }
        case .denied:
            naPrincipal { fim(.recusada(motivo: DonoDaCaptura.textoDoMicrofoneNegado, podeAbrirAjustes: true)) }
        case .restricted:
            naPrincipal { fim(.recusada(motivo: DonoDaCaptura.textoDoMicrofoneRestrito, podeAbrirAjustes: false)) }
        @unknown default:
            naPrincipal { fim(.recusada(motivo: DonoDaCaptura.textoDoMicrofoneNegado, podeAbrirAjustes: true)) }
        }
    }

    /// **O modo da sessão de áudio: `.measurement`, o mais cru.**
    ///
    /// A documentação da Apple diz que `.measurement` minimiza o processamento de sinal do sistema
    /// na entrada e na saída — é o modo sem ganho automático — e, com mais de um microfone, usa o
    /// principal. Os tratamentos de voz (cancelamento de eco, supressor de ruído, AGC de voz) vêm do
    /// *voice processing*, que só entra nos modos `.voiceChat` e `.videoChat` (ou com
    /// `setVoiceProcessingEnabled`), e nenhum deles é usado aqui. Os "modos de microfone" do iOS 15+
    /// (Isolamento de Voz, Amplo Espectro, na Central de Controle) são do voice processing também.
    ///
    /// `.videoRecording` é o modo que a Apple manda usar para gravar filme, e escolhe o microfone
    /// que acompanha a câmera em uso — mas a documentação **não diz** que processamento ele aplica.
    /// Fica como braço de bancada (`--modo-do-microfone videoRecording`), não como padrão: o que
    /// não está escrito nem medido não vira produto. O preço do `.measurement`: o nível sai baixo (sem
    /// AGC), como numa filmadora com o ganho no manual.
    ///
    /// **Não medido em aparelho**: que o iPhone X (iOS 16) e o iPhone 7 (iOS 15) não apliquem nada
    /// neste modo. É o que a checagem com tom sintético do §8.4 olha (o nível por degrau).
    static var modoDoMicrofone: AVAudioSession.Mode {
        switch BancadaDoMicrofone.opcoes.modo {
        case "videoRecording": return .videoRecording
        case "default": return .default
        default: return .measurement
        }
    }

    /// Abre o microfone. **Só na `controleDoMicrofone`**. Devolve `nil` quando abriu, e o texto para
    /// a pessoa quando não.
    ///
    /// **Na sessão do microfone, e não na da câmera** (`sessaoDoMicrofone`): a `sessao` da câmera
    /// não é reconfigurada, e a imagem não para (o motivo, e o que ainda não foi medido, em
    /// `docs/teleprompter-com-camera.md` §8.5). A janela de 2 s depois do toque
    /// (`janelaDoToque`) é a testemunha.
    ///
    /// **A sessão de áudio só é ativada aqui**, com o botão ligado: abrir a tela da câmera não
    /// interrompe a música de ninguém. Ligado, a categoria é `.playAndRecord` sem `mixWithOthers`:
    /// a música de outro app para, porque ela entraria no microfone.
    fileprivate func abrirMicrofoneNaFila() -> String? {
        guard !microfoneFechado else { return tr("A câmera já fechou.") }
        if entradaDeAudio != nil { return nil }
        guard let aparelho = AVCaptureDevice.default(for: .audio) else {
            return tr("Este aparelho não tem microfone disponível.")
        }
        let janela = abrirJanelaDoToque("ligar")
        defer { fecharJanelaDoToque(janela) }
        let audio = AVAudioSession.sharedInstance()
        let modo = DonoDaCaptura.modoDoMicrofone
        do {
            // A ativação da sessão de áudio **sozinha** vai para a linha da janela (`sessao_de_audio`):
            // separa o custo dela do da captura, se a imagem ainda soluçar.
            let t0 = CFAbsoluteTimeGetCurrent()
            try audio.setCategory(.playAndRecord, mode: modo, options: [])
            // 48 kHz é o relógio do Opus: pedindo aqui, o conversor quase sempre só troca o formato.
            try? audio.setPreferredSampleRate(48_000)
            try audio.setActive(true)
            anotarSessaoDeAudioNaJanela(CFAbsoluteTimeGetCurrent() - t0)
            sessaoDeAudioAtiva = true
        } catch {
            Diagnostico.falha("APP MICROFONE a sessão de áudio recusou: \(SanitizacaoDoLog.erro(error))")
            return tr("O iOS não liberou o áudio agora (%ld). Tente de novo; "
                + "se outro app estiver gravando, feche-o.", (error as NSError).code)
        }
        guard let nova = try? AVCaptureDeviceInput(device: aparelho) else {
            desativarSessaoDeAudio()
            return tr("Não foi possível abrir o microfone.")
        }
        let inicio = CFAbsoluteTimeGetCurrent()
        let s = sessaoDoMicrofone
        // A sessão de áudio é nossa (ver `montarCaptura`): a captura não escolhe modo nenhum.
        s.automaticallyConfiguresApplicationAudioSession = false
        s.beginConfiguration()
        var ok = s.canAddInput(nova)
        if ok {
            s.addInput(nova)
            if !s.outputs.contains(saidaDeAudio) {
                if s.canAddOutput(saidaDeAudio) {
                    saidaDeAudio.setSampleBufferDelegate(self, queue: filaDoAudio)
                    s.addOutput(saidaDeAudio)
                } else {
                    s.removeInput(nova)
                    ok = false
                }
            }
        }
        s.commitConfiguration()
        guard ok else {
            desativarSessaoDeAudio()
            return tr("A captura não aceitou o microfone.")
        }
        entradaDeAudio = nova
        travaDosContadores.lock(); _ultimoPtsDeAudio = -1; travaDosContadores.unlock()
        travaDosRelogios.lock()
        _relogioDoMicrofone = nil; _relogioDaCamera = nil; _relogioDaCameraProvisorio = false
        _microfoneAberto = true
        travaDosRelogios.unlock()
        // Síncrono, e **nesta** fila: a dos quadros segue livre.
        s.startRunning()
        guard s.isRunning else {
            Diagnostico.falha("APP MICROFONE a sessão do microfone não começou a rodar")
            fecharMicrofoneNaFila(motivo: "a sessão do microfone não rodou")
            return tr("O microfone não abriu junto da câmera. Tente de novo.")
        }
        let relogios = lerRelogios()
        let rota = audio.currentRoute.inputs.map { $0.portType.rawValue }
            .joined(separator: ",")
        let fonte = audio.inputDataSource == nil ? "padrão" : "selecionada"
        Diagnostico.nota(String(format: "APP MICROFONE aberto em %.0f ms", (CFAbsoluteTimeGetCurrent() - inicio) * 1000)
            + " sessao=propria categoria=\(audio.category.rawValue)"
            + " modo=\(audio.mode.rawValue) taxa=\(Int(audio.sampleRate)) Hz"
            + " rota=\(rota.isEmpty ? "?" : rota) fonte=\(fonte)"
            + " ganho_ajustavel=\(audio.isInputGainSettable) ganho=\(String(format: "%.2f", audio.inputGain))"
            + " camera_rodando=\(sessao.isRunning) \(relogios)")
        return nil
    }

    /// Fecha o microfone e devolve a sessão de áudio. **Só na `controleDoMicrofone`.** Sem entrada,
    /// só confere que a sessão de áudio não ficou ativa. A câmera não é tocada.
    fileprivate func fecharMicrofoneNaFila(motivo: String) {
        if let e = entradaDeAudio {
            let janela = abrirJanelaDoToque("desligar")
            let inicio = CFAbsoluteTimeGetCurrent()
            let s = sessaoDoMicrofone
            // Os buffers que ainda estiverem a caminho são descartados (`captureOutput`). Os
            // relógios **não** são zerados: o próximo abrir os relê.
            travaDosRelogios.lock(); _microfoneAberto = false; travaDosRelogios.unlock()
            // Parar primeiro (é o que apaga o ponto laranja), e tirar a entrada com a sessão parada,
            // que não custa nada.
            if s.isRunning { s.stopRunning() }
            s.beginConfiguration()
            s.removeInput(e)
            s.commitConfiguration()
            entradaDeAudio = nil
            Diagnostico.nota(String(format: "APP MICROFONE fechado em %.0f ms (%@)",
                                    (CFAbsoluteTimeGetCurrent() - inicio) * 1000, motivo))
            let t0 = CFAbsoluteTimeGetCurrent()
            desativarSessaoDeAudio()
            anotarSessaoDeAudioNaJanela(CFAbsoluteTimeGetCurrent() - t0)
            fecharJanelaDoToque(janela)
        }
        desativarSessaoDeAudio()
    }

    /// O relógio de uma sessão de captura: o de sincronização (iOS 15.4+), ou o `masterClock`
    /// antes dele. `nil` com a sessão parada.
    fileprivate static func relogio(de s: AVCaptureSession) -> CMClock? {
        if #available(iOS 15.4, *) { return s.synchronizationClock }
        return s.masterClock
    }

    /// Lê os dois relógios (com as duas sessões rodando) e devolve a testemunha para o diário: a
    /// diferença entre eles agora e a razão, que dizem se a conversão faz alguma coisa.
    fileprivate func lerRelogios() -> String {
        let doMicrofone = DonoDaCaptura.relogio(de: sessaoDoMicrofone)
        // Sem a câmera rodando ainda (montada, com o `ligar` na fila: `--microfone-apos 0`), o do
        // host, que é o que a sessão da câmera sem áudio usa — **provisório**: relido no primeiro
        // buffer com ela rodando.
        let lido = sessao.isRunning ? DonoDaCaptura.relogio(de: sessao) : nil
        let daCamera = lido ?? CMClockGetHostTimeClock()
        travaDosRelogios.lock()
        _relogioDoMicrofone = doMicrofone
        _relogioDaCamera = daCamera
        _relogioDaCameraProvisorio = lido == nil
        travaDosRelogios.unlock()
        let camera = lido == nil ? " camera=host_provisorio" : ""
        guard let doMicrofone else { return "relogios=sem_relogio_do_microfone" + camera }
        if CFEqual(doMicrofone, daCamera) { return "relogios=o_mesmo" + camera }
        let agora = CMClockGetTime(doMicrofone)
        let convertido = CMSyncConvertTime(agora, from: doMicrofone, to: daCamera)
        let dif = CMTimeGetSeconds(CMTimeSubtract(convertido, agora)) * 1000
        let razao = CMSyncGetRelativeRate(doMicrofone, relativeTo: daCamera)
        return String(format: "relogios=convertidos diferenca=%.3f ms razao=%.6f", dif, razao) + camera
    }

    /// **O PTS do som no relógio da câmera.** Na `filaDoAudio`. Os outros campos de tempo do buffer
    /// andam junto (o mesmo deslocamento); sem os dois relógios, ou com eles iguais, o buffer passa
    /// como veio.
    fileprivate func noRelogioDaCamera(_ amostra: CMSampleBuffer) -> CMSampleBuffer {
        travaDosRelogios.lock()
        var de = _relogioDoMicrofone, para = _relogioDaCamera
        let provisorio = _relogioDaCameraProvisorio
        travaDosRelogios.unlock()
        // Os primeiros buffers podem chegar antes de `lerRelogios` (o `startRunning` já voltou, o
        // registro ainda não), e a rota nova zera o do microfone: relidos aqui, **só** das sessões
        // rodando — uma sessão parada não tem relógio que valha.
        if de == nil, sessaoDoMicrofone.isRunning, let r = DonoDaCaptura.relogio(de: sessaoDoMicrofone) {
            de = r
            travaDosRelogios.lock(); if _relogioDoMicrofone == nil { _relogioDoMicrofone = r }; travaDosRelogios.unlock()
        }
        if para == nil || provisorio, sessao.isRunning, let r = DonoDaCaptura.relogio(de: sessao) {
            para = r
            travaDosRelogios.lock(); _relogioDaCamera = r; _relogioDaCameraProvisorio = false; travaDosRelogios.unlock()
            if provisorio {
                Diagnostico.nota("APP MICROFONE relógio da câmera relido com ela rodando (era o do host, provisório)")
            }
        }
        guard let de, let para else { return semConversao(amostra) }
        if CFEqual(de, para) { return amostra }
        return converter(amostra, de: de, para: para) ?? semConversao(amostra)
    }

    private func semConversao(_ amostra: CMSampleBuffer) -> CMSampleBuffer {
        travaDosRelogios.lock(); _semConversao &+= 1; travaDosRelogios.unlock()
        return amostra
    }

    private func converter(_ amostra: CMSampleBuffer, de: CMClock, para: CMClock) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(amostra)
        guard pts.isValid else { return nil }
        let desloc = CMTimeSubtract(CMSyncConvertTime(pts, from: de, to: para), pts)
        var n: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(amostra, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &n) == noErr, n > 0 else { return nil }
        var tempos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
        guard CMSampleBufferGetSampleTimingInfoArray(amostra, entryCount: n, arrayToFill: &tempos,
                                                     entriesNeededOut: &n) == noErr else { return nil }
        for k in tempos.indices {
            if tempos[k].presentationTimeStamp.isValid {
                tempos[k].presentationTimeStamp = CMTimeAdd(tempos[k].presentationTimeStamp, desloc)
            }
            if tempos[k].decodeTimeStamp.isValid {
                tempos[k].decodeTimeStamp = CMTimeAdd(tempos[k].decodeTimeStamp, desloc)
            }
        }
        var copia: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: amostra,
                                                    sampleTimingEntryCount: n, sampleTimingArray: &tempos,
                                                    sampleBufferOut: &copia) == noErr else { return nil }
        return copia
    }

    /// **Só na `controleDoMicrofone`.** Se o I/O da captura ainda não parou, o iOS recusa
    /// ("ocupado"): uma nova tentativa 150 ms depois, na mesma fila, e só então desiste — dizendo.
    /// A bandeira só baixa no sucesso, e o fechar seguinte tenta de novo. (Revisão de 24/09.)
    fileprivate func desativarSessaoDeAudio(tentativa: Int = 1) {
        guard sessaoDeAudioAtiva, entradaDeAudio == nil else { return }
        do {
            // Quem tocava música antes volta a tocar.
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessaoDeAudioAtiva = false
            Diagnostico.nota("APP MICROFONE sessão de áudio devolvida (tentativa \(tentativa))")
        } catch {
            Diagnostico.falha("APP MICROFONE a sessão de áudio não desativou (tentativa \(tentativa)): \(SanitizacaoDoLog.erro(error))")
            guard tentativa < 2 else { return }
            controleDoMicrofone.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.desativarSessaoDeAudio(tentativa: tentativa + 1)
            }
        }
    }

    /// **O iOS fechou o microfone.** Fora da tela (o app não tem modo de segundo plano, e a sessão
    /// do microfone é interrompida quando ele sai), o microfone fecha e **volta sozinho** no
    /// `.active` — antes, com a sessão única, ele voltava junto com a câmera. Com o app na tela (uma
    /// ligação, a Siri, outro app), fecha e o botão diz por quê. Na principal.
    fileprivate func perderMicrofone(_ motivo: String, foraDaTela: Bool) {
        guard microfone == .ligado || microfone == .pedindo else { return }
        guard foraDaTela || UIApplication.shared.applicationState == .background else {
            soltarMicrofonePorInterrupcao(motivo)
            return
        }
        vezDoMicrofone += 1
        religarAoVoltar = true
        microfone = .desligado
        Diagnostico.nota("APP MICROFONE fechado pelo iOS fora da tela (\(motivo)); volta sozinho no primeiro plano")
        controleDoMicrofone.async { [weak self] in self?.fecharMicrofoneNaFila(motivo: "fora da tela") }
    }

    /// A interrupção do áudio: o microfone sai (pela fila), e o botão diz por quê. Na principal.
    fileprivate func soltarMicrofonePorInterrupcao(_ motivo: String) {
        vezDoMicrofone += 1
        microfone = .falhou(tr("O microfone foi desligado: %@ (uma ligação, a Siri, um alarme "
            + "ou outro app). Toque no botão para ligar de novo.", DonoDaCaptura.motivoNaTela(motivo)))
        controleDoMicrofone.async { [weak self] in self?.fecharMicrofoneNaFila(motivo: motivo) }
    }

    /// O motivo da interrupção na língua da tela. O `motivo` em si continua em português: é o que o
    /// diário recebe (`fecharMicrofoneNaFila`).
    fileprivate static func motivoNaTela(_ motivo: String) -> String {
        switch motivo {
        case "a captura foi interrompida pelo áudio": return tr("a captura foi interrompida pelo áudio")
        case "o iOS interrompeu o microfone": return tr("o iOS interrompeu o microfone")
        case "o microfone parou por um erro do sistema": return tr("o microfone parou por um erro do sistema")
        case "o iOS interrompeu o áudio": return tr("o iOS interrompeu o áudio")
        default: return motivo
        }
    }

    /// Ligação telefônica, Siri, alarme: o iOS desativa a sessão de áudio e interrompe a sessão do
    /// microfone. **O microfone sai no começo da interrupção**, e não se espera o fim dela para
    /// voltar: o `.ended` não é garantido. Com o microfone em sessão própria (§8.5), a câmera não
    /// deveria parar junto — **hipótese, não medida**; se parar, ela volta sozinha como antes. O
    /// microfone volta no botão. (Revisão de 24/09.)
    fileprivate func observarSessaoDeAudio() {
        let centro = NotificationCenter.default
        // A sessão do microfone é própria: a interrupção dela (outro app tomou o áudio) e o erro de
        // execução dela não param a câmera, e o microfone sai com o porquê.
        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: sessaoDoMicrofone, queue: .main
        ) { [weak self] aviso in
            let codigo = (aviso.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            let estado = UIApplication.shared.applicationState.rawValue
            Diagnostico.nota("APP MICROFONE a sessão do microfone foi interrompida razao=\(codigo) app=\(estado)")
            let fora = codigo == AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground.rawValue
            self?.perderMicrofone("o iOS interrompeu o microfone", foraDaTela: fora)
        })
        observadores.append(centro.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.religarAoVoltar else { return }
            self.religarAoVoltar = false
            guard self.montado else { return }
            self.ligarMicrofone(por: "o app voltou ao primeiro plano com o microfone ligado")
        })
        observadores.append(centro.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: sessaoDoMicrofone, queue: .main
        ) { [weak self] aviso in
            let erro = aviso.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Diagnostico.falha("APP MICROFONE erro de execução da sessão do microfone: \(erro?.code ?? 0)")
            guard let self, self.microfone == .ligado || self.microfone == .pedindo else { return }
            self.soltarMicrofonePorInterrupcao("o microfone parou por um erro do sistema")
        })
        observadores.append(centro.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] aviso in
            let tipo = (aviso.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let comecou = tipo == AVAudioSession.InterruptionType.began.rawValue
            Diagnostico.nota("APP MICROFONE sessão de áudio interrompida: \(comecou ? "começou" : "acabou")")
            guard comecou, let self else { return }
            self.perderMicrofone("o iOS interrompeu o áudio", foraDaTela: false)
        })
        observadores.append(centro.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] aviso in
            // Outra rota pode ser outro dispositivo, com outro relógio: relido no próximo buffer.
            if let self {
                self.travaDosRelogios.lock(); self._relogioDoMicrofone = nil; self.travaDosRelogios.unlock()
            }
            let razao = (aviso.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            let entradas = AVAudioSession.sharedInstance().currentRoute.inputs
                .map { $0.portType.rawValue }.joined(separator: ",")
            Diagnostico.nota("APP MICROFONE rota mudou razao=\(razao) entrada=\(entradas.isEmpty ? "nenhuma" : entradas)")
        })
    }

    // --- as testemunhas -------------------------------------------------------------------------

    /// **A janela do toque**: do começo de um ligar ou desligar até 2 s depois do fim, o maior
    /// buraco entre dois quadros da **câmera** e quantos quadros chegaram. É a prova de que o
    /// microfone não para a imagem (critério: abaixo de ~70 ms, §8.5) — mais fina que a janela de
    /// 10 s do relato, onde o toque se mistura com o resto. Devolve o número da janela.
    fileprivate func abrirJanelaDoToque(_ acao: String) -> Int {
        travaDosContadores.lock()
        // Uma janela ainda aberta (o ligar que falhou e fechou; um toque rápido) é escrita agora,
        // cortada, e não perdida.
        let anterior = _janelaAberta ? fotoDaJanela(cortada: true) : nil
        _janelaDoToque += 1
        _janelaAberta = true
        _buracoDaJanela = 0
        _quadrosDaJanela = 0
        _inicioDaJanela = CFAbsoluteTimeGetCurrent()
        _fimDaAcaoDaJanela = 0
        _sessaoDeAudioDaJanela = -1
        _acaoDaJanela = acao
        let n = _janelaDoToque
        travaDosContadores.unlock()
        if let anterior { escreverJanela(anterior) }
        return n
    }

    /// O tempo da ativação (ou devolução) da `AVAudioSession` sozinha, na janela aberta.
    fileprivate func anotarSessaoDeAudioNaJanela(_ segundos: Double) {
        travaDosContadores.lock()
        if _janelaAberta { _sessaoDeAudioDaJanela = segundos }
        travaDosContadores.unlock()
    }

    /// Marca o fim da ação e escreve a linha 2 s depois, se nenhuma janela nova a tiver cortado.
    fileprivate func fecharJanelaDoToque(_ n: Int) {
        travaDosContadores.lock()
        if n == _janelaDoToque { _fimDaAcaoDaJanela = CFAbsoluteTimeGetCurrent() }
        travaDosContadores.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.travaDosContadores.lock()
            guard n == self._janelaDoToque, self._janelaAberta else { self.travaDosContadores.unlock(); return }
            let foto = self.fotoDaJanela(cortada: false)
            self.travaDosContadores.unlock()
            self.escreverJanela(foto)
        }
    }

    fileprivate struct FotoDaJanela {
        let acao: String, cortada: Bool, buraco: Double, quadros: Int
        let inicio: CFAbsoluteTime, fimDaAcao: CFAbsoluteTime, sessaoDeAudio: Double, ultimo: Double
    }

    /// **Sob `travaDosContadores`.** Tira a foto da janela aberta e a fecha.
    private func fotoDaJanela(cortada: Bool) -> FotoDaJanela {
        _janelaAberta = false
        return FotoDaJanela(acao: _acaoDaJanela, cortada: cortada, buraco: _buracoDaJanela,
                            quadros: _quadrosDaJanela, inicio: _inicioDaJanela, fimDaAcao: _fimDaAcaoDaJanela,
                            sessaoDeAudio: _sessaoDeAudioDaJanela, ultimo: _ultimoPts)
    }

    private func escreverJanela(_ f: FotoDaJanela) {
        // O quadro que não chegou não abre buraco nenhum: a idade do último diz se a imagem parou e
        // não voltou.
        let relogio = DonoDaCaptura.relogio(de: sessao) ?? CMClockGetHostTimeClock()
        let idade = f.ultimo >= 0 ? CMTimeGetSeconds(CMClockGetTime(relogio)) - f.ultimo : -1
        let agora = CFAbsoluteTimeGetCurrent()
        let acao = f.fimDaAcao > 0 ? String(format: "%.0f ms", (f.fimDaAcao - f.inicio) * 1000) : "inacabada"
        let audio = f.sessaoDeAudio >= 0 ? String(format: "%.0f ms", f.sessaoDeAudio * 1000) : "?"
        Diagnostico.nota("APP MICROFONE imagem ao \(f.acao)\(f.cortada ? " (cortada por outro toque)" : ""):"
            + " buraco_maior_da_camera=" + String(format: "%.0f", f.buraco * 1000) + " ms"
            + " quadros=\(f.quadros) em " + String(format: "%.1f", agora - f.inicio) + " s"
            + " acao=\(acao) sessao_de_audio=\(audio)"
            + " ultimo_quadro_ha=" + String(format: "%.0f", idade * 1000) + " ms")
    }

    /// Na fila do áudio: conta buffers e amostras, e o maior intervalo entre dois buffers seguidos.
    fileprivate func contarChegadaDeAudio(idade: Double?, agora: Double) {
        travaDosContadores.lock()
        if let idade { _idadeMaxNaChegadaDoSom = max(_idadeMaxNaChegadaDoSom, idade) }
        // Uma "rajada": um buffer que chega menos de 2 ms depois do anterior (21 ms de som cada).
        if _ultimaChegadaDoSom > 0, agora - _ultimaChegadaDoSom < 0.002 { _rajadasDoSom += 1 }
        _ultimaChegadaDoSom = agora
        travaDosContadores.unlock()
    }

    fileprivate func contarTrabalhoDeAudio(_ s: Double) {
        travaDosContadores.lock()
        _trabalhoMaxDoSom = max(_trabalhoMaxDoSom, s)
        _trabalhoSomaDoSom += s
        _trabalhosDoSom += 1
        travaDosContadores.unlock()
    }

    fileprivate func contarAudio(_ amostra: CMSampleBuffer) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(amostra))
        let n = CMSampleBufferGetNumSamples(amostra)
        travaDosContadores.lock()
        _buffersDeAudio &+= 1
        _amostrasDeAudio &+= UInt64(max(0, n))
        if pts.isFinite {
            if _ultimoPtsDeAudio >= 0 {
                if pts > _ultimoPtsDeAudio { _buracoMaiorDeAudio = max(_buracoMaiorDeAudio, pts - _ultimoPtsDeAudio) }
                _menorPassoDeAudio = min(_menorPassoDeAudio, pts - _ultimoPtsDeAudio)
            }
            _ultimoPtsDeAudio = pts
        }
        travaDosContadores.unlock()
    }

    /// A linha do microfone no relato de 10 s: o estado do botão, os buffers que chegaram na janela
    /// e o maior buraco entre eles. Com o botão desligado, `buffers=0` é a prova de que a entrada
    /// fechou de verdade.
    fileprivate func relatarMicrofone() {
        travaDosContadores.lock()
        let estado = _estadoDoMicrofone
        let d = _buffersDeAudio &- _buffersDeAudioNoRelato
        _buffersDeAudioNoRelato = _buffersDeAudio
        let amostras = _amostrasDeAudio
        let buraco = _buracoMaiorDeAudio
        _buracoMaiorDeAudio = 0
        let idadeNaChegada = _idadeMaxNaChegadaDoSom
        let (tMax, tMedio) = (_trabalhoMaxDoSom, _trabalhosDoSom > 0 ? _trabalhoSomaDoSom / Double(_trabalhosDoSom) : 0)
        let rajadas = _rajadasDoSom
        let menorPasso = _menorPassoDeAudio
        _menorPassoDeAudio = .infinity
        _idadeMaxNaChegadaDoSom = 0; _trabalhoMaxDoSom = 0; _trabalhoSomaDoSom = 0; _trabalhosDoSom = 0; _rajadasDoSom = 0
        travaDosContadores.unlock()
        travaDosRelogios.lock(); let semConversao = _semConversao; travaDosRelogios.unlock()
        Diagnostico.nota("APP MICROFONE entrega:"
            + String(format: " idade_na_chegada_max=%.0f ms trabalho_max=%.1f ms trabalho_medio=%.2f ms",
                     idadeNaChegada * 1000, tMax * 1000, tMedio * 1000)
            + " em_rajada=\(rajadas) (de \(d))"
            + (menorPasso.isFinite ? String(format: " menor_passo_de_pts=%.1f ms", menorPasso * 1000) : "")
            + String(format: " fracao_de_trabalho=%.1f%%", tMedio * Double(d) / 10 * 100))
        Diagnostico.nota("APP MICROFONE dono: botao=\(estado) buffers=\(d) na janela"
            + " amostras_total=\(amostras)"
            + " buraco_maior=\(String(format: "%.0f", buraco * 1000)) ms"
            + " sem_conversao_de_relogio=\(semConversao)"
            + " modo=\(DonoDaCaptura.modoDoMicrofone.rawValue)")
    }

    /// `--microfone-apos S` (e `--microfone-por D`): o mesmo caminho do botão, sem toque. Só com o
    /// diagnóstico ligado. **Abre o microfone de verdade**: cada corrida pede o sim do Pessoa Exemplo, e sem
    /// `--microfone-tom` o som da sala vai pela rede.
    fileprivate func agendarMicrofoneDaBancada() {
        let b = BancadaDoMicrofone.opcoes
        guard let apos = b.apos else { return }
        Diagnostico.nota("APP MICROFONE bancada: liga em \(apos) s"
            + (b.por.map { ", desliga \($0) s depois" } ?? "")
            + (b.tom ? ", com o TOM no lugar da sala" : ", com o SOM DA SALA"))
        DispatchQueue.main.asyncAfter(deadline: .now() + apos) { [weak self] in
            guard let self, self.montado else { return }
            self.ligarMicrofone(por: "bancada --microfone-apos \(apos)")
            guard let por = b.por else { return }
            let vez = self.vezDoMicrofone
            DispatchQueue.main.asyncAfter(deadline: .now() + por) { [weak self] in
                // Um toque humano no meio (outra vez) não é desfeito pela bancada.
                guard let self, self.montado, vez == self.vezDoMicrofone else { return }
                self.desligarMicrofone(por: "bancada --microfone-por \(por)")
            }
        }
    }
}

/// Os argumentos de bancada do microfone. Só valem com o diagnóstico ligado (o mesmo cuidado de
/// `--pin-da-camera`).
///
/// - `--microfone-apos S`: liga o microfone S segundos depois de a câmera montar;
/// - `--microfone-por D`: e desliga D segundos depois de ligar (prova o fechar e a devolução da
///   sessão de áudio);
/// - `--microfone-tom`: o conteúdo de cada quadro é o `TomSintetico`, com o carimbo da captura (a
///   sala não sai do aparelho). Ver `MicrofoneParaOpus`;
/// - `--modo-do-microfone measurement|videoRecording|default`: o braço do modo da sessão de áudio.
struct BancadaDoMicrofone {
    var apos: Double?
    var por: Double?
    var tom = false
    var modo = "measurement"

    static let opcoes: BancadaDoMicrofone = {
        var o = BancadaDoMicrofone()
        guard Diagnostico.ligado else { return o }
        let args = CommandLine.arguments
        func valor(_ nome: String) -> String? {
            guard let i = args.firstIndex(of: nome), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        o.apos = valor("--microfone-apos").flatMap { Double($0) }.map { max(0, $0) }
        o.por = valor("--microfone-por").flatMap { Double($0) }.map { max(0, $0) }
        o.tom = args.contains("--microfone-tom")
        if let m = valor("--modo-do-microfone"), ["measurement", "videoRecording", "default"].contains(m) {
            o.modo = m
        }
        return o
    }()
}
