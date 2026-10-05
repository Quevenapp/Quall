import Foundation

var casos = 0
var falhas = 0
func conferir(_ nome: String, _ passou: Bool) {
    casos += 1
    if !passou { falhas += 1 }
    print("\(passou ? "PASS" : "FAIL") \(nome)")
}
func sem(_ saida: String, _ proibidos: [String]) -> Bool {
    !proibidos.contains(where: saida.contains)
}

let segredo = "SEGREDO-SINTETICO-XYZ"
for campo in ["PIN", "senha", "password", "private_key", "session_key", "secret", "token", "ufrag", "ice-pwd", "nonce", "mac"] {
    let saida = RegistroSeguro.texto("status=7 \(campo)=\(segredo) frames=93")
    conferir("segredo-\(campo)", sem(saida, [segredo]) && saida.contains("status=7") && saida.contains("frames=93"))
}
conferir("segredo-chave-aspas", sem(RegistroSeguro.texto("\"password\": \"\(segredo)\" status=3"), [segredo]))
conferir("passphrase-com-espacos", sem(RegistroSeguro.texto("passphrase=\(segredo) SEGUNDA-PARTE status=3"), [segredo, "SEGUNDA-PARTE"]) && RegistroSeguro.texto("passphrase=\(segredo) SEGUNDA-PARTE status=3").contains("status=3"))
conferir("JSON-inteiro", sem(RegistroSeguro.texto("dados={\"pares\":{\"PAR-SINTETICO\":{\"secret\":\"\(segredo)\"}}} rc=5"), [segredo, "PAR-SINTETICO"]))
conferir("JSON-incompleto", sem(RegistroSeguro.texto("dados={\"secret\":\"\(segredo)"), [segredo]))
conferir("JSON-lista-strings", sem(RegistroSeguro.texto("dados=[\"PAR-SINTETICO\",\"\(segredo)\"] status=7"), [segredo, "PAR-SINTETICO"]))
conferir("PEM", sem(RegistroSeguro.texto("-----BEGIN PRIVATE KEY-----\n\(segredo)\n-----END PRIVATE KEY----- status=7"), [segredo]))
conferir("IPv4", sem(RegistroSeguro.texto("rede 192.0.2.77:7877 status=9"), ["192.0.2.77"]))
conferir("IPv6-zona", sem(RegistroSeguro.texto("rede [fe80::abcd%en0]:7877 status=9"), ["fe80", "abcd", "en0"]))
conferir("IPv6-global", sem(RegistroSeguro.texto("rede 2001:db8::23 status=9"), ["2001:db8", "::23"]))
conferir("URL", sem(RegistroSeguro.texto("url=rtsp://USUARIO-SINTETICO:\(segredo)@camera.invalid/video status=8"), ["USUARIO-SINTETICO", segredo, "camera.invalid"]))
conferir("nome-UID", sem(RegistroSeguro.texto("nome=Câmera PESSOA-SINTETICA uid=UID-SINTETICO fluxos=3"), ["PESSOA-SINTETICA", "UID-SINTETICO"]))
conferir("caminho", sem(RegistroSeguro.texto("arquivo=/Users/pessoa-exemplo/Library/pares.json"), ["USUARIO-SINTETICO", "pares.json"]))
conferir("controle", !RegistroSeguro.texto("status=1\nLINHA\r\u{001b}").contains(where: { $0.isNewline || $0.asciiValue == 27 }))
let estavel = "status=-50 frames=93 p50=3.70ms p95=19ms largura=1280 altura=720"
conferir("metricas-texto-estaveis", RegistroSeguro.texto(estavel) == estavel)
conferir("motivo-rede", RegistroSeguro.motivo("connect failed 192.0.2.77 password=\(segredo)").hasPrefix("falha de conexão/rede"))
conferir("motivo-prazo", RegistroSeguro.motivo("timeout \(segredo)").hasPrefix("prazo esgotado"))
conferir("motivo-permissao", RegistroSeguro.motivo("Operation not permitted /Users/pessoa-exemplo").hasPrefix("permissão recusada"))
conferir("motivo-desconhecido", sem(RegistroSeguro.motivo("\(segredo) PAR-SINTETICO"), [segredo, "PAR-SINTETICO"]))
let causa = NSError(domain: "NSPOSIXErrorDomain", code: 13, userInfo: [NSLocalizedDescriptionKey: segredo])
let erro = NSError(domain: "NSCocoaErrorDomain", code: 257, userInfo: [NSLocalizedDescriptionKey: segredo, NSUnderlyingErrorKey: causa])
let erroSeguro = RegistroSeguro.erro(erro)
conferir("NSError-causa-codigos", erroSeguro.contains("código=257") && erroSeguro.contains("código=13") && !erroSeguro.contains(segredo))
conferir("NSError-dominio-estranho", !RegistroSeguro.erro(NSError(domain: segredo, code: 71)).contains(segredo))
conferir("pares-contagem-formato-real", RegistroSeguro.pares("{\"pares\":{\"PAR-SINTETICO\":{\"secret\":\"\(segredo)\",\"updated_ms\":11}}}").contains("contagem=1"))
conferir("pares-nao-vaza", sem(RegistroSeguro.pares("{\"pares\":{\"PAR-SINTETICO\":\"\(segredo)\"}}"), [segredo, "PAR-SINTETICO"]))
conferir("pares-ausente", RegistroSeguro.pares(nil).contains("ausente/ilegível"))
conferir("pares-invalido", RegistroSeguro.pares("{quebrado\(segredo)").contains("estrutura inválida"))
let metricas = RegistroSeguro.metricas("""
{"frames_ready":93,"frames_dropped":2,"idrs_broken":1,"jitter_us":null,"password":"\(segredo)","nome":"PAR-SINTETICO",
"clock":{"reference":true,"status":"refused","capture_offset_us":null,"reason":"invalid track PAR-SINTETICO password=\(segredo)","residual_us":-7,"guard_violations":2},
"jitter_buffer":{"frames":91,"holes":2,"max_delay_us":700,"secret":"\(segredo)"}}
""")
conferir("JSON-metricas-e-null", ["frames_ready=93", "idrs_broken=1", "jitter_us=indisponível", "clock.status=refused", "clock.residual_us=-7", "jitter_buffer.max_delay_us=700"].allSatisfy(metricas.contains))
conferir("JSON-metricas-sem-segredos", sem(metricas, [segredo, "PAR-SINTETICO", "password", "secret"]))
conferir("clock-causa-conhecida", RegistroSeguro.metricas("{\"clock\":{\"reason\":\"a taxa do relógio RTP desta track não divide 720 000 Hz\"}}").contains("taxa não suportada"))
conferir("clock-causa-guarda-sem-identidade", RegistroSeguro.metricas("{\"clock\":{\"reason\":\"a track PAR-SINTETICO da sessão recusou o relógio desta\"}}") == "clock.reason=referência recusada por outra track")
conferir("JSON-grupos-null", RegistroSeguro.metricas("{\"clock\":null,\"jitter_buffer\":null}") == "clock=indisponível jitter_buffer=indisponível")
conferir("JSON-invalido-status", RegistroSeguro.metricas("{\(segredo)").contains("JSON inválido"))
conferir("JSON-sem-campos", RegistroSeguro.metricas("{\"pin\":123456}").contains("nenhum campo autorizado"))
print("RESULTADO casos=\(casos) falhas=\(falhas)")
exit(falhas == 0 ? 0 : 1)
