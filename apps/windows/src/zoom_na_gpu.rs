//! **O zoom digital do Quall na GPU do dono da captura** (`docs/controles-de-camera.md` §3.8.7, 14/10).
//! As contas são de `zoom_do_quall.rs`; aqui só se executa.
//!
//! - **Onde**: na thread do dono (`dono_da_captura.rs`, o bombeio), logo depois do `take_frame` e
//!   **antes** das saídas: a rede (a cópia no anel dela), a prévia e o gravador recebem o quadro já
//!   recortado. É a mesma imagem no ar, no arquivo e na tela de quem filma.
//! - **Como**: um `ID3D11VideoProcessor` com a entrada e a saída no **mesmo formato e tamanho** da
//!   câmera (NV12 ou YUY2), o retângulo de origem no recorte central e o de destino no quadro inteiro.
//!   O espaço de cor declarado é o mesmo nos dois lados: só a escala, nenhuma conversão. Sem
//!   auto-processamento do driver.
//! - **Em 1×, nada**: o quadro do anel da câmera passa como veio, sem `Blt`.
//! - **Dois destinos**: as saídas usam o quadro dentro da volta do bombeio (a rede copia para o anel
//!   dela, a prévia desenha, o gravador copia para a reserva dele); o contexto imediato ordena o
//!   resto. O segundo é folga.
//! - **Uma falha não derruba nada**: o recorte que não nasce ou não desenha é dito uma vez no diário,
//!   e o quadro segue sem zoom.

#![cfg(windows)]

use std::mem::ManuallyDrop;

use windows::core::{Interface, Result, BOOL};
use windows::Win32::Foundation::RECT;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_COLOR_SPACE_TYPE, DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P601, DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P709,
    DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P601, DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709, DXGI_FORMAT, DXGI_RATIONAL,
};

use crate::capture::CapturedFrame;

/// Quantos destinos o recorte tem (ver o cabeçalho).
const DESTINOS: usize = 2;

fn conteudo(largura: u32, altura: u32) -> D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
        InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
        InputFrameRate: DXGI_RATIONAL { Numerator: 30, Denominator: 1 },
        InputWidth: largura,
        InputHeight: altura,
        OutputFrameRate: DXGI_RATIONAL { Numerator: 30, Denominator: 1 },
        OutputWidth: largura,
        OutputHeight: altura,
        Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
    }
}

fn espaco(completa: bool, matriz_709: bool) -> DXGI_COLOR_SPACE_TYPE {
    match (completa, matriz_709) {
        (true, true) => DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P709,
        (true, false) => DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P601,
        (false, true) => DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709,
        (false, false) => DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P601,
    }
}

/// **Esta placa recorta este formato?** O processador de vídeo aceita `formato` na entrada **e** na
/// saída, em `largura × altura`. É o que a abertura confere antes de oferecer o zoom do Quall
/// (`captura_de_camera.rs`): o que não recorta não é oferecido.
pub fn suportado(dispositivo: &ID3D11Device, formato: DXGI_FORMAT, largura: u32, altura: u32) -> std::result::Result<(), String> {
    let r = (|| -> Result<(bool, bool)> {
        let video: ID3D11VideoDevice = dispositivo.cast()?;
        let enumerador = unsafe { video.CreateVideoProcessorEnumerator(&conteudo(largura, altura))? };
        let suporte = unsafe { enumerador.CheckVideoProcessorFormat(formato)? };
        let (entrada, saida) = (
            suporte & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT.0 as u32 != 0,
            suporte & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT.0 as u32 != 0,
        );
        if entrada && saida {
            // O destino de verdade: a textura do anel tem de aceitar a vista de saída (a do YUY2 pode
            // nascer sem `RENDER_TARGET`).
            let t = crate::captura_de_camera::textura_do_anel(dispositivo, formato, largura, altura)?;
            let desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
            };
            let mut vista: Option<ID3D11VideoProcessorOutputView> = None;
            unsafe { video.CreateVideoProcessorOutputView(&t, &enumerador, &desc, Some(&mut vista))? };
        }
        Ok((entrada, saida))
    })();
    match r {
        Ok((true, true)) => Ok(()),
        Ok((entrada, saida)) => Err(format!("o processador de vídeo desta placa não aceita {formato:?} (entrada {entrada}, saída {saida})")), // i18n: fora (diário)
        Err(e) => Err(format!("o processador de vídeo não respondeu ({e})")), // i18n: fora (diário)
    }
}

/// **O recorte**, criado na thread do dono no primeiro quadro com zoom.
pub struct RecorteNaGpu {
    video: ID3D11VideoDevice,
    contexto: ID3D11VideoContext1,
    enumerador: ID3D11VideoProcessorEnumerator,
    processador: ID3D11VideoProcessor,
    destinos: Vec<(ID3D11Texture2D, ID3D11VideoProcessorOutputView)>,
    proximo: usize,
    largura: u32,
    altura: u32,
    /// O recorte posto por último no processador (em pixels), para não repor a cada quadro.
    posto: Option<(u32, u32, u32, u32)>,
}

impl RecorteNaGpu {
    /// O recorte de quadros `formato` de `largura × altura`, com a faixa e a matriz da câmera.
    pub fn novo(dispositivo: &ID3D11Device, formato: DXGI_FORMAT, largura: u32, altura: u32, completa: bool, matriz_709: bool) -> Result<RecorteNaGpu> {
        let video: ID3D11VideoDevice = dispositivo.cast()?;
        let contexto: ID3D11VideoContext1 = unsafe { dispositivo.GetImmediateContext()? }.cast()?;
        let enumerador = unsafe { video.CreateVideoProcessorEnumerator(&conteudo(largura, altura))? };
        let processador = unsafe { video.CreateVideoProcessor(&enumerador, 0)? };
        let cor = espaco(completa, matriz_709);
        let cheio = RECT { left: 0, top: 0, right: largura as i32, bottom: altura as i32 };
        unsafe {
            contexto.VideoProcessorSetStreamFrameFormat(&processador, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            contexto.VideoProcessorSetStreamColorSpace1(&processador, 0, cor);
            contexto.VideoProcessorSetOutputColorSpace1(&processador, cor);
            contexto.VideoProcessorSetStreamAutoProcessingMode(&processador, 0, false);
            contexto.VideoProcessorSetStreamDestRect(&processador, 0, true, Some(&cheio));
            contexto.VideoProcessorSetOutputTargetRect(&processador, true, Some(&cheio));
        }
        let mut destinos = Vec::with_capacity(DESTINOS);
        for _ in 0..DESTINOS {
            let t = crate::captura_de_camera::textura_do_anel(dispositivo, formato, largura, altura)?;
            let desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
            };
            let mut vista: Option<ID3D11VideoProcessorOutputView> = None;
            unsafe { video.CreateVideoProcessorOutputView(&t, &enumerador, &desc, Some(&mut vista))? };
            let vista = vista.ok_or_else(|| windows::core::Error::new(windows::Win32::Foundation::E_POINTER, "sem vista de saída"))?; // i18n: fora (diário)
            destinos.push((t, vista));
        }
        Ok(RecorteNaGpu { video, contexto, enumerador, processador, destinos, proximo: 0, largura, altura, posto: None })
    }

    /// **O quadro com o zoom `z`**: o centro de `q` ampliado de volta ao tamanho, num destino nosso,
    /// com o mesmo instante. A textura volta para as saídas desta volta do bombeio (sem posse).
    pub fn aplicar(&mut self, q: &CapturedFrame, z: f64) -> Result<CapturedFrame> {
        let (x, y, l, a) = crate::zoom_do_quall::recorte(self.largura, self.altura, z);
        if self.posto != Some((x, y, l, a)) {
            let origem = RECT { left: x as i32, top: y as i32, right: (x + l) as i32, bottom: (y + a) as i32 };
            unsafe { self.contexto.VideoProcessorSetStreamSourceRect(&self.processador, 0, true, Some(&origem)) };
            self.posto = Some((x, y, l, a));
        }
        let i = self.proximo;
        self.proximo = (i + 1) % self.destinos.len();
        let (destino, vista_de_saida) = &self.destinos[i];
        let desc_entrada = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
            FourCC: 0,
            ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
        };
        let mut vista_de_entrada: Option<ID3D11VideoProcessorInputView> = None;
        unsafe { self.video.CreateVideoProcessorInputView(&q.texture, &self.enumerador, &desc_entrada, Some(&mut vista_de_entrada))? };
        let fluxo = D3D11_VIDEO_PROCESSOR_STREAM {
            Enable: BOOL::from(true),
            OutputIndex: 0,
            InputFrameOrField: 0,
            PastFrames: 0,
            FutureFrames: 0,
            ppPastSurfaces: std::ptr::null_mut(),
            pInputSurface: ManuallyDrop::new(vista_de_entrada),
            ppFutureSurfaces: std::ptr::null_mut(),
            ppPastSurfacesRight: std::ptr::null_mut(),
            pInputSurfaceRight: ManuallyDrop::new(None),
            ppFutureSurfacesRight: std::ptr::null_mut(),
        };
        let mut fluxos = [fluxo];
        let r = unsafe { self.contexto.VideoProcessorBlt(&self.processador, vista_de_saida, 0, &fluxos) };
        // A vista é nossa: solta aqui, dê o `Blt` certo ou errado.
        unsafe { ManuallyDrop::drop(&mut fluxos[0].pInputSurface) };
        r?;
        Ok(CapturedFrame { texture: destino.clone(), captured_at: q.captured_at, posse: None })
    }
}
