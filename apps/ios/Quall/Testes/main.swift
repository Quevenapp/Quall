// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Testes das funções puras do emissor, rodando **no MacBook**, sem aparelho e sem toque humano.
///
/// Existem por causa do defeito mais caro desta frente: a corrida de 464 s do degrau 4 morreu com
/// `EXC_BREAKPOINT` numa subtração de `UInt64` — e essa conta é uma função pura de duas entradas.
/// Um teste de cinco linhas no MacBook teria pego o defeito **antes** de gastar uma corrida de
/// dez minutos e um toque humano que o iPhone 7 não automatiza.
///
/// A regra que fica: toda conta que possa derrubar o processo sai do meio do caminho do quadro e
/// vira função com nome, testada aqui. Rodar:
///
///     ./Testes/rodar.sh
///
/// Este arquivo **não entra em nenhum alvo do app** — ele é compilado à parte pelo roteiro. É a
/// separação por processo antes da separação por bandeira: o binário embarcado não pode conter
/// código de bancada nem por engano, porque o código de bancada não está na lista de fontes.
enum Testes {
    static var falhas = 0

    static func conferir(_ condicao: Bool, _ oQue: String) {
        if condicao {
            print("  ok   \(oQue)")
        } else {
            print("  FALHA \(oQue)")
            falhas += 1
        }
    }

    static func rodar() {
        // Os testes comparam textos em português: o idioma fica em PT, qualquer que seja o do Mac.
        Idioma.usarTabelas(de: [], idioma: .pt)
        print("Carimbo.microssegundos")
        // O caso que derruba: `CMTime` inválido faz `CMTimeGetSeconds` devolver NaN, e
        // `UInt64(NaN)` é erro fatal. Este é o teste que a corrida de 464 s não teve.
        conferir(Carimbo.microssegundos(de: .invalid) == 0, "CMTime inválido (NaN) devolve 0")
        conferir(Carimbo.microssegundos(de: .indefinite) == 0, "CMTime indefinido devolve 0")
        conferir(Carimbo.microssegundos(de: .positiveInfinity) == 0, "infinito devolve 0")
        conferir(Carimbo.microssegundos(de: .negativeInfinity) == 0, "menos infinito devolve 0")
        conferir(Carimbo.microssegundos(de: .zero) == 0, "zero devolve 0")
        conferir(Carimbo.microssegundos(de: CMTime(value: -5, timescale: 30)) == 0,
                 "tempo negativo devolve 0")
        conferir(Carimbo.microssegundos(de: CMTime(value: 30, timescale: 30)) == 1_000_000,
                 "1 s vira 1 000 000 µs")
        conferir(Carimbo.microssegundos(de: CMTime(value: 1, timescale: 30)) == 33_333,
                 "1/30 s vira 33 333 µs")
        // Uma transmissão de dias ainda cabe; o que importa é não armadilhar.
        conferir(Carimbo.microssegundos(de: CMTime(value: 86_400, timescale: 1)) == 86_400_000_000,
                 "um dia inteiro cabe em UInt64")

        print("CodificadorH264.destino — o teto de 1920x1080 do SDP (nível 4.0)")
        // **O teto subiu de 1280x720 para 1920x1080 em 01/09/2026** (`profile-level-id=42e028`).
        // O iPhone 7 em pé: 750x1334 cabia mal no 3.1 e agora passa **inteiro**.
        conferir(CodificadorH264.destino(largura: 750, altura: 1334,
                                         tetoMaior: 1920, tetoMenor: 1080) == (750, 1334),
                 "750x1334 (iPhone 7 em pé) passa nativo no nível 4.0")
        // O mesmo aparelho deitado. Sem isto, um quadro deitado entra numa sessão em pé e o
        // VideoToolbox **estica** a imagem, em silêncio.
        conferir(CodificadorH264.destino(largura: 1334, altura: 750,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1334, 750),
                 "1334x750 (iPhone 7 deitado) passa nativo")
        // O iPhone X é 1125x2436, mais alongado que o 7, e continua sendo cortado — quem manda é
        // o **lado maior**: 1920/2436 = 0,78818, e 1125 × 0,78818 = 886,7 → 886 (par).
        conferir(CodificadorH264.destino(largura: 1125, altura: 2436,
                                         tetoMaior: 1920, tetoMenor: 1080) == (886, 1920),
                 "1125x2436 (iPhone X) é limitado pelo lado maior, e vira 886x1920")
        conferir(CodificadorH264.destino(largura: 1920, altura: 1080,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1920, 1080),
                 "quem já está no teto não é reescalado")
        conferir(CodificadorH264.destino(largura: 640, altura: 480,
                                         tetoMaior: 1920, tetoMenor: 1080) == (640, 480),
                 "quem é menor que o teto não é ampliado")
        // **A função continua parametrizada, e este vetor é quem garante.** Com o teto antigo ela
        // tem de produzir a resposta antiga — se alguém fixar 1920x1080 lá dentro, quebra aqui.
        conferir(CodificadorH264.destino(largura: 750, altura: 1334,
                                         tetoMaior: 1280, tetoMenor: 720) == (720, 1280),
                 "com o teto de 3.1 a resposta antiga volta: a função não fixa número")
        // Dimensão ímpar não existe em 4:2:0. Arredondar para baixo é obrigatório.
        let (l, a) = CodificadorH264.destino(largura: 1125, altura: 2436,
                                             tetoMaior: 1920, tetoMenor: 1080)
        conferir(l % 2 == 0 && a % 2 == 0, "a saída é sempre par nos dois lados")
        conferir(max(l, a) <= 1920 && min(l, a) <= 1080,
                 "nenhum lado passa do teto anunciado")
        // Entradas absurdas não podem derrubar nem devolver zero. O padrão de emergência subiu
        // junto com o teto: era (720, 1280), hoje é (1080, 1920).
        conferir(CodificadorH264.destino(largura: 0, altura: 0,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1080, 1920),
                 "dimensão zero cai no padrão em vez de dividir por zero")
        conferir(CodificadorH264.destino(largura: -10, altura: -10,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1080, 1920),
                 "dimensão negativa cai no padrão")

        print("CodificadorH264.destino — o que a câmera entrega")
        // A câmera é montada em `.hd1920x1080` desde 07/09/2026, com `videoOrientation =
        // .portrait`, e o ISP entrega o quadro **já girado**: 1080 de largura por 1920 de altura.
        // Não é reescalado, e é isso que o teste fixa — um dia em que passasse a ser, alguém
        // estaria pagando uma conversão por quadro sem saber.
        //
        // Os vetores de 720p ficam, e não por nostalgia: `montarCaptura` cai em `.hd1280x720`
        // quando o aparelho não oferece 1080p, e esse ramo tem de continuar passando intacto.
        conferir(CodificadorH264.destino(largura: 1080, altura: 1920,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1080, 1920),
                 "1080x1920 (câmera em pé) passa intacto")
        conferir(CodificadorH264.destino(largura: 1920, altura: 1080,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1920, 1080),
                 "1920x1080 (câmera deitada) passa intacto")
        conferir(CodificadorH264.destino(largura: 720, altura: 1280,
                                         tetoMaior: 1920, tetoMenor: 1080) == (720, 1280),
                 "720x1280 (queda para .hd1280x720 em pé) passa intacto")
        conferir(CodificadorH264.destino(largura: 1280, altura: 720,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1280, 720),
                 "1280x720 (queda para .hd1280x720 deitado) passa intacto")
        // O aparelho que não tem nem 1080p nem 720p cai em `.high`, que é "o que o aparelho achar
        // melhor" e **não tem teto declarado**. Sem o nosso teto, o fluxo violaria o nível
        // anunciado no SDP — em silêncio. 4K é o caso que exercita isso hoje.
        conferir(CodificadorH264.destino(largura: 2160, altura: 3840,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1080, 1920),
                 "2160x3840 (preset .high em pé) é trazido para 1080x1920")
        conferir(CodificadorH264.destino(largura: 3840, altura: 2160,
                                         tetoMaior: 1920, tetoMenor: 1080) == (1920, 1080),
                 "3840x2160 (preset .high deitado) é trazido para 1920x1080")

        print("CodificadorH264.nomeDoFormato — a medição do formato de entrada")
        // É esta função que transforma suposição em medição nos dois emissores: a appex registra
        // o que o ReplayKit entrega, o app registra o que a câmera entrega. Se ela mentir, a
        // linha do log mente junto e o diagnóstico da faixa de cor aponta para o lugar errado.
        conferir(CodificadorH264.nomeDoFormato(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                 == "420f(faixa-completa)", "420f é nomeado como faixa completa")
        conferir(CodificadorH264.nomeDoFormato(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                 == "420v(faixa-limitada)", "420v é nomeado como faixa limitada")
        conferir(CodificadorH264.nomeDoFormato(kCVPixelFormatType_32BGRA) == "BGRA",
                 "um formato inesperado sai pelos quatro caracteres, e não como número")

        enderecos()
        fluidez()

        print("")
        if falhas == 0 {
            print("todos os testes puros passaram")
        } else {
            print("\(falhas) teste(s) falharam")
        }
    }

    // ------------------------------------------------------------------------------------------
    // `Enderecos` — a classificação que destravou o cabo, e a tela que parou de mentir.
    //
    // Estes testes existem por um defeito que o usuário achou **usando o produto**: com só o cabo
    // USB plugado, o botão de emitir ficava desabilitado e a tela escrevia "sem rede Wi‑Fi" — de
    // pé sobre o enlace que na mesma manhã entregou 19 255 pacotes com 0,000 % de perda, três
    // câmeras iOS ao mesmo tempo (`docs/bancada.md`, o estúdio).
    //
    // São funções puras de entradas de texto, e é por isso que dá para exercitá-las aqui: a parte
    // que fala com o sistema (`getifaddrs`) ficou em `ipv4()`, e a decisão saiu de dentro dela.
    // O que **não** se prova aqui está escrito no relatório da frente: que o botão aparece
    // habilitado e que o endereço mostrado é o que funciona são coisas de aparelho.
    // ------------------------------------------------------------------------------------------
    static func enderecos() {
        typealias Enlace = Enderecos.Enlace

        print("Enderecos.classificar — `169.254/16` virou classe, e não sumiu")
        // A refutação da generalização de 26/08, em três endereços que de fato carregaram vídeo.
        conferir(Enderecos.classificar(ip: "169.254.20.3", interface: "en2") == .cabo,
                 "169.254.20.3 fora do en0 é cabo (o iPad da corrida de Modo Avião)")
        conferir(Enderecos.classificar(ip: "169.254.20.2", interface: "en3") == .cabo,
                 "169.254.20.2 fora do en0 é cabo (o iPhone X do estúdio)")
        conferir(Enderecos.classificar(ip: "169.254.212.12", interface: "en4") == .cabo,
                 "169.254.212.12 fora do en0 é cabo (o iPhone 7 do estúdio)")
        // O extremo da faixa: /16 inteiro, não só o meio dele.
        conferir(Enderecos.classificar(ip: "169.254.0.1", interface: "en2") == .cabo,
                 "o começo da faixa link-local é cabo")
        conferir(Enderecos.classificar(ip: "169.254.255.254", interface: "en2") == .cabo,
                 "o fim da faixa link-local é cabo")
        // E o vizinho de fora da faixa continua sendo LAN comum.
        conferir(Enderecos.classificar(ip: "169.253.1.1", interface: "en2") == .lan,
                 "169.253.x não é link-local")
        conferir(Enderecos.classificar(ip: "169.255.1.1", interface: "en2") == .lan,
                 "169.255.x não é link-local")

        print("Enderecos.classificar — a heurística do en0, e para que lado ela erra")
        // O palpite, escrito como palpite no código: no iPhone e no iPad o Wi-Fi é `en0`, então um
        // link-local ali é Wi-Fi que não pegou DHCP, e não cabo. Erra **escondendo**, nunca
        // inventando cabo — que seria a tela mentindo de novo, do avesso.
        conferir(Enderecos.classificar(ip: "169.254.75.173", interface: "en0") == nil,
                 "link-local no en0 é Wi-Fi sem DHCP, e continua descartado")
        conferir(Enderecos.classificar(ip: "169.254.75.173", interface: "en8") == .cabo,
                 "o MESMO endereço fora do en0 é cabo — quem decide é a interface")

        print("Enderecos.classificar — as duas faixas que continuam fora")
        // Estas duas de fato não são alcançáveis por par nenhum, e a medida que as pôs na lista
        // continua valendo: o clat do S24 Ultra e o CGNAT do iPhone 15.
        conferir(Enderecos.classificar(ip: "192.0.0.2", interface: "rmnet_data0") == nil,
                 "192.0.0.2 (clat 464XLAT) continua descartado")
        conferir(Enderecos.classificar(ip: "192.0.0.255", interface: "en2") == nil,
                 "o /24 inteiro de IETF Protocol Assignments continua descartado")
        conferir(Enderecos.classificar(ip: "192.0.1.1", interface: "en2") == .lan,
                 "192.0.1.1 está fora do /24 e é LAN")
        conferir(Enderecos.classificar(ip: "100.64.20.2", interface: "pdp_ip0") == nil,
                 "100.64.20.2 (CGNAT do pdp_ip0) continua descartado")
        conferir(Enderecos.classificar(ip: "100.64.0.0", interface: "pdp_ip0") == nil,
                 "o começo do 100.64/10 continua descartado")
        conferir(Enderecos.classificar(ip: "100.127.255.255", interface: "pdp_ip0") == nil,
                 "o fim do 100.64/10 continua descartado")
        conferir(Enderecos.classificar(ip: "100.63.1.1", interface: "en0") == .lan,
                 "100.63.x está abaixo do CGNAT e é LAN")
        conferir(Enderecos.classificar(ip: "100.128.1.1", interface: "en0") == .lan,
                 "100.128.x está acima do CGNAT e é LAN")

        print("Enderecos.classificar — o que já funcionava continua igual")
        conferir(Enderecos.classificar(ip: "192.168.56.137", interface: "en0") == .lan,
                 "192.168.56.137 (a Wi-Fi do iPad na foto do estúdio) é LAN")
        conferir(Enderecos.classificar(ip: "10.77.0.5", interface: "en0") == .lan,
                 "10.x é LAN")
        conferir(Enderecos.classificar(ip: "172.20.54.2", interface: "en2") == .lan,
                 "172.20.10.x (Hotspot Pessoal por USB) é LAN, e não cabo — tem DHCP")
        conferir(Enderecos.classificar(ip: "192.168.60.129", interface: "en5") == .lan,
                 "192.168.42.x (ancoragem USB do Android) é LAN, e é por isso que o ICE já a junta")
        // Endereço público não se descarta: há LAN com endereço público de verdade.
        conferir(Enderecos.classificar(ip: "200.1.2.3", interface: "en0") == .lan,
                 "endereço público continua sendo LAN")

        print("Enderecos.classificar — entrada torta não vira classe")
        conferir(Enderecos.classificar(ip: "nao-e-ip", interface: "en0") == nil,
                 "texto que não é IP é descartado")
        conferir(Enderecos.classificar(ip: "1.2.3", interface: "en0") == nil,
                 "três octetos são descartados")
        conferir(Enderecos.classificar(ip: "1.2.3.4.5", interface: "en0") == nil,
                 "cinco octetos são descartados")
        conferir(Enderecos.classificar(ip: "999.1.1.1", interface: "en0") == nil,
                 "octeto fora de 0–255 é descartado")
        conferir(Enderecos.classificar(ip: "", interface: "en0") == nil,
                 "texto vazio é descartado")

        print("Enderecos.escolher — principal() não muda de resposta quando há Wi-Fi")
        let wifiECabo: [(interface: String, ip: String, enlace: Enlace)] = [
            ("en0", "192.168.56.137", .lan),
            ("en2", "169.254.20.3", .cabo),
        ]
        // O teste central do item 2 do plano: **acrescentar o cabo, não reordenar o que já
        // funciona.** Quem tem Wi-Fi vê exatamente a mesma tela de antes.
        conferir(Enderecos.escolher(wifiECabo, enlace: .lan) == "192.168.56.137",
                 "com Wi-Fi e cabo, o principal continua sendo o Wi-Fi")
        conferir(Enderecos.escolher(wifiECabo, enlace: .cabo) == "169.254.20.3",
                 "e o cabo é achado ao lado, sem tirar o Wi-Fi do lugar")
        // O caso que o produto não atendia.
        let soCabo: [(interface: String, ip: String, enlace: Enlace)] = [
            ("en2", "169.254.20.3", .cabo),
        ]
        conferir(Enderecos.escolher(soCabo, enlace: .lan) == nil,
                 "só cabo: não há LAN, e principal() diz isso")
        conferir(Enderecos.escolher(soCabo, enlace: .cabo) == "169.254.20.3",
                 "só cabo: principalDoCabo() acha o cabo")
        conferir(Enderecos.escolher([], enlace: .lan) == nil
                 && Enderecos.escolher([], enlace: .cabo) == nil,
                 "sem interface nenhuma, as duas respostas são nil")
        // A preferência por `en0` dentro da classe LAN, que é de 26/08 e não mudou.
        let duasLans: [(interface: String, ip: String, enlace: Enlace)] = [
            ("en5", "10.77.0.5", .lan),
            ("en0", "192.168.56.137", .lan),
        ]
        conferir(Enderecos.escolher(duasLans, enlace: .lan) == "192.168.56.137",
                 "entre duas LANs, o en0 ganha mesmo vindo depois na lista")
        conferir(Enderecos.escolher([("en5", "10.77.0.5", .lan)], enlace: .lan) == "10.77.0.5",
                 "sem en0, a primeira LAN da lista serve")

        print("Enderecos.destaque — o que vai no lugar de destaque")
        // A decisão do caso "tem os dois", escrita como teste para não virar acidente: **ganha a
        // LAN**. O caminho de Wi-Fi está provado, quem o usa não pode ver a tela mudar debaixo de
        // si, e quem digita o endereço é um terceiro aparelho que quase nunca é o do fio.
        conferir(Enderecos.destaque(lan: "192.168.56.137", cabo: "169.254.20.3",
                                    porta: 7877) == "192.168.56.137:7877",
                 "com os dois, o destaque é o da LAN")
        conferir(Enderecos.destaque(lan: nil, cabo: "169.254.20.3",
                                    porta: 7877) == "169.254.20.3:7877",
                 "sem LAN, o destaque é o do cabo — o caso que o produto não atendia")
        conferir(Enderecos.destaque(lan: "192.168.56.137", cabo: nil,
                                    porta: 7877) == "192.168.56.137:7877",
                 "sem cabo, nada muda para quem tem Wi-Fi")
        conferir(Enderecos.destaque(lan: "192.168.56.137", cabo: nil,
                                    porta: 7878) == "192.168.56.137:7878",
                 "a porta vem de quem chama — a da câmera não é a do espelhamento")
        conferir(Enderecos.destaque(lan: nil, cabo: nil, porta: 7877) == nil,
                 "sem nenhum dos dois, não há endereço — e é isso que desabilita o botão")

        print("Enderecos.notaDoEnlace — a tela só fala de cabo quando há cabo")
        conferir(Enderecos.notaDoEnlace(lan: "192.168.56.137", cabo: nil, porta: 7877) == nil,
                 "sem cabo, não há segunda linha: a tela de quem só tem Wi-Fi não mudou")
        conferir(Enderecos.notaDoEnlace(lan: nil, cabo: nil, porta: 7877) == nil,
                 "sem rede nenhuma, não há segunda linha")
        // Com os dois, o endereço do cabo tem de estar **escrito**: numa instalação de estúdio é
        // ele que alguém digita do outro lado, e a corrida de 01/09 rodou com Wi-Fi ligado nos
        // três aparelhos — o caso "tem os dois" É o caso do estúdio.
        let ambos = Enderecos.notaDoEnlace(lan: "192.168.56.137", cabo: "169.254.20.3",
                                           porta: 7877) ?? ""
        conferir(ambos.contains("169.254.20.3:7877"),
                 "com os dois, o endereço do cabo aparece por extenso, com porta")
        conferir(ambos.contains("cabo"), "com os dois, a segunda linha diz que aquilo é o cabo")
        let soFio = Enderecos.notaDoEnlace(lan: nil, cabo: "169.254.20.3", porta: 7877) ?? ""
        conferir(soFio.contains("cabo"),
                 "sem Wi-Fi, a linha debaixo do destaque diz que o endereço é o do cabo")
        conferir(!soFio.contains("169.254.20.3"),
                 "e não repete o endereço, que já está em cima em corpo 30")
    }

    // ------------------------------------------------------------------------------------------
    // `Fluidez` — a distribuição dos intervalos entre entregas à tela.
    //
    // Existe por um defeito que o usuário achou **olhando**: em 01/09/2026 ele disse que faltava
    // fluidez numa corrida cuja média de `fila→tela` era 6,4 ms e estava **certa**. O pior caso
    // da mesma corrida era 226 ms. Média não vê tranco, e o olho só vê tranco.
    //
    // O tipo é puro de propósito — recebe o instante de quem o tem —, e é por isso que a
    // distribuição inteira dá para exercitar aqui: o buraco de 226 ms, o corte do tranco e a
    // porta de congelamento são formas que a amostra tem, não coisas de aparelho. **O que não se
    // prova aqui**: que o instante medido corresponde ao pixel no vidro. Ele não corresponde, e é
    // por isso que o tipo se chama pelo que mede — entrega à camada. Ver o cabeçalho de
    // `Fluidez.swift` e o relatório desta frente.
    //
    // O contrato é o do gêmeo `apps/windows/src/fluidez.rs`, e estas conferências são a prova de
    // que ele foi cumprido letra por letra: mesma linha, mesmos nomes, mesmo corte, mesma âncora.
    // ------------------------------------------------------------------------------------------
    static func fluidez() {
        /// Uma sessão com os intervalos dados, em milissegundos, a partir de um instante qualquer.
        func sessao(_ intervalosMs: [UInt64], desde: UInt64 = 7_777_777) -> Fluidez {
            var f = Fluidez()
            var agora = desde
            f.apresentou(agora)
            for ms in intervalosMs { agora += ms * 1000; f.apresentou(agora) }
            return f
        }

        print("Fluidez — a âncora, e o intervalo que não existe antes do primeiro quadro")
        var primeira = Fluidez()
        primeira.apresentou(1_234_567)
        conferir(primeira.linha().contains("n=0"),
                 "a primeira chamada só ancora: um quadro não faz intervalo")
        conferir(primeira.trancos == 0, "e um quadro só não faz tranco")
        // O que a âncora impede é concreto: a sessão do iPad sobe em ~50 ms e o pareamento por
        // PIN custa mais que isso. Contar desde a abertura plantaria um tranco em toda sessão
        // nova — a subida do ICE dentro da distribuição da imagem.
        conferir(sessao([33], desde: 0).linha().contains("n=1"),
                 "o segundo quadro é que abre a distribuição, e ela começa em 1")

        print("Fluidez — a derivada entre dois quadros, em ms de verdade")
        let doisQuadros = sessao([33])
        conferir(doisQuadros.linha().contains("n=1"), "dois quadros dão exatamente um intervalo")
        conferir(doisQuadros.linha().contains("p50=33"), "e o intervalo é o decorrido real")
        conferir(doisQuadros.linha().contains("max=33"), "o max de uma amostra só é ela mesma")
        conferir(sessao([33]).linha() == sessao([33], desde: 0).linha(),
                 "o instante de partida não entra na conta — só a diferença")

        print("Fluidez — o buraco no meio de uma sessão regular (a corrida de 01/09 em miniatura)")
        // Vinte e nove intervalos de 33 ms e um de 226. A média dá ~39 ms e parece saudável; é
        // exatamente o relatório que não respondeu ao usuário.
        var regular = [UInt64](repeating: 33, count: 29)
        regular.insert(226, at: 15)
        let comBuraco = sessao(regular)
        let l = comBuraco.linha()
        conferir(l.contains("n=30"), "trinta intervalos: \(l)")
        conferir(l.contains("p50=33"), "o centro continua dizendo que está tudo bem: \(l)")
        conferir(l.contains("p95=33"), "e o p95 também — vinte e nove de trinta são pontuais")
        conferir(l.contains("max=226"), "**o max é quem mostra o buraco**: \(l)")
        conferir(l.contains("trancos=1"), "e `trancos` o conta: \(l)")
        // A razão de serem quatro números e não um. A média dos mesmos dados é 39,4 ms —
        // indistinguível de uma sessão a 25 fps sem tranco nenhum.
        let semBuraco = sessao([UInt64](repeating: 39, count: 30))
        conferir(semBuraco.linha().contains("max=39") && semBuraco.trancos == 0,
                 "a sessão de média igual e sem buraco tem max=39 e trancos=0 — e a média não as separa")

        print("Fluidez — as duas corridas do A10s: p50 igual, e toda a diferença na cauda")
        // O achado que fixou este instrumento: Wi-Fi 2,4 GHz e cabo USB deram `p50` praticamente
        // igual no mesmo aparelho. Um relatório de centro diria que os dois enlaces são o mesmo.
        let radio = sessao([UInt64](repeating: 32, count: 20) + [115, 241, 180])
        let cabo = sessao([UInt64](repeating: 32, count: 20) + [39, 39, 39])
        conferir(radio.linha().contains("p50=32") && cabo.linha().contains("p50=32"),
                 "o mesmo p50 nos dois enlaces, que é o que a bancada mediu")
        conferir(radio.trancos == 3 && cabo.trancos == 0,
                 "e `trancos` os separa: \(radio.trancos) contra \(cabo.trancos)")

        print("Fluidez — o corte do tranco é estrito, e o limiar é três tempos de quadro")
        conferir(Fluidez.trancoMs == 100, "o corte é 100 ms — três tempos de quadro a 30 fps")
        conferir(sessao([Fluidez.trancoMs]).trancos == 0, "exatamente no limiar NÃO é tranco")
        // Um microssegundo acima, e não um milissegundo: é o corte que fica fixado, para que a
        // comparação entre duas corridas não dependa de arredondamento na fronteira.
        var noFio = Fluidez()
        noFio.apresentou(0)
        noFio.apresentou(Fluidez.trancoMs * 1000 + 1)
        conferir(noFio.trancos == 1, "um microssegundo acima do limiar É tranco")
        conferir(sessao([99]).trancos == 0 && sessao([101]).trancos == 1,
                 "99 ms não é tranco, 101 ms é")

        print("Fluidez — a porta de congelamento aparece como intervalo maior, e é o ponto")
        // Segurar um quadro condenado não o conserta: a tela para. A cada cinco quadros, três
        // ficam retidos pela porta — o intervalo seguinte é 4 x 33 ms. Medir chegadas esconderia
        // isto por completo: os quadros retidos chegam e decodificam, só não vão para o vidro.
        var comPorta: [UInt64] = []
        for i in 0..<10 { comPorta.append(i % 5 == 0 ? 33 * 4 : 33) }
        let porta = sessao(comPorta)
        conferir(porta.linha().contains("max=132"), "três quadros retidos viram um intervalo de 132 ms")
        conferir(porta.trancos == 2, "e os dois intervalos de 132 ms passam do corte de 100")
        conferir(porta.linha().contains("n=10"), "sem perder nenhum intervalo pelo caminho")

        print("Fluidez — a sessão vazia não afirma nada, e não divide por zero")
        let vazia = Fluidez()
        conferir(vazia.linha().contains("n=0"), "sem quadro nenhum, n=0 e não um número inventado")
        conferir(vazia.linha() == "fluidez_ms=[n=0 p50=0 p95=0 max=0] trancos=0",
                 "a linha existe por extenso: 'não medi' e 'medi zero' se distinguem pelo n")
        conferir(vazia.trancos == 0, "e `trancos` de amostra vazia é zero, não estouro")

        print("Fluidez — o teto de amostras, com o descarte dito em voz alta")
        var longa = Fluidez()
        var t: UInt64 = 0
        longa.apresentou(t)
        for _ in 0..<(Fluidez.maximoDeAmostras + 3) { t += 33_000; longa.apresentou(t) }
        conferir(longa.linha().contains("n=\(Fluidez.maximoDeAmostras)"),
                 "a distribuição para de crescer no teto em vez de a sessão longa comer memória")
        conferir(longa.linha().contains("(+3 além do teto)"),
                 "e os descartados saem na linha — fingir que o n é a sessão inteira seria mentir")
        conferir(!vazia.linha().contains("além do teto"),
                 "sem descarte não há sufixo: a linha do caso normal não carrega ruído")

        print("Fluidez — relógio que não avança não vira 18 quintilhões")
        // A família de defeito que matou a corrida de 464 s do degrau 4: subtração de `UInt64`
        // sem guarda. Aqui não há nenhuma.
        var parado = Fluidez()
        parado.apresentou(1_000_000)
        parado.apresentou(1_000_000)
        conferir(parado.linha().contains("max=0"), "dois quadros no mesmo instante dão intervalo 0")
        var atras = Fluidez()
        atras.apresentou(1_000_000)
        atras.apresentou(999_000)
        conferir(atras.linha().contains("max=0") && atras.trancos == 0,
                 "e um instante anterior ao anterior dá 0, não um número gigante")

        print("Fluidez — a linha é a do contrato, e o nome não é sugestão")
        // `docs/regras-de-frente.md`: nome de contrato é literal. Esta é a mesma forma que o
        // receptor Windows imprime, e é por ela que as duas cascas se comparam.
        conferir(comBuraco.linha()
                 == "fluidez_ms=[n=30 p50=33 p95=33 max=226] trancos=1",
                 "a linha inteira, campo por campo: \(comBuraco.linha())")

        rodarTeleprompter()
    }

    /// As três contas puras do teleprompter (F6b): o nome da instância mDNS, o link de
    /// pareamento, e a geometria que liga a posição do contrato aos pontos da vista.
    static func rodarTeleprompter() {
        print("NomeDaInstancia — alias efêmero público v3")
        let token = "0123456789abcdef0123456789abcdef"
        conferir(NomeDaInstancia.montar(token: token) == "Quall \(token)",
                 "instância pública contém apenas a marca e o token")
        conferir(NomeDaInstancia.host(token: token) == "quall-\(token).local.",
                 "SRV usa alias local efêmero, sem o hostname do aparelho")
        conferir(NomeDaInstancia.montar(token: token)!.utf8.count == 38,
                 "instância válida cabe nos 63 bytes DNS-SD")
        for invalido in ["", "abc", token.uppercased(), token + "0", String(token.dropLast()),
                         "0123456789abcdef0123456789abcdeg", "0000000000000000000000000000000ã"] {
            conferir(!NomeDaInstancia.tokenValido(invalido)
                     && NomeDaInstancia.montar(token: invalido) == nil
                     && NomeDaInstancia.host(token: invalido) == nil,
                     "token fora do contrato é recusado sem tentar publicar")
        }
        let primeiro = NomeDaInstancia.novoToken()
        let segundo = NomeDaInstancia.novoToken()
        conferir(NomeDaInstancia.tokenValido(primeiro) && NomeDaInstancia.tokenValido(segundo),
                 "tokens novos usam 32 bytes ASCII hexadecimais minúsculos")
        conferir(primeiro != segundo, "cada início recebe um token novo")

        print("LinkDePareamento — o endereço digitado ou colado, e o link quall:// antigo")
        conferir(LinkDePareamento.ler("quall://424242@192.168.57.20:7979")
                 == .init(endereco: "192.168.57.20:7979", pin: "424242"), "o link quall:// antigo, inteiro")
        conferir(LinkDePareamento.ler("  QUALL://424242@192.168.57.20:7979/  ")
                 == .init(endereco: "192.168.57.20:7979", pin: "424242"),
                 "maiúsculas, espaço e barra num link colado")
        conferir(LinkDePareamento.ler("quall://42424@192.168.57.20:7979") == nil,
                 "PIN de cinco dígitos é recusado — não vira tentativa de PIN errado")
        conferir(LinkDePareamento.ler("quall://abcdef@192.168.57.20:7979") == nil, "PIN que não é número")
        conferir(LinkDePareamento.ler("quall://192.168.57.20:7979") == nil, "link sem PIN")
        conferir(LinkDePareamento.ler("192.168.57.20:7979") == .init(endereco: "192.168.57.20:7979", pin: nil),
                 "endereço digitado, sem PIN")
        conferir(LinkDePareamento.ler("192.168.57.20") == .init(endereco: "192.168.57.20:7979", pin: nil),
                 "sem porta, vale a do teleprompter (7979), não a 7877 do espelhamento")
        conferir(LinkDePareamento.ler("ipad.local") == .init(endereco: "ipad.local:7979", pin: nil),
                 "nome de host sem porta")
        conferir(LinkDePareamento.ler("[fe80::1]:8000") == .init(endereco: "[fe80::1]:8000", pin: nil), "IPv6 com porta")
        conferir(LinkDePareamento.ler("fe80::1") == .init(endereco: "[fe80::1]:7979", pin: nil), "IPv6 sem colchetes")
        conferir(LinkDePareamento.ler("192.168.57.20:abc") == nil, "porta que não é número")
        conferir(LinkDePareamento.ler("192.168.57.20:0") == nil, "porta zero")
        conferir(LinkDePareamento.ler("   ") == nil, "vazio")

        print("GeometriaDoRoteiro — posição do contrato (0 = começo na linha, 1 = fim nela)")
        // Vista de 800 pt, linha de 60 pt, 100 linhas, linha de leitura a 30 %.
        let g = GeometriaDoRoteiro(alturaDaVista: 800, alturaDaLinha: 60, alturaDoTexto: 6000, linhaDeLeitura: 0.3)
        conferir(g.r == 240, "a linha de leitura fica a 240 pt do topo")
        conferir(g.folgaDeCima == 210 && g.folgaDeBaixo == 530, "as folgas: 210 em cima, 530 embaixo")
        conferir(g.y0 == 0, "posição 0: o centro da primeira linha na linha de leitura, deslocamento 0")
        conferir(g.percurso == 5940, "o percurso é a altura do texto menos uma linha")
        // Com y = y1, o centro da última linha fica em T + alturaDoTexto - L/2 - y1 = R.
        conferir(g.folgaDeCima + g.alturaDoTexto - g.alturaDaLinha / 2 - g.y1 == g.r,
                 "posição 1: o centro da última linha na linha de leitura")
        // O fim do trilho é o fim que a vista rola sozinha: conteúdo - vista.
        let conteudo = g.folgaDeCima + g.alturaDoTexto + g.folgaDeBaixo
        conferir(abs(g.y1 - (conteudo - g.alturaDaVista)) < 1e-9, "y1 é o fim da rolagem natural da vista")
        conferir(abs(g.posicao(deslocamento: g.deslocamento(posicao: 0.37)) - 0.37) < 1e-12,
                 "ida e volta de 0,37 (a menos do último bit do Double)")
        conferir(g.posicao(deslocamento: -100) == 0 && g.posicao(deslocamento: 1e9) == 1, "fora do trilho, prende")
        conferir(g.deslocamento(posicao: .nan) == g.y0, "NaN vai para o começo, não para o infinito")
        conferir(g.pontosPorSegundo(velocidade: 1.5) == 90, "1,5 linhas/s com linha de 60 pt = 90 pt/s")
        let topo = GeometriaDoRoteiro(alturaDaVista: 800, alturaDaLinha: 60, alturaDoTexto: 600, linhaDeLeitura: 0)
        conferir(topo.folgaDeCima == 0 && topo.y0 == 30, "linha de leitura no topo: sem folga negativa")
        let umaLinha = GeometriaDoRoteiro(alturaDaVista: 800, alturaDaLinha: 60, alturaDoTexto: 60, linhaDeLeitura: 0.5)
        conferir(umaLinha.percurso == 0 && umaLinha.posicao(deslocamento: 99) == 0,
                 "uma linha só: percurso zero, posição zero, sem divisão por zero")
        conferir(GeometriaDoRoteiro.noPixel(10.4, escala: 3) == 31.0 / 3, "arredonda ao pixel de uma tela 3x")
        // A linha de leitura em coordenadas do texto: com a linha de leitura longe do topo, o
        // deslocamento 0 põe o centro da primeira linha nela.
        conferir(g.leituraNoTexto(deslocamento: 0) == 30, "deslocamento 0: a leitura no centro da linha 0 (30 pt)")
        conferir(g.deslocamento(leituraNoTexto: 30) == 0 && g.deslocamento(leituraNoTexto: 1030) == 1000,
                 "e a volta, da leitura no texto para o deslocamento")
        conferir(g.deslocamento(leituraNoTexto: -500) == g.y0 && g.deslocamento(leituraNoTexto: 1e9) == g.y1,
                 "fora do texto, prende no trilho")
        conferir(topo.leituraNoTexto(deslocamento: topo.y0) == 30,
                 "linha de leitura no topo: no começo do trilho a leitura ainda está no centro da linha 0")

        rodarLinhasDoRoteiro()
        rodarMedidorDoRoteiro()
        rodarEscolhaDaMelhorImagem()
        rodarRegraDaFonteAutomatica()
        rodarDedosNosBotoes()
        rodarPerguntaDoTexto()
        rodarSolturaDaPorta()
        rodarPoliticaDeCalor()
        rodarZonaDaBorda()
        rodarDivisaoDaTelaComCamera()
        rodarFechoDaTela()
        rodarRepeticaoDoBotao()
        rodarDegrausDaTransmissao()
        rodarTraducao()
        rodarControlesDaCamera()
        rodarControleRemoto()
        rodarMediaDeLuma()
    }

    /// Os degraus da transmissão (decisão do Pessoa Exemplo de 27/09).
    static func rodarDegrausDaTransmissao() {
        print("DegrausDaTransmissao — a transmissão é a prioridade; sobe devagar, desce mais devagar")
        conferir(DegrausDaTransmissao.ruim(esperaNaFila: 0.6, idadeNaEntrada: 0.1, somPerdido: 0)
                 && DegrausDaTransmissao.ruim(esperaNaFila: 0.1, idadeNaEntrada: 0.6, somPerdido: 0)
                 && DegrausDaTransmissao.ruim(esperaNaFila: 0.1, idadeNaEntrada: 0.1, somPerdido: 0.02)
                 && !DegrausDaTransmissao.ruim(esperaNaFila: 0.4, idadeNaEntrada: 0.45, somPerdido: 0),
                 "ruim: espera ou idade acima de 0,5 s, ou som perdido")
        var d = DegrausDaTransmissao()
        conferir(d.janela(ruim: true, transmitindo: true, gravando: true, quente: true) == nil, "uma janela ruim: nada")
        conferir(d.janela(ruim: true, transmitindo: true, gravando: true, quente: true) == .previaPausada, "duas: a prévia pausa")
        conferir(d.janela(ruim: false, transmitindo: true, gravando: true, quente: true) == nil
                 && d.janela(ruim: true, transmitindo: true, gravando: true, quente: true) == nil,
                 "uma boa no meio zera a contagem")
        conferir(d.janela(ruim: true, transmitindo: true, gravando: true, quente: true) == .gravacaoParada,
                 "gravando: o próximo é parar a gravação")
        _ = d.janela(ruim: true, transmitindo: true, gravando: false, quente: true)
        conferir(d.janela(ruim: true, transmitindo: true, gravando: false, quente: true) == .capturaReduzida,
                 "ainda ruim: a captura em 720p")
        conferir(d.janela(ruim: true, transmitindo: true, gravando: false, quente: true) == nil
                 && d.janela(ruim: true, transmitindo: true, gravando: false, quente: true) == nil, "no topo, fica")
        // A sequência da bancada de abd2e9f: janelas boas (espera 4–13 ms) com o aparelho ainda quente.
        var desceuQuente = false
        for _ in 0..<30 { if d.janela(ruim: false, transmitindo: true, gravando: false, quente: true) != nil { desceuQuente = true } }
        conferir(!desceuQuente && d.degrau == .capturaReduzida,
                 "quente, 30 janelas boas: não desce (era a oscilação — a volta ao 1080p reaquecia)")
        for _ in 0..<5 { _ = d.janela(ruim: false, transmitindo: true, gravando: false, quente: false) }
        conferir(d.degrau == .capturaReduzida, "frio há 5 janelas: ainda no topo")
        conferir(d.janela(ruim: false, transmitindo: true, gravando: false, quente: false) == .previaPausada,
                 "frio há 6: desce à prévia pausada (a gravação parada não volta)")
        _ = d.janela(ruim: false, transmitindo: true, gravando: false, quente: true)
        for _ in 0..<5 { _ = d.janela(ruim: false, transmitindo: true, gravando: false, quente: false) }
        conferir(d.degrau == .previaPausada, "esquentou no meio: a contagem do frio recomeça")
        conferir(d.janela(ruim: false, transmitindo: true, gravando: false, quente: false) == .nenhum, "mais seis frias: nada")
        var s = DegrausDaTransmissao()
        _ = s.janela(ruim: true, transmitindo: true, gravando: false, quente: true)
        _ = s.janela(ruim: true, transmitindo: true, gravando: false, quente: true)
        _ = s.janela(ruim: true, transmitindo: true, gravando: false, quente: true)
        conferir(s.janela(ruim: true, transmitindo: true, gravando: false, quente: true) == .capturaReduzida,
                 "sem gravação: da prévia pausada direto à captura em 720p")
        conferir(s.janela(ruim: true, transmitindo: false, gravando: true, quente: true) == .nenhum,
                 "sem transmissão: tudo volta a zero (a gravação não para por calor)")
        conferir(s.janela(ruim: true, transmitindo: false, gravando: true, quente: true) == nil
                 && s.janela(ruim: true, transmitindo: false, gravando: true, quente: true) == nil && s.degrau == .nenhum,
                 "sem transmissão, janelas ruins não sobem nada")
        var f = DegrausDaTransmissao()
        conferir(f.janela(ruim: true, transmitindo: true, gravando: true, quente: false) == nil
                 && f.janela(ruim: true, transmitindo: true, gravando: true, quente: false) == nil
                 && f.janela(ruim: true, transmitindo: true, gravando: true, quente: false) == nil && f.degrau == .nenhum,
                 "frio e ruim: não sobe (um soluço num aparelho frio não para a gravação)")
        _ = f.janela(ruim: true, transmitindo: true, gravando: false, quente: true)
        _ = f.janela(ruim: true, transmitindo: true, gravando: false, quente: true)
        for _ in 0..<5 { _ = f.janela(ruim: true, transmitindo: true, gravando: false, quente: false) }
        conferir(f.janela(ruim: true, transmitindo: true, gravando: false, quente: false) == .nenhum,
                 "esfriou: as janelas contam como boas, e o degrau desce")
    }

    /// Os botões de velocidade que repetem enquanto pressionados (27/09).
    static func rodarRepeticaoDoBotao() {
        print("RepeticaoDoBotao — espera, acelera, piso e teto")
        conferir(RepeticaoDoBotao.intervalo(antesDaRepeticao: 0) == nil, "a repetição 0 não existe (o passo do toque é à parte)")
        conferir(RepeticaoDoBotao.intervalo(antesDaRepeticao: 1) == 0.4, "a primeira repetição espera 0,4 s")
        conferir(RepeticaoDoBotao.intervalo(antesDaRepeticao: 2) == 0.18, "a segunda, 0,18 s")
        var anterior = 1.0, cresce = false
        for n in 2...RepeticaoDoBotao.teto {
            let v = RepeticaoDoBotao.intervalo(antesDaRepeticao: n)!
            if v > anterior + 1e-12 { cresce = true }
            anterior = v
        }
        conferir(!cresce, "nunca desacelera")
        conferir(abs(RepeticaoDoBotao.intervalo(antesDaRepeticao: 40)! - RepeticaoDoBotao.minimo) < 1e-12, "chega ao piso de 50 ms")
        conferir(RepeticaoDoBotao.intervalo(antesDaRepeticao: RepeticaoDoBotao.teto + 1) == nil, "para no teto (gesto cancelado sem aviso)")
        var t = 0.0
        for n in 1...10 { t += RepeticaoDoBotao.intervalo(antesDaRepeticao: n)! }
        conferir(t > 1.0 && t < 1.6, String(format: "dez repetições em %.2f s (o dedo segurando ~1,5 s leva ~1 linha/s de velocidade)", t))
    }

    /// O fecho da tela com câmera sem depender do `onDisappear` (27/09, iPad: a câmera e a 7979 vivas
    /// 45 min depois do X).
    static func rodarFechoDaTela() {
        print("FechoDaTela — o primeiro caminho fecha, os outros não fazem nada")
        let f = FechoDaTela()
        var fechou: [String] = []
        conferir(!f.fechar(motivo: "nada aberto") && !f.aberta, "sem tela registrada: nada a fechar")
        let v1 = f.registrar { fechou.append("1:" + $0) }
        conferir(f.aberta, "registrada: aberta")
        conferir(f.fechar(motivo: "o X") && fechou == ["1:o X"], "o X fecha")
        conferir(!f.fechar(motivo: "o papel mudou") && fechou.count == 1, "a raiz depois do X: nada (uma vez só)")
        f.esquecer(vez: v1)
        let v2 = f.registrar { fechou.append("2:" + $0) }
        f.esquecer(vez: v1)
        conferir(f.aberta, "o registro velho não apaga o da tela nova")
        let v3 = f.registrar { fechou.append("3:" + $0) }
        conferir(v3 > v2 && fechou.last == "2:substituída por outra tela",
                 "uma tela registrada por cima da anterior: a anterior é fechada antes")
        conferir(f.fechar(motivo: "o papel mudou") && fechou.last == "3:o papel mudou" && fechou.count == 3,
                 "e o fecho seguinte fecha a de agora")
        let v4 = f.registrar { fechou.append("4:" + $0) }
        f.esquecer(vez: v4)
        conferir(!f.aberta && !f.fechar(motivo: "x") && fechou.count == 3,
                 "a tela que fechou por dentro (onDisappear) tira o registro")
    }

    /// A borda da divisão da tela R5 não pega toque dentro do texto (27/09, iPad: as marcas azuis do
    /// enquadramento, no pé do texto, mudavam o tamanho da prévia).
    static func rodarZonaDaBorda() {
        print("ZonaDaBordaDaDivisao — a borda só pega toque do lado da prévia")
        conferir(ZonaDaBordaDaDivisao.zona(texto: CGRect(x: 0, y: 0, width: 375, height: 700),
                                           previa: CGRect(x: 0, y: 700, width: 375, height: 0)) == nil,
                 "prévia sem altura: nenhuma zona")
        func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            return i.isNull ? 0 : i.width * i.height
        }
        // As quatro divisões, nas contas de `TelaDoPrompterComCamera.divisao`, em três telas: o iPad
        // deitado (1180x820), o iPhone X em pé (375x812) e deitado (812x375). n = o texto; hF = a faixa.
        for (W, H) in [(CGFloat(1180), CGFloat(820)), (375, 812), (812, 375)] {
            let hF: CGFloat = 112
            let nE = (H * 0.5).rounded(), nL = (W * 0.5).rounded()
            let casos: [(String, Bool, Bool, CGFloat, CGRect, CGRect)] = [
                ("cima", true, true, nE, CGRect(x: 0, y: 0, width: W, height: nE),
                 CGRect(x: 0, y: nE, width: W, height: max(0, H - nE - hF))),
                ("baixo", true, false, H - nE, CGRect(x: 0, y: H - nE, width: W, height: nE),
                 CGRect(x: 0, y: hF, width: W, height: max(0, H - nE - hF))),
                ("esquerda", false, true, nL, CGRect(x: 0, y: 0, width: nL, height: H),
                 CGRect(x: nL, y: 0, width: W - nL, height: max(0, H - hF))),
                ("direita", false, false, W - nL, CGRect(x: W - nL, y: 0, width: nL, height: H),
                 CGRect(x: 0, y: 0, width: W - nL, height: max(0, H - hF))),
            ]
            for (nome, empilhado, antes, borda, texto, previa) in casos {
                // A faixa dos controles: no lado a lado, sob a prévia; empilhado, na outra ponta.
                let faixa = empilhado
                    ? (antes ? CGRect(x: 0, y: H - hF, width: W, height: hF) : CGRect(x: 0, y: 0, width: W, height: hF))
                    : CGRect(x: previa.minX, y: H - hF, width: previa.width, height: hF)
                guard let z = ZonaDaBordaDaDivisao.zona(texto: texto, previa: previa) else {
                    conferir(false, "\(Int(W))x\(Int(H)) texto \(nome): há zona"); continue
                }
                let encosta = empilhado ? (antes ? z.minY == texto.maxY : z.maxY == texto.minY)
                                        : (antes ? z.minX == texto.maxX : z.maxX == texto.minX)
                let ponta = ZonaDaBordaDaDivisao.pontaDaAlca(texto: texto, previa: previa)
                let pontaCerta: Bool
                switch ponta {
                case .cima: pontaCerta = empilhado && antes
                case .baixo: pontaCerta = empilhado && !antes
                case .esquerda: pontaCerta = !empilhado && antes
                case .direita: pontaCerta = !empilhado && !antes
                }
                conferir(area(z, texto) == 0 && area(z, faixa) == 0 && encosta && pontaCerta
                         && (empilhado ? z.height : z.width) == ZonaDaBordaDaDivisao.espessura
                         && z == z.intersection(previa),
                         "\(Int(W))x\(Int(H)) texto \(nome): a zona não entra no texto nem na faixa, encosta na linha, fica na prévia")
                // A marca do enquadramento no pé do texto (a conta de `alturaDaMarca` com `noPe`: o centro
                // a 12,5 pt da ponta, a zona de 72 pt) fica fora da zona da borda na parte dentro do texto.
                if empilhado && antes {
                    let marca = CGRect(x: 0, y: texto.maxY - 12.5 - 36, width: 60, height: 72).intersection(texto)
                    conferir(area(marca, z) == 0, "\(Int(W))x\(Int(H)) texto \(nome): a marca no pé fica com o toque")
                    // O controle: a zona de antes (44 pt centrada na linha) roubava a marca.
                    let antiga = CGRect(x: 0, y: borda - 22, width: W, height: 44)
                    conferir(area(marca, antiga) > 0, "\(Int(W))x\(Int(H)) controle: a zona antiga cobria a marca (o defeito)")
                }
            }
        }
    }

    /// **A divisão da tela R5 com o pedido de 30/09** ("na horizontal o texto do teleprompter precisa
    /// ficar no centro embaixo da camera ... ai segue o mesmo modelo da vertical"): o automático põe o
    /// texto em cima com a lente de lado, e no iPhone deitado a faixa vai para o lado da prévia. As
    /// telas são as **áreas seguras** medidas pela conta (a vista não ignora a área segura fora da tela
    /// cheia): iPhone X deitado 724x354 (44 de cada lado, 21 embaixo), em pé 375x734; iPad A16 deitado
    /// 1180x820 inteiro e 1180x776 sem a barra de estado e o indicador.
    static func rodarDivisaoDaTelaComCamera() {
        print("DivisaoDaTelaComCamera — o texto em cima do iPhone deitado, a faixa ao lado da prévia (30/09)")
        typealias D = DivisaoDaTelaComCamera
        func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            return i.isNull ? 0 : i.width * i.height
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

        // --- a lente e o automático ---------------------------------------------------------------
        conferir(LadoDoTexto.daLente(ipad: false, interface: .portrait) == .cima
                 && LadoDoTexto.daLente(ipad: false, interface: .landscapeRight) == .esquerda
                 && LadoDoTexto.daLente(ipad: false, interface: .landscapeLeft) == .direita
                 && LadoDoTexto.daLente(ipad: false, interface: .portraitUpsideDown) == .baixo
                 && LadoDoTexto.daLente(ipad: false, interface: .desconhecida) == .cima,
                 "a lente do iPhone: em cima em pé, à esquerda em .landscapeRight, à direita em .landscapeLeft (a tabela não mudou)")
        conferir(LadoDoTexto.daLente(ipad: true, interface: .portrait) == .direita
                 && LadoDoTexto.daLente(ipad: true, interface: .landscapeRight) == .cima
                 && LadoDoTexto.daLente(ipad: true, interface: .landscapeLeft) == .baixo,
                 "a lente do iPad (borda longa): à direita em pé, em cima em .landscapeRight, embaixo em .landscapeLeft")
        func auto(ipad: Bool, _ i: InterfaceDaTela) -> LadoDoTexto {
            LadoDoTexto.automatico.resolvido(lente: LadoDoTexto.daLente(ipad: ipad, interface: i))
        }
        conferir(auto(ipad: false, .landscapeRight) == .cima && auto(ipad: false, .landscapeLeft) == .cima,
                 "iPhone deitado, nas duas paisagens: o texto EM CIMA (era à esquerda/à direita, colado na lente)")
        conferir(auto(ipad: false, .portrait) == .cima && auto(ipad: false, .portraitUpsideDown) == .baixo,
                 "iPhone em pé: do lado da lente, como antes")
        conferir(auto(ipad: true, .landscapeRight) == .cima && auto(ipad: true, .landscapeLeft) == .baixo,
                 "iPad deitado: do lado da lente (em cima ou embaixo), como antes")
        conferir(auto(ipad: true, .portrait) == .cima && auto(ipad: true, .portraitUpsideDown) == .cima,
                 "iPad em pé (lente de lado): em cima, empilhado (era lado a lado)")
        conferir(LadoDoTexto.allCases.filter { $0 != .automatico }.allSatisfy { l in
                     [LadoDoTexto.cima, .baixo, .esquerda, .direita].allSatisfy { l.resolvido(lente: $0) == l } },
                 "À esquerda, À direita, Em cima e Embaixo continuam valendo, onde quer que a lente esteja")
        conferir([LadoDoTexto.cima, .baixo, .esquerda, .direita].allSatisfy { LadoDoTexto.doAutomatico(lente: $0).empilhado },
                 "o automático nunca põe lado a lado")
        conferir(LadoDoTexto.automatico.nome == "Automático" && LadoDoTexto.automatico.rawValue == "automatico",
                 "o rótulo é \"Automático\", e o valor gravado continua \"automatico\"")
        conferir(FormaDaDivisao.retrato.rawValue == "retrato" && FormaDaDivisao.paisagem.rawValue == "paisagem"
                 && FormaDaDivisao.empilhadaLarga.rawValue == "empilhada-larga"
                 && Set(FormaDaDivisao.allCases.map(\.rawValue)).count == 3,
                 "as chaves: retrato e paisagem com o texto de antes (o gravado vale), e uma terceira, própria")

        // --- o iPhone X deitado, nas duas paisagens ------------------------------------------------
        let x = CGSize(width: 724, height: 354)
        for interface in [InterfaceDaTela.landscapeRight, .landscapeLeft] {
            let nome = interface == .landscapeRight ? ".landscapeRight" : ".landscapeLeft"
            let lado = auto(ipad: false, interface)
            for hF in [CGFloat(112), 146] {
                let d = D.calcular(x, lado: lado, fracao: 0.5, alturaDaFaixa: hF, previaEscondida: false)
                let z = ZonaDaBordaDaDivisao.zona(texto: d.texto, previa: d.previa)
                conferir(d.lado == .cima && d.forma == .empilhadaLarga && d.faixaAoLado && d.tetoDaFaixa == 177,
                         "iPhone X \(nome), faixa \(Int(hF)): texto em cima, a forma própria, a faixa ao lado (teto = a banda, 177)")
                conferir(d.texto == r(0, 0, 724, 177) && d.texto.midX == x.width / 2,
                         "iPhone X \(nome): o texto na largura toda, 50 % da altura, no alto — a coluna centrada fica no meio da tela, e não ao lado da prévia")
                conferir(d.previa == r(0, 177, 384, 177),
                         "iPhone X \(nome): a prévia com o resto da banda (724 - 340), na altura toda")
                conferir(d.faixa == r(384, 354 - hF, 340, hF),
                         "iPhone X \(nome): a faixa numa coluna de 340 à direita, encostada no pé")
                conferir(area(d.faixa, d.texto) == 0 && area(d.faixa, d.previa) == 0 && area(d.previa, d.texto) == 0
                         && d.faixa.minY >= d.texto.maxY && d.faixa.maxY == x.height && d.faixa.maxX == x.width,
                         "iPhone X \(nome): texto, prévia e faixa não se cruzam, e a faixa fica dentro da banda")
                if let z {
                    conferir(z == z.intersection(d.previa) && area(z, d.faixa) == 0 && area(z, d.texto) == 0
                             && z.minY == d.texto.maxY && z.width == d.previa.width
                             && ZonaDaBordaDaDivisao.pontaDaAlca(texto: d.texto, previa: d.previa) == .cima,
                             "iPhone X \(nome): a zona da borda só sobre a prévia — nem na faixa, nem no texto —, encostada na linha, a alça em cima")
                    for mx in [CGFloat(0), x.width - 60] {
                        let marca = r(mx, d.texto.maxY - 12.5 - 36, 60, 72).intersection(d.texto)
                        conferir(area(marca, z) == 0, "iPhone X \(nome): a marca do enquadramento em x=\(Int(mx)) fica com o toque")
                    }
                } else {
                    conferir(false, "iPhone X \(nome): há zona")
                }
            }
            let teto = 1 - 150.0 / 354
            let alto = D.calcular(x, lado: lado, fracao: 0.8, alturaDaFaixa: 112, previaEscondida: false)
            conferir(abs(alto.teto - teto) < 1e-12 && abs(alto.fracao - teto) < 1e-12 && alto.texto.height == 204,
                     String(format: "iPhone X %@: o teto do texto usa max(120, 150), e não a soma: %.3f (204 pt; com a soma, 84)", nome, teto))
        }
        // A faixa mais alta que a banda (os avisos abertos, letra grande): fica na banda, nunca no texto.
        let alta = D.calcular(x, lado: .cima, fracao: 0.5, alturaDaFaixa: 300, previaEscondida: false)
        conferir(alta.faixa == r(384, 177, 340, 177) && area(alta.faixa, alta.texto) == 0,
                 "faixa de 300 pt numa banda de 177: a faixa fica com a banda, e não cobre o texto")
        // O texto embaixo, escolhido à mão: a coluna na banda de cima, encostada no alto.
        let baixo = D.calcular(x, lado: .baixo, fracao: 0.5, alturaDaFaixa: 112, previaEscondida: false)
        conferir(baixo.forma == .empilhadaLarga && baixo.texto == r(0, 177, 724, 177) && baixo.previa == r(0, 0, 384, 177)
                 && baixo.faixa == r(384, 0, 340, 112) && baixo.borda == 177,
                 "iPhone X deitado, texto embaixo (à mão): a faixa na banda de cima, encostada no alto")
        if let z = ZonaDaBordaDaDivisao.zona(texto: baixo.texto, previa: baixo.previa) {
            conferir(z == r(0, 133, 384, 44) && area(z, baixo.faixa) == 0
                     && ZonaDaBordaDaDivisao.pontaDaAlca(texto: baixo.texto, previa: baixo.previa) == .baixo,
                     "texto embaixo: a zona só sobre a prévia, encostada na linha, a alça embaixo")
        } else {
            conferir(false, "texto embaixo: há zona")
        }
        // A prévia escondida: como hoje — a faixa no pé, na largura toda, sem teto.
        let escondida = D.calcular(x, lado: .cima, fracao: 0.5, alturaDaFaixa: 112, previaEscondida: true)
        conferir(escondida.faixa == r(0, 242, 724, 112) && escondida.texto == r(0, 0, 724, 242)
                 && !escondida.faixaAoLado && escondida.forma == .empilhadaLarga,
                 "iPhone X deitado, prévia escondida: a faixa no pé na largura toda, o texto com o resto (como hoje)")
        // A tela cheia ignora a área segura (812x375) e mede a faixa em zero sem avisos: a prévia fica
        // com a banda inteira, sem 340 pt de preto ao lado.
        let cheia = D.calcular(CGSize(width: 812, height: 375), lado: .cima, fracao: 0.5, alturaDaFaixa: 0, previaEscondida: false)
        conferir(cheia.forma == .empilhadaLarga && cheia.previa.width == 812 && cheia.faixa.height == 0,
                 "tela cheia sem avisos (812x375): a prévia com a banda inteira")
        let cheiaComAviso = D.calcular(CGSize(width: 812, height: 375), lado: .cima, fracao: 0.5, alturaDaFaixa: 40,
                                       previaEscondida: false)
        conferir(cheiaComAviso.previa.width == 472 && cheiaComAviso.faixa == r(472, 335, 340, 40),
                 "tela cheia com um aviso: a coluna volta, ao lado da prévia")
        // Lado a lado à mão, no iPhone deitado: como antes, na chave de paisagem.
        let esq = D.calcular(x, lado: .esquerda, fracao: 0.5, alturaDaFaixa: 112, previaEscondida: false)
        conferir(esq.forma == .paisagem && !esq.faixaAoLado && esq.texto == r(0, 0, 362, 354)
                 && esq.previa == r(362, 0, 362, 242) && esq.faixa == r(362, 242, 362, 112),
                 "iPhone X deitado, À esquerda (à mão): lado a lado como antes, na chave de paisagem")

        // --- como antes: a conta de antes de 30/09, copiada, contra a de agora ----------------------
        // A divisão de `TelaDoPrompterComCamera` em 28c0ca7, linha a linha (só o que não depende da
        // vista). Em toda tela e lado em que a faixa não vai para o lado, as duas têm de dar o mesmo.
        func antiga(_ t: CGSize, _ lado: LadoDoTexto, _ fr: Double, _ hF: CGFloat, _ esc: Bool)
            -> (texto: CGRect, previa: CGRect, faixa: CGRect, borda: CGFloat, eixo: CGFloat, paisagem: Bool, fracao: Double) {
            let paisagem = t.width > t.height
            let W = t.width, H = t.height
            let empilhado = lado.empilhado
            let eixo = max(1, empilhado ? H : W)
            let precisa: CGFloat = empilhado ? 120 + 150 : 340
            let teto = max(0.2, min(1 - 0.2, Double(1 - precisa / eixo)))
            let f = min(teto, fr)
            let n = (eixo * CGFloat(f)).rounded()
            var texto: CGRect, previa: CGRect, faixa: CGRect
            let borda: CGFloat
            switch lado {
            case .baixo:
                texto = r(0, H - n, W, n); faixa = r(0, 0, W, hF); previa = r(0, hF, W, max(0, H - n - hF)); borda = H - n
            case .esquerda:
                texto = r(0, 0, n, H); previa = r(n, 0, W - n, max(0, H - hF)); faixa = r(n, H - hF, W - n, hF); borda = n
            case .direita:
                texto = r(W - n, 0, n, H); previa = r(0, 0, W - n, max(0, H - hF)); faixa = r(0, H - hF, W - n, hF); borda = W - n
            default:
                texto = r(0, 0, W, n); previa = r(0, n, W, max(0, H - n - hF)); faixa = r(0, H - hF, W, hF); borda = n
            }
            if esc {
                if lado == .baixo { faixa = r(0, 0, W, hF); texto = r(0, hF, W, max(0, H - hF)) }
                else { faixa = r(0, H - hF, W, hF); texto = r(0, 0, W, max(0, H - hF)) }
            }
            return (texto, previa, faixa, borda, eixo, paisagem, f)
        }
        var iguais = 0, diferentes: [String] = []
        let telas: [CGSize] = [
            CGSize(width: 1180, height: 820), CGSize(width: 1180, height: 776), CGSize(width: 1133, height: 744),
            CGSize(width: 1366, height: 1024), CGSize(width: 820, height: 1180), CGSize(width: 820, height: 1136),
            CGSize(width: 375, height: 734), CGSize(width: 375, height: 812), CGSize(width: 375, height: 647),
            CGSize(width: 320, height: 548),
        ]
        for t in telas {
            for lado in [LadoDoTexto.cima, .baixo, .esquerda, .direita] {
                for esc in [false, true] {
                    for hF in [CGFloat(112), 146] {
                        for fr in [0.2, 0.5, 0.8] {
                            let a = antiga(t, lado, fr, hF, esc)
                            let d = D.calcular(t, lado: lado, fracao: fr, alturaDaFaixa: hF, previaEscondida: esc)
                            let chaveIgual = d.forma == (a.paisagem ? .paisagem : .retrato)
                            if a.texto == d.texto && a.previa == d.previa && a.faixa == d.faixa && a.borda == d.borda
                                && a.eixo == d.eixo && a.fracao == d.fracao && chaveIgual && d.tetoDaFaixa == nil {
                                iguais += 1
                            } else {
                                diferentes.append("\(Int(t.width))x\(Int(t.height)) \(lado.rawValue) esc=\(esc) hF=\(Int(hF)) f=\(fr)")
                            }
                        }
                    }
                }
            }
        }
        conferir(diferentes.isEmpty,
                 "as telas altas e o iPad deitado (\(telas.count) telas × 4 lados × prévia × faixa × fração = \(iguais) casos): "
                 + "a conta de agora é a de antes, retângulo por retângulo, e a fração vem da mesma chave"
                 + (diferentes.isEmpty ? "" : " — diferem: " + diferentes.prefix(4).joined(separator: "; ")))
        // O lado a lado à mão numa tela larga e baixa também é o de antes.
        var ladoALado = true
        for t in [x, CGSize(width: 667, height: 375), CGSize(width: 812, height: 375)] {
            for lado in [LadoDoTexto.esquerda, .direita] {
                let a = antiga(t, lado, 0.5, 112, false)
                let d = D.calcular(t, lado: lado, fracao: 0.5, alturaDaFaixa: 112, previaEscondida: false)
                if !(a.texto == d.texto && a.previa == d.previa && a.faixa == d.faixa && d.forma == .paisagem) { ladoALado = false }
            }
        }
        conferir(ladoALado, "À esquerda e À direita no iPhone deitado: a conta de antes, na chave de paisagem")
        // O iPad deitado pelo automático, as duas paisagens, com o resultado escrito.
        let ipad = D.calcular(CGSize(width: 1180, height: 820), lado: auto(ipad: true, .landscapeRight), fracao: 0.5,
                              alturaDaFaixa: 112, previaEscondida: false)
        conferir(ipad.lado == .cima && ipad.forma == .paisagem && !ipad.faixaAoLado
                 && ipad.texto == r(0, 0, 1180, 410) && ipad.previa == r(0, 410, 1180, 298) && ipad.faixa == r(0, 708, 1180, 112),
                 "iPad deitado (.landscapeRight): texto em cima, prévia embaixo, a faixa no pé na largura toda — como antes")
        let ipadInv = D.calcular(CGSize(width: 1180, height: 820), lado: auto(ipad: true, .landscapeLeft), fracao: 0.5,
                                 alturaDaFaixa: 112, previaEscondida: false)
        conferir(ipadInv.lado == .baixo && ipadInv.forma == .paisagem && ipadInv.faixa == r(0, 0, 1180, 112),
                 "iPad deitado (.landscapeLeft): texto embaixo, a faixa no alto — como antes")
        // O iPhone em pé pelo automático.
        let emPe = D.calcular(CGSize(width: 375, height: 734), lado: auto(ipad: false, .portrait), fracao: 0.5,
                              alturaDaFaixa: 112, previaEscondida: false)
        conferir(emPe.lado == .cima && emPe.forma == .retrato && emPe.texto == r(0, 0, 375, 367)
                 && emPe.previa == r(0, 367, 375, 255) && emPe.faixa == r(0, 622, 375, 112),
                 "iPhone X em pé: texto em cima, prévia, faixa no pé — como antes")

        // --- o critério da faixa ao lado, nas telas que existem -------------------------------------
        // iPhones deitados (inteiros e áreas seguras): SE 1ª, 7/8, 8 Plus, X/11 Pro, 12–16, Plus/Max.
        let iphonesDeitados: [CGSize] = [
            CGSize(width: 568, height: 320), CGSize(width: 667, height: 375), CGSize(width: 736, height: 414),
            CGSize(width: 812, height: 375), x, CGSize(width: 844, height: 390), CGSize(width: 750, height: 369),
            CGSize(width: 896, height: 414), CGSize(width: 808, height: 393), CGSize(width: 926, height: 428),
            CGSize(width: 932, height: 430), CGSize(width: 956, height: 440),
        ]
        let ipadsDeitados: [CGSize] = [
            CGSize(width: 1024, height: 768), CGSize(width: 1024, height: 748), CGSize(width: 1133, height: 744),
            CGSize(width: 1133, height: 700), CGSize(width: 1180, height: 820), CGSize(width: 1180, height: 776),
            CGSize(width: 1194, height: 834), CGSize(width: 1210, height: 834), CGSize(width: 1366, height: 1024),
            CGSize(width: 1376, height: 1032),
        ]
        conferir(iphonesDeitados.allSatisfy { D.faixaAoLadoDaPrevia($0, lado: .cima) && D.forma($0, lado: .cima) == .empilhadaLarga },
                 "todo iPhone deitado, empilhado: a faixa ao lado da prévia")
        conferir(ipadsDeitados.allSatisfy { !D.faixaAoLadoDaPrevia($0, lado: .cima) && D.forma($0, lado: .cima) == .paisagem },
                 "todo iPad deitado, empilhado: a faixa no pé, como antes (a altura decide, e não só largura > altura)")
        conferir(D.faixaAoLadoDaPrevia(CGSize(width: 1000, height: 539), lado: .cima)
                 && !D.faixaAoLadoDaPrevia(CGSize(width: 1000, height: 540), lado: .cima),
                 "o limite: 539 pt é baixa, 540 não")
        conferir(D.forma(CGSize(width: 1000, height: 500), lado: .cima) == .empilhadaLarga
                 && D.forma(CGSize(width: 1000, height: 600), lado: .cima) == .paisagem,
                 "uma janela de iPad: 1000x500 ganha a faixa ao lado (baixa como um iPhone deitado); 1000x600, no pé")
        conferir(!D.faixaAoLadoDaPrevia(CGSize(width: 450, height: 400), lado: .cima),
                 "uma tela larga e baixa que não deixa 120 pt de prévia ao lado da coluna: a faixa no pé")
        conferir((iphonesDeitados + ipadsDeitados).allSatisfy {
                     !D.faixaAoLadoDaPrevia(CGSize(width: $0.height, height: $0.width), lado: .cima)
                     && !D.faixaAoLadoDaPrevia($0, lado: .esquerda) && !D.faixaAoLadoDaPrevia($0, lado: .direita) },
                 "em pé, ou lado a lado: nunca")
    }

    /// A política de calor da câmera (R5 fase 5, 27/09): o iPhone 7 em `.serious` por 30 min.
    static func rodarPoliticaDeCalor() {
        print("PoliticaDeCalor — a rede a 720p com histerese, a gravação que começa quente, o quadro velho")
        let c1080 = (maior: 1920, menor: 1080)
        let r = PoliticaDeCalor.tetoDaRede(cardapio: c1080, reduzida: true)
        conferir(r.maior == 1280 && r.menor == 720, "reduzida: o teto da rede vai a 1280x720")
        let n = PoliticaDeCalor.tetoDaRede(cardapio: c1080, reduzida: false)
        conferir(n.maior == 1920 && n.menor == 1080, "sem calor: o cardápio")
        let p = PoliticaDeCalor.tetoDaRede(cardapio: (maior: 1280, menor: 720), reduzida: true)
        conferir(p.maior == 1280 && p.menor == 720, "cardápio em 720p não sobe")
        conferir(PoliticaDeCalor.taxaDaRede(base: 8_000_000, termico: 0, economia: false) == 8_000_000
                 && PoliticaDeCalor.taxaDaRede(base: 8_000_000, termico: 1, economia: false) == 8_000_000,
                 "nominal e fair: a taxa inteira")
        conferir(PoliticaDeCalor.taxaDaRede(base: 8_000_000, termico: 2, economia: false) == 4_000_000
                 && PoliticaDeCalor.taxaDaRede(base: 8_000_000, termico: 0, economia: true) == 4_000_000,
                 "serious ou baixo consumo: a metade")
        conferir(PoliticaDeCalor.taxaDaRede(base: 8_000_000, termico: 3, economia: true) == 2_000_000,
                 "critical: um quarto, mesmo em baixo consumo")

        // A gravação que começa quente: 720p na mesma orientação; fria, a captura inteira.
        let emPe = PoliticaDeCalor.tamanhoDaGravacao(largura: 1080, altura: 1920, quente: true)
        conferir(emPe.0 == 720 && emPe.1 == 1280, "quente, de pé: 720x1280 (\(emPe.0)x\(emPe.1))")
        let deitada = PoliticaDeCalor.tamanhoDaGravacao(largura: 1920, altura: 1080, quente: true)
        conferir(deitada.0 == 1280 && deitada.1 == 720, "quente, deitada: 1280x720")
        let fria = PoliticaDeCalor.tamanhoDaGravacao(largura: 1080, altura: 1920, quente: false)
        conferir(fria.0 == 1080 && fria.1 == 1920, "fria: a captura inteira")
        let pequena = PoliticaDeCalor.tamanhoDaGravacao(largura: 720, altura: 1280, quente: true)
        conferir(pequena.0 == 720 && pequena.1 == 1280, "quente com captura já em 720p: não muda")
        conferir(PoliticaDeCalor.aviso(termico: 2) == nil && PoliticaDeCalor.aviso(termico: 3) != nil,
                 "o aviso da faixa só no critical")

        // A histerese: reduz na hora; volta só com 60 s seguidos abaixo de serious.
        var h = RedeReduzidaPeloCalor()
        conferir(!h.observar(termico: 1, agora: 0) && !h.reduzida, "fair não reduz")
        conferir(h.observar(termico: 2, agora: 1) && h.reduzida, "serious reduz na hora")
        conferir(!h.observar(termico: 3, agora: 2) && h.reduzida, "critical continua reduzida, sem troca")
        conferir(!h.observar(termico: 1, agora: 10) && h.reduzida, "esfriou: ainda reduzida")
        conferir(!h.observar(termico: 1, agora: 69) && h.reduzida, "59 s frio: ainda reduzida")
        conferir(!h.observar(termico: 2, agora: 69.5) && h.reduzida, "esquentou de novo: o frio recomeça")
        conferir(!h.observar(termico: 0, agora: 70) && !h.observar(termico: 1, agora: 129) && h.reduzida,
                 "59 s frio contados do recomeço: ainda reduzida")
        conferir(h.observar(termico: 1, agora: 130) && !h.reduzida, "60 s seguidos frios: volta ao cardápio")
        conferir(!h.observar(termico: 0, agora: 200) && !h.reduzida, "fria continua fria, sem troca")

        // O atraso de fila: pelo piso das últimas N idades, com histerese; as rajadas passam.
        var d = DescarteDeVelhos(alto: 0.25, baixo: 0.12, janela: 4, desistirDepoisDe: 6)
        conferir(d.entrada(idade: 0.5) && d.entrada(idade: 0.5) && d.entrada(idade: 0.5),
                 "antes de a janela encher, nada é pulado (sem piso)")
        conferir(d.entrada(idade: 0.05), "um novo na janela: piso baixo, passa")
        // Rajadas (a bancada de 27/09): velhos e novos alternados — o piso fica baixo, nada é pulado.
        var rajadas = true
        for k in 0..<40 { rajadas = d.entrada(idade: k % 3 == 2 ? 0.04 : 0.44) && rajadas }
        conferir(rajadas && d.velhos == 0, "rajadas com um buffer novo em cada: nada pulado (era o defeito)")
        // A fila atrasada de verdade: todas velhas.
        var e = DescarteDeVelhos(alto: 0.25, baixo: 0.12, janela: 4, desistirDepoisDe: 6)
        for _ in 0..<3 { _ = e.entrada(idade: 0.4) }
        conferir(!e.entrada(idade: 0.4) && e.pulando && e.velhos == 1, "a janela cheia de velhos: começa a pular")
        conferir(!e.entrada(idade: 0.2) && e.velhos == 2, "pulando, 0,2 s ainda é pulado (histerese até o baixo)")
        conferir(e.entrada(idade: 0.1) && !e.pulando, "chegou um com 0,1 s: a fila se escoou, para")
        conferir(e.entrada(idade: 0.4) && e.entrada(idade: 0.4) && e.entrada(idade: 0.4),
                 "parou: o piso recomeça do zero (três velhos passam enquanto a janela enche)")
        conferir(e.entrada(idade: -0.2) && e.relogioIncoerente == 1, "idade negativa demais: relógio incoerente, passa")
        conferir(!e.entrada(idade: 0.4), "janela cheia de novo: volta a pular")
        for _ in 0..<5 { _ = e.entrada(idade: 0.5) }
        conferir(e.velhos == 8 && !e.desistiu, "seis pulados seguidos (o teto): ainda pulando")
        conferir(e.entrada(idade: 0.5) && e.desistiu && e.passaramVelhos == 1,
                 "o sétimo seguido: a regra desiste (relógio suspeito não vira apagão)")
        conferir(e.entrada(idade: 0.6) && e.passaramVelhos == 2, "desistida, velho passa e é contado")
        conferir(e.entrada(idade: 0.03) && !e.desistiu,
                 "um novo baixa o piso: religa, com o piso do zero (para pular de novo, a janela inteira velha)")
        conferir(e.entrada(idade: 0.5) && e.entrada(idade: 0.5) && e.entrada(idade: 0.5),
                 "religada, velhos passam enquanto a janela enche")
        // Religar com rajadas (o que a regra antiga, por novos seguidos, nunca fazia).
        var rr = DescarteDeVelhos(alto: 0.25, baixo: 0.12, janela: 4, desistirDepoisDe: 2)
        for _ in 0..<7 { _ = rr.entrada(idade: 0.5) }
        conferir(rr.desistiu, "desistida")
        for k in 0..<8 { _ = rr.entrada(idade: k % 3 == 2 ? 0.04 : 0.44) }
        conferir(!rr.desistiu, "rajadas com um novo em cada janela: o piso baixo religa")
        conferir(e.pisoMaximo >= 0.4, "o maior piso da janela do relato")
        e.zerarContadores()
        conferir(e.velhos == 0 && e.passaramVelhos == 0 && e.relogioIncoerente == 0 && e.pisoMaximo == 0,
                 "os contadores são da janela do relato")
        let v = DescarteDeVelhos.doVideo(), so = DescarteDeVelhos.doSom()
        conferir(v.janela == 30 && so.janela == 47 && v.alto == 0.25 && so.alto == 1.2,
                 "os limites do vídeo e do som (o som atrasa até ~1 s antes de picotar, §8.12.14)")
    }

    /// Fechar a tela com câmera e reabrir (27/09): a tela nova espera a anterior soltar a 7877,
    /// calada e com prazo, e só a porta presa é repetida sem aviso.
    static func rodarSolturaDaPorta() {
        print("SolturaDaPorta — fechar e reabrir a tela com câmera")
        // Os textos reais do núcleo: `bind` com EADDRINUSE no Darwin, e os vizinhos que NÃO são porta.
        let presa = "e/s: Address already in use (os error 48)"
        conferir(SolturaDaPorta.ehPortaOcupada(presa), "o EADDRINUSE do Darwin é porta presa")
        conferir(SolturaDaPorta.ehPortaOcupada("e/s: Endereço já em uso (os error 48)"),
                 "pelo número, em outro idioma")
        conferir(!SolturaDaPorta.ehPortaOcupada("e/s: Connection reset by peer (os error 54)"),
                 "outra falha de e/s não é porta presa")
        conferir(!SolturaDaPorta.ehPortaOcupada("tempo esgotado: nenhum receptor conectou"),
                 "o prazo sem ninguém não é porta presa")
        conferir(!SolturaDaPorta.ehPortaOcupada("sinalização: handshake WebSocket falhou: os error 48"),
                 "só o prefixo e/s: conta")
        conferir(SolturaDaPorta.repetirCalado(erro: presa, desdeOComeco: 0.3), "porta presa aos 0,3 s: repete calado")
        conferir(!SolturaDaPorta.repetirCalado(erro: presa, desdeOComeco: SolturaDaPorta.tolerancia),
                 "porta presa passados 2 s: a pessoa lê")
        conferir(!SolturaDaPorta.repetirCalado(erro: "pareamento: PIN errado", desdeOComeco: 0.1),
                 "PIN errado nunca é calado")

        // O registro dos laços: vazio não espera; com um laço vivo espera até ele sair; com um
        // laço que não sai, desiste no prazo e diz quantos restaram.
        let r = SolturaDaPorta()
        var t0 = Date()
        conferir(r.esperarOsOutros(prazo: 2) == 0 && Date().timeIntervalSince(t0) < 0.05,
                 "sem laço vivo, não espera")
        r.entrar()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { r.sair() }
        t0 = Date()
        let restaram = r.esperarOsOutros(prazo: 2)
        let esperou = Date().timeIntervalSince(t0)
        conferir(restaram == 0 && esperou >= 0.1 && esperou < 1,
                 String(format: "espera o laço anterior sair (%.0f ms)", esperou * 1000))
        r.entrar()
        t0 = Date()
        let presos = r.esperarOsOutros(prazo: 0.2)
        let gastou = Date().timeIntervalSince(t0)
        conferir(presos == 1 && gastou >= 0.19 && gastou < 0.6,
                 String(format: "laço que não sai: desiste no prazo (%.0f ms) com 1 vivo", gastou * 1000))
        r.sair(); r.sair()
        conferir(r.lacosVivos == 0, "sair a mais não fica negativo")
    }

    /// "A pergunta do texto" (§11.7): as palavras, o estado lido do núcleo, a caixa e os textos.
    static func rodarPerguntaDoTexto() {
        print("PerguntaDoTexto — palavras como na fonte automática; a caixa pelo estado; os textos literais")
        conferir(ContaDePalavras.de("— vamos agora") == 2 && ContaDePalavras.de("…") == 0
                 && ContaDePalavras.de("— …") == 0,
                 "\"— vamos agora\" são 2 palavras; travessão e reticências sozinhos não contam")
        conferir(ContaDePalavras.de("2026 foi") == 2 && ContaDePalavras.de("ação,") == 1
                 && ContaDePalavras.de("🎬") == 0 && ContaDePalavras.de("") == 0,
                 "algarismo faz palavra; pontuação grudada não separa; emoji sozinho não conta")
        conferir(ContaDePalavras.de("  Boa\n\nnoite,\ta todos \n") == 4,
                 "espaços, quebras e tabulação separam; nas pontas não contam")
        // O estado, com o exemplo literal do contrato (§11.6).
        let json = """
        {"rolando":false,"velocidade":1.0,"fonte":48.0,"margem":0.1,"linha_de_leitura":0.3,"espelho":false,
         "posicao":0.0,"salto":null,"texto_bytes":10,
         "pergunta_do_texto":{"aberta":true,"retido_ha_ms":840,"prompter_id":"ipad-a1b2",
          "prompter_nome":"iPad da Maria",
          "meu":{"bytes":10,"resumo":"aaaaaaaaaaaaaaaa","previa":"Boa noite."},
          "do_prompter":{"bytes":15,"resumo":"bbbbbbbbbbbbbbbb","previa":"Bom dia a todos"}},
         "copias_do_texto":[{"origem":"prompter","prompter_id":"ipad-a1b2","prompter_nome":"iPad da Maria",
          "quando_ms":1757880000000,"bytes":15,"resumo":"cccccccccccccccc","previa":"Bom dia a todos"}]}
        """
        struct SoAPergunta: Decodable {
            var pergunta: PerguntaDoTexto?
            var copias: [CopiaDoTexto]
            enum CodingKeys: String, CodingKey { case pergunta = "pergunta_do_texto", copias = "copias_do_texto" }
        }
        let lido = try? JSONDecoder().decode(SoAPergunta.self, from: Data(json.utf8))
        let p = lido?.pergunta
        conferir(p?.aberta == true && p?.retidoHaMs == 840 && p?.prompterNome == "iPad da Maria"
                 && p?.doPrompter?.resumo == "bbbbbbbbbbbbbbbb" && p?.meu?.previa == "Boa noite.",
                 "a pergunta do exemplo do contrato é lida inteira")
        conferir(lido?.copias.first?.origem == "prompter" && lido?.copias.first?.quandoMs == 1757880000000
                 && lido?.copias.first?.deOnde == "Do prompter iPad da Maria",
                 "a cópia do exemplo é lida, e diz de onde veio")
        conferir(CopiaDoTexto(origem: "controle", prompterNome: "Sonda").deOnde == "Deste aparelho, antes de Sonda",
                 "a cópia daqui: \"Deste aparelho, antes de {prompter_nome}\"")
        let comparando = try? JSONDecoder().decode(PerguntaDoTexto.self,
            from: Data(#"{"aberta":false,"retido_ha_ms":1500,"prompter_id":"x","prompter_nome":"X","meu":{"bytes":1,"resumo":"r","previa":"a"},"do_prompter":null}"#.utf8))
        conferir(comparando?.aberta == false && comparando?.doPrompter == nil, "comparando: do_prompter nulo")
        // A caixa.
        let aberta = p ?? PerguntaDoTexto()
        conferir(EstadoDaCaixa.de(pergunta: nil, prompterVisto: true, resposta: nil) == .escondida,
                 "sem nada retido: sem caixa")
        conferir(EstadoDaCaixa.de(pergunta: PerguntaDoTexto(aberta: false, retidoHaMs: 400), prompterVisto: true, resposta: nil)
                 == .escondida, "comparando há menos de 1 s: não pisca")
        conferir(EstadoDaCaixa.de(pergunta: comparando, prompterVisto: true, resposta: nil) == .conferindo,
                 "comparando há mais de 1 s: \"Conferindo o roteiro do prompter…\"")
        conferir(EstadoDaCaixa.de(pergunta: aberta, prompterVisto: true, resposta: nil)
                 == .pergunta(aberta, botoes: true, aviso: nil), "aberta, com o prompter: a pergunta e os botões")
        conferir(EstadoDaCaixa.de(pergunta: aberta, prompterVisto: false, resposta: nil)
                 == .pergunta(aberta, botoes: false, aviso: "O prompter saiu. A pergunta volta quando ele voltar."),
                 "o prompter sumiu: botões desligados, com o texto literal")
        conferir(EstadoDaCaixa.de(pergunta: aberta, prompterVisto: true, resposta: .prompterSaiu)
                 == .pergunta(aberta, botoes: false, aviso: TextosDaPergunta.prompterSaiu),
                 "CLOSED na escolha: o mesmo")
        conferir(EstadoDaCaixa.de(pergunta: aberta, prompterVisto: true, resposta: .roteiroMudou)
                 == .pergunta(aberta, botoes: true, aviso: "O roteiro do prompter mudou. Confira de novo."),
                 "BUSY: \"O roteiro do prompter mudou. Confira de novo.\", com os botões")
        conferir(TextosDaPergunta.titulo("Sonda P1") == "O prompter Sonda P1 tem outro roteiro."
                 && TextosDaPergunta.palavras(12) == "12 palavras"
                 && TextosDaPergunta.ficaGuardado == "O roteiro que sair fica em Roteiros guardados.",
                 "os textos literais do pedido")
        // O tamanho: concordância e ponto de milhar em pt-BR (ajuste do coordenador, 14/09).
        conferir(TextosDaPergunta.palavras(0) == "0 palavras" && TextosDaPergunta.palavras(1) == "1 palavra"
                 && TextosDaPergunta.palavras(2) == "2 palavras",
                 "\"0 palavras\" (texto vazio), \"1 palavra\", \"2 palavras\"")
        conferir(TextosDaPergunta.palavras(999) == "999 palavras" && TextosDaPergunta.palavras(1000) == "1.000 palavras"
                 && TextosDaPergunta.palavras(1234) == "1.234 palavras"
                 && TextosDaPergunta.palavras(1_234_567) == "1.234.567 palavras",
                 "ponto de milhar: \"1.234 palavras\", \"1.234.567 palavras\"")
        conferir(TextosDaPergunta.palavras(ContaDePalavras.de("")) == "0 palavras", "o texto vazio conta 0 palavras")
    }

    /// "Segurar para rolar" (§12): o mapeamento e as regras dos dedos nos dois botões.
    static func rodarDedosNosBotoes() {
        print("DedosNosBotoes — vale o último botão apertado; soltar só sem dedo nenhum num botão")
        conferir(BotaoDeSegurar.cima.paraTras(invertido: false) && !BotaoDeSegurar.baixo.paraTras(invertido: false)
                 && BotaoDeSegurar.cima.rotulo == "Rolar para cima" && BotaoDeSegurar.cima.legenda(invertido: false) == "volta o texto"
                 && BotaoDeSegurar.baixo.legenda(invertido: false) == "avança o texto",
                 "\"Rolar para cima\" volta o texto (hold com backwards); \"Rolar para baixo\" avança")
        // "Inverter botões" (14/09 à tarde): a ação e a legenda trocam; a seta e o rótulo ficam.
        conferir(!BotaoDeSegurar.cima.paraTras(invertido: true) && BotaoDeSegurar.baixo.paraTras(invertido: true),
                 "invertido: o de cima manda para_tras=false (avança) e o de baixo para_tras=true (volta)")
        conferir(BotaoDeSegurar.cima.legenda(invertido: true) == "avança o texto"
                 && BotaoDeSegurar.baixo.legenda(invertido: true) == "volta o texto",
                 "invertido: as legendas trocam junto com a ação")
        conferir(BotaoDeSegurar.cima.rotulo == "Rolar para cima" && BotaoDeSegurar.cima.simbolo == "arrow.up"
                 && BotaoDeSegurar.baixo.rotulo == "Rolar para baixo" && BotaoDeSegurar.baixo.simbolo == "arrow.down",
                 "invertido ou não, a seta e o rótulo ficam no lugar")
        var inv = DedosNosBotoes()
        conferir(inv.podeInverter, "sem dedo nenhum: a inversão pode trocar")
        inv.encostou(1, em: .cima)
        conferir(!inv.podeInverter, "com um dedo num botão de rolar, a troca não vale")
        inv.pararTodos()
        conferir(!inv.podeInverter, "nem com o dedo morto (o texto parou sozinho) ainda no vidro")
        inv.tirou(1)
        conferir(inv.podeInverter, "solto o dedo, a troca volta a valer")
        var d = DedosNosBotoes()
        d.encostou(1, em: .baixo)
        conferir(d.ativo == .baixo, "um dedo em \"Rolar para baixo\": segura para baixo")
        d.encostou(2, em: .cima)
        conferir(d.ativo == .cima, "o segundo dedo em \"Rolar para cima\": vale o último apertado")
        d.tirou(2)
        conferir(d.ativo == .baixo, "tirado o segundo, o primeiro ainda segura: nada de soltar")
        d.tirou(1)
        conferir(d.ativo == nil && d.quantos == 0, "nenhum dedo num botão: solta")
        d.encostou(3, em: nil)
        conferir(d.ativo == nil, "encostar fora dos botões não aperta nada")
        d.encostou(4, em: .baixo)
        d.moveu(4, para: .baixo)
        conferir(d.ativo == .baixo, "andar dentro do botão continua segurando")
        d.moveu(4, para: .cima)
        conferir(d.ativo == nil, "sair do botão solta — e passar pelo outro não o aperta")
        d.moveu(4, para: .baixo)
        conferir(d.ativo == nil, "e voltar ao botão depois de sair não aperta de novo")
        d.encostou(5, em: .cima)
        d.encostou(6, em: .baixo)
        d.moveu(6, para: nil)
        conferir(d.ativo == .cima, "o último sai do botão: volta a valer o que ainda segura")
        d.soltarTudo()
        conferir(d.ativo == nil && d.quantos == 0, "segundo plano ou tela fechando: tudo solto")

        // Nada aperta de novo sozinho (revisão adversarial, 14/09): o caminho que o defeito tinha.
        var p = DedosNosBotoes()
        p.encostou(1, em: .baixo)
        p.encostou(2, em: .cima)
        p.pararTodos()
        conferir(p.ativo == nil && p.mortosNaTela == 2, "o texto parou sozinho: os dois dedos morrem")
        p.tirou(2)
        conferir(p.ativo == nil, "tirar o segundo dedo não faz o primeiro, parado, apertar de novo")
        p.moveu(1, para: .baixo)
        conferir(p.ativo == nil, "o dedo morto andando no botão continua sem valer")
        p.encostou(3, em: .baixo)
        conferir(p.ativo == .baixo, "um dedo novo no mesmo botão aperta de novo")
        p.tirou(3)
        conferir(p.ativo == nil && p.mortosNaTela == 1, "tirado o novo, solta — e o morto segue morto")
        p.tirou(1)
        conferir(p.mortosNaTela == 0, "o morto sai da tela: nada sobra")
        p.encostouSemValer(4)
        conferir(p.ativo == nil && p.mortosNaTela == 1, "o dedo que encostou com os botões desligados não conta")
        p.moveu(4, para: .cima)
        conferir(p.ativo == nil, "nem quando anda, depois de os botões ligarem")
        p.soltarTudo()
        conferir(p.mortosNaTela == 0 && p.quantos == 0, "soltar tudo esquece os mortos também")
    }

    /// A regra da "Fonte automática" (`docs/teleprompter-ajustes-locais.md` §5).
    static func rodarRegraDaFonteAutomatica() {
        print("RegraDaFonteAutomatica — nenhuma linha com uma palavra só, menos fim de parágrafo e 12 letras ou mais")
        // "Vai " sozinha na linha 0, no meio do parágrafo; "e vem\n" com duas; "sim\n" no fim dele.
        let t1 = "Vai e vem\nsim\n" as NSString
        conferir(RegraDaFonteAutomatica.violacao(inicios: [0, 4, 10], texto: t1) == 0,
                 "uma palavra curta sozinha no meio do parágrafo é violação")
        conferir(RegraDaFonteAutomatica.linha(2, inicios: [0, 4, 10], texto: t1) == .fimDeParagrafo
                 && RegraDaFonteAutomatica.violacao(inicios: [0, 10], texto: t1) == nil,
                 "a palavra que sobra no fim do parágrafo não conta")
        // A exceção não depende da fonte: são as letras da palavra (correção de 14/09).
        let t4 = "Responsabilidade, vamos agora\nvamos\n" as NSString
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 18, 24], texto: t4) == .palavraLonga,
                 "\"Responsabilidade,\" sozinha (16 letras; a vírgula não conta) não conta")
        let t5 = "vamos agora\nfim\n" as NSString
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 6], texto: t5) == .sozinha,
                 "\"vamos\" sozinha conta, em qualquer fonte — era o defeito do Mac")
        let t6 = "desenvolvime nto\nfim\n" as NSString
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 13], texto: t6) == .palavraLonga
                 && RegraDaFonteAutomatica.letras("desenvolvime") == 12,
                 "12 letras já é palavra longa")
        let t7 = "desenvolvim ento\nfim\n" as NSString
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 12], texto: t7) == .sozinha,
                 "11 letras ainda é palavra curta")
        conferir(RegraDaFonteAutomatica.letras("ação,") == 4 && RegraDaFonteAutomatica.letras("🎬") == 0
                 && RegraDaFonteAutomatica.letras("2026") == 0, "letras: acento conta, pontuação, emoji e algarismo não")
        let t2 = "aa bb\ncc" as NSString
        conferir(RegraDaFonteAutomatica.violacao(inicios: [0, 6], texto: t2) == nil,
                 "a última linha do texto, sem quebra no fim, é fim de parágrafo")
        let t3 = "aa   bb cc\n\n\ndd ee\n" as NSString
        conferir(RegraDaFonteAutomatica.violacao(inicios: [0, 5, 11, 12, 13], texto: t3) == 0,
                 "espaços no fim não fazem de uma palavra duas")
        conferir(RegraDaFonteAutomatica.violacao(inicios: [0, 11, 12, 13], texto: t3) == nil,
                 "linhas em branco não têm palavra, e não contam")
        // As três definições alinhadas nas quatro telas (§5, 14/09).
        let t8 = "— vamos agora\nfim\n" as NSString
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 8], texto: t8) == .sozinha,
                 "\"— vamos\" sozinho numa linha é uma palavra só: violação (o travessão não é palavra)")
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 2], texto: t8) == .ok
                 && RegraDaFonteAutomatica.linha(0, inicios: [0, 2], texto: "… vamos\nfim\n" as NSString) == .ok,
                 "uma linha só com \"—\" ou \"…\" não tem palavra nenhuma, e não conta")
        conferir(RegraDaFonteAutomatica.linha(1, inicios: [0, 4], texto: "a b\n— vamos\n" as NSString) == .fimDeParagrafo,
                 "\"— vamos\" no fim do parágrafo não conta")
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 5], texto: "2026 foi\nfim\n" as NSString) == .sozinha
                 && RegraDaFonteAutomatica.ehPalavra("2026") && !RegraDaFonteAutomatica.ehPalavra("—…"),
                 "algarismo faz palavra (\"2026\" sozinho conta); pontuação sozinha não")
        let t9 = "responsabilidade agora\nfim\n" as NSString
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 13, 23], texto: t9) == .partida
                 && RegraDaFonteAutomatica.violacao(inicios: [0, 13, 23], texto: t9) == 0,
                 "palavra partida no meio conta contra a fonte, mesmo com um pedaço de 13 letras (\"responsabilid|ade\")")
        conferir(RegraDaFonteAutomatica.linha(1, inicios: [0, 13, 23], texto: t9) == .ok,
                 "a linha que começa com o resto (\"ade agora\") é julgada pelas palavras dela")
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 12], texto: "vamos responsabilidade\n" as NSString) == .partida,
                 "partida também com duas palavras na linha (\"vamos respon|sabilidade\")")
        conferir(RegraDaFonteAutomatica.linha(0, inicios: [0, 8], texto: "segunda-feira agora\nfim\n" as NSString) == .partida,
                 "a quebra depois do hífen cai dentro de um trecho sem espaço: partida")
        conferir(RegraDaFonteAutomatica.letras("comunicação,") == 11, "\"comunicação,\" tem 11 letras")
        let r = RegraDaFonteAutomatica.maior { $0 <= 57 }
        conferir(r.fonte == 57 && r.provas <= 9, "busca binária de 8 a 400: 57 pt em \(r.provas) provas")
        conferir(RegraDaFonteAutomatica.maior { _ in false }.fonte == 8, "nada passa: fica o mínimo, 8 pt")
        conferir(RegraDaFonteAutomatica.maior { _ in true }.fonte == 400, "tudo passa: o máximo, 400 pt")
    }

    /// A tabela de linhas e o ponto de leitura que sobrevive ao layout novo (14/09).
    static func rodarLinhasDoRoteiro() {
        print("LinhasDoRoteiro — o caractere na linha de leitura continua nela depois do layout novo")
        let t = LinhasDoRoteiro(inicios: [0, 10, 25, 40], alturaDaLinha: 50)
        conferir(t.alturaDoTexto == 200, "quatro linhas de 50 pt")
        conferir(t.linha(doCaractere: 0) == 0 && t.linha(doCaractere: 9) == 0 && t.linha(doCaractere: 10) == 1
                 && t.linha(doCaractere: 39) == 2 && t.linha(doCaractere: 40) == 3 && t.linha(doCaractere: 999) == 3,
                 "a linha de cada caractere (a última cujo início é <= c)")
        conferir(t.linha(noTexto: -5) == 0 && t.linha(noTexto: 49.9) == 0 && t.linha(noTexto: 50) == 1
                 && t.linha(noTexto: 1e9) == 3, "a linha de cada altura, presa nas pontas")
        conferir(t.pontoDeLeitura(noTexto: 75) == PontoDeLeitura(caractere: 10, fracao: 0),
                 "a leitura no centro da linha 1: o caractere 10, fração 0")
        let p = t.pontoDeLeitura(noTexto: 60)!
        conferir(p.caractere == 10 && abs(p.fracao + 0.3) < 1e-12, "10 pt abaixo do topo da linha 1: fração −0,3")
        var idaEVolta = true
        for alt in stride(from: 0.0, to: 200, by: 7.3) where abs(t.noTexto(paraPonto: t.pontoDeLeitura(noTexto: alt)!) - alt) > 1e-9 {
            idaEVolta = false
        }
        conferir(idaEVolta, "ida e volta da altura ao ponto de leitura, em todo o texto")
        // A fonte dobra: cada linha velha vira duas. O caractere que abria a linha lida abre uma
        // linha no layout novo, e é ela que volta à leitura.
        let dobro = LinhasDoRoteiro(inicios: [0, 5, 10, 15, 20, 25, 30, 35, 40, 45], alturaDaLinha: 100)
        conferir(dobro.noTexto(paraPonto: t.pontoDeLeitura(noTexto: 75)!) == 250,
                 "fonte em dobro: a linha que começa no caractere 10 (a 2.ª) no centro da leitura")
        conferir(dobro.linha(noTexto: dobro.noTexto(paraPonto: t.pontoDeLeitura(noTexto: 60)!)) == 2,
                 "e com a fração, a leitura continua dentro da mesma linha")
        conferir(t.noTexto(paraPonto: PontoDeLeitura(caractere: 5000, fracao: 0)) == 175,
                 "o texto encolheu: um caractere além do fim cai na última linha")
        conferir(LinhasDoRoteiro.vazia.pontoDeLeitura(noTexto: 10) == nil
                 && LinhasDoRoteiro.vazia.noTexto(paraPonto: PontoDeLeitura(caractere: 3, fracao: 0)) == 0,
                 "sem texto, sem ponto de leitura")
        conferir(t.linhas(de: 60, ate: 160) == 1..<4 && t.linhas(de: -100, ate: 10) == 0..<1
                 && t.linhas(de: 190, ate: 900) == 3..<4 && t.linhas(de: 300, ate: 400).isEmpty,
                 "as linhas que tocam um intervalo (é o que decide os blocos pintados)")
    }

    /// O instrumento do tranco: os quadros perdidos, a janela do evento e o piso.
    static func rodarMedidorDoRoteiro() {
        print("MedidorDoRoteiro — quadros perdidos pelo relógio da tela")
        let p = 1.0 / 60
        let m = MedidorDoRoteiro()
        var t = 100.0
        for _ in 0..<61 { m.quadro(timestamp: t, periodo: p, contando: true); t += p }
        conferir(m.quadrosFora == 60 && m.perdidosFora == 0, "um segundo a 60 Hz sem evento: 60 quadros, 0 perdidos")
        conferir(m.lerPiso().contains("quadros=60 perdidos=0") && m.quadrosFora == 0, "o piso sai numa linha, e zera")

        m.abrir("texto", agora: t)
        m.etapa("definir", ms: 290, agora: t + 0.29)
        m.etapa("desenho", ms: 8, agora: t + 0.30)
        m.etapa("desenho", ms: 2, agora: t + 0.30)
        m.nota("bytes=100000")
        // O último quadro foi em `t − p`: o próximo chega 300 ms depois dele.
        t += 0.300 - p
        conferir(m.quadro(timestamp: t, periodo: p, contando: true) == nil, "300 ms presos: a janela segue aberta")
        var fechou: MedidorDoRoteiro.Janela?
        for _ in 0..<70 where fechou == nil { t += p; fechou = m.quadro(timestamp: t, periodo: p, contando: true) }
        conferir(fechou != nil, "um segundo de silêncio fecha a janela")
        if let j = fechou {
            conferir(j.perdidos == 17, "300 ms a 60 Hz são 17 quadros perdidos (\(j.perdidos))")
            conferir(abs(j.maiorIntervaloMs - 300) < 1e-6, "e o maior intervalo, 300 ms")
            conferir(j.etapas == [.init(nome: "definir", ms: 290, vezes: 1), .init(nome: "desenho", ms: 10, vezes: 2)],
                     "as etapas do evento, somadas por nome")
            conferir(j.linha().hasPrefix("tranco: evento=texto perdidos=17 ")
                     && j.linha().contains("desenho_ms=10.0(x2)") && j.linha().hasSuffix("bytes=100000"),
                     "a linha do diário: \(j.linha())")
        }
        conferir(m.quadrosFora == 0, "os quadros da janela não entram no piso")

        let parado = MedidorDoRoteiro()
        parado.quadro(timestamp: 1, periodo: p, contando: false)
        parado.quadro(timestamp: 2, periodo: p, contando: false)
        parado.quadro(timestamp: 2 + p, periodo: p, contando: true)
        conferir(parado.perdidosFora == 0 && parado.quadrosFora == 1,
                 "parado, um buraco não conta — e o intervalo seguinte é medido do último quadro, não do começo")
        let semAnuncio = MedidorDoRoteiro()
        semAnuncio.etapa("geometria", ms: 1, agora: 5)
        conferir(semAnuncio.temJanelaAberta, "um layout que ninguém anunciou também abre janela")
    }

    /// A melhor imagem da tela R5 (conserto de 24/09): o 4K fixo derrubou a frontal do iPhone X.
    /// As listas são falsas, mas no formato do que o `AVCaptureDevice.formats` devolve.
    static func rodarEscolhaDaMelhorImagem() {
        print("EscolhaDaMelhorImagem — o maior formato que ESTA câmera oferece")
        let v = FormatoOferecido.subtipo420v, f = FormatoOferecido.subtipo420f
        let x420: UInt32 = 0x7834_3230
        func fmt(_ l: Int, _ a: Int, _ s: UInt32, _ faixas: [(Double, Double)],
                 binned: Bool = false) -> FormatoOferecido {
            FormatoOferecido(largura: l, altura: a, subtipo: s,
                             faixas: faixas.map { FormatoOferecido.Faixa(minima: $0.0, maxima: $0.1) },
                             binned: binned)
        }
        func maxFps(_ f: FormatoOferecido) -> Int { Int(f.faixas.map(\.maxima).max() ?? 0) }
        func dito(_ l: [FormatoOferecido], _ i: Int?) -> String {
            guard let i else { return "nenhum" }
            return "\(l[i].largura)x\(l[i].altura) \(l[i].nomeDoSubtipo) max=\(maxFps(l[i]))\(l[i].binned ? " binned" : "")"
        }

        // A frontal do iPhone X (forma aproximada): nada acima de 1080p em 16:9, e um 4:3 maior.
        let frontalX = [
            fmt(640, 480, v, [(1, 30)]), fmt(640, 480, f, [(1, 30)]),
            fmt(1280, 720, v, [(1, 60)]), fmt(1280, 720, f, [(1, 60)]),
            fmt(1920, 1080, v, [(1, 30)]), fmt(1920, 1080, f, [(1, 30)]),
            fmt(1920, 1440, v, [(1, 30)]), fmt(1920, 1440, f, [(1, 30)]),
            fmt(3088, 2320, f, [(1, 30)]),
        ]
        let iX = EscolhaDaMelhorImagem.escolher(frontalX, fps: 30)
        conferir(iX.map { frontalX[$0].largura == 1920 && frontalX[$0].altura == 1080 } == true,
                 "frontal do iPhone X a 30: 1920x1080, não 4K e não o 4:3 maior (\(dito(frontalX, iX)))")
        conferir(iX.map { frontalX[$0].subtipo == v } == true, "no empate de tamanho, 420v (o que a saída pede)")
        let q60 = EscolhaDaMelhorImagem.escolherComQueda(frontalX, fps: 60)
        conferir(q60.map { frontalX[$0.indice].largura == 1280 && $0.fps == 60 } == true,
                 "a 60: o maior que faz 60 (720p), a taxa do cardápio manda")
        let so30 = frontalX.filter { $0.largura != 1280 }
        let q = EscolhaDaMelhorImagem.escolherComQueda(so30, fps: 60)
        conferir(q.map { so30[$0.indice].largura == 1920 && $0.fps == 30 } == true,
                 "a 60 numa câmera que só faz 30: a melhor a 30, sem derrubar nada")

        // Uma traseira com 4K, formatos de alta taxa no mesmo tamanho e 16:9 exóticos maiores.
        let traseira = [
            fmt(1920, 1080, f, [(1, 240)], binned: true), fmt(1920, 1080, f, [(1, 30)]), fmt(1920, 1080, f, [(1, 60)]),
            fmt(3840, 2160, x420, [(1, 30)]),
            fmt(3840, 2160, f, [(1, 30)]), fmt(3840, 2160, f, [(1, 60)]),
            fmt(4032, 3024, f, [(1, 30)]),
            fmt(4096, 2304, f, [(1, 30)]),
        ]
        let iT = EscolhaDaMelhorImagem.escolher(traseira, fps: 30)
        conferir(iT == 4,
                 "traseira 4K a 30: 3840x2160 420f, o primeiro dos dois (não o x420, não o 4:3, não o 4096x2304) (\(dito(traseira, iT)))")
        let i60 = EscolhaDaMelhorImagem.escolher(traseira, fps: 60)
        conferir(i60 == 5,
                 "traseira 4K a 60: o 3840x2160 que faz 60")
        let so1080 = Array(traseira[0..<3])
        let i1080 = EscolhaDaMelhorImagem.escolher(so1080, fps: 30)
        conferir(i1080 == 1, "entre três 1080p, o primeiro não binned, e não o de 240 binned (\(dito(so1080, i1080)))")
        let binnedPrimeiro = [fmt(1920, 1080, v, [(1, 60)], binned: true), fmt(1920, 1080, f, [(1, 60)])]
        conferir(EscolhaDaMelhorImagem.escolher(binnedPrimeiro, fps: 30) == 1,
                 "não binned vence o 420v binned: o binning pesa mais que o subtipo")
        let exoticos = [fmt(3072, 1728, f, [(1, 30)]), fmt(2560, 1440, f, [(1, 30)]), fmt(1280, 720, f, [(1, 30)])]
        conferir(EscolhaDaMelhorImagem.escolher(exoticos, fps: 30) == 2,
                 "16:9 fora dos tamanhos padrão (3072x1728, 2560x1440) não entra: fica o 720p")

        // Nada serve: nil, e quem chama cai no cardápio — nunca derruba a câmera.
        conferir(EscolhaDaMelhorImagem.escolherComQueda([], fps: 30) == nil, "lista vazia: nenhum (cai no cardápio)")
        let ruins = [fmt(1920, 1440, f, [(1, 30)]), fmt(1920, 1080, x420, [(1, 30)]),
                     fmt(1920, 1080, f, [(1, 24)]), fmt(1920, 1080, f, [(31, 60)]),
                     fmt(0, 0, f, [(1, 30)])]
        conferir(EscolhaDaMelhorImagem.escolherComQueda(ruins, fps: 30) == nil,
                 "só 4:3, 10 bits, abaixo de 30 ou faixa sem o 30: nenhum")
        conferir(EscolhaDaMelhorImagem.escolher([fmt(1080, 1920, f, [(1, 30)])], fps: 30) == 0,
                 "16:9 em pé também conta")
        conferir(EscolhaDaMelhorImagem.escolher([fmt(1280, 720, f, [(1, 30)])], fps: 24) == 0,
                 "taxa abaixo de 30 pede 30")
        conferir(FormatoOferecido.subtipo420v == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                 && FormatoOferecido.subtipo420f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 "os FourCC escritos à mão batem com os do CoreVideo")
    }
}

/// Encoda um punhado de quadros com o **encoder do produto** e escreve o Annex-B num arquivo,
/// para o `ffprobe` e o `confere-h264.py` julgarem de fora.
///
/// Existe por causa do segundo defeito da primeira corrida do produto: o fluxo saiu em
/// `pix_fmt=yuvj420p`, `color_range=pc` — faixa **completa** —, e o projeto padronizou
/// **limitada** em `docs/contrato-sidecar.md`, com o argumento do MediaCodec do Android. Foi a
/// terceira plataforma a errar isso, cada uma de um jeito, e nenhuma das três foi pega por um
/// olho humano: "o vídeo funciona", só que lavado ou esmagado.
///
/// ## Os dois emissores, e os dois formatos de entrada
///
/// A tela recebe do ReplayKit, que entrega `420f` (medido no iPhone 7). A câmera recebe do
/// `AVCaptureVideoDataOutput`, e **o que ela entrega ainda não está medido em aparelho** — é o
/// que a linha `formato_da_camera=` do `provar.sh` vai responder. Por isso os fluxos de câmera
/// são gerados **das duas entradas possíveis**: a pergunta que o teste responde deixa de depender
/// da medição. Dê o que der, o encoder do produto precisa produzir faixa limitada.
///
/// ## Os controles negativos
///
/// Um teste de faixa de cor que só passa não prova que sabe reprovar. Aqui três fluxos são
/// gerados **errados de propósito** — faixa completa, dimensão fora do teto, IDR sem parâmetros —
/// e o roteiro exige que o veredito os **reprove**. A linha que reprova é o que dá valor à que
/// aprova; sem ela, um validador quebrado passaria por validador bom.
///
/// **O que estes testes não são**: prova no iPhone 7. É o mesmo `CodificadorH264`, a mesma API e o
/// mesmo mecanismo, mas o VideoToolbox do macOS não é o do A10. A prova no aparelho é o veredito
/// do `provar.sh` sobre o `.h264` gravado pelo receptor.
enum Fluxos {

    /// Um fluxo, do encoder do produto, com a entrada e o perfil pedidos.
    ///
    /// - Parameter declararEntrada: `false` reproduz o defeito da primeira corrida (faixa
    ///   completa). Só o controle negativo passa `false`.
    static func gerar(em caminho: String,
                      entrada: OSType,
                      largura: Int, altura: Int,
                      saidaL: Int32, saidaA: Int32,
                      perfil: CodificadorH264.Perfil,
                      declararEntrada: Bool = true,
                      declararCor: Bool = true,
                      quadros: Int = 40) -> Bool {
        var pix: CVPixelBuffer?
        let atributos: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, largura, altura, entrada,
                                  atributos as CFDictionary, &pix) == kCVReturnSuccess,
              let imagem = pix else {
            print("  FALHA não consegui criar o CVPixelBuffer de entrada")
            return false
        }

        FileManager.default.createFile(atPath: caminho, contents: nil)
        guard let punho = FileHandle(forWritingAtPath: caminho) else {
            print("  FALHA não consegui abrir \(caminho)")
            return false
        }
        defer { try? punho.close() }

        do {
            // Teto de quadros em voo alto **só aqui**: no produto ele é 2, porque descartar é o
            // comportamento certo quando o aparelho não acompanha. Neste laço os quadros são
            // submetidos o mais rápido que a máquina aceita, e um descarte que calhasse de cair
            // num quadro-chave forçado mudaria a contagem de IDR do fluxo de teste — que é
            // exatamente uma das coisas que o veredito mede. Já aconteceu: um controle passou a
            // reprovar por "tem 1 IDR" em vez de pelo defeito que ele existe para exercitar.
            let c = try CodificadorH264(largura: saidaL, altura: saidaA, fps: 30,
                                        bitrate: 4_000_000, perfil: perfil, tetoEmVoo: 64,
                                        declararEntrada: declararEntrada,
                                        declararCor: declararCor)
            c.aoSair = { annexb, _, _ in
                guard let base = annexb.baseAddress else { return }
                punho.write(Data(bytes: base, count: annexb.count))
            }
            let completa = entrada == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            for i in 0..<quadros {
                pintar(imagem, giro: i, faixaCompleta: completa)
                // Um IDR a cada dez quadros: sem mais de um, "todo IDR leva SPS e PPS" seria uma
                // afirmação sobre um único caso, e é justamente o segundo IDR em diante que
                // decide se quem entra no meio da sessão vê imagem.
                c.encodar(imagem, pts: CMTime(value: CMTimeValue(i), timescale: 30),
                          duracao: CMTime(value: 1, timescale: 30), forcarIDR: i % 10 == 0)
            }
            c.encerrar()
            return true
        } catch {
            print("  FALHA o encoder não subiu: \(error)")
            return false
        }
    }

    /// Copia um fluxo tirando **todos** os SPS e PPS, para o controle negativo de "IDR sem
    /// parâmetros".
    ///
    /// Este defeito não é detectável pelo `ffprobe`: um fluxo cujos IDR não levam parâmetros
    /// decodifica normalmente para quem estava lá desde o primeiro quadro. Quem entra no meio
    /// fica sem imagem — que é o defeito medido no Windows no M1 e o que
    /// `idrs_without_parameters` denuncia do lado do núcleo. Só varrendo as unidades NAL aparece,
    /// e é isso que o `confere-h264.py` faz.
    static func semParametros(de origem: String, para destino: String) -> Bool {
        guard let dados = FileManager.default.contents(atPath: origem) else { return false }
        var saida = Data()
        var corpo = Data()
        var i = 0
        let bytes = [UInt8](dados)

        func fechar() {
            guard let primeiro = corpo.first else { return }
            let tipo = primeiro & 0x1F
            guard tipo != 7 && tipo != 8 else { return }
            saida.append(contentsOf: [0, 0, 0, 1])
            saida.append(corpo)
        }

        while i < bytes.count {
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0,
               bytes[i + 3] == 1 {
                fechar()
                corpo = Data()
                i += 4
                continue
            }
            corpo.append(bytes[i])
            i += 1
        }
        fechar()
        return FileManager.default.createFile(atPath: destino, contents: saida)
    }

    /// Faixas com muita aresta, **nos extremos legais do formato de entrada**.
    ///
    /// Um buffer `420f` carrega 0 e 255 por definição; um `420v` carrega 16 e 235. Pintar os dois
    /// com 0 e 255 — que é o que este arquivo fazia antes — produz um `420v` com valores fora da
    /// própria faixa, e aí a medição de luma do fluxo de saída não distingue mais nada, porque a
    /// entrada já estava errada.
    ///
    /// É a medição de luma que responde à pergunta que o rótulo não responde: **o conteúdo é
    /// mesmo limitado, ou só está etiquetado como tal?**
    private static func pintar(_ imagem: CVPixelBuffer, giro: Int, faixaCompleta: Bool) {
        CVPixelBufferLockBaseAddress(imagem, [])
        defer { CVPixelBufferUnlockBaseAddress(imagem, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(imagem, 0) else { return }
        let largura = CVPixelBufferGetWidthOfPlane(imagem, 0)
        let alturaP = CVPixelBufferGetHeightOfPlane(imagem, 0)
        let passo = CVPixelBufferGetBytesPerRowOfPlane(imagem, 0)
        let escuro: UInt8 = faixaCompleta ? 0 : 16
        let claro: UInt8 = faixaCompleta ? 255 : 235
        let y = base.assumingMemoryBound(to: UInt8.self)
        for linha in 0..<alturaP {
            let faixa = ((linha + giro * 7) / 24) % 2
            memset(y + linha * passo, faixa == 0 ? Int32(escuro) : Int32(claro), largura)
        }
        if CVPixelBufferGetPlaneCount(imagem) > 1,
           let uv = CVPixelBufferGetBaseAddressOfPlane(imagem, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(imagem, 1)
                       * CVPixelBufferGetHeightOfPlane(imagem, 1))
        }
    }
}

Testes.rodar()

// Os `.h264` saem numa pasta para o `rodar.sh` julgar com `ffprobe` e com `confere-h264.py`: a
// asserção **não** é feita aqui de propósito — quem decide é a ferramenta externa, não o programa
// que produziu o fluxo. Foi assim que os três defeitos de faixa de cor deste projeto apareceram.
if CommandLine.arguments.count > 1 {
    let pasta = CommandLine.arguments[1]
    func caminho(_ nome: String) -> String { pasta + "/" + nome }

    print("")
    print("fluxos para o veredito externo")

    func gerar(_ nome: String, _ oQue: String, _ bloco: () -> Bool) {
        if bloco() {
            print("  ok   \(nome) — \(oQue)")
        } else {
            print("  FALHA \(nome) não foi escrito")
            Testes.falhas += 1
        }
    }

    // --- o caminho da câmera: escolher 420v na captura ---------------------------------------
    //
    // É o único que produz rótulo **e** conteúdo limitados. Precisa passar em tudo.
    gerar("camera-420v.h264", "entrada 420v (o que a captura passa a pedir), 720x1280 sem reescala") {
        Fluxos.gerar(em: caminho("camera-420v.h264"),
                     entrada: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     largura: 720, altura: 1280, saidaL: 720, saidaA: 1280, perfil: .camera)
    }

    // --- a matriz do mecanismo -----------------------------------------------------------------
    //
    // Este projeto errou a faixa de cor três vezes, e da terceira **atribuiu o conserto à alavanca
    // errada**: registrou que declarar a entrada em `imageBufferAttributes` fazia a sessão de
    // transferência converter a faixa. Um controle negativo que mexia só nessa chave mostrou o
    // contrário — o fluxo continuou saindo limitado sem ela.
    //
    // A resposta para isso não é outra história plausível: é a **matriz**. Duas chaves
    // (`imageBufferAttributes`, as três de descrição de cor) vezes dois casos de dimensão
    // (com e sem reescala), com a mesma entrada `420f` que o ReplayKit entrega. Oito células, e
    // o `rodar.sh` imprime as oito com rótulo e luma. O que explicar o resultado é o mecanismo;
    // o que não explicar sai da conversa.
    let matriz: [(String, Bool, Bool, Int32, Int32)] = [
        ("matriz-entrada1-cor1-reescala1", true,  true,  718, 1278),
        ("matriz-entrada1-cor1-reescala0", true,  true,  720, 1280),
        ("matriz-entrada1-cor0-reescala1", true,  false, 718, 1278),
        ("matriz-entrada1-cor0-reescala0", true,  false, 720, 1280),
        ("matriz-entrada0-cor1-reescala1", false, true,  718, 1278),
        ("matriz-entrada0-cor1-reescala0", false, true,  720, 1280),
        ("matriz-entrada0-cor0-reescala1", false, false, 718, 1278),
        ("matriz-entrada0-cor0-reescala0", false, false, 720, 1280),
    ]
    for (nome, entradaDeclarada, corDeclarada, l, a) in matriz {
        gerar("\(nome).h264", "entrada 420f 720x1280 → \(l)x\(a)") {
            Fluxos.gerar(em: caminho("\(nome).h264"),
                         entrada: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                         largura: 720, altura: 1280, saidaL: l, saidaA: a, perfil: .camera,
                         declararEntrada: entradaDeclarada, declararCor: corDeclarada,
                         quadros: 12)
        }
    }

    // O emissor de tela, exatamente como ele está hoje: o ReplayKit dá 420f em 750x1334 e o
    // encoder reescala para 720x1280.
    gerar("tela-como-esta-hoje.h264", "420f 750x1334 → 720x1280: o caminho do espelhamento") {
        Fluxos.gerar(em: caminho("tela-como-esta-hoje.h264"),
                     entrada: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                     largura: 750, altura: 1334, saidaL: 720, saidaA: 1280, perfil: .tela)
    }

    // O emissor de tela **no iPhone X**, que é o aparelho que esta bancada nunca rodou.
    //
    // Não é a mesma corrida com outro rótulo. O iPhone 7 é 750x1334, proporção 0,5622, e cai em
    // 720x1280 — em que os dois lados são múltiplos de 16. O iPhone X é 1125x2436, proporção
    // 0,4618, e `destino` o leva a **590x1280**. 590 não é múltiplo de 16: o encoder codifica
    // 592 de largura e o SPS passa a carregar **`frame_cropping`**, que nenhum fluxo desta
    // bancada jamais teve.
    //
    // Isso põe três peças num caminho inédito de uma vez:
    //
    //   1. o analisador do `RemendoDeSPS`, que tem de atravessar os quatro `ue(v)` do corte para
    //      achar o deslocamento em bits do `bitstream_restriction_flag`. Errar ali não degrada a
    //      imagem — **apaga**, porque o SPS entra em todo IDR;
    //   2. a releitura de `conferir()`, que compara a dimensão antes e depois e recusaria o
    //      remendo em silêncio se o corte não sobrevivesse;
    //   3. `confere-h264.py`, que subtrai o corte para dizer a dimensão de verdade.
    //
    // Custa dois segundos no MacBook. Descobrir isso no aparelho custaria a corrida inteira, e o
    // toque humano já teria sido gasto — a folha do `replayd` não se automatiza.
    gerar("tela-iphone-x.h264", "420f 1125x2436 → 590x1280: a tela do iPhone X, com frame_cropping") {
        Fluxos.gerar(em: caminho("tela-iphone-x.h264"),
                     entrada: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                     largura: 1125, altura: 2436, saidaL: 590, saidaA: 1280, perfil: .tela,
                     quadros: 30)
    }

    // --- controles negativos: precisam ser REPROVADOS ----------------------------------------
    //
    // O controle de faixa de cor não está aqui: ele é a própria matriz acima, e as quatro células
    // "sem reescala" são reprovadas nominalmente pelo roteiro. Um controle separado seria uma
    // nona célula dizendo o que as oito já dizem.
    // **Subiu junto com o teto, em 01/09/2026.** Este controle gerava 1080x1920, que era violação
    // no nível 3.1 e passou a ser **exatamente o teto** no 4.0 — um controle negativo que aprova
    // é pior que nenhum. 1440x2560 (QHD de celular) viola o lado maior por 640 px e volta a
    // exercitar o que este controle existe para exercitar.
    gerar("controle-fora-do-teto.h264", "1440x2560 na saída — viola o nível anunciado no SDP") {
        Fluxos.gerar(em: caminho("controle-fora-do-teto.h264"),
                     entrada: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     largura: 1440, altura: 2560, saidaL: 1440, saidaA: 2560, perfil: .camera,
                     quadros: 30)
    }
    gerar("controle-sem-parametros.h264", "os mesmos IDR, sem SPS nem PPS") {
        Fluxos.semParametros(de: caminho("camera-420v.h264"),
                             para: caminho("controle-sem-parametros.h264"))
    }
}

exit(Testes.falhas == 0 ? 0 : 1)
