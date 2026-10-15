//! `quall-varias` — **instrumento de bancada**, não produto: a prova de mecanismo do emissor com
//! vários receptores.
//!
//! # O que ele roda
//!
//! O **mesmo** `Emissor` do app, com `--varias-sessoes` e a origem sintética — o coordenador, as
//! threads de sessão, a tabela, a `Cadeia` e o encoder de verdade —, sem a janela. Os receptores são
//! **processos filhos** (este mesmo `.exe`, subcomando `receptor`) contra `127.0.0.1`, cada um com
//! `device_id` próprio, pareamento vazio e a tela de um aparelho da bancada dita no aperto de mão.
//! Processo separado de propósito: a API C da libdatachannel tem um mutex global por processo
//! (`docs/divida-do-nucleo.md`), e o receptor no mesmo processo misturaria as travas dele com as do
//! emissor que se quer medir.
//!
//! # Por que não captura tela, e por que roda na Sessão 0
//!
//! A origem é nossa (`sintetica.rs`): nenhuma tela é capturada, e sem `Windows.Graphics.Capture` a
//! cadeia sobe na Sessão 0, direto pelo SSH, como a `quall-gemeos`. **Número de desempenho da
//! Sessão 0 não vale para o produto** (o NVENC ativa ali e falha na sessão interativa); mecanismo
//! vale. `--preferir-intel` põe o Quick Sync, o encoder do produto.
//!
//! # O que ele não faz
//!
//! Não grava nem abre quadro de tela de ninguém. Com `--salvar-h264` os receptores gravam o `.h264`
//! que chegou — a origem é sintética nossa, que é a exceção que `docs/regras-de-frente.md` escreve.
//! Não chama `cleanup` da libdatachannel: com uma thread de sessão ainda viva, apagaria ids dela.
//!
//! # Com monitores virtuais (`--monitores-virtuais`, `docs/monitor-virtual-windows.md` §14)
//!
//! Cada receptor ganha um monitor virtual do SudoVDA no formato da tela dele, e sobre cada monitor
//! uma **janela sintética nossa cobrindo-o inteiro** (`cobertura.rs`): a captura WGC só abre depois
//! de a janela cobrir o monitor, e só deixa passar quadro coberto. Sem ela, o monitor mostraria o
//! papel de parede e o que a pessoa arrastasse para lá. Roda **na sessão interativa** (a tarefa
//! agendada de `scripts/varias-monitores.ps1`), e com `--so-local` forçado: a sinalização e o ICE só
//! em `127.0.0.1`, sem mDNS — um `.exe` novo escutando fora do loopback faria o firewall do Dell
//! mostrar um aviso na tela do usuário. **Os receptores só contam**: `--salvar-h264` é recusado.
//!
//! # Uso
//!
//!     quall-varias orquestrar --receptores 4 --segundos 20 --registro C:\...\varias.log
//!     quall-varias orquestrar --receptores 8 --roteiro-completo --preferir-intel --registro ...
//!     quall-varias orquestrar --receptores 2 --monitores-virtuais --segundos 20 --registro ...
//!     quall-varias orquestrar --receptores 8 --monitores-virtuais --cobertura cor --segundos 30 --registro ...
//!     quall-varias orquestrar --receptores 8 --monitores-virtuais --cobertura cor --sem-captura ...  # o controle da captura

#![cfg(windows)]

use quall_capture_probe::diagnostico_eprintln as eprintln;
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::os::windows::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clap::{Args, Parser, Subcommand};
use quall_capture_probe::argumentos::Argumentos;
use quall_capture_probe::emissor::{Emissor, Estado, Fase};
use quall_capture_probe::{identidade, registro, sessoes, sps};
use quall_core::discovery::{anuncio, endereco_manual};
use quall_core::pairing::{PairedPeers, Pin};
use quall_core::protocol::{Capabilities, Screen};
use quall_core::session::{conectar, EventoDeSessao, SessionConfig};
use quall_core::track::{QuadroCodificado, TrackKind};
use quall_core::transport::TransportConfig;
use windows::Win32::Media::MediaFoundation::{MFShutdown, MFStartup, MFSTARTUP_FULL, MF_VERSION};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

#[derive(Parser)]
#[command(about = "Bancada: o emissor com várias sessões, contra receptores sem cabeça.")]
struct Cli {
    #[command(subcommand)]
    modo: Modo,
}

#[derive(Subcommand)]
enum Modo {
    /// O emissor com várias sessões e os receptores filhos.
    Orquestrar(Orquestrar),
    /// Um receptor sem cabeça: conecta, conta quadros e IDR, e imprime uma linha `RESUMO {json}`.
    Receptor(ArgsDoReceptor),
}

#[derive(Args)]
struct Orquestrar {
    #[arg(long, default_value_t = 2)]
    receptores: usize,
    /// Quanto tempo todos ficam no ar juntos, depois de o último entrar.
    #[arg(long, default_value_t = 20)]
    segundos: u64,
    #[arg(long, default_value = "cor")]
    carga: String,
    #[arg(long, default_value = "movendo")]
    ritmo: String,
    #[arg(long)]
    preferir_intel: bool,
    #[arg(long)]
    sem_troca_a_quente: bool,
    /// Depois do trecho parado: um sai sem `Bye` e volta com a mesma identidade, um PIN errado na
    /// espera aberta, um sai com `Bye`, e Parar no meio de um desmonte.
    #[arg(long)]
    roteiro_completo: bool,
    #[arg(long)]
    registro: PathBuf,
    /// A pasta de dados descartável (pares, device-id, índices). Padrão: `%TEMP%\quall-varias-<pid>`.
    #[arg(long)]
    pasta: Option<PathBuf>,
    /// Os receptores gravam o `.h264` que chegou nesta pasta (origem sintética nossa).
    #[arg(long)]
    salvar_h264: Option<PathBuf>,
    /// Os receptores pedem um IDR N segundos depois do primeiro quadro.
    #[arg(long)]
    pedir_idr_em: Option<u64>,
    /// O teto de quadro em quadros médios (o do Mac é 5; 0 desliga — o braço de controle).
    #[arg(long, default_value_t = 5.0)]
    teto_quadro_em_medios: f64,
    /// Um monitor virtual do SudoVDA por receptor, coberto pela janela sintética nossa (ver o
    /// cabeçalho). Força `--so-local`.
    #[arg(long)]
    monitores_virtuais: bool,
    /// O que a janela sintética desenha sobre cada monitor virtual: `camadas` (listras e barras que
    /// andam: a tela inteira muda a cada quadro, ~120 `ClearView`), `cor` (a tela inteira numa cor
    /// que muda a cada quadro, um `ClearView` — o conteúdo da origem sintética `cor` do controle) ou
    /// `parada`.
    #[arg(long, default_value = "camadas")]
    cobertura: String,
    /// Com `--monitores-virtuais`: os monitores nascem e as janelas desenham, mas a captura nunca
    /// abre (os receptores recebem a origem preta) — o controle do custo da captura.
    #[arg(long)]
    sem_captura: bool,
    /// A sinalização e o ICE só em 127.0.0.1, sem mDNS (emissor e receptores).
    #[arg(long)]
    so_local: bool,
    /// **A câmera sintética** (fase 3 de `docs/camera-no-windows.md`): toda sessão transmite a fonte
    /// do Quall instanciada neste processo, pela captura de câmera do produto (o leitor assíncrono,
    /// o anel, o carimbo, o encoder NV12), com um nome aleatório e portanto um cano que ninguém
    /// serve — o padrão de bancada, que é nosso. Não abre câmera de ninguém. Roda na Sessão 0.
    #[arg(long)]
    camera_sintetica: bool,
    /// **A câmera de bancada** (fase 4, §7.3 de `docs/camera-no-windows.md`): o link exato da câmera
    /// que a sonda criou (`quall_camera_local segurar --criar-camera … --regua`). Toda sessão a
    /// transmite pelo Frame Server; o emissor recebe `--camera-de-bancada <link> --fonte <link>`, e a trava do produto só a libera com a sonda viva. **Quem cria a câmera é a sonda,
    /// com o sim do usuário.**
    #[arg(long)]
    camera_link: Option<String>,
    /// Os receptores decodificam e leem a régua de cada quadro (`receptor --regua`): o pixel
    /// conferido com a câmera sintética ou a de bancada com a régua.
    #[arg(long)]
    regua: bool,
    /// **A troca da primeira sessão** (o R3b da revisão do código da fase 4, M1): N segundos depois
    /// de todos entrarem, o receptor 0 sai com `Bye` (a [#1], a controladora, sai), e um receptor
    /// novo entra pela espera aberta (a [#3]). Com a câmera: a [#2] compartilhada fica, e a vez da
    /// [#3] não tem controladora viva no processo.
    #[arg(long)]
    trocar_primeiro_aos: Option<u64>,
}

#[derive(Args, Clone)]
struct ArgsDoReceptor {
    #[arg(long)]
    ip: String,
    #[arg(long)]
    pin: String,
    #[arg(long)]
    id: String,
    #[arg(long)]
    nome: String,
    /// `LxA` em pixels — a tela que este receptor diz ter.
    #[arg(long)]
    tela: Option<String>,
    #[arg(long, default_value_t = 900)]
    segundos: u64,
    #[arg(long)]
    pedir_idr_em: Option<u64>,
    #[arg(long)]
    salvar: Option<PathBuf>,
    /// O ICE preso em 127.0.0.1 (a bancada com `--so-local`).
    #[arg(long)]
    so_local: bool,
    /// **Decodifica e lê a régua** de cada quadro, sem janela (a fase 4 da câmera): o resumo ganha a
    /// contagem da régua. Só faz sentido com uma origem nossa que leva a régua.
    #[arg(long)]
    regua: bool,
    /// Não lê o stdin: lançado por um roteiro (e não pelo orquestrador), o stdin chega fechado, e o
    /// fechado é o "sair" do receptor. Com isto, só `--segundos` (ou o emissor) acaba a recepção.
    #[arg(long)]
    sem_stdin: bool,
}

fn main() {
    quall_capture_probe::higiene_do_registro::instalar_hook_do_executavel();
    let cli = quall_capture_probe::diagnostico_cli::interpretar::<Cli>();
    let codigo = match cli.modo {
        Modo::Orquestrar(o) => orquestrar(o),
        Modo::Receptor(r) => receptor(r),
    };
    std::process::exit(codigo);
}

// =============================================================================================
// O receptor sem cabeça
// =============================================================================================

#[derive(Default)]
struct Recepcao {
    quadros: u64,
    bytes: u64,
    idrs: u64,
    primeiro: Option<Instant>,
    ultimo: Option<Instant>,
    intervalos_ms: Vec<u64>,
    sps: Option<sps::ResumoSps>,
    maior_idr: usize,
    tamanhos_p: Vec<usize>,
    idrs_em: Vec<Instant>,
    /// Quando a track de tela chegou: o tempo dela ao primeiro quadro é o que o Android e o iOS
    /// medem contra os 10 s sem quadro (a revisão, item 7).
    track_em: Option<Instant>,
    /// Os buracos acima de 100 ms, com a hora UTC do quadro que os fechou (a mesma do registro do
    /// emissor): é o que diz se o buraco cai numa `SetDisplayConfig`, numa troca de captura ou em
    /// outra coisa.
    buracos: Vec<(std::time::SystemTime, u64)>,
}

/// `HH:MM:SS.mmmZ` de um instante do relógio do sistema, como o registro escreve.
fn hora_utc(t: std::time::SystemTime) -> String {
    let d = t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let s = d.as_secs() % 86_400;
    format!("{:02}:{:02}:{:02}.{:03}Z", s / 3600, (s / 60) % 60, s % 60, d.subsec_millis())
}

/// Os tipos de NAL de um Annex-B.
fn tipos_de_nal(annexb: &[u8]) -> Vec<u8> {
    let mut tipos = Vec::new();
    let mut i = 0usize;
    while i + 3 < annexb.len() {
        if annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1 {
            tipos.push(annexb[i + 3] & 0x1f);
            i += 3;
        } else {
            i += 1;
        }
    }
    tipos
}

fn receptor(a: ArgsDoReceptor) -> i32 {
    let resumo_de_erro = |etapa: &str, erro: String| {
        println!(
            "RESUMO {}",
            serde_json::json!({ "id": a.id, "conectou": false, "etapa": etapa, "erro": erro })
        );
    };
    let pin = match Pin::parse(&a.pin) {
        Ok(p) => p,
        Err(e) => {
            resumo_de_erro("pin", e.to_string());
            return 2;
        }
    };
    let tela = a.tela.as_deref().and_then(|t| {
        let (l, al) = t.split_once('x')?;
        Screen::nova(l.parse().ok()?, al.parse().ok()?)
    });
    let mut eu = anuncio(&a.id, &a.nome, Capabilities { screen_source: false, camera_source: false, sink: true });
    eu.screen = tela;
    let destino = match endereco_manual(&a.ip) {
        Ok(d) => d,
        Err(e) => {
            resumo_de_erro("endereco", e.to_string());
            return 2;
        }
    };
    let comeco = Instant::now();
    let pronto = conectar(
        destino,
        SessionConfig {
            announcement: eu,
            pin: Some(pin),
            // Pareamento vazio: cada sonda é um aparelho novo, e nada daqui toca o `pares.json` de
            // ninguém.
            known: PairedPeers::new(),
            transport: if a.so_local {
                TransportConfig { bind_address: Some("127.0.0.1".into()), ..TransportConfig::default() }
            } else {
                TransportConfig::default()
            },
            tracks: Vec::new(),
            timeout: Duration::from_secs(30),
            silencio_do_caminho: None,
            cancelamento: Default::default(),
        },
    );
    let mut pronto = match pronto {
        Ok(p) => p,
        Err(e) => {
            resumo_de_erro("conectar", e.to_string());
            return 1;
        }
    };
    let conectou_ms = comeco.elapsed().as_millis() as u64;
    println!("CONECTOU {}", serde_json::json!({ "id": a.id, "ms": conectou_ms }));
    let _ = std::io::stdout().flush();

    // A track de vídeo.
    let fim_da_espera = Instant::now() + Duration::from_secs(20);
    let mut track = None;
    while Instant::now() < fim_da_espera {
        let restante = fim_da_espera.saturating_duration_since(Instant::now());
        match pronto.session.proxima_track(restante) {
            // A track de vídeo: tela, ou câmera com `--camera-sintetica`.
            Some(t) if matches!(t.kind(), TrackKind::Screen | TrackKind::Camera) => {
                track = Some(t);
                break;
            }
            Some(_) => continue,
            None => break,
        }
    }
    let Some(track) = track else {
        resumo_de_erro("track", "nenhuma track de vídeo (tela ou câmera) em 20 s".into());
        return 1;
    };

    let estado = Arc::new(Mutex::new(Recepcao { track_em: Some(Instant::now()), ..Recepcao::default() }));
    let arquivo = a
        .salvar
        .as_ref()
        .and_then(|c| std::fs::File::create(c).ok())
        .map(|f| Arc::new(Mutex::new(std::io::BufWriter::new(f))));
    // **A régua** (fase 4): cada quadro vai também para o fio do decodificador, por uma fila curta.
    // Fila cheia descarta e conta: o fio da rede não espera o decodificador.
    let (fila_da_regua, fio_da_regua, descartados_da_regua) = if a.regua {
        let (tx, rx) = crossbeam_channel::bounded::<Vec<u8>>(64);
        let fio = std::thread::spawn(move || decodificar_com_regua(rx));
        (Some(tx), Some(fio), Arc::new(std::sync::atomic::AtomicU64::new(0)))
    } else {
        (None, None, Arc::new(std::sync::atomic::AtomicU64::new(0)))
    };
    {
        let estado = Arc::clone(&estado);
        let arquivo = arquivo.clone();
        let fila_da_regua = fila_da_regua.clone();
        let descartados_da_regua = Arc::clone(&descartados_da_regua);
        track.ao_receber_quadro(move |q: QuadroCodificado<'_>| {
            let agora = Instant::now();
            if let Some(f) = &fila_da_regua {
                if f.try_send(q.annexb.to_vec()).is_err() {
                    descartados_da_regua.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
            let tipos = tipos_de_nal(q.annexb);
            let e_idr = tipos.contains(&5);
            if let Some(f) = &arquivo {
                if let Ok(mut f) = f.lock() {
                    let _ = f.write_all(q.annexb);
                }
            }
            let Ok(mut r) = estado.lock() else { return };
            r.quadros += 1;
            r.bytes += q.annexb.len() as u64;
            if r.primeiro.is_none() {
                r.primeiro = Some(agora);
            }
            if let Some(u) = r.ultimo {
                let ms = (agora - u).as_millis() as u64;
                r.intervalos_ms.push(ms);
                // 128: na N = 8 de 15/09 a lista de 16 encheu antes do regime em cinco receptores.
                if ms > 100 && r.buracos.len() < 128 {
                    r.buracos.push((std::time::SystemTime::now(), ms));
                }
            }
            r.ultimo = Some(agora);
            if e_idr {
                r.idrs += 1;
                r.idrs_em.push(agora);
                r.maior_idr = r.maior_idr.max(q.annexb.len());
                if r.sps.is_none() {
                    r.sps = sps::resumir(q.annexb);
                }
            } else {
                r.tamanhos_p.push(q.annexb.len());
            }
        });
    }

    // `sair` no stdin, ou o stdin fechado, é o fim gracioso (com `Bye`). Com `--sem-stdin` (o
    // receptor lançado sozinho por um roteiro, sem o orquestrador segurando o stdin) só o prazo acaba.
    let sair = Arc::new(std::sync::atomic::AtomicBool::new(false));
    if !a.sem_stdin {
        let sair = Arc::clone(&sair);
        std::thread::spawn(move || {
            let entrada = std::io::stdin();
            for linha in entrada.lock().lines() {
                match linha {
                    Ok(l) if l.trim() == "sair" => break,
                    Ok(_) => continue,
                    Err(_) => break,
                }
            }
            sair.store(true, std::sync::atomic::Ordering::SeqCst);
        });
    }

    let prazo = Instant::now() + Duration::from_secs(a.segundos);
    let mut pedido_idr: Option<Instant> = None;
    let fim = loop {
        if sair.load(std::sync::atomic::Ordering::SeqCst) {
            break "sair pedido (com Bye)".to_string();
        }
        if Instant::now() >= prazo {
            break "prazo".to_string();
        }
        match pronto.proximo_evento(Duration::from_millis(100)) {
            EventoDeSessao::Desconectou => break "o emissor encerrou (Desconectou)".to_string(),
            EventoDeSessao::Falhou => break "a conexão caiu (Falhou)".to_string(),
            EventoDeSessao::Nenhum => {}
        }
        if let (Some(t), None) = (a.pedir_idr_em, pedido_idr) {
            let primeiro = estado.lock().ok().and_then(|r| r.primeiro);
            if primeiro.map(|p| p.elapsed() >= Duration::from_secs(t)).unwrap_or(false) {
                pedido_idr = Some(Instant::now());
                let _ = track.pedir_idr();
            }
        }
    };
    let _ = track.desregistrar_quadro();
    // A fila fecha: o fio do decodificador termina o que tem e devolve a contagem.
    drop(fila_da_regua);
    let regua = fio_da_regua.and_then(|f| f.join().ok()).map(|mut r| {
        r.descartados_na_fila = descartados_da_regua.load(std::sync::atomic::Ordering::Relaxed);
        r
    });
    if let Some(f) = &arquivo {
        if let Ok(mut f) = f.lock() {
            let _ = f.flush();
        }
    }

    let r = estado.lock().map(|r| {
        let mut tamanhos = r.tamanhos_p.clone();
        tamanhos.sort_unstable();
        let mut intervalos = r.intervalos_ms.clone();
        intervalos.sort_unstable();
        let p = |v: &Vec<u64>, q: f64| if v.is_empty() { 0 } else { v[((v.len() - 1) as f64 * q) as usize] };
        let duracao = match (r.primeiro, r.ultimo) {
            (Some(a), Some(b)) => (b - a).as_secs_f64(),
            _ => 0.0,
        };
        let idr_depois_do_pedido = pedido_idr.and_then(|t0| {
            r.idrs_em.iter().find(|t| **t >= t0).map(|t| (*t - t0).as_millis() as u64)
        });
        serde_json::json!({
            "id": a.id,
            "conectou": true,
            "conectou_ms": conectou_ms,
            "tela_dita": a.tela,
            // A régua de cada quadro decodificado, com `--regua` (fase 4 da câmera).
            "regua": regua.as_ref().map(|r| r.json()),
            // A espécie e o rótulo que chegaram: `Camera` com `--camera-sintetica` (fase 3 da câmera).
            "especie": format!("{:?}", track.kind()),
            "rotulo": track.label(),
            "sps": r.sps.as_ref().map(|s| s.linha()),
            "largura": r.sps.as_ref().map(|s| s.largura),
            "altura": r.sps.as_ref().map(|s| s.altura),
            "quadros": r.quadros,
            "bytes": r.bytes,
            "idrs": r.idrs,
            "primeiro_quadro_ms": r.primeiro.map(|t| (t - comeco).as_millis() as u64),
            "track_ao_primeiro_quadro_ms": match (r.track_em, r.primeiro) {
                (Some(t), Some(p)) => Some(p.saturating_duration_since(t).as_millis() as u64),
                _ => None,
            },
            "duracao_s": (duracao * 10.0).round() / 10.0,
            "fps_medio": if duracao > 0.0 { ((r.quadros as f64 - 1.0) / duracao * 10.0).round() / 10.0 } else { 0.0 },
            "intervalo_p50_ms": p(&intervalos, 0.5),
            "intervalo_p95_ms": p(&intervalos, 0.95),
            "maior_intervalo_ms": intervalos.last().copied().unwrap_or(0),
            "buracos_acima_de_100ms": r.buracos.iter().map(|(t, ms)| format!("{}:{ms}", hora_utc(*t))).collect::<Vec<_>>(),
            "maior_idr_bytes": r.maior_idr,
            "p_p50_bytes": if tamanhos.is_empty() { 0 } else { tamanhos[tamanhos.len() / 2] },
            "p_max_bytes": tamanhos.last().copied().unwrap_or(0),
            "idr_pedido": pedido_idr.is_some(),
            "idr_depois_do_pedido_ms": idr_depois_do_pedido,
            "pacotes_perdidos": track.pacotes_perdidos(),
            "quadros_descartados": track.quadros_descartados(),
            "fim": fim,
        })
    });
    if let Ok(mut j) = r {
        quall_capture_probe::diagnostico_json::redigir(&mut j);
        println!("RESUMO {j}");
    }
    let _ = std::io::stdout().flush();
    // O `Ready` cai aqui: o `Bye` sai. Sem `cleanup` — ver o cabeçalho.
    drop(track);
    drop(pronto);
    0
}

// =============================================================================================
// O orquestrador
// =============================================================================================

/// As telas dos aparelhos da bancada (retrato, como os painéis dizem), na ordem em que os
/// receptores entram. As oito cobrem os formatos da tabela de `docs/tela-estendida.md`.
const TELAS: [(&str, u32, u32); 8] = [
    ("tablet SM-X230", 1200, 1920),
    ("iPhone X", 1125, 2436),
    ("S24", 1440, 3120),
    ("iPad A16", 1640, 2360),
    ("A07", 720, 1600),
    ("iPhone 7", 750, 1334),
    ("A10s", 720, 1520),
    ("Mac 5K", 2880, 5120),
];

struct Filho {
    id: String,
    porta: u16,
    pin: String,
    processo: Child,
    entrada: Option<ChildStdin>,
    linhas: Arc<Mutex<Vec<String>>>,
    lancado: Instant,
}

fn lancar(
    exe: &std::path::Path,
    k: usize,
    porta: u16,
    pin: &str,
    pin_dito: &str,
    o: &Orquestrar,
    sufixo: &str,
) -> std::io::Result<Filho> {
    let (aparelho, l, a) = TELAS[k % TELAS.len()];
    let id = format!("sonda-{k}");
    let nome = format!("sonda {k} ({aparelho})");
    let mut cmd = Command::new(exe);
    cmd.creation_flags(windows::Win32::System::Threading::CREATE_NO_WINDOW.0);
    cmd.arg("receptor")
        .args(["--ip", &format!("127.0.0.1:{porta}")])
        .args(["--pin", pin_dito])
        .args(["--id", &id])
        .args(["--nome", &nome])
        .args(["--tela", &format!("{l}x{a}")]);
    if let Some(t) = o.pedir_idr_em {
        cmd.args(["--pedir-idr-em", &t.to_string()]);
    }
    if let Some(pasta) = &o.salvar_h264 {
        let _ = std::fs::create_dir_all(pasta);
        cmd.arg("--salvar").arg(pasta.join(format!("{id}{sufixo}.h264")));
    }
    if o.so_local || o.monitores_virtuais {
        cmd.arg("--so-local");
    }
    if o.regua {
        cmd.arg("--regua");
    }
    let err = o.registro.with_file_name(format!("receptor-{id}{sufixo}.err"));
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(std::fs::File::create(err)?));
    let mut processo = cmd.spawn()?;
    let linhas = Arc::new(Mutex::new(Vec::new()));
    if let Some(saida) = processo.stdout.take() {
        let linhas = Arc::clone(&linhas);
        let id_ = id.clone();
        std::thread::spawn(move || {
            for l in BufReader::new(saida).lines().map_while(Result::ok) {
                registro::linha(format!("bancada: receptor {id_}: {l}"));
                if let Ok(mut v) = linhas.lock() {
                    v.push(l);
                }
            }
        });
    }
    let entrada = processo.stdin.take();
    registro::linha(format!(
        "bancada: lancei {id} ({aparelho}, tela {l}x{a}) contra loopback:{porta} pin=<PIN>{}",
        if pin_dito != pin { " (ERRADO de propósito)" } else { "" }
    ));
    Ok(Filho { id, porta, pin: pin.to_string(), processo, entrada, linhas, lancado: Instant::now() })
}

/// **A troca da primeira sessão** (`--trocar-primeiro-aos`): o receptor 0 sai com `Bye` (stdin
/// fechado), a sessão dele desmonta, e um receptor novo entra pela espera aberta.
fn trocar_o_primeiro(
    emissor: &Arc<Emissor>,
    exe: &std::path::Path,
    o: &Orquestrar,
    filhos: &mut Vec<Filho>,
    usadas: &mut HashSet<(u16, String)>,
) {
    let antes = no_ar(&emissor.estado());
    registro::linha(format!("bancada: [troca] {} sai com Bye (stdin fechado); no ar antes: {antes}", filhos[0].id));
    filhos[0].entrada.take();
    let saiu = esperar(emissor, Duration::from_secs(15), |e| no_ar(e) < antes);
    registro::linha(format!(
        "bancada: [troca] a sessão dele {}",
        saiu.map(|t| format!("saiu em {} ms", t.as_millis())).unwrap_or_else(|| "!! NÃO saiu em 15 s".into())
    ));
    let Some((porta, pin)) = espera_nova(emissor, usadas, Duration::from_secs(10)) else {
        registro::linha("bancada: [troca] !! nenhuma espera nova em 10 s");
        return;
    };
    usadas.insert((porta, pin.clone()));
    let k = filhos.len();
    match lancar(exe, k, porta, &pin, &pin, o, "") {
        Ok(f) => {
            let id = f.id.clone();
            filhos.push(f);
            let entrou = esperar(emissor, Duration::from_secs(30), |e| no_ar(e) >= antes);
            registro::linha(format!(
                "bancada: [troca] {id} {}",
                entrou.map(|t| format!("no ar em {} ms", t.as_millis())).unwrap_or_else(|| "!! não ficou no ar em 30 s".into())
            ));
        }
        Err(e) => registro::linha(format!("bancada: [troca] !! não lancei o receptor {k}: {e}")),
    }
}

fn esperar(emissor: &Emissor, prazo: Duration, condicao: impl Fn(&Estado) -> bool) -> Option<Duration> {
    let comeco = Instant::now();
    while comeco.elapsed() < prazo {
        if condicao(&emissor.estado()) {
            return Some(comeco.elapsed());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

/// A espera aberta agora, se ela ainda não foi usada por nenhum receptor.
fn espera_nova(emissor: &Emissor, usadas: &HashSet<(u16, String)>, prazo: Duration) -> Option<(u16, String)> {
    let mut achada = None;
    esperar(emissor, prazo, |e| {
        if let Some(p) = e.porta_da_espera {
            if !e.pin.is_empty() && !usadas.contains(&(p, e.pin.clone())) {
                return true;
            }
        }
        false
    })?;
    let e = emissor.estado();
    if let Some(p) = e.porta_da_espera {
        achada = Some((p, e.pin.clone()));
    }
    achada
}

fn no_ar(e: &Estado) -> usize {
    e.receptores.iter().filter(|r| !r.monitor.starts_with("esperando")).count()
}

fn retrato(emissor: &Emissor) -> String {
    let e = emissor.estado();
    let mut s = format!(
        "fase={:?} no_ar={} esperando_mais_um={} porta_da_espera={:?} pin={}",
        e.fase,
        no_ar(&e),
        e.esperando_mais_um,
        e.porta_da_espera,
        if e.pin.is_empty() { "-".to_string() } else { "<PIN>".to_string() }
    );
    for r in &e.receptores {
        s.push_str(&format!("\n    #{} esperando={}", r.id, r.monitor.starts_with("esperando")));
    }
    s
}

fn orquestrar(o: Orquestrar) -> i32 {
    // **Antes de qualquer outra coisa**: a pasta de dados descartável. Nada desta corrida pode cair
    // no `%APPDATA%\Quall` do usuário (pares, device-id, índices).
    let pasta = o
        .pasta
        .clone()
        .unwrap_or_else(|| std::env::temp_dir().join(format!("quall-varias-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&pasta);
    let _ = std::fs::create_dir_all(&pasta);
    std::env::set_var(identidade::VARIAVEL_DA_PASTA, &pasta);

    // **Os receptores só contam** com monitor virtual: um monitor da sessão interativa, mesmo coberto
    // pela nossa janela, é da tela do usuário — nada dele se grava.
    if o.monitores_virtuais && o.salvar_h264.is_some() {
        eprintln!("recusa: --salvar-h264 com --monitores-virtuais — os receptores só contam");
        return 2;
    }
    let cobrir: Option<quall_capture_probe::cobertura::Modo> = if o.monitores_virtuais {
        match o.cobertura.parse() {
            Ok(m) => Some(m),
            Err(e) => {
                eprintln!("recusa: {e}");
                return 2;
            }
        }
    } else {
        None
    };
    // Pixels físicos: a janela sintética cobre o monitor pelo retângulo que a enumeração devolve.
    if o.monitores_virtuais {
        let _ = unsafe {
            windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        };
    }

    unsafe {
        if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
            eprintln!("CoInitializeEx falhou");
            return 2;
        }
        if MFStartup(MF_VERSION, MFSTARTUP_FULL).is_err() {
            eprintln!("MFStartup falhou");
            return 2;
        }
    }
    registro::abrir(Some(&o.registro));
    // `SESSIONNAME` falta tanto na Sessão 0 do SSH quanto numa tarefa agendada interativa: não
    // serve de testemunha da sessão. Quem a registra é o roteiro que lança (`SessionId` do
    // PowerShell). Número de desempenho só vale da interativa.
    let sessao = std::env::var("SESSIONNAME").unwrap_or_else(|_| "ausente".into());
    registro::linha(format!(
        "bancada: quall-varias orquestrar — receptores={} segundos={} carga={} ritmo={} preferir_intel={} \
         troca_a_quente={} roteiro_completo={} camera_sintetica={} camera_link={} regua={} SESSIONNAME={sessao} pasta_de_dados={}",
        o.receptores,
        o.segundos,
        o.carga,
        o.ritmo,
        o.preferir_intel,
        !o.sem_troca_a_quente,
        o.roteiro_completo,
        o.camera_sintetica,
        o.camera_link.as_deref().unwrap_or("nenhuma"),
        o.regua,
        pasta.display()
    ));

    let mut args = vec![
        "quall-app".to_string(),
        "--varias-sessoes".into(),
        // Nenhum roteiro nasce com som (`docs/handover-seis-frentes.md` §11).
        "--sem-som".into(),
        // Modo de bancada: o PIN, que é desta corrida e descartável, vai para o registro.
        "--espelhar-ja".into(),
        "--teto-quadro-em-medios".into(),
        o.teto_quadro_em_medios.to_string(),
    ];
    if let Some(m) = cobrir {
        args.extend(["--monitor-virtual".into(), "--cobrir-monitor".into(), m.nome().to_string()]);
        if o.sem_captura {
            args.push("--monitor-sem-captura".into());
        }
    } else if o.camera_sintetica {
        args.push("--camera-sintetica".into());
    } else if let Some(link) = &o.camera_link {
        // A câmera de bancada: liberada pela trava do produto, e escolhida pelo link exato.
        args.extend(["--camera-de-bancada".into(), link.clone(), "--fonte".into(), link.clone()]);
    } else {
        args.extend(["--origem-sintetica".into(), o.carga.clone(), "--ritmo-sintetico".into(), o.ritmo.clone()]);
    }
    if o.so_local || o.monitores_virtuais {
        args.push("--so-local".into());
    }
    if o.preferir_intel {
        args.push("--preferir-intel".into());
    }
    if o.sem_troca_a_quente {
        args.push("--sem-troca-a-quente".into());
    }
    let argumentos = quall_capture_probe::diagnostico_cli::interpretar_de::<Argumentos, _, _>(args);
    if o.monitores_virtuais {
        use quall_capture_probe::monitores_virtuais as mv;
        registro::linha(format!(
            "bancada: monitores virtuais (cobertura {}{}), só em 127.0.0.1 — antes: topologia={} ativos={} {} smkd1ce_presentes={}",
            o.cobertura,
            if o.sem_captura { ", SEM CAPTURA: o controle" } else { "" },
            mv::ccd::topologia(),
            mv::ccd::resumo_dos_ativos(),
            mv::sistema(),
            quall_capture_probe::sudovda::pnp::monitores_presentes().map(|v| v.len().to_string()).unwrap_or_else(|e| e)
        ));
    }
    let emissor = Emissor::novo(argumentos);
    let exe = std::env::current_exe().expect("o caminho deste .exe");

    emissor.espelhar();
    let mut usadas: HashSet<(u16, String)> = HashSet::new();
    let mut filhos: Vec<Filho> = Vec::new();
    let mut resultado = 0;

    // --- 1. os receptores entram, um por vez -------------------------------------------------------
    let n = o.receptores.min(sessoes::LIMITE_DE_SESSOES + 1);
    for k in 0..n {
        let Some((porta, pin)) = espera_nova(&emissor, &usadas, Duration::from_secs(20)) else {
            registro::linha(format!(
                "bancada: nenhuma espera nova abriu para o receptor {k} em 20 s ({})",
                if k >= sessoes::LIMITE_DE_SESSOES { "o limite, como devia" } else { "!! FALHA" }
            ));
            if k < sessoes::LIMITE_DE_SESSOES {
                resultado = 1;
            }
            break;
        };
        usadas.insert((porta, pin.clone()));
        match lancar(&exe, k, porta, &pin, &pin, &o, "") {
            Ok(f) => filhos.push(f),
            Err(e) => {
                registro::linha(format!("bancada: !! não lancei o receptor {k}: {e}"));
                resultado = 1;
                break;
            }
        }
        match esperar(&emissor, Duration::from_secs(30), |e| no_ar(e) >= k + 1) {
            Some(t) => registro::linha(format!("bancada: receptor {k} no ar em {} ms", t.as_millis())),
            None => {
                registro::linha(format!("bancada: !! o receptor {k} não ficou no ar em 30 s"));
                resultado = 1;
            }
        }
    }
    registro::linha(format!("bancada: todos lançados — {}", retrato(&emissor)));

    // --- 2. todos no ar juntos ---------------------------------------------------------------------
    let comeco_juntos = Instant::now();
    let fim = comeco_juntos + Duration::from_secs(o.segundos);
    let mut ultimo_retrato = Instant::now();
    let mut trocou = false;
    while Instant::now() < fim {
        std::thread::sleep(Duration::from_millis(250).min(fim.saturating_duration_since(Instant::now())));
        if let Some(aos) = o.trocar_primeiro_aos {
            if !trocou && comeco_juntos.elapsed() >= Duration::from_secs(aos) && !filhos.is_empty() {
                trocou = true;
                trocar_o_primeiro(&emissor, &exe, &o, &mut filhos, &mut usadas);
            }
        }
        if ultimo_retrato.elapsed() >= Duration::from_secs(5) {
            ultimo_retrato = Instant::now();
            registro::linha(format!("bancada: retrato — {}", retrato(&emissor)));
        }
    }

    // --- 3. o roteiro ------------------------------------------------------------------------------
    if o.roteiro_completo && !filhos.is_empty() {
        roteiro(&emissor, &exe, &o, &mut filhos, &mut usadas);
    }

    // --- 4. Parar, e o desmonte ----------------------------------------------------------------------
    let t0 = Instant::now();
    emissor.encerrar();
    let parou = esperar(&emissor, Duration::from_secs(20), |e| e.fase == Fase::Inicial);
    registro::linha(format!(
        "bancada: Parar -> tela inicial em {}",
        parou.map(|t| format!("{} ms", t.as_millis())).unwrap_or_else(|| "!! MAIS DE 20 s".into())
    ));
    let completo = emissor.esperar_desmonte(Duration::from_secs(15));
    registro::linha(format!(
        "bancada: desmonte completo={completo} em {} ms desde o Parar",
        t0.elapsed().as_millis()
    ));
    if parou.is_none() || !completo {
        resultado = 1;
    }
    if o.monitores_virtuais {
        let n = quall_capture_probe::monitores_virtuais::encerrar_tudo(Duration::from_secs(8));
        registro::linha(format!("bancada: encerrar_tudo dos monitores virtuais: {n} solto(s) na saída"));
    }

    // Os filhos que sobraram saem com `Bye` (stdin fechado), ou são derrubados em 10 s.
    for f in filhos.iter_mut() {
        f.entrada.take();
    }
    let prazo = Instant::now() + Duration::from_secs(10);
    for f in filhos.iter_mut() {
        loop {
            match f.processo.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() < prazo => std::thread::sleep(Duration::from_millis(50)),
                _ => {
                    registro::linha(format!("bancada: !! {} não saiu em 10 s — derrubando", f.id));
                    let _ = f.processo.kill();
                    let _ = f.processo.wait();
                    break;
                }
            }
        }
    }
    std::thread::sleep(Duration::from_millis(300));

    // --- 5. o resumo ---------------------------------------------------------------------------------
    let portas: HashSet<u16> = usadas.iter().map(|u| u.0).collect();
    let pins: HashSet<&String> = usadas.iter().map(|u| &u.1).collect();
    registro::linha(format!(
        "bancada: RESUMO esperas usadas={} portas distintas={} PINs distintos={} receptores lançados={}",
        usadas.len(),
        portas.len(),
        pins.len(),
        filhos.len()
    ));
    for f in &filhos {
        let linhas = f.linhas.lock().map(|v| v.clone()).unwrap_or_default();
        let resumo = linhas.iter().rev().find(|l| l.starts_with("RESUMO ")).cloned();
        registro::linha(format!(
            "bancada: {} porta={} pin={} vivo_por={:.1}s {}",
            f.id,
            f.porta,
            "<PIN>",
            f.lancado.elapsed().as_secs_f64(),
            resumo.unwrap_or_else(|| "(sem RESUMO)".into())
        ));
    }
    if o.monitores_virtuais {
        relatar_monitores();
    }
    registro::linha(format!("bancada: fim, código {resultado}"));
    drop(emissor);
    // A câmera solta o leitor e a fonte fora da sessão (o R4, M51): o `MFShutdown` espera por elas
    // até 30 s, e sai sem ele se alguma sobrar (a revisão do código da fase 4, m2).
    if quall_capture_probe::captura_de_camera::esperar_solturas_na_saida(Duration::from_secs(30)) {
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
    }
    resultado
}

/// O que os monitores virtuais fizeram nesta corrida: nascimentos (ADD → ativo), se algum outro saiu
/// da área de trabalho quando um chegou, os buracos da captura na troca de `HMONITOR`, as solturas
/// testemunhadas, os reparos depois de um `REMOVE`, o ping — e a tela do usuário no fim.
fn relatar_monitores() {
    use quall_capture_probe::monitores_virtuais as mv;
    let r = mv::relato();
    let p = |v: &mut Vec<u64>, q: f64| -> u64 {
        if v.is_empty() {
            return 0;
        }
        v.sort_unstable();
        v[((v.len() - 1) as f64 * q).round() as usize]
    };
    let mut ativos: Vec<u64> = r.nascimentos.iter().filter_map(|n| n.ativo_ms).collect();
    let mut filas: Vec<u64> = r.nascimentos.iter().map(|n| n.fila_ms).collect();
    registro::linha(format!(
        "bancada: MONITORES nascimentos={} (falhas={}) ADD→ativo p50={} máx={} ms · fila p50={} máx={} ms · algum outro saiu da área de trabalho: {}",
        r.nascimentos.len(),
        r.nascimentos.iter().filter(|n| n.falha.is_some()).count(),
        p(&mut ativos.clone(), 0.5),
        p(&mut ativos, 1.0),
        p(&mut filas.clone(), 0.5),
        p(&mut filas, 1.0),
        if r.nascimentos.iter().any(|n| n.algum_outro_saiu) { "SIM" } else { "não" }
    ));
    for n in &r.nascimentos {
        registro::linha(format!(
            "bancada: MONITOR índice={} alvo={} ativo={} ms fila={} ms pedidos={} clones_desfeitos={} esperas={} adotado={} modo={} desenha={} | outros: {} | nomes: [{}]{}",
            n.indice,
            n.alvo,
            n.ativo_ms.map_or("-".into(), |x| x.to_string()),
            n.fila_ms,
            n.pedidos,
            n.clones_desfeitos,
            n.esperas,
            n.adotado,
            n.modo,
            n.desenha,
            n.outros,
            n.nomes_dos_outros,
            n.falha.as_ref().map(|f| format!(" FALHA: {f}")).unwrap_or_default()
        ));
    }
    for (alvo, buraco, motivo) in &r.reaberturas {
        registro::linha(format!("bancada: REABERTURA alvo={alvo} buraco={buraco} ms ({motivo})"));
    }
    let confirmadas: Vec<u64> = r.solturas.iter().filter_map(|s| s.1).collect();
    registro::linha(format!(
        "bancada: SOLTURAS {} (testemunhadas {}, ms={:?}) · REPAROS depois de REMOVE {:?} (fora, pedidos) · capturas presas {} · recolher {:?} · ping (pings, falhas, maior intervalo ms, pulados) {:?}",
        r.solturas.len(),
        confirmadas.len(),
        confirmadas,
        r.reparos,
        r.capturas_presas,
        r.recolhimentos,
        r.ping
    ));
    registro::linha(format!(
        "bancada: depois: topologia={} ativos={} {} smkd1ce_presentes={} fios_de_captura_abandonados={} (voltaram tarde: {})",
        mv::ccd::topologia(),
        mv::ccd::resumo_dos_ativos(),
        mv::sistema(),
        quall_capture_probe::sudovda::pnp::monitores_presentes().map(|v| v.len().to_string()).unwrap_or_else(|e| e),
        quall_capture_probe::capture::FIOS_ABANDONADOS.load(std::sync::atomic::Ordering::SeqCst),
        quall_capture_probe::capture::FIOS_QUE_VOLTARAM_TARDE.load(std::sync::atomic::Ordering::SeqCst)
    ));
}

/// Um sai sem `Bye` e volta com a mesma identidade; um PIN errado; um sai com `Bye`; Parar no meio
/// de um desmonte fica para o passo 4.
fn roteiro(
    emissor: &Arc<Emissor>,
    exe: &std::path::Path,
    o: &Orquestrar,
    filhos: &mut Vec<Filho>,
    usadas: &mut HashSet<(u16, String)>,
) {
    let limite = sessoes::LIMITE_DE_SESSOES;
    let n_originais = filhos.len();
    // --- a1. o mesmo aparelho de novo, com a sessão velha ainda viva ---
    //
    // O caso do requisito: o Wi-Fi piscou e o aparelho reconectou antes de a sessão velha cair. A
    // primeira versão deste passo derrubava o receptor por `TerminateProcess` e o fazia voltar —
    // mas em `127.0.0.1` o sistema fecha o socket da sinalização na hora, o emissor percebeu a
    // queda em 18 ms, e a volta nunca encontrou a velha de pé. Aqui a velha **fica** no ar: um
    // segundo receptor com a mesma identidade entra pela espera aberta.
    let k = if filhos.len() > 1 { 1 } else { 0 };
    let prefixo = format!("sonda {k} ");
    let antes = {
        let e = emissor.estado();
        e.receptores.iter().find(|r| r.nome.starts_with(&prefixo)).map(|r| r.monitor.clone())
    };
    if filhos.len() < limite {
        if let Some((porta, pin)) = espera_nova(emissor, usadas, Duration::from_secs(5)) {
            usadas.insert((porta, pin.clone()));
            registro::linha(format!(
                "bancada: [a1] {} volta pela espera aberta com a sessão velha no ar — antes: {antes:?}",
                filhos[k].id
            ));
            if let Ok(f) = lancar(exe, k, porta, &pin, &pin, o, "-volta") {
                let aguardou = esperar(emissor, Duration::from_secs(10), |e| {
                    e.receptores.iter().any(|r| r.nome.starts_with(&prefixo) && r.monitor.starts_with("esperando"))
                });
                let transmite = esperar(emissor, Duration::from_secs(30), |e| {
                    let deste: Vec<_> = e.receptores.iter().filter(|r| r.nome.starts_with(&prefixo)).collect();
                    deste.len() == 1 && !deste[0].monitor.starts_with("esperando")
                });
                let depois = {
                    let e = emissor.estado();
                    e.receptores.iter().find(|r| r.nome.starts_with(&prefixo)).map(|r| r.monitor.clone())
                };
                registro::linha(format!(
                    "bancada: [a1] a nova se viu esperando a velha: {} | só uma deste aparelho, transmitindo, {} ms depois | monitor antes={antes:?} depois={depois:?} | mesmo índice: {}",
                    aguardou.is_some(),
                    transmite.map(|t| t.as_millis() as i64).unwrap_or(-1),
                    antes.is_some() && antes == depois
                ));
                filhos.push(f);
            }
        } else {
            registro::linha("bancada: [a1] !! sem espera aberta para a volta");
        }
        std::thread::sleep(Duration::from_secs(3));
    } else {
        registro::linha("bancada: [a1] no limite de 8 não há espera aberta: a volta com a velha viva não se aplica");
    }

    // --- a2. outro sai sem Bye (TerminateProcess), e volta ---
    // O último dos originais, quando há três ou mais (o 0 fica para o passo do `Bye` e o 1 foi o
    // do a1); com dois, o que acabou de voltar no a1.
    let j = if n_originais >= 3 { n_originais - 1 } else { filhos.len() - 1 };
    let alvo_id = filhos[j].id.clone();
    let alvo_k: usize = alvo_id.trim_start_matches("sonda-").parse().unwrap_or(0);
    let prefixo_j = format!("sonda {alvo_k} ");
    let antes_j = {
        let e = emissor.estado();
        e.receptores.iter().find(|r| r.nome.starts_with(&prefixo_j)).map(|r| r.monitor.clone())
    };
    let no_ar_antes = no_ar(&emissor.estado());
    registro::linha(format!("bancada: [a2] derrubando {alvo_id} sem Bye (TerminateProcess) — antes: {antes_j:?}"));
    let _ = filhos[j].processo.kill();
    let _ = filhos[j].processo.wait();
    let viu = esperar(emissor, Duration::from_secs(45), |e| no_ar(e) + 1 == no_ar_antes);
    registro::linha(format!(
        "bancada: [a2] o emissor viu a queda em {} ms",
        viu.map(|t| t.as_millis() as i64).unwrap_or(-1)
    ));
    match espera_nova(emissor, usadas, Duration::from_secs(10)) {
        Some((porta, pin)) => {
            usadas.insert((porta, pin.clone()));
            if let Ok(f) = lancar(exe, alvo_k, porta, &pin, &pin, o, "-volta2") {
                let transmite = esperar(emissor, Duration::from_secs(30), |e| {
                    e.receptores.iter().any(|r| r.nome.starts_with(&prefixo_j) && !r.monitor.starts_with("esperando"))
                });
                let depois = {
                    let e = emissor.estado();
                    e.receptores.iter().find(|r| r.nome.starts_with(&prefixo_j)).map(|r| r.monitor.clone())
                };
                registro::linha(format!(
                    "bancada: [a2] voltou e transmite em {} ms | monitor antes={antes_j:?} depois={depois:?} | mesmo índice: {}",
                    transmite.map(|t| t.as_millis() as i64).unwrap_or(-1),
                    antes_j.is_some() && antes_j == depois
                ));
                filhos.push(f);
            }
        }
        None => registro::linha("bancada: [a2] !! nenhuma espera abriu para a volta"),
    }
    std::thread::sleep(Duration::from_secs(3));

    // --- b. PIN errado na espera aberta ---
    if let Some((porta, pin)) = espera_nova(emissor, usadas, Duration::from_secs(5)) {
        // A espera tem de ter 3 s para ser reaberta (`sessoes::REABRIR_SO_DEPOIS_DE_MS`).
        std::thread::sleep(Duration::from_millis(3_500));
        let antes = no_ar(&emissor.estado());
        let errado = if pin.replace(' ', "") == "000000" { "111111".to_string() } else { "000000".to_string() };
        usadas.insert((porta, pin.clone()));
        if let Ok(f) = lancar(exe, 90, porta, &pin, &errado, o, "-errado") {
            let reaberta = esperar(emissor, Duration::from_secs(15), |e| {
                e.porta_da_espera.is_some() && !e.pin.is_empty() && e.pin != pin
            });
            let e = emissor.estado();
            registro::linha(format!(
                "bancada: [b] PIN errado — espera reaberta: {} em {} ms | porta antes={porta} depois={:?} | PIN mudou: {} | no ar antes={antes} depois={}",
                reaberta.is_some(),
                reaberta.map(|t| t.as_millis() as i64).unwrap_or(-1),
                e.porta_da_espera,
                e.pin != pin,
                no_ar(&e)
            ));
            drop(e);
            filhos.push(f);
        }
    } else {
        registro::linha("bancada: [b] sem espera aberta (no limite?) — PIN errado não exercitado");
    }
    std::thread::sleep(Duration::from_secs(2));

    // --- c. um sai com Bye ---
    if let Some(f) = filhos.iter_mut().find(|f| f.id == "sonda-0" && f.entrada.is_some()) {
        let antes = no_ar(&emissor.estado());
        if let Some(mut s) = f.entrada.take() {
            let _ = writeln!(s, "sair");
        }
        let saiu = esperar(emissor, Duration::from_secs(10), |e| no_ar(e) + 1 == antes);
        registro::linha(format!(
            "bancada: [c] sonda-0 saiu com Bye — o emissor viu em {} ms | {}",
            saiu.map(|t| t.as_millis() as i64).unwrap_or(-1),
            retrato(emissor)
        ));
    }
    std::thread::sleep(Duration::from_secs(2));

    // --- d. Parar no meio de um desmonte ---
    let alvo = emissor.estado().receptores.first().map(|r| r.id);
    if let Some(id) = alvo {
        registro::linha(format!("bancada: [d] Desconectar #{id} e, logo em seguida, Parar"));
        emissor.desconectar(id);
    }
}

// =============================================================================================
// O decodificador sem janela, com a régua (a fase 4 da câmera)
// =============================================================================================

/// O que a régua apurou num receptor com `--regua`.
#[derive(Default)]
struct ResumoDaRegua {
    decodificados: u64,
    antes_do_sps: u64,
    descartados_na_fila: u64,
    falhas_de_entrada: u64,
    falhas_de_saida: u64,
    contagem: quall_capture_probe::regua::Contagem,
    decodificador: String,
    erro: Option<String>,
}

impl ResumoDaRegua {
    fn json(&self) -> serde_json::Value {
        let c = &self.contagem;
        serde_json::json!({
            "decodificador": self.decodificador,
            "decodificados": self.decodificados,
            "lidas": c.lidas,
            "em_sequencia": c.em_sequencia,
            "fora_de_sequencia": c.fora_de_sequencia,
            "ilegiveis": c.ilegiveis,
            "sem_regua": c.sem_regua,
            "primeira": c.primeiro,
            "ultima": c.ultimo_visto,
            "antes_do_sps": self.antes_do_sps,
            "descartados_na_fila": self.descartados_na_fila,
            "falhas_de_entrada": self.falhas_de_entrada,
            "falhas_de_saida": self.falhas_de_saida,
            "erro": self.erro,
        })
    }
}

/// **O decodificador sem janela**: o mesmo MFT e o mesmo leitor da régua do app
/// (`exibicao.rs`), sem a swap chain — que não sobe na Sessão 0 (`prova-regua.ps1`). Decodifica cada
/// quadro que chega e lê a régua da textura que saiu do decodificador; o que fica é a contagem, um
/// inteiro por quadro, nunca a imagem. Só faz sentido com uma origem nossa que leva a régua (a
/// câmera sintética e a câmera de bancada da fase 4).
struct Decodificador {
    dec: quall_capture_probe::decoder::ChosenDecoder,
    _gerente: windows::Win32::Media::MediaFoundation::IMFDXGIDeviceManager,
    eventos: Option<crossbeam_channel::Receiver<quall_capture_probe::encoder::MftEvent>>,
    creditos: u32,
    leitor: Option<quall_capture_probe::regua::Leitor>,
    seq: i64,
    largura: u32,
    altura: u32,
}

impl Decodificador {
    fn novo(largura: u32, altura: u32, r: &mut ResumoDaRegua) -> anyhow::Result<Self> {
        use quall_capture_probe::{decoder, device, encoder, regua};
        let dec = decoder::find_and_activate_h264_decoder()?;
        r.decodificador = dec.friendly_name.clone();
        let adaptador = device::create_device(device::VENDOR_INTEL)?;
        let _ = device::proteger_contexto(&adaptador.context, true);
        let gerente = encoder::create_device_manager(&adaptador.device)?;
        decoder::configure(&dec, &gerente, &decoder::DecoderConfig { width: largura, height: altura, fps: 30 })?;
        decoder::start_stream(&dec.transform)?;
        let eventos = dec.events.clone().map(encoder::spawn_event_pump);
        let leitor = regua::Leitor::novo(&adaptador.device, largura, altura)?;
        Ok(Decodificador { dec, _gerente: gerente, eventos, creditos: 0, leitor: Some(leitor), seq: 0, largura, altura })
    }

    fn bombear(&mut self, r: &mut ResumoDaRegua, espera: Duration) {
        let Some(rx) = self.eventos.clone() else { return };
        let mut espera = espera;
        while let Ok(ev) = rx.recv_timeout(espera) {
            espera = Duration::ZERO;
            match ev {
                quall_capture_probe::encoder::MftEvent::NeedInput => self.creditos += 1,
                quall_capture_probe::encoder::MftEvent::HaveOutput => self.drenar(r),
                _ => {}
            }
        }
    }

    fn alimentar(&mut self, au: &[u8], r: &mut ResumoDaRegua) {
        use quall_capture_probe::decoder;
        use windows::Win32::Media::MediaFoundation::MF_E_NOTACCEPTING;
        let amostra = match decoder::sample_from_bytes(au, self.seq * 333_333, 333_333) {
            Ok(a) => a,
            Err(_) => {
                r.falhas_de_entrada += 1;
                return;
            }
        };
        for _ in 0..100 {
            if self.dec.is_async && self.creditos == 0 {
                self.bombear(r, Duration::from_millis(5));
                continue;
            }
            match unsafe { self.dec.transform.ProcessInput(0, &amostra, 0) } {
                Ok(()) => {
                    self.seq += 1;
                    if self.dec.is_async {
                        self.creditos -= 1;
                    }
                    break;
                }
                // O MFT síncrono pede a saída antes de aceitar mais.
                Err(e) if e.code() == MF_E_NOTACCEPTING => self.drenar(r),
                Err(_) => {
                    r.falhas_de_entrada += 1;
                    break;
                }
            }
        }
        if self.dec.is_async {
            self.bombear(r, Duration::ZERO);
        } else {
            self.drenar(r);
        }
    }

    /// Um quadro por vez, lido antes de pedir o próximo: o MFT recicla a superfície no
    /// `ProcessOutput` seguinte (`decoder::DecodedFrame`).
    fn drenar(&mut self, r: &mut ResumoDaRegua) {
        use quall_capture_probe::decoder;
        loop {
            match decoder::proximo_quadro_com_mudanca(&self.dec.transform, decoder::OUTPUT_STREAM_ID) {
                Ok((Some(q), _)) => {
                    r.decodificados += 1;
                    self.ler(&q, r);
                }
                Ok((None, _)) => break,
                Err(_) => {
                    r.falhas_de_saida += 1;
                    break;
                }
            }
        }
    }

    fn ler(&mut self, q: &quall_capture_probe::decoder::DecodedFrame, r: &mut ResumoDaRegua) {
        let (largura, altura) = (self.largura, self.altura);
        let Some(leitor) = self.leitor.as_mut() else { return };
        let ja_no_piso = leitor.no_caminho_largo();
        let resultado = leitor.ler(&q.texture, q.subresource_index);
        let segue_viva = match &resultado {
            Ok(_) => true,
            Err(_) if ja_no_piso => false,
            Err(_) => leitor.cair_para_o_caminho_largo(largura, altura).is_ok(),
        };
        match resultado {
            Ok(valor) => r.contagem.registrar(valor, true),
            Err(e) if !segue_viva => {
                r.erro = Some(format!("a leitura da régua desligou: {e}"));
                self.leitor = None;
            }
            Err(_) => {}
        }
    }
}

/// O fio do decodificador: espera o primeiro quadro com SPS (é dele que saem largura e altura), e
/// decodifica tudo o que vier depois, até a fila fechar.
fn decodificar_com_regua(fila: crossbeam_channel::Receiver<Vec<u8>>) -> ResumoDaRegua {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    }
    let mut r = ResumoDaRegua::default();
    let mut dec: Option<Decodificador> = None;
    for au in fila.iter() {
        if dec.is_none() {
            let Some(s) = sps::resumir(&au) else {
                r.antes_do_sps += 1;
                continue;
            };
            match Decodificador::novo(s.largura, s.altura, &mut r) {
                Ok(d) => dec = Some(d),
                Err(e) => {
                    r.erro = Some(format!("o decodificador não subiu: {e:#}"));
                    break;
                }
            }
        }
        if let Some(d) = dec.as_mut() {
            d.alimentar(&au, &mut r);
        }
    }
    drop(dec);
    unsafe {
        let _ = MFShutdown();
    }
    r
}
