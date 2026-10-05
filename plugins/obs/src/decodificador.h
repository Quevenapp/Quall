// Decodificador H.264 → NV12. Uma interface, duas implementações.
//
// A fronteira do Quall entrega **quadro codificado**: o núcleo não decodifica, por contrato. O
// `obs_source_output_video()` quer **quadro cru**. O decodificador é a peça que falta entre os dois,
// e ele é da casca — aqui, do plugin.
//
// | plataforma | arquivo | mecanismo |
// |---|---|---|
// | macOS | `decodificador-vt.c` | VideoToolbox |
// | Windows | `decodificador-mf.c` | Media Foundation Transform |
//
// **A interface é de planos NV12 em memória de sistema, e não de textura**, porque é isso que o
// destino aceita: `obs_source_output_video()` de uma fonte assíncrona lê `data[]`/`linesize[]` da
// CPU. Devolver textura obrigaria a uma leitura de volta dentro do `receptor.c`, que é justamente
// o arquivo que não pode saber de plataforma.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct decodificador;

/// Um quadro decodificado, NV12, válido **só durante a chamada** do tratador.
struct dec_nv12 {
	const uint8_t *y;
	uint32_t passo_y; // bytes por linha do plano Y
	const uint8_t *uv;
	uint32_t passo_uv;
	uint32_t largura, altura;
};

/// Chamado **de dentro** de `dec_decodificar`, na mesma thread.
typedef void (*dec_pronto_fn)(void *ctx, const struct dec_nv12 *q, uint64_t chegada_ns,
			      uint64_t decode_ns);

/// Só aloca. O mecanismo de decodificação sobe no primeiro quadro, **na thread que decodifica** —
/// no Windows um `IMFTransform` não atravessa apartamento COM.
struct decodificador *dec_criar(dec_pronto_fn cb, void *ctx);
/// Solta os recursos de plataforma. **Chame da mesma thread que decodificou**, antes de
/// `dec_thread_sair`. Idempotente.
void dec_fechar(struct decodificador *d);
/// Libera a memória. Pode vir de qualquer thread, depois de `dec_fechar`.
void dec_destruir(struct decodificador *d);

/// Entrega um quadro Annex-B. Devolve `false` quando nada foi decodificado (quadro sem VCL, ou
/// ainda sem SPS/PPS, ou erro do decodificador).
bool dec_decodificar(struct decodificador *d, const uint8_t *annexb, size_t n, uint64_t chegada_ns);

/// Chamados uma vez pela thread que vai chamar `dec_decodificar`, na entrada e na saída dela.
///
/// No macOS não fazem nada. No Windows são obrigatórios: um `IMFTransform` só pode ser chamado de
/// uma thread com apartamento COM, e `MFStartup`/`MFShutdown` são contados por chamada. A frente da
/// câmera virtual pagou essa lição — ver o cabeçalho de `integrations/camera-windows/sonda/src/
/// receber.rs`: chamar MFT de thread sem apartamento "funciona nove vezes e trava na décima", e no
/// Windows travar é literal.
void dec_thread_entrar(void);
void dec_thread_sair(void);

/// O decodificador confirmou aceleração em hardware? Só vale depois do primeiro quadro.
bool dec_em_hardware(const struct decodificador *d);
/// Nome do mecanismo, para o diário. Nunca NULL.
const char *dec_nome(const struct decodificador *d);
uint32_t dec_largura(const struct decodificador *d);
uint32_t dec_altura(const struct decodificador *d);
/// Quantas vezes a sessão de decodificação foi (re)criada. Mais de 1 significa parâmetros trocados.
uint32_t dec_sessoes(const struct decodificador *d);
