// Ver `recusa-do-vinculo.h`.
#include "recusa-do-vinculo.h"

#include <quall.h>

enum recusa_do_vinculo recusa_do_vinculo(int status)
{
	switch (status) {
	case QUALL_STATUS_INTERFERENCE:
		return RECUSA_INTERFERENCIA;
	case QUALL_STATUS_PAIR_NOT_RECOGNIZED:
		return RECUSA_NAO_RECONHECEU;
	case QUALL_STATUS_ALREADY_PAIRED:
		return RECUSA_JA_PAREADO;
	default:
		return RECUSA_NENHUMA;
	}
}

const char *chave_da_recusa(enum recusa_do_vinculo r)
{
	switch (r) {
	case RECUSA_INTERFERENCIA:
		return "Quall.Estado.Interferencia";
	case RECUSA_NAO_RECONHECEU:
		return "Quall.Estado.NaoReconheceu";
	case RECUSA_JA_PAREADO:
		return "Quall.Estado.JaPareado";
	case RECUSA_NENHUMA:
		break;
	}
	return NULL;
}
