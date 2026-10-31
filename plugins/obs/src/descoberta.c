#include "quall-obs.h"
#include <quall.h>

#include <string.h>

// Um navegador mDNS por módulo. Ver a explicação em `quall-obs.h`.
static QuallBrowser *navegador;
static pthread_t thread;
static volatile bool rodando;
static pthread_mutex_t trava = PTHREAD_MUTEX_INITIALIZER;
static char *cache; // último JSON de aparelhos, `bmalloc`'d
/// Os pares mudaram desde a última `quall_browser_set_known` (começa verdadeiro: a primeira volta dá).
static volatile bool pares_mudaram = true;
/// O "Atualizar lista" pediu uma varredura (`docs/v3-no-privado.md` §8.9).
static volatile bool varrer_de_novo = false;

void descoberta_pares_mudaram(void)
{
	os_atomic_set_bool(&pares_mudaram, true);
}

void descoberta_procurar_de_novo(void)
{
	os_atomic_set_bool(&varrer_de_novo, true);
}

/// **Os pares conhecidos, para a lista dizer quem é quem** (`docs/v3-no-privado.md` §5.4): o núcleo
/// sonda cada item novo uma vez e marca `known_device_id` no que casar. Só `me` e
/// `known_peers_json` são lidos.
static void dar_os_pares(void)
{
	char *pares = pares_ler();
	struct QuallSessionOptions op = {
		.me = {.device_id = identidade_device_id(), .display_name = "OBS", .sink = true},
		.pin = NULL,
		.known_peers_json = pares ? pares : "",
		.signaling_port = 0,
		.timeout_ms = 0,
		.tracks = NULL,
		.track_count = 0,
		.bind_address = NULL,
	};
	if (quall_browser_set_known(navegador, &op, NULL) != 0)
		diga(LOG_WARNING, "descoberta: os pares não foram dados à lista: status %d: %s",
		     (int)quall_last_status(), registro_causa_status(quall_last_status()));
	bfree(pares);
}

static void *laco(void *nada)
{
	UNUSED_PARAMETER(nada);
	os_set_thread_name("quall-descoberta");
	while (os_atomic_load_bool(&rodando)) {
		if (os_atomic_exchange_bool(&pares_mudaram, false))
			dar_os_pares();
		if (os_atomic_exchange_bool(&varrer_de_novo, false)) {
			if (quall_browser_rescan(navegador) == 0)
				diga(LOG_INFO, "descoberta: procurando de novo na rede (varredura da /24)");
		}
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

char *descoberta_par_conhecido(const char *endpoint)
{
	if (!endpoint || !*endpoint)
		return NULL;
	char *json = descoberta_aparelhos_json();
	if (!json)
		return NULL;
	struct dstr embrulho = {0};
	dstr_printf(&embrulho, "{\"lista\":%s}", json);
	bfree(json);
	obs_data_t *raiz = obs_data_create_from_json(embrulho.array);
	dstr_free(&embrulho);
	if (!raiz)
		return NULL;
	char *achado = NULL;
	obs_data_array_t *lista = obs_data_get_array(raiz, "lista");
	size_t n = obs_data_array_count(lista);
	for (size_t i = 0; i < n && !achado; i++) {
		obs_data_t *ap = obs_data_array_item(lista, i);
		const char *ponta = obs_data_get_string(ap, "endpoint");
		const char *id = obs_data_get_string(ap, "known_device_id");
		if (ponta && strcmp(ponta, endpoint) == 0 && id && *id && !obs_data_get_bool(ap, "own"))
			achado = bstrdup(id);
		obs_data_release(ap);
	}
	obs_data_array_release(lista);
	obs_data_release(raiz);
	return achado;
}

char *descoberta_aparelhos_json(void)
{
	pthread_mutex_lock(&trava);
	char *copia = cache ? bstrdup(cache) : NULL;
	pthread_mutex_unlock(&trava);
	return copia;
}
