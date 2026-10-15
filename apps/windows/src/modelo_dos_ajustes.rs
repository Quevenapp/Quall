//! **A janela "Ajustes da câmera" sem Win32** (R9, `docs/controles-de-camera.md` §4.2 e §4.3), no
//! molde de `modelo_da_janela.rs`: o estado em valores simples (o painel que a thread dos ajustes
//! publica, a aba escolhida, com ou sem prévia), e a composição em peças de `estilo.rs` e em lugares
//! de controle de `estilo::lugar::ajustes`. A janela (`janela_dos_ajustes.rs`) só executa: põe os
//! controles nativos onde o quadro diz, desenha cada botão pela [`aparencia`] no `NM_CUSTOMDRAW`, e
//! transforma cada clique numa [`Acao`] pelo [`gesto`].
//!
//! Os testes rodam em qualquer máquina: cada aba, em cada estado de exemplo, cabe na janela sem
//! rolar e sem um controle cobrir outro, e os textos são os do §3.5.

use crate::estilo::lugar::ajustes as lugar;
use crate::estilo::*;
use crate::idioma::t;
use crate::modelo_da_janela::{Aparencia, EstadoDoControle};
use crate::modelo_dos_ajustes_remotos::{self as remotos, EstadoRemoto, GestoRemoto};
use crate::regras_dos_controles::{
    self as regras, faixa_do_kelvin, faixa_do_obturador, Aba, Acao, AntiCintilacao, Balanco, Faixa, FaseDosAjustes, Foco, ModoDeExposicao,
    PainelDosAjustes, Propriedade,
};

/// Os controles nativos da janela.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum ControleDosAjustes {
    /// Uma das quatro abas (grupo de opções).
    Aba(usize),
    /// "Auto" (0) e "Manual" (1) da exposição.
    Exposicao(usize),
    Brilho,
    TravarExposicao,
    /// Auto, 50 Hz, 60 Hz, Desligada.
    Cintilacao(usize),
    PassarParaManual,
    Ganho,
    Obturador,
    /// A grade 2 × 3 do balanço, na ordem de `Balanco::GRADE`.
    Balanco(usize),
    Kelvin,
    TravarBalanco,
    /// Auto, Travado, Manual.
    Foco(usize),
    FocoPosicao,
    Restaurar,
    /// "Usar meus ajustes" (07/10): a câmera abre no automático e lembra o último manual.
    UsarMeusAjustes,
    /// "Permitir controle remoto da câmera" (R9b), só no aparelho que filma.
    PermitirRemoto,
    /// **"Travar fps"** (§3.1.1): a chave da aba Exposição, embaixo da trava de exposição.
    TravarFps,
    /// **O botão do aviso da pouca luz** (§3.1.1): "Travar em 30 fps" (ou, na câmera do outro lado
    /// travada, "Clarear (até 15 fps)"), dentro da caixa do aviso.
    AcaoDaPoucaLuz,
    /// **Os ajustes de imagem** (§3.7, 13/10), na aba "Imagem": gama, contraste, saturação e nitidez,
    /// na ordem de [`IMAGEM`], de -100 a 100.
    Imagem(usize),
    /// A compensação de contraluz sim/não (o driver com dois valores).
    Contraluz,
    /// A compensação de contraluz em níveis do driver.
    ContraluzNivel,
    /// **O zoom** (§3.8, 13/10), fora das abas, no alto da coluna: o fator em escala logarítmica.
    Zoom,
}

/// Os quatro deslizantes de imagem, na ordem de [`ControleDosAjustes::Imagem`].
pub const IMAGEM: [Propriedade; 4] = [Propriedade::Gama, Propriedade::Contraste, Propriedade::Saturacao, Propriedade::Nitidez];

/// Que controle nativo cada um é.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EspecieDosAjustes {
    /// `BS_PUSHBUTTON`, desenhado no `NM_CUSTOMDRAW`.
    Botao,
    /// `BS_AUTOCHECKBOX | BS_PUSHLIKE`.
    Alternar,
    /// `BS_AUTORADIOBUTTON | BS_PUSHLIKE`, num grupo.
    Opcao,
    /// `TRACKBAR_CLASS`, horizontal, em degraus.
    Deslizante,
}

impl ControleDosAjustes {
    pub fn id(self) -> usize {
        match self {
            ControleDosAjustes::Aba(i) => 300 + i,
            ControleDosAjustes::Exposicao(i) => 310 + i,
            ControleDosAjustes::Brilho => 320,
            ControleDosAjustes::TravarExposicao => 321,
            ControleDosAjustes::Cintilacao(i) => 330 + i,
            ControleDosAjustes::PassarParaManual => 340,
            ControleDosAjustes::Ganho => 341,
            ControleDosAjustes::Obturador => 342,
            ControleDosAjustes::Balanco(i) => 350 + i,
            ControleDosAjustes::Kelvin => 360,
            ControleDosAjustes::TravarBalanco => 361,
            ControleDosAjustes::Foco(i) => 370 + i,
            ControleDosAjustes::FocoPosicao => 380,
            ControleDosAjustes::Restaurar => 390,
            ControleDosAjustes::UsarMeusAjustes => 391,
            ControleDosAjustes::PermitirRemoto => 395,
            ControleDosAjustes::TravarFps => 322,
            ControleDosAjustes::AcaoDaPoucaLuz => 392,
            ControleDosAjustes::Imagem(i) => 400 + i,
            ControleDosAjustes::Contraluz => 404,
            ControleDosAjustes::ContraluzNivel => 405,
            ControleDosAjustes::Zoom => 381,
        }
    }

    pub fn de_id(id: usize) -> Option<ControleDosAjustes> {
        Some(match id {
            300..=304 => ControleDosAjustes::Aba(id - 300),
            310..=311 => ControleDosAjustes::Exposicao(id - 310),
            320 => ControleDosAjustes::Brilho,
            321 => ControleDosAjustes::TravarExposicao,
            330..=333 => ControleDosAjustes::Cintilacao(id - 330),
            340 => ControleDosAjustes::PassarParaManual,
            341 => ControleDosAjustes::Ganho,
            342 => ControleDosAjustes::Obturador,
            350..=355 => ControleDosAjustes::Balanco(id - 350),
            360 => ControleDosAjustes::Kelvin,
            361 => ControleDosAjustes::TravarBalanco,
            370..=372 => ControleDosAjustes::Foco(id - 370),
            380 => ControleDosAjustes::FocoPosicao,
            390 => ControleDosAjustes::Restaurar,
            391 => ControleDosAjustes::UsarMeusAjustes,
            395 => ControleDosAjustes::PermitirRemoto,
            322 => ControleDosAjustes::TravarFps,
            392 => ControleDosAjustes::AcaoDaPoucaLuz,
            400..=403 => ControleDosAjustes::Imagem(id - 400),
            404 => ControleDosAjustes::Contraluz,
            405 => ControleDosAjustes::ContraluzNivel,
            381 => ControleDosAjustes::Zoom,
            _ => return None,
        })
    }

    pub fn especie(self) -> EspecieDosAjustes {
        use ControleDosAjustes as C;
        match self {
            C::Aba(_) | C::Exposicao(_) | C::Cintilacao(_) | C::Balanco(_) | C::Foco(_) => EspecieDosAjustes::Opcao,
            C::TravarExposicao | C::TravarBalanco | C::PermitirRemoto | C::TravarFps | C::Contraluz => EspecieDosAjustes::Alternar,
            C::Brilho | C::Ganho | C::Obturador | C::Kelvin | C::FocoPosicao | C::Imagem(_) | C::ContraluzNivel | C::Zoom => EspecieDosAjustes::Deslizante,
            C::PassarParaManual | C::Restaurar | C::UsarMeusAjustes | C::AcaoDaPoucaLuz => EspecieDosAjustes::Botao,
        }
    }

    /// O primeiro de um grupo de opções (leva `WS_GROUP`).
    pub fn abre_grupo(self) -> bool {
        use ControleDosAjustes as C;
        match self {
            C::Aba(i) | C::Exposicao(i) | C::Cintilacao(i) | C::Balanco(i) | C::Foco(i) => i == 0,
            _ => true,
        }
    }

    /// Todos, na ordem de criação (a do Tab).
    pub fn todos() -> Vec<ControleDosAjustes> {
        use ControleDosAjustes as C;
        // O botão do aviso fica no alto, antes das abas, e o zoom (§3.8) entre os dois, fora das
        // abas: é a ordem de cima para baixo.
        let mut v: Vec<C> = vec![C::AcaoDaPoucaLuz, C::Zoom];
        v.extend((0..Aba::TODAS.len()).map(C::Aba));
        v.extend((0..2).map(C::Exposicao));
        v.extend([C::Brilho, C::TravarExposicao, C::TravarFps]);
        v.extend((0..4).map(C::Cintilacao));
        v.extend([C::PassarParaManual, C::Ganho, C::Obturador]);
        v.extend((0..6).map(C::Balanco));
        v.extend([C::Kelvin, C::TravarBalanco]);
        v.extend((0..3).map(C::Foco));
        v.push(C::FocoPosicao);
        v.extend((0..IMAGEM.len()).map(C::Imagem));
        v.extend([C::Contraluz, C::ContraluzNivel, C::Restaurar, C::UsarMeusAjustes, C::PermitirRemoto]);
        v
    }
}

/// O estado da janela: a aba, o que a thread dos ajustes publicou, e se há prévia.
#[derive(Clone, Debug, Default)]
pub struct EstadoDosAjustes {
    pub aba: Aba,
    pub painel: PainelDosAjustes,
    pub com_previa: bool,
    /// **R9b, no aparelho que filma**: a opção "Permitir controle remoto da câmera" (`None`: a
    /// janela não a mostra, como na sonda sem rede).
    pub permitir: Option<bool>,
    /// **R9b, no aparelho que recebe**: o painel é o da câmera do outro lado
    /// (`modelo_dos_ajustes_remotos`), sem prévia e sem a opção.
    pub remoto: Option<EstadoRemoto>,
}

/// Um deslizante em degraus: `0..=max`, na posição `pos`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Degraus {
    pub max: i32,
    pub pos: i32,
}

/// Um controle visível: onde, se está habilitado e marcado, e os degraus de um deslizante.
#[derive(Clone, Debug, PartialEq)]
pub struct ControleNaTela {
    pub c: ControleDosAjustes,
    pub ret: Ret,
    pub habilitado: bool,
    pub marcado: bool,
    pub degraus: Option<Degraus>,
}

/// O que pintar, onde fica cada controle visível, e onde fica a prévia.
#[derive(Clone, Debug, Default)]
pub struct QuadroDosAjustes {
    pub itens: Vec<Item>,
    pub controles: Vec<ControleNaTela>,
    pub previa: Option<Ret>,
}

impl QuadroDosAjustes {
    pub fn achar(&self, c: ControleDosAjustes) -> Option<&ControleNaTela> {
        self.controles.iter().find(|x| x.c == c)
    }
    pub fn lugar(&self, c: ControleDosAjustes) -> Option<Ret> {
        self.achar(c).map(|x| x.ret)
    }
    pub(crate) fn controle(&mut self, c: ControleDosAjustes, ret: Ret, habilitado: bool, marcado: bool) {
        self.controles.push(ControleNaTela { c, ret, habilitado, marcado, degraus: None });
    }
    pub(crate) fn deslizante(&mut self, c: ControleDosAjustes, ret: Ret, habilitado: bool, degraus: Degraus) {
        self.controles.push(ControleNaTela { c, ret, habilitado, marcado: false, degraus: Some(degraus) });
    }
    pub(crate) fn texto(&mut self, r: Ret, s: impl Into<String>, f: Fonte, cor: Cor) {
        self.itens.push(texto(r, s, f, cor).meio().item());
    }
}

/// O tamanho da área de cliente, em DIP: o remoto é sem prévia e sem a faixa da opção. Com zoom na
/// câmera (§3.8), a janela cresce a linha dele (`lugar::ZOOM_A`); a janela muda de tamanho quando ele
/// aparece ou some.
pub fn tamanho(e: &EstadoDosAjustes) -> (f32, f32) {
    if let Some(r) = &e.remoto {
        return (lugar::largura(false), lugar::ALTURA + lugar::desce(remotos::tem_zoom(r)));
    }
    (lugar::largura(e.com_previa), lugar::altura(e.com_previa, e.permitir.is_some(), tem_zoom(e)))
}

/// A câmera deste aparelho declara zoom (§3.8): a linha dele aparece fora das abas.
fn tem_zoom(e: &EstadoDosAjustes) -> bool {
    faixa(e, Propriedade::Zoom).and_then(|f| regras::escala_do_zoom(&f)).is_some()
}

// =============================================================================================
// Os valores na escala de cada deslizante
// =============================================================================================

fn faixa(e: &EstadoDosAjustes, p: Propriedade) -> Option<Faixa> {
    e.painel.caps.get(&p).copied()
}

fn lido(e: &EstadoDosAjustes, p: Propriedade) -> Option<i32> {
    e.painel.lidos.get(&p).map(|l| l.valor)
}

/// O brilho que a tela mostra: o do registro (padrão + deslocamento) ou o lido.
fn brilho(e: &EstadoDosAjustes, f: &Faixa) -> i32 {
    let r = &e.painel.registro;
    if r.ev.round() as i64 != 0 {
        f.cortar(i64::from(f.padrao) + r.ev.round() as i64)
    } else {
        f.cortar(i64::from(lido(e, Propriedade::Brilho).unwrap_or(f.padrao)))
    }
}

fn ganho(e: &EstadoDosAjustes, f: &Faixa) -> i32 {
    f.cortar(e.painel.registro.iso.map(|g| g.round() as i64).or(lido(e, Propriedade::Ganho).map(i64::from)).unwrap_or(i64::from(f.padrao)))
}

/// O obturador **aplicado** (cortado pelo teto do manual de agora: o fps e "Travar fps"); o guardado
/// fica intacto (§3.1).
fn obturador(e: &EstadoDosAjustes, f: &Faixa) -> i32 {
    let v = e.painel.registro.obturador_ns.map(regras::log2_dos_ns).or(lido(e, Propriedade::Exposicao)).unwrap_or(f.padrao);
    f.cortar(i64::from(v))
}

fn kelvin(e: &EstadoDosAjustes, f: &Faixa) -> i32 {
    f.cortar(i64::from(e.painel.registro.kelvin.or(lido(e, Propriedade::Balanco)).unwrap_or(f.padrao)))
}

fn foco_posicao(e: &EstadoDosAjustes) -> f64 {
    match (e.painel.registro.foco_posicao, faixa(e, Propriedade::Foco), lido(e, Propriedade::Foco)) {
        (Some(x), _, _) => x,
        (None, Some(f), Some(v)) => f.fracao(i64::from(v)),
        _ => 0.0,
    }
}

/// A contraluz que a tela mostra: a do registro, ou a lida do driver (o padrão da câmera).
fn contraluz(e: &EstadoDosAjustes, f: &Faixa) -> regras::Contraluz {
    match e.painel.registro.contraluz {
        Some(c) => regras::contraluz_na_forma(c, f),
        None => regras::contraluz_do_driver(lido(e, Propriedade::Contraluz).unwrap_or(f.padrao), f),
    }
}

/// A faixa da contraluz, quando ela é oferecida.
fn faixa_da_contraluz(e: &EstadoDosAjustes) -> Option<Faixa> {
    faixa(e, Propriedade::Contraluz).filter(regras::contraluz_oferecida)
}

/// Os degraus da contraluz em níveis: do primeiro nível de 0 para cima ao máximo.
fn niveis_da_contraluz(f: &Faixa) -> (i32, i32) {
    (f.cortar(i64::from(f.min.max(0))), f.max)
}

/// **A câmera oferece algum ajuste de imagem?** (§3.7) Sem nenhum, a aba "Imagem" não aparece.
pub fn tem_imagem(caps: &regras::Capacidades) -> bool {
    IMAGEM.iter().any(|p| caps.get(p).and_then(regras::escala_de_imagem).is_some())
        || caps.get(&Propriedade::Contraluz).is_some_and(regras::contraluz_oferecida)
}

// =============================================================================================
// A composição
// =============================================================================================

/// **Compõe a janela** no estado dado.
pub fn compor(e: &EstadoDosAjustes) -> QuadroDosAjustes {
    use ControleDosAjustes as C;
    if let Some(r) = &e.remoto {
        return remotos::compor(e.aba, r);
    }
    let mut q = QuadroDosAjustes::default();
    let (largura, altura) = tamanho(e);
    q.itens.push(caixa(Ret::new(0.0, 0.0, largura, altura), 0.0, FUNDO));
    let p = &e.painel;
    let pronto = p.fase == FaseDosAjustes::Pronto;
    // A prévia e as duas linhas do §3.6.
    let (linha_r, aviso_r) = if e.com_previa {
        q.previa = Some(lugar::PREVIA);
        q.itens.push(caixa(lugar::PREVIA, RAIO_DO_CARTAO, Cor::rgb(0x000000)));
        (lugar::LINHA_LIDA_COM_PREVIA, lugar::AVISO_COM_PREVIA)
    } else {
        (lugar::LINHA_LIDA_SEM_PREVIA, lugar::AVISO_SEM_PREVIA)
    };
    let linha = match p.fase {
        FaseDosAjustes::Lendo => t("Lendo a câmera…").to_string(),
        _ => p.linha_lida.clone(),
    };
    if !linha.is_empty() {
        q.itens.push(texto(linha_r, linha, F_MONO_12, TEXTO2).meio().item());
    }
    // Uma linha de aviso só: o modo compartilhado, depois a divergência (o pedido da pessoa não
    // vingou), e por último a pouca luz (§3.1), que é informação e não falha: vai no tom neutro.
    let aviso_ = match p.fase {
        FaseDosAjustes::Compartilhada => Some((Tom::Ambar, t(regras::FRASE_OUTRO_APP).to_string())),
        _ => p.divergencia.clone().map(|d| (Tom::Ambar, d)).or_else(|| p.pouca_luz.map(|l| (Tom::Info, l.texto()))),
    };
    // O botão da pouca luz (§3.1.1), só quando o aviso à vista é o dela e a câmera tem a trava.
    let botao_da_luz = match p.fase {
        FaseDosAjustes::Pronto if p.divergencia.is_none() => p.pouca_luz.and_then(|l| l.botao()),
        _ => None,
    };
    if let Some((tom, t)) = aviso_ {
        match botao_da_luz {
            Some(_) => {
                let b = aviso_com_botao(&mut q, aviso_r, tom, &t);
                q.controle(C::AcaoDaPoucaLuz, b, pronto, false);
            }
            None => {
                let a = altura_do_aviso(&t, aviso_r.l).min(aviso_r.a);
                q.itens.extend(aviso(Ret::new(aviso_r.x, aviso_r.y, aviso_r.l, a), tom, &t));
            }
        }
    }
    // **O zoom** (§3.8, 13/10), fora das abas e acima delas, só com `CameraControl_Zoom`.
    let com_zoom = {
        let (zx, mut zy) = lugar::zoom(e.com_previa);
        zoom_no_alto(&mut q, e, zx, &mut zy, lugar::COLUNA_L, pronto)
    };
    // As abas; a "Imagem" (§3.7) só com algum ajuste de imagem na câmera.
    let com_imagem = tem_imagem(&p.caps);
    for (i, r) in lugar::abas(e.com_previa, com_zoom).iter().enumerate() {
        if i == Aba::Imagem.indice() && !com_imagem {
            continue;
        }
        q.controle(C::Aba(i), *r, true, e.aba.indice() == i);
    }
    let (x, mut y) = lugar::inicio(e.com_previa, com_zoom);
    let l = lugar::COLUNA_L;
    let r = &p.registro;
    let nota = |q: &mut QuadroDosAjustes, y: f32, t: &str| {
        q.texto(Ret::new(x, y, l, lugar::NOTA_A), t.to_string(), F_LEGENDA, TEXTO3);
    };
    // O rótulo de um deslizante, com o valor à direita.
    let rotulo_e_valor = |q: &mut QuadroDosAjustes, y: f32, rotulo_: &str, valor: &str| {
        q.texto(Ret::new(x, y, l - lugar::VALOR_L, lugar::ROTULO_A), rotulo_.to_string(), F_CORPO_FORTE, TEXTO);
        q.itens.push(texto(Ret::new(x + l - lugar::VALOR_L, y, lugar::VALOR_L, lugar::ROTULO_A), valor.to_string(), F_MONO_13, TEXTO2).direita().meio().item());
    };
    match e.aba {
        Aba::Exposicao => {
            let fx = faixa(e, Propriedade::Exposicao);
            let ops = lugar::opcoes(x, y, 220.0, 2);
            q.controle(C::Exposicao(0), ops[0], pronto && fx.is_some(), r.exposicao == ModoDeExposicao::Auto);
            q.controle(C::Exposicao(1), ops[1], pronto && fx.is_some_and(|f| f.tem_manual()), r.exposicao == ModoDeExposicao::Manual);
            y += lugar::OPCAO_A + lugar::ESPACO;
            // O brilho (§3.3: no Windows, no lugar do EV).
            match faixa(e, Propriedade::Brilho) {
                Some(f) => {
                    let v = brilho(e, &f);
                    rotulo_e_valor(&mut q, y, t("Brilho"), &v.to_string());
                    // O brilho do driver não é a compensação do automático (13/10, §3.3): fica livre
                    // em qualquer exposição e com a trava, sem a linha "Destrave…".
                    q.deslizante(C::Brilho, Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: f.passos(), pos: f.indice(i64::from(v)) });
                }
                None => {
                    rotulo_e_valor(&mut q, y, t("Brilho"), "");
                    nota(&mut q, y + lugar::ROTULO_A + 4.0, &regras::frase_sem_controle(Propriedade::Brilho.nome()));
                }
            }
            y += lugar::ROTULO_A + 4.0 + lugar::DESLIZANTE_A + 2.0 + lugar::NOTA_A + 8.0;
            // A trava (só com Auto).
            let r_trava = Ret::new(x, y, l, lugar::INTERRUPTOR_A);
            q.controle(C::TravarExposicao, r_trava, pronto && fx.is_some_and(|f| f.tem_manual()) && r.exposicao == ModoDeExposicao::Auto, r.trava_exposicao);
            if fx.is_none_or(|f| !f.tem_manual()) {
                nota(&mut q, y + lugar::INTERRUPTOR_A + 2.0, &regras::frase_sem_controle("a trava de exposição")); // i18n: chave
            }
            y += lugar::INTERRUPTOR_A + 2.0 + lugar::NOTA_A + 8.0;
            // "Travar fps" (§3.1.1), só com a prioridade da exposição declarada (o Windows não tem
            // outro jeito de pedir o fps constante). Vale em qualquer exposição: no manual, decide o
            // teto do obturador (1/fps travado, o piso do automático destravado; 13/10).
            if p.trava_de_fps {
                q.controle(C::TravarFps, Ret::new(x, y, l, lugar::INTERRUPTOR_A), pronto, r.travar_fps);
                y += lugar::INTERRUPTOR_A + 8.0;
            }
            // A anti-cintilação.
            q.texto(Ret::new(x, y, l, lugar::ROTULO_A), t("Anti-cintilação"), F_CORPO_FORTE, TEXTO);
            y += lugar::ROTULO_A + 4.0;
            let fc = faixa(e, Propriedade::AntiCintilacao);
            for (i, (ret, a)) in lugar::opcoes(x, y, l, 4).into_iter().zip(AntiCintilacao::TODAS).enumerate() {
                q.controle(C::Cintilacao(i), ret, pronto && fc.is_some_and(|f| a.oferecida(&f)), r.anti_cintilacao == a);
            }
            if fc.is_none() {
                nota(&mut q, y + lugar::OPCAO_A + 2.0, &regras::frase_sem_controle(Propriedade::AntiCintilacao.nome()));
            }
        }
        Aba::GanhoEObturador => {
            let (fg, fo) = (faixa(e, Propriedade::Ganho), faixa(e, Propriedade::Exposicao).filter(|f| f.tem_manual()));
            if fg.is_none() && fo.is_none() {
                // §3.5: um grupo em que nada se aplica mostra uma linha só.
                nota(&mut q, y, &regras::frase_sem_controle("o ganho e o obturador")); // i18n: chave
            } else if r.exposicao == ModoDeExposicao::Auto {
                q.itens.push(texto(Ret::new(x, y, l, lugar::FRASE_A), t(regras::FRASE_PASSE_PARA_MANUAL), F_LEGENDA_13, TEXTO2).quebra().item());
                y += lugar::FRASE_A + lugar::ESPACO;
                q.controle(C::PassarParaManual, Ret::new(x, y, 190.0, 36.0), pronto && fo.is_some(), false);
            } else {
                match fg {
                    Some(f) => {
                        let v = ganho(e, &f);
                        rotulo_e_valor(&mut q, y, t("Ganho"), &v.to_string());
                        q.deslizante(C::Ganho, Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: f.passos(), pos: f.indice(i64::from(v)) });
                    }
                    None => {
                        rotulo_e_valor(&mut q, y, t("Ganho"), "");
                        nota(&mut q, y + lugar::ROTULO_A + 4.0, &regras::frase_sem_controle(Propriedade::Ganho.nome()));
                    }
                }
                y += lugar::ROTULO_A + 4.0 + lugar::DESLIZANTE_A + 2.0 + lugar::NOTA_A + 8.0;
                match fo {
                    Some(f) => {
                        let f = faixa_do_obturador(&f, p.fps, r.travar_fps);
                        let v = obturador(e, &f);
                        rotulo_e_valor(&mut q, y, t("Obturador"), &regras::texto_do_obturador(v));
                        q.deslizante(C::Obturador, Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: f.passos(), pos: f.indice(i64::from(v)) });
                        // Acima de 1/fps o quadro alonga e o fps cai (13/10, §3.1): a tela diz.
                        let um_por_fps = regras::teto_do_obturador(p.fps);
                        if v > um_por_fps {
                            let frase = crate::idioma::tf("Acima de {}, a câmera baixa o fps.", &[&regras::texto_do_obturador(um_por_fps)]);
                            nota(&mut q, y + lugar::ROTULO_A + 4.0 + lugar::DESLIZANTE_A + 2.0, &frase);
                        }
                    }
                    None => {
                        rotulo_e_valor(&mut q, y, t("Obturador"), "");
                        nota(&mut q, y + lugar::ROTULO_A + 4.0, &regras::frase_sem_controle(Propriedade::Exposicao.nome()));
                    }
                }
            }
        }
        Aba::Balanco => match faixa(e, Propriedade::Balanco) {
            None => nota(&mut q, y, &regras::frase_sem_controle(Propriedade::Balanco.nome())),
            Some(f) => {
                let w = (l - 12.0) / 3.0;
                for (i, b) in Balanco::GRADE.iter().enumerate() {
                    let ret = Ret::new(x + (i % 3) as f32 * (w + 6.0), y + (i / 3) as f32 * (lugar::OPCAO_A + 6.0), w, lugar::OPCAO_A);
                    let habilitado = match b {
                        Balanco::Auto => true,
                        Balanco::Kelvin => f.tem_manual(),
                        _ => false,
                    };
                    q.controle(C::Balanco(i), ret, pronto && habilitado, r.balanco == *b);
                }
                y += 2.0 * lugar::OPCAO_A + 6.0 + 2.0;
                // Os presets não existem no Windows (§1), e a grade os mostra apagados com a linha.
                nota(&mut q, y, &regras::frase_sem_controle("os presets de balanço")); // i18n: chave
                y += lugar::NOTA_A + lugar::ESPACO;
                if r.balanco == Balanco::Kelvin {
                    let fk = faixa_do_kelvin(&f);
                    let v = kelvin(e, &fk);
                    rotulo_e_valor(&mut q, y, t("Kelvin"), &format!("{v} K"));
                    q.deslizante(C::Kelvin, Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: fk.passos(), pos: fk.indice(i64::from(v)) });
                } else {
                    // Com Kelvin a trava de balanço não se aplica e some (§3.4).
                    q.controle(C::TravarBalanco, Ret::new(x, y, l, lugar::INTERRUPTOR_A), pronto && f.tem_manual() && r.balanco == Balanco::Auto, r.trava_balanco);
                    if !f.tem_manual() {
                        nota(&mut q, y + lugar::INTERRUPTOR_A + 2.0, &regras::frase_sem_controle("a trava de balanço")); // i18n: chave
                    }
                }
            }
        },
        // O zoom (§3.8) saiu desta aba em 13/10: fica acima das abas.
        Aba::Foco => {
            match faixa(e, Propriedade::Foco) {
                None => nota(&mut q, y, t(regras::FRASE_FOCO_FIXO)),
                Some(f) => {
                    for (i, (ret, x_)) in lugar::opcoes(x, y, 300.0, 3).into_iter().zip(Foco::TODOS).enumerate() {
                        let habilitado = x_ == Foco::Auto || f.tem_manual();
                        q.controle(C::Foco(i), ret, pronto && habilitado, r.foco == x_);
                    }
                    y += lugar::OPCAO_A + 2.0;
                    if !f.tem_manual() {
                        nota(&mut q, y, &regras::frase_sem_controle(Propriedade::Foco.nome()));
                    }
                    y += lugar::NOTA_A + lugar::ESPACO;
                    if r.foco == Foco::Manual {
                        let pos = foco_posicao(e);
                        rotulo_e_valor(&mut q, y, t("Perto ↔ Longe"), &regras::com_virgula(pos, 2));
                        q.deslizante(C::FocoPosicao, Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: 100, pos: (pos * 100.0).round() as i32 });
                    }
                }
            }
        }
        // **Imagem** (§3.7): só o que a câmera oferece, sem linhas apagadas. Os deslizantes não têm
        // nota embaixo: quatro e a contraluz cabem sem a prévia (a R5).
        Aba::Imagem => {
            for (i, prop) in IMAGEM.iter().enumerate() {
                let Some((lo, hi)) = faixa(e, *prop).and_then(|f| regras::escala_de_imagem(&f)) else { continue };
                let v = r.imagem(*prop).clamp(lo, hi);
                rotulo_e_valor(&mut q, y, t(prop.rotulo_de_imagem()), &regras::texto_de_imagem(v));
                q.deslizante(C::Imagem(i), Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: hi - lo, pos: v - lo });
                y += lugar::ROTULO_A + 4.0 + lugar::DESLIZANTE_A + 8.0;
            }
            if let Some(f) = faixa_da_contraluz(e) {
                match contraluz(e, &f) {
                    regras::Contraluz::Ligada(ligada) => {
                        q.controle(C::Contraluz, Ret::new(x, y, l, lugar::INTERRUPTOR_A), pronto, ligada);
                    }
                    regras::Contraluz::Nivel(n) => {
                        let (lo, hi) = niveis_da_contraluz(&f);
                        let n = n.clamp(lo, hi);
                        rotulo_e_valor(&mut q, y, t(Propriedade::Contraluz.rotulo_de_imagem()), &n.to_string());
                        let d = Faixa { min: lo, ..f };
                        q.deslizante(C::ContraluzNivel, Ret::new(x, y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A), pronto, Degraus { max: d.passos(), pos: d.indice(i64::from(n)) });
                    }
                }
            }
            if !com_imagem {
                nota(&mut q, y, &regras::frase_sem_controle("os ajustes de imagem")); // i18n: chave
            }
        }
    }
    q.controle(C::Restaurar, lugar::restaurar(e.com_previa, com_zoom), pronto, false);
    // Ao lado, só quando há "meus ajustes" diferentes do que vale (07/10).
    if regras::oferece_meus_ajustes(p.meus_ajustes.as_ref(), &p.registro) {
        q.controle(C::UsarMeusAjustes, lugar::usar_meus_ajustes(e.com_previa, com_zoom), pronto, false);
    }
    // **R9b**: a opção vale para o app (e não para esta câmera), e fica viva mesmo lendo ou no
    // modo compartilhado; embaixo, quem mexeu de longe.
    if let Some(permite) = e.permitir {
        q.controle(C::PermitirRemoto, lugar::permitir_remoto(e.com_previa, com_zoom), true, permite);
        if let Some(nome) = &p.controlado_por {
            q.texto(lugar::controlado_por(e.com_previa, com_zoom), crate::idioma::tf("Controlado por {}", &[nome]), F_LEGENDA_13, AGUARDANDO_TEXTO);
        }
    }
    q
}

/// **O zoom fora das abas** (§3.8, 13/10): "Zoom ……… 2,4×" e o deslizante logarítmico na largura da coluna,
/// quando a câmera o declara; desce `y`. Devolve `false` sem zoom (nada desenhado).
fn zoom_no_alto(q: &mut QuadroDosAjustes, e: &EstadoDosAjustes, x: f32, y: &mut f32, l: f32, pronto: bool) -> bool {
    let Some((lo, hi)) = faixa(e, Propriedade::Zoom).and_then(|f| regras::escala_do_zoom(&f)) else { return false };
    let z = e.painel.registro.zoom_ou_neutro().clamp(lo, hi);
    q.texto(Ret::new(x, *y, l - lugar::VALOR_L, lugar::ROTULO_A), t(rotulo_do_zoom(e)).to_string(), F_CORPO_FORTE, TEXTO);
    q.itens.push(texto(Ret::new(x + l - lugar::VALOR_L, *y, lugar::VALOR_L, lugar::ROTULO_A), regras::texto_do_zoom(z), F_MONO_13, TEXTO2).direita().meio().item());
    q.deslizante(
        ControleDosAjustes::Zoom,
        Ret::new(x, *y + lugar::ROTULO_A + 4.0, l, lugar::DESLIZANTE_A),
        pronto,
        Degraus { max: regras::DEGRAUS_DO_ZOOM, pos: regras::degrau_do_zoom(z, lo, hi) },
    );
    *y += lugar::ROTULO_A + 4.0 + lugar::DESLIZANTE_A + lugar::ESPACO;
    true
}

/// **O aviso com o botão da pouca luz** (§3.1.1), na caixa `r` inteira: o ícone, a frase em até duas
/// linhas na largura toda, e o botão embaixo dela, à esquerda. Devolve o lugar do botão. Ao lado do
/// botão a frase ficava com ~190 DIP e precisava de três linhas (13/10): a caixa tem 80 de altura.
pub(crate) fn aviso_com_botao(q: &mut QuadroDosAjustes, r: Ret, tom: Tom, s: &str) -> Ret {
    let (fundo, tinta, icone, cor_do_icone) = match tom {
        Tom::Ambar => (Cor::rgba(0xFFB340, 31).sobre(FUNDO), AGUARDANDO_TEXTO, Icone::Aviso, AGUARDANDO),
        Tom::Vermelho => (Cor::rgba(0xFF453A, 41).sobre(FUNDO), PERIGO_TEXTO, Icone::Aviso, PERIGO_TEXTO),
        Tom::Info => (SUPERFICIE, TEXTO2, Icone::Info, ACENTO_CLARO),
    };
    let frase = Ret::new(r.x + 40.0, r.y + 8.0, (r.l - 52.0).max(1.0), 36.0);
    let b = Ret::new(frase.x, frase.y + frase.a + 4.0, BOTAO_DA_LUZ_L.min(frase.l), 28.0);
    q.itens.push(caixa(r, RAIO_DO_CARTAO, fundo));
    q.itens.push(Item::Icone { ret: Ret::new(r.x + 12.0, r.y + 9.0, 18.0, 18.0), icone, tamanho: 15.0, cor: cor_do_icone });
    q.itens.push(texto(frase, s, F_LEGENDA_13, tinta).quebra().item());
    b
}

/// A largura do botão do aviso: cabe "Brighten (down to 15 fps)", o mais longo dos rótulos.
pub const BOTAO_DA_LUZ_L: f32 = 200.0;

/// Quantas linhas a frase ocupa ao lado do ícone, na conta de `estilo::altura_do_aviso`.
pub fn linhas_da_frase_do_aviso(s: &str, l: f32) -> f32 {
    ((altura_do_aviso(s, l) - 20.0) / 18.0).round()
}

// =============================================================================================
// Os gestos
// =============================================================================================

/// **O gesto de um controle**: a aba que ele abre (a janela troca sozinha), ou a [`Acao`] sobre o
/// registro. Um deslizante leva o degrau escolhido.
pub enum Gesto {
    Aba(Aba),
    Acao(Acao),
    /// Ligar ou desligar "Permitir controle remoto da câmera" (R9b).
    Permitir(bool),
    /// No aparelho que recebe: o pedido à câmera do outro lado.
    Remoto(GestoRemoto),
}

pub fn gesto(c: ControleDosAjustes, e: &EstadoDosAjustes, degrau: Option<i32>) -> Option<Gesto> {
    use ControleDosAjustes as C;
    if let Some(r) = &e.remoto {
        return match remotos::gesto(c, r, degrau)? {
            GestoRemoto::Aba(a) => Some(Gesto::Aba(a)),
            g => Some(Gesto::Remoto(g)),
        };
    }
    let p = &e.painel;
    let d = |f: Faixa| f.do_indice(i64::from(degrau.unwrap_or(0)));
    Some(match c {
        C::Aba(i) => Gesto::Aba(*Aba::TODAS.get(i)?),
        C::Exposicao(0) => Gesto::Acao(Acao::Exposicao(ModoDeExposicao::Auto)),
        C::Exposicao(_) => Gesto::Acao(Acao::Exposicao(ModoDeExposicao::Manual)),
        // "O Manual leva à aba ISO e obturador" (§4.3): quem chama troca a aba depois.
        C::PassarParaManual => Gesto::Acao(Acao::Exposicao(ModoDeExposicao::Manual)),
        C::Brilho => Gesto::Acao(Acao::Brilho(d(faixa(e, Propriedade::Brilho)?))),
        C::TravarExposicao => Gesto::Acao(Acao::TravarExposicao(!p.registro.trava_exposicao)),
        C::Cintilacao(i) => Gesto::Acao(Acao::AntiCintilacao(*AntiCintilacao::TODAS.get(i)?)),
        C::Ganho => Gesto::Acao(Acao::Ganho(d(faixa(e, Propriedade::Ganho)?))),
        C::Obturador => Gesto::Acao(Acao::Obturador(d(faixa_do_obturador(&faixa(e, Propriedade::Exposicao)?, p.fps, p.registro.travar_fps)))),
        C::Balanco(i) => Gesto::Acao(Acao::Balanco(*Balanco::GRADE.get(i)?)),
        C::Kelvin => Gesto::Acao(Acao::Kelvin(d(faixa_do_kelvin(&faixa(e, Propriedade::Balanco)?)))),
        C::TravarBalanco => Gesto::Acao(Acao::TravarBalanco(!p.registro.trava_balanco)),
        C::Foco(i) => Gesto::Acao(Acao::Foco(*Foco::TODOS.get(i)?)),
        C::FocoPosicao => Gesto::Acao(Acao::FocoPosicao(f64::from(degrau.unwrap_or(0)) / 100.0)),
        C::Restaurar => Gesto::Acao(Acao::Restaurar),
        C::UsarMeusAjustes => Gesto::Acao(Acao::UsarMeusAjustes),
        C::PermitirRemoto => Gesto::Permitir(!e.permitir?),
        // "Travar fps" (§3.1.1): a chave troca; o botão do aviso só aparece destravado, e trava.
        C::TravarFps => Gesto::Acao(Acao::TravarFps(!p.registro.travar_fps)),
        C::AcaoDaPoucaLuz => Gesto::Acao(Acao::TravarFps(!p.registro.travar_fps)),
        C::Imagem(i) => {
            let prop = *IMAGEM.get(i)?;
            let (lo, hi) = regras::escala_de_imagem(&faixa(e, prop)?)?;
            Gesto::Acao(Acao::Imagem(prop, (lo + degrau.unwrap_or(0)).clamp(lo, hi)))
        }
        C::Contraluz => {
            let f = faixa_da_contraluz(e)?;
            let ligada = matches!(contraluz(e, &f), regras::Contraluz::Ligada(true));
            Gesto::Acao(Acao::Contraluz(Some(regras::Contraluz::Ligada(!ligada))))
        }
        C::ContraluzNivel => {
            let f = faixa_da_contraluz(e)?;
            let (lo, _) = niveis_da_contraluz(&f);
            Gesto::Acao(Acao::Contraluz(Some(regras::Contraluz::Nivel(Faixa { min: lo, ..f }.do_indice(i64::from(degrau.unwrap_or(0)))))))
        }
        C::Zoom => {
            let (lo, hi) = regras::escala_do_zoom(&faixa(e, Propriedade::Zoom)?)?;
            Gesto::Acao(Acao::Zoom(regras::zoom_do_degrau(degrau.unwrap_or(0), lo, hi)))
        }
    })
}

// =============================================================================================
// A aparência e os nomes
// =============================================================================================

/// O rótulo de cada controle, no idioma de agora (os de `regras_dos_controles` são as chaves em
/// português). A janela o reescreve quando o idioma muda. No remoto, a segunda aba e os deslizantes
/// do EV e do ISO levam o nome da câmera do outro lado.
pub fn rotulo(c: ControleDosAjustes, e: &EstadoDosAjustes) -> String {
    use ControleDosAjustes as C;
    // O botão da pouca luz leva o número (o fps escolhido, ou o piso): já sai no idioma de agora.
    if c == C::AcaoDaPoucaLuz {
        return match &e.remoto {
            Some(r) => remotos::botao_da_pouca_luz(r).unwrap_or_default(),
            None => e.painel.pouca_luz.and_then(|l| l.botao()).unwrap_or_default(),
        };
    }
    if let Some(r) = &e.remoto {
        if let C::Aba(i) = c {
            if let Some(a) = Aba::TODAS.get(i) {
                return t(remotos::rotulo_da_aba(r, *a)).to_string();
            }
        }
        if let Some(s) = remotos::rotulo_do_deslizante(c, r) {
            return t(s).to_string();
        }
    }
    let s: &'static str = match c {
        C::Aba(i) => Aba::TODAS.get(i).map(|a| a.rotulo()).unwrap_or_default(),
        C::Exposicao(0) => "Auto", // i18n: chave
        C::Exposicao(_) => "Manual", // i18n: chave
        C::Brilho => "Brilho", // i18n: chave
        C::TravarExposicao => "Travar exposição", // i18n: chave
        C::Cintilacao(i) => AntiCintilacao::TODAS.get(i).map(|a| a.rotulo()).unwrap_or_default(),
        C::PassarParaManual => regras::PASSAR_PARA_MANUAL,
        C::Ganho => "Ganho", // i18n: chave
        C::Obturador => "Obturador", // i18n: chave
        C::Balanco(i) => Balanco::GRADE.get(i).map(|b| b.rotulo()).unwrap_or_default(),
        C::Kelvin => "Kelvin", // i18n: chave
        C::TravarBalanco => "Travar balanço", // i18n: chave
        C::Foco(i) => Foco::TODOS.get(i).map(|f| f.rotulo()).unwrap_or_default(),
        C::FocoPosicao => "Perto ↔ Longe", // i18n: chave
        C::Restaurar => regras::RESTAURAR_AUTOMATICO,
        C::UsarMeusAjustes => regras::USAR_MEUS_AJUSTES,
        C::PermitirRemoto => FRASE_PERMITIR,
        C::TravarFps => "Travar fps", // i18n: chave
        C::AcaoDaPoucaLuz => "",
        C::Imagem(i) => IMAGEM.get(i).map(|p| p.rotulo_de_imagem()).unwrap_or_default(),
        C::Contraluz | C::ContraluzNivel => Propriedade::Contraluz.rotulo_de_imagem(),
        C::Zoom => rotulo_do_zoom(e),
    };
    t(s).to_string()
}

/// **O rótulo da linha do zoom do Quall** (§3.8.7, 14/10): a câmera sem zoom recebe o recorte central,
/// e o rótulo diz que é um recorte (o Mac põe a mesma nota embaixo da linha; aqui a linha não cresce).
pub const ZOOM_DO_QUALL: &str = "Zoom (recorte do Quall)"; // i18n: chave

/// "Zoom", ou [`ZOOM_DO_QUALL`] quando o zoom desta câmera é o recorte do Quall.
fn rotulo_do_zoom(e: &EstadoDosAjustes) -> &'static str {
    let recorte = match &e.remoto {
        Some(r) => remotos::zoom_do_quall(r),
        None => faixa(e, Propriedade::Zoom).is_some_and(|f| f.do_quall()),
    };
    if recorte {
        ZOOM_DO_QUALL
    } else {
        "Zoom" // i18n: chave
    }
}

/// A opção do aparelho que filma (R9b, `docs/controle-remoto-da-camera.md`), literal.
pub const FRASE_PERMITIR: &str = "Permitir controle remoto da câmera"; // i18n: chave

/// **O nome de cada controle para o Narrador.** Os deslizantes levam o valor.
pub fn texto_acessivel(c: ControleDosAjustes, e: &EstadoDosAjustes) -> String {
    use ControleDosAjustes as C;
    let r = rotulo(c, e);
    if let Some(remoto) = &e.remoto {
        return match (c, remotos::valor_acessivel(c, remoto)) {
            (C::Aba(_), _) => format!("{r}, {}", t("aba")),
            (_, Some(v)) => format!("{r}, {v}"),
            _ => r,
        };
    }
    let valor = match c {
        C::Brilho => faixa(e, Propriedade::Brilho).map(|f| brilho(e, &f).to_string()),
        C::Ganho => faixa(e, Propriedade::Ganho).map(|f| ganho(e, &f).to_string()),
        C::Obturador => faixa(e, Propriedade::Exposicao).map(|f| regras::texto_do_obturador(obturador(e, &faixa_do_obturador(&f, e.painel.fps, e.painel.registro.travar_fps)))),
        C::Kelvin => faixa(e, Propriedade::Balanco).map(|f| format!("{} K", kelvin(e, &faixa_do_kelvin(&f)))),
        C::FocoPosicao => Some(regras::com_virgula(foco_posicao(e), 2)),
        C::Imagem(i) => IMAGEM.get(i).map(|p| regras::texto_de_imagem(e.painel.registro.imagem(*p))),
        C::ContraluzNivel => faixa_da_contraluz(e).map(|f| match contraluz(e, &f) {
            regras::Contraluz::Nivel(n) => n.to_string(),
            regras::Contraluz::Ligada(b) => b.to_string(),
        }),
        C::Zoom => Some(regras::texto_do_zoom(e.painel.registro.zoom_ou_neutro())),
        C::Aba(_) => Some(t("aba").into()),
        _ => None,
    };
    match valor {
        Some(v) => format!("{r}, {v}"),
        None => r,
    }
}

/// **Como cada botão se desenha**, no tamanho `l × a` (os deslizantes são do sistema), com o rótulo
/// de [`rotulo`].
pub fn aparencia(c: ControleDosAjustes, rotulo_: &str, l: f32, a: f32, s: EstadoDoControle) -> Aparencia {
    use ControleDosAjustes as C;
    let rotulo = |_c: ControleDosAjustes| rotulo_.to_string();
    let mut fundo = FUNDO;
    let mut raio = RAIO_DO_BOTAO;
    let mut itens = match c.especie() {
        // O título longo da opção do remoto (R9b) quebra em duas linhas, em vez de cortar.
        EspecieDosAjustes::Alternar if c == C::PermitirRemoto => {
            raio = RAIO_DO_CARTAO;
            let mut v = vec![caixa_com_borda(Ret::new(0.0, 0.0, l, a), RAIO_DO_CARTAO, SUPERFICIE, CONTORNO, 1.0)];
            let xi = l - 16.0 - INTERRUPTOR_L;
            v.push(texto(Ret::new(16.0, 4.0, (xi - 28.0).max(1.0), a - 8.0), rotulo_, F_CORPO_FORTE, TEXTO).quebra().meio().item());
            v.extend(interruptor(xi, (a - INTERRUPTOR_A) / 2.0, s.marcado));
            v
        }
        EspecieDosAjustes::Opcao => {
            fundo = FUNDO;
            raio = 4.0;
            let mut v = vec![caixa(Ret::new(0.0, 0.0, l, a), 6.0, SUPERFICIE_ALTA)];
            v.extend(segmento(l, a, &rotulo(c), s.marcado).into_iter().skip(1));
            v
        }
        EspecieDosAjustes::Alternar => {
            raio = RAIO_DO_CARTAO;
            linha_de_interruptor(l, a, &rotulo(c), "", s.marcado)
        }
        EspecieDosAjustes::Botao => {
            let tipo = if c == C::PassarParaManual { TipoDeBotao::Principal } else { TipoDeBotao::Secundario };
            botao(l, a, tipo, &rotulo(c), None, F_BOTAO_PEQUENO)
        }
        EspecieDosAjustes::Deslizante => vec![],
    };
    if s.quente && !s.desligado {
        itens.push(caixa(Ret::new(0.0, 0.0, l, a), raio, Cor::rgba(0xFFFFFF, 10)));
    }
    if s.foco {
        itens.push(anel_de_foco(l, a, raio));
    }
    let opacidade = if s.desligado {
        0.4
    } else if s.apertado {
        0.9
    } else {
        1.0
    };
    Aparencia { fundo, itens, opacidade }
}

// =============================================================================================
// Os exemplos (os testes e o retrato de bancada)
// =============================================================================================

fn faixa_(min: i32, max: i32, passo: i32, padrao: i32, bandeiras: i32) -> Faixa {
    Faixa { min, max, passo, padrao, bandeiras }
}

fn painel_de_exemplo() -> PainelDosAjustes {
    use regras::{Lido, FLAGS_AUTO as A, FLAGS_MANUAL as M};
    let mut p = PainelDosAjustes { fase: FaseDosAjustes::Pronto, fps: 30.0, ..Default::default() };
    p.caps.insert(Propriedade::Exposicao, faixa_(-11, -1, 1, -6, A | M));
    p.caps.insert(Propriedade::Ganho, faixa_(0, 100, 1, 0, M));
    p.caps.insert(Propriedade::Brilho, faixa_(-64, 64, 1, 0, M));
    p.caps.insert(Propriedade::Balanco, faixa_(2800, 6500, 10, 4600, A | M));
    p.caps.insert(Propriedade::Foco, faixa_(0, 250, 5, 0, A | M));
    p.caps.insert(Propriedade::AntiCintilacao, faixa_(0, 2, 1, 1, M));
    // Os ajustes de imagem (§3.7): o padrão fora do meio, a nitidez com o padrão na ponta.
    p.caps.insert(Propriedade::Gama, faixa_(100, 500, 1, 300, M));
    p.caps.insert(Propriedade::Contraste, faixa_(0, 10, 1, 7, M));
    p.caps.insert(Propriedade::Saturacao, faixa_(0, 100, 1, 64, M));
    p.caps.insert(Propriedade::Nitidez, faixa_(0, 7, 1, 0, M));
    p.caps.insert(Propriedade::Contraluz, faixa_(0, 1, 1, 0, M));
    // O zoom (§3.8): a escala da Logitech, 100 a 500 (1× a 5×).
    p.caps.insert(Propriedade::Zoom, faixa_(100, 500, 1, 100, M));
    for (prop, v, b) in [
        (Propriedade::Exposicao, -6, A),
        (Propriedade::Ganho, 32, M),
        (Propriedade::Brilho, 0, M),
        (Propriedade::Balanco, 5230, A),
        (Propriedade::Foco, 125, A),
        (Propriedade::AntiCintilacao, 2, M),
        (Propriedade::Gama, 300, M),
        (Propriedade::Contraste, 7, M),
        (Propriedade::Saturacao, 64, M),
        (Propriedade::Nitidez, 0, M),
        (Propriedade::Contraluz, 0, M),
    ] {
        p.lidos.insert(prop, Lido { valor: v, bandeiras: b });
    }
    p.linha_lida = regras::linha_lida(&p.lidos);
    p
}

/// **Os estados de exemplo**: cada aba, em Auto e em Manual, travada, compartilhada, lendo, sem
/// controles, e com e sem prévia.
pub fn exemplos() -> Vec<(String, EstadoDosAjustes)> {
    let base = EstadoDosAjustes { aba: Aba::Exposicao, painel: painel_de_exemplo(), com_previa: true, permitir: Some(false), remoto: None };
    let mut v = Vec::new();
    let mut manual = base.painel.clone();
    manual.registro.exposicao = ModoDeExposicao::Manual;
    manual.registro.iso = Some(64.0);
    manual.registro.obturador_ns = Some(regras::ns_do_log2(-7));
    manual.registro.balanco = Balanco::Kelvin;
    manual.registro.kelvin = Some(5600);
    manual.registro.foco = Foco::Manual;
    manual.registro.foco_posicao = Some(0.42);
    manual.registro.contraste = 25;
    manual.registro.gama = -40;
    manual.registro.contraluz = Some(regras::Contraluz::Ligada(true));
    manual.registro.zoom = Some(2.4);
    manual.divergencia = Some(regras::frase_da_divergencia(Propriedade::Exposicao, -6, -7));
    manual.controlado_por = Some("Pixel do Bruno".into()); // i18n: fora (exemplo)
    let mut travado = base.painel.clone();
    travado.registro.trava_exposicao = true;
    travado.registro.trava_balanco = true;
    let mut compartilhada = base.painel.clone();
    compartilhada.fase = FaseDosAjustes::Compartilhada;
    let lendo = PainelDosAjustes::default();
    let mut pobre = PainelDosAjustes { fase: FaseDosAjustes::Pronto, fps: 30.0, ..Default::default() };
    pobre.caps.insert(Propriedade::Brilho, faixa_(0, 255, 1, 128, regras::FLAGS_MANUAL));
    pobre.caps.insert(Propriedade::Foco, faixa_(0, 10, 1, 0, regras::FLAGS_AUTO));
    for com_previa in [true, false] {
        for aba in Aba::TODAS {
            for (nome, painel) in [("auto", &base.painel), ("manual", &manual), ("travado", &travado), ("compartilhada", &compartilhada), ("lendo", &lendo), ("pobre", &pobre)] {
                v.push((
                    format!("{}-{}-{nome}", if com_previa { "comum" } else { "r5" }, aba.indice()),
                    EstadoDosAjustes { aba, painel: painel.clone(), com_previa, permitir: Some(nome == "manual"), remoto: None },
                ));
            }
        }
    }
    v
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn o_id_de_cada_controle_volta() {
        let mut vistos = std::collections::HashSet::new();
        for c in ControleDosAjustes::todos() {
            assert_eq!(ControleDosAjustes::de_id(c.id()), Some(c), "{c:?}");
            assert!(vistos.insert(c.id()), "id repetido: {c:?}");
        }
        assert_eq!(ControleDosAjustes::de_id(1), None);
    }

    #[test]
    fn cada_aba_cabe_sem_rolar_e_nenhum_controle_cobre_outro() {
        for (nome, e) in exemplos() {
            let (l, a) = tamanho(&e);
            let janela = Ret::new(0.0, 0.0, l, a);
            let q = compor(&e);
            for x in &q.controles {
                assert!(janela.contem(&x.ret), "{nome}: {:?} fora da janela: {:?}", x.c, x.ret);
                if let Some(p) = q.previa {
                    assert!(!p.cruza(&x.ret), "{nome}: {:?} em cima da prévia", x.c);
                }
            }
            for (i, a_) in q.controles.iter().enumerate() {
                for b in q.controles.iter().skip(i + 1) {
                    assert!(!a_.ret.cruza(&b.ret), "{nome}: {:?} cobre {:?}", a_.c, b.c);
                }
            }
            for item in &q.itens {
                if let Item::Texto(t) = item {
                    assert!(janela.contem(&t.ret), "{nome}: texto fora: {:?}", t.texto_corrido());
                    for x in &q.controles {
                        assert!(!t.ret.cruza(&x.ret), "{nome}: o texto {:?} fica debaixo de {:?}", t.texto_corrido(), x.c);
                    }
                }
            }
        }
    }

    fn achar(nome: &str) -> EstadoDosAjustes {
        exemplos().into_iter().find(|(n, _)| n == nome).unwrap().1
    }

    fn textos(q: &QuadroDosAjustes) -> Vec<String> {
        q.itens.iter().filter_map(|i| if let Item::Texto(t) = i { Some(t.texto_corrido()) } else { None }).collect()
    }

    #[test]
    fn o_que_cada_aba_mostra() {
        use ControleDosAjustes as C;
        // Exposição em Auto: o brilho livre, a trava, a anti-cintilação.
        let q = compor(&achar("comum-0-auto"));
        assert!(q.achar(C::Brilho).unwrap().habilitado);
        assert!(q.achar(C::TravarExposicao).unwrap().habilitado);
        assert!(q.achar(C::Exposicao(0)).unwrap().marcado);
        assert!(q.achar(C::Cintilacao(0)).unwrap().marcado, "auto é o padrão");
        assert!(q.previa.is_some(), "a câmera comum tem a prévia dentro (§4.2)");
        // Travada (13/10): o brilho segue livre, sem a linha "Destrave…"; e em Manual também.
        let q = compor(&achar("comum-0-travado"));
        assert!(q.achar(C::Brilho).unwrap().habilitado);
        assert!(!textos(&q).contains(&"Destrave a exposição para compensar.".to_string()));
        assert!(compor(&achar("comum-0-manual")).achar(C::Brilho).unwrap().habilitado);
        // Ganho e obturador em Auto: a frase e o botão; em Manual, os dois deslizantes.
        let q = compor(&achar("comum-1-auto"));
        assert!(q.lugar(C::PassarParaManual).is_some() && q.lugar(C::Ganho).is_none());
        let q = compor(&achar("comum-1-manual"));
        assert!(q.lugar(C::Ganho).is_some() && q.lugar(C::Obturador).is_some());
        assert!(textos(&q).contains(&"1/128 s".to_string()));
        let d = q.achar(C::Obturador).unwrap().degraus.unwrap();
        assert_eq!(d.max, 7, "de −11 ao teto destravado a 30 fps (−4, 1/16 s; 13/10)");
        assert!(!textos(&q).iter().any(|t| t.starts_with("Acima de")), "1/128 s não alonga o quadro");
        // Travado, o teto é 1/30 (−5); destravado e acima de 1/fps, a linha diz que o fps cai.
        let mut travado = achar("comum-1-manual");
        travado.painel.registro.travar_fps = true;
        assert_eq!(compor(&travado).achar(C::Obturador).unwrap().degraus.unwrap().max, 6);
        let mut longo = achar("comum-1-manual");
        longo.painel.registro.obturador_ns = Some(regras::ns_do_log2(-3));
        let q = compor(&longo);
        assert!(textos(&q).contains(&"1/16 s".to_string()), "o aplicado, cortado no teto");
        assert!(textos(&q).contains(&"Acima de 1/32 s, a câmera baixa o fps.".to_string()));
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || {
            assert!(textos(&compor(&longo)).contains(&"Above 1/32 s, the camera lowers the frame rate.".to_string()));
        });
        travado.painel.registro.obturador_ns = Some(regras::ns_do_log2(-3));
        let q = compor(&travado);
        assert!(textos(&q).contains(&"1/32 s".to_string()) && !textos(&q).iter().any(|t| t.starts_with("Acima de")), "travado: no teto de 1/fps");
        // Balanço: os presets apagados com a linha; Kelvin com o deslizante e sem a trava.
        let q = compor(&achar("comum-2-auto"));
        assert!(!q.achar(C::Balanco(1)).unwrap().habilitado && q.achar(C::Balanco(5)).unwrap().habilitado);
        assert!(textos(&q).contains(&"Esta câmera não oferece os presets de balanço.".to_string()));
        assert!(q.lugar(C::TravarBalanco).is_some() && q.lugar(C::Kelvin).is_none());
        let q = compor(&achar("comum-2-manual"));
        assert!(q.lugar(C::Kelvin).is_some() && q.lugar(C::TravarBalanco).is_none(), "§3.4: com Kelvin a trava some");
        assert!(textos(&q).contains(&"5600 K".to_string()));
        // Foco manual: "Perto ↔ Longe" com 0,42.
        let q = compor(&achar("comum-3-manual"));
        assert!(textos(&q).contains(&"0,42".to_string()));
        assert_eq!(q.achar(C::FocoPosicao).unwrap().degraus, Some(Degraus { max: 100, pos: 42 }));
        // A divergência na linha do alto.
        assert!(textos(&q).iter().any(|t| t == "A câmera usou 1/64 s em vez de 1/128 s."));
        // Compartilhada: tudo apagado, com a frase do §3.5.
        let q = compor(&achar("comum-0-compartilhada"));
        assert!(q.controles.iter().filter(|x| !matches!(x.c, C::Aba(_) | C::PermitirRemoto)).all(|x| !x.habilitado));
        // A opção do remoto vale para o app: viva até no modo compartilhado (R9b).
        assert!(q.achar(C::PermitirRemoto).unwrap().habilitado);
        assert!(textos(&q).iter().any(|t| t == regras::FRASE_OUTRO_APP));
        // A câmera pobre: uma linha só onde nada se aplica.
        let q = compor(&achar("r5-1-pobre"));
        assert!(textos(&q).contains(&"Esta câmera não oferece o ganho e o obturador.".to_string()));
        assert!(q.previa.is_none(), "a R5 não tem prévia na janela (§4.2)");
        let q = compor(&achar("r5-2-pobre"));
        assert!(textos(&q).contains(&"Esta câmera não oferece o Kelvin.".to_string()));
        assert!(q.lugar(C::Balanco(0)).is_none(), "sem balanço, nada da grade");
        let q = compor(&achar("r5-3-pobre"));
        assert!(textos(&q).contains(&"Esta câmera não oferece o foco manual.".to_string()));
        let mut fixo = achar("r5-3-pobre");
        fixo.painel.caps.remove(&Propriedade::Foco);
        assert!(textos(&compor(&fixo)).contains(&"Esta câmera tem foco fixo.".to_string()));
        let q = compor(&achar("r5-0-pobre"));
        assert!(textos(&q).contains(&"Esta câmera não oferece a anti-cintilação.".to_string()));
        assert!(textos(&q).contains(&"Esta câmera não oferece a trava de exposição.".to_string()));
        assert!(q.achar(C::Restaurar).unwrap().habilitado);
        // "Usar meus ajustes" (07/10): só com lembrança diferente do que vale, ao lado do Restaurar.
        assert!(q.achar(C::UsarMeusAjustes).is_none(), "sem meus ajustes, sem botão");
        let mut com = achar("r5-0-pobre");
        com.painel.meus_ajustes = Some(crate::regras_dos_controles::Registro { ev: 1.0, ..Default::default() });
        let q2 = compor(&com);
        assert!(q2.achar(C::UsarMeusAjustes).is_some());
        com.painel.registro = com.painel.meus_ajustes.clone().unwrap();
        assert!(compor(&com).achar(C::UsarMeusAjustes).is_none(), "já vale: some");
        assert!(!compor(&achar("r5-0-lendo")).achar(C::Restaurar).unwrap().habilitado);
    }

    #[test]
    fn o_zoom_fica_fora_das_abas_e_acima_delas() {
        // 13/10: o zoom é o controle mais usado, e na aba "Foco" o Bruno não o achou (§3.8).
        use ControleDosAjustes as C;
        for nome in ["comum-0-auto", "comum-0-manual", "r5-0-auto"] {
            for aba in Aba::TODAS {
                let mut e = achar(nome);
                e.aba = aba;
                let q = compor(&e);
                let z = q.lugar(C::Zoom).unwrap_or_else(|| panic!("{nome}/{aba:?}: sem o zoom"));
                let aba0 = q.lugar(C::Aba(0)).unwrap();
                assert!(z.y + z.a <= aba0.y, "{nome}/{aba:?}: o zoom não está acima das abas");
                assert_eq!(z.l, lugar::COLUNA_L, "a largura da coluna");
                let (l, a) = tamanho(&e);
                let janela = Ret::new(0.0, 0.0, l, a);
                for x in &q.controles {
                    assert!(janela.contem(&x.ret), "{nome}/{aba:?}: {:?} fora da janela", x.c);
                }
            }
            // Sem zoom na câmera, nem a linha nem a altura.
            let mut sem = achar(nome);
            sem.painel.caps.remove(&Propriedade::Zoom);
            assert!(compor(&sem).lugar(C::Zoom).is_none());
        }
        // A ordem do Tab: o zoom antes das abas.
        let todos = ControleDosAjustes::todos();
        let pos = |c| todos.iter().position(|x| *x == c).unwrap();
        assert!(pos(C::Zoom) < pos(C::Aba(0)));
    }

    /// **O zoom do Quall** (§3.8.7, 14/10): a câmera sem zoom (a integrada do Dell) ganha a mesma linha,
    /// com o rótulo do recorte, e o deslizante vai de 1× ao teto.
    #[test]
    fn o_zoom_do_quall_tem_a_mesma_linha_com_o_rotulo_do_recorte() {
        use ControleDosAjustes as C;
        let mut e = achar("comum-0-auto");
        e.painel.caps.remove(&Propriedade::Zoom);
        assert!(compor(&e).lugar(C::Zoom).is_none());
        crate::zoom_do_quall::decidir(&mut e.painel.caps, Some(3.0));
        assert!(compor(&e).lugar(C::Zoom).is_some());
        crate::idioma::com_idioma(crate::idioma::Idioma::Pt, || assert_eq!(rotulo(C::Zoom, &e), "Zoom (recorte do Quall)"));
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || assert_eq!(rotulo(C::Zoom, &e), "Zoom (Quall crop)"));
        assert!(matches!(gesto(C::Zoom, &e, Some(regras::DEGRAUS_DO_ZOOM)), Some(Gesto::Acao(Acao::Zoom(z))) if z == 3.0));
        assert!(matches!(gesto(C::Zoom, &e, Some(0)), Some(Gesto::Acao(Acao::Zoom(z))) if z == 1.0));
        // A câmera com zoom de verdade fica com o rótulo de sempre.
        crate::idioma::com_idioma(crate::idioma::Idioma::Pt, || assert_eq!(rotulo(C::Zoom, &achar("comum-0-auto")), "Zoom"));
    }

    #[test]
    fn a_opcao_do_remoto_e_quem_controla() {
        use ControleDosAjustes as C;
        let q = compor(&achar("comum-0-manual"));
        let x = q.achar(C::PermitirRemoto).unwrap();
        assert!(x.marcado && x.habilitado);
        assert!(textos(&q).contains(&"Controlado por Pixel do Bruno".to_string()));
        let e = achar("comum-0-auto");
        assert!(!compor(&e).achar(C::PermitirRemoto).unwrap().marcado);
        assert!(matches!(gesto(C::PermitirRemoto, &e, None), Some(Gesto::Permitir(true))));
        // Sem prévia (a R5) a janela cresce a faixa; com ela, a faixa cabe embaixo do aviso. A câmera do
        // exemplo tem zoom: a linha dele (fora das abas, 13/10) cresce as duas.
        assert_eq!(tamanho(&achar("r5-0-auto")).1, lugar::ALTURA + lugar::ZOOM_A + lugar::FAIXA_DO_REMOTO_A);
        assert_eq!(tamanho(&e).1, lugar::ALTURA + lugar::ZOOM_A);
        let mut sem_zoom = e.clone();
        sem_zoom.painel.caps.remove(&Propriedade::Zoom);
        assert_eq!(tamanho(&sem_zoom).1, lugar::ALTURA, "sem zoom, a altura de sempre");
        // Sem a opção (a sonda sem rede), nada.
        let mut sem = e.clone();
        sem.permitir = None;
        assert!(compor(&sem).lugar(C::PermitirRemoto).is_none());
        assert_eq!(texto_acessivel(C::PermitirRemoto, &e), "Permitir controle remoto da câmera");
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || {
            assert_eq!(texto_acessivel(C::PermitirRemoto, &e), "Allow remote camera control");
            assert!(textos(&compor(&achar("r5-1-manual"))).contains(&"Controlled by Pixel do Bruno".to_string()));
        });
    }

    #[test]
    fn a_pouca_luz_na_linha_de_aviso() {
        use crate::regras_dos_controles::PoucaLuz;
        let luz = PoucaLuz { fps_agora: 15, fps: 30, com_manual: true, com_trava: false };
        let mut e = achar("comum-0-auto");
        assert!(!textos(&compor(&e)).iter().any(|t| t.starts_with("Pouca luz")), "sem pouca luz, sem aviso");
        e.painel.pouca_luz = Some(luz);
        let q = compor(&e);
        assert!(textos(&q).contains(&"Pouca luz: a câmera baixou para 15 fps para clarear a imagem. Para 30 fps, use a exposição manual nos ajustes da câmera, com o obturador até 1/32 s.".to_string()));
        assert!(q.itens.iter().any(|i| matches!(i, Item::Icone { icone: Icone::Info, .. })), "informação, no tom neutro");
        assert!(q.lugar(ControleDosAjustes::AcaoDaPoucaLuz).is_none(), "sem a trava, sem botão");
        // Na R5 (sem prévia) também, e sem obturador manual o conselho é a luz.
        let mut r5 = achar("r5-0-pobre");
        r5.painel.pouca_luz = Some(PoucaLuz { com_manual: false, ..luz });
        assert!(textos(&compor(&r5)).contains(&"Pouca luz: a câmera baixou para 15 fps para clarear a imagem. Mais luz no ambiente devolve os 30 fps.".to_string()));
        // A divergência e o modo compartilhado vêm antes: uma linha de aviso só.
        let mut manual = achar("comum-1-manual");
        manual.painel.pouca_luz = Some(luz);
        let t_ = textos(&compor(&manual));
        assert!(t_.iter().any(|t| t.starts_with("A câmera usou")) && !t_.iter().any(|t| t.starts_with("Pouca luz")));
        let mut compartilhada = achar("comum-0-compartilhada");
        compartilhada.painel.pouca_luz = Some(PoucaLuz { com_manual: false, ..luz });
        let t_ = textos(&compor(&compartilhada));
        assert!(t_.iter().any(|t| t == regras::FRASE_OUTRO_APP) && !t_.iter().any(|t| t.starts_with("Pouca luz")));
        // Com a trava (§3.1.1): a frase sem conselho e o botão "Travar em 30 fps" dentro da caixa.
        let mut com_trava = achar("comum-0-auto");
        com_trava.painel.trava_de_fps = true;
        com_trava.painel.pouca_luz = Some(PoucaLuz { com_trava: true, ..luz });
        let q = compor(&com_trava);
        assert!(textos(&q).contains(&"Pouca luz: a câmera baixou para 15 fps para clarear a imagem.".to_string()));
        let b = q.achar(ControleDosAjustes::AcaoDaPoucaLuz).expect("o botão");
        assert!(b.habilitado);
        assert_eq!(rotulo(ControleDosAjustes::AcaoDaPoucaLuz, &com_trava), "Travar em 30 fps");
        assert!(matches!(gesto(ControleDosAjustes::AcaoDaPoucaLuz, &com_trava, None), Some(Gesto::Acao(Acao::TravarFps(true)))));
        // A chave na aba Exposição, ligada pelo registro; em Manual também vale (o teto do obturador).
        let x = q.achar(ControleDosAjustes::TravarFps).expect("a chave");
        assert!(x.habilitado && !x.marcado);
        com_trava.painel.registro.travar_fps = true;
        assert!(compor(&com_trava).achar(ControleDosAjustes::TravarFps).unwrap().marcado);
        assert!(matches!(gesto(ControleDosAjustes::TravarFps, &com_trava, None), Some(Gesto::Acao(Acao::TravarFps(false)))));
        assert!(compor(&e).lugar(ControleDosAjustes::TravarFps).is_none(), "o driver sem a prioridade: sem a chave");
        // O aviso e a chave não cobrem controle nenhum, com e sem prévia (a R5, a mais apertada).
        let mut r5_trava = achar("r5-0-auto");
        r5_trava.painel.trava_de_fps = true;
        r5_trava.painel.pouca_luz = Some(PoucaLuz { com_trava: true, ..luz });
        for e in [e, r5, com_trava, r5_trava] {
            let q = compor(&e);
            for item in &q.itens {
                if let Item::Texto(t) = item {
                    for x in &q.controles {
                        assert!(!t.ret.cruza(&x.ret), "o texto {:?} fica debaixo de {:?}", t.texto_corrido(), x.c);
                    }
                }
            }
            for (i, a) in q.controles.iter().enumerate() {
                for b in &q.controles[i + 1..] {
                    assert!(!a.ret.cruza(&b.ret), "{:?} cobre {:?}", a.c, b.c);
                }
            }
        }
        // A frase com o botão cabe em duas linhas na caixa (PT e EN, as duas larguras).
        for idioma in [crate::idioma::Idioma::Pt, crate::idioma::Idioma::En] {
            crate::idioma::com_idioma(idioma, || {
                let f = PoucaLuz { com_trava: true, ..luz }.texto();
                for r in [lugar::AVISO_COM_PREVIA, lugar::AVISO_SEM_PREVIA] {
                    assert!(linhas_da_frase_do_aviso(&f, r.l) <= 2.0, "{f}");
                    assert!(r.a >= 8.0 + 36.0 + 4.0 + 28.0, "o botão cabe embaixo da frase");
                }
            });
        }
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || {
            let mut e = achar("comum-0-auto");
            e.painel.pouca_luz = Some(luz);
            assert!(textos(&compor(&e)).contains(&"Low light: the camera dropped to 15 fps to brighten the image. For 30 fps, use manual exposure in Camera settings, with the shutter at 1/32 s or faster.".to_string()));
            e.painel.pouca_luz = Some(PoucaLuz { com_trava: true, ..luz });
            assert_eq!(rotulo(ControleDosAjustes::AcaoDaPoucaLuz, &e), "Lock at 30 fps");
            assert_eq!(rotulo(ControleDosAjustes::TravarFps, &e), "Lock fps");
        });
    }

    #[test]
    fn os_gestos() {
        use ControleDosAjustes as C;
        let e = achar("comum-1-manual");
        let a = |c, d| match gesto(c, &e, d) {
            Some(Gesto::Acao(a)) => a,
            _ => panic!("{c:?}"),
        };
        assert_eq!(a(C::Obturador, Some(0)), Acao::Obturador(-11));
        assert_eq!(a(C::Obturador, Some(99)), Acao::Obturador(-4), "o teto destravado (13/10)");
        assert_eq!(a(C::Ganho, Some(50)), Acao::Ganho(50));
        assert_eq!(a(C::Kelvin, Some(0)), Acao::Kelvin(2800));
        assert_eq!(a(C::FocoPosicao, Some(42)), Acao::FocoPosicao(0.42));
        assert_eq!(a(C::Cintilacao(1), None), Acao::AntiCintilacao(AntiCintilacao::Hz50));
        assert_eq!(a(C::TravarExposicao, None), Acao::TravarExposicao(true));
        assert_eq!(a(C::Restaurar, None), Acao::Restaurar);
        assert!(matches!(gesto(C::Aba(2), &e, None), Some(Gesto::Aba(Aba::Balanco))));
        assert_eq!(texto_acessivel(C::Obturador, &e), "Obturador, 1/128 s");
        assert_eq!(texto_acessivel(C::Restaurar, &e), "Restaurar automático");
    }

    #[test]
    fn em_ingles() {
        use ControleDosAjustes as C;
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || {
            let e = achar("comum-1-manual");
            assert_eq!(texto_acessivel(C::Obturador, &e), "Shutter, 1/128 s");
            assert_eq!(texto_acessivel(C::Aba(1), &e), "Gain & shutter, tab");
            assert_eq!(texto_acessivel(C::Restaurar, &e), "Reset to auto");
            let q = compor(&achar("comum-3-manual"));
            assert!(textos(&q).contains(&"Near ↔ Far".to_string()));
            assert!(textos(&q).contains(&"0.42".to_string()));
            assert!(textos(&compor(&achar("r5-1-pobre"))).contains(&"This camera doesn't support gain and shutter.".to_string()));
        });
    }

    /// **A aba "Imagem"** (§3.7): só com algum ajuste de imagem; só o que a câmera oferece; vale em
    /// qualquer exposição; os gestos andam de -100 a 100 (a nitidez, de 0 a 100).
    #[test]
    fn a_aba_imagem() {
        use ControleDosAjustes as C;
        let q = compor(&achar("comum-4-manual"));
        assert!(q.lugar(C::Aba(4)).is_some());
        for i in 0..4 {
            assert!(q.achar(C::Imagem(i)).is_some_and(|x| x.habilitado), "Imagem({i}) viva em Manual");
        }
        let t_ = textos(&q);
        assert!(t_.contains(&"+25".to_string()) && t_.contains(&"-40".to_string()), "{t_:?}");
        assert!(t_.contains(&"Gama".to_string()) && t_.contains(&"Nitidez".to_string()));
        let x = q.achar(C::Contraluz).unwrap();
        assert!(x.marcado && x.habilitado);
        assert_eq!(q.achar(C::Imagem(1)).unwrap().degraus, Some(Degraus { max: 200, pos: 125 }));
        assert_eq!(q.achar(C::Imagem(3)).unwrap().degraus, Some(Degraus { max: 100, pos: 0 }), "a nitidez de 0 a 100");
        // Os gestos.
        let e = achar("comum-4-manual");
        let a = |c, d| match gesto(c, &e, d) {
            Some(Gesto::Acao(a)) => a,
            _ => panic!("{c:?}"),
        };
        assert_eq!(a(C::Imagem(1), Some(150)), Acao::Imagem(Propriedade::Contraste, 50));
        assert_eq!(a(C::Imagem(3), Some(30)), Acao::Imagem(Propriedade::Nitidez, 30));
        assert_eq!(a(C::Contraluz, None), Acao::Contraluz(Some(regras::Contraluz::Ligada(false))));
        assert_eq!(texto_acessivel(C::Imagem(1), &e), "Contraste, +25");
        // A contraluz do padrão da câmera mostra o lido.
        let auto = achar("comum-4-auto");
        assert!(!compor(&auto).achar(C::Contraluz).unwrap().marcado);
        // A contraluz em níveis vira deslizante.
        let mut niveis = achar("comum-4-auto");
        niveis.painel.caps.insert(Propriedade::Contraluz, faixa_(0, 3, 1, 1, regras::FLAGS_MANUAL));
        niveis.painel.lidos.insert(Propriedade::Contraluz, regras::Lido { valor: 1, bandeiras: regras::FLAGS_MANUAL });
        let q = compor(&niveis);
        assert!(q.lugar(C::Contraluz).is_none());
        assert_eq!(q.achar(C::ContraluzNivel).unwrap().degraus, Some(Degraus { max: 3, pos: 1 }));
        assert!(matches!(gesto(C::ContraluzNivel, &niveis, Some(2)), Some(Gesto::Acao(Acao::Contraluz(Some(regras::Contraluz::Nivel(2)))))));
        // A câmera sem nenhum: a aba some; a pobre não tem nenhum.
        let q = compor(&achar("r5-0-pobre"));
        assert!(q.lugar(C::Aba(4)).is_none() && q.lugar(C::Aba(3)).is_some());
        assert!(textos(&compor(&achar("r5-4-pobre"))).contains(&"Esta câmera não oferece os ajustes de imagem.".to_string()));
        // Só a gama: a aba com um deslizante.
        let mut so_gama = achar("r5-4-pobre");
        so_gama.painel.caps.insert(Propriedade::Gama, faixa_(1, 9, 1, 5, regras::FLAGS_MANUAL));
        let q = compor(&so_gama);
        assert!(q.lugar(C::Imagem(0)).is_some() && q.lugar(C::Imagem(1)).is_none() && q.lugar(C::Contraluz).is_none());
        crate::idioma::com_idioma(crate::idioma::Idioma::En, || {
            let e = achar("comum-4-manual");
            assert_eq!(rotulo(C::Aba(4), &e), "Picture");
            assert_eq!(rotulo(C::Contraluz, &e), "Backlight compensation");
            assert!(textos(&compor(&e)).contains(&"Saturation".to_string()));
        });
    }
}
