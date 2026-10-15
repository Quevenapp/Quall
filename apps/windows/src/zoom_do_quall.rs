//! **O zoom digital do Quall no Windows: a parte que é aritmética** (`docs/controles-de-camera.md`
//! §3.8.7, 14/10; o molde é o do Mac, §3.8.4, `QuallCaptureKit/ZoomDoQuall.swift`).
//!
//! > Relato do Bruno no Dell (14/10): "No Dell não tem a barra de zoom ainda." A câmera integrada
//! > não declara `CameraControl_Zoom` (o diário: `ajustes: nao se aplica prop=zoom`).
//!
//! **Quando a câmera não dá zoom (e só então)**, o Quall oferece o dele: o **centro** do quadro,
//! recortado em pixels pares e ampliado de volta ao tamanho da câmera, na GPU do dono da captura
//! (`zoom_na_gpu.rs`), **antes** das saídas (a rede, a gravação, a prévia). A câmera com zoom de
//! hardware continua no hardware (§3.8.2).
//!
//! - **O teto** é o que a imagem aguenta: o recorte não desce de [`LINHAS_MINIMAS`] linhas da
//!   câmera (1080p: 3×; 720p: 2×; 480p: 1,3×), nunca acima de [`TETO_ABSOLUTO`], e abaixo de
//!   [`FAIXA_MINIMA`] de faixa não se oferece. As mesmas contas do Mac.
//! - **As paradas**: 1×, 2× e 3× dentro da faixa; **as ópticas**: `[1]` (o 1× é o sensor inteiro).
//! - **No registro do R9**, o zoom do Quall é uma faixa sintética em [`Propriedade::Zoom`]
//!   ([`faixa`], com [`regras::FLAGS_DO_QUALL`]): de 100 a 100 × o teto, o padrão em 100. Tudo o
//!   que já existia para o zoom (o corte, o deslizante logarítmico, o fio, "meus ajustes" sem o
//!   zoom) vale sem caso novo; só não vai ao driver (`regras::desejado`).
//! - **O ponto no sensor** ([`ponto_no_sensor`]): um toque na imagem ampliada volta ao sensor pelo
//!   recorte, `0,5 + (p − 0,5) / z`. O Windows não tem toque de foco hoje (a webcam UVC não tem
//!   ponto de interesse: `regras_da_camera_remota`, `toque` nunca oferecido); a conta fica aqui para
//!   quando houver, e o teste a prende.

use crate::regras_dos_controles::{self as regras, Capacidades, Faixa, Propriedade};

/// O recorte nunca fica com menos linhas da câmera do que isto.
pub const LINHAS_MINIMAS: f64 = 360.0;
/// O teto do zoom do Quall, qualquer que seja a imagem.
pub const TETO_ABSOLUTO: f64 = 4.0;
/// Abaixo disto de faixa, o zoom do Quall não é oferecido (480p dá 1,3×; 400 linhas, 1,1×: não).
pub const FAIXA_MINIMA: f64 = 1.2;

/// **O teto do zoom do Quall** numa câmera de `altura` linhas, ao décimo para baixo; `None` quando não
/// chega a [`FAIXA_MINIMA`].
pub fn maximo(altura: u32) -> Option<f64> {
    if altura == 0 {
        return None;
    }
    let m = TETO_ABSOLUTO.min((f64::from(altura) / LINHAS_MINIMAS * 10.0 + 1e-9).floor() / 10.0);
    (m >= FAIXA_MINIMA).then_some(m)
}

/// Os botões rápidos (§3.8): 1×, 2× e 3× até o teto.
pub fn paradas(maximo: f64) -> Vec<f64> {
    [1.0, 2.0, 3.0].into_iter().filter(|z| *z <= maximo + 0.001).collect()
}

/// **A faixa sintética** do zoom do Quall até `maximo`: o fator × 100, o 1× no padrão. Com ela,
/// `regras::escala_do_zoom` dá `(1, maximo)` e `regras::zoom_no_driver` dá o fator em centésimos.
pub fn faixa(maximo: f64) -> Faixa {
    let max = (maximo * 100.0).round() as i32;
    Faixa { min: 100, max: max.max(100), passo: 1, padrao: 100, bandeiras: regras::FLAGS_MANUAL | regras::FLAGS_DO_QUALL }
}

/// O que a abertura decidiu sobre o zoom, para o diário e para a thread.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum DecisaoDoZoom {
    /// A câmera declara zoom: ele fica no hardware (§3.8.2).
    DaCamera,
    /// A câmera não dá zoom e o Quall oferece o dele, até o teto.
    DoQuall(f64),
    /// Nem a câmera nem o Quall: a imagem não aguenta (o teto abaixo de [`FAIXA_MINIMA`]), a placa não
    /// recorta este formato, ou a câmera não é do dono (`teto` ausente).
    Nenhum,
}

/// **A decisão da abertura**: com a câmera sem zoom utilizável e um `teto` (o dono da captura sabe
/// recortar este formato nesta placa, e a imagem aguenta), o zoom do Quall entra em `caps` no lugar do
/// zoom do driver (que, se veio, não servia: só Auto, ou uma faixa de um valor só).
pub fn decidir(caps: &mut Capacidades, teto: Option<f64>) -> DecisaoDoZoom {
    if caps.get(&Propriedade::Zoom).and_then(regras::escala_do_zoom).is_some() {
        return DecisaoDoZoom::DaCamera;
    }
    match teto.filter(|t| t.is_finite() && *t >= FAIXA_MINIMA) {
        Some(t) => {
            caps.insert(Propriedade::Zoom, faixa(t));
            DecisaoDoZoom::DoQuall(t)
        }
        None => DecisaoDoZoom::Nenhum,
    }
}

/// **O zoom do Quall que vale agora**, das capacidades e do fator do registro: `None` sem o zoom do
/// Quall, ou em 1× (o quadro passa como veio).
pub fn em_uso(caps: &Capacidades, z: f64) -> Option<f64> {
    let f = caps.get(&Propriedade::Zoom).filter(|f| f.do_quall())?;
    let z = regras::cortar_zoom(z, f)?;
    (z > 1.001).then_some(z)
}

/// **O recorte central**: `(x, y, largura, altura)` em pixels **pares** (o NV12 e o YUY2 andam de
/// dois em dois), dentro do quadro de `largura × altura`. Em 1× (ou num quadro pequeno demais), o
/// quadro inteiro.
pub fn recorte(largura: u32, altura: u32, z: f64) -> (u32, u32, u32, u32) {
    if !z.is_finite() || z <= 1.001 || largura < 4 || altura < 4 {
        return (0, 0, largura, altura);
    }
    let par = |v: f64| ((v / 2.0).round() as u32 * 2).max(2);
    let l = par(f64::from(largura) / z).min(largura);
    let a = par(f64::from(altura) / z).min(altura);
    let x = ((largura - l) / 2) & !1;
    let y = ((altura - a) / 2) & !1;
    (x, y, l, a)
}

/// **Um ponto da imagem ampliada no sensor** (0 a 1 nos dois eixos): o recorte é central, então o
/// espelho da prévia não muda a conta.
pub fn ponto_no_sensor(p: (f64, f64), z: f64) -> (f64, f64) {
    if !z.is_finite() || z <= 1.001 {
        return p;
    }
    (0.5 + (p.0 - 0.5) / z, 0.5 + (p.1 - 0.5) / z)
}

/// A linha do diário da decisão.
pub fn linha_da_decisao(d: DecisaoDoZoom, altura: u32, teto: Option<f64>) -> String {
    match d {
        DecisaoDoZoom::DaCamera => "ajustes: zoom: o da câmera (CameraControl_Zoom); o Quall não recorta".to_string(),
        DecisaoDoZoom::DoQuall(t) => format!(
            "ajustes: zoom: a câmera não oferece; o zoom do Quall (recorte central na GPU do dono) vai de 1× a {}× em {altura} linhas, paradas {:?}",
            t,
            paradas(t)
        ),
        DecisaoDoZoom::Nenhum => match teto {
            None => format!("ajustes: zoom: nem a câmera nem o Quall (o recorte não foi oferecido nesta abertura; {altura} linhas)"),
            Some(t) => format!("ajustes: zoom: nem a câmera nem o Quall (o teto de {t}× em {altura} linhas fica abaixo de {FAIXA_MINIMA}×)"),
        },
    }
}

#[cfg(test)]
mod testes {
    use super::*;

    /// **O teto** (o mesmo do Mac): 1080p 3×, 720p 2×, 480p 1,3×, 4K no teto absoluto; abaixo de
    /// 1,2× de faixa, nada.
    #[test]
    fn o_teto_e_o_que_a_imagem_aguenta() {
        assert_eq!(maximo(1080), Some(3.0));
        assert_eq!(maximo(720), Some(2.0));
        assert_eq!(maximo(480), Some(1.3));
        assert_eq!(maximo(2160), Some(4.0));
        assert_eq!(maximo(1440), Some(4.0));
        assert_eq!(maximo(400), None, "1,1× não se oferece");
        assert_eq!(maximo(0), None);
        assert_eq!(paradas(3.0), vec![1.0, 2.0, 3.0]);
        assert_eq!(paradas(2.0), vec![1.0, 2.0]);
        assert_eq!(paradas(1.3), vec![1.0]);
        assert_eq!(paradas(4.0), vec![1.0, 2.0, 3.0]);
    }

    /// **A faixa sintética** passa pelas contas de sempre do zoom: a escala, o corte e o fio em
    /// centésimos; e **não vai ao driver** (nem no plano, nem na normalização da abertura).
    #[test]
    fn a_faixa_sintetica_usa_as_contas_do_zoom_e_nao_vai_ao_driver() {
        let f = faixa(3.0);
        assert!(f.do_quall() && f.tem_manual() && !f.tem_auto());
        assert_eq!(regras::escala_do_zoom(&f), Some((1.0, 3.0)));
        assert_eq!(regras::cortar_zoom(2.456, &f), Some(2.46));
        assert_eq!(regras::cortar_zoom(9.0, &f), Some(3.0));
        assert_eq!(regras::zoom_no_driver(2.4, &f), 240);
        assert_eq!(regras::zoom_do_driver(240, &f), 2.4);
        assert_eq!(regras::paradas_da_faixa(&f), vec![1.0, 2.0, 3.0]);
        let mut caps = Capacidades::new();
        caps.insert(Propriedade::Zoom, f);
        let r = regras::Registro { zoom: Some(2.0), ..Default::default() };
        assert!(regras::desejado(&r, &caps, 30.0).is_empty(), "o zoom do Quall não é um Set");
        assert!(regras::plano(&r, &caps, 30.0, &regras::Lidos::new(), &Default::default()).is_empty());
        let mut lidos = regras::Lidos::new();
        lidos.insert(Propriedade::Zoom, regras::Lido { valor: 240, bandeiras: regras::FLAGS_MANUAL });
        assert!(regras::normalizacao_da_abertura(&r, &caps, 30.0, &lidos).is_empty());
    }

    /// **A decisão**: a câmera com zoom fica com o dela; sem zoom (ou com um que não serve) e com teto,
    /// o do Quall; sem teto, nada.
    #[test]
    fn so_sem_o_zoom_da_camera() {
        let mut com = Capacidades::new();
        com.insert(Propriedade::Zoom, Faixa { min: 100, max: 500, passo: 1, padrao: 100, bandeiras: regras::FLAGS_MANUAL });
        assert_eq!(decidir(&mut com, Some(3.0)), DecisaoDoZoom::DaCamera);
        assert!(!com[&Propriedade::Zoom].do_quall());
        let mut sem = Capacidades::new();
        assert_eq!(decidir(&mut sem, Some(3.0)), DecisaoDoZoom::DoQuall(3.0));
        assert!(sem[&Propriedade::Zoom].do_quall());
        // O driver que declara zoom só em Auto (ou de um valor só) não serve: o do Quall entra no lugar.
        let mut so_auto = Capacidades::new();
        so_auto.insert(Propriedade::Zoom, Faixa { min: 100, max: 500, passo: 1, padrao: 100, bandeiras: regras::FLAGS_AUTO });
        assert_eq!(decidir(&mut so_auto, Some(2.0)), DecisaoDoZoom::DoQuall(2.0));
        let mut nada = Capacidades::new();
        assert_eq!(decidir(&mut nada, None), DecisaoDoZoom::Nenhum);
        assert_eq!(decidir(&mut nada, Some(1.1)), DecisaoDoZoom::Nenhum);
        assert!(nada.is_empty());
        // O que vale agora.
        assert_eq!(em_uso(&sem, 1.0), None, "em 1× o quadro passa como veio");
        assert_eq!(em_uso(&sem, 2.5), Some(2.5));
        assert_eq!(em_uso(&sem, 7.0), Some(3.0), "cortado no teto");
        assert_eq!(em_uso(&com, 2.5), None, "o zoom da câmera não é recortado");
    }

    /// **O recorte** é central, em pixels pares, e o 1× é o quadro inteiro.
    #[test]
    fn o_recorte_e_central_e_par() {
        assert_eq!(recorte(1920, 1080, 1.0), (0, 0, 1920, 1080));
        assert_eq!(recorte(1920, 1080, 2.0), (480, 270, 960, 540));
        let (x, y, l, a) = recorte(1280, 720, 1.7);
        assert!(x % 2 == 0 && y % 2 == 0 && l % 2 == 0 && a % 2 == 0, "{x} {y} {l} {a}");
        assert!(x + l <= 1280 && y + a <= 720);
        assert!((i64::from(x) - i64::from(1280 - x - l)).abs() <= 2, "centrado na largura");
        assert!((i64::from(y) - i64::from(720 - y - a)).abs() <= 2, "centrado na altura");
        assert_eq!(recorte(1920, 1080, 3.0), (640, 360, 640, 360), "o teto de 1080p: 360 linhas");
        assert_eq!(recorte(2, 2, 3.0), (0, 0, 2, 2));
    }

    /// **O ponto no sensor**: o centro fica no centro; a borda da imagem ampliada cai dentro do recorte.
    #[test]
    fn o_toque_volta_ao_sensor_pelo_recorte() {
        assert_eq!(ponto_no_sensor((0.5, 0.5), 3.0), (0.5, 0.5));
        assert_eq!(ponto_no_sensor((0.0, 1.0), 2.0), (0.25, 0.75));
        assert_eq!(ponto_no_sensor((0.2, 0.3), 1.0), (0.2, 0.3));
    }
}
