//! Modos de vídeo da sonda: mandar um `.h264` por track e escrever o que chegar do outro lado.
//!
//! Existe para que a track possa ser exercitada **sem captura e sem decode**. Um `.h264` gravado
//! por `quall-capture` entra de um lado e sai do outro; `ffprobe` diz se o que saiu é vídeo de
//! verdade. Não é simulação — o caminho é o mesmo do produto: pacotizador da libdatachannel,
//! SRTP, rede, depacotizador da RFC 6184.
//!
//! Isso também destrava as outras frentes: um receptor de macOS ou Windows pode ser testado hoje
//! contra um `.h264` do repositório, sem esperar o Android ficar pronto.
//!
//! # A entrada é o par do contrato do sidecar
//!
//! `docs/contrato-sidecar.md`: um `.h264` Annex-B e um `.json` que diz, quadro a quadro, quantos
//! bytes ele tem, qual o carimbo e se é IDR. É o `.json` que permite fatiar o arquivo em quadros
//! **sem interpretar H.264** — a sonda nunca procura start code, ela lê `bytes` e avança.
//!
//! # Memória
//!
//! O `.h264` **não** é carregado inteiro. A sonda lê quadro a quadro num buffer único,
//! dimensionado pelo maior `bytes` do sidecar e reaproveitado. Uma captura de 20 s a 6 Mbps tem
//! ~15 MB, e carregar isso num Galaxy A10s de 1,79 GB funcionaria — mas seria exatamente o
//! hábito que o contrato de mídia proíbe, e a sonda existe para provar o hábito certo.

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use quall_core::error::{Error, Result};
use quall_core::relogio::{DeslocamentoDeCaptura, RetratoDoRelogio};
use quall_core::rtp;
use quall_core::session::Ready;
use quall_core::track::{AmostraDeAudio, QuadroCodificado, TrackKind, DURACAO_DO_QUADRO_MS};

/// Os controles do §9.3 (`docs/som-no-receptor.md`) que moram no emissor de som.
#[derive(Debug, Clone, Copy, Default)]
pub struct ControlesDoSom {
    /// `--atraso-no-audio MS` (controle 2): cada pacote de som sai MS mais tarde, com o carimbo
    /// intacto. A previsão por testemunha está no §9.3: o Mac, que sincroniza pela chegada, move o
    /// Δ nesse tanto.
    pub atraso_us: u64,
    /// `--deslocar-audio MS` (controle 6): o carimbo do som anda deslocado de MS em relação ao do
    /// vídeo. O relógio comum tem de recusar o par acima de 150 ms.
    pub deslocar_us: i64,
    /// `--perder-no-audio N` (controle 3): perde 1 de cada N quadros de som, a partir de
    /// [`PERDA_A_PARTIR_DO_QUADRO`]. **Como**: o quadro sai numerado, mas com uma carga maior que
    /// `reproducao::TAMANHO_MAXIMO_DO_PACOTE`, e a porta puxada do receptor o joga fora na entrada
    /// (`oversized`). O número de sequência é consumido — pular o envio não serviria: o pacotizador
    /// da libdatachannel numera no envio, a sequência ficaria contígua e o receptor, que põe o som
    /// pela sequência, tocaria o quadro seguinte no lugar do perdido (um degrau de 20 ms, e não uma
    /// perda). Para a reprodução é um buraco de sequência, como a perda na rede; o depacotizador e
    /// o relógio comum o veem chegar, e é isso que esta perda não exercita. `0` desliga.
    pub perder_a_cada: u64,
    /// `--travar-audio-ms MS` (controle 4): os quadros de som que sairiam em
    /// `[inicio_us, fim_us)` esperam até `fim_us` e saem juntos, numa rajada, com o carimbo
    /// intacto. É o emissor (ou a rede) travado por MS; o vídeo segue. `None` desliga.
    pub travar: Option<(u64, u64)>,
    /// `--origem-na-volta S` (controle 5): somado ao carimbo das **duas** tracks no fio, para o
    /// relógio RTP do som dar a volta de 32 bits S segundos depois do começo. Ver
    /// [`origem_perto_da_volta_us`]. Zero é a origem de sempre.
    pub origem_us: u64,
}

/// A perda do controle 3 só começa depois de 5 s de som: a primeira ancoragem da porta puxada e a
/// primeira janela do relógio comum ficam fora dela.
pub const PERDA_A_PARTIR_DO_QUADRO: u64 = 250;

/// A carga do quadro perdido de propósito: um byte acima do maior pacote que a porta puxada aceita
/// (`quall_core::reproducao::TAMANHO_MAXIMO_DO_PACOTE`).
pub const CARGA_DA_PERDA: usize = quall_core::reproducao::TAMANHO_MAXIMO_DO_PACOTE + 1;

impl ControlesDoSom {
    /// Quando o quadro de som `k` sai, em µs desde o começo da emissão: o tempo de mídia dele
    /// (`k × intervalo`, encolhido por `fator` com `--ppm-no-audio`), mais o atraso do controle 2,
    /// e segurado até o fim da travada do controle 4 quando cai dentro dela.
    pub fn envio_us(&self, k: u64, intervalo_us: u64, fator: f64) -> u64 {
        let envio = ((k * intervalo_us) as f64 * fator) as u64 + self.atraso_us;
        match self.travar {
            Some((inicio, fim)) if envio >= inicio && envio < fim => fim,
            _ => envio,
        }
    }

    /// O quadro de som `k` é um dos que a travada do controle 4 segurou?
    pub fn travado(&self, k: u64, intervalo_us: u64, fator: f64) -> bool {
        let envio = ((k * intervalo_us) as f64 * fator) as u64 + self.atraso_us;
        self.travar
            .is_some_and(|(inicio, fim)| envio >= inicio && envio < fim)
    }

    /// O quadro de som `k` é um dos perdidos do controle 3?
    pub fn perde(&self, k: u64) -> bool {
        self.perder_a_cada > 0 && k >= PERDA_A_PARTIR_DO_QUADRO && k % self.perder_a_cada == 0
    }
}

/// A origem que põe a volta de 32 bits do relógio RTP de `hz` a `depois_us` do começo da emissão.
///
/// O núcleo escreve o carimbo como `floor(µs × hz / 10⁶) mod 2³²` (`rtp::micros_para_carimbo_em`),
/// e a volta acontece no primeiro µs em que `µs × hz ≥ 2³² × 10⁶`. A 48 kHz são 89 478,485 s; a
/// 8 kHz (PCMU), 536 870,912 s. `None` quando `depois_us` passa da própria volta.
pub fn origem_perto_da_volta_us(hz: u32, depois_us: u64) -> Option<u64> {
    let volta_us = ((1u128 << 32) * 1_000_000).div_ceil(u128::from(hz.max(1)));
    u64::try_from(volta_us).ok()?.checked_sub(depois_us)
}

/// Maior fatia de espera entre dois quadros. Curta o bastante para que um pedido de IDR seja
/// atendido em milissegundos, longa o bastante para não virar espera ocupada no A10s.
const FATIA_DE_ESPERA: Duration = Duration::from_millis(2);

// ---------------------------------------------------------------------------------------------
// Sidecar
// ---------------------------------------------------------------------------------------------

/// O `.json` do contrato do sidecar, na parte que a sonda usa.
///
/// Os campos que não interessam ao envio (`encoder`, `capture_api`, `encode_latency_us`…) não
/// estão aqui de propósito: `serde` ignora o que não é declarado, e assim a sonda não quebra se
/// uma frente de captura acrescentar um campo.
#[derive(Debug, serde::Deserialize)]
pub struct Sidecar {
    pub header: Cabecalho,
    pub frames: Vec<Quadro>,
}

#[derive(Debug, serde::Deserialize)]
pub struct Cabecalho {
    pub width: u32,
    pub height: u32,
    pub target_fps: u32,
    pub preset: String,
    pub color_range: String,
    pub video_file: String,
}

#[derive(Debug, Clone, Copy, serde::Deserialize)]
pub struct Quadro {
    pub number: u64,
    pub timestamp_us: u64,
    pub bytes: u64,
    pub idr: bool,
}

impl Sidecar {
    /// Lê e **confere** o sidecar contra o `.h264` que ele diz descrever.
    ///
    /// As conferências não são zelo: são exatamente o que o contrato do sidecar manda checar, e
    /// cada uma já pegou defeito de verdade numa das frentes de captura. Um sidecar que não bate
    /// com o arquivo faz a sonda mandar lixo pela rede e o defeito aparece três camadas adiante.
    pub fn carregar(caminho: &Path) -> Result<(Self, PathBuf)> {
        let texto = std::fs::read_to_string(caminho)?;
        let sidecar: Sidecar = serde_json::from_str(&texto)
            .map_err(|e| Error::Invalid(format!("sidecar {}: {e}", caminho.display())))?;

        if sidecar.frames.is_empty() {
            return Err(Error::Invalid("sidecar sem quadro nenhum".into()));
        }
        if !sidecar.frames[0].idr {
            return Err(Error::Invalid(
                "o primeiro quadro do sidecar não é IDR; o contrato exige que seja".into(),
            ));
        }

        let mut anterior: Option<Quadro> = None;
        let mut soma = 0u64;
        for q in &sidecar.frames {
            if let Some(a) = anterior {
                if q.number <= a.number {
                    return Err(Error::Invalid(format!(
                        "sidecar com `number` fora de ordem: {} depois de {}",
                        q.number, a.number
                    )));
                }
                if q.timestamp_us <= a.timestamp_us {
                    return Err(Error::Invalid(format!(
                        "sidecar com `timestamp_us` não crescente no quadro {}: {} depois de {}",
                        q.number, q.timestamp_us, a.timestamp_us
                    )));
                }
            }
            soma += q.bytes;
            anterior = Some(*q);
        }

        // O `.h264` é procurado ao lado do `.json`, e não pelo caminho absoluto do
        // `video_file` — assim o par continua funcionando depois de ser copiado para outro
        // aparelho, que é justamente o que a sonda faz com `adb push`.
        let video = caminho
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join(&sidecar.header.video_file);
        let tamanho = std::fs::metadata(&video)
            .map_err(|e| Error::Io(format!("{}: {e}", video.display())))?
            .len();
        if tamanho != soma {
            return Err(Error::Invalid(format!(
                "a soma de `bytes` do sidecar é {soma} e o {} tem {tamanho}. \
                 O sidecar descreve outro arquivo.",
                video.display()
            )));
        }

        Ok((sidecar, video))
    }

    /// Duração da captura, do primeiro ao último quadro.
    pub fn duracao(&self) -> Duration {
        let primeiro = self.frames[0].timestamp_us;
        let ultimo = self.frames[self.frames.len() - 1].timestamp_us;
        Duration::from_micros(ultimo.saturating_sub(primeiro))
    }

    pub fn maior_quadro(&self) -> usize {
        self.frames
            .iter()
            .map(|q| q.bytes as usize)
            .max()
            .unwrap_or(0)
    }

    pub fn idrs(&self) -> usize {
        self.frames.iter().filter(|q| q.idr).count()
    }
}

/// Lê quadros do `.h264` na ordem do sidecar, sem carregar o arquivo inteiro.
struct LeitorDeQuadros {
    arquivo: BufReader<File>,
    buffer: Vec<u8>,
    /// Deslocamento de cada quadro no arquivo, acumulado a partir de `bytes`.
    deslocamentos: Vec<u64>,
}

impl LeitorDeQuadros {
    fn abrir(video: &Path, sidecar: &Sidecar) -> Result<Self> {
        let mut deslocamentos = Vec::with_capacity(sidecar.frames.len());
        let mut acumulado = 0u64;
        for q in &sidecar.frames {
            deslocamentos.push(acumulado);
            acumulado += q.bytes;
        }
        Ok(LeitorDeQuadros {
            arquivo: BufReader::new(File::open(video)?),
            // Alocado uma vez, no tamanho do maior quadro. Depois disto, zero alocação.
            buffer: vec![0u8; sidecar.maior_quadro()],
            deslocamentos,
        })
    }

    /// Carrega o quadro `indice` no buffer interno e devolve uma vista dele.
    fn quadro(&mut self, indice: usize, sidecar: &Sidecar) -> Result<&[u8]> {
        let q = sidecar
            .frames
            .get(indice)
            .ok_or_else(|| Error::Invalid(format!("quadro {indice} não existe no sidecar")))?;
        let tamanho = q.bytes as usize;
        self.arquivo
            .seek(SeekFrom::Start(self.deslocamentos[indice]))?;
        self.arquivo.read_exact(&mut self.buffer[..tamanho])?;
        Ok(&self.buffer[..tamanho])
    }
}

// ---------------------------------------------------------------------------------------------
// Emissor
// ---------------------------------------------------------------------------------------------

/// Manda o `.h264` pela track, respeitando os carimbos do sidecar.
///
/// `pronto` já vem com a sessão de pé e a track de saída aberta.
///
/// # `com_audio`: a **segunda** track, e por que ela é opcional
///
/// Com `--com-audio`, a sessão leva tela **e** som — a forma real do produto, e a única
/// configuração que exercita o receptor tendo de tratar duas tracks ao mesmo tempo. Ela entrou em
/// 30/08/2026 porque a casca Android ganhou áudio nessa rodada e **não havia como provar** o
/// caminho de duas tracks: `emitir-video` só mandava vídeo, `emitir-audio` só mandava áudio, e a
/// única alternativa era um segundo aparelho — proibido naquela noite, com outra frente medindo
/// perda na mesma Wi-Fi.
///
/// A origem do som é o **tom sintético** de sempre. `docs/audio.md` §8: a origem de áudio da
/// bancada é sintética, sempre.
///
/// ## O áudio sai de dentro do laço de vídeo, e não de uma thread
///
/// O laço já pica a espera em fatias de [`FATIA_DE_ESPERA`] (2 ms) por causa do pedido de IDR.
/// Um quadro de áudio de 20 ms cabe nessa grade com folga de uma ordem de grandeza, então o
/// carimbo do áudio erra por no máximo uma fatia — e o jitter buffer do outro lado tem
/// profundidade de 40 ms.
///
/// Uma thread seria mais elegante e traria a pergunta de mandar `TrackEmissor` entre threads, que
/// é justamente o que a casca do Windows evitou de propósito (`apps/windows/src/audio.rs`). Numa
/// ferramenta de bancada, a grade de 2 ms é resposta melhor que uma decisão de desenho nova.
pub fn emitir(
    mut pronto: Ready,
    entrada: &Path,
    repetir: bool,
    com_audio: Option<crate::audio::FonteDeQuadros>,
    ppm_no_audio: f64,
    mut claquete: Option<crate::claquete::Claquete>,
    controles: ControlesDoSom,
) -> Result<()> {
    let (sidecar, video) = Sidecar::carregar(entrada)?;
    let mut leitor = LeitorDeQuadros::abrir(&video, &sidecar)?;

    // As tracks **pela espécie**, e não pela posição: com `--som-primeiro` o som é a primeira da
    // oferta e o vídeo, a segunda (`docs/som-no-receptor.md` §7.0).
    let iv = pronto
        .tracks
        .iter()
        .position(|t| !t.kind().e_audio())
        .ok_or_else(|| Error::Invalid("a sessão subiu sem track de vídeo".into()))?;
    let ia = pronto.tracks.iter().position(|t| t.kind().e_audio());
    let emissor = &pronto.tracks[iv];

    // O pedido de IDR é lido por **bandeira**, e não por callback, de propósito: é o caminho que
    // a casca Android vai usar, e a sonda existe para exercitá-lo no aparelho de verdade.
    //
    // `TrackEmissor::ao_pedir_idr` também existe e funciona; o que ele exige é um tratador que
    // roda numa thread da libdatachannel — thread que, em Android, não está anexada à JVM. Aqui
    // o laço já passa por cada quadro, então uma leitura atômica por quadro resolve sem callback
    // nenhum.

    println!();
    println!("enviando {}", video.display());
    println!(
        "  fonte       : {}x{} @ {} fps, preset {}, faixa {}",
        sidecar.header.width,
        sidecar.header.height,
        sidecar.header.target_fps,
        sidecar.header.preset,
        sidecar.header.color_range
    );
    println!(
        "  quadros     : {} ({} IDR), {:.1} s de vídeo",
        sidecar.frames.len(),
        sidecar.idrs(),
        sidecar.duracao().as_secs_f64()
    );
    println!("  maior quadro: {} bytes", sidecar.maior_quadro());
    println!("  track       : {} [{}]", emissor.label(), emissor.mid());
    if repetir {
        println!("  repetindo em laço até Ctrl-C ou o receptor sair.");
    }
    println!();

    let base_captura = sidecar.frames[0].timestamp_us;
    let mut voltas = 0u64;
    let mut enviados = 0u64;
    let mut falhas = 0u64;
    let mut falhas_seguidas = 0u64;
    let mut idrs_forcados = 0u64;
    let mut buffer_maximo = 0usize;

    // --- a segunda track, quando há ---------------------------------------------------------
    let mut fonte_de_audio = com_audio;
    let mut indice_de_audio = 0u64;
    let mut audio_enviados = 0u64;
    let mut audio_falhas = 0u64;
    let mut audio_pulados = 0u64;
    // Os controles 3 e 4, contados para o `emissor.log` dizer o que foi injetado de fato.
    let mut audio_perdidos = 0u64;
    let mut audio_travados = 0u64;
    let carga_da_perda = vec![0u8; CARGA_DA_PERDA];
    let intervalo_de_audio_us = fonte_de_audio
        .as_ref()
        .map(|_| u64::from(DURACAO_DO_QUADRO_MS) * 1_000)
        .unwrap_or(0);
    if fonte_de_audio.is_some() {
        let Some(ia) = ia else {
            return Err(Error::Invalid(
                "--com-audio pediu uma track de som e a sessão subiu sem ela".into(),
            ));
        };
        println!(
            "  track de som: {} [{}]{}",
            pronto.tracks[ia].label(),
            pronto.tracks[ia].mid(),
            if ia < iv { " — a primeira da oferta" } else { "" }
        );
    }
    let ia = ia.unwrap_or(iv);

    // Índice do último IDR já visto no arquivo: é ele que responde a um PLI.
    let mut ultimo_idr = 0usize;

    // Quanto o relógio anda a cada repetição do arquivo. É a duração da captura **mais um
    // intervalo de quadro**: sem o intervalo, o último quadro de uma volta e o primeiro da
    // seguinte cairiam no mesmo instante, e a repetição produziria um soluço de dois quadros
    // juntos a cada volta.
    let passo_do_laco = sidecar.duracao().as_micros() as u64
        + 1_000_000 / u64::from(sidecar.header.target_fps.max(1));

    let inicio = Instant::now();

    'laco: loop {
        for i in 0..sidecar.frames.len() {
            let q = sidecar.frames[i];
            if q.idr {
                ultimo_idr = i;
            }

            // Espera o carimbo do quadro. É isto que faz a sonda entregar 30 fps de verdade em
            // vez de despejar o arquivo na rede — despejar mediria a rede, não o vídeo.
            let quando = Duration::from_micros(q.timestamp_us.saturating_sub(base_captura))
                + Duration::from_micros(voltas * passo_do_laco);

            // A espera é picada em fatias, e não num `sleep` só, **por causa do pedido de IDR**.
            //
            // Com um `sleep` inteiro, o pedido só era atendido no próximo quadro do arquivo — e
            // uma captura de tela tem intervalos enormes entre quadros quando a tela está
            // parada (nesta bancada, 33 ms de mediana e **817 ms** de máximo, porque o
            // ScreenCaptureKit só emite quando algo muda). Medido assim, o A10s deu 481 ms de
            // recuperação, e o número era do relógio da sonda, não do transporte. Medir a
            // própria ferramenta e chamar de resultado é o erro que este laço evita.
            loop {
                // Pedido pendente: manda o último IDR já, sem esperar o quadro da vez. É o que
                // um encoder de verdade faria ao ser forçado, e é o que o Windows paga ~150 ms
                // para fazer recriando o MFT.
                if emissor.pegar_pedido_de_idr() {
                    let carimbo = inicio.elapsed().as_micros() as u64 + controles.origem_us;
                    let idr = leitor.quadro(ultimo_idr, &sidecar)?;
                    if pronto.tracks[iv]
                        .enviar_quadro(QuadroCodificado {
                            annexb: idr,
                            timestamp_us: carimbo,
                            idr: true,
                        })
                        .is_ok()
                    {
                        idrs_forcados += 1;
                        enviados += 1;
                    }
                }
                // O som, na grade de 2 ms que a espera já tem. Um quadro por vez, sempre: o
                // pacotizador da libdatachannel não fragmenta, e dois quadros de Opus numa
                // chamada viram um pacote que o outro lado decodifica errado sem erro nenhum no
                // caminho (`docs/audio.md` §6).
                if let Some(fonte) = fonte_de_audio.as_mut() {
                    let agora_us = inicio.elapsed().as_micros() as u64;
                    // `--ppm-no-audio N`: o relógio de mídia do som anda N ppm mais depressa que o
                    // do vídeo. Os pacotes saem N ppm mais cedo, e o carimbo continua sendo o do
                    // tempo de mídia (índice × 20 ms): é um emissor com o cristal do áudio fora do
                    // relógio do sistema. O receptor vê deriva entre emissor e DAC (o Varispeed
                    // acompanha) e entre as tracks (`inter_track_drift_ppm`). §9.3, controle 6.
                    let fator = 1.0 - ppm_no_audio * 1e-6;
                    while controles.envio_us(indice_de_audio, intervalo_de_audio_us, fator)
                        <= agora_us
                    {
                        let carimbo = indice_de_audio * intervalo_de_audio_us;
                        // Com deslocamento negativo, os primeiros |MS|/20 pacotes teriam carimbo
                        // negativo. Saturar em 0 mandava vários pacotes com o mesmo carimbo 0
                        // (crítica 10, m4): eles não vão, e o resumo conta.
                        let Some(carimbo_no_fio) = carimbo.checked_add_signed(controles.deslocar_us)
                        else {
                            audio_pulados += 1;
                            indice_de_audio += 1;
                            continue;
                        };
                        let carimbo_no_fio = carimbo_no_fio + controles.origem_us;
                        let pacote = match claquete.as_ref() {
                            Some(c) => fonte.proximo_editado(indice_de_audio, |pcm, canais, taxa| {
                                c.editar_som(pcm, canais, taxa, carimbo)
                            })?,
                            None => fonte.proximo(indice_de_audio)?,
                        };
                        // O controle 3: o quadro sai numerado e grande demais, e a porta puxada
                        // do outro lado o joga fora (ver `ControlesDoSom::perder_a_cada`). O
                        // conteúdo continua sendo codificado acima, para o codificador não ver
                        // buraco nenhum: quem perde é o fio.
                        let perdido = controles.perde(indice_de_audio);
                        let carga: &[u8] = if perdido { &carga_da_perda } else { &pacote };
                        match pronto.tracks[ia].enviar_audio(AmostraDeAudio {
                            payload: carga,
                            timestamp_us: carimbo_no_fio,
                        }) {
                            Ok(()) if perdido => audio_perdidos += 1,
                            Ok(()) => audio_enviados += 1,
                            Err(_) => audio_falhas += 1,
                        }
                        if controles.travado(indice_de_audio, intervalo_de_audio_us, fator) {
                            audio_travados += 1;
                        }
                        indice_de_audio += 1;
                    }
                }

                let agora = inicio.elapsed();
                if agora >= quando {
                    break;
                }
                std::thread::sleep((quando - agora).min(FATIA_DE_ESPERA));
            }

            let carimbo = inicio.elapsed().as_micros() as u64;
            // A claquete marca o primeiro quadro de vídeo que passa do instante de cada evento, e
            // a verdade vai para o disco **a cada evento marcado**: a sonda morta por sinal (o
            // `provar-som.sh` a mata) não perde a testemunha B (crítica 10, M6).
            if let Some(c) = claquete.as_mut() {
                if c.marcar_video(i, carimbo) > 0 {
                    c.gravar()?;
                }
            }
            let bytes = leitor.quadro(i, &sidecar)?;
            // A claquete (acima) fica no relógio local; o fio leva a origem do controle 5.
            match pronto.tracks[iv].enviar_quadro(QuadroCodificado {
                annexb: bytes,
                timestamp_us: carimbo + controles.origem_us,
                idr: q.idr,
            }) {
                Ok(()) => {
                    enviados += 1;
                    falhas_seguidas = 0;
                }
                // Track ainda não aberta, ou transporte caído. Contar e seguir é o
                // comportamento do contrato: nunca enfileirar.
                Err(_) => {
                    falhas += 1;
                    falhas_seguidas += 1;
                }
            }
            buffer_maximo = buffer_maximo.max(pronto.tracks[iv].pendente());

            // Como o emissor não lê a sinalização depois que a sessão sobe, é a própria track
            // que avisa que o outro lado sumiu: quando ela fecha, todo envio falha. Um segundo
            // inteiro de falha seguida (a 30 fps, 30 quadros) é sinal claro, e não um soluço de
            // "ainda não abriu".
            if falhas_seguidas > sidecar.header.target_fps.max(1) as u64 {
                println!("  a track parou de aceitar quadros; o receptor saiu.");
                break 'laco;
            }
        }
        voltas += 1;
        if !repetir {
            break;
        }
    }

    // Arrasto: os últimos pacotes ainda estão no ar, e sair agora mataria a track antes de eles
    // saírem do buffer do SCTP/SRTP.
    std::thread::sleep(Duration::from_millis(500));

    if let Some(c) = claquete.as_ref() {
        c.gravar()?;
        println!(
            "claquete: semente {}, {} evento(s) marcado(s) no vídeo",
            c.semente,
            c.marcados()
        );
    }

    let emissor = &pronto.tracks[iv];
    println!();
    println!("resultado do emissor");
    println!("  quadros enviados     : {enviados}");
    println!("  falhas de envio      : {falhas}");
    if intervalo_de_audio_us > 0 {
        println!(
            "  som enviado          : {audio_enviados} quadro(s) de 20 ms, {audio_falhas} falha(s)"
        );
        if audio_pulados > 0 {
            println!(
                "  som não enviado      : {audio_pulados} quadro(s) com carimbo negativo (--deslocar-audio)"
            );
        }
        if controles.perder_a_cada > 0 {
            println!(
                "  som perdido de propósito: {audio_perdidos} quadro(s), 1 de cada {} a partir do {} (--perder-no-audio; carga de {} bytes)",
                controles.perder_a_cada, PERDA_A_PARTIR_DO_QUADRO, CARGA_DA_PERDA
            );
        }
        if let Some((a, b)) = controles.travar {
            println!(
                "  som travado de propósito: {audio_travados} quadro(s) segurados de {:.3} s a {:.3} s e soltos juntos (--travar-audio-ms)",
                a as f64 / 1e6,
                b as f64 / 1e6
            );
        }
        if controles.origem_us > 0 {
            println!(
                "  origem no fio        : +{} µs nas duas tracks (--origem-na-volta)",
                controles.origem_us
            );
        }
    }
    println!("  IDR no fluxo         : {}", emissor.idrs_enviados());
    println!("  IDR sem SPS/PPS      : {}", emissor.idrs_sem_parametros());
    if emissor.idrs_sem_parametros() > 0 {
        println!("    ATENÇÃO: o contrato manda todo IDR levar SPS e PPS. Quem entrar na sessão");
        println!("    depois vai ficar sem imagem até o próximo IDR completo — que é exatamente");
        println!("    o defeito medido no Windows no M1.");
    }
    println!("  pedidos de IDR (PLI/FIR): {}", emissor.pedidos_de_idr());
    println!("  IDR forçados por pedido : {idrs_forcados}");
    println!("  buffer máximo da track  : {buffer_maximo} bytes");
    // **O lado do emissor do par que decide a dívida 30.** O receptor conta os pacotes RTP
    // NUMERADOS (`pacotes_vistos + pacotes_faltando`); este conta os que a libdatachannel
    // deveria numerar para tudo o que já lhe entregamos. Ver `quall_core::track::pacotes_da_unidade`.
    println!(
        "  PACOTES ENTREGUES À libdatachannel : {}",
        emissor.pacotes_entregues()
    );
    println!("  bytes entregues         : {}", emissor.bytes_enviados());

    pronto.link.close("envio concluído");
    drop(pronto);
    quall_core::transport::cleanup();
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Receptor
// ---------------------------------------------------------------------------------------------

/// O que o receptor viu, para o relatório e para a medição de tempo até a primeira imagem.
#[derive(Default)]
struct Recepcao {
    quadros: u64,
    idrs: u64,
    bytes: u64,
    /// Do início da recepção ao primeiro IDR entregue. É o "tempo até a primeira imagem" do
    /// contrato — a única coisa que a pessoa sente como "funcionou".
    primeiro_idr_us: Option<u64>,
    /// Do pedido de IDR ao IDR seguinte. É a medida de recuperação.
    recuperacao_us: Option<u64>,

    // --- o conjunto de parâmetros, que este instrumento não olhava -----------------------------
    //
    // `docs/tela-preta.md` §3.3(a) mede o ponto cego: este tratador gravava `q.annexb` no disco e
    // contava `q.idr`, e **nunca percorria as NAL units**. Um emissor que jamais reinjeta SPS/PPS
    // passa na prova com "577 gravados, 0 perdidos" e deixa a tela preta, porque sem conjunto de
    // parâmetros nenhum decodificador tem por onde começar.
    //
    // Percorrer o Annex-B aqui é a resposta barata: é varredura linear de bytes, é a mesma que o
    // `DecodificadorH264` do receptor iOS já faz por quadro, e **não decodifica nem abre imagem
    // nenhuma** — o que importa porque a origem desta bancada é a tela de trabalho do usuário.
    nals_sps: u64,
    nals_pps: u64,
    nals_idr: u64,
    nals_nao_idr: u64,
    /// Quadros que traziam SPS **e** PPS no mesmo Annex-B.
    ///
    /// É esta a condição que o receptor iOS exige para montar a sessão de decode
    /// (`DecodificadorH264.alimentar`: `if let novoSps, let novoPps`). Contar SPS e PPS
    /// separadamente esconderia o caso em que os dois chegam, mas nunca juntos.
    quadros_com_parametros: u64,
    /// Do início da recepção ao primeiro quadro que trouxe SPS+PPS. `None` é o veredito.
    primeiro_parametro_us: Option<u64>,
    /// `profile_idc` e `level_idc` do primeiro SPS visto — bytes 1 e 3 da NAL, a mesma leitura
    /// que o receptor iOS faz. Diz o que o emissor mandou de verdade, e não o que se supunha.
    perfil: Option<(u8, u8)>,
    /// Tamanho, em bytes, do maior quadro que trouxe conjunto de parâmetros.
    ///
    /// **É deste número que sai a conta que importa.** Um quadro de N bytes atravessa a rede como
    /// ~N/1200 pacotes RTP, e o depacotizador condena o quadro inteiro se **um** deles faltar
    /// (`rtp.rs`: fragmento do meio sem começo → `condenado`). Com o emissor do Windows mandando
    /// conjunto de parâmetros só nos IDR, e IDR só a cada ~128 quadros, a probabilidade de uma
    /// sessão inteira passar sem nenhum conjunto íntegro é calculável — e é ela que decide se a
    /// tela fica preta para sempre.
    maior_quadro_com_parametros: usize,

    // --- a política de pedir IDR na perda, quando ligada por `--politica-de-perda` --------------
    //
    // Ver a doc de [`receber`] para por que ela existe aqui.
    /// Instante da perda ainda não coberta por um IDR. `None` quando não há nenhuma pendente.
    perda_em: Option<Instant>,
    /// Já saiu um PLI **para esta perda**? Enquanto for `false`, vale o piso curto.
    pediu_por_esta_perda: bool,
    /// Perdas **distintas**. Uma rajada que produz dez subidas de `quadros_descartados` seguidas
    /// continua sendo uma perda pendente — o piso é sobre o pedido, não sobre a perda.
    eventos_de_perda: u64,
    /// Perdas que um IDR resolveu **sem** que nenhum pedido tivesse saído por elas: o GOP do
    /// emissor consertou dentro da janela de supressão. Cada uma é uma rajada de IDR que não foi
    /// injetada no rádio que acabou de perder.
    perdas_resolvidas_sem_pedido: u64,
    /// Tempo sem referência, em ms: da perda detectada ao IDR seguinte. É a medida de recuperação
    /// que decide se a quinta porta (ou o piso dela) vale o que custa.
    sem_referencia_ms: Vec<f64>,
}

/// Varre os NALs de um quadro Annex-B, aceitando start code de 3 e de 4 bytes.
///
/// Cópia deliberada da varredura do `DecodificadorH264` do receptor iOS: uma sonda que usasse
/// outra varredura poderia discordar do produto por causa do instrumento, e a pergunta aqui é
/// exatamente "o que o produto teria visto".
fn percorrer_nals(dados: &[u8], mut visitar: impl FnMut(u8, &[u8])) {
    let n = dados.len();
    let mut i = 0usize;
    let mut inicio: Option<usize> = None;
    while i + 2 < n {
        if dados[i] == 0 && dados[i + 1] == 0 && dados[i + 2] == 1 {
            if let Some(p) = inicio {
                // Start code de 4 bytes: o zero que o antecede pertence ao start code, não à NAL.
                let mut fim = i;
                if fim > p && dados[fim - 1] == 0 {
                    fim -= 1;
                }
                if fim > p {
                    visitar(dados[p] & 0x1f, &dados[p..fim]);
                }
            }
            i += 3;
            inicio = Some(i);
            continue;
        }
        i += 1;
    }
    if let Some(p) = inicio {
        if p < n {
            visitar(dados[p] & 0x1f, &dados[p..n]);
        }
    }
}

/// A política de **pedir IDR quando o fluxo perde referência**, copiada do receptor Android.
///
/// # Por que uma sonda precisa dela
///
/// Sem ela a sonda **não é um receptor de produto**, e um A/B da quinta porta medido contra ela
/// não mede porta nenhuma: a quinta porta só age quando alguém pede quadro-chave, e a sonda pedia
/// um na entrada e mais nenhum. Medido nesta bancada em 29/08 — uma sessão de 57 s do `quall-app`
/// com a porta LIGADA fez **zero** recriações contra a sonda, e 69 a 75 contra o app Android, que
/// tem a política. O braço "porta ligada" era o braço "porta desligada" com outro nome.
///
/// O receptor que tem a política é o app Android, e ele não tem o contador exato de perda
/// (`pacotes_perdidos_de_verdade` está no núcleo, mas pôr o número lá dentro é recompilar `.so` e
/// APK). A sonda tem o contador e não tinha a política. Esta struct é a metade que faltava para
/// existir **um** receptor com as duas coisas.
///
/// # O que é copiado, e o que não é
///
/// São copiados o ritmo de leitura (100 ms), os dois pisos e a regra de que **um IDR fecha a
/// perda pendente venha ele do pedido ou do GOP**. Não é copiado o decodificador: a sonda não
/// decodifica, então o `quadros_descartados` do núcleo é a única testemunha de perda que ela tem
/// — que é a mesma que o Android lê por `framesDropped`.
#[derive(Clone, Copy)]
pub struct PoliticaDePerda {
    /// Piso antes do **primeiro** pedido de uma perda nova. Produto: 100 ms.
    pub piso_primeiro: Duration,
    /// Piso entre **repetições** do pedido, enquanto a mesma perda segue sem resposta.
    /// Produto: 500 ms.
    pub piso_repeticao: Duration,
}

impl Default for PoliticaDePerda {
    fn default() -> Self {
        Self {
            piso_primeiro: Duration::from_millis(100),
            piso_repeticao: Duration::from_millis(500),
        }
    }
}

/// Recebe a track e grava o `.h264` do outro lado.
///
/// `pedir_em` liga a demonstração de recuperação: passados N segundos, o receptor pede IDR e
/// mede quanto demora até um IDR chegar.
///
/// `politica` liga a política de pedir IDR na perda — ver [`PoliticaDePerda`]. `None`, que é o
/// padrão, mantém o comportamento antigo da sonda: pede um IDR na entrada e mais nenhum.
///
/// `relatar_a_cada` imprime uma linha `FATIA` por período, com a perda **da fatia** ao lado da
/// acumulada. É o que separa "a perda muda com o tempo" de "a perda é constante" numa sessão
/// longa — um total no fim não responde essa pergunta.
/// O cabeçalho de 64 bytes que `tools/vidro-a-vidro/Fontes/Comum/Fio.swift` lê, montado aqui.
///
/// # Por que a sonda fala o protocolo do arnês de vidro a vidro
///
/// `docs/medir-vidro-a-vidro.md` projetou dois métodos e travou o da câmera externa em dois fios
/// que não existiam: um shim de Android para desenhar a faixa, e um receptor que alimentasse o
/// decodificador **a partir da track**. Com câmera de verdade como emissor o primeiro fio some —
/// quem desenha a faixa passa a ser a tela do Mac, que `vidro-emissor` já sabe fazer. Este
/// encaminhador é o segundo fio, e ele **não reimplementa nada**: `Codigo.ler` e o `Decodificador`
/// do arnês já estão exercitados em milhares de quadros, e o que faltava era o cano até eles.
///
/// Os campos de tempo do emissor (`desenho`, `commit`, `captura`, `pts`, `encode`, `envio`) saem
/// **zerados de propósito**: aqui o quadro veio de um sensor do outro lado do vidro, e nós não
/// temos nenhum desses instantes. O que o arnês precisa é do índice lido nos pixels e do instante
/// em que decodificou — os dois nascem do lado dele. Preencher com palpite seria pior que zerar.
fn cabecalho_do_fio(idr: bool, tamanho: u32) -> [u8; 64] {
    let mut c = [0u8; 64];
    c[0..4].copy_from_slice(&0x5156_4431u32.to_le_bytes()); // "QVD1"
    c[56] = u8::from(idr);
    c[60..64].copy_from_slice(&tamanho.to_le_bytes());
    c
}

/// Abre o soquete unix e **espera** o arnês conectar, ou devolve `None` sem derrubar a corrida.
///
/// A sonda é servidora e o `vidro-receptor` é cliente, que é o inverso do laço fechado (lá quem
/// serve é o `vidro-emissor`). Espera limitada: uma corrida de bancada que trava esperando um
/// consumidor que ninguém subiu é pior que uma corrida sem encaminhamento.
fn abrir_encaminhamento(
    caminho: &Path,
    espera: Duration,
) -> Option<std::os::unix::net::UnixStream> {
    let _ = std::fs::remove_file(caminho);
    let ouvinte = std::os::unix::net::UnixListener::bind(caminho).ok()?;
    ouvinte.set_nonblocking(true).ok()?;
    println!(
        "  encaminhando quadros para {} (esperando o arnês…)",
        caminho.display()
    );
    let limite = Instant::now() + espera;
    while Instant::now() < limite {
        match ouvinte.accept() {
            Ok((fluxo, _)) => {
                fluxo.set_nonblocking(false).ok()?;
                println!("  arnês conectado ao encaminhamento");
                return Some(fluxo);
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => return None,
        }
    }
    println!(
        "  ninguém conectou em {}; sigo sem encaminhar",
        caminho.display()
    );
    None
}

pub fn receber(
    mut pronto: Ready,
    saida: &Path,
    segundos: Duration,
    pedir_em: Option<Duration>,
    politica: Option<PoliticaDePerda>,
    relatar_a_cada: Option<Duration>,
    encaminhar: Option<&Path>,
    relogio: bool,
    trocar_no_som: u32,
) -> Result<()> {
    println!();
    println!("esperando a track de vídeo…");

    // Com `--relogio`, a track de som também é aceita: ela fica com um tratador que não faz nada,
    // só para o núcleo observar os pacotes dela no relógio da sessão.
    let (track, som) = if relogio {
        esperar_video_e_som(&mut pronto)?
    } else {
        (
            crate::esperar_track(
                &mut pronto,
                |k| k == TrackKind::Screen || k == TrackKind::Camera,
                "vídeo",
                Duration::from_secs(20),
            )?,
            None,
        )
    };
    if let Some(s) = som.as_ref() {
        println!("  track de som: {:?} [{}] {} (só para o relógio; nada toca)", s.kind(), s.mid(), s.label());
        s.ao_receber_audio(|_| {})?;
        // `--trocar-no-som N`: a reordenação do controle 5, na chegada (§9.3 do som no receptor).
        if trocar_no_som > 0 {
            if !s.cravar_troca_de_bancada(trocar_no_som) {
                return Err(Error::Invalid(format!("--trocar-no-som {trocar_no_som} recusado")));
            }
            println!("  troca de bancada no som: 1 par a cada {trocar_no_som} pacotes, na chegada");
        }
    } else if trocar_no_som > 0 {
        return Err(Error::Invalid("--trocar-no-som pede --relogio (a track de som)".into()));
    }
    println!(
        "  track       : {:?} [{}] {}",
        track.kind(),
        track.mid(),
        track.label()
    );
    if track.kind() != TrackKind::Screen && track.kind() != TrackKind::Camera {
        return Err(Error::Invalid(format!(
            "track de {:?} não é vídeo",
            track.kind()
        )));
    }

    let arquivo = Arc::new(Mutex::new(std::io::BufWriter::new(File::create(saida)?)));
    // O encaminhamento sobe **depois** da track, para o arnês não esperar a sessão inteira.
    let fio: Arc<Mutex<Option<std::os::unix::net::UnixStream>>> = Arc::new(Mutex::new(
        encaminhar.and_then(|c| abrir_encaminhamento(c, Duration::from_secs(30))),
    ));
    let estado = Arc::new(Mutex::new(Recepcao::default()));
    // Marco zero da recepção: o momento em que o tratador é registrado, que é o mais próximo
    // que dá de "entrei na sessão".
    let inicio = Instant::now();
    let pedido_em: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));

    {
        let arquivo = Arc::clone(&arquivo);
        let estado = Arc::clone(&estado);
        let pedido_em = Arc::clone(&pedido_em);
        let fio = Arc::clone(&fio);
        track.ao_receber_quadro(move |q: QuadroCodificado<'_>| {
            // Antes do disco: o arnês mede latência, e escrever nele depois de um `write_all` de
            // arquivo somaria a espera do disco ao número que ele publica.
            if let Ok(mut f) = fio.lock() {
                if let Some(fluxo) = f.as_mut() {
                    let c = cabecalho_do_fio(q.idr, q.annexb.len() as u32);
                    if fluxo
                        .write_all(&c)
                        .and_then(|()| fluxo.write_all(q.annexb))
                        .is_err()
                    {
                        *f = None; // o arnês saiu; a corrida segue
                    }
                }
            }
            // Este tratador roda numa thread da libdatachannel. Gravar em disco aqui é aceitável
            // numa sonda — e é exatamente o que uma casca de verdade **não** deve fazer, porque
            // um disco lento seguraria a recepção. Uma casca entrega ao decoder, que é rápido.
            if let Ok(mut f) = arquivo.lock() {
                let _ = f.write_all(q.annexb);
            }
            // A varredura acontece **fora** do cadeado: é trabalho puro sobre o quadro, e segurar
            // a trava durante ela poria o instrumento no caminho da recepção que ele mede.
            let (mut sps, mut pps, mut idr, mut nao_idr) = (0u64, 0u64, 0u64, 0u64);
            let mut perfil: Option<(u8, u8)> = None;
            percorrer_nals(q.annexb, |tipo, nal| match tipo {
                rtp::nal::SPS => {
                    sps += 1;
                    if perfil.is_none() && nal.len() >= 4 {
                        perfil = Some((nal[1], nal[3]));
                    }
                }
                rtp::nal::PPS => pps += 1,
                rtp::nal::IDR => idr += 1,
                1 => nao_idr += 1,
                _ => {}
            });

            if let Ok(mut e) = estado.lock() {
                e.quadros += 1;
                e.bytes += q.annexb.len() as u64;
                e.nals_sps += sps;
                e.nals_pps += pps;
                e.nals_idr += idr;
                e.nals_nao_idr += nao_idr;
                if e.perfil.is_none() {
                    e.perfil = perfil;
                }
                // SPS **e** PPS no mesmo quadro é a condição que o receptor iOS exige para montar
                // a sessão. Sem os dois juntos ele nunca chama `recriarSessao`.
                if sps > 0 && pps > 0 {
                    e.quadros_com_parametros += 1;
                    e.maior_quadro_com_parametros =
                        e.maior_quadro_com_parametros.max(q.annexb.len());
                    if e.primeiro_parametro_us.is_none() {
                        e.primeiro_parametro_us = Some(inicio.elapsed().as_micros() as u64);
                    }
                }
                if q.idr {
                    e.idrs += 1;
                    if e.primeiro_idr_us.is_none() {
                        e.primeiro_idr_us = Some(inicio.elapsed().as_micros() as u64);
                    }
                    if e.recuperacao_us.is_none() {
                        if let Ok(p) = pedido_em.lock() {
                            if let Some(quando) = *p {
                                e.recuperacao_us = Some(quando.elapsed().as_micros() as u64);
                            }
                        }
                    }
                    // **O IDR fecha a perda pendente venha ele do pedido ou do GOP do emissor.**
                    // Se o emissor consertou sozinho dentro da janela de supressão, a perda deixa
                    // de existir e nenhum pedido sai por ela — a metade da supressão que a
                    // RFC 4585 não escreve e que a aritmética dos IDR exige. Mesma regra do
                    // receptor Android (`ReceptorSessao.kt`), de onde esta política foi copiada.
                    if let Some(quando) = e.perda_em.take() {
                        if !e.pediu_por_esta_perda {
                            e.perdas_resolvidas_sem_pedido += 1;
                        }
                        e.pediu_por_esta_perda = false;
                        let ms = quando.elapsed().as_secs_f64() * 1000.0;
                        if e.sem_referencia_ms.len() < 8000 {
                            e.sem_referencia_ms.push(ms);
                        }
                    }
                }
            }
        });
    }

    // Pedir IDR ao entrar é o caminho normal do contrato: o receptor não viu IDR nenhum ainda, e
    // sem ele o decoder não tem por onde começar. Tenta algumas vezes porque o PLI só sai depois
    // de o transporte estar de pé.
    let mut pediu_na_entrada = false;
    for _ in 0..50 {
        if track.pedir_idr().is_ok() {
            pediu_na_entrada = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    println!(
        "  pedido de IDR na entrada: {}",
        if pediu_na_entrada {
            "enviado"
        } else {
            "NÃO saiu (a track ainda não estava aberta)"
        }
    );
    println!("  gravando em {}", saida.display());
    println!();

    let fim = Instant::now() + segundos;
    let mut pediu_de_novo = false;
    let mut ocioso = Instant::now();
    let mut ultimo_visto = 0u64;

    // --- o estado da política de perda, que só existe com `--politica-de-perda` -----------------
    //
    // `-1` até a primeira leitura: ela só fixa a linha de base e nunca conta como perda. Zerar
    // aqui faria a volta seguinte inventar uma perda do tamanho do contador inteiro — a mesma
    // armadilha que o comentário do receptor Android registra.
    let mut ultimo_descartados: i64 = -1;
    let mut ultima_olhada = Instant::now();
    let mut ultimo_pli_de_perda: Option<Instant> = None;
    let mut pedidos_por_perda = 0u64;
    let mut perdas_suprimidas = 0u64;

    // --- o relatório periódico, que é o que uma sessão longa exige ------------------------------
    //
    // Um total no fim de 30 minutos responde "quanto perdeu" e **não** responde "a perda muda com
    // o tempo", que é a pergunta da sessão longa. Sem isto, uma perda que dobrasse no vigésimo
    // minuto e uma perda constante dariam exatamente o mesmo número final.
    //
    // Sai por delta, e não por acumulado, de propósito: o acumulado dilui qualquer mudança pelo
    // tempo já corrido, e é justamente a mudança que se procura.
    let mut proximo_relato = relatar_a_cada.map(|p| Instant::now() + p);
    let mut anterior = (0u64, 0u64, 0u64); // (vistos, perdidos_de_verdade, quadros)
    let mut proximo_relogio = Instant::now() + Duration::from_secs(1);

    while Instant::now() < fim {
        std::thread::sleep(Duration::from_millis(50));

        if relogio && Instant::now() >= proximo_relogio {
            proximo_relogio += Duration::from_secs(1);
            println!(
                "  RELOGIO t={:.0}s video[{}] som[{}]",
                inicio.elapsed().as_secs_f64(),
                linha_do_relogio(track.retrato_do_relogio()),
                som.as_ref()
                    .map(|s| linha_do_relogio(s.retrato_do_relogio()))
                    .unwrap_or_else(|| "sem track".into()),
            );
        }

        if let (Some(quando), Some(periodo)) = (proximo_relato, relatar_a_cada) {
            if Instant::now() >= quando {
                proximo_relato = Some(Instant::now() + periodo);
                let c = track.contadores();
                let quadros = estado.lock().map(|e| e.quadros).unwrap_or(0);
                let (dv, dp, dq) = (
                    c.pacotes_vistos - anterior.0,
                    c.pacotes_perdidos_de_verdade - anterior.1,
                    quadros - anterior.2,
                );
                anterior = (c.pacotes_vistos, c.pacotes_perdidos_de_verdade, quadros);
                let base = dv + dp;
                println!(
                    "  FATIA t={:.0}s vistos=+{dv} perdidos=+{dp} quadros=+{dq} \
                     perda_da_fatia={:.3}% acumulada={:.3}% descartados={} tarde_demais={}",
                    inicio.elapsed().as_secs_f64(),
                    if base > 0 {
                        100.0 * dp as f64 / base as f64
                    } else {
                        0.0
                    },
                    if c.pacotes_vistos + c.pacotes_perdidos_de_verdade > 0 {
                        100.0 * c.pacotes_perdidos_de_verdade as f64
                            / (c.pacotes_vistos + c.pacotes_perdidos_de_verdade) as f64
                    } else {
                        0.0
                    },
                    c.quadros_descartados,
                    c.pacotes_tarde_demais,
                );
            }
        }

        // --- perda no meio do fluxo: a política do produto, quando pedida --------------------
        //
        // Ver a doc de `receber` para por que uma sonda precisa dela. O ritmo de leitura (100 ms)
        // e os dois pisos são os do receptor Android, e é de propósito: um número que só valha
        // para a sonda não responde nada sobre o produto.
        if let Some(pol) = politica {
            if ultima_olhada.elapsed() >= Duration::from_millis(100) {
                ultima_olhada = Instant::now();
                let descartados = track.contadores().quadros_descartados as i64;
                if ultimo_descartados < 0 {
                    ultimo_descartados = descartados;
                } else if descartados > ultimo_descartados {
                    ultimo_descartados = descartados;
                    if let Ok(mut e) = estado.lock() {
                        if e.perda_em.is_none() {
                            e.perda_em = Some(Instant::now());
                            e.pediu_por_esta_perda = false;
                            e.eventos_de_perda += 1;
                        }
                    }
                }

                // Dois pisos, e a diferença é a estreia: o primeiro pedido de uma perda nova
                // limita rajada de perdas distintas (curto); do segundo em diante o pedido é
                // insistência num PLI que ninguém atendeu (longo).
                let (pendente, ja_pediu) = match estado.lock() {
                    Ok(e) => (e.perda_em.is_some(), e.pediu_por_esta_perda),
                    Err(_) => (false, false),
                };
                if pendente {
                    let piso = if ja_pediu {
                        pol.piso_repeticao
                    } else {
                        pol.piso_primeiro
                    };
                    let pode = match ultimo_pli_de_perda {
                        None => true,
                        Some(q) => q.elapsed() >= piso,
                    };
                    if pode {
                        ultimo_pli_de_perda = Some(Instant::now());
                        match track.pedir_idr() {
                            Ok(()) => {
                                pedidos_por_perda += 1;
                                if let Ok(mut e) = estado.lock() {
                                    e.pediu_por_esta_perda = true;
                                }
                            }
                            // Não engolir: pedido recusado é o receptor ficando sem imagem. A
                            // perda continua pendente para a volta seguinte tentar de novo.
                            Err(e) => println!("  pedido de IDR na perda recusado: {e}"),
                        }
                    } else {
                        perdas_suprimidas += 1;
                    }
                }
            }
        }

        if let Some(atraso) = pedir_em {
            if !pediu_de_novo && inicio.elapsed() >= atraso {
                pediu_de_novo = true;
                if let Ok(mut e) = estado.lock() {
                    e.recuperacao_us = None;
                }
                if let Ok(mut p) = pedido_em.lock() {
                    *p = Some(Instant::now());
                }
                match track.pedir_idr() {
                    Ok(()) => println!(
                        "  [{:.1}s] pedido de IDR enviado",
                        inicio.elapsed().as_secs_f64()
                    ),
                    Err(e) => println!(
                        "  [{:.1}s] o pedido de IDR falhou: {e}",
                        inicio.elapsed().as_secs_f64()
                    ),
                }
            }
        }

        let agora = estado.lock().map(|e| e.quadros).unwrap_or(0);
        if agora > ultimo_visto {
            ultimo_visto = agora;
            ocioso = Instant::now();
        } else if ultimo_visto > 0 && ocioso.elapsed() > Duration::from_secs(5) {
            println!("  cinco segundos sem quadro; o emissor terminou.");
            break;
        }
    }

    if let Ok(mut f) = arquivo.lock() {
        f.flush()?;
    }

    let e = estado.lock().map_err(|_| Error::Closed)?;
    println!();
    println!("resultado do receptor");
    if let Some(s) = som.as_ref() {
        let (trocados, na_volta) = s.trocados_na_bancada();
        if trocar_no_som > 0 {
            println!(
                "  som trocado na chegada: {trocados} par(es), {na_volta} através da volta de 32 bits"
            );
        }
        let c = s.contadores();
        println!(
            "  som (depacotizador): vistos {} faltando {} fora_de_ordem {}",
            c.pacotes_vistos, c.pacotes_faltando, c.eventos_fora_de_ordem
        );
    }
    println!("  quadros gravados  : {}", e.quadros);
    println!("  IDR               : {}", e.idrs);
    println!("  bytes             : {}", e.bytes);
    if politica.is_some() {
        // **A recuperação, que é o que a quinta porta compra.** Sai aqui e não no fim porque é o
        // par do número de perda: quem for escolher um piso entre recriações troca uma coisa
        // pela outra, e as duas têm de estar na mesma tela.
        let p50 = percentil(&e.sem_referencia_ms, 0.50);
        let p95 = percentil(&e.sem_referencia_ms, 0.95);
        println!(
            "  POLÍTICA DE PERDA : eventos={} pedidos_por_perda={pedidos_por_perda} \
             suprimidos={perdas_suprimidas} resolvidas_sem_pedido={}",
            e.eventos_de_perda, e.perdas_resolvidas_sem_pedido
        );
        println!(
            "  SEM REFERÊNCIA    : n={} p50={} p95={} máx={}  (ms, da perda ao IDR seguinte)",
            e.sem_referencia_ms.len(),
            p50.map(|v| format!("{v:.1}")).unwrap_or_else(|| "—".into()),
            p95.map(|v| format!("{v:.1}")).unwrap_or_else(|| "—".into()),
            e.sem_referencia_ms
                .iter()
                .cloned()
                .fold(f64::NAN, f64::max)
                .max(0.0),
        );
    }
    // Uma leitura só: os números abaixo saem do mesmo instante, e a aritmética entre eles fecha.
    let c = track.contadores();

    // --- o conjunto de parâmetros ------------------------------------------------------------
    //
    // Esta seção existe porque a sua ausência era o ponto cego de **todas** as provas de emissor
    // de desktop deste projeto (`docs/tela-preta.md` §3.3a). Sem ela a sonda diz "gravei tudo,
    // não perdi nada" sobre um fluxo do qual nenhum decodificador conseguiria tirar uma imagem.
    println!();
    println!("conjunto de parâmetros (o que um decodificador teria visto)");
    println!("  NAL SPS           : {}", e.nals_sps);
    println!("  NAL PPS           : {}", e.nals_pps);
    println!("  NAL IDR (tipo 5)  : {}", e.nals_idr);
    println!("  NAL não-IDR (1)   : {}", e.nals_nao_idr);
    println!(
        "  quadros com SPS+PPS juntos : {}  (é o que o receptor iOS exige para montar a sessão)",
        e.quadros_com_parametros
    );
    match e.perfil {
        Some((p, l)) => println!(
            "  primeiro SPS      : profile_idc={p} level_idc={l}  (nível {}.{})",
            l / 10,
            l % 10
        ),
        None => println!("  primeiro SPS      : NENHUM"),
    }
    match e.primeiro_parametro_us {
        Some(us) => println!("  1º SPS+PPS em     : {:.1} ms", us as f64 / 1000.0),
        None => println!("  1º SPS+PPS em     : NUNCA"),
    }

    // --- a fragilidade, em números -----------------------------------------------------------
    //
    // Não é opinião nem margem de segurança: é a conta que decide se uma sessão fica preta. Um
    // quadro com conjunto de parâmetros vira ~N/MTU pacotes, e **um** pacote que falte condena o
    // quadro inteiro (`rtp.rs`: fragmento do meio sem começo → `condenado`). Se o emissor só
    // manda conjunto de parâmetros em IDR raros e ignora pedidos, a chance de a sessão inteira
    // passar sem nenhum conjunto íntegro é (1 - (1-p)^pacotes) elevado ao número de tentativas.
    const MTU_RTP: usize = 1200;
    if e.maior_quadro_com_parametros > 0 {
        let pacotes = e.maior_quadro_com_parametros.div_ceil(MTU_RTP);
        println!(
            "  maior quadro com parâmetros : {} bytes  (~{} pacotes RTP a {} B)",
            e.maior_quadro_com_parametros, pacotes, MTU_RTP
        );
        let janela = c.pacotes_vistos + c.pacotes_faltando;
        if janela > 0 {
            let p = c.pacotes_faltando as f64 / janela as f64;
            let intacto = (1.0 - p).powi(pacotes as i32);
            println!(
                "  com a perda medida nesta corrida ({:.2}%), um desses quadros chega inteiro em \
                 {:.1}% das vezes",
                100.0 * p,
                100.0 * intacto
            );
        }
        // A perda da foto do usuário, para que a conta apareça mesmo numa corrida limpa. É o
        // único jeito honesto de dizer o que teria acontecido sem fingir que aconteceu aqui.
        const PERDA_DA_FOTO: f64 = 156.0 / 1815.0;
        let intacto_foto = (1.0 - PERDA_DA_FOTO).powi(pacotes as i32);
        println!(
            "  com a perda da foto de `docs/tela-preta.md` §1 ({:.1}%), chegaria inteiro em \
             {:.2}% das vezes",
            100.0 * PERDA_DA_FOTO,
            100.0 * intacto_foto
        );
        if e.quadros_com_parametros > 0 {
            let chance_nenhum = (1.0 - intacto_foto).powi(e.quadros_com_parametros as i32);
            println!(
                "  nas {} tentativas desta corrida, a chance de NENHUMA passar seria {:.1}% — e \
                 sem conjunto de parâmetros a tela fica preta para sempre, porque o emissor do \
                 Windows ignora todo pedido de IDR seguinte (§3.1)",
                e.quadros_com_parametros,
                100.0 * chance_nenhum
            );
        }
    }
    if e.quadros_com_parametros == 0 && e.quadros > 0 {
        println!();
        println!(
            "  *** NENHUM CONJUNTO DE PARÂMETROS CHEGOU EM {} QUADROS REMONTADOS ***",
            e.quadros
        );
        println!(
            "  Um decodificador não teria como começar: todo quadro seria descartado por falta"
        );
        println!(
            "  de SPS/PPS, `exibidos` ficaria em 0 e `decode p50` em 0,00 ms — que é exatamente"
        );
        println!("  a assinatura da foto em `docs/tela-preta.md` §1.");
    }
    println!();
    println!("resultado do transporte");
    // `quadros_prontos` é do núcleo e `quadros` é deste tratador. Em regime os dois têm de ser
    // iguais: `rtp.rs` incrementa `quadros_prontos` na linha anterior a `entregar(...)`, sem
    // nenhuma porteira entre um e outro. A foto de `docs/tela-preta.md` §1 mostra 168 contra 68,
    // e essa diferença não tem explicação medida — esta linha existe para que ela nunca mais
    // precise ser lida de uma fotografia.
    println!(
        "  quadros prontos   : {}  (núcleo){}",
        c.quadros_prontos,
        if c.quadros_prontos == e.quadros {
            String::new()
        } else {
            format!(
                "  *** DIFERE dos {} entregues a este tratador: {} quadro(s) sumiram entre o \
                 depacotizador e a casca ***",
                e.quadros,
                c.quadros_prontos.saturating_sub(e.quadros)
            )
        }
    );
    println!("  quadros perdidos  : {}", c.quadros_descartados);
    // O par do `idrs_sent` do emissor, e o joelho deste enlace em duas linhas. Ver
    // `docs/idr-que-sobrevive.md`: um IDR ao qual falta um pacote não conserta nada, e até
    // 31/08 nenhum receptor deste projeto contava os que quebravam.
    println!(
        "  IDR inteiros      : {}   quebrados: {}{}",
        c.idrs_prontos,
        c.idrs_quebrados,
        if c.idrs_quebrados > 0 {
            format!(
                "  *** {:.1} % dos IDR que começaram a chegar foram destruídos ***",
                100.0 * c.idrs_quebrados as f64 / (c.idrs_prontos + c.idrs_quebrados).max(1) as f64
            )
        } else {
            String::new()
        }
    );
    // O segundo número **não** é o tamanho do quadro que quebrou: é quantos pacotes dele
    // chegaram. No regime de truncamento de cauda ele é o ponto de corte do enlace. Ver
    // `quall_core::rtp::Contadores::maior_quebrado_pacotes_recebidos` e a corrida de 31/08 em que
    // a versão que estimava o tamanho mandado imprimiu 296 pacotes numa origem de 115.
    println!(
        "  maior quadro      : inteiro {} pac. · corte do maior quebrado em {} pac. recebidos",
        c.maior_quadro_pronto_pacotes, c.maior_quebrado_pacotes_recebidos
    );
    imprimir_cortes(&c);
    println!(
        "  anomalias de seq  : {}  (perda, repetição ou fora de ordem)",
        c.pacotes_perdidos()
    );
    println!(
        "  pacotes faltando  : {}{}",
        c.pacotes_faltando,
        if c.eventos_fora_de_ordem == 0 {
            "  (perda exata: ninguém reordenou)"
        } else {
            "  (TETO: houve reordenação, e ela infla este número)"
        }
    );
    println!(
        "  fora de ordem     : {} evento(s)",
        c.eventos_fora_de_ordem
    );
    // A janela observada, e por que ela precisa estar aqui: o primeiro pacote visto fixa a linha
    // de base, e o que caiu antes dele não aparece em contador nenhum.
    // **A perda exata, ao lado do teto.** `pacotes_faltando` compara cada pacote só com o
    // anterior e cobra a distância de qualquer reordenação; este número só cobra a posição que
    // saiu da janela sem nunca ter chegado. A diferença entre os dois é o que reorganizou a
    // leitura da matriz de perda desta bancada em 29/08.
    println!(
        "  PERDA EXATA       : {}  (posições que nunca chegaram; tarde demais: {})",
        c.pacotes_perdidos_de_verdade, c.pacotes_tarde_demais
    );
    if c.pacotes_vistos > 0 {
        println!(
            "  perda exata       : {:.3}% contra {:.2}% do teto `pacotes_faltando`",
            100.0 * c.pacotes_perdidos_de_verdade as f64
                / (c.pacotes_vistos + c.pacotes_perdidos_de_verdade) as f64,
            100.0 * c.pacotes_faltando as f64 / (c.pacotes_vistos + c.pacotes_faltando) as f64,
        );
    }
    if c.pacotes_vistos == 0 {
        println!("  pacotes vistos    : 0  — nenhum pacote de mídia chegou; nada a afirmar");
    } else {
        let janela = c.pacotes_vistos + c.pacotes_faltando;
        println!(
            "  pacotes vistos    : {}  ({:.2}% de perda na janela observada; o que caiu antes \
             do 1º pacote não é contável)",
            c.pacotes_vistos,
            100.0 * c.pacotes_faltando as f64 / janela as f64
        );
    }
    if c.rtcp_ignorados > 0 {
        println!(
            "  ATENÇÃO: {} pacote(s) RTCP chegaram pelo caminho do RTP. A track está sem a",
            c.rtcp_ignorados
        );
        println!("           sessão de RTCP encadeada, ou o filtro da libdatachannel mudou.");
    }
    println!("  pedidos de IDR    : {}", track.pedidos_de_idr());
    match e.primeiro_idr_us {
        Some(us) => println!(
            "  primeira imagem   : {:.1} ms depois de entrar na sessão",
            us as f64 / 1000.0
        ),
        None => println!("  primeira imagem   : NUNCA — nenhum IDR chegou"),
    }
    if let Some(us) = e.recuperacao_us {
        println!(
            "  recuperação       : {:.1} ms do pedido de IDR ao IDR",
            us as f64 / 1000.0
        );
    }
    println!();
    println!("confira com:");
    println!(
        "  ffprobe -v error -show_streams -count_frames {}",
        saida.display()
    );

    if e.quadros == 0 {
        return Err(Error::Timeout(
            "nenhum quadro atravessou a track; o arquivo está vazio".into(),
        ));
    }
    drop(e);

    pronto.link.close("recepção concluída");
    drop(pronto);
    quall_core::transport::cleanup();
    Ok(())
}

/// A track de vídeo e, se vier, a de som, na ordem que a oferta trouxer. Depois do vídeo, a de som
/// tem 3 s para chegar.
pub(crate) fn esperar_video_e_som(
    pronto: &mut Ready,
) -> Result<(quall_core::track::TrackReceptor, Option<quall_core::track::TrackReceptor>)> {
    let mut video = None;
    let mut som = None;
    let fim = Instant::now() + Duration::from_secs(20);
    loop {
        let agora = Instant::now();
        let limite = match video {
            Some(_) => (agora + Duration::from_secs(3)).min(fim),
            None => fim,
        };
        if agora >= limite || (video.is_some() && som.is_some()) {
            break;
        }
        let Some(t) = pronto.session.proxima_track(limite - agora) else {
            break;
        };
        match t.kind() {
            TrackKind::Screen | TrackKind::Camera if video.is_none() => video = Some(t),
            TrackKind::SystemAudio | TrackKind::Microphone if som.is_none() => som = Some(t),
            k => println!("  (ignorando track de {k:?} [{}])", t.mid()),
        }
    }
    match video {
        Some(v) => Ok((v, som)),
        None => Err(Error::Timeout("nenhuma track de vídeo chegou em 20 s".into())),
    }
}

/// Uma linha do relógio comum de uma track, para a linha RELOGIO.
fn linha_do_relogio(r: Option<RetratoDoRelogio>) -> String {
    let Some(r) = r else {
        return "sem pacote".into();
    };
    let (status, desloc) = match r.deslocamento {
        DeslocamentoDeCaptura::Ainda => ("ainda".to_string(), "-".to_string()),
        DeslocamentoDeCaptura::Valido { us } => ("valido".to_string(), us.to_string()),
        DeslocamentoDeCaptura::Recusado { motivo } => (format!("RECUSADO({motivo})"), "-".to_string()),
    };
    let op = |v: Option<i64>| v.map(|x| x.to_string()).unwrap_or_else(|| "-".into());
    format!(
        "ref={} status={status} desloc_us={desloc} residuo_us={} janela_us={} deriva_ppm={} violacoes={}",
        r.referencia,
        op(r.residuo_us),
        op(r.residuo_da_janela_us),
        r.deriva_entre_tracks_ppm
            .map(|x| format!("{x:.1}"))
            .unwrap_or_else(|| "-".into()),
        r.violacoes_da_guarda,
    )
}

/// Percentil de uma amostra, por interpolação de posição. `None` para amostra vazia.
///
/// Existe aqui, e simples, porque a única pergunta que ele responde nesta sonda é "quanto tempo a
/// imagem ficou quebrada" — e um p50 ao lado de um p95 já separa "quase sempre rápido" de "às
/// vezes eterno", que é a distinção que decide um piso entre recriações.
fn percentil(amostra: &[f64], q: f64) -> Option<f64> {
    if amostra.is_empty() {
        return None;
    }
    let mut v = amostra.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let pos = q * (v.len() - 1) as f64;
    let baixo = pos.floor() as usize;
    let alto = pos.ceil() as usize;
    if baixo == alto {
        Some(v[baixo])
    } else {
        Some(v[baixo] + (v[alto] - v[baixo]) * (pos - baixo as f64))
    }
}

/// O histograma dos pontos de corte, que é o que separa **truncamento por fila** de **rajada
/// cega** — a distinção que `docs/bancada.md` §8.24 deixou aberta por não ter este contador.
///
/// Se os cortes se agruparem numa faixa, a rajada é causada pelo quadro grande e o conserto é
/// encolher o quadro. Se estiverem espalhados, ela atinge o quadro por acaso e o conserto é de
/// transporte. Só imprime quando houve quadro abortado: linha de zeros é ruído.
fn imprimir_cortes(c: &quall_core::rtp::Contadores) {
    faixas("cortes por faixa  ", &c.cortes_por_faixa, "quadro(s) abortado(s)");
    // **O de IDR é o que decide**, e o outro sozinho engana: quadro P pequeno morto enche as
    // faixas baixas e imita truncamento. Ver `Contadores::cortes_de_idr_por_faixa`.
    faixas("cortes de IDR     ", &c.cortes_de_idr_por_faixa, "IDR truncado(s)");
}

fn faixas(rotulo: &str, hist: &[u32], oque: &str) {
    let total: u32 = hist.iter().sum();
    if total == 0 {
        return;
    }
    let largura = quall_core::rtp::LARGURA_DA_FAIXA_DE_CORTE;
    let ultima = quall_core::rtp::FAIXAS_DE_CORTE - 1;
    let pico = hist.iter().copied().max().unwrap_or(1).max(1);
    println!("  {rotulo}: {total} {oque}, em pacotes recebidos");
    for (i, &n) in hist.iter().enumerate() {
        if n == 0 {
            continue;
        }
        let rotulo = if i == ultima {
            format!("{:>4}+   ", ultima as u32 * largura)
        } else {
            format!(
                "{:>4}–{:<3}",
                i as u32 * largura,
                (i as u32 + 1) * largura - 1
            )
        };
        // Barra proporcional ao pico, para a forma saltar aos olhos sem ninguém somar coluna.
        let barra = "█".repeat(((n * 24).div_ceil(pico)).max(1) as usize);
        println!("      {rotulo} {n:>4}  {barra}");
    }
}

#[cfg(test)]
mod testes_dos_controles {
    //! Os controles 3, 4 e 5 do §9.3 (`docs/som-no-receptor.md`), que a S7 acrescentou à sonda.
    use super::*;

    const Q: u64 = 20_000;

    #[test]
    fn a_perda_comeca_depois_da_ancoragem_e_pega_um_de_cada_n() {
        let c = ControlesDoSom { perder_a_cada: 10, ..Default::default() };
        let perdidos: Vec<u64> = (0..400).filter(|&k| c.perde(k)).collect();
        assert_eq!(perdidos.first(), Some(&250));
        assert_eq!(perdidos.len(), 15, "{perdidos:?}");
        assert!(perdidos.windows(2).all(|w| w[1] - w[0] == 10));
        let sem = ControlesDoSom::default();
        assert!((0..10_000).all(|k| !sem.perde(k)));
        // A carga da perda passa do teto da porta puxada por um byte, e é isso que a faz cair.
        assert_eq!(CARGA_DA_PERDA, quall_core::reproducao::TAMANHO_MAXIMO_DO_PACOTE + 1);
    }

    #[test]
    fn a_travada_segura_os_quadros_e_solta_de_uma_vez_com_o_carimbo_intacto() {
        let c = ControlesDoSom { travar: Some((12_000_000, 12_150_000)), ..Default::default() };
        // O quadro de 11,98 s sai na hora; os de 12,00 a 12,14 s saem juntos aos 12,15 s.
        assert_eq!(c.envio_us(599, Q, 1.0), 11_980_000);
        let travados: Vec<u64> = (0..1000).filter(|&k| c.travado(k, Q, 1.0)).collect();
        assert_eq!(travados, (600..608).collect::<Vec<_>>());
        for k in 600..608 {
            assert_eq!(c.envio_us(k, Q, 1.0), 12_150_000);
        }
        assert_eq!(c.envio_us(608, Q, 1.0), 12_160_000);
        // O envio nunca anda para trás: a rajada sai na ordem.
        let envios: Vec<u64> = (0..1000).map(|k| c.envio_us(k, Q, 1.0)).collect();
        assert!(envios.windows(2).all(|w| w[1] >= w[0]));
        // Somada ao atraso do controle 2, a janela é a do envio, e não a do carimbo.
        let c2 = ControlesDoSom { atraso_us: 30_000, ..c };
        assert_eq!(c2.envio_us(598, Q, 1.0), 11_990_000);
        assert!(c2.travado(599, Q, 1.0) && !c2.travado(606, Q, 1.0));
    }

    #[test]
    fn a_origem_poe_a_volta_do_som_no_instante_pedido() {
        // Opus, 48 kHz, a volta aos 15 s: o quadro 749 tem o último carimbo antes da volta e o
        // 750 tem o primeiro depois dela, contado pelo mesmo `micros_para_carimbo_em` do núcleo.
        let origem = origem_perto_da_volta_us(48_000, 15_000_000).expect("origem");
        let carimbo = |k: u64| rtp::micros_para_carimbo_em(origem + k * Q, 48_000);
        assert!(carimbo(749) > u32::MAX - 960, "{}", carimbo(749));
        assert!(carimbo(750) < 960, "{}", carimbo(750));
        assert_eq!(carimbo(750).wrapping_sub(carimbo(749)), 960);
        // PCMU, 8 kHz: a mesma conta, com a volta 6 vezes mais longe.
        let origem = origem_perto_da_volta_us(8_000, 15_020_000).expect("origem");
        let carimbo = |k: u64| rtp::micros_para_carimbo_em(origem + k * Q, 8_000);
        assert!(carimbo(750) > u32::MAX - 160 && carimbo(751) < 160);
        // Pedir mais que a própria volta é recusado.
        assert!(origem_perto_da_volta_us(48_000, 90_000_000_000).is_none());
    }
}
