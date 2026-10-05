// Lê um JSON de coleção e um `.ini` do OBS **com a própria libobs** do OBS.app, sem abrir o OBS.
//
// A trava da bancada (`conferir-colecao.py`) tinha um leitor próprio em Python, e ele divergia da
// libobs: inteiro maior que int64, `1e400`, `\u0000`, `\ud800` sozinho — a trava lia e a libobs
// não; chave recuada no `user.ini` — a trava lia um valor e a libobs outro (reconferência da S2,
// F2). Cada divergência é um jeito de a trava aprovar uma coleção que o OBS carrega diferente.
// Aqui a pergunta vai a quem responde por ela: a libobs carregada por `dlopen`, só com os
// utilitários `obs_data_*` e `config_*`. Nada de `obs_startup`, nenhum módulo, nenhuma captura.
//
// **Só lê.** Não chama `obs_data_create_from_json_file_safe`, que renomeia o `.bak` por cima do
// principal quando o principal não se lê: quem decide o `.bak` é o chamador, lendo os dois.
//
// uso:
//   ler-libobs <libobs> json <arquivo>
//       VERSAO <versão da libobs>
//       LEU                        e, na linha seguinte, o JSON como a libobs o guardou
//     ou NAO_LEU
//   ler-libobs <libobs> ini <arquivo> <Seção> <Chave> [<Seção> <Chave> ...]
//       VERSAO <versão da libobs>
//       ABRIU <código do config_open>      0 é sucesso
//       <Seção>\t<Chave>\t1\t<valor>       ou <Seção>\t<Chave>\t0\t quando a chave não existe
//
// Sai com 2 se a libobs não carregar ou faltar símbolo: a trava recusa.
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef void *(*f_json)(const char *);
typedef const char *(*f_get_json)(void *);
typedef void (*f_release)(void *);
typedef int (*f_config_open)(void **, const char *, int);
typedef const char *(*f_config_get)(void *, const char *, const char *);
typedef void (*f_config_close)(void *);
typedef void (*f_log)(void (*)(int, const char *, va_list, void *), void *);
typedef const char *(*f_versao)(void);

static void calar(int nivel, const char *formato, va_list args, void *p)
{
	(void)nivel;
	(void)formato;
	(void)args;
	(void)p;
}

static void *simbolo(void *h, const char *nome)
{
	void *s = dlsym(h, nome);
	if (!s) {
		fprintf(stderr, "ler-libobs: a libobs não tem %s\n", nome);
	}
	return s;
}

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "uso: ler-libobs <libobs> json <arquivo> | ini <arquivo> <Seção> <Chave> ...\n");
		return 2;
	}
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		fprintf(stderr, "ler-libobs: dlopen: %s\n", dlerror());
		return 2;
	}
	f_log log = (f_log)simbolo(h, "base_set_log_handler");
	f_versao versao = (f_versao)simbolo(h, "obs_get_version_string");
	if (!log || !versao)
		return 2;
	log(calar, NULL);
	printf("VERSAO %s\n", versao());

	if (strcmp(argv[2], "json") == 0 && argc == 4) {
		f_json criar = (f_json)simbolo(h, "obs_data_create_from_json_file");
		f_get_json como_json = (f_get_json)simbolo(h, "obs_data_get_json");
		f_release soltar = (f_release)simbolo(h, "obs_data_release");
		if (!criar || !como_json || !soltar)
			return 2;
		void *d = criar(argv[3]);
		if (!d) {
			printf("NAO_LEU\n");
			return 0;
		}
		const char *texto = como_json(d);
		printf("LEU\n%s\n", texto ? texto : "{}");
		soltar(d);
		return 0;
	}
	if (strcmp(argv[2], "ini") == 0 && argc >= 4 && (argc - 4) % 2 == 0) {
		f_config_open abrir = (f_config_open)simbolo(h, "config_open");
		f_config_get ler = (f_config_get)simbolo(h, "config_get_string");
		f_config_close fechar = (f_config_close)simbolo(h, "config_close");
		if (!abrir || !ler || !fechar)
			return 2;
		void *c = NULL;
		int r = abrir(&c, argv[3], 0 /* CONFIG_OPEN_EXISTING */);
		printf("ABRIU %d\n", r);
		for (int i = 4; i + 1 < argc; i += 2) {
			const char *v = c ? ler(c, argv[i], argv[i + 1]) : NULL;
			printf("%s\t%s\t%d\t%s\n", argv[i], argv[i + 1], v ? 1 : 0, v ? v : "");
		}
		if (c)
			fechar(c);
		return 0;
	}
	fprintf(stderr, "ler-libobs: comando desconhecido\n");
	return 2;
}
