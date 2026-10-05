#include "quall-obs.h"
#include <quall.h>

OBS_DECLARE_MODULE()
// O idioma (`obs_module_text` e `obs_module_set_locale`) mora em `texto.c`.

MODULE_EXPORT const char *obs_module_name(void)
{
	return "Quall Studio";
}

MODULE_EXPORT const char *obs_module_description(void)
{
	return obs_module_text("Quall.Descricao");
}

static void ao_entrar_em_panico(const char *mensagem, void *ud)
{
	UNUSED_PARAMETER(ud);
	UNUSED_PARAMETER(mensagem);
	// Sem isto, um pânico do núcleo chega como um `SIGABRT` mudo — e o processo que morre é o
	// OBS inteiro, com as cenas do usuário dentro. O diário guarda a ocorrência fatal; o texto
	// opaco do pânico pode conter segredos, nomes ou configuração e não é copiado.
	diga(LOG_ERROR, "PÂNICO do núcleo: falha interna (texto do pânico omitido para privacidade)");
}

bool obs_module_load(void)
{
	quall_install_panic_hook(ao_entrar_em_panico, NULL);
	diga(LOG_INFO, "plugin carregado — protocolo %u, serviço %s", quall_protocol_version(),
	     quall_service_type());
	obs_register_source(&quall_fonte_info);
	descoberta_iniciar();
	return true;
}

void obs_module_unload(void)
{
	descoberta_parar();

	// `quall_cleanup()` solta as threads globais da libdatachannel. O header é explícito: num
	// plugin que é descarregado e recarregado, viver sem ele deixa threads vivas — mas chamá-lo
	// com uma sessão de pé faz o `rtcCleanup()` esperar 10 s, desistir, e deixar presa
	// justamente a thread que impede o processo de morrer.
	//
	// O OBS destrói todas as fontes antes de descarregar o módulo, e cada `destroy` só retorna
	// depois que a sessão dela foi fechada. As "pontes" são o nosso contador de sessões que
	// existiram; o que interessa aqui é que nenhuma fonte sobreviva — e isso o libobs garante.
	long pontes = receptor_pontes_deixadas();
	identidade_soltar();
	// Antes da dívida 24 esta linha dizia quantas pontes ficavam de propósito, uma por sessão, e
	// o `Number of memory leaks` do libobs marcava exatamente esse número. Hoje a barreira do
	// `quall_session_close` autoriza o `bfree`, e o esperado é **zero** nos dois lugares. Se este
	// número não for zero, o diário tem o motivo logo acima, sessão por sessão.
	if (pontes == 0)
		diga(LOG_INFO, "descarregando: nenhuma ponte de sessão ficou para trás — o contador de "
			       "vazamentos do libobs deve mostrar 0");
	else
		diga(LOG_WARNING,
		     "descarregando: %ld ponte(s) de sessão ficaram para trás porque a barreira da "
		     "fronteira C não deu OK — é esse o número que o contador de vazamentos do libobs "
		     "deve mostrar",
		     pontes);
	quall_cleanup();
}
