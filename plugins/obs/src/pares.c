#include "quall-obs.h"
#include <quall.h>

#include <stdlib.h>
#include <string.h>
#include <errno.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

// O pareamento é chaveado por `DeviceId` (dívida 23): quem pareou uma vez com este OBS não digita
// PIN de novo, nem por outra origem do mesmo aparelho. O preço é este arquivo, e o núcleo já
// oferece a fusão segura — `quall_known_peers_merge` —, então não escrevemos leitura-modificação-
// escrita crua.
static pthread_mutex_t trava = PTHREAD_MUTEX_INITIALIZER;

static char *caminho_de(const char *arquivo)
{
	return obs_module_config_path(arquivo);
}

static void garantir_pasta(void)
{
	char *base = obs_module_config_path("");
	if (base) {
		os_mkdirs(base);
		bfree(base);
	}
}

char *pares_ler(void)
{
	char *c = caminho_de("pares.json");
	if (!c)
		return NULL;
	pthread_mutex_lock(&trava);
	char *conteudo = os_quick_read_utf8_file(c);
	pthread_mutex_unlock(&trava);
	bfree(c);
	return conteudo; // `bmalloc`'d pelo libobs, ou NULL
}

void pares_gravar_fundindo(const char *novo_json)
{
	if (!novo_json || !*novo_json)
		return;
	char *c = caminho_de("pares.json");
	if (!c)
		return;

	pthread_mutex_lock(&trava);
	garantir_pasta();
	char *disco = os_quick_read_utf8_file(c);

	const char *para_gravar = novo_json;
	char *fundido = NULL;
	if (disco && *disco) {
		intptr_t precisa = quall_known_peers_merge(disco, novo_json, NULL, 0);
		if (precisa > 0) {
			fundido = bmalloc((size_t)precisa);
			if (quall_known_peers_merge(disco, novo_json, fundido, (size_t)precisa) > 0)
				para_gravar = fundido;
			else {
				diga(LOG_WARNING, "fusão de pares falhou: status %d: %s", (int)quall_last_status(), registro_causa_status(quall_last_status()));
				bfree(fundido);
				fundido = NULL;
			}
		}
	}

	if (!os_quick_write_utf8_file(c, para_gravar, strlen(para_gravar), false)) {
		int codigo = errno;
		diga(LOG_WARNING, "não consegui gravar os pares na configuração do módulo (errno %d; caminho omitido)", codigo);
	}

	bfree(fundido);
	bfree(disco);
	pthread_mutex_unlock(&trava);
	bfree(c);
}

/// Nome curto desta máquina. `gethostname` é POSIX e não existe no MSVC; `GetComputerNameA` é
/// Win32 e não existe no macOS. O ponto do nome (`.local`) some nos dois — o que vai para o painel
/// é "MacBook-Air", não "MacBook-Air.local".
void identidade_maquina(char *buf, size_t cap)
{
	if (!cap)
		return;
	buf[0] = 0;
#ifdef _WIN32
	DWORD n = (DWORD)cap;
	if (!GetComputerNameA(buf, &n))
		snprintf(buf, cap, "PC");
#else
	if (gethostname(buf, cap - 1) != 0)
		snprintf(buf, cap, "Mac");
	buf[cap - 1] = 0;
#endif
	char *ponto = strchr(buf, '.');
	if (ponto)
		*ponto = 0;
	if (!buf[0])
		snprintf(buf, cap, "desktop");
}

static char *device_id;

const char *identidade_device_id(void)
{
	pthread_mutex_lock(&trava);
	if (!device_id) {
		char *c = caminho_de("identidade.txt");
		char *lido = c ? os_quick_read_utf8_file(c) : NULL;
		if (lido && strlen(lido) >= 8) {
			// tirar quebra de linha, se houver
			size_t n = strlen(lido);
			while (n && (lido[n - 1] == '\n' || lido[n - 1] == '\r'))
				lido[--n] = 0;
			device_id = lido;
		} else {
			bfree(lido);
			char *uuid = os_generate_uuid();
			device_id = bstrdup(uuid);
			bfree(uuid);
			garantir_pasta();
			if (c)
				os_quick_write_utf8_file(c, device_id, strlen(device_id), false);
		}
		bfree(c);
	}
	pthread_mutex_unlock(&trava);
	return device_id;
}

void identidade_soltar(void)
{
	pthread_mutex_lock(&trava);
	bfree(device_id);
	device_id = NULL;
	pthread_mutex_unlock(&trava);
}
