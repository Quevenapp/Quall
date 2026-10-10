// SPDX-License-Identifier: GPL-3.0-or-later
// Carrega o plugin pela libobs instalada, com configuração explícita de bancada.
// Não abre o frontend, não cria fontes nem captura mídia. A inicialização do módulo
// abre seu navegador mDNS; o relatório omite a lista de aparelhos pessoais.
// Compilar com MSVC e SDK libobs compatível; executar com binário, recursos
// e uma pasta nova de configuração explícitos. Consulte testar-carregador.ps1.
#include <obs-module.h>
#include <stdarg.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

static unsigned casos, falhas;
static volatile LONG erros_do_diario;

static void confere(const char *nome, bool ok)
{
	casos++;
	printf("%s %s\n", ok ? "PASSOU" : "FALHOU", nome);
	if (!ok)
		falhas++;
}

static void diario(int nivel, const char *formato, va_list args, void *ud)
{
	(void)ud;
	if (nivel <= LOG_ERROR)
		InterlockedIncrement(&erros_do_diario);
	char texto[4096];
	vsnprintf(texto, sizeof texto, formato, args);
	if (strstr(texto, "aparelhos na rede")) {
		fprintf(stderr, "libobs: descoberta atualizou; lista omitida nesta prova\n");
		return;
	}
	if (nivel <= LOG_WARNING || strstr(texto, "[quall]") || strstr(texto, "memory leaks"))
		fprintf(stderr, "libobs: %s\n", texto);
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "uso: prova-compatibilidade <binario> <recursos> <config isolada>\n");
		return 2;
	}
	base_set_log_handler(diario, NULL);
	printf("libobs=%s API=0x%08x headers=0x%08x\n", obs_get_version_string(),
	       obs_get_version(), LIBOBS_API_VER);
	if (!obs_startup("pt-BR", argv[3], NULL)) {
		fprintf(stderr, "obs_startup falhou\n");
		return 2;
	}
	obs_module_t *modulo = NULL;
	int status = obs_open_module(&modulo, argv[1], argv[2]);
	printf("obs_open_module=%d\n", status);
	confere("carregador real aceita o modulo", status == MODULE_SUCCESS && modulo);
	if (modulo && status == MODULE_SUCCESS) {
		const char *traduzido = NULL;
		confere("export publico devolve traducao",
			obs_module_get_locale_string(modulo, "Quall.Fonte", &traduzido) &&
			traduzido && strcmp(traduzido, "Quall Studio (espelhamento da LAN)") == 0);
		obs_set_locale("en-US");
		traduzido = NULL;
		confere("export publico devolve traducao EN",
			obs_module_get_locale_string(modulo, "Quall.Fonte", &traduzido) &&
			traduzido && strcmp(traduzido, "Quall Studio (LAN mirror)") == 0);
		obs_set_locale("pt-PT");
		traduzido = NULL;
		confere("pt-PT usa traducao pt-BR",
			obs_module_get_locale_string(modulo, "Quall.Fonte", &traduzido) &&
			traduzido && strcmp(traduzido, "Quall Studio (espelhamento da LAN)") == 0);
		const char *nome = obs_get_module_name(modulo);
		confere("nome do produto", nome && strcmp(nome, "Quall Studio") == 0);
		char *config = obs_module_get_config_path(modulo, "prova.txt");
		confere("configuracao fica na bancada",
			config && strncmp(config, argv[3], strlen(argv[3])) == 0 &&
			(config[strlen(argv[3])] == '/' || config[strlen(argv[3])] == '\\'));
		bfree(config);
		bool iniciou = obs_init_module(modulo);
		confere("inicializacao do modulo", iniciou);
		if (iniciou) {
			bool encontrou = false;
			const char *id = NULL;
			for (size_t i = 0; obs_enum_input_types(i, &id); i++)
				if (id && strcmp(id, "quall_fonte") == 0)
					encontrou = true;
			confere("id de fonte preservado", encontrou);
			uint32_t flags = obs_get_source_output_flags("quall_fonte");
			confere("fonte declara video assincrono e audio",
				(flags & (OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO)) ==
					(OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO));
			const char *fonte = obs_source_get_display_name("quall_fonte");
			confere("nome traduzido da fonte",
				fonte && strcmp(fonte, "Quall Studio (espelhamento da LAN)") == 0);
            obs_properties_t *props = obs_get_source_properties("quall_fonte");
            obs_property_t *pin = props ? obs_properties_get(props, "pin") : NULL;
            confere("campo PIN usa OBS_TEXT_PASSWORD",
                pin && obs_property_get_type(pin) == OBS_PROPERTY_TEXT &&
                obs_property_text_type(pin) == OBS_TEXT_PASSWORD);
            if (props) obs_properties_destroy(props);
		}
	}
	obs_shutdown();
	confere("nenhum erro no diario libobs", InterlockedCompareExchange(&erros_do_diario, 0, 0) == 0);
	confere("alocacoes libobs liberadas", bnum_allocs() == 0);
	printf("RESULTADO %u conferencias, %u falhas; sem frontend ou fluxo de midia\n", casos, falhas);
	return falhas ? 1 : 0;
}
