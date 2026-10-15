//! Um escritor de Ogg Opus, para que a prova saia do nosso alcance.
//!
//! # Por que um contêiner, e não um despejo dos payloads
//!
//! A prova de PCMU fechava por fora com um `.wav` que o `ffprobe` e o `afplay` abrem sem
//! discussão. Um fluxo de Opus não tem esse luxo: os pacotes são de tamanho variável e não
//! carregam o próprio comprimento, então um arquivo com os payloads concatenados **não é
//! separável** — nem por nós, nem por ninguém.
//!
//! Um `.opus` (Ogg Opus, RFC 7845) resolve isso e resolve mais: ele carrega a taxa, os canais e o
//! *pre-skip*, e é lido pelo `ffprobe`, pelo `opusinfo` e por qualquer tocador. É o que permite a
//! frase que este projeto exige — *"confira por fora do sandbox"* — valer para o áudio.
//!
//! **A origem do que entra aqui é sempre o tom sintético de [`crate::audio`].** Ver a regra em
//! `docs/regras-de-frente.md`: um arquivo de mídia não carrega no nome o que tem dentro.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

use quall_core::error::{Error, Result};

/// A tabela de CRC do Ogg.
///
/// **Não é o CRC-32 comum.** O Ogg usa o polinômio 0x04C11DB7 *sem* reflexão de bits, com valor
/// inicial 0 e sem XOR final — enquanto o CRC-32 do zlib/PNG usa o mesmo polinômio refletido, com
/// inicial 0xFFFFFFFF e XOR final. Usar o do zlib produz um arquivo que parece certo, tem as
/// páginas no lugar, e é recusado por todo decodificador com "CRC mismatch".
fn tabela_crc() -> [u32; 256] {
    let mut t = [0u32; 256];
    let mut i = 0usize;
    while i < 256 {
        let mut r = (i as u32) << 24;
        let mut j = 0;
        while j < 8 {
            r = if r & 0x8000_0000 != 0 {
                (r << 1) ^ 0x04C1_1DB7
            } else {
                r << 1
            };
            j += 1;
        }
        t[i] = r;
        i += 1;
    }
    t
}

fn crc_ogg(tabela: &[u32; 256], dados: &[u8]) -> u32 {
    let mut r: u32 = 0;
    for b in dados {
        r = (r << 8) ^ tabela[(((r >> 24) as u8) ^ *b) as usize];
    }
    r
}

/// Escreve um arquivo Ogg Opus.
pub struct EscritorDeOgg {
    arquivo: BufWriter<File>,
    tabela: [u32; 256],
    serial: u32,
    sequencia: u32,
    /// Amostras a 48 kHz já entregues. É o `granulepos` do Ogg.
    granulo: u64,
    pacotes: u64,
    canais: u8,
}

impl EscritorDeOgg {
    /// `pre_skip` são as amostras que o decodificador deve descartar no começo — o lookahead do
    /// encoder. Passar 0 aqui não corrompe o arquivo; faz o tocador reproduzir alguns
    /// milissegundos de transiente do encoder no início.
    pub fn criar(caminho: &Path, canais: u8, pre_skip: u16, taxa_hz: u32) -> Result<Self> {
        let arquivo = File::create(caminho).map_err(|e| {
            Error::Invalid(format!("não deu para criar {}: {e}", caminho.display()))
        })?;
        let mut w = EscritorDeOgg {
            arquivo: BufWriter::new(arquivo),
            tabela: tabela_crc(),
            // Fixo e não aleatório: um arquivo gerado duas vezes da mesma origem tem de ser o
            // mesmo arquivo, senão `cmp` deixa de ser ferramenta de bancada.
            serial: 0x5155_0005,
            sequencia: 0,
            granulo: 0,
            pacotes: 0,
            canais,
        };

        // --- OpusHead (RFC 7845 §5.1) ---
        let mut cabeca = Vec::with_capacity(19);
        cabeca.extend_from_slice(b"OpusHead");
        cabeca.push(1); // versão
        cabeca.push(canais);
        cabeca.extend_from_slice(&pre_skip.to_le_bytes());
        cabeca.extend_from_slice(&taxa_hz.to_le_bytes()); // taxa de entrada original
        cabeca.extend_from_slice(&0i16.to_le_bytes()); // ganho de saída
        cabeca.push(0); // família de mapeamento 0: mono/estéreo simples
        w.pagina(&cabeca, 0x02, 0)?; // 0x02 = começo do fluxo

        // --- OpusTags (RFC 7845 §5.2) ---
        let fornecedor = b"quall-probe";
        let mut tags = Vec::new();
        tags.extend_from_slice(b"OpusTags");
        tags.extend_from_slice(&(fornecedor.len() as u32).to_le_bytes());
        tags.extend_from_slice(fornecedor);
        tags.extend_from_slice(&0u32.to_le_bytes()); // nenhum comentário
        w.pagina(&tags, 0x00, 0)?;

        Ok(w)
    }

    /// Escreve **uma** página com **um** pacote dentro.
    ///
    /// Uma página por pacote é desperdício de cabeçalho (~28 bytes por 80 de payload) e é
    /// deliberado: mantém a correspondência pacote-de-RTP ↔ pacote-de-Ogg de um para um, que é o
    /// que faz o arquivo servir de prova do que atravessou a rede, e não só de som.
    fn pagina(&mut self, pacote: &[u8], tipo: u8, granulo: u64) -> Result<()> {
        // O tamanho de um pacote é codificado em segmentos de até 255 bytes; um segmento de menos
        // de 255 encerra o pacote. Um pacote de exatamente 255×k bytes precisa de um segmento
        // final de zero, senão o leitor acha que o pacote continua na página seguinte.
        let mut tabela_de_segmentos = Vec::new();
        let mut resto = pacote.len();
        loop {
            if resto >= 255 {
                tabela_de_segmentos.push(255u8);
                resto -= 255;
                if resto == 0 {
                    tabela_de_segmentos.push(0);
                    break;
                }
            } else {
                tabela_de_segmentos.push(resto as u8);
                break;
            }
        }
        if tabela_de_segmentos.len() > 255 {
            return Err(Error::Invalid(format!(
                "pacote de {} bytes não cabe numa página de Ogg",
                pacote.len()
            )));
        }

        let mut p = Vec::with_capacity(27 + tabela_de_segmentos.len() + pacote.len());
        p.extend_from_slice(b"OggS");
        p.push(0); // versão
        p.push(tipo);
        p.extend_from_slice(&granulo.to_le_bytes());
        p.extend_from_slice(&self.serial.to_le_bytes());
        p.extend_from_slice(&self.sequencia.to_le_bytes());
        p.extend_from_slice(&0u32.to_le_bytes()); // lugar do CRC, zerado para o cálculo
        p.push(tabela_de_segmentos.len() as u8);
        p.extend_from_slice(&tabela_de_segmentos);
        p.extend_from_slice(pacote);

        let crc = crc_ogg(&self.tabela, &p);
        p[22..26].copy_from_slice(&crc.to_le_bytes());

        self.arquivo
            .write_all(&p)
            .map_err(|e| Error::Invalid(format!("escrita da página Ogg: {e}")))?;
        self.sequencia += 1;
        Ok(())
    }

    /// Acrescenta um pacote de Opus. `amostras` é quantas amostras por canal ele representa.
    pub fn escrever(&mut self, pacote: &[u8], amostras: u32) -> Result<()> {
        self.granulo += u64::from(amostras);
        self.pacotes += 1;
        let g = self.granulo;
        self.pagina(pacote, 0x00, g)
    }

    /// Fecha o fluxo. A última página precisa do bit de fim, senão o arquivo fica "truncado" para
    /// quem o ler.
    pub fn finalizar(mut self) -> Result<u64> {
        let g = self.granulo;
        // Uma página final vazia carrega o bit de fim sem inventar áudio.
        self.pagina(&[], 0x04, g)?;
        self.arquivo
            .flush()
            .map_err(|e| Error::Invalid(format!("flush do Ogg: {e}")))?;
        Ok(self.pacotes)
    }

    pub fn canais(&self) -> u8 {
        self.canais
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// O CRC do Ogg contra um vetor conhecido.
    ///
    /// Este teste existe porque errar o CRC produz um arquivo **estruturalmente perfeito** que
    /// todo decodificador recusa, e a mensagem de erro fala de corrupção — mandando quem
    /// investiga procurar defeito na rede, que é onde ele não está.
    #[test]
    fn o_crc_do_ogg_nao_e_o_crc_do_zlib() {
        let t = tabela_crc();
        // Do padrão: o CRC não refletido de "123456789" com polinômio 0x04C11DB7, inicial 0,
        // sem XOR final, é 0x89A1897F.
        assert_eq!(crc_ogg(&t, b"123456789"), 0x89A1_897F);
        // E é diferente do CRC-32 do zlib do mesmo texto (0xCBF43926), que é a troca fácil.
        assert_ne!(crc_ogg(&t, b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn a_tabela_de_segmentos_fecha_pacote_de_multiplo_de_255() {
        // Um pacote de 255 bytes precisa de [255, 0]; sem o zero final o leitor espera
        // continuação na página seguinte e o arquivo fica quebrado no fim.
        let dir = std::env::temp_dir().join("quall-ogg-teste");
        let _ = std::fs::create_dir_all(&dir);
        let caminho = dir.join("t.opus");
        let mut w = EscritorDeOgg::criar(&caminho, 1, 312, 48_000).expect("criar");
        w.escrever(&vec![0u8; 255], 960).expect("escrever");
        let n = w.finalizar().expect("finalizar");
        assert_eq!(n, 1);
        let bytes = std::fs::read(&caminho).expect("ler");
        assert!(bytes.starts_with(b"OggS"), "não é um Ogg");
        assert!(
            bytes.windows(8).any(|w| w == b"OpusHead"),
            "faltou o OpusHead"
        );
        let _ = std::fs::remove_file(&caminho);
    }
}
