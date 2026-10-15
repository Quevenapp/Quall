//! **A claquete** (`docs/som-no-receptor.md` §9.2): um evento que aparece na imagem e no som ao
//! mesmo tempo capturado, para medir o Δ = t_som − t_imagem **por evento**, sem depender do relógio
//! comum.
//!
//! - **O som**: um estouro de 10 ms a **3 150 Hz**. O que o separa do tom de fundo é a
//!   **distância**: as notas (400, 500, 800 e 1 000 Hz) ficam todas a mais de 2 kHz, e o lóbulo
//!   principal da janela de Hann de 2 ms do detector tem ±1 kHz — "fora da grade de 100 Hz" não
//!   separa nada (crítica 10, m6). E o **silêncio**: o tom é calado por ±40 ms em volta do estouro,
//!   com **rampas de cosseno de 4 ms** nas bordas do silêncio. O corte seco, numa fase qualquer do
//!   tom, dava 0,054 no detector, acima do limiar baixo (0,05); a rampa tira o degrau. As bordas do
//!   estouro ficam secas de propósito: o começo dele é o instante que se mede.
//! - **A imagem**: o quadro de vídeo cujo carimbo é o primeiro a passar do instante do evento. Ele é
//!   reconhecido pelo **índice da régua** que a origem sintética desenha em todo quadro
//!   (`apps/ios/Quall/Ferramentas/gerar-fonte.swift`, módulo 256) — e não por um clarão novo: a
//!   origem já carrega o índice, e reconhecer pelo índice sobrevive à perda de vídeo (o quadro
//!   depois do IDR é reconhecido pelo número, e não vira ponto fora da curva).
//! - **O deslocamento de propósito**: cada evento sorteia 0 ou +40 ms entre a imagem e o som, da
//!   mesma semente. A diferença entre as duas classes tem de dar 40 ms ± o erro da testemunha: é o
//!   controle 1 do §9.3, que separa o erro do método do Δ verdadeiro.
//! - Os intervalos entre eventos são de 700 a 1 300 ms, da mesma semente.
//!
//! A verdade de cada evento vai para um `.json` (`--claquete-saida`): o instante programado, o
//! deslocamento, o quadro de vídeo marcado e o carimbo dele. No momento da captura, o estouro está
//! `t + deslocamento − carimbo_do_quadro` depois do quadro — é isso que o Δ medido tem de descontar.

use std::path::PathBuf;

use quall_core::error::{Error, Result};

pub const FREQUENCIA_DO_ESTOURO_HZ: f64 = 3150.0;
pub const DURACAO_DO_ESTOURO_US: u64 = 10_000;
pub const SILENCIO_EM_VOLTA_US: u64 = 40_000;
const AMPLITUDE: f64 = 0.5;
const PRIMEIRO_EVENTO_US: u64 = 2_000_000;
const INTERVALO_MINIMO_US: u64 = 700_000;
const INTERVALO_VARIAVEL_US: u64 = 600_000;
const DESLOCAMENTO_DE_PROPOSITO_US: u64 = 40_000;
/// As rampas nas bordas do silêncio em volta do estouro (crítica 10, m6).
pub const RAMPA_DO_SILENCIO_US: u64 = 4_000;

/// O ganho do tom de fundo a `distancia_us` do centro do estouro: 0 no miolo do silêncio, 1 fora
/// dele, e um cosseno levantado de `RAMPA_DO_SILENCIO_US` entre os dois.
fn ganho_do_tom(distancia_us: f64) -> f64 {
    let fim = SILENCIO_EM_VOLTA_US as f64;
    let miolo = fim - RAMPA_DO_SILENCIO_US as f64;
    if distancia_us >= fim {
        1.0
    } else if distancia_us <= miolo {
        0.0
    } else {
        let x = (distancia_us - miolo) / RAMPA_DO_SILENCIO_US as f64;
        0.5 - 0.5 * (std::f64::consts::PI * x).cos()
    }
}

/// Um evento: o instante programado (µs desde o início da emissão, no relógio de mídia do som, que
/// é o mesmo `inicio` do vídeo), o deslocamento de propósito, e o quadro de vídeo que o marcou.
#[derive(Debug, Clone)]
pub struct Evento {
    pub t_us: u64,
    pub desloc_us: u64,
    /// `(índice do quadro no arquivo, carimbo do vídeo em µs)`, quando o vídeo passou por ele.
    pub quadro: Option<(usize, u64)>,
}

impl Evento {
    /// Onde o estouro começa, no relógio de mídia do som.
    pub fn estouro_us(&self) -> u64 {
        self.t_us + self.desloc_us
    }
}

pub struct Claquete {
    pub semente: u64,
    pub eventos: Vec<Evento>,
    saida: Option<PathBuf>,
}

/// splitmix64: o sorteio determinístico a partir da semente, que vai impressa.
fn misturar(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

impl Claquete {
    /// Os eventos até `ate_us`, sorteados da `semente`.
    pub fn nova(semente: u64, ate_us: u64, saida: Option<PathBuf>) -> Self {
        let mut eventos = Vec::new();
        let mut t = PRIMEIRO_EVENTO_US;
        let mut k = 0u64;
        while t < ate_us {
            let a = misturar(semente ^ k.wrapping_mul(2));
            let b = misturar(semente ^ k.wrapping_mul(2).wrapping_add(1));
            eventos.push(Evento {
                t_us: t,
                desloc_us: if b & 1 == 1 { DESLOCAMENTO_DE_PROPOSITO_US } else { 0 },
                quadro: None,
            });
            t += INTERVALO_MINIMO_US + a % (INTERVALO_VARIAVEL_US + 1);
            k += 1;
        }
        Claquete {
            semente,
            eventos,
            saida,
        }
    }

    /// Edita o PCM de um quadro de som que começa em `inicio_us` (tempo de mídia): cala o tom
    /// perto dos estouros, com rampa nas bordas, e escreve os estouros. `pcm` é intercalado, com
    /// `canais` canais.
    pub fn editar_som(&self, pcm: &mut [i16], canais: usize, taxa_hz: u32, inicio_us: u64) {
        let canais = canais.max(1);
        let n = pcm.len() / canais;
        let dur_us = n as u64 * 1_000_000 / u64::from(taxa_hz);
        let fim_us = inicio_us + dur_us;
        for e in &self.eventos {
            let comeco = e.estouro_us();
            let centro = comeco + DURACAO_DO_ESTOURO_US / 2;
            if centro + SILENCIO_EM_VOLTA_US < inicio_us || centro > fim_us + SILENCIO_EM_VOLTA_US {
                continue;
            }
            for i in 0..n {
                // A hora da amostra em µs, com resolução de amostra.
                let ts = inicio_us * u64::from(taxa_hz) / 1_000_000 + i as u64;
                let t_us = ts * 1_000_000 / u64::from(taxa_hz);
                let distancia = t_us.abs_diff(centro);
                if distancia >= SILENCIO_EM_VOLTA_US {
                    continue;
                }
                // A distância com a fração de amostra, para a rampa não andar em degraus de µs.
                let t_exato = ts as f64 * 1e6 / f64::from(taxa_hz);
                let ganho = ganho_do_tom((t_exato - centro as f64).abs());
                let estouro = if t_us >= comeco && t_us < comeco + DURACAO_DO_ESTOURO_US {
                    let dt = (ts - comeco * u64::from(taxa_hz) / 1_000_000) as f64 / f64::from(taxa_hz);
                    (2.0 * std::f64::consts::PI * FREQUENCIA_DO_ESTOURO_HZ * dt).sin()
                        * AMPLITUDE
                        * f64::from(i16::MAX)
                } else {
                    0.0
                };
                for c in 0..canais {
                    let k = i * canais + c;
                    pcm[k] = (f64::from(pcm[k]) * ganho + estouro).round() as i16;
                }
            }
        }
    }

    /// O vídeo vai mandar o quadro `indice` do arquivo com `carimbo_us`: marca os eventos cujo
    /// instante ele passou. Devolve quantos marcou agora (o chamador grava a verdade quando > 0).
    pub fn marcar_video(&mut self, indice: usize, carimbo_us: u64) -> usize {
        let mut novos = 0;
        for e in self.eventos.iter_mut().filter(|e| e.quadro.is_none() && e.t_us <= carimbo_us) {
            e.quadro = Some((indice, carimbo_us));
            novos += 1;
        }
        novos
    }

    pub fn marcados(&self) -> usize {
        self.eventos.iter().filter(|e| e.quadro.is_some()).count()
    }

    /// A verdade dos eventos marcados, em JSON, para o detector. Chamada a cada evento marcado:
    /// escreve num `.tmp` e renomeia, para quem lê nunca ver meio arquivo (crítica 10, M6).
    pub fn gravar(&self) -> Result<()> {
        let Some(saida) = &self.saida else {
            return Ok(());
        };
        let eventos: Vec<serde_json::Value> = self
            .eventos
            .iter()
            .enumerate()
            .filter_map(|(k, e)| {
                e.quadro.map(|(q, c)| {
                    serde_json::json!({
                        "e": k,
                        "t_us": e.t_us,
                        "desloc_us": e.desloc_us,
                        "estouro_us": e.estouro_us(),
                        "quadro": q,
                        "regua": q % 256,
                        "carimbo_video_us": c,
                        // Na captura, o estouro está isto depois do quadro.
                        "verdade_us": e.estouro_us() as i64 - c as i64,
                    })
                })
            })
            .collect();
        let json = serde_json::json!({
            "semente": self.semente,
            "frequencia_hz": FREQUENCIA_DO_ESTOURO_HZ,
            "duracao_us": DURACAO_DO_ESTOURO_US,
            "eventos": eventos,
        });
        let mut temporario = saida.clone().into_os_string();
        temporario.push(".tmp");
        let temporario = PathBuf::from(temporario);
        std::fs::write(&temporario, serde_json::to_vec_pretty(&json).unwrap_or_default())
            .and_then(|()| std::fs::rename(&temporario, saida))
            .map_err(|e| Error::Invalid(format!("gravar a claquete em {}: {e}", saida.display())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_semente_repete_os_eventos_e_os_intervalos_ficam_na_faixa() {
        let a = Claquete::nova(42, 60_000_000, None);
        let b = Claquete::nova(42, 60_000_000, None);
        assert_eq!(a.eventos.len(), b.eventos.len());
        assert!(a.eventos.len() > 40);
        for w in a.eventos.windows(2) {
            let d = w[1].t_us - w[0].t_us;
            assert!((700_000..=1_300_000).contains(&d), "{d}");
        }
        let com = a.eventos.iter().filter(|e| e.desloc_us == 40_000).count();
        assert!(com > 10 && com < a.eventos.len() - 10, "as duas classes aparecem: {com}");
    }

    #[test]
    fn o_estouro_sai_no_lugar_e_o_tom_cala_em_volta() {
        let c = Claquete {
            semente: 0,
            eventos: vec![Evento {
                t_us: 1_000_000,
                desloc_us: 40_000,
                quadro: None,
            }],
            saida: None,
        };
        // Um quadro de 20 ms a 48 kHz, estéreo, que contém o estouro (1,040 s a 1,050 s).
        let mut pcm = vec![1000i16; 960 * 2];
        c.editar_som(&mut pcm, 2, 48_000, 1_040_000);
        // Os primeiros 10 ms (480 amostras) são o estouro; o resto do quadro, silêncio.
        let energia: f64 = (0..480).map(|i| f64::from(pcm[i * 2]).powi(2)).sum();
        assert!(energia > 1e9, "o estouro saiu: {energia}");
        assert!((480..960).all(|i| pcm[i * 2] == 0), "o tom cala depois do estouro");
        assert_eq!(pcm[1], pcm[0], "os dois canais levam o mesmo estouro");
        // Um quadro longe do estouro fica intocado.
        let mut longe = vec![1000i16; 960];
        c.editar_som(&mut longe, 1, 48_000, 2_000_000);
        assert!(longe.iter().all(|&v| v == 1000));
        // Um quadro 30 ms antes do estouro: calado (±40 ms em volta do centro).
        let mut antes = vec![1000i16; 960];
        c.editar_som(&mut antes, 1, 48_000, 1_010_000);
        assert!(antes[900..].iter().all(|&v| v == 0), "o fim do quadro já cala");
    }

    #[test]
    fn o_video_marca_o_primeiro_quadro_que_passa_do_evento() {
        let mut c = Claquete::nova(7, 5_000_000, None);
        let t0 = c.eventos[0].t_us;
        assert_eq!(c.marcar_video(59, t0 - 1_000), 0);
        assert_eq!(c.marcados(), 0);
        assert_eq!(c.marcar_video(60, t0 + 12_000), 1);
        assert_eq!(c.eventos[0].quadro, Some((60, t0 + 12_000)));
        assert_eq!(c.marcar_video(61, t0 + 45_000), 0);
        assert_eq!(c.eventos[0].quadro, Some((60, t0 + 12_000)), "o primeiro fica");
    }

    /// Crítica 10, m6: o corte seco do tom, numa fase qualquer, era um degrau que o detector via
    /// (0,054, acima do limiar baixo). Com a rampa, o tom entra e sai sem degrau.
    #[test]
    fn o_silencio_entra_e_sai_em_rampa() {
        let c = Claquete {
            semente: 0,
            eventos: vec![Evento {
                t_us: 1_000_000,
                desloc_us: 0,
                quadro: None,
            }],
            saida: None,
        };
        // 120 ms de um tom de 1 kHz a 48 kHz, de 0,94 s a 1,06 s: cobre o silêncio inteiro (o
        // centro do estouro é 1,005 s; o silêncio vai de 0,965 s a 1,045 s).
        let n = 5_760;
        let tom = |i: usize| {
            (8_000.0 * (2.0 * std::f64::consts::PI * 1_000.0 * i as f64 / 48_000.0 + 0.7).sin()) as i16
        };
        let mut pcm: Vec<i16> = (0..n).map(tom).collect();
        c.editar_som(&mut pcm, 1, 48_000, 940_000);
        // O maior salto entre amostras vizinhas fora do estouro não passa do do próprio tom
        // (8 000 × 2π × 1 000 / 48 000 ≈ 1 047).
        let estouro = (1_000_000 - 940_000) * 48 / 1_000..(1_010_000 - 940_000) * 48 / 1_000;
        let maior = (1..n)
            .filter(|i| !estouro.contains(i) && !estouro.contains(&(i - 1)))
            .map(|i| (i32::from(pcm[i]) - i32::from(pcm[i - 1])).abs())
            .max()
            .unwrap();
        assert!(maior <= 1_050, "salto de {maior}: a borda do silêncio ainda tem degrau");
        // O miolo cala; fora do silêncio, o tom fica intacto.
        let miolo = (970_000 - 940_000) * 48 / 1_000;
        assert_eq!(pcm[miolo], 0);
        assert_eq!(pcm[10], tom(10));
        // No meio da rampa (2 ms dentro da borda), o ganho é ~0,5.
        let meio = (967_000 - 940_000) * 48 / 1_000;
        let razao = f64::from(pcm[meio]) / f64::from(tom(meio));
        assert!((razao - 0.5).abs() < 0.02, "ganho no meio da rampa: {razao}");
    }
}
