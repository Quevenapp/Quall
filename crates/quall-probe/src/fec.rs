//! A recuperação por FEC, exercida num buraco de verdade.
//!
//! # O que esta bancada existe para provar
//!
//! O `docs/audio.md` fechou a rodada anterior com esta frase na §13:
//!
//! > *"A recuperação por FEC nunca foi exercida. Sei que o LBRR está no fio (99,8% dos pacotes) e
//! > sei que 3 pacotes se perderam no Wi-Fi. **Não sei se o LBRR recuperou coisa alguma**, porque
//! > quem chamaria `opus_decode(..., decode_fec=1)` é o jitter buffer, e ele não existe."*
//!
//! Agora ele existe ([`quall_core::jitter`]), e esta bancada é a que fecha a frase: ela perde
//! pacotes de propósito, passa o resto pelo buffer de verdade — o mesmo tipo do núcleo, sem
//! simulação — e mede **o que volta e o que não volta**.
//!
//! # Por que a origem tem 6 kHz e 11 kHz dentro
//!
//! O tom de quatro notas da bancada vai de 400 a 1000 Hz. **Tudo isso cabe em banda estreita**, e
//! banda estreita é justamente o que o LBRR entrega. Medir a recuperação só com aquele tom
//! responderia "o FEC devolve tudo" — e a resposta seria um artefato da origem, não uma verdade
//! sobre o codec.
//!
//! Então a origem daqui carrega três parciais: a nota (400–1000 Hz), uma em **6 kHz** (fora da
//! banda estreita, dentro da larga) e uma em **11 kHz** (fora da larga). É assim que a pergunta
//! *"o que a recuperação NÃO devolve?"* passa a ter resposta numérica.
//!
//! A origem continua **sintética e nossa**, como a §8 do `docs/audio.md` exige.

use std::collections::BTreeMap;

use quall_core::error::{Error, Result};
use quall_core::jitter::{BufferDeJitter, ContadoresDeBuffer, Entrega, Politica};
use quall_core::rtp::QuadroDeAudio;
use quall_core::track::{PresetDeAudio, PRESET_MICROFONE};

/// Taxa de amostragem do Opus. Ver `docs/audio.md` §2.
const TAXA_HZ: u32 = 48_000;

/// As parciais da origem, em Hz, com a amplitude de cada uma em fração do fundo de escala.
///
/// A soma das amplitudes fica em 0,5 — a mesma da sonda —, porque o portão do LBRR é o VAD do
/// SILK e ele mede atividade contra o piso de ruído: uma origem fraca derruba o FEC antes de
/// qualquer perda acontecer. Está medido em `quall-ffi`.
const PARCIAIS: [(f64, f64); 3] = [(0.0, 0.30), (6_000.0, 0.12), (11_000.0, 0.08)];

/// As quatro notas, as mesmas da sonda.
const NOTAS_HZ: [f64; 4] = [400.0, 500.0, 800.0, 1000.0];

/// Quantos quadros cada nota dura.
const QUADROS_POR_NOTA: u64 = 25;

/// Gera **um** quadro de PCM da origem, deterministicamente a partir do índice.
///
/// A nota troca a cada 25 quadros pelo mesmo motivo da sonda — a fase de cada parcial é calculada
/// do índice absoluto da amostra, então não há salto na emenda entre quadros.
pub fn origem(indice: u64, amostras: usize) -> Vec<i16> {
    let nota = NOTAS_HZ[((indice / QUADROS_POR_NOTA) as usize) % NOTAS_HZ.len()];
    let base = indice * amostras as u64;
    (0..amostras)
        .map(|i| {
            let t = (base + i as u64) as f64 / f64::from(TAXA_HZ);
            let mut v = 0.0;
            for (hz, amp) in PARCIAIS {
                let f = if hz == 0.0 { nota } else { hz };
                v += (t * f * std::f64::consts::TAU).sin() * amp;
            }
            (v * f64::from(i16::MAX)) as i16
        })
        .collect()
}

/// A energia do sinal numa frequência, pelo algoritmo de Goertzel.
///
/// Um DFT de um bin só. É o suficiente e é honesto: a origem é uma soma de senoides de frequência
/// conhecida, então medir os bins dela responde exatamente *"esta parcial sobreviveu?"* sem
/// arrastar uma FFT para dentro da sonda.
pub fn energia_em(x: &[i16], hz: f64) -> f64 {
    if x.is_empty() {
        return 0.0;
    }
    let n = x.len() as f64;
    let k = (0.5 + n * hz / f64::from(TAXA_HZ)).floor();
    let w = std::f64::consts::TAU * k / n;
    let coef = 2.0 * w.cos();
    let (mut s1, mut s2) = (0.0f64, 0.0f64);
    for &v in x {
        let s = f64::from(v) + coef * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    ((s1 * s1 + s2 * s2 - coef * s1 * s2).max(0.0)).sqrt() / n
}

/// A raiz do valor quadrático médio.
pub fn rms(x: &[i16]) -> f64 {
    if x.is_empty() {
        return 0.0;
    }
    let soma: f64 = x.iter().map(|a| f64::from(*a) * f64::from(*a)).sum();
    (soma / x.len() as f64).sqrt()
}

/// O maior salto entre amostras vizinhas dentro de um quadro.
///
/// É o piso natural de descontinuidade do sinal: nenhuma emenda pode ser chamada de "estalo" se o
/// salto dela for da ordem do que a própria onda já faz.
pub fn maior_salto_interno(x: &[i16]) -> f64 {
    x.windows(2)
        .map(|p| (f64::from(p[1]) - f64::from(p[0])).abs())
        .fold(0.0, f64::max)
}

/// O que aconteceu com um slot que não chegou.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Desfecho {
    /// O LBRR do sucessor devolveu o quadro.
    CuradoPorFec,
    /// Havia sucessor, mas ele **não carregava LBRR** — e `opus_decode` com `decode_fec=1` teria
    /// caído na ocultação de perda em silêncio, devolvendo sucesso. Contado à parte por isso.
    SocorroSemLbrr,
    /// Não havia sucessor em mãos: rajada de duas perdas, ou fim do fluxo.
    Ocultado,
}

/// A medida de um buraco.
#[derive(Debug, Clone)]
pub struct MedidaDeBuraco {
    pub sequencia: u16,
    pub desfecho: Desfecho,
    /// RMS do quadro que o decoder produziu para o slot.
    pub rms_saida: f64,
    /// RMS do mesmo slot no fluxo **sem perda**, decodificado por um decoder de referência.
    pub rms_verdade: f64,
    /// Energia por parcial na saída e na verdade: `(hz, saida, verdade)`.
    pub parciais: Vec<(f64, f64, f64)>,
    /// Salto entre a última amostra do slot anterior e a primeira deste. O "estalo", em números.
    pub salto_na_emenda: f64,
}

/// O resultado de uma corrida inteira.
#[derive(Debug, Clone, Default)]
pub struct Relatorio {
    pub quadros: u64,
    pub perdidos: u64,
    pub buracos: Vec<MedidaDeBuraco>,
    pub contadores: ContadoresDeBuffer,
    /// Piso de descontinuidade do próprio sinal: o maior salto interno visto em quadro bom.
    pub salto_tipico_do_sinal: f64,
    /// Salto na emenda de quadros que chegaram normalmente. A régua contra a qual o estalo de um
    /// buraco é lido.
    pub salto_max_sem_buraco: f64,
}

impl Relatorio {
    pub fn conta(&self, d: Desfecho) -> usize {
        self.buracos.iter().filter(|b| b.desfecho == d).count()
    }
}

/// Como a corrida deve perder pacotes.
// `Estes` só é construída pelos testes, que é onde a perda precisa ser exatamente reprodutível.
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum Perda {
    /// Perde os índices dados, exatamente. Determinístico, e é o que os testes usam.
    Estes(Vec<u64>),
    /// Perde um a cada `n`. Perda isolada, o caso que o LBRR cobre.
    UmACada(u64),
    /// Perde `rajada` seguidos a cada `n`. É como se mede o que o LBRR **não** cobre.
    Rajada { a_cada: u64, rajada: u64 },
}

impl Perda {
    fn perde(&self, i: u64) -> bool {
        match self {
            Perda::Estes(v) => v.contains(&i),
            Perda::UmACada(n) => *n > 0 && i > 0 && i % *n == 0,
            Perda::Rajada { a_cada, rajada } => {
                *a_cada > 0 && i > 0 && (i % *a_cada) < *rajada && (i % *a_cada) < *a_cada
            }
        }
    }
}

/// Corre a bancada: codifica `n` quadros, perde os que `perda` mandar, passa o resto pelo jitter
/// buffer do núcleo e mede o que a recuperação devolveu.
///
/// `usar_fec` em `false` refaz a mesma corrida ignorando a oferta de FEC — é a corrida de
/// controle, e sem ela não dá para dizer o que o FEC melhorou.
pub fn correr(n: u64, perda: &Perda, usar_fec: bool, preset: &PresetDeAudio) -> Result<Relatorio> {
    let amostras = preset.amostras_por_quadro();
    let canais = usize::from(preset.canais);
    if canais != 1 {
        return Err(Error::Invalid(
            "a bancada de FEC é mono: o LBRR só existe em SILK/híbrido, e o preset estéreo roda \
             em CELT — ver docs/audio.md §3"
                .into(),
        ));
    }

    let mut enc = montar_encoder(preset)?;
    let mut buf = vec![0u8; 4000];

    // Codifica o fluxo inteiro **uma vez**. A perda é aplicada depois, no que já saiu do
    // encoder: é o que a rede faz. Perder antes de codificar mudaria o estado do encoder e a
    // corrida deixaria de ser comparável com a de controle.
    let mut pacotes: Vec<Vec<u8>> = Vec::with_capacity(n as usize);
    for i in 0..n {
        let pcm = origem(i, amostras);
        let escrito = enc
            .codificar(&pcm, &mut buf)
            .map_err(|e| Error::Invalid(format!("opus_encode: {e}")))?;
        pacotes.push(buf[..escrito].to_vec());
    }

    // O decoder de referência: vê **todos** os pacotes, e é ele que diz o que o slot deveria ter
    // sido. Sem ele "recuperou" não teria com o que ser comparado.
    let mut dec_ref = quall_opus::Decodificador::novo(TAXA_HZ, preset.canais)
        .map_err(|e| Error::Invalid(format!("criar decoder de referência: {e}")))?;
    let mut verdade: Vec<Vec<i16>> = Vec::with_capacity(n as usize);
    for p in &pacotes {
        let mut pcm = vec![0i16; amostras];
        let m = dec_ref
            .decodificar(p, &mut pcm)
            .map_err(|e| Error::Invalid(format!("decodificar referência: {e}")))?;
        pcm.truncate(m);
        verdade.push(pcm);
    }

    let politica = Politica {
        profundidade: 2,
        duracao_do_quadro_us: preset.duracao_do_quadro_ms * 1000,
        fec_disponivel: preset.fec,
        salto_maximo: 100,
    };
    let mut jitter = BufferDeJitter::novo(politica);
    let mut dec = quall_opus::Decodificador::novo(TAXA_HZ, preset.canais)
        .map_err(|e| Error::Invalid(format!("criar decoder: {e}")))?;

    let mut rel = Relatorio {
        quadros: n,
        ..Default::default()
    };
    // A última amostra do slot anterior, para medir o salto na emenda.
    let mut ultima_amostra: Option<i16> = None;
    let mut slots: BTreeMap<u16, ()> = BTreeMap::new();

    // O laço de saída precisa de `&mut` em várias coisas ao mesmo tempo; a closure do buffer só
    // pode emprestar o que não conflita, então ela **coleta as ordens** e o trabalho pesado
    // acontece fora dela.
    let mut ordens: Vec<(u16, Option<Vec<u8>>, bool)> = Vec::new();

    for i in 0..n {
        if perda.perde(i) {
            rel.perdidos += 1;
            continue;
        }
        let seq = i as u16;
        let quadro = QuadroDeAudio {
            payload: &pacotes[i as usize],
            timestamp_us: i * u64::from(preset.duracao_do_quadro_ms) * 1000,
            sequencia: seq,
            marca: true,
        };
        let chegada = quadro.timestamp_us;
        jitter.aceitar(&quadro, chegada, |e| coletar(&mut ordens, e));
    }
    jitter.drenar(|e| coletar(&mut ordens, e));
    rel.contadores = jitter.contadores();

    for (seq, carga, e_fec) in ordens {
        slots.insert(seq, ());
        let mut pcm = vec![0i16; amostras];

        let (saida, buraco) = match (&carga, e_fec) {
            // Chegou de verdade.
            (Some(p), false) => {
                let m = dec
                    .decodificar(p, &mut pcm)
                    .map_err(|e| Error::Invalid(format!("opus_decode: {e}")))?;
                pcm.truncate(m);
                (pcm, None)
            }
            // O buffer ofereceu socorro. **Conferir o LBRR antes é obrigatório**: sem ele,
            // `opus_decode` com `decode_fec=1` cai na ocultação de perda e devolve sucesso, e a
            // sonda contaria como cura o que o decoder inventou.
            (Some(socorro), true) => {
                let tem = quall_opus::tem_lbrr(socorro).unwrap_or(false);
                if usar_fec && tem {
                    // O buffer tem de ter EXATAMENTE a duração do quadro que faltou. Se for
                    // maior, a libopus preenche a diferença com ocultação de perda e só o final
                    // vem do LBRR — sem avisar. Ver `opus_decode_native`.
                    let m = dec
                        .decodificar_fec(socorro, &mut pcm)
                        .map_err(|e| Error::Invalid(format!("opus_decode(fec): {e}")))?;
                    pcm.truncate(m);
                    (pcm, Some(Desfecho::CuradoPorFec))
                } else {
                    let m = dec
                        .ocultar_perda(&mut pcm)
                        .map_err(|e| Error::Invalid(format!("opus PLC: {e}")))?;
                    pcm.truncate(m);
                    let d = if tem {
                        // A corrida de controle: havia LBRR e ela recusou usá-lo de propósito.
                        Desfecho::Ocultado
                    } else {
                        Desfecho::SocorroSemLbrr
                    };
                    (pcm, Some(d))
                }
            }
            // Sem socorro: PLC e pronto.
            (None, _) => {
                let m = dec
                    .ocultar_perda(&mut pcm)
                    .map_err(|e| Error::Invalid(format!("opus PLC: {e}")))?;
                pcm.truncate(m);
                (pcm, Some(Desfecho::Ocultado))
            }
        };

        let salto = match ultima_amostra {
            Some(a) => saida
                .first()
                .map(|b| (f64::from(*b) - f64::from(a)).abs())
                .unwrap_or(0.0),
            None => 0.0,
        };
        ultima_amostra = saida.last().copied();

        match buraco {
            None => {
                rel.salto_max_sem_buraco = rel.salto_max_sem_buraco.max(salto);
                rel.salto_tipico_do_sinal =
                    rel.salto_tipico_do_sinal.max(maior_salto_interno(&saida));
            }
            Some(desfecho) => {
                let vazio = Vec::new();
                let v = verdade.get(usize::from(seq)).unwrap_or(&vazio);
                let parciais = PARCIAIS
                    .iter()
                    .map(|(hz, _)| {
                        let f = if *hz == 0.0 {
                            NOTAS_HZ[((u64::from(seq) / QUADROS_POR_NOTA) as usize) % 4]
                        } else {
                            *hz
                        };
                        (f, energia_em(&saida, f), energia_em(v, f))
                    })
                    .collect();
                rel.buracos.push(MedidaDeBuraco {
                    sequencia: seq,
                    desfecho,
                    rms_saida: rms(&saida),
                    rms_verdade: rms(v),
                    parciais,
                    salto_na_emenda: salto,
                });
            }
        }
    }

    Ok(rel)
}

/// Recolhe uma ordem do buffer numa forma que sobrevive ao fim do empréstimo.
fn coletar(destino: &mut Vec<(u16, Option<Vec<u8>>, bool)>, e: Entrega<'_>) {
    match e {
        Entrega::Quadro {
            payload, sequencia, ..
        } => destino.push((sequencia, Some(payload.to_vec()), false)),
        Entrega::Fec {
            socorro, sequencia, ..
        } => destino.push((sequencia, Some(socorro.to_vec()), true)),
        Entrega::Silencio { sequencia, .. } => destino.push((sequencia, None, false)),
    }
}

/// O encoder da bancada, configurado **pelo preset** — a mesma regra de fonte única que a
/// fronteira C segue.
fn montar_encoder(preset: &PresetDeAudio) -> Result<quall_opus::Codificador> {
    use quall_opus::{Aplicacao, Codificador, Sinal};
    let mapear = |e: quall_opus::Erro| Error::Invalid(format!("configurar encoder: {e}"));
    let mut c = Codificador::novo(TAXA_HZ, preset.canais, Aplicacao::Voz).map_err(mapear)?;
    c.definir_taxa_de_bits(preset.taxa_media_bits)
        .and_then(|_| c.definir_fec_embutido(preset.fec))
        .and_then(|_| c.definir_perda_esperada(preset.perda_esperada_pct))
        .and_then(|_| c.definir_sinal(Sinal::Voz))
        .and_then(|_| c.definir_dtx(false))
        // A complexidade do produto (`complexidade_do_encoder`): a bancada de FEC mede o que as cascas emitem.
        .and_then(|_| c.definir_complexidade(preset.complexidade_do_encoder()))
        .map_err(mapear)?;
    Ok(c)
}

/// Imprime a bancada inteira. É o subcomando `fec-em-buraco`.
pub fn bancada(n: u64) -> Result<()> {
    let preset = PRESET_MICROFONE;
    println!("bancada de recuperação por FEC");
    println!("  libopus  : {}", quall_opus::versao());
    println!(
        "  preset   : {} canal, {} bit/s, fec={}, perda declarada {}%",
        preset.canais, preset.taxa_media_bits, preset.fec, preset.perda_esperada_pct
    );
    println!(
        "  origem   : nota 400–1000 Hz + parcial 6 kHz + parcial 11 kHz, sintética (§8)\n\
         \x20            as parciais altas existem para medir o que o LBRR NÃO devolve"
    );
    println!("  quadros  : {n}");

    for (nome, perda) in [
        ("perda isolada, 1 a cada 20", Perda::UmACada(20)),
        (
            "rajada de 2, a cada 25",
            Perda::Rajada {
                a_cada: 25,
                rajada: 2,
            },
        ),
        (
            "rajada de 3, a cada 30",
            Perda::Rajada {
                a_cada: 30,
                rajada: 3,
            },
        ),
    ] {
        println!("\n=== {nome} ===");
        let com = correr(n, &perda, true, &preset)?;
        let sem = correr(n, &perda, false, &preset)?;
        imprimir(&com, &sem);
    }
    Ok(())
}

fn imprimir(com: &Relatorio, sem: &Relatorio) {
    let c = com.contadores;
    println!(
        "  perdidos {} de {}   buracos {}   socorro oferecido {}   sem socorro {}",
        com.perdidos, com.quadros, c.buracos, c.curas_oferecidas, c.silencios
    );
    println!(
        "  curados por FEC {}   socorro sem LBRR {}   ocultados {}",
        com.conta(Desfecho::CuradoPorFec),
        com.conta(Desfecho::SocorroSemLbrr),
        com.conta(Desfecho::Ocultado),
    );

    // **A comparação é por slot, e isso não é detalhe.** A primeira versão desta função comparava
    // a média dos slots curados contra a média de TODOS os buracos da corrida de controle. Na
    // perda isolada os dois conjuntos coincidem e o número saía certo; na rajada não coincidem —
    // o controle carrega também os slots que o FEC nunca teve como curar — e a tabela dizia que
    // o FEC piorava o áudio. Dizia isso porque estava comparando slots diferentes.
    let curados: Vec<&MedidaDeBuraco> = com
        .buracos
        .iter()
        .filter(|b| b.desfecho == Desfecho::CuradoPorFec)
        .collect();
    let mesmos_slots: Vec<&MedidaDeBuraco> = sem
        .buracos
        .iter()
        .filter(|b| curados.iter().any(|c| c.sequencia == b.sequencia))
        .collect();

    let media = |v: &[&MedidaDeBuraco], f: fn(&MedidaDeBuraco) -> f64| -> f64 {
        if v.is_empty() {
            return 0.0;
        }
        v.iter().map(|b| f(b)).sum::<f64>() / v.len() as f64
    };

    println!(
        "  (as duas colunas abaixo são os MESMOS {} slots, curados numa corrida e ocultados na \
         outra)",
        curados.len()
    );
    println!(
        "  salto na emenda: sinal contínuo {:.0}, quadro bom {:.0}",
        com.salto_tipico_do_sinal, com.salto_max_sem_buraco
    );
    println!(
        "                   com FEC {:.0}   sem FEC (PLC) {:.0}",
        media(&curados, |b| b.salto_na_emenda),
        media(&mesmos_slots, |b| b.salto_na_emenda),
    );
    println!(
        "  RMS do slot    : verdade {:.0}   com FEC {:.0}   sem FEC (PLC) {:.0}",
        media(&curados, |b| b.rms_verdade),
        media(&curados, |b| b.rms_saida),
        media(&mesmos_slots, |b| b.rms_saida),
    );

    if let Some(primeiro) = curados.first() {
        println!("  por parcial (energia da saída ÷ energia da verdade), média nos curados:");
        for (i, (hz, _, _)) in primeiro.parciais.iter().enumerate() {
            let razao = |v: &[&MedidaDeBuraco]| -> f64 {
                let vs: Vec<f64> = v
                    .iter()
                    .filter_map(|b| b.parciais.get(i))
                    .filter(|(_, _, verdade)| *verdade > 1.0)
                    .map(|(_, s, verdade)| s / verdade)
                    .collect();
                if vs.is_empty() {
                    0.0
                } else {
                    vs.iter().sum::<f64>() / vs.len() as f64
                }
            };
            let nome = if i == 0 {
                "nota (400–1000 Hz)".to_string()
            } else {
                format!("{:.0} Hz", hz)
            };
            println!(
                "    {nome:<20} com FEC {:>5.2}×   sem FEC (PLC) {:>5.2}×",
                razao(&curados),
                razao(&mesmos_slots),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **O teste que fecha a frente.** Um buraco de verdade, `decode_fec` chamado nele, e o que
    /// volta comparado com o que deveria ter sido.
    #[test]
    fn decode_fec_recupera_um_buraco_de_verdade() {
        let rel = correr(80, &Perda::Estes(vec![40]), true, &PRESET_MICROFONE).expect("corrida");
        assert_eq!(rel.perdidos, 1);
        assert_eq!(rel.contadores.buracos, 1, "o buffer tinha de ver o buraco");
        assert_eq!(rel.contadores.curas_oferecidas, 1);
        assert_eq!(rel.buracos.len(), 1);
        let b = &rel.buracos[0];
        assert_eq!(
            b.desfecho,
            Desfecho::CuradoPorFec,
            "o pacote seguinte carregava LBRR e o decoder tinha de usá-lo"
        );
        // O quadro recuperado tem de ter som dentro. Um PLC sobre um tom também teria, então
        // isto sozinho não prova nada — a prova é a comparação da bancada. Mas um zero aqui
        // seria `decode_fec` devolvendo nada, que é o defeito grosseiro.
        assert!(
            b.rms_saida > b.rms_verdade * 0.3,
            "o slot curado saiu com RMS {:.0} contra {:.0} da verdade",
            b.rms_saida,
            b.rms_verdade
        );
    }

    /// **A regra do LBRR virando número.** Numa rajada de duas perdas, a primeira não tem
    /// sucessor em mãos e é ocultada; a segunda é curada.
    #[test]
    fn numa_rajada_de_duas_so_a_segunda_e_curada() {
        let rel =
            correr(80, &Perda::Estes(vec![40, 41]), true, &PRESET_MICROFONE).expect("corrida");
        assert_eq!(rel.buracos.len(), 2);
        assert_eq!(rel.buracos[0].sequencia, 40);
        assert_eq!(rel.buracos[0].desfecho, Desfecho::Ocultado);
        assert_eq!(rel.buracos[1].sequencia, 41);
        assert_eq!(rel.buracos[1].desfecho, Desfecho::CuradoPorFec);
    }

    /// **O que a recuperação NÃO devolve.** O LBRR é de banda reduzida: a parcial de 11 kHz sai
    /// muito mais fraca que a verdade, enquanto a nota de banda estreita volta.
    ///
    /// Este teste é a razão de a origem ter parciais altas. Com o tom de quatro notas sozinho a
    /// resposta seria "o FEC devolve tudo", e ela seria um artefato da origem.
    #[test]
    fn a_recuperacao_por_fec_nao_e_transparente_no_agudo() {
        let rel = correr(120, &Perda::UmACada(20), true, &PRESET_MICROFONE).expect("corrida");
        let curados: Vec<_> = rel
            .buracos
            .iter()
            .filter(|b| b.desfecho == Desfecho::CuradoPorFec)
            .collect();
        assert!(!curados.is_empty(), "nenhum buraco foi curado");

        let razao = |i: usize| -> f64 {
            let v: Vec<f64> = curados
                .iter()
                .filter_map(|b| b.parciais.get(i))
                .filter(|(_, _, verdade)| *verdade > 1.0)
                .map(|(_, s, verdade)| s / verdade)
                .collect();
            v.iter().sum::<f64>() / v.len().max(1) as f64
        };
        let baixa = razao(0);
        let alta = razao(2); // 11 kHz
        assert!(
            alta < baixa,
            "o LBRR é de banda reduzida: 11 kHz saiu em {alta:.2}× e a nota em {baixa:.2}×. \
             Se isto inverteu, a origem ou o codec mudaram."
        );
    }

    /// A corrida de controle existe e é diferente da com FEC — sem isso não daria para afirmar
    /// que o FEC melhorou coisa alguma.
    #[test]
    fn a_corrida_de_controle_oculta_em_vez_de_curar() {
        let rel = correr(80, &Perda::Estes(vec![40]), false, &PRESET_MICROFONE).expect("corrida");
        assert_eq!(rel.buracos.len(), 1);
        assert_eq!(rel.buracos[0].desfecho, Desfecho::Ocultado);
    }

    /// A origem tem mesmo energia nas três parciais — se ela não tivesse, o teste do agudo
    /// passaria por vacuidade.
    #[test]
    fn a_origem_tem_energia_nas_tres_parciais() {
        let pcm = origem(0, 960);
        assert!(energia_em(&pcm, 400.0) > 100.0);
        assert!(energia_em(&pcm, 6_000.0) > 100.0);
        assert!(energia_em(&pcm, 11_000.0) > 100.0);
    }
}
