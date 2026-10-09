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
/// PCM real da fonte, recortado pelo início da parte sem fabricar silêncio.
fn alinhar_som(q: &Som, captura: i64, zero: i64) -> Option<(i64, &[i16])> {
    let mut pts = captura.saturating_sub(zero);
    let quadros = q.pcm.len() / 2;
    let mut pcm = &q.pcm[..quadros * 2];
    if pts < 0 {
        // Arredonda para cima: deixar -1 µs depois do corte descartava o bloco inteiro.
        let pular = pts
            .unsigned_abs()
            .saturating_mul(48_000)
            .saturating_add(999_999)
            / 1_000_000;
        let pular = usize::try_from(pular).unwrap_or(usize::MAX).min(quadros);
        pcm = &pcm[pular * 2..];
        pts = pts.saturating_add(pular as i64 * 1_000_000 / 48_000);
    }
    (!pcm.is_empty() && pts >= 0).then_some((pts, pcm))
}
fn pcm_no_zero_do_idr(q: &Som, offset: i64, zero: i64) -> bool {
    alinhar_som(q, q.carimbo.saturating_add(offset), zero).is_some_and(|(pts, _)| pts <= 20)
}
fn quadros_antes_do_corte(captura: i64, corte: i64, quadros: usize) -> usize {
    let antes = (corte.saturating_sub(captura).max(0) as u64)
        .saturating_mul(48_000)
        .saturating_add(999_999)
        / 1_000_000;
    usize::try_from(antes).unwrap_or(usize::MAX).min(quadros)
}
fn guardar_som(fila: &mut std::collections::VecDeque<Som>, q: Som) {
    if fila.len() == 64 {
        fila.pop_front();
    }
    fila.push_back(q);
}
fn drenar_som(canal: &Receiver<Som>, fila: &mut std::collections::VecDeque<Som>) {
    while let Ok(q) = canal.try_recv() {
        guardar_som(fila, q);
    }
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
                let resultado = correr(&pasta, &porta_thread, &te, &tp, vrx, srx);
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
    quadros_pcm: u64,
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
                    quadros_pcm: 0,
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
        let Some((pts, pcm)) = alinhar_som(&q, capture, self.zero) else {
            return Ok(());
        };
        if pts < self.ultimo_som {
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
        self.quadros_pcm += (pcm.len() / 2) as u64;
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
    if w.som.is_some() && w.quadros_pcm == 0 {
        // Nunca anuncia como salvo um MP4 com faixa AAC vazia. Este é apenas o
        // arquivo temporário criado pelo escritor atual; gravações anteriores ficam intactas.
        let arquivo = w.arquivo.clone();
        drop(w);
        let _ = std::fs::remove_file(arquivo);
        return Err(t("Não deu para iniciar a gravação do som.").into());
    }
    let arquivo = w.fechar_ate(fim)?;
    registro::linha("receptor: MP4 recebido finalizado");
    estado
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .arquivos
        .push(arquivo);
    Ok(())
}
fn som_antes_do_corte(
    w: &mut Escritor,
    fila: &mut std::collections::VecDeque<Som>,
    offset: i64,
    corte: i64,
) -> Result<(), String> {
    if w.som.is_none() || offset == SEM_RELOGIO {
        return Ok(());
    }
    let mut resto = std::collections::VecDeque::new();
    while let Some(q) = fila.pop_front() {
        let captura = q.carimbo.saturating_add(offset);
        if captura >= corte {
            resto.push_back(q);
            continue;
        }
        let quadros = q.pcm.len() / 2;
        let antes = quadros_antes_do_corte(captura, corte, quadros);
        if antes > 0 {
            w.som(
                Som {
                    pcm: q.pcm[..antes * 2].to_vec(),
                    carimbo: q.carimbo,
                },
                captura,
            )?;
        }
        if antes < quadros {
            resto.push_back(Som {
                pcm: q.pcm[antes * 2..quadros * 2].to_vec(),
                carimbo: q.carimbo.saturating_add(antes as i64 * 1_000_000 / 48_000),
            });
        }
    }
    *fila = resto;
    Ok(())
}
fn correr(
    pasta: &Path,
    porta: &Porta,
    estado: &Mutex<Estado>,
    parar: &AtomicBool,
    video: Receiver<Video>,
    som: Receiver<Som>,
) -> Result<(), String> {
    for linha in gravador_local::recuperar_pendentes(pasta) {
        registro::linha(linha);
    }
    let mut guarda = crate::guardia_da_gravacao::Guardia::default();
    let mut escritor: Option<Escritor> = None;
    let mut parte = 0;
    let mut som_pendente: std::collections::VecDeque<Som> = std::collections::VecDeque::new();
    let mut idr_pedido_para_som = false;
    let mut aguardando_desde = Instant::now();
    let mut conferir = Instant::now();
    let resultado = (|| -> Result<(), String> {
        loop {
            drenar_som(&som, &mut som_pendente);
            let off_som = porta.som_offset.load(Ordering::Acquire);
            let pcm_pronto = porta.som_presente.load(Ordering::Acquire)
                && off_som != SEM_RELOGIO
                && som_pendente.iter().any(|q| q.pcm.len() >= 2);
            if pcm_pronto && escritor.as_ref().is_some_and(|w| w.som.is_none()) {
                // O anúncio de microfone não é PCM. Uma faixa AAC vazia faz o leitor nativo
                // rejeitar o MP4. A parte só vídeo segue até o IDR que abre a parte com PCM.
                if !idr_pedido_para_som {
                    idr_pedido_para_som = true;
                    porta.pedir_idr.store(true, Ordering::Release);
                }
            } else if off_som != SEM_RELOGIO {
                if let Some(w) = escritor.as_mut().filter(|w| w.som.is_some()) {
                    // Um bloco à frente do vídeo pode pertencer à próxima resolução/parte.
                    // Tela estática libera a fila após 100 ms, por SendStreamTick, sem esperar
                    // outro quadro. Stop drena o que resta, preservando a fila limitada.
                    while som_pendente.front().is_some_and(|q| {
                        parar.load(Ordering::Acquire)
                            || w.ultimo_quadro_em.elapsed() >= Duration::from_millis(100)
                            || w.pendente
                                .as_ref()
                                .is_some_and(|v| q.carimbo.saturating_add(off_som) <= v.carimbo)
                    }) {
                        let q = som_pendente.pop_front().unwrap();
                        let captura = q.carimbo.saturating_add(off_som);
                        w.som(q, captura)?;
                    }
                }
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
                    let mut nova_parte = false;
                    let mut primeiro_som = None;
                    // Mesmo se select! escolheu vídeo primeiro, este IDR deve enxergar o PCM
                    // já enfileirado. Não gasta o único IDR da chegada tardia na parte sem AAC.
                    drenar_som(&som, &mut som_pendente);
                    let off_som = porta.som_offset.load(Ordering::Acquire);
                    if !guarda.aceitar(&q.bytes) { porta.pedir_idr.store(true,Ordering::Release); continue; }
                    let ps = parametros(&q.bytes);
                    let muda_formato = escritor.as_ref().zip(ps.as_ref()).is_some_and(|(w,p)|w.ps != *p);
                    if muda_formato && !q.idr { guarda.romper(); porta.pedir_idr.store(true, Ordering::Release); continue; }
                    let pode_ter_som = porta.som_presente.load(Ordering::Acquire) && off_som != SEM_RELOGIO;
                    let pretende_abrir_aac = q.idr && pode_ter_som && (escritor.is_none()
                        || muda_formato || (escritor.as_ref().is_some_and(|w|w.som.is_none())
                            && som_pendente.iter().any(|s|s.pcm.len() >= 2)));
                    if pretende_abrir_aac {
                        // O tocador pode entregar PCM depois do IDR. Espera limitada nesta
                        // thread de disco; callbacks continuam usando suas filas limitadas.
                        let prazo = Instant::now() + Duration::from_millis(100);
                        while !som_pendente.iter().any(|s|pcm_no_zero_do_idr(s,off_som,captura))
                            && !parar.load(Ordering::Acquire) && Instant::now() < prazo {
                            if let Ok(s) = som.recv_timeout(Duration::from_millis(5)) {
                                guardar_som(&mut som_pendente, s);
                            }
                        }
                    }
                    let pcm_no_idr = pode_ter_som && som_pendente.iter().any(|s|pcm_no_zero_do_idr(s,off_som,captura));
                    let adota_som = q.idr && pcm_no_idr && escritor.as_ref().is_some_and(|w|w.som.is_none());
                    // Só um escritor: a parte anterior termina nesta thread antes de abrir outra.
                    // Disco lento não cria uma fila de muxers/finalizações; só descarta nas filas limitadas.
                    if muda_formato || adota_som {
                        if let Some(w) = escritor.as_mut() { som_antes_do_corte(w,&mut som_pendente,off_som,captura)?; }
                        salvar(escritor.take().unwrap(), estado)?;
                        aguardando_desde = Instant::now();
                    }
                    if q.idr && pode_ter_som && (escritor.is_none() || escritor.as_ref().is_some_and(|w|w.som.is_none())) {
                        // PCM anterior não cabe na parte cujo vídeo começa neste IDR. Libera
                        // outro pedido quando PCM novo chegar; não repete pelo mesmo bloco velho.
                        som_pendente.retain(|s|alinhar_som(s,s.carimbo.saturating_add(off_som),captura).is_some());
                        idr_pedido_para_som = false;
                    }
                    if escritor.is_none() {
                        if !q.idr { continue; } let Some(ps) = ps else { continue }; parte += 1;
                        if pode_ter_som {
                            if let Some(i) = som_pendente.iter().position(|s|pcm_no_zero_do_idr(s,off_som,captura)) {
                                primeiro_som = som_pendente.remove(i);
                            }
                        }
                        let com_som = primeiro_som.is_some();
                        // FMPEG4 rebaseia o primeiro sample de cada track. Ambas precisam
                        // começar no IDR: PCM futuro não é adiantado artificialmente para zero.
                        escritor = Some(Escritor::abrir(pasta,ps,captura,com_som,parte)?);
                        nova_parte = true;
                        idr_pedido_para_som = false;
                        let mut e = estado.lock().unwrap_or_else(|e|e.into_inner()); e.desde.get_or_insert_with(Instant::now); e.linha = t("Gravando o vídeo e o som recebidos.").into();
                    }
                    let w = escritor.as_mut().unwrap(); if w.espera_idr && !q.idr { continue; } if q.idr { w.espera_idr=false; }
                    w.video(q,captura)?;
                    // A mesma snapshot que escolheu AAC/zero deve escrever o primeiro PCM.
                    let off = if nova_parte { off_som } else { porta.som_offset.load(Ordering::Acquire) };
                    if off != SEM_RELOGIO && w.som.is_some() {
                        if let Some(s) = primeiro_som {
                            let captura = s.carimbo.saturating_add(off);
                            w.som(s, captura)?;
                        }
                        while som_pendente.front().is_some_and(|s| nova_parte
                            || parar.load(Ordering::Acquire)
                            || s.carimbo.saturating_add(off) <= captura) {
                            let s = som_pendente.pop_front().unwrap();
                            let captura = s.carimbo.saturating_add(off);
                            w.som(s, captura)?;
                        }
                        if nova_parte && w.quadros_pcm == 0 {
                            return Err(t("Não deu para iniciar a gravação do som.").into());
                        }
                    }
                },
                recv(som) -> q => if let Ok(q) = q {
                    guardar_som(&mut som_pendente, q);
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
    fn pcm_que_atravessa_o_zero_e_cortado_sem_descartar_o_bloco() {
        let q = Som {
            pcm: vec![1; 1920],
            carimbo: -1,
        };
        let (pts, pcm) = alinhar_som(&q, q.carimbo, 0).unwrap();
        assert_eq!(pts, 19);
        assert_eq!(pcm.len(), 1918);
        assert!(alinhar_som(&q, -20_001, 0).is_none());
        assert!(alinhar_som(
            &Som {
                pcm: vec![1],
                carimbo: 0
            },
            0,
            0
        )
        .is_none());
        assert!(pcm_no_zero_do_idr(&q, 0, 0));
        assert!(!pcm_no_zero_do_idr(&q, 22, 0));
        assert!(!pcm_no_zero_do_idr(&q, 0, 30_000));
    }
    #[test]
    fn corte_fracionario_preserva_a_ultima_amostra_estereo() {
        let q = Som {
            pcm: vec![1; 641 * 2],
            carimbo: 0,
        };
        let corte = 13_333;
        let (_, original) = alinhar_som(&q, 0, corte).unwrap();
        let antes = quadros_antes_do_corte(0, corte, 641);
        assert_eq!(antes, 640);
        let resto = Som {
            pcm: q.pcm[antes * 2..].to_vec(),
            carimbo: antes as i64 * 1_000_000 / 48_000,
        };
        let (pts, pcm) = alinhar_som(&resto, resto.carimbo, corte).unwrap();
        assert_eq!(pts, 0);
        assert_eq!(pcm.len(), original.len());
        assert_eq!(pcm.len(), 2);
    }
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
    #[ignore = "Bancada MF: anúncio sem PCM, relógio ausente e blocos curtos; somente mídia sintética"]
    fn aac_so_existe_com_pcm_real_e_partes_curtas_sao_legiveis() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-pcm-real-{}", std::process::id()));
        for (nome, offset, tem_pcm, pcm_us, video_us) in [
            ("SEM_PCM", Some(0), false, 0, 0),
            ("PCM_SEM_RELOGIO", None, true, 0, 0),
            ("UM_PCM_E_STOP", Some(0), true, 0, 0),
            ("PCM_ANTERIOR_AO_IDR", Some(0), true, 0, 500_000),
            ("PCM_FUTURO_AO_IDR", Some(0), true, 500_000, 0),
        ] {
            let porta = Porta::nova();
            porta.relogios(Some(0), offset);
            let g = Gravador::iniciar_na_pasta(Arc::clone(&porta), true, pasta.join(nome)).unwrap();
            if tem_pcm {
                porta.som(&vec![0.125; 960 * 2], pcm_us);
            }
            porta.video(quadros()[0], video_us, true);
            std::thread::sleep(Duration::from_millis(40));
            let resultado = g.finalizar();
            assert!(!resultado.erro, "{nome}: {}", resultado.linha);
            assert_eq!(resultado.arquivos.len(), 1, "{nome}");
            println!("PCM_REAL_{nome}={}", resultado.arquivos[0].display());
        }
        // O mesmo bloco atravessando o zero do vídeo tem PCM restante, inclusive quando
        // o deslocamento não é um múltiplo exato de uma amostra de 48 kHz.
        let corte = pasta.join("CORTE_PARCIAL");
        std::fs::create_dir_all(&corte).unwrap();
        let primeiro = quadros()[0];
        let mut w =
            Escritor::abrir(&corte, parametros(primeiro).unwrap(), 13_001, true, 1).unwrap();
        w.video(
            Video {
                bytes: primeiro.to_vec(),
                carimbo: 13_001,
                idr: true,
            },
            13_001,
        )
        .unwrap();
        w.som(
            Som {
                pcm: vec![4096; 960 * 2],
                carimbo: 0,
            },
            0,
        )
        .unwrap();
        assert!(w.quadros_pcm > 0);
        println!("PCM_REAL_CORTE_PARCIAL={}", w.fechar().unwrap().display());
        let minimo = pasta.join("UM_QUADRO_PCM");
        std::fs::create_dir_all(&minimo).unwrap();
        let mut w =
            Escritor::abrir(&minimo, parametros(primeiro).unwrap(), 19_979, true, 1).unwrap();
        w.video(
            Video {
                bytes: primeiro.to_vec(),
                carimbo: 19_979,
                idr: true,
            },
            19_979,
        )
        .unwrap();
        w.som(
            Som {
                pcm: vec![4096; 960 * 2],
                carimbo: 0,
            },
            0,
        )
        .unwrap();
        assert_eq!(w.quadros_pcm, 1);
        println!("PCM_REAL_UM_QUADRO_PCM={}", w.fechar().unwrap().display());
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada MF: IDR antes do PCM e fila fora de ordem; somente mídia sintética"]
    fn idr_aguarda_pcm_alinhado_e_escreve_o_inicio_antes_do_futuro() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta = std::env::temp_dir().join(format!(
            "Quall-receptor-pcm-apos-idr-{}",
            std::process::id()
        ));
        for futuro in [false, true] {
            let porta = Porta::nova();
            porta.relogios(Some(0), Some(0));
            let g = Gravador::iniciar_na_pasta(
                Arc::clone(&porta),
                true,
                pasta.join(futuro.to_string()),
            )
            .unwrap();
            if futuro {
                porta.som(&vec![0.125; 960 * 2], 500_000);
            }
            porta.video(quadros()[0], 0, true);
            std::thread::sleep(Duration::from_millis(30));
            porta.som(&vec![0.125; 960 * 2], 0);
            std::thread::sleep(Duration::from_millis(40));
            let resultado = g.finalizar();
            assert!(!resultado.erro, "{}", resultado.linha);
            assert_eq!(resultado.arquivos.len(), 1);
            println!(
                "PCM_APOS_IDR_30MS_FUTURO_{futuro}={}",
                resultado.arquivos[0].display()
            );
        }
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada MF: o relógio de áudio chega depois do PCM; somente mídia sintética"]
    fn pcm_aguarda_relogio_e_antecede_video_sem_impedir_nova_parte() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta = std::env::temp_dir().join(format!(
            "Quall-receptor-relogio-tardio-{}",
            std::process::id()
        ));
        let porta = Porta::nova();
        porta.relogios(Some(0), None);
        let g = Gravador::iniciar_na_pasta(Arc::clone(&porta), true, pasta).unwrap();
        porta.som(&vec![0.125; 960 * 2], 0);
        porta.video(quadros()[0], 0, true);
        std::thread::sleep(Duration::from_millis(40));
        porta.relogios(Some(0), Some(0));
        std::thread::sleep(Duration::from_millis(40));
        let _ = porta.tirar_pedido_idr();
        porta.video(quadros()[30], 1_000_000, true);
        std::thread::sleep(Duration::from_millis(40));
        // O bloco antigo não cabe no novo zero. PCM novo deve poder pedir outro IDR.
        porta.som(&vec![0.125; 960 * 2], 1_999_999);
        let prazo = Instant::now() + Duration::from_secs(2);
        loop {
            if porta.tirar_pedido_idr() {
                break;
            }
            assert!(
                Instant::now() < prazo,
                "PCM novo deve liberar outro pedido de IDR"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        porta.video(quadros()[0], 2_000_000, true);
        std::thread::sleep(Duration::from_millis(40));
        let resultado = g.finalizar();
        assert!(!resultado.erro, "{}", resultado.linha);
        assert_eq!(resultado.arquivos.len(), 2);
        for (i, p) in resultado.arquivos.iter().enumerate() {
            println!("RELOGIO_TARDIO_PARTE{}={}", i + 1, p.display());
        }
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
    }
    #[test]
    #[ignore = "Bancada MF: vídeo primeiro, PCM tardio e resposta ao pedido de IDR; somente mídia sintética"]
    fn video_primeiro_pcm_tardio_e_idr_respondido_gravam_som() {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        }
        let pasta =
            std::env::temp_dir().join(format!("Quall-receptor-idr-som-{}", std::process::id()));
        let porta = Porta::nova();
        porta.relogios(Some(0), Some(0));
        let g = Gravador::iniciar_na_pasta(Arc::clone(&porta), true, pasta).unwrap();
        porta.video(quadros()[0], 0, true);
        std::thread::sleep(Duration::from_millis(40));
        let _ = porta.tirar_pedido_idr(); // pedido inicial; agora a parte só vídeo já abriu.
        porta.video(quadros()[1], 33_333, false);
        porta.som(&vec![0.125; 960 * 2], 33_333);
        let prazo = Instant::now() + Duration::from_secs(2);
        loop {
            if porta.tirar_pedido_idr() {
                break;
            }
            assert!(Instant::now() < prazo, "PCM tardio deve pedir um IDR");
            std::thread::sleep(Duration::from_millis(5));
        }
        // A fonte responde dentro do bloco PCM real; o corte conserva o fim do bloco.
        porta.video(quadros()[30], 50_000, true);
        std::thread::sleep(Duration::from_millis(40));
        let resultado = g.finalizar();
        assert!(!resultado.erro, "{}", resultado.linha);
        assert_eq!(resultado.arquivos.len(), 2);
        for (i, p) in resultado.arquivos.iter().enumerate() {
            println!("IDR_SOM_RESPONDIDO_PARTE{}={}", i + 1, p.display());
        }
        unsafe {
            MFShutdown().unwrap();
            CoUninitialize();
        }
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
            let pcm: Vec<f32> = (0..1600)
                .flat_map(|j| {
                    let valor = (((i * 1600 + j) as f64 * 440.0 * std::f64::consts::TAU / 48_000.0)
                        .sin()
                        * 0.25) as f32;
                    [valor, valor]
                })
                .collect();
            porta.som(&pcm, carimbo);
            porta.video(frame, carimbo as u64, i % 30 == 0);
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
            if i >= 30 {
                porta.som(&vec![0.125; 1600 * 2], i as i64 * 1_000_000 / 30);
            }
            porta.video(frame, i as u64 * 1_000_000 / 30, i % 30 == 0);
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
        let pcm = vec![0.125; 960 * 2];
        porta.som(&pcm, 0);
        porta.video(quadros()[0], 0, true);
        for i in 1..800 {
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
