#include "camera-remota-regras.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

// =================================================================================================
// As regras puras do painel "Câmera do aparelho". Ver `camera-remota-regras.h`.
// =================================================================================================

enum area_da_camera area_do_campo(const char *campo)
{
	static const struct {
		const char *campo;
		enum area_da_camera area;
	} mapa[] = {
		{"exposicao", AREA_EXPOSICAO},  {"ev", AREA_EXPOSICAO},
		{"travaExposicao", AREA_EXPOSICAO}, {"antiCintilacao", AREA_EXPOSICAO},
		{"iso", AREA_ISO_E_OBTURADOR}, {"obturadorNs", AREA_ISO_E_OBTURADOR},
		{"balanco", AREA_BALANCO},      {"kelvin", AREA_BALANCO},
		{"travaBalanco", AREA_BALANCO}, {"foco", AREA_FOCO},
		{"focoPosicao", AREA_FOCO},
	};
	if (!campo)
		return AREA_NENHUMA;
	for (size_t i = 0; i < sizeof mapa / sizeof mapa[0]; i++)
		if (strcmp(campo, mapa[i].campo) == 0)
			return mapa[i].area;
	return AREA_NENHUMA;
}

bool metros_do_foco(double dioptrias_em_1, double posicao, double *metros)
{
	double d = dioptrias_em_1 * posicao;
	if (!isfinite(d) || d <= 1e-9)
		return false;
	*metros = 1.0 / d;
	return true;
}

bool numeros_iguais(double a, double b)
{
	double escala = fabs(a) > 1.0 ? fabs(a) : 1.0;
	return fabs(a - b) <= 1e-6 * escala;
}

/// Põe `v` em `out` mantendo a ordem crescente e sem repetir. Devolve o novo `n`.
static size_t inserir_em_ordem(int64_t *out, size_t n, size_t cap, int64_t v)
{
	size_t i = 0;
	while (i < n && out[i] < v)
		i++;
	if (i < n && out[i] == v)
		return n;
	if (n >= cap)
		return n;
	memmove(&out[i + 1], &out[i], (n - i) * sizeof *out);
	out[i] = v;
	return n + 1;
}

size_t degraus_de_iso(double min, double max, bool tem_atual, double atual, int64_t *out, size_t cap)
{
	// R9 §3.2, literal.
	static const int64_t tercos[] = {50,  64,   80,   100,  125,  160,  200,  250,  320,  400,  500,
					 640, 800,  1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400};
	size_t n = 0;
	if (!(min <= max) || !isfinite(min) || !isfinite(max))
		return 0;
	int64_t lo = llround(min), hi = llround(max);
	n = inserir_em_ordem(out, n, cap, lo);
	n = inserir_em_ordem(out, n, cap, hi);
	for (size_t i = 0; i < sizeof tercos / sizeof tercos[0]; i++)
		if (tercos[i] >= lo && tercos[i] <= hi)
			n = inserir_em_ordem(out, n, cap, tercos[i]);
	if (tem_atual && isfinite(atual) && llround(atual) >= lo && llround(atual) <= hi)
		n = inserir_em_ordem(out, n, cap, llround(atual));
	return n;
}

size_t degraus_do_obturador(double min, double max, bool log2, bool tem_atual, double atual,
			    int64_t *out, size_t cap)
{
	// R9 §3.1, literal: as frações de cinema e vídeo.
	static const int denominadores[] = {24,  25,  30,  48,   50,   60,   100,  120,
					    125, 250, 500, 1000, 2000, 4000, 8000};
	size_t n = 0;
	if (!(min <= max) || !isfinite(min) || !isfinite(max) || max <= 0)
		return 0;
	if (log2) {
		// 2^v s em ns, arredondado ao inteiro (2^-13 s = 122070,3125 ns): o descritor é inteiro, e
		// a casca do filmador arredonda ao log2 mais próximo de qualquer jeito (§3.2).
		for (int v = -20; v <= 10; v++) {
			double ns = ldexp(1e9, v);
			if (ns >= min - 0.5 && ns <= max + 0.5)
				n = inserir_em_ordem(out, n, cap, llround(ns));
		}
	} else {
		n = inserir_em_ordem(out, n, cap, llround(min));
		n = inserir_em_ordem(out, n, cap, llround(max));
		for (size_t i = 0; i < sizeof denominadores / sizeof denominadores[0]; i++) {
			int64_t ns = llround(1e9 / denominadores[i]);
			if (ns >= llround(min) && ns <= llround(max))
				n = inserir_em_ordem(out, n, cap, ns);
		}
	}
	if (tem_atual && isfinite(atual) && atual > 0 && atual >= min - 0.5 && atual <= max + 0.5)
		n = inserir_em_ordem(out, n, cap, llround(atual));
	return n;
}

void numero_com_separador(double v, int casas, char separador, char *buf, size_t cap)
{
	if (cap == 0)
		return;
	if (!isfinite(v)) {
		snprintf(buf, cap, "?");
		return;
	}
	if (casas < 0)
		casas = 0;
	if (casas > 6)
		casas = 6;
	int64_t escala = 1;
	for (int i = 0; i < casas; i++)
		escala *= 10;
	bool negativo = v < 0;
	int64_t total = llround(fabs(v) * (double)escala);
	int64_t inteiro = total / escala, fracao = total % escala;
	int largura = casas;
	// Sem zeros à direita: 0,50 → 0,5; 2,00 → 2.
	while (largura > 0 && fracao % 10 == 0) {
		fracao /= 10;
		largura--;
	}
	const char *sinal = (negativo && total != 0) ? "-" : "";
	if (largura == 0)
		snprintf(buf, cap, "%s%lld", sinal, (long long)inteiro);
	else
		snprintf(buf, cap, "%s%lld%c%0*lld", sinal, (long long)inteiro, separador, largura,
			 (long long)fracao);
}

void texto_do_obturador(int64_t ns, char separador, char *buf, size_t cap)
{
	if (ns <= 0) {
		snprintf(buf, cap, "?");
		return;
	}
	if (ns < 1000000000ll) {
		snprintf(buf, cap, "1/%lld s", (long long)llround(1e9 / (double)ns));
		return;
	}
	char n[32];
	numero_com_separador((double)ns / 1e9, 1, separador, n, sizeof n);
	snprintf(buf, cap, "%s s", n);
}

enum frase_de_limite frase_do_limite(const char *codigo)
{
	static const char *const codigos[] = {
		"fabricante",         "macos",     "ios_cintilacao", "camera_nao_oferece",
		"foco_fixo",          "sem_calibracao", "outro_app",
	};
	if (codigo)
		for (size_t i = 0; i < sizeof codigos / sizeof codigos[0]; i++)
			if (strcmp(codigo, codigos[i]) == 0)
				return (enum frase_de_limite)i;
	return LIMITE_OUTRO;
}

bool limite_leva_controle(enum frase_de_limite f)
{
	return f != LIMITE_IOS_CINTILACAO && f != LIMITE_FOCO_FIXO && f != LIMITE_SEM_CALIBRACAO &&
	       f != LIMITE_OUTRO_APP;
}

enum frase_de_recusa frase_da_recusa(const char *motivo)
{
	if (!motivo || !*motivo)
		return RECUSA_NADA;
	static const char *const caladas[] = {"superado",       "ocupado",     "invalido",
					      "camera_trocada", "nao_pareado", "fora_da_imagem",
					      "sem_camera"};
	for (size_t i = 0; i < sizeof caladas / sizeof caladas[0]; i++)
		if (strcmp(motivo, caladas[i]) == 0)
			return RECUSA_NADA;
	if (strcmp(motivo, "nao_permitido") == 0)
		return RECUSA_NAO_PERMITIDO;
	if (strcmp(motivo, "campo_desconhecido") == 0 || strcmp(motivo, "fora_da_faixa") == 0 ||
	    strcmp(motivo, "incoerente") == 0)
		return RECUSA_NAO_ACEITOU;
	if (strcmp(motivo, "sem_resposta") == 0)
		return RECUSA_NAO_RESPONDEU;
	// `nao_aplicado` e todo código que esta build não conhece (§3.5: "mostrado como nao_aplicado").
	return RECUSA_NAO_APLICOU;
}

// -------------------------------------------------------------------------------------------------
// O leitor mínimo de JSON (ver o cabeçalho)
// -------------------------------------------------------------------------------------------------
static const char *pular_espacos(const char *p)
{
	while (p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
		p++;
	return p;
}

/// Pula um texto que começa em `"`; devolve o ponteiro depois da aspa final, ou NULL.
static const char *pular_texto(const char *p)
{
	if (!p || *p != '"')
		return NULL;
	for (p++; *p; p++) {
		if (*p == '\\') {
			if (!p[1])
				return NULL;
			p++;
		} else if (*p == '"') {
			return p + 1;
		}
	}
	return NULL;
}

/// Pula um valor qualquer; devolve o ponteiro logo depois dele, ou NULL.
static const char *pular_valor(const char *p)
{
	p = pular_espacos(p);
	if (!p || !*p)
		return NULL;
	if (*p == '"')
		return pular_texto(p);
	if (*p == '{' || *p == '[') {
		int fundo = 0;
		while (*p) {
			if (*p == '"') {
				p = pular_texto(p);
				if (!p)
					return NULL;
				continue;
			}
			if (*p == '{' || *p == '[') {
				fundo++;
			} else if (*p == '}' || *p == ']') {
				fundo--;
				if (fundo == 0)
					return p + 1;
			}
			p++;
		}
		return NULL;
	}
	// número, true, false, null
	while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\n')
		p++;
	return p;
}

/// O valor da `chave` no objeto que começa em `p` (`{`), ou NULL.
static const char *valor_da_chave(const char *p, const char *chave)
{
	p = pular_espacos(p);
	if (!p || *p != '{')
		return NULL;
	size_t n = strlen(chave);
	p++;
	for (;;) {
		p = pular_espacos(p);
		if (!p || *p != '"')
			return NULL;
		const char *ini = p + 1;
		const char *fim = pular_texto(p);
		if (!fim)
			return NULL;
		bool achou = (size_t)(fim - 1 - ini) == n && strncmp(ini, chave, n) == 0;
		p = pular_espacos(fim);
		if (!p || *p != ':')
			return NULL;
		p = pular_espacos(p + 1);
		if (achou)
			return p;
		p = pular_espacos(pular_valor(p));
		if (!p || *p != ',')
			return NULL;
		p++;
	}
}

size_t json_tamanho_do_valor(const char *valor)
{
	const char *p = pular_espacos(valor);
	const char *fim = pular_valor(p);
	return (p && fim && fim > p) ? (size_t)(fim - p) : 0;
}

const char *json_procurar(const char *json, const char *const *caminho, size_t n)
{
	const char *p = json;
	for (size_t i = 0; p && i < n; i++)
		p = valor_da_chave(p, caminho[i]);
	return p ? pular_espacos(p) : NULL;
}

size_t json_lista_de_textos(const char *valor, char *out, size_t largura, size_t cap)
{
	const char *p = pular_espacos(valor);
	size_t n = 0;
	if (!p || *p != '[' || largura == 0)
		return 0;
	p++;
	for (;;) {
		p = pular_espacos(p);
		if (!p || !*p || *p == ']')
			return n;
		if (*p != '"') {
			p = pular_valor(p);
		} else {
			const char *fim = pular_texto(p);
			if (!fim)
				return n;
			if (n < cap) {
				size_t t = (size_t)(fim - 1 - (p + 1));
				if (t > largura - 1)
					t = largura - 1;
				memcpy(out + n * largura, p + 1, t);
				out[n * largura + t] = '\0';
				n++;
			}
			p = fim;
		}
		p = pular_espacos(p);
		if (!p || *p != ',')
			return n;
		p++;
	}
}
