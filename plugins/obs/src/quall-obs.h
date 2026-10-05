// Declarações comuns do plugin. Um cabeçalho só: o plugin tem sete arquivos e a superfície entre
// eles cabe numa tela.
#pragma once

#include <obs-module.h>
#include <util/dstr.h>
#include <util/platform.h>
#include <util/threading.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include "registro-seguro.h"

// Identificador da fonte. Ele entra nas cenas salvas do usuário: **nunca mude**.
#define QUALL_FONTE_ID "quall_fonte"

// Todas as mensagens próprias passam por esta barreira antes do libobs. Só o diário muda: os
// valores usados por interface, pareamento, arquivos e protocolo continuam intactos.
static inline void registro_dizer(int nivel, const char *formato, ...)
{
	char bruto[4096], seguro[4096];
	va_list ap;
	va_start(ap, formato);
	int n = vsnprintf(bruto, sizeof bruto, formato, ap);
	va_end(ap);
	if (n < 0) {
		blog(nivel, "[quall] mensagem de diagnóstico indisponível (falha de formatação)");
		return;
	}
	registro_sanitizar(bruto, seguro, sizeof seguro);
	blog(nivel, "[quall] %s%s", seguro, (size_t)n >= sizeof bruto ? " [mensagem truncada]" : "");
}

#define diga(nivel, ...) registro_dizer(nivel, __VA_ARGS__)

// -------------------------------------------------------------------------------------------------
// Textos (`texto.c`): o painel no idioma do OBS (`obs_module_text`), o diário sempre em português.
// -------------------------------------------------------------------------------------------------
/// O texto da `chave` no `pt-BR`, para o diário — os roteiros de bancada procuram frases dele.
const char *texto_pt(const char *chave);
/// O formato `printf` da `chave` no idioma do OBS, ou o do `pt-BR` se as conversões não baterem.
const char *texto_formato(const char *chave);
/// O arquivo de idioma que o plugin carrega para o idioma `locale` do OBS (`pt-*` → `pt-BR`).
const char *texto_idioma_do_plugin(const char *locale);

// -------------------------------------------------------------------------------------------------
// Descoberta: um navegador mDNS para o módulo inteiro, não um por fonte.
//
// `quall_browser_collect` **bloqueia**, e o painel de propriedades roda na thread da interface do
// OBS. Uma fonte que coletasse ali congelaria a janela por `ms` a cada abertura do painel. Então uma
// thread do módulo coleta em laço e o painel só lê a lista, que o header garante ser segura de
// qualquer thread (o navegador guarda a lista atrás de um `Mutex`).
// -------------------------------------------------------------------------------------------------
void descoberta_iniciar(void);
void descoberta_parar(void);
/// JSON dos aparelhos vistos, alocado com `bmalloc` (libere com `bfree`). NULL se nada ainda.
char *descoberta_aparelhos_json(void);

// -------------------------------------------------------------------------------------------------
// Pareamento persistido e identidade deste OBS.
// -------------------------------------------------------------------------------------------------
/// Conteúdo de `pares.json` na pasta de configuração do módulo. `bmalloc`'d ou NULL.
char *pares_ler(void);
/// Funde `novo_json` com o que está no disco (`quall_known_peers_merge`) e grava.
void pares_gravar_fundindo(const char *novo_json);
/// `device_id` estável desta instalação do OBS. Vive enquanto o módulo estiver carregado.
const char *identidade_device_id(void);
void identidade_soltar(void);

/// Quantas "pontes" de sessão ficaram para trás porque a barreira da fronteira C não devolveu
/// `QUALL_STATUS_OK`. **O esperado é zero**, e é esse o número que o contador de vazamentos do
/// libobs deve mostrar no fim — o `obs_module_unload` escreve os dois no diário, para a linha ter
/// explicação em vez de virar suspeita.
long receptor_pontes_deixadas(void);

/// Nome curto desta máquina, para o padrão de "Este OBS aparece como". Copia para `buf`.
void identidade_maquina(char *buf, size_t cap);

// -------------------------------------------------------------------------------------------------
// Medidas: percentis sobre as últimas amostras. Instrumento de bancada dentro do produto, como o
// resto do projeto faz — número medido é o que separa "funciona" de "parece funcionar".
// -------------------------------------------------------------------------------------------------
#define MEDIDA_CAP 2048
struct medida {
	uint64_t v[MEDIDA_CAP];
	size_t n;     // quantas amostras válidas
	size_t proxi; // próxima posição do anel
	uint64_t total;
	uint64_t maximo;
	uint64_t contagem; // amostras desde sempre, não só as do anel
};
void medida_zerar(struct medida *m);
void medida_por(struct medida *m, uint64_t amostra);
/// Percentil sobre as amostras do anel. `p` em 0..1. Devolve 0 sem amostras.
uint64_t medida_percentil(const struct medida *m, double p);
uint64_t medida_media(const struct medida *m);

// -------------------------------------------------------------------------------------------------
// Receptor: uma sessão do Quall por fonte de OBS.
// -------------------------------------------------------------------------------------------------
struct receptor;
struct receptor *receptor_criar(obs_source_t *fonte);
void receptor_atualizar(struct receptor *r, obs_data_t *ajustes);
/// O botão **Conectar**: aplica o que está no painel e tenta agora.
///
/// O OBS não tem "OK" — ele aplica cada tecla ao vivo. Sem este botão o receptor discava no
/// endereço pela metade e antes de o PIN existir; ver `docs/bancada.md` §8.51.
void receptor_conectar_agora(struct receptor *r);
void receptor_destruir(struct receptor *r);
/// Texto curto do estado atual, copiado para `buf`.
void receptor_estado(struct receptor *r, char *buf, size_t cap);

/// A fonte do OBS que este receptor serve. Existe para que `propriedades()` possa ler os ajustes
/// **atuais** e reconstruir o painel no estado em que ele estava — sem isto, toda reconstrução
/// devolvia o campo de endereço à visibilidade padrão, desfazendo a escolha de aparelho.
obs_source_t *receptor_fonte(struct receptor *r);

// -------------------------------------------------------------------------------------------------
// A câmera do aparelho (`camera-remota.c`, R9b): o grupo "Câmera do aparelho" nas propriedades da
// fonte, que pede ajustes à câmera de quem filma. Uma por receptor.
// -------------------------------------------------------------------------------------------------
struct camera_remota;
struct QuallSession;
struct camera_remota *camera_remota_criar(obs_source_t *fonte);
/// Depois de a `laco` terminar.
void camera_remota_destruir(struct camera_remota *c);
/// **Só da `laco`**: a sessão de vídeo subiu (cria o controle e pega as mensagens dela).
void camera_remota_comecar(struct camera_remota *c, struct QuallSession *ses);
/// **Só da `laco`**, a cada volta, depois de `quall_session_next_event`: bombeia com `timeout_ms = 0`.
void camera_remota_bombear(struct camera_remota *c);
/// **Só da `laco`**, antes de liberar as tracks e fechar a sessão. `refazer`: tirar o grupo do
/// painel aberto (falso quando a sessão caiu porque a pessoa mexe no endereço ou no PIN).
void camera_remota_acabar(struct camera_remota *c, bool refazer);
/// O `.update` da fonte: segura o refazer do painel enquanto a pessoa digita.
void camera_remota_ajustes_mudaram(struct camera_remota *c);
/// O grupo, no `get_properties` (thread de quem pede as propriedades).
void camera_remota_propriedades(struct camera_remota *c, obs_properties_t *props);
/// Tira do `settings` as chaves da câmera: elas **não** são salvas com a cena (achado I8).
void camera_remota_nao_salvar(obs_data_t *ajustes);
struct camera_remota *receptor_camera(struct receptor *r);

// A fonte, registrada em `plugin.c`.
extern struct obs_source_info quall_fonte_info;
