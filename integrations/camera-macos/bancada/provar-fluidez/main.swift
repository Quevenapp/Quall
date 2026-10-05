// Exercita a aritmética de `Fluidez` **sem aparelho, sem rede e sem câmera do sistema**.
//
// Esta casca não tem alvo de teste de unidade — `project.yml` tem dois alvos, o app e a extensão,
// e criar um terceiro muda o conjunto de fontes (ver `docs/camera-virtual.md`: mexer nisso já
// derrubou a câmera do sistema três vezes nesta máquina). Então a prova vem por fora, no mesmo
// molde do `provar-janela` ao lado: um `main.swift` compilado **junto do arquivo de produto**, e
// não copiando dele — não há duas verdades.
//
// O que ele NÃO prova: que a marca é tirada no instante certo do caminho de produto, que a linha
// sai numa corrida, e — sobretudo — que este intervalo é o intervalo que um consumidor sente. O
// que se mede aqui é a entrega à fila do CoreMediaIO; entre ela e o olho de alguém ainda há a
// extensão, o assistente e o app consumidor. Isso é bancada com aparelho, e está dito no relatório.
//
//   cd integrations/camera-macos
//   swiftc -O bancada/provar-fluidez/main.swift Fontes/App/Fluidez.swift -o /tmp/provar-fluidez
//   /tmp/provar-fluidez

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
print("1. a primeira entrega só ancora")
// Não existe intervalo antes do primeiro quadro. Contar o tempo desde a abertura da sessão poria a
// subida do ICE e a espera pelo primeiro IDR dentro da distribuição da imagem — um `max` de
// segundos em toda corrida saudável, que é um instrumento que ninguém lê duas vezes.
do {
    var f = Fluidez()
    f.entregou(agoraUs: 10_000 * ms)
    conferir("n=0 depois de uma entrega só", f.linha.contains("n=0"), f.linha)
    conferir("e nenhum tranco", f.trancos == 0, "veio \(f.trancos)")
}

// ------------------------------------------------------------------------------------------------
print("2. duas entregas dão um intervalo, e ele é o decorrido real")
// A entrega acontece quando acontece: qualquer número nominal aqui mediria o cronograma, não o
// que saiu para o consumidor.
do {
    var f = Fluidez()
    f.entregou(agoraUs: 10_000 * ms)
    f.entregou(agoraUs: 10_033 * ms)
    let l = f.linha
    conferir("n=1", l.contains("n=1"), l)
    conferir("p50=33 e max=33", l.contains("p50=33") && l.contains("max=33"), l)
    conferir("trancos=0", l.contains("trancos=0"), l)
}

// ------------------------------------------------------------------------------------------------
print("3. um buraco no meio de uma sessão regular aparece no max e nos trancos")
// A corrida de 01/09/2026 em miniatura: 29 intervalos de 33 ms e um de 226 ms. A média dá ~39 ms e
// parece saudável — foi exatamente uma média assim (6,4 ms de fila→tela) que respondeu "está bom"
// para quem estava olhando a tela e vendo o contrário.
do {
    var f = Fluidez()
    var agora: UInt64 = 0
    var intervalos: [UInt64] = []
    f.entregou(agoraUs: agora)
    for i in 0..<30 {
        let passo: UInt64 = (i == 15) ? 226 : 33
        intervalos.append(passo)
        agora += passo * ms
        f.entregou(agoraUs: agora)
    }
    let media = Double(intervalos.reduce(0, +)) / Double(intervalos.count)
    conferir("a média desta sessão é ~39 ms, e não responde nada", abs(media - 39.4) < 0.2,
             "veio \(media)")
    let l = f.linha
    conferir("n=30 e p50=33", l.contains("n=30") && l.contains("p50=33"), l)
    conferir("o max mostra o buraco", l.contains("max=226"), l)
    conferir("e trancos o conta", l.contains("trancos=1"), l)
}

// ------------------------------------------------------------------------------------------------
print("4. o corte do tranco é estrito")
// Fica fixado para que a comparação entre duas corridas não dependa de arredondamento. E o corte é
// convenção de comparação, NÃO afirmação perceptual: ninguém está dizendo que 100 ms é o limiar em
// que uma pessoa percebe. Quem quiser outro corte tem os percentis ao lado.
do {
    var f = Fluidez()
    var agora: UInt64 = 0
    f.entregou(agoraUs: agora)
    agora += Fluidez.trancoMs * ms
    f.entregou(agoraUs: agora)
    conferir("exatamente no limiar não é tranco", f.trancos == 0, "veio \(f.trancos)")
    agora += (Fluidez.trancoMs + 1) * ms
    f.entregou(agoraUs: agora)
    conferir("um milissegundo acima é", f.trancos == 1, "veio \(f.trancos)")
}

// ------------------------------------------------------------------------------------------------
print("5. a porta que segura quadros aparece como intervalo maior")
// É o ponto de medir entre ENTREGAS e não entre chegadas. `Receptor.entregar` não empurra o quadro
// de cadeia condenada: ele foi decodificado e ficou. Medindo chegadas, essa política custaria o
// mesmo e não apareceria em número nenhum. O mesmo vale para o quadro largado com a fila de 3
// cheia.
do {
    var f = Fluidez()
    var agora: UInt64 = 0
    f.entregou(agoraUs: agora)
    for i in 0..<10 {
        // A cada cinco quadros, três ficam retidos: o intervalo seguinte é 4 x 33.
        agora += (i % 5 == 0 ? 33 * 4 : 33) * ms
        f.entregou(agoraUs: agora)
    }
    let l = f.linha
    conferir("n=10 e max=132", l.contains("n=10") && l.contains("max=132"), l)
    conferir("dois intervalos de 132 ms passam do corte de 100", f.trancos == 2, "veio \(f.trancos)")
}

// ------------------------------------------------------------------------------------------------
print("6. sessão vazia: a linha existe e não divide por zero")
// "Não medi" e "medi zero" precisam ser distinguíveis por quem lê o diário, e o `n` é quem separa
// os dois.
do {
    let f = Fluidez()
    conferir("a linha é a de sessão vazia",
             f.linha == "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0", "veio \(f.linha)")
    conferir("e trancos é 0", f.trancos == 0, "veio \(f.trancos)")
}

// ------------------------------------------------------------------------------------------------
print("7. o teto diz o que descartou, em vez de fingir que o n é a sessão inteira")
// Mesma família de defeito de `packets_missing`: um número que se apresenta como uma coisa e é
// outra. Aqui o excedente sai escrito ao lado do `n`.
do {
    var f = Fluidez()
    var agora: UInt64 = 0
    f.entregou(agoraUs: agora)
    for _ in 0..<(Fluidez.maximoDeAmostras + 7) {
        agora += 33 * ms
        f.entregou(agoraUs: agora)
    }
    let l = f.linha
    conferir("n para no teto", l.contains("n=\(Fluidez.maximoDeAmostras)"), l)
    conferir("e o descarte é dito", l.contains("(+7 além do teto)"), l)
}

// ------------------------------------------------------------------------------------------------
print("8. reiniciar larga a âncora junto com as amostras")
// O `ClienteDoSumidouro` vive a sessão, mas a peça precisa saber largar a âncora de qualquer jeito:
// sem isso, o intervalo entre duas sessões — o tempo de alguém digitar um endereço — entraria na
// distribuição como o maior tranco da corrida.
do {
    var f = Fluidez()
    f.entregou(agoraUs: 10_000 * ms)
    f.entregou(agoraUs: 10_033 * ms)
    f.reiniciar()
    conferir("zerou", f.linha.contains("n=0"), f.linha)
    f.entregou(agoraUs: 1_210_000 * ms)
    conferir("a primeira da sessão nova só ancora", f.linha.contains("n=0"), f.linha)
    f.entregou(agoraUs: 1_210_033 * ms)
    conferir("os 20 minutos parados não viram o max",
             f.linha.contains("n=1") && f.linha.contains("max=33"), f.linha)
}

// ------------------------------------------------------------------------------------------------
print("9. a forma da linha é a do contrato, e são quatro números por um motivo")
// Um estouro isolado em vinte intervalos NÃO move o p95, e move o max. Quem publicasse só
// percentis diria que esta sessão foi limpa.
do {
    var f = Fluidez()
    var agora: UInt64 = 0
    f.entregou(agoraUs: agora)
    for i in 0..<20 {
        agora += (i == 9 ? 241 : 32) * ms
        f.entregou(agoraUs: agora)
    }
    conferir("a linha inteira, literal",
             f.linha == "fluidez_ms=[n=20 p50=32 p95=32 max=241] trancos=1", "veio \(f.linha)")
}

print("")
print(falhas == 0 ? "VERDE: \(casos)/\(casos)" : "VERMELHO: \(falhas) de \(casos) falharam")
exit(falhas == 0 ? 0 : 1)
