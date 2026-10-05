//! `quall_camera_local` — sonda de bancada da **Frente C** (o Windows emite câmera).
//!
//! Desenho e resultados em `docs/camera-no-windows.md`. **Não é código de produto** e nenhum
//! binário de produto a chama; desde a fase 2 ela é que chama o produto (o catálogo e o encoder).
//!
//! # A regra que esta sonda obedece antes de tudo
//!
//! Vídeo de câmera de máquina do usuário é material do usuário. Então:
//!
//! - `adaptadores` e `listar` **não ativam** câmera nenhuma. `listar` é o catálogo do produto
//!   (`cameras::catalogo`): nome, link simbólico e o dono lido do registro, só leitura;
//! - `ler` só abre **a fonte do Quall**: ou instanciada dentro deste processo (`--direto`, sem nó de
//!   dispositivo e sem Frame Server), ou uma câmera virtual cujo nó tenha o **nosso** CLSID,
//!   conferido pela regra do produto **antes** do `ActivateObject`: a que `--criar-camera` criou, ou,
//!   por `--link`, **só** a câmera de bancada de outra sonda viva ("<base> sonda <PID>", com o PID de
//!   um `quall_camera_local.exe` rodando). Uma baia do `Quall.exe` do usuário tem o mesmo dono e
//!   mostra o celular dele: recusada (a revisão de código de 18/09, achado 2 do catálogo).
//!   Webcam USB, a Câmera Conectada do Windows, a da Canon: recusadas com código 2;
//! - no `--direto`, a fonte recebe um **nome aleatório** no repositório de atributos antes do
//!   `Start`, e com ele lê um cano que ninguém serve: entrega o padrão de bancada, que é nosso. A
//!   versão da manhã conferia o cano sem nome antes e depois, e a revisão adversarial mostrou a
//!   janela no meio;
//! - nenhum quadro é gravado nem aberto. Conta-se: quadros, carimbos, tamanhos, um resumo barato do
//!   plano Y e um FNV-1a do bitstream codificado. O `--h264` grava o bitstream, e só é aceito com
//!   origem nossa (`--direto`, ou a câmera que a própria sonda criou). Com `--link` é recusado: uma
//!   baia do `Quall.exe` do usuário tem o dono Quall e pode estar mostrando o celular dele.
//!
//! # O que ela mede
//!
//! 1. Que relógio o quadro da câmera leva: o carimbo de `ReadSample` contra `MFGetSystemTime()` e
//!    contra o QPC, na chegada, e se o `MFSampleExtension_DeviceTimestamp` vem.
//! 2. Os formatos que a fonte declara, e o que o leitor entrega (memória de sistema ou superfície
//!    DXGI) com e sem `MF_SOURCE_READER_D3D_MANAGER`.
//! 3. **O encoder do produto com entrada NV12** (fase 2): montado como `transmissao.rs` monta, ou
//!    pela `Oficina` com o LUID (`--oficina`), entregando memória, textura, a fatia *k* de um array
//!    (`--codificar array`, com o controle negativo `--subrecurso-errado`) ou a amostra do leitor. A
//!    negociação própria da fase 1 ficou atrás de `--negociar-local`, para comparar e para o
//!    `--declarar-cor`.
//! 4. **A captura do produto** (fase 3, `capturar`): `captura_de_camera::CapturaDeCamera` inteira —
//!    o leitor assíncrono, o tipo nativo fixado, a cópia para o anel, o carimbo, o recuo para o
//!    compartilhado e as testemunhas de parada — com o conversor e o encoder do produto atrás.
//!    Com `--conferir-a-cada N`, lê de volta um quadro do anel a cada N e confere que a barra do
//!    padrão de bancada está numa posição só e anda com os quadros que chegaram (a revisão do código
//!    da fase 3, T1): a amostra volta ao pool antes de a cópia de GPU rodar? `--conferir-atrasado` lê
//!    o quadro n só depois de tomar n+3, sem forçar a cópia a rodar na hora, e `--sem-flush` tira a
//!    defesa do produto (o `Flush` antes de soltar a amostra), para medir a hipótese sem ela.
//! 5. **O anel e o conversor com texturas sintéticas** (`anel`): a cópia na chegada pela fatia certa
//!    de um array, pela memória, de outro dispositivo e **pela abertura** (a imagem num quadro
//!    maior), e a faixa e a escala do conversor, medidas em texturas que a própria sonda monta. Sem
//!    câmera nenhuma.
//! 6. **O dono do nó** (`segurar`): cria a câmera de bancada e só a segura, sem leitor, para duas
//!    capturas do produto dividirem a câmera com o nó vivo (o R3, a revisão do código da fase 3, T2).
//!
//! Roda na Sessão 0 (pelo SSH): não captura tela nenhuma e não escuta rede.

#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::collections::{HashSet, VecDeque};
use std::io::Write;
use std::mem::ManuallyDrop;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use crossbeam_channel::Receiver;

use windows::core::{Interface, GUID, HSTRING, PWSTR};
use windows::Win32::Foundation::{GetLastError, ERROR_FILE_NOT_FOUND, LUID, VARIANT_FALSE, VARIANT_TRUE};
use windows::Win32::System::Pipes::WaitNamedPipeW;
use windows::Win32::System::Variant::{VARIANT, VARIANT_0, VARIANT_0_0, VARIANT_0_0_0, VT_BOOL, VT_I4};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_BIND_DECODER, D3D11_BIND_RENDER_TARGET,
    D3D11_BIND_SHADER_RESOURCE,
    D3D11_CPU_ACCESS_WRITE, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_WRITE, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

use quall_capture_probe::cameras;
use quall_capture_probe::catalogo_de_cameras::{self, Dono};
use quall_capture_probe::encoder::{self, ChosenEncoder, MftEvent};
use quall_capture_probe::oficina::Oficina;
use quall_capture_probe::{device, sps};

/// `MF_DEVSOURCE_ATTRIBUTE_FRAMESERVER_SHARE_MODE` (`mfidl.h` do SDK 10.0.26100, `NTDDI_WIN11_ZN`),
/// lido no cabeçalho do Dell em 18/09/2026. Não existe no crate `windows` 0.62.
const MF_DEVSOURCE_ATTRIBUTE_FRAMESERVER_SHARE_MODE: GUID =
    GUID::from_u128(0x44d1a9bc_2999_4238_ae43_0730ceb2ab1b);

macro_rules! diga {
    ($($t:tt)*) => {{
        println!("{}", quall_capture_probe::higiene_do_registro::sanitizar_argumentos(&format!($($t)*)));
        let _ = std::io::stdout().flush();
    }};
}

// =============================================================================================
// Relógios
// =============================================================================================

fn qpc_100ns() -> i64 {
    let mut c = 0i64;
    let mut f = 0i64;
    unsafe {
        let _ = QueryPerformanceCounter(&mut c);
        let _ = QueryPerformanceFrequency(&mut f);
    }
    if f == 0 {
        return 0;
    }
    ((c as i128) * 10_000_000 / (f as i128)) as i64
}

/// `MFGetSystemTime()` é o QPC em 100 ns? Cinco pares lidos lado a lado, e a diferença de cada um.
fn conferir_relogios() {
    let mut difs = Vec::new();
    for _ in 0..5 {
        let a = unsafe { MFGetSystemTime() };
        let b = qpc_100ns();
        difs.push(b - a);
    }
    let mut f = 0i64;
    unsafe {
        let _ = QueryPerformanceFrequency(&mut f);
    }
    diga!(
        "relogios: QPC(100ns) - MFGetSystemTime() = {:?} (em unidades de 100 ns) | frequencia do QPC = {f} Hz",
        difs
    );
}

// =============================================================================================
// O cano sem nome
// =============================================================================================

/// **Alguém serve o cano sem nome?** A fonte instanciada no processo (`--direto`) não tem nome e
/// lê `\\.\pipe\quall-camera-v1` (`fonte/src/quadros.rs`, `CANO_SEM_NOME`). Sem servidor ela entrega
/// o padrão de bancada; **com** servidor ela entrega o que ele mandar — e a sonda da câmera virtual
/// serve esse cano por padrão, inclusive com vídeo recebido de um celular. Então o `--direto` só é
/// origem nossa se o cano **não existir**.
///
/// `WaitNamedPipeW` responde sem conectar: abrir o cano para "ver se existe" contaria como cliente
/// para quem o serve. `true` também quando existe e está ocupado.
fn cano_existe(cano: &str) -> bool {
    let nome = HSTRING::from(cano);
    let ok = unsafe { WaitNamedPipeW(&nome, 1) };
    if ok.as_bool() {
        return true;
    }
    let erro = unsafe { GetLastError() };
    erro != ERROR_FILE_NOT_FOUND
}

fn variante_bool(v: bool) -> VARIANT {
    let dentro = VARIANT_0_0 {
        vt: VT_BOOL,
        wReserved1: 0,
        wReserved2: 0,
        wReserved3: 0,
        Anonymous: VARIANT_0_0_0 { boolVal: if v { VARIANT_TRUE } else { VARIANT_FALSE } },
    };
    VARIANT { Anonymous: VARIANT_0 { Anonymous: ManuallyDrop::new(dentro) } }
}

fn variante_i32(v: i32) -> VARIANT {
    let dentro = VARIANT_0_0 {
        vt: VT_I4,
        wReserved1: 0,
        wReserved2: 0,
        wReserved3: 0,
        Anonymous: VARIANT_0_0_0 { lVal: v },
    };
    VARIANT { Anonymous: VARIANT_0 { Anonymous: ManuallyDrop::new(dentro) } }
}

// =============================================================================================
// Estatística
// =============================================================================================

fn resumo(v: &[f64]) -> String {
    if v.is_empty() {
        return "[n=0]".into();
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p = |q: f64| s[((s.len() as f64 - 1.0) * q).round() as usize];
    format!(
        "[n={} min={:.2} p50={:.2} p95={:.2} max={:.2}]",
        s.len(),
        s[0],
        p(0.5),
        p(0.95),
        s[s.len() - 1]
    )
}

// =============================================================================================
// Nomes
// =============================================================================================

fn nome_do_subtipo(g: &GUID) -> String {
    let conhecidos: [(&GUID, &str); 12] = [
        (&MFVideoFormat_NV12, "NV12"),
        (&MFVideoFormat_YUY2, "YUY2"),
        (&MFVideoFormat_MJPG, "MJPG"),
        (&MFVideoFormat_RGB32, "RGB32"),
        (&MFVideoFormat_ARGB32, "ARGB32"),
        (&MFVideoFormat_I420, "I420"),
        (&MFVideoFormat_IYUV, "IYUV"),
        (&MFVideoFormat_YV12, "YV12"),
        (&MFVideoFormat_H264, "H264"),
        (&MFVideoFormat_P010, "P010"),
        (&MFVideoFormat_L8, "L8"),
        (&MFVideoFormat_RGB24, "RGB24"),
    ];
    for (c, n) in conhecidos {
        if c == g {
            return n.to_string();
        }
    }
    // Subtipos de vídeo "FourCC": Data1 é o código de quatro letras.
    let b = g.data1.to_le_bytes();
    if b.iter().all(|c| c.is_ascii_graphic()) {
        return format!("fourcc:{}", String::from_utf8_lossy(&b));
    }
    format!("{g:?}")
}

unsafe fn texto_de(a: &IMFAttributes, chave: &GUID) -> Option<String> {
    let mut p = PWSTR::null();
    let mut n = 0u32;
    unsafe { a.GetAllocatedString(chave, &mut p, &mut n) }.ok()?;
    let s = unsafe { p.to_string() }.ok();
    if !p.is_null() {
        unsafe { CoTaskMemFree(Some(p.0 as *const _)) };
    }
    s
}

unsafe fn descrever_tipo(t: &IMFMediaType) -> String {
    let sub = unsafe { t.GetGUID(&MF_MT_SUBTYPE) }.map(|g| nome_do_subtipo(&g)).unwrap_or_else(|_| "?".into());
    let tam = unsafe { t.GetUINT64(&MF_MT_FRAME_SIZE) }.unwrap_or(0);
    let fps = unsafe { t.GetUINT64(&MF_MT_FRAME_RATE) }.unwrap_or(0);
    let (fn_, fd) = ((fps >> 32) as u32, fps as u32);
    let faixa = match unsafe { t.GetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE) } {
        Ok(v) if v == MFNominalRange_16_235.0 as u32 => " faixa=16-235".to_string(),
        Ok(v) if v == MFNominalRange_0_255.0 as u32 => " faixa=0-255".to_string(),
        Ok(v) => format!(" faixa={v}"),
        Err(_) => String::new(),
    };
    let passo = match unsafe { t.GetUINT32(&MF_MT_DEFAULT_STRIDE) } {
        Ok(v) => format!(" passo={}", v as i32),
        Err(_) => String::new(),
    };
    format!(
        "{sub} {}x{} @{}{}{faixa}{passo}",
        (tam >> 32) as u32,
        tam as u32,
        if fd == 0 { "?".to_string() } else { format!("{:.3}", fn_ as f64 / fd as f64) },
        if fd == 0 { String::new() } else { format!(" ({fn_}/{fd})") },
    )
}

// =============================================================================================
// Placas (só leitura)
// =============================================================================================

fn luid_de(v: u64) -> LUID {
    LUID { LowPart: v as u32, HighPart: (v >> 32) as u32 as i32 }
}

fn luid_u64(l: LUID) -> u64 {
    ((l.HighPart as u32 as u64) << 32) | u64::from(l.LowPart)
}

fn de_utf16(b: &[u16]) -> String {
    let fim = b.iter().position(|c| *c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..fim])
}

/// Os MFTs de encode H.264 de hardware **ligados a esta placa** (`MFTEnum2` com
/// `MFT_ENUM_ADAPTER_LUID`). Enumera, não ativa.
fn encoders_da_placa(luid: u64) -> Vec<String> {
    let mut nomes = Vec::new();
    unsafe {
        let saida = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_H264 };
        let mut a: Option<IMFAttributes> = None;
        if MFCreateAttributes(&mut a, 1).is_err() {
            return nomes;
        }
        let Some(a) = a else { return nomes };
        let l = luid_de(luid);
        let bytes = std::slice::from_raw_parts(&l as *const LUID as *const u8, std::mem::size_of::<LUID>());
        if a.SetBlob(&MFT_ENUM_ADAPTER_LUID, bytes).is_err() {
            return nomes;
        }
        let mut ptr: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n = 0u32;
        let r = MFTEnum2(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            None,
            Some(&saida),
            &a,
            &mut ptr,
            &mut n,
        );
        if r.is_ok() && !ptr.is_null() {
            for i in 0..n as usize {
                // `read` toma posse da referência, e ela cai no fim da volta.
                let item = std::ptr::read(ptr.add(i));
                if let Some(x) = item {
                    nomes.push(texto_de(&x, &MFT_FRIENDLY_NAME_Attribute).unwrap_or_else(|| "(sem nome)".into()));
                }
            }
            CoTaskMemFree(Some(ptr as *const _));
        }
    }
    nomes
}

struct Placa {
    indice: u32,
    nome: String,
    fornecedor: u32,
    luid: u64,
    indireto: Option<bool>,
    encoders: Vec<String>,
}

fn placas() -> Result<Vec<Placa>> {
    let f: IDXGIFactory1 = unsafe { CreateDXGIFactory1()? };
    let mut v = Vec::new();
    let mut i = 0u32;
    loop {
        let a: IDXGIAdapter1 = match unsafe { f.EnumAdapters1(i) } {
            Ok(a) => a,
            Err(_) => break,
        };
        if let Ok(d) = unsafe { a.GetDesc1() } {
            let luid = luid_u64(d.AdapterLuid);
            v.push(Placa {
                indice: i,
                nome: de_utf16(&d.Description),
                fornecedor: d.VendorId,
                luid,
                indireto: device::adaptador_indireto(luid),
                encoders: encoders_da_placa(luid),
            });
        }
        i += 1;
    }
    Ok(v)
}

/// A Intel **de verdade**: fornecedor 0x8086, não indireta, e com um encoder H.264 de hardware
/// ligado a ela. Sem depender da ordem da DXGI — é o defeito que o conserto pendente de
/// `device.rs::create_device` existe para pagar, e esta sonda não mexe nele.
fn placa_intel() -> Result<u64> {
    for p in placas()? {
        if p.fornecedor == device::VENDOR_INTEL && p.indireto == Some(false) && !p.encoders.is_empty() {
            return Ok(p.luid);
        }
    }
    bail!("nenhuma Intel de hardware com encoder H.264 ligado a ela")
}

fn cmd_adaptadores() -> Result<()> {
    for p in placas()? {
        diga!(
            "placa {} | {} | fornecedor 0x{:04X} | luid {:016X} | indireta={} | encoders H.264 de hardware ligados: {}",
            p.indice,
            p.nome,
            p.fornecedor,
            p.luid,
            match p.indireto {
                Some(true) => "sim",
                Some(false) => "não",
                None => "?",
            },
            if p.encoders.is_empty() { "nenhum".to_string() } else { p.encoders.join(" ; ") }
        );
    }
    match placa_intel() {
        Ok(l) => diga!("placa que esta sonda usaria para codificar: luid {l:016X}"),
        Err(e) => diga!("placa que esta sonda usaria para codificar: nenhuma ({e})"),
    }
    Ok(())
}

// =============================================================================================
// Câmeras (enumerar sem ativar)
// =============================================================================================

struct Entrada {
    ativador: IMFActivate,
    nome: String,
    link: String,
}

fn enumerar(categoria: Option<GUID>) -> Result<Vec<Entrada>> {
    unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2)?;
        let attrs = attrs.ok_or_else(|| anyhow!("MFCreateAttributes devolveu nulo"))?;
        attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)?;
        if let Some(c) = categoria {
            attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY, &c)?;
        }
        let mut ptr: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n = 0u32;
        MFEnumDeviceSources(&attrs, &mut ptr, &mut n)?;
        let mut v = Vec::new();
        if !ptr.is_null() {
            for i in 0..n as usize {
                let item = std::ptr::read(ptr.add(i));
                if let Some(a) = item {
                    let nome = texto_de(&a, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME).unwrap_or_default();
                    let link = texto_de(&a, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK)
                        .unwrap_or_default();
                    v.push(Entrada { ativador: a, nome, link });
                }
            }
            CoTaskMemFree(Some(ptr as *const _));
        }
        Ok(v)
    }
}

/// **O dono de uma câmera pela regra do produto** (`cameras::catalogo`, `catalogo_de_cameras`): a
/// sonda e o app decidem com o mesmo código. Até 18/09 a sonda tinha a própria cópia, lida por
/// `reg.exe`; uma regra em dois lugares diverge em silêncio.
fn dono_pelo_produto(link: &str) -> Result<Dono> {
    let lista = cameras::catalogo().map_err(|e| anyhow!(e))?;
    Ok(lista
        .into_iter()
        .find(|c| c.link.eq_ignore_ascii_case(link))
        .map(|c| c.dono)
        .unwrap_or_else(|| Dono::Ilegivel("não enumerada agora".into())))
}

/// `listar`: o catálogo do produto, que é o que o seletor do app mostra (desde a fase 5 sem bandeira). Sem ativar nada.
/// `--repetir S` repete a listagem a cada segundo por S segundos (para uma câmera de bancada criada
/// por outro processo no meio).
fn cmd_listar(args: &[String]) -> Result<()> {
    conferir_relogios();
    let repetir: u64 = match args.iter().position(|a| a == "--repetir") {
        Some(i) => args.get(i + 1).ok_or_else(|| anyhow!("--repetir S"))?.parse()?,
        None => 0,
    };
    diga!("token: {}", descrever_token());
    let fim = Instant::now() + Duration::from_secs(repetir);
    let mut vistas: HashSet<String> = HashSet::new();
    loop {
        match cameras::catalogo() {
            Ok(lista) => {
                let novas: Vec<_> = lista.iter().filter(|c| !vistas.contains(&c.link)).collect();
                if vistas.is_empty() || !novas.is_empty() {
                    diga!("catálogo do produto: {} câmera(s) — NENHUMA foi ativada", lista.len());
                    for l in cameras::linhas_do_registro(&lista) {
                        diga!("  {l}");
                    }
                }
                for c in &lista {
                    vistas.insert(c.link.clone());
                }
            }
            Err(e) => diga!("catálogo do produto: {e}"),
        }
        if Instant::now() >= fim {
            break;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    Ok(())
}

/// O token deste processo está elevado? `TokenElevation`, só leitura. É a testemunha de que a prova
/// sem elevação rodou mesmo sem elevação (a Sessão 0 do SSH entra elevada).
fn descrever_token() -> String {
    use windows::Win32::Security::{GetTokenInformation, TokenElevation, TokenSessionId, TOKEN_ELEVATION, TOKEN_QUERY};
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    unsafe {
        let mut token = windows::Win32::Foundation::HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).is_err() {
            return "(não deu para abrir o token)".into();
        }
        let mut el = TOKEN_ELEVATION::default();
        let mut n = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            Some(&mut el as *mut TOKEN_ELEVATION as *mut core::ffi::c_void),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut n,
        )
        .is_ok();
        let mut sessao = 0u32;
        let _ = GetTokenInformation(
            token,
            TokenSessionId,
            Some(&mut sessao as *mut u32 as *mut core::ffi::c_void),
            4,
            &mut n,
        );
        let _ = windows::Win32::Foundation::CloseHandle(token);
        if ok {
            format!("elevado={} sessão={sessao}", el.TokenIsElevated != 0)
        } else {
            format!("elevação desconhecida, sessão={sessao}")
        }
    }
}

// =============================================================================================
// Encode: o segundo caminho de configuração do MFT (entrada NV12)
// =============================================================================================

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Entrega {
    /// `MFCreateMemoryBuffer` + cópia do NV12 contíguo.
    Memoria,
    /// Cópia para uma textura NV12 nossa (staging → `CopyResource`), entregue por
    /// `MFCreateDXGISurfaceBuffer`: o caminho que a tela já usa, com outro formato.
    Textura,
    /// A amostra do leitor, como veio (só faz sentido com `--leitor-d3d` e superfície DXGI).
    Amostra,
    /// **A fatia *k* de um array** NV12 de 4 fatias, entregue com `sample_from_texture(.., k, ..)`:
    /// a forma da superfície que um decodificador de câmera entrega (G2 da revisão de 18/09). Com
    /// `--subrecurso-errado` a sonda entrega sempre a fatia 0 — o defeito de antes, como controle
    /// negativo: o bitstream tem de sair **diferente** do da `Textura`.
    TexturaArray,
}

/// Como o encoder nasce.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Montagem {
    /// `encoder::ativar_h264_na_placa` + `encoder::configure` com `FormatoDeEntrada::Nv12` +
    /// `tentar_espacamento_de_idr` + `start_stream`: a sequência de `transmissao.rs` com a entrada da
    /// câmera. O padrão desde a fase 2.
    Produto,
    /// Pela `Oficina` do produto com `placa = Some(luid)` e `Preferencia::Produto` — que, sem o LUID,
    /// ativaria o primeiro da ordem de produto (a NVIDIA, na Sessão 0). A prova do M5.
    Oficina,
    /// A negociação própria da sonda (fase 1): lista tudo o que o MFT oferece antes de escolher, e
    /// só com ela o `--declarar-cor` (M6) existe — o `configure` do produto não declara cor.
    Local,
}

/// Quantas fatias o array da `Entrega::TexturaArray` tem.
const FATIAS: u32 = 4;

struct Codificador {
    entrega: Entrega,
    enc: ChosenEncoder,
    eventos: Receiver<MftEvent>,
    creditos: u32,
    contexto: ID3D11DeviceContext,
    _dispositivo: ID3D11Device,
    staging: ID3D11Texture2D,
    anel: Vec<ID3D11Texture2D>,
    proxima: usize,
    arranjo: Option<ID3D11Texture2D>,
    fatia: u32,
    subrecurso_errado: bool,
    montagem: Montagem,
    /// FNV-1a de 64 bits sobre todo o bitstream que saiu, na ordem: é a testemunha de "o mesmo
    /// quadro entrou" entre duas entregas sem gravar arquivo nenhum.
    soma: u64,
    largura: u32,
    altura: u32,
    tipos_oferecidos: Vec<String>,
    aceitos: u64,
    recusados: u64,
    primeira_recusa: Option<String>,
    sem_credito: u64,
    saidas: u64,
    idrs: u64,
    idrs_em: Vec<u64>,
    bytes: u64,
    sps: Option<String>,
    arquivo: Option<std::fs::File>,
    entradas: VecDeque<Instant>,
    latencias_ms: Vec<f64>,
}

unsafe fn tamanho(t: &IMFMediaType, chave: &GUID, a: u32, b: u32) -> windows::core::Result<()> {
    unsafe { t.SetUINT64(chave, ((a as u64) << 32) | b as u64) }
}

impl Codificador {
    #[allow(clippy::too_many_arguments)]
    fn abrir(
        entrega: Entrega,
        largura: u32,
        altura: u32,
        fps: u32,
        bitrate: u32,
        dispositivo: &ID3D11Device,
        contexto: &ID3D11DeviceContext,
        gerenciador: &IMFDXGIDeviceManager,
        luid: u64,
        h264: Option<&str>,
        montagem: Montagem,
        baixa_latencia: bool,
        declarar_cor: bool,
        subrecurso_errado: bool,
    ) -> Result<Self> {
        // A configuração que a câmera usará no produto: a da tela com a entrada NV12. GOP de 1 s,
        // sem refresh intra, sem fatia e sem teto — os padrões de `transmissao.rs` para uma sessão.
        let cfg = encoder::EncoderConfig {
            entrada: encoder::FormatoDeEntrada::Nv12,
            width: largura,
            height: altura,
            fps,
            bitrate_bps: bitrate,
            gop_frames: fps,
            intra_refresh_frames: 0,
            slice_bytes: 0,
            teto_de_quadro_bits: 0,
        };
        let (enc, eventos, tipos_oferecidos) = match montagem {
            Montagem::Produto => {
                let (enc, como) = encoder::ativar_h264_na_placa(luid).context("ativar o MFT da placa")?;
                diga!("encoder: \"{}\" hardware={} ({como}) — montagem do produto", enc.friendly_name, enc.is_hardware);
                encoder::configure(&enc, gerenciador, &cfg).context("encoder::configure com FormatoDeEntrada::Nv12")?;
                let espacamento = encoder::tentar_espacamento_de_idr(&enc, cfg.gop_frames);
                encoder::start_stream(&enc.transform).context("start_stream")?;
                let eventos = encoder::spawn_event_pump(enc.events.clone());
                diga!(
                    "encoder: configure do produto aceitou NV12 {largura}x{altura}@{fps}; MF_MT_MAX_KEYFRAME_SPACING={espacamento}; entrega={entrega:?}"
                );
                (enc, eventos, vec!["(configure do produto: os candidatos saem no stderr)".to_string()])
            }
            Montagem::Oficina => {
                let comeco = Instant::now();
                // Estrita, como a da câmera no produto (`transmissao.rs`; a revisão do código da fase 3, m7).
                let mut oficina = Oficina::abrir(gerenciador, cfg, encoder::Preferencia::Produto, Some(luid), true);
                let prazo = Instant::now() + Duration::from_secs(8);
                let reserva = loop {
                    if let Some(r) = oficina.colher() {
                        break r.context("a oficina montou com erro")?;
                    }
                    if Instant::now() > prazo {
                        bail!("a oficina não entregou a primeira reserva em 8 s");
                    }
                    std::thread::sleep(Duration::from_millis(5));
                };
                // Só a primeira reserva interessa: a oficina não monta outra sem `reciclar`.
                for sobra in oficina.fechar_e_esperar(Duration::from_secs(2)) {
                    let _ = encoder::desligar(&sobra.enc);
                }
                diga!(
                    "encoder: pela oficina — \"{}\" hardware={} montagem_ms={} espaçamento_de_idr={} \
                     (Preferencia::Produto, placa=Some({luid:#x}); colhido em {} ms)",
                    reserva.enc.friendly_name,
                    reserva.enc.is_hardware,
                    reserva.montagem_ms,
                    reserva.espacamento,
                    comeco.elapsed().as_millis()
                );
                (reserva.enc, reserva.eventos, vec!["(oficina do produto)".to_string()])
            }
            Montagem::Local => {
                let (enc, como) = encoder::ativar_h264_na_placa(luid).context("ativar o MFT da placa")?;
                diga!("encoder: \"{}\" hardware={} ({como}) — negociação local", enc.friendly_name, enc.is_hardware);
                let tipos = unsafe { Self::negociar_local(&enc, gerenciador, &cfg, baixa_latencia, declarar_cor)? };
                encoder::start_stream(&enc.transform).context("start_stream")?;
                let eventos = encoder::spawn_event_pump(enc.events.clone());
                (enc, eventos, tipos)
            }
        };

        let desc = D3D11_TEXTURE2D_DESC {
            Width: largura,
            Height: altura,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_NV12,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut anel = Vec::new();
        for _ in 0..6 {
            let mut t: Option<ID3D11Texture2D> = None;
            unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t)) }.context("CreateTexture2D NV12")?;
            anel.push(t.ok_or_else(|| anyhow!("textura nula"))?);
        }
        let arranjo = if entrega == Entrega::TexturaArray {
            // Um array NV12 com `RENDER_TARGET` o driver da Intel recusa (`E_INVALIDARG`, medido em
            // 18/09); o decodificador cria os dele com `DECODER`. Tenta na ordem e diz qual pegou.
            let tentativas: [(&str, u32); 4] = [
                ("RENDER_TARGET", D3D11_BIND_RENDER_TARGET.0 as u32),
                ("DECODER", D3D11_BIND_DECODER.0 as u32),
                ("SHADER_RESOURCE", D3D11_BIND_SHADER_RESOURCE.0 as u32),
                ("nenhum", 0),
            ];
            let mut achado = None;
            let mut recusas = Vec::new();
            for (nome, bind) in tentativas {
                let desc_arr = D3D11_TEXTURE2D_DESC { ArraySize: FATIAS, BindFlags: bind, ..desc };
                let mut t: Option<ID3D11Texture2D> = None;
                match unsafe { dispositivo.CreateTexture2D(&desc_arr, None, Some(&mut t)) } {
                    Ok(()) => {
                        achado = t.map(|t| (nome, t));
                        break;
                    }
                    Err(e) => recusas.push(format!("{nome}: {e}")),
                }
            }
            let Some((nome, t)) = achado else {
                bail!("nenhum array NV12 de {FATIAS} fatias: {}", recusas.join("; "));
            };
            diga!(
                "encoder: array NV12 de {FATIAS} fatias com BindFlags={nome} (recusados antes: [{}]); subrecurso entregue = {}",
                recusas.join("; "),
                if subrecurso_errado { "sempre 0 (controle negativo)" } else { "a fatia escrita" }
            );
            Some(t)
        } else {
            None
        };
        let desc_st = D3D11_TEXTURE2D_DESC {
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
            ..desc
        };
        let mut st: Option<ID3D11Texture2D> = None;
        unsafe { dispositivo.CreateTexture2D(&desc_st, None, Some(&mut st)) }.context("CreateTexture2D staging NV12")?;
        let arquivo = match h264 {
            Some(c) => Some(std::fs::File::create(c).with_context(|| format!("criar {c}"))?),
            None => None,
        };
        Ok(Codificador {
            entrega,
            enc,
            eventos,
            creditos: 0,
            contexto: contexto.clone(),
            _dispositivo: dispositivo.clone(),
            staging: st.ok_or_else(|| anyhow!("staging nula"))?,
            anel,
            proxima: 0,
            arranjo,
            fatia: 0,
            subrecurso_errado,
            montagem,
            soma: 0xcbf2_9ce4_8422_2325,
            largura,
            altura,
            tipos_oferecidos,
            aceitos: 0,
            recusados: 0,
            primeira_recusa: None,
            sem_credito: 0,
            saidas: 0,
            idrs: 0,
            idrs_em: Vec::new(),
            bytes: 0,
            sps: None,
            arquivo,
            entradas: VecDeque::new(),
            latencias_ms: Vec::new(),
        })
    }

    /// A negociação da fase 1, guardada para o que o produto não faz: listar **tudo** o que o MFT
    /// oferece (antes de escolher: depois do `SetInputType` ele oferece só o aceito) e declarar a cor
    /// (`--declarar-cor`, M6) — BT.709, faixa limitada, nos dois tipos. A pergunta do M6 é se o MFT
    /// passa isso para o `video_signal_type` do SPS; quem responde é a linha `sps:` do resumo.
    unsafe fn negociar_local(
        enc: &ChosenEncoder,
        gerenciador: &IMFDXGIDeviceManager,
        cfg: &encoder::EncoderConfig,
        baixa_latencia: bool,
        declarar_cor: bool,
    ) -> Result<Vec<String>> {
        let (largura, altura, fps) = (cfg.width, cfg.height, cfg.fps);
        let cor = |t: &IMFMediaType| -> windows::core::Result<()> {
            if declarar_cor {
                unsafe {
                    t.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32)?;
                    t.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32)?;
                    t.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32)?;
                    t.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709.0 as u32)?;
                }
            }
            Ok(())
        };
        let mut tipos_oferecidos = Vec::new();
        unsafe {
            if let Ok(a) = enc.transform.GetAttributes() {
                let _ = a.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1);
            }
            let unk: windows::core::IUnknown = gerenciador.cast()?;
            enc.transform
                .ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, Interface::as_raw(&unk) as usize)
                .context("MFT_MESSAGE_SET_D3D_MANAGER")?;

            let saida = MFCreateMediaType()?;
            saida.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            saida.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
            saida.SetUINT32(&MF_MT_AVG_BITRATE, cfg.bitrate_bps)?;
            tamanho(&saida, &MF_MT_FRAME_SIZE, largura, altura)?;
            tamanho(&saida, &MF_MT_FRAME_RATE, fps, 1)?;
            saida.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            saida.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base.0 as u32)?;
            if baixa_latencia {
                saida.SetUINT32(&MF_MT_ALL_SAMPLES_INDEPENDENT, 0)?;
            }
            cor(&saida)?;
            enc.transform.SetOutputType(0, &saida, 0).context("SetOutputType H.264")?;

            let mut i = 0u32;
            let mut indice_nv12 = None;
            while let Ok(t) = enc.transform.GetInputAvailableType(0, i) {
                let sub = t.GetGUID(&MF_MT_SUBTYPE).unwrap_or(GUID::zeroed());
                let nome = nome_do_subtipo(&sub);
                tipos_oferecidos.push(if nome.starts_with("fourcc:") { format!("{nome} {sub:?}") } else { nome });
                if sub == MFVideoFormat_NV12 && indice_nv12.is_none() {
                    indice_nv12 = Some(i);
                }
                i += 1;
            }
            let mut escolhido = false;
            if let Some(k) = indice_nv12 {
                let t = enc.transform.GetInputAvailableType(0, k)?;
                tamanho(&t, &MF_MT_FRAME_SIZE, largura, altura)?;
                tamanho(&t, &MF_MT_FRAME_RATE, fps, 1)?;
                cor(&t)?;
                match enc.transform.SetInputType(0, &t, 0) {
                    Ok(()) => escolhido = true,
                    Err(e) => diga!("  SetInputType recusou NV12: {e}"),
                }
            }
            diga!("encoder: tipos de entrada oferecidos, na ordem: {}", tipos_oferecidos.join(", "));
            if !escolhido {
                bail!("o MFT não aceitou NV12 como entrada");
            }
            diga!("encoder: entrada NV12 {largura}x{altura}@{fps} aceita pelo SetInputType; cor declarada={declarar_cor}");
            if baixa_latencia {
                // Os cinco que `encoder.rs::apply_low_latency_params` tenta, na mesma ordem e com os
                // mesmos tipos. "Aplicado" é o retorno da API, não o fluxo.
                if let Some(api) = &enc.codec_api {
                    let pares: [(&str, GUID, VARIANT); 5] = [
                        ("AVLowLatencyMode", CODECAPI_AVLowLatencyMode, variante_bool(true)),
                        ("AVEncMPVGOPSize", CODECAPI_AVEncMPVGOPSize, variante_i32(fps as i32)),
                        (
                            "AVEncCommonRateControlMode",
                            CODECAPI_AVEncCommonRateControlMode,
                            variante_i32(eAVEncCommonRateControlMode_LowDelayVBR.0),
                        ),
                        ("AVEncH264CABACEnable", CODECAPI_AVEncH264CABACEnable, variante_bool(false)),
                        ("AVEncMPVDefaultBPictureCount", CODECAPI_AVEncMPVDefaultBPictureCount, variante_i32(0)),
                    ];
                    let mut linha = Vec::new();
                    for (nome, chave, valor) in pares.iter() {
                        let ok = api.SetValue(chave, valor).is_ok();
                        linha.push(format!("{nome}={}", if ok { "aplicado" } else { "recusado" }));
                    }
                    diga!("encoder: baixa latência do produto — {}", linha.join(" "));
                } else {
                    diga!("encoder: sem ICodecAPI; baixa latência não aplicada");
                }
            }
        }
        Ok(tipos_oferecidos)
    }

    fn tratar(&mut self, ev: MftEvent) {
        match ev {
            MftEvent::NeedInput => self.creditos += 1,
            MftEvent::HaveOutput => match encoder::drain_output(&self.enc.transform, encoder::OUTPUT_STREAM_ID) {
                Ok(v) => {
                    for q in v {
                        self.registrar_saida(q);
                    }
                }
                Err(e) => diga!("aviso: drain_output falhou: {e}"),
            },
            _ => {}
        }
    }

    fn registrar_saida(&mut self, q: encoder::EncodedFrame) {
        if let Some(t) = self.entradas.pop_front() {
            self.latencias_ms.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        if q.is_idr {
            self.idrs += 1;
            self.idrs_em.push(self.saidas);
        }
        if self.sps.is_none() {
            if let Some(r) = sps::resumir(&q.bytes) {
                self.sps = Some(r.linha());
            }
        }
        self.saidas += 1;
        self.bytes += q.bytes.len() as u64;
        for b in &q.bytes {
            self.soma = (self.soma ^ *b as u64).wrapping_mul(0x0000_0100_0000_01b3);
        }
        if let Some(f) = self.arquivo.as_mut() {
            let _ = f.write_all(&q.bytes);
        }
    }

    fn escoar(&mut self) {
        while let Ok(ev) = self.eventos.try_recv() {
            self.tratar(ev);
        }
    }

    /// Uma entrada: espera crédito até 40 ms (o MFT é assíncrono: sem `METransformNeedInput` não
    /// há `ProcessInput`), monta a amostra pela `Entrega` pedida, e espera a saída até 25 ms, como
    /// `transmissao.rs::bombear`.
    fn submeter(&mut self, amostra: &IMFSample, nv12: Option<&[u8]>, ts: i64) {
        self.escoar();
        let prazo = Instant::now() + Duration::from_millis(40);
        while self.creditos == 0 && Instant::now() < prazo {
            if let Ok(ev) = self.eventos.recv_timeout(Duration::from_millis(5)) {
                self.tratar(ev);
            }
        }
        if self.creditos == 0 {
            self.sem_credito += 1;
            return;
        }
        let entrada = match self.montar(amostra, nv12, ts) {
            Ok(a) => a,
            Err(e) => {
                self.recusados += 1;
                self.primeira_recusa.get_or_insert_with(|| format!("montar a amostra: {e:#}"));
                return;
            }
        };
        let antes = self.saidas;
        match unsafe { self.enc.transform.ProcessInput(0, &entrada, 0) } {
            Ok(()) => {
                self.aceitos += 1;
                self.creditos -= 1;
                self.entradas.push_back(Instant::now());
            }
            Err(e) => {
                self.recusados += 1;
                self.primeira_recusa.get_or_insert_with(|| format!("ProcessInput: {e}"));
                return;
            }
        }
        let prazo = Instant::now() + Duration::from_millis(25);
        while self.saidas == antes && Instant::now() < prazo {
            if let Ok(ev) = self.eventos.recv_timeout(Duration::from_millis(4)) {
                self.tratar(ev);
            }
        }
    }

    fn montar(&mut self, amostra: &IMFSample, nv12: Option<&[u8]>, ts: i64) -> Result<IMFSample> {
        const DURACAO: i64 = 333_333;
        match self.entrega {
            Entrega::Amostra => {
                unsafe {
                    amostra.SetSampleTime(ts)?;
                    amostra.SetSampleDuration(DURACAO)?;
                }
                Ok(amostra.clone())
            }
            Entrega::Memoria => {
                let dados = nv12.ok_or_else(|| anyhow!("sem bytes NV12 (a amostra do leitor não é de memória)"))?;
                unsafe {
                    let b = MFCreateMemoryBuffer(dados.len() as u32)?;
                    let mut p: *mut u8 = std::ptr::null_mut();
                    b.Lock(&mut p, None, None)?;
                    std::ptr::copy_nonoverlapping(dados.as_ptr(), p, dados.len());
                    b.Unlock()?;
                    b.SetCurrentLength(dados.len() as u32)?;
                    let s = MFCreateSample()?;
                    s.AddBuffer(&b)?;
                    s.SetSampleTime(ts)?;
                    s.SetSampleDuration(DURACAO)?;
                    Ok(s)
                }
            }
            Entrega::Textura | Entrega::TexturaArray => {
                let dados = nv12.ok_or_else(|| anyhow!("sem bytes NV12 (a amostra do leitor não é de memória)"))?;
                let (w, h) = (self.largura as usize, self.altura as usize);
                if dados.len() < w * h * 3 / 2 {
                    bail!("NV12 curto: {} bytes para {w}x{h}", dados.len());
                }
                unsafe {
                    let mut m = D3D11_MAPPED_SUBRESOURCE::default();
                    self.contexto.Map(&self.staging, 0, D3D11_MAP_WRITE, 0, Some(&mut m))?;
                    let passo = m.RowPitch as usize;
                    let base = m.pData as *mut u8;
                    // A mesma suposição de layout de `escala_nv12.rs` (o plano UV começa em
                    // `RowPitch * altura`), no sentido da escrita.
                    for y in 0..h {
                        std::ptr::copy_nonoverlapping(dados.as_ptr().add(y * w), base.add(y * passo), w);
                    }
                    for y in 0..h / 2 {
                        std::ptr::copy_nonoverlapping(
                            dados.as_ptr().add(w * h + y * w),
                            base.add(passo * h + y * passo),
                            w,
                        );
                    }
                    self.contexto.Unmap(&self.staging, 0);
                }
                if let Some(arranjo) = self.arranjo.clone() {
                    // Fatia k de um array de uma mip só: o subrecurso é k (`D3D11CalcSubresource(0, k, 1)`).
                    let k = self.fatia;
                    self.fatia = (self.fatia + 1) % FATIAS;
                    unsafe { self.contexto.CopySubresourceRegion(&arranjo, k, 0, 0, 0, &self.staging, 0, None) };
                    let entregue = if self.subrecurso_errado { 0 } else { k };
                    Ok(encoder::sample_from_texture(&arranjo, entregue, ts, DURACAO)?)
                } else {
                    let destino = self.anel[self.proxima].clone();
                    self.proxima = (self.proxima + 1) % self.anel.len();
                    unsafe { self.contexto.CopyResource(&destino, &self.staging) };
                    Ok(encoder::sample_from_texture(&destino, 0, ts, DURACAO)?)
                }
            }
        }
    }

    fn fechar(mut self) -> String {
        match encoder::end_stream_and_drain(&self.enc.transform, &self.eventos) {
            Ok(v) => {
                for q in v {
                    self.registrar_saida(q);
                }
            }
            Err(e) => diga!("aviso: drenagem final: {e}"),
        }
        let limpo = encoder::desligar(&self.enc);
        format!(
            "CODIFICADO entrega={:?}{} montagem={:?} aceitos={} recusados={} sem_credito={} saidas={} idrs={} idrs_em={:?} bytes={} \
             fnv64={:016x} latencia_entrada_saida_ms={} desligamento_limpo={limpo} | primeira_recusa={} | sps: {} | tipos_de_entrada=[{}]",
            self.entrega,
            if self.subrecurso_errado { "(subrecurso sempre 0)" } else { "" },
            self.montagem,
            self.aceitos,
            self.recusados,
            self.sem_credito,
            self.saidas,
            self.idrs,
            &self.idrs_em[..self.idrs_em.len().min(12)],
            self.bytes,
            self.soma,
            resumo(&self.latencias_ms),
            self.primeira_recusa.as_deref().unwrap_or("nenhuma"),
            self.sps.as_deref().unwrap_or("(nenhum SPS lido)"),
            self.tipos_oferecidos.join(", "),
        )
    }
}

// =============================================================================================
// ler
// =============================================================================================

struct Opcoes {
    direto: bool,
    link: Option<String>,
    criar_camera: Option<String>,
    compartilhado: bool,
    quadros: u32,
    prazo_s: u64,
    leitor_d3d: bool,
    converter: bool,
    codificar: Option<Entrega>,
    h264: Option<String>,
    bitrate: u32,
    /// Pede ao leitor este tamanho na saída (`--tamanho 1274x716`): é a pergunta "o leitor reduz ao
    /// teto sozinho?". Exige `--converter` ou `--leitor-d3d` (sem processador de vídeo o leitor
    /// não escala).
    tamanho: Option<(u32, u32)>,
    /// Os parâmetros de baixa latência que o produto aplica ao MFT, na negociação local (o
    /// `configure` do produto já os aplica sempre).
    baixa_latencia: bool,
    montagem: Montagem,
    declarar_cor: bool,
    subrecurso_errado: bool,
}

fn ler_opcoes(args: &[String]) -> Result<Opcoes> {
    let mut o = Opcoes {
        direto: false,
        link: None,
        criar_camera: None,
        compartilhado: false,
        quadros: 150,
        prazo_s: 30,
        leitor_d3d: false,
        converter: false,
        codificar: None,
        h264: None,
        bitrate: 6_000_000,
        tamanho: None,
        baixa_latencia: false,
        montagem: Montagem::Produto,
        declarar_cor: false,
        subrecurso_errado: false,
    };
    let mut i = 0;
    while i < args.len() {
        let valor = |i: usize| args.get(i + 1).cloned().ok_or_else(|| anyhow!("falta o valor de {}", args[i]));
        match args[i].as_str() {
            "--direto" => o.direto = true,
            "--link" => {
                o.link = Some(valor(i)?);
                i += 1;
            }
            "--criar-camera" => {
                o.criar_camera = Some(valor(i)?);
                i += 1;
            }
            "--compartilhado" => o.compartilhado = true,
            "--quadros" => {
                o.quadros = valor(i)?.parse()?;
                i += 1;
            }
            "--prazo" => {
                o.prazo_s = valor(i)?.parse()?;
                i += 1;
            }
            "--leitor-d3d" => o.leitor_d3d = true,
            "--baixa-latencia" => o.baixa_latencia = true,
            "--oficina" => o.montagem = Montagem::Oficina,
            "--negociar-local" => o.montagem = Montagem::Local,
            "--declarar-cor" => o.declarar_cor = true,
            "--subrecurso-errado" => o.subrecurso_errado = true,
            "--converter" => o.converter = true,
            "--codificar" => {
                o.codificar = Some(match valor(i)?.as_str() {
                    "memoria" => Entrega::Memoria,
                    "textura" => Entrega::Textura,
                    "amostra" => Entrega::Amostra,
                    "array" => Entrega::TexturaArray,
                    outro => bail!("--codificar {outro}: use memoria, textura, array ou amostra"),
                });
                i += 1;
            }
            "--h264" => {
                o.h264 = Some(valor(i)?);
                i += 1;
            }
            "--bitrate" => {
                o.bitrate = valor(i)?.parse()?;
                i += 1;
            }
            "--tamanho" => {
                let v = valor(i)?;
                let (l, a) = v.split_once('x').ok_or_else(|| anyhow!("--tamanho LxA"))?;
                o.tamanho = Some((l.parse()?, a.parse()?));
                i += 1;
            }
            outro => bail!("opção desconhecida: {outro}"),
        }
        i += 1;
    }
    let origens = o.direto as u8 + o.link.is_some() as u8 + o.criar_camera.is_some() as u8;
    if origens != 1 {
        bail!("escolha exatamente uma origem: --direto, --link <link exato> ou --criar-camera <nome>");
    }
    if o.h264.is_some() && o.codificar.is_none() {
        bail!("--h264 só com --codificar");
    }
    // **Gravar só o que é nosso por construção.** Uma câmera com o dono do Quall não é conteúdo
    // nosso: as baias do `Quall.exe` do usuário mostram a tela do celular dele quando há sessão de
    // exibição no ar. Só `--direto` (com o cano sem nome livre, conferido em `cmd_ler`) e a câmera
    // que esta sonda criou (cano que ninguém serve) entregam o padrão de bancada.
    if o.h264.is_some() && o.link.is_some() {
        bail!("--h264 recusado com --link: a câmera pode estar mostrando o aparelho de alguém");
    }
    if o.compartilhado && o.direto {
        bail!("--compartilhado não tem efeito com --direto (não há Frame Server)");
    }
    if o.tamanho.is_some() && !(o.converter || o.leitor_d3d) {
        bail!("--tamanho sem --converter ou --leitor-d3d não tem efeito: o leitor não escala sem processador");
    }
    if o.baixa_latencia && o.montagem != Montagem::Local {
        bail!("--baixa-latencia só com --negociar-local: o configure do produto já aplica os mesmos cinco sempre");
    }
    if o.declarar_cor && o.montagem != Montagem::Local {
        bail!("--declarar-cor só com --negociar-local: o configure do produto não declara cor");
    }
    if o.subrecurso_errado && o.codificar != Some(Entrega::TexturaArray) {
        bail!("--subrecurso-errado só com --codificar array");
    }
    if o.montagem != Montagem::Produto && o.codificar.is_none() {
        bail!("--oficina e --negociar-local só com --codificar");
    }
    // A amostra do leitor só é superfície DXGI com o gerenciador no leitor; sem ele é memória, e o
    // braço `Amostra` entregaria ao MFT algo que ele não pediu (a revisão de 18/09).
    if o.codificar == Some(Entrega::Amostra) && !o.leitor_d3d {
        bail!("--codificar amostra só com --leitor-d3d");
    }
    Ok(o)
}

/// Acha a câmera pelo link **exato** e só a devolve se o dono for o Quall. Nunca ativa nada aqui.
fn achar_camera_do_quall(link: &str) -> Result<Entrada> {
    let v = enumerar(None)?;
    let Some(e) = v.into_iter().find(|e| e.link.eq_ignore_ascii_case(link)) else {
        bail!("nenhuma câmera enumerada com o link solicitado (link omitido)");
    };
    match dono_pelo_produto(&e.link)? {
        Dono::Quall => Ok(e),
        outro => {
            diga!("RECUSADO: câmera selecionada não é do Quall (dono={outro:?}). Nada foi ativado.");
            std::process::exit(2);
        }
    }
}

/// **A trava do `--link`** (a revisão de código de 18/09, achado 2 do catálogo). O dono Quall não
/// basta: uma baia do `Quall.exe` do usuário tem o mesmo dono e mostra o celular dele. Só passa a
/// câmera de bancada de **outra sonda viva**: o nome enumerado é `"<base> sonda <PID>"` (com ou sem
/// o " (…)" do sistema), e o PID é de um `quall_camera_local.exe` que ainda roda. Qualquer outra
/// câmera do Quall é recusada **antes** do `ActivateObject`.
fn conferir_camera_de_bancada(e: &Entrada) -> Result<u32, String> {
    // A regra mora no produto desde a fase 4 (`--camera-de-bancada` a usa): o nome
    // "<base> sonda <PID>" e o PID de um `quall_camera_local.exe` vivo. O dono Quall já foi conferido
    // por `achar_camera_do_quall`.
    catalogo_de_cameras::conferir_camera_de_bancada(&e.nome, &Dono::Quall, &cameras::imagem_de_processo_vivo)
}

fn cmd_ler(args: &[String]) -> Result<()> {
    let o = ler_opcoes(args)?;
    // **Cão de guarda de fora do laço.** `ReadSample` bloqueante ignora prazo em laço
    // (`integrations/camera-windows/README.md`, achado 3): só outra thread tira o processo daí.
    let limite = o.prazo_s + 20;
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(limite));
        eprintln!("CÃO DE GUARDA: {limite} s sem terminar — saindo com código 3");
        std::process::exit(3);
    });
    conferir_relogios();

    // --- a placa e o dispositivo (só quando algo vai para a GPU) --------------------------------
    let precisa_de_gpu = o.leitor_d3d || o.codificar.is_some();
    let gpu = if precisa_de_gpu {
        let luid = placa_intel()?;
        let a = device::create_device_por_luid(luid)?;
        let antes = device::proteger_contexto(&a.context, true)?;
        let mgr = encoder::create_device_manager(&a.device)?;
        diga!(
            "dispositivo: {} (0x{:04X}) luid {luid:016X} | proteção multithread ligada (antes={antes})",
            a.description, a.vendor_id
        );
        Some((a, mgr, luid))
    } else {
        None
    };

    // --- a origem -------------------------------------------------------------------------------
    let mut _camera_criada: Option<quall_capture_probe::baia::CameraVirtual> = None;
    let mut cano_da_corrida: Option<String> = None;
    let fonte: IMFMediaSource = if o.direto {
        // **Um nome aleatório no repositório da fonte, antes do `Start`.** A fonte lê o nome amigável
        // do próprio repositório no `Start` (`fonte.rs`, `nome_da_camera`) e deriva dele o cano que
        // vai ler (`quadros::cano_do_nome`). Sem nome ela lê o cano sem nome — que o `Quall.exe` do
        // usuário pode passar a servir entre a nossa conferência e o `Start` (a revisão de 18/09).
        // Com um nome que ninguém conhece, o cano é um que ninguém serve, e a janela fecha.
        let nome = format!("quall-sonda-{}-{:x}", std::process::id(), qpc_100ns());
        let cano = quall_camera_fonte::quadros::cano_do_nome(&nome);
        if cano_existe(&cano) {
            diga!("RECUSADO: {cano} existe — alguém o serve. Nada foi instanciado.");
            std::process::exit(2);
        }
        // **O cano sem nome também, antes e depois.** O nome aleatório só vale se a DLL registrada
        // no Windows o lê; uma DLL anterior a 09/09 ignoraria o nome e leria o cano sem nome (a
        // revisão de código de 18/09). A linha "cano desta câmera" do diário da fonte é quem diz
        // qual das duas rodou.
        if cano_existe(quall_camera_fonte::quadros::CANO_SEM_NOME) {
            diga!(
                "RECUSADO: {} existe — com uma DLL que ignore o nome, a fonte leria o que ele manda. Nada foi instanciado.",
                quall_camera_fonte::quadros::CANO_SEM_NOME
            );
            std::process::exit(2);
        }
        let fonte = unsafe {
            CoCreateInstance::<_, IMFMediaSource>(&quall_camera_fonte::CLSID_FONTE, None, CLSCTX_INPROC_SERVER)
        }
        .context("CoCreateInstance da fonte do Quall")?;
        unsafe {
            let ex: IMFMediaSourceEx = fonte.cast().context("a fonte não é IMFMediaSourceEx")?;
            ex.GetSourceAttributes()?
                .SetString(&MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &HSTRING::from(nome.as_str()))
                .context("pôr o nome aleatório no repositório da fonte")?;
        }
        diga!(
            "origem: a fonte do Quall ({}) instanciada NESTE processo — sem nó de dispositivo e sem \
             Frame Server. Nome aleatório \"{nome}\" → {cano}, livre (WaitNamedPipeW: não existe): sem \
             cano, ela entrega o padrão de bancada (nosso). A linha \"cano desta câmera\" do diário da \
             fonte confirma o nome que ela usou.",
            quall_camera_fonte::CLSID_TEXTO
        );
        cano_da_corrida = Some(cano);
        fonte
    } else {
        let link = if let Some(base) = &o.criar_camera {
            // O PID no nome: nenhuma baia do `Quall.exe` (nem outra sonda) nasce com ele, e a busca
            // por prefixo de baixo não casa com câmera alheia (a revisão de 18/09).
            let nome = &catalogo_de_cameras::nome_da_camera_de_bancada(base, std::process::id());
            // **Cria um nó PnP** (vida de sessão, só este usuário): exige o sim do usuário. O nome
            // deriva um cano que ninguém serve, então a fonte entrega o padrão de bancada.
            //
            // A câmera criada é achada por **link novo**, e não por nome: um prefixo de nome casaria
            // com uma baia do `Quall.exe` do usuário ("SM…"), que é dono Quall e pode estar
            // mostrando o celular dele.
            let antes: HashSet<String> =
                enumerar(None)?.into_iter().map(|e| e.link.to_ascii_lowercase()).collect();
            let c = quall_capture_probe::baia::CameraVirtual::criar(nome).context("criar a câmera virtual")?;
            diga!("camera virtual criada (vida de sessão, nome omitido); esperando ela aparecer na enumeração");
            _camera_criada = Some(c);
            let fim = Instant::now() + Duration::from_secs(10);
            loop {
                let achada = enumerar(None)?.into_iter().find(|e| {
                    !antes.contains(&e.link.to_ascii_lowercase())
                        // O nome inteiro, e não prefixo: "X sonda 1234" é prefixo de
                        // "X sonda 12345", a câmera de outra sonda (a revisão de código de 18/09).
                        && catalogo_de_cameras::e_o_nome_pedido(&e.nome, nome)
                        && matches!(dono_pelo_produto(&e.link), Ok(Dono::Quall))
                });
                if let Some(e) = achada {
                    break e.link;
                }
                if Instant::now() > fim {
                    bail!("a câmera criada não apareceu na enumeração em 10 s");
                }
                std::thread::sleep(Duration::from_millis(200));
            }
        } else {
            o.link.clone().unwrap_or_default()
        };
        let e = achar_camera_do_quall(&link)?;
        if o.link.is_some() {
            match conferir_camera_de_bancada(&e) {
                Ok(pid) => diga!("--link: câmera de bancada da sonda viva de PID {pid}"),
                Err(motivo) => {
                    diga!("RECUSADO: --link só abre a câmera de bancada de outra sonda viva — {motivo}. Nada foi ativado.");
                    std::process::exit(2);
                }
            }
        }
        diga!("origem: câmera do Quall pelo Frame Server (nome/link omitidos)");
        if o.compartilhado {
            unsafe { e.ativador.SetUINT32(&MF_DEVSOURCE_ATTRIBUTE_FRAMESERVER_SHARE_MODE, 1) }?;
            diga!("modo compartilhado pedido (MF_DEVSOURCE_ATTRIBUTE_FRAMESERVER_SHARE_MODE=1)");
        }
        unsafe { e.ativador.ActivateObject::<IMFMediaSource>() }.context("ActivateObject")?
    };

    // --- os formatos declarados -----------------------------------------------------------------
    unsafe {
        let pd = fonte.CreatePresentationDescriptor()?;
        let n = pd.GetStreamDescriptorCount()?;
        for s in 0..n {
            let mut sel = windows::core::BOOL(0);
            let mut sd: Option<IMFStreamDescriptor> = None;
            pd.GetStreamDescriptorByIndex(s, &mut sel, &mut sd)?;
            let Some(sd) = sd else { continue };
            let h = sd.GetMediaTypeHandler()?;
            let k = h.GetMediaTypeCount()?;
            diga!("fluxo {s} (selecionado={}): {k} formato(s) declarado(s)", sel.as_bool());
            for j in 0..k.min(40) {
                if let Ok(t) = h.GetMediaTypeByIndex(j) {
                    diga!("  [{j}] {}", descrever_tipo(&t));
                }
            }
        }
    }

    // --- o leitor -------------------------------------------------------------------------------
    let leitor: IMFSourceReader = unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 4)?;
        let attrs = attrs.ok_or_else(|| anyhow!("MFCreateAttributes nulo"))?;
        if o.leitor_d3d {
            let (_, mgr, _) = gpu.as_ref().expect("gpu");
            attrs.SetUnknown(&MF_SOURCE_READER_D3D_MANAGER, mgr)?;
            attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;
            attrs.SetUINT32(&MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1)?;
        } else if o.converter {
            attrs.SetUINT32(&MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1)?;
        }
        MFCreateSourceReaderFromMediaSource(&fonte, &attrs)?
    };
    let fluxo = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
        if let Some((l, a)) = o.tamanho {
            tamanho(&t, &MF_MT_FRAME_SIZE, l, a)?;
        }
        if let Err(e) = leitor.SetCurrentMediaType(fluxo, None, &t) {
            diga!("SetCurrentMediaType(NV12) recusado: {e}");
        }
        let atual = leitor.GetCurrentMediaType(fluxo)?;
        diga!("leitor: tipo atual {} | leitor_d3d={} converter={}", descrever_tipo(&atual), o.leitor_d3d, o.converter);
    }
    let (largura, altura, fps) = unsafe {
        let atual = leitor.GetCurrentMediaType(fluxo)?;
        let tam = atual.GetUINT64(&MF_MT_FRAME_SIZE)?;
        let r = atual.GetUINT64(&MF_MT_FRAME_RATE).unwrap_or((30u64 << 32) | 1);
        let (n, d) = ((r >> 32) as u32, (r as u32).max(1));
        // Arredondado, não truncado: 30000/1001 é 30, e não 29 (a revisão de 18/09).
        ((tam >> 32) as u32, tam as u32, ((n + d / 2) / d).max(1))
    };

    let mut codificador = match (o.codificar, gpu.as_ref()) {
        (Some(entrega), Some((a, mgr, luid))) => Some(Codificador::abrir(
            entrega,
            largura,
            altura,
            fps,
            o.bitrate,
            &a.device,
            &a.context,
            mgr,
            *luid,
            o.h264.as_deref(),
            o.montagem,
            o.baixa_latencia,
            o.declarar_cor,
            o.subrecurso_errado,
        )?),
        _ => None,
    };

    // --- o laço -------------------------------------------------------------------------------
    let t0 = Instant::now();
    let prazo = Duration::from_secs(o.prazo_s);
    let mut lidos = 0u32;
    let mut vazios = 0u32;
    let mut marcas = 0u32;
    let mut erro_de_leitura: Option<String> = None;
    let mut bandeiras_vistas = 0u32;
    let mut ate_o_primeiro_ms = 0.0;
    let mut chegada_anterior: Option<Instant> = None;
    let mut ts_anterior: Option<i64> = None;
    let mut intervalos_ms = Vec::new();
    let mut passos_ts_ms = Vec::new();
    let mut idade_mf_ms = Vec::new();
    let mut idade_qpc_ms = Vec::new();
    let mut ts_diferente_do_sample_time = 0u32;
    let mut com_carimbo_do_dispositivo = 0u32;
    let mut descontinuidades = 0u32;
    let mut dxgi = 0u32;
    let mut memoria = 0u32;
    let mut tamanhos = HashSet::new();
    let mut distintos = HashSet::new();
    let mut subrecursos: HashSet<u32> = HashSet::new();
    let mut tamanhos_de_array: HashSet<u32> = HashSet::new();
    let mut primeiro_ts: Option<i64> = None;

    while lidos < o.quadros && t0.elapsed() < prazo {
        let mut bandeiras = 0u32;
        let mut ts = 0i64;
        let mut amostra: Option<IMFSample> = None;
        if let Err(e) = unsafe {
            leitor.ReadSample(fluxo, 0, None, Some(&mut bandeiras), Some(&mut ts), Some(&mut amostra))
        } {
            erro_de_leitura = Some(format!("ReadSample: {e}"));
            break;
        }
        bandeiras_vistas |= bandeiras;
        if bandeiras & MF_SOURCE_READERF_ERROR.0 as u32 != 0 {
            erro_de_leitura = Some(format!("MF_SOURCE_READERF_ERROR (bandeiras=0x{bandeiras:X})"));
            break;
        }
        if bandeiras & MF_SOURCE_READERF_STREAMTICK.0 as u32 != 0 {
            marcas += 1;
        }
        if bandeiras & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            erro_de_leitura = Some("fim de fluxo".into());
            break;
        }
        let Some(amostra) = amostra else {
            vazios += 1;
            continue;
        };
        let agora_mf = unsafe { MFGetSystemTime() };
        let agora_qpc = qpc_100ns();
        let agora = Instant::now();
        if lidos == 0 {
            ate_o_primeiro_ms = t0.elapsed().as_secs_f64() * 1000.0;
            primeiro_ts = Some(ts);
        }
        if let Some(a) = chegada_anterior {
            intervalos_ms.push((agora - a).as_secs_f64() * 1000.0);
        }
        chegada_anterior = Some(agora);
        if let Some(a) = ts_anterior {
            passos_ts_ms.push((ts - a) as f64 / 10_000.0);
        }
        ts_anterior = Some(ts);
        idade_mf_ms.push((agora_mf - ts) as f64 / 10_000.0);
        idade_qpc_ms.push((agora_qpc - ts) as f64 / 10_000.0);
        unsafe {
            if amostra.GetSampleTime().map(|s| s != ts).unwrap_or(true) {
                ts_diferente_do_sample_time += 1;
            }
            if amostra.GetUINT64(&MFSampleExtension_DeviceTimestamp).is_ok() {
                com_carimbo_do_dispositivo += 1;
            }
            if amostra.GetUINT32(&MFSampleExtension_Discontinuity).map(|v| v != 0).unwrap_or(false) {
                descontinuidades += 1;
            }
        }
        // O buffer: superfície DXGI ou memória? Na memória, um resumo barato do plano Y (passo
        // primo, como `ler.rs` da sonda da câmera virtual) para contar quadros distintos. Nada é
        // guardado além do número.
        let mut bytes_nv12: Option<Vec<u8>> = None;
        unsafe {
            let n = amostra.GetBufferCount().unwrap_or(0);
            let primeiro = if n > 0 { amostra.GetBufferByIndex(0).ok() } else { None };
            let dxgi_buf = primeiro.as_ref().and_then(|b| b.cast::<IMFDXGIBuffer>().ok());
            if let Some(d) = dxgi_buf {
                dxgi += 1;
                // A superfície é fatia de um array de texturas? Quem derivar de `escala.rs`
                // (`ArraySlice: 0`) leria a fatia errada; `escala_nv12.rs` já trata o subrecurso.
                if let Ok(k) = d.GetSubresourceIndex() {
                    subrecursos.insert(k);
                }
                let mut p: *mut core::ffi::c_void = std::ptr::null_mut();
                if d.GetResource(&ID3D11Texture2D::IID, &mut p).is_ok() && !p.is_null() {
                    let t = ID3D11Texture2D::from_raw(p);
                    let mut desc = D3D11_TEXTURE2D_DESC::default();
                    t.GetDesc(&mut desc);
                    tamanhos_de_array.insert(desc.ArraySize);
                }
            } else if let Ok(buf) = amostra.ConvertToContiguousBuffer() {
                memoria += 1;
                let mut p: *mut u8 = std::ptr::null_mut();
                let mut atual = 0u32;
                if buf.Lock(&mut p, None, Some(&mut atual)).is_ok() {
                    let dados = std::slice::from_raw_parts(p, atual as usize);
                    tamanhos.insert(atual);
                    let mut h: u64 = 1469598103934665603;
                    let mut i = 0usize;
                    let fim_y = (largura as usize * altura as usize).min(dados.len());
                    while i < fim_y {
                        h ^= dados[i] as u64;
                        h = h.wrapping_mul(1099511628211);
                        i += 1021;
                    }
                    distintos.insert(h);
                    if codificador.as_ref().is_some_and(|c| c.entrega != Entrega::Amostra) {
                        bytes_nv12 = Some(dados.to_vec());
                    }
                    let _ = buf.Unlock();
                }
            }
        }
        if let Some(c) = codificador.as_mut() {
            let ts_do_encoder = ts - primeiro_ts.unwrap_or(ts);
            c.submeter(&amostra, bytes_nv12.as_deref(), ts_do_encoder);
        }
        lidos += 1;
    }

    diga!(
        "LIDO quadros={lidos} vazios={vazios} marcas_de_fluxo={marcas} ate_o_primeiro_ms={ate_o_primeiro_ms:.1} \
         bandeiras_vistas=0x{bandeiras_vistas:X} erro={}",
        erro_de_leitura.as_deref().unwrap_or("nenhum")
    );
    diga!("  intervalo de chegada ms {}", resumo(&intervalos_ms));
    diga!("  passo do carimbo ms {}", resumo(&passos_ts_ms));
    diga!("  MFGetSystemTime(chegada) - carimbo, ms {}", resumo(&idade_mf_ms));
    diga!("  QPC(chegada) - carimbo, ms {}", resumo(&idade_qpc_ms));
    diga!(
        "  primeiro carimbo={} (100 ns) | ts != GetSampleTime em {ts_diferente_do_sample_time} | com MFSampleExtension_DeviceTimestamp: {com_carimbo_do_dispositivo} | descontinuidades: {descontinuidades}",
        primeiro_ts.unwrap_or(0)
    );
    diga!(
        "  buffers: dxgi={dxgi} memoria={memoria} tamanhos={:?} | quadros distintos (resumo do plano Y) = {}",
        tamanhos,
        distintos.len()
    );
    if dxgi > 0 {
        let mut s: Vec<_> = subrecursos.into_iter().collect();
        s.sort();
        diga!(
            "  superfícies DXGI: índices de subrecurso vistos={:?} | ArraySize das texturas={:?}",
            s,
            tamanhos_de_array
        );
    }
    if let Some(c) = codificador.take() {
        diga!("{}", c.fechar());
    }
    unsafe {
        let _ = fonte.Shutdown();
    }
    // O cano da corrida **no fim** também, e o sem nome no `--direto` (a DLL registrada pode ignorar
    // o nome): se alguém começou a servir um deles no meio, a fonte pode ter entregado o conteúdo
    // dele, e o `.h264` deixa de ser nosso. Apaga sem abrir.
    let apareceu = cano_da_corrida.as_deref().is_some_and(cano_existe)
        || (o.direto && cano_existe(quall_camera_fonte::quadros::CANO_SEM_NOME));
    if apareceu {
        if let Some(arq) = &o.h264 {
            let _ = std::fs::remove_file(arq);
            diga!("APAGADO {arq}: o cano da corrida apareceu; a origem deixou de ser só nossa");
        } else {
            diga!("aviso: o cano da corrida apareceu; os contadores podem não ser do padrão de bancada");
        }
    }
    drop(_camera_criada);
    Ok(())
}

// =============================================================================================
// capturar: a captura de câmera DO PRODUTO (fase 3)
// =============================================================================================

/// `capturar`: a mesma captura que a cadeia do produto usa (`captura_de_camera.rs`): o leitor
/// assíncrono, o tipo nativo escolhido e fixado, a cópia na chegada para o anel, o carimbo decidido
/// uma vez, o recuo para o compartilhado, e as testemunhas de parada. Com `--codificar`, o quadro do
/// anel (ou do conversor) vai para o encoder do produto em NV12, como na cadeia.
///
/// As origens são as de `ler`, com as mesmas travas: `--direto` (a fonte do Quall neste processo, com
/// nome aleatório: nada é aberto além dela), `--link` (só a câmera de bancada de **outra sonda
/// viva**) e `--criar-camera` (cria um nó de vida de sessão: **só com o sim do usuário**).
fn cmd_capturar(args: &[String]) -> Result<()> {
    use quall_capture_probe::captura_de_camera::{CapturaDeCamera, FonteDaCamera};
    use quall_capture_probe::conversor_de_camera::ConversorDeCamera;
    use quall_capture_probe::regras_da_camera::TetoDaCamera;

    let mut direto = false;
    let mut link: Option<String> = None;
    let mut criar: Option<String> = None;
    let mut quadros: u64 = 150;
    let mut prazo_s: u64 = 30;
    let mut codificar = false;
    let mut converter_para: Option<(u32, u32)> = None;
    let mut conferir_a_cada: Option<u64> = None;
    let mut conferir_atrasado = false;
    let mut sem_flush = false;
    let mut com_regua = false;
    let mut compartilhada = false;
    let mut i = 0;
    while i < args.len() {
        let valor = |i: usize| args.get(i + 1).cloned().ok_or_else(|| anyhow!("falta o valor de {}", args[i]));
        match args[i].as_str() {
            "--direto" => direto = true,
            "--conferir-atrasado" => conferir_atrasado = true,
            "--regua" => com_regua = true,
            "--sem-flush" => sem_flush = true,
            // O A/B do desentrelaçador (22/09), como no app: o padrão é o adapt2.
            "--sem-desentrelacar" => quall_capture_probe::captura_de_camera::SEM_DESENTRELACAR.store(true, std::sync::atomic::Ordering::SeqCst),
            "--desentrelacador" => {
                let v = valor(i)?;
                let bob = match v.as_str() {
                    "bob" => true,
                    "adapt2" => false,
                    outro => bail!("--desentrelacador adapt2|bob, e não {outro}"),
                };
                quall_capture_probe::captura_de_camera::DESENTRELACADOR_BOB.store(bob, std::sync::atomic::Ordering::SeqCst);
                i += 1;
            }
            // O R3b (a revisão do código da fase 4, M1): abrir **compartilhada direto** pelo link,
            // sem tentar a controladora antes — e, se ela falhar sem controladora viva neste
            // processo, o recuo do produto para controladora.
            "--compartilhada" => compartilhada = true,
            "--conferir-a-cada" => {
                conferir_a_cada = Some(valor(i)?.parse::<u64>()?.max(1));
                i += 1;
            }
            "--link" => {
                link = Some(valor(i)?);
                i += 1;
            }
            "--criar-camera" => {
                criar = Some(valor(i)?);
                i += 1;
            }
            "--quadros" => {
                quadros = valor(i)?.parse()?;
                i += 1;
            }
            "--prazo" => {
                prazo_s = valor(i)?.parse()?;
                i += 1;
            }
            "--codificar" => codificar = true,
            "--converter-para" => {
                let v = valor(i)?;
                let (l, a) = v.split_once('x').ok_or_else(|| anyhow!("--converter-para LxA"))?;
                converter_para = Some((l.parse()?, a.parse()?));
                i += 1;
            }
            outro => bail!("opção desconhecida: {outro}"),
        }
        i += 1;
    }
    if direto as u8 + link.is_some() as u8 + criar.is_some() as u8 != 1 {
        bail!("escolha exatamente uma origem: --direto, --link <link exato> ou --criar-camera <base>");
    }
    let limite = prazo_s + 20;
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(limite));
        eprintln!("CÃO DE GUARDA: {limite} s sem terminar — saindo com código 3");
        std::process::exit(3);
    });
    conferir_relogios();

    // --- a placa: a Intel de verdade, como a bancada pelo SSH (`--preferir-intel`) ----------------
    let luid = placa_intel()?;
    let a = device::create_device_por_luid(luid)?;
    let antes = device::proteger_contexto(&a.context, true)?;
    let mgr = encoder::create_device_manager(&a.device)?;
    diga!("dispositivo: {} (0x{:04X}) luid {luid:016X} | proteção multithread ligada (antes={antes})", a.description, a.vendor_id);

    // --- a origem ---------------------------------------------------------------------------------
    let mut _camera_criada: Option<quall_capture_probe::baia::CameraVirtual> = None;
    if com_regua && !direto {
        bail!("--regua só com --direto: a câmera criada tem o cano servido pelo `segurar --regua` de outra sonda");
    }
    let fonte = if direto {
        // Com `--regua`, este processo serve o cano do nome aleatório com o quadro de bancada com a
        // régua (`regua_de_bancada`): conteúdo nosso.
        FonteDaCamera::DoQuallNoProcesso { regua: com_regua }
    } else if let Some(base) = &criar {
        // **Cria um nó PnP** (vida de sessão, só este usuário): exige o sim do usuário.
        let (c, achada) = criar_camera_de_bancada(base)?;
        _camera_criada = Some(c);
        FonteDaCamera::Link(achada)
    } else {
        let l = link.clone().unwrap_or_default();
        let e = achar_camera_do_quall(&l)?;
        match conferir_camera_de_bancada(&e) {
            Ok(pid) => diga!("--link: câmera de bancada da sonda viva de PID {pid}"),
            Err(motivo) => {
                diga!("RECUSADO: --link só abre a câmera de bancada de outra sonda viva — {motivo}. Nada foi ativado.");
                std::process::exit(2);
            }
        }
        FonteDaCamera::Link(e.link)
    };

    // --- a captura do produto -------------------------------------------------------------------
    let origem = Instant::now();
    let teto = TetoDaCamera { max_macroblocos: 8_160, fps: 30 };
    let t_abrir = Instant::now();
    if compartilhada && link.is_none() {
        bail!("--compartilhada só com --link");
    }
    let plano = compartilhada.then_some(quall_capture_probe::regras_da_camera::PlanoDaAbertura::SoCompartilhada { outras: 0 });
    let mut captura = match CapturaDeCamera::abrir_com_plano(&a.device, &mgr, &fonte, teto, origem, None, None, plano) {
        Ok(c) => c,
        Err(e) => {
            diga!("A CAPTURA NÃO ABRIU ({} ms): {e}", t_abrir.elapsed().as_millis());
            std::process::exit(4);
        }
    };
    diga!(
        "captura aberta em {} ms: {} {:?} nativo {:?} modo {:?} | {}",
        t_abrir.elapsed().as_millis(),
        captura.geometria.descricao(),
        captura.formato,
        captura.nativo,
        captura.modo,
        captura.descricao
    );
    // **Sem a defesa da T1** (bancada): a amostra volta ao pool sem despachar a cópia antes.
    if sem_flush {
        captura.flush_antes_de_soltar = false;
        diga!("--sem-flush: a amostra volta ao pool sem o Flush do contexto antes (a T1 sem defesa)");
    }
    let conversor = match converter_para {
        Some((l, h)) => {
            let c = ConversorDeCamera::novo(
                &a.device,
                captura.formato.dxgi(),
                captura.width,
                captura.height,
                l,
                h,
                captura.faixa_completa,
                captura.matriz_709,
                captura.entrelacamento_no_anel,
            )
            .map_err(|e| anyhow!("o conversor não subiu: {e}"))?;
            diga!("conversor: {}", c.descricao);
            Some(c)
        }
        None => None,
    };
    let (larg_enc, alt_enc) = conversor.as_ref().map(|c| (c.largura, c.altura)).unwrap_or((captura.width, captura.height));
    let mut codificador = if codificar {
        Some(Codificador::abrir(
            Entrega::Amostra,
            larg_enc,
            alt_enc,
            30,
            6_000_000,
            &a.device,
            &a.context,
            &mgr,
            luid,
            None,
            Montagem::Produto,
            false,
            false,
            false,
        )?)
    } else {
        None
    };

    // --- o laço: quadros, carimbos, e as testemunhas de parada ------------------------------------
    let avisos = captura.frame_ready.clone();
    let link_vigiado = match &fonte {
        FonteDaCamera::Link(l) => Some(l.clone()),
        FonteDaCamera::DoQuallNoProcesso { .. } => None,
    };
    let mut habilitada_antes = link_vigiado.as_deref().map(cameras::interface_habilitada_com_codigo);
    let mut conferencia = ConferenciaDoAnel::default();
    let mut leitura_do_anel: Option<ID3D11Texture2D> = None;
    // A conferência atrasada: (o quadro, a textura do anel dele, os quadros chegados quando ele saiu).
    const ATRASO_DA_CONFERENCIA: u64 = 3;
    let mut atrasados: VecDeque<(u64, ID3D11Texture2D, u64)> = VecDeque::new();
    let mut ultima_conferencia = Instant::now();
    let fim = Instant::now() + Duration::from_secs(prazo_s);
    let mut entregues = 0u64;
    let mut anterior: Option<Instant> = None;
    let mut intervalos_ms: Vec<f64> = Vec::new();
    let mut idades_ms: Vec<f64> = Vec::new();
    let mut falhas_de_conversao = 0u64;
    let mut parou_em: Option<(Instant, String)> = None;
    while entregues < quadros && Instant::now() < fim {
        let _ = avisos.recv_timeout(Duration::from_millis(100));
        if let Some(q) = captura.take_frame() {
            entregues += 1;
            idades_ms.push(Instant::now().saturating_duration_since(q.captured_at).as_secs_f64() * 1000.0);
            if let Some(p) = anterior {
                intervalos_ms.push(q.captured_at.saturating_duration_since(p).as_secs_f64() * 1000.0);
            }
            anterior = Some(q.captured_at);
            // **A leitura de volta do anel** (T1): o quadro que a cópia deixou no anel é o padrão
            // de bancada inteiro, com a barra numa posição só?
            if let Some(n) = conferir_a_cada {
                // **Atrasada** (a reconferência da fase 3): a leitura logo depois da tomada força a
                // cópia a rodar na hora, e não vê a cópia tardia que a T1 descreve. O quadro n é lido
                // só depois de tomar n+3 (o anel tem 6 posições), sem nada no meio que force a GPU.
                if conferir_atrasado {
                    if let Some((alvo, textura, chegados)) = atrasados.front().cloned() {
                        if entregues >= alvo + ATRASO_DA_CONFERENCIA {
                            atrasados.pop_front();
                            let barra = barra_no_anel(&a.device, &a.context, &textura, &mut leitura_do_anel);
                            conferencia.registrar(barra, chegados);
                        }
                    }
                    if entregues % n == 0 {
                        atrasados.push_back((entregues, q.texture.clone(), captura.chegados()));
                    }
                } else if entregues % n == 0 {
                    let barra = barra_no_anel(&a.device, &a.context, &q.texture, &mut leitura_do_anel);
                    conferencia.registrar(barra, captura.chegados());
                }
            }
            if let Some(cod) = codificador.as_mut() {
                let textura = match &conversor {
                    Some(c) => match c.converter(&q.texture) {
                        Ok(t) => t,
                        Err(e) => {
                            falhas_de_conversao += 1;
                            if falhas_de_conversao == 1 {
                                diga!("conversor: o Blt falhou: {e}");
                            }
                            continue;
                        }
                    },
                    None => q.texture.clone(),
                };
                let ts = (q.captured_at.saturating_duration_since(origem).as_nanos() / 100) as i64;
                match encoder::sample_from_texture(&textura, 0, ts, 333_333) {
                    Ok(amostra) => cod.submeter(&amostra, None, ts),
                    Err(e) => diga!("aviso: sample_from_texture: {e}"),
                }
            }
        }
        if ultima_conferencia.elapsed() >= Duration::from_millis(200) {
            ultima_conferencia = Instant::now();
            if let Some(l) = &link_vigiado {
                let agora = cameras::interface_habilitada_com_codigo(l);
                if Some(agora) != habilitada_antes {
                    diga!(
                        "interface habilitada: {:?} → {:?} (CONFIGRET {}, quadro {entregues})",
                        habilitada_antes.and_then(|h| h.0),
                        agora.0,
                        agora.1
                    );
                    habilitada_antes = Some(agora);
                }
            }
            if parou_em.is_none() {
                // A sonda continua parando com a câmera parada (3 s sem quadro), como antes de
                // 22/09: no produto isso deixou de ser fim (a câmera que pausa), aqui é o sinal
                // que as corridas de desconexão leem ("nenhum quadro há 3 s").
                let parada = || {
                    captura
                        .parada_ha(Instant::now())
                        .map(|d| format!("nenhum quadro da câmera há {} s (parada, sem fim do leitor)", d.as_secs()))
                };
                if let Some(m) = captura.motivo_do_fim().or_else(parada) {
                    diga!("A CAPTURA PAROU no quadro {entregues}: {m}");
                    parou_em = Some((Instant::now(), m));
                }
            }
            if let Some((quando, _)) = &parou_em {
                // Dois segundos depois da parada, para as outras testemunhas terem tempo de falar.
                if quando.elapsed() >= Duration::from_secs(2) {
                    break;
                }
            }
        }
    }
    diga!(
        "CAPTURADO entregues={entregues} | intervalo entre carimbos ms {} | idade do carimbo na entrega ms {} | falhas_de_conversao={falhas_de_conversao}",
        resumo(&intervalos_ms),
        resumo(&idades_ms)
    );
    diga!("{}", captura.relato());
    if let Some(n) = conferir_a_cada {
        diga!(
            "{}{}{}",
            conferencia.resumo(n),
            if conferir_atrasado { " | ATRASADA: cada quadro lido depois de tomar mais 3" } else { " | na hora" },
            if sem_flush { " | SEM o Flush" } else { " | com o Flush" }
        );
    }
    if let Some(c) = codificador.take() {
        diga!("{}", c.fechar());
    }
    captura.stop();
    // A soltura sai da thread que para (o R4, M51): a câmera de bancada só sai depois dela.
    let t = Instant::now();
    let presas = quall_capture_probe::captura_de_camera::esperar_solturas(Duration::from_secs(25));
    diga!("soltura da captura: {} em {} ms", if presas == 0 { "acabou" } else { "AINDA PRESA" }, t.elapsed().as_millis());
    drop(_camera_criada);
    Ok(())
}

/// **Cria a câmera de bancada** — um nó PnP de vida de sessão, só deste usuário: **exige o sim do
/// usuário** — e a acha por **link novo**, nome exato ("<base> sonda <PID>") e dono Quall. Devolve a
/// câmera (o nó vive enquanto ela viver) e o link.
fn criar_camera_de_bancada(base: &str) -> Result<(quall_capture_probe::baia::CameraVirtual, String)> {
    let nome = catalogo_de_cameras::nome_da_camera_de_bancada(base, std::process::id());
    let antes: HashSet<String> = enumerar(None)?.into_iter().map(|e| e.link.to_ascii_lowercase()).collect();
    let c = quall_capture_probe::baia::CameraVirtual::criar(&nome).context("criar a câmera virtual")?;
    diga!("câmera virtual criada (vida de sessão, nome omitido); esperando ela aparecer na enumeração");
    let fim = Instant::now() + Duration::from_secs(10);
    loop {
        let achada = enumerar(None)?.into_iter().find(|e| {
            !antes.contains(&e.link.to_ascii_lowercase())
                && catalogo_de_cameras::e_o_nome_pedido(&e.nome, &nome)
                && matches!(dono_pelo_produto(&e.link), Ok(Dono::Quall))
        });
        if let Some(e) = achada {
            diga!("  link={}", e.link);
            return Ok((c, e.link));
        }
        if Instant::now() > fim {
            bail!("a câmera criada não apareceu na enumeração em 10 s");
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// `segurar --criar-camera <base> [--prazo S]`: **cria a câmera de bancada e só a segura**, sem
/// abrir leitor nenhum, por `S` segundos. É o dono do nó do R3 (duas capturas do produto na mesma
/// câmera, e a controladora sai com o nó vivo: a revisão do código da fase 3, T2). **Cria um nó:
/// só com o sim do usuário.**
fn cmd_segurar(args: &[String]) -> Result<()> {
    let mut base: Option<String> = None;
    let mut prazo_s: u64 = 60;
    let mut com_regua = false;
    let mut i = 0;
    while i < args.len() {
        let valor = |i: usize| args.get(i + 1).cloned().ok_or_else(|| anyhow!("falta o valor de {}", args[i]));
        match args[i].as_str() {
            "--criar-camera" => {
                base = Some(valor(i)?);
                i += 1;
            }
            "--prazo" => {
                prazo_s = valor(i)?.parse()?;
                i += 1;
            }
            "--regua" => com_regua = true,
            outro => bail!("opção desconhecida: {outro}"),
        }
        i += 1;
    }
    let base = base.ok_or_else(|| anyhow!("segurar precisa de --criar-camera <base>"))?;
    let limite = prazo_s + 20;
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(limite));
        eprintln!("CÃO DE GUARDA: {limite} s sem terminar — saindo com código 3");
        std::process::exit(3);
    });
    // **O cano da câmera de bancada, servido com a régua** (a fase 4, §7.3): antes de a câmera
    // nascer, para a fonte o achar no primeiro `Start` do Frame Server. O nome é o que a câmera vai
    // ter, e o cano sai dele como a fonte o deriva.
    let regua = com_regua.then(|| {
        let nome = catalogo_de_cameras::nome_da_camera_de_bancada(&base, std::process::id());
        quall_capture_probe::regua_de_bancada::FonteDeRegua::servir(quall_capture_probe::cano::cano_do_nome(&nome))
    });
    if let Some(r) = &regua {
        diga!("régua: servindo {} com o quadro de bancada com a régua, a 30 fps", r.cano);
    }
    let (camera, link) = criar_camera_de_bancada(&base)?;
    diga!("segurando a câmera por {prazo_s} s, sem abrir leitor nenhum");
    let fim = Instant::now() + Duration::from_secs(prazo_s);
    let mut antes = cameras::interface_habilitada_com_codigo(&link);
    diga!("interface: {:?} (CONFIGRET {})", antes.0, antes.1);
    while Instant::now() < fim {
        std::thread::sleep(Duration::from_millis(200));
        let agora = cameras::interface_habilitada_com_codigo(&link);
        if agora != antes {
            diga!("interface: {:?} → {:?} (CONFIGRET {})", antes.0, agora.0, agora.1);
            antes = agora;
        }
    }
    drop(camera);
    diga!("SOLTA: a câmera de bancada saiu com o processo que a segurava");
    if let Some(r) = regua {
        let (publicados, clientes, escritos) = r.contadores();
        diga!("régua: publicados={publicados} clientes_do_cano={clientes} escritos_no_cano={escritos}");
    }
    Ok(())
}

// =============================================================================================
// `capturar --conferir-a-cada N`: a leitura de volta do anel (a revisão do código da fase 3, T1)
// =============================================================================================

/// O que a leitura de volta de um quadro do anel achou da barra do padrão de bancada.
#[derive(Debug, PartialEq, Eq)]
enum Barra {
    /// A barra numa posição só, em todas as linhas conferidas.
    Uma(usize),
    /// Nenhuma linha com a barra (ela está no fim da largura, curta demais para contar).
    Nenhuma,
    /// **Posições diferentes entre linhas**: o quadro do anel é feito de dois quadros da fonte.
    Varias(Vec<(usize, usize)>),
}

/// A barra de uma linha do plano Y do padrão de bancada (`quadros.rs`, `padrao_de_bancada`): a
/// maior corrida de 235 com pelo menos 20 px. A grade (a cada 128 colunas) pode encostar na barra
/// e esticá-la em 1 px de cada lado: uma corrida de 61 ou 62 que começa na grade começa 1 px depois.
fn barra_da_linha(linha: &[u8]) -> Option<usize> {
    let mut melhor: Option<(usize, usize)> = None;
    let mut x = 0;
    while x < linha.len() {
        if linha[x] == 235 {
            let comeco = x;
            while x < linha.len() && linha[x] == 235 {
                x += 1;
            }
            let n = x - comeco;
            if n >= 20 && melhor.is_none_or(|(_, m)| n > m) {
                melhor = Some((comeco, n));
            }
        } else {
            x += 1;
        }
    }
    melhor.map(|(comeco, n)| if n > 60 && comeco % 128 == 0 { comeco + 1 } else { comeco })
}

/// Lê de volta **uma textura do anel** (o padrão de bancada, que é nosso) e procura a barra nas
/// linhas 72, 88, 104… (abaixo da régua; as da grade, múltiplas de 128, ficam de fora). Nada é
/// gravado.
fn barra_no_anel(
    dispositivo: &ID3D11Device,
    contexto: &ID3D11DeviceContext,
    textura: &ID3D11Texture2D,
    leitura: &mut Option<ID3D11Texture2D>,
) -> Result<Barra> {
    use windows::Win32::Graphics::Direct3D11::{D3D11_CPU_ACCESS_READ, D3D11_MAP_READ};
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { textura.GetDesc(&mut desc) };
    let (w, h) = (desc.Width as usize, desc.Height as usize);
    if leitura.is_none() {
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
        desc.MiscFlags = 0;
        let mut t: Option<ID3D11Texture2D> = None;
        unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t)) }.context("textura de leitura do anel")?;
        *leitura = t;
    }
    let l = leitura.clone().ok_or_else(|| anyhow!("sem textura de leitura"))?;
    let mut m = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        contexto.CopyResource(&l, textura);
        contexto.Map(&l, 0, D3D11_MAP_READ, 0, Some(&mut m)).context("Map da leitura do anel")?;
    }
    let mut posicoes: std::collections::BTreeMap<usize, usize> = std::collections::BTreeMap::new();
    let mut sem = 0usize;
    // A partir da linha 72: as 64 de cima podem levar a régua (o quadro de bancada com régua, fase
    // 4), e a barra dele só corre abaixo delas. 72, 88, 104… nunca caem na grade (múltiplas de 128).
    for y in (8 + quall_capture_probe::regua::LADO..h).step_by(16) {
        if y % 128 == 0 {
            continue;
        }
        let linha = unsafe { std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w) };
        match barra_da_linha(linha) {
            Some(p) => *posicoes.entry(p).or_default() += 1,
            None => sem += 1,
        }
    }
    unsafe { contexto.Unmap(&l, 0) };
    Ok(match posicoes.len() {
        0 => Barra::Nenhuma,
        1 if sem == 0 => Barra::Uma(*posicoes.keys().next().unwrap_or(&0)),
        _ => {
            let mut v: Vec<(usize, usize)> = posicoes.into_iter().collect();
            if sem > 0 {
                v.push((usize::MAX, sem));
            }
            Barra::Varias(v)
        }
    })
}

/// O que a conferência juntou numa corrida.
#[derive(Default)]
struct ConferenciaDoAnel {
    conferidos: u64,
    uma_barra: u64,
    rasgados: u64,
    sem_barra: u64,
    erros: u64,
    /// A barra da conferência anterior, e quantos quadros tinham chegado nela.
    anterior: Option<(usize, u64)>,
    /// Quantas vezes o avanço da barra (em quadros da fonte, 8 px por quadro) bateu com os
    /// quadros que chegaram entre duas conferências, e quantas não.
    avanco_igual: u64,
    avanco_diferente: Vec<(u64, u64)>,
}

impl ConferenciaDoAnel {
    fn registrar(&mut self, barra: Result<Barra>, chegados: u64) {
        self.conferidos += 1;
        match barra {
            Ok(Barra::Uma(p)) => {
                self.uma_barra += 1;
                if let Some((pa, ca)) = self.anterior {
                    // A barra anda 8 px por quadro da fonte numa largura de 1920 (240 quadros por volta).
                    let avanco = (((p + 1920 - pa) % 1920) / 8) as u64;
                    let chegaram = (chegados - ca) % 240;
                    if avanco == chegaram {
                        self.avanco_igual += 1;
                    } else if self.avanco_diferente.len() < 20 {
                        self.avanco_diferente.push((avanco, chegaram));
                    }
                }
                self.anterior = Some((p, chegados));
            }
            Ok(Barra::Nenhuma) => {
                self.sem_barra += 1;
                self.anterior = None;
            }
            Ok(Barra::Varias(v)) => {
                self.rasgados += 1;
                if self.rasgados <= 3 {
                    diga!("RASGADO: posições da barra por linha (posição, linhas): {v:?}");
                }
                self.anterior = None;
            }
            Err(e) => {
                self.erros += 1;
                if self.erros <= 3 {
                    diga!("aviso: a leitura de volta do anel falhou: {e:#}");
                }
                self.anterior = None;
            }
        }
    }

    fn resumo(&self, a_cada: u64) -> String {
        format!(
            "CONFERIDO o anel a cada {a_cada} entregues: conferidos={} uma_barra={} rasgados={} sem_barra={} erros={} | \
             o avanço da barra bateu com os quadros chegados em {} de {} pares; diferentes (avanço, chegados): {:?}",
            self.conferidos,
            self.uma_barra,
            self.rasgados,
            self.sem_barra,
            self.erros,
            self.avanco_igual,
            self.avanco_igual + self.avanco_diferente.len() as u64,
            self.avanco_diferente
        )
    }
}



// =============================================================================================
// `anel`: a cópia na chegada e o conversor, com texturas sintéticas (fase 3, sem câmera)
// =============================================================================================

/// Um campo de cor de três faixas verticais: (Y, U, V) de cada terço da largura.
type Faixas = [(u8, u8, u8); 3];

fn faixa_de(faixas: &Faixas, x: u32, w: u32) -> (u8, u8, u8) {
    faixas[((x * 3) / w).min(2) as usize]
}

/// Uma textura NV12 ou YUY2 de `faixas.len()` fatias, com as faixas da fatia k em `faixas[k]`. Cada
/// fatia é pintada numa textura de preparo de uma fatia só (o Intel recusa preparo NV12 em array,
/// `E_INVALIDARG`) e copiada para a fatia k da textura padrão.
fn textura_sintetica(
    dispositivo: &ID3D11Device,
    contexto: &ID3D11DeviceContext,
    formato: windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT,
    w: u32,
    h: u32,
    faixas: &[Faixas],
) -> Result<ID3D11Texture2D> {
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_YUY2;
    let fatias = faixas.len() as u32;
    let desc_preparo = D3D11_TEXTURE2D_DESC {
        Width: w,
        Height: h,
        MipLevels: 1,
        ArraySize: 1,
        Format: formato,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
        MiscFlags: 0,
    };
    let mut preparo: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc_preparo, None, Some(&mut preparo)) }.context("preparo sintético")?;
    let preparo = preparo.ok_or_else(|| anyhow!("sem preparo"))?;
    let mut alvo: Option<ID3D11Texture2D> = None;
    let mut ultimo = None;
    for bind in [
        (D3D11_BIND_DECODER.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
        D3D11_BIND_SHADER_RESOURCE.0 as u32,
        D3D11_BIND_DECODER.0 as u32,
        0,
    ] {
        let desc = D3D11_TEXTURE2D_DESC {
            ArraySize: fatias,
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: bind,
            CPUAccessFlags: 0,
            ..desc_preparo
        };
        let mut t: Option<ID3D11Texture2D> = None;
        match unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t)) } {
            Ok(()) => {
                alvo = t;
                break;
            }
            Err(e) => ultimo = Some(e),
        }
    }
    let alvo = alvo.ok_or_else(|| anyhow!("textura sintética {formato:?} {w}x{h}x{fatias}: {:?}", ultimo))?;
    for (k, f) in faixas.iter().enumerate() {
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe { contexto.Map(&preparo, 0, D3D11_MAP_WRITE, 0, Some(&mut m)) }.context("Map do preparo")?;
        let p = m.pData as *mut u8;
        let passo = m.RowPitch as usize;
        unsafe {
            if formato == DXGI_FORMAT_YUY2 {
                for y in 0..h as usize {
                    let linha = p.add(y * passo);
                    for x in 0..(w / 2) as usize {
                        let (yy, u, v) = faixa_de(f, (x * 2) as u32, w);
                        *linha.add(x * 4) = yy;
                        *linha.add(x * 4 + 1) = u;
                        *linha.add(x * 4 + 2) = yy;
                        *linha.add(x * 4 + 3) = v;
                    }
                }
            } else {
                for y in 0..h as usize {
                    let linha = p.add(y * passo);
                    for x in 0..w as usize {
                        *linha.add(x) = faixa_de(f, x as u32, w).0;
                    }
                }
                let uv = p.add(h as usize * passo);
                for y in 0..(h / 2) as usize {
                    let linha = uv.add(y * passo);
                    for x in 0..(w / 2) as usize {
                        let (_, u, v) = faixa_de(f, (x * 2) as u32, w);
                        *linha.add(x * 2) = u;
                        *linha.add(x * 2 + 1) = v;
                    }
                }
            }
            contexto.Unmap(&preparo, 0);
            contexto.CopySubresourceRegion(&alvo, k as u32, 0, 0, 0, &preparo, 0, None);
        }
    }
    Ok(alvo)
}

/// Lê de volta uma textura NV12 **nossa** (sintética, ou a saída do conversor dela) e mede, por
/// faixa, a média de Y, U e V no miolo da faixa, e quantos bytes da textura inteira diferem do
/// esperado exato. Nada é gravado.
struct Leitura {
    medias: [(f64, f64, f64); 3],
    diferentes: u64,
}

fn ler_nv12(
    dispositivo: &ID3D11Device,
    contexto: &ID3D11DeviceContext,
    textura: &ID3D11Texture2D,
    esperado: Option<&Faixas>,
) -> Result<Leitura> {
    use windows::Win32::Graphics::Direct3D11::{D3D11_CPU_ACCESS_READ, D3D11_MAP_READ};
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { textura.GetDesc(&mut desc) };
    let (w, h) = (desc.Width, desc.Height);
    desc.ArraySize = 1;
    desc.MipLevels = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
    desc.MiscFlags = 0;
    let mut leitura: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut leitura)) }.context("textura de leitura")?;
    let leitura = leitura.ok_or_else(|| anyhow!("sem leitura"))?;
    let mut m = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        contexto.CopySubresourceRegion(&leitura, 0, 0, 0, 0, textura, 0, None);
        contexto.Map(&leitura, 0, D3D11_MAP_READ, 0, Some(&mut m)).context("Map da leitura")?;
    }
    let p = m.pData as *const u8;
    let passo = m.RowPitch as usize;
    let mut somas = [(0f64, 0f64, 0f64, 0u64); 3];
    let mut diferentes = 0u64;
    unsafe {
        for y in 0..h {
            let linha = p.add(y as usize * passo);
            for x in 0..w {
                let v = *linha.add(x as usize);
                let f = ((x * 3) / w).min(2) as usize;
                if let Some(e) = esperado {
                    if v != faixa_de(e, x, w).0 {
                        diferentes += 1;
                    }
                }
                // O miolo: longe das bordas entre as faixas e das bordas da imagem.
                let dentro = x % (w / 3) > w / 12 && x % (w / 3) < w / 3 - w / 12 && y > h / 8 && y < h - h / 8;
                if dentro {
                    somas[f].0 += v as f64;
                    somas[f].3 += 1;
                }
            }
        }
        let uv = p.add(h as usize * passo);
        let mut contagem_uv = [0u64; 3];
        for y in 0..h / 2 {
            let linha = uv.add(y as usize * passo);
            for x in 0..w / 2 {
                let (u, v) = (*linha.add(x as usize * 2), *linha.add(x as usize * 2 + 1));
                let f = ((x * 2 * 3) / w).min(2) as usize;
                if let Some(e) = esperado {
                    let (_, eu, ev) = faixa_de(e, x * 2, w);
                    diferentes += (u != eu) as u64 + (v != ev) as u64;
                }
                let xx = x * 2;
                let dentro = xx % (w / 3) > w / 12 && xx % (w / 3) < w / 3 - w / 12 && y * 2 > h / 8 && y * 2 < h - h / 8;
                if dentro {
                    somas[f].1 += u as f64;
                    somas[f].2 += v as f64;
                    contagem_uv[f] += 1;
                }
            }
        }
        contexto.Unmap(&leitura, 0);
        let mut medias = [(0.0, 0.0, 0.0); 3];
        for f in 0..3 {
            medias[f] = (
                somas[f].0 / somas[f].3.max(1) as f64,
                somas[f].1 / contagem_uv[f].max(1) as f64,
                somas[f].2 / contagem_uv[f].max(1) as f64,
            );
        }
        Ok(Leitura { medias, diferentes })
    }
}

/// Pinta um quadro NV12 `qw`×`qh` (passo `passo`, o UV depois de `qh` linhas) com as faixas dentro
/// do retângulo `(x0, y0, w, h)` — a faixa pela posição **dentro** dele — e `lixo` fora. É o quadro
/// alinhado de um decodificador (a imagem num quadro maior), para provar a cópia pela abertura.
#[allow(clippy::too_many_arguments)]
unsafe fn pintar_com_moldura(p: *mut u8, passo: usize, qw: u32, qh: u32, retangulo: (u32, u32, u32, u32), f: &Faixas, lixo: (u8, u8, u8)) {
    let (x0, y0, w, h) = retangulo;
    let dentro = |x: u32, y: u32| x >= x0 && x < x0 + w && y >= y0 && y < y0 + h;
    unsafe {
        for y in 0..qh {
            for x in 0..qw {
                *p.add(y as usize * passo + x as usize) = if dentro(x, y) { faixa_de(f, x - x0, w).0 } else { lixo.0 };
            }
        }
        let uv = p.add(qh as usize * passo);
        for y in 0..qh / 2 {
            for x in 0..qw / 2 {
                let (xx, yy) = (x * 2, y * 2);
                let (_, u, v) = if dentro(xx, yy) { faixa_de(f, xx - x0, w) } else { lixo };
                *uv.add(y as usize * passo + xx as usize) = u;
                *uv.add(y as usize * passo + xx as usize + 1) = v;
            }
        }
    }
}

/// Uma textura NV12 `qw`×`qh` pintada por [`pintar_com_moldura`], de fatia única.
fn textura_com_moldura(
    dispositivo: &ID3D11Device,
    contexto: &ID3D11DeviceContext,
    qw: u32,
    qh: u32,
    retangulo: (u32, u32, u32, u32),
    f: &Faixas,
    lixo: (u8, u8, u8),
) -> Result<ID3D11Texture2D> {
    let desc_preparo = D3D11_TEXTURE2D_DESC {
        Width: qw,
        Height: qh,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_NV12,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
        MiscFlags: 0,
    };
    let mut preparo: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc_preparo, None, Some(&mut preparo)) }.context("preparo com moldura")?;
    let preparo = preparo.ok_or_else(|| anyhow!("sem preparo"))?;
    let mut m = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        contexto.Map(&preparo, 0, D3D11_MAP_WRITE, 0, Some(&mut m)).context("Map do preparo com moldura")?;
        pintar_com_moldura(m.pData as *mut u8, m.RowPitch as usize, qw, qh, retangulo, f, lixo);
        contexto.Unmap(&preparo, 0);
    }
    let desc = D3D11_TEXTURE2D_DESC {
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: (D3D11_BIND_DECODER.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
        CPUAccessFlags: 0,
        ..desc_preparo
    };
    let mut t: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut t)) }.context("textura com moldura")?;
    let t = t.ok_or_else(|| anyhow!("sem textura"))?;
    unsafe { contexto.CopyResource(&t, &preparo) };
    Ok(t)
}

/// Um YUY2 `w`x`h` em pente: as linhas pares com Y `y_par`, as ímpares com `y_impar`, croma neutro.
/// Conteúdo nosso, para o teste de desentrelaçar (a fase 5).
fn textura_pente_yuy2(dispositivo: &ID3D11Device, contexto: &ID3D11DeviceContext, w: u32, h: u32, y_par: u8, y_impar: u8) -> Result<ID3D11Texture2D> {
    use quall_capture_probe::captura_de_camera::textura_do_anel;
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_YUY2;
    let desc = D3D11_TEXTURE2D_DESC {
        Width: w,
        Height: h,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_YUY2,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
        MiscFlags: 0,
    };
    let mut preparo: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut preparo)) }.context("preparo do pente")?;
    let preparo = preparo.ok_or_else(|| anyhow!("sem preparo do pente"))?;
    let alvo = textura_do_anel(dispositivo, DXGI_FORMAT_YUY2, w, h).context("o pente YUY2")?;
    unsafe {
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        contexto.Map(&preparo, 0, D3D11_MAP_WRITE, 0, Some(&mut m)).context("Map do pente")?;
        let p = m.pData as *mut u8;
        for y in 0..h as usize {
            let linha = p.add(y * m.RowPitch as usize);
            let yy = if y % 2 == 0 { y_par } else { y_impar };
            for x in 0..(w / 2) as usize {
                *linha.add(x * 4) = yy;
                *linha.add(x * 4 + 1) = 128;
                *linha.add(x * 4 + 2) = yy;
                *linha.add(x * 4 + 3) = 128;
            }
        }
        contexto.Unmap(&preparo, 0);
        contexto.CopyResource(&alvo, &preparo);
    }
    Ok(alvo)
}

/// O Y médio de cada linha de uma textura NV12 nossa (a saída do conversor), lido de volta.
fn luma_por_linha(dispositivo: &ID3D11Device, contexto: &ID3D11DeviceContext, textura: &ID3D11Texture2D) -> Result<Vec<f64>> {
    use windows::Win32::Graphics::Direct3D11::{D3D11_CPU_ACCESS_READ, D3D11_MAP_READ};
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { textura.GetDesc(&mut desc) };
    let (w, h) = (desc.Width as usize, desc.Height as usize);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
    desc.MiscFlags = 0;
    let mut leitura: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut leitura)) }.context("leitura por linha")?;
    let leitura = leitura.ok_or_else(|| anyhow!("sem leitura"))?;
    let mut linhas = Vec::with_capacity(h);
    unsafe {
        contexto.CopyResource(&leitura, textura);
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        contexto.Map(&leitura, 0, D3D11_MAP_READ, 0, Some(&mut m)).context("Map da leitura por linha")?;
        let p = m.pData as *const u8;
        for y in 0..h {
            let linha = std::slice::from_raw_parts(p.add(y * m.RowPitch as usize), w);
            linhas.push(linha.iter().map(|v| f64::from(*v)).sum::<f64>() / w as f64);
        }
        contexto.Unmap(&leitura, 0);
    }
    Ok(linhas)
}

/// O U e o V médios de cada linha do plano de croma de uma textura NV12 nossa, lidos de volta.
fn croma_por_linha(dispositivo: &ID3D11Device, contexto: &ID3D11DeviceContext, textura: &ID3D11Texture2D) -> Result<Vec<(f64, f64)>> {
    use windows::Win32::Graphics::Direct3D11::{D3D11_CPU_ACCESS_READ, D3D11_MAP_READ};
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { textura.GetDesc(&mut desc) };
    let (w, h) = (desc.Width as usize, desc.Height as usize);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
    desc.MiscFlags = 0;
    let mut leitura: Option<ID3D11Texture2D> = None;
    unsafe { dispositivo.CreateTexture2D(&desc, None, Some(&mut leitura)) }.context("leitura do croma")?;
    let leitura = leitura.ok_or_else(|| anyhow!("sem leitura do croma"))?;
    let mut linhas = Vec::with_capacity(h / 2);
    unsafe {
        contexto.CopyResource(&leitura, textura);
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        contexto.Map(&leitura, 0, D3D11_MAP_READ, 0, Some(&mut m)).context("Map do croma")?;
        let p = m.pData as *const u8;
        // O plano UV começa depois das `h` linhas do Y, com o mesmo passo.
        for y in 0..h / 2 {
            let linha = std::slice::from_raw_parts(p.add((h + y) * m.RowPitch as usize), w);
            let (mut u, mut v) = (0f64, 0f64);
            for par in linha.chunks_exact(2) {
                u += f64::from(par[0]);
                v += f64::from(par[1]);
            }
            linhas.push((u / (w / 2) as f64, v / (w / 2) as f64));
        }
        contexto.Unmap(&leitura, 0);
    }
    Ok(linhas)
}

/// O custo de um `Blt` do conversor, com a espera da GPU (uma consulta de evento depois de cada um):
/// a mediana de `n`, em ms.
fn custo_do_blt(
    dispositivo: &ID3D11Device,
    contexto: &ID3D11DeviceContext,
    conv: &quall_capture_probe::conversor_de_camera::ConversorDeCamera,
    entrada: &ID3D11Texture2D,
    n: usize,
) -> Result<f64> {
    use windows::Win32::Graphics::Direct3D11::{ID3D11Query, D3D11_QUERY_DESC, D3D11_QUERY_EVENT};
    let desc = D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 };
    let mut consulta: Option<ID3D11Query> = None;
    unsafe { dispositivo.CreateQuery(&desc, Some(&mut consulta)) }.context("CreateQuery")?;
    let consulta = consulta.ok_or_else(|| anyhow!("sem consulta"))?;
    let mut tempos = Vec::with_capacity(n);
    for _ in 0..n {
        let t0 = std::time::Instant::now();
        let _ = conv.converter(entrada).map_err(|e| anyhow!("Blt: {e}"))?;
        unsafe {
            contexto.End(&consulta);
            let mut feito: u32 = 0;
            while contexto.GetData(&consulta, Some(&mut feito as *mut u32 as *mut core::ffi::c_void), 4, 0).is_err() || feito == 0 {
                std::hint::spin_loop();
                if t0.elapsed() > std::time::Duration::from_secs(1) {
                    break;
                }
            }
        }
        tempos.push(t0.elapsed().as_secs_f64() * 1000.0);
    }
    tempos.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    Ok(tempos[tempos.len() / 2])
}

fn amostra_de(buffer: &IMFMediaBuffer) -> Result<IMFSample> {
    let s = unsafe { MFCreateSample() }.context("MFCreateSample")?;
    unsafe { s.AddBuffer(buffer) }.context("AddBuffer")?;
    Ok(s)
}

/// A regra da faixa: completa (0–255) → limitada (16–235 no Y, 16–240 no croma).
fn para_limitada(f: &Faixas) -> [(f64, f64, f64); 3] {
    let mut r = [(0.0, 0.0, 0.0); 3];
    for (i, (y, u, v)) in f.iter().enumerate() {
        r[i] = (
            16.0 + (*y as f64) * 219.0 / 255.0,
            128.0 + (*u as f64 - 128.0) * 224.0 / 255.0,
            128.0 + (*v as f64 - 128.0) * 224.0 / 255.0,
        );
    }
    r
}

fn pior_desvio(medidas: &[(f64, f64, f64); 3], esperadas: &[(f64, f64, f64); 3]) -> f64 {
    let mut pior = 0f64;
    for i in 0..3 {
        pior = pior
            .max((medidas[i].0 - esperadas[i].0).abs())
            .max((medidas[i].1 - esperadas[i].1).abs())
            .max((medidas[i].2 - esperadas[i].2).abs());
    }
    pior
}

fn medias_texto(m: &[(f64, f64, f64); 3]) -> String {
    m.iter().map(|(y, u, v)| format!("({y:.1},{u:.1},{v:.1})")).collect::<Vec<_>>().join(" ")
}

/// **O anel com texturas sintéticas.** O mesmo código da captura (`copiar_amostra`) e o mesmo
/// conversor (`ConversorDeCamera`), com amostras que esta sonda monta de texturas dela. Nenhuma
/// câmera é ativada, nenhum nó é criado, nada é gravado.
fn cmd_anel() -> Result<()> {
    use quall_capture_probe::captura_de_camera::{copiar_amostra, textura_do_anel, CaminhoDaCopia, FormatoDoLeitor};
    use quall_capture_probe::regras_da_camera::{Entrelacamento, Geometria};
    use quall_capture_probe::conversor_de_camera::ConversorDeCamera;
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_YUY2;

    let (w, h) = (1280u32, 720u32);
    let luid = placa_intel()?;
    let a = device::create_device_por_luid(luid)?;
    let antes = device::proteger_contexto(&a.context, true)?;
    diga!("dispositivo: {} (0x{:04X}) luid {luid:016X} | proteção multithread ligada (antes={antes})", a.description, a.vendor_id);
    let (d, c) = (&a.device, &a.context);
    let mut falhas = 0u32;
    let mut julgar = |nome: &str, ok: bool, detalhe: String| {
        if !ok {
            falhas += 1;
        }
        diga!("{} {nome}: {detalhe}", if ok { "PASSOU" } else { "FALHOU" });
    };

    // --- 1. o array NV12 de 4 fatias, visitado fora de ordem: a fatia certa -----------------------
    let fatias: Vec<Faixas> = (0..4u8)
        .map(|k| [(30 + 40 * k, 100 + k, 150 - k), (60 + 40 * k, 110 + k, 140 - k), (90 + 40 * k, 120 + k, 130 - k)])
        .collect();
    let array = textura_sintetica(d, c, DXGI_FORMAT_NV12, w, h, &fatias)?;
    let anel: Vec<ID3D11Texture2D> = (0..6)
        .map(|_| textura_do_anel(d, DXGI_FORMAT_NV12, w, h))
        .collect::<windows::core::Result<_>>()
        .context("o anel NV12")?;
    let mut preparo: Option<ID3D11Texture2D> = None;
    for (i, k) in [2u32, 0, 3, 1].into_iter().enumerate() {
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &array, k, false) }.context("MFCreateDXGISurfaceBuffer")?;
        let amostra = amostra_de(&buffer)?;
        let destino = &anel[i % anel.len()];
        let caminho = copiar_amostra(d, c, &amostra, destino, Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo).map_err(|e| anyhow!(e))?;
        let l = ler_nv12(d, c, destino, Some(&fatias[k as usize]))?;
        julgar(
            &format!("array NV12, fatia {k} para o anel[{}]", i % anel.len()),
            caminho == (CaminhoDaCopia::Gpu { subrecurso: k, fatias: 4, recorta: false }) && l.diferentes == 0,
            format!("caminho {caminho:?}, bytes diferentes da fatia {k}: {}", l.diferentes),
        );
    }

    // --- 2. a memória: buffer 2D (passo próprio) e buffer linear ----------------------------------
    let f_mem: Faixas = [(200, 90, 60), (50, 170, 200), (128, 128, 128)];
    unsafe {
        let buffer = MFCreate2DMediaBuffer(w, h, MFVideoFormat_NV12.data1, false).context("MFCreate2DMediaBuffer")?;
        let b2: IMF2DBuffer2 = buffer.cast().context("IMF2DBuffer2")?;
        let (mut base, mut passo, mut inicio, mut tamanho) = (std::ptr::null_mut::<u8>(), 0i32, std::ptr::null_mut::<u8>(), 0u32);
        b2.Lock2DSize(MF2DBuffer_LockFlags_Write, &mut base, &mut passo, &mut inicio, &mut tamanho).context("Lock2DSize")?;
        let passo = passo as usize;
        for y in 0..h as usize {
            for x in 0..w as usize {
                *base.add(y * passo + x) = faixa_de(&f_mem, x as u32, w).0;
            }
        }
        for y in 0..(h / 2) as usize {
            for x in 0..(w / 2) as usize {
                let (_, u, v) = faixa_de(&f_mem, (x * 2) as u32, w);
                *base.add((h as usize + y) * passo + x * 2) = u;
                *base.add((h as usize + y) * passo + x * 2 + 1) = v;
            }
        }
        let _ = b2.Unlock2D();
        let _ = buffer.SetCurrentLength(tamanho);
        let amostra = amostra_de(&buffer)?;
        let caminho = copiar_amostra(d, c, &amostra, &anel[4], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo).map_err(|e| anyhow!(e))?;
        let l = ler_nv12(d, c, &anel[4], Some(&f_mem))?;
        julgar(
            "memória 2D NV12",
            caminho == CaminhoDaCopia::Memoria && l.diferentes == 0,
            format!("passo {passo} para {w}, caminho {caminho:?}, bytes diferentes: {}", l.diferentes),
        );

        let n = (w * h * 3 / 2) as usize;
        let linear = MFCreateMemoryBuffer(n as u32).context("MFCreateMemoryBuffer")?;
        let mut base: *mut u8 = std::ptr::null_mut();
        linear.Lock(&mut base, None, None).context("Lock")?;
        for y in 0..h as usize {
            for x in 0..w as usize {
                *base.add(y * w as usize + x) = faixa_de(&f_mem, x as u32, w).0;
            }
        }
        for y in 0..(h / 2) as usize {
            for x in 0..(w / 2) as usize {
                let (_, u, v) = faixa_de(&f_mem, (x * 2) as u32, w);
                *base.add((h as usize + y) * w as usize + x * 2) = u;
                *base.add((h as usize + y) * w as usize + x * 2 + 1) = v;
            }
        }
        let _ = linear.Unlock();
        let _ = linear.SetCurrentLength(n as u32);
        let amostra = amostra_de(&linear)?;
        let caminho = copiar_amostra(d, c, &amostra, &anel[5], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo).map_err(|e| anyhow!(e))?;
        let l = ler_nv12(d, c, &anel[5], Some(&f_mem))?;
        julgar(
            "memória linear NV12",
            caminho == CaminhoDaCopia::Memoria && l.diferentes == 0,
            format!("caminho {caminho:?}, bytes diferentes: {}", l.diferentes),
        );

        // Curto demais: recusado, sem ler além do fim.
        let curto = MFCreateMemoryBuffer((n / 2) as u32).context("MFCreateMemoryBuffer curto")?;
        let _ = curto.SetCurrentLength((n / 2) as u32);
        let amostra = amostra_de(&curto)?;
        let r = copiar_amostra(d, c, &amostra, &anel[5], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo);
        julgar("buffer curto recusado", r.is_err(), format!("{r:?}"));
    }

    // --- 3. superfície de outro dispositivo: sobe pela memória ------------------------------------
    let outro = device::create_device_por_luid(luid)?;
    let f_outro: Faixas = [(70, 80, 90), (140, 150, 160), (210, 100, 200)];
    let array_outro = textura_sintetica(&outro.device, &outro.context, DXGI_FORMAT_NV12, w, h, &[f_outro])?;
    let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &array_outro, 0, false) }.context("MFCreateDXGISurfaceBuffer do outro")?;
    let amostra = amostra_de(&buffer)?;
    let r = copiar_amostra(d, c, &amostra, &anel[0], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo);
    let l = ler_nv12(d, c, &anel[0], Some(&f_outro))?;
    julgar(
        "superfície de outro dispositivo",
        r == Ok(CaminhoDaCopia::OutraPlaca) && l.diferentes == 0,
        format!("{r:?}, bytes diferentes: {}", l.diferentes),
    );

    // A superfície de outro dispositivo **alinhada** (a reconferência da fase 3): 1280x736 com a
    // imagem nas 720 de cima e o tipo dizendo 1280x720. O plano UV dela começa depois das 736 linhas;
    // lido depois das 720 do tipo, a cor sairia deslocada.
    {
        let f_img: Faixas = [(50, 90, 200), (150, 200, 60), (230, 128, 128)];
        let t = textura_com_moldura(&outro.device, &outro.context, 1280, 736, (0, 0, 1280, 720), &f_img, (16, 240, 16))?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }.context("MFCreateDXGISurfaceBuffer alinhada do outro")?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[1], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo);
        let l = ler_nv12(d, c, &anel[1], Some(&f_img))?;
        julgar(
            "superfície alinhada (1280x736) de outro dispositivo, tipo 1280x720",
            r == Ok(CaminhoDaCopia::OutraPlaca) && l.diferentes == 0,
            format!("{r:?}, bytes diferentes: {}", l.diferentes),
        );
    }

    // --- 4. tamanho errado: recusado ------------------------------------------------------------
    let pequeno = textura_sintetica(d, c, DXGI_FORMAT_NV12, 640, 360, &[f_outro])?;
    let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &pequeno, 0, false) }?;
    let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[1], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo);
    julgar("superfície de outro tamanho recusada", r.is_err(), format!("{r:?}"));

    // --- 5. YUY2: o anel e o conversor ------------------------------------------------------------
    let f_yuy2: Faixas = [(40, 100, 180), (120, 128, 128), (220, 150, 90)];
    let array_yuy2 = textura_sintetica(d, c, DXGI_FORMAT_YUY2, w, h, &[f_yuy2, f_yuy2]);
    match array_yuy2 {
        Err(e) => julgar("YUY2", false, format!("a textura YUY2 não foi criada: {e}")),
        Ok(array_yuy2) => {
            let anel_yuy2 = textura_do_anel(d, DXGI_FORMAT_YUY2, w, h).context("anel YUY2")?;
            let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &array_yuy2, 1, false) }?;
            let mut preparo_yuy2 = None;
            let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel_yuy2, Geometria::inteira(w, h), FormatoDoLeitor::Yuy2, &mut preparo_yuy2);
            julgar("array YUY2, fatia 1", r == Ok(CaminhoDaCopia::Gpu { subrecurso: 1, fatias: 2, recorta: false }), format!("{r:?}"));
            match ConversorDeCamera::novo(d, DXGI_FORMAT_YUY2, w, h, w, h, false, true, Entrelacamento::Progressivo) {
                Err(e) => julgar("conversor YUY2 → NV12", false, format!("não subiu: {e}")),
                Ok(conv) => {
                    let saida = conv.converter(&anel_yuy2).map_err(|e| anyhow!("Blt: {e}"))?;
                    let l = ler_nv12(d, c, &saida, None)?;
                    let esperadas = f_yuy2.map(|(y, u, v)| (y as f64, u as f64, v as f64));
                    let desvio = pior_desvio(&l.medias, &esperadas);
                    julgar(
                        "conversor YUY2 limitado → NV12 limitado",
                        desvio <= 3.0,
                        format!("{} | medido {} esperado {} | pior desvio {desvio:.1}", conv.descricao, medias_texto(&l.medias), medias_texto(&esperadas)),
                    );
                }
            }
        }
    }

    // --- 6. o conversor NV12: a faixa, declarada nos dois lados, e a escala -----------------------
    // Cores dentro da gama nas duas matrizes (sem recorte se o driver passar por RGB): o preto e o
    // branco de cada faixa, e um laranja apagado.
    let f_cor: Faixas = [(0, 128, 128), (128, 90, 170), (255, 128, 128)];
    let f_ident: Faixas = [(16, 128, 128), (128, 90, 170), (235, 128, 128)];
    let entrada_completa = textura_sintetica(d, c, DXGI_FORMAT_NV12, w, h, &[f_cor])?;
    let entrada_limitada = textura_sintetica(d, c, DXGI_FORMAT_NV12, w, h, &[f_ident])?;
    for (nome, completa, matriz_709) in [("limitada, BT.709 (identidade)", false, true), ("completa → limitada, BT.709", true, true), ("completa → limitada, BT.601", true, false)] {
        match ConversorDeCamera::novo(d, DXGI_FORMAT_NV12, w, h, w, h, completa, matriz_709, Entrelacamento::Progressivo) {
            Err(e) => julgar(&format!("conversor NV12 {nome}"), false, format!("não subiu: {e}")),
            Ok(conv) => {
                let entrada = if completa { &entrada_completa } else { &entrada_limitada };
                let saida = conv.converter(entrada).map_err(|e| anyhow!("Blt: {e}"))?;
                let l = ler_nv12(d, c, &saida, None)?;
                let esperadas = if completa { para_limitada(&f_cor) } else { f_ident.map(|(y, u, v)| (y as f64, u as f64, v as f64)) };
                let desvio = pior_desvio(&l.medias, &esperadas);
                julgar(
                    &format!("conversor NV12 {nome}"),
                    desvio <= 3.0,
                    format!("{} | medido {} esperado {} | pior desvio {desvio:.1}", conv.descricao, medias_texto(&l.medias), medias_texto(&esperadas)),
                );
            }
        }
    }
    let grande = textura_sintetica(d, c, DXGI_FORMAT_NV12, 1920, 1080, &[f_mem])?;
    match ConversorDeCamera::novo(d, DXGI_FORMAT_NV12, 1920, 1080, w, h, false, true, Entrelacamento::Progressivo) {
        Err(e) => julgar("conversor NV12 1920x1080 → 1280x720", false, format!("não subiu: {e}")),
        Ok(conv) => {
            // Quatro quadros seguidos: o anel de destinos gira, e cada saída é a sua.
            let mut saidas = Vec::new();
            for _ in 0..5 {
                saidas.push(conv.converter(&grande).map_err(|e| anyhow!("Blt: {e}"))?);
            }
            let distintos = saidas[..4].iter().map(|t| t.as_raw() as usize).collect::<HashSet<_>>().len();
            let volta = saidas[4].as_raw() == saidas[0].as_raw();
            let l = ler_nv12(d, c, &saidas[4], None)?;
            let esperadas = f_mem.map(|(y, u, v)| (y as f64, u as f64, v as f64));
            let desvio = pior_desvio(&l.medias, &esperadas);
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            unsafe { saidas[4].GetDesc(&mut desc) };
            julgar(
                "conversor NV12 1920x1080 → 1280x720",
                desvio <= 3.0 && distintos == 4 && volta && (desc.Width, desc.Height) == (w, h),
                format!(
                    "saída {}x{}, destinos distintos em 4 quadros: {distintos}, o 5º volta ao 1º: {volta} | medido {} | pior desvio {desvio:.1}",
                    desc.Width,
                    desc.Height,
                    medias_texto(&l.medias)
                ),
            );
        }
    }
    // --- 7. a geometria pela abertura (a revisão do código da fase 3, M3) -------------------------
    {
        use quall_capture_probe::regras_da_camera::geometria;
        let f_img: Faixas = [(50, 90, 200), (150, 200, 60), (230, 128, 128)];
        let lixo = (16u8, 240u8, 16u8);
        // (i) o quadro alinhado de um decodificador: 1280x736, a imagem nas 720 de cima.
        let g = geometria(1280, 736, Some((0, 0, 1280, 720)));
        let t = textura_com_moldura(d, c, 1280, 736, (0, 0, 1280, 720), &f_img, lixo)?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[2], g, FormatoDoLeitor::Nv12, &mut preparo);
        let l = ler_nv12(d, c, &anel[2], Some(&f_img))?;
        julgar(
            "abertura 1280x720 de um quadro 1280x736 (GPU)",
            matches!(r, Ok(CaminhoDaCopia::Gpu { .. })) && l.diferentes == 0,
            format!("{} → {r:?}, bytes diferentes: {}", g.descricao(), l.diferentes),
        );
        // A abertura com deslocamento: 1296x736, a imagem em (16, 8).
        let g = geometria(1296, 736, Some((16, 8, 1280, 720)));
        let t = textura_com_moldura(d, c, 1296, 736, (16, 8, 1280, 720), &f_img, lixo)?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[3], g, FormatoDoLeitor::Nv12, &mut preparo);
        let l = ler_nv12(d, c, &anel[3], Some(&f_img))?;
        julgar(
            "abertura em (16,8) de um quadro 1296x736 (GPU)",
            matches!(r, Ok(CaminhoDaCopia::Gpu { .. })) && l.diferentes == 0,
            format!("{} → {r:?}, bytes diferentes: {}", g.descricao(), l.diferentes),
        );
        // (ii) o tipo diz 1280x720 e a superfície tem 1280x736: antes, toda cópia era recusada.
        let t = textura_com_moldura(d, c, 1280, 736, (0, 0, 1280, 720), &f_img, lixo)?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[4], Geometria::inteira(1280, 720), FormatoDoLeitor::Nv12, &mut preparo);
        let l = ler_nv12(d, c, &anel[4], Some(&f_img))?;
        julgar(
            "tipo 1280x720 numa superfície 1280x736 (GPU)",
            matches!(r, Ok(CaminhoDaCopia::Gpu { .. })) && l.diferentes == 0,
            format!("{r:?}, bytes diferentes: {}", l.diferentes),
        );
        // A memória com a abertura em (16, 8): o UV começa depois das 736 linhas do quadro.
        let g = geometria(1296, 736, Some((16, 8, 1280, 720)));
        let r = unsafe {
            let buffer = MFCreate2DMediaBuffer(1296, 736, MFVideoFormat_NV12.data1, false).context("MFCreate2DMediaBuffer 1296x736")?;
            let b2: IMF2DBuffer2 = buffer.cast().context("IMF2DBuffer2")?;
            let (mut base, mut passo, mut inicio, mut tamanho) = (std::ptr::null_mut::<u8>(), 0i32, std::ptr::null_mut::<u8>(), 0u32);
            b2.Lock2DSize(MF2DBuffer_LockFlags_Write, &mut base, &mut passo, &mut inicio, &mut tamanho).context("Lock2DSize")?;
            pintar_com_moldura(base, passo as usize, 1296, 736, (16, 8, 1280, 720), &f_img, lixo);
            let _ = b2.Unlock2D();
            let _ = buffer.SetCurrentLength(tamanho);
            let mut preparo_1280 = None;
            copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[5], g, FormatoDoLeitor::Nv12, &mut preparo_1280)
        };
        let l = ler_nv12(d, c, &anel[5], Some(&f_img))?;
        julgar(
            "abertura em (16,8) de um quadro 1296x736 (memória 2D)",
            r == Ok(CaminhoDaCopia::Memoria) && l.diferentes == 0,
            format!("{} → {r:?}, bytes diferentes: {}", g.descricao(), l.diferentes),
        );
        // A superfície **grande demais** (a reconferência da fase 3): 1920x1088 para um tipo de
        // 1280x720 não é alinhamento, é um tamanho que mudou sem aviso. Antes, recortada calada.
        let t = textura_com_moldura(d, c, 1920, 1088, (0, 0, 1280, 720), &f_img, lixo)?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[0], Geometria::inteira(1280, 720), FormatoDoLeitor::Nv12, &mut preparo);
        julgar("superfície grande demais recusada", r.is_err(), format!("{r:?}"));
        // O recorte do alinhamento vem marcado, para o registro dizer uma vez.
        let t = textura_com_moldura(d, c, 1280, 736, (0, 0, 1280, 720), &f_img, lixo)?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[0], Geometria::inteira(1280, 720), FormatoDoLeitor::Nv12, &mut preparo);
        julgar("o recorte do alinhamento vem marcado", r == Ok(CaminhoDaCopia::Gpu { subrecurso: 0, fatias: 1, recorta: true }), format!("{r:?}"));
        // A superfície menor que a imagem: recusada, com o motivo.
        let t = textura_com_moldura(d, c, 1280, 704, (0, 0, 1280, 704), &f_img, lixo)?;
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &t, 0, false) }?;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[0], Geometria::inteira(1280, 720), FormatoDoLeitor::Nv12, &mut preparo);
        julgar("superfície menor que a imagem recusada", r.is_err(), format!("{r:?}"));
    }

    // --- 8. o I420 da Canon (a fase 5): três planos em memória viram o NV12 do anel -----------------
    // O EOS Webcam Utility só declara I420 1280x720 @30 (a fase 5, passo 1). A cópia para o anel
    // entrelaça U e V (`regras_da_camera::entrelacar_uv`): o NV12 lido de volta tem de ser, byte a
    // byte, o das três faixas, no buffer 2D (passo do Media Foundation) e no linear.
    unsafe {
        use quall_capture_probe::regras_da_camera::planos_i420;
        let f_i420: Faixas = [(210, 60, 190), (35, 200, 90), (128, 128, 128)];
        let pintar_i420 = |base: *mut u8, passo: usize| {
            let (iu, iv, puv) = planos_i420(passo, h as usize);
            for y in 0..h as usize {
                for x in 0..w as usize {
                    *base.add(y * passo + x) = faixa_de(&f_i420, x as u32, w).0;
                }
            }
            for y in 0..(h / 2) as usize {
                for x in 0..(w / 2) as usize {
                    let (_, u, v) = faixa_de(&f_i420, (x * 2) as u32, w);
                    *base.add(iu + y * puv + x) = u;
                    *base.add(iv + y * puv + x) = v;
                }
            }
        };
        let buffer = MFCreate2DMediaBuffer(w, h, MFVideoFormat_I420.data1, false).context("MFCreate2DMediaBuffer I420")?;
        let b2: IMF2DBuffer2 = buffer.cast().context("IMF2DBuffer2 I420")?;
        let (mut base, mut passo, mut inicio, mut tamanho) = (std::ptr::null_mut::<u8>(), 0i32, std::ptr::null_mut::<u8>(), 0u32);
        b2.Lock2DSize(MF2DBuffer_LockFlags_Write, &mut base, &mut passo, &mut inicio, &mut tamanho).context("Lock2DSize I420")?;
        pintar_i420(base, passo as usize);
        let _ = b2.Unlock2D();
        let _ = buffer.SetCurrentLength(tamanho);
        let mut preparo_i420 = None;
        let r = copiar_amostra(d, c, &amostra_de(&buffer)?, &anel[0], Geometria::inteira(w, h), FormatoDoLeitor::I420, &mut preparo_i420);
        let l = ler_nv12(d, c, &anel[0], Some(&f_i420))?;
        julgar(
            "memória 2D I420 → anel NV12",
            r == Ok(CaminhoDaCopia::Memoria) && l.diferentes == 0,
            format!("passo {passo} para {w}, {tamanho} bytes, {r:?}, bytes diferentes: {}", l.diferentes),
        );

        let n = (w * h * 3 / 2) as usize;
        let linear = MFCreateMemoryBuffer(n as u32).context("MFCreateMemoryBuffer I420")?;
        let mut base: *mut u8 = std::ptr::null_mut();
        linear.Lock(&mut base, None, None).context("Lock I420")?;
        pintar_i420(base, w as usize);
        let _ = linear.Unlock();
        let _ = linear.SetCurrentLength(n as u32);
        let r = copiar_amostra(d, c, &amostra_de(&linear)?, &anel[1], Geometria::inteira(w, h), FormatoDoLeitor::I420, &mut preparo_i420);
        let l = ler_nv12(d, c, &anel[1], Some(&f_i420))?;
        julgar(
            "memória linear I420 → anel NV12",
            r == Ok(CaminhoDaCopia::Memoria) && l.diferentes == 0,
            format!("{r:?}, bytes diferentes: {}", l.diferentes),
        );

        // O controle negativo: o mesmo buffer I420 lido como NV12 sai com o croma errado.
        let r = copiar_amostra(d, c, &amostra_de(&linear)?, &anel[2], Geometria::inteira(w, h), FormatoDoLeitor::Nv12, &mut preparo);
        let l = ler_nv12(d, c, &anel[2], Some(&f_i420))?;
        julgar(
            "controle: o I420 lido como NV12 NÃO confere",
            r == Ok(CaminhoDaCopia::Memoria) && l.diferentes > 0,
            format!("{r:?}, bytes diferentes: {}", l.diferentes),
        );

        // Curto demais: recusado, sem ler além do fim.
        let curto = MFCreateMemoryBuffer((n / 2) as u32).context("MFCreateMemoryBuffer I420 curto")?;
        let _ = curto.SetCurrentLength((n / 2) as u32);
        let r = copiar_amostra(d, c, &amostra_de(&curto)?, &anel[3], Geometria::inteira(w, h), FormatoDoLeitor::I420, &mut preparo_i420);
        julgar("buffer I420 curto recusado", r.is_err(), format!("{r:?}"));
    }

    // --- 9. desentrelaçar (a fase 5, o DV da Panasonic): um pente sintético ----------------------
    // Um YUY2 720x480 com as linhas pares (o campo de cima) em Y=200 e as ímpares (o campo de baixo)
    // em Y=40: progressivo, a saída continua um pente; desentrelaçado pelo `bob` do primeiro campo
    // no tempo, a saída é lisa e tem o Y do campo que veio primeiro: 40 com o campo de baixo
    // primeiro (o DV), 200 com o de cima. O custo de cada `Blt`, com a espera da GPU, vai junto.
    {
        let (wd, hd) = (720u32, 480u32);
        let (y_cima, y_baixo) = (200u8, 40u8);
        let pente = textura_pente_yuy2(d, c, wd, hd, y_cima, y_baixo)?;
        let mut custos: Vec<(String, f64)> = Vec::new();
        for (nome, e) in [
            ("progressivo (o controle: o pente fica)", Entrelacamento::Progressivo),
            ("campo de baixo primeiro (o DV)", Entrelacamento::CampoDeBaixoPrimeiro),
            ("campo de cima primeiro", Entrelacamento::CampoDeCimaPrimeiro),
        ] {
            match ConversorDeCamera::novo(d, DXGI_FORMAT_YUY2, wd, hd, wd, hd, false, false, e) {
                Err(err) => julgar(&format!("desentrelaçar, {nome}"), false, format!("o conversor não subiu: {err}")),
                Ok(conv) => {
                    let saida = conv.converter(&pente).map_err(|x| anyhow!("Blt: {x}"))?;
                    let linhas = luma_por_linha(d, c, &saida)?;
                    // O miolo, longe das bordas de cima e de baixo (o bob interpola nelas).
                    let miolo = &linhas[8..linhas.len() - 8];
                    let pentes = miolo.windows(2).filter(|p| (p[0] - p[1]).abs() > 60.0).count() as f64 / (miolo.len() - 1) as f64;
                    let media = miolo.iter().sum::<f64>() / miolo.len() as f64;
                    let (ok, esperado) = match e {
                        Entrelacamento::Progressivo => (pentes > 0.9, "pente em >90% das linhas".to_string()),
                        Entrelacamento::CampoDeBaixoPrimeiro => (
                            pentes < 0.05 && (media - f64::from(y_baixo)).abs() < 12.0,
                            format!("liso, Y ~ {y_baixo} (o campo de baixo)"),
                        ),
                        Entrelacamento::CampoDeCimaPrimeiro => (
                            pentes < 0.05 && (media - f64::from(y_cima)).abs() < 12.0,
                            format!("liso, Y ~ {y_cima} (o campo de cima)"),
                        ),
                    };
                    let custo = custo_do_blt(d, c, &conv, &pente, 120)?;
                    custos.push((nome.to_string(), custo));
                    julgar(
                        &format!("desentrelaçar, {nome}"),
                        ok,
                        format!(
                            "{} | linhas com pente {:.0}%, Y médio {media:.1}; esperado {esperado} | Blt com a espera da GPU p50 {custo:.3} ms",
                            conv.descricao,
                            pentes * 100.0
                        ),
                    );
                }
            }
        }
        diga!("custo do desentrelaçamento (Blt 720x480 YUY2 → NV12 com a espera da GPU, p50 de 120): {}", custos.iter().map(|(n, c)| format!("{n} {c:.3} ms")).collect::<Vec<_>>().join(" | "));
    }

    // --- 10. o fundo das faixas (a revisão curta do `08af2cd`, A6) --------------------------------
    // A sessão que abriu em 4:3 (saída 640x480) e passou a 16:9: o quadro entra encaixado em
    // (0, 60, 640, 360), e as faixas de cima e de baixo são o fundo do processador. O produto pinta
    // RGB (0, 0, 0); o esperado é o preto da faixa limitada (Y ~ 16, croma 128). O controle mede o
    // fundo da primeira versão (YCbCr 16/255 com `YCbCr = true`), que o Pessoa Exemplo viu preto sem o Y medido.
    {
        use quall_capture_probe::conversor_de_camera::Fundo;
        let (we, he) = (720u32, 480u32);
        let y_imagem = 180u8;
        let liso = textura_pente_yuy2(d, c, we, he, y_imagem, y_imagem)?;
        match ConversorDeCamera::novo(d, DXGI_FORMAT_YUY2, we, he, 640, 480, false, false, Entrelacamento::Progressivo) {
            Err(err) => julgar("o fundo das faixas", false, format!("o conversor não subiu: {err}")),
            Ok(conv) => {
                // O controle do encaixe: sem ele, a linha 0 é imagem.
                let inteira = luma_por_linha(d, c, &conv.converter(&liso).map_err(|x| anyhow!("Blt: {x}"))?)?;
                let r = conv.encaixar((854, 480));
                for (nome, fundo) in [("RGB (0,0,0), o do produto", Fundo::PretoRgb), ("YCbCr 16/255, o da primeira versão (controle)", Fundo::YCbCrLimitado)] {
                    conv.pintar_fundo(fundo);
                    let saida = conv.converter(&liso).map_err(|x| anyhow!("Blt: {x}"))?;
                    let y = luma_por_linha(d, c, &saida)?;
                    let uv = croma_por_linha(d, c, &saida)?;
                    let media = |v: &[f64]| v.iter().sum::<f64>() / v.len() as f64;
                    let faixa_y = (media(&y[2..56]) + media(&y[424..478])) / 2.0;
                    let imagem_y = media(&y[80..400]);
                    let faixa_u = media(&uv[1..28].iter().map(|p| p.0).collect::<Vec<_>>());
                    let faixa_v = media(&uv[1..28].iter().map(|p| p.1).collect::<Vec<_>>());
                    let detalhe = format!(
                        "encaixe {r:?} na saída 640x480 | faixa Y {faixa_y:.1} U {faixa_u:.1} V {faixa_v:.1}; imagem Y {imagem_y:.1} (entrou {y_imagem}); sem o encaixe, a linha 2 tinha Y {:.1}",
                        inteira[2]
                    );
                    if fundo == Fundo::PretoRgb {
                        julgar(
                            &format!("o fundo das faixas, {nome}"),
                            r == (0, 60, 640, 360)
                                && (faixa_y - 16.0).abs() <= 3.0
                                && (faixa_u - 128.0).abs() <= 3.0
                                && (faixa_v - 128.0).abs() <= 3.0
                                && (imagem_y - f64::from(y_imagem)).abs() <= 6.0
                                && (inteira[2] - f64::from(y_imagem)).abs() <= 6.0,
                            format!("{detalhe}; esperado faixa Y 16 ± 3 e croma 128 ± 3"),
                        );
                    } else {
                        diga!("o fundo das faixas, {nome}: {detalhe}");
                    }
                }
            }
        }
    }

    // --- 11. a apresentação da janela na troca de tamanho (o G1 do controle de 21/09) ------------
    // O receptor do Windows apresenta pelo Video Processor com um enumerador montado para a entrada
    // do primeiro SPS. No controle, o fluxo desceu de 854x480 (textura 864x480) para 640x480, e o
    // `present_frame` falhou com 0x80070057 em todo quadro de 640. Aqui, sem janela, o mesmo par de
    // chamadas numa textura NV12 de 640x480 e num alvo BGRA de 854x480, para dizer QUAL delas
    // recusa: a vista de entrada (o enumerador de 854) ou o `Blt` (a origem de 854 numa textura de
    // 640). Depois o conserto: a origem da abertura de agora, e o enumerador refeito. E a subida (o
    // enumerador de 640, a textura de 864, a origem de 854), que no produto de antes cortava sem
    // erro.
    {
        use windows::Win32::Foundation::RECT;
        use windows::Win32::Graphics::Direct3D11::{
            ID3D11VideoContext, ID3D11VideoDevice, ID3D11VideoProcessor, ID3D11VideoProcessorEnumerator,
            ID3D11VideoProcessorInputView, ID3D11VideoProcessorOutputView, D3D11_TEX2D_VPIV, D3D11_TEX2D_VPOV,
            D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE, D3D11_VIDEO_PROCESSOR_CONTENT_DESC,
            D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0,
            D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0,
            D3D11_VIDEO_PROCESSOR_STREAM, D3D11_VIDEO_USAGE_PLAYBACK_NORMAL, D3D11_VPIV_DIMENSION_TEXTURE2D,
            D3D11_VPOV_DIMENSION_TEXTURE2D,
        };
        use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_RATIONAL};

        let vd: ID3D11VideoDevice = d.cast().context("ID3D11VideoDevice")?;
        let vc: ID3D11VideoContext = c.cast().context("ID3D11VideoContext")?;
        let processador = |entrada: (u32, u32)| -> windows::core::Result<(ID3D11VideoProcessorEnumerator, ID3D11VideoProcessor)> {
            let desc = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputFrameRate: DXGI_RATIONAL { Numerator: 30, Denominator: 1 },
                InputWidth: entrada.0,
                InputHeight: entrada.1,
                OutputFrameRate: DXGI_RATIONAL { Numerator: 30, Denominator: 1 },
                OutputWidth: 854,
                OutputHeight: 480,
                Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
            };
            let e = unsafe { vd.CreateVideoProcessorEnumerator(&desc) }?;
            let p = unsafe { vd.CreateVideoProcessor(&e, 0) }?;
            Ok((e, p))
        };
        let alvo = {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: 854,
                Height: 480,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
                CPUAccessFlags: 0,
                MiscFlags: 0,
            };
            let mut t: Option<ID3D11Texture2D> = None;
            unsafe { d.CreateTexture2D(&desc, None, Some(&mut t)) }.context("o alvo BGRA 854x480")?;
            t.ok_or_else(|| anyhow!("sem alvo"))?
        };
        // Uma apresentação: a vista de entrada, a vista de saída e o `Blt` com a origem pedida.
        // Devolve qual etapa recusou, com o código.
        let apresentar = |e: &ID3D11VideoProcessorEnumerator, p: &ID3D11VideoProcessor, textura: &ID3D11Texture2D, origem: RECT| -> String {
            let desc_in = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                FourCC: 0,
                ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
            };
            let mut vin: Option<ID3D11VideoProcessorInputView> = None;
            if let Err(x) = unsafe { vd.CreateVideoProcessorInputView(textura, e, &desc_in, Some(&mut vin)) } {
                return format!("CreateVideoProcessorInputView recusou: {x}");
            }
            let Some(vin) = vin else { return "CreateVideoProcessorInputView sem vista".into() };
            let desc_out = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
            };
            let mut vout: Option<ID3D11VideoProcessorOutputView> = None;
            if let Err(x) = unsafe { vd.CreateVideoProcessorOutputView(&alvo, e, &desc_out, Some(&mut vout)) } {
                return format!("CreateVideoProcessorOutputView recusou: {x}");
            }
            let Some(vout) = vout else { return "CreateVideoProcessorOutputView sem vista".into() };
            let inteira = RECT { left: 0, top: 0, right: 854, bottom: 480 };
            unsafe {
                vc.VideoProcessorSetOutputTargetRect(p, true, Some(&inteira));
                vc.VideoProcessorSetStreamSourceRect(p, 0, true, Some(&origem));
                vc.VideoProcessorSetStreamDestRect(p, 0, true, Some(&inteira));
            }
            let fluxo = D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: windows::core::BOOL::from(true),
                OutputIndex: 0,
                InputFrameOrField: 0,
                PastFrames: 0,
                FutureFrames: 0,
                ppPastSurfaces: std::ptr::null_mut(),
                pInputSurface: unsafe { std::mem::transmute_copy(&vin) },
                ppFutureSurfaces: std::ptr::null_mut(),
                ppPastSurfacesRight: std::ptr::null_mut(),
                pInputSurfaceRight: ManuallyDrop::new(None),
                ppFutureSurfacesRight: std::ptr::null_mut(),
            };
            match unsafe { vc.VideoProcessorBlt(p, &vout, 0, &[fluxo]) } {
                Ok(()) => "ok".into(),
                Err(x) => format!("VideoProcessorBlt recusou: {x}"),
            }
        };
        let rect = |l: i32, a: i32| RECT { left: 0, top: 0, right: l, bottom: a };
        let t640 = textura_do_anel(d, DXGI_FORMAT_NV12, 640, 480).context("NV12 640x480")?;
        let t864 = textura_do_anel(d, DXGI_FORMAT_NV12, 864, 480).context("NV12 864x480")?;
        match (processador((854, 480)), processador((640, 480))) {
            (Ok((e854, p854)), Ok((e640, p640))) => {
                // O controle: o produto de antes, descendo — o enumerador de 854 e a origem de 854
                // numa textura de 640. É o 0x80070057 do controle de 21/09; diz qual etapa recusa.
                let antes = apresentar(&e854, &p854, &t640, rect(854, 480));
                diga!("a apresentação na troca, o controle (o produto de antes, descendo 854 -> 640): {antes}");
                // Só a origem nova, com o enumerador de 854: separa a origem do enumerador.
                let so_origem = apresentar(&e854, &p854, &t640, rect(640, 480));
                diga!("a apresentação na troca, só a origem de 640 com o enumerador de 854: {so_origem}");
                // O conserto, descendo: o enumerador refeito para 640 e a origem de 640.
                let descendo = apresentar(&e640, &p640, &t640, rect(640, 480));
                julgar("a apresentação na troca, descendo (enumerador e origem de 640)", descendo == "ok", descendo);
                // O conserto, subindo: o enumerador refeito para 864 e a origem da abertura, 854.
                match processador((864, 480)) {
                    Ok((e864, p864)) => {
                        let subindo = apresentar(&e864, &p864, &t864, rect(854, 480));
                        julgar("a apresentação na troca, subindo (enumerador de 864, origem de 854)", subindo == "ok", subindo);
                    }
                    Err(x) => julgar("a apresentação na troca, subindo", false, format!("o processador de 864 não subiu: {x}")),
                }
                // O produto de antes, subindo: o enumerador de 640 com a textura de 864 e a origem
                // de 640 — não falha, e corta a imagem à direita (o cenário A da crítica).
                let antes_subindo = apresentar(&e640, &p640, &t864, rect(640, 480));
                diga!("a apresentação na troca, o produto de antes subindo 640 -> 854 (a origem de 640 na textura de 864): {antes_subindo} — sem erro, e cortando à direita");
            }
            (a, b) => julgar(
                "a apresentação na troca",
                false,
                format!("os processadores não subiram: 854 {:?} | 640 {:?}", a.err(), b.err()),
            ),
        }
    }

    diga!("ANEL: {} falha(s)", falhas);
    if falhas > 0 {
        std::process::exit(5);
    }
    Ok(())
}

// =============================================================================================
// A fase 5: o leitor contra a Canon, variante por variante
// =============================================================================================

/// Uma variante do diagnóstico do leitor.
#[derive(Clone, Copy, Debug)]
struct Variante {
    nome: &'static str,
    /// O leitor com o gerenciador D3D da Intel (e `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`).
    d3d: bool,
    /// `IMFSourceReaderEx::SetNativeMediaType` com o tipo nativo, antes (o produto faz).
    fixar_nativo: bool,
    /// O tipo de saída: o nativo devolvido como veio (`true`) ou o reconstruído só com o tipo
    /// maior e o subtipo, como o produto (`false`).
    saida_nativa: bool,
}

const VARIANTES: [Variante; 4] = [
    Variante { nome: "1 sem D3D, saída = o nativo como veio", d3d: false, fixar_nativo: false, saida_nativa: true },
    Variante { nome: "2 sem D3D, saída reconstruída (maior + subtipo)", d3d: false, fixar_nativo: false, saida_nativa: false },
    Variante { nome: "3 com D3D, saída = o nativo como veio", d3d: true, fixar_nativo: false, saida_nativa: true },
    Variante { nome: "4 com D3D, SetNativeMediaType e saída reconstruída (o produto, síncrono)", d3d: true, fixar_nativo: true, saida_nativa: false },
];

/// **O diagnóstico do leitor** (a fase 5: a Canon com o I420 não abriu, o leitor devolveu
/// `0xC00D36B4`, `MF_E_INVALIDMEDIATYPE`, na espera do primeiro quadro, nas duas tentativas). Abre a
/// câmera do link **exato** e lê **um** quadro em cada variante, uma de cada vez, com a fonte criada
/// de novo em cada uma: o `HRESULT` e a chamada em que ele saiu. O quadro não é lido nem gravado:
/// só o tamanho, o carimbo e o tipo do buffer (DXGI ou memória). Só webcam USB (`\\?\usb#`) e a
/// fonte do EOS Webcam Utility (`\\?\root#eoswebcamsource#`); a câmera virtual do Windows (o S24, as
/// do Quall) é recusada antes de criar a fonte. **Cada variante põe a câmera a transmitir por um
/// instante** (a Canon abre o obturador).
fn cmd_diagnosticar_leitor(args: &[String]) -> Result<()> {
    let mut link: Option<String> = None;
    let mut escolhidas: Vec<usize> = (0..VARIANTES.len()).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--link" => {
                link = args.get(i + 1).cloned();
                i += 1;
            }
            "--variantes" => {
                escolhidas = args
                    .get(i + 1)
                    .map(|v| v.split(',').filter_map(|n| n.trim().parse::<usize>().ok()).filter(|n| (1..=VARIANTES.len()).contains(n)).map(|n| n - 1).collect())
                    .unwrap_or_default();
                i += 1;
            }
            outro => bail!("opção desconhecida: {outro}"),
        }
        i += 1;
    }
    let link = link.ok_or_else(|| anyhow!("--link <link exato> é obrigatório"))?;
    let minusculo = link.to_ascii_lowercase();
    if minusculo.starts_with(r"\\?\swd#vcamdevapi#") || !(minusculo.starts_with(r"\\?\usb#") || minusculo.starts_with(r"\\?\root#eoswebcamsource#")) {
        diga!("RECUSADO antes de criar a fonte: só webcam USB ou a fonte do EOS Webcam Utility | {link}");
        std::process::exit(2);
    }
    let luid = placa_intel()?;
    let a = device::create_device_por_luid(luid)?;
    let _ = device::proteger_contexto(&a.context, true);
    let gerenciador = quall_capture_probe::encoder::create_device_manager(&a.device)?;
    diga!("placa: {} luid {luid:016X}; {} variante(s); o link: {link}", a.description, escolhidas.len());
    for k in escolhidas {
        let v = VARIANTES[k];
        diga!("=== variante {} ({}) ===", v.nome, chrono_agora());
        match diagnosticar_uma(&link, v, &gerenciador) {
            Ok(texto) => diga!("  {texto}"),
            Err(e) => diga!("  FALHOU: {e:#}"),
        }
        std::thread::sleep(Duration::from_millis(1500));
    }
    Ok(())
}

fn chrono_agora() -> String {
    let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let s = d.as_secs() % 86_400;
    format!("{:02}:{:02}:{:02}.{:03}Z", s / 3600, (s / 60) % 60, s % 60, d.subsec_millis())
}

struct LeitorEnviavelDiag(IMFSourceReader);
unsafe impl Send for LeitorEnviavelDiag {}

/// Uma variante: a fonte, o leitor, os tipos e **um** `ReadSample` síncrono com prazo de 8 s (numa
/// thread: o síncrono pode não voltar, agosto); depois o `Shutdown` da fonte.
fn diagnosticar_uma(link: &str, v: Variante, gerenciador: &IMFDXGIDeviceManager) -> Result<String> {
    let etapa = |nome: &str, e: windows::core::Error| anyhow!("{nome}: {:?} ({})", e.code(), e.message());
    let t0 = Instant::now();
    let fonte: IMFMediaSource = unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2).map_err(|e| etapa("MFCreateAttributes", e))?;
        let attrs = attrs.ok_or_else(|| anyhow!("sem atributos"))?;
        attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID).map_err(|e| etapa("SOURCE_TYPE", e))?;
        attrs.SetString(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &HSTRING::from(link)).map_err(|e| etapa("SYMBOLIC_LINK", e))?;
        MFCreateDeviceSource(&attrs).map_err(|e| etapa("MFCreateDeviceSource", e))?
    };
    let resultado = (|| -> Result<String> {
        let mut passos = vec![format!("fonte {} ms", t0.elapsed().as_millis())];
        let leitor: IMFSourceReader = unsafe {
            let mut attrs: Option<IMFAttributes> = None;
            MFCreateAttributes(&mut attrs, 2).map_err(|e| etapa("MFCreateAttributes do leitor", e))?;
            let attrs = attrs.ok_or_else(|| anyhow!("sem atributos"))?;
            if v.d3d {
                attrs.SetUnknown(&MF_SOURCE_READER_D3D_MANAGER, gerenciador).map_err(|e| etapa("D3D_MANAGER", e))?;
                attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1).map_err(|e| etapa("HARDWARE_TRANSFORMS", e))?;
            }
            MFCreateSourceReaderFromMediaSource(&fonte, &attrs).map_err(|e| etapa("MFCreateSourceReaderFromMediaSource", e))?
        };
        let fluxo = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
        let nativo = unsafe { leitor.GetNativeMediaType(fluxo, 0) }.map_err(|e| etapa("GetNativeMediaType(0)", e))?;
        let sub_nativo = unsafe { nativo.GetGUID(&MF_MT_SUBTYPE) }.unwrap_or(GUID::zeroed());
        passos.push(format!("nativo {}", nome_do_subtipo(&sub_nativo)));
        if v.fixar_nativo {
            let ex: IMFSourceReaderEx = leitor.cast().map_err(|e| etapa("IMFSourceReaderEx", e))?;
            unsafe { ex.SetNativeMediaType(fluxo, &nativo) }.map_err(|e| etapa("SetNativeMediaType", e))?;
            passos.push("SetNativeMediaType ok".into());
        }
        let saida: IMFMediaType = if v.saida_nativa {
            nativo.clone()
        } else {
            let t = unsafe { MFCreateMediaType() }.map_err(|e| etapa("MFCreateMediaType", e))?;
            unsafe {
                t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(|e| etapa("MAJOR_TYPE", e))?;
                t.SetGUID(&MF_MT_SUBTYPE, &sub_nativo).map_err(|e| etapa("SUBTYPE", e))?;
            }
            t
        };
        unsafe { leitor.SetCurrentMediaType(fluxo, None, &saida) }.map_err(|e| etapa("SetCurrentMediaType", e))?;
        let atual = unsafe { leitor.GetCurrentMediaType(fluxo) }.map_err(|e| etapa("GetCurrentMediaType", e))?;
        let tam = unsafe { atual.GetUINT64(&MF_MT_FRAME_SIZE) }.unwrap_or(0);
        passos.push(format!(
            "o leitor aceitou {} {}x{}",
            nome_do_subtipo(&unsafe { atual.GetGUID(&MF_MT_SUBTYPE) }.unwrap_or(GUID::zeroed())),
            tam >> 32,
            tam & 0xffff_ffff
        ));
        // Um ReadSample síncrono numa thread, com prazo.
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let enviavel = LeitorEnviavelDiag(leitor.clone());
        let t1 = Instant::now();
        std::thread::spawn(move || {
            let enviavel = enviavel;
            let com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            let mut texto = String::new();
            for tentativa in 0..10 {
                let (mut real, mut bandeiras, mut ts) = (0u32, 0u32, 0i64);
                let mut amostra: Option<IMFSample> = None;
                let r = unsafe { enviavel.0.ReadSample(fluxo, 0, Some(&mut real), Some(&mut bandeiras), Some(&mut ts), Some(&mut amostra)) };
                match r {
                    Err(e) => {
                        texto = format!("ReadSample: {:?} ({})", e.code(), e.message());
                        break;
                    }
                    Ok(()) => match amostra {
                        None => {
                            texto = format!("ReadSample sem amostra (bandeiras 0x{bandeiras:X}), tentativa {tentativa}");
                            if bandeiras & (MF_SOURCE_READERF_ERROR.0 as u32 | MF_SOURCE_READERF_ENDOFSTREAM.0 as u32) != 0 {
                                break;
                            }
                        }
                        Some(s) => {
                            let n = unsafe { s.GetBufferCount() }.unwrap_or(0);
                            let buf = unsafe { s.GetBufferByIndex(0) }.ok();
                            let dxgi = buf.as_ref().map(|b| b.cast::<IMFDXGIBuffer>().is_ok()).unwrap_or(false);
                            let tamanho = buf.as_ref().and_then(|b| unsafe { b.GetCurrentLength() }.ok()).unwrap_or(0);
                            let disp = unsafe { s.GetUINT64(&MFSampleExtension_DeviceTimestamp) }.ok();
                            texto = format!(
                                "UM QUADRO: bandeiras 0x{bandeiras:X}, tempo {:.2} ms, DeviceTimestamp {}, {n} buffer(s), {} de {tamanho} bytes",
                                ts as f64 / 10_000.0,
                                disp.map(|d| format!("{:.2} ms", d as f64 / 10_000.0)).unwrap_or_else(|| "ausente".into()),
                                if dxgi { "DXGI" } else { "memória" }
                            );
                            break;
                        }
                    },
                }
            }
            if com.is_ok() {
                unsafe { CoUninitialize() };
            }
            let _ = tx.send(texto);
        });
        let r = match rx.recv_timeout(Duration::from_secs(8)) {
            Ok(t) => format!("{t} em {} ms", t1.elapsed().as_millis()),
            Err(_) => "ReadSample SEM RESPOSTA em 8 s (a fonte é desligada agora)".into(),
        };
        passos.push(r);
        Ok(passos.join(" | "))
    })();
    let t2 = Instant::now();
    let _ = unsafe { fonte.Shutdown() };
    let fim = format!(" | Shutdown em {} ms", t2.elapsed().as_millis());
    resultado.map(|t| t + &fim).map_err(|e| anyhow!("{e:#}{fim}"))
}

// =============================================================================================
// A fase 5: o aspecto do DV (16:9 e 4:3), com o fluxo rodando
// =============================================================================================

/// Os nomes das chaves que importam para o aspecto e o tipo; o resto sai pelo GUID.
fn nome_da_chave(g: &GUID) -> String {
    let conhecidas: [(&GUID, &str); 22] = [
        (&MF_MT_MAJOR_TYPE, "MAJOR_TYPE"),
        (&MF_MT_SUBTYPE, "SUBTYPE"),
        (&MF_MT_FRAME_SIZE, "FRAME_SIZE"),
        (&MF_MT_FRAME_RATE, "FRAME_RATE"),
        (&MF_MT_PIXEL_ASPECT_RATIO, "PIXEL_ASPECT_RATIO"),
        (&MF_MT_INTERLACE_MODE, "INTERLACE_MODE"),
        (&MF_MT_DV_VAUX_SRC_PACK, "DV_VAUX_SRC_PACK"),
        (&MF_MT_DV_VAUX_CTRL_PACK, "DV_VAUX_CTRL_PACK"),
        (&MF_MT_GEOMETRIC_APERTURE, "GEOMETRIC_APERTURE"),
        (&MF_MT_MINIMUM_DISPLAY_APERTURE, "MINIMUM_DISPLAY_APERTURE"),
        (&MF_MT_PAN_SCAN_APERTURE, "PAN_SCAN_APERTURE"),
        (&MF_MT_PAN_SCAN_ENABLED, "PAN_SCAN_ENABLED"),
        (&MF_MT_PAD_CONTROL_FLAGS, "PAD_CONTROL_FLAGS"),
        (&MF_MT_SOURCE_CONTENT_HINT, "SOURCE_CONTENT_HINT"),
        (&MF_MT_VIDEO_NOMINAL_RANGE, "VIDEO_NOMINAL_RANGE"),
        (&MF_MT_YUV_MATRIX, "YUV_MATRIX"),
        (&MF_MT_DEFAULT_STRIDE, "DEFAULT_STRIDE"),
        (&MF_MT_SAMPLE_SIZE, "SAMPLE_SIZE"),
        (&MF_MT_AM_FORMAT_TYPE, "AM_FORMAT_TYPE"),
        (&MF_MT_USER_DATA, "USER_DATA"),
        (&MFSampleExtension_Interlaced, "Sample.Interlaced"),
        (&MFSampleExtension_BottomFieldFirst, "Sample.BottomFieldFirst"),
    ];
    conhecidas.iter().find(|(k, _)| *k == g).map(|(_, n)| n.to_string()).unwrap_or_else(|| format!("{g:?}"))
}

/// **Todos os atributos** de um repositório (tipo ou amostra), "NOME=valor". Os pacotes do DV saem
/// também em hexadecimal: é neles que o DV guarda o aspecto (o campo DISP do VAUX de controle).
fn todos_os_atributos(a: &IMFAttributes) -> String {
    let mut partes = Vec::new();
    unsafe {
        let n = a.GetCount().unwrap_or(0);
        for i in 0..n {
            let mut k = GUID::zeroed();
            if a.GetItemByIndex(i, &mut k, None).is_err() {
                continue;
            }
            let valor = match a.GetItemType(&k) {
                Ok(t) if t == MF_ATTRIBUTE_UINT32 => a.GetUINT32(&k).map(|v| format!("{v} (0x{v:08X})")).unwrap_or_default(),
                Ok(t) if t == MF_ATTRIBUTE_UINT64 => a.GetUINT64(&k).map(|v| format!("{}:{}", v >> 32, v & 0xffff_ffff)).unwrap_or_default(),
                Ok(t) if t == MF_ATTRIBUTE_GUID => a.GetGUID(&k).map(|g| nome_do_subtipo(&g)).unwrap_or_default(),
                Ok(t) if t == MF_ATTRIBUTE_DOUBLE => a.GetDouble(&k).map(|v| v.to_string()).unwrap_or_default(),
                Ok(t) if t == MF_ATTRIBUTE_STRING => {
                    let n = a.GetStringLength(&k).unwrap_or(0) as usize;
                    let mut b = vec![0u16; n + 1];
                    let _ = a.GetString(&k, &mut b, None);
                    format!("\"{}\"", String::from_utf16_lossy(&b[..n]))
                }
                Ok(t) if t == MF_ATTRIBUTE_BLOB => {
                    let n = a.GetBlobSize(&k).unwrap_or(0) as usize;
                    let mut b = vec![0u8; n];
                    let _ = a.GetBlob(&k, &mut b, None);
                    let hex: String = b.iter().take(48).map(|x| format!("{x:02X}")).collect();
                    format!("blob {n} B [{hex}{}]", if n > 48 { "…" } else { "" })
                }
                Ok(_) => "(interface)".into(),
                Err(e) => format!("(tipo? {e})"),
            };
            partes.push(format!("{}={valor}", nome_da_chave(&k)));
        }
    }
    partes.join(" ")
}

/// **O aspecto do DV com o fluxo rodando** (a fase 5: a Panasonic em 16:9 sai comprimida no
/// receptor; em 4:3, normal). Abre a câmera do link exato como o produto abre o DV (controladora,
/// o leitor com o gerenciador D3D, o tipo escolhido pela regra do produto, YUY2 pedido ao
/// decodificador do Windows) e lê quadros por `--segundos`: imprime **todos** os atributos dos tipos
/// nativos, do tipo que o leitor entrega e da primeira amostra; a cada troca de tipo
/// (`CURRENTMEDIATYPECHANGED`, `NATIVEMEDIATYPECHANGED`), os dois tipos de novo; e a cada 5 s, o
/// aspecto do tipo em uso e os atributos da amostra, para uma troca que não venha como troca de
/// tipo. **Nenhum pixel é lido** nem gravado. Só webcam USB e a fonte do EOS Webcam Utility.
fn cmd_aspecto(args: &[String]) -> Result<()> {
    use quall_capture_probe::regras_da_camera::{escolher_tipo_nativo, Subtipo, TetoDaCamera, TipoNativo};
    let mut link: Option<String> = None;
    let mut segundos = 60u64;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--link" => {
                link = args.get(i + 1).cloned();
                i += 1;
            }
            "--segundos" => {
                segundos = args.get(i + 1).and_then(|v| v.parse().ok()).unwrap_or(60);
                i += 1;
            }
            outro => bail!("opção desconhecida: {outro}"),
        }
        i += 1;
    }
    let link = link.ok_or_else(|| anyhow!("--link <link exato> é obrigatório"))?;
    let minusculo = link.to_ascii_lowercase();
    if minusculo.starts_with(r"\\?\swd#vcamdevapi#") || !(minusculo.starts_with(r"\\?\usb#") || minusculo.starts_with(r"\\?\root#eoswebcamsource#")) {
        diga!("RECUSADO antes de criar a fonte: só webcam USB ou a fonte do EOS Webcam Utility | {link}");
        std::process::exit(2);
    }
    let luid = placa_intel()?;
    let a = device::create_device_por_luid(luid)?;
    let _ = device::proteger_contexto(&a.context, true);
    let gerenciador = quall_capture_probe::encoder::create_device_manager(&a.device)?;
    let etapa = |nome: &str, e: windows::core::Error| anyhow!("{nome}: {:?} ({})", e.code(), e.message());
    let fonte: IMFMediaSource = unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2).map_err(|e| etapa("MFCreateAttributes", e))?;
        let attrs = attrs.ok_or_else(|| anyhow!("sem atributos"))?;
        attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID).map_err(|e| etapa("SOURCE_TYPE", e))?;
        attrs.SetString(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &HSTRING::from(link.as_str())).map_err(|e| etapa("SYMBOLIC_LINK", e))?;
        MFCreateDeviceSource(&attrs).map_err(|e| etapa("MFCreateDeviceSource", e))?
    };
    let resultado = (|| -> Result<()> {
        let leitor: IMFSourceReader = unsafe {
            let mut attrs: Option<IMFAttributes> = None;
            MFCreateAttributes(&mut attrs, 2).map_err(|e| etapa("MFCreateAttributes do leitor", e))?;
            let attrs = attrs.ok_or_else(|| anyhow!("sem atributos"))?;
            attrs.SetUnknown(&MF_SOURCE_READER_D3D_MANAGER, &gerenciador).map_err(|e| etapa("D3D_MANAGER", e))?;
            attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1).map_err(|e| etapa("HARDWARE_TRANSFORMS", e))?;
            MFCreateSourceReaderFromMediaSource(&fonte, &attrs).map_err(|e| etapa("MFCreateSourceReaderFromMediaSource", e))?
        };
        let fluxo = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
        let atual_nativo = MF_SOURCE_READER_CURRENT_TYPE_INDEX.0 as u32;
        let mut nativos: Vec<(TipoNativo, IMFMediaType)> = Vec::new();
        let mut k = 0u32;
        while let Ok(t) = unsafe { leitor.GetNativeMediaType(fluxo, k) } {
            diga!("NATIVO {k}: {}", todos_os_atributos(&t.cast()?));
            let sub = unsafe { t.GetGUID(&MF_MT_SUBTYPE) }.unwrap_or(GUID::zeroed());
            let tam = unsafe { t.GetUINT64(&MF_MT_FRAME_SIZE) }.unwrap_or(0);
            let fps = unsafe { t.GetUINT64(&MF_MT_FRAME_RATE) }.unwrap_or(0);
            let subtipo = match nome_do_subtipo(&sub).as_str() {
                "NV12" => Subtipo::Nv12,
                "YUY2" => Subtipo::Yuy2,
                "MJPG" => Subtipo::Mjpg,
                "I420" => Subtipo::I420,
                s if s.starts_with("fourcc:dv") => Subtipo::Dv,
                _ => Subtipo::Outro,
            };
            nativos.push((TipoNativo { subtipo, largura: (tam >> 32) as u32, altura: tam as u32, fps_num: (fps >> 32) as u32, fps_den: fps as u32 }, t));
            k += 1;
        }
        let lista: Vec<TipoNativo> = nativos.iter().map(|(t, _)| *t).collect();
        let escolhido = escolher_tipo_nativo(&lista, TetoDaCamera { max_macroblocos: 8160, fps: 30 })
            .ok_or_else(|| anyhow!("a regra do produto não escolhe nenhum dos {} tipos", lista.len()))?;
        let ex: IMFSourceReaderEx = leitor.cast().map_err(|e| etapa("IMFSourceReaderEx", e))?;
        unsafe { ex.SetNativeMediaType(fluxo, &nativos[escolhido].1) }.map_err(|e| etapa("SetNativeMediaType", e))?;
        diga!("escolhido o NATIVO {escolhido} ({})", lista[escolhido].descricao());
        let mut aceito = None;
        for sub in [MFVideoFormat_YUY2, MFVideoFormat_NV12] {
            let t = unsafe { MFCreateMediaType() }?;
            unsafe {
                t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
                t.SetGUID(&MF_MT_SUBTYPE, &sub)?;
            }
            if unsafe { leitor.SetCurrentMediaType(fluxo, None, &t) }.is_ok() {
                aceito = Some(nome_do_subtipo(&sub));
                break;
            }
        }
        diga!("o leitor aceitou {}", aceito.unwrap_or_else(|| "NADA (nem YUY2 nem NV12)".into()));
        let dizer_os_tipos = |quando: &str| {
            if let Ok(t) = unsafe { leitor.GetCurrentMediaType(fluxo) } {
                if let Ok(a) = t.cast::<IMFAttributes>() {
                    diga!("  {quando} SAÍDA: {}", todos_os_atributos(&a));
                }
            }
            if let Ok(t) = unsafe { leitor.GetNativeMediaType(fluxo, atual_nativo) } {
                if let Ok(a) = t.cast::<IMFAttributes>() {
                    diga!("  {quando} NATIVO EM USO: {}", todos_os_atributos(&a));
                }
            }
        };
        dizer_os_tipos("[antes do primeiro quadro]");
        let t0 = Instant::now();
        let mut quadros = 0u64;
        let mut proximo_relato = Duration::from_secs(5);
        let mut primeira_amostra = true;
        diga!("lendo por {segundos} s: troque 16:9 <-> 4:3 na câmera agora ({})", chrono_agora());
        while t0.elapsed() < Duration::from_secs(segundos) {
            let (mut real, mut bandeiras, mut ts) = (0u32, 0u32, 0i64);
            let mut amostra: Option<IMFSample> = None;
            if let Err(e) = unsafe { leitor.ReadSample(fluxo, 0, Some(&mut real), Some(&mut bandeiras), Some(&mut ts), Some(&mut amostra)) } {
                diga!("ReadSample: {:?} ({}) aos {:.1} s", e.code(), e.message(), t0.elapsed().as_secs_f64());
                break;
            }
            let mudou_saida = bandeiras & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED.0 as u32 != 0;
            let mudou_nativo = bandeiras & MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED.0 as u32 != 0;
            if mudou_saida || mudou_nativo {
                diga!(
                    "TROCA DE TIPO aos {:.2} s ({}), quadro {quadros}: saída={mudou_saida} nativo={mudou_nativo}",
                    t0.elapsed().as_secs_f64(),
                    chrono_agora()
                );
                dizer_os_tipos("[depois da troca]");
            }
            if bandeiras & (MF_SOURCE_READERF_ERROR.0 as u32 | MF_SOURCE_READERF_ENDOFSTREAM.0 as u32) != 0 {
                diga!("o fluxo acabou (bandeiras 0x{bandeiras:X})");
                break;
            }
            if let Some(s) = amostra {
                quadros += 1;
                if primeira_amostra {
                    primeira_amostra = false;
                    diga!("  a primeira AMOSTRA: {}", todos_os_atributos(&s.cast()?));
                }
                if t0.elapsed() >= proximo_relato {
                    proximo_relato += Duration::from_secs(5);
                    let par = unsafe { leitor.GetCurrentMediaType(fluxo) }
                        .and_then(|t| unsafe { t.GetUINT64(&MF_MT_PIXEL_ASPECT_RATIO) })
                        .map(|v| format!("{}:{}", v >> 32, v & 0xffff_ffff))
                        .unwrap_or_else(|_| "não declarada".into());
                    let vaux = unsafe { leitor.GetNativeMediaType(fluxo, atual_nativo) }
                        .and_then(|t| unsafe { t.GetUINT32(&MF_MT_DV_VAUX_CTRL_PACK) })
                        .map(|v| format!("0x{v:08X}"))
                        .unwrap_or_else(|_| "—".into());
                    diga!(
                        "  vivo aos {:.0} s ({}): {quadros} quadros; PAR da saída {par}; VAUX_CTRL do nativo {vaux} | amostra: {}",
                        t0.elapsed().as_secs_f64(),
                        chrono_agora(),
                        todos_os_atributos(&s.cast()?)
                    );
                }
            }
        }
        diga!("fim: {quadros} quadros em {:.1} s", t0.elapsed().as_secs_f64());
        dizer_os_tipos("[no fim]");
        Ok(())
    })();
    let _ = unsafe { fonte.Shutdown() };
    resultado
}

// =============================================================================================
// `desentrelacar`: o A/B do desentrelaçador sobre quadros de arquivo (sem câmera)
// =============================================================================================

/// **O controle e o A/B do desentrelaçador** (a frente de 22/09): lê quadros YUY2 720×480 seguidos
/// de um arquivo (o DV da Panasonic decodificado no Mac, o que o decodificador de DV do Windows
/// entrega ao leitor), passa cada um pelo caminho do produto e grava o NV12 que sai do conversor,
/// quadro a quadro, para medir no Mac:
///
/// - `nenhum`: o conversor progressivo, o quadro com os dois campos (o `--sem-desentrelacar`);
/// - `bob`: o conversor do produto com o índice do `bob` do processador de vídeo, sem quadros de
///   referência (o que o app fazia até esta frente);
/// - `adapt2`: o desentrelaçador na CPU (`desentrelacador.rs`) sobre o YUY2, e o conversor
///   progressivo atrás (o que o app faz agora).
///
/// O custo do desentrelaçamento vai junto: o `Blt` com a espera da GPU e, no `adapt2`, a CPU.
/// Nenhum pixel de câmera: a entrada é arquivo.
fn cmd_desentrelacar(args: &[String]) -> Result<()> {
    use quall_capture_probe::captura_de_camera::textura_do_anel;
    use quall_capture_probe::conversor_de_camera::ConversorDeCamera;
    use quall_capture_probe::regras_da_camera::Entrelacamento;
    use windows::Win32::Graphics::Direct3D11::{ID3D11Query, D3D11_CPU_ACCESS_READ, D3D11_MAP_READ, D3D11_QUERY_DESC, D3D11_QUERY_EVENT};
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_YUY2;

    let mut entrada = None;
    let mut saida = None;
    let mut modo = "bob".to_string();
    let mut cima_primeiro = false;
    let (mut sl, mut sa) = (720u32, 480u32);
    let mut h264: Option<String> = None;
    let mut bitrate: u32 = 1_779_166;
    let mut gravar_entrada: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        let valor = |i: usize| args.get(i + 1).cloned().ok_or_else(|| anyhow!("falta o valor de {}", args[i]));
        match args[i].as_str() {
            "--entrada" => entrada = Some(valor(i)?),
            "--saida" => saida = Some(valor(i)?),
            "--modo" => modo = valor(i)?,
            "--h264" => h264 = Some(valor(i)?),
            "--gravar-entrada" => gravar_entrada = Some(valor(i)?),
            "--bitrate" => bitrate = valor(i)?.parse()?,
            "--campo-de-cima-primeiro" => {
                cima_primeiro = true;
                i += 1;
                continue;
            }
            "--saida-tamanho" => {
                let v = valor(i)?;
                let (l, a) = v.split_once('x').ok_or_else(|| anyhow!("--saida-tamanho LxA"))?;
                sl = l.parse()?;
                sa = a.parse()?;
            }
            outro => bail!("opção desconhecida: {outro}"),
        }
        i += 2;
    }
    let entrada = entrada.ok_or_else(|| anyhow!("--entrada ARQ.yuy2"))?;
    let saida = saida.ok_or_else(|| anyhow!("--saida ARQ.nv12"))?;
    if modo == "so-codificar" {
        // A segunda compressão (o OBS gravando, aproximado pelo Quick Sync do produto): quadros NV12
        // `--saida-tamanho` de arquivo direto ao encoder, sem conversor. `--saida` não é escrita.
        let h264 = h264.ok_or_else(|| anyhow!("so-codificar pede --h264"))?;
        let dados = std::fs::read(&entrada).with_context(|| format!("lendo {entrada}"))?;
        let t = (sl * sa * 3 / 2) as usize;
        let luid = placa_intel()?;
        let a = device::create_device_por_luid(luid)?;
        let gerenciador = encoder::create_device_manager(&a.device)?;
        let mut cod = Codificador::abrir(
            Entrega::Textura, sl, sa, 30, bitrate, &a.device, &a.context, &gerenciador, luid, Some(&h264), Montagem::Produto, false, false, false,
        )?;
        let vazia = unsafe { MFCreateSample() }?;
        for (q, quadro) in dados.chunks_exact(t).enumerate() {
            cod.submeter(&vazia, Some(quadro), q as i64 * 333_333);
        }
        diga!("{}", cod.fechar());
        return Ok(());
    }
    let (w, h) = (720u32, 480u32);
    let tam = (w * h * 2) as usize;
    let dados = if entrada.to_ascii_lowercase().ends_with(".avi") {
        quadros_yuy2_de_arquivo(&entrada, w, h)?
    } else {
        std::fs::read(&entrada).with_context(|| format!("lendo {entrada}"))?
    };
    if let Some(g) = &gravar_entrada {
        std::fs::write(g, &dados).with_context(|| format!("gravando {g}"))?;
    }
    let n = dados.len() / tam;
    let campos = if cima_primeiro { Entrelacamento::CampoDeCimaPrimeiro } else { Entrelacamento::CampoDeBaixoPrimeiro };
    let e = match modo.as_str() {
        "bob" | "gpu-passado" | "gpu-referencias" => campos,
        "nenhum" | "adapt2" | "adapt2-produto" | "adapt2-recorte" => Entrelacamento::Progressivo,
        outro => bail!("--modo bob|adapt2|adapt2-produto|nenhum|gpu-passado|gpu-referencias, e não {outro}"),
    };

    let luid = placa_intel()?;
    let a = device::create_device_por_luid(luid)?;
    let (d, c) = (&a.device, &a.context);
    let conv = ConversorDeCamera::novo(d, DXGI_FORMAT_YUY2, w, h, sl, sa, false, false, e).map_err(|x| anyhow!("conversor: {x}"))?;
    diga!("dispositivo: {} | {} quadros de {entrada} | modo {modo} | {}", a.description, n, conv.descricao);

    let preparo_desc = D3D11_TEXTURE2D_DESC {
        Width: w,
        Height: h,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_YUY2,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
        MiscFlags: 0,
    };
    let mut preparo: Option<ID3D11Texture2D> = None;
    unsafe { d.CreateTexture2D(&preparo_desc, None, Some(&mut preparo)) }.context("preparo")?;
    let preparo = preparo.ok_or_else(|| anyhow!("sem preparo"))?;
    // Três texturas: o quadro, o passado e o futuro (os modos `gpu-*`).
    let anel = (0..3).map(|_| textura_do_anel(d, DXGI_FORMAT_YUY2, w, h).context("anel YUY2")).collect::<Result<Vec<_>>>()?;
    let leitura_desc = D3D11_TEXTURE2D_DESC {
        Width: sl,
        Height: sa,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_NV12,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
        MiscFlags: 0,
    };
    let mut leitura: Option<ID3D11Texture2D> = None;
    unsafe { d.CreateTexture2D(&leitura_desc, None, Some(&mut leitura)) }.context("leitura")?;
    let leitura = leitura.ok_or_else(|| anyhow!("sem leitura"))?;
    let consulta_desc = D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 };
    let mut consulta: Option<ID3D11Query> = None;
    unsafe { d.CreateQuery(&consulta_desc, Some(&mut consulta)) }.context("CreateQuery")?;
    let consulta = consulta.ok_or_else(|| anyhow!("sem consulta"))?;
    // `--h264`: o NV12 que sai do conversor vai ao encoder do produto (a montagem da câmera, 30 fps,
    // GOP de 1 s), para separar o que é do desentrelaçador do que é da taxa do encoder.
    let gerenciador = encoder::create_device_manager(d)?;
    let mut codificador = match h264.as_deref() {
        Some(arq) => Some(Codificador::abrir(
            Entrega::Textura, sl, sa, 30, bitrate, d, c, &gerenciador, luid, Some(arq), Montagem::Produto, false, false, false,
        )?),
        None => None,
    };
    let vazia = unsafe { MFCreateSample() }?;
    let mut nv12 = vec![0u8; (sl * sa * 3 / 2) as usize];

    let mut des = quall_capture_probe::desentrelacador::Desentrelacador::novo_yuy2(
        w as usize,
        h as usize,
        if cima_primeiro {
            quall_capture_probe::desentrelacador::Ordem::CampoDeCimaPrimeiro
        } else {
            quall_capture_probe::desentrelacador::Ordem::CampoDeBaixoPrimeiro
        },
    )
    .ok_or_else(|| anyhow!("geometria recusada pelo desentrelaçador"))?;
    let mut quadro = vec![0u8; tam];
    // `adapt2-produto`: o caminho do produto inteiro — a amostra do Media Foundation num buffer 2D
    // YUY2 (como o do decodificador de DV), `copiar_amostra_desentrelacando` com o preparo da
    // captura; o tempo medido é o da cópia com o adapt2 (o que a thread da sessão paga).
    let mut preparo_do_produto: Option<ID3D11Texture2D> = None;
    let mut arq = std::io::BufWriter::new(std::fs::File::create(&saida).with_context(|| format!("criando {saida}"))?);
    let (mut t_cpu, mut t_blt) = (Vec::with_capacity(n), Vec::with_capacity(n));
    let mut bob_por_mil = Vec::with_capacity(n);
    for q in 0..n {
        let origem = &dados[q * tam..(q + 1) * tam];
        let t0 = Instant::now();
        let fonte: &[u8] = if modo == "adapt2" {
            let r = des.yuy2(origem, w as usize * 2, &mut quadro, w as usize * 2);
            bob_por_mil.push(r.bob_por_mil());
            &quadro
        } else {
            origem
        };
        if modo == "adapt2-produto" || modo == "adapt2-recorte" {
            // `adapt2-recorte`: a imagem dentro de um quadro maior (736×488, em x=8, y=4, com lixo
            // em volta e o passo maior que a linha), como a de um decodificador alinhado: a saída
            // tem de ser a mesma do `adapt2-produto`.
            let (qw, qh, gx, gy) = if modo == "adapt2-recorte" { (736u32, 488u32, 8u32, 4u32) } else { (w, h, 0, 0) };
            let b = unsafe { MFCreate2DMediaBuffer(qw, qh, u32::from_le_bytes(*b"YUY2"), false) }.context("MFCreate2DMediaBuffer")?;
            unsafe {
                let b2: IMF2DBuffer = b.cast()?;
                let mut p: *mut u8 = std::ptr::null_mut();
                let mut passo = 0i32;
                b2.Lock2D(&mut p, &mut passo)?;
                for y in 0..qh as usize {
                    std::ptr::write_bytes(p.offset(y as isize * passo as isize), 0x3C, qw as usize * 2);
                }
                for y in 0..h as usize {
                    std::ptr::copy_nonoverlapping(
                        origem.as_ptr().add(y * w as usize * 2),
                        p.offset((y + gy as usize) as isize * passo as isize + gx as isize * 2),
                        w as usize * 2,
                    );
                }
                b2.Unlock2D()?;
                b.SetCurrentLength(b.GetMaxLength()?)?;
            }
            let geometria = quall_capture_probe::regras_da_camera::Geometria { quadro_largura: qw, quadro_altura: qh, x: gx, y: gy, largura: w, altura: h };
            let amostra = amostra_de(&b)?;
            let t0 = Instant::now();
            let antes = des.pix_bob;
            let total_antes = des.pix_total;
            let caminho = quall_capture_probe::captura_de_camera::copiar_amostra_desentrelacando(
                d,
                c,
                &amostra,
                &anel[q % 3],
                geometria,
                quall_capture_probe::captura_de_camera::FormatoDoLeitor::Yuy2,
                &mut preparo_do_produto,
                Some(&mut des),
            )
            .map_err(|e| anyhow!("copiar_amostra_desentrelacando: {e}"))?;
            t_cpu.push(t0.elapsed().as_secs_f64() * 1000.0);
            if q == 0 {
                diga!("adapt2-produto: o primeiro quadro entrou por {caminho:?}");
            }
            let tot = des.pix_total - total_antes;
            bob_por_mil.push(if tot == 0 { 0.0 } else { 1000.0 * (des.pix_bob - antes) as f64 / tot as f64 });
        } else {
        t_cpu.push(t0.elapsed().as_secs_f64() * 1000.0);
        unsafe {
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            c.Map(&preparo, 0, D3D11_MAP_WRITE, 0, Some(&mut m)).context("Map do preparo")?;
            let p = m.pData as *mut u8;
            for y in 0..h as usize {
                std::ptr::copy_nonoverlapping(fonte.as_ptr().add(y * w as usize * 2), p.add(y * m.RowPitch as usize), w as usize * 2);
            }
            c.Unmap(&preparo, 0);
            c.CopyResource(&anel[q % 3], &preparo);
        }
        }
        // O que converter agora: (o quadro, os passados, os futuros). No `gpu-referencias` a saída
        // atrasa um quadro (o futuro é o que acabou de chegar); o último sai sem futuro.
        let mut trabalhos: Vec<(usize, Vec<usize>, Vec<usize>)> = Vec::new();
        match modo.as_str() {
            "gpu-passado" => trabalhos.push((q, if q > 0 { vec![q - 1] } else { vec![] }, vec![])),
            "gpu-referencias" => {
                if q >= 1 {
                    trabalhos.push((q - 1, if q >= 2 { vec![q - 2] } else { vec![] }, vec![q]));
                }
                if q + 1 == n {
                    trabalhos.push((q, if q >= 1 { vec![q - 1] } else { vec![] }, vec![]));
                }
            }
            _ => trabalhos.push((q, vec![], vec![])),
        }
        for (alvo, passados, futuros) in trabalhos {
            let t1 = Instant::now();
            let saida_t = if passados.is_empty() && futuros.is_empty() && !modo.starts_with("gpu-") {
                conv.converter(&anel[alvo % 3]).map_err(|x| anyhow!("Blt: {x}"))?
            } else {
                let ps: Vec<&ID3D11Texture2D> = passados.iter().map(|k| &anel[k % 3]).collect();
                let fs: Vec<&ID3D11Texture2D> = futuros.iter().map(|k| &anel[k % 3]).collect();
                conv.converter_com_referencias(&anel[alvo % 3], &ps, &fs, alvo as u32).map_err(|x| anyhow!("Blt com referências: {x}"))?
            };
            unsafe {
                c.End(&consulta);
                let mut feito: u32 = 0;
                while c.GetData(&consulta, Some(&mut feito as *mut u32 as *mut core::ffi::c_void), 4, 0).is_err() || feito == 0 {
                    std::hint::spin_loop();
                    if t1.elapsed() > Duration::from_secs(1) {
                        break;
                    }
                }
            }
            t_blt.push(t1.elapsed().as_secs_f64() * 1000.0);
            unsafe {
                c.CopyResource(&leitura, &saida_t);
                let mut m = D3D11_MAPPED_SUBRESOURCE::default();
                c.Map(&leitura, 0, D3D11_MAP_READ, 0, Some(&mut m)).context("Map da leitura")?;
                let p = m.pData as *const u8;
                for y in 0..(sa + sa / 2) as usize {
                    let l = std::slice::from_raw_parts(p.add(y * m.RowPitch as usize), sl as usize);
                    nv12[y * sl as usize..(y + 1) * sl as usize].copy_from_slice(l);
                }
                c.Unmap(&leitura, 0);
            }
            arq.write_all(&nv12)?;
            if let Some(cod) = codificador.as_mut() {
                cod.submeter(&vazia, Some(&nv12), alvo as i64 * 333_333);
            }
        }
    }
    arq.flush()?;
    if let Some(cod) = codificador.take() {
        diga!("{}", cod.fechar());
    }
    let p = |v: &mut Vec<f64>, f: f64| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        v.get(((v.len() as f64 - 1.0) * f).round() as usize).copied().unwrap_or(0.0)
    };
    let bob_medio = if bob_por_mil.is_empty() { 0.0 } else { bob_por_mil.iter().sum::<f64>() / bob_por_mil.len() as f64 };
    diga!(
        "{n} quadros NV12 {sl}x{sa} em {saida} | CPU (desentrelaçar) p50 {:.3} p95 {:.3} máx {:.3} ms | Blt com a espera da GPU p50 {:.3} p95 {:.3} ms | adapt2: {bob_medio:.1}‰ das linhas reconstruídas por interpolação",
        p(&mut t_cpu, 0.5),
        p(&mut t_cpu, 0.95),
        p(&mut t_cpu, 1.0),
        p(&mut t_blt, 0.5),
        p(&mut t_blt, 0.95),
    );
    Ok(())
}

/// **O decodificador de DV da Microsoft, sem câmera**: um AVI com `dvsd` (o DV da fase A remuxado
/// pelo FFmpeg, `-c copy`) lido pelo leitor do Media Foundation **sem o gerenciador D3D**, pedindo
/// YUY2 — o que o leitor da câmera DV faz com o adapt2 ligado. Devolve os quadros YUY2 w×h seguidos,
/// e diz o que a amostra traz dos campos.
fn quadros_yuy2_de_arquivo(caminho: &str, w: u32, h: u32) -> Result<Vec<u8>> {
    let fluxo = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
    let leitor = unsafe { MFCreateSourceReaderFromURL(&HSTRING::from(caminho), None) }.context("MFCreateSourceReaderFromURL")?;
    unsafe {
        let _ = leitor.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false);
        leitor.SetStreamSelection(fluxo, true)?;
        let nativo = leitor.GetNativeMediaType(fluxo, 0)?;
        let sub = nativo.GetGUID(&MF_MT_SUBTYPE).unwrap_or(GUID::zeroed());
        let modo = nativo.GetUINT32(&MF_MT_INTERLACE_MODE).ok();
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_YUY2)?;
        leitor.SetCurrentMediaType(fluxo, None, &t).context("o leitor não entrega YUY2")?;
        let atual = leitor.GetCurrentMediaType(fluxo)?;
        let modo_saida = atual.GetUINT32(&MF_MT_INTERLACE_MODE).ok();
        diga!("arquivo: nativo {} (MF_MT_INTERLACE_MODE {modo:?}) → YUY2 (saída {modo_saida:?}), sem o gerenciador D3D", nome_do_subtipo(&sub));
    }
    let tam = (w * h * 2) as usize;
    let mut saida = Vec::new();
    let mut primeira = true;
    loop {
        let mut indice = 0u32;
        let mut bandeiras = 0u32;
        let mut tempo = 0i64;
        let mut amostra: Option<IMFSample> = None;
        unsafe { leitor.ReadSample(fluxo, 0, Some(&mut indice), Some(&mut bandeiras), Some(&mut tempo), Some(&mut amostra)) }
            .context("ReadSample")?;
        if bandeiras & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            break;
        }
        let Some(a) = amostra else { continue };
        if primeira {
            let b = |g: &GUID| unsafe { a.GetUINT32(g) }.ok();
            diga!(
                "arquivo: a primeira amostra diz Interlaced={:?} BottomFieldFirst={:?}",
                b(&MFSampleExtension_Interlaced),
                b(&MFSampleExtension_BottomFieldFirst)
            );
            primeira = false;
        }
        unsafe {
            let buffer = a.ConvertToContiguousBuffer()?;
            let mut p: *mut u8 = std::ptr::null_mut();
            let mut passo = (w * 2) as i32;
            let dois_d = buffer.cast::<IMF2DBuffer>().ok();
            match &dois_d {
                Some(b2) => b2.Lock2D(&mut p, &mut passo)?,
                None => {
                    let mut n = 0u32;
                    buffer.Lock(&mut p, None, Some(&mut n))?;
                    if (n as usize) < tam {
                        let _ = buffer.Unlock();
                        bail!("buffer de {n} bytes para um quadro YUY2 {w}x{h}");
                    }
                }
            }
            for y in 0..h as usize {
                saida.extend_from_slice(std::slice::from_raw_parts(p.offset(y as isize * passo as isize), (w * 2) as usize));
            }
            match &dois_d {
                Some(b2) => b2.Unlock2D()?,
                None => buffer.Unlock()?,
            }
        }
    }
    diga!("arquivo: {} quadros YUY2 {w}x{h} do decodificador do Windows", saida.len() / tam);
    Ok(saida)
}

fn uso() {
    eprintln!(
        "uso:\n  quall_camera_local adaptadores\n  quall_camera_local listar\n  quall_camera_local ler \
         (--direto | --link <link exato> | --criar-camera <nome>) [--compartilhado] [--quadros N] \
         [--prazo S] [--leitor-d3d | --converter] [--tamanho LxA] \
         [--codificar memoria|textura|array|amostra [--subrecurso-errado] [--oficina | --negociar-local [--baixa-latencia] [--declarar-cor]] [--h264 ARQ] [--bitrate B]]\n  \
         quall_camera_local listar [--repetir S]\n  \
         quall_camera_local capturar (--direto | --link <link exato> | --criar-camera <base>) [--quadros N] [--prazo S] [--codificar] [--converter-para LxA] [--conferir-a-cada N [--conferir-atrasado]] [--sem-flush] [--regua (só com --direto)] [--compartilhada (só com --link)] [--desentrelacador adapt2|bob] [--sem-desentrelacar]\n  \
         quall_camera_local segurar --criar-camera <base> [--prazo S] [--regua]   (cria o nó e só o segura; com --regua, serve o cano dele)\n  \
         quall_camera_local diagnosticar-leitor --link <link exato de webcam USB ou do EOS Webcam Utility> [--variantes 1,2,3,4]   (um quadro por variante; a câmera transmite um instante em cada)\n  \
         quall_camera_local aspecto --link <link exato> [--segundos N]   (o fluxo rodando N s: os tipos, as trocas de tipo e o aspecto; nenhum pixel lido)\n  \
         quall_camera_local anel   (a cópia na chegada e o conversor com texturas sintéticas; sem câmera)\n  \
         quall_camera_local desentrelacar --entrada ARQ.yuy2|ARQ.avi --saida ARQ.nv12 [--modo bob|adapt2|adapt2-produto|adapt2-recorte|nenhum|gpu-passado|gpu-referencias|so-codificar] [--h264 ARQ [--bitrate B]] [--gravar-entrada ARQ] [--campo-de-cima-primeiro] [--saida-tamanho LxA]   (quadros YUY2 720x480 de arquivo; sem câmera)\n\
         \n--h264 só com --direto (nome aleatório, cano livre) ou --criar-camera.\
         \n--link só abre a câmera de bancada de outra sonda viva (\"<base> sonda <PID>\").\
         \n--criar-camera cria um nó PnP de vida de sessão: só com o sim do usuário."
    );
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    quall_capture_probe::diagnostico_cli::concluir(rodar());
}

fn rodar() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        MFStartup(MF_VERSION, MFSTARTUP_FULL)?;
    }
    let r = match args.first().map(String::as_str) {
        Some("adaptadores") => cmd_adaptadores(),
        Some("listar") => cmd_listar(&args[1..]),
        Some("ler") => cmd_ler(&args[1..]),
        Some("capturar") => cmd_capturar(&args[1..]),
        Some("anel") => cmd_anel(),
        Some("desentrelacar") => cmd_desentrelacar(&args[1..]),
        Some("segurar") => cmd_segurar(&args[1..]),
        Some("diagnosticar-leitor") => cmd_diagnosticar_leitor(&args[1..]),
        Some("aspecto") => cmd_aspecto(&args[1..]),
        _ => {
            uso();
            std::process::exit(64);
        }
    };
    // Sem soltura de câmera em curso (a revisão do código da fase 4, m2): senão, sai sem o
    // `MFShutdown`, e diz.
    if quall_capture_probe::captura_de_camera::solturas_pendentes() == 0 {
        unsafe {
            let _ = MFShutdown();
        }
    } else {
        diga!(
            "saída sem MFShutdown: {} soltura(s) de câmera ainda em curso",
            quall_capture_probe::captura_de_camera::solturas_pendentes()
        );
    }
    if let Err(e) = &r {
        diga!("ERRO: {e:#}");
    }
    r
}
