import Foundation

/// **O estado para a tela**, lido do JSON de `quall_teleprompter_state_json`
/// (`docs/contrato-teleprompter.md` §6). Os nomes das chaves são os do contrato, literais.
///
/// # Tolerante de propósito
///
/// A leitura é campo a campo, e um campo que falta ou não se lê fica no padrão da tabela da §3 —
/// a mesma regra que o núcleo aplica na chegada ("cada campo é lido sozinho, então um `null` não
/// derruba o estado inteiro"). Uma casca que recusasse o estado inteiro por um contador novo que
/// ela não conhece (o contrato acrescenta campos sem subir o `v`) congelaria a tela. A leitura só
/// falha quando o texto nem é um objeto JSON.
public struct EstadoDoTeleprompter: Equatable, Sendable {
    public var rolando = false
    public var velocidade = 1.0
    public var fonte = 48.0
    public var margem = 0.1
    public var linhaDeLeitura = 0.3
    public var espelho = false
    public var posicao = 0.0
    /// O alvo do salto mais recente; `nil` se nunca houve salto.
    public var salto: Double?
    public var textoBytes = 0
    /// Há quantos ms chegou a última mensagem do outro lado **nesta sessão**; `nil` se nada chegou
    /// (e depois de `quall_teleprompter_peer_lost`).
    public var parVistoHaMs: UInt64?
    /// Há quantos ms existe uma edição daqui que o outro lado ainda não confirmou.
    public var semConfirmacaoHaMs: UInt64?
    /// "Segurar para rolar" (§12): com `rolando`, o prompter rola **para trás** e para no começo.
    public var paraTras = false
    /// O dedo no botão do controle (§12). Volta a `false` sozinho na queda, no silêncio de 2,5 s e
    /// na pausa do prompter — e aí o texto parou.
    public var segurando = false
    /// O outro lado disse, no último estado dele, que entende o segurar (§12.2). O controle só
    /// segura com isto.
    public var parEntendeSegurar = false
    /// `"pergunta_do_texto"` (§11.6): `nil` sem nada retido — e sempre `nil` sem a trava (§11.10).
    public var perguntaDoTexto: PerguntaDoTexto?
    /// `"copias_do_texto"` (§11.5): até três, a mais nova primeiro.
    public var copiasDoTexto: [CopiaDoTexto] = []
    public var contadores = Contadores()

    // MARK: a gravação (§13, R5)

    /// `"gravando_ha_ms"` (§13.1): há quanto tempo o prompter grava, no relógio dele; `nil` parado.
    public var gravandoHaMs: UInt64?
    /// `"pedido_de_gravacao"` (§13.7): no prompter, o pedido que a casca decide; no controle, o daqui
    /// sem resposta.
    public var pedidoDeGravacao: PedidoDeGravacao?
    /// `"gravacao_recusada"` (§13.3): no controle, a do último pedido dele; no prompter, a última que
    /// ele deu nesta sessão.
    public var gravacaoRecusada: RecusaDeGravacao?
    /// `"par_entende_gravar"` (§13.5): o prompter do outro lado diz que grava. O controle só mostra o
    /// botão Gravar com isto.
    public var parEntendeGravar = false

    public struct PedidoDeGravacao: Equatable, Sendable {
        public var n: UInt64
        public var gravar: Bool
        public var haMs: UInt64
        public init(n: UInt64, gravar: Bool, haMs: UInt64) {
            self.n = n
            self.gravar = gravar
            self.haMs = haMs
        }
    }

    public struct RecusaDeGravacao: Equatable, Sendable {
        public var n: UInt64
        public var gravar: Bool
        public var motivo: String
        public init(n: UInt64, gravar: Bool, motivo: String) {
            self.n = n
            self.gravar = gravar
            self.motivo = motivo
        }
    }

    public struct Contadores: Equatable, Sendable {
        public var estadosEnviados: UInt64 = 0
        public var textosEnviados: UInt64 = 0
        public var recebidas: UInt64 = 0
        public var invalidas: UInt64 = 0
        public var deOutroApp: UInt64 = 0
        public var deOutraVersao: UInt64 = 0
        public var camposRecusados: UInt64 = 0
        public var carimbosDoFuturo: UInt64 = 0
        public var mensagensImpossiveis: UInt64 = 0
        public var reenviosDesistidos: UInt64 = 0
        public init() {}
    }

    public init() {}

    /// As faixas da §3. Ficam aqui para a tela desenhar os controles com os limites que o núcleo
    /// aplica — um controle que deixasse passar 25 linhas/s receberia `QUALL_STATUS_INVALID` e
    /// ficaria parado sem dizer por quê.
    public static let faixaDaVelocidade: ClosedRange<Double> = 0.05...20
    public static let faixaDaFonte: ClosedRange<Double> = 8...400
    public static let faixaDaMargem: ClosedRange<Double> = 0...0.45
    public static let faixaDaLinha: ClosedRange<Double> = 0...1

    /// Lê o JSON do núcleo. `nil` só quando o texto nem é um objeto JSON.
    public static func doJSON(_ texto: String) -> EstadoDoTeleprompter? {
        guard let dados = texto.data(using: .utf8),
              let bruto = try? JSONSerialization.jsonObject(with: dados),
              let o = bruto as? [String: Any] else { return nil }
        var e = EstadoDoTeleprompter()
        if let v = booleano(o["rolando"]) { e.rolando = v }
        if let v = numero(o["velocidade"]) { e.velocidade = v }
        if let v = numero(o["fonte"]) { e.fonte = v }
        if let v = numero(o["margem"]) { e.margem = v }
        if let v = numero(o["linha_de_leitura"]) { e.linhaDeLeitura = v }
        if let v = booleano(o["espelho"]) { e.espelho = v }
        if let v = numero(o["posicao"]) { e.posicao = v }
        e.salto = numero(o["salto"])
        if let v = inteiro(o["texto_bytes"]) { e.textoBytes = Int(v) }
        e.parVistoHaMs = inteiro(o["par_visto_ha_ms"])
        e.semConfirmacaoHaMs = inteiro(o["sem_confirmacao_ha_ms"])
        if let v = booleano(o["para_tras"]) { e.paraTras = v }
        if let v = booleano(o["segurando"]) { e.segurando = v }
        if let v = booleano(o["par_entende_segurar"]) { e.parEntendeSegurar = v }
        if let p = o["pergunta_do_texto"] as? [String: Any] { e.perguntaDoTexto = pergunta(p) }
        if let lista = o["copias_do_texto"] as? [Any] {
            e.copiasDoTexto = lista.compactMap { ($0 as? [String: Any]).flatMap(copia) }
        }
        e.gravandoHaMs = inteiro(o["gravando_ha_ms"])
        if let p = o["pedido_de_gravacao"] as? [String: Any], let n = inteiro(p["n"]), let g = booleano(p["gravar"]) {
            e.pedidoDeGravacao = PedidoDeGravacao(n: n, gravar: g, haMs: inteiro(p["ha_ms"]) ?? 0)
        }
        if let r = o["gravacao_recusada"] as? [String: Any], let n = inteiro(r["n"]) {
            e.gravacaoRecusada = RecusaDeGravacao(n: n, gravar: booleano(r["gravar"]) ?? true,
                                                  motivo: r["motivo"] as? String ?? "")
        }
        if let v = booleano(o["par_entende_gravar"]) { e.parEntendeGravar = v }
        if let c = o["contadores"] as? [String: Any] {
            e.contadores.estadosEnviados = inteiro(c["estados_enviados"]) ?? 0
            e.contadores.textosEnviados = inteiro(c["textos_enviados"]) ?? 0
            e.contadores.recebidas = inteiro(c["recebidas"]) ?? 0
            e.contadores.invalidas = inteiro(c["invalidas"]) ?? 0
            e.contadores.deOutroApp = inteiro(c["de_outro_app"]) ?? 0
            e.contadores.deOutraVersao = inteiro(c["de_outra_versao"]) ?? 0
            e.contadores.camposRecusados = inteiro(c["campos_recusados"]) ?? 0
            e.contadores.carimbosDoFuturo = inteiro(c["carimbos_do_futuro"]) ?? 0
            e.contadores.mensagensImpossiveis = inteiro(c["mensagens_impossiveis"]) ?? 0
            e.contadores.reenviosDesistidos = inteiro(c["reenvios_desistidos"]) ?? 0
        }
        return e
    }

    /// A pergunta, campo a campo como o resto: um lado ilegível fica nulo (e a caixa não abre com
    /// ele), e não derruba o estado.
    private static func pergunta(_ o: [String: Any]) -> PerguntaDoTexto? {
        guard let aberta = booleano(o["aberta"]) else { return nil }
        func lado(_ v: Any?) -> LadoDaPergunta? {
            guard let l = v as? [String: Any], let bytes = inteiro(l["bytes"]),
                  let resumo = l["resumo"] as? String else { return nil }
            return LadoDaPergunta(bytes: Int(bytes), resumo: resumo, previa: l["previa"] as? String ?? "")
        }
        return PerguntaDoTexto(aberta: aberta, retidoHaMs: inteiro(o["retido_ha_ms"]) ?? 0,
                               prompterId: o["prompter_id"] as? String ?? "",
                               prompterNome: o["prompter_nome"] as? String ?? "",
                               meu: lado(o["meu"]), doPrompter: lado(o["do_prompter"]))
    }

    /// Uma cópia sem resumo não se pode ver, usar nem apagar: fica de fora.
    private static func copia(_ o: [String: Any]) -> CopiaDoTexto? {
        guard let resumo = o["resumo"] as? String, !resumo.isEmpty else { return nil }
        let origem: OrigemDaCopia
        switch o["origem"] as? String {
        case "prompter": origem = .prompter
        case "controle": origem = .controle
        case let outra?: origem = .outra(outra)
        case nil: origem = .outra("")
        }
        return CopiaDoTexto(origem: origem, prompterId: o["prompter_id"] as? String ?? "",
                            prompterNome: o["prompter_nome"] as? String ?? "",
                            quandoMs: inteiro(o["quando_ms"]) ?? 0, bytes: Int(inteiro(o["bytes"]) ?? 0),
                            resumo: resumo, previa: o["previa"] as? String ?? "")
    }

    /// `JSONSerialization` devolve `NSNumber` para número **e** para booleano; um `true` lido como
    /// número daria 1,0 e um `1` lido como booleano daria `true`. Os dois são separados pelo tipo
    /// de verdade do `NSNumber`, e o que não é do tipo pedido é tratado como ausente.
    private static func ehBooleano(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func numero(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !ehBooleano(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func inteiro(_ v: Any?) -> UInt64? {
        guard let n = v as? NSNumber, !ehBooleano(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0 else { return nil }
        return n.uint64Value
    }

    private static func booleano(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, ehBooleano(n) else { return nil }
        return n.boolValue
    }
}

/// **Os bits de `changed`** (`QuallTeleprompterChange`): o que mudou **por causa do outro lado**.
///
/// Os valores são os do contrato (§6) e são ABI. A ponte com a fronteira C (`QuallNetKit`) não
/// confia nesta tabela: ela traduz bit a bit pelas constantes do `quall.h`, então um valor errado
/// aqui não passaria em silêncio — só deixaria de acender um bit, e o teste
/// `os_bits_sao_os_do_contrato` pega isso antes.
public struct MudancasDoTeleprompter: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let texto = MudancasDoTeleprompter(rawValue: 1)
    public static let rolando = MudancasDoTeleprompter(rawValue: 2)
    public static let velocidade = MudancasDoTeleprompter(rawValue: 4)
    public static let fonte = MudancasDoTeleprompter(rawValue: 8)
    public static let margem = MudancasDoTeleprompter(rawValue: 16)
    public static let linhaDeLeitura = MudancasDoTeleprompter(rawValue: 32)
    public static let espelho = MudancasDoTeleprompter(rawValue: 64)
    /// O relato de posição do prompter. **Quem mostra o texto ignora**; o controle desenha.
    public static let posicao = MudancasDoTeleprompter(rawValue: 128)
    /// Um salto novo: quem mostra o texto vai até `salto` e chama `set_position` com ele.
    public static let salto = MudancasDoTeleprompter(rawValue: 256)
    /// O contato com o outro lado mudou: releia `par_visto_ha_ms` e `sem_confirmacao_ha_ms`.
    public static let par = MudancasDoTeleprompter(rawValue: 512)
    /// Mudou `"pergunta_do_texto"` (§11.6): abriu, entrou em "comparando", o texto do prompter nela
    /// mudou, ou fechou. A caixa relê.
    public static let perguntaDoTexto = MudancasDoTeleprompter(rawValue: 1024)
    /// Há cópia nova do roteiro: **grave o salvo agora** (§11.5).
    public static let copiaDoTexto = MudancasDoTeleprompter(rawValue: 2048)
    /// Mudou `para_tras` ou `segurando` (§12). Quem mostra o texto relê `rolando` e `para_tras`; o
    /// controle relê `segurando`.
    public static let segurar = MudancasDoTeleprompter(rawValue: 4096)
    /// A gravação (§13). No prompter: chegou um pedido do controle (`"pedido_de_gravacao"`). No
    /// controle: a gravação começou ou parou, o pedido daqui foi respondido, ou o prompter passou a
    /// dizer (ou deixou de dizer) que grava.
    public static let gravacao = MudancasDoTeleprompter(rawValue: 8192)

    /// O que muda o desenho do texto no prompter (e pede um novo layout).
    public static let layout: MudancasDoTeleprompter = [.texto, .fonte, .margem]

    /// Os nomes, para o registro: um bit que acende aparece por extenso, e não como número.
    public var nomes: [String] {
        var n: [String] = []
        if contains(.texto) { n.append("texto") }
        if contains(.rolando) { n.append("rolando") }
        if contains(.velocidade) { n.append("velocidade") }
        if contains(.fonte) { n.append("fonte") }
        if contains(.margem) { n.append("margem") }
        if contains(.linhaDeLeitura) { n.append("linha") }
        if contains(.espelho) { n.append("espelho") }
        if contains(.posicao) { n.append("posicao") }
        if contains(.salto) { n.append("salto") }
        if contains(.par) { n.append("par") }
        if contains(.perguntaDoTexto) { n.append("pergunta") }
        if contains(.copiaDoTexto) { n.append("copia") }
        if contains(.segurar) { n.append("segurar") }
        if contains(.gravacao) { n.append("gravacao") }
        let conhecidos: UInt32 = 1023 | MudancasDoTeleprompter.perguntaDoTexto.rawValue
            | MudancasDoTeleprompter.copiaDoTexto.rawValue | MudancasDoTeleprompter.segurar.rawValue
            | MudancasDoTeleprompter.gravacao.rawValue
        if rawValue & ~conhecidos != 0 { n.append("desconhecido(\(rawValue & ~conhecidos))") }
        return n
    }
}
