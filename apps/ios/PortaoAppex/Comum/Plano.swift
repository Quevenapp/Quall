import Foundation

/// O roteiro da corrida do degrau 4, escrito pelo app hospedeiro no App Group e lido pela
/// extension quando a transmissão começa.
///
/// Existe porque **iniciar uma transmissão custa um toque humano** e o toque não é
/// automatizável no iPhone 7 (ver `README.md`). Recompilar para mudar "quantos segundos" ou
/// "qual porta" gastaria um toque por experimento. Com o plano em arquivo, o mesmo binário
/// serve para a corrida curta de conferência e para a corrida longa de medição, e o roteiro
/// `degrau4.sh` decide qual é qual sem tocar no Xcode.
///
/// Os instantes são todos contados a partir de `broadcastStarted`, porque é o único relógio que
/// os dois processos compartilham: o app não sabe quando a pessoa vai tocar em "Iniciar
/// Transmissão".
public struct Plano: Codable {
    /// Rótulo da corrida, só para separar as linhas no syslog.
    public var rotulo: String = "corrida"

    /// Quando começar a **calibragem de retenção** dos `CVPixelBuffer` do ReplayKit. Zero
    /// desliga.
    ///
    /// Pergunta que o orçamento inteiro assume respondida e ninguém mediu: os buffers que o
    /// ReplayKit entrega **já estão pagos** na pegada da appex, ou reter um custa memória nova?
    /// Se custarem, todo o resto da conta muda — e a hora de descobrir é **antes** de existir
    /// encoder, sessão ou rede, quando nada mais está mexendo no número.
    ///
    /// O experimento retém um quadro por segundo, registrando a pegada a cada retenção, e para
    /// sozinho se a pegada subir demais: reter meia dúzia de quadros de 750x1334 pode custar
    /// mais que os 46,6 MB inteiros, e um experimento que mata o processo não mede nada.
    public var t_calibragem_s: Double = 4
    public var calibragem_quadros: Int = 6
    /// Quantos bytes a calibragem pode gastar antes de se interromper sozinha.
    public var calibragem_teto_bytes: UInt64 = 12 * 1024 * 1024

    /// Quando chamar `quall_protocol_version()` pela primeira vez. Antes disso a appex está
    /// **linkada e carregada** mas nenhuma linha de Rust rodou — é essa a janela que mede
    /// "quanto custou só existir".
    public var t_versao_s: Double = 15

    /// Quando subir a sessão (`quall_host`). Entre `t_versao_s` e a chegada do receptor a
    /// pegada mede a sessão de pé esperando.
    public var t_host_s: Double = 25

    /// Quando desmontar a primeira sessão. Zero desliga.
    public var t_fim_sessao1_s: Double = 420

    /// Quando subir a **segunda** sessão, na outra porta. Zero desliga.
    ///
    /// A segunda sessão é o experimento da dívida 12 e da dívida 14: `quall_session_close()`
    /// não desmonta a sessão quando o par já sumiu, e `Drop for Session` vaza em três mapas
    /// globais. Se isso morder, a pegada da segunda sessão sobe sobre a da primeira.
    public var t_host2_s: Double = 450

    /// Quando a extension encerra a si mesma com `finishBroadcastWithError`.
    ///
    /// Encerrar por dentro é o que permite duas corridas seguidas com **um** toque cada: sem
    /// isso, parar a transmissão seria mais um toque, e reinstalar por cima de uma appex viva é
    /// pedir para medir outra coisa.
    public var duracao_s: Double = 600

    public var pin: String = "314159"
    public var porta: UInt16 = 7877
    public var porta2: UInt16 = 7878

    /// Teto de resolução: o `PERFIL_H264` anunciado no SDP (`profile-level-id=42e028`, nível
    /// **4.0** desde 01/09/2026) comporta 1920x1080. Os 750x1334 nativos do iPhone 7 passam
    /// inteiros agora — no 3.1 não passavam. Ver `docs/arquitetura-ios.md`.
    public var largura: Int32 = 1080
    public var altura: Int32 = 1920

    /// Quadros por segundo **encodados**. O ReplayKit entrega ~60; encodar 30 é o que o produto
    /// quer para tela e é o que deixa margem térmica numa corrida de dez minutos no A10.
    public var fps: Int32 = 30
    /// **Era `4_000_000` cravado até 02/09/2026.** O padrão agora vem do núcleo, para a mesma
    /// geometria acima: a 1080x1920 são 9 Mbps, e a 720p continuariam sendo os 4 Mbps de sempre.
    /// Ver `quall_core::teto::teto_de_taxa` — quando o teto de resolução subiu em 01/09, este
    /// literal e mais quatro iguais a ele não subiram junto.
    public var bitrate: Int = Plano.tetoDeTaxaPadrao()

    /// O teto de taxa da geometria padrão deste plano, perguntado à fronteira C.
    ///
    /// Recusa da fronteira cai nos 4 Mbps históricos e não em zero: um alvo ausente é um encoder
    /// sem alvo, e isso é pior que um alvo defasado.
    public static func tetoDeTaxaPadrao() -> Int {
        var t = QuallTeto()
        guard quall_teto_ajustar(1080, 1920, 30, &t) == QUALL_STATUS_OK,
              t.teto_de_taxa_bps > 0 else { return 4_000_000 }
        return Int(t.teto_de_taxa_bps)
    }

    /// Quantos quadros podem estar dentro do VideoToolbox ao mesmo tempo antes de a casca
    /// começar a descartar. "Empacota e solta" vale para o encoder também: uma fila aqui
    /// apareceria na medição como se fosse crescimento do núcleo.
    public var encodes_em_voo: Int = 2

    /// Provocar ou não o diálogo de permissão de rede local ao abrir o app. Ver `Degrau4`.
    public var rede_local: Bool = true

    /// **Ensaio**: em vez de abrir a folha do seletor, o próprio app sobe uma sessão e manda
    /// vídeo gerado por ele mesmo.
    ///
    /// Serve para gastar menos toque humano. Tudo o que separa "compila" de "atravessa a rede"
    /// — permissão de rede local, `bind` da sinalização, pareamento por PIN, ICE, DTLS-SRTP,
    /// abertura da track, VideoToolbox no A10, `quall_track_send_frame` — falha igual num app
    /// comum e numa Broadcast Upload Extension, e num app comum se conferem **sem** o toque em
    /// "Iniciar Transmissão". O que o ensaio **não** cobre é o que sobra de verdade para a
    /// appex: o teto de 50 MB e os buffers do ReplayKit.
    public var ensaio: Bool = false
    public var ensaio_s: Double = 45

    public init() {}

    /// Onde o roteiro deixa o plano para o app: o `Documents` do app hospedeiro, que é a única
    /// pasta que o `ios-deploy --upload` alcança.
    ///
    /// Por que não por `--args`: medido nesta rodada, `ios-deploy --args` **não** entrega os
    /// argumentos ao app no iPhone 7 — o app abre, `CommandLine.arguments` não tem o que foi
    /// passado, e não há erro em lugar nenhum. Um arquivo enviado por house arrest é um caminho
    /// que dá para conferir do MacBook antes de gastar o toque humano.
    public static let nomeNoDocuments = "plano-degrau4.json"

    /// Decodificação **explícita**, campo a campo, com o padrão da struct quando a chave falta.
    ///
    /// A síntese do `Decodable` exige toda chave presente: um JSON sem `pin` faria o decoder
    /// lançar, o `carregar()` cair no plano padrão e a corrida durar dez minutos onde o roteiro
    /// pediu dois. O erro seria silencioso e apareceria como "a medição não bate" — que é o
    /// tipo de defeito que custa uma corrida inteira e um toque humano para descobrir.
    enum CodingKeys: String, CodingKey {
        case rotulo, t_versao_s, t_host_s, t_fim_sessao1_s, t_host2_s, duracao_s
        case pin, porta, porta2, largura, altura, fps, bitrate, encodes_em_voo, rede_local
        case t_calibragem_s, calibragem_quadros, calibragem_teto_bytes
        case ensaio, ensaio_s
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let padrao = Plano()
        func ler<T: Decodable>(_ chave: CodingKeys, _ p: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: chave)) .flatMap { $0 } ?? p
        }
        rotulo = ler(.rotulo, padrao.rotulo)
        t_calibragem_s = ler(.t_calibragem_s, padrao.t_calibragem_s)
        calibragem_quadros = ler(.calibragem_quadros, padrao.calibragem_quadros)
        calibragem_teto_bytes = ler(.calibragem_teto_bytes, padrao.calibragem_teto_bytes)
        t_versao_s = ler(.t_versao_s, padrao.t_versao_s)
        t_host_s = ler(.t_host_s, padrao.t_host_s)
        t_fim_sessao1_s = ler(.t_fim_sessao1_s, padrao.t_fim_sessao1_s)
        t_host2_s = ler(.t_host2_s, padrao.t_host2_s)
        duracao_s = ler(.duracao_s, padrao.duracao_s)
        pin = ler(.pin, padrao.pin)
        porta = ler(.porta, padrao.porta)
        porta2 = ler(.porta2, padrao.porta2)
        largura = ler(.largura, padrao.largura)
        altura = ler(.altura, padrao.altura)
        fps = ler(.fps, padrao.fps)
        bitrate = ler(.bitrate, padrao.bitrate)
        encodes_em_voo = ler(.encodes_em_voo, padrao.encodes_em_voo)
        rede_local = ler(.rede_local, padrao.rede_local)
        ensaio = ler(.ensaio, padrao.ensaio)
        ensaio_s = ler(.ensaio_s, padrao.ensaio_s)
    }

    public static var arquivo: URL? {
        Diario.pastaDoGrupo?.appendingPathComponent("plano.json")
    }

    /// Lê o plano do App Group. Sem arquivo, devolve o padrão — e diz qual foi, para que o
    /// relato nunca dependa de adivinhar o que estava valendo.
    /// Devolve o plano **e o motivo**, para que cair no padrão nunca passe em silêncio.
    ///
    /// Sem isto, uma appex que não achasse o arquivo no App Group rodaria o plano padrão — dez
    /// minutos, com sessão e segunda sessão — onde o roteiro pediu cem segundos de linha de
    /// base. A corrida terminaria "bem" e mediria outra coisa.
    public static func carregarComMotivo() -> (Plano, String) {
        guard let arquivo else { return (Plano(), "PADRÃO-SEM-APP-GROUP") }
        guard let dados = try? Data(contentsOf: arquivo) else {
            return (Plano(), "PADRÃO-SEM-ARQUIVO")
        }
        guard let plano = try? JSONDecoder().decode(Plano.self, from: dados) else {
            return (Plano(), "PADRÃO-JSON-ILEGÍVEL(\(dados.count) bytes)")
        }
        return (plano, "App Group")
    }

    public static func carregar() -> Plano { carregarComMotivo().0 }

    public func gravar() throws {
        guard let arquivo = Plano.arquivo else {
            throw NSError(domain: "Plano", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sem App Group"])
        }
        try JSONEncoder().encode(self).write(to: arquivo, options: .atomic)
    }

    /// Uma linha só, para o syslog. O que foi medido tem de sair junto com a condição em que
    /// foi medido, senão o número não prova nada.
    /// Uma linha só, para o syslog. O que foi medido tem de sair junto com a condição em que foi
    /// medido, senão o número não prova nada.
    ///
    /// **`ensaio` vem primeiro, e está aqui porque a falta dele custou uma tentativa.** A versão
    /// anterior deste resumo imprimia todos os prazos e omitia justamente o campo que decide o
    /// **modo** da corrida. Um plano de ensaio decodificado com perfeição — todos os prazos em
    /// zero, porque é isso que o ensaio pede — ficou idêntico no log a um plano lido pela
    /// metade, e a leitura errada do log virou diagnóstico errado. Campo que muda o
    /// comportamento não pode ficar de fora do eco.
    public var resumo: String {
        "rotulo=\(rotulo) ensaio=\(ensaio) ensaio_s=\(ensaio_s) rede_local=\(rede_local)"
            + " t_calib=\(t_calibragem_s)x\(calibragem_quadros)"
            + " t_versao=\(t_versao_s) t_host=\(t_host_s)"
            + " t_fim1=\(t_fim_sessao1_s) t_host2=\(t_host2_s) duracao=\(duracao_s)"
            + " porta=\(porta)/\(porta2) dim=\(largura)x\(altura) fps=\(fps) bitrate=\(bitrate)"
            + " em_voo=\(encodes_em_voo) calib_teto=\(calibragem_teto_bytes) pin=\(pin)"
    }

    /// O plano decodificado, de volta a JSON com as chaves em ordem, para que o roteiro no
    /// MacBook possa **comparar com o que enviou**.
    ///
    /// O eco existe porque o modo de falha que custou duas tentativas do usuário tem sempre a
    /// mesma forma: uma condição que deveria abortar passou em silêncio. Um plano que chega pela
    /// metade — chave nova que o binário no aparelho ainda não conhece, campo com o tipo errado,
    /// arquivo truncado no envio — produz uma corrida que roda bonito e mede outra coisa. Com o
    /// eco, o roteiro compara campo a campo e aborta antes de gastar o toque.
    public var eco: String {
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.sortedKeys]
        guard let dados = try? codificador.encode(self) else { return "{}" }
        return String(decoding: dados, as: UTF8.self)
    }
}
