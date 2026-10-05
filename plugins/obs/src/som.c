#include "som.h"
#include "tempo-do-som.h"

#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <pthread/qos.h>
#endif
#ifdef _WIN32
#include <windows.h>
#endif

// =================================================================================================
// O som da fonte do Quall. Ver `som.h` para o desenho; aqui ficam as decisões miúdas.
//
// **O relógio de produção é o do sistema.** O OBS não puxa áudio de fonte assíncrona: quem publica
// decide quando. A thread produz blocos de 10 ms no ritmo do `os_gettime_ns`, e é essa cadência que
// o núcleo vê como "o DAC": ela puxa um slot de 20 ms sempre que o reamostrador pede mais entrada,
// dizendo daqui a quanto a primeira amostra dele toca (o adiantamento mais o que já está à frente
// no reamostrador). Com a razão sugerida aplicada no conteúdo, o nível do buffer do núcleo fica
// parado mesmo com o emissor noutro cristal.
//
// **O carimbo é a hora do bloco mais o adiantamento, e só anda para a frente.** Contínuo, com os
// blocos emendados exatos (480 × 10⁹ / 48 000 = 10⁷ ns). Um atraso da thread maior que
// `ATRASO_MAXIMO_NS` recomeça do agora — um salto para a frente de mais de 70 ms, que a libobs
// põe pelo carimbo; nunca para trás.
//
// **Um bloco atrasado não sai, e abre um salto** (crítica 16, N3; crítica 17). A decisão é tomada
// **antes** de publicar (`salto_publicar`, `tempo-do-som.c`): um bloco cujo carimbo já não está no
// futuro não é publicado, e nada sai até um bloco com o carimbo no futuro **e** pelo menos 80 ms
// depois do fim do último publicado. Os blocos do meio são produzidos (a porta é puxada no ritmo de
// sempre, e o mapa segue) e descartados.
// - Publicado, um bloco no passado deixava a libobs pôr a fonte no passado: numa parada de 65 a
//   200 ms a fonte já tinha sido esvaziada, o `audio_ts` ia para o carimbo velho, e o buffer global
//   de áudio subia ~(parada − 40) ms para sempre, para todas as fontes (crítica 17). A primeira
//   versão do salto media a folga depois de publicar, e deixava esse bloco sair.
// - Num atraso curto, a libobs pode ter retemporizado o que estava guardado (`audio_ts = ts->end`,
//   `obs-audio.c:297`, o som ~21 ms depois); o bloco que volta 80 ms à frente, acima dos 70 ms do
//   `TS_SMOOTHING_THRESHOLD`, é posto pelo carimbo, e isso se desfaz.
// A latência não sobe (o carimbo segue na hora do bloco); custa pelo menos 80 ms de som.
//
// **O mapa** (`som_mapa`) é o que sobra da sincronia do lado do som: para cada bloco com som de
// verdade, a hora em que ele toca menos a captura da primeira amostra. O vídeo segura cada quadro
// por ele.
// =================================================================================================

/// O bloco de saída: 10 ms a 48 kHz, estéreo sempre (o PCMU mono é duplicado).
#define TAXA 48000u
#define BLOCO 480u
#define BLOCO_NS 10000000ull
#define CANAIS 2u
/// Um slot de 20 ms a 48 kHz, estéreo, é o maior que a porta entrega.
#define SLOT_MAX (960u * 2u)
/// Quantos slots o registro das marcas guarda (o reamostrador tem no máximo ~200 ms de entrada).
#define MARCAS 32
/// Atrasada mais que isto, a produção recomeça do agora.
#define ATRASO_MAXIMO_NS 200000000ull
/// **Só bancada** (`som-no-obs.sh --atrasar-o-som MS`): a thread dorme MS uma vez, aos 10 s, para a
/// prova do salto na libobs de verdade. Com `QUALL_OBS_PROVA_SEM_SALTO` também, todo bloco sai, o
/// atrasado inclusive: é o controle, que mostra a retemporização de +21 ms (atraso curto) e o buffer
/// global subindo (parada de 65 a 200 ms) que o salto evita. Sem as variáveis (o OBS de todo mundo),
/// nada disto acontece: o `getenv` roda uma vez, no `som_criar`.
#define PROVA_ATRASO_VAR "QUALL_OBS_PROVA_ATRASO_DO_SOM_MS"
#define PROVA_SEM_SALTO_VAR "QUALL_OBS_PROVA_SEM_SALTO"
#define PROVA_ATRASO_NO_BLOCO 1000u
/// Um mapa mais velho que isto não vale: o som parou de chegar (ocioso) e a imagem não espera.
#define MAPA_VALE_NS 500000000ull
/// **O atraso do codificador Opus do emissor** (crítica 14, M4): o que o decodificador devolve na
/// posição p é a captura de p menos a antecipação do codificador — 312 amostras a 48 kHz, 6,5 ms,
/// nos presets de áudio e de voz (2,5 ms de antecipação e 4 ms de compensação). O T0 do Mac mediu
/// os mesmos 6,5 ms (§17.4). O PCMU não tem: o atraso dele é o do filtro por 6.
#define OPUS_ATRASO_DO_CODIFICADOR_US 6500.0

/// Onde começa cada slot na entrada do reamostrador, e o carimbo dele.
struct marca {
	uint64_t inicio;       // quadro de entrada (48 kHz) onde o slot começa
	uint64_t timestamp_us; // o carimbo do slot, na base da track
	bool tem_carimbo;      // ocioso não tem
};

struct som {
	obs_source_t *fonte;

	pthread_t thread;
	bool thread_viva;
	volatile bool parar;

	// --- a porta da sessão, sob `trava_da_porta` (a thread a segura por bloco) ---
	pthread_mutex_t trava_da_porta;
	QuallAudioPlayout *porta;
	QuallAudioDecoder *dec; // Opus; nulo no PCMU
	bool pcmu;
	uint32_t canais_do_fio;     // 1 no PCMU; 1 ou 2 no Opus
	uint32_t amostras_por_slot; // no fio: 160 no PCMU, 960 no Opus
	double atraso_interno_us;   // o filtro do PCMU, ou a antecipação do Opus
	bool reiniciar;             // a porta mudou: zerar o estado da thread

	// --- só da thread do som ---
	struct reamostrador ream;
	struct interpolador interp;
	struct marca marcas[MARCAS];
	size_t proxima_marca;
	uint64_t empurrados;
	float ultima_pcmu;

	// --- partilhado, sob `trava` ---
	pthread_mutex_t trava;
	bool codec_pcmu;
	uint64_t ligacoes;
	double razao_aplicada;
	uint64_t puxadas, quadros, fec, silencios, ociosas, blocos, blocos_com_som;
	uint64_t atrasos, atrasos_alem_da_folga, falhas_de_decodificar;
	/// Saltos por folga estourada, e blocos que eles deixaram de publicar.
	uint64_t saltos, blocos_saltados;
	/// A prova do salto (só bancada; ver `PROVA_ATRASO_VAR`). Lidos no `som_criar`, antes da thread.
	uint32_t prova_atraso_ms;
	bool prova_sem_salto;
	/// A menor folga (adiantamento menos o atraso da thread) desde o último relato, em ns.
	int64_t folga_minima_ns;
	/// O mapa: `hora = captura_us * 1000 + desvio`, e quando foi medido.
	int64_t mapa_desvio_ns;
	uint64_t mapa_em_ns;
	/// A hora do fim do último bloco publicado (para o relato: o adiantamento que a libobs vê).
	uint64_t fim_publicado_ns;
};

// -------------------------------------------------------------------------------------------------
// Decodificar um slot em float, a 48 kHz, estéreo
// -------------------------------------------------------------------------------------------------

/// Devolve quantos quadros de 48 kHz foram escritos em `saida` (estéreo intercalado).
static size_t decodificar(struct som *s, const QuallAudioSlot *sl, float *saida)
{
	if (s->pcmu) {
		float a8k[160];
		float a48[160 * INTERPOLADOR_FATOR];
		size_t n = s->amostras_por_slot > 160 ? 160 : s->amostras_por_slot;
		if (sl->order == QUALL_AUDIO_ORDER_FRAME && sl->payload && sl->len >= n) {
			for (size_t i = 0; i < n; i++)
				a8k[i] = mulaw_para_float(sl->payload[i]);
		} else {
			// Silêncio, socorro ou ocioso no PCMU: uma rampa de 5 ms da última amostra até zero,
			// e não um corte seco (o estalo por pacote perdido, crítica 9, miúdo 3).
			float de = s->ultima_pcmu;
			for (size_t i = 0; i < n; i++)
				a8k[i] = i < 40 ? de * (1.0f - (float)(i + 1) / 40.0f) : 0.0f;
		}
		s->ultima_pcmu = a8k[n - 1];
		interpolador_processar(&s->interp, a8k, n, a48);
		for (size_t i = 0; i < n * INTERPOLADOR_FATOR; i++) {
			saida[i * 2] = a48[i];
			saida[i * 2 + 1] = a48[i];
		}
		return n * INTERPOLADOR_FATOR;
	}
	int16_t pcm[SLOT_MAX];
	intptr_t n = -1;
	switch (sl->order) {
	case QUALL_AUDIO_ORDER_FRAME:
		n = quall_audio_decoder_decode(s->dec, sl->payload, sl->len, false, pcm, SLOT_MAX);
		break;
	case QUALL_AUDIO_ORDER_FEC:
		// Só com LBRR de verdade: sem ele, `decode_fec` cai na ocultação e devolve sucesso.
		n = sl->fec_has_lbrr == 1
			    ? quall_audio_decoder_decode(s->dec, sl->payload, sl->len, true, pcm, SLOT_MAX)
			    : quall_audio_decoder_decode(s->dec, NULL, 0, false, pcm, SLOT_MAX);
		break;
	case QUALL_AUDIO_ORDER_SILENCE:
		n = quall_audio_decoder_decode(s->dec, NULL, 0, false, pcm, SLOT_MAX);
		break;
	default:
		n = 0;
		break;
	}
	size_t quadros = s->amostras_por_slot;
	if (n < 0) {
		pthread_mutex_lock(&s->trava);
		s->falhas_de_decodificar++;
		pthread_mutex_unlock(&s->trava);
		n = 0;
	}
	const size_t c = s->canais_do_fio;
	for (size_t i = 0; i < quadros; i++) {
		float e = 0.0f, d = 0.0f;
		if ((intptr_t)i < n) {
			e = (float)pcm[i * c] / 32768.0f;
			d = c > 1 ? (float)pcm[i * c + 1] / 32768.0f : e;
		}
		saida[i * 2] = e;
		saida[i * 2 + 1] = d;
	}
	return quadros;
}

// -------------------------------------------------------------------------------------------------
// A thread
// -------------------------------------------------------------------------------------------------

/// Puxa um slot da porta e o põe no reamostrador. `sai_em_ns` é a hora em que a primeira amostra do
/// bloco em produção toca; `agora_ns`, a de agora.
static void puxar_um_slot(struct som *s, uint64_t sai_em_ns, uint64_t agora_ns, double razao)
{
	// Daqui a quanto a primeira amostra deste slot toca: a hora do bloco em produção, mais tudo o
	// que já está à frente no reamostrador, lido a `razao`. Com o adiantamento, é positivo (o
	// `delay_to_dac_us` que era sempre zero, crítica 14, m3).
	double a_frente_ns = reamostrador_a_frente(&s->ream) / razao / (double)TAXA * 1e9;
	double toca_em_ns = (double)sai_em_ns + a_frente_ns;
	double atraso_us = (toca_em_ns - (double)agora_ns) / 1000.0;
	uint32_t atraso = atraso_us > 0 ? (uint32_t)atraso_us : 0;

	// O slot vale até a próxima puxada: local, zerado inteiro antes de a fronteira escrever.
	QuallAudioSlot slot;
	memset(&slot, 0, sizeof slot);
	if (quall_audio_playout_pull(s->porta, atraso, razao, &slot) != QUALL_STATUS_OK) {
		memset(&slot, 0, sizeof slot);
		slot.order = QUALL_AUDIO_ORDER_IDLE;
	}
	// 960 quadros de 48 kHz em qualquer caso, estéreo.
	float pcm[SLOT_MAX];
	size_t n;
	if (slot.order == QUALL_AUDIO_ORDER_IDLE && !s->pcmu) {
		n = s->amostras_por_slot;
		memset(pcm, 0, n * CANAIS * sizeof(float));
	} else {
		// No PCMU o ocioso também passa pelo filtro: a rampa até zero, sem degrau.
		n = decodificar(s, &slot, pcm);
	}
	struct marca *m = &s->marcas[s->proxima_marca];
	m->inicio = s->empurrados;
	m->timestamp_us = slot.timestamp_us;
	m->tem_carimbo = slot.order != QUALL_AUDIO_ORDER_IDLE;
	s->proxima_marca = (s->proxima_marca + 1) % MARCAS;
	s->empurrados += reamostrador_empurrar(&s->ream, pcm, n);

	pthread_mutex_lock(&s->trava);
	s->puxadas++;
	switch (slot.order) {
	case QUALL_AUDIO_ORDER_FRAME:
		s->quadros++;
		break;
	case QUALL_AUDIO_ORDER_FEC:
		s->fec++;
		break;
	case QUALL_AUDIO_ORDER_SILENCE:
		s->silencios++;
		break;
	default:
		s->ociosas++;
		break;
	}
	pthread_mutex_unlock(&s->trava);
}

/// A captura (µs, na base da track de som) da amostra de entrada na posição global `posicao`.
/// `false` quando a amostra é de um slot ocioso, ou velho demais para o registro.
static bool captura_da_posicao(const struct som *s, double posicao, double *captura_us)
{
	const double quadros_por_slot =
		(double)(s->pcmu ? s->amostras_por_slot * INTERPOLADOR_FATOR : s->amostras_por_slot);
	for (size_t i = 0; i < MARCAS; i++) {
		const struct marca *m = &s->marcas[i];
		if (!m->tem_carimbo)
			continue;
		if (posicao >= (double)m->inicio && posicao < (double)m->inicio + quadros_por_slot) {
			// A saída está o atraso interno atrás do sinal: o filtro do PCMU, ou a antecipação do
			// codificador Opus.
			*captura_us = (double)m->timestamp_us + (posicao - (double)m->inicio) / (double)TAXA * 1e6 -
				      s->atraso_interno_us;
			return true;
		}
	}
	return false;
}

static double razao_da_porta(struct som *s)
{
	double r = quall_audio_playout_rate(s->porta);
	if (!isfinite(r) || r <= 0)
		return 1.0;
	if (r > 1.0 + 500e-6)
		r = 1.0 + 500e-6;
	if (r < 1.0 - 500e-6)
		r = 1.0 - 500e-6;
	return r;
}

/// A prioridade da thread (crítica 14, M2): ela concorre com o x264 e com os filtros do usuário, e
/// um atraso maior que o adiantamento cala um tique.
static void subir_a_prioridade(void)
{
#ifdef __APPLE__
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
#ifdef _WIN32
	SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
#endif
}

/// Produz o bloco `t_bloco` (a hora dele sem o adiantamento) em `saida`. Devolve se ele tem som
/// (uma porta ligada), e o mapa em `desvio_ns` quando a primeira amostra mapeia para uma captura.
static bool produzir(struct som *s, uint64_t t_bloco, uint64_t carimbo, uint64_t agora, float *saida,
		     bool *mapeou, int64_t *desvio_ns, double *razao_usada)
{
	*mapeou = false;
	*razao_usada = 1.0;
	pthread_mutex_lock(&s->trava_da_porta);
	if (s->reiniciar) {
		s->reiniciar = false;
		reamostrador_zerar(&s->ream, CANAIS);
		interpolador_iniciar(&s->interp);
		memset(s->marcas, 0, sizeof s->marcas);
		s->proxima_marca = 0;
		s->empurrados = 0;
		s->ultima_pcmu = 0.0f;
	}
	if (!s->porta) {
		pthread_mutex_unlock(&s->trava_da_porta);
		memset(saida, 0, BLOCO * CANAIS * sizeof(float));
		return false;
	}
	double razao = razao_da_porta(s);
	while (reamostrador_disponivel(&s->ream, razao) < BLOCO)
		puxar_um_slot(s, carimbo, agora, razao);
	double posicao = reamostrador_posicao_global(&s->ream);
	size_t n = reamostrador_tirar(&s->ream, saida, BLOCO, razao);
	if (n < BLOCO)
		memset(&saida[n * CANAIS], 0, (BLOCO - n) * CANAIS * sizeof(float));
	double captura_us = 0;
	if (captura_da_posicao(s, posicao, &captura_us)) {
		*mapeou = true;
		*desvio_ns = (int64_t)carimbo - (int64_t)llround(captura_us * 1000.0);
	}
	*razao_usada = razao;
	pthread_mutex_unlock(&s->trava_da_porta);
	UNUSED_PARAMETER(t_bloco);
	return true;
}

static void *thread_do_som(void *arg)
{
	struct som *s = arg;
	os_set_thread_name("quall-som");
	subir_a_prioridade();

	float saida[BLOCO * CANAIS];
	uint64_t t0 = os_gettime_ns();
	uint64_t blocos = 0;
	/// O salto: quem decide, antes de publicar, se o bloco sai.
	struct salto_do_som salto = {0};
	uint64_t produzidos_na_vida = 0;

	while (!os_atomic_load_bool(&s->parar)) {
		if (s->prova_atraso_ms && produzidos_na_vida >= PROVA_ATRASO_NO_BLOCO) {
			os_sleep_ms(s->prova_atraso_ms);
			s->prova_atraso_ms = 0;
		}
		uint64_t agora = os_gettime_ns();
		// `blocos * BLOCO_NS` e não `produzidos * 1e9 / TAXA`: sem o estouro de ~4,45 dias de
		// sessão contínua (crítica 14, m5).
		uint64_t t_bloco = t0 + blocos * BLOCO_NS;
		if (agora > t_bloco + ATRASO_MAXIMO_NS) {
			// A thread ficou parada (o sistema suspendeu, o OBS travou): recomeça do agora. O
			// salto é para a frente e maior que 70 ms, e a libobs põe o bloco pelo carimbo.
			t0 = agora;
			blocos = 0;
			t_bloco = t0;
			pthread_mutex_lock(&s->trava);
			s->atrasos++;
			pthread_mutex_unlock(&s->trava);
		}
		// Produz todo bloco cuja hora de produção já chegou: o bloco k sai na hora t_k, com o
		// carimbo t_k + adiantamento.
		while (t_bloco <= agora && !os_atomic_load_bool(&s->parar)) {
			uint64_t carimbo = t_bloco + SOM_ADIANTAMENTO_NS;
			bool mapeou = false;
			int64_t desvio = 0;
			double razao = 1.0;
			bool com_som = produzir(s, t_bloco, carimbo, agora, saida, &mapeou, &desvio, &razao);

			// A folga deste bloco, **antes** de publicar: quanto antes da hora dele ele sairia. É ela
			// que decide se ele sai (crítica 17).
			uint64_t antes_de_publicar = os_gettime_ns();
			int64_t folga = (int64_t)carimbo - (int64_t)antes_de_publicar;
			bool abriu = false;
			bool publicar = salto_publicar(&salto, carimbo, BLOCO_NS, antes_de_publicar, &abriu);
			if (s->prova_sem_salto) {
				// O controle de bancada: todo bloco sai, o atrasado inclusive.
				publicar = true;
				abriu = false;
				salto.em_salto = false;
			}
			if (publicar) {
				struct obs_source_audio a = {0};
				a.data[0] = (const uint8_t *)saida;
				a.frames = BLOCO;
				a.speakers = SPEAKERS_STEREO;
				a.format = AUDIO_FORMAT_FLOAT;
				a.samples_per_sec = TAXA;
				a.timestamp = carimbo;
				obs_source_output_audio(s->fonte, &a);
			}
			produzidos_na_vida++;
			pthread_mutex_lock(&s->trava);
			s->blocos++;
			if (com_som)
				s->blocos_com_som++;
			s->razao_aplicada = razao;
			if (folga < s->folga_minima_ns)
				s->folga_minima_ns = folga;
			if (folga <= (int64_t)SALTO_MARGEM_NS)
				s->atrasos_alem_da_folga++;
			if (abriu)
				s->saltos++;
			if (!publicar)
				s->blocos_saltados++;
			if (mapeou) {
				s->mapa_desvio_ns = desvio;
				s->mapa_em_ns = carimbo;
			}
			if (publicar)
				s->fim_publicado_ns = carimbo + BLOCO_NS;
			pthread_mutex_unlock(&s->trava);

			blocos++;
			t_bloco = t0 + blocos * BLOCO_NS;
		}
		// O `_fast` dorme sem girar: no Windows o `os_sleepto_ns` gira com `YieldProcessor` depois do
		// `Sleep(ms − 1)`, e em prioridade de tempo real isso é ~1–2 ms de CPU a cada 10 ms, por fonte
		// (crítica 16, N5). O timer do Windows está em 1 ms (`timeBeginPeriod(1)` no `DllMain` da
		// libobs): o que ele erra a mais sai da folga de 20 ms.
		os_sleepto_ns_fast(t_bloco);
	}
	return NULL;
}

// -------------------------------------------------------------------------------------------------
// Criar, ligar, soltar, mapa, relatar, fechar
// -------------------------------------------------------------------------------------------------

struct som *som_criar(obs_source_t *fonte)
{
	struct som *s = bzalloc(sizeof(*s));
	s->fonte = fonte;
	s->razao_aplicada = 1.0;
	s->folga_minima_ns = INT64_MAX;
	s->reiniciar = true;
	const char *atraso = getenv(PROVA_ATRASO_VAR);
	if (atraso && *atraso) {
		long ms = strtol(atraso, NULL, 10);
		s->prova_atraso_ms = ms > 0 && ms < 1000 ? (uint32_t)ms : 0;
		s->prova_sem_salto = getenv(PROVA_SEM_SALTO_VAR) != NULL;
		diga(LOG_WARNING, "som: PROVA DE BANCADA: a thread do som vai dormir %u ms aos 10 s%s",
		     s->prova_atraso_ms, s->prova_sem_salto ? ", sem o salto (o controle)" : "");
	}
	pthread_mutex_init(&s->trava, NULL);
	pthread_mutex_init(&s->trava_da_porta, NULL);
	if (pthread_create(&s->thread, NULL, thread_do_som, s) != 0) {
		pthread_mutex_destroy(&s->trava);
		pthread_mutex_destroy(&s->trava_da_porta);
		bfree(s);
		return NULL;
	}
	s->thread_viva = true;
	return s;
}

bool som_ligar(struct som *s, QuallTrack *audio, char *motivo, size_t cap)
{
	enum QuallTrackKind tipo = quall_track_kind(audio);
	enum QuallAudioCodec codec = quall_track_audio_codec(audio);
	if (codec == QUALL_AUDIO_CODEC_DEFAULT) {
		snprintf(motivo, cap, "a track não disse o codec: %s", quall_last_error());
		return false;
	}
	// O padrão `(buf, cap)`: pergunta o tamanho, e só então lê.
	intptr_t precisa = quall_audio_preset_json(tipo, codec, NULL, 0);
	if (precisa <= 0) {
		snprintf(motivo, cap, "o preset da track não se leu: %s", quall_last_error());
		return false;
	}
	char *json = bmalloc((size_t)precisa);
	if (quall_audio_preset_json(tipo, codec, json, (size_t)precisa) <= 0) {
		snprintf(motivo, cap, "o preset da track não se leu: %s", quall_last_error());
		bfree(json);
		return false;
	}
	obs_data_t *p = obs_data_create_from_json(json);
	if (!p) {
		snprintf(motivo, cap, "o preset da track não é JSON: %s", json);
		bfree(json);
		return false;
	}
	bfree(json);
	long long taxa = obs_data_get_int(p, "sample_rate_hz");
	long long canais = obs_data_get_int(p, "channels");
	long long por_slot = obs_data_get_int(p, "frame_samples");
	obs_data_release(p);

	bool pcmu = codec == QUALL_AUDIO_CODEC_PCMU;
	if (pcmu ? (taxa != 8000 || por_slot != 160) : (taxa != 48000 || por_slot != 960 || canais < 1 ||
							  canais > 2)) {
		snprintf(motivo, cap, "preset fora do que este plugin toca: %lld Hz × %lld, %lld por quadro",
			 taxa, canais, por_slot);
		return false;
	}

	QuallAudioDecoder *dec = NULL;
	if (!pcmu) {
		dec = quall_audio_decoder_new(tipo, codec);
		if (!dec) {
			snprintf(motivo, cap, "o decodificador não abriu: %s", quall_last_error());
			return false;
		}
	}
	QuallAudioPlayout *porta = quall_audio_playout_new(audio, true);
	if (!porta) {
		snprintf(motivo, cap, "a porta puxada não abriu: %s", quall_last_error());
		quall_audio_decoder_free(dec);
		return false;
	}

	// Uma porta ligada ainda (sessão que não soltou): solta antes.
	som_soltar(s);
	pthread_mutex_lock(&s->trava_da_porta);
	s->porta = porta;
	s->dec = dec;
	s->pcmu = pcmu;
	s->canais_do_fio = pcmu ? 1 : (uint32_t)canais;
	s->amostras_por_slot = (uint32_t)por_slot;
	s->atraso_interno_us = pcmu ? INTERPOLADOR_ATRASO_US : OPUS_ATRASO_DO_CODIFICADOR_US;
	s->reiniciar = true;
	pthread_mutex_unlock(&s->trava_da_porta);

	pthread_mutex_lock(&s->trava);
	s->codec_pcmu = pcmu;
	s->ligacoes++;
	s->mapa_em_ns = 0;
	pthread_mutex_unlock(&s->trava);
	return true;
}

void som_soltar(struct som *s)
{
	if (!s)
		return;
	pthread_mutex_lock(&s->trava_da_porta);
	QuallAudioPlayout *porta = s->porta;
	QuallAudioDecoder *dec = s->dec;
	s->porta = NULL;
	s->dec = NULL;
	s->reiniciar = true;
	pthread_mutex_unlock(&s->trava_da_porta);
	pthread_mutex_lock(&s->trava);
	s->mapa_em_ns = 0;
	pthread_mutex_unlock(&s->trava);
	// A thread não usa mais a porta (ela a pega sob a trava, por bloco): pode soltar, com barreira.
	if (porta) {
		enum QuallStatus st = quall_audio_playout_free(porta);
		if (st != QUALL_STATUS_OK)
			diga(LOG_WARNING, "som: a porta puxada fechou com status %d: %s", (int)st,
			     registro_causa_status(st));
	}
	quall_audio_decoder_free(dec);
}

bool som_mapa(struct som *s, int64_t *desvio_ns)
{
	if (!s)
		return false;
	pthread_mutex_lock(&s->trava);
	bool vale = s->mapa_em_ns && os_gettime_ns() < s->mapa_em_ns + MAPA_VALE_NS;
	*desvio_ns = s->mapa_desvio_ns;
	pthread_mutex_unlock(&s->trava);
	return vale;
}

void som_relatar(struct som *s, char *buf, size_t cap)
{
	// O padrão `(buf, cap)`: pergunta o tamanho, e só então lê. Da `laco`, a cada 5 s: alocar aqui
	// não é tempo real. **Sem a `trava_da_porta`** (crítica 16, N6): a thread do som a segura para
	// puxar, e ela não pode esperar um `bmalloc` daqui. Não precisa: a `laco` é a única que liga e
	// solta a porta (este relato também roda nela), e o contrato da fronteira permite
	// `quall_audio_playout_stats_json` junto com o `pull`.
	char *porta = NULL;
	if (s->porta) {
		intptr_t precisa = quall_audio_playout_stats_json(s->porta, NULL, 0);
		if (precisa > 0) {
			porta = bmalloc((size_t)precisa);
			if (quall_audio_playout_stats_json(s->porta, porta, (size_t)precisa) <= 0) {
				bfree(porta);
				porta = NULL;
			}
		}
	}
	// O que a libobs vê: do começo do que ela ainda não consumiu até o fim do que publicamos.
	uint64_t ts_da_libobs = obs_source_get_audio_timestamp(s->fonte);
	pthread_mutex_lock(&s->trava);
	uint64_t agora = os_gettime_ns();
	bool mapa_vale = s->mapa_em_ns && agora < s->mapa_em_ns + MAPA_VALE_NS;
	snprintf(buf, cap,
		 "som %s %u Hz x %u adiantamento_ms=%.1f razao=%.6f ligacoes=%" PRIu64 " puxadas=%" PRIu64
		 " quadros=%" PRIu64 " fec=%" PRIu64 " silencios=%" PRIu64 " ociosas=%" PRIu64 " blocos=%" PRIu64
		 " blocos_com_som=%" PRIu64 " atrasos=%" PRIu64 " atrasos_alem_da_folga=%" PRIu64
		 " folga_minima_ms=%.2f saltos=%" PRIu64 " blocos_saltados=%" PRIu64
		 " falhas_de_decodificar=%" PRIu64 " mapa=%s mapa_ms=%.2f"
		 " libobs_a_frente_ms=%.1f porta=%s",
		 s->codec_pcmu ? "pcmu" : "opus", TAXA, CANAIS, (double)SOM_ADIANTAMENTO_NS / 1e6, s->razao_aplicada,
		 s->ligacoes, s->puxadas, s->quadros, s->fec, s->silencios, s->ociosas, s->blocos, s->blocos_com_som,
		 s->atrasos, s->atrasos_alem_da_folga,
		 s->folga_minima_ns == INT64_MAX ? 0.0 : (double)s->folga_minima_ns / 1e6, s->saltos,
		 s->blocos_saltados, s->falhas_de_decodificar,
		 mapa_vale ? "vale" : "nao", (double)s->mapa_desvio_ns / 1e6,
		 ts_da_libobs && s->fim_publicado_ns ? ((double)s->fim_publicado_ns - (double)ts_da_libobs) / 1e6 : 0.0,
		 porta ? porta : "{}");
	// A folga mínima é por relato.
	s->folga_minima_ns = INT64_MAX;
	pthread_mutex_unlock(&s->trava);
	bfree(porta);
}

void som_fechar(struct som *s)
{
	if (!s)
		return;
	os_atomic_set_bool(&s->parar, true);
	if (s->thread_viva)
		pthread_join(s->thread, NULL);
	som_soltar(s);
	pthread_mutex_destroy(&s->trava);
	pthread_mutex_destroy(&s->trava_da_porta);
	bfree(s);
}
