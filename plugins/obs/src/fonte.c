#include "quall-obs.h"

#include <string.h>

// =================================================================================================
// A fonte. Uma por aparelho: cada instância tem a própria sessão, a própria thread e o próprio
// decodificador, e nada é compartilhado entre elas além do navegador mDNS do módulo.
// =================================================================================================

static const char *nome_da_fonte(void *tipo)
{
	UNUSED_PARAMETER(tipo);
	return obs_module_text("Quall.Fonte");
}

static void padroes(obs_data_t *a)
{
	obs_data_set_default_string(a, "aparelho", "manual");
	obs_data_set_default_string(a, "endereco", "");
	obs_data_set_default_string(a, "pin", "");
	char maquina[256];
	identidade_maquina(maquina, sizeof(maquina));
	char nome[320];
	snprintf(nome, sizeof(nome), "OBS (%s)", maquina);
	obs_data_set_default_string(a, "nome", nome);
	// Sem buffer por padrão: espelhamento é ao vivo, e o buffer do OBS troca latência por
	// suavidade. Quem estiver numa rede ruim liga.
	obs_data_set_default_bool(a, "sem_buffer", true);
	// A porta que segura o quadro de referência condenada. **Desligada por padrão**, e é
	// reversão medida: em 31/08 o emissor mandou 31 IDR e o receptor viu 13, e todos os oito
	// intervalos sem referência terminaram na válvula de 2 s em vez de na cura. Onde o IDR não
	// chega, a porta troca imagem suja por tela parada. Ver `struct receptor::congelar`.
	obs_data_set_default_bool(a, "congelar", false);
	obs_data_set_default_bool(a, "gravar", false);
}

// -------------------------------------------------------------------------------------------------
// As trilhas de áudio das fontes salvas antes do som (crítica 14, G1)
//
// Antes da S5 a fonte não tinha `OBS_SOURCE_AUDIO`, e a libobs salvava `"mixers": 0` (o que
// `obs_source_get_audio_mixers` devolve para fonte sem som). Ao carregar, o padrão 0x3F só vale
// quando a chave **falta** (`obs.c:2315-2317`): com o 0 salvo, a fonte do Quall abria com as
// trilhas todas desligadas, o medidor andava e a gravação e a transmissão saíam **sem o som**, sem
// aviso. É o caso da coleção do Pessoa Exemplo hoje.
//
// A migração é **uma vez por fonte**, no `.load` — que a libobs chama depois de aplicar o
// `mixers` e as `private_settings` salvas (`obs.c:2317`, `:2359-2362`, `:2424`) —, com a marca
// `MARCA_DAS_TRILHAS` nas `private_settings`: sem a marca e com `mixers` 0, liga 0x3F (o padrão da
// própria libobs) e diz no diário. Com a marca, um 0 é escolha de quem usa, e fica. Toda fonte
// nasce com a marca (`criar`): numa fonte nova, um 0 escolhido depois também fica. A coleção
// salva não é tocada aqui; a migração acontece quando o OBS abre a fonte com este plugin, e a
// marca vai para o disco no próximo salvamento do próprio OBS.
//
// **A volta de um plugin sem som** (crítica 16, a migração): a coleção salva com este plugin tem a
// marca; aberta com um plugin de antes da S5 (ou sem o plugin), a libobs a salva com `"mixers": 0`
// e **mantém** as `private_settings`, a marca junto. Voltando a este plugin, o 0 parecia escolha, e a
// fonte ficava muda. Então cada salvamento com este plugin grava também as trilhas que ele salvou
// (`TRILHAS_SALVAS`, no `.save`, que a libobs chama antes de serializar as `private_settings`,
// `obs.c:2465` → `:2502`): um 0 com a marca e com as trilhas salvas diferentes de 0 veio de um
// salvamento sem este plugin, e as trilhas salvas voltam. Um 0 escolhido aqui é salvo como 0 nas
// duas chaves, e fica.
// -------------------------------------------------------------------------------------------------
#define MARCA_DAS_TRILHAS "quall_trilhas_de_audio_conferidas"
#define TRILHAS_SALVAS "quall_trilhas_de_audio_salvas"

static void marcar_trilhas(obs_source_t *fonte)
{
	obs_data_t *priv = obs_source_get_private_settings(fonte);
	obs_data_set_bool(priv, MARCA_DAS_TRILHAS, true);
	obs_data_release(priv);
}

static void *criar(obs_data_t *ajustes, obs_source_t *fonte)
{
	struct receptor *r = receptor_criar(fonte);
	receptor_atualizar(r, ajustes);
	// Numa fonte carregada de uma coleção, as `private_settings` são trocadas pelas salvas logo
	// depois do `create` (`obs.c:2359-2362`): a marca daqui só fica na fonte nova.
	marcar_trilhas(fonte);
	return r;
}

static void carregar(void *dados, obs_data_t *ajustes)
{
	// Uma coleção salva por um build em que as chaves da câmera escapassem: elas saem aqui também.
	camera_remota_nao_salvar(ajustes);
	obs_source_t *fonte = receptor_fonte(dados);
	obs_data_t *priv = obs_source_get_private_settings(fonte);
	bool conferida = obs_data_get_bool(priv, MARCA_DAS_TRILHAS);
	bool tem_salvas = obs_data_has_user_value(priv, TRILHAS_SALVAS);
	uint32_t salvas = (uint32_t)obs_data_get_int(priv, TRILHAS_SALVAS);
	obs_data_release(priv);
	if (conferida) {
		if (obs_source_get_audio_mixers(fonte) == 0 && tem_salvas && salvas != 0) {
			obs_source_set_audio_mixers(fonte, salvas);
			diga(LOG_INFO,
			     "%s: a fonte foi salva sem o som do Quall (um plugin de antes, ou sem o plugin) e veio "
			     "com as trilhas de áudio desligadas: voltaram as trilhas salvas com o som (mixers 0x%x)",
			     "fonte", salvas);
		}
		return;
	}
	uint32_t trilhas = obs_source_get_audio_mixers(fonte);
	if (trilhas == 0) {
		obs_source_set_audio_mixers(fonte, 0x3F);
		diga(LOG_INFO,
		     "%s: a fonte foi salva antes de ter som e veio com as trilhas de áudio desligadas "
		     "(mixers 0): ligadas as trilhas 1 a 6, uma vez. Para desligar, Propriedades avançadas de áudio.",
		     "fonte");
	} else {
		diga(LOG_INFO, "%s: trilhas de áudio conferidas (mixers 0x%x), sem mudança",
		     "fonte", trilhas);
	}
	marcar_trilhas(fonte);
	UNUSED_PARAMETER(ajustes);
}

/// O `.save`: as trilhas que este plugin salvou, para a volta de um plugin sem som (acima).
static void salvar(void *dados, obs_data_t *ajustes)
{
	obs_source_t *fonte = receptor_fonte(dados);
	obs_data_t *priv = obs_source_get_private_settings(fonte);
	obs_data_set_int(priv, TRILHAS_SALVAS, obs_source_get_audio_mixers(fonte));
	obs_data_release(priv);
	// **A câmera do aparelho não vai para a coleção** (achado I8): os valores vêm do filmador, e um
	// OBS que reabrisse com eles salvos estaria mexendo na câmera de alguém. O `.save` roda antes
	// de o `settings` ser serializado (`obs.c:2465` → `:2480`).
	camera_remota_nao_salvar(ajustes);
}

static void destruir(void *dados)
{
	receptor_destruir(dados);
}

static void atualizar(void *dados, obs_data_t *ajustes)
{
	receptor_atualizar(dados, ajustes);
}

// -------------------------------------------------------------------------------------------------
// Painel de propriedades
// -------------------------------------------------------------------------------------------------
static void povoar_lista(obs_property_t *lista)
{
	obs_property_list_clear(lista);
	obs_property_list_add_string(lista, obs_module_text("Quall.Manual"), "manual");

	char *json = descoberta_aparelhos_json();
	if (!json)
		return;

	// `obs_data_create_from_json` só lê objeto; o núcleo devolve array. Embrulhar é mais barato
	// que carregar um leitor de JSON só para isto.
	struct dstr embrulho = {0};
	dstr_printf(&embrulho, "{\"lista\":%s}", json);
	obs_data_t *raiz = obs_data_create_from_json(embrulho.array);
	dstr_free(&embrulho);
	bfree(json);
	if (!raiz)
		return;

	obs_data_array_t *lista_json = obs_data_get_array(raiz, "lista");
	size_t n = obs_data_array_count(lista_json);
	for (size_t i = 0; i < n; i++) {
		obs_data_t *ap = obs_data_array_item(lista_json, i);
		const char *nome = obs_data_get_string(ap, "display_name");
		const char *ponta = obs_data_get_string(ap, "endpoint");
		obs_data_t *cap = obs_data_get_obj(ap, "capabilities");
		bool tela = cap && obs_data_get_bool(cap, "screen_source");
		bool camera = cap && obs_data_get_bool(cap, "camera_source");

		if (ponta && *ponta) {
			char rotulo[320];
			if (tela || camera)
				snprintf(rotulo, sizeof(rotulo), "%s — %s", nome && *nome ? nome : "?", ponta);
			else
				snprintf(rotulo, sizeof(rotulo), "%s — %s (%s)", nome && *nome ? nome : "?",
					 ponta, obs_module_text("Quall.NaoEmite"));
			obs_property_list_add_string(lista, rotulo, ponta);
		}
		obs_data_release(cap);
		obs_data_release(ap);
	}
	obs_data_array_release(lista_json);
	obs_data_release(raiz);
}

static bool ao_trocar_aparelho(obs_properties_t *props, obs_property_t *p, obs_data_t *ajustes)
{
	UNUSED_PARAMETER(p);
	const char *escolhido = obs_data_get_string(ajustes, "aparelho");
	bool manual = !escolhido || !*escolhido || strcmp(escolhido, "manual") == 0;
	obs_property_set_visible(obs_properties_get(props, "endereco"), manual);
	return true;
}

/// O botão **Conectar**.
///
/// Ele não precisa ler os ajustes: o OBS já entregou cada tecla ao `.update`, então o receptor
/// **já tem** o endereço e o PIN inteiros. O que faltava era alguém dizer que o formulário
/// acabou — e é só isso que este clique diz.
static bool ao_conectar(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(p);
	struct receptor *r = dados;
	if (!r)
		return false;
	receptor_conectar_agora(r);
	// **Escreve o estado de agora e pede redesenho.**
	//
	// Até 09/09/2026 isto devolvia `false`, com o argumento de que o estado muda na thread do
	// receptor e o texto de agora ainda diria "pronto para …". O argumento está certo e o
	// resultado era pior: quem clicava em Conectar ficava com o campo de estado **vazio** até
	// fechar o diálogo e reabrir a fonte — relatado assim pelo usuário. Um texto defasado por um
	// instante é melhor que nenhum texto, e o clique em "atualizar lista" corrige em seguida.
	//
	// Devolver `true` aqui refaz os **widgets** a partir deste mesmo `props`; não chama
	// `propriedades()` de novo, e portanto não refaz a lista de aparelhos nem mexe em campo
	// digitado — que é a diferença entre isto e o `obs_source_update_properties` que foi
	// retirado hoje por comer as teclas de quem digitava.
	char estado[256];
	receptor_estado(r, estado, sizeof(estado));
	if (estado[0])
		obs_property_set_description(obs_properties_get(props, "estado"), estado);
	return true;
}

static bool ao_atualizar_lista(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(p);
	povoar_lista(obs_properties_get(props, "aparelho"));

	struct receptor *r = dados;
	if (r) {
		char estado[256];
		receptor_estado(r, estado, sizeof(estado));
		// **Só a descrição, e não a descrição longa.** Num `OBS_TEXT_INFO` o OBS desenha a
		// descrição como rótulo à esquerda e a descrição longa como conteúdo à direita: escrever
		// o mesmo texto nas duas mostrava a linha **duas vezes**, lado a lado. Visto no print do
		// usuário em 09/09/2026, com "recebendo 1920x1080 a 59 fps · decode 2.5 ms · descartes 2"
		// repetido.
		obs_property_set_description(obs_properties_get(props, "estado"), estado);
	}
	return true;
}

static obs_properties_t *propriedades(void *dados)
{
	obs_properties_t *props = obs_properties_create();

	obs_property_t *lista = obs_properties_add_list(props, "aparelho",
						       obs_module_text("Quall.Aparelho"),
						       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	povoar_lista(lista);
	obs_property_set_modified_callback(lista, ao_trocar_aparelho);

	// **O botão de atualizar fica colado na lista que ele atualiza.** Estava no fim do painel,
	// depois de quatro caixas de ajuste, e quem não achasse o aparelho na lista tinha de procurar
	// o botão que refaz a busca no outro extremo do diálogo. Um botão que age sobre um controle
	// pertence ao lado dele; a distância era a única coisa que dizia que os dois se relacionam.
	obs_properties_add_button2(props, "atualizar", obs_module_text("Quall.Atualizar"),
				   ao_atualizar_lista, dados);

	obs_property_t *endereco =
		obs_properties_add_text(props, "endereco", obs_module_text("Quall.Endereco"),
					OBS_TEXT_DEFAULT);
	// **A visibilidade sai do ajuste atual, e não do padrão.** `ao_trocar_aparelho` esconde este
	// campo quando um aparelho da lista é escolhido, mas ele só dispara quando alguém MEXE no
	// seletor. Toda reconstrução do painel — reabrir Propriedades, ou qualquer coisa que peça ao
	// OBS para refazer o formulário — recriava o campo visível e desfazia a escolha, que é como
	// isto foi encontrado em 09/09/2026: "estou escolhendo o s24 na lista mas ele continua o
	// campo para colocar o ip".
	if (dados) {
		obs_data_t *cfg = obs_source_get_settings(receptor_fonte(dados));
		if (cfg) {
			const char *escolhido = obs_data_get_string(cfg, "aparelho");
			bool manual = !escolhido || !*escolhido || strcmp(escolhido, "manual") == 0;
			obs_property_set_visible(endereco, manual);
			obs_data_release(cfg);
		}
	}
	obs_properties_add_text(props, "pin", obs_module_text("Quall.Pin"), OBS_TEXT_DEFAULT);

	// **O botão vem colado no PIN, e a linha de estado vai DEPOIS dele.**
	//
	// A ordem anterior era estado → botão, pela ideia de que a frase "toque em Conectar" devia
	// preceder o botão. Na prática ela o empurrava para fora: a linha de estado cresce com o
	// texto do erro — *"não conectou: pareamento: o emissor recusou: pareamento: o PIN não
	// conferiu"* ocupa duas linhas —, e num diálogo rolado o que sobrava à vista era a mensagem,
	// com o botão abaixo do corte. Visto em 07/09/2026, na captura do usuário: *"o usuário pode
	// não ver"*.
	//
	// Nada pode entrar entre o campo do PIN e o botão. Terminar de digitar e ter o botão sob o
	// dedo é a ordem em que a mão trabalha, e um elemento de tamanho variável no meio é
	// exatamente o que quebra isso.
	obs_properties_add_button2(props, "conectar", obs_module_text("Quall.Conectar"), ao_conectar,
				   dados);

	char estado[256] = "";
	if (dados)
		receptor_estado(dados, estado, sizeof(estado));
	obs_properties_add_text(props, "estado", estado[0] ? estado : obs_module_text("Quall.Estado"),
				OBS_TEXT_INFO);

	// **A câmera do aparelho** (R9b): o grupo só existe numa sessão de vídeo cujo filmador
	// responde, e vem logo abaixo da linha de estado, que é a da sessão. Ver `camera-remota.c`.
	if (dados)
		camera_remota_propriedades(receptor_camera(dados), props);

	obs_properties_add_text(props, "nome", obs_module_text("Quall.Nome"), OBS_TEXT_DEFAULT);
	obs_properties_add_bool(props, "sem_buffer", obs_module_text("Quall.SemBuffer"));
	obs_properties_add_bool(props, "congelar", obs_module_text("Quall.Congelar"));
	obs_properties_add_bool(props, "gravar", obs_module_text("Quall.Gravar"));
	return props;
}

struct obs_source_info quall_fonte_info = {
	.id = QUALL_FONTE_ID,
	.type = OBS_SOURCE_TYPE_INPUT,
	// **Assíncrona**, que é o que `obs_source_output_video()` exige, e **com som** desde a S5
	// (`som.c`): o som do emissor sai por `obs_source_output_audio`, na trilha que o `mixers` da
	// fonte escolher.
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.get_name = nome_da_fonte,
	.create = criar,
	.destroy = destruir,
	.update = atualizar,
	.load = carregar,
	.save = salvar,
	.get_defaults = padroes,
	.get_properties = propriedades,
	.icon_type = OBS_ICON_TYPE_CAMERA,
};
