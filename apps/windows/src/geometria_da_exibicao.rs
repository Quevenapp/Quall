//! **De onde a janela tira a imagem**, quadro a quadro: a aritmética do retângulo de origem do
//! Video Processor da exibição (`present.rs`), sem Win32, para ser testada em qualquer máquina.
//!
//! # O defeito que isto conserta (o G1 da crítica de 21/09, medido no controle da troca)
//!
//! O `Presenter` nascia com a largura e a altura do primeiro SPS e usava esse retângulo como
//! origem em **todo** quadro. Quando o fluxo trocava de tamanho no meio da sessão, o decoder
//! renegociava (`MF_E_TRANSFORM_STREAM_CHANGE`) e a exibição relia a abertura, mas a origem
//! continuava a do primeiro SPS. O controle de 21/09 (`.h264` sintético 854×480 → 640×480 → 854×480
//! mandado ao app de hoje, no Dell) mostrou os dois sentidos:
//! - **descendo, de 854 para 640**: a origem de 854 passava da textura de 640 e o `present_frame`
//!   falhava com `0x80070057` (parâmetro incorreto) em todo quadro. A janela ficou parada na última
//!   imagem de 854 enquanto o fluxo esteve em 640, e voltou a andar quando ele voltou a 854;
//! - **subindo, de 640 para 854** (uma sessão que abre em 640): a origem de 640 cabia na textura
//!   de 864 e pegava só as 640 colunas da esquerda. Esse retângulo esticado no destino 16:9 dava uma
//!   imagem **cortada à direita e esticada**, sem erro nenhum. É um cenário lido no código, sem
//!   medida.
//!
//! O passo 11 do `anel` (21/09, no Dell) disse qual chamada recusava: o `VideoProcessorBlt`, com a
//! origem de 854 numa textura de 640 (`0x80070057`). A vista de entrada com o enumerador de 854
//! aceita a textura de 640.
//!
//! O conserto é pedir a origem **por quadro**: a abertura visível que o decoder declarou
//! (`MF_MT_MINIMUM_DISPLAY_APERTURE`), recortada ao tamanho da textura que chegou. Uma origem
//! nunca passa da textura, qualquer que seja a ordem em que o tipo e a textura mudarem.

/// Um retângulo em pixels, `(esquerda, topo, direita, base)`, como o `RECT` do Win32.
pub type Retangulo = (i32, i32, i32, i32);

/// **A origem da apresentação**: a abertura visível, recortada à textura. `None` quando não sobra
/// área (uma abertura fora da textura, ou uma textura vazia): o quadro não é apresentado, e o
/// chamador conta e segue.
pub fn origem_na_textura(visivel: Retangulo, textura: (u32, u32)) -> Option<Retangulo> {
    let (tl, ta) = (textura.0.min(i32::MAX as u32) as i32, textura.1.min(i32::MAX as u32) as i32);
    let esquerda = visivel.0.clamp(0, tl);
    let topo = visivel.1.clamp(0, ta);
    let direita = visivel.2.clamp(0, tl);
    let base = visivel.3.clamp(0, ta);
    (direita > esquerda && base > topo).then_some((esquerda, topo, direita, base))
}

/// O tamanho de um retângulo.
pub fn tamanho(r: Retangulo) -> (u32, u32) {
    ((r.2 - r.0).max(0) as u32, (r.3 - r.1).max(0) as u32)
}

/// **Onde a imagem cai dentro do buffer**: o maior retângulo com a proporção do `conteudo`, centrado
/// no `alvo`; o resto fica preto (as faixas). É a conta de `present::aspect_fit`, aqui para ser
/// testada: a prova de que a imagem não é espremida é que este retângulo tem a proporção do vídeo
/// **e** o buffer tem o tamanho do cliente (`Exibicao::bombear` o redimensiona a cada mudança).
pub fn destino_na_proporcao(conteudo: (u32, u32), alvo: (u32, u32)) -> Retangulo {
    let (cw, ch, tw, th) = (conteudo.0, conteudo.1, alvo.0, alvo.1);
    if cw == 0 || ch == 0 || tw == 0 || th == 0 {
        return (0, 0, tw as i32, th as i32);
    }
    let c = cw as f64 / ch as f64;
    let t = tw as f64 / th as f64;
    let (w, h) = if c > t { (tw as f64, tw as f64 / c) } else { (th as f64 * c, th as f64) };
    let x = ((tw as f64 - w) / 2.0).round() as i32;
    let y = ((th as f64 - h) / 2.0).round() as i32;
    (x, y, x + w.round() as i32, y + h.round() as i32)
}

// ---------------------------------------------------------------------------------------------
// O tamanho e o lugar da janela de vídeo: uma prévia
// ---------------------------------------------------------------------------------------------
//
// # Os dois relatos que isto responde
//
// **12/10, primeiro relato: a janela abria maior que a tela.** No `93b45a82` o cliente era o quadro
// vezes a escala (`exibicao.rs:354-356`, `--escala-do-video` 1,0 de padrão), criado em
// `CW_USEDEFAULT` (`present.rs:84-97`). O processo é Per-Monitor V2, então 1080 × 1920 eram 1920 px
// físicos de altura.
//
// **12/10, segundo relato: "filmando na vertical, a tela saiu quadrada, espremida".** É o mesmo
// defeito visto por dentro. O Windows não deixa uma janela nova passar muito do monitor (o
// `ptMaxTrackSize` do `WM_GETMINMAXINFO` é da ordem da tela mais a moldura), então a janela de
// 1080 × 1959 nascia cortada na altura — um cliente da ordem de 1080 × 745 num 1366 × 768 —,
// enquanto a swap chain nascia com 1080 × 1920 (`present.rs:225`, do tamanho **pedido**, não do
// que a janela ganhou) e sem `Scaling` na descrição, isto é, `DXGI_SCALING_STRETCH`. O
// `aspect_fit` (`exibicao.rs:714`) encaixava a imagem certinho no buffer de 1080 × 1920, e o DXGI
// esticava o buffer inteiro no cliente achatado: a imagem em pé virava quase quadrada. Arrastar a
// borda dava o mesmo, em qualquer orientação. Desde o `641a5164` a swap chain segue o cliente a
// cada quadro (`Exibicao::bombear`), e o encaixe usa o tamanho do buffer de agora.
//
// **12/10, pedido do Bruno: "a janela do Windows precisa ser um preview apenas, uma janela pequena
// com botão fullscreen".** A janela nasce pequena ([`cliente_da_previa`]) no canto de baixo à
// direita da área útil ([`canto_da_previa`]), e a tela cheia é um botão sobre o vídeo, F11, Esc e
// o duplo clique ([`TelaCheia`]).
//
// # Por que estes números
//
// - **30 % da área útil no eixo do lado maior do vídeo.** Um vídeo deitado mede pela largura do
//   monitor, um em pé pela altura: assim um celular em pé não vira uma tira de 30 % da largura.
// - **Piso de 360 DIP**: abaixo disso um rosto num celular em pé deixa de ser reconhecível, e a
//   barra de título (o arrasto, o fechar) fica mais larga que o vídeo. Num notebook de 1366 × 768,
//   30 % dariam 328 DIP, então o piso é que manda ali.
// - **Teto de 640 DIP**: num 4K a 150 %, 30 % dariam 768 DIP — já não é prévia, cobre metade da
//   tela de trabalho. 640 DIP é o lado de uma prévia de 640 × 360, o tamanho clássico de "pequeno"
//   em vídeo.
// - **O canto de baixo à direita**, com 16 DIP de margem: a janela principal do Quall (880 × 580
//   DIP) abre no meio do monitor e mostra os números da sessão no painel "Exibindo"; uma prévia no
//   meio cobriria exatamente esse painel. É o lugar de imagem-sobre-imagem dos players.
// - O teto absoluto continua [`FRACAO_DA_AREA_UTIL`] (com a moldura), para o piso nunca empurrar a
//   janela para fora de um monitor pequeno a 200 %.

/// A fração da área útil que a janela de vídeo (com a moldura) ocupa no máximo, em cada eixo.
pub const FRACAO_DA_AREA_UTIL: f64 = 0.85;
/// O lado maior da prévia, como fração da área útil no mesmo eixo.
pub const FRACAO_DA_PREVIA: f64 = 0.30;
/// O piso e o teto do lado maior da prévia, em DIP (pixels a 96 dpi).
pub const PREVIA_MINIMA_DIP: f64 = 360.0;
pub const PREVIA_MAXIMA_DIP: f64 = 640.0;
/// A distância da prévia às bordas da área útil, em DIP.
pub const MARGEM_DA_PREVIA_DIP: f64 = 16.0;

/// DIP em pixels físicos no `dpi` dado.
pub fn em_pixels(dpi: u32, dip: f64) -> f64 {
    dip * dpi.max(96) as f64 / 96.0
}

/// O que a moldura do Windows soma ao cliente em cada lado, em pixels físicos, no DPI do monitor:
/// o retângulo que `AdjustWindowRectExForDpi` devolve para um cliente vazio, com o sinal tirado.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Moldura {
    pub esquerda: i32,
    pub topo: i32,
    pub direita: i32,
    pub base: i32,
}

impl Moldura {
    /// A partir do retângulo de `AdjustWindowRectExForDpi` sobre `(0, 0, 0, 0)`.
    pub fn do_ajuste(r: Retangulo) -> Moldura {
        Moldura { esquerda: (-r.0).max(0), topo: (-r.1).max(0), direita: r.2.max(0), base: r.3.max(0) }
    }
    pub fn largura(&self) -> i32 {
        self.esquerda + self.direita
    }
    pub fn altura(&self) -> i32 {
        self.topo + self.base
    }
}

/// O vídeo, ou 16:9 quando ele não tem tamanho (o SPS que não disse): a janela nasce assim mesmo.
fn com_tamanho(video: (u32, u32)) -> (u32, u32) {
    if video.0 == 0 || video.1 == 0 {
        (1280, 720)
    } else {
        video
    }
}

/// Um cliente desejado (com a proporção já certa), encolhido por igual até a janela inteira
/// (cliente + `moldura`) caber em [`FRACAO_DA_AREA_UTIL`] da `area_util`. Nunca amplia.
fn caber(desejado: (f64, f64), area_util: Retangulo, moldura: Moldura) -> (u32, u32) {
    let (dw, dh) = (desejado.0.max(1.0), desejado.1.max(1.0));
    let (aw, ah) = tamanho(area_util);
    let limite_w = ((aw as f64 * FRACAO_DA_AREA_UTIL).floor() - moldura.largura() as f64).max(1.0);
    let limite_h = ((ah as f64 * FRACAO_DA_AREA_UTIL).floor() - moldura.altura() as f64).max(1.0);
    let s = (limite_w / dw).min(limite_h / dh).min(1.0);
    let w = (dw * s).round().clamp(1.0, limite_w);
    let h = (dh * s).round().clamp(1.0, limite_h);
    (w as u32, h as u32)
}

/// O cliente com o `lado` maior dado e a proporção do `video`.
fn com_lado_maior(video: (u32, u32), lado: f64) -> (f64, f64) {
    let (vw, vh) = com_tamanho(video);
    let r = vw as f64 / vh as f64;
    if vw >= vh {
        (lado, lado / r)
    } else {
        (lado * r, lado)
    }
}

/// **O cliente da prévia**: o lado maior do vídeo em [`FRACAO_DA_PREVIA`] da área útil no mesmo
/// eixo, entre [`PREVIA_MINIMA_DIP`] e [`PREVIA_MAXIMA_DIP`] no `dpi` do monitor, vezes a `escala`
/// de bancada, na proporção do vídeo, e nunca passando de [`FRACAO_DA_AREA_UTIL`] com a moldura.
///
/// A resolução do vídeo não entra, só a proporção: a prévia de um 720p e a de um 4K têm o mesmo
/// tamanho.
pub fn cliente_da_previa(video: (u32, u32), escala: f64, area_util: Retangulo, moldura: Moldura, dpi: u32) -> (u32, u32) {
    let (vw, vh) = com_tamanho(video);
    let (aw, ah) = tamanho(area_util);
    let eixo = if vw >= vh { aw } else { ah } as f64;
    let escala = if escala.is_finite() && escala > 0.0 { escala } else { 1.0 };
    let lado = (FRACAO_DA_PREVIA * eixo).clamp(em_pixels(dpi, PREVIA_MINIMA_DIP), em_pixels(dpi, PREVIA_MAXIMA_DIP)) * escala;
    caber(com_lado_maior((vw, vh), lado), area_util, moldura)
}

/// **O cliente depois de um giro** (o celular passou de em pé a deitado, ou o contrário): o mesmo
/// lado maior do cliente de agora — a prévia continua pequena, e a janela que a pessoa aumentou
/// continua grande — na proporção nova, dentro do teto.
pub fn cliente_girado(cliente_agora: (u32, u32), video_novo: (u32, u32), area_util: Retangulo, moldura: Moldura) -> (u32, u32) {
    let lado = cliente_agora.0.max(cliente_agora.1).max(1) as f64;
    caber(com_lado_maior(video_novo, lado), area_util, moldura)
}

/// O canto de baixo à direita da área útil, recuado [`MARGEM_DA_PREVIA_DIP`]: onde a prévia nasce.
pub fn canto_da_previa(area_util: Retangulo, dpi: u32) -> (i32, i32) {
    let m = em_pixels(dpi, MARGEM_DA_PREVIA_DIP).round() as i32;
    (area_util.2 - m, area_util.3 - m)
}

/// **A janela inteira (cliente + moldura) com o canto de baixo à direita em `canto`**, empurrada
/// para dentro da `area_util`. Uma janela maior que a área encosta em cima à esquerda, onde ficam a
/// barra de título e os botões.
pub fn janela_ancorada(cliente: (u32, u32), moldura: Moldura, area_util: Retangulo, canto: (i32, i32)) -> Retangulo {
    let w = cliente.0 as i32 + moldura.largura();
    let h = cliente.1 as i32 + moldura.altura();
    let encaixe = |fim_pedido: i32, lado: i32, inicio: i32, fim: i32| {
        if lado >= fim - inicio {
            inicio
        } else {
            (fim_pedido - lado).clamp(inicio, fim - lado)
        }
    };
    let esquerda = encaixe(canto.0, w, area_util.0, area_util.2);
    let topo = encaixe(canto.1, h, area_util.1, area_util.3);
    (esquerda, topo, esquerda + w, topo + h)
}

/// Um retângulo de janela trazido para dentro da `area_util`, com o tamanho dele (cortado ao da
/// área, se for maior): a volta da tela cheia para um monitor que mudou enquanto isso.
pub fn devolver_para_dentro(r: Retangulo, area_util: Retangulo) -> Retangulo {
    let (rw, rh) = tamanho(r);
    let (aw, ah) = tamanho(area_util);
    let (w, h) = (rw.min(aw) as i32, rh.min(ah) as i32);
    let esquerda = r.0.clamp(area_util.0, area_util.2 - w);
    let topo = r.1.clamp(area_util.1, area_util.3 - h);
    (esquerda, topo, esquerda + w, topo + h)
}

/// **A imagem virou de pé para deitada, ou o contrário** (o celular girou no meio da sessão e o
/// emissor refez o codificador na dimensão nova). É quando a janela se reencaixa: ela tinha o
/// formato da orientação antiga, e o quadro novo ficaria numa faixa no meio dela. Uma troca de
/// tamanho na mesma orientação (a taxa que desce de 1080p para 720p) não mexe na janela que a
/// pessoa ajustou.
pub fn mudou_de_orientacao(antes: (u32, u32), depois: (u32, u32)) -> bool {
    let deitada = |t: (u32, u32)| t.0 > t.1;
    antes.0 > 0 && antes.1 > 0 && depois.0 > 0 && depois.1 > 0 && deitada(antes) != deitada(depois)
}

// ---------------------------------------------------------------------------------------------
// A tela cheia
// ---------------------------------------------------------------------------------------------

/// O que pediu a tela cheia (ou a volta dela).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GestoDaTelaCheia {
    /// O botão sobre o vídeo.
    Botao,
    F11,
    /// Só sai: fora da tela cheia, não faz nada.
    Esc,
    /// O duplo clique no vídeo.
    DuploClique,
}

/// O que a janela faz com um gesto.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PassoDaTelaCheia {
    /// Sem borda, no retângulo do **monitor inteiro** (`rcMonitor`, por cima da barra de tarefas).
    Entrar(Retangulo),
    /// De volta à moldura, no retângulo de antes (trazido para dentro da área útil de agora).
    Sair(Retangulo),
}

/// **A tela cheia da janela de vídeo**: ligada ou não, e onde a janela estava antes de entrar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TelaCheia {
    antes: Option<Retangulo>,
}

impl TelaCheia {
    pub fn ligada(&self) -> bool {
        self.antes.is_some()
    }

    /// Um gesto: entra guardando `janela_agora`, ou sai devolvendo o retângulo guardado. O
    /// `monitor` e a `area_util` são os do monitor em que a janela está agora.
    pub fn gesto(
        &mut self,
        g: GestoDaTelaCheia,
        janela_agora: Retangulo,
        monitor: Retangulo,
        area_util: Retangulo,
    ) -> Option<PassoDaTelaCheia> {
        match (self.antes, g) {
            (None, GestoDaTelaCheia::Esc) => None,
            (None, _) => {
                self.antes = Some(janela_agora);
                Some(PassoDaTelaCheia::Entrar(monitor))
            }
            (Some(a), _) => {
                self.antes = None;
                Some(PassoDaTelaCheia::Sair(devolver_para_dentro(a, area_util)))
            }
        }
    }

    /// O retângulo da volta, para o giro do celular em tela cheia ajustá-lo à orientação nova.
    pub fn retorno(&self) -> Option<Retangulo> {
        self.antes
    }

    /// Troca o retângulo da volta (só com a tela cheia ligada).
    pub fn trocar_retorno(&mut self, r: Retangulo) {
        if self.antes.is_some() {
            self.antes = Some(r);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// O botão da tela cheia
// ---------------------------------------------------------------------------------------------
//
// **Aparece quando o mouse anda sobre o vídeo e some 2,5 s depois de ele parar** (e fica enquanto
// o mouse estiver em cima dele). É o comportamento dos players: numa prévia pequena, um botão
// sempre à vista cobriria parte da imagem o tempo todo, e quem quer tela cheia sem mouse tem F11 e
// o duplo clique. Ele aparece também nos primeiros 2,5 s da janela, para ser descoberto. Canto de
// baixo à direita, como nos players.

/// O lado do botão e a distância dele às bordas do cliente, em DIP.
pub const BOTAO_LADO_DIP: f64 = 36.0;
pub const BOTAO_MARGEM_DIP: f64 = 12.0;
/// Quanto tempo o botão fica depois do último movimento do mouse.
pub const BOTAO_SOME_MS: u64 = 2_500;

/// O botão no cliente (coordenadas do cliente), no canto de baixo à direita. Num cliente menor que
/// o botão, ele encosta em cima à esquerda.
pub fn botao_no_cliente(cliente: (u32, u32), dpi: u32) -> Retangulo {
    let lado = em_pixels(dpi, BOTAO_LADO_DIP).round() as i32;
    let m = em_pixels(dpi, BOTAO_MARGEM_DIP).round() as i32;
    let esquerda = (cliente.0 as i32 - m - lado).max(0);
    let topo = (cliente.1 as i32 - m - lado).max(0);
    (esquerda, topo, esquerda + lado, topo + lado)
}

/// O botão está à vista? `ms_desde_o_movimento` é o tempo desde o último movimento do mouse sobre o
/// vídeo (`None`: o mouse saiu).
pub fn botao_visivel(ms_desde_o_movimento: Option<u64>, mouse_no_botao: bool) -> bool {
    mouse_no_botao || ms_desde_o_movimento.is_some_and(|ms| ms < BOTAO_SOME_MS)
}

// =============================================================================================
// As cores da janela do vídeo (13/10)
// =============================================================================================
//
// **O relato do Bruno no Dell (MSI 1.0.17): "a janela de preview da fonte no Windows está clara,
// não seguindo as cores do Quall".** A janela do vídeo era a única janela independente do produto
// sem a moldura do `decoracao.rs`: a barra de título saía na cor do tema do Windows (clara num
// Windows claro), e o cliente, sem pincel e sem `WM_PAINT`, ficava com o que o DWM tivesse até o
// primeiro quadro. O botão da tela cheia tinha cinzas próprios, fora dos tokens.
//
// **O cliente e as faixas ficam pretos, e não no `FUNDO` do tema**: é o padrão do projeto para
// tudo o que mostra imagem — a prévia dos Ajustes e a da R5 (`BLACK_BRUSH`), o `ClearRenderTargetView`
// do `present.rs`, a barra do vídeo "sobre a imagem" do §11.1 (preto) — e é o que os players fazem.
// Um `FUNDO` (0B0B0F) nas faixas mudaria a cor no meio da imagem num vídeo de borda preta, e
// trocaria de cor no primeiro quadro (o fundo antes, as faixas depois). A barra de título é a do
// resto do app.

/// O fundo do cliente antes do primeiro quadro e as faixas do encaixe: preto puro.
pub const PRETO_DO_VIDEO: crate::estilo::Cor = crate::estilo::Cor::rgb(0x000000);

/// As cores do botão da tela cheia, opacas (o GDI não tem alfa).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CoresDoBotao {
    /// Atrás dos cantos redondos: o preto do vídeo (o botão é uma janela própria, quadrada).
    pub atras: crate::estilo::Cor,
    pub caixa: crate::estilo::Cor,
    pub borda: crate::estilo::Cor,
    pub glifo: crate::estilo::Cor,
}

/// O botão nos tokens do "Estúdio de bolso": a `SUPERFICIE` com o `CONTORNO` de 1 DIP, a
/// `SUPERFICIE_ALTA` sob o mouse ou apertado, e o glifo no `TEXTO`.
pub fn cores_do_botao(quente: bool) -> CoresDoBotao {
    use crate::estilo::{CONTORNO, SUPERFICIE, SUPERFICIE_ALTA, TEXTO};
    let caixa = if quente { SUPERFICIE_ALTA } else { SUPERFICIE };
    CoresDoBotao { atras: PRETO_DO_VIDEO, caixa, borda: CONTORNO.sobre(caixa), glifo: TEXTO }
}

/// A cor do Direct3D (`[r, g, b, a]` de 0 a 1) para o `ClearRenderTargetView`.
pub fn cor_do_d3d(c: crate::estilo::Cor) -> [f32; 4] {
    [c.r as f32 / 255.0, c.g as f32 / 255.0, c.b as f32 / 255.0, c.a as f32 / 255.0]
}

#[cfg(test)]
mod testes {
    use super::*;

    // --- A prévia ---

    /// A moldura de `WS_OVERLAPPEDWINDOW` da ordem do que o Windows 11 devolve: borda de
    /// redimensionar (invisível) dos lados e embaixo, barra de título em cima. Os números exatos
    /// dependem do tema e só o Dell diz; a regra não depende deles, só os soma.
    fn moldura(dpi: u32) -> Moldura {
        let e = |px: i32| (px as f64 * dpi as f64 / 96.0).round() as i32;
        Moldura { esquerda: e(8), topo: e(31), direita: e(8), base: e(8) }
    }

    fn proporcao(t: (u32, u32)) -> f64 {
        t.0 as f64 / t.1 as f64
    }

    fn confere_dentro(janela: Retangulo, area: Retangulo) {
        assert!(
            janela.0 >= area.0 && janela.1 >= area.1 && janela.2 <= area.2 && janela.3 <= area.3,
            "{janela:?} fora de {area:?}"
        );
        let (w, h) = tamanho(janela);
        let (aw, ah) = tamanho(area);
        assert!(
            w as f64 <= aw as f64 * FRACAO_DA_AREA_UTIL && h as f64 <= ah as f64 * FRACAO_DA_AREA_UTIL,
            "{w}x{h} passa de 85 % de {aw}x{ah}"
        );
    }

    /// **A imagem não é espremida**: o destino dentro de um buffer do tamanho do cliente tem a
    /// proporção do vídeo, com no máximo o erro do arredondamento (meio pixel por lado).
    fn confere_sem_espremer(video: (u32, u32), cliente: (u32, u32)) {
        let d = tamanho(destino_na_proporcao(video, cliente));
        let tolerancia = 1.0 / d.0.min(d.1) as f64 + 1e-9;
        let erro = (proporcao(d) / proporcao(video) - 1.0).abs();
        assert!(erro <= tolerancia, "vídeo {video:?} no cliente {cliente:?}: destino {d:?}, erro {erro:.4}");
        assert!(d.0 <= cliente.0 && d.1 <= cliente.1);
    }

    /// **O caso dos dois relatos**: o celular em pé, 1080 × 1920 (e 720 × 1280), num notebook de
    /// 1366 × 768 a 125 % (barra de tarefas de 48 DIP = 60 px, área útil 1366 × 708). A prévia é o
    /// piso, 360 DIP = 450 px de altura, na proporção, no canto de baixo à direita.
    #[test]
    fn retrato_num_notebook_1366x768_a_125() {
        let area = (0, 0, 1366, 708);
        let m = moldura(120);
        for video in [(1080, 1920), (720, 1280)] {
            let c = cliente_da_previa(video, 1.0, area, m, 120);
            assert_eq!(c, (253, 450), "{video:?}");
            confere_sem_espremer(video, c);
            let j = janela_ancorada(c, m, area, canto_da_previa(area, 120));
            confere_dentro(j, area);
            assert_eq!((j.2, j.3), (1366 - 20, 708 - 20), "canto de baixo à direita, 16 DIP = 20 px de margem");
        }
    }

    /// Deitado no mesmo notebook: 30 % de 1366 = 410 px < piso de 450.
    #[test]
    fn paisagem_num_notebook_e_o_piso() {
        let c = cliente_da_previa((1920, 1080), 1.0, (0, 0, 1366, 708), moldura(120), 120);
        assert_eq!(c, (450, 253));
        confere_sem_espremer((1920, 1080), c);
    }

    /// Full HD a 100 % (área 1920 × 1040): deitado, 30 % da largura (576); em pé, 30 % da altura
    /// daria 312 e vale o piso, 360.
    #[test]
    fn full_hd_a_100() {
        let area = (0, 0, 1920, 1040);
        assert_eq!(cliente_da_previa((1920, 1080), 1.0, area, moldura(96), 96), (576, 324));
        assert_eq!(cliente_da_previa((1080, 1920), 1.0, area, moldura(96), 96), (203, 360));
    }

    /// 4K a 150 % (área 3840 × 2088): deitado bate no teto de 640 DIP = 960 px; em pé, 30 % da
    /// altura (626 px) fica entre o piso e o teto.
    #[test]
    fn quatro_k_a_150_e_o_teto() {
        let area = (0, 0, 3840, 2088);
        assert_eq!(cliente_da_previa((1920, 1080), 1.0, area, moldura(144), 144), (960, 540));
        assert_eq!(cliente_da_previa((1080, 1920), 1.0, area, moldura(144), 144), (352, 626));
    }

    /// Num monitor pequeno a 200 % o piso (720 px) passaria da tela: o teto de 85 % vence.
    #[test]
    fn o_teto_de_85_vence_o_piso() {
        let area = (0, 0, 800, 600);
        let m = moldura(192);
        let c = cliente_da_previa((1080, 1920), 1.0, area, m, 192);
        assert_eq!(c.1 as i32 + m.altura(), (600.0 * FRACAO_DA_AREA_UTIL).floor() as i32, "{c:?}");
        confere_sem_espremer((1080, 1920), c);
        confere_dentro(janela_ancorada(c, m, area, canto_da_previa(area, 192)), area);
    }

    /// A resolução não muda a prévia, a escala de bancada sim; escala sem sentido volta a 1; vídeo
    /// sem tamanho nasce 16:9.
    #[test]
    fn so_a_proporcao_e_a_escala_entram() {
        let area = (0, 0, 1920, 1040);
        assert_eq!(cliente_da_previa((640, 360), 1.0, area, moldura(96), 96), (576, 324));
        assert_eq!(cliente_da_previa((3840, 2160), 1.0, area, moldura(96), 96), (576, 324));
        assert_eq!(cliente_da_previa((1920, 1080), 0.5, area, moldura(96), 96), (288, 162));
        assert_eq!(cliente_da_previa((1920, 1080), f64::NAN, area, moldura(96), 96), (576, 324));
        assert_eq!(cliente_da_previa((0, 0), 1.0, area, moldura(96), 96), (576, 324));
        // 4:3 e quadrado: a proporção do vídeo, sem virar 16:9.
        assert_eq!(cliente_da_previa((640, 480), 1.0, area, moldura(96), 96), (576, 432));
        assert_eq!(cliente_da_previa((720, 720), 1.0, area, moldura(96), 96), (576, 576));
    }

    /// O monitor da janela não é sempre o principal: à esquerda (coordenadas negativas) e à direita
    /// com a barra de tarefas em cima. A prévia fica na área **dele**.
    #[test]
    fn monitores_fora_da_origem() {
        let esquerdo = (-1366, 0, 0, 708);
        let c = cliente_da_previa((1080, 1920), 1.0, esquerdo, moldura(120), 120);
        let j = janela_ancorada(c, moldura(120), esquerdo, canto_da_previa(esquerdo, 120));
        confere_dentro(j, esquerdo);
        assert_eq!((j.2, j.3), (-20, 688));

        let direito = (1920, 48, 1920 + 2560, 1440);
        let c = cliente_da_previa((1920, 1080), 1.0, direito, moldura(96), 96);
        let j = janela_ancorada(c, moldura(96), direito, canto_da_previa(direito, 96));
        confere_dentro(j, direito);
    }

    /// Um canto pedido fora da área é empurrado para dentro; maior que a área, a janela encosta em
    /// cima à esquerda (a barra de título continua alcançável).
    #[test]
    fn o_canto_pedido_e_empurrado_para_dentro() {
        let area = (0, 0, 1366, 708);
        assert_eq!(janela_ancorada((400, 300), Moldura::default(), area, (2000, 900)), (966, 408, 1366, 708));
        assert_eq!(janela_ancorada((400, 300), Moldura::default(), area, (100, 100)), (0, 0, 400, 300));
        let j = janela_ancorada((2000, 1000), Moldura::default(), area, (683, 354));
        assert_eq!((j.0, j.1), (0, 0));
    }

    #[test]
    fn a_moldura_sai_do_ajuste_do_windows() {
        let m = Moldura::do_ajuste((-10, -39, 10, 10));
        assert_eq!(m, Moldura { esquerda: 10, topo: 39, direita: 10, base: 10 });
        assert_eq!((m.largura(), m.altura()), (20, 49));
    }

    // --- O giro ---

    /// **A sessão que começa deitada e gira para em pé, e o contrário**: o lado maior fica, a
    /// proporção troca, ida e volta dão o mesmo cliente, e nenhum dos dois espreme.
    #[test]
    fn o_giro_mantem_a_previa_pequena_e_nao_espreme() {
        let area = (0, 0, 1366, 708);
        let m = moldura(120);
        let deitado = cliente_da_previa((1920, 1080), 1.0, area, m, 120);
        let em_pe = cliente_girado(deitado, (1080, 1920), area, m);
        assert_eq!(em_pe, (253, 450));
        confere_sem_espremer((1080, 1920), em_pe);
        let de_volta = cliente_girado(em_pe, (1920, 1080), area, m);
        assert_eq!(de_volta, deitado);
        confere_sem_espremer((1920, 1080), de_volta);
        // 720p em pé depois de 1080p deitado (o emissor que desce a taxa junto com o giro).
        confere_sem_espremer((720, 1280), cliente_girado(deitado, (720, 1280), area, m));
        // A janela que a pessoa aumentou continua grande depois do giro, dentro do teto.
        let grande = cliente_girado((1100, 619), (1080, 1920), area, m);
        assert_eq!(grande.1 as i32 + m.altura(), (708.0 * FRACAO_DA_AREA_UTIL).floor() as i32);
        confere_sem_espremer((1080, 1920), grande);
    }

    #[test]
    fn so_a_troca_de_orientacao_reencaixa() {
        assert!(mudou_de_orientacao((1080, 1920), (1920, 1080)));
        assert!(mudou_de_orientacao((1920, 1080), (720, 1280)));
        assert!(!mudou_de_orientacao((1920, 1080), (1280, 720)));
        assert!(!mudou_de_orientacao((720, 1280), (1080, 1920)));
        assert!(!mudou_de_orientacao((0, 0), (1920, 1080)), "sem tamanho antes não é giro");
    }

    // --- Espremer, ou não ---

    /// **O defeito do segundo relato, na conta**: no `93b45a82` a swap chain tinha o tamanho pedido
    /// (1080 × 1920), a janela ganhava o que o Windows deixava (um cliente da ordem de 1080 × 745
    /// num 1366 × 768) e o DXGI esticava o buffer no cliente. O vídeo em pé ocupava o buffer inteiro
    /// e saía com a proporção do **cliente**: 1,45 em vez de 0,5625 — "quadrada, espremida".
    #[test]
    fn o_defeito_antigo_esticava_o_buffer_no_cliente() {
        let video = (1080, 1920);
        let buffer_antigo = (1080, 1920);
        let cliente_cortado = (1080u32, 745u32);
        let no_buffer = tamanho(destino_na_proporcao(video, buffer_antigo));
        assert_eq!(no_buffer, buffer_antigo, "no buffer a imagem estava certa");
        let na_tela = (
            no_buffer.0 as f64 * cliente_cortado.0 as f64 / buffer_antigo.0 as f64,
            no_buffer.1 as f64 * cliente_cortado.1 as f64 / buffer_antigo.1 as f64,
        );
        let deformacao = (na_tela.0 / na_tela.1) / proporcao(video);
        assert!(deformacao > 2.5, "o esticão achatava {deformacao:.2}x");
        // Com o buffer do tamanho do cliente (o conserto), o mesmo cliente cortado dá faixas e a
        // proporção certa.
        confere_sem_espremer(video, cliente_cortado);
    }

    /// Em qualquer cliente — a prévia, a borda arrastada para qualquer formato, a tela cheia de
    /// monitores deitados e em pé — o destino tem a proporção do vídeo, nas duas orientações e com
    /// os tamanhos que os celulares mandam (com o recorte do SPS já descontado: 1080 e não 1088).
    #[test]
    fn nenhum_cliente_espreme_nenhum_video() {
        let videos = [(1080, 1920), (720, 1280), (1920, 1080), (1280, 720), (1440, 3120), (3120, 1440), (640, 480), (854, 480)];
        let clientes = [
            (253, 450),
            (450, 253),
            (1366, 768),  // tela cheia do notebook
            (1920, 1080), // tela cheia Full HD
            (1080, 1920), // tela cheia num monitor em pé
            (3840, 2160),
            (500, 500), // a borda arrastada até quadrada
            (1000, 200),
            (200, 1000),
            (161, 90),
        ];
        for v in videos {
            for c in clientes {
                confere_sem_espremer(v, c);
            }
        }
    }

    // --- A tela cheia ---

    #[test]
    fn a_tela_cheia_alterna_e_volta_ao_lugar() {
        let monitor = (0, 0, 1366, 768);
        let area = (0, 0, 1366, 708);
        let previa = (1073, 189, 1346, 688);
        let mut t = TelaCheia::default();
        assert_eq!(t.gesto(GestoDaTelaCheia::Esc, previa, monitor, area), None, "Esc fora da tela cheia não faz nada");
        for (entra, sai) in [
            (GestoDaTelaCheia::Botao, GestoDaTelaCheia::Esc),
            (GestoDaTelaCheia::F11, GestoDaTelaCheia::DuploClique),
            (GestoDaTelaCheia::DuploClique, GestoDaTelaCheia::Botao),
            (GestoDaTelaCheia::F11, GestoDaTelaCheia::F11),
        ] {
            assert_eq!(t.gesto(entra, previa, monitor, area), Some(PassoDaTelaCheia::Entrar(monitor)), "{entra:?}");
            assert!(t.ligada());
            // Em tela cheia o cliente é o monitor, e a imagem não espreme.
            confere_sem_espremer((1080, 1920), tamanho(monitor));
            assert_eq!(t.gesto(sai, monitor, monitor, area), Some(PassoDaTelaCheia::Sair(previa)), "{sai:?}");
            assert!(!t.ligada());
        }
    }

    /// O monitor mudou enquanto a janela estava em tela cheia (a resolução baixou): a volta vem
    /// para dentro da área útil nova, com o mesmo tamanho.
    #[test]
    fn a_volta_cabe_no_monitor_de_agora() {
        let mut t = TelaCheia::default();
        t.gesto(GestoDaTelaCheia::F11, (1073, 189, 1346, 688), (0, 0, 1366, 768), (0, 0, 1366, 708));
        let passo = t.gesto(GestoDaTelaCheia::Esc, (0, 0, 1024, 768), (0, 0, 1024, 768), (0, 0, 1024, 700));
        assert_eq!(passo, Some(PassoDaTelaCheia::Sair((751, 189, 1024, 688))));
        assert_eq!(devolver_para_dentro((0, 0, 3000, 3000), (0, 0, 1024, 700)), (0, 0, 1024, 700));
    }

    /// O giro em tela cheia troca o retorno: ao sair, a janela já tem o formato novo.
    #[test]
    fn o_giro_em_tela_cheia_ajusta_a_volta() {
        let mut t = TelaCheia::default();
        t.trocar_retorno((1, 2, 3, 4));
        assert_eq!(t.retorno(), None, "desligada, não guarda");
        t.gesto(GestoDaTelaCheia::F11, (1073, 189, 1346, 688), (0, 0, 1366, 768), (0, 0, 1366, 708));
        t.trocar_retorno((896, 415, 1346, 688));
        assert_eq!(
            t.gesto(GestoDaTelaCheia::F11, (0, 0, 1366, 768), (0, 0, 1366, 768), (0, 0, 1366, 708)),
            Some(PassoDaTelaCheia::Sair((896, 415, 1346, 688)))
        );
    }

    // --- O botão ---

    #[test]
    fn o_botao_fica_no_canto_e_escala_com_o_dpi() {
        assert_eq!(botao_no_cliente((253, 450), 120), (193, 390, 238, 435));
        assert_eq!(botao_no_cliente((576, 324), 96), (528, 276, 564, 312));
        assert_eq!(botao_no_cliente((1920, 1080), 192), (1824, 984, 1896, 1056));
        assert_eq!(botao_no_cliente((20, 20), 96), (0, 0, 36, 36), "cliente menor que o botão");
    }

    #[test]
    fn o_botao_some_depois_de_parado() {
        assert!(botao_visivel(Some(0), false));
        assert!(botao_visivel(Some(BOTAO_SOME_MS - 1), false));
        assert!(!botao_visivel(Some(BOTAO_SOME_MS), false));
        assert!(!botao_visivel(None, false), "o mouse saiu");
        assert!(botao_visivel(None, true), "em cima do botão ele fica");
        assert!(botao_visivel(Some(60_000), true));
    }

    // --- A origem (G1) ---

    /// **O controle de 21/09, descendo**: a sessão abriu em 854×480 (textura 864×480, "só o
    /// alinhamento") e o fluxo passou a 640×480. A origem antiga, fixa no primeiro SPS, era
    /// (0, 0, 854, 480): maior que a textura de 640, e o `present_frame` devolvia `0x80070057` em
    /// todo quadro. A origem nova é a abertura de agora, dentro da textura.
    #[test]
    fn g1_descendo_de_854_para_640_a_origem_cabe_na_textura() {
        let origem_antiga = (0, 0, 854, 480);
        assert!(origem_na_textura(origem_antiga, (640, 480)) != Some(origem_antiga), "a antiga passava da textura");
        assert_eq!(origem_na_textura((0, 0, 640, 480), (640, 480)), Some((0, 0, 640, 480)));
        // Com o tipo relido atrasado um quadro (a abertura ainda a de 854), a origem recorta à
        // textura em vez de passar dela.
        assert_eq!(origem_na_textura((0, 0, 854, 480), (640, 480)), Some((0, 0, 640, 480)));
    }

    /// **Subindo, de 640 para 854** (a sessão que abre em 4:3): a origem antiga, (0, 0, 640, 480),
    /// cabia na textura de 864 e cortava a imagem à direita. A nova pega a abertura inteira, 854,
    /// sem a coluna de enchimento do alinhamento.
    #[test]
    fn g1_subindo_de_640_para_854_a_origem_pega_a_imagem_inteira() {
        let origem = origem_na_textura((0, 0, 854, 480), (864, 480)).unwrap();
        assert_eq!(origem, (0, 0, 854, 480));
        assert_eq!(tamanho(origem), (854, 480), "nem as 640 da esquerda, nem as 864 da textura");
        // A abertura com deslocamento (um decodificador que recorta em cima) é respeitada.
        assert_eq!(origem_na_textura((0, 4, 1920, 1084), (1920, 1088)), Some((0, 4, 1920, 1084)));
    }

    #[test]
    fn a_origem_vazia_nao_apresenta() {
        assert_eq!(origem_na_textura((0, 0, 0, 480), (640, 480)), None);
        assert_eq!(origem_na_textura((700, 0, 854, 480), (640, 480)), None, "a abertura toda fora da textura");
        assert_eq!(origem_na_textura((0, 0, 640, 480), (0, 0)), None);
        assert_eq!(origem_na_textura((-5, -5, 10, 10), (640, 480)), Some((0, 0, 10, 10)));
    }

    // --- As cores (13/10) ---

    fn luminancia(c: crate::estilo::Cor) -> f64 {
        let canal = |v: u8| {
            let v = v as f64 / 255.0;
            if v <= 0.03928 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * canal(c.r) + 0.7152 * canal(c.g) + 0.0722 * canal(c.b)
    }

    fn contraste(a: crate::estilo::Cor, b: crate::estilo::Cor) -> f64 {
        let (x, y) = (luminancia(a), luminancia(b));
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    }

    #[test]
    fn o_botao_da_tela_cheia_usa_os_tokens_e_e_escuro() {
        use crate::estilo::{SUPERFICIE, SUPERFICIE_ALTA, TEXTO};
        let frio = cores_do_botao(false);
        let quente = cores_do_botao(true);
        assert_eq!((frio.caixa, quente.caixa), (SUPERFICIE, SUPERFICIE_ALTA));
        assert_eq!((frio.glifo, quente.glifo), (TEXTO, TEXTO));
        for c in [frio, quente] {
            assert_eq!(c.atras, PRETO_DO_VIDEO, "atrás dos cantos, o preto das faixas");
            for cor in [c.atras, c.caixa, c.borda, c.glifo] {
                assert_eq!(cor.a, 255, "o GDI pinta opaco: {cor:?}");
            }
            // Nada claro além do glifo: o relato era de janela clara.
            for cor in [c.atras, c.caixa, c.borda] {
                assert!(luminancia(cor) < 0.05, "{cor:?} claro demais");
            }
            assert!(contraste(c.glifo, c.caixa) >= 7.0, "glifo {:.1}:1", contraste(c.glifo, c.caixa));
            assert!(c.borda != c.caixa, "a borda aparece");
        }
    }

    #[test]
    fn as_faixas_e_o_fundo_do_video_sao_preto_puro() {
        assert_eq!(cor_do_d3d(PRETO_DO_VIDEO), [0.0, 0.0, 0.0, 1.0]);
        assert_eq!(PRETO_DO_VIDEO.colorref(), 0);
        assert_eq!(cor_do_d3d(crate::estilo::BRANCO), [1.0, 1.0, 1.0, 1.0]);
    }
}
