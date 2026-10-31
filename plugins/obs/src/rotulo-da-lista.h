// **O rótulo de uma linha da lista "Aparelho"** do painel da fonte, a regra pura, sem libobs, para o
// banco de prova `bancada/prova-rotulo-da-lista.c` exercitar com `cc`.
//
// Desde `docs/v3-no-privado.md` §8.7 o anúncio pode trazer o nome que o outro aparelho escolheu para a
// rede (`"announced_name"`). Ele **não autentica nada**: a linha mostra o nome com o código do alias
// entre parênteses ("iPhone 7 (46eb4d0a) · 192.168.15.6"), e o código é o que a espera do outro
// aparelho mostra. Sem nome anunciado (uma build das lojas, o campo apagado), o de antes: só o código.
// O OBS não guarda o nome dos pares; o par reconhecido diz "pareado" na nota.
#pragma once

#include <stddef.h>

/// Escreve em `saida` (até `cap` bytes, sempre terminado em zero):
/// `"<anunciado> (<código>) · <onde>[ (<nao_emite>)][ · <nota>]"`, ou sem o nome anunciado
/// `"<código> · <onde>…"`. `alias` é o `"display_name"` do núcleo (`"Quall 1a2b3c4d"`): o
/// `"Quall "` da frente sai. `anunciado`, `nao_emite` e `nota` podem ser NULL ou vazios.
void rotulo_da_lista(char *saida, size_t cap, const char *alias, const char *anunciado, const char *onde,
		     const char *nao_emite, const char *nota);
