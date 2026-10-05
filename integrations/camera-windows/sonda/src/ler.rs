//! `ler` — o consumidor de bancada.
//!
//! Abre a câmera pelo mesmo caminho que qualquer app do Windows usa (`MFEnumDeviceSources` →
//! `IMFActivate::ActivateObject` → `IMFSourceReader`) e mede o que chega. Não substitui a
//! testemunha de terceiro, mas é a única medida em que dá para instrumentar os dois lados.

use anyhow::{anyhow, Result};
use serde::Serialize;

use windows::core::GUID;
use windows::Win32::Media::MediaFoundation::{
    MFCreateAttributes, MFCreateSourceReaderFromMediaSource, MFEnumDeviceSources, IMFActivate,
    IMFAttributes, IMFMediaSource, IMFSample, IMFSourceReader, MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, MF_MT_FRAME_SIZE, MF_MT_SUBTYPE,
    MF_SOURCE_READER_FIRST_VIDEO_STREAM,
};

use crate::cano;
use crate::carimbo;
use crate::medida::{estat, Estatistica};
use crate::{string_de, KSCATEGORY_VIDEO_CAMERA};

#[derive(Serialize)]
pub struct Relatorio {
    pub camera: String,
    pub link: String,
    pub formato: String,
    pub quadros: u32,
    pub ate_o_primeiro_ms: f64,
    pub intervalo_ms: Estatistica,
    /// Latência host→app, atravessando o Frame Server, medida pelo carimbo de QPC nos pixels.
    /// Ausente quando ninguém carimbou — ou seja, quando a fonte entregou o padrão de bancada.
    pub latencia_do_cano_ms: Option<Estatistica>,
    pub quadros_carimbados: u32,
    /// Latência **do emissor** ao app consumidor, lida da faixa de células que o
    /// `emitir` desenha dentro do vídeo (ver `carimbo.rs`). Ausente quando o vídeo não vem de um
    /// emissor carimbado — que é o caso normal quando a origem é um celular ou o MacBook.
    pub latencia_do_emissor_ms: Option<Estatistica>,
    pub quadros_com_faixa: u32,
    /// Quadros em que a fonte de mídia repetiu o quadro anterior porque a origem da rede entrega
    /// menos de 30 fps. Eles carregam o **carimbo velho**, então entram nesta contagem e ficam
    /// **fora** das médias de latência: uma repetição mediria a idade do quadro repetido, não a
    /// latência do caminho, e inflaria a cauda sem que ninguém percebesse.
    pub quadros_repetidos_pela_fonte: u32,
    /// Quadros em que a faixa existia mas a soma de verificação não fechou. Um número que não é
    /// zero aqui quer dizer que o encode/escala está borrando as células, e que a média acima
    /// está calculada só sobre as leituras boas.
    pub faixas_recusadas: u32,
    /// Quantos quadros **diferentes** apareceram. Um app que mostra sempre a mesma imagem e um
    /// app que mostra vídeo são indistinguíveis sem este número.
    pub quadros_distintos: u32,
    /// As oito linhas do carimbo chegaram idênticas? Se não, alguém reamostrou no caminho e a
    /// medida de latência não vale.
    pub carimbo_integro: bool,
}

pub fn executar(
    trecho: &str,
    so_do_quall: bool,
    quadros: u32,
    segundos_max: u64,
    direto: Option<String>,
    json: Option<String>,
    salvar: Option<String>,
) -> Result<()> {
    unsafe {
        // Dois caminhos, e a diferença entre eles é o **diagnóstico**: `--direto <clsid>` cria a
        // fonte de mídia dentro deste processo, sem Frame Server nenhum no meio. Se o direto
        // entrega quadro e o normal não, o defeito está na integração com o Frame Server; se
        // nenhum dos dois entrega, o defeito é da fonte. Sem essa separação, "não vem imagem" é
        // uma frase, não um achado.
        let (fonte, nome, link): (IMFMediaSource, String, String) = if let Some(clsid) = direto {
            let g = guid_de_texto(&clsid)?;
            let f: IMFMediaSource = windows::Win32::System::Com::CoCreateInstance(
                &g,
                None,
                windows::Win32::System::Com::CLSCTX_INPROC_SERVER,
            )?;
            (f, format!("(direto) {clsid}"), "sem Frame Server".into())
        } else {
            let (ativador, nome, link) = if so_do_quall { achar_camera_do_quall(trecho)? } else { achar_camera(trecho)? };
            (ativador.ActivateObject()?, nome, link)
        };
        println!("câmera aberta (nome/link omitidos no diagnóstico)");
        let leitor: IMFSourceReader = MFCreateSourceReaderFromMediaSource(&fonte, None)?;

        let tipo = leitor.GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32)?;
        let sub: GUID = tipo.GetGUID(&MF_MT_SUBTYPE)?;
        let tam = tipo.GetUINT64(&MF_MT_FRAME_SIZE)?;
        let formato = format!("{}x{} subtipo={:?}", (tam >> 32) as u32, tam as u32, sub);
        println!("formato negociado: {formato}");

        let t0 = std::time::Instant::now();
        let mut ate_o_primeiro = 0.0f64;
        let mut anterior: Option<std::time::Instant> = None;
        let mut intervalos = Vec::new();
        let mut latencias = Vec::new();
        let mut latencias_emissor = Vec::new();
        let mut com_faixa = 0u32;
        let mut faixas_recusadas = 0u32;
        let mut carimbados = 0u32;
        let mut repetidos = 0u32;
        let mut marca_anterior: Option<u64> = None;
        let mut carimbo_integro = true;
        let mut assinaturas = std::collections::HashSet::new();
        let mut lidos = 0u32;

        let prazo = std::time::Duration::from_secs(segundos_max);
        let mut vazios = 0u32;
        while lidos < quadros {
            if t0.elapsed() > prazo {
                eprintln!(
                    "prazo de {segundos_max}s estourado com {lidos} quadros ({vazios} retornos \
                     vazios) — relatando o que deu"
                );
                break;
            }
            let mut flags = 0u32;
            let mut ts = 0i64;
            let mut amostra: Option<IMFSample> = None;
            eprint!("");
            leitor.ReadSample(
                MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                0,
                None,
                Some(&mut flags),
                Some(&mut ts),
                Some(&mut amostra),
            )?;
            let Some(amostra) = amostra else {
                vazios += 1;
                if t0.elapsed().as_secs() > 20 && lidos == 0 {
                    anyhow::bail!("20 s sem quadro nenhum — o pipeline não entregou nada");
                }
                continue;
            };
            let agora = std::time::Instant::now();
            if lidos == 0 {
                ate_o_primeiro = t0.elapsed().as_secs_f64() * 1000.0;
            }
            if let Some(a) = anterior {
                intervalos.push((agora - a).as_secs_f64() * 1000.0);
            }
            anterior = Some(agora);

            let buf = amostra.ConvertToContiguousBuffer()?;
            let salvar_este = salvar.as_ref().filter(|_| lidos == quadros / 2);
            let mut p: *mut u8 = std::ptr::null_mut();
            let mut atual = 0u32;
            buf.Lock(&mut p, None, Some(&mut atual))?;
            let largura = cano::LARGURA as usize;
            if atual as usize >= largura * 16 {
                let dados = std::slice::from_raw_parts(p, atual as usize);
                let agora_us = cano::qpc_us();
                let marca = u64::from_le_bytes(dados[0..8].try_into().unwrap());
                // Carimbo plausível: QPC em µs do passado recente da mesma máquina.
                let e_repeticao = marca_anterior == Some(marca) && marca != 0;
                if e_repeticao {
                    repetidos += 1;
                }
                if marca != 0 && marca <= agora_us && agora_us - marca < 10_000_000 {
                    if !e_repeticao {
                        latencias.push((agora_us - marca) as f64 / 1000.0);
                    }
                    marca_anterior = Some(marca);
                    carimbados += 1;
                    for linha in 1..8usize {
                        let b = linha * largura;
                        if dados[b..b + 8] != dados[0..8] {
                            carimbo_integro = false;
                        }
                    }
                }
                // Faixa de células do emissor: o relógio que atravessou o H.264. Só existe
                // quando a origem é o `emitir` desta sonda; num vídeo de celular a faixa não
                // está lá e `ler_y` recusa em vez de inventar número.
                let altura = (atual as usize / largura).min(cano::ALTURA as usize);
                if altura > carimbo::LINHA + carimbo::CELULA {
                    match carimbo::ler_y(dados, largura, altura) {
                        carimbo::Leitura::Lida(marca) => {
                            com_faixa += 1;
                            // Aritmética de 32 bits: a volta do contador é tratada de graça.
                            let atraso = (agora_us as u32).wrapping_sub(marca);
                            // Repetição da fonte carrega o carimbo velho; fica fora da média
                            // pelo mesmo motivo do carimbo de bytes acima.
                            if (atraso as u64) < 5_000_000 && !e_repeticao {
                                latencias_emissor.push(atraso as f64 / 1000.0);
                            }
                        }
                        carimbo::Leitura::Recusada => faixas_recusadas += 1,
                        // Sem faixa: é o caso normal quando a origem é um celular ou o MacBook.
                        carimbo::Leitura::Ausente => {}
                    }
                }
                // Assinatura barata do quadro, pulando as linhas do carimbo.
                //
                // O passo é **primo**, e isso custou uma corrida: com passo 4096 e linha de 1280
                // bytes o maior divisor comum é 256, então a amostragem caía sempre nas mesmas
                // cinco colunas e um quadro com uma barra andando aparecia como três quadros
                // distintos em cento e vinte. O número não era da imagem, era da régua.
                let mut h: u64 = 1469598103934665603;
                let mut i = largura * 16;
                while i < dados.len() {
                    h ^= dados[i] as u64;
                    h = h.wrapping_mul(1099511628211);
                    i += 1021;
                }
                assinaturas.insert(h);

                // Prova visual do pixel de verdade, sem fotografar a tela de ninguém: o quadro
                // que o app consumidor recebeu, gravado em BMP. Um `.bmp` de 24 bpp não precisa
                // de biblioteca nenhuma e abre em qualquer lugar.
                if let Some(caminho) = salvar_este {
                    match nv12_para_bmp(dados, largura, cano::ALTURA as usize, caminho) {
                        Ok(()) => eprintln!("quadro {lidos} gravado em {caminho}"),
                        Err(e) => eprintln!("aviso: não gravou o BMP: {}", crate::resumo_erro(&e)),
                    }
                }
            }
            buf.Unlock()?;
            lidos += 1;
        }

        let rel = Relatorio {
            camera: nome,
            link,
            formato,
            quadros: lidos,
            ate_o_primeiro_ms: ate_o_primeiro,
            intervalo_ms: estat(intervalos),
            latencia_do_cano_ms: if latencias.is_empty() { None } else { Some(estat(latencias)) },
            latencia_do_emissor_ms: if latencias_emissor.is_empty() {
                None
            } else {
                Some(estat(latencias_emissor))
            },
            quadros_com_faixa: com_faixa,
            quadros_repetidos_pela_fonte: repetidos,
            faixas_recusadas,
            quadros_carimbados: carimbados,
            quadros_distintos: assinaturas.len() as u32,
            carimbo_integro,
        };
        let diagnostico = crate::diagnostico(&rel)?;
        println!("{}", serde_json::to_string_pretty(&diagnostico)?);
        if let Some(c) = json {
            std::fs::write(c, serde_json::to_vec_pretty(&diagnostico)?)?;
        }
        let _ = fonte.Shutdown();
    }
    Ok(())
}

/// NV12 → BMP de 24 bpp, faixa limitada BT.601 (o inverso exato do que a placa faz ao entrar).
fn nv12_para_bmp(dados: &[u8], largura: usize, altura: usize, caminho: &str) -> Result<()> {
    use std::io::Write;
    if dados.len() < largura * altura * 3 / 2 {
        anyhow::bail!("quadro menor que um NV12 de {largura}x{altura}");
    }
    let linha_bmp = ((largura * 3 + 3) / 4) * 4;
    let dados_px = linha_bmp * altura;
    let mut f = std::io::BufWriter::new(std::fs::File::create(caminho)?);
    f.write_all(b"BM")?;
    f.write_all(&((14 + 40 + dados_px) as u32).to_le_bytes())?;
    f.write_all(&0u16.to_le_bytes())?;
    f.write_all(&0u16.to_le_bytes())?;
    f.write_all(&54u32.to_le_bytes())?;
    f.write_all(&40u32.to_le_bytes())?;
    f.write_all(&(largura as i32).to_le_bytes())?;
    f.write_all(&(-(altura as i32)).to_le_bytes())?; // negativo: de cima para baixo
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&24u16.to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?;
    f.write_all(&(dados_px as u32).to_le_bytes())?;
    f.write_all(&0i32.to_le_bytes())?;
    f.write_all(&0i32.to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?;

    let inicio_uv = largura * altura;
    let mut linha = vec![0u8; linha_bmp];
    for y in 0..altura {
        for x in 0..largura {
            let yv = dados[y * largura + x] as f32;
            let i = inicio_uv + (y / 2) * largura + (x & !1);
            let u = dados[i] as f32 - 128.0;
            let v = dados[i + 1] as f32 - 128.0;
            let l = 1.164 * (yv - 16.0);
            let r = (l + 1.596 * v).clamp(0.0, 255.0) as u8;
            let g = (l - 0.392 * u - 0.813 * v).clamp(0.0, 255.0) as u8;
            let b = (l + 2.017 * u).clamp(0.0, 255.0) as u8;
            linha[x * 3] = b;
            linha[x * 3 + 1] = g;
            linha[x * 3 + 2] = r;
        }
        f.write_all(&linha)?;
    }
    f.flush()?;
    Ok(())
}

fn guid_de_texto(s: &str) -> Result<GUID> {
    let limpo: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if limpo.len() != 32 {
        anyhow::bail!("CLSID malformado: {s}");
    }
    Ok(GUID::from_u128(u128::from_str_radix(&limpo, 16)?))
}

/// **Só uma câmera do Quall, por identidade** (crítica 13, miúdo 8): o nome **igual** ao pedido, o
/// link de câmera virtual (`SWD#VCAMDEVAPI`) e o dono lido do registro igual ao CLSID da fonte do
/// Quall — pelo catálogo do app (`quall_capture_probe::cameras`), que lê sem ativar nada. Nunca
/// "contém" entre todas: uma webcam de verdade com o mesmo trecho no nome não é aberta. Mais de
/// uma, ou nenhuma, é recusa.
fn achar_camera_do_quall(nome: &str) -> Result<(IMFActivate, String, String)> {
    use quall_capture_probe::catalogo_de_cameras::Dono;
    let catalogo = quall_capture_probe::cameras::catalogo().map_err(|e| anyhow!(e))?;
    let do_quall: Vec<_> = catalogo.iter().filter(|c| c.dono == Dono::Quall).collect();
    let alvos: Vec<_> = do_quall
        .iter()
        .filter(|c| c.nome == nome && c.link.to_ascii_lowercase().contains("swd#vcamdevapi"))
        .collect();
    let link = match alvos.as_slice() {
        [um] => um.link.clone(),
        [] => anyhow::bail!(
            "nenhuma câmera do Quall chamada \"{nome}\"; as do Quall: {:?}",
            do_quall.iter().map(|c| c.nome.as_str()).collect::<Vec<_>>()
        ),
        varias => anyhow::bail!("{} câmeras do Quall correspondem ao nome solicitado: recuso escolher (nome omitido)", varias.len()),
    };
    unsafe {
        for (a, n, l) in ativadores()? {
            if l.eq_ignore_ascii_case(&link) {
                return Ok((a, n, l));
            }
        }
    }
    anyhow::bail!("a câmera do Quall solicitada está no catálogo e não na enumeração do Media Foundation (nome/link omitidos)")
}

/// Todas as câmeras que o Media Foundation enumera: o ativador, o nome e o link.
unsafe fn ativadores() -> Result<Vec<(IMFActivate, String, String)>> {
    let mut attrs: Option<IMFAttributes> = None;
    MFCreateAttributes(&mut attrs, 2)?;
    let attrs = attrs.ok_or_else(|| anyhow!("MFCreateAttributes devolveu nulo"))?;
    attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)?;
    attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY, &KSCATEGORY_VIDEO_CAMERA)?;
    let mut lista: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut n: u32 = 0;
    MFEnumDeviceSources(&attrs, &mut lista, &mut n)?;
    if lista.is_null() {
        return Ok(Vec::new());
    }
    let fatia = std::slice::from_raw_parts(lista, n as usize);
    Ok(fatia
        .iter()
        .flatten()
        .map(|a| {
            let nome = string_de(a, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME).unwrap_or_default();
            let link = string_de(a, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK).unwrap_or_default();
            (a.clone(), nome, link)
        })
        .collect())
}

fn achar_camera(trecho: &str) -> Result<(IMFActivate, String, String)> {
    unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2)?;
        let attrs = attrs.ok_or_else(|| anyhow!("MFCreateAttributes devolveu nulo"))?;
        attrs.SetGUID(
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
        )?;
        attrs.SetGUID(
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY,
            &KSCATEGORY_VIDEO_CAMERA,
        )?;
        let mut ativadores: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n: u32 = 0;
        MFEnumDeviceSources(&attrs, &mut ativadores, &mut n)?;
        if ativadores.is_null() {
            anyhow::bail!("nenhuma câmera enumerada");
        }
        let fatia = std::slice::from_raw_parts(ativadores, n as usize);
        let alvo = trecho.to_lowercase();
        for a in fatia.iter().flatten() {
            let nome = string_de(a, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME).unwrap_or_default();
            if nome.to_lowercase().contains(&alvo) {
                let link = string_de(a, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK)
                    .unwrap_or_default();
                return Ok((a.clone(), nome, link));
            }
        }
        anyhow::bail!("nenhuma câmera corresponde ao filtro entre as {n} enumeradas (filtro omitido)")
    }
}
