// O dano do enlace numa **janela**, e não desde o começo da sessão — o caminho de volta do sinal.
//
// Todo contador de recepção deste projeto é acumulado desde o início: `packets_seen`,
// `packets_lost_for_real`, `idrs_broken`, e o `suspeitos` que esta casca conta sozinha. Isso é
// certo para o relato final e é inútil para decidir alguma coisa **agora** — uma sessão que perdeu
// 8 % nos primeiros dez segundos e nada depois continua dizendo 8 % meia hora adiante. Quem escuta
// o enlace precisa da derivada, não da integral.
//
// ## Por que esta peça existe no plugin do OBS, e por que ela não existia
//
// O controlador de taxa do emissor (`quall_core::taxa`) é alimentado por
// `quall_session_report_link`, que **o receptor** chama. Sem esta peça, uma casca receptora nunca
// manda amostra e o controlador do outro lado é inerte por construção — não "desligado", inerte:
// ele roda e não tem o que ler. Foi o que a bancada mediu em 31/08/2026 no par A10s → iPad, com o
// controlador ligado por padrão: `trocas_de_bitrate=0` com 2,95 % de perda e 881 quadros exibidos
// com a referência quebrada, porque o relato existia **só** na casca Android.
//
// É a mesma peça do Android (`JanelaDoEnlace.kt`) e do iOS (`JanelaDoEnlace.swift`), com a mesma
// forma e os mesmos cinco nomes, de propósito: um controlador alimentado por um número diferente
// do que a bancada mediu é um controlador projetado contra outra curva.
//
// ## O denominador vem do emissor, e isso não é detalhe
//
// `pacotes` é `vistos + perdidos`, que é **o que o emissor mandou** na janela — os dois termos
// saem de números de sequência RTP, que são contíguos. Dividir a perda pelo que **chegou**
// responde outra pergunta, e o viés não é constante: numa medição desta bancada ele inverteu a
// ordem entre dois braços da matriz e o laudo já estava escrito.
//
// `perdidos` é `packets_lost_for_real` e **nunca** `packets_missing_upper_bound`. O teto cobra
// reordenação como perda, com erro medido de 1,3× a 44× (ver `perda.h`); um controlador alimentado
// por ele reduziria o bitrate por causa de pacotes que chegaram.
//
// ## Contador que anda para trás é track recriada, não perda negativa
//
// Os deltas usam subtração **saturante**. Contador de núcleo não regride, mas uma casca que assume
// isso e erra publica um número absurdo em vez de um zero — e um delta negativo alimentando um
// controlador é como se sobe o bitrate exatamente quando não se deve. Uma janela zerada custa meio
// segundo de silêncio; uma janela absurda custa a decisão.
//
// ## Por que ele não conhece o `obs_data`
//
// Mesma razão de `perda.h`: compilar o plugin exige os cabeçalhos do `libobs`, e uma peça que não
// inclui nada do OBS pode ser compilada e **exercitada** sozinha — é o que
// `bancada/prova-janela-do-enlace.c` faz, sem aparelho e sem rede. Quem converte `obs_data_t`
// nestes campos, e quem sabe de qual thread isto pode ser chamado, é o `receptor.c`.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Uma janela fechada. **Todos os campos são deltas da janela**, exceto `ms`; nenhum é acumulado
// desde o começo da sessão. Os cinco nomes são os do contrato de `quall_session_report_link` e são
// literais.
struct amostra_do_enlace {
	/// Duração **real** da janela, em ms. Nunca a nominal: esta peça é chamada de um laço que
	/// acorda quando acorda, e dividir pelo período nominal daria uma taxa sistematicamente alta.
	uint64_t ms;
	/// O que o emissor mandou nesta janela: `vistos + perdidos`. Ver o cabeçalho.
	uint64_t pacotes;
	/// Perda **exata** (`packets_lost_for_real`), não o teto `packets_missing_upper_bound`.
	uint64_t perdidos;
	/// Quadros publicados com a cadeia de referência condenada — contador **desta casca**.
	uint64_t suspeitos;
	/// `idrs_broken` do núcleo: IDR que começou a chegar e foi destruído no caminho.
	uint64_t idrs_quebrados;
};

// A âncora da janela aberta. Sem estado global e sem alocação: quem chama guarda uma destas na
// pilha do laço que é dono da sessão.
struct janela_do_enlace {
	uint64_t aberta_em_ns;
	uint64_t vistos, perdidos, suspeitos, idrs_quebrados;
	bool ancorada;
};

void janela_do_enlace_zerar(struct janela_do_enlace *j);

// Fecha a janela se ela já durou `periodo_ms`, escreve a **derivada** em `saida` e reancora.
//
// Devolve `false` — e não escreve em `saida` — em três casos, e nenhum deles é erro:
//
//  1. **a primeira chamada**, que só ancora. Os acumulados de uma sessão que já rodou meio segundo
//     antes de a primeira janela abrir não são dano desta janela: uma primeira janela contando
//     desde zero mediria o arranque da sessão (o primeiro IDR, a subida do ICE) como se fosse
//     regime, e o controlador do outro lado veria uma perda que já tinha passado;
//  2. **a janela ainda não fechou** (`decorrido < periodo_ms`);
//  3. `periodo_ms == 0`, que não é janela nenhuma.
bool janela_do_enlace_fechar(struct janela_do_enlace *j, uint64_t agora_ns, uint64_t periodo_ms,
			     uint64_t vistos_acum, uint64_t perdidos_acum, uint64_t suspeitos_acum,
			     uint64_t idrs_quebrados_acum, struct amostra_do_enlace *saida);

// Escreve, em `saida`, a linha do diário — o **mesmo** formato das cascas Android e iOS, para que
// um script de bancada leia as três com um parser só:
//
//     janela_do_enlace ms=502 pacotes=1000 perdidos=30 (3.00%) suspeitos=2 idrs_quebrados=1
//
// `pacotes == 0` sai como `0.00%`: sem nada no ar, não há taxa a afirmar, e a janela existe assim
// mesmo — um meio segundo em que o emissor não mandou nada é informação.
void formatar_janela_do_enlace(const struct amostra_do_enlace *a, char *saida, size_t cap);
