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
		{"travarFps", AREA_EXPOSICAO},
		{"iso", AREA_ISO_E_OBTURADOR}, {"obturadorNs", AREA_ISO_E_OBTURADOR},
		{"balanco", AREA_BALANCO},      {"kelvin", AREA_BALANCO},
		{"travaBalanco", AREA_BALANCO}, {"foco", AREA_FOCO},
		{"focoPosicao", AREA_FOCO},
		{"gama", AREA_IMAGEM},          {"contraste", AREA_IMAGEM},
		{"saturacao", AREA_IMAGEM},     {"nitidez", AREA_IMAGEM},
		{"contraluz", AREA_IMAGEM},
		// O zoom (R9 §3.8) fica no alto da área Foco: enquadramento e lente juntos.
		{"zoom", AREA_FOCO},
	};
	if (!campo)
		return AREA_NENHUMA;
	for (size_t i = 0; i < sizeof mapa / sizeof mapa[0]; i++)
		if (strcmp(campo, mapa[i].campo) == 0)
			return mapa[i].area;
	return AREA_NENHUMA;
}

bool e_ajuste_de_imagem(const char *campo)
{
	static const char *const imagem[] = {"gama", "contraste", "saturacao", "nitidez"};
	if (!campo)
		return false;
	for (size_t i = 0; i < sizeof imagem / sizeof imagem[0]; i++)
		if (strcmp(campo, imagem[i]) == 0)
			return true;
	return false;
}

bool e_zoom(const char *campo)
{
	return campo && strcmp(campo, "zoom") == 0;
}

double zoom_neutro(double min, double max)
{
	double z = 1.0;
	if (z < min)
		z = min;
	if (z > max)
		z = max;
	return z;
}

void texto_do_zoom(double z, char separador, char *buf, size_t cap)
{
	if (!buf || cap == 0)
		return;
	if (z >= 9.95) {
		snprintf(buf, cap, "%lld\xc3\x97", (long long)llround(z));
		return;
	}
	double d = round(z * 10.0) / 10.0;
	if (d == floor(d)) {
		snprintf(buf, cap, "%lld\xc3\x97", (long long)llround(d));
		return;
	}
	char n[32];
	numero_com_separador(d, 1, separador, n, sizeof n);
	snprintf(buf, cap, "%s\xc3\x97", n);
}

struct pouca_luz pouca_luz_do_filmador(bool ha, double chegando, double piso, bool tem_fps, double fps,
					bool exposicao_auto, bool travado, bool oferece_trava, bool permitido)
{
	struct pouca_luz p = {POUCA_LUZ_NADA, 0, BOTAO_DA_LUZ_NADA, 0, false};
	// Em Manual o manual já segura o fps: sem aviso (R9 §3.1.1).
	if (!ha || !exposicao_auto || !isfinite(chegando) || !isfinite(piso) || chegando < 1 || piso < 1)
		return p;
	bool fps_ok = tem_fps && isfinite(fps) && fps >= 1;
	if (travado) {
		p.frase = POUCA_LUZ_ESCURA;
		p.numero_da_frase = llround(fps_ok ? fps : chegando);
	} else {
		p.frase = POUCA_LUZ_CLAREANDO;
		p.numero_da_frase = llround(chegando);
	}
	if (!oferece_trava || !permitido)
		return p;
	p.botao_trava = !travado;
	if (travado) {
		p.botao = BOTAO_DA_LUZ_CLAREAR;
		p.numero_do_botao = llround(piso);
	} else if (fps_ok) {
		p.botao = BOTAO_DA_LUZ_TRAVAR_EM;
		p.numero_do_botao = llround(fps);
	} else {
		p.botao = BOTAO_DA_LUZ_TRAVAR;
	}
	return p;
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

bool ev_remoto_livre(bool independente, bool exposicao_auto, bool trava_exposicao)
{
	return independente || (exposicao_auto && !trava_exposicao);
}

bool nota_de_destravar_o_ev(bool independente, bool exposicao_auto, bool trava_exposicao)
{
	return !independente && exposicao_auto && trava_exposicao;
}

size_t degraus_do_obturador(double min, double max, bool log2, bool tem_atual, double atual,
			    int64_t *out, size_t cap)
{
	// R9 §3.1: as frações de cinema e vídeo, e (13/10) o 1/15 e o 1/20, que só cabem quando o
	// teto de quem filma passa de 1/fps ("Travar fps" desligado).
	static const int denominadores[] = {15,  20,  24,   25,   30,   48,   50,  60,  100,
					    120, 125, 250, 500, 1000, 2000, 4000, 8000};
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

/// Um número JSON em `p`, sem o locale: sinal, dígitos, fração e expoente. Devolve o fim, ou NULL.
static const char *ler_numero(const char *p, double *out)
{
	double sinal = 1, v = 0;
	bool algum = false;
	if (*p == '-') {
		sinal = -1;
		p++;
	}
	while (*p >= '0' && *p <= '9') {
		v = v * 10 + (*p++ - '0');
		algum = true;
	}
	if (*p == '.') {
		double peso = 0.1;
		p++;
		while (*p >= '0' && *p <= '9') {
			v += (*p++ - '0') * peso;
			peso /= 10;
			algum = true;
		}
	}
	if (!algum)
		return NULL;
	if (*p == 'e' || *p == 'E') {
		p++;
		int sinal_e = 1, e = 0;
		if (*p == '+' || *p == '-')
			sinal_e = *p++ == '-' ? -1 : 1;
		while (*p >= '0' && *p <= '9' && e < 400)
			e = e * 10 + (*p++ - '0');
		v *= pow(10.0, sinal_e * e);
	}
	*out = sinal * v;
	return p;
}

size_t json_lista_de_numeros(const char *valor, double *out, size_t cap)
{
	const char *p = pular_espacos(valor);
	size_t n = 0;
	if (!p || *p != '[')
		return 0;
	p++;
	for (;;) {
		p = pular_espacos(p);
		if (!p || !*p || *p == ']')
			return n;
		double v;
		const char *fim = (*p == '-' || (*p >= '0' && *p <= '9')) ? ler_numero(p, &v) : NULL;
		if (fim) {
			if (n < cap && isfinite(v))
				out[n++] = v;
			p = fim;
		} else {
			p = pular_valor(p);
		}
		p = pular_espacos(p);
		if (!p || *p != ',')
			return n;
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

// -------------------------------------------------------------------------------------------------
// A prévia antes de conectar
// -------------------------------------------------------------------------------------------------
static const struct {
	const char *campo, *rotulo;
} PREVIA[] = {
	// Exposição, na ordem da montagem (`camera_remota_propriedades`).
	{"exposicao", "Quall.Camera.Modo"},
	{"ev", "Quall.Camera.Ev"},
	{"travaExposicao", "Quall.Camera.TravarExposicao"},
	{"travarFps", "Quall.Camera.TravarFps"},
	{"antiCintilacao", "Quall.Camera.AntiCintilacao"},
	// ISO e obturador.
	{"iso", "Quall.Camera.Iso"},
	{"obturadorNs", "Quall.Camera.Obturador"},
	// Balanço.
	{"balanco", "Quall.Camera.Modo"},
	{"kelvin", "Quall.Camera.Kelvin"},
	{"travaBalanco", "Quall.Camera.TravarBalanco"},
	// Foco, com o zoom no alto (R9 §3.8), como na montagem.
	{"zoom", "Quall.Camera.Zoom"},
	{"foco", "Quall.Camera.Modo"},
	{"focoPosicao", "Quall.Camera.PertoLonge"},
	// Imagem (R9 §3.7).
	{"gama", "Quall.Camera.Gama"},
	{"contraste", "Quall.Camera.Contraste"},
	{"saturacao", "Quall.Camera.Saturacao"},
	{"nitidez", "Quall.Camera.Nitidez"},
	{"contraluz", "Quall.Camera.Contraluz"},
};

size_t campos_da_previa(enum area_da_camera area, const char **out, size_t cap)
{
	size_t n = 0;
	for (size_t i = 0; i < sizeof PREVIA / sizeof PREVIA[0] && n < cap; i++)
		if (area_do_campo(PREVIA[i].campo) == area)
			out[n++] = PREVIA[i].campo;
	return n;
}

const char *rotulo_da_previa(const char *campo)
{
	if (!campo)
		return NULL;
	for (size_t i = 0; i < sizeof PREVIA / sizeof PREVIA[0]; i++)
		if (strcmp(campo, PREVIA[i].campo) == 0)
			return PREVIA[i].rotulo;
	return NULL;
}

const char *titulo_da_area(enum area_da_camera area)
{
	switch (area) {
	case AREA_EXPOSICAO:
		return "Quall.Camera.Exposicao";
	case AREA_ISO_E_OBTURADOR:
		return "Quall.Camera.IsoEObturador";
	case AREA_BALANCO:
		return "Quall.Camera.Balanco";
	case AREA_FOCO:
		return "Quall.Camera.Foco";
	case AREA_IMAGEM:
		return "Quall.Camera.Imagem";
	case AREA_NENHUMA:
		break;
	}
	return NULL;
}
