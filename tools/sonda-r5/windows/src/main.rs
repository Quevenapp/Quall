//! `sonda-r5-w1` — **a sonda S-W1 do R5** (`docs/teleprompter-com-camera.md` §8.1), instrumento de
//! bancada, não produto.
//!
//! Duas perguntas do desenho, as duas no Dell e as duas com **origem sintética** (nenhuma câmera,
//! nenhum microfone, nenhuma tela: texturas pintadas por `ClearRenderTargetView` e um tom gerado
//! aqui):
//!
//! 1. **Dois H.264 de hardware ao mesmo tempo na mesma placa** (§5.1): um 1080p30 de taxa alta (a
//!    gravação) e um 720p30 (a rede), 60 s, cada placa de hardware do computador. fps de saída,
//!    latência por quadro, quadros perdidos, e qual MFT subiu.
//! 2. **O MP4 fragmentado do `IMFSinkWriter`** (§5.4): H.264 + AAC em
//!    `MFTranscodeContainerType_FMPEG4`, um controle finalizado e uma gravação com o processo morto no
//!    meio. O arquivo abre? Quanto se perde?
//!
//! Sem janela e sem captura: roda na Sessão 0, pelo SSH. **Mas a NVIDIA muda de resposta entre as
//! sessões**: o `ActivateObject` do MFT dela falha na sessão interativa e funcionava na Sessão 0 em
//! 30/08 (`encoder.rs`, `Preferencia::Intel`); em 24/09, pela Sessão 0, esta sonda o viu falhar
//! também (`E_UNEXPECTED`, driver 528.79). `roda-interativa.ps1` roda a mesma sonda na sessão do
//! Pessoa Exemplo, que é a do produto.
//!
//! Uso (ver `tools/sonda-r5/README.md`, seção Windows):
//!
//!     sonda-r5-w1 tudo --pasta C:\Users\pessoa-exemplo\qp-sonda-r5\saida
//!     sonda-r5-w1 dois --segundos 60
//!     sonda-r5-w1 fmp4
//!     sonda-r5-w1 ler --arquivo x.mp4
//!     sonda-r5-w1 controles --segundos 10      # onde o tempo vai: fonte, encoder, relógio
//!     sonda-r5-w1 --sem-throttling dois ...    # a parte 1 com o power throttling desligado

mod caixas;
#[cfg(windows)]
mod comum;
#[cfg(windows)]
mod controles;
#[cfg(windows)]
mod dois;
#[cfg(windows)]
mod fmp4;

#[cfg(not(windows))]
fn main() {
    eprintln!("sonda-r5-w1 só roda no Windows (o Dell da bancada). No Mac, só os testes de caixas.rs.");
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    std::process::exit(windows_main::principal());
}

#[cfg(windows)]
mod windows_main {
    use std::path::PathBuf;

    use clap::{Args, Parser, Subcommand};
    use quall_capture_probe::device::{self, PlacaDeHardware};
    use serde_json::{json, Value};
    use windows::Win32::Media::MediaFoundation::{MFShutdown, MFStartup, MFSTARTUP_FULL, MF_VERSION};
    use windows::Win32::Media::timeBeginPeriod;
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

    use crate::{controles, dois, fmp4};

    #[derive(Parser)]
    #[command(about = "S-W1 do R5: dois H.264 de hardware juntos, e o fMP4 do IMFSinkWriter depois de matar o processo.")]
    struct Cli {
        /// Desliga o power throttling do processo antes de tudo (EcoQoS e o descarte do
        /// `timeBeginPeriod`), como o produto faz para a velocidade. Ver `controles.rs`.
        #[arg(long, global = true)]
        sem_throttling: bool,
        #[command(subcommand)]
        cmd: Cmd,
    }

    #[derive(Args, Clone)]
    struct Comuns {
        /// Onde gravar o JSON e os MP4.
        #[arg(long, default_value = ".")]
        pasta: PathBuf,
        /// Só esta placa (LUID em hexa, como o relato imprime). Sem ela, todas as de hardware.
        #[arg(long)]
        placa: Option<String>,
    }

    #[derive(Subcommand)]
    enum Cmd {
        /// As duas partes, em todas as placas, com JSON e VEREDITO.
        Tudo {
            #[command(flatten)]
            c: Comuns,
            #[arg(long, default_value_t = 60.0)]
            segundos: f64,
            #[arg(long, default_value_t = 10.0)]
            sozinho: f64,
            #[arg(long, default_value_t = 10.0)]
            controle: f64,
            /// Segundos de gravação antes do tiro.
            #[arg(long, default_value_t = 20.0)]
            matar_em: f64,
        },
        /// Só a parte 1.
        Dois {
            #[command(flatten)]
            c: Comuns,
            #[arg(long, default_value_t = 60.0)]
            segundos: f64,
            #[arg(long, default_value_t = 10.0)]
            sozinho: f64,
        },
        /// Só a parte 2.
        Fmp4 {
            #[command(flatten)]
            c: Comuns,
            #[arg(long, default_value_t = 10.0)]
            controle: f64,
            #[arg(long, default_value_t = 20.0)]
            matar_em: f64,
        },
        /// (interno) O filho da parte 2: grava até acabar ou morrer.
        Gravar {
            #[arg(long)]
            arquivo: PathBuf,
            #[arg(long)]
            segundos: f64,
            #[arg(long)]
            placa: Option<String>,
            #[arg(long, default_value = "gpu")]
            origem: String,
            /// `nv12` (o formato da câmera) ou `argb` — só com a origem `gpu`.
            #[arg(long, default_value = "nv12")]
            entrada: String,
            #[arg(long, default_value_t = 1920)]
            largura: u32,
            #[arg(long, default_value_t = 1080)]
            altura: u32,
            #[arg(long, default_value_t = 30)]
            fps: u32,
            #[arg(long, default_value_t = 16_000_000)]
            bitrate: u32,
        },
        /// Controles da parte 1: só a fonte, fonte + encoder instrumentado (três variantes) e o
        /// relógio, como veio e com o throttling desligado. JSON em `sonda-r5-w1-controles.json`.
        Controles {
            #[command(flatten)]
            c: Comuns,
            #[arg(long, default_value_t = 10.0)]
            segundos: f64,
        },
        /// Lê um MP4 (caixas + IMFSourceReader) e imprime o JSON.
        Ler {
            #[arg(long)]
            arquivo: PathBuf,
        },
    }

    const GRAVACAO: dois::Perfil = dois::Perfil { rotulo: "gravação", largura: 1920, altura: 1080, fps: 30, bitrate: 16_000_000, gop: 60 };
    const REDE: dois::Perfil = dois::Perfil { rotulo: "rede", largura: 1280, altura: 720, fps: 30, bitrate: 4_000_000, gop: 30 };

    fn placas(filtro: &Option<String>) -> Vec<PlacaDeHardware> {
        let todas = device::placas_de_hardware().unwrap_or_default();
        match filtro {
            None => todas,
            Some(f) => todas.into_iter().filter(|p| format!("{:016X}", p.luid).eq_ignore_ascii_case(f.trim_start_matches("0x"))).collect(),
        }
    }

    fn sessao() -> u32 {
        let mut s = 0u32;
        unsafe {
            let _ = windows::Win32::System::RemoteDesktop::ProcessIdToSessionId(std::process::id(), &mut s);
        }
        s
    }

    fn parte1(c: &Comuns, segundos: f64, sozinho: f64) -> Vec<dois::DaPlaca> {
        placas(&c.placa).iter().map(|p| dois::medir_placa(p, GRAVACAO, REDE, sozinho, segundos)).collect()
    }

    fn parte2(c: &Comuns, controle: f64, matar_em: f64) -> Vec<Value> {
        let exe = std::env::current_exe().expect("caminho do próprio executável");
        let mut v = Vec::new();
        for p in placas(&c.placa) {
            let base = vec!["--placa".to_string(), format!("{:016X}", p.luid), "--origem".into(), "gpu".into()];
            let r = fmp4::prova(&exe, &c.pasta, p.luid, &p.descricao, true, controle, matar_em, &base, 30.0);
            v.push(r);
        }
        // O controle sem GPU: se a origem em textura falhar em alguma placa, este diz se o defeito é
        // do contêiner ou do caminho D3D.
        let base = vec!["--origem".to_string(), "memoria".into()];
        v.push(fmp4::prova(&exe, &c.pasta, 0, "(memória do sistema, o escritor escolhe o encoder)", false, controle, matar_em, &base, 30.0));
        v
    }

    fn veredito(p1: &[dois::DaPlaca], p2: &[Value]) -> String {
        let mut partes = Vec::new();
        for d in p1 {
            let juntos = d.fases.iter().find(|f| f.nome == "juntos");
            let t = match juntos {
                None => format!("{}: sem medida ({})", d.placa, d.erro.clone().unwrap_or_default()),
                Some(f) if f.erro.as_deref().is_some_and(|e| e.contains("SOZINHO")) => {
                    format!("{}: o MFT NÃO ativa nem sozinho, a pergunta dos dois não se põe ({})", d.placa, f.erro.clone().unwrap())
                }
                Some(f) if f.erro.is_some() => format!("{}: os dois NÃO sobem juntos ({})", d.placa, f.erro.clone().unwrap()),
                Some(f) => {
                    let ok = f.medidas.len() == 2
                        && f.medidas.iter().all(|m| m.fps_saida >= 29.5 && m.perdidos_na_entrada == 0 && m.perdidos_no_encoder <= 2 && m.erro.is_none());
                    let resumo = f
                        .medidas
                        .iter()
                        .map(|m| format!("{} {:.1} fps p95 {:.1} ms perdidos {}", m.rotulo, m.fps_saida, m.latencia_p95_ms, m.perdidos_na_entrada + m.perdidos_no_encoder))
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!("{}: {} ({resumo})", d.placa, if ok { "dois H.264 juntos a 30 fps SIM" } else { "dois H.264 juntos NÃO sustentam 30 fps" })
                }
            };
            partes.push(t);
        }
        for r in p2 {
            let placa = r["placa"].as_str().unwrap_or("?");
            let t = if r["erro"].is_string() {
                format!("fMP4 {placa}: controle falhou ({})", r["erro"].as_str().unwrap())
            } else {
                let m = &r["morte"];
                let abriu = m["analise"]["leitor"]["abriu"].as_bool().unwrap_or(false);
                let dec = m["analise"]["leitor_decodificando"]["video"].as_u64().unwrap_or(0);
                format!(
                    "fMP4 {placa}: morto no quadro {}, arquivo {} com {} quadros ({} decodificados), perda {:.2} s",
                    m["quadros_entregues"],
                    if abriu { "ABRE" } else { "NÃO ABRE" },
                    m["quadros_no_arquivo"],
                    dec,
                    m["segundos_perdidos"].as_f64().unwrap_or(-1.0)
                )
            };
            partes.push(t);
        }
        partes.join(" | ")
    }

    fn gravar_json(pasta: &PathBuf, v: &Value) {
        gravar_json_em(pasta, "sonda-r5-w1.json", v)
    }

    fn gravar_json_em(pasta: &PathBuf, nome: &str, v: &Value) {
        let _ = std::fs::create_dir_all(pasta);
        let arq = pasta.join(nome);
        match std::fs::write(&arq, serde_json::to_string_pretty(v).unwrap()) {
            Ok(()) => println!("\nJSON: {}", arq.display()),
            Err(e) => println!("\nJSON não gravado em {}: {e}", arq.display()),
        }
    }

    fn cabecalho() -> Value {
        let s = sessao();
        println!("== sonda-r5-w1 (S-W1 do R5) ==");
        println!("origem SINTÉTICA: texturas BGRA pintadas e um tom de 1 kHz gerado aqui — nenhuma câmera, microfone ou tela");
        println!("sessão do Windows: {s}{}", if s == 0 { " (Sessão 0, a do SSH: a ativação do MFT da NVIDIA muda de resposta entre sessões; ver o README)" } else { " (interativa)" });
        let pl: Vec<Value> = device::placas_de_hardware()
            .unwrap_or_default()
            .iter()
            .map(|p| json!({ "placa": p.descricao, "vendor": format!("0x{:04X}", p.vendor_id), "luid": format!("{:016X}", p.luid) }))
            .collect();
        for p in &pl {
            println!("placa de hardware: {} {} LUID {}", p["placa"].as_str().unwrap_or(""), p["vendor"].as_str().unwrap_or(""), p["luid"].as_str().unwrap_or(""));
        }
        json!({ "sonda": "S-W1", "sessao": s, "placas": pl, "origem": "sintetica" })
    }

    pub fn principal() -> i32 {
        let cli = Cli::parse();
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            if MFStartup(MF_VERSION, MFSTARTUP_FULL).is_err() {
                eprintln!("MFStartup falhou");
                return 1;
            }
            timeBeginPeriod(1);
        }
        if cli.sem_throttling {
            println!("power throttling desligado (EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION): {}", controles::desligar_throttling());
        }
        let codigo = match cli.cmd {
            Cmd::Gravar { arquivo, segundos, placa, origem, entrada, largura, altura, fps, bitrate } => {
                let o = fmp4::Opcoes {
                    luid: placa.and_then(|p| u64::from_str_radix(p.trim_start_matches("0x"), 16).ok()),
                    arquivo,
                    segundos,
                    largura,
                    altura,
                    fps,
                    bitrate,
                    gpu: origem == "gpu",
                    nv12: entrada == "nv12",
                };
                match fmp4::gravar(&o) {
                    Ok(()) => 0,
                    Err(e) => {
                        println!("ERRO gravar: {}", crate::comum::hr(&e));
                        3
                    }
                }
            }
            Cmd::Controles { c, segundos } => {
                let mut j = cabecalho();
                j["sem_throttling_desde_o_inicio"] = json!(cli.sem_throttling);
                j["controles"] = controles::medir(&placas(&c.placa), &[GRAVACAO, REDE], segundos, cli.sem_throttling);
                gravar_json_em(&c.pasta, "sonda-r5-w1-controles.json", &j);
                0
            }
            Cmd::Ler { arquivo } => {
                println!("{}", serde_json::to_string_pretty(&fmp4::analisar(&arquivo)).unwrap());
                0
            }
            Cmd::Dois { c, segundos, sozinho } => {
                let mut j = cabecalho();
                let p1 = parte1(&c, segundos, sozinho);
                let v = veredito(&p1, &[]);
                j["parte1"] = json!(p1);
                j["veredito"] = json!(v);
                gravar_json(&c.pasta, &j);
                println!("VEREDITO: {v}");
                0
            }
            Cmd::Fmp4 { c, controle, matar_em } => {
                let mut j = cabecalho();
                let p2 = parte2(&c, controle, matar_em);
                let v = veredito(&[], &p2);
                j["parte2"] = json!(p2);
                j["veredito"] = json!(v);
                gravar_json(&c.pasta, &j);
                println!("VEREDITO: {v}");
                0
            }
            Cmd::Tudo { c, segundos, sozinho, controle, matar_em } => {
                let mut j = cabecalho();
                let p1 = parte1(&c, segundos, sozinho);
                j["parte1"] = json!(p1);
                let p2 = parte2(&c, controle, matar_em);
                let v = veredito(&p1, &p2);
                j["parte2"] = json!(p2);
                j["veredito"] = json!(v);
                gravar_json(&c.pasta, &j);
                println!("\nVEREDITO: {v}");
                0
            }
        };
        unsafe {
            let _ = MFShutdown();
        }
        codigo
    }
}
