// Decodificador H.264 por Media Foundation Transform — a implementação de Windows de
// `decodificador.h`.
//
// =================================================================================================
// A escolha que este arquivo faz, e o argumento
//
// `integrations/camera-windows` já mediu o caminho de decode neste mesmo Dell: *Microsoft H264
// Video Decoder MFT*, com um `IMFDXGIDeviceManager` registrado, decode p50 de **4,63 ms** e saída
// em **textura D3D11**. Esse é o caminho certo **para aquele consumidor**, que entrega pixel a um
// `VideoProcessorBlt` e a um cano — tudo do lado da GPU.
//
// Aqui o consumidor é outro. `obs_source_output_video()` de uma fonte assíncrona lê
// `data[]`/`linesize[]` da **CPU**: o OBS copia esses bytes para a fila de quadros da fonte. Pegar
// textura D3D11 do MFT para depois baixá-la com `CopyResource` + `Map` seria acrescentar uma
// leitura de volta GPU→CPU de ~1,4 MB por quadro no caminho — e uma sincronização com a GPU dentro
// da thread que publica.
//
// Então este arquivo **não registra o D3D manager**: pede NV12 em memória de sistema e entrega os
// dois planos direto ao OBS. O preço é decode em software, e o preço está medido — ver
// `plugins/obs/README.md`. Se algum dia o número não couber no orçamento, a alternativa está
// escrita aqui e não precisa ser redescoberta.
//
// A outra metade da lição da frente 7 **foi** copiada, e essa não é negociável: um `IMFTransform`
// só é chamado de uma thread com apartamento COM, e nunca de uma thread da libdatachannel. Ver
// `dec_thread_entrar` e o cabeçalho de `integrations/camera-windows/sonda/src/receber.rs`.
// =================================================================================================

#include "decodificador.h"
#include "quall-obs.h"
#include "remendo-sps.h"

#define COBJMACROS
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
// `ICodecAPI` é declarada no `strmif.h` (herança do DirectShow), não nos cabeçalhos de Media
// Foundation. Os GUIDs dela moram no `strmiids.lib`; ver logo abaixo por que não linkamos essa
// biblioteca.
#include <strmif.h>

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

// `CODECAPI_AVLowLatencyMode` e `IID_ICodecAPI` moram no `strmiids.lib`, que traz junto centenas de
// GUIDs de DirectShow que não usamos. Declarar os dois aqui evita a biblioteca inteira. Os valores
// são os do `codecapi.h`/`strmif.h` do SDK.
static const GUID quall_IID_ICodecAPI = {
	0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}};
static const GUID quall_CODECAPI_AVLowLatencyMode = {
	0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};

struct decodificador {
	dec_pronto_fn cb;
	void *ctx;

	IMFTransform *mft;
	char nome[192];
	bool d3d_aware; // indício de que o MFT sabe trabalhar com D3D11 — não é prova de nada aqui
	bool tentou_subir;

	// Amostra de saída própria. Só existe quando o MFT **não** provê a dele, que é o caso do
	// decodificador de software.
	IMFSample *saida;
	IMFMediaBuffer *saida_buf;
	bool mft_prove_amostra;

	// Layout do quadro. `_cod` é o tamanho codificado (o que manda no passo e no deslocamento do
	// plano UV); `largura`/`altura` são a abertura de exibição (o que vai para o OBS).
	uint32_t largura, altura;
	uint32_t largura_cod, altura_cod;
	LONG passo;

	uint32_t sessoes; // quantas vezes o tipo de saída foi (re)negociado
	bool fluxo_de_pe;
	int64_t relogio_100ns;

	uint64_t chegada_ns;
	uint64_t inicio_ns;
	bool saiu;

	// O remendo da `bitstream_restriction` (`remendo-sps.h`): o braço de bancada que o desliga
	// (`QUALL_OBS_PROVA_SPS_COMO_VEIO`, lido uma vez no `dec_criar`) e o aviso de uma vez só.
	bool sps_como_veio;
	bool avisou_restricao;
};

// -------------------------------------------------------------------------------------------------
// Apartamento COM e Media Foundation, por thread
// -------------------------------------------------------------------------------------------------
void dec_thread_entrar(void)
{
	// `COINIT_MULTITHREADED`: esta thread não tem laço de mensagens e nunca terá. Um apartamento
	// de thread única (STA) exigiria bombear mensagens para o COM não engasgar.
	HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
	if (FAILED(hr) && hr != RPC_E_CHANGED_MODE)
		diga(LOG_ERROR, "CoInitializeEx falhou: 0x%08lX", (unsigned long)hr);
	// `MFSTARTUP_LITE` não sobe a fila de trabalho do pipeline de mídia, que não usamos. As
	// chamadas são contadas: cada `MFStartup` pede um `MFShutdown`.
	hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
	if (FAILED(hr))
		diga(LOG_ERROR, "MFStartup falhou: 0x%08lX", (unsigned long)hr);
}

void dec_thread_sair(void)
{
	MFShutdown();
	CoUninitialize();
}

// -------------------------------------------------------------------------------------------------
// Escolha e configuração do MFT
// -------------------------------------------------------------------------------------------------
static void ler_nome(IMFActivate *act, char *destino, size_t cap)
{
	LPWSTR w = NULL;
	UINT32 n = 0;
	snprintf(destino, cap, "(sem nome)");
	if (SUCCEEDED(IMFActivate_GetAllocatedString(act, &MFT_FRIENDLY_NAME_Attribute, &w, &n)) && w) {
		WideCharToMultiByte(CP_UTF8, 0, w, -1, destino, (int)cap, NULL, NULL);
		CoTaskMemFree(w);
	}
}

static void tamanho_para(IMFMediaType *t, const GUID *chave, uint32_t a, uint32_t b)
{
	IMFMediaType_SetUINT64(t, chave, ((UINT64)a << 32) | (UINT64)b);
}

/// Escolhe NV12 entre os tipos de saída que o MFT oferece e lê o layout resultante.
///
/// A enumeração de saída só existe **depois** do `SetInputType`: um decodificador precisa saber o
/// que vai decodificar antes de dizer o que consegue entregar.
static bool negociar_saida(struct decodificador *d)
{
	bool escolheu = false;
	for (DWORD i = 0;; i++) {
		IMFMediaType *cand = NULL;
		if (FAILED(IMFTransform_GetOutputAvailableType(d->mft, 0, i, &cand)) || !cand)
			break;
		GUID sub = {0};
		IMFMediaType_GetGUID(cand, &MF_MT_SUBTYPE, &sub);
		if (IsEqualGUID(&sub, &MFVideoFormat_NV12) &&
		    SUCCEEDED(IMFTransform_SetOutputType(d->mft, 0, cand, 0)))
			escolheu = true;
		IMFMediaType_Release(cand);
		if (escolheu)
			break;
	}
	if (!escolheu) {
		diga(LOG_ERROR, "o MFT de decode não ofereceu NV12 na saída");
		return false;
	}

	IMFMediaType *saida = NULL;
	if (FAILED(IMFTransform_GetOutputCurrentType(d->mft, 0, &saida)) || !saida)
		return false;

	UINT64 quadro = 0;
	IMFMediaType_GetUINT64(saida, &MF_MT_FRAME_SIZE, &quadro);
	d->largura_cod = (uint32_t)(quadro >> 32);
	d->altura_cod = (uint32_t)(quadro & 0xffffffffu);
	d->largura = d->largura_cod;
	d->altura = d->altura_cod;

	// **A abertura de exibição não é enfeite.** Um 1080p chega codificado em 1920x1088 (o H.264
	// alinha a altura em 16), e publicar 1088 linhas mostra oito linhas de lixo no fim do quadro.
	// O deslocamento do plano UV, esse sim, usa a altura **codificada**.
	MFVideoArea abertura = {0};
	if (SUCCEEDED(IMFMediaType_GetBlob(saida, &MF_MT_MINIMUM_DISPLAY_APERTURE,
					   (UINT8 *)&abertura, sizeof(abertura), NULL)) &&
	    abertura.Area.cx > 0 && abertura.Area.cy > 0) {
		d->largura = (uint32_t)abertura.Area.cx;
		d->altura = (uint32_t)abertura.Area.cy;
	}

	UINT32 passo = 0;
	d->passo = (LONG)d->largura_cod;
	if (SUCCEEDED(IMFMediaType_GetUINT32(saida, &MF_MT_DEFAULT_STRIDE, &passo)) && (LONG)passo > 0)
		d->passo = (LONG)passo;
	IMFMediaType_Release(saida);

	// A amostra de saída. O decodificador de software não provê a dele — quem aloca somos nós, e
	// o mesmo par amostra/buffer é reusado em todos os quadros.
	if (d->saida) {
		IMFSample_Release(d->saida);
		d->saida = NULL;
	}
	if (d->saida_buf) {
		IMFMediaBuffer_Release(d->saida_buf);
		d->saida_buf = NULL;
	}
	MFT_OUTPUT_STREAM_INFO info = {0};
	IMFTransform_GetOutputStreamInfo(d->mft, 0, &info);
	d->mft_prove_amostra = (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
						MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
	if (!d->mft_prove_amostra) {
		DWORD tam = info.cbSize ? info.cbSize
					: (DWORD)(d->passo * (LONG)d->altura_cod * 3 / 2);
		DWORD alinha = info.cbAlignment ? info.cbAlignment - 1 : MF_16_BYTE_ALIGNMENT;
		if (FAILED(MFCreateAlignedMemoryBuffer(tam, alinha, &d->saida_buf)) ||
		    FAILED(MFCreateSample(&d->saida))) {
			diga(LOG_ERROR, "não consegui alocar a amostra de saída do decodificador");
			return false;
		}
		IMFSample_AddBuffer(d->saida, d->saida_buf);
	}

	d->sessoes++;
	diga(LOG_INFO,
	     "decodificador de pé: %ux%u (codificado %ux%u, passo %ld, sessão %u, amostra %s)",
	     d->largura, d->altura, d->largura_cod, d->altura_cod, d->passo, d->sessoes,
	     d->mft_prove_amostra ? "do MFT" : "nossa");
	return true;
}

static bool subir_mft(struct decodificador *d)
{
	MFT_REGISTER_TYPE_INFO entrada = {MFMediaType_Video, MFVideoFormat_H264};
	IMFActivate **lista = NULL;
	UINT32 quantos = 0;

	// `LOCALMFT` inclui MFTs registrados só para este processo; `SYNCMFT` é o que o
	// decodificador da Microsoft é — a frente 7 mediu isso neste mesmo Dell: nenhum MFT de
	// decode H.264 se registrou como assíncrono aqui, e o cast para `IMFMediaEventGenerator`
	// devolveu `E_NOINTERFACE`. Por isso este arquivo não tem fila de eventos: o laço é
	// `ProcessInput`/`ProcessOutput` direto.
	HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
			       MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
				       MFT_ENUM_FLAG_SORTANDFILTER,
			       &entrada, NULL, &lista, &quantos);
	if (FAILED(hr) || !quantos) {
		diga(LOG_ERROR, "nenhum MFT de decode H.264 nesta máquina (0x%08lX)", (unsigned long)hr);
		if (lista)
			CoTaskMemFree(lista);
		return false;
	}

	for (UINT32 i = 0; i < quantos && !d->mft; i++) {
		char nome[192];
		ler_nome(lista[i], nome, sizeof(nome));
		IMFTransform *t = NULL;
		hr = IMFActivate_ActivateObject(lista[i], &IID_IMFTransform, (void **)&t);
		if (FAILED(hr) || !t) {
			diga(LOG_WARNING, "candidato \"%s\" não ativou: 0x%08lX", nome,
			     (unsigned long)hr);
			continue;
		}
		diga(LOG_INFO, "MFT de decode escolhido: \"%s\" (entre %u candidato(s))", nome, quantos);
		snprintf(d->nome, sizeof(d->nome), "%s", nome);
		d->mft = t;
	}
	for (UINT32 i = 0; i < quantos; i++)
		if (lista[i])
			IMFActivate_Release(lista[i]);
	CoTaskMemFree(lista);
	if (!d->mft)
		return false;

	// --- baixa latência, e ela não é opcional -------------------------------------------------
	// Sem isto o decodificador da Microsoft **segura quadros** para reordenar, e o que chega ao
	// OBS é meio segundo atrasado com o contador subindo normalmente: o pior tipo de defeito,
	// porque parece que está tudo certo.
	IMFAttributes *at = NULL;
	if (SUCCEEDED(IMFTransform_GetAttributes(d->mft, &at)) && at) {
		UINT32 v = 0;
		if (SUCCEEDED(IMFAttributes_GetUINT32(at, &MF_SA_D3D11_AWARE, &v)))
			d->d3d_aware = (v == 1);
		bool baixa = SUCCEEDED(IMFAttributes_SetUINT32(at, &MF_LOW_LATENCY, 1));
		diga(LOG_INFO, "MF_LOW_LATENCY: %s | MF_SA_D3D11_AWARE: %s (só indício)",
		     baixa ? "aceito" : "RECUSADO", d->d3d_aware ? "sim" : "não");
		IMFAttributes_Release(at);
	}
	ICodecAPI *codec = NULL;
	if (SUCCEEDED(IMFTransform_QueryInterface(d->mft, &quall_IID_ICodecAPI, (void **)&codec)) &&
	    codec) {
		VARIANT v;
		VariantInit(&v);
		v.vt = VT_BOOL;
		v.boolVal = VARIANT_TRUE;
		HRESULT hr2 = ICodecAPI_SetValue(codec, &quall_CODECAPI_AVLowLatencyMode, &v);
		diga(LOG_INFO, "CODECAPI_AVLowLatencyMode: %s",
		     SUCCEEDED(hr2) ? "aceito" : "recusado");
		VariantClear(&v);
		ICodecAPI_Release(codec);
	}

	// --- tipo de entrada ----------------------------------------------------------------------
	// Sem tamanho: o SPS que vem no Annex-B manda, e o decodificador avisa por
	// `MF_E_TRANSFORM_STREAM_CHANGE` quando descobrir o tamanho de verdade. Declarar um tamanho
	// aqui seria inventar um número que o fluxo pode desmentir.
	IMFMediaType *tipo = NULL;
	if (FAILED(MFCreateMediaType(&tipo)))
		return false;
	IMFMediaType_SetGUID(tipo, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
	IMFMediaType_SetGUID(tipo, &MF_MT_SUBTYPE, &MFVideoFormat_H264);
	IMFMediaType_SetUINT32(tipo, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
	tamanho_para(tipo, &MF_MT_FRAME_RATE, 30, 1);
	hr = IMFTransform_SetInputType(d->mft, 0, tipo, 0);
	IMFMediaType_Release(tipo);
	if (FAILED(hr)) {
		diga(LOG_ERROR, "SetInputType (H.264) falhou: 0x%08lX", (unsigned long)hr);
		return false;
	}

	if (!negociar_saida(d))
		return false;

	IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
	IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
	d->fluxo_de_pe = true;
	return true;
}

// -------------------------------------------------------------------------------------------------
// Entrega de um quadro pronto
// -------------------------------------------------------------------------------------------------
static void publicar(struct decodificador *d, IMFSample *amostra)
{
	IMFMediaBuffer *buf = NULL;
	// `ConvertToContiguousBuffer` e não `GetBufferByIndex`: uma amostra pode trazer mais de um
	// buffer, e aí os planos não estariam onde a conta abaixo espera.
	if (FAILED(IMFSample_ConvertToContiguousBuffer(amostra, &buf)) || !buf)
		return;

	BYTE *p = NULL;
	LONG passo = d->passo;
	IMF2DBuffer *b2d = NULL;
	bool travou_2d = false;

	if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer, (void **)&b2d)) && b2d) {
		if (SUCCEEDED(IMF2DBuffer_Lock2D(b2d, &p, &passo)))
			travou_2d = true;
		else
			p = NULL;
	}
	DWORD max = 0, atual = 0;
	if (!p) {
		if (FAILED(IMFMediaBuffer_Lock(buf, &p, &max, &atual)) || !p) {
			if (b2d)
				IMF2DBuffer_Release(b2d);
			IMFMediaBuffer_Release(buf);
			return;
		}
	}

	if (passo > 0) {
		uint64_t decode_ns = os_gettime_ns() - d->inicio_ns;
		d->saiu = true;
		struct dec_nv12 q = {
			.y = p,
			.passo_y = (uint32_t)passo,
			// NV12 contíguo: o plano de croma começa logo depois de `altura_cod` linhas de
			// luma, com o **mesmo** passo. É por isso que a altura codificada é lida
			// separada da abertura de exibição.
			.uv = p + (size_t)passo * d->altura_cod,
			.passo_uv = (uint32_t)passo,
			.largura = d->largura,
			.altura = d->altura,
		};
		d->cb(d->ctx, &q, d->chegada_ns, decode_ns);
	} else {
		diga(LOG_WARNING, "passo negativo (%ld): quadro de baixo para cima não é tratado", passo);
	}

	if (travou_2d)
		IMF2DBuffer_Unlock2D(b2d);
	else
		IMFMediaBuffer_Unlock(buf);
	if (b2d)
		IMF2DBuffer_Release(b2d);
	IMFMediaBuffer_Release(buf);
}

/// Tira do MFT tudo que estiver pronto agora.
static void drenar(struct decodificador *d)
{
	for (;;) {
		MFT_OUTPUT_DATA_BUFFER saida = {0};
		DWORD estado = 0;
		saida.dwStreamID = 0;
		if (!d->mft_prove_amostra) {
			if (!d->saida)
				return;
			IMFMediaBuffer_SetCurrentLength(d->saida_buf, 0);
			saida.pSample = d->saida;
		}

		HRESULT hr = IMFTransform_ProcessOutput(d->mft, 0, 1, &saida, &estado);
		if (saida.pEvents) {
			IMFCollection_Release(saida.pEvents);
			saida.pEvents = NULL;
		}

		if (SUCCEEDED(hr)) {
			if (saida.pSample)
				publicar(d, saida.pSample);
			if (d->mft_prove_amostra && saida.pSample)
				IMFSample_Release(saida.pSample);
			continue;
		}
		if (d->mft_prove_amostra && saida.pSample)
			IMFSample_Release(saida.pSample);

		if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT)
			return;
		if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
			// O decodificador leu o SPS e agora sabe o tamanho de verdade. Renegociar não
			// é erro: é o caminho normal do primeiro IDR e de toda troca de resolução.
			if (!negociar_saida(d))
				return;
			continue;
		}
		diga(LOG_WARNING, "ProcessOutput devolveu 0x%08lX", (unsigned long)hr);
		return;
	}
}

// -------------------------------------------------------------------------------------------------
// Superfície pública
// -------------------------------------------------------------------------------------------------
struct decodificador *dec_criar(dec_pronto_fn cb, void *ctx)
{
	// Só memória. O MFT sobe na primeira chamada de `dec_decodificar`, que é a primeira vez que
	// estamos comprovadamente na thread de decodificação — e é lá que existe apartamento COM.
	struct decodificador *d = bzalloc(sizeof(*d));
	d->cb = cb;
	d->ctx = ctx;
	snprintf(d->nome, sizeof(d->nome), "Media Foundation");
	const char *como_veio = getenv("QUALL_OBS_PROVA_SPS_COMO_VEIO");
	d->sps_como_veio = como_veio && strcmp(como_veio, "1") == 0;
	if (d->sps_como_veio)
		diga(LOG_WARNING, "BANCADA: o SPS vai ao decodificador como veio (sem o remendo da "
				  "bitstream_restriction)");
	return d;
}

void dec_fechar(struct decodificador *d)
{
	if (!d)
		return;
	if (d->mft && d->fluxo_de_pe) {
		IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
		IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
		d->fluxo_de_pe = false;
	}
	if (d->saida) {
		IMFSample_Release(d->saida);
		d->saida = NULL;
	}
	if (d->saida_buf) {
		IMFMediaBuffer_Release(d->saida_buf);
		d->saida_buf = NULL;
	}
	if (d->mft) {
		IMFTransform_Release(d->mft);
		d->mft = NULL;
	}
}

void dec_destruir(struct decodificador *d)
{
	if (!d)
		return;
	// `dec_fechar` já rodou na thread de decodificação; isto aqui é a rede de segurança para o
	// caso de a thread nunca ter subido — quando não há nada de COM para soltar.
	dec_fechar(d);
	bfree(d);
}

static bool decodificar_um(struct decodificador *d, const uint8_t *annexb, size_t n,
			   uint64_t chegada_ns);

bool dec_decodificar(struct decodificador *d, const uint8_t *annexb, size_t n, uint64_t chegada_ns)
{
	// **A `bitstream_restriction` antes do MFT** (a S7 do som, `docs/som-no-receptor.md` §20.19):
	// sem ela, este decodificador segura ~5 quadros antes de entregar, e o `MF_LOW_LATENCY` não
	// basta (o `CODECAPI_AVLowLatencyMode` ele recusa). O SPS Baseline que chega sem a restrição a
	// ganha com `max_num_reorder_frames = 0`; ver `remendo-sps.h`. Braço de bancada:
	// `QUALL_OBS_PROVA_SPS_COMO_VEIO=1` desliga.
	uint8_t *remendado = NULL;
	size_t n_remendado = 0;
	if (!d->sps_como_veio && remendo_sps_restricao(annexb, n, &remendado, &n_remendado)) {
		if (!d->avisou_restricao) {
			d->avisou_restricao = true;
			diga(LOG_INFO,
			     "sps: o emissor não declara bitstream_restriction — declarando reorder=0 "
			     "(Baseline não reordena), para o decodificador não segurar quadros (%zu -> %zu "
			     "bytes no quadro)",
			     n, n_remendado);
		}
		bool r = decodificar_um(d, remendado, n_remendado, chegada_ns);
		free(remendado);
		return r;
	}
	return decodificar_um(d, annexb, n, chegada_ns);
}

static bool decodificar_um(struct decodificador *d, const uint8_t *annexb, size_t n,
			   uint64_t chegada_ns)
{
	if (!d->mft) {
		if (d->tentou_subir)
			return false;
		d->tentou_subir = true;
		if (!subir_mft(d)) {
			dec_fechar(d);
			return false;
		}
	}

	IMFMediaBuffer *buf = NULL;
	if (FAILED(MFCreateMemoryBuffer((DWORD)n, &buf)) || !buf)
		return false;
	BYTE *destino = NULL;
	if (FAILED(IMFMediaBuffer_Lock(buf, &destino, NULL, NULL))) {
		IMFMediaBuffer_Release(buf);
		return false;
	}
	memcpy(destino, annexb, n);
	IMFMediaBuffer_Unlock(buf);
	IMFMediaBuffer_SetCurrentLength(buf, (DWORD)n);

	IMFSample *entrada = NULL;
	if (FAILED(MFCreateSample(&entrada)) || !entrada) {
		IMFMediaBuffer_Release(buf);
		return false;
	}
	IMFSample_AddBuffer(entrada, buf);
	// Relógio próprio, em passos de 33,3 ms. O carimbo do emissor não serve aqui: o que importa
	// para o decodificador é a **ordem**, e o Baseline que este projeto emite não tem quadro B
	// para reordenar. O carimbo que o OBS recebe é o da chegada na casca, e vem de `receptor.c`.
	IMFSample_SetSampleTime(entrada, d->relogio_100ns);
	IMFSample_SetSampleDuration(entrada, 333667);
	d->relogio_100ns += 333667;

	d->chegada_ns = chegada_ns;
	d->inicio_ns = os_gettime_ns();
	d->saiu = false;

	HRESULT hr = IMFTransform_ProcessInput(d->mft, 0, entrada, 0);
	if (hr == MF_E_NOTACCEPTING) {
		// O MFT quer que a saída seja retirada antes de aceitar mais entrada.
		drenar(d);
		hr = IMFTransform_ProcessInput(d->mft, 0, entrada, 0);
	}
	IMFSample_Release(entrada);
	IMFMediaBuffer_Release(buf);

	if (FAILED(hr)) {
		diga(LOG_WARNING, "ProcessInput devolveu 0x%08lX", (unsigned long)hr);
		return false;
	}
	drenar(d);
	return d->saiu;
}

bool dec_em_hardware(const struct decodificador *d)
{
	// **Não** mentir aqui. Sem `IMFDXGIDeviceManager` registrado, o MFT decodifica na CPU; o
	// `MF_SA_D3D11_AWARE` diz só que ele **saberia** usar D3D11 se lhe dessem um. Ver o
	// cabeçalho deste arquivo para por que não damos.
	UNUSED_PARAMETER(d);
	return false;
}

const char *dec_nome(const struct decodificador *d)
{
	return d->nome;
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
