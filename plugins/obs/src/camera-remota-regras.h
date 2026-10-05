// As regras puras do painel "Câmera do aparelho" (R9b, `docs/controle-remoto-da-camera.md` §12):
// sem libobs, para o banco de prova `bancada/prova-camera-remota.c` exercitar com `cc`.
//
// O que mora aqui é o que decide **o que** o painel mostra: os degraus de ISO e do obturador, o
// texto do obturador, os números com o separador do idioma, e de que área do R9 (§4.3) é cada
// campo. **Quais palavras** saem é das `.ini` (`camera-remota.c`): esta parte devolve índices, e o
// texto fica onde a conferência dos textos o vê.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// As quatro áreas do R9 (§4.3), na ordem do painel.
enum area_da_camera {
	AREA_EXPOSICAO = 0,
	AREA_ISO_E_OBTURADOR = 1,
	AREA_BALANCO = 2,
	AREA_FOCO = 3,
	AREA_NENHUMA = 4, // `toque` (o OBS não tem toque na imagem) ou campo que esta build não conhece
};

/// A área de um campo do ajuste (ou de uma chave de `limites`).
enum area_da_camera area_do_campo(const char *campo);

/// **Os degraus de ISO** (R9 §3.2): os terços de stop de 50 a 6400 que cabem em `[min, max]`, mais
/// o `min` e o `max` exatos, mais `atual` (se `tem_atual` e dentro da faixa), sem repetição, em ordem.
/// Devolve quantos escreveu (no máximo `cap`).
size_t degraus_de_iso(double min, double max, bool tem_atual, double atual, int64_t *out, size_t cap);

/// **Os degraus do obturador**, em ns inteiros (o descritor diz `"inteiro":true`, §3.2):
/// - `log2`: 2^v s para todo v inteiro com a duração em `[min, max]` (R9 §3.1, o Windows);
/// - senão: as frações de cinema (1/24 … 1/8000) que cabem, mais `min` e `max` exatos.
/// Mais `atual`, como no ISO. Ordem crescente de duração. Devolve quantos escreveu.
size_t degraus_do_obturador(double min, double max, bool log2, bool tem_atual, double atual,
			    int64_t *out, size_t cap);

/// **O texto do obturador** (R9 §3.1): `1/N s` abaixo de 1 s (N arredondado; no `log2`, a potência
/// exata), e `N s` (com o separador) de 1 s para cima.
void texto_do_obturador(int64_t ns, char separador, char *buf, size_t cap);

/// Um número com `casas` decimais e o `separador` do idioma (vírgula em PT, ponto em EN), sem zeros
/// à direita na parte decimal e sem depender do `LC_NUMERIC` do processo (o OBS é um app Qt, e
/// `printf("%f")` obedece ao locale de quem o chamou).
void numero_com_separador(double v, int casas, char separador, char *buf, size_t cap);

/// **Os metros do foco** (R9 §1): o descritor de `focoPosicao` traz `calibrado`, as dioptrias da
/// posição 1 (o mais perto), só com a lente calibrada. A distância é 1 / (dioptrias × posição).
/// Devolve `false` para o infinito (posição ou dioptrias zero, ou valor que não se lê).
bool metros_do_foco(double dioptrias_em_1, double posicao, double *metros);

/// Iguais para o painel: o mesmo número com folga de arredondamento (o slider do OBS guarda
/// `double`, e o núcleo escreve `800` onde a casca escreveu `800.0`, §3).
bool numeros_iguais(double a, double b);

/// O índice da frase de um código de `limites` (§3.2). A ordem casa com a tabela de chaves em
/// `camera-remota.c`.
enum frase_de_limite {
	LIMITE_FABRICANTE = 0,
	LIMITE_MACOS,
	LIMITE_IOS_CINTILACAO,
	LIMITE_CAMERA_NAO_OFERECE,
	LIMITE_FOCO_FIXO,
	LIMITE_SEM_CALIBRACAO,
	LIMITE_OUTRO_APP,
	LIMITE_OUTRO, // código que esta build não conhece: "Este aparelho não oferece {controle}."
};
enum frase_de_limite frase_do_limite(const char *codigo);
/// A frase do limite leva o `{controle}`? (`ios_cintilacao`, `foco_fixo` e `sem_calibracao` não.)
bool limite_leva_controle(enum frase_de_limite f);

/// A linha que uma recusa mostra (§3.5), por 3 s.
enum frase_de_recusa {
	RECUSA_NADA = 0,       // superado, ocupado, invalido, camera_trocada, nao_pareado, fora_da_imagem, sem_camera
	RECUSA_NAO_PERMITIDO,  // "O aparelho não permite controle remoto da câmera"
	RECUSA_NAO_ACEITOU,    // campo_desconhecido, fora_da_faixa, incoerente: "Este aparelho não aceitou {controle}."
	RECUSA_NAO_APLICOU,    // nao_aplicado e todo código desconhecido
	RECUSA_NAO_RESPONDEU,  // sem_resposta
};
enum frase_de_recusa frase_da_recusa(const char *motivo);

// -------------------------------------------------------------------------------------------------
// Listas de textos no JSON do estado
//
// O `obs_data` do libobs **descarta** lista de textos ao ler JSON (`obs-data.c`: só objeto vira
// item de lista), e o estado traz duas: os `valores` de um descritor (`{"valores":["auto","manual"]}`)
// e o `lido.divergentes`. O núcleo escreve o estado pelo `serde_json` (compacto), mas o leitor abaixo
// não supõe isso: ele anda pelo JSON de verdade (textos com escape, objetos e listas aninhados).
// -------------------------------------------------------------------------------------------------
/// O começo do valor no `caminho` de chaves de objeto (`{"capacidades","controles","foco","valores"}`),
/// ou NULL se algum passo não existe ou não é objeto.
const char *json_procurar(const char *json, const char *const *caminho, size_t n);
/// Lê uma lista de textos simples (sem escape) começando em `valor` (que aponta para `[`), cada um em
/// `out + i * largura`, cortado em `largura - 1` bytes. Devolve quantos escreveu; 0 se não é lista.
size_t json_lista_de_textos(const char *valor, char *out, size_t largura, size_t cap);
/// Quantos bytes tem o valor que começa em `valor` (um objeto inteiro, um texto, um número), ou 0 se
/// ele não se lê. Serve para comparar trechos do estado como texto, sem passar pelo `obs_data`.
size_t json_tamanho_do_valor(const char *valor);
