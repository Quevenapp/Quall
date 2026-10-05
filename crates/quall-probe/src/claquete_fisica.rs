//! **`receber-claquete`**: o gravador da claquete física do R5 (G4 de
//! `docs/teleprompter-com-camera.md` §8 e §8.4, passo B).
//!
//! Um emissor de verdade (câmera + track `MICROPHONE`) filma a Claquete R5 do iPad, que pisca a
//! tela e toca um bipe de 3 150 Hz. Esta sonda recebe as duas tracks e grava, **sem decodificar a
//! imagem e sem abrir quadro nenhum**, o que o analisador (`tools/claquete-fisica/analisar.py`)
//! precisa para achar o clarão e o bipe no **relógio comum** da sessão (`quall_core::relogio`):
//!
//! | arquivo | o quê |
//! |---|---|
//! | `P.h264` | o Annex-B da câmera, a partir do primeiro IDR com SPS+PPS (antes dele nenhum decodificador tira imagem, e um quadro a mais no arquivo desalinharia o sidecar) |
//! | `P.quadros.csv` | um quadro por linha, **na ordem do arquivo**: `indice,pos,bytes,timestamp_us,idr`. `pos` é o byte onde o quadro começa no `.h264`: é por ele que o analisador casa cada imagem decodificada com o seu carimbo |
//! | `P.som.pcm` | o som decodificado, `i16` little-endian intercalado, na ordem de chegada |
//! | `P.som.csv` | um pacote por linha: `seq,timestamp_us,amostra,amostras` (a primeira amostra do pacote no `.pcm`, por canal, e quantas) |
//! | `P.json` | o codec, a taxa, os canais, o **atraso do conteúdo** do codec (Opus: 6,5 ms, `CodecDeAudio::atraso_do_conteudo_us`), o **deslocamento de captura** final de cada track e a série dele ao longo da corrida |
//!
//! A captura no relógio comum é `timestamp_us + deslocamento` de cada track. O deslocamento é lido
//! a cada 0,5 s pelo laço principal, e não de dentro dos tratadores (que rodam na thread da
//! libdatachannel e não têm a track): o analisador usa o final e recusa a corrida se a série andou
//! mais de 1 ms, ou se o status não chegou a `valido`.
//!
//! O que esta sonda **não** faz: tocar o som, decodificar a imagem, ou julgar a sincronia. O
//! juízo é do analisador, que é reproduzível sobre os arquivos.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use quall_core::error::{Error, Result};
use quall_core::relogio::DeslocamentoDeCaptura;
use quall_core::rtp;
use quall_core::session::Ready;
use quall_core::track::{CodecDeAudio, QuadroCodificado, QuadroDeAudio};

/// O prefixo dos arquivos: `--saida /tmp/r5-claq` ou `--saida /tmp/r5-claq.h264` dão o mesmo.
fn prefixo(saida: &Path) -> PathBuf {
    match saida.extension().and_then(|e| e.to_str()) {
        Some("h264") | Some("json") => saida.with_extension(""),
        _ => saida.to_path_buf(),
    }
}

fn com_sufixo(p: &Path, sufixo: &str) -> PathBuf {
    let mut s = p.as_os_str().to_owned();
    s.push(sufixo);
    PathBuf::from(s)
}

#[derive(Default)]
struct Imagem {
    /// Já passou o primeiro IDR com SPS+PPS: daí em diante tudo vai para o arquivo.
    abriu: bool,
    antes_do_idr: u64,
    quadros: u64,
    idrs: u64,
    pos: u64,
}

#[derive(Default)]
struct Som {
    pacotes: u64,
    amostras: u64,
    falhas: u64,
    buracos_de_seq: u64,
    fora_de_ordem: u64,
    ultima_seq: Option<u16>,
}

enum Decodificador {
    #[cfg(feature = "opus")]
    Opus(quall_opus::Decodificador),
    Pcmu,
}

fn deslocamento_us(d: &DeslocamentoDeCaptura) -> (String, Option<i64>) {
    match d {
        DeslocamentoDeCaptura::Ainda => ("ainda".into(), None),
        DeslocamentoDeCaptura::Valido { us } => ("valido".into(), Some(*us)),
        DeslocamentoDeCaptura::Recusado { motivo } => (format!("recusado: {motivo}"), None),
    }
}

pub fn receber(mut pronto: Ready, saida: &Path, segundos: Duration) -> Result<()> {
    println!();
    println!("claquete física: esperando a track de vídeo e a de som…");
    let (video, som) = crate::video::esperar_video_e_som(&mut pronto)?;
    let Some(som) = som else {
        return Err(Error::Invalid(
            "a sessão não trouxe track de som: sem microfone na oferta não há claquete".into(),
        ));
    };
    let codec = som
        .codec_de_audio()
        .ok_or_else(|| Error::Invalid("a track de som não tem codec de áudio".into()))?;
    let taxa = codec.relogio_hz();
    let canais = codec.canais_no_fio(som.kind().preset_de_audio().map(|p| p.canais).unwrap_or(1));
    let amostras_por_quadro = codec.amostras_por_quadro(20);
    println!(
        "  vídeo : {:?} [{}] {}",
        video.kind(),
        video.mid(),
        video.label()
    );
    println!(
        "  som   : {:?} [{}] {} — {codec:?} {taxa} Hz, {canais} canal(is), atraso do conteúdo {} µs",
        som.kind(),
        som.mid(),
        som.label(),
        codec.atraso_do_conteudo_us()
    );

    let p = prefixo(saida);
    let caminho_h264 = com_sufixo(&p, ".h264");
    let caminho_quadros = com_sufixo(&p, ".quadros.csv");
    let caminho_pcm = com_sufixo(&p, ".som.pcm");
    let caminho_pacotes = com_sufixo(&p, ".som.csv");
    let caminho_json = com_sufixo(&p, ".json");

    let h264 = Arc::new(Mutex::new(BufWriter::new(File::create(&caminho_h264)?)));
    let quadros = Arc::new(Mutex::new(BufWriter::new(File::create(&caminho_quadros)?)));
    let pcm = Arc::new(Mutex::new(BufWriter::new(File::create(&caminho_pcm)?)));
    let pacotes = Arc::new(Mutex::new(BufWriter::new(File::create(&caminho_pacotes)?)));
    if let Ok(mut q) = quadros.lock() {
        writeln!(q, "indice,pos,bytes,timestamp_us,idr")?;
    }
    if let Ok(mut q) = pacotes.lock() {
        writeln!(q, "seq,timestamp_us,amostra,amostras")?;
    }
    let imagem = Arc::new(Mutex::new(Imagem::default()));
    let estado_som = Arc::new(Mutex::new(Som::default()));

    {
        let (h264, quadros, imagem) =
            (Arc::clone(&h264), Arc::clone(&quadros), Arc::clone(&imagem));
        video.ao_receber_quadro(move |q: QuadroCodificado<'_>| {
            let Ok(mut e) = imagem.lock() else { return };
            if !e.abriu {
                if q.idr && q.tem_parametros() {
                    e.abriu = true;
                } else {
                    e.antes_do_idr += 1;
                    return;
                }
            }
            let (Ok(mut f), Ok(mut c)) = (h264.lock(), quadros.lock()) else {
                return;
            };
            if f.write_all(q.annexb).is_err() {
                return;
            }
            let _ = writeln!(
                c,
                "{},{},{},{},{}",
                e.quadros,
                e.pos,
                q.annexb.len(),
                q.timestamp_us,
                u8::from(q.idr)
            );
            e.pos += q.annexb.len() as u64;
            e.quadros += 1;
            if q.idr {
                e.idrs += 1;
            }
        });
    }

    {
        let dec = match codec {
            #[cfg(feature = "opus")]
            CodecDeAudio::Opus => Decodificador::Opus(
                quall_opus::Decodificador::novo(taxa, canais)
                    .map_err(|e| Error::Invalid(format!("criar decoder de Opus: {e}")))?,
            ),
            #[cfg(not(feature = "opus"))]
            CodecDeAudio::Opus => {
                return Err(Error::Invalid(
                    "sonda construída sem a feature `opus`".into(),
                ))
            }
            CodecDeAudio::Pcmu => Decodificador::Pcmu,
        };
        let (pcm, pacotes, estado) = (
            Arc::clone(&pcm),
            Arc::clone(&pacotes),
            Arc::clone(&estado_som),
        );
        let canais_us = usize::from(canais.max(1));
        // Com folga: um pacote de Opus pode trazer até 120 ms.
        let buf = vec![0i16; amostras_por_quadro.max(1) * 6 * canais_us];
        // O tratador é `Fn`: o decoder (que tem estado) e o buffer moram atrás de um cadeado.
        let decodificacao = Mutex::new((dec, buf));
        som.ao_receber_audio(move |a: QuadroDeAudio<'_>| {
            let Ok(mut e) = estado.lock() else { return };
            let Ok(mut g) = decodificacao.lock() else {
                return;
            };
            let (dec, buf) = &mut *g;
            let n = match dec {
                #[cfg(feature = "opus")]
                Decodificador::Opus(d) => d.decodificar(a.payload, buf),
                Decodificador::Pcmu => {
                    let n = a.payload.len().min(buf.len());
                    for (o, b) in buf.iter_mut().zip(&a.payload[..n]) {
                        *o = crate::audio::ulaw_para_linear(*b);
                    }
                    Ok(n / canais_us)
                }
            };
            let Ok(n) = n else {
                e.falhas += 1;
                return;
            };
            if let Some(u) = e.ultima_seq {
                let d = a.sequencia.wrapping_sub(u);
                if d == 0 || d > 0x8000 {
                    e.fora_de_ordem += 1;
                } else if d > 1 {
                    e.buracos_de_seq += 1;
                }
            }
            e.ultima_seq = Some(a.sequencia);
            let (Ok(mut f), Ok(mut c)) = (pcm.lock(), pacotes.lock()) else {
                return;
            };
            let mut bytes = Vec::with_capacity(n * canais_us * 2);
            for v in &buf[..n * canais_us] {
                bytes.extend_from_slice(&v.to_le_bytes());
            }
            if f.write_all(&bytes).is_err() {
                return;
            }
            let _ = writeln!(c, "{},{},{},{}", a.sequencia, a.timestamp_us, e.amostras, n);
            e.amostras += n as u64;
            e.pacotes += 1;
        })?;
    }

    // O IDR na entrada, como o `receber-video`: sem ele o arquivo só começa no próximo GOP.
    for _ in 0..50 {
        if video.pedir_idr().is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    println!(
        "  gravando em {}.{{h264,quadros.csv,som.pcm,som.csv,json}}",
        p.display()
    );
    println!();

    let inicio = Instant::now();
    let fim = inicio + segundos;
    let mut serie: Vec<serde_json::Value> = Vec::new();
    let mut proxima_amostra = inicio;
    let mut proximo_relato = inicio + Duration::from_secs(2);
    let mut idr_de_novo = false;
    while Instant::now() < fim {
        std::thread::sleep(Duration::from_millis(50));
        if Instant::now() >= proxima_amostra {
            proxima_amostra += Duration::from_millis(500);
            let (sv, dv) = deslocamento_us(&video.deslocamento_de_captura());
            let (ss, ds) = deslocamento_us(&som.deslocamento_de_captura());
            serie.push(serde_json::json!({
                "t_s": inicio.elapsed().as_secs_f64(),
                "video": dv, "video_status": sv, "som": ds, "som_status": ss,
            }));
        }
        // Sem IDR em 3 s, pede de novo uma vez: o primeiro PLI pode ter saído antes da track abrir.
        if !idr_de_novo && inicio.elapsed() > Duration::from_secs(3) {
            idr_de_novo = true;
            if imagem.lock().map(|e| !e.abriu).unwrap_or(false) {
                let _ = video.pedir_idr();
            }
        }
        if Instant::now() >= proximo_relato {
            proximo_relato += Duration::from_secs(2);
            let (q, a) = (
                imagem.lock().map(|e| e.quadros).unwrap_or(0),
                estado_som.lock().map(|e| e.pacotes).unwrap_or(0),
            );
            let (sv, dv) = deslocamento_us(&video.deslocamento_de_captura());
            let (ss, ds) = deslocamento_us(&som.deslocamento_de_captura());
            println!(
                "  CLAQUETE t={:.0}s quadros={q} pacotes_de_som={a} desloc_video={}({sv}) desloc_som={}({ss})",
                inicio.elapsed().as_secs_f64(),
                dv.map(|v| v.to_string()).unwrap_or_else(|| "-".into()),
                ds.map(|v| v.to_string()).unwrap_or_else(|| "-".into()),
            );
        }
    }

    // Os tratadores saem antes de fechar os arquivos: nada escreve depois do `flush`.
    let _ = video.desregistrar_quadro();
    let _ = som.desregistrar_audio();
    h264.lock()
        .map_err(|_| Error::Invalid("h264 envenenado".into()))?
        .flush()?;
    for f in [&quadros, &pacotes] {
        f.lock()
            .map_err(|_| Error::Invalid("csv envenenado".into()))?
            .flush()?;
    }
    pcm.lock()
        .map_err(|_| Error::Invalid("pcm envenenado".into()))?
        .flush()?;

    let (sv, dv) = deslocamento_us(&video.deslocamento_de_captura());
    let (ss, ds) = deslocamento_us(&som.deslocamento_de_captura());
    let rv = video.retrato_do_relogio();
    let rs = som.retrato_do_relogio();
    let e = imagem
        .lock()
        .map_err(|_| Error::Invalid("estado envenenado".into()))?;
    let s = estado_som
        .lock()
        .map_err(|_| Error::Invalid("estado envenenado".into()))?;
    let cv: rtp::Contadores = video.contadores();
    let json = serde_json::json!({
        "sonda": "receber-claquete",
        "video": {
            "especie": format!("{:?}", video.kind()), "rotulo": video.label(),
            "quadros": e.quadros, "idrs": e.idrs, "antes_do_primeiro_idr": e.antes_do_idr,
            "pacotes_vistos": cv.pacotes_vistos, "pacotes_faltando": cv.pacotes_faltando,
            "quadros_descartados": cv.quadros_descartados,
            "deslocamento_us": dv, "status": sv,
            "violacoes_da_guarda": rv.as_ref().map(|r| r.violacoes_da_guarda),
            "referencia": rv.as_ref().map(|r| r.referencia),
        },
        "som": {
            "especie": format!("{:?}", som.kind()), "rotulo": som.label(),
            "codec": format!("{codec:?}"), "taxa_hz": taxa, "canais": canais,
            "atraso_do_conteudo_us": codec.atraso_do_conteudo_us(),
            "pacotes": s.pacotes, "amostras": s.amostras, "falhas_de_decodificacao": s.falhas,
            "buracos_de_seq": s.buracos_de_seq, "fora_de_ordem": s.fora_de_ordem,
            "deslocamento_us": ds, "status": ss,
            "violacoes_da_guarda": rs.as_ref().map(|r| r.violacoes_da_guarda),
            "residuo_us": rs.as_ref().and_then(|r| r.residuo_us),
            "deriva_entre_tracks_ppm": rs.as_ref().and_then(|r| r.deriva_entre_tracks_ppm),
            "referencia": rs.as_ref().map(|r| r.referencia),
        },
        "serie_do_deslocamento": serie,
    });
    std::fs::write(
        &caminho_json,
        serde_json::to_vec_pretty(&json).unwrap_or_default(),
    )?;

    println!();
    println!("resultado da claquete física");
    println!(
        "  vídeo: {} quadro(s) gravados ({} IDR), {} antes do primeiro IDR descartados, desloc {} ({sv})",
        e.quadros,
        e.idrs,
        e.antes_do_idr,
        dv.map(|v| format!("{v} µs")).unwrap_or_else(|| "-".into())
    );
    println!(
        "  som  : {} pacote(s), {} amostra(s), {} falha(s), {} buraco(s) de seq, {} fora de ordem, desloc {} ({ss})",
        s.pacotes,
        s.amostras,
        s.falhas,
        s.buracos_de_seq,
        s.fora_de_ordem,
        ds.map(|v| format!("{v} µs")).unwrap_or_else(|| "-".into())
    );
    println!("  analise com:");
    println!(
        "    python3 tools/claquete-fisica/analisar.py {} --semente <SEMENTE>",
        p.display()
    );
    let vazio = e.quadros == 0 || s.pacotes == 0;
    drop(e);
    drop(s);

    pronto.link.close("claquete concluída");
    drop(pronto);
    quall_core::transport::cleanup();
    if vazio {
        return Err(Error::Timeout(
            "a imagem ou o som não atravessaram; nada a analisar".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn o_prefixo_ignora_a_extensao_dos_nossos_arquivos() {
        assert_eq!(prefixo(Path::new("/tmp/a.h264")), PathBuf::from("/tmp/a"));
        assert_eq!(prefixo(Path::new("/tmp/a")), PathBuf::from("/tmp/a"));
        assert_eq!(
            com_sufixo(Path::new("/tmp/a"), ".som.pcm"),
            PathBuf::from("/tmp/a.som.pcm")
        );
    }
}
