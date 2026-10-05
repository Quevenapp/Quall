// Captura **uma janela** do macOS, achada pelo nome do processo dono.
//
// Existe por causa de uma regra da bancada que já foi furada duas vezes: **nunca capturar a tela
// cheia da máquina de trabalho**. Aqui não há caminho para isso — a ferramenta só sabe capturar
// uma `CGWindowID`, e só imprime janelas cujo dono casa com o filtro que veio na linha de
// comando. Sem filtro ela não lista nada, de propósito: uma lista de todas as janelas já é, ela
// mesma, informação da vida de quem usa a máquina.
//
//   swift janela.swift listar Quall
//   swift janela.swift capturar Quall /tmp/receptor.png
//
// A captura exige a permissão de Gravação de Tela para o processo que roda isto (o Terminal).

import CoreGraphics
import Foundation

func janelas(donoContem filtro: String) -> [(id: CGWindowID, dono: String, largura: Int, altura: Int)] {
    let opcoes = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    guard let lista = CGWindowListCopyWindowInfo(opcoes, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    let alvo = filtro.lowercased()
    return lista.compactMap { info in
        guard let dono = info[kCGWindowOwnerName as String] as? String,
              dono.lowercased().contains(alvo),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let limites = info[kCGWindowBounds as String] as? [String: Any],
              let largura = limites["Width"] as? Double,
              let altura = limites["Height"] as? Double,
              largura > 1, altura > 1
        else { return nil }
        return (id, dono, Int(largura), Int(altura))
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("uso: janela.swift listar|capturar FILTRO [saida.png]\n".utf8))
    exit(2)
}
let comando = args[1]
let filtro = args[2]
let achadas = janelas(donoContem: filtro)

if achadas.isEmpty {
    FileHandle.standardError.write(Data("nenhuma janela de dono contendo \"\(filtro)\"\n".utf8))
    exit(1)
}

switch comando {
case "listar":
    for j in achadas { print("id=\(j.id) dono=\(j.dono) \(j.largura)x\(j.altura)") }
case "capturar":
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("falta o caminho de saída\n".utf8))
        exit(2)
    }
    // A maior janela do processo é a do receptor; as pequenas são painéis e menus.
    let alvo = achadas.max(by: { $0.largura * $0.altura < $1.largura * $1.altura })!
    let saida = args[3]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // `-l` fixa a janela; sem ele o `screencapture` pegaria a tela inteira, que é o que esta
    // ferramenta existe para impedir. `-o` tira a sombra, `-x` cala o som do obturador.
    p.arguments = ["-l\(alvo.id)", "-o", "-x", saida]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: saida) else {
        FileHandle.standardError.write(Data("screencapture falhou (permissão de Gravação de Tela?)\n".utf8))
        exit(1)
    }
    print("id=\(alvo.id) dono=\(alvo.dono) \(alvo.largura)x\(alvo.altura) -> \(saida)")
default:
    FileHandle.standardError.write(Data("comando desconhecido: \(comando)\n".utf8))
    exit(2)
}
