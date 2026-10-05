//! As caixas de um MP4, lidas do arquivo e não do que a API diz ter escrito.
//!
//! É a regra "verifique no fluxo, não no retorno da API" (`docs/regras-de-frente.md`) aplicada ao
//! arquivo: o `IMFSinkWriter` devolve `S_OK` em cada `WriteSample`, e isso não diz nada sobre o que
//! chegou ao disco quando o processo morre. Aqui se conta, direto dos bytes:
//!
//! - as caixas de topo (`ftyp`, `moov`, `moof`, `mdat`, `mfra`…) e se a última está cortada;
//! - em cada `moof` **completo e seguido do seu `mdat` completo**, as amostras de cada track (`trun`)
//!   e o começo do fragmento (`tfdt`), na escala de tempo da track (`mdhd`);
//! - num MP4 não fragmentado, as amostras do `stsz` de cada track.
//!
//! Aritmética pura, sem Win32: os testes rodam em qualquer máquina (no Mac, contra arquivos feitos
//! pelo `ffmpeg`).

use std::collections::BTreeMap;

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Track {
    pub id: u32,
    /// `vide`, `soun`, ou o que o `hdlr` disser.
    pub tipo: String,
    pub escala: u32,
    /// Amostras em fragmentos completos (`moof` + `mdat` inteiros), ou do `stsz` se não fragmentado.
    pub amostras: u64,
    /// Soma das durações das amostras contadas, em segundos.
    pub duracao_s: f64,
    /// Duração de cada fragmento desta track, em segundos (do `trun`).
    pub fragmentos_s: Vec<f64>,
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Relato {
    pub bytes: u64,
    /// As caixas de topo, na ordem, como "tipo:tamanho".
    pub topo: Vec<String>,
    pub tem_ftyp: bool,
    pub tem_moov: bool,
    pub fragmentado: bool,
    pub moofs: u32,
    /// Fragmentos cujo `moof` e `mdat` estão inteiros no arquivo.
    pub fragmentos_completos: u32,
    /// Bytes depois da última caixa inteira (a caixa cortada pela morte do processo, se houver).
    pub bytes_cortados: u64,
    pub caixa_cortada: Option<String>,
    pub tracks: Vec<Track>,
    pub erro: Option<String>,
}

fn u32_em(b: &[u8], i: usize) -> Option<u32> {
    b.get(i..i + 4).map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}

fn u64_em(b: &[u8], i: usize) -> Option<u64> {
    b.get(i..i + 8).map(|s| u64::from_be_bytes(s.try_into().unwrap()))
}

/// Uma caixa: (tipo, início do conteúdo, fim da caixa). `None` se não cabe em `b[..fim]`.
fn caixa(b: &[u8], i: usize, fim: usize) -> Result<Option<(String, usize, usize)>, (String, u64)> {
    if i + 8 > fim {
        return Ok(None);
    }
    let tam32 = u32_em(b, i).unwrap() as u64;
    let tipo = String::from_utf8_lossy(&b[i + 4..i + 8]).to_string();
    let (tam, cab) = match tam32 {
        0 => ((fim - i) as u64, 8usize),
        1 => match u64_em(b, i + 8) {
            Some(t) => (t, 16usize),
            None => return Err((tipo, (fim - i) as u64)),
        },
        t => (t, 8usize),
    };
    if tam < cab as u64 || i as u64 + tam > fim as u64 {
        return Err((tipo, (fim - i) as u64));
    }
    Ok(Some((tipo, i + cab, i + tam as usize)))
}

/// As caixas filhas de `b[ini..fim]`, ignorando o que não fecha.
fn filhas(b: &[u8], ini: usize, fim: usize) -> Vec<(String, usize, usize)> {
    let mut v = Vec::new();
    let mut i = ini;
    while let Ok(Some((t, c, f))) = caixa(b, i, fim) {
        v.push((t, c, f));
        i = f;
    }
    v
}

fn achar<'a>(v: &'a [(String, usize, usize)], tipo: &str) -> Option<&'a (String, usize, usize)> {
    v.iter().find(|(t, _, _)| t == tipo)
}

struct InfoTrack {
    tipo: String,
    escala: u32,
    duracao_padrao: u32,
    amostras_stsz: u64,
    duracao_stts: u64,
}

fn ler_trak(b: &[u8], ini: usize, fim: usize) -> Option<(u32, InfoTrack)> {
    let f = filhas(b, ini, fim);
    let tkhd = achar(&f, "tkhd")?;
    let versao = b[tkhd.1];
    let id = if versao == 1 { u32_em(b, tkhd.1 + 4 + 16)? } else { u32_em(b, tkhd.1 + 4 + 8)? };
    let mdia = achar(&f, "mdia")?;
    let fm = filhas(b, mdia.1, mdia.2);
    let mdhd = achar(&fm, "mdhd")?;
    let escala = if b[mdhd.1] == 1 { u32_em(b, mdhd.1 + 4 + 16)? } else { u32_em(b, mdhd.1 + 4 + 8)? };
    let hdlr = achar(&fm, "hdlr")?;
    let tipo = String::from_utf8_lossy(b.get(hdlr.1 + 8..hdlr.1 + 12)?).to_string();
    let mut amostras_stsz = 0u64;
    let mut duracao_stts = 0u64;
    if let Some(minf) = achar(&fm, "minf") {
        let fi = filhas(b, minf.1, minf.2);
        if let Some(stbl) = achar(&fi, "stbl") {
            let fs = filhas(b, stbl.1, stbl.2);
            if let Some(stsz) = achar(&fs, "stsz") {
                amostras_stsz = u32_em(b, stsz.1 + 8).unwrap_or(0) as u64;
            }
            if let Some(stts) = achar(&fs, "stts") {
                let n = u32_em(b, stts.1 + 4).unwrap_or(0) as usize;
                for k in 0..n {
                    let c = u32_em(b, stts.1 + 8 + k * 8).unwrap_or(0) as u64;
                    let d = u32_em(b, stts.1 + 12 + k * 8).unwrap_or(0) as u64;
                    duracao_stts += c * d;
                }
            }
        }
    }
    Some((id, InfoTrack { tipo, escala, duracao_padrao: 0, amostras_stsz, duracao_stts }))
}

/// Lê o `trex` do `mvex` (duração padrão de amostra por track), se houver.
fn ler_trex(b: &[u8], mvex: &(String, usize, usize), tracks: &mut BTreeMap<u32, InfoTrack>) {
    for (t, c, _) in filhas(b, mvex.1, mvex.2) {
        if t == "trex" {
            if let (Some(id), Some(d)) = (u32_em(b, c + 4), u32_em(b, c + 12)) {
                if let Some(tr) = tracks.get_mut(&id) {
                    tr.duracao_padrao = d;
                }
            }
        }
    }
}

/// Um `traf`: (track, amostras, soma das durações na escala da track).
fn ler_traf(b: &[u8], ini: usize, fim: usize, tracks: &BTreeMap<u32, InfoTrack>) -> Option<(u32, u64, u64)> {
    let f = filhas(b, ini, fim);
    let tfhd = achar(&f, "tfhd")?;
    let flags_h = u32_em(b, tfhd.1)? & 0x00FF_FFFF;
    let id = u32_em(b, tfhd.1 + 4)?;
    let mut p = tfhd.1 + 8;
    if flags_h & 0x01 != 0 {
        p += 8;
    }
    if flags_h & 0x02 != 0 {
        p += 4;
    }
    let mut dur_padrao = tracks.get(&id).map(|t| t.duracao_padrao).unwrap_or(0);
    if flags_h & 0x08 != 0 {
        dur_padrao = u32_em(b, p)?;
    }
    let mut amostras = 0u64;
    let mut soma = 0u64;
    for (t, c, _) in &f {
        if t != "trun" {
            continue;
        }
        let flags = u32_em(b, *c)? & 0x00FF_FFFF;
        let n = u32_em(b, c + 4)? as u64;
        amostras += n;
        let mut q = c + 8;
        if flags & 0x001 != 0 {
            q += 4;
        }
        if flags & 0x004 != 0 {
            q += 4;
        }
        let tem_dur = flags & 0x100 != 0;
        let passo = [0x100, 0x200, 0x400, 0x800].iter().filter(|m| flags & **m != 0).count() * 4;
        for k in 0..n as usize {
            let d = if tem_dur { u32_em(b, q + k * passo).unwrap_or(0) } else { dur_padrao };
            soma += d as u64;
        }
    }
    Some((id, amostras, soma))
}

/// Lê um MP4 inteiro da memória.
pub fn ler(b: &[u8]) -> Relato {
    let mut r = Relato { bytes: b.len() as u64, ..Default::default() };
    let mut tracks: BTreeMap<u32, InfoTrack> = BTreeMap::new();
    let mut contagem: BTreeMap<u32, (u64, u64, Vec<f64>)> = BTreeMap::new();
    let mut i = 0usize;
    let fim = b.len();
    // O `moof` só conta quando o `mdat` que o segue também está inteiro: é o `mdat` que carrega as
    // amostras, e um `moof` sem ele descreve bytes que não existem.
    let mut moof_pendente: Option<(usize, usize)> = None;
    loop {
        match caixa(b, i, fim) {
            Ok(None) => {
                if i < fim {
                    r.bytes_cortados = (fim - i) as u64;
                    r.caixa_cortada = Some("(cabeçalho incompleto)".into());
                }
                break;
            }
            Err((tipo, resto)) => {
                r.bytes_cortados = resto;
                r.caixa_cortada = Some(tipo);
                break;
            }
            Ok(Some((tipo, c, f))) => {
                r.topo.push(format!("{tipo}:{}", f - i));
                match tipo.as_str() {
                    "ftyp" => r.tem_ftyp = true,
                    "moov" => {
                        r.tem_moov = true;
                        let fm = filhas(b, c, f);
                        for (t, cc, ff) in &fm {
                            if t == "trak" {
                                if let Some((id, info)) = ler_trak(b, *cc, *ff) {
                                    tracks.insert(id, info);
                                }
                            }
                        }
                        if let Some(mvex) = achar(&fm, "mvex") {
                            r.fragmentado = true;
                            ler_trex(b, mvex, &mut tracks);
                        }
                    }
                    "moof" => {
                        r.moofs += 1;
                        r.fragmentado = true;
                        moof_pendente = Some((c, f));
                    }
                    "mdat" => {
                        if let Some((mc, mf)) = moof_pendente.take() {
                            r.fragmentos_completos += 1;
                            for (t, cc, ff) in filhas(b, mc, mf) {
                                if t == "traf" {
                                    if let Some((id, n, soma)) = ler_traf(b, cc, ff, &tracks) {
                                        let e = contagem.entry(id).or_default();
                                        e.0 += n;
                                        e.1 += soma;
                                        let escala = tracks.get(&id).map(|t| t.escala).unwrap_or(0);
                                        if escala > 0 {
                                            e.2.push(soma as f64 / escala as f64);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    _ => {}
                }
                i = f;
            }
        }
    }
    if !r.tem_moov {
        r.erro = Some("sem moov inteiro: nenhum leitor sabe as tracks".into());
    }
    for (id, info) in &tracks {
        let (amostras, soma, frags) = if r.fragmentado {
            contagem.get(id).cloned().unwrap_or_default()
        } else {
            (info.amostras_stsz, info.duracao_stts, Vec::new())
        };
        r.tracks.push(Track {
            id: *id,
            tipo: info.tipo.clone(),
            escala: info.escala,
            amostras,
            duracao_s: if info.escala > 0 { soma as f64 / info.escala as f64 } else { 0.0 },
            fragmentos_s: frags,
        });
    }
    r
}

#[cfg(test)]
mod testes {
    use super::*;
    use std::process::Command;

    /// Faz um MP4 com o `ffmpeg` do Mac: 3 s de 30 fps, e som. `None` sem `ffmpeg` (o teste se
    /// apaga, dizendo).
    fn gerar(frag: bool) -> Option<Vec<u8>> {
        let dir = std::env::temp_dir().join(format!("sonda-r5-caixas-{}-{frag}", std::process::id()));
        std::fs::create_dir_all(&dir).ok()?;
        let saida = dir.join("t.mp4");
        let mut c = Command::new("ffmpeg");
        c.args(["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=3"]);
        c.args(["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=3"]);
        c.args(["-c:v", "libx264", "-g", "30", "-c:a", "aac"]);
        if frag {
            c.args(["-movflags", "frag_keyframe+empty_moov+default_base_moof"]);
        }
        c.arg(&saida);
        let ok = c.status().ok()?.success();
        if !ok {
            return None;
        }
        std::fs::read(&saida).ok()
    }

    #[test]
    fn nao_fragmentado_conta_pelo_stsz() {
        let Some(b) = gerar(false) else { eprintln!("sem ffmpeg: teste pulado"); return };
        let r = ler(&b);
        assert!(r.tem_moov && !r.fragmentado, "{r:?}");
        let v = r.tracks.iter().find(|t| t.tipo == "vide").unwrap();
        assert_eq!(v.amostras, 90);
        assert!((v.duracao_s - 3.0).abs() < 0.05, "{v:?}");
        assert!(r.tracks.iter().any(|t| t.tipo == "soun"));
    }

    #[test]
    fn fragmentado_inteiro_e_cortado() {
        let Some(b) = gerar(true) else { eprintln!("sem ffmpeg: teste pulado"); return };
        let r = ler(&b);
        assert!(r.fragmentado && r.tem_moov, "{r:?}");
        assert_eq!(r.bytes_cortados, 0);
        let v = r.tracks.iter().find(|t| t.tipo == "vide").unwrap();
        assert_eq!(v.amostras, 90, "{r:?}");
        assert!((v.duracao_s - 3.0).abs() < 0.05, "{v:?}");
        assert!(r.fragmentos_completos >= 3, "{r:?}");

        // Corta no meio do último `mdat`: aquele fragmento sai da conta, os anteriores ficam.
        let corte = b.len() - 200;
        let c = ler(&b[..corte]);
        assert!(c.bytes_cortados > 0 && c.caixa_cortada.as_deref() == Some("mdat"), "{c:?}");
        let vc = c.tracks.iter().find(|t| t.tipo == "vide").unwrap();
        assert!(vc.amostras < 90 && vc.amostras >= 30, "{vc:?}");
        assert_eq!(c.fragmentos_completos, r.fragmentos_completos - 1);
    }
}
