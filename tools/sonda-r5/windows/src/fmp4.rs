//! **Parte 2: o MP4 fragmentado do `IMFSinkWriter`, e o que sobra dele quando o processo morre.**
//!
//! O §5.4 do desenho escreve como hipótese de nome e de suporte o contêiner
//! `MFTranscodeContainerType_FMPEG4`. Esta parte grava com ele — H.264 da placa pedida (o
//! `IMFSinkWriter` escolhe o encoder, com `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS` e o gerenciador
//! DXGI da placa) e AAC de um tom sintético de 1 kHz —, e mede duas corridas:
//!
//! 1. **controle**: grava N s e chama `Finalize`. Prova que o arquivo e o leitor servem.
//! 2. **morte**: grava, e o processo pai chama `TerminateProcess` no filho no meio. O filho imprime
//!    uma linha por quadro entregue ao `WriteSample`, com as estatísticas do escritor
//!    (`GetStatistics`: recebidos, codificados, processados pelo coletor), então o pai sabe quanto
//!    tinha sido entregue no instante do tiro.
//!
//! O arquivo que sobra é lido de dois jeitos, e os dois entram no relato: **pelas caixas**
//! (`caixas.rs`: quantos fragmentos completos, quantas amostras, quanto está cortado no fim) e
//! **pelo `IMFSourceReader`** (abre? quantas amostras comprimidas ele entrega? e decodificando para
//! NV12, quantos quadros saem?).

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use quall_capture_probe::device;
use serde::Serialize;
use serde_json::{json, Value};
use windows::core::{Interface, GUID, HSTRING, Result};
use windows::Win32::Media::MediaFoundation::*;

use crate::caixas;
use crate::comum::{hr, par, Origem, OrigemNv12};

pub struct Opcoes {
    pub luid: Option<u64>,
    pub arquivo: PathBuf,
    pub segundos: f64,
    pub largura: u32,
    pub altura: u32,
    pub fps: u32,
    pub bitrate: u32,
    /// `true`: texturas D3D11 da placa pelo gerenciador DXGI. `false`: ARGB32 em memória.
    pub gpu: bool,
    /// Com `gpu`: `true` entrega NV12 (o formato da câmera), `false` BGRA.
    pub nv12: bool,
}

fn linha(s: &str) {
    let mut o = std::io::stdout().lock();
    let _ = writeln!(o, "{s}");
    let _ = o.flush();
}

/// O tom: 1 kHz, estéreo, 16 bits, 48 kHz, a um quarto da escala.
struct Tom {
    n: u64,
}

impl Tom {
    fn bloco(&mut self, quadros: usize) -> Vec<u8> {
        let mut v = Vec::with_capacity(quadros * 4);
        for _ in 0..quadros {
            let x = (2.0 * std::f64::consts::PI * 1000.0 * self.n as f64 / 48_000.0).sin();
            let s = (x * 0.25 * i16::MAX as f64) as i16;
            v.extend_from_slice(&s.to_le_bytes());
            v.extend_from_slice(&s.to_le_bytes());
            self.n += 1;
        }
        v
    }
}

fn amostra_de_memoria(dados: &[u8], t: i64, d: i64) -> Result<IMFSample> {
    unsafe {
        let b = MFCreateMemoryBuffer(dados.len() as u32)?;
        let mut p: *mut u8 = std::ptr::null_mut();
        b.Lock(&mut p, None, None)?;
        std::ptr::copy_nonoverlapping(dados.as_ptr(), p, dados.len());
        b.Unlock()?;
        b.SetCurrentLength(dados.len() as u32)?;
        let s = MFCreateSample()?;
        s.AddBuffer(&b)?;
        s.SetSampleTime(t)?;
        s.SetSampleDuration(d)?;
        Ok(s)
    }
}

/// A amostra de uma textura, **com o comprimento do buffer declarado**. É a diferença para
/// `encoder::sample_from_texture`, que serve ao MFT direto: o buffer DXGI nasce com comprimento
/// corrente 0, o MFT não olha, e o `IMFSinkWriter` recusa o `WriteSample` com `E_INVALIDARG`
/// (medido no Dell em 24/09, nas duas entradas, NV12 e ARGB32). O comprimento vem do
/// `IMF2DBuffer::GetContiguousLength`.
fn amostra_de_textura(tex: &windows::Win32::Graphics::Direct3D11::ID3D11Texture2D, t: i64, d: i64) -> Result<IMFSample> {
    unsafe {
        let b = MFCreateDXGISurfaceBuffer(&windows::Win32::Graphics::Direct3D11::ID3D11Texture2D::IID, tex, 0, false)?;
        let b2: IMF2DBuffer = b.cast()?;
        b.SetCurrentLength(b2.GetContiguousLength()?)?;
        let s = MFCreateSample()?;
        s.AddBuffer(&b)?;
        s.SetSampleTime(t)?;
        s.SetSampleDuration(d)?;
        Ok(s)
    }
}

/// O nome do encoder que o escritor escolheu, se ele deixar perguntar.
fn encoder_do_escritor(w: &IMFSinkWriter, fluxo: u32) -> String {
    unsafe {
        let mut p: *mut core::ffi::c_void = std::ptr::null_mut();
        if let Err(e) = w.GetServiceForStream(fluxo, &GUID::zeroed(), &IMFTransform::IID, &mut p) {
            return format!("(não perguntável: {})", hr(&e));
        }
        let t = IMFTransform::from_raw(p);
        let Ok(a) = t.GetAttributes() else { return "(transform sem atributos)".into() };
        let async_ = a.GetUINT32(&MF_TRANSFORM_ASYNC).unwrap_or(0) == 1;
        let mut nome = String::new();
        let mut buf = [0u16; 256];
        let mut n = 0u32;
        if a.GetString(&MFT_FRIENDLY_NAME_Attribute, &mut buf, Some(&mut n)).is_ok() {
            nome = String::from_utf16_lossy(&buf[..n as usize]);
        }
        if nome.is_empty() {
            nome = "(sem nome amigável)".into();
        }
        let d3d11 = a.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) == 1;
        let sub = |r: Result<IMFMediaType>| {
            r.ok()
                .and_then(|t| t.GetGUID(&MF_MT_SUBTYPE).ok())
                .map(|g| {
                    let b = g.data1.to_le_bytes();
                    if b.iter().all(|c| c.is_ascii_alphanumeric()) {
                        String::from_utf8_lossy(&b).to_string()
                    } else {
                        format!("{g:?}")
                    }
                })
                .unwrap_or_else(|| "?".into())
        };
        format!(
            "{nome} (assíncrono/hardware={async_}, D3D11_AWARE={d3d11}, entra={}, sai={})",
            sub(t.GetInputCurrentType(0)),
            sub(t.GetOutputCurrentType(0))
        )
    }
}

/// O erro com o nome do passo: o `E_INVALIDARG` do escritor não diz de onde veio.
fn com<T>(passo: &str, r: Result<T>) -> Result<T> {
    r.map_err(|e| windows::core::Error::new(e.code(), format!("{passo}: {}", e.message())))
}

/// **O filho**: grava até acabar os segundos (e finaliza) ou até ser morto.
pub fn gravar(o: &Opcoes) -> Result<()> {
    let _ = std::fs::remove_file(&o.arquivo);
    let attrs = unsafe {
        let mut a: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut a, 4)?;
        a.unwrap()
    };
    unsafe {
        attrs.SetGUID(&MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_FMPEG4)?;
        attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;
    }
    let mut origem = None;
    let mut origem_nv12 = None;
    let mut _gerenciador = None;
    if o.gpu {
        let luid = o.luid.ok_or_else(|| windows::core::Error::new(windows::Win32::Foundation::E_INVALIDARG, "--placa é obrigatório com origem gpu"))?;
        let ad = device::create_device_por_luid(luid)?;
        let _ = device::proteger_contexto(&ad.context, true);
        let g = quall_capture_probe::encoder::create_device_manager(&ad.device)?;
        unsafe { attrs.SetUnknown(&MF_SINK_WRITER_D3D_MANAGER, &g)? };
        linha(&format!("INFO placa={} luid={:016X}", ad.description, luid));
        if o.nv12 {
            origem_nv12 = Some(OrigemNv12::nova(&ad.device, o.largura, o.altura, 8)?);
        } else {
            origem = Some(Origem::nova(&ad.device, o.largura, o.altura, 8)?);
        }
        _gerenciador = Some(g);
    }
    let w = com("MFCreateSinkWriterFromURL", unsafe { MFCreateSinkWriterFromURL(&HSTRING::from(o.arquivo.as_os_str()), None, &attrs) })?;

    // --- vídeo ---
    let vs = unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
        t.SetUINT32(&MF_MT_AVG_BITRATE, o.bitrate)?;
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        t.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High.0 as u32)?;
        par(&t, &MF_MT_FRAME_SIZE, o.largura, o.altura)?;
        par(&t, &MF_MT_FRAME_RATE, o.fps, 1)?;
        par(&t, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)?;
        com("AddStream vídeo", w.AddStream(&t))?
    };
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        let nv12 = o.gpu && o.nv12;
        t.SetGUID(&MF_MT_SUBTYPE, if nv12 { &MFVideoFormat_NV12 } else { &MFVideoFormat_ARGB32 })?;
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        t.SetUINT32(&MF_MT_DEFAULT_STRIDE, if nv12 { o.largura } else { o.largura * 4 })?;
        par(&t, &MF_MT_FRAME_SIZE, o.largura, o.altura)?;
        par(&t, &MF_MT_FRAME_RATE, o.fps, 1)?;
        par(&t, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)?;
        com("SetInputMediaType vídeo", w.SetInputMediaType(vs, &t, None))?;
    }
    // --- som ---
    let aus = unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC)?;
        t.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48_000)?;
        t.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2)?;
        t.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
        t.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24_000)?;
        t.SetUINT32(&MF_MT_AAC_PAYLOAD_TYPE, 0)?;
        com("AddStream som", w.AddStream(&t))?
    };
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM)?;
        t.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48_000)?;
        t.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2)?;
        t.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
        t.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, 4)?;
        t.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192_000)?;
        com("SetInputMediaType som", w.SetInputMediaType(aus, &t, None))?;
    }
    com("BeginWriting", unsafe { w.BeginWriting() })?;
    linha(&format!("INFO encoder_video={}", encoder_do_escritor(&w, vs)));
    linha(&format!("INFO encoder_audio={}", encoder_do_escritor(&w, aus)));
    linha(&format!("INFO origem={} entrada={}", if o.gpu { "gpu" } else { "memoria" }, if o.gpu && o.nv12 { "NV12" } else { "ARGB32" }));

    let mut quadro_mem: Vec<u8> = if o.gpu { Vec::new() } else { vec![0u8; (o.largura * o.altura * 4) as usize] };
    let mut tom = Tom { n: 0 };
    let periodo = Duration::from_nanos(1_000_000_000 / o.fps as u64);
    let inicio = Instant::now();
    let total = (o.segundos * o.fps as f64).round() as u64;
    let mut som_quadros: u64 = 0;
    for n in 0..total {
        let alvo = inicio + periodo * n as u32;
        let agora = Instant::now();
        if alvo > agora {
            std::thread::sleep(alvo - agora);
        }
        let t = (n as i64 * 10_000_000) / o.fps as i64;
        let t1 = ((n + 1) as i64 * 10_000_000) / o.fps as i64;
        let amostra = if let Some(or) = origem_nv12.as_mut() {
            let tex = com("origem NV12", or.proxima())?;
            com("amostra da textura", amostra_de_textura(&tex, t, t1 - t))?
        } else if let Some(or) = origem.as_mut() {
            com("amostra da textura", amostra_de_textura(&or.proxima(), t, t1 - t))?
        } else {
            let v = (n % 256) as u8;
            for px in quadro_mem.chunks_exact_mut(4) {
                px[0] = v;
                px[1] = 255 - v;
                px[2] = v.wrapping_mul(2);
                px[3] = 255;
            }
            amostra_de_memoria(&quadro_mem, t, t1 - t)?
        };
        com(&format!("WriteSample vídeo, quadro {n}"), unsafe { w.WriteSample(vs, &amostra) })?;
        // O som acompanha o vídeo no mesmo relógio: tudo o que cabe até o fim deste quadro.
        let alvo_som = ((n + 1) * 48_000) / o.fps as u64;
        let q = (alvo_som - som_quadros) as usize;
        let ts = (som_quadros as i64 * 10_000_000) / 48_000;
        let te = (alvo_som as i64 * 10_000_000) / 48_000;
        let a = amostra_de_memoria(&tom.bloco(q), ts, te - ts)?;
        com(&format!("WriteSample som, quadro {n}"), unsafe { w.WriteSample(aus, &a) })?;
        som_quadros = alvo_som;

        let mut st = MF_SINK_WRITER_STATISTICS { cb: std::mem::size_of::<MF_SINK_WRITER_STATISTICS>() as u32, ..Default::default() };
        let _ = unsafe { w.GetStatistics(vs, &mut st) };
        linha(&format!(
            "P v={} rec={} cod={} proc={} ms={}",
            n + 1,
            st.qwNumSamplesReceived,
            st.qwNumSamplesEncoded,
            st.qwNumSamplesProcessed,
            inicio.elapsed().as_millis()
        ));
    }
    let t = Instant::now();
    unsafe { w.Finalize()? };
    linha(&format!("FIM finalizado em {} ms", t.elapsed().as_millis()));
    Ok(())
}

#[derive(Debug, Default, Serialize)]
pub struct Leitura {
    pub abriu: bool,
    pub erro_ao_abrir: Option<String>,
    pub video: u64,
    pub audio: u64,
    pub ultimo_video_s: f64,
    pub ultimo_audio_s: f64,
    pub erro_no_meio: Option<String>,
}

/// Lê o arquivo pelo `IMFSourceReader`. `decodificar`: pede NV12 do vídeo (e larga o som), o que
/// põe um decodificador no caminho — é o "abre num player" mais perto que dá sem abrir player.
pub fn ler_com_leitor(arquivo: &Path, decodificar: bool) -> Leitura {
    let mut l = Leitura::default();
    let r = match unsafe { MFCreateSourceReaderFromURL(&HSTRING::from(arquivo.as_os_str()), None) } {
        Ok(r) => r,
        Err(e) => {
            l.erro_ao_abrir = Some(hr(&e));
            return l;
        }
    };
    l.abriu = true;
    // O tipo de cada fluxo, pelo tipo nativo.
    let mut e_video: Vec<bool> = Vec::new();
    for i in 0..8u32 {
        match unsafe { r.GetNativeMediaType(i, 0) } {
            Ok(t) => e_video.push(unsafe { t.GetGUID(&MF_MT_MAJOR_TYPE) }.map(|g| g == MFMediaType_Video).unwrap_or(false)),
            Err(_) => break,
        }
    }
    if decodificar {
        unsafe {
            let _ = r.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false);
            let _ = r.SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32, true);
            if let Ok(t) = MFCreateMediaType() {
                let _ = t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video);
                let _ = t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12);
                if let Err(e) = r.SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32, None, &t) {
                    l.erro_no_meio = Some(format!("SetCurrentMediaType NV12: {}", hr(&e)));
                    return l;
                }
            }
        }
    } else {
        unsafe {
            let _ = r.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, true);
        }
    }
    let selecionados = if decodificar { 1 } else { e_video.len().max(1) };
    let mut acabados: Vec<u32> = Vec::new();
    let mut vazios = 0u32;
    loop {
        let mut idx = 0u32;
        let mut flags = 0u32;
        let mut ts = 0i64;
        let mut s: Option<IMFSample> = None;
        let res = unsafe {
            r.ReadSample(MF_SOURCE_READER_ANY_STREAM.0 as u32, 0, Some(&mut idx), Some(&mut flags), Some(&mut ts), Some(&mut s))
        };
        if let Err(e) = res {
            l.erro_no_meio = Some(hr(&e));
            break;
        }
        if flags & MF_SOURCE_READERF_ERROR.0 as u32 != 0 {
            l.erro_no_meio = Some(format!("MF_SOURCE_READERF_ERROR no fluxo {idx}"));
            break;
        }
        if s.is_some() {
            vazios = 0;
            if e_video.get(idx as usize).copied().unwrap_or(false) {
                l.video += 1;
                l.ultimo_video_s = ts as f64 / 1e7;
            } else {
                l.audio += 1;
                l.ultimo_audio_s = ts as f64 / 1e7;
            }
        } else {
            vazios += 1;
        }
        if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 && !acabados.contains(&idx) {
            acabados.push(idx);
        }
        // Com `ANY_STREAM`, o fim de um fluxo não é o fim do outro.
        if acabados.len() >= selecionados || vazios > 1000 || l.video + l.audio > 1_000_000 {
            break;
        }
    }
    l
}

pub fn analisar(arquivo: &Path) -> Value {
    let bytes = std::fs::read(arquivo).unwrap_or_default();
    let cx = caixas::ler(&bytes);
    let comprimido = ler_com_leitor(arquivo, false);
    let decodificado = ler_com_leitor(arquivo, true);
    json!({ "caixas": cx, "leitor": comprimido, "leitor_decodificando": decodificado })
}

fn imprimir_analise(rotulo: &str, a: &Value) {
    let cx = &a["caixas"];
    let v = cx["tracks"].as_array().and_then(|t| t.iter().find(|x| x["tipo"] == "vide")).cloned().unwrap_or(Value::Null);
    let s = cx["tracks"].as_array().and_then(|t| t.iter().find(|x| x["tipo"] == "soun")).cloned().unwrap_or(Value::Null);
    println!(
        "     [{rotulo}] arquivo {} B; moov={} fragmentado={} moofs={} fragmentos completos={} cortado no fim={} B ({})",
        cx["bytes"], cx["tem_moov"], cx["fragmentado"], cx["moofs"], cx["fragmentos_completos"], cx["bytes_cortados"],
        cx["caixa_cortada"].as_str().unwrap_or("nada")
    );
    println!(
        "       caixas: vídeo {} amostras ({:.2} s), som {} amostras ({:.2} s)",
        v["amostras"], v["duracao_s"].as_f64().unwrap_or(0.0), s["amostras"], s["duracao_s"].as_f64().unwrap_or(0.0)
    );
    if let Some(fr) = v["fragmentos_s"].as_array() {
        let d: Vec<f64> = fr.iter().filter_map(|x| x.as_f64()).collect();
        if !d.is_empty() {
            let med = d.iter().sum::<f64>() / d.len() as f64;
            let max = d.iter().cloned().fold(0.0, f64::max);
            println!("       fragmentos de vídeo: {} de {:.2} s em média (maior {:.2} s)", d.len(), med, max);
        }
    }
    for k in ["leitor", "leitor_decodificando"] {
        let l = &a[k];
        println!(
            "       {k}: abriu={} vídeo={} (último {:.2} s) som={} (último {:.2} s){}{}",
            l["abriu"], l["video"], l["ultimo_video_s"].as_f64().unwrap_or(0.0), l["audio"],
            l["ultimo_audio_s"].as_f64().unwrap_or(0.0),
            l["erro_ao_abrir"].as_str().map(|e| format!(" ERRO AO ABRIR {e}")).unwrap_or_default(),
            l["erro_no_meio"].as_str().map(|e| format!(" erro no meio: {e}")).unwrap_or_default()
        );
    }
}

/// Uma linha de progresso do filho.
#[derive(Debug, Default, Clone, Copy, Serialize)]
pub struct Progresso {
    pub v: u64,
    pub rec: u64,
    pub cod: u64,
    pub proc_: u64,
    pub ms: u64,
}

fn ler_progresso(s: &str) -> Option<Progresso> {
    let mut p = Progresso::default();
    let mut rest = s.strip_prefix("P ")?.split_whitespace();
    for kv in &mut rest {
        let (k, v) = kv.split_once('=')?;
        let v: u64 = v.parse().ok()?;
        match k {
            "v" => p.v = v,
            "rec" => p.rec = v,
            "cod" => p.cod = v,
            "proc" => p.proc_ = v,
            "ms" => p.ms = v,
            _ => {}
        }
    }
    Some(p)
}

/// Roda o filho e, se `matar_em` vier, mata-o esse tanto de segundos depois do primeiro quadro.
fn correr_filho(
    exe: &Path,
    args: &[String],
    diario: &Path,
    matar_em: Option<f64>,
    teto: Duration,
) -> (Vec<String>, Option<Progresso>, bool, Option<i32>) {
    let err = std::fs::File::create(diario).ok();
    let mut c = Command::new(exe);
    c.args(args).stdout(Stdio::piped()).stdin(Stdio::null());
    match err {
        Some(f) => c.stderr(Stdio::from(f)),
        None => c.stderr(Stdio::null()),
    };
    let mut filho = match c.spawn() {
        Ok(f) => f,
        Err(e) => return (vec![format!("não subiu: {e}")], None, false, None),
    };
    let saida = filho.stdout.take().unwrap();
    let (tx, rx) = crossbeam_channel::unbounded::<String>();
    std::thread::spawn(move || {
        for l in BufReader::new(saida).lines() {
            match l {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    let mut info = Vec::new();
    let mut ultimo: Option<Progresso> = None;
    let mut primeiro: Option<Instant> = None;
    let comeco = Instant::now();
    let mut morto = false;
    loop {
        match rx.recv_timeout(Duration::from_millis(5)) {
            Ok(l) => {
                if let Some(p) = ler_progresso(&l) {
                    primeiro.get_or_insert_with(Instant::now);
                    ultimo = Some(p);
                } else {
                    info.push(l);
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
            Err(_) => {}
        }
        if let (Some(m), Some(p0)) = (matar_em, primeiro) {
            if !morto && p0.elapsed().as_secs_f64() >= m {
                // Esvazia o que já chegou antes do tiro: a última linha lida é o último quadro que
                // o filho confirmou antes de morrer (ele pode ter entregue mais um, sem imprimir).
                while let Ok(l) = rx.try_recv() {
                    if let Some(p) = ler_progresso(&l) {
                        ultimo = Some(p);
                    }
                }
                let _ = filho.kill(); // TerminateProcess
                morto = true;
            }
        }
        if comeco.elapsed() > teto && !morto {
            let _ = filho.kill();
            info.push("TETO: o filho passou do tempo e foi morto".into());
            morto = true;
        }
    }
    let codigo = filho.wait().ok().and_then(|s| s.code());
    (info, ultimo, morto, codigo)
}

pub fn prova(
    exe: &Path,
    pasta: &Path,
    luid: u64,
    rotulo_placa: &str,
    gpu: bool,
    s_controle: f64,
    s_morte: f64,
    base: &[String],
    fps: f64,
) -> Value {
    let _ = std::fs::create_dir_all(pasta);
    let sufixo = format!("{:016X}-{}", luid, if gpu { "gpu" } else { "mem" });
    let mut r = json!({ "placa": rotulo_placa, "luid": format!("{luid:016X}"), "origem": if gpu {"gpu"} else {"memoria"} });
    println!("\n== parte 2, fMP4, placa \"{rotulo_placa}\", origem {} ==", if gpu { "gpu" } else { "memória" });

    // 1. controle
    let arq_c = pasta.join(format!("controle-{sufixo}.mp4"));
    let mut args = vec!["gravar".to_string(), "--arquivo".into(), arq_c.display().to_string(), "--segundos".into(), s_controle.to_string()];
    args.extend_from_slice(base);
    let (info, ult, _, cod) = correr_filho(exe, &args, &pasta.join(format!("controle-{sufixo}.log")), None, Duration::from_secs_f64(s_controle + 60.0));
    for l in &info {
        println!("     controle: {l}");
    }
    let finalizou = info.iter().any(|l| l.starts_with("FIM"));
    let a = if arq_c.exists() { analisar(&arq_c) } else { Value::Null };
    if !a.is_null() {
        imprimir_analise("controle", &a);
    }
    r["controle"] = json!({ "info": info, "ultimo": ult, "finalizou": finalizou, "codigo": cod, "analise": a });
    if !finalizou {
        println!("     o controle não finalizou (código {cod:?}); a prova da morte não teria régua. Parando esta placa.");
        r["erro"] = json!("controle não finalizou");
        return r;
    }

    // 2. morte
    let arq_m = pasta.join(format!("morte-{sufixo}.mp4"));
    let mut args = vec!["gravar".to_string(), "--arquivo".into(), arq_m.display().to_string(), "--segundos".into(), (s_morte * 10.0).to_string()];
    args.extend_from_slice(base);
    let (info, ult, morto, cod) = correr_filho(exe, &args, &pasta.join(format!("morte-{sufixo}.log")), Some(s_morte), Duration::from_secs_f64(s_morte * 10.0 + 60.0));
    for l in &info {
        println!("     morte: {l}");
    }
    let u = ult.unwrap_or_default();
    println!(
        "     morto={morto} (código {cod:?}) no quadro {} (a {:.2} s de vídeo); o escritor tinha: recebido {}, codificado {}, processado pelo coletor {}",
        u.v, u.v as f64 / fps, u.rec, u.cod, u.proc_
    );
    std::thread::sleep(Duration::from_millis(300));
    let a = if arq_m.exists() { analisar(&arq_m) } else { Value::Null };
    if a.is_null() {
        println!("     o arquivo NÃO EXISTE depois da morte");
    } else {
        imprimir_analise("morte", &a);
    }
    let amostras_video = a["caixas"]["tracks"].as_array().and_then(|t| t.iter().find(|x| x["tipo"] == "vide")).and_then(|x| x["amostras"].as_u64()).unwrap_or(0);
    let perdidos = u.v.saturating_sub(amostras_video);
    println!(
        "     PERDA: {} quadro(s) entregues ao WriteSample não estão em fragmento completo = {:.2} s de vídeo",
        perdidos,
        perdidos as f64 / fps
    );
    r["morte"] = json!({
        "info": info, "ultimo": ult, "morto": morto, "codigo": cod, "analise": a,
        "quadros_entregues": u.v, "quadros_no_arquivo": amostras_video,
        "quadros_perdidos": perdidos, "segundos_perdidos": perdidos as f64 / fps,
    });
    r
}
