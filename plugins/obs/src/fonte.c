#include "quall-obs.h"
#include "rotulo-da-lista.h"

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
// aviso. É o caso da coleção do Bruno hoje.
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

/// A fonte entrou no ar (cena do programa): o QR, se estiver na imagem, sai já.
static void ativar(void *dados)
{
	receptor_ativou(dados);
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
		// O nome que o aparelho escolheu para a rede (`docs/v3-no-privado.md` §8.7): vai na frente,
		// com o código do alias entre parênteses — ele não autentica nada. `null` vira "".
		const char *anunciado = obs_data_get_string(ap, "announced_name");
		const char *ponta = obs_data_get_string(ap, "endpoint");
		obs_data_t *cap = obs_data_get_obj(ap, "capabilities");
		bool tela = cap && obs_data_get_bool(cap, "screen_source");
		bool camera = cap && obs_data_get_bool(cap, "camera_source");
		// A busca por três caminhos (`docs/conexao.md` §2): `accepts_code` é o aparelho que conecta
		// sem PIN (os dois mostram o código), e `alive` falso é "visto há X s" — o item fica mais
		// 30 s na lista em vez de piscar. Faltando (núcleo anterior), "não aceita" e "vivo".
		bool sem_pin = obs_data_get_bool(ap, "accepts_code");
		bool vivo = !obs_data_has_user_value(ap, "alive") || obs_data_get_bool(ap, "alive");
		long long visto_ha_s = obs_data_get_int(ap, "seen_ms_ago") / 1000;
		// O próprio anúncio não entra (§8.3); o item que a sonda reconheceu como par guardado diz
		// "pareado" (§5.4) — e Conectar nele é a retomada com ele como alvo (`uma_sessao`).
		bool proprio = obs_data_get_bool(ap, "own");
		const char *conhecido = obs_data_get_string(ap, "known_device_id");
		bool pareado = conhecido && *conhecido;

		if (ponta && *ponta && !proprio) {
			// Curto, para o combo não espremer a coluna (13/10): o alias, o ip (a porta só quando não
			// é a 7877 de sempre) e uma nota.
			char onde[96];
			snprintf(onde, sizeof onde, "%s", ponta);
			size_t t = strlen(onde);
			if (t > 5 && strcmp(onde + t - 5, ":7877") == 0)
				onde[t - 5] = '\0';
			char nota[96] = "";
			if (!vivo)
				snprintf(nota, sizeof nota, texto_formato("Quall.Lista.VistoHa"), visto_ha_s);
			else if (pareado)
				snprintf(nota, sizeof nota, "%s", obs_module_text("Quall.Lista.Pareado"));
			else if (sem_pin && (tela || camera))
				snprintf(nota, sizeof nota, "%s", obs_module_text("Quall.Lista.SemPin"));
			// O código do alias sem o "Quall " (o mesmo da espera do outro aparelho), e o nome anunciado
			// na frente quando há (`rotulo-da-lista.c`).
			char rotulo[320];
			rotulo_da_lista(rotulo, sizeof rotulo, nome, anunciado, onde,
					tela || camera ? NULL : obs_module_text("Quall.NaoEmite"), nota);
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

/// Uma linha de texto que **quebra** (`OBS_TEXT_INFO` com word wrap): sem isto, uma frase longa
/// alarga a coluna e espreme os controles (foto do Bruno no Dell, 13/10).
static obs_property_t *info(obs_properties_t *props, const char *nome, const char *texto)
{
	obs_property_t *p = obs_properties_add_text(props, nome, texto, OBS_TEXT_INFO);
	if (p)
		obs_property_text_set_info_word_wrap(p, true);
	return p;
}

/// O rótulo curto e a explicação na dica (`long_description`, o "?" do OBS).
static obs_property_t *com_dica(obs_property_t *p, const char *chave_da_dica)
{
	if (p)
		obs_property_set_long_description(p, obs_module_text(chave_da_dica));
	return p;
}

/// **Recusar** do cartão do código (`docs/conexao.md` §4). O toque vai com a tentativa do cartão
/// (`receptor_codigo_recusar`). Devolve `false`: quem refaz o painel é a vigia do código, quando a fase
/// muda.
static bool ao_recusar_codigo(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(p);
	receptor_codigo_recusar(dados);
	return false;
}

/// **O cartão do código**, logo abaixo do Conectar que o pediu: os dígitos numa linha só (um
/// `OBS_TEXT_INFO` sem valor nem descrição longa ocupa a largura toda), o que fazer no outro aparelho e
/// Recusar. Este OBS é sempre o **convidado** (`docs/v3-no-privado.md` §3.6): ele mostra o número, e
/// quem confirma é o anfitrião, tocando nele entre três. O nome do anfitrião só chega no fim (M2).
static void cartao_do_codigo(obs_properties_t *props, void *dados)
{
	struct codigo_na_tela c;
	if (!dados || !receptor_codigo(dados, &c))
		return;
	// "04 27", como as outras telas mostram.
	char grupos[8];
	if (strlen(c.codigo) == 4)
		snprintf(grupos, sizeof grupos, "%.2s %.2s", c.codigo, c.codigo + 2);
	else
		snprintf(grupos, sizeof grupos, "%s", c.codigo);
	char linha[256];
	snprintf(linha, sizeof linha, texto_formato("Quall.Codigo.Valor"), grupos,
		 c.par[0] ? c.par : obs_module_text("Quall.Codigo.OutroAparelho"));
	info(props, "codigo", linha);
	info(props, "codigo_aviso",
	     obs_module_text(c.pareamento_anterior ? "Quall.Codigo.PareamentoAnterior" : "Quall.Codigo.NoOutro"));
	if (strcmp(c.fase, "mostrando") == 0)
		obs_properties_add_button2(props, "codigo_recusar", obs_module_text("Quall.Codigo.Recusar"),
					   ao_recusar_codigo, dados);
}

/// **"Esquecer este aparelho"** (`docs/v3-no-privado.md` §3.5), só depois de a sessão salva falhar
/// fechado. Devolve `true`: o botão some e a linha de estado diz que esqueceu.
static bool ao_esquecer(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(p);
	struct receptor *r = dados;
	if (!r)
		return false;
	receptor_esquecer_o_salvo(r);
	obs_property_set_visible(obs_properties_get(props, "esquecer"), receptor_pode_esquecer(r));
	char estado[256];
	receptor_estado(r, estado, sizeof(estado));
	if (estado[0])
		obs_property_set_description(obs_properties_get(props, "estado"), estado);
	return true;
}

/// **Mostrar o QR para o celular** / **Esconder o QR** (`docs/conexao.md` §10). Devolve `false`: quem
/// refaz o painel é a `laco`, quando o QR entra ou sai da imagem — refazer daqui, de dentro do clique,
/// apagaria o botão que está sendo clicado.
static bool ao_alternar_qr(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(p);
	receptor_mostrar_qr(dados, !receptor_qr_ativo(dados));
	return false;
}

static bool ao_atualizar_lista(obs_properties_t *props, obs_property_t *p, void *dados)
{
	UNUSED_PARAMETER(p);
	// A busca do módulo varre a /24 sozinha só com a lista vazia, uma vez (`docs/v3-no-privado.md`
	// §8.9); o botão a recomeça. Quem aparecer entra na próxima vez que a lista for povoada.
	descoberta_procurar_de_novo();
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
	// **Dois grupos** (13/10): a conexão em cima, as opções embaixo, e entre eles o grupo da câmera
	// do aparelho. Os botões tratam com o grupo em que estão (`p->parent`), por isso tudo o que um
	// tratador procura — lista, endereço, estado, esquecer — mora no mesmo grupo "Conexão".
	obs_properties_t *conexao = obs_properties_create();

	obs_property_t *lista = obs_properties_add_list(conexao, "aparelho",
						       obs_module_text("Quall.Aparelho"),
						       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	povoar_lista(lista);
	obs_property_set_modified_callback(lista, ao_trocar_aparelho);

	// **O botão de atualizar fica colado na lista que ele atualiza.** Estava no fim do painel,
	// depois de quatro caixas de ajuste, e quem não achasse o aparelho na lista tinha de procurar
	// o botão que refaz a busca no outro extremo do diálogo. Um botão que age sobre um controle
	// pertence ao lado dele; a distância era a única coisa que dizia que os dois se relacionam.
	com_dica(obs_properties_add_button2(conexao, "atualizar", obs_module_text("Quall.Atualizar"),
					    ao_atualizar_lista, dados),
		 "Quall.Atualizar.Dica");

	obs_property_t *endereco =
		obs_properties_add_text(conexao, "endereco", obs_module_text("Quall.Endereco"),
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
	com_dica(endereco, "Quall.Endereco.Dica");
	com_dica(obs_properties_add_text(conexao, "pin", obs_module_text("Quall.Pin"), OBS_TEXT_PASSWORD),
		 "Quall.Pin.Dica");

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
	com_dica(obs_properties_add_button2(conexao, "conectar", obs_module_text("Quall.Conectar"), ao_conectar,
					    dados),
		 "Quall.Conectar.Dica");
	// O que o rótulo do PIN dizia, numa linha que quebra, logo abaixo do botão (nada entre o PIN e o
	// Conectar: ver acima).
	info(conexao, "pin_dica", obs_module_text("Quall.Pin.Dica"));
	// O código de 4 dígitos (`docs/conexao.md` §4) vem colado no Conectar que o pediu.
	cartao_do_codigo(conexao, dados);
	// **O QR invertido** (§10), ao lado do caminho de sempre e não no lugar: para o celular que já
	// espera (no suporte) ler, sem ninguém digitar nada aqui.
	bool qr = dados && receptor_qr_ativo(dados);
	com_dica(obs_properties_add_button2(conexao, "qr", obs_module_text(qr ? "Quall.Qr.Esconder" : "Quall.Qr.Mostrar"),
					    ao_alternar_qr, dados),
		 "Quall.Qr.Mostrar.Dica");
	if (qr)
		info(conexao, "qr_dica", obs_module_text("Quall.Qr.Dica"));
	else if (dados && obs_source_active(receptor_fonte(dados)))
		// O botão fica, e a frase diz antes do clique o que a `laco` vai recusar (revisão de 12/10, M1).
		info(conexao, "qr_dica", obs_module_text("Quall.Qr.NoAr"));

	char estado[256] = "";
	if (dados)
		receptor_estado(dados, estado, sizeof(estado));
	info(conexao, "estado", estado[0] ? estado : obs_module_text("Quall.Estado"));
	// A sessão salva falhou fechado: a única porta de volta ao código e ao QR para este aparelho.
	if (dados && receptor_pode_esquecer(dados))
		com_dica(obs_properties_add_button2(conexao, "esquecer", obs_module_text("Quall.EsquecerAparelho"),
						    ao_esquecer, dados),
			 "Quall.EsquecerAparelho.Dica");
	obs_properties_add_group(props, "grupo_conexao", obs_module_text("Quall.Grupo.Conexao"), OBS_GROUP_NORMAL,
				 conexao);

	// **A câmera do aparelho** (R9b): o grupo só existe numa sessão de vídeo cujo filmador
	// responde, e vem logo abaixo da linha de estado, que é a da sessão. Ver `camera-remota.c`.
	if (dados)
		camera_remota_propriedades(receptor_camera(dados), props);

	obs_properties_t *opcoes = obs_properties_create();
	com_dica(obs_properties_add_text(opcoes, "nome", obs_module_text("Quall.Nome"), OBS_TEXT_DEFAULT),
		 "Quall.Nome.Dica");
	com_dica(obs_properties_add_bool(opcoes, "sem_buffer", obs_module_text("Quall.SemBuffer")),
		 "Quall.SemBuffer.Dica");
	com_dica(obs_properties_add_bool(opcoes, "congelar", obs_module_text("Quall.Congelar")),
		 "Quall.Congelar.Dica");
	com_dica(obs_properties_add_bool(opcoes, "gravar", obs_module_text("Quall.Gravar")), "Quall.Gravar.Dica");
	obs_properties_add_group(props, "grupo_opcoes", obs_module_text("Quall.Grupo.Opcoes"), OBS_GROUP_NORMAL,
				 opcoes);
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
	.activate = ativar,
	.load = carregar,
	.save = salvar,
	.get_defaults = padroes,
	.get_properties = propriedades,
	.icon_type = OBS_ICON_TYPE_CAMERA,
};
