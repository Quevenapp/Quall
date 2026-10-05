//! Áudio na bancada: emitir e receber uma track de som pela rede, com número.
//!
//! # A origem é sintética, e isso é regra e não conveniência
//!
//! **Esta sonda nunca abre o microfone nem o áudio de sistema da máquina.** A regra do
//! `docs/regras-de-frente.md` sobre não capturar a tela do anfitrião vale igual para o som, e vale
//! com força maior: um `.wav` não carrega no nome o que tem dentro, e o precedente já existe no
//! repositório — em 2026-08-24 uma frente abriu um quadro de um `.h264` cuja origem era a tela do
//! usuário.
//!
//! O que sai daqui é [`tom_sintetico`]: quatro notas geradas por seno, deterministicamente, a
//! partir do índice do quadro. É por isso que o `.wav` gravado pode ser ouvido e anexado sem
//! pergunta nenhuma.
//!
//! # Os dois codecs, e o que cada um prova
//!
//! **Opus** é o codec do produto, e desde 2026-08-27 ele existe de verdade aqui: a libopus está
//! vendorizada em `crates/quall-opus`. É o padrão da sonda. O que ele prova é o que só ele pode
//! provar — que o `a=fmtp` não está mentindo: o **byte de TOC** de cada pacote recebido diz o
//! modo, a largura de banda e a duração do quadro, e `opus_packet_has_lbrr` diz se o FEC que o
//! `useinbandfec` promete está mesmo no fio. Ver `docs/audio.md` §11.
//!
//! **G.711 µ-law** fica como piso, e continua útil por uma razão que o Opus não pode dar: é uma
//! tabela de consulta de 8 bits, sem estado, então todo quadro de uma nota é byte a byte idêntico
//! e o `.wav` do receptor pode ser comparado com o da origem com um `cmp`. É a conferência de
//! conteúdo mais forte que existe aqui, e ela **não tem equivalente em Opus** — ver
//! [`FonteDeQuadros`] e `docs/audio.md` §12.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use quall_core::error::{Error, Result};
use quall_core::jitter::{BufferDeJitter, Entrega, Politica};
use quall_core::session::Ready;
use quall_core::track::{
    AmostraDeAudio, CodecDeAudio, PresetDeAudio, QuadroDeAudio, DURACAO_DO_QUADRO_MS,
};

// ---------------------------------------------------------------------------------------------
// O tom sintético
// ---------------------------------------------------------------------------------------------

/// As quatro notas do tom, em Hz.
///
/// Escolhidas para que **cada uma tenha um número inteiro de ciclos dentro de um quadro de 20 ms
/// a 8 kHz** (160 amostras): 8000/400 = 20 amostras por ciclo, 160/20 = 8 ciclos exatos; idem
/// para 500, 800 e 1000. Sem isso haveria um salto de fase na emenda entre quadros, que vira um
/// estalo audível a cada 20 ms — e alguém gastaria uma tarde procurando esse estalo na rede.
const NOTAS_HZ: [u32; 4] = [400, 500, 800, 1000];

/// Quantos quadros cada nota dura. 25 × 20 ms = 0,5 s por nota, 2 s por volta.
const QUADROS_POR_NOTA: u64 = 25;

/// Amplitude, em fração do fundo de escala. Longe do teto para não recortar no µ-law.
const AMPLITUDE: f64 = 0.5;

/// Gera as amostras PCM de **um** quadro, deterministicamente a partir do índice dele.
///
/// Determinístico é o ponto: o receptor regenera o mesmo quadro a partir do índice que deduz do
/// carimbo RTP e **compara byte a byte**. É o equivalente, no áudio, do
/// `quall_core::media::conferir_padrao` — verificar o que chegou, e não só cronometrá-lo.
pub fn tom_sintetico(indice_do_quadro: u64, amostras_por_quadro: usize, taxa_hz: u32) -> Vec<i16> {
    let nota = NOTAS_HZ[((indice_do_quadro / QUADROS_POR_NOTA) as usize) % NOTAS_HZ.len()];
    let amostras_por_ciclo = f64::from(taxa_hz) / f64::from(nota);
    let base = indice_do_quadro * amostras_por_quadro as u64;

    (0..amostras_por_quadro)
        .map(|i| {
            let n = base + i as u64;
            // A fase é calculada a partir do índice **absoluto** da amostra, e não reiniciada por
            // quadro: é o que mantém a onda contínua na emenda.
            let fase = 2.0 * std::f64::consts::PI * (n as f64) / amostras_por_ciclo;
            (fase.sin() * AMPLITUDE * f64::from(i16::MAX)) as i16
        })
        .collect()
}

/// Os quadros de referência das quatro notas, já codificados.
///
/// # Por que a conferência é contra esta tabela, e não contra o índice do quadro
///
/// A primeira versão desta sonda deduzia o índice do quadro do carimbo RTP e regenerava o tom
/// para ele. Deu **11 divergências em 299 quadros**, e a causa não era corrupção nenhuma: o
/// receptor perdeu o quadro 0 (dívida 25 — *"o primeiro pacote que o depacotizador vê fixa a
/// linha de base"*), então a linha do tempo dele começa no quadro 1 do emissor e todo índice sai
/// deslocado de um. As divergências caíam exatamente nas trocas de nota.
///
/// **Esse deslocamento não é recuperável do RTP.** Um número de sequência não diz nada sobre o
/// que veio antes do primeiro que se viu, e é isso que a dívida 25 documenta. Insistir em
/// alinhamento absoluto seria a sonda exigindo do protocolo uma informação que ele não carrega.
///
/// Então a conferência muda de pergunta. Em vez de *"este quadro é o índice N do tom?"*, ela
/// pergunta **"este quadro é um dos quatro quadros que eu sei gerar?"** — o que prova
/// integridade de conteúdo byte a byte — e, separadamente, **"as notas trocam a cada 25
/// quadros?"** — o que prova a estrutura temporal. As duas juntas dizem tudo o que a primeira
/// versão queria dizer, e não dependem de saber onde o fluxo começou.
///
/// Isso é possível porque cada nota tem um número inteiro de ciclos por quadro, o que faz todo
/// quadro de uma mesma nota ser byte a byte idêntico. A mesma propriedade que evita o estalo na
/// emenda dá a tabela de referência de graça.
pub fn notas_de_referencia(
    codec: CodecDeAudio,
    amostras_por_quadro: usize,
) -> Result<Vec<Vec<u8>>> {
    (0..NOTAS_HZ.len())
        .map(|n| quadro_codificado(n as u64 * QUADROS_POR_NOTA, codec, amostras_por_quadro))
        .collect()
}

/// Um quadro do tom, já codificado no codec da track.
///
/// **Só serve para o PCMU.** O Opus tem estado — ver [`FonteDeQuadros`] —, e uma função que
/// codifica "o quadro N" isoladamente não existe para ele: o quadro N depende dos anteriores.
pub fn quadro_codificado(
    indice: u64,
    codec: CodecDeAudio,
    amostras_por_quadro: usize,
) -> Result<Vec<u8>> {
    let pcm = tom_sintetico(indice, amostras_por_quadro, codec.relogio_hz());
    match codec {
        CodecDeAudio::Pcmu => Ok(pcm.into_iter().map(linear_para_ulaw).collect()),
        CodecDeAudio::Opus => Err(Error::Invalid(
            "o Opus é preditivo: não dá para codificar um quadro solto por índice. \
             Use `FonteDeQuadros`, que carrega o encoder entre os quadros."
                .into(),
        )),
    }
}

/// O tom sintético intercalado em `canais`.
///
/// O preset de áudio de sistema é estéreo, e o Opus precisa do PCM intercalado. Os dois canais
/// recebem a **mesma** onda de propósito: um estéreo de verdade exigiria uma segunda origem
/// sintética, e o que se quer provar aqui é que dois canais atravessam e voltam como dois — não
/// separação estéreo.
pub fn tom_sintetico_intercalado(
    indice_do_quadro: u64,
    amostras_por_canal: usize,
    taxa_hz: u32,
    canais: u8,
) -> Vec<i16> {
    let mono = tom_sintetico(indice_do_quadro, amostras_por_canal, taxa_hz);
    if canais <= 1 {
        return mono;
    }
    let mut v = Vec::with_capacity(mono.len() * usize::from(canais));
    for a in mono {
        for _ in 0..canais {
            v.push(a);
        }
    }
    v
}

/// A origem: gera o tom e o codifica, **carregando o estado do encoder entre os quadros**.
///
/// # Por que isto não é uma função
///
/// Porque o Opus é preditivo. No PCMU, `quadro_codificado(n)` é uma função pura — a tabela de
/// consulta de 8 bits não tem memória, e é por isso que a conferência do receptor pode ser uma
/// tabela de quatro quadros de referência. No Opus o quadro *n* depende de todos os anteriores, e
/// as duas consequências estão em `docs/audio.md` §12:
///
/// 1. não existe "quadro de referência" de uma nota para comparar byte a byte;
/// 2. **comparar bytes entre dois aparelhos não é conferência válida** — builds de ponto fixo e
///    de ponto flutuante produzem fluxos diferentes e igualmente válidos do mesmo PCM.
///
/// A conferência de um fluxo de Opus é outra: o **TOC** de cada pacote (estrutura), a energia do
/// PCM decodificado (é som), e o artefato `.opus` que um `ffprobe` de fora abre.
pub struct FonteDeQuadros {
    codec: CodecDeAudio,
    canais: u8,
    amostras_por_canal: usize,
    #[cfg(feature = "opus")]
    opus: Option<quall_opus::Codificador>,
    #[cfg(feature = "opus")]
    buf: Vec<u8>,
}

impl FonteDeQuadros {
    /// Monta a origem a partir do preset — **do preset inteiro**, e é esse o ponto.
    ///
    /// `taxa_media_bits`, `fec` e `perda_esperada_pct` saem daqui e vão para o encoder. Antes
    /// desta rodada eles iam só para o texto do `a=fmtp` e nenhum encoder os lia; era exatamente
    /// a lacuna que a §13 do `docs/audio.md` chamava de "conferidos como texto, nunca honrados".
    pub fn nova(preset: &PresetDeAudio) -> Result<Self> {
        let amostras_por_canal = preset.amostras_por_quadro();
        match preset.codec {
            CodecDeAudio::Pcmu => Ok(FonteDeQuadros {
                codec: preset.codec,
                canais: 1,
                amostras_por_canal,
                #[cfg(feature = "opus")]
                opus: None,
                #[cfg(feature = "opus")]
                buf: Vec::new(),
            }),
            #[cfg(feature = "opus")]
            CodecDeAudio::Opus => {
                use quall_opus::{Aplicacao, Codificador, Sinal};
                // **A espécie do conteúdo vem do preset, não de um palpite sobre os canais.**
                // A primeira versão disto deduzia "mono ⇒ fala" e deixava o resto com a análise
                // do Opus; medido em 2026-08-27, isso pôs o preset de microfone em CELT em 282
                // de 300 quadros — onde o LBRR não existe — com `useinbandfec=1` no SDP.
                let (aplicacao, sinal) = if preset.conteudo_e_fala {
                    (Aplicacao::Voz, Sinal::Voz)
                } else {
                    (Aplicacao::Audio, Sinal::Automatico)
                };
                let mut enc =
                    Codificador::novo(preset.codec.relogio_hz(), preset.canais, aplicacao)
                        .map_err(|e| Error::Invalid(format!("criar encoder de Opus: {e}")))?;
                enc.definir_taxa_de_bits(preset.taxa_media_bits)
                    .and_then(|_| enc.definir_fec_embutido(preset.fec))
                    .and_then(|_| enc.definir_perda_esperada(preset.perda_esperada_pct))
                    .and_then(|_| enc.definir_sinal(sinal))
                    .and_then(|_| enc.definir_dtx(false))
                    // A complexidade do produto (`complexidade_do_encoder`), como a fronteira C.
                    .and_then(|_| enc.definir_complexidade(preset.complexidade_do_encoder()))
                    .map_err(|e| Error::Invalid(format!("configurar encoder de Opus: {e}")))?;
                Ok(FonteDeQuadros {
                    codec: preset.codec,
                    canais: preset.canais,
                    amostras_por_canal,
                    opus: Some(enc),
                    // Teto generoso: um quadro de 20 ms a 128 kbit/s são ~320 bytes, e o VBR
                    // estoura isso nos primeiros quadros.
                    buf: vec![0u8; 4000],
                })
            }
            #[cfg(not(feature = "opus"))]
            CodecDeAudio::Opus => Err(Error::Invalid(
                "esta sonda foi construída sem a feature `opus`; use `--codec pcmu` ou \
                 reconstrua com `--features opus`"
                    .into(),
            )),
        }
    }

    pub fn canais(&self) -> u8 {
        self.canais
    }

    pub fn amostras_por_canal(&self) -> usize {
        self.amostras_por_canal
    }

    /// O lookahead do encoder, em amostras — o `pre-skip` do Ogg Opus.
    ///
    /// É a metade do atraso algorítmico que o `docs/audio.md` §2 contabiliza como 6,5 ms, agora
    /// dita pela libopus compilada em vez de citada da documentação.
    #[cfg(feature = "opus")]
    pub fn pre_skip(&mut self) -> u16 {
        self.opus
            .as_mut()
            .and_then(|e| e.lookahead().ok())
            .unwrap_or(0)
            .min(u32::from(u16::MAX)) as u16
    }

    /// O PCM da origem para o quadro `indice`, antes de codificar.
    pub fn pcm(&self, indice: u64) -> Vec<i16> {
        tom_sintetico_intercalado(
            indice,
            self.amostras_por_canal,
            self.codec.relogio_hz(),
            self.canais,
        )
    }

    /// O próximo quadro codificado.
    pub fn proximo(&mut self, indice: u64) -> Result<Vec<u8>> {
        self.proximo_editado(indice, |_, _, _| {})
    }

    /// O próximo quadro, com o PCM editado **antes** de codificar: `editar(pcm intercalado, canais,
    /// taxa)`. É por onde a claquete escreve o estouro (`claquete.rs`).
    pub fn proximo_editado(
        &mut self,
        indice: u64,
        editar: impl FnOnce(&mut [i16], usize, u32),
    ) -> Result<Vec<u8>> {
        let mut pcm = self.pcm(indice);
        editar(&mut pcm, usize::from(self.canais.max(1)), self.codec.relogio_hz());
        match self.codec {
            CodecDeAudio::Pcmu => Ok(pcm.into_iter().map(linear_para_ulaw).collect()),
            #[cfg(feature = "opus")]
            CodecDeAudio::Opus => {
                let enc = self
                    .opus
                    .as_mut()
                    .ok_or_else(|| Error::Invalid("encoder de Opus ausente".into()))?;
                let n = enc
                    .codificar(&pcm, &mut self.buf)
                    .map_err(|e| Error::Invalid(format!("opus_encode: {e}")))?;
                Ok(self.buf[..n].to_vec())
            }
            #[cfg(not(feature = "opus"))]
            CodecDeAudio::Opus => Err(Error::Invalid("sonda construída sem `opus`".into())),
        }
    }
}

// ---------------------------------------------------------------------------------------------
// G.711 µ-law (ITU-T G.711, RFC 3551 §4.5.14)
// ---------------------------------------------------------------------------------------------

/// Deslocamento que a G.711 soma antes de achar o expoente.
const VIES: i32 = 0x84;
/// Maior amplitude representável depois do viés.
const RECORTE: i32 = 32635;

/// PCM de 16 bits → um byte de µ-law.
///
/// O expoente sai de `leading_zeros` em vez da tabela de 256 entradas que as implementações em C
/// costumam carregar: é a mesma conta — a posição do bit mais alto de `pcm >> 7` — e cabe numa
/// linha que dá para conferir lendo.
pub fn linear_para_ulaw(amostra: i16) -> u8 {
    let mut pcm = i32::from(amostra);
    let sinal = if pcm < 0 {
        pcm = -pcm;
        0x80u8
    } else {
        0x00
    };
    if pcm > RECORTE {
        pcm = RECORTE;
    }
    pcm += VIES;

    let expoente = (31 - ((pcm >> 7) as u32).leading_zeros()).min(7) as u8;
    let mantissa = ((pcm >> (expoente + 3)) & 0x0F) as u8;
    // A G.711 transmite o complemento: é o que faz o silêncio virar 0xFF em vez de 0x00, e o
    // fluxo em repouso ficar visível num `tcpdump`.
    !(sinal | (expoente << 4) | mantissa)
}

/// Um byte de µ-law → PCM de 16 bits.
pub fn ulaw_para_linear(byte: u8) -> i16 {
    let u = !byte;
    let sinal = u & 0x80;
    let expoente = (u >> 4) & 0x07;
    let mantissa = i32::from(u & 0x0F);

    let magnitude = (((mantissa << 3) + VIES) << expoente) - VIES;
    if sinal != 0 {
        -magnitude as i16
    } else {
        magnitude as i16
    }
}

// ---------------------------------------------------------------------------------------------
// WAV
// ---------------------------------------------------------------------------------------------

/// Escreve um WAV PCM de 16 bits, mono.
///
/// PCM linear e não µ-law (formato 7) de propósito: o µ-law é o que atravessou a rede, mas o que
/// se quer do artefato é que **qualquer coisa** o abra sem discussão — `ffprobe`, `afplay`, um
/// editor. A conversão de volta é exata: o µ-law é sem perda em relação a si mesmo.
pub struct EscritorDeWav {
    arquivo: BufWriter<File>,
    /// Amostras **por canal**.
    amostras: u32,
    taxa_hz: u32,
    /// O cabeçalho do WAV declara os canais, e declarar errado é a mesma falta do M4: um arquivo
    /// estéreo com cabeçalho mono toca no dobro da velocidade e ninguém acusa.
    canais: u16,
}

impl EscritorDeWav {
    pub fn criar(caminho: &Path, taxa_hz: u32, canais: u8) -> Result<Self> {
        let arquivo = File::create(caminho).map_err(|e| {
            Error::Invalid(format!("não deu para criar {}: {e}", caminho.display()))
        })?;
        let mut w = EscritorDeWav {
            arquivo: BufWriter::new(arquivo),
            amostras: 0,
            taxa_hz,
            canais: u16::from(canais.max(1)),
        };
        // Cabeçalho com os tamanhos zerados; `finalizar` volta e os corrige.
        w.escrever_cabecalho()?;
        Ok(w)
    }

    fn escrever_cabecalho(&mut self) -> Result<()> {
        let bytes_por_quadro = u32::from(self.canais) * 2;
        let bytes_de_dados = self.amostras * bytes_por_quadro;
        let taxa_de_bytes = self.taxa_hz * bytes_por_quadro;
        let mut c = Vec::with_capacity(44);
        c.extend_from_slice(b"RIFF");
        c.extend_from_slice(&(36 + bytes_de_dados).to_le_bytes());
        c.extend_from_slice(b"WAVE");
        c.extend_from_slice(b"fmt ");
        c.extend_from_slice(&16u32.to_le_bytes()); // tamanho do bloco fmt
        c.extend_from_slice(&1u16.to_le_bytes()); // 1 = PCM
        c.extend_from_slice(&self.canais.to_le_bytes());
        c.extend_from_slice(&self.taxa_hz.to_le_bytes());
        c.extend_from_slice(&taxa_de_bytes.to_le_bytes());
        c.extend_from_slice(&(bytes_por_quadro as u16).to_le_bytes()); // alinhamento de bloco
        c.extend_from_slice(&16u16.to_le_bytes()); // bits por amostra
        c.extend_from_slice(b"data");
        c.extend_from_slice(&bytes_de_dados.to_le_bytes());
        self.arquivo
            .write_all(&c)
            .map_err(|e| Error::Invalid(format!("escrita do cabeçalho WAV: {e}")))
    }

    /// `pcm` é intercalado; a conta de amostras é **por canal**.
    pub fn escrever(&mut self, pcm: &[i16]) -> Result<()> {
        for a in pcm {
            self.arquivo
                .write_all(&a.to_le_bytes())
                .map_err(|e| Error::Invalid(format!("escrita do WAV: {e}")))?;
        }
        self.amostras += pcm.len() as u32 / u32::from(self.canais);
        Ok(())
    }

    /// Fecha o arquivo corrigindo os dois campos de tamanho do cabeçalho.
    pub fn finalizar(mut self) -> Result<u32> {
        use std::io::Seek;
        self.arquivo
            .flush()
            .map_err(|e| Error::Invalid(format!("flush do WAV: {e}")))?;
        let mut arquivo = self
            .arquivo
            .into_inner()
            .map_err(|e| Error::Invalid(format!("fechando o WAV: {e}")))?;
        arquivo
            .rewind()
            .map_err(|e| Error::Invalid(format!("rebobinando o WAV: {e}")))?;

        let bytes_de_dados = self.amostras * u32::from(self.canais) * 2;
        arquivo
            .write_all(b"RIFF")
            .and_then(|_| arquivo.write_all(&(36 + bytes_de_dados).to_le_bytes()))
            .map_err(|e| Error::Invalid(format!("corrigindo o RIFF: {e}")))?;
        use std::io::SeekFrom;
        arquivo
            .seek(SeekFrom::Start(40))
            .and_then(|_| arquivo.write_all(&bytes_de_dados.to_le_bytes()))
            .map_err(|e| Error::Invalid(format!("corrigindo o tamanho dos dados: {e}")))?;
        Ok(self.amostras)
    }
}

// ---------------------------------------------------------------------------------------------
// A cópia da origem
// ---------------------------------------------------------------------------------------------

/// Onde a sonda grava o que ela mesma gerou, no formato que o codec permite conferir.
///
/// **O formato muda com o codec, e isso não é detalhe de conveniência.** No PCMU o `.wav` pode ser
/// comparado byte a byte com o do receptor, porque a G.711 não tem estado e o µ-law é reversível.
/// No Opus essa comparação não existiria: os payloads concatenados não são separáveis, e mesmo
/// separados não seriam comparáveis entre duas máquinas — ver `docs/audio.md` §12. Então o Opus
/// grava um `.opus` (Ogg), que carrega o enquadramento e é lido por `ffprobe`, `opusinfo` e
/// qualquer tocador.
enum Copia {
    Nada,
    Wav(EscritorDeWav),
    #[cfg(feature = "opus")]
    Ogg(Box<crate::ogg::EscritorDeOgg>),
}

impl Copia {
    fn criar(
        salvar: Option<&Path>,
        preset: &PresetDeAudio,
        _fonte: &mut FonteDeQuadros,
    ) -> Result<Copia> {
        let Some(caminho) = salvar else {
            return Ok(Copia::Nada);
        };
        match preset.codec {
            CodecDeAudio::Pcmu => Ok(Copia::Wav(EscritorDeWav::criar(
                caminho,
                preset.codec.relogio_hz(),
                1,
            )?)),
            #[cfg(feature = "opus")]
            CodecDeAudio::Opus => {
                // O pre-skip é o lookahead do encoder, em amostras a 48 kHz. Sem ele o tocador
                // reproduz o transiente de convergência do encoder como se fosse áudio.
                let pre_skip = _fonte.pre_skip();
                Ok(Copia::Ogg(Box::new(crate::ogg::EscritorDeOgg::criar(
                    caminho,
                    preset.canais,
                    pre_skip,
                    preset.codec.relogio_hz(),
                )?)))
            }
            #[cfg(not(feature = "opus"))]
            CodecDeAudio::Opus => Err(Error::Invalid("sonda construída sem `opus`".into())),
        }
    }

    fn escrever(&mut self, payload: &[u8], amostras_por_canal: u32) -> Result<()> {
        match self {
            Copia::Nada => Ok(()),
            Copia::Wav(w) => {
                let pcm: Vec<i16> = payload.iter().copied().map(ulaw_para_linear).collect();
                w.escrever(&pcm)
            }
            #[cfg(feature = "opus")]
            // O `.opus` guarda o **pacote codificado**, e não o PCM: é literalmente o que
            // atravessou (ou vai atravessar) a rede.
            Copia::Ogg(w) => w.escrever(payload, amostras_por_canal),
        }
    }

    fn finalizar(self) -> Result<Option<String>> {
        match self {
            Copia::Nada => Ok(None),
            Copia::Wav(w) => Ok(Some(format!("{} amostras gravadas", w.finalizar()?))),
            #[cfg(feature = "opus")]
            Copia::Ogg(w) => {
                let canais = w.canais();
                Ok(Some(format!(
                    "{} pacotes de Opus gravados ({canais} canal/canais)",
                    w.finalizar()?
                )))
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Emitir
// ---------------------------------------------------------------------------------------------

/// Emite o tom sintético por `duracao`, um quadro a cada [`quall_core::track::DURACAO_DO_QUADRO_MS`].
pub fn emitir(mut pronto: Ready, duracao: Duration, salvar: Option<&Path>) -> Result<()> {
    let emissor = pronto
        .tracks
        .first()
        .ok_or_else(|| Error::Invalid("a sessão subiu sem track de saída".into()))?;

    let preset = emissor
        .preset_de_audio()
        .ok_or_else(|| Error::Invalid("a track de saída não é de áudio".into()))?;
    let amostras_por_quadro = preset.amostras_por_quadro();
    let intervalo = Duration::from_millis(u64::from(preset.duracao_do_quadro_ms));

    let mut fonte = FonteDeQuadros::nova(&preset)?;

    println!();
    println!("emitindo áudio sintético");
    println!("  track          : {:?}", emissor.kind());
    println!("  codec          : {:?}", preset.codec);
    println!("  relógio        : {} Hz", preset.codec.relogio_hz());
    println!("  canais         : {}", fonte.canais());
    println!("  quadro         : {} ms", preset.duracao_do_quadro_ms);
    println!("  amostras/quadro: {amostras_por_quadro}");
    println!("  taxa alvo      : {} bit/s", preset.taxa_media_bits);
    println!(
        "  FEC embutido   : {} (perda declarada {}%)",
        preset.fec, preset.perda_esperada_pct
    );
    println!("  fmtp           : {}", preset.fmtp());
    println!("  origem         : tom sintético (nunca o microfone da máquina)");
    #[cfg(feature = "opus")]
    if preset.codec == CodecDeAudio::Opus {
        println!("  libopus        : {}", quall_opus::versao());
    }

    // Se pedirem, grava **o que foi gerado** — a origem, não a rede.
    //
    // No PCMU sai um `.wav`, que é comparável byte a byte com o do receptor. No Opus sai um
    // `.opus` (Ogg), porque payloads de Opus concatenados não são separáveis por ninguém — ver
    // `crate::ogg`.
    let mut copia = Copia::criar(salvar, &preset, &mut fonte)?;

    let total_de_quadros = duracao.as_millis() as u64 / u64::from(preset.duracao_do_quadro_ms);
    let comeco = Instant::now();
    let mut enviados = 0u64;
    let mut falhas = 0u64;
    let mut falhas_seguidas = 0u64;

    for indice in 0..total_de_quadros {
        let payload = fonte.proximo(indice)?;

        // O carimbo é o tempo **da mídia**, e não o relógio de parede: quadro `n` vale
        // `n × 20 ms` desde o começo do fluxo. É o que faz o receptor reconstruir a linha do
        // tempo mesmo quando o emissor se atrasa para dormir.
        let timestamp_us = indice * u64::from(preset.duracao_do_quadro_ms) * 1000;

        match emissor.enviar_audio(AmostraDeAudio {
            payload: &payload,
            timestamp_us,
        }) {
            Ok(()) => {
                enviados += 1;
                falhas_seguidas = 0;
                copia.escrever(&payload, fonte.amostras_por_canal() as u32)?;
            }
            Err(_) => {
                // Normal enquanto o ICE não fechou. Descarta e segue: áudio atrasado não vale
                // nada, e enfileirar seria pior que perder.
                falhas += 1;
                falhas_seguidas += 1;
                if falhas_seguidas > 50 {
                    println!("  a track parou de aceitar áudio; desistindo");
                    break;
                }
            }
        }

        // Ritmo pelo relógio absoluto, e não por soma de `sleep`: somar dorminhoco acumula o
        // atraso de cada um e o fluxo vai ficando para trás sem que nada acuse.
        let alvo = comeco + intervalo * (indice as u32 + 1);
        if let Some(espera) = alvo.checked_duration_since(Instant::now()) {
            std::thread::sleep(espera);
        }
    }

    let decorrido = comeco.elapsed();
    let bytes = emissor.bytes_enviados();

    println!();
    println!("resultado do emissor");
    println!("  quadros enviados : {enviados}");
    println!("  falhas de envio  : {falhas}");
    println!("  bytes de mídia   : {bytes}");
    println!("  duração          : {:.2} s", decorrido.as_secs_f64());
    if decorrido.as_secs_f64() > 0.0 {
        println!(
            "  taxa de mídia    : {:.1} kbit/s (sem cabeçalho de RTP/SRTP/UDP)",
            (bytes as f64 * 8.0 / 1000.0) / decorrido.as_secs_f64()
        );
    }
    if let Some(linha) = copia.finalizar()? {
        println!("  cópia da origem  : {linha}");
    }

    pronto.link.close("envio de áudio concluído");
    drop(pronto);
    quall_core::transport::cleanup();
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Receber
// ---------------------------------------------------------------------------------------------

#[derive(Default)]
struct Recepcao {
    quadros: u64,
    bytes: u64,
    /// PCMU: quadros que bateram **byte a byte** com um dos quadros de referência das notas.
    conferidos: u64,
    /// PCMU: quadros que não bateram com nota nenhuma — corrupção de verdade.
    divergentes: u64,
    /// A nota do quadro anterior, e há quantos quadros ela dura.
    nota_atual: Option<usize>,
    quadros_na_nota: u64,
    /// Comprimento de cada corrida **completa** de nota. A primeira e a última são parciais.
    corridas: Vec<u64>,
    primeira_sequencia: Option<u16>,

    // --- Opus: a conferência é estrutural, não byte a byte. Ver `docs/audio.md` §12. ---
    /// Pacotes em que o nosso leitor de TOC e o da libopus concordaram.
    toc_conferidos: u64,
    /// Pacotes em que os dois leitores divergiram, com a primeira frase de divergência.
    toc_divergentes: u64,
    primeira_divergencia: Option<String>,
    /// Quantos pacotes carregaram LBRR — o FEC embutido, medido e não prometido.
    com_lbrr: u64,
    /// Quantos quadros de Opus vieram em cada pacote. Tem de ser sempre 1: o pacotizador da
    /// libdatachannel não fragmenta, e mais de um quadro por pacote é decodificado errado sem
    /// erro nenhum no caminho.
    pacotes_com_mais_de_um_quadro: u64,
    /// Contagem por modo do TOC, do fluxo que de fato atravessou.
    modos: std::collections::BTreeMap<String, u64>,
    /// Contagem por largura de banda.
    larguras: std::collections::BTreeMap<String, u64>,
    estereo: u64,
    mono: u64,
    /// RMS do último quadro decodificado: prova que o que voltou é som, e não silêncio.
    ultimo_rms: f64,
    /// Falhas de decodificação.
    falhas_de_decode: u64,

    // --- O jitter buffer, e o que ele fez com cada buraco. Ver `quall_core::jitter`. ---
    /// Pacotes que a sonda jogou fora de propósito, para varrer perda sem root. **É perda
    /// SIMULADA**, e todo número derivado dela precisa dizer isso.
    descartados_de_proposito: u64,
    /// Buracos que o LBRR do sucessor devolveu.
    curados_por_fec: u64,
    /// Buracos com sucessor em mãos que **não carregava LBRR**. Contado à parte porque
    /// `opus_decode(decode_fec=1)` cairia na ocultação de perda em silêncio e devolveria sucesso
    /// — a sonda contaria como cura o que o decoder inventou.
    socorro_sem_lbrr: u64,
    /// Buracos que viraram ocultação de perda.
    ocultados: u64,
    /// `decodificar_fec` devolveu erro.
    falhas_de_fec: u64,

    /// Instante da chegada anterior, em µs desde o começo da gravação.
    chegada_anterior_us: Option<u64>,
    /// Histograma do **intervalo entre chegadas**, em faixas de 5 ms: `[0,5) [5,10) … [35,∞)`.
    ///
    /// # Por que este número existe, e o que ele separa
    ///
    /// A origem emite um pacote a cada 20 ms, cravados. Se a rede entregasse do mesmo jeito, todo
    /// intervalo cairia na faixa de 20 ms. Duas coisas diferentes fazem um pacote "chegar
    /// atrasado", e o histograma de atraso relativo sozinho **não as distingue**:
    ///
    /// - **jitter de verdade**: cada pacote sofre um atraso próprio, e os intervalos ficam
    ///   espalhados em torno de 20 ms;
    /// - **entrega em rajada**: o rádio segura vários pacotes e solta todos juntos. Aí os
    ///   intervalos ficam **bimodais** — vários perto de zero (dentro da rajada) e um longo (a
    ///   espera entre rajadas).
    ///
    /// A diferença muda a conclusão inteira. Jitter se resolve com buffer mais fundo; rajada de
    /// rádio, não — ela é economia de energia do Wi-Fi, e enterrar 100 ms de buffer para
    /// acomodá-la seria pagar com a moeda deste produto por um defeito que está na outra ponta.
    intervalos_de_chegada: [u64; 8],
    /// Maior intervalo entre duas chegadas, em µs.
    maior_intervalo_us: u64,
}

/// Sorteia se este pacote deve ser descartado, para a varredura de perda **simulada**.
///
/// A decisão sai da **sequência**, e não de um contador de chegada: uma perda "uma a cada N"
/// mede um caso especial — ela nunca produz rajada — e rajada é justamente onde o LBRR falha.
/// Um embaralhamento da sequência dá perda descorrelacionada e, ainda assim, reproduzível: a
/// mesma corrida perde os mesmos pacotes.
fn sortear_descarte(sequencia: u16, pct: u8) -> bool {
    if pct == 0 {
        return false;
    }
    let mut x = u32::from(sequencia)
        .wrapping_mul(2_654_435_761)
        .wrapping_add(0x9E37_79B9);
    x ^= x >> 15;
    x = x.wrapping_mul(0x85EB_CA6B);
    x ^= x >> 13;
    (x % 100) < u32::from(pct)
}

/// Como conferir o que chegou, por codec.
///
/// # Duas perguntas diferentes, porque os dois codecs são diferentes
///
/// No **PCMU** a pergunta é *"este quadro é um dos quatro que eu sei gerar?"* — a G.711 não tem
/// estado, todo quadro de uma nota é byte a byte idêntico, e a igualdade de bytes prova
/// integridade de conteúdo ponta a ponta.
///
/// No **Opus** essa pergunta não existe. O encoder é preditivo: o quadro *n* depende dos
/// anteriores, então não há tabela de referência. E mesmo que houvesse, comparar bytes entre duas
/// máquinas não seria válido — ver `docs/audio.md` §12. A pergunta vira estrutural e vale mais
/// para o que esta frente veio provar: *"o TOC deste pacote diz o que o `fmtp` prometeu?"*
enum Conferidor {
    Pcmu {
        referencia: Vec<Vec<u8>>,
    },
    #[cfg(feature = "opus")]
    Opus {
        dec: quall_opus::Decodificador,
        canais: u8,
        amostras_por_canal: usize,
    },
}

/// Recolhe uma ordem do buffer numa forma que sobrevive ao fim do empréstimo da fila.
///
/// `(sequência, carga, é_socorro_de_fec)`. Carga nula é ocultação de perda.
fn coletar_ordem(destino: &mut Vec<(u16, Option<Vec<u8>>, bool)>, o: Entrega<'_>) {
    match o {
        Entrega::Quadro {
            payload, sequencia, ..
        } => destino.push((sequencia, Some(payload.to_vec()), false)),
        Entrega::Fec {
            socorro, sequencia, ..
        } => destino.push((sequencia, Some(socorro.to_vec()), true)),
        Entrega::Silencio { sequencia, .. } => destino.push((sequencia, None, false)),
    }
}

/// Executa as ordens do buffer: decodifica, cura por FEC, ou oculta — **um slot de 20 ms para
/// cada uma, sempre, em ordem**. É o que um DAC consumiria.
#[allow(clippy::too_many_arguments)]
fn executar_ordens(
    ordens: &[(u16, Option<Vec<u8>>, bool)],
    e: &mut Recepcao,
    conferidor: &mut Conferidor,
    escritor: &Arc<Mutex<EscritorDeWav>>,
    #[cfg(feature = "opus")] ogg: Option<&Arc<Mutex<crate::ogg::EscritorDeOgg>>>,
    erros: &Arc<AtomicU64>,
) {
    for (_seq, carga, e_socorro) in ordens {
        match conferidor {
            Conferidor::Pcmu { referencia } => {
                let pcm: Vec<i16> = match carga {
                    Some(p) => {
                        // Ver `notas_de_referencia`: a pergunta é "é um dos quatro quadros que eu
                        // sei gerar?", e não "é o índice N do tom?".
                        match referencia.iter().position(|r| r == p) {
                            Some(nota) => {
                                e.conferidos += 1;
                                match e.nota_atual {
                                    Some(anterior) if anterior == nota => e.quadros_na_nota += 1,
                                    Some(_) => {
                                        let fechada = e.quadros_na_nota;
                                        e.corridas.push(fechada);
                                        e.nota_atual = Some(nota);
                                        e.quadros_na_nota = 1;
                                    }
                                    None => {
                                        e.nota_atual = Some(nota);
                                        e.quadros_na_nota = 1;
                                    }
                                }
                            }
                            None => e.divergentes += 1,
                        }
                        p.iter().copied().map(ulaw_para_linear).collect()
                    }
                    None => {
                        // G.711 não tem ocultação de perda: ele não tem estado nenhum de onde
                        // interpolar. O slot vira silêncio, e é por isso que o PCMU é piso e não
                        // alternativa.
                        e.ocultados += 1;
                        vec![0i16; referencia.first().map(|r| r.len()).unwrap_or(160)]
                    }
                };
                if let Ok(mut w) = escritor.lock() {
                    let _ = w.escrever(&pcm);
                } else {
                    erros.fetch_add(1, Ordering::Relaxed);
                }
            }

            #[cfg(feature = "opus")]
            Conferidor::Opus {
                dec,
                canais,
                amostras_por_canal,
            } => {
                let mut pcm = vec![0i16; *amostras_por_canal * usize::from(*canais)];
                let resultado = match (carga, e_socorro) {
                    // Chegou de verdade.
                    (Some(p), false) => dec.decodificar(p, &mut pcm),
                    // O buffer ofereceu socorro. **Conferir o LBRR antes é obrigatório**: sem
                    // LBRR, `opus_decode` com `decode_fec=1` cai na ocultação de perda e devolve
                    // sucesso, e a sonda contaria como cura o que o decoder inventou.
                    (Some(socorro), true) => {
                        if quall_opus::tem_lbrr(socorro).unwrap_or(false) {
                            // `pcm` tem EXATAMENTE a duração de um quadro. Se fosse maior, a
                            // libopus preencheria a diferença com ocultação de perda e só o
                            // final viria do LBRR — sem avisar.
                            let r = dec.decodificar_fec(socorro, &mut pcm);
                            if r.is_ok() {
                                e.curados_por_fec += 1;
                            } else {
                                e.falhas_de_fec += 1;
                            }
                            r
                        } else {
                            e.socorro_sem_lbrr += 1;
                            e.ocultados += 1;
                            dec.ocultar_perda(&mut pcm)
                        }
                    }
                    (None, _) => {
                        e.ocultados += 1;
                        dec.ocultar_perda(&mut pcm)
                    }
                };

                match resultado {
                    Ok(n) => {
                        let usadas = n * usize::from(*canais);
                        let soma: f64 = pcm[..usadas]
                            .iter()
                            .map(|a| f64::from(*a) * f64::from(*a))
                            .sum();
                        e.ultimo_rms = (soma / usadas.max(1) as f64).sqrt();
                        if let Ok(mut w) = escritor.lock() {
                            let _ = w.escrever(&pcm[..usadas]);
                        }
                    }
                    Err(_) => e.falhas_de_decode += 1,
                }

                // O `.opus` guarda **o que atravessou a rede**, e nada mais: um slot recuperado
                // por FEC ou ocultado não tem bytes de fio para guardar. O `.wav` ao lado é que
                // carrega a reprodução inteira, com buraco e tudo.
                if let (Some(o), Some(p), false) = (ogg, carga, *e_socorro) {
                    if let Ok(mut o) = o.lock() {
                        let _ = o.escrever(p, *amostras_por_canal as u32);
                    }
                }
            }
        }
    }
}

/// Recebe a track de áudio, grava o artefato do codec e imprime os contadores.
pub fn receber(
    mut pronto: Ready,
    saida: &Path,
    limite: Duration,
    profundidade: u16,
    descartar_pct: u8,
) -> Result<()> {
    println!();
    println!("esperando uma track de áudio…");
    let track = crate::esperar_track(
        &mut pronto,
        |k| k.e_audio(),
        "áudio",
        Duration::from_secs(20),
    )?;

    println!("track recebida");
    println!("  tipo     : {:?}", track.kind());
    println!("  mid      : {}", track.mid());
    println!("  rótulo   : {}", track.label());

    let Some(codec) = track.codec_de_audio() else {
        return Err(Error::Invalid(format!(
            "a track que chegou é de {:?}, e não é áudio. Use `receber-video`.",
            track.kind()
        )));
    };
    println!("  codec    : {codec:?} ({} Hz)", codec.relogio_hz());

    if !track.kind().e_audio() {
        return Err(Error::Invalid("track sem espécie de áudio".into()));
    }

    // Os canais vêm do **codec negociado**, não da espécie da track — e essa distinção custou um
    // defeito, achado em 27/08/2026 pela frente do áudio no macOS.
    //
    // A versão anterior lia `track.kind().preset_de_audio().canais`, com o comentário de que "a
    // espécie é a mesma informação pela porta que já existe". É verdade para Opus. **É falso para
    // G.711**: a RFC 3551 §6 atribui o payload type 0 a `PCMU/8000/1`, mono por definição, e não há
    // como transportar dois canais nele. Numa track `SystemAudio` (preset estéreo) transportando
    // PCMU, o `.wav` saía declarando 2 canais — e 12,76 s de áudio mono viravam 6,38 s de estéreo,
    // tocando no dobro da velocidade e uma oitava acima.
    //
    // É literalmente o defeito que a §2 do `docs/audio.md` descreve como o que não tem contador
    // ("não dá erro; dá áudio que acelera ou arrasta sem contador nenhum acusando"), dentro do
    // próprio instrumento de bancada. E os dois lados discordavam entre si: quem emite (mais acima
    // neste arquivo) já fixava 1 para PCMU. Só o receptor derivava 2 — por isso o `cmp` entre
    // origem e recebido da §9 nunca o pegou: a combinação `--track sistema --codec pcmu`
    // aparentemente nunca tinha sido corrida.
    //
    // Confirmado por leitura do arquivo, não por dedução: lido como o cabeçalho manda dava 880 Hz,
    // lido como mono dava os 440 Hz que saíram, e "canal esquerdo == canal direito" batia em 0,6%
    // das amostras (estéreo duplicado daria 100%).
    let canais = codec.canais_no_fio(
        track
            .kind()
            .preset_de_audio()
            .map(|p| p.canais)
            .unwrap_or(1),
    );
    let amostras_por_quadro = codec.amostras_por_quadro(20);
    println!("  canais   : {canais} (do codec negociado)");

    let conferidor = match codec {
        CodecDeAudio::Pcmu => Conferidor::Pcmu {
            referencia: notas_de_referencia(codec, amostras_por_quadro)?,
        },
        #[cfg(feature = "opus")]
        CodecDeAudio::Opus => {
            println!("  libopus  : {}", quall_opus::versao());
            Conferidor::Opus {
                dec: quall_opus::Decodificador::novo(codec.relogio_hz(), canais)
                    .map_err(|e| Error::Invalid(format!("criar decoder de Opus: {e}")))?,
                canais,
                amostras_por_canal: amostras_por_quadro,
            }
        }
        #[cfg(not(feature = "opus"))]
        CodecDeAudio::Opus => {
            return Err(Error::Invalid(
                "chegou uma track de Opus e esta sonda foi construída sem a feature `opus`".into(),
            ))
        }
    };

    // O artefato. No PCMU é um `.wav` só. No Opus são dois, e cada um prova uma coisa:
    // o `.opus` é **literalmente o que atravessou a rede**, e o `.wav` é o que ele vira depois de
    // decodificado — para poder ser ouvido e medido por fora.
    let caminho_wav = match codec {
        CodecDeAudio::Pcmu => saida.to_path_buf(),
        CodecDeAudio::Opus => saida.with_extension("wav"),
    };
    let escritor = Arc::new(Mutex::new(EscritorDeWav::criar(
        &caminho_wav,
        codec.relogio_hz(),
        canais,
    )?));

    #[cfg(feature = "opus")]
    let ogg = match codec {
        CodecDeAudio::Opus => Some(Arc::new(Mutex::new(crate::ogg::EscritorDeOgg::criar(
            &saida.with_extension("opus"),
            canais,
            // O receptor não conhece o lookahead do encoder do outro lado; 0 é honesto aqui.
            0,
            codec.relogio_hz(),
        )?))),
        CodecDeAudio::Pcmu => None,
    };

    let estado = Arc::new(Mutex::new(Recepcao::default()));
    let erros = Arc::new(AtomicU64::new(0));

    // O jitter buffer do núcleo, no caminho de verdade. Ele é a única coisa entre o que chegou do
    // fio e o que vai para o `.wav`, exatamente como numa casca com um DAC do outro lado.
    //
    // `fec_disponivel` **não** é `preset.fec` cru: o preset do microfone carrega `fec: true`
    // mesmo quando o codec foi trocado para PCMU, porque `com_codec_de_audio` só troca o codec.
    // Oferecer socorro num fluxo de G.711 faria a sonda chamar `decode_fec` num payload que não
    // tem LBRR nenhum. É a mesma correção que a fronteira C precisou.
    let politica = Politica {
        profundidade,
        duracao_do_quadro_us: DURACAO_DO_QUADRO_MS * 1000,
        fec_disponivel: matches!(codec, CodecDeAudio::Opus)
            && track
                .kind()
                .preset_de_audio()
                .map(|p| p.fec)
                .unwrap_or(false),
        salto_maximo: 100,
    };
    println!(
        "  buffer   : profundidade {} pacote(s) = {} ms de latência, FEC {}",
        politica.profundidade,
        politica.latencia_us() / 1000,
        if politica.fec_disponivel {
            "ligado"
        } else {
            "desligado"
        }
    );
    let jitter = Arc::new(Mutex::new(BufferDeJitter::novo(politica)));
    // O conferidor guarda o decodificador de Opus, que tem estado e precisa de `&mut`. Ele é
    // compartilhado — e não movido para dentro do tratador — porque o **escoamento final** do
    // jitter buffer, depois que a gravação termina, precisa do mesmo decodificador: os últimos
    // `profundidade` slots ainda estão retidos, e continuar a decodificação com outro decoder
    // produziria 40 ms de estalo no fim de toda corrida.
    let conferidor = Arc::new(Mutex::new(conferidor));

    {
        let escritor = Arc::clone(&escritor);
        let estado = Arc::clone(&estado);
        let erros = Arc::clone(&erros);
        #[cfg(feature = "opus")]
        let ogg = ogg.clone();
        // O tratador é `Fn + Send + Sync` — ele roda em threads da libdatachannel e pode ser
        // chamado de mais de uma. O decodificador de Opus tem estado e precisa de `&mut`, então
        // ele entra pelo mesmo caminho que o escritor: atrás de um cadeado.
        let conferidor = Arc::clone(&conferidor);

        let jitter = Arc::clone(&jitter);
        let comeco = Instant::now();

        track.ao_receber_audio(move |q: QuadroDeAudio<'_>| {
            let Ok(mut e) = estado.lock() else {
                erros.fetch_add(1, Ordering::Relaxed);
                return;
            };
            let Ok(mut conferidor) = conferidor.lock() else {
                erros.fetch_add(1, Ordering::Relaxed);
                return;
            };
            let Ok(mut jb) = jitter.lock() else {
                erros.fetch_add(1, Ordering::Relaxed);
                return;
            };

            e.quadros += 1;
            e.bytes += q.payload.len() as u64;

            let agora_us = comeco.elapsed().as_micros() as u64;
            if let Some(anterior) = e.chegada_anterior_us {
                let gap = agora_us.saturating_sub(anterior);
                let faixa = (gap / 5_000) as usize;
                let ultima = e.intervalos_de_chegada.len() - 1;
                e.intervalos_de_chegada[faixa.min(ultima)] += 1;
                if gap > e.maior_intervalo_us {
                    e.maior_intervalo_us = gap;
                }
            }
            e.chegada_anterior_us = Some(agora_us);
            if e.primeira_sequencia.is_none() {
                e.primeira_sequencia = Some(q.sequencia);
            }

            // ------------------------------------------------------------------------------
            // 1. A conferência de ESTRUTURA acontece no pacote que chegou, e não no slot que
            //    saiu: ela é sobre o que o fio entregou. O TOC de um slot recuperado por FEC é o
            //    TOC do pacote seguinte, e contá-lo aqui contaria duas vezes.
            // ------------------------------------------------------------------------------
            #[cfg(feature = "opus")]
            if matches!(codec, CodecDeAudio::Opus) {
                use quall_opus::Toc;
                match Toc::conferir_contra_libopus(q.payload) {
                    Ok(toc) => {
                        e.toc_conferidos += 1;
                        *e.modos.entry(format!("{:?}", toc.modo())).or_insert(0) += 1;
                        *e.larguras
                            .entry(format!("{:?}", toc.largura_de_banda()))
                            .or_insert(0) += 1;
                        if toc.estereo {
                            e.estereo += 1;
                        } else {
                            e.mono += 1;
                        }
                    }
                    Err(motivo) => {
                        e.toc_divergentes += 1;
                        if e.primeira_divergencia.is_none() {
                            e.primeira_divergencia = Some(motivo);
                        }
                    }
                }
                if quall_opus::quadros_no_pacote(q.payload).unwrap_or(1) != 1 {
                    e.pacotes_com_mais_de_um_quadro += 1;
                }
                if quall_opus::tem_lbrr(q.payload).unwrap_or(false) {
                    e.com_lbrr += 1;
                }
            }

            // ------------------------------------------------------------------------------
            // 2. Perda SIMULADA, se pedida. Descartar aqui — depois de contar a chegada e antes
            //    do buffer — é o que faz o número de "buracos" incluir a perda induzida.
            // ------------------------------------------------------------------------------
            if sortear_descarte(q.sequencia, descartar_pct) {
                e.descartados_de_proposito += 1;
                return;
            }

            // ------------------------------------------------------------------------------
            // 3. O buffer. A closure só COLETA: decodificar dentro dela seguraria o empréstimo
            //    da fila enquanto o decoder trabalha, e o decoder é o pedaço lento.
            // ------------------------------------------------------------------------------
            let mut ordens: Vec<(u16, Option<Vec<u8>>, bool)> = Vec::new();
            jb.aceitar(&q, agora_us, |o| coletar_ordem(&mut ordens, o));
            drop(jb);

            executar_ordens(
                &ordens,
                &mut e,
                &mut conferidor,
                &escritor,
                #[cfg(feature = "opus")]
                ogg.as_ref(),
                &erros,
            );
        })?;
    }

    println!();
    println!("gravando por até {:.0} s...", limite.as_secs_f64());
    let comeco = Instant::now();
    while comeco.elapsed() < limite {
        std::thread::sleep(Duration::from_millis(100));
    }

    // **Desligar o tratador antes de escoar.** É barreira: com `Ok`, o tratador não está rodando
    // em thread nenhuma e não voltará a rodar, então o escoamento tem os cadeados só para si e
    // não corre com um pacote que chegou no último instante.
    if !track.desregistrar_audio().is_ok_and(|b| b.cumprida()) {
        // A porta ficou fechada de qualquer jeito; só não há garantia de que ninguém estava
        // dentro. O escoamento abaixo pega os cadeados, então o pior caso é ele esperar.
        println!("  (aviso: a barreira do tratador não se cumpriu no prazo)");
    }

    // O fim do fluxo. Sem isto, os últimos `profundidade` pacotes de toda corrida sumiriam — 40
    // ms que atravessaram a rede e nunca tocaram, e que apareceriam numa tabela como dois
    // quadros a menos sem que ninguém soubesse de onde vieram.
    {
        let mut ordens: Vec<(u16, Option<Vec<u8>>, bool)> = Vec::new();
        if let Ok(mut jb) = jitter.lock() {
            jb.drenar(|o| coletar_ordem(&mut ordens, o));
        }
        if let (Ok(mut e), Ok(mut cf)) = (estado.lock(), conferidor.lock()) {
            executar_ordens(
                &ordens,
                &mut e,
                &mut cf,
                &escritor,
                #[cfg(feature = "opus")]
                ogg.as_ref(),
                &erros,
            );
        }
    }

    // Uma leitura só: todos os números do mesmo instante. Ver a dívida 26.
    let c = track.contadores();
    let e = estado.lock().map_err(|_| Error::Closed)?;

    println!();
    println!("resultado do receptor");
    println!("  quadros recebidos : {}", e.quadros);
    println!("  bytes de mídia    : {}", e.bytes);

    match codec {
        CodecDeAudio::Pcmu => {
            println!(
                "  conteúdo conferido: {} de {} quadro(s) idênticos, byte a byte, a uma nota do tom",
                e.conferidos, e.quadros
            );
            if e.divergentes > 0 {
                println!(
                    "  DIVERGENTES       : {} quadro(s) não bateram com nota nenhuma — corrupção",
                    e.divergentes
                );
            }
            let corridas_completas = e.corridas.len().saturating_sub(1);
            let fora_do_ritmo = e.corridas.iter().skip(1).filter(|n| **n != 25).count();
            println!(
                "  ritmo das notas   : {corridas_completas} corrida(s) completa(s), \
                 {fora_do_ritmo} fora dos 25 quadros"
            );
        }
        CodecDeAudio::Opus => {
            println!(
                "  TOC conferido     : {} de {} pacote(s), pelos dois leitores (nosso × libopus)",
                e.toc_conferidos, e.quadros
            );
            if e.toc_divergentes > 0 {
                println!(
                    "  TOC DIVERGENTE    : {} pacote(s). Primeira: {}",
                    e.toc_divergentes,
                    e.primeira_divergencia.as_deref().unwrap_or("?")
                );
            }
            let m: Vec<String> = e.modos.iter().map(|(k, v)| format!("{k} {v}")).collect();
            let l: Vec<String> = e.larguras.iter().map(|(k, v)| format!("{k} {v}")).collect();
            println!("  modo no fio       : {}", m.join(", "));
            println!("  largura no fio    : {}", l.join(", "));
            println!(
                "  canais no fio     : {} estéreo, {} mono (do byte de TOC)",
                e.estereo, e.mono
            );
            println!(
                "  quadros por pacote: {} pacote(s) com mais de um{}",
                e.pacotes_com_mais_de_um_quadro,
                if e.pacotes_com_mais_de_um_quadro == 0 {
                    "  (um pacote = um quadro, como a §6 exige)"
                } else {
                    "  ← DEFEITO: o outro lado concatenou quadros"
                }
            );
            println!(
                "  LBRR (FEC medido) : {} de {} pacote(s) carregaram a cópia do quadro anterior",
                e.com_lbrr, e.quadros
            );
            println!(
                "  falhas de decode  : {}{}",
                e.falhas_de_decode,
                if e.falhas_de_decode == 0 {
                    ""
                } else {
                    "  ← o fluxo não decodifica"
                }
            );
            println!(
                "  RMS do último     : {:.0} (fundo de escala 32767; ~0 seria silêncio)",
                e.ultimo_rms
            );
        }
    }

    // ------------------------------------------------------------------------------------
    // O jitter buffer. Sem estes números ninguém consegue afirmar nada depois.
    // ------------------------------------------------------------------------------------
    let jb = jitter.lock().map_err(|_| Error::Closed)?.contadores();
    println!();
    println!(
        "jitter buffer (profundidade {profundidade} = {} ms)",
        u64::from(profundidade) * 20
    );
    println!(
        "  slots entregues   : {}  ({} com pacote, {} buracos)",
        jb.slots_entregues, jb.quadros, jb.buracos
    );
    if e.descartados_de_proposito > 0 {
        println!(
            "  perda SIMULADA    : {} pacote(s) descartados pela sonda (--descartar-pct {})",
            e.descartados_de_proposito, descartar_pct
        );
    }
    println!(
        "  buracos           : {} curados por FEC, {} com socorro sem LBRR, {} ocultados",
        e.curados_por_fec, e.socorro_sem_lbrr, e.ocultados
    );
    if e.falhas_de_fec > 0 {
        println!("  FALHAS de decode_fec: {}", e.falhas_de_fec);
    }
    println!(
        "  socorro oferecido : {} de {} buracos  (o resto não tinha o sucessor em mãos)",
        jb.curas_oferecidas, jb.buracos
    );
    println!(
        "  reordenados       : {}  (chegaram trocados e o buffer salvou)",
        jb.reordenados
    );
    println!(
        "  tarde demais      : {}  ← se subir, a profundidade está pequena",
        jb.tarde_demais
    );
    println!("  duplicados        : {}", jb.duplicados);
    println!("  ressincronizações : {}", jb.resincronizacoes);
    println!("  ocupação máxima   : {} pacote(s)", jb.ocupacao_maxima);
    println!(
        "  atraso relativo   : máximo {:.1} ms  (em relação ao pacote mais rápido da sessão)",
        jb.atraso_max_us as f64 / 1000.0
    );
    let faixas: Vec<String> = jb
        .atraso_por_slots
        .iter()
        .enumerate()
        .filter(|(_, n)| **n > 0)
        .map(|(i, n)| format!("{i}:{n}"))
        .collect();
    let gaps: Vec<String> = e
        .intervalos_de_chegada
        .iter()
        .enumerate()
        .filter(|(_, n)| **n > 0)
        .map(|(i, n)| {
            if i == 7 {
                format!("35+ms:{n}")
            } else {
                format!("{}-{}ms:{n}", i * 5, i * 5 + 5)
            }
        })
        .collect();
    println!(
        "  entre chegadas    : {}   maior {:.1} ms",
        gaps.join("  "),
        e.maior_intervalo_us as f64 / 1000.0
    );
    println!(
        "  (a origem emite a cada 20 ms cravados. Concentração em 15–25 ms = jitter de verdade;\n\
         \x20  massa perto de 0 MAIS um intervalo longo = o rádio entregou em rajada, e buffer\n\
         \x20  fundo não conserta rajada.)"
    );
    println!(
        "  por faixa de slot : {}   → profundidade necessária nesta corrida: {}",
        faixas.join("  "),
        jb.profundidade_necessaria()
    );
    println!(
        "  (a faixa k conta os pacotes que atrasaram entre k e k+1 slots de 20 ms. Um pacote na \n\
         \x20  faixa k só é aproveitável com profundidade >= k. Esta é a medida que dimensiona o\n\
         \x20  buffer — NÃO o jitter da RFC 3550, que é média e não cauda.)"
    );
    println!();

    println!("  quadros prontos   : {}", c.quadros_prontos);
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
    match c.jitter_us {
        Some(j) => println!(
            "  jitter (RFC 3550) : {:.3} ms  ({j} µs)",
            f64::from(j) / 1000.0
        ),
        None => println!("  jitter (RFC 3550) : não medido (menos de dois pacotes)"),
    }
    if c.rtcp_ignorados > 0 {
        println!(
            "  ATENÇÃO: {} pacote(s) RTCP chegaram pelo caminho do RTP. A track está sem a",
            c.rtcp_ignorados
        );
        println!("           sessão de RTCP encadeada, ou o filtro da libdatachannel mudou.");
    }

    drop(e);

    // **Desregistrar com barreira, antes de tocar nos escritores.**
    //
    // Os pacotes continuam chegando depois do laço, e o tratador roda numa thread da
    // libdatachannel. Sem barreira não há instante em que se possa afirmar que ele não está lá
    // dentro — é o defeito que a dívida 24 pagou na fronteira C.
    let barreira = track.desregistrar_audio()?;
    if !barreira.cumprida() {
        return Err(Error::Invalid(format!(
            "o tratador de áudio não saiu no prazo ({barreira:?}); não dá para fechar o artefato"
        )));
    }

    let amostras = {
        let escritor = Arc::try_unwrap(escritor).map_err(|_| {
            Error::Invalid("o escritor continua compartilhado depois da barreira".into())
        })?;
        escritor
            .into_inner()
            .map_err(|_| Error::Invalid("cadeado do escritor envenenado".into()))?
            .finalizar()?
    };

    #[cfg(feature = "opus")]
    let pacotes_ogg = match ogg {
        Some(o) => {
            let o = Arc::try_unwrap(o).map_err(|_| {
                Error::Invalid("o escritor de Ogg continua compartilhado depois da barreira".into())
            })?;
            Some(
                o.into_inner()
                    .map_err(|_| Error::Invalid("cadeado do Ogg envenenado".into()))?
                    .finalizar()?,
            )
        }
        None => None,
    };

    println!();
    println!("artefato: {}", caminho_wav.display());
    println!(
        "  {amostras} amostras por canal, {:.2} s a {} Hz, {canais} canal/canais",
        amostras as f64 / f64::from(codec.relogio_hz()),
        codec.relogio_hz()
    );
    #[cfg(feature = "opus")]
    if let Some(n) = pacotes_ogg {
        println!();
        println!("artefato: {}", saida.with_extension("opus").display());
        println!("  {n} pacotes de Opus — os bytes que atravessaram a rede, sem decodificar");
    }
    println!();
    println!("confira com:");
    println!("  ffprobe -v error -show_streams {}", caminho_wav.display());
    #[cfg(feature = "opus")]
    if codec == CodecDeAudio::Opus {
        let o = saida.with_extension("opus");
        println!("  ffprobe -v error -show_streams {}", o.display());
        println!(
            "  opusinfo {}   # se o opus-tools estiver instalado",
            o.display()
        );
    }
    println!("  afplay {}   # macOS", caminho_wav.display());

    let sem_nada = {
        let e = estado.lock().map_err(|_| Error::Closed)?;
        e.quadros == 0
    };

    pronto.link.close("recepção de áudio concluída");
    drop(pronto);
    quall_core::transport::cleanup();

    if sem_nada {
        return Err(Error::Timeout("nenhum quadro de áudio chegou".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A ida e volta do µ-law não é exata — ele é um codec com perda —, mas o erro tem de ficar
    /// dentro do degrau de quantização da faixa.
    ///
    /// **O sinal só é conferido acima do primeiro degrau.** A primeira versão deste teste exigia
    /// `signum` preservado para todo valor e falhou com `1 -> 0`, o que parecia defeito e não
    /// era: o degrau mais fino do µ-law vale 8 unidades de PCM, então qualquer amplitude abaixo
    /// dele quantiza para zero — por desenho do formato, não por erro nosso. Exigir o contrário
    /// era o teste afirmando algo falso sobre a G.711.
    #[test]
    fn ulaw_ida_e_volta_fica_perto() {
        /// Menor degrau de quantização do µ-law, em unidades de PCM de 16 bits.
        const PRIMEIRO_DEGRAU: i32 = 8;

        for a in [0i16, 1, -1, 100, -100, 1000, -1000, 20000, -20000, 32000] {
            let voltou = ulaw_para_linear(linear_para_ulaw(a));
            if i32::from(a).abs() >= PRIMEIRO_DEGRAU {
                assert_eq!(
                    voltou.signum(),
                    a.signum(),
                    "o sinal inverteu: {a} virou {voltou}"
                );
            }
            // O µ-law tem ~8% de erro relativo no pior caso da faixa alta.
            let erro = (i32::from(voltou) - i32::from(a)).unsigned_abs();
            let teto = (i32::from(a).unsigned_abs() / 10).max(PRIMEIRO_DEGRAU as u32);
            assert!(erro <= teto, "{a} -> {voltou}, erro {erro} > teto {teto}");
        }
    }

    /// Todo byte de µ-law decodifica e recodifica para ele mesmo — **menos um**.
    ///
    /// É o que garante que o `.wav` do receptor represente exatamente o que atravessou a rede.
    ///
    /// A exceção é o **zero negativo**, e ela é da G.711 e não nossa: `0xFF` é +0 e `0x7F` é −0,
    /// os dois decodificam para o linear 0, e o linear 0 só tem uma codificação de volta —
    /// `0xFF`. `0x7F` é, portanto, irrecuperável por construção.
    ///
    /// Isso está fixado aqui de propósito. A primeira versão deste teste varria os 256 bytes sem
    /// exceção e falhou em `0x7F`, o que parecia defeito do codificador; é o formato. Um emissor
    /// nosso nunca produz `0x7F` (o zero sai sempre como `0xFF`), mas outro emissor pode, e
    /// então um `.wav` gravado daqui terá um byte trocado sem que nada esteja errado.
    #[test]
    fn ulaw_e_reversivel_byte_a_byte_menos_o_zero_negativo() {
        /// −0 na G.711.
        const ZERO_NEGATIVO: u8 = 0x7F;
        /// +0 na G.711, a única codificação para a qual o linear 0 volta.
        const ZERO_POSITIVO: u8 = 0xFF;

        for b in 0u8..=255 {
            let pcm = ulaw_para_linear(b);
            let voltou = linear_para_ulaw(pcm);
            if b == ZERO_NEGATIVO {
                assert_eq!(pcm, 0, "−0 tem de decodificar para o linear 0");
                assert_eq!(
                    voltou, ZERO_POSITIVO,
                    "o −0 da G.711 volta como +0; é do formato"
                );
            } else {
                assert_eq!(voltou, b, "byte {b:#04x} não voltou");
            }
        }
    }

    /// Os dois zeros da G.711 são o mesmo som, e o nosso codificador só emite um deles.
    #[test]
    fn o_silencio_sai_sempre_como_zero_positivo() {
        assert_eq!(linear_para_ulaw(0), 0xFF);
        assert_eq!(ulaw_para_linear(0x7F), 0);
        assert_eq!(ulaw_para_linear(0xFF), 0);
    }

    #[test]
    fn o_tom_e_deterministico() {
        let a = tom_sintetico(7, 160, 8000);
        let b = tom_sintetico(7, 160, 8000);
        assert_eq!(a, b, "sem determinismo o receptor não pode conferir nada");
        assert_eq!(a.len(), 160);
    }

    /// Cada nota tem um número inteiro de ciclos no quadro, então a onda não salta de fase na
    /// emenda entre quadros consecutivos da **mesma** nota. Um salto ali vira estalo a cada
    /// 20 ms, e o estalo seria procurado na rede.
    #[test]
    fn a_onda_nao_salta_de_fase_entre_quadros_da_mesma_nota() {
        for indice in [0u64, 1, 2, 26, 51] {
            let atual = tom_sintetico(indice, 160, 8000);
            let proximo = tom_sintetico(indice + 1, 160, 8000);
            let mesma_nota = (indice / QUADROS_POR_NOTA) == ((indice + 1) / QUADROS_POR_NOTA);
            if !mesma_nota {
                continue;
            }
            // A amostra seguinte à última do quadro atual é a primeira do próximo. A diferença
            // entre elas não pode ser maior que o maior degrau dentro do próprio quadro.
            let maior_degrau = atual
                .windows(2)
                .map(|w| (i32::from(w[1]) - i32::from(w[0])).abs())
                .max()
                .unwrap_or(0);
            let emenda = (i32::from(proximo[0]) - i32::from(atual[159])).abs();
            assert!(
                emenda <= maior_degrau * 2,
                "salto de fase na emenda do quadro {indice}: {emenda} contra degrau {maior_degrau}"
            );
        }
    }

    #[test]
    fn notas_diferentes_geram_audio_diferente() {
        // Quadro 0 é a primeira nota; quadro 25 é a segunda.
        assert_ne!(tom_sintetico(0, 160, 8000), tom_sintetico(25, 160, 8000));
    }

    #[test]
    fn opus_recusa_com_mensagem_util() {
        let erro = quadro_codificado(0, CodecDeAudio::Opus, 960);
        assert!(
            erro.is_err(),
            "não temos encoder de Opus e não podemos fingir"
        );
    }
}
