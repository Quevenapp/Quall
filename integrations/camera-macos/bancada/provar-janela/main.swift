// Exercita a aritmética de `JanelaDoEnlace` **sem aparelho e sem rede**.
//
// Esta casca não tem alvo de teste de unidade — `project.yml` tem dois alvos, o app e a extensão,
// e criar um terceiro só para quarenta linhas de subtração muda a impressão digital de
// `construir.sh` (ver `docs/camera-virtual.md`: mexer no conjunto de fontes já derrubou a câmera
// do sistema três vezes nesta máquina). Então a prova vem por fora, no mesmo padrão do
// `gerar-clipe` daqui: um `main.swift` compilado **junto do arquivo de produto**, e não copiando
// dele — não há duas verdades.
//
// O que ele NÃO prova: que o relato sai no fio, que o emissor o recebe, e que o controlador do
// outro lado acorda. Isso é bancada com aparelho, e está dito no relatório.
//
//   cd integrations/camera-macos
//   swiftc -O bancada/provar-janela/main.swift Fontes/App/JanelaDoEnlace.swift -o /tmp/provar-janela
//   /tmp/provar-janela

import Foundation

var falhas = 0
var casos = 0

func conferir(_ nome: String, _ ok: Bool, _ detalhe: @autoclosure () -> String = "") {
    casos += 1
    if ok {
        print("  ok   \(nome)")
    } else {
        falhas += 1
        print("  FALHOU \(nome) \(detalhe())")
    }
}

let ms: UInt64 = 1_000  // um milissegundo, em microssegundos

// ------------------------------------------------------------------------------------------------
print("1. a primeira chamada só ancora")
// Uma sessão que já rodou meio segundo antes de a primeira janela abrir tem acumulados que medem
// o arranque — o primeiro IDR, a subida do ICE —, e não o regime.
do {
    var j = JanelaDoEnlace()
    let primeira = j.fechar(agoraUs: 10_000 * ms, periodoMs: 500,
                            vistosAcum: 9_000, perdidosAcum: 400,
                            suspeitosAcum: 70, idrsQuebradosAcum: 5)
    conferir("a primeira devolve nil", primeira == nil)

    let segunda = j.fechar(agoraUs: 10_500 * ms, periodoMs: 500,
                           vistosAcum: 9_100, perdidosAcum: 402,
                           suspeitosAcum: 71, idrsQuebradosAcum: 5)
    conferir("a segunda mede só o que andou depois da âncora",
             segunda?.pacotes == 102 && segunda?.perdidos == 2 && segunda?.suspeitos == 1
             && segunda?.idrsQuebrados == 0,
             "veio \(String(describing: segunda))")
}

// ------------------------------------------------------------------------------------------------
print("2. a janela não fecha antes do período")
do {
    var j = JanelaDoEnlace()
    _ = j.fechar(agoraUs: 0, periodoMs: 500, vistosAcum: 0, perdidosAcum: 0,
                 suspeitosAcum: 0, idrsQuebradosAcum: 0)
    // O laço desta casca bate a 50 ms: nove voltas dentro da janela não podem produzir amostra.
    var produziu = 0
    for volta in 1...9 {
        if j.fechar(agoraUs: UInt64(volta) * 50 * ms, periodoMs: 500,
                    vistosAcum: UInt64(volta) * 10, perdidosAcum: 0,
                    suspeitosAcum: 0, idrsQuebradosAcum: 0) != nil { produziu += 1 }
    }
    conferir("nove voltas de 50 ms não fecham nada", produziu == 0, "produziu \(produziu)")
    let decima = j.fechar(agoraUs: 500 * ms, periodoMs: 500, vistosAcum: 100, perdidosAcum: 0,
                          suspeitosAcum: 0, idrsQuebradosAcum: 0)
    conferir("a décima fecha, com os 500 ms inteiros", decima?.ms == 500 && decima?.pacotes == 100,
             "veio \(String(describing: decima))")
}

// ------------------------------------------------------------------------------------------------
print("3. os números são deltas da janela, e não acumulados da sessão")
// O defeito que esta prova existe para pegar: uma sessão que perdeu tudo no começo e nada depois
// continuaria dizendo a mesma perda meia hora adiante, e o controlador desceria o bitrate para
// sempre.
do {
    var j = JanelaDoEnlace()
    _ = j.fechar(agoraUs: 0, periodoMs: 500, vistosAcum: 0, perdidosAcum: 0,
                 suspeitosAcum: 0, idrsQuebradosAcum: 0)
    // Janela suja: 1 000 vistos, 100 perdidos.
    let suja = j.fechar(agoraUs: 500 * ms, periodoMs: 500, vistosAcum: 1_000, perdidosAcum: 100,
                        suspeitosAcum: 12, idrsQuebradosAcum: 3)
    // Janela limpa: mais 1 000 vistos, **nenhum** perdido novo. Os acumulados continuam com os 100.
    let limpa = j.fechar(agoraUs: 1_000 * ms, periodoMs: 500, vistosAcum: 2_000, perdidosAcum: 100,
                         suspeitosAcum: 12, idrsQuebradosAcum: 3)
    conferir("a janela suja acusa a perda", suja?.perdidos == 100 && suja?.pacotes == 1_100,
             "veio \(String(describing: suja))")
    conferir("a janela limpa acusa zero, com o acumulado ainda em 100",
             limpa?.perdidos == 0 && limpa?.pacotes == 1_000 && limpa?.suspeitos == 0,
             "veio \(String(describing: limpa))")
}

// ------------------------------------------------------------------------------------------------
print("4. o denominador é o que o emissor mandou, não o que chegou")
// A regra que inverteu a conclusão de uma frente inteira desta bancada. Com 900 vistos e 100
// perdidos: 100/1000 = 10,00 % (certo) contra 100/900 = 11,11 % (a pergunta errada).
do {
    var j = JanelaDoEnlace()
    _ = j.fechar(agoraUs: 0, periodoMs: 500, vistosAcum: 0, perdidosAcum: 0,
                 suspeitosAcum: 0, idrsQuebradosAcum: 0)
    let a = j.fechar(agoraUs: 500 * ms, periodoMs: 500, vistosAcum: 900, perdidosAcum: 100,
                     suspeitosAcum: 0, idrsQuebradosAcum: 0)
    conferir("pacotes = vistos + perdidos", a?.pacotes == 1_000, "veio \(String(describing: a?.pacotes))")
    conferir("a linha imprime 10,00 % e não 11,11 %",
             a?.linha.contains("(10.00%)") == true, "veio \(a?.linha ?? "nil")")
}

// ------------------------------------------------------------------------------------------------
print("5. contador que anda para trás é track recriada, não perda negativa")
// Um delta negativo alimentando um controlador é como se sobe o bitrate exatamente quando não se
// deve. Em `UInt64` uma subtração ao contrário não fica negativa: fica astronômica.
do {
    var j = JanelaDoEnlace()
    _ = j.fechar(agoraUs: 0, periodoMs: 500, vistosAcum: 0, perdidosAcum: 0,
                 suspeitosAcum: 0, idrsQuebradosAcum: 0)
    _ = j.fechar(agoraUs: 500 * ms, periodoMs: 500, vistosAcum: 5_000, perdidosAcum: 200,
                 suspeitosAcum: 40, idrsQuebradosAcum: 7)
    // A track é recriada: todos os acumulados do núcleo voltam para perto de zero.
    let depois = j.fechar(agoraUs: 1_000 * ms, periodoMs: 500, vistosAcum: 30, perdidosAcum: 1,
                          suspeitosAcum: 0, idrsQuebradosAcum: 0)
    conferir("nenhum campo estoura", depois != nil
             && depois!.pacotes <= 31 && depois!.perdidos <= 1
             && depois!.suspeitos == 0 && depois!.idrsQuebrados == 0,
             "veio \(String(describing: depois))")
    conferir("a perda da janela não vira um número absurdo",
             depois.map { $0.perdidos < 1_000 } == true, "veio \(String(describing: depois?.perdidos))")
}

// ------------------------------------------------------------------------------------------------
print("6. ms é o decorrido real, não o período nominal")
// O laço acorda quando acorda. Dividir pelo nominal daria uma taxa sistematicamente alta.
do {
    var j = JanelaDoEnlace()
    _ = j.fechar(agoraUs: 0, periodoMs: 500, vistosAcum: 0, perdidosAcum: 0,
                 suspeitosAcum: 0, idrsQuebradosAcum: 0)
    let a = j.fechar(agoraUs: 730 * ms, periodoMs: 500, vistosAcum: 100, perdidosAcum: 0,
                     suspeitosAcum: 0, idrsQuebradosAcum: 0)
    conferir("ms = 730, e não 500", a?.ms == 730, "veio \(String(describing: a?.ms))")
}

// ------------------------------------------------------------------------------------------------
print("7. os acumulados vêm do JSON certo do núcleo")
// `packets_lost_for_real`, e **não** `packets_missing_upper_bound` — o teto cobra reordenação como
// perda, de 1,3x a 44x de inflação nas medições desta bancada.
do {
    let json = """
    {"packets_seen":27729,"packets_lost_for_real":50,"packets_missing_upper_bound":486,\
    "packets_too_late":0,"frames_dropped":2,"idrs_ready":13,"idrs_broken":18}
    """
    let a = JanelaDoEnlace.acumulados(json)
    conferir("lê a perda exata (50), não o teto (486)", a?.perdidos == 50,
             "veio \(String(describing: a?.perdidos))")
    conferir("lê packets_seen", a?.vistos == 27_729, "veio \(String(describing: a?.vistos))")
    conferir("lê idrs_broken", a?.idrsQuebrados == 18, "veio \(String(describing: a?.idrsQuebrados))")

    // Leitura falha devolve `nil`, e `nil` **não** é zero: zerar zeraria a âncora, e a janela
    // seguinte entregaria a sessão inteira como dano de 500 ms.
    conferir("JSON ilegível é leitura falha, não zero",
             JanelaDoEnlace.acumulados("{ isto não é json") == nil, "devolveu tupla")
    conferir("chave ausente é leitura falha", JanelaDoEnlace.acumulados("{}") == nil,
             "devolveu tupla")
    conferir("duas das três chaves ainda é leitura falha",
             JanelaDoEnlace.acumulados("{\"packets_seen\":100,\"idrs_broken\":1}") == nil,
             "devolveu tupla")
}

// ------------------------------------------------------------------------------------------------
print("8. a linha de diário tem os cinco nomes do contrato")
do {
    var j = JanelaDoEnlace()
    _ = j.fechar(agoraUs: 0, periodoMs: 500, vistosAcum: 0, perdidosAcum: 0,
                 suspeitosAcum: 0, idrsQuebradosAcum: 0)
    let a = j.fechar(agoraUs: 512 * ms, periodoMs: 500, vistosAcum: 1_940, perdidosAcum: 60,
                     suspeitosAcum: 9, idrsQuebradosAcum: 2)!
    let esperado = "janela_do_enlace ms=512 pacotes=2000 perdidos=60 (3.00%) "
        + "suspeitos=9 idrs_quebrados=2"
    conferir("a linha é literalmente a do iOS", a.linha == esperado, "\n         veio     \(a.linha)\n         esperado \(esperado)")
}

print("")
print(falhas == 0 ? "VERDE: \(casos)/\(casos)" : "VERMELHO: \(falhas) de \(casos) falharam")
exit(falhas == 0 ? 0 : 1)
