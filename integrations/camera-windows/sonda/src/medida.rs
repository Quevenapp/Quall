//! Estatística mínima, no formato que o resto do projeto já usa (média / p50 / p95 / máx).

use serde::Serialize;

#[derive(Serialize, Clone, Default)]
pub struct Estatistica {
    pub amostras: usize,
    pub media: f64,
    pub p50: f64,
    pub p95: f64,
    pub max: f64,
}

pub fn estat(mut v: Vec<f64>) -> Estatistica {
    if v.is_empty() {
        return Estatistica { amostras: 0, media: 0.0, p50: 0.0, p95: 0.0, max: 0.0 };
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let media = v.iter().sum::<f64>() / v.len() as f64;
    let idx = |q: f64| v[((v.len() as f64 - 1.0) * q).round() as usize];
    Estatistica {
        amostras: v.len(),
        media,
        p50: idx(0.5),
        p95: idx(0.95),
        max: *v.last().unwrap(),
    }
}
