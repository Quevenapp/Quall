import Foundation

@main
enum TestesDoRegistroMac {
    static func main() throws {
        let pasta = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let arquivo = pasta.appendingPathComponent("diario-sintetico.log")
        Registro.compartilhado.abrir(caminho: arquivo.path)
        Registro.compartilhado.linha(#"status=PAIRING secret="NÃO RETER SEGREDO SINTÉTICO 901234" nome="Pessoa Sintética" endereço=[2001:db8::42]:7877 falhas=2"#)
        Registro.compartilhado.linha("quadros=100 codec=pcmu taxa=8000 canais=1\nlinha simulada")
        Registro.compartilhado.fechar()
        let conteudo = try String(contentsOf: arquivo, encoding: .utf8)
        for proibido in ["RETER", "SEGREDO SINTÉTICO", "901234", "Pessoa Sintética", "2001:db8"] {
            precondition(!conteudo.contains(proibido), "o sink em arquivo reteve um valor sintético")
        }
        precondition(conteudo.contains("status=PAIRING") && conteudo.contains("falhas=2"))
        precondition(conteudo.contains("quadros=100 codec=pcmu taxa=8000 canais=1"))
        precondition(conteudo.components(separatedBy: "\n").count == 3, "nova linha externa forjou registro")
        let modo = try FileManager.default.attributesOfItem(atPath: arquivo.path)[.posixPermissions] as? Int
        precondition(modo == 0o600, "arquivo novo deveria restringir acesso ao usuário")
        print("Registro macOS: arquivo, métricas, redação, quebra de linha e modo 0600 passaram")
    }
}
