//! **Parte 1: dois codificadores H.264 de hardware ao mesmo tempo, na mesma placa.**
//!
//! O R5 (`docs/teleprompter-com-camera.md` §5.1) quer um segundo codificador, na melhor qualidade,
//! para a gravação local, vivo junto do da rede. O §5.1 escreve a hipótese: *"o NVENC de placa de
//! consumo tem teto de sessões simultâneas"*. Esta parte mede, por placa:
//!
//! - **gravação**: 1920x1080 a 30 fps, taxa alta;
//! - **rede**: 1280x720 a 30 fps, a taxa de sempre;
//!
//! primeiro cada um sozinho (a linha de base), depois os dois juntos, cada um na sua thread, no
//! ritmo do relógio (um quadro a cada 1/30 s, sem esperar o encoder). Quadro que chega na hora e
//! não acha crédito (`METransformNeedInput`) é **perdido na entrada**, como a `Cadeia` faz; quadro
//! que entrou e não saiu até o fim da drenagem é **perdido no encoder**.
//!
//! Usa o encoder do produto (`encoder::ativar_h264_so_na_placa`, `configure`, o bombeador de
//! eventos) — os mesmos parâmetros de baixa latência e o perfil Baseline que a rede usa. A gravação
//! no produto provavelmente pediria High; o perfil não é o que se mede aqui.

use std::collections::HashMap;
use std::mem::ManuallyDrop;
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

use quall_capture_probe::device::{self, PlacaDeHardware};
use quall_capture_probe::encoder::{self, ChosenEncoder, EncoderConfig, FormatoDeEntrada, MftEvent};
use serde::Serialize;
use windows::core::Result;
use windows::Win32::Graphics::Direct3D11::ID3D11Device;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

use crate::comum::{hr, percentil_ms, Enviavel, Origem};

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Perfil {
    pub rotulo: &'static str,
    pub largura: u32,
    pub altura: u32,
    pub fps: u32,
    pub bitrate: u32,
    pub gop: u32,
}

#[derive(Debug, Default, Serialize, Clone)]
pub struct Medida {
    pub rotulo: String,
    pub mft: String,
    pub hardware: bool,
    pub largura: u32,
    pub altura: u32,
    pub fps_pedido: u32,
    pub bitrate_pedido: u32,
    pub segundos: f64,
    /// Instantes de relógio em que um quadro era devido.
    pub devidos: u64,
    pub entrada: u64,
    pub saida: u64,
    /// Devidos que não acharam crédito do MFT na hora (a `Cadeia` descartaria).
    pub perdidos_na_entrada: u64,
    /// Entraram e não saíram até o fim da drenagem.
    pub perdidos_no_encoder: u64,
    /// Devidos em que a própria thread chegou mais de um período atrasada (ruído do agendador,
    /// não do encoder).
    pub atrasos_do_relogio: u64,
    /// Saídas na janela da medida / duração da janela.
    pub fps_saida: f64,
    /// O pior segundo inteiro da janela (quadros saídos naquele segundo).
    pub pior_segundo: u64,
    pub latencia_p50_ms: f64,
    pub latencia_p95_ms: f64,
    pub latencia_p99_ms: f64,
    pub latencia_max_ms: f64,
    pub idrs: u64,
    pub mbps: f64,
    pub erro: Option<String>,
}

/// Um encoder montado, pronto para ir para a thread.
struct Montado {
    enc: ChosenEncoder,
    eventos: crossbeam_channel::Receiver<MftEvent>,
}

fn montar(placa: &PlacaDeHardware, gerenciador: &IMFDXGIDeviceManager, p: &Perfil) -> Result<Montado> {
    let enc = preparar(placa, gerenciador, p)?;
    let eventos = encoder::spawn_event_pump(enc.events.clone());
    Ok(Montado { enc, eventos })
}

/// Ativa, configura e dá a largada no encoder do produto para este perfil, sem bombeador de eventos
/// (os controles usam um bombeador próprio, que carimba a chegada de cada evento).
pub(crate) fn preparar(placa: &PlacaDeHardware, gerenciador: &IMFDXGIDeviceManager, p: &Perfil) -> Result<ChosenEncoder> {
    let enc = encoder::ativar_h264_so_na_placa(placa.luid)?;
    let cfg = EncoderConfig {
        entrada: FormatoDeEntrada::Argb32,
        width: p.largura,
        height: p.altura,
        fps: p.fps,
        bitrate_bps: p.bitrate,
        gop_frames: p.gop,
        intra_refresh_frames: 0,
        slice_bytes: 0,
        teto_de_quadro_bits: 0,
    };
    if let Err(e) = encoder::configure(&enc, gerenciador, &cfg) {
        encoder::desligar(&enc);
        return Err(e);
    }
    let _ = encoder::tentar_espacamento_de_idr(&enc, p.gop);
    if let Err(e) = encoder::start_stream(&enc.transform) {
        encoder::desligar(&enc);
        return Err(e);
    }
    Ok(enc)
}

/// Uma saída colhida: o carimbo da amostra (para casar com a entrada), bytes, e se é ponto limpo.
pub(crate) struct Colhida {
    pub(crate) t: i64,
    pub(crate) bytes: u64,
    pub(crate) limpo: bool,
    pub(crate) quando: Instant,
}

/// A drenagem de `encoder::drain_output`, mas guardando o **carimbo** da amostra de saída — é ele
/// que casa a saída com a entrada e dá a latência por quadro. Os mesmos três casos especiais do
/// Quick Sync (ver o original).
pub(crate) fn colher(t: &IMFTransform) -> Vec<Colhida> {
    let mut out = Vec::new();
    loop {
        let Ok(info) = (unsafe { t.GetOutputStreamInfo(0) }) else { break };
        let proprias = (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32) != 0;
        let mut buf = MFT_OUTPUT_DATA_BUFFER {
            dwStreamID: 0,
            pSample: ManuallyDrop::new(None),
            dwStatus: 0,
            pEvents: ManuallyDrop::new(None),
        };
        if !proprias {
            let Ok(b) = (unsafe { MFCreateMemoryBuffer(info.cbSize) }) else { break };
            let Ok(s) = (unsafe { MFCreateSample() }) else { break };
            if unsafe { s.AddBuffer(&b) }.is_err() {
                break;
            }
            buf.pSample = ManuallyDrop::new(Some(s));
        }
        let mut status = 0u32;
        let r = unsafe { t.ProcessOutput(0, std::slice::from_mut(&mut buf), &mut status) };
        let amostra = ManuallyDrop::into_inner(std::mem::replace(&mut buf.pSample, ManuallyDrop::new(None)));
        let _ = ManuallyDrop::into_inner(std::mem::replace(&mut buf.pEvents, ManuallyDrop::new(None)));
        match r {
            Ok(()) => {
                if let Some(s) = amostra {
                    let quando = Instant::now();
                    let tt = unsafe { s.GetSampleTime() }.unwrap_or(-1);
                    let bytes = unsafe { s.GetTotalLength() }.unwrap_or(0) as u64;
                    let limpo = unsafe { s.GetUINT32(&MFSampleExtension_CleanPoint) }.unwrap_or(0) == 1;
                    out.push(Colhida { t: tt, bytes, limpo, quando });
                }
            }
            Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => break,
            Err(e) if e.code() == windows::Win32::Foundation::E_UNEXPECTED => break,
            Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => unsafe {
                match t.GetOutputAvailableType(0, 0) {
                    Ok(n) => {
                        if t.SetOutputType(0, &n, 0).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            },
            Err(_) => break,
        }
    }
    out
}

#[derive(Default)]
struct Estado {
    creditos: u32,
    envio: HashMap<i64, Instant>,
    latencias: Vec<u64>,
    saidas: Vec<Instant>,
    bytes: u64,
    idrs: u64,
    saida: u64,
}

fn tratar(ev: MftEvent, t: &IMFTransform, e: &mut Estado) {
    match ev {
        MftEvent::NeedInput => e.creditos += 1,
        MftEvent::HaveOutput => {
            for c in colher(t) {
                if let Some(t0) = e.envio.remove(&c.t) {
                    e.latencias.push(c.quando.duration_since(t0).as_micros() as u64);
                }
                e.saidas.push(c.quando);
                e.bytes += c.bytes;
                if c.limpo {
                    e.idrs += 1;
                }
                e.saida += 1;
            }
        }
        _ => {}
    }
}

/// A thread de um encoder: o relógio manda, o encoder acompanha ou perde.
fn correr(
    m: Enviavel<Montado>,
    dispositivo: Enviavel<ID3D11Device>,
    p: Perfil,
    segundos: f64,
    largada: Arc<Barrier>,
) -> Medida {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let m = m.0;
    let mut med = Medida {
        rotulo: p.rotulo.to_string(),
        mft: m.enc.friendly_name.clone(),
        hardware: m.enc.is_hardware,
        largura: p.largura,
        altura: p.altura,
        fps_pedido: p.fps,
        bitrate_pedido: p.bitrate,
        segundos,
        ..Default::default()
    };
    let mut origem = match Origem::nova(&dispositivo.0, p.largura, p.altura, 8) {
        Ok(o) => o,
        Err(e) => {
            med.erro = Some(format!("origem: {}", hr(&e)));
            largada.wait();
            return med;
        }
    };
    let dur_100ns = 10_000_000i64 / p.fps as i64;
    let periodo = Duration::from_nanos(1_000_000_000 / p.fps as u64);
    let mut e = Estado::default();

    largada.wait();
    let inicio = Instant::now();
    let fim = inicio + Duration::from_secs_f64(segundos);
    let mut n: u64 = 0;
    loop {
        let alvo = inicio + periodo * n as u32;
        if alvo >= fim {
            break;
        }
        // Espera o instante do quadro atendendo os eventos que chegarem.
        loop {
            let agora = Instant::now();
            if agora >= alvo {
                break;
            }
            match m.eventos.recv_timeout(alvo - agora) {
                Ok(ev) => tratar(ev, &m.enc.transform, &mut e),
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => break,
                Err(_) => break,
            }
        }
        while let Ok(ev) = m.eventos.try_recv() {
            tratar(ev, &m.enc.transform, &mut e);
        }
        med.devidos += 1;
        if Instant::now() > alvo + periodo {
            med.atrasos_do_relogio += 1;
        }
        if e.creditos == 0 {
            med.perdidos_na_entrada += 1;
        } else {
            let tex = origem.proxima();
            let t = n as i64 * dur_100ns;
            match encoder::sample_from_texture(&tex, 0, t, dur_100ns) {
                Ok(a) => {
                    e.envio.insert(t, Instant::now());
                    match unsafe { m.enc.transform.ProcessInput(0, &a, 0) } {
                        Ok(()) => {
                            e.creditos -= 1;
                            med.entrada += 1;
                        }
                        Err(x) => {
                            e.envio.remove(&t);
                            med.perdidos_na_entrada += 1;
                            if med.erro.is_none() {
                                med.erro = Some(format!("ProcessInput: {}", hr(&x)));
                            }
                        }
                    }
                }
                Err(x) => {
                    med.perdidos_na_entrada += 1;
                    if med.erro.is_none() {
                        med.erro = Some(format!("amostra: {}", hr(&x)));
                    }
                }
            }
        }
        n += 1;
    }
    // Drenagem: meio segundo para o que ainda está lá dentro sair.
    let prazo = Instant::now() + Duration::from_millis(500);
    while Instant::now() < prazo {
        if let Ok(ev) = m.eventos.recv_timeout(Duration::from_millis(20)) {
            tratar(ev, &m.enc.transform, &mut e);
        }
    }
    med.saida = e.saida;
    med.idrs = e.idrs;
    let (latencias, saidas, bytes) = (e.latencias, e.saidas, e.bytes);
    med.perdidos_no_encoder = med.entrada.saturating_sub(med.saida);
    let na_janela: Vec<&Instant> = saidas.iter().filter(|q| **q <= fim).collect();
    med.fps_saida = na_janela.len() as f64 / segundos;
    let inteiros = segundos.floor() as u64;
    let mut pior = u64::MAX;
    for s in 1..inteiros {
        // O primeiro segundo fica fora: é o do IDR e o da subida do encoder.
        let a = inicio + Duration::from_secs(s);
        let b = a + Duration::from_secs(1);
        let c = saidas.iter().filter(|q| **q >= a && **q < b).count() as u64;
        pior = pior.min(c);
    }
    med.pior_segundo = if pior == u64::MAX { 0 } else { pior };
    med.latencia_p50_ms = percentil_ms(&latencias, 0.50);
    med.latencia_p95_ms = percentil_ms(&latencias, 0.95);
    med.latencia_p99_ms = percentil_ms(&latencias, 0.99);
    med.latencia_max_ms = percentil_ms(&latencias, 1.0);
    med.mbps = bytes as f64 * 8.0 / segundos / 1e6;
    encoder::desligar(&m.enc);
    med
}

#[derive(Debug, Default, Serialize)]
pub struct Fase {
    pub nome: String,
    pub medidas: Vec<Medida>,
    pub erro: Option<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct DaPlaca {
    pub placa: String,
    pub vendor_id: String,
    pub luid: String,
    pub fases: Vec<Fase>,
    pub erro: Option<String>,
}

fn fase(
    nome: &str,
    placa: &PlacaDeHardware,
    dispositivo: &ID3D11Device,
    gerenciador: &IMFDXGIDeviceManager,
    perfis: &[Perfil],
    segundos: f64,
) -> Fase {
    println!("\n  -- {nome}: {} por {segundos:.0} s --", perfis.iter().map(|p| p.rotulo).collect::<Vec<_>>().join(" + "));
    let mut f = Fase { nome: nome.to_string(), ..Default::default() };
    // Montar **todos** antes de alimentar qualquer um: é a ordem do produto (a rede já está no ar
    // quando a gravação liga), e é onde um teto de sessões apareceria — na ativação ou no configure
    // do segundo.
    let mut montados = Vec::new();
    for p in perfis {
        match montar(placa, gerenciador, p) {
            Ok(m) => {
                println!("     {} montado: \"{}\" hardware={}", p.rotulo, m.enc.friendly_name, m.enc.is_hardware);
                montados.push((m, *p));
            }
            Err(e) => {
                let msg = if montados.is_empty() {
                    format!("montar {} SOZINHO, nenhum outro vivo: {}", p.rotulo, hr(&e))
                } else {
                    format!("montar {} com {} já vivo(s): {}", p.rotulo, montados.len(), hr(&e))
                };
                println!("     FALHOU: {msg}");
                f.erro = Some(msg);
                for (m, _) in &montados {
                    encoder::desligar(&m.enc);
                }
                return f;
            }
        }
    }
    let largada = Arc::new(Barrier::new(montados.len()));
    let mut fios = Vec::new();
    for (m, p) in montados {
        let l = largada.clone();
        let env = Enviavel(m);
        let d = Enviavel(dispositivo.clone());
        fios.push(std::thread::spawn(move || correr(env, d, p, segundos, l)));
    }
    for fio in fios {
        match fio.join() {
            Ok(m) => {
                println!(
                    "     {:<9} {}x{}: fps de saída {:.2} (pior segundo {}), entrada {}/{} devidos, perdidos na entrada {}, no encoder {}, \
                     latência p50 {:.1} p95 {:.1} p99 {:.1} máx {:.1} ms, IDRs {}, {:.1} Mb/s{}",
                    m.rotulo, m.largura, m.altura, m.fps_saida, m.pior_segundo, m.entrada, m.devidos,
                    m.perdidos_na_entrada, m.perdidos_no_encoder, m.latencia_p50_ms, m.latencia_p95_ms,
                    m.latencia_p99_ms, m.latencia_max_ms, m.idrs, m.mbps,
                    m.erro.as_ref().map(|e| format!(" [erro: {e}]")).unwrap_or_default()
                );
                if m.atrasos_do_relogio > 0 {
                    println!("               (a thread chegou atrasada ao relógio {} vez(es))", m.atrasos_do_relogio);
                }
                f.medidas.push(m);
            }
            Err(_) => f.erro = Some("uma thread de encoder entrou em pânico".into()),
        }
    }
    // Um respiro para os bombeadores saírem antes da fase seguinte.
    std::thread::sleep(Duration::from_millis(300));
    f
}

pub fn medir_placa(placa: &PlacaDeHardware, gravacao: Perfil, rede: Perfil, s_sozinho: f64, s_juntos: f64) -> DaPlaca {
    let mut r = DaPlaca {
        placa: placa.descricao.clone(),
        vendor_id: format!("0x{:04X}", placa.vendor_id),
        luid: format!("{:016X}", placa.luid),
        ..Default::default()
    };
    println!("\n== parte 1, placa \"{}\" ({}, LUID {}) ==", r.placa, r.vendor_id, r.luid);
    let adaptador = match device::create_device_por_luid(placa.luid) {
        Ok(a) => a,
        Err(e) => {
            r.erro = Some(format!("dispositivo: {}", hr(&e)));
            println!("  {}", r.erro.as_ref().unwrap());
            return r;
        }
    };
    // Duas threads pintam no mesmo contexto imediato: sem a proteção, é corrida no D3D11.
    let _ = device::proteger_contexto(&adaptador.context, true);
    let gerenciador = match encoder::create_device_manager(&adaptador.device) {
        Ok(g) => g,
        Err(e) => {
            r.erro = Some(format!("gerenciador DXGI: {}", hr(&e)));
            return r;
        }
    };
    if s_sozinho > 0.0 {
        r.fases.push(fase("gravação sozinha", placa, &adaptador.device, &gerenciador, &[gravacao], s_sozinho));
        r.fases.push(fase("rede sozinha", placa, &adaptador.device, &gerenciador, &[rede], s_sozinho));
    }
    r.fases.push(fase("juntos", placa, &adaptador.device, &gerenciador, &[gravacao, rede], s_juntos));
    r
}
