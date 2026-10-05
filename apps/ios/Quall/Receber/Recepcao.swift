import Combine
import Foundation
import SwiftUI

/// O lado que **exibe**, como objeto de aplicação: dono do painel, da camada e da sessão.
///
/// # De onde isto veio
///
/// Era o `@main struct ReceptorApp` de `apps/ios/Receptor/App/ReceptorApp.swift`, o ponto de
/// entrada do segundo aplicativo. Com a unificação não pode haver dois `@main` no mesmo alvo, e
/// o que aquele arquivo tinha de próprio — o portão da permissão de Rede Local, o modo automático
/// de bancada, o adiamento obrigatório de meio segundo — não é do ponto de entrada: é **do papel
/// de exibir**. Virou este objeto, e `QuallApp` só o segura.
///
/// Nada aqui foi redecidido. Os comentários que explicam *por que* cada passo existe são os
/// daquele arquivo, porque as medições que os produziram continuam valendo.
///
/// # O que a unificação mudou de verdade neste caminho
///
/// **Uma permissão de Rede Local em vez de duas.** `PermissaoDeRedeLocal` documenta o defeito medido
/// em 2026-08-27: "Quall" ligado nos Ajustes e "Quall RX" desligado, mesma Wi-Fi, mesma sub-rede,
/// três falhas seguidas com `No route to host`. Aquilo era consequência direta de haver dois
/// bundle ids — a permissão é concedida **por app**. Num app só, quem já autorizou para espelhar
/// já autorizou para exibir.
///
/// Por isso `jaTentouNaLan` passou a ser marcado **também** pelo emissor (ver `Emissor.espelhar`):
/// o registro é do app, e agora o app tem dois caminhos que tocam a LAN.
final class Recepcao: ObservableObject {

    let painel = Painel()
    let exibidor = Exibidor()
    /// A câmera de quem filma (R9b): o painel "Ajustes da câmera" da tela de recepção. Vive o app; a
    /// sessão de agora o alimenta.
    let cameraRemota = ControleRemotoDaCamera()

    private var sessao: SessaoDeRecepcao?
    /// A escolha da bancada, lida uma vez. `nil` quando o app foi aberto por uma pessoa.
    private(set) var automatico: (endereco: String, pin: String?, segundos: Double, esperar: Double)?

    /// Há uma sessão de recepção no ar agora. `Raiz` usa isto para não deixar a tela de escolha
    /// aparecer por cima de vídeo em curso.
    var noAr: Bool {
        switch painel.fase {
        case .conectando, .esperandoTrack, .exibindo, .pedindoPermissao: return true
        case .parado, .permissaoNegada, .erro: return false
        }
    }

    // --- o caminho da pessoa -------------------------------------------------------------------

    func conectar(endereco: String, pin: String?, segundos: Double) {
        pedirPermissaoEntaoIniciar(endereco: endereco, pin: pin, segundos: segundos,
                                   automatico: false)
    }

    func parar() { sessao?.parar() }

    private func iniciar(endereco: String, pin: String?, segundos: Double) {
        let nova = SessaoDeRecepcao(painel: painel, exibidor: exibidor, cameraRemota: cameraRemota)
        sessao = nova
        nova.iniciar(endereco: endereco, pin: pin, segundos: segundos)
    }

    /// **A fase que faltava.** Provoca o alerta de Rede Local e só então conecta.
    ///
    /// O emissor tem isto desde antes (`Emissor.Fase.pedindoPermissao`); o receptor não tinha nada
    /// equivalente, e o preço foi o defeito descrito em `PermissaoDeRedeLocal`: o diálogo do sistema
    /// nascia da própria tentativa de conexão, sem ninguém na frente da tela para respondê-lo, e
    /// **todas as tentativas seguintes falhavam para sempre**.
    ///
    /// ## Por que `negada` bloqueia no modo manual e não bloqueia no automático
    ///
    /// Não é inconsistência, é a diferença entre haver e não haver alguém para agir:
    ///
    /// - **Manual** (a pessoa tocou "Conectar"): parar em `.permissaoNegada` mostra a frase certa
    ///   e o botão que abre os Ajustes. Conectar mesmo assim gastaria 30 s de prazo para chegar à
    ///   mesma conclusão por um caminho pior.
    /// - **Automático** (`--endereco`, lançado por `devicectl`/`idevicedebug`, ninguém olhando):
    ///   segue em frente **de propósito**. O veredito da sonda é sinal indireto, e barrar uma
    ///   corrida de bancada por causa dele seria deixar o instrumento decidir o que o produto faz
    ///   — o defeito que `docs/regras-de-frente.md` chama de instrumento entrando na medição.
    ///   Seguindo em frente, a corrida produz as **duas** evidências em vez de uma.
    ///
    /// `indefinida` segue em frente nos dois modos, e é o caso **normal** sem ninguém olhando: o
    /// alerta fica na tela sem resposta até o prazo. Concluir "negada" a partir de "ninguém
    /// respondeu" seria mandar a pessoa aos Ajustes sem motivo.
    private func pedirPermissaoEntaoIniciar(endereco: String, pin: String?, segundos: Double,
                                            automatico: Bool) {
        // A sonda solicita acesso pela mesma rota de rede usada pela conexão.
        // A tela pode orientar a pessoa enquanto o alerta está pendente; NWError/NWPath
        // permitem distinguir causas sem depender do texto traduzido do núcleo.
        // O prazo se estende enquanto o alerta está na tela. Ver PermissaoDeRedeLocal.
        painel.fase = .pedindoPermissao
        painel.precisaDeRedeLocal = false
        // Na primeira vez desta instalação o aviso do sistema vai subir por cima desta tela em
        // menos de um segundo. Dizer isso **antes** é a diferença entre um diálogo que aparece do
        // nada e um que a pessoa estava esperando.
        let jaTentou = PermissaoDeRedeLocal.jaTentouNaLan
        painel.dizer { jaTentou ? tr("verificando o acesso à rede local…") : PermissaoDeRedeLocal.textoPrimeiraVez }

        let pedidoEm = Medidas.agoraUs()
        PermissaoDeRedeLocal.pedir(destino: endereco) { [weak self] resposta in
            guard let self else { return }
            // O custo do pedido é medido e dito, porque ele entra no caminho de **toda** corrida.
            // No caminho feliz o `ECONNREFUSED` chega em milissegundos; se algum dia não chegar,
            // esta linha é que vai denunciar.
            let ms = Double(Medidas.delta(Medidas.agoraUs(), pedidoEm)) / 1000
            Diario.dizer(String(format: "permissão de Rede Local: %@ em %.1f ms (modo %@) [%@]",
                                resposta.rawValue, ms, automatico ? "automático" : "manual",
                                PermissaoDeRedeLocal.testemunho))

            if resposta == .negada, !automatico {
                self.painel.fase = .permissaoNegada
                // O botão "Abrir os Ajustes" só aparece para quem tem o que ligar lá. Mandar aos
                // Ajustes quem está com o diálogo do sistema na tela seria mandar a pessoa sair da
                // tela onde a resposta está — a mesma família de defeito, no terceiro lugar em que
                // ela cabe. A decisão mora inteira em `PermissaoDeRedeLocal.conselho`.
                let conselho = PermissaoDeRedeLocal.conselho
                self.painel.precisaDeRedeLocal =
                    (conselho == .abraOsAjustes || conselho == .talvezPermissao)
                self.painel.dizer { PermissaoDeRedeLocal.texto }
                return
            }
            if resposta == .negada {
                Diario.dizer("!! seguindo mesmo assim: modo automático não tem quem responda o "
                             + "alerta, e a falha de conexão a seguir é a segunda testemunha")
            }
            self.iniciar(endereco: endereco, pin: pin, segundos: segundos)
        }
    }

    // --- o caminho da bancada ------------------------------------------------------------------

    /// Lê os argumentos de lançamento. Sem `--endereco`, não há modo automático e o app segue o
    /// caminho de produto — que agora começa na tela de escolha de papel.
    ///
    /// `UserDefaults` **não** é usado para isto de propósito, mesmo que o iOS injete argumentos
    /// `-chave valor` lá: um argumento de bancada persistido viraria estado que sobrevive à
    /// corrida seguinte, e uma corrida que se comporta diferente por causa da anterior é a família
    /// de defeito que este projeto persegue.
    ///
    /// Devolve `true` quando há modo automático — é o que faz `QuallApp` pular a tela de escolha.
    @discardableResult
    func lerArgumentos() -> Bool {
        let args = CommandLine.arguments
        func valor(_ chave: String) -> String? {
            guard let i = args.firstIndex(of: chave), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // **`--laco-de-audio`: o emissor e o receptor no mesmo processo, por `127.0.0.1`.**
        //
        // É o equivalente iOS do `laco-de-audio.py` do Android, e ele existe porque a única outra
        // forma de fazer um slot de áudio chegar ao `AVAudioEngine` deste app é uma sessão de
        // rede — que a permissão de Rede Local do iPad bloqueia até alguém tocar num interruptor
        // (ver `PermissaoDeRedeLocal`). Loopback não passa por essa permissão.
        //
        // Ele **fabrica** o `--endereco`, em vez de exigi-lo, para que a corrida de bancada seja
        // uma linha só e para que ninguém possa apontá-lo, por engano, a um aparelho de verdade:
        // um laço que sai do aparelho deixa de ser laço.
        if args.contains("--laco-de-audio") {
            let pin = valor("--pin") ?? "424242"
            let segundos = Double(valor("--segundos") ?? "") ?? 25
            // Meio segundo a mais no emissor: ele tem de continuar mandando enquanto o receptor
            // fecha os contadores, senão a última volta do relato pega uma track já morta.
            LacoDeAudio.hospedar(pin: pin, segundos: segundos + 1.5)
            automatico = ("127.0.0.1:\(LacoDeAudio.porta)", pin, segundos, 0.5)
            Diario.dizer("laço de áudio: --pin (seis dígitos) --segundos \(segundos); "
                         + "o app hospeda e se conecta em 127.0.0.1:\(LacoDeAudio.porta)")
            return true
        }

        guard let endereco = valor("--endereco") else { return false }
        let pin = valor("--pin")
        let segundos = Double(valor("--segundos") ?? "") ?? 40
        // **`--esperar` existe por causa de uma medição, e é o achado mais caro da frente do
        // receptor.** Na primeira corrida boa o vídeo chegou a 30,0 fps e **parou seco aos 8,6 s**,
        // com o emissor ainda mandando e sem nenhuma falha de envio. A causa estava no `caminho`
        // que o emissor imprime: `fd2a:7902:e4db::2 <-> fd2a:7902:e4db::1`, que não é a Wi-Fi — é o
        // **túnel do CoreDevice**, a interface que o `devicectl` cria para falar com o aparelho e
        // que ele desmonta alguns segundos depois de o comando de lançamento voltar. O ICE tinha
        // escolhido aquele par por ser o de menor latência, e a mídia morreu junto com o túnel.
        //
        // Não é defeito do produto e não é defeito do núcleo: é o instrumento entrando na medição.
        let esperar = Double(valor("--esperar") ?? "") ?? 0.5
        automatico = (endereco, pin, segundos, esperar)
        Diario.dizer("modo automático: endereço informado "
                     + "--pin \(pin == nil ? "(nenhum, retomada)" : "(seis dígitos)") "
                     + "--segundos \(segundos) --esperar \(esperar)")
        return true
    }

    /// Dispara a corrida automática, se houver. Chamado uma vez, da abertura da tela.
    func talvezAutomatico() {
        guard let a = automatico else { return }
        automatico = nil
        // Mesmo sem `--esperar`, meio segundo de adiamento é obrigatório: a `WindowGroup` ainda não
        // montou a camada de exibição, e o primeiro quadro chegaria numa
        // `AVSampleBufferDisplayLayer` sem superfície — que é o caso em que os contadores sobem e a
        // tela fica preta, o pior sintoma possível para um receptor.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, a.esperar)) { [weak self] in
            self?.pedirPermissaoEntaoIniciar(endereco: a.endereco, pin: a.pin,
                                             segundos: a.segundos, automatico: true)
        }
    }
}
