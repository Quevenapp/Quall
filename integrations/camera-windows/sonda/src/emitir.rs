//! `emitir` — o emissor **de medição**, e só de medição.
//!
//! # Por que esta frente escreveu um emissor
//!
//! Porque sem ele não há como medir latência de ponta a ponta com honestidade, e a alternativa
//! seria somar fatias — que é exatamente o que `docs/contrato-track.md` e
//! `docs/medir-vidro-a-vidro.md` proíbem, com razão.
//!
//! O problema é de **relógio**. Para dizer "do emissor ao app consumidor levou N ms" é preciso
//! subtrair dois instantes medidos no mesmo relógio. Emissor no MacBook e consumidor no Dell são
//! dois relógios sem relação, e o núcleo não ajuda: o `timestamp_us` que o receptor recebe é
//! **relativo ao primeiro quadro que chegou** (`rtp.rs` subtrai `carimbo_base`), então nem
//! conhecendo o relógio do emissor dá para recuperar o instante absoluto de envio.
//!
//! A saída é a que o projeto já decidiu para a campanha filmada: **o relógio viaja dentro do
//! vídeo**. Este emissor desenha o próprio `QueryPerformanceCounter` numa faixa de células
//! claras e escuras (ver `carimbo.rs`), encoda em hardware, e manda pela track. O carimbo
//! atravessa encode, RTP, SRTP, rede, depacotização, decode, escala, cano e Frame Server, e quem
//! o lê de volta é o **app consumidor**, com o mesmo QPC. A subtração é a latência, e não há
//! sincronização de relógio nenhuma para dar errado.
//!
//! # O que este número cobre, e o que não cobre
//!
//! Cobre: encode em hardware, empacotamento RTP, SRTP, pilha de rede, depacotização, decode em
//! hardware, escala/letterbox, cano nomeado, Frame Server e o app consumidor.
//!
//! **Não cobre** e é preciso dizer sempre junto: (1) a captura de tela ou de câmera de verdade,
//! porque o conteúdo aqui é sintético — é o carimbo que interessa; (2) o **salto de rádio**,
//! porque emissor e consumidor rodam na mesma máquina para partilhar o relógio, e o tráfego
//! atravessa a pilha de rede local em vez do Wi-Fi; (3) a varredura do painel, porque não há
//! painel — o consumidor é um app, não um olho.
//!
//! Para (2) o número que falta existe e está medido em `docs/bancada.md` (M1: ~4,3 ms num
//! sentido entre MacBook e Dell). Ele fica **declarado à parte**, nunca somado dentro da
//! manchete.

use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde::Serialize;

use quall_capture_probe::{device, encoder as mft};
use quall_core::track::{QuadroCodificado, TrackKind};

use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};

use crate::cano;
use crate::carimbo;
use crate::medida::{estat, Estatistica};
use crate::nucleo;

pub struct Opcoes {
    pub segundos: u64,
    pub porta: u16,
    pub fps: u32,
    pub largura: u32,
    pub altura: u32,
    pub bitrate: u32,
    pub gop: u32,
    pub json: Option<String>,
    pub camera: bool,
    pub pin: Option<String>,
}

#[derive(Serialize, Default)]
pub struct Relatorio {
    pub encoder: String,
    pub encoder_e_hardware: bool,
    pub adaptador: String,
    pub resolucao: String,
    pub fps_pedido: u32,
    pub quadros_desenhados: u64,
    pub quadros_encodados: u64,
    pub quadros_enviados: u64,
    pub falhas_de_envio: u64,
    pub idrs: u64,
    pub idrs_sem_parametros: u64,
    pub pedidos_de_idr_recebidos: u64,
    pub encode_ms: Estatistica,
    /// Quanto o laço se afastou do ritmo pedido. Um emissor que derrapa mede o próprio atraso e
    /// chama de latência do sistema; este número existe para essa acusação não colar sem prova.
    pub desvio_do_ritmo_ms: Estatistica,
}

pub fn executar(op: Opcoes) -> Result<()> {
    let mut rel = Relatorio {
        fps_pedido: op.fps,
        resolucao: format!("{}x{}", op.largura, op.altura),
        ..Default::default()
    };

    // 1. Encoder e adaptador, antes da sessão: se o encoder não ativar, é melhor descobrir agora
    //    do que depois de alguém digitar o PIN.
    let enc = mft::find_and_activate_h264_encoder()
        .map_err(|e| anyhow::anyhow!("nenhum MFT de encode H.264 ativou: {e}"))?;
    rel.encoder = enc.friendly_name.clone();
    rel.encoder_e_hardware = enc.is_hardware;
    eprintln!("encoder: \"{}\" (hardware={})", enc.friendly_name, enc.is_hardware);

    let vendor = if enc.friendly_name.to_uppercase().contains("NVIDIA") {
        device::VENDOR_NVIDIA
    } else {
        device::VENDOR_INTEL
    };
    let adaptador =
        device::create_device(vendor).map_err(|e| anyhow::anyhow!("D3D11CreateDevice: {e}"))?;
    rel.adaptador = format!("{} (vendor 0x{:04X})", adaptador.description, adaptador.vendor_id);
    eprintln!("adaptador: {}", rel.adaptador);

    let gerenciador = mft::create_device_manager(&adaptador.device)
        .map_err(|e| anyhow::anyhow!("IMFDXGIDeviceManager: {e}"))?;
    mft::configure(
        &enc,
        &gerenciador,
        &mft::EncoderConfig {
            entrada: mft::FormatoDeEntrada::Argb32,
            width: op.largura,
            height: op.altura,
            fps: op.fps,
            bitrate_bps: op.bitrate,
            gop_frames: op.gop,
            // Os botões de `docs/idr-pequeno.md` nascem desligados; ver `EncoderConfig`.
            intra_refresh_frames: 0,
            slice_bytes: 0,
            // O teto de quadro da tela estendida (F2b) também: esta sonda mede a câmera.
            teto_de_quadro_bits: 0,
        },
    )
    .map_err(|e| anyhow::anyhow!("configurar o encoder: {e}"))?;
    mft::start_stream(&enc.transform).map_err(|e| anyhow::anyhow!("start_stream: {e}"))?;
    let eventos = mft::spawn_event_pump(enc.events.clone());

    // 2. A textura de entrada. `D3D11_USAGE_DEFAULT` com `UpdateSubresource`, e não `DYNAMIC` com
    //    `Map`: uma textura dinâmica é feita para ser reescrita pela CPU a cada quadro **e lida
    //    por shader**, e não é o que um MFT de hardware espera receber por
    //    `MFCreateDXGISurfaceBuffer`.
    let desc = D3D11_TEXTURE2D_DESC {
        Width: op.largura,
        Height: op.altura,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: (D3D11_BIND_SHADER_RESOURCE.0 | D3D11_BIND_RENDER_TARGET.0) as u32,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    };
    let mut textura: Option<ID3D11Texture2D> = None;
    unsafe { adaptador.device.CreateTexture2D(&desc, None, Some(&mut textura)) }
        .context("CreateTexture2D (entrada do encoder)")?;
    let textura = textura.context("CreateTexture2D não devolveu textura")?;
    let contexto = unsafe { adaptador.device.GetImmediateContext() }.context("contexto")?;

    // 3. A sessão. Bloqueia até alguém conectar e digitar o PIN.
    let kind = if op.camera { TrackKind::Camera } else { TrackKind::Screen };
    let mut emissor = nucleo::hospedar_com_track(
        "quall-camera-emissor",
        "Emissor de medição (Frente 7)",
        op.porta,
        "carimbo de medição",
        kind,
        op.pin.as_deref(),
        Duration::from_secs(300),
    )
    .map_err(anyhow::Error::new)?;
    println!("receptor conectado");

    // 4. O laço.
    let passo = op.largura as usize * 4;
    let mut quadro = vec![0u8; passo * op.altura as usize];
    let inicio = Instant::now();
    let fim = inicio + Duration::from_secs(op.segundos);
    let mut n: u64 = 0;
    let mut desvios = Vec::new();
    let mut encodes = Vec::new();
    let mut submetido_em: std::collections::VecDeque<Instant> = std::collections::VecDeque::new();
    let mut creditos: u32 = 0;
    let duracao_100ns: i64 = 10_000_000 / op.fps.max(1) as i64;
    let mut falhas_seguidas = 0u64;

    while Instant::now() < fim {
        // Ritmo do emissor: **este** é o único relógio que pode ditar quadro nesta frente, porque
        // aqui não há nada chegando para esperar — é a origem.
        let alvo = inicio + Duration::from_nanos(n * 1_000_000_000 / op.fps.max(1) as u64);
        let agora = Instant::now();
        if alvo > agora {
            std::thread::sleep(alvo - agora);
        } else if n > 0 {
            desvios.push((agora - alvo).as_secs_f64() * 1000.0);
        }

        if emissor.pronto.tracks[0].pegar_pedido_de_idr() {
            rel.pedidos_de_idr_recebidos += 1;
            // Best-effort e medido no M1 como ignorado por este driver: a `ICodecAPI` aceita e o
            // encoder não força nada. O GOP curto é o que de fato garante o IDR.
            let _ = mft::force_next_keyframe(&enc);
        }

        // Desenha, e o carimbo é a **última** coisa escrita antes do encode: quanto mais perto do
        // `ProcessInput`, menos tempo do próprio emissor entra no número.
        pintar(&mut quadro, op.largura as usize, op.altura as usize, n);
        let marca = cano::qpc_us() as u32;
        carimbo::desenhar_bgra(&mut quadro, passo, marca);
        rel.quadros_desenhados += 1;

        unsafe {
            contexto.UpdateSubresource(
                &textura,
                0,
                None,
                quadro.as_ptr() as *const core::ffi::c_void,
                passo as u32,
                0,
            );
        }

        let t_encode = Instant::now();
        let amostra = mft::sample_from_texture(
            &textura,
            0,
            (n as i64) * duracao_100ns,
            duracao_100ns,
        )
        .map_err(|e| anyhow::anyhow!("sample_from_texture: {e}"))?;

        // O MFT é assíncrono nesta bancada: só aceita entrada quando dá crédito.
        let prazo_credito = Instant::now() + Duration::from_millis(100);
        while creditos == 0 && Instant::now() < prazo_credito {
            match eventos.recv_timeout(Duration::from_millis(5)) {
                Ok(mft::MftEvent::NeedInput) => creditos += 1,
                Ok(mft::MftEvent::HaveOutput) => {
                    drenar(&enc, &mut submetido_em, &mut encodes, &mut emissor, &mut rel);
                }
                _ => {}
            }
        }
        let mut submetido = false;
        if creditos > 0 {
            match unsafe { enc.transform.ProcessInput(0, &amostra, 0) } {
                Ok(()) => {
                    creditos -= 1;
                    submetido_em.push_back(t_encode);
                    submetido = true;
                }
                Err(e) => eprintln!("aviso: ProcessInput recusou: {}", crate::resumo_erro(&e)),
            }
        }

        // **Esperar a saída do encoder, não pegá-la na volta seguinte do laço.**
        //
        // A primeira versão só drenava o que já estivesse pronto (`try_recv`) e seguia para o
        // `sleep` do próximo quadro. O efeito ficou medido e é grande: `encode_ms` deu **33,4 ms
        // de mediana** — exatamente um intervalo de quadro, e não a latência do NVENC. O quadro
        // ficava pronto em milissegundos e só era enviado uma volta depois, o que empurrou a
        // latência de ponta a ponta em ~33 ms.
        //
        // É o mesmo defeito que esta frente já tinha pago do outro lado do cano — ritmar no
        // relógio próprio em vez de esperar o quadro — reaparecendo na ferramenta de medição. Se
        // não tivesse aparecido, o número publicado seria a régua, não o sistema.
        let prazo_saida = Instant::now() + Duration::from_millis(25);
        let mut saiu = false;
        while submetido && !saiu && Instant::now() < prazo_saida {
            match eventos.recv_timeout(Duration::from_millis(5)) {
                Ok(mft::MftEvent::NeedInput) => creditos += 1,
                Ok(mft::MftEvent::HaveOutput) => {
                    let antes = rel.quadros_encodados;
                    drenar(&enc, &mut submetido_em, &mut encodes, &mut emissor, &mut rel);
                    saiu = rel.quadros_encodados > antes;
                }
                Ok(_) => {}
                Err(_) => {}
            }
        }
        // O que sobrou de evento, sem esperar.
        while let Ok(evento) = eventos.try_recv() {
            match evento {
                mft::MftEvent::NeedInput => creditos += 1,
                mft::MftEvent::HaveOutput => {
                    drenar(&enc, &mut submetido_em, &mut encodes, &mut emissor, &mut rel)
                }
                _ => {}
            }
        }

        if rel.falhas_de_envio > 0 && rel.quadros_enviados == 0 {
            falhas_seguidas += 1;
            if falhas_seguidas > (op.fps as u64) * 5 {
                eprintln!("cinco segundos sem a track aceitar quadro; desistindo.");
                break;
            }
        }
        n += 1;
    }

    rel.encode_ms = estat(encodes);
    rel.desvio_do_ritmo_ms = estat(desvios);
    rel.idrs = emissor.pronto.tracks[0].idrs_enviados();
    rel.idrs_sem_parametros = emissor.pronto.tracks[0].idrs_sem_parametros();

    // Arrasto: os últimos pacotes ainda estão no ar.
    std::thread::sleep(Duration::from_millis(500));
    emissor.pronto.link.close("emissão de medição concluída");
    drop(emissor);
    quall_core::transport::cleanup();

    let diagnostico = crate::diagnostico(&rel)?;
    println!("{}", serde_json::to_string_pretty(&diagnostico)?);
    if let Some(c) = op.json {
        std::fs::write(c, serde_json::to_vec_pretty(&diagnostico)?)?;
    }
    Ok(())
}

fn drenar(
    enc: &mft::ChosenEncoder,
    submetido_em: &mut std::collections::VecDeque<Instant>,
    encodes: &mut Vec<f64>,
    emissor: &mut nucleo::EmissorPronto,
    rel: &mut Relatorio,
) {
    let quadros = match mft::drain_output(&enc.transform, mft::OUTPUT_STREAM_ID) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("aviso: drain_output do encoder falhou: {}", crate::resumo_erro(&e));
            return;
        }
    };
    for q in quadros {
        rel.quadros_encodados += 1;
        if let Some(t) = submetido_em.pop_front() {
            encodes.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        let carimbo_us = cano::qpc_us();
        match emissor.pronto.tracks[0].enviar_quadro(QuadroCodificado {
            annexb: &q.bytes,
            timestamp_us: carimbo_us,
            idr: q.is_idr,
        }) {
            Ok(()) => rel.quadros_enviados += 1,
            // Antes de o ICE fechar, isto é o estado **normal** — 31 quadros nesta bancada, ver
            // `docs/bancada.md`. Contar e seguir; nunca enfileirar.
            Err(_) => rel.falhas_de_envio += 1,
        }
    }
}

/// Conteúdo do quadro, em BGRA: gradiente de fundo, uma barra que desce e uma grade.
///
/// Não é enfeite. Uma testemunha de terceiro (Chrome, OBS) precisa mostrar **movimento** para
/// distinguir "chega vídeo" de "o último quadro ficou congelado", e a grade mostra na hora se o
/// letterbox recortou ou esticou a imagem no caminho.
fn pintar(buf: &mut [u8], largura: usize, altura: usize, n: u64) {
    let barra = ((n * 7) % altura as u64) as usize;
    for y in 0..altura {
        let base = y * largura * 4;
        let fundo = (24 + y * 90 / altura) as u8;
        let na_barra = y >= barra && y < barra + 24;
        for x in 0..largura {
            let mut v = if na_barra { 220 } else { fundo };
            if x % 128 == 0 || y % 128 == 0 {
                v = v.saturating_add(50);
            }
            let p = base + x * 4;
            buf[p] = v;
            buf[p + 1] = v;
            buf[p + 2] = v;
            buf[p + 3] = 255;
        }
    }
}
