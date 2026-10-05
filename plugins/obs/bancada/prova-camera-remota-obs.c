// Banco de prova de `src/camera-remota.c` **com a libobs de verdade**, sem abrir o OBS: a libobs do
// OBS.app sobe sem vídeo (`obs_startup`), uma fonte mínima usa o grupo "Câmera do aparelho", e a
// prova passa pelo mesmo caminho que a janela de propriedades — `obs_source_properties`, que chama o
// `get_properties` **e depois `obs_properties_apply_settings`**, ou seja, todos os
// `modified_callback` a cada montagem (`obs-source.c:1032-1039`; achado B1 da revisão).
//
// O núcleo fica de fora de propósito: as funções `quall_*` que o arquivo chama são trocadas por
// macro antes do `#include`, e a prova conta os pedidos que **sairiam**. O caminho das mensagens é
// do núcleo, provado em `crates/quall-core/src/camera_remota/testes.rs` e na fronteira C.
//
//     B=plugins/obs; L=$B/.libobs/obs-studio/libobs; F=/Applications/OBS.app/Contents/Frameworks
//     cc -Wall -Wextra -Wno-unused-parameter -I$L -I$B/.libobs/simde -I$B/build-portao/gerado \
//        -Icrates/quall-ffi/include -F$F -framework libobs -Wl,-rpath,$F \
//        -o "$TMPDIR/prova-camera-remota-obs" $B/bancada/prova-camera-remota-obs.c \
//        $B/src/camera-remota-regras.c && "$TMPDIR/prova-camera-remota-obs"
//
// (`build-portao/gerado` é o `obsconfig.h` que o `tools/portao.sh --so obs` gera.)

// --- o núcleo trocado por contadores ------------------------------------------------------------
// As macros vêm **antes** de qualquer `#include <quall.h>`: o cabeçalho, incluído pelo arquivo
// provado, declara então as funções de prova com as assinaturas da fronteira.
#define quall_camera_remote_request prova_request
#define quall_camera_remote_restore prova_restore
#define quall_camera_remote_state_json prova_state_json
#define quall_camera_remote_pump prova_pump
#define quall_camera_remote_new prova_new
#define quall_camera_remote_free prova_free
#define quall_session_messages prova_messages
#define quall_messages_free prova_messages_free
#define quall_last_error prova_last_error
#define quall_last_status prova_last_status

#include "../src/camera-remota.c"
// Os textos de verdade, das `.ini` (`texto_formato` confere as conversões contra o `pt-BR`).
#include "../src/texto.c"

#include <stdio.h>

obs_module_t *obs_current_module(void)
{
	return NULL;
}

static int pedidos, restauros;
static char ultimo_pedido[512];
static enum QuallStatus resposta_do_request = QUALL_STATUS_OK;

enum QuallStatus prova_request(const QuallCameraRemote *r, const char *json)
{
	(void)r;
	pedidos++;
	// Sem espaços, para comparar com o esperado: o `obs_data_get_json` indenta.
	size_t n = 0;
	for (const char *p = json; *p && n + 1 < sizeof ultimo_pedido; p++)
		if (*p != ' ' && *p != '\n' && *p != '\t')
			ultimo_pedido[n++] = *p;
	ultimo_pedido[n] = '\0';
	return resposta_do_request;
}
enum QuallStatus prova_restore(const QuallCameraRemote *r)
{
	(void)r;
	restauros++;
	return QUALL_STATUS_OK;
}
intptr_t prova_state_json(const QuallCameraRemote *r, char *b, uintptr_t c)
{
	(void)r, (void)b, (void)c;
	return -1;
}
enum QuallStatus prova_pump(const QuallCameraRemote *r, const QuallMessages *m, uint32_t t, uint32_t *ch)
{
	(void)r, (void)m, (void)t, (void)ch;
	return QUALL_STATUS_OK;
}
QuallCameraRemote *prova_new(void)
{
	return NULL;
}
void prova_free(QuallCameraRemote *r)
{
	(void)r;
}
QuallMessages *prova_messages(const QuallSession *s)
{
	(void)s;
	return NULL;
}
void prova_messages_free(QuallMessages *m)
{
	(void)m;
}
const char *prova_last_error(void)
{
	return "prova";
}

enum QuallStatus prova_last_status(void)
{
	return resposta_do_request;
}

// --- a fonte mínima ------------------------------------------------------------------------------
static const char *nome_da_prova(void *t)
{
	(void)t;
	return "prova da câmera";
}
static void *criar_prova(obs_data_t *s, obs_source_t *f)
{
	(void)s;
	return camera_remota_criar(f);
}
static void destruir_prova(void *d)
{
	camera_remota_destruir(d);
}
static obs_properties_t *propriedades_da_prova(void *d)
{
	obs_properties_t *p = obs_properties_create();
	camera_remota_propriedades(d, p);
	return p;
}
static void salvar_prova(void *d, obs_data_t *s)
{
	(void)d;
	camera_remota_nao_salvar(s);
}
static struct obs_source_info info_da_prova = {
	.id = "quall_prova_camera",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO,
	.get_name = nome_da_prova,
	.create = criar_prova,
	.destroy = destruir_prova,
	.get_properties = propriedades_da_prova,
	.save = salvar_prova,
};

// --- conferências --------------------------------------------------------------------------------
static int falhas, casos;

static void confere(const char *caso, bool ok)
{
	casos++;
	if (!ok) {
		falhas++;
		printf("FALHOU %s\n", caso);
	}
}

static void confere_pedidos(const char *caso, int esperado, const char *json)
{
	casos++;
	if (pedidos != esperado || (json && strcmp(ultimo_pedido, json) != 0)) {
		falhas++;
		printf("FALHOU %s: %d pedidos (esperado %d), último %s (esperado %s)\n", caso, pedidos,
		       esperado, ultimo_pedido, json ? json : "-");
	}
}

static int refazeres;
static void ao_refazer(void *d, calldata_t *cd)
{
	(void)d, (void)cd;
	refazeres++;
}

static void por_estado(struct camera_remota *c, const char *json)
{
	pthread_mutex_lock(&c->trava);
	bfree(c->estado);
	c->estado = json ? bstrdup(json) : NULL;
	pthread_mutex_unlock(&c->trava);
}

/// Monta o painel como a janela do OBS: `get_properties` + `apply_settings` (todos os callbacks).
static obs_properties_t *montar(obs_source_t *fonte)
{
	return obs_source_properties(fonte);
}

/// A mexida da pessoa: o widget escreve no `settings` e a view chama o callback do controle.
static void mexer(obs_properties_t *props, obs_source_t *fonte, const char *chave)
{
	obs_data_t *s = obs_source_get_settings(fonte);
	obs_property_modified(obs_properties_get(props, chave), s);
	obs_data_release(s);
}

static const char *descricao(obs_properties_t *props, const char *nome)
{
	obs_property_t *p = obs_properties_get(props, nome);
	return p ? obs_property_description(p) : "";
}

#define CAPS_ANDROID                                                                                   \
	"{\"plataforma\":\"android\",\"nomeDaCamera\":\"Traseira\",\"controles\":{"                    \
	"\"antiCintilacao\":{\"valores\":[\"auto\",\"50\",\"60\",\"desligada\"]},"                     \
	"\"balanco\":{\"valores\":[\"auto\",\"incandescente\",\"fluorescente\",\"luzDoDia\",\"nublado\"," \
	"\"kelvin\"]},\"ev\":{\"max\":2.0,\"min\":-2.0,\"passo\":0.1},"                                 \
	"\"exposicao\":{\"valores\":[\"auto\",\"manual\"]},\"foco\":{\"valores\":[\"auto\",\"travado\"," \
	"\"manual\"]},\"focoPosicao\":{\"calibrado\":10.0,\"max\":1.0,\"min\":0.0,\"passo\":0.01},"     \
	"\"iso\":{\"analogicoMax\":800,\"inteiro\":true,\"max\":3200,\"min\":50},"                       \
	"\"kelvin\":{\"inteiro\":true,\"max\":10000,\"min\":2000,\"passo\":100},"                       \
	"\"obturadorNs\":{\"inteiro\":true,\"max\":33333333,\"min\":100000},\"toque\":{},"             \
	"\"travaBalanco\":{},\"travaExposicao\":{}},\"limites\":{}}"

static char *estado_android(const char *situacao, const char *ajuste, const char *extra)
{
	struct dstr d = {0};
	dstr_printf(&d,
		    "{\"situacao\":\"%s\",\"capacidades\":" CAPS_ANDROID ",\"ajuste\":%s,\"aplicado\":%s,"
		    "\"pendente\":{},\"lido\":{\"iso\":400,\"obturadorNs\":16666666,\"kelvin\":5150,"
		    "\"abertura\":1.7,\"divergentes\":[\"iso\"]},\"autor\":null,\"versao\":17%s}",
		    situacao, ajuste, ajuste, extra ? extra : "");
	return d.array;
}

int main(void)
{
	base_set_log_handler(NULL, NULL);
	if (!obs_startup("pt-BR", NULL, NULL)) {
		printf("a libobs não subiu\n");
		return 2;
	}
	obs_module_lookup = text_lookup_create("plugins/obs/data/locale/pt-BR.ini");
	lookup_pt = text_lookup_create("plugins/obs/data/locale/pt-BR.ini");
	if (!obs_module_lookup || !lookup_pt) {
		printf("rode da raiz do repositório (não achei plugins/obs/data/locale/pt-BR.ini)\n");
		return 2;
	}
	obs_register_source(&info_da_prova);
	obs_source_t *fonte = obs_source_create("quall_prova_camera", "prova", NULL, NULL);
	struct camera_remota *c = obs_obj_get_data(fonte);
	signal_handler_connect(obs_source_get_signal_handler(fonte), "update_properties", ao_refazer,
			       NULL);
	c->remoto = (QuallCameraRemote *)(uintptr_t)1; // nunca é tocado: as funções são de prova

	const char *ajuste1 = "{\"exposicao\":\"manual\",\"ev\":0,\"travaExposicao\":false,\"iso\":400,"
			      "\"obturadorNs\":16666666,\"antiCintilacao\":\"auto\",\"balanco\":\"auto\","
			      "\"kelvin\":null,\"travaBalanco\":false,\"foco\":\"auto\",\"focoPosicao\":null}";

	// 1. Sem estado, nada de grupo.
	obs_properties_t *props = montar(fonte);
	confere("sem estado: sem grupo", obs_properties_get(props, "camera.grupo") == NULL);
	obs_properties_destroy(props);

	// 2. `esperando` também não mostra.
	char *e = estado_android("esperando", ajuste1, NULL);
	por_estado(c, e);
	bfree(e);
	props = montar(fonte);
	confere("esperando: sem grupo", obs_properties_get(props, "camera.grupo") == NULL);
	obs_properties_destroy(props);

	// 3. `pronto`: o grupo, e **nenhum pedido** na montagem (o `apply_settings` chamou todos os
	//    callbacks).
	e = estado_android("pronto", ajuste1, NULL);
	por_estado(c, e);
	bfree(e);
	props = montar(fonte);
	confere("pronto: grupo", obs_properties_get(props, "camera.grupo") != NULL);
	confere_pedidos("montagem não pede", 0, NULL);
	confere("título com o nome da câmera",
		strcmp(descricao(props, "camera.grupo"), "Câmera do aparelho — Traseira") == 0);
	confere("ISO visível com Manual", obs_property_visible(obs_properties_get(props, "camera.iso")));
	confere("nota do Manual escondida com Manual",
		!obs_property_visible(obs_properties_get(props, "camera.nota_manual")));
	confere("EV apagado com Manual", !obs_property_enabled(obs_properties_get(props, "camera.ev")));
	confere("Kelvin escondido com balanço Auto",
		!obs_property_visible(obs_properties_get(props, "camera.kelvin")));
	confere("Perto↔Longe escondido com foco Auto",
		!obs_property_visible(obs_properties_get(props, "camera.focoPosicao")));
	confere("linha do lido", strcmp(descricao(props, "camera.lido"),
					"ISO 400 · 1/60 s · 5150 K · f/1,7") == 0);
	confere("toque não aparece (o OBS não tem toque)",
		obs_properties_get(props, "camera.toque") == NULL);
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		confere("settings com o ISO aplicado", obs_data_get_int(s, "camera.iso") == 400);
		confere("Kelvin nulo do Android sem valor de usuário",
			!obs_data_has_user_value(s, "camera.kelvin"));
		obs_data_release(s);
		obs_property_t *iso = obs_properties_get(props, "camera.iso");
		size_t n = obs_property_list_item_count(iso);
		bool tem_digital = false;
		for (size_t i = 0; i < n; i++)
			if (obs_property_list_item_int(iso, i) == 1000)
				tem_digital = strstr(obs_property_list_item_name(iso, i), "ganho digital") != NULL;
		confere("ISO acima do analógico marcado", tem_digital);
	}

	// 4. A mexida da pessoa: um pedido, só do campo mexido, inteiro sem `.0`.
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		obs_data_set_int(s, "camera.iso", 800);
		obs_data_release(s);
	}
	mexer(props, fonte, "camera.iso");
	confere_pedidos("mexer no ISO", 1, "{\"iso\":800}");
	mexer(props, fonte, "camera.iso");
	confere_pedidos("o mesmo valor de novo não pede", 1, NULL);
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		obs_data_set_int(s, "camera.obturadorNs", 8333333);
		obs_data_set_double(s, "camera.ev", 0.3);
		obs_data_release(s);
	}
	mexer(props, fonte, "camera.obturadorNs");
	confere_pedidos("mexer no obturador", 2, "{\"obturadorNs\":8333333}");
	obs_properties_destroy(props);

	// 5. Outro aparelho mudou o ISO (o estado anda): remontar escreve o valor novo e não pede.
	const char *ajuste2 = "{\"exposicao\":\"manual\",\"iso\":1600,\"obturadorNs\":8333333,"
			      "\"balanco\":\"kelvin\",\"kelvin\":5200,\"foco\":\"manual\",\"focoPosicao\":0.4}";
	e = estado_android("pronto", ajuste2, NULL);
	por_estado(c, e);
	bfree(e);
	props = montar(fonte);
	confere_pedidos("remontar com o valor de outro não pede", 2, NULL);
	confere("Kelvin visível com Kelvin", obs_property_visible(obs_properties_get(props, "camera.kelvin")));
	confere("trava de balanço escondida com Kelvin",
		!obs_property_visible(obs_properties_get(props, "camera.travaBalanco")));
	confere("Perto↔Longe visível com Manual",
		obs_property_visible(obs_properties_get(props, "camera.focoPosicao")));
	confere("metros do foco calibrado (10 dioptrias em 1, posição 0,4)",
		strcmp(descricao(props, "camera.foco_metros"), "Foco a 0,25 m") == 0);

	// 6. A corrida do B1: a montagem escreveu v2, e o estado anda para v3 **antes** do
	//    `apply_settings` (outra thread). O callback compara com o que a montagem escreveu: nada sai.
	obs_properties_destroy(props);
	props = obs_properties_create();
	camera_remota_propriedades(c, props);
	const char *ajuste3 = "{\"exposicao\":\"manual\",\"iso\":3200,\"obturadorNs\":8333333}";
	e = estado_android("pronto", ajuste3, NULL);
	por_estado(c, e);
	bfree(e);
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		obs_properties_apply_settings(props, s);
		obs_data_release(s);
	}
	confere_pedidos("estado que anda no meio da montagem não pede", 2, NULL);
	obs_properties_destroy(props);

	// 7. Não salvo com a cena; e, com a chave apagada pelo `.save` e o diálogo aberto, o callback
	//    não pede.
	props = montar(fonte);
	{
		obs_data_t *salvo = obs_save_source(fonte);
		const char *j = obs_data_get_json(salvo);
		confere("a coleção não leva camera.*", strstr(j, "camera.") == NULL);
		obs_data_release(salvo);
	}
	mexer(props, fonte, "camera.iso");
	mexer(props, fonte, "camera.exposicao");
	confere_pedidos("chave apagada pelo .save não pede", 2, NULL);

	// 8. Uma lista: "Auto" na exposição pede só `exposicao`, e mostra a nota do Manual.
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		obs_data_set_string(s, "camera.exposicao", "auto");
		obs_data_release(s);
	}
	mexer(props, fonte, "camera.exposicao");
	confere_pedidos("mexer na exposição", 3, "{\"exposicao\":\"auto\"}");
	confere("com Auto, o ISO some", !obs_property_visible(obs_properties_get(props, "camera.iso")));
	confere("com Auto, o Passar para Manual aparece",
		obs_property_visible(obs_properties_get(props, "camera.passar_manual")));
	obs_property_button_clicked(obs_properties_get(props, "camera.passar_manual"), fonte);
	confere_pedidos("Passar para Manual", 4, "{\"exposicao\":\"manual\"}");
	obs_property_button_clicked(obs_properties_get(props, "camera.restaurar"), fonte);
	confere("Restaurar automático", restauros == 1);
	obs_properties_destroy(props);

	// 9. O refazer: estrutura nova (outra câmera) pede ao OBS; a mesma assinatura não pede de novo;
	//    logo depois de um `.update` (alguém digitando), espera.
	c->ultimo_gesto_ns = 0;
	c->ultimo_update_ns = 0;
	c->ultimo_refazer_ns = 0;
	int antes = refazeres;
	e = estado_android("nao_permitido", ajuste3, NULL);
	por_estado(c, e);
	bfree(e);
	talvez_refazer(c, agora_ns());
	confere("situação nova refaz", refazeres == antes + 1);
	talvez_refazer(c, agora_ns() + 10 * REFAZER_NO_MAXIMO_NS);
	confere("a mesma assinatura não refaz", refazeres == antes + 1);
	// (O painel montado por último é o `pronto` do caso 7: sem janela aberta, ninguém remontou com o
	// `nao_permitido`. O grupo sumir, `sem_camera`, é estrutura nova em relação a ele.)
	e = estado_android("sem_camera", ajuste3, NULL);
	por_estado(c, e);
	bfree(e);
	camera_remota_ajustes_mudaram(c);
	talvez_refazer(c, agora_ns());
	confere("com a pessoa digitando, não refaz", refazeres == antes + 1);
	talvez_refazer(c, agora_ns() + QUIETO_DEPOIS_DO_UPDATE_NS + 1);
	confere("depois da quietude, refaz", refazeres == antes + 2);

	// 10. `nao_permitido`: a linha, os controles apagados com os valores, e nenhum pedido.
	e = estado_android("nao_permitido", ajuste3, NULL);
	por_estado(c, e);
	bfree(e);
	props = montar(fonte);
	confere("nao_permitido: a frase", strcmp(descricao(props, "camera.nao_permitido"),
						 "O aparelho não permite controle remoto da câmera") == 0);
	confere("nao_permitido: ISO apagado", !obs_property_enabled(obs_properties_get(props, "camera.iso")));
	confere("nao_permitido: Restaurar apagado",
		!obs_property_enabled(obs_properties_get(props, "camera.restaurar")));
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		confere("nao_permitido: com os valores", obs_data_get_int(s, "camera.iso") == 3200);
		obs_data_set_int(s, "camera.iso", 100);
		obs_data_release(s);
	}
	mexer(props, fonte, "camera.iso");
	confere_pedidos("nao_permitido não pede", 4, NULL);
	obs_properties_destroy(props);

	// 11. A recusa com frase, e o ISO fora da faixa e o valor fora da lista ainda no combo (a view
	//     do OBS chama o callback sozinha quando o valor não está na lista).
	e = estado_android("pronto",
			   "{\"exposicao\":\"manual\",\"iso\":12800,\"antiCintilacao\":\"vela\"}",
			   ",\"recusa\":{\"motivo\":\"fora_da_faixa\",\"campo\":\"iso\",\"ha_ms\":300}");
	por_estado(c, e);
	bfree(e);
	props = montar(fonte);
	confere("recusa: a frase", strcmp(descricao(props, "camera.recusa"),
					  "Este aparelho não aceitou ISO.") == 0);
	{
		obs_property_t *iso = obs_properties_get(props, "camera.iso");
		bool achou = false;
		for (size_t i = 0; i < obs_property_list_item_count(iso); i++)
			achou = achou || obs_property_list_item_int(iso, i) == 12800;
		confere("ISO fora da faixa no combo", achou);
		obs_property_t *ac = obs_properties_get(props, "camera.antiCintilacao");
		size_t n = obs_property_list_item_count(ac);
		confere("valor fora da lista no combo, apagado",
			n == 5 && strcmp(obs_property_list_item_string(ac, 4), "vela") == 0 &&
				obs_property_list_item_disabled(ac, 4));
	}
	confere_pedidos("montagem com recusa não pede", 4, NULL);
	obs_properties_destroy(props);

	// 12. O Mac: só travas e foco; "quem limita" numa linha por frase, juntando os controles.
	por_estado(c,
		   "{\"situacao\":\"pronto\",\"capacidades\":{\"plataforma\":\"macos\",\"controles\":{"
		   "\"travaExposicao\":{},\"travaBalanco\":{},\"foco\":{\"valores\":[\"auto\",\"travado\"]},"
		   "\"toque\":{}},\"limites\":{\"ev\":\"macos\",\"iso\":\"macos\",\"obturadorNs\":\"macos\","
		   "\"kelvin\":\"macos\",\"antiCintilacao\":\"macos\",\"focoPosicao\":\"macos\"}},"
		   "\"ajuste\":{\"travaExposicao\":false,\"travaBalanco\":false,\"foco\":\"auto\"},"
		   "\"pendente\":{},\"lido\":{}}");
	props = montar(fonte);
	confere("Mac: ISO e obturador numa linha",
		strcmp(descricao(props, "camera.limite.1.1"),
		       "O macOS não oferece ISO e o obturador para câmeras.") == 0);
	confere("Mac: sem ISO", obs_properties_get(props, "camera.iso") == NULL);
	confere("Mac: área ISO existe pela linha", obs_properties_get(props, "camera.area.iso") != NULL);
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		obs_data_set_bool(s, "camera.travaExposicao", true);
		obs_data_release(s);
	}
	mexer(props, fonte, "camera.travaExposicao");
	confere_pedidos("Mac: travar exposição", 5, "{\"travaExposicao\":true}");
	obs_properties_destroy(props);

	// 13. O Windows: brilho com origem, ganho em deslizante, obturador log2 inteiro.
	por_estado(c,
		   "{\"situacao\":\"pronto\",\"capacidades\":{\"plataforma\":\"windows\",\"controles\":{"
		   "\"exposicao\":{\"valores\":[\"auto\",\"manual\"]},"
		   "\"ev\":{\"min\":-64,\"max\":64,\"passo\":1,\"inteiro\":true,\"unidade\":\"brilho\","
		   "\"origem\":128},\"iso\":{\"min\":0,\"max\":100,\"inteiro\":true,\"unidade\":\"ganho\"},"
		   "\"obturadorNs\":{\"min\":122070,\"max\":31250000,\"inteiro\":true,\"escala\":\"log2\"}},"
		   "\"limites\":{\"focoPosicao\":\"camera_nao_oferece\",\"foco\":\"camera_nao_oferece\","
		   "\"antiCintilacao\":\"outro_app\"}},"
		   "\"ajuste\":{\"exposicao\":\"auto\",\"ev\":0},\"pendente\":{},\"lido\":{}}");
	props = montar(fonte);
	confere("Windows: Brilho", strcmp(descricao(props, "camera.ev"), "Brilho") == 0);
	confere("Windows: área Ganho e obturador",
		strcmp(descricao(props, "camera.area.iso"), "Ganho e obturador") == 0);
	confere("Windows: foco sem câmera que ofereça",
		strcmp(descricao(props, "camera.limite.3.3"),
		       "Esta câmera não oferece a trava de foco e o foco manual.") == 0 ||
			strcmp(descricao(props, "camera.limite.3.3"),
			       "Esta câmera não oferece o foco manual e a trava de foco.") == 0);
	{
		obs_data_t *s = obs_source_get_settings(fonte);
		confere("Windows: brilho mostrado com a origem", obs_data_get_int(s, "camera.ev") == 128);
		obs_data_set_int(s, "camera.ev", 140);
		obs_data_release(s);
		obs_property_t *ob = obs_properties_get(props, "camera.obturadorNs");
		bool inteiros = obs_property_list_item_count(ob) == 9;
		confere("Windows: nove degraus log2", inteiros);
	}
	mexer(props, fonte, "camera.ev");
	confere_pedidos("Windows: brilho volta sem a origem", 6, "{\"ev\":12}");
	obs_properties_destroy(props);

	// 14. O fim da sessão: o remoto sai, o estado some, e o grupo também.
	camera_remota_acabar(c, false);
	props = montar(fonte);
	confere("depois da sessão, sem grupo", obs_properties_get(props, "camera.grupo") == NULL);
	obs_properties_destroy(props);

	obs_source_release(fonte);
	obs_module_free_locale();
	obs_shutdown();
	printf("%d casos, %d falhas\n", casos, falhas);
	return falhas ? 1 : 0;
}
