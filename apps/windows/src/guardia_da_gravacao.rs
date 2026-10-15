//! Continuidade por access unit: não grava quadros P com referência faltando.
use crate::sps::{self, Bits};
#[derive(Clone, Copy)]
struct Parametros {
    bits: u32,
    separado: bool,
    progressivo: bool,
}
pub struct Guardia {
    sps: [Option<Parametros>; 32],
    pps: [Option<usize>; 256],
    ultimo: Option<u32>,
    quebrada: bool,
}
impl Default for Guardia {
    fn default() -> Self {
        Self {
            sps: [None; 32],
            pps: [None; 256],
            ultimo: None,
            quebrada: true,
        }
    }
}
fn nals(bytes: &[u8]) -> Vec<&[u8]> {
    let mut inicios = Vec::new();
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n = if bytes[i..].starts_with(&[0, 0, 0, 1]) {
            4
        } else if bytes[i..].starts_with(&[0, 0, 1]) {
            3
        } else {
            i += 1;
            continue;
        };
        inicios.push((i, i + n));
        i += n;
    }
    inicios
        .iter()
        .enumerate()
        .filter_map(|(k, (_, c))| {
            let fim = inicios.get(k + 1).map(|x| x.0).unwrap_or(bytes.len());
            (*c < fim).then_some(&bytes[*c..fim])
        })
        .collect()
}
impl Guardia {
    pub fn romper(&mut self) {
        self.quebrada = true;
    }
    pub fn aceitar(&mut self, bytes: &[u8]) -> bool {
        let r = self.ler(bytes);
        if !r {
            self.quebrada = true;
        }
        r
    }
    fn ler(&mut self, bytes: &[u8]) -> bool {
        let mut quadro: Option<(u32, bool, bool, u32)> = None;
        for nal in nals(bytes) {
            let tipo = nal[0] & 31;
            match tipo {
                7 => {
                    let Some(s) = sps::analisar(nal) else {
                        return false;
                    };
                    self.sps[s.sps_id as usize] = Some(Parametros {
                        bits: s.bits_frame_num,
                        separado: s.separate_colour_plane,
                        progressivo: s.frame_mbs_only,
                    });
                }
                8 => {
                    let rbsp = sps::desescapar(&nal[1..]);
                    let mut b = Bits::new(&rbsp);
                    let (Some(p), Some(s)) = (b.ue(), b.ue()) else {
                        return false;
                    };
                    if p >= 256 || s >= 32 {
                        return false;
                    };
                    self.pps[p as usize] = Some(s as usize);
                }
                1 | 5 => {
                    let rbsp = sps::desescapar(&nal[1..nal.len().min(129)]);
                    let mut b = Bits::new(&rbsp);
                    let (Some(_mb), Some(slice), Some(pps)) = (b.ue(), b.ue(), b.ue()) else {
                        return false;
                    };
                    if pps >= 256 || slice > 9 {
                        return false;
                    };
                    let Some(si) = self.pps[pps as usize] else {
                        return false;
                    };
                    let Some(ps) = self.sps[si] else { return false };
                    if !ps.progressivo {
                        return false;
                    };
                    if ps.separado && b.u(2).is_none() {
                        return false;
                    };
                    let Some(numero) = b.u(ps.bits as usize) else {
                        return false;
                    };
                    let referencia = (nal[0] >> 5) & 3 != 0;
                    let idr = tipo == 5;
                    if let Some((anterior, r, i, modulo)) = quadro {
                        if anterior != numero
                            || r != referencia
                            || i != idr
                            || modulo != (1 << ps.bits)
                        {
                            return false;
                        }
                    } else {
                        quadro = Some((numero, referencia, idr, 1 << ps.bits));
                    }
                }
                6 | 9 | 10 | 11 | 12 => {}
                _ => return false,
            }
        }
        let Some((numero, referencia, idr, modulo)) = quadro else {
            return false;
        };
        if idr {
            if numero != 0 {
                return false;
            };
            self.ultimo = Some(0);
            self.quebrada = false;
            return true;
        }
        if self.quebrada {
            return false;
        };
        if referencia {
            if self.ultimo.is_none_or(|n| (n + 1) % modulo != numero) {
                return false;
            };
            self.ultimo = Some(numero);
        }
        true
    }
}
#[cfg(test)]
mod testes {
    use super::*;
    fn fatia(numero: u8, referencia: bool) -> Vec<u8> {
        vec![
            0,
            0,
            1,
            if referencia { 0x61 } else { 0x01 },
            0xe0 | (numero << 1),
        ]
    }
    fn pronta() -> Guardia {
        let mut g = Guardia::default();
        g.sps[0] = Some(Parametros {
            bits: 4,
            separado: false,
            progressivo: true,
        });
        g.pps[0] = Some(0);
        g.ultimo = Some(0);
        g.quebrada = false;
        g
    }
    #[test]
    fn perda_bloqueia_ate_idr_e_wrap_funciona() {
        let mut g = pronta();
        assert!(g.aceitar(&fatia(1, true)));
        assert!(!g.aceitar(&fatia(3, true)));
        assert!(!g.aceitar(&fatia(4, true)));
        let mut g = pronta();
        g.ultimo = Some(15);
        assert!(g.aceitar(&fatia(0, true)));
    }
    #[test]
    fn nao_referencia_nao_avanca_e_varias_fatias_sao_um_quadro() {
        let mut g = pronta();
        assert!(g.aceitar(&fatia(1, false)));
        let mut q = fatia(1, true);
        q.extend_from_slice(&fatia(1, true));
        assert!(g.aceitar(&q));
        assert!(g.aceitar(&fatia(2, true)));
    }
    #[test]
    fn sintaxe_desconhecida_se_fecha() {
        let mut g = pronta();
        assert!(!g.aceitar(&[0, 0, 1, 0x62, 0]));
        assert!(!g.aceitar(&fatia(1, true)));
    }
}
