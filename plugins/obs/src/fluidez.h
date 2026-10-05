// **A distribuição dos intervalos entre apresentações** — o número que faltava para "sem fluidez"
// deixar de ser impressão nesta casca.
//
// É a mesma peça de `apps/windows/src/fluidez.rs`, com o mesmo contrato e a mesma linha, de
// propósito: um script de bancada lê as duas com um parser só, e duas corridas em cascas diferentes
// só podem ser comparadas se o número for o mesmo número.
//
// ## Por que a média não serve, e por que ela existia
//
// A média de `fila→tela` da corrida de 01/09/2026 dava **6,4 ms** e estava **certa**. O usuário
// olhava para a mesma tela e dizia que faltava fluidez, e a média não respondia nada: o pior caso
// daquela corrida era **226 ms**. Média não vê tranco — um segundo com 29 quadros pontuais e um
// buraco de 200 ms tem a mesma média de um segundo regular.
//
// Com o instrumento pronto, o mesmo aparelho (A10s) deu:
//
//     Wi-Fi 2,4 GHz : fluidez_ms=[n=2541 p50=32 p95=115 max=241]  trancos=208
//     cabo USB      : fluidez_ms=[n=2639 p50=34 p95=39  max=83 ]  trancos=0
//
// O `p50` é o mesmo nos dois. **Toda a diferença está na cauda**, e é ela que o olho vê. Um relato
// de centro teria dito que os dois enlaces eram iguais.
//
// ## O intervalo é entre **apresentações**, e nesta casca "apresentar" é publicar para o OBS
//
// Não entre chegadas, não entre decodificações: entre os instantes em que um quadro foi **entregue
// à cena**, por `obs_source_output_video`. É o único ponto do caminho desta casca que corresponde
// ao que sai na composição, e é por isso que ele mede também o custo das políticas daqui — a porta
// que segura o quadro condenado (`struct quadro::segurar`, em `receptor.c`) não chama
// `obs_source_output_video`, então ela aparece aqui como **intervalo maior**, que é exatamente o
// que ela custa e o que precisava ficar visível. Medir chegadas esconderia a porta.
//
// ## **Publicar para o OBS não é pôr na tela, e este cabeçalho não vai fingir que é**
//
// O que esta peça mede é *"a hora em que este quadro foi publicado para o OBS"*. O OBS **compõe e
// renderiza depois**, no ritmo dele: a fonte é assíncrona, o quadro entra numa fila de vídeo do
// próprio OBS e só vira pixel no passo de renderização da cena, que tem o relógio da saída
// (30/60 fps do canvas), o `vsync` do monitor e o custo de todos os outros itens da cena entre ele
// e o vidro. Nada disso está dentro deste número.
//
// Ou seja: **é um piso do que o olho vê, não o que o olho vê.** Um tranco medido aqui aconteceu;
// um intervalo limpo aqui não garante uma tela limpa, porque o OBS pode ter engasgado depois.
// A diferença entre este ponto e o vidro só a bancada mede, com o OBS aberto.
//
// Isto está escrito porque este projeto já pagou uma semana por um número que se apresentava como
// uma coisa e era outra: `packets_missing` nunca foi perda, e nenhuma documentação consertou isso
// depois. Ver `docs/contador-nas-cascas.md`, §§1–2.
//
// ## `trancos` é convenção de comparação, não afirmação perceptual
//
// A 30 fps o orçamento é 33 ms. `trancos` conta os intervalos acima de `FLUIDEZ_TRANCO_MS` — três
// tempos de quadro. **Não** se está afirmando que 100 ms é o limiar em que uma pessoa percebe; o
// que se afirma é que duas corridas com o mesmo emissor e a mesma origem podem ser comparadas por
// esse número. Quem quiser outro corte tem os percentis ao lado, na mesma linha.
//
// ## Por que ele não conhece o `obs_data`
//
// Mesma razão de `perda.h` e de `janela-do-enlace.h`: compilar o plugin exige os cabeçalhos do
// `libobs`, e uma peça que não inclui nada do OBS pode ser compilada e **exercitada** sozinha — é o
// que `bancada/prova-fluidez.c` faz, sem OBS, sem rede e sem aparelho. Quem sabe de qual thread
// isto pode ser chamado, e onde fica o instante da publicação, é o `receptor.c`.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// O corte de `trancos`: três tempos de quadro a 30 fps. Ver a nota acima — é convenção de
/// comparação, e a distribuição completa sai junto para quem quiser outro corte. O corte é
/// **estrito**: exatamente 100 ms não é tranco, um microssegundo acima é. Fixado assim para que a
/// comparação entre duas corridas não dependa de arredondamento.
#define FLUIDEZ_TRANCO_MS 100ull

/// Teto de amostras guardadas. A 30 fps são ~5,5 minutos de sessão; passado isso a distribuição
/// para de crescer em vez de a sessão longa comer memória. Mesmo teto do receptor do Windows.
///
/// **O que passa do teto é dito em voz alta** (`(+N além do teto)` na linha), e não engolido: um
/// `n` que se apresentasse como a sessão inteira estaria mentindo, e — pior — `max` e `trancos`
/// **não** enxergam o que foi descartado. Um buraco de meio segundo que chegue depois da
/// amostra 10.000 não aparece em lugar nenhum a não ser nesse `+N`. É a limitação do teto, e ela
/// tem de ser legível na própria linha.
#define FLUIDEZ_MAXIMO_DE_AMOSTRAS 10000

/// Os intervalos entre apresentações de uma sessão.
///
/// **Sem estado global e sem alocação**, como `janela_do_enlace`: quem chama guarda uma destas
/// dentro da própria sessão. São ~80 KB — o `receptor.c` a põe no `struct sessao`, que é
/// `bzalloc`'d, e não na pilha de thread nenhuma.
struct fluidez {
	/// O instante da apresentação anterior, no relógio de quem chama (`os_gettime_ns`).
	uint64_t anterior_ns;
	/// Falsa até a primeira apresentação. Ver `fluidez_publicou`.
	bool ancorada;
	/// As amostras, em microssegundos. **A ordem não significa nada**: é um conjunto, não uma
	/// série temporal — nada aqui olha para a sequência. É o que autoriza `formatar_fluidez` a
	/// ordenar no lugar em vez de alocar uma cópia.
	uint64_t intervalos_us[FLUIDEZ_MAXIMO_DE_AMOSTRAS];
	size_t n;
	/// Quantas amostras foram descartadas por teto.
	uint64_t descartadas;
};

void fluidez_zerar(struct fluidez *f);

/// Marca que um quadro foi **publicado para o OBS** agora.
///
/// A primeira chamada **só ancora**: não existe intervalo antes do primeiro quadro, e contar o
/// tempo desde a abertura da sessão como se fosse um intervalo poria a subida do ICE e a espera
/// pelo primeiro IDR dentro da distribuição da imagem — uma sessão que demorou 4 s para montar
/// imagem sairia com `max=4000` e um tranco que nunca foi tranco.
///
/// A subtração é **saturante** pela mesma razão de `janela_do_enlace_fechar`: o relógio de quem
/// chama é monotônico, mas um `agora_ns` menor que a âncora viraria um intervalo gigante em
/// `uint64_t`, e um `max` absurdo é pior que um zero.
void fluidez_publicou(struct fluidez *f, uint64_t agora_ns);

/// Quantos intervalos **guardados** passaram de `FLUIDEZ_TRANCO_MS`. O corte é estrito.
uint64_t fluidez_trancos(const struct fluidez *f);

/// Escreve, em `saida`, a linha do diário — o **mesmo** formato do receptor do Windows:
///
///     fluidez_ms=[n=2541 p50=32 p95=115 max=241] trancos=208
///
/// Com descarte por teto, a linha termina em ` (+N além do teto)`. Sem amostra nenhuma ela sai
/// zerada e **não divide por zero**: uma sessão sem quadro não afirma nada, e a linha existe assim
/// mesmo — a ausência é informação.
///
/// **`f` não é `const`, e isso é de propósito**: a função ordena `intervalos_us` no lugar para
/// achar os percentis, em vez de alocar uma cópia de 80 KB a cada 5 segundos. Pode fazer isso
/// porque as amostras são um conjunto (ver o campo). E é seguro contra a thread que publica: ela
/// só escreve em `intervalos_us[n]` e depois incrementa `n`, enquanto esta função lê `n` uma vez e
/// mexe apenas em `[0, n)` — os dois intervalos de índices não se tocam, qualquer que seja a ordem
/// em que as duas coisas aconteçam.
void formatar_fluidez(struct fluidez *f, char *saida, size_t cap);
