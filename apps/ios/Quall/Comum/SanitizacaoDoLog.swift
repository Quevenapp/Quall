import Foundation

/// Última barreira antes de os_log, stdout e arquivo. Vale igualmente em Debug e Release.
/// Os pontos de chamada evitam incluir dados pessoais; estas regras cobrem também mensagens
/// de erro externas. Nenhum valor removido recebe hash ou identificador persistente.
public enum SanitizacaoDoLog {
    private static let campoSecreto = try? NSRegularExpression(pattern:
        #"(?i)[\"']?\b(?:pin|pinDoPrompter|pin_do_prompter|secret|segredo|password|senha|private_key|public_key|shared_secret|chave|token|nonce|mac|proof|authorization|ice_pwd|ice_ufrag|ufrag)\b[\"']?\s*[:=][ \t]*"#)
    private static let campoPessoal = try? NSRegularExpression(pattern:
        #"(?i)[\"']?\b(?:display_name|device_id|deviceId|peer_id|nomeDaCamera|prompterNome|prompterId|nome|autor|author|label|rotulo|rótulo|par)\b[\"']?\s*[:=][ \t]*"#)
    private static let regras: [(NSRegularExpression, String)]? = {
        let padroes: [(String, String)] = [
            (#"(?i)(\bPIN\b\s*(?:novo\s*|inválido\s*|malformado\s*)?[=:]?\s*)[\"']?\d(?:[\d -]*\d)?[\"']?"#, "$1[oculto]"),
            // Material de chave em hex/base64 mesmo quando uma falha não conserva o rótulo.
            (#"(?<![\w])[a-fA-F0-9]{32,}(?![\w])"#, "[oculto]"),
            (#"(?<![\w])[A-Za-z0-9+/]{40,}={0,2}(?![\w])"#, "[oculto]"),
            // URLs podem incluir senha, host, caminho ou nome de arquivo.
            (#"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"<>]+"#, "[endereço]"),
            // IPv6 completo, comprimido, com zona, entre colchetes ou IPv4 mapeado.
            (#"(?i)(?<![a-z0-9])\[?(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.]*(?:%[a-z0-9_.-]+)?(?:\](?::\d+)?)?"#, "[endereço]"),
            (#"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?![\w.])"#, "[endereço]"),
            (#"(?i)\b[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.local\b(?::\d+)?"#, "[endereço]"),
            // IDs de aparelhos e de itens do Fotos; nenhum hash substitui o valor original.
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b(?:/[^\s,;)]+)?"#, "[identificador]"),
            (#"(?i)\b(?:ios|ios-rx|rx-ios)-[a-z0-9-]+\b"#, "[identificador]"),
            // IDs personalizados que aparecem nos erros atuais de pareamento do núcleo.
            (#"(?i)(aparelho\s+).+?(\s+não está pareado aqui)"#, "$1[identificador]$2"),
            (#"(?i)(segredo carregado é do aparelho\s+).+?(,\s*não de\s+).+?(?=[;)\n]|$)"#, "$1[identificador]$2[identificador]"),
            // Caminhos externos podem conter nome de usuário ou nomes de mídia.
            (#"(?<![a-zA-Z0-9])/(?:[^\s\"<>])+"#, "[arquivo]"),
            // Resumos de texto são fingerprints do roteiro e não são necessários ao diagnóstico.
            (#"(?i)(\bresumo[ =]+)[a-f0-9]{16}\b"#, "$1[oculto]")
        ]
        var compiladas: [(NSRegularExpression, String)] = []
        for (padrao, troca) in padroes {
            guard let expressao = try? NSRegularExpression(pattern: padrao) else { return nil }
            compiladas.append((expressao, troca))
        }
        return compiladas
    }()

    public static func mensagem(_ texto: String) -> String {
        guard let regras, let campoSecreto, let campoPessoal else { return "[diagnóstico removido: regra inválida]" }
        let semSegredos = ocultarCampos(texto, expressao: campoSecreto, marcador: "[oculto]")
        let semIdentificadores = ocultarCampos(semSegredos, expressao: campoPessoal, marcador: "[identificador]")
        return regras.reduce(semIdentificadores) { linha, regra in
            regra.0.stringByReplacingMatches(in: linha, range: NSRange(linha.startIndex..., in: linha),
                                             withTemplate: regra.1)
        }
    }

    /// Delimitadores completos conservam os campos seguintes. Aspas, objetos ou arrays
    /// incompletos retiram o restante da linha, incluindo espaços e containers aninhados.
    /// Um segredo sem delimitador também retira o resto: não supõe que acaba na primeira palavra.
    private static func ocultarCampos(_ texto: String, expressao: NSRegularExpression, marcador: String) -> String {
        let s = texto as NSString
        var faixas: [NSRange] = []
        for campo in expressao.matches(in: texto, range: NSRange(location: 0, length: s.length)) {
            let inicio = NSMaxRange(campo.range)
            var fimDaLinha = inicio
            while fimDaLinha < s.length, s.character(at: fimDaLinha) != 10,
                  s.character(at: fimDaLinha) != 13 { fimDaLinha += 1 }
            var fim = fimDaLinha
            if inicio < fimDaLinha {
                let primeiro = s.character(at: inicio)
                if primeiro == 34 || primeiro == 39 || primeiro == 91 || primeiro == 123 {
                    var quote: unichar? = primeiro == 34 || primeiro == 39 ? primeiro : nil
                    var esperado: [unichar] = primeiro == 91 ? [93] : primeiro == 123 ? [125] : []
                    var escapado = false
                    var i = inicio + 1
                    while i < fimDaLinha {
                        let c = s.character(at: i)
                        if let q = quote {
                            if escapado { escapado = false }
                            else if c == 92 { escapado = true }
                            else if c == q {
                                quote = nil
                                if esperado.isEmpty { fim = i + 1; break }
                            }
                        } else if c == 34 || c == 39 { quote = c }
                        else if c == 91 { esperado.append(93) }
                        else if c == 123 { esperado.append(125) }
                        else if c == 93 || c == 125 {
                            guard esperado.last == c else { break }
                            esperado.removeLast()
                            if esperado.isEmpty { fim = i + 1; break }
                        }
                        i += 1
                    }
                }
            }
            let faixa = NSRange(location: inicio, length: fim - inicio)
            if let anterior = faixas.last, NSMaxRange(anterior) >= inicio {
                faixas[faixas.count - 1] = NSUnionRange(anterior, faixa)
            } else { faixas.append(faixa) }
        }
        let resultado = NSMutableString(string: texto)
        for faixa in faixas.reversed() { resultado.replaceCharacters(in: faixa, with: marcador) }
        return resultado as String
    }

    /// Mensagens do núcleo podem conter prosa recebida do par. Só categorias conhecidas e
    /// códigos numéricos do sistema podem ser publicados; o chamador registra também o status.
    public static func causaExterna(_ texto: String) -> String {
        let minusculo = texto.lowercased()
        let causas = [
            ("parado aqui", "parado aqui"),
            ("a sessão fechou", "sessão fechada"),
            ("o outro lado saiu", "outro lado desconectou"),
            ("o transporte falhou", "transporte falhou"),
            ("o núcleo não deu o handle de mensagens", "handle de mensagens indisponível"),
            ("a bombeada falhou", "bombeada falhou"),
            ("o arquivo falhou", "arquivo falhou"),
            ("o arquivo não abriu", "arquivo não abriu"),
            ("o arquivo não começou", "arquivo não começou"),
            ("o arquivo não fechou", "arquivo não fechou"),
            ("o arquivo não aceitou as trilhas", "trilhas recusadas"),
            ("a câmera não está entregando imagem", "câmera sem imagem"),
            ("a câmera parou de entregar imagem", "câmera sem imagem"),
            ("câmera interrompida", "câmera interrompida"),
            ("sem espaço", "sem espaço"),
            ("o aparelho esquentou", "temperatura alta"),
            ("o botão parar", "botão Parar"),
            ("pedido do controle remoto", "pedido remoto"),
            ("address already in use", "porta em uso"),
            ("connection refused", "conexão recusada"),
            ("network is unreachable", "rede inacessível"),
            ("no route to host", "sem rota"),
            ("timed out", "tempo esgotado"),
            ("prazo esgotou", "tempo esgotado"),
            ("tempo esgotou", "tempo esgotado"),
            ("não está pareado aqui", "pareamento ausente"),
            ("segredo carregado é do aparelho", "pareamento de outro aparelho"),
            ("sem segredo guardado", "pareamento ausente")
        ]
        for (trecho, categoria) in causas where minusculo.contains(trecho) { return categoria }
        if let expressao = try? NSRegularExpression(pattern: #"\bos error (-?\d{1,10})\b"#),
           let achado = expressao.firstMatch(in: texto, range: NSRange(texto.startIndex..., in: texto)),
           let faixa = Range(achado.range(at: 1), in: texto),
           let codigo = Int(texto[faixa]), (-4095...4095).contains(codigo) {
            // Não permitir que prosa remota disfarce um PIN de seis dígitos como errno.
            return "erro do sistema=\(codigo)"
        }
        return "detalhe externo omitido"
    }

    /// Erros Apple podem carregar URL, nome de mídia ou identificador em userInfo.
    /// Os códigos permanecem; a descrição e userInfo nunca entram no log.
    public static func erro(_ erro: Error) -> String {
        let e = erro as NSError
        let conhecidos: Set<String> = ["NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain",
                                       "AVFoundationErrorDomain", "PHPhotosErrorDomain", "NSURLErrorDomain"]
        return "domínio=\(conhecidos.contains(e.domain) ? e.domain : "outro") código=\(e.code)"
    }

    public static func codigoRemoto(_ codigo: String) -> String {
        let conhecidos: Set<String> = ["nao_aplicado", "invalido", "campo_desconhecido", "fora_da_imagem", "fora_da_faixa", "incoerente",
                                       "sem_camera", "ocupado", "nao_permitido", "nao_pareado", "camera_trocada",
                                       "superado", "sem_resposta", "esperando", "pronto"]
        return conhecidos.contains(codigo) ? codigo : "código externo omitido"
    }
}
