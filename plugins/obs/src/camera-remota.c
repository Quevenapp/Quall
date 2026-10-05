#include "quall-obs.h"
#include "camera-remota-regras.h"
#include <quall.h>

#include <math.h>
#include <string.h>

// =================================================================================================
// A câmera do aparelho, nas propriedades da fonte (R9b, `docs/controle-remoto-da-camera.md` §12).
//
// O OBS só recebe: quem filma é o outro aparelho, e o plugin **pede** ajustes à câmera dele pelo
// canal de dados da sessão de vídeo (`quall_camera_remote_*`). O núcleo cuida do protocolo, do
// reenvio e do "vence quem mexer por último"; esta casca desenha o grupo "Câmera do aparelho" a
// partir das capacidades que chegaram, e transforma a mexida da pessoa num pedido.
//
// **Três threads**, e a regra de cada uma:
//
// - a `laco` (`receptor.c`) é dona do `QuallCameraRemote` e do `QuallMessages`: cria, bombeia com
//   `timeout_ms = 0` depois de cada `quall_session_next_event`, e libera. Ela guarda a última cópia
//   do estado do núcleo (texto JSON) e decide quando pedir ao OBS para refazer as propriedades;
// - a da interface do OBS (ou a de quem pedir as propriedades, como o obs-websocket) monta o grupo
//   a partir dessa cópia e trata a mexida da pessoa, chamando `request`/`restore` — que o header
//   autoriza de qualquer thread;
// - a trava `trava` protege o ponteiro do remoto (a `laco` o zera **antes** de liberar, então a
//   interface nunca pede num remoto morto), a cópia do estado, o espelho e os relógios. **Com ela
//   na mão, nada de `r->trava` (`dizer`, `receptor_estado`) nem `obs_source_update_properties`.**
//
// **Só de gesto** (achado I8). O OBS chama os `modified_callback` em **toda** montagem do painel —
// `obs_source_properties` faz `obs_properties_apply_settings` logo depois do `get_properties`
// (`obs-source.c:1032-1039`) —, e não só quando a pessoa mexe. Então o pedido só sai quando o valor
// do `settings` difere do **espelho**: o que a última montagem escreveu no `settings` (e o que a
// própria pessoa pediu depois). O espelho só é escrito pela montagem e pelo gesto, nunca pela
// `laco`; numa montagem o `settings` é igual ao espelho por construção, e nada sai.
//
// **Não é salvo com a cena** (I8): as chaves `camera.*` saem do `settings` no `.save` e no `.load`
// (`fonte.c`). O `.save` roda antes de o `settings` ser serializado (`obs.c:2465` → `:2480`).
// =================================================================================================

#define PREFIXO "camera."

/// Os campos do ajuste que o painel conhece (R9 §2), na ordem do registro. Os de leitura
/// (`travaIso`, `travaObturadorNs`, `travaGanhos`) nunca são pedidos (§3.2) e não entram.
static const char *const CAMPOS[] = {
	"exposicao", "ev",     "travaExposicao", "antiCintilacao", "iso",         "obturadorNs",
	"balanco",   "kelvin", "travaBalanco",   "foco",           "focoPosicao",
};
#define N_CAMPOS (sizeof CAMPOS / sizeof CAMPOS[0])

enum tipo_do_campo { TIPO_NENHUM = 0, TIPO_LISTA, TIPO_SIM_NAO, TIPO_NUMERO };

/// Como um campo foi posto na tela, para o gesto converter o `settings` de volta ao núcleo.
struct campo_na_tela {
	enum tipo_do_campo tipo;
	/// O `settings` guarda inteiro (slider inteiro, combo de ISO ou obturador) ou `double`.
	bool guarda_inteiro;
	/// O descritor diz `"inteiro":true`: o pedido vai sem parte fracionária (§3.2).
	bool inteiro;
	/// O "Brilho" do Windows é mostrado como `origem + valor` (§3.2, achado I7).
	double origem;
};

struct camera_remota {
	obs_source_t *fonte;
	pthread_mutex_t trava;

	// --- sob `trava` ---------------------------------------------------------------------------
	/// O controle da sessão de agora. Só a `laco` escreve; a interface lê para pedir.
	QuallCameraRemote *remoto;
	/// A última cópia de `quall_camera_remote_state_json`. NULL fora de sessão.
	char *estado;
	/// O que a tela mostra, nas unidades do núcleo: escrito pela montagem e pelo gesto.
	obs_data_t *espelho;
	/// A estrutura (situação, capacidades, recusa visível) da última montagem; "oculto" sem grupo.
	char *estrutura_na_tela;
	struct campo_na_tela campos[N_CAMPOS];
	bool permitido;
	uint64_t ultimo_gesto_ns;
	uint64_t ultimo_update_ns;

	// --- só da `laco` --------------------------------------------------------------------------
	QuallMessages *mensagens;
	bool bombeando;
	bool avisou_bombeada;
	char *assinatura_pedida;
	uint64_t ultimo_refazer_ns;
	uint64_t ultima_leitura_ns;
};

/// O refazer não corta uma mexida: espera a pessoa largar o controle por este tempo.
#define QUIETO_DEPOIS_DO_GESTO_NS 1000000000ull
/// Nem come teclas: espera este tempo depois do último `.update` (endereço, PIN, nome). É o defeito
/// medido em 09/09/2026 (`receptor.c`, `dizer`): refazer o painel com a pessoa digitando.
#define QUIETO_DEPOIS_DO_UPDATE_NS 2000000000ull
#define REFAZER_NO_MAXIMO_NS 500000000ull
#define LER_O_ESTADO_A_CADA_NS 500000000ull

static uint64_t agora_ns(void)
{
	return os_gettime_ns();
}

// -------------------------------------------------------------------------------------------------
// Ler o estado
// -------------------------------------------------------------------------------------------------
/// A chave tem um valor **simples** (texto, número, sim/não)? O `null` do JSON não conta: a libobs
/// o lê como um **objeto nulo** (`obs_data_add_json_null`, `obs-data.c:486`), e não como
/// `OBS_DATA_NULL` — e o `get_double` dele dá 0. Foi a prova com a libobs que mostrou: o `kelvin`
/// nulo do Android virava um pedido de `{"kelvin":0}` na montagem.
static bool tem_valor(obs_data_t *d, const char *k)
{
	if (!d)
		return false;
	obs_data_item_t *it = obs_data_item_byname(d, k);
	if (!it)
		return false;
	enum obs_data_type t = obs_data_item_gettype(it);
	obs_data_item_release(&it);
	return t == OBS_DATA_STRING || t == OBS_DATA_NUMBER || t == OBS_DATA_BOOLEAN;
}

static enum obs_data_type tipo_do_item(obs_data_t *d, const char *k)
{
	obs_data_item_t *it = obs_data_item_byname(d, k);
	if (!it)
		return OBS_DATA_NULL;
	enum obs_data_type t = obs_data_item_gettype(it);
	obs_data_item_release(&it);
	return t;
}

/// O mesmo valor nas duas, com `null` igual a ausente e `800` igual a `800.0` (§3).
static bool itens_iguais(obs_data_t *a, obs_data_t *b, const char *k)
{
	bool ta = tem_valor(a, k), tb = tem_valor(b, k);
	if (ta != tb)
		return false;
	if (!ta)
		return true;
	enum obs_data_type xa = tipo_do_item(a, k), xb = tipo_do_item(b, k);
	if (xa != xb)
		return false;
	switch (xa) {
	case OBS_DATA_STRING:
		return strcmp(obs_data_get_string(a, k), obs_data_get_string(b, k)) == 0;
	case OBS_DATA_NUMBER:
		return numeros_iguais(obs_data_get_double(a, k), obs_data_get_double(b, k));
	case OBS_DATA_BOOLEAN:
		return obs_data_get_bool(a, k) == obs_data_get_bool(b, k);
	default:
		return true;
	}
}

static void copiar_item(obs_data_t *de, obs_data_t *para, const char *k)
{
	switch (tipo_do_item(de, k)) {
	case OBS_DATA_STRING:
		obs_data_set_string(para, k, obs_data_get_string(de, k));
		break;
	case OBS_DATA_NUMBER:
		obs_data_set_double(para, k, obs_data_get_double(de, k));
		break;
	case OBS_DATA_BOOLEAN:
		obs_data_set_bool(para, k, obs_data_get_bool(de, k));
		break;
	default:
		break;
	}
}

/// O estado no padrão `(buf, cap)`: repita até caber (§11.1).
static char *ler_estado(QuallCameraRemote *remoto)
{
	size_t cap = 2048;
	char *b = bmalloc(cap);
	for (int i = 0; i < 4; i++) {
		intptr_t n = quall_camera_remote_state_json(remoto, b, cap);
		if (n <= 0)
			break;
		if ((size_t)n <= cap)
			return b;
		cap = (size_t)n;
		b = brealloc(b, cap);
	}
	bfree(b);
	return NULL;
}

static bool situacao_mostra(const char *s)
{
	return s && (strcmp(s, "pronto") == 0 || strcmp(s, "nao_permitido") == 0);
}

/// Acrescenta a `out` o trecho cru do valor no `caminho` (ou "-" se não há).
static void trecho_cru(struct dstr *out, const char *json, const char *const *caminho, size_t n)
{
	const char *v = json_procurar(json, caminho, n);
	size_t t = v ? json_tamanho_do_valor(v) : 0;
	if (t)
		dstr_ncat(out, v, t);
	else
		dstr_cat(out, "-");
}

/// **A estrutura** do que o grupo desenha: a situação, as capacidades (cruas: o `obs_data` perderia
/// as listas de `valores`) e a recusa que mostra linha. Mudou, o painel tem de ser refeito.
static void estrutura_do_estado(const char *json, obs_data_t *estado, struct dstr *out)
{
	dstr_free(out);
	const char *s = estado ? obs_data_get_string(estado, "situacao") : NULL;
	const char *const caps[] = {"capacidades"};
	const char *cv = json ? json_procurar(json, caps, 1) : NULL;
	if (!situacao_mostra(s) || !cv || *cv != '{') {
		dstr_copy(out, "oculto");
		return;
	}
	dstr_printf(out, "%s|", s);
	trecho_cru(out, json, caps, 1);
	obs_data_t *rec = obs_data_get_obj(estado, "recusa");
	if (rec) {
		const char *motivo = obs_data_get_string(rec, "motivo");
		if (frase_da_recusa(motivo) != RECUSA_NADA)
			dstr_catf(out, "|%s|%s", motivo, obs_data_get_string(rec, "campo"));
		obs_data_release(rec);
	}
}

static bool pendente_vazio(obs_data_t *estado)
{
	obs_data_t *p = obs_data_get_obj(estado, "pendente");
	if (!p)
		return true;
	obs_data_item_t *it = obs_data_first(p);
	bool vazio = it == NULL;
	obs_data_item_release(&it);
	obs_data_release(p);
	return vazio;
}

// -------------------------------------------------------------------------------------------------
// A `laco`
// -------------------------------------------------------------------------------------------------
struct camera_remota *camera_remota_criar(obs_source_t *fonte)
{
	struct camera_remota *c = bzalloc(sizeof *c);
	c->fonte = fonte;
	pthread_mutex_init(&c->trava, NULL);
	c->espelho = obs_data_create();
	return c;
}

void camera_remota_destruir(struct camera_remota *c)
{
	if (!c)
		return;
	// A `laco` já terminou (`receptor_destruir` a junta antes): o remoto já foi liberado.
	obs_data_release(c->espelho);
	bfree(c->estado);
	bfree(c->estrutura_na_tela);
	bfree(c->assinatura_pedida);
	pthread_mutex_destroy(&c->trava);
	bfree(c);
}

void camera_remota_comecar(struct camera_remota *c, struct QuallSession *ses)
{
	if (!c || !ses)
		return;
	QuallMessages *m = quall_session_messages(ses);
	QuallCameraRemote *remoto = m ? quall_camera_remote_new() : NULL;
	if (!m || !remoto) {
		diga(LOG_WARNING, "câmera do aparelho: não consegui criar o controle remoto (status %d: %s)",
		     (int)quall_last_status(), registro_causa_status(quall_last_status()));
		quall_camera_remote_free(remoto);
		quall_messages_free(m);
		return;
	}
	c->mensagens = m;
	c->bombeando = true;
	c->avisou_bombeada = false;
	c->ultima_leitura_ns = 0;
	bfree(c->assinatura_pedida);
	c->assinatura_pedida = NULL;
	pthread_mutex_lock(&c->trava);
	c->remoto = remoto;
	pthread_mutex_unlock(&c->trava);
}

/// Decide se o painel tem de ser refeito, e o pede ao OBS. Ver o cabeçalho deste arquivo.
static void talvez_refazer(struct camera_remota *c, uint64_t agora)
{
	pthread_mutex_lock(&c->trava);
	char *json = c->estado ? bstrdup(c->estado) : NULL;
	pthread_mutex_unlock(&c->trava);

	obs_data_t *estado = json ? obs_data_create_from_json(json) : NULL;
	struct dstr estrutura = {0}, assinatura = {0};
	estrutura_do_estado(json, estado, &estrutura);
	dstr_copy_dstr(&assinatura, &estrutura);
	bool sem_pendente = estado && pendente_vazio(estado);
	if (sem_pendente) {
		const char *const aj[] = {"ajuste"};
		dstr_cat(&assinatura, "|");
		trecho_cru(&assinatura, json, aj, 1);
	}

	if (!c->assinatura_pedida || strcmp(c->assinatura_pedida, assinatura.array) != 0) {
		obs_data_t *ajuste = estado ? obs_data_get_obj(estado, "ajuste") : NULL;
		pthread_mutex_lock(&c->trava);
		bool precisa = strcmp(estrutura.array,
				      c->estrutura_na_tela ? c->estrutura_na_tela : "oculto") != 0;
		if (!precisa && sem_pendente && ajuste && strcmp(estrutura.array, "oculto") != 0)
			for (size_t i = 0; i < N_CAMPOS && !precisa; i++)
				precisa = !itens_iguais(ajuste, c->espelho, CAMPOS[i]);
		uint64_t gesto = c->ultimo_gesto_ns;
		uint64_t update = c->ultimo_update_ns;
		pthread_mutex_unlock(&c->trava);
		obs_data_release(ajuste);

		bool quieto = agora - gesto >= QUIETO_DEPOIS_DO_GESTO_NS &&
			      agora - update >= QUIETO_DEPOIS_DO_UPDATE_NS &&
			      agora - c->ultimo_refazer_ns >= REFAZER_NO_MAXIMO_NS;
		if (precisa && quieto) {
			// O sinal `update_properties` faz a janela de propriedades aberta chamar
			// `get_properties` de novo, na thread dela; com a janela fechada, ninguém escuta.
			// **Não** se mexe no espelho daqui (revisão, B2): só a montagem sabe o que pôs na
			// tela.
			obs_source_update_properties(c->fonte);
			c->ultimo_refazer_ns = agora;
		}
		// Sem precisar, ou já pedido: esta assinatura não pede mais nada. Precisando e sem
		// quietude, fica para a volta seguinte.
		if (!precisa || quieto) {
			bfree(c->assinatura_pedida);
			c->assinatura_pedida = bstrdup(assinatura.array);
		}
	}

	dstr_free(&estrutura);
	dstr_free(&assinatura);
	obs_data_release(estado);
	bfree(json);
}

void camera_remota_bombear(struct camera_remota *c)
{
	if (!c || !c->bombeando)
		return;
	uint32_t mudou = 0;
	enum QuallStatus st = quall_camera_remote_pump(c->remoto, c->mensagens, 0, &mudou);
	if (st == QUALL_STATUS_CLOSED) {
		// A sessão acabou; o laço da sessão vê a queda pelo `next_event` e chama `acabar`.
		c->bombeando = false;
	} else if (st != QUALL_STATUS_OK && !c->avisou_bombeada) {
		c->avisou_bombeada = true;
		diga(LOG_WARNING, "câmera do aparelho: a bombeada devolveu status %d: %s", (int)st,
		     registro_causa_status(st));
	}

	uint64_t agora = agora_ns();
	if (!mudou && agora - c->ultima_leitura_ns < LER_O_ESTADO_A_CADA_NS)
		return;
	c->ultima_leitura_ns = agora;
	char *novo = ler_estado(c->remoto);
	if (!novo)
		return;
	pthread_mutex_lock(&c->trava);
	bfree(c->estado);
	c->estado = novo;
	pthread_mutex_unlock(&c->trava);
	talvez_refazer(c, agora);
}

void camera_remota_acabar(struct camera_remota *c, bool refazer)
{
	if (!c)
		return;
	pthread_mutex_lock(&c->trava);
	QuallCameraRemote *remoto = c->remoto;
	c->remoto = NULL;
	bool tinha_grupo = c->estrutura_na_tela && strcmp(c->estrutura_na_tela, "oculto") != 0;
	bfree(c->estado);
	c->estado = NULL;
	uint64_t update = c->ultimo_update_ns;
	pthread_mutex_unlock(&c->trava);

	// O remoto sai antes das mensagens, e os dois antes de a sessão fechar (o handle de mensagens
	// pode ser liberado antes ou depois do `quall_session_close`, diz o header).
	quall_camera_remote_free(remoto);
	quall_messages_free(c->mensagens);
	c->mensagens = NULL;
	c->bombeando = false;
	bfree(c->assinatura_pedida);
	c->assinatura_pedida = NULL;

	// O grupo some do painel aberto, **menos** quando a sessão caiu porque a pessoa está mexendo
	// no endereço ou no PIN (a geração virou, `refazer` falso) ou acabou de mexer (revisão, B3):
	// refazer ali come as teclas. Sem o refazer, o grupo fica até a próxima montagem, e os gestos
	// nele não saem (o remoto é nulo).
	if (refazer && tinha_grupo && agora_ns() - update >= QUIETO_DEPOIS_DO_UPDATE_NS)
		obs_source_update_properties(c->fonte);
}

void camera_remota_ajustes_mudaram(struct camera_remota *c)
{
	if (!c)
		return;
	pthread_mutex_lock(&c->trava);
	c->ultimo_update_ns = agora_ns();
	pthread_mutex_unlock(&c->trava);
}

void camera_remota_nao_salvar(obs_data_t *ajustes)
{
	if (!ajustes)
		return;
	char chave[64];
	for (size_t i = 0; i < N_CAMPOS; i++) {
		snprintf(chave, sizeof chave, PREFIXO "%s", CAMPOS[i]);
		obs_data_erase(ajustes, chave);
	}
}

// -------------------------------------------------------------------------------------------------
// Os textos
// -------------------------------------------------------------------------------------------------
static char separador_decimal(void)
{
	const char *s = obs_module_text("Quall.Camera.SeparadorDecimal");
	return (s && *s) ? s[0] : ',';
}

/// O rótulo de um valor de lista (`auto`, `luzDoDia`…). Valor que esta build não conhece sai cru.
static const char *rotulo_do_valor(const char *v)
{
	static const struct {
		const char *valor, *chave;
	} mapa[] = {
		{"auto", "Quall.Camera.Auto"},
		{"manual", "Quall.Camera.Manual"},
		{"travado", "Quall.Camera.Travado"},
		{"50", "Quall.Camera.Hz50"},
		{"60", "Quall.Camera.Hz60"},
		{"desligada", "Quall.Camera.Desligada"},
		{"incandescente", "Quall.Camera.Incandescente"},
		{"fluorescente", "Quall.Camera.Fluorescente"},
		{"luzDoDia", "Quall.Camera.LuzDoDia"},
		{"nublado", "Quall.Camera.Nublado"},
		{"kelvin", "Quall.Camera.Kelvin"},
	};
	for (size_t i = 0; i < sizeof mapa / sizeof mapa[0]; i++)
		if (strcmp(v, mapa[i].valor) == 0)
			return obs_module_text(mapa[i].chave);
	return v;
}

/// Na tela do Windows o `ev` é o "Brilho" e o `iso` é o "Ganho" (R9 §3.2, §3.3): pela `unidade`
/// do descritor, ou, para um campo que só aparece em `limites`, pela plataforma.
struct unidades {
	bool brilho, ganho;
};

static struct unidades unidades_do_estado(obs_data_t *caps)
{
	struct unidades u = {false, false};
	if (!caps)
		return u;
	bool windows = strcmp(obs_data_get_string(caps, "plataforma"), "windows") == 0;
	obs_data_t *ctl = obs_data_get_obj(caps, "controles");
	obs_data_t *ev = ctl ? obs_data_get_obj(ctl, "ev") : NULL;
	obs_data_t *iso = ctl ? obs_data_get_obj(ctl, "iso") : NULL;
	u.brilho = ev ? strcmp(obs_data_get_string(ev, "unidade"), "brilho") == 0 : windows;
	u.ganho = iso ? strcmp(obs_data_get_string(iso, "unidade"), "ganho") == 0 : windows;
	obs_data_release(ev);
	obs_data_release(iso);
	obs_data_release(ctl);
	return u;
}

/// O `{controle}` das frases (R9 §3.5), com o artigo.
static const char *nome_do_controle(const char *campo, struct unidades u)
{
	static const struct {
		const char *campo, *chave;
	} mapa[] = {
		{"obturadorNs", "Quall.Camera.Nome.Obturador"},
		{"kelvin", "Quall.Camera.Nome.Kelvin"},
		{"balanco", "Quall.Camera.Nome.Presets"},
		{"focoPosicao", "Quall.Camera.Nome.FocoManual"},
		{"antiCintilacao", "Quall.Camera.Nome.AntiCintilacao"},
		{"toque", "Quall.Camera.Nome.Toque"},
		{"travaExposicao", "Quall.Camera.Nome.TravaExposicao"},
		{"travaBalanco", "Quall.Camera.Nome.TravaBalanco"},
		{"foco", "Quall.Camera.Nome.TravaFoco"},
		{"exposicao", "Quall.Camera.Nome.ExposicaoManual"},
	};
	if (!campo)
		return obs_module_text("Quall.Camera.Nome.Outro");
	if (strcmp(campo, "iso") == 0)
		return obs_module_text(u.ganho ? "Quall.Camera.Nome.Ganho" : "Quall.Camera.Nome.Iso");
	if (strcmp(campo, "ev") == 0)
		return obs_module_text(u.brilho ? "Quall.Camera.Nome.Brilho" : "Quall.Camera.Nome.Ev");
	for (size_t i = 0; i < sizeof mapa / sizeof mapa[0]; i++)
		if (strcmp(campo, mapa[i].campo) == 0)
			return obs_module_text(mapa[i].chave);
	return obs_module_text("Quall.Camera.Nome.Outro");
}

/// A chave da frase de um código de limite. A ordem casa com `enum frase_de_limite`.
static const char *const CHAVES_DE_LIMITE[] = {
	"Quall.Camera.Limite.Fabricante",       "Quall.Camera.Limite.Macos",
	"Quall.Camera.Limite.IosCintilacao",    "Quall.Camera.Limite.CameraNaoOferece",
	"Quall.Camera.Limite.FocoFixo",         "Quall.Camera.Limite.SemCalibracao",
	"Quall.Camera.Limite.OutroApp",         "Quall.Camera.Limite.Outro",
};

/// Um valor do ajuste ou do lido, como a tela o escreve.
static void texto_do_valor(const char *campo, double v, struct unidades u, char *buf, size_t cap)
{
	char n[32];
	char sep = separador_decimal();
	if (strcmp(campo, "obturadorNs") == 0) {
		texto_do_obturador(llround(v), sep, buf, cap);
	} else if (strcmp(campo, "kelvin") == 0) {
		snprintf(buf, cap, "%lld K", (long long)llround(v));
	} else if (strcmp(campo, "abertura") == 0) {
		numero_com_separador(v, 1, sep, n, sizeof n);
		snprintf(buf, cap, "f/%s", n);
	} else if (strcmp(campo, "iso") == 0) {
		snprintf(n, sizeof n, "%lld", (long long)llround(v));
		snprintf(buf, cap, texto_formato(u.ganho ? "Quall.Camera.ValorGanho" : "Quall.Camera.ValorIso"),
			 n);
	} else {
		numero_com_separador(v, 2, sep, buf, cap);
	}
}

// -------------------------------------------------------------------------------------------------
// As regras da tela (R9 §3.3, §3.4, §4.3), a partir do espelho — nunca do `settings`, que o
// `.save` esvazia com o diálogo aberto (revisão, I1)
// -------------------------------------------------------------------------------------------------
static void habilitar(obs_properties_t *props, const char *nome, bool sim)
{
	obs_property_t *p = obs_properties_get(props, nome);
	if (p)
		obs_property_set_enabled(p, sim);
}

static void mostrar(obs_properties_t *props, const char *nome, bool sim)
{
	obs_property_t *p = obs_properties_get(props, nome);
	if (p)
		obs_property_set_visible(p, sim);
}

static const char *texto_ou(obs_data_t *d, const char *k, const char *padrao)
{
	return tem_valor(d, k) ? obs_data_get_string(d, k) : padrao;
}

/// Com `trava` na mão (só mexe nos `props`).
static void aplicar_regras(obs_properties_t *props, obs_data_t *espelho, bool permitido)
{
	// O modo que o registro não grava vale `auto` (§6, item 7).
	const char *exp = texto_ou(espelho, "exposicao", "auto");
	const char *bal = texto_ou(espelho, "balanco", "auto");
	const char *foco = texto_ou(espelho, "foco", "auto");
	bool auto_exp = strcmp(exp, "auto") == 0;
	bool manual = strcmp(exp, "manual") == 0;
	bool trava_exp = obs_data_get_bool(espelho, "travaExposicao");

	for (size_t i = 0; i < N_CAMPOS; i++) {
		char chave[64];
		snprintf(chave, sizeof chave, PREFIXO "%s", CAMPOS[i]);
		habilitar(props, chave, permitido);
	}
	habilitar(props, PREFIXO "restaurar", permitido);
	habilitar(props, PREFIXO "passar_manual", permitido);

	// Exposição: o EV só com Auto e destravado; a trava só com Auto.
	habilitar(props, PREFIXO "ev", permitido && auto_exp && !trava_exp);
	mostrar(props, PREFIXO "nota_destrave", auto_exp && trava_exp);
	habilitar(props, PREFIXO "travaExposicao", permitido && auto_exp);
	// ISO e obturador: só com Manual; com Auto, a nota e o "Passar para Manual".
	mostrar(props, PREFIXO "iso", manual);
	mostrar(props, PREFIXO "obturadorNs", manual);
	mostrar(props, PREFIXO "nota_manual", !manual);
	mostrar(props, PREFIXO "passar_manual", !manual);
	// Balanço: o Kelvin só com Kelvin; a trava some com Kelvin e só vale com Auto.
	bool kelvin = strcmp(bal, "kelvin") == 0;
	mostrar(props, PREFIXO "kelvin", kelvin);
	mostrar(props, PREFIXO "travaBalanco", !kelvin);
	habilitar(props, PREFIXO "travaBalanco", permitido && strcmp(bal, "auto") == 0);
	// Foco: o "Perto ↔ Longe" só com Manual.
	mostrar(props, PREFIXO "focoPosicao", strcmp(foco, "manual") == 0);
	mostrar(props, PREFIXO "foco_metros", strcmp(foco, "manual") == 0);
}

// -------------------------------------------------------------------------------------------------
// O gesto
// -------------------------------------------------------------------------------------------------
static int indice_do_campo(const char *campo)
{
	for (size_t i = 0; i < N_CAMPOS; i++)
		if (strcmp(campo, CAMPOS[i]) == 0)
			return (int)i;
	return -1;
}

/// Pede um ajuste parcial `q` (um campo só), com `trava` na mão. Devolve se saiu.
static bool pedir(struct camera_remota *c, obs_data_t *q)
{
	const char *json = obs_data_get_json(q);
	enum QuallStatus st = quall_camera_remote_request(c->remoto, json);
	if (st != QUALL_STATUS_OK) {
		diga(LOG_WARNING, "câmera do aparelho: o pedido não saiu (status %d; configuração omitida): %s",
		     (int)st, registro_causa_status(st));
		return false;
	}
	c->ultimo_gesto_ns = agora_ns();
	return true;
}

/// O `modified_callback2` de cada controle. Ver "Só de gesto" no cabeçalho deste arquivo.
static bool ao_mexer(void *priv, obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	struct camera_remota *c = priv;
	const char *chave = obs_property_name(p);
	if (!c || !chave || strncmp(chave, PREFIXO, strlen(PREFIXO)) != 0)
		return false;
	const char *campo = chave + strlen(PREFIXO);
	int i = indice_do_campo(campo);
	// Sem valor de usuário: a chave foi apagada (o `.save`) ou nunca foi escrita. Nada a pedir.
	if (i < 0 || !obs_data_has_user_value(settings, chave))
		return false;

	bool refazer = false;
	pthread_mutex_lock(&c->trava);
	struct campo_na_tela info = c->campos[i];
	obs_data_t *q = obs_data_create();
	switch (info.tipo) {
	case TIPO_LISTA:
		obs_data_set_string(q, campo, obs_data_get_string(settings, chave));
		refazer = true;
		break;
	case TIPO_SIM_NAO:
		obs_data_set_bool(q, campo, obs_data_get_bool(settings, chave));
		refazer = true;
		break;
	case TIPO_NUMERO: {
		double v = info.guarda_inteiro ? (double)obs_data_get_int(settings, chave)
					       : obs_data_get_double(settings, chave);
		v -= info.origem;
		// `set_int` e não `set_double`: o `obs_data` guarda o tipo do número, e um `800.0` no
		// fio seria recusado num campo inteiro (revisão, I2).
		if (info.inteiro)
			obs_data_set_int(q, campo, llround(v));
		else
			obs_data_set_double(q, campo, v);
		break;
	}
	default:
		obs_data_release(q);
		pthread_mutex_unlock(&c->trava);
		return false;
	}

	if (c->remoto && c->permitido && !itens_iguais(q, c->espelho, campo) && pedir(c, q))
		copiar_item(q, c->espelho, campo);
	obs_data_release(q);
	// As listas e as caixas mudam o que se vê (o Manual mostra ISO e obturador): reaplicar as
	// regras e devolver `true` refaz os widgets **deste** `props`, sem chamar `get_properties`.
	// Os deslizantes devolvem `false`: refazer no meio de um arraste o cortaria.
	if (refazer)
		aplicar_regras(props, c->espelho, c->permitido);
	pthread_mutex_unlock(&c->trava);
	return refazer;
}

static bool ao_restaurar(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(p);
	struct camera_remota *c = dados;
	if (!c)
		return false;
	pthread_mutex_lock(&c->trava);
	if (c->remoto && c->permitido) {
		enum QuallStatus st = quall_camera_remote_restore(c->remoto);
		if (st == QUALL_STATUS_OK)
			c->ultimo_gesto_ns = agora_ns();
		else
			diga(LOG_WARNING, "câmera do aparelho: o restaurar não saiu (status %d): %s",
			     (int)st, registro_causa_status(st));
	}
	pthread_mutex_unlock(&c->trava);
	// O painel volta quando o estado novo chegar (o refazer da `laco`).
	return false;
}

static bool ao_passar_para_manual(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(p);
	struct camera_remota *c = dados;
	if (!c)
		return false;
	bool saiu = false;
	pthread_mutex_lock(&c->trava);
	if (c->remoto && c->permitido) {
		// "O 'Passar para Manual' manda `exposicao` sozinho" (§12): ISO e obturador partem do lido,
		// na casca do filmador.
		obs_data_t *q = obs_data_create();
		obs_data_set_string(q, "exposicao", "manual");
		if (pedir(c, q)) {
			copiar_item(q, c->espelho, "exposicao");
			saiu = true;
		}
		obs_data_release(q);
		aplicar_regras(props, c->espelho, c->permitido);
	}
	pthread_mutex_unlock(&c->trava);
	if (saiu) {
		obs_data_t *settings = obs_source_get_settings(c->fonte);
		obs_data_set_string(settings, PREFIXO "exposicao", "manual");
		obs_data_release(settings);
	}
	return saiu;
}

// -------------------------------------------------------------------------------------------------
// A montagem
// -------------------------------------------------------------------------------------------------
struct montagem {
	struct camera_remota *c;
	const char *json;
	obs_data_t *settings;
	obs_data_t *controles;
	obs_data_t *ajuste;
	obs_data_t *espelho;
	struct campo_na_tela campos[N_CAMPOS];
	struct unidades u;
};

// A montagem escreve o valor do ajuste no `settings` (para o widget mostrar) ou, sem valor, só tira
// o valor de usuário e deixa o padrão (`obs_data_unset_user_value`). **Nunca `obs_data_erase` aqui**:
// ele leva o padrão junto, e o widget mostraria zero.
//
// **O valor de agora tem de estar na lista.** A view do OBS, quando o valor do `settings` não está
// entre os itens de um combo, chama `ControlChanged` por conta própria (`AddList`, "trigger a
// settings update if the index was not found"): ela escreve o primeiro item e chama o callback —
// um pedido sem gesto. Por isso cada combo leva o valor atual, mesmo fora da escala ou da faixa.

static obs_property_t *linha(obs_properties_t *g, const char *nome, const char *texto, bool aviso)
{
	obs_property_t *p = obs_properties_add_text(g, nome, texto, OBS_TEXT_INFO);
	if (p) {
		obs_property_text_set_info_word_wrap(p, true);
		if (aviso)
			obs_property_text_set_info_type(p, OBS_TEXT_INFO_WARNING);
	}
	return p;
}

static obs_data_t *descritor(struct montagem *m, const char *campo)
{
	return m->controles ? obs_data_get_obj(m->controles, campo) : NULL;
}

/// Os `valores` de um descritor de lista, lidos do texto cru (o `obs_data` os descarta).
static size_t valores_de(struct montagem *m, const char *campo, char (*out)[24], size_t cap)
{
	const char *caminho[] = {"capacidades", "controles", campo, "valores"};
	const char *v = json_procurar(m->json, caminho, 4);
	return v ? json_lista_de_textos(v, &out[0][0], 24, cap) : 0;
}

static void ligar(struct montagem *m, obs_property_t *p)
{
	if (p)
		obs_property_set_modified_callback2(p, ao_mexer, m->c);
}

/// Uma lista (`exposicao`, `antiCintilacao`, `balanco`, `foco`).
static bool por_lista(struct montagem *m, obs_properties_t *g, const char *campo, const char *rotulo)
{
	char valores[16][24];
	size_t n = valores_de(m, campo, valores, 16);
	if (n == 0)
		return false;
	char chave[64];
	snprintf(chave, sizeof chave, PREFIXO "%s", campo);
	obs_property_t *p =
		obs_properties_add_list(g, chave, rotulo, OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	bool achou = false;
	const char *atual = tem_valor(m->ajuste, campo) ? obs_data_get_string(m->ajuste, campo) : NULL;
	for (size_t i = 0; i < n; i++) {
		obs_property_list_add_string(p, rotulo_do_valor(valores[i]), valores[i]);
		achou = achou || (atual && strcmp(atual, valores[i]) == 0);
	}
	if (atual && !achou) {
		// Um valor que a câmera tem e não oferece para pedir: aparece, apagado.
		size_t idx = obs_property_list_add_string(p, rotulo_do_valor(atual), atual);
		obs_property_list_item_disable(p, idx, true);
	}
	obs_data_set_default_string(m->settings, chave, valores[0]);
	if (atual)
		obs_data_set_string(m->settings, chave, atual);
	else
		obs_data_unset_user_value(m->settings, chave);
	m->campos[indice_do_campo(campo)].tipo = TIPO_LISTA;
	ligar(m, p);
	return true;
}

/// Uma caixa (`travaExposicao`, `travaBalanco`).
static bool por_caixa(struct montagem *m, obs_properties_t *g, const char *campo, const char *rotulo)
{
	obs_data_t *d = descritor(m, campo);
	if (!d)
		return false;
	obs_data_release(d);
	char chave[64];
	snprintf(chave, sizeof chave, PREFIXO "%s", campo);
	obs_property_t *p = obs_properties_add_bool(g, chave, rotulo);
	obs_data_set_default_bool(m->settings, chave, false);
	if (tem_valor(m->ajuste, campo))
		obs_data_set_bool(m->settings, chave, obs_data_get_bool(m->ajuste, campo));
	else
		obs_data_unset_user_value(m->settings, chave);
	m->campos[indice_do_campo(campo)].tipo = TIPO_SIM_NAO;
	ligar(m, p);
	return true;
}

/// Um número. ISO (sem `unidade`) e obturador viram combos de degraus (R9 §3.1, §3.2); o resto,
/// deslizante na faixa e no passo do descritor.
static bool por_numero(struct montagem *m, obs_properties_t *g, const char *campo, const char *rotulo)
{
	obs_data_t *d = descritor(m, campo);
	if (!d)
		return false;
	if (!tem_valor(d, "min") || !tem_valor(d, "max")) {
		obs_data_release(d);
		return false;
	}
	double min = obs_data_get_double(d, "min"), max = obs_data_get_double(d, "max");
	bool inteiro = obs_data_get_bool(d, "inteiro");
	double passo = tem_valor(d, "passo") ? obs_data_get_double(d, "passo") : 0;
	double origem = tem_valor(d, "origem") ? obs_data_get_double(d, "origem") : 0;
	bool log2 = strcmp(obs_data_get_string(d, "escala"), "log2") == 0;
	bool tem_analogico = tem_valor(d, "analogicoMax");
	double analogico = obs_data_get_double(d, "analogicoMax");
	obs_data_release(d);
	if (!(min <= max))
		return false;

	char chave[64];
	snprintf(chave, sizeof chave, PREFIXO "%s", campo);
	bool tem = tem_valor(m->ajuste, campo);
	double atual = tem ? obs_data_get_double(m->ajuste, campo) : min;
	struct campo_na_tela info = {TIPO_NUMERO, false, inteiro, 0};
	obs_property_t *p = NULL;

	bool iso_em_degraus = strcmp(campo, "iso") == 0 && !m->u.ganho;
	if (iso_em_degraus || strcmp(campo, "obturadorNs") == 0) {
		int64_t degraus[64];
		size_t n = iso_em_degraus ? degraus_de_iso(min, max, tem, atual, degraus, 63)
					  : degraus_do_obturador(min, max, log2, tem, atual, degraus, 63);
		if (n == 0)
			return false;
		// O atual fora da faixa (as regras só o põem dentro dela) entra no fim: ver o comentário
		// sobre `AddList` acima.
		bool achou = false;
		for (size_t i = 0; i < n; i++)
			achou = achou || degraus[i] == llround(atual);
		if (tem && !achou)
			degraus[n++] = llround(atual);
		p = obs_properties_add_list(g, chave, rotulo, OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
		for (size_t i = 0; i < n; i++) {
			char t[64], comp[96];
			texto_do_valor(campo, (double)degraus[i], m->u, t, sizeof t);
			if (iso_em_degraus && tem_analogico && (double)degraus[i] > analogico) {
				snprintf(comp, sizeof comp, texto_formato("Quall.Camera.GanhoDigital"), t);
				obs_property_list_add_int(p, comp, degraus[i]);
			} else {
				obs_property_list_add_int(p, t, degraus[i]);
			}
		}
		info.guarda_inteiro = true;
		info.inteiro = true; // os degraus já são inteiros (I2)
		obs_data_set_default_int(m->settings, chave, degraus[0]);
		if (tem)
			obs_data_set_int(m->settings, chave, llround(atual));
		else
			obs_data_unset_user_value(m->settings, chave);
	} else {
		info.origem = origem;
		double lo = min + origem, hi = max + origem;
		if (inteiro) {
			int p_int = passo >= 1 ? (int)llround(passo) : 1;
			p = obs_properties_add_int_slider(g, chave, rotulo, (int)llround(lo), (int)llround(hi),
							  p_int);
			info.guarda_inteiro = true;
			obs_data_set_default_int(m->settings, chave, llround(lo));
			if (tem)
				obs_data_set_int(m->settings, chave, llround(atual + origem));
			else
				obs_data_unset_user_value(m->settings, chave);
		} else {
			if (passo <= 0)
				passo = strcmp(campo, "focoPosicao") == 0 ? 0.01 : 0.1;
			p = obs_properties_add_float_slider(g, chave, rotulo, lo, hi, passo);
			obs_data_set_default_double(m->settings, chave, lo);
			if (tem)
				obs_data_set_double(m->settings, chave, atual + origem);
			else
				obs_data_unset_user_value(m->settings, chave);
		}
	}
	m->campos[indice_do_campo(campo)] = info;
	ligar(m, p);
	return true;
}

/// As linhas de "quem limita" de uma área (R9 §3.5): uma por frase, juntando os controles que a
/// mesma frase cobre ("O macOS não oferece ISO e o obturador para câmeras."), para uma área em que
/// nada se aplica não virar uma lista de linhas apagadas.
static int linhas_de_limite(struct montagem *m, obs_properties_t *g, obs_data_t *limites,
			    enum area_da_camera area)
{
	if (!limites)
		return 0;
	struct dstr nomes[LIMITE_OUTRO + 1] = {0};
	bool usada[LIMITE_OUTRO + 1] = {false};
	for (obs_data_item_t *it = obs_data_first(limites); it; obs_data_item_next(&it)) {
		const char *campo = obs_data_item_get_name(it);
		if (area_do_campo(campo) != area || obs_data_item_gettype(it) != OBS_DATA_STRING)
			continue;
		enum frase_de_limite f = frase_do_limite(obs_data_item_get_string(it));
		usada[f] = true;
		if (!limite_leva_controle(f))
			continue;
		const char *nome = nome_do_controle(campo, m->u);
		if (dstr_is_empty(&nomes[f])) {
			dstr_copy(&nomes[f], nome);
		} else {
			struct dstr junto = {0};
			dstr_printf(&junto, texto_formato("Quall.Camera.NomesJuntos"), nomes[f].array, nome);
			dstr_move(&nomes[f], &junto);
		}
	}
	int n = 0;
	for (int f = 0; f <= LIMITE_OUTRO; f++) {
		if (!usada[f])
			continue;
		char texto[512], nome[64];
		if (limite_leva_controle((enum frase_de_limite)f))
			snprintf(texto, sizeof texto, texto_formato(CHAVES_DE_LIMITE[f]),
				 nomes[f].array ? nomes[f].array : "");
		else
			snprintf(texto, sizeof texto, "%s", obs_module_text(CHAVES_DE_LIMITE[f]));
		snprintf(nome, sizeof nome, PREFIXO "limite.%d.%d", (int)area, f);
		linha(g, nome, texto, false);
		dstr_free(&nomes[f]);
		n++;
	}
	return n;
}

/// A linha do que a câmera diz estar usando (R9 §3.6) e as divergências. É um retrato da montagem:
/// o painel não se refaz pelo `lido` (refazer a 4 por segundo comeria teclas), como a linha de
/// estado da fonte.
static void linhas_do_lido(struct montagem *m, obs_properties_t *g, obs_data_t *estado)
{
	obs_data_t *lido = obs_data_get_obj(estado, "lido");
	if (!lido)
		return;
	static const char *const ordem[] = {"iso", "obturadorNs", "kelvin", "abertura"};
	struct dstr l = {0};
	for (size_t i = 0; i < sizeof ordem / sizeof ordem[0]; i++) {
		if (!tem_valor(lido, ordem[i]) || tipo_do_item(lido, ordem[i]) != OBS_DATA_NUMBER)
			continue;
		char t[64];
		texto_do_valor(ordem[i], obs_data_get_double(lido, ordem[i]), m->u, t, sizeof t);
		if (!dstr_is_empty(&l))
			dstr_cat(&l, " · ");
		dstr_cat(&l, t);
	}
	if (!dstr_is_empty(&l))
		linha(g, PREFIXO "lido", l.array, false);
	dstr_free(&l);

	char divergentes[8][24];
	const char *caminho[] = {"lido", "divergentes"};
	size_t n = json_lista_de_textos(json_procurar(m->json, caminho, 2), &divergentes[0][0], 24, 8);
	for (size_t i = 0; i < n; i++) {
		const char *campo = divergentes[i];
		if (!tem_valor(lido, campo) || !tem_valor(m->ajuste, campo) ||
		    tipo_do_item(lido, campo) != OBS_DATA_NUMBER ||
		    tipo_do_item(m->ajuste, campo) != OBS_DATA_NUMBER)
			continue;
		char a[64], b[64], texto[256], nome[64];
		texto_do_valor(campo, obs_data_get_double(lido, campo), m->u, a, sizeof a);
		texto_do_valor(campo, obs_data_get_double(m->ajuste, campo), m->u, b, sizeof b);
		snprintf(texto, sizeof texto, texto_formato("Quall.Camera.Usou"), a, b);
		snprintf(nome, sizeof nome, PREFIXO "divergente.%zu", i);
		linha(g, nome, texto, true);
	}
	obs_data_release(lido);
}

/// A linha da recusa, por 3 s (§3.5). `nao_permitido` já tem a linha fixa da situação.
static void linha_da_recusa(struct montagem *m, obs_properties_t *g, obs_data_t *estado,
			    bool nao_permitido)
{
	obs_data_t *rec = obs_data_get_obj(estado, "recusa");
	if (!rec)
		return;
	const char *campo = tem_valor(rec, "campo") ? obs_data_get_string(rec, "campo") : NULL;
	char texto[256];
	texto[0] = '\0';
	switch (frase_da_recusa(obs_data_get_string(rec, "motivo"))) {
	case RECUSA_NAO_PERMITIDO:
		if (!nao_permitido)
			snprintf(texto, sizeof texto, "%s", obs_module_text("Quall.Camera.NaoPermite"));
		break;
	case RECUSA_NAO_ACEITOU:
		snprintf(texto, sizeof texto, texto_formato("Quall.Camera.NaoAceitou"),
			 nome_do_controle(campo, m->u));
		break;
	case RECUSA_NAO_APLICOU:
		snprintf(texto, sizeof texto, "%s", obs_module_text("Quall.Camera.NaoAplicou"));
		break;
	case RECUSA_NAO_RESPONDEU:
		snprintf(texto, sizeof texto, "%s", obs_module_text("Quall.Camera.NaoRespondeu"));
		break;
	case RECUSA_NADA:
		break;
	}
	if (texto[0])
		linha(g, PREFIXO "recusa", texto, true);
	obs_data_release(rec);
}

/// **Os metros do foco manual**, quando a lente é calibrada: o descritor de `focoPosicao` traz
/// `calibrado`, as dioptrias da posição 1 (o mesmo contrato da casca Android). O deslizante do OBS
/// não troca o texto dos valores, então a distância vai numa linha embaixo dele, um retrato da
/// montagem como a do lido; sem calibração, só o "Perto ↔ Longe".
static void linha_dos_metros(struct montagem *m, obs_properties_t *g)
{
	obs_data_t *d = descritor(m, "focoPosicao");
	bool calibrado = d && tipo_do_item(d, "calibrado") == OBS_DATA_NUMBER;
	double dioptrias = calibrado ? obs_data_get_double(d, "calibrado") : 0;
	obs_data_release(d);
	if (!calibrado || !tem_valor(m->ajuste, "focoPosicao"))
		return;
	double metros = 0;
	char texto[128];
	if (metros_do_foco(dioptrias, obs_data_get_double(m->ajuste, "focoPosicao"), &metros)) {
		char n[32];
		numero_com_separador(metros, metros < 1 ? 2 : 1, separador_decimal(), n, sizeof n);
		snprintf(texto, sizeof texto, texto_formato("Quall.Camera.FocoEmMetros"), n);
	} else {
		snprintf(texto, sizeof texto, "%s", obs_module_text("Quall.Camera.FocoNoInfinito"));
	}
	linha(g, PREFIXO "foco_metros", texto, false);
}

static void fechar_area(obs_properties_t *grupo, obs_properties_t *area, int itens, const char *nome,
			const char *titulo)
{
	if (itens > 0)
		obs_properties_add_group(grupo, nome, titulo, OBS_GROUP_NORMAL, area);
	else
		obs_properties_destroy(area);
}

void camera_remota_propriedades(struct camera_remota *c, obs_properties_t *props)
{
	if (!c || !props)
		return;
	pthread_mutex_lock(&c->trava);
	char *json = c->estado ? bstrdup(c->estado) : NULL;
	pthread_mutex_unlock(&c->trava);

	obs_data_t *estado = json ? obs_data_create_from_json(json) : NULL;
	struct dstr estrutura = {0};
	estrutura_do_estado(json, estado, &estrutura);
	obs_data_t *caps = estado ? obs_data_get_obj(estado, "capacidades") : NULL;
	const char *situacao = estado ? obs_data_get_string(estado, "situacao") : "";

	struct montagem m = {0};
	m.c = c;
	m.json = json;
	m.espelho = obs_data_create();
	bool mostra = situacao_mostra(situacao) && caps && strcmp(estrutura.array, "oculto") != 0;
	bool permitido = strcmp(situacao, "pronto") == 0;

	if (mostra) {
		m.settings = obs_source_get_settings(c->fonte);
		m.controles = obs_data_get_obj(caps, "controles");
		m.ajuste = obs_data_get_obj(estado, "ajuste");
		if (!m.ajuste)
			m.ajuste = obs_data_create();
		m.u = unidades_do_estado(caps);
		for (size_t i = 0; i < N_CAMPOS; i++)
			copiar_item(m.ajuste, m.espelho, CAMPOS[i]);

		obs_properties_t *grupo = obs_properties_create();
		if (!permitido)
			linha(grupo, PREFIXO "nao_permitido", obs_module_text("Quall.Camera.NaoPermite"), true);
		linha_da_recusa(&m, grupo, estado, !permitido);
		linhas_do_lido(&m, grupo, estado);

		obs_data_t *limites = obs_data_get_obj(caps, "limites");

		// Exposição
		obs_properties_t *a = obs_properties_create();
		int n = 0;
		n += por_lista(&m, a, "exposicao", obs_module_text("Quall.Camera.Modo"));
		int ev = por_numero(&m, a, "ev",
				    obs_module_text(m.u.brilho ? "Quall.Camera.Brilho" : "Quall.Camera.Ev"));
		n += ev;
		if (ev)
			linha(a, PREFIXO "nota_destrave", obs_module_text("Quall.Camera.Destrave"), false);
		n += por_caixa(&m, a, "travaExposicao", obs_module_text("Quall.Camera.TravarExposicao"));
		n += por_lista(&m, a, "antiCintilacao", obs_module_text("Quall.Camera.AntiCintilacao"));
		n += linhas_de_limite(&m, a, limites, AREA_EXPOSICAO);
		fechar_area(grupo, a, n, PREFIXO "area.exposicao", obs_module_text("Quall.Camera.Exposicao"));

		// ISO e obturador (no Windows, ganho e obturador)
		a = obs_properties_create();
		n = 0;
		int numeros = por_numero(&m, a, "iso",
					 obs_module_text(m.u.ganho ? "Quall.Camera.Ganho" : "Quall.Camera.Iso"));
		numeros += por_numero(&m, a, "obturadorNs", obs_module_text("Quall.Camera.Obturador"));
		n += numeros;
		if (numeros > 0) {
			linha(a, PREFIXO "nota_manual",
			      obs_module_text(m.u.ganho ? "Quall.Camera.PasseParaManualGanho"
							: "Quall.Camera.PasseParaManual"),
			      false);
			char manual[16][24];
			size_t nv = valores_de(&m, "exposicao", manual, 16);
			for (size_t i = 0; i < nv; i++)
				if (strcmp(manual[i], "manual") == 0)
					obs_properties_add_button2(a, PREFIXO "passar_manual",
								   obs_module_text("Quall.Camera.PassarParaManual"),
								   ao_passar_para_manual, c);
		}
		n += linhas_de_limite(&m, a, limites, AREA_ISO_E_OBTURADOR);
		fechar_area(grupo, a, n, PREFIXO "area.iso",
			    obs_module_text(m.u.ganho ? "Quall.Camera.GanhoEObturador"
						      : "Quall.Camera.IsoEObturador"));

		// Balanço
		a = obs_properties_create();
		n = 0;
		n += por_lista(&m, a, "balanco", obs_module_text("Quall.Camera.Modo"));
		n += por_numero(&m, a, "kelvin", obs_module_text("Quall.Camera.Kelvin"));
		n += por_caixa(&m, a, "travaBalanco", obs_module_text("Quall.Camera.TravarBalanco"));
		n += linhas_de_limite(&m, a, limites, AREA_BALANCO);
		fechar_area(grupo, a, n, PREFIXO "area.balanco", obs_module_text("Quall.Camera.Balanco"));

		// Foco
		a = obs_properties_create();
		n = 0;
		n += por_lista(&m, a, "foco", obs_module_text("Quall.Camera.Modo"));
		int foco_manual = por_numero(&m, a, "focoPosicao", obs_module_text("Quall.Camera.PertoLonge"));
		n += foco_manual;
		if (foco_manual)
			linha_dos_metros(&m, a);
		n += linhas_de_limite(&m, a, limites, AREA_FOCO);
		fechar_area(grupo, a, n, PREFIXO "area.foco", obs_module_text("Quall.Camera.Foco"));
		obs_data_release(limites);

		obs_properties_add_button2(grupo, PREFIXO "restaurar", obs_module_text("Quall.Camera.Restaurar"),
					   ao_restaurar, c);

		const char *nome_da_camera = obs_data_get_string(caps, "nomeDaCamera");
		char titulo[256];
		if (nome_da_camera && *nome_da_camera)
			snprintf(titulo, sizeof titulo, texto_formato("Quall.Camera.ComNome"), nome_da_camera);
		else
			snprintf(titulo, sizeof titulo, "%s", obs_module_text("Quall.Camera"));
		obs_properties_add_group(props, PREFIXO "grupo", titulo, OBS_GROUP_NORMAL, grupo);
	}

	pthread_mutex_lock(&c->trava);
	if (mostra) {
		obs_data_release(c->espelho);
		c->espelho = m.espelho;
		obs_data_addref(m.espelho);
		memcpy(c->campos, m.campos, sizeof c->campos);
		c->permitido = permitido;
		aplicar_regras(props, c->espelho, permitido);
	} else {
		c->permitido = false;
	}
	bfree(c->estrutura_na_tela);
	c->estrutura_na_tela = bstrdup(estrutura.array);
	pthread_mutex_unlock(&c->trava);

	obs_data_release(m.espelho);
	obs_data_release(m.settings);
	obs_data_release(m.controles);
	obs_data_release(m.ajuste);
	obs_data_release(caps);
	obs_data_release(estado);
	dstr_free(&estrutura);
	bfree(json);
}
