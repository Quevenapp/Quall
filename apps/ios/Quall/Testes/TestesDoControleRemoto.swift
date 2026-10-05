import Foundation

/// Os testes do R9b (`docs/controle-remoto-da-camera.md`): o molde do painel (o local tem de ser o
/// painel do R9 de sempre; o remoto lê as formas do §3.2), as capacidades do iOS no fio, o pedido
/// aplicado na ordem do §6, o pedido parcial do receptor, o estado do receptor e o ponto do toque.
extension Testes {
    static func rodarControleRemoto() {
        typealias R = RegrasDosControles
        typealias X = RegrasDoControleRemoto

        // Uma traseira completa, uma frontal de foco fixo sem ganhos manuais, e uma câmera pobre.
        var cheia = CapacidadesDaCamera()
        cheia.exposicaoCustom = true; cheia.exposicaoUmaVez = true; cheia.exposicaoContinua = true
        cheia.exposicaoTravada = true; cheia.pontoDeExposicao = true; cheia.focoContinuo = true
        cheia.focoUmaVez = true; cheia.focoTravado = true; cheia.pontoDeFoco = true; cheia.lenteCustom = true
        cheia.balancoContinuo = true; cheia.balancoUmaVez = true; cheia.balancoTravado = true; cheia.ganhosCustom = true
        var frontal = CapacidadesDaCamera()
        frontal.exposicaoCustom = true; frontal.exposicaoUmaVez = true; frontal.exposicaoContinua = true
        frontal.pontoDeExposicao = true; frontal.balancoContinuo = true; frontal.balancoUmaVez = true
        let pobre = CapacidadesDaCamera()
        let f = FaixasDaCamera(isoMin: 22.5, isoMax: 1840.7, obturadorMinNs: 14_000, obturadorMaxNs: 500_000_000,
                               evMin: -8, evMax: 8, ganhoMax: 4, fps: 30)
        let semEv = FaixasDaCamera(isoMin: 34, isoMax: 2176, obturadorMinNs: 14_000, obturadorMaxNs: 500_000_000,
                                   evMin: 0, evMax: 0, ganhoMax: 4, fps: 60)

        print("MoldeDoPainel.local — as linhas de quem limita são as do painel do R9")
        let todos = R.Controle.allCases.filter { $0 != .brilho && $0 != .ganho }
        for (nome, c, fx) in [("cheia", cheia, f), ("frontal", frontal, f), ("pobre", pobre, semEv), ("cheia sem EV", cheia, semEv)] {
            let m = MoldeDoPainel.local(c, fx)
            let iguais = todos.filter { m.limite($0) != R.limite($0, c, fx) }
            conferir(iguais.isEmpty, "\(nome): as \(todos.count) linhas iguais às de RegrasDosControles.limite"
                     + (iguais.isEmpty ? "" : " (diferem: \(iguais.map(\.rawValue)))"))
        }
        let mc = MoldeDoPainel.local(cheia, f)
        conferir(mc.escalaDoEv() == R.escalaDoEv(minimo: -8, maximo: 8), "o EV local: a escala de 1/3 do R9")
        conferir(mc.escalaDoIso() == R.escalaDoIso(minimo: 22.5, maximo: 1840.7), "o ISO local: os terços do R9")
        conferir(mc.escalaDoObturador() == R.escalaDoObturador(minimoNs: 14_000, maximoNs: 500_000_000, fps: 30),
                 "o obturador local: a escala do R9, com o teto de 1/fps")
        conferir(mc.obturadorAplicado(66_666_666) == 33_333_333, "o obturador guardado acima do teto aparece no teto")
        conferir(mc.escalaDoKelvin().first == 2000 && mc.escalaDoKelvin().last == 10000 && mc.escalaDoKelvin().count == 81,
                 "o Kelvin local: 2000 a 10000 de 100 em 100")
        let foco = mc.escalaDoFoco()
        conferir(foco.count == 101 && foco.first == 1 && foco.last == 0, "o foco local: 101 degraus, do perto (1) ao longe (0)")
        conferir(MoldeDoPainel.local(frontal, f).focoFixo && !mc.focoFixo, "a frontal sem foco é foco fixo; a traseira, não")
        conferir(mc.textoDoEv(0.3333) == "+0,3 EV" && mc.tituloDoEv == "EV" && mc.tituloDaAbaDoIso == "ISO e obturador",
                 "os títulos e o texto do EV do iOS")

        print("CapacidadesRemotas.doIOS — o fio do §3.2")
        let caps = CapacidadesRemotas.doIOS(cheia, f, nome: "Câmera traseira")
        let json = CapacidadesRemotas.json(caps) ?? ""
        conferir(!json.isEmpty && json.utf8.count < 2048, "as capacidades cabem no teto de 2048 bytes (\(json.utf8.count))")
        let ctl = caps["controles"] as? [String: Any] ?? [:]
        let iso = ctl["iso"] as? [String: Any] ?? [:]
        conferir(iso["min"] as? Int == 23 && iso["max"] as? Int == 1840 && iso["inteiro"] as? Bool == true,
                 "iso com inteiro, a faixa para dentro (23–1840 de 22,5–1840,7)")
        let obt = ctl["obturadorNs"] as? [String: Any] ?? [:]
        conferir(obt["max"] as? Int64 == 33_333_333 && obt["inteiro"] as? Bool == true,
                 "obturadorNs com o teto de 1/fps (33.333.333) e inteiro")
        conferir((ctl["kelvin"] as? [String: Any])?["inteiro"] as? Bool == true, "kelvin com inteiro")
        conferir(ctl["antiCintilacao"] == nil && (caps["limites"] as? [String: String])?["antiCintilacao"] == "ios_cintilacao",
                 "a anti-cintilação fora de controles, com ios_cintilacao")
        conferir((ctl["exposicao"] as? [String: Any])?["valores"] as? [String] == ["auto", "manual"]
                 && (ctl["foco"] as? [String: Any])?["valores"] as? [String] == ["auto", "travado", "manual"]
                 && ctl["toque"] != nil, "exposição, foco e toque da traseira")
        conferir(ctl["travaIso"] == nil && ctl["travaGanhos"] == nil && ctl["travaObturadorNs"] == nil,
                 "os campos de trava lida nunca aparecem")
        let capsF = CapacidadesRemotas.doIOS(frontal, f, nome: "Frontal")
        let limF = capsF["limites"] as? [String: String] ?? [:]
        conferir(limF["foco"] == "foco_fixo" && limF["focoPosicao"] == "foco_fixo" && limF["kelvin"] == "fabricante"
                 && (capsF["controles"] as? [String: Any])?["foco"] == nil,
                 "a frontal: foco fixo e sem Kelvin, com os códigos")
        conferir(CapacidadesRemotas.cortarNome(String(repeating: "câmera ", count: 20)).utf8.count <= 64,
                 "o nome da câmera em até 64 bytes")
        // A forma que o núcleo confere (`conferir_capacidades` e `descritor`, camera_remota.rs): uma
        // forma errada é `QUALL_STATUS_INVALID` no `set_camera`, e a câmera nunca chega ao receptor.
        let estranha = FaixasDaCamera(isoMin: 22.000002, isoMax: 22.4, obturadorMinNs: 40_000_000,
                                      obturadorMaxNs: 50_000_000, evMin: -2, evMax: 2, ganhoMax: 4, fps: 60)
        for (nome, cx) in [("traseira", caps), ("frontal", capsF), ("sem EV", CapacidadesRemotas.doIOS(cheia, semEv, nome: "x")),
                           ("pobre", CapacidadesRemotas.doIOS(pobre, semEv, nome: "x")),
                           ("ISO de um ponto e obturador mínimo acima do teto", CapacidadesRemotas.doIOS(cheia, estranha, nome: "x"))] {
            let problemas = problemasDeForma(cx)
            conferir(problemas.isEmpty, "\(nome): a forma que o núcleo aceita" + (problemas.isEmpty ? "" : " (\(problemas))"))
        }
        let cxEstranha = CapacidadesRemotas.doIOS(cheia, estranha, nome: "x")
        conferir(((cxEstranha["controles"] as? [String: Any])?["iso"] as? [String: Any])?["min"] as? Int == 22
                 && (cxEstranha["limites"] as? [String: String])?["obturadorNs"] == "fabricante",
                 "o ruído do Float não empurra o ISO mínimo (22,000002 → 22), e o obturador sem faixa vira limite")
        let capsSemEv = CapacidadesRemotas.doIOS(cheia, semEv, nome: "x")
        let obt60 = (capsSemEv["controles"] as? [String: Any])?["obturadorNs"] as? [String: Any]
        conferir(obt60?["max"] as? Int64 == 16_666_666, "a 60 fps o teto do obturador vira 1/60 (só as faixas mudam)")

        print("MoldeDoPainel.remoto — o iOS de volta, o Android, o Mac e o Windows do §3.2")
        let volta = MoldeDoPainel.remoto(caps)
        conferir(volta.exposicaoManual && volta.ev == mc.ev && volta.travaExposicao && volta.balanco == mc.balanco
                 && volta.foco == mc.foco && volta.toque && volta.kelvin?.min == 2000,
                 "o iOS ida e volta: o mesmo molde")
        let semFps = todos.filter { volta.limite($0) != mc.limite($0) }
        conferir(semFps.isEmpty, "o iOS ida e volta: as mesmas linhas de quem limita (\(semFps.map(\.rawValue)))")
        conferir(volta.escalaDoObturador().first?.texto == "1/30 s"
                 && volta.escalaDoObturador().map(\.texto) == mc.escalaDoObturador().map(\.texto),
                 "o iOS ida e volta: a mesma escala do obturador (\(volta.escalaDoObturador().first?.texto ?? "-"))")
        let android = jsonObjeto("""
        {"plataforma":"android","nomeDaCamera":"Traseira","controles":{
         "exposicao":{"valores":["auto","manual"]},"ev":{"min":-2.0,"max":2.0,"passo":0.1},"travaExposicao":{},
         "antiCintilacao":{"valores":["auto","50","60","desligada"]},
         "iso":{"min":50,"max":3200,"inteiro":true,"analogicoMax":800},
         "obturadorNs":{"min":100000,"max":33333333,"inteiro":true},
         "balanco":{"valores":["auto","incandescente","fluorescente","luzDoDia","nublado","kelvin"]},
         "kelvin":{"min":2000,"max":10000,"passo":100,"inteiro":true},"travaBalanco":{},
         "foco":{"valores":["auto","travado","manual"]},"focoPosicao":{"min":0.0,"max":1.0,"passo":0.01},"toque":{}},
         "limites":{}}
        """)
        let ma = MoldeDoPainel.remoto(android)
        conferir(ma.escalaDoEv().count == 41 && ma.textoDoEv(0.5) == "+0,5 EV", "Android: EV de 0,1 em 0,1 (41 degraus)")
        conferir(ma.antiCintilacao == ["auto", "50", "60", "desligada"] && ma.limite(.antiCintilacao) == nil,
                 "Android: a anti-cintilação com os quatro valores, sem linha")
        conferir(ma.textoDoIso(1600) == "ISO 1600 · ganho digital" && ma.textoDoIso(800) == "ISO 800",
                 "Android: \"ganho digital\" acima do analógico")
        conferir(ma.escalaDoObturador().first?.texto == "1/30 s" && ma.escalaDoObturador().last?.texto == "1/8000 s",
                 "Android: o obturador de 1/30 a 1/8000 s")
        conferir(ma.limite(.iso) == nil && ma.limite(.kelvin) == nil && ma.limite(.presets) == nil && !ma.focoFixo,
                 "Android: nada limitado")
        let mac = jsonObjeto("""
        {"controles":{"travaExposicao":{},"travaBalanco":{},"foco":{"valores":["auto","travado"]},"toque":{}},
         "limites":{"ev":"macos","iso":"macos","obturadorNs":"macos","kelvin":"macos","antiCintilacao":"macos","focoPosicao":"macos"}}
        """)
        let mm = MoldeDoPainel.remoto(mac)
        conferir(mm.limite(.iso) == "O macOS não oferece ISO para câmeras."
                 && mm.limite(.compensacao) == "O macOS não oferece a compensação de exposição para câmeras."
                 && mm.limite(.focoManual) == "O macOS não oferece o foco manual para câmeras.",
                 "Mac: as linhas com o código macos")
        conferir(!mm.exposicaoManual && mm.limite(.travaFoco) == nil && mm.balanco.isEmpty && mm.toque,
                 "Mac: sem Manual, com trava de foco e toque")
        conferir(mm.limite(.presets) == "O macOS não oferece os presets de balanço para câmeras.",
                 "Mac: sem presets nem Kelvin, a linha dos presets com o motivo do Kelvin")
        let windows = jsonObjeto("""
        {"controles":{"exposicao":{"valores":["auto","manual"]},
         "ev":{"min":-64,"max":64,"passo":1,"inteiro":true,"unidade":"brilho","origem":128},
         "iso":{"min":0,"max":100,"passo":1,"inteiro":true,"unidade":"ganho"},
         "obturadorNs":{"min":1000000,"max":33333333,"inteiro":true,"escala":"log2"},
         "balanco":{"valores":["auto","kelvin"]},"kelvin":{"min":2800,"max":6500,"passo":10,"inteiro":true},
         "antiCintilacao":{"valores":["50","60","desligada"]}},
         "limites":{"focoPosicao":"camera_nao_oferece","foco":"camera_nao_oferece","toque":"camera_nao_oferece","x":"codigo_novo"}}
        """)
        let mw = MoldeDoPainel.remoto(windows)
        conferir(mw.tituloDoEv == "Brilho" && mw.textoDoEv(-28) == "100" && mw.tituloDaAbaDoIso == "Ganho e obturador"
                 && mw.tituloDoIso == "Ganho", "Windows: Brilho (origem + valor), Ganho, \"Ganho e obturador\"")
        let log2 = mw.escalaDoObturador().map(\.texto)
        conferir(log2 == ["1/32 s", "1/64 s", "1/128 s", "1/256 s", "1/512 s"],
                 "Windows: o obturador em 2^v dentro da faixa (\(log2))")
        conferir(mw.escalaDoIso().count == 101 && mw.escalaDoKelvin().first == 2800 && mw.escalaDoKelvin().last == 6500,
                 "Windows: o ganho de 1 em 1, o Kelvin da faixa do driver")
        conferir(mw.limite(.focoManual) == "Esta câmera não oferece o foco manual."
                 && mw.limite(.toque) == "Esta câmera não oferece o toque para focar."
                 && mw.limite(.presets) == "Este aparelho não oferece os presets de balanço.",
                 "Windows: camera_nao_oferece, e o genérico sem código")
        let calibrado = MoldeDoPainel.remoto(jsonObjeto("""
        {"controles":{"foco":{"valores":["auto","travado","manual"]},
         "focoPosicao":{"min":0.0,"max":1.0,"passo":0.01,"calibrado":10.0}},"limites":{}}
        """))
        conferir(calibrado.dioptriasDoFoco == 10 && calibrado.textoDoFoco(0) == "∞" && calibrado.textoDoFoco(1) == "0,10 m"
                 && calibrado.textoDoFoco(0.05) == "2,0 m" && mc.textoDoFoco(0.4) == "0,40",
                 "o foco em metros com a lente calibrada (∞, 0,10 m, 2,0 m); sem calibração, a posição")
        conferir(CapacidadesRemotas.nomeDaCamera(frontal: true, nomeDaOrigem: "Câmera frontal") == "Frontal"
                 && CapacidadesRemotas.nomeDaCamera(frontal: false, nomeDaOrigem: "Câmera traseira (teleobjetiva)")
                    == "Traseira (teleobjetiva)"
                 && CapacidadesRemotas.nomeDaCamera(frontal: nil, nomeDaOrigem: "USB Camera") == "USB Camera",
                 "o nome da câmera no fio: Frontal / Traseira (com a lente), ou o do seletor")
        conferir(X.frase("codigo_que_nao_existe", .iso) == "Este aparelho não oferece ISO."
                 && X.frase("sem_calibracao", .kelvin) == "Esta câmera não publica a calibração de cor que o Kelvin precisa."
                 && X.frase("outro_app", .iso) == "Outro app está controlando esta câmera. Feche-o para ajustar.",
                 "as frases de cada código, e o código desconhecido")

        print("RegrasDoControleRemoto.aplicar — a ordem do §6, partindo do lido só no ausente")
        let lido = X.Lido(iso: 320, obturadorNs: 16_666_667, ganhos: [2.0, 1.0, 1.6], kelvin: 4870, focoPosicao: 0.42)
        func pedido(_ ajuste: String, restaurar: Bool = false) -> X.Pedido {
            X.Pedido.de(json: "{\"n\":7,\"autor\":\"OBS no Dell\",\"ajuste\":\(ajuste),\"restaurar\":\(restaurar),\"toque\":null}")!
        }
        let manualIso = X.aplicar(pedido("{\"exposicao\":\"manual\",\"iso\":800}"), sobre: .padrao, lido: lido, evMin: -8, evMax: 8)
        conferir(manualIso?.exposicao == .manual && manualIso?.iso == 800 && manualIso?.obturadorNs == 16_666_667,
                 "{exposicao: manual, iso: 800}: fica 800, e o obturador parte do lido")
        let soManual = X.aplicar(pedido("{\"exposicao\":\"manual\"}"), sobre: .padrao, lido: lido, evMin: -8, evMax: 8)
        conferir(soManual?.iso == 320 && soManual?.obturadorNs == 16_666_667, "o \"Passar para Manual\" sozinho parte do lido")
        conferir(X.aplicar(pedido("{\"exposicao\":\"manual\"}"), sobre: .padrao, lido: X.Lido(), evMin: -8, evMax: 8) == nil,
                 "Manual sem lido: nao_aplicado (nil)")
        var travado = AjustesDaCamera()
        travado.travaExposicao = true; travado.travaIso = 100; travado.travaObturadorNs = 1_000_000
        travado.ev = 1; travado.foco = .manual; travado.focoPosicao = 0.9
        let restaurado = X.aplicar(pedido("{\"ev\":0.7}", restaurar: true), sobre: travado, lido: lido, evMin: -2, evMax: 2)
        conferir(restaurado?.travaExposicao == false && restaurado?.foco == .auto && abs((restaurado?.ev ?? 0) - 2.0 / 3.0) < 1e-9,
                 "restaurar antes dos campos: o padrão, e o EV pedido arredondado a 1/3 (0,7 → 2/3)")
        let trava = X.aplicar(pedido("{\"travaExposicao\":true,\"travaBalanco\":true}"), sobre: .padrao, lido: lido,
                              evMin: -8, evMax: 8)
        conferir(trava?.travaIso == 320 && trava?.travaObturadorNs == 16_666_667 && trava?.travaGanhos == [2.0, 1.0, 1.6],
                 "as travas guardam o que a câmera estava usando")
        let kelvin = X.aplicar(pedido("{\"balanco\":\"kelvin\"}"), sobre: trava ?? .padrao, lido: lido, evMin: -8, evMax: 8)
        conferir(kelvin?.kelvin == 4900 && kelvin?.travaBalanco == false && kelvin?.travaGanhos == nil,
                 "passar a Kelvin parte do estimado (4870 → 4900) e tira a trava de balanço")
        let kelvinPedido = X.aplicar(pedido("{\"balanco\":\"kelvin\",\"kelvin\":3240}"), sobre: .padrao, lido: lido,
                                     evMin: -8, evMax: 8)
        conferir(kelvinPedido?.kelvin == 3200, "o Kelvin pedido junto vale, arredondado (3240 → 3200)")
        let focoManual = X.aplicar(pedido("{\"foco\":\"manual\"}"), sobre: .padrao, lido: lido, evMin: -8, evMax: 8)
        let focoComPos = X.aplicar(pedido("{\"foco\":\"manual\",\"focoPosicao\":0.123}"), sobre: .padrao, lido: lido,
                                   evMin: -8, evMax: 8)
        conferir(focoManual?.focoPosicao == 0.42 && focoComPos?.focoPosicao == 0.12,
                 "foco manual parte da posição lida; com a posição pedida, ela (0,123 → 0,12)")
        let anti = X.aplicar(pedido("{\"antiCintilacao\":\"60\"}"), sobre: .padrao, lido: lido, evMin: -8, evMax: 8)
        conferir(anti?.antiCintilacao == .hz60, "a anti-cintilação pedida fica no registro")
        let toque = X.Pedido.de(json: "{\"n\":9,\"autor\":\"\",\"ajuste\":{},\"restaurar\":false,\"toque\":{\"x\":0.25,\"y\":0.75,\"longo\":true}}")
        conferir(toque?.toque?.x == 0.25 && toque?.toque?.y == 0.75 && toque?.toque?.longo == true && toque?.n == 9,
                 "o toque do pedido")
        conferir(X.Pedido.de(json: "{\"n\":0}") == nil && X.Pedido.de(json: "lixo") == nil, "pedido sem n ou ilegível: nil")

        print("RegrasDoControleRemoto.camposMudados — o pedido parcial do receptor")
        var antes = AjustesDaCamera()
        antes.exposicao = .manual; antes.iso = 400; antes.obturadorNs = 16_666_667; antes.travaIso = 1
        var depois = antes
        depois.iso = 800
        let permitidos = X.camposPedidos(android)
        let mudou = X.camposMudados(de: antes, para: depois, pedidos: permitidos)
        conferir(mudou.count == 1 && (mudou["iso"] as? NSNumber)?.doubleValue == 800, "só o ISO mexido vai")
        var trocaTrava = antes
        trocaTrava.travaIso = 999
        conferir(X.camposMudados(de: antes, para: trocaTrava, pedidos: permitidos).isEmpty, "um campo de trava lida nunca vai")
        conferir(!permitidos.contains("toque") && permitidos.contains("iso"), "o toque é ação, não campo")
        conferir(X.iguais(NSNumber(value: 800), NSNumber(value: 800.0)) && X.iguais(nil, NSNull()) && !X.iguais("a", nil),
                 "800 e 800,0 são o mesmo; null e ausente também")

        print("RegrasDoControleRemoto.EstadoDoReceptor — o estado literal do §11.1")
        let estado = X.EstadoDoReceptor.de(json: """
        {"situacao":"pronto","capacidades":{"controles":{"iso":{"min":50,"max":3200,"inteiro":true}},"limites":{}},
         "ajuste":{"exposicao":"manual","iso":800.0,"obturadorNs":16666666,"kelvin":5200.0},"aplicado":{},"pendente":{"iso":800},
         "lido":{"iso":400,"obturadorNs":16666666,"kelvin":5150,"abertura":1.7,"divergentes":["iso"]},
         "autor":"Pixel do Pessoa Exemplo","versao":17,"recusa":{"motivo":"superado","campo":"iso","ha_ms":300},"contadores":{}}
        """)
        conferir(estado?.situacao == "pronto" && estado?.ajuste?.iso == 800 && estado?.ajuste?.kelvin == 5200
                 && estado?.ajuste?.obturadorNs == 16_666_666, "o ajuste com o pendente por cima (5200.0 vira 5200)")
        conferir(estado?.leitura.iso == 400 && estado?.leitura.abertura == 1.7 && estado?.divergentes == ["iso"]
                 && estado?.autor == "Pixel do Pessoa Exemplo" && estado?.recusa?.motivo == "superado",
                 "o lido, os divergentes, o autor e a recusa")
        if let e = estado, let a = e.ajuste {
            conferir(X.textoDaDivergencia(e.divergentes, lido: e.leitura, ajuste: a, molde: ma)
                     == "A câmera usou ISO 400 em vez de ISO 800.", "a divergência que o filmador anunciou")
        }
        let vazio = X.EstadoDoReceptor.de(json: "{\"situacao\":\"esperando\",\"capacidades\":null,\"ajuste\":null,\"lido\":null,\"recusa\":null}")
        conferir(vazio?.situacao == "esperando" && vazio?.capacidades == nil && vazio?.ajuste == nil, "antes de chegar: nulos")
        conferir(X.textoDaRecusa(motivo: "fora_da_faixa", campo: "iso") == "Este aparelho não aceitou ISO."
                 && X.textoDaRecusa(motivo: "superado", campo: "iso") == nil
                 && X.textoDaRecusa(motivo: "sem_resposta", campo: nil) == "O aparelho não respondeu."
                 && X.textoDaRecusa(motivo: "codigo_da_casca", campo: nil) == "O aparelho não conseguiu aplicar o ajuste.",
                 "as linhas das recusas (§3.5)")

        print("PontoNoQuadro — o toque no quadro decodificado, com .resizeAspect")
        let tela = (largura: 375.0, altura: 667.0)
        let deitado = (largura: 1280.0, altura: 720.0)
        let meio = PontoNoQuadro.de(toque: (187.5, 333.5), area: tela, video: deitado)
        conferir(meio.map { abs($0.x - 0.5) < 1e-9 && abs($0.y - 0.5) < 1e-9 } ?? false, "o centro é o centro")
        conferir(PontoNoQuadro.de(toque: (187.5, 100), area: tela, video: deitado) == nil,
                 "um toque na tarja de cima não é ponto do quadro")
        let canto = PontoNoQuadro.de(toque: (0, 333.5 - 105.46875), area: tela, video: deitado)
        conferir(canto.map { abs($0.x) < 1e-9 && abs($0.y) < 1e-6 } ?? false, "o canto de cima à esquerda da imagem é (0, 0)")
        let emPe = PontoNoQuadro.de(toque: (375, 333.5), area: tela, video: (720, 1280))
        conferir(emPe.map { $0.x == 1 && abs($0.y - 0.5) < 1e-3 } ?? false,
                 "o vídeo em pé numa tela em pé: a borda direita é x = 1")
    }

    /// As regras de forma do núcleo, reescritas aqui (o `rodar.sh` não liga o núcleo): cada descritor
    /// é `{"valores":[…]}` (1 a 32 textos de 1 a 32 bytes), `{"min","max"}` com min ≤ max (e limites
    /// inteiros com `"inteiro"`), ou `{}`; os códigos de `limites` são `[a-z0-9_]{1,32}`; o nome tem
    /// até 64 bytes; e o JSON cabe nos 2048 bytes.
    private static func problemasDeForma(_ caps: [String: Any]) -> [String] {
        var p: [String] = []
        guard let controles = caps["controles"] as? [String: Any] else { return ["sem controles"] }
        for (k, v) in controles {
            guard let d = v as? [String: Any] else { p.append("\(k): não é objeto"); continue }
            if let valores = d["valores"] {
                guard let lista = valores as? [String], !lista.isEmpty, lista.count <= 32,
                      lista.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }) else { p.append("\(k): valores"); continue }
            } else if d["min"] != nil || d["max"] != nil {
                guard let a = RegrasDoControleRemoto.numeroJSON(d["min"]), let b = RegrasDoControleRemoto.numeroJSON(d["max"]),
                      a <= b else { p.append("\(k): min/max"); continue }
                if let i = d["inteiro"] {
                    guard let inteiro = RegrasDoControleRemoto.booleanoJSON(i) else { p.append("\(k): inteiro"); continue }
                    if inteiro, a.rounded() != a || b.rounded() != b { p.append("\(k): limites com casas e inteiro") }
                }
            }
        }
        for (k, v) in caps["limites"] as? [String: Any] ?? [:] {
            guard let c = v as? String, !c.isEmpty, c.utf8.count <= 32,
                  c.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else {
                p.append("limite \(k)"); continue
            }
        }
        if let n = caps["nomeDaCamera"] as? String, n.utf8.count > 64 { p.append("nome") }
        if (CapacidadesRemotas.json(caps)?.utf8.count ?? 9999) > 2048 { p.append("passa de 2048 bytes") }
        return p
    }

    private static func jsonObjeto(_ texto: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(texto.utf8)) as? [String: Any]) ?? [:]
    }
}
