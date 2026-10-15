//! **O controle remoto da câmera, do lado de quem filma: a parte que é aritmética** (R9b,
//! `docs/controle-remoto-da-camera.md` §3.2, §6 e §12).
//!
//! Aqui não há Win32 nem núcleo, no molde de `regras_dos_controles.rs`: entram as faixas que a
//! câmera declarou, o registro e o lido; saem as **capacidades** que o filmador publica, o **pedido**
//! de um receptor traduzido em gestos do R9 ([`Acao`]) na ordem do contrato, o registro em JSON e o
//! **lido** em JSON. Quem fala com o `quall_core::camera_remota::Filmador` é `camera_remota.rs`, e
//! quem aplica é a thread dos ajustes (`ajustes_da_camera.rs`), que é a fila serial do dono da
//! câmera (§6, achado B1).
//!
//! # O que o Windows publica (§3.2, achado I7)
//!
//! | campo | descritor | por quê |
//! |---|---|---|
//! | `ev` | o **brilho** como deslocamento do padrão, `"unidade":"brilho"`, `"origem"` = o padrão, `"independenteDaExposicao":true` | é o que o registro guarda (`regras_dos_controles.rs`, cabeçalho); o brilho vale em qualquer exposição (13/10, R9 §3.3) |
//! | `iso` | o **ganho** do driver, `"unidade":"ganho"`, inteiro | idem |
//! | `obturadorNs` | de `2^min` ao teto **efetivo** do manual, `"escala":"log2"`, inteiro | o driver anda em potências de 2; o teto segue "Travar fps" (R9 §3.1, 13/10: o piso do automático destravado, 1/fps travado) |
//! | `kelvin` | a escala da tela (2000–10000 de 100 em 100, dentro da faixa do driver) | `faixa_do_kelvin` |
//! | `foco` / `focoPosicao` | só com `CameraControl_Focus`; sem ele, `camera_nao_oferece` | §12 |
//! | `toque` | nunca: `camera_nao_oferece` | as câmeras da bancada não têm ponto de interesse |
//! | `gama`, `contraste`, `saturacao`, `nitidez` | de -100 a 100 (menos o lado que o padrão do driver não deixa), `"origem":"camera"`; só os que o driver declara | R9 §3.7: o 0 é o padrão do driver |
//! | `contraluz` | `{"origem":"camera"}` (dois valores) ou os níveis do driver de 0 para cima; só se declarada | idem |
//! | `zoom` | o fator (1× = o padrão do driver), `{"min","max","passo":0.1,"paradas","origem":"camera"}`, sem `opticas`; só com `CameraControl_Zoom` | R9 §3.8 |
//! | `zoom` do Quall | sem `CameraControl_Zoom`: o recorte central, `{"min":1,"max":3,"passo":0.1,"paradas":[1,2,3],"opticas":[1],"origem":"quall"}` (o teto pela altura da imagem) | R9 §3.8.7 |
//!
//! **`Modo::Compartilhada`** (outro app abriu a câmera antes): `controles` vazio e todos os campos
//! em `limites` com `outro_app`. Os controles locais estão apagados por decisão do Bruno, e o
//! remoto recusa igual.

use serde_json::{json, Map, Value};

use crate::regras_dos_controles::{
    self as regras, faixa_do_kelvin, faixa_do_obturador, log2_dos_ns, ns_do_log2, Acao, AntiCintilacao, Balanco, Capacidades, Contraluz, Foco,
    Lidos, ModoDeExposicao, PoucaLuz, Propriedade, Registro,
};

/// Os campos (e a ação `toque`) que o contrato conhece, na ordem em que vão nas capacidades.
pub const CAMPOS: [&str; 13] = [
    "exposicao", "ev", "travaExposicao", "antiCintilacao", "iso", "obturadorNs", "balanco", "kelvin", "travaBalanco", "foco", "focoPosicao", "toque", // i18n: fora (o nome no fio)
    "travarFps", // i18n: fora (o nome no fio)
];

/// Os códigos de "quem limita" que o Windows usa (§3.2).
pub const CAMERA_NAO_OFERECE: &str = "camera_nao_oferece";
pub const OUTRO_APP: &str = "outro_app";
/// O motivo de recusa do contrato quando a casca não consegue aplicar (§3.5).
pub const NAO_APLICADO: &str = "nao_aplicado";

/// O nome do campo do ajuste que cada propriedade do driver alimenta (para o `lido` e os
/// `divergentes`).
pub fn campo_da_propriedade(p: Propriedade) -> &'static str {
    match p {
        Propriedade::Exposicao => "obturadorNs",
        Propriedade::Ganho => "iso",
        Propriedade::Brilho => "ev",
        Propriedade::Balanco => "kelvin",
        Propriedade::Foco => "focoPosicao",
        Propriedade::AntiCintilacao => "antiCintilacao",
        Propriedade::Zoom => "zoom",
        p => p.campo_de_imagem().unwrap_or("contraluz"),
    }
}

fn valores(v: &[&str]) -> Value {
    json!({ "valores": v })
}

/// A dica do descritor de `ev` que solta o brilho da exposição (13/10, R9 §3.3): o mesmo texto de
/// `quall_core::camera_remota::DICA_DO_EV_INDEPENDENTE` (este módulo não depende do núcleo; um teste
/// com o núcleo confere).
pub const DICA_DO_EV_INDEPENDENTE: &str = "independenteDaExposicao"; // i18n: fora (o nome no fio)

/// **As capacidades que o filmador publica** (§3.2), do mesmo mapa de faixas que monta o painel do
/// R9. `fps` é o do tipo nativo (o teto do obturador, R9 §3.1), destravado.
pub fn capacidades(caps: &Capacidades, fps: f64, compartilhada: bool) -> Value {
    capacidades_com_trava(caps, fps, compartilhada, false, false)
}

/// [`capacidades`] com o **"Travar fps"** (R9 §3.1.1): `"travarFps":{}` quando o driver declara a
/// prioridade da exposição (`regras::prioridade_oferecida`); sem ela, `camera_nao_oferece`, e o
/// controlador não mostra a chave nem o botão do aviso. `travar_fps` é o do registro: o `max` do
/// `obturadorNs` é o teto **efetivo** do manual (`regras::teto_do_obturador_manual`, 13/10), e a
/// thread dos ajustes republica as capacidades quando ele muda.
pub fn capacidades_com_trava(caps: &Capacidades, fps: f64, compartilhada: bool, trava_de_fps: bool, travar_fps: bool) -> Value {
    let mut controles = Map::new();
    let mut limites = Map::new();
    if compartilhada {
        for c in CAMPOS {
            limites.insert(c.into(), Value::from(OUTRO_APP));
        }
        return json!({ "plataforma": "windows", "controles": controles, "limites": limites });
    }
    let mut falta = |campo: &str| {
        limites.insert(campo.into(), Value::from(CAMERA_NAO_OFERECE));
    };
    // A exposição manual (o obturador) é a porta do ganho e da trava: sem ela, a tela local também
    // não chega a eles (`modelo_dos_ajustes.rs`, as abas).
    // Um driver que declarasse a exposição numa unidade linear (e não em log2 de segundos) daria
    // durações absurdas: fora da janela plausível, o obturador não é oferecido (a revisão, achado 6).
    let exposicao = caps
        .get(&Propriedade::Exposicao)
        .filter(|f| f.tem_manual() && f.min >= LOG2_MINIMO && f.max <= LOG2_MAXIMO)
        .copied();
    match exposicao {
        Some(f) => {
            controles.insert("exposicao".into(), valores(&["auto", "manual"]));
            controles.insert("travaExposicao".into(), json!({}));
            let teto = faixa_do_obturador(&f, fps, travar_fps);
            // O piso e o teto **por fora** do arredondamento de `ns_do_log2`: o degrau 2^v que o
            // receptor monta (e arredonda) cai sempre dentro de `[min, max]` (achado 6).
            controles.insert(
                "obturadorNs".into(),
                json!({ "min": ns_por_baixo(teto.min), "max": ns_por_cima(teto.max), "inteiro": true, "escala": "log2" }),
            );
        }
        None => {
            falta("exposicao");
            falta("travaExposicao");
            falta("obturadorNs");
        }
    }
    match (exposicao, caps.get(&Propriedade::Ganho).filter(|f| f.tem_manual())) {
        (Some(_), Some(g)) => {
            controles.insert("iso".into(), json!({ "min": g.min, "max": g.max, "passo": g.passo, "inteiro": true, "unidade": "ganho" }));
        }
        _ => falta("iso"),
    }
    match caps.get(&Propriedade::Brilho).filter(|f| f.tem_manual()) {
        Some(b) => {
            controles.insert(
                "ev".into(),
                json!({
                    "min": i64::from(b.min) - i64::from(b.padrao),
                    "max": i64::from(b.max) - i64::from(b.padrao),
                    "passo": b.passo,
                    "inteiro": true,
                    "unidade": "brilho",
                    "origem": b.padrao,
                    // O brilho do driver não é a compensação do automático: vale em Manual e com a
                    // trava de exposição, e o núcleo das duas pontas deixa pedir assim (13/10).
                    DICA_DO_EV_INDEPENDENTE: true,
                }),
            );
        }
        None => falta("ev"),
    }
    match caps.get(&Propriedade::AntiCintilacao) {
        Some(f) => {
            let v: Vec<&str> = AntiCintilacao::TODAS.into_iter().filter(|a| a.oferecida(f)).map(texto_da_cintilacao).collect();
            controles.insert("antiCintilacao".into(), valores(&v));
        }
        None => falta("antiCintilacao"),
    }
    match caps.get(&Propriedade::Balanco) {
        Some(f) if f.tem_manual() => {
            controles.insert("balanco".into(), valores(&["auto", "kelvin"]));
            let k = faixa_do_kelvin(f);
            controles.insert("kelvin".into(), json!({ "min": k.min, "max": k.max, "passo": k.passo, "inteiro": true }));
            controles.insert("travaBalanco".into(), json!({}));
        }
        Some(_) => {
            controles.insert("balanco".into(), valores(&["auto"]));
            falta("kelvin");
            falta("travaBalanco");
        }
        None => {
            falta("balanco");
            falta("kelvin");
            falta("travaBalanco");
        }
    }
    match caps.get(&Propriedade::Foco) {
        Some(f) if f.tem_manual() => {
            controles.insert("foco".into(), valores(&["auto", "travado", "manual"]));
            controles.insert("focoPosicao".into(), json!({ "min": 0, "max": 1, "passo": 0.01 }));
        }
        Some(_) => {
            controles.insert("foco".into(), valores(&["auto"]));
            falta("focoPosicao");
        }
        None => {
            falta("foco");
            falta("focoPosicao");
        }
    }
    falta("toque"); // i18n: fora (o nome no fio)
    // **Os ajustes de imagem** (R9 §3.7, 13/10): só os que o driver declara, com `origem: camera`.
    // Ausente = não oferece, e nada vai em `limites`.
    for p in Propriedade::DE_IMAGEM {
        let (Some(f), Some(campo)) = (caps.get(&p), p.campo_de_imagem()) else { continue };
        if p == Propriedade::Contraluz {
            if !regras::contraluz_oferecida(f) {
                continue;
            }
            let d = if regras::contraluz_sim_ou_nao(f) {
                json!({ "origem": ORIGEM_CAMERA })
            } else {
                json!({ "min": f.min.max(0), "max": f.max, "passo": f.passo, "inteiro": true, "origem": ORIGEM_CAMERA })
            };
            controles.insert(campo.into(), d);
        } else if let Some((min, max)) = regras::escala_de_imagem(f) {
            controles.insert(campo.into(), json!({ "min": min, "max": max, "passo": 1, "inteiro": true, "origem": ORIGEM_CAMERA }));
        }
    }
    // **O zoom** (R9 §3.8, 13/10): só com `CameraControl_Zoom`, o fator em torno do padrão do driver.
    // A webcam não diz onde há lente: sem `opticas`. Ausente = não oferece, e nada vai em `limites`.
    // **O zoom do Quall** (§3.8.7, 14/10: a câmera sem zoom): o recorte central, `"origem":"quall"` e
    // `"opticas":[1]` (o 1× é o sensor inteiro), como o do Mac; quem controla mostra a nota do recorte.
    if let Some(f) = caps.get(&Propriedade::Zoom) {
        if let Some((lo, hi)) = regras::escala_do_zoom(f) {
            let d = if f.do_quall() {
                json!({ "min": lo, "max": hi, "passo": 0.1, "paradas": regras::paradas_da_faixa(f), "opticas": [1.0], "origem": ORIGEM_QUALL })
            } else {
                json!({ "min": lo, "max": hi, "passo": 0.1, "paradas": regras::paradas_da_faixa(f), "origem": ORIGEM_CAMERA })
            };
            controles.insert("zoom".into(), d);
        }
    }
    if trava_de_fps {
        controles.insert("travarFps".into(), json!({}));
    } else {
        falta("travarFps"); // i18n: fora (o nome no fio)
    }
    json!({ "plataforma": "windows", "controles": controles, "limites": limites })
}

/// A `origem` dos ajustes de imagem do Windows (R9 §3.7): o próprio driver (`IAMVideoProcAmp`). O
/// processamento de imagem do Quall não existe no Windows nesta rodada (§3.7.1).
pub const ORIGEM_CAMERA: &str = "camera"; // i18n: fora (o nome no fio)
/// A `origem` do **zoom do Quall** (R9 §3.8.7, 14/10): o recorte central na GPU do dono da captura.
pub const ORIGEM_QUALL: &str = "quall"; // i18n: fora (o nome no fio)

/// A janela plausível do `CameraControl_Exposure` em log2 de segundos: de 1/65536 s a 1024 s.
pub const LOG2_MINIMO: i32 = -16;
pub const LOG2_MAXIMO: i32 = 10;

/// 2^v s em ns, arredondado para baixo e para cima.
pub fn ns_por_baixo(v: i32) -> i64 {
    (1e9 * 2f64.powi(v)).floor() as i64
}
pub fn ns_por_cima(v: i32) -> i64 {
    (1e9 * 2f64.powi(v)).ceil() as i64
}

/// O valor de `antiCintilacao` no fio.
pub fn texto_da_cintilacao(a: AntiCintilacao) -> &'static str {
    match a {
        AntiCintilacao::Auto => "auto",
        AntiCintilacao::Hz50 => "50",
        AntiCintilacao::Hz60 => "60",
        AntiCintilacao::Desligada => "desligada",
    }
}

/// O registro no JSON do R9 (o mesmo que vai ao disco), para o núcleo, **com os inteiros sem `.0`**:
/// o `Registro` guarda `iso` e `ev` em `f64`, e o descritor diz `"inteiro":true` (a revisão, achado
/// 7; o Android lê `Int`).
pub fn registro_em_json(r: &Registro) -> String {
    let Ok(Value::Object(mut o)) = serde_json::to_value(r) else { return "{}".into() };
    for v in o.values_mut() {
        if let Some(x) = v.as_f64().filter(|x| v.is_f64() && x.fract() == 0.0 && x.abs() < 9.0e15) {
            *v = Value::from(x as i64);
        }
    }
    Value::Object(o).to_string()
}

// =============================================================================================
// O pedido de um receptor
// =============================================================================================

/// Um pedido aceito pelo núcleo, como `proximo_pedido` o entrega (§6).
#[derive(Clone, Debug, PartialEq)]
pub struct PedidoRemoto {
    pub n: u64,
    pub autor: Option<String>,
    pub ajuste: Map<String, Value>,
    pub restaurar: bool,
    pub tem_toque: bool,
}

/// Lê o JSON de `proximo_pedido`. `None` quando ele não se lê (o núcleo nunca manda assim).
pub fn ler_pedido(json: &str) -> Option<PedidoRemoto> {
    let Ok(Value::Object(o)) = serde_json::from_str::<Value>(json) else { return None };
    Some(PedidoRemoto {
        n: o.get("n")?.as_u64()?,
        autor: o.get("autor").and_then(Value::as_str).map(str::to_string),
        ajuste: o.get("ajuste").and_then(Value::as_object).cloned().unwrap_or_default(),
        restaurar: o.get("restaurar").and_then(Value::as_bool).unwrap_or(false),
        tem_toque: o.get("toque").is_some_and(|t| !t.is_null()), // i18n: fora (o nome no fio)
    })
}

fn texto<'a>(a: &'a Map<String, Value>, campo: &str) -> Option<&'a str> {
    a.get(campo).and_then(Value::as_str)
}

fn numero(a: &Map<String, Value>, campo: &str) -> Option<f64> {
    a.get(campo).and_then(Value::as_f64).filter(|x| x.is_finite())
}

/// **O pedido em gestos do R9, na ordem do contrato** (§6, achado B3): `restaurar` → os modos
/// (`exposicao`, `balanco`, `foco`) → as travas → os valores (`ev`, `iso`, `obturadorNs`,
/// `kelvin`, `focoPosicao`, `antiCintilacao`). Aplicados em sequência por
/// [`regras::aplicar_acao`], "partir do lido" só vale para o que o pedido **não** trouxe: o modo
/// Manual parte do lido, e o `iso` pedido vem depois e fica.
///
/// Os valores chegam conferidos pelo núcleo contra as capacidades daqui; o corte pela faixa de agora
/// (R9 §2.2) acontece aqui mesmo; o obturador, no teto do manual com o `travar_fps` que vale
/// **depois** do pedido (o do pedido, ou o de agora; `restaurar` destrava). `Err` traz o motivo de
/// recusa.
pub fn acoes_do_pedido(p: &PedidoRemoto, caps: &Capacidades, fps: f64, travar_fps: bool) -> Result<Vec<Acao>, &'static str> {
    if p.tem_toque {
        // As capacidades nunca listam `toque`; o núcleo já recusaria. Por garantia.
        return Err(NAO_APLICADO);
    }
    let a = &p.ajuste;
    let mut v = Vec::new();
    if p.restaurar {
        v.push(Acao::Restaurar);
    }
    // Os modos.
    match texto(a, "exposicao") {
        Some("auto") => v.push(Acao::Exposicao(ModoDeExposicao::Auto)),
        Some("manual") => v.push(Acao::Exposicao(ModoDeExposicao::Manual)),
        Some(_) => return Err(NAO_APLICADO),
        None => {}
    }
    if let Some(b) = a.get("balanco") {
        let b: Balanco = serde_json::from_value(b.clone()).map_err(|_| NAO_APLICADO)?;
        v.push(Acao::Balanco(b));
    }
    if let Some(f) = a.get("foco") {
        let f: Foco = serde_json::from_value(f.clone()).map_err(|_| NAO_APLICADO)?;
        v.push(Acao::Foco(f));
    }
    // As travas.
    if let Some(t) = a.get("travaExposicao") {
        v.push(Acao::TravarExposicao(t.as_bool().ok_or(NAO_APLICADO)?));
    }
    if let Some(t) = a.get("travaBalanco") {
        v.push(Acao::TravarBalanco(t.as_bool().ok_or(NAO_APLICADO)?));
    }
    // "Travar fps" (R9 §3.1.1): vale em qualquer exposição, sem partir de lido nenhum.
    if let Some(t) = a.get("travarFps") {
        v.push(Acao::TravarFps(t.as_bool().ok_or(NAO_APLICADO)?));
    }
    // Os valores, cortados pela faixa de agora.
    if let Some(ev) = numero(a, "ev") {
        let f = caps.get(&Propriedade::Brilho).ok_or(NAO_APLICADO)?;
        v.push(Acao::Brilho(f.cortar(i64::from(f.padrao) + ev.round() as i64)));
    }
    if let Some(g) = numero(a, "iso") {
        let f = caps.get(&Propriedade::Ganho).ok_or(NAO_APLICADO)?;
        v.push(Acao::Ganho(f.cortar(g.round() as i64)));
    }
    if let Some(ns) = numero(a, "obturadorNs") {
        let f = caps.get(&Propriedade::Exposicao).ok_or(NAO_APLICADO)?;
        // O log2 mais perto, cortado no teto do manual (§3.2: "a casca do filmador arredonda").
        let travar_fps = a.get("travarFps").and_then(Value::as_bool).unwrap_or(travar_fps && !p.restaurar);
        v.push(Acao::Obturador(faixa_do_obturador(f, fps, travar_fps).cortar(i64::from(log2_dos_ns(ns.round() as i64)))));
    }
    if let Some(k) = numero(a, "kelvin") {
        let f = caps.get(&Propriedade::Balanco).ok_or(NAO_APLICADO)?;
        v.push(Acao::Kelvin(faixa_do_kelvin(f).cortar(k.round() as i64)));
    }
    if let Some(x) = numero(a, "focoPosicao") {
        caps.get(&Propriedade::Foco).ok_or(NAO_APLICADO)?;
        v.push(Acao::FocoPosicao(x));
    }
    if let Some(c) = a.get("antiCintilacao") {
        let c: AntiCintilacao = serde_json::from_value(c.clone()).map_err(|_| NAO_APLICADO)?;
        v.push(Acao::AntiCintilacao(c));
    }
    // Os ajustes de imagem (R9 §3.7): de -100 a 100, sem modo nem trava; a contraluz na forma do
    // descritor (sim/não ou o nível).
    for p in Propriedade::DE_IMAGEM {
        let Some(campo) = p.campo_de_imagem() else { continue };
        let Some(x) = a.get(campo) else { continue };
        caps.get(&p).ok_or(NAO_APLICADO)?;
        if p == Propriedade::Contraluz {
            let c = match x {
                Value::Bool(b) => Contraluz::Ligada(*b),
                x => Contraluz::Nivel(x.as_f64().filter(|x| x.is_finite()).ok_or(NAO_APLICADO)?.round() as i32),
            };
            v.push(Acao::Contraluz(Some(c)));
        } else {
            let x = x.as_f64().filter(|x| x.is_finite()).ok_or(NAO_APLICADO)?;
            v.push(Acao::Imagem(p, x.round().clamp(f64::from(regras::IMAGEM_MIN), f64::from(regras::IMAGEM_MAX)) as i32));
        }
    }
    // O zoom (R9 §3.8): em qualquer exposição; `aplicar_acao` corta na escala da câmera.
    if let Some(z) = a.get("zoom") {
        caps.get(&Propriedade::Zoom).and_then(regras::escala_do_zoom).ok_or(NAO_APLICADO)?;
        v.push(Acao::Zoom(z.as_f64().filter(|z| z.is_finite()).ok_or(NAO_APLICADO)?));
    }
    Ok(v)
}

/// **Aplica um pedido ao registro**, sobre o lido de agora: o registro que fica valendo, ou o motivo
/// de recusa. "Sem lido (o Windows sem `Get`), recusa com `nao_aplicado` em vez de aplicar um manual
/// vazio" (§6): um modo manual que terminou sem o valor dele é recusado, e o registro não muda.
pub fn aplicar_pedido(r: &Registro, p: &PedidoRemoto, caps: &Capacidades, lidos: &Lidos, fps: f64) -> Result<Registro, &'static str> {
    let acoes = acoes_do_pedido(p, caps, fps, r.travar_fps)?;
    let mut novo = r.clone();
    for a in acoes {
        regras::aplicar_acao(&mut novo, a, caps, lidos);
    }
    if manual_vazio(&novo, caps) {
        return Err(NAO_APLICADO);
    }
    Ok(novo)
}

/// Um modo manual sem o valor que ele precisa (o lido faltou ao passar).
pub fn manual_vazio(r: &Registro, caps: &Capacidades) -> bool {
    let tem = |p: Propriedade| caps.contains_key(&p);
    (r.exposicao == ModoDeExposicao::Manual
        && ((tem(Propriedade::Ganho) && r.iso.is_none()) || (tem(Propriedade::Exposicao) && r.obturador_ns.is_none())))
        || (r.balanco == Balanco::Kelvin && r.kelvin.is_none())
        || (r.foco == Foco::Manual && r.foco_posicao.is_none())
}

// =============================================================================================
// O lido e a permissão
// =============================================================================================

/// **O lido** (§3.3), só o que o Windows lê, na unidade do registro: o ganho em `iso`, o obturador
/// em ns, o balanço em Kelvin, o foco de 0 a 1; e os campos em que a tela daqui diz "A câmera usou
/// {lido} em vez de {pedido}." (`divergentes`).
pub fn lido(lidos: &Lidos, caps: &Capacidades, divergentes: &[Propriedade]) -> Value {
    lido_com_pouca_luz(lidos, caps, divergentes, None)
}

/// [`lido`] com o **`poucaLuz`** (R9 §3.1.1): `{"fpsChegando","piso","fps"}` enquanto o aviso está
/// aceso, `null` quando não está. O piso é o de [`PoucaLuz::piso`] (o Windows não sabe o do driver).
pub fn lido_com_pouca_luz(lidos: &Lidos, caps: &Capacidades, divergentes: &[Propriedade], pouca_luz: Option<PoucaLuz>) -> Value {
    let mut o = Map::new();
    if let Some(l) = lidos.get(&Propriedade::Ganho) {
        o.insert("iso".into(), Value::from(l.valor));
    }
    if let Some(l) = lidos.get(&Propriedade::Exposicao) {
        o.insert("obturadorNs".into(), Value::from(ns_do_log2(l.valor)));
    }
    if let Some(l) = lidos.get(&Propriedade::Balanco) {
        o.insert("kelvin".into(), Value::from(l.valor));
    }
    if let (Some(l), Some(f)) = (lidos.get(&Propriedade::Foco), caps.get(&Propriedade::Foco)) {
        let x = (f.fracao(i64::from(l.valor)) * 100.0).round() / 100.0;
        o.insert("focoPosicao".into(), json!(x));
    }
    // A contraluz lida (R9 §3.7), na forma do descritor: com o registro sem ela (o padrão da câmera),
    // é o que quem recebe mostra na chave.
    if let (Some(l), Some(f)) = (lidos.get(&Propriedade::Contraluz), caps.get(&Propriedade::Contraluz).filter(|f| regras::contraluz_oferecida(f))) {
        let v = match regras::contraluz_do_driver(l.valor, f) {
            Contraluz::Ligada(b) => Value::from(b),
            Contraluz::Nivel(n) => Value::from(n.max(0)),
        };
        o.insert("contraluz".into(), v);
    }
    // O zoom lido (R9 §3.8), em fator.
    if let (Some(l), Some(f)) = (lidos.get(&Propriedade::Zoom), caps.get(&Propriedade::Zoom).filter(|f| regras::escala_do_zoom(f).is_some())) {
        o.insert("zoom".into(), json!(regras::zoom_do_driver(l.valor, f)));
    }
    o.insert("divergentes".into(),Value::from(divergentes.iter().map(|p| campo_da_propriedade(*p)).collect::<Vec<_>>()));
    o.insert(
        "poucaLuz".into(),
        pouca_luz.map_or(Value::Null, |p| json!({ "fpsChegando": p.fps_agora, "piso": p.piso(), "fps": p.fps })),
    );
    Value::Object(o)
}

/// O nome do arquivo da opção "Permitir controle remoto da câmera", na pasta de dados.
pub const ARQUIVO_DA_PERMISSAO: &str = "camera-controle-remoto.txt";

/// A opção guardada: só `sim` liga. Ausente, ilegível ou outra coisa: desligada (o padrão).
pub fn ler_permissao(conteudo: &str) -> bool {
    conteudo.trim_start_matches('\u{FEFF}').trim().eq_ignore_ascii_case("sim")
}

pub fn texto_da_permissao(permite: bool) -> &'static str {
    if permite {
        "sim"
    } else {
        "nao"
    }
}

/// O nome de quem está controlando, do estado do filmador do núcleo (`controlado_por`), ou `None`.
pub fn controlado_por(estado_json: &str) -> Option<String> {
    let v: Value = serde_json::from_str(estado_json).ok()?;
    let nome = v.get("controlado_por")?.get("nome")?.as_str()?.trim();
    (!nome.is_empty()).then(|| nome.to_string())
}

#[cfg(test)]
mod testes {
    use super::*;
    use crate::regras_dos_controles::{Faixa, Lido, FLAGS_AUTO, FLAGS_MANUAL};

    fn f(min: i32, max: i32, passo: i32, padrao: i32, bandeiras: i32) -> Faixa {
        Faixa::do_get_range(min, max, passo, padrao, bandeiras).unwrap()
    }

    /// A webcam de exemplo de `regras_dos_controles.rs`.
    fn caps() -> Capacidades {
        let mut c = Capacidades::new();
        c.insert(Propriedade::Exposicao, f(-11, -1, 1, -6, FLAGS_AUTO | FLAGS_MANUAL));
        c.insert(Propriedade::Ganho, f(0, 100, 1, 0, FLAGS_MANUAL));
        c.insert(Propriedade::Brilho, f(-64, 64, 1, 0, FLAGS_MANUAL));
        c.insert(Propriedade::Balanco, f(2800, 6500, 10, 4600, FLAGS_AUTO | FLAGS_MANUAL));
        c.insert(Propriedade::AntiCintilacao, f(0, 2, 1, 1, FLAGS_MANUAL));
        c
    }

    fn lidos() -> Lidos {
        let mut l = Lidos::new();
        l.insert(Propriedade::Exposicao, Lido { valor: -6, bandeiras: FLAGS_AUTO });
        l.insert(Propriedade::Ganho, Lido { valor: 32, bandeiras: FLAGS_MANUAL });
        l.insert(Propriedade::Brilho, Lido { valor: 0, bandeiras: FLAGS_MANUAL });
        l.insert(Propriedade::Balanco, Lido { valor: 5230, bandeiras: FLAGS_AUTO });
        l
    }

    fn pedido(ajuste: Value) -> PedidoRemoto {
        PedidoRemoto { n: 7, autor: Some("Pixel".into()), ajuste: ajuste.as_object().cloned().unwrap(), restaurar: false, tem_toque: false }
    }

    #[test]
    fn as_capacidades_da_webcam_da_bancada() {
        let c = capacidades(&caps(), 30.0, false);
        let ctl = &c["controles"];
        assert_eq!(c["plataforma"], "windows");
        assert_eq!(ctl["exposicao"]["valores"], json!(["auto", "manual"]));
        // O brilho como deslocamento do padrão, com a origem (achado I7).
        // E a dica de 13/10: o brilho vale em qualquer exposição (R9 §3.3).
        assert_eq!(ctl["ev"], json!({"min": -64, "max": 64, "passo": 1, "inteiro": true, "unidade": "brilho", "origem": 0, "independenteDaExposicao": true}));
        assert_eq!(ctl["iso"]["unidade"], "ganho");
        assert_eq!(ctl["iso"]["inteiro"], true);
        // O obturador de 2^-11 ao teto efetivo do manual, em log2: destravado (o padrão), o piso do
        // automático a 30 fps, 1/16 s (2^-4; 13/10).
        assert_eq!(ctl["obturadorNs"]["escala"], "log2");
        assert_eq!(ctl["obturadorNs"]["min"], json!(ns_por_baixo(-11)));
        assert_eq!(ctl["obturadorNs"]["max"], json!(ns_por_cima(-4)));
        // O degrau arredondado (o que o receptor manda) cai dentro da faixa publicada.
        for v in -11..=-4 {
            let ns = ns_do_log2(v);
            assert!(ns >= ns_por_baixo(-11) && ns <= ns_por_cima(-4), "2^{v}");
        }
        assert_eq!(ns_por_baixo(-12), 244140);
        assert_eq!(ns_por_cima(-12), 244141);
        // Um driver com a exposição numa unidade que não é log2 fica sem obturador.
        let mut linear = caps();
        linear.insert(Propriedade::Exposicao, f(1, 10000, 1, 100, FLAGS_AUTO | FLAGS_MANUAL));
        assert_eq!(capacidades(&linear, 30.0, false)["limites"]["obturadorNs"], CAMERA_NAO_OFERECE);
        assert_eq!(ctl["kelvin"], json!({"min": 2800, "max": 6500, "passo": 100, "inteiro": true}));
        assert_eq!(ctl["balanco"]["valores"], json!(["auto", "kelvin"]));
        assert_eq!(ctl["antiCintilacao"]["valores"], json!(["auto", "50", "60", "desligada"]));
        // Sem foco na câmera da bancada (§12), e nunca o toque.
        assert!(ctl.get("foco").is_none() && ctl.get("toque").is_none());
        assert_eq!(c["limites"]["foco"], CAMERA_NAO_OFERECE);
        assert_eq!(c["limites"]["focoPosicao"], CAMERA_NAO_OFERECE);
        assert_eq!(c["limites"]["toque"], CAMERA_NAO_OFERECE);
        // Cabe no teto do núcleo (2.048 bytes) com folga.
        assert!(c.to_string().len() < 1100, "{} bytes", c.to_string().len());
        // A 60 fps o teto destravado desce para 2^-5; travado, 1/fps: 2^-5 a 30 e 2^-6 a 60.
        assert_eq!(capacidades(&caps(), 60.0, false)["controles"]["obturadorNs"]["max"], json!(ns_por_cima(-5)));
        assert_eq!(capacidades_com_trava(&caps(), 30.0, false, true, true)["controles"]["obturadorNs"]["max"], json!(ns_por_cima(-5)));
        assert_eq!(capacidades_com_trava(&caps(), 60.0, false, true, true)["controles"]["obturadorNs"]["max"], json!(ns_do_log2(-6)));
    }

    #[test]
    fn o_modo_compartilhado_nao_oferece_nada() {
        let c = capacidades(&caps(), 30.0, true);
        assert_eq!(c["controles"], json!({}));
        for campo in CAMPOS {
            assert_eq!(c["limites"][campo], OUTRO_APP, "{campo}");
        }
    }

    #[test]
    fn a_camera_pobre_diz_o_que_falta() {
        let mut c = Capacidades::new();
        c.insert(Propriedade::Brilho, f(0, 255, 1, 128, FLAGS_MANUAL));
        c.insert(Propriedade::Foco, f(0, 10, 1, 0, FLAGS_AUTO));
        c.insert(Propriedade::Ganho, f(0, 100, 1, 0, FLAGS_MANUAL));
        let j = capacidades(&c, 30.0, false);
        assert_eq!(j["controles"]["ev"]["origem"], 128);
        assert_eq!(j["controles"]["ev"]["min"], -128);
        assert_eq!(j["controles"]["foco"]["valores"], json!(["auto"]));
        for campo in ["exposicao", "iso", "obturadorNs", "balanco", "kelvin", "antiCintilacao", "focoPosicao"] {
            assert_eq!(j["limites"][campo], CAMERA_NAO_OFERECE, "{campo}");
        }
    }

    #[test]
    fn passar_para_manual_com_iso_fica_com_o_iso_pedido() {
        // §6: `{"exposicao":"manual","iso":800}` fica com o ISO pedido, e o obturador parte do lido.
        let r = aplicar_pedido(&Registro::default(), &pedido(json!({"exposicao":"manual","iso":64})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(r.exposicao, ModoDeExposicao::Manual);
        assert_eq!(r.iso, Some(64.0));
        assert_eq!(r.obturador_ns, Some(ns_do_log2(-6)), "do lido");
        // Só o modo: os dois do lido.
        let r = aplicar_pedido(&Registro::default(), &pedido(json!({"exposicao":"manual"})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(r.iso, Some(32.0));
    }

    #[test]
    fn a_ordem_do_contrato() {
        let mut p = pedido(json!({"iso": 10, "antiCintilacao": "50", "exposicao": "manual", "travaBalanco": true, "balanco": "auto"}));
        p.restaurar = true;
        let v = acoes_do_pedido(&p, &caps(), 30.0, false).unwrap();
        assert_eq!(
            v,
            vec![
                Acao::Restaurar,
                Acao::Exposicao(ModoDeExposicao::Manual),
                Acao::Balanco(Balanco::Auto),
                Acao::TravarBalanco(true),
                Acao::Ganho(10),
                Acao::AntiCintilacao(AntiCintilacao::Hz50),
            ]
        );
    }

    #[test]
    fn os_valores_voltam_a_unidade_do_driver() {
        let mut r = Registro { exposicao: ModoDeExposicao::Manual, iso: Some(1.0), obturador_ns: Some(ns_do_log2(-7)), ..Default::default() };
        // O obturador: o log2 mais perto, cortado no teto do manual (destravado a 30 fps, 1/16 s).
        r = aplicar_pedido(&r, &pedido(json!({"obturadorNs": ns_do_log2(-9)})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(r.obturador_ns, Some(ns_do_log2(-9)));
        r = aplicar_pedido(&r, &pedido(json!({"obturadorNs": 1_000_000_000})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(r.obturador_ns, Some(ns_do_log2(-4)), "o teto destravado: o piso do automático");
        // Travado, o teto de 1/30; e um pedido que trava no mesmo ajuste já corta no teto novo.
        let travado = Registro { travar_fps: true, ..r.clone() };
        let t = aplicar_pedido(&travado, &pedido(json!({"obturadorNs": 1_000_000_000})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(t.obturador_ns, Some(ns_do_log2(-5)), "o teto de 1/30");
        let t = aplicar_pedido(&r, &pedido(json!({"obturadorNs": 1_000_000_000, "travarFps": true})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(t.obturador_ns, Some(ns_do_log2(-5)));
        // O brilho em Manual e com a trava de exposição (13/10): vale, o núcleo deixa pedir com a dica.
        let m = aplicar_pedido(&r, &pedido(json!({"ev": -5})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(m.ev, -5.0);
        // O brilho: o deslocamento do padrão.
        let r = aplicar_pedido(&Registro::default(), &pedido(json!({"ev": 12})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(r.ev, 12.0);
        // O Kelvin na escala da tela.
        let r = aplicar_pedido(&Registro { balanco: Balanco::Kelvin, kelvin: Some(5000), ..Default::default() }, &pedido(json!({"kelvin": 9000})), &caps(), &lidos(), 30.0).unwrap();
        assert_eq!(r.kelvin, Some(6500));
    }

    #[test]
    fn manual_sem_lido_e_recusado() {
        let mut sem = lidos();
        sem.remove(&Propriedade::Ganho);
        let e = aplicar_pedido(&Registro::default(), &pedido(json!({"exposicao":"manual"})), &caps(), &sem, 30.0);
        assert_eq!(e, Err(NAO_APLICADO));
        // Com o ganho no pedido, o lido do ganho não faz falta.
        assert!(aplicar_pedido(&Registro::default(), &pedido(json!({"exposicao":"manual","iso":5})), &caps(), &sem, 30.0).is_ok());
    }

    #[test]
    fn o_pedido_do_nucleo_se_le() {
        let p = ler_pedido(r#"{"n":5,"autor":"OBS no Dell","autor_id":"dell-7f2a","ajuste":{"exposicao":"manual","iso":800},"restaurar":false,"toque":null}"#).unwrap();
        assert_eq!(p.n, 5);
        assert_eq!(p.autor.as_deref(), Some("OBS no Dell"));
        assert_eq!(p.ajuste["iso"], 800);
        assert!(!p.restaurar && !p.tem_toque);
        assert!(ler_pedido("lixo").is_none());
        assert!(acoes_do_pedido(&PedidoRemoto { tem_toque: true, ..p }, &caps(), 30.0, false).is_err());
    }

    #[test]
    fn o_lido_e_a_permissao() {
        let mut c = caps();
        c.insert(Propriedade::Foco, f(0, 250, 5, 0, FLAGS_AUTO | FLAGS_MANUAL));
        let mut l = lidos();
        l.insert(Propriedade::Foco, Lido { valor: 125, bandeiras: FLAGS_AUTO });
        let j = lido(&l, &c, &[Propriedade::Exposicao]);
        assert_eq!(j["iso"], 32);
        assert_eq!(j["obturadorNs"], json!(ns_do_log2(-6)));
        assert_eq!(j["kelvin"], 5230);
        assert_eq!(j["focoPosicao"], json!(0.5));
        assert_eq!(j["divergentes"], json!(["obturadorNs"]));
        assert!(ler_permissao("sim\r\n") && ler_permissao("\u{FEFF}SIM"));
        assert!(!ler_permissao("") && !ler_permissao("nao") && !ler_permissao("talvez"));
        assert!(ler_permissao(texto_da_permissao(true)) && !ler_permissao(texto_da_permissao(false)));
        assert_eq!(controlado_por(r#"{"controlado_por":{"nome":"OBS no Dell","ha_ms":10}}"#).as_deref(), Some("OBS no Dell"));
        assert_eq!(controlado_por(r#"{"controlado_por":null}"#), None);
    }

    /// A dica é o mesmo texto do núcleo (só com `net`: o `camera_remota` do núcleo fica atrás de
    /// `quall-core/webrtc`; sem ele, este módulo compila sozinho).
    #[cfg(feature = "net")]
    #[test]
    fn a_dica_do_ev_e_a_do_nucleo() {
        assert_eq!(DICA_DO_EV_INDEPENDENTE, quall_core::camera_remota::DICA_DO_EV_INDEPENDENTE);
    }

    #[test]
    fn travar_fps_nas_capacidades_no_pedido_e_no_lido() {
        // §3.1.1: só com a prioridade da exposição declarada.
        assert_eq!(capacidades(&caps(), 30.0, false)["limites"]["travarFps"], CAMERA_NAO_OFERECE);
        let c = capacidades_com_trava(&caps(), 30.0, false, true, false);
        assert_eq!(c["controles"]["travarFps"], json!({}));
        assert!(c["limites"].get("travarFps").is_none());
        assert_eq!(capacidades_com_trava(&caps(), 30.0, true, true, false)["limites"]["travarFps"], OUTRO_APP);
        // O pedido: em qualquer exposição, e o "Restaurar" desliga antes.
        let r = aplicar_pedido(&Registro::default(), &pedido(json!({"travarFps": true})), &caps(), &lidos(), 30.0).unwrap();
        assert!(r.travar_fps);
        let manual = Registro { exposicao: ModoDeExposicao::Manual, iso: Some(1.0), obturador_ns: Some(ns_do_log2(-7)), travar_fps: true, ..Default::default() };
        assert!(!aplicar_pedido(&manual, &pedido(json!({"travarFps": false})), &caps(), &lidos(), 30.0).unwrap().travar_fps);
        assert_eq!(acoes_do_pedido(&pedido(json!({"travarFps": 1})), &caps(), 30.0, false), Err(NAO_APLICADO));
        // O lido: o aviso aceso, ou `null`.
        let p = PoucaLuz { fps_agora: 15, fps: 30, com_manual: true, com_trava: true };
        let j = lido_com_pouca_luz(&lidos(), &caps(), &[], Some(p));
        assert_eq!(j["poucaLuz"], json!({"fpsChegando": 15, "piso": 15, "fps": 30}));
        assert_eq!(lido(&lidos(), &caps(), &[])["poucaLuz"], Value::Null);
        // O registro antigo, sem a chave, é destravado; o novo vai com a chave.
        assert!(!serde_json::from_str::<Registro>(r#"{"exposicao":"auto"}"#).unwrap().travar_fps);
        assert!(registro_em_json(&r).contains("\"travarFps\":true"));
    }

    #[test]
    fn o_registro_em_json_e_o_do_disco() {
        let r = Registro { exposicao: ModoDeExposicao::Manual, iso: Some(64.0), ev: -3.0, ..Default::default() };
        let texto = registro_em_json(&r);
        assert!(texto.contains("\"iso\":64") && !texto.contains("64.0"), "{texto}");
        assert!(texto.contains("\"ev\":-3") && !texto.contains("-3.0"), "{texto}");
        let j: Value = serde_json::from_str(&texto).unwrap();
        assert_eq!(serde_json::from_value::<Registro>(j.clone()).unwrap(), r, "volta igual");
        assert_eq!(j["exposicao"], "manual");
        assert_eq!(j["antiCintilacao"], "auto");
        assert_eq!(j["balanco"], "auto");
        assert_eq!(j["travaExposicao"], false);
    }

    /// A webcam com os ajustes de imagem (R9 §3.7): a de cima, mais o `IAMVideoProcAmp` de imagem.
    fn caps_com_imagem() -> Capacidades {
        let mut c = caps();
        c.insert(Propriedade::Contraste, f(0, 10, 1, 7, FLAGS_MANUAL));
        c.insert(Propriedade::Saturacao, f(0, 100, 1, 64, FLAGS_MANUAL));
        c.insert(Propriedade::Gama, f(100, 500, 1, 300, FLAGS_MANUAL));
        c.insert(Propriedade::Nitidez, f(0, 7, 1, 0, FLAGS_MANUAL));
        c.insert(Propriedade::Contraluz, f(0, 1, 1, 0, FLAGS_MANUAL));
        c
    }

    #[test]
    fn a_imagem_nas_capacidades_no_pedido_e_no_lido() {
        let c = capacidades(&caps_com_imagem(), 30.0, false);
        let ctl = &c["controles"];
        assert_eq!(ctl["gama"], json!({"min": -100, "max": 100, "passo": 1, "inteiro": true, "origem": "camera"}));
        assert_eq!(ctl["contraste"]["min"], -100);
        assert_eq!(ctl["nitidez"], json!({"min": 0, "max": 100, "passo": 1, "inteiro": true, "origem": "camera"}), "o padrão na ponta de baixo");
        assert_eq!(ctl["contraluz"], json!({"origem": "camera"}), "dois valores: sim/não");
        assert!(c["limites"].get("gama").is_none(), "ausente = não oferece, sem limite");
        assert!(c.to_string().len() < 1100, "{} bytes", c.to_string().len());
        // A câmera da bancada de antes, sem imagem: nada.
        let sem = capacidades(&caps(), 30.0, false);
        assert!(sem["controles"].get("gama").is_none() && sem["controles"].get("contraluz").is_none());
        // No modo compartilhado, nada (e nada em `limites`).
        assert!(capacidades(&caps_com_imagem(), 30.0, true)["limites"].get("gama").is_none());
        // A contraluz em níveis.
        let mut niveis = caps_com_imagem();
        niveis.insert(Propriedade::Contraluz, f(0, 3, 1, 1, FLAGS_MANUAL));
        assert_eq!(capacidades(&niveis, 30.0, false)["controles"]["contraluz"], json!({"min": 0, "max": 3, "passo": 1, "inteiro": true, "origem": "camera"}));
        // O pedido: valem em qualquer exposição, na escala do fio.
        let manual = Registro { exposicao: ModoDeExposicao::Manual, iso: Some(1.0), obturador_ns: Some(ns_do_log2(-7)), ..Default::default() };
        let r = aplicar_pedido(&manual, &pedido(json!({"gama": -20, "contraste": 35, "contraluz": true})), &caps_com_imagem(), &lidos(), 30.0).unwrap();
        assert_eq!((r.gama, r.contraste, r.contraluz), (-20, 35, Some(Contraluz::Ligada(true))));
        let texto = registro_em_json(&r);
        assert!(texto.contains("\"gama\":-20") && texto.contains("\"contraluz\":true") && !texto.contains("saturacao"), "{texto}");
        let r = aplicar_pedido(&Registro::default(), &pedido(json!({"contraluz": 2})), &niveis, &lidos(), 30.0).unwrap();
        assert_eq!(r.contraluz, Some(Contraluz::Nivel(2)));
        // O "Restaurar" vem antes: os campos do mesmo pedido ficam.
        let mut p = pedido(json!({"nitidez": 50}));
        p.restaurar = true;
        let r = aplicar_pedido(&Registro { gama: 10, ..Default::default() }, &p, &caps_com_imagem(), &lidos(), 30.0).unwrap();
        assert_eq!((r.gama, r.nitidez), (0, 50));
        // A câmera sem a propriedade recusa (o núcleo já recusaria antes).
        assert_eq!(acoes_do_pedido(&pedido(json!({"gama": 10})), &caps(), 30.0, false), Err(NAO_APLICADO));
        // O lido leva a contraluz na forma do descritor.
        let mut l = lidos();
        l.insert(Propriedade::Contraluz, Lido { valor: 1, bandeiras: FLAGS_MANUAL });
        assert_eq!(lido(&l, &caps_com_imagem(), &[])["contraluz"], true);
        l.insert(Propriedade::Contraluz, Lido { valor: 2, bandeiras: FLAGS_MANUAL });
        assert_eq!(lido(&l, &niveis, &[])["contraluz"], 2);
        assert!(lido(&lidos(), &caps(), &[]).get("contraluz").is_none());
    }

    /// As capacidades de imagem passam pela conferência do núcleo (só com `net`).
    #[cfg(feature = "net")]
    #[test]
    fn as_capacidades_de_imagem_passam_no_nucleo() {
        let f_ = quall_core::camera_remota::Filmador::novo();
        let mut niveis = caps_com_imagem();
        niveis.insert(Propriedade::Contraluz, f(0, 3, 1, 1, FLAGS_MANUAL));
        for c in [caps_com_imagem(), niveis] {
            let caps_json = capacidades(&c, 30.0, false).to_string();
            let reg = registro_em_json(&Registro { gama: -20, contraluz: Some(Contraluz::Ligada(true)), ..Default::default() });
            f_.definir_camera(Some((&caps_json, &reg))).unwrap();
        }
        assert_eq!(ORIGEM_CAMERA, quall_core::camera_remota::ORIGENS_DA_IMAGEM[0]);
    }

    /// **O zoom** (R9 §3.8): o descritor só com `CameraControl_Zoom`, o pedido e o lido em fator.
    #[test]
    fn o_zoom_nas_capacidades_no_pedido_e_no_lido() {
        let mut c = caps();
        c.insert(Propriedade::Zoom, f(100, 500, 1, 100, FLAGS_MANUAL));
        let j = capacidades(&c, 30.0, false);
        assert_eq!(j["controles"]["zoom"], json!({"min": 1.0, "max": 5.0, "passo": 0.1, "paradas": [1.0, 2.0, 4.0, 5.0], "origem": "camera"}));
        assert!(j["controles"]["zoom"].get("opticas").is_none(), "a webcam não diz onde há lente");
        assert!(capacidades(&caps(), 30.0, false)["controles"].get("zoom").is_none());
        assert!(capacidades(&c, 30.0, true)["limites"].get("zoom").is_none(), "compartilhada: ausente, sem limite");
        let manual = Registro { exposicao: ModoDeExposicao::Manual, iso: Some(1.0), obturador_ns: Some(ns_do_log2(-7)), ..Default::default() };
        let r = aplicar_pedido(&manual, &pedido(json!({"zoom": 2.5})), &c, &lidos(), 30.0).unwrap();
        assert_eq!(r.zoom, Some(2.5));
        assert!(registro_em_json(&r).contains("\"zoom\":2.5"));
        assert_eq!(acoes_do_pedido(&pedido(json!({"zoom": 2})), &caps(), 30.0, false), Err(NAO_APLICADO));
        let mut l = lidos();
        l.insert(Propriedade::Zoom, Lido { valor: 240, bandeiras: FLAGS_MANUAL });
        assert_eq!(lido(&l, &c, &[])["zoom"], 2.4);
        assert_eq!(campo_da_propriedade(Propriedade::Zoom), "zoom");
    }

    /// **O zoom do Quall** (R9 §3.8.7, 14/10): a câmera sem `CameraControl_Zoom` ganha o recorte, com
    /// `"origem":"quall"`, as paradas 1–2–3 e `"opticas":[1]`; o pedido corta no teto e o lido é o fator.
    #[test]
    fn o_zoom_do_quall_no_fio() {
        let mut c = caps();
        assert_eq!(crate::zoom_do_quall::decidir(&mut c, Some(3.0)), crate::zoom_do_quall::DecisaoDoZoom::DoQuall(3.0));
        let j = capacidades(&c, 30.0, false);
        assert_eq!(
            j["controles"]["zoom"],
            json!({"min": 1.0, "max": 3.0, "passo": 0.1, "paradas": [1.0, 2.0, 3.0], "opticas": [1.0], "origem": "quall"})
        );
        let r = aplicar_pedido(&Registro::default(), &pedido(json!({"zoom": 8})), &c, &lidos(), 30.0).unwrap();
        assert_eq!(r.zoom, Some(3.0), "cortado no teto do recorte");
        let mut l = lidos();
        l.insert(Propriedade::Zoom, Lido { valor: 250, bandeiras: FLAGS_MANUAL });
        assert_eq!(lido(&l, &c, &[])["zoom"], 2.5);
    }

    /// O zoom do Quall passa pela conferência do núcleo (só com `net`).
    #[cfg(feature = "net")]
    #[test]
    fn o_zoom_do_quall_passa_no_nucleo() {
        let mut c = caps_com_imagem();
        crate::zoom_do_quall::decidir(&mut c, Some(2.0));
        let caps_json = capacidades(&c, 30.0, false).to_string();
        let reg = registro_em_json(&Registro { zoom: Some(1.5), ..Default::default() });
        quall_core::camera_remota::Filmador::novo().definir_camera(Some((&caps_json, &reg))).unwrap();
    }

    /// As capacidades com o zoom passam pela conferência do núcleo (só com `net`).
    #[cfg(feature = "net")]
    #[test]
    fn as_capacidades_com_zoom_passam_no_nucleo() {
        let mut c = caps_com_imagem();
        c.insert(Propriedade::Zoom, f(100, 500, 1, 100, FLAGS_MANUAL));
        let caps_json = capacidades(&c, 30.0, false).to_string();
        let reg = registro_em_json(&Registro { zoom: Some(2.5), ..Default::default() });
        quall_core::camera_remota::Filmador::novo().definir_camera(Some((&caps_json, &reg))).unwrap();
        assert_eq!(quall_core::camera_remota::ZOOM, "zoom");
    }
}
