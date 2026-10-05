//! `quall-som-local` — **o tocador do receptor, sem rede** (S6 do `docs/som-no-receptor.md`).
//!
//! O tom de prova (as quatro notas da sonda, `crates/quall-probe/src/audio.rs`) é codificado aqui
//! mesmo — Opus pelo `quall-opus`, como o emissor do Windows, ou G.711 µ-law, como o do Mac —,
//! entregue à porta puxada do núcleo como a rede entregaria, um pacote a cada 20 ms, e tocado pelo
//! [`Tocador`] do app: o mesmo WASAPI compartilhado por evento, com `RATEADJUST`, que o receptor
//! usa. É a metade do receptor que não depende de outro aparelho nem de janela.
//!
//! # Para que serve
//!
//! - **Na Sessão 0** (o SSH do Dell): prova o que der. Se a saída monta, e senão com que motivo;
//!   que a thread do render entra no MMCSS; que a porta anda sem subconsumo. Sem janela e sem som.
//! - **Na sessão interativa**: a prova da saída **sem janela nenhuma** na tela da pessoa — o
//!   processo roda escondido, e o que se percebe é o tom saindo pela saída padrão.
//! - **`--ppm N`**: o "emissor" anda N ppm mais depressa que o relógio local (o intervalo entre
//!   pacotes encurta, o carimbo não muda). O que se confere é a razão que o núcleo sugere chegar ao
//!   `SetSampleRate` e o nível da porta ficar parado, sem descarte nem inserção — o `RATEADJUST`
//!   funcionando de ponta a ponta, sem um segundo cristal.
//!
//! # Mudo por padrão
//!
//! Sem `--volume`, o ganho é **zero**: o motor inteiro roda (decodificação, porta, WASAPI,
//! `RATEADJUST`) e o que chega ao DAC são zeros. O pico do sinal (antes do ganho) prova que a
//! decodificação anda; o pico na saída prova o mudo. Tocar alto é pedir `--volume` de propósito.
//!
//! # O que este binário nunca faz
//!
//! Não abre entrada de som nenhuma: nem microfone, nem loopback. A origem é o tom de prova e mais
//! nada. Não abre janela e não toca a rede.

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use clap::Parser;

use quall_capture_probe::registro;
use quall_capture_probe::som_puxado::{mulaw_de_i16, tom_de_prova, CANAIS, QUADROS_POR_SLOT, TAXA};
use quall_capture_probe::tocador::Tocador;
use quall_core::jitter::Politica;
use quall_core::media::Clock;
use quall_core::reproducao::{OpcoesDeReproducao, ReproducaoPuxada};
use quall_core::rtp::QuadroDeAudio;
use quall_core::track::CodecDeAudio;

#[derive(Parser, Debug)]
#[command(name = "quall-som-local", about = "O tocador do receptor, sem rede: tom de prova → porta puxada → WASAPI")]
struct Args {
    /// Quanto tempo tocar, em segundos.
    #[arg(long, default_value_t = 20)]
    segundos: u64,
    /// `opus` (o emissor do Windows) ou `pcmu` (o do Mac).
    #[arg(long, default_value = "opus")]
    codec: String,
    /// O ganho, de 0 a 1. **0 é o padrão**: o motor roda e o DAC recebe zeros.
    #[arg(long, default_value_t = 0.0, value_parser = volume_finito)]
    volume: f32,
    /// O relógio do "emissor" anda N ppm mais depressa que o local (±500 no máximo).
    #[arg(long, default_value_t = 0.0)]
    ppm: f64,
    /// O arquivo do diário. Sem ele, só o stderr.
    #[arg(long)]
    registro: Option<PathBuf>,
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    let a = quall_capture_probe::diagnostico_cli::interpretar::<Args>();
    if let Some(p) = registro::abrir(a.registro.as_deref()) {
        eprintln!("diário: {}", p.display());
    }
    let codec = match a.codec.to_ascii_lowercase().as_str() {
        "opus" => CodecDeAudio::Opus,
        "pcmu" => CodecDeAudio::Pcmu,
        outro => {
            eprintln!("--codec: opus ou pcmu, e não {outro}");
            std::process::exit(2);
        }
    };
    if !a.ppm.is_finite() || a.ppm.abs() > 500.0 {
        eprintln!("--ppm: entre -500 e 500");
        std::process::exit(2);
    }
    let volume = a.volume.clamp(0.0, 1.0);
    registro::linha(format!(
        "som-local: {codec:?} | volume {volume:.2}{} | ppm {:+.1} | {} s",
        if volume == 0.0 { " (mudo: o DAC recebe zeros)" } else { "" },
        a.ppm,
        a.segundos
    ));

    let relogio = Arc::new(Clock::new());
    let (alimentador, porta) = ReproducaoPuxada::nova(
        OpcoesDeReproducao { politica: Politica::AUDIO_DO_SISTEMA, casca_reamostra: true },
        Arc::clone(&relogio),
    );
    let canais = if codec == CodecDeAudio::Opus { 2 } else { 1 };
    let tocador = match Tocador::iniciar(porta, codec, canais, volume) {
        Ok(t) => t,
        Err(e) => {
            registro::linha(format!("som-local: !! o tocador não subiu: {e}"));
            std::process::exit(1);
        }
    };

    // O "emissor": um pacote a cada 20 ms / (1 + ppm), com o carimbo de mídia de sempre.
    let parar = Arc::new(AtomicBool::new(false));
    let emissor = {
        let parar = Arc::clone(&parar);
        let relogio = Arc::clone(&relogio);
        let ppm = a.ppm;
        std::thread::spawn(move || {
            let mut enc = if codec == CodecDeAudio::Opus {
                let mut e = quall_opus::Codificador::novo(TAXA, 2, quall_opus::Aplicacao::Audio).expect("codificador Opus");
                let _ = e.definir_taxa_de_bits(128_000);
                Some(e)
            } else {
                None
            };
            let periodo = Duration::from_secs_f64(0.020 / (1.0 + ppm * 1e-6));
            let comeco = Instant::now();
            let mut pacote = vec![0u8; 4_000];
            let mut pcm = vec![0i16; QUADROS_POR_SLOT * CANAIS];
            let mut i: u64 = 0;
            while !parar.load(Ordering::Relaxed) {
                let alvo = comeco + periodo.mul_f64(i as f64);
                let agora = Instant::now();
                if alvo > agora {
                    std::thread::sleep(alvo - agora);
                }
                let n = match enc.as_mut() {
                    Some(e) => {
                        for q in 0..QUADROS_POR_SLOT {
                            let v = (tom_de_prova(i * QUADROS_POR_SLOT as u64 + q as u64, TAXA) * 32767.0) as i16;
                            pcm[q * 2] = v;
                            pcm[q * 2 + 1] = v;
                        }
                        e.codificar(&pcm, &mut pacote).unwrap_or(0)
                    }
                    None => {
                        for (q, b) in pacote.iter_mut().take(160).enumerate() {
                            *b = mulaw_de_i16((tom_de_prova(i * 160 + q as u64, 8_000) * 32767.0) as i16);
                        }
                        160
                    }
                };
                if n > 0 {
                    alimentador.entregar(
                        &QuadroDeAudio {
                            payload: &pacote[..n],
                            timestamp_us: i * 20_000,
                            sequencia: i as u16,
                            marca: true,
                        },
                        relogio.micros(),
                    );
                }
                i += 1;
            }
            i
        })
    };

    let inicio = Instant::now();
    let fim = inicio + Duration::from_secs(a.segundos);
    let mut proximo = inicio + Duration::from_secs(1);
    while Instant::now() < fim {
        // A razão do núcleo vai ao render a cada 100 ms, daqui, fora do render — como o laço da
        // sessão do receptor faz.
        while Instant::now() < proximo {
            std::thread::sleep(Duration::from_millis(100).min(proximo.saturating_duration_since(Instant::now())));
            tocador.atualizar_razao();
        }
        proximo += Duration::from_secs(1);
        let s = tocador.situacao();
        let (pico_do_sinal, pico) = tocador.tirar_picos();
        let c = tocador.contadores_da_porta();
        let r = s.retrato;
        let db = |p: f32| if p > 0.0 { 20.0 * f64::from(p).log10() } else { f64::NEG_INFINITY };
        registro::linha(format!(
            "som-local t={:.0}s ligado={} rateadjust={} mixador={} Hz latencia={:.1}ms buffer={} razao={:.6} \
             renders={} render=[{}..{}] puxadas={} ociosas={} silencios={} pico_do_sinal={:.1}dBFS \
             pico_na_saida={:.1}dBFS porta=[quadros={} nivel={} k={} subconsumos={} descartes_deriva={} \
             insercoes_deriva={} insercoes_atraso={} razao_sugerida={:?} deriva_ppm={:?}] \
             religamentos={} tentativas_falhas={} falhas_de_decodificar={} ultima_falha=\"{}\"",
            inicio.elapsed().as_secs_f64(),
            if s.ligado { "sim" } else { "NAO" },
            if s.com_rateadjust { "sim" } else { "nao" },
            s.taxa_do_mixador,
            s.latencia_ms,
            s.buffer_quadros,
            s.razao_aplicada,
            r.renders,
            if r.menor_render == usize::MAX { 0 } else { r.menor_render },
            r.maior_render,
            r.puxadas,
            r.ociosas,
            r.silencios,
            db(pico_do_sinal),
            db(pico),
            c.quadros,
            c.nivel,
            c.profundidade_efetiva,
            c.subconsumos,
            c.descartes_por_deriva,
            c.insercoes_por_deriva,
            c.insercoes_por_atraso,
            c.razao_sugerida,
            c.deriva_ed_ppm,
            s.religamentos,
            s.tentativas_falhas,
            tocador.falhas_de_decodificar(),
            s.ultima_falha,
        ));
    }
    parar.store(true, Ordering::Relaxed);
    let enviados = emissor.join().unwrap_or(0);
    let s = tocador.situacao();
    let c = tocador.contadores_da_porta();
    let barreira = tocador.parar();
    registro::linha(format!(
        "som-local fim: pacotes={enviados} quadros_tocados={} subconsumos={} descartes_deriva={} insercoes_deriva={} \
         razao_final={:.6} razao_sugerida={:?} religamentos={} tentativas_falhas={} barreira={barreira:?}",
        c.quadros,
        c.subconsumos,
        c.descartes_por_deriva,
        c.insercoes_por_deriva,
        s.razao_aplicada,
        c.razao_sugerida,
        s.religamentos,
        s.tentativas_falhas,
    ));
}

/// `--volume`: um número finito de 0 a 1. NaN passaria pelo `clamp` e iria ao WASAPI.
fn volume_finito(texto: &str) -> Result<f32, String> {
    match texto.parse::<f32>() {
        Ok(v) if v.is_finite() && (0.0..=1.0).contains(&v) => Ok(v),
        _ => Err(format!("um número de 0 a 1, e não {texto}")),
    }
}
