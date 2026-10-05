// Lista as janelas de um processo pelo nome do dono, e imprime o **CGWindowID** de cada uma.
//
// # Por que ele existe, e por que ele NÃO captura nada
//
// `docs/regras-de-frente.md` proíbe capturar a tela do MacBook anfitrião: é a máquina de trabalho
// do usuário, e uma frente já capturou o banco dele por engano. A saída que a regra deixa aberta é
// capturar **apenas a janela**, com `screencapture -l <id da janela>` — e para isso é preciso o id,
// que nenhuma ferramenta de linha de comando do sistema imprime.
//
// Este programa imprime **id, dono, posição e tamanho**, e nada mais. Ele não lê pixel nenhum:
// `CGWindowListCopyWindowInfo` com `.optionOnScreenOnly` devolve metadados, e o **título** da
// janela (a única parte que poderia carregar conteúdo do usuário) é deliberadamente descartado —
// mesmo quando o sistema o entrega. O que sai daqui é geometria.
//
// Ele também responde, sozinho, a uma pergunta que nenhum contador responde: **a janela existe e
// tem área?** Uma `AVSampleBufferDisplayLayer` de quadro zero aceita quadro e não desenha nada, e
// `docs/app-macos.md` fechou a rodada anterior dizendo "não afirmo que a janela apareceu na tela".
//
// Uso:
//   swiftc -O apps/macos/Bancada/janela-do-app.swift -o /tmp/janela-do-app
//   /tmp/janela-do-app Quall
//   screencapture -o -l $(/tmp/janela-do-app Quall | head -1 | cut -d' ' -f1) /tmp/janela.png

import CoreGraphics
import Foundation

let dono = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Quall"

guard let lista = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("!! CGWindowListCopyWindowInfo devolveu nulo\n".data(using: .utf8)!)
    exit(2)
}

var achou = false
for janela in lista {
    guard let nomeDoDono = janela[kCGWindowOwnerName as String] as? String, nomeDoDono == dono,
          let id = janela[kCGWindowNumber as String] as? Int,
          let caixa = janela[kCGWindowBounds as String] as? [String: Any],
          let x = caixa["X"] as? Double, let y = caixa["Y"] as? Double,
          let l = caixa["Width"] as? Double, let a = caixa["Height"] as? Double
    else { continue }
    let camada = janela[kCGWindowLayer as String] as? Int ?? 0
    // Camada 0 é janela normal; acima disso são painéis, menus e afins. A janela do produto é a
    // de camada 0 — e sem este filtro o primeiro id da lista pode ser um menu de 1x1.
    guard camada == 0, l >= 1, a >= 1 else { continue }
    print("\(id) \(dono) \(Int(l))x\(Int(a)) em (\(Int(x)),\(Int(y)))")
    achou = true
}

if !achou {
    print("nenhuma janela de \"\(dono)\" na tela")
    exit(1)
}
