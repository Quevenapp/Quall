// Decodificador H.264 por VideoToolbox — a implementação de macOS de `decodificador.h`.
#include "decodificador.h"
#include "anexob.h"
#include "quall-obs.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <string.h>

struct decodificador {
	dec_pronto_fn cb;
	void *ctx;

	struct buf avcc, sps, pps;

	CMVideoFormatDescriptionRef formato;
	VTDecompressionSessionRef sessao;

	uint32_t largura, altura;
	bool hardware;
	bool hardware_conferido;
	uint32_t sessoes;

	// Repassados ao tratador de saída do VideoToolbox pela referência da amostra.
	uint64_t chegada_ns;
	uint64_t inicio_ns;
	bool saiu;
};

static void ao_sair(void *ctx_dec, void *ref_quadro, OSStatus estado, VTDecodeInfoFlags bandeiras,
		    CVImageBufferRef imagem, CMTime pts, CMTime duracao)
{
	UNUSED_PARAMETER(ref_quadro);
	UNUSED_PARAMETER(bandeiras);
	UNUSED_PARAMETER(pts);
	UNUSED_PARAMETER(duracao);

	struct decodificador *d = ctx_dec;
	if (estado != noErr || !imagem) {
		if (estado != noErr)
			diga(LOG_WARNING, "VideoToolbox recusou o quadro: OSStatus %d", (int)estado);
		return;
	}

	uint64_t decode_ns = os_gettime_ns() - d->inicio_ns;
	d->largura = (uint32_t)CVPixelBufferGetWidth(imagem);
	d->altura = (uint32_t)CVPixelBufferGetHeight(imagem);
	d->saiu = true;

	// Travar aqui e não no chamador: o `CVPixelBufferRef` é detalhe do VideoToolbox e não
	// atravessa a interface. Quem recebe vê dois planos e dois passos, iguais aos do Windows.
	if (CVPixelBufferLockBaseAddress(imagem, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
		return;
	struct dec_nv12 q = {
		.y = CVPixelBufferGetBaseAddressOfPlane(imagem, 0),
		.passo_y = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(imagem, 0),
		.uv = CVPixelBufferGetBaseAddressOfPlane(imagem, 1),
		.passo_uv = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(imagem, 1),
		.largura = d->largura,
		.altura = d->altura,
	};
	d->cb(d->ctx, &q, d->chegada_ns, decode_ns);
	CVPixelBufferUnlockBaseAddress(imagem, kCVPixelBufferLock_ReadOnly);
}

static void largar_sessao(struct decodificador *d)
{
	if (d->sessao) {
		VTDecompressionSessionWaitForAsynchronousFrames(d->sessao);
		VTDecompressionSessionInvalidate(d->sessao);
		CFRelease(d->sessao);
		d->sessao = NULL;
	}
	if (d->formato) {
		CFRelease(d->formato);
		d->formato = NULL;
	}
}

static bool subir_sessao(struct decodificador *d)
{
	largar_sessao(d);
	if (!d->sps.n || !d->pps.n)
		return false;

	const uint8_t *conjuntos[2] = {d->sps.p, d->pps.p};
	const size_t tamanhos[2] = {d->sps.n, d->pps.n};
	OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, conjuntos,
									  tamanhos, 4, &d->formato);
	if (st != noErr) {
		diga(LOG_ERROR, "SPS/PPS recusados pelo CoreMedia: OSStatus %d (sps %zu B, pps %zu B)",
		     (int)st, d->sps.n, d->pps.n);
		d->formato = NULL;
		return false;
	}

	// NV12 de **faixa de vídeo**: o projeto padronizou faixa limitada (ver contrato-sidecar.md), e
	// no macOS quem decide a faixa é o formato do pixel buffer, não uma propriedade de sessão.
	CFMutableDictionaryRef atributos =
		CFDictionaryCreateMutable(kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
					  &kCFTypeDictionaryValueCallBacks);
	int32_t formato_px = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
	CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &formato_px);
	CFDictionarySetValue(atributos, kCVPixelBufferPixelFormatTypeKey, num);
	CFRelease(num);
	CFDictionaryRef vazio = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
						   &kCFTypeDictionaryKeyCallBacks,
						   &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(atributos, kCVPixelBufferIOSurfacePropertiesKey, vazio);
	CFRelease(vazio);

	VTDecompressionOutputCallbackRecord tratador = {ao_sair, d};
	st = VTDecompressionSessionCreate(kCFAllocatorDefault, d->formato, NULL, atributos, &tratador,
					  &d->sessao);
	CFRelease(atributos);
	if (st != noErr) {
		diga(LOG_ERROR, "VTDecompressionSessionCreate falhou: OSStatus %d", (int)st);
		d->sessao = NULL;
		CFRelease(d->formato);
		d->formato = NULL;
		return false;
	}

	VTSessionSetProperty(d->sessao, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
	d->sessoes++;
	d->hardware_conferido = false;

	CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(d->formato);
	diga(LOG_INFO, "decodificador de pé: %dx%d (sessão %u, sps %zu B, pps %zu B)", dim.width,
	     dim.height, d->sessoes, d->sps.n, d->pps.n);
	return true;
}

struct decodificador *dec_criar(dec_pronto_fn cb, void *ctx)
{
	struct decodificador *d = bzalloc(sizeof(*d));
	d->cb = cb;
	d->ctx = ctx;
	return d;
}

void dec_fechar(struct decodificador *d)
{
	if (d)
		largar_sessao(d);
}

void dec_destruir(struct decodificador *d)
{
	if (!d)
		return;
	largar_sessao(d);
	buf_soltar(&d->avcc);
	buf_soltar(&d->sps);
	buf_soltar(&d->pps);
	bfree(d);
}

bool dec_decodificar(struct decodificador *d, const uint8_t *annexb, size_t n, uint64_t chegada_ns)
{
	struct anexob_resultado res;
	if (!anexob_converter(annexb, n, &d->avcc, &d->sps, &d->pps, &res))
		return false;

	if (res.parametros_novos || !d->sessao) {
		if (!subir_sessao(d))
			return false;
	}
	if (!res.tem_vcl || d->avcc.n == 0)
		return false;

	CMBlockBufferRef bloco = NULL;
	// `kCFAllocatorNull` como desalocador: o buffer é nosso e sobrevive à chamada, porque a
	// decodificação abaixo é drenada antes de retornar. Sem isso seria uma cópia por quadro.
	OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, d->avcc.p, d->avcc.n,
							kCFAllocatorNull, NULL, 0, d->avcc.n, 0, &bloco);
	if (st != noErr)
		return false;

	CMSampleBufferRef amostra = NULL;
	size_t tamanho = d->avcc.n;
	CMSampleTimingInfo tempo = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
	st = CMSampleBufferCreateReady(kCFAllocatorDefault, bloco, d->formato, 1, 1, &tempo, 1, &tamanho,
				       &amostra);
	CFRelease(bloco);
	if (st != noErr)
		return false;

	d->chegada_ns = chegada_ns;
	d->inicio_ns = os_gettime_ns();
	d->saiu = false;

	VTDecodeInfoFlags saida_bandeiras = 0;
	st = VTDecompressionSessionDecodeFrame(d->sessao, amostra, 0, NULL, &saida_bandeiras);
	// **Drenar sempre.** A documentação da Apple não garante entrega síncrona mesmo sem
	// `kVTDecodeFrame_EnableAsynchronousDecompression`: sem esta espera, o `CVPixelBufferRef`
	// poderia chegar ao tratador depois de a fonte do OBS ter sido destruída.
	VTDecompressionSessionWaitForAsynchronousFrames(d->sessao);
	CFRelease(amostra);

	if (st != noErr) {
		diga(LOG_WARNING, "DecodeFrame falhou: OSStatus %d", (int)st);
		return false;
	}

	if (!d->hardware_conferido && d->saiu) {
		CFBooleanRef hw = NULL;
		if (VTSessionCopyProperty(d->sessao,
					  kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
					  kCFAllocatorDefault, &hw) == noErr &&
		    hw) {
			d->hardware = CFBooleanGetValue(hw);
			CFRelease(hw);
		}
		d->hardware_conferido = true;
		diga(LOG_INFO, "decode em hardware: %s", d->hardware ? "sim" : "NÃO");
	}

	return d->saiu;
}

void dec_thread_entrar(void) {}
void dec_thread_sair(void) {}

bool dec_em_hardware(const struct decodificador *d)
{
	return d->hardware;
}
const char *dec_nome(const struct decodificador *d)
{
	UNUSED_PARAMETER(d);
	return "VideoToolbox";
}
uint32_t dec_largura(const struct decodificador *d)
{
	return d->largura;
}
uint32_t dec_altura(const struct decodificador *d)
{
	return d->altura;
}
uint32_t dec_sessoes(const struct decodificador *d)
{
	return d->sessoes;
}
