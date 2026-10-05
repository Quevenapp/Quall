// SPDX-License-Identifier: GPL-3.0-or-later
// Regressão da implementação usada pelo sink: C puro, sem OBS, rede, aparelho ou dados do usuário.
// cc -std=c17 -Wall -Wextra -Werror -Icrates/quall-ffi/include \
//    plugins/obs/bancada/prova-registro-seguro.c -o /tmp/prova-registro-seguro
// /tmp/prova-registro-seguro
// Não prova carregamento do plugin, logs de vendors, runtime Windows nem anonimato de texto livre.
#ifdef QUALL_PROVAR_SINK
#include "../src/quall-obs.h"
#else
#include "../src/registro-seguro.h"
#endif

#include <limits.h>
#include <stdlib.h>

static unsigned casos, falhas;

#ifdef QUALL_PROVAR_SINK
// Substitui apenas o destino final. Nem linka libobs nem chama obs_startup/GUI/rede.
static char ultima_linha[4600];
static int ultimo_nivel;
void blog(int nivel, const char *formato, ...)
{
	ultimo_nivel = nivel;
	va_list ap;
	va_start(ap, formato);
	vsnprintf(ultima_linha, sizeof ultima_linha, formato, ap);
	va_end(ap);
}
#endif

static void conferir(const char *nome, bool ok)
{
	casos++;
	if (!ok)
		falhas++;
	printf("%s %s\n", ok ? "PASSOU" : "FALHOU", nome);
}

static void texto(const char *nome, const char *entrada, const char *esperado)
{
	char saida[4096];
	registro_sanitizar(entrada, saida, sizeof saida);
	conferir(nome, strcmp(saida, esperado) == 0);
	// Não imprimir entrada/saída em falha: o próprio teste não deve ensinar a expor uma mensagem.
}

static void sem_valor(const char *nome, const char *entrada, const char *proibido, const char *preservado)
{
	char saida[4096];
	registro_sanitizar(entrada, saida, sizeof saida);
	conferir(nome, strstr(saida, proibido) == NULL && (!preservado || strstr(saida, preservado)));
}

int main(void)
{
	texto("status e causa de erro", "quall_session_close status -3: transporte fechado",
	      "quall_session_close status -3: transporte fechado");
	texto("causa de pareamento sem PIN", "não conectou: pareamento: o PIN não confere",
	      "não conectou: pareamento: o PIN não confere");
	texto("tempos e percentis", "sessão de pé em 1200 ms (pareamento novo, por PIN); primeira imagem 42 ms",
	      "sessão de pé em 1200 ms (pareamento novo, por PIN); primeira imagem 42 ms");
	texto("métricas com colchetes", "frames_ready=123456 idrs_broken=7 fluidez_ms=[n=900 p50=33 p95=40 max=500] trancos=2",
	      "frames_ready=123456 idrs_broken=7 fluidez_ms=[n=900 p50=33 p95=40 max=500] trancos=2");
	texto("HRESULT e OSStatus", "MFStartup falhou: 0x80004005; VideoToolbox: OSStatus -12909",
	      "MFStartup falhou: 0x80004005; VideoToolbox: OSStatus -12909");
	texto("versão e taxa", "plugin 0.1.0 protocolo 7; decode 3.70 ms; 29.97 fps",
	      "plugin 0.1.0 protocolo 7; decode 3.70 ms; 29.97 fps");
	texto("nome de decoder", "MFT de decode escolhido: \"Microsoft H264 Video Decoder MFT\" (entre 3 candidato(s))",
	      "MFT de decode escolhido: \"Microsoft H264 Video Decoder MFT\" (entre 3 candidato(s))");

	sem_valor("PIN nomeado", "não conectou status=-2 pin=654321", "654321", "status=-2");
	sem_valor("PIN sem sinal", "falhou PIN 654321 status=-2", "654321", "status=-2");
	sem_valor("chave genérica", "falhou key=chave-sintetica status=-2", "chave-sintetica", "status=-2");
	sem_valor("private_key", "erro private_key=chave-privada-sintetica status=-3", "chave-privada-sintetica", "status=-3");
	sem_valor("private-key em maiúscula", "erro PRIVATE-KEY=chave-privada-sintetica status=-3", "chave-privada-sintetica", "status=-3");
	sem_valor("segredo de sessão", "falhou session_secret=segredo-sintetico status=-4", "segredo-sintetico", "status=-4");
	sem_valor("token", "erro access_token=token-sintetico codigo=403", "token-sintetico", "codigo=403");
	sem_valor("senha com espaços", "falhou senha=frase secreta sintética status=-2", "secreta", "status=-2");
	sem_valor("valor com escapes", "falhou private_key=\"chave \\\"sintética\\\" final\" status=-3", "sintética", "status=-3");
	sem_valor("PIN após newline", "falhou pin=\n\t654321 status=-2", "654321", "status=-2");
	sem_valor("chave entre aspas", "falhou \"private_key\": \"chave-sintetica\" status=-3", "chave-sintetica", "status=-3");
	sem_valor("nome com espaços", "erro name=Pessoa Sintética status=-2", "Sintética", "status=-2");
	sem_valor("nome entre aspas", "erro display_name=\"Pessoa Sintética\" status=-2", "Sintética", "status=-2");
	sem_valor("identificador do aparelho", "erro device_id=identificador-sintetico status=-2", "identificador-sintetico", "status=-2");
	sem_valor("hostname", "erro hostname=maquina-sintetica.local status=-2", "maquina-sintetica", "status=-2");
	sem_valor("email nomeado", "erro email=pessoa@example.invalid status=-2", "example.invalid", "status=-2");
	sem_valor("JSON de configuração", "falhou status=-4 pedido={\"pin\":\"654321\",\"private_key\":\"secreto\",\"name\":\"Pessoa Sintética\"}", "654321", "status=-4");
	sem_valor("JSON aninhado e aspas", "status=-4 pedido={\"nested\":[{\"name\":\"Pessoa \\\"Sintética\\\"\",\"token\":\"oculto\"}]} fim=1", "oculto", "fim=1");
	sem_valor("lista JSON com espaços", "aparelhos [ {\"name\":\"Pessoa Sintética\",\"ip\":\"192.0.2.8\"} ] total=1", "Sintética", "total=1");
	sem_valor("JSON truncado", "status=-4 pedido={\"pin\":\"654321", "654321", "status=-4");
	sem_valor("JSON malformado fecha barreira", "status=-4 pedido={\"pin\":\"654321\"] segredo-sintetico", "segredo-sintetico", "status=-4");
	sem_valor("PEM", "erro: -----BEGIN PRIVATE KEY-----\nchave-sintetica\n-----END PRIVATE KEY----- status=-3", "chave-sintetica", "status=-3");
	sem_valor("IPv4 e porta", "conectar 192.0.2.8:7000 status=-2", "192.0.2.8", "status=-2");
	sem_valor("IPv4 no loopback", "conectar 127.0.0.1:7000 status=-2", "127.0.0.1", "status=-2");
	sem_valor("IPv6 com porta", "conectar [2001:db8::1234]:7000 status=-2", "db8", "status=-2");
	sem_valor("IPv6 link-local e escopo", "conectar fe80::1234%en99 status=-2", "1234%en99", "status=-2");
	sem_valor("IPv6 loopback", "conectar ::1 status=-2", "::1", "status=-2");
	sem_valor("IPv6 não especificado", "bind :: status=-2", "::", "status=-2");
	sem_valor("caminho POSIX", "open /Users/pessoa-exemplo Sintética/config/pares.json: Permission denied (13)", "Sintética", "Permission denied (13)");
	sem_valor("caminho Windows", "open C:\\Users\\Pessoa Sintética\\config\\pares.json: Permission denied (13)", "Sintética", "Permission denied (13)");
	sem_valor("caminho UNC", "open \\\\servidor-sintetico\\Pessoa Sintética\\pares.json: Access denied (5)", "servidor-sintetico", "Access denied (5)");
	sem_valor("URL com credencial", "erro https://pessoa:senha@example.invalid/cfg?key=secreto status=403", "senha", "status=403");
	sem_valor("WebSocket com credencial", "erro wss://pessoa:senha@example.invalid/cfg?key=secreto status=403", "senha", "status=403");
	sem_valor("WebSocket local", "erro ws://192.0.2.8/cfg?key=secreto status=403", "secreto", "status=403");
	sem_valor("PSK", "erro psk=segredo-sintetico status=5", "segredo-sintetico", "status=5");
	sem_valor("ICE pwd/ufrag", "erro pwd=segredo-sintetico ufrag=identificador-sintetico status=5", "sintetico", "status=5");
	sem_valor("nonce/mac", "erro nonce=nonce-sintetico mac=mac-sintetico status=6", "sintetico", "status=6");
	sem_valor("authkey/sharedkey", "erro authkey=chave-sintetica shared_key=segredo-sintetico status=6", "sintetico", "status=6");
	sem_valor("uid/signingid", "erro uid=id-sintetico signing_id=assinatura-sintetica status=6", "sintetic", "status=6");
	texto("controle não injeta linhas", "erro\n\r\tstatus=-3\033[erro]", "erro   status=-3 [erro]");
	texto("mensagem nula", NULL, "(mensagem indisponível)");
	texto("mensagem vazia", "", "");

	char numero[256], seguro[256];
	registro_formatar_numero(numero, sizeof numero, "idrs_broken", true, false, false, 7, 0);
	registro_sanitizar(numero, seguro, sizeof seguro);
	conferir("IDR quebrado preservado", strcmp(seguro, "idrs_broken=7") == 0);
	registro_formatar_numero(numero, sizeof numero, "packets_seen", true, false, false, INT64_MAX, 0);
	registro_sanitizar(numero, seguro, sizeof seguro);
	conferir("contador grande preservado", strcmp(seguro, "packets_seen=9223372036854775807") == 0);
	registro_formatar_numero(numero, sizeof numero, "frames_dropped", true, false, false, 0, 0);
	conferir("zero medido preservado", strcmp(numero, "frames_dropped=0") == 0);
	registro_formatar_numero(numero, sizeof numero, "jitter_us", true, true, false, 0, 0);
	conferir("jitter não medido mantém null", strcmp(numero, "jitter_us=null") == 0);
	registro_formatar_numero(numero, sizeof numero, "jitter_us", false, false, false, 0, 0);
	conferir("métrica ausente separada de null", strcmp(numero, "jitter_us=ausente") == 0);
	registro_formatar_numero(numero, sizeof numero, "clock.capture_offset_us", true, false, false, -123456, 0);
	registro_sanitizar(numero, seguro, sizeof seguro);
	conferir("deslocamento negativo preservado", strcmp(seguro, "clock.capture_offset_us=-123456") == 0);
	double drift = -0.12345678901234567;
	registro_formatar_numero(numero, sizeof numero, "clock.inter_track_drift_ppm", true, false, true, 0, drift);
	registro_sanitizar(numero, seguro, sizeof seguro);
	const char *igual = strchr(seguro, '=');
	conferir("precisão do double preservada", igual && strtod(igual + 1, NULL) == drift);
	texto("clock e buffer não medidos", "núcleo: frames_ready=20 clock=null jitter_buffer=null",
	      "núcleo: frames_ready=20 clock=null jitter_buffer=null");
	conferir("estado pending", strcmp(registro_estado_relogio("pending"), "pending") == 0);
	conferir("estado valid", strcmp(registro_estado_relogio("valid"), "valid") == 0);
	conferir("estado refused", strcmp(registro_estado_relogio("refused"), "refused") == 0);
	conferir("estado desconhecido não copia texto", strcmp(registro_estado_relogio("name=Pessoa Sintética"), "indisponivel") == 0);
	conferir("causa de relógio conhecida", strcmp(registro_motivo_relogio("a taxa do relógio RTP desta track não divide 720 000 Hz"), "taxa_nao_suportada") == 0);
	conferir("guarda recusada categorizada", strcmp(registro_motivo_relogio("o relógio desta track e o da referência se separaram: resíduo de 55 µs"), "guarda_recusada") == 0);
	conferir("causa desconhecida não copia texto", strstr(registro_motivo_relogio("Pessoa Sintética token=secreto"), "Sintética") == NULL);
	conferir("PIN errado distinto de novo PIN", strcmp(registro_causa_status(QUALL_STATUS_WRONG_PIN),
		 registro_causa_status(QUALL_STATUS_NEEDS_PIN)) != 0);
	conferir("pareamento distinto de PIN errado", strcmp(registro_causa_status(QUALL_STATUS_PAIRING),
		 registro_causa_status(QUALL_STATUS_WRONG_PIN)) != 0);
	conferir("sem rota distinto de IO", strcmp(registro_causa_status(QUALL_STATUS_NO_ROUTE),
		 registro_causa_status(QUALL_STATUS_IO)) != 0);
	conferir("status fechado mantém causa", strcmp(registro_causa_status(QUALL_STATUS_CLOSED), "objeto ou sessão fechado") == 0);
	conferir("status desconhecido explicita omissão", strcmp(registro_causa_status((enum QuallStatus)9999),
		 "causa não classificada (texto interno omitido)") == 0);
	registro_formatar_motivo_som("a porta puxada não abriu: segredoOpacoSemRotulo", seguro, sizeof seguro);
	conferir("falha de som não ecoa segredo opaco", strstr(seguro, "segredoOpacoSemRotulo") == NULL &&
		 strstr(seguro, "porta de áudio indisponível") != NULL);
	registro_formatar_motivo_som("o preset da track não é JSON: Pessoa Sintética 654321", seguro, sizeof seguro);
	conferir("preset inválido não ecoa conteúdo", strstr(seguro, "654321") == NULL &&
		 strstr(seguro, "preset de áudio inválido") != NULL);
	registro_formatar_motivo_som("falha sem rótulo segredoOpacoSemRotulo", seguro, sizeof seguro);
	conferir("motivo de som desconhecido é omitido", strstr(seguro, "segredoOpacoSemRotulo") == NULL &&
		 strstr(seguro, "falha de áudio não classificada") != NULL);
	registro_formatar_motivo_som("preset fora do que este plugin toca: 44100 Hz × 3, 880 por quadro", seguro, sizeof seguro);
	conferir("preset numérico mantém parâmetros", strcmp(seguro,
		 "preset de áudio não suportado: sample_rate_hz=44100 channels=3 frame_samples=880") == 0);
	registro_formatar_motivo_som("preset fora do que este plugin toca: 44100 Hz × 3, 880 por quadro segredoOpacoSemRotulo", seguro, sizeof seguro);
	conferir("preset com sufixo desconhecido não ecoa", strstr(seguro, "segredoOpacoSemRotulo") == NULL);

#ifdef QUALL_PROVAR_SINK
	diga(LOG_WARNING, "falha status %d: %s", (int)QUALL_STATUS_WRONG_PIN, registro_causa_status(QUALL_STATUS_WRONG_PIN));
	conferir("sink real mantém nível e código", ultimo_nivel == LOG_WARNING && strstr(ultima_linha, "[quall] falha status 15: PIN não confere"));
	diga(LOG_ERROR, "falha status=5 pin=654321; pedido=%s", "{\"name\":\"Pessoa Sintética\",\"private_key\":\"opaco\"}");
	conferir("sink real elimina PIN e JSON", ultimo_nivel == LOG_ERROR && strstr(ultima_linha, "654321") == NULL &&
		 strstr(ultima_linha, "Sintética") == NULL && strstr(ultima_linha, "opaco") == NULL && strstr(ultima_linha, "status=5"));
	char longa[6000];
	memset(longa, 'x', sizeof longa - 1);
	longa[sizeof longa - 1] = '\0';
	diga(LOG_WARNING, "falha status=5 private_key=%s", longa);
	conferir("sink truncado explicita limite e protege chave", strstr(ultima_linha, "xxxxxxxx") == NULL &&
		 strstr(ultima_linha, "status=5") && strstr(ultima_linha, "mensagem truncada"));
#endif

	// Guardas contra overflow e saída não terminada; todas as capacidades, inclusive 0/1.
	bool limites_ok = true;
	for (size_t cap = 0; cap < 128; cap++) {
		unsigned char guarda[130];
		memset(guarda, 0xA5, sizeof guarda);
		registro_sanitizar("status=-3 PIN=654321 secret=segredo-sintetico name=Pessoa Sintética codigo=7",
				   (char *)guarda + 1, cap);
		limites_ok &= guarda[0] == 0xA5 && guarda[cap + 1] == 0xA5;
		limites_ok &= !cap || memchr(guarda + 1, '\0', cap) != NULL;
		limites_ok &= !cap || strstr((char *)guarda + 1, "654321") == NULL;
	}
	conferir("128 capacidades e guardas de memória", limites_ok);
	printf("RESULTADO %u conferências, %u falhas; C puro, sem OBS ou dados do usuário\n", casos, falhas);
	return falhas ? 1 : 0;
}
