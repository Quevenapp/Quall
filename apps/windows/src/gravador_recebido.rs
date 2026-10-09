//! Grava apenas a mídia recebida depois do clique em Gravar. H.264 de passagem e AAC do
//! PCM decodificado, antes do volume/mudo. Filas limitadas e escrita fora das threads da rede/DAC.
use crate::{
    gravador_local,
    idioma::{t, tf},
    registro, sps,
};
use crossbeam_channel::{bounded, Receiver, Sender};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicI64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use windows::{
    core::HSTRING,
    Win32::{
        Media::MediaFoundation::*,
        System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED},
    },
};

const SEM_RELOGIO: i64 = i64::MIN;
const MAX_QUADRO: usize = 16 * 1024 * 1024;
const RESERVA_DISCO: u64 = 256 * 1024 * 1024;
#[derive(Clone)]
struct Video {
    bytes: Vec<u8>,
    carimbo: i64,
    idr: bool,
}
struct Som {
    pcm: Vec<i16>,
    carimbo: i64,
}
struct Entradas {
    video: Sender<Video>,
    som: Sender<Som>,
}
/// Porta permanente da sessão. Tentar o cadeado nunca atrasa os callbacks.
#[derive(Default)]
pub struct Porta {
    entradas: Mutex<Option<Entradas>>,
    ativa: AtomicBool,
    ruptura: AtomicBool,
    pedir_idr: AtomicBool,
    video_offset: AtomicI64,
    som_offset: AtomicI64,
    som_presente: AtomicBool,
}
impl Porta {
    pub fn nova() -> Arc<Self> {
        Arc::new(Self {
            video_offset: AtomicI64::new(SEM_RELOGIO),
            som_offset: AtomicI64::new(SEM_RELOGIO),
            ..Self::default()
        })
    }
    pub fn video(&self, bytes: &[u8], carimbo: u64, idr: bool) {
        if !self.ativa.load(Ordering::Acquire) {
            return;
        }
        let Ok(e) = self.entradas.try_lock() else {
            self.perdeu_video();
            return;
        };
        if let Some(e) = e.as_ref() {
            if bytes.len() > MAX_QUADRO
                || e.video
                    .try_send(Video {
                        bytes: bytes.to_vec(),
                        carimbo: i64::try_from(carimbo).unwrap_or(i64::MAX),
                        idr,
                    })
                    .is_err()
            {
                self.perdeu_video();
            }
        }
    }
    pub fn som(&self, pcm: &[f32], carimbo: i64) {
        if !self.ativa.load(Ordering::Acquire) {
            return;
        }
        if let Ok(e) = self.entradas.try_lock() {
            if let Some(e) = e.as_ref() {
                let amostras = pcm
                    .iter()
                    .map(|x| (x.clamp(-1.0, 1.0) * 32767.0).round() as i16)
                    .collect();
                let _ = e.som.try_send(Som {
                    pcm: amostras,
                    carimbo,
                });
            }
        }
    }
    pub fn relogios(&self, video: Option<i64>, som: Option<i64>) {
        self.video_offset
            .store(video.unwrap_or(SEM_RELOGIO), Ordering::Release);
        self.som_offset
            .store(som.unwrap_or(SEM_RELOGIO), Ordering::Release);
    }
    pub fn comecar_sessao(&self) {
        self.relogios(None, None);
        self.som_presente.store(false, Ordering::Release);
    }
    pub fn habilitar_som(&self) {
        self.som_presente.store(true, Ordering::Release);
    }
    pub fn ativa(&self) -> bool {
        self.ativa.load(Ordering::Acquire)
    }
    pub fn perdeu_video(&self) {
        self.ruptura.store(true, Ordering::Release);
        self.pedir_idr.store(true, Ordering::Release);
    }
    pub fn tirar_pedido_idr(&self) -> bool {
        self.pedir_idr.swap(false, Ordering::AcqRel)
    }
}
#[derive(Clone, Debug, Default)]
pub struct Estado {
    pub ativa: bool,
    pub fechando: bool,
    pub desde: Option<Instant>,
    pub linha: String,
    pub arquivos: Vec<PathBuf>,
    pub erro: bool,
    parou_em: Option<Instant>,
}
pub struct Gravador {
    estado: Arc<Mutex<Estado>>,
    parar: Arc<AtomicBool>,
    porta: Arc<Porta>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Gravador {
    pub fn iniciar(porta: Arc<Porta>, com_som: bool) -> Result<Self, String> {
        let pasta = gravador_local::pasta_padrao()?;
        Self::iniciar_na_pasta(porta, com_som, pasta)
    }
    fn iniciar_na_pasta(porta: Arc<Porta>, com_som: bool, pasta: PathBuf) -> Result<Self, String> {
        if com_som {
            porta.habilitar_som();
        }
        std::fs::create_dir_all(&pasta)
            .map_err(|e| tf("Não deu para criar a pasta de gravações: {}", &[&e]))?;
        if gravador_local::espaco_livre(&pasta).is_some_and(|n| n < RESERVA_DISCO) {
            return Err(t("Não há espaço livre suficiente para gravar.").into());
        }
        let (vtx, vrx) = bounded(8);
        let (stx, srx) = bounded(64);
        let estado = Arc::new(Mutex::new(Estado {
            ativa: true,
            linha: t("Aguardando o primeiro quadro para gravar…").into(),
            ..Estado::default()
        }));
        let parar = Arc::new(AtomicBool::new(false));
        let te = Arc::clone(&estado);
        let tp = Arc::clone(&parar);
        let porta_thread = Arc::clone(&porta);
        let thread = std::thread::Builder::new()
            .name("gravar-recebido".into())
            .spawn(move || {
                unsafe {
                    let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                }
                let resultado = correr(&pasta, com_som, &porta_thread, &te, &tp, vrx, srx);
                porta_thread.ativa.store(false, Ordering::Release);
                if let Ok(mut e) = te.lock() {
                    e.ativa = false;
                    e.fechando = false;
                    if let Err(m) = resultado {
                        e.erro = true;
                        e.linha = tf("A gravação parou: {}", &[&m]);
                    } else if e.arquivos.is_empty() {
                        e.linha = t("Nenhum quadro chegou para gravar.").into();
                    } else {
                        e.linha = tf("Gravação salva em {}", &[&pasta.display()]);
                    }
                }
                unsafe {
                    CoUninitialize();
                }
            })
            .map_err(|e| e.to_string())?;
        *porta.entradas.lock().unwrap_or_else(|e| e.into_inner()) = Some(Entradas {
            video: vtx,
            som: stx,
        });
        porta.ruptura.store(false, Ordering::Release);
        porta.pedir_idr.store(true, Ordering::Release);
        porta.ativa.store(true, Ordering::Release);
        Ok(Self {
            estado,
            parar,
            porta,
            thread: Some(thread),
        })
    }
    pub fn finalizar(mut self) -> Estado {
        self.parar();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        self.estado()
    }
    pub fn estado(&self) -> Estado {
        self.estado
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
    pub fn parar(&self) {
        self.porta.ativa.store(false, Ordering::Release);
        self.parar.store(true, Ordering::Release);
        if let Ok(mut e) = self.estado.lock() {
            if e.ativa {
                e.fechando = true;
                e.parou_em.get_or_insert_with(Instant::now);
                e.linha = t("Salvando a gravação…").into();
            }
        }
    }
}
impl Drop for Gravador {
    fn drop(&mut self) {
        self.parar();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        *self
            .porta
            .entradas
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
    }
}

/// Parâmetros em Annex-B, preservados exatamente como vieram no fio.
fn parametros(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut limites = Vec::new();
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
        limites.push((i, i + n));
        i += n;
    }
    let mut ps = Vec::new();
    let mut sps = false;
    let mut pps = false;
    for (k, &(inicio, corpo)) in limites.iter().enumerate() {
        let fim = limites.get(k + 1).map(|x| x.0).unwrap_or(bytes.len());
        let tipo = *bytes.get(corpo)? & 31;
        if tipo == 7 || tipo == 8 {
            ps.extend_from_slice(&bytes[inicio..fim]);
            sps |= tipo == 7;
            pps |= tipo == 8;
        }
    }
    (sps && pps).then_some(ps)
}
fn par(t: &IMFMediaType, chave: &windows::core::GUID, a: u32, b: u32) -> windows::core::Result<()> {
    unsafe { t.SetUINT64(chave, (u64::from(a) << 32) | u64::from(b)) }
}
struct Escritor {
    writer: IMFSinkWriter,
    video: u32,
    som: Option<u32>,
    arquivo: PathBuf,
    ps: Vec<u8>,
    zero: i64,
    ultimo_som: i64,
    pendente: Option<Video>,
    espera_idr: bool,
    quadros: u64,
    ultima_duracao_100ns: i64,
    ultimo_quadro_em: Instant,
    lacuna_video: bool,
}
impl Escritor {
    fn abrir(
        pasta: &Path,
        ps: Vec<u8>,
        zero: i64,
        com_som: bool,
        parte: u32,
    ) -> Result<Self, String> {
        let tamanho = sps::resumir(&ps).ok_or("SPS inválido")?;
        if tamanho.largura == 0 || tamanho.altura == 0 {
            return Err("tamanho inválido".into());
        }
        let hora = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
        let nome = format!(
            "Quall-recebido-{:04}{:02}{:02}-{:02}{:02}{:02}-{:03}-{}-parte{}.gravando.mp4",
            hora.wYear,
            hora.wMonth,
            hora.wDay,
            hora.wHour,
            hora.wMinute,
            hora.wSecond,
            hora.wMilliseconds,
            std::process::id(),
            parte
        );
        let arquivo = pasta.join(nome);
        // Reserva exclusiva: nunca sobrescreve uma gravação anterior.
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&arquivo)
            .map_err(|e| e.to_string())?;
        let r = unsafe {
            (|| -> windows::core::Result<Self> {
                let mut attr = None;
                MFCreateAttributes(&mut attr, 3)?;
                let attr = attr.unwrap();
                attr.SetGUID(
                    &MF_TRANSCODE_CONTAINERTYPE,
                    &MFTranscodeContainerType_FMPEG4,
                )?;
                // O MF pode aplicar contrapressão nesta thread de disco; as filas dos callbacks
                // são limitadas e nunca esperam por ela. Não desligamos o limite interno do sink.
                let writer =
                    MFCreateSinkWriterFromURL(&HSTRING::from(arquivo.as_os_str()), None, &attr)?;
                let video_tipo = MFCreateMediaType()?;
                video_tipo.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
                video_tipo.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
                video_tipo
                    .SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
                par(
                    &video_tipo,
                    &MF_MT_FRAME_SIZE,
                    tamanho.largura,
                    tamanho.altura,
                )?;
                par(&video_tipo, &MF_MT_FRAME_RATE, 30, 1)?;
                par(&video_tipo, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)?;
                video_tipo.SetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &ps)?;
                let video = writer.AddStream(&video_tipo)?;
                writer.SetInputMediaType(video, &video_tipo, None)?;
                let som = if com_som {
                    let aac = MFCreateMediaType()?;
                    aac.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
                    aac.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC)?;
                    aac.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48_000)?;
                    aac.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2)?;
                    aac.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
                    aac.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 20_000)?;
                    aac.SetUINT32(&MF_MT_AAC_PAYLOAD_TYPE, 0)?;
                    let indice = writer.AddStream(&aac)?;
                    let pcm = MFCreateMediaType()?;
                    pcm.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
                    pcm.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM)?;
                    pcm.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48_000)?;
                    pcm.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2)?;
                    pcm.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
                    pcm.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, 4)?;
                    pcm.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192_000)?;
                    writer.SetInputMediaType(indice, &pcm, None)?;
                    Some(indice)
                } else {
                    None
                };
                writer.BeginWriting()?;
                Ok(Self {
                    writer,
                    video,
                    som,
                    arquivo: arquivo.clone(),
                    ps,
                    zero,
                    ultimo_som: -1,
                    pendente: None,
                    espera_idr: false,
                    quadros: 0,
                    ultima_duracao_100ns: 333_333,
                    ultimo_quadro_em: Instant::now(),
                    lacuna_video: false,
                })
            })()
        };
        match r {
            Ok(w) => Ok(w),
            Err(e) => {
                let _ = std::fs::remove_file(&arquivo);
                Err(e.to_string())
            }
        }
    }
    fn video(&mut self, q: Video, capture: i64) -> Result<(), String> {
        if let Some(anterior) = self.pendente.take() {
            let pts = anterior.carimbo.saturating_sub(self.zero).max(0);
            if capture <= anterior.carimbo {
                self.pendente = Some(anterior);
                return Err(t("O relógio do vídeo voltou para trás; a gravação foi salva.").into());
            }
            let dur = capture.saturating_sub(anterior.carimbo);
            let sample = amostra(
                &anterior.bytes,
                pts.saturating_mul(10),
                dur.saturating_mul(10),
                anterior.idr,
            )
            .map_err(|e| e.to_string())?;
            if self.lacuna_video {
                unsafe {
                    sample
                        .SetUINT32(&MFSampleExtension_Discontinuity, 1)
                        .map_err(|e| e.to_string())?;
                }
                self.lacuna_video = false;
            }
            unsafe {
                self.writer
                    .WriteSample(self.video, &sample)
                    .map_err(|e| e.to_string())?;
            }
            self.quadros += 1;
            // A pausa inteira pertence ao quadro anterior. Não vira a duração nominal
            // do próximo: Parar logo após voltar de uma tela parada não duplica a pausa.
            if dur <= 250_000 {
                self.ultima_duracao_100ns = dur.saturating_mul(10);
            }
        }
        self.pendente = Some(Video {
            carimbo: capture,
            ..q
        });
        self.ultimo_quadro_em = Instant::now();
        Ok(())
    }
    fn som(&mut self, q: Som, capture: i64) -> Result<(), String> {
        let Some(indice) = self.som else {
            return Ok(());
        };
        let mut pts = capture.saturating_sub(self.zero);
        let mut pcm = q.pcm.as_slice();
        if pts < 0 {
            let pular = ((-pts as u64 * 48_000 / 1_000_000) as usize).min(pcm.len() / 2);
            pcm = &pcm[pular * 2..];
            pts += pular as i64 * 1_000_000 / 48_000;
        }
        if pcm.is_empty() || pts < 0 || pts < self.ultimo_som {
            return Ok(());
        }
        let bytes = unsafe { std::slice::from_raw_parts(pcm.as_ptr() as *const u8, pcm.len() * 2) };
        let dur = (pcm.len() / 2) as i64 * 10_000_000 / 48_000;
        let sample = amostra(bytes, pts * 10, dur, false).map_err(|e| e.to_string())?;
        unsafe {
            // Tela estática: informa o intervalo ao mux sem inventar quadros. Mantém o último
            // AU pendente para dar-lhe a duração correta ao salvar e libera a fila de AAC.
            if self.pendente.is_some()
                && self.ultimo_quadro_em.elapsed() >= Duration::from_millis(100)
            {
                self.writer
                    .SendStreamTick(self.video, pts * 10 + dur)
                    .map_err(|e| e.to_string())?;
                self.lacuna_video = true;
            }
            self.writer
                .WriteSample(indice, &sample)
                .map_err(|e| e.to_string())?;
        }
        self.ultimo_som = pts + dur / 10;
        Ok(())
    }
    #[cfg(test)]
    fn fechar(self) -> Result<PathBuf, String> {
        self.fechar_ate(Instant::now())
    }
    fn fechar_ate(mut self, fim: Instant) -> Result<PathBuf, String> {
        let ultimo = if let Some(q) = self.pendente.take() {
            let pts = (q.carimbo.saturating_sub(self.zero))
                .max(0)
                .saturating_mul(10);
            // Uma tela parada pode não mandar outro AU. Conserva esse quadro até o clique
            // em Parar; o limiar evita transformar jitter normal em duração extra no fim.
            let parado = fim.saturating_duration_since(self.ultimo_quadro_em);
            let duracao = if parado >= Duration::from_millis(250) {
                self.ultima_duracao_100ns.max(
                    i64::try_from(parado.as_micros())
                        .unwrap_or(i64::MAX)
                        .saturating_mul(10),
                )
            } else {
                self.ultima_duracao_100ns
            };
            amostra(&q.bytes, pts, duracao, q.idr)
                .and_then(|s| unsafe { self.writer.WriteSample(self.video, &s) })
        } else {
            Ok(())
        };
        let finalizou = unsafe { self.writer.Finalize() };
        if let Err(e) = ultimo {
            registro::linha(format!("receptor: último quadro não escrito: {e}"));
        }
        finalizou.map_err(|e| e.to_string())?;
        drop(self.writer);
        let destino = self.arquivo.with_file_name(
            self.arquivo
                .file_name()
                .unwrap()
                .to_string_lossy()
                .replace(".gravando.mp4", ".mp4"),
        );
        match std::fs::rename(&self.arquivo, &destino) {
            Ok(()) => Ok(destino),
            Err(e) => {
                registro::linha(format!("receptor: MP4 finalizado, renomear falhou: {e}"));
                Ok(self.arquivo)
            }
        }
    }
}
fn amostra(bytes: &[u8], pts: i64, dur: i64, idr: bool) -> windows::core::Result<IMFSample> {
    unsafe {
        let buffer = MFCreateMemoryBuffer(bytes.len() as u32)?;
        let mut dados = std::ptr::null_mut();
        buffer.Lock(&mut dados, None, None)?;
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), dados, bytes.len());
        buffer.Unlock()?;
        buffer.SetCurrentLength(bytes.len() as u32)?;
        let sample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        sample.SetSampleTime(pts)?;
        sample.SetSampleDuration(dur.max(1))?;
        sample.SetUINT32(&MFSampleExtension_CleanPoint, u32::from(idr))?;
        Ok(sample)
    }
}
fn salvar(w: Escritor, estado: &Mutex<Estado>) -> Result<(), String> {
    let fim = estado
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .parou_em
        .unwrap_or_else(Instant::now);
    let arquivo = w.fechar_ate(fim)?;
    registro::linha("receptor: MP4 recebido finalizado");
    estado
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .arquivos
        .push(arquivo);
    Ok(())
}
fn correr(
    pasta: &Path,
    com_som: bool,
    porta: &Porta,
    estado: &Mutex<Estado>,
    parar: &AtomicBool,
    video: Receiver<Video>,
    som: Receiver<Som>,
) -> Result<(), String> {
    for linha in gravador_local::recuperar_pendentes(pasta) {
        registro::linha(linha);
    }
    let mut com_som = com_som;
    let mut guarda = crate::guardia_da_gravacao::Guardia::default();
    let mut escritor: Option<Escritor> = None;
    let mut parte = 0;
    let mut som_pendente: std::collections::VecDeque<Som> = std::collections::VecDeque::new();
    let mut aguardando_desde = Instant::now();
    let mut conferir = Instant::now();
    let resultado = (|| -> Result<(), String> {
        loop {
            if !com_som && porta.som_presente.load(Ordering::Acquire) {
                // Áudio tardio muda a configuração do mux, não a sessão/exibição. Fecha o
                // arquivo só vídeo antes de abrir a parte AAC, sempre a partir de outro IDR.
                com_som = true;
                if let Some(w) = escritor.take() {
                    salvar(w, estado)?;
                }
                aguardando_desde = Instant::now();
                guarda.romper();
                porta.pedir_idr.store(true, Ordering::Release);
            }
            if porta.ruptura.swap(false, Ordering::AcqRel) {
                guarda.romper();
                if let Some(w) = escritor.as_mut() {
                    w.espera_idr = true;
                }
            }
            if conferir.elapsed() >= Duration::from_secs(5) {
                conferir = Instant::now();
                if gravador_local::espaco_livre(pasta).is_some_and(|n| n < RESERVA_DISCO) {
                    return Err(t("Não há espaço livre suficiente para gravar.").into());
                }
            }
            if parar.load(Ordering::Acquire) && video.is_empty() && som.is_empty() {
                break;
            }
            if escritor.is_none() && aguardando_desde.elapsed() > Duration::from_secs(15) {
                return Err(t("Nenhum quadro chegou para gravar.").into());
            }
            crossbeam_channel::select! {
                recv(video) -> q => if let Ok(q) = q {
                    let off = porta.video_offset.load(Ordering::Acquire); if off == SEM_RELOGIO { porta.pedir_idr.store(true,Ordering::Release); continue; }
                    let captura = q.carimbo.saturating_add(off);
                    if !guarda.aceitar(&q.bytes) { porta.pedir_idr.store(true,Ordering::Release); continue; }
                    let ps = parametros(&q.bytes);
                    // Só um escritor: a parte anterior termina nesta thread antes de abrir outra.
                    // Disco lento não cria uma fila de muxers/finalizações; só descarta nas filas limitadas.
                    if let (Some(w),Some(ps)) = (escritor.as_ref(), ps.as_ref()) { if w.ps != *ps { if !q.idr { guarda.romper(); porta.pedir_idr.store(true, Ordering::Release); continue; } salvar(escritor.take().unwrap(),estado)?; } }
                    if escritor.is_none() {
                        if !q.idr { continue; } let Some(ps) = ps else { continue }; parte += 1;
                        escritor = Some(Escritor::abrir(pasta,ps,captura,com_som,parte)?);
                        let mut e = estado.lock().unwrap_or_else(|e|e.into_inner()); e.desde.get_or_insert_with(Instant::now); e.linha = t("Gravando o vídeo e o som recebidos.").into();
                    }
                    let w = escritor.as_mut().unwrap(); if w.espera_idr && !q.idr { continue; } if q.idr { w.espera_idr=false; }
                    w.video(q,captura)?;
                    let off = porta.som_offset.load(Ordering::Acquire); if off != SEM_RELOGIO { while let Some(q) = som_pendente.pop_front() { let capture=q.carimbo.saturating_add(off); w.som(q,capture)?; } }
                },
                recv(som) -> q => if let Ok(q) = q {
                    let off = porta.som_offset.load(Ordering::Acquire);
                    if let (Some(w),true) = (escritor.as_mut(),off != SEM_RELOGIO) { let capture=q.carimbo.saturating_add(off); w.som(q,capture)?; }
                    else { if som_pendente.len()==64 { som_pendente.pop_front(); } som_pendente.push_back(q); }
                },
                default(Duration::from_millis(20)) => {}
            }
        }
        Ok(())
    })();
    let fechamento = if let Some(w) = escritor {
        salvar(w, estado)
    } else {
        Ok(())
    };
    resultado.and(fechamento)
}

#[cfg(test)]
mod testes {
    use super::*;
    #[test]
    fn parametros_preservam_sps_pps_e_excluem_imagem() {
        let ps = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 4];
        let mut video = ps.to_vec();
        video.extend_from_slice(&[0, 0, 0, 1, 0x65, 9, 9]);
        assert_eq!(parametros(&video), Some(ps.to_vec()));
        assert_eq!(parametros(&[0, 0, 1, 0x65, 9]), None);
    }
    #[test]
    fn porta_inativa_nao_copia_midia_e_ruptura_pede_idr() {
        let porta = Porta::nova();
        porta.video(&[0, 0, 1, 0x65], 1, true);
        assert!(porta.entradas.lock().unwrap().is_none());
        porta.perdeu_video();
        assert!(porta.tirar_pedido_idr());
        assert!(!porta.tirar_pedido_idr());
    }
}

#[cfg(test)]
mod bancada_nativa {
    use super::*;
    // Gerado de testsrc2 por x264, 2 segundos, 160×96 a 30 fps, sem B, AUD e headers repetidos.
    const H264: &[u8] = include_bytes!("../tests/fixtures/receptor-sintetico-160x96.h264");
    fn quadros() -> Vec<&'static [u8]> {
        let marcas: Vec<usize> = H264
            .windows(5)
            .enumerate()
            .filter_map(|(i, b)| (b[0..4] == [0, 0, 0, 1] && b[4] & 31 == 9).then_some(i))
            .collect();
        marcas
            .iter()
            .enumerate()
            .map(|(i, &de)| &H264[de..marcas.get(i + 1).copied().unwrap_or(H264.len())])
            .collect()
    }
    #[test]
    fn sintaxe_da_camera_x264_e_perda_se_recuperam_no_idr() {
        let frames = quadros();
        assert_eq!(frames.len(), 60);
        let mut guarda = crate::guardia_da_gravacao::Guardia::default();
        for frame in &frames {
            assert!(guarda.aceitar(frame));
        }
        let mut guarda = crate::guardia_da_gravacao::Guardia::default();
        assert!(guarda.aceitar(frames[0]));
        assert!(!guarda.aceitar(frames[2]));
        assert!(!guarda.aceitar(frames[29]));
        assert!(guarda.aceitar(frames[30]));
        assert!(guarda.aceitar(frames[31]));
    }
    #[test]
    #[ignore = "Bancada nativa do worker: padrão sintético e pasta temporária, sem câmera/rede"]
    fn worker_para_salva_e_troca_formato_sem_parar_recepcao() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-worker-{}", std::process::id()));
        std::fs::create_dir_all(&pasta).unwrap();
        let porta = Porta::nova();
        porta.relogios(Some(0), Some(0));
        let g = Gravador::iniciar_na_pasta(Arc::clone(&porta), true, pasta).unwrap();
        let h2: &[u8] = include_bytes!("../tests/fixtures/receptor-sintetico-96x160.h264");
        let marcas: Vec<usize> = h2
            .windows(5)
            .enumerate()
            .filter_map(|(i, b)| (b[..4] == [0, 0, 0, 1] && b[4] & 31 == 9).then_some(i))
            .collect();
        let q2: Vec<&[u8]> = marcas
            .iter()
            .enumerate()
            .map(|(i, &de)| &h2[de..marcas.get(i + 1).copied().unwrap_or(h2.len())])
            .collect();
        for (i, frame) in quadros().into_iter().chain(q2).enumerate() {
            let carimbo = (i as u64 * 1_000_000 / 30) as i64;
            porta.video(frame, carimbo as u64, i % 30 == 0);
            let pcm: Vec<f32> = (0..1600)
                .flat_map(|j| {
                    let valor = (((i * 1600 + j) as f64 * 440.0 * std::f64::consts::TAU / 48_000.0)
                        .sin()
                        * 0.25) as f32;
                    [valor, valor]
                })
                .collect();
            porta.som(&pcm, carimbo);
            std::thread::sleep(Duration::from_millis(35));
        }
        let resultado = g.finalizar();
        assert!(!resultado.ativa);
        assert!(!resultado.erro, "{}", resultado.linha);
        assert_eq!(resultado.arquivos.len(), 2);
        assert!(!porta.ativa());
        for p in resultado.arquivos {
            assert!(std::fs::metadata(&p).unwrap().len() > 20_000);
            println!("WORKER_MP4={}", p.display());
        }
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada nativa: escreve somente padrão sintético na pasta temporária; executar isoladamente no Windows"]
    fn pausa_e_novo_quadro_nao_duplicam_intervalo_no_stop() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-retomada-{}", std::process::id()));
        std::fs::create_dir_all(&pasta).unwrap();
        let frames = quadros();
        let mut w = Escritor::abrir(&pasta, parametros(frames[0]).unwrap(), 0, false, 1).unwrap();
        w.video(
            Video {
                bytes: frames[0].to_vec(),
                carimbo: 0,
                idr: true,
            },
            0,
        )
        .unwrap();
        w.video(
            Video {
                bytes: frames[30].to_vec(),
                carimbo: 16_000_000,
                idr: true,
            },
            16_000_000,
        )
        .unwrap();
        let arquivo = w.fechar().unwrap();
        assert!(std::fs::metadata(&arquivo).unwrap().len() > 1_000);
        println!("RETOMADA_MP4={}", arquivo.display());
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada nativa: escreve somente padrão sintético na pasta temporária; executar isoladamente no Windows"]
    fn som_tardio_abre_parte_aac_sem_reconectar() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-som-tardio-{}", std::process::id()));
        let porta = Porta::nova();
        porta.relogios(Some(0), Some(0));
        let g = Gravador::iniciar_na_pasta(Arc::clone(&porta), false, pasta).unwrap();
        for (i, frame) in quadros().iter().enumerate() {
            if i == 29 {
                porta.habilitar_som();
            }
            porta.video(frame, i as u64 * 1_000_000 / 30, i % 30 == 0);
            if i >= 30 {
                porta.som(&vec![0.125; 1600 * 2], i as i64 * 1_000_000 / 30);
            }
            std::thread::sleep(Duration::from_millis(35));
        }
        let resultado = g.finalizar();
        assert!(!resultado.erro, "{}", resultado.linha);
        assert_eq!(resultado.arquivos.len(), 2);
        for p in resultado.arquivos {
            println!("SOM_TARDIO_MP4={}", p.display());
        }
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada nativa: escreve somente padrão sintético na pasta temporária; executar isoladamente no Windows"]
    fn tela_parada_por_mais_de_15_segundos_continua_gravando_com_som() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-parado-{}", std::process::id()));
        let porta = Porta::nova();
        porta.relogios(Some(0), Some(0));
        let g = Gravador::iniciar_na_pasta(Arc::clone(&porta), true, pasta).unwrap();
        porta.video(quadros()[0], 0, true);
        let pcm = vec![0.125; 960 * 2];
        for i in 0..800 {
            porta.som(&pcm, i * 20_000);
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(g.estado().ativa, "tela estática não encerra a gravação");
        let resultado = g.finalizar();
        assert!(!resultado.erro, "{}", resultado.linha);
        assert_eq!(resultado.arquivos.len(), 1);
        println!("ESTATICO_MP4={}", resultado.arquivos[0].display());
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada nativa: escreve somente padrão sintético na pasta temporária; executar isoladamente no Windows"]
    fn mp4_nativo_video_aac_sem_recodificar_h264() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-bancada-{}", std::process::id()));
        std::fs::create_dir_all(&pasta).unwrap();
        let frames = quadros();
        let ps = parametros(frames[0]).unwrap();
        let mut w = Escritor::abrir(&pasta, ps, 0, true, 1).unwrap();
        for (i, frame) in frames.iter().enumerate() {
            let timestamp = (i as u64 * 1_000_000 / 30) as i64;
            w.video(
                Video {
                    bytes: frame.to_vec(),
                    carimbo: timestamp,
                    idr: i % 30 == 0,
                },
                timestamp,
            )
            .unwrap();
            let pcm: Vec<i16> = (0..1600)
                .flat_map(|j| {
                    let valor = (((i * 1600 + j) as f64 * 440.0 * std::f64::consts::TAU / 48_000.0)
                        .sin()
                        * 8000.0) as i16;
                    [valor, valor]
                })
                .collect();
            w.som(
                Som {
                    pcm,
                    carimbo: timestamp,
                },
                timestamp,
            )
            .unwrap();
        }
        let arquivo = w.fechar().unwrap();
        assert!(std::fs::metadata(&arquivo).unwrap().len() > 20_000);
        println!("SYNTHETIC_MP4={}", arquivo.display());
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
}
