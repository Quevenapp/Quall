// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation
import UIKit

/// **A bancada sem toque** do teleprompter: argumentos de lançamento que abrem as telas e fazem o
/// que uma pessoa faria, para provar em aparelho sem a mão de ninguém.
///
///     idevicedebug -u <UDID> run br.com.queven.quall --prompter --pin 424242 --porta 7979
///     idevicedebug -u <UDID> run br.com.queven.quall --prompter --pin 424242 --editar-apos 1.5
///     idevicedebug -u <UDID> run br.com.queven.quall --controle 192.168.57.20:7979 --pin 424242 \
///         --roteiro-de-bancada 100000 --segundos 20
///
/// - `--prompter`: entra direto no prompter e hospeda. `--pin` fixa o PIN (seis dígitos; sem ele, o
///   núcleo sorteia), `--porta` a porta (padrão 7979), `--tela-cheia` entra em tela cheia.
///   `--editar-apos S`: S segundos depois de a **primeira sessão subir**, edita **deste lado** —
///   fonte 64, margem 0,15, espelho ligado, e o texto com uma frase na frente —, para provar que as
///   edições dos dois lados convergem. (Era "depois de o primeiro texto chegar": com a sonda mandando
///   o mesmo roteiro que o prompter já tinha salvo, o texto não mudava, nada "chegava", e a edição
///   deste lado não acontecia — a corrida final de 13/09 saiu sem ela.)
/// - `--controle HOST:PORTA`: entra direto no controle e conecta (`--pin` no primeiro pareamento).
///   `--roteiro-de-bancada BYTES`: manda um roteiro sintético **nosso** desse tamanho, a velocidade e
///   o rolar, e depois vinte edições, medindo quanto cada uma leva para voltar confirmada — o mesmo
///   roteiro da `quall-probe controle`. `--segundos S`: desconecta S segundos depois de conectar.
///   `--pausar-e-sair`: no fim, liga o rolar, espera 1 s, **pausa e desconecta na mesma hora** — o
///   prompter tem de terminar parado. É a prova, numa casca de verdade, de que a última mensagem
///   entra na bombeada final antes de `peer_lost` (§6, §9 "A bombeada final numa casca de verdade").
///   `--saltar F`: depois de conectar, salta para a fração F (sem mandar roteiro) e relata onde o
///   prompter diz que ficou — a prova de que o salto cai no lugar com o roteiro que o prompter já tem.
///   `--mudar-fonte P` (com `--mudar-fonte-apos S`, padrão 8): S segundos depois de conectar, muda a
///   fonte para P pt — a prova de que uma fonte vinda do controle desliga a "Fonte automática" do
///   prompter, com aviso (`AjustesLocais`).
///
/// **O tranco do layout** (`MedidorDoRoteiro`), no prompter, sem controle nenhum:
///
/// - `--varrer-layout 10000,50000,100000,128000`: rola o texto a 2,5 linhas/s e, para cada
///   tamanho, faz **chegar** um roteiro sintético desse tamanho (a réplica o recebe numa thread que
///   não é a principal, e a tela o relê como faz quando ele vem do controle), depois troca a fonte
///   para 96, 32 e 48, e faz chegar o roteiro de novo — 3,5 s entre cada passo, duas voltas. Cada
///   evento sai no diário como uma linha `tranco:` com os quadros perdidos e as etapas.
/// - `--sonda-de-pilhas`: o mesmo roteiro, a mesma fonte e a mesma largura, medidos em cada pilha de
///   texto do sistema (`SondaDePilhas`), com o texto parado.
/// - `--conferir-leitura`: o texto **parado**, sem espelho, um roteiro de 100 KB, salto para 0,3, e
///   então fonte 96, fonte 32, o roteiro chegando de novo, fonte 48 — com uma linha
///   `bancada: conferência: foto N` antes de cada captura. Quem roda tira a captura da tela do
///   aparelho nessa hora (`idevicescreenshot`): o roteiro sintético escreve "Linha N" em cada
///   frase, e é pelos pixels, e não pela conta da própria vista, que se vê se a linha que estava na
///   linha de leitura continuou nela.
/// - `--pausar-apos S` (no prompter): S segundos depois de a primeira sessão subir, a pessoa do
///   prompter aperta "Pausar" (`pedirRolando(false)`) — a pausa no prompter no meio de um segurar
///   do controle (§12.5).
///
/// Lidos **uma vez**, e consumidos pela primeira tela que os usa: voltar à escolha e entrar de novo
/// com o dedo é o caminho de produto, sem bancada. `UserDefaults` não é usado de propósito (o
/// mesmo motivo de `Recepcao.lerArgumentos`): argumento de bancada persistido viraria estado que
/// sobrevive à corrida seguinte.
enum BancadaDoTeleprompter {
    struct Opcoes {
        var prompter = false
        /// `--prompter-camera`: a tela "Teleprompter com câmera" (R5), com o prompter hospedando como
        /// em `--prompter` (as mesmas opções valem) e a câmera frontal esperando um receptor.
        /// `--pin-da-camera NNNNNN` fixa o PIN da câmera (`EmissorDeCamera.pinDaBancada`).
        var prompterComCamera = false
        /// `--esconder-previa-apos S`: S segundos depois de a tela abrir, esconde a prévia; max(S, 30)
        /// segundos depois, mostra de novo. A prova de que esconder não fecha a câmera.
        var esconderPreviaApos: Double?
        var controle: String?
        var pin: String?
        var porta: UInt16?
        var telaCheia = false
        var editarApos: Double?
        var pausarApos: Double?
        var roteiroDeBancada: Int?
        var segundos: Double?
        var pausarESair = false
        var saltar: Double?
        var varrerLayout: [Int]?
        var sondaDePilhas = false
        var conferirLeitura = false
        var mudarFonte: Double?
        var mudarFonteApos: Double = 8
    }

    private static var pendentes: Opcoes?

    /// Lê os argumentos. Devolve as opções quando há teleprompter a abrir sem toque.
    static func ler() -> Opcoes? {
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        var o = Opcoes()
        o.prompterComCamera = args.contains("--prompter-camera")
        o.prompter = args.contains("--prompter") || o.prompterComCamera
        o.esconderPreviaApos = valor("--esconder-previa-apos").flatMap { Double($0) }
        o.controle = valor("--controle")
        guard o.prompter || o.controle != nil else { return nil }
        if let p = valor("--pin"), p.count == 6, p.allSatisfy(\.isNumber) { o.pin = p }
        o.porta = valor("--porta").flatMap { UInt16($0) }
        o.telaCheia = args.contains("--tela-cheia")
        o.editarApos = valor("--editar-apos").flatMap { Double($0) }
        o.pausarApos = valor("--pausar-apos").flatMap { Double($0) }
        o.roteiroDeBancada = valor("--roteiro-de-bancada").flatMap { Int($0) }
        o.segundos = valor("--segundos").flatMap { Double($0) }
        o.pausarESair = args.contains("--pausar-e-sair")
        o.saltar = valor("--saltar").flatMap { Double($0) }
        o.varrerLayout = valor("--varrer-layout").map { $0.split(separator: ",").compactMap { Int($0) } }
        o.sondaDePilhas = args.contains("--sonda-de-pilhas")
        o.conferirLeitura = args.contains("--conferir-leitura")
        o.mudarFonte = valor("--mudar-fonte").flatMap { Double($0) }
        o.mudarFonteApos = valor("--mudar-fonte-apos").flatMap { Double($0) } ?? 8
        pendentes = o
        DiarioDoTeleprompter.dizer("bancada: \(o.prompterComCamera ? "--prompter-camera" : o.prompter ? "--prompter" : "--controle")"
            + " pin_modo=\(o.pin == nil ? "sorteado" : "fixo") porta=\(o.porta.map(String.init) ?? "padrão")"
            + (o.editarApos.map { " editar-apos=\($0)" } ?? "")
            + (o.pausarApos.map { " pausar-apos=\($0)" } ?? "")
            + (o.roteiroDeBancada.map { " roteiro=\($0)" } ?? "")
            + (o.segundos.map { " segundos=\($0)" } ?? "")
            + (o.pausarESair ? " pausar-e-sair" : "")
            + (o.saltar.map { " saltar=\($0)" } ?? "")
            + (o.varrerLayout.map { " varrer-layout=\($0.map(String.init).joined(separator: ","))" } ?? "")
            + (o.sondaDePilhas ? " sonda-de-pilhas" : "")
            + (o.conferirLeitura ? " conferir-leitura" : ""))
        return o
    }

    /// As opções, **uma vez**.
    static func consumir() -> Opcoes? {
        defer { pendentes = nil }
        return pendentes
    }

    // =========================================================================================
    // O prompter edita do lado dele
    // =========================================================================================

    static func ligarNoPrompter(_ m: ModeloDoTeleprompter, opcoes: Opcoes?) {
        if let tamanhos = opcoes?.varrerLayout, !tamanhos.isEmpty { varrer(m, tamanhos: tamanhos) }
        if opcoes?.conferirLeitura == true { conferirLeitura(m) }
        if opcoes?.sondaDePilhas == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let tela = UIScreen.main.bounds
                SondaDePilhas.correr(largura: tela.width, altura: tela.height, escala: UIScreen.main.scale,
                                     tamanhos: opcoes?.varrerLayout ?? [10_000, 50_000, 100_000, 128_000])
            }
        }
        if let s = opcoes?.pausarApos {
            var pausou = false
            let anterior = m.aoConectar
            m.aoConectar = { [weak m] in
                anterior?()
                guard !pausou else { return }
                pausou = true
                DiarioDoTeleprompter.dizer("bancada: a sessão subiu; pausando deste lado em \(s) s (--pausar-apos)")
                DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak m] in
                    guard let m else { return }
                    m.pedirRolando(false)
                    DiarioDoTeleprompter.dizer("bancada: o prompter apertou Pausar (--pausar-apos): rolando=\(m.estado.rolando) "
                        + "para_tras=\(m.estado.paraTras) segurando=\(m.estado.segurando)")
                }
            }
        }
        guard let apos = opcoes?.editarApos else { return }
        var feito = false
        let anterior = m.aoConectar
        m.aoConectar = { [weak m] in
            anterior?()
            guard !feito else { return }
            feito = true
            DiarioDoTeleprompter.dizer("bancada: a sessão subiu; editando deste lado em \(apos) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + apos) { [weak m] in
                guard let m else { return }
                m.definirFonte(64)
                m.definirMargem(0.15)
                m.definirEspelho(true)
                let erro = m.confirmarTexto("Editado no prompter. " + m.texto)
                DiarioDoTeleprompter.dizer("bancada: edições do prompter feitas — fonte=\(m.estado.fonte) "
                    + "margem=\(m.estado.margem) espelho=\(m.estado.espelho) texto=\(m.texto.utf8.count) bytes "
                    + "resumo=\(ResumoDoTexto.de(m.texto))" + (erro.map { " ERRO: \($0)" } ?? ""))
            }
        }
    }

    // =========================================================================================
    // O tranco do layout: a varredura, com o texto rolando
    // =========================================================================================

    /// Ver o cabeçalho (`--varrer-layout`). O roteiro "chega" pelo mesmo caminho do controle, do
    /// ponto de vista da thread principal: a réplica o recebe noutra thread (como a bombeada), e a
    /// tela o relê (`recarregar`, o mesmo `texto()` + comparação + publicação de `aplicar`).
    static func varrer(_ m: ModeloDoTeleprompter, tamanhos: [Int]) {
        let t = Thread { [weak m] in
            Thread.sleep(forTimeInterval: 2.5)
            DispatchQueue.main.sync {
                m?.definirFonte(48)
                m?.definirMargem(0.1)
                m?.definirVelocidade(2.5)
                m?.saltar(0)
                m?.definirRolando(true)
            }
            DiarioDoTeleprompter.dizer("bancada: varredura começando (tamanhos \(tamanhos), fonte 48, rolando a 2,5 linhas/s)")
            Thread.sleep(forTimeInterval: 3.5)
            for volta in 1...2 {
                for bytes in tamanhos {
                    guard m != nil else { return }
                    chegarTexto(m, bytes: bytes, volta: volta)
                    Thread.sleep(forTimeInterval: 3.5)
                    for f in [96.0, 32.0, 48.0] {
                        DiarioDoTeleprompter.dizer("bancada: fonte \(Int(f)) (volta \(volta), \(bytes) bytes)")
                        DispatchQueue.main.async { m?.definirFonte(f) }
                        Thread.sleep(forTimeInterval: 3.5)
                    }
                    chegarTexto(m, bytes: bytes, volta: volta)
                    Thread.sleep(forTimeInterval: 3.5)
                }
            }
            DispatchQueue.main.async { m?.definirRolando(false) }
            DiarioDoTeleprompter.dizer("bancada: varredura terminada")
        }
        t.name = "quall.teleprompter.varredura"
        t.start()
    }

    /// Ver o cabeçalho (`--conferir-leitura`).
    static func conferirLeitura(_ m: ModeloDoTeleprompter) {
        let t = Thread { [weak m] in
            func foto(_ n: Int, _ o_que: String) {
                Thread.sleep(forTimeInterval: 2.5)
                DiarioDoTeleprompter.dizer("bancada: conferência: foto \(n) (\(o_que))")
                Thread.sleep(forTimeInterval: 4)
            }
            Thread.sleep(forTimeInterval: 2.5)
            DispatchQueue.main.sync {
                m?.definirRolando(false)
                m?.definirEspelho(false)
                m?.definirFonte(48)
                m?.definirMargem(0.1)
            }
            chegarTexto(m, bytes: 100_000, volta: 0)
            Thread.sleep(forTimeInterval: 2)
            DispatchQueue.main.sync { m?.saltar(0.3) }
            foto(1, "fonte 48, salto para 0,3")
            DispatchQueue.main.async { m?.definirFonte(96) }
            foto(2, "fonte 96")
            DispatchQueue.main.async { m?.definirFonte(32) }
            foto(3, "fonte 32")
            chegarTexto(m, bytes: 100_000, volta: 0)
            foto(4, "o roteiro chegou de novo, fonte 32")
            DispatchQueue.main.async { m?.definirFonte(48) }
            foto(5, "fonte 48")
            DiarioDoTeleprompter.dizer("bancada: conferência terminada")
        }
        t.name = "quall.teleprompter.conferencia"
        t.start()
    }

    private static func chegarTexto(_ m: ModeloDoTeleprompter?, bytes: Int, volta: Int) {
        guard let m else { return }
        // A marca tem sempre o mesmo comprimento (13 dígitos de ms): o resto do roteiro fica nos
        // mesmos caracteres, e a conferência da leitura (`pulo_linhas`) compara a mesma letra.
        let marca = "Corrida \(Int(Date().timeIntervalSince1970 * 1000))\n"
        let roteiro = marca + sintetico(max(0, bytes - marca.utf8.count))
        let st = m.replica.definirTexto(roteiro)
        DiarioDoTeleprompter.dizer("bancada: texto de \(roteiro.utf8.count) bytes chegando (volta \(volta), "
                                   + "status \(SessaoDoTeleprompter.nome(st)))")
        DispatchQueue.main.async {
            let t0 = CACurrentMediaTime()
            m.recarregar()
            DiarioDoTeleprompter.dizer(String(format: "bancada: chegada na principal (texto() + comparar + "
                                              + "publicar): %.1f ms", (CACurrentMediaTime() - t0) * 1000))
        }
    }

    // =========================================================================================
    // O controle manda um roteiro e mede a confirmação
    // =========================================================================================

    static func ligarNoControle(_ m: ModeloDoTeleprompter, opcoes o: Opcoes) {
        let r = m.replica
        let t = Thread { [weak m] in
            // A sessão está de pé quando o prompter mandou alguma coisa nesta sessão.
            let limite = Date().addingTimeInterval(90)
            while Date() < limite, r.estado()?.parVistoHaMs == nil { Thread.sleep(forTimeInterval: 0.05) }
            guard r.estado()?.parVistoHaMs != nil else {
                DiarioDoTeleprompter.dizer("bancada: o controle não conectou em 90 s")
                return
            }
            let conectouEm = Date()
            if let bytes = o.roteiroDeBancada {
                correrRoteiro(r, bytes: bytes) { DispatchQueue.main.async { m?.recarregar() } }
            }
            if let p = o.mudarFonte {
                Thread.sleep(forTimeInterval: o.mudarFonteApos)
                let antes = r.estado()?.fonte ?? -1
                r.definirFonte(p)
                DispatchQueue.main.async { m?.recarregar() }
                let ms = esperarConfirmacao(r, prazo: 10).map { String(format: "%.1f ms", $0 * 1000) } ?? "NÃO confirmado em 10 s"
                DiarioDoTeleprompter.dizer("bancada: mudei a fonte de \(antes) para \(p); confirmado em \(ms)")
            }
            if let alvo = o.saltar {
                // O roteiro é o que o prompter já tem: nada de texto sai daqui.
                Thread.sleep(forTimeInterval: 1.5)
                let antes = r.estado()
                r.saltar(alvo)
                DispatchQueue.main.async { m?.recarregar() }
                let ms = esperarConfirmacao(r, prazo: 10).map { String(format: "%.1f ms", $0 * 1000) } ?? "NÃO confirmado em 10 s"
                DiarioDoTeleprompter.dizer("bancada: saltei para \(alvo) (o prompter relatava posicao="
                    + "\(antes?.posicao ?? -1), texto=\(antes?.textoBytes ?? -1) bytes); confirmado em \(ms)")
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 1)
                    if let e = r.estado() {
                        DiarioDoTeleprompter.dizer("bancada: depois do salto, o prompter relata posicao=\(e.posicao) "
                            + "rolando=\(e.rolando) texto=\(e.textoBytes) bytes resumo=\(ResumoDoTexto.de(r.texto()))")
                    }
                }
            }
            if o.pausarESair {
                r.definirRolando(true)
                DispatchQueue.main.async { m?.recarregar() }
                Thread.sleep(forTimeInterval: 1)
                // A pausa sai da thread desta chamada, na hora; a desconexão vem logo atrás, sem
                // esperar confirmação nenhuma. O prompter tem de terminar parado.
                r.definirRolando(false)
                DiarioDoTeleprompter.dizer("bancada: pausei e desconectei na mesma hora (--pausar-e-sair)")
                DispatchQueue.main.async { m?.parar() }
                return
            }
            if let s = o.segundos {
                let resta = s - Date().timeIntervalSince(conectouEm)
                if resta > 0 { Thread.sleep(forTimeInterval: resta) }
                DiarioDoTeleprompter.dizer("bancada: --segundos \(s) cumpridos; desconectando")
                DispatchQueue.main.async { m?.parar() }
            }
        }
        t.name = "quall.teleprompter.bancada"
        t.start()
    }

    private static func correrRoteiro(_ r: ReplicaDoTeleprompter, bytes: Int, recarregar: () -> Void) {
        // Uma marca da corrida na primeira linha: um roteiro idêntico ao da corrida anterior (que
        // ficou no salvo) não seria edição nenhuma, e nada sairia.
        let marca = "Corrida \(Int(Date().timeIntervalSince1970 * 1000))\n"
        let roteiro = marca + sintetico(max(0, bytes - marca.utf8.count))
        let t0 = Date()
        let st = r.definirTexto(roteiro)
        r.definirVelocidade(2.5)
        r.definirRolando(true)
        recarregar()
        DiarioDoTeleprompter.dizer("bancada: roteiro de \(roteiro.utf8.count) bytes (resumo "
            + "\(ResumoDoTexto.de(roteiro))) status=\(SessaoDoTeleprompter.nome(st)) + velocidade 2,5 + rolar")
        // Com a pergunta do texto ligada, o roteiro fica retido até a escolha (a `BancadaDaPergunta`
        // responde "meu"): `sem_confirmacao_ha_ms` nulo não quer dizer que ele chegou (§11.3).
        guard let primeiro = esperarConfirmacao(r, prazo: 30, textoTambem: true) else {
            DiarioDoTeleprompter.dizer("bancada: o roteiro não voltou confirmado em 30 s")
            return
        }
        DiarioDoTeleprompter.dizer(String(format: "bancada: roteiro + velocidade + rolar confirmados em %.1f ms "
                                          + "(desde a edição: %.1f ms)", primeiro * 1000,
                                          Date().timeIntervalSince(t0) * 1000))
        var tempos: [Double] = []
        for i in 0..<20 {
            switch i % 3 {
            case 0: r.definirRolando(i % 2 == 0)
            case 1: r.definirVelocidade(1.0 + Double(i) * 0.1)
            default: r.pular(0.02)
            }
            recarregar()
            guard let ms = esperarConfirmacao(r, prazo: 10) else {
                DiarioDoTeleprompter.dizer("bancada: a edição \(i) não voltou confirmada em 10 s")
                return
            }
            tempos.append(ms * 1000)
            Thread.sleep(forTimeInterval: 0.2)
        }
        tempos.sort()
        DiarioDoTeleprompter.dizer(String(format: "bancada: 20 edições: confirmação p50 %.1f ms, p90 %.1f ms, "
                                          + "máx %.1f ms", tempos[tempos.count / 2],
                                          tempos[tempos.count * 9 / 10], tempos[tempos.count - 1]))
        if let e = r.estado() {
            DiarioDoTeleprompter.dizer("bancada: do prompter: espelho=\(e.espelho) fonte=\(e.fonte) "
                + "margem=\(e.margem) posição=\(e.posicao) texto=\(e.textoBytes) bytes "
                + "resumo=\(ResumoDoTexto.de(r.texto()))")
        }
    }

    /// Espera o estado do outro lado mostrar todas as edições daqui. Devolve quanto levou (s).
    private static func esperarConfirmacao(_ r: ReplicaDoTeleprompter, prazo: Double,
                                           textoTambem: Bool = false) -> Double? {
        let comeco = Date()
        while Date().timeIntervalSince(comeco) < prazo {
            if let e = r.estado(), e.semConfirmacaoHaMs == nil, !textoTambem || e.perguntaDoTexto == nil {
                return Date().timeIntervalSince(comeco)
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return nil
    }

    /// Um roteiro sintético, **nosso**, com acento e emoji, de ~`bytes` bytes. O mesmo texto da
    /// `quall-probe controle` (`crates/quall-probe/src/teleprompter.rs`).
    static func sintetico(_ bytes: Int) -> String {
        var s = ""
        var i = 0
        while s.utf8.count < bytes {
            s += "Linha \(i): boa noite, ação e emoção no teleprompter. 🎬\n"
            i += 1
        }
        while s.utf8.count > bytes { s.removeLast() }
        return s
    }
}
