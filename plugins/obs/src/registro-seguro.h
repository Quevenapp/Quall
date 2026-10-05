// SPDX-License-Identifier: GPL-3.0-or-later
// Higiene do diário, sem libobs, rede, locale, alocação ou estado global.
// Dados conhecidos (nomes, pares, pedidos e caminhos) são omitidos pelo chamador. Esta segunda
// barreira protege mensagens externas de erro/pânico; não transforma texto arbitrário em prova
// de anonimato. Nunca use a saída para GUI, protocolo, pareamento ou persistência.
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <quall.h>

static inline bool registro_letra(unsigned char c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static inline bool registro_digito(unsigned char c)
{
	return c >= '0' && c <= '9';
}

static inline bool registro_palavra(unsigned char c)
{
	return registro_letra(c) || registro_digito(c) || c == '_' || c == '-';
}

static inline void registro_anexar(char *saida, size_t cap, size_t *n, const char *p, size_t len)
{
	while (len-- && *n + 1 < cap)
	{
		unsigned char c = (unsigned char)*p++;
		saida[(*n)++] = c < 32 || c == 127 ? ' ' : (char)c;
	}
	if (cap)
		saida[*n] = '\0';
}

static inline bool registro_chave_privada(const char *p, size_t len)
{
	char chave[64];
	size_t n = 0;
	for (size_t i = 0; i < len; i++) {
		unsigned char c = (unsigned char)p[i];
		if (c == '_' || c == '-')
			continue;
		if (n + 1 >= sizeof chave)
			return false;
		chave[n++] = (char)(c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c);
	}
	chave[n] = '\0';
	static const char *const privadas[] = {
		"pin", "senha", "password", "passwd", "passphrase", "token", "accesstoken",
		"refreshtoken", "authorization", "apikey", "key", "privatekey", "publickey",
		"sessionsecret", "sessionkey", "sharedsecret", "secret", "secretkey", "pairingkey",
		"knownpeers", "knownpeersjson", "deviceid", "displayname", "name", "nome",
		"hostname", "username", "email", "address", "localaddress", "remoteaddress",
		"endereco", "identity", "identidade", "fingerprint", "icepwd", "iceufrag",
		"psk", "pwd", "ufrag", "nonce", "mac", "authkey", "sharedkey", "uid", "signingid",
	};
	for (size_t i = 0; i < sizeof privadas / sizeof privadas[0]; i++)
		if (strcmp(chave, privadas[i]) == 0)
			return true;
	return false;
}

static inline const char *registro_fim_aspas(const char *p)
{
	char aspas = *p++;
	while (*p) {
		if (*p == '\\' && p[1]) {
			p += 2;
			continue;
		}
		if (*p++ == aspas)
			break;
	}
	return p;
}

// Objeto/lista completos, inclusive aninhamento e escapes. Truncamento ou JSON malformado fecha
// a barreira até o fim da mensagem: não deixa um pedaço de segredo passar depois da falha.
static inline const char *registro_fim_json(const char *p)
{
	char pilha[64];
	size_t profundidade = 0;
	do {
		if (*p == '"') {
			p = registro_fim_aspas(p);
			continue;
		}
		if (*p == '{' || *p == '[') {
			if (profundidade == sizeof pilha)
				return p + strlen(p);
			pilha[profundidade++] = *p;
		}
		else if (*p == '}' || *p == ']') {
			if (!profundidade || pilha[profundidade - 1] != (*p == '}' ? '{' : '['))
				return p + strlen(p);
			profundidade--;
			if (!profundidade)
				return p + 1;
		}
		p++;
	} while (*p);
	return p;
}

static inline bool registro_lista_json(const char *p)
{
	if (*p++ != '[')
		return false;
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	return *p == '"' || *p == '{' || *p == '[' || *p == ']' || registro_digito((unsigned char)*p) ||
	       *p == '-' || strncmp(p, "null", 4) == 0 || strncmp(p, "true", 4) == 0 ||
	       strncmp(p, "false", 5) == 0;
}

static inline const char *registro_fim_valor(const char *p)
{
	if (*p == '"' || *p == '\'')
		return registro_fim_aspas(p);
	if (*p == '{' || *p == '[')
		return registro_fim_json(p);
	while (*p && *p != '\r' && *p != '\n' && *p != ',' && *p != ';' && *p != ')') {
		// Um novo campo nomeado encerra o anterior; valores com espaços não deixam metade de
		// um nome ou passphrase no diário. Códigos/métricas seguintes continuam disponíveis.
		if (*p == ' ' || *p == '\t') {
			const char *q = p;
			while (*q == ' ' || *q == '\t')
				q++;
			const char *chave = q;
			while (registro_palavra((unsigned char)*q) || *q == '.')
				q++;
			if (q != chave && (*q == '=' || *q == ':'))
				return p;
		}
		p++;
	}
	return p;
}

static inline bool registro_hex(unsigned char c)
{
	return registro_digito(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static inline const char *registro_fim_ip(const char *p)
{
	const char *q = p;
	if (*q == '[')
		q++;
	const char *inicio = q;
	unsigned colons = 0;
	bool tem_hex = false;
	while (registro_hex((unsigned char)*q) || *q == ':' || *q == '.') {
		tem_hex |= registro_hex((unsigned char)*q);
		colons += *q == ':';
		q++;
	}
	if ((tem_hex || q > inicio) && colons >= 2) {
		if (*q == '%') {
			q++;
			while (registro_palavra((unsigned char)*q) || *q == '.')
				q++;
		}
		if (*q == ']')
			q++;
		if (*q == ':' && registro_digito((unsigned char)q[1]))
			while (*++q && registro_digito((unsigned char)*q)) {}
		return q;
	}
	q = inicio;
	for (unsigned parte = 0; parte < 4; parte++) {
		unsigned numero = 0, digitos = 0;
		while (registro_digito((unsigned char)*q)) {
			numero = numero * 10 + (unsigned)(*q++ - '0');
			if (++digitos > 3)
				return p;
		}
		if (!digitos || numero > 255)
			return p;
		if (parte != 3 && *q++ != '.')
			return p;
	}
	if (registro_palavra((unsigned char)*q) || *q == '.')
		return p;
	if (*q == ':' && registro_digito((unsigned char)q[1]))
		while (*++q && registro_digito((unsigned char)*q)) {}
	return q;
}

static inline const char *registro_fim_caminho(const char *p)
{
	while (*p && *p != '\r' && *p != '\n' && *p != '"' && *p != '\'' && *p != ',' &&
	       *p != ';' && *p != ')' && !(*p == ':' && p[1] == ' '))
		p++;
	return p;
}

static inline void registro_sanitizar(const char *texto, char *saida, size_t cap)
{
	if (!cap)
		return;
	size_t n = 0;
	saida[0] = '\0';
	if (!texto)
		texto = "(mensagem indisponível)";
	const char *p = texto;
	while (*p && n + 1 < cap) {
		const char *fim = p;
		const char *substituto = NULL;
		bool limite = p == texto || !registro_palavra((unsigned char)p[-1]);
		if (*p == '{' || registro_lista_json(p)) {
			fim = registro_fim_json(p);
			substituto = "[dados omitidos]";
		} else if (strncmp(p, "-----BEGIN", 10) == 0) {
			const char *fim_pem = strstr(p, "-----END");
			fim = fim_pem ? strstr(fim_pem + 8, "-----") : NULL;
			fim = fim ? fim + 5 : p + strlen(p);
			substituto = "[credencial omitida]";
		} else if (limite && (strncmp(p, "http://", 7) == 0 || strncmp(p, "https://", 8) == 0 ||
				      strncmp(p, "rtsp://", 7) == 0 || strncmp(p, "file://", 7) == 0 ||
				      strncmp(p, "ws://", 5) == 0 || strncmp(p, "wss://", 6) == 0)) {
			fim = p;
			while (*fim && *fim != ' ' && *fim != '\t' && *fim != '\r' && *fim != '\n')
				fim++;
			substituto = "[URL omitida]";
		} else if (limite && (*p == '/' || (*p == '\\' && p[1] == '\\') ||
				      (registro_letra((unsigned char)*p) && p[1] == ':' &&
				       (p[2] == '\\' || p[2] == '/')))) {
			fim = registro_fim_caminho(p);
			substituto = "[caminho omitido]";
		} else if (limite && (registro_hex((unsigned char)*p) || *p == ':' || *p == '[') &&
			   (fim = registro_fim_ip(p)) != p) {
			substituto = "[endereço omitido]";
		} else if (limite && registro_letra((unsigned char)*p)) {
			const char *chave = p;
			while (registro_palavra((unsigned char)*chave))
				chave++;
			if (registro_chave_privada(p, (size_t)(chave - p))) {
				const char *valor = chave;
				if ((*valor == '"' || *valor == '\'') && p != texto && p[-1] == *valor)
					valor++;
				while (*valor == ' ' || *valor == '\t' || *valor == '\r' || *valor == '\n')
					valor++;
				if (*valor == ':' || *valor == '=') {
					valor++;
					while (*valor == ' ' || *valor == '\t' || *valor == '\r' || *valor == '\n')
						valor++;
					registro_anexar(saida, cap, &n, p, (size_t)(valor - p));
					fim = registro_fim_valor(valor);
					substituto = "[valor omitido]";
				} else if ((size_t)(chave - p) == 3 &&
					   (p[0] == 'p' || p[0] == 'P') && registro_digito((unsigned char)*valor)) {
					registro_anexar(saida, cap, &n, p, (size_t)(valor - p));
					fim = registro_fim_valor(valor);
					substituto = "[valor omitido]";
				}
			}
		}
		if (substituto) {
			registro_anexar(saida, cap, &n, substituto, strlen(substituto));
			p = fim;
			continue;
		}
		unsigned char c = (unsigned char)*p++;
		char seguro = c < 32 || c == 127 ? ' ' : (char)c;
		registro_anexar(saida, cap, &n, &seguro, 1);
	}
}

// Código público já existente na fronteira C, sem interpretar texto externo que pode conter
// valores opacos. O chamador captura o código imediatamente após a falha, antes de outra API C.
static inline const char *registro_causa_status(enum QuallStatus status)
{
	switch (status) {
	case QUALL_STATUS_OK: return "nenhuma falha informada";
	case QUALL_STATUS_INVALID: return "entrada inválida";
	case QUALL_STATUS_PROTOCOL: return "falha de protocolo";
	case QUALL_STATUS_DISCOVERY: return "falha de descoberta";
	case QUALL_STATUS_SIGNALING: return "falha de sinalização";
	case QUALL_STATUS_TRANSPORT: return "falha de transporte";
	case QUALL_STATUS_PAIRING: return "pareamento recusado";
	case QUALL_STATUS_TIMEOUT: return "prazo esgotado";
	case QUALL_STATUS_CLOSED: return "objeto ou sessão fechado";
	case QUALL_STATUS_IO: return "falha de entrada/saída";
	case QUALL_STATUS_NULL_POINTER: return "ponteiro nulo";
	case QUALL_STATUS_NOT_UTF8: return "texto UTF-8 inválido";
	case QUALL_STATUS_NO_ROUTE: return "sem rota entre aparelhos";
	case QUALL_STATUS_NEEDS_PIN: return "novo PIN necessário";
	case QUALL_STATUS_CANCELLED: return "operação cancelada";
	case QUALL_STATUS_WRONG_PIN: return "PIN não confere";
	case QUALL_STATUS_BUSY: return "aparelho ocupado";
	default: return "causa não classificada (texto interno omitido)";
	}
}

// `som_ligar` mantém sua mensagem operacional intacta. Só a cópia do diário recebe categoria ou
// valores numéricos de um formato conhecido, e jamais o sufixo externo de quall_last_error/JSON.
static inline void registro_formatar_motivo_som(const char *motivo, char *saida, size_t cap)
{
	const char *causa = "falha de áudio não classificada (texto interno omitido)";
	if (!motivo)
		motivo = "";
	if (strncmp(motivo, "a track não disse o codec:", strlen("a track não disse o codec:")) == 0)
		causa = "codec de áudio não informado (texto interno omitido)";
	else if (strncmp(motivo, "o preset da track não se leu:", strlen("o preset da track não se leu:")) == 0)
		causa = "preset de áudio indisponível (texto interno omitido)";
	else if (strncmp(motivo, "o preset da track não é JSON:", strlen("o preset da track não é JSON:")) == 0)
		causa = "preset de áudio inválido (conteúdo omitido)";
	else if (strncmp(motivo, "o decodificador não abriu:", strlen("o decodificador não abriu:")) == 0)
		causa = "decodificador de áudio indisponível (texto interno omitido)";
	else if (strncmp(motivo, "a porta puxada não abriu:", strlen("a porta puxada não abriu:")) == 0)
		causa = "porta de áudio indisponível (texto interno omitido)";
	else {
		long long taxa = 0, canais = 0, amostras = 0;
		int fim = 0;
		if (sscanf(motivo, "preset fora do que este plugin toca: %lld Hz × %lld, %lld por quadro%n",
			   &taxa, &canais, &amostras, &fim) == 3 && motivo[fim] == '\0') {
			snprintf(saida, cap, "preset de áudio não suportado: sample_rate_hz=%lld channels=%lld frame_samples=%lld",
				 taxa, canais, amostras);
			return;
		}
	}
	snprintf(saida, cap, "%s", causa);
}

// O chamador só passa chaves constantes da lista de métricas, nunca strings do JSON. Preserva
// inteiro/double e a diferença entre zero, null e ausência, sem copiar configuração nova por
// acidente quando a fronteira C acrescentar campos.
static inline void registro_formatar_numero(char *saida, size_t cap, const char *chave, bool tem,
					   bool nulo, bool real, int64_t inteiro, double decimal)
{
	if (!tem)
		snprintf(saida, cap, "%s=ausente", chave);
	else if (nulo)
		snprintf(saida, cap, "%s=null", chave);
	else if (real)
	{
		char valor[64];
		snprintf(valor, sizeof valor, "%.17g", decimal);
		// Sem trocar o locale global do OBS: só esta representação numérica é normalizada.
		for (char *p = valor; *p; p++)
			if (*p == ',')
				*p = '.';
		snprintf(saida, cap, "%s=%s", chave, valor);
	}
	else
		snprintf(saida, cap, "%s=%lld", chave, (long long)inteiro);
}

static inline const char *registro_estado_relogio(const char *estado)
{
	if (estado && (strcmp(estado, "pending") == 0 || strcmp(estado, "valid") == 0 ||
		       strcmp(estado, "refused") == 0))
		return strcmp(estado, "valid") == 0 ? "valid" :
		       strcmp(estado, "refused") == 0 ? "refused" : "pending";
	return "indisponivel";
}

static inline const char *registro_motivo_relogio(const char *motivo)
{
	if (!motivo || !*motivo)
		return "null";
	if (strcmp(motivo, "o estado do relógio da sessão foi envenenado") == 0)
		return "estado_envenenado";
	if (strcmp(motivo, "track desconhecida do relógio da sessão") == 0)
		return "track_desconhecida";
	if (strcmp(motivo, "a taxa do relógio RTP desta track não divide 720 000 Hz") == 0)
		return "taxa_nao_suportada";
	if (strncmp(motivo, "a track ", strlen("a track ")) == 0)
		return "guarda_da_referencia_recusada";
	if (strncmp(motivo, "o relógio desta track e o da referência se separaram:",
		    strlen("o relógio desta track e o da referência se separaram:")) == 0)
		return "guarda_recusada";
	return "motivo_nao_reconhecido_texto_omitido";
}
