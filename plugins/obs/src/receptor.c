#include "quall-obs.h"
#include "decodificador.h"
#include "encaixe.h"
#include "fluidez.h"
#include "interface-do-cabo.h"
#include "janela-do-enlace.h"
#include "perda.h"
#include "som.h"
#include "tempo-do-som.h"
#include <quall.h>

#include <inttypes.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// =================================================================================================
// Um receptor por fonte de OBS. Toda chamada à fronteira C sai de **uma** thread — a `laco` — com
// duas exceções que o header autoriza por escrito: `quall_session_cancel` (de qualquer thread) e o
// tratador de quadro (que roda numa thread da libdatachannel e só enfileira).
//
// A regra de plataforma que organiza este arquivo: **nunca chamar a API C com um id que possa estar
// morto.** No Windows a libdatachannel lança de dentro do `lock_guard` do mutex global e não solta
// o cadeado — a chamada seguinte trava o processo para sempre. Por isso a `laco` é dona da sessão e
// das tracks do início ao fim, e ninguém mais toca nelas.
// =================================================================================================

/// A fila de quadros **codificados** entre a rede e a decodificação. Era 3: vídeo ao vivo não se
/// enfileira, e uma fila grande esconde atraso. Com o som (S5), a thread de decodificação **segura**
/// cada quadro até a hora do som dele (`esperar_a_hora_do_som`), até `ESPERA_NO_MAXIMO_NS` (200 ms,
/// `tempo-do-som.h`): a 120 fps são 24 quadros parados de propósito, e a fila tem de caber isso com
/// folga (crítica 16, N8: com 24, um emissor de 120 fps enchia a fila, e o descarte condenava a
/// cadeia e mandava o emissor descer a taxa). Quadro codificado é pequeno; o decodificado não fica
/// guardado em lugar nenhum.
#define FILA_TAM 48
/// **O teto de memória da fila** (N8): a soma dos quadros esperando. Acima dele, o mais antigo sai,
/// como na fila cheia. Uma fila de IDR de 4K não passa disto.
#define FILA_TETO_BYTES (32u * 1024u * 1024u)
/// Um slot que cresceu acima disto (um IDR grande) é devolvido depois de decodificar: cada slot
/// crescia até o maior quadro já visto e nunca encolhia (N8).
#define SLOT_GRANDE_BYTES (1024u * 1024u)
/// A folga entre a saída do quadro para o OBS e o tique em que ele tem de aparecer.
#define MARGEM_DO_TIQUE_NS 3000000ll

/// Por quanto tempo, no máximo, a fonte fica com o último quadro bom esperando um IDR depois de
/// uma ruptura. Mesmo valor do receptor iOS e do Android — ver `struct receptor::congelar`.
#define CONGELAR_NO_MAXIMO_NS 2000000000ull

/// O período da janela do enlace — **o caminho de volta do sinal**, e ele não é escolha livre.
///
/// 500 ms é a janela contra a qual a política do controlador de taxa do emissor foi medida
/// (`crates/quall-core/src/taxa.rs`, e a curva de resposta em `docs/taxa-que-escuta.md`).
/// Alimentar aquele controlador com uma janela diferente da que produziu a curva é projetá-lo
/// contra outra curva. As cascas Android e iOS usam a mesma, de propósito.
#define JANELA_DO_ENLACE_MS 500ull

struct quadro {
	uint8_t *p;
	size_t n, cap;
	uint64_t chegada_ns;
	uint64_t timestamp_us; // relógio do **emissor**, como veio no `QuallFrame`
	bool idr;
	/// A referência deste quadro foi condenada: ele decodifica, mas **não** vai para o OBS.
	///
	/// Viaja no próprio slot, e não numa variável da sessão, porque a decodificação acontece
	/// noutra thread: uma bandeira lida lá pertenceria ao quadro errado. A troca de ponteiro do
	/// `thread_de_decodificar` já leva o slot inteiro, então isto não custa cópia nenhuma.
	bool segurar;
};

// Gravação do Annex-B recebido, no par do contrato do sidecar. É instrumento de bancada: serve
// para conferir com `ffprobe` e `tools/valida-sidecar.py` que o que chegou é H.264 de verdade —
// e o par gravado vira entrada de `quall-probe emitir-video`, que é como esta frente conseguiu um
// segundo emissor sem um segundo aparelho.
struct gravacao {
	FILE *h264;
	char *caminho_json;
	char *nome_video;
	struct {
		uint64_t timestamp_us;
		uint32_t bytes;
		bool idr;
	} *quadros;
	size_t n, cap;
};

// -------------------------------------------------------------------------------------------------
// A ponte, agora com prazo de validade
//
// Ela nasceu porque não havia como desregistrar um tratador e `quall_session_close()` não era
// barreira: um `quall_track_on_frame` que já estava correndo numa thread da libdatachannel podia
// ainda estar dentro do nosso código quando o `close` retornasse, e liberar o `user_data` na linha
// seguinte era uso-após-liberação. A saída foi um mutex e um ponteiro que **nunca** eram liberados.
//
// **A dívida 24 foi paga.** Hoje duas chamadas são barreira, e é o `QuallStatus` delas — não um
// relógio — que autoriza o `bfree`:
//
// - `quall_track_on_frame(t, NULL, NULL)` com `QUALL_STATUS_OK`: aquele tratador não está rodando
//   em thread nenhuma e não volta a rodar.
// - `quall_session_close(s)` com `QUALL_STATUS_OK`: o mesmo, para a sessão inteira.
//
// Qualquer outro status quer dizer **não libere nada** (`TIMEOUT`: o tratador não voltou em 2 s;
// `INVALID`: a chamada veio de dentro de um tratador). Nesse caso a ponte fica para trás, como
// antes — mas agora é exceção contada e registrada no diário, não regra.
//
// A ponte continua existindo mesmo com a barreira, e não é desperdício: é ela que torna o caminho
// degradado seguro, porque com o ponteiro zerado sob o trinco um tratador atrasado não alcança
// nada.
// -------------------------------------------------------------------------------------------------
struct ponte {
	pthread_mutex_t trava;
	struct sessao *s;
};
/// Pontes que **não** puderam ser liberadas porque a barreira não deu `QUALL_STATUS_OK`. O
/// esperado é zero, e é esse o número que o contador de vazamentos do libobs deve mostrar.
static volatile long pontes_deixadas;

struct sessao {
	struct receptor *r;
	struct ponte *ponte;

	pthread_mutex_t trava;
	pthread_cond_t sino;
	struct quadro fila[FILA_TAM];
	bool cheio[FILA_TAM];
	int escreve, le;
	bool encerrar;
	/// Os bytes dos quadros esperando na fila (sob `trava`), contra `FILA_TETO_BYTES`.
	size_t bytes_na_fila;
	/// Quantos saíram da fila pelo teto de bytes (também contados em `descartados_na_fila`).
	uint64_t descartados_por_bytes;

	struct quadro atual; // gaveta da thread de decodificação; troca de ponteiro com o slot
	pthread_t thread_decode;
	bool thread_viva;

	struct decodificador *dec;

	/// **O tamanho que esta fonte publica** (decisão do Pessoa Exemplo de 21/09, `encaixe.h`): a cópia da
	/// sessão do `publicado_l/a` da fonte, lida ao nascer. Uma imagem de outro tamanho entra
	/// encaixada em `encaixado`, com faixas, e a fonte não muda de tamanho na cena. Só a thread que
	/// decodifica toca nestes campos; a fonte recebe o primeiro tamanho de volta sob `r->trava`.
	uint32_t publicado_l, publicado_a;
	uint8_t *encaixado;
	size_t encaixado_cap;
	struct encaixe encaixe;
	/// Quantos quadros saíram encaixados, e o tamanho da imagem da última vez que ela mudou (para
	/// a linha do diário sair uma vez por troca, e não por quadro).
	uint64_t encaixados;
	uint32_t imagem_l, imagem_a;

	// contadores
	uint64_t recebidos, decodificados, publicados, descartados_na_fila;
	/// O valor de `descartados_na_fila` na última vez que o relato do enlace saiu. A diferença
	/// entre os dois é **o que o emissor precisa saber**: quantos quadros esta casca não
	/// entregou *nesta janela*. Mandar o acumulado faria o emissor descer para sempre depois do
	/// primeiro descarte.
	uint64_t descartados_no_relato;
	/// Quantos IDR chegaram da rede, e **quando o último chegou**. Escritos pela thread da
	/// libdatachannel sob `trava`, lidos pela `laco` — é como ela sabe que a referência do
	/// decodificador voltou depois de uma perda.
	///
	/// O carimbo é tirado na chegada, e não na volta do laço que a observa: senão o tempo sem
	/// referência sairia quantizado na sondagem de 50 ms e a medida do conserto seria a medida da
	/// sondagem. Foi assim que a primeira leitura desta bancada saiu em 62 · 62 · 64 · 64 ms —
	/// quatro números quase iguais que eram o relógio do laço, não o do conserto.
	uint64_t idrs_recebidos, ultimo_idr_ns;
	uint64_t primeiro_publicado_ns;

	/// **A janela do relato anterior**, para que a linha de estado diga o que está acontecendo
	/// agora e não a média da sessão inteira.
	///
	/// O `fps` que esta linha mostrava era `publicados / (ultimo - primeiro)` — a média desde o
	/// primeiro quadro. Numa transmissão de duas horas, uma fonte que caiu para 20 fps há um
	/// minuto continuava exibindo 57: o denominador é tão grande que nada recente o move. É o
	/// mesmo defeito de denominador que fez esta bancada publicar uma célula falsa em 07/09, só
	/// que na cara do usuário em vez de no diário.
	///
	/// `relatar` roda a cada 5 s, então a diferença entre dois relatos é uma janela de 5 s — curta
	/// o bastante para um operador reagir, longa o bastante para não tremer.
	uint64_t publicados_no_relato, ns_do_relato;

	// -----------------------------------------------------------------------------------------
	// **A testemunha que faltava: quadro publicado com a referência quebrada.**
	//
	// Todo contador acima conta **entrega** — `recebidos`, `decodificados`, `publicados`. Nenhum
	// contava se a imagem publicada está **certa**. Entre uma ruptura da cadeia de referência e o
	// IDR seguinte, todo quadro P chega inteiro, decodifica sem erro nenhum e sai visualmente
	// podre, e conta como sucesso em todas as linhas. Medido no receptor iOS na mesma semana:
	// numa corrida com 1,6 % de perda, **301 de 1156 quadros — 26 % da sessão** — foram para a
	// tela com a referência condenada enquanto todo contador dizia zero.
	//
	// Os nomes são os de `docs/contrato-track.md` e são literais.
	//
	// Escritos pela thread da libdatachannel (em `enfileirar`) e pela `laco`, lidos pela thread
	// de decodificação: tudo sob `trava`. **`retidos` é a exceção que importa**: ele sobe em
	// `ao_pronto`, que até aqui não pegava trava nenhuma no caminho da imagem.
	bool cadeia_condenada;
	uint64_t rupturas, suspeitos, suspeitos_na_rajada, pior_rajada, retidos;
	uint64_t condenada_desde_ns;
	/// Quanto durou cada intervalo sem referência utilizável. **Quatro números e não um**: numa
	/// medida de dano visual a cauda *é* o dano — p50 de 22 ms é imperceptível e max de 879 ms é
	/// quase um segundo de tela errada.
	struct medida sem_referencia_us;

	struct medida decode_us, rede_ate_pronto_us;
	uint64_t ultimo_publicado_ns;

	/// **A imagem espera o som** (S5, `som.h`). O deslocamento entre as tracks, escrito pela
	/// `laco` sob `trava` a cada volta; lido pela thread de decodificação.
	struct {
		bool valido;
		/// `deslocamento do vídeo − deslocamento do som`: o carimbo do vídeo na base do som.
		int64_t video_para_som_us;
		struct som *som;
	} sinc;
	/// O que a espera fez. Escritos pela thread de decodificação, lidos pelo relato, no mesmo
	/// regime dos contadores desta região: sem trava.
	uint64_t segurados, soltos_sem_mapa, soltos_atrasados, no_teto, perdeu_o_tique;
	/// Sem espera porque o som do Quall não é ouvido no OBS (mudo, volume 0, sem trilha, ou só no
	/// monitor; crítica 16, N2); quadros na rampa (N4); trocas de lado do tique (N1).
	uint64_t soltos_mudo, em_rampa, trocas_de_lado;
	/// Quadros que pediram a troca de lado sozinhos, e ficaram (um quadro fora da fase).
	uint64_t fora_da_fase;
	/// O tique, a rampa e a decodificação estimada (`tempo-do-som.h`). Só da thread de
	/// decodificação (o `ao_pronto` roda dentro do `dec_decodificar`, na mesma thread).
	struct espera_da_imagem espera;
	struct medida espera_us, erro_do_tique_us;
	/// O erro do tique **com sinal** (tique − hora do som), somado, para a média: o Δ que a
	/// gravação mostra é o negativo dele mais o erro do método (crítica 14, M4).
	int64_t erro_do_tique_soma_us;
	uint64_t erro_do_tique_n;
	/// O tique em que o quadro que está saindo tem de aparecer (0: sem espera).
	int64_t tique_alvo_ns;

	// -----------------------------------------------------------------------------------------
	// **A distribuição dos intervalos entre publicações.** Ver `fluidez.h`, que é onde a peça
	// mora e onde está escrito por que ela não é a mesma coisa que "o que aparece na tela".
	//
	// Ela substitui um `struct medida intervalo_us` que era alimentado exatamente aqui e **nunca
	// era relatado**: um instrumento mudo é o mesmo que instrumento nenhum, e este media a coisa
	// certa com a forma errada — sem `trancos`, com o percentil sobre um anel de 2048 e com o
	// descarte por anel invisível na linha.
	//
	// Escrita pela thread de decodificação (em `ao_pronto`, logo depois de
	// `obs_source_output_video`), lida pela `laco` (em `relatar`). **Sem trava, e não por
	// descuido**: quem escreve mexe em `intervalos_us[n]` e depois incrementa `n`; quem lê pega
	// `n` uma vez e trabalha em `[0, n)`. Os dois intervalos de índices não se tocam. É o mesmo
	// regime dos outros contadores desta região do arquivo, com uma corrida a menos que
	// `medida_percentil`, que copia o anel enquanto o anel gira.
	struct fluidez fluidez;

	struct gravacao *grav;
};

struct receptor {
	obs_source_t *fonte;

	pthread_t laco;
	bool laco_vivo;
	volatile bool parar;

	pthread_mutex_t trava;
	/// Acorda a `laco` quando a configuração muda ou quando é hora de parar. `os_event_t` e não
	/// `pthread_cond_t` porque `pthread_cond_timedwait` precisa de `clock_gettime`, que o MSVC
	/// não tem — e porque o libobs já oferece o evento nos dois sistemas.
	os_event_t *acordado;

	char *endereco;
	char *pin;
	char *nome;
	bool sem_buffer;
	/// A porta que **não publica** um quadro cuja referência foi condenada. Produto: ligada.
	///
	/// Desligar existe para o braço "antes" do A/B — a bancada deste projeto mede porta ligada
	/// contra porta desligada em vez de argumentar. É o equivalente do `--sem-congelar` do
	/// receptor iOS e do `congelar_na_ruptura` do Android.
	bool congelar;
	bool gravar;
	uint32_t prazo_ms;
	uint32_t geracao;
	/// **Há edição no painel esperando o botão Conectar.**
	///
	/// O OBS aplica configuração ao vivo, tecla a tecla, e sem este portão o receptor discava no
	/// que ainda estava sendo escrito — inclusive **antes de o PIN existir**, o que faz o emissor
	/// contar uma recusa e mostrar "tentativa 2, 3, 4…" enquanto a pessoa ainda preenche o
	/// formulário. Ver `docs/bancada.md` §8.51.
	///
	/// Só endereço e PIN armam o portão: são o par que identifica **com quem** se está falando.
	/// Marcar "latência mínima" não derruba uma sessão de pé.
	bool esperando_clique;
	/// A primeira `receptor_atualizar` de uma fonte vem do OBS montando a cena, com o que foi
	/// salvo — não de alguém digitando. Essa não arma o portão: cena salva é intenção já
	/// declarada, e exigir um clique por fonte a cada abertura do OBS seria um defeito pior que o
	/// consertado.
	bool primeira_vez;

	/// **O tamanho que esta fonte publica, por fonte, e não por sessão** (a revisão do `23eb480`,
	/// M3, decisão do coordenador). A primeira sessão que publica grava aqui o tamanho dela; as
	/// sessões seguintes (uma reconexão com outro tamanho, por exemplo) nascem com ele e encaixam o
	/// que vier. Zerado só quando a pessoa muda com quem a fonte fala (endereço ou PIN), em
	/// `receptor_atualizar`, ou quando a fonte é recriada. Sob `trava`.
	uint32_t publicado_l, publicado_a;

	QuallCanceller *cancelador;
	char estado[256];

	/// O som da fonte (S5): criado na primeira track de som e vivo até a fonte morrer — a thread
	/// dele publica silêncio entre as sessões (crítica 14, M1). Só a `laco` o cria.
	struct som *som;
	/// A hora do último tique do vídeo do OBS (`obs_add_tick_callback`), para a imagem sair no
	/// tique mais perto da hora do som.
	pthread_mutex_t trava_do_tique;
	uint64_t ultimo_tique_ns;

	/// A câmera do aparelho (R9b, `camera-remota.c`): viva enquanto a fonte vive; o controle de
	/// cada sessão de vídeo é criado e liberado pela `laco`.
	struct camera_remota *camera;
};

// -------------------------------------------------------------------------------------------------
// Estado exibido no painel
// -------------------------------------------------------------------------------------------------
/// Escreve o estado da `chave` (`Quall.Estado.*` nas `.ini`): no painel, no idioma do OBS; no
/// diário, sempre em português, que é o que os roteiros de bancada procuram (`texto.c`). Os números
/// vão como `%llu`, e não `PRIu64`: o formato mora na `.ini`, e ela não expande macro.
static void dizer(struct receptor *r, const char *chave, ...)
{
	char buf[256], diario[256];
	va_list ap, ap_diario;
	va_start(ap, chave);
	va_copy(ap_diario, ap);
	vsnprintf(buf, sizeof(buf), texto_formato(chave), ap);
	// A GUI mostra os valores necessários à conexão; o diário não copia nomes, endereços,
	// interfaces nem o JSON do par. Mantém as mesmas frases de estado e a duração medida.
	if (strcmp(chave, "Quall.Estado.Procurando") == 0 ||
	    strcmp(chave, "Quall.Estado.Conectando") == 0 ||
	    strcmp(chave, "Quall.Estado.ConectandoCabo") == 0 || strcmp(chave, "Quall.Estado.Pronto") == 0)
		snprintf(diario, sizeof diario, texto_pt(chave), "[endereço omitido]", "[interface omitida]");
	else if (strcmp(chave, "Quall.Estado.SessaoNova") == 0 ||
		 strcmp(chave, "Quall.Estado.SessaoNovaCabo") == 0 ||
		 strcmp(chave, "Quall.Estado.SessaoRetomada") == 0 ||
		 strcmp(chave, "Quall.Estado.SessaoRetomadaCabo") == 0) {
		unsigned long long ms = va_arg(ap_diario, unsigned long long);
		snprintf(diario, sizeof diario, texto_pt(chave), ms, "[par omitido]");
	} else if (strcmp(chave, "Quall.Estado.NaoConectou") == 0) {
		(void)va_arg(ap_diario, const char *); // mensagem completa pertence só à GUI
		enum QuallStatus status = (enum QuallStatus)va_arg(ap_diario, int);
		char motivo[160];
		snprintf(motivo, sizeof motivo, "status %d: %s", (int)status, registro_causa_status(status));
		snprintf(diario, sizeof diario, texto_pt(chave), motivo);
	} else
		vsnprintf(diario, sizeof(diario), texto_pt(chave), ap_diario);
	va_end(ap_diario);
	va_end(ap);

	pthread_mutex_lock(&r->trava);
	snprintf(r->estado, sizeof(r->estado), "%s", buf);
	pthread_mutex_unlock(&r->trava);
	diga(LOG_INFO, "%s: %s", "fonte", diario);
	// **Aqui NÃO entra `obs_source_update_properties`, e a razão foi medida em campo.**
	//
	// Ela foi posta aqui em 09/09/2026 para o texto de estado deixar de ser um retrato parado, e
	// foi retirada no mesmo dia, minutos depois, com o usuário no meio de um formulário. O sinal
	// `update_properties` não reescreve um rótulo: ele faz o OBS **reconstruir o painel inteiro**,
	// chamando `propriedades()` de novo. A cada 5 s isso (a) refazia a lista de aparelhos, (b)
	// devolvia o campo de endereço à visibilidade padrão desfazendo a escolha do usuário, e (c)
	// **comia as teclas de quem estava digitando** — relatado assim, com estas palavras: "não
	// consigo digitar o ip".
	//
	// Atualização ao vivo do estado exige um alvo que se possa reescrever sem reconstruir o
	// formulário. No OBS isso é um dock, e dock é Qt — a decisão que `CMakeLists.txt:6-9` evitou
	// de propósito. Enquanto ela não for tomada, o texto se atualiza no clique de "atualizar
	// lista", e o número que ele mostra passou a ser o certo, que é o conserto que sobrou desta
	// rodada.
}

obs_source_t *receptor_fonte(struct receptor *r)
{
	return r ? r->fonte : NULL;
}

struct camera_remota *receptor_camera(struct receptor *r)
{
	return r ? r->camera : NULL;
}

void receptor_estado(struct receptor *r, char *buf, size_t cap)
{
	pthread_mutex_lock(&r->trava);
	snprintf(buf, cap, "%s", r->estado);
	pthread_mutex_unlock(&r->trava);
}

// -------------------------------------------------------------------------------------------------
// Fila entre a thread da libdatachannel e a thread de decodificação
// -------------------------------------------------------------------------------------------------
/// Tira o quadro mais antigo da fila, sob `trava`. Ver o comentário em `enfileirar`.
static void descartar_o_mais_antigo(struct sessao *s, uint64_t agora)
{
	s->bytes_na_fila -= s->fila[s->le].n;
	s->cheio[s->le] = false;
	s->le = (s->le + 1) % FILA_TAM;
	s->descartados_na_fila++;
	s->rupturas++;
	if (!s->cadeia_condenada)
		s->condenada_desde_ns = agora;
	s->cadeia_condenada = true;
}

static void enfileirar(struct sessao *s, const QuallFrame *quadro, uint64_t agora)
{
	pthread_mutex_lock(&s->trava);
	if (s->cheio[s->escreve]) {
		// Fila cheia: o mais antigo vai embora. Vídeo ao vivo não se enfileira para tentar de
		// novo — é o mesmo princípio que o header do `send_frame` escreve do lado do emissor.
		// **E este descarte é uma ruptura da cadeia que o núcleo nunca vai relatar.**
		//
		// `quall_track_frames_dropped` conta o que o *depacotizador* jogou fora por incompleto.
		// Este quadro chegou inteiro: quem o jogou fora fomos nós, aqui, porque a thread de
		// decodificação não deu conta. Para o decodificador o efeito é idêntico — o quadro
		// seguinte referencia algo que nunca foi decodificado —, e nenhuma outra casca deste
		// projeto tem esta segunda origem, porque nenhuma outra descarta localmente.
		//
		// Ela é **exata e por quadro**, ao contrário da sondagem de 50 ms lá do laço.
		descartar_o_mais_antigo(s, agora);
	}
	size_t n = quadro->len;
	// O teto de memória (crítica 16, N8): o mesmo descarte, até o quadro novo caber.
	while (s->cheio[s->le] && s->bytes_na_fila + n > FILA_TETO_BYTES) {
		descartar_o_mais_antigo(s, agora);
		s->descartados_por_bytes++;
	}
	struct quadro *q = &s->fila[s->escreve];
	if (q->cap < n) {
		q->p = brealloc(q->p, n);
		q->cap = n;
	}
	memcpy(q->p, quadro->annexb, n);
	q->n = n;
	q->chegada_ns = agora;
	q->timestamp_us = quadro->timestamp_us;
	q->idr = quadro->idr;
	s->bytes_na_fila += n;
	s->cheio[s->escreve] = true;
	s->escreve = (s->escreve + 1) % FILA_TAM;
	s->recebidos++;
	if (quadro->idr) {
		s->idrs_recebidos++;
		s->ultimo_idr_ns = agora;
		// O IDR é o quadro que não depende de referência nenhuma: ele **cura** a cadeia,
		// venha do pedido ou do GOP do emissor.
		if (s->suspeitos_na_rajada > s->pior_rajada)
			s->pior_rajada = s->suspeitos_na_rajada;
		if (s->condenada_desde_ns)
			medida_por(&s->sem_referencia_us,
				   (agora - s->condenada_desde_ns) / 1000);
		s->suspeitos_na_rajada = 0;
		s->cadeia_condenada = false;
		s->condenada_desde_ns = 0;
	} else if (s->cadeia_condenada) {
		s->suspeitos++;
		s->suspeitos_na_rajada++;
		// A válvula. Um emissor que aceita o pedido de IDR e não o atende existiu de verdade
		// nesta bancada — o `quall-app.exe` de 27/08 pôs um IDR na sessão inteira contra 54
		// pedidos. Contra ele, segurar sem prazo trocaria imagem suja por imagem parada, que
		// é pior. O intervalo entra na conta do mesmo jeito: ele não terminou porque a imagem
		// se curou, terminou porque desistimos de esperar.
		if (s->condenada_desde_ns &&
		    agora - s->condenada_desde_ns > CONGELAR_NO_MAXIMO_NS) {
			medida_por(&s->sem_referencia_us,
				   (agora - s->condenada_desde_ns) / 1000);
			s->cadeia_condenada = false;
			s->condenada_desde_ns = 0;
		}
	}
	// A marca viaja no slot, para a thread que decodifica. Ver `struct quadro::segurar`.
	q->segurar = s->cadeia_condenada && s->r->congelar;
	pthread_cond_signal(&s->sino);
	pthread_mutex_unlock(&s->trava);
}

static void ao_quadro(const QuallFrame *quadro, void *user_data)
{
	// **Thread da libdatachannel.** Não bloqueie aqui: uma cópia e um sinal, nada mais. O
	// `annexb` só vale durante esta chamada, então a cópia não é opcional.
	struct ponte *p = user_data;
	uint64_t agora = os_gettime_ns();
	pthread_mutex_lock(&p->trava);
	if (p->s)
		enfileirar(p->s, quadro, agora);
	pthread_mutex_unlock(&p->trava);
}

// -------------------------------------------------------------------------------------------------
// Publicação no OBS
// -------------------------------------------------------------------------------------------------
static void ao_pronto(void *ctx, const struct dec_nv12 *q, uint64_t chegada_ns, uint64_t decode_ns)
{
	struct sessao *s = ctx;

	struct obs_source_frame f = {0};
	f.format = VIDEO_FORMAT_NV12;
	f.width = q->largura;
	f.height = q->altura;
	f.data[0] = (uint8_t *)q->y;
	f.linesize[0] = q->passo_y;
	f.data[1] = (uint8_t *)q->uv;
	f.linesize[1] = q->passo_uv;

	// Faixa **limitada**, que é o padrão do projeto (contrato-sidecar.md), e BT.709.
	f.full_range = false;
	video_format_get_parameters_for_format(VIDEO_CS_709, VIDEO_RANGE_PARTIAL, VIDEO_FORMAT_NV12,
					       f.color_matrix, f.color_range_min, f.color_range_max);
	f.timestamp = chegada_ns;

	// **A porta: um quadro cuja referência foi condenada não vai para o OBS.**
	//
	// Ele já foi **decodificado** — parar de alimentar o decodificador dessincronizaria a
	// sessão e o IDR seguinte chegaria num decodificador com buraco. O que ele não faz é ser
	// publicado: uma fonte assíncrona do OBS que para de receber `obs_source_output_video`
	// **mantém o último quadro na tela**, que é exatamente o comportamento pedido.
	//
	// `s->atual` é o slot desta thread e ninguém mais o toca enquanto ela decodifica — a troca
	// de ponteiro em `thread_de_decodificar` acontece antes, sob `trava`. O contador, esse, é
	// partilhado, e é por ele que esta função passa a pegar a trava.
	if (s->atual.segurar) {
		pthread_mutex_lock(&s->trava);
		s->retidos++;
		pthread_mutex_unlock(&s->trava);
		return;
	}

	// **O primeiro tamanho da fonte fica** (`encaixe.h`), e **depois da porta** (a revisão do
	// `23eb480`, B5): o quadro retido não paga o encaixe nem conta como encaixado. Uma imagem de
	// outro tamanho entra encaixada, com faixas pretas, e a fonte não muda de tamanho na cena. O
	// controle da troca de 21/09 mostrou o contrário: o plugin publicava cada quadro no tamanho
	// dele, e o Pessoa Exemplo viu a fonte encolher e crescer na cena a cada troca.
	bool era_o_primeiro = !s->publicado_l;
	bool encaixar = encaixe_publicar_em(&s->publicado_l, &s->publicado_a, q->largura, q->altura);
	if (era_o_primeiro) {
		pthread_mutex_lock(&s->r->trava);
		if (!s->r->publicado_l) {
			s->r->publicado_l = s->publicado_l;
			s->r->publicado_a = s->publicado_a;
		}
		pthread_mutex_unlock(&s->r->trava);
	}
	if (q->largura != s->imagem_l || q->altura != s->imagem_a) {
		if (s->imagem_l || encaixar)
			diga(LOG_INFO, "%s: a imagem é %ux%u; %s %ux%u, o primeiro tamanho desta fonte",
			     "fonte", q->largura, q->altura,
			     encaixar ? "publicada encaixada, com faixas, em" : "publicada inteira, como no começo, em",
			     s->publicado_l, s->publicado_a);
		s->imagem_l = q->largura;
		s->imagem_a = q->altura;
	}
	if (encaixar) {
		uint32_t l = s->publicado_l & ~1u, a = s->publicado_a & ~1u;
		size_t precisa = (size_t)l * a + (size_t)l * (a / 2);
		if (precisa > s->encaixado_cap) {
			s->encaixado = brealloc(s->encaixado, precisa);
			s->encaixado_cap = precisa;
		}
		if (s->encaixado && encaixe_preparar(&s->encaixe, l, a, q->largura, q->altura)) {
			uint8_t *y = s->encaixado, *uv = s->encaixado + (size_t)l * a;
			encaixe_nv12(&s->encaixe, y, l, uv, l, q->y, q->passo_y, q->uv, q->passo_uv);
			f.width = l;
			f.height = a;
			f.data[0] = y;
			f.linesize[0] = l;
			f.data[1] = uv;
			f.linesize[1] = l;
			s->encaixados++;
		}
	}

	obs_source_output_video(s->r->fonte, &f);
	// Saiu depois do tique em que tinha de aparecer: aparece um tique depois.
	if (s->tique_alvo_ns && (int64_t)os_gettime_ns() > s->tique_alvo_ns)
		s->perdeu_o_tique++;
	s->tique_alvo_ns = 0;

	// **A marca da fluidez é tirada aqui, e este é o único ponto desta casca que serve.**
	//
	// Depois do `obs_source_output_video`, e não antes: o instante que interessa é o da entrega
	// concluída à cena. A escolha desloca o par inteiro pelo mesmo tanto — os dois extremos de
	// todo intervalo são tirados no mesmo lugar do código —, então ela não vicia a distribuição;
	// o que ela faz é pôr o custo da própria entrega dentro do intervalo em que ele acontece.
	//
	// E o `return` lá em cima, o da porta, é parte da medida e não um desvio dela: um quadro
	// retido não chega até aqui, então o intervalo até a publicação seguinte sai maior. É
	// exatamente o que a porta custa, e é o que uma medida tirada na chegada esconderia.
	//
	// **O que este instante NÃO é**: a hora em que o quadro apareceu na tela. O OBS compõe e
	// renderiza depois, no ritmo dele. Ver `fluidez.h`.
	uint64_t agora = os_gettime_ns();
	s->publicados++;
	if (!s->primeiro_publicado_ns)
		s->primeiro_publicado_ns = agora;
	fluidez_publicou(&s->fluidez, agora);
	s->ultimo_publicado_ns = agora;
	medida_por(&s->decode_us, decode_ns / 1000);
	// A estimativa corrente que a espera usa (N10): sem ordenar o anel a cada quadro.
	espera_medir_decode(&s->espera, (int64_t)decode_ns);
	medida_por(&s->rede_ate_pronto_us, (agora - chegada_ns) / 1000);
}

// -------------------------------------------------------------------------------------------------
// Gravação do fluxo recebido (par do contrato do sidecar)
// -------------------------------------------------------------------------------------------------
static struct gravacao *gravacao_abrir(const char *nome_fonte)
{
	char base[128];
	snprintf(base, sizeof(base), "recebido-%s", nome_fonte && *nome_fonte ? nome_fonte : "fonte");
	for (char *c = base; *c; c++)
		if (*c == '/' || *c == ' ' || *c == ':')
			*c = '_';

	char *pasta = obs_module_config_path("");
	if (pasta) {
		os_mkdirs(pasta);
		bfree(pasta);
	}
	struct dstr nome_h264 = {0}, nome_json = {0};
	dstr_printf(&nome_h264, "%s.h264", base);
	dstr_printf(&nome_json, "%s.json", base);
	char *caminho_h264 = obs_module_config_path(nome_h264.array);
	char *caminho_json = obs_module_config_path(nome_json.array);

	struct gravacao *g = bzalloc(sizeof(*g));
	g->h264 = os_fopen(caminho_h264, "wb");
	g->caminho_json = caminho_json;
	g->nome_video = bstrdup(nome_h264.array);
	dstr_free(&nome_h264);
	dstr_free(&nome_json);
	if (!g->h264) {
		int codigo = errno;
		diga(LOG_WARNING, "não consegui gravar o fluxo recebido (errno %d; caminho omitido)", codigo);
		bfree(caminho_h264);
		bfree(g->caminho_json);
		bfree(g->nome_video);
		bfree(g);
		return NULL;
	}
	diga(LOG_INFO, "gravando o fluxo recebido na configuração do módulo (caminho omitido)");
	bfree(caminho_h264);
	return g;
}

static void gravacao_por(struct gravacao *g, const struct quadro *q)
{
	if (fwrite(q->p, 1, q->n, g->h264) != q->n)
		return;
	if (g->n == g->cap) {
		g->cap = g->cap ? g->cap * 2 : 1024;
		g->quadros = brealloc(g->quadros, g->cap * sizeof(*g->quadros));
	}
	g->quadros[g->n].timestamp_us = q->timestamp_us;
	g->quadros[g->n].bytes = (uint32_t)q->n;
	g->quadros[g->n].idr = q->idr;
	g->n++;
}

static void gravacao_fechar(struct gravacao *g, uint32_t largura, uint32_t altura, double fps)
{
	if (!g)
		return;
	fclose(g->h264);

	// O primeiro quadro **precisa** ser IDR pelo contrato; se a sessão começou no meio de um GOP,
	// os quadros antes do primeiro IDR são cortados aqui em vez de produzir um sidecar inválido.
	size_t inicio = 0;
	while (inicio < g->n && !g->quadros[inicio].idr)
		inicio++;

	struct dstr j = {0};
	dstr_printf(&j,
		    "{\n  \"header\": {\n"
		    "    \"width\": %u,\n    \"height\": %u,\n    \"target_fps\": %d,\n"
		    "    \"preset\": \"camera\",\n"
		    "    \"capture_api\": \"quall-obs (recebido pela rede, nao capturado aqui)\",\n"
		    "    \"encoder\": \"do emissor; este lado so recebeu\",\n"
		    "    \"encoder_is_hardware\": false,\n"
		    "    \"target_bitrate_bps\": 0,\n    \"gop_frames\": 0,\n"
		    "    \"color_range\": \"limited\",\n    \"video_file\": \"%s\"\n  },\n"
		    "  \"frames\": [\n",
		    largura, altura, (int)(fps + 0.5), g->nome_video);
	for (size_t i = inicio; i < g->n; i++)
		dstr_catf(&j,
			  "    {\"number\": %zu, \"timestamp_us\": %llu, \"bytes\": %u, "
			  "\"idr\": %s, \"encode_latency_us\": 0}%s\n",
			  i - inicio, (unsigned long long)g->quadros[i].timestamp_us, g->quadros[i].bytes,
			  g->quadros[i].idr ? "true" : "false", i + 1 < g->n ? "," : "");
	dstr_cat(&j, "  ]\n}\n");
	os_quick_write_utf8_file(g->caminho_json, j.array, j.len, false);
	dstr_free(&j);

	if (inicio)
		diga(LOG_WARNING,
		     "a gravação começou no meio de um GOP: %zu quadros antes do primeiro IDR ficaram "
		     "no .h264 e fora do sidecar — o par não vai bater no validador",
		     inicio);
	diga(LOG_INFO, "sidecar gravado na configuração do módulo (%zu quadros; caminho omitido)", g->n - inicio);

	bfree(g->quadros);
	bfree(g->caminho_json);
	bfree(g->nome_video);
	bfree(g);
}

static uint64_t periodo_do_canvas_ns(void)
{
	struct obs_video_info ovi;
	if (obs_get_video_info(&ovi) && ovi.fps_num)
		return (uint64_t)ovi.fps_den * 1000000000ull / ovi.fps_num;
	return 0;
}

static bool encerrando(struct sessao *s)
{
	pthread_mutex_lock(&s->trava);
	bool e = s->encerrar;
	pthread_mutex_unlock(&s->trava);
	return e;
}

/// O som do Quall chega a alguma saída do OBS? Mudo, volume zero, nenhuma trilha, ou só no monitor:
/// não, e a imagem não tem por que esperar (crítica 16, N2). Quem muta o Quall no mixer e usa o
/// próprio microfone teria a imagem atrasada e o microfone adiantado nesse tanto. Os quatro são
/// campos simples da fonte, lidos sem trava, como a libobs os lê na thread de áudio.
static bool som_do_quall_ouvido(obs_source_t *fonte)
{
	return !obs_source_muted(fonte) && obs_source_get_volume(fonte) > 0.0f &&
	       obs_source_get_audio_mixers(fonte) != 0 &&
	       obs_source_get_monitoring_type(fonte) != OBS_MONITORING_TYPE_MONITOR_ONLY;
}

/// **A imagem espera o som** (decisão do Pessoa Exemplo de 18/09/2026, ~22h30; `som.h`): segura o quadro
/// `q` (ainda codificado) até ele poder sair **no tique do OBS da hora em que o som da mesma
/// captura toca**. A hora do som vem do mapa (`som_mapa`); a captura do quadro, do carimbo dele e
/// do relógio comum. O tique mais perto, e não "o primeiro depois da entrega": é o que tira da
/// medida a fase sorteada entre a entrega e o render do OBS (crítica 14, M4) — o erro fica em meio
/// quadro do canvas, e o relato o mede (`erro_do_tique`). Com histerese (crítica 16, N1): o quadro
/// fica do lado do tique do anterior enquanto o erro couber em 0,75 período.
///
/// Sem mapa (sem som, som ocioso, relógio comum ainda não medido), sem o `sem_buffer`, ou com o som
/// do Quall fora das saídas do OBS (N2), não há espera. As passagens entre "espera" e "não espera"
/// são em rampa, 10 % do intervalo entre quadros por quadro (N4): a imagem não congela quando o
/// mapa passa a valer, nem pula quando ele vence. As contas estão em `tempo-do-som.c`, e a prova em
/// `bancada/prova-tempo-do-som.c`.
static void esperar_a_hora_do_som(struct sessao *s, const struct quadro *q)
{
	s->tique_alvo_ns = 0;
	pthread_mutex_lock(&s->trava);
	bool valido = s->sinc.valido && s->sinc.som;
	int64_t video_para_som = s->sinc.video_para_som_us;
	struct som *som = s->sinc.som;
	pthread_mutex_unlock(&s->trava);
	int64_t desvio = 0;
	bool com_mapa = valido && s->r->sem_buffer && som_mapa(som, &desvio);
	bool ouvido = com_mapa && som_do_quall_ouvido(s->r->fonte);
	if (!com_mapa)
		s->soltos_sem_mapa++;
	else if (!ouvido)
		s->soltos_mudo++;

	int64_t tique = 0, desejada = 0;
	if (ouvido) {
		// A hora em que o som desta captura toca, e o tique dela.
		int64_t alvo = ((int64_t)q->timestamp_us + video_para_som) * 1000 + desvio;
		pthread_mutex_lock(&s->r->trava_do_tique);
		int64_t referencia = (int64_t)s->r->ultimo_tique_ns;
		pthread_mutex_unlock(&s->r->trava_do_tique);
		bool trocou = false, segurou = false;
		tique = espera_tique(&s->espera, alvo, referencia, (int64_t)periodo_do_canvas_ns(), &trocou,
				     &segurou);
		if (trocou)
			s->trocas_de_lado++;
		if (segurou)
			s->fora_da_fase++;
		// Sai o tempo da decodificação (a mediana corrente; 3 ms antes de medir) e a margem antes.
		int64_t soltar = tique - espera_decode(&s->espera) - MARGEM_DO_TIQUE_NS;
		desejada = soltar - (int64_t)q->chegada_ns;
		if (desejada > ESPERA_NO_MAXIMO_NS)
			s->no_teto++;
	} else {
		espera_esquecer_o_tique(&s->espera);
	}
	bool na_rampa = false;
	int64_t espera = espera_do_quadro(&s->espera, q->timestamp_us, ouvido, desejada, &na_rampa);
	if (na_rampa)
		s->em_rampa++;
	// O erro do tique conta só quando o quadro vai mesmo ao tique: fora da rampa e dentro do teto.
	bool no_tique = ouvido && !na_rampa && espera == desejada;
	if (no_tique) {
		int64_t erro = s->espera.erro_anterior_ns;
		medida_por(&s->erro_do_tique_us, (uint64_t)((erro < 0 ? -erro : erro) / 1000));
		s->erro_do_tique_soma_us += erro / 1000;
		s->erro_do_tique_n++;
	}
	if (!ouvido && espera == 0)
		return;

	int64_t soltar = (int64_t)q->chegada_ns + espera;
	int64_t agora = (int64_t)os_gettime_ns();
	if (soltar <= agora) {
		if (ouvido)
			s->soltos_atrasados++;
		medida_por(&s->espera_us, (uint64_t)((agora - (int64_t)q->chegada_ns) / 1000));
		return;
	}
	s->segurados++;
	if (no_tique)
		s->tique_alvo_ns = tique;
	medida_por(&s->espera_us, (uint64_t)(espera / 1000));
	// Dorme em pedaços de até 10 ms: o encerrar da sessão não espera a espera inteira. O `_fast`
	// dorme sem girar (no Windows o `os_sleepto_ns` gira com `YieldProcessor`; crítica 16, N5).
	while (agora < soltar) {
		if (encerrando(s))
			return;
		int64_t ate = soltar < agora + 10000000 ? soltar : agora + 10000000;
		os_sleepto_ns_fast((uint64_t)ate);
		agora = (int64_t)os_gettime_ns();
	}
}

static void *thread_de_decodificar(void *arg)
{
	struct sessao *s = arg;
	os_set_thread_name("quall-decode");
	// Esta thread — e só ela — fala com o decodificador. No Windows isso quer dizer apartamento
	// COM e `MFStartup`; no macOS não quer dizer nada. Ver `decodificador.h`.
	dec_thread_entrar();
	for (;;) {
		pthread_mutex_lock(&s->trava);
		while (!s->cheio[s->le] && !s->encerrar)
			pthread_cond_wait(&s->sino, &s->trava);
		if (!s->cheio[s->le] && s->encerrar) {
			pthread_mutex_unlock(&s->trava);
			break;
		}
		// Troca de ponteiro com o slot: nenhum byte é copiado de novo.
		struct quadro tmp = s->atual;
		s->atual = s->fila[s->le];
		s->fila[s->le] = tmp;
		s->cheio[s->le] = false;
		s->bytes_na_fila -= s->atual.n;
		s->le = (s->le + 1) % FILA_TAM;
		pthread_mutex_unlock(&s->trava);

		if (s->grav)
			gravacao_por(s->grav, &s->atual);
		esperar_a_hora_do_som(s, &s->atual);
		if (dec_decodificar(s->dec, s->atual.p, s->atual.n, s->atual.chegada_ns))
			s->decodificados++;
		// Um slot que cresceu por um quadro grande volta ao tamanho zero (crítica 16, N8): ele
		// entra na fila pela próxima troca, e o `enfileirar` o faz crescer só se precisar.
		if (s->atual.cap > SLOT_GRANDE_BYTES) {
			bfree(s->atual.p);
			s->atual.p = NULL;
			s->atual.cap = 0;
			s->atual.n = 0;
		}
	}
	// O decodificador nasceu nesta thread e morre nela. No Windows isso é obrigação, não estilo:
	// soltar um objeto COM de uma thread sem apartamento é o começo de uma história ruim.
	dec_fechar(s->dec);
	dec_thread_sair();
	return NULL;
}

// -------------------------------------------------------------------------------------------------
// Ciclo de vida da sessão
// -------------------------------------------------------------------------------------------------
static struct sessao *sessao_criar(struct receptor *r)
{
	struct sessao *s = bzalloc(sizeof(*s));
	s->r = r;
	pthread_mutex_init(&s->trava, NULL);
	pthread_cond_init(&s->sino, NULL);
	medida_zerar(&s->sem_referencia_us);
	medida_zerar(&s->decode_us);
	medida_zerar(&s->rede_ate_pronto_us);
	medida_zerar(&s->espera_us);
	medida_zerar(&s->erro_do_tique_us);
	espera_zerar(&s->espera);
	fluidez_zerar(&s->fluidez);

	s->ponte = bzalloc(sizeof(*s->ponte));
	pthread_mutex_init(&s->ponte->trava, NULL);
	s->ponte->s = s;

	pthread_mutex_lock(&r->trava);
	bool gravar = r->gravar;
	s->publicado_l = r->publicado_l;
	s->publicado_a = r->publicado_a;
	pthread_mutex_unlock(&r->trava);
	if (s->publicado_l)
		diga(LOG_INFO, "%s: a sessão nova nasce publicando %ux%u, o tamanho que esta fonte já publicava",
		     "fonte", s->publicado_l, s->publicado_a);
	if (gravar)
		s->grav = gravacao_abrir(obs_source_get_name(r->fonte));

	s->dec = dec_criar(ao_pronto, s);
	if (pthread_create(&s->thread_decode, NULL, thread_de_decodificar, s) == 0)
		s->thread_viva = true;
	else
		diga(LOG_ERROR, "não consegui criar a thread de decodificação");
	return s;
}

/// `frames_dropped` da track, sozinho e já em número.
///
/// Devolve `false` quando não deu para ler, e quem chama trata isso como "sem informação nesta
/// volta" — **nunca** como zero: zerar faria a volta seguinte enxergar uma subida que não houve e
/// pedir um IDR à toa.
///
/// O JSON é montado e desmontado a cada 50 ms. Custa uma alocação e um parse de ~150 bytes; num
/// caminho que já copia um quadro de 1280x720 por vez, é ruído. O que **não** dava para fazer era
/// continuar lendo isto a cada 5 s, como o relatório fazia: cinco segundos de espera são mais que o
/// dobro do GOP da câmera do Android, e o gatilho chegaria depois de o problema já ter passado.
static bool ler_quadros_perdidos(const QuallTrack *t, uint64_t *saida)
{
	intptr_t precisa = quall_track_stats_json(t, NULL, 0);
	if (precisa <= 0)
		return false;
	char *b = bmalloc((size_t)precisa);
	bool ok = false;
	if (quall_track_stats_json(t, b, (size_t)precisa) > 0) {
		obs_data_t *d = obs_data_create_from_json(b);
		if (d) {
			// `obs_data_get_int` devolve 0 tanto para "vale zero" quanto para "não existe";
			// `obs_data_has_user_value` separa os dois, e é essa separação que impede o
			// caminho degradado de virar um pedido de IDR espúrio.
			if (obs_data_has_user_value(d, "frames_dropped")) {
				*saida = (uint64_t)obs_data_get_int(d, "frames_dropped");
				ok = true;
			}
			obs_data_release(d);
		}
	}
	bfree(b);
	return ok;
}

// Chave ausente é **ausente**, nunca zero: `obs_data_get_int` devolve 0 para os dois casos, e um
// zero num contador de perda é a afirmação mais perigosa que este relatório pode fazer por engano.
static struct numero_do_nucleo ler_numero(obs_data_t *d, const char *chave)
{
	struct numero_do_nucleo n = {0, obs_data_has_user_value(d, chave)};
	if (n.tem)
		n.v = obs_data_get_int(d, chave);
	return n;
}

/// Os três acumulados do núcleo que a janela do enlace precisa, numa leitura só.
///
/// Devolve `false` quando **qualquer** um deles falta, e quem chama trata isso como "sem janela
/// nesta volta" — nunca como zero. A regra é a de `perda.h` e o motivo é maior aqui: um zero em
/// `packets_lost_for_real` não fica só num diário, ele atravessa até o emissor como a afirmação
/// "medi e não perdi nada" e faz o controlador de taxa **subir** o bitrate.
///
/// `packets_lost_for_real` e **não** `packets_missing_upper_bound`: o teto cobra reordenação como
/// perda, de 1,3× a 44× nas medições desta bancada. Um controlador alimentado por ele reduziria o
/// bitrate por causa de pacotes que chegaram.
///
/// **Esta função entra no núcleo, e por isso não pode ser chamada com `s->trava` na mão** — mesmo
/// ciclo ABBA que a sondagem de perda documenta. Ver o bloco do relato, no laço.
static bool ler_acumulados_do_enlace(const QuallTrack *t, uint64_t *vistos, uint64_t *perdidos,
				     uint64_t *idrs_quebrados)
{
	intptr_t precisa = quall_track_stats_json(t, NULL, 0);
	if (precisa <= 0)
		return false;
	char *b = bmalloc((size_t)precisa);
	bool ok = false;
	if (quall_track_stats_json(t, b, (size_t)precisa) > 0) {
		obs_data_t *d = obs_data_create_from_json(b);
		if (d) {
			struct numero_do_nucleo v = ler_numero(d, "packets_seen");
			struct numero_do_nucleo p = ler_numero(d, "packets_lost_for_real");
			struct numero_do_nucleo i = ler_numero(d, "idrs_broken");
			if (v.tem && p.tem && i.tem) {
				// Nenhum destes contadores pode ser negativo. Se um vier assim, é
				// lixo — e zero é o único valor que não inventa dano nem o esconde
				// por baixo de um `uint64_t` gigante.
				*vistos = v.v > 0 ? (uint64_t)v.v : 0;
				*perdidos = p.v > 0 ? (uint64_t)p.v : 0;
				*idrs_quebrados = i.v > 0 ? (uint64_t)i.v : 0;
				ok = true;
			}
			obs_data_release(d);
		}
	}
	bfree(b);
	return ok;
}

// Lê os contadores **uma vez** e escreve as duas formas: a linha de perda e o resumo tipado de
// métricas. Ler duas vezes daria dois instantes, e a aritmética entre os
// números do relatório deixaria de fechar — que é a razão de `rtp::Contadores` existir no núcleo.
//
// A formatação em si mora em `perda.c` e não conhece o OBS: é o que permite exercitá-la sem os
// cabeçalhos do `libobs`. Ver o cabeçalho de `perda.h`.
static void anexar_metrica(struct dstr *linha, obs_data_t *d, const char *prefixo, const char *chave)
{
	obs_data_item_t *item = obs_data_item_byname(d, chave);
	enum obs_data_type tipo = item ? obs_data_item_gettype(item) : OBS_DATA_NULL;
	enum obs_data_number_type tipo_numero = item ? obs_data_item_numtype(item) : OBS_DATA_NUM_INVALID;
	bool real = tipo_numero == OBS_DATA_NUM_DOUBLE;
	bool nulo = tipo == OBS_DATA_NULL;
	// libobs 32.2.2 converte JSON null em objeto NULL (`obs_data_add_json_null`). Não confundir
	// uma medida ausente/nula com zero ou com um objeto de configuração de tipo errado.
	if (item && tipo == OBS_DATA_OBJECT) {
		obs_data_t *objeto = obs_data_item_get_obj(item);
		nulo = objeto == NULL;
		obs_data_release(objeto);
	}
	char nome[96], valor[160];
	snprintf(nome, sizeof nome, "%s%s", prefixo, chave);
	if (item && !nulo && ((tipo != OBS_DATA_NUMBER && tipo != OBS_DATA_BOOLEAN) ||
			     (tipo == OBS_DATA_NUMBER && tipo_numero == OBS_DATA_NUM_INVALID)))
		snprintf(valor, sizeof valor, "%s=indisponivel", nome);
	else
		registro_formatar_numero(valor, sizeof valor, nome, item != NULL, nulo, real,
					tipo == OBS_DATA_BOOLEAN ? (int64_t)obs_data_item_get_bool(item) :
					(item ? obs_data_item_get_int(item) : 0),
					item ? obs_data_item_get_double(item) : 0.0);
	if (linha->len)
		dstr_cat(linha, " ");
	dstr_cat(linha, valor);
	obs_data_item_release(&item);
}

static void anexar_conjunto_indisponivel(struct dstr *linha, obs_data_t *d, const char *chave)
{
	obs_data_item_t *item = obs_data_item_byname(d, chave);
	const char *estado = "ausente";
	if (item) {
		enum obs_data_type tipo = obs_data_item_gettype(item);
		obs_data_t *objeto = tipo == OBS_DATA_OBJECT ? obs_data_item_get_obj(item) : NULL;
		estado = tipo == OBS_DATA_NULL || (tipo == OBS_DATA_OBJECT && !objeto) ? "null" : "indisponivel";
		obs_data_release(objeto);
	}
	dstr_catf(linha, " %s=%s", chave, estado);
	obs_data_item_release(&item);
}

static void relatar_metricas_do_nucleo(obs_data_t *d)
{
	// Lista explícita: não registrar strings, identificadores ou configuração adicionada ao JSON.
	static const char *const track[] = {
		"frames_ready", "frames_dropped", "idrs_ready", "idrs_broken",
		"largest_frame_ready_packets", "largest_broken_frame_packets_received",
		"sequence_anomalies", "packets_missing_upper_bound", "reorder_events",
		"reorderings_absorbed", "reorder_giveups", "reorder_depth", "reorder_adjusts",
		"packets_seen", "packets_lost_for_real", "packets_too_late", "rtcp_ignored",
		"idr_requests", "jitter_us",
	};
	static const char *const relogio[] = {
		"reference", "capture_offset_us", "residual_us", "window_residual_us",
		"inter_track_drift_ppm", "guard_violations",
	};
	static const char *const buffer[] = {
		"slots", "frames", "holes", "fec_offers", "silences", "too_late", "duplicates",
		"reordered", "resyncs", "max_occupancy", "max_delay_us",
	};
	struct dstr linha = {0};
	for (size_t i = 0; i < sizeof track / sizeof track[0]; i++)
		anexar_metrica(&linha, d, "", track[i]);
	obs_data_t *clock = obs_data_get_obj(d, "clock");
	if (clock) {
		for (size_t i = 0; i < sizeof relogio / sizeof relogio[0]; i++)
			anexar_metrica(&linha, clock, "clock.", relogio[i]);
		dstr_catf(&linha, " clock.status=%s clock.reason=%s",
			  registro_estado_relogio(obs_data_get_string(clock, "status")),
			  registro_motivo_relogio(obs_data_get_string(clock, "reason")));
		obs_data_release(clock);
	} else
		anexar_conjunto_indisponivel(&linha, d, "clock");
	obs_data_t *jitter = obs_data_get_obj(d, "jitter_buffer");
	if (jitter) {
		for (size_t i = 0; i < sizeof buffer / sizeof buffer[0]; i++)
			anexar_metrica(&linha, jitter, "jitter_buffer.", buffer[i]);
		obs_data_release(jitter);
	} else
		anexar_conjunto_indisponivel(&linha, d, "jitter_buffer");
	diga(LOG_INFO, "  núcleo: %s", linha.array);
	dstr_free(&linha);
}

static void relatar_perda(struct receptor *r, const QuallTrack *t)
{
	UNUSED_PARAMETER(r);
	intptr_t precisa = quall_track_stats_json(t, NULL, 0);
	if (precisa <= 0)
		return;
	char *b = bmalloc((size_t)precisa);
	if (quall_track_stats_json(t, b, (size_t)precisa) > 0) {
		obs_data_t *d = obs_data_create_from_json(b);
		if (d) {
			struct contadores_de_perda c = {
				.exata = ler_numero(d, "packets_lost_for_real"),
				.teto = ler_numero(d, "packets_missing_upper_bound"),
				.tarde = ler_numero(d, "packets_too_late"),
				.vistos = ler_numero(d, "packets_seen"),
			};
			char linha[256];
			formatar_perda(&c, linha, sizeof linha);
			diga(LOG_INFO, "  %s: %s", "fonte", linha);
			relatar_metricas_do_nucleo(d);
			obs_data_release(d);
		} else
			diga(LOG_WARNING, "não deu para ler as métricas do núcleo: JSON inválido (conteúdo omitido)");
	}
	bfree(b);
}

/// Acima disto, a fonte parou de entregar e a linha de estado diz isso em vez de exibir taxa.
/// Dois segundos: mais que qualquer intervalo de IDR do produto (1 s na tela, 2 s na câmera) e
/// menos que o tempo de alguém perceber pela imagem.
#define PARADO_ACIMA_DE_MS 2000

static void relatar(struct sessao *s, const char *rotulo)
{
	uint64_t janela_ns = s->ultimo_publicado_ns - s->primeiro_publicado_ns;
	double fps = (janela_ns && s->publicados > 1)
			     ? (double)(s->publicados - 1) * 1e9 / (double)janela_ns
			     : 0.0;

	// **O fps da janela, que é o que vai para a interface.** O `fps` acima é da sessão inteira e
	// continua indo para o diário, que é onde se lê depois; este é o de agora, que é o que se lê
	// durante. Os dois na mesma função de propósito: são o mesmo número em janelas diferentes, e
	// separá-los em dois lugares seria criar a sexta ocorrência da família.
	uint64_t agora_ns = os_gettime_ns();
	uint64_t desde_o_relato = (s->ns_do_relato && agora_ns > s->ns_do_relato)
					  ? agora_ns - s->ns_do_relato
					  : 0;
	uint64_t novos = s->publicados - s->publicados_no_relato;
	double fps_recente = (desde_o_relato && novos) ? (double)novos * 1e9 / (double)desde_o_relato
						      : 0.0;
	// **Uma fonte muda não pode exibir número vivo.** O laço só enxerga `DISCONNECTED` e
	// `FAILED`; uma sessão que simplesmente parou de entregar quadro continuava publicando a
	// média da sessão como se nada tivesse acontecido. `parado_ha_ms` é a idade do último quadro
	// publicado, e é ela que decide se a linha diz taxa ou diz silêncio.
	uint64_t parado_ha_ms = (s->ultimo_publicado_ns && agora_ns > s->ultimo_publicado_ns)
					? (agora_ns - s->ultimo_publicado_ns) / 1000000ull
					: 0;
	s->publicados_no_relato = s->publicados;
	s->ns_do_relato = agora_ns;
	// **Os quatro números que o `fps` acima não dá, e a razão de ele não bastar.** Um segundo com
	// 29 quadros pontuais e um buraco de 200 ms tem os mesmos 30 fps de um segundo regular. Sai
	// na mesma linha do resto de propósito: separar o centro da cauda em duas linhas foi como
	// esta casca chegou a 01/09/2026 mostrando uma média de 6,4 ms para uma tela que travava.
	// Ver `fluidez.h` — e ler `fluidez_ms` como "publicado para o OBS", não como "na tela".
	char fluidez_linha[192];
	formatar_fluidez(&s->fluidez, fluidez_linha, sizeof fluidez_linha);

	// **A linha de estado passa a dizer o que está chegando, e não só que chegou.**
	//
	// O OBS mostra o FPS da **tela dele**, não o da fonte — quem quisesse saber a que taxa um
	// aparelho está entregando tinha de abrir o diário. Em 07/09/2026 isso virou obstáculo real:
	// o cardápio de resolução e taxa passou a existir, e a única forma de o usuário conferir se
	// o que ele escolheu de fato chegou era pedir a alguém que lesse o log.
	//
	// É a mesma regra do cardápio: oferecer sem dizer o que aconteceu é oferecer em silêncio.
	if (parado_ha_ms >= PARADO_ACIMA_DE_MS) {
		dizer(s->r, "Quall.Estado.SemQuadro", (double)parado_ha_ms / 1000.0,
		      dec_largura(s->dec), dec_altura(s->dec), (unsigned long long)s->publicados);
	} else
	dizer(s->r, "Quall.Estado.Recebendo", dec_largura(s->dec), dec_altura(s->dec), fps_recente,
	      medida_percentil(&s->decode_us, 0.50) / 1000.0,
	      (unsigned long long)s->descartados_na_fila);
	diga(LOG_INFO,
	     "%s | %s: %ux%u %s (%s) | recebidos %" PRIu64 " decodificados %" PRIu64 " publicados %" PRIu64
	     " descartados_na_fila %" PRIu64 " | %.2f fps | decode p50 %.2f ms p95 %.2f ms | "
	     "rede→pronto p50 %.2f ms p95 %.2f ms | "
	     // **Os cinco números que esta casca não tinha**, com os nomes de
	     // `docs/contrato-track.md`. Os de cima dizem se o quadro chegou; estes dizem se a
	     // imagem dele tinha **como** estar certa.
	     "rupturas %" PRIu64 " suspeitos %" PRIu64 " pior_rajada %" PRIu64 " retidos %" PRIu64
	     " congelar %s | sem_referencia_ms [n=%" PRIu64 " p50=%.0f p95=%.0f max=%.0f] | %s",
	     "fonte", rotulo, dec_largura(s->dec), dec_altura(s->dec),
	     dec_em_hardware(s->dec) ? "hw" : "sw", dec_nome(s->dec), s->recebidos, s->decodificados,
	     s->publicados,
	     s->descartados_na_fila, fps, medida_percentil(&s->decode_us, 0.50) / 1000.0,
	     medida_percentil(&s->decode_us, 0.95) / 1000.0,
	     medida_percentil(&s->rede_ate_pronto_us, 0.50) / 1000.0,
	     medida_percentil(&s->rede_ate_pronto_us, 0.95) / 1000.0,
	     s->rupturas, s->suspeitos,
	     s->suspeitos_na_rajada > s->pior_rajada ? s->suspeitos_na_rajada : s->pior_rajada,
	     s->retidos, s->r->congelar ? "sim" : "NAO",
	     // `contagem` e não `n`: `n` é o anel, e um relato que dissesse "n=256" numa sessão com
	     // 900 intervalos esconderia justamente a sessão pior. `maximo` é desde sempre, pelo
	     // mesmo motivo — numa medida de dano visual a cauda **é** o dano.
	     s->sem_referencia_us.contagem,
	     medida_percentil(&s->sem_referencia_us, 0.50) / 1000.0,
	     medida_percentil(&s->sem_referencia_us, 0.95) / 1000.0,
	     s->sem_referencia_us.maximo / 1000.0, fluidez_linha);
}

/// Encerra a sessão local. **Chamada só depois de `quall_session_close`.**
///
/// `barreira` é o veredito das chamadas de desligamento da fronteira C: `true` quer dizer que
/// nenhum tratador desta sessão está rodando nem voltará a rodar, e só então a ponte pode ir junto.
static void sessao_encerrar(struct sessao *s, bool barreira)
{
	// 1. Fechar a ponte: a partir daqui nenhum tratador atrasado alcança a fila.
	pthread_mutex_lock(&s->ponte->trava);
	s->ponte->s = NULL;
	pthread_mutex_unlock(&s->ponte->trava);

	// 2. Parar a thread de decodificação. Só ela chama `obs_source_output_video`, e ela morre
	//    antes de `destroy` retornar — que é o que o libobs exige de uma fonte assíncrona.
	pthread_mutex_lock(&s->trava);
	s->encerrar = true;
	pthread_cond_broadcast(&s->sino);
	pthread_mutex_unlock(&s->trava);
	if (s->thread_viva)
		pthread_join(s->thread_decode, NULL);

	if (s->grav) {
		uint64_t janela = s->ultimo_publicado_ns - s->primeiro_publicado_ns;
		double fps = (janela && s->publicados > 1)
				     ? (double)(s->publicados - 1) * 1e9 / (double)janela
				     : 30.0;
		gravacao_fechar(s->grav, dec_largura(s->dec), dec_altura(s->dec), fps);
		s->grav = NULL;
	}
	dec_destruir(s->dec);
	for (int i = 0; i < FILA_TAM; i++)
		bfree(s->fila[i].p);
	bfree(s->atual.p);
	bfree(s->encaixado);
	encaixe_liberar(&s->encaixe);
	if (s->encaixados)
		diga(LOG_INFO, "%s: %" PRIu64 " quadro(s) publicados encaixados em %ux%u nesta sessão",
		     "fonte", s->encaixados, s->publicado_l, s->publicado_a);
	pthread_cond_destroy(&s->sino);
	pthread_mutex_destroy(&s->trava);

	// 3. A ponte, agora que dá para saber se é seguro.
	if (barreira) {
		pthread_mutex_destroy(&s->ponte->trava);
		bfree(s->ponte);
	} else {
		// O caminho degradado: alguém ainda pode estar dentro do tratador. Nada de relógio —
		// deixa para trás e conta, para a linha do contador de vazamentos ter explicação.
		long n = os_atomic_inc_long(&pontes_deixadas);
		diga(LOG_WARNING,
		     "a barreira da fronteira C não deu OK: esta ponte fica para trás de propósito "
		     "(%ld no total nesta carga do módulo)",
		     n);
	}
	bfree(s);
}

/// Dorme até `ms` ou até alguém mexer na configuração / mandar parar.
static void dormir(struct receptor *r, uint32_t ms)
{
	if (os_atomic_load_bool(&r->parar))
		return;
	// Evento de rearme **automático**: um sinal que chegue entre duas esperas não se perde, ele
	// faz a próxima espera voltar na hora. Com rearme manual haveria janela para engolir o aviso
	// de "a configuração mudou", e o usuário esperaria os três segundos à toa.
	os_event_timedwait(r->acordado, ms);
}

static bool ainda_vale(struct receptor *r, uint32_t geracao)
{
	if (os_atomic_load_bool(&r->parar))
		return false;
	pthread_mutex_lock(&r->trava);
	bool ok = (r->geracao == geracao);
	pthread_mutex_unlock(&r->trava);
	return ok;
}

// -------------------------------------------------------------------------------------------------
// As tracks pela espécie, e não pela ordem de chegada (S2 do `docs/som-no-receptor.md` §7.3)
//
// A ordem em que as tracks saem de `quall_session_next_track` não é contrato nenhum. Até 18/09/2026
// esta casca tomava **a primeira que não fosse microfone** como vídeo: com o som chegando primeiro
// (`quall-probe emitir-video --com-audio --som-primeiro`, ou `emitir-audio` direto para o OBS),
// uma `SYSTEM_AUDIO` virava "vídeo", `quall_track_on_frame` aceitava, a bomba entregava só ao
// tratador de áudio, e a fonte ficava preta **sem erro nenhum** (crítica 2, M1).
//
// A regra é a do receptor iOS (`SessaoDeRecepcao.swift`): o vídeo é só tela ou câmera, registrado
// na hora; o som é **adotado** — na espera do vídeo, ou por uma espiada de prazo zero a cada volta
// do laço da sessão —, e uma espécie desconhecida é largada com uma linha no diário em vez de virar
// vídeo por acidente. Nesta fase o som adotado não é publicado (isso é a S5): ele fica guardado até
// o fim da sessão, e o diário diz que chegou.
// -------------------------------------------------------------------------------------------------
static bool e_video(enum QuallTrackKind k)
{
	return k == QUALL_TRACK_KIND_SCREEN || k == QUALL_TRACK_KIND_CAMERA;
}

static bool e_audio(enum QuallTrackKind k)
{
	return k == QUALL_TRACK_KIND_MICROPHONE || k == QUALL_TRACK_KIND_SYSTEM_AUDIO;
}

static const char *nome_da_especie(enum QuallTrackKind k)
{
	switch (k) {
	case QUALL_TRACK_KIND_SCREEN:
		return "tela";
	case QUALL_TRACK_KIND_CAMERA:
		return "câmera";
	case QUALL_TRACK_KIND_MICROPHONE:
		return "microfone";
	case QUALL_TRACK_KIND_SYSTEM_AUDIO:
		return "som do sistema";
	}
	return "desconhecida";
}

/// Arquiva uma track pela espécie. Vídeo vai para `*video` se ainda não houver um; som vai para
/// `*audio` se ainda não houver um. O resto — a segunda de cada espécie, e espécie desconhecida —
/// é largado e dito. Devolve a espécie arquivada, ou `-1` se a track foi largada.
static int arquivar_track(struct receptor *r, QuallTrack *t, QuallTrack **video, QuallTrack **audio)
{
	UNUSED_PARAMETER(r);
	enum QuallTrackKind k = quall_track_kind(t);
	int arquivada = -1;
	if (e_video(k) && !*video) {
		*video = t;
		arquivada = (int)k;
	} else if (e_audio(k) && !*audio) {
		*audio = t;
		arquivada = (int)k;
		diga(LOG_INFO, "fonte: track de som adotada (%s) — rótulo omitido; ainda não publicada nesta fase",
		     nome_da_especie(k));
	} else {
		diga(LOG_WARNING, "fonte: track largada (espécie %s, %d); rótulo omitido%s",
		     nome_da_especie(k), (int)k,
		     e_video(k) || e_audio(k) ? " — já há uma dessa espécie" : "");
		quall_track_free(t);
	}
	return arquivada;
}

// -------------------------------------------------------------------------------------------------
// **A segunda testemunha de que a mídia foi pelo cabo.**
//
// A primeira é a escolha desta casca: quem ligou o `bind_address` sabe o que pediu. Ela não basta,
// e o header de `quall_session_path_json` diz por quê: *"uma corrida 'pelo cabo' pode fechar pela
// Wi-Fi e parecer sucesso"*. O auditor existe no núcleo desde 01/09 e **não tinha consumidor** —
// nenhuma casca o chamava. Esta é a primeira.
//
// Lê-se o **endereço**, não o candidato. Na primeira corrida real de cabo os dois candidatos
// vieram `null` com os dois endereços preenchidos (`docs/bancada.md`, 01/09): o par se formou por
// *peer-reflexive* e não há objeto de candidato do lado remoto. Uma casca que decidisse "é cabo?"
// pelo candidato concluiria "ainda não sei" numa sessão que estava rodando pelo cabo.
//
// Discordância vira **aviso**, não silêncio: um instrumento que erra calado custa mais que o
// defeito que ele deixou passar.
// -------------------------------------------------------------------------------------------------
static void conferir_o_caminho(QuallSession *ses, const struct escolha_de_interface *enlace)
{
	intptr_t precisa = quall_session_path_json(ses, NULL, 0);
	if (precisa <= 0) {
		diga(LOG_WARNING, "não deu para ler o caminho da mídia: status %d: %s", (int)quall_last_status(), registro_causa_status(quall_last_status()));
		return;
	}
	char *json = bmalloc((size_t)precisa);
	if (quall_session_path_json(ses, json, (size_t)precisa) <= 0) {
		diga(LOG_WARNING, "não deu para ler o caminho da mídia: status %d: %s", (int)quall_last_status(), registro_causa_status(quall_last_status()));
		bfree(json);
		return;
	}

	obs_data_t *caminho = obs_data_create_from_json(json);
	bfree(json);
	if (!caminho) {
		diga(LOG_WARNING, "o caminho da mídia não veio como JSON de objeto");
		return;
	}
	const char *local = obs_data_get_string(caminho, "local_address");
	const char *remoto = obs_data_get_string(caminho, "remote_address");
	diga(LOG_INFO, "caminho da mídia: local %s, remoto %s (endereços omitidos)",
	     *local ? "informado" : "indisponível", *remoto ? "informado" : "indisponível");

	if (enlace->prender) {
		size_t n = strlen(enlace->endereco);
		bool bate = strncmp(local, enlace->endereco, n) == 0 && local[n] == ':';
		if (!bate)
			diga(LOG_WARNING,
			     "as duas testemunhas discordam: pedi o cabo e o caminho local da mídia "
			     "não corresponde (endereços/interfaces omitidos). Trate os números desta "
			     "sessão como de rede, não de cabo.");
	}
	obs_data_release(caminho);
}

/// Uma tentativa completa: conectar, receber, encerrar. Devolve quantos ms esperar antes da próxima.
// -------------------------------------------------------------------------------------------------
// O som (S5): a `laco` entrega o relógio à thread do som a cada volta
//
// O carimbo de uma amostra de som vira hora do OBS por `timestamp + desvio`, com
//
//     desvio = deslocamento do som − deslocamento do vídeo + trânsito mínimo do vídeo
//              + atraso de publicação do vídeo
//
// O trânsito mínimo é da base da track de vídeo (chegada − carimbo); somado ao deslocamento do
// vídeo ele leva a captura no relógio comum à chegada no relógio do OBS. O atraso de publicação é
// o p50 da chegada à entrega ao OBS (fila e decodificação), mais meio quadro do canvas: uma fonte
// assíncrona sem buffer aparece no passo de renderização seguinte à entrega. Com isso o som cai
// onde o quadro da mesma captura apareceu na saída do OBS.
//
// **Os deslocamentos são lidos aqui, sem `s->trava` na mão**, pela mesma regra do ciclo ABBA da
// sondagem de perda: `quall_track_capture_offset_us` entra no núcleo.
// -------------------------------------------------------------------------------------------------
/// Liga a track de som desta sessão ao som da fonte, criando-o na primeira vez (S5, `som.h`).
static bool ligar_o_som(struct receptor *r, QuallTrack *audio)
{
	if (!r->som)
		r->som = som_criar(r->fonte);
	if (!r->som) {
		diga(LOG_WARNING, "%s: som adotado e NÃO publicado: a thread do som não subiu",
		     "fonte");
		return false;
	}
	char motivo[256] = "";
	if (som_ligar(r->som, audio, motivo, sizeof motivo)) {
		diga(LOG_INFO,
		     "%s: som publicado no OBS pela porta puxada, adiantado %.0f ms, com a razão aplicada "
		     "no conteúdo; a imagem espera o som",
		     "fonte", (double)SOM_ADIANTAMENTO_NS / 1e6);
		return true;
	}
	char motivo_do_diario[256];
	registro_formatar_motivo_som(motivo, motivo_do_diario, sizeof motivo_do_diario);
	diga(LOG_WARNING, "%s: som adotado e NÃO publicado: %s", "fonte", motivo_do_diario);
	return false;
}

/// O deslocamento entre as tracks, para a espera da imagem. A cada volta da `laco`.
static void sincronizar(struct sessao *s, struct som *som, QuallTrack *t, QuallTrack *audio)
{
	int64_t off_video = 0, off_som = 0;
	bool validos = som && t && audio && quall_track_capture_offset_us(t, &off_video) == 1 &&
		       quall_track_capture_offset_us(audio, &off_som) == 1;
	pthread_mutex_lock(&s->trava);
	s->sinc.valido = validos;
	s->sinc.video_para_som_us = off_video - off_som;
	s->sinc.som = validos ? som : NULL;
	pthread_mutex_unlock(&s->trava);
}

static void relatar_o_som(struct receptor *r, struct sessao *s)
{
	if (!r->som)
		return;
	char linha[2560];
	som_relatar(r->som, linha, sizeof linha);
	diga(LOG_INFO, "%s: %s", "fonte", linha);
	if (!s)
		return;
	pthread_mutex_lock(&s->trava);
	int64_t video_para_som = s->sinc.video_para_som_us;
	bool valido = s->sinc.valido;
	pthread_mutex_unlock(&s->trava);
	pthread_mutex_lock(&s->trava);
	size_t bytes_na_fila = s->bytes_na_fila;
	uint64_t por_bytes = s->descartados_por_bytes;
	pthread_mutex_unlock(&s->trava);
	diga(LOG_INFO,
	     "%s: imagem espera o som: sincronia=%s ouvido=%s segurados=%" PRIu64 " sem_mapa=%" PRIu64
	     " mudo=%" PRIu64 " em_rampa=%" PRIu64 " trocas_de_lado=%" PRIu64 " fora_da_fase=%" PRIu64
	     " atrasados=%" PRIu64
	     " no_teto=%" PRIu64 " perdeu_o_tique=%" PRIu64 " espera_ms=[p50=%.1f p95=%.1f max=%.1f]"
	     " erro_do_tique_ms=[p50=%.1f p95=%.1f max=%.1f] erro_do_tique_medio_ms=%.2f"
	     " decode_estimado_ms=%.2f fila_kb=%zu descartados_por_bytes=%" PRIu64 " video_para_som_ms=%.2f",
	     "fonte", valido ? "vale" : "nao", som_do_quall_ouvido(r->fonte) ? "sim" : "nao",
	     s->segurados, s->soltos_sem_mapa, s->soltos_mudo, s->em_rampa, s->trocas_de_lado, s->fora_da_fase,
	     s->soltos_atrasados, s->no_teto, s->perdeu_o_tique, medida_percentil(&s->espera_us, 0.50) / 1000.0,
	     medida_percentil(&s->espera_us, 0.95) / 1000.0, s->espera_us.maximo / 1000.0,
	     medida_percentil(&s->erro_do_tique_us, 0.50) / 1000.0,
	     medida_percentil(&s->erro_do_tique_us, 0.95) / 1000.0, s->erro_do_tique_us.maximo / 1000.0,
	     s->erro_do_tique_n ? (double)s->erro_do_tique_soma_us / (double)s->erro_do_tique_n / 1000.0 : 0.0,
	     (double)espera_decode(&s->espera) / 1e6, bytes_na_fila / 1024, por_bytes, (double)video_para_som / 1000.0);
}

static uint32_t uma_sessao(struct receptor *r, const char *endereco, const char *pin, const char *nome,
			   uint32_t prazo_ms, uint32_t geracao)
{
	// ------------------------------------------------------------------------------------
	// **Por onde a mídia vai sair, decidido antes de a sessão existir.**
	//
	// Fora do link-local isto não abre socket nenhum e devolve "não prenda" na hora — o
	// caminho de Wi-Fi de todo usuário de hoje não paga nada por esta linha. No cabo ela põe
	// um pacote no fio por candidata, e é o que faltava ao produto: os roteiros de bancada
	// aquecem o ARP com um `ping` antes de conectar, e `tools/emissor_android.py:70` registra
	// que *"o produto não tem equivalente"*. Agora tem.
	//
	// Antes da criação do cancelador de propósito: a sondagem não é cancelável (são centenas
	// de ms, não dezenas de segundos), e sair daqui antes de haver cancelador é uma saída sem
	// nada para desfazer.
	// ------------------------------------------------------------------------------------
	char candidatas[256] = "";
	// A mensagem de progresso só para quem vai esperar por ela: a sondagem só acontece com
	// empate entre interfaces, e no caso comum a escolha volta na hora — um "procurando…" que
	// aparece e some seria ruído no painel.
	uint32_t ip_do_par = 0;
	uint16_t porta_do_par = 0;
	if (separar_endereco_do_par(endereco, &ip_do_par, &porta_do_par))
		dizer(r, "Quall.Estado.Procurando", endereco);
	struct escolha_de_interface enlace =
		escolher_interface_do_par(endereco, candidatas, sizeof candidatas);

	if (enlace.prender) {
		diga(LOG_INFO, "cabo: a mídia vai presa à interface escolhida — %s. Candidatas: %zu "
		     "(nomes e endereços omitidos)", motivo_em_palavras(enlace.motivo), enlace.candidatas);
		diga(LOG_INFO,
		     "cabo: prender **desiste das outras interfaces**. Se a interface escolhida não alcançar o "
		     "aparelho, a sessão não sobe — não há recuo para a Wi-Fi.");
	} else if (enlace.motivo != MOTIVO_NENHUMA_INTERFACE_NO_ENLACE &&
		   enlace.motivo != MOTIVO_PAR_NAO_E_IPV4) {
		// Havia interface no enlace do par e mesmo assim não se prendeu — empate que a sondagem
		// não desfez, ou recusa explícita do sistema. É o caso que precisa de humano.
		//
		// `MOTIVO_NENHUMA_INTERFACE_NO_ENLACE` **não** entra aqui: par roteado é o caso comum
		// de Wi-Fi, chega pelo gateway, e avisar seria transformar o normal em alarme.
		diga(LOG_WARNING,
		     "cabo: há interface no enlace e eu não prendi a mídia a nenhuma — %s. "
		     "Candidatas: %zu (nomes e endereços omitidos)",
		     motivo_em_palavras(enlace.motivo), enlace.candidatas);
	}

	if (!ainda_vale(r, geracao))
		return 0;

	QuallCanceller *c = quall_canceller_new();
	pthread_mutex_lock(&r->trava);
	if (os_atomic_load_bool(&r->parar) || r->geracao != geracao) {
		pthread_mutex_unlock(&r->trava);
		quall_canceller_free(c);
		return 0;
	}
	r->cancelador = c;
	pthread_mutex_unlock(&r->trava);

	struct QuallDeviceDesc eu = {
		.device_id = identidade_device_id(),
		.display_name = nome,
		.screen_source = false,
		.camera_source = false,
		.sink = true,
	};
	char *pares = pares_ler();
	struct QuallSessionOptions op = {
		.me = eu,
		.pin = (pin && *pin) ? pin : NULL,
		.known_peers_json = pares,
		.signaling_port = 0,
		.timeout_ms = prazo_ms,
		.tracks = NULL,
		.track_count = 0,
		// **Nomeado mesmo quando é `NULL`**, e não deixado ao zero implícito do C: é a regra
		// que `tools/confere-fronteira.py` cobra, e ela existe porque um inicializador
		// parcial vira lixo de pilha no dia em que a declaração mudar de forma.
		.bind_address = enlace.prender ? enlace.endereco : NULL,
	};

	if (enlace.prender)
		dizer(r, "Quall.Estado.ConectandoCabo", endereco, enlace.nome);
	else
		dizer(r, "Quall.Estado.Conectando", endereco);
	uint64_t t_conectar = os_gettime_ns();
	QuallSession *ses = quall_connect_cancelable(endereco, &op, c);
	enum QuallStatus status_conexao = QUALL_STATUS_OK;
	char erro[256] = "";
	if (!ses) {
		status_conexao = quall_last_status();
		snprintf(erro, sizeof erro, "%s", quall_last_error());
	}

	pthread_mutex_lock(&r->trava);
	r->cancelador = NULL;
	pthread_mutex_unlock(&r->trava);
	quall_canceller_free(c);

	if (!ses) {
		bfree(pares);
		if (!ainda_vale(r, geracao))
			return 0;
		dizer(r, "Quall.Estado.NaoConectou", erro, (int)status_conexao);
		return 3000;
	}

	uint64_t ate_sessao_ms = (os_gettime_ns() - t_conectar) / 1000000;
	bool pareamento_novo = quall_session_pairing_is_new(ses);

	// Persistir o pareamento **agora**: sem isto o usuário digita o PIN a cada sessão.
	intptr_t precisa = quall_session_known_peers_json(ses, pares, NULL, 0);
	if (precisa > 0) {
		char *b = bmalloc((size_t)precisa);
		if (quall_session_known_peers_json(ses, pares, b, (size_t)precisa) > 0)
			pares_gravar_fundindo(b);
		bfree(b);
	}
	bfree(pares);

	// **Aloca o que o núcleo pediu, em vez de conferir contra um teto de 512.** Perguntar o
	// tamanho e depois desistir quando ele não cabe é meio contrato: o `par` sairia como "?" e
	// o diário diria que a sessão subiu sem dizer com quem — em silêncio, exatamente como o
	// pareamento do macOS parou de ser gravado quando o `pares.json` cresceu. O `display_name`
	// que entra nesse JSON é o nome que a **outra** máquina escolheu; não é nosso, e não há
	// motivo para supor teto nele.
	char *par = NULL;
	precisa = quall_session_peer_json(ses, NULL, 0);
	if (precisa > 0) {
		par = bmalloc((size_t)precisa);
		if (quall_session_peer_json(ses, par, (size_t)precisa) <= 0) {
			bfree(par);
			par = NULL;
		}
	}

	// Quatro chaves e não pedaços: "novo, por PIN" e ", pelo cabo" mudam de lugar no inglês.
	dizer(r,
	      pareamento_novo ? (enlace.prender ? "Quall.Estado.SessaoNovaCabo" : "Quall.Estado.SessaoNova")
			      : (enlace.prender ? "Quall.Estado.SessaoRetomadaCabo"
						: "Quall.Estado.SessaoRetomada"),
	      (unsigned long long)ate_sessao_ms, par ? par : "?");
	bfree(par);

	conferir_o_caminho(ses, &enlace);

	struct sessao *s = sessao_criar(r);

	// --- esperar a track de vídeo, arquivando o som pelo caminho ----------------------------
	// Ver `arquivar_track`: só tela ou câmera viram vídeo.
	QuallTrack *t = NULL;
	QuallTrack *audio = NULL;
	/// O som desta sessão (S5) ligado ao som da fonte: ligado quando a track de som é adotada, e
	/// solto **antes** de a track ser liberada.
	bool som_ligado = false;
	bool som_tentado = false;
	uint64_t limite = os_gettime_ns() + 20ull * 1000000000ull;
	while (ainda_vale(r, geracao) && !t && os_gettime_ns() < limite) {
		QuallTrack *candidata = quall_session_next_track(ses, 200);
		if (!candidata)
			continue;
		bool ja_tinha_audio = audio != NULL;
		arquivar_track(r, candidata, &t, &audio);
		if (!t && audio && !ja_tinha_audio) {
			// O som chegou primeiro. As duas tracks saem da mesma oferta SDP: se a de
			// vídeo existe, ela vem em milissegundos. Três segundos, e não os vinte,
			// como no receptor iOS — o que se ganharia esperando mais é zero.
			uint64_t curto = os_gettime_ns() + 3ull * 1000000000ull;
			if (curto < limite)
				limite = curto;
		}
	}

	uint32_t espera = 3000;
	if (!t && audio && ainda_vale(r, geracao)) {
		// **Uma sessão só de som** (`quall-probe emitir-audio`, ou um emissor sem tela): a S5
		// a publica, com carimbo direto — sem vídeo não há chegada de quadro para mapear a
		// captura. Antes da S5 ela entrava num laço de 3 s e reconexão (crítica 10, m2).
		dizer(r, "Quall.Estado.SoSom");
		som_ligado = ligar_o_som(r, audio);
		som_tentado = true;
		uint64_t ultimo_relato = os_gettime_ns();
		while (som_ligado && ainda_vale(r, geracao)) {
			enum QuallSessionEvent ev = quall_session_next_event(ses, 20);
			if (ev == QUALL_SESSION_EVENT_DISCONNECTED) {
				dizer(r, "Quall.Estado.EmissorSaiu");
				espera = 1000;
				break;
			}
			if (ev == QUALL_SESSION_EVENT_FAILED) {
				dizer(r, "Quall.Estado.TransporteFalhou");
				break;
			}
			uint64_t agora = os_gettime_ns();
			if (agora - ultimo_relato > 5000000000ull) {
				ultimo_relato = agora;
				relatar_o_som(r, NULL);
			}
		}
		relatar_o_som(r, NULL);
	} else if (!t) {
		// A fonte removida ou reconfigurada no meio da espera também sai daqui sem vídeo, e
		// não é "a sessão só trouxe som" (crítica 10, m2).
		dizer(r, !ainda_vale(r, geracao) ? "Quall.Estado.FonteMudou" : "Quall.Estado.SemVideo");
	} else {
		diga(LOG_INFO, "track %s adotada (rótulo omitido)",
		     quall_track_kind(t) == QUALL_TRACK_KIND_SCREEN ? "de tela" : "de câmera");

		if (quall_track_on_frame(t, ao_quadro, s->ponte) != QUALL_STATUS_OK)
			diga(LOG_ERROR, "quall_track_on_frame recusou: status %d: %s", (int)quall_last_status(), registro_causa_status(quall_last_status()));

		uint64_t ultimo_pli = 0, ultimo_relato = os_gettime_ns();
		uint64_t t_track = os_gettime_ns();
		bool avisou_primeira = false;

		// ---------------------------------------------------------------------------------
		// Pedir IDR quando o núcleo perde quadro
		//
		// Até 26/08/2026 esta casca parava de pedir depois do **primeiro** quadro publicado, e
		// lia `frames_dropped` uma vez a cada 5 s só para escrever no diário. Ou seja: fazia a
		// primeira metade do `pedir_idr()` do `contrato-track.md` ("ao entrar na sessão sem ter
		// visto IDR") e não a segunda ("ou quando o decoder perde sincronia") — que é justamente
		// a que a arquitetura escolheu quando recusou NACK. A dívida 25 fecha aquela decisão com
		// "a recuperação de perda aqui é o IDR pedido por PLI, que custa um quadro e não uma
		// fila"; sem este bloco, o PLI não estava ligado no caso que o escolheu, e o
		// decodificador ficava sem referência até o próximo IDR **programado** do emissor —
		// medido em até 2 s na câmera do Android.
		//
		// `frames_dropped` é gatilho suficiente, e isso não é óbvio: um quadro que some inteiro
		// não incrementa ele próprio, mas o buraco na sequência é visto no pacote seguinte, que
		// condena o quadro seguinte.
		//
		// **Com piso de supressão**, como a RFC 4585 pede e como a aritmética do
		// `anomalia-de-sequencia.md` exige: atender um PLI injeta um IDR inteiro em rajada no
		// caminho que acabou de perder pacote, e os IDR são 69% dos pacotes daquele fluxo.
		//
		// Os dois números são os mesmos das outras duas cascas receptoras (`Receptor.swift` do
		// macOS e `receber.rs` do Windows): é uma política, não três.
		// **Dois pisos, e o motivo foi medido no Dell G3, na sonda do Windows.** Com um piso
		// só, de 500 ms, um PLI disparado por outra causa gastava o orçamento e a perda de rede
		// esperava os 500 ms inteiros — 462 · 519 · 518 ms de decodificador sem referência,
		// contra 24 e 25 ms quando a ordem se invertia. Supressão é **por causa**: um PLI que
		// saiu antes de a perda existir não pode consertá-la. O piso longo vale só para
		// insistir num pedido que ninguém atendeu.
		const uint64_t sondagem_de_perda_ns = 50000000ull;        // 50 ms
		const uint64_t piso_do_primeiro_pedido_ns = 100000000ull; // 100 ms
		// 250 ms desde 27/08/2026, e o número é **emprestado do Android**: a varredura de
		// docs/android-para-android.md (seção 17) mostrou que a mediana não se move de 100 a
		// 2000 ms e que quem decide é a cauda — p95 de 490 ms no piso 250 contra 1147+ nos
		// pisos de 500 para cima —, ao custo de 85 PLI/min em vez de 173 no piso de 100.
		// Não foi medido neste rádio nem neste sistema, e os 500 ms anteriores também não
		// eram: eram palpite. Trocar palpite por número medido noutro lugar é melhora, não
		// prova.
		const uint64_t piso_entre_repeticoes_ns = 250000000ull;   // 250 ms
		uint64_t perdidos_antes = 0, ultima_sondagem = 0;
		/// Linha de base **da condenação**, separada da de `perdidos_antes` de propósito: a
		/// política de PLI tem a sua e não pode mudar de comportamento por causa desta.
		uint64_t antes_da_condenacao = 0;
		bool leu_perdidos = false, perda_pendente = false;
		uint64_t idrs_quando_perdeu = 0, perda_em = 0;
		bool pediu_por_esta_perda = false;

		// A derivada do dano, que é o que atravessa até o emissor. Ver `janela-do-enlace.h`.
		// Vive na pilha desta thread de propósito: a `laco` é a dona da sessão, e o relato sai
		// da mesma thread que chama `quall_session_next_event` porque o header assim exige.
		const uint64_t janela_do_enlace_ns = JANELA_DO_ENLACE_MS * 1000000ull;
		struct janela_do_enlace janela;
		janela_do_enlace_zerar(&janela);
		uint64_t ultimo_enlace = 0;
		int relatos_recusados = 0;

		// A câmera do aparelho (R9b): o controle desta sessão de vídeo. Só aqui, no ramo com
		// vídeo: a sessão só de som não tem câmera para controlar.
		camera_remota_comecar(r->camera, ses);

		while (ainda_vale(r, geracao)) {
			// **A track de som pode chegar depois da de vídeo**, e chega assim em quase todo
			// emissor: ela é a segunda do `tracks` do `quall_host`. Uma espiada com prazo
			// zero por volta, da mesma thread que chama `quall_session_next_event`, como o
			// header exige. Para de espiar quando uma é adotada.
			if (!audio) {
				QuallTrack *nova = quall_session_next_track(ses, 0);
				if (nova)
					arquivar_track(r, nova, &t, &audio);
			}
			// O som adotado vira som publicado (S5): uma tentativa por sessão.
			if (audio && !som_tentado) {
				som_tentado = true;
				som_ligado = ligar_o_som(r, audio);
			}
			enum QuallSessionEvent ev = quall_session_next_event(ses, 20);
			if (ev == QUALL_SESSION_EVENT_DISCONNECTED) {
				dizer(r, "Quall.Estado.EmissorSaiu");
				espera = 1000;
				break;
			}
			if (ev == QUALL_SESSION_EVENT_FAILED) {
				dizer(r, "Quall.Estado.TransporteFalhou");
				break;
			}
			// A bombeada da câmera, com prazo zero, da mesma thread que chama
			// `quall_session_next_event` (§11.1 do contrato, achado M13): os relógios dela
			// andam pelo relógio, e a espera continua sendo a dos 20 ms acima.
			camera_remota_bombear(r->camera);

			uint64_t agora = os_gettime_ns();
			sincronizar(s, som_ligado ? r->som : NULL, t, audio);

			// A sondagem de perda. Ela é separada do relatório de 5 s de propósito: aqui
			// cada milissegundo entra direto no tempo em que o decodificador fica sem
			// referência.
			if (agora - ultima_sondagem > sondagem_de_perda_ns) {
				ultima_sondagem = agora;
				pthread_mutex_lock(&s->trava);
				uint64_t idrs = s->idrs_recebidos;
				uint64_t quando_idr = s->ultimo_idr_ns;
				pthread_mutex_unlock(&s->trava);
				// Um IDR que chegou sozinho apaga o pedido pendente: se o GOP do
				// emissor já consertou dentro da janela de supressão, pedir seria
				// injetar uma rajada de IDR por nada.
				//
				// A linha do diário aqui não é enfeite: **é o tempo em que o
				// decodificador ficou sem referência**, que é o número que diz se o
				// conserto está funcionando nesta instalação. Sai uma vez por evento
				// de perda, não por quadro.
				if (perda_pendente && idrs > idrs_quando_perdeu) {
					perda_pendente = false;
					diga(LOG_INFO,
					     "%s: referência de volta em %" PRIu64
					     " ms (IDR depois da perda)",
					     "fonte",
					     (quando_idr > perda_em ? quando_idr - perda_em : 0) /
						     1000000ull);
				}

				uint64_t perdidos = 0;
				if (ler_quadros_perdidos(t, &perdidos)) {
					if (leu_perdidos && perdidos > perdidos_antes &&
					    !perda_pendente) {
						perda_pendente = true;
						pediu_por_esta_perda = false;
						idrs_quando_perdeu = idrs;
						perda_em = agora;
						diga(LOG_INFO,
						     "%s: o núcleo perdeu quadro (frames_dropped %" PRIu64
						     " -> %" PRIu64 "); pedindo IDR",
						     "fonte", perdidos_antes,
						     perdidos);
					}
					perdidos_antes = perdidos;
					leu_perdidos = true;
				}
				// A mesma ruptura que dispara o pedido de IDR passa a **condenar a
				// cadeia de referência**: pedir IDR conserta a recuperação, condenar
				// conserta o que se mostra até ela chegar.
				//
				// **A trava vem depois de `ler_quadros_perdidos`, e a ordem não é
				// estilo.** Aquela função entra no núcleo, que pega o cadeado do
				// depacotizador; a thread da libdatachannel segura esse mesmo cadeado
				// enquanto chama `ao_quadro` → `enfileirar`, que pede `s->trava`.
				// Segurar `s->trava` aqui e entrar no núcleo fecharia o ciclo ABBA, e
				// o travamento pareceria culpa do caminho da perda.
				//
				// A granularidade desta origem é a da sondagem, 50 ms — é um piso, e
				// `suspeitos` é maior ou igual ao relatado. A **outra** origem de
				// condenação desta casca, o descarte na fila local, é exata e por
				// quadro; ver `enfileirar`.
				if (leu_perdidos && perdidos > antes_da_condenacao) {
					pthread_mutex_lock(&s->trava);
					s->rupturas++;
					if (!s->cadeia_condenada)
						s->condenada_desde_ns = agora;
					s->cadeia_condenada = true;
					pthread_mutex_unlock(&s->trava);
				}
				if (leu_perdidos)
					antes_da_condenacao = perdidos;
			}

			// Sem IDR não há imagem. O header manda insistir por alguns milissegundos: a
			// track pode ainda não ter aberto quando o PLI é pedido.
			//
			// Duas condições, um pedido: **não publicou ainda** (a metade que já existia)
			// **ou** o núcleo perdeu quadro (a metade que faltava). O piso de 300 ms da
			// entrada continua valendo para ela; a perda usa o piso de supressão, maior.
			bool na_entrada = !s->publicados && agora - ultimo_pli > 300000000ull;
			uint64_t piso = pediu_por_esta_perda ? piso_entre_repeticoes_ns
							     : piso_do_primeiro_pedido_ns;
			bool na_perda = perda_pendente && agora - ultimo_pli > piso;
			if (na_entrada || na_perda) {
				enum QuallStatus st = quall_track_request_idr(t);
				ultimo_pli = agora;
				if (na_perda && st == QUALL_STATUS_OK)
					pediu_por_esta_perda = true;
				// Recusa não é para engolir: o header manda insistir por alguns
				// milissegundos, e o pendente continua de pé para a volta seguinte.
				if (st != QUALL_STATUS_OK && na_perda)
					diga(LOG_WARNING,
					     "%s: pedido de IDR na perda recusado (status %d): %s",
					     "fonte", (int)st,
					     registro_causa_status(st));
			}
			if (s->publicados && !avisou_primeira) {
				avisou_primeira = true;
				dizer(r, "Quall.Estado.PrimeiraImagem",
				      (unsigned long long)((s->primeiro_publicado_ns - t_track) / 1000000));
			}
			// ---------------------------------------------------------------------
			// **O caminho de volta do sinal**, a 2 Hz: o receptor conta ao emissor o
			// que viu do enlace na janela, e é isso que acorda o controlador de taxa
			// do outro lado.
			//
			// **Sem esta casca relatar, aquele controlador é inerte por construção** —
			// não desligado, inerte: ele roda e não tem o que ler. Medido em 31/08/2026
			// no par A10s → iPad, com o controlador ligado: `trocas_de_bitrate=0` com
			// 2,95 % de perda, porque o relato existia só no Android.
			//
			// **Daqui, e não do tratador de quadro**: o header exige que
			// `quall_session_report_link` saia da **mesma thread** que chama
			// `quall_session_next_event`. Nesta casca essa thread é a `laco`, que é a
			// dona da sessão — a regra que abre este arquivo.
			//
			// **Sai sempre**, sem propriedade de fonte para ligar ou desligar, ao
			// contrário de `congelar`. Nos dois braços de um A/B o mesmo tráfego de
			// relato precisa estar no ar: uma diferença que possa ser explicada pelo
			// próprio instrumento não mede nada. Custa ~129 bytes por janela — 0,05 %
			// de um vídeo de 4 Mbps.
			//
			// **A ordem das duas leituras não é estilo: é o mesmo ciclo ABBA da
			// sondagem de perda.** `ler_acumulados_do_enlace` entra no núcleo e pega o
			// cadeado do depacotizador; a thread da libdatachannel segura esse mesmo
			// cadeado enquanto chama `ao_quadro` → `enfileirar`, que pede `s->trava`.
			// Primeiro o núcleo, sem trava nenhuma na mão; depois `s->trava`, e só para
			// copiar um `uint64_t`.
			//
			// Uma terceira batida, própria: a sondagem de perda é de 50 ms e o
			// relatório é de 5 s. Ver `JANELA_DO_ENLACE_MS` para por que 500.
			if (agora - ultimo_enlace >= janela_do_enlace_ns) {
				ultimo_enlace = agora;
				uint64_t vistos = 0, perdidos_de_verdade = 0, idrs_quebrados = 0;
				if (ler_acumulados_do_enlace(t, &vistos, &perdidos_de_verdade,
							     &idrs_quebrados)) {
					pthread_mutex_lock(&s->trava);
					uint64_t suspeitos = s->suspeitos;
					pthread_mutex_unlock(&s->trava);

					struct amostra_do_enlace am;
					if (janela_do_enlace_fechar(&janela, agora,
								    JANELA_DO_ENLACE_MS, vistos,
								    perdidos_de_verdade, suspeitos,
								    idrs_quebrados, &am)) {
						char linha[256];
						formatar_janela_do_enlace(&am, linha, sizeof linha);
						diga(LOG_INFO, "%s: %s",
						     "fonte", linha);
						// O último campo é quantos quadros **esta casca**
						// não conseguiu entregar na janela. O plugin
						// descarta na fila local quando o OBS não drena;
						// é esse o número, e é ele que faz o emissor
						// descer em vez de subir (ver §8.63 e o campo
						// `nao_decodificados` do núcleo).
						uint64_t nao_entregues =
							s->descartados_na_fila -
							s->descartados_no_relato;
						s->descartados_no_relato =
							s->descartados_na_fila;
						enum QuallStatus st = quall_session_report_link(
							ses, am.ms, am.pacotes, am.perdidos,
							am.suspeitos, am.idrs_quebrados,
							nao_entregues);
						// Três vezes e cala, e o laço não para por isso: um
						// emissor de versão antiga não escuta por conta
						// própria, e um socket morto aparece no detector de
						// queda que já existe, alguns milissegundos adiante.
						if (st != QUALL_STATUS_OK &&
						    relatos_recusados < 3) {
							relatos_recusados++;
							diga(LOG_WARNING,
							     "%s: o relato do enlace não saiu "
							     "(status %d): %s",
							     "fonte",
							     (int)st, registro_causa_status(st));
						}
					}
				}
			}

			if (agora - ultimo_relato > 5000000000ull) {
				ultimo_relato = agora;
				relatar(s, "em curso");
				relatar_perda(r, t);
				if (som_ligado)
					relatar_o_som(r, s);
			}
		}
		relatar(s, "fim da sessão");
		relatar_perda(r, t);
		if (som_ligado)
			relatar_o_som(r, s);
		// O controle da câmera sai antes das tracks e da sessão. Com a geração virada (a pessoa
		// mexendo no endereço ou no PIN) ou a fonte morrendo, o painel não é refeito daqui.
		camera_remota_acabar(r->camera,
				     ainda_vale(r, geracao) && !os_atomic_load_bool(&r->parar));
	}

	// --- encerrar, na ordem que o header pede -------------------------------------------------
	// As tracks primeiro; depois a sessão. Nenhuma chamada à API C daqui em diante toca num id
	// que já morreu — regra de plataforma, não higiene: no Windows a libdatachannel lança de
	// dentro do `lock_guard` do mutex global do `capi.cpp` e **não solta o cadeado**.
	//
	// **Duas barreiras, e é o status delas que manda.** Primeiro desligar o tratador de quadro da
	// track; depois fechar a sessão. Basta uma das duas devolver `QUALL_STATUS_OK` para a ponte
	// poder ser liberada, porque a única coisa que a usa é `ao_quadro`.
	bool barreira = true;
	if (t) {
		enum QuallStatus st = quall_track_on_frame(t, NULL, NULL);
		if (st != QUALL_STATUS_OK) {
			barreira = false;
			diga(LOG_WARNING, "desregistro do tratador de quadro devolveu status %d: %s",
			     (int)st, registro_causa_status(st));
		}
	}
	// O som da sessão sai antes das tracks: a porta puxada é solta **antes** de a track de som ser
	// liberada (`quall_audio_playout_free` tira o produtor do caminho do pacote, com barreira). A
	// thread do som da fonte continua, publicando silêncio até a próxima sessão (crítica 14, M1).
	if (som_ligado) {
		pthread_mutex_lock(&s->trava);
		s->sinc.valido = false;
		s->sinc.som = NULL;
		pthread_mutex_unlock(&s->trava);
		som_soltar(r->som);
		som_ligado = false;
	}
	// Os handles só saem **depois** de todo tratador desligado, na ordem que o `quall.h` pede
	// (crítica 10, m1).
	if (audio)
		quall_track_free(audio);
	if (t)
		quall_track_free(t);
	enum QuallStatus st_fechar = quall_session_close(ses);
	if (st_fechar != QUALL_STATUS_OK)
		diga(LOG_WARNING, "quall_session_close devolveu status %d: %s", (int)st_fechar,
		     registro_causa_status(st_fechar));
	else
		barreira = true;

	sessao_encerrar(s, barreira);
	obs_source_output_video(r->fonte, NULL);
	return espera;
}

static void *laco_principal(void *arg)
{
	struct receptor *r = arg;
	os_set_thread_name("quall-receptor");

	while (!os_atomic_load_bool(&r->parar)) {
		pthread_mutex_lock(&r->trava);
		char *endereco = bstrdup(r->endereco ? r->endereco : "");
		char *pin = bstrdup(r->pin ? r->pin : "");
		char *nome = bstrdup(r->nome ? r->nome : "OBS");
		uint32_t prazo = r->prazo_ms;
		uint32_t geracao = r->geracao;
		bool esperando = r->esperando_clique;
		pthread_mutex_unlock(&r->trava);

		uint32_t espera;
		if (!*endereco) {
			dizer(r, "Quall.Estado.Escolha");
			espera = 1000;
		} else if (esperando) {
			// Nada de disparar sozinho: quem diz quando é a pessoa. A espera é longa porque
			// `acordar()` corta na hora — o número é teto, não cadência.
			dizer(r, "Quall.Estado.Pronto", endereco);
			espera = 60000;
		} else {
			espera = uma_sessao(r, endereco, pin, nome, prazo, geracao);
		}

		bfree(endereco);
		bfree(pin);
		bfree(nome);

		if (espera && !os_atomic_load_bool(&r->parar))
			dormir(r, espera);
	}
	return NULL;
}

// -------------------------------------------------------------------------------------------------
// Superfície pública
// -------------------------------------------------------------------------------------------------
/// O tique do vídeo do OBS, na thread gráfica: só guarda a hora (a espera da imagem mira nele).
static void tique_do_obs(void *param, float segundos)
{
	struct receptor *r = param;
	// A hora **do quadro** do canvas, e não a de agora (crítica 16, N7): o render deste tique carimba
	// o quadro com ela (`video_sleep`, `vframe_info.timestamp`), e a gravação mede o Δ contra ela. O
	// `os_gettime_ns` daqui é essa hora mais o atraso de acordar da thread de vídeo, um viés
	// pequeno e constante contra a gravação.
	uint64_t agora = obs_get_video_frame_time();
	pthread_mutex_lock(&r->trava_do_tique);
	r->ultimo_tique_ns = agora;
	pthread_mutex_unlock(&r->trava_do_tique);
	UNUSED_PARAMETER(segundos);
}

struct receptor *receptor_criar(obs_source_t *fonte)
{
	struct receptor *r = bzalloc(sizeof(*r));
	r->fonte = fonte;
	r->prazo_ms = 20000;
	// A primeira atualização vem do OBS montando a cena, e não de alguém digitando. Ver
	// `struct receptor::primeira_vez`.
	r->primeira_vez = true;
	pthread_mutex_init(&r->trava, NULL);
	pthread_mutex_init(&r->trava_do_tique, NULL);
	os_event_init(&r->acordado, OS_EVENT_TYPE_AUTO);
	snprintf(r->estado, sizeof(r->estado), "%s", obs_module_text("Quall.Estado"));
	r->camera = camera_remota_criar(fonte);
	obs_add_tick_callback(tique_do_obs, r);
	return r;
}

static void acordar(struct receptor *r)
{
	pthread_mutex_lock(&r->trava);
	r->geracao++;
	if (r->cancelador)
		quall_session_cancel(r->cancelador); // autorizado de qualquer thread
	pthread_mutex_unlock(&r->trava);
	os_event_signal(r->acordado);
}

void receptor_atualizar(struct receptor *r, obs_data_t *ajustes)
{
	const char *escolhido = obs_data_get_string(ajustes, "aparelho");
	const char *manual = obs_data_get_string(ajustes, "endereco");
	const char *endereco = (escolhido && strcmp(escolhido, "manual") != 0 && *escolhido) ? escolhido
										             : manual;

	pthread_mutex_lock(&r->trava);
	// **Com quem se fala mudou?** Endereço e PIN, e só eles. Um `.update` que só mexe em
	// "latência mínima" não pode exigir um clique nem derrubar uma sessão de pé.
	const char *pin = obs_data_get_string(ajustes, "pin");
	bool identidade_mudou = !r->endereco || !r->pin ||
			        strcmp(r->endereco, endereco ? endereco : "") != 0 ||
			        strcmp(r->pin, pin ? pin : "") != 0;
	if (r->primeira_vez)
		r->primeira_vez = false;
	else if (identidade_mudou)
		r->esperando_clique = true;
	// Outro emissor, ou o mesmo com outro PIN: o tamanho que a fonte publica volta a ser o da
	// primeira imagem que chegar (M3). Mudar só "latência mínima" ou "gravar" não o toca.
	if (identidade_mudou) {
		r->publicado_l = 0;
		r->publicado_a = 0;
	}

	bfree(r->endereco);
	bfree(r->pin);
	bfree(r->nome);
	r->endereco = bstrdup(endereco ? endereco : "");
	r->pin = bstrdup(pin);
	r->nome = bstrdup(obs_data_get_string(ajustes, "nome"));
	r->sem_buffer = obs_data_get_bool(ajustes, "sem_buffer");
	r->congelar = obs_data_get_bool(ajustes, "congelar");
	// **`gravar` é o único dos três que a sessão lê uma vez, ao nascer** (ver `sessao_criar`).
	// `congelar` é consultado quadro a quadro em `s->r->congelar`, e `sem_buffer` é aplicado
	// logo abaixo pelo próprio OBS: nenhum dos dois precisa de sessão nova para valer.
	bool gravar_mudou = r->gravar != obs_data_get_bool(ajustes, "gravar");
	r->gravar = obs_data_get_bool(ajustes, "gravar");
	pthread_mutex_unlock(&r->trava);

	obs_source_set_async_unbuffered(r->fonte, r->sem_buffer);
	// Qualquer `.update` (uma tecla no endereço, no PIN, no nome) segura o refazer do painel da
	// câmera: refazer com a pessoa digitando come as teclas (ver `dizer`).
	camera_remota_ajustes_mudaram(r->camera);

	if (!r->laco_vivo) {
		if (pthread_create(&r->laco, NULL, laco_principal, r) == 0)
			r->laco_vivo = true;
		else
			diga(LOG_ERROR, "não consegui criar a thread do receptor");
	} else if (identidade_mudou || gravar_mudou) {
		// **Só quem precisa acorda o laço.** `acordar` vira a geração, e virar a geração
		// derruba a sessão de pé (`laco_de_sessao` roda enquanto `ainda_vale`). Antes disto
		// qualquer tecla em qualquer campo cortava o vídeo — inclusive marcar uma caixa que a
		// sessão nem consulta.
		acordar(r);
	}
}

void receptor_conectar_agora(struct receptor *r)
{
	if (!r)
		return;
	pthread_mutex_lock(&r->trava);
	r->esperando_clique = false;
	pthread_mutex_unlock(&r->trava);
	// `acordar` também cancela a tentativa em curso e vira a geração — é o que faz o botão
	// significar "esta configuração, agora" em vez de "entra na fila".
	acordar(r);
}

void receptor_destruir(struct receptor *r)
{
	if (!r)
		return;
	os_atomic_set_bool(&r->parar, true);
	acordar(r);
	if (r->laco_vivo)
		pthread_join(r->laco, NULL);
	obs_remove_tick_callback(tique_do_obs, r);
	// A `laco` terminou, e com ela toda sessão e toda thread de decodificação: ninguém mais lê o
	// mapa do som.
	som_fechar(r->som);
	r->som = NULL;
	camera_remota_destruir(r->camera);
	r->camera = NULL;

	pthread_mutex_destroy(&r->trava_do_tique);
	os_event_destroy(r->acordado);
	pthread_mutex_destroy(&r->trava);
	bfree(r->endereco);
	bfree(r->pin);
	bfree(r->nome);
	bfree(r);
}

long receptor_pontes_deixadas(void)
{
	return os_atomic_load_long(&pontes_deixadas);
}
