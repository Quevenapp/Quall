// **Por que uma conexão sem PIN parou** antes do código ou no fim dele (`docs/v3-no-privado.md`
// §3.4, §3.5, §8.1 e §8.3), a regra pura, sem libobs, para o banco de prova
// `bancada/prova-recusa-do-vinculo.c` exercitar com `cc`. É a mesma do Mac
// (`QuallReceptorKit/AparelhosNaRede.swift`, `RecusaDoVinculo`). Desde §8.3 cada uma tem status
// próprio na fronteira; o `PAIRING` genérico não é delas.
#pragma once

#include <stdbool.h>

enum recusa_do_vinculo {
	RECUSA_NENHUMA = 0,
	/// A1 (`QUALL_STATUS_INTERFERENCE`): pernas demais caíram antes de o código chegar à tela.
	RECUSA_INTERFERENCIA,
	/// A2 (`QUALL_STATUS_PAIR_NOT_RECOGNIZED`): o alvo não mostrou a dica do vínculo. Falha fechado;
	/// a saída é "Esquecer este aparelho" (ou um PIN).
	RECUSA_NAO_RECONHECEU,
	/// B2 (`QUALL_STATUS_ALREADY_PAIRED`): o código ou o QR chegou ao fim, mas um dos dois lados já
	/// tem vínculo com o outro.
	RECUSA_JA_PAREADO,
};

/// `status`: o `QuallStatus` da chamada que falhou.
enum recusa_do_vinculo recusa_do_vinculo(int status);

/// A chave da frase (`data/locale/*.ini`), ou NULL para `RECUSA_NENHUMA`.
const char *chave_da_recusa(enum recusa_do_vinculo r);
