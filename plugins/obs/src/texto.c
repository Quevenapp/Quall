#include "quall-obs.h"

#include <string.h>

// =================================================================================================
// Os textos do plugin: o idioma da interface do OBS, e o diário sempre em português.
//
// Isto é o `OBS_MODULE_USE_DEFAULT_LOCALE` escrito à mão, por duas diferenças:
//
// 1. **Qualquer `pt-*` vira `pt-BR`.** A macro só carrega o arquivo do idioma exato; com o OBS em
//    `pt-PT` não há `pt-PT.ini` aqui, e o plugin caía no inglês ao lado de um OBS em português. O
//    contrato da tradução (`docs/traducao.md`) é o mesmo nas cinco plataformas: `pt-*` → PT,
//    qualquer outro → EN.
// 2. **Um segundo lookup, sempre `pt-BR`, para o diário.** As frases de estado aparecem no painel
//    *e* no diário, e a bancada lê o diário por `grep` ("sessão de pé", "primeira imagem", "o
//    transporte falhou" — `bancada/som-primeiro-obs.sh`, `bancada/pli-corrida-obs.sh`). Um OBS em
//    inglês não pode mudar o que esses roteiros procuram.
//
// O idioma do plugin **segue o do OBS** (Configurações → Geral → Idioma, que o próprio OBS só
// aplica ao reabrir). Não há seletor próprio: ver `docs/traducao.md`, seção OBS.
// =================================================================================================

lookup_t *obs_module_lookup = NULL;
/// O `pt-BR`, para o diário. Criado junto com o do idioma e solto junto com ele.
static lookup_t *lookup_pt = NULL;

const char *obs_module_text(const char *val)
{
	const char *out = val;
	text_lookup_getstr(obs_module_lookup, val, &out);
	return out;
}

bool obs_module_get_string(const char *val, const char **out)
{
	return text_lookup_getstr(obs_module_lookup, val, out);
}

const char *texto_idioma_do_plugin(const char *locale)
{
	if (locale && (locale[0] == 'p' || locale[0] == 'P') && (locale[1] == 't' || locale[1] == 'T') &&
	    (locale[2] == '\0' || locale[2] == '-' || locale[2] == '_'))
		return "pt-BR";
	return locale ? locale : "en-US";
}

void obs_module_set_locale(const char *locale)
{
	if (obs_module_lookup)
		text_lookup_destroy(obs_module_lookup);
	// `en-US` é a base (o que faltar no idioma escolhido sai em inglês), como na macro.
	obs_module_lookup =
		obs_module_load_locale(obs_current_module(), "en-US", texto_idioma_do_plugin(locale));
	if (!lookup_pt)
		lookup_pt = obs_module_load_locale(obs_current_module(), "pt-BR", "pt-BR");
}

void obs_module_free_locale(void)
{
	text_lookup_destroy(obs_module_lookup);
	obs_module_lookup = NULL;
	text_lookup_destroy(lookup_pt);
	lookup_pt = NULL;
}

const char *texto_pt(const char *chave)
{
	const char *out = chave;
	text_lookup_getstr(lookup_pt, chave, &out);
	return out;
}

// -------------------------------------------------------------------------------------------------
// Formatos que vêm de arquivo
//
// As frases de estado têm números e nomes dentro, então o formato do `printf` mora na `.ini`. Um
// formato de dados com `%s` onde o código passa um inteiro derruba o OBS inteiro, com as cenas do
// usuário dentro. `cmake/conferir-locale.cmake` cobra, a cada build, que as duas `.ini` tenham as
// mesmas conversões, chave a chave; isto é a segunda trava, em tempo de execução: se o formato do
// idioma não tiver **exatamente** as conversões do `pt-BR` (que é o texto-fonte, o que o código foi
// escrito para alimentar), vale o `pt-BR`.
// -------------------------------------------------------------------------------------------------

/// As conversões de `f`, sem largura nem precisão: `"%.1f s %ux%u %llu"` → `"f|u|u|llu|"`.
static void assinatura(const char *f, char *out, size_t cap)
{
	size_t n = 0;
	out[0] = '\0';
	for (const char *p = f; p && *p; p++) {
		if (*p != '%')
			continue;
		p++;
		if (*p == '%')
			continue;
		while (*p && strchr("-+ #0123456789.*", *p))
			p++;
		while (*p && strchr("hlLqjzt", *p)) {
			if (n + 1 < cap)
				out[n++] = *p;
			p++;
		}
		if (!*p)
			break;
		if (n + 2 < cap) {
			out[n++] = *p;
			out[n++] = '|';
		}
	}
	out[n < cap ? n : cap - 1] = '\0';
}

const char *texto_formato(const char *chave)
{
	const char *pt = texto_pt(chave);
	const char *local = obs_module_text(chave);
	if (local == pt)
		return pt;
	char a[64], b[64];
	assinatura(pt, a, sizeof a);
	assinatura(local, b, sizeof b);
	return strcmp(a, b) == 0 ? local : pt;
}
