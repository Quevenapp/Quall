import Combine
import Foundation

/// Qual dos dois papéis a pessoa escolheu nesta abertura do app.
///
/// # Por que existe um objeto para isto, e não um `@State` na raiz
///
/// Três lugares diferentes escrevem esta escolha, e dois deles não são um toque na tela:
///
/// 1. a tela de escolha (`TelaDeModo`), que é o caminho da pessoa;
/// 2. o **modo automático** de bancada (`--endereco`), que precisa entrar direto em `.exibir` sem
///    nenhum dedo — é o que permite a corrida sem toque do iPad continuar existindo depois da
///    unificação; e os do teleprompter (`--prompter`, `--controle`), pelo mesmo motivo;
/// 3. a **retomada**: se a appex já está transmitindo quando o app abre (ela sobrevive ao app, é
///    para isso que é autônoma), o papel já está decidido pelos fatos e a tela de escolha seria
///    uma pergunta cuja resposta o aparelho já deu.
///
/// Um `@State` numa view só serve ao primeiro. Os outros dois escrevem de fora da árvore.
///
/// **`nil` é um estado legítimo e é o inicial**: nenhum papel pré-selecionado. Escolher um padrão
/// (por exemplo, "sempre espelhar") economizaria um toque de quem espelha e esconderia metade do
/// produto de quem exibe — que é exatamente o defeito que a unificação veio consertar, só que
/// dentro do mesmo ícone em vez de em dois.
final class Papel: ObservableObject {

    enum Escolha: String {
        /// Este aparelho anuncia e espera. `quall_host`, na appex (tela) ou no app (câmera).
        case espelhar
        /// Este aparelho escolhe e conecta. `quall_connect`, no app.
        case exibir
        /// Este aparelho **mostra o texto** do teleprompter: hospeda com papel `"teleprompter"`
        /// (`quall_host_with_role`), mostra o PIN e espera o controle. `docs/contrato-teleprompter.md`.
        case teleprompter
        /// Este aparelho **controla** um teleprompter: conecta com papel `"controle_remoto"`
        /// (`quall_connect_with_role`). Todo aparelho faz os dois papéis (decisão do usuário, 13/09).
        case controleRemoto = "controle_remoto"
        /// Este aparelho **mostra o texto e filma com a frontal** ao mesmo tempo (R5): o roteiro
        /// colado à lente, a prévia ao lado, a câmera transmitida pela rede. Duas sessões do núcleo,
        /// independentes: o prompter (`quall_host_with_role`, 7979) e a câmera (`quall_host` na porta
        /// do espelhamento). `docs/teleprompter-com-camera.md`.
        case teleprompterComCamera = "teleprompter_com_camera"
    }

    @Published private(set) var escolha: Escolha?

    /// De onde veio a escolha. Só para o relato: uma corrida de bancada e um toque humano
    /// produzem a mesma tela, e depois ninguém sabe dizer qual foi.
    private(set) var origemDaEscolha = ""

    func escolher(_ e: Escolha, por origem: String = "toque") {
        guard escolha != e else { return }
        escolha = e
        origemDaEscolha = origem
        Diagnostico.nota("APP papel=\(e.rawValue) por=\(origem)")
    }

    /// Volta à tela de escolha. Quem chama é responsável por ter encerrado o que estava no ar —
    /// a raiz não deixa esta tela aparecer com sessão viva, mas isso é uma guarda, não uma
    /// desculpa para largar sessão aberta.
    func voltar() {
        guard escolha != nil else { return }
        Diagnostico.nota("APP papel=nenhum (voltou à escolha)")
        escolha = nil
        origemDaEscolha = ""
    }
}
