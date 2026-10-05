// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation

@main
enum TestesDaSanitizacao {
    static func main() {
        var verificacoes = 0
        func conferir(_ condicao: Bool, _ caso: String) {
            verificacoes += 1
            if !condicao { fatalError("Sanitização falhou: \(caso)") }
        }
        let segredo = "NAO RETENHA ESTE VALOR SINTETICO 314159"
        let campos = ["pin", "PIN", "secret", "segredo", "senha", "private_key", "public_key",
                      "shared_secret", "nonce", "mac", "proof", "ice_pwd", "ice_ufrag", "ufrag",
                      "pinDoPrompter", "pin_do_prompter", "authorization"]
        let formas = ["\"\(segredo)\"", "'\(segredo)'", "\"\(segredo)", "'\(segredo)",
                      "[\"\(segredo)\"]", "[[1], [\"\(segredo)\"]]", "[[1], [\"\(segredo)\"",
                      "{\"interno\": \"\(segredo)\"}", "{\"interno\": \"\(segredo)", segredo,
                      "\"prefixo \\\"escapado\\\" \(segredo)\"", "[1, [2, \"\(segredo)"]
        for campo in campos {
            for (i, forma) in formas.enumerated() {
                let texto = "status=PAIRING 🟣 \"\(campo)\": \(forma)"
                let log = SanitizacaoDoLog.mensagem(texto)
                conferir(!log.contains("RETENHA") && !log.contains("VALOR") && !log.contains("314159"),
                         "campo \(campo), forma \(i), inclusive fragmentos")
                conferir(log.contains("status=PAIRING"), "status preservado, \(campo)/\(i)")
                conferir(SanitizacaoDoLog.mensagem(log) == log, "idempotência, \(campo)/\(i)")
            }
        }
        let completo = #"{"secret":"valor sintético", "pin":"123456", "falhas":0, "codec":"pcmu", "taxa":8000}"#
        let completoSeguro = SanitizacaoDoLog.mensagem(completo)
        conferir(completoSeguro.contains(#""falhas":0"#) && completoSeguro.contains(#""codec":"pcmu""#), "métricas após credenciais completas")
        let rede = ["192.168.55.9:17893", "10.77.1.4", "127.0.0.1", "[2001:db8::1]:17893",
                    "fe80::42%en0", "::1", "::ffff:192.168.55.9", "2001:0db8:0000:0000:0000:ff00:0042:8329",
                    "iphone-de-teste.local:17893", "https://conta:senha@example.org/pasta/secreta",
                    "file:///private/var/mobile/Containers/Data/meu-video.mp4"]
        for endereco in rede {
            let log = SanitizacaoDoLog.mensagem("não conectou: \(endereco); status=IO")
            conferir(!log.contains(endereco), "endereço removido")
            conferir(log.contains("status=IO"), "status após endereço")
        }
        let pessoais = [#"nome="Pessoa da Bancada""#, #"par="Pessoa da Bancada""#,
                        #"display_name="Pessoa da Bancada""#, #"autor="Pessoa da Bancada""#,
                        #"nome="Pessoa da Bancada"#, "nome=Pessoa da Bancada"]
        for entrada in pessoais { conferir(!SanitizacaoDoLog.mensagem(entrada).contains("Pessoa"), "nome removido") }
        for pin in ["com o PIN 123456", "PIN novo 123 456", "PIN inválido '123456'", "--pin 123-456"] {
            conferir(!SanitizacaoDoLog.mensagem(pin).contains("123"), "PIN em prosa")
        }
        let valores = [String(repeating: "a", count: 64), String(repeating: "AbCd12+/", count: 8),
                       "ABCDEF12-1234-5678-9ABC-DEF012345678/L0/001", "ios-abcdef12",
                       "/Users/pessoa-exemplo/Movies/arquivo.mp4", "resumo=abcdef0123456789"]
        for valor in valores { conferir(SanitizacaoDoLog.mensagem(valor) != valor, "material/identificador/caminho removido") }
        let medidas = "codec=pcmu taxa=8000 canais=1 slots=1085 falhas=0 bitrate=128000 rms=0.3544 tom_verde=sim memória=104857600"
        conferir(SanitizacaoDoLog.mensagem(medidas) == medidas, "métricas intactas")
        conferir(SanitizacaoDoLog.causaExterna("texto livre \(segredo)") == "detalhe externo omitido", "erro externo arbitrário")
        conferir(SanitizacaoDoLog.causaExterna("connection refused: \(segredo)") == "conexão recusada", "categoria externa")
        conferir(SanitizacaoDoLog.causaExterna("falha (os error 61) \(segredo)") == "erro do sistema=61", "errno")
        conferir(SanitizacaoDoLog.causaExterna("os error 314159") == "detalhe externo omitido", "PIN disfarçado como errno")
        let erro = NSError(domain: NSCocoaErrorDomain, code: 513,
                           userInfo: [NSLocalizedDescriptionKey: segredo, NSFilePathErrorKey: "/Users/pessoa-exemplo/video.mp4"])
        conferir(SanitizacaoDoLog.erro(erro) == "domínio=NSCocoaErrorDomain código=513", "NSError sem descrição/userInfo")
        conferir(SanitizacaoDoLog.erro(NSError(domain: segredo, code: -3)) == "domínio=outro código=-3", "domínio externo")
        conferir(SanitizacaoDoLog.codigoRemoto(segredo) == "código externo omitido", "recusa arbitrária")
        conferir(SanitizacaoDoLog.codigoRemoto("fora_da_faixa") == "fora_da_faixa", "causa de recusa conhecida")
        print("PASSOU: \(verificacoes) verificações de sanitização, sem rede, mídia ou aparelho.")
    }
}
