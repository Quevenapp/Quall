import Foundation
import Network
import UIKit

/// Preparo do degrau 4, feito pelo app hospedeiro antes de a transmissão começar.
///
/// Três coisas que **só o app** pode fazer, e que a extension colhe depois:
///
/// 1. **Levar o plano até o App Group.** Iniciar uma transmissão custa um toque humano que o
///    iPhone 7 não automatiza; se cada mudança de prazo exigisse recompilar, exigiria também um
///    toque. O plano chega pelo `Documents` do app, que o `ios-deploy --upload` alcança.
///
///    A rota óbvia — `ios-deploy --args` — foi tentada e **não funciona neste aparelho**: o app
///    abre, o `CommandLine.arguments` não traz o que foi passado, e nada reclama em lugar
///    nenhum. Custou uma conferência a seco; fica registrado para não custar outra. Os
///    argumentos continuam aceitos como segundo caminho, porque a `Sonda` do degrau 2 depende
///    deles e porque um dia podem voltar a funcionar.
///
/// 2. **Provocar a permissão de rede local.** Desde o iOS 14, tráfego de saída para a LAN é
///    barrado até a pessoa autorizar, e o diálogo é do **app**, não da extension — uma Broadcast
///    Upload Extension não tem como apresentá-lo. Sem isso o ICE do libjuice manda STUN para o
///    vazio e a sessão nunca fecha, com um sintoma que parece defeito de pareamento. Um
///    `NWBrowser` de Bonjour é o gatilho canônico e **não** precisa do entitlement de multicast
///    (o que precisa é socket multicast cru, que é o caminho do núcleo e está desligado aqui).
///
///    Se a permissão de fato se propaga do app para a appex é pergunta empírica; no relato do
///    degrau 4 ela aparece respondida pela medição, não por suposição.
///
/// 3. **Abrir a folha do seletor**, para que só reste o toque em "Iniciar Transmissão".
enum Degrau4 {
    private static var navegador: NWBrowser?

    /// Há um plano esperando em `Documents`? Consultado **antes** de a interface montar, sem
    /// consumir o arquivo.
    ///
    /// Serve para zerar o diário no começo de cada corrida. O `Diario` do App Group acumula
    /// entre corridas, e a tela do app renderiza o arquivo inteiro num único `Text` dentro de um
    /// `ScrollView` — sem preguiça, sem reciclagem. Foi assim que a pegada do **processo do
    /// app** foi de ~39 MB para ~77 MB ao longo de corridas sucessivas do mesmo código, e por um
    /// tempo isso pareceu custo do núcleo. Não era: com a pegada instrumentada por estágio,
    /// `quall_host` já começava em 77 MB, e a sessão inteira mais o encoder mais o pool custaram
    /// **~2,5 MB**. Um diário limpo por corrida devolve o número ao que ele deveria medir.
    static var haPlanoPendente: Bool {
        let documentos = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Plano.nomeNoDocuments)
        return FileManager.default.fileExists(atPath: documentos.path)
    }

    /// Devolve `true` quando há corrida em andamento — o app usa isso para trocar a interface
    /// pelo `Agitador`, que é condição experimental e não enfeite (ver `Agitador`).
    @discardableResult
    static func talvezPreparar() -> Bool {
        guard let (plano, origem) = procurarPlano() else { return false }

        do {
            try plano.gravar()
            Diario.anotar("APP plano de \(origem) gravado no App Group {\(plano.resumo)}")
            // Eco em JSON canônico: é o que o roteiro no MacBook compara, campo a campo, com o
            // que enviou. Sem ele, um plano lido pela metade roda bonito e mede outra coisa.
            Diario.anotar("APP plano-eco \(plano.eco)")
        } catch {
            Diario.anotar("APP plano NÃO gravado: \(error)")
            return false
        }

        Diario.anotar("APP enderecos \(Enderecos.ipv4().joined(separator: " "))")

        if plano.rede_local {
            provocarPermissaoDeRedeLocal()
        } else {
            Diario.anotar("APP rede-local gatilho desligado pelo plano")
        }

        let espera: Double = plano.rede_local ? 10 : 2

        // Ensaio: nada de folha do seletor. O próprio app sobe a sessão e manda vídeo gerado,
        // para gastar zero toque no que não precisa de ReplayKit. Ver `EnsaioDeSessao`.
        if plano.ensaio {
            #if COM_NUCLEO
            DispatchQueue.main.asyncAfter(deadline: .now() + espera) {
                EnsaioDeSessao.rodar(plano)
            }
            #else
            Diario.anotar("ENSAIO pedido, mas este binário foi construído sem o núcleo")
            #endif
            return false
        }

        // A folha do seletor abre **depois** do diálogo de rede local, e não junto: as duas são
        // apresentações do sistema, e a segunda a chegar cancela a primeira.
        DispatchQueue.main.asyncAfter(deadline: .now() + espera) {
            Sonda.abrirSeletor()
            Diario.anotar("APP seletor aberto para o degrau 4")
        }
        return true
    }

    /// Procura o plano no `Documents` e, se não achar, nos argumentos. Devolve também de onde
    /// veio, porque num experimento que custa um toque humano a proveniência do parâmetro é
    /// parte do resultado.
    private static func procurarPlano() -> (Plano, String)? {
        let documentos = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Plano.nomeNoDocuments)
        if let dados = try? Data(contentsOf: documentos) {
            // Some depois de lido: um plano esquecido faria a próxima abertura comum do app
            // abrir a folha do seletor sozinha, e ninguém entenderia por quê.
            try? FileManager.default.removeItem(at: documentos)
            if let plano = try? JSONDecoder().decode(Plano.self, from: dados) {
                return (plano, "Documents")
            }
            Diario.anotar("APP plano em Documents não decodificou")
        }

        let argumentos = CommandLine.arguments
        guard let posicao = argumentos.firstIndex(of: "degrau4") else { return nil }
        for argumento in argumentos.dropFirst(posicao + 1) {
            guard let dados = decodificar(argumento),
                  let plano = try? JSONDecoder().decode(Plano.self, from: dados)
            else { continue }
            return (plano, "argumento")
        }
        Diario.anotar("APP 'degrau4' nos argumentos, mas sem plano legível — usando o padrão")
        return (Plano(), "padrão")
    }

    /// Aceita **hexadecimal** ou base64: o argumento atravessa `ios-deploy`, um arquivo de
    /// comandos do lldb e o `debugserver` antes de virar `argv`, e `+`, `/` e `=` são
    /// caracteres que cada uma dessas camadas trata à sua maneira.
    private static func decodificar(_ texto: String) -> Data? {
        if texto.count >= 2, texto.count % 2 == 0, texto.allSatisfy({ $0.isHexDigit }) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(texto.count / 2)
            var i = texto.startIndex
            while i < texto.endIndex {
                let j = texto.index(i, offsetBy: 2)
                guard let b = UInt8(texto[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            let dados = Data(bytes)
            if dados.first == UInt8(ascii: "{") { return dados }
        }
        return Data(base64Encoded: texto)
    }

    /// Abre um navegador Bonjour só para que o sistema mostre o diálogo de rede local. Ele fica
    /// de pé alguns segundos e é solto — não é descoberta, é gatilho de permissão.
    private static func provocarPermissaoDeRedeLocal() {
        let parametros = NWParameters()
        parametros.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_quall._tcp", domain: nil), using: parametros)
        b.stateUpdateHandler = { estado in
            Diario.anotar("APP rede-local navegador=\(estado)")
        }
        b.start(queue: .main)
        navegador = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            navegador?.cancel()
            navegador = nil
            Diario.anotar("APP rede-local gatilho encerrado")
        }
    }
}
