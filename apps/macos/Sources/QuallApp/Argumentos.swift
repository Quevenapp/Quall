// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation

/// Os argumentos de bancada do app.
///
/// # Por que um app de produto aceita argumentos
///
/// Porque a alternativa é não conseguir provar nada. Um app macOS que exige permissão de TCC tem
/// de ser aberto pelo LaunchServices (`open -n -W -a Quall.app --args …`) para que o pedido saia
/// no nome dele — `docs/regras-de-frente.md`, "Quem pede a permissão é o processo responsável".
/// Sob `open` não há terminal, não há como clicar, e um agente de bancada não tem mão. Sem
/// `--espelhar-ja` e `--sair-apos`, o caminho de produto deste app seria não-verificável, e a
/// única frase honesta sobre ele seria "não afirmo nada".
///
/// **`-n` é obrigatório no `open`.** Com uma instância já aberta, o `open` apenas a traz para a
/// frente e **descarta os argumentos em silêncio** — o modo mais irritante de um teste mentir.
///
/// Nenhum destes argumentos muda o que a interface faz quando uma pessoa usa o app; eles só
/// dispensam o toque que a pessoa daria.
struct Argumentos {
    /// Onde escrever o registro. Nulo = `~/Library/Logs/Quall/quall-app.log`.
    var registro: String?
    /// Fixa o PIN em vez de sortear. Só para bancada: com PIN sorteado, o outro lado da medição
    /// teria de lê-lo da tela, e ninguém tem olhos aqui.
    var pin: String?
    /// Pré-seleciona a fonte. Aceita o id completo (`tela:1`, `camera:0x…`, `tela-estendida`) ou as
    /// palavras `tela` / `camera`, que pegam a primeira daquele tipo. **`tela` é sempre um monitor de
    /// verdade**: a tela estendida vem depois deles na lista e só é escolhida pelo id dela.
    var fonte: String?
    /// A escala do monitor da tela estendida: `1x` ou `2x` (padrão). Não escolhe a fonte — quem
    /// escolhe é `--fonte=tela-estendida`. Cada escala tem identidade de monitor própria
    /// (`MonitorVirtual.serie(para:)`), então a de uma corrida não contamina a da seguinte.
    var telaEstendida: String?
    /// Quadros por segundo da tela estendida (padrão 60). Existe para comparar 30 com 60 no mesmo
    /// binário: em 10/09 o `SM-X230` pediu 7 IDR em 2 min sem perder pacote, e a suspeita é o
    /// decodificador dele não dar conta de 1920 × 1200 a 60.
    var telaEstendidaHz: Int?
    /// O tamanho do monitor da tela estendida em **pixels**, deitado: `3120x1440`. Padrão: o tablet da
    /// bancada, 1920 × 1200. Fase 1: o receptor ainda não diz o tamanho dele, então testar outro
    /// aparelho (o S24, 10/09) é por aqui.
    var telaEstendidaTamanho: String?
    /// A rede por onde o vídeo sai: o nome BSD da interface (`en12`, `en0`) ou `auto`. Sobrepõe a
    /// escolha lembrada da tela inicial só nesta abertura.
    var rede: String?
    /// Toca em Espelhar sozinho, assim que as fontes forem listadas.
    var espelharJa = false
    /// A tela estendida volta ao `minimumFrameInterval` de um período (o de antes de 11/09), para
    /// comparar — ver `ScreenCapturer.intervaloMinimoDeMeioPeriodo`.
    var capturaPeriodoInteiro = false
    /// Espaça a saída de vídeo a no máximo N Mbit/s; `0` desliga. Sem o argumento vale
    /// ``Emissor/espacamentoPadraoMbps``. Existe para comparar com e sem — ver `quall_set_video_pacing_kbps`.
    var espacamentoMbps: Double?
    /// Teto de KB por quadro no encoder (`TransmissaoAoVivo.tetoDeQuadroBytes`); `0` desliga. Sem o
    /// argumento, o automático da tela estendida (5 quadros médios).
    var tetoQuadroKb: Int?
    /// Segundos entre IDR programados na tela estendida (`TransmissaoAoVivo.gopDaTelaEstendida`); sem o
    /// argumento, 30. `10` é o de antes de 11/09.
    var gopTelaEstendida: Double?
    /// Quadros por segundo capturados e codificados na tela estendida, **separados do Hz do monitor**
    /// (`--tela-estendida-hz`). Sem o argumento, os dois são iguais, como sempre foram. Existe para
    /// medir o monitor a 60 Hz mandando 30: um quadro que a captura perde vira um buraco de 50 ms, e
    /// não de 67 (`docs/tela-estendida.md`, as pausas pequenas da D4).
    var telaEstendidaFps: Int?
    /// Encerra o processo depois de N segundos. É o que faz `open -W` voltar.
    var sairApos: Double?
    /// Liga ou desliga o som, sobrepondo o padrão da interface. Nulo = o padrão.
    var comSom: Bool?
    /// **Modo de prova de áudio.** Toca um tom que este processo gera e limita a captura ao
    /// próprio processo (`EscopoDaCaptura.somenteEsteApp`).
    ///
    /// As duas coisas andam juntas de propósito e não são dois argumentos: o tom existe para dar
    /// uma origem que é nossa, e o escopo existe para garantir que **nada além dela** entre na
    /// captura. Separá-los permitiria pedir o tom sem o escopo — e aí o artefato levaria junto o
    /// som da máquina do usuário, que é exatamente o que `docs/audio.md` §8 proíbe.
    var tomSintetico = false
    /// A frequência do tom, em Hz. Padrão 440. Precisa ficar abaixo do Nyquist do codec mais
    /// estreito (4 kHz no PCMU), senão volta rebatida como outra frequência.
    var tomHz: Double?

    // --- o lado que recebe ---------------------------------------------------------------------

    /// Abre o app já no modo **exibir**, na tela de endereço e PIN, em vez da tela de espelhar.
    var exibir = false
    /// O endereço do emissor (`192.168.56.131:7877` ou `127.0.0.1:17881`). Preenche o campo.
    var endereco: String?
    /// Toca em Conectar sozinho. O `--pin` acima é o PIN digitado neste lado.
    var conectarJa = false
    /// Quanto tempo a **sessão de recepção** dura. Nulo = sem limite, que é o comportamento de
    /// produto: quem manda parar é a pessoa, o emissor, ou o silêncio.
    ///
    /// Separado de `--sair-apos` de propósito, e a diferença já custou uma leitura ambígua nesta
    /// casa: `docs/app-macos.md` §12 registra uma corrida em que o prazo do receptor venceu 180 ms
    /// depois de o emissor derrubar a sessão, e por isso ela **não distingue** "o receptor viu a
    /// sessão cair" de "o relógio dele acabou". Com os dois prazos separados dá para dar ao
    /// receptor uma folga grande e a distinção volta a existir.
    var segundos: Double?
    /// Espera N segundos antes de conectar sozinho.
    ///
    /// Herdado do `--esperar` do receptor iOS, onde ele existe porque o túnel do CoreDevice ganha
    /// o ICE e some depois. **Aqui não há túnel**: o uso é dar tempo de o emissor do outro lado
    /// abrir a porta antes de o receptor bater nela, num roteiro que sobe os dois de uma vez.
    var esperar: Double?

    // --- o teleprompter (`docs/contrato-teleprompter.md`) ----------------------------------------
    //
    // Nomes **próprios**, e não os do receptor de vídeo: `--endereco` e `--conectar-ja` ligam o modo
    // exibir (`exibir = true`) e o `Receptor` conectaria como receptor de vídeo — que o prompter
    // recusa antes do PIN. O `--pin` e o `--sair-apos` são os de sempre.

    /// Abre o app direto numa tela do teleprompter: `prompter` (mostra o texto e hospeda) ou
    /// `controle` (conecta e comanda).
    var teleprompter: String?
    /// A porta de sinalização do prompter. Sem ela, uma livre. Fixa pela vida da tela: depois de uma
    /// queda o prompter hospeda de novo **nesta** porta.
    var porta: UInt16?
    /// O controle conecta sozinho neste `host:porta` (ou `quall://pin@host:porta`).
    var prompter: String?
    /// Um arquivo de texto que vira o roteiro ao abrir a tela — edição local, pelo caminho do editor.
    var teleprompterTexto: String?
    /// Edições locais programadas no tempo (`AcoesDeBancada`): `3:fonte=64,5:espelho=1,…`.
    var teleprompterAcoes: String?
    /// O prompter abre em tela cheia.
    var telaCheia = false
    /// **Troca a pasta de dados** (`~/Library/Application Support/Quall`) por outra: o `device_id`,
    /// os pares e o roteiro salvo da bancada ficam fora dos do usuário. Uma corrida de bancada que
    /// gravasse no `pares.json` de verdade deixaria nele um par por execução da sonda.
    var dados: String?
    /// O prompter não anuncia por mDNS (só o endereço). Numa corrida em 127.0.0.1 o anúncio não
    /// serve para nada, e anunciar é o que pede a permissão de rede local.
    var semMdns = false

    // --- o som do receptor (S4 do `docs/som-no-receptor.md`; D1 e D3 do §12.1) -------------------

    /// Abre mudo. O motor liga e puxa do mesmo jeito — a porta fica ancorada e a medida é a mesma —,
    /// só o ganho vai a zero. É como as corridas de bancada nascem: nenhum roteiro nasce com som.
    var somMudo = false
    /// O volume inicial, de 0 a 1. Sem ele, o último que a pessoa deixou (ou 1).
    var somVolume: Float?
    /// Desliga o mudo automático com a câmera do Quall em uso (D3). Só para bancada.
    var somComCamera = false
    /// Tela estendida: **não** passa o som ao próximo receptor quando o dono sai (D2 do §12.1). A
    /// passagem é o padrão, porque foi a sugestão que o Pessoa Exemplo aceitou; a confirmação está com o
    /// coordenador, e esta chave a desliga sem mexer em código.
    var semPassarSom = false
    /// A claquete da sonda (`quall-probe … --claquete`): o app acha o estouro no som que sai e o
    /// índice da régua na imagem que entra na camada, e escreve as horas no diário. Só bancada.
    var claquete = false
    /// Com `--claquete`: a janela de vídeo do próprio app recapturada pelo ScreenCaptureKit, na
    /// taxa do painel, para o T1 completo do `docs/som-no-receptor.md` §9.4 (a S7). Só a janela
    /// deste processo, e só com a Gravação de Tela já concedida (ver `RecapturaDaJanela`).
    var recapturarJanela = false
    /// A taxa pedida ao SCK na recaptura; sem ela, o dobro da do painel (§20.6: na taxa do painel,
    /// o SCK entregou de 0 a 2 refreshes atrasado). É o controle do instrumento.
    var recapturarJanelaHz: Int?

    // --- o teleprompter com câmera (R5 fase 4, `docs/teleprompter-com-camera.md` §8.9) -------------
    //
    // `--teleprompter=prompter-camera` abre a tela R5 direto. Os argumentos do microfone e da
    // gravação valem também na câmera comum (`--fonte=camera:… --espelhar-ja`).

    /// A câmera da tela R5, pelo `uniqueID` (sem ele: a embutida, ou a última escolhida).
    var camera: String?
    /// O PIN e a porta da sessão de **vídeo** da tela R5 (o `--pin` e o `--porta` são do prompter).
    var pinDaCamera: String?
    var portaDaCamera: UInt16?
    /// O PIN que o **controle** usa quando o app também é receptor (M4, `--controle-em-janela`): o
    /// `--pin` fica com o receptor de vídeo.
    var pinDoPrompter: String?
    /// **O microfone da bancada, pelo `uniqueID`** (G5): só um dispositivo **virtual** abre, e sem
    /// este argumento o microfone não abre na bancada. Nunca o microfone do MacBook.
    var microfone: String?
    /// Liga o microfone S s depois de a câmera montar (o caminho do botão), e desliga D s depois.
    var microfoneApos: Double?
    var microfonePor: Double?
    /// O botão do microfone liga a **fonte sintética** do dono (o tom de quatro notas, sem aparelho de
    /// áudio nenhum): prova o caminho sem o dispositivo virtual.
    var microfoneSintetico = false
    /// Toca o tom de quatro notas **na saída** deste dispositivo virtual (o de laço), para a entrada
    /// dele, aberta por `--microfone=`, trazer o nosso tom. Recusa se for a saída padrão ou a de efeitos.
    var tomNoDispositivo: String?
    /// Grava S s depois de a câmera montar, por D s; ou mata o processo M s depois de começar.
    var gravarApos: Double?
    var gravarPor: Double?
    var matarGravandoApos: Double?
    /// Esconde a prévia S s depois de abrir, por max(S, 30) s.
    var esconderPreviaApos: Double?
    /// Onde as gravações vão, em vez de `~/Movies/Quall`.
    var pastaDeGravacoes: String?
    /// O lado do texto na tela R5: `cima`, `baixo`, `esquerda` ou `direita`.
    var ladoDoTexto: String?
    /// M4: o controle do teleprompter numa janela própria, ao lado do receptor.
    var controleEmJanela = false

    // --- os ajustes da câmera (R9, `docs/controles-de-camera.md` §5) ------------------------------
    //
    // Valem na tela R5 e na câmera comum. Com qualquer argumento, o registro dos ajustes mora num
    // domínio de bancada (`BancadaDosAjustesDaCamera.dominio`), e não no `UserDefaults` do produto.

    /// `luma_media`: a média de luma do plano Y, um quadro a cada 30, no diário (só contador).
    var lumaMedia = false
    /// Os ajustes pelo caminho do painel, `--camera-ajustes-apos` s depois de a câmera montar: uma lista
    /// com `trava-exposicao`, `trava-balanco`, `trava-foco` (o que não estiver na lista fica destravado),
    /// ou `restaurar` ("Restaurar automático").
    var cameraAjustes: String?
    var cameraAjustesApos: Double?
    /// Um clique na prévia, já no referencial do sensor (`x,y` de 0 a 1), `--camera-ponto-apos` s depois
    /// de montar; com `--camera-ponto-travar=1`, o ⌥-clique.
    var cameraPonto: String?
    var cameraPontoApos: Double?
    var cameraPontoTravar = false
    /// Começa sem registro de ajustes (apaga o domínio de bancada uma vez por processo).
    var cameraAjustesLimpos = false

    // --- os retratos das telas (`docs/telas-estudio.md` §9) ----------------------------------------

    /// **Desenha as telas em PNG nesta pasta e sai** (`Retratos`): as vistas de apresentação com dados
    /// de exemplo, por `ImageRenderer`, a 880 × 580 e 2x. Não cria janela, não abre sessão, não lê a
    /// identidade deste Mac nem pede permissão nenhuma — é para provar a tela sem tocar na bancada.
    var retratosDeBancada: String?

    /// Verdadeiro quando qualquer argumento de bancada foi passado. PIN e chaves nunca entram
    /// no diário, inclusive na bancada; só presença, estados e métricas são registrados.
    var modoDeBancada: Bool {
        registro != nil || pin != nil || fonte != nil || espelharJa || sairApos != nil
            || comSom != nil || tomSintetico || telaEstendida != nil || telaEstendidaHz != nil
            || telaEstendidaTamanho != nil || rede != nil
            || exibir || endereco != nil || conectarJa || segundos != nil || esperar != nil
            || teleprompter != nil || dados != nil
            || camera != nil || pinDaCamera != nil || portaDaCamera != nil || pinDoPrompter != nil
            || microfone != nil || microfoneApos != nil || microfonePor != nil || microfoneSintetico
            || tomNoDispositivo != nil || gravarApos != nil || gravarPor != nil || matarGravandoApos != nil
            || esconderPreviaApos != nil || pastaDeGravacoes != nil || ladoDoTexto != nil || controleEmJanela
            || lumaMedia || cameraAjustes != nil || cameraPonto != nil || cameraAjustesLimpos
    }

    /// Algum `--argumento` veio na linha de comando (qualquer um, conhecido ou não).
    var algumArgumento = false

    /// **A regra do microfone da bancada (G5) vale com qualquer argumento**, e não só com os de
    /// `modoDeBancada`: uma corrida com só `--porta=` ou `--mudo` que abrisse a tela da câmera e
    /// tocasse no botão cairia no produto e abriria o microfone padrão — o do MacBook (a revisão de
    /// 25/09). Os três lugares que decidem o microfone (a tela R5, a câmera comum e o menu) leem isto.
    var microfoneNaRegraDaBancada: Bool { modoDeBancada || algumArgumento }

    /// Aberto direto numa tela que **não emite**: o receptor de vídeo ou o teleprompter. Nesses
    /// modos o `Emissor` não monta o catálogo de fontes — montar pede Gravação de Tela e Câmera, e
    /// um app aberto para ver um roteiro não tem por que pedir nenhuma das duas.
    var semEmissao: Bool { exibir || teleprompter != nil }

    /// # A forma `--chave=valor`, e por que ela não é gosto
    ///
    /// O `NSUserDefaults` do AppKit consome a linha de comando **em pares**: um token que começa
    /// com `-` é chave e o **próximo token é o valor dele**, seja ele qual for. Uma bandeira sem
    /// valor no meio da lista desalinha o pareamento, sobra um token sem `-` na posição de chave —
    /// e um token solto é, para o AppKit, **um arquivo a abrir**. Um app lançado "para abrir um
    /// documento" não ganha a janela padrão do `WindowGroup`, e um receptor sem janela decodifica
    /// e não mostra nada, com todos os contadores fechando. Ver ``Janela`` para a medição.
    ///
    /// Com `=`, **todo** token começa com `-` e nada sobra. As duas formas são aceitas para que
    /// nenhum roteiro antigo quebre; os roteiros novos usam `=`.
    static func lidos(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Argumentos {
        var a = Argumentos()
        a.algumArgumento = args.contains { $0.hasPrefix("--") }
        // `--chave=valor` vira `["--chave", "valor"]` **antes** do laço, para que o resto deste
        // arquivo continue tendo um caso por argumento em vez de dois.
        let args = args.flatMap { token -> [String] in
            guard token.hasPrefix("--"), let igual = token.firstIndex(of: "=") else { return [token] }
            return [String(token[token.startIndex..<igual]),
                    String(token[token.index(after: igual)...])]
        }
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--registro": i += 1; if i < args.count { a.registro = args[i] }
            case "--pin": i += 1; if i < args.count { a.pin = args[i] }
            case "--fonte": i += 1; if i < args.count { a.fonte = args[i] }
            #if QUALL_TELA_ESTENDIDA_FUTURA
            case "--tela-estendida": i += 1; if i < args.count { a.telaEstendida = args[i] }
            #endif
            case "--rede": i += 1; if i < args.count { a.rede = args[i] }
            #if QUALL_TELA_ESTENDIDA_FUTURA
            case "--tela-estendida-hz": i += 1; if i < args.count { a.telaEstendidaHz = Int(args[i]) }
            #endif
            #if QUALL_TELA_ESTENDIDA_FUTURA
            case "--tela-estendida-tamanho": i += 1; if i < args.count { a.telaEstendidaTamanho = args[i] }
            #endif
            case "--espelhar-ja": a.espelharJa = true
            #if QUALL_TELA_ESTENDIDA_FUTURA
            case "--captura-periodo-inteiro": a.capturaPeriodoInteiro = true
            #endif
            case "--espacamento-mbps": i += 1; if i < args.count { a.espacamentoMbps = Double(args[i]) }
            case "--teto-quadro-kb": i += 1; if i < args.count { a.tetoQuadroKb = Int(args[i]) }
            #if QUALL_TELA_ESTENDIDA_FUTURA
            case "--gop-tela-estendida": i += 1; if i < args.count { a.gopTelaEstendida = Double(args[i]) }
            #endif
            #if QUALL_TELA_ESTENDIDA_FUTURA
            case "--tela-estendida-fps": i += 1; if i < args.count { a.telaEstendidaFps = Int(args[i]) }
            #endif
            case "--sair-apos": i += 1; if i < args.count { a.sairApos = Double(args[i]) }
            case "--com-som": a.comSom = true
            case "--sem-som": a.comSom = false
            case "--tom-sintetico": a.tomSintetico = true
            case "--tom-hz": i += 1; if i < args.count { a.tomHz = Double(args[i]) }
            case "--exibir": a.exibir = true
            case "--endereco": i += 1; if i < args.count { a.endereco = args[i]; a.exibir = true }
            case "--conectar-ja": a.conectarJa = true; a.exibir = true
            case "--segundos": i += 1; if i < args.count { a.segundos = Double(args[i]) }
            case "--esperar": i += 1; if i < args.count { a.esperar = Double(args[i]) }
            case "--teleprompter": i += 1; if i < args.count { a.teleprompter = args[i] }
            case "--porta": i += 1; if i < args.count { a.porta = UInt16(args[i]) }
            case "--prompter": i += 1; if i < args.count { a.prompter = args[i] }
            case "--teleprompter-texto": i += 1; if i < args.count { a.teleprompterTexto = args[i] }
            case "--teleprompter-acoes": i += 1; if i < args.count { a.teleprompterAcoes = args[i] }
            case "--tela-cheia": a.telaCheia = true
            case "--dados": i += 1; if i < args.count { a.dados = args[i] }
            case "--sem-mdns": a.semMdns = true
            case "--mudo": a.somMudo = true
            case "--volume": i += 1; if i < args.count { a.somVolume = Float(args[i]) }
            case "--som-com-camera": a.somComCamera = true
            case "--sem-passar-som": a.semPassarSom = true
            case "--claquete": a.claquete = true
            case "--recapturar-janela": a.recapturarJanela = true
            case "--recapturar-janela-hz": i += 1; if i < args.count { a.recapturarJanelaHz = Int(args[i]) }
            case "--passar-som": a.semPassarSom = false
            case "--camera": i += 1; if i < args.count { a.camera = args[i] }
            case "--pin-da-camera": i += 1; if i < args.count { a.pinDaCamera = args[i] }
            case "--porta-da-camera": i += 1; if i < args.count { a.portaDaCamera = UInt16(args[i]) }
            case "--pin-do-prompter": i += 1; if i < args.count { a.pinDoPrompter = args[i] }
            case "--microfone": i += 1; if i < args.count { a.microfone = args[i] }
            case "--microfone-apos": i += 1; if i < args.count { a.microfoneApos = Double(args[i]).map { max(0, $0) } }
            case "--microfone-por": i += 1; if i < args.count { a.microfonePor = Double(args[i]).map { max(0, $0) } }
            case "--microfone-sintetico": a.microfoneSintetico = true
            case "--tom-no-dispositivo": i += 1; if i < args.count { a.tomNoDispositivo = args[i] }
            case "--gravar-apos": i += 1; if i < args.count { a.gravarApos = Double(args[i]).map { max(0, $0) } }
            case "--gravar-por": i += 1; if i < args.count { a.gravarPor = Double(args[i]).map { max(0, $0) } }
            case "--matar-gravando-apos": i += 1; if i < args.count { a.matarGravandoApos = Double(args[i]).map { max(0, $0) } }
            case "--esconder-previa-apos": i += 1; if i < args.count { a.esconderPreviaApos = Double(args[i]).map { max(0, $0) } }
            case "--pasta-de-gravacoes": i += 1; if i < args.count { a.pastaDeGravacoes = args[i] }
            case "--lado-do-texto": i += 1; if i < args.count { a.ladoDoTexto = args[i] }
            case "--controle-em-janela": a.controleEmJanela = true
            case "--luma-media": a.lumaMedia = true
            case "--camera-ajustes": i += 1; if i < args.count { a.cameraAjustes = args[i] }
            case "--camera-ajustes-apos": i += 1; if i < args.count { a.cameraAjustesApos = Double(args[i]).map { max(0, $0) } }
            case "--camera-ponto": i += 1; if i < args.count { a.cameraPonto = args[i] }
            case "--camera-ponto-apos": i += 1; if i < args.count { a.cameraPontoApos = Double(args[i]).map { max(0, $0) } }
            case "--camera-ponto-travar": a.cameraPontoTravar = true
            case "--camera-ajustes-limpos": a.cameraAjustesLimpos = true
            case "--retratos-de-bancada": i += 1; if i < args.count { a.retratosDeBancada = args[i] }
            default: break
            }
            i += 1
        }
        return a
    }
}
