import Foundation

/// **O editor do roteiro, e o texto que chega do outro lado enquanto ele está aberto.**
///
/// O contrato deixa a regra para a tela: "um texto que chega do outro lado enquanto o usuário edita
/// (bit `_TEXT`) é assunto da tela: o núcleo não mistura" (§6). A regra desta tela, nos dois papéis:
///
/// 1. **O rascunho nunca é tocado por fora.** O que a pessoa digitou não some nem muda sob o cursor
///    porque o outro aparelho confirmou uma edição.
/// 2. **Sem conflito, sem pergunta.** Se a pessoa ainda não mudou nada (o rascunho é igual ao texto
///    de quando o editor abriu), o texto novo simplesmente entra no editor, com uma nota discreta.
/// 3. **Com conflito, avisar e deixar escolher.** Se ela já mudou algo, aparece o aviso "o texto
///    mudou no outro aparelho enquanto você editava", com duas saídas:
///    - **Usar o texto novo**: o rascunho é trocado pelo texto que chegou, e o rascunho descartado
///      vai para a área de transferência (nada do que a pessoa digitou se perde sem ela saber);
///    - **Manter o meu**: o aviso some; ao confirmar, o texto dela é mandado e — sendo a edição mais
///      recente — vence nos dois aparelhos, pela regra do usuário ("vale o último que mudou").
/// 4. **Confirmar é o único envio** (`set_text` só ao confirmar, §6). Confirmar com um aviso aberto
///    é "manter o meu": o aviso diz isso antes.
///
/// A fusão por caractere não está no contrato (§3): o texto vencedor entra inteiro. Esta regra não
/// finge o contrário — ela só garante que ninguém perde o que digitou sem escolher.
public struct RascunhoDoTexto: Equatable, Sendable {
    /// O texto de quando o editor abriu, ou do último "usar o texto novo".
    public private(set) var base: String
    /// O que está no editor.
    public var rascunho: String
    /// O texto que chegou do outro lado **em conflito** com o rascunho, esperando a escolha.
    public private(set) var textoNovoDoOutroLado: String?
    /// O texto do outro lado entrou sozinho (sem conflito) — para a nota discreta.
    public private(set) var atualizadoPeloOutroLado = false

    public init(textoAtual: String) {
        base = textoAtual
        rascunho = textoAtual
    }

    /// A pessoa mudou alguma coisa desde que o editor abriu (ou desde "usar o texto novo").
    public var alterado: Bool { rascunho != base }
    public var emConflito: Bool { textoNovoDoOutroLado != nil }

    /// Chegou `_TEXT` com o editor aberto, e este é o texto da réplica agora.
    public mutating func chegou(textoNovo: String) {
        if textoNovo == base && !emConflito { return }
        if !alterado && !emConflito {
            base = textoNovo
            rascunho = textoNovo
            atualizadoPeloOutroLado = true
            return
        }
        // Com conflito (inclusive um segundo texto chegando antes da escolha): guarda o mais novo.
        // Se o outro lado chegou exatamente ao que a pessoa está escrevendo, não há o que escolher.
        if textoNovo == rascunho {
            base = textoNovo
            textoNovoDoOutroLado = nil
            return
        }
        textoNovoDoOutroLado = textoNovo
    }

    /// **Usar o texto novo.** Devolve o rascunho descartado (para a área de transferência), ou
    /// `nil` se não havia conflito.
    public mutating func usarOTextoNovo() -> String? {
        guard let novo = textoNovoDoOutroLado else { return nil }
        let descartado = rascunho
        base = novo
        rascunho = novo
        textoNovoDoOutroLado = nil
        atualizadoPeloOutroLado = true
        return descartado
    }

    /// **Manter o meu.** O aviso some; o rascunho continua, e confirmar o manda.
    public mutating func manterOMeu() {
        guard let novo = textoNovoDoOutroLado else { return }
        // A base passa a ser o texto do outro lado: é contra ele que "alterado" se mede agora, e um
        // terceiro texto que chegue depois volta a perguntar.
        base = novo
        textoNovoDoOutroLado = nil
    }

    /// O texto a mandar para `set_text` ao confirmar, ou `nil` quando não há o que mandar (o
    /// rascunho já é o texto da réplica). NUL é tirado: a fronteira recusaria o texto inteiro
    /// (`QUALL_STATUS_INVALID`), e um NUL colado de outro programa não é nada que a pessoa veja.
    public func paraConfirmar(textoDaReplica: String) -> String? {
        let limpo = rascunho.replacingOccurrences(of: "\u{0}", with: "")
        return limpo == textoDaReplica ? nil : limpo
    }

    /// Bytes de UTF-8 do rascunho, contra o teto de `quall_teleprompter_max_text_bytes`.
    public var bytes: Int { rascunho.utf8.count }
}

/// **O endereço do prompter** que a pessoa digita ou cola no controle.
///
/// Aceita `host:porta` (o que a tela do prompter mostra) e o link `quall://<pin>@<host:porta>`.
/// Nenhuma tela gera mais esse link — ele vinha no QR, que saiu em 24/09/2026 por decisão do Pessoa Exemplo —,
/// mas a leitura fica: um link colado de uma versão antiga e o `--prompter=` da bancada ainda o usam,
/// e ele traz o PIN junto.
public struct EnderecoDoPrompter: Equatable, Sendable {
    public var endereco: String
    public var pin: String?

    public static func ler(_ digitado: String) -> EnderecoDoPrompter? {
        var t = digitado.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var pin: String?
        if t.lowercased().hasPrefix("quall://") {
            t = String(t.dropFirst("quall://".count))
            if let arroba = t.lastIndex(of: "@") {
                let antes = String(t[t.startIndex..<arroba]).trimmingCharacters(in: .whitespaces)
                pin = antes.isEmpty ? nil : antes
                t = String(t[t.index(after: arroba)...])
            }
            while t.hasSuffix("/") { t.removeLast() }
        }
        t = t.replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return nil }
        return EnderecoDoPrompter(endereco: t, pin: pin)
    }
}
