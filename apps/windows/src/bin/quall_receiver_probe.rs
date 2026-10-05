//! Sonda de bancada da Frente 6: decodifica H.264 em hardware e exibe numa janela.
//!
//! Dois modos:
//!
//! - `playback`: lê um `.h264`+`.json` de bancada (o par que `quall-capture-probe` produz, ou
//!   qualquer captura que passe em `tools/valida-sidecar.py`) e decodifica+exibe quadro a quadro.
//!   É o caminho principal desta entrega, porque a track de vídeo do núcleo
//!   (`ao_receber_quadro`/`pedir_idr`/`QuadroCodificado`, ver `docs/contrato-track.md`) ainda não
//!   existe neste snapshot do repositório — está sendo escrita pela Frente 1 em paralelo. Ver
//!   `connect.rs` para o porquê de não haver um framing de rede improvisado aqui.
//! - `connect`: prova a descoberta + pareamento + sessão WebRTC de verdade, usando
//!   `quall_core::session::conectar` (o mesmo caminho provado pelo `quall-probe` no M1) — sem
//!   vídeo nenhum trafegando, porque não há um emissor de vídeo real para casar do outro lado
//!   ainda. Existe para provar que o receptor consegue *achar e parear* com um emissor pelo
//!   núcleo, que é a metade do escopo desta frente que não depende da track.
//!
//! Ver `README.md`, seção "Frente 6", para os números medidos e os achados.

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use clap::{Parser, Subcommand};

use windows::Win32::Media::MediaFoundation::MF_E_NOTACCEPTING;

use quall_capture_probe::sidecar::Sidecar;
use quall_capture_probe::{decoder, device, encoder, present, regua};
#[cfg(feature = "net")]
use quall_capture_probe::connect;

#[cfg(feature = "net")]
use quall_core::pairing::{PairedPeers, Pin};
#[cfg(feature = "net")]
use quall_core::transport as core_transport;

#[derive(Parser, Debug)]
#[command(about = "Decodifica H.264 em hardware e exibe numa janela (Frente 6).")]
struct Args {
    #[command(subcommand)]
    modo: Modo,
}

#[derive(Subcommand, Debug)]
enum Modo {
    /// Decodifica e exibe um `.h264`+`.json` de bancada.
    Playback {
        /// Caminho do elementary stream Annex-B.
        #[arg(long)]
        h264: PathBuf,
        /// Caminho do sidecar `.json`. Padrão: mesmo nome do `.h264`, extensão trocada.
        #[arg(long)]
        sidecar: Option<PathBuf>,
        /// Repete o arquivo N vezes seguidas — útil para medir CPU/latência sob carga
        /// sustentada, já que uma captura de bancada dura só alguns segundos.
        #[arg(long, default_value_t = 1)]
        repeat: u32,
        /// Começa a alimentar o decoder a partir deste índice de quadro em vez do quadro 0,
        /// **sem** pular para o próximo IDR antes — simula um receptor entrando no meio da
        /// sessão (ou perdendo o IDR inicial). Mede o custo de não ter `pedir_idr()` ainda
        /// disponível: quantos quadros/ms até a imagem ficar limpa de novo. Ver README.md.
        #[arg(long)]
        mid_stream_from: Option<usize>,
        /// Escala da janela em relação à resolução do conteúdo (1.0 = tamanho nativo).
        #[arg(long, default_value_t = 1.0)]
        scale: f64,
        /// Grava as métricas medidas em JSON neste caminho.
        #[arg(long)]
        report: Option<PathBuf>,
        /// Fecha sozinho depois de decodificar tudo, em vez de esperar a janela ser fechada —
        /// necessário para rodar via Tarefa Agendada sem alguém clicando no X (ver
        /// `apps/windows/README.md`, armadilha de sessão interativa).
        #[arg(long)]
        auto_close: bool,
        /// Grava o backbuffer (o quadro que acabou de ir pro `Present`) em `.bmp` de tempos em
        /// tempos — prova visual do pixel de verdade, sem depender de captura de tela do Windows
        /// (que se mostrou não confiável nesta bancada em sessão via Tarefa Agendada; ver
        /// `present.rs::copy_texture_to_bmp`). Um `-primeiro.bmp` ao lado marca a primeira
        /// imagem apresentada.
        #[arg(long)]
        snapshot_out: Option<PathBuf>,
        /// Lê a **régua de blocos** de cada quadro decodificado e confere contra o índice que foi
        /// alimentado. Só faz sentido com uma fonte sintética (`gerar-fonte.swift`).
        ///
        /// Este é o modo que **prova o leitor**: aqui o índice do quadro é conhecido, então a
        /// pergunta é "o número lido é exatamente `indice % 256`?" — bem mais forte que "a
        /// sequência anda". É o que permite confiar no mesmo leitor depois, no app, quando a
        /// origem passa a ser a rede e ninguém sabe qual quadro deveria chegar.
        #[arg(long)]
        regua: bool,
    },
    /// Descobre/pareia com um emissor de verdade pelo núcleo. Não transporta vídeo (ver
    /// cabeçalho deste arquivo) — prova só a descoberta, o pareamento e a sessão WebRTC.
    /// Só existe com a feature `net` (default) — ver `Cargo.toml`.
    #[cfg(feature = "net")]
    Connect {
        /// Endereço do emissor (fallback obrigatório se mDNS não achar nada).
        #[arg(long)]
        ip: Option<String>,
        /// Procura o emissor por mDNS em vez de usar `--ip`.
        #[arg(long)]
        discover: bool,
        /// PIN mostrado na tela do emissor. Obrigatório no primeiro pareamento.
        #[arg(long)]
        pin: Option<String>,
        /// Por quanto tempo navegar (modo `--discover`) ou esperar dados depois de conectar.
        #[arg(long, default_value_t = 15)]
        segundos: u64,
        #[arg(long, default_value = "quall-receiver-probe")]
        device_id: String,
        #[arg(long, default_value = "Receptor Windows (sonda)")]
        display_name: String,
    },
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    quall_capture_probe::diagnostico_cli::concluir(rodar());
}

fn rodar() -> anyhow::Result<()> {
    let args = quall_capture_probe::diagnostico_cli::interpretar::<Args>();
    match args.modo {
        Modo::Playback { h264, sidecar, repeat, mid_stream_from, scale, report, auto_close, snapshot_out, regua } => {
            playback(h264, sidecar, repeat, mid_stream_from, scale, report, auto_close, snapshot_out, regua)
        }
        #[cfg(feature = "net")]
        Modo::Connect { ip, discover, pin, segundos, device_id, display_name } => {
            connect_mode(ip, discover, pin, segundos, device_id, display_name)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// playback
// ---------------------------------------------------------------------------------------------

fn playback(
    h264_path: PathBuf,
    sidecar_path: Option<PathBuf>,
    repeat: u32,
    mid_stream_from: Option<usize>,
    scale: f64,
    report_path: Option<PathBuf>,
    auto_close: bool,
    snapshot_out: Option<PathBuf>,
    com_regua: bool,
) -> anyhow::Result<()> {
    let sidecar_path = sidecar_path.unwrap_or_else(|| h264_path.with_extension("json"));
    let sidecar: Sidecar = serde_json::from_slice(&fs::read(&sidecar_path)?)?;
    let h264_bytes = fs::read(&h264_path)?;

    let soma_bytes: u64 = sidecar.frames.iter().map(|f| f.bytes as u64).sum();
    if soma_bytes != h264_bytes.len() as u64 {
        anyhow::bail!(
            "sidecar não bate com o .h264: soma de bytes = {soma_bytes}, arquivo tem {} bytes \
             (mesmo defeito que tools/valida-sidecar.py detectaria)",
            h264_bytes.len()
        );
    }
    if sidecar.frames.is_empty() {
        anyhow::bail!("sidecar sem quadros");
    }
    if !sidecar.frames[0].idr {
        anyhow::bail!("contrato violado: o primeiro quadro do sidecar não é IDR");
    }

    // Fatia o .h264 em quadros individuais usando os tamanhos do sidecar — é o mesmo dado que
    // prova a soma de bytes acima, então cortar por ele é seguro e não depende de reconhecer
    // start code Annex-B (o encoder já fez isso; o receptor não precisa refazer).
    let mut quadros: Vec<&[u8]> = Vec::with_capacity(sidecar.frames.len());
    let mut offset = 0usize;
    for f in &sidecar.frames {
        let fim = offset + f.bytes as usize;
        quadros.push(&h264_bytes[offset..fim]);
        offset = fim;
    }

    let start_index = mid_stream_from.unwrap_or(0);
    if start_index >= quadros.len() {
        anyhow::bail!("--mid-stream-from {start_index} está além do fim ({} quadros)", quadros.len());
    }
    let mut mid_stream_report: Option<MidStreamReport> = None;
    if let Some(idx) = mid_stream_from {
        let comeca_com_idr = sidecar.frames[idx].idr;
        eprintln!(
            "--mid-stream-from {idx}: primeiro quadro alimentado {} IDR",
            if comeca_com_idr { "É" } else { "NÃO é" }
        );
        if !comeca_com_idr {
            let prox_idr = sidecar.frames[idx..].iter().position(|f| f.idr).map(|rel| idx + rel);
            match prox_idr {
                Some(prox) => {
                    let frames_perdidos = prox - idx;
                    let tempo_perdido_us = sidecar.frames[prox].timestamp_us - sidecar.frames[idx].timestamp_us;
                    eprintln!(
                        "  sem pedir_idr(), o próximo IDR só está no quadro {prox} — \
                         {frames_perdidos} quadro(s) / {:.1} ms de tela potencialmente ruim/preta \
                         até lá, medido no próprio sidecar (não suposto).",
                        tempo_perdido_us as f64 / 1000.0
                    );
                    mid_stream_report = Some(MidStreamReport {
                        start_index: idx,
                        started_on_idr: false,
                        next_idr_index: Some(prox),
                        frames_until_idr: Some(frames_perdidos as u64),
                        time_until_idr_us: Some(tempo_perdido_us),
                    });
                }
                None => {
                    eprintln!("  não há NENHUM IDR depois do quadro {idx} nesta captura — pior caso ainda, sem pedir_idr() o receptor nunca se recupera sozinho.");
                    mid_stream_report = Some(MidStreamReport {
                        start_index: idx,
                        started_on_idr: false,
                        next_idr_index: None,
                        frames_until_idr: None,
                        time_until_idr_us: None,
                    });
                }
            }
        } else {
            mid_stream_report = Some(MidStreamReport {
                start_index: idx,
                started_on_idr: true,
                next_idr_index: Some(idx),
                frames_until_idr: Some(0),
                time_until_idr_us: Some(0),
            });
        }
    }

    unsafe {
        windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED).ok()?;
        windows::Win32::Media::MediaFoundation::MFStartup(
            windows::Win32::Media::MediaFoundation::MF_VERSION,
            windows::Win32::Media::MediaFoundation::MFSTARTUP_FULL,
        )?;
    }

    let resultado = run_playback(
        &sidecar,
        &quadros,
        start_index,
        repeat,
        scale,
        auto_close,
        mid_stream_report,
        report_path,
        snapshot_out,
        com_regua,
    );

    unsafe {
        let _ = windows::Win32::Media::MediaFoundation::MFShutdown();
        windows::Win32::System::Com::CoUninitialize();
    }

    resultado
}

#[derive(serde::Serialize)]
struct MidStreamReport {
    start_index: usize,
    started_on_idr: bool,
    next_idr_index: Option<usize>,
    frames_until_idr: Option<u64>,
    time_until_idr_us: Option<u64>,
}

#[derive(serde::Serialize)]
struct Report {
    decoder_friendly_name: String,
    decoder_is_async: bool,
    decoder_is_hardware: bool,
    adapter_description: String,
    adapter_vendor_id: u32,
    width: u32,
    height: u32,
    frames_submitted: u64,
    frames_decoded: u64,
    frames_presented: u64,
    time_to_first_frame_us: Option<u64>,
    decode_latency_us: LatSummary,
    total_latency_us: LatSummary,
    cpu_percent_of_one_core: f64,
    wall_seconds: f64,
    mid_stream: Option<MidStreamReport>,
    /// `None` quando `--regua` não foi pedida. Ver `regua.rs`.
    regua: Option<ReguaReport>,
}

/// A conferência da régua de blocos, quadro a quadro, contra o índice alimentado.
#[derive(serde::Serialize)]
struct ReguaReport {
    conferidas: u64,
    divergiram: u64,
    ilegiveis: u64,
    /// `(índice, esperado, lido)` da primeira divergência, se houve.
    primeira_divergencia: Option<(usize, u32, u32)>,
    /// A cópia caiu para o quadro inteiro? Ver `regua::Leitor`.
    caminho_largo: bool,
}

#[derive(serde::Serialize)]
struct LatSummary {
    mean: u64,
    p50: u64,
    p95: u64,
    max: u64,
}

fn latency_stats(values: &mut [u64]) -> LatSummary {
    if values.is_empty() {
        return LatSummary { mean: 0, p50: 0, p95: 0, max: 0 };
    }
    values.sort_unstable();
    let sum: u64 = values.iter().sum();
    LatSummary {
        mean: sum / values.len() as u64,
        p50: values[values.len() / 2],
        p95: values[(values.len() * 95 / 100).min(values.len() - 1)],
        max: *values.last().unwrap(),
    }
}

/// Insere `sufixo` antes da extensão: `foo.bmp` + `-primeiro` = `foo-primeiro.bmp`.
fn com_sufixo(base: &PathBuf, sufixo: &str) -> PathBuf {
    let stem = base.file_stem().and_then(|s| s.to_str()).unwrap_or("snapshot");
    let ext = base.extension().and_then(|s| s.to_str()).unwrap_or("bmp");
    base.with_file_name(format!("{stem}{sufixo}.{ext}"))
}

fn run_playback(
    sidecar: &Sidecar,
    quadros: &[&[u8]],
    start_index: usize,
    repeat: u32,
    scale: f64,
    auto_close: bool,
    mid_stream: Option<MidStreamReport>,
    report_path: Option<PathBuf>,
    snapshot_out: Option<PathBuf>,
    com_regua: bool,
) -> anyhow::Result<()> {
    let width = sidecar.header.width;
    let height = sidecar.header.height;
    let fps = sidecar.header.target_fps.max(1);

    eprintln!("=== adaptadores DXGI disponíveis ===");
    for a in device::list_adapters()? {
        eprintln!("  - {a}");
    }

    let chosen_decoder = decoder::find_and_activate_h264_decoder()?;
    eprintln!(
        "decoder ativado: \"{}\" (assíncrono: {}, MF_SA_D3D11_AWARE: {} — indício, não prova; ver README.md)",
        chosen_decoder.friendly_name, chosen_decoder.is_async, chosen_decoder.is_hardware
    );

    // Mesma lógica do encoder (main.rs): escolhe o adaptador *depois* de saber qual MFT ativou —
    // `MFT_MESSAGE_SET_D3D_MANAGER` exige o dispositivo D3D11 no mesmo adaptador do MFT (medido
    // no M1 para o encoder; ver decoder.rs/present.rs para a mesma restrição do lado do decode).
    let vendor_guess = if chosen_decoder.friendly_name.to_uppercase().contains("NVIDIA") {
        device::VENDOR_NVIDIA
    } else {
        device::VENDOR_INTEL
    };
    let chosen_adapter = device::create_device(vendor_guess)?;
    eprintln!(
        "adaptador escolhido para decode+apresentação: {} (vendor 0x{:04X})",
        chosen_adapter.description, chosen_adapter.vendor_id
    );

    let device_manager = encoder::create_device_manager(&chosen_adapter.device)?;
    decoder::configure(&chosen_decoder, &device_manager, &decoder::DecoderConfig { width, height, fps })?;
    decoder::start_stream(&chosen_decoder.transform)?;

    // Achado desta bancada (ver `decoder.rs`, doc de `ChosenDecoder`): o único MFT de decode
    // H.264 que o Dell expõe é **síncrono** (não implementa `IMFMediaEventGenerator`), diferente
    // do encoder (sempre assíncrono aqui). Sem fila de eventos, o laço abaixo não espera
    // `NeedInput`/`HaveOutput` — tenta `ProcessInput`/`drain_output` direto a cada volta.
    let events_rx = chosen_decoder
        .events
        .clone()
        .map(|events| encoder::spawn_event_pump(events));

    let output_width = ((width as f64) * scale).round() as u32;
    let output_height = ((height as f64) * scale).round() as u32;
    let window = present::Window::create("Quall — receptor (Frente 6)", output_width, output_height)?;
    let presenter = present::Presenter::new(
        &chosen_adapter.device,
        window.hwnd,
        width,
        height,
        output_width,
        output_height,
        fps,
        2,
    )?;

    // **A régua, e por que ela é provada aqui antes de valer no app.**
    // Neste modo o índice do quadro alimentado é conhecido, então a conferência é exata: o número
    // lido tem de ser `indice % 256`. Um leitor aprovado assim — no mesmo decoder, no mesmo
    // adaptador, no mesmo NV12 — é o que autoriza confiar nele quando a origem passar a ser a rede
    // e ninguém mais souber qual quadro deveria estar chegando.
    let mut leitor_de_regua = if com_regua {
        match regua::Leitor::novo(&chosen_adapter.device, width, height) {
            Ok(l) => {
                eprintln!("régua: ligada — conferindo cada quadro contra o índice alimentado");
                Some(l)
            }
            Err(e) => {
                eprintln!("régua: NÃO subiu ({e}) — seguindo sem ela");
                None
            }
        }
    } else {
        None
    };
    let mut regua_conferidas: u64 = 0;
    let mut regua_divergiu: u64 = 0;
    let mut regua_ilegivel: u64 = 0;
    let mut regua_primeira_divergencia: Option<(usize, u32, u32)> = None;

    let cpu_inicio = cpu_time_now();
    let wall_inicio = Instant::now();

    let mut need_input_credits: u32 = 0;
    // O índice **no carretel**, e não o número de ordem da submissão: é ele que diz qual número a
    // régua daquele quadro tem de carregar.
    let mut submitted: std::collections::VecDeque<(usize, Instant)> = std::collections::VecDeque::new();
    let mut frame_index_in_reel: usize = start_index;
    let mut voltas_restantes = repeat;
    let mut frames_submitted: u64 = 0;
    let mut frames_decoded: u64 = 0;
    let mut frames_presented: u64 = 0;
    let mut primeira_imagem_em: Option<Instant> = None;
    let mut decode_latencies: Vec<u64> = Vec::new();
    let mut total_latencies: Vec<u64> = Vec::new();
    let frame_duration_100ns = 10_000_000i64 / fps as i64;
    let mut proximo_seq: u64 = 0;

    // Ritmo real de captura, não "decodifica o mais rápido possível": alimenta cada quadro no
    // instante relativo que `timestamp_us` do sidecar registrou, não assim que houver crédito de
    // `NeedInput`. Sem isto a medição de CPU/latência descreveria um "quão rápido dá para
    // decodificar de uma vez", que não é o que um receptor de verdade faz — ele recebe quadro a
    // quadro no ritmo que o emissor captura. Em repetições (`--repeat`), cada volta soma a
    // duração da anterior ao alvo (`lap_offset_us`), para o ritmo continuar coerente em vez de
    // reiniciar a régua de tempo a cada volta.
    let duracao_total_us = sidecar
        .frames
        .last()
        .map(|f| f.timestamp_us.saturating_sub(sidecar.frames[0].timestamp_us))
        .unwrap_or(0)
        .max(1);
    let base_ts_us = sidecar.frames[start_index].timestamp_us;
    let mut lap_offset_us: u64 = 0;

    let mut ainda_ha_quadro = true;
    let mut janela_viva = true;
    let mut ultimo_diag = Instant::now();
    // Throttle de 500ms: gravar o backbuffer a cada quadro custaria uma cópia GPU→CPU por
    // quadro, poluindo justamente as latências que este programa está medindo. Uma vez a cada
    // meio segundo é o bastante pra prova visual sem interferir no número.
    let mut ultimo_snapshot = Instant::now() - Duration::from_secs(1);

    // Cão de guarda contra travamento sem progresso — achado medido nesta bancada com
    // `--mid-stream-from`: alimentar o decoder a partir de um quadro que não é IDR faz este MFT
    // (síncrono, ver decoder.rs) entrar num estado do qual às vezes **não sai sozinho**, mesmo
    // depois de um IDR de verdade (quadro 128) ter sido alimentado — `drain_output` para de
    // devolver quadro novo, `frames_decoded` para de crescer, e sem isto o laço giraria pra
    // sempre (só a Tarefa Agendada com teto externo de 60s salvou a primeira rodada de teste). É
    // exatamente o preço de não ter `pedir_idr()` de verdade: sem um encoder do outro lado pra
    // pedir um IDR novo, esta sonda não tem como se recuperar sozinha — só pode desistir de
    // forma limpa, e é isso que este relógio faz.
    let mut ultimo_progresso = Instant::now();
    let mut ultimo_frames_decoded_visto = 0u64;
    const TETO_SEM_PROGRESSO: Duration = Duration::from_secs(5);

    while janela_viva && (ainda_ha_quadro || !submitted.is_empty()) {
        if frames_decoded != ultimo_frames_decoded_visto {
            ultimo_frames_decoded_visto = frames_decoded;
            ultimo_progresso = Instant::now();
        } else if ultimo_progresso.elapsed() > TETO_SEM_PROGRESSO {
            eprintln!(
                "aviso: {} s sem decodificar quadro novo (decodificados={frames_decoded}, \
                 submetidos={frames_submitted}, restam no carretel={}) — desistindo em vez de \
                 travar. Sem pedir_idr() disponível, esta sonda não tem como pedir recuperação a \
                 um emissor de verdade; ver README.md.",
                TETO_SEM_PROGRESSO.as_secs(),
                quadros.len().saturating_sub(frame_index_in_reel)
            );
            break;
        }

        janela_viva = window.pump();
        if !janela_viva {
            eprintln!("janela fechada pelo usuário; encerrando.");
            break;
        }

        // Drenagem: no caminho assíncrono, só vale a pena tentar quando o evento `HaveOutput`
        // avisou. No síncrono não existe aviso nenhum — `drain_output` já é seguro de chamar a
        // qualquer momento (devolve vazio se não houver nada pronto, sem custo de mais que uma
        // chamada COM), então chama a cada volta do laço.
        let mut algo_pronto_para_drenar = !chosen_decoder.is_async;
        if let Some(rx) = &events_rx {
            match rx.recv_timeout(Duration::from_millis(5)) {
                Ok(encoder::MftEvent::NeedInput) => need_input_credits += 1,
                Ok(encoder::MftEvent::HaveOutput) => algo_pronto_para_drenar = true,
                _ => {}
            }
        } else {
            // Sem fila de eventos para dormir, uma pausa curta evita 100% de um núcleo num laço
            // que, de outra forma, ficaria só perguntando "chegou alguma coisa?" sem parar.
            std::thread::sleep(Duration::from_millis(2));
        }

        if algo_pronto_para_drenar {
            // **Um quadro por vez, consumido antes de pedir o próximo.** Ver
            // `decoder::DecodedFrame`: juntar um lote e olhar depois entrega quadros já
            // sobrescritos pela reciclagem de superfície do MFT — foi o que a régua achou aqui,
            // e é um defeito que existia desde o M2 sem nenhum contador acusá-lo.
            loop {
                match decoder::proximo_quadro(&chosen_decoder.transform, decoder::OUTPUT_STREAM_ID) {
                    Ok(None) => break,
                    Ok(Some(f)) => {
                        frames_decoded += 1;
                        let t_decoded = Instant::now();
                        let Some((indice, t_submit)) = submitted.pop_front() else {
                            eprintln!("aviso: quadro decodificado sem correspondência na fila de submissão");
                            continue;
                        };
                        decode_latencies.push((t_decoded - t_submit).as_micros() as u64);

                        // A régua **antes** de apresentar, e sobre a textura que saiu do decoder:
                        // é essa a afirmação que ela sustenta. Depois do Video Processor já houve
                        // conversão de cor e escala.
                        if let Some(l) = leitor_de_regua.as_mut() {
                            let esperado = (indice as u32) % regua::MODULO;
                            match l.ler(&f.texture, f.subresource_index) {
                                Ok(Some(lido)) => {
                                    regua_conferidas += 1;
                                    if lido != esperado {
                                        regua_divergiu += 1;
                                        if regua_primeira_divergencia.is_none() {
                                            regua_primeira_divergencia = Some((indice, esperado, lido));
                                            eprintln!(
                                                "régua: DIVERGÊNCIA no quadro {indice}: esperado {esperado}, lido {lido}"
                                            );
                                        }
                                    }
                                }
                                Ok(None) => regua_ilegivel += 1,
                                Err(e) => {
                                    eprintln!("régua: leitura falhou ({e}) — desligando");
                                    leitor_de_regua = None;
                                }
                            }
                        }

                        // A decisão de "salvar este quadro?" precisa vir *antes* de apresentar:
                        // `present_frame` lê o próprio backbuffer que acabou de escrever, na
                        // mesma chamada — é o que evita o defeito medido nesta bancada de ler o
                        // buffer errado numa chamada de `GetBuffer` separada e mais tarde (ver
                        // `present.rs`, doc de `copy_texture_to_bmp`).
                        let e_o_primeiro_quadro = primeira_imagem_em.is_none();
                        let snapshot_path: Option<PathBuf> = snapshot_out.as_ref().and_then(|base| {
                            if e_o_primeiro_quadro {
                                Some(com_sufixo(base, "-primeiro"))
                            } else if ultimo_snapshot.elapsed() >= Duration::from_millis(500) {
                                Some(base.clone())
                            } else {
                                None
                            }
                        });

                        let dest = present::aspect_fit(width, height, output_width, output_height);
                        // A sonda de receptor não troca de tamanho no meio (o `.h264` dela é de um
                        // tamanho só): a origem é a imagem inteira do SPS, como sempre foi.
                        let origem = windows::Win32::Foundation::RECT { left: 0, top: 0, right: width as i32, bottom: height as i32 };
                        if let Err(e) =
                            presenter.present_frame(&f.texture, f.subresource_index, origem, dest, snapshot_path.as_deref())
                        {
                            eprintln!("aviso: present_frame falhou: {e}");
                            continue;
                        }
                        if let Some(p) = &snapshot_path {
                            if !e_o_primeiro_quadro {
                                ultimo_snapshot = Instant::now();
                            }
                            eprintln!("  quadro salvo em {}", p.display());
                        }
                        let t_presented = Instant::now();
                        frames_presented += 1;
                        total_latencies.push((t_presented - t_submit).as_micros() as u64);
                        if e_o_primeiro_quadro {
                            primeira_imagem_em = Some(t_presented);
                            eprintln!(
                                "primeira imagem apresentada em {:.1} ms desde o início da decodificação",
                                (t_presented - wall_inicio).as_secs_f64() * 1000.0
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("aviso: ProcessOutput (decode) falhou: {e}");
                        break;
                    }
                }
            }
        }

        // `frame_index_in_reel` só é um índice válido em `sidecar.frames`/`quadros` enquanto
        // `ainda_ha_quadro` for `true` — depois do último quadro da última volta ele fica igual a
        // `quadros.len()` (e não é resetado, porque não há próxima volta). Checar
        // `ainda_ha_quadro` *antes* de indexar evita o `panic!` de índice fora do intervalo que
        // aconteceu aqui numa primeira rodada de teste na bancada.
        let na_hora = ainda_ha_quadro && {
            let alvo_us = {
                let referencia = if lap_offset_us == 0 { base_ts_us } else { sidecar.frames[0].timestamp_us };
                lap_offset_us + sidecar.frames[frame_index_in_reel].timestamp_us.saturating_sub(referencia)
            };
            wall_inicio.elapsed().as_micros() as u64 >= alvo_us
        };
        let pode_submeter = if chosen_decoder.is_async { need_input_credits > 0 } else { true };

        if pode_submeter && ainda_ha_quadro && na_hora {
            let bytes = quadros[frame_index_in_reel];
            let t_submit = Instant::now();
            let t = (proximo_seq as i64) * frame_duration_100ns;
            match decoder::sample_from_bytes(bytes, t, frame_duration_100ns) {
                Ok(sample) => match unsafe { chosen_decoder.transform.ProcessInput(0, &sample, 0) } {
                    Ok(()) => {
                        submitted.push_back((frame_index_in_reel, t_submit));
                        proximo_seq += 1;
                        frames_submitted += 1;
                        if chosen_decoder.is_async {
                            need_input_credits -= 1;
                        }

                        frame_index_in_reel += 1;
                        if frame_index_in_reel >= quadros.len() {
                            voltas_restantes = voltas_restantes.saturating_sub(1);
                            if voltas_restantes == 0 {
                                ainda_ha_quadro = false;
                            } else {
                                // Uma nova volta do arquivo, sem passar por `--mid-stream-from`
                                // de novo: a partir da segunda volta o quadro 0 é sempre IDR
                                // verdadeiro (é o contrato do sidecar), então isto não repete o
                                // teste de "entrar no meio" — só sustenta carga para medir CPU.
                                frame_index_in_reel = 0;
                                lap_offset_us += duracao_total_us;
                            }
                        }
                    }
                    // `MF_E_NOTACCEPTING`: normal no MFT síncrono — ele está pedindo para
                    // `ProcessOutput` ser chamado antes de aceitar mais entrada. Não é erro: a
                    // próxima volta do laço já drena (`algo_pronto_para_drenar` é sempre `true` no
                    // caminho síncrono) e tenta de novo, sem perder o quadro (não avança
                    // `frame_index_in_reel`).
                    Err(e) if !chosen_decoder.is_async && e.code() == MF_E_NOTACCEPTING => {}
                    Err(e) => eprintln!("aviso: ProcessInput recusou o quadro: {e}"),
                },
                Err(e) => eprintln!("aviso: falhou empacotar quadro como amostra: {e}"),
            }
        }

        if ultimo_diag.elapsed() >= Duration::from_secs(2) {
            eprintln!(
                "diag: submetidos={frames_submitted} decodificados={frames_decoded} apresentados={frames_presented} \
                 creditos={need_input_credits} restam_no_carretel={}",
                quadros.len().saturating_sub(frame_index_in_reel)
            );
            ultimo_diag = Instant::now();
        }
    }

    if janela_viva {
        eprintln!("carretel esgotado; drenando o que já entrou no decoder...");
        match decoder::end_stream_and_drain(&chosen_decoder.transform, events_rx.as_ref()) {
            Ok(frames) => {
                for f in frames {
                    frames_decoded += 1;
                    let t_decoded = Instant::now();
                    if let Some((_seq, t_submit)) = submitted.pop_front() {
                        decode_latencies.push((t_decoded - t_submit).as_micros() as u64);
                        let dest = present::aspect_fit(width, height, output_width, output_height);
                        // Sem *throttle* aqui de propósito: são no máximo os últimos 1-2 quadros
                        // que entraram no decoder antes do fim, então sobrescrever o mesmo
                        // arquivo a cada um deixa o `snap.bmp` no quadro mais recente possível —
                        // a melhor aproximação de "último quadro" que dá pra ter sem depender de
                        // a drenagem final devolver algo (medido nesta bancada: raramente
                        // devolve, porque o laço principal já drena tudo sozinho a cada volta).
                        let origem = windows::Win32::Foundation::RECT { left: 0, top: 0, right: width as i32, bottom: height as i32 };
                        if presenter
                            .present_frame(&f.texture, f.subresource_index, origem, dest, snapshot_out.as_deref())
                            .is_ok()
                        {
                            frames_presented += 1;
                            total_latencies.push((Instant::now() - t_submit).as_micros() as u64);
                        }
                    }
                }
            }
            Err(e) => eprintln!("aviso: drenagem final falhou: {e}"),
        }
    }

    let wall_segundos = wall_inicio.elapsed().as_secs_f64();
    let cpu_fim = cpu_time_now();
    let cpu_percent = if wall_segundos > 0.0 {
        ((cpu_fim - cpu_inicio) / wall_segundos) * 100.0
    } else {
        0.0
    };

    eprintln!();
    eprintln!("quadros submetidos: {frames_submitted}, decodificados: {frames_decoded}, apresentados: {frames_presented}");
    eprintln!("CPU: {cpu_percent:.1}% de um núcleo, em {wall_segundos:.2} s de parede");

    let report = Report {
        decoder_friendly_name: chosen_decoder.friendly_name.clone(),
        decoder_is_async: chosen_decoder.is_async,
        decoder_is_hardware: chosen_decoder.is_hardware,
        adapter_description: chosen_adapter.description.clone(),
        adapter_vendor_id: chosen_adapter.vendor_id,
        width,
        height,
        frames_submitted,
        frames_decoded,
        frames_presented,
        time_to_first_frame_us: primeira_imagem_em.map(|t| (t - wall_inicio).as_micros() as u64),
        decode_latency_us: latency_stats(&mut decode_latencies),
        total_latency_us: latency_stats(&mut total_latencies),
        cpu_percent_of_one_core: cpu_percent,
        wall_seconds: wall_segundos,
        mid_stream,
        regua: if com_regua {
            Some(ReguaReport {
                conferidas: regua_conferidas,
                divergiram: regua_divergiu,
                ilegiveis: regua_ilegivel,
                primeira_divergencia: regua_primeira_divergencia,
                caminho_largo: leitor_de_regua
                    .as_ref()
                    .map(|l| l.no_caminho_largo())
                    .unwrap_or(false),
            })
        } else {
            None
        },
    };
    if com_regua {
        eprintln!(
            "régua: {regua_conferidas} conferidas, {regua_divergiu} divergiram, \
             {regua_ilegivel} ilegíveis"
        );
        if regua_conferidas > 0 && regua_divergiu == 0 && regua_ilegivel == 0 {
            eprintln!(
                "régua: os pixels que saíram do decodificador são os que entraram no encoder, \
                 em {regua_conferidas} quadros — e isto é um contador, não uma imagem."
            );
        }
    }
    eprintln!(
        "latência decode (us): média={} p50={} p95={} máx={}",
        report.decode_latency_us.mean, report.decode_latency_us.p50, report.decode_latency_us.p95, report.decode_latency_us.max
    );
    eprintln!(
        "latência total, submissão→apresentado (us): média={} p50={} p95={} máx={}",
        report.total_latency_us.mean, report.total_latency_us.p50, report.total_latency_us.p95, report.total_latency_us.max
    );

    if let Some(path) = report_path {
        fs::write(&path, serde_json::to_string_pretty(&report)?)?;
        eprintln!("relatório gravado em {}", path.display());
    }

    if !auto_close {
        eprintln!("janela aberta; feche-a para encerrar.");
        while window.pump() {
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    Ok(())
}

/// Tempo de CPU do processo (kernel + usuário), em segundos — soma dos dois `FILETIME` de
/// `GetProcessTimes`. Método simples e no processo, ao contrário do `Get-Counter` externo que a
/// Frente 2 usou para o encoder (ver `README.md`, "O que eu tentei que não funcionou") — aqui
/// bastou isso, sem os problemas de amostragem que o PowerShell deu para GPU.
fn cpu_time_now() -> f64 {
    use windows::Win32::Foundation::FILETIME;
    use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessTimes};

    let mut criacao = FILETIME::default();
    let mut saida = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut usuario = FILETIME::default();
    unsafe {
        let _ = GetProcessTimes(GetCurrentProcess(), &mut criacao, &mut saida, &mut kernel, &mut usuario);
    }
    let filetime_to_100ns = |f: FILETIME| ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64;
    let total_100ns = filetime_to_100ns(kernel) + filetime_to_100ns(usuario);
    total_100ns as f64 / 10_000_000.0
}

// ---------------------------------------------------------------------------------------------
// connect
// ---------------------------------------------------------------------------------------------

#[cfg(feature = "net")]
fn connect_mode(
    ip: Option<String>,
    discover: bool,
    pin: Option<String>,
    segundos: u64,
    device_id: String,
    display_name: String,
) -> anyhow::Result<()> {
    let alvo = match (ip, discover) {
        (Some(ip), _) => connect::Alvo::Ip(ip),
        (None, true) => connect::Alvo::Descobrir { timeout: Duration::from_secs(segundos) },
        (None, false) => anyhow::bail!("diga --ip <endereço> ou --discover"),
    };
    let pin = pin.map(|p| Pin::parse(&p)).transpose().map_err(anyhow::Error::new)?;

    eprintln!("conectando como receptor pelo núcleo (quall_core::session::conectar)...");
    let pronto = connect::conectar_como_receptor(alvo, &device_id, &display_name, pin, PairedPeers::new())
        .map_err(anyhow::Error::new)?;

    eprintln!("conectado.");
    eprintln!("  par conectado (nome e identidade omitidos)");
    if let Some((local, remoto)) = pronto.session.selected_pair() {
        eprintln!("  candidato: {} -> {}", quall_capture_probe::higiene_do_registro::candidato(&local), quall_capture_probe::higiene_do_registro::candidato(&remoto));
    }
    eprintln!(
        "  pareamento: {}",
        if pronto.outcome.novo { "novo, por PIN" } else { "retomado, sem PIN" }
    );
    eprintln!();
    eprintln!(
        "sem track de vídeo ainda (ver connect.rs) — só provando que descoberta+pareamento+sessão \
         funcionam de verdade a partir deste código. Esperando dados brutos do canal por {segundos}s..."
    );

    let fim = Instant::now() + Duration::from_secs(segundos);
    let mut recebidos: u64 = 0;
    while Instant::now() < fim {
        if let Some(dados) = pronto.session.next_data(Duration::from_millis(200)) {
            recebidos += 1;
            if recebidos <= 5 {
                eprintln!("  quadro bruto recebido: {} bytes", dados.len());
            }
        }
    }
    eprintln!("total de mensagens recebidas pelo canal de dados: {recebidos}");
    eprintln!("quadros descartados por fila cheia: {}", pronto.session.dropped_frames());

    drop(pronto);
    core_transport::cleanup();
    Ok(())
}
