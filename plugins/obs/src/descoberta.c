#include "quall-obs.h"
#include <quall.h>

#include <string.h>

// Um navegador mDNS por módulo. Ver a explicação em `quall-obs.h`.
static QuallBrowser *navegador;
static pthread_t thread;
static volatile bool rodando;
static pthread_mutex_t trava = PTHREAD_MUTEX_INITIALIZER;
static char *cache; // último JSON de aparelhos, `bmalloc`'d

static void *laco(void *nada)
{
	UNUSED_PARAMETER(nada);
	os_set_thread_name("quall-descoberta");
	while (os_atomic_load_bool(&rodando)) {
		// **Bloqueia por esta janela**, e é por isso que a thread existe. Janela curta em laço
		// é o uso que o header recomenda: a lista acumula, não é substituída.
		int32_t total = quall_browser_collect(navegador, 400);
		if (total < 0) {
			diga(LOG_WARNING, "descoberta: status %d: %s", (int)quall_last_status(), registro_causa_status(quall_last_status()));
			continue;
		}
		intptr_t precisa = quall_browser_devices_json(navegador, NULL, 0);
		if (precisa <= 0)
			continue;
		char *b = bmalloc((size_t)precisa);
		if (quall_browser_devices_json(navegador, b, (size_t)precisa) < 0) {
			bfree(b);
			continue;
		}
		pthread_mutex_lock(&trava);
		bool mudou = !cache || strcmp(cache, b) != 0;
		bfree(cache);
		cache = b;
		pthread_mutex_unlock(&trava);
		// O painel mantém a lista completa; o diário confirma a atualização sem publicar nomes,
		// identificadores, IPs ou configuração de outros aparelhos.
		if (mudou)
			diga(LOG_INFO, "aparelhos na rede (%d): lista atualizada; dados dos aparelhos omitidos", total);
	}
	return NULL;
}

void descoberta_iniciar(void)
{
	navegador = quall_browser_start();
	if (!navegador) {
		diga(LOG_ERROR, "não consegui abrir o navegador mDNS: status %d: %s", (int)quall_last_status(), registro_causa_status(quall_last_status()));
		return;
	}
	os_atomic_set_bool(&rodando, true);
	if (pthread_create(&thread, NULL, laco, NULL) != 0) {
		diga(LOG_ERROR, "não consegui criar a thread de descoberta");
		os_atomic_set_bool(&rodando, false);
		quall_browser_stop(navegador);
		navegador = NULL;
	}
}

void descoberta_parar(void)
{
	if (!navegador)
		return;
	os_atomic_set_bool(&rodando, false);
	pthread_join(thread, NULL);
	quall_browser_stop(navegador);
	navegador = NULL;
	pthread_mutex_lock(&trava);
	bfree(cache);
	cache = NULL;
	pthread_mutex_unlock(&trava);
}

char *descoberta_aparelhos_json(void)
{
	pthread_mutex_lock(&trava);
	char *copia = cache ? bstrdup(cache) : NULL;
	pthread_mutex_unlock(&trava);
	return copia;
}
