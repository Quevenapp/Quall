//! O painel de quem recebe, desenhado das capacidades de cada plataforma (R9b).

use super::*;
use crate::idioma::{com_idioma, Idioma};
use crate::modelo_dos_ajustes::{self as modelo, EstadoDosAjustes};
use crate::regras_dos_controles::{Capacidades, Faixa, Propriedade, FLAGS_AUTO, FLAGS_MANUAL};

/// As capacidades que um filmador Windows publica (a webcam de exemplo de `regras_dos_controles`).
fn capacidades_do_windows() -> Value {
    let f = |min, max, passo, padrao, b| Faixa::do_get_range(min, max, passo, padrao, b).unwrap();
    let mut c = Capacidades::new();
    c.insert(Propriedade::Exposicao, f(-11, -1, 1, -6, FLAGS_AUTO | FLAGS_MANUAL));
    c.insert(Propriedade::Ganho, f(0, 100, 1, 0, FLAGS_MANUAL));
    c.insert(Propriedade::Brilho, f(-64, 64, 1, 0, FLAGS_MANUAL));
    c.insert(Propriedade::Balanco, f(2800, 6500, 10, 4600, FLAGS_AUTO | FLAGS_MANUAL));
    c.insert(Propriedade::AntiCintilacao, f(0, 2, 1, 1, FLAGS_MANUAL));
    // Os ajustes de imagem (R9 §3.7).
    c.insert(Propriedade::Contraste, f(0, 10, 1, 7, FLAGS_MANUAL));
    c.insert(Propriedade::Saturacao, f(0, 100, 1, 64, FLAGS_MANUAL));
    c.insert(Propriedade::Gama, f(100, 500, 1, 300, FLAGS_MANUAL));
    c.insert(Propriedade::Nitidez, f(0, 7, 1, 0, FLAGS_MANUAL));
    c.insert(Propriedade::Contraluz, f(0, 1, 1, 0, FLAGS_MANUAL));
    crate::regras_da_camera_remota::capacidades(&c, 30.0, false)
}

/// Um Android com os ajustes de imagem do Quall e a contraluz em níveis (R9 §3.7).
fn capacidades_do_android_com_imagem() -> Value {
    let mut c = capacidades_do_android();
    for campo in CAMPOS_DE_IMAGEM {
        c["controles"][campo] = json!({"min": -100, "max": 100, "passo": 1, "origem": "quall"});
    }
    c["controles"][CONTRALUZ] = json!({"min": 0, "max": 3, "passo": 1, "origem": "camera"});
    c
}

fn ajuste_manual() -> Value {
    json!({"exposicao":"manual","ev":0,"travaExposicao":false,"iso":400,"obturadorNs":16666666,"antiCintilacao":"60",
           "balanco":"kelvin","kelvin":5200,"travaBalanco":false,"foco":"manual","focoPosicao":0.42})
}

fn todos_os_estados() -> Vec<(String, EstadoRemoto)> {
    let mut v = Vec::new();
    for (plataforma, caps) in [
        ("android", capacidades_do_android()),
        ("mac", capacidades_do_mac()),
        ("windows", capacidades_do_windows()),
        ("android-imagem", capacidades_do_android_com_imagem()),
    ] {
        for situacao in [PRONTO, NAO_PERMITIDO] {
            for (nome, ajuste) in [("auto", json!({})), ("manual", ajuste_manual()), ("travado", json!({"travaExposicao":true,"travaBalanco":true}))] {
                v.push((format!("{plataforma}-{situacao}-{nome}"), estado_de_exemplo(situacao, caps.clone(), ajuste.clone())));
                // "Travar fps" (R9 §3.1.1): a chave na aba Exposição e o aviso com o botão.
                if plataforma == "android" {
                    v.push((format!("{plataforma}-{situacao}-{nome}-trava"), com_trava_e_pouca_luz(estado_de_exemplo(situacao, caps.clone(), ajuste))));
                }
            }
        }
    }
    v
}

/// Um estado com `travarFps` nas capacidades e a pouca luz acesa no lido.
fn com_trava_e_pouca_luz(mut r: EstadoRemoto) -> EstadoRemoto {
    if let Some(Value::Object(c)) = r.capacidades.get_mut("controles") {
        c.insert("travarFps".into(), json!({}));
    }
    r.lido.insert("poucaLuz".into(), json!({"fpsChegando": 15, "piso": 15, "fps": 30}));
    r
}

fn textos(q: &QuadroDosAjustes) -> Vec<String> {
    q.itens.iter().filter_map(|i| if let Item::Texto(t) = i { Some(t.texto_corrido()) } else { None }).collect()
}

fn no_estado(r: &EstadoRemoto, aba: Aba) -> EstadoDosAjustes {
    EstadoDosAjustes { aba, remoto: Some(r.clone()), ..Default::default() }
}

#[test]
fn cada_aba_cabe_sem_rolar_e_nenhum_controle_cobre_outro() {
    for (nome, r) in todos_os_estados() {
        for aba in Aba::TODAS {
            let e = no_estado(&r, aba);
            let (l, a) = modelo::tamanho(&e);
            // Sem prévia e sem a faixa da opção; com o zoom de quem filma, a linha dele no alto (13/10).
            assert_eq!((l, a), (lugar::largura(false), lugar::ALTURA + lugar::desce(tem_zoom(&r))), "{nome}");
            let janela = Ret::new(0.0, 0.0, l, a);
            let q = modelo::compor(&e);
            assert!(q.previa.is_none());
            // O zoom de quem filma (R9 §3.8), fora das abas: em todas, acima da linha delas (13/10).
            if tem_zoom(&r) {
                let z = q.lugar(ControleDosAjustes::Zoom).unwrap_or_else(|| panic!("{nome}/{aba:?}: sem o zoom"));
                let aba0 = q.lugar(ControleDosAjustes::Aba(0)).unwrap();
                assert!(z.y + z.a <= aba0.y, "{nome}/{aba:?}: o zoom não está acima das abas");
            } else {
                assert!(q.lugar(ControleDosAjustes::Zoom).is_none(), "{nome}/{aba:?}");
            }
            assert!(q.lugar(ControleDosAjustes::PermitirRemoto).is_none(), "{nome}: a opção é de quem filma");
            for x in &q.controles {
                assert!(janela.contem(&x.ret), "{nome}/{aba:?}: {:?} fora da janela: {:?}", x.c, x.ret);
            }
            for (i, a_) in q.controles.iter().enumerate() {
                for b in q.controles.iter().skip(i + 1) {
                    assert!(!a_.ret.cruza(&b.ret), "{nome}/{aba:?}: {:?} cobre {:?}", a_.c, b.c);
                }
            }
            for item in &q.itens {
                if let Item::Texto(t) = item {
                    assert!(janela.contem(&t.ret), "{nome}/{aba:?}: texto fora: {:?}", t.texto_corrido());
                    for x in &q.controles {
                        assert!(!t.ret.cruza(&x.ret), "{nome}/{aba:?}: o texto {:?} fica debaixo de {:?}", t.texto_corrido(), x.c);
                    }
                }
            }
            // Os degraus de todo deslizante cabem no trackbar.
            for x in &q.controles {
                if let Some(d) = x.degraus {
                    assert!(d.max >= 0 && d.pos >= 0 && d.pos <= d.max, "{nome}/{aba:?}: {:?} {d:?}", x.c);
                }
            }
        }
    }
}

#[test]
fn o_android_desenha_tudo_o_que_anuncia() {
    use ControleDosAjustes as C;
    let r = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({"ev":0.3}));
    let q = compor(Aba::Exposicao, &r);
    assert!(q.achar(C::Brilho).unwrap().habilitado, "o EV com Auto");
    assert_eq!(q.achar(C::Brilho).unwrap().degraus.unwrap().max, 40, "de −2 a 2, de 0,1 em 0,1");
    assert!(textos(&q).contains(&"+0,3 EV".to_string()));
    assert!(textos(&q).contains(&"EV".to_string()));
    assert!((0..4).all(|i| q.achar(C::Cintilacao(i)).unwrap().habilitado));
    // A linha do alto (§3.6).
    assert!(textos(&q).contains(&"ISO 400 · 1/60 s · 5150 K · f/1,7".to_string()));
    // ISO em terços de stop, de 50 a 3200, e as frações de cinema até o teto.
    let r = estado_de_exemplo(PRONTO, capacidades_do_android(), ajuste_manual());
    let q = compor(Aba::GanhoEObturador, &r);
    assert_eq!(q.achar(C::Ganho).unwrap().degraus.unwrap().max, 18, "19 degraus de ISO");
    let n = r.numero("obturadorNs").unwrap();
    let d = degraus("obturadorNs", &n);
    assert_eq!(*d.last().unwrap(), 33333333.0, "o teto (1/30) entra");
    assert!(d.contains(&(1e9f64 / 60.0).round()) && d.contains(&125000.0));
    assert!(textos(&q).contains(&"1/60 s".to_string()));
    // Balanço: a grade inteira, Kelvin com o deslizante.
    let q = compor(Aba::Balanco, &r);
    assert!((0..6).all(|i| q.achar(C::Balanco(i)).unwrap().habilitado));
    assert!(textos(&q).contains(&"5200 K".to_string()));
    // Foco manual com Perto ↔ Longe.
    let q = compor(Aba::Foco, &r);
    assert!(textos(&q).contains(&"0,42".to_string()));
    assert_eq!(q.achar(C::FocoPosicao).unwrap().degraus, Some(Degraus { max: 100, pos: 42 }));
}

#[test]
fn o_windows_do_outro_lado_e_brilho_e_ganho() {
    use ControleDosAjustes as C;
    let r = estado_de_exemplo(PRONTO, capacidades_do_windows(), json!({"ev":12}));
    let q = compor(Aba::Exposicao, &r);
    // O brilho, com a origem (o padrão do driver) somada, e nunca "EV".
    assert!(textos(&q).contains(&"Brilho".to_string()) && textos(&q).contains(&"12".to_string()));
    assert!(!textos(&q).iter().any(|t| t.contains("EV")));
    assert!(textos(&q).iter().any(|t| t.starts_with("Ganho 400")), "{:?}", textos(&q));
    let e = no_estado(&r, Aba::GanhoEObturador);
    assert_eq!(modelo::texto_acessivel(C::Aba(1), &e), "Ganho e obturador, aba");
    // O obturador em 2^v: de 2^-11 ao teto que o filmador publica, destravado a 30 fps 1/16 s
    // (2^-4, 13/10), oito degraus.
    let r = estado_de_exemplo(PRONTO, capacidades_do_windows(), json!({"exposicao":"manual","iso":32,"obturadorNs":15625000}));
    let q = compor(Aba::GanhoEObturador, &r);
    assert_eq!(q.achar(C::Obturador).unwrap().degraus, Some(Degraus { max: 7, pos: 5 }));
    assert!(textos(&q).contains(&"1/64 s".to_string()));
    // O degrau mais rápido sai dentro da faixa publicada (a revisão do plano, achado 6).
    let Some(GestoRemoto::Pedido(p)) = gesto(C::Obturador, &r, Some(0)) else { panic!() };
    let ns = p["obturadorNs"].as_f64().unwrap();
    let n = r.numero("obturadorNs").unwrap();
    assert!(ns >= n.min && ns <= n.max, "{ns} fora de [{}, {}]", n.min, n.max);
    assert!(p["obturadorNs"].is_i64(), "inteiro, sem .0");
    // O balanço do Windows: só Auto e Kelvin, e a linha dos presets.
    let q = compor(Aba::Balanco, &r);
    assert!(q.achar(C::Balanco(0)).unwrap().habilitado && q.achar(C::Balanco(5)).unwrap().habilitado);
    assert!(!q.achar(C::Balanco(1)).unwrap().habilitado);
    assert!(textos(&q).contains(&"Este aparelho não oferece os presets de balanço.".to_string()));
    // Sem foco na webcam da bancada (§12).
    assert!(textos(&compor(Aba::Foco, &r)).contains(&"Esta câmera não oferece o foco manual.".to_string()));
}

/// **O brilho do Windows em qualquer exposição** (13/10, R9 §3.3): com a dica
/// `independenteDaExposicao` no descritor de `ev`, o deslizante responde em Manual e com a trava, sem
/// a linha "Destrave…"; sem ela (o EV do Android), a regra de sempre.
#[test]
fn o_brilho_com_a_dica_vale_em_qualquer_exposicao() {
    use ControleDosAjustes as C;
    let caps = capacidades_do_windows();
    assert_eq!(caps["controles"]["ev"]["independenteDaExposicao"], json!(true));
    for ajuste in [json!({"exposicao":"manual","iso":32,"obturadorNs":15625000}), json!({"travaExposicao":true}), json!({})] {
        let r = estado_de_exemplo(PRONTO, caps.clone(), ajuste.clone());
        assert!(r.ev_independente() && r.ev_livre(), "{ajuste}");
        let q = compor(Aba::Exposicao, &r);
        assert!(q.achar(C::Brilho).unwrap().habilitado, "{ajuste}");
        assert!(!textos(&q).contains(&"Destrave a exposição para compensar.".to_string()), "{ajuste}");
    }
    // O gesto pede o `ev` também em Manual (o núcleo aceita com a dica).
    let r = estado_de_exemplo(PRONTO, caps.clone(), json!({"exposicao":"manual","iso":32,"obturadorNs":15625000}));
    assert!(matches!(gesto(C::Brilho, &r, Some(70)), Some(GestoRemoto::Pedido(p)) if p.get("ev").is_some()));
    // Sem a dica (o Android, o Windows de antes): só Auto e destravado, com a linha.
    let travado = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({"travaExposicao":true}));
    assert!(!travado.ev_independente() && !travado.ev_livre());
    let q = compor(Aba::Exposicao, &travado);
    assert!(!q.achar(C::Brilho).unwrap().habilitado);
    assert!(textos(&q).contains(&"Destrave a exposição para compensar.".to_string()));
    let manual = estado_de_exemplo(PRONTO, capacidades_do_android(), ajuste_manual());
    assert!(!compor(Aba::Exposicao, &manual).achar(C::Brilho).unwrap().habilitado);
    let mut sem_dica = caps.clone();
    sem_dica["controles"]["ev"].as_object_mut().unwrap().remove("independenteDaExposicao");
    let r = estado_de_exemplo(PRONTO, sem_dica, json!({"exposicao":"manual","iso":32,"obturadorNs":15625000}));
    assert!(!compor(Aba::Exposicao, &r).achar(C::Brilho).unwrap().habilitado);
    // A dica que não é `true` não vale.
    let mut torta = caps;
    torta["controles"]["ev"]["independenteDaExposicao"] = json!("sim");
    assert!(!estado_de_exemplo(PRONTO, torta, json!({"travaExposicao":true})).ev_livre());
}

/// **O obturador além de 1/fps** (13/10, R9 §3.1): a escala de frações ganha 1/15 e 1/20 quando o
/// `max` do filmador passa de 1/fps (o Android destravado a 30 fps publica 1/15 s), e o próprio teto
/// entra quando não é fração da lista.
#[test]
fn as_fracoes_novas_ate_o_teto_destravado() {
    let n = |v: Value| match Descritor::de(&v) {
        Some(Descritor::Numero(n)) => n,
        _ => panic!(),
    };
    let d = degraus("obturadorNs", &n(json!({"min":100000,"max":66666667,"inteiro":true})));
    assert_eq!(*d.last().unwrap(), 66666667.0, "1/15 é o teto");
    assert!(d.contains(&50000000.0), "1/20");
    assert!(d.contains(&41666667.0) && d.contains(&33333333.0), "1/24 e 1/30");
    let travado = degraus("obturadorNs", &n(json!({"min":100000,"max":33333333,"inteiro":true})));
    assert!(!travado.contains(&50000000.0) && !travado.contains(&66666667.0), "travado: nada acima de 1/30");
    assert_eq!(texto_do_valor("obturadorNs", None, 66666667.0), "1/15 s");
    assert_eq!(texto_do_valor("obturadorNs", None, 50000000.0), "1/20 s");
    // A 60 fps destravado o teto é 1/30: 1/15 e 1/20 não cabem.
    let d60 = degraus("obturadorNs", &n(json!({"min":100000,"max":33333333,"inteiro":true})));
    assert_eq!(*d60.last().unwrap(), 33333333.0);
}

/// "Travar fps" vale em qualquer exposição (13/10): no manual, ele decide o teto do obturador.
#[test]
fn travar_fps_responde_tambem_no_manual() {
    use ControleDosAjustes as C;
    let mut caps = capacidades_do_windows();
    caps["controles"]["travarFps"] = json!({});
    let r = estado_de_exemplo(PRONTO, caps, json!({"exposicao":"manual","iso":32,"obturadorNs":15625000}));
    let q = compor(Aba::Exposicao, &r);
    let x = q.achar(C::TravarFps).expect("a chave");
    assert!(x.habilitado && !x.marcado);
    assert_eq!(gesto(C::TravarFps, &r, None), Some(GestoRemoto::Pedido(json!({"travarFps": true}))));
}

#[test]
fn o_mac_diz_quem_limita() {
    use ControleDosAjustes as C;
    let r = estado_de_exemplo(PRONTO, capacidades_do_mac(), json!({}));
    let q = compor(Aba::Exposicao, &r);
    assert!(textos(&q).contains(&"O macOS não oferece a compensação de exposição para câmeras.".to_string()));
    assert!(q.achar(C::TravarExposicao).unwrap().habilitado);
    assert!(!q.achar(C::Exposicao(1)).unwrap().habilitado);
    // Um grupo em que nada se aplica é uma linha só (R9 §3.5).
    let q = compor(Aba::GanhoEObturador, &r);
    assert_eq!(textos(&q).iter().filter(|t| t.contains("macOS")).count(), 1);
    assert!(textos(&q).contains(&"O macOS não oferece ISO e o obturador para câmeras.".to_string()));
    assert!(q.lugar(C::PassarParaManual).is_none());
    let q = compor(Aba::Balanco, &r);
    assert!(textos(&q).contains(&"O macOS não oferece o Kelvin para câmeras.".to_string()));
    assert!(q.achar(C::TravarBalanco).unwrap().habilitado);
    let q = compor(Aba::Foco, &r);
    assert!(q.achar(C::Foco(1)).unwrap().habilitado && !q.achar(C::Foco(2)).unwrap().habilitado);
    assert!(textos(&q).contains(&"O macOS não oferece o foco manual para câmeras.".to_string()));
}

#[test]
fn nao_permitido_apaga_com_os_valores() {
    use ControleDosAjustes as C;
    let r = estado_de_exemplo(NAO_PERMITIDO, capacidades_do_android(), ajuste_manual());
    for aba in Aba::TODAS {
        let q = compor(aba, &r);
        assert!(q.controles.iter().filter(|x| !matches!(x.c, C::Aba(_))).all(|x| !x.habilitado), "{aba:?}");
        assert!(textos(&q).contains(&"O aparelho não permite controle remoto da câmera".to_string()));
    }
    assert!(textos(&compor(Aba::Balanco, &r)).contains(&"5200 K".to_string()), "com os valores");
    com_idioma(Idioma::En, || {
        assert!(textos(&compor(Aba::Exposicao, &r)).contains(&"This device doesn't allow remote camera control".to_string()));
    });
}

#[test]
fn sem_controles_nas_outras_situacoes() {
    for (situacao, frase) in [("esperando", "Lendo a câmera…"), (SEM_RESPOSTA, "O aparelho não respondeu."), (SEM_CAMERA, "O aparelho não está mostrando uma câmera.")] {
        let r = estado_de_exemplo(situacao, capacidades_do_android(), json!({}));
        let q = compor(Aba::Exposicao, &r);
        assert!(q.controles.is_empty(), "{situacao}");
        assert!(textos(&q).contains(&frase.to_string()), "{situacao}");
    }
    // Pronto sem capacidades (ainda não chegaram): também sem controles.
    let r = EstadoRemoto::de_json(r#"{"situacao":"pronto","capacidades":null}"#);
    assert!(!r.com_controles());
    assert!(EstadoRemoto::de_json("lixo").situacao == "esperando");
}

#[test]
fn as_recusas_e_a_divergencia() {
    let mut r = estado_de_exemplo(PRONTO, capacidades_do_android(), ajuste_manual());
    r.recusa = Some(("fora_da_faixa".into(), Some("iso".into())));
    assert_eq!(aviso_do_alto(&r).as_deref(), Some("Este aparelho não aceitou ISO."));
    r.recusa = Some(("nao_aplicado".into(), None));
    assert_eq!(aviso_do_alto(&r).as_deref(), Some("O aparelho não conseguiu aplicar o ajuste."));
    r.recusa = Some(("um_codigo_novo".into(), None));
    assert_eq!(aviso_do_alto(&r).as_deref(), Some("O aparelho não conseguiu aplicar o ajuste."), "código desconhecido é nao_aplicado (§3.5)");
    r.recusa = Some(("sem_resposta".into(), None));
    assert_eq!(aviso_do_alto(&r).as_deref(), Some("O aparelho não respondeu."));
    r.recusa = Some(("superado".into(), Some("iso".into())));
    assert_eq!(aviso_do_alto(&r), None, "superado não se mostra");
    r.recusa = None;
    r.lido.insert("divergentes".into(), json!(["iso"]));
    r.ajuste.insert("iso".into(), json!(800));
    assert_eq!(aviso_do_alto(&r).as_deref(), Some("A câmera usou 400 em vez de 800."));
    com_idioma(Idioma::En, || {
        let mut r = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({}));
        r.recusa = Some(("incoerente".into(), Some("ev".into())));
        assert_eq!(aviso_do_alto(&r).as_deref(), Some("This device didn't accept exposure compensation."));
        assert_eq!(rotulo_da_aba(&r, Aba::GanhoEObturador), "ISO e obturador");
        assert_eq!(crate::idioma::t(rotulo_da_aba(&r, Aba::GanhoEObturador)), "ISO & shutter");
    });
}

#[test]
fn os_gestos_viram_pedidos_parciais() {
    use ControleDosAjustes as C;
    let r = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({"travaExposicao":true}));
    let p = |c, d| match gesto(c, &r, d) {
        Some(GestoRemoto::Pedido(v)) => v,
        outro => panic!("{c:?}: {outro:?}"),
    };
    assert_eq!(p(C::Exposicao(1), None), json!({"exposicao":"manual"}));
    assert_eq!(p(C::PassarParaManual, None), json!({"exposicao":"manual"}), "só o modo: a casca parte do lido");
    assert_eq!(p(C::Exposicao(0), None), json!({"exposicao":"auto"}));
    assert_eq!(p(C::TravarExposicao, None), json!({"travaExposicao":false}));
    assert_eq!(p(C::Cintilacao(2), None), json!({"antiCintilacao":"60"}));
    assert_eq!(p(C::Balanco(3), None), json!({"balanco":"luzDoDia"}));
    assert_eq!(p(C::Foco(1), None), json!({"foco":"travado"}));
    assert_eq!(p(C::Brilho, Some(23)), json!({"ev":0.3}));
    assert_eq!(p(C::Ganho, Some(0)), json!({"iso":50}));
    assert_eq!(p(C::Ganho, Some(999)), json!({"iso":3200}), "o degrau além do fim é o último");
    assert_eq!(p(C::Kelvin, Some(32)), json!({"kelvin":5200}));
    assert_eq!(p(C::FocoPosicao, Some(42)), json!({"focoPosicao":0.42}));
    assert_eq!(gesto(C::Restaurar, &r, None), Some(GestoRemoto::Restaurar));
    assert_eq!(gesto(C::Aba(3), &r, None), Some(GestoRemoto::Aba(Aba::Foco)));
    assert_eq!(gesto(C::PermitirRemoto, &r, None), None);
    // Pelo modelo da janela: o mesmo gesto.
    let e = no_estado(&r, Aba::Exposicao);
    assert!(matches!(modelo::gesto(C::Exposicao(1), &e, None), Some(modelo::Gesto::Remoto(GestoRemoto::Pedido(_)))));
    assert!(matches!(modelo::gesto(C::Aba(2), &e, None), Some(modelo::Gesto::Aba(Aba::Balanco))));
}

#[test]
fn os_textos_de_valor() {
    let n = |v: Value| match Descritor::de(&v) {
        Some(Descritor::Numero(n)) => n,
        _ => panic!(),
    };
    let ev = n(json!({"min":-2,"max":2,"passo":0.1}));
    assert_eq!(texto_do_valor("ev", Some(&ev), 0.0), "0 EV");
    assert_eq!(texto_do_valor("ev", Some(&ev), -0.7), "-0,7 EV");
    assert_eq!(texto_do_valor("ev", Some(&n(json!({"min":-2,"max":2,"passo":0.5}))), 1.5), "+1,5 EV");
    let brilho = n(json!({"min":-128,"max":127,"inteiro":true,"unidade":"brilho","origem":128}));
    assert_eq!(texto_do_valor("ev", Some(&brilho), -28.0), "100");
    assert_eq!(texto_do_obturador_ns(1e9 / 250.0, false), "1/250 s");
    assert_eq!(texto_do_obturador_ns(2e9, false), "2 s");
    assert_eq!(texto_do_obturador_ns(1e9 / 128.0, true), "1/128 s");
    com_idioma(Idioma::En, || assert_eq!(texto_do_valor("ev", Some(&ev), 0.3), "+0.3 EV"));
    // O foco calibrado do Android: metros, e o infinito na posição 0.
    let foco = n(json!({"min":0,"max":1,"passo":0.01,"calibrado":10.0}));
    assert_eq!(foco.calibrado, Some(10.0));
    assert_eq!(texto_do_valor("focoPosicao", Some(&foco), 0.0), "∞");
    assert_eq!(texto_do_valor("focoPosicao", Some(&foco), 0.5), "0,20 m");
    assert_eq!(texto_do_valor("focoPosicao", Some(&foco), 0.005), "20,0 m");
    assert_eq!(texto_do_valor("focoPosicao", Some(&n(json!({"min":0,"max":1}))), 0.42), "0,42");
    // O ganho do Windows anda pelo passo do driver.
    let g = n(json!({"min":0,"max":100,"passo":5,"inteiro":true,"unidade":"ganho"}));
    assert_eq!(degraus("iso", &g).len(), 21);
    // Um descritor sem passo nem inteiro: cem degraus.
    assert_eq!(degraus("focoPosicao", &n(json!({"min":0,"max":1}))).len(), 101);
    // Faixas enormes são amostradas, e o último é o máximo.
    let grande = n(json!({"min":0,"max":1000000,"inteiro":true}));
    let d = degraus("iso", &n(json!({"min":0,"max":1000000,"inteiro":true,"unidade":"ganho"})));
    assert!(d.len() <= 1001 && *d.last().unwrap() == 1_000_000.0, "{}", d.len());
    assert!(degraus("kelvin", &grande).len() <= 1001);
}

#[test]
fn travar_fps_e_a_pouca_luz_do_filmador() {
    use ControleDosAjustes as C;
    let r = com_trava_e_pouca_luz(estado_de_exemplo(PRONTO, capacidades_do_android(), json!({})));
    // Destravado: a frase do que aconteceu, e o botão "Travar em 30 fps".
    assert_eq!(aviso_do_alto(&r).as_deref(), Some("Pouca luz: a câmera baixou para 15 fps para clarear a imagem."));
    assert_eq!(botao_da_pouca_luz(&r).as_deref(), Some("Travar em 30 fps"));
    let q = modelo::compor(&no_estado(&r, Aba::Exposicao));
    assert!(q.achar(C::AcaoDaPoucaLuz).is_some_and(|b| b.habilitado));
    assert!(q.achar(C::TravarFps).is_some_and(|x| x.habilitado && !x.marcado));
    assert_eq!(gesto(C::AcaoDaPoucaLuz, &r, None), Some(GestoRemoto::Pedido(json!({"travarFps": true}))));
    assert_eq!(gesto(C::TravarFps, &r, None), Some(GestoRemoto::Pedido(json!({"travarFps": true}))));
    // Travado: "imagem escura a 30 fps" e "Clarear (até 15 fps)", que destrava.
    let mut t = r.clone();
    t.ajuste.insert("travarFps".into(), json!(true));
    t.lido.insert("poucaLuz".into(), json!({"fpsChegando": 30, "piso": 15, "fps": 30}));
    assert_eq!(aviso_do_alto(&t).as_deref(), Some("Pouca luz: imagem escura a 30 fps."));
    assert_eq!(botao_da_pouca_luz(&t).as_deref(), Some("Clarear (até 15 fps)"));
    assert_eq!(gesto(C::AcaoDaPoucaLuz, &t, None), Some(GestoRemoto::Pedido(json!({"travarFps": false}))));
    assert!(modelo::compor(&no_estado(&t, Aba::Exposicao)).achar(C::TravarFps).unwrap().marcado);
    // Sem o `fps` (opcional): "Travar fps".
    let mut sem_fps = r.clone();
    sem_fps.lido.insert("poucaLuz".into(), json!({"fpsChegando": 15, "piso": 15}));
    assert_eq!(botao_da_pouca_luz(&sem_fps).as_deref(), Some("Travar fps"));
    // Em Manual, apagada; sem a chave nas capacidades, a frase sem botão; não permitido, nada.
    let mut manual = r.clone();
    manual.ajuste.insert("exposicao".into(), json!("manual"));
    assert!(pouca_luz(&manual).is_none() && botao_da_pouca_luz(&manual).is_none());
    let mut sem_chave = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({}));
    sem_chave.lido.insert("poucaLuz".into(), json!({"fpsChegando": 15, "piso": 15, "fps": 30}));
    assert!(aviso_do_alto(&sem_chave).is_some() && botao_da_pouca_luz(&sem_chave).is_none());
    assert!(modelo::compor(&no_estado(&sem_chave, Aba::Exposicao)).lugar(C::TravarFps).is_none());
    let mut np = r.clone();
    np.situacao = NAO_PERMITIDO.into();
    assert!(botao_da_pouca_luz(&np).is_none());
    // A divergência vem antes da pouca luz.
    let mut div = r.clone();
    div.lido.insert("divergentes".into(), json!(["iso"]));
    div.ajuste.insert("iso".into(), json!(800));
    assert!(aviso_do_alto(&div).unwrap().starts_with("A câmera usou") && botao_da_pouca_luz(&div).is_none());
    com_idioma(Idioma::En, || {
        assert_eq!(aviso_do_alto(&t).as_deref(), Some("Low light: dark image at 30 fps."));
        assert_eq!(botao_da_pouca_luz(&t).as_deref(), Some("Brighten (down to 15 fps)"));
        assert_eq!(botao_da_pouca_luz(&r).as_deref(), Some("Lock at 30 fps"));
    });
}

/// **A aba "Imagem"** (R9 §3.7): só com o filmador que oferece, só o que ele oferece, e os gestos
/// pedem só o campo mexido, em qualquer exposição.
#[test]
fn a_imagem_do_outro_lado() {
    use ControleDosAjustes as C;
    // O Android de antes (sem imagem): a aba não aparece.
    let sem = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({}));
    assert!(!sem.tem_imagem());
    assert!(modelo::compor(&no_estado(&sem, Aba::Exposicao)).lugar(C::Aba(4)).is_none());
    // O Windows: os quatro deslizantes (a nitidez de 0 a 100) e a chave da contraluz.
    let w = estado_de_exemplo(PRONTO, capacidades_do_windows(), json!({"exposicao": "manual", "iso": 10, "obturadorNs": 7812500, "contraste": 25}));
    let e = no_estado(&w, Aba::Imagem);
    let q = modelo::compor(&e);
    assert!(q.lugar(C::Aba(4)).is_some());
    for i in 0..4 {
        assert!(q.achar(C::Imagem(i)).is_some_and(|x| x.habilitado), "Imagem({i}) viva em Manual");
    }
    assert!(q.achar(C::Contraluz).is_some() && q.lugar(C::ContraluzNivel).is_none());
    assert!(textos(&q).contains(&"+25".to_string()), "{:?}", textos(&q));
    assert!(textos(&q).contains(&"Contraste".to_string()));
    let d = q.achar(C::Imagem(3)).unwrap().degraus.unwrap();
    assert_eq!((d.max, d.pos), (100, 0), "a nitidez do Windows vai de 0 a 100");
    assert_eq!(gesto(C::Imagem(1), &w, Some(150)), Some(GestoRemoto::Pedido(json!({"contraste": 50}))));
    assert_eq!(gesto(C::Imagem(0), &w, Some(0)), Some(GestoRemoto::Pedido(json!({"gama": -100}))));
    assert_eq!(gesto(C::Contraluz, &w, None), Some(GestoRemoto::Pedido(json!({"contraluz": true}))));
    // Com a contraluz lida ligada (o registro sem ela: o padrão da câmera), a chave mostra ligada e
    // o gesto desliga.
    let mut lida = w.clone();
    lida.lido.insert(CONTRALUZ.into(), json!(true));
    assert!(modelo::compor(&no_estado(&lida, Aba::Imagem)).achar(C::Contraluz).unwrap().marcado);
    assert_eq!(gesto(C::Contraluz, &lida, None), Some(GestoRemoto::Pedido(json!({"contraluz": false}))));
    // O Android com a imagem do Quall e a contraluz em níveis: o deslizante da contraluz.
    let a = estado_de_exemplo(PRONTO, capacidades_do_android_com_imagem(), json!({"contraluz": 2}));
    let q = modelo::compor(&no_estado(&a, Aba::Imagem));
    let n = q.achar(C::ContraluzNivel).expect("os níveis");
    assert_eq!(n.degraus, Some(Degraus { max: 3, pos: 2 }));
    assert_eq!(gesto(C::ContraluzNivel, &a, Some(1)), Some(GestoRemoto::Pedido(json!({"contraluz": 1}))));
    assert_eq!(valor_acessivel(C::Imagem(2), &a).as_deref(), Some("0"), "o ausente é o 0");
    // Apagada sem a permissão, com os valores.
    let np = estado_de_exemplo(NAO_PERMITIDO, capacidades_do_windows(), json!({"saturacao": -30}));
    let q = modelo::compor(&no_estado(&np, Aba::Imagem));
    assert!(!q.achar(C::Imagem(2)).unwrap().habilitado && textos(&q).contains(&"-30".to_string()));
    com_idioma(Idioma::En, || {
        let q = modelo::compor(&no_estado(&w, Aba::Imagem));
        assert!(textos(&q).contains(&"Contrast".to_string()) && textos(&q).contains(&"Sharpness".to_string()));
        assert_eq!(modelo::rotulo(C::Aba(4), &no_estado(&w, Aba::Imagem)), "Picture");
        assert_eq!(modelo::rotulo(C::Contraluz, &no_estado(&w, Aba::Imagem)), "Backlight compensation");
    });
}

/// **O zoom do outro lado** (R9 §3.8): o deslizante no alto da aba Foco, só com o descritor, em escala
/// logarítmica; o gesto pede só o `zoom`, e o ausente é o 1×.
#[test]
fn o_zoom_do_outro_lado() {
    use ControleDosAjustes as C;
    let a = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({"zoom": 3}));
    let q = compor(Aba::Foco, &a);
    let z = q.achar(C::Zoom).expect("o zoom na aba Foco");
    assert!(z.habilitado);
    let d = z.degraus.unwrap();
    assert_eq!(d.max, regras::DEGRAUS_DO_ZOOM);
    com_idioma(Idioma::Pt, || assert_eq!(valor_acessivel(C::Zoom, &a).as_deref(), Some("3×")));
    assert!(q.lugar(C::Zoom).unwrap().y < q.lugar(C::Foco(0)).unwrap().y, "no alto da aba");
    assert_eq!(gesto(C::Zoom, &a, Some(d.max)), Some(GestoRemoto::Pedido(json!({"zoom": 100}))));
    assert_eq!(gesto(C::Zoom, &a, Some(0)), Some(GestoRemoto::Pedido(json!({"zoom": 0.6}))));
    // O ausente é o 1×.
    let b = estado_de_exemplo(PRONTO, capacidades_do_android(), json!({}));
    com_idioma(Idioma::Pt, || assert_eq!(valor_acessivel(C::Zoom, &b).as_deref(), Some("1×")));
    // O Mac não declara: sem o deslizante.
    assert!(compor(Aba::Foco, &estado_de_exemplo(PRONTO, capacidades_do_mac(), json!({}))).achar(C::Zoom).is_none());
}

/// **O zoom do Quall de quem filma** (R9 §3.8.7, 14/10: o Windows sem zoom na câmera; o Mac, §3.8.4): a
/// mesma linha, com o rótulo do recorte, e o deslizante de 1× ao teto.
#[test]
fn o_zoom_do_quall_do_outro_lado_diz_que_e_recorte() {
    use ControleDosAjustes as C;
    let f = |min, max, passo, padrao, b| Faixa::do_get_range(min, max, passo, padrao, b).unwrap();
    let mut c = Capacidades::new();
    c.insert(Propriedade::Brilho, f(-64, 64, 1, 0, FLAGS_MANUAL));
    crate::zoom_do_quall::decidir(&mut c, Some(3.0));
    let a = estado_de_exemplo(PRONTO, crate::regras_da_camera_remota::capacidades(&c, 30.0, false), json!({"zoom": 2}));
    assert!(zoom_do_quall(&a) && tem_zoom(&a));
    com_idioma(Idioma::Pt, || {
        let q = compor(Aba::Exposicao, &a);
        assert!(textos(&q).contains(&"Zoom (recorte do Quall)".to_string()), "{:?}", textos(&q));
        assert_eq!(modelo::rotulo(C::Zoom, &no_estado(&a, Aba::Exposicao)), "Zoom (recorte do Quall)");
    });
    com_idioma(Idioma::En, || assert!(textos(&compor(Aba::Exposicao, &a)).contains(&"Zoom (Quall crop)".to_string())));
    let d = compor(Aba::Exposicao, &a).achar(C::Zoom).unwrap().degraus.unwrap();
    assert_eq!(gesto(C::Zoom, &a, Some(d.max)), Some(GestoRemoto::Pedido(json!({"zoom": 3}))));
    // O zoom da câmera (o Android) fica com o rótulo de sempre.
    assert!(!zoom_do_quall(&estado_de_exemplo(PRONTO, capacidades_do_android(), json!({}))));
}

/// O descritor exato de um Mac de 14/10 (`CameraRemotaNoFilmador.jsonRemoto`): as travas, o ponto,
/// "Travar fps", a imagem do Quall e o zoom do recorte (`ZoomDoQuall.descritor`); o resto em `limites`.
fn capacidades_do_mac_de_14_10() -> Value {
    let q = json!({"min": -100, "max": 100, "passo": 1, "origem": "quall"});
    json!({"plataforma":"macos","nomeDaCamera":"Câmera FaceTime HD", // i18n: fora (o nome no fio)
      "controles":{"travaExposicao":{},"travaBalanco":{},"foco":{"valores":["auto","travado"]},"toque":{},
        "travarFps":{"fps":30,"piso":15},
        "gama":q,"contraste":q,"saturacao":q,"nitidez":q,"contraluz":q,
        "zoom":{"min":1,"max":3,"passo":0.1,"paradas":[1,2,3],"opticas":[1],"origem":"quall"}}, // i18n: fora (o nome no fio)
      "limites":{"ev":"macos","iso":"macos","obturadorNs":"macos","kelvin":"macos","antiCintilacao":"macos","focoPosicao":"macos"}})
}

/// **A janela remota nunca fica só com o fundo** (14/10, o Dell recebendo o Mac: a janela abria preta e
/// continuava preta, em `nao_permitido` e em `pronto`). Em cada estado: o quadro tem o fundo da janela
/// inteira, a frase certa, e a altura é positiva e cabe na tela de 1080p a 150 % (720 DIP, menos a
/// barra de tarefas e o título); e a primeira volta do relógio aplica mesmo com o estado igual ao
/// lido ao abrir (`precisa_aplicar`).
#[test]
fn a_janela_remota_desenha_em_todos_os_estados() {
    use ControleDosAjustes as C;
    let mac = capacidades_do_mac_de_14_10();
    let com_lido = |situacao: &str, caps: Value, lido: Value| {
        EstadoRemoto::de_json(&json!({"situacao": situacao, "capacidades": caps, "ajuste": {}, "lido": lido}).to_string())
    };
    let recusado = EstadoRemoto::de_json(
        &json!({"situacao": PRONTO, "capacidades": capacidades_do_android(), "ajuste": {}, "lido": {},
                "recusa": {"motivo": "fora_da_faixa", "campo": "iso", "ha_ms": 200}})
        .to_string(),
    );
    let casos: Vec<(&str, EstadoRemoto, Option<&str>, bool)> = vec![
        ("esperando", EstadoRemoto::de_json(r#"{"situacao":"esperando","capacidades":null}"#), Some("Lendo a câmera…"), false),
        ("desconectado (ilegível)", EstadoRemoto::de_json(""), Some("Lendo a câmera…"), false),
        ("sem_resposta", estado_de_exemplo(SEM_RESPOSTA, capacidades_do_android(), json!({})), Some("O aparelho não respondeu."), false),
        ("sem_camera", estado_de_exemplo(SEM_CAMERA, capacidades_do_android(), json!({})), Some("O aparelho não está mostrando uma câmera."), false),
        ("pronto, o Mac com o zoom do Quall", com_lido(PRONTO, mac.clone(), json!({})), None, true),
        ("pronto, um Mac sem zoom", com_lido(PRONTO, capacidades_do_mac(), json!({})), None, true),
        ("pronto, o S24 com zoom", estado_de_exemplo(PRONTO, capacidades_do_android(), json!({})), None, true),
        ("nao_permitido, o Mac", com_lido(NAO_PERMITIDO, mac.clone(), json!({})), Some(FRASE_NAO_PERMITE), true),
        ("nao_permitido, sem capacidades", EstadoRemoto::de_json(r#"{"situacao":"nao_permitido","capacidades":null}"#), Some(FRASE_NAO_PERMITE), false),
        ("recusado", recusado, Some("Este aparelho não aceitou ISO."), true),
    ];
    for (nome, r, frase, com_controles) in casos {
        com_idioma(Idioma::Pt, || {
            let e = no_estado(&r, Aba::Exposicao);
            let (l, a) = modelo::tamanho(&e);
            assert!(l > 0.0 && a > 0.0, "{nome}: {l} × {a}");
            assert!(a <= 720.0 - 48.0 - 32.0, "{nome}: a altura {a} não cabe na tela");
            assert!(l <= 1280.0, "{nome}: a largura {l}");
            for aba in Aba::TODAS {
                let q = modelo::compor(&no_estado(&r, aba));
                assert!(!q.itens.is_empty(), "{nome} {aba:?}: nada a pintar");
                match q.itens.first() {
                    Some(Item::Caixa { ret, fundo, .. }) => {
                        assert_eq!((ret.x, ret.y, ret.l, ret.a), (0.0, 0.0, l, a), "{nome} {aba:?}: o fundo cobre a janela");
                        assert_eq!(*fundo, FUNDO, "{nome}: o fundo do tema");
                    }
                    outro => panic!("{nome} {aba:?}: o primeiro item não é o fundo: {outro:?}"),
                }
                if let Some(f) = frase {
                    assert!(textos(&q).iter().any(|t| t == f), "{nome} {aba:?}: sem a frase {f:?}: {:?}", textos(&q));
                }
                assert_eq!(!q.controles.is_empty(), com_controles, "{nome} {aba:?}: os controles");
                for c in &q.controles {
                    assert!(c.ret.y >= 0.0 && c.ret.y + c.ret.a <= a + 0.5, "{nome} {aba:?}: {:?} fora da janela", c.c);
                }
            }
            // A primeira volta aplica com o estado igual ao lido ao abrir; as seguintes, só com mudança.
            assert!(precisa_aplicar(Some(&r), &r, true), "{nome}: a primeira volta");
            assert!(!precisa_aplicar(Some(&r), &r, false), "{nome}: estado igual não redesenha");
        });
    }
    // O Mac: o zoom do recorte acima das abas, e a imagem do Quall com a aba "Imagem".
    let pronto = com_lido(PRONTO, mac.clone(), json!({}));
    let q = compor(Aba::Exposicao, &pronto);
    assert!(q.achar(C::Zoom).is_some_and(|z| z.habilitado));
    assert!(q.achar(C::Aba(Aba::Imagem.indice())).is_some(), "a aba Imagem do Mac");
    com_idioma(Idioma::Pt, || assert!(textos(&compor(Aba::Exposicao, &pronto)).contains(&"Zoom (recorte do Quall)".to_string())));
    // **O descritor que chega depois da janela aberta**: de `esperando` a `pronto` aplica, e a janela
    // cresce a linha do zoom.
    let antes = EstadoRemoto::de_json(r#"{"situacao":"esperando","capacidades":null}"#);
    assert!(precisa_aplicar(Some(&antes), &pronto, false));
    let (_, a0) = modelo::tamanho(&no_estado(&antes, Aba::Exposicao));
    let (_, a1) = modelo::tamanho(&no_estado(&pronto, Aba::Exposicao));
    assert_eq!(a1 - a0, lugar::ZOOM_A);
    // E o `nao_permitido` → `pronto` (o Bruno liga a opção no Mac) aplica e acende os controles.
    let negado = com_lido(NAO_PERMITIDO, mac, json!({}));
    assert!(precisa_aplicar(Some(&negado), &pronto, false));
    assert!(!compor(Aba::Exposicao, &negado).achar(C::Zoom).unwrap().habilitado);
}
