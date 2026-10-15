//! A coreografia de sessão do núcleo, do lado desta frente.
//!
//! # Por que este arquivo existe, se `apps/windows/src/connect.rs` já fazia isto
//!
//! Fazia, contra outro núcleo. Aquele arquivo monta um `SessionConfig` com cinco campos
//! (`announcement`, `pin`, `known`, `transport`, `timeout`); o `SessionConfig` de hoje tem
//! **sete** — ganhou `tracks` e `cancelamento`. Um `struct literal` sem campo é erro de
//! compilação, então `quall-capture-probe --features net` **não compila** contra o núcleo do
//! tronco de hoje. Medido, não suposto: é por isso que este pacote depende dele com as features
//! padrão (sem `net`) e refaz aqui as ~40 linhas de coreografia.
//!
//! O que **não** se refaz é o que interessa: `decoder`, `device` e `encoder` daquele pacote
//! entram inteiros, e são eles que carregam o decode em hardware já provado.
//!
//! # Regra de plataforma do Windows que este arquivo respeita
//!
//! `docs/divida-do-nucleo.md`: **nunca chamar a API C com um id que possa estar morto** — no
//! Windows a exceção da libdatachannel sobe de dentro do `lock_guard` do mutex global sem
//! soltá-lo, e a próxima chamada trava o processo para sempre. Aqui isso se traduz em uma regra
//! simples e verificável: o `Ready` (e portanto a `Session`, o `Link` e as tracks) vive numa
//! variável só, é solto uma vez, e **nada do resto do programa guarda cópia de handle**. O cano
//! cai e reconecta o tempo todo; a sessão, não. Ver `receber.rs`, onde o laço do cano nunca toca
//! na track.

use std::net::SocketAddr;
use std::time::Duration;

use quall_core::discovery::{anuncio, endereco_manual, Advertiser, Browser};
use quall_core::error::{Error, Result};
use quall_core::pairing::{PairedPeers, Pin};
use quall_core::protocol::Capabilities;
use quall_core::session::{conectar, hospedar, Ready, SessionConfig};
use quall_core::signaling::SignalingServer;
use quall_core::track::TrackConfig;
use quall_core::transport::TransportConfig;

/// Como achar o emissor.
pub enum Alvo {
    /// Endereço digitado — o fallback obrigatório de `docs/fluxo-de-uso.md`, para rede com mDNS
    /// bloqueado ou isolamento entre segmentos.
    Ip(String),
    /// Procura por mDNS o primeiro aparelho que anuncia tela ou câmera.
    Descobrir { prazo: Duration },
}

/// Conecta como **receptor** (o papel do app do Quall no desktop: quem exibe escolhe e conecta).
pub fn conectar_como_receptor(
    alvo: Alvo,
    device_id: &str,
    display_name: &str,
    pin: Option<Pin>,
    conhecidos: PairedPeers,
) -> Result<Ready> {
    let destino: SocketAddr = match alvo {
        Alvo::Ip(texto) => endereco_manual(&texto)?,
        Alvo::Descobrir { prazo } => {
            let navegador = Browser::start()?;
            let achados = navegador.collect(prazo)?;
            navegador.stop();
            let escolhido = achados
                .into_iter()
                .find(|a| {
                    a.announcement.capabilities.screen_source
                        || a.announcement.capabilities.camera_source
                })
                .ok_or_else(|| {
                    Error::Discovery(
                        "nenhum emissor apareceu por mDNS em tempo. Se a rede bloqueia mDNS \
                         (ex.: o Firewall do Windows barrando UDP 5353 de entrada — ver \
                         docs/bancada.md), conecte pelo IP digitado."
                            .into(),
                    )
                })?;
            for endereco in &escolhido.addresses {
                eprintln!("  emissor anuncia: {endereco}");
            }
            escolhido
                .endpoint()
                .ok_or_else(|| Error::Discovery("o emissor não anunciou endereço utilizável".into()))?
        }
    };

    let eu = anuncio(
        device_id,
        display_name,
        Capabilities {
            screen_source: false,
            camera_source: false,
            sink: true,
        },
    );

    eprintln!("conectando em {destino}…");
    conectar(
        destino,
        SessionConfig {
            announcement: eu,
            pin,
            known: conhecidos,
            transport: TransportConfig::default(),
            // Quem responde não declara tracks: as do outro lado chegam pela oferta.
            tracks: Vec::new(),
            timeout: Duration::from_secs(120),
            cancelamento: Default::default(),
            // Detector de silêncio do caminho desligado, que é o padrão do núcleo. Ver
            // `SessionConfig::silencio_do_caminho`.
            silencio_do_caminho: None,
        },
    )
}

/// Sobe o lado **emissor** com uma track de vídeo, e devolve a sessão pronta.
///
/// Só existe para a medição: é o emissor que carimba o relógio dentro dos pixels (ver
/// `carimbo.rs`), e ele precisa rodar na mesma máquina do consumidor para que o relógio seja um
/// só. Ver `emitir.rs` para o porquê disso ser a diferença entre um número e uma estimativa.
pub struct EmissorPronto {
    pub pronto: Ready,
    pub pin: String,
    pub porta: u16,
    /// Mantido vivo enquanto o emissor existir: soltar o anunciante tira o serviço do mDNS.
    pub _anunciante: Option<Advertiser>,
}

#[allow(clippy::too_many_arguments)]
pub fn hospedar_com_track(
    device_id: &str,
    display_name: &str,
    porta: u16,
    rotulo: &str,
    kind: quall_core::track::TrackKind,
    pin_fixo: Option<&str>,
    prazo: Duration,
) -> Result<EmissorPronto> {
    let eu = anuncio(
        device_id,
        display_name,
        Capabilities {
            screen_source: kind == quall_core::track::TrackKind::Screen,
            camera_source: kind == quall_core::track::TrackKind::Camera,
            sink: false,
        },
    );

    let servidor = SignalingServer::bind(porta)?;
    let porta = servidor.port()?;
    let anunciante = Advertiser::start(&eu, porta).ok();
    // PIN fixo é recurso **de bancada**, não de produto: sem ele uma corrida automatizada
    // precisaria ler o número da saída de um processo para passar a outro, e a corrida ficaria
    // refém de análise de texto. No produto o PIN é sempre gerado.
    let pin = match pin_fixo {
        Some(p) => Pin::parse(p)?,
        None => Pin::generate()?,
    };
    let pin_texto = pin.to_display();

    println!("Quall — emissor de medição");
    println!("  sinalização : porta {porta}");
    println!("  PIN         : <PIN> (consulte a interface ou o PIN fixado para a bancada)");
    println!("esperando um receptor…");

    let pronto = hospedar(
        &servidor,
        SessionConfig {
            announcement: eu,
            pin: Some(pin),
            known: PairedPeers::new(),
            transport: TransportConfig::default(),
            tracks: vec![TrackConfig::new(kind, rotulo.to_string())],
            timeout: prazo,
            cancelamento: Default::default(),
            // Detector de silêncio do caminho desligado, que é o padrão do núcleo. Ver
            // `SessionConfig::silencio_do_caminho`.
            silencio_do_caminho: None,
        },
    )?;

    Ok(EmissorPronto {
        pronto,
        pin: pin_texto,
        porta,
        _anunciante: anunciante,
    })
}
