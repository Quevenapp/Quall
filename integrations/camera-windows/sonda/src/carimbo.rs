//! O relógio que viaja dentro dos pixels — e sobrevive ao H.264.
//!
//! # O problema, e por que há **dois** carimbos nesta frente
//!
//! O carimbo que já existia (`cano::carimbar`) escreve oito bytes crus de `QueryPerformanceCounter`
//! nos pixels. Ele mede host→app perfeitamente **porque o cano não comprime nada**: os bytes que
//! entram saem idênticos. Atravessar um encoder H.264 destrói esse carimbo — H.264 é com perda, e
//! um byte de valor 173 volta 171.
//!
//! Para medir do **emissor** ao app consumidor, o relógio precisa atravessar encode, RTP, rede,
//! decode e escala. A técnica é a que `docs/medir-vidro-a-vidro.md` já decidiu para a campanha
//! filmada, e pelo mesmo motivo: **o relógio viaja dentro do vídeo, então não há relógio para
//! sincronizar**. A diferença é que aqui ninguém filma nada — quem lê é o próprio app consumidor,
//! nos pixels que recebeu.
//!
//! # O desenho
//!
//! Uma faixa de células quadradas de 16x16 pixels, na linha 16 do quadro (abaixo do carimbo de
//! bytes, que ocupa as oito primeiras linhas):
//!
//! | células | conteúdo |
//! |---|---|
//! | 0 | referência **clara** |
//! | 1 | referência **escura** |
//! | 2..34 | 32 bits do relógio, do menos significativo ao mais, claro = 1 |
//! | 34..38 | soma de verificação de 4 bits (XOR dos oito nibbles) |
//!
//! As duas células de referência não são zelo: elas dão o **limiar** medido no próprio quadro, em
//! vez de um número fixo que o encoder, o processador de vídeo e a faixa de cor deslocam. Sem
//! elas seria preciso supor quanto vale "claro" depois de ir e voltar por três conversões — e
//! supor aqui é como se produz um número plausível e errado.
//!
//! A soma de verificação existe porque uma leitura errada não aparece como erro: aparece como uma
//! latência absurda no meio de uma amostra boa, e contamina a média. Quadro que não fecha a soma
//! é **descartado e contado**, nunca corrigido.
//!
//! # O relógio é de 32 bits, e isso é uma escolha
//!
//! `QueryPerformanceCounter` em microssegundos truncado a 32 bits dá a volta a cada 4.295 s
//! (1 h 11 min). Uma corrida de bancada dura segundos; a subtração é feita em aritmética de 32
//! bits, então a volta é tratada de graça. Registrar 64 bits custaria o dobro de células.

/// Lado de cada célula, em pixels. Dezesseis é o tamanho de um macrobloco do H.264: uma célula
/// alinhada a macrobloco é a coisa mais fácil que existe para o encoder preservar.
pub const CELULA: usize = 16;
/// Linha em que a faixa começa. As oito primeiras linhas são do carimbo de bytes do cano.
pub const LINHA: usize = 16;
pub const CELULAS: usize = 2 + 32 + 4;
/// Largura mínima de quadro para a faixa caber.
pub const LARGURA_MINIMA: usize = CELULAS * CELULA;

const CLARO: u8 = 235;
const ESCURO: u8 = 16;

fn verificacao(valor: u32) -> u8 {
    let mut x = 0u8;
    for i in 0..8 {
        x ^= ((valor >> (i * 4)) & 0xF) as u8;
    }
    x & 0xF
}

/// Desenha a faixa num buffer **BGRA** (o formato que o encoder de hardware aceita sem conversão
/// de cor em CPU). `passo` é o número de bytes por linha.
pub fn desenhar_bgra(buf: &mut [u8], passo: usize, valor: u32) {
    let soma = verificacao(valor);
    for celula in 0..CELULAS {
        let claro = match celula {
            0 => true,
            1 => false,
            c if c < 34 => (valor >> (c - 2)) & 1 == 1,
            c => (soma >> (c - 34)) & 1 == 1,
        };
        let v = if claro { CLARO } else { ESCURO };
        for y in LINHA..LINHA + CELULA {
            let base = y * passo + celula * CELULA * 4;
            for x in 0..CELULA {
                let p = base + x * 4;
                buf[p] = v;
                buf[p + 1] = v;
                buf[p + 2] = v;
                buf[p + 3] = 255;
            }
        }
    }
}

/// O que saiu de uma tentativa de leitura da faixa.
///
/// Três resultados, e não dois, porque "não tem faixa" e "tem faixa e não deu para ler" são
/// coisas diferentes que precisam ser contadas separado. A primeira versão devolvia `Option` e o
/// relatório contou **300 recusas em 300 quadros** num vídeo de celular que nunca teve faixa
/// nenhuma — um número alarmante que não queria dizer nada.
#[derive(Debug, PartialEq, Eq)]
pub enum Leitura {
    /// Não há faixa aqui: as células de referência não têm contraste de faixa.
    Ausente,
    /// Há faixa, e a soma de verificação não fechou. **Este** número importa: quer dizer que o
    /// encode ou a escala estão borrando as células.
    Recusada,
    Lida(u32),
}

/// Lê a faixa do plano Y de um quadro NV12. `passo` é a largura em bytes de uma linha do plano Y.
pub fn ler_y(plano_y: &[u8], passo: usize, altura: usize) -> Leitura {
    if passo < LARGURA_MINIMA || altura < LINHA + CELULA {
        return Leitura::Ausente;
    }

    let media = |celula: usize| -> u32 {
        // Só o miolo 8x8 da célula: as bordas são onde o encoder e o processador de vídeo borram,
        // e o miolo é o que sobrevive a uma escala moderada.
        let mut soma = 0u32;
        for y in (LINHA + 4)..(LINHA + 12) {
            let base = y * passo + celula * CELULA + 4;
            for x in 0..8 {
                soma += plano_y[base + x] as u32;
            }
        }
        soma / 64
    };

    let claro = media(0);
    let escuro = media(1);
    if claro <= escuro || claro - escuro < 40 {
        return Leitura::Ausente;
    }
    let limiar = (claro + escuro) / 2;

    let mut valor = 0u32;
    for c in 2..34 {
        if media(c) > limiar {
            valor |= 1 << (c - 2);
        }
    }
    let mut soma = 0u8;
    for c in 34..38 {
        if media(c) > limiar {
            soma |= 1 << (c - 34);
        }
    }
    if soma != verificacao(valor) {
        return Leitura::Recusada;
    }
    Leitura::Lida(valor)
}

#[cfg(test)]
mod testes {
    use super::*;

    /// Ida e volta pelo caminho exato dos dois formatos: desenha em BGRA, converte para Y como o
    /// encoder converteria (faixa limitada, BT.601) e lê de volta.
    #[test]
    fn ida_e_volta_sobrevive_a_faixa_limitada() {
        let largura = 1280usize;
        let altura = 720usize;
        let mut bgra = vec![0u8; largura * altura * 4];
        let valor = 0xDEAD_BEEFu32;
        desenhar_bgra(&mut bgra, largura * 4, valor);

        let mut y = vec![0u8; largura * altura];
        for i in 0..largura * altura {
            let b = bgra[i * 4] as f32;
            let g = bgra[i * 4 + 1] as f32;
            let r = bgra[i * 4 + 2] as f32;
            let luma = 0.299 * r + 0.587 * g + 0.114 * b;
            y[i] = (16.0 + 219.0 * luma / 255.0).round() as u8;
        }
        assert_eq!(ler_y(&y, largura, altura), Leitura::Lida(valor));
    }

    /// Um quadro sem faixa nenhuma tem de dar `Ausente`, não `Recusada`. Ver o doc de [`Leitura`].
    #[test]
    fn quadro_sem_faixa_e_ausente() {
        let largura = 1280usize;
        let altura = 720usize;
        let cinza = vec![120u8; largura * altura];
        assert_eq!(ler_y(&cinza, largura, altura), Leitura::Ausente);
    }

    #[test]
    fn soma_errada_e_recusada() {
        let largura = 1280usize;
        let altura = 720usize;
        let mut bgra = vec![0u8; largura * altura * 4];
        // Valor zero: todas as células de dado e de soma nascem escuras, então acender uma é
        // sempre uma mudança de verdade — com outro valor a célula escolhida podia já estar
        // acesa e o teste passaria sem testar nada.
        desenhar_bgra(&mut bgra, largura * 4, 0);
        let mut y = vec![ESCURO; largura * altura];
        for i in 0..largura * altura {
            y[i] = bgra[i * 4];
        }
        assert_eq!(ler_y(&y, largura, altura), Leitura::Lida(0));
        // Vira um bit de dado sem mexer na soma: a leitura tem de recusar, não devolver o valor
        // errado com cara de bom.
        for yy in LINHA..LINHA + CELULA {
            for xx in 0..CELULA {
                y[yy * largura + 5 * CELULA + xx] = CLARO;
            }
        }
        assert_eq!(ler_y(&y, largura, altura), Leitura::Recusada);
    }
}
