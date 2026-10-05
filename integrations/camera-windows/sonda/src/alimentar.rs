//! `alimentar` — o servidor do cano de quadros.
//!
//! No produto este papel é do app do Quall: ele decodifica o que vem da rede, escala para
//! 1920x1080 NV12 e escreve aqui. Nesta sonda o conteúdo é sintético, porque o que se quer medir é
//! **o custo da travessia**, não o do decode (que a Frente 6 já mediu: ~2,6 ms em hardware).

use anyhow::Result;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::cano;
use crate::medida::{estat, Estatistica};

#[derive(Serialize)]
pub struct Relatorio {
    pub clientes_atendidos: u64,
    pub quadros_escritos: u64,
    pub bytes_por_quadro: usize,
    /// Custo de um `WriteFile` do quadro inteiro no cano, em microssegundos.
    pub escrita_us: Estatistica,
}

/// `nome_da_camera` escolhe **qual** cano servir: com nome, o cano daquela câmera; sem nome, o
/// cano histórico. Ver `quall_camera_fonte::quadros::cano_do_nome`.
pub fn executar(segundos: u64, json: Option<String>, nome_da_camera: Option<String>) -> Result<()> {
    let fim = std::time::Instant::now() + std::time::Duration::from_secs(segundos);
    let parar = Arc::new(AtomicBool::new(false));
    let escritos = Arc::new(AtomicU64::new(0));
    let clientes = Arc::new(AtomicU64::new(0));
    let custos: Arc<Mutex<Vec<f64>>> = Arc::new(Mutex::new(Vec::new()));

    let cano_servido = match nome_da_camera {
        Some(n) => cano::cano_do_nome(&n),
        None => cano::CANO.to_string(),
    };
    println!("servindo cano da câmera (identificação omitida) por {segundos}s");

    // Quatro fios porque há mais de um consumidor possível ao mesmo tempo: o Frame Server abre
    // uma instância do cano, e o processo do app que consome a câmera abre outra. Cada um recebe
    // o mesmo vídeo pela sua instância.
    let mut fios = Vec::new();
    for _ in 0..4 {
        let (escritos, clientes, custos, parar) =
            (escritos.clone(), clientes.clone(), custos.clone(), parar.clone());
        let cano_servido = cano_servido.clone();
        fios.push(std::thread::spawn(move || {
            while !parar.load(Ordering::Relaxed) && std::time::Instant::now() < fim {
                let s = match cano::Servidor::esperar_cliente(&cano_servido) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("cano: {}", crate::resumo_erro(&e));
                        std::thread::sleep(std::time::Duration::from_millis(300));
                        continue;
                    }
                };
                clientes.fetch_add(1, Ordering::Relaxed);
                let t0 = std::time::Instant::now();
                let mut n = 0u64;
                loop {
                    if parar.load(Ordering::Relaxed) || std::time::Instant::now() >= fim {
                        return;
                    }
                    let alvo = t0 + std::time::Duration::from_nanos(n * 1_000_000_000 / 30);
                    let agora = std::time::Instant::now();
                    if alvo > agora {
                        std::thread::sleep(alvo - agora);
                    }
                    let mut quadro = quadro_de_teste(n);
                    let ts = cano::qpc_us();
                    // Sem `--carimbo-de-bancada` isto não escreve nada. A origem aqui é padrão
                    // sintético nosso, mas o quadro atravessa o mesmo cano e sai na mesma câmera
                    // que qualquer app da máquina abre — a chave vale igual.
                    cano::carimbar(&mut quadro, ts);
                    match s.escrever(&quadro, ts) {
                        Ok(us) => {
                            custos.lock().unwrap().push(us as f64);
                            escritos.fetch_add(1, Ordering::Relaxed);
                        }
                        // Cliente foi embora: volta a esperar outro. É o caso normal quando o app
                        // consumidor fecha a câmera.
                        Err(_) => break,
                    }
                    n += 1;
                }
            }
        }));
    }
    for f in fios {
        let _ = f.join();
    }

    let rel = Relatorio {
        clientes_atendidos: clientes.load(Ordering::Relaxed),
        quadros_escritos: escritos.load(Ordering::Relaxed),
        bytes_por_quadro: cano::BYTES_NV12,
        escrita_us: estat(custos.lock().unwrap().clone()),
    };
    let diagnostico = crate::diagnostico(&rel)?;
    println!("{}", serde_json::to_string_pretty(&diagnostico)?);
    if let Some(c) = json {
        std::fs::write(c, serde_json::to_vec_pretty(&diagnostico)?)?;
    }
    Ok(())
}

/// Padrão do **host**: uma barra horizontal que desce. É diferente do padrão da fonte de mídia
/// (barra vertical, colorida) de propósito — olhando um app, dá para dizer de olho se a imagem
/// veio do cano ou do fallback interno da fonte.
fn quadro_de_teste(n: u64) -> Vec<u8> {
    let w = cano::LARGURA as usize;
    let h = cano::ALTURA as usize;
    let mut buf = vec![0u8; cano::BYTES_NV12];
    let barra = ((n * 6) % (h as u64)) as usize;
    for y in 0..h {
        let base = y * w;
        let v = if y >= barra && y < barra + 40 {
            235u8
        } else {
            (30 + (y * 120 / h)) as u8
        };
        buf[base..base + w].fill(v);
    }
    buf[w * h..].fill(128);
    buf
}
