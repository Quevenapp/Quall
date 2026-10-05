//  As quatro funções da libopus que o lado que **exibe** precisa, declaradas à mão.
//
//  ## Por que declarar em vez de incluir o `opus.h`
//
//  Não há `opus.h` alcançável deste alvo: a libopus entra no iOS **dentro do `libquall.a`**, pelo
//  crate `quall-opus`, que a vendoriza e compila junto. Medido no arquivo estático desta rodada:
//
//      nm -gU target/aarch64-apple-ios/release/libquall.a | grep -c ' T _opus_'   →  98
//
//  Os símbolos estão lá e são globais — `opus_decoder_create`, `opus_decode`,
//  `opus_decoder_destroy` e `opus_packet_has_lbrr` entre eles. O que não está é o header, porque o
//  crate não instala nada. Declarar as quatro assinaturas aqui é o mesmo recurso que
//  `apps/ios/PortaoOpus/Fontes/atalho_opus.h` já usa neste repositório e que
//  `crates/quall-opus/src/sys.rs` usa do lado Rust: **mesma limitação, mesma solução, linguagem
//  diferente**.
//
//  `opus_int32` e `opus_int16` são `int32_t` e `int16_t` em toda plataforma Apple. Escrevê-los
//  assim evita depender de um typedef que não temos como incluir.
//
//  ## Por que isto pode morar em `Comum/`, que a appex também compila
//
//  Porque **declaração não é código**. O `Ponte.h` é o header-ponte dos dois alvos (um alvo Swift
//  só pode ter um), então não há onde pôr isto que o app veja e a appex não. O que decide o
//  tamanho do binário é a **referência**: a appex não chama nenhuma destas funções, então o `ld`
//  não puxa um objeto sequer da libopus para dentro dela.
//
//  Isso é medido, não suposto — `provar.sh` e `provar-receptor.sh` conferem `_opus_` no
//  `Difusao.appex` junto com os símbolos do decodificador de vídeo, e a guarda reprova o build se
//  algum aparecer. Num processo com teto de jetsam de 50,00 MB, "provavelmente não entra" não é
//  resposta.
//
//  ## O que **não** está aqui, e por quê
//
//  `opus_decoder_ctl` é variádica, e o Swift recusa importar função variádica em C ("Variadic
//  function is unavailable") — foi por isso que o `PortaoOpus` precisou de atalhos em C. O lado
//  que exibe não precisa dela: `docs/audio.md` §13 é explícito em que **`opus_decode` não é
//  configurado por preset nenhum** — a taxa, os canais e o `decode_fec` são argumentos, e é por
//  isso que o núcleo não expõe um decodificador próprio. Sem `ctl`, sem atalho em C, sem alvo
//  novo de build.
#ifndef OPUS_DO_NUCLEO_H
#define OPUS_DO_NUCLEO_H

#include <stdint.h>

typedef struct OpusDecoder OpusDecoder;

/// `Fs` só aceita 8000, 12000, 16000, 24000 ou 48000. O do produto é 48000 e **não é escolha**:
/// a RFC 7587 §4.1 fixa o relógio do Opus em 48 kHz independentemente da taxa interna do encoder.
/// Errar por um fator de 6 não dá erro — dá áudio que acelera ou arrasta, sem contador nenhum
/// acusando.
OpusDecoder *opus_decoder_create(int32_t Fs, int channels, int *error);

/// - `data`/`len`: o pacote. Com `data` nulo e `len` 0, é ocultação de perda (PLC).
/// - `pcm`: `int16` **intercalado**, com espaço para `frame_size * channels` amostras.
/// - `frame_size`: amostras **por canal** que cabem em `pcm`.
/// - `decode_fec`: 1 pede o LBRR do pacote *N+1* para reconstruir o slot *N*.
///
/// Devolve o número de amostras por canal decodificadas, ou um código negativo.
///
/// **A armadilha do `frame_size`**, e ela é a que `crates/quall-probe` documenta: o buffer tem de
/// ter **exatamente** a duração de um quadro. Se fosse maior, a libopus preencheria a diferença
/// com ocultação de perda e só o começo viria do LBRR — sem avisar ninguém.
int opus_decode(OpusDecoder *st,
                const unsigned char *data,
                int32_t len,
                int16_t *pcm,
                int frame_size,
                int decode_fec);

void opus_decoder_destroy(OpusDecoder *st);

/// O pacote carrega LBRR? Existe aqui como **segunda testemunha**: o núcleo já responde isso no
/// `fec_has_lbrr` do slot, e a casca confia nele. Esta função permite conferir, em bancada, que os
/// dois concordam — e `docs/audio.md` §14 registra que nenhum `FEC` de perda real jamais
/// atravessou a fronteira C, então um dia alguém vai querer conferir.
int opus_packet_has_lbrr(const unsigned char *packet, int32_t len);

//  ## As três leituras do byte TOC, e por que elas não são luxo
//
//  O codec negociado vem de `quall_track_audio_codec`, declarado no `quall.h`. DEFAULT nessa
//  consulta significa "não sei"; não é autorização para presumir Opus. O receptor usa o codec
//  adotado do SDP para escolher o preset e o decoder, inclusive PCMU a 8 kHz mono.
//
//  Estas três funções conferem o **formato de uma track já declarada Opus**, sem identificar o
//  codec. Um payload G.711 pode passar pela inspeção do TOC: ele nunca deve chegar aqui. O byte
//  TOC de um pacote Opus carrega a configuração, e lê-lo confere canais e duração:
//
//    * `opus_packet_get_nb_channels` devolve 1 ou 2 — os canais **que estão no pacote**, não os
//      que o preset pediu;
//    * `opus_packet_get_nb_frames` e `opus_packet_get_samples_per_frame` dão, juntos, as amostras
//      por canal do pacote a uma dada taxa — o que confere a duração do quadro contra os 20 ms;
//    * uma resposta negativa recusa o pacote da track Opus com um diagnóstico; não determina
//      que outro codec foi negociado.
//
//  Nenhuma delas é variádica, nenhuma precisa de estado, e todas já estão dentro do `libquall.a`.
int opus_packet_get_nb_channels(const unsigned char *data);
int opus_packet_get_nb_frames(const unsigned char *packet, int32_t len);
int opus_packet_get_samples_per_frame(const unsigned char *data, int32_t Fs);

#endif /* OPUS_DO_NUCLEO_H */
