import Foundation

/// O nome da instância mDNS que o iOS publica sozinho, pela mesma regra do núcleo
/// (`quall_core::discovery::nome_da_instancia`, `docs/contrato-teleprompter.md` §2).
///
/// # Por que existe
///
/// O nome da instância é um **rótulo DNS**: acima de 63 bytes o registro não vale. No núcleo, o
/// `mdns-sd` descartava o registro **em silêncio** e o prompter de nome longo sumia de toda lista
/// (defeito 6 da revisão de 13/09). O iOS não passa pelo núcleo para anunciar
/// (`AnuncianteBonjour`, pelo `mDNSResponder`), então a mesma conta precisa existir aqui — e do
/// mesmo jeito, para o mesmo aparelho não aparecer com dois nomes conforme quem anunciou.
///
/// # A regra, a mesma do núcleo
///
/// - **Com papel**: `"<nome> <papel> <sufixo>"`, com o sufixo tirado do `device_id` (os últimos seis
///   alfanuméricos ASCII, em minúsculas; `"anon"` se não houver nenhum). O papel no nome é o que
///   deixa o mesmo aparelho anunciar vídeo e teleprompter sem colidir.
/// - **Sem papel**: o nome de antes deste arquivo — **só o nome do aparelho**, que é o que o iOS
///   sempre publicou, deixando a colisão para o `mDNSResponder` resolver ("Nome (2)"). Um nome que
///   já cabia sai idêntico ao de antes.
/// - O nome do aparelho é cortado para o total caber em 63 bytes, **numa fronteira de escalar
///   Unicode** (a `is_char_boundary` do Rust), e o espaço que sobrar no fim do corte sai. O nome
///   inteiro continua na chave `n` do TXT, que é o que as listas mostram.
///
/// Função pura, sem sistema nenhum: é testada no MacBook por `Testes/rodar.sh`.
enum NomeDaInstancia {
    /// O teto de um rótulo DNS, em bytes.
    static let teto = 63

    static func montar(nome: String, deviceId: String, papel: String?) -> String {
        guard let papel, !papel.isEmpty else {
            return cortar(nome, cabe: teto)
        }
        let sufixo = sufixoCurto(deviceId)
        let fixo = sufixo.utf8.count + 1 + papel.utf8.count + 1
        let cabe = max(0, teto - fixo)
        return "\(cortar(nome, cabe: cabe)) \(papel) \(sufixo)"
    }

    /// Os últimos seis alfanuméricos ASCII do id, em minúsculas. Nome de host com acento ou espaço
    /// quebra resolvedor em algum lugar da matriz; o id é escolhido pela casca.
    static func sufixoCurto(_ deviceId: String) -> String {
        let limpo = String(String.UnicodeScalarView(deviceId.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0))
        })).lowercased()
        let sufixo = String(limpo.suffix(6))
        return sufixo.isEmpty ? "anon" : sufixo
    }

    /// Corta `texto` para caber em `cabe` bytes de UTF-8, numa fronteira de escalar, e tira o
    /// espaço do fim. Um texto que já cabia volta **inteiro, sem trim** — o nome de antes.
    static func cortar(_ texto: String, cabe: Int) -> String {
        guard texto.utf8.count > cabe else { return texto }
        var escalares = String.UnicodeScalarView()
        var bytes = 0
        for e in texto.unicodeScalars {
            let n = String(e).utf8.count
            if bytes + n > cabe { break }
            escalares.append(e)
            bytes += n
        }
        var fora = escalares
        while let ultimo = fora.last, CharacterSet.whitespacesAndNewlines.contains(ultimo) {
            fora.removeLast()
        }
        return String(fora)
    }
}
