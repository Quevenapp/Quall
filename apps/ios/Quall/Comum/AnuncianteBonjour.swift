import Foundation

/// Anuncia este aparelho por mDNS (`_quall._tcp`) **pelo `mDNSResponder` do sistema**, e não por
/// socket multicast cru.
///
/// # Por que esta peça existe, sendo que o núcleo já sabe anunciar
///
/// O `quall_advertiser_start` do núcleo abre socket multicast, e no iOS isso depende do
/// entitlement `com.apple.developer.networking.multicast` — pedido que está com a Apple e que
/// `App/Quall.entitlements` proíbe acrescentar antes de o App ID mostrar a chave habilitada. A
/// consequência estava medida em 01/09/2026: com três iOS emitindo câmera e a porta 7877 aberta
/// nos três, `dns-sd -B _quall._tcp` listava **os dois Android e nenhum iOS**.
///
/// **`NetService` não passa por ali.** Ele publica pelo daemon do sistema, que é o mesmo que
/// anuncia `_apple-mobdev2._tcp` sozinho e atravessa até pelo cabo. Não pede entitlement nenhum, e
/// é por isso que esta casca pode aparecer na lista hoje, sem esperar a Apple.
///
/// # Por que `NetService` e não `NWListener`
///
/// `NWListener` publicaria o serviço **e abriria a porta** — e a porta de sinalização já é do
/// núcleo, que faz o próprio `TcpListener::bind`. Dois donos do mesmo número é defeito esperando
/// acontecer. `NetService` anuncia sem escutar, que é exatamente o papel aqui.
///
/// # O formato é do núcleo, e é ele que manda
///
/// As chaves do TXT são as de `quall_core::discovery` — `v`, `id`, `n`, `c`, `p`, e `pa` só quando
/// há papel — curtas de propósito, porque uma resposta mDNS que não cabe num datagrama fragmenta, e
/// no Wi-Fi de 2,4 GHz fragmentar é perder. As capacidades são letras: `s` tela, `c` câmera, `k`
/// exibe. Escrever isto diferente aqui faria o anúncio existir e **não ser entendido**, que é pior
/// que não anunciar.
///
/// A **versão** vem de `quall_protocol_version()` e não de uma constante daqui: anunciar uma
/// versão diferente da que a sessão vai negociar poria este aparelho na lista do outro e o faria
/// ser recusado ao conectar — o pior dos dois mundos, e sem mensagem que explique. Duas
/// linguagens com o mesmo número escrito à mão divergem; perguntar não diverge.
final class AnuncianteBonjour: NSObject {
    private var servico: NetService?
    private let trava = NSLock()

    /// Começa a anunciar. Devolve `false` só quando já havia um anúncio no ar.
    ///
    /// Publicar **não** garante que alguém veja: rede com multicast bloqueado é caso normal e
    /// **não é erro de produto** — o endereço digitado continua sendo o caminho obrigatório
    /// (`PROMPT.md`). Por isso o retorno não é o veredito, e a interface não muda de discurso por
    /// causa dele.
    ///
    /// `papel`: `nil` para o vídeo (o anúncio de sempre, chave a chave); `"teleprompter"` para quem
    /// hospeda um teleprompter. Com papel, o TXT ganha a chave **`pa`** — a mesma do núcleo
    /// (`quall_core::discovery`, `docs/contrato-teleprompter.md` §2 e §7) — e o nome da instância
    /// passa a levar o papel. É por essa chave que os controles do Android, do Mac e do Windows
    /// acham o prompter na lista, e é ela que faz os receptores de vídeo o esconderem.
    @discardableResult
    func comecar(deviceId: String, nome: String, porta: UInt16,
                 emiteTela: Bool, emiteCamera: Bool, exibe: Bool = false,
                 papel: String? = nil) -> Bool {
        trava.lock()
        defer { trava.unlock() }
        guard servico == nil else { return false }

        var caps = ""
        if emiteTela { caps += "s" }
        if emiteCamera { caps += "c" }
        if exibe { caps += "k" }

        // Sem papel, o nome da instância é o do aparelho, como sempre foi: um sufixo evitaria
        // colisão entre dois aparelhos de mesmo nome, e o `mDNSResponder` já resolve isso sozinho
        // renomeando para "Nome (2)". **O que mudou é o teto**: um rótulo DNS tem 63 bytes, e acima
        // disso o registro não vale — o nome é cortado numa fronteira de caractere, como o núcleo
        // faz. Com papel, vai o papel e o sufixo do id, na regra do núcleo. Ver `NomeDaInstancia`.
        let instancia = NomeDaInstancia.montar(nome: nome, deviceId: deviceId, papel: papel)
        let s = NetService(domain: "local.", type: "_quall._tcp.", name: instancia, port: Int32(porta))
        var txt: [String: Data] = [
            "v": Data(String(quall_protocol_version()).utf8),
            "id": Data(deviceId.utf8),
            // O nome **inteiro** fica aqui: é o que as listas mostram.
            "n": Data(nome.utf8),
            "c": Data(caps.utf8),
            "p": Data(String(porta).utf8),
        ]
        // Só quando existe: sem papel o registro é o de antes, chave a chave.
        if let papel, !papel.isEmpty { txt["pa"] = Data(papel.utf8) }
        s.setTXTRecord(NetService.data(fromTXTRecord: txt))
        s.publish()
        servico = s
        return true
    }

    func parar() {
        trava.lock()
        let atual = servico
        servico = nil
        trava.unlock()
        atual?.stop()
    }

    deinit { parar() }
}
