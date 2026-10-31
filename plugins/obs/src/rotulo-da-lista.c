#include "rotulo-da-lista.h"

#include <stdio.h>
#include <string.h>

void rotulo_da_lista(char *saida, size_t cap, const char *alias, const char *anunciado, const char *onde,
		     const char *nao_emite, const char *nota)
{
	if (!saida || cap == 0)
		return;
	// O alias sem o "Quall " da frente: a lista inteira é de aparelhos Quall, e o código que sobra
	// ("1a2b3c4d") é o mesmo que a espera do outro aparelho mostra.
	const char *codigo = alias && *alias ? alias : "?";
	if (strncmp(codigo, "Quall ", 6) == 0 && codigo[6])
		codigo += 6;
	if (!onde)
		onde = "";
	if (anunciado && *anunciado)
		snprintf(saida, cap, "%s (%s) · %s", anunciado, codigo, onde);
	else
		snprintf(saida, cap, "%s · %s", codigo, onde);
	size_t n = strlen(saida);
	if (nao_emite && *nao_emite && n < cap)
		snprintf(saida + n, cap - n, " (%s)", nao_emite);
	n = strlen(saida);
	if (nota && *nota && n < cap)
		snprintf(saida + n, cap - n, " · %s", nota);
}
