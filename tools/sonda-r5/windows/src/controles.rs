//! **Controles da parte 1: separar a fonte do encoder, e o relógio dos dois.**
//!
//! Na sessão interativa do Pessoa Exemplo (24/09, pelo `roda-interativa.ps1`) a parte 1 deu, na UHD 630,
//! gravação sozinha a 27,8 fps (22/301 perdidos **na entrada**, 0 no encoder) e rede sozinha a
//! 24,0 fps (60/301 na entrada), com a latência cravada em ~16 ms; pela Sessão 0 do SSH, os mesmos
//! deram 30,00 fps sem perda. As perdas estão na entrada (o crédito do MFT não voltou a tempo), não
//! no encoder. Estes controles dizem **onde o tempo vai**, com a mesma origem sintética:
//!
//! - **(c) o relógio**: a resolução do temporizador do sistema (`NtQueryTimerResolution`,
//!   `timeGetDevCaps`), quanto um `Sleep(1)` e um `recv_timeout(1 ms)` dormem de fato, com e sem
//!   `timeBeginPeriod(1)`, se a janela do console está visível, e o estado do *power throttling*
//!   do processo. O ritmo de 30 fps usa `Instant` (QPC) e espera com `recv_timeout` do canal de
//!   eventos, como a parte 1.
//! - **(a) só a fonte, sem encoder**: no mesmo ritmo, quanto a thread acorda atrasada, quanto custa
//!   pintar (`ClearRenderTargetView`), quanto a GPU leva até terminar a pintura (consulta de evento
//!   D3D11 + `Flush`), e quanto custa embrulhar a amostra. Quantos quadros ficam prontos no prazo.
//! - **(b) fonte + encoder, instrumentado**, em três variantes:
//!   - `relógio`: igual à parte 1 (sem crédito na hora, perde);
//!   - `espera-crédito`: sem crédito na hora, espera até um período pelo `METransformNeedInput`
//!     antes de perder (quantos entram atrasados, e com quanto atraso);
//!   - `gpu-sincronizada`: pinta, espera a GPU terminar, e só então `ProcessInput`.
//!   Em cada uma: o tempo do `ProcessInput`, quanto o crédito leva para voltar depois dele (medido
//!   **no bombeador**, na chegada do evento, e não quando a thread o vê), a latência de saída no
//!   bombeador e na thread, e, para cada quadro perdido, quanto depois do instante devido o crédito
//!   chegou.
//!
//! Tudo roda duas vezes: **como veio** (o processo como o Windows o classifica; `timeBeginPeriod(1)`
//! já pedido pelo `main`) e com o **throttling desligado** (`SetProcessInformation` com
//! `PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION` e
//! `StateMask = 0`, o que o produto faz para a velocidade em `apps/windows/src/main.rs`). Se a
//! diferença entre as sessões for o Windows tratando a sonda como processo de fundo, ela some no
//! segundo regime.

use std::time::{Duration, Instant};

use quall_capture_probe::device::{self, PlacaDeHardware};
use quall_capture_probe::encoder::{self, ChosenEncoder};
use serde_json::{json, Value};
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11DeviceContext, ID3D11Query, D3D11_QUERY_DESC, D3D11_QUERY_EVENT};
use windows::Win32::Media::MediaFoundation::*;

use crate::comum::{hr, percentil_ms, Origem};
use crate::dois::{colher, preparar, Perfil};

// ---------------------------------------------------------------------------------------------
// (c) o relógio e o regime do processo

#[link(name = "ntdll")]
extern "system" {
    /// Em unidades de 100 ns: `maxima` é a mais grossa (tipicamente 156250 = 15,625 ms), `minima`
    /// a mais fina, `atual` a que o sistema está usando agora (a menor pedida por alguém).
    fn NtQueryTimerResolution(maxima: *mut u32, minima: *mut u32, atual: *mut u32) -> i32;
}

/// Liga ou devolve ao sistema o *power throttling* do processo nas duas dimensões que importam:
/// velocidade de execução (EcoQoS) e resolução do temporizador (no Windows 11, o pedido de
/// `timeBeginPeriod` de um processo sem janela visível pode ser ignorado).
pub fn desligar_throttling() -> bool {
    use windows::Win32::System::Threading::{
        GetCurrentProcess, ProcessPowerThrottling, SetProcessInformation, PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
        PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION, PROCESS_POWER_THROTTLING_STATE,
    };
    let estado = PROCESS_POWER_THROTTLING_STATE {
        Version: 1,
        ControlMask: PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
        StateMask: 0,
    };
    unsafe {
        SetProcessInformation(
            GetCurrentProcess(),
            ProcessPowerThrottling,
            &estado as *const _ as *const std::ffi::c_void,
            std::mem::size_of::<PROCESS_POWER_THROTTLING_STATE>() as u32,
        )
        .is_ok()
    }
}

fn estado_throttling() -> Value {
    use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessInformation, ProcessPowerThrottling, PROCESS_POWER_THROTTLING_STATE};
    let mut e = PROCESS_POWER_THROTTLING_STATE { Version: 1, ControlMask: 0, StateMask: 0 };
    let r = unsafe {
        GetProcessInformation(
            GetCurrentProcess(),
            ProcessPowerThrottling,
            &mut e as *mut _ as *mut std::ffi::c_void,
            std::mem::size_of::<PROCESS_POWER_THROTTLING_STATE>() as u32,
        )
    };
    match r {
        Ok(()) => json!({ "control_mask": e.ControlMask, "state_mask": e.StateMask }),
        Err(x) => json!({ "erro": hr(&x) }),
    }
}

fn resolucao_do_sistema() -> Value {
    let (mut ma, mut mi, mut at) = (0u32, 0u32, 0u32);
    let st = unsafe { NtQueryTimerResolution(&mut ma, &mut mi, &mut at) };
    json!({ "status": st, "mais_grossa_ms": ma as f64 / 1e4, "mais_fina_ms": mi as f64 / 1e4, "atual_ms": at as f64 / 1e4 })
}

fn console_visivel() -> Option<bool> {
    use windows::Win32::System::Console::GetConsoleWindow;
    use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;
    let h = unsafe { GetConsoleWindow() };
    if h.0.is_null() {
        return None;
    }
    Some(unsafe { IsWindowVisible(h) }.as_bool())
}

fn resumo_us(v: &[u64]) -> Value {
    json!({
        "n": v.len(),
        "p50_ms": percentil_ms(v, 0.50),
        "p95_ms": percentil_ms(v, 0.95),
        "p99_ms": percentil_ms(v, 0.99),
        "max_ms": percentil_ms(v, 1.0),
    })
}

fn txt(v: &Value) -> String {
    if v["n"].as_u64().unwrap_or(0) == 0 {
        return "—".into();
    }
    format!(
        "p50 {:.2} p95 {:.2} máx {:.2}",
        v["p50_ms"].as_f64().unwrap_or(0.0),
        v["p95_ms"].as_f64().unwrap_or(0.0),
        v["max_ms"].as_f64().unwrap_or(0.0)
    )
}

fn medir_sono(vezes: usize, f: impl Fn()) -> Vec<u64> {
    (0..vezes)
        .map(|_| {
            let t = Instant::now();
            f();
            t.elapsed().as_micros() as u64
        })
        .collect()
}

/// (c): o que o relógio deste processo faz agora.
fn relogio() -> Value {
    use windows::Win32::Media::{timeBeginPeriod, timeEndPeriod, timeGetDevCaps, TIMECAPS};
    let mut caps = TIMECAPS::default();
    unsafe { timeGetDevCaps(&mut caps, std::mem::size_of::<TIMECAPS>() as u32) };
    let (tx, rx) = crossbeam_channel::bounded::<()>(1);
    let um_ms = Duration::from_millis(1);
    let res_com = resolucao_do_sistema();
    let sleep_com = medir_sono(100, || std::thread::sleep(um_ms));
    let recv_com = medir_sono(100, || {
        let _ = rx.recv_timeout(um_ms);
    });
    unsafe { timeEndPeriod(1) };
    let res_sem = resolucao_do_sistema();
    let sleep_sem = medir_sono(60, || std::thread::sleep(um_ms));
    unsafe { timeBeginPeriod(1) };
    drop(tx);
    let v = json!({
        "timecaps_min_ms": caps.wPeriodMin,
        "timecaps_max_ms": caps.wPeriodMax,
        "console_visivel": console_visivel(),
        "throttling": estado_throttling(),
        "com_timeBeginPeriod1": { "resolucao": res_com, "sleep_1ms": resumo_us(&sleep_com), "recv_timeout_1ms": resumo_us(&recv_com) },
        "sem_timeBeginPeriod": { "resolucao": res_sem, "sleep_1ms": resumo_us(&sleep_sem) },
        "relogio_do_ritmo": "Instant (QueryPerformanceCounter); espera por crossbeam recv_timeout até o instante devido",
    });
    println!(
        "  (c) relógio: console visível {:?}; throttling {}; timeGetDevCaps {}..{} ms",
        v["console_visivel"], v["throttling"], caps.wPeriodMin, caps.wPeriodMax
    );
    println!(
        "      com timeBeginPeriod(1): resolução atual {:.3} ms; Sleep(1) {}; recv_timeout(1) {}",
        res_com["atual_ms"].as_f64().unwrap_or(-1.0),
        txt(&v["com_timeBeginPeriod1"]["sleep_1ms"]),
        txt(&v["com_timeBeginPeriod1"]["recv_timeout_1ms"])
    );
    println!(
        "      sem timeBeginPeriod:    resolução atual {:.3} ms; Sleep(1) {}",
        res_sem["atual_ms"].as_f64().unwrap_or(-1.0),
        txt(&v["sem_timeBeginPeriod"]["sleep_1ms"])
    );
    v
}

// ---------------------------------------------------------------------------------------------
// A GPU: uma consulta de evento para saber quando a pintura terminou.

struct Cerca {
    ctx: ID3D11DeviceContext,
    q: ID3D11Query,
}

impl Cerca {
    fn nova(d: &ID3D11Device) -> windows::core::Result<Self> {
        let desc = D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 };
        let mut q: Option<ID3D11Query> = None;
        unsafe { d.CreateQuery(&desc, Some(&mut q))? };
        Ok(Cerca { ctx: unsafe { d.GetImmediateContext()? }, q: q.expect("consulta") })
    }

    /// `End` + `Flush` e gira até a GPU dizer que terminou. `GetData` devolve `S_FALSE` (que o
    /// windows-rs trata como `Ok`) enquanto não terminou; o sinal é o BOOL escrito.
    fn esperar(&self) {
        unsafe {
            self.ctx.End(&self.q);
            self.ctx.Flush();
            let prazo = Instant::now() + Duration::from_millis(500);
            loop {
                let mut feito: i32 = 0;
                let _ = self.ctx.GetData(&self.q, Some(&mut feito as *mut i32 as *mut std::ffi::c_void), 4, 0);
                if feito != 0 || Instant::now() > prazo {
                    break;
                }
                std::hint::spin_loop();
            }
        }
    }
}

/// Espera até `alvo` do jeito da parte 1: `recv_timeout` num canal (aqui, um que nunca recebe).
fn esperar_ate(rx: &crossbeam_channel::Receiver<()>, alvo: Instant) {
    loop {
        let agora = Instant::now();
        if agora >= alvo {
            return;
        }
        let _ = rx.recv_timeout(alvo - agora);
    }
}

fn us(d: Duration) -> u64 {
    d.as_micros() as u64
}

// ---------------------------------------------------------------------------------------------
// (a) só a fonte

fn so_fonte(dispositivo: &ID3D11Device, p: &Perfil, segundos: f64) -> Value {
    let mut origem = match Origem::nova(dispositivo, p.largura, p.altura, 8) {
        Ok(o) => o,
        Err(e) => return json!({ "erro": format!("origem: {}", hr(&e)) }),
    };
    let cerca = match Cerca::nova(dispositivo) {
        Ok(c) => c,
        Err(e) => return json!({ "erro": format!("consulta: {}", hr(&e)) }),
    };
    let (_tx, rx) = crossbeam_channel::bounded::<()>(1);
    let periodo = Duration::from_nanos(1_000_000_000 / p.fps as u64);
    let dur = 10_000_000i64 / p.fps as i64;
    let (mut despertar, mut pintura, mut gpu, mut amostra, mut total) = (vec![], vec![], vec![], vec![], vec![]);
    let (mut devidos, mut no_prazo) = (0u64, 0u64);
    let inicio = Instant::now();
    let fim = inicio + Duration::from_secs_f64(segundos);
    let mut n = 0u32;
    loop {
        let alvo = inicio + periodo * n;
        if alvo >= fim {
            break;
        }
        esperar_ate(&rx, alvo);
        let t0 = Instant::now();
        let tex = origem.proxima();
        let t1 = Instant::now();
        cerca.esperar();
        let t2 = Instant::now();
        let a = encoder::sample_from_texture(&tex, 0, n as i64 * dur, dur);
        let t3 = Instant::now();
        drop(a);
        devidos += 1;
        if t3 < alvo + periodo {
            no_prazo += 1;
        }
        despertar.push(us(t0 - alvo));
        pintura.push(us(t1 - t0));
        gpu.push(us(t2 - t1));
        amostra.push(us(t3 - t2));
        total.push(us(t3 - alvo));
        n += 1;
    }
    let v = json!({
        "perfil": p.rotulo, "largura": p.largura, "altura": p.altura, "segundos": segundos,
        "devidos": devidos, "prontos_no_prazo": no_prazo,
        "fps_pronto": no_prazo as f64 / segundos,
        "despertar_atrasado": resumo_us(&despertar),
        "pintura_cpu": resumo_us(&pintura),
        "gpu_ate_terminar": resumo_us(&gpu),
        "amostra": resumo_us(&amostra),
        "do_instante_devido_ao_pronto": resumo_us(&total),
    });
    println!(
        "    (a) só fonte {:<9} {}x{}: prontos no prazo {}/{} ({:.2} fps)",
        p.rotulo, p.largura, p.altura, no_prazo, devidos, v["fps_pronto"].as_f64().unwrap_or(0.0)
    );
    println!("          despertar atrasado  {}", txt(&v["despertar_atrasado"]));
    println!("          pintura (CPU)       {}", txt(&v["pintura_cpu"]));
    println!("          GPU até terminar    {}", txt(&v["gpu_ate_terminar"]));
    println!("          amostra             {}", txt(&v["amostra"]));
    println!("          devido → pronto     {}", txt(&v["do_instante_devido_ao_pronto"]));
    v
}

// ---------------------------------------------------------------------------------------------
// (b) fonte + encoder, instrumentado

#[derive(Clone, Copy, PartialEq)]
enum Variante {
    Relogio,
    EsperaCredito,
    GpuSincronizada,
}

impl Variante {
    fn nome(self) -> &'static str {
        match self {
            Variante::Relogio => "relógio",
            Variante::EsperaCredito => "espera-crédito",
            Variante::GpuSincronizada => "gpu-sincronizada",
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Ev {
    Precisa,
    Saida,
    Outro,
}

/// O bombeador do produto (`encoder::spawn_event_pump`), mas carimbando a **chegada** de cada
/// evento: é o instante em que o MFT o publicou, não o instante em que a thread do encoder o viu.
fn bombeador(ger: IMFMediaEventGenerator) -> crossbeam_channel::Receiver<(Ev, Instant)> {
    let g = crate::comum::Enviavel(ger);
    let (tx, rx) = crossbeam_channel::unbounded();
    std::thread::spawn(move || {
        let g = g;
        unsafe {
            let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
        }
        loop {
            let Ok(ev) = (unsafe { g.0.GetEvent(MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS(0)) }) else { break };
            let quando = Instant::now();
            let Ok(tipo) = (unsafe { ev.GetType() }) else { continue };
            let e = if tipo == METransformNeedInput.0 as u32 {
                Ev::Precisa
            } else if tipo == METransformHaveOutput.0 as u32 {
                Ev::Saida
            } else {
                Ev::Outro
            };
            if tx.send((e, quando)).is_err() {
                break;
            }
        }
    });
    rx
}

#[derive(Default)]
struct Registro {
    creditos: u32,
    envio: std::collections::HashMap<i64, Instant>,
    /// Chegadas de `METransformNeedInput` no bombeador.
    precisa: Vec<Instant>,
    lat_thread: Vec<u64>,
    lat_bombeador: Vec<u64>,
    /// Da chegada do HaveOutput no bombeador até a thread colher.
    atraso_da_thread: Vec<u64>,
    colher: Vec<u64>,
    saidas: Vec<Instant>,
}

fn tratar(ev: (Ev, Instant), t: &IMFTransform, r: &mut Registro) {
    match ev.0 {
        Ev::Precisa => {
            r.creditos += 1;
            r.precisa.push(ev.1);
        }
        Ev::Saida => {
            let c0 = Instant::now();
            let cs = colher(t);
            r.colher.push(us(c0.elapsed()));
            r.atraso_da_thread.push(us(c0.saturating_duration_since(ev.1)));
            for (i, c) in cs.into_iter().enumerate() {
                if let Some(t0) = r.envio.remove(&c.t) {
                    r.lat_thread.push(us(c.quando.saturating_duration_since(t0)));
                    if i == 0 {
                        r.lat_bombeador.push(us(ev.1.saturating_duration_since(t0)));
                    }
                }
                r.saidas.push(c.quando);
            }
        }
        Ev::Outro => {}
    }
}

/// O primeiro instante de `v` (ordenado) estritamente depois de `t`.
fn primeiro_depois(v: &[Instant], t: Instant) -> Option<Instant> {
    let i = v.partition_point(|x| *x <= t);
    v.get(i).copied()
}

fn com_encoder(
    placa: &PlacaDeHardware,
    dispositivo: &ID3D11Device,
    gerenciador: &IMFDXGIDeviceManager,
    p: &Perfil,
    var: Variante,
    segundos: f64,
) -> Value {
    let enc: ChosenEncoder = match preparar(placa, gerenciador, p) {
        Ok(e) => e,
        Err(e) => {
            let v = json!({ "perfil": p.rotulo, "variante": var.nome(), "erro": format!("montar: {}", hr(&e)) });
            println!("    (b) {:<16} {:<9}: FALHOU {}", var.nome(), p.rotulo, v["erro"].as_str().unwrap_or(""));
            return v;
        }
    };
    let eventos = bombeador(enc.events.clone());
    let mut origem = match Origem::nova(dispositivo, p.largura, p.altura, 8) {
        Ok(o) => o,
        Err(e) => {
            encoder::desligar(&enc);
            return json!({ "erro": format!("origem: {}", hr(&e)) });
        }
    };
    let cerca = Cerca::nova(dispositivo).ok();
    let periodo = Duration::from_nanos(1_000_000_000 / p.fps as u64);
    let dur = 10_000_000i64 / p.fps as i64;
    let mut r = Registro::default();
    let (mut despertar, mut pintura, mut sinc, mut amostra, mut process_input) = (vec![], vec![], vec![], vec![], vec![]);
    let mut entradas: Vec<Instant> = Vec::new();
    let mut perdidos_em: Vec<Instant> = Vec::new();
    let mut atraso_do_credito_esperado: Vec<u64> = Vec::new();
    let (mut devidos, mut entrada, mut perdidos, mut atrasados) = (0u64, 0u64, 0u64, 0u64);
    let mut erro: Option<String> = None;

    let inicio = Instant::now();
    let fim = inicio + Duration::from_secs_f64(segundos);
    let mut n = 0u32;
    loop {
        let alvo = inicio + periodo * n;
        if alvo >= fim {
            break;
        }
        loop {
            let agora = Instant::now();
            if agora >= alvo {
                break;
            }
            match eventos.recv_timeout(alvo - agora) {
                Ok(ev) => tratar(ev, &enc.transform, &mut r),
                Err(_) => break,
            }
        }
        while let Ok(ev) = eventos.try_recv() {
            tratar(ev, &enc.transform, &mut r);
        }
        let acordou = Instant::now();
        despertar.push(us(acordou.saturating_duration_since(alvo)));
        devidos += 1;
        if r.creditos == 0 && var == Variante::EsperaCredito {
            // Espera o crédito até o fim do período deste quadro.
            let limite = alvo + periodo;
            while r.creditos == 0 {
                let agora = Instant::now();
                if agora >= limite {
                    break;
                }
                match eventos.recv_timeout(limite - agora) {
                    Ok(ev) => tratar(ev, &enc.transform, &mut r),
                    Err(_) => break,
                }
            }
            if r.creditos > 0 {
                atrasados += 1;
                atraso_do_credito_esperado.push(us(Instant::now().saturating_duration_since(alvo)));
            }
        }
        if r.creditos == 0 {
            perdidos += 1;
            perdidos_em.push(alvo);
            n += 1;
            continue;
        }
        let t0 = Instant::now();
        let tex = origem.proxima();
        let t1 = Instant::now();
        pintura.push(us(t1 - t0));
        if var == Variante::GpuSincronizada {
            if let Some(c) = &cerca {
                c.esperar();
            }
            sinc.push(us(t1.elapsed()));
        }
        let t2 = Instant::now();
        let ts = n as i64 * dur;
        match encoder::sample_from_texture(&tex, 0, ts, dur) {
            Ok(a) => {
                let t3 = Instant::now();
                amostra.push(us(t3 - t2));
                r.envio.insert(ts, t3);
                let pi = unsafe { enc.transform.ProcessInput(0, &a, 0) };
                let t4 = Instant::now();
                process_input.push(us(t4 - t3));
                match pi {
                    Ok(()) => {
                        r.creditos -= 1;
                        entrada += 1;
                        entradas.push(t4);
                    }
                    Err(x) => {
                        r.envio.remove(&ts);
                        perdidos += 1;
                        perdidos_em.push(alvo);
                        erro.get_or_insert(format!("ProcessInput: {}", hr(&x)));
                    }
                }
            }
            Err(x) => {
                perdidos += 1;
                perdidos_em.push(alvo);
                erro.get_or_insert(format!("amostra: {}", hr(&x)));
            }
        }
        n += 1;
    }
    let prazo = Instant::now() + Duration::from_millis(500);
    while Instant::now() < prazo {
        if let Ok(ev) = eventos.recv_timeout(Duration::from_millis(20)) {
            tratar(ev, &enc.transform, &mut r);
        }
    }
    encoder::desligar(&enc);

    // O crédito: da volta do ProcessInput até o próximo NeedInput no bombeador.
    let credito: Vec<u64> = entradas.iter().filter_map(|t| primeiro_depois(&r.precisa, *t).map(|c| us(c - *t))).collect();
    // Os perdidos: quanto depois do instante devido o crédito chegou no bombeador.
    let falta: Vec<u64> = perdidos_em.iter().filter_map(|t| primeiro_depois(&r.precisa, *t).map(|c| us(c - *t))).collect();
    let na_janela = r.saidas.iter().filter(|q| **q <= fim).count();
    let v = json!({
        "perfil": p.rotulo, "largura": p.largura, "altura": p.altura, "variante": var.nome(), "mft": enc.friendly_name,
        "segundos": segundos, "devidos": devidos, "entrada": entrada, "saida": r.saidas.len(),
        "perdidos_na_entrada": perdidos, "entraram_atrasados": atrasados,
        "perdidos_no_encoder": entrada.saturating_sub(r.saidas.len() as u64),
        "fps_saida": na_janela as f64 / segundos,
        "despertar_atrasado": resumo_us(&despertar),
        "pintura_cpu": resumo_us(&pintura),
        "gpu_ate_terminar": resumo_us(&sinc),
        "amostra": resumo_us(&amostra),
        "process_input": resumo_us(&process_input),
        "credito_depois_do_process_input": resumo_us(&credito),
        "perdido_credito_chegou_depois_do_devido": resumo_us(&falta),
        "atraso_dos_que_esperaram_credito": resumo_us(&atraso_do_credito_esperado),
        "latencia_no_bombeador": resumo_us(&r.lat_bombeador),
        "latencia_na_thread": resumo_us(&r.lat_thread),
        "bombeador_ate_a_thread_colher": resumo_us(&r.atraso_da_thread),
        "colher": resumo_us(&r.colher),
        "erro": erro,
    });
    println!(
        "    (b) {:<16} {:<9}: fps de saída {:.2}, entrada {}/{}, perdidos na entrada {}{}, no encoder {}",
        var.nome(),
        p.rotulo,
        v["fps_saida"].as_f64().unwrap_or(0.0),
        entrada,
        devidos,
        perdidos,
        if var == Variante::EsperaCredito { format!(" (entraram atrasados {atrasados})") } else { String::new() },
        v["perdidos_no_encoder"]
    );
    println!("          despertar atrasado        {}", txt(&v["despertar_atrasado"]));
    println!("          pintura (CPU)             {}", txt(&v["pintura_cpu"]));
    if var == Variante::GpuSincronizada {
        println!("          GPU até terminar          {}", txt(&v["gpu_ate_terminar"]));
    }
    println!("          ProcessInput              {}", txt(&v["process_input"]));
    println!("          crédito após ProcessInput {}", txt(&v["credito_depois_do_process_input"]));
    if perdidos > 0 {
        println!("          perdido: crédito chegou   {} depois do devido", txt(&v["perdido_credito_chegou_depois_do_devido"]));
    }
    if var == Variante::EsperaCredito && atrasados > 0 {
        println!("          atrasados entraram        {} depois do devido", txt(&v["atraso_dos_que_esperaram_credito"]));
    }
    println!("          latência no bombeador     {}", txt(&v["latencia_no_bombeador"]));
    println!("          latência na thread        {}", txt(&v["latencia_na_thread"]));
    println!("          bombeador → thread colhe  {}", txt(&v["bombeador_ate_a_thread_colher"]));
    if let Some(e) = v["erro"].as_str() {
        println!("          [erro: {e}]");
    }
    v
}

// ---------------------------------------------------------------------------------------------

fn uma_placa(placa: &PlacaDeHardware, perfis: &[Perfil], segundos: f64) -> Value {
    let luid = format!("{:016X}", placa.luid);
    println!("\n  -- placa \"{}\" (LUID {luid}) --", placa.descricao);
    let adaptador = match device::create_device_por_luid(placa.luid) {
        Ok(a) => a,
        Err(e) => return json!({ "placa": placa.descricao, "luid": luid, "erro": format!("dispositivo: {}", hr(&e)) }),
    };
    let _ = device::proteger_contexto(&adaptador.context, true);
    let gerenciador = match encoder::create_device_manager(&adaptador.device) {
        Ok(g) => g,
        Err(e) => return json!({ "placa": placa.descricao, "luid": luid, "erro": format!("gerenciador DXGI: {}", hr(&e)) }),
    };
    let fonte: Vec<Value> = perfis.iter().map(|p| so_fonte(&adaptador.device, p, segundos)).collect();
    let mut enc = Vec::new();
    for p in perfis {
        for var in [Variante::Relogio, Variante::EsperaCredito, Variante::GpuSincronizada] {
            let v = com_encoder(placa, &adaptador.device, &gerenciador, p, var, segundos);
            let falhou = v["erro"].as_str().is_some_and(|e| e.starts_with("montar"));
            enc.push(v);
            std::thread::sleep(Duration::from_millis(300));
            if falhou {
                break;
            }
        }
    }
    json!({ "placa": placa.descricao, "luid": luid, "so_fonte": fonte, "com_encoder": enc })
}

pub fn medir(placas: &[PlacaDeHardware], perfis: &[Perfil], segundos: f64, so_desligado: bool) -> Value {
    let mut regimes = Vec::new();
    let lista: &[(&str, bool)] = if so_desligado { &[("throttling desligado", true)] } else { &[("como veio", false), ("throttling desligado", true)] };
    for (nome, desligar) in lista {
        println!("\n== controles, regime: {nome} ==");
        let aceito = if *desligar { Some(desligar_throttling()) } else { None };
        if let Some(ok) = aceito {
            println!("  SetProcessInformation(EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION, StateMask 0): {}", if ok { "aceito" } else { "RECUSADO" });
        }
        let rel = relogio();
        let pl: Vec<Value> = placas.iter().map(|p| uma_placa(p, perfis, segundos)).collect();
        regimes.push(json!({ "regime": nome, "throttling_desligado_aceito": aceito, "relogio": rel, "placas": pl }));
    }
    json!(regimes)
}
