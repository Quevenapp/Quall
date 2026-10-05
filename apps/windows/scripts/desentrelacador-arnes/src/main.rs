//! Arnês de igualdade (22/09): o `desentrelacador.rs` do app, incluído como está, contra a referência
//! em C (`ref-planar.c`, que inclui o `dv-bancada.c` da frente do S24 sem mudança). Roda no Mac; o
//! módulo não usa nada do Windows. Ver `compara.sh`.
//!
//!     desentrelacador-arnes sintetico N ARQ          # a sequência do teste, em yuv411p
//!     desentrelacador-arnes rust ENT SAI [cima]      # o adapt2 do app sobre quadros yuv411p
//!     desentrelacador-arnes fnv ARQ                  # o FNV-1a de cada quadro (o GOLDEN_C do teste)
#[path = "../../../src/desentrelacador.rs"]
#[allow(dead_code)]
mod desentrelacador;
use desentrelacador::*;
use std::io::Write;

const W: usize = 720;
const H: usize = 480;
const CW: usize = 180;
const T: usize = W * H + 2 * CW * H;

fn fnv(d: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in d {
        h = (h ^ *b as u64).wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("sintetico") => {
            let n: usize = a[2].parse().expect("N");
            let mut f = std::fs::File::create(&a[3]).expect("criar");
            for (y, u, v) in sequencia_sintetica_411(n) {
                f.write_all(&y).unwrap();
                f.write_all(&u).unwrap();
                f.write_all(&v).unwrap();
            }
        }
        Some("rust") => {
            let d = std::fs::read(&a[2]).expect("ler");
            let ordem = if a.get(4).map(|s| s == "cima").unwrap_or(false) { Ordem::CampoDeCimaPrimeiro } else { Ordem::CampoDeBaixoPrimeiro };
            let mut des = Desentrelacador::novo(W, H, 4, ordem).expect("geometria");
            let mut f = std::io::BufWriter::new(std::fs::File::create(&a[3]).expect("criar"));
            let t0 = std::time::Instant::now();
            for q in d.chunks_exact(T) {
                des.planar(&q[..W * H], W, &q[W * H..W * H + CW * H], &q[W * H + CW * H..], CW);
                let (y, u, v) = des.saida_planar();
                f.write_all(y).unwrap();
                f.write_all(u).unwrap();
                f.write_all(v).unwrap();
            }
            eprintln!("{} quadros, {:.3} ms/quadro", des.quadros, t0.elapsed().as_secs_f64() * 1000.0 / des.quadros.max(1) as f64);
        }
        Some("fnv") => {
            let d = std::fs::read(&a[2]).expect("ler");
            let v: Vec<String> = d.chunks_exact(T).map(|q| format!("0x{:016x}", fnv(q))).collect();
            println!("[{}]", v.join(", "));
        }
        _ => {
            eprintln!("uso: sintetico N ARQ | rust ENT SAI [cima] | fnv ARQ");
            std::process::exit(2);
        }
    }
}
