// Os identificadores e endereços de exemplos/fixtures são sintéticos; não identificam a bancada privada.
//! Sonda de bancada: prova que o núcleo do Quall **executa** no aparelho, não só que compila
//! para ele. Feita para ser empurrada por `adb push` e rodada por `adb shell`, e para medir os
//! dois números do M1 entre o MacBook e o Dell G3.
//!
//! Existe por causa do Galaxy A10s: ele é `armeabi-v7a`, 32 bits, e é o aparelho onde um núcleo
//! que assume ponteiro de 8 bytes quebra. Cross-compile verde não é prova de execução.
//!
//! ```text
//! quall-probe                       # ficha do núcleo (o que o M0 já fazia)
//! quall-probe descobrir             # navega _quall._tcp por alguns segundos
//! quall-probe emitir                # hospeda, mostra o PIN e mede a latência
//! quall-probe receber --ip 192.168.56.131
//! quall-probe receber --descobrir
//! quall-probe emitir-video --entrada captura.json
//! quall-probe receber-video --ip 192.168.56.131 --saida recebido.h264
//! ```
//!
//! Os dois últimos são o M2: exercitam a **track de mídia** — RTP, RFC 6184, PLI — com um
//! `.h264` de verdade e sem depender de captura nem de decode. Ver [`video`].
//!
//! O que a sonda mede é **ida e volta pelo canal de dados WebRTC**: o emissor carimba o quadro
//! com o próprio relógio monotônico, o receptor devolve o cabeçalho e o emissor fecha a conta.
//! Não há sincronização de relógio no meio, e não há encode: é o piso do transporte, e é contra
//! ele que o custo do VideoToolbox e do MediaCodec vai ser cobrado nos marcos seguintes.

mod audio;
mod claquete;
mod claquete_fisica;
#[cfg(feature = "opus")]
mod fec;
mod ogg;
mod teleprompter;
mod video;

use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use quall_core::cancel::Cancelamento;
use quall_core::discovery::{
    anuncio, endereco_manual_com_porta, escolher_porta_do_teleprompter, porta_para_completar,
    Advertiser, Browser, DiscoveredDevice, DEFAULT_SIGNALING_PORT,
    ESPERA_PELA_PORTA_DO_TELEPROMPTER, PORTA_DO_TELEPROMPTER, PRAZO_DE_RESOLUCAO,
};
use quall_core::error::{Error, Result};
use quall_core::media::{
    conferir_padrao, montar_eco, FrameHeader, FrameKind, LatencyStats, SyntheticPattern, HEADER_LEN,
};
use quall_core::pairing::{PairedPeers, Pin};
use quall_core::protocol::{
    Announcement, Capabilities, DeviceId, Papel, Screen, PROTOCOL_VERSION, SERVICE_TYPE,
};
use quall_core::session::{conectar, hospedar, Ready, SessionConfig};
use quall_core::signaling::SignalingServer;
use quall_core::track::{CodecDeAudio, PresetDeAudio, TrackConfig, TrackKind, TrackReceptor};
use quall_core::transport::{Delivery, TransportConfig};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let comando = args.first().map(String::as_str).unwrap_or("ficha");

    // **Antes de qualquer sessão subir.** O crate `datachannel` chama `rtcInitLogger` uma única
    // vez, dentro de `RtcPeerConnection::new`, com o nível lido de `log::max_level()`; ligar
    // depois disso não tem efeito nenhum e o sintoma seria um registro vazio com a flag ligada.
    if args.iter().any(|a| a == "--registro-da-biblioteca") {
        let ligou = quall_core::transport::ativar_registro_da_biblioteca(
            quall_core::transport::NivelDeRegistro::Informacao,
            |linha| eprintln!("{linha}"),
        );
        eprintln!(
            "registro da biblioteca: {}",
            if ligou {
                "LIGADO em Info — `Send failed` é descarte no socket de saída"
            } else {
                "NÃO ligou: já havia registrador instalado neste processo"
            }
        );
    }

    let r = match comando {
        "ficha" => ficha(),
        #[cfg(feature = "opus")]
        // Quadros de 20 ms: `--segundos N` são 50·N quadros. Padrão de 10 s.
        "fec-em-buraco" => fec::bancada(Opcoes::parse(&args[1..]).segundos.as_secs().max(1) * 50),
        "descobrir" => descobrir(&Opcoes::parse(&args[1..])),
        "emitir" => emitir(&Opcoes::parse(&args[1..])),
        "receber" => receber(&Opcoes::parse(&args[1..])),
        "emitir-video" => emitir_video(&Opcoes::parse(&args[1..])),
        "receber-video" => receber_video(&Opcoes::parse(&args[1..])),
        "emitir-audio" | "emitir-áudio" => emitir_audio(&Opcoes::parse(&args[1..])),
        "receber-audio" | "receber-áudio" => receber_audio(&Opcoes::parse(&args[1..])),
        // A claquete física do R5 (G4): câmera + microfone de um emissor real, no relógio comum.
        "receber-claquete" => receber_claquete(&Opcoes::parse(&args[1..])),
        // O teleprompter (F6a): só mensagens, nenhum vídeo.
        "teleprompter" => {
            let mut op = Opcoes::parse(&args[1..]);
            op.papel = Some(Papel::Teleprompter);
            // Sem `--porta`, a do teleprompter — escolhida como o produto escolhe (§11.1 do
            // contrato): a 7979, esperando por ela; ocupada, a próxima livre.
            if !op.porta_explicita {
                op.porta = escolher_porta_do_teleprompter(ESPERA_PELA_PORTA_DO_TELEPROMPTER)
                    .unwrap_or(PORTA_DO_TELEPROMPTER);
            }
            teleprompter::prompter(&op)
        }
        "controle" => {
            let mut op = Opcoes::parse(&args[1..]);
            op.papel = Some(Papel::ControleRemoto);
            teleprompter::controle(&op)
        }
        "ajuda" | "-h" | "--help" => {
            ajuda();
            Ok(())
        }
        outro => {
            eprintln!("comando desconhecido: {outro}");
            ajuda();
            return ExitCode::FAILURE;
        }
    };

    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            // O **código** ao lado da prosa, porque é o código que as cascas ramificam e a prosa
            // que elas mostram. Sem isto a sonda não conseguia exibir a diferença entre
            // `NO_ROUTE` e `TRANSPORT` — os dois têm o prefixo `transporte:` de propósito, para
            // não quebrar as cascas que ainda casam por texto — nem entre os três erros de
            // pareamento. Ver as dívidas 28 e 29.
            eprintln!("erro [{}]: {e}", codigo_de(&e));
            ExitCode::FAILURE
        }
    }
}

/// O nome do código de status que a fronteira C devolveria em `quall_last_status()`.
///
/// Escrito à mão em vez de derivado porque a sonda não depende do `quall-ffi`; o que importa é
/// que a bancada possa **ver** o que a casca vê.
fn codigo_de(e: &Error) -> &'static str {
    match e {
        Error::Invalid(_) => "INVALID",
        Error::Protocol(_) => "PROTOCOL",
        Error::Discovery(_) => "DISCOVERY",
        Error::Signaling(_) => "SIGNALING",
        Error::Transport(_) => "TRANSPORT",
        Error::NoRoute(_) => "NO_ROUTE",
        Error::Pairing(_) => "PAIRING",
        Error::WrongPin(_) => "WRONG_PIN",
        Error::NeedsPin(_) => "NEEDS_PIN",
        Error::Timeout(_) => "TIMEOUT",
        Error::Closed => "CLOSED",
        Error::Cancelled => "CANCELLED",
        Error::Io(_) => "IO",
        Error::Ocupado(_) => "BUSY",
    }
}

fn ajuda() {
    eprintln!(
        "\
quall-probe — sonda de bancada do Quall

  quall-probe                       ficha do núcleo (versão, ponteiro, ida e volta por JSON)
  quall-probe descobrir             navega {SERVICE_TYPE} na LAN
  quall-probe emitir                hospeda a sinalização, mostra o PIN e mede a latência
  quall-probe receber --ip HOST     conecta pelo IP digitado (fallback obrigatório)
  quall-probe receber --descobrir   acha o emissor por mDNS
  quall-probe emitir-video          manda um .h264 pela track de mídia
  quall-probe receber-video         recebe a track e grava o .h264 do outro lado
  quall-probe receber-claquete      claquete física do R5: grava câmera + microfone com os
                                    carimbos do relógio comum (--saida PREFIXO); analisar com
                                    tools/claquete-fisica/analisar.py
  quall-probe teleprompter          hospeda como teleprompter (só mensagens; ver --pin, --porta).
                                    Sem --porta, a do teleprompter: 7979, ou a próxima livre
  quall-probe controle --ip HOST    conecta como controle remoto (sem porta, a 7979), manda um
                                    roteiro de --carga bytes e mede a confirmação de 20 edições

teleprompter / controle  (docs/contrato-teleprompter.md §11)
  --texto BYTES      o roteiro sintético com que a réplica começa, antes de conectar. No
                     controle, liga a pergunta do texto no lugar da medição das 20 edições
  --escolha QUAL     controle: liga a pergunta do texto e responde `prompter` (usar o do
                     prompter), `meu` (mandar o meu) ou `nenhuma` (deixa a pergunta aberta e
                     sai). Sem --escolha, a pergunta fica desligada: vale o último que mudou
  --salvo ARQ        controle: carrega a réplica do arquivo, se existir, e a grava no fim
  --segurar MS       controle: segurar para rolar (§12) — aperta, segura MS ms e solta
  --para-tras        com --segurar: para trás, a partir do meio do percurso
  --sair-segurando   com --segurar: sai do processo com o dedo no botão (o prompter tem de parar)
  --vezes N          com --segurar: aperta e solta N vezes, e resume a confirmação do soltar
  --descartar-pct P  teleprompter: joga fora P % das mensagens que chegam, antes da réplica —
                     perda SIMULADA na chegada, sem a retransmissão do SCTP (§12.3)
  --gravar           controle: pede ao prompter que grave (§13) e espera a resposta — a
                     duração contando, ou a recusa com o motivo
  --parar            controle: pede que pare e espera a resposta. Com --gravar, grava,
                     espera --gravar-por e para
  --gravar-por MS    com --gravar --parar: quanto esperar gravando (padrão: 3000)
  --sair-gravando    com --gravar: sai do processo gravando (a queda: o prompter continua)
  --recusar-gravacao MOTIVO
                     teleprompter: recusa todo pedido de gravação com MOTIVO. Sem ela, a
                     sonda aceita (finge o arquivo: não grava nada)

opções comuns
  --id ID            identidade deste aparelho (padrão: sorteada a cada execução)
  --nome NOME        nome exibido na lista
  --segundos N       duração da medição ou da navegação (padrão: 10)
  --segredos ARQ     arquivo JSON de aparelhos pareados; sem ele o PIN é pedido toda vez
  --pin 123456       PIN. No emissor, fixa em vez de sortear; no receptor, é o que foi digitado
  --entrega MODO     `tempo-real` (padrão) ou `confiavel`. Ver a nota abaixo
  --ligar-em END     prende os candidatos ICE a UMA interface, pelo endereço local dela.
                     ATENÇÃO: ligar DESISTE das outras — a Wi-Fi deixa de ser candidata, não há
                     corrida nem fallback, e endereço errado não degrada: a sessão não fecha.
                     É o que permite pedir à libjuice um endereço que ela filtraria sozinha
                     (`169.254/16`). Confira com a linha `caminho (json)` do relato.

emitir
  --porta P          porta de sinalização (padrão: {DEFAULT_SIGNALING_PORT}; 0 = o sistema escolhe)
  --fps N            quadros por segundo (padrão: 60)
  --carga BYTES      carga por quadro, além do cabeçalho (padrão: 1200)
  --sem-mdns         não anuncia; força o outro lado a usar --ip

receber
  --ip HOST[:PORTA]  endereço do emissor
  --descobrir        procura o emissor por mDNS antes de conectar

emitir-video / receber-video  (M2: track de mídia, não canal de dados)
  --entrada ARQ.json sidecar do contrato (docs/contrato-sidecar.md); o `.h264` é procurado
                     ao lado dele, pelo nome que o `video_file` diz
  --saida ARQ.h264   onde o receptor grava o Annex-B que chegou
  --encaminhar SOQ   repassa cada quadro para `tools/vidro-a-vidro/vidro-receptor`, que decodifica
                     e lê a faixa de Gray nos pixels. É o fio da campanha de vidro a vidro com
                     câmera de verdade: a sonda serve o soquete, o arnês conecta.
  --repetir          manda o arquivo em laço, para medir por mais tempo que a captura dura
  --com-audio        põe uma track de som sintético (tom) na oferta, depois da de vídeo
  --som-primeiro     com --com-audio, a track de som vem ANTES da de vídeo na oferta: é o
                     receptor que recebe o som primeiro (docs/som-no-receptor.md §7.0)
  --ppm-no-audio N   com --com-audio, o relógio de mídia do som anda N ppm mais depressa que o do
                     vídeo: deriva entre emissor e DAC, e entre as tracks, sem um segundo aparelho
  --claquete SEMENTE com --com-audio: estouros de 10 ms a 3150 Hz no som, a cada 0,7–1,3 s, com
                     0 ou +40 ms de propósito; o quadro de vídeo do evento é o do índice da régua
  --claquete-saida ARQ.json  grava a verdade de cada evento (quadro, carimbo, deslocamento)
  --atraso-no-audio MS  o som sai MS mais tarde, com o carimbo intacto (controle 2 do §9.3)
  --deslocar-audio MS   o carimbo do som anda MS deslocado do vídeo (controle 6 do §9.3)
  --perder-no-audio N   perde 1 de cada N quadros de som depois de 5 s (controle 3): o quadro
                     sai numerado e grande demais, e a porta puxada do receptor o joga fora
  --travar-audio-ms MS  o som para de sair por MS aos --travar-em S (padrão 12) e sai de uma vez,
                     com o carimbo intacto (controle 4)
  --origem-na-volta S   soma às duas tracks a origem que põe a volta de 32 bits do relógio RTP do
                     som S segundos depois do começo (controle 5)
  --trocar-no-som N  receber-video --relogio: troca a ordem de 1 par de pacotes de som a cada N,
                     na chegada, antes do núcleo (a reordenação do controle 5)
  --track screen|camera   qual track abrir (padrão: screen)
  --pedir-idr-em N   o receptor pede um IDR aos N segundos e mede quanto demora a imagem
                     voltar. É a prova do PLI, e o número que o M2 tem de produzir
  --politica-de-perda  o receptor pede IDR QUANDO PERDE, como o app de produto faz. Sem isto a
                     sonda pede um IDR na entrada e mais nenhum — e um emissor cuja quinta porta
                     só age a pedido nunca recria o encoder contra ela.
  --piso-primeiro-ms N / --piso-repeticao-ms N   os dois pisos da política (100 / 500 no produto)
  --relatar-a-cada N   imprime uma linha FATIA a cada N s, com a perda DA FATIA ao lado da
                     acumulada. Numa sessão longa, o total do fim não diz se a perda mudou.
  --relogio          aceita também a track de som (sem tocar nada) e imprime a cada segundo uma
                     linha RELOGIO com o relógio comum das duas tracks: status, deslocamento,
                     resíduo, resíduo da janela, deriva entre tracks e violações da guarda. É a
                     testemunha da S8 (os emissores carimbando certo).
  aceita todas as opções comuns de `emitir` e `receber` (--ip, --pin, --porta, --descobrir…)

  O receptor grava o `.h264` para que a prova seja externa, e não relato:
    ffprobe -v error -show_streams -count_frames recebido.h264

sobre --entrega
  `confiavel` é o padrão do WebRTC: o SCTP retransmite o que se perdeu e segura o que veio
  depois. Zero perda e latência de segundos são o mesmo fenômeno. `tempo-real` desliga
  retransmissão e ordenação, que é o que espelhamento ao vivo precisa. Os dois modos existem
  aqui para que a diferença seja medida, não argumentada. A opção vale no **emissor**: é ele
  quem cria o canal, e a negociação vale para os dois sentidos.
"
    );
}

/// A ficha que o M0 já imprimia, mais o que o M1 acrescentou.
fn ficha() -> Result<()> {
    println!("quall-probe");
    println!("  versão do protocolo : {PROTOCOL_VERSION}");
    println!("  serviço mDNS        : {SERVICE_TYPE}");
    println!("  tamanho do ponteiro : {} bytes", size_of::<usize>());
    println!("  cabeçalho de quadro : {HEADER_LEN} bytes");

    let a = anuncio(
        "probe",
        "sonda",
        Capabilities {
            screen_source: true,
            camera_source: true,
            sink: true,
        },
    );
    let json = serde_json::to_string(&a).map_err(Error::from)?;
    let volta: Announcement = serde_json::from_str(&json).map_err(Error::from)?;
    if volta != a {
        return Err(Error::Protocol(
            "anúncio não sobreviveu à ida e volta".into(),
        ));
    }
    println!("  ida e volta por JSON: ok ({} bytes)", json.len());

    // Prova que o pareamento roda de verdade neste aparelho — inclusive o X25519, que é o
    // pedaço com mais chance de se comportar diferente em 32 bits.
    let pin = Pin::generate()?;
    let pin_texto = pin.to_display();
    if pin_texto.len() != 6 {
        return Err(Error::Pairing("PIN gerado com tamanho errado".into()));
    }
    println!("  gerador de PIN      : ok");

    println!("ok");
    Ok(())
}

fn descobrir(op: &Opcoes) -> Result<()> {
    let navegador = Browser::start()?;
    println!("navegando {SERVICE_TYPE} por {} s…", op.segundos.as_secs());
    let achados = navegador.collect(op.segundos)?;
    navegador.stop();

    if achados.is_empty() {
        println!("nenhum aparelho Quall respondeu.");
        println!();
        println!("Isso não quer dizer que não há nenhum. Numa rede com AP isolation, ou com o");
        println!("Firewall do Windows barrando UDP 5353 de entrada, o mDNS some sem erro — só");
        println!("silêncio. Use `receber --ip <endereço>` para contornar.");
        return Ok(());
    }

    for a in &achados {
        imprimir_aparelho(a);
    }
    Ok(())
}

fn imprimir_aparelho(a: &DiscoveredDevice) {
    let c = a.announcement.capabilities;
    println!(
        "{}  [{}]  v{}  {}{}{}",
        a.announcement.display_name,
        a.announcement.device_id.0,
        a.announcement.protocol_version,
        if c.screen_source { "tela " } else { "" },
        if c.camera_source { "câmera " } else { "" },
        if c.sink { "exibe" } else { "" },
    );
    match a.endpoint() {
        Some(e) => println!("    sinalização: {e}"),
        None => println!("    sinalização: sem endereço utilizável"),
    }
    if a.addresses.len() > 1 {
        // Um MacBook com Wi-Fi, cabo, `awdl0` e interfaces de virtualização anuncia dezenas de
        // endereços. Mostrar os quatro melhores basta para diagnóstico; o resto é ruído.
        let mostrar = a.addresses.len().min(4);
        let outros: Vec<String> = a.addresses[..mostrar]
            .iter()
            .map(|i| i.to_string())
            .collect();
        let resto = a.addresses.len() - mostrar;
        println!(
            "    endereços  : {}{}",
            outros.join(", "),
            if resto > 0 {
                format!(" (+{resto})")
            } else {
                String::new()
            }
        );
    }
}

/// Emissor: hospeda a sinalização, anuncia por mDNS, pareia e mede a latência.
fn emitir(op: &Opcoes) -> Result<()> {
    let pronto = subir_emissor(op, Vec::new())?;
    medir(pronto, op)
}

/// Emissor de vídeo: a mesma subida, com uma track de saída, e o `.h264` no lugar do padrão
/// sintético.
fn emitir_video(op: &Opcoes) -> Result<()> {
    let entrada = op
        .entrada
        .clone()
        .ok_or_else(|| Error::Invalid("diga --entrada <sidecar .json>".into()))?;
    // Falhar antes de subir a sessão: um sidecar que não bate com o `.h264` faria a sonda
    // mandar lixo pela rede, e o defeito apareceria três camadas adiante.
    let (_, video) = video::Sidecar::carregar(&entrada)?;
    println!("entrada conferida: {}", video.display());

    let rotulo = format!("{} — {}", op.nome, entrada.display());
    let mut tracks = vec![TrackConfig::new(op.track, rotulo)];

    // `--com-audio` põe a **segunda** track na oferta: tela e som na mesma sessão, que é a forma
    // real do produto. Ela entra aqui, e não depois, porque o que não está na oferta SDP só entra
    // com renegociação — que o Quall não implementa.
    //
    // Existe desde 30/08/2026, para o receptor Android poder ser provado com duas tracks sem um
    // segundo aparelho. A origem é o tom sintético, sempre (`docs/audio.md` §8).
    let fonte_de_audio = if op.com_audio {
        let especie = TrackKind::SystemAudio;
        let som = TrackConfig::new(especie, format!("{} — som sintético", op.nome))
            .com_codec_de_audio(op.codec);
        // `--som-primeiro` inverte a ordem da oferta: é o caso que deixava a fonte do OBS preta
        // (a primeira track que chegava era tomada como vídeo).
        if op.som_primeiro {
            tracks.insert(0, som);
        } else {
            tracks.push(som);
        }
        let preset = especie
            .preset_de_audio()
            .map(|p| PresetDeAudio {
                codec: op.codec,
                ..p
            })
            .ok_or_else(|| Error::Invalid("a espécie de áudio não tem preset".into()))?;
        Some(audio::FonteDeQuadros::nova(&preset)?)
    } else {
        None
    };

    // As combinações sem sentido recusam **antes** de subir a sessão (crítica 10, m4).
    let sem_som = fonte_de_audio.is_none();
    if sem_som
        && (op.claquete.is_some()
            || op.ppm_no_audio != 0.0
            || op.atraso_no_audio_ms != 0
            || op.deslocar_audio_ms != 0
            || op.perder_no_audio != 0
            || op.travar_audio_ms != 0
            || op.origem_na_volta_ms.is_some())
    {
        return Err(Error::Invalid(
            "--claquete, --ppm-no-audio, --atraso-no-audio, --deslocar-audio, --perder-no-audio, \
             --travar-audio-ms e --origem-na-volta pedem --com-audio"
                .into(),
        ));
    }
    // A origem do controle 5 põe a volta do relógio RTP **do som** a S segundos do começo; a taxa
    // é a do codec pedido.
    let origem_us = match op.origem_na_volta_ms {
        None => 0,
        Some(ms) => video::origem_perto_da_volta_us(op.codec.relogio_hz(), ms * 1000).ok_or_else(|| {
            Error::Invalid(format!("--origem-na-volta {ms} ms: passa da própria volta do relógio"))
        })?,
    };
    // A verdade da claquete é "tempo de mídia do som − hora do host do quadro". Com o relógio do
    // som andando N ppm, ela anda N ppm × t (30 ms em 150 s a 200 ppm): a verdade gravada estaria
    // errada, e em silêncio.
    if op.claquete.is_some() && op.ppm_no_audio != 0.0 {
        return Err(Error::Invalid(
            "--claquete com --ppm-no-audio: a verdade de cada evento andaria com a deriva; rode separado".into(),
        ));
    }
    if op.claquete_saida.is_some() && op.claquete.is_none() {
        return Err(Error::Invalid("--claquete-saida sem --claquete".into()));
    }

    let pronto = subir_emissor(op, tracks)?;
    // O eco do que foi injetado: o `emissor.log` tem de dizer que corrida foi esta (m3).
    if !sem_som {
        println!(
            "controles do som: atraso {} ms, deslocamento {} ms, deriva {} ppm, claquete {}, \
             perda 1/{} , travada {} ms aos {} s, origem na volta {}",
            op.atraso_no_audio_ms,
            op.deslocar_audio_ms,
            op.ppm_no_audio,
            op.claquete.map(|s| format!("semente {s}")).unwrap_or_else(|| "não".into()),
            op.perder_no_audio,
            op.travar_audio_ms,
            op.travar_em_s,
            op.origem_na_volta_ms
                .map(|ms| format!("{:.3} s (+{origem_us} µs)", ms as f64 / 1000.0))
                .unwrap_or_else(|| "não".into()),
        );
    }
    let claquete = op.claquete.map(|semente| {
        claquete::Claquete::nova(semente, 3_600_000_000, op.claquete_saida.clone())
    });
    let controles = video::ControlesDoSom {
        atraso_us: op.atraso_no_audio_ms * 1000,
        deslocar_us: op.deslocar_audio_ms * 1000,
        perder_a_cada: op.perder_no_audio,
        travar: (op.travar_audio_ms > 0).then(|| {
            let inicio = op.travar_em_s * 1_000_000;
            (inicio, inicio + op.travar_audio_ms * 1000)
        }),
        origem_us,
    };
    video::emitir(pronto, &entrada, op.repetir, fonte_de_audio, op.ppm_no_audio, claquete, controles)
}

/// Emissor de áudio: sobe a sessão com uma track de áudio e manda o tom sintético.
///
/// A espécie padrão é [`TrackKind::SystemAudio`], que é a que o espelhamento de tela precisa.
/// `--track microfone` troca a espécie, e com ela o preset — ver `docs/audio.md`.
fn emitir_audio(op: &Opcoes) -> Result<()> {
    let especie = if op.track.e_audio() {
        op.track
    } else {
        // `--track` sem valor de áudio (ou omitido) cai no padrão desta rodada.
        TrackKind::SystemAudio
    };
    let rotulo = format!("{} — áudio sintético", op.nome);
    let cfg = TrackConfig::new(especie, rotulo).com_codec_de_audio(op.codec);
    let pronto = subir_emissor(op, vec![cfg])?;
    audio::emitir(pronto, op.segundos, op.saida.as_deref())
}

/// Espera a track da **espécie pedida**, drenando as que não servem.
///
/// # Por que não basta pegar a primeira
///
/// `proxima_track` entrega as tracks na ordem em que a libdatachannel as abre, e com **duas
/// tracks na mesma sessão** — tela + áudio, que é a configuração realista do produto — essa ordem
/// não é determinística. A sonda pegava a primeira e abortava com *"a track que chegou é de
/// Screen, e não é áudio"*: virava moeda.
///
/// O precedente já estava no repositório, no teste
/// `sessao_com_tracks_leva_video_e_o_pedido_de_idr_volta` de `session.rs`, que drena as duas e
/// depois procura a que quer.
///
/// As tracks descartadas são **soltas**, e isso é deliberado: uma sonda que segurasse a track de
/// vídeo manteria um receptor vivo para um fluxo que ninguém lê. Elas ficam registradas na saída
/// para que "a sonda não achou a track" nunca seja confundido com "a track não chegou".
fn esperar_track(
    pronto: &mut Ready,
    aceita: impl Fn(TrackKind) -> bool,
    o_que: &str,
    prazo: Duration,
) -> Result<TrackReceptor> {
    let fim = Instant::now() + prazo;
    let mut recusadas: Vec<String> = Vec::new();
    while Instant::now() < fim {
        let restante = fim.saturating_duration_since(Instant::now());
        let Some(t) = pronto.session.proxima_track(restante) else {
            break;
        };
        if aceita(t.kind()) {
            return Ok(t);
        }
        println!("  (ignorando track de {:?} [{}])", t.kind(), t.mid());
        recusadas.push(format!("{:?}", t.kind()));
    }
    Err(Error::Timeout(format!(
        "nenhuma track de {o_que} chegou em {:.0} s. Chegaram: {}",
        prazo.as_secs_f64(),
        if recusadas.is_empty() {
            "nenhuma".to_string()
        } else {
            recusadas.join(", ")
        }
    )))
}

/// Receptor de áudio: grava a track num `.wav` e imprime perda e jitter.
fn receber_audio(op: &Opcoes) -> Result<()> {
    let saida = op
        .saida
        .clone()
        .ok_or_else(|| Error::Invalid("diga --saida <arquivo .wav>".into()))?;
    let pronto = subir_receptor(op)?;
    audio::receber(
        pronto,
        &saida,
        op.segundos + Duration::from_secs(5),
        op.profundidade,
        op.descartar_pct,
    )
}

/// A claquete física (`claquete_fisica.rs`): grava imagem e som com os carimbos do relógio comum.
fn receber_claquete(op: &Opcoes) -> Result<()> {
    let saida = op.saida.clone().ok_or_else(|| Error::Invalid("diga --saida <prefixo>".into()))?;
    let pronto = subir_receptor(op)?;
    claquete_fisica::receber(pronto, &saida, op.segundos)
}

/// Receptor de vídeo: a mesma conexão, e grava a track num `.h264`.
fn receber_video(op: &Opcoes) -> Result<()> {
    let saida = op
        .saida
        .clone()
        .ok_or_else(|| Error::Invalid("diga --saida <arquivo .h264>".into()))?;
    let pronto = subir_receptor(op)?;
    video::receber(
        pronto,
        &saida,
        op.segundos + Duration::from_secs(10),
        op.pedir_idr_em,
        op.politica_de_perda,
        op.relatar_a_cada,
        op.encaminhar.as_deref(),
        op.relogio,
        op.trocar_no_som,
    )
}

/// Sobe o lado emissor: sinalização, mDNS, PIN, pareamento e transporte.
///
/// As tracks entram aqui e não depois porque elas fazem parte da oferta SDP — o que não estava
/// na oferta só entra com renegociação, que o Quall não implementa.
fn subir_emissor(op: &Opcoes, tracks: Vec<TrackConfig>) -> Result<Ready> {
    let mut segredos = carregar_segredos(op)?;
    let eu = op.anuncio(true);

    let servidor = SignalingServer::bind(op.porta)?;
    let porta = servidor.port()?;

    let _anunciante = if op.sem_mdns {
        println!("mDNS desligado por --sem-mdns; o receptor precisa do --ip.");
        None
    } else {
        Some(Advertiser::start(&eu, porta)?)
    };

    let pin = match &op.pin {
        Some(p) => p.clone(),
        None => Pin::generate()?,
    };

    println!("Quall — emissor");
    println!("  aparelho    : {} [{}]", eu.display_name, eu.device_id.0);
    println!("  sinalização : porta {porta}");
    for ip in ips_locais() {
        println!("  endereço    : {ip}:{porta}");
    }
    println!();
    println!("  PIN: {}", pin.to_display());
    println!();
    if !segredos.is_empty() {
        println!(
            "  ({} aparelho(s) já pareado(s); para esses o PIN não é usado)",
            segredos.len()
        );
    }
    println!("esperando um receptor…");

    let pronto = hospedar(
        &servidor,
        SessionConfig {
            announcement: eu.clone(),
            pin: Some(pin),
            known: segredos.clone(),
            transport: TransportConfig {
                delivery: op.entrega,
                bind_address: op.ligar_em.clone(),
                ..TransportConfig::default()
            },
            tracks,
            timeout: Duration::from_secs(120),
            cancelamento: Cancelamento::novo(),
            silencio_do_caminho: None,
        },
    )?;

    relatar_conexao(&pronto);
    if pronto.outcome.novo {
        println!("  pareamento  : novo, por PIN");
    } else {
        println!("  pareamento  : retomado, sem PIN");
    }
    if let Some(arquivo) = &op.segredos {
        segredos.insert(&pronto.outcome);
        fs::write(arquivo, segredos.to_json()?)?;
        println!("  segredos    : gravados em {}", arquivo.display());
    }

    Ok(pronto)
}

/// Receptor: acha o emissor (ou usa o IP digitado), pareia e devolve os ecos.
fn receber(op: &Opcoes) -> Result<()> {
    let pronto = subir_receptor(op)?;
    ecoar(pronto, op)
}

/// Sobe o lado receptor: descoberta ou IP digitado, pareamento e transporte.
fn subir_receptor(op: &Opcoes) -> Result<Ready> {
    let mut segredos = carregar_segredos(op)?;
    let eu = op.anuncio(false);

    let destino: SocketAddr = match (&op.ip, op.descobrir) {
        (Some(texto), _) => {
            // Sem porta, a do papel: 7979 para o controle remoto, 7877 para o vídeo (§11.1 do
            // contrato do teleprompter). Um link `quall://` é recusado, como no `quall_connect`.
            let e = endereco_manual_com_porta(texto, porta_para_completar(op.papel), PRAZO_DE_RESOLUCAO)?;
            println!("usando o endereço digitado: {e}");
            e
        }
        (None, true) => {
            println!("procurando um emissor por mDNS…");
            let navegador = Browser::start()?;
            let achados = navegador.collect(op.segundos)?;
            navegador.stop();
            let escolhido = achados
                .into_iter()
                .find(|a| a.announcement.capabilities.screen_source)
                .ok_or_else(|| {
                    Error::Discovery(
                        "nenhum emissor apareceu. Se a rede bloqueia mDNS, use --ip".into(),
                    )
                })?;
            imprimir_aparelho(&escolhido);
            escolhido
                .endpoint()
                .ok_or_else(|| Error::Discovery("o emissor não anunciou endereço".into()))?
        }
        (None, false) => return Err(Error::Invalid("diga --ip <endereço> ou --descobrir".into())),
    };

    let pin = match &op.pin {
        Some(p) => Some(p.clone()),
        None if segredos.is_empty() => {
            return Err(Error::Pairing(
                "primeiro pareamento precisa de --pin (o número que está na tela do emissor)"
                    .into(),
            ))
        }
        None => None,
    };

    println!("conectando em {destino}…");
    let pronto = conectar(
        destino,
        SessionConfig {
            announcement: eu,
            pin,
            known: segredos.clone(),
            transport: TransportConfig {
                delivery: op.entrega,
                bind_address: op.ligar_em.clone(),
                ..TransportConfig::default()
            },
            // Quem responde não declara tracks: as do outro lado chegam pela oferta.
            tracks: Vec::new(),
            timeout: Duration::from_secs(60),
            cancelamento: Cancelamento::novo(),
            silencio_do_caminho: None,
        },
    )?;

    relatar_conexao(&pronto);
    if pronto.outcome.novo {
        println!("  pareamento  : novo, por PIN");
    } else {
        println!("  pareamento  : retomado, sem PIN");
    }
    if let Some(arquivo) = &op.segredos {
        segredos.insert(&pronto.outcome);
        fs::write(arquivo, segredos.to_json()?)?;
        println!("  segredos    : gravados em {}", arquivo.display());
    }

    Ok(pronto)
}

fn relatar_conexao(pronto: &Ready) {
    println!();
    println!("conectado.");
    println!(
        "  par         : {} [{}]",
        pronto.peer.display_name, pronto.peer.device_id.0
    );
    // **Uma leitura só, e a mesma que a fronteira C entrega.** As linhas legíveis abaixo e o
    // JSON saem do mesmo `CaminhoDaMidia`, para que a sonda e a casca nunca contem histórias
    // diferentes sobre por onde a mídia foi — que é a única coisa que separa "medi a rede" de
    // "medi o cabo".
    let caminho = pronto.session.caminho();
    if let (Some(local), Some(remoto)) = (&caminho.local_candidate, &caminho.remote_candidate) {
        println!("  candidato   : {local}");
        println!("             -> {remoto}");
        // Sem STUN e sem TURN, os dois lados só têm candidato `host`. Se algum dia isto deixar
        // de valer, é sinal de que alguém acrescentou servidor ICE — e a promessa de LAN-only
        // caiu junto.
        if !local.contains("typ host") || !remoto.contains("typ host") {
            println!("  ATENÇÃO: o caminho escolhido não é `typ host`. Isso não deveria acontecer");
            println!("           num transporte sem STUN e sem TURN.");
        }
    }
    if let (Some(l), Some(r)) = (&caminho.local_address, &caminho.remote_address) {
        println!("  caminho     : {l} <-> {r}");
    }
    // O mesmo relato, byte a byte como `quall_session_path_json` o entrega. É o que a bancada
    // cola no registro, e é o que uma casca vê.
    match serde_json::to_string(&caminho) {
        Ok(json) => println!("  caminho (json): {json}"),
        Err(e) => println!("  caminho (json): não serializou: {e}"),
    }
}

/// Emissor: manda o padrão sintético e fecha a conta quando o eco volta.
fn medir(mut pronto: Ready, op: &Opcoes) -> Result<()> {
    // A sinalização fica aberta até o fim da medição, e não é fechada aqui.
    //
    // Fechar assim que a sessão sobe parecia limpo e quebrou o primeiro ensaio: o canal de
    // dados do emissor abre alguns milissegundos antes do canal do receptor, e o `Bye` chegava
    // lá enquanto ele ainda esperava o próprio `ChannelOpen`. O núcleo agora tolera isso, mas
    // não há motivo para provocar: um socket TCP parado não custa nada.
    let mut gerador = SyntheticPattern::new(op.carga);
    let mut stats = LatencyStats::new();
    let intervalo = Duration::from_secs_f64(1.0 / op.fps as f64);

    println!();
    println!(
        "medindo por {} s — {} quadro(s)/s de {} bytes, entrega {}…",
        op.segundos.as_secs(),
        op.fps,
        gerador.frame_len(),
        match op.entrega {
            Delivery::Realtime => "tempo-real (sem retransmissão, sem ordem)",
            Delivery::Reliable => "confiável e ordenada",
            Delivery::ReliableUnordered => "confiável e sem ordem",
        }
    );

    let fim = Instant::now() + op.segundos;
    let mut proximo = Instant::now();
    let mut enviados: u64 = 0;
    let mut buffer_maximo: usize = 0;

    while Instant::now() < fim {
        let agora = Instant::now();
        if agora >= proximo {
            let quadro = gerador.next_frame()?;
            // Buffer cheio no SCTP: é a rede dizendo que não acompanha. Seguir sem contar é
            // mais honesto do que travar o laço e mentir na medição.
            if pronto.session.send(quadro).is_ok() {
                enviados += 1;
            }
            buffer_maximo = buffer_maximo.max(pronto.session.buffered_amount());
            proximo += intervalo;
            // Se o processo ficou para trás (agendamento, GC de outro app), não tenta recuperar
            // mandando uma rajada — isso mediria a rajada, não a latência.
            if proximo < agora {
                proximo = agora + intervalo;
            }
        }

        while let Some(dados) = pronto.session.next_data(Duration::from_millis(1)) {
            let Ok(h) = FrameHeader::parse(&dados) else {
                continue;
            };
            if h.kind == FrameKind::Echo {
                let ida_e_volta = gerador.clock().micros().saturating_sub(h.sent_at_micros);
                stats.record_micros(ida_e_volta);
            }
            if Instant::now() >= fim {
                break;
            }
        }
    }

    // Depois de parar de enviar, ainda há ecos no ar. Sem esta janela, os últimos quadros
    // contariam como perdidos e a taxa sairia pior do que é.
    let arrasto = Instant::now() + Duration::from_millis(500);
    while Instant::now() < arrasto {
        if let Some(dados) = pronto.session.next_data(Duration::from_millis(50)) {
            if let Ok(h) = FrameHeader::parse(&dados) {
                if h.kind == FrameKind::Echo {
                    let ida_e_volta = gerador.clock().micros().saturating_sub(h.sent_at_micros);
                    stats.record_micros(ida_e_volta);
                }
            }
        }
    }

    println!();
    println!("resultado");
    println!("  quadros enviados : {enviados}");
    println!("  ecos recebidos   : {}", stats.count());
    if enviados > 0 {
        println!(
            "  ecos por envio   : {:.1}%",
            100.0 * stats.count() as f64 / enviados as f64
        );
    }
    println!("  descartes na fila: {}", pronto.session.dropped_frames());
    println!("  buffer máximo    : {buffer_maximo} bytes");
    println!("  ida e volta      : {}", stats.resumo());
    match (stats.percentile_ms(50.0), stats.mean_ms()) {
        (Some(p50), Some(media)) => {
            println!();
            println!("  latência de um sentido, estimada por metade da ida e volta:");
            println!(
                "    p50 ≈ {:.2} ms   média ≈ {:.2} ms",
                p50 / 2.0,
                media / 2.0
            );
            println!("  (hipótese de caminho simétrico; sem encode, sem decode, sem apresentação)");
        }
        _ => println!("  nenhum eco voltou — a medição não vale."),
    }

    pronto.link.close("medição concluída");
    // `drop` explícito antes do `cleanup`: ver a documentação de `transport::cleanup`. Sem ele o
    // processo fica pendurado depois de imprimir o relatório inteiro.
    drop(pronto);
    quall_core::transport::cleanup();
    Ok(())
}

/// Receptor: confere o padrão e devolve o cabeçalho.
fn ecoar(mut pronto: Ready, op: &Opcoes) -> Result<()> {
    println!();
    println!("recebendo por até {} s…", op.segundos.as_secs() + 5);

    let mut eco = [0u8; HEADER_LEN];
    let mut recebidos: u64 = 0;
    let mut corrompidos: u64 = 0;
    let mut fora_de_ordem: u64 = 0;
    let mut ultimo: Option<u32> = None;
    // Para o receptor, a folga é maior que a do emissor: ele não sabe quando o outro lado
    // começou a contar.
    let fim = Instant::now() + op.segundos + Duration::from_secs(5);
    let mut ocioso = Instant::now();

    while Instant::now() < fim {
        let Some(dados) = pronto.session.next_data(Duration::from_millis(100)) else {
            // Cinco segundos sem nada depois de já ter recebido algo: o emissor terminou.
            if recebidos > 0 && ocioso.elapsed() > Duration::from_secs(5) {
                break;
            }
            continue;
        };
        ocioso = Instant::now();

        let Ok(h) = FrameHeader::parse(&dados) else {
            corrompidos += 1;
            continue;
        };
        if h.kind != FrameKind::Pattern {
            continue;
        }
        recebidos += 1;

        let carga = &dados[HEADER_LEN..];
        if carga.len() != h.payload_len as usize || !conferir_padrao(carga, h.seq) {
            corrompidos += 1;
        }
        if let Some(anterior) = ultimo {
            if h.seq <= anterior {
                fora_de_ordem += 1;
            }
        }
        ultimo = Some(h.seq);

        montar_eco(&h, &mut eco)?;
        // Falha ao ecoar não derruba o receptor: o canal pode ter fechado do outro lado, e o
        // que importa é o relatório sair.
        let _ = pronto.session.send(&eco);
    }

    println!();
    println!("resultado");
    println!("  quadros recebidos : {recebidos}");
    println!("  corrompidos       : {corrompidos}");
    // O `--entrega` do receptor não vale nada: quem cria o canal é o emissor, e a
    // confiabilidade negociada vem de lá. Então a nota sai do que foi observado, não do que
    // este lado pediu — a primeira versão imprimia "esperado: entrega não ordenada" numa
    // sessão confiável, e uma nota errada é pior que nota nenhuma.
    println!(
        "  fora de ordem     : {fora_de_ordem}{}",
        if fora_de_ordem > 0 {
            "  (normal em entrega não ordenada)"
        } else {
            ""
        }
    );
    println!("  descartes na fila : {}", pronto.session.dropped_frames());
    if let Some(ultimo) = ultimo {
        let esperados = u64::from(ultimo) + 1;
        let perdidos = esperados.saturating_sub(recebidos);
        println!("  maior sequência   : {ultimo}");
        println!(
            "  perdidos          : {perdidos} de {esperados} ({:.2}%)",
            100.0 * perdidos as f64 / esperados as f64
        );
    }

    pronto.link.close("recepção concluída");
    drop(pronto);
    quall_core::transport::cleanup();
    Ok(())
}

fn carregar_segredos(op: &Opcoes) -> Result<PairedPeers> {
    match &op.segredos {
        Some(arquivo) if arquivo.exists() => {
            let texto = fs::read_to_string(arquivo)?;
            PairedPeers::from_json(&texto)
        }
        _ => Ok(PairedPeers::new()),
    }
}

/// Endereços IPv4 das interfaces, só para imprimir na tela do emissor.
///
/// Feito com um truque de socket UDP em vez de enumerar interfaces: um `connect` UDP não manda
/// pacote nenhum, mas faz o sistema escolher a interface de saída e revelar o IP local. É o
/// suficiente para o usuário saber o que digitar no outro aparelho, e evita mais uma dependência
/// no núcleo.
fn ips_locais() -> Vec<String> {
    use std::net::UdpSocket;
    let mut saida = Vec::new();
    if let Ok(s) = UdpSocket::bind("0.0.0.0:0") {
        // O destino não precisa existir nem responder.
        if s.connect("192.168.1.1:9").is_ok() {
            if let Ok(addr) = s.local_addr() {
                saida.push(addr.ip().to_string());
            }
        }
    }
    saida
}

/// Analisador de argumentos feito à mão.
///
/// Sem `clap` de propósito: a sonda é empurrada por `adb push` para um aparelho de 1,79 GB e
/// linkada com libdatachannel — cada dependência a mais também é tamanho de binário, e tamanho
/// de binário é justamente um dos dois números que o M1 tem de produzir.
struct Opcoes {
    id: String,
    nome: String,
    segundos: Duration,
    /// Profundidade do jitter buffer, em pacotes. Cada um custa 20 ms de latência.
    profundidade: u16,
    /// Perda **simulada** no receptor, em porcento. A bancada não tem root para induzir perda no
    /// enlace, então a varredura é feita descartando pacote depois de ele chegar — e todo número
    /// que sair daqui precisa dizer que a perda foi simulada.
    descartar_pct: u8,
    pin: Option<Pin>,
    segredos: Option<PathBuf>,
    porta: u16,
    fps: u32,
    carga: usize,
    sem_mdns: bool,
    /// Liga o registro interno da libdatachannel/libjuice no stderr da sonda.
    ///
    /// É a **única** testemunha de um datagrama que o socket de saída recusou
    /// (`Send failed, buffer is full`, `libjuice/src/conn_poll.c:417`). Sem ela o descarte não
    /// aparece em lugar nenhum: `Track::outgoing` sobrescreve o retorno a cada fragmento
    /// (`impl/track.cpp:187-199`, a dívida 30) e `enviar_quadro` devolve `Ok(())`.
    registro_da_biblioteca: bool,
    ip: Option<String>,
    descobrir: bool,
    /// `--tela LxA`: a tela que este receptor diz ter no aperto de mão — emula um aparelho para a
    /// tela estendida do Mac escolher o formato do monitor (`docs/tela-estendida.md`).
    tela: Option<Screen>,
    /// `--ligar-em ENDERECO`: prende os candidatos ICE a uma interface só.
    ///
    /// É o que torna o degrau do cabo mensurável: sem ele não há como pedir à libjuice que
    /// abandone a Wi-Fi. **E o preço é o mesmo do campo do núcleo — ligar desiste das outras
    /// interfaces**, então um endereço errado não degrada para a rede: a sessão não fecha. Ver
    /// `TransportConfig::bind_address`.
    ligar_em: Option<String>,
    entrega: Delivery,
    /// Sidecar `.json` a enviar em `emitir-video`.
    entrada: Option<PathBuf>,
    /// Arquivo `.h264` a gravar em `receber-video`.
    saida: Option<PathBuf>,
    /// `--encaminhar SOQUETE`: repassa cada quadro recebido no formato de `tools/vidro-a-vidro`.
    ///
    /// É o fio que faltava para a campanha filmada de `docs/medir-vidro-a-vidro.md`: o arnês já
    /// sabe decodificar Annex-B e ler a faixa de Gray nos pixels, e não tinha como receber da
    /// track. Ver `video::cabecalho_do_fio`.
    encaminhar: Option<PathBuf>,
    /// Repete o arquivo em laço, para medir por mais tempo que a captura dura.
    repetir: bool,
    /// `--com-audio`: põe uma segunda track, de som sintético, na oferta de `emitir-video`.
    com_audio: bool,
    /// `--som-primeiro`: a track de som é a **primeira** da oferta, e o vídeo a segunda. Exercita
    /// o receptor que recebe o som antes do vídeo (`docs/som-no-receptor.md` §7.0, crítica 2 M1).
    som_primeiro: bool,
    /// `--ppm-no-audio N`: o relógio de mídia do som do emissor anda N ppm mais depressa que o do
    /// vídeo (`docs/som-no-receptor.md` §9.3, controle 6; crítica 2 M6d).
    ppm_no_audio: f64,
    /// `--claquete SEMENTE`: estouros de 3 150 Hz no som e o quadro marcado no vídeo
    /// (`claquete.rs`, §9.2). `--claquete-saida ARQ.json` grava a verdade dos eventos.
    claquete: Option<u64>,
    claquete_saida: Option<PathBuf>,
    /// `--atraso-no-audio MS` e `--deslocar-audio MS`: os controles 2 e 6 do §9.3.
    atraso_no_audio_ms: u64,
    deslocar_audio_ms: i64,
    /// `--perder-no-audio N`, `--travar-audio-ms MS` com `--travar-em S`, e `--origem-na-volta S`:
    /// os controles 3, 4 e 5 do §9.3 (a S7). Ver `video::ControlesDoSom`.
    perder_no_audio: u64,
    travar_audio_ms: u64,
    travar_em_s: u64,
    origem_na_volta_ms: Option<u64>,
    /// `receber-video --trocar-no-som N`: o receptor troca a ordem de 1 par de pacotes de som a cada
    /// N, na chegada, antes do núcleo ver (`TrackReceptor::cravar_troca_de_bancada`). É a
    /// reordenação do controle 5, que `lo0` não tem.
    trocar_no_som: u32,
    /// Depois de quanto tempo o receptor pede um IDR, para medir a recuperação.
    pedir_idr_em: Option<Duration>,
    /// Liga a política de **pedir IDR na perda**, a do receptor de produto.
    ///
    /// `None` (o padrão) é o comportamento histórico da sonda: um pedido na entrada e mais
    /// nenhum. Com ela desligada, um emissor cuja quinta porta só age quando alguém pede
    /// quadro-chave **nunca recria o encoder** — e o braço "porta ligada" de um A/B vira o braço
    /// "porta desligada" com outro nome. Ver [`video::PoliticaDePerda`].
    politica_de_perda: Option<video::PoliticaDePerda>,
    /// Período do relatório parcial de recepção. `None` (o padrão) não imprime nenhum.
    relatar_a_cada: Option<Duration>,
    /// `receber-video --relogio`: aceita também a track de som (sem tocar) e imprime o relógio
    /// comum das duas a cada segundo — a guarda de ritmo vista de fora (§19 do
    /// `som-no-receptor.md`).
    relogio: bool,
    track: TrackKind,
    /// Codec da track de áudio.
    ///
    /// O padrão é **Opus**, que é o codec do produto e que passou a existir de verdade quando a
    /// libopus foi vendorizada (`crates/quall-opus`). `pcmu` continua disponível como piso — é o
    /// único codec que não depende de biblioteca nenhuma, e é o que prova o caminho de RTP quando
    /// se quer tirar o codec da equação.
    codec: CodecDeAudio,
    /// O papel no anúncio: só `teleprompter` e `controle` o ligam.
    papel: Option<Papel>,
    /// `--fonte PT`, só no `controle`: depois das edições, muda a fonte do teleprompter — é o que
    /// desliga a "Fonte automática" num prompter (`docs/teleprompter-ajustes-locais.md` §5).
    fonte: Option<f64>,
    /// `--texto BYTES`: o roteiro sintético com que a réplica do teleprompter **começa**, antes
    /// de qualquer sessão (`docs/contrato-teleprompter.md` §11.8). `0` é "sem roteiro".
    texto: usize,
    /// `--porta` veio na linha de comando. Sem ela, o prompter escolhe a porta do teleprompter.
    porta_explicita: bool,
    /// `controle --escolha prompter|meu|nenhuma`: o que responder à pergunta do texto (§11.4).
    escolha: Option<String>,
    /// `controle --salvo ARQUIVO`: carrega e grava a réplica — para provar "o prompter da última
    /// vez" entre duas corridas.
    salvo: Option<PathBuf>,
    /// `controle --segurar MS`: aperta o "segurar para rolar", segura MS ms e solta (§12).
    segurar_ms: Option<u64>,
    /// `controle --para-tras`: com `--segurar`, para trás (a partir do meio do percurso).
    para_tras: bool,
    /// `controle --sair-segurando`: com `--segurar`, sai do processo com o dedo no botão — a queda.
    sair_segurando: bool,
    /// `controle --vezes N`: com `--segurar`, aperta e solta N vezes e resume a confirmação do soltar
    /// (§12.3, o reenvio rápido).
    vezes: u32,
    /// `controle --gravar`: pede ao prompter que grave (§13).
    gravar: bool,
    /// `controle --parar`: pede ao prompter que pare (§13). Com `--gravar`, depois de `gravar_por`.
    parar: bool,
    /// `controle --gravar-por MS`: com `--gravar --parar`, quanto esperar gravando.
    gravar_por: Duration,
    /// `controle --sair-gravando`: com `--gravar`, sai do processo gravando — a queda.
    sair_gravando: bool,
    /// `teleprompter --recusar-gravacao MOTIVO`: recusa os pedidos de gravação com este motivo.
    recusar_gravacao: Option<String>,
}

/// O maior `--ppm-no-audio` aceito, em módulo: 1 %.
const PPM_NO_AUDIO_MAXIMO: f64 = 10_000.0;

/// Lê o número de uma opção de controle, ou **sai** com 2: `--atraso-no-audio -30` e
/// `--ppm-no-audio 200ppm` viravam 0 calados (crítica 10, m3), e `--claquete 0x2a` virava "sem
/// claquete" (M6).
fn numero_da_opcao<T: std::str::FromStr>(opcao: &str, valor: Option<&String>) -> T {
    match valor.map(|v| (v, v.parse::<T>())) {
        Some((_, Ok(n))) => n,
        Some((v, Err(_))) => {
            eprintln!("{opcao}: não consegui ler '{v}' como número; nada foi emitido");
            std::process::exit(2);
        }
        None => {
            eprintln!("{opcao}: falta o valor; nada foi emitido");
            std::process::exit(2);
        }
    }
}

impl Opcoes {
    fn parse(args: &[String]) -> Self {
        let mut op = Opcoes {
            id: String::new(),
            nome: String::new(),
            segundos: Duration::from_secs(10),
            profundidade: 2,
            descartar_pct: 0,
            pin: None,
            segredos: None,
            porta: DEFAULT_SIGNALING_PORT,
            fps: 60,
            carga: 1200,
            sem_mdns: false,
            registro_da_biblioteca: false,
            ip: None,
            tela: None,
            descobrir: false,
            ligar_em: None,
            entrega: Delivery::Realtime,
            entrada: None,
            saida: None,
            encaminhar: None,
            repetir: false,
            pedir_idr_em: None,
            politica_de_perda: None,
            relatar_a_cada: None,
            relogio: false,
            track: TrackKind::Screen,
            codec: CodecDeAudio::Opus,
            com_audio: false,
            som_primeiro: false,
            ppm_no_audio: 0.0,
            claquete: None,
            claquete_saida: None,
            atraso_no_audio_ms: 0,
            deslocar_audio_ms: 0,
            perder_no_audio: 0,
            travar_audio_ms: 0,
            travar_em_s: 12,
            origem_na_volta_ms: None,
            trocar_no_som: 0,
            papel: None,
            fonte: None,
            texto: 0,
            porta_explicita: false,
            escolha: None,
            salvo: None,
            segurar_ms: None,
            para_tras: false,
            sair_segurando: false,
            vezes: 1,
            gravar: false,
            parar: false,
            gravar_por: Duration::from_millis(3_000),
            sair_gravando: false,
            recusar_gravacao: None,
        };

        let mut i = 0;
        while i < args.len() {
            let valor = |i: usize| args.get(i + 1).cloned().unwrap_or_default();
            match args[i].as_str() {
                "--id" => {
                    op.id = valor(i);
                    i += 1;
                }
                "--nome" => {
                    op.nome = valor(i);
                    i += 1;
                }
                "--segundos" => {
                    op.segundos = Duration::from_secs(valor(i).parse().unwrap_or(10));
                    i += 1;
                }
                "--pin" => {
                    op.pin = Pin::parse(&valor(i)).ok();
                    i += 1;
                }
                "--segredos" => {
                    op.segredos = Some(PathBuf::from(valor(i)));
                    i += 1;
                }
                "--porta" => {
                    op.porta = valor(i).parse().unwrap_or(DEFAULT_SIGNALING_PORT);
                    op.porta_explicita = true;
                    i += 1;
                }
                "--escolha" => {
                    op.escolha = Some(valor(i));
                    i += 1;
                }
                "--salvo" => {
                    op.salvo = Some(PathBuf::from(valor(i)));
                    i += 1;
                }
                "--segurar" => {
                    op.segurar_ms = valor(i).parse().ok();
                    i += 1;
                }
                "--para-tras" | "--para-trás" => op.para_tras = true,
                "--sair-segurando" => op.sair_segurando = true,
                "--gravar" => op.gravar = true,
                "--parar" => op.parar = true,
                "--sair-gravando" => op.sair_gravando = true,
                "--gravar-por" => {
                    let Ok(ms) = valor(i).parse() else {
                        eprintln!("--gravar-por: esperava milissegundos, veio {:?}", valor(i));
                        std::process::exit(2);
                    };
                    op.gravar_por = Duration::from_millis(ms);
                    i += 1;
                }
                "--recusar-gravacao" => {
                    let motivo = valor(i);
                    if motivo.is_empty() || motivo.len() > quall_core::teleprompter::TETO_DO_MOTIVO {
                        eprintln!(
                            "--recusar-gravacao: o motivo tem de 1 a {} bytes",
                            quall_core::teleprompter::TETO_DO_MOTIVO
                        );
                        std::process::exit(2);
                    }
                    op.recusar_gravacao = Some(motivo);
                    i += 1;
                }
                "--vezes" => {
                    op.vezes = valor(i).parse().unwrap_or(1).max(1);
                    i += 1;
                }
                "--fps" => {
                    op.fps = valor(i).parse().unwrap_or(60).max(1);
                    i += 1;
                }
                "--carga" => {
                    op.carga = valor(i).parse().unwrap_or(1200);
                    i += 1;
                }
                "--fonte" => {
                    op.fonte = valor(i).parse().ok();
                    i += 1;
                }
                "--texto" => {
                    op.texto = valor(i).parse().unwrap_or(0);
                    i += 1;
                }
                "--ip" => {
                    op.ip = Some(valor(i));
                    i += 1;
                }
                "--tela" => {
                    let v = valor(i);
                    let lados: Vec<u32> = v.split(['x', 'X']).filter_map(|n| n.parse().ok()).collect();
                    op.tela = match lados.as_slice() {
                        [l, a] => Screen::nova(*l, *a),
                        _ => None,
                    };
                    if op.tela.is_none() {
                        eprintln!("--tela {v}: use LxA em pixels, de 1 a {}", Screen::LADO_MAXIMO);
                        std::process::exit(2);
                    }
                    i += 1;
                }
                "--ligar-em" => {
                    op.ligar_em = Some(valor(i));
                    i += 1;
                }
                "--entrega" => {
                    op.entrega = match valor(i).as_str() {
                        "confiavel" | "confiável" => Delivery::Reliable,
                        _ => Delivery::Realtime,
                    };
                    i += 1;
                }
                // O valor é pulado aqui, e o laço pula a opção no fim. Até a S7, `--encaminhar`
                // pulava dois e `--relogio` (sem valor) pulava um: a opção seguinte sumia em
                // silêncio (`--relogio --trocar-no-som 2` virava "opção ignorada: 2").
                "--encaminhar" => {
                    op.encaminhar = Some(PathBuf::from(valor(i)));
                    i += 1;
                }
                "--relogio" => {
                    op.relogio = true;
                }
                "--entrada" => {
                    op.entrada = Some(PathBuf::from(valor(i)));
                    i += 1;
                }
                "--saida" | "--saída" => {
                    op.saida = Some(PathBuf::from(valor(i)));
                    i += 1;
                }
                "--pedir-idr-em" => {
                    op.pedir_idr_em = valor(i).parse().ok().map(Duration::from_secs);
                    i += 1;
                }
                // Sem argumento: liga com os números do produto (100 ms de piso curto, 500 ms de
                // piso longo). Os dois pisos têm sinalizador próprio logo abaixo, para a bancada
                // poder varrer a política sem recompilar.
                "--politica-de-perda" => {
                    op.politica_de_perda = Some(video::PoliticaDePerda::default());
                }
                "--relatar-a-cada" => {
                    op.relatar_a_cada = valor(i).parse().ok().map(Duration::from_secs);
                    i += 1;
                }
                "--piso-primeiro-ms" => {
                    let mut p = op.politica_de_perda.unwrap_or_default();
                    if let Ok(ms) = valor(i).parse::<u64>() {
                        p.piso_primeiro = Duration::from_millis(ms);
                    }
                    op.politica_de_perda = Some(p);
                    i += 1;
                }
                "--piso-repeticao-ms" => {
                    let mut p = op.politica_de_perda.unwrap_or_default();
                    if let Ok(ms) = valor(i).parse::<u64>() {
                        p.piso_repeticao = Duration::from_millis(ms);
                    }
                    op.politica_de_perda = Some(p);
                    i += 1;
                }
                "--track" => {
                    op.track = match valor(i).as_str() {
                        "camera" | "câmera" => TrackKind::Camera,
                        "microfone" | "microphone" | "mic" => TrackKind::Microphone,
                        "sistema" | "system-audio" | "system" => TrackKind::SystemAudio,
                        _ => TrackKind::Screen,
                    };
                    i += 1;
                }
                "--codec" => {
                    op.codec = match valor(i).as_str() {
                        "opus" => CodecDeAudio::Opus,
                        _ => CodecDeAudio::Pcmu,
                    };
                    i += 1;
                }
                "--profundidade" => {
                    i += 1;
                    op.profundidade = args.get(i).and_then(|v| v.parse().ok()).unwrap_or(2);
                }
                "--descartar-pct" => {
                    i += 1;
                    op.descartar_pct = args.get(i).and_then(|v| v.parse().ok()).unwrap_or(0);
                }
                "--com-audio" | "--com-áudio" => op.com_audio = true,
                "--som-primeiro" => op.som_primeiro = true,
                // Os controles de bancada **não** caem no padrão em silêncio: um erro de leitura
                // transformava uma corrida de controle numa corrida de base, sem linha nenhuma que
                // dissesse (crítica 10, M6 e m3). Erro de leitura é fatal.
                "--claquete" => {
                    i += 1;
                    op.claquete = Some(numero_da_opcao("--claquete", args.get(i)));
                }
                "--atraso-no-audio" => {
                    i += 1;
                    op.atraso_no_audio_ms = numero_da_opcao("--atraso-no-audio", args.get(i));
                }
                "--deslocar-audio" => {
                    i += 1;
                    op.deslocar_audio_ms = numero_da_opcao("--deslocar-audio", args.get(i));
                }
                "--claquete-saida" => {
                    i += 1;
                    op.claquete_saida = args.get(i).map(PathBuf::from);
                }
                "--perder-no-audio" => {
                    i += 1;
                    op.perder_no_audio = numero_da_opcao("--perder-no-audio", args.get(i));
                    if op.perder_no_audio == 1 {
                        eprintln!("--perder-no-audio 1 perderia todo o som depois de 5 s; use N ≥ 2. Nada foi emitido");
                        std::process::exit(2);
                    }
                }
                "--travar-audio-ms" => {
                    i += 1;
                    op.travar_audio_ms = numero_da_opcao("--travar-audio-ms", args.get(i));
                }
                "--travar-em" => {
                    i += 1;
                    op.travar_em_s = numero_da_opcao("--travar-em", args.get(i));
                }
                "--origem-na-volta" => {
                    i += 1;
                    let s: f64 = numero_da_opcao("--origem-na-volta", args.get(i));
                    if !s.is_finite() || !(0.0..=3600.0).contains(&s) {
                        eprintln!("--origem-na-volta: segundos entre 0 e 3600, e não {s}; nada foi emitido");
                        std::process::exit(2);
                    }
                    op.origem_na_volta_ms = Some((s * 1000.0).round() as u64);
                }
                "--trocar-no-som" => {
                    i += 1;
                    op.trocar_no_som = numero_da_opcao("--trocar-no-som", args.get(i));
                    if op.trocar_no_som == 1 {
                        eprintln!("--trocar-no-som N pede N ≥ 2 (um par a cada N pacotes); nada foi recebido");
                        std::process::exit(2);
                    }
                }
                "--ppm-no-audio" => {
                    i += 1;
                    op.ppm_no_audio = numero_da_opcao("--ppm-no-audio", args.get(i));
                    // NaN, infinito ou ≥ 10⁶ ppm fariam o fator do relógio do som NaN ou negativo,
                    // e o laço de envio mandaria pacotes sem parar (reconferência, F6). 1 % já é
                    // vinte vezes o alcance do Varispeed.
                    if !op.ppm_no_audio.is_finite() || op.ppm_no_audio.abs() > PPM_NO_AUDIO_MAXIMO {
                        eprintln!(
                            "--ppm-no-audio: um número finito entre -{PPM_NO_AUDIO_MAXIMO} e {PPM_NO_AUDIO_MAXIMO}, e não {}; nada foi emitido",
                            op.ppm_no_audio
                        );
                        std::process::exit(2);
                    }
                }
                "--repetir" => op.repetir = true,
                "--sem-mdns" => op.sem_mdns = true,
                "--registro-da-biblioteca" => op.registro_da_biblioteca = true,
                "--descobrir" => op.descobrir = true,
                outro => eprintln!("aviso: opção ignorada: {outro}"),
            }
            i += 1;
        }

        if op.id.is_empty() {
            // Sorteado para que duas sondas na mesma LAN não colidam no nome da instância mDNS.
            // Passe `--id` para que o pareamento sobreviva entre execuções.
            let mut b = [0u8; 3];
            let _ = getrandom_bytes(&mut b);
            op.id = format!("probe-{:02x}{:02x}{:02x}", b[0], b[1], b[2]);
        }
        if op.nome.is_empty() {
            op.nome = format!("sonda {}", op.id);
        }
        op
    }

    fn anuncio(&self, emissor: bool) -> Announcement {
        Announcement {
            protocol_version: PROTOCOL_VERSION,
            device_id: DeviceId(self.id.clone()),
            display_name: self.nome.clone(),
            capabilities: Capabilities {
                screen_source: emissor,
                camera_source: false,
                sink: !emissor,
            },
            // `--tela LxA` emula a tela de um aparelho, só do lado que exibe.
            screen: if emissor { None } else { self.tela },
            papel: self.papel,
        }
    }
}

/// Aleatoriedade sem arrastar `getrandom` para o `Cargo.toml` da sonda: um `DeviceId` de
/// conveniência não precisa de qualidade criptográfica, e o que precisa (PIN, chaves) já é feito
/// no núcleo com o gerador do sistema.
fn getrandom_bytes(destino: &mut [u8]) -> std::io::Result<()> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let semente = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() ^ d.as_secs() as u32)
        .unwrap_or(0x5EED_1234);
    let mut estado = semente | 1;
    for b in destino.iter_mut() {
        estado ^= estado << 13;
        estado ^= estado >> 17;
        estado ^= estado << 5;
        *b = (estado & 0xff) as u8;
    }
    Ok(())
}

#[cfg(test)]
mod testes_das_opcoes {
    use super::*;

    fn opcoes(a: &[&str]) -> Opcoes {
        Opcoes::parse(&a.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    /// `--relogio` não tem valor, e não pode comer a opção seguinte (a S7 perdeu uma corrida
    /// inteira assim: a troca do controle 5 nunca ligou).
    #[test]
    fn relogio_nao_come_a_opcao_seguinte() {
        let o = opcoes(&["--relogio", "--trocar-no-som", "2", "--segundos", "7"]);
        assert!(o.relogio);
        assert_eq!(o.trocar_no_som, 2);
        assert_eq!(o.segundos, Duration::from_secs(7));
        let o = opcoes(&["--trocar-no-som", "4", "--relogio"]);
        assert!(o.relogio);
        assert_eq!(o.trocar_no_som, 4);
    }

    #[test]
    fn encaminhar_pula_so_o_proprio_valor() {
        let o = opcoes(&["--encaminhar", "/tmp/qv.sock", "--relogio", "--segundos", "3"]);
        assert_eq!(o.encaminhar.as_deref(), Some(std::path::Path::new("/tmp/qv.sock")));
        assert!(o.relogio);
        assert_eq!(o.segundos, Duration::from_secs(3));
    }

    #[test]
    fn os_controles_da_s7_sao_lidos() {
        let o = opcoes(&[
            "--perder-no-audio", "10", "--travar-audio-ms", "150", "--travar-em", "9",
            "--origem-na-volta", "15.02",
        ]);
        assert_eq!(o.perder_no_audio, 10);
        assert_eq!((o.travar_audio_ms, o.travar_em_s), (150, 9));
        assert_eq!(o.origem_na_volta_ms, Some(15_020));
    }
}
