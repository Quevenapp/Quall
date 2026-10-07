import Foundation
import CoreVideo

/// Os testes do R9 (`docs/controles-de-camera.md` §3): as escalas, o registro e o JSON, as regras de
/// corte e de reaplicação, os textos de quem limita e a divergência pedido × lido. E a média de luma
/// (§5), cronometrada aqui no MacBook antes de virar prova no aparelho.
extension Testes {
    static func rodarControlesDaCamera() {
        typealias R = RegrasDosControles
        print("TetosDoCardapio — o cardápio apaga o que a câmera não faz")
        typealias T = TetosDoCardapio
        let tamanhos = [(chave: 3_600, largura: 1280, altura: 720), (chave: 8_160, largura: 1920, altura: 1080),
                        (chave: 14_400, largura: 2560, altura: 1440), (chave: 32_400, largura: 3840, altura: 2160)]
        // Uma frontal antiga: até 1080p, só a 30.
        let frontal = T.tetos(formatos: [(640, 480, 30), (1280, 720, 30), (1920, 1080, 30)], tamanhos: tamanhos)
        conferir(frontal[8_160] == .some(30) && frontal[32_400] == .some(nil) && frontal[14_400] == .some(nil),
                 "frontal até 1080p30: 1080p a 30, sem 2K nem 4K")
        let ef = T.estado(tetos: frontal, escolhida: 8_160, fps: 60, taxas: [30, 60])
        conferir(ef.resolucoesFora == [14_400, 32_400] && ef.taxasFora == [60] && ef.fpsEfetivo == 30,
                 "o salvo em 1080p60 apaga 2K, 4K e o 60, e vai a 30")
        // Uma traseira com 1080p60 e 4K30: o 2K sai do 4K (30); o 1080p chega a 60.
        let traseira = T.tetos(formatos: [(1920, 1080, 60), (3840, 2160, 30)], tamanhos: tamanhos)
        conferir(traseira[8_160] == .some(60) && traseira[14_400] == .some(30) && traseira[32_400] == .some(30),
                 "traseira 1080p60 + 4K30: 1080p a 60, 2K e 4K a 30")
        conferir(T.estado(tetos: traseira, escolhida: 8_160, fps: 60, taxas: [30, 60]) == T.Estado(),
                 "1080p60 numa câmera que faz: nada apagado")
        conferir(T.estado(tetos: traseira, escolhida: 32_400, fps: 30, taxas: [30, 60]).taxasFora == [60],
                 "4K: o 60 apaga, o salvo em 30 fica")
        let lenta = T.estado(tetos: [32_400: .some(24)], escolhida: 32_400, fps: 30, taxas: [30, 60])
        conferir(lenta.taxasFora == [60] && lenta.fpsEfetivo == 24, "4K só a 24: o 30 nunca se apaga e vai a 24")
        conferir(T.estado(tetos: [:], escolhida: 8_160, fps: 60, taxas: [30, 60]) == T.Estado(),
                 "sem tetos (a tela, ou nada legível): tudo disponível")
        print("RegrasDosControles — pouca luz: o piso do automático e o aviso (§3.1)")
        conferir(R.pisoDoAutomatico(faixas: [(2, 30)], fps: 30) == 15, "faixa 2–30 a 30 fps: o piso é a metade, 15")
        conferir(R.pisoDoAutomatico(faixas: [(2, 30)], fps: 15) == 10, "a 15 fps a metade seria 7,5: o piso fica em 10")
        conferir(R.pisoDoAutomatico(faixas: [(15, 30)], fps: 30) == 15, "faixa 15–30: o piso é 15")
        conferir(R.pisoDoAutomatico(faixas: [(30, 30)], fps: 30) == 30, "faixa fixa: o fps de antes")
        conferir(R.pisoDoAutomatico(faixas: [(2, 30), (2, 60)], fps: 60) == 30, "a 60, a metade: 30")
        conferir(R.pisoDoAutomatico(faixas: [(2, 30)], fps: 60) == 60, "nenhuma faixa alcança 60: fixa")
        var luz = R.VigiaDaPoucaLuz()
        conferir(luz.observar(auto: true, obturadorNs: 100_000_000, fps: 30, agora: 0) == nil, "não acende no primeiro quadro lento")
        conferir(luz.observar(auto: true, obturadorNs: 100_000_000, fps: 30, agora: 1) == 10, "acende depois de 1 s: 10 fps")
        conferir(luz.observar(auto: true, obturadorNs: 33_000_000, fps: 30, agora: 2) == 30, "um quadro normal não apaga")
        conferir(luz.observar(auto: true, obturadorNs: 33_000_000, fps: 30, agora: 4) == nil, "2 s normais apagam")
        var manual = R.VigiaDaPoucaLuz()
        _ = manual.observar(auto: false, obturadorNs: 100_000_000, fps: 30, agora: 0)
        conferir(manual.observar(auto: false, obturadorNs: 100_000_000, fps: 30, agora: 5) == nil, "com exposição manual, nunca")
        var folga = R.VigiaDaPoucaLuz()
        _ = folga.observar(auto: true, obturadorNs: 36_000_000, fps: 30, agora: 0)
        conferir(folga.observar(auto: true, obturadorNs: 36_000_000, fps: 30, agora: 5) == nil, "36 ms a 30 fps é folga, não aviso")
        conferir(R.textoDaPoucaLuz(fpsAgora: 15, fps: 30, temManual: true)
                 == "Pouca luz: 15 fps para clarear a imagem. Para 30 fps, use a exposição manual na engrenagem.",
                 "o texto com manual")
        conferir(R.textoDaPoucaLuz(fpsAgora: 15, fps: 30, temManual: false)
                 == "Pouca luz: 15 fps para clarear a imagem. Mais luz no ambiente devolve os 30 fps.",
                 "o texto sem manual")
        print("RegrasDosControles — obturador: nunca acima de 1/fps (§3.1)")
        // A traseira de um iPhone típico: de 1/45000 s a ~1 s no formato ativo.
        let min = Int64(22_000), max = Int64(1_000_000_000)
        let e30 = R.escalaDoObturador(minimoNs: min, maximoNs: max, fps: 30)
        conferir(e30.first?.texto == "1/30 s", "a 30 fps o mais longo é 1/30 s (\(e30.first?.texto ?? "-"))")
        conferir(!e30.contains { $0.denominador == 24 || $0.denominador == 25 },
                 "1/24 e 1/25 passam do teto de 1/30 e ficam de fora")
        conferir(e30.last?.texto == "1/8000 s", "o mais curto é 1/8000 s, dentro do mínimo da câmera")
        conferir(e30.map(\.ns) == e30.map(\.ns).sorted(by: >), "do mais longo para o mais curto")
        let e60 = R.escalaDoObturador(minimoNs: min, maximoNs: max, fps: 60)
        conferir(e60.first?.texto == "1/60 s" && !e60.contains { $0.denominador == 30 || $0.denominador == 48 },
                 "a 60 fps o teto vira 1/60 s: 1/30 e 1/48 saem")
        let e24 = R.escalaDoObturador(minimoNs: min, maximoNs: max, fps: 24)
        conferir(e24.first?.texto == "1/24 s" && e24.filter { $0.denominador == 24 }.count == 1,
                 "a 24 fps o 1/24 vem da lista, sem repetir")
        let e29 = R.escalaDoObturador(minimoNs: min, maximoNs: max, fps: 29.97)
        conferir(e29.first?.denominador == 30, "a 29,97 fps o 1/30 da lista vale como 1/fps (sem 1/30 duplicado)")
        let e15 = R.escalaDoObturador(minimoNs: min, maximoNs: max, fps: 15)
        conferir(e15.first?.texto == "1/15 s" && e15.contains { $0.denominador == 24 },
                 "a 15 fps: o próprio 1/fps entra (1/15 s), e 1/24 cabe")
        let curta = R.escalaDoObturador(minimoNs: 250_000, maximoNs: 20_000_000, fps: 30)
        conferir(curta.first?.denominador == 50 && curta.last?.denominador == 4000,
                 "uma câmera de máximo 1/50 e mínimo 1/4000: o teto é o da câmera (\(curta.map(\.texto)))")
        conferir(R.tetoDoObturadorNs(fps: 30, maximoNs: max) == 33_333_333, "teto de 1/30: 33.333.333 ns")
        conferir(R.cortarObturador(66_666_666, minimoNs: min, maximoNs: max, fps: 30) == 33_333_333,
                 "1/15 guardado, 30 fps: aplicado no teto")
        conferir(R.cortarObturador(66_666_666, minimoNs: min, maximoNs: max, fps: 15) == 66_666_666,
                 "e o guardado volta a valer se o fps voltar")
        conferir(R.cortarObturador(1_000, minimoNs: min, maximoNs: max, fps: 30) == min,
                 "abaixo do mínimo do formato: o mínimo (NSRangeException evitada)")
        conferir(R.cortarObturador(5_000_000, minimoNs: min, maximoNs: 2_000_000, fps: 30) == 2_000_000,
                 "acima do máximo do formato novo: o máximo")
        conferir(R.textoDoObturador(ns: 16_666_667) == "1/60 s" && R.textoDoObturador(ns: 8_000_000) == "1/125 s",
                 "o texto é sempre 1/N s")
        let brasil = R.sugestaoContraCintilacao(.auto, regiao: "BR")
        conferir(brasil?.fracoes == [60, 120] && brasil?.legenda == "sem cintilação em luz de 60 Hz",
                 "auto no Brasil: 1/60 e 1/120, \"sem cintilação em luz de 60 Hz\"")
        conferir(R.sugestaoContraCintilacao(.hz50, regiao: "BR")?.fracoes == [50, 100]
                 && R.sugestaoContraCintilacao(.hz50, regiao: "BR")?.legenda == "sem cintilação em luz de 50 Hz",
                 "50 Hz: 1/50 e 1/100")
        conferir(R.sugestaoContraCintilacao(.auto, regiao: "PT") == nil
                 && R.sugestaoContraCintilacao(.desligada, regiao: "BR") == nil,
                 "auto fora do Brasil, ou desligada: sem legenda")
        let marcada = R.escalaDoObturador(minimoNs: min, maximoNs: max, fps: 30, marcados: [60, 120])
        conferir(marcada.filter(\.semCintilacao).map(\.denominador) == [60, 120], "o ponto vai em 1/60 e 1/120")

        print("RegrasDosControles — ISO em terços de stop (§3.2)")
        let iso = R.escalaDoIso(minimo: 23, maximo: 736)
        conferir(iso.first == 23 && iso.last == 736 && iso.contains(50) && iso.contains(640) && !iso.contains(800),
                 "cortada pela faixa, mais o mínimo e o máximo exatos (\(iso.map { Int($0) }))")
        conferir(R.escalaDoIso(minimo: 100, maximo: 100) == [100], "faixa de um ponto: só ele")
        conferir(R.cortarIso(3200, minimo: 23, maximo: 736) == 736 && R.cortarIso(10, minimo: 23, maximo: 736) == 23,
                 "o ISO cortado pela faixa do formato ativo")
        conferir(R.cortarIso(.nan, minimo: 23, maximo: 736) == 23, "NaN não chega à câmera")
        conferir(!R.ganhoDigital(3200, maximoAnalogico: nil) && R.ganhoDigital(1600, maximoAnalogico: 800),
                 "ganho digital só onde a câmera declara o fim do analógico (o iOS não declara)")

        print("RegrasDosControles — EV (§3.3)")
        let ev = R.escalaDoEv(minimo: -8, maximo: 8)
        conferir(ev.count == 49 && ev.contains(0), "de -8 a +8 em terços: 49 degraus")
        conferir(abs(R.arredondarEv(0.4, minimo: -8, maximo: 8) - 1.0 / 3) < 1e-9, "0,4 arredonda a 1/3")
        conferir(R.arredondarEv(12, minimo: -2, maximo: 2) == 2, "fora da faixa: o extremo (NSRangeException evitada)")
        conferir(R.textoDoEv(1.0 / 3) == "+0,3 EV" && R.textoDoEv(0) == "0 EV" && R.textoDoEv(-2.0 / 3) == "-0,7 EV",
                 "texto: +0,3 EV, 0 EV, -0,7 EV (sinal sempre visível, vírgula)")

        print("RegrasDosControles — Kelvin e presets (§3.4)")
        conferir(R.kelvinDoPreset(.incandescente) == 2850 && R.kelvinDoPreset(.fluorescente) == 4000
                 && R.kelvinDoPreset(.luzDoDia) == 5500 && R.kelvinDoPreset(.nublado) == 6500,
                 "presets: 2850, 4000, 5500 e 6500 K")
        conferir(R.arredondarKelvin(5249) == 5200 && R.arredondarKelvin(1500) == 2000 && R.arredondarKelvin(12000) == 10000,
                 "Kelvin de 100 em 100, entre 2000 e 10000")
        conferir(R.cortarGanhos([0.5, 2, 9], maximo: 4) == [1, 2, 4], "ganhos em [1, maxWhiteBalanceGain]")

        print("RegrasDosControles — foco: lensPosition = 1 − focoPosicao (§2)")
        conferir(R.lentePara(focoPosicao: 0) == 1 && R.lentePara(focoPosicao: 1) == 0
                 && abs(R.lentePara(focoPosicao: 0.3) - 0.7) < 1e-12,
                 "longe (0) é lensPosition 1; o mais perto (1) é 0")
        conferir(R.focoPosicao(daLente: 0.25) == 0.75 && R.lentePara(focoPosicao: 7) == 0,
                 "a volta, e o corte em [0, 1]")

        print("RegrasDosControles — o registro e o JSON (§2)")
        var a = AjustesDaCamera()
        a.exposicao = .manual; a.iso = 400; a.obturadorNs = 16_666_667; a.antiCintilacao = .hz60
        a.balanco = .luzDoDia; a.travaGanhos = [1.9, 1, 2.1]; a.foco = .manual; a.focoPosicao = 0.42
        let json = a.json() ?? Data()
        let texto = String(data: json, encoding: .utf8) ?? ""
        conferir(AjustesDaCamera.de(json: json) == a, "ida e volta pelo JSON")
        conferir(texto.contains("\"obturadorNs\"") && texto.contains("\"luzDoDia\"") && texto.contains("\"antiCintilacao\":\"60\"")
                 && texto.contains("\"focoPosicao\""), "camelCase e valores literais no JSON (\(texto.prefix(60))…)")
        conferir(AjustesDaCamera.de(json: Data("{}".utf8)) == .padrao, "JSON vazio: o padrão da tabela")
        conferir(AjustesDaCamera.de(json: Data("{\"balanco\":\"marciano\",\"ev\":1}".utf8)).balanco == .auto
                 && AjustesDaCamera.de(json: Data("{\"balanco\":\"marciano\",\"ev\":1}".utf8)).ev == 1,
                 "valor desconhecido fica no padrão sem perder o resto")
        conferir(AjustesDaCamera.de(json: Data("lixo".utf8)) == .padrao && AjustesDaCamera.de(json: nil) == .padrao,
                 "JSON ilegível ou ausente: o padrão")
        conferir(AjustesDaCamera.chave("ABC") == "camera.ajustes.ABC", "a chave é camera.ajustes.<uniqueID>")
        conferir(!texto.contains("travaIso"), "o que é nenhum não vai ao JSON")

        print("RegrasDosControles — o plano de aplicação, com corte e reaplicação (§2.1, §2.2)")
        var tudo = CapacidadesDaCamera()
        tudo.exposicaoCustom = true; tudo.exposicaoUmaVez = true; tudo.exposicaoContinua = true; tudo.exposicaoTravada = true
        tudo.pontoDeExposicao = true; tudo.focoContinuo = true; tudo.focoUmaVez = true; tudo.focoTravado = true
        tudo.pontoDeFoco = true; tudo.lenteCustom = true; tudo.balancoContinuo = true; tudo.balancoUmaVez = true
        tudo.balancoTravado = true; tudo.ganhosCustom = true
        let f30 = FaixasDaCamera(isoMin: 23, isoMax: 736, obturadorMinNs: min, obturadorMaxNs: max,
                                 evMin: -8, evMax: 8, ganhoMax: 4, fps: 30)
        var f60 = f30; f60.fps = 60; f60.isoMin = 46
        conferir(R.plano(.padrao, tudo, f30, reaplicando: true)
                 == R.Plano(exposicao: .continua(ev: 0), balanco: .continuo, foco: .continuo, travadoDeNovo: false),
                 "padrão: tudo contínuo")
        var m = AjustesDaCamera(); m.exposicao = .manual; m.iso = 30; m.obturadorNs = 33_333_333
        conferir(R.plano(m, tudo, f60, reaplicando: true).exposicao == .manual(iso: 46, ns: 16_666_666),
                 "manual reaplicado num formato de 60 fps: ISO e obturador cortados na faixa nova")
        var t = AjustesDaCamera(); t.travaExposicao = true; t.travaIso = 200; t.travaObturadorNs = 10_000_000
        conferir(R.plano(t, tudo, f30, reaplicando: true).exposicao == .manual(iso: 200, ns: 10_000_000)
                 && !R.plano(t, tudo, f30, reaplicando: true).travadoDeNovo,
                 "trava com manual disponível: volta como manual com os valores guardados")
        var semManual = tudo; semManual.exposicaoCustom = false; semManual.ganhosCustom = false; semManual.lenteCustom = false
        let pSem = R.plano(t, semManual, f30, reaplicando: true)
        conferir(pSem.exposicao == .medirETravar(ev: 0) && pSem.travadoDeNovo,
                 "trava sem manual: mede e trava ao convergir, e a tela avisa")
        conferir(!R.plano(t, semManual, f30, reaplicando: false).travadoDeNovo, "travar agora (não reaplicar) não avisa")
        var tSemValor = t; tSemValor.travaIso = nil
        conferir(R.plano(tSemValor, tudo, f30, reaplicando: true).exposicao == .medirETravar(ev: 0),
                 "trava sem os valores guardados: mede e trava")
        var comEv = AjustesDaCamera(); comEv.ev = 0.4
        conferir(R.plano(comEv, tudo, f30, reaplicando: false).exposicao == .continua(ev: 1.0 / 3),
                 "o EV vai arredondado ao passo")
        var mSemValor = AjustesDaCamera(); mSemValor.exposicao = .manual
        conferir(R.plano(mSemValor, tudo, f30, reaplicando: true).exposicao == .continua(ev: 0),
                 "manual sem ISO e obturador lidos: não inventa valor, fica no automático")
        var k = AjustesDaCamera(); k.balanco = .kelvin; k.kelvin = 3150
        conferir(R.plano(k, tudo, f30, reaplicando: true).balanco == .kelvin(3200), "Kelvin arredondado a 100")
        var p = AjustesDaCamera(); p.balanco = .nublado
        conferir(R.plano(p, tudo, f30, reaplicando: true).balanco == .kelvin(6500), "preset por Kelvin fixo")
        conferir(R.plano(p, semManual, f30, reaplicando: true).balanco == .continuo, "preset sem ganhos manuais: automático")
        var tb = AjustesDaCamera(); tb.travaBalanco = true; tb.travaGanhos = [0.8, 1, 5]
        conferir(R.plano(tb, tudo, f30, reaplicando: true).balanco == .ganhos([1, 1, 4]),
                 "trava de balanço reaplicada como ganhos, cortados em [1, máximo]")
        conferir(R.plano(tb, semManual, f30, reaplicando: true).balanco == .medirETravar, "sem ganhos manuais: mede e trava")
        var fm = AjustesDaCamera(); fm.foco = .manual; fm.focoPosicao = 0.25
        conferir(R.plano(fm, tudo, f30, reaplicando: true).foco == .lente(0.75), "foco manual: lensPosition = 1 − 0,25")
        var ft = AjustesDaCamera(); ft.foco = .travado; ft.focoPosicao = 1
        conferir(R.plano(ft, tudo, f30, reaplicando: true).foco == .lente(0), "foco travado no mais perto: lensPosition 0")
        conferir(R.plano(ft, semManual, f30, reaplicando: true).foco == .medirETravar
                 && R.plano(ft, semManual, f30, reaplicando: true).travadoDeNovo, "foco travado sem lente manual: mede e trava")
        var fixo = semManual; fixo.focoContinuo = false; fixo.focoUmaVez = false; fixo.focoTravado = false; fixo.pontoDeFoco = false
        conferir(R.plano(fm, fixo, f30, reaplicando: true).foco == .nada, "foco fixo: nada a fazer no foco")

        print("RegrasDosControles — quem limita: os textos (§3.5)")
        conferir(R.textoDoFabricante(.kelvin) == "O fabricante deste aparelho não libera o Kelvin para outros apps.",
                 "a frase do fabricante, com o artigo no nome")
        conferir(R.limite(.antiCintilacao, tudo, f30) == "O iOS ajusta a cintilação sozinho.", "anti-cintilação no iOS")
        conferir(R.limite(.focoManual, fixo, f30) == "Esta câmera tem foco fixo."
                 && R.limite(.travaFoco, fixo, f30) == "Esta câmera tem foco fixo.", "foco fixo")
        conferir(R.limite(.iso, semManual, f30) == "O fabricante deste aparelho não libera ISO para outros apps."
                 && R.limite(.iso, tudo, f30) == nil, "ISO apagado só sem o manual")
        conferir(R.limite(.presets, semManual, f30) != nil && R.limite(.travaExposicao, semManual, f30) == nil,
                 "presets sem ganhos manuais; a trava continua (mede e trava)")
        var semEv = f30; semEv.evMin = 0; semEv.evMax = 0
        conferir(R.limite(.compensacao, tudo, semEv) == R.textoDoFabricante(.compensacao), "EV sem faixa")
        conferir(R.Controle.allCases.map(\.rawValue).contains("o toque para focar"), "os nomes são os da especificação")

        print("RegrasDosControles — a leitura e a divergência (§3.6)")
        let l = R.Leitura(iso: 400, obturadorNs: 16_666_667, kelvin: 5200, abertura: 1.7, lente: 0.3)
        conferir(R.linhaDaLeitura(l) == "ISO 400 · 1/60 s · 5200 K · f/1,7",
                 "ISO 400 · 1/60 s · 5200 K · f/1,7 (\(R.linhaDaLeitura(l)))")
        conferir(R.linhaDaLeitura(R.Leitura(iso: 100, abertura: 2.0)) == "ISO 100 · f/2", "só o que se leu; f/2 sem o ,0")
        conferir(!R.divergeEmStops(pedido: 400, lido: 500) && R.divergeEmStops(pedido: 400, lido: 640),
                 "ISO: um terço de stop é um passo; dois passos divergem")
        conferir(!R.divergeEmKelvin(pedido: 5000, lido: 5100) && R.divergeEmKelvin(pedido: 5000, lido: 5300),
                 "Kelvin: 100 K é um passo")
        var vigia = R.VigiaDaDivergencia()
        conferir(!vigia.observar(diverge: true, agora: 10) && !vigia.observar(diverge: true, agora: 11.5)
                 && vigia.observar(diverge: true, agora: 12.1), "só depois de 2 s seguidos")
        conferir(!vigia.observar(diverge: false, agora: 12.2) && !vigia.observar(diverge: true, agora: 13),
                 "uma leitura que concorda zera o relógio")
        conferir(R.textoDaDivergencia(lido: "ISO 640", pedido: "ISO 400") == "A câmera usou ISO 640 em vez de ISO 400.",
                 "o texto da divergência")

        print("RegrasDosControles — deslizantes: no máximo 15 envios por segundo (§2.2)")
        var g = R.Agrupador()
        conferir(g.pedir(agora: 100) == 0, "o primeiro vai na hora")
        conferir(g.pedir(agora: 100.01) == nil, "outro pedido com um marcado: o marcado leva o último valor")
        g.enviou(agora: 100)
        let atraso = g.pedir(agora: 100.02) ?? -1
        conferir(abs(atraso - (1.0 / 15 - 0.02)) < 1e-9, "o seguinte espera o resto de 1/15 s")
        g.enviou(agora: 100.0667)
        conferir(g.pedir(agora: 101) == 0, "parado há muito: vai na hora")

        print("RegrasDosControles — o toque na prévia (§4.4)")
        let simples = R.decidirToque(.padrao, tudo, longo: false)
        conferir(simples.foca && simples.mede && simples.quadrado && simples.pilula == nil, "um toque foca e mede, com quadrado")
        let longo = R.decidirToque(.padrao, tudo, longo: true)
        conferir(longo.ajustes.travaExposicao && longo.ajustes.foco == .travado && longo.travarExposicao && longo.travarFoco
                 && longo.pilula == "Exposição e foco travados", "o toque longo trava os dois, e a pílula diz")
        let desfaz = R.decidirToque(longo.ajustes, tudo, longo: false)
        conferir(!desfaz.ajustes.travaExposicao && desfaz.ajustes.foco == .auto && desfaz.mede && desfaz.foca,
                 "um toque simples depois desfaz as duas travas e mede no ponto novo")
        var expManual = AjustesDaCamera(); expManual.exposicao = .manual
        let soFoca = R.decidirToque(expManual, tudo, longo: true)
        conferir(soFoca.foca && !soFoca.mede && soFoca.pilula == "Foco travado", "exposição manual: só foca (\"Foco travado\")")
        let soMede = R.decidirToque(.padrao, fixo, longo: true)
        conferir(soMede.mede && !soMede.foca && soMede.pilula == "Exposição travada", "foco fixo: só mede (\"Exposição travada\")")
        var osDois = expManual; osDois.foco = .manual
        let nada = R.decidirToque(osDois, tudo, longo: true)
        conferir(!nada.quadrado && nada.pilula == nil && nada.ajustes == osDois, "os dois em manual: nada, e nem quadrado")
    }

    static func rodarMediaDeLuma() {
        print("MediaDeLuma — a média do plano Y subamostrado (§5), e quanto custa")
        func buffer(_ l: Int, _ a: Int, _ tipo: OSType, valor: (Int, Int) -> UInt8) -> CVPixelBuffer? {
            var b: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, l, a, tipo, nil, &b) == kCVReturnSuccess, let b else { return nil }
            CVPixelBufferLockBaseAddress(b, [])
            if let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) {
                let passo = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
                for j in 0..<a { for i in 0..<l { y[j * passo + i] = valor(i, j) } }
            }
            CVPixelBufferUnlockBaseAddress(b, [])
            return b
        }
        let v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if let cinza = buffer(1920, 1080, v, valor: { _, _ in 126 }) {
            conferir(MediaDeLuma.media(cinza) == 126, "um quadro uniforme dá o próprio valor")
            // O custo, cronometrado: 300 chamadas (dez segundos de captura a 30 fps chamariam 10).
            let n = 300
            var maior = 0.0
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<n {
                let a = CFAbsoluteTimeGetCurrent()
                _ = MediaDeLuma.media(cinza)
                maior = Swift.max(maior, CFAbsoluteTimeGetCurrent() - a)
            }
            let medio = (CFAbsoluteTimeGetCurrent() - t0) / Double(n)
            print(String(format: "       custo no MacBook, 1920x1080 420v, passo %d: médio %.1f µs, maior %.1f µs",
                         MediaDeLuma.passo, medio * 1e6, maior * 1e6))
            conferir(medio < 0.002, "abaixo de 2 ms por chamada no MacBook (uma em 30 quadros)")
        } else {
            conferir(false, "não criou o buffer 420v de teste")
        }
        // Metade escura, metade clara: a média fica no meio, e o subamostrado não erra por pegar só
        // um dos lados.
        if let meio = buffer(1280, 720, v, valor: { i, _ in i < 640 ? 16 : 235 }) {
            let m = MediaDeLuma.media(meio) ?? -1
            conferir(abs(m - 125.5) < 0.5, "metade 16, metade 235: média 125,5 (\(m))")
        }
        if let bgra = buffer(64, 64, kCVPixelFormatType_32BGRA, valor: { _, _ in 0 }) {
            conferir(MediaDeLuma.media(bgra) == nil, "BGRA não tem plano de luma: nenhum número em vez de um errado")
        }
    }
}
