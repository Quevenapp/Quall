#pragma once

// O som da fonte do Quall no OBS (S5 do `docs/som-no-receptor.md`, §7.3 e §18).
//
// # O desenho, depois da decisão do Pessoa Exemplo de 18/09/2026 (~22h30)
//
// **A imagem espera o som; o som nunca empurra o buffer global de áudio do OBS.** O som é
// publicado com carimbo **direto e adiantado**: cada bloco de 10 ms sai `SOM_ADIANTAMENTO_NS`
// antes da hora dele, na hora do sistema (`os_gettime_ns`, a de todo o OBS). A libobs trata isso
// como direto (a menos de 2 s, `obs-source.c:1584-1588`), empilha os blocos contínuos, e nunca tem
// motivo para aumentar o buffer global — que é de **todas** as fontes, o microfone incluído, e só
// sobe (crítica 14, G2). O carimbo nunca volta para trás e nunca é "reancorado".
//
// A sincronia sai do vídeo: a thread publica o **mapa** (`som_mapa`) — a hora do sistema em que o
// som de uma captura toca —, e a thread de decodificação do vídeo (`receptor.c`) segura cada
// quadro até o tique do OBS mais perto da hora do som da mesma captura. Com o `sem_buffer` (o
// padrão da fonte), é o plugin quem decide quando cada quadro aparece. O custo é a imagem mais
// tarde, e ele está no §7.3.
//
// # Uma thread por receptor, e não por sessão (crítica 14, M1)
//
// Entre sessões a thread publica silêncio com o carimbo contínuo. Sem isso, a fonte ficava mais de
// 2 s sem som numa reconexão, e a libobs rebaseava o primeiro bloco da sessão nova para a hora da
// chegada — a sessão inteira saía deslocada pelo adiantamento, sem ninguém ver.
//
// Quem chama o quê:
// - a `laco` (a dona das sessões) cria o som na primeira track de som, liga e solta a porta de cada
//   sessão, e relata; o `receptor_destruir` fecha;
// - a thread do som é a única que puxa e decodifica;
// - a thread de decodificação do vídeo lê o mapa.

#include "quall-obs.h"

#include <quall.h>

struct som;

/// Quanto antes da hora dele cada bloco é publicado. É a folga contra a thread atrasar: a libobs
/// precisa do bloco no tique que o contém, e um bloco que chega tarde deixa a fonte pendente um
/// tique (o som inteiro passa a tocar 21 ms depois, crítica 14, M2). Custa o mesmo tanto de
/// latência de imagem.
#define SOM_ADIANTAMENTO_NS 20000000ull

/// Cria o som da fonte e sobe a thread, que publica silêncio até uma porta ser ligada. `NULL` só
/// quando a thread não sobe.
struct som *som_criar(obs_source_t *fonte);
/// Liga a track de som de uma sessão: abre a porta puxada e o decodificador. `false` com o motivo:
/// a fonte segue com silêncio.
bool som_ligar(struct som *s, QuallTrack *audio, char *motivo, size_t cap);
/// Solta a porta da sessão (com a barreira da porta puxada). **Antes** de `quall_track_free` da
/// track de som. A thread segue publicando silêncio.
void som_soltar(struct som *s);
/// O mapa do som, para o vídeo: `hora_ns = captura_us * 1000 + *desvio_ns` é a hora do sistema em
/// que o som da captura `captura_us` (na base da track de som) toca. `false` sem porta, ou sem um
/// bloco mapeado há mais de 500 ms (o som ocioso: o D2 deu o som a outro receptor).
bool som_mapa(struct som *s, int64_t *desvio_ns);
/// Uma linha de relato, com o JSON da porta.
void som_relatar(struct som *s, char *buf, size_t cap);
/// Para a thread e solta tudo. Do `receptor_destruir`.
void som_fechar(struct som *s);
