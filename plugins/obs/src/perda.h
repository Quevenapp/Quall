// A perda, em uma linha, com os três números que ela precisa para não mentir.
//
// Até 29/08/2026 este plugin despejava o JSON cru do núcleo a cada 5 s e mais nada. Quem lia
// aquele JSON lia `packets_missing` como perda — e ele **nunca foi perda**: é a soma dos saltos de
// sequência, e uma reordenação de distância `d` entra ali como `1 + d` posições sem que nada tenha
// se perdido. Numa corrida com 486 nele, o emissor tinha entregado 27.779 pacotes e o receptor
// visto 27.729: sumiram **cinquenta**. O erro medido vai de 1,3× a 44×.
//
// A chave passou a se chamar `packets_missing_upper_bound`, e ao lado dela existem
// `packets_lost_for_real` (perda exata, com janela de reordenação de 128 posições) e
// `packets_too_late` (que denuncia quando a própria janela foi curta demais). Este módulo põe os
// três na mesma linha, no mesmo formato das outras três cascas receptoras.
//
// **Por que ele não conhece o `obs_data`.** Compilar o plugin exige os cabeçalhos do `libobs`, que
// esta máquina só tem depois de um clone pela rede. Uma função de formatação que não inclui nada do
// OBS pode ser compilada e **exercitada** sozinha, e é o que `bancada/prova-perda.c` faz. Quem
// converte `obs_data_t` nestes campos é o `receptor.c`, em quatro linhas.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Chave ausente é **ausente**, nunca zero. `obs_data_get_int` devolve 0 tanto para "vale zero"
// quanto para "não existe", e um zero num contador de perda é a afirmação mais perigosa que este
// relatório pode fazer por engano: ela diz "medi e não perdi nada".
struct numero_do_nucleo {
	int64_t v;
	bool tem;
};

struct contadores_de_perda {
	struct numero_do_nucleo exata;  // `packets_lost_for_real`
	struct numero_do_nucleo teto;   // `packets_missing_upper_bound`
	struct numero_do_nucleo tarde;  // `packets_too_late`
	struct numero_do_nucleo vistos; // `packets_seen`
};

// Escreve, em `saida`, algo como:
//
//     perda exata 50 (0,180%) · teto 486 (1,720%) · tarde demais 0 · vistos 27729
//
// Número ausente sai como `?`. `vistos == 0` vira uma frase que diz que não há o que afirmar —
// nenhum pacote chegou, e aí nem "não perdeu nada" pode ser dito. `tarde demais` diferente de zero
// acrescenta o aviso de que a janela foi curta e a perda exata está superestimada nesse tanto.
void formatar_perda(const struct contadores_de_perda *c, char *saida, size_t cap);
