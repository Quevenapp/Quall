#pragma once

// A aritmética do som do OBS (S5 do `docs/som-no-receptor.md`, §7.3), sem OBS, sem rede e sem
// aparelho: o que não depende da libobs mora aqui, para `bancada/prova-tempo-do-som.c` provar
// sozinho, como `fluidez.c` e `janela-do-enlace.c`.
//
// As peças (o trânsito mínimo do vídeo saiu com o desenho da D5: a imagem espera o som, e o som
// não se ancora mais na chegada do vídeo):
//
// - **O reamostrador** (`struct reamostrador`): a razão do núcleo aplicada ao conteúdo, com a
//   fração levada de um bloco ao outro. O OBS não tem DAC: o relógio dele é o do sistema, e o
//   plugin entrega amostras no ritmo desse relógio. Sem reamostrar, a deriva entre o emissor e o
//   sistema viraria um salto a cada 70 ms acumulados (o `TS_SMOOTHING_THRESHOLD` da libobs).
// - **O µ-law** do PCMU, em tabela.
// - **O interpolador por 6** do PCMU.
// - **A espera da imagem** (`struct espera_da_imagem`): qual tique, e quanto segurar (crítica 16).
//
// Nada aqui aloca depois de criado, e nada aqui tem cadeado: quem chama decide a thread.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// -------------------------------------------------------------------------------------------------
// O reamostrador
// -------------------------------------------------------------------------------------------------

/// A entrada que cabe na fila, em quadros por canal: 200 ms a 48 kHz, com folga.
#define REAMOSTRADOR_FILA 16384
#define REAMOSTRADOR_CANAIS_MAX 2

/// Interpolação cúbica de Hermite (Catmull-Rom) entre quatro vizinhos, com a posição fracionária
/// guardada entre chamadas. Com razão exatamente 1 e fração zero, a saída é a entrada, amostra por
/// amostra: no caso comum (os dois relógios quase iguais) ela só desliza devagar.
struct reamostrador {
	uint32_t canais;
	float fila[REAMOSTRADOR_FILA * REAMOSTRADOR_CANAIS_MAX]; // intercalada
	size_t quadros;   // quantos quadros válidos há na fila
	double posicao;   // posição de leitura, em quadros, a partir do começo da fila (>= 1)
	uint64_t consumidos; // quadros de entrada que já saíram da fila, desde a criação
};

void reamostrador_zerar(struct reamostrador *r, uint32_t canais);
/// Acrescenta `n` quadros intercalados. Devolve quantos couberam.
size_t reamostrador_empurrar(struct reamostrador *r, const float *pcm, size_t n);
/// Quantos quadros de saída dá para tirar agora com `razao` (entrada por saída).
size_t reamostrador_disponivel(const struct reamostrador *r, double razao);
/// Tira até `n` quadros de saída, intercalados, consumindo entrada a `razao` quadros de entrada
/// por quadro de saída. Devolve quantos saíram.
size_t reamostrador_tirar(struct reamostrador *r, float *saida, size_t n, double razao);
/// Quantos quadros de entrada ainda faltam ler, da posição atual ao fim da fila.
double reamostrador_a_frente(const struct reamostrador *r);
/// A posição de leitura atual, em quadros de entrada desde a criação (fracionária).
double reamostrador_posicao_global(const struct reamostrador *r);

// -------------------------------------------------------------------------------------------------
// O interpolador por 6 do PCMU (8 → 48 kHz)
// -------------------------------------------------------------------------------------------------

/// O mesmo FIR do Mac (`InterpoladorPor6`, `SomPuxado.swift`): 144 coeficientes, Kaiser β = 7,
/// corte em 4 kHz, 24 por fase. **Por que existe aqui**: a 8 kHz, o estouro de 3 150 Hz da
/// claquete está a 0,39 da taxa, e a cúbica do reamostrador ali não é transparente (8,6 dB de SNR,
/// medido na prova). Levado a 48 kHz antes, ele fica a 0,066 da taxa, e a cúbica o atravessa.
#define INTERPOLADOR_FATOR 6
#define INTERPOLADOR_POR_FASE 24
/// O atraso de grupo do filtro, em µs: (144 − 1) / 2 amostras a 48 kHz = 1,49 ms.
#define INTERPOLADOR_ATRASO_US ((double)(INTERPOLADOR_FATOR * INTERPOLADOR_POR_FASE - 1) / 2.0 / 48000.0 * 1e6)

struct interpolador {
	float coeficientes[INTERPOLADOR_FATOR * INTERPOLADOR_POR_FASE];
	float historia[INTERPOLADOR_POR_FASE];
	int cabeca;
};

void interpolador_iniciar(struct interpolador *it);
/// `n` amostras de 8 kHz → `6n` de 48 kHz (mono).
void interpolador_processar(struct interpolador *it, const float *entrada, size_t n, float *saida);
/// A última amostra de 8 kHz que entrou (a rampa do silêncio do PCMU parte dela).
float interpolador_ultima(const struct interpolador *it);

// -------------------------------------------------------------------------------------------------
// µ-law
// -------------------------------------------------------------------------------------------------

/// G.711 µ-law para `float` em [-1, 1). Tabela de 256 entradas, a mesma de `MuLaw` do Mac.
float mulaw_para_float(uint8_t u);

// -------------------------------------------------------------------------------------------------
// A espera da imagem (a D5: a imagem espera o som), quadro a quadro
// -------------------------------------------------------------------------------------------------
//
// O `receptor.c` calcula, para cada quadro, a hora em que o som da mesma captura toca (o mapa do
// som) e segura o quadro até o tique do OBS certo. O que decide **qual tique** e **quanto segurar**
// mora aqui, sem OBS, para a prova (crítica 16):
//
// - **O tique, com histerese (N1).** O "tique mais perto" era um limiar seco no meio do quadro:
//   com a hora do som perto do meio entre dois tiques, o jitter trocava o tique de quadro para
//   quadro, e um quadro de 30 fps ficava 1 ou 3 tiques em vez de 2 (a `opus-c`: p95 de 50 ms na
//   fluidez). Agora o quadro fica do mesmo lado do tique do anterior enquanto o erro couber em
//   `ESPERA_HISTERESE` períodos; passou disso **em `ESPERA_TROCA_QUADROS` quadros seguidos**, volta
//   ao mais perto. Uma troca por travessia, e não uma por quadro. Os quadros seguidos são da
//   primeira corrida com a histerese (`r16-opus-b`): a fase parada a 0,51 período e **um** quadro
//   fora da fase (o mapa ou o carimbo de um quadro só) trocaram o lado da corrida inteira, e o Δ
//   pulou de +8,5 para −8,5 ms aos 16,5 s. Um quadro só não troca mais nada.
// - **A rampa (N4).** A espera sobe e desce no máximo `ESPERA_RAMPA` do intervalo entre quadros
//   por quadro (10 %: a imagem anda a 90 % ou 110 % da velocidade por um instante), em vez de
//   congelar ~a espera quando o mapa passa a valer e pular ~a espera quando ele vence. Depois da
//   rampa, a espera é a do tique, com o jitter livre dentro de `ESPERA_FOLGA_DA_RAMPA_NS`; um
//   quadro atrasado sozinho não a derruba.
// - **A decodificação (N10)**: uma mediana corrente (o passo de 1/32), no lugar de ordenar 2 048
//   amostras a cada quadro.

/// O teto da espera de um quadro, desde a chegada.
#define ESPERA_NO_MAXIMO_NS 200000000ll
/// Quanto a espera anda por quadro, como fração do intervalo entre os quadros.
#define ESPERA_RAMPA 0.10
/// Quanto acima da espera atual o teto da rampa fica: o jitter da chegada, sem rampa.
#define ESPERA_FOLGA_DA_RAMPA_NS 20000000ll
/// O quadro fica do lado do tique do anterior enquanto o erro couber nisto, em períodos.
#define ESPERA_HISTERESE 0.75
/// Quantos quadros seguidos fora da histerese trocam o lado.
#define ESPERA_TROCA_QUADROS 2
/// O maior intervalo entre quadros que a rampa considera (10 fps).
#define ESPERA_INTERVALO_MAXIMO_NS 100000000ll
/// A decodificação suposta antes da primeira medida.
#define ESPERA_DECODE_PADRAO_NS 3000000ll

struct espera_da_imagem {
	/// Até onde a espera pode ir neste quadro (a rampa de subida).
	int64_t teto_ns;
	/// A espera do quadro anterior (de onde a rampa de descida parte).
	int64_t ultima_ns;
	/// O erro do tique do quadro anterior (tique − hora do som), para a histerese.
	int64_t erro_anterior_ns;
	bool tem_erro_anterior;
	/// Quadros seguidos que pediram a troca de lado.
	int pedidos_de_troca;
	uint64_t timestamp_anterior_us;
	/// A mediana corrente da decodificação; 0 antes da primeira medida.
	int64_t decode_ns;
};

void espera_zerar(struct espera_da_imagem *e);
/// O tique em que o quadro cuja hora do som é `alvo_ns` aparece: `referencia_ns + k × periodo_ns`,
/// com a histerese. Sem referência ou período, devolve `alvo_ns`. `*trocou` fica verdadeiro quando
/// a histerese soltou (o quadro mudou de lado do tique); `*segurou`, quando o quadro pediu a troca e
/// ficou do lado de antes por ser o primeiro a pedir.
int64_t espera_tique(struct espera_da_imagem *e, int64_t alvo_ns, int64_t referencia_ns, int64_t periodo_ns,
		     bool *trocou, bool *segurou);
/// A histerese esquece o lado (sem mapa, o som mudo): o próximo quadro vai ao tique mais perto.
void espera_esquecer_o_tique(struct espera_da_imagem *e);
/// A espera a aplicar a um quadro, desde a chegada, sempre em [0, `ESPERA_NO_MAXIMO_NS`].
/// `com_espera`: há mapa e o som é ouvido; `desejada_ns`: a espera que põe o quadro no tique
/// (negativa quando ele chegou atrasado). Sem espera, a rampa desce. `*na_rampa` fica verdadeiro
/// quando a espera não é a desejada por causa da rampa.
int64_t espera_do_quadro(struct espera_da_imagem *e, uint64_t timestamp_us, bool com_espera, int64_t desejada_ns,
			 bool *na_rampa);
/// Uma medida da decodificação de um quadro.
void espera_medir_decode(struct espera_da_imagem *e, int64_t decode_ns);

// -------------------------------------------------------------------------------------------------
// O salto do som (crítica 16, N3; crítica 17)
// -------------------------------------------------------------------------------------------------
//
// A thread do som (`som.c`) publica cada bloco de 10 ms com carimbo 20 ms à frente. Se ela atrasa
// (o sistema, um filtro lento, uma parada), um bloco pode ficar com o carimbo **no passado**. Um
// bloco assim, publicado, é posto pela libobs no passado: com a fonte esvaziada numa parada de 65 a
// 200 ms (`discard_if_stopped`), o `audio_ts` dela vai para o carimbo velho, e o `find_min_ts` o
// pega — o buffer global de áudio sobe ~(parada − 40) ms, **para sempre e para todas as fontes**
// (crítica 17, lido em `obs-audio.c:182-219`, `:456`, `:674-676`). A primeira versão do salto media
// a folga **depois** de publicar, e o bloco atrasado saía.
//
// A regra, decidida **antes** de publicar:
// - um bloco com o carimbo a menos de `SALTO_MARGEM_NS` de agora (ou no passado) **não sai**, e
//   abre um salto;
// - no salto, nada sai até um bloco ter o carimbo no futuro **e** `SALTO_MINIMO_NS` depois do fim
//   do último publicado: acima dos 70 ms do `TS_SMOOTHING_THRESHOLD`, a libobs o põe pelo carimbo, e
//   não o emenda ao que tinha.
// O carimbo nunca é mexido: o mapa do som segue valendo, e a imagem não percebe.

/// Quão perto de agora um carimbo pode estar para o bloco ainda sair.
#define SALTO_MARGEM_NS 2000000ull
/// O menor buraco que um salto deixa: acima dos 70 ms em que a libobs emenda o carimbo.
#define SALTO_MINIMO_NS 80000000ull

struct salto_do_som {
	bool em_salto;
	/// O fim do último bloco publicado (0: nenhum ainda).
	uint64_t fim_publicado_ns;
};

/// Decide, antes de publicar, se o bloco `[carimbo, carimbo + duracao)` sai agora. Quando sai,
/// anota o fim dele. `*abriu` fica verdadeiro no bloco que abre um salto.
bool salto_publicar(struct salto_do_som *s, uint64_t carimbo_ns, uint64_t duracao_ns, uint64_t agora_ns,
		    bool *abriu);
/// A decodificação estimada (`ESPERA_DECODE_PADRAO_NS` antes da primeira medida).
int64_t espera_decode(const struct espera_da_imagem *e);
