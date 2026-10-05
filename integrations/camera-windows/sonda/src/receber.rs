//! `receber` — a ligação que faltava: o vídeo que vem da rede vira a câmera virtual.
//!
//! Este é o papel do **app do Quall** no desktop, e o caminho inteiro está aqui:
//!
//! ```text
//!   emissor (celular / MacBook / outro Windows)
//!       │  H.264 pela track de mídia do núcleo (RTP/SRTP)
//!       ▼
//!   ao_receber_quadro          ← fio da libdatachannel; copia e sai
//!       │
//!   fio de decode              ← MFT de hardware da Frente 6 (~2,6 ms)
//!       │  textura D3D11 NV12, no tamanho que veio da rede
//!   escala.rs                  ← VideoProcessorBlt para 1920x1080 NV12, com letterbox
//!       │  3,11 MB em memória de sistema
//!   Distribuidor               ← guarda o **último** quadro e acorda quem espera
//!       │
//!   fios do cano               ← \\.\pipe\quall-camera-v1, um por instância
//!       ▼
//!   svchost -k Camera → câmera "Quall" → Chrome, Meet, OBS, Zoom
//! ```
//!
//! # O terceiro relógio
//!
//! A primeira versão desta frente media 52,8 ms de host→app e caiu para 37,2 ms com uma mudança
//! só: a **fonte** passou a esperar o quadro chegar em vez de ritmar no relógio dela. Os 15 ms
//! eram batimento de fase entre dois relógios independentes de 30 Hz.
//!
//! Agora entra um **terceiro**: o do emissor, que também é ~30 Hz e não tem relação nenhuma com
//! os outros dois. O mesmo fenômeno se repetiria — e a mesma correção o resolve, um andar acima:
//! **nada neste arquivo ritma quadro no relógio próprio**. O fio de decode publica quando o
//! quadro chega da rede; os fios do cano escrevem quando o `Distribuidor` acorda. A única coisa
//! que anda por relógio próprio é a **placa de espera**, e ela existe justamente para quando não
//! há vídeo nenhum para esperar.
//!
//! # Por que copiar o quadro no tratador, se o contrato diz para não copiar
//!
//! `docs/contrato-track.md` diz que a casca entrega o quadro ao decoder sem copiar. Aqui há uma
//! cópia do quadro **comprimido** (dezenas de KB), e ela é deliberada: o tratador roda numa
//! thread da libdatachannel, que nunca chamou `CoInitializeEx`. Chamar um `IMFTransform` de uma
//! thread sem apartamento COM é o tipo de coisa que funciona nove vezes e trava na décima — e no
//! Windows "trava" tem significado literal nesta bancada (ver `docs/divida-do-nucleo.md`). A
//! cópia é de bytes comprimidos, não de pixel: ~40 KB por quadro contra 3,11 MB do quadro cru.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde::Serialize;

use quall_capture_probe::{decoder, device, encoder as mft};
use quall_core::pairing::{PairedPeers, Pin};
use quall_core::session::EventoDeSessao;
use quall_core::track::QuadroCodificado;

use windows::Win32::Media::MediaFoundation::{
    MFVideoFormat_NV12, MF_E_NOTACCEPTING, MF_MT_FRAME_SIZE, MF_MT_MINIMUM_DISPLAY_APERTURE,
    MF_MT_SUBTYPE,
};

use crate::cano;
// Distribuidor, fios do cano e fio da placa moraram aqui até 09/09/2026. Hoje moram no app,
// que é quem serve o cano no produto — ver `apps/windows/src/baia.rs`.
use quall_capture_probe::baia::{soltar_o_cano, subir_cano, subir_placa, Distribuidor};
use crate::escala::Escalador;
use crate::medida::{estat, Estatistica};
use crate::nucleo::{self, Alvo};
use crate::placa::{Estado, Placa};

pub struct Opcoes {
    pub ip: Option<String>,
    pub descobrir: bool,
    pub pin: Option<String>,
    pub segundos: u64,
    pub json: Option<String>,
    pub device_id: String,
    pub display_name: String,
    /// Serve só a placa de espera, sem sessão nenhuma. Existe para provar a placa isolada, e
    /// porque é literalmente o estado do produto antes de alguém conectar.
    pub so_placa: bool,
    /// O **nome da câmera** que este host alimenta. É ele que escolhe o cano
    /// (`cano_do_nome`), e tem de ser a mesma string usada no `MFCreateVirtualCamera`.
    ///
    /// `None` serve o cano histórico, que é o que todo roteiro de bancada anterior a 09/09/2026
    /// espera.
    pub camera: Option<String>,
}

// ---------------------------------------------------------------------------------------------
// Relatório
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Default)]
pub struct Relatorio {
    pub emissor: String,
    pub track: String,
    pub resolucao_recebida: String,
    pub decoder: String,
    pub decoder_e_hardware: bool,
    pub adaptador: String,
    /// Quadros que a track entregou ao tratador.
    pub quadros_da_rede: u64,
    pub idrs_da_rede: u64,
    /// Quadros que o tratador teve de descartar por a fila do decoder estar cheia.
    ///
    /// **Não confundir com perda de rede**, e a confusão já custou um enquadramento errado: o
    /// `anomalia-de-sequencia.md` mostra que os "3 descartados na fila" desta sonda no Dell vieram
    /// com `1803 quadros da rede / 1800 decodificados` — os 1803 **chegaram**. Isto é vazão de
    /// decodificador. Quem conta rede é `perdas_da_rede` e `anomalias_de_sequencia`, abaixo.
    pub descartados_na_fila: u64,
    /// `frames_dropped` do núcleo: quadro que o depacotizador condenou porque faltou pacote. É o
    /// gatilho do pedido de IDR na perda.
    pub perdas_da_rede: u64,
    /// `sequence_anomalies` do núcleo. Superestima em Wi-Fi carregado: uma troca de ordem aparece
    /// três vezes. Serve como ordem de grandeza do buraco, não como contagem de pacote perdido.
    pub anomalias_de_sequencia: u64,
    /// De cada perda detectada até o IDR seguinte, em ms. É o número do A/B do PLI na perda.
    pub sem_referencia_ms: Vec<u64>,
    pub quadros_decodificados: u64,
    pub quadros_publicados: u64,
    pub quadros_de_placa: u64,
    pub clientes_do_cano: u64,
    pub quadros_escritos_no_cano: u64,
    /// Do quadro sair da track ao pixel escalado estar pronto para o cano. É a fatia que esta
    /// entrega acrescentou ao caminho.
    pub rede_ate_pronto_ms: Estatistica,
    pub decode_ms: Estatistica,
    pub escala_ms: Estatistica,
    pub escrita_no_cano_ms: Estatistica,
    /// Do início da recepção ao primeiro pixel publicado.
    pub primeira_imagem_ms: Option<f64>,
    pub pedidos_de_idr: u64,
    /// O carimbo de bancada está armado neste processo? **Falso é o caminho normal.**
    pub carimbo_de_bancada_armado: bool,
    /// Quantos quadros saíram com o carimbo de bancada escrito nos pixels. Tem de ser **zero**
    /// sempre que `carimbo_de_bancada_armado` for falso; é o par produtor da contagem que o
    /// consumidor (`ler`) publica em `quadros_carimbados`.
    pub quadros_carimbados_de_bancada: u64,
    pub evento_final: String,
}

// ---------------------------------------------------------------------------------------------

pub fn executar(op: Opcoes) -> Result<()> {
    let dist = Distribuidor::novo();
    let parar = Arc::new(AtomicBool::new(false));
    let estado_placa = Arc::new(Mutex::new(Estado::Procurando));
    let clientes = Arc::new(AtomicU64::new(0));
    let escritos = Arc::new(AtomicU64::new(0));
    let custos_escrita: Arc<Mutex<Vec<f64>>> = Arc::new(Mutex::new(Vec::new()));
    // Um app abriu a câmera: é o gatilho natural para pedir IDR.
    let alguem_abriu = Arc::new(AtomicBool::new(false));

    // 1. O cano sobe **antes** da sessão, de propósito. Quem abre o Meet e escolhe a câmera Quall
    //    antes de mexer no celular precisa ver a placa dizendo o que fazer — não preto, e não a
    //    barra de bancada da fonte, que quer dizer outra coisa ("o Quall nem está rodando").
    let cano_servido = match op.camera.as_deref() {
        Some(n) => cano::cano_do_nome(n),
        None => cano::CANO.to_string(),
    };
    // Quem está lendo agora. A sonda converte todo quadro de qualquer jeito — ela existe para
    // medir a câmera, e sem leitor não há o que medir —, então o número só é passado adiante.
    let leitores = Arc::new(AtomicU64::new(0));
    let fios_do_cano = subir_cano(
        Arc::clone(&dist),
        Arc::clone(&parar),
        Arc::clone(&clientes),
        Arc::clone(&leitores),
        Arc::clone(&escritos),
        Arc::clone(&custos_escrita),
        Arc::clone(&alguem_abriu),
        cano_servido.clone(),
    );
    let fio_da_placa = subir_placa(
        Arc::clone(&dist),
        Arc::clone(&parar),
        Arc::clone(&estado_placa),
    );

    let mut rel = Relatorio::default();

    if op.so_placa {
        println!("modo --so-placa: servindo a placa de espera por {}s", op.segundos);
        *estado_placa.lock().unwrap() = Estado::SemAparelho;
        std::thread::sleep(Duration::from_secs(op.segundos));
        rel.evento_final = "so-placa".into();
    } else {
        match sessao(&op, &dist, &estado_placa, &alguem_abriu, &parar, &mut rel) {
            Ok(()) => {}
            Err(e) => {
                *estado_placa.lock().unwrap() = Estado::Caiu;
                eprintln!("sessão terminou com erro: {}", crate::resumo_erro(&e));
                rel.evento_final = format!("erro: {}", crate::resumo_erro(&e));
                // Não sai: a placa continua servindo por alguns segundos, para quem estiver com a
                // câmera aberta ler o que aconteceu em vez de ver a imagem congelar.
                std::thread::sleep(Duration::from_secs(3));
            }
        }
    }

    parar.store(true, Ordering::Relaxed);
    dist.acordar();
    soltar_o_cano(fios_do_cano.len(), &cano_servido);
    for f in fios_do_cano {
        let _ = f.join();
    }
    let _ = fio_da_placa.join();

    rel.clientes_do_cano = clientes.load(Ordering::Relaxed);
    rel.quadros_escritos_no_cano = escritos.load(Ordering::Relaxed);
    let (publicados_de_video, publicados_de_placa) = dist.publicados();
    rel.quadros_publicados = publicados_de_video;
    rel.quadros_de_placa = publicados_de_placa;
    rel.escrita_no_cano_ms = estat(custos_escrita.lock().unwrap().clone());
    rel.carimbo_de_bancada_armado = cano::carimbo_armado();

    let diagnostico = crate::diagnostico(&rel)?;
    println!("{}", serde_json::to_string_pretty(&diagnostico)?);
    if let Some(c) = op.json {
        std::fs::write(c, serde_json::to_vec_pretty(&diagnostico)?)?;
    }
    Ok(())
}

struct DaRede {
    annexb: Vec<u8>,
    idr: bool,
    /// QPC de quando o quadro **saiu da track**. É este carimbo que viaja nos pixels até o app
    /// consumidor, e é ele que faz o número ser medido em vez de somado.
    chegada_us: u64,
}

fn sessao(
    op: &Opcoes,
    dist: &Arc<Distribuidor>,
    estado_placa: &Arc<Mutex<Estado>>,
    alguem_abriu: &Arc<AtomicBool>,
    parar: &Arc<AtomicBool>,
    rel: &mut Relatorio,
) -> Result<()> {
    let alvo = match (&op.ip, op.descobrir) {
        (Some(ip), _) => Alvo::Ip(ip.clone()),
        (None, true) => {
            *estado_placa.lock().unwrap() = Estado::Procurando;
            Alvo::Descobrir { prazo: Duration::from_secs(10) }
        }
        (None, false) => anyhow::bail!("diga --ip <endereço> ou --descobrir"),
    };
    let pin = op
        .pin
        .as_deref()
        .map(Pin::parse)
        .transpose()
        .map_err(anyhow::Error::new)?;

    *estado_placa.lock().unwrap() = Estado::Conectando;
    let mut pronto = nucleo::conectar_como_receptor(
        alvo,
        &op.device_id,
        &op.display_name,
        pin,
        PairedPeers::new(),
    )
    .map_err(anyhow::Error::new)?;

    rel.emissor = "<nome omitido>".into();
    println!("conectado ao emissor");
    if let Some((local, remoto)) = pronto.session.selected_pair() {
        println!("  candidato ICE: {} -> {}", crate::higiene_do_registro::candidato(&local), crate::higiene_do_registro::candidato(&remoto));
    }

    *estado_placa.lock().unwrap() = Estado::EsperandoImagem;

    let track = pronto
        .session
        .proxima_track(Duration::from_secs(20))
        .context("nenhuma track de vídeo chegou em 20 s — o outro lado abriu uma?")?;
    rel.track = format!("{:?} [{}]", track.kind(), track.mid());
    println!("  track: {}", rel.track);
    if !track.kind().e_video() {
        anyhow::bail!("track de {:?} não é vídeo", track.kind());
    }

    // Fila curta e com descarte, não fila que cresce. O contrato proíbe enfileirar; quatro
    // quadros é o bastante para absorver um soluço do decoder sem virar atraso acumulado.
    let (envia, recebe) = crossbeam_channel::bounded::<DaRede>(4);
    let recebidos = Arc::new(AtomicU64::new(0));
    let idrs = Arc::new(AtomicU64::new(0));
    let descartados = Arc::new(AtomicU64::new(0));
    let pedir_idr = Arc::new(AtomicBool::new(false));
    // Quando o último IDR chegou, no relógio do QPC. Carimbado na chegada, e não na volta do laço
    // que o observa: senão o tempo sem referência sairia quantizado na sondagem de 50 ms, e a
    // medida do conserto seria a medida da sondagem — foi exatamente o que aconteceu na primeira
    // leitura da mesma medida no plugin de OBS (62 · 62 · 64 · 64 ms, todos o relógio do laço).
    let ultimo_idr_us = Arc::new(AtomicU64::new(0));

    {
        let (recebidos, idrs, descartados, pedir_idr, ultimo_idr_us) = (
            Arc::clone(&recebidos),
            Arc::clone(&idrs),
            Arc::clone(&descartados),
            Arc::clone(&pedir_idr),
            Arc::clone(&ultimo_idr_us),
        );
        track.ao_receber_quadro(move |q: QuadroCodificado<'_>| {
            // Roda numa thread da libdatachannel. Regra: copiar e sair. Nada de COM, nada de
            // disco, nada de bloqueio — e nenhuma chamada de volta para a API C daqui.
            let chegada_us = cano::qpc_us();
            recebidos.fetch_add(1, Ordering::Relaxed);
            if q.idr {
                idrs.fetch_add(1, Ordering::Relaxed);
                ultimo_idr_us.store(chegada_us, Ordering::Relaxed);
            }
            let item = DaRede {
                annexb: q.annexb.to_vec(),
                idr: q.idr,
                chegada_us,
            };
            if envia.try_send(item).is_err() {
                // Descartar é o comportamento certo num espelhamento ao vivo; o que não pode é
                // descartar em silêncio e deixar o decoder sem referência para sempre.
                descartados.fetch_add(1, Ordering::Relaxed);
                pedir_idr.store(true, Ordering::Relaxed);
            }
        });
    }

    // O fio de decode: é ele que tem apartamento COM e fala com o Media Foundation.
    //
    // A bandeira de parada é **própria**, e não a global: o fio precisa morrer antes de esta
    // função retornar, senão o `join` abaixo espera para sempre. A global só é baixada depois,
    // por quem chamou.
    let parar_decode = Arc::new(AtomicBool::new(false));
    let fio_decode = {
        let (dist, parar_decode) = (Arc::clone(dist), Arc::clone(&parar_decode));
        std::thread::spawn(move || decodificar(recebe, dist, parar_decode))
    };
    let _ = parar; // a global é de quem chamou; ver acima.

    // Pedir IDR ao entrar na sessão. Sem isto a Frente 6 mediu **3,71 s** de tela sem imagem
    // contra 44 ms com — e um app abrindo a câmera virtual é exatamente o caso "entrar no meio
    // da sessão" que aquele número descreve.
    let mut pediu = 0u64;
    for _ in 0..50 {
        if track.pedir_idr().is_ok() {
            pediu += 1;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    println!(
        "  pedido de IDR na entrada: {}",
        if pediu > 0 { "enviado" } else { "NÃO saiu" }
    );

    // ------------------------------------------------------------------------------------------
    // Pedir IDR quando **o núcleo** perde quadro — e não só quando a fila daqui descarta
    //
    // O laço abaixo já reemitia PLI, mas por dois gatilhos que são os dois locais: "um app abriu a
    // câmera" e "a minha fila do decoder encheu". Nenhum dos dois vê a rede. O
    // `anomalia-de-sequencia.md` separou as duas coisas explicitamente: os "3 descartados na fila"
    // desta sonda no Dell **não** são perda de rede — os 1803 quadros chegaram —, e juntá-los com
    // `sequence_anomalies` mistura vazão de decodificador com rádio.
    //
    // O gatilho que faltava é `quadros_descartados()` da track, que é o `frames_dropped` do
    // contrato: quadro que o depacotizador condenou porque faltou pacote. É a segunda metade do
    // `pedir_idr()` do `contrato-track.md` — "ou quando o decoder perde sincronia" —, e sem ela o
    // decodificador fica sem referência até o próximo IDR programado do emissor.
    //
    // **Com o mesmo piso de supressão das outras cascas**, e pelo mesmo motivo medido: atender um
    // PLI injeta um IDR inteiro em rajada no caminho que acabou de perder pacote.
    const SONDAGEM_DE_PERDA: Duration = Duration::from_millis(50);
    // **Dois pisos, e o motivo foi medido nesta máquina.** Com um piso só, de 500 ms, o pedido que
    // a fila do decoder dispara gastava o orçamento e a perda de rede — que vem do mesmo soluço,
    // uns 30 ms depois — esperava os 500 ms inteiros: três corridas seguidas no Dell G3 deram
    // 462 · 519 · 518 ms de decodificador sem referência, contra 24 e 25 ms na corrida em que a
    // ordem se inverteu. Supressão é **por causa**: um PLI que saiu antes de a perda existir não
    // pode consertá-la. O piso longo passa a valer só para insistir num pedido não atendido.
    const PISO_DO_PRIMEIRO_PEDIDO: Duration = Duration::from_millis(100);
    const PISO_ENTRE_REPETICOES: Duration = Duration::from_millis(500);

    let mut perdidos_antes = track.quadros_descartados();
    let mut idrs_quando_perdeu = 0u64;
    let mut perda_pendente = false;
    let mut pediu_por_esta_perda = false;
    let mut pedido_local = false;
    let mut ultimo_pli = Instant::now();
    let mut perdas_vistas = 0u64;
    let mut perda_em_us = 0u64;
    let mut sem_referencia_ms: Vec<u64> = Vec::new();

    let fim = Instant::now() + Duration::from_secs(op.segundos);
    let mut evento = EventoDeSessao::Nenhum;
    while Instant::now() < fim {
        // Um IDR que chega sozinho apaga o pedido pendente: se o GOP do emissor consertou dentro
        // da janela de supressão, pedir seria gastar uma rajada de IDR à toa.
        if perda_pendente && idrs.load(Ordering::Relaxed) > idrs_quando_perdeu {
            perda_pendente = false;
            // O tempo em que o decodificador ficou sem referência. É o número que diz se o
            // conserto está funcionando nesta instalação, e sai uma vez por evento de perda.
            let volta = ultimo_idr_us.load(Ordering::Relaxed);
            let ms = volta.saturating_sub(perda_em_us) / 1000;
            println!("  referência de volta em {ms} ms (IDR depois da perda)");
            sem_referencia_ms.push(ms);
        }
        let perdidos = track.quadros_descartados();
        if perdidos > perdidos_antes {
            perdas_vistas += perdidos - perdidos_antes;
            if !perda_pendente {
                perda_pendente = true;
                pediu_por_esta_perda = false;
                idrs_quando_perdeu = idrs.load(Ordering::Relaxed);
                perda_em_us = cano::qpc_us();
                println!("  o núcleo perdeu quadro (frames_dropped -> {perdidos}); pedindo IDR");
            }
        }
        perdidos_antes = perdidos;

        // Um app acabou de abrir a câmera: ele entra no meio da sessão e não viu IDR nenhum.
        // A bandeira é lida com `swap` e **guardada** num pendente próprio: sob o piso de
        // supressão, ler e descartar perderia o pedido em silêncio — que é o defeito que este
        // laço existe para não ter.
        if alguem_abriu.swap(false, Ordering::Relaxed) || pedir_idr.swap(false, Ordering::Relaxed) {
            pedido_local = true;
        }
        let piso = if perda_pendente && !pediu_por_esta_perda {
            PISO_DO_PRIMEIRO_PEDIDO
        } else {
            PISO_ENTRE_REPETICOES
        };
        if (pedido_local || perda_pendente) && ultimo_pli.elapsed() >= piso {
            match track.pedir_idr() {
                Ok(()) => {
                    pediu += 1;
                    ultimo_pli = Instant::now();
                    pedido_local = false;
                    if perda_pendente {
                        pediu_por_esta_perda = true;
                    }
                }
                // Não engolir: pedido recusado é o receptor ficando sem imagem, e o header manda
                // insistir por alguns milissegundos. O pendente continua de pé para a volta seguinte.
                Err(e) => eprintln!("  pedido de IDR falhou: {}", crate::resumo_erro(&e)),
            }
        }
        if dist.ha_video_recente() {
            *estado_placa.lock().unwrap() = Estado::EsperandoImagem;
        }
        evento = pronto.proximo_evento(SONDAGEM_DE_PERDA);
        if evento != EventoDeSessao::Nenhum {
            println!("  sessão: {}", crate::higiene_do_registro::sanitizar(&format!("{evento:?}")));
            break;
        }
    }
    rel.perdas_da_rede = perdas_vistas;
    rel.anomalias_de_sequencia = track.pacotes_perdidos();
    rel.sem_referencia_ms = sem_referencia_ms;

    rel.pedidos_de_idr = pediu;
    rel.quadros_da_rede = recebidos.load(Ordering::Relaxed);
    rel.idrs_da_rede = idrs.load(Ordering::Relaxed);
    rel.descartados_na_fila = descartados.load(Ordering::Relaxed);
    rel.evento_final = format!("{evento:?}");

    *estado_placa.lock().unwrap() = match evento {
        EventoDeSessao::Nenhum => Estado::SemAparelho,
        _ => Estado::Caiu,
    };

    // Ordem deliberada, e é a regra de plataforma do Windows em forma de código: primeiro o
    // `Link` e a sessão morrem (o que baixa a bandeira `SessaoViva` de todas as tracks), depois
    // o fio de decode termina. Nada guarda handle de track depois daqui.
    pronto.link.close("recepção encerrada");
    drop(pronto);
    // A track sai **depois** da sessão, que é a ordem que baixa a bandeira `SessaoViva` antes de
    // qualquer chamada à API C — a regra de plataforma do Windows da `docs/divida-do-nucleo.md`.
    // Soltar a track aqui também solta o tratador, e com ele a ponta de envio do canal.
    drop(track);
    parar_decode.store(true, Ordering::Relaxed);

    if let Ok(Ok(medidas)) = fio_decode.join() {
        rel.resolucao_recebida = medidas.resolucao;
        rel.decoder = medidas.decoder;
        rel.decoder_e_hardware = medidas.hardware;
        rel.adaptador = medidas.adaptador;
        rel.quadros_decodificados = medidas.decodificados;
        rel.decode_ms = estat(medidas.decode_ms);
        rel.escala_ms = estat(medidas.escala_ms);
        rel.rede_ate_pronto_ms = estat(medidas.rede_ate_pronto_ms);
        rel.primeira_imagem_ms = medidas.primeira_imagem_ms;
        rel.quadros_carimbados_de_bancada = medidas.carimbados;
    }

    quall_core::transport::cleanup();
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Decode + escala
// ---------------------------------------------------------------------------------------------

#[derive(Default)]
struct Medidas {
    resolucao: String,
    decoder: String,
    hardware: bool,
    adaptador: String,
    decodificados: u64,
    decode_ms: Vec<f64>,
    escala_ms: Vec<f64>,
    rede_ate_pronto_ms: Vec<f64>,
    primeira_imagem_ms: Option<f64>,
    /// Quantos quadros saíram **com** o carimbo de bancada nos pixels. No caminho normal é zero,
    /// e é assim que o produtor declara o próprio estado — a prova não depende de ler o código.
    carimbados: u64,
}

fn decodificar(
    recebe: crossbeam_channel::Receiver<DaRede>,
    dist: Arc<Distribuidor>,
    parar: Arc<AtomicBool>,
) -> Result<Medidas> {
    unsafe {
        windows::Win32::System::Com::CoInitializeEx(
            None,
            windows::Win32::System::Com::COINIT_MULTITHREADED,
        )
        .ok()
        .context("CoInitializeEx no fio de decode")?;
        windows::Win32::Media::MediaFoundation::MFStartup(
            crate::mf_versao(),
            windows::Win32::Media::MediaFoundation::MFSTARTUP_FULL,
        )
        .context("MFStartup no fio de decode")?;
    }
    let r = decodificar_de_verdade(recebe, dist, parar);
    unsafe {
        let _ = windows::Win32::Media::MediaFoundation::MFShutdown();
        windows::Win32::System::Com::CoUninitialize();
    }
    r
}

fn decodificar_de_verdade(
    recebe: crossbeam_channel::Receiver<DaRede>,
    dist: Arc<Distribuidor>,
    parar: Arc<AtomicBool>,
) -> Result<Medidas> {
    let mut m = Medidas::default();

    let escolhido = decoder::find_and_activate_h264_decoder()
        .map_err(|e| anyhow::anyhow!("nenhum MFT de decode H.264 ativou: {e}"))?;
    m.decoder = escolhido.friendly_name.clone();
    m.hardware = escolhido.is_hardware;
    eprintln!(
        "decoder: \"{}\" (assíncrono={}, MF_SA_D3D11_AWARE={})",
        escolhido.friendly_name, escolhido.is_async, escolhido.is_hardware
    );

    // Mesmo raciocínio da Frente 6 e do M1: o adaptador é escolhido **depois** de saber qual MFT
    // ativou, porque `MFT_MESSAGE_SET_D3D_MANAGER` só aceita um dispositivo D3D11 criado no mesmo
    // adaptador do MFT.
    let vendor = if escolhido.friendly_name.to_uppercase().contains("NVIDIA") {
        device::VENDOR_NVIDIA
    } else {
        device::VENDOR_INTEL
    };
    let adaptador = device::create_device(vendor)
        .map_err(|e| anyhow::anyhow!("D3D11CreateDevice: {e}"))?;
    m.adaptador = format!("{} (vendor 0x{:04X})", adaptador.description, adaptador.vendor_id);
    eprintln!("adaptador: {}", m.adaptador);

    let gerenciador = mft::create_device_manager(&adaptador.device)
        .map_err(|e| anyhow::anyhow!("IMFDXGIDeviceManager: {e}"))?;

    // O tamanho declarado aqui é só um ponto de partida: o SPS que vier da rede manda, e o MFT
    // avisa por `MF_E_TRANSFORM_STREAM_CHANGE`. O tamanho **de verdade** é lido do tipo de saída
    // corrente depois do primeiro quadro (ver `resolucao_do_tipo`), que é a única fonte
    // autoritativa sem escrever um leitor de SPS.
    decoder::configure(
        &escolhido,
        &gerenciador,
        &decoder::DecoderConfig { width: cano::LARGURA, height: cano::ALTURA, fps: 30 },
    )
    .map_err(|e| anyhow::anyhow!("configurar o decoder: {e}"))?;
    decoder::start_stream(&escolhido.transform)
        .map_err(|e| anyhow::anyhow!("start_stream: {e}"))?;

    let eventos = escolhido
        .events
        .clone()
        .map(mft::spawn_event_pump);
    let mut creditos: u32 = 0;

    let mut escalador: Option<Escalador> = None;
    let mut buffer = vec![0u8; cano::BYTES_NV12];
    let mut pendentes: std::collections::VecDeque<(u64, Instant)> = std::collections::VecDeque::new();
    let mut proximo_ts_100ns: i64 = 0;
    let inicio = Instant::now();
    const DURACAO_100NS: i64 = 10_000_000 / 30;

    while !parar.load(Ordering::Relaxed) {
        // 1. Entrada.
        let pode_submeter = if escolhido.is_async { creditos > 0 } else { true };
        if pode_submeter {
            match recebe.recv_timeout(Duration::from_millis(20)) {
                Ok(item) => {
                    let amostra = decoder::sample_from_bytes(
                        &item.annexb,
                        proximo_ts_100ns,
                        DURACAO_100NS,
                    )
                    .map_err(|e| anyhow::anyhow!("empacotar amostra: {e}"))?;
                    match unsafe { escolhido.transform.ProcessInput(0, &amostra, 0) } {
                        Ok(()) => {
                            proximo_ts_100ns += DURACAO_100NS;
                            pendentes.push_back((item.chegada_us, Instant::now()));
                            if escolhido.is_async {
                                creditos -= 1;
                            }
                        }
                        // Normal no MFT síncrono: ele quer que se drene a saída antes de aceitar
                        // mais entrada. O quadro é perdido nesta volta — e é por isso que o
                        // laço drena logo abaixo, e não só quando um evento avisa.
                        Err(e) if !escolhido.is_async && e.code() == MF_E_NOTACCEPTING => {}
                        Err(e) => eprintln!("aviso: ProcessInput recusou o quadro: {}", crate::resumo_erro(&e)),
                    }
                }
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
            }
        }

        // 2. Eventos, no caminho assíncrono.
        let mut drenar = !escolhido.is_async;
        if let Some(rx) = &eventos {
            match rx.recv_timeout(Duration::from_millis(2)) {
                Ok(mft::MftEvent::NeedInput) => creditos += 1,
                Ok(mft::MftEvent::HaveOutput) => drenar = true,
                _ => {}
            }
        }

        // 3. Saída.
        if !drenar {
            continue;
        }
        let quadros = match decoder::drain_output(&escolhido.transform, decoder::OUTPUT_STREAM_ID) {
            Ok(q) => q,
            Err(e) => {
                eprintln!("aviso: drain_output falhou: {}", crate::resumo_erro(&e));
                continue;
            }
        };
        for quadro in quadros {
            let (chegada_us, submetido_em) = match pendentes.pop_front() {
                Some(p) => p,
                None => (cano::qpc_us(), Instant::now()),
            };
            m.decodificados += 1;
            m.decode_ms
                .push(submetido_em.elapsed().as_secs_f64() * 1000.0);

            // O tamanho vem do tipo de saída corrente, não da textura: um decoder de hardware
            // devolve textura alinhada (1088 linhas para 1080), e usar a textura faria a escala
            // incluir a sobra.
            let Some((codificado, visivel)) = abertura_do_tipo(&escolhido.transform) else {
                continue;
            };
            if escalador.as_ref().map(|e| e.entrada()) != Some((codificado, visivel)) {
                let (vw, vh) = (visivel.right - visivel.left, visivel.bottom - visivel.top);
                eprintln!(
                    "resolução recebida: {vw}x{vh} (textura {}x{})",
                    codificado.0, codificado.1
                );
                m.resolucao = format!("{vw}x{vh}");
                escalador = Some(Escalador::novo(&adaptador.device, codificado, visivel, 30)?);
            }
            let Some(esc) = &escalador else { continue };

            let t_escala = Instant::now();
            if let Err(e) = esc.converter(&quadro.texture, quadro.subresource_index, &mut buffer) {
                eprintln!("aviso: escala falhou: {}", crate::resumo_erro(&e));
                continue;
            }
            m.escala_ms.push(t_escala.elapsed().as_secs_f64() * 1000.0);

            // O carimbo de bytes leva o QPC de **quando o quadro saiu da track**, não de agora:
            // é assim que o app consumidor mede rede→app sem precisar do relógio do emissor.
            //
            // **Não escreve nada a menos que `--carimbo-de-bancada` tenha armado.** No caminho
            // normal esta linha é um teste de um `AtomicBool` e um `return false`: o quadro que
            // sai para o Zoom/Meet/OBS é só imagem. Ver `cano::CARIMBO_ARMADO`.
            if cano::carimbar(&mut buffer, chegada_us) {
                m.carimbados += 1;
            }
            if m.primeira_imagem_ms.is_none() {
                m.primeira_imagem_ms = Some(inicio.elapsed().as_secs_f64() * 1000.0);
                eprintln!(
                    "primeira imagem publicada em {:.1} ms",
                    m.primeira_imagem_ms.unwrap()
                );
            }
            m.rede_ate_pronto_ms
                .push((cano::qpc_us().saturating_sub(chegada_us)) as f64 / 1000.0);
            dist.publicar(std::sync::Arc::new(buffer.clone()), chegada_us, true);
        }
    }

    Ok(m)
}

/// Do tipo de saída corrente do MFT: o tamanho **codificado** da textura e o retângulo que é
/// imagem de verdade dentro dela.
///
/// Dois motivos para esta função existir, e os dois foram medidos nesta bancada.
///
/// 1. **`MF_MT_FRAME_SIZE` não é o tamanho da imagem.** Um vídeo 1920x1080 do MacBook chegou
///    declarado como 1920x**1088**: o H.264 codifica em macroblocos de 16 e arredonda a altura
///    para cima. Quem sabe o tamanho certo é `MF_MT_MINIMUM_DISPLAY_APERTURE`, um blob com a
///    estrutura `MFVideoArea` (dois `MFOffset` de 4 bytes e um par de `i32`). Sem ele o letterbox
///    calculava contra 1088 e punha quatro pixels de barra preta nas laterais de um vídeo 16:9,
///    além de espremer as oito linhas de preenchimento do decoder dentro do quadro.
/// 2. **O subtipo pode mudar sem aviso.** `drain_output` trata `MF_E_TRANSFORM_STREAM_CHANGE`
///    escolhendo o tipo de índice 0 — que nesta bancada é NV12, mas nada na API promete. Se um
///    dia não for, o sintoma seria uma vista de processador de vídeo recusada com `E_INVALIDARG`;
///    aqui a causa aparece por escrito.
fn abertura_do_tipo(
    transform: &windows::Win32::Media::MediaFoundation::IMFTransform,
) -> Option<((u32, u32), windows::Win32::Foundation::RECT)> {
    use windows::Win32::Foundation::RECT;
    unsafe {
        let tipo = transform.GetOutputCurrentType(0).ok()?;
        if tipo.GetGUID(&MF_MT_SUBTYPE).ok()? != MFVideoFormat_NV12 {
            eprintln!("aviso: o tipo de saída do decoder deixou de ser NV12");
            return None;
        }
        let empacotado = tipo.GetUINT64(&MF_MT_FRAME_SIZE).ok()?;
        let codificado = ((empacotado >> 32) as u32, empacotado as u32);

        // `MFVideoArea`: OffsetX (MFOffset: u16 fract + i16 value), OffsetY (idem), Area (SIZE de
        // dois i32). Dezesseis bytes. A parte fracionária é ignorada de propósito: um recorte de
        // meio pixel não existe num plano NV12, cujo croma já é subamostrado 2x2.
        let mut area = [0u8; 16];
        let mut lidos = 0u32;
        let visivel = match tipo.GetBlob(
            &MF_MT_MINIMUM_DISPLAY_APERTURE,
            &mut area,
            Some(&mut lidos),
        ) {
            Ok(()) if lidos as usize == area.len() => {
                let ox = i16::from_le_bytes([area[2], area[3]]) as i32;
                let oy = i16::from_le_bytes([area[6], area[7]]) as i32;
                let cx = i32::from_le_bytes([area[8], area[9], area[10], area[11]]);
                let cy = i32::from_le_bytes([area[12], area[13], area[14], area[15]]);
                if cx > 0 && cy > 0 && (ox + cx) as u32 <= codificado.0 && (oy + cy) as u32 <= codificado.1
                {
                    RECT { left: ox, top: oy, right: ox + cx, bottom: oy + cy }
                } else {
                    eprintln!(
                        "aviso: abertura de exibição implausível ({ox},{oy} {cx}x{cy}) para uma                          textura {}x{}; usando a textura inteira",
                        codificado.0, codificado.1
                    );
                    RECT { left: 0, top: 0, right: codificado.0 as i32, bottom: codificado.1 as i32 }
                }
            }
            // Sem abertura declarada, a textura inteira **é** a imagem. É o caso do 1280x720, em
            // que 720 já é múltiplo de 16.
            _ => RECT { left: 0, top: 0, right: codificado.0 as i32, bottom: codificado.1 as i32 },
        };
        Some((codificado, visivel))
    }
}
