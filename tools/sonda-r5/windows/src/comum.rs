//! O que as duas medidas dividem: a origem sintética na GPU, o envelope para mandar COM entre
//! threads, e a aritmética de percentis.

use windows::core::Result;
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11RenderTargetView, ID3D11Texture2D, D3D11_BIND_RENDER_TARGET,
    D3D11_BIND_SHADER_RESOURCE, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Media::MediaFoundation::IMFMediaType;
use windows::core::GUID;

/// Um objeto COM levado a outra thread. O processo inteiro é MTA (`COINIT_MULTITHREADED` em toda
/// thread que toca COM), e os objetos do Media Foundation e do D3D11 usados aqui são de threading
/// livre; o `windows-rs` só não marca `Send` nas interfaces que não são ágeis por declaração.
pub struct Enviavel<T>(pub T);
unsafe impl<T> Send for Enviavel<T> {}

/// **A origem sintética**: um anel de texturas BGRA pintadas por `ClearRenderTargetView` com uma
/// cor que muda a cada quadro. Nada que exista fora deste processo — nem câmera, nem tela.
///
/// O preço está no relato: cor chapada comprime muito melhor que imagem de câmera, então **taxa e
/// tamanho de quadro daqui não valem para o produto**. O que vale é o mecanismo: se os dois
/// encoders vivem juntos, se sustentam o ritmo, e quanto tempo cada quadro leva lá dentro.
pub struct Origem {
    dispositivo: ID3D11Device,
    texturas: Vec<(ID3D11Texture2D, ID3D11RenderTargetView)>,
    n: usize,
}

impl Origem {
    pub fn nova(dispositivo: &ID3D11Device, largura: u32, altura: u32, quantas: usize) -> Result<Self> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: largura,
            Height: altura,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut texturas = Vec::new();
        for _ in 0..quantas {
            let mut t: Option<ID3D11Texture2D> = None;
            unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t))? };
            let t = t.expect("CreateTexture2D não devolveu textura");
            let mut v: Option<ID3D11RenderTargetView> = None;
            unsafe { dispositivo.CreateRenderTargetView(&t, None, Some(&mut v))? };
            texturas.push((t, v.expect("CreateRenderTargetView não devolveu vista")));
        }
        Ok(Origem { dispositivo: dispositivo.clone(), texturas, n: 0 })
    }

    /// A próxima textura do anel, já pintada. Anel, e não uma textura só: o MFT segura a textura até
    /// terminar de codificá-la.
    pub fn proxima(&mut self) -> ID3D11Texture2D {
        let i = self.n % self.texturas.len();
        self.n += 1;
        let f = (self.n % 60) as f32 / 60.0;
        let cor = [f, 1.0 - f, (f * 2.0) % 1.0, 1.0f32];
        unsafe {
            let ctx = self.dispositivo.GetImmediateContext().expect("contexto imediato");
            ctx.ClearRenderTargetView(&self.texturas[i].1, &cor);
        }
        self.texturas[i].0.clone()
    }
}

/// **A origem sintética em NV12**, o formato que a câmera entrega (`captura_de_camera.rs`): um anel
/// de texturas NV12 na GPU, cada quadro escrito numa textura de estágio pela CPU (luma chapada que
/// muda a cada quadro, croma neutra) e copiado para a posição do anel.
pub struct OrigemNv12 {
    dispositivo: ID3D11Device,
    estagio: ID3D11Texture2D,
    anel: Vec<ID3D11Texture2D>,
    largura: u32,
    altura: u32,
    n: usize,
}

impl OrigemNv12 {
    pub fn nova(dispositivo: &ID3D11Device, largura: u32, altura: u32, quantas: usize) -> Result<Self> {
        use windows::Win32::Graphics::Direct3D11::{D3D11_CPU_ACCESS_WRITE, D3D11_USAGE_STAGING};
        use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_NV12;
        let mut desc = D3D11_TEXTURE2D_DESC {
            Width: largura,
            Height: altura,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_NV12,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut anel = Vec::new();
        for _ in 0..quantas {
            let mut t: Option<ID3D11Texture2D> = None;
            unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t))? };
            anel.push(t.expect("textura NV12"));
        }
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE.0 as u32;
        let mut e: Option<ID3D11Texture2D> = None;
        unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut e))? };
        Ok(OrigemNv12 { dispositivo: dispositivo.clone(), estagio: e.expect("estágio NV12"), anel, largura, altura, n: 0 })
    }

    pub fn proxima(&mut self) -> Result<ID3D11Texture2D> {
        use windows::Win32::Graphics::Direct3D11::{D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_WRITE};
        let i = self.n % self.anel.len();
        self.n += 1;
        let luma = (16 + (self.n * 4) % 220) as u8;
        unsafe {
            let ctx = self.dispositivo.GetImmediateContext()?;
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&self.estagio, 0, D3D11_MAP_WRITE, 0, Some(&mut m))?;
            let passo = m.RowPitch as usize;
            let base = m.pData as *mut u8;
            let h = self.altura as usize;
            let w = self.largura as usize;
            for y in 0..h {
                std::ptr::write_bytes(base.add(y * passo), luma, w);
            }
            for y in 0..h / 2 {
                std::ptr::write_bytes(base.add((h + y) * passo), 128, w);
            }
            ctx.Unmap(&self.estagio, 0);
            ctx.CopyResource(&self.anel[i], &self.estagio);
        }
        Ok(self.anel[i].clone())
    }
}

/// `MFSetAttributeSize`/`MFSetAttributeRatio` são inline no SDK; o par de `u32` vai num `u64`.
pub fn par(tipo: &IMFMediaType, chave: &GUID, alto: u32, baixo: u32) -> Result<()> {
    unsafe { tipo.SetUINT64(chave, ((alto as u64) << 32) | baixo as u64) }
}

/// Percentil por posição, sobre microssegundos, devolvido em milissegundos.
pub fn percentil_ms(v: &[u64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    let mut s = v.to_vec();
    s.sort_unstable();
    let i = ((s.len() - 1) as f64 * p).round() as usize;
    s[i] as f64 / 1000.0
}

pub fn hr(e: &windows::core::Error) -> String {
    format!("0x{:08X} {}", e.code().0 as u32, e.message())
}
